import React, { useEffect, useMemo, useState } from 'react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { Languages, Printer, ArrowLeft, ShieldCheck } from 'lucide-react';
import { supabase } from '../supabaseClient';
import { CHAPTERS, LANGS, TRACKS, DEFAULT_LANG, UI } from './manifest';
import { makeComponents, slugify } from './mdComponents.jsx';

// Каждая глава — отдельный markdown-файл; Vite раскладывает их по языковым
// чанкам, так что страница качает только выбранный язык.
const FILES = import.meta.glob('./content/*/*.md', { query: '?raw', import: 'default' });

function loadChapter(lang, id) {
  const loader = FILES[`./content/${lang}/${id}.md`];
  return loader ? loader() : null;
}

// Куски, которые видит только администратор платформы, размечаются в markdown
// парой <!-- admin-only --> … <!-- /admin-only -->. Всем остальным они
// вырезаются до рендера, а не прячутся стилем: в DOM их нет, и в печать они
// тоже не попадают.
const ADMIN_BLOCK = /^[ \t]*<!--[ \t]*admin-only[ \t]*-->[\s\S]*?<!--[ \t]*\/admin-only[ \t]*-->[ \t]*\n?/gm;
const ADMIN_MARKER = /^[ \t]*<!--[ \t]*\/?admin-only[ \t]*-->[ \t]*\n?/gm;

// Сами маркеры убираются всегда: react-markdown не рендерит сырой HTML, а
// печатает его как текст, и «<!-- admin-only -->» иначе видно на экране.
function applyAdminBlocks(markdown, isAdmin) {
  return isAdmin ? markdown.replace(ADMIN_MARKER, '') : markdown.replace(ADMIN_BLOCK, '');
}

function tocOf(markdown) {
  const out = [];
  for (const line of markdown.split('\n')) {
    const m = /^##\s+(.+?)\s*$/.exec(line);
    if (m) out.push({ text: m[1].replace(/[*`]/g, ''), slug: slugify(m[1].replace(/[*`]/g, '')) });
  }
  return out;
}

export default function Help() {
  const [lang, setLang] = useState(() => {
    const saved = typeof localStorage !== 'undefined' && localStorage.getItem('help_lang');
    if (LANGS.some(l => l.code === saved)) return saved;
    const nav = (navigator.language || '').slice(0, 2);
    return LANGS.some(l => l.code === nav) ? nav : DEFAULT_LANG;
  });
  const [isSuperadmin, setIsSuperadmin] = useState(false);
  // Две ветки инструкции: владельцу и администратору платформы. Печать берёт
  // текущую — владельцу отдают PDF без админских глав.
  const [track, setTrack] = useState('owner');
  const [chapters, setChapters] = useState([]);
  const [loading, setLoading] = useState(true);

  const ui = UI[lang] || UI[DEFAULT_LANG];

  useEffect(() => {
    let alive = true;
    supabase.auth.getSession().then(({ data }) => {
      if (alive) setIsSuperadmin(data?.session?.user?.app_metadata?.is_superadmin === true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, session) => {
      setIsSuperadmin(session?.user?.app_metadata?.is_superadmin === true);
    });
    return () => { alive = false; sub?.subscription?.unsubscribe(); };
  }, []);

  // Админская ветка существует только для суперадмина: не суперадмин не видит ни
  // переключателя, ни её глав.
  const activeTrack = isSuperadmin ? track : 'owner';

  const visible = useMemo(
    () => CHAPTERS.filter(c => c.track === activeTrack),
    [activeTrack],
  );

  useEffect(() => {
    let alive = true;
    setLoading(true);
    Promise.all(
      visible.map(async chapter => {
        const own = loadChapter(lang, chapter.id);
        const text = own ? await own : null;
        if (text != null) {
          return { ...chapter, text: applyAdminBlocks(text, isSuperadmin), fallback: false };
        }
        // Перевода ещё нет — показываем русский, но честно предупреждаем об этом.
        const ru = loadChapter(DEFAULT_LANG, chapter.id);
        const fb = ru ? await ru : '';
        return { ...chapter, text: applyAdminBlocks(fb, isSuperadmin), fallback: true };
      }),
    ).then(list => { if (alive) { setChapters(list); setLoading(false); } });
    return () => { alive = false; };
  }, [lang, visible, isSuperadmin]);

  useEffect(() => {
    localStorage.setItem('help_lang', lang);
    document.documentElement.lang = lang;
  }, [lang]);

  const printedAt = new Date().toLocaleDateString(lang === 'ru' ? 'ru-RU' : lang);

  return (
    <div className="help-root min-h-screen bg-surface-container-lowest text-slate-800">
      <header className="help-chrome sticky top-0 z-30 border-b border-slate-200 bg-white/90 backdrop-blur">
        <div className="mx-auto flex max-w-6xl items-center gap-3 px-4 py-3">
          <a
            href="/admin"
            className="flex items-center gap-1.5 text-xs font-bold text-slate-500 hover:text-primary transition-colors"
          >
            <ArrowLeft size={16} />
            <span className="hidden sm:inline">{ui.toPanel}</span>
          </a>
          <h1 className="flex-1 truncate font-lexend text-base font-black text-primary sm:text-lg">
            {ui.title}
          </h1>
          <div className="flex items-center gap-1">
            <Languages size={16} className="text-slate-400" />
            {LANGS.map(l => (
              <button
                key={l.code}
                onClick={() => setLang(l.code)}
                title={l.name}
                className={`rounded-lg px-2 py-1 text-[11px] font-black transition-all ${
                  l.code === lang ? 'bg-primary text-white' : 'text-slate-400 hover:text-slate-700'
                }`}
              >
                {l.label}
              </button>
            ))}
          </div>
          <button
            onClick={() => window.print()}
            className="ml-1 flex items-center gap-1.5 rounded-xl bg-primary px-3 py-2 text-[11px] font-black text-white transition-all active:scale-95"
          >
            <Printer size={14} />
            <span className="hidden sm:inline">{ui.pdf}</span>
          </button>
        </div>
      </header>

      <div className="mx-auto flex max-w-6xl gap-8 px-4 py-6">
        <nav className="help-chrome hidden w-64 shrink-0 lg:block">
          <div className="sticky top-20 max-h-[calc(100vh-6rem)] overflow-y-auto no-scrollbar pb-10">
            {isSuperadmin && (
              <div className="mb-4 flex flex-col gap-1 rounded-2xl bg-slate-100 p-1">
                {TRACKS.map(tr => (
                  <button
                    key={tr.id}
                    onClick={() => setTrack(tr.id)}
                    className={`rounded-xl px-3 py-2 text-left text-[12px] font-black transition-all ${
                      tr.id === activeTrack ? 'bg-white text-primary shadow-sm' : 'text-slate-500 hover:text-slate-800'
                    }`}
                  >
                    {tr.title[lang] || tr.title.ru}
                  </button>
                ))}
              </div>
            )}
            <div className="mb-2 text-[11px] font-black uppercase tracking-wide text-slate-400">
              {ui.contents}
            </div>
            {chapters.map(ch => (
              <div key={ch.id} className="mb-3">
                <a
                  href={`#${ch.id}`}
                  className="block rounded-lg px-2 py-1 text-sm font-black text-slate-700 hover:bg-slate-100"
                >
                  {ch.title[lang] || ch.title.ru}
                </a>
                <div className="mt-0.5 space-y-0.5 border-l border-slate-200 pl-3 ml-2">
                  {tocOf(ch.text).map(h => (
                    <a
                      key={h.slug}
                      href={`#${ch.id}--${h.slug}`}
                      className="block rounded px-1 py-0.5 text-[12px] leading-5 text-slate-500 hover:text-primary"
                    >
                      {h.text}
                    </a>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </nav>

        <main className="min-w-0 flex-1">
          {isSuperadmin && (
            <div className="help-chrome mb-6 flex gap-1 rounded-2xl bg-slate-100 p-1 lg:hidden">
              {TRACKS.map(tr => (
                <button
                  key={tr.id}
                  onClick={() => setTrack(tr.id)}
                  className={`flex-1 rounded-xl px-3 py-2 text-[12px] font-black transition-all ${
                    tr.id === activeTrack ? 'bg-white text-primary shadow-sm' : 'text-slate-500'
                  }`}
                >
                  {tr.title[lang] || tr.title.ru}
                </button>
              ))}
            </div>
          )}
          {loading && <div className="py-20 text-center text-sm text-slate-400">{ui.loading}</div>}
          {chapters.map(ch => (
            <section key={ch.id} id={ch.id} className="help-chapter mb-14 scroll-mt-20">
              {ch.track === 'admin' && (
                <div className="mb-3 inline-flex items-center gap-1.5 rounded-full bg-primary/10 px-3 py-1 text-[11px] font-black text-primary">
                  <ShieldCheck size={13} />
                  {ui.adminOnly}
                </div>
              )}
              {ch.fallback && (
                <div className="mb-3 rounded-xl bg-amber-50 px-3 py-2 text-[12px] font-bold text-amber-800">
                  {ui.missing}
                </div>
              )}
              <ReactMarkdown remarkPlugins={[remarkGfm]} components={makeComponents(ch.id)}>
                {ch.text}
              </ReactMarkdown>
            </section>
          ))}
          <div className="help-print-footer hidden text-[11px] text-slate-400">
            {ui.title} · {ui.printedAt} {printedAt}
          </div>
        </main>
      </div>
    </div>
  );
}
