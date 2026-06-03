-- Function to decrement stock securely
CREATE OR REPLACE FUNCTION decrement_stock(product_id UUID, qty INT)
RETURNS void AS $$
BEGIN
  UPDATE inventory
  SET stock = stock - qty
  WHERE id = product_id;
END;
$$ LANGUAGE plpgsql;

-- Ensure commands table is in the realtime publication
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables 
    WHERE pubname = 'supabase_realtime' 
    AND schemaname = 'public' 
    AND tablename = 'commands'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.commands;
  END IF;
END $$;
