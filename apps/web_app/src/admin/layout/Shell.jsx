import { useEffect, useState } from 'react';
import { HelpCircle, LogOut, Menu, X } from 'lucide-react';
import { useTranslation } from 'react-i18next';

export const LANGS = [
  { code: 'ru', label: 'Рус' },
  { code: 'kk', label: 'Қаз' },
  { code: 'en', label: 'Eng' },
];

// The MicroVend emblem (apps/tablet/design/micromart_emblem.png, the same
// mark the tablet shows). `size` is its height; the mark is 241×148, so it
// runs about 1.6 times wider. Decorative: the name is always written next to it.
export function Logo({ size = 40 }) {
  return (
    <img
      src="/brand/microvend-emblem.png"
      alt=""
      aria-hidden="true"
      className="shrink-0 select-none"
      style={{ height: Math.round(size * 0.8), width: 'auto' }}
      draggable={false}
    />
  );
}

function Brand({ compact = false }) {
  const { t } = useTranslation();
  return (
    <div className="flex items-center gap-3 min-w-0">
      <Logo size={compact ? 32 : 40} />
      <div className="flex flex-col min-w-0">
        <span className={`${compact ? 'text-[17px]' : 'text-[19px]'} font-extrabold text-white leading-tight`}>MicroVend</span>
        {!compact && <span className="text-[11px] font-semibold tracking-[0.12em] uppercase text-slate-400 truncate">{t('admin_panel')}</span>}
      </div>
    </div>
  );
}

// One entry of the side menu; the drawer on a phone reuses it.
function NavItem({ item, active, onClick }) {
  const Icon = item.icon;
  const on = active === item.key;
  const accent = item.admin ? 'shadow-[inset_3px_0_0_#f59e0b]' : 'shadow-[inset_3px_0_0_#3b82f6]';
  return (
    <button
      type="button"
      onClick={onClick}
      aria-current={on ? 'page' : undefined}
      className={`w-full flex items-center gap-3 min-h-12 px-3.5 rounded-[10px] text-[15px] text-left transition-colors focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-400 ${on ? `bg-sidebar-active text-white font-bold ${accent}` : 'text-slate-300 font-medium hover:bg-sidebar-raised hover:text-white'}`}
    >
      <Icon size={20} className={on ? (item.admin ? 'text-amber-400' : 'text-blue-400') : item.admin ? 'text-amber-400' : ''} />
      <span className="truncate">{item.label}</span>
    </button>
  );
}

function NavList({ items, active, onPick }) {
  const { t } = useTranslation();
  const main = items.filter((i) => !i.admin);
  const admin = items.filter((i) => i.admin);
  return (
    <nav aria-label={t('nav_sections')} className="flex flex-col gap-1">
      {main.map((i) => <NavItem key={i.key} item={i} active={active} onClick={() => onPick(i)} />)}
      {admin.length > 0 && (
        <>
          <div className="text-[11px] font-bold tracking-[0.12em] uppercase text-slate-400 px-3.5 pt-5 pb-1.5">{t('role_superadmin')}</div>
          {admin.map((i) => <NavItem key={i.key} item={i} active={active} onClick={() => onPick(i)} />)}
        </>
      )}
    </nav>
  );
}

function Extras({ onNavigate }) {
  const { t, i18n } = useTranslation();
  const lang = i18n.resolvedLanguage || i18n.language;
  return (
    <div className="flex flex-col gap-1">
      <div className="h-px bg-sidebar-line mx-1.5 my-3" />
      <a
        href="/help"
        onClick={onNavigate}
        className="flex items-center gap-3 min-h-12 px-3.5 rounded-[10px] text-[15px] font-medium text-slate-300 hover:bg-sidebar-raised hover:text-white focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-400"
      >
        <HelpCircle size={20} /> {t('help_link')}
      </a>
      <div role="group" aria-label={t('language')} className="flex gap-1 mx-1.5 mt-2 p-1 rounded-[10px] bg-sidebar-raised">
        {LANGS.map((l) => (
          <button
            key={l.code}
            type="button"
            aria-pressed={lang === l.code}
            onClick={() => i18n.changeLanguage(l.code)}
            className={`flex-1 min-h-10 rounded-[8px] text-sm transition-colors focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-400 ${lang === l.code ? 'bg-brand text-white font-bold' : 'text-slate-300 font-medium hover:text-white'}`}
          >
            {l.label}
          </button>
        ))}
      </div>
    </div>
  );
}

function UserCard({ email, isSuperadmin, onLogout }) {
  const { t } = useTranslation();
  const initials = (email || '?').slice(0, 2).toUpperCase();
  return (
    <div className="flex items-center gap-3 p-3 rounded-[12px] bg-sidebar-raised">
      <div className={`w-10 h-10 rounded-full flex items-center justify-center text-sm font-extrabold shrink-0 ${isSuperadmin ? 'bg-amber-500 text-ink' : 'bg-brand text-white'}`}>{initials}</div>
      <div className="flex-1 min-w-0">
        <div className="text-sm font-bold text-white truncate" title={email}>{email}</div>
        <div className={`text-xs ${isSuperadmin ? 'text-amber-400' : 'text-slate-400'}`}>{isSuperadmin ? t('role_superadmin') : t('role_owner')}</div>
      </div>
      <button
        type="button"
        onClick={onLogout}
        aria-label={t('logout')}
        title={t('logout')}
        className="w-10 h-10 inline-flex items-center justify-center rounded-[8px] text-slate-400 hover:text-white hover:bg-sidebar-active focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-400"
      >
        <LogOut size={18} />
      </button>
    </div>
  );
}

/**
 * Frame of the panel. Desktop (lg+): a dark side menu with the sections, help,
 * language and the account. Phone and tablet: a dark top bar with a menu
 * button that slides the same menu in, and a bottom bar with the sections —
 * the thumb reaches it without stretching.
 */
export default function Shell({ items, active, email, isSuperadmin, onLogout, children }) {
  const { t } = useTranslation();
  const [drawer, setDrawer] = useState(false);

  useEffect(() => {
    if (!drawer) return undefined;
    const onKey = (e) => { if (e.key === 'Escape') setDrawer(false); };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [drawer]);

  const pick = (item) => { setDrawer(false); item.onClick(); };
  const bottom = items.slice(0, 4);

  return (
    <div className="admin-ui min-h-dvh bg-canvas text-ink lg:flex">
      <a href="#main" className="sr-only focus:not-sr-only focus:fixed focus:top-2 focus:left-2 focus:z-[400] focus:bg-white focus:px-3 focus:py-2 focus:rounded-[8px]">{t('skip_to_content')}</a>

      {/* Desktop side menu */}
      <aside className="hidden lg:flex flex-col w-[264px] shrink-0 bg-sidebar px-4 py-6 sticky top-0 h-dvh overflow-y-auto">
        <div className="px-2 pb-7"><Brand /></div>
        <NavList items={items} active={active} onPick={pick} />
        <Extras />
        <div className="mt-auto pt-6"><UserCard email={email} isSuperadmin={isSuperadmin} onLogout={onLogout} /></div>
      </aside>

      {/* Phone / tablet top bar */}
      <header className="lg:hidden sticky top-0 z-40 flex items-center justify-between gap-3 bg-sidebar px-4 py-2.5 pt-[max(0.625rem,env(safe-area-inset-top))]">
        <Brand compact />
        <button
          type="button"
          onClick={() => setDrawer(true)}
          aria-label={t('menu')}
          aria-expanded={drawer}
          className="w-11 h-11 inline-flex items-center justify-center rounded-[10px] text-white hover:bg-sidebar-raised focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-400"
        >
          <Menu size={22} />
        </button>
      </header>

      {drawer && (
        <div className="lg:hidden fixed inset-0 z-[90]">
          <div className="absolute inset-0 bg-sidebar/60" onClick={() => setDrawer(false)} />
          <div role="dialog" aria-modal="true" aria-label={t('menu')} className="absolute inset-y-0 left-0 w-[86vw] max-w-[320px] bg-sidebar flex flex-col px-3.5 py-4 pb-[max(1.5rem,env(safe-area-inset-bottom))] overflow-y-auto shadow-2xl">
            <div className="flex items-center justify-between px-1.5 pb-5">
              <Brand />
              <button
                type="button"
                autoFocus
                onClick={() => setDrawer(false)}
                aria-label={t('close')}
                className="w-11 h-11 inline-flex items-center justify-center rounded-[10px] text-slate-300 hover:text-white hover:bg-sidebar-raised focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-400"
              >
                <X size={20} />
              </button>
            </div>
            <NavList items={items} active={active} onPick={pick} />
            <Extras onNavigate={() => setDrawer(false)} />
            <div className="mt-auto pt-6"><UserCard email={email} isSuperadmin={isSuperadmin} onLogout={onLogout} /></div>
          </div>
        </div>
      )}

      <main id="main" className="flex-1 min-w-0 px-4 sm:px-6 lg:px-9 py-5 sm:py-7 pb-28 lg:pb-10">
        <div className="max-w-[1320px] mx-auto">{children}</div>
      </main>

      {/* Phone / tablet bottom bar */}
      <nav aria-label={t('nav_sections')} className="lg:hidden fixed bottom-0 inset-x-0 z-40 bg-sidebar flex pb-[env(safe-area-inset-bottom)]">
        {bottom.map((item) => {
          const Icon = item.icon;
          const on = active === item.key;
          return (
            <button
              key={item.key}
              type="button"
              onClick={() => pick(item)}
              aria-current={on ? 'page' : undefined}
              className={`flex-1 min-w-0 flex flex-col items-center justify-center gap-1 h-16 text-xs transition-colors focus-visible:outline-none focus-visible:bg-sidebar-raised ${on ? `text-white font-bold ${item.admin ? 'shadow-[inset_0_3px_0_#f59e0b]' : 'shadow-[inset_0_3px_0_#3b82f6]'}` : 'text-slate-400 font-medium'}`}
            >
              <Icon size={22} className={on ? (item.admin ? 'text-amber-400' : 'text-blue-400') : ''} />
              <span className="truncate max-w-full px-1">{item.short ?? item.label}</span>
            </button>
          );
        })}
      </nav>
    </div>
  );
}
