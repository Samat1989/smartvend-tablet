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
  };
}
