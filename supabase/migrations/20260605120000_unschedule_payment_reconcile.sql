-- Remove the per-minute payment-reconcile cron job.
--
-- create-payment now keeps polling payment_result server-side in the background
-- (EdgeRuntime.waitUntil, every 12s for ~1 min) right after the QR is issued,
-- which covers the SmartVend auto-refund window without a separate cron. The
-- browser also polls when active. The cron-process-payments function is left
-- deployed but unscheduled (dormant backstop; can be re-scheduled if needed).
--
-- Applied to prod via Supabase MCP on 2026-06-05 (cron.unschedule).
select cron.unschedule('reconcile-payments');
