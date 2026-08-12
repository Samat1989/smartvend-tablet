import 'package:flutter/foundation.dart';

import 'device_storage.dart';

/// Lightweight static i18n. Keys map to {ru, kk, en} entries; fallback is RU.
class Strings extends ChangeNotifier {
  Strings(this._storage) {
    _lang = _storage.language;
    _storage.addListener(_syncFromStorage);
  }

  final DeviceStorage _storage;
  String _lang = 'ru';
  String get lang => _lang;

  void _syncFromStorage() {
    if (_lang != _storage.language) {
      _lang = _storage.language;
      notifyListeners();
    }
  }

  Future<void> setLang(String code) async {
    if (!_messages.values.first.containsKey(code)) return;
    await _storage.setLanguage(code);
    // _syncFromStorage will fire via DeviceStorage listener.
  }

  String t(String key) {
    final entry = _messages[key];
    if (entry == null) return key;
    return entry[_lang] ?? entry['ru'] ?? key;
  }

  /// Localised label for a M102 motor-poll result code (per
  /// `docs/01_PROTOCOL.md` and `BoardClient.PollStatus.resultNames`).
  /// Returns the raw "Code N" form for unknown codes so faults are still
  /// distinguishable in the UI.
  String pollResult(int code) {
    switch (code) {
      case 0: return t('poll_ok');
      case 1: return t('poll_overload');
      case 2: return t('poll_wire_break');
      case 3: return t('poll_timeout');
      case 4: return t('poll_curtain_err');
      case 5: return t('poll_lock_not_open');
      case 10: return t('poll_microswitch');
      default: return 'Code $code';
    }
  }

  @override
  void dispose() {
    _storage.removeListener(_syncFromStorage);
    super.dispose();
  }

  static const Map<String, Map<String, String>> _messages = {
    // Pairing screen
    'pairing_title': {
      'ru': 'Подключение аппарата',
      'kk': 'Аппаратты қосу',
      'en': 'Device pairing',
    },
    'pairing_subtitle': {
      'ru': 'Введите номер аппарата и секретный ключ из панели владельца',
      'kk': 'Аппарат нөмірі мен иесінің панеліндегі құпия кілтті енгізіңіз',
      'en': 'Enter the machine number and secret key from the owner panel',
    },
    'machid_label': {'ru': 'Номер аппарата', 'kk': 'Аппарат нөмірі', 'en': 'Machine ID'},
    'secret_label': {'ru': 'Секретный ключ', 'kk': 'Құпия кілт', 'en': 'Secret key'},
    'connect_btn': {'ru': 'Подключить', 'kk': 'Қосу', 'en': 'Connect'},
    'verifying': {'ru': 'Проверка…', 'kk': 'Тексеру…', 'en': 'Verifying…'},
    // Home / catalog
    'cart': {'ru': 'Корзина', 'kk': 'Себет', 'en': 'Cart'},
    'cart_empty': {'ru': 'Корзина пуста', 'kk': 'Себет бос', 'en': 'Cart is empty'},
    // Compact unit label after the cart count, e.g. "2 товара" / "2 öнім" / "2 items".
    'items_short': {'ru': 'товара', 'kk': 'өнім', 'en': 'items'},
    'cart_total': {'ru': 'Итого', 'kk': 'Барлығы', 'en': 'Total'},
    'pay_btn': {'ru': 'Оплатить', 'kk': 'Төлеу', 'en': 'Pay'},
    // Caption over the right-hand shelf rail on the catalog.
    'shelves_caption': {'ru': 'полки', 'kk': 'сөрелер', 'en': 'shelves'},
    'currency': {'ru': '₸', 'kk': '₸', 'en': '₸'},
    // Connection / status
    'board_connect': {'ru': 'Подключить', 'kk': 'Қосу', 'en': 'Connect'},
    'board_not_found': {
      'ru': 'USB-адаптер не найден. Проверьте подключение.',
      'kk': 'USB-адаптер табылмады. Қосылымды тексеріңіз.',
      'en': 'USB adapter not found. Check the cable.',
    },
    // Payment
    'waiting_payment': {'ru': 'Ожидание оплаты…', 'kk': 'Төлемді күту…', 'en': 'Waiting for payment…'},
    'payment_failed': {'ru': 'Оплата не прошла', 'kk': 'Төлем өтпеді', 'en': 'Payment failed'},
    'payment_expired': {'ru': 'Время ожидания истекло', 'kk': 'Күту уақыты бітті', 'en': 'Payment expired'},
    'payment_cancel': {'ru': 'Отменить', 'kk': 'Болдырмау', 'en': 'Cancel'},
    'try_again': {'ru': 'Повторить', 'kk': 'Қайталау', 'en': 'Try again'},
    // Dispense
    'dispense_progress': {
      'ru': 'Идёт выдача… подождите',
      'kk': 'Беру жүріп жатыр… күтіңіз',
      'en': 'Dispensing… please wait',
    },
    'dispense_done': {'ru': 'Готово! Заберите товар', 'kk': 'Дайын! Тауарыңызды алыңыз', 'en': 'Done! Take your items'},
    'dispense_failed': {'ru': 'Выдача не удалась', 'kk': 'Беру сәтсіз аяқталды', 'en': 'Dispense failed'},
    'dispense_partial': {
      'ru': 'Завершено с ошибками',
      'kk': 'Қателермен аяқталды',
      'en': 'Completed with errors',
    },
    'home_btn': {'ru': 'На главную', 'kk': 'Басты бетке', 'en': 'Home'},
    'auto_return_in': {
      'ru': 'Возврат на главную через',
      'kk': 'Басты бетке оралу',
      'en': 'Returning home in',
    },
    'seconds_short': {'ru': 'сек', 'kk': 'сек', 'en': 's'},
    'refund_title': {'ru': 'Возврат', 'kk': 'Қайтару', 'en': 'Refund'},
    'refund_msg': {
      'ru': 'Покажите чек владельцу для возврата',
      'kk': 'Қайтару үшін иесіне түбіртекті көрсетіңіз',
      'en': 'Show the receipt to the owner for a refund',
    },
    // Service mode
    'service_mode': {'ru': 'Сервисный режим', 'kk': 'Сервистік режим', 'en': 'Service mode'},
    'enter_pin': {'ru': 'Введите PIN', 'kk': 'PIN енгізіңіз', 'en': 'Enter PIN'},
    'service_test_motors': {
      'ru': 'Настройка моторов',
      'kk': 'Моторларды баптау',
      'en': 'Motor setup',
    },
    'service_climate': {
      'ru': 'Холодильник',
      'kk': 'Тоңазытқыш',
      'en': 'Refrigeration',
    },
    // "Unpair" reads as jargon to the operator — from their side this is
    // simply signing the tablet out of the machine's account, after which
    // the pairing screen asks for the machine number and key again.
    'service_unpair': {
      'ru': 'Выйти из аккаунта',
      'kk': 'Аккаунттан шығу',
      'en': 'Sign out',
    },
    'service_storefront': {
      'ru': 'Витрина',
      'kk': 'Витрина',
      'en': 'Storefront',
    },
    'storefront_columns': {
      'ru': 'Товаров в строке',
      'kk': 'Жолдағы тауар саны',
      'en': 'Products per row',
    },
    'storefront_show_shelves': {
      'ru': 'Показывать названия полок',
      'kk': 'Сөре атауларын көрсету',
      'en': 'Show shelf names',
    },
    'storefront_show_shelves_hint': {
      'ru': 'Заголовок с номером и названием полки над каждым рядом. '
          'Выключите, если полки на автомате не подписаны.',
      'kk': 'Әр қатардың үстінде сөре нөмірі мен атауы бар тақырып. '
          'Аппаратта сөрелер белгіленбесе, өшіріңіз.',
      'en': 'A header with the shelf number and name above each row. '
          'Turn off if the cabinet shelves are not labelled.',
    },
    'ss_settings': {
      'ru': 'Настройки заставки',
      'kk': 'Скринсейвер баптаулары',
      'en': 'Attract loop settings',
    },
    'ss_delay': {
      'ru': 'Запускать после простоя',
      'kk': 'Тоқтап тұрғаннан кейін іске қосу',
      'en': 'Start after idle',
    },
    'ss_slide': {
      'ru': 'Держать слайд',
      'kk': 'Слайдты ұстау',
      'en': 'Slide duration',
    },
    'ss_wait_video': {
      'ru': 'Досматривать видео до конца',
      'kk': 'Бейнені соңына дейін көрсету',
      'en': 'Play videos to the end',
    },
    'ss_wait_video_hint': {
      'ru': 'Ролик доиграет полностью, и только потом включится следующая '
          'заставка. Если выключить — видео оборвётся по времени слайда.',
      'kk': 'Ролик толық ойналады, содан кейін ғана келесі слайд қосылады. '
          'Өшірсеңіз — бейне слайд уақыты бойынша үзіледі.',
      'en': 'A clip finishes before the next slide comes up. With this off '
          'the video is cut at the slide duration.',
    },
    'ss_sec': {'ru': 'сек', 'kk': 'сек', 'en': 's'},
    'ss_min': {'ru': 'мин', 'kk': 'мин', 'en': 'min'},
    'storefront_preview': {
      'ru': 'ПРЕДПРОСМОТР',
      'kk': 'АЛДЫН АЛА ҚАРАУ',
      'en': 'PREVIEW',
    },
    'storefront_preview_empty': {
      'ru': 'Каталог пуст — нечего показать',
      'kk': 'Каталог бос — көрсететін ештеңе жоқ',
      'en': 'Catalog is empty — nothing to show',
    },
    'storefront_show_slot': {
      'ru': 'Показывать номер ячейки',
      'kk': 'Ұяшық нөмірін көрсету',
      'en': 'Show slot number',
    },
    'storefront_show_slot_hint': {
      'ru': 'На карточке товара появится номер ячейки из раскладки. '
          'Если у товара нет фото, номер покажется вместо картинки. '
          'Включайте, если ячейки на дверце пронумерованы.',
      'kk': 'Тауар картасында раскладкадағы ұяшық нөмірі шығады. '
          'Тауардың фотосы болмаса, нөмір суреттің орнына көрсетіледі. '
          'Есіктегі ұяшықтар нөмірленген болса қосыңыз.',
      'en': 'Product cards get the slot number from the layout. Cards '
          'without a photo show the number in place of the picture. '
          'Turn on if the cabinet doors are numbered.',
    },
    'storefront_slot_no_layout': {
      'ru': 'Раскладка ещё не задана — номера показывать не из чего. '
          'Откройте «Редактор раскладки».',
      'kk': 'Раскладка әлі жасалмаған — нөмір алатын жер жоқ. '
          '«Раскладка редакторын» ашыңыз.',
      'en': 'No layout yet — there are no numbers to show. Open the '
          'layout editor first.',
    },
    'service_unpair_hint': {
      'ru': 'Планшет отвяжется от аппарата. Чтобы вернуться к работе, '
          'нужно будет снова ввести номер аппарата и секретный ключ.',
      'kk': 'Планшет аппараттан ажыратылады. Жұмысқа оралу үшін аппарат '
          'нөмірі мен құпия кілтті қайта енгізу қажет болады.',
      'en': 'The tablet will be unlinked from the machine. To resume, you '
          'will have to enter the machine number and secret key again.',
    },
    'service_exit_kiosk': {
      'ru': 'Выйти в Android',
      'kk': 'Android-қа шығу',
      'en': 'Exit to Android',
    },
    'service_exit_kiosk_confirm': {
      'ru': 'Откроется системное меню Android. Приложение вернётся в '
          'режим киоска при следующем открытии.',
      'kk': 'Android жүйелік мәзірі ашылады. Қосымша келесі ашылғанда '
          'қайтадан киоск режиміне көшеді.',
      'en': 'The Android system menu will open. The app re-enters '
          'kiosk mode the next time it is brought to the foreground.',
    },
    'service_change_pin': {'ru': 'Сменить PIN', 'kk': 'PIN өзгерту', 'en': 'Change PIN'},
    'service_m102_password': {
      'ru': 'CRC-пароль M102',
      'kk': 'M102 CRC құпиясөзі',
      'en': 'M102 CRC password',
    },
    'service_board': {'ru': 'Плата', 'kk': 'Плата', 'en': 'Board'},
    'service_layout_editor': {
      'ru': 'Раскладка слотов',
      'kk': 'Слоттар орналасуы',
      'en': 'Slot layout',
    },
    'service_screensaver_media': {
      'ru': 'Заставка / Медиа',
      'kk': 'Скринсейвер / Медиа',
      'en': 'Screensaver media',
    },
    'board_disconnect': {'ru': 'Отключить', 'kk': 'Ажырату', 'en': 'Disconnect'},
    'board_reconnect': {'ru': 'Подключить', 'kk': 'Қосу', 'en': 'Reconnect'},
    'board_slave_addr': {'ru': 'Адрес', 'kk': 'Мекенжайы', 'en': 'Addr'},
    'service_machine_id': {'ru': 'Аппарат №', 'kk': 'Аппарат №', 'en': 'Machine #'},
    'service_inventory': {
      'ru': 'Товары',
      'kk': 'Тауарлар',
      'en': 'Products',
    },
    'service_sensor_mode': {
      'ru': 'Режим выдачи',
      'kk': 'Беру режимі',
      'en': 'Dispense mode',
    },
    'sensor_off': {
      'ru': 'Без датчика',
      'kk': 'Сенсорсыз',
      'en': 'Without sensor',
    },
    'sensor_on': {
      'ru': 'С датчиком',
      'kk': 'Сенсормен',
      'en': 'With sensor',
    },
    'sensor_mode_hint': {
      'ru':
          'Применяется ко всем слотам. «С датчиком» делает рефанд если '
              'товар не упал в зону луча после оборота мотора.',
      'kk':
          'Барлық слоттарға қолданылады. «Сенсормен» — мотор айналғаннан '
              'кейін тауар сәуле аймағына түспесе, ақша қайтарылады.',
      'en':
          'Applied to every slot. "With sensor" issues a refund when the '
              'motor finished but the drop sensor never triggered.',
    },
    // Inventory editor
    'inv_grid_title': {
      'ru': 'Карта слотов',
      'kk': 'Слот картасы',
      'en': 'Slot map',
    },
    'inv_empty_slot': {
      'ru': 'пусто',
      'kk': 'бос',
      'en': 'empty',
    },
    'product_edit_title': {
      'ru': 'Редактирование товара',
      'kk': 'Тауарды өңдеу',
      'en': 'Edit product',
    },
    'product_new_title': {
      'ru': 'Новый товар',
      'kk': 'Жаңа тауар',
      'en': 'New product',
    },
    'field_price': {'ru': 'Цена, ₸', 'kk': 'Бағасы, ₸', 'en': 'Price, ₸'},
    'field_stock': {'ru': 'Остаток, шт', 'kk': 'Қалдық, дана', 'en': 'Stock, pcs'},
    'curtain_off': {'ru': 'Выключен', 'kk': 'Өшірулі', 'en': 'Off'},
    'curtain_standard': {'ru': 'Обычный', 'kk': 'Қалыпты', 'en': 'Standard'},
    'curtain_priority': {'ru': 'Приоритетный', 'kk': 'Басымдылықпен', 'en': 'Priority'},
    'btn_save': {'ru': 'Сохранить', 'kk': 'Сақтау', 'en': 'Save'},
    'btn_delete': {'ru': 'Удалить', 'kk': 'Жою', 'en': 'Delete'},
    'confirm_delete': {
      'ru': 'Удалить товар из этого слота?',
      'kk': 'Бұл слоттан тауарды жою керек пе?',
      'en': 'Delete the product from this slot?',
    },
    'save_failed': {
      'ru': 'Не удалось сохранить',
      'kk': 'Сақталмады',
      'en': 'Save failed',
    },
    'save_ok': {
      'ru': 'Сохранено',
      'kk': 'Сақталды',
      'en': 'Saved',
    },
    'name_required': {
      'ru': 'Введите название',
      'kk': 'Атауын енгізіңіз',
      'en': 'Name is required',
    },
    'motor_label': {'ru': 'Мотор', 'kk': 'Мотор', 'en': 'Motor'},
    // Board status / health
    'board_firmware': {'ru': 'Прошивка', 'kk': 'Прошивка', 'en': 'Firmware'},
    'board_status': {'ru': 'Связь с платой', 'kk': 'Платамен байланыс', 'en': 'Board link'},
    'board_health_ok': {'ru': 'Норма', 'kk': 'Қалыпты', 'en': 'Healthy'},
    'board_health_lost': {
      'ru': 'Связь потеряна',
      'kk': 'Байланыс жоғалды',
      'en': 'Communication lost',
    },
    'maintenance_title': {
      'ru': 'Технический перерыв',
      'kk': 'Техникалық үзіліс',
      'en': 'Out of service',
    },
    'maintenance_subtitle': {
      'ru': 'Аппарат не отвечает. Пожалуйста, попробуйте позже.',
      'kk': 'Аппарат жауап бермейді. Кейінірек қайталап көріңіз.',
      'en': 'The machine is unresponsive. Please try again later.',
    },
    // Poll result codes — surfaced when a motor fails
    'poll_ok': {'ru': 'OK', 'kk': 'OK', 'en': 'OK'},
    'poll_overload': {'ru': 'Перегрузка', 'kk': 'Шамадан тыс жүктеме', 'en': 'Overload'},
    'poll_wire_break': {'ru': 'Обрыв провода', 'kk': 'Сымның үзілуі', 'en': 'Wire break'},
    'poll_timeout': {'ru': 'Таймаут', 'kk': 'Таймаут', 'en': 'Timeout'},
    'poll_curtain_err': {
      'ru': 'Ошибка датчика падения',
      'kk': 'Құлау сенсорының қатесі',
      'en': 'Drop sensor error',
    },
    'poll_lock_not_open': {
      'ru': 'Замок не открыт',
      'kk': 'Құлып ашылмады',
      'en': 'Lock did not open',
    },
    'poll_microswitch': {
      'ru': 'Микропереключатель не сработал',
      'kk': 'Микроқосқыш іске қосылмады',
      'en': 'Micro-switch never pressed',
    },
    // Categories
    'no_products': {
      'ru': 'Нет товаров',
      'kk': 'Тауарлар жоқ',
      'en': 'No products',
    },
    // Loading / errors
    'reload': {'ru': 'Обновить', 'kk': 'Жаңарту', 'en': 'Reload'},
    'fetch_error': {'ru': 'Не удалось загрузить товары', 'kk': 'Тауарларды жүктеу сәтсіз', 'en': 'Failed to load products'},
    'fetch_retrying': {
      'ru': 'Повторная попытка выполняется автоматически…',
      'kk': 'Қайта әрекет автоматты түрде жасалады…',
      'en': 'Retrying automatically…',
    },
    // Customer support
    'support': {'ru': 'Помощь', 'kk': 'Көмек', 'en': 'Help'},
    'support_title': {
      'ru': 'Служба поддержки',
      'kk': 'Қолдау қызметі',
      'en': 'Customer support',
    },
    'support_intro': {
      'ru': 'Товар не выдался или деньги списались дважды? '
          'Позвоните или напишите — разберёмся и вернём.',
      'kk': 'Тауар шықпады ма, әлде ақша екі рет шегерілді ме? '
          'Қоңырау шалыңыз немесе жазыңыз — шешеміз және қайтарамыз.',
      'en': 'Item never dropped, or charged twice? '
          'Call or message us — we will sort it out and refund you.',
    },
    'support_machine': {
      'ru': 'Номер аппарата',
      'kk': 'Аппарат нөмірі',
      'en': 'Machine number',
    },
    'support_machine_hint': {
      'ru': 'Назовите этот номер оператору — по нему мы найдём вашу покупку',
      'kk': 'Осы нөмірді операторға айтыңыз — ол бойынша сатып алуыңызды табамыз',
      'en': 'Give this number to the operator — we find your purchase by it',
    },
    'support_phone_label': {'ru': 'Телефон', 'kk': 'Телефон', 'en': 'Phone'},
    'support_hours_label': {
      'ru': 'Время работы',
      'kk': 'Жұмыс уақыты',
      'en': 'Working hours',
    },
    'support_whatsapp_hint': {
      'ru': 'Наведите камеру телефона, чтобы написать в WhatsApp',
      'kk': 'WhatsApp-қа жазу үшін телефон камерасын бағыттаңыз',
      'en': 'Point your phone camera here to message us on WhatsApp',
    },
    // Service mode — support contact editor
    'service_support': {
      'ru': 'Поддержка',
      'kk': 'Қолдау',
      'en': 'Support',
    },
    'support_settings_title': {
      'ru': 'Контакты поддержки',
      'kk': 'Қолдау байланыстары',
      'en': 'Support contacts',
    },
    'support_settings_hint': {
      'ru': 'Показывается покупателю по кнопке «Помощь» в углу экрана. '
          'Пока телефон не указан, кнопка скрыта.',
      'kk': 'Экран бұрышындағы «Көмек» түймесі арқылы сатып алушыға '
          'көрсетіледі. Телефон көрсетілмейінше түйме жасырылады.',
      'en': 'Shown to the customer via the «Help» button in the screen '
          'corner. The button stays hidden until a phone is set.',
    },
    'support_field_phone': {
      'ru': 'Телефон поддержки',
      'kk': 'Қолдау телефоны',
      'en': 'Support phone',
    },
    'support_field_whatsapp': {
      'ru': 'WhatsApp, если отличается',
      'kk': 'WhatsApp, өзгеше болса',
      'en': 'WhatsApp, if different',
    },
    'support_field_hours': {
      'ru': 'Время работы',
      'kk': 'Жұмыс уақыты',
      'en': 'Working hours',
    },
    'support_hours_example': {
      'ru': 'Например: Пн–Пт, 9:00–18:00',
      'kk': 'Мысалы: Дс–Жм, 9:00–18:00',
      'en': 'For example: Mon–Fri, 9:00–18:00',
    },
  };
}
