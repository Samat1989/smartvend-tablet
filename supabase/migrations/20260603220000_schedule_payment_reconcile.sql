-- ============================================================
-- Schedule server-side payment reconciliation (pg_cron).
--
-- Finalizing a Kaspi payment requires querying SmartVend payment_result. The
-- storefront polls verify-payment from the browser, but if the customer pays
-- and never returns to the tab the poll stops and SmartVend auto-refunds the
-- unconfirmed payment. This job runs the cron-process-payments Edge Function
-- every minute to confirm + record paid orders independent of the browser.
--
-- Idempotent: cron.schedule with the same job name replaces it.
-- Applied to prod via Supabase MCP on 2026-06-03 (jobid assigned by pg_cron).
-- ============================================================
select cron.schedule(
  'reconcile-payments',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://cgvfhtvdtdjsyluhlcbq.supabase.co/functions/v1/cron-process-payments',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := '{}'::jsonb,
    timeout_milliseconds := 25000
  )
  $$
);
