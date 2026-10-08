import { useId, useState } from 'react';
import { Eye, EyeOff, Search, X } from 'lucide-react';
import { useTranslation } from 'react-i18next';

// Shared look of every text input, select and textarea. The focus ring is the
// point: 21 fields had `outline-none` and nothing in its place, so a keyboard
// user could not see where they were.
export const inputCls =
  'w-full min-h-11 px-3.5 rounded-[10px] border border-slate-300 bg-white text-[15px] text-ink placeholder-slate-400 ' +
  'focus:outline-none focus:border-brand focus:ring-3 focus:ring-blue-200 disabled:bg-slate-100 disabled:text-slate-500 ' +
  'aria-[invalid=true]:border-rose-500 aria-[invalid=true]:bg-rose-50';

/**
 * A labelled field. The label is a real <label for>, so tapping it focuses
 * the input and a screen reader reads it; about half the panel's labels were
 * loose text next to their inputs.
 *
 * `children` receives `{ id, describedBy, invalid }` when it is a function, for
 * inputs that need more than the default <input>.
 */
export function Field({ label, hint, error, className = '', children, ...inputProps }) {
  const id = useId();
  const hintId = `${id}-hint`;
  const describedBy = error || hint ? hintId : undefined;
  return (
    <div className={`flex flex-col gap-1.5 ${className}`}>
      {label && <label htmlFor={id} className={`text-sm font-semibold ${error ? 'text-rose-700' : 'text-slate-700'}`}>{label}</label>}
      {typeof children === 'function'
        ? children({ id, describedBy, invalid: !!error })
        : children ?? <input id={id} aria-describedby={describedBy} aria-invalid={error ? true : undefined} className={inputCls} {...inputProps} />}
      {(error || hint) && (
        <p id={hintId} className={`text-[13px] leading-snug ${error ? 'font-semibold text-rose-700' : 'text-slate-600'}`}>{error || hint}</p>
      )}
    </div>
  );
}

export function PasswordInput({ id, className = '', ...rest }) {
  const { t } = useTranslation();
  const [shown, setShown] = useState(false);
  return (
    <div className="relative">
      <input id={id} type={shown ? 'text' : 'password'} className={`${inputCls} pr-12 ${className}`} {...rest} />
      <button
        type="button"
        onClick={() => setShown((v) => !v)}
        aria-label={shown ? t('password_hide') : t('password_show')}
        aria-pressed={shown}
        className="absolute right-1 top-1/2 -translate-y-1/2 w-10 h-10 inline-flex items-center justify-center rounded-[8px] text-slate-500 hover:text-slate-800 hover:bg-slate-100 focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-200"
      >
        {shown ? <EyeOff size={18} /> : <Eye size={18} />}
      </button>
    </div>
  );
}

// Search box with a clear button. `label` is read by screen readers only —
// the magnifier and the placeholder say the same thing to a sighted user.
export function SearchInput({ value, onChange, placeholder, label, className = '' }) {
  const { t } = useTranslation();
  const id = useId();
  return (
    <div className={`relative ${className}`}>
      <label htmlFor={id} className="sr-only">{label ?? placeholder}</label>
      <Search size={17} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-500 pointer-events-none" />
      <input
        id={id}
        type="search"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
        className={`${inputCls} pl-10 pr-10 bg-slate-50 [&::-webkit-search-cancel-button]:hidden`}
      />
      {value && (
        <button
          type="button"
          onClick={() => onChange('')}
          aria-label={t('search_clear')}
          className="absolute right-1.5 top-1/2 -translate-y-1/2 w-8 h-8 inline-flex items-center justify-center rounded-[8px] bg-slate-200/70 text-slate-600 hover:bg-slate-300"
        >
          <X size={14} />
        </button>
      )}
    </div>
  );
}

// Case- and space-insensitive "contains" over a few fields of a row.
export function matches(needle, ...fields) {
  const q = (needle || '').trim().toLowerCase();
  if (!q) return true;
  return fields.some((v) => v != null && String(v).toLowerCase().includes(q));
}
