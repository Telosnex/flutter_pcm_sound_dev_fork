package com.lib.flutter_pcm_sound;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.media.AudioFocusRequest;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;

import androidx.annotation.NonNull;

import java.util.Map;
import java.util.HashMap;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.atomic.AtomicLong;
import java.io.StringWriter;
import java.io.PrintWriter;
import java.nio.ByteBuffer;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * FlutterPcmSoundPlugin implements a "one pedal" PCM sound playback mechanism.
 * Playback starts automatically when samples are fed and stops when no more samples are available.
 */
public class FlutterPcmSoundPlugin implements
    FlutterPlugin,
    MethodChannel.MethodCallHandler
{
    private static final String CHANNEL_NAME = "flutter_pcm_sound/methods";
    private static final int BUFFER_SIZE_MULTIPLIER = 4;
    private static final int MIN_TARGET_BUFFER_MS = 160;

    private MethodChannel mMethodChannel;
    private Handler mainThreadHandler = new Handler(Looper.getMainLooper());
    private Thread playbackThread;
    private volatile boolean mShouldCleanup = false;

    private AudioTrack mAudioTrack;
    private int mNumChannels;
    private int mMinBufferSize;
    private int mBytesPerFrame;
    private int mTargetBufferSize;
    private boolean mDidSetup = false;

    // Needed for AudioFocus management.
    private Context context;
    private AudioManager audioManager;
    private AudioFocusRequest focusRequest;
    private AudioAttributes playbackAttributes;

    private long mFeedThreshold = 8000;
    private volatile boolean mDidInvokeFeedCallback = false;

    // Thread-safe queue for storing audio samples
    private final LinkedBlockingQueue<ByteBuffer> mSamples = new LinkedBlockingQueue<>();
    private final AtomicLong mBufferedBytes = new AtomicLong(0);

    // Log level enum (kept for potential future use)
    private enum LogLevel {
        NONE,
        ERROR,
        STANDARD,
        VERBOSE
    }

    private LogLevel mLogLevel = LogLevel.VERBOSE;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        BinaryMessenger messenger = binding.getBinaryMessenger();
        mMethodChannel = new MethodChannel(messenger, CHANNEL_NAME);
        mMethodChannel.setMethodCallHandler(this);

        this.context = binding.getApplicationContext();
        this.audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        mMethodChannel.setMethodCallHandler(null);
        cleanup();
    }

    @Override
    @SuppressWarnings("deprecation") // Needed for compatibility with Android < 23
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        try {
            switch (call.method) {
                case "setLogLevel": {
                    result.success(true);
                    break;
                }
                case "setup": {
                    Integer sampleRateObj = call.argument("sample_rate");
                    Integer numChannelsObj = call.argument("num_channels");

                    if (sampleRateObj == null || numChannelsObj == null) {
                        result.error("InvalidArguments", "sample_rate and num_channels are required.", null);
                        return;
                    }

                    int sampleRate = sampleRateObj;
                    mNumChannels = numChannelsObj;

                    if (mNumChannels <= 0) {
                        result.error("InvalidArguments", "num_channels must be greater than zero.", null);
                        return;
                    }

                    // Cleanup existing resources if any
                    if (mAudioTrack != null) {
                        cleanup();
                    }

                    int channelConfig = (mNumChannels == 2) ?
                        AudioFormat.CHANNEL_OUT_STEREO :
                        AudioFormat.CHANNEL_OUT_MONO;

                    mMinBufferSize = AudioTrack.getMinBufferSize(
                        sampleRate, channelConfig, AudioFormat.ENCODING_PCM_16BIT);

                    if (mMinBufferSize == AudioTrack.ERROR || mMinBufferSize == AudioTrack.ERROR_BAD_VALUE) {
                        result.error("AudioTrackError", "Invalid buffer size.", null);
                        return;
                    }

                    mBytesPerFrame = mNumChannels * 2; // 16-bit PCM

                    int computedTargetBuffer = Math.max(
                        mMinBufferSize * BUFFER_SIZE_MULTIPLIER,
                        alignToFrameSize((sampleRate * mBytesPerFrame * MIN_TARGET_BUFFER_MS) / 1000)
                    );

                    if (computedTargetBuffer < mMinBufferSize) {
                        computedTargetBuffer = alignToFrameSize(mMinBufferSize);
                    }

                    mTargetBufferSize = computedTargetBuffer;

                    if (Build.VERSION.SDK_INT >= 23) { // Android 6 (Marshmallow) and above
                        mAudioTrack = new AudioTrack.Builder()
                            .setAudioAttributes(new AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                    .build())
                            .setAudioFormat(new AudioFormat.Builder()
                                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                                    .setSampleRate(sampleRate)
                                    .setChannelMask(channelConfig)
                                    .build())
                            .setBufferSizeInBytes(mTargetBufferSize)
                            .setTransferMode(AudioTrack.MODE_STREAM)
                            .build();
                    } else {
                        mAudioTrack = new AudioTrack(
                            AudioManager.STREAM_MUSIC,
                            sampleRate,
                            channelConfig,
                            AudioFormat.ENCODING_PCM_16BIT,
                            mTargetBufferSize,
                            AudioTrack.MODE_STREAM);
                    }

                    if (mAudioTrack.getState() != AudioTrack.STATE_INITIALIZED) {
                        result.error("AudioTrackError", "AudioTrack initialization failed.", null);
                        mAudioTrack.release();
                        mAudioTrack = null;
                        return;
                    }

                    mSamples.clear();
                    mBufferedBytes.set(0);
                    mDidInvokeFeedCallback = false;
                    mShouldCleanup = false;

                    // Request audio focus for ducking
                    if (audioManager != null) {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            playbackAttributes = new AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                    .build();

                            focusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                                    .setAudioAttributes(playbackAttributes)
                                    .setOnAudioFocusChangeListener(focusChange -> {
                                        // handle audio focus changes if needed
                                    })
                                    .build();

                            int focusResult = audioManager.requestAudioFocus(focusRequest);
                            if (focusResult != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                                result.error("AudioFocusError", "Could not get audio focus.", null);
                                return;
                            }
                        } else {
                            int focusResult = audioManager.requestAudioFocus(
                                    focusChange -> {
                                        // handle focus changes if needed
                                    },
                                    AudioManager.STREAM_MUSIC,
                                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
                            );
                            if (focusResult != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                                result.error("AudioFocusError", "Could not get audio focus.", null);
                                return;
                            }
                        }
                    }

                    // Start playback thread
                    playbackThread = new Thread(this::playbackThreadLoop, "PCMPlaybackThread");
                    playbackThread.setPriority(Thread.MAX_PRIORITY);
                    playbackThread.start();

                    mDidSetup = true;

                    result.success(true);
                    break;
                }
                case "feed": {

                    // check setup (to match iOS behavior)
                    if (!mDidSetup) {
                        result.error("Setup", "must call setup first", null);
                        return;
                    }

                    byte[] buffer = call.argument("buffer");

                    if (buffer == null || buffer.length == 0) {
                        result.error("InvalidArguments", "buffer is required and cannot be empty", null);
                        return;
                    }

                    ByteBuffer byteBuffer = ByteBuffer.wrap(buffer);
                    mSamples.put(byteBuffer);
                    mBufferedBytes.addAndGet(byteBuffer.remaining());

                    // Reset the feed callback flag
                    mDidInvokeFeedCallback = false;

                    result.success(true);
                    break;
                }
                case "setFeedThreshold": {
                    mFeedThreshold = ((Number) call.argument("feed_threshold")).longValue();
                    result.success(true);
                    break;
                }
                case "release": {
                    cleanup();
                    result.success(true);
                    break;
                }
                default:
                    result.notImplemented();
                    break;
            }


        } catch (Exception e) {
            StringWriter sw = new StringWriter();
            PrintWriter pw = new PrintWriter(sw);
            e.printStackTrace(pw);
            String stackTrace = sw.toString();
            result.error("androidException", e.toString(), stackTrace);
        }
    }


    /**
     * Cleans up resources by stopping the playback thread and releasing AudioTrack.
     */
    private void cleanup() {
        // stop playback thread
        if (playbackThread != null) {
            mShouldCleanup = true;
            playbackThread.interrupt();
            try {
                playbackThread.join();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            playbackThread = null;
            mDidSetup = false;
        }

        if (mAudioTrack != null) {
            mAudioTrack.release();
            mAudioTrack = null;
        }

        mSamples.clear();
        mBufferedBytes.set(0);

        // Abandon audio focus
        if (audioManager != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && focusRequest != null) {
                audioManager.abandonAudioFocusRequest(focusRequest);
            } else {
                audioManager.abandonAudioFocus(null);
            }
        }
    }

    /**
     * Calculates the number of remaining frames in the sample buffer.
     */
    private long mRemainingFrames() {
        if (mBytesPerFrame <= 0) {
            return 0;
        }
        long totalBytes = mBufferedBytes.get();
        return totalBytes / mBytesPerFrame; // 16-bit PCM
    }

    /**
     * Invokes the 'OnFeedSamples' callback with the number of remaining frames.
     */
    private void invokeFeedCallback() {
        long remainingFrames = mRemainingFrames();
        Map<String, Object> response = new HashMap<>();
        response.put("remaining_frames", remainingFrames);
        mMethodChannel.invokeMethod("OnFeedSamples", response);
    }


    /**
     * The main loop of the playback thread.
     */
    private void playbackThreadLoop() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO);

        mAudioTrack.play();

        while (!mShouldCleanup) {
            ByteBuffer data = null;
            try {
                // blocks indefinitely until new data
                data = mSamples.take();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                continue;
            }

            if (data == null) {
                continue;
            }

            int bytesToWrite = data.remaining();
            int written = mAudioTrack.write(data, bytesToWrite, AudioTrack.WRITE_BLOCKING);

            if (written > 0) {
                long remaining = mBufferedBytes.addAndGet(-written);
                if (remaining < 0) {
                    mBufferedBytes.set(0);
                }
            }

            // invoke feed callback?
            if (mRemainingFrames() <= mFeedThreshold && !mDidInvokeFeedCallback) {
                mDidInvokeFeedCallback = true;
                mainThreadHandler.post(this::invokeFeedCallback);
            }
        }

        mAudioTrack.stop();
        mAudioTrack.flush();
        mAudioTrack.release();
        mAudioTrack = null;
    }


    private int alignToFrameSize(int sizeInBytes) {
        if (mBytesPerFrame <= 0) {
            return sizeInBytes;
        }
        int remainder = sizeInBytes % mBytesPerFrame;
        if (remainder == 0) {
            return sizeInBytes;
        }
        return sizeInBytes + (mBytesPerFrame - remainder);
    }
}
