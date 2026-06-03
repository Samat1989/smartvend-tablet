import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const RESULT_URL = "https://levending.smartvend.kz/payment_result"

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { marketId, orderid, torderid, cartItems } = await req.json()
    console.log(`[VerifyPayment] Checking status for Order: ${orderid}, Market: ${marketId}`);

    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    // --- NEW: Check if ESP32 already finalized this order ---
    const { data: pendingOrder } = await supabaseClient
      .from('pending_orders')
      .select('status')
      .eq('orderid', orderid)
      .single();
    
    if (pendingOrder?.status === 'completed') {
      console.log(`[VerifyPayment] Order ${orderid} already finalized by ESP32. Returning success.`);
      return new Response(JSON.stringify({ status: 'success' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    const { data: market } = await supabaseClient
      .from('micromarkets')
      .select('secret')
      .eq('id', marketId)
      .single()

    if (!market) throw new Error("Market secret not found");

    const appkey = market.secret.trim()
    const timestamp = new Date().toISOString().replace(/[-:T]/g, '').split('.')[0]
    const randstr = Math.random().toString(36).substring(2, 18).padEnd(16, '0')
    
    // Принудительная алфавитная сортировка
    const parts = [appkey, randstr, timestamp];
    parts.sort();
    const signatureInput = parts.join("");
    
    console.log(`[Debug] Signature Input: ${signatureInput}`);
    
    const msgUint8 = new TextEncoder().encode(signatureInput)
    const hashBuffer = await crypto.subtle.digest("SHA-1", msgUint8)
    const hashArray = Array.from(new Uint8Array(hashBuffer))
    const sign = hashArray.map((b) => b.toString(16).padStart(2, "0")).join("")

    const formData = new URLSearchParams()
    formData.append("ver", "v1")
    formData.append("orderid", orderid)
    formData.append("torderid", torderid)
    formData.append("machid", marketId)
    formData.append("channelid", "36")
    formData.append("randstr", randstr)
    formData.append("timestamp", timestamp)
    formData.append("sign", sign)

    const response = await fetch(RESULT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: formData.toString(),
    })

    const result = await response.json()
    console.log(`[VerifyPayment] SmartVend Response: Code ${result.code}, Msg: ${result.msg}`);

    const code = parseInt(result.code);

    if (code === 1) {
      console.log("[VerifyPayment] Success! Triggering door and saving sale.");
      const amount = Object.values(cartItems).reduce((sum: number, item: any) => sum + (item.price * item.count), 0);

      const { data: saleData, error: saleError } = await supabaseClient
        .from('sales')
        .insert({ 
          micromarket_id: marketId,
          amount: amount,
          status: 'completed',
          payment_id: torderid
        })
        .select()
        .single();

      if (saleError) console.error("[VerifyPayment] Sale insert error:", saleError);

      for (const item of Object.values(cartItems) as any[]) {
        await supabaseClient.from('sales_items').insert({
          sale_id: saleData.id,
          product_id: item.id,
          price: item.price,
          quantity: item.count
        });

        await supabaseClient.rpc('decrement_stock', { 
          product_id: item.id, 
          qty: item.count 
        });
      }

      await supabaseClient.from('commands').insert({
        micromarket_id: marketId,
        command_type: 'open',
        status: 'pending'
      });

      // --- NEW: Mark pending order as completed so Cron ignores it ---
      await supabaseClient
        .from('pending_orders')
        .update({ status: 'completed' })
        .eq('orderid', orderid);

      return new Response(JSON.stringify({ status: 'success' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      });
    }

    return new Response(JSON.stringify({ status: 'waiting', code: code, msg: result.msg }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });

  } catch (error) {
    console.error("[VerifyPayment] Error:", error.message);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
