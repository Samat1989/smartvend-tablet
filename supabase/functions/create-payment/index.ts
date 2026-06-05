import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// static_qr payment: the phone sends only machid + items (id + count). The
// secret stays server-side; the amount is recomputed from inventory. Initiates
// a SmartVend/Kaspi payment_request, records a pending order, returns the Kaspi
// link, and then KEEPS POLLING payment_result server-side in the background
// (EdgeRuntime.waitUntil) — SmartVend auto-refunds if payment_result isn't
// polled within ~1 min, and the customer's browser is asleep while they pay in
// the Kaspi app, so the server must keep the confirmation window open itself.
const PAYMENT_URL = "https://levending.smartvend.kz/payment_request";
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

// Poll payment_result once; if paid (code 1) claim the pending order and record
// the sale + stock exactly once. Returns true when the order is settled (paid
// and recorded, or already completed by another poller) so the caller can stop.
async function finalizeIfPaid(supabase, orderid, machid, appkey) {
  const { data: po } = await supabase
    .from("pending_orders").select("*").eq("orderid", orderid).single();
  if (!po) return true;                 // gone — stop
  if (po.status === "completed") return true;

  const timestamp = new Date().toISOString().replace(/[-:T]/g, "").split(".")[0];
  const randstr = Math.random().toString(36).substring(2, 18).padEnd(16, "0");
  const s = await sign(appkey, randstr, timestamp);
  const form = new URLSearchParams();
  form.append("ver", "v1");
  form.append("orderid", orderid);
  form.append("torderid", po.torderid ?? "");
  form.append("machid", String(machid));
  form.append("channelid", "36");
  form.append("randstr", randstr);
  form.append("timestamp", timestamp);
  form.append("sign", s);

  let res;
  try {
    const r = await fetch(RESULT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    res = await r.json();
  } catch (_) {
    return false; // transient — keep polling
  }
  if (parseInt(res.code) !== 1) return false;

  const { data: claimed } = await supabase
    .from("pending_orders").update({ status: "completed" })
    .eq("orderid", orderid).eq("status", "pending").select();
  if (!claimed || claimed.length === 0) return true; // finalized elsewhere

  const cart = Array.isArray(claimed[0].cart) ? claimed[0].cart : [];
  const { data: sale, error: saleErr } = await supabase.from("sales").insert({
    micromarket_id: machid, amount: claimed[0].amount, status: "completed",
    payment_id: claimed[0].torderid,
  }).select().single();
  if (saleErr) return true;
  for (const it of cart) {
    await supabase.from("sales_items").insert({
      sale_id: sale.id, product_id: it.id, price: it.price, quantity: it.count,
    });
    const { data: inv } = await supabase
      .from("inventory").select("stock").eq("id", it.id).single();
    const newStock = Math.max(0, (inv?.stock ?? 0) - (it.count ?? 1));
    await supabase.from("inventory").update({ stock: newStock })
      .eq("id", it.id).eq("micromarket_id", machid);
  }
  return true;
}

// Keep the payment_result window open right after the QR is shown: poll every
// 10s for ~90s (covers scan -> Kaspi app -> pay), independent of the browser.
async function backgroundPoll(supabase, orderid, machid, appkey) {
  const deadline = Date.now() + 60_000; // poll for ~1 minute
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 12_000)); // every 12s
    try {
      if (await finalizeIfPaid(supabase, orderid, machid, appkey)) return;
    } catch (_) { /* keep going */ }
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { token, marketId, items } = await req.json();
    if (!Array.isArray(items) || items.length === 0) {
      throw new Error("items are required");
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    // Resolve the machine by its unguessable qr_token (preferred — keeps the
    // machid out of the browser) or by legacy marketId. The secret stays here.
    let market, mErr;
    if (token) {
      ({ data: market, error: mErr } = await supabase
        .from("micromarkets").select("id, secret").eq("qr_token", token).single());
    } else {
      ({ data: market, error: mErr } = await supabase
        .from("micromarkets").select("id, secret").eq("id", parseInt(marketId)).single());
    }
    if (mErr || !market) throw new Error("Market not found");
    const numericId = market.id;
    const appkey = (market.secret || "").trim();

    const ids = items.map((i) => i.id).filter(Boolean);
    const { data: invRows, error: invErr } = await supabase
      .from("inventory").select("id, name, price, stock").in("id", ids).eq("micromarket_id", numericId);
    if (invErr) throw new Error("inventory lookup failed");
    const byId = new Map((invRows ?? []).map((r) => [r.id, r]));

    let totalTenge = 0;
    const cart = [];
    const names = [];
    for (const it of items) {
      const row = byId.get(it.id);
      if (!row) throw new Error("Товар недоступен в этом аппарате");
      const qty = Math.max(1, parseInt(it.count) || 1);
      if ((row.stock ?? 0) < qty) throw new Error(`Недостаточно товара: ${row.name}`);
      totalTenge += Number(row.price) * qty;
      cart.push({ id: row.id, price: Number(row.price), count: qty });
      names.push(row.name);
    }
    if (totalTenge <= 0) throw new Error("Empty order");
    const totalCents = Math.round(totalTenge * 100);
    const orderName = names.join(", ").substring(0, 50) || "Micromart";

    const timestamp = new Date().toISOString().replace(/[-:T]/g, "").split(".")[0].substring(0, 14);
    const randstr = Math.random().toString(36).substring(2, 18).padEnd(16, "0");
    const s = await sign(appkey, randstr, timestamp);
    const orderid = `${numericId}${timestamp}${randstr.substring(0, 6)}`.substring(0, 59);

    const form = new URLSearchParams();
    form.append("ver", "v1");
    form.append("orderid", orderid);
    form.append("machid", String(numericId));
    form.append("trackno", "01");
    form.append("name", orderName);
    form.append("price", String(totalCents));
    form.append("channelid", "36");
    form.append("randstr", randstr);
    form.append("timestamp", timestamp);
    form.append("sign", s);

    const controller = new AbortController();
    const tid = setTimeout(() => controller.abort(), 12000);
    let result;
    try {
      const resp = await fetch(PAYMENT_URL, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: form.toString(),
        signal: controller.signal,
      });
      clearTimeout(tid);
      const text = await resp.text();
      try { result = JSON.parse(text); }
      catch { throw new Error(`Bad gateway response: ${text.substring(0, 60)}`); }
    } catch (e) {
      clearTimeout(tid);
      if (e.name === "AbortError") throw new Error("Payment gateway timeout");
      throw e;
    }

    if (Number(result.code) !== 1) {
      throw new Error(`SmartVend: ${result.msg || "error"} (code ${result.code})`);
    }

    await supabase.from("pending_orders").upsert({
      orderid: result.orderid,
      torderid: result.torderid,
      micromarket_id: numericId,
      amount: totalTenge,
      cart,
      status: "pending",
    }, { onConflict: "orderid" });

    const response = new Response(
      JSON.stringify({ paymentUrl: result.twocode, orderid: result.orderid, torderid: result.torderid }),
      { headers: { ...cors, "Content-Type": "application/json" } },
    );

    // TEMPORARILY DISABLED to test the ESP32-relay finalization path in
    // isolation (the relay POSTs {orderid} to complete-order on MQTT payment).
    // Re-enable to restore the server-side confirmation backstop for web-only
    // markets without a relay.
    // try {
    //   globalThis.EdgeRuntime?.waitUntil(
    //     backgroundPoll(supabase, result.orderid, numericId, appkey),
    //   );
    // } catch (_) { /* waitUntil unavailable */ }

    return response;
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 400, headers: { ...cors, "Content-Type": "application/json" },
    });
  }
});
