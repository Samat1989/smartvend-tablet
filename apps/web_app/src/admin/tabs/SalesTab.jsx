import { useEffect, useMemo, useRef, useState } from 'react';
import { Download, Receipt, RefreshCw, RotateCcw, ShoppingBag, TrendingUp, Wallet } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../supabaseClient';
import { Button, IconButton } from '../ui/Button';
import { KpiCard, PageHeader } from '../ui/Card';
import { Segmented } from '../ui/Chips';
import { Banner, EmptyState, SkeletonRows } from '../ui/Feedback';
import { inputCls } from '../ui/Field';
import { catName, currencyOf, machineName, money, parseLayout } from '../lib/machines';
import {
  SALES_PAGE_SIZE, buildChart, computeStats, dateLocale, delta, downloadText, fetchSalesAggregate,
  fetchSalesPage, periodRange, previousRange, revenueByCategory, revenueByMachine, salesCsv,
} from '../lib/sales';
import SaleCard from './SaleCard';
import { CategoryDonut, MachineBars, RevenueChart } from './SalesCharts';

const fmtDelta = (d) => (d == null ? null : `${d > 0 ? '+' : ''}${d.toFixed(1).replace('.', ',')}%`);
// Up is green, down is red, flat is grey — the colour of the card's edge says
// nothing about whether things got better.
const deltaTone = (d) => (d == null || Math.abs(d) < 0.05 ? 'slate' : d > 0 ? 'green' : 'red');

/**
 * Sales: totals, charts and the receipts, for one machine or all of them.
 *
 * The totals are computed from every sale of the period (fetchSalesAggregate,
 * light columns), not from the page on screen: the old tab capped the list at
 * 500 and summed what it got, so a busy month under-reported without a word.
 * The list itself pages, 50 at a time, with the real count above it.
 */
export default function SalesTab({ markets, categories, showToast, onConfirm }) {
  const { t, i18n } = useTranslation();
  const lang = i18n.language;
  const [timeFilter, setTimeFilter] = useState('recent');
  const [periodFrom, setPeriodFrom] = useState('');
  const [periodTo, setPeriodTo] = useState('');
  const [market, setMarket] = useState('all');

  const [list, setList] = useState([]);
  const [count, setCount] = useState(null);
  const [listLoading, setListLoading] = useState(true);
  const [moreLoading, setMoreLoading] = useState(false);
  const [agg, setAgg] = useState(null);       // { rows, partial } of the period
  const [prevAgg, setPrevAgg] = useState(null);
  const [aggLoading, setAggLoading] = useState(false);
  const [open, setOpen] = useState(() => new Set());
  const [exporting, setExporting] = useState(false);
  const reqId = useRef(0);

  const range = useMemo(() => periodRange(timeFilter, periodFrom, periodTo), [timeFilter, periodFrom, periodTo]);

  const byId = useMemo(() => new Map(markets.map((m) => [String(m.id), m])), [markets]);
  const currencyFor = (id) => currencyOf(byId.get(String(id)));
  const nameFor = (id) => machineName(byId.get(String(id)) ?? { id }, t);
  // Layouts parsed once per machine: parseLayout builds a fresh object and
  // motorToSlotLabel hangs its motor→slot map on it.
  const layouts = useMemo(() => {
    const m = new Map();
    for (const mk of markets) m.set(String(mk.id), parseLayout(mk.layout_json));
    return m;
  }, [markets]);

  async function load() {
    const id = ++reqId.current;
    setListLoading(true);
    setOpen(new Set());
    const wantAgg = timeFilter !== 'recent';
    if (wantAgg) setAggLoading(true); else { setAgg(null); setPrevAgg(null); }
    try {
      const prev = wantAgg ? previousRange(timeFilter, range) : null;
      const [page, a, p] = await Promise.all([
        fetchSalesPage({ market, range, offset: 0, pageSize: timeFilter === 'recent' ? 20 : SALES_PAGE_SIZE }),
        wantAgg ? fetchSalesAggregate({ market, range }) : null,
        prev ? fetchSalesAggregate({ market, range: prev }) : null,
      ]);
      if (id !== reqId.current) return;
      setList(page.rows);
      setCount(page.count);
      setAgg(a);
      setPrevAgg(p);
    } catch (err) {
      if (id !== reqId.current) return;
      console.error('Error fetching sales:', err);
      showToast(t('sales_load_error'), 'error');
    } finally {
      if (id === reqId.current) { setListLoading(false); setAggLoading(false); }
    }
  }

  useEffect(() => { load(); }, [timeFilter, periodFrom, periodTo, market]);

  async function loadMore() {
    setMoreLoading(true);
    try {
      const page = await fetchSalesPage({ market, range, offset: list.length });
      setList((prev) => [...prev, ...page.rows]);
      if (page.count != null) setCount(page.count);
    } catch (err) {
      console.error('Error fetching more sales:', err);
      showToast(t('sales_load_error'), 'error');
    } finally {
      setMoreLoading(false);
    }
  }

  function restoreStock(sale) {
    onConfirm({
      message: t('restore_stock_confirm'),
      yesLabel: t('restore_stock'),
      tone: 'primary',
      onYes: async () => {
        const { error } = await supabase.rpc('restore_sale_stock', { p_sale_id: sale.id });
        if (error) { showToast(error.message, 'error'); return; }
        showToast(t('stock_restored'));
        load();
      },
    });
  }

  async function exportCsv() {
    setExporting(true);
    try {
      const rows = agg?.rows ?? (await fetchSalesAggregate({ market, range })).rows;
      const csv = salesCsv(rows, { t, lang, machineNameFor: nameFor, currencyFor });
      const stamp = new Date().toISOString().slice(0, 10);
      downloadText(csv, `microvend-sales-${market === 'all' ? 'all' : market}-${stamp}.csv`);
    } catch (err) {
      showToast(`${t('csv_error')}: ${err.message}`, 'error');
    } finally {
      setExporting(false);
    }
  }

  // Numbers: the whole period when there is one, else what is on screen.
  const statRows = agg?.rows ?? list;
  const stats = computeStats(statRows, currencyFor);
  const prevStats = prevAgg ? computeStats(prevAgg.rows, currencyFor) : null;
  const main = stats.totals[0];
  const prevMain = prevStats?.totals.find((c) => c.currency === main?.currency);
  const cur = main?.currency ?? currencyOf(null);

  const chart = agg && main ? buildChart({ rows: agg.rows, timeFilter, range, lang, currency: cur, currencyFor }) : null;
  const machineRows = agg && main && market === 'all' ? revenueByMachine(agg.rows, cur, currencyFor) : [];
  const catRows = agg && main ? revenueByCategory(agg.rows, cur, currencyFor) : [];
  const catById = new Map(categories.map((c) => [c.id, c]));
  const catLabel = (id) => (id == null ? t('no_category') : catName(catById.get(id), lang) ?? t('no_category'));

  const multi = stats.totals.length > 1;
  const sumText = (key) => stats.totals.length === 0
    ? `0 ${cur}`
    : stats.totals.map((c) => `${money(c[key])} ${c.currency}`).join(' · ');
  const vsNote = timeFilter === 'day' ? t('vs_yesterday') : t('vs_previous');

  const periodLabel = (() => {
    if (!range) return t('sales_recent_hint');
    const f = (d) => d.toLocaleDateString(dateLocale(lang), { day: 'numeric', month: 'long' });
    const from = range.since ? f(range.since) : '…';
    const to = range.until ? f(range.until) : t('today_lower');
    return timeFilter === 'day' ? t('today') : `${from} — ${to}`;
  })();

  const loaded = list.length;
  const hasMore = count != null && loaded < count;

  return (
    <div className="flex flex-col gap-6">
      <PageHeader
        title={t('sales_title')}
        subtitle={`${market === 'all' ? t('all_machines') : nameFor(market)} · ${periodLabel}`}
        actions={(
          <>
            <label className="sr-only" htmlFor="sales-machine">{t('machine')}</label>
            <select
              id="sales-machine"
              className={`${inputCls} !w-full sm:!w-auto sm:max-w-56 font-semibold`}
              value={market}
              onChange={(e) => setMarket(e.target.value)}
            >
              <option value="all">{t('all_machines')}</option>
              {markets.map((m) => (
                <option key={m.id} value={String(m.id)}>{machineName(m, t)}</option>
              ))}
            </select>
            <IconButton icon={RefreshCw} label={t('refresh')} loading={listLoading} onClick={load} className="!w-11 !h-11" />
            <Button variant="primary" icon={Download} loading={exporting} onClick={exportCsv} className="min-h-11 flex-1 sm:flex-none">
              {t('export_csv')}
            </Button>
          </>
        )}
      />

      <div className="flex flex-wrap items-center gap-3">
        <Segmented
          label={t('period')}
          value={timeFilter}
          onChange={setTimeFilter}
          className="w-full sm:w-auto"
          options={[
            { value: 'recent', label: t('recent') },
            { value: 'day', label: t('today') },
            { value: 'week', label: t('this_week') },
            { value: 'month', label: t('this_month') },
            { value: 'period', label: t('period') },
          ]}
        />
        {timeFilter === 'period' && (
          <div className="flex items-center gap-2 w-full sm:w-auto">
            <label className="sr-only" htmlFor="sales-from">{t('period_from')}</label>
            <input id="sales-from" type="date" value={periodFrom} onChange={(e) => setPeriodFrom(e.target.value)} className={`${inputCls} sm:!w-44`} />
            <span className="text-slate-500" aria-hidden="true">—</span>
            <label className="sr-only" htmlFor="sales-to">{t('period_to')}</label>
            <input id="sales-to" type="date" value={periodTo} onChange={(e) => setPeriodTo(e.target.value)} className={`${inputCls} sm:!w-44`} />
          </div>
        )}
      </div>

      <div className={`grid grid-cols-2 xl:grid-cols-4 gap-3 sm:gap-4 ${aggLoading ? 'opacity-60' : ''}`} aria-busy={aggLoading}>
        <KpiCard
          accent="blue" icon={Wallet}
          label={t('revenue')}
          value={sumText('net')}
          pill={!multi ? fmtDelta(delta(main?.net, prevMain?.net)) : null}
          pillTone={deltaTone(delta(main?.net, prevMain?.net))}
          note={!multi && prevMain ? vsNote : stats.totals.some((c) => c.refund > 0) ? `${t('paid_gross')}: ${sumText('gross')}` : null}
        />
        <KpiCard
          accent="orange" icon={Receipt}
          label={t('orders')}
          value={money(stats.orders)}
          pill={fmtDelta(delta(stats.orders, prevStats?.orders))}
          pillTone={deltaTone(delta(stats.orders, prevStats?.orders))}
          note={prevStats ? vsNote : null}
        />
        <KpiCard
          accent="green" icon={TrendingUp}
          label={t('avg_check')}
          value={main?.avg != null ? `${money(main.avg)} ${main.currency}` : '—'}
          pill={fmtDelta(delta(main?.avg, prevMain?.avg))}
          pillTone={deltaTone(delta(main?.avg, prevMain?.avg))}
          note={prevMain?.avg != null ? vsNote : null}
        />
        <KpiCard
          accent={stats.refundCount > 0 ? 'red' : 'violet'} icon={RotateCcw}
          label={t('refund_due')}
          value={stats.refundCount === 0 ? '0' : stats.totals.filter((c) => c.refund > 0).map((c) => `${money(c.refund)} ${c.currency}`).join(' · ')}
          pill={stats.refundCount > 0 ? `${stats.refundCount} ${t('orders_short')}` : null}
          note={stats.refundCount > 0 ? t('refund_due_hint') : null}
        />
      </div>

      {agg?.partial && (
        <Banner tone="warning">{t('sales_totals_partial', { n: money(agg.rows.length) })}</Banner>
      )}

      {chart && (
        <div className={`grid gap-4 items-start ${machineRows.length > 1 || catRows.length > 0 ? 'xl:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]' : ''}`}>
          <RevenueChart
            buckets={chart}
            currency={cur}
            subtitle={timeFilter === 'day' ? t('chart_by_hour', { currency: cur }) : t('chart_by_day', { currency: cur })}
            note={multi ? t('chart_currency_note', { currency: cur }) : t('chart_hint')}
          />
          {(machineRows.length > 1 || catRows.length > 0) && (
            <div className="flex flex-col gap-4 min-w-0">
              {machineRows.length > 1 && <MachineBars rows={machineRows} nameFor={nameFor} currency={cur} />}
              {catRows.length > 0 && <CategoryDonut rows={catRows} nameFor={catLabel} currency={cur} orders={stats.orders} />}
            </div>
          )}
        </div>
      )}

      <div>
        <section className="flex flex-col gap-3" aria-labelledby="sales-list-title">
          <div className="flex flex-wrap items-end justify-between gap-2">
            <h2 id="sales-list-title" className="text-lg font-bold">{t('sales_list_title')}</h2>
            {count != null && !listLoading && (
              <span className="text-sm text-slate-600 tabular-nums">{t('shown_of', { shown: money(loaded), total: money(count) })}</span>
            )}
          </div>
          {listLoading ? (
            <SkeletonRows rows={5} />
          ) : list.length === 0 ? (
            <div className="bg-white border border-slate-200 rounded-[12px]">
              <EmptyState
                icon={ShoppingBag}
                title={t('no_data_period')}
                hint={t('no_data_period_hint')}
                action={timeFilter !== 'month' ? <Button variant="secondary" onClick={() => setTimeFilter('month')}>{t('show_month')}</Button> : null}
              />
            </div>
          ) : (
            <>
              {hasMore && timeFilter !== 'recent' && (
                <Banner tone="info">{t('sales_shown_banner', { shown: money(loaded), total: money(count) })}</Banner>
              )}
              <ul className="flex flex-col gap-2.5">
                {list.map((sale) => (
                  <SaleCard
                    key={sale.id}
                    sale={sale}
                    market={byId.get(String(sale.micromarket_id))}
                    layout={layouts.get(String(sale.micromarket_id))}
                    currency={currencyFor(sale.micromarket_id)}
                    open={open.has(sale.id)}
                    onToggle={() => setOpen((prev) => {
                      const next = new Set(prev);
                      if (next.has(sale.id)) next.delete(sale.id); else next.add(sale.id);
                      return next;
                    })}
                    onRestoreStock={restoreStock}
                  />
                ))}
              </ul>
              {hasMore && (
                <Button variant="secondary" size="lg" className="self-center mt-1" loading={moreLoading} onClick={loadMore}>
                  {t('load_more_n', { n: Math.min(SALES_PAGE_SIZE, count - loaded) })}
                </Button>
              )}
            </>
          )}
        </section>
      </div>
    </div>
  );
}
