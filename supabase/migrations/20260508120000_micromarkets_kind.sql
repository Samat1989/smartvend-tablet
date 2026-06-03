-- Adds an explicit `kind` discriminator to `micromarkets` so each app
-- (vending tablet / staffed micromarket tablet / static-QR micromarket /
-- customer_web) can refuse to operate on the wrong type of machine.
--
-- Three exclusive values:
--   • `micromarket_tablet`  — micromarket with an attended tablet UI
--   • `micromarket_static`  — unattended micromarket whose QR points at
--                              customer_web and uses no on-site device
--   • `vending`             — motorised cabinet driven by M109E/M102
--
-- Default `micromarket_tablet` is the legacy/safe value: pre-existing rows
-- predate the vending fork and were all that kind. We then explicitly mark
-- the known vending test machines.

ALTER TABLE public.micromarkets
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'micromarket_tablet';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_schema = 'public'
      AND table_name = 'micromarkets'
      AND constraint_name = 'micromarkets_kind_check'
  ) THEN
    ALTER TABLE public.micromarkets
      ADD CONSTRAINT micromarkets_kind_check
      CHECK (kind IN ('micromarket_tablet', 'micromarket_static', 'vending'));
  END IF;
END $$;

COMMENT ON COLUMN public.micromarkets.kind IS
  'micromarket_tablet = staffed micromarket with interactive tablet UI; '
  'micromarket_static = unstaffed micromarket with static QR pointing at customer_web; '
  'vending = motorised vending cabinet (M109E/M102 board)';

-- Bootstrap the known vending test installations. Add more IDs as you
-- migrate further machines, or set via the owner UI once it supports the
-- field.
UPDATE public.micromarkets
   SET kind = 'vending'
 WHERE id IN (5840, 100000000)
   AND kind <> 'vending';
