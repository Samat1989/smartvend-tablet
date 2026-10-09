import { useEffect, useRef, useState } from 'react';
import { Download, Link2, Loader2, Unlink as LinkOff } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../supabaseClient';
import Modal from '../ui/Modal';
import { Button } from '../ui/Button';
import { inputCls } from '../ui/Field';
import { Tabs } from '../ui/Chips';
import { Banner } from '../ui/Feedback';
import { BoardLamp, DeviceStatusDot } from '../status/Status';
import { kindLabel, machineName } from '../lib/machines';

// Привязка платы на Realtime-прошивке (firmware/esp-rt). Владелец получает
// одноразовый код на 30 минут и вводит его на плате вместе с номером аппарата;
// плата обменивает код на свой канал и ключ подписи (RPC device_pair). Новая
// привязка выдаёт новые канал и ключ, так что прежняя плата аппарата глохнет.
// Settings of one machine (gear in the machine list), in tabs:
// - lock-board machines: Board (status, firmware check for the superadmin),
//   Lock (open time), Pairing (steps and code), Unpair — a tab of its own that
//   says what unpairing does before the button. Without a board only Pairing.
// - vending: Tablet (status) and Unpair, which replaced the bare unlink icon
//   in the machine row.
// `market` is the live row, so a board that pairs while the dialog is open
// shows up here by itself.
export default function MachineSettingsModal({ market, rtLive, rtState, onClose, onUnpair, onRelease, onRefresh, onCheckUpdate }) {
  const { t, i18n } = useTranslation();
  const paired = !!market.rt;
  const vending = market.kind === 'vending';
  const [tab, setTab] = useState(vending ? 'tablet' : paired ? 'board' : 'pair');
  const [busy, setBusy] = useState(false);
  // Open time of the machine (micromarkets.open_seconds): one number for paid
  // orders and service opens, sent to the board in every signed command. The
  // lock only latches shut when the door's reed switch sees its magnet, so this
  // is the window to pull the door open, not how long it stays unlocked.
  const [openSec, setOpenSec] = useState(String(market.open_seconds ?? 20));
  const [savingSec, setSavingSec] = useState(false);
  const [secMsg, setSecMsg] = useState(null); // {ok, text}
  const [code, setCode] = useState(null); // {code, expires_at}
  const [error, setError] = useState(null);
  const [now, setNow] = useState(Date.now());
  const [otaBusy, setOtaBusy] = useState(false);
  const [otaMsg, setOtaMsg] = useState(null); // {ok, text}
  const pairedAt = market.rt?.paired_at;

  async function checkUpdate() {
    setOtaBusy(true);
    setOtaMsg(null);
    setOtaMsg(await onCheckUpdate());
    setOtaBusy(false);
  }

  useEffect(() => {
    if (!code) return undefined;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [code]);

  // While a code is on screen, look for the board every 5 s: the moment it
  // pairs, the status at the top turns green without closing the dialog.
  useEffect(() => {
    if (!code) return undefined;
    const id = setInterval(() => onRefresh?.(), 5000);
    return () => clearInterval(id);
  }, [code]);

  // A new pairing landed: the code is spent.
  const firstPairedAt = useRef(pairedAt);
  useEffect(() => {
    if (pairedAt && pairedAt !== firstPairedAt.current) {
      firstPairedAt.current = pairedAt;
      setCode(null);
      setTab('board'); // show the fresh board's status
    }
  }, [pairedAt]);

  async function getCode() {
    setBusy(true);
    setError(null);
    const { data, error: err } = await supabase.rpc('create_pair_code', { p_machid: market.id });
    setBusy(false);
    if (err) setError(err.message);
    else setCode(data);
  }

  async function saveOpenSeconds(value = openSec) {
    const n = parseInt(value, 10);
    if (!Number.isInteger(n) || n < 1 || n > 600) {
      setSecMsg({ ok: false, text: t('open_seconds_range') });
      return;
    }
    setSavingSec(true);
    setSecMsg(null);
    const { error: err } = await supabase.rpc('set_open_seconds', { p_machid: market.id, p_seconds: n });
    setSavingSec(false);
    if (err) { setSecMsg({ ok: false, text: err.message }); return; }
    setOpenSec(String(n));
    setSecMsg({ ok: true, text: t('open_seconds_saved') });
    onRefresh?.();
  }

  const left = code ? Math.max(0, Math.floor((new Date(code.expires_at).getTime() - now) / 1000)) : 0;
  const mmss = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
  const head = 'text-xs font-bold text-slate-600 uppercase tracking-wider mb-2';

  const pairing = (
    <>
      <ol className="space-y-2 text-sm text-slate-700 leading-relaxed">
        {[1, 2, 3, 4].map((i) => (
          <li key={i} className="flex gap-2">
            <span className="shrink-0 w-6 h-6 rounded-full bg-sidebar text-white text-xs font-bold flex items-center justify-center">{i}</span>
            <span>{t(`settings_step_${i}`)}</span>
          </li>
        ))}
      </ol>
      {code && left > 0 && (
        <div className="mt-4 text-center rounded-[12px] bg-blue-50 border border-blue-200 py-3">
          <div className="text-xs font-bold text-blue-900 uppercase tracking-wider">{t('pair_board_code')}</div>
          <div className="text-4xl font-extrabold tracking-[0.3em] text-ink tabular-nums select-all">{code.code}</div>
          <div className="text-sm font-semibold text-slate-600 tabular-nums">{t('pair_board_expires')} {mmss}</div>
          <div className="mt-1 text-[13px] font-semibold text-slate-600 inline-flex items-center gap-1.5">
            <Loader2 size={12} className="animate-spin" /> {t('settings_waiting_board')}
          </div>
        </div>
      )}
      {code && left === 0 && (
        <div className="mt-4 rounded-[8px] px-3 py-3 bg-amber-50 border border-amber-300 text-amber-900 text-sm font-semibold">
          {t('pair_board_expired')}
        </div>
      )}
      {error && (
        <div className="mt-4 rounded-[8px] px-3 py-3 bg-rose-50 border border-rose-200 text-rose-800 text-sm font-semibold break-words">
          {error}
        </div>
      )}
      <Button variant="primary" block className="mt-4" loading={busy} icon={Link2} onClick={getCode}>
        {code ? t('pair_board_new_code') : t('pair_board_get_code')}
      </Button>
    </>
  );

  const tabs = vending
    ? [
        { value: 'tablet', label: t('settings_tab_tablet') },
        { value: 'release', label: t('settings_tab_unpair') },
      ]
    : paired
      ? [
          { value: 'board', label: t('settings_tab_board') },
          { value: 'lock', label: t('settings_tab_lock') },
          { value: 'pair', label: t('settings_tab_pair') },
          { value: 'unpair', label: t('settings_tab_unpair') },
        ]
      : null;
  const shown = tabs ? tab : 'pair';
  const seen = market.status?.last_seen_at;

  return (
    <Modal
      title={t('machine_settings')}
      subtitle={`${machineName(market, t)} · ${t('apparatus_no')}${market.id}`}
      onClose={onClose}
      mobile="sheet"
      bodyClassName="px-5 sm:px-6 pb-5 min-h-[22rem]"
    >
      {tabs ? (
        <div className="sticky top-0 z-10 bg-white -mx-5 sm:-mx-6 px-3 sm:px-4 pt-2 mb-5">
          <Tabs label={t('machine_settings')} options={tabs} value={shown} onChange={setTab} />
        </div>
      ) : (
        <div className="pt-5 mb-4">
          <Banner tone="warning">{t('pair_board_not_paired')}</Banner>
        </div>
      )}

      {shown === 'board' && (
        <div className="flex flex-col gap-5">
          <div className="rounded-[12px] border border-slate-200 bg-slate-50 p-3">
            <div className="flex items-center justify-between gap-2">
              <span className={head.replace('mb-2', '')}>{t('settings_board')}</span>
              <BoardLamp rt={rtLive} rtState={rtState} rtRow={market.rt} withLabel />
            </div>
            <dl className="mt-2 grid grid-cols-[auto,1fr] gap-x-3 gap-y-1 text-sm">
              <dt className="text-slate-600">ID</dt>
              <dd className="font-mono font-semibold text-ink truncate">{market.rt.device_id || '—'}</dd>
              <dt className="text-slate-600">{t('settings_firmware')}</dt>
              <dd className="font-semibold text-ink">{market.rt.board_ver || '—'}</dd>
              <dt className="text-slate-600">{t('adm_paired_at')}</dt>
              <dd className="font-semibold text-ink">{pairedAt ? new Date(pairedAt).toLocaleString(i18n.language) : '—'}</dd>
              {rtLive === false && market.rt.last_seen_at && (
                <>
                  <dt className="text-slate-600">{t('status_last_seen')}</dt>
                  <dd className="font-semibold text-ink">{new Date(market.rt.last_seen_at).toLocaleString(i18n.language)}</dd>
                </>
              )}
            </dl>
          </div>
          {onCheckUpdate && (
            <div>
              <div className={head}>{t('settings_firmware')}</div>
              <Button variant="secondary" block loading={otaBusy} icon={Download} onClick={checkUpdate}>
                {t('ota_check')}
              </Button>
              {otaMsg && (
                <p role="status" className={`mt-1 text-sm font-semibold ${otaMsg.ok ? 'text-emerald-800' : 'text-rose-700'}`}>{otaMsg.text}</p>
              )}
            </div>
          )}
        </div>
      )}

      {/* Typed only: the 10/20/30/60 presets saved on a single tap, so a
          stray touch changed the lock of a live machine. */}
      {shown === 'lock' && (
        <div>
          <label htmlFor="open-seconds" className={`block ${head}`}>{t('open_seconds_label')}</label>
          <form className="flex gap-2" onSubmit={(e) => { e.preventDefault(); saveOpenSeconds(); }}>
            <input
              id="open-seconds"
              type="number" min="1" max="600" inputMode="numeric"
              value={openSec}
              onChange={(e) => { setOpenSec(e.target.value); setSecMsg(null); }}
              className={`${inputCls} !w-28 font-bold tabular-nums`}
            />
            <Button type="submit" variant="primary" className="flex-1" loading={savingSec}>
              {t('open_seconds_save')}
            </Button>
          </form>
          <p className="mt-2 text-[13px] text-slate-600 leading-snug">{t('open_seconds_range')}. {t('open_seconds_hint')}</p>
          {secMsg && (
            <p role="status" className={`mt-1 text-sm font-semibold ${secMsg.ok ? 'text-emerald-800' : 'text-rose-700'}`}>{secMsg.text}</p>
          )}
        </div>
      )}

      {shown === 'pair' && (
        <div>
          {paired && (
            <p className="mb-3 rounded-[8px] bg-amber-50 border border-amber-300 px-3 py-2 text-[13px] font-semibold text-amber-900">
              {t('settings_repair_hint')}. {t('settings_repair_warn')}
            </p>
          )}
          {pairing}
        </div>
      )}

      {shown === 'unpair' && (
        <DangerTab
          title={t('unpair_title')}
          effects={[t('unpair_effect_1'), t('unpair_effect_2'), t('unpair_effect_3')]}
          warning={t('unpair_warn')}
          button={t('pair_board_unpair')}
          onClick={onUnpair}
        />
      )}

      {shown === 'tablet' && (
        <div className="flex flex-col gap-4">
          <div className="rounded-[12px] border border-slate-200 bg-slate-50 p-3 flex items-center justify-between gap-2">
            <span className={head.replace('mb-2', '')}>{t('settings_tab_tablet')}</span>
            <DeviceStatusDot status={market.status} kind={market.kind} withLabel />
          </div>
          <dl className="grid grid-cols-[auto,1fr] gap-x-3 gap-y-1.5 text-sm">
            <dt className="text-slate-600">{t('adm_col_kind')}</dt>
            <dd className="font-semibold text-ink">{kindLabel(market.kind, t)}</dd>
            <dt className="text-slate-600">{t('tablet_app_version')}</dt>
            <dd className="font-semibold text-ink">{market.status?.app_version || '—'}</dd>
            <dt className="text-slate-600">{t('tablet_last_signal')}</dt>
            <dd className="font-semibold text-ink">{seen ? new Date(seen).toLocaleString(i18n.language) : t('never')}</dd>
          </dl>
        </div>
      )}

      {shown === 'release' && (
        <DangerTab
          title={t('release_tab_title')}
          effects={[t('release_effect_1'), t('release_effect_2'), t('release_effect_3')]}
          warning={t('release_warn')}
          tone="warning"
          button={t('release_tablet')}
          onClick={onRelease}
        />
      )}
    </Modal>
  );
}

// What unpairing does, a warning, then the button. The button only opens the
// panel's confirmation; nothing is unpaired from this tab directly.
function DangerTab({ title, effects, warning, tone = 'danger', button, onClick }) {
  const { t } = useTranslation();
  return (
    <div className="flex flex-col gap-3">
      <h3 className="text-base font-extrabold text-ink">{title}</h3>
      <p className="text-sm text-slate-700">{t('unpair_effects_lead')}</p>
      <ul className="list-disc pl-5 flex flex-col gap-1.5 text-sm text-slate-700 leading-relaxed">
        {effects.map((e) => <li key={e}>{e}</li>)}
      </ul>
      <Banner tone={tone}>{warning}</Banner>
      <Button variant="danger-outline" block icon={LinkOff} onClick={onClick} className="min-h-11">
        {button}…
      </Button>
      <p className="text-[13px] text-slate-600">{t('confirm_comes_next')}</p>
    </div>
  );
}
