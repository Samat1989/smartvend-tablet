-- Vending machine extensions for the existing micromarket schema.
-- Adds motor mapping columns to `inventory` and a `dispensed` flag to
-- `sales_items` so we can record per-item dispense success.

-- ---- inventory: motor mapping ----
ALTER TABLE public.inventory
  ADD COLUMN IF NOT EXISTS motor_id      INT,
  ADD COLUMN IF NOT EXISTS motor_type    INT  DEFAULT 2,
  ADD COLUMN IF NOT EXISTS curtain_mode  INT  DEFAULT 0,
  ADD COLUMN IF NOT EXISTS emoji         TEXT;

-- One slot can only be bound to one motor per machine.
CREATE UNIQUE INDEX IF NOT EXISTS inventory_market_motor_uk
  ON public.inventory (micromarket_id, motor_id)
  WHERE motor_id IS NOT NULL;

COMMENT ON COLUMN public.inventory.motor_id     IS 'M109E motor id (44..99 for 6x6 cabinets)';
COMMENT ON COLUMN public.inventory.motor_type   IS '2 = 2-wire (default), 3 = 3-wire';
COMMENT ON COLUMN public.inventory.curtain_mode IS '0 = no drop sensor, 1 = present, 2 = priority';

-- ---- sales_items: per-item dispense outcome ----
ALTER TABLE public.sales_items
  ADD COLUMN IF NOT EXISTS dispensed BOOLEAN DEFAULT TRUE;

COMMENT ON COLUMN public.sales_items.dispensed
  IS 'TRUE if motor reported success + drop confirmed; FALSE means owner owes refund';

-- ---- decrement_stock RPC (mirrors the micromarket inventory function) ----
CREATE OR REPLACE FUNCTION public.decrement_stock(product_id UUID, qty INT)
RETURNS void AS $$
BEGIN
  UPDATE public.inventory
     SET stock = GREATEST(stock - qty, 0)
   WHERE id = product_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.decrement_stock(UUID, INT) TO anon, authenticated;
