part of 'app.dart';

// ─────────────────────────────────────────────────────────
// Location Spend Map & Trajectory Page
// ─────────────────────────────────────────────────────────

class LocationSpendMapPage extends StatefulWidget {
  const LocationSpendMapPage({required this.book, super.key});

  final LedgerBook book;

  @override
  State<LocationSpendMapPage> createState() => _LocationSpendMapPageState();
}

class _LocationSpendMapPageState extends State<LocationSpendMapPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5FAFF),
      appBar: AppBar(
        title: Text(
          '消费地图',
          style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.bubble_chart_rounded), text: '热力分布'),
            Tab(icon: Icon(Icons.timeline_rounded), text: '消费轨迹'),
          ],
          indicatorColor: const Color(0xFF5C6BC0),
          labelColor: const Color(0xFF5C6BC0),
          unselectedLabelColor: const Color(0xFF7A869C),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _SpendHeatmapTab(book: widget.book),
          _SpendTrajectoryTab(book: widget.book),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
// Tab 1: Heatmap Bubble Map
// ─────────────────────────────────────────────────────────

class _SpendHeatmapTab extends StatelessWidget {
  const _SpendHeatmapTab({required this.book});

  final LedgerBook book;

  @override
  Widget build(BuildContext context) {
    final geoEntries = book.entries
        .where((e) =>
            e.latitude != null &&
            e.longitude != null &&
            e.type == EntryType.expense)
        .toList();

    if (geoEntries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.location_off_rounded,
                  size: 64, color: const Color(0xFFB0BEC5)),
              const SizedBox(height: 16),
              Text(
                '暂无位置数据',
                style: GoogleFonts.spaceGrotesk(
                    fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                '开启位置记账后，消费记录将自动带上经纬度坐标，这里会展示你的消费地理分布。',
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                    color: const Color(0xFF60708A), height: 1.6),
              ),
            ],
          ),
        ),
      );
    }

    // Group by location (cluster nearby points within 100m)
    final clusters = _clusterEntries(geoEntries);

    // Calculate map bounds
    final lats = geoEntries.map((e) => e.latitude!).toList();
    final lons = geoEntries.map((e) => e.longitude!).toList();
    final centerLat = (lats.reduce(math.min) + lats.reduce(math.max)) / 2;
    final centerLon = (lons.reduce(math.min) + lons.reduce(math.max)) / 2;
    final totalSpend = geoEntries.fold<double>(0, (s, e) => s + e.amount);

    return Column(
      children: [
        // Summary bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          color: const Color(0xFFE8EAF6),
          child: Row(
            children: [
              const Icon(Icons.pin_drop_rounded,
                  color: Color(0xFF5C6BC0), size: 20),
              const SizedBox(width: 8),
              Text(
                '${clusters.length} 个消费地点',
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF3F51B5)),
              ),
              const Spacer(),
              Text(
                '总计 ${_safeCurrencyFormatter.format(totalSpend)}',
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF283593)),
              ),
            ],
          ),
        ),
        // Map
        Expanded(
          child: FlutterMap(
            options: MapOptions(
              initialCenter: LatLng(centerLat, centerLon),
              initialZoom: 13,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.chaoxi.ledger',
              ),
              MarkerLayer(
                markers: [
                  for (final cluster in clusters)
                    Marker(
                      point: LatLng(cluster.latitude, cluster.longitude),
                      width: _bubbleSize(cluster.totalAmount, totalSpend),
                      height: _bubbleSize(cluster.totalAmount, totalSpend),
                      child: GestureDetector(
                        onTap: () => _showClusterDetail(context, cluster),
                        child: _SpendBubble(
                          amount: cluster.totalAmount,
                          count: cluster.entries.length,
                          maxAmount: totalSpend,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  double _bubbleSize(double amount, double total) {
    final ratio = total > 0 ? (amount / total) : 0.1;
    return (40 + ratio * 80).clamp(40.0, 120.0);
  }

  void _showClusterDetail(BuildContext context, _SpendCluster cluster) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.location_on,
                    color: Color(0xFF5C6BC0), size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    cluster.label,
                    style: GoogleFonts.spaceGrotesk(
                        fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${cluster.entries.length} 笔消费 · 合计 ${_safeCurrencyFormatter.format(cluster.totalAmount)}',
              style: GoogleFonts.plusJakartaSans(
                  color: const Color(0xFF60708A)),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: cluster.entries.length.clamp(0, 10),
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final e = cluster.entries[i];
                  final cat = categoryForId(e.categoryId);
                  return ListTile(
                    dense: true,
                    leading: Icon(cat.icon, color: cat.color, size: 20),
                    title: Text(e.title,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        DateFormat('MM/dd HH:mm').format(e.occurredAt)),
                    trailing: Text(
                      _safeCurrencyFormatter.format(e.amount),
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: cat.color),
                    ),
                  );
                },
              ),
            ),
            if (cluster.entries.length > 10)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '还有 ${cluster.entries.length - 10} 笔...',
                  style: GoogleFonts.plusJakartaSans(
                      color: const Color(0xFF7A869C)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<_SpendCluster> _clusterEntries(List<LedgerEntry> entries) {
    final clusters = <_SpendCluster>[];
    for (final entry in entries) {
      bool merged = false;
      for (final cluster in clusters) {
        final dist = LocationHelper.distanceMeters(
          cluster.latitude,
          cluster.longitude,
          entry.latitude!,
          entry.longitude!,
        );
        if (dist < 150) {
          cluster.entries.add(entry);
          cluster.totalAmount += entry.amount;
          merged = true;
          break;
        }
      }
      if (!merged) {
        clusters.add(_SpendCluster(
          latitude: entry.latitude!,
          longitude: entry.longitude!,
          label: entry.locationInfo.isNotEmpty
              ? entry.locationInfo
              : entry.merchant,
          entries: [entry],
          totalAmount: entry.amount,
        ));
      }
    }
    clusters.sort((a, b) => b.totalAmount.compareTo(a.totalAmount));
    return clusters;
  }
}

class _SpendCluster {
  _SpendCluster({
    required this.latitude,
    required this.longitude,
    required this.label,
    required this.entries,
    required this.totalAmount,
  });

  final double latitude;
  final double longitude;
  final String label;
  final List<LedgerEntry> entries;
  double totalAmount;
}

class _SpendBubble extends StatelessWidget {
  const _SpendBubble({
    required this.amount,
    required this.count,
    required this.maxAmount,
  });

  final double amount;
  final int count;
  final double maxAmount;

  @override
  Widget build(BuildContext context) {
    final ratio = maxAmount > 0 ? (amount / maxAmount).clamp(0.2, 1.0) : 0.5;
    final color = Color.lerp(
      const Color(0xFF7986CB),
      const Color(0xFFE53935),
      ratio,
    )!;
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.6),
        border: Border.all(color: color, width: 2),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.3),
            blurRadius: 8,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '¥${amount >= 1000 ? '${(amount / 1000).toStringAsFixed(1)}k' : amount.toStringAsFixed(0)}',
              style: GoogleFonts.spaceGrotesk(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              '$count笔',
              style: GoogleFonts.plusJakartaSans(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 9,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
// Tab 2: Spend Trajectory (Timeline)
// ─────────────────────────────────────────────────────────

class _SpendTrajectoryTab extends StatelessWidget {
  const _SpendTrajectoryTab({required this.book});

  final LedgerBook book;

  @override
  Widget build(BuildContext context) {
    final geoEntries = book.entries
        .where((e) =>
            e.latitude != null &&
            e.longitude != null &&
            e.type == EntryType.expense)
        .toList()
      ..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));

    if (geoEntries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.timeline_rounded,
                  size: 64, color: const Color(0xFFB0BEC5)),
              const SizedBox(height: 16),
              Text(
                '暂无轨迹数据',
                style: GoogleFonts.spaceGrotesk(
                    fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                '开启位置记账后，这里会按时间顺序展示你的消费轨迹。',
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                    color: const Color(0xFF60708A), height: 1.6),
              ),
            ],
          ),
        ),
      );
    }

    final lats = geoEntries.map((e) => e.latitude!).toList();
    final lons = geoEntries.map((e) => e.longitude!).toList();
    final centerLat = (lats.reduce(math.min) + lats.reduce(math.max)) / 2;
    final centerLon = (lons.reduce(math.min) + lons.reduce(math.max)) / 2;

    // Build polyline points
    final polyPoints =
        geoEntries.map((e) => LatLng(e.latitude!, e.longitude!)).toList();

    return FlutterMap(
      options: MapOptions(
        initialCenter: LatLng(centerLat, centerLon),
        initialZoom: 13,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.chaoxi.ledger',
        ),
        PolylineLayer(
          polylines: [
            Polyline(
              points: polyPoints,
              strokeWidth: 3,
              color: const Color(0xFF5C6BC0).withValues(alpha: 0.7),
              pattern: const StrokePattern.dotted(),
            ),
          ],
        ),
        MarkerLayer(
          markers: [
            for (var i = 0; i < geoEntries.length; i++)
              Marker(
                point: LatLng(
                    geoEntries[i].latitude!, geoEntries[i].longitude!),
                width: 36,
                height: 36,
                child: _TrajectoryNode(
                  entry: geoEntries[i],
                  index: i + 1,
                  isLast: i == geoEntries.length - 1,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _TrajectoryNode extends StatelessWidget {
  const _TrajectoryNode({
    required this.entry,
    required this.index,
    required this.isLast,
  });

  final LedgerEntry entry;
  final int index;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final cat = categoryForId(entry.categoryId);
    return GestureDetector(
      onTap: () => _showEntryDetail(context),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isLast ? const Color(0xFFE53935) : cat.color,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [
            BoxShadow(
              color: cat.color.withValues(alpha: 0.4),
              blurRadius: 6,
            ),
          ],
        ),
        child: Center(
          child: Text(
            '$index',
            style: GoogleFonts.spaceGrotesk(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }

  void _showEntryDetail(BuildContext context) {
    final cat = categoryForId(entry.categoryId);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(cat.icon, color: cat.color, size: 22),
            const SizedBox(width: 8),
            Expanded(child: Text(entry.title)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _safeCurrencyFormatter.format(entry.amount),
              style: GoogleFonts.spaceGrotesk(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: cat.color,
              ),
            ),
            const SizedBox(height: 8),
            if (entry.merchant.isNotEmpty)
              _detailRow(Icons.store, entry.merchant),
            if (entry.locationInfo.isNotEmpty)
              _detailRow(Icons.location_on, entry.locationInfo),
            _detailRow(Icons.access_time,
                DateFormat('yyyy-MM-dd HH:mm').format(entry.occurredAt)),
            _detailRow(Icons.category, cat.name),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: const Color(0xFF7A869C)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: GoogleFonts.plusJakartaSans(
                    color: const Color(0xFF3C4858))),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
// Region Analysis Helpers
// ─────────────────────────────────────────────────────────

class _RegionSpend {
  const _RegionSpend({required this.region, required this.amount, required this.count});
  final String region;
  final double amount;
  final int count;
}

List<_RegionSpend> regionSpendAnalysis(LedgerBook book) {
  final regionMap = <String, (double, int)>{};
  for (final entry in book.entries) {
    if (entry.type != EntryType.expense || entry.locationInfo.isEmpty) continue;
    // Extract the first segment (city or district) as region key
    final parts = entry.locationInfo.split(' ');
    final region = parts.length >= 2 ? '${parts[0]} ${parts[1]}' : parts[0];
    final current = regionMap[region] ?? (0.0, 0);
    regionMap[region] = (current.$1 + entry.amount, current.$2 + 1);
  }
  final result = regionMap.entries
      .map((e) => _RegionSpend(region: e.key, amount: e.value.$1, count: e.value.$2))
      .toList()
    ..sort((a, b) => b.amount.compareTo(a.amount));
  return result;
}

/// Calculates nearby spending summary for a given location text prefix.
String nearbySummaryForLocation(LedgerBook book, String locationInfo) {
  if (locationInfo.isEmpty) return '';
  final prefix = locationInfo.split(' ').first;
  if (prefix.isEmpty) return '';
  final now = DateTime.now();
  double total = 0;
  int count = 0;
  for (final entry in book.entries) {
    if (entry.type != EntryType.expense) continue;
    if (entry.occurredAt.year != now.year || entry.occurredAt.month != now.month) continue;
    if (entry.locationInfo.startsWith(prefix)) {
      total += entry.amount;
      count++;
    }
  }
  if (count == 0) return '';
  return '📍 你在 $prefix 本月已消费 ${_safeCurrencyFormatter.format(total)} ($count笔)';
}

// ─────────────────────────────────────────────────────────
// Favorite Locations Management Page
// ─────────────────────────────────────────────────────────

class FavoriteLocationsPage extends ConsumerWidget {
  const FavoriteLocationsPage({required this.book, super.key});

  final LedgerBook book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(ledgerControllerProvider.notifier);
    final state = ref.watch(ledgerControllerProvider);
    final locations = state.book?.favoriteLocations ?? book.favoriteLocations;

    return Scaffold(
      backgroundColor: const Color(0xFFF5FAFF),
      appBar: AppBar(
        title: Text('常用地点', style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.add_location_alt_rounded, color: Color(0xFF5C6BC0)),
            tooltip: '添加当前位置',
            onPressed: () => _addCurrentLocation(context, controller),
          ),
          IconButton(
            icon: const Icon(Icons.add, color: Color(0xFF5C6BC0)),
            tooltip: '手动添加',
            onPressed: () => _showEditDialog(context, controller, null),
          ),
        ],
      ),
      body: locations.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bookmark_border_rounded,
                        size: 64, color: const Color(0xFFB0BEC5)),
                    const SizedBox(height: 16),
                    Text(
                      '还没有收藏地点',
                      style: GoogleFonts.spaceGrotesk(
                          fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '点击右上角添加你常去的地方（家、公司、超市等），记账时可以快速选择。',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.plusJakartaSans(
                          color: const Color(0xFF60708A), height: 1.6),
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: locations.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final fav = locations[i];
                return _GlassCard(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF3E0),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.location_on_rounded,
                          color: Color(0xFFFF7043), size: 22),
                    ),
                    title: Text(fav.name,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(fav.address,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        if (fav.categoryId != null || fav.defaultTitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                if (fav.categoryId != null) ...[
                                  Icon(categoryForId(fav.categoryId!).icon,
                                      size: 14,
                                      color:
                                          categoryForId(fav.categoryId!).color),
                                  const SizedBox(width: 4),
                                  Text(categoryForId(fav.categoryId!).name,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: categoryForId(fav.categoryId!)
                                              .color)),
                                  const SizedBox(width: 8),
                                ],
                                if (fav.defaultTitle != null)
                                  Text('📝 ${fav.defaultTitle}',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF7A869C))),
                                if (fav.defaultAmount != null)
                                  Text(
                                      ' · ¥${fav.defaultAmount!.toStringAsFixed(0)}',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF7A869C))),
                              ],
                            ),
                          ),
                      ],
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'edit') {
                          _showEditDialog(context, controller, fav);
                        } else if (value == 'delete') {
                          controller.removeFavoriteLocation(fav.id);
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'edit', child: Text('编辑')),
                        PopupMenuItem(
                            value: 'delete',
                            child: Text('删除',
                                style: TextStyle(color: Color(0xFFC44536)))),
                      ],
                    ),
                    isThreeLine: fav.categoryId != null || fav.defaultTitle != null,
                  ),
                );
              },
            ),
    );
  }

  Future<void> _addCurrentLocation(
      BuildContext context, LedgerController controller) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在获取当前位置...')),
    );
    try {
      final result = await LocationHelper.getDetailedLocation();
      if (result.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('无法获取位置，请检查GPS和权限。')),
          );
        }
        return;
      }
      if (!context.mounted) return;
      final nameController = TextEditingController();
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('给这个地点起个名字'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(result.address,
                  style: GoogleFonts.plusJakartaSans(
                      color: const Color(0xFF60708A))),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '名称（如：家、公司）',
                  hintText: '输入地点名称',
                ),
                autofocus: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(nameController.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (name != null && name.isNotEmpty) {
        await controller.addFavoriteLocation(FavoriteLocation(
          id: _uuid.v4(),
          name: name,
          address: result.address,
          latitude: result.latitude,
          longitude: result.longitude,
        ));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('添加失败，请稍后重试。')),
        );
      }
    }
  }

  void _showEditDialog(
      BuildContext context, LedgerController controller, FavoriteLocation? existing) {
    final isNew = existing == null;
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final addressCtrl = TextEditingController(text: existing?.address ?? '');
    final latCtrl =
        TextEditingController(text: existing?.latitude.toString() ?? '');
    final lonCtrl =
        TextEditingController(text: existing?.longitude.toString() ?? '');
    final titleCtrl =
        TextEditingController(text: existing?.defaultTitle ?? '');
    final amountCtrl = TextEditingController(
        text: existing?.defaultAmount?.toStringAsFixed(2) ?? '');
    var catId = existing?.categoryId;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(isNew ? '添加常用地点' : '编辑地点'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: '名称 *'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: addressCtrl,
                  decoration: const InputDecoration(labelText: '地址 *'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                        child: TextField(
                      controller: latCtrl,
                      decoration: const InputDecoration(labelText: '纬度'),
                      keyboardType: TextInputType.number,
                    )),
                    const SizedBox(width: 8),
                    Expanded(
                        child: TextField(
                      controller: lonCtrl,
                      decoration: const InputDecoration(labelText: '经度'),
                      keyboardType: TextInputType.number,
                    )),
                  ],
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('位置模板（可选）',
                      style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF60708A))),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(labelText: '默认标题'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: amountCtrl,
                  decoration: const InputDecoration(labelText: '默认金额'),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String?>(
                  value: catId,
                  decoration:
                      const InputDecoration(labelText: '默认分类'),
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('不指定')),
                    for (final cat in appCategories
                        .where((c) => c.type == EntryType.expense))
                      DropdownMenuItem(
                        value: cat.id,
                        child: Row(
                          children: [
                            Icon(cat.icon, color: cat.color, size: 16),
                            const SizedBox(width: 8),
                            Text(cat.name),
                          ],
                        ),
                      ),
                  ],
                  onChanged: (val) => setState(() => catId = val),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                final address = addressCtrl.text.trim();
                final lat = double.tryParse(latCtrl.text.trim());
                final lon = double.tryParse(lonCtrl.text.trim());
                if (name.isEmpty || address.isEmpty) return;
                final loc = FavoriteLocation(
                  id: existing?.id ?? _uuid.v4(),
                  name: name,
                  address: address,
                  latitude: lat ?? existing?.latitude ?? 0,
                  longitude: lon ?? existing?.longitude ?? 0,
                  categoryId: catId,
                  defaultTitle: titleCtrl.text.trim().isEmpty
                      ? null
                      : titleCtrl.text.trim(),
                  defaultAmount:
                      double.tryParse(amountCtrl.text.trim()),
                );
                if (isNew) {
                  controller.addFavoriteLocation(loc);
                } else {
                  controller.updateFavoriteLocation(loc);
                }
                Navigator.of(ctx).pop();
              },
              child: Text(isNew ? '添加' : '保存'),
            ),
          ],
        ),
      ),
    );
  }
}
