import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../core/event_bus.dart';
import '../models/app_settings.dart';
import '../models/nav_event.dart';
import '../providers/app_providers.dart';
import '../providers/ui_providers.dart';

/// Đọc hướng dẫn bằng giọng vi-VN — subscriber của [NavEventBus] (§4.3 bước 5).
/// Độc lập với engine: thêm/bỏ giọng nói không sửa NavController.
class NavVoice {
  final FlutterTts _tts = FlutterTts();
  StreamSubscription<VoicePrompt>? _sub;
  bool muted = false;
  bool _ready = false;

  NavVoice(
    NavEventBus bus, {
    required double rate,
    required AppLanguage language,
  }) {
    _init(rate, language);
    _sub = bus.on<VoicePrompt>().listen((e) async {
      if (!muted && _ready) {
        await _tts.stop();
        await _tts.speak(e.text);
      }
    });
  }

  Future<void> _init(double rate, AppLanguage language) async {
    await setLanguage(language);
    await _tts.setSpeechRate(rate.clamp(0.2, 0.9));
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _ready = true;
  }

  Future<void> setLanguage(AppLanguage language) async {
    final preferred = language.navigationLanguage;
    final prefix = language == AppLanguage.vi ? 'vi' : 'en';
    try {
      final langs = await _tts.getLanguages;
      final list = langs as List;
      final match = list
          .cast<Object?>()
          .map((l) => l.toString())
          .firstWhere(
            (l) => l.toLowerCase() == preferred.toLowerCase(),
            orElse: () => list
                .cast<Object?>()
                .map((l) => l.toString())
                .firstWhere(
                  (l) => l.toLowerCase().startsWith(prefix),
                  orElse: () => preferred,
                ),
          );
      await _tts.setLanguage(match);
    } catch (_) {
      try {
        await _tts.setLanguage(preferred);
      } catch (_) {
        // Ignore unsupported language errors; TTS may fall back internally.
      }
    }
  }

  Future<void> setRate(double r) => _tts.setSpeechRate(r.clamp(0.2, 0.9));
  void toggleMute() => muted = !muted;

  Future<void> speak(String text) async {
    if (_ready) {
      await _tts.stop();
      await _tts.speak(text);
    }
  }

  void dispose() {
    _sub?.cancel();
    _tts.stop();
  }
}

/// Provider giữ NavVoice sống suốt phiên dẫn đường, đồng bộ rate từ settings.
final navVoiceProvider = Provider<NavVoice>((ref) {
  final settings = ref.read(settingsProvider);
  final voice = NavVoice(
    ref.watch(navEventBusProvider),
    rate: settings.ttsRate,
    language: settings.language,
  );
  ref.listen(settingsProvider, (prev, next) {
    voice.setRate(next.ttsRate);
    if (prev?.language != next.language) {
      unawaited(voice.setLanguage(next.language));
    }
    voice.muted = !next.ttsEnabled;
  });
  ref.onDispose(voice.dispose);
  return voice;
});
