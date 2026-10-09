import { Fragment, useEffect, useState } from 'react';
import { ArrowLeftRight, ChevronDown, Cpu, KeyRound, Plus, RefreshCw, Trash2, UserX, Wifi, WifiOff } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import { Button, IconButton } from '../ui/Button';
import { Card, KpiCard, PageHeader, Pagination, Pill } from '../ui/Card';
import { ChipGroup, Tabs } from '../ui/Chips';
import { EmptyState, SkeletonRows } from '../ui/Feedback';
import { SearchInput, inputCls, matches } from '../ui/Field';
import { DeviceStatusDot, KindSelect } from '../status/Status';
import { MACHINE_KINDS, kindLabel } from '../lib/machines';

const PAGE_SIZES = [25, 50, 100];

// Overall state of a fleet row. No Presence channels here (one per board would
// load Realtime for nothing): the board reports every 15 minutes, so 20 minutes
// of silence means offline. The owner's own panel stays live.
function fleetRow(m) {
  const rtLamp = m.rt
    ? !!m.rt.last_seen_at && Date.now() - new Date(m.rt.last_seen_at).getTime() < 20 * 60 * 1000
    : undefined;
  const hb = m.heartbeat;
  const tabletKind = m.kind === 'micromarket_tablet' || m.kind === 'vending' || m.kind === 'micromarket_screen';
  const online = rtLamp === true || (m.kind !== 'micromarket_static' && tabletKind && !!hb?.online);
  const paired = !!m.rt;
  const needsBoard = m.kind === 'micromarket_static' || m.kind === 'micromarket_tablet';
  const last = [hb?.last_seen_at, m.rt?.last_seen_at].filter(Boolean).sort().pop() ?? null;
  return { m, rtLamp, online, paired, needsBoard, last };
}

// Keeps the page in range when a filter shrinks the list under it.
function usePaged(items, initial = 25) {
  const [page, setPage] = useState(1);
  const [size, setSize] = useState(initial);
  const pages = Math.max(1, Math.ceil(items.length / size));
  const cur = Math.min(page, pages);
  return {
    page: cur, size, setPage, total: items.length,
    setSize: (s) => { setSize(s); setPage(1); },
    slice: items.slice((cur - 1) * size, cur * size),
  };
}

function ago(iso, t, lang) {
  if (!iso) return t('never');
  const min = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (min < 2) return t('just_now');
  if (min < 60) return t('min_ago', { count: min });
  const h = Math.round(min / 60);
  if (h < 24) return t('hours_ago', { count: h });
  return new Date(iso).toLocaleDateString(lang);
}

// ---- Administration (superadmin only) ----
// Every device and every account of the platform. Accounts come from
// admin-create-user, machines from device-admin; both need the service_role
// key, so neither can happen in the browser, and RLS would show the superadmin
// only its own machines anyway. The functions refuse anyone else regardless of
// what this page shows.
export default function AdminTab({
  users, usersLoading, devices, devicesLoading, currentUserId,
  onRefresh, onCreateUser, onAddDevice, onChangePassword, onDeleteUser,
  onTransfer, onDeleteDevice, onChangeKind,
}) {
  const { t } = useTranslation();
  const [view, setView] = useState('devices');

  const rows = (devices ?? []).map(fleetRow);
  const total = rows.length;
  const onlineN = rows.filter((r) => r.online).length;
  const orphanN = rows.filter((r) => !r.m.owner_id).length;
  const unpairedN = rows.filter((r) => r.needsBoard && !r.paired).length;

  return (
    <div className="flex flex-col gap-6">
      <PageHeader
        title={t('tab_users')}
        subtitle={t('admin_subtitle')}
        actions={(
          <>
            <IconButton icon={RefreshCw} label={t('refresh')} loading={usersLoading || devicesLoading} onClick={onRefresh} className="!w-11 !h-11" />
            <Button icon={Plus} onClick={onCreateUser} className="min-h-11 flex-1 sm:flex-none">{t('user_short')}</Button>
            <Button variant="primary" icon={Plus} onClick={onAddDevice} className="min-h-11 flex-1 sm:flex-none">{t('device_short')}</Button>
          </>
        )}
      />

      <Tabs
        label={t('tab_users')}
        value={view}
        onChange={setView}
        options={[
          { value: 'devices', label: t('adm_view_devices'), count: devices ? total : null },
          { value: 'users', label: t('adm_view_users'), count: users ? users.length : null },
        ]}
      />

      {view === 'devices' && (
        <div className="grid grid-cols-2 xl:grid-cols-4 gap-3 sm:gap-4">
          <KpiCard accent="blue" icon={Cpu} label={t('adm_total')} value={devices ? String(total) : '—'} />
          <KpiCard accent="green" icon={Wifi} label={t('status_online')} value={devices ? String(onlineN) : '—'} />
          <KpiCard accent="orange" icon={WifiOff} label={t('status_offline')} value={devices ? String(total - onlineN) : '—'} pill={unpairedN ? `${t('adm_unpaired')}: ${unpairedN}` : null} />
          <KpiCard accent="violet" icon={UserX} label={t('devices_no_owner')} value={devices ? String(orphanN) : '—'} />
        </div>
      )}

      {view === 'devices'
        ? <DevicesTable rows={rows} loading={devices == null} onTransfer={onTransfer} onDelete={onDeleteDevice} onChangeKind={onChangeKind} />
        : <UsersTable users={users} devices={devices} currentUserId={currentUserId} onChangePassword={onChangePassword} onDeleteUser={onDeleteUser} onTransfer={onTransfer} />}
    </div>
  );
}

// Renaming lives with the owner (their machine list); the superadmin's row
// keeps only what changes hands or ends a machine.
function DeviceActions({ m, onTransfer, onDelete, wide = false }) {
  const { t } = useTranslation();
  return (
    <div className="flex items-center gap-1.5">
      <Button variant="soft" size="sm" icon={ArrowLeftRight} onClick={() => onTransfer(m)} className={wide ? 'flex-1' : ''}>
        {t('transfer_short')}
      </Button>
      <IconButton icon={Trash2} label={t('delete')} tone="danger" onClick={() => onDelete(m.id)} />
    </div>
  );
}

function DevicesTable({ rows, loading, onTransfer, onDelete, onChangeKind }) {
  const { t, i18n } = useTranslation();
  const [q, setQ] = useState('');
  const [kindF, setKindF] = useState('all');
  const [stateF, setStateF] = useState('all');
  const [expanded, setExpanded] = useState(null);

  const shown = rows.filter(({ m, online, paired, needsBoard }) => {
    if (kindF !== 'all' && m.kind !== kindF) return false;
    if (stateF === 'online' && !online) return false;
    if (stateF === 'offline' && online) return false;
    if (stateF === 'unpaired' && !(needsBoard && !paired)) return false;
    if (stateF === 'orphan' && m.owner_id) return false;
    return matches(q, m.id, m.name, m.owner_email, m.rt?.device_id);
  });
  const paged = usePaged(shown);
  useEffect(() => { paged.setPage(1); }, [q, kindF, stateF]);
  const fmt = (v) => (v ? new Date(v).toLocaleString(i18n.language) : '—');

  return (
    <Card>
      <div className="flex flex-col gap-3 p-4 sm:px-5">
        <div className="flex flex-wrap gap-3">
          <SearchInput value={q} onChange={setQ} placeholder={t('adm_search')} className="flex-1 min-w-[220px]" />
          <label className="sr-only" htmlFor="adm-kind">{t('adm_col_kind')}</label>
          <select id="adm-kind" value={kindF} onChange={(e) => setKindF(e.target.value)} className={`${inputCls} !w-auto font-semibold`}>
            <option value="all">{t('adm_all_kinds')}</option>
            {MACHINE_KINDS.map((k) => <option key={k} value={k}>{kindLabel(k, t)}</option>)}
          </select>
        </div>
        <ChipGroup
          label={t('filter')}
          value={stateF}
          onChange={setStateF}
          scroll
          options={[
            { value: 'all', label: t('filter_all'), count: rows.length },
            { value: 'online', label: t('status_online') },
            { value: 'offline', label: t('status_offline'), tone: 'danger' },
            { value: 'unpaired', label: t('adm_unpaired'), tone: 'warning' },
            { value: 'orphan', label: t('devices_no_owner'), tone: 'warning' },
          ]}
        />
      </div>

      {loading ? (
        <div className="px-4 pb-4"><SkeletonRows rows={6} /></div>
      ) : shown.length === 0 ? (
        <EmptyState title={t('adm_nothing')} hint={t('nothing_found_hint')} />
      ) : (
        <>
          <div className="hidden lg:block overflow-x-auto px-3">
            <table className="w-full text-sm min-w-[960px]">
              <thead>
                <tr className="bg-slate-100 text-slate-600 text-xs uppercase tracking-wider text-left">
                  <th scope="col" className="px-3 py-3 font-bold rounded-l-[8px]">{t('adm_col_name')}</th>
                  <th scope="col" className="px-3 py-3 font-bold">{t('adm_col_owner')}</th>
                  <th scope="col" className="px-3 py-3 font-bold">{t('adm_col_kind')}</th>
                  <th scope="col" className="px-3 py-3 font-bold">{t('adm_col_status')}</th>
                  <th scope="col" className="px-3 py-3 font-bold">{t('adm_col_last')}</th>
                  <th scope="col" className="px-3 py-3 font-bold text-right rounded-r-[8px]">{t('actions')}</th>
                </tr>
              </thead>
              <tbody>
                {paged.slice.map(({ m, rtLamp, paired, needsBoard, last }) => (
                  <Fragment key={m.id}>
                    <tr className="border-b border-slate-200 align-middle hover:bg-slate-50">
                      <td className="px-3 py-3">
                        <button
                          type="button"
                          onClick={() => setExpanded(expanded === m.id ? null : m.id)}
                          aria-expanded={expanded === m.id}
                          className="flex items-start gap-1.5 text-left focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300 rounded"
                        >
                          <ChevronDown size={16} className={`mt-0.5 shrink-0 text-slate-500 transition-transform ${expanded === m.id ? 'rotate-180' : ''}`} />
                          <span>
                            <span className="block font-bold text-ink">{m.name || '—'}</span>
                            <span className="block text-xs text-slate-600">
                              {t('apparatus_no')}{m.id}
                              {m.heartbeat?.app_version && ` · ${t('lamp_tablet')} ${m.heartbeat.app_version}`}
                              {m.rt?.board_ver && ` · ${t('lamp_board')} ${m.rt.board_ver}`}
                            </span>
                          </span>
                        </button>
                      </td>
                      <td className="px-3 py-3">
                        {m.owner_email
                          ? <span className="text-ink break-all">{m.owner_email}</span>
                          : <span className="font-bold text-rose-700">{t('devices_no_owner')}</span>}
                      </td>
                      <td className="px-3 py-3"><KindSelect kind={m.kind} onChange={(k) => onChangeKind(m.id, k)} /></td>
                      <td className="px-3 py-3">
                        <div className="flex flex-col items-start gap-1.5">
                          <DeviceStatusDot status={m.heartbeat} kind={m.kind} withLabel rt={rtLamp} rtRow={m.rt} />
                          {needsBoard && !paired && <Pill tone="amber">{t('adm_unpaired')}</Pill>}
                        </div>
                      </td>
                      <td className="px-3 py-3 text-slate-700 whitespace-nowrap" title={fmt(last)}>{ago(last, t, i18n.language)}</td>
                      <td className="px-3 py-3"><div className="flex justify-end"><DeviceActions m={m} onTransfer={onTransfer} onDelete={onDelete} /></div></td>
                    </tr>
                    {expanded === m.id && (
                      <tr className="bg-slate-50 border-b border-slate-200">
                        <td colSpan={6} className="px-10 py-3">
                          <dl className="grid grid-cols-[auto,1fr] sm:grid-cols-[auto,1fr,auto,1fr] gap-x-4 gap-y-1 text-[13px]">
                            <dt className="text-slate-600">{t('adm_paired_at')}</dt><dd className="font-semibold">{fmt(m.rt?.paired_at)}</dd>
                            <dt className="text-slate-600">{t('adm_col_last')}</dt><dd className="font-semibold">{fmt(last)}</dd>
                            <dt className="text-slate-600">{t('adm_col_open')}</dt><dd className="font-semibold">{m.open_seconds ? `${m.open_seconds} ${t('adm_sec')}` : '—'}</dd>
                            <dt className="text-slate-600">ID</dt><dd className="font-mono font-semibold">{m.rt?.device_id || '—'}{m.heartbeat?.ter_number ? ` · ter ${m.heartbeat.ter_number}` : ''}</dd>
                          </dl>
                        </td>
                      </tr>
                    )}
                  </Fragment>
                ))}
              </tbody>
            </table>
          </div>

          <ul className="lg:hidden grid md:grid-cols-2 gap-2 px-3">
            {paged.slice.map(({ m, rtLamp, paired, needsBoard, last }) => (
              <li key={m.id} className="rounded-[12px] border border-slate-200 bg-white p-3 flex flex-col gap-2.5">
                <div className="flex justify-between gap-2">
                  <div className="min-w-0">
                    <div className="font-bold text-ink">{m.name || '—'}</div>
                    <div className={`text-[13px] break-all ${m.owner_email ? 'text-slate-600' : 'text-rose-700 font-bold'}`}>
                      {t('apparatus_no')}{m.id} · {m.owner_email || t('devices_no_owner')}
                    </div>
                  </div>
                  <span className="text-xs text-slate-600 whitespace-nowrap">{ago(last, t, i18n.language)}</span>
                </div>
                <div className="flex flex-wrap items-center gap-1.5">
                  <DeviceStatusDot status={m.heartbeat} kind={m.kind} withLabel rt={rtLamp} rtRow={m.rt} />
                  <KindSelect kind={m.kind} onChange={(k) => onChangeKind(m.id, k)} />
                  {needsBoard && !paired && <Pill tone="amber">{t('adm_unpaired')}</Pill>}
                </div>
                <DeviceActions m={m} wide onTransfer={onTransfer} onDelete={onDelete} />
              </li>
            ))}
          </ul>

          <div className="p-4 sm:px-5">
            <Pagination page={paged.page} pageSize={paged.size} total={paged.total} onPage={paged.setPage} sizes={PAGE_SIZES} onPageSize={paged.setSize} />
          </div>
        </>
      )}
    </Card>
  );
}

function UsersTable({ users, devices, currentUserId, onChangePassword, onDeleteUser, onTransfer }) {
  const { t, i18n } = useTranslation();
  const [q, setQ] = useState('');
  const [open, setOpen] = useState(null);

  const byOwner = new Map();
  for (const m of devices ?? []) {
    const key = m.owner_id || '__none__';
    if (!byOwner.has(key)) byOwner.set(key, []);
    byOwner.get(key).push(m);
  }
  const shown = (users ?? []).filter((u) => matches(q, u.email, u.full_name));
  const paged = usePaged(shown);
  useEffect(() => { paged.setPage(1); }, [q]);
  const orphans = byOwner.get('__none__') ?? [];

  const deviceList = (list) => (
    <ul className="flex flex-col gap-1.5">
      {list.map((m) => (
        <li key={m.id} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2 rounded-[8px] bg-white border border-slate-200">
          <span className="min-w-0 text-sm">
            <span className="font-bold">{m.name || `${t('apparatus_no')}${m.id}`}</span>
            <span className="text-slate-600"> · {t('apparatus_no')}{m.id} · {kindLabel(m.kind, t)}</span>
          </span>
          <Button variant="soft" size="sm" icon={ArrowLeftRight} onClick={() => onTransfer(m)}>{t('transfer_short')}</Button>
        </li>
      ))}
    </ul>
  );

  return (
    <div className="flex flex-col gap-6">
      <Card>
        <div className="p-4 sm:px-5">
          <SearchInput value={q} onChange={setQ} placeholder={t('users_search')} className="w-full sm:w-96" />
        </div>
        {users == null ? (
          <div className="px-4 pb-4"><SkeletonRows rows={5} /></div>
        ) : shown.length === 0 ? (
          <EmptyState title={users.length === 0 ? t('no_users') : t('nothing_found')} />
        ) : (
          <>
            <ul className="flex flex-col divide-y divide-slate-200 border-y border-slate-200">
              {paged.slice.map((u) => {
                const owned = byOwner.get(u.id) ?? [];
                const isOpen = open === u.id;
                const superadmin = u.role === 'superadmin';
                return (
                  <li key={u.id} className={isOpen ? 'bg-slate-50' : ''}>
                    <div className="flex flex-wrap items-center gap-3 px-4 sm:px-5 py-3">
                      <div className={`w-10 h-10 rounded-full flex items-center justify-center text-sm font-extrabold shrink-0 ${superadmin ? 'bg-amber-400 text-ink' : 'bg-slate-200 text-slate-700'}`}>
                        {(u.email || '?').charAt(0).toUpperCase()}
                      </div>
                      <div className="flex-1 min-w-[180px]">
                        <div className="font-bold text-ink break-all">{u.email}</div>
                        <div className="text-[13px] text-slate-600">
                          {u.full_name ? `${u.full_name} · ` : ''}
                          {t('user_since')} {u.created_at ? new Date(u.created_at).toLocaleDateString(i18n.language) : '—'}
                        </div>
                      </div>
                      <Pill tone={superadmin ? 'amber' : 'slate'}>{superadmin ? t('role_superadmin') : t('role_owner')}</Pill>
                      <button
                        type="button"
                        onClick={() => setOpen(isOpen ? null : u.id)}
                        aria-expanded={isOpen}
                        disabled={owned.length === 0}
                        className={`inline-flex items-center gap-1.5 min-h-9 px-3 rounded-[8px] border text-[13px] font-bold transition-colors focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300 disabled:cursor-default ${isOpen ? 'border-blue-200 bg-blue-50 text-brand-dark' : 'border-slate-200 bg-white text-slate-700 hover:border-slate-300'}`}
                      >
                        {t('devices_n', { count: u.machines ?? owned.length })}
                        {owned.length > 0 && <ChevronDown size={14} className={`transition-transform ${isOpen ? 'rotate-180' : ''}`} />}
                      </button>
                      <div className="flex gap-1.5 ml-auto sm:ml-0">
                        <Button size="sm" icon={KeyRound} onClick={() => onChangePassword(u)}>
                          <span className="hidden sm:inline">{t('change_password')}</span>
                        </Button>
                        {/* Deleting your own account would lock you out of the
                            panel — the function refuses it too. */}
                        <IconButton icon={Trash2} label={t('delete')} tone="danger" onClick={() => onDeleteUser(u)} disabled={u.id === currentUserId} />
                      </div>
                    </div>
                    {isOpen && owned.length > 0 && (
                      <div className="px-4 sm:px-5 pb-4 sm:pl-[4.25rem]">{deviceList(owned)}</div>
                    )}
                  </li>
                );
              })}
            </ul>
            <div className="p-4 sm:px-5">
              <Pagination page={paged.page} pageSize={paged.size} total={paged.total} onPage={paged.setPage} sizes={PAGE_SIZES} onPageSize={paged.setSize} />
            </div>
          </>
        )}
      </Card>

      {/* Machines with no owner have no profile to hide under — surface them
          separately so they can still be assigned or removed. */}
      {orphans.length > 0 && (
        <Card className="p-4 sm:p-5 border-rose-200">
          <h2 className="text-lg font-bold text-rose-800">{t('devices_no_owner')} ({orphans.length})</h2>
          <p className="text-sm text-slate-600 mb-3">{t('devices_no_owner_hint')}</p>
          {deviceList(orphans)}
        </Card>
      )}
    </div>
  );
}
