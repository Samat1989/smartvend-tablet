import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Superadmin-only account management, called from the web admin
// (apps/web_app → /admin, "Администрирование" tab).
//
//   GET  → list the existing auth users + how many machines each one owns
//   POST { email, password, full_name? }        → create a new owner account
//   POST { action:'set_password', user_id, password }
//   POST { action:'delete', user_id }
//
// Mutations go through POST + `action`, matching device-admin, rather than
// PATCH/DELETE — a DELETE that carries its payload in the body is the kind of
// request intermediaries are allowed to strip.
//
// The slug still says "create-user" because the deployed name can't be changed
// without leaving the old endpoint live (this project has no CLI to delete a
// function). It handles the whole account lifecycle.
//
// PASSWORDS ARE SET, NOT MAILED. resetPasswordForEmail would need SMTP, which
// this project doesn't have — Supabase's built-in sender is rate-limited to a
// handful of messages an hour and isn't meant for production. Accounts are
// already created with a password the superadmin hands over in person, so a
// reset follows the same path: set a new one, pass it on.
//
// All of this requires `auth.admin.*`, which needs the service_role key — so it
// can only happen server-side, never from the browser bundle.
//
// AUTHORIZATION. The caller sends its own access token
// (`Authorization: Bearer <jwt>`, supabase-js does this automatically when a
// session exists) and we require that user to carry
// `app_metadata.is_superadmin = true`. app_metadata is writable only with the
// service_role key, so the browser cannot forge it (unlike user_metadata,
// which the user can set on themselves). See migration
// 20260804120000_superadmin_role.sql for how the flag is granted — and note
// the key is `is_superadmin`, not `role`: a `role` claim is what PostgREST
// uses to pick the Postgres role, so we keep well clear of that name.
//
// verify_jwt is false in config.toml: the gateway can't tell the project's
// publishable key from a real user JWT, so the check has to live here anyway.

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MIN_PASSWORD_LEN = 8;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const admin = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    { auth: { persistSession: false } },
  );

  // ── caller must be a superadmin ───────────────────────────────────────────
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ error: "not authenticated" }, 401);

  const { data: caller, error: callerErr } = await admin.auth.getUser(token);
  if (callerErr || !caller?.user) return json({ error: "not authenticated" }, 401);
  if (caller.user.app_metadata?.is_superadmin !== true) {
    return json({ error: "forbidden" }, 403);
  }

  try {
    // ── GET: list users ─────────────────────────────────────────────────────
    if (req.method === "GET") {
      const { data: list, error: listErr } = await admin.auth.admin.listUsers({
        page: 1,
        perPage: 200,
      });
      if (listErr) throw listErr;

      // How many machines each account owns — the practical reason the
      // superadmin opens this screen ("did the new owner get their machine?").
      const { data: machines } = await admin.from("micromarkets").select("id, owner_id");
      const owned = new Map();
      for (const m of machines ?? []) {
        if (!m.owner_id) continue;
        owned.set(m.owner_id, (owned.get(m.owner_id) ?? 0) + 1);
      }

      return json({
        users: (list?.users ?? []).map((u) => ({
          id: u.id,
          email: u.email,
          full_name: u.user_metadata?.full_name ?? null,
          role: u.app_metadata?.is_superadmin === true ? "superadmin" : "owner",
          created_at: u.created_at,
          last_sign_in_at: u.last_sign_in_at ?? null,
          machines: owned.get(u.id) ?? 0,
        })),
      });
    }

    // ── POST: create / set password / delete ────────────────────────────────
    if (req.method === "POST") {
      const body = await req.json().catch(() => ({}));
      const action = String(body.action ?? "create").trim();
      const userId = String(body.user_id ?? "").trim();

      if (action === "set_password") {
        const password = String(body.password ?? "");
        if (!userId) return json({ error: "user_required" }, 400);
        if (password.length < MIN_PASSWORD_LEN) return json({ error: "password_too_short" }, 400);

        const { data: updated, error } = await admin.auth.admin.updateUserById(userId, { password });
        if (error) return json({ error: error.message }, 400);
        return json({ user: { id: updated.user.id, email: updated.user.email } });
      }

      if (action === "delete") {
        if (!userId) return json({ error: "user_required" }, 400);
        // Deleting the account you're signed in as would lock you out of the
        // panel and could leave the fleet with no admin at all.
        if (userId === caller.user.id) return json({ error: "cannot_delete_self" }, 400);

        // micromarkets.owner_id has no FK to auth.users, so deleting an owner
        // would leave its machines pointing at a user that no longer exists —
        // invisible in every admin panel. Reassign them first.
        const { count } = await admin
          .from("micromarkets").select("id", { count: "exact", head: true }).eq("owner_id", userId);
        if ((count ?? 0) > 0) return json({ error: "has_machines", machines: count }, 409);

        const { error } = await admin.auth.admin.deleteUser(userId);
        if (error) return json({ error: error.message }, 400);
        return json({ deleted: userId });
      }

      if (action !== "create") return json({ error: "bad_action" }, 400);

      const email = String(body.email ?? "").trim().toLowerCase();
      const password = String(body.password ?? "");
      const fullName = String(body.full_name ?? "").trim();

      if (!EMAIL_RE.test(email)) return json({ error: "invalid email" }, 400);
      if (password.length < MIN_PASSWORD_LEN) {
        return json({ error: `password must be at least ${MIN_PASSWORD_LEN} characters` }, 400);
      }

      const { data: created, error: createErr } = await admin.auth.admin.createUser({
        email,
        password,
        // No mail server is wired up for this project and the superadmin hands
        // the credentials over directly, so the account is usable immediately.
        email_confirm: true,
        user_metadata: fullName ? { full_name: fullName } : {},
      });
      if (createErr) {
        // Supabase returns 422 "User already registered" for a duplicate email.
        const dup = /already been registered|already registered|duplicate/i.test(createErr.message);
        return json({ error: createErr.message }, dup ? 409 : 400);
      }

      return json({
        user: {
          id: created.user.id,
          email: created.user.email,
          full_name: fullName || null,
          role: "owner",
          created_at: created.user.created_at,
          machines: 0,
        },
      }, 201);
    }

    return json({ error: "method not allowed" }, 405);
  } catch (error) {
    return json({ error: error.message }, 500);
  }
});
