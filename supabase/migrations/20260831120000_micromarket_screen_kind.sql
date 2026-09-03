-- Fourth machine kind: `micromarket_screen` — a lock cabinet whose storefront
-- lives on the machine's own touchscreen (ESP32-S3), not on the buyer's phone
-- and not on a tablet. Design: docs/esp-screen-micromarket.md.
--
-- Why a separate kind rather than reusing `micromarket_static`:
--   • a screen machine's positions need a cell number (inventory.motor_id,
--     10..99) — the buyer types it on the on-screen numpad. static-QR machines
--     have no numpad and no numbers, and six of them are live today;
--   • a screen machine reports itself through device_ping like a tablet, so it
--     has a heartbeat and deserves the connection lamp. A static-QR machine has
--     no device at all and a lamp there would be a lie.
-- Keeping them apart means the working static-QR path is untouched by
-- construction, at the price of this one CHECK.
--
-- Nothing else in the schema moves: the cell number is the existing
-- `inventory.motor_id` column (for vending it is a motor index, here it is the
-- number written on the shelf), and uniqueness within a machine is already
-- enforced by the partial index `inventory_market_motor_uk`.
--
-- Kept in sync by hand: KINDS in supabase/functions/device-claim/index.ts.

ALTER TABLE public.micromarkets
  DROP CONSTRAINT IF EXISTS micromarkets_kind_check;

ALTER TABLE public.micromarkets
  ADD CONSTRAINT micromarkets_kind_check
  CHECK (kind IN ('micromarket_tablet', 'micromarket_static', 'vending', 'micromarket_screen'));

COMMENT ON COLUMN public.micromarkets.kind IS
  'micromarket_tablet = staffed micromarket with interactive tablet UI; '
  'micromarket_static = unstaffed micromarket with static QR pointing at customer_web; '
  'micromarket_screen = unstaffed micromarket with an on-machine touchscreen (numpad by cell number); '
  'vending = motorised vending cabinet (M109E/M102 board)';
