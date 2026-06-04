import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Server-side payment reconciliation. Runs on a schedule (pg_cron) and finalizes
// paid pending orders WITHOUT depending on the customer's browser — so a buyer
// who pays in Kaspi and never returns to the tab still gets their order closed
// (and SmartVend doesn't auto-refund an unconfirmed payment). Idempotent: each
// order is claimed exactly once.
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    // Only recent, still-pending orders (older ones are abandoned/expired).
    const cutoff = new Date(Date.now() - 20 * 60 * 1000).toISOString();
    const { data: pendings } = await supabase
      .from("pending_orders")
      .select("*")
      .eq("status", "pending")
      .gte("created_at", cutoff)
      .limit(50);

    let processed = 0;
    let finalized = 0;

    for (const po of pendings ?? []) {
      processed++;
      const { data: market } = await supabase
        .from("micromarkets").select("secret").eq("id", po.micromarket_id).single();
      if (!market) continue;
      const appkey = (market.secret || "").trim();

      const timestamp = new Date().toISOString().replace(/[-:T]/g, "").split(".")[0];
      const randstr = Math.random().toString(36).substring(2, 18).padEnd(16, "0");
      const s = await sign(appkey, randstr, timestamp);

      const form = new URLSearchParams();
      form.append("ver", "v1");
      form.append("orderid", po.orderid);
      form.append("torderid", po.torderid ?? "");
      form.append("machid", String(po.micromarket_id));
      form.append("channelid", "36");
      form.append("randstr", randstr);
      form.append("timestamp", timestamp);
      form.append("sign", s);

      let result;
      try {
        const resp = await fetch(RESULT_URL, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: form.toString(),
        });
        result = await resp.json();
      } catch (_) {
        continue; // gateway hiccup — try again next tick
      }
      if (parseInt(result.code) !== 1) continue;

      // Claim exactly once.
      const { data: claimed } = await supabase
        .from("pending_orders").update({ status: "completed" })
        .eq("orderid", po.orderid).eq("status", "pending").select();
      if (!claimed || claimed.length === 0) continue;

      const cart = Array.isArray(po.cart) ? po.cart : [];
      const { data: sale, error: saleErr } = await supabase.from("sales").insert({
        micromarket_id: po.micromarket_id,
        amount: po.amount,
        status: "completed",
        payment_id: po.torderid,
      }).select().single();
      if (saleErr) continue;

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
      finalized++;
    }

    return new Response(JSON.stringify({ processed, finalized }), {
      headers: { ...cors, "Content-Type": "application/json" },
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 400, headers: { ...cors, "Content-Type": "application/json" },
    });
  }
});
