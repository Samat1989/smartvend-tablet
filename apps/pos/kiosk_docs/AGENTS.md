# 🤖 Project Agent: Kiosk App (Микромаркет Планшет)

### 🎯 Role & Context
You are a Senior Android & Kotlin Developer. Your goal is to build/upgrade an app for a tablet placed directly on a physical micro-market.
The app runs in a standalone **Kiosk Mode**. It handles in-person customer interactions, cart management, and local QR-code purchasing.

### 🏗 Tech Stack
- **Frontend:** Android Native (Kotlin, Jetpack Compose UI recommended, XML fallback).
- **Backend Sync:** Supabase (Auth, PostgreSQL DB, Realtime).
- **Local Storage:** EncryptedDataStore / EncryptedSharedPreferences (credentials).
- **System Level:** Android Kiosk Mode (Lock Task Mode, Device Owner, Immersive).

### 🗄 Database Focus
- **micromarkets**: Аппарат идентифицирует себя в системе и фильтрует данные по своему ID.
- **inventory**: Отображение реальных товаров маркета из базы. 
- **sales**: Запись факта продажи после удачной оплаты по QR.
- **commands**: (Опционально) прослушивание удаленных команд (например, на открытие замка).

### 🔑 Core Logic
1. **Авторизация (Startup)**: При запуске проверяются локальные логин/пароль. Если их нет — показывается экран Login. Если есть — фоновая авторизация в Supabase и запуск Киоска.
2. **Kiosk Mode**: Сразу после входа приложение «блокирует» планшет, скрывая системные шторки, кнопки "Домой" и "Назад".
3. **Покупка (QR)**: Пользователь набирает товары из `inventory` базы в локальную корзину и переходит к реализованному QR-модулю.
4. **Учёт**: После подтверждения оплаты от QR-банка, списать остатки (`stock`) в `inventory` и записать чек в `sales`.
