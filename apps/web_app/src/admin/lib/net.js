import { supabase } from '../../supabaseClient';

// Ответ от базы или запрос, который до неё не доехал?
//
// postgrest-js ловит упавший fetch сам и возвращает его как обычную ошибку
// PostgREST — только без HTTP-статуса и с пустым `code`, а в message кладёт имя
// исходной ошибки. В Chrome это читается ровно как "TypeError: Failed to fetch",
// и именно эта строка уезжала оператору в тост вместо чего-то осмысленного.
//
// Любая ошибка с `code` — это ответ Postgres (нарушен constraint, не прошла
// RLS): её повторять бессмысленно, сервер уже всё решил. Отличаем одно от
// другого здесь, в одном месте.
export function isNetworkFailure(err) {
  if (!err) return false;
  if (err.code) return false;              // настоящий ответ PostgREST/Postgres
  if (err.status && err.status !== 0) return false;
  return /TypeError|FetchError|Failed to fetch|Load failed|NetworkError|network request failed/i
    .test(`${err.name || ''} ${err.message || ''}`);
}

/**
 * Правка строки: PATCH, а если он до сервера не доехал — то же тело POST-ом.
 *
 * Зачем. У одного из операторов добавление товара проходило (29 строк
 * в products за один день), а сохранение правок падало с
 * "TypeError: Failed to fetch" — то есть ответа не было вовсе. В базе это
 * видно без всяких логов: у всех 29 строк updated_at равен created_at, при
 * том что у полутора десятков других владельцев правки в те же минуты
 * ложились нормально. Значит сервер здоров, а до него не доходит конкретно
 * PATCH: разница между работающим insert() и падающим update() только в
 * методе. PATCH (и его CORS-preflight) режут корпоративные прокси,
 * антивирусы с проверкой HTTPS и часть расширений браузера; POST пускают все.
 *
 * upsert бьётся в первичный ключ, то есть уходит ровно в ту же строку.
 * `fullRow` — полный набор колонок на случай, если строку успели удалить и
 * upsert окажется вставкой: без него в каталоге завёлся бы безымянный призрак.
 * Он же несёт owner_id / micromarket_id, которые при upsert обязательны —
 * RLS проверяет тогда и INSERT-политику, а она требует своего владельца.
 *
 * Его можно и не передавать — тогда вставка заведомо не пройдёт RLS, и это
 * ровно то, что нужно там, где призрак недопустим (см. renameMarket).
 *
 * INSERT здесь намеренно не повторяется нигде: POST мог дойти и потерять
 * только ответ, и второй заход создал бы дубль.
 */
export async function patchRow(table, id, patch, fullRow) {
  let { error } = await supabase.from(table).update(patch).eq('id', id);
  if (isNetworkFailure(error)) {
    console.warn(`PATCH ${table} не дошёл, повтор через upsert:`, error.message);
    // created_at/updated_at выкидываем: их ведёт база, и слать своё значение
    // туда, где вызывающий просто передал строку из списка, — только портить.
    const row = { ...fullRow };
    delete row.created_at;
    delete row.updated_at;
    ({ error } = await supabase.from(table).upsert({ ...row, ...patch, id }));
  }
  return error;
}

/**
 * Удаление строки: DELETE, а если он до сервера не доехал — та же работа
 * через RPC, то есть POST-ом на /rest/v1/rpc/<rpcName>.
 *
 * Тот же диагноз, что и у patchRow(), только лечится иначе: у PostgREST
 * удаление — это всегда метод DELETE, подменить его на POST на клиенте
 * нечем. Поэтому в базе лежат три security invoker функции
 * (supabase/migrations/20260921120000_delete_rpcs_for_blocked_delete_method.sql),
 * которые делают ровно тот же delete под теми же RLS-политиками.
 *
 * Возвращает количество удалённых строк — как `.select('id')` у обычного
 * DELETE. Ноль значит «строку не отдала RLS»: PostgREST на удаление без
 * прав отвечает не ошибкой, а пустым результатом, и без этой цифры панель
 * бодро рапортовала бы об успехе.
 */
export async function deleteRow(table, id, rpcName) {
  const { data, error } = await supabase.from(table).delete().eq('id', id).select('id');
  if (!isNetworkFailure(error)) return { error, deleted: data?.length ?? 0 };

  console.warn(`DELETE ${table} не дошёл, повтор через RPC ${rpcName}:`, error.message);
  const { data: count, error: rpcError } = await supabase.rpc(rpcName, { p_id: id });
  return { error: rpcError, deleted: rpcError ? 0 : (count ?? 0) };
}
