import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/models/common/search/search_type.dart';
import 'package:PiliPlus/models/search/result.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/tv/focus/tv_focusable.dart';
import 'package:PiliPlus/tv/models/tv_video_data.dart';
import 'package:PiliPlus/tv/tv_theme.dart';
import 'package:PiliPlus/tv/utils/tv_open.dart';
import 'package:PiliPlus/tv/widgets/tv_feed_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:get/get.dart';

/// Video search over the existing [SearchHttp.searchByType] API, driven by
/// the on-screen keyboard and/or the system IME (no submit on init; [submit]
/// starts a new query).
///
/// Mirrors the mobile SearchPanelController's video slice, including the
/// gaia risk-control token retry.
class TvSearchController
    extends CommonListController<SearchVideoData, SearchVideoItemModel> {
  /// Text being composed on the keyboard.
  final RxString query = ''.obs;

  /// Whether a search has been submitted (shows the results pane).
  final RxBool hasSearched = false.obs;

  String _keyword = '';
  String? _gaiaVtoken;

  @override
  List<SearchVideoItemModel>? getDataList(SearchVideoData response) =>
      response.list;

  @override
  Future<LoadingState<SearchVideoData>> customGetData() =>
      SearchHttp.searchByType<SearchVideoData>(
        searchType: SearchType.video,
        keyword: _keyword,
        page: page,
        gaiaVtoken: _gaiaVtoken,
        onSuccess: (String gaiaVtoken) {
          _gaiaVtoken = gaiaVtoken;
          queryData(page == 1);
        },
      );

  void append(String char) => query.value += char;

  void backspace() {
    final value = query.value;
    if (value.isNotEmpty) {
      query.value = value.substring(0, value.length - 1);
    }
  }

  void clear() => query.value = '';

  Future<void> submit() {
    final keyword = query.value.trim();
    if (keyword.isEmpty) return Future.value();
    if (keyword != _keyword) _gaiaVtoken = null;
    _keyword = keyword;
    hasSearched.value = true;
    page = 1;
    isEnd = false;
    loadingState.value = LoadingState<List<SearchVideoItemModel>?>.loading();
    if (scrollController.hasClients) {
      scrollController.jumpTo(0);
    }
    return queryData();
  }
}

/// TV search screen: a D-pad-navigable on-screen keyboard on the left and a
/// results grid on the right.
///
/// Two input paths edit the same [TvSearchController.query]:
/// * the custom on-screen keyboard (latin/digits/space) for quick D-pad
///   typing without leaving the app's focus model;
/// * the Tizen system IME (pinyin/CJK/voice) — the「系统键盘」key focuses the
///   query box, which is a real [TextField], so the embedder's text-input
///   channel raises the native keyboard.
class TvSearch extends StatefulWidget {
  const TvSearch({super.key});

  @override
  State<TvSearch> createState() => _TvSearchState();
}

class _TvSearchState extends State<TvSearch> {
  static const _controllerTag = 'tv-search';
  final TvSearchController _controller = Get.put(
    TvSearchController(),
    tag: _controllerTag,
  );

  static const double _panelWidth = 460 * TvTheme.designScale;

  /// Gap between the on-screen keyboard's keys and rows.
  static const double _keyGap = 10 * TvTheme.designScale;

  static const BorderRadius _fieldRadius = BorderRadius.all(
    Radius.circular(14 * TvTheme.designScale),
  );

  static const List<String> _keyRows = [
    '1234567890',
    'abcdefghij',
    'klmnopqrst',
    'uvwxyz',
  ];

  /// Backs the query box's [TextField]; kept in two-way sync with
  /// [TvSearchController.query] so the system IME and the custom on-screen
  /// keyboard edit one shared value.
  final TextEditingController _imeController = TextEditingController();

  /// Focus of the query box's [TextField]. [FocusNode.skipTraversal] keeps
  /// D-pad arrows from ever landing on it; it is only entered explicitly by
  /// the「系统键盘」key, whose requestFocus opens a platform text-input
  /// connection — flutter-tizen's embedder then raises the system IME.
  final FocusNode _imeFocusNode = FocusNode(
    debugLabel: 'TvSearch.ime',
    skipTraversal: true,
  );

  /// The「系统键盘」key's node: where D-pad focus returns when an IME editing
  /// session ends (submit / Back / Up / Down).
  final FocusNode _imeKeyNode = FocusNode(debugLabel: 'TvSearch.imeKey');

  /// GetX worker mirroring [TvSearchController.query] into [_imeController].
  late final Worker _queryWorker;

  /// Mirrors [_imeFocusNode]'s state for the query box's focus ring.
  bool _imeFocused = false;

  @override
  void initState() {
    super.initState();
    _imeController
      ..text = _controller.query.value
      ..addListener(_pushTextFieldIntoQuery);
    _imeFocusNode.addListener(_onImeFocusChange);
    _queryWorker = ever(_controller.query, _pushQueryIntoTextField);
  }

  @override
  void dispose() {
    _queryWorker.dispose();
    _imeController.dispose();
    _imeFocusNode.dispose();
    _imeKeyNode.dispose();
    Get.delete<TvSearchController>(tag: _controllerTag);
    super.dispose();
  }

  // ------------------------------------------------------------ system IME --

  /// [TextField] edits (system IME) → [TvSearchController.query]. The
  /// equality guard — plus Rx skipping same-value assignments — breaks the
  /// loop with [_pushQueryIntoTextField]. An IME that deletes everything
  /// simply syncs an empty string, which the field renders as its hint.
  void _pushTextFieldIntoQuery() {
    final text = _imeController.text;
    if (_controller.query.value != text) {
      _controller.query.value = text;
    }
  }

  /// Custom on-screen keyboard edits → the [TextField], caret kept at the
  /// end. Setting [TextEditingController.value] whole also clears any stale
  /// composing region.
  void _pushQueryIntoTextField(String query) {
    if (_imeController.text == query) return;
    _imeController.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
  }

  void _onImeFocusChange() {
    final focused = _imeFocusNode.hasFocus;
    if (focused != _imeFocused) {
      setState(() => _imeFocused = focused);
    }
  }

  /// OK on「系统键盘」: focus the query box so the platform raises the native
  /// keyboard, with the caret at the end of whatever was already typed.
  void _openSystemKeyboard() {
    _imeController.selection = TextSelection.collapsed(
      offset: _imeController.text.length,
    );
    _imeFocusNode.requestFocus();
  }

  /// Ends an IME editing session: moving focus off the [TextField] closes
  /// the text-input connection (hiding the system keyboard) and hands D-pad
  /// focus back to the「系统键盘」key.
  void _closeSystemKeyboard() {
    _imeKeyNode.requestFocus();
  }

  void _onImeSubmitted(String _) {
    _closeSystemKeyboard();
    _controller.submit();
  }

  /// Remote keys that bubble past the focused [TextField]. Back ends the IME
  /// session instead of popping out of search; Up/Down also exit (vertical
  /// caret movement is meaningless in a single-line field) so the D-pad can
  /// never get stuck once the IME panel itself has been dismissed.
  /// Left/Right fall through and move the caret.
  KeyEventResult _onImeKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !_imeFocusNode.hasFocus) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      _closeSystemKeyboard();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: TvTheme.screenPadding,
            top: TvTheme.gridTopPadding,
          ),
          child: SizedBox(width: _panelWidth, child: _buildKeyboardPanel()),
        ),
        const SizedBox(width: 40 * TvTheme.designScale),
        Expanded(child: _buildResults()),
      ],
    );
  }

  // ------------------------------------------------------------- keyboard --

  Widget _buildKeyboardPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildQueryField(),
        const SizedBox(height: 20 * TvTheme.designScale),
        for (var row = 0; row < _keyRows.length; row++) ...[
          if (row > 0) const SizedBox(height: _keyGap),
          _buildKeyRow(row),
        ],
        const SizedBox(height: _keyGap),
        Row(
          children: [
            _TvKey(
              label: '系统键盘',
              flex: 4,
              focusNode: _imeKeyNode,
              onSelect: _openSystemKeyboard,
            ),
            const SizedBox(width: _keyGap),
            _TvKey(
              label: '清空',
              flex: 3,
              onSelect: _controller.clear,
            ),
            const SizedBox(width: _keyGap),
            _TvKey(
              label: '搜索',
              flex: 3,
              accent: true,
              onSelect: _controller.submit,
            ),
          ],
        ),
      ],
    );
  }

  /// The query box is a real (single-line, visually plain) [TextField] so
  /// the system IME can edit the query directly. It must keep a real size in
  /// the tree — a truly offstage field cannot hold a text-input connection —
  /// but D-pad traversal skips it, so until「系统键盘」focuses it, it looks
  /// and behaves exactly like the old read-only display.
  Widget _buildQueryField() {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onImeKeyEvent,
      child: AnimatedContainer(
        duration: TvTheme.focusDuration,
        curve: TvTheme.focusOutCurve,
        decoration: const BoxDecoration(
          color: TvTheme.surface,
          borderRadius: _fieldRadius,
        ),
        foregroundDecoration: tvFocusRing(
          focused: _imeFocused,
          borderRadius: _fieldRadius,
          dimWhenUnfocused: false,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 20 * TvTheme.designScale,
            vertical: 16 * TvTheme.designScale,
          ),
          child: TextField(
            controller: _imeController,
            focusNode: _imeFocusNode,
            showCursor: true,
            enableInteractiveSelection: false,
            style: TvTheme.buttonLabel,
            cursorColor: TvTheme.brandPink,
            textInputAction: TextInputAction.search,
            onSubmitted: _onImeSubmitted,
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              hintText: '输入关键词',
              hintStyle: TvTheme.buttonLabel.copyWith(
                color: TvTheme.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKeyRow(int row) {
    final chars = _keyRows[row];
    final isLastCharRow = row == _keyRows.length - 1;
    return Row(
      children: [
        for (var i = 0; i < chars.length; i++) ...[
          if (i > 0) const SizedBox(width: _keyGap),
          _TvKey(
            label: chars[i],
            autofocus: row == 0 && i == 0,
            onSelect: () => _controller.append(chars[i]),
          ),
        ],
        // Fill the short last letter row with space/backspace keys so every
        // row spans the same width (keeps D-pad geometry predictable).
        if (isLastCharRow) ...[
          const SizedBox(width: _keyGap),
          _TvKey(
            label: '空格',
            flex: 2,
            onSelect: () => _controller.append(' '),
          ),
          const SizedBox(width: _keyGap),
          _TvKey(
            label: '删除',
            flex: 2,
            onSelect: _controller.backspace,
          ),
        ],
      ],
    );
  }

  // -------------------------------------------------------------- results --

  Widget _buildResults() {
    return Obx(() {
      if (!_controller.hasSearched.value) {
        return const TvStatusView(
          message: '使用左侧键盘输入关键词，选择「搜索」查看结果\n「系统键盘」可调出系统输入法（支持中文）',
        );
      }
      return TvFeedGrid<SearchVideoItemModel>(
        controller: _controller,
        toData: TvVideoData.fromHorizontal,
        onOpen: TvOpen.openHorizontalVideo,
        emptyMessage: '没有找到相关视频',
        autofocusFirst: false,
        columns: 3,
        padding: const EdgeInsets.fromLTRB(
          8 * TvTheme.designScale,
          TvTheme.gridTopPadding,
          TvTheme.screenPadding,
          TvTheme.gridBottomPadding,
        ),
      );
    });
  }
}

/// A single focusable key of the on-screen keyboard.
class _TvKey extends StatelessWidget {
  const _TvKey({
    required this.label,
    required this.onSelect,
    this.flex = 1,
    this.accent = false,
    this.autofocus = false,
    this.focusNode,
  });

  final String label;
  final VoidCallback onSelect;
  final int flex;

  /// Highlights the primary action key (搜索).
  final bool accent;

  final bool autofocus;

  /// Optional external node (owned by the caller) so the parent can return
  /// D-pad focus to this key programmatically (系统键盘).
  final FocusNode? focusNode;

  static const BorderRadius _radius = BorderRadius.all(
    Radius.circular(12 * TvTheme.designScale),
  );

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: TvFocusable(
        onSelect: onSelect,
        focusNode: focusNode,
        autofocus: autofocus,
        borderRadius: _radius,
        focusScale: TvTheme.focusScaleSmall,
        dimWhenUnfocused: false,
        ensureVisible: false,
        child: Container(
          height: 56 * TvTheme.designScale,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: accent ? const Color(0x59FB7299) : TvTheme.surface,
            borderRadius: _radius,
          ),
          child: Text(label, style: TvTheme.buttonLabel),
        ),
      ),
    );
  }
}
