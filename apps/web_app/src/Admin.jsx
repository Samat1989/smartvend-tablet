import { useEffect, useMemo, useRef, useState } from 'react';
import { LayoutGrid, LineChart, ShieldCheck, Tag } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { supabase } from './supabaseClient';
import './i18n';

import Shell from './admin/layout/Shell';
import Login from './admin/layout/Login';
import { ConfirmDialog, Toast } from './admin/ui/Feedback';
import SalesTab from './admin/tabs/SalesTab';
import MachinesTab from './admin/tabs/MachinesTab';
import MachineDetail from './admin/tabs/MachineDetail';
import CatalogTab from './admin/tabs/CatalogTab';
import AdminTab from './admin/tabs/AdminTab';
import QrModal from './admin/modals/QrModal';
import MachineSettingsModal from './admin/modals/MachineSettingsModal';
import PhotoLibraryModal from './admin/modals/PhotoLibraryModal';
import {
  AddDeviceModal, CatalogEditModal, CatalogPickerModal, CategoryManagerModal, CropperModal,
  InventoryEditModal, NewUserModal, PasswordModal, RenameModal, TransferModal,
} from './admin/modals/Forms';
import { deleteRow, isNetworkFailure, patchRow } from './admin/lib/net';
import { CELL_MAX, CELL_MIN, currencyOf, kindLabel, machineName, nextFreeCellNumber, parseLayout } from './admin/lib/machines';
import { LIBRARY_BASE, getCroppedImg, prepareForCrop } from './admin/lib/photo';

// Machine-readable codes from supabase/functions/device-claim/index.ts →
// operator-facing text. Anything else falls through to the raw message.
// (`secret_required` only fires on the function's curl-only `force` path.)
const DEVICE_CLAIM_ERRORS = {
  bad_machid: 'device_err_bad_machid',
  machine_not_found: 'device_err_not_found',
  secret_mismatch: 'device_err_secret_mismatch',
};

/**
 * MicroVend owner panel. This component holds the session, the machine list
 * with its live board presence, and every write the panel makes; the screens
 * themselves live in ./admin/tabs and the dialogs in ./admin/modals.
 */
export default function Admin() {
  const { t } = useTranslation();
  const [session, setSession] = useState(null);
  const [toast, setToast] = useState(null); // { message, type }
  const [activeTab, setActiveTab] = useState('sales'); // 'sales' | 'inventory' | 'catalog' | 'users'
  const [confirmAction, setConfirmAction] = useState(null); // {message, onYes, yesLabel?, tone?, subject?, warning?}

  // ── Machines ────────────────────────────────────────────────────────────
  const [markets, setMarkets] = useState([]);
  const [marketsLoaded, setMarketsLoaded] = useState(false);
  const [selectedMarketId, setSelectedMarketId] = useState(null);
  const [qrModalMarket, setQrModalMarket] = useState(null);
  const [serviceOpening, setServiceOpening] = useState(null); // machid whose door is being opened for service
  const [renamingMarket, setRenamingMarket] = useState(null); // {id,name}
  const [pairMarket, setPairMarket] = useState(null);         // machine whose settings dialog is open

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
    setActiveTab('inventory');
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

  // A new screen starts at the top; switching sections kept the old scroll
  // and opened Sales somewhere in the middle of the list.
  useEffect(() => { window.scrollTo(0, 0); }, [activeTab, selectedMarketId]);

  // ── Inventory of the open machine ───────────────────────────────────────
  const [products, setProducts] = useState([]);
  const [inventoryLoading, setInventoryLoading] = useState(false);
  const [editingProduct, setEditingProduct] = useState(null);
  const [savingProduct, setSavingProduct] = useState(false);
  const [categories, setCategories] = useState([]);
  const [showCategoryManager, setShowCategoryManager] = useState(false);
  const [showCatalogPicker, setShowCatalogPicker] = useState(false);
  const [pickerProducts, setPickerProducts] = useState(null);

  // ── Catalog ─────────────────────────────────────────────────────────────
  // Separate from inventory: products are reusable across micromarkets and
  // only carry name/photo/category/volume; per-slot fields like price/stock/
  // motor_id live on inventory rows that reference them.
  const [catalogProducts, setCatalogProducts] = useState([]);
  const [catalogLoading, setCatalogLoading] = useState(false);
  const [catalogFilter, setCatalogFilter] = useState('active');
  const [editingCatalog, setEditingCatalog] = useState(null);
  const [savingCatalog, setSavingCatalog] = useState(false);
  const [uploadingImage, setUploadingImage] = useState(false);
  const catalogFileInputRef = useRef(null);
  const [cropImageSrc, setCropImageSrc] = useState(null);
  const [crop, setCrop] = useState({ x: 0, y: 0 });
  const [zoom, setZoom] = useState(1);
  const [croppedAreaPixels, setCroppedAreaPixels] = useState(null);
  // The shared photo library: the index is fetched once per session and kept
  // here rather than in the modal, so reopening the picker costs nothing.
  const [libraryOpen, setLibraryOpen] = useState(false);
  const [libraryIndex, setLibraryIndex] = useState(null);
  const [libraryLoading, setLibraryLoading] = useState(false);

  // ── Superadmin ──────────────────────────────────────────────────────────
  // The flag comes from app_metadata, which only the service_role can write —
  // see migration 20260804120000_superadmin_role.sql. Hiding the section is
  // cosmetic; the real check is inside the admin edge functions.
  const isSuperadmin = session?.user?.app_metadata?.is_superadmin === true;
  const [users, setUsers] = useState(null);
  const [usersLoading, setUsersLoading] = useState(false);
  const [newUser, setNewUser] = useState(null);      // {email,password,full_name} while the form is open
  const [userSaving, setUserSaving] = useState(false);
  const [pwdTarget, setPwdTarget] = useState(null);  // {id,email,password}
  // "Add device": the superadmin types the machine's SmartVend Internal ID and
  // optionally its Secret; device-claim resolves the rest upstream.
  const [addingDevice, setAddingDevice] = useState(null); // {machid,secret,kind}
  const [deviceSaving, setDeviceSaving] = useState(false);
  // Fleet view. RLS hides other owners' machines from the browser session, so
  // this list comes from the device-admin function.
  const [adminDevices, setAdminDevices] = useState(null);
  const [adminOwners, setAdminOwners] = useState([]);
  const [devicesLoading, setDevicesLoading] = useState(false);
  const [transferTarget, setTransferTarget] = useState(null);
  const [transferring, setTransferring] = useState(false);

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

  // ── Session ─────────────────────────────────────────────────────────────
  useEffect(() => {
    // Both sources below hand us a structurally identical session object with a
    // fresh identity: getSession() resolves once, and onAuthStateChange fires
    // for INITIAL_SESSION right after it, on every token refresh (~hourly), and
    // whenever the tab regains focus. Storing a new object each time re-renders
    // the panel and re-runs every effect keyed on `session` — which is why the
    // edge functions saw every request twice, milliseconds apart.
    //
    // Keep the previous object while the token is unchanged, so only a real auth
    // change propagates.
    const keepIfSame = (s) =>
      setSession(prev => (prev?.access_token === s?.access_token ? prev : s));

    supabase.auth.getSession().then(({ data: { session } }) => keepIfSame(session));
    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      (_event, session) => keepIfSame(session),
    );
    return () => subscription.unsubscribe();
  }, []);

  // A dead session arrives in two disguises. PostgREST answers 42501: the
  // request fell through to the `anon` role, which lost its direct grants in
  // the June lockdown, so "permission denied for table micromarkets" really
  // means "no token". Edge functions answer 401 from their own getUser check.
  // Re-check the session, and if it is really gone, drop to the login screen.
  // Returns true when it handled the error, so callers can skip their own toast.
  async function handleAuthFailure(err) {
    const looksAuth =
      err?.code === '42501' || err?.code === 'PGRST301' ||
      err?.status === 401 || err?.context?.status === 401;
    if (!looksAuth) return false;

    const { data } = await supabase.auth.getSession();
    if (data?.session) return false;   // signed in after all — a genuine denial

    setSession(null);
    showToast(t('session_expired'), 'error');
    return true;
  }

  // Call one of the admin edge functions with the operator's own session token
  // (supabase-js attaches it automatically while a session exists). invoke()
  // reports every non-2xx as the same generic message, so dig the function's
  // own JSON `error` out of the response body.
  async function invokeAdminFn(name, options) {
    const { data, error } = await supabase.functions.invoke(name, options);
    if (error) {
      let payload = null;
      try { payload = await error.context?.json(); } catch { /* not JSON */ }
      const err = new Error(payload?.error || error.message);
      err.code = payload?.error;   // stable machine-readable code
      err.status = error.context?.status;
      err.details = payload;       // full body — e.g. the row counts on a delete
      if (err.status === 401) await handleAuthFailure(err);
      throw err;
    }
    return data;
  }

  useEffect(() => {
    if (session) {
      fetchMarkets();
      fetchCategories();
    } else {
      setMarketsLoaded(false);
    }
  }, [session]);

  // The superadmin lands on Administration — it's the section they actually
  // open the panel for. Runs once: after that the operator's choice stands.
  const landedRef = useRef(false);
  useEffect(() => {
    if (session && isSuperadmin && !landedRef.current) {
      landedRef.current = true;
      setActiveTab('users');
    }
  }, [session, isSuperadmin]);

  // Keep the connection lamps current while a machine list is on screen, and
  // only while the page is actually visible. Coming back to the tab refreshes
  // immediately rather than waiting out the interval.
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

  useEffect(() => {
    if (selectedMarketId && activeTab === 'inventory') fetchProducts(selectedMarketId);
  }, [selectedMarketId, activeTab]);

  useEffect(() => {
    if (session && activeTab === 'catalog') fetchCatalogProducts();
  }, [session, activeTab]);

  useEffect(() => {
    if (session && isSuperadmin && activeTab === 'users') {
      fetchUsers();
      fetchAdminDevices();
    }
  }, [session, isSuperadmin, activeTab]);

  // ── Machines: load ──────────────────────────────────────────────────────
  async function fetchMarkets() {
    try {
      // Two queries, merged here rather than one embedded select: PostgREST
      // can't infer a relationship to a view, and `online` has to come from
      // the view — the 3-minute threshold is evaluated in SQL against the
      // database clock. Computing it here would compare the tablet's beat
      // to the browser's clock, which on a kiosk network is often minutes
      // out and would flip machines offline at random.
      const [marketsRes, statusRes, rtRes] = await Promise.all([
        supabase.from('micromarkets').select('id, name, layout_json, kind, qr_token, open_seconds'),
        supabase.from('device_status_view').select('machid, last_seen_at, board_ok, online, app_version, ter_number'),
        // Boards on the Realtime firmware. Missing RPC (migration not applied
        // yet) just means "none" — the panel keeps working.
        supabase.rpc('my_device_rt'),
      ]);
      if (marketsRes.error) throw marketsRes.error;
      const byId = new Map((statusRes.data || []).map((s) => [String(s.machid), s]));
      // A failed my_device_rt must not erase what the list already knows: it
      // would drop the connection lamp of every paired board until the next
      // poll, and a machine without a lamp reads as "no board", not "no data".
      if (rtRes.error) console.error('my_device_rt failed, keeping last known:', rtRes.error);
      const rtById = new Map((rtRes.error ? [] : rtRes.data || []).map((r) => [String(r.machid), r]));
      setMarkets((prev) => {
        const prevRt = new Map(prev.map((m) => [String(m.id), m.rt]));
        return (marketsRes.data || [])
          .map((m) => ({
            ...m,
            // Absent row = the machine has never reported. Left undefined so the
            // badge can say "never seen" instead of claiming it's offline.
            status: byId.get(String(m.id)),
            rt: rtRes.error ? prevRt.get(String(m.id)) : rtById.get(String(m.id)),
          }))
          .sort((a, b) => (a.name || '').localeCompare(b.name || '') || a.id - b.id);
      });
      setMarketsLoaded(true);
    } catch (err) {
      console.error('Error fetching markets:', err);
      if (await handleAuthFailure(err)) return;
      setMarketsLoaded(true);
      showToast(t('could_not_load_markets'), 'error');
    }
  }

  async function fetchCategories() {
    try {
      // RLS limits categories to owner_id=auth.uid() OR owner_id IS NULL
      // (legacy shared rows from before the per-owner migration).
      const { data, error } = await supabase.from('categories').select('*').order('name_ru');
      if (error && error.code !== '42P01') throw error;
      if (data) setCategories(data);
    } catch (err) {
      console.error('Error fetching categories:', err);
    }
  }

  // Live connection of boards on the Realtime firmware: one presence-only
  // channel per board. The board tracks itself under its own ID (MAC) and
  // publishes its state there {device, ver, variant, net, rssi_dbm, csq, heap};
  // the panel only listens. rtOnline[machid] = that state, or null when the
  // board is not in the channel.
  const [rtOnline, setRtOnline] = useState({});
  const rtWasOnline = useRef({});
  const rtTopicsKey = markets
    .filter((m) => m.rt?.topic && m.rt?.device_id)
    .map((m) => `${m.id}:${m.rt.topic}:${m.rt.device_id}`)
    .sort()
    .join(',');
  useEffect(() => {
    if (!rtTopicsKey) { setRtOnline({}); return undefined; }
    const channels = rtTopicsKey.split(',').map((entry) => {
      const [machid, topic, deviceId] = entry.split(':');
      const ch = supabase.channel(`dev:${topic}`, { config: { presence: { key: '' } } });
      const update = () => {
        const metas = ch.presenceState()[deviceId];
        const meta = Array.isArray(metas) && metas.length ? metas[metas.length - 1] : null;
        setRtOnline((prev) => ({ ...prev, [machid]: meta }));
        // Seen online, now gone: Presence just fired the board's "last will".
        // Stamp the moment in device_rt (the board's own 15-minute beat can
        // only say "alive at about"), then refresh the lamp tooltip.
        const was = rtWasOnline.current[machid];
        rtWasOnline.current[machid] = !!meta;
        if (was && !meta) {
          supabase.rpc('touch_device_seen', { p_machid: Number(machid) }).then(() => fetchMarkets());
        }
      };
      ch.on('presence', { event: 'sync' }, update);
      // An empty channel may never sync; settle it to "offline" after a beat.
      ch.subscribe((st) => { if (st === 'SUBSCRIBED') setTimeout(update, 2000); });
      return ch;
    });
    return () => { channels.forEach((ch) => supabase.removeChannel(ch)); };
  }, [rtTopicsKey]);

  const rtLiveOf = (m) => (m?.rt ? (m.id in rtOnline ? !!rtOnline[m.id] : null) : undefined);

  // ── Machines: actions ───────────────────────────────────────────────────
  // Superadmin: ask the board to look for a firmware update right now.
  async function checkBoardUpdate(market) {
    try {
      const data = await invokeAdminFn('device-ota', { body: { machid: market.id } });
      const s = data?.status;
      const text = t(`ota_${s}`, { ver: data?.ver ?? '', defaultValue: String(s) });
      return { ok: s === 'current' || s === 'updating', text };
    } catch (e) {
      return { ok: false, text: (e && e.message) || String(e) };
    }
  }

  // Payment-free unlock for refilling. The answer is what the board said, not
  // a guess: opened true/false from a board on the Realtime firmware,
  // nudge:false when nothing answered (offline, or an old MQTT board).
  async function openForService(market) {
    setServiceOpening(market.id);
    try {
      const data = await invokeAdminFn('service-open-request', { body: { machid: market.id } });
      if (data?.opened === true) showToast(t('service_open_opened_for', { seconds: data.seconds }));
      else if (data?.opened === false) showToast(t('service_open_lock_failed'), 'error');
      else showToast(t('service_open_sent_offline'), 'error');
    } catch (e) {
      showToast(`${t('service_open_failed')}: ${(e && e.message) || e}`, 'error');
    } finally {
      setServiceOpening(null);
    }
  }

  function unpairBoard(market) {
    setConfirmAction({
      title: t('pair_board_unpair'),
      subject: `${machineName(market, t)} · ${t('apparatus_no')}${market.id}`,
      message: t('pair_board_unpair_confirm'),
      yesLabel: t('pair_board_unpair'),
      tone: 'danger',
      onYes: async () => {
        const { error } = await supabase.rpc('unpair_device', { p_machid: market.id });
        if (error) { showToast(error.message, 'error'); return; }
        showToast(t('pair_board_unpaired'));
        setPairMarket(null);
        fetchMarkets();
      },
    });
  }

  // Frees a machine whose tablet can't sign itself out — smashed, lost, or
  // already wiped. Without it the machid stays claimed forever and no
  // replacement can pair. Explicit confirmation because the machine keeps
  // working until its next heartbeat and then drops to the pairing screen.
  function releaseTablet(m) {
    setConfirmAction({
      title: t('release_tablet_title'),
      subject: machineName(m, t),
      message: t('release_tablet_hint'),
      yesLabel: t('release_tablet'),
      tone: 'warning',
      onYes: async () => {
        try {
          const { error } = await supabase.rpc('admin_release_machine', { p_machid: m.id });
          if (error) throw error;
          setPairMarket(null);
          await fetchMarkets();
          showToast(t('tablet_released'));
        } catch (err) {
          showToast(`${t('tablet_release_error')}: ${err.message}`, 'error');
        }
      },
    });
  }

  // Renaming is the owner's, from its own machine list, straight to the
  // table: the "Owner manages micromarkets" policy already limits
  // authenticated UPDATEs to owner_id = auth.uid().
  async function renameMarket() {
    const name = (renamingMarket?.name || '').trim();
    if (!name) return showToast(t('device_name_required'), 'error');
    try {
      // Обход заблокированного PATCH — см. patchRow(). Полная строка сюда
      // намеренно не передаётся: список машин читается частичным select, и
      // отправить его целиком значило бы записать обратно свой layout_json,
      // который правит планшет. А без owner_id вставка-призрак не пройдёт RLS.
      const error = await patchRow('micromarkets', renamingMarket.id, { name });
      if (error) throw error;
      setRenamingMarket(null);
      await fetchMarkets();
      if (isSuperadmin && adminDevices) fetchAdminDevices();
      showToast(t('device_renamed'));
    } catch (err) {
      showToast(`${t('device_rename_error')}: ${err.message}`, 'error');
    }
  }

  // ── Inventory ───────────────────────────────────────────────────────────
  const selectedMarket = markets.find(m => String(m.id) === String(selectedMarketId));
  const isScreenMarket = selectedMarket?.kind === 'micromarket_screen';
  const selectedMarketLayout = useMemo(() => parseLayout(selectedMarket?.layout_json), [selectedMarket?.layout_json]);

  async function fetchProducts(marketId) {
    setInventoryLoading(true);
    try {
      // Pull the joined products row so the list can display the canonical
      // SKU image/name even when the inventory row's own image_url is stale.
      const { data, error } = await supabase
        .from('inventory')
        .select('*, products(id,name,image_url,emoji,category_id,volume_ml,is_draft)')
        .eq('micromarket_id', marketId);
      if (error) throw error;
      setProducts(data || []);
    } catch (err) {
      console.error('Error fetching products:', err);
      if (await handleAuthFailure(err)) return;
      showToast(t('inventory_load_error'), 'error');
    } finally {
      setInventoryLoading(false);
    }
  }

  function addStaticProduct() {
    setEditingProduct({
      id: 'new', product_id: null, name: '', price: 0, stock: 0,
      image_url: '', emoji: '', category_id: null,
      // Предлагаем номер сразу: у машины с экраном позиция без номера покупателю
      // недоступна. products здесь — весь инвентарь машины, до фильтров, иначе
      // автономер предложил бы уже занятый.
      motor_id: isScreenMarket ? nextFreeCellNumber(products) : null,
    });
  }

  async function openCatalogPicker() {
    setShowCatalogPicker(true);
    // Пустой список не кэшируем: и сетевая ошибка, и «сессия ещё не поднялась»
    // записывают сюда []. Один такой промах — и пикер до перезагрузки
    // показывал бы «Каталог пуст», хотя товары есть.
    if (pickerProducts == null || pickerProducts.length === 0) {
      try {
        const ownerId = session?.user?.id;
        if (!ownerId) {
          showToast(t('catalog_load_error'), 'error');
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
      } catch {
        showToast(t('catalog_load_error'), 'error');
        setPickerProducts([]);
      }
    }
  }

  /// Apply a chosen catalog product into the inventory edit form: mirror its
  /// display fields onto editingProduct and record the FK.
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

  async function saveProduct() {
    if (!editingProduct.product_id) return showToast(t('pick_product_from_catalog'), 'error');
    if (editingProduct.price == null || editingProduct.price === '') return showToast(t('specify_price'), 'error');

    // Номер ячейки правится только у машины с экраном — см. payload ниже.
    let cellNumber = null;
    if (isScreenMarket) {
      const raw = editingProduct.motor_id;
      if (raw != null && String(raw).trim() !== '') {
        cellNumber = Number(raw);
        if (!Number.isInteger(cellNumber) || cellNumber < CELL_MIN || cellNumber > CELL_MAX) {
          return showToast(t('cell_number_range', { min: CELL_MIN, max: CELL_MAX }), 'error');
        }
        // Обычный случай — «взял номер соседа» — объясняем до похода в базу.
        // Арбитром всё равно остаётся индекс: список в состоянии может отставать.
        const clash = products.find(p =>
          String(p.id) !== String(editingProduct.id) && Number(p.motor_id) === cellNumber);
        if (clash) return showToast(t('cell_number_taken', { n: cellNumber, name: clash.name || '—' }), 'error');
      }
    }

    setSavingProduct(true);
    try {
      // Keep name/image_url/emoji/category_id mirrored on inventory for
      // back-compat with older tablet builds that read those columns directly.
      //
      // motor_type and curtain_mode are never in the payload, and motor_id
      // only for a screen micromarket. For vending motor_id is a physical
      // spiral owned by the tablet's Motor Setup screen; a screen micromarket
      // has no spirals and no tablet — motor_id there is the number written on
      // the shelf, and this form is the only place it can be set.
      const payload = {
        product_id: editingProduct.product_id,
        name: editingProduct.name || '',
        category_id: editingProduct.category_id || null,
        price: Number(editingProduct.price),
        stock: Number(editingProduct.stock) || 0,
        image_url: editingProduct.image_url || null,
        emoji: editingProduct.emoji || null,
      };
      // null здесь — не «не трогать», а «снять номер».
      if (isScreenMarket) payload.motor_id = cellNumber;
      if (editingProduct.id === 'new') {
        const { error } = await supabase.from('inventory').insert({ ...payload, micromarket_id: selectedMarketId });
        if (error) throw error;
      } else {
        const error = await patchRow('inventory', editingProduct.id, payload, {
          micromarket_id: editingProduct.micromarket_id || selectedMarketId,
        });
        if (error) throw error;
      }
      setEditingProduct(null);
      showToast(t('product_saved'));
      fetchProducts(selectedMarketId);
    } catch (err) {
      console.error('Error saving product:', err);
      // 23505 on inventory_market_motor_uk (micromarket_id, motor_id): the
      // number was taken between drawing the list and saving — a second tab,
      // a second operator. The index name is checked explicitly: it is not
      // the only constraint on inventory.
      const cellClash = err?.code === '23505'
        && `${err.message || ''} ${err.details || ''}`.includes('inventory_market_motor_uk');
      if (cellClash) {
        const holder = products.find(p => Number(p.motor_id) === cellNumber);
        showToast(
          holder
            ? t('cell_number_taken', { n: cellNumber, name: holder.name || '—' })
            : t('cell_number_taken_unknown', { n: cellNumber }),
          'error',
        );
        fetchProducts(selectedMarketId);
        return;
      }
      showToast(
        isNetworkFailure(err) ? t('network_save_error') : `${t('save_product_error')}: ${err.message || JSON.stringify(err)}`,
        'error',
      );
    } finally {
      setSavingProduct(false);
    }
  }

  function deleteProduct(p) {
    setConfirmAction({
      title: t('delete_product_title'),
      subject: p.name,
      message: t('delete_product_confirm'),
      yesLabel: t('yes_delete'),
      onYes: async () => {
        try {
          const { error } = await deleteRow('inventory', p.id, 'delete_inventory_item');
          if (error) throw error;
          showToast(t('product_deleted'));
          fetchProducts(selectedMarketId);
        } catch (err) {
          console.error('Delete inventory error:', err);
          showToast(t('delete_error') + ': ' + err.message, 'error');
        }
      },
    });
  }

  async function addCategory({ ru, kz, en }) {
    if (!ru.trim() || !kz.trim() || !en.trim()) { showToast(t('fill_all_languages'), 'error'); return false; }
    try {
      const ownerId = session?.user?.id;
      if (!ownerId) { showToast(t('session_inactive'), 'error'); return false; }
      const { error } = await supabase.from('categories').insert({
        name_ru: ru.trim(), name_kz: kz.trim(), name_en: en.trim(), owner_id: ownerId,
      });
      if (error) throw error;
      fetchCategories();
      showToast(t('category_added'));
      return true;
    } catch (err) {
      showToast(`${t('save_error')}: ${err.message}`, 'error');
      return false;
    }
  }

  function deleteCategory(id) {
    setConfirmAction({
      message: t('delete_category_confirm'),
      onYes: async () => {
        try {
          // supabase-js returns the error instead of throwing it; without this
          // check the panel reported «deleted» even when nothing was.
          const { error } = await deleteRow('categories', id, 'delete_category');
          if (error) throw error;
          fetchCategories();
          showToast(t('category_deleted'));
        } catch (err) {
          console.error('Delete category error:', err);
          showToast(t('category_delete_error'), 'error');
        }
      },
    });
  }

  // ── Catalog ─────────────────────────────────────────────────────────────
  async function fetchCatalogProducts() {
    setCatalogLoading(true);
    try {
      const ownerId = session?.user?.id;
      if (!ownerId) { setCatalogProducts([]); return; }
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
      if (await handleAuthFailure(err)) return;
      showToast(t('catalog_load_error'), 'error');
    } finally {
      setCatalogLoading(false);
    }
  }

  async function saveCatalogProduct() {
    if (!editingCatalog?.name?.trim()) return showToast(t('name_required'), 'error');
    setSavingCatalog(true);
    try {
      const payload = {
        name: editingCatalog.name.trim(),
        image_url: editingCatalog.image_url || null,
        emoji: editingCatalog.emoji || null,
        category_id: editingCatalog.category_id || null,
        volume_ml: editingCatalog.volume_ml === '' || editingCatalog.volume_ml == null ? null : Number(editingCatalog.volume_ml),
        description: editingCatalog.description || null,
        is_draft: !!editingCatalog.is_draft,
      };
      if (editingCatalog.id === 'new') {
        const { error } = await supabase.from('products').insert({
          ...payload,
          owner_id: session?.user?.id || null,
          is_draft: false, // admin-created rows are published immediately
        });
        if (error) throw error;
        showToast(t('product_added'));
      } else {
        const error = await patchRow('products', editingCatalog.id, payload, {
          owner_id: editingCatalog.owner_id || session?.user?.id || null,
          is_archived: !!editingCatalog.is_archived,
        });
        if (error) throw error;
        showToast(t('product_saved'));
      }
      setEditingCatalog(null);
      setPickerProducts(null);
      fetchCatalogProducts();
    } catch (err) {
      console.error('Save catalog error:', err);
      // The dialog stays open with everything typed in — Save can be pressed
      // again without retyping anything.
      showToast(isNetworkFailure(err) ? t('network_save_error') : `${t('save_error')}: ${err.message}`, 'error');
    } finally {
      setSavingCatalog(false);
    }
  }

  async function archiveCatalogProduct(p) {
    try {
      const error = await patchRow('products', p.id, { is_archived: !p.is_archived }, p);
      if (error) throw error;
      showToast(p.is_archived ? t('restored') : t('archived_toast'));
      fetchCatalogProducts();
    } catch (err) {
      showToast(t('save_error') + ': ' + err.message, 'error');
    }
  }

  async function publishDraft(p) {
    try {
      const error = await patchRow('products', p.id, { is_draft: false }, p);
      if (error) throw error;
      showToast(t('published'));
      fetchCatalogProducts();
    } catch (err) {
      showToast(t('save_error') + ': ' + err.message, 'error');
    }
  }

  function deleteCatalogProduct(p) {
    setConfirmAction({
      title: t('delete_product_title'),
      subject: p.name,
      message: t('delete_catalog_confirm_body'),
      onYes: async () => {
        try {
          // `deleted` matters: PostgREST answers 204 both when it deleted the
          // row and when RLS filtered every candidate out.
          const { deleted, error } = await deleteRow('products', p.id, 'delete_product');
          if (error) throw error;
          if (deleted === 0) { showToast(t('delete_catalog_no_rights'), 'error'); return; }
          showToast(t('deleted_toast'));
          fetchCatalogProducts();
        } catch (err) {
          console.error('Delete catalog product error:', err);
          // 23503 = still referenced by inventory (ON DELETE RESTRICT) — the one
          // failure an operator can act on, so name it.
          showToast(err.code === '23503' ? t('delete_catalog_in_use') : `${t('delete_catalog_failed')}: ${err.message}`, 'error');
        }
      },
    });
  }

  const onCatalogFileChange = async (e) => {
    const file = e.target.files?.[0];
    // Clear the input right away: otherwise picking the SAME file again after
    // an error fires no change event and the operator thinks nothing happened.
    e.target.value = '';
    if (!file) return;
    setUploadingImage(true);
    try {
      setCropImageSrc(await prepareForCrop(file, t));
    } catch (err) {
      console.error('Photo pick failed:', err);
      showToast(err.message, 'error');
    } finally {
      setUploadingImage(false);
    }
  };

  // index.json holds only names and hashes; thumbnails are requested by the
  // grid itself, a page at a time, and every one is cached for a year.
  async function openPhotoLibrary() {
    setLibraryOpen(true);
    if (libraryIndex || libraryLoading) return;
    setLibraryLoading(true);
    try {
      const resp = await fetch(`${LIBRARY_BASE}/index.json`);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      setLibraryIndex(await resp.json());
    } catch (err) {
      console.error('Photo library index failed:', err);
      showToast(t('library_error'), 'error');
      setLibraryOpen(false);
    } finally {
      setLibraryLoading(false);
    }
  }

  // image_url points straight at the shared object — nothing is copied, so
  // the tablet's disk cache fetches it once across the fleet. The name is
  // filled in only when the field is still empty.
  function pickFromLibrary(entry) {
    setEditingCatalog(prev => prev ? {
      ...prev,
      image_url: `${LIBRARY_BASE}/${entry.f}.webp`,
      name: prev.name?.trim() ? prev.name : entry.n,
    } : prev);
    setLibraryOpen(false);
  }

  const closeCropper = () => {
    if (cropImageSrc?.startsWith('blob:')) URL.revokeObjectURL(cropImageSrc);
    setCropImageSrc(null);
    setCroppedAreaPixels(null);
    setCrop({ x: 0, y: 0 });
    setZoom(1);
  };

  const handleUploadCrop = async () => {
    if (!cropImageSrc || !croppedAreaPixels) return;
    setUploadingImage(true);
    try {
      const processedBlob = await getCroppedImg(cropImageSrc, croppedAreaPixels, t);
      const filePath = `products/${Math.random().toString(36).substring(2, 15)}.webp`;
      const { error: uploadError } = await supabase.storage
        .from('product-images')
        .upload(filePath, processedBlob, {
          // Random name + upsert:false: each URL is immutable, cache a year.
          cacheControl: '31536000',
          upsert: false,
          contentType: 'image/webp',
        });
      if (uploadError) throw uploadError;
      const { data } = supabase.storage.from('product-images').getPublicUrl(filePath);
      setEditingCatalog(prev => prev ? { ...prev, image_url: data.publicUrl } : prev);
      closeCropper();
    } catch (err) {
      console.error('Error uploading image:', err);
      showToast(`${t('photo_upload_error')}: ${err.message || JSON.stringify(err)}`, 'error');
    } finally {
      setUploadingImage(false);
    }
  };

  // ── Superadmin ──────────────────────────────────────────────────────────
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
      await invokeAdminFn('admin-create-user', { body: { action: 'set_password', user_id: pwdTarget.id, password } });
      setPwdTarget(null);
      showToast(t('password_changed'));
    } catch (err) {
      showToast(`${t('password_change_error')}: ${err.message}`, 'error');
    } finally {
      setUserSaving(false);
    }
  }

  // The function refuses while the account still owns machines — orphaned
  // rows would be invisible in every panel.
  function deleteUser(u) {
    setConfirmAction({
      title: t('delete_user_title'),
      subject: u.email,
      message: t('delete_user_hint'),
      yesLabel: t('yes_delete'),
      onYes: async () => {
        try {
          await invokeAdminFn('admin-create-user', { body: { action: 'delete', user_id: u.id } });
          await fetchUsers();
          showToast(t('user_deleted'));
        } catch (err) {
          if (err.code === 'has_machines') showToast(t('user_err_has_machines', { count: err.details?.machines ?? 0 }), 'error');
          else if (err.code === 'cannot_delete_self') showToast(t('user_err_cannot_delete_self'), 'error');
          else showToast(`${t('user_delete_error')}: ${err.message}`, 'error');
        }
      },
    });
  }

  // The owner is picked in TransferModal; this asks once more, naming both.
  function confirmTransfer(to) {
    const market = transferTarget;
    if (!market || !to) return;
    const from = adminOwners.find((o) => o.id === market.owner_id)?.email ?? t('no_owner');
    setConfirmAction({
      title: t('transfer_confirm_title'),
      subject: `${machineName(market, t)} · ${t('apparatus_no')}${market.id}`,
      message: t('transfer_confirm_msg', { from, to: to.email }),
      tone: 'primary',
      yesLabel: t('transfer_short'),
      onYes: () => transferDevice(to),
    });
  }

  async function transferDevice(to) {
    const market = transferTarget;
    if (!market || !to) return;
    setTransferring(true);
    try {
      const data = await invokeAdminFn('device-admin', {
        body: { action: 'transfer', machid: market.id, owner_id: to.id },
      });
      setTransferTarget(null);
      await Promise.all([fetchAdminDevices(), fetchUsers(), fetchMarkets()]);
      showToast(`${t('device_transferred')} → ${data?.owner_email ?? to.email}`);
    } catch (err) {
      showToast(`${t('device_transfer_error')}: ${err.message}`, 'error');
    } finally {
      setTransferring(false);
    }
  }

  // Change the machine type without enrolling it anew — that used to cost the
  // whole sales history.
  // Asked first: the type decides how the machine takes orders and payment.
  function changeDeviceKind(machid, kind) {
    const m = (adminDevices ?? []).find((d) => d.id === machid) ?? { id: machid };
    if (m.kind === kind) return;
    setConfirmAction({
      title: t('device_kind_change_title'),
      subject: `${machineName(m, t)} · ${t('apparatus_no')}${machid}`,
      message: t('device_kind_change_msg', { from: kindLabel(m.kind, t), to: kindLabel(kind, t) }),
      tone: 'warning',
      yesLabel: t('device_kind_change_yes'),
      onYes: () => applyDeviceKind(machid, kind),
    });
  }

  async function applyDeviceKind(machid, kind) {
    try {
      const data = await invokeAdminFn('device-admin', { body: { action: 'kind', machid, kind } });
      await Promise.all([fetchAdminDevices(), fetchMarkets()]);
      // The unnumbered-cells warning arrives with the success: the type changed,
      // but the screen machine's storefront won't show everything.
      if (data?.warn?.code === 'cells_need_numbers') {
        showToast(t('device_kind_cells_warn', {
          unnumbered: data.warn.unnumbered ?? 0,
          out: data.warn.out_of_range ?? 0,
        }), 'error');
      } else {
        showToast(t('device_kind_changed'));
      }
    } catch (err) {
      showToast(`${t('device_kind_error')}: ${err.message}`, 'error');
    }
  }

  // Delete is destructive: inventory and sales cascade. Always two warnings,
  // and the second wants the machine's number typed in, so a stray click on
  // the bin cannot wipe a machine. Both are passed by then, so the server is
  // told `confirm` straight away.
  function deleteDevice(machid) {
    const m = (adminDevices ?? []).find((d) => d.id === machid) ?? { id: machid };
    const subject = `${machineName(m, t)} · ${t('apparatus_no')}${machid}`;
    const reallyDelete = async () => {
      try {
        await invokeAdminFn('device-admin', { body: { action: 'delete', machid, confirm: true } });
        await Promise.all([fetchAdminDevices(), fetchMarkets()]);
        showToast(t('device_deleted'));
      } catch (err) {
        if (err.code === 'has_pending_orders') { showToast(t('device_del_pending'), 'error'); return; }
        showToast(`${t('device_delete_error')}: ${err.message}`, 'error');
      }
    };
    setConfirmAction({
      title: t('delete_device_title'),
      subject,
      message: t('delete_device_irreversible'),
      warning: t('delete_device_cascade_all'),
      yesLabel: t('continue'),
      // ConfirmDialog closes after onYes; the second step opens right after.
      onYes: () => { setTimeout(() => setConfirmAction({
        title: t('delete_device_sure'),
        subject,
        message: t('delete_device_type_hint', { id: machid }),
        typeToConfirm: String(machid),
        typeLabel: t('delete_device_type_label'),
        yesLabel: t('delete_forever'),
        onYes: reallyDelete,
      }), 0); },
    });
  }

  async function claimDevice() {
    const machid = String(addingDevice?.machid ?? '').trim();
    const secret = String(addingDevice?.secret ?? '').trim();
    if (!/^\d+$/.test(machid)) return showToast(t('device_err_bad_machid'), 'error');
    setDeviceSaving(true);
    try {
      // Secret is optional: omitted, device-claim resolves it from the
      // SmartVend list server-side; typed, it's sent and wins.
      const data = await invokeAdminFn('device-claim', {
        body: { machid: Number(machid), ...(secret ? { secret } : {}), kind: addingDevice.kind || 'vending' },
      });
      setAddingDevice(null);
      await fetchMarkets();
      if (isSuperadmin && adminDevices) fetchAdminDevices();
      showToast(data?.claimed ? t('device_linked') : t('device_added'));
    } catch (err) {
      // A machine that's already assigned can only be moved via transfer —
      // name whoever holds it so it's obvious where to go next.
      if (err.code === 'already_claimed') {
        showToast(t('device_err_already_claimed', { email: err.details?.owner_email || '—' }), 'error');
        return;
      }
      const key = DEVICE_CLAIM_ERRORS[err.code];
      showToast(key ? t(key) : `${t('device_add_error')}: ${err.message}`, 'error');
    } finally {
      setDeviceSaving(false);
    }
  }

  // ── Render ──────────────────────────────────────────────────────────────
  if (!session) {
    return (
      <>
        <Login onError={(msg) => showToast(msg, 'error')} />
        <Toast toast={toast} onClose={() => setToast(null)} />
      </>
    );
  }

  // Any section button, the current one included, leaves an open machine.
  const go = (tab) => () => { if (selectedMarketId != null) closeMarket(); setActiveTab(tab); };
  const navItems = [
    { key: 'sales', icon: LineChart, label: t('sales'), onClick: go('sales') },
    { key: 'inventory', icon: LayoutGrid, label: t('devices'), onClick: go('inventory') },
    { key: 'catalog', icon: Tag, label: t('tab_catalog'), onClick: go('catalog') },
    isSuperadmin && { key: 'users', icon: ShieldCheck, label: t('tab_users'), short: t('tab_users_short'), admin: true, onClick: go('users') },
  ].filter(Boolean);

  return (
    <Shell
      items={navItems}
      active={activeTab}
      email={session.user?.email}
      isSuperadmin={isSuperadmin}
      onLogout={() => supabase.auth.signOut()}
    >
      {activeTab === 'users' && isSuperadmin ? (
        <AdminTab
          users={users}
          usersLoading={usersLoading}
          devices={adminDevices}
          devicesLoading={devicesLoading}
          currentUserId={session.user?.id}
          onRefresh={() => { fetchUsers(); fetchAdminDevices(); }}
          onCreateUser={() => setNewUser({ email: '', password: '', full_name: '' })}
          onAddDevice={() => setAddingDevice({ machid: '', secret: '', kind: 'vending' })}
          onChangePassword={(u) => setPwdTarget({ id: u.id, email: u.email, password: '' })}
          onDeleteUser={deleteUser}
          onTransfer={(m) => setTransferTarget(m)}
          onDeleteDevice={deleteDevice}
          onChangeKind={changeDeviceKind}
        />
      ) : activeTab === 'catalog' ? (
        <CatalogTab
          products={catalogProducts}
          categories={categories}
          filter={catalogFilter}
          setFilter={setCatalogFilter}
          loading={catalogLoading}
          onCreate={() => setEditingCatalog({
            id: 'new', name: '', image_url: '', emoji: '',
            // No category by default: silently filing every new product under
            // whichever sorts first was wrong more often than right.
            category_id: null, volume_ml: '', description: '', is_draft: false, is_archived: false,
          })}
          onEdit={(p) => setEditingCatalog({ ...p })}
          onArchive={archiveCatalogProduct}
          onPublish={publishDraft}
          onDelete={deleteCatalogProduct}
        />
      ) : activeTab === 'inventory' ? (
        selectedMarketId == null ? (
          <MachinesTab
            markets={markets}
            loaded={marketsLoaded}
            rtOnline={rtOnline}
            showToast={showToast}
            onOpen={openMarket}
            onRename={(m) => setRenamingMarket({ id: m.id, name: m.name || '' })}
            onSettings={(m) => setPairMarket(m)}
          />
        ) : (
          <MachineDetail
            key={selectedMarketId}
            market={selectedMarket}
            marketId={selectedMarketId}
            rtLive={rtLiveOf(selectedMarket)}
            rtState={rtOnline[selectedMarketId]}
            products={products}
            loading={inventoryLoading}
            categories={categories}
            layout={selectedMarketLayout}
            onBack={closeMarket}
            onAdd={addStaticProduct}
            onQr={() => setQrModalMarket(selectedMarket || { id: selectedMarketId })}
            onServiceOpen={() => openForService(selectedMarket || { id: selectedMarketId })}
            serviceOpening={String(serviceOpening) === String(selectedMarketId)}
            onSettings={() => setPairMarket(selectedMarket)}
            onCategories={() => setShowCategoryManager(true)}
            onEdit={(p) => setEditingProduct({ ...p })}
            onDelete={deleteProduct}
          />
        )
      ) : (
        <SalesTab markets={markets} categories={categories} showToast={showToast} onConfirm={setConfirmAction} />
      )}

      {/* Dialogs. Order matters only within one layer; see Modal for layers. */}
      {editingProduct && (
        <InventoryEditModal
          value={editingProduct}
          onChange={setEditingProduct}
          isScreen={isScreenMarket}
          layout={selectedMarketLayout}
          categories={categories}
          currency={currencyOf(selectedMarket)}
          onPickCatalog={openCatalogPicker}
          onSave={saveProduct}
          saving={savingProduct}
          onClose={() => setEditingProduct(null)}
        />
      )}
      {showCatalogPicker && (
        <CatalogPickerModal
          products={pickerProducts}
          categories={categories}
          onPick={applyCatalogToInventory}
          onClose={() => setShowCatalogPicker(false)}
        />
      )}
      {showCategoryManager && (
        <CategoryManagerModal
          categories={categories}
          onAdd={addCategory}
          onDelete={deleteCategory}
          onClose={() => setShowCategoryManager(false)}
        />
      )}
      {editingCatalog && (
        <CatalogEditModal
          value={editingCatalog}
          onChange={setEditingCatalog}
          categories={categories}
          uploading={uploadingImage}
          saving={savingCatalog}
          fileInputRef={catalogFileInputRef}
          onFile={onCatalogFileChange}
          onOpenLibrary={openPhotoLibrary}
          onSave={saveCatalogProduct}
          onPublish={() => { publishDraft(editingCatalog); setEditingCatalog(null); }}
          onClose={() => setEditingCatalog(null)}
        />
      )}
      <PhotoLibraryModal
        open={libraryOpen}
        loading={libraryLoading}
        index={libraryIndex}
        onPick={pickFromLibrary}
        onClose={() => setLibraryOpen(false)}
      />
      {cropImageSrc && (
        <CropperModal
          src={cropImageSrc}
          crop={crop}
          zoom={zoom}
          onCrop={setCrop}
          onZoom={setZoom}
          onComplete={setCroppedAreaPixels}
          uploading={uploadingImage}
          canSave={!!croppedAreaPixels}
          onSave={handleUploadCrop}
          onCancel={closeCropper}
        />
      )}
      {pairMarket && (
        <MachineSettingsModal
          market={markets.find((m) => m.id === pairMarket.id) ?? pairMarket}
          rtLive={rtLiveOf(pairMarket) ?? null}
          rtState={rtOnline[pairMarket.id]}
          onClose={() => setPairMarket(null)}
          onUnpair={() => unpairBoard(pairMarket)}
          onRelease={() => releaseTablet(pairMarket)}
          onRefresh={fetchMarkets}
          onCheckUpdate={isSuperadmin ? () => checkBoardUpdate(pairMarket) : undefined}
        />
      )}
      {qrModalMarket && <QrModal market={qrModalMarket} onClose={() => setQrModalMarket(null)} />}
      {renamingMarket && (
        <RenameModal value={renamingMarket} onChange={setRenamingMarket} onSave={renameMarket} onClose={() => setRenamingMarket(null)} />
      )}
      {addingDevice && (
        <AddDeviceModal value={addingDevice} onChange={setAddingDevice} saving={deviceSaving} onSave={claimDevice} onClose={() => setAddingDevice(null)} />
      )}
      {transferTarget && (
        <TransferModal market={transferTarget} owners={adminOwners} busy={transferring} onConfirm={confirmTransfer} onClose={() => setTransferTarget(null)} />
      )}
      {pwdTarget && (
        <PasswordModal value={pwdTarget} onChange={setPwdTarget} saving={userSaving} onSave={changePassword} onClose={() => setPwdTarget(null)} />
      )}
      {newUser && (
        <NewUserModal value={newUser} onChange={setNewUser} saving={userSaving} onSave={createUser} onClose={() => setNewUser(null)} />
      )}

      <ConfirmDialog action={confirmAction} onClose={() => setConfirmAction(null)} />
      <Toast toast={toast} onClose={() => setToast(null)} />
    </Shell>
  );
}
