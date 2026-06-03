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
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    console.log("[Cron] Starting background payment check loop (50 seconds)...");
    
    const startTime = Date.now();
    const maxDuration = 50 * 1000;
    const allResults = [];

    while (Date.now() - startTime < maxDuration) {
      const tenMinutesAgo = new Date(Date.now() - 10 * 60 * 1000).toISOString();
      
      const { data: pendingOrders, error: fetchError } = await supabaseClient
        .from('pending_orders')
        .select('*')
        .eq('status', 'pending')
        .gt('created_at', tenMinutesAgo)
        .limit(10);

      if (fetchError) {
        console.error("[Cron] Error fetching pending orders:", fetchError);
        break;
      }

      if (pendingOrders && pendingOrders.length > 0) {
        for (const order of pendingOrders) {
          try {
            const { data: market } = await supabaseClient
              .from('micromarkets')
              .select('secret')
              .eq('id', order.market_id)
              .single();

            if (!market) continue;

            const appkey = market.secret.trim();
            const timestamp = new Date().toISOString().replace(/[-:T]/g, '').split('.')[0];
            const randstr = Math.random().toString(36).substring(2, 18).padEnd(16, '0');
            
            const parts = [appkey, randstr, timestamp];
            parts.sort(); 
            const signatureInput = parts.join("");
            
            const msgUint8 = new TextEncoder().encode(signatureInput);
            const hashBuffer = await crypto.subtle.digest("SHA-1", msgUint8);
            const sign = Array.from(new Uint8Array(hashBuffer)).map((b) => b.toString(16).padStart(2, "0")).join("");

            const formData = new URLSearchParams();
            formData.append("ver", "v1");
            formData.append("orderid", order.orderid);
            formData.append("torderid", order.torderid || "");
            formData.append("machid", order.market_id.toString());
            formData.append("channelid", "36");
            formData.append("randstr", randstr);
            formData.append("timestamp", timestamp);
            formData.append("sign", sign);

            const response = await fetch(RESULT_URL, {
              method: "POST",
              headers: { "Content-Type": "application/x-www-form-urlencoded" },
              body: formData.toString(),
            });

            const result = await response.json();
            const code = parseInt(result.code);

            if (code === 1) {
              console.log(`[Cron] Order ${order.orderid} SUCCESS. Finalizing.`);
              const cartItems = order.cart_data;
              const amount = Object.values(cartItems).reduce((sum: number, item: any) => sum + (item.price * item.count), 0);

              const { data: saleData } = await supabaseClient
                .from('sales')
                .insert({ 
                  micromarket_id: order.market_id,
                  amount: amount,
                  status: 'completed',
                  payment_id: order.torderid
                })
                .select()
                .single();

              if (saleData) {
                for (const item of Object.values(cartItems) as any[]) {
                  await supabaseClient.from('sales_items').insert({
                    sale_id: saleData.id,
                    product_id: item.id,
                    price: item.price,
                    quantity: item.count
                  });
                  await supabaseClient.rpc('decrement_stock', { product_id: item.id, qty: item.count });
                }

                await supabaseClient.from('commands').insert({
                  micromarket_id: order.market_id,
                  command_type: 'open',
                  status: 'pending'
                });

                await supabaseClient.from('pending_orders').update({ status: 'completed' }).eq('orderid', order.orderid);
                allResults.push({ orderid: order.orderid, status: 'finalized' });
              }
            } else if (code === 3 || code === 4) {
              console.log(`[Cron] Order ${order.orderid} expired or cancelled. Marking in DB.`);
              await supabaseClient.from('pending_orders').update({ status: 'expired' }).eq('orderid', order.orderid);
              allResults.push({ orderid: order.orderid, status: 'expired', code });
            }
          } catch (err: any) {
            console.error(`[Cron] Error processing order ${order.orderid}:`, err.message);
          }
        }
      }

      await new Promise(resolve => setTimeout(resolve, 10000));
    }

    return new Response(JSON.stringify({ status: 'done', loops_finished: true, allResults }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    });

  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
})
