# 🗄 Спецификация базы данных: Smartvend Ecosystem

**Проект:** Система управления микромаркетом (холодильником) через планшет (Android + USB Serial) и ESP32.
**Технологии:** Supabase (PostgreSQL), Realtime, Auth.

## 📌 Общая архитектура
- **POS App (Планшет):** Авторизуется по `id` и `secret`, пишет продажи в `sales`, слушает команды в `commands`, управляет ESP32 через USB (Serial).
- **Owner App (Приложение владельца):** Управляет товарами, смотрит выручку, создает команды на удаленное открытие.
- **ESP32:** Исполнительное устройство (принимает команды по USB от планшета).

---

## 🏗 Схема таблиц (Public Schema)

### 1. `profiles`
Данные владельцев. Связана с системной таблицей `auth.users`.
| Колонка | Тип | Описание |
| :--- | :--- | :--- |
| `id` | uuid (PK) | Ссылка на пользователя в Auth. |
| `email` | text | Почта владельца. |
| `full_name` | text | Имя владельца. |
| `updated_at` | timestamptz | Время последнего обновления. |

### 2. `micromarkets`
Реестр холодильников. Главная таблица для авторизации устройств.
| Колонка | Тип | Описание |
| :--- | :--- | :--- |
| `id` | bigint (PK) | **ID точки** (вводится на планшете вручную, напр. 1001). |
| `secret` | text | **Пароль точки** (вводится на планшете). |
| `owner_id` | uuid (FK) | Ссылка на `profiles.id`. |
| `name` | text | Название (напр. "Офис Google, 5 этаж"). |
| `location_name`| text | Адрес установки. |
| `status` | text | Текущее состояние (`active`, `maintenance`). |

### 3. `inventory`
Список товаров в конкретном холодильнике.
| Колонка | Тип | Описание |
| :--- | :--- | :--- |
| `id` | uuid (PK) | Уникальный ID товара. |
| `micromarket_id`| bigint (FK) | Привязка к конкретному холодильнику. |
| `name` | text | Название товара. |
| `price` | numeric | Цена товара. |
| `stock` | integer | Остаток в наличии. |
| `barcode` | text | Штрих-код товара. |
| `image_url` | text | Ссылка на фото товара. |

### 4. `sales`
Финансовый лог всех успешных транзакций (чеков).
| Колонка | Тип | Описание |
| :--- | :--- | :--- |
| `id` | uuid (PK) | ID транзакции (чека). |
| `micromarket_id`| bigint (FK) | Где совершена продажа. |
| `amount` | numeric | Итоговая сумма чека. |
| `status` | text | Статус продажи (напр., `completed`, `pending`). |
| `payment_id` | text | ID транзакции из банковского API (если есть). |
| `created_at` | timestamptz | Дата и время продажи. |

### 4.1. `sales_items`
Купленные позиции внутри одного чека (Связь 1:N).
| Колонка | Тип | Описание |
| :--- | :--- | :--- |
| id | uuid (PK) | Уникальный ID позиции продажи. |
| sale_id | uuid (FK) | Ссылка на чек (таблицу `sales`). |
| product_id | uuid (FK) | Ссылка на товар (таблицу `inventory`). |
| price | numeric | Цена за 1 шт. на момент продажи. |
| quantity | integer | Количество единиц товара в позиции (по умолчанию 1). |

### 5. `commands`
Шина управления и лог физических событий открытия двери.
| Колонка | Тип | Описание |
| :--- | :--- | :--- |
| `id` | uuid (PK) | ID команды. |
| `micromarket_id`| bigint (FK) | К какому устройству относится команда. |
| `command_type` | text | Тип: `SALE_OPEN` (продажа), `REMOTE_OPEN` (удаленно). |
| `status` | text | `pending` (ожидает), `success` (исполнено), `failed`. |
| `created_at` | timestamptz | Время создания команды. |
| `executed_at` | timestamptz | Время, когда планшет подтвердил открытие двери. |

---

## 🔐 Логика безопасности и автоматизации

### Авторизация Планшета
Планшет не использует логин/пароль пользователя. Он делает запрос:
`SELECT * FROM micromarkets WHERE id = [INPUT_ID] AND secret = '[INPUT_SECRET]'`
Если запись найдена, планшет сохраняет эти данные локально.

### Автоматическое создание профиля (Trigger)
При регистрации нового пользователя в Supabase Auth автоматически создается запись в `public.profiles` через SQL-триггер:
```sql
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name)
  VALUES (new.id, new.email, new.raw_user_meta_data->>'full_name');
  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;