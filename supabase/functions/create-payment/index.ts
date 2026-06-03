import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const PAYMENT_URL = "https://levending.smartvend.kz/payment_request"

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { marketId, items } = await req.json()
    console.log(`[CreatePayment] Market: ${marketId}, Items: ${items?.length}`);

    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    // Принудительно ищем по числу, так как в базе int8
    const numericId = parseInt(marketId);
    const { data: market, error: marketError } = await supabaseClient
      .from('micromarkets')
      .select('secret')
      .eq('id', numericId)
      .single()

    if (marketError || !market) {
      throw new Error(`Market ${numericId} not found in DB`);
    }

    const appkey = market.secret
    const totalCents = items.length > 0 
      ? items.reduce((sum: number, item: any) => sum + (item.price * item.count * 100), 0)
      : 100; // Минимум 1 тенге для теста если корзина пуста

    const orderName = items.length > 0 
      ? items.map((i: any) => i.name).join(", ").substring(0, 50)
      : "Test Order";

    // Точный формат даты как в успешном тесте
    const timestamp = new Date().toISOString().replace(/[-:T]/g, '').split('.')[0].substring(0, 14);
    const randstr = Math.random().toString(36).substring(2, 18).padEnd(16, '0')
    const combined = [appkey, randstr, timestamp].sort().join("")
    
    const msgUint8 = new TextEncoder().encode(combined)
    const hashBuffer = await crypto.subtle.digest("SHA-1", msgUint8)
    const hashArray = Array.from(new Uint8Array(hashBuffer))
    const sign = hashArray.map((b) => b.toString(16).padStart(2, "0")).join("")

    const orderid = `${numericId}${timestamp}${randstr.substring(0, 6)}`.substring(0, 59)

    const formData = new URLSearchParams()
    formData.append("ver", "v1")
    formData.append("orderid", orderid)
    formData.append("machid", numericId.toString())
    formData.append("trackno", "01")
    formData.append("name", orderName)
    formData.append("price", totalCents.toString())
    formData.append("channelid", "36") 
    formData.append("randstr", randstr)
    formData.append("timestamp", timestamp)
    formData.append("sign", sign)

    console.log(`[CreatePayment] Requesting SmartVend: Order: ${orderid}, Tot: ${totalCents}c`);

    // Add Timeout to Fetch
    const controller = new AbortController()
    const timeoutId = setTimeout(() => controller.abort(), 12000)

    try {
      const response = await fetch(PAYMENT_URL, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: formData.toString(),
        signal: controller.signal
      })

      clearTimeout(timeoutId)
      const text = await response.text();
      console.log(`[CreatePayment] SmartVend Raw Res: ${text.substring(0, 300)}`);
      
      let result;
      try {
        result = JSON.parse(text);
      } catch (pe) {
        throw new Error(`Invalid JSON from Pay Gateway: ${text.substring(0, 50)}`);
      }

      if (result.code != 1) {
        throw new Error(`SmartVend Error: ${result.msg || 'Unknown'} (Code: ${result.code})`);
      }

      // --- NEW: Save pending order to DB ---
      const { error: dbError } = await supabaseClient
        .from('pending_orders')
        .insert({
          orderid: result.orderid,
          torderid: result.torderid,
          market_id: numericId,
          cart_data: items
        });
      
      if (dbError) console.error(`[CreatePayment] DB Save Error: ${dbError.message}`);

      return new Response(
        JSON.stringify({
          paymentUrl: result.twocode,
          orderid: result.orderid,
          torderid: result.torderid
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    } catch (fetchErr: any) {
      clearTimeout(timeoutId)
      if (fetchErr.name === 'AbortError') {
         throw new Error("Payment Gateway Timeout (12s limit reached). Try again later.");
      }
      throw fetchErr;
    }

  } catch (error: any) {
    console.error(`[CreatePayment] Fatal Catch: ${error.message}`);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
