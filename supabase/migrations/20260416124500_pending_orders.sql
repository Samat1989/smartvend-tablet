CREATE TABLE IF NOT EXISTS pending_orders (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  orderid text UNIQUE NOT NULL,
  market_id int4 NOT NULL,
  cart_data jsonb NOT NULL,
  status text DEFAULT 'pending',
  created_at timestamp with time zone DEFAULT now()
);

-- RLS
ALTER TABLE pending_orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Enable all for service role" ON pending_orders FOR ALL USING (true);
