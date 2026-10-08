import { useState } from 'react';
import { AlertTriangle, CheckCircle2, Inbox, Info, Loader2 } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { Button } from './Button';
import Modal from './Modal';

// Single notification surface for the whole admin — green when something
// succeeded, red for a rejection or an error, and nothing else. It sits above
// every overlay on purpose: most warnings are raised while a modal is open
// (a rejected device, a failed save), and underneath the dialogs the operator
// would see nothing happen at all.
//
// Rendered on the login screen too, which returns before the main tree, so
// sign-in failures get the same treatment instead of a system alert().
export function Toast({ toast, onClose }) {
  if (!toast) return null;
  const isError = toast.type === 'error';
  return (
    <div
      onClick={onClose}
      role={isError ? 'alert' : 'status'}
      className={`fixed bottom-24 lg:bottom-6 left-1/2 -translate-x-1/2 px-5 py-3 rounded-[12px] font-semibold text-white shadow-2xl z-[300] max-w-[92vw] sm:max-w-md flex items-start gap-2 cursor-pointer ${isError ? 'bg-rose-700' : 'bg-emerald-700'}`}
    >
      <span className="shrink-0 mt-0.5">
        {isError ? <AlertTriangle size={16} /> : <CheckCircle2 size={16} />}
      </span>
      <span className="text-sm leading-snug">{toast.message}</span>
    </div>
  );
}

// Confirmation for any action, not only deletes: the caller names the button
// and its colour. The dialog stays open with a spinner until onYes finishes,
// so a second tap cannot fire the action twice.
//
// In-app instead of window.confirm(). The native dialog is a trap here: after
// a few of them the browser offers "prevent this page from creating more
// dialogs", and once the operator ticks it confirm() returns false instantly —
// the delete button then does nothing at all, silently, for the session.
export function ConfirmDialog({ action, onClose }) {
  const { t } = useTranslation();
  const [busy, setBusy] = useState(false);
  if (!action) return null;
  const tone = action.tone ?? 'danger';
  async function yes() {
    setBusy(true);
    try { await action.onYes(); } finally { setBusy(false); onClose(); }
  }
  return (
    <Modal
      title={action.title}
      onClose={busy ? () => {} : onClose}
      dismissable={!busy}
      size="sm"
      layer={130}
      onSubmit={yes}
      footer={(
        <>
          <Button variant="secondary" onClick={onClose} disabled={busy}>{t('cancel')}</Button>
          <Button type="submit" variant={tone === 'danger' ? 'danger' : tone === 'warning' ? 'warning' : 'primary'} loading={busy}>
            {action.yesLabel ?? t('delete_forever')}
          </Button>
        </>
      )}
    >
      {action.subject && <p className="font-bold text-ink mb-2 break-words">{action.subject}</p>}
      <p className="text-sm text-slate-700 leading-relaxed">{action.message}</p>
      {action.warning && (
        <p className="mt-3 text-sm font-semibold text-rose-800 bg-rose-50 border border-rose-200 rounded-[8px] p-3">{action.warning}</p>
      )}
    </Modal>
  );
}

export function Spinner({ className = 'py-16', size = 28 }) {
  const { t } = useTranslation();
  return (
    <div className={`flex justify-center ${className}`} role="status" aria-label={t('loading_short')}>
      <Loader2 className="animate-spin text-brand" size={size} />
    </div>
  );
}

// Grey placeholder rows while a list loads, instead of the "nothing here"
// message the machine list used to show for its first second.
export function SkeletonRows({ rows = 4 }) {
  const { t } = useTranslation();
  return (
    <div className="flex flex-col gap-2.5" aria-busy="true" aria-label={t('loading_short')}>
      {Array.from({ length: rows }, (_, i) => (
        <div key={i} className="flex items-center gap-3 p-3 rounded-[12px] bg-white border border-slate-200 animate-pulse">
          <div className="w-10 h-10 rounded-[8px] bg-slate-200 shrink-0" />
          <div className="flex-1 flex flex-col gap-2">
            <div className="h-3 rounded bg-slate-200" style={{ width: `${55 + ((i * 17) % 30)}%` }} />
            <div className="h-2.5 rounded bg-slate-100 w-2/5" />
          </div>
        </div>
      ))}
    </div>
  );
}

// One empty state for every list. There used to be three: italic grey text,
// an uppercase tracked line, and a dashed box.
export function EmptyState({ icon: Icon = Inbox, title, hint, action }) {
  return (
    <div className="flex flex-col items-center text-center gap-2 py-12 px-4">
      <div className="w-12 h-12 rounded-full bg-brand-soft text-brand-dark flex items-center justify-center mb-1">
        <Icon size={22} />
      </div>
      <p className="text-base font-bold text-ink">{title}</p>
      {hint && <p className="text-sm text-slate-600 max-w-sm">{hint}</p>}
      {action && <div className="mt-2">{action}</div>}
    </div>
  );
}

const BANNER = {
  info: { box: 'bg-blue-50 border-blue-200 text-blue-900', icon: Info },
  warning: { box: 'bg-amber-50 border-amber-300 text-amber-900', icon: AlertTriangle },
  danger: { box: 'bg-rose-50 border-rose-200 text-rose-900', icon: AlertTriangle },
};

export function Banner({ tone = 'info', title, children, action }) {
  const b = BANNER[tone] ?? BANNER.info;
  const Icon = b.icon;
  return (
    <div className={`flex flex-wrap items-start gap-x-3 gap-y-2 rounded-[12px] border px-4 py-3 ${b.box}`}>
      <Icon size={18} className="shrink-0 mt-0.5" />
      <div className="flex-1 min-w-[12rem] text-sm leading-relaxed">
        {title && <span className="font-bold">{title} </span>}
        {children}
      </div>
      {action}
    </div>
  );
}
