import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/widgets/cdn_speed_test.dart';
import 'package:PiliPlus/tv/widgets/tv_option_row.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// TV CDN-mirror picker.
///
/// The Bilibili video CDN routes each request to a mirror (`baseUrl`), whose
/// throughput varies a lot by mirror and by congestion — a slow one starves 4K
/// (which needs ~15 Mbps) while 1080P still plays. This page reuses the app's
/// existing mirror machinery ([VideoUtils.getCdnUrl] host-rewriting +
/// [CDNService]) so a faster mirror can be chosen from the couch when high
/// resolutions stutter.
///
/// It speed-tests every [CDNService] via [CdnSpeedTest], streaming results in as
/// they finish. Picking a row persists it exactly like the mobile 设置 → CDN
/// dialog: `VideoUtils.cdnService = x` + `SettingBoxKey.CDNService`, taking
/// effect for the next play session.
class TvCdnPage extends StatefulWidget {
  const TvCdnPage({super.key});

  @override
  State<TvCdnPage> createState() => _TvCdnPageState();
}

class _TvCdnPageState extends State<TvCdnPage> {
  static const double _rowGap = 10 * TvTheme.designScale;

  final CdnSpeedTest _tester = CdnSpeedTest();

  /// The row the user has committed to (checkmark). Starts at the active pref.
  CDNService _selected = VideoUtils.cdnService;

  @override
  void initState() {
    super.initState();
    _tester.start();
  }

  @override
  void dispose() {
    _tester.dispose();
    super.dispose();
  }

  void _select(CDNService cdn) {
    VideoUtils.cdnService = cdn;
    GStorage.setting.put(SettingBoxKey.CDNService, cdn.name);
    setState(() => _selected = cdn);
    Get.back();
  }

  @override
  Widget build(BuildContext context) {
    final values = CDNService.values;
    final int selectedIndex = values.indexOf(_selected);
    return Theme(
      data: ThemeUtils.darkTheme,
      child: Scaffold(
        backgroundColor: TvTheme.background,
        body: DecoratedBox(
          decoration: const BoxDecoration(gradient: TvTheme.backgroundGradient),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 920 * TvTheme.designScale,
              ),
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(
                  TvTheme.screenPadding,
                  TvTheme.gridTopPadding,
                  TvTheme.screenPadding,
                  TvTheme.gridBottomPadding,
                ),
                itemCount: values.length + 2,
                separatorBuilder: (_, index) =>
                    SizedBox(height: index == 0 ? 0 : _rowGap),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(
                        bottom: 8 * TvTheme.designScale,
                      ),
                      child: Text('CDN 线路测速', style: TvTheme.cardTitle),
                    );
                  }
                  if (index == values.length + 1) {
                    return Padding(
                      padding: const EdgeInsets.only(
                        top: 16 * TvTheme.designScale,
                      ),
                      child: Text(
                        '选中后对新开始的播放生效。线路速度随网络波动，'
                        '4K 卡顿时可回到此页重新测速并切换更快的线路。',
                        style: TvTheme.cardMeta,
                      ),
                    );
                  }
                  final int i = index - 1;
                  final CDNService cdn = values[i];
                  return ValueListenableBuilder<String?>(
                    valueListenable: _tester.results[i],
                    builder: (context, result, _) => TvOptionRow(
                      autofocus: i == (selectedIndex < 0 ? 0 : selectedIndex),
                      dense: true,
                      label: cdn.desc,
                      value: result ?? '—',
                      checked: cdn == _selected,
                      onSelect: () => _select(cdn),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
