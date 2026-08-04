-- ============================================================
-- Superadmin flag for the operator-provisioning screen
--
-- The web admin gains a "Пользователи" tab (create owner accounts) that is
-- served by the `admin-create-user` edge function. That function needs a way
-- to tell "this is the platform owner" from "this is a regular micromarket
-- owner", and the answer has to be un-forgeable from the browser.
--
-- auth.users.raw_app_meta_data is exactly that: it lands in the user's JWT as
-- the `app_metadata` claim and is writable ONLY with the service_role key /
-- direct SQL — unlike raw_user_meta_data, which any logged-in user can rewrite
-- on themselves via supabase.auth.updateUser().
--
-- Key name is `is_superadmin`, NOT `role`: PostgREST reads a top-level `role`
-- claim to decide which Postgres role to SET ROLE into, and we don't want a
-- value like 'superadmin' anywhere near that lookup.
--
-- The flag reaches the client only on the next token issue, so the account
-- must sign out and back in (or wait for a token refresh) after this runs.
-- ============================================================

UPDATE auth.users
   SET raw_app_meta_data =
         COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('is_superadmin', true)
 WHERE email = 'smartvend.kz@gmail.com';

-- To grant another platform admin later:
--   UPDATE auth.users SET raw_app_meta_data =
--     COALESCE(raw_app_meta_data,'{}'::jsonb) || '{"is_superadmin":true}'::jsonb
--   WHERE email = '<email>';
--
-- To revoke:
--   UPDATE auth.users SET raw_app_meta_data = raw_app_meta_data - 'is_superadmin'
--   WHERE email = '<email>';
