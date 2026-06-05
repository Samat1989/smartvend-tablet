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
    if (!po) return json({ status: "unknown" });            // no such order
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

    // Claim exactly once, then record the sale + decrement stock.
    const { data: claimed } = await supabase
      .from("pending_orders").update({ status: "completed" })
      .eq("orderid", orderid).eq("status", "pending").select();
    if (!claimed || claimed.length === 0) return json({ status: "success" }); // finalized elsewhere

    const cart = Array.isArray(claimed[0].cart) ? claimed[0].cart : [];
    const { data: sale, error: saleErr } = await supabase.from("sales").insert({
      micromarket_id: po.micromarket_id,
      amount: claimed[0].amount,
      status: "completed",
      payment_id: claimed[0].torderid,
    }).select().single();
    if (saleErr) throw saleErr;

    for (const it of cart) {
      await supabase.from("sales_items").insert({
        sale_id: sale.id, product_id: it.id, price: it.price, quantity: it.count,
      });
      const { data: inv } = await supabase
        .from("inventory").select("stock").eq("id", it.id).single();
      const newStock = Math.max(0, (inv?.stock ?? 0) - (it.count ?? 1));
      await supabase.from("inventory").update({ stock: newStock })
        .eq("id", it.id).eq("micromarket_id", po.micromarket_id);
    }
    return json({ status: "success" });
  } catch (error) {
    return json({ error: error.message }, 400);
  }
});
