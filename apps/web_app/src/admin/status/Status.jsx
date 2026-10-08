import { Signal, SignalHigh, SignalLow, SignalMedium, SignalZero, Wifi, WifiHigh, WifiLow, WifiZero } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { MACHINE_KINDS, kindLabel, kindTint } from '../lib/machines';

// Connection state of one machine, from its heartbeat.
//
// Three states, not two, because "the tablet answers" and "the board answers"
// are different faults with different call-outs: a machine can be perfectly
// online while nothing dispenses. One lamp would hide exactly the failure
// that costs the owner money.
//
//   зелёный — на связи, плата отвечает
//   жёлтый  — на связи, но плата молчит  → выехать к автомату, не к сети
//   серый   — не видели дольше порога, или ни разу (новый аппарат)
//
// `online` is computed server-side (device_status_view, 3-minute threshold);
// this only renders it.

export function KindBadge({ kind }) {
  const { t } = useTranslation();
  return (
    <span className={`text-xs font-semibold px-2 py-1 rounded-md shrink-0 whitespace-nowrap ${kindTint(kind)}`}>
      {kindLabel(kind, t)}
    </span>
  );
}

// Тот же бейдж типа, но его можно переключить — только в списке флота, где
// действует суперадмин. Селект, а не кнопка с диалогом: значений четыре, все
// известны заранее, и подтверждать нечего — смена типа обратима и ничего не
// удаляет, в отличие от прежнего способа «удалить и завести заново».
export function KindSelect({ kind, onChange }) {
  const { t } = useTranslation();
  return (
    <select
      value={kind || 'vending'}
      onChange={(e) => onChange(e.target.value)}
      title={t('device_kind_change')}
      aria-label={t('device_kind_change')}
      className={`text-xs font-semibold pl-2 pr-1 py-1 rounded-md border-0 cursor-pointer focus:outline-none focus:ring-3 focus:ring-blue-200 ${kindTint(kind)}`}
    >
      {MACHINE_KINDS.map((k) => (
        <option key={k} value={k}>{kindLabel(k, t)}</option>
      ))}
    </select>
  );
}

// Which payment rail the cabinet reported on its last heartbeat. Only drawn
// when it is not the default: an unmarked machine takes Kaspi, which is every
// machine in Kazakhstan and needs no badge. The tablet is what chooses this
// (a tick at pairing) — the panel only repeats what the tablet said, so a
// machine that was re-paired without the tick loses the badge after one beat.
export function PayChannelBadge({ status }) {
  if (status?.ter_number !== 'ODG') return null;
  return (
    <span
      className="text-xs font-bold px-2 py-1 rounded-md shrink-0 bg-sky-100 text-sky-800"
      title="O!Деньги · Кыргызстан · сом"
    >
      O!
    </span>
  );
}

// `rt` is the live Presence of a board on the Realtime firmware: true/false,
// null while the channel is still connecting, undefined for machines without
// such a board. Presence is the board's last will — Realtime drops it the
// moment the board's socket dies — so it needs no heartbeat threshold.
// Signal of a Realtime board from its Presence state, drawn the way a phone
// does: cellular bars for GSM, the Wi-Fi fan for Wi-Fi. dBm is negative for
// both (closer to 0 = stronger); for GSM the modem's own CSQ scale (0..31,
// 99 = unknown) goes in the tooltip too, since that is what installers know.
export function SignalIcon({ state }) {
  const dbm = Number(state?.rssi_dbm);
  if (!dbm) return null;
  const gsm = state.net === 'gsm';
  let Icon, level;
  if (gsm) {
    const csq = Number(state.csq);
    level = csq >= 20 ? 4 : csq >= 15 ? 3 : csq >= 10 ? 2 : csq >= 1 ? 1 : 0;
    Icon = [SignalZero, SignalLow, SignalMedium, SignalHigh, Signal][level];
  } else {
    level = dbm >= -55 ? 3 : dbm >= -67 ? 2 : dbm >= -75 ? 1 : 0;
    Icon = [WifiZero, WifiLow, WifiHigh, Wifi][level];
  }
  const tone = level >= 2 ? 'text-emerald-700' : level === 1 ? 'text-amber-600' : 'text-rose-600';
  const title = [
    gsm ? 'GSM' : 'Wi-Fi',
    gsm && Number(state.csq) <= 31 ? `CSQ ${state.csq}/31` : null,
    `${dbm} dBm`,
    state.ver && `v${state.ver}`,
  ].filter(Boolean).join(' · ');
  return (
    <span className={`shrink-0 ${tone}`} title={title}>
      <Icon size={14} strokeWidth={2.5} />
    </span>
  );
}

// Lamp, drawn as a pill so the state reads without hovering: green online,
// amber "online but the board is silent", red offline, grey never seen.
const LAMP = {
  green: 'bg-emerald-100 text-emerald-800',
  amber: 'bg-amber-100 text-amber-900',
  red: 'bg-rose-100 text-rose-800',
  grey: 'bg-slate-100 text-slate-700',
  wait: 'bg-slate-100 text-slate-500',
};
// Status words come lower-case from the dictionary (they also sit mid-sentence
// in tooltips); a pill starts with a capital.
const cap = (s) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : s);

function Lamp({ tone, label: raw, title, withLabel, extra }) {
  const label = cap(raw);
  if (!withLabel) {
    const dot = { green: 'bg-emerald-500', amber: 'bg-amber-500', red: 'bg-rose-500', grey: 'bg-slate-400', wait: 'bg-slate-300 animate-pulse' }[tone];
    return (
      <span className="inline-flex items-center gap-1.5 shrink-0" title={title}>
        <span className={`w-2.5 h-2.5 rounded-full ${dot}`} />
        <span className="sr-only">{label}</span>
        {extra}
      </span>
    );
  }
  return (
    <span className={`inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[13px] font-semibold whitespace-nowrap shrink-0 ${LAMP[tone]}`} title={title}>
      <span className={`w-1.5 h-1.5 rounded-full bg-current ${tone === 'wait' ? 'animate-pulse' : ''}`} aria-hidden="true" />
      {label}
      {extra}
    </span>
  );
}

// Lamp of a lock board on the Realtime firmware. Presence only knows "right
// now"; when the board is gone, the last time it was around is
// device_rt.last_seen_at: the board reports every 15 minutes (device_beat) and
// the panel stamps the exact moment it sees the board leave (touch_device_seen).
// It lives in device_rt, not device_status: on a machine with a tablet that row
// is the tablet's own.
export function BoardLamp({ rt, rtState, rtRow, withLabel, prefix }) {
  const { t, i18n } = useTranslation();
  const label = rt === true ? t('status_online') : rt === false ? t('status_offline') : t('status_checking');
  const tone = rt === true ? 'green' : rt === false ? 'red' : 'wait';
  const lastSeen = rt === false && rtRow?.last_seen_at
    ? `${t('status_last_seen')} ${new Date(rtRow.last_seen_at).toLocaleString(i18n.language)}`
    : null;
  const head = prefix ? `${prefix}: ` : '';
  return (
    <Lamp
      tone={tone}
      label={head + label}
      title={[head + label, lastSeen].filter(Boolean).join(' · ')}
      withLabel={withLabel}
      extra={rt === true ? <SignalIcon state={rtState} /> : null}
    />
  );
}

export function DeviceStatusDot({ status, kind, withLabel = false, rt, rtState, rtRow }) {
  const { t, i18n } = useTranslation();

  if (kind === 'micromarket_static' && rt !== undefined) {
    return <BoardLamp rt={rt} rtState={rtState} rtRow={rtRow} withLabel={withLabel} />;
  }

  // A static-QR micromarket has no tablet — the ESP relay doesn't report yet,
  // so there is nothing to draw. Showing it as permanently green would be the
  // same lie as storing `online` in a column: a claim about a device we have
  // no signal from. The lamp appears on its own once the relay starts beating.
  //
  // A screen micromarket is the opposite case: its ESP32 calls device_ping
  // every five minutes exactly like a tablet, so it has a real heartbeat and
  // hiding it would be the same lie in reverse.
  if (kind === 'micromarket_static') return null;

  const seen = status?.last_seen_at ? new Date(status.last_seen_at) : null;
  // A tablet machine with a paired lock board draws two lamps; each says which
  // device it speaks for.
  const two = kind === 'micromarket_tablet' && rt !== undefined;
  const who = two ? t('lamp_tablet') : null;

  let tone, label, note;
  if (!status) {
    tone = 'grey';
    label = t('status_never');
  } else if (!status.online) {
    tone = 'red';
    label = t('status_offline');
  } else if (status.board_ok === false) {
    tone = 'amber';
    label = t('status_board_down');
  } else {
    tone = 'green';
    label = t('status_online');
    // null ≠ false. BarysVend has no health poll, so the tablet reports
    // "unknown" and the lamp only speaks for the tablet. Said out loud in
    // the tooltip, otherwise it looks like the board check silently works
    // on some machines and not others.
    if (status.board_ok == null) note = two ? null : t('status_board_unknown');
  }

  const title = [
    who ? `${who}: ${label}` : label,
    seen && `${t('status_last_seen')} ${seen.toLocaleString(i18n.language)}`,
    note,
  ].filter(Boolean).join(' · ');

  const tabletLamp = <Lamp tone={tone} label={who ? `${who}: ${label}` : label} title={title} withLabel={withLabel} />;
  if (!two) return tabletLamp;
  return (
    <span className="inline-flex items-center gap-2 flex-wrap">
      {tabletLamp}
      <BoardLamp rt={rt} rtState={rtState} rtRow={rtRow} withLabel={withLabel} prefix={t('lamp_board')} />
    </span>
  );
}

// "Is this machine reachable?" as one boolean, for counters and filters.
// Static-QR without a board has no signal at all → null (not counted).
export function machineOnline(m, rtLive) {
  if (m.kind === 'micromarket_static') return m.rt ? rtLive === true : null;
  const tablet = !!m.status?.online;
  if (m.kind === 'micromarket_tablet' && m.rt) return tablet || rtLive === true;
  return m.status ? tablet : false;
}
