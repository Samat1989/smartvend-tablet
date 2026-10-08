import { useState } from 'react';
import { Archive, ArchiveRestore, CheckCircle2, Image, Pencil, Plus, Trash2 } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { Button, IconButton } from '../ui/Button';
import { Card, PageHeader, Pill } from '../ui/Card';
import { ChipGroup } from '../ui/Chips';
import { EmptyState, SkeletonRows } from '../ui/Feedback';
import { SearchInput, matches } from '../ui/Field';
import { catName } from '../lib/machines';

// ---- Catalog tab (products table) ----
// Shows the owner's SKU catalog. Each row in `products` is a reusable
// SKU that inventory rows reference via `product_id`. Filters cover
// the three editorial states: active, drafts (auto-created from the
// tablet), and archived.
export default function CatalogTab({ products, categories, filter, setFilter, loading, onCreate, onEdit, onArchive, onPublish, onDelete }) {
  const { t, i18n } = useTranslation();
  const [q, setQ] = useState('');
  const catById = new Map(categories.map((c) => [c.id, c]));
  const catOf = (p) => catName(catById.get(p.category_id), i18n.language);

  const inState = products.filter(p => {
    if (filter === 'drafts') return p.is_draft && !p.is_archived;
    if (filter === 'archived') return p.is_archived;
    return !p.is_draft && !p.is_archived;
  });
  const visible = inState.filter((p) => matches(q, p.name, catOf(p), p.volume_ml));

  const counts = {
    active: products.filter(p => !p.is_draft && !p.is_archived).length,
    drafts: products.filter(p => p.is_draft && !p.is_archived).length,
    archived: products.filter(p => p.is_archived).length,
  };

  return (
    <div className="flex flex-col gap-6">
      <PageHeader
        title={t('catalog_products_title')}
        subtitle={t('catalog_products_subtitle')}
        actions={<Button variant="primary" icon={Plus} onClick={onCreate} className="min-h-11 w-full sm:w-auto">{t('add_product')}</Button>}
      />

      <Card>
        <div className="flex flex-wrap items-center justify-between gap-3 p-4 sm:px-5">
          <SearchInput value={q} onChange={setQ} placeholder={t('catalog_search')} className="w-full sm:w-80" />
          <ChipGroup
            label={t('filter')}
            value={filter}
            onChange={setFilter}
            scroll
            options={[
              { value: 'active', label: t('filter_active'), count: counts.active },
              { value: 'drafts', label: t('filter_drafts'), count: counts.drafts, tone: counts.drafts ? 'warning' : 'default' },
              { value: 'archived', label: t('filter_archived'), count: counts.archived },
            ]}
          />
        </div>

        <div className="px-3 sm:px-4 pb-4">
          {loading ? (
            <SkeletonRows rows={6} />
          ) : visible.length === 0 ? (
            <EmptyState
              icon={Image}
              title={q ? t('nothing_found') : filter === 'drafts' ? t('no_drafts') : filter === 'archived' ? t('archive_empty') : t('catalog_empty')}
              hint={q ? t('nothing_found_hint') : filter === 'active' ? t('catalog_empty_hint') : null}
              action={!q && filter === 'active' ? <Button variant="primary" icon={Plus} onClick={onCreate}>{t('add_product')}</Button> : null}
            />
          ) : (
            <ul className="grid gap-2 md:grid-cols-2">
              {visible.map(p => (
                <li
                  key={p.id}
                  className={`flex items-center gap-3 p-3 rounded-[12px] border transition-all ${
                    p.is_archived ? 'bg-slate-50 border-slate-200' : p.is_draft ? 'bg-amber-50 border-amber-300' : 'bg-white border-slate-200 hover:border-brand hover:shadow-card'
                  }`}
                >
                  <button type="button" onClick={() => onEdit(p)} className="flex items-center gap-3 flex-1 min-w-0 text-left rounded-[8px] focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300">
                    <div className="w-14 h-14 bg-white rounded-[8px] flex items-center justify-center overflow-hidden shrink-0 border border-slate-200">
                      {p.image_url ? (
                        <img src={p.image_url} alt="" loading="lazy" className="w-full h-full object-contain p-1" />
                      ) : p.emoji ? (
                        <span className="text-2xl" aria-hidden="true">{p.emoji}</span>
                      ) : (
                        <Image className="text-slate-300" size={20} aria-hidden="true" />
                      )}
                    </div>
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 flex-wrap">
                        <span className="font-bold text-[15px] text-ink truncate">{p.name}</span>
                        {p.is_draft && <Pill tone="amber">{t('badge_draft')}</Pill>}
                        {p.is_archived && <Pill>{t('badge_archived')}</Pill>}
                      </div>
                      <div className="text-[13px] text-slate-600 truncate mt-0.5">
                        {catOf(p) || t('no_category')}
                        {p.volume_ml != null && ` · ${p.volume_ml} ${t('unit_ml')}`}
                      </div>
                    </div>
                  </button>
                  <div className="flex gap-1 shrink-0">
                    {p.is_draft && <IconButton icon={CheckCircle2} label={t('publish')} tone="success" onClick={() => onPublish(p)} />}
                    <IconButton icon={Pencil} label={t('edit')} className="hidden sm:inline-flex" onClick={() => onEdit(p)} />
                    <IconButton
                      icon={p.is_archived ? ArchiveRestore : Archive}
                      label={p.is_archived ? t('restore') : t('to_archive')}
                      onClick={() => onArchive(p)}
                    />
                    <IconButton icon={Trash2} label={t('delete_forever')} tone="danger" onClick={() => onDelete(p)} />
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      </Card>
    </div>
  );
}
