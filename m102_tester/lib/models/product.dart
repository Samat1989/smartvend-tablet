import 'motor_layout.dart';

/// A product slot — one cell on the cabinet.
class Product {
  /// Supabase inventory row UUID (null for placeholder/un-mapped slots).
  final String? id;
  final int motorId;        // protocol id (44..99)
  final String shelfLabel;  // "001".."056"
  final String name;
  final int priceTenge;     // price in KZT (whole tenge, no kopecks)
  final int motorType;      // 2 = 2-wire (default), 3 = 3-wire
  final int curtainMode;    // 0 = no curtain, 1 = present, 2 = priority
  final int stock;          // current inventory count
  final String? emoji;      // simple visual placeholder
  final String? imageUrl;   // optional product image from DB
  /// Optional FK to `public.categories.id` — drives the catalog filter
  /// chips and is editable from the product form.
  final String? categoryId;

  const Product({
    this.id,
    required this.motorId,
    required this.shelfLabel,
    required this.name,
    required this.priceTenge,
    this.motorType = 2,
    this.curtainMode = 0,
    this.stock = 5,
    this.emoji,
    this.imageUrl,
    this.categoryId,
  });

  Product copyWith({
    String? id,
    String? name,
    int? priceTenge,
    int? motorType,
    int? curtainMode,
    int? stock,
    String? emoji,
    String? imageUrl,
    String? categoryId,
  }) =>
      Product(
        id: id ?? this.id,
        motorId: motorId,
        shelfLabel: shelfLabel,
        name: name ?? this.name,
        priceTenge: priceTenge ?? this.priceTenge,
        motorType: motorType ?? this.motorType,
        curtainMode: curtainMode ?? this.curtainMode,
        stock: stock ?? this.stock,
        emoji: emoji ?? this.emoji,
        imageUrl: imageUrl ?? this.imageUrl,
        categoryId: categoryId ?? this.categoryId,
      );

  bool get inStock => stock > 0;
  bool get isMapped => id != null;
}

/// Build a placeholder catalog covering all 36 physical slots.
/// Used when the device is not paired or the DB has no rows for the slot —
/// the UI shows them greyed-out / "не назначено".
List<Product> placeholderCatalog() {
  final motors = MotorLayout.allMotors().toList();
  return [
    for (final m in motors)
      Product(
        motorId: m,
        shelfLabel: MotorLayout.motorToLabel(m),
        name: 'Слот ${MotorLayout.motorToLabel(m)}',
        priceTenge: 0,
        stock: 0,
        emoji: '📦',
      ),
  ];
}
