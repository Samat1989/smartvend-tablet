import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Device registration, called from the web admin
// (apps/web_app → /admin, "Устройства" tab → «Добавить устройство»).
//
//   POST { machid, kind? } → creates the micromarkets row
//
// The operator types ONE thing: the machine's Internal ID. Secret and name are
// resolved here from the SmartVend list (cached in public.smartvend_machines,
// same source device-provision uses) — the secret is the payment-signing key
// and has no business travelling through a browser at all, and the name is
// already on the machine's partner page, so retyping it was busywork that only
// produced typos. `kind` stays a choice because the upstream list doesn't carry
// the machine type and it can't be guessed.
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
const KINDS = ["vending", "micromarket_static", "micromarket_tablet"];

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
    // Escape hatch for machines the SmartVend list doesn't carry (in-house test
    // rigs): there is no secret to look up, so it has to be supplied. Not
    // reachable from the admin UI — curl only, deliberately.
    const force = body.force === true;
    const forcedSecret = force ? String(body.secret ?? "").trim() : "";

    if (!machid || machid < 0) return json({ error: "bad_machid" }, 400);
    if (!KINDS.includes(kind)) return json({ error: "bad_kind" }, 400);
    if (force && !forcedSecret) return json({ error: "secret_required" }, 400);

    // ── resolve the machine (and its secret) from the SmartVend list ────────
    //
    // Go to the source rather than trusting the cache. Enrolment is rare and
    // human-triggered, so one upstream fetch is cheap — and it's the only thing
    // standing between a rotated secret and a machine enrolled with a key that
    // can't sign payments. That used to be caught by the operator typing the
    // current secret off the partner page (a mismatch forced a refresh); with
    // nothing typed, a stale cache would go unnoticed until the first customer.
    // The refresh also updates the cache device-provision reads.
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
      if (!upstream) return json({ error: "machine_not_found" }, 404);
    }

    const secret = force ? forcedSecret : String(upstream.secret ?? "").trim();
    // A cached row with an empty secret can't sign payments — treat it as if
    // the machine weren't there rather than enrolling a dud.
    if (!secret) return json({ error: "machine_not_found" }, 404);

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
