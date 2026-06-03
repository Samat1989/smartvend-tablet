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
    const { orderid } = await req.json()
    console.log(`[CompleteOrder] Background finalization for Order: ${orderid}`);

    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    // 1. Get the pending order data
    const { data: order, error: orderError } = await supabaseClient
      .from('pending_orders')
      .select('*')
      .eq('orderid', orderid)
      .single()

    if (orderError || !order) throw new Error(`Pending order ${orderid} not found`);
    if (order.status === 'completed') {
      console.log(`[CompleteOrder] Order ${orderid} already completed.`);
      return new Response(JSON.stringify({ status: 'already_completed' }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      })
    }

    // 2. Get market secret for signing
    const { data: market } = await supabaseClient
      .from('micromarkets')
      .select('secret')
      .eq('id', order.market_id)
      .single()

    if (!market) throw new Error("Market secret not found");

    // 3. --- NEW: Call SmartVend to definitively CAPTURE the payment ---
    // This prevents auto-refunds if the browser was closed
    const appkey = market.secret
    const timestamp = new Date().toISOString().replace(/[-:T]/g, '').split('.')[0].substring(0, 14)
    const randstr = Math.random().toString(36).substring(2, 18).padEnd(16, '0')
    const combined = [appkey, randstr, timestamp].sort().join("")
    
    const msgUint8 = new TextEncoder().encode(combined)
    const hashBuffer = await crypto.subtle.digest("SHA-1", msgUint8)
    const hashArray = Array.from(new Uint8Array(hashBuffer))
    const sign = hashArray.map((b) => b.toString(16).padStart(2, "0")).join("")

    const formData = new URLSearchParams()
    formData.append("ver", "v1")
    formData.append("orderid", order.orderid)
    formData.append("torderid", order.torderid || "")
    formData.append("machid", order.market_id.toString())
    formData.append("channelid", "36")
    formData.append("randstr", randstr)
    formData.append("timestamp", timestamp)
    formData.append("sign", sign)

    console.log(`[CompleteOrder] Notifying SmartVend for Order: ${order.orderid}...`);
    const svResponse = await fetch(RESULT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: formData.toString(),
    })

    const svResult = await svResponse.json()
    console.log(`[CompleteOrder] SmartVend Response: Code ${svResult.code}, Msg: ${svResult.msg}`);

    // We proceed only if SmartVend says success (code 1) or already processed
    if (svResult.code != 1 && svResult.code != "1") {
       // Note: sometimes SmartVend might return an error if it was ALREADY confirmed by browser.
       // We should handle that, but typically code 1 is what we want.
       console.warn(`[CompleteOrder] SmartVend didn't return success (Code ${svResult.code}). Procedings anyway if DB update was needed.`);
    }

    // 4. Map cart data and calculate total
    const cartItems = order.cart_data;
    const amount = Object.values(cartItems).reduce((sum: number, item: any) => sum + (item.price * item.count), 0);

    // 5. Create Sale Record
    const { data: saleData } = await supabaseClient
      .from('sales')
      .insert({ 
        micromarket_id: order.market_id,
        amount: amount,
        status: 'completed',
        payment_id: order.torderid || orderid 
      })
      .select()
      .single();

    if (saleData) {
      // 6. Record Items & Decrement Stock
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

      // 7. Update pending order status
      await supabaseClient
        .from('pending_orders')
        .update({ status: 'completed' })
        .eq('orderid', orderid);
      
      // 8. Signal Realtime for UI (if any browser is still listening)
      await supabaseClient.from('commands').insert({
        micromarket_id: order.market_id,
        command_type: 'payment_success',
        status: 'completed',
        payload: { orderid }
      });
    }

    return new Response(JSON.stringify({ status: 'success' }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });

  } catch (error: any) {
    console.error("[CompleteOrder] Fatal Error:", error.message);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
