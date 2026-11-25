import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import 'desk.dart';
import 'media_player.dart';
import 'window_manager.dart';
import 'xp_theme.dart';

const kMiniPlayerId = 'miniplayer';

/// The small always-on-top remote for the desktop's own Media Player.
DeskWindow miniPlayerWindow() => DeskWindow(
      id: kMiniPlayerId,
      title: 'Media Player',
      icon: Icons.music_note,
      size: const Size(360, 158),
      resizable: false,
      canMaximize: false,
      alwaysOnTop: true,
      content: (c, w) => const _MiniPlayer(),
    );

class _MiniPlayer extends StatefulWidget {
  const _MiniPlayer();

  @override
  State<_MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<_MiniPlayer> {
  final _p = DeskPlayer.instance;
  String _lastTitle = '';

  @override
  void initState() {
    super.initState();
    _p.addListener(_changed);
    if (!MediaLibrary.instance.scanned) unawaited(MediaLibrary.instance.scan());
  }

  @override
  void dispose() {
    _p.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final t = _p.current?.title ?? 'Media Player';
    if (t != _lastTitle) {
      _lastTitle = t;
      context.read<WindowManager>().setTitle(kMiniPlayerId, t);
    }
  }

  /// Back to the big Media Player (closes this one).
  void _toFull() {
    final desk = context.read<Desk>();
    context.read<WindowManager>().close(kMiniPlayerId);
    desk.openMediaPlayer();
  }

  /// Album art, or the video itself for videos.
  Widget _art(MediaItem cur) {
    final c = _p.controller;
    if (cur.video && c != null && c.value.isInitialized) {
      return Container(
        width: 96,
        height: 96,
        color: Colors.black,
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(width: c.value.size.width, height: c.value.size.height, child: VideoPlayer(c)),
        ),
      );
    }
    return MediaArt(item: cur, size: 96);
  }

  @override
  Widget build(BuildContext context) {
    final desk = context.read<Desk>();
    final cur = _p.current;
    if (cur == null) {
      final lib = MediaLibrary.instance;
      return Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          const MediaArt(item: null, size: 96),
          const SizedBox(width: 10),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Nothing playing', style: Xp.textBold),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                XpButton(
                    label: 'Shuffle All',
                    minWidth: 90,
                    onPressed: lib.songs.isEmpty ? null : () => _p.play(lib.songs, 0, shuffled: true)),
                XpButton(label: 'Library...', minWidth: 80, onPressed: () => desk.openMediaPlayer(tab: 1)),
              ]),
            ]),
          ),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GestureDetector(
          onDoubleTap: cur.video ? () => _p.setFullScreen(true) : _toFull,
          child: _art(cur),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(cur.title, style: Xp.textBold, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(cur.subtitle, style: Xp.textGrey.copyWith(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              RoundButton(icon: Icons.skip_previous, tip: 'Previous', onTap: _p.previous),
              const SizedBox(width: 6),
              RoundButton(
                  icon: _p.playing ? Icons.pause : Icons.play_arrow,
                  tip: _p.playing ? 'Pause' : 'Play',
                  size: 34,
                  onTap: _p.toggle),
              const SizedBox(width: 6),
              RoundButton(icon: Icons.skip_next, tip: 'Next', onTap: _p.next),
              const Spacer(),
              if (cur.video)
                Tooltip(
                  message: 'Full Screen',
                  child: GestureDetector(
                    onTap: () => _p.setFullScreen(true),
                    child: const Padding(padding: EdgeInsets.all(3), child: Icon(Icons.fullscreen, size: 18)),
                  ),
                ),
              Tooltip(
                message: 'Switch to the full Media Player (Ctrl+1)',
                child: GestureDetector(
                  onTap: _toFull,
                  child: const Padding(padding: EdgeInsets.all(3), child: Icon(Icons.open_in_new, size: 16)),
                ),
              ),
            ]),
            SeekBar(player: _p),
          ]),
        ),
      ]),
    );
  }
}
