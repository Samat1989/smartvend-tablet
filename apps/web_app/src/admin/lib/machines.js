// Machine kinds, currency, cabinet layout and cell numbers — everything the
// panel derives from a micromarkets row without asking the server again.

export const MACHINE_KINDS = ['vending', 'micromarket_tablet', 'micromarket_static', 'micromarket_screen'];

// Остаток, при котором позиция считается «заканчивается» (включительно).
// Им же считаются сводки по аппаратам.
export const LOW_STOCK = 2;
export const isLowStock = (stock) => (stock ?? 0) <= LOW_STOCK;

// Три типа машин, а проверка была одна: "static или вендинг". С появлением
// micromarket_tablet тернарник начал врать — планшетный микромаркет
// показывался как вендинг. Одно место вместо трёх копий.
// Цвет бейджа по типу. Планшетный микромаркет отличается от static-QR не
// косметически: у него есть устройство, которое отчитывается, поэтому у него
// горит лампочка связи — и в списке он не должен сливаться с тем, у которого
// её никогда не будет.
export function kindTint(kind) {
  if (kind === 'micromarket_static') return 'bg-emerald-100 text-emerald-800';
  if (kind === 'micromarket_tablet') return 'bg-amber-100 text-amber-800';
  if (kind === 'micromarket_screen') return 'bg-violet-100 text-violet-800';
  return 'bg-blue-100 text-blue-800';
}

export function kindLabel(kind, t) {
  if (kind === 'micromarket_static') return t('badge_micromarket');
  if (kind === 'micromarket_tablet') return t('badge_micromarket_tablet');
  if (kind === 'micromarket_screen') return t('badge_micromarket_screen');
  return t('badge_vending');
}

// Открытая полка: ни моторов, ни раскладки. Инвентарь рисуется плоским
// списком, и позиции заводит сам владелец — планшета, который создал бы их на
// месте, у таких машин нет.
export function isOpenShelfKind(kind) {
  return kind === 'micromarket_static' || kind === 'micromarket_screen';
}

export const machineName = (m, t) => m?.name || `${t('apparatus_no')}${m?.id ?? ''}`;

export const TENGE = '₸';
// The som is a 'с' with a bar under it. U+20C0 SOM SIGN exists for exactly
// that and is deliberately NOT used: no system font on the tablets or the
// handsets we checked carries the glyph, so it renders as a tofu box. A
// Cyrillic 'с' plus U+0332 COMBINING LOW LINE draws the same mark out of
// fonts that are actually installed. Same call as the tablet's
// DeviceStorage.currencySymbol — keep the two in step.
export const SOM = 'с̲';

// What a machine charges in. Follows the payment channel its tablet reported,
// not the owner's interface language: a Kyrgyz cabinet takes som whether the
// panel is being read in Russian or English. Unmarked machines take Kaspi.
export function currencyOf(market) {
  return market?.status?.ter_number === 'ODG' ? SOM : TENGE;
}

// Category name in the panel's language. Every category carries all three
// names (the add form requires them), but the panel used to print name_ru
// regardless of the switch. Falls back to Russian for rows from before kz/en.
export function catName(cat, lang) {
  if (!cat) return null;
  if (lang === 'kk' || lang === 'kz') return cat.name_kz || cat.name_ru;
  if (lang === 'en') return cat.name_en || cat.name_ru;
  return cat.name_ru;
}

// Money with thin grouping: 1 482 300. toLocaleString('ru') does the same but
// with a no-break space that some fonts draw wider than a digit.
export function money(n) {
  return Math.round(n || 0).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
}

// Build the default factory 6×6 layout (matches LayoutTemplate.factory6x6
// on the tablet). Used as a fallback when micromarkets.layout_json is
// null — newly-paired machines or anything that hasn't run a layout
// editor on-device yet.
function buildFactory6x6Layout() {
  const shelves = [];
  for (let s = 1; s <= 6; s++) {
    const slots = [];
    for (let j = 1; j <= 6; j++) {
      const motor = (10 - s) * 10 + (10 - j);
      const n = (s - 1) * 6 + j;
      slots.push({ label: n.toString().padStart(3, '0'), motorIds: [motor] });
    }
    const first = (s - 1) * 6 + 1;
    const last = s * 6;
    shelves.push({
      label: `${first.toString().padStart(3, '0')} — ${last.toString().padStart(3, '0')}`,
      slots,
    });
  }
  return { shelves };
}

// Parse layout_json from Supabase. Falls back to factory 6×6 on null,
// malformed JSON, or empty shelves. Same on-disk shape as the tablet's
// MachineLayout.encode().
export function parseLayout(rawJson) {
  if (rawJson == null) return { ...buildFactory6x6Layout(), _source: 'fallback' };
  try {
    const obj = typeof rawJson === 'string' ? JSON.parse(rawJson) : rawJson;
    if (!obj?.shelves || !Array.isArray(obj.shelves) || obj.shelves.length === 0) {
      return { ...buildFactory6x6Layout(), _source: 'fallback' };
    }
    return {
      _source: 'db',
      shelves: obj.shelves.map(sh => ({
        label: sh.label ?? '',
        slots: (sh.slots ?? []).map(sl => ({
          label: sl.label ?? '',
          motorIds: (sl.motorIds ?? []).map(n => Number(n)),
        })),
      })),
    };
  } catch {
    return { ...buildFactory6x6Layout(), _source: 'fallback' };
  }
}

// Build a Map<motorId, slot> for O(1) lookup of which slot a given
// motor belongs to. Twin spirals have multiple motorIds → all map to
// the same slot record. Inventory rows store the primary motor_id, so
// matching covers the common case + the rare "operator wired the
// secondary" case.
function buildSlotByMotor(layout) {
  const byMotor = new Map();
  for (const sh of layout.shelves) {
    for (const sl of sh.slots) {
      for (const m of sl.motorIds) {
        byMotor.set(m, sl);
      }
    }
  }
  return byMotor;
}

// Translate an M102 motor index into the printed slot label on the
// cabinet door, using the operator-defined layout when available.
export function motorToSlotLabel(motorId, layout) {
  if (motorId == null) return null;
  const id = Number(motorId);
  if (!Number.isInteger(id)) return null;
  if (layout) {
    const byMotor = layout._byMotorCache ?? buildSlotByMotor(layout);
    if (!layout._byMotorCache) layout._byMotorCache = byMotor;
    const slot = byMotor.get(id);
    if (slot) return slot.label;
  }
  // Fallback to factory 6×6 formula when caller didn't pass a layout
  // (e.g. for the inventory list view where we render rows before the
  // full layout is loaded).
  if (id < 0 || id > 99) return null;
  const row = 10 - Math.floor(id / 10);
  const col = 10 - (id % 10);
  if (row < 1 || row > 9 || col < 1 || col > 9) return null;
  const n = (row - 1) * 10 + col;
  return n.toString().padStart(3, '0');
}

// Cell numbers on a screen micromarket are always two digits (10..99): the
// numpad then searches on its own after the second key and needs no «OK», and
// the number on the shelf sticker is the number the buyer types — no leading
// zero to explain. Returns the lowest free one, or null when all 90 are taken
// (the field then stays empty and the operator decides).
//
// Pass the machine's WHOLE inventory, not the category-filtered list: a filter
// would hide part of the taken numbers and this would hand out a duplicate.
export const CELL_MIN = 10;
export const CELL_MAX = 99;

export function nextFreeCellNumber(rows, min = CELL_MIN, max = CELL_MAX) {
  const taken = new Set();
  for (const r of rows ?? []) {
    // Explicit null check: Number(null) === 0 would silently take a slot.
    if (r?.motor_id == null) continue;
    const n = Number(r.motor_id);
    if (Number.isInteger(n)) taken.add(n);
  }
  for (let n = min; n <= max; n++) if (!taken.has(n)) return n;
  return null;
}

// Порядок списка у машины с экраном — по номеру ячейки, как товар стоит на
// полке. motorToSlotLabel здесь применять нельзя: она переводит номер по
// вендинговой раскладке, и «15» стало бы «085», а «10» — «?». Позиции без
// номера уходят в конец: на экране их всё равно нет.
export function byCellNumber(a, b) {
  const ca = a?.motor_id == null ? null : Number(a.motor_id);
  const cb = b?.motor_id == null ? null : Number(b.motor_id);
  if (ca == null && cb == null) return (a.name || '').localeCompare(b.name || '');
  if (ca == null) return 1;
  if (cb == null) return -1;
  return ca - cb;
}
