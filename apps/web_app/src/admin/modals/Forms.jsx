import { useState } from 'react';
import Cropper from 'react-easy-crop';
import { ArrowRight, CheckCircle2, Image, Loader2, Pencil, Plus, Save, ShoppingBag, Trash2, Upload } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import Modal from '../ui/Modal';
import { Button, IconButton } from '../ui/Button';
import { Banner, EmptyState, Spinner } from '../ui/Feedback';
import { Field, SearchInput, inputCls, matches } from '../ui/Field';
import { MACHINE_KINDS, catName, kindLabel, machineName, motorToSlotLabel } from '../lib/machines';
import { PHOTO_ACCEPT } from '../lib/photo';

function ProductThumb({ p, className = 'w-14 h-14' }) {
  return (
    <div className={`${className} bg-white rounded-[8px] flex items-center justify-center overflow-hidden shrink-0 border border-slate-200`}>
      {p?.image_url ? (
        <img src={p.image_url} alt="" className="w-full h-full object-contain p-1" />
      ) : p?.emoji ? (
        <span className="text-2xl" aria-hidden="true">{p.emoji}</span>
      ) : (
        <Image className="text-slate-400" size={20} aria-hidden="true" />
      )}
    </div>
  );
}

// ---- Inventory position (price, stock, cell) ----
export function InventoryEditModal({ value, onChange, isScreen, layout, categories, currency, onPickCatalog, onSave, saving, onClose }) {
  const { t, i18n } = useTranslation();
  const p = value;
  const set = (patch) => onChange({ ...p, ...patch });
  const cat = categories.find(c => c.id === p.category_id);
  return (
    <Modal
      title={p.id === 'new' ? t('new_product') : t('edit_product_title')}
      onClose={onClose}
      onSubmit={onSave}
      mobile="full"
      footer={(
        <Button type="submit" variant="primary" size="lg" block icon={Save} loading={saving} disabled={saving || !p.product_id}>
          {t('save')}
        </Button>
      )}
    >
      <div className="flex flex-col gap-5">
        {/* Catalog link card — name/photo/category come from the linked
            products row, not typed freehand. New items must pick a SKU. */}
        {p.product_id ? (
          <div className="flex gap-3 items-center bg-emerald-50 border border-emerald-300 rounded-[12px] p-3">
            <ProductThumb p={p} className="w-16 h-16" />
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-1.5 text-xs font-bold uppercase tracking-wider text-emerald-800">
                <CheckCircle2 size={13} /> {t('from_catalog')}
              </div>
              <div className="font-bold text-ink truncate">{p.name}</div>
              <div className="text-[13px] text-slate-700">{catName(cat, i18n.language) || t('no_category')}</div>
            </div>
            <IconButton icon={Pencil} label={t('change_product')} tone="success" onClick={onPickCatalog} />
          </div>
        ) : (
          <button
            type="button"
            onClick={onPickCatalog}
            className="w-full flex items-center justify-between gap-3 bg-blue-50 border border-blue-300 hover:bg-blue-100 hover:border-brand transition-all rounded-[12px] p-3 text-left focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300"
          >
            <span className="flex items-center gap-3">
              <span className="w-12 h-12 bg-white rounded-[8px] flex items-center justify-center border border-blue-300">
                <ShoppingBag size={20} className="text-brand" />
              </span>
              <span>
                <span className="block font-bold text-blue-900">{t('pick_from_catalog')}</span>
                <span className="block text-[13px] text-blue-800">{t('pick_from_catalog_hint')}</span>
              </span>
            </span>
            <Plus size={18} className="text-brand" />
          </button>
        )}

        {/* Cell number. Screen micromarket: editable — the number on the shelf,
            typed by the buyer on the numpad; empty keeps the position but hides
            it from the screen. Vending: read-only — motor wiring is edited on
            the tablet, where the operator can verify it at the cabinet; a wrong
            motor index from here would dispense the wrong product. */}
        {isScreen ? (
          <Field label={t('cell_number')} hint={`${t('cell_number_hint')} ${t('cell_number_optional_hint')}`}>
            {({ id, describedBy }) => (
              <input
                id={id}
                aria-describedby={describedBy}
                type="text"
                inputMode="numeric"
                maxLength={2}
                placeholder={t('cell_number_none')}
                className={`${inputCls} !w-28 font-extrabold text-lg tabular-nums`}
                value={p.motor_id ?? ''}
                onChange={e => {
                  // type="text" + filter instead of type="number": there an empty
                  // field collapses to 0 (a valid but wrong number), and Chrome
                  // takes «e», «+», «−» and spins the value on the mouse wheel.
                  const digits = e.target.value.replace(/\D/g, '').slice(0, 2);
                  set({ motor_id: digits === '' ? null : Number(digits) });
                }}
              />
            )}
          </Field>
        ) : p.motor_id != null && p.motor_id !== '' ? (
          <div className="flex items-center gap-3 bg-slate-100 border border-slate-300 rounded-[12px] p-3">
            <div className="bg-sidebar text-white px-3 py-1.5 rounded-[8px] font-extrabold tabular-nums shrink-0">
              {motorToSlotLabel(p.motor_id, layout) ?? '?'}
            </div>
            <div className="flex-1 min-w-0">
              <div className="text-xs font-bold uppercase tracking-wider text-slate-700">{t('slot_in_machine')}</div>
              <div className="text-[13px] text-slate-700 leading-snug">{t('motor_link_tablet_only')}</div>
            </div>
          </div>
        ) : null}

        {/* Stock left, price right — the order of the list row. */}
        <div className="grid grid-cols-2 gap-4">
          <Field
            label={t('stock_pcs')}
            type="number" inputMode="numeric" min="0"
            value={p.stock === 0 ? '' : p.stock}
            placeholder="0"
            onChange={e => set({ stock: e.target.value === '' ? 0 : Number(e.target.value) })}
          />
          <Field
            label={`${t('price_label')} (${currency})`}
            type="number" inputMode="numeric" min="0"
            value={p.price === 0 ? '' : p.price}
            placeholder="0"
            onChange={e => set({ price: e.target.value === '' ? 0 : Number(e.target.value) })}
          />
        </div>

        <Banner tone="info">{t('edit_photo_in_catalog')}</Banner>
      </div>
    </Modal>
  );
}

// ---- Categories ----
export function CategoryManagerModal({ categories, onAdd, onDelete, onClose }) {
  const { t, i18n } = useTranslation();
  const [ru, setRu] = useState('');
  const [kz, setKz] = useState('');
  const [en, setEn] = useState('');
  const [busy, setBusy] = useState(false);
  async function add() {
    setBusy(true);
    const ok = await onAdd({ ru, kz, en });
    setBusy(false);
    if (ok) { setRu(''); setKz(''); setEn(''); }
  }
  return (
    <Modal title={t('categories')} onClose={onClose} mobile="sheet">
      <form className="flex flex-col gap-3" onSubmit={(e) => { e.preventDefault(); add(); }}>
        <Field label={t('name_ru')} value={ru} onChange={e => setRu(e.target.value)} />
        <Field label={t('name_kz')} value={kz} onChange={e => setKz(e.target.value)} />
        <Field label={t('name_en')} value={en} onChange={e => setEn(e.target.value)} />
        <Button type="submit" variant="primary" icon={Plus} loading={busy}>{t('add')}</Button>
      </form>

      <ul className="mt-5 pt-5 border-t border-slate-200 flex flex-col gap-2">
        {categories.map(c => (
          <li key={c.id} className="flex justify-between items-center gap-3 bg-slate-50 border border-slate-200 p-3 rounded-[8px]">
            <div className="flex flex-col min-w-0">
              <span className="font-bold text-sm">{catName(c, i18n.language)}</span>
              <span className="text-xs text-slate-600 truncate">{[c.name_ru, c.name_kz, c.name_en].filter(Boolean).join(' / ')}</span>
            </div>
            <IconButton icon={Trash2} label={t('delete')} tone="danger" onClick={() => onDelete(c.id)} />
          </li>
        ))}
        {categories.length === 0 && <p className="text-center text-sm text-slate-600 py-4">{t('no_categories')}</p>}
      </ul>
    </Modal>
  );
}

// ---- Catalog picker over the inventory form ----
export function CatalogPickerModal({ products, categories, onPick, onClose }) {
  const { t, i18n } = useTranslation();
  const [q, setQ] = useState('');
  const shown = (products ?? []).filter(p => matches(q, p.name));
  return (
    <Modal title={t('tab_catalog')} subtitle={t('pick_ready_product')} onClose={onClose} size="lg" mobile="full" layer={110} bodyClassName="flex flex-col !overflow-hidden">
      <div className="px-5 py-3 border-b border-slate-200">
        <SearchInput value={q} onChange={setQ} placeholder={t('search_placeholder_short')} />
      </div>
      <div className="flex-1 min-h-[40dvh] overflow-y-auto p-4">
        {products == null ? (
          <Spinner />
        ) : products.length === 0 ? (
          <EmptyState icon={Image} title={t('catalog_empty')} hint={t('catalog_empty_hint')} />
        ) : shown.length === 0 ? (
          <EmptyState title={t('nothing_found')} />
        ) : (
          <ul className="flex flex-col gap-2">
            {shown.map(p => (
              <li key={p.id}>
                <button
                  type="button"
                  onClick={() => onPick(p)}
                  className="w-full flex items-center gap-3 p-3 rounded-[8px] bg-white border border-slate-200 hover:border-brand hover:shadow-card transition-all text-left focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300"
                >
                  <ProductThumb p={p} className="w-12 h-12" />
                  <span className="flex-1 min-w-0">
                    <span className="block font-bold text-sm truncate text-ink">{p.name}</span>
                    <span className="block text-[13px] text-slate-600">
                      {catName(categories.find(c => c.id === p.category_id), i18n.language) || t('no_category')}
                      {p.volume_ml != null && ` · ${p.volume_ml} ${t('unit_ml')}`}
                    </span>
                  </span>
                  <Plus size={16} className="text-slate-500" />
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </Modal>
  );
}

// ---- Catalog product (SKU) ----
export function CatalogEditModal({ value, onChange, categories, uploading, saving, fileInputRef, onFile, onOpenLibrary, onSave, onPublish, onClose }) {
  const { t, i18n } = useTranslation();
  const [menu, setMenu] = useState(false);
  const p = value;
  const set = (patch) => onChange({ ...p, ...patch });
  return (
    <Modal
      title={p.id === 'new' ? t('new_catalog_product') : t('edit_product_title')}
      onClose={onClose}
      onSubmit={onSave}
      mobile="full"
      footer={(
        <>
          {p.is_draft && p.id !== 'new' && (
            <Button variant="success" icon={CheckCircle2} onClick={onPublish} className="flex-1 sm:flex-none">{t('publish')}</Button>
          )}
          <Button type="submit" variant="primary" icon={Save} loading={saving} disabled={saving || uploading} className="flex-1 sm:flex-none min-w-32">
            {t('save')}
          </Button>
        </>
      )}
    >
      <div className="flex flex-col gap-4">
        <div className="flex gap-4 items-start">
          {/* Two sources, so the tile opens a menu instead of jumping straight
              into the file dialog. */}
          <div className="relative shrink-0">
            <button
              type="button"
              onClick={() => setMenu(v => !v)}
              aria-haspopup="menu"
              aria-expanded={menu}
              aria-label={t('photo')}
              className="w-24 h-24 bg-blue-50 rounded-[12px] flex flex-col items-center justify-center border-2 border-dashed border-blue-300 hover:bg-blue-100 hover:border-brand transition-all overflow-hidden focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300"
            >
              {uploading ? (
                <Loader2 className="animate-spin text-brand" />
              ) : p.image_url ? (
                <img src={p.image_url} className="w-full h-full object-contain" alt="" />
              ) : (
                <>
                  <Upload className="text-brand mb-1" size={20} />
                  <span className="text-xs font-bold text-brand-dark">{t('photo')}</span>
                </>
              )}
            </button>
            {menu && (
              <>
                <div className="fixed inset-0 z-20" onClick={() => setMenu(false)} />
                <div role="menu" className="absolute z-30 top-full left-0 mt-1 w-60 bg-white rounded-[8px] shadow-xl border border-slate-200 overflow-hidden">
                  <button type="button" role="menuitem" onClick={() => { setMenu(false); onOpenLibrary(); }} className="w-full flex items-center gap-2 px-3 min-h-11 text-sm font-semibold text-ink hover:bg-blue-50 text-left">
                    <Image size={16} className="text-brand shrink-0" /> {t('photo_from_library')}
                  </button>
                  <button type="button" role="menuitem" onClick={() => { setMenu(false); fileInputRef.current?.click(); }} className="w-full flex items-center gap-2 px-3 min-h-11 text-sm font-semibold text-ink hover:bg-blue-50 text-left border-t border-slate-200">
                    <Upload size={16} className="text-brand shrink-0" /> {t('photo_from_gallery')}
                  </button>
                </div>
              </>
            )}
            <input type="file" className="hidden" accept={PHOTO_ACCEPT} ref={fileInputRef} onChange={onFile} />
          </div>
          <div className="flex-1 flex flex-col gap-3 min-w-0">
            <Field label={t('product_name')} placeholder={t('name_coca_example')} value={p.name || ''} onChange={e => set({ name: e.target.value })} />
            <Field label={t('category')}>
              {({ id }) => (
                <select id={id} className={inputCls} value={p.category_id || ''} onChange={e => set({ category_id: e.target.value || null })}>
                  <option value="">{t('no_category')}</option>
                  {categories.map(c => <option key={c.id} value={c.id}>{catName(c, i18n.language)}</option>)}
                </select>
              )}
            </Field>
          </div>
        </div>

        <div className="grid grid-cols-2 gap-3">
          <Field label={t('volume_ml')} type="number" inputMode="numeric" placeholder="500" value={p.volume_ml ?? ''} onChange={e => set({ volume_ml: e.target.value })} />
          <Field label={t('emoji_fallback')} placeholder="🥤" maxLength={4} value={p.emoji || ''} onChange={e => set({ emoji: e.target.value })} />
        </div>

        <Field label={t('description_optional')}>
          {({ id }) => (
            <textarea id={id} rows={2} className={`${inputCls} py-2.5`} value={p.description || ''} onChange={e => set({ description: e.target.value })} />
          )}
        </Field>

        {p.is_draft && p.id !== 'new' && <Banner tone="warning">{t('draft_from_tablet')}</Banner>}
      </div>
    </Modal>
  );
}

// ---- Photo cropper ----
export function CropperModal({ src, crop, zoom, onCrop, onZoom, onComplete, uploading, canSave, onSave, onCancel }) {
  const { t } = useTranslation();
  return (
    <div className="admin-ui fixed inset-0 z-[120] bg-black flex flex-col" role="dialog" aria-modal="true" aria-label={t('crop_photo')}>
      <div className="flex-1 relative">
        <Cropper image={src} crop={crop} zoom={zoom} aspect={1} onCropChange={onCrop} onZoomChange={onZoom} onCropComplete={(_, px) => onComplete(px)} />
      </div>
      <div className="p-4 sm:p-6 bg-white flex justify-end gap-3 items-center pb-[max(1rem,env(safe-area-inset-bottom))]">
        <Button variant="ghost" onClick={onCancel}>{t('cancel')}</Button>
        <Button variant="primary" loading={uploading} onClick={onSave} disabled={uploading || !canSave}>{t('save_and_upload')}</Button>
      </div>
    </div>
  );
}

// ---- Superadmin: add device ----
export function AddDeviceModal({ value, onChange, saving, onSave, onClose }) {
  const { t } = useTranslation();
  const v = value;
  const hints = {
    vending: t('device_kind_vending_hint'),
    micromarket_tablet: t('device_kind_tablet_hint'),
    micromarket_static: t('device_kind_static_hint'),
    micromarket_screen: t('device_kind_screen_hint'),
  };
  return (
    <Modal
      title={t('add_device')}
      subtitle={t('add_device_hint')}
      onClose={onClose}
      onSubmit={onSave}
      mobile="full"
      footer={(
        <>
          <Button variant="secondary" onClick={onClose}>{t('cancel')}</Button>
          <Button type="submit" variant="primary" loading={saving}>{t('add')}</Button>
        </>
      )}
    >
      <div className="flex flex-col gap-4">
        <Field
          label={t('device_internal_id')}
          hint={t('device_id_hint')}
          value={v.machid}
          onChange={e => onChange({ ...v, machid: e.target.value.replace(/\D/g, '') })}
          inputMode="numeric"
          placeholder="3001000"
        />
        <Field
          label={t('device_secret')}
          hint={t('device_secret_hint')}
          value={v.secret}
          onChange={e => onChange({ ...v, secret: e.target.value })}
          autoComplete="off"
          spellCheck={false}
          className="[&_input]:font-mono"
        />
        <fieldset>
          <legend className="text-sm font-semibold text-slate-700 mb-1.5">{t('device_kind')}</legend>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
            {MACHINE_KINDS.map(k => (
              <button
                key={k}
                type="button"
                aria-pressed={v.kind === k}
                onClick={() => onChange({ ...v, kind: k })}
                className={`p-3 rounded-[8px] border-2 text-left transition-all focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300 ${v.kind === k ? 'border-brand bg-blue-50' : 'border-slate-200 hover:border-slate-300'}`}
              >
                <span className="block font-bold text-sm text-ink">{kindLabel(k, t)}</span>
                <span className="block text-xs text-slate-600 leading-tight mt-0.5">{hints[k]}</span>
              </button>
            ))}
          </div>
        </fieldset>
      </div>
    </Modal>
  );
}

// ---- Rename a machine ----
export function RenameModal({ value, onChange, onSave, onClose }) {
  const { t } = useTranslation();
  const [busy, setBusy] = useState(false);
  return (
    <Modal
      title={t('rename')}
      subtitle={`${t('apparatus_no')}${value.id}`}
      onClose={onClose}
      size="sm"
      onSubmit={async () => { setBusy(true); await onSave(); setBusy(false); }}
      footer={(
        <>
          <Button variant="secondary" onClick={onClose}>{t('cancel')}</Button>
          <Button type="submit" variant="primary" loading={busy}>{t('save')}</Button>
        </>
      )}
    >
      <Field label={t('device_name')} hint={t('device_name_hint')} value={value.name} onChange={e => onChange({ ...value, name: e.target.value })} />
    </Modal>
  );
}

// ---- Superadmin: move a machine to another account ----
// One dialog: pick the new owner, see both accounts side by side, confirm.
// It used to take two (a list, then a separate confirmation).
export function TransferModal({ market, owners, busy, onConfirm, onClose }) {
  const { t } = useTranslation();
  const [q, setQ] = useState('');
  const [to, setTo] = useState(null);
  const from = owners.find(o => o.id === market.owner_id) || null;
  const shown = owners.filter(o => o.id !== market.owner_id && matches(q, o.email));
  return (
    <Modal
      title={t('transfer_device')}
      subtitle={`${machineName(market, t)} · ${t('apparatus_no')}${market.id}`}
      onClose={busy ? () => {} : onClose}
      dismissable={!busy}
      mobile="full"
      onSubmit={() => to && onConfirm(to)}
      footer={(
        <>
          <Button variant="secondary" onClick={onClose} disabled={busy}>{t('cancel')}</Button>
          <Button type="submit" variant="primary" loading={busy} disabled={!to}>{t('transfer_short')}</Button>
        </>
      )}
    >
      <div className="flex flex-col gap-4">
        <div className="flex items-stretch gap-2">
          <div className="flex-1 min-w-0 rounded-[8px] border border-slate-200 bg-slate-50 p-3">
            <div className="text-xs font-bold uppercase tracking-wider text-slate-600">{t('transfer_from')}</div>
            <div className="text-sm font-bold text-ink break-all">{from?.email || t('no_owner')}</div>
          </div>
          <ArrowRight className="self-center text-brand shrink-0" size={20} aria-hidden="true" />
          <div className={`flex-1 min-w-0 rounded-[8px] border-2 p-3 ${to ? 'border-brand bg-blue-50' : 'border-dashed border-slate-300'}`}>
            <div className="text-xs font-bold uppercase tracking-wider text-slate-600">{t('transfer_to')}</div>
            <div className="text-sm font-bold text-ink break-all">{to?.email || t('transfer_pick_owner')}</div>
          </div>
        </div>

        <SearchInput value={q} onChange={setQ} placeholder={t('users_search')} />
        <ul className="flex flex-col gap-1.5 max-h-72 overflow-y-auto" role="listbox" aria-label={t('transfer_pick_owner')}>
          {shown.map(o => (
            <li key={o.id}>
              <button
                type="button"
                role="option"
                aria-selected={to?.id === o.id}
                onClick={() => setTo(o)}
                className={`w-full min-h-11 px-3 py-2 rounded-[8px] border text-left text-sm font-semibold break-all transition-colors focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300 ${to?.id === o.id ? 'border-brand bg-blue-50 text-brand-dark' : 'border-slate-200 hover:border-slate-300 text-ink'}`}
              >
                {o.email}
              </button>
            </li>
          ))}
          {shown.length === 0 && <li className="text-sm text-slate-600 py-3 text-center">{t('nothing_found')}</li>}
        </ul>

        <Banner tone="warning">{t('transfer_confirm_hint')}</Banner>
      </div>
    </Modal>
  );
}

// ---- Superadmin: set a user's password ----
// No reset mail: the project has no SMTP, and the account was handed over
// with a password in the first place.
export function PasswordModal({ value, onChange, saving, onSave, onClose }) {
  const { t } = useTranslation();
  return (
    <Modal
      title={t('change_password')}
      subtitle={value.email}
      onClose={onClose}
      size="sm"
      onSubmit={onSave}
      footer={(
        <>
          <Button variant="secondary" onClick={onClose}>{t('cancel')}</Button>
          <Button type="submit" variant="primary" loading={saving}>{t('save')}</Button>
        </>
      )}
    >
      <Field
        label={t('new_password')}
        hint={t('user_password_hint')}
        value={value.password}
        onChange={e => onChange({ ...value, password: e.target.value })}
        autoComplete="new-password"
        className="[&_input]:font-mono"
      />
    </Modal>
  );
}

// ---- Superadmin: create an owner account ----
// The password is set here and handed to the owner directly; there is no
// signup/invite mail flow.
export function NewUserModal({ value, onChange, saving, onSave, onClose }) {
  const { t } = useTranslation();
  return (
    <Modal
      title={t('new_user')}
      subtitle={t('new_user_hint')}
      onClose={onClose}
      onSubmit={onSave}
      mobile="full"
      footer={(
        <>
          <Button variant="secondary" onClick={onClose}>{t('cancel')}</Button>
          <Button type="submit" variant="primary" loading={saving}>{t('create')}</Button>
        </>
      )}
    >
      <div className="flex flex-col gap-4">
        <Field label={t('email')} type="email" autoComplete="off" value={value.email} onChange={e => onChange({ ...value, email: e.target.value })} />
        <Field label={t('password')} hint={t('user_password_hint')} autoComplete="new-password" value={value.password} onChange={e => onChange({ ...value, password: e.target.value })} className="[&_input]:font-mono" />
        <Field label={t('user_full_name')} value={value.full_name} onChange={e => onChange({ ...value, full_name: e.target.value })} />
      </div>
    </Modal>
  );
}
