import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Superadmin-only fleet management, called from the web admin
// (apps/web_app → /admin, "Пользователи" tab → «Все устройства»).
//
//   POST { action: 'list' }                        → every machine + owner email
//   POST { action: 'transfer', machid, owner_id }  → reassign to another account
//   POST { action: 'rename', machid, name }        → rename any machine
//   POST { action: 'kind', machid, kind }          → change the machine type
//   POST { action: 'delete', machid, confirm? }    → remove the machine
//
// Owners rename their OWN machines with a plain UPDATE from the browser (the
// RLS policy already scopes that). `rename` here exists for the fleet list,
// where the superadmin edits machines it doesn't own and RLS would silently
// match zero rows.
//
// Why a function and not direct table access: RLS scopes `micromarkets` to
// owner_id = auth.uid() for the authenticated role, so even the superadmin's
// browser sees only its own machines. Everything here runs as service_role and
// is gated on app_metadata.is_superadmin instead — the same un-forgeable flag
// admin-create-user uses (see 20260804120000_superadmin_role.sql).
//
// DELETE IS DESTRUCTIVE. inventory.micromarket_id and sales.micromarket_id are
// both ON DELETE CASCADE, so removing a machine also removes its entire sales
// history. We therefore refuse a machine that has sales unless the caller
// passes confirm:true, and always report the counts so the UI can spell out
// what is about to be lost.
//
// pending_orders used to be NO ACTION, and the comment here called that
// correct — "an unsettled payment must not vanish". It read well and was
// wrong in a way nobody could see from the UI: the constraint does not know
// what "unsettled" means. It blocked on ANY row, including orders finished
// months ago, so a machine that had ever sold anything could not be deleted
// at all — DELETE reached the database and came back as a raw 23503 behind
// "Не удалось удалить аппарат". Machine 5840 had 27 pending and 61 completed;
// only the first group produced a message anyone could act on.
//
// The constraint is CASCADE now (20260903120000) and the guard lives here,
// where it can tell a live payment from litter: only orders younger than
// PENDING_FRESH_MS block. An unpaid QR is abandoned within a minute and the
// gateway returns the money on its own, so a day-old `pending` row protects
// nothing — it only makes the machine undeletable.
//
// verify_jwt is false in config.toml; the caller's session token is checked here.

// Насколько свежим должен быть неоплаченный заказ, чтобы считаться деньгами
// в полёте. Окно оплаты у шлюза — минута, плюс запас на цепочку MQTT →
// complete-order → finalize_paid_order; час перекрывает её многократно и
// при этом не даёт вчерашнему мусору держать аппарат.
const PENDING_FRESH_MS = 60 * 60 * 1000;

// Зеркало CHECK на micromarkets.kind (20260831120000) и того же списка в
// device-claim. Значение, принятое здесь и отсутствующее там, приезжает
// сырым 23514 из базы вместо внятного отказа.
const KINDS = [
  "vending",
  "micromarket_static",
  "micromarket_tablet",
  "micromarket_screen",
];

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    { auth: { persistSession: false } },
  );

  // ── caller must be a superadmin ───────────────────────────────────────────
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ error: "not authenticated" }, 401);
  const { data: caller, error: callerErr } = await supabase.auth.getUser(token);
  if (callerErr || !caller?.user) return json({ error: "not authenticated" }, 401);
  if (caller.user.app_metadata?.is_superadmin !== true) return json({ error: "forbidden" }, 403);

  try {
    const body = await req.json().catch(() => ({}));
    const action = String(body.action ?? "").trim();

    // ── list: every machine, with its owner's email ─────────────────────────
    if (action === "list") {
      const { data: markets, error } = await supabase
        .from("micromarkets")
        .select("id, name, kind, status, owner_id")
        .order("id");
      if (error) throw error;

      // Heartbeat comes from the view, not the table: `online` is evaluated
      // there against the database clock with a single threshold, so the
      // fleet list and the owner's own list can never disagree about who is
      // up. RLS hides other owners' rows from the browser, which is exactly
      // why this read has to happen here under service_role.
      const { data: beats } = await supabase
        .from("device_status_view")
        .select("machid, last_seen_at, board_ok, online, ter_number");
      const beatById = new Map((beats ?? []).map((b) => [b.machid, b]));

      // Resolve owner_id → email. listUsers is one call; joining auth.users
      // through PostgREST isn't possible (it's not in the exposed schema).
      const { data: list } = await supabase.auth.admin.listUsers({ page: 1, perPage: 200 });
      const emailById = new Map((list?.users ?? []).map((u) => [u.id, u.email]));

      return json({
        markets: (markets ?? []).map((m) => ({
          ...m,
          owner_email: m.owner_id ? emailById.get(m.owner_id) ?? null : null,
          // Undefined when the machine never reported — the UI says
          // "never seen" rather than calling a fresh install a fault.
          heartbeat: beatById.get(m.id) ?? null,
        })),
        owners: (list?.users ?? []).map((u) => ({ id: u.id, email: u.email })),
      });
    }

    const machid = parseInt(String(body.machid ?? "").trim());
    if (!machid) return json({ error: "bad_machid" }, 400);

    const { data: market } = await supabase
      .from("micromarkets").select("id, name, kind, owner_id").eq("id", machid).maybeSingle();
    if (!market) return json({ error: "machine_not_found" }, 404);

    // ── transfer: hand the machine to another account ───────────────────────
    if (action === "transfer") {
      const ownerId = String(body.owner_id ?? "").trim();
      if (!ownerId) return json({ error: "owner_required" }, 400);

      // Reject unknown ids up front: owner_id has no FK to auth.users, so a
      // typo would silently orphan the machine instead of erroring.
      const { data: target, error: targetErr } = await supabase.auth.admin.getUserById(ownerId);
      if (targetErr || !target?.user) return json({ error: "owner_not_found" }, 404);

      const { data: row, error } = await supabase
        .from("micromarkets").update({ owner_id: ownerId }).eq("id", machid)
        .select("id, name, kind, owner_id").single();
      if (error) throw error;
      return json({ market: row, owner_email: target.user.email });
    }

    // ── rename ──────────────────────────────────────────────────────────────
    if (action === "rename") {
      const name = String(body.name ?? "").trim();
      if (!name) return json({ error: "name_required" }, 400);

      const { data: row, error } = await supabase
        .from("micromarkets").update({ name }).eq("id", machid)
        .select("id, name, kind, owner_id").single();
      if (error) throw error;
      return json({ market: row });
    }

    // ── kind: сменить тип машины, не удаляя её ──────────────────────────────
    //
    // Раньше единственным способом было завести машину заново — а вместе с
    // ней уезжала вся история продаж и раскладка. Тип же меняется не от
    // хорошей жизни: холодильник переехал с планшета на статический QR,
    // вендинговый шкаф стал микромаркетом. Это перенастройка, а не новая
    // машина.
    //
    // Меняем только колонку. Ни продажи, ни inventory, ни привязка планшета
    // не трогаются: kind описывает, чем машина работает, а не что она
    // продала. Планшет, который уже привязан, продолжит работать — kind он
    // читает только при привязке (verify_pairing), и режим у него всё равно
    // определяет выбранный на месте тип платы.
    if (action === "kind") {
      const kind = String(body.kind ?? "").trim();
      if (!KINDS.includes(kind)) return json({ error: "bad_kind", kinds: KINDS }, 400);
      if (kind === market.kind) return json({ market });

      const { data: row, error } = await supabase
        .from("micromarkets").update({ kind }).eq("id", machid)
        .select("id, name, kind, owner_id").single();
      if (error) throw error;

      // Предупреждение, а не запрет: у screen-машины покупатель набирает
      // номер ячейки, то есть позиции обязаны иметь motor_id 10..99. Позиции
      // с номером вне диапазона на витрине просто не появятся, и знать об
      // этом лучше сразу, чем по звонку с точки.
      let warn = null;
      if (kind === "micromarket_screen") {
        const { count: unnumbered } = await supabase
          .from("inventory").select("id", { count: "exact", head: true })
          .eq("micromarket_id", machid).is("motor_id", null);
        const { count: outOfRange } = await supabase
          .from("inventory").select("id", { count: "exact", head: true })
          .eq("micromarket_id", machid).not("motor_id", "is", null)
          .or("motor_id.lt.10,motor_id.gt.99");
        if ((unnumbered ?? 0) > 0 || (outOfRange ?? 0) > 0) {
          warn = { code: "cells_need_numbers", unnumbered: unnumbered ?? 0, out_of_range: outOfRange ?? 0 };
        }
      }
      return json({ market: row, warn });
    }

    // ── delete: destructive, gated on an explicit confirm ───────────────────
    if (action === "delete") {
      const freshSince = new Date(Date.now() - PENDING_FRESH_MS).toISOString();
      const [
        { count: sales },
        { count: inventory },
        { count: orders },
        { count: freshPending },
      ] = await Promise.all([
        supabase.from("sales").select("id", { count: "exact", head: true }).eq("micromarket_id", machid),
        supabase.from("inventory").select("id", { count: "exact", head: true }).eq("micromarket_id", machid),
        // Все заказы, а не только pending: теперь они уходят каскадом, и в
        // диалоге честнее показать, сколько именно исчезнет.
        supabase.from("pending_orders").select("orderid", { count: "exact", head: true })
          .eq("micromarket_id", machid),
        supabase.from("pending_orders").select("orderid", { count: "exact", head: true })
          .eq("micromarket_id", machid).eq("status", "pending").gte("created_at", freshSince),
      ]);

      // Money in flight — never delete underneath it. Старые pending сюда не
      // попадают: платёж, за который никто не взялся, шлюз возвращает сам, и
      // строка остаётся памятником несостоявшейся покупке, а не долгом.
      if ((freshPending ?? 0) > 0) {
        return json({ error: "has_pending_orders", pending: freshPending }, 409);
      }
      // First call always comes back with the impact so the UI can spell it out.
      if (body.confirm !== true) {
        return json({
          error: "confirm_required",
          machid, name: market.name, sales: sales ?? 0, inventory: inventory ?? 0,
          orders: orders ?? 0,
        }, 409);
      }

      const { error } = await supabase.from("micromarkets").delete().eq("id", machid);
      if (error) throw error;
      return json({
        deleted: machid,
        sales: sales ?? 0,
        inventory: inventory ?? 0,
        orders: orders ?? 0,
      });
    }

    return json({ error: "bad_action" }, 400);
  } catch (error) {
    return json({ error: error.message }, 500);
  }
});
