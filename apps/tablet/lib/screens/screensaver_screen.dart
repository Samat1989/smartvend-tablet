import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models/motor_layout.dart';
import '../models/product.dart';
import '../services/media_service.dart';
import '../services/strings.dart';
import '../services/vending_service.dart';
import '../theme.dart';
import '../widgets/product_thumb.dart';

/// Full-screen attract loop that takes over when the customer hasn't
/// interacted with the kiosk for a while. Cycles each shelf in turn
/// so the cabinet's whole inventory is shown to passers-by.
///
/// Tap anywhere → pops back to the catalog instantly.
///
/// Future iteration will interleave operator-supplied images / videos
/// from `lib/services/media_service.dart`; the cycle infrastructure
/// here is built to handle that case (the [_Slide] enum + page list).
class ScreensaverScreen extends StatefulWidget {
  const ScreensaverScreen({super.key});

  @override
  State<ScreensaverScreen> createState() => _ScreensaverScreenState();
}

class _ScreensaverScreenState extends State<ScreensaverScreen> {
  static const Duration _slideDwell = Duration(seconds: 3);

  Timer? _timer;
  int _currentIndex = 0;
  VideoPlayerController? _videoController;
  String? _videoForPath;

  @override
  void initState() {
    super.initState();
    // Re-scan media right when the attract loop starts so newly
    // copied files appear without restarting the app.
    context.read<MediaService>().refresh();
    _timer = Timer.periodic(_slideDwell, (_) {
      final slides = _buildSlides();
      if (slides.isEmpty) return;
      setState(() => _currentIndex = (_currentIndex + 1) % slides.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _videoController?.dispose();
    super.dispose();
  }

  /// Same shelf-resolution rule the catalog uses (MachineLayout first,
  /// MotorLayout fallback), so the screensaver mirrors whatever the
  /// customer would see if they tapped the screen and resumed shopping.
  List<_ShelfData> _buildShelves(VendingService svc) {
    final byMotor = {for (final p in svc.catalog) p.motorId: p};
    final layout = svc.layout;
    if (layout.isNotEmpty) {
      return [
        for (final sh in layout.shelves)
          _ShelfData(
            label: sh.label,
            products: [
              for (final slot in sh.slots)
                if (byMotor[slot.primaryMotorId] != null)
                  byMotor[slot.primaryMotorId]!,
            ],
          ),
      ];
    }
    return [
      for (var s = 1; s <= MotorLayout.rows; s++)
        _ShelfData(
          label: MotorLayout.shelfLabelRange(s),
          products: [
            for (final m in MotorLayout.motorsForShelf(s))
              if (byMotor[m] != null) byMotor[m]!,
          ],
        ),
    ];
  }

  /// Combine shelves with media files into one round-robin list. Media
  /// gets sprinkled between shelves so the loop never shows two media
  /// files in a row when at least one shelf has products.
  List<_Slide> _buildSlides() {
    final svc = context.read<VendingService>();
    final media = context.read<MediaService>().items;
    final shelves = _buildShelves(svc)
        .where((sh) => sh.products.isNotEmpty)
        .map<_Slide>(_ShelfSlide.new)
        .toList();
    if (media.isEmpty) return shelves;
    if (shelves.isEmpty) return media.map<_Slide>(_MediaSlide.new).toList();
    final out = <_Slide>[];
    var mi = 0;
    for (final sh in shelves) {
      out.add(sh);
      if (mi < media.length) {
        out.add(_MediaSlide(media[mi]));
        mi++;
      }
    }
    while (mi < media.length) {
      out.add(_MediaSlide(media[mi]));
      mi++;
    }
    return out;
  }

  Future<void> _attachVideoIfNeeded(_Slide slide) async {
    if (slide is! _MediaSlide || slide.item.kind != MediaKind.video) {
      if (_videoController != null) {
        await _videoController!.dispose();
        _videoController = null;
        _videoForPath = null;
      }
      return;
    }
    if (_videoForPath == slide.item.path && _videoController != null) return;
    final old = _videoController;
    _videoController = null;
    _videoForPath = null;
    await old?.dispose();
    final ctrl = VideoPlayerController.file(File(slide.item.path));
    try {
      await ctrl.initialize();
      await ctrl.setLooping(true);
      await ctrl.setVolume(0); // silent attract loop
      await ctrl.play();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      setState(() {
        _videoController = ctrl;
        _videoForPath = slide.item.path;
      });
    } catch (e) {
      // Bad video file (codec unsupported, corrupt) — fall through;
      // the slide will render the "media unavailable" placeholder.
      await ctrl.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch media so a refresh() during the loop redraws.
    context.watch<MediaService>();
    context.watch<VendingService>();
    final s = context.watch<Strings>();
    final slides = _buildSlides();
    final slide = slides.isEmpty
        ? null
        : slides[_currentIndex % slides.length];
    // Kick off video init when a video slide rolls in. fire-and-forget;
    // the controller's own listener triggers a rebuild via setState.
    if (slide != null) {
      // Schedule for after this build frame to avoid setState-in-build.
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _attachVideoIfNeeded(slide));
    }
    return Scaffold(
      backgroundColor: AppColors.iosBackground,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: SafeArea(
          child: slide == null
              ? Center(
                  child: Text(
                    s.t('cart_empty'),
                    style: const TextStyle(
                      color: AppColors.iosGray,
                      fontSize: 18,
                    ),
                  ),
                )
              : AnimatedSwitcher(
                  duration: const Duration(milliseconds: 600),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.04),
                        end: Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  ),
                  child: _renderSlide(
                    slide,
                    index: _currentIndex % slides.length,
                    total: slides.length,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _renderSlide(_Slide slide, {required int index, required int total}) {
    return switch (slide) {
      _ShelfSlide(:final data) => _ShelfSlideView(
          key: ValueKey('shelf-$index-${data.label}'),
          shelf: data,
          index: index,
          total: total,
        ),
      _MediaSlide(:final item) => _MediaSlideView(
          key: ValueKey('media-$index-${item.path}'),
          item: item,
          controller: _videoForPath == item.path ? _videoController : null,
          index: index,
          total: total,
        ),
    };
  }
}

/// One step of the attract loop. Kept as a sealed family so the
/// render switch is exhaustive.
sealed class _Slide {
  const _Slide();
}

class _ShelfSlide extends _Slide {
  const _ShelfSlide(this.data);
  final _ShelfData data;
}

class _MediaSlide extends _Slide {
  const _MediaSlide(this.item);
  final MediaItem item;
}

class _ShelfData {
  const _ShelfData({required this.label, required this.products});
  final String label;
  final List<Product> products;
}

class _ShelfSlideView extends StatelessWidget {
  const _ShelfSlideView({
    super.key,
    required this.shelf,
    required this.index,
    required this.total,
  });

  final _ShelfData shelf;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  shelf.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.iosBlack,
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              _Dots(index: index, total: total),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                // 3 cols when there's room (wider tablets / landscape),
                // 2 cols otherwise. Cards are big to grab attention from
                // across the room.
                final cols = c.maxWidth >= 720 ? 3 : 2;
                return GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisSpacing: 20,
                    crossAxisSpacing: 20,
                    childAspectRatio: 0.78,
                  ),
                  itemCount: shelf.products.length,
                  itemBuilder: (ctx, i) => _ShowcaseCard(product: shelf.products[i]),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              'Коснитесь, чтобы выбрать',
              style: TextStyle(
                color: AppColors.iosGray.withValues(alpha: 0.7),
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.index, required this.total});
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < total; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == index ? 26 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i == index
                  ? AppColors.iosBlue
                  : AppColors.iosGray.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}

class _ShowcaseCard extends StatelessWidget {
  const _ShowcaseCard({required this.product});
  final Product product;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.all(Radius.circular(24)),
        boxShadow: iosCardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 4,
            child: ColoredBox(
              color: AppColors.iosBackground,
              child: ProductThumb(
                product: product,
                emojiSize: 72,
                fit: BoxFit.cover,
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      product.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.iosBlack,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.1,
                        height: 1.15,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${product.priceTenge} ₸',
                    style: const TextStyle(
                      color: AppColors.iosOrange,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Image or video slide. Image branch just renders Image.file; video
/// branch expects an already-initialised [VideoPlayerController]
/// from [_ScreensaverScreenState._attachVideoIfNeeded] — if it's null
/// (init pending or failed) we show a loading dot so the loop keeps
/// moving instead of freezing on a black frame.
class _MediaSlideView extends StatelessWidget {
  const _MediaSlideView({
    super.key,
    required this.item,
    required this.controller,
    required this.index,
    required this.total,
  });

  final MediaItem item;
  final VideoPlayerController? controller;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Spacer(),
              _Dots(index: index, total: total),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: ColoredBox(
                color: Colors.black,
                child: Center(child: _renderBody()),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              'Коснитесь, чтобы выбрать',
              style: TextStyle(
                color: AppColors.iosGray.withValues(alpha: 0.7),
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _renderBody() {
    switch (item.kind) {
      case MediaKind.image:
        return Image.file(
          File(item.path),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Icon(
            Icons.broken_image,
            color: Colors.white24,
            size: 64,
          ),
        );
      case MediaKind.video:
        final c = controller;
        if (c == null || !c.value.isInitialized) {
          return const CircularProgressIndicator(color: Colors.white24);
        }
        return AspectRatio(
          aspectRatio: c.value.aspectRatio,
          child: VideoPlayer(c),
        );
    }
  }
}
