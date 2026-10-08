import { useEffect, useId, useRef } from 'react';
import { X } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { IconButton } from './Button';

// Open dialogs, innermost last. Escape closes only the top one: the catalog
// picker sits on the inventory form, and one key press must not close both.
const stack = [];

const FOCUSABLE = 'input:not([type=hidden]):not([disabled]), select:not([disabled]), textarea:not([disabled]), button:not([disabled]), [href], [tabindex]:not([tabindex="-1"])';

/**
 * The one dialog shell of the panel. It used to be twenty hand-written
 * `fixed inset-0` overlays with four different backdrops, ad-hoc z-indexes,
 * no Escape and no dialog role, so a screen reader announced none of them.
 *
 * - Escape and a click on the backdrop close it (`dismissable={false}` for a
 *   dialog that must not vanish mid-save).
 * - Focus moves into the dialog — the first field, else the first button —
 *   and goes back to whatever opened it once it closes.
 * - `onSubmit` wraps the body in a <form>, so Enter submits and the footer's
 *   `type="submit"` button is the default action.
 * - `mobile="sheet"` docks it to the bottom on a phone, `"full"` takes the
 *   whole screen with the footer pinned (long forms), `"center"` keeps it a card.
 * - `layer` orders stacked dialogs: 100 base, 110 a picker over a form,
 *   120 the cropper, 130 confirmations. The toast sits at 300 above them all.
 */
export default function Modal({
  title,
  subtitle,
  onClose,
  onSubmit,
  footer,
  children,
  size = 'md',
  mobile = 'center',
  layer = 100,
  dismissable = true,
  bodyClassName = 'px-5 sm:px-6 py-5',
  labelledBy,
}) {
  const { t } = useTranslation();
  const titleId = useId();
  const ref = useRef(null);
  const closeRef = useRef(null);
  useEffect(() => { closeRef.current = dismissable ? onClose : null; });

  useEffect(() => {
    const token = {};
    stack.push(token);
    const opener = document.activeElement;
    const root = ref.current;
    // Fields first: a dialog that opens to type into should be ready to type.
    const first = root?.querySelector('input:not([type=hidden]):not([disabled]), select, textarea')
      ?? root?.querySelector(FOCUSABLE);
    first?.focus({ preventScroll: true });

    const prevOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';

    const onKey = (e) => {
      if (stack[stack.length - 1] !== token) return;
      if (e.key === 'Escape') {
        e.stopPropagation();
        closeRef.current?.();
        return;
      }
      // Keep Tab inside the dialog.
      if (e.key === 'Tab' && root) {
        const items = [...root.querySelectorAll(FOCUSABLE)].filter((el) => el.offsetParent !== null);
        if (!items.length) return;
        const firstEl = items[0], lastEl = items[items.length - 1];
        if (e.shiftKey && document.activeElement === firstEl) { e.preventDefault(); lastEl.focus(); }
        else if (!e.shiftKey && document.activeElement === lastEl) { e.preventDefault(); firstEl.focus(); }
      }
    };
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('keydown', onKey);
      const i = stack.indexOf(token);
      if (i >= 0) stack.splice(i, 1);
      if (!stack.length) document.body.style.overflow = prevOverflow;
      if (opener && typeof opener.focus === 'function' && document.contains(opener)) opener.focus({ preventScroll: true });
    };
  }, []);

  const width = { sm: 'sm:max-w-sm', md: 'sm:max-w-md', lg: 'sm:max-w-lg', xl: 'sm:max-w-4xl' }[size] ?? 'sm:max-w-md';
  const place = {
    center: 'items-center justify-center p-4',
    sheet: 'items-end sm:items-center justify-center sm:p-4',
    full: 'sm:items-center sm:justify-center sm:p-4',
  }[mobile];
  const panel = {
    center: 'rounded-2xl max-h-[90dvh]',
    sheet: 'rounded-t-2xl sm:rounded-2xl max-h-[92dvh]',
    full: 'h-full sm:h-auto sm:rounded-2xl sm:max-h-[90dvh]',
  }[mobile];

  const Body = onSubmit ? 'form' : 'div';
  const bodyProps = onSubmit
    ? { onSubmit: (e) => { e.preventDefault(); onSubmit(e); }, noValidate: true }
    : {};

  return (
    <div
      className={`fixed inset-0 flex ${place} bg-sidebar/60 backdrop-blur-[2px]`}
      style={{ zIndex: layer }}
      onMouseDown={(e) => { if (e.target === e.currentTarget) closeRef.current?.(); }}
    >
      <div
        ref={ref}
        role="dialog"
        aria-modal="true"
        aria-labelledby={labelledBy ?? (title ? titleId : undefined)}
        className={`admin-ui bg-white w-full ${width} ${panel} shadow-2xl flex flex-col overflow-hidden text-ink`}
      >
        <Body className="flex flex-col min-h-0 flex-1" {...bodyProps}>
          {title != null && (
            <div className="flex items-start justify-between gap-3 px-5 sm:px-6 py-4 border-b border-slate-200 shrink-0">
              <div className="min-w-0">
                <h2 id={titleId} className="text-lg font-bold text-ink">{title}</h2>
                {subtitle && <p className="text-sm text-slate-600 mt-0.5 truncate">{subtitle}</p>}
              </div>
              {dismissable && <IconButton icon={X} label={t('close')} tone="plain" className="!bg-slate-100 -mr-1" onClick={onClose} />}
            </div>
          )}
          <div className={`flex-1 min-h-0 overflow-y-auto ${bodyClassName}`}>{children}</div>
          {footer && (
            <div className="shrink-0 flex flex-wrap justify-end gap-2 px-5 sm:px-6 py-3.5 border-t border-slate-200 bg-slate-50 pb-[max(0.875rem,env(safe-area-inset-bottom))]">
              {footer}
            </div>
          )}
        </Body>
      </div>
    </div>
  );
}
