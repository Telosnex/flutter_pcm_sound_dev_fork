import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return const PcmSoundApp();
  }
}

class PcmSoundApp extends StatefulWidget {
  const PcmSoundApp({Key? key}) : super(key: key);

  @override
  State<PcmSoundApp> createState() => _PcmSoundAppState();
}

class _PcmSoundAppState extends State<PcmSoundApp> {
  static const int sampleRate = 48000;

  int _remainingFrames = 0;
  MajorScale scale = MajorScale(sampleRate: sampleRate, noteDuration: 0.20);
  MajorScale _stressScale = MajorScale(sampleRate: sampleRate, noteDuration: 0.12);

  // ── Stress-test state ──────────────────────────────────────────────────
  bool _stressRunning = false;
  Timer? _stressTimer;
  Timer? _jankTimer;
  Timer? _uiTimer;
  int _stressFeedCount = 0;
  int _stressDropCount = 0;
  double _phase = 0.0;
  bool _stressUseSine = true;

  @override
  void initState() {
    super.initState();
    FlutterPcmSound.setLogLevel(LogLevel.verbose);
    if (!kIsWeb) {
      FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
    }
    FlutterPcmSound.setFeedThreshold(sampleRate ~/ 10);
    FlutterPcmSound.setFeedCallback(_onFeed);
  }

  @override
  void dispose() {
    _stopStress();
    FlutterPcmSound.release();
    super.dispose();
  }

  // ── Normal playback ────────────────────────────────────────────────────

  void _onFeed(int remainingFrames) async {
    setState(() => _remainingFrames = remainingFrames);
    List<int> frames = scale.generate(periods: 20);
    await FlutterPcmSound.feed(PcmArrayInt16.fromList(frames));
  }

  // ── Stress test ────────────────────────────────────────────────────────
  //
  // Maximises contention between main thread (feed) and RT audio thread:
  //
  //   1. Feeds 128-frame chunks (~2.7 ms of audio) as fast as the event
  //      loop allows, batching multiple feeds per timer tick.
  //
  //   2. Every 50 ms, blocks the main thread for 8 ms of busy-work,
  //      simulating UI jank / GC pauses.
  //
  //   3. Continuous 440 Hz sine — any glitch is instantly audible.

  void _startStress() {
    if (_stressRunning) return;
    _stressRunning = true;
    _stressFeedCount = 0;
    _stressDropCount = 0;
    _phase = 0.0;

    // Disable the normal-playback feed callback.
    FlutterPcmSound.setFeedCallback(null);

    // Feed aggressively: every 5 ms, push several tiny chunks.
    _stressTimer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      if (_stressUseSine) {
        for (int i = 0; i < 4; i++) {
          _stressFeed(128);
        }
      } else {
        // Use the MajorScale generator — same tiny-chunk stress pattern.
        final frames = _stressScale.generate(periods: 2);
        FlutterPcmSound.feed(PcmArrayInt16.fromList(frames));
        _stressFeedCount++;
      }
    });

    // Hammer the main thread: 15 ms of busy-work every 30 ms.
    // That's 50% of wall-clock time where the main thread is blocked
    // and can't service the event loop.  Any @synchronized contention
    // in the old code will hit this constantly.
    _jankTimer = Timer.periodic(const Duration(milliseconds: 30), (_) {
      _simulateJank();
    });

    // Update the UI counter periodically (timers don't call setState).
    _uiTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && _stressRunning) setState(() {});
    });

    // Kick-start immediately.
    for (int i = 0; i < 10; i++) {
      _stressFeed(128);
    }

    setState(() {});
  }

  void _stopStress() {
    _stressTimer?.cancel();
    _stressTimer = null;
    _jankTimer?.cancel();
    _jankTimer = null;
    _uiTimer?.cancel();
    _uiTimer = null;
    _stressRunning = false;

    // Tear down and re-init so audio stops immediately
    // (otherwise the ring buffer / NSMutableData drains to silence).
    FlutterPcmSound.release().then((_) {
      if (!kIsWeb) {
        FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
      }
      FlutterPcmSound.setFeedThreshold(sampleRate ~/ 10);
      FlutterPcmSound.setFeedCallback(_onFeed);
    });

    if (mounted) setState(() {});
  }

  /// Feed [n] frames of a continuous 440 Hz sine wave.
  void _stressFeed(int n) {
    const double freq = 440.0;
    const double volume = 0.5;
    final double step = 2.0 * math.pi * freq / sampleRate;

    final byteData = ByteData(n * 2);
    for (int i = 0; i < n; i++) {
      final sample = (math.sin(_phase) * volume * 32767).toInt();
      byteData.setInt16(i * 2, sample, Endian.host);
      _phase += step;
    }
    _phase %= 2.0 * math.pi;

    _stressFeedCount++;
    FlutterPcmSound.feed(PcmArrayInt16(bytes: byteData)).catchError((_) {
      _stressDropCount++;
    });
  }

  /// Busy-wait on the main thread for ~15 ms.
  /// Also thrashes memory to trigger GC pauses and increase the
  /// chance of holding the @synchronized lock during a render callback.
  void _simulateJank() {
    final sw = Stopwatch()..start();
    double sink = 0;
    // Allocate + fill throwaway buffers to pressure the GC.
    final junk = <List<int>>[];
    while (sw.elapsedMilliseconds < 15) {
      junk.add(List<int>.generate(4096, (i) => i));
      for (int i = 0; i < 2000; i++) {
        sink += math.sin(i.toDouble());
      }
    }
    if (sink == double.negativeInfinity) debugPrint('$sink ${junk.length}');
  }

  // ── UI ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(primarySwatch: Colors.blue),
      home: Scaffold(
        appBar: AppBar(
          centerTitle: true,
          title: const Text('Flutter PCM Sound'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              const Text('Normal Playback',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ElevatedButton(
                onPressed: () {
                  if (kIsWeb) {
                    FlutterPcmSound.setup(
                        sampleRate: sampleRate, channelCount: 1);
                  }
                  FlutterPcmSound.setFeedCallback(_onFeed);
                  _onFeed(0);
                },
                child: const Text('Play Scale'),
              ),
              ElevatedButton(
                onPressed: () {
                  FlutterPcmSound.setFeedCallback(null);
                  setState(() => _remainingFrames = 0);
                },
                child: const Text('Stop'),
              ),
              Text('$_remainingFrames remaining frames'),

              const Divider(height: 40),

              const Text('Stress Test (440 Hz sine)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  'Tiny chunks every 5 ms + simulated main-thread jank.\n'
                  'Old code: pops/clicks.  New code: clean tone.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _stressRunning ? Colors.red : Colors.green,
                ),
                onPressed: _stressRunning ? _stopStress : _startStress,
                child: Text(_stressRunning
                    ? 'Stop Stress Test'
                    : 'Start Stress Test'),
              ),
              if (_stressRunning) ...[
                Text(
                  'Feeds: $_stressFeedCount  |  Errors: $_stressDropCount',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Melody'),
                    Switch(
                      value: _stressUseSine,
                      onChanged: (v) => setState(() => _stressUseSine = v),
                    ),
                    const Text('Sine'),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
