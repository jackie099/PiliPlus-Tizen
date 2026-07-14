import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/pages/hot/controller.dart';
import 'package:PiliPlus/tv/models/tv_video_data.dart';
import 'package:PiliPlus/tv/utils/tv_open.dart';
import 'package:PiliPlus/tv/widgets/tv_feed_grid.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// TV hot feed (热门): the existing [HotController] data layer rendered
/// through the shared [TvFeedGrid].
class TvHot extends StatefulWidget {
  const TvHot({super.key});

  @override
  State<TvHot> createState() => _TvHotState();
}

class _TvHotState extends State<TvHot> {
  static const _controllerTag = 'tv-hot';
  final HotController _controller = Get.put(
    HotController(),
    tag: _controllerTag,
  );

  @override
  void dispose() {
    Get.delete<HotController>(tag: _controllerTag);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TvFeedGrid<HotVideoItemModel>(
      controller: _controller,
      toData: TvVideoData.fromHorizontal,
      onOpen: TvOpen.openHorizontalVideo,
      emptyMessage: '暂无热门内容',
    );
  }
}
