import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../board/board_client.dart';
import '../services/strings.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import '../widgets/product_thumb.dart';
import 'payment_screen.dart';

class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(s.t('cart').toUpperCase(),
            style: const TextStyle(
                fontWeight: FontWeight.w900,
                letterSpacing: -0.5,
                fontSize: 22)),
      ),
      body: Consumer<VendingService>(
        builder: (context, svc, _) {
          if (svc.cartIsEmpty) {
            return Center(
              child: Text(s.t('cart_empty'),
                  style: const TextStyle(
                      color: AppColors.onSurfaceVariant,
                      fontSize: 14)),
            );
          }
          return Column(
            children: [
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  itemCount: svc.cartItems.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    final item = svc.cartItems[i];
                    return Container(
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: const [appCardShadow],
                      ),
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          // Same thumbnail as the catalog so the customer
                          // visually recognises the product they tapped —
                          // earlier we showed only the emoji here even
                          // when image_url was set, which broke that
                          // recognition.
                          ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Container(
                              width: 64,
                              height: 64,
                              color: AppColors.surfaceContainerLow,
                              alignment: Alignment.center,
                              child: ProductThumb(
                                product: item.product,
                                emojiSize: 32,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.product.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                        letterSpacing: -0.3,
                                        color: AppColors.onSurface)),
                                const SizedBox(height: 4),
                                Text(
                                  '${s.t('shelf')} ${item.product.shelfLabel}',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color:
                                          AppColors.onSurfaceVariant),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    _RoundIconButton(
                                      icon: Icons.remove,
                                      onTap: () => svc
                                          .removeOne(item.product.motorId),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12),
                                      child: Text(
                                        '${item.quantity}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: 14,
                                            color: AppColors.primary),
                                      ),
                                    ),
                                    _RoundIconButton(
                                      icon: Icons.add,
                                      filled: true,
                                      onTap: () =>
                                          svc.addToCart(item.product),
                                    ),
                                    const Spacer(),
                                    Text(
                                      '${item.totalTenge} ₸',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16,
                                          color: AppColors.primary,
                                          letterSpacing: -0.3),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              _PayBar(),
            ],
          );
        },
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: filled
          ? AppColors.primary
          : AppColors.surfaceContainerLow,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(
            icon,
            size: 16,
            color: filled
                ? AppColors.onPrimary
                : AppColors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _PayBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final svc = context.watch<VendingService>();
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainerLowest,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 24,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.t('cart_total').toUpperCase(),
                      style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                          color: AppColors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${svc.cartTotalTenge} ₸',
                      style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w900,
                          color: AppColors.onSurface,
                          letterSpacing: -1),
                    ),
                  ],
                ),
                const Spacer(),
                Expanded(
                  child: SizedBox(
                    height: 64,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.kaspi,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: () => _goToPayment(context, svc),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            s.t('pay_btn').toUpperCase(),
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.qr_code_2, size: 28),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              icon: const Icon(Icons.delete_outline,
                  size: 16, color: AppColors.onSurfaceVariant),
              label: Text(
                s.t('clear_cart'),
                style: const TextStyle(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
              ),
              onPressed: svc.clearCart,
            ),
          ],
        ),
      ),
    );
  }

  void _goToPayment(BuildContext context, VendingService svc) {
    final s = context.read<Strings>();
    final board = context.read<BoardClient>();
    if (!board.isConnected && !kDebugMode) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.t('board_not_found')),
          backgroundColor: const Color(0xFFB3261E),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PaymentScreen()),
    );
  }
}
