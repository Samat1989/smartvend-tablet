import React, { useState, useEffect, useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { 
  ShoppingBag, 
  Search, 
  Plus, 
  Minus, 
  ChevronRight, 
  X, 
  Languages, 
  Trash2, 
  CheckCircle2,
  Loader2,
  MapPin,
  Flame,
  Zap,
  Leaf,
  Package
} from 'lucide-react';
import { useTranslation } from 'react-i18next';
import './i18n';
import { supabase } from './supabaseClient';

function App() {
  const { t, i18n } = useTranslation();
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [cart, setCart] = useState({});
  const [isCartOpen, setIsCartOpen] = useState(false);
  const [search, setSearch] = useState('');
  const [selectedCategory, setSelectedCategory] = useState('All');
  const [language, setLanguage] = useState('RU');
  const [marketInfo, setMarketInfo] = useState(null);
  const [paymentStatus, setPaymentStatus] = useState('idle');
  const [errorMessage, setErrorMessage] = useState('');
  const [paymentData, setPaymentData] = useState(null);
  const [currentMarketId, setCurrentMarketId] = useState(null);
  const pollingRef = useRef(null);
  const timeoutRef = useRef(null);

  const [categories, setCategories] = useState([]);

  const getCategoryName = (cat) => {
    const lang = language.toLowerCase();
    if (lang === 'kz') return cat.name_kz || cat.name_ru;
    if (lang === 'en') return cat.name_en || cat.name_ru;
    return cat.name_ru;
  };

  useEffect(() => {
    // The storefront only opens a machine when its id comes from the QR
    // (?marketId=...). With no URL id we show the "scan QR" screen and never
    // fall back to a saved/default market.
    const params = new URLSearchParams(window.location.search);
    const urlMarketId = params.get('id') || params.get('marketId');

    setCurrentMarketId(urlMarketId || null);

    if (urlMarketId) {
      fetchMarketInfo(urlMarketId);
      fetchItems(urlMarketId);
    }
    fetchCategories();
    
    const lng = i18n.language.toUpperCase().substring(0, 2);
    setLanguage(lng === 'KK' ? 'KZ' : lng === 'EN' ? 'EN' : 'RU');

    const saved = localStorage.getItem('micromart_pending_payment');
    if (saved) {
      try {
        const { marketId, orderid, torderid, savedCart } = JSON.parse(saved);
        setCart(savedCart);
        setPaymentStatus('awaiting_payment');
        setIsCartOpen(true);
        startPaymentPolling(marketId, orderid, torderid, savedCart);
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

  async function fetchMarketInfo(id) {
    try {
      const { data } = await supabase
        .from('market_settings')
        .select('*')
        .eq('id', id)
        .single();
      if (data) setMarketInfo(data);
    } catch (err) {
      console.error('Error fetching market info:', err);
    }
  }

  async function fetchCategories() {
    try {
      const { data, error } = await supabase.from('categories').select('*').order('name_ru');
      if (!error && data) setCategories(data);
    } catch (err) {
      console.error('Error fetching categories:', err);
    }
  }

  async function fetchItems(marketId) {
    try {
      setLoading(true);
      let query = supabase.from('inventory').select('*').order('name');
      if (marketId) query = query.eq('micromarket_id', marketId);
      
      const { data, error } = await query;
      if (error) throw error;
      setItems(data || []);
    } catch (error) {
      console.error('Error fetching items:', error.message);
    } finally {
      setLoading(false);
    }
  }

  const toggleLanguage = () => {
    const languages = ['ru', 'kk', 'en'];
    const currentIndex = languages.findIndex(l => i18n.language.startsWith(l));
    i18n.changeLanguage(languages[(currentIndex + 1) % languages.length]);
  };

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

  const stopPolling = () => {
    if (pollingRef.current) { clearInterval(pollingRef.current); pollingRef.current = null; }
    if (timeoutRef.current) { clearTimeout(timeoutRef.current); timeoutRef.current = null; }
  };

  const startPaymentPolling = (marketId, orderid, torderid, currentCart) => {
    stopPolling(); // Баг #5: сбрасываем и interval, и timeout перед новым запуском
    pollingRef.current = setInterval(async () => {
      try {
        const { data } = await supabase.functions.invoke('verify-payment', {
          body: { marketId, orderid, torderid, cartItems: currentCart || cart }
        });
        if (data?.status === 'success') {
          stopPolling();
          localStorage.removeItem('micromart_pending_payment');
          setPaymentStatus('success');
          setCart({});
          fetchItems(marketId); // Баг #2: передаем marketId чтобы загрузить товары нужного маркета
        } else if (data?.status === 'error' || (data?.code && ![1, 2].includes(Number(data.code)))) {
          stopPolling();
          localStorage.removeItem('micromart_pending_payment');
          setPaymentStatus('error');
          setErrorMessage(data.msg || "Payment failed");
        }
      } catch (err) {}
    }, 4000);
    // Баг #5: сохраняем ref таймаута чтобы можно было его сбросить
    timeoutRef.current = setTimeout(() => {
      stopPolling();
      localStorage.removeItem('micromart_pending_payment');
      setPaymentStatus('error');
      setErrorMessage("Timeout");
    }, 5 * 60 * 1000);
  };

  const handleCheckout = async () => {
    if (Object.keys(cart).length === 0) return;
    const marketId = marketInfo?.id || Object.values(cart)[0]?.micromarket_id || 1;
    setPaymentStatus('processing');
    try {
      const { data, error } = await supabase.functions.invoke('create-payment', {
        body: { marketId: marketId.toString(), items: Object.values(cart) }
      });
      if (error || !data?.paymentUrl) throw new Error("Payment initialization failed");
      setPaymentData(data);
      setPaymentStatus('awaiting_payment');
      localStorage.setItem('micromart_pending_payment', JSON.stringify({
        marketId: marketId.toString(), orderid: data.orderid, torderid: data.torderid, savedCart: cart
      }));
      startPaymentPolling(marketId.toString(), data.orderid, data.torderid, cart);
      setTimeout(() => window.location.href = data.paymentUrl, 800);
    } catch (err) {
      setPaymentStatus('error');
      setErrorMessage(err.message);
    }
  };

  const cartTotal = Object.values(cart).reduce((s, i) => s + (i.price * i.count), 0);
  const cartItemCount = Object.values(cart).reduce((s, i) => s + i.count, 0);

  const filteredItems = items.filter(i => {
    const matchesSearch = i.name.toLowerCase().includes(search.toLowerCase());
    const matchesCategory = selectedCategory === 'All' || i.category_id === selectedCategory;
    return matchesSearch && matchesCategory && i.stock > 0;
  });

  const chefsPick = items.find(i => i.stock > 0);

  // No machine id in the URL → the storefront was opened without a QR.
  // Don't show any machine's catalog; prompt the customer to scan the code.
  if (!currentMarketId) {
    return (
      <div className="min-h-screen bg-background text-on-surface flex flex-col items-center justify-center px-6 text-center">
        <div className="w-20 h-20 rounded-full bg-primary/10 flex items-center justify-center mb-6">
          <ShoppingBag className="text-primary" size={36} />
        </div>
        <h1 className="text-primary font-lexend font-black text-2xl mb-3">Micromart</h1>
        <p className="text-on-surface-variant font-lexend max-w-xs">
          {t('scan_qr_prompt', { defaultValue: 'Отсканируйте QR-код на аппарате, чтобы открыть витрину.' })}
        </p>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-background text-on-surface">
      {/* TopAppBar */}
      <header className="fixed top-0 left-0 right-0 z-50 glassmorphism border-b border-surface-container-high/50 h-16 md:h-20 flex items-center justify-between px-5">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-full overflow-hidden bg-primary/10 flex items-center justify-center">
            <ShoppingBag className="text-primary" size={20} />
          </div>
          <div className="flex flex-col">
            <h1 className="text-primary font-lexend font-black text-xl md:text-2xl tracking-tight leading-tight">Micromart</h1>
            <span className="text-[10px] font-lexend font-bold opacity-50 uppercase tracking-wider">
              {t('apparatus_no', { defaultValue: 'Аппарат №' })}{currentMarketId || '...'}
            </span>
          </div>
        </div>
        <div className="flex items-center gap-4">
          <button onClick={toggleLanguage} className="flex items-center gap-1 hover:opacity-70 transition-all">
            <Languages className="text-primary" size={20} />
            <span className="font-lexend font-bold text-xs text-primary uppercase">{language}</span>
          </button>
          <MapPin className="text-primary" size={20} />
        </div>
      </header>

      <main className="max-w-6xl mx-auto px-5 pt-24 md:pt-32 pb-32">
        {/* Hero Section */}
        <div className="mb-12">
          <div className="relative group max-w-md">
            <Search className="absolute left-4 top-1/2 -translate-y-1/2 text-on-surface-variant/50" size={20} />
            <input 
              className="w-full bg-surface-container-low border-none rounded-xl border-b-2 border-transparent focus:ring-0 focus:border-primary py-4 pl-12 pr-4 font-lexend text-on-surface transition-all shadow-sm"
              placeholder={t('search_placeholder')}
              value={search}
              onChange={e => setSearch(e.target.value)}
            />
          </div>
        </div>

        {/* Categories */}
        <div className="flex gap-3 overflow-x-auto no-scrollbar mb-10 pb-2">
          <button
            onClick={() => setSelectedCategory('All')}
            className={`px-6 py-2.5 rounded-full font-lexend font-bold text-sm whitespace-nowrap transition-all ${
              selectedCategory === 'All' ? 'bg-primary text-on-primary scale-105' : 'bg-surface-container-high text-on-surface-variant hover:bg-surface-container-highest'
            }`}
          >
            {t('all_items')}
          </button>
          {categories.map(cat => (
            <button
              key={cat.id}
              onClick={() => setSelectedCategory(cat.id)}
              className={`px-6 py-2.5 rounded-full font-lexend font-bold text-sm whitespace-nowrap transition-all ${
                selectedCategory === cat.id ? 'bg-primary text-on-primary scale-105' : 'bg-surface-container-high text-on-surface-variant hover:bg-surface-container-highest'
              }`}
            >
              {getCategoryName(cat)}
            </button>
          ))}
        </div>

        {/* Product Grid */}
        <div className="grid grid-cols-2 md:grid-cols-4 gap-6">
          {filteredItems.map(item => {
            const inCart = cart[item.id];
            const count = inCart?.count || 0;
            const isOutOfStock = (item.stock - count) <= 0;

            return (
              <motion.div 
                key={item.id} 
                layout
                whileTap={{ scale: 0.98 }}
                onClick={() => !isOutOfStock && addToCart(item)}
                className={`bg-surface-container-lowest rounded-2xl p-4 product-card-shadow flex flex-col relative group cursor-pointer transition-all select-none ${isOutOfStock && count === 0 ? 'opacity-50 grayscale' : ''}`}
              >
                <div className="aspect-square mb-4 rounded-xl overflow-hidden bg-surface-container-low flex items-center justify-center relative shadow-sm">
                  <img className="w-3/4 h-3/4 object-contain group-hover:scale-110 transition-transform duration-500" src={item.image_url} alt={item.name} />
                </div>
                
                <div className="flex-1">
                  {item.category_id && categories.length > 0 && (
                    <span className="text-[9px] font-lexend font-bold text-primary tracking-widest uppercase mb-1 block opacity-60">
                      {getCategoryName(categories.find(c => c.id === item.category_id) || { name_ru: '' })}
                    </span>
                  )}
                  <h4 className="font-lexend font-bold text-on-surface text-base mb-1 truncate">{item.name}</h4>
                  
                  <div className="flex flex-wrap items-center justify-between gap-1 mb-2">
                    <p className="font-lexend font-bold text-primary text-lg leading-none">
                      {item.price.toFixed(0)} <span className="text-xs opacity-50">₸</span>
                    </p>
                    <span className="flex items-center gap-1 font-lexend font-bold text-[9px] bg-surface-container-high text-on-surface-variant px-1.5 py-0.5 rounded-md whitespace-nowrap">
                      <Package size={10} strokeWidth={2.5} /> {item.stock - count}
                    </span>
                  </div>
                  
                  {count > 0 ? (
                    <div className="flex items-center justify-between bg-surface-container-low rounded-full p-1" onClick={(e) => e.stopPropagation()}>
                      <button 
                        onClick={() => removeFromCart(item.id)}
                        className="w-8 h-8 rounded-full flex items-center justify-center bg-white text-on-surface shadow-sm active:scale-90 transition-all"
                      >
                        <Minus size={14} strokeWidth={3} />
                      </button>
                      <span className="font-lexend font-black text-primary text-sm">{count}</span>
                      <button 
                        onClick={() => !isOutOfStock && addToCart(item)}
                        disabled={isOutOfStock}
                        className={`w-8 h-8 rounded-full flex items-center justify-center bg-primary text-white shadow-sm active:scale-90 transition-all disabled:opacity-30`}
                      >
                        <Plus size={14} strokeWidth={3} />
                      </button>
                    </div>
                  ) : (
                    <div className="flex items-center justify-center w-8 h-8 rounded-full bg-primary text-white shadow-sm active:scale-90 transition-all ml-auto">
                      <Plus size={14} strokeWidth={3} />
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
          <nav className="fixed bottom-4 left-0 right-0 z-50 flex justify-center px-5 pb-safe">
            <motion.div 
              initial={{ y: 100 }} animate={{ y: 0 }} exit={{ y: 100 }}
              className="w-full max-w-md flex gap-2"
            >
              <button onClick={() => window.scrollTo({ top: 0, behavior: 'smooth' })} className="bg-surface-container-lowest/90 backdrop-blur-md rounded-full w-14 h-14 flex items-center justify-center text-on-surface shadow-xl border border-white/20">
                <Search size={22} />
              </button>
              <button onClick={() => setIsCartOpen(true)} className="flex-1 signature-gradient text-white rounded-full px-8 flex items-center justify-between shadow-xl shadow-primary/20 active:scale-95 transition-all">
                <div className="flex items-center gap-2">
                  <ShoppingBag size={18} />
                  <span className="font-lexend font-bold text-sm tracking-wide">{cartItemCount} {t('items')}</span>
                </div>
                <div className="flex items-center gap-2">
                  <span className="font-lexend font-extrabold text-lg">{cartTotal} ₸</span>
                  <ChevronRight size={18} />
                </div>
              </button>
            </motion.div>
          </nav>
        )}
      </AnimatePresence>

      {/* Cart Modal */}
      <AnimatePresence>
        {isCartOpen && (
          <>
            <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} onClick={() => setIsCartOpen(false)} className="fixed inset-0 bg-on-surface/40 backdrop-blur-sm z-[100]" />
            <motion.div 
              initial={{ y: "100%" }} animate={{ y: 0 }} exit={{ y: "100%" }} transition={{ type: "spring", damping: 25, stiffness: 200 }}
              className="fixed bottom-0 left-0 right-0 z-[110] bg-surface-bright rounded-t-3xl max-h-[90vh] flex flex-col overflow-hidden shadow-2xl"
            >
              <div className="p-8 overflow-y-auto no-scrollbar flex-1 pb-safe">
                <div className="flex justify-between items-center mb-8">
                  <h2 className="font-lexend font-black text-3xl text-on-surface uppercase tracking-tight">{t('cart')}</h2>
                  <div className="flex items-center gap-2">
                    <button 
                      onClick={() => setCart({})}
                      className="flex items-center gap-1 px-3 py-2 rounded-full bg-surface-container-low text-on-surface-variant text-xs font-lexend font-bold hover:bg-surface-container-high transition-all"
                    >
                      <Trash2 size={13} />
                      <span>{t('clear_cart')}</span>
                    </button>
                    <button onClick={() => setIsCartOpen(false)} className="w-10 h-10 rounded-full bg-surface-container-low flex items-center justify-center"><X size={20} /></button>
                  </div>
                </div>

                <div className="space-y-4">
                  {Object.values(cart).map(item => (
                    <div key={item.id} className="bg-white p-4 rounded-2xl flex items-center gap-4 product-card-shadow">
                      <div className="w-20 h-20 bg-surface-container-low rounded-xl flex items-center justify-center p-2">
                        <img className="w-full h-full object-contain" src={item.image_url} alt={item.name} />
                      </div>
                      <div className="flex-1">
                        <h4 className="font-lexend font-bold text-on-surface">{item.name}</h4>
                        <div className="flex items-center justify-between mt-2">
                          <div className="flex items-center bg-surface-container-low rounded-full p-1">
                            <button onClick={() => removeFromCart(item.id)} className="w-7 h-7 flex items-center justify-center"><Minus size={12} /></button>
                            <span className="px-3 font-lexend font-bold text-xs">{item.count}</span>
                            <button onClick={() => addToCart(item)} disabled={(items.find(i => i.id === item.id)?.stock ?? 0) <= item.count} className="w-7 h-7 flex items-center justify-center disabled:opacity-30"><Plus size={12} /></button>
                          </div>
                          <span className="font-lexend font-black text-primary">{item.price * item.count} ₸</span>
                        </div>
                      </div>
                    </div>
                  ))}
                </div>

                {paymentStatus === 'awaiting_payment' && paymentData && (
                  <div className="mt-8 p-6 bg-white rounded-2xl flex flex-col items-center text-center product-card-shadow border border-primary/5">
                    <Loader2 className="animate-spin text-primary mb-4" size={32} />
                    <p className="font-lexend font-bold text-on-surface mb-6">{t('waiting_for_payment')}...</p>
                    <a href={paymentData.paymentUrl} className="w-full signature-gradient py-4 rounded-xl text-white font-lexend font-bold shadow-lg mb-4">{t('pay_kaspi')}</a>
                    <button onClick={() => { stopPolling(); setPaymentStatus('idle'); localStorage.removeItem('micromart_pending_payment'); }} className="text-on-surface-variant font-bold text-sm uppercase opacity-50">{t('cancel_payment')}</button>
                  </div>
                )}
              </div>

              <div className="p-8 bg-surface-container-lowest border-t border-surface-container-high pb-safe">
                <div className="flex justify-between items-center gap-6">
                  <div>
                    <p className="text-[10px] font-lexend font-bold opacity-40 uppercase tracking-widest">{t('total')}</p>
                    <p className="text-3xl font-lexend font-black text-on-surface">{cartTotal} <span className="text-sm opacity-20">₸</span></p>
                  </div>
                  <button 
                    onClick={handleCheckout} 
                    disabled={paymentStatus === 'processing' || paymentStatus === 'awaiting_payment'}
                    className="flex-1 h-16 bg-[#F14635] text-white rounded-xl font-lexend font-black text-sm md:text-lg shadow-xl shadow-[#F14635]/20 flex items-center justify-center gap-3 active:scale-95 transition-all disabled:opacity-50"
                  >
                    {paymentStatus === 'processing' ? <Loader2 className="animate-spin" /> : (
                      <div className="flex items-center gap-2">
                        <span>{t('pay_in_app')}</span>
                        <img 
                          src="/kaspi_logo_final.png" 
                          className="w-12 h-12 object-contain" 
                          alt="Kaspi"
                        />
                      </div>
                    )}
                  </button>
                </div>
              </div>
            </motion.div>
          </>
        )}
      </AnimatePresence>

      {/* Success Modal */}
      <AnimatePresence>
        {paymentStatus === 'success' && (
          <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} className="fixed inset-0 z-[200] bg-background flex flex-col items-center justify-center p-10 text-center">
            <div className="w-24 h-24 bg-primary/10 rounded-full flex items-center justify-center mb-8 text-primary shadow-kinetic">
              <CheckCircle2 size={48} />
            </div>
            <h2 className="text-4xl font-lexend font-black text-on-surface mb-4 tracking-tight uppercase leading-none">{t('fuel_locked_in')}</h2>
            <p className="text-on-surface-variant mb-10 opacity-70 leading-relaxed">{t('grab_and_go_desc')}</p>
            <button onClick={() => { setPaymentStatus('idle'); setIsCartOpen(false); }} className="signature-gradient w-full max-w-sm py-5 rounded-xl text-white font-lexend font-black text-xl shadow-xl">{t('reload_catalog')}</button>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

export default App;
