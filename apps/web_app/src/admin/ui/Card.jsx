import { ChevronLeft, ChevronRight } from 'lucide-react';
import { useTranslation } from 'react-i18next';

export function Card({ children, className = '', as: Tag = 'section', ...rest }) {
  return (
    <Tag className={`bg-white border border-slate-200 rounded-[12px] shadow-card ${className}`} {...rest}>
      {children}
    </Tag>
  );
}

export function CardHeader({ title, subtitle, actions, className = '' }) {
  return (
    <div className={`flex flex-wrap items-start justify-between gap-3 ${className}`}>
      <div className="min-w-0">
        <h2 className="text-lg font-bold text-ink">{title}</h2>
        {subtitle && <p className="text-sm text-slate-600 mt-0.5">{subtitle}</p>}
      </div>
      {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
    </div>
  );
}

// Page title row: one size for every tab. Sales used text-xl in slate-800
// and every other tab text-2xl in slate-900.
export function PageHeader({ title, subtitle, actions, before }) {
  return (
    <div className="flex flex-col gap-3">
      {before}
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div className="min-w-0">
          <h1 className="text-2xl sm:text-[28px] font-extrabold text-ink leading-tight break-words">{title}</h1>
          {subtitle && <div className="mt-1 text-[15px] text-slate-600">{subtitle}</div>}
        </div>
        {actions && <div className="flex flex-wrap items-center gap-2 w-full sm:w-auto">{actions}</div>}
      </div>
    </div>
  );
}

const ACCENTS = {
  blue: { bar: 'bg-brand', soft: 'bg-blue-100 text-blue-800' },
  orange: { bar: 'bg-amber-500', soft: 'bg-amber-100 text-amber-900' },
  green: { bar: 'bg-emerald-600', soft: 'bg-emerald-100 text-emerald-800' },
  violet: { bar: 'bg-violet-600', soft: 'bg-violet-100 text-violet-800' },
  red: { bar: 'bg-rose-600', soft: 'bg-rose-100 text-rose-800' },
  slate: { bar: 'bg-slate-400', soft: 'bg-slate-100 text-slate-700' },
};

/**
 * Headline number with a coloured edge. `pill` is a short badge under the
 * number (a change in percent, a count); `note` the grey words after it.
 */
export function KpiCard({ label, value, pill, pillTone, note, accent = 'blue', icon: Icon, compact = false }) {
  const a = ACCENTS[accent] ?? ACCENTS.blue;
  const pa = ACCENTS[pillTone ?? accent] ?? a;
  return (
    <div className={`relative overflow-hidden bg-white border border-slate-200 rounded-[12px] shadow-card ${compact ? 'p-3 pl-4' : 'px-5 py-4 pl-6'}`}>
      <span className={`absolute left-0 inset-y-0 w-1 ${a.bar}`} aria-hidden="true" />
      <div className="flex items-start justify-between gap-2">
        <span className={`font-bold uppercase tracking-wider text-slate-600 ${compact ? 'text-[11px]' : 'text-xs'}`}>{label}</span>
        {Icon && !compact && (
          <span className={`w-8 h-8 rounded-full flex items-center justify-center shrink-0 ${a.soft}`} aria-hidden="true"><Icon size={16} /></span>
        )}
      </div>
      <div className={`font-extrabold text-ink tabular-nums mt-1 break-words ${compact ? 'text-xl' : 'text-[26px] leading-tight'}`}>{value}</div>
      {(pill != null || note) && (
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1 mt-2">
          {pill != null && <span className={`text-[13px] font-bold px-2.5 py-0.5 rounded-full ${pa.soft}`}>{pill}</span>}
          {note && <span className="text-[13px] text-slate-600">{note}</span>}
        </div>
      )}
    </div>
  );
}

// Status pill: green ok, amber waiting, red problem, grey neutral.
const PILL = {
  green: 'bg-emerald-100 text-emerald-800',
  amber: 'bg-amber-100 text-amber-900',
  red: 'bg-rose-100 text-rose-800',
  blue: 'bg-blue-100 text-blue-800',
  violet: 'bg-violet-100 text-violet-800',
  slate: 'bg-slate-100 text-slate-700',
};
export function Pill({ tone = 'slate', dot = false, children, className = '', title }) {
  return (
    <span title={title} className={`inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[13px] font-semibold whitespace-nowrap ${PILL[tone] ?? PILL.slate} ${className}`}>
      {dot && <span className="w-1.5 h-1.5 rounded-full bg-current" aria-hidden="true" />}
      {children}
    </span>
  );
}

/**
 * Page switcher for long lists. Shows 1 … 4 5 6 … 12 and a "1–25 of 184"
 * counter; `sizes` adds a page-size select.
 */
export function Pagination({ page, pageSize, total, onPage, sizes, onPageSize }) {
  const { t } = useTranslation();
  const pages = Math.max(1, Math.ceil(total / pageSize));
  if (total === 0) return null;
  const from = (page - 1) * pageSize + 1;
  const to = Math.min(total, page * pageSize);

  const nums = [];
  for (let p = 1; p <= pages; p++) {
    if (p === 1 || p === pages || Math.abs(p - page) <= 1) nums.push(p);
    else if (nums[nums.length - 1] !== '…') nums.push('…');
  }
  const btn = 'min-w-10 h-10 px-2 inline-flex items-center justify-center rounded-[8px] border text-sm font-semibold transition-colors focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300 disabled:opacity-40 disabled:cursor-not-allowed';

  return (
    <nav aria-label={t('pagination')} className="flex flex-wrap items-center justify-between gap-3">
      <div className="flex items-center gap-3 text-sm text-slate-600">
        <span className="tabular-nums">{t('page_range', { from, to, total })}</span>
        {sizes && onPageSize && (
          <label className="hidden sm:inline-flex items-center gap-2">
            {t('page_size')}
            <select
              value={pageSize}
              onChange={(e) => onPageSize(Number(e.target.value))}
              className="h-9 px-2 rounded-[8px] border border-slate-300 bg-white font-semibold text-ink focus:outline-none focus:ring-3 focus:ring-blue-200"
            >
              {sizes.map((s) => <option key={s} value={s}>{s}</option>)}
            </select>
          </label>
        )}
      </div>
      {pages > 1 && (
        <div className="flex items-center gap-1">
          <button type="button" className={`${btn} border-slate-300 bg-white text-ink hover:bg-slate-50`} onClick={() => onPage(page - 1)} disabled={page <= 1} aria-label={t('page_prev')}>
            <ChevronLeft size={18} />
          </button>
          {nums.map((n, i) => n === '…'
            ? <span key={`e${i}`} className="px-1 text-slate-500">…</span>
            : (
              <button
                key={n}
                type="button"
                onClick={() => onPage(n)}
                aria-current={n === page ? 'page' : undefined}
                className={`${btn} hidden sm:inline-flex ${n === page ? 'bg-brand border-brand text-white !inline-flex' : 'border-slate-300 bg-white text-ink hover:bg-slate-50'}`}
              >
                {n}
              </button>
            ))}
          <button type="button" className={`${btn} border-slate-300 bg-white text-ink hover:bg-slate-50`} onClick={() => onPage(page + 1)} disabled={page >= pages} aria-label={t('page_next')}>
            <ChevronRight size={18} />
          </button>
        </div>
      )}
    </nav>
  );
}
