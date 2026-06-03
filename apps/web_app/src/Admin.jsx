import React, { useState, useEffect, useRef } from 'react';
import { supabase } from './supabaseClient';
import { Image, Upload, Plus, Minus, Save, Trash2, X, Loader2, Pencil, Receipt, Calendar, ShoppingBag, History, Languages, CheckCircle2, XCircle, AlertTriangle } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import './i18n';
import Cropper from 'react-easy-crop';

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
  const [activeTab, setActiveTab] = useState('inventory'); // 'inventory' | 'catalog' | 'sales'
  const [sales, setSales] = useState([]);
  const [timeFilter, setTimeFilter] = useState('all'); // 'all', 'day', 'week', 'month'
  const [selectedSalesMarket, setSelectedSalesMarket] = useState('all');

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
        showToast('Ошибка загрузки каталога', 'error');
        setPickerProducts([]);
      }
    }
  }

  const showToast = (message, type = 'success') => {
    setToast({ message, type });
    setTimeout(() => setToast(null), 3000);
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
  }, [session, activeTab]);

  useEffect(() => {
    if (session && activeTab === 'catalog') {
      fetchCatalogProducts();
    }
  }, [session, activeTab]);

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
      showToast('Ошибка загрузки каталога', 'error');
    } finally {
      setLoading(false);
    }
  }

  async function saveCatalogProduct() {
    if (!editingCatalog?.name?.trim()) return showToast('Название обязательно', 'error');
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
        showToast('Товар добавлен');
      } else {
        const { error } = await supabase
          .from('products')
          .update(payload)
          .eq('id', editingCatalog.id);
        if (error) throw error;
        showToast('Товар сохранён');
      }
      setEditingCatalog(null);
      fetchCatalogProducts();
    } catch (err) {
      console.error('Save catalog error:', err);
      showToast('Ошибка: ' + err.message, 'error');
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
      showToast(p.is_archived ? 'Восстановлен' : 'В архив');
      fetchCatalogProducts();
    } catch (err) {
      showToast('Ошибка: ' + err.message, 'error');
    }
  }

  async function publishDraft(p) {
    try {
      const { error } = await supabase
        .from('products')
        .update({ is_draft: false })
        .eq('id', p.id);
      if (error) throw error;
      showToast('Опубликован');
      fetchCatalogProducts();
    } catch (err) {
      showToast('Ошибка: ' + err.message, 'error');
    }
  }

  async function deleteCatalogProduct(p) {
    if (!confirm(`Удалить «${p.name}» из каталога? Все слоты на эту запись потеряют ссылку.`)) return;
    try {
      const { error } = await supabase.from('products').delete().eq('id', p.id);
      if (error) throw error;
      showToast('Удалён');
      fetchCatalogProducts();
    } catch (err) {
      showToast('Не удалось удалить — возможно есть связанный inventory. Используйте «В архив».', 'error');
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
      const { data, error } = await supabase
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
      
      if (error) throw error;
      setSales(data || []);
    } catch (err) {
      console.error('Error fetching sales:', err);
      showToast('Ошибка при загрузке продаж', 'error');
    } finally {
      setLoading(false);
    }
  }

  async function fetchMarkets() {
    try {
      const { data, error } = await supabase
        .from('micromarkets')
        .select('id, name, layout_json');
      if (error) throw error;
      setMarkets(data || []);
      if (data?.length > 0) setSelectedMarketId(data[0].id);
    } catch (err) {
      console.error('Error fetching markets:', err);
      alert('Could not load markets');
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
          cacheControl: '3600', 
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
      alert('Ошибка загрузки фото: ' + (err.message || JSON.stringify(err)));
      showToast('Ошибка при загрузке фото', 'error');
    } finally {
      setUploadingImage(false);
    }
  };

  async function addCategory() {
    if (!newCatRu.trim() || !newCatKz.trim() || !newCatEn.trim()) return alert('Заполните все языки');
    try {
      const ownerId = session?.user?.id;
      if (!ownerId) return alert('Сессия не активна');
      const { error } = await supabase.from('categories').insert({
        name_ru: newCatRu.trim(),
        name_kz: newCatKz.trim(),
        name_en: newCatEn.trim(),
        owner_id: ownerId,
      });
      if (error) throw error;
      setNewCatRu(''); setNewCatKz(''); setNewCatEn('');
      fetchCategories();
      showToast('Категория добавлена');
    } catch (err) {
      alert('Ошибка: ' + err.message);
    }
  }

  async function deleteCategory(id) {
    if (!confirm('Точно удалить категорию? (Товары в ней останутся)')) return;
    try {
      await supabase.from('categories').delete().eq('id', id);
      fetchCategories();
      showToast('Категория удалена');
    } catch (err) {
      alert('Ошибка удаления');
    }
  }

  async function saveProduct() {
    if (!editingProduct.product_id) {
      return alert('Выберите товар из каталога');
    }
    if (editingProduct.price == null || editingProduct.price === '') {
      return alert('Укажите цену');
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
      alert('Ошибка сохранения: ' + (err.message || JSON.stringify(err)));
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
      
      showToast('Товар удален');
      setProductToDelete(null);
      fetchProducts(selectedMarketId);
    } catch (err) {
      console.error('Подробная ошибка удаления:', err);
      showToast('Ошибка при удалении: ' + err.message, 'error');
      setProductToDelete(null);
    }
  }

  async function updateStock(product, delta) {
    const newStock = Math.max(0, product.stock + delta);
    setProducts(products.map(p => p.id === product.id ? { ...p, stock: newStock } : p));
    
    try {
      const { error } = await supabase.from('inventory').update({ stock: newStock }).eq('id', product.id);
      if (error) throw error;
      showToast('Остаток сохранен!');
    } catch (err) {
      console.error('Error updating stock:', err);
      showToast('Ошибка сохранения остатка', 'error');
      fetchProducts(selectedMarketId); // Revert on error
    }
  }

  async function updatePrice(product, newPrice) {
    if (newPrice === product.price || newPrice < 0) return;
    setProducts(products.map(p => p.id === product.id ? { ...p, price: newPrice } : p));
    
    try {
      const { error } = await supabase.from('inventory').update({ price: newPrice }).eq('id', product.id);
      if (error) throw error;
      showToast('Цена успешно изменена!');
    } catch (err) {
      console.error('Error updating price:', err);
      showToast('Ошибка сохранения цены', 'error');
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
          <h2 className="text-2xl font-black text-primary mb-6 text-center">Вход в Админку</h2>
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
              <label className="text-xs font-bold opacity-50 ml-2">Пароль</label>
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
                if (error) alert('Ошибка входа: ' + error.message);
                setAuthLoading(false);
              }}
              disabled={authLoading}
              className="w-full bg-primary text-white py-3 rounded-xl font-black shadow-lg shadow-primary/20 active:scale-95 transition-all mt-4 flex justify-center"
            >
              {authLoading ? <Loader2 className="animate-spin" /> : 'Войти'}
            </button>
          </div>
        </div>
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

  const filteredSales = sales.filter(sale => {
    // Фильтр по маркету
    const matchesMarket = selectedSalesMarket === 'all' || sale.micromarket_id.toString() === selectedSalesMarket;
    if (!matchesMarket) return false;

    // Фильтр по времени
    if (timeFilter === 'all') return true;
    const saleDate = new Date(sale.created_at);
    const now = new Date();
    if (timeFilter === 'day') {
      const startOfDay = new Date();
      startOfDay.setHours(0, 0, 0, 0);
      return saleDate >= startOfDay;
    }
    if (timeFilter === 'week') {
      const lastWeek = new Date();
      lastWeek.setDate(lastWeek.getDate() - 7);
      return saleDate >= lastWeek;
    }
    if (timeFilter === 'month') {
      const lastMonth = new Date();
      lastMonth.setMonth(lastMonth.getMonth() - 1);
      return saleDate >= lastMonth;
    }
    return true;
  });

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
            <button
              onClick={() => setActiveTab('inventory')}
              className={`flex-1 sm:flex-none px-2.5 sm:px-4 py-2 sm:py-1.5 rounded-lg font-bold transition-all text-xs ${activeTab === 'inventory' ? 'bg-white text-primary shadow-md' : 'text-slate-600 hover:text-slate-900'}`}
            >
              {t('inventory')}
            </button>
            <button
              onClick={() => setActiveTab('catalog')}
              className={`flex-1 sm:flex-none px-2.5 sm:px-4 py-2 sm:py-1.5 rounded-lg font-bold transition-all text-xs ${activeTab === 'catalog' ? 'bg-white text-primary shadow-md' : 'text-slate-600 hover:text-slate-900'}`}
            >
              Каталог
            </button>
            <button
              onClick={() => setActiveTab('sales')}
              className={`flex-1 sm:flex-none px-2.5 sm:px-4 py-2 sm:py-1.5 rounded-lg font-bold transition-all text-xs ${activeTab === 'sales' ? 'bg-white text-primary shadow-md' : 'text-slate-600 hover:text-slate-900'}`}
            >
              {t('sales')}
            </button>
          </div>
        </div>
        <div className="flex items-center gap-3">
          <button onClick={toggleLanguage} className="flex items-center gap-1 hover:opacity-70 transition-all mr-2">
            <Languages size={16} className="text-slate-400" />
            <span className="text-[10px] font-black uppercase text-slate-400">{i18n.language}</span>
          </button>
          <select 
            className="p-2 text-xs rounded-lg border border-slate-200 bg-slate-50 font-bold focus:ring-2 focus:ring-primary/20 outline-none"
            value={selectedMarketId || ''}
            onChange={(e) => setSelectedMarketId(e.target.value)}
          >
            {markets.map(m => (
              <option key={m.id} value={m.id}>{m.name || `${t('market')} #${m.id}`}</option>
            ))}
          </select>
          <button
            onClick={() => supabase.auth.signOut()}
            className="text-xs font-bold text-on-surface-variant hover:text-red-500 transition-colors ml-4"
          >
            {t('logout')}
          </button>
        </div>
      </header>

      {selectedMarketId && (
        <div className="bg-white rounded-2xl sm:rounded-3xl p-3 sm:p-4 md:p-8 shadow-lg border border-slate-300">
          {activeTab === 'catalog' ? (
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
            <>
              <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4 mb-8">
                <div>
                  <h2 className="text-2xl font-black text-slate-900">{t('inventory')}</h2>
                  <p className="text-[11px] font-bold text-slate-500 uppercase tracking-widest">{t('apparatus_no')}{selectedMarketId}</p>
                </div>
                <div className="flex gap-2 w-full sm:w-auto items-center">
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

              {/* Read-only note — admin can edit existing slots but
                  cannot create new ones. New rows must come from the
                  tablet's service-mode product editor so the operator
                  on-site confirms motor_id maps to a real spiral. */}
              <div className="mb-3 flex items-start gap-2 bg-sky-50 border-2 border-sky-300 rounded-xl p-3">
                <Image size={16} className="text-sky-700 mt-0.5 shrink-0" />
                <div className="text-[12px] text-sky-900 leading-relaxed">
                  <span className="font-black">Добавление новых слотов — только с планшета.</span>
                  <span className="opacity-80"> Здесь можно редактировать цену, остаток и привязку к каталогу для уже существующих ячеек.</span>
                </div>
              </div>

              {selectedMarketLayout._source === 'fallback' && (
                <div className="mb-6 flex items-start gap-2 bg-amber-50 border-2 border-amber-400 rounded-xl p-3">
                  <AlertTriangle size={16} className="text-amber-700 mt-0.5 shrink-0" />
                  <div className="text-[12px] text-amber-900 leading-relaxed">
                    <span className="font-black">Раскладка показывается по умолчанию (заводская 6×6).</span>
                    <span className="opacity-80">{' '}Реальная раскладка с планшета ещё не пришла в БД — перезапустите приложение на планшете или нажмите «Сохранить» в редакторе раскладки.</span>
                  </div>
                </div>
              )}

              {loading && !editingProduct ? (
                <div className="flex justify-center p-20"><Loader2 className="animate-spin text-primary" size={32} /></div>
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
                      { id: 'day', label: t('today') },
                      { id: 'week', label: t('this_week') },
                      { id: 'month', label: t('this_month') },
                      { id: 'all', label: t('all_time') }
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
                  <button onClick={fetchSales} className="p-2.5 bg-slate-100 text-slate-500 rounded-xl hover:bg-primary/5 hover:text-primary transition-all"><History size={18}/></button>
                </div>
              </div>

              {/* Статистика */}
              <div className="grid grid-cols-2 sm:grid-cols-3 gap-4">
                <div className="bg-white border border-slate-100 rounded-2xl p-4 shadow-sm">
                  <div className="text-[9px] font-black text-slate-300 uppercase tracking-widest mb-1">{t('revenue')}</div>
                  <div className="text-xl font-black text-primary">{totalSalesAmount} <span className="text-xs">₸</span></div>
                </div>
                <div className="bg-white border border-slate-100 rounded-2xl p-4 shadow-sm">
                  <div className="text-[9px] font-black text-slate-300 uppercase tracking-widest mb-1">{t('orders')}</div>
                  <div className="text-xl font-black text-slate-800">{filteredSales.length}</div>
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
                    <div key={sale.id} className="bg-white border border-slate-100 rounded-2xl p-4 md:p-6 hover:border-primary/20 transition-all">
                      <div className="flex flex-wrap justify-between items-start gap-4 mb-6">
                        <div className="flex items-center gap-4">
                          <div className="w-10 h-10 bg-slate-50 text-slate-400 rounded-xl flex items-center justify-center">
                            <Receipt size={20} />
                          </div>
                          <div>
                            <div className="text-sm font-black text-slate-800">{sale.micromarkets?.name || `Аппарат #${sale.micromarket_id}`}</div>
                            <div className="flex items-center gap-2 text-[10px] font-bold opacity-30 uppercase tracking-tighter">
                              <Calendar size={10} />
                              {new Date(sale.created_at).toLocaleString('ru-RU')}
                            </div>
                            {inProgress && (
                              <div className="mt-1 inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-amber-50 text-amber-700 text-[10px] font-black uppercase tracking-wider">
                                <AlertTriangle size={11} />
                                {t('sale_in_progress')}
                              </div>
                            )}
                          </div>
                        </div>
                        <div className="text-right">
                          <div className="text-xl font-black text-primary">{sale.amount} ₸</div>
                          {failedItems.length > 0 && (
                            <div className="mt-1 inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-rose-50 text-rose-600 text-[10px] font-black uppercase tracking-wider">
                              <AlertTriangle size={11} />
                              {t('refund_due')}: {refundTotal} ₸
                            </div>
                          )}
                        </div>
                      </div>

                      <div className="space-y-3">
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
                                <div className="font-bold text-slate-600 truncate">{item.inventory?.name || 'Удаленный товар'}</div>
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
                    </div>
                    );
                  })}
                  {sales.length === 0 && (
                    <div className="text-center py-20 bg-slate-50 rounded-3xl border-2 border-dashed border-slate-100">
                      <ShoppingBag size={40} className="mx-auto mb-4 opacity-10" />
                      <p className="font-black opacity-20 text-sm uppercase tracking-widest">Нет данных за период</p>
                    </div>
                  )}
                </div>
              )}
            </div>
          )}
        </div>
      )}

      {/* Модалка редактирования — full-screen на мобильном, центр на десктопе. */}
      {editingProduct && (
        <div className="fixed inset-0 z-50 bg-slate-900/60 backdrop-blur-sm sm:flex sm:items-center sm:justify-center sm:p-4">
          <div className="bg-white w-full h-full sm:h-auto sm:max-w-md sm:rounded-3xl sm:shadow-2xl sm:border-2 sm:border-slate-300 flex flex-col">
            <div className="flex justify-between items-center px-5 py-4 sm:px-6 sm:py-5 border-b-2 border-slate-200 sm:border-b-0">
              <h3 className="font-black text-lg sm:text-xl text-slate-900">{editingProduct.id === 'new' ? 'Новый товар' : 'Редактировать товар'}</h3>
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
                      <span className="text-[9px] uppercase font-black tracking-widest text-emerald-800">Из каталога</span>
                    </div>
                    <h4 className="font-black text-sm truncate text-slate-900">{editingProduct.name}</h4>
                    <span className="text-[10px] font-bold text-slate-600">
                      {categories.find(c => c.id === editingProduct.category_id)?.name_ru || 'Без категории'}
                    </span>
                  </div>
                  <button
                    onClick={openCatalogPicker}
                    title="Сменить товар"
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
                      <div className="font-black text-sm text-indigo-900">Выбрать из каталога</div>
                      <div className="text-[11px] text-indigo-600 font-medium">Подтянуть фото и название из готового товара</div>
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
                    <div className="text-[10px] font-black uppercase tracking-widest text-slate-600">Слот в аппарате</div>
                    <div className="text-xs text-slate-700 leading-snug">
                      Привязка к мотору меняется только с планшета («Настройка моторов»).
                    </div>
                  </div>
                </div>
              )}

              <div className="flex gap-4">
                <div className="flex-1">
                  <label className="text-xs font-bold text-slate-700 ml-2 mb-1 block">Цена (₸)</label>
                  <input
                    type="number"
                    className="w-full p-2.5 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-bold text-slate-900 bg-white"
                    value={editingProduct.price === 0 ? '' : editingProduct.price}
                    onChange={e => setEditingProduct({...editingProduct, price: e.target.value === '' ? 0 : Number(e.target.value)})}
                  />
                </div>
                <div className="flex-1">
                  <label className="text-xs font-bold text-slate-700 ml-2 mb-1 block">Остаток (шт)</label>
                  <input
                    type="number"
                    className="w-full p-2.5 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-bold text-slate-900 bg-white"
                    value={editingProduct.stock === 0 ? '' : editingProduct.stock}
                    onChange={e => setEditingProduct({...editingProduct, stock: e.target.value === '' ? 0 : Number(e.target.value)})}
                  />
                </div>
              </div>

              <div className="text-[11px] text-slate-600 leading-relaxed bg-slate-100 border border-slate-300 rounded-xl p-2.5">
                Чтобы изменить фото или название — отредактируйте товар во вкладке «Каталог».
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
                Сохранить
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
              <h3 className="font-black text-xl">Категории</h3>
              <button onClick={() => setShowCategoryManager(false)} className="p-2 bg-surface-container-low rounded-full"><X size={18} /></button>
            </div>
            
            <div className="flex flex-col gap-2 mb-4">
              <input 
                placeholder="Название (RU)" 
                className="p-2 border border-surface-container-high rounded-xl font-bold text-sm"
                value={newCatRu}
                onChange={e => setNewCatRu(e.target.value)}
              />
              <input 
                placeholder="Название (KZ)" 
                className="p-2 border border-surface-container-high rounded-xl font-bold text-sm"
                value={newCatKz}
                onChange={e => setNewCatKz(e.target.value)}
              />
              <input 
                placeholder="Название (EN)" 
                className="p-2 border border-surface-container-high rounded-xl font-bold text-sm"
                value={newCatEn}
                onChange={e => setNewCatEn(e.target.value)}
              />
              <button onClick={addCategory} className="bg-primary text-white p-2 rounded-xl mt-2 font-bold"><Plus size={20} className="inline mr-2"/> Добавить</button>
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
              {categories.length === 0 && <p className="text-center text-xs opacity-50 py-4">Нет категорий</p>}
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
              Отмена
            </button>
            <button 
              onClick={handleUploadCrop}
              disabled={uploadingImage}
              className="bg-primary text-white px-8 py-3 rounded-xl font-black shadow-lg shadow-primary/20 flex items-center gap-2 active:scale-95 transition-all"
            >
              {uploadingImage ? <Loader2 className="animate-spin" /> : 'Сохранить и загрузить'}
            </button>
          </div>
        </div>
      )}

      {/* Уведомления (Toast) */}
      {toast && (
        <div className={`fixed bottom-6 left-1/2 -translate-x-1/2 px-6 py-3 rounded-full font-bold text-white shadow-xl z-[100] flex items-center gap-2 animate-in fade-in slide-in-from-bottom-5 ${toast.type === 'error' ? 'bg-red-500' : 'bg-primary'}`}>
          {toast.type === 'error' ? <X size={16} /> : <Save size={16} />}
          {toast.message}
        </div>
      )}

      {/* Catalog picker — overlays on top of the inventory edit modal,
          so it's z-[60] (modal is z-50). Filters the SKU list by the
          search box and pops back to the inventory form on selection. */}
      {showCatalogPicker && (
        <div className="fixed inset-0 z-[60] bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-3xl w-full max-w-lg shadow-2xl border-2 border-slate-300 max-h-[85vh] flex flex-col">
            <div className="flex justify-between items-center px-6 pt-6 pb-4 border-b-2 border-slate-200">
              <div>
                <h3 className="font-black text-xl text-slate-900">Каталог</h3>
                <span className="text-[10px] font-bold text-slate-500 uppercase tracking-widest">
                  Выберите готовый товар
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
                placeholder="Поиск…"
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
                    Каталог пуст
                  </p>
                  <p className="text-[11px] text-slate-600 mt-1">
                    Создайте товары во вкладке «Каталог»
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
                            <img src={p.image_url} alt={p.name} className="w-full h-full object-contain p-1" />
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
                              {categories.find(c => c.id === p.category_id)?.name_ru || 'Без категории'}
                            </span>
                            {p.volume_ml != null && (
                              <span className="text-[10px] font-bold text-slate-700 bg-white border border-slate-300 px-1.5 py-0.5 rounded">
                                {p.volume_ml} мл
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
                {editingCatalog.id === 'new' ? 'Новый товар в каталог' : 'Редактировать товар'}
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
                      <span className="text-[10px] font-bold text-primary">Фото</span>
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
                    placeholder="Название (Coca-Cola 0.5)"
                    className="w-full p-2.5 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-bold text-slate-900 bg-white placeholder-slate-400"
                    value={editingCatalog.name || ''}
                    onChange={e => setEditingCatalog({ ...editingCatalog, name: e.target.value })}
                  />
                  <select
                    className="w-full p-2.5 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl text-sm font-bold bg-white text-slate-900"
                    value={editingCatalog.category_id || ''}
                    onChange={e => setEditingCatalog({ ...editingCatalog, category_id: e.target.value || null })}
                  >
                    <option value="">Без категории</option>
                    {categories.map(c => (
                      <option key={c.id} value={c.id}>{c.name_ru}</option>
                    ))}
                  </select>
                </div>
              </div>

              <div className="flex gap-3">
                <div className="flex-1">
                  <label className="text-xs font-bold text-slate-700 ml-2 mb-1 block">Объём (мл)</label>
                  <input
                    type="number"
                    placeholder="500"
                    className="w-full p-2.5 border-2 border-slate-300 focus:border-primary focus:outline-none rounded-xl font-bold text-slate-900 bg-white placeholder-slate-400"
                    value={editingCatalog.volume_ml ?? ''}
                    onChange={e => setEditingCatalog({ ...editingCatalog, volume_ml: e.target.value })}
                  />
                </div>
                <div className="flex-1">
                  <label className="text-xs font-bold text-slate-700 ml-2 mb-1 block">Emoji (fallback)</label>
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
                <label className="text-xs font-bold text-slate-700 ml-2 mb-1 block">Описание (опционально)</label>
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
                    Черновик — создан с планшета. Заполните и опубликуйте.
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
                  Сохранить
                </button>
                {editingCatalog.is_draft && editingCatalog.id !== 'new' && (
                  <button
                    onClick={() => { publishDraft(editingCatalog); setEditingCatalog(null); }}
                    className="w-full bg-emerald-600 text-white py-2.5 rounded-xl font-bold text-sm flex justify-center items-center gap-2 hover:bg-emerald-700 transition-all border-2 border-emerald-600"
                  >
                    <CheckCircle2 size={16} /> Опубликовать
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
            <h3 className="text-xl font-black mb-2 text-on-surface">Удалить товар?</h3>
            <p className="text-sm text-on-surface-variant opacity-70 mb-6">Это действие нельзя будет отменить. Вы уверены?</p>
            <div className="flex gap-3">
              <button 
                onClick={() => setProductToDelete(null)}
                className="flex-1 py-3 px-4 bg-surface-container-high rounded-xl font-bold text-on-surface hover:bg-surface-container-highest transition-all"
              >
                Отмена
              </button>
              <button 
                onClick={confirmDelete}
                className="flex-1 py-3 px-4 bg-red-600 text-white rounded-xl font-bold hover:bg-red-700 shadow-lg shadow-red-200 transition-all active:scale-95"
              >
                Да, удалить
              </button>
            </div>
          </div>
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
          <h2 className="text-2xl font-black text-slate-900">Каталог товаров</h2>
          <p className="text-[11px] font-bold text-slate-500 uppercase tracking-widest">
            SKU для всех ваших аппаратов
          </p>
        </div>
        <button
          onClick={onCreate}
          className="flex items-center justify-center gap-2 bg-primary text-white px-5 py-2.5 rounded-xl font-bold hover:brightness-110 transition-all shadow-lg shadow-primary/30 text-sm border-2 border-primary"
        >
          <Plus size={16} /> Добавить товар
        </button>
      </div>

      <div className="flex gap-2 mb-8 border-b-2 border-slate-200 pb-3 overflow-x-auto no-scrollbar">
        {[
          { id: 'active', label: 'Активные', count: counts.active },
          { id: 'drafts', label: 'Черновики', count: counts.drafts },
          { id: 'archived', label: 'Архив', count: counts.archived },
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
            {filter === 'drafts' ? 'Черновиков нет' : filter === 'archived' ? 'Архив пуст' : 'Каталог пуст'}
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
                  <img src={p.image_url} alt={p.name} className="w-full h-full object-contain p-1" />
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
                      Draft
                    </span>
                  )}
                  {p.is_archived && (
                    <span className="text-[9px] uppercase font-black bg-slate-600 text-white px-1.5 py-0.5 rounded">
                      Архив
                    </span>
                  )}
                </div>
                <div className="flex items-center gap-2 mt-1">
                  <span className="text-[9px] uppercase font-black text-slate-600 tracking-wider px-1.5 py-0.5 bg-white border border-slate-300 rounded">
                    {categories.find(c => c.id === p.category_id)?.name_ru || 'Без категории'}
                  </span>
                  {p.volume_ml != null && (
                    <span className="text-[10px] font-bold text-slate-700 bg-white border border-slate-300 px-1.5 py-0.5 rounded">{p.volume_ml} мл</span>
                  )}
                </div>
              </div>

              <div className="flex gap-1">
                {p.is_draft && (
                  <button
                    onClick={() => onPublish(p)}
                    title="Опубликовать"
                    className="p-2.5 bg-emerald-600 text-white rounded-lg hover:bg-emerald-700 transition-all shadow-sm"
                  >
                    <CheckCircle2 size={14} />
                  </button>
                )}
                <button
                  onClick={() => onEdit(p)}
                  title="Редактировать"
                  className="p-2.5 bg-white border border-slate-300 text-slate-600 rounded-lg hover:bg-primary hover:border-primary hover:text-white transition-all"
                >
                  <Pencil size={14} />
                </button>
                <button
                  onClick={() => onArchive(p)}
                  title={p.is_archived ? 'Восстановить' : 'В архив'}
                  className="p-2.5 bg-white border border-slate-300 text-slate-600 rounded-lg hover:bg-amber-600 hover:border-amber-600 hover:text-white transition-all"
                >
                  {p.is_archived ? <CheckCircle2 size={14} /> : <XCircle size={14} />}
                </button>
                <button
                  onClick={() => onDelete(p)}
                  title="Удалить навсегда"
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
function InventoryByLayout({ products, layout, categories, stockLabel, priceLabel, onEdit, onDelete }) {
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
              Полка {idx + 1}
            </span>
            <span className="text-[11px] font-bold text-slate-600">{shelf.label}</span>
            <span className="text-[10px] font-bold text-slate-400 ml-auto">
              {shelf.slots.length} {shelf.slots.length === 1 ? 'слот' : 'слотов'}
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
              Не привязано к раскладке ({unassigned.length})
            </span>
          </div>
          <div className="space-y-2">
            {unassigned.map(p => (
              <button
                key={p.id}
                onClick={() => onEdit(p)}
                className="w-full flex items-center gap-3 p-2.5 rounded-xl bg-white border-2 border-amber-200 hover:border-amber-500 hover:shadow-md transition-all text-left"
              >
                <div className="w-10 h-10 bg-slate-50 rounded-lg flex items-center justify-center overflow-hidden shrink-0 border border-slate-200">
                  {p.image_url ? (
                    <img src={p.image_url} alt={p.name} className="w-full h-full object-contain p-1" />
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
                      ? 'Без Motor ID — задайте на планшете'
                      : `M${p.motor_id} не входит в текущую раскладку`}
                  </div>
                </div>
                <Pencil size={14} className="text-amber-700" />
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

function InventoryRow({ slot, product, category, stockLabel, priceLabel, onEdit, onDelete }) {
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
            <img src={product.image_url} alt={product.name} className="w-full h-full object-contain p-1" />
          ) : product.emoji ? (
            <span className="text-2xl">{product.emoji}</span>
          ) : (
            <Image className="text-slate-300" size={20} />
          )}
        </div>

        {/* Name + category + (mobile-only) stock × price line */}
        <div className="flex-1 min-w-0">
          {empty ? (
            <div className="italic text-slate-400 font-bold text-sm">Слот пуст</div>
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
                  {category || 'Без категории'}
                </span>
              </div>
              <div className="hidden sm:flex items-center gap-2 mt-1">
                <span className="text-[9px] uppercase font-black text-slate-600 tracking-wider px-1.5 py-0.5 bg-white border border-slate-300 rounded">
                  {category || 'Без категории'}
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
            <span className="hidden sm:block text-[10px] font-bold text-slate-400 italic max-w-[80px] text-right leading-tight">только с планшета</span>
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
