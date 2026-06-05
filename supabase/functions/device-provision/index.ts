// Device provisioning lookup. The ESP32 relay can't download the 1.85 MB /
// 14867-entry SmartVend machine list (no RAM for it), so it asks us by machid
// and we return just that one machine's MQTT identity:
//   { machid, uuid, secret, name }
// where uuid = MQTT username/client_id, secret = MQTT password, and the device
// builds its topic as vending/<uuid>/in. verify_jwt=false: the device sends the
// publishable key, not a JWT. Note: the upstream list is itself public (no
// auth), so this proxy doesn't expose anything not already exposed by SmartVend.
const PARTNER_URL =
  "https://partner.smartvend.kz/mb/public/question/8ef367bd-764e-4962-953b-e004df2b690d.json";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    // Accept machid from ?machid= (GET, simplest for the device) or JSON body.
    const url = new URL(req.url);
    let machidRaw = url.searchParams.get("machid");
    if (!machidRaw && req.method === "POST") {
      try { machidRaw = (await req.json())?.machid; } catch (_) { /* no body */ }
    }
    const machid = parseInt(machidRaw ?? "");
    if (!machid) return json({ error: "machid is required" }, 400);

    const resp = await fetch(PARTNER_URL);
    if (!resp.ok) return json({ error: `upstream ${resp.status}` }, 502);
    const list = await resp.json();
    if (!Array.isArray(list)) return json({ error: "unexpected upstream format" }, 502);

    const rec = list.find((r) => Number(r["Internal ID"]) === machid);
    if (!rec) return json({ error: `machine ${machid} not found` }, 404);

    return json({
      machid,
      uuid: rec["ID"],
      secret: String(rec["Secret"] ?? "").trim(),
      name: rec["Description"] ?? "",
    });
  } catch (error) {
    return json({ error: error.message }, 500);
  }
});
