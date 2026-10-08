import { AlertTriangle, CheckCircle2, Loader2, XCircle } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { Button } from '../ui/Button';
import { money } from '../lib/machines';
import { formatSaleDate, resultLabel, saleOutcome, saleSlotLabel, summarizeSaleItems } from '../lib/sales';

function SlotBadge({ slot, screen }) {
  const { t } = useTranslation();
  return (
    <span
      title={screen ? t('cell_number') : t('slot_in_machine')}
      className="shrink-0 px-2 py-0.5 rounded-md bg-sidebar text-white font-bold text-xs tabular-nums"
    >
      {slot}
    </span>
  );
}

/**
 * One receipt in the sales list.
 *
 * The heading is the goods, not the machine: 332 of 400 receipts hold exactly
 * one line, so a one-line card says everything — item, status, cell, amount.
 * Longer receipts list their lines below (not grouped: two lines of the same
 * product can differ in result_code, and that is what the list is for) and
 * fold after two, keeping every failed line visible.
 */
export default function SaleCard({ sale, market, layout, currency, open, onToggle, onRestoreStock }) {
  const { t, i18n } = useTranslation();
  const items = sale.sales_items || [];
  // `dispensed` defaults to TRUE in the DB, so an item is considered failed
  // only when it's explicitly false.
  const failedItems = items.filter(i => i.dispensed === false);
  const { groups, totalUnits } = summarizeSaleItems(items);
  // Full contents go to the tooltip: only so much fits the heading line.
  const itemsTitle = groups
    .map(g => {
      const name = g.name || t('deleted_product');
      return g.units > 1 ? `${name} ×${g.units}` : name;
    })
    .join(', ');
  // The cell goes into the header only when exactly one line failed: with two
  // or more the cells differ, and one of them would mislead.
  const failedSlot = failedItems.length === 1
    ? saleSlotLabel(failedItems[0].inventory?.motor_id, market?.kind, layout)
    : null;
  const single = items.length === 1 ? items[0] : null;
  const singleSlot = single ? saleSlotLabel(single.inventory?.motor_id, market?.kind, layout) : null;
  const refundSlot = single ? null : failedSlot;
  const screen = market?.kind === 'micromarket_screen';

  // One status per sale, one colour: the strip on the left and the pill say
  // the same thing.
  const outcome = saleOutcome(sale);
  const refundText = `${refundSlot ? `${refundSlot} · ` : ''}${t('refund_due')}: ${money(outcome.refund)} ${currency}`;
  const tone = {
    ok: { strip: 'bg-emerald-500', pill: 'bg-emerald-100 text-emerald-800', icon: CheckCircle2, text: t('sale_ok') },
    partial: { strip: 'bg-rose-500', pill: 'bg-rose-100 text-rose-800', icon: AlertTriangle, text: refundText },
    failed: { strip: 'bg-rose-500', pill: 'bg-rose-100 text-rose-800', icon: XCircle, text: refundText },
    pending: { strip: 'bg-amber-400', pill: 'bg-amber-100 text-amber-900', icon: Loader2, text: t('door_pending') },
    progress: { strip: 'bg-amber-400', pill: 'bg-amber-100 text-amber-900', icon: AlertTriangle, text: t('sale_in_progress') },
    restored: { strip: 'bg-slate-300', pill: 'bg-slate-100 text-slate-700', icon: CheckCircle2, text: t('stock_restored') },
  }[outcome.state];
  const StatusIcon = tone.icon;
  const doorBad = sale.door_status === 'failed' || sale.door_status === 'no_ack';
  const visibleItems = open ? items : items.filter((it, i) => i < 2 || it.dispensed === false);
  const hiddenCount = items.length - visibleItems.length;

  return (
    <li className="relative flex bg-white border border-slate-200 rounded-[12px] overflow-hidden shadow-card">
      <span className={`w-1 shrink-0 ${tone.strip}`} aria-hidden="true" />
      <div className="flex-1 min-w-0 p-3 sm:p-4">
        <div className="flex justify-between items-start gap-3">
          <div className="min-w-0 flex-1">
            <div className="text-[15px] font-bold text-ink truncate" title={itemsTitle || undefined}>
              {groups.length === 0 ? (
                <span className="font-semibold italic text-slate-500" title={t('sale_no_items_hint')}>{t('sale_no_items')}</span>
              ) : itemsTitle}
            </div>
            <div className="flex flex-wrap items-center gap-x-2 text-[13px] text-slate-600 tabular-nums mt-0.5">
              <span className="truncate">{sale.micromarkets?.name || `${t('apparatus_no')}${sale.micromarket_id}`}</span>
              <span>· {totalUnits} {t('items_short')}</span>
              {/* select-all: the payment number is matched against the bank
                  statement when refunding, one gesture should select it. */}
              {sale.payment_id && (
                <span className="font-mono text-xs text-slate-500 select-all break-all" title={t('payment_id')}>
                  · #{sale.payment_id}
                </span>
              )}
            </div>
            {single && single.dispensed === false && (
              <div className="mt-1 text-[13px] font-semibold text-rose-700 truncate" title={resultLabel(t, single)}>
                {resultLabel(t, single)}
              </div>
            )}
            {/* Realtime boards: the sale is written when the money is taken,
                the door opens after. failed / no_ack mean "paid, door stayed
                shut" — the owner refunds by hand (no refund API at LV). */}
            {doorBad && (
              <div className="mt-1.5 flex flex-wrap items-center gap-2">
                <span className="text-[13px] font-semibold text-rose-700" title={t('door_failed_hint')}>
                  {t(`door_${sale.door_status}`)}
                </span>
                {!sale.stock_restored_at && (
                  <Button size="sm" variant="secondary" onClick={() => onRestoreStock(sale)}>
                    {t('restore_stock')}
                  </Button>
                )}
              </div>
            )}
          </div>
          <div className="flex items-center gap-3 shrink-0">
            {single && (
              <div className="flex items-center gap-2">
                {single.dispensed === false
                  ? <XCircle size={18} className="text-rose-600" aria-label={t('dispense_failed')} />
                  : <CheckCircle2 size={18} className="text-emerald-600" aria-label={t('sale_ok')} />}
                {singleSlot && <SlotBadge slot={singleSlot} screen={screen} />}
              </div>
            )}
            <div className="text-right">
              <div className={`text-lg font-extrabold tabular-nums whitespace-nowrap ${outcome.state === 'failed' ? 'text-slate-400 line-through' : 'text-ink'}`}>
                {money(sale.amount)} <span className="text-sm">{currency}</span>
              </div>
              <div className="text-[13px] text-slate-600 tabular-nums whitespace-nowrap">
                {formatSaleDate(sale.created_at, i18n.language)}
              </div>
            </div>
          </div>
        </div>
        {outcome.state !== 'ok' && (
          <div className={`mt-2 inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[13px] font-semibold ${tone.pill}`}>
            <StatusIcon size={13} className={outcome.state === 'pending' ? 'animate-spin' : ''} />
            {tone.text}
          </div>
        )}

        {!single && items.length > 0 && (
          <div className="space-y-2.5 mt-3 pt-3 border-t border-slate-100">
            {visibleItems.map(item => {
              const failed = item.dispensed === false;
              const slot = saleSlotLabel(item.inventory?.motor_id, market?.kind, layout);
              return (
                <div key={item.id} className="flex justify-between items-center gap-3 text-sm pb-2.5 border-b border-slate-100 last:border-0 last:pb-0">
                  <div className="flex items-start gap-2 min-w-0 flex-1">
                    <span className="shrink-0 min-w-7 h-6 px-1.5 bg-slate-100 border border-slate-200 rounded-md flex items-center justify-center font-bold text-xs text-slate-700 tabular-nums">
                      ×{item.quantity}
                    </span>
                    {failed
                      ? <XCircle size={15} className="shrink-0 mt-0.5 text-rose-600" />
                      : <CheckCircle2 size={15} className="shrink-0 mt-0.5 text-emerald-600" />}
                    <div className="min-w-0 flex-1">
                      <div className="font-semibold text-ink truncate">{item.product_name || item.inventory?.name || item.inventory?.products?.name || t('deleted_product')}</div>
                      {failed && <div className="text-xs font-semibold text-rose-700 mt-0.5 truncate">{resultLabel(t, item)}</div>}
                    </div>
                  </div>
                  {slot && <SlotBadge slot={slot} screen={screen} />}
                  <span className={`font-bold ml-1 whitespace-nowrap tabular-nums ${failed ? 'text-rose-600 line-through opacity-80' : 'text-ink'}`}>{money(item.price * item.quantity)} {currency}</span>
                </div>
              );
            })}
            {(hiddenCount > 0 || (open && items.length > 2)) && (
              <button
                type="button"
                onClick={onToggle}
                aria-expanded={open}
                className="text-sm font-semibold text-brand-dark hover:underline min-h-9"
              >
                {open ? t('show_less') : t('show_more_n', { n: hiddenCount })}
              </button>
            )}
          </div>
        )}
      </div>
    </li>
  );
}
