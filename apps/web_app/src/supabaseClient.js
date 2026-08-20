import { createClient } from '@supabase/supabase-js';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

/**
 * Drop-in replacement for supabase-js's own `navigatorLock`.
 *
 * The auth client serialises token refresh across tabs with the Web Locks API.
 * On the auto-refresh tick it asks for the lock with `acquireTimeout === 0`,
 * which the stock implementation maps to `{ ifAvailable: true }` and then
 * THROWS `NavigatorLockAcquireTimeoutError` when another tab already holds it.
 * Nothing on that path catches it, so every time a second tab regains focus the
 * console gets an uncaught rejection:
 *
 *     Acquiring an exclusive Navigator LockManager lock "lock:sb-…-auth-token"
 *     immediately failed
 *
 * Losing that race is normal and harmless — the tick simply belongs to another
 * tab this round and runs again in 30 s. So for the no-wait case we return
 * instead of throwing. Waiting acquisitions (sign-in, initialize, getSession)
 * keep the original blocking behaviour, because there a silent skip really
 * would swallow work.
 */
async function tolerantNavigatorLock(name, acquireTimeout, fn) {
  const locks = globalThis.navigator?.locks;
  if (!locks) return await fn(); // no Web Locks (older Safari, SSR) — just run

  if (acquireTimeout === 0) {
    return await locks.request(
      name,
      { mode: 'exclusive', ifAvailable: true },
      async (lock) => (lock ? await fn() : undefined),
    );
  }

  if (acquireTimeout < 0) {
    return await locks.request(name, { mode: 'exclusive' }, async () => await fn());
  }

  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), acquireTimeout);
  try {
    return await locks.request(
      name,
      { mode: 'exclusive', signal: ctl.signal },
      async () => await fn(),
    );
  } finally {
    clearTimeout(timer);
  }
}

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: { lock: tolerantNavigatorLock },
});

// Dev escape hatch: point functions.invoke() at an edge function running
// locally (`deno run supabase/functions/<name>/index.ts`) while the DB, auth
// and storage keep talking to the real project. supabase-js derives the
// functions URL from the project URL and offers no option for it, but the
// `functions` getter re-reads this property on every access, so assigning it
// is enough. Unset in production — leave VITE_FUNCTIONS_URL out of .env there.
if (import.meta.env.VITE_FUNCTIONS_URL) {
  supabase.functionsUrl = new URL(import.meta.env.VITE_FUNCTIONS_URL);
}
