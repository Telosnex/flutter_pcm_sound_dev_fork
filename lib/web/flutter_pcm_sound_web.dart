import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart';

class FlutterPcmSoundPlugin {
  static void registerWith(Registrar registrar) {
    final MethodChannel channel = MethodChannel(
      'flutter_pcm_sound/methods',
      const StandardMethodCodec(),
      registrar,
    );
    final instance = FlutterPcmSoundPlugin._(channel);
    channel.setMethodCallHandler(instance._handleMethodCall);
  }

  final MethodChannel _channel;
  AudioContext? _audioContext;
  AudioWorkletNode? _workletNode;
  bool _didSetup = false;
  int _numChannels = 1;
  int _sampleRate = 44100;
  int _feedThreshold = 8000;
  bool _invokedFeedCallback = false;

  FlutterPcmSoundPlugin._(this._channel);

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'setLogLevel':
        return true; // Logging handled by print statements as needed.
      case 'setup':
        final args = call.arguments as Map;
        _sampleRate = args['sample_rate'];
        _numChannels = args['num_channels'];
        await _initializeAudioWorklet();
        _didSetup = true;
        return true;
      case 'feed':
        if (!_didSetup) {
          _handleMethodCall(MethodCall('setup', call.arguments));
        }
        final args = call.arguments as Map;
        final Uint8List buffer = args['buffer'];
        if (buffer.isEmpty) {
          print("[PCM][ERROR] Received empty buffer.");
          return true;
        }
        _invokedFeedCallback = false;
        _workletNode?.port
            .postMessage({'type': 'samples', 'samples': buffer}.jsify());
        return true;
      case 'setFeedThreshold':
        final args = call.arguments as Map;
        _feedThreshold = args['feed_threshold'];
        _workletNode?.port.postMessage({
          'type': 'configThreshold',
          'feedThreshold': _feedThreshold
        }.jsify());
        return true;
      case 'release':
        _cleanup();
        return true;
      default:
        throw PlatformException(
            code: 'Unimplemented',
            message: '${call.method} not implemented on web');
    }
  }

  Future<void> _initializeAudioWorklet() async {
    if (_audioContext == null) {
      _audioContext =
          AudioContext(AudioContextOptions(sampleRate: _sampleRate));
    }

    final workletUrl = _createWorkletUrl();
    try {
      await _audioContext!.audioWorklet.addModule(workletUrl).toDart;
    } finally {
      // Clean up the Blob URL after it's loaded
      URL.revokeObjectURL(workletUrl);
    }
    _workletNode = AudioWorkletNode(_audioContext!, 'pcm-processor');

    _workletNode!.port
        .postMessage({'type': 'config', 'numChannels': _numChannels}.toJSBox);
    _workletNode!.port.postMessage(
        {'type': 'configThreshold', 'feedThreshold': _feedThreshold}.toJSBox);

    _workletNode!.port.onmessage =
        ((MessageEvent event) => _onMessage(event)).toJS;
    _workletNode!.connect(_audioContext!.destination);
    await _audioContext!.resume().toDart;
    print("[PCM] AudioWorklet setup complete and stable.");
  }

  void _onMessage(MessageEvent event) {
    final data = event.data?.dartify();
    if (data is Map) {
      if (data['type'] == 'requestMoreData') {
        final remainingFrames = data['remainingFrames'] as int;
        _invokedFeedCallback = true;
        _channel.invokeMethod(
            'OnFeedSamples', {'remaining_frames': remainingFrames});
      } else if (data['type'] == 'configured') {
        print('[PCM] AudioWorklet configured successfully.');
      }
    }
  }

  void _cleanup() {
    if (_workletNode != null) {
      _workletNode!.disconnect();
      _workletNode = null;
    }
    if (_audioContext != null) {
      _audioContext!.close();
      _audioContext = null;
    }
    _didSetup = false;
    print("[PCM] Cleaned up audio resources. System stable.");
  }
}

String _createWorkletUrl() {
  final blob = Blob(
    [_workletJs.jsify()!].toJS,
    BlobPropertyBag(type: 'application/javascript'),
  );
  return URL.createObjectURL(blob);
}

const _workletJs = '''
class PCMProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this._queue = [];
    this.numChannels = 1;
    this.feedThreshold = 8000;
    this.invokedFeedCallback = false;

    this.port.onmessage = (event) => {
      const data = event.data;
      if (!data) return;
      switch (data.type) {
        case 'config':
          this.numChannels = data.numChannels;
          this.port.postMessage({type: 'configured'});
          break;
        case 'configThreshold':
          this.feedThreshold = data.feedThreshold;
          break;
        case 'samples':
          // Append incoming PCM data to the queue as Int16
          const samples = data.samples;
          if (samples && samples.length > 0) {
            this._queue.push(new Int16Array(samples));
            this.invokedFeedCallback = false;
          }
          break;
      }
    };
  }

  process(inputs, outputs, parameters) {
    const output = outputs[0];
    const framesNeeded = output[0].length;
    let framePos = 0;

    while (framePos < framesNeeded && this._queue.length > 0) {
      const currentBuffer = this._queue[0];
      const framesFromBuffer = Math.min(
        currentBuffer.length / this.numChannels,
        framesNeeded - framePos
      );

      for (let f = 0; f < framesFromBuffer; f++) {
        for (let ch = 0; ch < this.numChannels; ch++) {
          const sampleInt = currentBuffer[f * this.numChannels + ch];
          const sampleFloat = sampleInt / 32768.0;
          output[ch][framePos + f] = sampleFloat;
        }
      }

      const usedSamples = framesFromBuffer * this.numChannels;
      if (usedSamples < currentBuffer.length) {
        this._queue[0] = currentBuffer.slice(usedSamples);
      } else {
        this._queue.shift();
      }
      framePos += framesFromBuffer;
    }

    while (framePos < framesNeeded) {
      for (let ch = 0; ch < this.numChannels; ch++) {
        output[ch][framePos] = 0.0;
      }
      framePos++;
    }

    let totalSamples = 0;
    for (const b of this._queue) {
      totalSamples += b.length;
    }
    const remainingFrames = totalSamples / this.numChannels;

    if (remainingFrames <= this.feedThreshold && !this.invokedFeedCallback) {
      this.invokedFeedCallback = true;
      this.port.postMessage({
        type: 'requestMoreData',
        remainingFrames: remainingFrames
      });
    }

    return true;
  }
}

registerProcessor('pcm-processor', PCMProcessor);
''';
