import { supabase } from '../../supabaseClient';
import { motorToSlotLabel } from './machines';

// One page of the sales list. The list used to load everything up to a silent
// cap of 500 and compute the totals from that — a busy month simply lost the
// rest. The list now pages, and the totals come from fetchSalesAggregate.
export const SALES_PAGE_SIZE = 50;
// Hard stop for the totals query: 25 round trips of 1000 rows. Past that the
// panel says the numbers are partial instead of hanging the tab.
const AGGREGATE_CAP = 25000;
const AGGREGATE_CHUNK = 1000;

// Map an M102 poll result byte → i18n key. The codes are emitted by the
// vending tablet's `BoardClient.dispense` and persisted to
// `sales_items.result_code` (see m102_tester migration
// 20260513120000_sales_items_result_details.sql).
const RESULT_CODE_I18N = {
  1: 'result_overload',
  2: 'result_wire_break',
  3: 'result_timeout',
  4: 'result_curtain_err',
  5: 'result_lock_not_open',
  10: 'result_microswitch',
};

export function resultLabel(t, item) {
  const key = item.result_code != null ? RESULT_CODE_I18N[item.result_code] : null;
  if (key) return t(key);
  // No mapped label for this byte. In practice that means `0`, which the
  // board sends for "motor finished, no error" — the tablet still refunded
  // because the drop sensor never fired or the poll loop timed out. Printing
  // a bare "Код ошибки 0" hides that; the actual reason is the free-form
  // message the tablet stores alongside the byte ("Мотор отработал, но
  // датчик падения не сработал", "Таймаут выдачи (20с)"), so prefer it.
  //
  // Same fallback covers transport-level failures, where there is no poll
  // byte at all ("Нет ответа от платы", "Плата занята" etc.).
  if (item.result_message) return item.result_message;
  if (item.result_code != null) return `${t('result_unknown')} ${item.result_code}`;
  return t('dispense_failed');
}

// What a sale means for the money. `refund` is what the owner owes back:
// items that did not come out, or the whole sale when the door of a Realtime
// board stayed shut (paid, nothing taken). Restoring the stock marks such a
// sale as handled. A sale still in progress counts nowhere yet.
export function saleOutcome(sale) {
  if (sale.status === 'in_progress') return { state: 'progress', refund: 0 };
  const items = sale.sales_items || [];
  const failed = items.filter((i) => i.dispensed === false);
  const doorBad = sale.door_status === 'failed' || sale.door_status === 'no_ack';
  if (doorBad) {
    return sale.stock_restored_at
      ? { state: 'restored', refund: 0 }
      : { state: 'failed', refund: sale.amount || 0 };
  }
  if (sale.door_status === 'pending') return { state: 'pending', refund: 0 };
  if (failed.length) {
    const refund = failed.reduce((s, i) => s + (i.price || 0) * (i.quantity || 1), 0);
    return { state: failed.length === items.length ? 'failed' : 'partial', refund };
  }
  return { state: 'ok', refund: 0 };
}

// Локаль для даты продажи. i18n.language здесь — 'ru' | 'kk' | 'en'.
const SALE_DATE_LOCALE = { ru: 'ru-RU', kk: 'kk-KZ', kz: 'kk-KZ', en: 'en-GB' };
export const dateLocale = (lang) => SALE_DATE_LOCALE[lang] || SALE_DATE_LOCALE.ru;

/**
 * Дата продажи в списке: «21.09.2026, 14:02».
 *
 * Секунды убраны — это список чеков, а не журнал отладки, и третья пара цифр
 * только удлиняла строку. Локаль раньше была захардкожена 'ru-RU' мимо
 * переключателя языка: казахская и английская панели показывали русский формат.
 */
export function formatSaleDate(iso, lang) {
  return new Date(iso).toLocaleString(dateLocale(lang), {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  });
}

/**
 * Свести позиции чека к тому, что помещается в свёрнутую строку.
 *
 * Группировка по товару здесь обязательна: на вендинге планшет пишет каждую
 * штуку ОТДЕЛЬНОЙ строкой с quantity = 1 — количество разворачивается в цикл
 * по моторам, — поэтому чек на две банки одного энергетика приезжает двумя
 * строками, и без склейки заголовок читался бы «Gorilla, Gorilla». Static-QR,
 * наоборот, пишет настоящий count, так что units складывает оба случая.
 *
 * Ключ — product_id (это внешний ключ на inventory.id), с запасным вариантом
 * на id самой строки: позиции без product_id иначе слиплись бы в одну
 * непонятную группу. Порядок — первого появления, его Map даёт сама: чек
 * читается в том порядке, в котором его набирали.
 */
export function summarizeSaleItems(items) {
  const groups = new Map();
  let totalUnits = 0;

  for (const item of items || []) {
    const units = item.quantity || 1;
    totalUnits += units;

    const key = item.product_id ?? `#${item.id}`;
    const seen = groups.get(key);
    if (seen) {
      seen.units += units;
      seen.hasFailed = seen.hasFailed || item.dispensed === false;
      continue;
    }

    const inv = item.inventory;
    groups.set(key, {
      key,
      // Снимок имени впереди живых ссылок: product_name записан в момент
      // продажи, и это единственное, что переживает удаление позиции из
      // аппарата. Дальше — имя позиции, потом каталожное: имя позиции
      // оператор правит руками под конкретный аппарат, и это законное
      // отличие, а не протухшая копия.
      name: item.product_name || inv?.name || inv?.products?.name || null,
      units,
      hasFailed: item.dispensed === false,
      motorId: inv?.motor_id ?? null,
    });
  }

  return { groups: [...groups.values()], totalUnits };
}

/**
 * Номер ячейки для строки продажи — или null, когда его нет либо он соврёт.
 *
 * О достоверности, честно: в sales_items номера мотора нет вообще. Он берётся
 * из ТЕКУЩЕГО inventory.motor_id по ссылке product_id, то есть показывает, где
 * товар стоит сейчас, а не откуда его выдавали. Переставили товар в другую
 * спираль — у старой продажи покажется новая ячейка. Ради чего номер и нужен —
 * разбор свежего сбоя — это верно; чек месячной давности может врать. Закрыть
 * дыру можно только колонкой в sales_items, которую планшет заполнял бы в
 * момент выдачи.
 *
 * У машины с экраном motor_id — это и есть номер, написанный на полке, и
 * переводить его нельзя: motorToSlotLabel считает по вендинговой раскладке, и
 * «15» стало бы «085», а «10» — «?» (тот же капкан описан у byCellNumber).
 * У статичного микромаркета спиралей нет, motor_id там всегда пустой.
 */
export function saleSlotLabel(motorId, kind, layout) {
  if (motorId == null) return null;
  if (kind === 'micromarket_screen') return String(motorId);
  if (kind !== 'vending') return null;
  return motorToSlotLabel(motorId, layout);
}

// ── Periods ────────────────────────────────────────────────────────────────

// [since, until) of a filter, as Dates, or null for "recent" (no period).
export function periodRange(timeFilter, periodFrom, periodTo) {
  const now = new Date();
  if (timeFilter === 'day') {
    const d = new Date(now); d.setHours(0, 0, 0, 0);
    return { since: d, until: null };
  }
  if (timeFilter === 'week') {
    const d = new Date(now); d.setDate(d.getDate() - 7);
    return { since: d, until: null };
  }
  if (timeFilter === 'month') {
    const d = new Date(now); d.setMonth(d.getMonth() - 1);
    return { since: d, until: null };
  }
  if (timeFilter === 'period') {
    const since = periodFrom ? new Date(periodFrom) : null;
    let until = null;
    if (periodTo) { until = new Date(periodTo); until.setHours(23, 59, 59, 999); }
    return { since, until };
  }
  return null;
}

// The window of the same length right before `range` — what the "+4,2 %"
// pills compare against. Today is compared with yesterday up to the same hour,
// not with all of yesterday, or every morning would read as a collapse.
export function previousRange(timeFilter, range) {
  if (!range?.since) return null;
  const end = range.until ?? new Date();
  const len = end.getTime() - range.since.getTime();
  if (len <= 0) return null;
  if (timeFilter === 'period' && !range.until) return null;
  return { since: new Date(range.since.getTime() - len), until: new Date(range.since.getTime() - 1) };
}

function applyFilters(q, market, range) {
  if (market !== 'all') q = q.eq('micromarket_id', market);
  if (range?.since) q = q.gte('created_at', range.since.toISOString());
  if (range?.until) q = q.lte('created_at', range.until.toISOString());
  return q;
}

// ── Queries ────────────────────────────────────────────────────────────────

const LIST_SELECT = `
  *,
  micromarkets(name),
  sales_items(
    *,
    inventory(name, motor_id, products(name))
  )
`;

// Only what the totals, the charts and the CSV need: no joins to products,
// no result details. A month of a busy fleet is a few thousand of these.
const AGG_SELECT = `
  id, created_at, amount, status, door_status, stock_restored_at, payment_id, micromarket_id,
  sales_items(id, product_name, quantity, price, dispensed, inventory(category_id))
`;

export async function fetchSalesPage({ market, range, offset = 0, pageSize = SALES_PAGE_SIZE }) {
  const q = applyFilters(
    supabase.from('sales').select(LIST_SELECT, { count: 'exact' }),
    market, range,
  )
    .order('created_at', { ascending: false })
    .range(offset, offset + pageSize - 1);
  const { data, error, count } = await q;
  if (error) throw error;
  return { rows: data || [], count: count ?? null };
}

// Every sale of the filter, light columns only, in chunks of 1000 (the
// PostgREST row limit). `partial` is set when the cap cut it short.
export async function fetchSalesAggregate({ market, range }) {
  const rows = [];
  for (let from = 0; from < AGGREGATE_CAP; from += AGGREGATE_CHUNK) {
    const q = applyFilters(supabase.from('sales').select(AGG_SELECT), market, range)
      .order('created_at', { ascending: false })
      .order('id', { ascending: false })
      .range(from, from + AGGREGATE_CHUNK - 1);
    const { data, error } = await q;
    if (error) throw error;
    rows.push(...(data || []));
    if (!data || data.length < AGGREGATE_CHUNK) return { rows, partial: false };
  }
  return { rows, partial: true };
}

// ── Numbers ────────────────────────────────────────────────────────────────

// Grouped by currency, not summed flat. With the machine filter on "all" an
// owner can have Kazakh and Kyrgyz cabinets in the same list, and adding
// tenge to som would print a number that means nothing.
export function computeStats(rows, currencyFor) {
  const byCurrency = new Map();
  let orders = 0, refundCount = 0;
  for (const s of rows) {
    const o = saleOutcome(s);
    if (o.state === 'progress') continue;
    orders += 1;
    if (o.refund > 0) refundCount += 1;
    const cur = currencyFor(s.micromarket_id);
    const c = byCurrency.get(cur) ?? { currency: cur, gross: 0, refund: 0, okOrders: 0 };
    c.gross += s.amount || 0;
    c.refund += o.refund;
    if (o.state === 'ok' || o.state === 'partial' || o.state === 'pending') c.okOrders += 1;
    byCurrency.set(cur, c);
  }
  const totals = [...byCurrency.values()]
    .map((c) => ({ ...c, net: c.gross - c.refund, avg: c.okOrders ? Math.round((c.gross - c.refund) / c.okOrders) : null }))
    .sort((a, b) => b.net - a.net);
  return { totals, orders, refundCount };
}

// Percent change, or null when there is nothing to compare with.
export function delta(now, before) {
  if (before == null || now == null || before === 0) return null;
  return ((now - before) / before) * 100;
}

// Bars: hours of today, or the days of the chosen period. "Recent" is the
// last few sales, not a period, so it gets no chart.
export function buildChart({ rows, timeFilter, range, lang, currency, currencyFor }) {
  if (timeFilter === 'recent' || !currency) return null;
  const buckets = [];
  const index = new Map();
  if (timeFilter === 'day') {
    for (let hr = 0; hr < 24; hr++) {
      index.set(hr, buckets.length);
      buckets.push({ label: String(hr), tip: `${String(hr).padStart(2, '0')}:00`, value: 0, count: 0 });
    }
  } else {
    const start = new Date(range?.since ?? (rows.length ? rows[rows.length - 1].created_at : Date.now()));
    const end = range?.until ? new Date(range.until) : new Date();
    start.setHours(0, 0, 0, 0); end.setHours(0, 0, 0, 0);
    for (let d = new Date(start), guard = 0; d <= end && guard < 400; d.setDate(d.getDate() + 1), guard++) {
      index.set(d.toDateString(), buckets.length);
      buckets.push({
        label: String(d.getDate()),
        tip: d.toLocaleDateString(dateLocale(lang), { day: 'numeric', month: 'short' }),
        value: 0, count: 0,
      });
    }
  }
  for (const s of rows) {
    if (currencyFor(s.micromarket_id) !== currency) continue;
    const o = saleOutcome(s);
    if (o.state === 'progress') continue;
    const d = new Date(s.created_at);
    const i = index.get(timeFilter === 'day' ? d.getHours() : d.toDateString());
    if (i == null) continue;
    buckets[i].value += (s.amount || 0) - o.refund;
    buckets[i].count += 1;
  }
  return buckets;
}

// Net revenue per machine in one currency, biggest first.
export function revenueByMachine(rows, currency, currencyFor) {
  const m = new Map();
  for (const s of rows) {
    if (currencyFor(s.micromarket_id) !== currency) continue;
    const o = saleOutcome(s);
    if (o.state === 'progress') continue;
    const k = String(s.micromarket_id);
    m.set(k, (m.get(k) ?? 0) + (s.amount || 0) - o.refund);
  }
  return [...m.entries()].map(([id, value]) => ({ id, value })).sort((a, b) => b.value - a.value);
}

// Revenue of what actually came out, by the category of its inventory row.
// Items whose position was deleted since have no category and land in "other".
export function revenueByCategory(rows, currency, currencyFor) {
  const m = new Map();
  for (const s of rows) {
    if (currencyFor(s.micromarket_id) !== currency) continue;
    if (s.status === 'in_progress') continue;
    if ((s.door_status === 'failed' || s.door_status === 'no_ack')) continue;
    for (const it of s.sales_items || []) {
      if (it.dispensed === false) continue;
      const k = it.inventory?.category_id ?? null;
      m.set(k, (m.get(k) ?? 0) + (it.price || 0) * (it.quantity || 1));
    }
  }
  return [...m.entries()].map(([categoryId, value]) => ({ categoryId, value })).sort((a, b) => b.value - a.value);
}

// ── CSV ────────────────────────────────────────────────────────────────────

const csvCell = (v) => {
  const s = v == null ? '' : String(v);
  return /[";\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

// Semicolon-separated with a BOM: that is what Excel opens correctly with
// Cyrillic in a Russian locale, where a comma is the decimal separator.
export function salesCsv(rows, { t, lang, machineNameFor, currencyFor }) {
  const head = [t('csv_date'), t('csv_machine'), t('csv_items'), t('csv_amount'), t('csv_refund'), t('csv_currency'), t('csv_status'), t('payment_id')];
  const lines = [head.map(csvCell).join(';')];
  for (const s of rows) {
    const o = saleOutcome(s);
    const items = (s.sales_items || [])
      .map((i) => `${i.product_name || t('deleted_product')}${(i.quantity || 1) > 1 ? ` ×${i.quantity}` : ''}`)
      .join(', ');
    lines.push([
      formatSaleDate(s.created_at, lang),
      machineNameFor(s.micromarket_id),
      items,
      s.amount ?? 0,
      o.refund,
      currencyFor(s.micromarket_id),
      t(`sale_state_${o.state}`),
      s.payment_id ?? '',
    ].map(csvCell).join(';'));
  }
  return '﻿' + lines.join('\r\n');
}

export function downloadText(text, filename, type = 'text/csv;charset=utf-8') {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
