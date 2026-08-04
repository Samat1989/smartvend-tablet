import { createClient } from '@supabase/supabase-js';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

export const supabase = createClient(supabaseUrl, supabaseAnonKey);

// Dev escape hatch: point functions.invoke() at an edge function running
// locally (`deno run supabase/functions/<name>/index.ts`) while the DB, auth
// and storage keep talking to the real project. supabase-js derives the
// functions URL from the project URL and offers no option for it, but the
// `functions` getter re-reads this property on every access, so assigning it
// is enough. Unset in production — leave VITE_FUNCTIONS_URL out of .env there.
if (import.meta.env.VITE_FUNCTIONS_URL) {
  supabase.functionsUrl = new URL(import.meta.env.VITE_FUNCTIONS_URL);
}
