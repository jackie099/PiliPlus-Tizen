import 'package:PiliPlus/http/dynamics.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/dynamic/dynamics_type.dart';
import 'package:PiliPlus/models/dynamics/result.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/tv/models/tv_video_data.dart';
import 'package:PiliPlus/tv/pages/tv_login.dart';
import 'package:PiliPlus/tv/utils/tv_open.dart';
import 'package:PiliPlus/tv/widgets/tv_feed_grid.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Feed controller for the TV dynamics tab: the 投稿 (video) slice of the
/// followed-UPs dynamics feed, reusing the existing [DynamicsHttp] API and
/// the [CommonListController] loading pattern. Kept TV-local because the
/// mobile [DynamicsTabController] pulls in the whole mobile shell
/// (MainController / DynamicsController).
class TvDynamicsController
    extends CommonListController<DynamicsDataModel, DynamicItemModel> {
  String? offset;

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  List<DynamicItemModel>? getDataList(DynamicsDataModel response) {
    offset = response.offset;
    return response.items;
  }

  @override
  Future<void> onRefresh() {
    offset = null;
    return super.onRefresh();
  }

  @override
  Future<LoadingState<DynamicsDataModel>> customGetData() =>
      DynamicsHttp.followDynamic(
        offset: offset,
        type: DynamicsTabType.video,
      );
}

/// TV dynamics feed (动态): video uploads from followed UPs.
///
/// The feed requires a logged-in account; without one a focusable
/// placeholder routes to the TV QR login ([TvLoginPage]). `isLogin` is
/// reactive, so the feed appears as soon as the login completes.
class TvDynamics extends StatefulWidget {
  const TvDynamics({super.key});

  @override
  State<TvDynamics> createState() => _TvDynamicsState();
}

class _TvDynamicsState extends State<TvDynamics> {
  static const _controllerTag = 'tv-dynamics';
  final AccountService _accountService = Get.find<AccountService>();
  TvDynamicsController? _controller;

  @override
  void dispose() {
    if (_controller != null) {
      Get.delete<TvDynamicsController>(tag: _controllerTag);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!_accountService.isLogin.value) {
        // Drop any feed loaded for a previous account so a later login
        // starts fresh.
        if (_controller != null) {
          _controller = null;
          Get.delete<TvDynamicsController>(tag: _controllerTag);
        }
        return TvStatusView(
          message: '动态来自你关注的UP主\n扫码登录后即可查看',
          actionLabel: '扫码登录',
          onRetry: () => Get.to(() => const TvLoginPage()),
        );
      }
      final controller = _controller ??= Get.put(
        TvDynamicsController(),
        tag: _controllerTag,
      );
      return TvFeedGrid<DynamicItemModel>(
        controller: controller!,
        toData: TvVideoData.fromDynamic,
        onOpen: TvOpen.openDynamic,
        emptyMessage: '暂无动态内容',
      );
    });
  }
}
