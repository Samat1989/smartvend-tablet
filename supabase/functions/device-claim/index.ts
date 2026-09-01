import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Device registration, called from the web admin
// (apps/web_app → /admin, "Устройства" tab → «Добавить устройство»).
//
//   POST { machid, secret?, kind? } → creates the micromarkets row
//
// `secret` is OPTIONAL. Left out, it is resolved here from the SmartVend list
// (cached in public.smartvend_machines, same source device-provision uses) —
// that's the normal path, and it keeps the payment-signing key out of the
// browser entirely. Supplied, it wins: that's the escape hatch for a machine
// the upstream list doesn't carry (in-house rigs, a machine enrolled in
// SmartVend but not published yet), which otherwise can't be registered at all.
//
// A supplied secret is still cross-checked when the machine IS in the list: a
// mismatch there is almost always a typo, and enrolling a key that can't sign
// payments fails silently later, at the first customer. `force: true` skips
// even that comparison.
//
// The name always comes from the SmartVend list; `kind` stays a choice because
// the upstream list doesn't carry the machine type and it can't be guessed.
//
// SUPERADMIN ONLY. Owners must not enrol machines themselves — they get one
// handed to them by the platform admin (who can then reassign it with
// device-admin's `transfer`). Gating only the button would be cosmetic: the
// function is a public HTTP endpoint, so the check lives here.
//
// A machine that already has an owner is rejected with 409 `already_claimed`
// (plus that owner's email) even for the superadmin — reassigning is
// device-admin's `transfer`, which names both accounts and asks first.
//
// Why an edge function and not a direct insert from the browser: `secret` is
// the payment-signing key for the LV gateway and is meant to be backend-only
// (audit finding F1, docs/security-audit-2026-06.md). Resolving it here means
// it is never sent to a client on the way in either — the browser only ever
// learns whether the Internal ID exists.
//
// verify_jwt is false in config.toml (the gateway can't tell the publishable
// key from a user JWT); the caller's session token is validated here.

const PARTNER_URL =
  "https://partner.smartvend.kz/mb/public/question/8ef367bd-764e-4962-953b-e004df2b690d.json";
// Mirrors the CHECK on micromarkets.kind (migration
// 20260831120000_micromarket_screen_kind.sql) — a value accepted here but
// missing there fails as a raw 23514 at insert time.
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

// Refresh public.smartvend_machines from the upstream list and return the row
// for `wantMachid` (or null). Same shape as device-provision/index.ts — the two
// deliberately stay self-contained so redeploying one can't break the other.
async function refreshCache(supabase, wantMachid) {
  const resp = await fetch(PARTNER_URL);
  if (!resp.ok) throw new Error(`upstream ${resp.status}`);
  const list = await resp.json();
  if (!Array.isArray(list)) throw new Error("unexpected upstream format");

  const byId = new Map();
  for (const r of list) {
    const machid = Number(r["Internal ID"]);
    const uuid = r["ID"];
    const secret = String(r["Secret"] ?? "").trim();
    if (!machid || !uuid || !secret) continue;
    byId.set(machid, { machid, uuid, secret, name: r["Description"] ?? "" });
  }
  const rows = [...byId.values()];

  for (let i = 0; i < rows.length; i += 1000) {
    const { error } = await supabase
      .from("smartvend_machines")
      .upsert(rows.slice(i, i + 1000), { onConflict: "machid" });
    if (error) throw error;
  }

  return byId.get(wantMachid) ?? null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    { auth: { persistSession: false } },
  );

  // ── caller must be the superadmin ─────────────────────────────────────────
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ error: "not authenticated" }, 401);
  const { data: caller, error: callerErr } = await supabase.auth.getUser(token);
  if (callerErr || !caller?.user) return json({ error: "not authenticated" }, 401);
  if (caller.user.app_metadata?.is_superadmin !== true) return json({ error: "forbidden" }, 403);
  const ownerId = caller.user.id;

  try {
    const body = await req.json().catch(() => ({}));
    const machid = parseInt(String(body.machid ?? "").trim());
    const kind = String(body.kind ?? "vending").trim();
    const typedSecret = String(body.secret ?? "").trim();
    // Skip the cross-check against the list entirely. Not reachable from the
    // admin UI — curl only, for when SmartVend's own record is the wrong one.
    const force = body.force === true;

    if (!machid || machid < 0) return json({ error: "bad_machid" }, 400);
    if (!KINDS.includes(kind)) return json({ error: "bad_kind" }, 400);
    if (force && !typedSecret) return json({ error: "secret_required" }, 400);

    // ── look the machine up in the SmartVend list ───────────────────────────
    //
    // Go to the source rather than trusting the cache. Enrolment is rare and
    // human-triggered, so one upstream fetch is cheap — and with nothing typed
    // it is the only thing standing between a rotated secret and a machine
    // enrolled with a key that can't sign payments. The refresh also updates
    // the cache device-provision reads.
    let upstream = null;
    if (!force) {
      try {
        upstream = await refreshCache(supabase, machid);
      } catch (_) {
        // Upstream unreachable — fall back to whatever we cached earlier.
        const { data: cached } = await supabase
          .from("smartvend_machines").select("machid, secret, name").eq("machid", machid).maybeSingle();
        upstream = cached ?? null;
      }
    }

    // ── settle on the secret ────────────────────────────────────────────────
    let secret;
    if (typedSecret) {
      // Typed by hand wins — that's the whole point of the field. But if the
      // machine is in the list, disagreeing with it means a typo far more often
      // than it means SmartVend is wrong, so say so instead of enrolling a key
      // that will fail at the first payment.
      const listed = String(upstream?.secret ?? "").trim();
      if (listed && listed !== typedSecret) {
        return json({ error: "secret_mismatch" }, 403);
      }
      secret = typedSecret;
    } else {
      // Nothing typed: the list is the only source. No row there, or a row
      // without a usable key, and there is nothing to enrol.
      if (!upstream) return json({ error: "machine_not_found" }, 404);
      secret = String(upstream.secret ?? "").trim();
      if (!secret) return json({ error: "machine_not_found" }, 404);
    }

    // ── claim or create the micromarkets row ────────────────────────────────
    const { data: existing } = await supabase
      .from("micromarkets").select("id, owner_id, name").eq("id", machid).maybeSingle();

    // A machine that already has an owner is never re-enrolled here, not even
    // by the superadmin: moving one between accounts is device-admin's
    // `transfer`, where the UI names both sides and asks for confirmation. Here
    // a mistyped Internal ID would silently move a live machine instead.
    // An owner-less row (imported by hand, or left over) may still be claimed.
    if (existing?.owner_id) {
      const { data: prev } = await supabase.auth.admin.getUserById(existing.owner_id);
      return json({
        error: "already_claimed",
        owner_email: prev?.user?.email ?? null,
      }, 409);
    }

    // Name comes off the machine's SmartVend page ("Description"). The operator
    // renames it later from the devices list if they want something else.
    const label = String(upstream?.name ?? "").trim() || `Аппарат ${machid}`;
    let row, err;
    if (existing) {
      // Owner-less row: adopt it, refreshing the secret. Keep whatever name it
      // already carries — someone typed it for a reason, and the upstream
      // "Description" is usually the vaguer of the two. Never rewrite `kind` on
      // an existing machine — that would repoint a live tablet/relay at the
      // wrong flow.
      ({ data: row, error: err } = await supabase
        .from("micromarkets")
        .update({ owner_id: ownerId, secret, name: existing.name || label })
        .eq("id", machid)
        .select("id, name, kind, qr_token, owner_id")
        .single());
    } else {
      ({ data: row, error: err } = await supabase
        .from("micromarkets")
        .insert({ id: machid, owner_id: ownerId, secret, name: label, kind })
        .select("id, name, kind, qr_token, owner_id")
        .single());
    }
    if (err) throw err;

    // Never echo the secret back to the browser.
    return json({ market: row, claimed: Boolean(existing), verified: !force }, existing ? 200 : 201);
  } catch (error) {
    return json({ error: error.message }, 500);
  }
});
