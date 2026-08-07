import React, { useState, useEffect, useRef } from 'react';
import { supabase } from './supabaseClient';
import { Image, Upload, Download, Plus, Minus, Save, Trash2, X, Loader2, Pencil, Receipt, Calendar, ShoppingBag, History, Languages, CheckCircle2, XCircle, AlertTriangle, ChevronRight, ChevronLeft, ChevronDown, Package, QrCode, KeyRound, Unlink as LinkOff } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import './i18n';
import Cropper from 'react-easy-crop';
import QRCode from 'qrcode';

// Build a minimal one-page A4 PDF Blob embedding `canvas` as a JPEG image.
// Dependency-free (no jsPDF) — bundling jsPDF produced an unusable constructor
// in the Vercel/Node production build, so we emit the PDF bytes ourselves.
function buildPdfBlobFromCanvas(canvas) {
  const jpegB64 = canvas.toDataURL('image/jpeg', 0.92).split(',')[1];
  const bin = atob(jpegB64);
  const jpeg = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) jpeg[i] = bin.charCodeAt(i);

  const W = canvas.width, H = canvas.height;
  const CM = 28.3465; // points per cm
  const pageW = 7 * CM;          // 7cm wide
  const pageH = pageW * (H / W); // height follows the canvas — no empty bottom
  const drawW = pageW;
  const drawH = pageH;
  const x = 0;
  const y = 0;
  const content = `q\n${drawW.toFixed(2)} 0 0 ${drawH.toFixed(2)} ${x.toFixed(2)} ${y.toFixed(2)} cm\n/Im0 Do\nQ\n`;

  const enc = new TextEncoder();
  const parts = [];
  const offsets = [];
  let length = 0;
  const push = (u8) => { parts.push(u8); length += u8.length; };
  const pushStr = (s) => push(enc.encode(s));
  const addObj = (fn) => { offsets.push(length); fn(); };

  pushStr('%PDF-1.3\n');
  addObj(() => pushStr('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'));
  addObj(() => pushStr('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n'));
  addObj(() => pushStr(`3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pageW} ${pageH}] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>\nendobj\n`));
  addObj(() => {
    pushStr(`4 0 obj\n<< /Type /XObject /Subtype /Image /Width ${W} /Height ${H} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>\nstream\n`);
    push(jpeg);
    pushStr('\nendstream\nendobj\n');
  });
  const contentBytes = enc.encode(content);
  addObj(() => {
    pushStr(`5 0 obj\n<< /Length ${contentBytes.length} >>\nstream\n`);
    push(contentBytes);
    pushStr('\nendstream\nendobj\n');
  });

  const xrefStart = length;
  let xref = 'xref\n0 6\n0000000000 65535 f \n';
  for (const off of offsets) xref += String(off).padStart(10, '0') + ' 00000 n \n';
  pushStr(xref);
  pushStr(`trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xrefStart}\n%%EOF`);

  const out = new Uint8Array(length);
  let pos = 0;
  for (const p of parts) { out.set(p, pos); pos += p.length; }
  return new Blob([out], { type: 'application/pdf' });
}

// How many most-recent sales to load (avoid pulling the whole history).
const SALES_PAGE_SIZE = 10;

// Base URL the QR points at — the customer storefront. Set VITE_STOREFRONT_URL
// to the deployed storefront origin; falls back to the current origin.
const STOREFRONT_BASE = import.meta.env.VITE_STOREFRONT_URL || (typeof window !== 'undefined' ? window.location.origin : '');

// Build + download a printable PDF with the machine's QR (encodes
// <storefront>/?marketId=<id>). Rendered via canvas so Cyrillic text works
// (jsPDF's built-in fonts don't support it).
async function buildMarketQrPdf(market, qrDataUrl, t) {
  const url = `${STOREFRONT_BASE}/micromarket?t=${market.qr_token}`;
  if (!qrDataUrl) qrDataUrl = await QRCode.toDataURL(url, { width: 900, margin: 1, errorCorrectionLevel: 'M' });

  // Canvas aspect = 7:15 to match the printed label (7cm wide × 15cm tall).
  // 100 px per cm. QR is kept square so it scans reliably.
  // 7cm wide; the height is trimmed to the content (no empty bottom). QR stays
  // square so it scans. 100 px per cm.
  const canvas = document.createElement('canvas');
  canvas.width = 700;
  canvas.height = 920;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.textAlign = 'center';
  const cx = canvas.width / 2;

  ctx.fillStyle = '#111827';
  ctx.font = 'bold 42px sans-serif';
  ctx.fillText(`${t('apparatus_no')}${market.id}`, cx, 72);

  // NB: `Image` is imported from lucide-react in this file, so use the global
  // browser constructor explicitly (new Image() would hit the lucide icon).
  const img = new window.Image();
  await new Promise((resolve, reject) => {
    img.onload = resolve;
    img.onerror = reject;
    img.src = qrDataUrl;
  });
  const qrSize = 620; // ~6.2 cm square
  ctx.drawImage(img, (canvas.width - qrSize) / 2, 110, qrSize, qrSize);

  ctx.fillStyle = '#111827';
  ctx.font = 'bold 42px sans-serif';
  ctx.fillText(t('qr_scan_to'), cx, 800);
  ctx.fillText(t('qr_to_buy'), cx, 850);
  ctx.fillStyle = '#9ca3af';
  ctx.font = '20px sans-serif';
  ctx.fillText(url, cx, 895);

  return buildPdfBlobFromCanvas(canvas);
}

// Modal that previews a machine's QR (links to the storefront on this same
// Vercel deployment) with a button to download it as a printable PDF.
function QrModal({ market, onClose }) {
  const { t } = useTranslation();
  const [qrSrc, setQrSrc] = useState(null);
  const [pdfUrl, setPdfUrl] = useState(null);
  const [pdfErr, setPdfErr] = useState(null);
  const url = `${STOREFRONT_BASE}/micromarket?t=${market.qr_token}`;
  useEffect(() => {
    let alive = true;
    let createdUrl = null;
    (async () => {
      const qr = await QRCode.toDataURL(url, { width: 600, margin: 1, errorCorrectionLevel: 'M' });
      if (!alive) return;
      setQrSrc(qr);
      // Pre-build the PDF blob now (not on click) so the download is a plain
      // anchor click — avoids browsers blocking a download triggered after await.
      const blob = await buildMarketQrPdf(market, qr, t);
      if (!alive) return;
      createdUrl = URL.createObjectURL(blob);
      setPdfUrl(createdUrl);
    })().catch((e) => { console.error('[QrModal] build failed', e); if (alive) setPdfErr(String((e && e.message) || e)); });
    return () => { alive = false; if (createdUrl) URL.revokeObjectURL(createdUrl); };
  }, [url, market]);

  return (
    <div className="fixed inset-0 z-[60] bg-black/50 flex items-center justify-center p-4" onClick={onClose}>
      <div className="bg-white rounded-3xl p-6 w-full max-w-sm shadow-2xl" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-4">
          <h3 className="text-lg font-black text-slate-900">{t('qr_machine')}</h3>
          <button onClick={onClose} className="p-2 text-slate-400 hover:text-slate-700 rounded-lg"><X size={20} /></button>
        </div>
        <div className="text-center">
          <div className="font-bold text-slate-900">{market.name || `${t('apparatus_no')}${market.id}`}</div>
          <div className="text-[11px] font-bold text-slate-500 uppercase tracking-widest mb-4">{t('apparatus_no')}{market.id}</div>
          <div className="bg-white border-2 border-slate-200 rounded-2xl p-4 inline-block">
            {qrSrc ? (
              <img src={qrSrc} alt="QR" className="w-56 h-56" />
            ) : (
              <div className="w-56 h-56 flex items-center justify-center"><Loader2 className="animate-spin text-slate-300" size={32} /></div>
            )}
          </div>
          <a href={url} target="_blank" rel="noreferrer" className="mt-3 block text-[11px] text-slate-400 hover:text-slate-600 break-all">{url}</a>
        </div>
        {pdfUrl ? (
          <a
            href={pdfUrl}
            download={`qr-apparat-${market.id}.pdf`}
            className="mt-5 w-full flex items-center justify-center gap-2 bg-slate-900 text-white py-3 rounded-xl font-bold hover:bg-slate-700 transition-all"
          >
            <Download size={18} /> {t('download_qr_pdf')}
          </a>
        ) : pdfErr ? (
          <div className="mt-5 w-full text-center bg-rose-50 border border-rose-200 text-rose-700 py-3 px-3 rounded-xl text-xs font-bold break-words">
            {t('pdf_error')}: {pdfErr}
          </div>
        ) : (
          <button disabled className="mt-5 w-full flex items-center justify-center gap-2 bg-slate-300 text-white py-3 rounded-xl font-bold cursor-wait">
            <Loader2 size={18} className="animate-spin" /> {t('preparing')}
          </button>
        )}
      </div>
    </div>
  );
}

// Map an M102 poll result byte → i18n key. The codes are emitted by the
// vending tablet's `BoardClient.dispense` and persisted to
// `sales_items.result_code` (see m102_tester migration
// 20260513120000_sales_items_result_details.sql).
const RESULT_CODE_I18N = {
  1: 'result_overload',
  2: 'result_wire_break',
  3: 'result_timeout',
  4: 'result_curtain_err',
  5: 'result_lock_not_open',
  10: 'result_microswitch',
};

// Build the default factory 6×6 layout (matches LayoutTemplate.factory6x6
// on the tablet). Used as a fallback when micromarkets.layout_json is
// null — newly-paired machines or anything that hasn't run a layout
// editor on-device yet.
function buildFactory6x6Layout() {
  const shelves = [];
  for (let s = 1; s <= 6; s++) {
    const slots = [];
    for (let j = 1; j <= 6; j++) {
      const motor = (10 - s) * 10 + (10 - j);
      const n = (s - 1) * 6 + j;
      slots.push({ label: n.toString().padStart(3, '0'), motorIds: [motor] });
    }
    const first = (s - 1) * 6 + 1;
    const last = s * 6;
    shelves.push({
      label: `${first.toString().padStart(3, '0')} — ${last.toString().padStart(3, '0')}`,
      slots,
    });
  }
  return { shelves };
}

// Parse layout_json from Supabase. Falls back to factory 6×6 on null,
// malformed JSON, or empty shelves. Same on-disk shape as the tablet's
// MachineLayout.encode().
function parseLayout(rawJson) {
  if (rawJson == null) return { ...buildFactory6x6Layout(), _source: 'fallback' };
  try {
    const obj = typeof rawJson === 'string' ? JSON.parse(rawJson) : rawJson;
    if (!obj?.shelves || !Array.isArray(obj.shelves) || obj.shelves.length === 0) {
      return { ...buildFactory6x6Layout(), _source: 'fallback' };
    }
    return {
      _source: 'db',
      shelves: obj.shelves.map(sh => ({
        label: sh.label ?? '',
        slots: (sh.slots ?? []).map(sl => ({
          label: sl.label ?? '',
          motorIds: (sl.motorIds ?? []).map(n => Number(n)),
        })),
      })),
    };
  } catch (_) {
    return { ...buildFactory6x6Layout(), _source: 'fallback' };
  }
}

// Build a Map<motorId, slot> for O(1) lookup of which slot a given
// motor belongs to. Twin spirals have multiple motorIds → all map to
// the same slot record. Inventory rows store the primary motor_id, so
// matching covers the common case + the rare "operator wired the
// secondary" case.
function buildSlotByMotor(layout) {
  const byMotor = new Map();
  for (const sh of layout.shelves) {
    for (const sl of sh.slots) {
      for (const m of sl.motorIds) {
        byMotor.set(m, sl);
      }
    }
  }
  return byMotor;
}

// Translate an M102 motor index into the printed slot label on the
// cabinet door, using the operator-defined layout when available.
function motorToSlotLabel(motorId, layout) {
  if (motorId == null) return null;
  const id = Number(motorId);
  if (!Number.isInteger(id)) return null;
  if (layout) {
    const byMotor = layout._byMotorCache ?? buildSlotByMotor(layout);
    if (!layout._byMotorCache) layout._byMotorCache = byMotor;
    const slot = byMotor.get(id);
    if (slot) return slot.label;
  }
  // Fallback to factory 6×6 formula when caller didn't pass a layout
  // (e.g. for the inventory list view where we render rows before the
  // full layout is loaded).
  if (id < 0 || id > 99) return null;
  const row = 10 - Math.floor(id / 10);
  const col = 10 - (id % 10);
  if (row < 1 || row > 9 || col < 1 || col > 9) return null;
  const n = (row - 1) * 10 + col;
  return n.toString().padStart(3, '0');
}

// Single notification surface for the whole admin — green when something
// succeeded, red for a rejection or an error, and nothing else. It sits above
// every overlay on purpose: most warnings are raised while a modal is open
// (a rejected device, a failed save), and underneath the dialogs the operator
// would see nothing happen at all. Layer map in this file: 50 edit modal,
// 60 QR / catalog picker, 100 cropper, 110 dialogs, 120 transfer confirm,
// 300 toast — keep the toast highest.
//
// Rendered on the login screen too, which returns before the main tree, so
// sign-in failures get the same treatment instead of a system alert().
function Toast({ toast, onClose }) {
  if (!toast) return null;
  const isError = toast.type === 'error';
  return (
    <div
      onClick={onClose}
      role="alert"
      className={`fixed bottom-6 left-1/2 -translate-x-1/2 px-5 py-3 rounded-2xl font-bold text-white shadow-2xl z-[300] max-w-[92vw] sm:max-w-md flex items-start gap-2 cursor-pointer animate-in fade-in slide-in-from-bottom-5 ${isError ? 'bg-red-600' : 'bg-emerald-600'}`}
    >
      <span className="shrink-0 mt-0.5">
        {isError ? <AlertTriangle size={16} /> : <CheckCircle2 size={16} />}
      </span>
      <span className="text-sm leading-snug">{toast.message}</span>
    </div>
  );
}

// Connection state of one machine, from its heartbeat.
//
// Three states, not two, because "the tablet answers" and "the board answers"
// are different faults with different call-outs: a machine can be perfectly
// online while nothing dispenses. One lamp would hide exactly the failure
// that costs the owner money.
//
//   зелёный — на связи, плата отвечает
//   жёлтый  — на связи, но плата молчит  → выехать к автомату, не к сети
//   серый   — не видели дольше порога, или ни разу (новый аппарат)
//
// `online` is computed server-side (device_status_view, 3-minute threshold);
// this only renders it.
function DeviceStatusDot({ status, kind, withLabel = false }) {
  const { t, i18n } = useTranslation();

  // A static-QR micromarket has no tablet — the ESP relay doesn't report yet,
  // so there is nothing to draw. Showing it as permanently green would be the
  // same lie as storing `online` in a column: a claim about a device we have
  // no signal from. The lamp appears on its own once the relay starts beating.
  if (kind === 'micromarket_static') return null;

  const seen = status?.last_seen_at ? new Date(status.last_seen_at) : null;

  let tone, label, note;
  if (!status) {
    tone = 'bg-slate-300';
    label = t('status_never');
  } else if (!status.online) {
    tone = 'bg-slate-400';
    label = t('status_offline');
  } else if (status.board_ok === false) {
    tone = 'bg-amber-500';
    label = t('status_board_down');
  } else {
    tone = 'bg-emerald-500';
    label = t('status_online');
    // null ≠ false. BarysVend has no health poll, so the tablet reports
    // "unknown" and the lamp only speaks for the tablet. Said out loud in
    // the tooltip, otherwise it looks like the board check silently works
    // on some machines and not others.
    if (status.board_ok == null) note = t('status_board_unknown');
  }

  const title = [
    label,
    seen && `${t('status_last_seen')} ${seen.toLocaleString(i18n.language)}`,
    note,
  ].filter(Boolean).join(' · ');

  return (
    <span className="flex items-center gap-1.5 shrink-0" title={title}>
      <span className={`w-2.5 h-2.5 rounded-full ${tone}`} />
      {withLabel && (
        <span className="text-[10px] font-bold uppercase tracking-wider text-slate-500">
          {label}
        </span>
      )}
    </span>
  );
}

function resultLabel(t, item) {
  if (item.result_code != null) {
    const key = RESULT_CODE_I18N[item.result_code];
    if (key) return t(key);
    return `${t('result_unknown')} ${item.result_code}`;
  }
  // Transport-level failure: no poll byte, but the tablet attaches a
  // free-form message ("Нет ответа от платы", "Плата занята" etc.).
  return item.result_message || t('dispense_failed');
}

export default function Admin() {
  const { t, i18n } = useTranslation();
  const [markets, setMarkets] = useState([]);
  const [selectedMarketId, setSelectedMarketId] = useState(null);

  // Drilling into a machine used to be pure React state, so on a phone the
  // back swipe found nothing to pop and left the site altogether — the
  // operator lost the whole panel instead of returning to the list. Each
  // drill-in now pushes a history entry, and the swipe (or the browser's
  // back button) pops it back to the machine list.
  //
  // The entry carries a marker so `closeMarket` knows whether there is one
  // to pop: reaching the detail view any other way (tab switch, reload)
  // must not fire history.back() and jump off the site.
  const openMarket = (id) => {
    window.history.pushState({ mmMarket: id }, '');
    setSelectedMarketId(id);
  };

  const closeMarket = () => {
    if (window.history.state?.mmMarket != null) window.history.back();
    else setSelectedMarketId(null);
  };

  useEffect(() => {
    const onPop = () => setSelectedMarketId(null);
    window.addEventListener('popstate', onPop);
    return () => window.removeEventListener('popstate', onPop);
  }, []);
  const [products, setProducts] = useState([]);
  const [loading, setLoading] = useState(false);
  const [editingProduct, setEditingProduct] = useState(null);
  const [uploadingImage, setUploadingImage] = useState(false);
  const [session, setSession] = useState(null);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [authLoading, setAuthLoading] = useState(false);
  const [toast, setToast] = useState(null); // { message, type }
  const fileInputRef = useRef(null);

  // Состояния для обрезки
  const [cropImageSrc, setCropImageSrc] = useState(null);
  // Where the uploaded image URL should be written: 'inventory' (legacy
  // inventory modal) or 'catalog' (new catalog modal). Defaults to
  // 'inventory' for back-compat.
  const [cropTarget, setCropTarget] = useState('inventory');
  const [crop, setCrop] = useState({ x: 0, y: 0 });
  const [zoom, setZoom] = useState(1);
  const [croppedAreaPixels, setCroppedAreaPixels] = useState(null);

  // Состояния категорий
  const [categories, setCategories] = useState([]);
  const [showCategoryManager, setShowCategoryManager] = useState(false);
  const [newCatRu, setNewCatRu] = useState('');
  const [newCatKz, setNewCatKz] = useState('');
  const [newCatEn, setNewCatEn] = useState('');
  const [selectedCategoryFilter, setSelectedCategoryFilter] = useState('All');
  const [productToDelete, setProductToDelete] = useState(null);
  const [activeTab, setActiveTab] = useState('sales'); // 'sales' | 'inventory' | 'catalog'
  const [sales, setSales] = useState([]);
  const [timeFilter, setTimeFilter] = useState('recent'); // 'recent'|'day'|'week'|'month'|'period'
  const [periodFrom, setPeriodFrom] = useState('');
  const [periodTo, setPeriodTo] = useState('');
  const [selectedSalesMarket, setSelectedSalesMarket] = useState('all');
  const [expandedSaleId, setExpandedSaleId] = useState(null); // which sale's items are shown
  const [qrModalMarket, setQrModalMarket] = useState(null); // machine whose QR modal is open

  // Catalog tab — products table (SKU catalog, owner-scoped).
  // Separate from inventory: products are reusable across micromarkets
  // and only carry name/photo/category/volume; per-slot fields like
  // price/stock/motor_id live on inventory rows that reference them.
  const [catalogProducts, setCatalogProducts] = useState([]);
  const [catalogFilter, setCatalogFilter] = useState('active'); // 'active' | 'drafts' | 'archived'
  const [editingCatalog, setEditingCatalog] = useState(null);
  const catalogFileInputRef = useRef(null);

  // Picker overlay used by the inventory edit modal to pick a catalog
  // SKU. The product list is loaded lazily on first open.
  const [showCatalogPicker, setShowCatalogPicker] = useState(false);
  const [pickerProducts, setPickerProducts] = useState(null);
  const [pickerSearch, setPickerSearch] = useState('');

  // Platform admin (only the operator running the whole fleet). The flag comes
  // from app_metadata, which only the service_role can write — see migration
  // 20260804120000_superadmin_role.sql. Hiding the tab is cosmetic; the real
  // check is inside the admin-create-user function.
  const isSuperadmin = session?.user?.app_metadata?.is_superadmin === true;
  const [users, setUsers] = useState(null);
  const [usersLoading, setUsersLoading] = useState(false);
  const [newUser, setNewUser] = useState(null);      // {email,password,full_name} while the form is open
  const [userSaving, setUserSaving] = useState(false);
  const [pwdTarget, setPwdTarget] = useState(null);      // {id,email,password}
  const [userDeleteTarget, setUserDeleteTarget] = useState(null); // {id,email}

  // "Add device" modal — the owner registers a machine by typing its SmartVend
  // Internal ID + Secret; device-claim verifies the pair and writes micromarkets.
  const [addingDevice, setAddingDevice] = useState(null); // {machid,secret,name,kind}
  const [deviceSaving, setDeviceSaving] = useState(false);

  // Fleet view for the superadmin. RLS hides other owners' machines from the
  // browser session, so this list comes from the device-admin function.
  const [adminDevices, setAdminDevices] = useState(null);
  const [adminOwners, setAdminOwners] = useState([]);
  const [devicesLoading, setDevicesLoading] = useState(false);
  const [transferTarget, setTransferTarget] = useState(null); // {id,name,owner_id}
  const [transferConfirm, setTransferConfirm] = useState(null); // {market,from,to}
  const [transferring, setTransferring] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState(null);     // {machid,name,sales,inventory}

  // Rename, available to the owner of the machine (plain RLS-scoped UPDATE).
  const [renamingMarket, setRenamingMarket] = useState(null); // {id,name}
  const [releaseTarget, setReleaseTarget] = useState(null);   // {id,name}


  async function openCatalogPicker() {
    setShowCatalogPicker(true);
    if (pickerProducts == null) {
      try {
        // Owner-scoped — RLS enforces it server-side, the .eq() is
        // belt-and-suspenders so the query plan filters early and the
        // result is empty on dev DBs before the RLS migration is applied.
        const ownerId = session?.user?.id;
        if (!ownerId) {
          setPickerProducts([]);
          return;
        }
        const { data, error } = await supabase
          .from('products')
          .select('id,name,image_url,emoji,category_id,volume_ml')
          .eq('owner_id', ownerId)
          .eq('is_archived', false)
          .eq('is_draft', false)
          .order('name');
        if (error) throw error;
        setPickerProducts(data || []);
      } catch (err) {
        showToast(t('catalog_load_error'), 'error');
        setPickerProducts([]);
      }
    }
  }

  // One shared timer: without clearing the previous one, an older toast's
  // timeout would cut a newly raised warning short.
  const toastTimer = useRef(null);
  const showToast = (message, type = 'success') => {
    setToast({ message, type });
    clearTimeout(toastTimer.current);
    // Warnings linger — they usually carry an instruction ("move it via
    // Transfer"), not just an acknowledgement.
    toastTimer.current = setTimeout(() => setToast(null), type === 'error' ? 6000 : 3000);
  };

  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session } }) => {
      setSession(session);
    });

    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session);
    });

    return () => subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (session) {
      fetchMarkets();
      fetchCategories();
    }
  }, [session]);

  // Keep the connection lamps current while a machine list is on screen.
  // Without this the panel showed the snapshot it loaded with — a tab left
  // open for an hour reported hour-old state, which is worse than no lamp:
  // the operator trusts it.
  //
  // Only while the relevant tab is open, and only while the page is actually
  // visible: a phone in a pocket or a background tab has nobody looking at
  // it, and browsers throttle its timers anyway. Coming back to the tab
  // refreshes immediately rather than waiting out the interval.
  useEffect(() => {
    if (!session) return;
    const onDevices = activeTab === 'inventory';
    const onFleet = activeTab === 'users' && isSuperadmin;
    if (!onDevices && !onFleet) return;

    const refresh = () => {
      if (document.visibilityState !== 'visible') return;
      if (onDevices) fetchMarkets();
      if (onFleet) fetchAdminDevices();
    };
    const id = setInterval(refresh, 30000);
    document.addEventListener('visibilitychange', refresh);
    return () => {
      clearInterval(id);
      document.removeEventListener('visibilitychange', refresh);
    };
  }, [session, activeTab, isSuperadmin]);

  async function fetchCategories() {
    try {
      // RLS limits categories to owner_id=auth.uid() OR owner_id IS NULL
      // (legacy shared rows from before the per-owner migration). No
      // explicit .eq() here so the legacy NULL rows still show up.
      const { data, error } = await supabase.from('categories').select('*').order('name_ru');
      if (error && error.code !== '42P01') throw error; // Ignore table missing error until user runs SQL
      if (data) setCategories(data);
    } catch (err) {
      console.error('Error fetching categories:', err);
    }
  }

  useEffect(() => {
    if (selectedMarketId && activeTab === 'inventory') {
      fetchProducts(selectedMarketId);
    }
  }, [selectedMarketId, activeTab]);

  useEffect(() => {
    if (session && activeTab === 'sales') {
      fetchSales();
    }
    // Re-query server-side whenever a sales filter changes.
  }, [session, activeTab, timeFilter, selectedSalesMarket, periodFrom, periodTo]);

  useEffect(() => {
    if (session && activeTab === 'catalog') {
      fetchCatalogProducts();
    }
  }, [session, activeTab]);

  // The superadmin lands on Administration, not Sales — it's the panel they
  // actually open the app for. Runs once: after that the operator's own tab
  // choice stands, including going back to Sales.
  const landedRef = useRef(false);
  useEffect(() => {
    if (session && isSuperadmin && !landedRef.current) {
      landedRef.current = true;
      setActiveTab('users');
    }
  }, [session, isSuperadmin]);

  useEffect(() => {
    if (session && isSuperadmin && activeTab === 'users') {
      fetchUsers();
      fetchAdminDevices();
    }
  }, [session, isSuperadmin, activeTab]);

  // Call one of the admin edge functions with the operator's own session token
  // (supabase-js attaches it automatically while a session exists). invoke()
  // reports every non-2xx as the same generic message, so dig the function's
  // own JSON `error` out of the response body.
  async function invokeAdminFn(name, options) {
    const { data, error } = await supabase.functions.invoke(name, options);
    if (error) {
      let payload = null;
      try { payload = await error.context?.json(); } catch (_) { /* not JSON */ }
      const err = new Error(payload?.error || error.message);
      err.code = payload?.error;   // stable machine-readable code
      err.details = payload;       // full body — e.g. the row counts on a delete
      throw err;
    }
    return data;
  }

  async function fetchUsers() {
    setUsersLoading(true);
    try {
      const data = await invokeAdminFn('admin-create-user', { method: 'GET' });
      setUsers(data?.users || []);
    } catch (err) {
      console.error('Error fetching users:', err);
      showToast(`${t('users_load_error')}: ${err.message}`, 'error');
      setUsers([]);
    } finally {
      setUsersLoading(false);
    }
  }

  async function createUser() {
    const email = (newUser?.email || '').trim();
    const password = newUser?.password || '';
    if (!email) return showToast(t('user_email_required'), 'error');
    if (password.length < 8) return showToast(t('user_password_too_short'), 'error');

    setUserSaving(true);
    try {
      const data = await invokeAdminFn('admin-create-user', {
        body: { email, password, full_name: (newUser.full_name || '').trim() },
      });
      if (data?.user) setUsers(prev => [data.user, ...(prev || [])]);
      else fetchUsers();
      setNewUser(null);
      showToast(t('user_created'));
    } catch (err) {
      // The function answers 409 with the gotrue wording for a taken email.
      const taken = /already/i.test(err.message || '');
      showToast(taken ? t('user_email_taken') : `${t('user_create_error')}: ${err.message}`, 'error');
    } finally {
      setUserSaving(false);
    }
  }

  async function changePassword() {
    const password = pwdTarget?.password || '';
    if (password.length < 8) return showToast(t('user_password_too_short'), 'error');
    setUserSaving(true);
    try {
      await invokeAdminFn('admin-create-user', {
        body: { action: 'set_password', user_id: pwdTarget.id, password },
      });
      setPwdTarget(null);
      showToast(t('password_changed'));
    } catch (err) {
      showToast(`${t('password_change_error')}: ${err.message}`, 'error');
    } finally {
      setUserSaving(false);
    }
  }

  async function deleteUser() {
    if (!userDeleteTarget) return;
    setUserSaving(true);
    try {
      await invokeAdminFn('admin-create-user', {
        body: { action: 'delete', user_id: userDeleteTarget.id },
      });
      setUserDeleteTarget(null);
      await fetchUsers();
      showToast(t('user_deleted'));
    } catch (err) {
      // The function blocks deletion while the account still owns machines —
      // orphaned rows would be invisible in every panel.
      if (err.code === 'has_machines') {
        showToast(t('user_err_has_machines', { count: err.details?.machines ?? 0 }), 'error');
      } else if (err.code === 'cannot_delete_self') {
        showToast(t('user_err_cannot_delete_self'), 'error');
      } else {
        showToast(`${t('user_delete_error')}: ${err.message}`, 'error');
      }
      setUserDeleteTarget(null);
    } finally {
      setUserSaving(false);
    }
  }

  async function fetchAdminDevices() {
    setDevicesLoading(true);
    try {
      const data = await invokeAdminFn('device-admin', { body: { action: 'list' } });
      setAdminDevices(data?.markets || []);
      setAdminOwners(data?.owners || []);
    } catch (err) {
      console.error('Error fetching devices:', err);
      showToast(`${t('devices_load_error')}: ${err.message}`, 'error');
      setAdminDevices([]);
    } finally {
      setDevicesLoading(false);
    }
  }

  async function transferDevice() {
    const { market, to } = transferConfirm || {};
    if (!market || !to) return;
    setTransferring(true);
    try {
      const data = await invokeAdminFn('device-admin', {
        body: { action: 'transfer', machid: market.id, owner_id: to.id },
      });
      setTransferConfirm(null);
      setTransferTarget(null);
      await Promise.all([fetchAdminDevices(), fetchUsers(), fetchMarkets()]);
      showToast(`${t('device_transferred')} → ${data?.owner_email ?? to.email}`);
    } catch (err) {
      showToast(`${t('device_transfer_error')}: ${err.message}`, 'error');
    } finally {
      setTransferring(false);
    }
  }

  // Two-phase on purpose: the first call comes back with `confirm_required`
  // plus the row counts, so the confirmation dialog can say exactly how much
  // sales history the CASCADE is about to take with it.
  async function deleteDevice(machid, confirm = false) {
    try {
      await invokeAdminFn('device-admin', { body: { action: 'delete', machid, confirm } });
      setDeleteTarget(null);
      await Promise.all([fetchAdminDevices(), fetchMarkets()]);
      showToast(t('device_deleted'));
    } catch (err) {
      if (err.code === 'confirm_required') {
        setDeleteTarget(err.details || { machid });
        return;
      }
      if (err.code === 'has_pending_orders') {
        showToast(t('device_del_pending'), 'error');
        setDeleteTarget(null);
        return;
      }
      showToast(`${t('device_delete_error')}: ${err.message}`, 'error');
      setDeleteTarget(null);
    }
  }

  // Frees a machine whose tablet can't sign itself out — smashed, lost, or
  // already wiped. The only path when the tablet is gone: without it the
  // machid stays claimed forever and no replacement can pair.
  async function releaseTablet(m) {
    try {
      const { error } = await supabase.rpc('admin_release_machine', { p_machid: m.id });
      if (error) throw error;
      await fetchMarkets();
      showToast(t('tablet_released'));
    } catch (err) {
      showToast(`${t('tablet_release_error')}: ${err.message}`, 'error');
    } finally {
      setReleaseTarget(null);
    }
  }

  // An owner renaming its own machine goes straight to the table: the "Owner
  // manages micromarkets" policy already limits authenticated UPDATEs to
  // owner_id = auth.uid(), and only the name column is in the payload. From the
  // superadmin's fleet list (viaAdmin) the same UPDATE would match zero rows
  // for someone else's machine, so that path goes through device-admin.
  async function renameMarket() {
    const name = (renamingMarket?.name || '').trim();
    if (!name) return showToast(t('device_name_required'), 'error');
    try {
      if (renamingMarket.viaAdmin) {
        await invokeAdminFn('device-admin', {
          body: { action: 'rename', machid: renamingMarket.id, name },
        });
      } else {
        const { error } = await supabase
          .from('micromarkets').update({ name }).eq('id', renamingMarket.id);
        if (error) throw error;
      }
      setRenamingMarket(null);
      await fetchMarkets();
      if (isSuperadmin && adminDevices) fetchAdminDevices();
      showToast(t('device_renamed'));
    } catch (err) {
      showToast(`${t('device_rename_error')}: ${err.message}`, 'error');
    }
  }

  // Machine-readable codes from supabase/functions/device-claim/index.ts →
  // operator-facing text. Anything else falls through to the raw message.
  const DEVICE_CLAIM_ERRORS = {
    bad_machid: 'device_err_bad_machid',
    secret_required: 'device_err_secret_required',
    machine_not_found: 'device_err_not_found',
    secret_mismatch: 'device_err_secret_mismatch',
  };

  async function claimDevice() {
    const machid = String(addingDevice?.machid ?? '').trim();
    const secret = String(addingDevice?.secret ?? '').trim();
    if (!/^\d+$/.test(machid)) return showToast(t('device_err_bad_machid'), 'error');
    if (!secret) return showToast(t('device_err_secret_required'), 'error');

    setDeviceSaving(true);
    try {
      const data = await invokeAdminFn('device-claim', {
        body: {
          machid: Number(machid),
          secret,
          name: (addingDevice.name || '').trim(),
          kind: addingDevice.kind || 'vending',
        },
      });
      setAddingDevice(null);
      await fetchMarkets();
      if (isSuperadmin && adminDevices) fetchAdminDevices();
      showToast(data?.claimed ? t('device_linked') : t('device_added'));
    } catch (err) {
      // A machine that's already assigned can only be moved via transfer —
      // name whoever holds it so it's obvious where to go next.
      if (err.code === 'already_claimed') {
        showToast(t('device_err_already_claimed', {
          email: err.details?.owner_email || '—',
        }), 'error');
        return;
      }
      const key = DEVICE_CLAIM_ERRORS[err.code];
      showToast(key ? t(key) : `${t('device_add_error')}: ${err.message}`, 'error');
    } finally {
      setDeviceSaving(false);
    }
  }

  async function fetchCatalogProducts() {
    setLoading(true);
    try {
      const ownerId = session?.user?.id;
      if (!ownerId) {
        setCatalogProducts([]);
        return;
      }
      const { data, error } = await supabase
        .from('products')
        .select('*')
        .eq('owner_id', ownerId)
        .order('is_draft', { ascending: false })
        .order('name', { ascending: true });
      if (error) throw error;
      setCatalogProducts(data || []);
    } catch (err) {
      console.error('Error fetching catalog:', err);
      showToast(t('catalog_load_error'), 'error');
    } finally {
      setLoading(false);
    }
  }

  async function saveCatalogProduct() {
    if (!editingCatalog?.name?.trim()) return showToast(t('name_required'), 'error');
    setLoading(true);
    try {
      const payload = {
        name: editingCatalog.name.trim(),
        image_url: editingCatalog.image_url || null,
        emoji: editingCatalog.emoji || null,
        category_id: editingCatalog.category_id || null,
        volume_ml: editingCatalog.volume_ml === '' || editingCatalog.volume_ml == null
          ? null
          : Number(editingCatalog.volume_ml),
        description: editingCatalog.description || null,
        is_draft: !!editingCatalog.is_draft,
      };
      if (editingCatalog.id === 'new') {
        // owner_id is auto-filled by RLS to auth.uid() of the inserter
        // (or null; we leave it to the DB-level default + policy chain).
        const { error } = await supabase.from('products').insert({
          ...payload,
          owner_id: session?.user?.id || null,
          is_draft: false, // admin-created rows are published immediately
        });
        if (error) throw error;
        showToast(t('product_added'));
      } else {
        const { error } = await supabase
          .from('products')
          .update(payload)
          .eq('id', editingCatalog.id);
        if (error) throw error;
        showToast(t('product_saved'));
      }
      setEditingCatalog(null);
      fetchCatalogProducts();
    } catch (err) {
      console.error('Save catalog error:', err);
      showToast(t('save_error') + ': ' + err.message, 'error');
    } finally {
      setLoading(false);
    }
  }

  async function archiveCatalogProduct(p) {
    try {
      const { error } = await supabase
        .from('products')
        .update({ is_archived: !p.is_archived })
        .eq('id', p.id);
      if (error) throw error;
      showToast(p.is_archived ? t('restored') : t('archived_toast'));
      fetchCatalogProducts();
    } catch (err) {
      showToast(t('save_error') + ': ' + err.message, 'error');
    }
  }

  async function publishDraft(p) {
    try {
      const { error } = await supabase
        .from('products')
        .update({ is_draft: false })
        .eq('id', p.id);
      if (error) throw error;
      showToast(t('published'));
      fetchCatalogProducts();
    } catch (err) {
      showToast(t('save_error') + ': ' + err.message, 'error');
    }
  }

  async function deleteCatalogProduct(p) {
    if (!confirm(`${t('delete_catalog_confirm_prefix')}${p.name}${t('delete_catalog_confirm_suffix')}`)) return;
    try {
      const { error } = await supabase.from('products').delete().eq('id', p.id);
      if (error) throw error;
      showToast(t('deleted_toast'));
      fetchCatalogProducts();
    } catch (err) {
      showToast(t('delete_catalog_failed'), 'error');
    }
  }

  // Catalog modal uses its own file-input handler so the shared crop
  // modal knows to route the resulting URL into editingCatalog.
  const onCatalogFileChange = (e) => {
    if (e.target.files && e.target.files.length > 0) {
      const file = e.target.files[0];
      const reader = new FileReader();
      reader.readAsDataURL(file);
      reader.onload = () => {
        setCropTarget('catalog');
        setCropImageSrc(reader.result);
      };
    }
  };

  async function fetchSales() {
    setLoading(true);
    try {
      let q = supabase
        .from('sales')
        .select(`
          *,
          micromarkets(name),
          sales_items(
            *,
            inventory(name)
          )
        `)
        .order('created_at', { ascending: false });

      // Machine filter
      if (selectedSalesMarket !== 'all') {
        q = q.eq('micromarket_id', selectedSalesMarket);
      }

      // Time filter (server-side)
      let since = null;
      if (timeFilter === 'day') {
        const d = new Date(); d.setHours(0, 0, 0, 0); since = d.toISOString();
      } else if (timeFilter === 'week') {
        const d = new Date(); d.setDate(d.getDate() - 7); since = d.toISOString();
      } else if (timeFilter === 'month') {
        const d = new Date(); d.setMonth(d.getMonth() - 1); since = d.toISOString();
      }
      if (since) q = q.gte('created_at', since);
      if (timeFilter === 'period') {
        if (periodFrom) q = q.gte('created_at', new Date(periodFrom).toISOString());
        if (periodTo) {
          const to = new Date(periodTo); to.setHours(23, 59, 59, 999);
          q = q.lte('created_at', to.toISOString());
        }
      }

      // "recent" = just the last few; filtered views get a higher safety cap.
      q = q.limit(timeFilter === 'recent' ? SALES_PAGE_SIZE : 500);

      const { data, error } = await q;
      if (error) throw error;
      setSales(data || []);
    } catch (err) {
      console.error('Error fetching sales:', err);
      showToast(t('sales_load_error'), 'error');
    } finally {
      setLoading(false);
    }
  }

  async function fetchMarkets() {
    try {
      // Two queries, merged here rather than one embedded select: PostgREST
      // can't infer a relationship to a view, and `online` has to come from
      // the view — the 3-minute threshold is evaluated in SQL against the
      // database clock. Computing it here would compare the tablet's beat
      // to the browser's clock, which on a kiosk network is often minutes
      // out and would flip machines offline at random.
      const [marketsRes, statusRes] = await Promise.all([
        supabase.from('micromarkets').select('id, name, layout_json, kind, qr_token'),
        supabase.from('device_status_view').select('machid, last_seen_at, board_ok, online'),
      ]);
      if (marketsRes.error) throw marketsRes.error;
      const byId = new Map(
        (statusRes.data || []).map((s) => [String(s.machid), s]),
      );
      setMarkets((marketsRes.data || []).map((m) => ({
        ...m,
        // Absent row = the machine has never reported. Left undefined so the
        // badge can say "never seen" instead of claiming it's offline —
        // a machine that isn't installed yet isn't a fault.
        status: byId.get(String(m.id)),
      })));
      // No auto-select: the Inventory tab opens on the machine list and the
      // operator drills into a specific machine. Sales/Catalog don't need one.
    } catch (err) {
      console.error('Error fetching markets:', err);
      showToast(t('could_not_load_markets'), 'error');
    }
  }

  // Layout of the currently-selected market, parsed once and memoized
  // so CabinetLayout doesn't re-parse on every render. Falls back to
  // factory 6×6 when layout_json hasn't been pushed yet (new pairing
  // or older client).
  const selectedMarketLayout = React.useMemo(() => {
    const market = markets.find(m => String(m.id) === String(selectedMarketId));
    return parseLayout(market?.layout_json);
  }, [markets, selectedMarketId]);

  // Static micromarkets are open-shelf: no motors/cabinet layout, so the admin
  // shows a flat product list (with add/edit/delete) instead of the cabinet view.
  const selectedMarket = markets.find(m => String(m.id) === String(selectedMarketId));
  const isStaticMarket = selectedMarket?.kind === 'micromarket_static';

  function addStaticProduct() {
    setEditingProduct({
      id: 'new', product_id: null, name: '', price: 0, stock: 0,
      image_url: '', emoji: '', category_id: null, motor_id: null,
    });
  }

  async function fetchProducts(marketId) {
    setLoading(true);
    try {
      // Pull the joined products row so the list can display the
      // canonical SKU image/name even when the inventory row's own
      // image_url is stale (older clients used to write it directly).
      const { data, error } = await supabase
        .from('inventory')
        .select('*, products(id,name,image_url,emoji,category_id,volume_ml,is_draft)')
        .eq('micromarket_id', marketId);
      if (error) throw error;
      // Sorting happens at render time via filteredProducts so the
      // ordering tracks the selected market's layout.
      setProducts(data || []);
    } catch (err) {
      console.error('Error fetching products:', err);
    } finally {
      setLoading(false);
    }
  }

  // Вызывается при выборе файла
  const onFileChange = (e) => {
    if (e.target.files && e.target.files.length > 0) {
      const file = e.target.files[0];
      const reader = new FileReader();
      reader.readAsDataURL(file);
      reader.onload = () => {
        setCropImageSrc(reader.result); // Открываем модалку кроппера
      };
    }
  };

  // Конвертация обрезанной области в Blob
  const getCroppedImg = (imageSrc, pixelCrop) => {
    return new Promise((resolve, reject) => {
      const img = new window.Image();
      img.src = imageSrc;
      img.onload = () => {
        const canvas = document.createElement('canvas');
        const ctx = canvas.getContext('2d');
        
        const targetSize = 600;
        canvas.width = targetSize;
        canvas.height = targetSize;
        
        ctx.fillStyle = 'white';
        ctx.fillRect(0, 0, targetSize, targetSize);
        
        ctx.drawImage(
          img,
          pixelCrop.x,
          pixelCrop.y,
          pixelCrop.width,
          pixelCrop.height,
          0,
          0,
          targetSize,
          targetSize
        );
        
        canvas.toBlob((blob) => {
          if (!blob) return reject(new Error('Canvas empty'));
          resolve(blob);
        }, 'image/webp', 0.85);
      };
      img.onerror = reject;
    });
  };

  // Загрузка готового обрезанного фото
  const handleUploadCrop = async () => {
    if (!cropImageSrc || !croppedAreaPixels) return;
    setUploadingImage(true);
    try {
      const processedBlob = await getCroppedImg(cropImageSrc, croppedAreaPixels);
      
      const fileName = `${Math.random().toString(36).substring(2, 15)}.webp`;
      const filePath = `products/${fileName}`;

      const { error: uploadError } = await supabase.storage
        .from('product-images')
        .upload(filePath, processedBlob, {
          // Filenames are random + upsert:false, so each URL is immutable —
          // safe to cache for a year (was 3600 = 1h, far too short).
          cacheControl: '31536000',
          upsert: false,
          contentType: 'image/webp'
        });

      if (uploadError) throw uploadError;

      const { data } = supabase.storage.from('product-images').getPublicUrl(filePath);

      if (cropTarget === 'catalog') {
        setEditingCatalog(prev => prev ? { ...prev, image_url: data.publicUrl } : prev);
      } else {
        setEditingProduct(prev => prev ? { ...prev, image_url: data.publicUrl } : prev);
      }
      setCropImageSrc(null);
      setCropTarget('inventory');
    } catch (err) {
      console.error('Error uploading image:', err);
      showToast(`${t('photo_upload_error')}: ${err.message || JSON.stringify(err)}`, 'error');
    } finally {
      setUploadingImage(false);
    }
  };

  async function addCategory() {
    if (!newCatRu.trim() || !newCatKz.trim() || !newCatEn.trim()) return showToast(t('fill_all_languages'), 'error');
    try {
      const ownerId = session?.user?.id;
      if (!ownerId) return showToast(t('session_inactive'), 'error');
      const { error } = await supabase.from('categories').insert({
        name_ru: newCatRu.trim(),
        name_kz: newCatKz.trim(),
        name_en: newCatEn.trim(),
        owner_id: ownerId,
      });
      if (error) throw error;
      setNewCatRu(''); setNewCatKz(''); setNewCatEn('');
      fetchCategories();
      showToast(t('category_added'));
    } catch (err) {
      showToast(`${t('save_error')}: ${err.message}`, 'error');
    }
  }

  async function deleteCategory(id) {
    if (!confirm(t('delete_category_confirm'))) return;
    try {
      await supabase.from('categories').delete().eq('id', id);
      fetchCategories();
      showToast(t('category_deleted'));
    } catch (err) {
      showToast(t('category_delete_error'), 'error');
    }
  }

  async function saveProduct() {
    if (!editingProduct.product_id) {
      return showToast(t('pick_product_from_catalog'), 'error');
    }
    if (editingProduct.price == null || editingProduct.price === '') {
      return showToast(t('specify_price'), 'error');
    }

    setLoading(true);
    try {
      // Keep name/image_url/emoji/category_id mirrored on inventory for
      // back-compat with older tablet builds that read those columns
      // directly. The catalog row is the source of truth — when admin
      // edits the product, this row will fall behind until a re-link.
      // Wiring fields (motor_id, motor_type, curtain_mode) are not in
      // the payload — they're owned by the tablet's Motor Setup screen.
      // Updating them from admin could put a product on the wrong
      // physical spiral, so we never touch them here.
      const payload = {
        product_id: editingProduct.product_id,
        name: editingProduct.name || '',
        category_id: editingProduct.category_id || null,
        price: Number(editingProduct.price),
        stock: Number(editingProduct.stock) || 0,
        image_url: editingProduct.image_url || null,
        emoji: editingProduct.emoji || null,
      };
      if (editingProduct.id === 'new') {
        const { error } = await supabase.from('inventory').insert({
          ...payload,
          micromarket_id: selectedMarketId,
        });
        if (error) throw error;
      } else {
        const { error } = await supabase
          .from('inventory')
          .update(payload)
          .eq('id', editingProduct.id);
        if (error) throw error;
      }
      setEditingProduct(null);
      fetchProducts(selectedMarketId);
    } catch (err) {
      console.error('Error saving product:', err);
      showToast(`${t('save_product_error')}: ${err.message || JSON.stringify(err)}`, 'error');
    } finally {
      setLoading(false);
    }
  }

  /// Apply a chosen catalog product into the inventory edit form:
  /// the picker passes the full `products` row, we mirror its display
  /// fields onto editingProduct + record the FK.
  function applyCatalogToInventory(cp) {
    setEditingProduct(prev => ({
      ...prev,
      product_id: cp.id,
      name: cp.name,
      image_url: cp.image_url || '',
      emoji: cp.emoji || '',
      category_id: cp.category_id || null,
    }));
    setShowCatalogPicker(false);
  }

  async function deleteProduct(id) {
    setProductToDelete(id);
  }

  async function confirmDelete() {
    if (!productToDelete) return;
    const id = productToDelete;
    console.log('Попытка окончательного удаления товара с ID:', id);
    
    try {
      const { error, status } = await supabase.from('inventory').delete().eq('id', id);
      console.log('Статус ответа базы данных:', status);
      
      if (error) throw error;
      
      showToast(t('product_deleted'));
      setProductToDelete(null);
      fetchProducts(selectedMarketId);
    } catch (err) {
      console.error('Подробная ошибка удаления:', err);
      showToast(t('delete_error') + ': ' + err.message, 'error');
      setProductToDelete(null);
    }
  }

  async function updateStock(product, delta) {
    const newStock = Math.max(0, product.stock + delta);
    setProducts(products.map(p => p.id === product.id ? { ...p, stock: newStock } : p));
    
    try {
      const { error } = await supabase.from('inventory').update({ stock: newStock }).eq('id', product.id);
      if (error) throw error;
      showToast(t('stock_saved'));
    } catch (err) {
      console.error('Error updating stock:', err);
      showToast(t('stock_save_error'), 'error');
      fetchProducts(selectedMarketId); // Revert on error
    }
  }

  async function updatePrice(product, newPrice) {
    if (newPrice === product.price || newPrice < 0) return;
    setProducts(products.map(p => p.id === product.id ? { ...p, price: newPrice } : p));
    
    try {
      const { error } = await supabase.from('inventory').update({ price: newPrice }).eq('id', product.id);
      if (error) throw error;
      showToast(t('price_changed'));
    } catch (err) {
      console.error('Error updating price:', err);
      showToast(t('price_save_error'), 'error');
      fetchProducts(selectedMarketId); // Revert on error
    }
  }

  const toggleLanguage = () => {
    const langs = ['ru', 'kk', 'en'];
    const nextIdx = (langs.indexOf(i18n.language) + 1) % langs.length;
    i18n.changeLanguage(langs[nextIdx]);
  };

  if (!session) {
    return (
      <div className="min-h-screen bg-surface-container-lowest flex items-center justify-center p-5 font-lexend">
        <div className="bg-white p-8 rounded-3xl shadow-2xl max-w-sm w-full border border-surface-container-high">
          <h2 className="text-2xl font-black text-primary mb-6 text-center">{t('login_title')}</h2>
          <div className="space-y-4">
            <div>
              <label className="text-xs font-bold opacity-50 ml-2">Email</label>
              <input
                type="email"
                value={email}
                onChange={e => setEmail(e.target.value)}
                className="w-full p-3 bg-surface-container-low rounded-xl font-bold focus:outline-none focus:ring-2 focus:ring-primary/50"
              />
            </div>
            <div>
              <label className="text-xs font-bold opacity-50 ml-2">{t('password')}</label>
              <input
                type="password"
                value={password}
                onChange={e => setPassword(e.target.value)}
                className="w-full p-3 bg-surface-container-low rounded-xl font-bold focus:outline-none focus:ring-2 focus:ring-primary/50"
              />
            </div>
            <button
              onClick={async () => {
                setAuthLoading(true);
                const { error } = await supabase.auth.signInWithPassword({ email, password });
                if (error) showToast(`${t('login_error')}: ${error.message}`, 'error');
                setAuthLoading(false);
              }}
              disabled={authLoading}
              className="w-full bg-primary text-white py-3 rounded-xl font-black shadow-lg shadow-primary/20 active:scale-95 transition-all mt-4 flex justify-center"
            >
              {authLoading ? <Loader2 className="animate-spin" /> : t('login_btn')}
            </button>
          </div>
        </div>
        <Toast toast={toast} onClose={() => setToast(null)} />
      </div>
    );
  }

  const filteredProducts = (selectedCategoryFilter === 'All'
    ? products
    : products.filter(p => p.category_id === selectedCategoryFilter))
    .slice()
    .sort((a, b) => {
      // Sort by the operator's per-machine layout so the list mirrors
      // what the cabinet view shows (MP2404 puts "01" before "11"
      // even though motor 99 > motor 89).
      const la = motorToSlotLabel(a.motor_id, selectedMarketLayout);
      const lb = motorToSlotLabel(b.motor_id, selectedMarketLayout);
      if (la == null && lb == null) return (a.name || '').localeCompare(b.name || '');
      if (la == null) return 1;
      if (lb == null) return -1;
      return la.localeCompare(lb, undefined, { numeric: true });
    });

  // Filtering (market + time/period) now happens server-side in fetchSales();
  // render exactly what was loaded.
  const filteredSales = sales;

  const totalSalesAmount = filteredSales.reduce((sum, s) => sum + (s.amount || 0), 0);

  return (
    <div className="min-h-screen bg-slate-200 text-slate-900 p-3 md:p-6 font-lexend">
      <header className="flex justify-between items-center mb-4 sm:mb-6 bg-white p-3 sm:p-4 rounded-2xl shadow-md border border-slate-300 flex-wrap gap-3 sm:gap-4">
        <div className="flex items-center gap-4 flex-1 min-w-[280px]">
          <div className="flex flex-col">
            <h1 className="text-lg sm:text-xl font-black text-slate-900 tracking-tight">Micromart</h1>
            <span className="text-[9px] sm:text-[10px] font-bold text-slate-500 uppercase tracking-widest">{t('admin_panel')}</span>
          </div>
          <div className="h-10 w-[1px] bg-slate-300 hidden sm:block"></div>
          <div className="flex bg-slate-200 p-1 rounded-xl border border-slate-300 w-full sm:w-auto">
            {/* Administration first — it's the superadmin's landing tab. */}
            {isSuperadmin && (
              <button
                onClick={() => setActiveTab('users')}
                className={`flex-1 sm:flex-none px-2.5 sm:px-4 py-2 sm:py-1.5 rounded-lg font-bold transition-all text-xs ${activeTab === 'users' ? 'bg-white text-primary shadow-md' : 'text-slate-600 hover:text-slate-900'}`}
              >
                {t('tab_users')}
              </button>
            )}
            <button
              onClick={() => setActiveTab('sales')}
              className={`flex-1 sm:flex-none px-2.5 sm:px-4 py-2 sm:py-1.5 rounded-lg font-bold transition-all text-xs ${activeTab === 'sales' ? 'bg-white text-primary shadow-md' : 'text-slate-600 hover:text-slate-900'}`}
            >
              {t('sales')}
            </button>
            <button
              onClick={() => { closeMarket(); setActiveTab('inventory'); }}
              className={`flex-1 sm:flex-none px-2.5 sm:px-4 py-2 sm:py-1.5 rounded-lg font-bold transition-all text-xs ${activeTab === 'inventory' ? 'bg-white text-primary shadow-md' : 'text-slate-600 hover:text-slate-900'}`}
            >
              {t('devices')}
            </button>
            <button
              onClick={() => setActiveTab('catalog')}
              className={`flex-1 sm:flex-none px-2.5 sm:px-4 py-2 sm:py-1.5 rounded-lg font-bold transition-all text-xs ${activeTab === 'catalog' ? 'bg-white text-primary shadow-md' : 'text-slate-600 hover:text-slate-900'}`}
            >
              {t('tab_catalog')}
            </button>
          </div>
        </div>
        <div className="flex items-center gap-3">
          <button onClick={toggleLanguage} className="flex items-center gap-1 hover:opacity-70 transition-all mr-2">
            <Languages size={16} className="text-slate-400" />
            <span className="text-[10px] font-black uppercase text-slate-400">{i18n.language}</span>
          </button>
          {/* No global machine picker: Sales/Catalog don't need one, and the
              Inventory tab has its own machine list to drill into. */}
          {session?.user?.email && (
            <span
              className="text-[11px] font-medium text-slate-400 max-w-[180px] truncate"
              title={session.user.email}
            >
              {session.user.email}
            </span>
          )}
          <button
            onClick={() => supabase.auth.signOut()}
            className="text-xs font-bold text-on-surface-variant hover:text-red-500 transition-colors ml-4"
          >
            {t('logout')}
          </button>
        </div>
      </header>

      <div className="bg-white rounded-2xl sm:rounded-3xl p-3 sm:p-4 md:p-8 shadow-lg border border-slate-300">
          {activeTab === 'users' && isSuperadmin ? (
            <UsersTab
              users={users}
              loading={usersLoading}
              onCreate={() => setNewUser({ email: '', password: '', full_name: '' })}
              onAddDevice={() => setAddingDevice({ machid: '', secret: '', name: '', kind: 'vending' })}
              onChangePassword={(u) => setPwdTarget({ id: u.id, email: u.email, password: '' })}
              onDeleteUser={(u) => setUserDeleteTarget({ id: u.id, email: u.email })}
              currentUserId={session?.user?.id}
              onRefresh={() => { fetchUsers(); fetchAdminDevices(); }}
              devices={adminDevices}
              devicesLoading={devicesLoading}
              onTransfer={(m) => setTransferTarget(m)}
              onDelete={(machid) => deleteDevice(machid)}
              onRename={(m) => setRenamingMarket({ ...m, viaAdmin: true })}
            />
          ) : activeTab === 'catalog' ? (
            <CatalogTab
              products={catalogProducts}
              categories={categories}
              filter={catalogFilter}
              setFilter={setCatalogFilter}
              loading={loading}
              onCreate={() => setEditingCatalog({
                id: 'new',
                name: '',
                image_url: '',
                emoji: '',
                category_id: categories[0]?.id || null,
                volume_ml: '',
                description: '',
                is_draft: false,
                is_archived: false,
              })}
              onEdit={(p) => setEditingCatalog(p)}
              onArchive={archiveCatalogProduct}
              onPublish={publishDraft}
              onDelete={deleteCatalogProduct}
            />
          ) : activeTab === 'inventory' ? (
            !selectedMarketId ? (
              <div>
                {/* No "add device" button here: enrolling a machine is a
                    platform-admin act and lives on the Users tab. This tab is
                    what an owner sees, and device-claim refuses them anyway. */}
                <h2 className="text-2xl font-black text-slate-900 mb-1">{t('devices')}</h2>
                <p className="text-[11px] font-bold text-slate-500 uppercase tracking-widest mb-6">{t('select_machine')}</p>
                <div className="space-y-2">
                  {markets.map(m => {
                    // Status + type badge. On a phone they don't fit on the
                    // name's line — the row put five fixed-width items next
                    // to a shrinking name and everything collided — so they
                    // drop under it and get the full width instead.
                    const meta = (
                      <>
                        <DeviceStatusDot status={m.status} kind={m.kind} withLabel />
                        <span className={`text-[9px] font-black uppercase tracking-wider px-2 py-1 rounded-lg shrink-0 ${m.kind === 'micromarket_static' ? 'bg-emerald-100 text-emerald-700' : 'bg-indigo-100 text-indigo-700'}`}>
                          {m.kind === 'micromarket_static' ? t('badge_micromarket') : t('badge_vending')}
                        </span>
                      </>
                    );
                    return (
                    <div
                      key={m.id}
                      className="w-full flex items-center gap-3 p-4 rounded-2xl bg-slate-50 border-2 border-slate-200 hover:border-primary hover:bg-white hover:shadow-md transition-all"
                    >
                      <button
                        onClick={() => openMarket(m.id)}
                        className="flex items-center gap-3 flex-1 min-w-0 text-left"
                      >
                        <div className="w-11 h-11 rounded-xl bg-indigo-600 text-white flex items-center justify-center shrink-0">
                          <Package size={20} />
                        </div>
                        <div className="flex-1 min-w-0">
                          <div className="font-bold text-slate-900 truncate">{m.name || `${t('market')} #${m.id}`}</div>
                          <div className="text-[11px] font-bold text-slate-500 uppercase tracking-widest">{t('apparatus_no')}{m.id}</div>
                          <div className="flex sm:hidden items-center gap-2 mt-2 flex-wrap">{meta}</div>
                        </div>
                      </button>
                      <div className="hidden sm:flex items-center gap-3 shrink-0">{meta}</div>
                      <button
                        onClick={() => setRenamingMarket({ id: m.id, name: m.name || '' })}
                        title={t('rename')}
                        className="p-2 rounded-lg bg-white border border-slate-300 text-slate-600 hover:text-primary hover:border-primary transition-all shrink-0"
                      >
                        <Pencil size={15} />
                      </button>
                      <button
                        onClick={() => setReleaseTarget({ id: m.id, name: m.name || '' })}
                        title={t('release_tablet')}
                        className="p-2 rounded-lg bg-white border border-slate-300 text-slate-600 hover:text-amber-600 hover:border-amber-400 transition-all shrink-0"
                      >
                        <LinkOff size={15} />
                      </button>
                      <button
                        onClick={() => openMarket(m.id)}
                        className="shrink-0 text-slate-400 hover:text-primary transition-colors"
                      >
                        <ChevronRight size={18} />
                      </button>
                    </div>
                    );
                  })}
                  {markets.length === 0 && (
                    <p className="text-sm text-slate-400 italic p-4">{t('no_machines')}</p>
                  )}
                </div>
              </div>
            ) : (
            <>
              {/* Was a bare text link and got missed on a phone. Now a real
                  bordered button — and inline-flex, not flex, or a
                  block-level button would stretch across the whole card. */}
              <button
                onClick={closeMarket}
                className="inline-flex w-fit items-center gap-1.5 mb-4 px-3 py-2 rounded-xl bg-slate-100 border-2 border-slate-300 text-sm font-bold text-slate-700 hover:bg-slate-200 hover:border-primary hover:text-primary active:scale-95 transition-all"
              >
                <ChevronLeft size={18} /> {t('all_machines_back')}
              </button>
              <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 mb-8">
                <div>
                  <h2 className="text-2xl font-black text-slate-900">{t('inventory')}</h2>
                  <p className="text-[11px] font-bold text-slate-500 uppercase tracking-widest">{t('apparatus_no')}{selectedMarketId}</p>
                </div>
                <div className="flex gap-2 w-full sm:w-auto items-center">
                  {isStaticMarket && (
                    <button
                      onClick={addStaticProduct}
                      className="flex-1 sm:flex-none flex items-center justify-center gap-2 bg-primary text-white px-4 py-2.5 rounded-xl font-bold hover:opacity-90 transition-all text-sm"
                    >
                      <Plus size={16} /> {t('add')}
                    </button>
                  )}
                  {isStaticMarket && (
                    <button
                      onClick={() => setQrModalMarket(markets.find(m => String(m.id) === String(selectedMarketId)) || { id: selectedMarketId })}
                      className="flex-1 sm:flex-none flex items-center justify-center gap-2 bg-slate-900 text-white px-4 py-2.5 rounded-xl font-bold hover:bg-slate-700 transition-all text-sm"
                    >
                      <QrCode size={16} /> QR
                    </button>
                  )}
                  <button
                    onClick={() => setShowCategoryManager(true)}
                    className="flex-1 sm:flex-none flex items-center justify-center gap-2 bg-slate-200 text-slate-700 border border-slate-300 px-4 py-2.5 rounded-xl font-bold hover:bg-slate-300 transition-all text-sm"
                  >
                    {t('categories')}
                  </button>
                </div>
              </div>

              {/* Фильтры */}
              <div className="flex gap-2 mb-8 overflow-x-auto pb-3 no-scrollbar border-b border-slate-200">
                <button
                  onClick={() => setSelectedCategoryFilter('All')}
                  className={`px-5 py-2 rounded-xl text-xs font-bold whitespace-nowrap transition-all ${selectedCategoryFilter === 'All' ? 'bg-slate-900 text-white shadow-md' : 'bg-white text-slate-600 border border-slate-300 hover:border-slate-400 hover:bg-slate-50'}`}
                >
                  {t('all_items')}
                </button>
                {categories.map(c => (
                  <button
                    key={c.id}
                    onClick={() => setSelectedCategoryFilter(c.id)}
                    className={`px-5 py-2 rounded-xl text-xs font-bold whitespace-nowrap transition-all ${selectedCategoryFilter === c.id ? 'bg-slate-900 text-white shadow-md' : 'bg-white text-slate-600 border border-slate-300 hover:border-slate-400 hover:bg-slate-50'}`}
                  >
                    {c.name_ru}
                  </button>
                ))}
              </div>

              {/* Vending only: admin can edit existing slots but new rows must
                  come from the tablet (the operator maps motor_id on-site). */}
              {!isStaticMarket && (
              <div className="mb-3 flex items-start gap-2 bg-sky-50 border-2 border-sky-300 rounded-xl p-3">
                <Image size={16} className="text-sky-700 mt-0.5 shrink-0" />
                <div className="text-[12px] text-sky-900 leading-relaxed">
                  <span className="font-black">{t('new_slots_tablet_only')}</span>
                  <span className="opacity-80">{t('new_slots_tablet_hint')}</span>
                </div>
              </div>
              )}

              {!isStaticMarket && selectedMarketLayout._source === 'fallback' && (
                <div className="mb-6 flex items-start gap-2 bg-amber-50 border-2 border-amber-400 rounded-xl p-3">
                  <AlertTriangle size={16} className="text-amber-700 mt-0.5 shrink-0" />
                  <div className="text-[12px] text-amber-900 leading-relaxed">
                    <span className="font-black">{t('layout_fallback_title')}</span>
                    <span className="opacity-80">{t('layout_fallback_hint')}</span>
                  </div>
                </div>
              )}

              {loading && !editingProduct ? (
                <div className="flex justify-center p-20"><Loader2 className="animate-spin text-primary" size={32} /></div>
              ) : isStaticMarket ? (
                <StaticInventoryList
                  products={filteredProducts}
                  categories={categories}
                  stockLabel={t('stock_label')}
                  priceLabel={t('price_label')}
                  onEdit={(p) => setEditingProduct(p)}
                  onDelete={(p) => deleteProduct(p.id)}
                />
              ) : (
                <InventoryByLayout
                  products={filteredProducts}
                  layout={selectedMarketLayout}
                  categories={categories}
                  stockLabel={t('stock_label')}
                  priceLabel={t('price_label')}
                  onEdit={(p) => setEditingProduct(p)}
                  onDelete={(p) => deleteProduct(p.id)}
                />
              )}
            </>
            )
          ) : (
            <div className="space-y-8">
              <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
                <div>
                  <h2 className="text-xl font-black text-slate-800">{t('sales_history')}</h2>
                  <p className="text-[10px] font-bold opacity-30 uppercase tracking-widest">{t('admin_panel')}</p>
                </div>
                <div className="flex flex-wrap items-center gap-2 w-full sm:w-auto">
                  <select 
                    className="flex-1 sm:flex-none p-2 rounded-xl border border-slate-200 bg-slate-50 text-xs font-bold outline-none"
                    value={selectedSalesMarket}
                    onChange={(e) => setSelectedSalesMarket(e.target.value)}
                  >
                    <option value="all">{t('all_machines')}</option>
                    {markets.map(m => (
                      <option key={m.id} value={m.id.toString()}>{m.name || `${t('apparatus_no')}${m.id}`}</option>
                    ))}
                  </select>

                  <div className="flex-1 sm:flex-none bg-slate-100 p-1 rounded-xl flex gap-1">
                    {[
                      { id: 'recent', label: t('recent') },
                      { id: 'day', label: t('today') },
                      { id: 'week', label: t('this_week') },
                      { id: 'month', label: t('this_month') },
                      { id: 'period', label: t('period') }
                    ].map(f => (
                      <button
                        key={f.id}
                        onClick={() => setTimeFilter(f.id)}
                        className={`flex-1 sm:flex-none px-3 py-1.5 rounded-lg text-[10px] font-black uppercase tracking-wider transition-all ${timeFilter === f.id ? 'bg-white text-primary shadow-sm' : 'text-slate-400 hover:text-slate-600'}`}
                      >
                        {f.label}
                      </button>
                    ))}
                  </div>
                  {timeFilter === 'period' && (
                    <div className="flex items-center gap-1.5 w-full sm:w-auto">
                      <input
                        type="date"
                        value={periodFrom}
                        onChange={(e) => setPeriodFrom(e.target.value)}
                        className="flex-1 sm:flex-none p-2 rounded-xl border border-slate-200 bg-slate-50 text-xs font-bold outline-none"
                      />
                      <span className="text-slate-400 text-xs">—</span>
                      <input
                        type="date"
                        value={periodTo}
                        onChange={(e) => setPeriodTo(e.target.value)}
                        className="flex-1 sm:flex-none p-2 rounded-xl border border-slate-200 bg-slate-50 text-xs font-bold outline-none"
                      />
                    </div>
                  )}
                  <button onClick={fetchSales} className="p-2.5 bg-slate-100 text-slate-500 rounded-xl hover:bg-primary/5 hover:text-primary transition-all"><History size={18}/></button>
                </div>
              </div>

              {/* Статистика */}
              <div className="grid grid-cols-2 sm:grid-cols-3 gap-4">
                <div className="bg-white border border-slate-200 rounded-2xl p-4 shadow-sm">
                  <div className="text-[10px] font-black text-slate-500 uppercase tracking-widest mb-1">{t('revenue')}</div>
                  <div className="text-2xl font-black text-primary">{totalSalesAmount} <span className="text-sm">₸</span></div>
                </div>
                <div className="bg-white border border-slate-200 rounded-2xl p-4 shadow-sm">
                  <div className="text-[10px] font-black text-slate-500 uppercase tracking-widest mb-1">{t('orders')}</div>
                  <div className="text-2xl font-black text-slate-900">{filteredSales.length}</div>
                </div>
              </div>

              {loading ? (
                <div className="flex justify-center p-20"><Loader2 className="animate-spin text-primary" size={32} /></div>
              ) : (
                <div className="grid gap-4">
                  {filteredSales.map(sale => {
                    const items = sale.sales_items || [];
                    // `dispensed` defaults to TRUE in the DB, so an item is
                    // considered failed only when it's explicitly false.
                    // (The kiosk no longer writes null — autonomous machines
                    // collapse "unknown / timed-out" to failed → auto-refund,
                    // since there's nobody on-site to inspect the bin.)
                    const failedItems = items.filter(i => i.dispensed === false);
                    const refundTotal = failedItems.reduce(
                      (s, i) => s + ((i.price || 0) * (i.quantity || 1)),
                      0,
                    );
                    const inProgress = sale.status === 'in_progress';
                    return (
                    <div key={sale.id} className="bg-white border-2 border-slate-200 rounded-2xl p-4 md:p-6 hover:border-primary/40 hover:shadow-md transition-all">
                      <div
                        className="flex flex-wrap justify-between items-start gap-4 cursor-pointer select-none"
                        onClick={() => setExpandedSaleId(expandedSaleId === sale.id ? null : sale.id)}
                      >
                        <div className="flex items-center gap-4">
                          <div className="w-10 h-10 bg-primary/10 text-primary rounded-xl flex items-center justify-center">
                            <Receipt size={20} />
                          </div>
                          <div>
                            <div className="text-sm font-black text-slate-900">{sale.micromarkets?.name || `${t('apparatus_no')}${sale.micromarket_id}`}</div>
                            <div className="flex items-center gap-2 text-[10px] font-bold text-slate-500 uppercase tracking-tighter">
                              <Calendar size={10} />
                              {new Date(sale.created_at).toLocaleString('ru-RU')}
                              <span className="text-slate-400">· {items.length} {t('items_short')}</span>
                            </div>
                            {inProgress && (
                              <div className="mt-1 inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-amber-50 text-amber-700 text-[10px] font-black uppercase tracking-wider">
                                <AlertTriangle size={11} />
                                {t('sale_in_progress')}
                              </div>
                            )}
                          </div>
                        </div>
                        <div className="flex items-center gap-3 shrink-0">
                          <div className="text-right">
                            <div className="text-xl font-black text-primary">{sale.amount} ₸</div>
                            {failedItems.length > 0 && (
                              <div className="mt-1 inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-rose-50 text-rose-600 text-[10px] font-black uppercase tracking-wider">
                                <AlertTriangle size={11} />
                                {t('refund_due')}: {refundTotal} ₸
                              </div>
                            )}
                          </div>
                          <ChevronDown
                            size={18}
                            className={`text-slate-400 transition-transform ${expandedSaleId === sale.id ? 'rotate-180' : ''}`}
                          />
                        </div>
                      </div>

                      {expandedSaleId === sale.id && (
                      <div className="space-y-3 mt-6 pt-4 border-t border-slate-100">
                        {items.map(item => {
                          const failed = item.dispensed === false;
                          return (
                          <div
                            key={item.id}
                            className={`flex justify-between items-start text-xs pb-2 border-b last:border-0 last:pb-0 ${failed ? 'border-rose-100' : 'border-slate-50'}`}
                          >
                            <div className="flex items-start gap-2 min-w-0 flex-1">
                              <span className="shrink-0 w-5 h-5 bg-slate-50 rounded flex items-center justify-center font-black text-[9px] text-slate-400">{item.quantity}</span>
                              {failed ? (
                                <XCircle size={14} className="shrink-0 mt-px text-rose-500" />
                              ) : (
                                <CheckCircle2 size={14} className="shrink-0 mt-px text-emerald-500" />
                              )}
                              <div className="min-w-0 flex-1">
                                <div className="font-bold text-slate-600 truncate">{item.inventory?.name || t('deleted_product')}</div>
                                {failed && (
                                  <div className="text-[10px] font-bold text-rose-500 mt-0.5 truncate">
                                    {resultLabel(t, item)}
                                  </div>
                                )}
                              </div>
                            </div>
                            <span className={`font-black ml-4 ${failed ? 'text-rose-500 line-through opacity-70' : 'text-slate-800'}`}>{item.price * item.quantity} ₸</span>
                          </div>
                          );
                        })}
                      </div>
                      )}
                    </div>
                    );
                  })}
                  {sales.length === 0 && (
                    <div className="text-center py-20 bg-slate-50 rounded-3xl border-2 border-dashed border-slate-200">
                      <ShoppingBag size={40} className="mx-auto mb-4 text-slate-300" />
                      <p className="font-black text-slate-400 text-sm uppercase tracking-widest">{t('no_data_period')}</p>
                    </div>
                  )}
                </div>
              )}
            </div>
          )}
        </div>

      {/* Модалка редактирования — full-screen на мобильном, центр на десктопе. */}
      {editingProduct && (
        <div className="fixed inset-0 z-50 bg-slate-900/60 backdrop-blur-sm sm:flex sm:items-center sm:justify-center sm:p-4">
          <div className="bg-white w-full h-full sm:h-auto sm:max-w-md sm:rounded-3xl sm:shadow-2xl sm:border-2 sm:border-slate-300 flex flex-col">
            <div className="flex justify-between items-center px-5 py-4 sm:px-6 sm:py-5 border-b-2 border-slate-200 sm:border-b-0">
              <h3 className="font-black text-lg sm:text-xl text-slate-900">{editingProduct.id === 'new' ? t('new_product') : t('edit_product_title')}</h3>
              <button onClick={() => setEditingProduct(null)} className="p-2.5 bg-slate-200 border border-slate-300 text-slate-700 rounded-full hover:bg-slate-300 active:scale-95"><X size={20} /></button>
            </div>

            <div className="space-y-4 flex-1 overflow-y-auto px-5 sm:px-6 py-5">
              {/* Catalog link card — name/photo/category come from the
                  linked products row, not typed freehand. New items
                  must pick a SKU before save. */}
              {editingProduct.product_id ? (
                <div className="flex gap-3 items-center bg-emerald-50 border-2 border-emerald-400 rounded-2xl p-3">
                  <div className="w-16 h-16 bg-white rounded-xl flex items-center justify-center overflow-hidden shrink-0 border-2 border-emerald-300">
                    {editingProduct.image_url ? (
                      <img src={editingProduct.image_url} className="w-full h-full object-contain" alt={editingProduct.name} />
                    ) : editingProduct.emoji ? (
                      <span className="text-3xl">{editingProduct.emoji}</span>
                    ) : (
                      <Image className="text-slate-400" size={20} />
                    )}
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-1.5">
                      <CheckCircle2 size={12} className="text-emerald-700" />
                      <span className="text-[9px] uppercase font-black tracking-widest text-emerald-800">{t('from_catalog')}</span>
                    </div>
                    <h4 className="font-black text-sm truncate text-slate-900">{editingProduct.name}</h4>
                    <span className="text-[10px] font-bold text-slate-600">
                      {categories.find(c => c.id === editingProduct.category_id)?.name_ru || t('no_category')}
                    </span>
                  </div>
                  <button
                    onClick={openCatalogPicker}
                    title={t('change_product')}
                    className="p-2 bg-white border border-emerald-300 text-emerald-700 rounded-lg hover:bg-emerald-600 hover:text-white hover:border-emerald-600 transition-all"
                  >
                    <Pencil size={14} />
                  </button>
                </div>
              ) : (
                <button
                  onClick={openCatalogPicker}
                  className="w-full flex items-center justify-between gap-3 bg-indigo-50 border-2 border-indigo-300 hover:bg-indigo-100 hover:border-indigo-500 transition-all rounded-2xl p-3 text-left"
                >
                  <div className="flex items-center gap-3">
                    <div className="w-12 h-12 bg-white rounded-xl flex items-center justify-center border-2 border-indigo-300">
                      <ShoppingBag size={20} className="text-indigo-600" />
                    </div>
                    <div>
                      <div className="font-black text-sm text-indigo-900">{t('pick_from_catalog')}</div>
                      <div className="text-[11px] text-indigo-600 font-medium">{t('pick_from_catalog_hint')}</div>
                    </div>
                  </div>
                  <Plus size={16} className="text-indigo-600" />
                </button>
              )}

              {/* Slot info — read-only. Motor wiring (id + type) is
                  edited on the tablet's «Настройка моторов» screen so
                  the operator standing in front of the cabinet can
                  verify the change physically. Admin can't change it
                  remotely (a wrong motor index = wrong product
                  dispensed). */}
              {editingProduct.motor_id != null && editingProduct.motor_id !== '' && (
                <div className="flex items-center gap-3 bg-slate-100 border-2 border-slate-300 rounded-2xl p-3">
                  <div className="bg-indigo-600 text-white px-3 py-1.5 rounded-lg font-black text-base tabular-nums shadow-sm shrink-0">
                    {motorToSlotLabel(editingProduct.motor_id) ?? '?'}
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="text-[10px] font-black uppercase tracking-widest text-slate-600">{t('slot_in_machine')}</div>
                    <div className="text-xs text-slate-700 leading-snug">
                      {t('motor_link_tablet_only')}
                    </div>
                  </div>
                </div>
              )}

              <div className="flex gap-4">
                <div className="flex-1">
                  <label className="text-xs font-bold text-slate-700 ml-2 mb-1 block">{t('price_kzt')}</label>
                  <input
                    type="number"
                    className="w-full p-2.5 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-bold text-slate-900 bg-white"
                    value={editingProduct.price === 0 ? '' : editingProduct.price}
                    onChange={e => setEditingProduct({...editingProduct, price: e.target.value === '' ? 0 : Number(e.target.value)})}
                  />
                </div>
                <div className="flex-1">
                  <label className="text-xs font-bold text-slate-700 ml-2 mb-1 block">{t('stock_pcs')}</label>
                  <input
                    type="number"
                    className="w-full p-2.5 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-bold text-slate-900 bg-white"
                    value={editingProduct.stock === 0 ? '' : editingProduct.stock}
                    onChange={e => setEditingProduct({...editingProduct, stock: e.target.value === '' ? 0 : Number(e.target.value)})}
                  />
                </div>
              </div>

              <div className="text-[11px] text-slate-600 leading-relaxed bg-slate-100 border border-slate-300 rounded-xl p-2.5">
                {t('edit_photo_in_catalog')}
              </div>

            </div>
            {/* Sticky footer — Save stays in reach on mobile no matter
                how much you scroll the form. */}
            <div className="px-5 sm:px-6 py-3 sm:py-4 border-t-2 border-slate-200 bg-white sm:rounded-b-3xl">
              <button
                onClick={saveProduct}
                disabled={loading || uploadingImage || !editingProduct.product_id}
                className="w-full bg-primary text-white py-3.5 rounded-xl font-black text-base sm:text-lg flex justify-center items-center gap-2 shadow-lg shadow-primary/30 active:scale-95 transition-all disabled:opacity-50 disabled:cursor-not-allowed border-2 border-primary"
              >
                {loading ? <Loader2 className="animate-spin" /> : <Save size={20} />}
                {t('save')}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Управление Категориями */}
      {showCategoryManager && (
        <div className="fixed inset-0 z-[60] bg-black/50 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-3xl p-6 w-full max-w-sm shadow-2xl">
            <div className="flex justify-between items-center mb-6">
              <h3 className="font-black text-xl">{t('categories')}</h3>
              <button onClick={() => setShowCategoryManager(false)} className="p-2 bg-surface-container-low rounded-full"><X size={18} /></button>
            </div>
            
            <div className="flex flex-col gap-2 mb-4">
              <input 
                placeholder={t('name_ru')}
                className="p-2 border border-surface-container-high rounded-xl font-bold text-sm"
                value={newCatRu}
                onChange={e => setNewCatRu(e.target.value)}
              />
              <input 
                placeholder={t('name_kz')}
                className="p-2 border border-surface-container-high rounded-xl font-bold text-sm"
                value={newCatKz}
                onChange={e => setNewCatKz(e.target.value)}
              />
              <input 
                placeholder={t('name_en')}
                className="p-2 border border-surface-container-high rounded-xl font-bold text-sm"
                value={newCatEn}
                onChange={e => setNewCatEn(e.target.value)}
              />
              <button onClick={addCategory} className="bg-primary text-white p-2 rounded-xl mt-2 font-bold"><Plus size={20} className="inline mr-2"/> {t('add')}</button>
            </div>

            <div className="max-h-60 overflow-y-auto flex flex-col gap-2">
              {categories.map(c => (
                <div key={c.id} className="flex justify-between items-center bg-surface-container-lowest border border-surface-container-high p-3 rounded-xl">
                  <div className="flex flex-col">
                    <span className="font-bold text-sm">{c.name_ru}</span>
                    <span className="text-[10px] opacity-50">{c.name_kz} / {c.name_en}</span>
                  </div>
                  <button onClick={() => deleteCategory(c.id)} className="text-red-500 hover:bg-red-50 p-2 rounded-lg transition-colors"><Trash2 size={16}/></button>
                </div>
              ))}
              {categories.length === 0 && <p className="text-center text-xs opacity-50 py-4">{t('no_categories')}</p>}
            </div>
          </div>
        </div>
      )}

      {/* Модалка для ручной обрезки фото */}
      {cropImageSrc && (
        <div className="fixed inset-0 z-[100] bg-black flex flex-col">
          <div className="flex-1 relative">
            <Cropper
              image={cropImageSrc}
              crop={crop}
              zoom={zoom}
              aspect={1}
              onCropChange={setCrop}
              onZoomChange={setZoom}
              onCropComplete={(croppedArea, croppedAreaPixels) => setCroppedAreaPixels(croppedAreaPixels)}
            />
          </div>
          <div className="p-6 bg-white flex justify-end gap-4 items-center">
            <button
              onClick={() => { setCropImageSrc(null); setCropTarget('inventory'); }}
              className="px-6 py-3 font-bold text-on-surface-variant hover:text-black transition-colors"
            >
              {t('cancel')}
            </button>
            <button 
              onClick={handleUploadCrop}
              disabled={uploadingImage}
              className="bg-primary text-white px-8 py-3 rounded-xl font-black shadow-lg shadow-primary/20 flex items-center gap-2 active:scale-95 transition-all"
            >
              {uploadingImage ? <Loader2 className="animate-spin" /> : t('save_and_upload')}
            </button>
          </div>
        </div>
      )}

      {qrModalMarket && (
        <QrModal market={qrModalMarket} onClose={() => setQrModalMarket(null)} />
      )}

      <Toast toast={toast} onClose={() => setToast(null)} />

      {/* Catalog picker — overlays on top of the inventory edit modal,
          so it's z-[60] (modal is z-50). Filters the SKU list by the
          search box and pops back to the inventory form on selection. */}
      {showCatalogPicker && (
        <div className="fixed inset-0 z-[60] bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-3xl w-full max-w-lg shadow-2xl border-2 border-slate-300 max-h-[85vh] flex flex-col">
            <div className="flex justify-between items-center px-6 pt-6 pb-4 border-b-2 border-slate-200">
              <div>
                <h3 className="font-black text-xl text-slate-900">{t('tab_catalog')}</h3>
                <span className="text-[10px] font-bold text-slate-500 uppercase tracking-widest">
                  {t('pick_ready_product')}
                </span>
              </div>
              <button
                onClick={() => setShowCatalogPicker(false)}
                className="p-2 bg-slate-200 border border-slate-300 text-slate-700 rounded-full hover:bg-slate-300"
              >
                <X size={18} />
              </button>
            </div>

            <div className="px-6 py-4 bg-slate-50 border-b border-slate-200">
              <input
                placeholder={t('search_placeholder_short')}
                value={pickerSearch}
                onChange={e => setPickerSearch(e.target.value)}
                className="w-full p-2.5 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-medium text-sm bg-white text-slate-900 placeholder-slate-400"
                autoFocus
              />
            </div>

            <div className="flex-1 overflow-y-auto p-4">
              {pickerProducts == null ? (
                <div className="flex justify-center p-10">
                  <Loader2 className="animate-spin text-primary" size={28} />
                </div>
              ) : pickerProducts.length === 0 ? (
                <div className="text-center py-10 bg-slate-50 border-2 border-dashed border-slate-300 rounded-2xl">
                  <Image className="mx-auto mb-3 text-slate-300" size={40} />
                  <p className="text-xs font-bold text-slate-500 uppercase tracking-widest">
                    {t('catalog_empty')}
                  </p>
                  <p className="text-[11px] text-slate-600 mt-1">
                    {t('catalog_empty_hint')}
                  </p>
                </div>
              ) : (
                <div className="space-y-2">
                  {pickerProducts
                    .filter(p =>
                      pickerSearch.trim() === '' ||
                      p.name.toLowerCase().includes(pickerSearch.trim().toLowerCase())
                    )
                    .map(p => (
                      <button
                        key={p.id}
                        onClick={() => applyCatalogToInventory(p)}
                        className="w-full flex items-center gap-3 p-3 rounded-xl bg-slate-50 border-2 border-slate-200 hover:border-primary hover:bg-white hover:shadow-md transition-all text-left"
                      >
                        <div className="w-12 h-12 bg-white rounded-xl flex items-center justify-center overflow-hidden shrink-0 border-2 border-slate-200">
                          {p.image_url ? (
                            <img src={p.image_url} alt={p.name} loading="lazy" className="w-full h-full object-contain p-1" />
                          ) : p.emoji ? (
                            <span className="text-2xl">{p.emoji}</span>
                          ) : (
                            <Image className="text-slate-300" size={18} />
                          )}
                        </div>
                        <div className="flex-1 min-w-0">
                          <div className="font-bold text-sm truncate text-slate-900">{p.name}</div>
                          <div className="flex items-center gap-2 mt-1">
                            <span className="text-[9px] uppercase font-black text-slate-600 tracking-wider px-1.5 py-0.5 bg-white border border-slate-300 rounded">
                              {categories.find(c => c.id === p.category_id)?.name_ru || t('no_category')}
                            </span>
                            {p.volume_ml != null && (
                              <span className="text-[10px] font-bold text-slate-700 bg-white border border-slate-300 px-1.5 py-0.5 rounded">
                                {p.volume_ml} {t('unit_ml')}
                              </span>
                            )}
                          </div>
                        </div>
                        <Plus size={14} className="text-slate-500" />
                      </button>
                    ))}
                </div>
              )}
            </div>
          </div>
        </div>
      )}

      {/* Catalog edit modal — separate form from inventory edit since
          catalog rows have different fields (volume_ml, description,
          is_draft, is_archived) and no per-slot price/stock. */}
      {editingCatalog && (
        <div className="fixed inset-0 z-50 bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-3xl p-6 w-full max-w-md shadow-2xl border-2 border-slate-300 max-h-[90vh] overflow-y-auto">
            <div className="flex justify-between items-center mb-6">
              <h3 className="font-black text-xl text-slate-900">
                {editingCatalog.id === 'new' ? t('new_catalog_product') : t('edit_product_title')}
              </h3>
              <button onClick={() => setEditingCatalog(null)} className="p-2 bg-slate-200 border border-slate-300 text-slate-700 rounded-full hover:bg-slate-300">
                <X size={18} />
              </button>
            </div>

            <div className="space-y-4">
              <div className="flex gap-4 items-start">
                <div
                  onClick={() => catalogFileInputRef.current?.click()}
                  className="w-24 h-24 bg-indigo-50 rounded-2xl flex flex-col items-center justify-center cursor-pointer border-2 border-dashed border-indigo-400 hover:bg-indigo-100 hover:border-indigo-600 transition-all overflow-hidden relative shrink-0"
                >
                  {uploadingImage ? (
                    <Loader2 className="animate-spin text-primary" />
                  ) : editingCatalog.image_url ? (
                    <img src={editingCatalog.image_url} className="w-full h-full object-contain" alt="Preview" />
                  ) : (
                    <>
                      <Upload className="text-primary mb-1" size={20} />
                      <span className="text-[10px] font-bold text-primary">{t('photo')}</span>
                    </>
                  )}
                  <input
                    type="file"
                    className="hidden"
                    accept="image/*"
                    ref={catalogFileInputRef}
                    onChange={onCatalogFileChange}
                  />
                </div>
                <div className="flex-1 space-y-2 flex flex-col">
                  <input
                    placeholder={t('name_coca_example')}
                    className="w-full p-2.5 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-bold text-slate-900 bg-white placeholder-slate-400"
                    value={editingCatalog.name || ''}
                    onChange={e => setEditingCatalog({ ...editingCatalog, name: e.target.value })}
                  />
                  <select
                    className="w-full p-2.5 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl text-sm font-bold bg-white text-slate-900"
                    value={editingCatalog.category_id || ''}
                    onChange={e => setEditingCatalog({ ...editingCatalog, category_id: e.target.value || null })}
                  >
                    <option value="">{t('no_category')}</option>
                    {categories.map(c => (
                      <option key={c.id} value={c.id}>{c.name_ru}</option>
                    ))}
                  </select>
                </div>
              </div>

              <div className="flex gap-3">
                <div className="flex-1">
                  <label className="text-xs font-bold text-slate-700 ml-2 mb-1 block">{t('volume_ml')}</label>
                  <input
                    type="number"
                    placeholder="500"
                    className="w-full p-2.5 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-bold text-slate-900 bg-white placeholder-slate-400"
                    value={editingCatalog.volume_ml ?? ''}
                    onChange={e => setEditingCatalog({ ...editingCatalog, volume_ml: e.target.value })}
                  />
                </div>
                <div className="flex-1">
                  <label className="text-xs font-bold text-slate-700 ml-2 mb-1 block">{t('emoji_fallback')}</label>
                  <input
                    placeholder="🥤"
                    maxLength={4}
                    className="w-full p-2.5 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-bold text-slate-900 bg-white"
                    value={editingCatalog.emoji || ''}
                    onChange={e => setEditingCatalog({ ...editingCatalog, emoji: e.target.value })}
                  />
                </div>
              </div>

              <div>
                <label className="text-xs font-bold text-slate-700 ml-2 mb-1 block">{t('description_optional')}</label>
                <textarea
                  rows={2}
                  className="w-full p-2.5 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl text-sm text-slate-900 bg-white"
                  value={editingCatalog.description || ''}
                  onChange={e => setEditingCatalog({ ...editingCatalog, description: e.target.value })}
                />
              </div>

              {editingCatalog.is_draft && editingCatalog.id !== 'new' && (
                <div className="flex items-center gap-2 bg-amber-100 border-2 border-amber-400 rounded-xl px-3 py-2.5">
                  <AlertTriangle size={16} className="text-amber-700" />
                  <span className="text-xs font-bold text-amber-900">
                    {t('draft_from_tablet')}
                  </span>
                </div>
              )}

              <div className="pt-4 border-t-2 border-slate-200 flex flex-col gap-2">
                <button
                  onClick={saveCatalogProduct}
                  disabled={loading || uploadingImage}
                  className="w-full bg-primary text-white py-3 rounded-xl font-black text-lg flex justify-center items-center gap-2 shadow-xl shadow-primary/30 active:scale-95 transition-all disabled:opacity-50 border-2 border-primary"
                >
                  {loading ? <Loader2 className="animate-spin" /> : <Save size={20} />}
                  {t('save')}
                </button>
                {editingCatalog.is_draft && editingCatalog.id !== 'new' && (
                  <button
                    onClick={() => { publishDraft(editingCatalog); setEditingCatalog(null); }}
                    className="w-full bg-emerald-600 text-white py-2.5 rounded-xl font-bold text-sm flex justify-center items-center gap-2 hover:bg-emerald-700 transition-all border-2 border-emerald-600"
                  >
                    <CheckCircle2 size={16} /> {t('publish')}
                  </button>
                )}
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Модалка подтверждения удаления */}
      {productToDelete && (
        <div className="fixed inset-0 z-[110] bg-black/50 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-3xl p-8 w-full max-w-sm shadow-2xl text-center">
            <div className="w-16 h-16 bg-red-100 text-red-600 rounded-full flex items-center justify-center mx-auto mb-4">
              <Trash2 size={32} />
            </div>
            <h3 className="text-xl font-black mb-2 text-on-surface">{t('delete_product_title')}</h3>
            <p className="text-sm text-on-surface-variant opacity-70 mb-6">{t('delete_product_confirm')}</p>
            <div className="flex gap-3">
              <button 
                onClick={() => setProductToDelete(null)}
                className="flex-1 py-3 px-4 bg-surface-container-high rounded-xl font-bold text-on-surface hover:bg-surface-container-highest transition-all"
              >
                {t('cancel')}
              </button>
              <button
                onClick={confirmDelete}
                className="flex-1 py-3 px-4 bg-red-600 text-white rounded-xl font-bold hover:bg-red-700 shadow-lg shadow-red-200 transition-all active:scale-95"
              >
                {t('yes_delete')}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Add device — Internal ID + Secret are copied off the machine's page in
          the SmartVend partner cabinet; device-claim checks the pair against
          the SmartVend list before it writes anything. */}
      {addingDevice && (
        <div className="fixed inset-0 z-[110] bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-3xl w-full max-w-md shadow-2xl border-2 border-slate-300 max-h-[90vh] overflow-y-auto">
            <div className="flex justify-between items-center px-6 pt-6 pb-4 border-b-2 border-slate-200">
              <div>
                <h3 className="font-black text-xl text-slate-900">{t('add_device')}</h3>
                <span className="text-[10px] font-bold text-slate-500 uppercase tracking-widest">{t('add_device_hint')}</span>
              </div>
              <button
                onClick={() => setAddingDevice(null)}
                className="p-2 bg-slate-200 border border-slate-300 text-slate-700 rounded-full hover:bg-slate-300"
              >
                <X size={18} />
              </button>
            </div>

            <div className="p-6 space-y-4">
              <div>
                <label className="text-xs font-bold text-slate-500 ml-1">{t('device_internal_id')}</label>
                <input
                  value={addingDevice.machid}
                  onChange={e => setAddingDevice({ ...addingDevice, machid: e.target.value.replace(/\D/g, '') })}
                  inputMode="numeric"
                  autoFocus
                  placeholder="3001000"
                  className="w-full mt-1 p-3 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-bold bg-white text-slate-900 placeholder-slate-300"
                />
              </div>
              <div>
                <label className="text-xs font-bold text-slate-500 ml-1">{t('device_secret')}</label>
                <input
                  value={addingDevice.secret}
                  onChange={e => setAddingDevice({ ...addingDevice, secret: e.target.value })}
                  autoComplete="off"
                  spellCheck={false}
                  className="w-full mt-1 p-3 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-mono text-sm bg-white text-slate-900"
                />
                <p className="text-[11px] text-slate-400 mt-1 ml-1">{t('device_secret_hint')}</p>
              </div>
              <div>
                <label className="text-xs font-bold text-slate-500 ml-1">{t('device_name')}</label>
                <input
                  value={addingDevice.name}
                  onChange={e => setAddingDevice({ ...addingDevice, name: e.target.value })}
                  placeholder={t('device_name_placeholder')}
                  className="w-full mt-1 p-3 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-bold bg-white text-slate-900 placeholder-slate-300"
                />
              </div>
              <div>
                <label className="text-xs font-bold text-slate-500 ml-1">{t('device_kind')}</label>
                <div className="grid grid-cols-2 gap-2 mt-1">
                  {[
                    { value: 'vending', label: t('badge_vending'), hint: t('device_kind_vending_hint') },
                    { value: 'micromarket_static', label: t('badge_micromarket'), hint: t('device_kind_static_hint') },
                  ].map(opt => (
                    <button
                      key={opt.value}
                      onClick={() => setAddingDevice({ ...addingDevice, kind: opt.value })}
                      className={`p-3 rounded-xl border-2 text-left transition-all ${addingDevice.kind === opt.value ? 'border-primary bg-primary/5' : 'border-slate-200 hover:border-slate-300'}`}
                    >
                      <div className="font-black text-sm text-slate-900">{opt.label}</div>
                      <div className="text-[10px] font-bold text-slate-500 leading-tight mt-0.5">{opt.hint}</div>
                    </button>
                  ))}
                </div>
              </div>
            </div>

            <div className="flex gap-3 px-6 pb-6">
              <button
                onClick={() => setAddingDevice(null)}
                className="flex-1 py-3 px-4 bg-slate-200 rounded-xl font-bold text-slate-700 hover:bg-slate-300 transition-all"
              >
                {t('cancel')}
              </button>
              <button
                onClick={claimDevice}
                disabled={deviceSaving}
                className="flex-1 py-3 px-4 bg-primary text-white rounded-xl font-black shadow-lg shadow-primary/20 flex items-center justify-center gap-2 active:scale-95 transition-all disabled:opacity-60"
              >
                {deviceSaving ? <Loader2 className="animate-spin" size={18} /> : t('add')}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Unbind the tablet. Explicit confirmation because the machine keeps
          working until its next heartbeat, and the operator standing at it
          will see the app drop to the pairing screen without warning. */}
      {releaseTarget && (
        <div className="fixed inset-0 z-[110] bg-black/50 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-3xl p-8 w-full max-w-sm shadow-2xl text-center">
            <div className="w-16 h-16 bg-amber-100 text-amber-600 rounded-full flex items-center justify-center mx-auto mb-4">
              <LinkOff size={30} />
            </div>
            <h3 className="text-xl font-black mb-2 text-slate-900">{t('release_tablet_title')}</h3>
            <p className="text-sm text-slate-600 mb-2">
              {releaseTarget.name || `${t('apparatus_no')}${releaseTarget.id}`}
            </p>
            <p className="text-xs text-slate-500 mb-6">{t('release_tablet_hint')}</p>
            <div className="flex gap-3">
              <button
                onClick={() => setReleaseTarget(null)}
                className="flex-1 py-3 px-4 bg-slate-200 rounded-xl font-bold text-slate-700 hover:bg-slate-300 transition-all"
              >
                {t('cancel')}
              </button>
              <button
                onClick={() => releaseTablet(releaseTarget)}
                className="flex-1 py-3 px-4 bg-amber-500 text-white rounded-xl font-bold hover:bg-amber-600 shadow-lg shadow-amber-200 transition-all active:scale-95"
              >
                {t('release_tablet')}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Rename a machine. Owner path is a plain RLS-scoped UPDATE; the
          superadmin's fleet list sets viaAdmin and goes through device-admin. */}
      {renamingMarket && (
        <div className="fixed inset-0 z-[110] bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-3xl w-full max-w-sm shadow-2xl border-2 border-slate-300">
            <div className="flex justify-between items-center px-6 pt-6 pb-4 border-b-2 border-slate-200">
              <div>
                <h3 className="font-black text-xl text-slate-900">{t('rename')}</h3>
                <span className="text-[10px] font-bold text-slate-500 uppercase tracking-widest">
                  {t('apparatus_no')}{renamingMarket.id}
                </span>
              </div>
              <button
                onClick={() => setRenamingMarket(null)}
                className="p-2 bg-slate-200 border border-slate-300 text-slate-700 rounded-full hover:bg-slate-300"
              >
                <X size={18} />
              </button>
            </div>
            <div className="p-6">
              <label className="text-xs font-bold text-slate-500 ml-1">{t('device_name')}</label>
              <input
                value={renamingMarket.name}
                onChange={e => setRenamingMarket({ ...renamingMarket, name: e.target.value })}
                onKeyDown={e => { if (e.key === 'Enter') renameMarket(); }}
                autoFocus
                className="w-full mt-1 p-3 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-bold bg-white text-slate-900"
              />
            </div>
            <div className="flex gap-3 px-6 pb-6">
              <button
                onClick={() => setRenamingMarket(null)}
                className="flex-1 py-3 px-4 bg-slate-200 rounded-xl font-bold text-slate-700 hover:bg-slate-300 transition-all"
              >
                {t('cancel')}
              </button>
              <button
                onClick={renameMarket}
                className="flex-1 py-3 px-4 bg-primary text-white rounded-xl font-black shadow-lg shadow-primary/20 active:scale-95 transition-all"
              >
                {t('save')}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Transfer a machine to another account — superadmin only. */}
      {transferTarget && (
        <div className="fixed inset-0 z-[110] bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-3xl w-full max-w-md shadow-2xl border-2 border-slate-300 max-h-[85vh] flex flex-col">
            <div className="flex justify-between items-center px-6 pt-6 pb-4 border-b-2 border-slate-200">
              <div>
                <h3 className="font-black text-xl text-slate-900">{t('transfer_device')}</h3>
                <span className="text-[10px] font-bold text-slate-500 uppercase tracking-widest">
                  {transferTarget.name || `${t('apparatus_no')}${transferTarget.id}`}
                </span>
              </div>
              <button
                onClick={() => setTransferTarget(null)}
                className="p-2 bg-slate-200 border border-slate-300 text-slate-700 rounded-full hover:bg-slate-300"
              >
                <X size={18} />
              </button>
            </div>
            <div className="px-6 py-4 text-[11px] font-bold text-slate-500">{t('transfer_pick_owner')}</div>
            <div className="flex-1 overflow-y-auto px-6 pb-6 space-y-2">
              {adminOwners.map(o => (
                <button
                  key={o.id}
                  onClick={() => setTransferConfirm({
                    market: transferTarget,
                    from: adminOwners.find(x => x.id === transferTarget.owner_id) || null,
                    to: o,
                  })}
                  disabled={o.id === transferTarget.owner_id}
                  className={`w-full p-3 rounded-xl border-2 text-left transition-all ${o.id === transferTarget.owner_id ? 'border-primary bg-primary/5 cursor-default' : 'border-slate-200 hover:border-primary hover:bg-slate-50'}`}
                >
                  <div className="font-bold text-sm text-slate-900 truncate">{o.email}</div>
                  {o.id === transferTarget.owner_id && (
                    <div className="text-[10px] font-black uppercase tracking-wider text-primary mt-0.5">
                      {t('current_owner')}
                    </div>
                  )}
                </button>
              ))}
            </div>
          </div>
        </div>
      )}

      {/* Set a new password. No reset mail: the project has no SMTP, and the
          account was handed over with a password in the first place. */}
      {pwdTarget && (
        <div className="fixed inset-0 z-[110] bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-3xl w-full max-w-sm shadow-2xl border-2 border-slate-300">
            <div className="flex justify-between items-center px-6 pt-6 pb-4 border-b-2 border-slate-200">
              <div className="min-w-0">
                <h3 className="font-black text-xl text-slate-900">{t('change_password')}</h3>
                <span className="text-[10px] font-bold text-slate-500 uppercase tracking-widest truncate block">
                  {pwdTarget.email}
                </span>
              </div>
              <button
                onClick={() => setPwdTarget(null)}
                className="p-2 bg-slate-200 border border-slate-300 text-slate-700 rounded-full hover:bg-slate-300 shrink-0"
              >
                <X size={18} />
              </button>
            </div>
            <div className="p-6">
              <label className="text-xs font-bold text-slate-500 ml-1">{t('change_password_for')} {pwdTarget.email}</label>
              <input
                type="text"
                value={pwdTarget.password}
                onChange={e => setPwdTarget({ ...pwdTarget, password: e.target.value })}
                onKeyDown={e => { if (e.key === 'Enter') changePassword(); }}
                autoFocus
                autoComplete="new-password"
                className="w-full mt-1 p-3 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-mono text-sm bg-white text-slate-900"
              />
              <p className="text-[11px] text-slate-400 mt-1 ml-1">{t('user_password_hint')}</p>
            </div>
            <div className="flex gap-3 px-6 pb-6">
              <button
                onClick={() => setPwdTarget(null)}
                className="flex-1 py-3 px-4 bg-slate-200 rounded-xl font-bold text-slate-700 hover:bg-slate-300 transition-all"
              >
                {t('cancel')}
              </button>
              <button
                onClick={changePassword}
                disabled={userSaving}
                className="flex-1 py-3 px-4 bg-primary text-white rounded-xl font-black shadow-lg shadow-primary/20 flex items-center justify-center gap-2 active:scale-95 transition-all disabled:opacity-60"
              >
                {userSaving ? <Loader2 className="animate-spin" size={18} /> : t('save')}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Delete an account. The function refuses while it still owns machines. */}
      {userDeleteTarget && (
        <div className="fixed inset-0 z-[110] bg-black/50 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-3xl p-8 w-full max-w-sm shadow-2xl text-center">
            <div className="w-16 h-16 bg-red-100 text-red-600 rounded-full flex items-center justify-center mx-auto mb-4">
              <AlertTriangle size={32} />
            </div>
            <h3 className="text-xl font-black mb-2 text-slate-900">{t('delete_user_title')}</h3>
            <p className="text-sm text-slate-600 mb-2 break-all">{userDeleteTarget.email}</p>
            <p className="text-xs text-slate-500 mb-6">{t('delete_user_hint')}</p>
            <div className="flex gap-3">
              <button
                onClick={() => setUserDeleteTarget(null)}
                disabled={userSaving}
                className="flex-1 py-3 px-4 bg-slate-200 rounded-xl font-bold text-slate-700 hover:bg-slate-300 transition-all disabled:opacity-60"
              >
                {t('cancel')}
              </button>
              <button
                onClick={deleteUser}
                disabled={userSaving}
                className="flex-1 py-3 px-4 bg-red-600 text-white rounded-xl font-bold hover:bg-red-700 shadow-lg shadow-red-200 transition-all active:scale-95 flex items-center justify-center disabled:opacity-60"
              >
                {userSaving ? <Loader2 className="animate-spin" size={18} /> : t('yes_delete')}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Transfer confirmation — spells out both accounts, because after this
          the previous owner loses the machine from their admin panel. */}
      {transferConfirm && (
        <div className="fixed inset-0 z-[120] bg-black/50 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-3xl p-7 w-full max-w-sm shadow-2xl">
            <h3 className="text-xl font-black mb-1 text-slate-900 text-center">{t('transfer_confirm_title')}</h3>
            <p className="text-xs font-bold text-slate-500 uppercase tracking-widest text-center mb-5">
              {transferConfirm.market.name || `${t('apparatus_no')}${transferConfirm.market.id}`}
              {' · '}{t('apparatus_no')}{transferConfirm.market.id}
            </p>

            <div className="space-y-2 mb-5">
              <div className="p-3 rounded-xl bg-slate-100 border border-slate-200">
                <div className="text-[10px] font-black uppercase tracking-wider text-slate-500">{t('transfer_from')}</div>
                <div className="font-bold text-sm text-slate-900 truncate">
                  {transferConfirm.from?.email || t('no_owner')}
                </div>
              </div>
              <div className="flex justify-center text-slate-400"><ChevronDown size={18} /></div>
              <div className="p-3 rounded-xl bg-primary/5 border-2 border-primary">
                <div className="text-[10px] font-black uppercase tracking-wider text-primary">{t('transfer_to')}</div>
                <div className="font-bold text-sm text-slate-900 truncate">{transferConfirm.to.email}</div>
              </div>
            </div>

            <p className="text-[11px] text-slate-500 text-center mb-5">{t('transfer_confirm_hint')}</p>

            <div className="flex gap-3">
              <button
                onClick={() => setTransferConfirm(null)}
                disabled={transferring}
                className="flex-1 py-3 px-4 bg-slate-200 rounded-xl font-bold text-slate-700 hover:bg-slate-300 transition-all disabled:opacity-60"
              >
                {t('cancel')}
              </button>
              <button
                onClick={transferDevice}
                disabled={transferring}
                className="flex-1 py-3 px-4 bg-primary text-white rounded-xl font-black shadow-lg shadow-primary/20 flex items-center justify-center gap-2 active:scale-95 transition-all disabled:opacity-60"
              >
                {transferring ? <Loader2 className="animate-spin" size={18} /> : t('confirm_btn')}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Delete confirmation. The counts come back from device-admin's first
          (unconfirmed) call — sales cascade, so say so out loud. */}
      {deleteTarget && (
        <div className="fixed inset-0 z-[110] bg-black/50 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-3xl p-8 w-full max-w-sm shadow-2xl text-center">
            <div className="w-16 h-16 bg-red-100 text-red-600 rounded-full flex items-center justify-center mx-auto mb-4">
              <AlertTriangle size={32} />
            </div>
            <h3 className="text-xl font-black mb-2 text-slate-900">{t('delete_device_title')}</h3>
            <p className="text-sm text-slate-600 mb-2">
              {deleteTarget.name || `${t('apparatus_no')}${deleteTarget.machid}`}
            </p>
            {(deleteTarget.sales > 0 || deleteTarget.inventory > 0) && (
              <p className="text-xs font-bold text-red-600 bg-red-50 border border-red-200 rounded-xl p-3 mb-4">
                {t('delete_device_cascade', {
                  sales: deleteTarget.sales ?? 0,
                  inventory: deleteTarget.inventory ?? 0,
                })}
              </p>
            )}
            <p className="text-xs text-slate-500 mb-6">{t('delete_device_irreversible')}</p>
            <div className="flex gap-3">
              <button
                onClick={() => setDeleteTarget(null)}
                className="flex-1 py-3 px-4 bg-slate-200 rounded-xl font-bold text-slate-700 hover:bg-slate-300 transition-all"
              >
                {t('cancel')}
              </button>
              <button
                onClick={() => deleteDevice(deleteTarget.machid, true)}
                className="flex-1 py-3 px-4 bg-red-600 text-white rounded-xl font-bold hover:bg-red-700 shadow-lg shadow-red-200 transition-all active:scale-95"
              >
                {t('yes_delete')}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Create owner account — superadmin only. The password is set here and
          handed to the owner directly; there is no signup/invite mail flow. */}
      {newUser && (
        <div className="fixed inset-0 z-[110] bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-3xl w-full max-w-md shadow-2xl border-2 border-slate-300">
            <div className="flex justify-between items-center px-6 pt-6 pb-4 border-b-2 border-slate-200">
              <div>
                <h3 className="font-black text-xl text-slate-900">{t('new_user')}</h3>
                <span className="text-[10px] font-bold text-slate-500 uppercase tracking-widest">{t('new_user_hint')}</span>
              </div>
              <button
                onClick={() => setNewUser(null)}
                className="p-2 bg-slate-200 border border-slate-300 text-slate-700 rounded-full hover:bg-slate-300"
              >
                <X size={18} />
              </button>
            </div>

            <div className="p-6 space-y-4">
              <div>
                <label className="text-xs font-bold text-slate-500 ml-1">Email</label>
                <input
                  type="email"
                  value={newUser.email}
                  onChange={e => setNewUser({ ...newUser, email: e.target.value })}
                  autoFocus
                  autoComplete="off"
                  className="w-full mt-1 p-3 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-bold bg-white text-slate-900"
                />
              </div>
              <div>
                <label className="text-xs font-bold text-slate-500 ml-1">{t('password')}</label>
                <input
                  type="text"
                  value={newUser.password}
                  onChange={e => setNewUser({ ...newUser, password: e.target.value })}
                  autoComplete="new-password"
                  className="w-full mt-1 p-3 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-mono text-sm bg-white text-slate-900"
                />
                <p className="text-[11px] text-slate-400 mt-1 ml-1">{t('user_password_hint')}</p>
              </div>
              <div>
                <label className="text-xs font-bold text-slate-500 ml-1">{t('user_full_name')}</label>
                <input
                  value={newUser.full_name}
                  onChange={e => setNewUser({ ...newUser, full_name: e.target.value })}
                  className="w-full mt-1 p-3 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-bold bg-white text-slate-900"
                />
              </div>
            </div>

            <div className="flex gap-3 px-6 pb-6">
              <button
                onClick={() => setNewUser(null)}
                className="flex-1 py-3 px-4 bg-slate-200 rounded-xl font-bold text-slate-700 hover:bg-slate-300 transition-all"
              >
                {t('cancel')}
              </button>
              <button
                onClick={createUser}
                disabled={userSaving}
                className="flex-1 py-3 px-4 bg-primary text-white rounded-xl font-black shadow-lg shadow-primary/20 flex items-center justify-center gap-2 active:scale-95 transition-all disabled:opacity-60"
              >
                {userSaving ? <Loader2 className="animate-spin" size={18} /> : t('create')}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ---- Administration tab (superadmin only) ----
// The account list is the whole tab: expanding a profile reveals the machines
// assigned to it, with rename / transfer / delete on each. Machines that have
// no owner would have nowhere to appear in an owner-keyed list, so they get
// their own group at the bottom — otherwise they'd be unreachable from the UI.
//
// Accounts come from admin-create-user, machines from device-admin; both need
// the service_role key, so neither can happen in the browser. The fleet list
// can't come from a plain query either — RLS shows the superadmin only its own
// machines. The tab is hidden for non-superadmins; the functions refuse them
// regardless.
function UsersTab({
  users,
  loading,
  onCreate,
  onAddDevice,
  onChangePassword,
  onDeleteUser,
  currentUserId,
  onRefresh,
  devices,
  devicesLoading,
  onTransfer,
  onDelete,
  onRename,
}) {
  const { t, i18n } = useTranslation();
  const [expandedId, setExpandedId] = useState(null);

  const byOwner = new Map();
  for (const m of devices ?? []) {
    const key = m.owner_id || '__none__';
    if (!byOwner.has(key)) byOwner.set(key, []);
    byOwner.get(key).push(m);
  }
  const orphans = byOwner.get('__none__') ?? [];

  // One machine row, shared by the per-account lists and the orphan group.
  const deviceRow = (m) => (
    <div
      key={m.id}
      className="flex items-center gap-3 p-3 rounded-xl bg-white border border-slate-200"
    >
      <div className="w-9 h-9 rounded-lg bg-indigo-600 text-white flex items-center justify-center shrink-0">
        <Package size={16} />
      </div>
      <div className="flex-1 min-w-0">
        <div className="font-bold text-sm text-slate-900 truncate">{m.name || `${t('apparatus_no')}${m.id}`}</div>
        <div className="text-[11px] font-bold text-slate-500">{t('apparatus_no')}{m.id}</div>
        {/* Same crowding as the owner list, worse: three action buttons here.
            Status and type move under the name on a phone. */}
        <div className="flex sm:hidden items-center gap-2 mt-1.5 flex-wrap">
          <DeviceStatusDot status={m.heartbeat} kind={m.kind} />
          <span className={`text-[9px] font-black uppercase tracking-wider px-2 py-1 rounded-lg ${m.kind === 'micromarket_static' ? 'bg-emerald-100 text-emerald-700' : 'bg-indigo-100 text-indigo-700'}`}>
            {m.kind === 'micromarket_static' ? t('badge_micromarket') : t('badge_vending')}
          </span>
        </div>
      </div>
      <div className="hidden sm:flex items-center gap-3 shrink-0">
        <DeviceStatusDot status={m.heartbeat} kind={m.kind} />
        <span className={`text-[9px] font-black uppercase tracking-wider px-2 py-1 rounded-lg ${m.kind === 'micromarket_static' ? 'bg-emerald-100 text-emerald-700' : 'bg-indigo-100 text-indigo-700'}`}>
          {m.kind === 'micromarket_static' ? t('badge_micromarket') : t('badge_vending')}
        </span>
      </div>
      <div className="flex gap-1.5 shrink-0">
        <button
          onClick={() => onRename({ id: m.id, name: m.name || '' })}
          title={t('rename')}
          className="p-2 rounded-lg bg-white border border-slate-300 text-slate-600 hover:text-primary hover:border-primary transition-all"
        >
          <Pencil size={14} />
        </button>
        <button
          onClick={() => onTransfer(m)}
          title={t('transfer_device')}
          className="p-2 rounded-lg bg-white border border-slate-300 text-slate-600 hover:text-primary hover:border-primary transition-all"
        >
          <ChevronRight size={14} />
        </button>
        <button
          onClick={() => onDelete(m.id)}
          disabled={devicesLoading}
          title={t('delete')}
          className="p-2 rounded-lg bg-white border border-slate-300 text-slate-600 hover:text-red-600 hover:border-red-300 transition-all disabled:opacity-50"
        >
          <Trash2 size={14} />
        </button>
      </div>
    </div>
  );

  return (
    <div>
      <div className="flex justify-between items-start gap-3 mb-6">
        <div>
          <h2 className="text-2xl font-black text-slate-900 mb-1">{t('users_section')}</h2>
          <p className="text-[11px] font-bold text-slate-500 uppercase tracking-widest">{t('users_subtitle')}</p>
        </div>
        <div className="flex gap-2 shrink-0 flex-wrap justify-end">
          <button
            onClick={onRefresh}
            disabled={loading}
            className="px-3 py-2.5 bg-slate-200 rounded-xl font-bold text-sm text-slate-700 hover:bg-slate-300 transition-all disabled:opacity-60"
          >
            {loading ? <Loader2 className="animate-spin" size={16} /> : <History size={16} />}
          </button>
          <button
            onClick={onCreate}
            className="bg-primary text-white px-4 py-2.5 rounded-xl font-bold text-sm shadow-lg shadow-primary/20 flex items-center gap-2 active:scale-95 transition-all"
          >
            <Plus size={16} /> {t('new_user')}
          </button>
          {/* Enrolling a machine is a platform-admin act, so it lives here
              next to account creation rather than on the owner-facing tab. */}
          <button
            onClick={onAddDevice}
            className="bg-slate-900 text-white px-4 py-2.5 rounded-xl font-bold text-sm shadow-lg shadow-slate-900/20 flex items-center gap-2 active:scale-95 transition-all"
          >
            <Plus size={16} /> {t('add_device')}
          </button>
        </div>
      </div>

      {users == null ? (
        <div className="flex justify-center p-10"><Loader2 className="animate-spin text-primary" size={28} /></div>
      ) : users.length === 0 ? (
        <p className="text-sm text-slate-400 italic p-4">{t('no_users')}</p>
      ) : (
        <div className="space-y-2">
          {users.map(u => {
            const owned = byOwner.get(u.id) ?? [];
            const open = expandedId === u.id;
            return (
              <div key={u.id} className="rounded-2xl bg-slate-50 border-2 border-slate-200 overflow-hidden">
                <div className="flex items-center gap-3 p-4">
                  <button
                    onClick={() => setExpandedId(open ? null : u.id)}
                    className="flex items-center gap-3 flex-1 min-w-0 text-left"
                  >
                    <div className={`w-11 h-11 rounded-xl text-white flex items-center justify-center shrink-0 font-black ${u.role === 'superadmin' ? 'bg-amber-500' : 'bg-slate-500'}`}>
                      {(u.email || '?').charAt(0).toUpperCase()}
                    </div>
                    <div className="flex-1 min-w-0">
                      <div className="font-bold text-slate-900 truncate">{u.email}</div>
                      <div className="text-[11px] font-bold text-slate-500 truncate">
                        {u.full_name ? `${u.full_name} · ` : ''}
                        {t('user_since')} {u.created_at ? new Date(u.created_at).toLocaleDateString(i18n.language) : '—'}
                      </div>
                    </div>
                  </button>
                  {u.role === 'superadmin' && (
                    <span className="text-[9px] font-black uppercase tracking-wider px-2 py-1 rounded-lg bg-amber-100 text-amber-700 shrink-0">
                      {t('role_superadmin')}
                    </span>
                  )}
                  <button
                    onClick={() => setExpandedId(open ? null : u.id)}
                    className="flex items-center gap-1 text-[9px] font-black uppercase tracking-wider px-2 py-1 rounded-lg bg-indigo-100 text-indigo-700 shrink-0 hover:bg-indigo-200 transition-all"
                  >
                    {u.machines} {t('devices_short')}
                    <ChevronDown size={12} className={`transition-transform ${open ? 'rotate-180' : ''}`} />
                  </button>
                  <div className="flex gap-1.5 shrink-0">
                    <button
                      onClick={() => onChangePassword(u)}
                      title={t('change_password')}
                      className="p-2 rounded-lg bg-white border border-slate-300 text-slate-600 hover:text-primary hover:border-primary transition-all"
                    >
                      <KeyRound size={15} />
                    </button>
                    {/* Deleting your own account would lock you out of the panel —
                        the function refuses it too. */}
                    <button
                      onClick={() => onDeleteUser(u)}
                      disabled={u.id === currentUserId}
                      title={t('delete')}
                      className="p-2 rounded-lg bg-white border border-slate-300 text-slate-600 hover:text-red-600 hover:border-red-300 transition-all disabled:opacity-40 disabled:hover:text-slate-600 disabled:hover:border-slate-300"
                    >
                      <Trash2 size={15} />
                    </button>
                  </div>
                </div>

                {open && (
                  <div className="px-4 pb-4 pt-1 border-t border-slate-200 bg-slate-100/60">
                    {devices == null ? (
                      <div className="flex justify-center p-6"><Loader2 className="animate-spin text-primary" size={22} /></div>
                    ) : owned.length === 0 ? (
                      <p className="text-xs text-slate-400 italic py-3">{t('user_no_devices')}</p>
                    ) : (
                      <div className="space-y-2 pt-3">{owned.map(deviceRow)}</div>
                    )}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      {/* Machines with no owner have no profile to hide under — surface them
          separately so they can still be assigned or removed. */}
      {orphans.length > 0 && (
        <div className="mt-8 pt-6 border-t-2 border-slate-200">
          <h3 className="text-sm font-black text-rose-600 mb-1">{t('devices_no_owner')}</h3>
          <p className="text-[11px] font-bold text-slate-500 uppercase tracking-widest mb-4">{t('devices_no_owner_hint')}</p>
          <div className="space-y-2">{orphans.map(deviceRow)}</div>
        </div>
      )}
    </div>
  );
}

// ---- Catalog tab (products table) ----
// Shows the owner's SKU catalog. Each row in `products` is a reusable
// SKU that inventory rows reference via `product_id`. Filters cover
// the three editorial states: active, drafts (auto-created from the
// tablet), and archived.
function CatalogTab({
  products,
  categories,
  filter,
  setFilter,
  loading,
  onCreate,
  onEdit,
  onArchive,
  onPublish,
  onDelete,
}) {
  const { t } = useTranslation();
  const visible = products.filter(p => {
    if (filter === 'drafts') return p.is_draft && !p.is_archived;
    if (filter === 'archived') return p.is_archived;
    return !p.is_draft && !p.is_archived;
  });

  const counts = {
    active: products.filter(p => !p.is_draft && !p.is_archived).length,
    drafts: products.filter(p => p.is_draft && !p.is_archived).length,
    archived: products.filter(p => p.is_archived).length,
  };

  return (
    <>
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 mb-8">
        <div>
          <h2 className="text-2xl font-black text-slate-900">{t('catalog_products_title')}</h2>
          <p className="text-[11px] font-bold text-slate-500 uppercase tracking-widest">
            {t('catalog_products_subtitle')}
          </p>
        </div>
        <button
          onClick={onCreate}
          className="flex items-center justify-center gap-2 bg-primary text-white px-5 py-2.5 rounded-xl font-bold hover:brightness-110 transition-all shadow-lg shadow-primary/30 text-sm border-2 border-primary"
        >
          <Plus size={16} /> {t('add_product')}
        </button>
      </div>

      <div className="flex gap-2 mb-8 border-b-2 border-slate-200 pb-3 overflow-x-auto no-scrollbar">
        {[
          { id: 'active', label: t('filter_active'), count: counts.active },
          { id: 'drafts', label: t('filter_drafts'), count: counts.drafts },
          { id: 'archived', label: t('filter_archived'), count: counts.archived },
        ].map(tab => (
          <button
            key={tab.id}
            onClick={() => setFilter(tab.id)}
            className={`px-5 py-2 rounded-xl text-xs font-bold whitespace-nowrap transition-all ${
              filter === tab.id
                ? 'bg-slate-900 text-white shadow-md'
                : 'bg-white text-slate-600 border border-slate-300 hover:border-slate-400 hover:bg-slate-50'
            }`}
          >
            {tab.label}
            <span className={`ml-1.5 ${filter === tab.id ? 'text-slate-300' : 'text-slate-400'}`}>
              {tab.count}
            </span>
          </button>
        ))}
      </div>

      {loading ? (
        <div className="flex justify-center p-20">
          <Loader2 className="animate-spin text-primary" size={32} />
        </div>
      ) : visible.length === 0 ? (
        <div className="text-center py-20 bg-slate-50 border-2 border-dashed border-slate-300 rounded-2xl">
          <Image className="mx-auto mb-3 text-slate-300" size={48} />
          <p className="font-black text-slate-500 text-sm uppercase tracking-widest">
            {filter === 'drafts' ? t('no_drafts') : filter === 'archived' ? t('archive_empty') : t('catalog_empty')}
          </p>
        </div>
      ) : (
        <div className="space-y-2.5">
          {visible.map(p => (
            <div
              key={p.id}
              className={`group border-2 p-3 rounded-2xl flex items-center gap-4 transition-all ${
                p.is_archived
                  ? 'bg-slate-100 border-slate-300'
                  : p.is_draft
                    ? 'bg-amber-50 border-amber-300 hover:border-amber-500 hover:shadow-md'
                    : 'bg-slate-50 border-slate-200 hover:border-primary hover:bg-white hover:shadow-md'
              }`}
            >
              <div className="w-14 h-14 bg-white rounded-xl flex items-center justify-center overflow-hidden shrink-0 border-2 border-slate-200">
                {p.image_url ? (
                  <img src={p.image_url} alt={p.name} loading="lazy" className="w-full h-full object-contain p-1" />
                ) : p.emoji ? (
                  <span className="text-2xl">{p.emoji}</span>
                ) : (
                  <Image className="text-slate-300" size={20} />
                )}
              </div>

              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2 flex-wrap">
                  <h4 className="font-bold text-sm text-slate-900 truncate pr-1">{p.name}</h4>
                  {p.is_draft && (
                    <span className="text-[9px] uppercase font-black bg-amber-600 text-white px-1.5 py-0.5 rounded">
                      {t('badge_draft')}
                    </span>
                  )}
                  {p.is_archived && (
                    <span className="text-[9px] uppercase font-black bg-slate-600 text-white px-1.5 py-0.5 rounded">
                      {t('badge_archived')}
                    </span>
                  )}
                </div>
                <div className="flex items-center gap-2 mt-1">
                  <span className="text-[9px] uppercase font-black text-slate-600 tracking-wider px-1.5 py-0.5 bg-white border border-slate-300 rounded">
                    {categories.find(c => c.id === p.category_id)?.name_ru || t('no_category')}
                  </span>
                  {p.volume_ml != null && (
                    <span className="text-[10px] font-bold text-slate-700 bg-white border border-slate-300 px-1.5 py-0.5 rounded">{p.volume_ml} {t('unit_ml')}</span>
                  )}
                </div>
              </div>

              <div className="flex gap-1">
                {p.is_draft && (
                  <button
                    onClick={() => onPublish(p)}
                    title={t('publish')}
                    className="p-2.5 bg-emerald-600 text-white rounded-lg hover:bg-emerald-700 transition-all shadow-sm"
                  >
                    <CheckCircle2 size={14} />
                  </button>
                )}
                <button
                  onClick={() => onEdit(p)}
                  title={t('edit')}
                  className="p-2.5 bg-white border border-slate-300 text-slate-600 rounded-lg hover:bg-primary hover:border-primary hover:text-white transition-all"
                >
                  <Pencil size={14} />
                </button>
                <button
                  onClick={() => onArchive(p)}
                  title={p.is_archived ? t('restore') : t('to_archive')}
                  className="p-2.5 bg-white border border-slate-300 text-slate-600 rounded-lg hover:bg-amber-600 hover:border-amber-600 hover:text-white transition-all"
                >
                  {p.is_archived ? <CheckCircle2 size={14} /> : <XCircle size={14} />}
                </button>
                <button
                  onClick={() => onDelete(p)}
                  title={t('delete_forever')}
                  className="p-2.5 bg-white border border-slate-300 text-slate-600 rounded-lg hover:bg-red-600 hover:border-red-600 hover:text-white transition-all"
                >
                  <Trash2 size={14} />
                </button>
              </div>
            </div>
          ))}
        </div>
      )}
    </>
  );
}

// ---- Inventory list (driven by per-machine layout) ----
// Single list view: walks the layout shelf-by-shelf and renders one
// row per slot. Empty positions are still shown (italic "Слот пуст")
// so the operator immediately sees which spirals need re-stocking.
// Rows that point to a motor not present in the current layout get a
// "Не привязано" section at the bottom.
// Flat product list for open-shelf (static) micromarkets — no motors/slots.
// Add is handled by the header button; rows support edit + delete.
function StaticInventoryList({ products, categories, priceLabel, onEdit, onDelete }) {
  const { t } = useTranslation();
  if (!products || products.length === 0) {
    return (
      <div className="text-center py-16 bg-slate-50 rounded-3xl border-2 border-dashed border-slate-200">
        <Package size={36} className="mx-auto mb-3 text-slate-300" />
        <p className="font-black text-slate-400 text-sm uppercase tracking-widest">{t('no_products')}</p>
        <p className="text-xs text-slate-400 mt-1">{t('no_products_hint')}</p>
      </div>
    );
  }
  return (
    <div className="space-y-2">
      {products.map(p => {
        const lowStock = (p.stock ?? 0) < 5;
        const cat = categories.find(c => c.id === p.category_id)?.name_ru;
        return (
          <div
            key={p.id}
            onClick={() => onEdit(p)}
            className="flex items-center gap-3 p-2.5 sm:p-3 rounded-2xl border-2 border-slate-200 bg-slate-50 hover:border-primary hover:bg-white hover:shadow-md cursor-pointer transition-all"
          >
            <div className="w-12 h-12 sm:w-14 sm:h-14 rounded-xl flex items-center justify-center overflow-hidden shrink-0 border-2 border-slate-200 bg-white">
              {p.image_url ? (
                <img src={p.image_url} alt={p.name} loading="lazy" className="w-full h-full object-contain p-1" />
              ) : p.emoji ? (
                <span className="text-2xl">{p.emoji}</span>
              ) : (
                <Image className="text-slate-300" size={20} />
              )}
            </div>
            <div className="flex-1 min-w-0">
              <h4 className="font-bold text-sm text-slate-900 truncate">{p.name || '—'}</h4>
              <div className="flex items-center gap-1.5 mt-1">
                <span className={`text-[10px] font-black px-1.5 py-0.5 rounded tabular-nums ${lowStock ? 'bg-red-100 text-red-700' : 'bg-emerald-100 text-emerald-700'}`}>×{p.stock ?? 0}</span>
                <span className="text-[9px] uppercase font-black text-slate-500 tracking-wider truncate">{cat || t('no_category')}</span>
              </div>
            </div>
            <div className="text-right px-2 sm:px-4 shrink-0">
              <span className="hidden sm:block text-[9px] font-black text-slate-500 uppercase tracking-tighter">{priceLabel}</span>
              <p className="text-base font-black text-primary tabular-nums">{p.price} ₸</p>
            </div>
            <div className="flex items-center gap-1 shrink-0">
              <button onClick={(e) => { e.stopPropagation(); onEdit(p); }} className="p-2.5 bg-white border border-slate-300 text-slate-600 rounded-lg hover:bg-primary hover:border-primary hover:text-white transition-all"><Pencil size={14} /></button>
              <button onClick={(e) => { e.stopPropagation(); onDelete(p); }} className="hidden sm:inline-flex p-2.5 bg-white border border-slate-300 text-slate-600 rounded-lg hover:bg-red-600 hover:border-red-600 hover:text-white transition-all"><Trash2 size={14} /></button>
            </div>
          </div>
        );
      })}
    </div>
  );
}

function InventoryByLayout({ products, layout, categories, stockLabel, priceLabel, onEdit, onDelete }) {
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
  const unassigned = products.filter(p =>
    p.motor_id == null || !mappedMotorIds.has(Number(p.motor_id))
  );

  return (
    <div className="space-y-6">
      {layout.shelves.map((shelf, idx) => (
        <div key={`${idx}-${shelf.label}`}>
          <div className="flex items-center gap-2 mb-3 px-1">
            <span className="bg-slate-900 text-white text-[10px] font-black px-2 py-0.5 rounded tabular-nums">
              {t('shelf')} {idx + 1}
            </span>
            <span className="text-[11px] font-bold text-slate-600">{shelf.label}</span>
            <span className="text-[10px] font-bold text-slate-400 ml-auto">
              {shelf.slots.length} {shelf.slots.length === 1 ? t('slot_one') : t('slot_many')}
            </span>
          </div>
          <div className="space-y-2">
            {shelf.slots.map((sl, j) => {
              const primary = sl.motorIds[0];
              const p = productByMotor.get(primary) || null;
              return (
                <InventoryRow
                  key={`${idx}-${j}-${primary}`}
                  slot={sl}
                  product={p}
                  category={p ? categories.find(c => c.id === p.category_id)?.name_ru : null}
                  stockLabel={stockLabel}
                  priceLabel={priceLabel}
                  onEdit={p ? () => onEdit(p) : null}
                  onDelete={p ? () => onDelete(p) : null}
                />
              );
            })}
          </div>
        </div>
      ))}

      {unassigned.length > 0 && (
        <div className="p-4 bg-amber-50 border-2 border-amber-300 rounded-2xl">
          <div className="flex items-center gap-2 mb-3">
            <AlertTriangle size={16} className="text-amber-700" />
            <span className="text-xs font-black uppercase tracking-wider text-amber-900">
              {t('not_linked_to_layout')} ({unassigned.length})
            </span>
          </div>
          <div className="space-y-2">
            {unassigned.map(p => (
              <div
                key={p.id}
                onClick={() => onEdit(p)}
                className="w-full flex items-center gap-3 p-2.5 rounded-xl bg-white border-2 border-amber-200 hover:border-amber-500 hover:shadow-md transition-all text-left cursor-pointer"
              >
                <div className="w-10 h-10 bg-slate-50 rounded-lg flex items-center justify-center overflow-hidden shrink-0 border border-slate-200">
                  {p.image_url ? (
                    <img src={p.image_url} alt={p.name} loading="lazy" className="w-full h-full object-contain p-1" />
                  ) : p.emoji ? (
                    <span className="text-xl">{p.emoji}</span>
                  ) : (
                    <Image size={14} className="text-slate-300" />
                  )}
                </div>
                <div className="flex-1 min-w-0">
                  <div className="font-bold text-sm truncate text-slate-900">{p.name || '—'}</div>
                  <div className="text-[11px] text-amber-800">
                    {p.motor_id == null
                      ? t('no_motor_id')
                      : `M${p.motor_id} ${t('motor_not_in_layout')}`}
                  </div>
                </div>
                <div className="flex items-center gap-1 shrink-0">
                  <button
                    onClick={(e) => { e.stopPropagation(); onEdit(p); }}
                    className="p-2 bg-white border border-amber-300 text-amber-700 rounded-lg hover:bg-amber-600 hover:border-amber-600 hover:text-white transition-all"
                    title={t('edit')}
                  >
                    <Pencil size={14} />
                  </button>
                  <button
                    onClick={(e) => { e.stopPropagation(); onDelete(p); }}
                    className="p-2 bg-white border border-amber-300 text-amber-700 rounded-lg hover:bg-red-600 hover:border-red-600 hover:text-white transition-all"
                    title={t('delete_short')}
                  >
                    <Trash2 size={14} />
                  </button>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

function InventoryRow({ slot, product, category, stockLabel, priceLabel, onEdit, onDelete }) {
  const { t } = useTranslation();
  // Slot identification: label ("001") + the linked motor index
  // (e.g. "M99" or "M99+M95" for twin spirals).
  const motorsLabel = (slot.motorIds ?? []).map(m => `M${m}`).join('+');
  const isTwin = (slot.motorIds?.length ?? 0) > 1;
  const empty = product == null;
  const lowStock = !empty && (product.stock ?? 0) < 5;

  return (
    <div
      onClick={empty ? undefined : onEdit}
      className={`group border-2 rounded-2xl transition-all ${
        empty
          ? 'border-dashed border-slate-300 bg-slate-50'
          : 'border-slate-200 bg-slate-50 hover:border-primary hover:bg-white hover:shadow-md cursor-pointer active:scale-[0.99]'
      } p-2.5 sm:p-3`}
    >
      <div className="flex items-center gap-2.5 sm:gap-4">
        {/* Slot badge — narrower on mobile (no motor pin to save space) */}
        <div className="bg-indigo-600 text-white rounded-xl flex flex-col items-center justify-center shrink-0 border-2 border-indigo-700 px-2 py-1.5 min-w-[48px] sm:min-w-[64px]">
          <span className="font-black text-base sm:text-lg leading-none tabular-nums">{slot.label}</span>
          <span className="hidden sm:block text-[9px] font-black opacity-70 leading-none mt-0.5 tabular-nums">{motorsLabel}</span>
          {isTwin && (
            <span className="text-[7px] font-black bg-amber-500 text-white px-1 rounded mt-0.5 leading-none">TWIN</span>
          )}
        </div>

        {/* Thumbnail */}
        <div className="w-12 h-12 sm:w-14 sm:h-14 rounded-xl flex items-center justify-center overflow-hidden shrink-0 border-2 border-slate-200 bg-white">
          {empty ? (
            <Image className="text-slate-200" size={20} />
          ) : product.image_url ? (
            <img src={product.image_url} alt={product.name} loading="lazy" className="w-full h-full object-contain p-1" />
          ) : product.emoji ? (
            <span className="text-2xl">{product.emoji}</span>
          ) : (
            <Image className="text-slate-300" size={20} />
          )}
        </div>

        {/* Name + category + (mobile-only) stock × price line */}
        <div className="flex-1 min-w-0">
          {empty ? (
            <div className="italic text-slate-400 font-bold text-sm">{t('slot_empty')}</div>
          ) : (
            <>
              <h4 className="font-bold text-sm text-slate-900 truncate">{product.name}</h4>
              {/* Mobile: stock + price inline; desktop: just category */}
              <div className="flex items-center gap-1.5 mt-1 sm:hidden">
                <span className={`text-[10px] font-black px-1.5 py-0.5 rounded tabular-nums ${lowStock ? 'bg-red-100 text-red-700' : 'bg-emerald-100 text-emerald-700'}`}>
                  ×{product.stock ?? 0}
                </span>
                <span className="text-sm font-black text-primary tabular-nums">{product.price} ₸</span>
                <span className="text-[9px] uppercase font-black text-slate-500 tracking-wider truncate">
                  {category || t('no_category')}
                </span>
              </div>
              <div className="hidden sm:flex items-center gap-2 mt-1">
                <span className="text-[9px] uppercase font-black text-slate-600 tracking-wider px-1.5 py-0.5 bg-white border border-slate-300 rounded">
                  {category || t('no_category')}
                </span>
              </div>
            </>
          )}
        </div>

        {/* Desktop-only stock + price columns */}
        <div className="hidden sm:flex flex-col items-end px-6 border-l-2 border-slate-200">
          <span className="text-[9px] font-black text-slate-500 uppercase tracking-tighter">{stockLabel}</span>
          {empty ? (
            <span className="font-black text-base text-slate-300">—</span>
          ) : (
            <span className={`font-black text-base tabular-nums ${lowStock ? 'text-red-600' : 'text-slate-900'}`}>{product.stock}</span>
          )}
        </div>
        <div className="hidden sm:block text-right px-4 border-l-2 border-slate-200 min-w-[80px]">
          <span className="text-[9px] font-black text-slate-500 uppercase tracking-tighter block">{priceLabel}</span>
          {empty ? (
            <p className="text-base font-black text-slate-300">—</p>
          ) : (
            <p className="text-base font-black text-primary tabular-nums">{product.price} ₸</p>
          )}
        </div>

        {/* Right-edge controls. Whole row is tap-to-edit on mobile so
            the pencil is just a visual cue. Delete lives in the modal
            (deleteProduct call on Trash icon there). */}
        <div className="flex items-center gap-1 shrink-0">
          {empty ? (
            <span className="hidden sm:block text-[10px] font-bold text-slate-400 italic max-w-[80px] text-right leading-tight">{t('tablet_only')}</span>
          ) : (
            <>
              <button
                onClick={(e) => { e.stopPropagation(); onEdit(); }}
                className="p-2.5 bg-white border border-slate-300 text-slate-600 rounded-lg hover:bg-primary hover:border-primary hover:text-white transition-all"
              >
                <Pencil size={14} />
              </button>
              <button
                onClick={(e) => { e.stopPropagation(); onDelete(); }}
                className="hidden sm:inline-flex p-2.5 bg-white border border-slate-300 text-slate-600 rounded-lg hover:bg-red-600 hover:border-red-600 hover:text-white transition-all"
              >
                <Trash2 size={14} />
              </button>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
