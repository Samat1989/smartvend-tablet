import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../supabaseClient';
import { Button } from '../ui/Button';
import { Field, PasswordInput } from '../ui/Field';
import { LANGS, Logo } from './Shell';

// Sign-in. A real <form>, so Enter submits and the browser's password manager
// recognises the pair (autocomplete email / current-password); the old screen
// had neither and needed a mouse click on the button.
export default function Login({ onError }) {
  const { t, i18n } = useTranslation();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const lang = i18n.resolvedLanguage || i18n.language;

  async function submit(e) {
    e.preventDefault();
    setBusy(true);
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    if (error) onError(`${t('login_error')}: ${error.message}`);
    setBusy(false);
  }

  return (
    <div className="admin-ui min-h-dvh flex bg-canvas text-ink">
      <div className="hidden lg:flex flex-1 bg-sidebar text-white p-12 flex-col justify-between">
        <div className="flex items-center gap-3">
          <Logo size={44} />
          <div className="flex flex-col">
            <span className="text-[21px] font-extrabold">MicroVend</span>
            <span className="text-[11px] font-semibold tracking-[0.12em] uppercase text-slate-400">{t('admin_panel')}</span>
          </div>
        </div>
        <div>
          <p className="text-[32px] font-extrabold leading-tight max-w-md">{t('login_tagline')}</p>
          <div className="flex gap-2.5 mt-5" aria-hidden="true">
            <span className="w-8 h-1 rounded bg-brand" />
            <span className="w-8 h-1 rounded bg-amber-500" />
            <span className="w-8 h-1 rounded bg-emerald-600" />
            <span className="w-8 h-1 rounded bg-violet-600" />
          </div>
        </div>
      </div>

      <div className="flex-1 flex flex-col items-center justify-center p-5">
        <div className="lg:hidden flex items-center gap-3 mb-8">
          <Logo size={40} />
          <span className="text-[21px] font-extrabold">MicroVend</span>
        </div>
        <form onSubmit={submit} className="w-full max-w-sm bg-white lg:bg-transparent rounded-2xl lg:rounded-none p-6 lg:p-0 shadow-card lg:shadow-none border border-slate-200 lg:border-0 flex flex-col gap-4">
          <h1 className="text-[26px] font-extrabold">{t('login_title')}</h1>
          <Field label={t('email')} type="email" autoComplete="email" inputMode="email" required value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@example.com" />
          <Field label={t('password')}>
            {({ id }) => (
              <PasswordInput id={id} autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />
            )}
          </Field>
          <Button type="submit" variant="primary" size="lg" block loading={busy} className="mt-1">
            {t('login_btn')}
          </Button>
          <div className="flex justify-center gap-1 mt-2" role="group" aria-label={t('language')}>
            {LANGS.map((l) => (
              <button
                key={l.code}
                type="button"
                aria-pressed={lang === l.code}
                onClick={() => i18n.changeLanguage(l.code)}
                className={`min-h-10 px-3 rounded-[8px] text-sm ${lang === l.code ? 'bg-brand-soft text-brand-dark font-bold' : 'text-slate-600 hover:bg-slate-100'}`}
              >
                {l.label}
              </button>
            ))}
          </div>
        </form>
      </div>
    </div>
  );
}
