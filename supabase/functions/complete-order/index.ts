import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Finalize a payment from the ESP32 relay. The device subscribes to the
// SmartVend MQTT topic and, on a "Processed order" (code 1) event, POSTs
// { orderid } here. This is the SAFETY NET for when the customer never returns
// to the browser (so the browser's 4s payment_result polling never runs).
//
// We don't trust the POST blindly (public endpoint): we look up the
// server-side pending order and call SmartVend payment_result — which is the
// CAPTURE step (without it SmartVend auto-refunds within ~1 min). Because the
// MQTT event already proves the payment happened, a payment_result that doesn't
// yet return code 1 is almost certainly transient, so we retry a few times
// inside this one request. If we still can't capture, we return a non-2xx so
// the device's outer retry loop tries the whole thing again.
const RESULT_URL = "https://levending.smartvend.kz/payment_result";
const CAPTURE_ATTEMPTS = 4;       // attempts within a single request
const CAPTURE_GAP_MS = 3000;      // pause between attempts (~4x3s fits ESP32's 15s timeout)
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

async function sign(appkey, randstr, timestamp) {
  const combined = [appkey, randstr, timestamp].sort().join("");
  const buf = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(combined));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

// One payment_result call. Returns the parsed gateway response, or null on a
// network/parse error (caller treats that as "retry").
async function callPaymentResult(orderid, torderid, machid, appkey) {
  const timestamp = new Date().toISOString().replace(/[-:T]/g, "").split(".")[0];
  const randstr = Math.random().toString(36).substring(2, 18).padEnd(16, "0");
  const s = await sign(appkey, randstr, timestamp);
  const form = new URLSearchParams();
  form.append("ver", "v1");
  form.append("orderid", orderid);
  form.append("torderid", torderid ?? "");
  form.append("machid", String(machid));
  form.append("channelid", "36");
  form.append("randstr", randstr);
  form.append("timestamp", timestamp);
  form.append("sign", s);
  try {
    const resp = await fetch(RESULT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    return await resp.json();
  } catch (_) {
    return null; // transient — retry
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { orderid } = await req.json();
    if (!orderid) throw new Error("orderid is required");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const { data: po } = await supabase
      .from("pending_orders").select("*").eq("orderid", orderid).single();
    // No such order → 404, deliberately NOT 200.
    //
    // The board opens the door on any 2xx (handle_order_task in main.c), so a
    // 200 here meant "unknown order" unlocked the fridge for free. It was
    // reachable: the board dedupes only against its single last_order_id, so an
    // MQTT redelivery of an older order — one whose pending row had since been
    // cleaned up — sailed past that check and got its 200.
    //
    // A non-2xx leaves the door shut. The board retries three times and gives
    // up, which is the right end state for an order we have no record of.
    if (!po) return json({ status: "unknown" }, 404);
    if (po.status === "completed") return json({ status: "success" });

    const { data: market } = await supabase
      .from("micromarkets").select("secret").eq("id", po.micromarket_id).single();
    if (!market) throw new Error("Market not found");
    const appkey = (market.secret || "").trim();

    // Capture with retries. The MQTT event already confirmed payment, so keep
    // trying payment_result until it returns code 1 (or we run out of attempts).
    let lastCode, lastMsg;
    let captured = false;
    for (let attempt = 1; attempt <= CAPTURE_ATTEMPTS; attempt++) {
      const res = await callPaymentResult(orderid, po.torderid, po.micromarket_id, appkey);
      if (res) { lastCode = res.code; lastMsg = res.msg; }
      if (res && parseInt(res.code) === 1) { captured = true; break; }
      if (attempt < CAPTURE_ATTEMPTS) await sleep(CAPTURE_GAP_MS);
    }
    // Couldn't capture: return non-2xx so the device retries the whole request.
    if (!captured) return json({ status: "waiting", code: lastCode, msg: lastMsg }, 503);

    // Claim + sale + items + stock in one Postgres transaction.
    //
    // Today the board is the only caller, but create-payment's disabled
    // backstop (for markets with no relay) calls the same function, so if it
    // is ever switched back on the two can race for one order and exactly one
    // will record it.
    //
    // The claim used to happen here, in JS, before any of the writes. Money was
    // captured by then, so a failure in the lines that followed left the order
    // no longer `pending`: no sale, no stock change, and nothing that could
    // retry it. Now a failure commits nothing and 503 tells the caller to come
    // back — the order is still there to finish.
    const { data: fin, error: finErr } = await supabase
      .rpc("finalize_paid_order", { p_orderid: orderid });
    if (finErr) {
      console.error("finalize_paid_order failed", orderid, finErr.message);
      return json({ status: "waiting", error: finErr.message }, 503);
    }
    // Same reasoning as the 404 above — reachable only if the row vanished
    // between the read and the call, but the door must not open for an order
    // we did not record.
    if (fin?.status === "unknown") return json({ status: "unknown" }, 404);
    return json({ status: "success" });
  } catch (error) {
    return json({ error: error.message }, 400);
  }
});
