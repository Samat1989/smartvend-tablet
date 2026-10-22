import React, { useState, useEffect, useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { 
  ShoppingBag, 
  Search, 
  Plus, 
  Minus, 
  ChevronRight, 
  X, 
  Trash2, 
  CheckCircle2,
  Loader2,
  QrCode,
  RefreshCw,
  Package,
  AlertTriangle,
  WifiOff
} from 'lucide-react';
import { useTranslation } from 'react-i18next';
import './i18n';
import { supabase } from './supabaseClient';
import { Logo, LANGS } from './admin/layout/Shell';
import { Button, IconButton } from './admin/ui/Button';
import { ChipGroup } from './admin/ui/Chips';

// The storefront wears the panel's look (MicroVend): the dark brand bar on
// top, blue `brand` for every action, Inter throughout (`admin-ui`). Kaspi
// keeps its own red on the pay button — that one is the payment's brand.
const SIDEBAR_HEX = '#0f1b2d';

function BrandMark({ dark = false, subtitle }) {
  return (
    <div className="flex items-center gap-3 min-w-0">
      <Logo size={36} />
      <div className="flex flex-col min-w-0">
        <span className={`text-[18px] font-extrabold leading-tight ${dark ? 'text-white' : 'text-ink'}`}>MicroVend</span>
        {subtitle && <span className="text-[12px] font-semibold text-slate-400 truncate">{subtitle}</span>}
      </div>
    </div>
  );
}

// Ru → Kk → En on one tap; the label is the language now on screen.
function LangButton() {
  const { i18n } = useTranslation();
  const cur = Math.max(0, LANGS.findIndex((l) => (i18n.resolvedLanguage || i18n.language || 'ru').startsWith(l.code)));
  const next = LANGS[(cur + 1) % LANGS.length];
  return (
    <button
      type="button"
      onClick={() => i18n.changeLanguage(next.code)}
      className="shrink-0 min-h-10 px-3 rounded-[10px] border border-sidebar-line bg-sidebar-raised text-[13px] font-bold text-slate-200 hover:text-white hover:bg-sidebar-active transition-colors focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-400"
    >
      {LANGS[cur].label}
    </button>
  );
}

// −/+ stepper, shared by the product card and the cart rows.
function Stepper({ count, onMinus, onPlus, plusDisabled }) {
  const btn = 'w-9 h-9 rounded-[10px] flex items-center justify-center transition-all active:scale-90 focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300 disabled:opacity-30 disabled:active:scale-100';
  return (
    <div className="flex items-center justify-between gap-1 bg-slate-100 rounded-[12px] p-1" onClick={(e) => e.stopPropagation()}>
      <button type="button" onClick={onMinus} aria-label="−" className={`${btn} bg-white border border-slate-200 text-slate-700`}>
        <Minus size={15} strokeWidth={2.75} />
      </button>
      <span className="min-w-6 text-center font-extrabold text-ink text-[15px]">{count}</span>
      <button type="button" onClick={onPlus} disabled={plusDisabled} aria-label="+" className={`${btn} bg-brand text-white`}>
        <Plus size={15} strokeWidth={2.75} />
      </button>
    </div>
  );
}

// Inline warning box (errors, offline machine) in the panel's rose/amber tones.
function Alert({ tone = 'danger', icon: Icon = AlertTriangle, title, children }) {
  const tones = {
    danger: 'bg-rose-50 border-rose-200 text-rose-800',
    warning: 'bg-amber-50 border-amber-200 text-amber-900',
  };
  return (
    <div role="alert" className={`mb-4 flex gap-3 p-3.5 rounded-[12px] border text-sm ${tones[tone]}`}>
      <Icon size={18} className="shrink-0 mt-0.5" />
      <div className="min-w-0">
        {title && <p className="font-bold">{title}</p>}
        {children}
      </div>
    </div>
  );
}

// Centered full-page message — the storefront's only layout for "there is no
// catalog to draw", shared by the no-QR, bad-QR and load-failed screens.
function FullScreenNotice({ icon: Icon, children }) {
  return (
    <div className="admin-ui min-h-dvh bg-canvas text-ink flex flex-col">
      <header className="bg-sidebar px-4 sm:px-6 h-16 flex items-center justify-between gap-3">
        <BrandMark dark />
        <LangButton />
      </header>
      <div className="flex-1 flex items-center justify-center px-4 py-10">
        <div className="w-full max-w-sm bg-white border border-slate-200 rounded-[12px] shadow-card px-6 py-8 flex flex-col items-center text-center">
          <div className="w-16 h-16 rounded-full bg-brand-soft flex items-center justify-center mb-5">
            <Icon className="text-brand" size={30} />
          </div>
          {children}
        </div>
      </div>
    </div>
  );
}

function App() {
  const { t, i18n } = useTranslation();
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [cart, setCart] = useState({});
  const [isCartOpen, setIsCartOpen] = useState(false);
  const [search, setSearch] = useState('');
  const [selectedCategory, setSelectedCategory] = useState('All');
  const [marketInfo, setMarketInfo] = useState(null);
  const [paymentStatus, setPaymentStatus] = useState('idle');
  const [errorMessage, setErrorMessage] = useState('');
  const [paymentData, setPaymentData] = useState(null);
  // Board on the Realtime firmware didn't answer a ping: no QR is issued for an
  // unreachable fridge, because once SmartVend takes the money only the board
  // can open the door. MQTT-era boards always report online (legacy).
  const [machineOffline, setMachineOffline] = useState(false);
  // Order paid, the server is sending `open` to the board.
  const [doorOpening, setDoorOpening] = useState(false);
  // Why the storefront has nothing to show, when it has nothing to show.
  // null | 'legacy' (pre-2026-06 sticker with the machid in it) | 'unknown'
  // (token matches no machine) | 'network'. Before this existed all three
  // rendered an identical blank grid and the customer had no way to tell a
  // dead sticker from a sold-out fridge.
  const [storefrontError, setStorefrontError] = useState(null);
  const [currentMarketId, setCurrentMarketId] = useState(null);  // machid, for display only (from get_storefront)
  const [marketToken, setMarketToken] = useState(null);          // unguessable QR token — the real key
  const pollingRef = useRef(null);
  const timeoutRef = useRef(null);

  const [categories, setCategories] = useState([]);

  const getCategoryName = (cat) => {
    const lang = (i18n.resolvedLanguage || i18n.language || 'ru').slice(0, 2);
    if (lang === 'kk') return cat.name_kz || cat.name_ru;
    if (lang === 'en') return cat.name_en || cat.name_ru;
    return cat.name_ru;
  };

  // Phone status bar in the brand bar's colour, and the page ground in the
  // panel's canvas (overscroll, scrollbar gutter) while the storefront is
  // open; both come back on leave.
  useEffect(() => {
    const meta = document.querySelector('meta[name="theme-color"]');
    const prevMeta = meta?.getAttribute('content');
    const prevBg = document.body.style.backgroundColor;
    meta?.setAttribute('content', SIDEBAR_HEX);
    document.body.style.backgroundColor = 'var(--color-canvas)';
    return () => {
      if (meta && prevMeta) meta.setAttribute('content', prevMeta);
      document.body.style.backgroundColor = prevBg;
    };
  }, []);

  useEffect(() => {
    // The storefront opens a machine only via the QR token (?t=...). The token
    // is unguessable, so machines can't be enumerated; the machid never appears
    // in the URL. (We also accept ?id=/?marketId= as the token value for
    // flexibility.) With no token we show the "scan QR" screen.
    const params = new URLSearchParams(window.location.search);
    const urlToken = params.get('t') || params.get('id') || params.get('marketId');

    setMarketToken(urlToken || null);

    if (urlToken) fetchStorefront(urlToken);
    fetchCategories();

    const saved = localStorage.getItem('micromart_pending_payment');
    if (saved) {
      try {
        const p = JSON.parse(saved);
        // Only resume a payment that is recent (<15 min) AND for the machine
        // just scanned — otherwise a fresh scan would resurrect an old cart.
        const fresh = p.ts && (Date.now() - p.ts < 15 * 60 * 1000);
        const sameMarket = String(p.token) === String(urlToken);
        if (fresh && sameMarket) {
          setCart(p.savedCart);
          setPaymentStatus('awaiting_payment');
          setIsCartOpen(true);
          startPaymentPolling(p.token, p.orderid);
        } else {
          localStorage.removeItem('micromart_pending_payment');
        }
      } catch (e) {
        localStorage.removeItem('micromart_pending_payment');
      }
    }
  }, [i18n.language]);

  // Баг #4: очищаем interval и timeout при размонтировании компонента
  useEffect(() => {
    return () => {
      if (pollingRef.current) clearInterval(pollingRef.current);
      if (timeoutRef.current) clearTimeout(timeoutRef.current);
    };
  }, []);

  // Idle reset: a static-QR tab can sit backgrounded for hours and come back
  // with a stale cart open and stale stock. When the tab regains focus after
  // being hidden a while, drop the cart, close it, and refresh the catalog —
  // EXCEPT during an active payment (Kaspi -> back to tab), which we preserve.
  useEffect(() => {
    const IDLE_RESET_MS = 3 * 60 * 1000;
    let hiddenAt = null;
    const onVis = () => {
      if (document.visibilityState === 'hidden') {
        hiddenAt = Date.now();
        return;
      }
      const idle = hiddenAt ? Date.now() - hiddenAt : 0;
      hiddenAt = null;
      if (paymentStatus === 'awaiting_payment' || paymentStatus === 'processing') return;
      if (idle > IDLE_RESET_MS) {
        setCart({});
        setIsCartOpen(false);
        setSearch('');
        if (marketToken) fetchStorefront(marketToken);   // fresh stock/prices
      }
    };
    document.addEventListener('visibilitychange', onVis);
    return () => document.removeEventListener('visibilitychange', onVis);
  }, [paymentStatus, marketToken]);

  async function fetchCategories() {
    try {
      const { data, error } = await supabase.from('categories').select('*').order('name_ru');
      if (!error && data) setCategories(data);
    } catch (err) {
      console.error('Error fetching categories:', err);
    }
  }

  // Token-gated storefront load: machine name + inventory via the get_storefront
  // RPC (anon can't read inventory directly anymore). Cached by token for a fast
  // perceived rescan.
  async function fetchStorefront(token) {
    const cacheKey = token ? `mm_sf_${token}` : null;
    let hadCache = false;
    if (cacheKey) {
      try {
        const cached = localStorage.getItem(cacheKey);
        if (cached) {
          const sf = JSON.parse(cached);
          setItems(sf.items || []);
          if (sf.machid) setCurrentMarketId(sf.machid);
          if (sf.name) setMarketInfo({ name: sf.name, kind: sf.kind });
          hadCache = true;
        }
      } catch (_) {}
    }
    if (!hadCache) setLoading(true);
    setStorefrontError(null);
    try {
      const { data, error } = await supabase.rpc('get_storefront', { p_token: token });
      if (error) throw error;
      if (!data) {
        // The RPC matches on qr_token only. An all-digits token is a machid,
        // i.e. a sticker printed before the token migration (2026-06-05) when
        // the QR still carried `?id=<machid>` — worth naming, because the fix
        // is "owner reprints the label", not "scan again".
        setStorefrontError(/^\d+$/.test(String(token)) ? 'legacy' : 'unknown');
        setItems([]);
        setMarketInfo(null);
        setCurrentMarketId(null);
        if (cacheKey) { try { localStorage.removeItem(cacheKey); } catch (_) {} }
        return;
      }
      setItems(data.items || []);
      checkMachineOnline(token);
      setCurrentMarketId(data.machid);
      setMarketInfo({ name: data.name, kind: data.kind });
      if (cacheKey) { try { localStorage.setItem(cacheKey, JSON.stringify(data)); } catch (_) {} }
    } catch (error) {
      console.error('Error fetching storefront:', error.message);
      // A cached catalog is better than an error screen: the customer can still
      // browse, and checkout re-prices server-side anyway.
      if (!hadCache) setStorefrontError('network');
    } finally {
      setLoading(false);
    }
  }

  const addToCart = (product) => {
    setCart(prev => {
      const existing = prev[product.id];
      if (existing) {
        if (existing.count >= product.stock) return prev;
        return { ...prev, [product.id]: { ...existing, count: existing.count + 1 } };
      }
      return { ...prev, [product.id]: { ...product, count: 1 } };
    });
  };

  const removeFromCart = (productId) => {
    setCart(prev => {
      const existing = prev[productId];
      if (!existing) return prev;
      if (existing.count > 1) return { ...prev, [productId]: { ...existing, count: existing.count - 1 } };
      const { [productId]: _, ...rest } = prev;
      return rest;
    });
  };

  // Courtesy check for the UI only; create-payment pings again before the QR.
  // Any failure here leaves the storefront usable.
  async function checkMachineOnline(token) {
    try {
      const { data } = await supabase.functions.invoke('device-online', { body: { token } });
      setMachineOffline(data?.online === false);
    } catch (_) {}
  }

  const stopPolling = () => {
    if (pollingRef.current) { clearInterval(pollingRef.current); pollingRef.current = null; }
    if (timeoutRef.current) { clearTimeout(timeoutRef.current); timeoutRef.current = null; }
  };

  const startPaymentPolling = (token, orderid) => {
    stopPolling(); // Баг #5: сбрасываем и interval, и timeout перед новым запуском
    // Passive observer: the whole static_qr fleet is ESP32-relay, where the
    // device (via complete-order) is the single capture path — it takes the
    // payment only when the lock opens. The browser must NOT capture; it just
    // reads the status the device set and shows success when the order closes.
    // If the device is offline the order stays pending → SmartVend auto-refunds
    // and we hit the timeout below (no money taken without the lock opening).
    pollingRef.current = setInterval(async () => {
      try {
        const { data: status } = await supabase.rpc('get_order_status', { p_orderid: orderid });
        // Realtime boards: 'paid' while the door is being opened, then
        // 'completed' (opened) or 'door_failed'; 'expired' when the payment
        // window closed unpaid. MQTT boards go straight pending -> completed.
        if (status === 'paid') setDoorOpening(true);
        if (status === 'completed') {
          stopPolling();
          setDoorOpening(false);
          localStorage.removeItem('micromart_pending_payment');
          setPaymentStatus('success');
          setCart({});
          fetchStorefront(token); // refresh stock for this machine
        } else if (status === 'door_failed' || status === 'expired') {
          stopPolling();
          setDoorOpening(false);
          localStorage.removeItem('micromart_pending_payment');
          setPaymentStatus('error');
          setErrorMessage(t(status === 'door_failed' ? 'door_failed_desc' : 'payment_expired_desc'));
          fetchStorefront(token);
        }
      } catch (err) {}
    }, 4000);
    // Баг #5: сохраняем ref таймаута чтобы можно было его сбросить
    timeoutRef.current = setTimeout(() => {
      stopPolling();
      localStorage.removeItem('micromart_pending_payment');
      setPaymentStatus('error');
      setErrorMessage(t('payment_timeout'));
    }, 5 * 60 * 1000);
  };

  const handleCheckout = async () => {
    if (Object.keys(cart).length === 0) return;
    if (!marketToken) {
      setPaymentStatus('error');
      setErrorMessage(t('sf_no_machine'));
      return;
    }
    setPaymentStatus('processing');
    try {
      const items = Object.values(cart).map(i => ({ id: i.id, count: i.count }));
      const { data, error } = await supabase.functions.invoke('create-payment', {
        body: { token: marketToken, items }
      });
      if (error || !data?.paymentUrl) {
        // Surface the function's real error (e.g. the SmartVend gateway message).
        let reason = error?.message;
        try { reason = (await error?.context?.json())?.error || reason; } catch (_) {}
        if (reason === 'offline') {
          // Not an error screen: the same short «machine is offline» notice the
          // storefront shows up front, with its «check again» link.
          setMachineOffline(true);
          setPaymentStatus('idle');
          return;
        }
        throw new Error(reason || data?.error || 'Payment initialization failed');
      }
      setPaymentData(data);
      setPaymentStatus('awaiting_payment');
      localStorage.setItem('micromart_pending_payment', JSON.stringify({
        token: marketToken, orderid: data.orderid, torderid: data.torderid, savedCart: cart, ts: Date.now()
      }));
      startPaymentPolling(marketToken, data.orderid);
      // Single-tap: go straight to Kaspi from the "Pay" button. Note the gesture
      // has expired during the ~2-3s create-payment round-trip, so on iOS this
      // often lands on the Kaspi web page (QR + pay button) rather than launching
      // the app — an accepted fallback. If the app opens, our tab stays alive
      // underneath (polling + success screen). The awaiting-screen "pay_kaspi"
      // link remains as a manual retry when the user returns to our tab.
      window.location.href = data.paymentUrl;
    } catch (err) {
      setPaymentStatus('error');
      setErrorMessage(err.message);
    }
  };

  const cartTotal = Object.values(cart).reduce((s, i) => s + (i.price * i.count), 0);
  const cartItemCount = Object.values(cart).reduce((s, i) => s + i.count, 0);

  // Split in two: `inStockItems` answers "is the fridge empty?", the filtered
  // list answers "did this search match?". Collapsing them made a sold-out
  // machine and a typo in the search box look identical.
  const inStockItems = items.filter(i => i.stock > 0);
  const filteredItems = items.filter(i => {
    const matchesSearch = i.name.toLowerCase().includes(search.toLowerCase());
    const matchesCategory = selectedCategory === 'All' || i.category_id === selectedCategory;
    return matchesSearch && matchesCategory && i.stock > 0;
  });

  // No QR token in the URL → the storefront was opened without a QR.
  // Don't show any machine's catalog; prompt the customer to scan the code.
  if (!marketToken) {
    return (
      <FullScreenNotice icon={QrCode}>
        <h2 className="text-[19px] font-extrabold text-ink mb-2">MicroVend</h2>
        <p className="text-slate-600 text-[15px] leading-relaxed">
          {t('scan_qr_prompt')}
        </p>
      </FullScreenNotice>
    );
  }

  // The token resolved to nothing (or the load failed outright). Say which of
  // the three it was: a customer staring at an empty grid can't tell a dead
  // sticker from an empty fridge, and neither can the owner they complain to.
  if (storefrontError) {
    const notice = {
      legacy:  { icon: QrCode,     title: 'sf_legacy_qr_title', desc: 'sf_legacy_qr_desc' },
      unknown: { icon: QrCode,     title: 'sf_unknown_title',   desc: 'sf_unknown_desc' },
      network: { icon: RefreshCw,  title: 'sf_load_failed',     desc: 'sf_load_failed_desc' },
    }[storefrontError];
    return (
      <FullScreenNotice icon={notice.icon}>
        <h2 className="text-[19px] font-extrabold text-ink mb-2">{t(notice.title)}</h2>
        <p className="text-slate-600 text-[15px] leading-relaxed mb-6">{t(notice.desc)}</p>
        <Button variant="primary" size="lg" block icon={RefreshCw} onClick={() => fetchStorefront(marketToken)}>
          {t('sf_retry')}
        </Button>
        {/* The machid is what an owner needs to find the machine in the panel,
            and on a legacy sticker the URL is the only place it survives. */}
        {storefrontError === 'legacy' && (
          <p className="mt-5 text-[12px] font-semibold text-slate-500">
            {t('apparatus_no', { defaultValue: 'Аппарат №' })}{marketToken}
          </p>
        )}
      </FullScreenNotice>
    );
  }

  return (
    <div className="admin-ui min-h-dvh bg-canvas text-ink">
      {/* Brand bar — the panel's sidebar colour and emblem */}
      <header className="fixed top-0 left-0 right-0 z-50 bg-sidebar border-b border-sidebar-line">
        <div className="max-w-6xl mx-auto h-16 px-4 sm:px-6 flex items-center justify-between gap-3">
          <BrandMark
            dark
            subtitle={`${t('apparatus_no', { defaultValue: 'Аппарат №' })}${currentMarketId || '…'}${marketInfo?.name ? ` · ${marketInfo.name}` : ''}`}
          />
          <LangButton />
        </div>
      </header>

      <main className="max-w-6xl mx-auto px-4 sm:px-6 pt-20 sm:pt-24 pb-32">
        {/* Search */}
        <div className="relative max-w-md mb-4">
          <Search className="absolute left-3.5 top-1/2 -translate-y-1/2 text-slate-400 pointer-events-none" size={18} />
          <input
            type="search"
            className="w-full min-h-12 bg-white border border-slate-300 rounded-[10px] pl-11 pr-4 text-[15px] text-ink placeholder:text-slate-400 transition-colors focus:outline-none focus:border-brand focus:ring-3 focus:ring-blue-200"
            placeholder={t('search_placeholder')}
            value={search}
            onChange={e => setSearch(e.target.value)}
          />
        </div>

        {/* Categories */}
        <ChipGroup
          scroll
          className="mb-6"
          label={t('all_items')}
          value={selectedCategory}
          onChange={setSelectedCategory}
          options={[
            { value: 'All', label: t('all_items') },
            ...categories.filter(cat => items.some(i => i.category_id === cat.id)).map(cat => ({ value: cat.id, label: getCategoryName(cat) })),
          ]}
        />

        {/* Nothing to show: name the reason instead of leaving a blank page. */}
        {!loading && filteredItems.length === 0 && (
          <div className="bg-white border border-slate-200 rounded-[12px] shadow-card flex flex-col items-center justify-center text-center py-14 px-6">
            <div className="w-14 h-14 rounded-full bg-slate-100 flex items-center justify-center mb-4">
              <Package className="text-slate-400" size={26} />
            </div>
            <h3 className="font-extrabold text-[17px] text-ink mb-1.5">
              {items.length === 0 ? t('sf_empty_title')
                : inStockItems.length === 0 ? t('sf_sold_out_title')
                : t('nothing_found')}
            </h3>
            <p className="text-slate-600 text-sm max-w-xs">
              {items.length === 0 ? t('sf_empty_desc')
                : inStockItems.length === 0 ? t('sf_sold_out_desc')
                : t('nothing_found_desc')}
            </p>
          </div>
        )}

        {loading && items.length === 0 && (
          <div className="flex justify-center py-20 text-slate-400">
            <Loader2 className="animate-spin" size={28} />
          </div>
        )}

        {/* Product Grid */}
        <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-3 sm:gap-4">
          {filteredItems.map(item => {
            const inCart = cart[item.id];
            const count = inCart?.count || 0;
            const isOutOfStock = (item.stock - count) <= 0;
            const cat = item.category_id && categories.find(c => c.id === item.category_id);

            return (
              <motion.div
                key={item.id}
                layout
                whileTap={{ scale: 0.98 }}
                onClick={() => !isOutOfStock && addToCart(item)}
                className={`bg-white border rounded-[12px] shadow-card p-3 flex flex-col cursor-pointer select-none transition-colors ${count > 0 ? 'border-brand ring-1 ring-brand' : 'border-slate-200 hover:border-slate-300'} ${isOutOfStock && count === 0 ? 'opacity-50 grayscale' : ''}`}
              >
                <div className="aspect-square mb-3 rounded-[10px] overflow-hidden bg-slate-50 flex items-center justify-center">
                  <img className="w-4/5 h-4/5 object-contain" src={item.image_url} alt={item.name} loading="lazy" />
                </div>

                <div className="flex-1 flex flex-col">
                  {cat && (
                    <span className="text-[11px] font-bold text-brand-dark uppercase tracking-[0.08em] mb-0.5 truncate">
                      {getCategoryName(cat)}
                    </span>
                  )}
                  <h4 className="font-semibold text-ink text-[15px] leading-snug line-clamp-2 mb-2">{item.name}</h4>

                  <div className="mt-auto flex items-center justify-between gap-2 mb-2.5">
                    <p className="font-extrabold text-ink text-[18px] leading-none whitespace-nowrap">
                      {item.price.toFixed(0)} <span className="text-[13px] font-bold text-slate-500">₸</span>
                    </p>
                    <span className="inline-flex items-center gap-1 text-[12px] font-semibold bg-slate-100 text-slate-600 px-2 py-0.5 rounded-full whitespace-nowrap">
                      <Package size={12} /> {item.stock - count}
                    </span>
                  </div>

                  {count > 0 ? (
                    <Stepper
                      count={count}
                      onMinus={() => removeFromCart(item.id)}
                      onPlus={() => !isOutOfStock && addToCart(item)}
                      plusDisabled={isOutOfStock}
                    />
                  ) : (
                    <div className="min-h-11 rounded-[10px] bg-brand-soft text-brand-dark font-bold text-sm flex items-center justify-center gap-1.5">
                      <Plus size={16} strokeWidth={2.75} />
                    </div>
                  )}
                </div>
              </motion.div>
            );
          })}
        </div>
      </main>

      {/* Floating Cart Bar */}
      <AnimatePresence>
        {cartItemCount > 0 && paymentStatus !== 'success' && (
          <nav className="fixed bottom-4 left-0 right-0 z-50 flex justify-center px-4 pb-safe">
            <motion.div
              initial={{ y: 100 }} animate={{ y: 0 }} exit={{ y: 100 }}
              className="w-full max-w-md flex gap-2"
            >
              <button
                type="button"
                aria-label={t('search_placeholder')}
                onClick={() => window.scrollTo({ top: 0, behavior: 'smooth' })}
                className="bg-white border border-slate-200 rounded-[12px] w-14 h-14 flex items-center justify-center text-slate-700 shadow-lg"
              >
                <Search size={22} />
              </button>
              <button
                type="button"
                onClick={() => setIsCartOpen(true)}
                className="flex-1 h-14 bg-brand hover:bg-brand-dark text-white rounded-[12px] px-5 flex items-center justify-between shadow-lg shadow-brand/30 active:scale-[0.98] transition-all"
              >
                <span className="flex items-center gap-2">
                  <ShoppingBag size={19} />
                  <span className="font-bold text-[15px]">{cartItemCount} {t('items')}</span>
                </span>
                <span className="flex items-center gap-1.5">
                  <span className="font-extrabold text-[18px]">{cartTotal} ₸</span>
                  <ChevronRight size={18} />
                </span>
              </button>
            </motion.div>
          </nav>
        )}
      </AnimatePresence>

      {/* Cart sheet */}
      <AnimatePresence>
        {isCartOpen && (
          <>
            <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} onClick={() => setIsCartOpen(false)} className="fixed inset-0 bg-slate-900/50 z-[100]" />
            <motion.div
              role="dialog"
              aria-modal="true"
              aria-label={t('cart')}
              initial={{ y: "100%" }} animate={{ y: 0 }} exit={{ y: "100%" }} transition={{ type: "spring", damping: 25, stiffness: 200 }}
              className="admin-ui fixed bottom-0 left-0 right-0 z-[110] mx-auto max-w-xl bg-canvas rounded-t-[16px] max-h-[90dvh] flex flex-col overflow-hidden shadow-2xl"
            >
              <div className="flex justify-center pt-2.5"><span className="w-10 h-1.5 rounded-full bg-slate-300" /></div>
              <div className="px-4 sm:px-6 pt-3 pb-4 overflow-y-auto no-scrollbar flex-1">
                <div className="flex justify-between items-center gap-3 mb-4">
                  <h2 className="font-extrabold text-[22px] text-ink">{t('cart')}</h2>
                  <div className="flex items-center gap-2">
                    <Button variant="ghost" size="sm" icon={Trash2} onClick={() => setCart({})}>
                      {t('clear_cart')}
                    </Button>
                    <IconButton icon={X} label={t('close', { defaultValue: 'Закрыть' })} onClick={() => setIsCartOpen(false)} />
                  </div>
                </div>

                <div className="space-y-2.5">
                  {Object.values(cart).map(item => (
                    <div key={item.id} className="bg-white border border-slate-200 rounded-[12px] shadow-card p-3 flex items-center gap-3">
                      <div className="w-16 h-16 shrink-0 bg-slate-50 rounded-[10px] flex items-center justify-center p-1.5">
                        <img className="w-full h-full object-contain" src={item.image_url} alt={item.name} />
                      </div>
                      <div className="flex-1 min-w-0">
                        <h4 className="font-semibold text-ink text-[15px] truncate">{item.name}</h4>
                        <div className="flex items-center justify-between gap-2 mt-1.5">
                          <Stepper
                            count={item.count}
                            onMinus={() => removeFromCart(item.id)}
                            onPlus={() => addToCart(item)}
                            plusDisabled={(items.find(i => i.id === item.id)?.stock ?? 0) <= item.count}
                          />
                          <span className="font-extrabold text-ink whitespace-nowrap">{item.price * item.count} ₸</span>
                        </div>
                      </div>
                    </div>
                  ))}
                </div>

                {paymentStatus === 'awaiting_payment' && paymentData && (
                  <div className="mt-4 p-5 bg-white border border-slate-200 rounded-[12px] shadow-card flex flex-col items-center text-center">
                    {/* The actual app-open must be a real user tap: mobile OSes
                        (esp. iOS) won't launch the Kaspi app from a programmatic
                        redirect after the create-payment round-trip — the user
                        gesture has expired. So this big button is the primary CTA. */}
                    <a href={paymentData.paymentUrl} className="w-full min-h-14 flex items-center justify-center bg-[#F14635] hover:bg-[#d93a2a] rounded-[10px] text-white font-extrabold text-[17px] shadow-md shadow-[#F14635]/25 mb-3 active:scale-[0.98] transition-all">
                      {t('pay_kaspi')}
                    </a>
                    <p className="text-slate-600 text-sm mb-4">
                      {t('tap_to_open_kaspi', { defaultValue: 'Нажмите кнопку, чтобы открыть приложение Kaspi и оплатить' })}
                    </p>
                    <div className="inline-flex items-center justify-center gap-2 text-brand-dark bg-brand-soft rounded-full px-3.5 py-1.5 mb-3">
                      <Loader2 className="animate-spin" size={15} />
                      <span className="text-sm font-semibold">{doorOpening ? t('opening_door') : t('waiting_for_payment')}…</span>
                    </div>
                    <Button variant="ghost" size="sm" onClick={() => { stopPolling(); setPaymentStatus('idle'); localStorage.removeItem('micromart_pending_payment'); }}>
                      {t('cancel_payment')}
                    </Button>
                  </div>
                )}
              </div>

              <div className="px-4 sm:px-6 pt-4 bg-white border-t border-slate-200 pb-safe">
                {paymentStatus === 'error' && errorMessage && (
                  <Alert>{errorMessage}</Alert>
                )}
                {machineOffline && paymentStatus !== 'error' && (
                  <Alert tone="warning" icon={WifiOff} title={t('machine_offline_title')}>
                    <button type="button" onClick={() => checkMachineOnline(marketToken)} className="mt-1.5 font-bold underline underline-offset-2">
                      {t('machine_offline_retry')}
                    </button>
                  </Alert>
                )}
                <div className="flex justify-between items-center gap-4">
                  <div className="shrink-0">
                    <p className="text-[11px] font-bold text-slate-500 uppercase tracking-[0.12em]">{t('total')}</p>
                    <p className="text-[26px] font-extrabold text-ink leading-tight">{cartTotal} <span className="text-[15px] text-slate-500">₸</span></p>
                  </div>
                  <button
                    type="button"
                    onClick={handleCheckout}
                    disabled={paymentStatus === 'processing' || machineOffline}
                    className="flex-1 h-14 bg-[#F14635] hover:bg-[#d93a2a] text-white rounded-[10px] font-extrabold text-[15px] sm:text-[17px] shadow-md shadow-[#F14635]/25 flex items-center justify-center gap-2 active:scale-[0.98] transition-all disabled:opacity-50 disabled:active:scale-100"
                  >
                    {paymentStatus === 'processing' ? <Loader2 className="animate-spin" /> : (
                      <>
                        <span>{t('pay_in_app')}</span>
                        <img src="/kaspi_logo_final.png" className="w-10 h-10 object-contain" alt="Kaspi" />
                      </>
                    )}
                  </button>
                </div>
              </div>
            </motion.div>
          </>
        )}
      </AnimatePresence>

      {/* Success screen */}
      <AnimatePresence>
        {paymentStatus === 'success' && (
          <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} className="admin-ui fixed inset-0 z-[200] bg-canvas flex flex-col">
            <header className="bg-sidebar px-4 sm:px-6 h-16 flex items-center">
              <BrandMark dark />
            </header>
            <div className="flex-1 flex items-center justify-center px-4 py-10">
              <div className="w-full max-w-sm bg-white border border-slate-200 rounded-[12px] shadow-card px-6 py-8 flex flex-col items-center text-center">
                <div className="w-20 h-20 bg-emerald-50 rounded-full flex items-center justify-center mb-5 text-emerald-600">
                  <CheckCircle2 size={44} />
                </div>
                <h2 className="text-[24px] font-extrabold text-ink mb-2 leading-tight">{t('fuel_locked_in')}</h2>
                <p className="text-slate-600 mb-7 leading-relaxed">{t('grab_and_go_desc')}</p>
                <Button variant="primary" size="lg" block onClick={() => { setPaymentStatus('idle'); setIsCartOpen(false); }}>
                  {t('reload_catalog')}
                </Button>
              </div>
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

export default App;
