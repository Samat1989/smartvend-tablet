
import { createClient } from '@supabase/supabase-js';

const supabaseUrl = 'https://cgvfhtvdtdjsyluhlcbq.supabase.co';
const supabaseKey = 'sb_publishable_84RnaNCrFwxKicybxLGL2w_StEYpHnD';
const supabase = createClient(supabaseUrl, supabaseKey);

async function check() {
  console.log('--- Checking Market 100000000 ---');
  const { data, error } = await supabase
    .from('micromarkets')
    .select('id, name, secret')
    .eq('id', 100000000)
    .single();

  if (error) {
    console.error('Error fetching market:', error.message);
  } else {
    console.log('Market Name:', data.name);
    console.log('Secret Length:', data.secret ? data.secret.length : 0);
    // Be careful with printing secrets, but since I am debugging a 'stuck' issue:
    console.log('Secret:', data.secret); 
  }

  console.log('--- Checking Inventory ---');
  const { data: inv, error: invErr } = await supabase
    .from('inventory')
    .select('name, stock')
    .eq('micromarket_id', 100000000);
  
  if (invErr) {
    console.error('Error fetching inventory:', invErr.message);
  } else {
    console.log('Inventory items:', inv?.length);
  }
}

check();
