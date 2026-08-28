-- ============================================================
-- Снятие пометки об отвязке переезжает в verify_pairing.
--
-- 20260828120000 повесило это на accept_admin_release — новую функцию,
-- которую вызывает только новая сборка планшета. Миграция ушла на прод
-- раньше приложения, и получилось окно, в котором отвязанный планшет со
-- старой сборкой заперт: claim_machine ему отказывает, снять пометку он не
-- умеет, и «Подключить» бесконечно отвечает «аппарат уже используется».
-- Поймано на живом планшете через десять минут после применения.
--
-- Сигнал, который был нужен, всё это время существовал: verify_pairing.
-- Её вызывает экран подключения ЛЮБОЙ версии, и только он — по нажатию
-- кнопки, когда номер и ключ уже введены руками. Ровно то же намерение,
-- ради которого заводилась accept_admin_release, но доступное всему парку
-- немедленно и без обновления.
--
-- Да, проверочная функция теперь пишет. Это осознанно: другого места, где
-- сервер узнаёт «человек стоит у аппарата и вводит его учётные данные», в
-- протоколе нет.
--
-- Безопасность не меняется. Пометка и так отказывает ровно одному планшету,
-- а сюда нельзя попасть, не зная секрет машины — с ним и без пометки можно
-- привязаться. Чужой планшет, вводящий тот же секрет, снимет пометку и
-- заберёт аппарат: это не обход, а нормальная замена, ради которой владелец
-- кнопку и нажимал.
--
-- Случай «аппарат занят другим планшетом» сюда не доходит: _assert_machine
-- с p_check_claim = true бросает 42501 раньше, чем очистка успевает
-- выполниться.
-- ============================================================

create or replace function public.verify_pairing(p_machid bigint, p_secret text)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_kind text;
begin
  perform public._assert_machine(p_machid, p_secret);

  -- Учётные данные ввели руками — значит, отвязку в панели отменяют
  -- осознанно. Условие в where только чтобы не трогать строку впустую:
  -- у подавляющего большинства машин пометки нет никогда.
  update public.device_status
     set released_device_id = null,
         released_at        = null,
         updated_at         = now()
   where machid = p_machid
     and released_device_id is not null;

  select kind into v_kind from public.micromarkets where id = p_machid;
  return v_kind;
end;
$$;

revoke execute on function public.verify_pairing(bigint, text)
  from public, authenticated;
grant  execute on function public.verify_pairing(bigint, text) to anon;

-- accept_admin_release больше не нужна: её работу делает verify_pairing,
-- причём для всех сборок сразу. Оставлять вторую дверь к тому же замку —
-- значит однажды чинить только одну из них.
drop function if exists public.accept_admin_release(bigint, text, text);
