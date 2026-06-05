import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Device provisioning lookup. The ESP32 relay can't download the 1.85 MB /
// 14867-entry SmartVend machine list (no RAM), so it asks us by machid and we
// return just that machine's MQTT identity: { machid, uuid, secret, name }
// (uuid = MQTT username/client_id & topic, secret = MQTT password).
//
// We cache the list in public.smartvend_machines and only refetch the upstream
// file on a CACHE MISS (a machid we don't have yet). So the heavy download
// happens once (or when a genuinely new machine shows up), not every call.
// verify_jwt=false: the device sends the publishable key, not a JWT. The cache
// table is backend-only (service_role); the upstream list is itself public.
const PARTNER_URL =
  "https://partner.smartvend.kz/mb/public/question/8ef367bd-764e-4962-953b-e004df2b690d.json";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

// Fetch the upstream list and (re)populate the cache. Returns the row for the
// requested machid if present, else null.
async function refreshCache(supabase, wantMachid) {
  const resp = await fetch(PARTNER_URL);
  if (!resp.ok) throw new Error(`upstream ${resp.status}`);
  const list = await resp.json();
  if (!Array.isArray(list)) throw new Error("unexpected upstream format");

  // Dedupe by machid (upsert can't touch the same key twice in one batch).
  const byId = new Map();
  for (const r of list) {
    const machid = Number(r["Internal ID"]);
    const uuid = r["ID"];
    const secret = String(r["Secret"] ?? "").trim();
    if (!machid || !uuid || !secret) continue;
    byId.set(machid, { machid, uuid, secret, name: r["Description"] ?? "" });
  }
  const rows = [...byId.values()];

  // Chunked upsert (14k+ rows) — keep each request a reasonable size.
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
  try {
    const url = new URL(req.url);
    let machidRaw = url.searchParams.get("machid");
    if (!machidRaw && req.method === "POST") {
      try { machidRaw = (await req.json())?.machid; } catch (_) { /* no body */ }
    }
    const machid = parseInt(machidRaw ?? "");
    if (!machid) return json({ error: "machid is required" }, 400);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    // 1) Cache hit → return immediately, no upstream fetch.
    const { data: cached } = await supabase
      .from("smartvend_machines").select("uuid, secret, name").eq("machid", machid).single();
    if (cached) {
      return json({ machid, uuid: cached.uuid, secret: cached.secret, name: cached.name, cached: true });
    }

    // 2) Miss → refresh the whole cache from upstream, then serve.
    const rec = await refreshCache(supabase, machid);
    if (!rec) return json({ error: `machine ${machid} not found` }, 404);
    return json({ machid, uuid: rec.uuid, secret: rec.secret, name: rec.name, cached: false });
  } catch (error) {
    return json({ error: error.message }, 500);
  }
});
