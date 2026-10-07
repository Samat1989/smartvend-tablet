import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { DeviceChannel } from "../_shared/device_channel.ts";

// Проверка обновления прошивки платы прямо сейчас (кнопка в панели).
//
//   POST { machid } -> 200 { ok, status, code?, ver? }
//   status: current | updating | skipped | failed | offline | busy
//
// Только суперадмин: обновление флота — не дело владельца аппарата. Плата
// получает подписанную команду ota-check, смотрит манифест в Storage
// (updates/esp-rt-<variant>/manifest.json) и, если для неё есть сборка,
// качает её в фоне, продолжая работать; перезагружается, когда замок
// свободен. Выбор платы и версия — в манифесте (devices / pins), см.
// scripts/publish_esp_rt.py.
//
// verify_jwt=false в config.toml — токен вызывающего проверяется здесь.

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

  const admin = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    { auth: { persistSession: false } },
  );

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ error: "not authenticated" }, 401);
  const { data: caller, error: callerErr } = await admin.auth.getUser(token);
  if (callerErr || !caller?.user) return json({ error: "not authenticated" }, 401);
  if (caller.user.app_metadata?.is_superadmin !== true) return json({ error: "forbidden" }, 403);

  let ch: DeviceChannel | null = null;
  try {
    const body = await req.json().catch(() => ({}));
    const machid = parseInt(String(body.machid ?? "").trim());
    if (!machid || machid < 0) return json({ error: "bad_machid" }, 400);

    const { data: rt } = await admin
      .from("device_rt").select("topic, key, device_id").eq("machid", machid).maybeSingle();
    if (!rt) return json({ error: "not_paired" }, 400);

    // Идёт оплата — не трогаем: после загрузки плата перезагрузится.
    const since = new Date(Date.now() - 2 * 60_000).toISOString();
    const { count } = await admin
      .from("pending_orders").select("orderid", { count: "exact", head: true })
      .eq("micromarket_id", machid).eq("status", "pending").gte("created_at", since);
    if ((count ?? 0) > 0) return json({ ok: true, status: "busy" });

    ch = await DeviceChannel.open(admin, rt.topic, rt.device_id ?? "");
    const ans = await ch.otaCheck(rt.key, 8000);
    if (!ans) return json({ ok: true, status: "offline" });
    console.log(`ota-check machid=${machid} by=${caller.user.id} -> ${ans.status}`);
    return json({ ok: true, status: ans.status, code: ans.code, ver: ans.ver });
  } catch (e) {
    return json({ ok: true, status: "offline", detail: (e as Error).message });
  } finally {
    await ch?.close();
  }
});
