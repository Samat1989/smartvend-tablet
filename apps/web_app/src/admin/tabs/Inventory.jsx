import { AlertTriangle, Image, Package, Pencil, Trash2 } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { IconButton } from '../ui/Button';
import { EmptyState } from '../ui/Feedback';
import { isLowStock, money } from '../lib/machines';

function Thumb({ p, size = 'w-12 h-12' }) {
  return (
    <div className={`${size} rounded-[8px] flex items-center justify-center overflow-hidden shrink-0 border border-slate-200 bg-white`}>
      {p?.image_url ? (
        <img src={p.image_url} alt="" loading="lazy" className="w-full h-full object-contain p-1" />
      ) : p?.emoji ? (
        <span className="text-2xl" aria-hidden="true">{p.emoji}</span>
      ) : (
        <Image className="text-slate-300" size={20} aria-hidden="true" />
      )}
    </div>
  );
}

// Stock as a number with its state: red when empty, amber when running low.
function StockValue({ stock, label }) {
  const s = stock ?? 0;
  const tone = s <= 0 ? 'bg-rose-100 text-rose-800' : isLowStock(s) ? 'bg-amber-100 text-amber-900' : 'bg-slate-100 text-ink';
  return (
    <div className="flex flex-col items-end shrink-0">
      <span className="hidden sm:block text-[11px] font-bold text-slate-600 uppercase tracking-wider">{label}</span>
      <span className={`text-base font-extrabold px-2 py-0.5 rounded-md tabular-nums ${tone}`}>{s}</span>
    </div>
  );
}

function PriceValue({ price, currency, label }) {
  return (
    <div className="flex flex-col items-end shrink-0 min-w-[72px]">
      <span className="hidden sm:block text-[11px] font-bold text-slate-600 uppercase tracking-wider">{label}</span>
      <span className="text-base font-extrabold text-brand-dark tabular-nums whitespace-nowrap">{money(price)} {currency}</span>
    </div>
  );
}

function SlotTag({ label, sub, twin, muted }) {
  return (
    <div className={`rounded-[8px] flex flex-col items-center justify-center shrink-0 px-2 py-1.5 min-w-[50px] sm:min-w-[60px] ${muted ? 'bg-white text-slate-400 border border-dashed border-slate-300' : 'bg-sidebar text-white'}`}>
      <span className="font-extrabold text-base leading-none tabular-nums">{label}</span>
      {sub && <span className="hidden sm:block text-[11px] font-semibold opacity-75 leading-none mt-1 tabular-nums">{sub}</span>}
      {twin && <span className="text-[10px] font-bold bg-amber-500 text-ink px-1 rounded mt-1 leading-tight">TWIN</span>}
    </div>
  );
}

/**
 * One position: slot or cell number, picture, name and category, stock and
 * price. The whole row opens the editor; pencil and bin are there for the
 * mouse and for clarity.
 */
export function ItemRow({ p, slot, category, currency, onEdit, onDelete, warn }) {
  const { t } = useTranslation();
  const tone = (p.stock ?? 0) <= 0 ? 'border-rose-200 bg-rose-50/40' : isLowStock(p.stock) ? 'border-amber-300 bg-amber-50/50' : 'border-slate-200 bg-white';
  return (
    <li
      onClick={() => onEdit(p)}
      className={`group flex items-center gap-3 p-2.5 sm:p-3 rounded-[12px] border ${tone} hover:border-brand hover:shadow-card cursor-pointer transition-all`}
    >
      {slot}
      <Thumb p={p} />
      <div className="flex-1 min-w-0">
        <div className="font-bold text-[15px] text-ink truncate">{p.name || '—'}</div>
        <div className="text-[13px] text-slate-600 truncate">{warn ?? category ?? t('no_category')}</div>
      </div>
      <StockValue stock={p.stock} label={t('stock_label')} />
      <PriceValue price={p.price} currency={currency} label={t('price_label')} />
      <div className="flex items-center gap-1 shrink-0">
        <IconButton icon={Pencil} label={t('edit')} className="hidden sm:inline-flex" onClick={(e) => { e.stopPropagation(); onEdit(p); }} />
        <IconButton icon={Trash2} label={t('delete')} tone="danger" onClick={(e) => { e.stopPropagation(); onDelete(p); }} />
      </div>
    </li>
  );
}

// Flat list: open-shelf machines always, and any machine while a search or a
// filter is on — a layout with most slots blanked by the filter read as if
// those slots were empty.
export function FlatInventory({ items, slotOf, catOf, currency, onEdit, onDelete, emptyTitle, emptyHint }) {
  if (!items.length) {
    return <EmptyState icon={Package} title={emptyTitle} hint={emptyHint} />;
  }
  return (
    <ul className="flex flex-col gap-2">
      {items.map((p) => (
        <ItemRow key={p.id} p={p} slot={slotOf?.(p)} category={catOf(p)} currency={currency} onEdit={onEdit} onDelete={onDelete} />
      ))}
    </ul>
  );
}

export function CellTag({ cell }) {
  return <SlotTag label={cell ?? '—'} muted={cell == null} />;
}

// ---- Inventory list driven by the per-machine layout ----
// Walks the layout shelf by shelf, one row per slot. Empty slots are still
// shown so the operator sees which spirals need restocking. Rows pointing at
// a motor that isn't in the layout get their own group at the bottom.
export function InventoryByLayout({ products, layout, catOf, currency, onEdit, onDelete }) {
  const { t } = useTranslation();
  const productByMotor = new Map();
  for (const p of products) {
    if (p.motor_id != null) productByMotor.set(Number(p.motor_id), p);
  }
  const mappedMotorIds = new Set();
  for (const sh of layout.shelves) {
    for (const sl of sh.slots) {
      for (const m of sl.motorIds) mappedMotorIds.add(m);
    }
  }
  const unassigned = products.filter(p => p.motor_id == null || !mappedMotorIds.has(Number(p.motor_id)));

  return (
    <div className="flex flex-col gap-6">
      {layout.shelves.map((shelf, idx) => (
        <section key={`${idx}-${shelf.label}`} aria-label={`${t('shelf')} ${idx + 1}`}>
          <div className="flex items-center gap-2 mb-2.5 px-1">
            <span className="bg-sidebar text-white text-xs font-bold px-2 py-0.5 rounded tabular-nums">{t('shelf')} {idx + 1}</span>
            <span className="text-[13px] font-semibold text-slate-700">{shelf.label}</span>
            <span className="text-xs font-medium text-slate-500 ml-auto">
              {shelf.slots.length} {shelf.slots.length === 1 ? t('slot_one') : t('slot_many')}
            </span>
          </div>
          <ul className="flex flex-col gap-2">
            {shelf.slots.map((sl, j) => {
              const primary = sl.motorIds[0];
              const p = productByMotor.get(primary) || null;
              const tag = (
                <SlotTag
                  label={sl.label}
                  sub={(sl.motorIds ?? []).map(m => `M${m}`).join('+')}
                  twin={(sl.motorIds?.length ?? 0) > 1}
                  muted={!p}
                />
              );
              if (!p) {
                return (
                  <li key={`${idx}-${j}-${primary}`} className="flex items-center gap-3 p-2.5 sm:p-3 rounded-[12px] border border-dashed border-slate-300 bg-slate-50">
                    {tag}
                    <Thumb p={null} />
                    <div className="flex-1 min-w-0 italic text-slate-500 font-semibold text-sm">{t('slot_empty')}</div>
                    <span className="hidden sm:block text-[13px] text-slate-500 italic text-right max-w-[120px] leading-tight">{t('tablet_only')}</span>
                  </li>
                );
              }
              return (
                <ItemRow key={`${idx}-${j}-${primary}`} p={p} slot={tag} category={catOf(p)} currency={currency} onEdit={onEdit} onDelete={onDelete} />
              );
            })}
          </ul>
        </section>
      ))}

      {unassigned.length > 0 && (
        <section className="p-4 bg-amber-50 border border-amber-300 rounded-[12px]">
          <div className="flex items-center gap-2 mb-3">
            <AlertTriangle size={16} className="text-amber-800" />
            <span className="text-sm font-bold text-amber-900">
              {t('not_linked_to_layout')} ({unassigned.length})
            </span>
          </div>
          <ul className="flex flex-col gap-2">
            {unassigned.map(p => (
              <ItemRow
                key={p.id}
                p={p}
                currency={currency}
                onEdit={onEdit}
                onDelete={onDelete}
                warn={p.motor_id == null ? t('no_motor_id') : `M${p.motor_id} ${t('motor_not_in_layout')}`}
              />
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}
