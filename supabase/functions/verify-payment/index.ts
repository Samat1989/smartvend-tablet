import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// static_qr payment verification. Reads the cart + amount from the server-side
// pending_orders row (never from the client), queries SmartVend payment_result
// with the server-held secret, and on success records the sale + decrements
// stock exactly once (claims the pending row atomically). No motor/door — these
// are open-shelf micromarkets, so a paid order just records the sale.
const RESULT_URL = "https://levending.smartvend.kz/payment_result";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

async function sign(appkey: string, randstr: string, timestamp: string) {
  const combined = [appkey, randstr, timestamp].sort().join("");
  const buf = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(combined));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function ok(body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { headers: { ...cors, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { marketId, orderid, torderid } = await req.json();
    const numericId = parseInt(marketId);
    if (!numericId || !orderid) throw new Error("marketId and orderid are required");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const { data: pending } = await supabase
      .from("pending_orders").select("*").eq("orderid", orderid).single();
    if (pending?.status === "completed") return ok({ status: "success" });

    const { data: market } = await supabase
      .from("micromarkets").select("secret").eq("id", numericId).single();
    if (!market) throw new Error("Market not found");
    const appkey = (market.secret || "").trim();

    const timestamp = new Date().toISOString().replace(/[-:T]/g, "").split(".")[0];
    const randstr = Math.random().toString(36).substring(2, 18).padEnd(16, "0");
    const s = await sign(appkey, randstr, timestamp);

    const form = new URLSearchParams();
    form.append("ver", "v1");
    form.append("orderid", orderid);
    form.append("torderid", torderid ?? pending?.torderid ?? "");
    form.append("machid", String(numericId));
    form.append("channelid", "36");
    form.append("randstr", randstr);
    form.append("timestamp", timestamp);
    form.append("sign", s);

    const resp = await fetch(RESULT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
    });
    const result = await resp.json();
    const code = parseInt(result.code);

    if (code === 1) {
      // Claim the pending order exactly once (idempotent across concurrent polls).
      const { data: claimed } = await supabase
        .from("pending_orders")
        .update({ status: "completed" })
        .eq("orderid", orderid).eq("status", "pending").select();
      if (!claimed || claimed.length === 0) return ok({ status: "success" });

      const po: any = claimed[0];
      const cart: any[] = Array.isArray(po.cart) ? po.cart : [];

      const { data: sale, error: saleErr } = await supabase.from("sales").insert({
        micromarket_id: numericId,
        amount: po.amount,
        status: "completed",
        payment_id: torderid ?? po.torderid,
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
          .eq("id", it.id).eq("micromarket_id", numericId);
      }
      return ok({ status: "success" });
    }

    return ok({ status: "waiting", code, msg: result.msg });
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 400, headers: { ...cors, "Content-Type": "application/json" },
    });
  }
});
