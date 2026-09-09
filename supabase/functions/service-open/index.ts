import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Сервисное открытие замка: подтверждение для платы.
//
//   POST { machid, uuid, secret } -> 200 { seconds }  — открывай на N секунд
//                                    404              — разрешения нет
//
// Зовётся прошивкой esp-pulse/esp-relay после MQTT-пинка от нашего брокера в
// топик svc/<machid>/in. Пинок — это только звонок в дверь: решение «можно»
// живёт в таблице service_opens, куда его положил владелец кнопкой в панели.
// Плата открывает замок ТОЛЬКО по 2xx отсюда — тот же инвариант, что у
// complete-order.
//
// ОТСЮДА ГЛАВНОЕ ПРАВИЛО ЭТОГО ФАЙЛА: всё, что не «открывай», обязано быть
// НЕ-2xx. Прошивка не смотрит в тело ответа, чтобы решить, открывать ли, —
// только на статус (см. handle_service_open_task в main.c). Ровно на этом
// однажды погорел complete-order: 200 на неизвестный заказ открывал холодильник
// бесплатно (см. комментарий в complete-order/index.ts). Поэтому 404 здесь —
// не «не найдено» в смысле REST, а «не открывай».
//
// verify_jwt=false в config.toml: плата шлёт publishable-ключ, а не JWT.
//
// ПРО АУТЕНТИФИКАЦИЮ УСТРОЙСТВА. (uuid, secret) сверяются с кэшем
// smartvend_machines — тем же, из которого их выдаёт device-provision. Это
// НЕ граница безопасности, и притворяться иначе не нужно: device-provision
// публична, так что любой, знающий machid, получит эту пару одним запросом.
// Проверка стоит здесь как защита от случайного вызова и чтобы поднять цену
// шума на порядок, не более.
//
// Настоящая же граница в другом месте, и она держится без этой проверки:
// замок открывает не бэкенд, а физически присутствующая плата, а разрешение
// выдаёт только аутентифицированный владелец. Худшее, чего добьётся посторонний
// с этим эндпоинтом, — заберёт чужую заявку, и у оператора кнопка в панели
// «не сработает». Открыть чужой холодильник этот путь не даёт.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json();
    const machid = parseInt(body?.machid ?? "");
    const uuid = String(body?.uuid ?? "").trim();
    const secret = String(body?.secret ?? "").trim();
    if (!machid) return json({ error: "machid is required" }, 400);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    // Сверка личности платы — см. оговорку в шапке о том, чем она является и
    // чем нет. 401, а не 200, по общему правилу файла.
    const { data: dev } = await supabase
      .from("smartvend_machines")
      .select("uuid, secret")
      .eq("machid", machid)
      .single();
    if (!dev) return json({ status: "unknown_machine" }, 404);
    if (dev.uuid !== uuid || String(dev.secret ?? "").trim() !== secret) {
      return json({ status: "bad_credentials" }, 401);
    }

    // Атомарный захват: повторный пинок (MQTT QoS 0 умеет продублировать
    // сообщение на переподключении) заберёт уже нечего и получит 404, поэтому
    // замок не откроется дважды.
    const { data: claim, error: claimErr } = await supabase
      .rpc("claim_service_open", { p_machid: machid });
    if (claimErr) {
      console.error("claim_service_open failed", machid, claimErr.message);
      // 503, а не 500: плата ретраит трижды, и транзиентная ошибка БД должна
      // получить эти попытки.
      return json({ status: "error", error: claimErr.message }, 503);
    }

    // Разрешения нет: не выдавали, просрочено, или его уже забрали. Все три
    // случая — «не открывай», и различать их плате незачем.
    if (!claim?.ok) return json({ status: "no_request" }, 404);

    console.log(`service open granted machid=${machid} id=${claim.id} seconds=${claim.seconds}`);
    return json({ status: "ok", seconds: claim.seconds });
  } catch (error) {
    return json({ error: error.message }, 400);
  }
});
