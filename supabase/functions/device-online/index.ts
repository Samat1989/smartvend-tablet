import { createClient } from "https://esm.sh/@supabase/supabase-js@2.118.0";
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
// courtesy for the UI, not the safety check. That is why a few seconds of
// staleness is fine, and why the answer is cached.
//
// The qr_token sits in the public storefront link, and every uncached call
// opens a Realtime channel and pings the board (whose queue holds 6 messages:
// a flood would crowd out a real `open`). So: one probe per token per
// CACHE_MS, concurrent callers share it, and each IP gets RATE_MAX calls a
// minute. Both limits live in the isolate's memory — best effort across
// isolates, which is plenty against a casual flood.

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

const CACHE_MS = 8_000;
const RATE_MAX = 30;
const RATE_WINDOW_MS = 60_000;

type Answer = { status: number; body: Record<string, unknown> };
const cache = new Map<string, { at: number; answer: Answer }>();
const inflight = new Map<string, Promise<Answer>>();
const hits = new Map<string, { since: number; n: number }>();

function rateLimited(ip: string): boolean {
  const now = Date.now();
  if (hits.size > 5000) {
    for (const [k, v] of hits) if (now - v.since > RATE_WINDOW_MS) hits.delete(k);
  }
  const h = hits.get(ip);
  if (!h || now - h.since > RATE_WINDOW_MS) { hits.set(ip, { since: now, n: 1 }); return false; }
  return ++h.n > RATE_MAX;
}

async function probe(token: string): Promise<Answer> {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  );

  const { data: market } = await supabase
    .from("micromarkets").select("id").eq("qr_token", token).maybeSingle();
  if (!market) return { status: 404, body: { error: "Market not found" } };

  const { data: rt } = await supabase
    .from("device_rt").select("topic, device_id").eq("machid", market.id).maybeSingle();
  if (!rt) return { status: 200, body: { online: true, legacy: true } };

  let ch: DeviceChannel | null = null;
  try {
    ch = await DeviceChannel.open(supabase, rt.topic, rt.device_id ?? "");
    const pong = await ch.ping(3000);
    if (!pong) {
      console.warn(`device-online machid=${market.id}: joined dev:${rt.topic}, present=${ch.present()}, no pong in 3s`);
      return { status: 200, body: { online: false } };
    }
    return {
      status: 200,
      body: { online: true, lock_ok: pong.lock_ok !== false, net: pong.net, rssi_dbm: pong.rssi_dbm },
    };
  } catch (e) {
    console.error(`device-online machid=${market.id}: ${(e as Error).message}`);
    return { status: 200, body: { online: false } };
  } finally {
    await ch?.close();
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  try {
    const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "?";
    if (rateLimited(ip)) return json({ error: "too many requests" }, 429);

    const { token } = await req.json().catch(() => ({}));
    if (!token || typeof token !== "string") return json({ error: "token is required" }, 400);

    const hit = cache.get(token);
    if (hit && Date.now() - hit.at < CACHE_MS) return json(hit.answer.body, hit.answer.status);

    let run = inflight.get(token);
    if (!run) {
      run = probe(token).then((answer) => {
        if (answer.status === 200) cache.set(token, { at: Date.now(), answer });
        return answer;
      }).finally(() => inflight.delete(token));
      inflight.set(token, run);
    }
    const answer = await run;
    return json(answer.body, answer.status);
  } catch (error) {
    return json({ error: (error as Error).message }, 400);
  }
});
