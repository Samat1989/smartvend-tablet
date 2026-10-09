import { useMemo, useState } from 'react';
import { ChevronLeft, ChevronRight } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { Button, IconButton } from './Button';
import Modal from './Modal';
import { dateLocale } from '../lib/sales';

// Dates travel as 'YYYY-MM-DD' strings (what <input type="date"> gave before),
// so they compare as plain strings and never shift with the time zone.
const pad = (n) => String(n).padStart(2, '0');
export const isoDay = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
export const parseDay = (s) => { const [y, m, d] = s.split('-').map(Number); return new Date(y, m - 1, d); };

const addDays = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };

/**
 * Calendar for the sales period: one month on screen, the arrows beside its
 * name page through months, the first click is the start of the period and
 * the second its end (picked backwards, the two swap). A third click starts
 * over. Days after today are off — there are no sales there yet.
 */
export default function DateRangeModal({ from, to, onApply, onClose }) {
  const { t, i18n } = useTranslation();
  const loc = dateLocale(i18n.language);
  const today = useMemo(() => { const d = new Date(); d.setHours(0, 0, 0, 0); return d; }, []);
  const todayIso = isoDay(today);

  const [start, setStart] = useState(from || '');
  const [end, setEnd] = useState(from ? (to || '') : '');
  const [view, setView] = useState(() => {
    const d = to ? parseDay(to) : from ? parseDay(from) : today;
    return { y: d.getFullYear(), m: d.getMonth() };
  });

  const presets = [
    { key: 'preset_today', s: today, e: today },
    { key: 'preset_yesterday', s: addDays(today, -1), e: addDays(today, -1) },
    { key: 'preset_7d', s: addDays(today, -6), e: today },
    { key: 'preset_30d', s: addDays(today, -29), e: today },
    { key: 'preset_this_month', s: new Date(today.getFullYear(), today.getMonth(), 1), e: today },
    { key: 'preset_last_month', s: new Date(today.getFullYear(), today.getMonth() - 1, 1), e: new Date(today.getFullYear(), today.getMonth(), 0) },
  ].map((p) => ({ ...p, s: isoDay(p.s), e: isoDay(p.e) }));

  function setRange(s, e) {
    setStart(s);
    setEnd(e);
    const d = parseDay(e);
    setView({ y: d.getFullYear(), m: d.getMonth() });
  }

  function pick(day) {
    if (!start || end) { setStart(day); setEnd(''); }
    else if (day < start) { setEnd(start); setStart(day); }
    else setEnd(day);
  }

  const atMax = view.y * 12 + view.m >= today.getFullYear() * 12 + today.getMonth();
  const shiftMonth = (n) => setView(({ y, m }) => {
    const d = new Date(y, m + n, 1);
    return { y: d.getFullYear(), m: d.getMonth() };
  });

  const monthName = new Intl.DateTimeFormat(loc, { month: 'long' }).format(new Date(view.y, view.m, 1));
  const monthTitle = `${monthName.charAt(0).toUpperCase()}${monthName.slice(1)} ${view.y}`;
  // 1 January 2024 was a Monday: the week starts there.
  const weekdays = Array.from({ length: 7 }, (_, i) => new Intl.DateTimeFormat(loc, { weekday: 'short' }).format(new Date(2024, 0, 1 + i)));

  const lead = (new Date(view.y, view.m, 1).getDay() + 6) % 7;
  const daysInMonth = new Date(view.y, view.m + 1, 0).getDate();
  const cells = [
    ...Array.from({ length: lead }, () => null),
    ...Array.from({ length: daysInMonth }, (_, i) => isoDay(new Date(view.y, view.m, i + 1))),
  ];

  const days = start && end ? Math.round((parseDay(end) - parseDay(start)) / 86400000) + 1 : 0;
  const hint = !start ? t('period_hint_start') : !end ? t('period_hint_end') : t('period_hint_days', { n: days });

  return (
    <Modal
      title={t('period')}
      onClose={onClose}
      size="sm"
      mobile="sheet"
      bodyClassName="px-4 sm:px-5 py-4 flex flex-col gap-4"
      footer={(
        <>
          <Button variant="secondary" onClick={onClose} className="min-h-11">{t('cancel')}</Button>
          <Button variant="primary" disabled={!end} onClick={() => onApply(start, end)} className="min-h-11 flex-1 sm:flex-none">
            {t('apply')}
          </Button>
        </>
      )}
    >
      <div role="group" aria-label={t('period')} className="flex flex-wrap gap-1.5">
        {presets.map((p) => {
          const on = p.s === start && p.e === end;
          return (
            <button
              key={p.key}
              type="button"
              aria-pressed={on}
              onClick={() => setRange(p.s, p.e)}
              className={`min-h-9 px-3 rounded-full border text-[13px] font-semibold whitespace-nowrap transition-colors focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300 ${on ? 'bg-brand border-brand text-white' : 'bg-white border-slate-300 text-slate-700 hover:border-slate-400 hover:bg-slate-50'}`}
            >
              {t(p.key)}
            </button>
          );
        })}
      </div>

      <div className="flex items-center justify-between gap-2 border-t border-slate-200 pt-3">
        <IconButton icon={ChevronLeft} label={t('prev_month')} onClick={() => shiftMonth(-1)} className="!w-11 !h-11" />
        <span aria-live="polite" className="text-base font-extrabold">{monthTitle}</span>
        <IconButton icon={ChevronRight} label={t('next_month')} disabled={atMax} onClick={() => shiftMonth(1)} className="!w-11 !h-11" />
      </div>

      <div className="grid grid-cols-7 gap-y-1">
        {weekdays.map((w, i) => (
          <span key={w} className={`text-center text-xs font-bold pb-1 ${i >= 5 ? 'text-rose-700' : 'text-slate-500'}`}>{w}</span>
        ))}
        {cells.map((day, i) => {
          if (!day) return <span key={`lead-${i}`} aria-hidden="true" />;
          const edge = day === start || day === end;
          const inside = start && end && day > start && day < end;
          const future = day > todayIso;
          const isToday = day === todayIso;
          return (
            <button
              key={day}
              type="button"
              disabled={future}
              aria-pressed={edge || inside}
              aria-label={parseDay(day).toLocaleDateString(loc, { day: 'numeric', month: 'long', year: 'numeric' })}
              onClick={() => pick(day)}
              className={`h-11 text-sm tabular-nums transition-colors focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300 focus-visible:z-10 ${
                edge ? 'rounded-[10px] bg-brand text-white font-extrabold'
                  : inside ? 'bg-brand-soft text-brand-dark font-semibold'
                    : future ? 'rounded-[10px] text-slate-400 cursor-not-allowed'
                      : `rounded-[10px] text-ink hover:bg-slate-100 ${isToday ? 'font-extrabold ring-2 ring-inset ring-brand' : 'font-medium'}`
              }`}
            >
              {parseDay(day).getDate()}
            </button>
          );
        })}
      </div>

      <p className="text-[13px] text-slate-600" aria-live="polite">{hint}</p>
    </Modal>
  );
}
