import { useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Card, CardHeader } from '../ui/Card';
import { money } from '../lib/machines';

// Revenue bars for the selected period: hours for "today", days otherwise.
// Plain SVG, no chart library; a tap, hover or focus shows the bar's numbers.
// The scale is written on the left (0, half, top) so the bars read without
// hovering. Keyboard: Tab enters the chart, the arrows walk the bars.
export function RevenueChart({ buckets, currency, note, subtitle }) {
  const { t } = useTranslation();
  const [hover, setHover] = useState(null);
  const [focus, setFocus] = useState(null);
  const barRefs = useRef([]);
  const max = Math.max(1, ...buckets.map((b) => b.value));
  const n = buckets.length;
  const W = 100, H = 40, gap = n > 40 ? 0.15 : 0.6;
  const bw = W / n - gap;
  const every = Math.ceil(n / 8);
  const h = hover != null ? buckets[hover] : null;
  const peak = buckets.reduce((best, b, i) => (b.value > (buckets[best]?.value ?? -1) ? i : best), 0);
  // One tab stop for the whole row of bars: the peak, or wherever focus is.
  const stop = focus ?? peak;
  const walk = (e, i) => {
    const to = e.key === 'ArrowRight' ? i + 1 : e.key === 'ArrowLeft' ? i - 1 : e.key === 'Home' ? 0 : e.key === 'End' ? n - 1 : null;
    if (to == null || to < 0 || to >= n) return;
    e.preventDefault();
    barRefs.current[to]?.focus();
  };
  return (
    <Card className="p-5">
      <CardHeader title={t('chart_revenue')} subtitle={subtitle} />
      <div className="mt-2 min-h-6 text-sm font-semibold text-slate-700 tabular-nums" aria-live="polite">
        {h ? <>{h.tip}: <span className="text-brand-dark">{money(h.value)} {currency}</span> · {h.count} {t('orders_short')}</> : note}
      </div>
      <div className="mt-2 grid grid-cols-[auto_minmax(0,1fr)] gap-x-2">
        <div className="h-44 flex flex-col justify-between text-xs font-medium text-slate-600 tabular-nums text-right" aria-hidden="true">
          <span>{money(max)}</span>
          <span>{money(max / 2)}</span>
          <span>0</span>
        </div>
        <svg
          viewBox={`0 0 ${W} ${H}`}
          preserveAspectRatio="none"
          className="w-full h-44"
          onMouseLeave={() => setHover(null)}
          role="group"
          aria-label={t('chart_revenue')}
        >
          {[0.25, 0.5, 0.75].map((f) => (
            <line key={f} x1="0" x2={W} y1={H * f} y2={H * f} className="stroke-slate-200" strokeWidth="0.15" />
          ))}
          <line x1="0" y1={H - 0.1} x2={W} y2={H - 0.1} className="stroke-slate-300" strokeWidth="0.2" />
          {buckets.map((b, i) => {
            const bh = b.value > 0 ? Math.max(0.6, (b.value / max) * (H - 2)) : 0;
            const x = i * (W / n) + gap / 2;
            const on = hover === i;
            return (
              <g
                key={i}
                ref={(el) => { barRefs.current[i] = el; }}
                role="img"
                aria-label={`${b.tip}: ${money(b.value)} ${currency}, ${b.count} ${t('orders_short')}`}
                tabIndex={i === stop ? 0 : -1}
                onMouseEnter={() => setHover(i)}
                onClick={() => setHover(on ? null : i)}
                onFocus={() => { setFocus(i); setHover(i); }}
                onBlur={() => { setFocus(null); setHover(null); }}
                onKeyDown={(e) => walk(e, i)}
                className="cursor-pointer outline-none"
              >
                <rect x={x} y="0" width={bw} height={H} fill="transparent" />
                <rect
                  x={x} y={H - bh} width={bw} height={bh} rx="0.4"
                  className={on || (hover == null && i === peak) ? 'fill-brand-dark' : 'fill-blue-400'}
                  stroke={focus === i ? 'currentColor' : 'none'} strokeWidth="2" vectorEffect="non-scaling-stroke"
                />
              </g>
            );
          })}
        </svg>
        <div />
        <div className="flex mt-1.5 text-xs font-medium text-slate-600 tabular-nums" aria-hidden="true">
          {buckets.map((b, i) => (
            <span key={i} className="flex-1 text-center truncate">{i % every === 0 ? b.label : ''}</span>
          ))}
        </div>
      </div>
    </Card>
  );
}

// Net revenue by machine as horizontal bars, top eight.
export function MachineBars({ rows, nameFor, currency }) {
  const { t } = useTranslation();
  const top = rows.slice(0, 8);
  const max = Math.max(1, ...top.map((r) => r.value));
  return (
    <Card className="p-5">
      <CardHeader title={t('chart_by_machine')} subtitle={t('chart_by_machine_hint', { currency })} />
      <ul className="mt-4 flex flex-col gap-3">
        {top.map((r) => (
          <li key={r.id}>
            <div className="flex justify-between gap-3 text-sm">
              <span className="font-semibold text-ink truncate">{nameFor(r.id)}</span>
              <span className="font-bold tabular-nums whitespace-nowrap">{money(r.value)} {currency}</span>
            </div>
            <div className="h-2 mt-1.5 rounded-full bg-slate-100 overflow-hidden">
              <div className="h-full rounded-full bg-brand" style={{ width: `${Math.max(2, (r.value / max) * 100)}%` }} />
            </div>
          </li>
        ))}
      </ul>
    </Card>
  );
}

// Colours live in index.css (--chart-1…6, --chart-rest) so a re-skin touches one file.
const DONUT = [1, 2, 3, 4, 5, 6].map((n) => `var(--chart-${n})`);

// Share of revenue by category: five biggest plus "other".
export function CategoryDonut({ rows, nameFor, currency, orders }) {
  const { t } = useTranslation();
  const total = rows.reduce((s, r) => s + r.value, 0);
  if (!total) return null;
  const head = rows.slice(0, 5);
  const rest = rows.slice(5).reduce((s, r) => s + r.value, 0);
  const parts = [
    ...head.map((r, i) => ({ label: nameFor(r.categoryId), value: r.value, color: DONUT[i] })),
    ...(rest ? [{ label: t('category_other'), value: rest, color: 'var(--chart-rest)' }] : []),
  ];
  let acc = 0;
  const stops = parts.map((p) => {
    const from = (acc / total) * 100;
    acc += p.value;
    return `${p.color} ${from}% ${(acc / total) * 100}%`;
  }).join(', ');
  return (
    <Card className="p-5">
      <CardHeader title={t('chart_by_category')} subtitle={t('chart_by_category_hint')} />
      <div className="mt-5 flex flex-wrap items-center gap-7">
        <div
          className="w-40 h-40 rounded-full flex items-center justify-center shrink-0"
          style={{ background: `conic-gradient(${stops})` }}
          role="img"
          aria-label={parts.map((p) => `${p.label} ${Math.round((p.value / total) * 100)}%`).join(', ')}
        >
          <div className="w-[104px] h-[104px] rounded-full bg-white flex flex-col items-center justify-center">
            <span className="text-2xl font-extrabold tabular-nums">{orders}</span>
            <span className="text-[13px] text-slate-600">{t('orders_word', { count: orders })}</span>
          </div>
        </div>
        <ul className="flex flex-col gap-2.5 min-w-0 flex-1">
          {parts.map((p) => (
            <li key={p.label} className="flex gap-2.5 min-w-0">
              <span className="w-3 h-3 rounded-full mt-1 shrink-0" style={{ background: p.color }} />
              <span className="min-w-0">
                <span className="block text-sm font-bold truncate">{p.label}</span>
                <span className="text-[13px] text-slate-600 tabular-nums">{money(p.value)} {currency} ({Math.round((p.value / total) * 100)}%)</span>
              </span>
            </li>
          ))}
        </ul>
      </div>
    </Card>
  );
}
