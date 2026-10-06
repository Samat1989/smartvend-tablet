import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { DeviceChannel } from "../_shared/device_channel.ts";

// Is the machine behind this storefront reachable right now?
//
//   POST { token } -> 200 { online, lock_ok?, legacy? }
//
// The storefront asks before showing the cart, so a customer never builds an
// order for a fridge that cannot open. Only boards on the Realtime firmware
// (row in device_rt) can answer a ping; MQTT-era boards have no way to, so
// they report online with legacy:true — exactly the behaviour they had before.
//
// create-payment pings again before issuing the QR; this endpoint is a
// courtesy for the UI, not the safety check.

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  try {
    const { token } = await req.json().catch(() => ({}));
    if (!token) return json({ error: "token is required" }, 400);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const { data: market } = await supabase
      .from("micromarkets").select("id").eq("qr_token", token).maybeSingle();
    if (!market) return json({ error: "Market not found" }, 404);

    const { data: rt } = await supabase
      .from("device_rt").select("topic, device_id").eq("machid", market.id).maybeSingle();
    if (!rt) return json({ online: true, legacy: true });

    let ch: DeviceChannel | null = null;
    try {
      ch = await DeviceChannel.open(supabase, rt.topic, rt.device_id ?? "");
      const pong = await ch.ping(3000);
      if (!pong) return json({ online: false });
      return json({
        online: true,
        lock_ok: pong.lock_ok !== false,
        net: pong.net,
        rssi_dbm: pong.rssi_dbm,
      });
    } catch (_) {
      return json({ online: false });
    } finally {
      await ch?.close();
    }
  } catch (error) {
    return json({ error: (error as Error).message }, 400);
  }
});
