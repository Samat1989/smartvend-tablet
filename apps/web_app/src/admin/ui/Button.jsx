import { Loader2 } from 'lucide-react';

// One set of buttons for the whole panel. Before these, 97 buttons were styled
// inline in a dozen variants; size, radius and colour now come from here.
// Phones get at least 40 px of touch target.
const BTN_TONES = {
  primary: 'bg-brand text-white border-brand hover:bg-brand-dark shadow-sm shadow-brand/20',
  dark: 'bg-sidebar text-white border-sidebar hover:bg-sidebar-active',
  secondary: 'bg-white text-slate-800 border-slate-300 hover:border-brand hover:text-brand-dark',
  soft: 'bg-blue-50 text-brand-dark border-blue-200 hover:bg-blue-100',
  danger: 'bg-rose-600 text-white border-rose-600 hover:bg-rose-700',
  success: 'bg-emerald-600 text-white border-emerald-600 hover:bg-emerald-700',
  warning: 'bg-amber-500 text-slate-900 border-amber-500 hover:bg-amber-400',
  'danger-outline': 'bg-white text-rose-700 border-rose-200 hover:bg-rose-50',
  ghost: 'bg-transparent text-slate-600 border-transparent hover:bg-slate-100 hover:text-slate-900',
};

const FOCUS = 'focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300';

export function Button({ variant = 'secondary', size = 'md', loading = false, icon: Icon, block = false, className = '', disabled, type = 'button', children, ...rest }) {
  const sz = size === 'sm'
    ? 'min-h-9 px-3 text-[13px] gap-1.5'
    : size === 'lg'
      ? 'min-h-12 px-5 text-[15px] gap-2'
      : 'min-h-10 px-4 text-sm gap-2';
  return (
    <button
      type={type}
      disabled={disabled || loading}
      className={`inline-flex items-center justify-center rounded-[10px] border font-bold whitespace-nowrap transition-all active:scale-[0.98] disabled:opacity-50 disabled:cursor-not-allowed disabled:active:scale-100 ${FOCUS} ${sz} ${BTN_TONES[variant] ?? BTN_TONES.secondary} ${block ? 'w-full' : ''} ${className}`}
      {...rest}
    >
      {loading ? <Loader2 size={size === 'sm' ? 14 : 16} className="animate-spin shrink-0" /> : Icon && <Icon size={size === 'sm' ? 14 : 16} className="shrink-0" />}
      {children}
    </button>
  );
}

// Icon-only button: the label is required and becomes the tooltip and the
// screen-reader name, so no icon is left unexplained.
export function IconButton({ icon: Icon, label, tone = 'default', loading = false, className = '', disabled, ...rest }) {
  const tones = {
    default: 'border-slate-300 text-slate-600 hover:text-brand-dark hover:border-brand',
    danger: 'border-rose-200 text-rose-700 hover:bg-rose-50 hover:border-rose-300',
    success: 'border-emerald-300 text-emerald-700 hover:text-brand-dark hover:border-brand',
    plain: 'border-transparent text-slate-500 hover:text-slate-800 hover:bg-slate-100',
  };
  return (
    <button
      type="button"
      title={label}
      aria-label={label}
      disabled={disabled || loading}
      className={`inline-flex items-center justify-center w-10 h-10 sm:w-9 sm:h-9 shrink-0 rounded-[10px] border transition-all disabled:opacity-40 disabled:cursor-not-allowed ${FOCUS} ${tones[tone] ?? tones.default} ${tone === 'plain' ? 'bg-transparent' : 'bg-white'} ${className}`}
      {...rest}
    >
      {loading ? <Loader2 size={16} className="animate-spin" /> : <Icon size={16} />}
    </button>
  );
}
