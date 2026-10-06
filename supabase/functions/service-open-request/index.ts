import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { DeviceChannel } from "../_shared/device_channel.ts";

// Сервисное открытие замка: выдача разрешения из панели владельца.
//
//   POST { machid, seconds? } -> 200 { ok, seconds, nudge, opened? }
//
// Без seconds плата открывает замок на своё время из сервисного режима (то же,
// что у оплаченного заказа) и сообщает его в ответе; в журнал service_opens
// пишется именно оно.
//
// Зовётся из apps/web_app (Admin.jsx, кнопка «Открыть на обслуживание») через
// invokeAdminFn, то есть с сессионным токеном оператора.
//
//   1. request_service_open — кладёт разрешение в service_opens. ЭТО ГЛАВНОЕ.
//      Права проверяются внутри RPC (владелец машины или суперадмин).
//   2. Плата на Realtime-прошивке (строка в device_rt) получает подписанную
//      команду service-open в свой канал и отвечает opened. Только после
//      подтверждения заявка забирается (claim_service_open), чтобы журнал
//      не врал «открыто», когда плата была офлайн.
//
// Старым платам (MQTT) сигнал больше не отправляется: брокер HiveMQ, через
// который шёл пинок, не работает, и клиент для него удалён. Для них ответ
// `nudge: false`, как и раньше при недоступном брокере.
//
// verify_jwt=false в config.toml (гейт не отличает publishable-ключ от JWT) —
// токен вызывающего проверяется здесь.

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ??
    Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? "";

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  // ── вызывающий должен быть залогинен ──────────────────────────────────────
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ error: "not authenticated" }, 401);
  const { data: caller, error: callerErr } = await admin.auth.getUser(token);
  if (callerErr || !caller?.user) return json({ error: "not authenticated" }, 401);

  try {
    const body = await req.json().catch(() => ({}));
    const machid = parseInt(String(body.machid ?? "").trim());
    // 0 = «время платы». request_service_open хранит 10…600, поэтому до ответа
    // платы в журнале стоит значение по умолчанию, а после — фактическое.
    const asked = parseInt(String(body.seconds ?? "0").trim()) || 0;
    const seconds = asked > 0 ? asked : 180;
    if (!machid || machid < 0) return json({ error: "bad_machid" }, 400);

    // Разрешение выдаём от имени вызывающего, а не service_role: проверка
    // «твоя ли это машина» живёт внутри request_service_open и опирается на
    // auth.uid(). Позвать RPC сервисным ключом значило бы перенести границу
    // безопасности сюда, в TypeScript, — а её место в SQL, рядом с данными.
    if (!anonKey) return json({ error: "misconfigured: no anon key" }, 500);
    const asUser = createClient(url, anonKey, {
      auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    });

    const { data: grant, error: grantErr } = await asUser
      .rpc("request_service_open", { p_machid: machid, p_seconds: seconds });

    if (grantErr) {
      // 42501 — «не твоя машина» / не залогинен; 22023 — нет такой машины или
      // у неё нет замка (вендинг). И то и другое — ошибка вызывающего.
      const code = grantErr.code;
      if (code === "42501") return json({ error: "forbidden" }, 403);
      if (code === "22023") return json({ error: "bad_machine" }, 400);
      console.error("request_service_open failed", machid, grantErr.message);
      return json({ error: grantErr.message }, 500);
    }

    // ── команда плате ─────────────────────────────────────────────────────────
    let nudge = false;
    let opened: boolean | undefined;
    let openedFor: number = grant.seconds;
    const { data: rt } = await admin
      .from("device_rt").select("topic, key").eq("machid", machid).maybeSingle();
    if (rt) {
      let ch: DeviceChannel | null = null;
      try {
        ch = await DeviceChannel.open(admin, rt.topic, machid);
        const ack = await ch.command(
          "service-open", rt.key, grant.id, { seconds: asked > 0 ? grant.seconds : 0 }, Date.now() + 12_000,
        );
        nudge = !!ack;
        if (ack) {
          opened = ack.ok !== false;
          const { error: claimErr } = await admin.rpc("claim_service_open", { p_machid: machid });
          if (claimErr) console.error("claim_service_open failed", machid, claimErr.message);
          const s = Number(ack.seconds);
          if (Number.isInteger(s) && s >= 1 && s <= 600) {
            openedFor = s;
            const { error: secErr } = await admin
              .from("service_opens").update({ seconds: s }).eq("id", grant.id);
            if (secErr) console.error("service_opens seconds update failed", machid, secErr.message);
          } else {
            console.error("board ack without valid seconds", machid, JSON.stringify(ack));
          }
        }
      } catch (e) {
        // Плата недоступна — разрешение остаётся в журнале невыбранным.
        console.error("service-open command failed", machid, (e as Error).message);
      } finally {
        await ch?.close();
      }
    }

    console.log(
      `service open requested machid=${machid} by=${caller.user.id} ` +
      `seconds=${openedFor} nudge=${nudge} opened=${opened}`,
    );
    return json({ ok: true, seconds: openedFor, nudge, opened });
  } catch (error) {
    return json({ error: error.message }, 400);
  }
});
