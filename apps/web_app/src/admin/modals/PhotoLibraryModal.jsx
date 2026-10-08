import { useEffect, useState } from 'react';
import { Loader2 } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import Modal from '../ui/Modal';
import { SearchInput } from '../ui/Field';
import { LIBRARY_BASE, LIBRARY_PAGE } from '../lib/photo';

/**
 * Picker over the shared photo bank.
 *
 * Choosing a picture here writes the shared object's URL onto the product —
 * nothing is copied, so every owner who picks the same photo ends up with the
 * identical `image_url`. That is what lets the tablet's disk cache fetch each
 * picture once for the whole fleet instead of once per operator.
 *
 * The bank is ~3000 entries, so nothing here ever renders all of it: search
 * filters the (name-only) index in memory, and tiles are added a page at a
 * time as the grid is scrolled. Thumbnails are the 200px variant — a full
 * page of them is ~220 KB against ~1.5 MB of the 600px files.
 */
export default function PhotoLibraryModal({ open, loading, index, onPick, onClose }) {
  const { t } = useTranslation();
  const [query, setQuery] = useState('');
  const [shown, setShown] = useState(LIBRARY_PAGE);

  // A new search is a new list; keep the old scroll depth and the operator
  // sees an arbitrary slice of it.
  useEffect(() => { setShown(LIBRARY_PAGE); }, [query]);
  useEffect(() => { if (open) { setQuery(''); setShown(LIBRARY_PAGE); } }, [open]);

  if (!open) return null;

  const q = query.trim().toLowerCase();
  const matches = !index ? [] : (q ? index.filter(e => e.n.toLowerCase().includes(q)) : index);
  const visible = matches.slice(0, shown);

  const onScroll = (e) => {
    const el = e.currentTarget;
    if (el.scrollHeight - el.scrollTop - el.clientHeight < 400) {
      setShown(v => (v >= matches.length ? v : v + LIBRARY_PAGE));
    }
  };

  return (
    <Modal title={t('library_title')} onClose={onClose} size="xl" mobile="full" layer={110} bodyClassName="flex flex-col !overflow-hidden">
      <div className="px-5 py-3 border-b border-slate-200">
        <SearchInput value={query} onChange={setQuery} placeholder={t('library_search')} />
        {index && (
          <p className="text-[13px] font-semibold text-slate-600 mt-2" role="status">
            {t('library_found', { count: matches.length })}
          </p>
        )}
      </div>

      <div className="flex-1 min-h-[50dvh] overflow-y-auto px-5 py-4" onScroll={onScroll}>
        {loading && (
          <div className="flex items-center justify-center gap-2 py-16 text-slate-600 font-semibold">
            <Loader2 className="animate-spin" size={18} /> {t('library_loading')}
          </div>
        )}

        {!loading && index && matches.length === 0 && (
          <p className="text-center text-sm font-semibold text-slate-600 py-16">{t('library_empty')}</p>
        )}

        <div className="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-6 gap-3">
          {visible.map(entry => (
            <button
              key={entry.f + entry.n}
              type="button"
              onClick={() => onPick(entry)}
              title={entry.n}
              className="group flex flex-col gap-1 text-left rounded-[8px] focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300"
            >
              <div className="aspect-square bg-slate-50 rounded-[8px] border border-slate-200 group-hover:border-brand overflow-hidden transition-colors">
                <img
                  src={`${LIBRARY_BASE}/t/${entry.f}.webp`}
                  alt={entry.n}
                  loading="lazy"
                  className="w-full h-full object-contain p-1"
                />
              </div>
              <span className="text-xs font-medium text-slate-700 leading-tight line-clamp-2">
                {entry.n}
              </span>
            </button>
          ))}
        </div>
      </div>
    </Modal>
  );
}
