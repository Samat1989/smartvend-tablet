import { useState } from 'react';
import { Package } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { Card, CardHeader, Pill } from '../ui/Card';
import { Segmented } from '../ui/Chips';
import { EmptyState } from '../ui/Feedback';
import { money } from '../lib/machines';
import { delta, slowProducts, topProducts } from '../lib/sales';

const TOP = 10;
const fmtDelta = (d) => `${d > 0 ? '+' : ''}${d.toFixed(0)}%`;
const deltaTone = (d) => (Math.abs(d) < 0.5 ? 'slate' : d > 0 ? 'green' : 'red');

/**
 * What sells and what sits. «Leaders» ranks the products of the period by
 * pieces or by revenue, with the change against the previous period beside
 * each; «Not selling» lists positions that still have stock but moved least
 * (zero included), so the owner sees what to restock and what to take off the
 * shelf. Everything comes from the sales already loaded for the page.
 */
export default function TopProducts({ rows, prevRows, inventory, currency, currencyFor }) {
  const { t } = useTranslation();
  const [view, setView] = useState('leaders');
  const [by, setBy] = useState('units');

  const all = topProducts(rows, currency, currencyFor);
  const prev = prevRows ? new Map(topProducts(prevRows, currency, currencyFor).map((p) => [p.key, p])) : null;

  let list;
  let max = 1;
  if (view === 'leaders') {
    list = all.slice().sort((a, b) => (b[by] - a[by]) || (b.revenue - a.revenue)).slice(0, TOP);
    max = Math.max(1, list[0]?.[by] ?? 1);
  } else if (inventory) {
    const sold = new Map(all.map((p) => [p.key, p.units]));
    list = slowProducts(inventory, sold, currency, currencyFor).slice(0, TOP);
  } else {
    list = null; // the stock list did not load
  }

  return (
    <Card className="p-5">
      <CardHeader
        title={t('top_products_title')}
        subtitle={t('top_products_hint')}
        actions={(
          <>
            <Segmented
              label={t('top_products_title')}
              value={view}
              onChange={setView}
              options={[{ value: 'leaders', label: t('tp_leaders') }, { value: 'slow', label: t('tp_laggards') }]}
            />
            {view === 'leaders' && (
              <Segmented
                label={t('tp_by')}
                value={by}
                onChange={setBy}
                options={[{ value: 'units', label: t('tp_by_units') }, { value: 'revenue', label: t('tp_by_revenue') }]}
              />
            )}
          </>
        )}
      />

      {list == null ? (
        <EmptyState icon={Package} title={t('tp_unavailable')} />
      ) : list.length === 0 ? (
        <EmptyState icon={Package} title={view === 'leaders' ? t('tp_empty') : t('tp_empty_slow')} />
      ) : (
        <ol className="mt-4 flex flex-col gap-3">
          {list.map((p, i) => {
            if (view === 'slow') {
              return (
                <li key={p.key} className="flex items-center gap-3 min-h-11">
                  <span className="w-6 text-sm font-bold text-slate-500 tabular-nums text-right shrink-0">{i + 1}</span>
                  <div className="min-w-0 flex-1">
                    <div className="font-semibold text-ink truncate text-sm">{p.name}</div>
                    <div className="text-[13px] text-slate-600 tabular-nums">{t('tp_stock_sold', { stock: money(p.stock), sold: money(p.sold) })}</div>
                  </div>
                  <Pill tone={p.sold === 0 ? 'red' : 'amber'}>{t('pcs_n', { count: p.sold })}</Pill>
                </li>
              );
            }
            const d = prev ? delta(p.units, prev.get(p.key)?.units) : null;
            const main = by === 'units' ? t('pcs_n', { count: p.units }) : `${money(p.revenue)} ${currency}`;
            const sub = by === 'units' ? `${money(p.revenue)} ${currency}` : t('pcs_n', { count: p.units });
            return (
              <li key={p.key} className="flex items-center gap-3 min-h-11">
                <span className="w-6 text-sm font-bold text-slate-500 tabular-nums text-right shrink-0">{i + 1}</span>
                <div className="min-w-0 flex-1">
                  <div className="flex justify-between gap-3 text-sm">
                    <span className="font-semibold text-ink truncate">{p.name}</span>
                    <span className="font-bold tabular-nums whitespace-nowrap">{main}</span>
                  </div>
                  <div className="h-2 mt-1.5 rounded-full bg-slate-100 overflow-hidden">
                    <div className="h-full rounded-full bg-brand" style={{ width: `${Math.max(2, (p[by] / max) * 100)}%` }} />
                  </div>
                  <div className="mt-1 text-[13px] text-slate-600 tabular-nums">{sub}</div>
                </div>
                {d != null && <Pill tone={deltaTone(d)} className="shrink-0">{fmtDelta(d)}</Pill>}
              </li>
            );
          })}
        </ol>
      )}
    </Card>
  );
}
