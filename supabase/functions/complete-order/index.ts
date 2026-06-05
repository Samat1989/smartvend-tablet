import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Finalize a payment from the ESP32 relay. The device subscribes to the
// SmartVend MQTT topic and, on a "Processed order" (code 1) event, POSTs
// { orderid } here. We don't trust that blindly (public endpoint): we look up
// the server-side pending order, RE-VERIFY with SmartVend payment_result, then
// record the sale + decrement stock exactly once. This is the instant,
// push-based path — no polling, no auto-refund window to miss.
const RESULT_URL = "https://levending.smartvend.kz/payment_result";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

async function sign(appkey, randstr, timestamp) {
  const combined = [appkey, randstr, timestamp].sort().join("");
  const buf = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(combined));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function ok(body) {
  return new Response(JSON.stringify(body), { headers: { ...cors, "Content-Type": "application/json" } });
}

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
    if (!po) return ok({ status: "unknown" });           // no such order
    if (po.status === "completed") return ok({ status: "success" });

    const { data: market } = await supabase
      .from("micromarkets").select("secret").eq("id", po.micromarket_id).single();
    if (!market) throw new Error("Market not found");
    const appkey = (market.secret || "").trim();

    // Re-verify the payment with the gateway before recording anything. This is
    // also the capture call that prevents the SmartVend auto-refund.
    const timestamp = new Date().toISOString().replace(/[-:T]/g, "").split(".")[0];
    const randstr = Math.random().toString(36).substring(2, 18).padEnd(16, "0");
    const s = await sign(appkey, randstr, timestamp);
    const form = new URLSearchParams();
    form.append("ver", "v1");
    form.append("orderid", orderid);
    form.append("torderid", po.torderid ?? "");
    form.append("machid", String(po.micromarket_id));
    form.append("channelid", "36");
    form.append("randstr", randstr);
    form.append("timestamp", timestamp);
    form.append("sign", s);

    const resp = await fetch(RESULT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    const res = await resp.json();
    if (parseInt(res.code) !== 1) return ok({ status: "waiting", code: res.code, msg: res.msg });

    // Claim exactly once, then record the sale + decrement stock.
    const { data: claimed } = await supabase
      .from("pending_orders").update({ status: "completed" })
      .eq("orderid", orderid).eq("status", "pending").select();
    if (!claimed || claimed.length === 0) return ok({ status: "success" }); // finalized elsewhere

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
    return ok({ status: "success" });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 400, headers: { ...cors, "Content-Type": "application/json" },
    });
  }
});
