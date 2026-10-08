import { useEffect, useMemo, useState } from 'react';
import { AlertTriangle, ChevronRight, Package, Pencil, RotateCcw, Settings, Unlink as LinkOff, Wallet, Wifi } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../supabaseClient';
import { IconButton } from '../ui/Button';
import { Card, KpiCard, PageHeader, Pill } from '../ui/Card';
import { ChipGroup } from '../ui/Chips';
import { EmptyState, SkeletonRows } from '../ui/Feedback';
import { SearchInput, matches } from '../ui/Field';
import { DeviceStatusDot, KindBadge, PayChannelBadge, machineOnline } from '../status/Status';
import { LOW_STOCK, currencyOf, machineName, money } from '../lib/machines';
import { fetchSalesAggregate, periodRange, saleOutcome } from '../lib/sales';

const needsBoard = (m) => m.kind === 'micromarket_static' || m.kind === 'micromarket_tablet';

/**
 * The owner's machines: headline numbers for today, then every machine with
 * its connection, today's takings and how many cells are running low.
 *
 * Low stock and today's revenue come from two light queries made here (all of
 * the owner's inventory rows, today's sales), so the list can say "3 cells
 * running low" without opening each machine.
 */
export default function MachinesTab({ markets, loaded, rtOnline, onOpen, onRename, onSettings, onRelease, showToast }) {
  const { t } = useTranslation();
  const [q, setQ] = useState('');
  const [filter, setFilter] = useState('all');
  const [low, setLow] = useState(null);        // Map machid -> {low, empty}
  const [today, setToday] = useState(null);    // Map machid -> {net, refund}

  const ids = markets.map((m) => m.id).join(',');
  useEffect(() => {
    if (!loaded) return;
    let alive = true;
    (async () => {
      try {
        const [inv, sales] = await Promise.all([
          supabase.from('inventory').select('micromarket_id, stock'),
          fetchSalesAggregate({ market: 'all', range: periodRange('day') }),
        ]);
        if (!alive) return;
        if (inv.error) throw inv.error;
        const lm = new Map();
        for (const r of inv.data || []) {
          const k = String(r.micromarket_id);
          const e = lm.get(k) ?? { low: 0, empty: 0 };
          if ((r.stock ?? 0) <= 0) e.empty += 1;
          else if (r.stock < LOW_STOCK) e.low += 1;
          lm.set(k, e);
        }
        setLow(lm);
        const tm = new Map();
        for (const s of sales.rows) {
          const o = saleOutcome(s);
          if (o.state === 'progress') continue;
          const k = String(s.micromarket_id);
          const e = tm.get(k) ?? { net: 0, refund: 0 };
          e.net += (s.amount || 0) - o.refund;
          e.refund += o.refund;
          tm.set(k, e);
        }
        setToday(tm);
      } catch (err) {
        console.error('Machine summary failed:', err);
        if (alive) { setLow(new Map()); setToday(new Map()); }
        showToast?.(t('machines_summary_error'), 'error');
      }
    })();
    return () => { alive = false; };
  }, [loaded, ids]);

  const rows = useMemo(() => markets.map((m) => {
    const rtLive = m.rt ? (m.id in rtOnline ? !!rtOnline[m.id] : null) : undefined;
    const lw = low?.get(String(m.id)) ?? { low: 0, empty: 0 };
    return { m, rtLive, online: machineOnline(m, rtLive), needRefill: lw.low + lw.empty, lw, today: today?.get(String(m.id)) };
  }), [markets, rtOnline, low, today]);

  const counts = {
    all: rows.length,
    offline: rows.filter((r) => r.online === false).length,
    low: rows.filter((r) => r.needRefill > 0).length,
  };
  const shown = rows.filter((r) => {
    if (filter === 'offline' && r.online !== false) return false;
    if (filter === 'low' && !(r.needRefill > 0)) return false;
    return matches(q, r.m.name, r.m.id);
  });

  const watched = rows.filter((r) => r.online != null);
  const onlineN = watched.filter((r) => r.online).length;
  const cells = rows.reduce((s, r) => s + r.needRefill, 0);
  // Sum today's takings per currency — a fleet can mix tenge and som.
  const perCur = new Map();
  for (const r of rows) {
    if (!r.today) continue;
    const c = currencyOf(r.m);
    const e = perCur.get(c) ?? { net: 0, refund: 0 };
    e.net += r.today.net; e.refund += r.today.refund;
    perCur.set(c, e);
  }
  const curText = (key) => perCur.size === 0 ? `0 ${currencyOf(null)}` : [...perCur.entries()].map(([c, v]) => `${money(v[key])} ${c}`).join(' · ');
  const refundAny = [...perCur.values()].some((v) => v.refund > 0);

  const lowText = (r) => {
    if (low == null) return null;
    if (r.lw.empty && r.lw.low) return t('cells_empty_low', { empty: r.lw.empty, low: r.lw.low });
    if (r.lw.empty) return t('cells_empty', { count: r.lw.empty });
    if (r.lw.low) return t('cells_low', { count: r.lw.low });
    return null;
  };

  const actions = (m) => (
    <>
      <IconButton icon={Pencil} label={t('rename')} onClick={() => onRename(m)} />
      {needsBoard(m) && (
        <IconButton icon={Settings} label={t('machine_settings')} tone={m.rt ? 'success' : 'default'} onClick={() => onSettings(m)} />
      )}
      {m.kind === 'vending' && (
        <IconButton icon={LinkOff} label={t('release_tablet')} onClick={() => onRelease(m)} />
      )}
    </>
  );

  return (
    <div className="flex flex-col gap-6">
      <PageHeader
        title={t('devices')}
        subtitle={loaded ? t('machines_subtitle', { count: rows.length, low: counts.low }) : t('loading_short')}
      />

      <div className="grid grid-cols-2 xl:grid-cols-4 gap-3 sm:gap-4">
        <KpiCard accent="blue" icon={Wifi} label={t('kpi_online')} value={loaded ? t('n_of_m', { n: onlineN, m: watched.length }) : '—'}
          pill={watched.length - onlineN > 0 ? t('n_offline', { count: watched.length - onlineN }) : null} pillTone="red" />
        <KpiCard accent="orange" icon={AlertTriangle} label={t('kpi_need_refill')} value={low == null ? '—' : String(counts.low)}
          pill={cells > 0 ? t('cells_n', { count: cells }) : null} note={cells > 0 ? t('low_stock_rule', { n: LOW_STOCK }) : null} />
        <KpiCard accent="green" icon={Wallet} label={t('kpi_revenue_today')} value={today == null ? '—' : curText('net')} />
        <KpiCard accent={refundAny ? 'red' : 'violet'} icon={RotateCcw} label={t('kpi_refund_today')} value={today == null ? '—' : curText('refund')} />
      </div>

      <Card>
        <div className="flex flex-wrap items-center justify-between gap-3 p-4 sm:px-5">
          <SearchInput value={q} onChange={setQ} placeholder={t('machines_search')} className="w-full sm:w-80" />
          <ChipGroup
            label={t('filter')}
            value={filter}
            onChange={setFilter}
            scroll
            options={[
              { value: 'all', label: t('filter_all'), count: counts.all },
              { value: 'offline', label: t('filter_offline'), count: counts.offline, tone: 'danger' },
              { value: 'low', label: t('filter_low'), count: low == null ? null : counts.low, tone: 'warning', icon: AlertTriangle },
            ]}
          />
        </div>

        {!loaded ? (
          <div className="px-4 pb-4"><SkeletonRows rows={4} /></div>
        ) : shown.length === 0 ? (
          <EmptyState icon={Package} title={rows.length === 0 ? t('no_machines') : t('nothing_found')} hint={rows.length === 0 ? t('no_machines_hint') : t('nothing_found_hint')} />
        ) : (
          <>
            {/* Table from md up */}
            <div className="hidden md:block overflow-x-auto px-3 pb-3">
              <table className="w-full text-sm">
                <thead>
                  <tr className="bg-slate-100 text-slate-600 text-xs uppercase tracking-wider text-left">
                    <th scope="col" className="px-3 py-3 font-bold rounded-l-[8px]">{t('machine')}</th>
                    <th scope="col" className="px-3 py-3 font-bold">{t('adm_col_kind')}</th>
                    <th scope="col" className="px-3 py-3 font-bold">{t('connection')}</th>
                    <th scope="col" className="px-3 py-3 font-bold text-right">{t('kpi_revenue_today')}</th>
                    <th scope="col" className="px-3 py-3 font-bold">{t('stock_label')}</th>
                    <th scope="col" className="px-3 py-3 font-bold rounded-r-[8px]"><span className="sr-only">{t('actions')}</span></th>
                  </tr>
                </thead>
                <tbody>
                  {shown.map((r) => {
                    const { m } = r;
                    const lt = lowText(r);
                    return (
                      <tr key={m.id} className="border-b border-slate-200 last:border-0 hover:bg-slate-50">
                        <td className="px-3 py-3">
                          <button type="button" onClick={() => onOpen(m.id)} className="text-left font-bold text-ink hover:text-brand-dark focus-visible:outline-none focus-visible:underline">
                            {machineName(m, t)}
                          </button>
                          <div className="text-xs text-slate-600 mt-0.5">{t('apparatus_no')}{m.id}</div>
                        </td>
                        <td className="px-3 py-3"><div className="flex flex-wrap gap-1.5"><KindBadge kind={m.kind} /><PayChannelBadge status={m.status} /></div></td>
                        <td className="px-3 py-3">
                          <DeviceStatusDot status={m.status} kind={m.kind} withLabel rt={r.rtLive} rtState={rtOnline[m.id]} rtRow={m.rt} />
                          {m.kind === 'micromarket_static' && !m.rt && <span className="text-[13px] text-slate-500">—</span>}
                        </td>
                        <td className="px-3 py-3 text-right font-bold tabular-nums whitespace-nowrap">
                          {r.today ? `${money(r.today.net)} ${currencyOf(m)}` : today == null ? '…' : `0 ${currencyOf(m)}`}
                        </td>
                        <td className="px-3 py-3">
                          {lt ? <Pill tone={r.lw.empty ? 'red' : 'amber'}>{lt}</Pill> : low == null ? <span className="text-slate-400">…</span> : <Pill>{t('stock_ok')}</Pill>}
                        </td>
                        <td className="px-3 py-3">
                          <div className="flex items-center justify-end gap-1.5">
                            {actions(m)}
                            <button
                              type="button"
                              onClick={() => onOpen(m.id)}
                              className="inline-flex items-center gap-1 min-h-9 pl-3 pr-2 rounded-[10px] bg-brand text-white text-[13px] font-bold hover:bg-brand-dark focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300"
                            >
                              {t('open')} <ChevronRight size={16} />
                            </button>
                          </div>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>

            {/* Cards on a phone */}
            <ul className="md:hidden flex flex-col gap-2 px-3 pb-3">
              {shown.map((r) => {
                const { m } = r;
                const lt = lowText(r);
                return (
                  <li key={m.id} className="rounded-[12px] border border-slate-200 bg-white">
                    <button type="button" onClick={() => onOpen(m.id)} className="w-full flex items-center gap-3 p-3 text-left focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300 rounded-[12px]">
                      <div className="flex-1 min-w-0 flex flex-col gap-1.5">
                        <div className="flex items-start justify-between gap-2">
                          <span className="font-bold text-ink truncate">{machineName(m, t)}</span>
                          <span className="font-extrabold tabular-nums whitespace-nowrap">{r.today ? `${money(r.today.net)} ${currencyOf(m)}` : ''}</span>
                        </div>
                        <div className="flex flex-wrap gap-1.5 items-center">
                          <DeviceStatusDot status={m.status} kind={m.kind} withLabel rt={r.rtLive} rtState={rtOnline[m.id]} rtRow={m.rt} />
                          {lt && <Pill tone={r.lw.empty ? 'red' : 'amber'}>{lt}</Pill>}
                        </div>
                      </div>
                      <ChevronRight size={20} className="text-slate-500 shrink-0" aria-hidden="true" />
                    </button>
                    <div className="flex items-center gap-1.5 px-3 pb-3 -mt-1">
                      <KindBadge kind={m.kind} />
                      <span className="text-xs text-slate-600">{t('apparatus_no')}{m.id}</span>
                      <div className="ml-auto flex gap-1.5">{actions(m)}</div>
                    </div>
                  </li>
                );
              })}
            </ul>
          </>
        )}
      </Card>
    </div>
  );
}
