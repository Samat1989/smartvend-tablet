// Filter chips and segmented switches. Category filters, sales periods and the
// catalog's state tabs were three hand-styled copies; they are one now, and
// each chip says whether it is on (aria-pressed), which none did before.

const CHIP_TONES = {
  default: {
    on: 'bg-brand border-brand text-white',
    off: 'bg-white border-slate-300 text-slate-700 hover:border-slate-400 hover:bg-slate-50',
  },
  warning: {
    on: 'bg-amber-700 border-amber-700 text-white',
    off: 'bg-amber-50 border-amber-300 text-amber-900 hover:bg-amber-100',
  },
  danger: {
    on: 'bg-rose-700 border-rose-700 text-white',
    off: 'bg-rose-50 border-rose-200 text-rose-800 hover:bg-rose-100',
  },
};

/**
 * Pill chips. `options`: [{ value, label, count?, tone?, icon? }].
 * `scroll` keeps them on one line and scrollable sideways (phones).
 */
export function ChipGroup({ options, value, onChange, label, scroll = false, className = '' }) {
  return (
    <div
      role="group"
      aria-label={label}
      className={`flex gap-2 ${scroll ? 'overflow-x-auto no-scrollbar -mx-4 px-4 sm:mx-0 sm:px-0 sm:flex-wrap' : 'flex-wrap'} ${className}`}
    >
      {options.map((o) => {
        const on = o.value === value;
        const tone = CHIP_TONES[o.tone ?? 'default'];
        const Icon = o.icon;
        return (
          <button
            key={String(o.value)}
            type="button"
            aria-pressed={on}
            onClick={() => onChange(o.value)}
            className={`shrink-0 inline-flex items-center gap-1.5 min-h-10 px-3.5 rounded-full border text-[13px] font-semibold whitespace-nowrap transition-colors focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300 ${on ? tone.on : tone.off}`}
          >
            {Icon && <Icon size={14} />}
            {typeof o.label === 'string' ? o.label.charAt(0).toUpperCase() + o.label.slice(1) : o.label}
            {o.count != null && <span className={on ? 'opacity-80' : 'opacity-70'}>· {o.count}</span>}
          </button>
        );
      })}
    </div>
  );
}

// Segmented control on a grey track — for a short, exclusive choice that reads
// as a view switch rather than a filter (periods, list/table).
export function Segmented({ options, value, onChange, label, className = '' }) {
  return (
    <div role="group" aria-label={label} className={`inline-flex flex-wrap gap-1 p-1 rounded-[12px] bg-slate-200/70 ${className}`}>
      {options.map((o) => {
        const on = o.value === value;
        return (
          <button
            key={String(o.value)}
            type="button"
            aria-pressed={on}
            onClick={() => onChange(o.value)}
            className={`flex-1 sm:flex-none min-h-9 px-3 rounded-[8px] text-[13px] font-semibold whitespace-nowrap transition-all focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300 ${on ? 'bg-white text-brand-dark shadow-sm' : 'text-slate-700 hover:text-ink'}`}
          >
            {o.label}
          </button>
        );
      })}
    </div>
  );
}

// Underlined tabs for a page split in two (Administration: devices / users).
export function Tabs({ options, value, onChange, label }) {
  return (
    <div role="tablist" aria-label={label} className="flex gap-1 border-b border-slate-300 overflow-x-auto no-scrollbar">
      {options.map((o) => {
        const on = o.value === value;
        return (
          <button
            key={o.value}
            type="button"
            role="tab"
            aria-selected={on}
            onClick={() => onChange(o.value)}
            className={`inline-flex items-center gap-2 min-h-11 px-4 text-[15px] whitespace-nowrap border-b-[3px] -mb-px transition-colors focus-visible:outline-none focus-visible:bg-blue-50 ${on ? 'border-brand text-brand-dark font-bold' : 'border-transparent text-slate-600 font-semibold hover:text-ink'}`}
          >
            {o.label}
            {o.count != null && (
              <span className={`text-xs px-2 py-0.5 rounded-full ${on ? 'bg-brand-soft text-brand-dark' : 'bg-slate-200 text-slate-700'}`}>{o.count}</span>
            )}
          </button>
        );
      })}
    </div>
  );
}
