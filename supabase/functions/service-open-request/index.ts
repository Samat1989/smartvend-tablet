import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Сервисное открытие замка: выдача разрешения из панели владельца.
//
//   POST { machid, seconds? } -> 200 { ok, seconds, nudge }
//
// Зовётся из apps/web_app (Admin.jsx, кнопка «Открыть на обслуживание») через
// invokeAdminFn, то есть с сессионным токеном оператора.
//
// Делает два дела, и они неравнозначны:
//   1. request_service_open — кладёт разрешение в service_opens. ЭТО ГЛАВНОЕ.
//      Права проверяются внутри RPC (владелец машины или суперадмин).
//   2. Публикует пинок в svc/<machid>/in нашего MQTT-брокера, чтобы плата не
//      ждала. Это УСКОРЕНИЕ, а не команда: сообщение ничего не открывает,
//      подделанное — тем более (в БД нет заявки, service-open ответит 404).
//
// Отсюда `nudge: false` в ответе вместо ошибки, когда брокер недоступен:
// разрешение выдано и живёт 10 минут, плата подберёт его на переподключении.
// Ронять всю операцию из-за недоступного «звонка в дверь» значило бы сделать
// фичу менее надёжной, чем она есть.
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

// ── Минимальный MQTT 3.1.1 поверх WebSocket ────────────────────────────────
// Нам нужны ровно два пакета — CONNECT и PUBLISH QoS 0. Это ~60 строк против
// целого дерева зависимостей mqtt.js, которое пришлось бы тянуть в Edge-функцию
// ради одного 60-байтного сообщения, попутно поставив фичу в зависимость от
// node-совместимости рантайма. Ни подписок, ни QoS>0, ни retained здесь нет и
// не планируется: если понадобятся — это повод взять библиотеку, а не дописать
// сюда ещё пять пакетов.

function encodeLength(n: number): number[] {
  const out: number[] = [];
  do {
    let byte = n % 128;
    n = Math.floor(n / 128);
    if (n > 0) byte |= 0x80;
    out.push(byte);
  } while (n > 0);
  return out;
}

// MQTT-строка: длина big-endian двумя байтами, затем UTF-8.
function encodeString(s: string): number[] {
  const bytes = new TextEncoder().encode(s);
  return [(bytes.length >> 8) & 0xff, bytes.length & 0xff, ...bytes];
}

function connectPacket(clientId: string, user: string, pass: string): Uint8Array {
  const KEEPALIVE = 30;
  const FLAGS = 0xc2; // username + password + clean session
  const rest = [
    ...encodeString("MQTT"),
    0x04, // protocol level 4 = MQTT 3.1.1
    FLAGS,
    (KEEPALIVE >> 8) & 0xff, KEEPALIVE & 0xff,
    ...encodeString(clientId),
    ...encodeString(user),
    ...encodeString(pass),
  ];
  return new Uint8Array([0x10, ...encodeLength(rest.length), ...rest]);
}

function publishPacket(topic: string, payload: string): Uint8Array {
  // QoS 0 — без идентификатора пакета и без подтверждения.
  const rest = [...encodeString(topic), ...new TextEncoder().encode(payload)];
  return new Uint8Array([0x30, ...encodeLength(rest.length), ...rest]);
}

const DISCONNECT = new Uint8Array([0xe0, 0x00]);

// Открывает WSS, логинится, публикует одно сообщение и закрывается.
// Бросает исключение на любой заминке — вызывающий трактует это как «пинок не
// доехал», не как провал операции.
function mqttPublish(
  opts: { host: string; port: string; user: string; pass: string },
  topic: string,
  payload: string,
  timeoutMs = 6000,
): Promise<void> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`wss://${opts.host}:${opts.port}/mqtt`, "mqtt");
    ws.binaryType = "arraybuffer";

    let settled = false;
    const finish = (err?: Error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { ws.close(); } catch (_) { /* уже закрыт */ }
      err ? reject(err) : resolve();
    };
    const timer = setTimeout(() => finish(new Error("mqtt timeout")), timeoutMs);

    ws.onopen = () => {
      // client_id обязан быть уникальным: одинаковые выбивают друг друга с
      // брокера. Функция может исполняться параллельно, отсюда случайный хвост.
      ws.send(connectPacket(`svc-fn-${crypto.randomUUID().slice(0, 8)}`, opts.user, opts.pass));
    };

    ws.onmessage = (ev) => {
      const b = new Uint8Array(ev.data as ArrayBuffer);
      if ((b[0] & 0xf0) !== 0x20) return; // ждём только CONNACK
      // CONNACK: [0x20, 0x02, flags, returnCode]. 0 = приняли.
      if (b[3] !== 0) return finish(new Error(`mqtt connack rc=${b[3]}`));
      ws.send(publishPacket(topic, payload));
      ws.send(DISCONNECT);
      // close() по спецификации уходит ПОСЛЕ уже поставленных в очередь кадров,
      // поэтому publish не потеряется; ждём onclose, чтобы не завершить
      // изолят до того, как рантайм их отправит.
      ws.close();
    };

    ws.onclose = () => finish();
    ws.onerror = () => finish(new Error("mqtt ws error"));
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
    const seconds = parseInt(String(body.seconds ?? "180").trim());
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

    // ── пинок ────────────────────────────────────────────────────────────────
    const host = Deno.env.get("MQTT_SVC_HOST") ?? "";
    const mqttUser = Deno.env.get("MQTT_SVC_USER") ?? "";
    const mqttPass = Deno.env.get("MQTT_SVC_PASS") ?? "";
    const port = Deno.env.get("MQTT_SVC_WSS_PORT") ?? "8884";

    let nudge = false;
    if (host && mqttUser && mqttPass) {
      try {
        await mqttPublish(
          { host, port, user: mqttUser, pass: mqttPass },
          `svc/${machid}/in`,
          JSON.stringify({ cmd: "service-open", id: grant.id, seconds: grant.seconds }),
        );
        nudge = true;
      } catch (e) {
        // Намеренно не роняем запрос — см. шапку файла.
        console.error("mqtt nudge failed", machid, e.message);
      }
    } else {
      console.error("mqtt nudge skipped: MQTT_SVC_* secrets are not set");
    }

    console.log(
      `service open requested machid=${machid} by=${caller.user.id} ` +
      `seconds=${grant.seconds} nudge=${nudge}`,
    );
    return json({ ok: true, seconds: grant.seconds, nudge });
  } catch (error) {
    return json({ error: error.message }, 400);
  }
});
