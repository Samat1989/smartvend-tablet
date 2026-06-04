import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// static_qr payment: the phone sends only machid + items (id + count). The
// secret stays server-side; the amount is recomputed from inventory (never
// trusted from the client). Initiates a SmartVend/Kaspi payment_request and
// records a pending order so verify-payment can finalize from server data.
const PAYMENT_URL = "https://levending.smartvend.kz/payment_request";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

async function sign(appkey: string, randstr: string, timestamp: string) {
  const combined = [appkey, randstr, timestamp].sort().join("");
  const buf = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(combined));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { marketId, items } = await req.json();
    const numericId = parseInt(marketId);
    if (!numericId || !Array.isArray(items) || items.length === 0) {
      throw new Error("marketId and items are required");
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const { data: market, error: mErr } = await supabase
      .from("micromarkets").select("secret").eq("id", numericId).single();
    if (mErr || !market) throw new Error(`Market ${numericId} not found`);
    const appkey = (market.secret || "").trim();

    // Authoritative price + stock from inventory (ignore any client prices).
    const ids = items.map((i: any) => i.id).filter(Boolean);
    const { data: invRows, error: invErr } = await supabase
      .from("inventory").select("id, name, price, stock").in("id", ids).eq("micromarket_id", numericId);
    if (invErr) throw new Error("inventory lookup failed");
    const byId = new Map((invRows ?? []).map((r: any) => [r.id, r]));

    let totalTenge = 0;
    const cart: any[] = [];
    const names: string[] = [];
    for (const it of items) {
      const row: any = byId.get(it.id);
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
    let result: any;
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
    } catch (e: any) {
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

    return new Response(
      JSON.stringify({ paymentUrl: result.twocode, orderid: result.orderid, torderid: result.torderid }),
      { headers: { ...cors, "Content-Type": "application/json" } },
    );
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 400, headers: { ...cors, "Content-Type": "application/json" },
    });
  }
});
