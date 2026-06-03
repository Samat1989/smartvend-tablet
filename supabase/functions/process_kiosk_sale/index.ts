import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
      }
    })
  }

  try {
    const { machid, secret, sales } = await req.json()

    if (!machid || !secret || !sales || !Array.isArray(sales)) {
      throw new Error("Invalid request payload: machid, secret, and sales[] are required")
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    const supabase = createClient(supabaseUrl, supabaseServiceKey)

    // 1. Верифицируем аппарат: ищем micromarket по machine_number + api_secret
    const cleanSecret = String(secret).trim()
    const { data: market, error: marketError } = await supabase
      .from('micromarkets')
      .select('id')
      .eq('id', machid)
      .eq('secret', cleanSecret)
      .single()

    if (marketError || !market) {
      console.error("Auth failed:", marketError?.message, "machid:", machid)
      return new Response(
        JSON.stringify({ error: "Unauthorized: Invalid machine number or secret" }),
        { status: 401, headers: { "Content-Type": "application/json" } }
      )
    }

    const micromarketUuid = market.id
    console.log("Verified micromarket ID:", micromarketUuid, "for machine:", machid)

    // 2. Считаем общую сумму чека
    const totalAmount = sales.reduce((sum, item) => sum + (item.amount || 0), 0)

    // 3. Создаем запись в таблице sales (основной чек)
    const { data: saleData, error: saleError } = await supabase
      .from('sales')
      .insert({
        micromarket_id: micromarketUuid,
        amount: totalAmount,
        status: 'completed',
        payment_id: 'internal_kiosk' // или передавать из терминала
      })
      .select('id')
      .single()

    if (saleError || !saleData) {
      throw new Error(`Failed to create sale: ${saleError?.message}`)
    }

    const saleId = saleData.id

    // 4. Обрабатываем каждую позицию
    for (const item of sales) {
      // 4.1 Добавляем в sales_items
      const { error: itemError } = await supabase
        .from('sales_items')
        .insert({
          sale_id: saleId,
          product_id: item.product_id,
          price: item.amount / item.qty, // цена за 1 шт
          quantity: item.qty
        })

      if (itemError) {
        console.error(`Failed to insert item ${item.product_id}:`, itemError.message)
        // Продолжаем, чтобы попробовать списать остаток и обработать другие товары
      }

      // 4.2 Списываем остаток из inventory
      const { data: currentInv, error: invReadError } = await supabase
        .from('inventory')
        .select('stock')
        .eq('id', item.product_id)
        .eq('micromarket_id', micromarketUuid)
        .single()

      if (!invReadError && currentInv) {
        const newStock = Math.max(0, currentInv.stock - item.qty)
        await supabase
          .from('inventory')
          .update({ stock: newStock })
          .eq('id', item.product_id)
          .eq('micromarket_id', micromarketUuid)
          
        console.log(`Stock updated for ${item.product_id}: ${currentInv.stock} -> ${newStock}`)
      } else {
        console.error(`Failed to update stock for ${item.product_id}:`, invReadError?.message)
      }
    }

    return new Response(
      JSON.stringify({ 
        success: true, 
        sale_id: saleId,
        message: `Successfully processed ${sales.length} items for machine ${machid}` 
      }),
      { headers: { "Content-Type": "application/json" } },
    )

  } catch (error) {
    console.error("Edge function error:", error.message)
    return new Response(JSON.stringify({ error: error.message }), {
      status: 400,
      headers: { "Content-Type": "application/json" }
    })
  }
})
