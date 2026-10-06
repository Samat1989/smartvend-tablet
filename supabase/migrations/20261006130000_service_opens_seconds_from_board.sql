-- ============================================================
-- service_opens.seconds: фактическое время от платы, 1…600
--
-- С прошивки esp-rt 1.0.1 панель не выбирает длительность: плата открывает
-- замок на своё время из портала настройки (opensec, 1…600) и сообщает его
-- в ответе opened, а service-open-request записывает его сюда. Ограничение
-- 10…600 из 20260904120000 осталось от выбора 1/3/5 минут в панели и молча
-- отбрасывало запись, когда у платы открытие короче 10 секунд, — в журнале
-- оставалось 180 по умолчанию.
-- ============================================================

alter table public.service_opens drop constraint if exists service_opens_seconds_check;
alter table public.service_opens add constraint service_opens_seconds_check
  check (seconds between 1 and 600);
