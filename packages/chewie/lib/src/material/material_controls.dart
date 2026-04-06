import 'dart:async';

import 'package:chewie/src/center_play_button.dart';
import 'package:chewie/src/center_seek_button.dart';
import 'package:chewie/src/chewie_player.dart';
import 'package:chewie/src/chewie_progress_colors.dart';
import 'package:chewie/src/helpers/utils.dart';
import 'package:chewie/src/material/material_progress_bar.dart';
import 'package:chewie/src/material/widgets/options_dialog.dart';
import 'package:chewie/src/material/widgets/playback_speed_dialog.dart';
import 'package:chewie/src/models/option_item.dart';
import 'package:chewie/src/models/subtitle_model.dart';
import 'package:chewie/src/notifiers/index.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

class MaterialControls extends StatefulWidget {
  const MaterialControls({
    this.showPlayButton = true,
    /// 为 true 时不绘制底栏（时间/音量/进度/全屏），用于与 [bottomBarOnly] 搭配分屏。
    this.hideBottomBar = false,
    /// 为 true 时仅绘制底栏，无全屏点击层；叠在 [InteractiveViewer] 之上时勿用全屏 [Positioned.fill]。
    this.bottomBarOnly = false,
    /// 为 true 时用右下角播放/暂停替代全屏按钮（媒体页等场景）。
    this.replaceFullscreenWithPlayPause = false,
    /// 为 true 时不绘制右上角字幕/更多菜单条，避免与页面自定义顶栏重叠（媒体预览页）。
    this.hideTopActionBar = false,
    super.key,
  });

  final bool showPlayButton;
  final bool hideBottomBar;
  final bool bottomBarOnly;
  final bool replaceFullscreenWithPlayPause;
  final bool hideTopActionBar;

  @override
  State<StatefulWidget> createState() {
    return _MaterialControlsState();
  }
}

class _MaterialControlsState extends State<MaterialControls>
    with SingleTickerProviderStateMixin {
  late PlayerNotifier notifier;
  late VideoPlayerValue _latestValue;
  double? _latestVolume;
  Timer? _hideTimer;
  Timer? _initTimer;
  late var _subtitlesPosition = Duration.zero;
  bool _subtitleOn = false;
  Timer? _showAfterExpandCollapseTimer;
  bool _dragging = false;
  bool _displayTapped = false;
  Timer? _bufferingDisplayTimer;
  bool _displayBufferingIndicator = false;

  final barHeight = 48.0 * 1.5;
  final marginSize = 5.0;

  /// 底部栏第一行（时间/音量/全屏）高度。非全屏时若仍用 [barHeight]（72）会与固定总高内的进度条抢空间，导致进度条被挤成 0 高。
  double get _bottomBarControlRowHeight =>
      chewieController.isFullScreen ? barHeight : 48.0;

  late VideoPlayerController controller;
  ChewieController? _chewieController;

  // We know that _chewieController is set in didChangeDependencies
  ChewieController get chewieController => _chewieController!;

  @override
  void initState() {
    super.initState();
    notifier = Provider.of<PlayerNotifier>(context, listen: false);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bottomBarOnly) {
      if (_latestValue.hasError) {
        return const SizedBox.shrink();
      }
      return _buildBottomBar(context);
    }

    if (_latestValue.hasError) {
      return chewieController.errorBuilder?.call(
            context,
            chewieController.videoPlayerController.value.errorDescription!,
          ) ??
          const Center(child: Icon(Icons.error, color: Colors.white, size: 42));
    }

    return MouseRegion(
      onHover: (_) {
        _cancelAndRestartTimer();
      },
      child: GestureDetector(
        onTap: () => _cancelAndRestartTimer(),
        child: AbsorbPointer(
          absorbing: notifier.hideStuff,
          child: Stack(
            children: [
              if (_displayBufferingIndicator)
                _chewieController?.bufferingBuilder?.call(context) ??
                    const Center(child: CircularProgressIndicator())
              else
                _buildHitArea(),
              if (!widget.hideTopActionBar) _buildActionBar(),
              Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  if (_subtitleOn)
                    Transform.translate(
                      offset: Offset(
                        0.0,
                        notifier.hideStuff ? barHeight * 0.8 : 0.0,
                      ),
                      child: _buildSubtitles(
                        context,
                        chewieController.subtitle!,
                      ),
                    ),
                  if (!widget.hideBottomBar) _buildBottomBar(context),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _dispose();
    super.dispose();
  }

  void _dispose() {
    controller.removeListener(_updateState);
    _hideTimer?.cancel();
    _initTimer?.cancel();
    _showAfterExpandCollapseTimer?.cancel();
  }

  @override
  void didChangeDependencies() {
    final oldController = _chewieController;
    _chewieController = ChewieController.of(context);
    controller = chewieController.videoPlayerController;

    if (oldController != chewieController) {
      _dispose();
      _initialize();
    }

    super.didChangeDependencies();
  }

  Widget _buildActionBar() {
    return Positioned(
      top: 0,
      right: 0,
      child: SafeArea(
        child: AnimatedOpacity(
          opacity: notifier.hideStuff ? 0.0 : 1.0,
          duration: const Duration(milliseconds: 250),
          child: Row(
            children: [
              _buildSubtitleToggle(),
              if (chewieController.showOptions) _buildOptionsButton(),
            ],
          ),
        ),
      ),
    );
  }

  List<OptionItem> _buildOptions(BuildContext context) {
    final options = <OptionItem>[
      OptionItem(
        onTap: (context) async {
          Navigator.pop(context);
          _onSpeedButtonTap();
        },
        iconData: Icons.speed,
        title:
            chewieController.optionsTranslation?.playbackSpeedButtonText ??
            'Playback speed',
      ),
    ];

    if (chewieController.additionalOptions != null &&
        chewieController.additionalOptions!(context).isNotEmpty) {
      options.addAll(chewieController.additionalOptions!(context));
    }
    return options;
  }

  Widget _buildOptionsButton() {
    return AnimatedOpacity(
      opacity: notifier.hideStuff ? 0.0 : 1.0,
      duration: const Duration(milliseconds: 250),
      child: IconButton(
        onPressed: () async {
          _hideTimer?.cancel();

          if (chewieController.optionsBuilder != null) {
            await chewieController.optionsBuilder!(
              context,
              _buildOptions(context),
            );
          } else {
            await showModalBottomSheet<OptionItem>(
              context: context,
              isScrollControlled: true,
              useRootNavigator: chewieController.useRootNavigator,
              builder: (context) => OptionsDialog(
                options: _buildOptions(context),
                cancelButtonText:
                    chewieController.optionsTranslation?.cancelButtonText,
              ),
            );
          }

          if (_latestValue.isPlaying) {
            _startHideTimer();
          }
        },
        icon: const Icon(Icons.more_vert, color: Colors.white),
      ),
    );
  }

  Widget _buildSubtitles(BuildContext context, Subtitles subtitles) {
    if (!_subtitleOn) {
      return const SizedBox();
    }
    final currentSubtitle = subtitles.getByPosition(_subtitlesPosition);
    if (currentSubtitle.isEmpty) {
      return const SizedBox();
    }

    if (chewieController.subtitleBuilder != null) {
      return chewieController.subtitleBuilder!(
        context,
        currentSubtitle.first!.text,
      );
    }

    return Padding(
      padding: EdgeInsets.all(marginSize),
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: const Color(0x96000000),
          borderRadius: BorderRadius.circular(10.0),
        ),
        child: Text(
          currentSubtitle.first!.text.toString(),
          style: const TextStyle(fontSize: 18),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  AnimatedOpacity _buildBottomBar(BuildContext context) {
    final iconColor = Theme.of(context).textTheme.labelLarge!.color;
    final double controlRowH = _bottomBarControlRowHeight;

    return AnimatedOpacity(
      opacity: notifier.hideStuff ? 0.0 : 1.0,
      duration: const Duration(milliseconds: 300),
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          bottom: !chewieController.isFullScreen ? 10.0 : 0,
        ),
        child: SafeArea(
          top: false,
          // 嵌入（非全屏）时必须避开系统导航栏，否则底栏会画在导航条下方，只能看到进度条手柄边缘。
          bottom: true,
          minimum: chewieController.controlsSafeAreaMinimum,
          child: SizedBox(
            height: controlRowH,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                if (chewieController.isLive)
                  const Expanded(child: Text('LIVE'))
                else
                  _buildPosition(iconColor),
                if (chewieController.allowMuting) _buildMuteButton(controller),
                if (!chewieController.isLive)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: _buildProgressBar(),
                    ),
                  )
                else
                  const Spacer(),
                if (widget.replaceFullscreenWithPlayPause)
                  _buildPlayPauseBarButton()
                else if (chewieController.allowFullScreen)
                  _buildExpandButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 底栏右侧：播放/暂停（与 [_buildExpandButton] 同尺寸区域，便于替换全屏键）。
  GestureDetector _buildPlayPauseBarButton() {
    return GestureDetector(
      onTap: () {
        _cancelAndRestartTimer();
        _playPause();
      },
      child: AnimatedOpacity(
        opacity: notifier.hideStuff ? 0.0 : 1.0,
        duration: const Duration(milliseconds: 300),
        child: SizedBox(
          height: _bottomBarControlRowHeight,
          child: Container(
            margin: const EdgeInsets.only(right: 12.0),
            padding: const EdgeInsets.only(left: 8.0, right: 8.0),
            alignment: Alignment.center,
            child: Icon(
              _latestValue.isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  GestureDetector _buildMuteButton(VideoPlayerController controller) {
    return GestureDetector(
      onTap: () {
        _cancelAndRestartTimer();

        if (_latestValue.volume == 0) {
          controller.setVolume(_latestVolume ?? 0.5);
        } else {
          _latestVolume = controller.value.volume;
          controller.setVolume(0.0);
        }
      },
      child: AnimatedOpacity(
        opacity: notifier.hideStuff ? 0.0 : 1.0,
        duration: const Duration(milliseconds: 300),
        child: ClipRect(
          child: Container(
            height: _bottomBarControlRowHeight,
            padding: const EdgeInsets.only(left: 6.0),
            child: Icon(
              _latestValue.volume > 0 ? Icons.volume_up : Icons.volume_off,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  GestureDetector _buildExpandButton() {
    return GestureDetector(
      onTap: _onExpandCollapse,
      child: AnimatedOpacity(
        opacity: notifier.hideStuff ? 0.0 : 1.0,
        duration: const Duration(milliseconds: 300),
        child: SizedBox(
          height: _bottomBarControlRowHeight,
          child: Container(
            margin: const EdgeInsets.only(right: 12.0),
            padding: const EdgeInsets.only(left: 8.0, right: 8.0),
            alignment: Alignment.center,
            child: Icon(
              chewieController.isFullScreen
                  ? Icons.fullscreen_exit
                  : Icons.fullscreen,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHitArea() {
    final bool isFinished =
        (_latestValue.position >= _latestValue.duration) &&
        _latestValue.duration.inSeconds > 0;
    final bool showPlayButton =
        widget.showPlayButton && !_dragging && !notifier.hideStuff;

    return GestureDetector(
      onTap: () {
        if (_latestValue.isPlaying) {
          if (_chewieController?.pauseOnBackgroundTap ?? false) {
            _playPause();
            _cancelAndRestartTimer();
          } else {
            if (_displayTapped) {
              setState(() {
                notifier.hideStuff = true;
              });
            } else {
              _cancelAndRestartTimer();
            }
          }
        } else {
          _playPause();

          setState(() {
            notifier.hideStuff = true;
          });
        }
      },
      child: Container(
        alignment: Alignment.center,
        color: Colors
            .transparent, // The Gesture Detector doesn't expand to the full size of the container without this; Not sure why!
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!isFinished && !chewieController.isLive)
              CenterSeekButton(
                iconData: Icons.replay_10,
                backgroundColor: Colors.black54,
                iconColor: Colors.white,
                show: showPlayButton,
                fadeDuration: chewieController.materialSeekButtonFadeDuration,
                iconSize: chewieController.materialSeekButtonSize,
                onPressed: _seekBackward,
              ),
            Container(
              margin: EdgeInsets.symmetric(horizontal: marginSize),
              child: CenterPlayButton(
                backgroundColor: Colors.black54,
                iconColor: Colors.white,
                isFinished: isFinished,
                isPlaying: controller.value.isPlaying,
                show: showPlayButton,
                onPressed: _playPause,
              ),
            ),
            if (!isFinished && !chewieController.isLive)
              CenterSeekButton(
                iconData: Icons.forward_10,
                backgroundColor: Colors.black54,
                iconColor: Colors.white,
                show: showPlayButton,
                fadeDuration: chewieController.materialSeekButtonFadeDuration,
                iconSize: chewieController.materialSeekButtonSize,
                onPressed: _seekForward,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _onSpeedButtonTap() async {
    _hideTimer?.cancel();

    final chosenSpeed = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: chewieController.useRootNavigator,
      builder: (context) => PlaybackSpeedDialog(
        speeds: chewieController.playbackSpeeds,
        selected: _latestValue.playbackSpeed,
      ),
    );

    if (chosenSpeed != null) {
      controller.setPlaybackSpeed(chosenSpeed);
    }

    if (_latestValue.isPlaying) {
      _startHideTimer();
    }
  }

  Widget _buildPosition(Color? iconColor) {
    final position = _latestValue.position;
    final duration = _latestValue.duration;

    return RichText(
      text: TextSpan(
        text: '${formatDuration(position)} ',
        children: <InlineSpan>[
          TextSpan(
            text: '/ ${formatDuration(duration)}',
            style: TextStyle(
              fontSize: 14.0,
              color: Colors.white.withValues(alpha: .75),
              fontWeight: FontWeight.normal,
            ),
          ),
        ],
        style: const TextStyle(
          fontSize: 14.0,
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildSubtitleToggle() {
    //if don't have subtitle hiden button
    if (chewieController.subtitle?.isEmpty ?? true) {
      return const SizedBox();
    }
    return GestureDetector(
      onTap: _onSubtitleTap,
      child: Container(
        height: barHeight,
        color: Colors.transparent,
        padding: const EdgeInsets.only(left: 12.0, right: 12.0),
        child: Icon(
          _subtitleOn
              ? Icons.closed_caption
              : Icons.closed_caption_off_outlined,
          color: _subtitleOn ? Colors.white : Colors.grey[700],
        ),
      ),
    );
  }

  void _onSubtitleTap() {
    setState(() {
      _subtitleOn = !_subtitleOn;
    });
  }

  void _cancelAndRestartTimer() {
    _hideTimer?.cancel();
    _startHideTimer();

    setState(() {
      notifier.hideStuff = false;
      _displayTapped = true;
    });
  }

  Future<void> _initialize() async {
    _subtitleOn =
        chewieController.showSubtitles &&
        (chewieController.subtitle?.isNotEmpty ?? false);
    controller.addListener(_updateState);

    _updateState();

    if (controller.value.isPlaying || chewieController.autoPlay) {
      _startHideTimer();
    }

    if (chewieController.showControlsOnInitialize) {
      _initTimer = Timer(const Duration(milliseconds: 200), () {
        setState(() {
          notifier.hideStuff = false;
        });
      });
    }
  }

  void _onExpandCollapse() {
    setState(() {
      notifier.hideStuff = true;

      chewieController.toggleFullScreen();
      _showAfterExpandCollapseTimer = Timer(
        const Duration(milliseconds: 300),
        () {
          setState(() {
            _cancelAndRestartTimer();
          });
        },
      );
    });
  }

  void _playPause() {
    final bool isFinished =
        (_latestValue.position >= _latestValue.duration) &&
        _latestValue.duration.inSeconds > 0;

    setState(() {
      if (controller.value.isPlaying) {
        notifier.hideStuff = false;
        _hideTimer?.cancel();
        controller.pause();
      } else {
        _cancelAndRestartTimer();

        if (!controller.value.isInitialized) {
          controller.initialize().then((_) {
            controller.play();
          });
        } else {
          if (isFinished) {
            controller.seekTo(Duration.zero);
          }
          controller.play();
        }
      }
    });
  }

  void _seekRelative(Duration relativeSeek) {
    _cancelAndRestartTimer();
    final position = _latestValue.position + relativeSeek;
    final duration = _latestValue.duration;

    if (position < Duration.zero) {
      controller.seekTo(Duration.zero);
    } else if (position > duration) {
      controller.seekTo(duration);
    } else {
      controller.seekTo(position);
    }
  }

  void _seekBackward() {
    _seekRelative(const Duration(seconds: -10));
  }

  void _seekForward() {
    _seekRelative(const Duration(seconds: 10));
  }

  void _startHideTimer() {
    final hideControlsTimer = chewieController.hideControlsTimer.isNegative
        ? ChewieController.defaultHideControlsTimer
        : chewieController.hideControlsTimer;
    _hideTimer = Timer(hideControlsTimer, () {
      setState(() {
        notifier.hideStuff = true;
      });
    });
  }

  void _bufferingTimerTimeout() {
    _displayBufferingIndicator = true;
    if (mounted) {
      setState(() {});
    }
  }

  void _updateState() {
    if (!mounted) return;

    final bool buffering = getIsBuffering(controller);

    // display the progress bar indicator only after the buffering delay if it has been set
    if (chewieController.progressIndicatorDelay != null) {
      if (buffering) {
        _bufferingDisplayTimer ??= Timer(
          chewieController.progressIndicatorDelay!,
          _bufferingTimerTimeout,
        );
      } else {
        _bufferingDisplayTimer?.cancel();
        _bufferingDisplayTimer = null;
        _displayBufferingIndicator = false;
      }
    } else {
      _displayBufferingIndicator = buffering;
    }

    setState(() {
      _latestValue = controller.value;
      _subtitlesPosition = controller.value.position;
    });
  }

  Widget _buildProgressBar() {
    return MaterialVideoProgressBar(
      controller,
      barHeight: chewieController.materialProgressBarHeight,
      handleHeight: chewieController.materialProgressHandleHeight,
      onDragStart: () {
        setState(() {
          _dragging = true;
        });

        _hideTimer?.cancel();
      },
      onDragUpdate: () {
        _hideTimer?.cancel();
      },
      onDragEnd: () {
        setState(() {
          _dragging = false;
        });

        _startHideTimer();
      },
      colors:
          chewieController.materialProgressColors ??
          ChewieProgressColors(
            playedColor: Theme.of(context).colorScheme.secondary,
            handleColor: Theme.of(context).colorScheme.secondary,
            bufferedColor: Theme.of(
              context,
            ).colorScheme.surface.withValues(alpha: 0.5),
            backgroundColor: Theme.of(
              context,
            ).disabledColor.withValues(alpha: .5),
          ),
      draggableProgressBar: chewieController.draggableProgressBar,
    );
  }
}
