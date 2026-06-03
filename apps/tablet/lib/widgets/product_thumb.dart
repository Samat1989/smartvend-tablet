import 'package:flutter/material.dart';

import '../models/product.dart';

/// Renders a product picture with graceful degradation:
///   1. Try `product.imageUrl` (Supabase Storage URL)
///   2. While loading or on network failure → fall back to the emoji
///   3. No emoji either → generic 📦 box
///
/// Used in both the customer-facing catalog and the cart, so the same
/// product looks identical in both places.
class ProductThumb extends StatelessWidget {
  const ProductThumb({
    super.key,
    required this.product,
    this.emojiSize = 48,
    this.fit = BoxFit.contain,
  });

  final Product product;
  final double emojiSize;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final url = product.imageUrl;
    final fallback = Center(
      child: Text(
        product.emoji ?? '📦',
        style: TextStyle(fontSize: emojiSize),
      ),
    );
    if (url == null || url.isEmpty) return fallback;
    return Image.network(
      url,
      fit: fit,
      errorBuilder: (_, _, _) => fallback,
      loadingBuilder: (ctx, child, progress) =>
          progress == null ? child : fallback,
    );
  }
}
