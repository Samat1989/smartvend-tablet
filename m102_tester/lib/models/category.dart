/// Product category fetched from the `public.categories` Supabase table.
/// Has parallel localized names for the three UI languages (ru/kk/en).
class Category {
  final String id;
  final String nameRu;
  final String nameKk;
  final String nameEn;

  const Category({
    required this.id,
    required this.nameRu,
    required this.nameKk,
    required this.nameEn,
  });

  /// Returns the name for the given language code (`ru`, `kk`, or `en`),
  /// falling back to RU when a translation is missing/empty.
  String localizedName(String lang) {
    switch (lang) {
      case 'kk':
        return nameKk.isNotEmpty ? nameKk : nameRu;
      case 'en':
        return nameEn.isNotEmpty ? nameEn : nameRu;
      default:
        return nameRu;
    }
  }
}
