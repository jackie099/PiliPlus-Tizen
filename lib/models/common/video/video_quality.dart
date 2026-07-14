enum VideoQuality {
  hdrVivid(129, 'HDR Vivid', 'HDR Vivid'),
  super8k(127, '8K 超高清', '8K'),
  dolbyVision(126, '杜比视界', '杜比'),
  hdr(125, 'HDR 真彩', 'HDR'),
  super4K(120, '4K 超高清', '4K'),
  high108060(116, '1080P 60帧', '1080P60'),
  high1080plus(112, '1080P 高码率', '1080P+'),
  high1080(80, '1080P 高清', '1080P'),
  high72060(74, '720P 60帧', '720P60'),
  high720(64, '720P 准高清', '720P'),
  clear480(32, '480P 标清', '480P'),
  fluent360(16, '360P 流畅', '360P'),
  speed240(6, '240P 极速', '240P'),
  ;

  final int code;
  final String desc;
  final String shortDesc;

  const VideoQuality(this.code, this.desc, this.shortDesc);

  static final _codeMap = {for (final i in values) i.code: i};

  static VideoQuality fromCode(int code) => _codeMap[code]!;

  /// Quality codes the Samsung S90F (and Samsung panels generally) cannot play:
  /// Dolby Vision (126 — Samsung never licenses DV), 8K (127 — pointless and too
  /// heavy to decode on a 4K panel), and HDR-Vivid/CUVA (129 — unsupported).
  /// HDR10 (125, "HDR真彩") IS supported. Used to filter the TV quality menu
  /// (tv_player_options.dart) so an unplayable stream is never offered there;
  /// auto quality selection relies on a separate quality clamp.
  static bool isTizenSupported(int code) =>
      code != dolbyVision.code &&
      // 8K (127): CONFIRMED unplayable — the S90F's AVPlay decoder rejects the
      // 7680×4320 stream with "Media Player error: Not supported format" (tested
      // on 影视飓风's 8K demo). Excluded from the TV quality menu.
      code != super8k.code &&
      code != hdrVivid.code;
}
