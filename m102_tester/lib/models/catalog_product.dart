/// Catalog SKU — a product definition that lives independently of any
/// specific cabinet slot. Owned at the Supabase level by the same
/// `owner_id` that owns the micromarkets. Created and edited in the
/// admin panel (customer_web); the tablet only reads from this table
/// to populate the "Выбрать из каталога" picker.
///
/// `inventory.product_id` references one of these — that's where
/// per-slot fields like price, stock and motor wiring live.
class CatalogProduct {
  const CatalogProduct({
    required this.id,
    required this.name,
    this.imageUrl,
    this.emoji,
    this.categoryId,
    this.volumeMl,
    this.description,
    this.isDraft = false,
    this.isArchived = false,
  });

  final String id;
  final String name;
  final String? imageUrl;
  final String? emoji;
  final String? categoryId;
  final int? volumeMl;
  final String? description;

  /// True for entries the tablet auto-created when the operator typed a
  /// product name manually without picking from the catalog. Admin can
  /// review and promote/edit them later.
  final bool isDraft;

  /// Hidden in the picker. Existing inventory rows that already
  /// referenced this product still work; only the picker filters it
  /// out.
  final bool isArchived;

  static CatalogProduct fromJson(Map<String, dynamic> j) => CatalogProduct(
        id: j['id'] as String,
        name: j['name']?.toString() ?? '',
        imageUrl: j['image_url']?.toString(),
        emoji: j['emoji']?.toString(),
        categoryId: j['category_id']?.toString(),
        volumeMl: (j['volume_ml'] as num?)?.toInt(),
        description: j['description']?.toString(),
        isDraft: j['is_draft'] == true,
        isArchived: j['is_archived'] == true,
      );
}
