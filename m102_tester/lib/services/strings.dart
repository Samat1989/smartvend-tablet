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
    'kind_mismatch': {
      'ru': 'Это не вендинг-аппарат. Используйте приложение, '
          'соответствующее типу аппарата.',
      'kk': 'Бұл вендинг-аппарат емес. Аппарат түріне сәйкес '
          'қосымшаны пайдаланыңыз.',
      'en': 'This is not a vending machine. Use the app that matches the '
          'machine type.',
    },
    // Home / catalog
    'app_title': {'ru': 'Вендинг', 'kk': 'Вендинг', 'en': 'Vending'},
    'choose_product': {
      'ru': 'Выберите товар',
      'kk': 'Тауарды таңдаңыз',
      'en': 'Choose a product',
    },
    'cart': {'ru': 'Корзина', 'kk': 'Себет', 'en': 'Cart'},
    'cart_empty': {'ru': 'Корзина пуста', 'kk': 'Себет бос', 'en': 'Cart is empty'},
    // Compact unit label after the cart count, e.g. "2 товара" / "2 öнім" / "2 items".
    'items_short': {'ru': 'товара', 'kk': 'өнім', 'en': 'items'},
    'cart_total': {'ru': 'Итого', 'kk': 'Барлығы', 'en': 'Total'},
    'pay_btn': {'ru': 'Оплатить', 'kk': 'Төлеу', 'en': 'Pay'},
    'pay_via_kaspi': {'ru': 'Оплатить через Kaspi', 'kk': 'Kaspi арқылы төлеу', 'en': 'Pay with Kaspi'},
    'clear_cart': {'ru': 'Очистить', 'kk': 'Тазалау', 'en': 'Clear'},
    'out_of_stock': {'ru': 'нет', 'kk': 'жоқ', 'en': 'out'},
    'in_stock': {'ru': 'осталось', 'kk': 'қалды', 'en': 'left'},
    'unmapped_slot': {'ru': 'не назначено', 'kk': 'бекітілмеген', 'en': 'not assigned'},
    'shelf': {'ru': 'Ячейка', 'kk': 'Ұяшық', 'en': 'Shelf'},
    'pcs': {'ru': 'шт', 'kk': 'дана', 'en': 'pcs'},
    'currency': {'ru': '₸', 'kk': '₸', 'en': '₸'},
    // Connection / status
    'board_ok': {'ru': 'Плата OK', 'kk': 'Плата OK', 'en': 'Board OK'},
    'board_connect': {'ru': 'Подключить', 'kk': 'Қосу', 'en': 'Connect'},
    'board_not_found': {
      'ru': 'USB-адаптер не найден. Проверьте подключение.',
      'kk': 'USB-адаптер табылмады. Қосылымды тексеріңіз.',
      'en': 'USB adapter not found. Check the cable.',
    },
    // Payment
    'payment_title': {'ru': 'Оплата', 'kk': 'Төлем', 'en': 'Payment'},
    'scan_qr_kaspi': {
      'ru': 'Отсканируйте QR-код в приложении Kaspi',
      'kk': 'Kaspi қосымшасында QR кодты сканерлеңіз',
      'en': 'Scan the QR code in the Kaspi app',
    },
    'waiting_payment': {'ru': 'Ожидание оплаты…', 'kk': 'Төлемді күту…', 'en': 'Waiting for payment…'},
    'payment_success': {'ru': 'Оплачено', 'kk': 'Төленді', 'en': 'Paid'},
    'payment_failed': {'ru': 'Оплата не прошла', 'kk': 'Төлем өтпеді', 'en': 'Payment failed'},
    'payment_expired': {'ru': 'Время ожидания истекло', 'kk': 'Күту уақыты бітті', 'en': 'Payment expired'},
    'payment_cancel': {'ru': 'Отменить', 'kk': 'Болдырмау', 'en': 'Cancel'},
    'try_again': {'ru': 'Повторить', 'kk': 'Қайталау', 'en': 'Try again'},
    // Dispense
    'dispense_title': {'ru': 'Выдача товара', 'kk': 'Тауар беру', 'en': 'Dispensing'},
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
    'wrong_pin': {'ru': 'Неверный PIN', 'kk': 'Қате PIN', 'en': 'Wrong PIN'},
    'service_test_motors': {
      'ru': 'Тест моторов',
      'kk': 'Моторларды тексеру',
      'en': 'Test motors',
    },
    'service_climate': {
      'ru': 'Холодильник',
      'kk': 'Тоңазытқыш',
      'en': 'Refrigeration',
    },
    'service_unpair': {'ru': 'Сбросить пэйринг', 'kk': 'Қосылымды тастау', 'en': 'Reset pairing'},
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
    'board_disconnect': {'ru': 'Отключить', 'kk': 'Ажырату', 'en': 'Disconnect'},
    'board_reconnect': {'ru': 'Подключить', 'kk': 'Қосу', 'en': 'Reconnect'},
    'board_slave_addr': {'ru': 'Адрес', 'kk': 'Мекенжайы', 'en': 'Addr'},
    'service_machine_id': {'ru': 'Аппарат №', 'kk': 'Аппарат №', 'en': 'Machine #'},
    'service_inventory': {
      'ru': 'Товары и слоты',
      'kk': 'Тауарлар мен слоттар',
      'en': 'Products & slots',
    },
    'service_layout': {
      'ru': 'Раскладка каталога',
      'kk': 'Каталог орналасуы',
      'en': 'Catalog layout',
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
    'sensor_priority': {
      'ru': 'Приоритет',
      'kk': 'Басымдылық',
      'en': 'Priority',
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
    'test_mode_override': {
      'ru': 'Режим теста',
      'kk': 'Тест режимі',
      'en': 'Test mode',
    },
    'tap_to_test': {
      'ru': 'Нажмите на слот для теста',
      'kk': 'Тексеру үшін слотты басыңыз',
      'en': 'Tap a slot to test it',
    },
    'testing_motor': {
      'ru': 'Тест мотора',
      'kk': 'Мотор тексерілуде',
      'en': 'Testing motor',
    },
    'layout_columns': {
      'ru': 'Товаров в строке',
      'kk': 'Жолдағы тауарлар саны',
      'en': 'Products per row',
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
    'inv_tap_to_edit': {
      'ru': 'Нажмите на слот для редактирования',
      'kk': 'Өңдеу үшін слотты басыңыз',
      'en': 'Tap a slot to edit',
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
    'field_name': {'ru': 'Название', 'kk': 'Атауы', 'en': 'Name'},
    'field_price': {'ru': 'Цена, ₸', 'kk': 'Бағасы, ₸', 'en': 'Price, ₸'},
    'field_stock': {'ru': 'Остаток, шт', 'kk': 'Қалдық, дана', 'en': 'Stock, pcs'},
    'field_emoji': {'ru': 'Эмодзи (необязательно)', 'kk': 'Эмодзи (қаласа)', 'en': 'Emoji (optional)'},
    'field_image_url': {
      'ru': 'URL изображения (необязательно)',
      'kk': 'Сурет URL (қаласа)',
      'en': 'Image URL (optional)',
    },
    'field_motor_type': {
      'ru': 'Тип мотора',
      'kk': 'Мотор түрі',
      'en': 'Motor type',
    },
    'motor_type_2': {'ru': '2-проводный', 'kk': '2 сымды', 'en': '2-wire'},
    'motor_type_3': {'ru': '3-проводный', 'kk': '3 сымды', 'en': '3-wire'},
    'field_curtain': {
      'ru': 'Датчик падения',
      'kk': 'Құлау сенсоры',
      'en': 'Drop sensor',
    },
    'curtain_off': {'ru': 'Выключен', 'kk': 'Өшірулі', 'en': 'Off'},
    'curtain_standard': {'ru': 'Обычный', 'kk': 'Қалыпты', 'en': 'Standard'},
    'curtain_priority': {'ru': 'Приоритетный', 'kk': 'Басымдылықпен', 'en': 'Priority'},
    'btn_test_motor': {
      'ru': 'Тест мотора',
      'kk': 'Моторды тексеру',
      'en': 'Test motor',
    },
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
    // Drop-sensor (light-curtain) standalone test
    'btn_test_sensor': {
      'ru': 'Тест датчика падения',
      'kk': 'Құлау сенсорын тексеру',
      'en': 'Test drop sensor',
    },
    'sensor_ok': {
      'ru': 'Датчик работает: падение зафиксировано',
      'kk': 'Сенсор жұмыс істейді: құлау тіркелді',
      'en': 'Sensor works: drop detected',
    },
    'sensor_no_drop': {
      'ru':
          'Мотор отработал, падение не обнаружено. Датчик скорее всего жив, '
              'но товар не упал в зону луча (пустой слот, застрял или датчик смещён).',
      'kk':
          'Мотор аяқталды, бірақ құлау тіркелмеді. Сенсор тірі болуы мүмкін, '
              'бірақ тауар сәуле аймағына түспеді.',
      'en':
          'Motor finished but no drop detected. Sensor is likely alive but the '
              'product did not pass through the beam (empty slot or misalignment).',
    },
    // Categories
    'all_categories': {
      'ru': 'Все',
      'kk': 'Барлығы',
      'en': 'All',
    },
    'field_category': {
      'ru': 'Категория',
      'kk': 'Санат',
      'en': 'Category',
    },
    'no_category': {
      'ru': 'Без категории',
      'kk': 'Санатсыз',
      'en': 'No category',
    },
    'no_products': {
      'ru': 'Нет товаров',
      'kk': 'Тауарлар жоқ',
      'en': 'No products',
    },
    'sensor_self_test_fail': {
      'ru':
          'Самотест датчика провалился (плата не получила сигнал с SIG). '
              'Проверьте: 24В на V1 во время выдачи, целостность проводов '
              'V1/SIG/GND, общая земля датчика и платы.',
      'kk':
          'Сенсордың өзін-өзі тексеруі сәтсіз аяқталды. V1-дегі 24В, '
              'V1/SIG/GND сымдары мен ортақ жерді тексеріңіз.',
      'en':
          'Sensor self-test failed (board got no SIG response). Check: 24V on '
              'V1 during dispense, integrity of V1/SIG/GND wires, common ground.',
    },
    // Loading / errors
    'loading': {'ru': 'Загрузка…', 'kk': 'Жүктелуде…', 'en': 'Loading…'},
    'reload': {'ru': 'Обновить', 'kk': 'Жаңарту', 'en': 'Reload'},
    'fetch_error': {'ru': 'Не удалось загрузить товары', 'kk': 'Тауарларды жүктеу сәтсіз', 'en': 'Failed to load products'},
  };
}
