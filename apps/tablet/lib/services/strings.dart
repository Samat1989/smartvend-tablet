import 'package:flutter/foundation.dart';

import 'device_storage.dart';

/// Lightweight static i18n. Keys map to {ru, kk, ky, en} entries; fallback
/// is RU. Which of those a cabinet offers depends on where it stands — see
/// [languages].
class Strings extends ChangeNotifier {
  Strings(this._storage) {
    _lang = _resolveLang();
    _currency = _storage.currencySymbol;
    _storage.addListener(_syncFromStorage);
  }

  final DeviceStorage _storage;
  String _lang = 'ru';
  String _currency = '';
  String get lang => _lang;

  /// Sign to print after a price. Deliberately not a translation: it follows
  /// the cabinet's payment channel, not the interface language — a Kyrgyz
  /// machine charges som whether the customer is reading Russian or English.
  String get currency => _currency;

  /// Languages offered here, in the order the switcher shows them.
  ///
  /// An unpaired tablet offers all four: the pairing screen is where the
  /// installer stands, and until they have ticked O!Dengi and connected,
  /// nothing yet says which country this cabinet is in.
  ///
  /// Once paired the list narrows to the machine's own country, then English,
  /// then Russian — Kazakh is dropped on a Kyrgyz cabinet and Kyrgyz on a
  /// Kazakh one. This is a customer's screen, and an option nobody standing
  /// in front of that machine reads costs more room than it gives. The
  /// payment channel decides, because it is what already knows the country.
  List<String> get languages {
    if (!_storage.isPaired) return const ['kk', 'ky', 'en', 'ru'];
    return _storage.isOdengi
        ? const ['ky', 'en', 'ru']
        : const ['kk', 'en', 'ru'];
  }

  /// Chip label. 'kk'/'ky' are ISO *language* codes, but on the machine they
  /// read as countries — a customer looks for KZ and KG, not KK and KY.
  static String label(String code) => switch (code) {
        'kk' => 'KZ',
        'ky' => 'KG',
        _ => code.toUpperCase(),
      };

  /// The stored language, clamped to what this cabinet offers. It is the
  /// clamp that carries a choice across pairing: an installer who picks KG
  /// on the pairing screen and then connects with the tick keeps Kyrgyz,
  /// and one who picks it without the tick lands back on Kazakh. Without
  /// it the switcher would be handed a selected value that is not among its
  /// segments — an assertion failure, not a cosmetic slip.
  String _resolveLang() {
    final offered = languages;
    final stored = _storage.language;
    return offered.contains(stored) ? stored : offered.first;
  }

  void _syncFromStorage() {
    final lang = _resolveLang();
    final currency = _storage.currencySymbol;
    if (_lang != lang || _currency != currency) {
      _lang = lang;
      _currency = currency;
      notifyListeners();
    }
  }

  Future<void> setLang(String code) async {
    if (!languages.contains(code)) return;
    await _storage.setLanguage(code);
    // _syncFromStorage will fire via DeviceStorage listener.
  }

  String t(String key) {
    // Not in the table — the currency follows the machine, not the language.
    // Routed through t() as well so the existing call sites keep working.
    if (key == 'currency') return _currency;
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
      'ky': 'Аппаратты туташтыруу',
      'en': 'Device pairing',
    },
    'pairing_subtitle': {
      'ru': 'Введите номер аппарата и секретный ключ из панели владельца',
      'kk': 'Аппарат нөмірі мен иесінің панеліндегі құпия кілтті енгізіңіз',
      'ky': 'Аппараттын номерин жана ээсинин панелиндеги купуя ачкычты '
          'киргизиңиз',
      'en': 'Enter the machine number and secret key from the owner panel',
    },
    'machid_label': {'ru': 'Номер аппарата', 'kk': 'Аппарат нөмірі', 'ky': 'Аппараттын номери', 'en': 'Machine ID'},
    'secret_label': {'ru': 'Секретный ключ', 'kk': 'Құпия кілт', 'ky': 'Купуя ачкыч', 'en': 'Secret key'},
    'connect_btn': {'ru': 'Подключить', 'kk': 'Қосу', 'ky': 'Туташтыруу', 'en': 'Connect'},
    'odengi_label': {
      'ru': 'O!Деньги (Кыргызстан)',
      'kk': 'O!Деньги (Қырғызстан)',
      'ky': 'O!Деньги (Кыргызстан)',
      'en': 'O!Dengi (Kyrgyzstan)'
    },
    'odengi_hint': {
      'ru': 'QR через O!Деньги, цены в сомах. Без галочки — Kaspi QR.',
      'kk': 'QR O!Деньги арқылы, бағалар сомда. Белгісіз — Kaspi QR.',
      'ky': 'QR O!Деньги аркылуу, баалар сом менен. Белгиленбесе — Kaspi '
          'QR.',
      'en': 'QR via O!Dengi, prices in som. Unchecked — Kaspi QR.'
    },
    'verifying': {'ru': 'Проверка…', 'kk': 'Тексеру…', 'ky': 'Текшерилүүдө…', 'en': 'Verifying…'},
    // Home / catalog
    'cart': {'ru': 'Корзина', 'kk': 'Себет', 'ky': 'Себет', 'en': 'Cart'},
    'cart_empty': {'ru': 'Корзина пуста', 'kk': 'Себет бос', 'ky': 'Себет бош', 'en': 'Cart is empty'},
    // Compact unit label after the cart count, e.g. "2 товара" / "2 öнім" / "2 items".
    'items_short': {'ru': 'товара', 'kk': 'өнім', 'ky': 'товар', 'en': 'items'},
    'cart_total': {'ru': 'Итого', 'kk': 'Барлығы', 'ky': 'Жалпы', 'en': 'Total'},
    'pay_btn': {'ru': 'Оплатить', 'kk': 'Төлеу', 'ky': 'Төлөө', 'en': 'Pay'},
    // Caption over the right-hand shelf rail on the catalog.
    'shelves_caption': {'ru': 'полки', 'kk': 'сөрелер', 'ky': 'текчелер', 'en': 'shelves'},
    // Connection / status
    'board_connect': {'ru': 'Подключить', 'kk': 'Қосу', 'ky': 'Туташтыруу', 'en': 'Connect'},
    'board_not_found': {
      'ru': 'USB-адаптер не найден. Проверьте подключение.',
      'kk': 'USB-адаптер табылмады. Қосылымды тексеріңіз.',
      'ky': 'USB-адаптер табылган жок. Туташууну текшериңиз.',
      'en': 'USB adapter not found. Check the cable.',
    },
    // Payment
    'waiting_payment': {'ru': 'Ожидание оплаты…', 'kk': 'Төлемді күту…', 'ky': 'Төлөм күтүлүүдө…', 'en': 'Waiting for payment…'},
    'payment_failed': {'ru': 'Оплата не прошла', 'kk': 'Төлем өтпеді', 'ky': 'Төлөм өткөн жок', 'en': 'Payment failed'},
    'payment_expired': {'ru': 'Время ожидания истекло', 'kk': 'Күту уақыты бітті', 'ky': 'Күтүү убакыты бүттү', 'en': 'Payment expired'},
    'payment_cancel': {'ru': 'Отменить', 'kk': 'Болдырмау', 'ky': 'Жокко чыгаруу', 'en': 'Cancel'},
    'try_again': {'ru': 'Повторить', 'kk': 'Қайталау', 'ky': 'Кайталоо', 'en': 'Try again'},
    // Dispense
    'dispense_progress': {
      'ru': 'Идёт выдача… подождите',
      'kk': 'Беру жүріп жатыр… күтіңіз',
      'ky': 'Берилүүдө… күтө туруңуз',
      'en': 'Dispensing… please wait',
    },
    'dispense_done': {'ru': 'Готово! Заберите товар', 'kk': 'Дайын! Тауарыңызды алыңыз', 'ky': 'Даяр! Товарыңызды алыңыз', 'en': 'Done! Take your items'},
    'dispense_failed': {'ru': 'Выдача не удалась', 'kk': 'Беру сәтсіз аяқталды', 'ky': 'Берүү ишке ашкан жок', 'en': 'Dispense failed'},
    'dispense_partial': {
      'ru': 'Завершено с ошибками',
      'kk': 'Қателермен аяқталды',
      'ky': 'Каталар менен аяктады',
      'en': 'Completed with errors',
    },
    'pay_not_configured': {
      'ru': 'Аппарат не настроен',
      'kk': 'Автомат бапталмаған',
      'ky': 'Аппарат жөндөлгөн эмес',
      'en': 'Machine is not configured',
    },
    'pay_time_expired': {
      'ru': 'Время оплаты истекло',
      'kk': 'Төлем уақыты аяқталды',
      'ky': 'Төлөм убакыты бүттү',
      'en': 'Payment time expired',
    },
    'pay_transaction_closed': {
      'ru': 'Транзакция закрыта',
      'kk': 'Транзакция жабылды',
      'ky': 'Транзакция жабылды',
      'en': 'Transaction closed',
    },
    'details_more': {'ru': 'Подробнее', 'kk': 'Толығырақ', 'ky': 'Толугураак', 'en': 'Details'},
    'dispense_board_lost': {
      'ru': 'Связь с платой потеряна — возврат средств',
      'kk': 'Платамен байланыс жоғалды — қаражат қайтарылады',
      'ky': 'Плата менен байланыш жоголду — акча кайтарылат',
      'en': 'Board link lost — refunding',
    },
    'dispense_timeout': {
      'ru': 'Превышено время выдачи',
      'kk': 'Беру уақыты асып кетті',
      'ky': 'Берүү убакыты ашып кетти',
      'en': 'Dispense timed out',
    },
    // Composed as "<label> <count>" so the number can follow the word in
    // all three languages without a per-language template.
    'dispense_sum_delivered': {'ru': 'Выдано', 'kk': 'Берілді', 'ky': 'Берилди', 'en': 'Delivered'},
    'dispense_sum_refund': {'ru': 'Возврат', 'kk': 'Қайтарым', 'ky': 'Кайтарым', 'en': 'Refund'},
    'sale_saving': {
      'ru': 'Сохранение продажи…',
      'kk': 'Сатылым сақталуда…',
      'ky': 'Сатуу сакталууда…',
      'en': 'Saving the sale…',
    },
    'tap_to_choose': {
      'ru': 'Коснитесь, чтобы выбрать',
      'kk': 'Таңдау үшін түртіңіз',
      'ky': 'Тандоо үчүн басыңыз',
      'en': 'Tap to choose',
    },
    'home_btn': {'ru': 'На главную', 'kk': 'Басты бетке', 'ky': 'Башкы бетке', 'en': 'Home'},
    'auto_return_in': {
      'ru': 'Возврат на главную через',
      'kk': 'Басты бетке оралу',
      'ky': 'Башкы бетке кайтуу',
      'en': 'Returning home in',
    },
    'seconds_short': {'ru': 'сек', 'kk': 'сек', 'ky': 'сек', 'en': 's'},
    // Micromarket: the door opens once and the customer serves themselves
    'unlock_opening': {'ru': 'Открываем…', 'kk': 'Ашылуда…', 'ky': 'Ачылууда…', 'en': 'Opening…'},
    'unlock_thanks': {
      'ru': 'Спасибо за покупку!',
      'kk': 'Сатып алғаныңыз үшін рахмет!',
      'ky': 'Сатып алганыңыз үчүн рахмат!',
      'en': 'Thank you for your purchase!',
    },
    'unlock_close_door': {
      'ru': 'Пожалуйста, закройте дверь',
      'kk': 'Есікті жабуды ұмытпаңыз',
      'ky': 'Сураныч, эшикти жабыңыз',
      'en': 'Please close the door',
    },
    'unlock_failed_hint': {
      'ru': 'Замок не открылся. Оплата не подтверждена и вернётся '
          'автоматически — обратитесь в поддержку.',
      'kk': 'Құлып ашылмады. Төлем расталмады және автоматты түрде '
          'қайтарылады — қолдау қызметіне хабарласыңыз.',
      'ky': 'Кулпу ачылган жок. Төлөм тастыкталган жок жана автоматтык '
          'түрдө кайтарылат — колдоо кызматына кайрылыңыз.',
      'en': 'The lock did not open. The payment was not captured and comes '
          'back automatically — please contact support.',
    },
    'pay_no_lock_link': {
      'ru': 'Нет связи с замком. Оплата не начата — обратитесь к оператору',
      'kk': 'Құлыппен байланыс жоқ. Төлем басталмады — операторға '
          'хабарласыңыз',
      'ky': 'Кулпу менен байланыш жок. Төлөм башталган жок — операторго '
          'кайрылыңыз',
      'en': 'No link to the lock. Payment was not started — please contact '
          'the operator',
    },
    'refund_title': {'ru': 'Возврат', 'kk': 'Қайтару', 'ky': 'Кайтаруу', 'en': 'Refund'},
    'refund_msg': {
      'ru': 'Покажите чек владельцу для возврата',
      'kk': 'Қайтару үшін иесіне түбіртекті көрсетіңіз',
      'ky': 'Кайтаруу үчүн ээсине чекти көрсөтүңүз',
      'en': 'Show the receipt to the owner for a refund',
    },
    // Service mode
    'service_mode': {'ru': 'Сервисный режим', 'kk': 'Сервистік режим', 'ky': 'Тейлөө режими', 'en': 'Service mode'},
    'enter_pin': {'ru': 'Введите PIN', 'kk': 'PIN енгізіңіз', 'ky': 'PIN киргизиңиз', 'en': 'Enter PIN'},
    'service_test_motors': {
      'ru': 'Настройка моторов',
      'kk': 'Моторларды баптау',
      'ky': 'Моторлорду жөндөө',
      'en': 'Motor setup',
    },
    'service_climate': {
      'ru': 'Холодильник',
      'kk': 'Тоңазытқыш',
      'ky': 'Муздаткыч',
      'en': 'Refrigeration',
    },
    // "Unpair" reads as jargon to the operator — from their side this is
    // simply signing the tablet out of the machine's account, after which
    // the pairing screen asks for the machine number and key again.
    'service_unpair': {
      'ru': 'Выйти из аккаунта',
      'kk': 'Аккаунттан шығу',
      'ky': 'Аккаунттан чыгуу',
      'en': 'Sign out',
    },
    'service_storefront': {
      'ru': 'Витрина',
      'kk': 'Витрина',
      'ky': 'Витрина',
      'en': 'Storefront',
    },
    'storefront_columns': {
      'ru': 'Товаров в строке',
      'kk': 'Жолдағы тауар саны',
      'ky': 'Саптагы товар саны',
      'en': 'Products per row',
    },
    'storefront_show_shelves': {
      'ru': 'Показывать названия полок',
      'kk': 'Сөре атауларын көрсету',
      'ky': 'Текче аттарын көрсөтүү',
      'en': 'Show shelf names',
    },
    'storefront_show_shelves_hint': {
      'ru': 'Заголовок с номером и названием полки над каждым рядом. '
          'Выключите, если полки на автомате не подписаны.',
      'kk': 'Әр қатардың үстінде сөре нөмірі мен атауы бар тақырып. '
          'Аппаратта сөрелер белгіленбесе, өшіріңіз.',
      'ky': 'Ар бир катардын үстүндө текченин номери жана аты бар аталыш. '
          'Аппаратта текчелер белгиленбесе, өчүрүңүз.',
      'en': 'A header with the shelf number and name above each row. '
          'Turn off if the cabinet shelves are not labelled.',
    },
    'ss_settings': {
      'ru': 'Настройки заставки',
      'kk': 'Скринсейвер баптаулары',
      'ky': 'Экран сактагычтын жөндөөлөрү',
      'en': 'Attract loop settings',
    },
    'ss_delay': {
      'ru': 'Запускать после простоя',
      'kk': 'Тоқтап тұрғаннан кейін іске қосу',
      'ky': 'Токтоп калгандан кийин иштетүү',
      'en': 'Start after idle',
    },
    'ss_slide': {
      'ru': 'Держать слайд',
      'kk': 'Слайдты ұстау',
      'ky': 'Слайдды кармоо',
      'en': 'Slide duration',
    },
    'ss_wait_video': {
      'ru': 'Досматривать видео до конца',
      'kk': 'Бейнені соңына дейін көрсету',
      'ky': 'Видеону аягына чейин көрсөтүү',
      'en': 'Play videos to the end',
    },
    'ss_wait_video_hint': {
      'ru': 'Ролик доиграет полностью, и только потом включится следующая '
          'заставка. Если выключить — видео оборвётся по времени слайда.',
      'kk': 'Ролик толық ойналады, содан кейін ғана келесі слайд қосылады. '
          'Өшірсеңіз — бейне слайд уақыты бойынша үзіледі.',
      'ky': 'Ролик толук ойнойт, ошондон кийин гана кийинки слайд күйөт. '
          'Өчүрсөңүз — видео слайддын убакытына жараша үзүлөт.',
      'en': 'A clip finishes before the next slide comes up. With this off '
          'the video is cut at the slide duration.',
    },
    'ss_sec': {'ru': 'сек', 'kk': 'сек', 'ky': 'сек', 'en': 's'},
    'ss_min': {'ru': 'мин', 'kk': 'мин', 'ky': 'мүн', 'en': 'min'},
    'storefront_preview': {
      'ru': 'ПРЕДПРОСМОТР',
      'kk': 'АЛДЫН АЛА ҚАРАУ',
      'ky': 'АЛДЫН АЛА КӨРҮҮ',
      'en': 'PREVIEW',
    },
    'storefront_preview_empty': {
      'ru': 'Каталог пуст — нечего показать',
      'kk': 'Каталог бос — көрсететін ештеңе жоқ',
      'ky': 'Каталог бош — көрсөтө турган эч нерсе жок',
      'en': 'Catalog is empty — nothing to show',
    },
    'storefront_show_slot': {
      'ru': 'Показывать номер ячейки',
      'kk': 'Ұяшық нөмірін көрсету',
      'ky': 'Уяча номерин көрсөтүү',
      'en': 'Show slot number',
    },
    'storefront_show_slot_hint': {
      'ru': 'На карточке товара появится номер ячейки из раскладки. '
          'Если у товара нет фото, номер покажется вместо картинки. '
          'Включайте, если ячейки на дверце пронумерованы.',
      'kk': 'Тауар картасында раскладкадағы ұяшық нөмірі шығады. '
          'Тауардың фотосы болмаса, нөмір суреттің орнына көрсетіледі. '
          'Есіктегі ұяшықтар нөмірленген болса қосыңыз.',
      'ky': 'Товардын картасында жайгаштыруудагы уяча номери чыгат. '
          'Товардын сүрөтү жок болсо, номер сүрөттүн ордуна көрүнөт. '
          'Эшиктеги уячалар номерленген болсо күйгүзүңүз.',
      'en': 'Product cards get the slot number from the layout. Cards '
          'without a photo show the number in place of the picture. '
          'Turn on if the cabinet doors are numbered.',
    },
    'storefront_slot_no_layout': {
      'ru': 'Раскладка ещё не задана — номера показывать не из чего. '
          'Откройте «Редактор раскладки».',
      'kk': 'Раскладка әлі жасалмаған — нөмір алатын жер жоқ. '
          '«Раскладка редакторын» ашыңыз.',
      'ky': 'Жайгаштыруу азырынча берилген жок — номер ала турган жер '
          'жок. «Жайгаштыруу редакторун» ачыңыз.',
      'en': 'No layout yet — there are no numbers to show. Open the '
          'layout editor first.',
    },
    'service_unpair_hint': {
      'ru': 'Планшет отвяжется от аппарата. Чтобы вернуться к работе, '
          'нужно будет снова ввести номер аппарата и секретный ключ.',
      'kk': 'Планшет аппараттан ажыратылады. Жұмысқа оралу үшін аппарат '
          'нөмірі мен құпия кілтті қайта енгізу қажет болады.',
      'ky': 'Планшет аппараттан ажыратылат. Жумушка кайтуу үчүн '
          'аппараттын номерин жана купуя ачкычты кайра киргизүү керек '
          'болот.',
      'en': 'The tablet will be unlinked from the machine. To resume, you '
          'will have to enter the machine number and secret key again.',
    },
    'service_system': {
      'ru': 'Системные настройки',
      'kk': 'Жүйелік параметрлер',
      'ky': 'Тутум жөндөөлөрү',
      'en': 'System settings',
    },
    'service_exit_kiosk': {
      'ru': 'Выйти в Android',
      'kk': 'Android-қа шығу',
      'ky': 'Android менюсуна чыгуу',
      'en': 'Exit to Android',
    },
    'service_exit_kiosk_confirm': {
      'ru': 'Откроется системное меню Android. Приложение вернётся в '
          'режим киоска при следующем открытии.',
      'kk': 'Android жүйелік мәзірі ашылады. Қосымша келесі ашылғанда '
          'қайтадан киоск режиміне көшеді.',
      'ky': 'Android тутум менюсу ачылат. Колдонмо кийинки жолу ачылганда '
          'киоск режимине кайтат.',
      'en': 'The Android system menu will open. The app re-enters '
          'kiosk mode the next time it is brought to the foreground.',
    },
    'service_show_navbar': {
      'ru': 'Показать навбар',
      'kk': 'Навигация панелін көрсету',
      'ky': 'Навигация панелин көрсөтүү',
      'en': 'Show nav bar',
    },
    'service_show_navbar_go': {
      'ru': 'Показать и перезагрузить',
      'kk': 'Көрсету және қайта қосу',
      'ky': 'Көрсөтүү жана өчүрүп-күйгүзүү',
      'en': 'Show and reboot',
    },
    'service_show_navbar_confirm': {
      'ru': 'Планшет сразу перезагрузится и включится с системными '
          'кнопками внизу и строкой состояния сверху. Это на один сеанс: '
          'после следующей перезагрузки они снова исчезнут сами.',
      'kk': 'Планшет бірден қайта қосылады және төменде жүйелік '
          'батырмалармен, жоғарыда күй жолағымен қосылады. Бұл бір '
          'сеансқа: келесі қайта қосудан кейін олар өздігінен жоғалады.',
      'ky': 'Планшет дароо өчүп-күйөт жана ылдыйда тутум баскычтары, '
          'жогоруда абал сабы менен күйөт. Бул бир сеанска: кийинки '
          'өчүрүп-күйгүзүүдөн кийин алар өздөрү жоголот.',
      'en': 'The tablet reboots immediately and comes back with the '
          'system buttons at the bottom and the status bar on top. This '
          'lasts one session — the reboot after that hides them again on '
          'its own.',
    },
    'service_clear_owner': {
      'ru': 'Снять права владельца',
      'kk': 'Иесі құқықтарын алып тастау',
      'ky': 'Ээлик укуктарын алып салуу',
      'en': 'Release device owner',
    },
    'service_clear_owner_go': {
      'ru': 'Снять права',
      'kk': 'Құқықтарды алып тастау',
      'ky': 'Укуктарды алып салуу',
      'en': 'Release',
    },
    'service_clear_owner_confirm': {
      'ru': 'Приложение перестанет быть владельцем устройства. Защита '
          'киоска отключится сразу: шторка станет доступной, закрепление '
          'экрана пропадёт. Вернуть права можно только через adb или '
          'mmd_diag на планшете без аккаунтов. Делайте это, только если '
          'снимаете планшет с аппарата.',
      'kk': 'Қосымша құрылғы иесі болуын тоқтатады. Киоск қорғанысы бірден '
          'өшеді: перде қолжетімді болады, экранды бекіту жоғалады. '
          'Құқықтарды тек аккаунтсыз планшетте adb немесе mmd_diag арқылы '
          'қайтаруға болады. Мұны планшетті автоматтан шешкенде ғана '
          'жасаңыз.',
      'ky': 'Колдонмо түзмөктүн ээси болбой калат. Киоск коргоосу дароо '
          'өчөт: парда жеткиликтүү болот, экранды бекитүү жоголот. '
          'Укуктарды аккаунтсуз планшетте adb же mmd_diag аркылуу гана '
          'кайтарууга болот. Муну планшетти автоматтан чечкенде гана '
          'кылыңыз.',
      'en': 'The app will stop being the device owner. Kiosk protection ends '
          'at once: the notification shade becomes reachable and screen '
          'pinning goes away. The rights can only be restored over adb or '
          'mmd_diag on a tablet with no accounts. Do this only when taking '
          'the tablet off a machine.',
    },
    'service_clear_owner_done': {
      'ru': 'Права владельца сняты',
      'kk': 'Иесі құқықтары алынды',
      'ky': 'Ээлик укуктары алынды',
      'en': 'Device owner released',
    },
    'tile_off_no_owner': {
      'ru': 'права не выданы',
      'kk': 'құқықтар берілмеген',
      'ky': 'укуктар берилген эмес',
      'en': 'not device owner',
    },
    'service_reboot': {
      'ru': 'Перезагрузить',
      'kk': 'Қайта қосу',
      'ky': 'Өчүрүп-күйгүзүү',
      'en': 'Restart tablet',
    },
    'service_reboot_confirm': {
      'ru': 'Планшет перезагрузится сейчас. Если идёт продажа, она '
          'прервётся. Аппарат вернётся в рабочий режим сам.',
      'kk': 'Планшет қазір қайта қосылады. Сатылым жүріп жатса, ол '
          'үзіледі. Автомат жұмыс режиміне өзі оралады.',
      'ky': 'Планшет азыр өчүп-күйөт. Сатуу жүрүп жатса, ал үзүлөт. '
          'Автомат иш режимине өзү кайтат.',
      'en': 'The tablet will restart now. A sale in progress will be '
          'interrupted. The machine comes back on its own.',
    },
    'service_reboot_failed': {
      'ru': 'Не удалось перезагрузить. Выключите питание вручную.',
      'kk': 'Қайта қосу мүмкін болмады. Қуатты қолмен өшіріңіз.',
      'ky': 'Өчүрүп-күйгүзүү мүмкүн болгон жок. Кубатты кол менен өчүрүңүз.',
      'en': 'Restart failed. Power-cycle the tablet by hand.',
    },
    'service_change_pin': {'ru': 'Сменить PIN', 'kk': 'PIN өзгерту', 'ky': 'PIN өзгөртүү', 'en': 'Change PIN'},
    'service_m102_password': {
      'ru': 'CRC-пароль M102',
      'kk': 'M102 CRC құпиясөзі',
      'ky': 'M102 CRC сырсөзү',
      'en': 'M102 CRC password',
    },
    'service_board': {'ru': 'Плата', 'kk': 'Плата', 'ky': 'Плата', 'en': 'Board'},
    'service_layout_editor': {
      'ru': 'Раскладка слотов',
      'kk': 'Слоттар орналасуы',
      'ky': 'Слоттордун жайгашуусу',
      'en': 'Slot layout',
    },
    'service_screensaver_media': {
      'ru': 'Заставка / Медиа',
      'kk': 'Скринсейвер / Медиа',
      'ky': 'Экран сактагыч / Медиа',
      'en': 'Screensaver media',
    },
    'board_disconnect': {'ru': 'Отключить', 'kk': 'Ажырату', 'ky': 'Ажыратуу', 'en': 'Disconnect'},
    'board_reconnect': {'ru': 'Подключить', 'kk': 'Қосу', 'ky': 'Кайра туташтыруу', 'en': 'Reconnect'},
    'board_slave_addr': {'ru': 'Адрес', 'kk': 'Мекенжайы', 'ky': 'Дарек', 'en': 'Addr'},
    'service_machine_id': {'ru': 'Аппарат №', 'kk': 'Аппарат №', 'ky': 'Аппарат №', 'en': 'Machine #'},
    'service_inventory': {
      'ru': 'Товары',
      'kk': 'Тауарлар',
      'ky': 'Товарлар',
      'en': 'Products',
    },
    'service_sensor_mode': {
      'ru': 'Режим выдачи',
      'kk': 'Беру режимі',
      'ky': 'Берүү режими',
      'en': 'Dispense mode',
    },
    'sensor_off': {
      'ru': 'Без датчика',
      'kk': 'Сенсорсыз',
      'ky': 'Сенсорсуз',
      'en': 'Without sensor',
    },
    'sensor_on': {
      'ru': 'С датчиком',
      'kk': 'Сенсормен',
      'ky': 'Сенсор менен',
      'en': 'With sensor',
    },
    'sensor_mode_hint': {
      'ru':
          'Применяется ко всем слотам. «С датчиком» делает рефанд если '
              'товар не упал в зону луча после оборота мотора.',
      'kk':
          'Барлық слоттарға қолданылады. «Сенсормен» — мотор айналғаннан '
              'кейін тауар сәуле аймағына түспесе, ақша қайтарылады.',
      'ky': 'Бардык слотторго колдонулат. «Сенсор менен» — мотор '
          'айлангандан кийин товар нур аймагына түшпөсө, акча '
          'кайтарылат.',
      'en':
          'Applied to every slot. "With sensor" issues a refund when the '
              'motor finished but the drop sensor never triggered.',
    },
    // Inventory editor
    'inv_grid_title': {
      'ru': 'Карта слотов',
      'kk': 'Слот картасы',
      'ky': 'Слот картасы',
      'en': 'Slot map',
    },
    'inv_empty_slot': {
      'ru': 'пусто',
      'kk': 'бос',
      'ky': 'бош',
      'en': 'empty',
    },
    'product_edit_title': {
      'ru': 'Редактирование товара',
      'kk': 'Тауарды өңдеу',
      'ky': 'Товарды түзөтүү',
      'en': 'Edit product',
    },
    'product_new_title': {
      'ru': 'Новый товар',
      'kk': 'Жаңа тауар',
      'ky': 'Жаңы товар',
      'en': 'New product',
    },
    'field_price': {'ru': 'Цена', 'kk': 'Бағасы', 'ky': 'Баасы', 'en': 'Price'},
    'field_stock': {'ru': 'Остаток, шт', 'kk': 'Қалдық, дана', 'ky': 'Калдыгы, даана', 'en': 'Stock, pcs'},
    'curtain_off': {'ru': 'Выключен', 'kk': 'Өшірулі', 'ky': 'Өчүк', 'en': 'Off'},
    'curtain_standard': {'ru': 'Обычный', 'kk': 'Қалыпты', 'ky': 'Кадимки', 'en': 'Standard'},
    'curtain_priority': {'ru': 'Приоритетный', 'kk': 'Басымдылықпен', 'ky': 'Артыкчылыктуу', 'en': 'Priority'},
    'btn_save': {'ru': 'Сохранить', 'kk': 'Сақтау', 'ky': 'Сактоо', 'en': 'Save'},
    'btn_delete': {'ru': 'Удалить', 'kk': 'Жою', 'ky': 'Өчүрүү', 'en': 'Delete'},
    'confirm_delete': {
      'ru': 'Удалить товар из этого слота?',
      'kk': 'Бұл слоттан тауарды жою керек пе?',
      'ky': 'Бул слоттон товарды өчүрөсүзбү?',
      'en': 'Delete the product from this slot?',
    },
    'save_failed': {
      'ru': 'Не удалось сохранить',
      'kk': 'Сақталмады',
      'ky': 'Сакталган жок',
      'en': 'Save failed',
    },
    'save_ok': {
      'ru': 'Сохранено',
      'kk': 'Сақталды',
      'ky': 'Сакталды',
      'en': 'Saved',
    },
    'name_required': {
      'ru': 'Введите название',
      'kk': 'Атауын енгізіңіз',
      'ky': 'Атын киргизиңиз',
      'en': 'Name is required',
    },
    'price_required': {
      'ru': 'Укажите цену',
      'kk': 'Бағасын көрсетіңіз',
      'ky': 'Баасын көрсөтүңүз',
      'en': 'Enter the price',
    },
    'price_positive': {
      'ru': 'Цена должна быть больше 0',
      'kk': 'Бағасы 0-ден үлкен болуы керек',
      'ky': 'Баасы 0дөн чоң болушу керек',
      'en': 'Price must be greater than 0',
    },
    'stock_required': {
      'ru': 'Укажите остаток',
      'kk': 'Қалдықты көрсетіңіз',
      'ky': 'Калдыгын көрсөтүңүз',
      'en': 'Enter the stock',
    },
    'price_stock_required': {
      'ru': 'Заполните обе строки — цену и остаток. '
          'Без них товар не появится в витрине.',
      'kk': 'Екі жолды да толтырыңыз — бағасы мен қалдығы. '
          'Онсыз тауар витринада көрінбейді.',
      'ky': 'Эки сапты тең толтуруңуз — баасын жана калдыгын. Аларсыз '
          'товар витринада көрүнбөйт.',
      'en': 'Fill in both fields — price and stock. '
          'Without them the product will not appear in the storefront.',
    },
    'motor_label': {'ru': 'Мотор', 'kk': 'Мотор', 'ky': 'Мотор', 'en': 'Motor'},
    // Service mode — menu tiles disabled on a lock board
    'tile_off_no_motors': {'ru': 'нет моторов', 'kk': 'моторлар жоқ', 'ky': 'мотор жок', 'en': 'no motors'},
    'tile_off_vendor_only': {
      'ru': 'только на заводской прошивке SHENGMA',
      'kk': 'тек SHENGMA зауыттық микробағдарламасында',
      'ky': 'SHENGMA заводдук программасында гана',
      'en': 'SHENGMA firmware only',
    },
    'tile_off_needs_owner': {
      'ru': 'нужны права владельца устройства',
      'kk': 'құрылғы иесінің құқықтары қажет',
      'ky': 'түзмөк ээсинин укуктары керек',
      'en': 'needs device owner',
    },
    'tile_off_no_channels': {'ru': 'нет каналов', 'kk': 'арналар жоқ', 'ky': 'канал жок', 'en': 'no channels'},
    'service_update': {'ru': 'Обновление', 'kk': 'Жаңарту', 'ky': 'Жаңыртуу', 'en': 'Update'},
    'pin_changed': {'ru': 'PIN изменён', 'kk': 'PIN өзгертілді', 'ky': 'PIN өзгөртүлдү', 'en': 'PIN changed'},
    // Service mode — inventory editor
    'layout_not_set': {
      'ru': 'Раскладка не настроена',
      'kk': 'Сөре сызбасы бапталмаған',
      'ky': 'Жайгаштыруу жөндөлгөн эмес',
      'en': 'Layout is not configured',
    },
    'layout_not_set_hint': {
      'ru': 'Сначала откройте редактор раскладки и выберите шаблон — после '
          'этого здесь появятся строки на каждый слот.',
      'kk': 'Алдымен сызба редакторын ашып, үлгіні таңдаңыз — содан кейін '
          'мұнда әр слотқа жол пайда болады.',
      'ky': 'Алгач жайгаштыруу редакторун ачып, үлгүнү тандаңыз — андан '
          'кийин бул жерде ар бир слотко сап пайда болот.',
      'en': 'Open the layout editor and pick a template first — a row per '
          'slot appears here afterwards.',
    },
    'open_layout_editor': {
      'ru': 'Открыть редактор',
      'kk': 'Редакторды ашу',
      'ky': 'Редакторду ачуу',
      'en': 'Open the editor',
    },
    'no_slots': {'ru': 'нет слотов', 'kk': 'слоттар жоқ', 'ky': 'слот жок', 'en': 'no slots'},
    // Service mode — PIN
    'pin_mismatch': {
      'ru': 'PIN не совпадает',
      'kk': 'PIN сәйкес келмейді',
      'ky': 'PIN дал келбейт',
      'en': 'PINs do not match',
    },
    'pin_wrong_left': {
      'ru': 'Неверный PIN. Осталось попыток:',
      'kk': 'PIN қате. Қалған әрекет:',
      'ky': 'PIN туура эмес. Калган аракет:',
      'en': 'Wrong PIN. Attempts left:',
    },
    'pin_too_many': {
      'ru': 'Слишком много попыток',
      'kk': 'Тым көп әрекет',
      'ky': 'Аракет өтө көп',
      'en': 'Too many attempts',
    },
    'pin_locked_for': {
      'ru': 'Ввод PIN заблокирован. Попробуйте через ~',
      'kk': 'PIN енгізу бұғатталды. Шамамен кейін көріңіз:',
      'ky': 'PIN киргизүү бөгөттөлдү. Болжол менен кийин аракет кылыңыз:',
      'en': 'PIN entry is locked. Try again in about',
    },
    'pin_minutes_short': {'ru': 'мин.', 'kk': 'мин.', 'ky': 'мүн.', 'en': 'min'},
    'pin_set_title': {
      'ru': 'Задайте сервис-PIN',
      'kk': 'Қызмет PIN-ін орнатыңыз',
      'ky': 'Тейлөө PIN-ин коюңуз',
      'en': 'Set a service PIN',
    },
    'pin_set_hint': {
      'ru': 'PIN по умолчанию больше не используется. Придумайте свой '
          '(минимум %d цифры).',
      'kk': 'Әдепкі PIN енді қолданылмайды. Өз PIN-іңізді ойлап табыңыз '
          '(кемінде %d сан).',
      'ky': 'Демейки PIN мындан ары колдонулбайт. Өз PIN-иңизди ойлоп '
          'табыңыз (кеминде %d сан).',
      'en': 'The default PIN is no longer in use. Choose your own '
          '(at least %d digits).',
    },
    'pin_repeat': {'ru': 'Повторите PIN', 'kk': 'PIN-ді қайталаңыз', 'ky': 'PIN-ди кайталаңыз', 'en': 'Repeat the PIN'},
    'pin_save': {'ru': 'Сохранить PIN', 'kk': 'PIN сақтау', 'ky': 'PIN сактоо', 'en': 'Save the PIN'},
    // Service mode — screensaver media
    'media_copy_failed': {
      'ru': 'Не удалось скопировать',
      'kk': 'Көшіру мүмкін болмады',
      'ky': 'Көчүрүлгөн жок',
      'en': 'Could not copy',
    },
    'media_added': {
      'ru': 'Добавлено файлов:',
      'kk': 'Қосылған файлдар:',
      'ky': 'Кошулган файлдар:',
      'en': 'Files added:',
    },
    'media_add': {'ru': 'Добавить', 'kk': 'Қосу', 'ky': 'Кошуу', 'en': 'Add'},
    'media_folder': {
      'ru': 'Папка с медиа на устройстве',
      'kk': 'Құрылғыдағы медиа қалтасы',
      'ky': 'Түзмөктөгү медиа папкасы',
      'en': 'Media folder on the device',
    },
    'media_folder_missing': {
      'ru': '(не доступна)',
      'kk': '(қолжетімсіз)',
      'ky': '(жеткиликсиз)',
      'en': '(unavailable)',
    },
    'media_copy_hint': {
      'ru': 'Копируйте сюда .jpg / .png / .webp / .gif или .mp4 / .mov / '
          '.webm / .mkv через adb push или файловый менеджер, потом нажмите '
          '«обновить» сверху.',
      'kk': 'Мұнда .jpg / .png / .webp / .gif немесе .mp4 / .mov / .webm / '
          '.mkv файлдарын adb push немесе файл менеджері арқылы көшіріңіз, '
          'содан кейін жоғарыдан «жаңарту» түймесін басыңыз.',
      'ky': 'Бул жерге .jpg / .png / .webp / .gif же .mp4 / .mov / .webm '
          '/ .mkv файлдарын adb push же файл менеджери аркылуу '
          'көчүрүңүз, андан соң жогорудагы «жаңыртуу» баскычын басыңыз.',
      'en': 'Copy .jpg / .png / .webp / .gif or .mp4 / .mov / .webm / .mkv '
          'here with adb push or a file manager, then hit "refresh" above.',
    },
    'media_scanning': {'ru': 'Сканирование…', 'kk': 'Сканерлеу…', 'ky': 'Скандалууда…', 'en': 'Scanning…'},
    'media_empty': {
      'ru': 'Медиа-файлов пока нет',
      'kk': 'Әзірге медиа файлдар жоқ',
      'ky': 'Азырынча медиа файлдар жок',
      'en': 'No media files yet',
    },
    'media_video': {'ru': 'видео', 'kk': 'видео', 'ky': 'видео', 'en': 'video'},
    'media_image': {'ru': 'изображение', 'kk': 'сурет', 'ky': 'сүрөт', 'en': 'image'},
    // Board status / health
    'board_firmware': {'ru': 'Прошивка', 'kk': 'Прошивка', 'ky': 'Прошивка', 'en': 'Firmware'},
    'board_status': {'ru': 'Связь с платой', 'kk': 'Платамен байланыс', 'ky': 'Плата менен байланыш', 'en': 'Board link'},
    'board_health_ok': {'ru': 'Норма', 'kk': 'Қалыпты', 'ky': 'Калыпта', 'en': 'Healthy'},
    'board_health_lost': {
      'ru': 'Связь потеряна',
      'kk': 'Байланыс жоғалды',
      'ky': 'Байланыш жоголду',
      'en': 'Communication lost',
    },
    'maintenance_title': {
      'ru': 'Технический перерыв',
      'kk': 'Техникалық үзіліс',
      'ky': 'Техникалык тыныгуу',
      'en': 'Out of service',
    },
    'maintenance_subtitle': {
      'ru': 'Аппарат не отвечает. Пожалуйста, попробуйте позже.',
      'kk': 'Аппарат жауап бермейді. Кейінірек қайталап көріңіз.',
      'ky': 'Аппарат жооп бербейт. Сураныч, кийинчерээк аракет кылыңыз.',
      'en': 'The machine is unresponsive. Please try again later.',
    },
    // Poll result codes — surfaced when a motor fails
    'poll_ok': {'ru': 'OK', 'kk': 'OK', 'ky': 'OK', 'en': 'OK'},
    'poll_overload': {'ru': 'Перегрузка', 'kk': 'Шамадан тыс жүктеме', 'ky': 'Ашыкча жүктөм', 'en': 'Overload'},
    'poll_wire_break': {'ru': 'Обрыв провода', 'kk': 'Сымның үзілуі', 'ky': 'Зымдын үзүлүшү', 'en': 'Wire break'},
    'poll_timeout': {'ru': 'Таймаут', 'kk': 'Таймаут', 'ky': 'Таймаут', 'en': 'Timeout'},
    'poll_curtain_err': {
      'ru': 'Ошибка датчика падения',
      'kk': 'Құлау сенсорының қатесі',
      'ky': 'Түшүү сенсорунун катасы',
      'en': 'Drop sensor error',
    },
    'poll_lock_not_open': {
      'ru': 'Замок не открыт',
      'kk': 'Құлып ашылмады',
      'ky': 'Кулпу ачылган жок',
      'en': 'Lock did not open',
    },
    'poll_microswitch': {
      'ru': 'Микропереключатель не сработал',
      'kk': 'Микроқосқыш іске қосылмады',
      'ky': 'Микро которгуч иштеген жок',
      'en': 'Micro-switch never pressed',
    },
    // Categories
    'no_products': {
      'ru': 'Нет товаров',
      'kk': 'Тауарлар жоқ',
      'ky': 'Товарлар жок',
      'en': 'No products',
    },
    // Loading / errors
    'reload': {'ru': 'Обновить', 'kk': 'Жаңарту', 'ky': 'Жаңыртуу', 'en': 'Reload'},
    'fetch_error': {'ru': 'Не удалось загрузить товары', 'kk': 'Тауарларды жүктеу сәтсіз', 'ky': 'Товарларды жүктөө ишке ашкан жок', 'en': 'Failed to load products'},
    'fetch_retrying': {
      'ru': 'Повторная попытка выполняется автоматически…',
      'kk': 'Қайта әрекет автоматты түрде жасалады…',
      'ky': 'Кайра аракет автоматтык түрдө жасалууда…',
      'en': 'Retrying automatically…',
    },
    // Customer support
    'support': {'ru': 'Помощь', 'kk': 'Көмек', 'ky': 'Жардам', 'en': 'Help'},
    'support_title': {
      'ru': 'Служба поддержки',
      'kk': 'Қолдау қызметі',
      'ky': 'Колдоо кызматы',
      'en': 'Customer support',
    },
    'support_intro': {
      'ru': 'Товар не выдался или деньги списались дважды? '
          'Позвоните или напишите — разберёмся и вернём.',
      'kk': 'Тауар шықпады ма, әлде ақша екі рет шегерілді ме? '
          'Қоңырау шалыңыз немесе жазыңыз — шешеміз және қайтарамыз.',
      'ky': 'Товар чыккан жокпу же акча эки жолу алындыбы? Чалыңыз же '
          'жазыңыз — чечебиз жана кайтарабыз.',
      'en': 'Item never dropped, or charged twice? '
          'Call or message us — we will sort it out and refund you.',
    },
    'support_machine': {
      'ru': 'Номер аппарата',
      'kk': 'Аппарат нөмірі',
      'ky': 'Аппараттын номери',
      'en': 'Machine number',
    },
    'support_machine_hint': {
      'ru': 'Назовите этот номер оператору — по нему мы найдём вашу покупку',
      'kk': 'Осы нөмірді операторға айтыңыз — ол бойынша сатып алуыңызды табамыз',
      'ky': 'Бул номерди операторго айтыңыз — ошону менен сатып алууңузду '
          'табабыз',
      'en': 'Give this number to the operator — we find your purchase by it',
    },
    'support_phone_label': {'ru': 'Телефон', 'kk': 'Телефон', 'ky': 'Телефон', 'en': 'Phone'},
    'support_hours_label': {
      'ru': 'Время работы',
      'kk': 'Жұмыс уақыты',
      'ky': 'Иш убактысы',
      'en': 'Working hours',
    },
    'support_whatsapp_hint': {
      'ru': 'Наведите камеру телефона, чтобы написать в WhatsApp',
      'kk': 'WhatsApp-қа жазу үшін телефон камерасын бағыттаңыз',
      'ky': 'WhatsApp аркылуу жазуу үчүн телефондун камерасын багыттаңыз',
      'en': 'Point your phone camera here to message us on WhatsApp',
    },
    // Service mode — support contact editor
    'service_support': {
      'ru': 'Поддержка',
      'kk': 'Қолдау',
      'ky': 'Колдоо',
      'en': 'Support',
    },
    'support_settings_title': {
      'ru': 'Контакты поддержки',
      'kk': 'Қолдау байланыстары',
      'ky': 'Колдоо байланыштары',
      'en': 'Support contacts',
    },
    'support_settings_hint': {
      'ru': 'Показывается покупателю по кнопке «Помощь» в углу экрана. '
          'Пока телефон не указан, кнопка скрыта.',
      'kk': 'Экран бұрышындағы «Көмек» түймесі арқылы сатып алушыға '
          'көрсетіледі. Телефон көрсетілмейінше түйме жасырылады.',
      'ky': 'Экрандын бурчундагы «Жардам» баскычы аркылуу сатып алуучуга '
          'көрсөтүлөт. Телефон көрсөтүлмөйүнчө баскыч жашырылат.',
      'en': 'Shown to the customer via the «Help» button in the screen '
          'corner. The button stays hidden until a phone is set.',
    },
    'support_field_phone': {
      'ru': 'Телефон поддержки',
      'kk': 'Қолдау телефоны',
      'ky': 'Колдоо телефону',
      'en': 'Support phone',
    },
    'support_field_whatsapp': {
      'ru': 'WhatsApp, если отличается',
      'kk': 'WhatsApp, өзгеше болса',
      'ky': 'WhatsApp, айырмаланса',
      'en': 'WhatsApp, if different',
    },
    'support_field_hours': {
      'ru': 'Время работы',
      'kk': 'Жұмыс уақыты',
      'ky': 'Иш убактысы',
      'en': 'Working hours',
    },
    'support_hours_example': {
      'ru': 'Например: Пн–Пт, 9:00–18:00',
      'kk': 'Мысалы: Дс–Жм, 9:00–18:00',
      'ky': 'Мисалы: Дү–Жм, 9:00–18:00',
      'en': 'For example: Mon–Fri, 9:00–18:00',
    },
    // Service mode — motor tester
    'btn_cancel': {
      'ru': 'Отмена',
      'kk': 'Болдырмау',
      'ky': 'Жокко чыгаруу',
      'en': 'Cancel',
    },
    'btn_apply': {
      'ru': 'Применить',
      'kk': 'Қолдану',
      'ky': 'Колдонуу',
      'en': 'Apply',
    },
    'curtain_apply_all_title': {
      'ru': 'Применить ко всем слотам?',
      'kk': 'Барлық слоттарға қолдану керек пе?',
      'ky': 'Бардык слотторго колдонулсунбу?',
      'en': 'Apply to every slot?',
    },
    'curtain_apply_all_body': {
      'ru': 'Режим выдачи будет установлен на «%mode%» для всех %n% '
          'слотов с товарами.',
      'kk': 'Беру режимі тауары бар барлық %n% слотқа «%mode%» болып '
          'орнатылады.',
      'ky': 'Берүү режими товары бар бардык %n% слотко «%mode%» болуп '
          'коюлат.',
      'en': 'Dispense mode will be set to "%mode%" on all %n% slots '
          'that hold a product.',
    },
    'curtain_applied_n': {
      'ru': 'Обновлено %n% из %total% слотов',
      'kk': '%total% слоттың %n% жаңартылды',
      'ky': '%total% слоттун %n% жаңыртылды',
      'en': 'Updated %n% of %total% slots',
    },
    'tester_no_layout_hint': {
      'ru': 'Откройте редактор раскладки, выберите шаблон («Заводская '
          '6×6» или «MP2404») и возвращайтесь сюда.',
      'kk': 'Сызба редакторын ашып, үлгіні таңдаңыз («Зауыттық 6×6» '
          'немесе «MP2404») және осында оралыңыз.',
      'ky': 'Жайгаштыруу редакторун ачып, үлгүнү тандаңыз («Заводдук '
          '6×6» же «MP2404») жана бул жерге кайтыңыз.',
      'en': 'Open the layout editor, pick a template ("Factory 6×6" or '
          '"MP2404") and come back here.',
    },
    'tester_curtain_global': {
      'ru': 'РЕЖИМ ВЫДАЧИ — ОБЩИЙ',
      'kk': 'БЕРУ РЕЖИМІ — ЖАЛПЫ',
      'ky': 'БЕРҮҮ РЕЖИМИ — ЖАЛПЫ',
      'en': 'DISPENSE MODE — GLOBAL',
    },
    'tester_curtain_hint': {
      'ru': 'Действует на новые тесты. Кнопкой ниже — записать на все '
          'слоты.',
      'kk': 'Жаңа тесттерге әсер етеді. Төмендегі түймемен барлық '
          'слоттарға жазылады.',
      'ky': 'Жаңы тесттерге таасир этет. Төмөнкү баскыч бардык '
          'слотторго жазат.',
      'en': 'Applies to new tests. The button below writes it to every '
          'slot.',
    },
    'tester_apply_all': {
      'ru': 'Применить ко всем',
      'kk': 'Барлығына қолдану',
      'ky': 'Бардыгына колдонуу',
      'en': 'Apply to all',
    },
    'tester_run': {
      'ru': 'Тест',
      'kk': 'Тест',
      'ky': 'Тест',
      'en': 'Test',
    },
    'tester_run_sensor': {
      'ru': '+датчик',
      'kk': '+сенсор',
      'ky': '+сенсор',
      'en': '+sensor',
    },
    // Service mode — board diagnostics
    'btn_keep': {
      'ru': 'Оставить',
      'kk': 'Қалдыру',
      'ky': 'Калтыруу',
      'en': 'Keep',
    },
    'btn_replace': {
      'ru': 'Заменить',
      'kk': 'Ауыстыру',
      'ky': 'Алмаштыруу',
      'en': 'Replace',
    },
    'diag_board_found': {
      'ru': 'Плата найдена: %path%',
      'kk': 'Плата табылды: %path%',
      'ky': 'Плата табылды: %path%',
      'en': 'Board found: %path%',
    },
    'diag_board_not_found': {
      'ru': 'Плата не найдена ни на одной ноде',
      'kk': 'Плата бірде-бір нодада табылмады',
      'ky': 'Плата бир да нодадан табылган жок',
      'en': 'No board on any node',
    },
    'diag_lock_ok': {
      'ru': 'Плата приняла команду — замок открыт на %n% с',
      'kk': 'Плата команданы қабылдады — құлып %n% с ашық',
      'ky': 'Плата команданы кабыл алды — кулпу %n% сек ачык',
      'en': 'Board accepted the command — lock open for %n% s',
    },
    'diag_lock_fail': {
      'ru': 'Плата не ответила OK. Проверьте кабель, скорость 115200 и '
          'что прошита esp-serial — журнал ниже покажет, что ушло и '
          'что пришло',
      'kk': 'Плата OK жауабын бермеді. Кабельді, 115200 жылдамдығын '
          'және esp-serial жанғанын тексеріңіз — төмендегі журнал не '
          'кеткенін және не келгенін көрсетеді',
      'ky': 'Плата OK деп жооп берген жок. Кабелди, 115200 ылдамдыгын '
          'жана esp-serial куюлганын текшериңиз — төмөнкү журнал эмне '
          'кеткенин жана эмне келгенин көрсөтөт',
      'en': 'The board did not answer OK. Check the cable, the 115200 '
          'baud rate and that esp-serial is flashed — the log below '
          'shows what went out and what came back',
    },
    'diag_lyt_ok': {
      'ru': 'Плата ответила — связь в обе стороны работает',
      'kk': 'Плата жауап берді — байланыс екі бағытта да жұмыс істейді',
      'ky': 'Плата жооп берди — байланыш эки тарапка тең иштейт',
      'en': 'The board answered — the link works both ways',
    },
    'diag_lyt_fail': {
      'ru': 'Нет ответа. Проверьте линию и скорость; внешний FTDI 3.3 В '
          'может не дочитывать уровень платы (~1.8 В) — надёжнее '
          'родной UART планшета',
      'kk': 'Жауап жоқ. Желі мен жылдамдықты тексеріңіз; сыртқы FTDI '
          '3.3 В плата деңгейін (~1.8 В) толық оқымауы мүмкін — '
          'планшеттің өз UART-ы сенімдірек',
      'ky': 'Жооп жок. Линияны жана ылдамдыкты текшериңиз; сырткы FTDI '
          '3.3 В платанын деңгээлин (~1.8 В) толук окубай коюшу '
          'мүмкүн — планшеттин өз UART-ы ишенимдүүрөөк',
      'en': 'No answer. Check the line and the baud rate; an external '
          '3.3 V FTDI may not read the board level (~1.8 V) — the '
          'tablet native UART is more reliable',
    },
    'diag_mm_layout_title': {
      'ru': 'Раскладка микромаркета',
      'kk': 'Микромаркет сызбасы',
      'ky': 'Микромаркет жайгаштыруусу',
      'en': 'Micromarket layout',
    },
    'diag_mm_layout_body': {
      'ru': 'Заменить текущую раскладку на 4 полки по 5 ячеек с '
          'нумерацией 1…20? Товары останутся привязаны к своим '
          'номерам.',
      'kk': 'Ағымдағы сызбаны 1…20 нөмірленген 5 ұяшықтан 4 сөреге '
          'ауыстыру керек пе? Тауарлар өз нөмірлеріне байланып '
          'қалады.',
      'ky': 'Учурдагы жайгаштырууну 1…20 номерленген 5 уячалуу 4 '
          'текчеге алмаштырасызбы? Товарлар өз номерлерине байланып '
          'калат.',
      'en': 'Replace the current layout with 4 shelves of 5 slots, '
          'numbered 1…20? Products stay bound to their numbers.',
    },
    'diag_mm_layout_done': {
      'ru': 'Применена раскладка микромаркета: 20 ячеек',
      'kk': 'Микромаркет сызбасы қолданылды: 20 ұяшық',
      'ky': 'Микромаркет жайгаштыруусу колдонулду: 20 уяча',
      'en': 'Micromarket layout applied: 20 slots',
    },
    'diag_hint_m102': {
      'ru': 'M102 / M109E — кадры 20 байт CRC-16, 9600 8N1, моторы '
          '0..99',
      'kk': 'M102 / M109E — 20 байт CRC-16 кадрлар, 9600 8N1, моторлар '
          '0..99',
      'ky': 'M102 / M109E — 20 байт CRC-16 кадрлар, 9600 8N1, моторлор '
          '0..99',
      'en': 'M102 / M109E — 20-byte CRC-16 frames, 9600 8N1, motors '
          '0..99',
    },
    'diag_hint_lyt': {
      'ru': 'BarysVend V27.2 (LiYuTai) — кадры AA..DD XOR, 115200 8N1, '
          'адресация ряд/колонка, обычно порт ttyS1. Плата отвечает '
          'только на выдачу — проверка связи кнопкой «Тест связи»',
      'kk': 'BarysVend V27.2 (LiYuTai) — AA..DD XOR кадрлар, 115200 '
          '8N1, қатар/баған адрестеуі, әдетте ttyS1 порты. Плата тек '
          'беруге жауап береді — байланысты «Байланыс тесті» '
          'түймесімен тексеріңіз',
      'ky': 'BarysVend V27.2 (LiYuTai) — AA..DD XOR кадрлар, 115200 '
          '8N1, катар/тилке даректөө, адатта ttyS1 порту. Плата '
          'берүүгө гана жооп берет — байланышты «Байланыш тести» '
          'баскычы менен текшериңиз',
      'en': 'BarysVend V27.2 (LiYuTai) — AA..DD XOR frames, 115200 8N1, '
          'row/column addressing, usually port ttyS1. The board '
          'answers a dispense and nothing else — check the link with '
          '"Link test"',
    },
    'diag_hint_micromarket': {
      'ru': 'Микромаркет — вместо моторов электрозамок на релейном '
          'модуле по USB. Текстовые команды PING / OPEN, 115200 8N1. '
          'После оплаты открывается дверь, покупатель забирает товар '
          'сам',
      'kk': 'Микромаркет — моторлардың орнына USB арқылы реле '
          'модуліндегі электрқұлып. PING / OPEN мәтіндік командалары, '
          '115200 8N1. Төлемнен кейін есік ашылады, сатып алушы '
          'тауарды өзі алады',
      'ky': 'Микромаркет — моторлордун ордуна USB аркылуу реле '
          'модулундагы электр кулпу. PING / OPEN текст командалары, '
          '115200 8N1. Төлөмдөн кийин эшик ачылат, сатып алуучу '
          'товарды өзү алат',
      'en': 'Micromarket — an electric lock on a USB relay module '
          'instead of motors. Text commands PING / OPEN, 115200 8N1. '
          'The door opens after payment and the customer takes the '
          'goods themselves',
    },
    'diag_board_protocol': {
      'ru': 'ТИП ПЛАТЫ / ПРОТОКОЛ',
      'kk': 'ПЛАТА ТҮРІ / ПРОТОКОЛ',
      'ky': 'ПЛАТА ТҮРҮ / ПРОТОКОЛ',
      'en': 'BOARD TYPE / PROTOCOL',
    },
    'diag_lock_hold': {
      'ru': 'Время удержания замка',
      'kk': 'Құлыпты ұстау уақыты',
      'ky': 'Кулпуну кармоо убакыты',
      'en': 'Lock hold time',
    },
    'diag_swap_rowcol': {
      'ru': 'Ряд ↔ колонка местами',
      'kk': 'Қатар ↔ баған орнын ауыстыру',
      'ky': 'Катар ↔ тилке ордун алмаштыруу',
      'en': 'Swap row ↔ column',
    },
    'diag_swap_rowcol_hint': {
      'ru': 'Включите, если крутится не тот мотор (перепутана '
          'распиновка ряд/колонка)',
      'kk': 'Басқа мотор айналса қосыңыз (қатар/баған распиновкасы '
          'шатасқан)',
      'ky': 'Башка мотор айланса күйгүзүңүз (катар/тилке распиновкасы '
          'аралашкан)',
      'en': 'Turn on if the wrong motor spins (row/column pinout is '
          'swapped)',
    },
    'diag_board_port': {
      'ru': 'ПОРТ ПЛАТЫ',
      'kk': 'ПЛАТА ПОРТЫ',
      'ky': 'ПЛАТАНЫН ПОРТУ',
      'en': 'BOARD PORT',
    },
    'diag_autodetect': {
      'ru': 'Автопоиск',
      'kk': 'Автоіздеу',
      'ky': 'Автоиздөө',
      'en': 'Auto-detect',
    },
    'diag_no_native_ports': {
      'ru': 'Нативные порты не найдены — нажмите «Автопоиск».',
      'kk': 'Нативті порттар табылмады — «Автоіздеу» түймесін басыңыз.',
      'ky': 'Нативдик порттор табылган жок — «Автоиздөө» баскычын '
          'басыңыз.',
      'en': 'No native ports found — tap "Auto-detect".',
    },
    'diag_open_lock': {
      'ru': 'Открыть замок',
      'kk': 'Құлыпты ашу',
      'ky': 'Кулпуну ачуу',
      'en': 'Open the lock',
    },
    'diag_lyt_test': {
      'ru': 'Тест связи (1·1)',
      'kk': 'Байланыс тесті (1·1)',
      'ky': 'Байланыш тести (1·1)',
      'en': 'Link test (1·1)',
    },
    // Service mode — climate
    'climate_title': {
      'ru': 'Климат',
      'kk': 'Климат',
      'ky': 'Климат',
      'en': 'Climate',
    },
    'climate_ch_fan': {
      'ru': 'Вентилятор',
      'kk': 'Желдеткіш',
      'ky': 'Желдеткич',
      'en': 'Fan',
    },
    'climate_ch_compressor': {
      'ru': 'Компрессор',
      'kk': 'Компрессор',
      'ky': 'Компрессор',
      'en': 'Compressor',
    },
    'climate_ch_glass': {
      'ru': 'Подогрев стекла',
      'kk': 'Шыны жылытқышы',
      'ky': 'Айнек жылытуу',
      'en': 'Glass heater',
    },
    'climate_ch_light': {
      'ru': 'Подсветка',
      'kk': 'Жарықтандыру',
      'ky': 'Жарыктандыруу',
      'en': 'Light',
    },
    'climate_ch_heater': {
      'ru': 'Нагревательный модуль',
      'kk': 'Жылыту модулі',
      'ky': 'Жылытуу модулу',
      'en': 'Heater module',
    },
    'climate_mode_off': {
      'ru': 'Выкл',
      'kk': 'Өшірулі',
      'ky': 'Өчүк',
      'en': 'Off',
    },
    'climate_mode_cooling': {
      'ru': 'Холодильник',
      'kk': 'Тоңазытқыш',
      'ky': 'Муздаткыч',
      'en': 'Cooling',
    },
    'climate_mode_heating': {
      'ru': 'Нагрев',
      'kk': 'Жылыту',
      'ky': 'Жылытуу',
      'en': 'Heating',
    },
    'climate_phase_idle': {
      'ru': 'Простой',
      'kk': 'Бос тұр',
      'ky': 'Бош турат',
      'en': 'Idle',
    },
    'climate_phase_fan': {
      'ru': 'Продувка вентилятором',
      'kk': 'Желдеткішпен үрлеу',
      'ky': 'Желдеткич менен үйлөө',
      'en': 'Fan purge',
    },
    'climate_phase_cooling': {
      'ru': 'Компрессор работает',
      'kk': 'Компрессор жұмыс істеп тұр',
      'ky': 'Компрессор иштеп жатат',
      'en': 'Compressor running',
    },
    'climate_phase_rest': {
      'ru': 'Принудительный отдых',
      'kk': 'Мәжбүрлі демалыс',
      'ky': 'Мажбурлап эс алуу',
      'en': 'Forced rest',
    },
    'climate_phase_noprobe': {
      'ru': 'Нет датчика температуры',
      'kk': 'Температура сенсоры жоқ',
      'ky': 'Температура сенсору жок',
      'en': 'No temperature probe',
    },
    'climate_mode_label': {
      'ru': 'Режим',
      'kk': 'Режим',
      'ky': 'Режим',
      'en': 'Mode',
    },
    'climate_setpoint_cool': {
      'ru': 'Целевая температура (холод)',
      'kk': 'Мақсатты температура (суық)',
      'ky': 'Максаттуу температура (муздатуу)',
      'en': 'Target temperature (cooling)',
    },
    'climate_setpoint_heat': {
      'ru': 'Целевая температура (нагрев)',
      'kk': 'Мақсатты температура (жылыту)',
      'ky': 'Максаттуу температура (жылытуу)',
      'en': 'Target temperature (heating)',
    },
    'climate_setpoint_hint_cool': {
      'ru': 'Компрессор включится при %on% °C, выключится при %off% °C.',
      'kk': 'Компрессор %on% °C кезінде қосылады, %off% °C кезінде '
          'өшеді.',
      'ky': 'Компрессор %on% °C болгондо күйөт, %off% °C болгондо өчөт.',
      'en': 'The compressor starts at %on% °C and stops at %off% °C.',
    },
    'climate_setpoint_hint_heat': {
      'ru': 'Нагрев включится при %on% °C, выключится при %off% °C.',
      'kk': 'Жылыту %on% °C кезінде қосылады, %off% °C кезінде өшеді.',
      'ky': 'Жылытуу %on% °C болгондо күйөт, %off% °C болгондо өчөт.',
      'en': 'Heating starts at %on% °C and stops at %off% °C.',
    },
    'climate_light_hint': {
      'ru': 'LED-лента в витрине',
      'kk': 'Витринадағы LED-таспа',
      'ky': 'Витринадагы LED-тасма',
      'en': 'LED strip in the cabinet',
    },
    'climate_glass_title': {
      'ru': 'Подогрев стекла подключён',
      'kk': 'Шыны жылытқышы жалғанған',
      'ky': 'Айнек жылытуу туташтырылган',
      'en': 'Glass heater is wired',
    },
    'climate_glass_hint': {
      'ru': 'Выключите, если на этой машине реле есть, а нагревателя '
          'физически нет',
      'kk': 'Бұл машинада реле бар, бірақ жылытқыш физикалық жоқ болса '
          '— өшіріңіз',
      'ky': 'Бул машинада реле бар, бирок жылыткыч физикалык жок болсо '
          '— өчүрүңүз',
      'en': 'Turn off when this machine has the relay but no heater '
          'actually attached',
    },
    'climate_details_hint': {
      'ru': 'Состояние реле, защита компрессора',
      'kk': 'Реле күйі, компрессорды қорғау',
      'ky': 'Релелердин абалы, компрессорду коргоо',
      'en': 'Relay state, compressor protection',
    },
    'climate_protect_title': {
      'ru': 'Защита компрессора (по заводскому алгоритму):',
      'kk': 'Компрессорды қорғау (зауыттық алгоритм бойынша):',
      'ky': 'Компрессорду коргоо (заводдук алгоритм боюнча):',
      'en': 'Compressor protection (per the factory algorithm):',
    },
    'climate_protect_1': {
      'ru': 'Гистерезис ±4°C — без частых пусков-остановок',
      'kk': 'Гистерезис ±4°C — жиі қосылып-өшуісіз',
      'ky': 'Гистерезис ±4°C — тез-тез күйүп-өчпөйт',
      'en': '±4°C hysteresis — no rapid start-stop cycling',
    },
    'climate_protect_2': {
      'ru': 'Продувка вентилятором 5 мин при первом запуске, потом 2 '
          'мин',
      'kk': 'Алғашқы іске қосуда 5 мин желдету, содан кейін 2 мин',
      'ky': 'Биринчи ишке киргенде 5 мүн желдетүү, андан кийин 2 мүн',
      'en': '5 min fan purge on the first start, 2 min after that',
    },
    'climate_protect_3': {
      'ru': 'Продувка перед нагревателем 2 мин',
      'kk': 'Жылытқыштың алдында 2 мин желдету',
      'ky': 'Жылыткычтын алдында 2 мүн желдетүү',
      'en': '2 min purge before the heater',
    },
    'climate_protect_4': {
      'ru': 'При >60 мин непрерывной работы — отдых 5 мин',
      'kk': '>60 мин үздіксіз жұмыстан кейін — 5 мин демалыс',
      'ky': '>60 мүн үзгүлтүксүз иштегенден кийин — 5 мүн эс алуу',
      'en': 'After >60 min of continuous run — 5 min rest',
    },
    'climate_protect_5': {
      'ru': 'При потере датчика — компрессор сразу ВЫКЛ',
      'kk': 'Сенсор жоғалса — компрессор бірден ӨШІРІЛЕДІ',
      'ky': 'Сенсор жоголсо — компрессор дароо ӨЧӨТ',
      'en': 'If the probe is lost — the compressor goes OFF at once',
    },
    'climate_protect_6': {
      'ru': 'Компрессор не стартует, если вентилятор выключен',
      'kk': 'Желдеткіш өшірулі болса компрессор іске қосылмайды',
      'ky': 'Желдеткич өчүк болсо компрессор ишке кирбейт',
      'en': 'The compressor will not start while the fan is off',
    },
    'climate_on': {
      'ru': 'ВКЛ',
      'kk': 'ҚОСУЛЫ',
      'ky': 'КҮЙҮК',
      'en': 'ON',
    },
    'climate_off': {
      'ru': 'выкл',
      'kk': 'өшірулі',
      'ky': 'өчүк',
      'en': 'off',
    },
    'climate_st_waiting': {
      'ru': 'Ожидание',
      'kk': 'Күту',
      'ky': 'Күтүү',
      'en': 'Waiting',
    },
    'climate_st_stopped': {
      'ru': 'Климат-контроль остановлен',
      'kk': 'Климат-бақылау тоқтатылды',
      'ky': 'Климат-контроль токтотулду',
      'en': 'Climate control stopped',
    },
    'climate_st_no_board': {
      'ru': 'Нет связи с платой',
      'kk': 'Платамен байланыс жоқ',
      'ky': 'Плата менен байланыш жок',
      'en': 'No link to the board',
    },
    'climate_st_off': {
      'ru': 'Климат отключён',
      'kk': 'Климат өшірілген',
      'ky': 'Климат өчүрүлгөн',
      'en': 'Climate is off',
    },
    'climate_st_no_probe': {
      'ru': 'Нет данных от датчика температуры',
      'kk': 'Температура сенсорынан дерек жоқ',
      'ky': 'Температура сенсорунан маалымат жок',
      'en': 'No reading from the temperature probe',
    },
    'climate_st_prefan': {
      'ru': 'Продувка перед компрессором: ещё %n% с',
      'kk': 'Компрессор алдында желдету: тағы %n% с',
      'ky': 'Компрессордун алдында желдетүү: дагы %n% сек',
      'en': 'Purge before the compressor: %n% s left',
    },
    'climate_st_forced_rest': {
      'ru': 'Принудительный отдых: ещё %n% мин',
      'kk': 'Мәжбүрлі демалыс: тағы %n% мин',
      'ky': 'Мажбурлап эс алуу: дагы %n% мүн',
      'en': 'Forced rest: %n% min left',
    },
    'climate_st_normal': {
      'ru': 'В норме: %t%°C (уставка %set%°C)',
      'kk': 'Қалыпты: %t%°C (уставка %set%°C)',
      'ky': 'Калыпта: %t%°C (коюлган %set%°C)',
      'en': 'Normal: %t%°C (setpoint %set%°C)',
    },
    'climate_st_hysteresis': {
      'ru': 'В пределах гистерезиса: %t%°C',
      'kk': 'Гистерезис шегінде: %t%°C',
      'ky': 'Гистерезис чегинде: %t%°C',
      'en': 'Within hysteresis: %t%°C',
    },
    'climate_st_circulating': {
      'ru': 'Циркуляция воздуха перед компрессором',
      'kk': 'Компрессор алдында ауа айналымы',
      'ky': 'Компрессордун алдында аба айлануусу',
      'en': 'Air circulation before the compressor',
    },
    'climate_st_cooling': {
      'ru': 'Охлаждение: %t%°C → %set%°C',
      'kk': 'Суыту: %t%°C → %set%°C',
      'ky': 'Муздатуу: %t%°C → %set%°C',
      'en': 'Cooling: %t%°C → %set%°C',
    },
    'climate_st_rest_after': {
      'ru': 'Компрессор работал %n% мин — принудительный отдых %rest% '
          'мин',
      'kk': 'Компрессор %n% мин жұмыс істеді — мәжбүрлі демалыс %rest% '
          'мин',
      'ky': 'Компрессор %n% мүн иштеди — мажбурлап эс алуу %rest% мүн',
      'en': 'The compressor ran %n% min — forced rest %rest% min',
    },
    'climate_st_heat_normal': {
      'ru': 'Нагрев: норма %t%°C',
      'kk': 'Жылыту: қалыпты %t%°C',
      'ky': 'Жылытуу: калыпта %t%°C',
      'en': 'Heating: normal %t%°C',
    },
    'climate_st_heat_start': {
      'ru': 'Запуск нагрева: вентилятор включён',
      'kk': 'Жылытуды бастау: желдеткіш қосылды',
      'ky': 'Жылытууну баштоо: желдеткич күйдү',
      'en': 'Starting heating: fan on',
    },
    'climate_st_heating': {
      'ru': 'Нагрев: %t%°C → %set%°C',
      'kk': 'Жылыту: %t%°C → %set%°C',
      'ky': 'Жылытуу: %t%°C → %set%°C',
      'en': 'Heating: %t%°C → %set%°C',
    },
    'climate_st_preheat': {
      'ru': 'Циркуляция перед нагревателем: ещё %n% с',
      'kk': 'Жылытқыш алдында айналым: тағы %n% с',
      'ky': 'Жылыткычтын алдында айлануу: дагы %n% сек',
      'en': 'Circulation before the heater: %n% s left',
    },
    // Service mode — product editor
    'pe_pick_catalog_first': {
      'ru': 'Сначала выберите товар из каталога',
      'kk': 'Алдымен каталогтан тауарды таңдаңыз',
      'ky': 'Адегенде каталогдон товарды тандаңыз',
      'en': 'Pick a product from the catalog first',
    },
    'pe_save_q': {
      'ru': 'Сохранить?',
      'kk': 'Сақтау керек пе?',
      'ky': 'Сакталсынбы?',
      'en': 'Save?',
    },
    'pe_slot_line': {
      'ru': 'Слот %slot% · M%motor%',
      'kk': 'Слот %slot% · M%motor%',
      'ky': 'Слот %slot% · M%motor%',
      'en': 'Slot %slot% · M%motor%',
    },
    'pe_stock_line': {
      'ru': 'Остаток: %n% шт',
      'kk': 'Қалдық: %n% дана',
      'ky': 'Калдык: %n% даана',
      'en': 'Stock: %n% pcs',
    },
    'pe_applied_to_n': {
      'ru': 'Применено к %n% слотам',
      'kk': '%n% слотқа қолданылды',
      'ky': '%n% слотко колдонулду',
      'en': 'Applied to %n% slots',
    },
    'pe_applied_partial': {
      'ru': 'Частично применено',
      'kk': 'Ішінара қолданылды',
      'ky': 'Жарым-жартылай колдонулду',
      'en': 'Partly applied',
    },
    'pe_product_line': {
      'ru': 'Товар: %name%',
      'kk': 'Тауар: %name%',
      'ky': 'Товар: %name%',
      'en': 'Product: %name%',
    },
    'pe_saved_to': {
      'ru': '✓ Сохранено в:',
      'kk': '✓ Мына жерге сақталды:',
      'ky': '✓ Мына жерге сакталды:',
      'en': '✓ Saved to:',
    },
    'pe_not_saved': {
      'ru': '✕ Не сохранилось:',
      'kk': '✕ Сақталмады:',
      'ky': '✕ Сакталган жок:',
      'en': '✕ Not saved:',
    },
    'pe_storefront': {
      'ru': 'ВИТРИНА',
      'kk': 'ВИТРИНА',
      'ky': 'ВИТРИНА',
      'en': 'STOREFRONT',
    },
    'pe_apply_other': {
      'ru': 'Применить к другим слотам',
      'kk': 'Басқа слоттарға қолдану',
      'ky': 'Башка слотторго колдонуу',
      'en': 'Apply to other slots',
    },
    'pe_motor_hint': {
      'ru': 'Тип мотора и режим выдачи задаются в разделе «Настройка '
          'моторов».',
      'kk': 'Мотор түрі мен беру режимі «Моторларды баптау» бөлімінде '
          'орнатылады.',
      'ky': 'Мотордун түрү жана берүү режими «Моторлорду жөндөө» '
          'бөлүмүндө коюлат.',
      'en': 'Motor type and dispense mode are set in "Motor setup".',
    },
    'pe_pick_catalog': {
      'ru': 'Выбрать из каталога',
      'kk': 'Каталогтан таңдау',
      'ky': 'Каталогдон тандоо',
      'en': 'Pick from the catalog',
    },
    'pe_pick_catalog_hint': {
      'ru': 'Подтянуть фото и название из готового товара',
      'kk': 'Дайын тауардан фото мен атауды алу',
      'ky': 'Даяр товардан сүрөттү жана атын алуу',
      'en': 'Pull the photo and name from an existing product',
    },
    'pe_from_catalog': {
      'ru': 'Из каталога',
      'kk': 'Каталогтан',
      'ky': 'Каталогдон',
      'en': 'From the catalog',
    },
    'pe_change': {
      'ru': 'Сменить',
      'kk': 'Ауыстыру',
      'ky': 'Алмаштыруу',
      'en': 'Change',
    },
    'pe_unlink': {
      'ru': 'Отвязать',
      'kk': 'Ажырату',
      'ky': 'Ажыратуу',
      'en': 'Unlink',
    },
    'pe_catalog_title': {
      'ru': 'Каталог товаров',
      'kk': 'Тауарлар каталогы',
      'ky': 'Товарлар каталогу',
      'en': 'Product catalog',
    },
    'pe_search': {
      'ru': 'Поиск',
      'kk': 'Іздеу',
      'ky': 'Издөө',
      'en': 'Search',
    },
    'pe_catalog_empty': {
      'ru': 'Каталог пуст. Добавьте товары в admin-панели.',
      'kk': 'Каталог бос. Тауарларды admin-панельде қосыңыз.',
      'ky': 'Каталог бош. Товарларды admin-панелде кошуңуз.',
      'en': 'The catalog is empty. Add products in the admin panel.',
    },
    'pe_nothing_found': {
      'ru': 'Ничего не найдено',
      'kk': 'Ештеңе табылмады',
      'ky': 'Эч нерсе табылган жок',
      'en': 'Nothing found',
    },
    'pe_ml': {
      'ru': '%n% мл',
      'kk': '%n% мл',
      'ky': '%n% мл',
      'en': '%n% ml',
    },
    'pe_copy_hint': {
      'ru': 'Скопирует «%name%» на выбранные слоты с привязкой к '
          'каталогу.',
      'kk': '«%name%» тауарын таңдалған слоттарға каталогқа '
          'байланыстырып көшіреді.',
      'ky': '«%name%» товарын тандалган слотторго каталогго байлап '
          'көчүрөт.',
      'en': 'Copies "%name%" onto the selected slots, keeping the '
          'catalog link.',
    },
    'pe_stock_chip': {
      'ru': 'Остаток %n%',
      'kk': 'Қалдық %n%',
      'ky': 'Калдык %n%',
      'en': 'Stock %n%',
    },
    'pe_selected_n': {
      'ru': 'Выбрано: %n%',
      'kk': 'Таңдалды: %n%',
      'ky': 'Тандалды: %n%',
      'en': 'Selected: %n%',
    },
    'pe_clear_sel': {
      'ru': 'Снять',
      'kk': 'Алып тастау',
      'ky': 'Алып салуу',
      'en': 'Clear',
    },
    'pe_select_all': {
      'ru': 'Все',
      'kk': 'Барлығы',
      'ky': 'Баары',
      'en': 'All',
    },
    'pe_slot_empty': {
      'ru': 'Слот пуст',
      'kk': 'Слот бос',
      'ky': 'Слот бош',
      'en': 'Slot is empty',
    },
    'pe_apply_n': {
      'ru': 'Применить (%n%)',
      'kk': 'Қолдану (%n%)',
      'ky': 'Колдонуу (%n%)',
      'en': 'Apply (%n%)',
    },
    // Service mode — app update
    'upd_confirm_system_dialog': {
      'ru': 'Подтвердите установку в системном диалоге',
      'kk': 'Жүйелік диалогта орнатуды растаңыз',
      'ky': 'Тутум диалогунда орнотууну ырастаңыз',
      'en': 'Confirm the install in the system dialog',
    },
    'upd_err_blocked': {
      'ru': 'Установка заблокирована системой',
      'kk': 'Орнатуды жүйе бұғаттады',
      'ky': 'Орнотууну тутум бөгөттөдү',
      'en': 'The system blocked the install',
    },
    'upd_err_aborted': {
      'ru': 'Установка отменена',
      'kk': 'Орнату тоқтатылды',
      'ky': 'Орнотуу жокко чыгарылды',
      'en': 'Install cancelled',
    },
    'upd_err_invalid': {
      'ru': 'Система отклонила APK',
      'kk': 'Жүйе APK-ны қабылдамады',
      'ky': 'Тутум APK\'ны кабыл алган жок',
      'en': 'The system rejected the APK',
    },
    'upd_err_conflict': {
      'ru': 'Конфликт с установленной версией (другая подпись?) — '
          'переустановите приложение вручную',
      'kk': 'Орнатылған нұсқамен қайшылық (басқа қолтаңба ма?) — '
          'қосымшаны қолмен қайта орнатыңыз',
      'ky': 'Орнотулган версия менен чыр (башка кол тамга бекен?) — '
          'колдонмону кол менен кайра орнотуңуз',
      'en': 'Conflict with the installed version (different signature?) '
          '— reinstall the app by hand',
    },
    'upd_err_storage': {
      'ru': 'Недостаточно места на планшете',
      'kk': 'Планшетте орын жеткіліксіз',
      'ky': 'Планшетте орун жетишсиз',
      'en': 'Not enough space on the tablet',
    },
    'upd_err_incompatible': {
      'ru': 'APK несовместим с этим устройством',
      'kk': 'APK бұл құрылғыға үйлеспейді',
      'ky': 'APK бул түзмөккө туура келбейт',
      'en': 'The APK is not compatible with this device',
    },
    'upd_err_no_dialog': {
      'ru': 'Не удалось показать системный диалог установки',
      'kk': 'Жүйелік орнату диалогын көрсету мүмкін болмады',
      'ky': 'Тутумдун орнотуу диалогун көрсөтүү мүмкүн болгон жок',
      'en': 'Could not bring up the system install dialog',
    },
    'upd_err_generic': {
      'ru': 'Установка не удалась',
      'kk': 'Орнату сәтсіз аяқталды',
      'ky': 'Орнотуу ишке ашкан жок',
      'en': 'Install failed',
    },
    'upd_err_code': {
      'ru': '%base% (код %code%)',
      'kk': '%base% (код %code%)',
      'ky': '%base% (код %code%)',
      'en': '%base% (code %code%)',
    },
    'upd_err_code_msg': {
      'ru': '%base% (код %code%): %msg%',
      'kk': '%base% (код %code%): %msg%',
      'ky': '%base% (код %code%): %msg%',
      'en': '%base% (code %code%): %msg%',
    },
    'upd_no_releases': {
      'ru': 'Релизов с APK не найдено',
      'kk': 'APK бар релиздер табылмады',
      'ky': 'APK камтыган релиздер табылган жок',
      'en': 'No release with an APK found',
    },
    'upd_stalled': {
      'ru': 'Установка не началась. Проверьте: Настройки → Приложения → '
          'MicroVend → «Установка неизвестных приложений» '
          '(разрешить), затем повторите.',
      'kk': 'Орнату басталмады. Тексеріңіз: Параметрлер → Қосымшалар → '
          'MicroVend → «Белгісіз қосымшаларды орнату» (рұқсат '
          'етіңіз), содан кейін қайталаңыз.',
      'ky': 'Орнотуу башталган жок. Текшериңиз: Жөндөөлөр → Колдонмолор '
          '→ MicroVend → «Белгисиз колдонмолорду орнотуу» (уруксат '
          'бериңиз), андан соң кайталаңыз.',
      'en': 'The install never started. Check Settings → Apps → '
          'MicroVend → "Install unknown apps" (allow it), then try '
          'again.',
    },
    'upd_no_permission': {
      'ru': 'Нет разрешения «Установка неизвестных приложений». Система '
          'открыла нужную настройку — включите переключатель для '
          'MicroVend, вернитесь и нажмите «Скачать и установить» ещё '
          'раз.',
      'kk': '«Белгісіз қосымшаларды орнату» рұқсаты жоқ. Жүйе қажетті '
          'параметрді ашты — MicroVend үшін қосқышты қосыңыз, '
          'оралыңыз да «Жүктеп орнату» түймесін қайта басыңыз.',
      'ky': '«Белгисиз колдонмолорду орнотуу» уруксаты жок. Тутум '
          'керектүү жөндөөнү ачты — MicroVend үчүн которгучту '
          'күйгүзүңүз, кайтып келип «Жүктөп орнотуу» баскычын кайра '
          'басыңыз.',
      'en': 'No "Install unknown apps" permission. The system opened '
          'the right setting — turn the switch on for MicroVend, come '
          'back and tap "Download and install" again.',
    },
    'upd_open_failed': {
      'ru': 'Не удалось открыть установщик: %err%',
      'kk': 'Орнатқышты ашу мүмкін болмады: %err%',
      'ky': 'Орноткучту ачуу мүмкүн болгон жок: %err%',
      'en': 'Could not open the installer: %err%',
    },
    'upd_open_manually': {
      'ru': 'Откройте файл вручную через файловый менеджер:',
      'kk': 'Файлды файл менеджері арқылы қолмен ашыңыз:',
      'ky': 'Файлды файл менеджери аркылуу кол менен ачыңыз:',
      'en': 'Open the file by hand from a file manager:',
    },
    'upd_current_version': {
      'ru': 'Текущая версия',
      'kk': 'Ағымдағы нұсқа',
      'ky': 'Учурдагы версия',
      'en': 'Current version',
    },
    'upd_checking': {
      'ru': 'Проверяем…',
      'kk': 'Тексерілуде…',
      'ky': 'Текшерилүүдө…',
      'en': 'Checking…',
    },
    'upd_check': {
      'ru': 'Проверить обновление',
      'kk': 'Жаңартуды тексеру',
      'ky': 'Жаңыртууну текшерүү',
      'en': 'Check for an update',
    },
    'upd_available': {
      'ru': 'Доступна новая версия',
      'kk': 'Жаңа нұсқа қолжетімді',
      'ky': 'Жаңы версия жеткиликтүү',
      'en': 'A new version is available',
    },
    'upd_up_to_date': {
      'ru': 'У вас актуальная версия',
      'kk': 'Сізде ең соңғы нұсқа',
      'ky': 'Сизде эң акыркы версия',
      'en': 'You are on the latest version',
    },
    'upd_size_tag': {
      'ru': 'Размер: %size%  ·  тег %tag%',
      'kk': 'Өлшемі: %size%  ·  тег %tag%',
      'ky': 'Өлчөмү: %size%  ·  тег %tag%',
      'en': 'Size: %size%  ·  tag %tag%',
    },
    'upd_changes': {
      'ru': 'Изменения',
      'kk': 'Өзгерістер',
      'ky': 'Өзгөрүүлөр',
      'en': 'Changes',
    },
    'upd_download_install': {
      'ru': 'Скачать и установить',
      'kk': 'Жүктеп орнату',
      'ky': 'Жүктөп орнотуу',
      'en': 'Download and install',
    },
    'upd_download_manual': {
      'ru': 'Скачать для ручной установки',
      'kk': 'Қолмен орнату үшін жүктеу',
      'ky': 'Кол менен орнотуу үчүн жүктөө',
      'en': 'Download for a manual install',
    },
    'upd_check_again': {
      'ru': 'Проверить ещё раз',
      'kk': 'Қайта тексеру',
      'ky': 'Кайра текшерүү',
      'en': 'Check again',
    },
    'upd_downloading': {
      'ru': 'Загрузка…',
      'kk': 'Жүктелуде…',
      'ky': 'Жүктөлүүдө…',
      'en': 'Downloading…',
    },
    'upd_mb': {
      'ru': 'МБ',
      'kk': 'МБ',
      'ky': 'МБ',
      'en': 'MB',
    },
    'upd_dont_power_off': {
      'ru': 'Не выключайте планшет — приложение перезапустится '
          'автоматически.',
      'kk': 'Планшетті өшірмеңіз — қосымша автоматты түрде қайта іске '
          'қосылады.',
      'ky': 'Планшетти өчүрбөңүз — колдонмо автоматтык түрдө кайра ишке '
          'кирет.',
      'en': 'Do not power the tablet off — the app restarts by itself.',
    },
    'upd_apk_downloaded': {
      'ru': 'APK скачан',
      'kk': 'APK жүктелді',
      'ky': 'APK жүктөлдү',
      'en': 'APK downloaded',
    },
    'upd_install_hint': {
      'ru': 'Нажмите «Установить» — откроется системный установщик (как '
          'при открытии файла из файлового менеджера). Если не '
          'открылся — найдите файл по пути выше.',
      'kk': '«Орнату» түймесін басыңыз — жүйелік орнатқыш ашылады '
          '(файлды файл менеджерінен ашқандағыдай). Ашылмаса — файлды '
          'жоғарыдағы жол бойынша табыңыз.',
      'ky': '«Орнотуу» баскычын басыңыз — тутумдун орноткучу ачылат '
          '(файлды файл менеджеринен ачкандай). Ачылбаса — файлды '
          'жогорудагы жол боюнча табыңыз.',
      'en': 'Tap "Install" — the system installer opens (the same as '
          'opening the file from a file manager). If it does not, '
          'find the file at the path above.',
    },
    'upd_install': {
      'ru': 'Установить',
      'kk': 'Орнату',
      'ky': 'Орнотуу',
      'en': 'Install',
    },
    // Service mode — layout editor and templates
    'lt_factory6x6': {
      'ru': 'Заводская 6×6',
      'kk': 'Зауыттық 6×6',
      'ky': 'Заводдук 6×6',
      'en': 'Factory 6×6',
    },
    'lt_factory6x6_desc': {
      'ru': '6 полок × 6 слотов, моторы 99..44, ярлыки 001..006 / '
          '011..016 / … / 051..056',
      'kk': '6 сөре × 6 слот, моторлар 99..44, белгілер 001..006 / '
          '011..016 / … / 051..056',
      'ky': '6 текче × 6 слот, моторлор 99..44, белгилер 001..006 / '
          '011..016 / … / 051..056',
      'en': '6 shelves × 6 slots, motors 99..44, labels 001..006 / '
          '011..016 / … / 051..056',
    },
    'lt_mp2404': {
      'ru': 'MP2404 (5 + 5×10)',
      'kk': 'MP2404 (5 + 5×10)',
      'ky': 'MP2404 (5 + 5×10)',
      'en': 'MP2404 (5 + 5×10)',
    },
    'lt_mp2404_desc': {
      'ru': '1×5 сдвоенных слотов сверху + 5×10 обычных снизу',
      'kk': 'Жоғарыда 1×5 қос слот + төменде 5×10 қарапайым',
      'ky': 'Жогоруда 1×5 кош слот + ылдыйда 5×10 кадимки',
      'en': '1×5 twin slots on top + 5×10 regular below',
    },
    'lt_barysvend': {
      'ru': 'BarysVend V27.2',
      'kk': 'BarysVend V27.2',
      'ky': 'BarysVend V27.2',
      'en': 'BarysVend V27.2',
    },
    'lt_barysvend_desc': {
      'ru': 'Ряд 1 — 5 широких (к1,3,5,7,9), ряды 2–6 — по 10; подписи '
          '1…55',
      'kk': '1-қатар — 5 кең (б1,3,5,7,9), 2–6 қатарлар — 10-нан; '
          'белгілер 1…55',
      'ky': '1-катар — 5 кең (т1,3,5,7,9), 2–6 катарлар — 10дон; '
          'белгилер 1…55',
      'en': 'Row 1 — 5 wide (col 1,3,5,7,9), rows 2–6 — 10 each; labels '
          '1…55',
    },
    'lt_micromarket': {
      'ru': 'Микромаркет 4×5',
      'kk': 'Микромаркет 4×5',
      'ky': 'Микромаркет 4×5',
      'en': 'Micromarket 4×5',
    },
    'lt_micromarket_desc': {
      'ru': '4 полки × 5 ячеек, сквозная нумерация 1…20',
      'kk': '4 сөре × 5 ұяшық, тұтас нөмірлеу 1…20',
      'ky': '4 текче × 5 уяча, ырааттуу номерлөө 1…20',
      'en': '4 shelves × 5 slots, numbered straight through 1…20',
    },
    'le_rowcol': {
      'ru': 'Р%r%·К%c%',
      'kk': 'Қ%r%·Б%c%',
      'ky': 'К%r%·Т%c%',
      'en': 'R%r%·C%c%',
    },
    'le_nothing_to_save': {
      'ru': 'Раскладка пуста — нечего сохранять',
      'kk': 'Сызба бос — сақтайтын ештеңе жоқ',
      'ky': 'Жайгаштыруу бош — сакталчу эч нерсе жок',
      'en': 'The layout is empty — nothing to save',
    },
    'le_template_n': {
      'ru': 'Шаблон %n%',
      'kk': 'Үлгі %n%',
      'ky': 'Үлгү %n%',
      'en': 'Template %n%',
    },
    'le_save_as_template': {
      'ru': 'Сохранить как шаблон',
      'kk': 'Үлгі ретінде сақтау',
      'ky': 'Үлгү катары сактоо',
      'en': 'Save as a template',
    },
    'le_template_name': {
      'ru': 'Название шаблона',
      'kk': 'Үлгі атауы',
      'ky': 'Үлгүнүн аты',
      'en': 'Template name',
    },
    'le_template_name_hint': {
      'ru': 'например BarysVend кофейня',
      'kk': 'мысалы BarysVend кофехана',
      'ky': 'мисалы BarysVend кофекана',
      'en': 'for example BarysVend coffee shop',
    },
    'le_overwrite_template_q': {
      'ru': 'Перезаписать шаблон?',
      'kk': 'Үлгіні қайта жазу керек пе?',
      'ky': 'Үлгү кайра жазылсынбы?',
      'en': 'Overwrite the template?',
    },
    'le_template_exists': {
      'ru': 'Шаблон «%name%» уже существует.',
      'kk': '«%name%» үлгісі бұрыннан бар.',
      'ky': '«%name%» үлгүсү мурдатан бар.',
      'en': 'A template named "%name%" already exists.',
    },
    'btn_overwrite': {
      'ru': 'Перезаписать',
      'kk': 'Қайта жазу',
      'ky': 'Кайра жазуу',
      'en': 'Overwrite',
    },
    'le_template_saved': {
      'ru': 'Шаблон «%name%» сохранён',
      'kk': '«%name%» үлгісі сақталды',
      'ky': '«%name%» үлгүсү сакталды',
      'en': 'Template "%name%" saved',
    },
    'le_describe': {
      'ru': 'Полок: %shelves% · ячеек: %slots%',
      'kk': 'Сөре: %shelves% · ұяшық: %slots%',
      'ky': 'Текче: %shelves% · уяча: %slots%',
      'en': 'Shelves: %shelves% · slots: %slots%',
    },
    'le_describe_twins': {
      'ru': '%base% · сдвоенных: %n%',
      'kk': '%base% · қос: %n%',
      'ky': '%base% · кош: %n%',
      'en': '%base% · twins: %n%',
    },
    'le_templates_title': {
      'ru': 'Шаблоны раскладки',
      'kk': 'Сызба үлгілері',
      'ky': 'Жайгаштыруу үлгүлөрү',
      'en': 'Layout templates',
    },
    'le_templates_hint': {
      'ru': 'Шаблон заменит текущую раскладку целиком. Подписи и моторы '
          'можно править после применения.',
      'kk': 'Үлгі ағымдағы сызбаны толығымен ауыстырады. Белгілер мен '
          'моторларды қолданғаннан кейін өңдеуге болады.',
      'ky': 'Үлгү учурдагы жайгаштырууну толугу менен алмаштырат. '
          'Белгилерди жана моторлорду колдонгондон кийин оңдоого '
          'болот.',
      'en': 'A template replaces the whole current layout. Labels and '
          'motors stay editable afterwards.',
    },
    'le_factory_templates': {
      'ru': 'ЗАВОДСКИЕ',
      'kk': 'ЗАУЫТТЫҚ',
      'ky': 'ЗАВОДДУК',
      'en': 'FACTORY',
    },
    'le_my_templates': {
      'ru': 'МОИ ШАБЛОНЫ',
      'kk': 'МЕНІҢ ҮЛГІЛЕРІМ',
      'ky': 'МЕНИН ҮЛГҮЛӨРҮМ',
      'en': 'MY TEMPLATES',
    },
    'le_delete_template': {
      'ru': 'Удалить шаблон',
      'kk': 'Үлгіні жою',
      'ky': 'Үлгүнү өчүрүү',
      'en': 'Delete the template',
    },
    'le_delete_template_q': {
      'ru': 'Удалить шаблон?',
      'kk': 'Үлгіні жою керек пе?',
      'ky': 'Үлгү өчүрүлсүнбү?',
      'en': 'Delete the template?',
    },
    'le_delete_template_body': {
      'ru': '«%name%» будет удалён. Текущая раскладка не изменится.',
      'kk': '«%name%» жойылады. Ағымдағы сызба өзгермейді.',
      'ky': '«%name%» өчүрүлөт. Учурдагы жайгаштыруу өзгөрбөйт.',
      'en': '"%name%" will be deleted. The current layout stays as it '
          'is.',
    },
    'le_overwrite_layout_q': {
      'ru': 'Перезаписать раскладку?',
      'kk': 'Сызбаны қайта жазу керек пе?',
      'ky': 'Жайгаштыруу кайра жазылсынбы?',
      'en': 'Overwrite the layout?',
    },
    'le_overwrite_layout_body': {
      'ru': 'Текущая раскладка будет заменена на «%name%». Подписи и '
          'моторы можно будет править после применения.',
      'kk': 'Ағымдағы сызба «%name%» үлгісіне ауыстырылады. Белгілер '
          'мен моторларды кейін өңдеуге болады.',
      'ky': 'Учурдагы жайгаштыруу «%name%» үлгүсүнө алмаштырылат. '
          'Белгилерди жана моторлорду кийин оңдоого болот.',
      'en': 'The current layout will be replaced with "%name%". Labels '
          'and motors stay editable afterwards.',
    },
    'le_shelf_n': {
      'ru': 'Полка %n%',
      'kk': 'Сөре %n%',
      'ky': 'Текче %n%',
      'en': 'Shelf %n%',
    },
    'le_shelf_name': {
      'ru': 'Название полки',
      'kk': 'Сөре атауы',
      'ky': 'Текченин аты',
      'en': 'Shelf name',
    },
    'le_slot': {
      'ru': 'Слот',
      'kk': 'Слот',
      'ky': 'Слот',
      'en': 'Slot',
    },
    'le_scanning': {
      'ru': 'Сканирование %n% / 100…',
      'kk': 'Сканерлеу %n% / 100…',
      'ky': 'Скандоо %n% / 100…',
      'en': 'Scanning %n% / 100…',
    },
    'le_scan_motors': {
      'ru': 'Сканировать моторы',
      'kk': 'Моторларды сканерлеу',
      'ky': 'Моторлорду скандоо',
      'en': 'Scan the motors',
    },
    'le_slot_label_mm': {
      'ru': 'Подпись ячейки',
      'kk': 'Ұяшық белгісі',
      'ky': 'Уячанын белгиси',
      'en': 'Slot label',
    },
    'le_slot_label': {
      'ru': 'Подпись слота',
      'kk': 'Слот белгісі',
      'ky': 'Слоттун белгиси',
      'en': 'Slot label',
    },
    'le_optional': {
      'ru': 'необязательно',
      'kk': 'міндетті емес',
      'ky': 'милдеттүү эмес',
      'en': 'optional',
    },
    'le_slot_label_hint': {
      'ru': 'например 001',
      'kk': 'мысалы 001',
      'ky': 'мисалы 001',
      'en': 'for example 001',
    },
    'le_pick_cell_hint': {
      'ru': 'Выберите номер ячейки — тот, что написан на полке.  %n% '
          'выбрано.',
      'kk': 'Ұяшық нөмірін таңдаңыз — сөреде жазылғанын.  %n% таңдалды.',
      'ky': 'Уяча номерин тандаңыз — текчеде жазылганын.  %n% тандалды.',
      'en': 'Pick the slot number — the one written on the shelf.  %n% '
          'selected.',
    },
    'le_pick_lyt_hint': {
      'ru': 'Задайте позицию мотора рядом и колонкой (2+ позиции для '
          'сдвоенного слота).  %n% выбрано.',
      'kk': 'Мотор орнын қатар мен бағанмен беріңіз (қос слот үшін 2+ '
          'орын).  %n% таңдалды.',
      'ky': 'Мотордун ордун катар жана тилке менен бериңиз (кош слот '
          'үчүн 2+ орун).  %n% тандалды.',
      'en': 'Set the motor position by row and column (2+ positions for '
          'a twin slot).  %n% selected.',
    },
    'le_pick_motor_hint': {
      'ru': 'Выберите motor id (1+ для сдвоенного слота).  %n% выбрано.',
      'kk': 'motor id таңдаңыз (қос слот үшін 1+).  %n% таңдалды.',
      'ky': 'motor id тандаңыз (кош слот үчүн 1+).  %n% тандалды.',
      'en': 'Pick a motor id (1+ for a twin slot).  %n% selected.',
    },
    'le_row_l': {
      'ru': 'Ряд (L)',
      'kk': 'Қатар (L)',
      'ky': 'Катар (L)',
      'en': 'Row (L)',
    },
    'le_col_c': {
      'ru': 'Колонка (C)',
      'kk': 'Баған (C)',
      'ky': 'Тилке (C)',
      'en': 'Column (C)',
    },
    'le_add': {
      'ru': 'Добавить',
      'kk': 'Қосу',
      'ky': 'Кошуу',
      'en': 'Add',
    },
    'le_pos_taken': {
      'ru': 'Эта позиция уже занята другим слотом',
      'kk': 'Бұл орынды басқа слот алып қойған',
      'ky': 'Бул орунду башка слот ээлеп алган',
      'en': 'That position already belongs to another slot',
    },
    'le_save_slot': {
      'ru': 'Сохранить слот',
      'kk': 'Слотты сақтау',
      'ky': 'Слотту сактоо',
      'en': 'Save the slot',
    },
    'le_pick_template': {
      'ru': 'Выбрать шаблон',
      'kk': 'Үлгі таңдау',
      'ky': 'Үлгү тандоо',
      'en': 'Pick a template',
    },
    'le_done': {
      'ru': 'Готово',
      'kk': 'Дайын',
      'ky': 'Даяр',
      'en': 'Done',
    },
    'le_cells_n': {
      'ru': '%n% ячеек',
      'kk': '%n% ұяшық',
      'ky': '%n% уяча',
      'en': '%n% slots',
    },
    'le_shelf_menu': {
      'ru': 'Переименовать или удалить полку',
      'kk': 'Сөрені қайта атау немесе жою',
      'ky': 'Текчени кайра атоо же өчүрүү',
      'en': 'Rename or delete the shelf',
    },
    'le_shelf': {
      'ru': 'Полка',
      'kk': 'Сөре',
      'ky': 'Текче',
      'en': 'Shelf',
    },
    'le_rename': {
      'ru': 'Переименовать',
      'kk': 'Қайта атау',
      'ky': 'Кайра атоо',
      'en': 'Rename',
    },
    'le_delete_shelf': {
      'ru': 'Удалить полку',
      'kk': 'Сөрені жою',
      'ky': 'Текчени өчүрүү',
      'en': 'Delete the shelf',
    },
    'le_add_shelf_first': {
      'ru': 'Добавьте полку слева, чтобы начать раскладку',
      'kk': 'Сызбаны бастау үшін сол жақтан сөре қосыңыз',
      'ky': 'Жайгаштырууну баштоо үчүн сол жактан текче кошуңуз',
      'en': 'Add a shelf on the left to start the layout',
    },
    'le_cells_hint_mm': {
      'ru': 'Ячеек: %n% · нажмите на ячейку, чтобы изменить номер и '
          'подпись',
      'kk': 'Ұяшық: %n% · нөмірі мен белгісін өзгерту үшін ұяшықты '
          'басыңыз',
      'ky': 'Уяча: %n% · номерин жана белгисин өзгөртүү үчүн уячаны '
          'басыңыз',
      'en': 'Slots: %n% · tap a slot to change its number and label',
    },
    'le_cells_hint': {
      'ru': 'Ячеек: %n% · нажмите на ячейку, чтобы изменить подпись и '
          'моторы',
      'kk': 'Ұяшық: %n% · белгісі мен моторларын өзгерту үшін ұяшықты '
          'басыңыз',
      'ky': 'Уяча: %n% · белгисин жана моторлорун өзгөртүү үчүн уячаны '
          'басыңыз',
      'en': 'Slots: %n% · tap a slot to change its label and motors',
    },
    'le_add_cell': {
      'ru': 'Добавить ячейку',
      'kk': 'Ұяшық қосу',
      'ky': 'Уяча кошуу',
      'en': 'Add a slot',
    },
    'le_no_cells': {
      'ru': 'Ячеек ещё нет — нажмите «Добавить ячейку»',
      'kk': 'Әзірге ұяшық жоқ — «Ұяшық қосу» түймесін басыңыз',
      'ky': 'Азырынча уяча жок — «Уяча кошуу» баскычын басыңыз',
      'en': 'No slots yet — tap "Add a slot"',
    },
    'le_edit_cell': {
      'ru': 'Изменить ячейку',
      'kk': 'Ұяшықты өзгерту',
      'ky': 'Уячаны өзгөртүү',
      'en': 'Edit the slot',
    },
    'le_delete_cell': {
      'ru': 'Удалить ячейку',
      'kk': 'Ұяшықты жою',
      'ky': 'Уячаны өчүрүү',
      'en': 'Delete the slot',
    },
    'le_twin': {
      'ru': 'СДВОЕННАЯ',
      'kk': 'ҚОС',
      'ky': 'КОШ',
      'en': 'TWIN',
    },
    'le_cell_prefix': {
      'ru': 'ячейка %ids%',
      'kk': 'ұяшық %ids%',
      'ky': 'уяча %ids%',
      'en': 'slot %ids%',
    },
    'le_legend_lyt': {
      'ru': 'Ряд (L) — полка сверху вниз, колонка (C) — мотор слева '
          'направо. Если крутится не тот мотор — включите '
          '«Ряд↔колонка» во вкладке «Плата».',
      'kk': 'Қатар (L) — сөре жоғарыдан төмен, баған (C) — мотор солдан '
          'оңға. Басқа мотор айналса — «Плата» қойындысында '
          '«Қатар↔баған» қосыңыз.',
      'ky': 'Катар (L) — текче жогорудан ылдый, тилке (C) — мотор '
          'солдон оңго. Башка мотор айланса — «Плата» өтмөгүндө '
          '«Катар↔тилке» күйгүзүңүз.',
      'en': 'Row (L) is the shelf top to bottom, column (C) the motor '
          'left to right. If the wrong motor spins, turn on "Swap row '
          '↔ column" in the Board tab.',
    },
    'le_legend_aa': {
      'ru': 'AA — мотор подключён',
      'kk': 'AA — мотор қосылған',
      'ky': 'AA — мотор туташтырылган',
      'en': 'AA — motor connected',
    },
    'le_legend_bb': {
      'ru': 'BB — пусто / обрыв',
      'kk': 'BB — бос / үзіліс',
      'ky': 'BB — бош / үзүлүү',
      'en': 'BB — empty / open circuit',
    },
    'le_legend_cc': {
      'ru': 'CC — перегрузка',
      'kk': 'CC — шамадан тыс жүктеме',
      'ky': 'CC — ашыкча жүктөм',
      'en': 'CC — overload',
    },
    'le_legend_sel': {
      'ru': 'выбран',
      'kk': 'таңдалды',
      'ky': 'тандалды',
      'en': 'selected',
    },
    // Service PIN and lock
    'pin_min_digits': {
      'ru': 'Минимум %n% цифры',
      'kk': 'Кемінде %n% сан',
      'ky': 'Кеминде %n% сан',
      'en': 'At least %n% digits',
    },
    'pin_too_simple': {
      'ru': 'Слишком простой PIN',
      'kk': 'PIN тым қарапайым',
      'ky': 'PIN өтө жөнөкөй',
      'en': 'That PIN is too easy to guess',
    },
    'unlock_opened': {
      'ru': 'Замок открыт',
      'kk': 'Құлып ашылды',
      'ky': 'Кулпу ачылды',
      'en': 'The lock is open',
    },
    // Service mode — PIN change
    'pin_new': {
      'ru': 'Новый PIN',
      'kk': 'Жаңа PIN',
      'ky': 'Жаңы PIN',
      'en': 'New PIN',
    },
    'pin_change_hint': {
      'ru': 'Введите новый PIN дважды — так опечатка не запрёт вход в '
          'сервисный режим.',
      'kk': 'Жаңа PIN-ді екі рет енгізіңіз — сонда қате басу сервистік '
          'режимге кіруді бөгемейді.',
      'ky': 'Жаңы PIN\'ди эки жолу киргизиңиз — ошондо ката басуу тейлөө '
          'режимине киргизбей койбойт.',
      'en': 'Enter the new PIN twice — a typo then cannot lock you out '
          'of service mode.',
    },
  };
}
