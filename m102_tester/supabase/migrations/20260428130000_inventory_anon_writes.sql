-- Allow the tablet (anon key) to manage inventory rows directly.
--
-- Trust model: the anon key is already shipped inside the APK, and it can
-- already SELECT every inventory row in the database (see existing
-- "Allow anon select inventory" policy). Adding INSERT/UPDATE/DELETE for
-- anon keeps the trust boundary the same — the only new capability is
-- mutation, which is gated client-side by the service-mode PIN.
--
-- For stronger separation move these writes into an Edge Function that
-- validates `(machid, secret)` against `micromarkets.secret` server-side.

CREATE POLICY "Allow anon insert inventory"
  ON public.inventory FOR INSERT TO anon
  WITH CHECK (true);

CREATE POLICY "Allow anon update inventory"
  ON public.inventory FOR UPDATE TO anon
  USING (true) WITH CHECK (true);

CREATE POLICY "Allow anon delete inventory"
  ON public.inventory FOR DELETE TO anon
  USING (true);
