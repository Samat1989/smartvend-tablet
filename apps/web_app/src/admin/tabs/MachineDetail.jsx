import { useEffect, useState } from 'react';
import { AlertTriangle, ChevronLeft, KeyRound, Layers, Package, Plus, QrCode, Settings, ShoppingBag, Tags } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { Button } from '../ui/Button';
import { Card, KpiCard, PageHeader } from '../ui/Card';
import { ChipGroup } from '../ui/Chips';
import { Banner, SkeletonRows } from '../ui/Feedback';
import { SearchInput, matches } from '../ui/Field';
import { DeviceStatusDot, KindBadge } from '../status/Status';
import { LOW_STOCK, byCellNumber, catName, currencyOf, isLowStock, isOpenShelfKind, machineName, money, motorToSlotLabel } from '../lib/machines';
import { fetchSalesAggregate, periodRange, saleOutcome } from '../lib/sales';
import { CellTag, FlatInventory, InventoryByLayout } from './Inventory';

/**
 * One machine: what it sold today, what is running low, and every position
 * with search and filters. Editing goes through the parent's modals.
 */
export default function MachineDetail({
  market, marketId, rtLive, rtState, products, loading, categories, layout,
  onBack, onAdd, onQr, onServiceOpen, serviceOpening, onSettings, onCategories, onEdit, onDelete,
}) {
  const { t, i18n } = useTranslation();
  const [q, setQ] = useState('');
  const [stock, setStock] = useState('all');
  const [cat, setCat] = useState('all');
  const [sold, setSold] = useState(null);

  const kind = market?.kind;
  const isStatic = kind === 'micromarket_static';
  const isScreen = kind === 'micromarket_screen';
  const openShelf = isOpenShelfKind(kind);
  const currency = currencyOf(market);

  useEffect(() => {
    let alive = true;
    setSold(null);
    fetchSalesAggregate({ market: String(marketId), range: periodRange('day') })
      .then(({ rows }) => {
        if (!alive) return;
        let net = 0, units = 0;
        for (const s of rows) {
          const o = saleOutcome(s);
          if (o.state === 'progress') continue;
          net += o.revenue;
          for (const it of s.sales_items || []) if (it.dispensed !== false) units += it.quantity || 1;
        }
        setSold({ net, units });
      })
      .catch((err) => { console.error('Machine sales today failed:', err); if (alive) setSold({ net: null, units: null }); });
    return () => { alive = false; };
  }, [marketId]);

  const catById = new Map(categories.map((c) => [c.id, c]));
  const catOf = (p) => catName(catById.get(p.category_id), i18n.language);
  const slotOf = (p) => (isScreen ? (p.motor_id == null ? null : Number(p.motor_id)) : motorToSlotLabel(p.motor_id, layout));

  const lowN = products.filter((p) => (p.stock ?? 0) > 0 && isLowStock(p.stock)).length;
  const emptyN = products.filter((p) => (p.stock ?? 0) <= 0).length;
  const units = products.reduce((s, p) => s + Math.max(0, p.stock ?? 0), 0);
  const usedCats = categories.filter((c) => products.some((p) => p.category_id === c.id));

  const filtered = products.filter((p) => {
    if (stock === 'low' && !((p.stock ?? 0) > 0 && isLowStock(p.stock))) return false;
    if (stock === 'empty' && (p.stock ?? 0) > 0) return false;
    if (cat !== 'all' && p.category_id !== cat) return false;
    return matches(q, p.name, p.products?.name, slotOf(p), p.motor_id);
  });
  const filtering = q.trim() !== '' || stock !== 'all' || cat !== 'all';
  const sorted = filtered.slice().sort(isScreen ? byCellNumber : (a, b) => {
    // The operator's per-machine layout decides the order, so the list
    // mirrors the cabinet (MP2404 puts "01" before "11" though motor 99 > 89).
    const la = motorToSlotLabel(a.motor_id, layout);
    const lb = motorToSlotLabel(b.motor_id, layout);
    if (la == null && lb == null) return (a.name || '').localeCompare(b.name || '');
    if (la == null) return 1;
    if (lb == null) return -1;
    return la.localeCompare(lb, undefined, { numeric: true });
  });

  const reset = () => { setQ(''); setStock('all'); setCat('all'); };
  const slotTag = openShelf ? (isScreen ? (p) => <CellTag cell={slotOf(p)} /> : null) : (p) => <CellTag cell={slotOf(p)} />;

  return (
    <div className="flex flex-col gap-6">
      <PageHeader
        before={(
          <nav aria-label={t('breadcrumbs')} className="flex items-center gap-1.5 text-sm">
            <button type="button" onClick={onBack} className="inline-flex items-center gap-1 min-h-9 pr-2 font-semibold text-brand-dark hover:underline focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300 rounded">
              <ChevronLeft size={16} /> {t('devices')}
            </button>
            <span className="text-slate-400" aria-hidden="true">/</span>
            <span className="text-slate-700 truncate" aria-current="page">{machineName(market ?? { id: marketId }, t)}</span>
          </nav>
        )}
        title={machineName(market ?? { id: marketId }, t)}
        subtitle={(
          <span className="flex flex-wrap items-center gap-2">
            <span>{t('apparatus_no')}{marketId}</span>
            {market && <KindBadge kind={kind} />}
            {market && <DeviceStatusDot status={market.status} kind={kind} withLabel rt={rtLive} rtState={rtState} rtRow={market.rt} />}
          </span>
        )}
        actions={(
          <>
            {isStatic && <Button icon={QrCode} onClick={onQr} className="flex-1 sm:flex-none">QR</Button>}
            {/* A tablet machine has no other way to unlock from the panel
                once its lock board is on the Realtime firmware. */}
            {(isStatic || (kind === 'micromarket_tablet' && market?.rt)) && (
              <Button icon={KeyRound} loading={serviceOpening} disabled={serviceOpening} onClick={onServiceOpen} title={t('service_open_title')} className="flex-1 sm:flex-none">
                {t('service_open')}
              </Button>
            )}
            {(isStatic || kind === 'micromarket_tablet') && (
              <Button icon={Settings} onClick={onSettings} className={`flex-1 sm:flex-none ${market?.rt ? '!text-emerald-800 !border-emerald-300' : ''}`}>
                {t('machine_settings_short')}
              </Button>
            )}
            <Button icon={Tags} onClick={onCategories} className="flex-1 sm:flex-none">{t('categories')}</Button>
            {openShelf && <Button variant="primary" icon={Plus} onClick={onAdd} className="flex-1 sm:flex-none">{t('add_product_short')}</Button>}
          </>
        )}
      />

      <div className="grid grid-cols-2 xl:grid-cols-4 gap-3 sm:gap-4">
        <KpiCard accent="blue" icon={Layers} label={t('kpi_positions')} value={loading ? '—' : String(products.length)} note={loading ? null : t('units_in_machine', { count: units })} />
        <KpiCard accent="orange" icon={AlertTriangle} label={t('filter_low')} value={loading ? '—' : String(lowN)} pill={t('low_stock_rule', { n: LOW_STOCK })} pillTone="orange" />
        <KpiCard accent="red" icon={Package} label={t('filter_empty')} value={loading ? '—' : String(emptyN)} />
        <KpiCard accent="green" icon={ShoppingBag} label={t('kpi_sold_today')} value={sold == null ? '—' : sold.net == null ? '!' : `${money(sold.net)} ${currency}`} pill={sold?.units ? t('pcs_n', { count: sold.units }) : null} />
      </div>

      {!openShelf && (
        <Banner tone="info" title={t('new_slots_tablet_only')}>{t('new_slots_tablet_hint')}</Banner>
      )}
      {!openShelf && layout._source === 'fallback' && (
        <Banner tone="warning" title={t('layout_fallback_title')}>{t('layout_fallback_hint')}</Banner>
      )}

      <Card className="p-4 sm:p-5 flex flex-col gap-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 className="text-lg font-bold">{t('cells_and_stock')}</h2>
            <p className="text-sm text-slate-600">{t('cells_and_stock_hint')}</p>
          </div>
          <SearchInput value={q} onChange={setQ} placeholder={t('inventory_search')} className="w-full sm:w-80" />
        </div>
        <ChipGroup
          label={t('filter')}
          value={stock}
          onChange={setStock}
          scroll
          options={[
            { value: 'all', label: t('filter_all'), count: products.length },
            { value: 'low', label: t('filter_low'), count: lowN, tone: 'warning', icon: AlertTriangle },
            { value: 'empty', label: t('filter_empty'), count: emptyN, tone: 'danger' },
          ]}
        />
        {usedCats.length > 0 && (
          <ChipGroup
            label={t('categories')}
            value={cat}
            onChange={setCat}
            scroll
            options={[
              { value: 'all', label: t('all_categories') },
              ...usedCats.map((c) => ({ value: c.id, label: catName(c, i18n.language) })),
            ]}
          />
        )}
        {filtering && !loading && (
          <p className="text-sm text-slate-600" role="status">
            {t('found_n', { count: sorted.length })}
            {' · '}
            <button type="button" onClick={reset} className="font-semibold text-brand-dark hover:underline">{t('reset_filters')}</button>
          </p>
        )}

        {loading ? (
          <SkeletonRows rows={6} />
        ) : openShelf || filtering ? (
          <FlatInventory
            items={sorted}
            slotOf={slotTag}
            catOf={catOf}
            currency={currency}
            onEdit={onEdit}
            onDelete={onDelete}
            emptyTitle={filtering ? t('nothing_found') : t('no_products')}
            emptyHint={filtering ? t('nothing_found_hint') : t('no_products_hint')}
          />
        ) : (
          <InventoryByLayout products={sorted} layout={layout} catOf={catOf} currency={currency} onEdit={onEdit} onDelete={onDelete} />
        )}
      </Card>
    </div>
  );
}
