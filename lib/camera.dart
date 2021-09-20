// Copyright 2018 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:event_bus/event_bus.dart';

part 'camera_image.dart';

final MethodChannel _channel =
    const MethodChannel('plugins.flutter.io/camera_with_rtmp');

enum CameraLensDirection { front, back, external }

EventBus eventBus = EventBus();

/// Affect the quality of video recording and image capture:
///
/// If a preset is not available on the camera being used a preset of lower quality will be selected automatically.
enum ResolutionPreset {
  /// 352x288 on iOS, 240p (320x240) on Android
  low,

  /// 480p (640x480 on iOS, 720x480 on Android)
  medium,

  /// 720p (1280x720)
  high,

  /// 1080p (1920x1080)
  veryHigh,

  /// 2160p (3840x2160)
  ultraHigh,

  /// The highest resolution available.
  max,
}

// ignore: inference_failure_on_function_return_type
// ignore: camel_case_types
typedef onLatestImageAvailable = Function(CameraImage image);

/// Returns the resolution preset as a String.
String serializeResolutionPreset(ResolutionPreset resolutionPreset) {
  switch (resolutionPreset) {
    case ResolutionPreset.max:
      return 'max';
    case ResolutionPreset.ultraHigh:
      return 'ultraHigh';
    case ResolutionPreset.veryHigh:
      return 'veryHigh';
    case ResolutionPreset.high:
      return 'high';
    case ResolutionPreset.medium:
      return 'medium';
    case ResolutionPreset.low:
      return 'low';
  }
  // ignore: dead_code
  throw ArgumentError('Unknown ResolutionPreset value');
}

CameraLensDirection _parseCameraLensDirection(String string) {
  switch (string) {
    case 'front':
      return CameraLensDirection.front;
    case 'back':
      return CameraLensDirection.back;
    case 'external':
      return CameraLensDirection.external;
  }
  throw ArgumentError('Unknown CameraLensDirection value');
}

/// Completes with a list of available cameras.
///
/// May throw a [CameraException].
Future<List<CameraDescription>> availableCameras() async {
  try {
    final List<Map>? cameras = await _channel
        .invokeListMethod<Map<dynamic, dynamic>>('availableCameras');
    return cameras!.map((Map<dynamic, dynamic> camera) {
      return CameraDescription(
        name: camera['name'],
        lensDirection: _parseCameraLensDirection(camera['lensFacing']),
        sensorOrientation: camera['sensorOrientation'],
      );
    }).toList();
  } on PlatformException catch (e) {
    throw CameraException(e.code, e.message.toString());
  }
}

class CameraDescription {
  CameraDescription(
      {required this.name,
      required this.lensDirection,
      required this.sensorOrientation});

  final String name;
  final CameraLensDirection lensDirection;

  /// Clockwise angle through which the output image needs to be rotated to be upright on the device screen in its native orientation.
  ///
  /// **Range of valid values:**
  /// 0, 90, 180, 270
  ///
  /// On Android, also defines the direction of rolling shutter readout, which
  /// is from top to bottom in the sensor's coordinate system.
  final int sensorOrientation;

  @override
  bool operator ==(Object o) {
    return o is CameraDescription &&
        o.name == name &&
        o.lensDirection == lensDirection;
  }

  @override
  int get hashCode {
    return hashValues(name, lensDirection);
  }

  @override
  String toString() {
    return '$runtimeType($name, $lensDirection, $sensorOrientation)';
  }
}

/// Statistics about the streaming, bitrate, errors, drops etc.
///
class StreamStatistics {
  final int cacheSize;
  final int sentAudioFrames;
  final int sentVideoFrames;
  final int droppedAudioFrames;
  final int droppedVideoFrames;
  final bool isAudioMuted;
  final int bitrate;
  final int width;
  final int height;

  StreamStatistics({
    required this.cacheSize,
    required this.sentAudioFrames,
    required this.sentVideoFrames,
    required this.droppedAudioFrames,
    required this.droppedVideoFrames,
    required this.bitrate,
    required this.width,
    required this.height,
    required this.isAudioMuted,
  });

  @override
  String toString() {
    return 'StreamStatistics{cacheSize: $cacheSize, sentAudioFrames: $sentAudioFrames, sentVideoFrames: $sentVideoFrames, droppedAudioFrames: $droppedAudioFrames, droppedVideoFrames: $droppedVideoFrames, isAudioMuted: $isAudioMuted, bitrate: $bitrate, width: $width, height: $height}';
  }
}

/// This is thrown when the plugin reports an error.
class CameraException implements Exception {
  CameraException(this.code, this.description);

  String code;
  String description;

  @override
  String toString() => '$runtimeType($code, $description)';
}

// Build the UI texture view of the video data with textureId.
class CameraPreview extends StatelessWidget {
  const CameraPreview(this.controller);

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    return controller.value.isInitialized
        ? controller.value.previewSize.width <
                controller.value.previewSize.height
            ? RotatedBox(
                quarterTurns: controller.value.previewQuarterTurns,
                child: Texture(textureId: controller._textureId))
            : Texture(textureId: controller._textureId)
        : Container();
  }
}

/// The state of a [CameraController].
class CameraValue {
  const CameraValue({
    this.isInitialized = false,
    this.errorDescription = '',
    this.previewSize = const Size(0, 0),
    this.previewQuarterTurns = 0,
    this.isRecordingVideo = false,
    this.isTakingPicture = false,
    this.isStreamingImages = false,
    this.isStreamingVideoRtmp = false,
    bool isRecordingPaused = false,
    bool isStreamingPaused = false,
  })  : _isRecordingPaused = isRecordingPaused,
        _isStreamingPaused = isStreamingPaused;

  const CameraValue.uninitialized()
      : this(
          isInitialized: false,
          isRecordingVideo: false,
          isTakingPicture: false,
          isStreamingImages: false,
          isStreamingVideoRtmp: false,
          isRecordingPaused: false,
          isStreamingPaused: false,
          previewQuarterTurns: 0,
        );

  /// True after [CameraController.initialize] has completed successfully.
  final bool isInitialized;

  /// True when a picture capture request has been sent but as not yet returned.
  final bool isTakingPicture;

  /// True when the camera is recording (not the same as previewing).
  final bool isRecordingVideo;

  /// True when the camera is recording (not the same as previewing).
  final bool isStreamingVideoRtmp;

  /// True when images from the camera are being streamed.
  final bool isStreamingImages;

  final bool _isRecordingPaused;
  final bool _isStreamingPaused;

  /// True when camera [isRecordingVideo] and recording is paused.
  bool get isRecordingPaused => isRecordingVideo && _isRecordingPaused;

  /// True when camera [isRecordingVideo] and streaming is paused.
  bool get isStreamingPaused => isStreamingVideoRtmp && _isStreamingPaused;

  final String errorDescription;

  /// The size of the preview in pixels.
  ///
  /// Is `null` until  [isInitialized] is `true`.
  final Size previewSize;

  /// The amount to rotate the preview by in quarter turns.
  ///
  /// Is `null` until  [isInitialized] is `true`.
  final int previewQuarterTurns;

  /// Convenience getter for `previewSize.height / previewSize.width`.
  ///
  /// Can only be called when [initialize] is done.
  double get aspectRatio => previewSize.height / previewSize.width;

  bool get hasError => errorDescription != null;

  CameraValue copyWith({
    bool? isInitialized,
    bool? isRecordingVideo,
    bool? isStreamingVideoRtmp,
    bool? isTakingPicture,
    bool? isStreamingImages,
    String? errorDescription,
    Size? previewSize,
    int? previewQuarterTurns,
    bool? isRecordingPaused,
    bool? isStreamingPaused,
  }) {
    return CameraValue(
      isInitialized: isInitialized ?? this.isInitialized,
      errorDescription: errorDescription ?? '',
      previewSize: previewSize ?? this.previewSize,
      previewQuarterTurns: previewQuarterTurns ?? this.previewQuarterTurns,
      isRecordingVideo: isRecordingVideo ?? this.isRecordingVideo,
      isStreamingVideoRtmp: isStreamingVideoRtmp ?? this.isStreamingVideoRtmp,
      isTakingPicture: isTakingPicture ?? this.isTakingPicture,
      isStreamingImages: isStreamingImages ?? this.isStreamingImages,
      isRecordingPaused: isRecordingPaused ?? _isRecordingPaused,
      isStreamingPaused: isStreamingPaused ?? _isStreamingPaused,
    );
  }

  @override
  String toString() {
    return '$runtimeType('
        'isRecordingVideo: $isRecordingVideo, '
        'isRecordingVideo: $isRecordingVideo, '
        'isInitialized: $isInitialized, '
        'errorDescription: $errorDescription, '
        'previewSize: $previewSize, '
        'previewQuarterTurns: $previewQuarterTurns, '
        'isStreamingImages: $isStreamingImages, '
        'isStreamingVideoRtmp: $isStreamingVideoRtmp)';
  }
}

/// Controls a device camera.
///
/// Use [availableCameras] to get a list of available cameras.
///
/// Before using a [CameraController] a call to [initialize] must complete.
///
/// To show the camera preview on the screen use a [CameraPreview] widget.
class CameraController extends ValueNotifier<CameraValue> {
  CameraController(
    this.description,
    this.resolutionPreset, {
    this.enableAudio = true,
    this.streamingPreset = ResolutionPreset.max,
    this.androidUseOpenGL = false,
  }) : super(const CameraValue.uninitialized());

  final CameraDescription description;
  final ResolutionPreset resolutionPreset;
  final ResolutionPreset streamingPreset;

  /// Whether to include audio when recording a video.
  final bool enableAudio;

  late int _textureId;
  late bool _isDisposed = false;
  late StreamSubscription<dynamic> _eventSubscription;
  late StreamSubscription<dynamic> _imageStreamSubscription;
  late Completer<void> _creatingCompleter;
  final bool androidUseOpenGL;

  /// Initializes the camera on the device.
  ///
  /// Throws a [CameraException] if the initialization fails.
  Future<void> initialize() async {
    if (_isDisposed) {
      return Future<void>.value();
    }
    try {
      _creatingCompleter = Completer<void>();
      final Map<String, dynamic>? reply =
          await _channel.invokeMapMethod<String, dynamic>(
        'initialize',
        <String, dynamic>{
          'cameraName': description.name,
          'resolutionPreset': serializeResolutionPreset(resolutionPreset),
          'streamingPreset': serializeResolutionPreset(streamingPreset),
          'enableAudio': enableAudio,
          'enableAndroidOpenGL': androidUseOpenGL
        },
      );
      _textureId = reply!['textureId'];
      value = value.copyWith(
        isInitialized: true,
        previewSize: Size(
          reply['previewWidth'].toDouble(),
          reply['previewHeight'].toDouble(),
        ),
        previewQuarterTurns: reply['previewQuarterTurns'],
      );
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message.toString());
    }
    _eventSubscription = EventChannel(
            'plugins.flutter.io/camera_with_rtmp/cameraEvents$_textureId')
        .receiveBroadcastStream()
        .listen(_listener);
    _creatingCompleter.complete();
    return _creatingCompleter.future;
  }

  /// Prepare the capture session for video recording.
  ///
  /// Use of this method is optional, but it may be called for performance
  /// reasons on iOS.
  ///
  /// Preparing audio can cause a minor delay in the CameraPreview view on iOS.
  /// If video recording is intended, calling this early eliminates this delay
  /// that would otherwise be experienced when video recording is started.
  /// This operation is a no-op on Android.
  ///
  /// Throws a [CameraException] if the prepare fails.
  Future<void> prepareForVideoRecording() async {
    await _channel.invokeMethod<void>('prepareForVideoRecording');
  }

  /// Prepare the capture session for video streaming.
  ///
  /// Use of this method is optional, but it may be called for performance
  /// reasons on iOS.
  ///
  /// Preparing audio can cause a minor delay in the CameraPreview view on iOS.
  /// If video streaming is intended, calling this early eliminates this delay
  /// that would otherwise be experienced when video streaming is started.
  /// This operation is a no-op on Android.
  ///
  /// Throws a [CameraException] if the prepare fails.
  Future<void> prepareForVideoStreaming() async {
    await _channel.invokeMethod<void>('prepareForVideoStreaming');
  }

  /// Listen to events from the native plugins.
  ///
  /// A "cameraClosing" event is sent when the camera is closed automatically by the system (for example when the app go to background). The plugin will try to reopen the camera automatically but any ongoing recording will end.
  void _listener(dynamic event) {
    final Map<dynamic, dynamic> map = event;
    if (_isDisposed) {
      return;
    }

    print("BrianEvent $map");
    switch (map['eventType']) {
      case 'error':
        value = value.copyWith(errorDescription: event['errorDescription']);
        break;
      case 'camera_closing':
        value = value.copyWith(
            isRecordingVideo: false, isStreamingVideoRtmp: false);
        break;
      case 'rtmp_connected':
        break;
      case 'rtmp_retry':
        break;
      case 'rtmp_stopped':
        value = value.copyWith(isStreamingVideoRtmp: false);
        break;
      case 'rotation_update':
        value = value.copyWith(
            previewQuarterTurns: int.parse(event['errorDescription']));
        break;
    }

    eventBus.fire(event);
  }

  /// Captures an image and saves it to [path].
  ///
  /// A path can for example be obtained using
  /// [path_provider](https://pub.dartlang.org/packages/path_provider).
  ///
  /// If a file already exists at the provided path an error will be thrown.
  /// The file can be read as this function returns.
  ///
  /// Throws a [CameraException] if the capture fails.
  Future<void> takePicture(String path) async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController.',
        'takePicture was called on uninitialized CameraController',
      );
    }
    if (value.isTakingPicture) {
      throw CameraException(
        'Previous capture has not returned yet.',
        'takePicture was called before the previous capture returned.',
      );
    }
    try {
      value = value.copyWith(isTakingPicture: true);
      await _channel.invokeMethod<void>(
        'takePicture',
        <String, dynamic>{'textureId': _textureId, 'path': path},
      );
      value = value.copyWith(isTakingPicture: false);
    } on PlatformException catch (e) {
      value = value.copyWith(isTakingPicture: false);
      throw CameraException(e.code, e.message.toString());
    }
  }

  /// Start streaming images from platform camera.
  ///
  /// Settings for capturing images on iOS and Android is set to always use the
  /// latest image available from the camera and will drop all other images.
  ///
  /// When running continuously with [CameraPreview] widget, this function runs
  /// best with [ResolutionPreset.low]. Running on [ResolutionPreset.high] can
  /// have significant frame rate drops for [CameraPreview] on lower end
  /// devices.
  ///
  /// Throws a [CameraException] if image streaming or video recording has
  /// already started.
  // TODO(bmparr): Add settings for resolution and fps.
  Future<void> startImageStream(onLatestImageAvailable onAvailable) async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController',
        'startImageStream was called on uninitialized CameraController.',
      );
    }
    if (value.isRecordingVideo) {
      throw CameraException(
        'A video recording is already started.',
        'startImageStream was called while a video is being recorded.',
      );
    }
    if (value.isStreamingVideoRtmp) {
      throw CameraException(
        'A video recording is already started.',
        'startImageStream was called while a video is being recorded.',
      );
    }
    if (value.isStreamingImages) {
      throw CameraException(
        'A camera has started streaming images.',
        'startImageStream was called while a camera was streaming images.',
      );
    }

    try {
      await _channel.invokeMethod<void>('startImageStream');
      value = value.copyWith(isStreamingImages: true);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message.toString());
    }
    const EventChannel cameraEventChannel =
        EventChannel('plugins.flutter.io/camera_with_rtmp/imageStream');
    _imageStreamSubscription =
        cameraEventChannel.receiveBroadcastStream().listen(
      (dynamic imageData) {
        onAvailable(CameraImage._fromPlatformData(imageData));
      },
    );
  }

  /// Stop streaming images from platform camera.
  ///
  /// Throws a [CameraException] if image streaming was not started or video
  /// recording was started.
  Future<void> stopImageStream() async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController',
        'stopImageStream was called on uninitialized CameraController.',
      );
    }
    if (!value.isStreamingImages) {
      throw CameraException(
        'No camera is streaming images',
        'stopImageStream was called when no camera is streaming images.',
      );
    }

    try {
      value = value.copyWith(isStreamingImages: false);
      await _channel.invokeMethod<void>('stopImageStream');
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message.toString());
    }

    await _imageStreamSubscription.cancel();
  }

  /// Get statistics about the rtmp stream.
  ///
  /// Throws a [CameraException] if image streaming was not started.
  Future<StreamStatistics> getStreamStatistics() async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController',
        'stopImageStream was called on uninitialized CameraController.',
      );
    }
    if (!value.isStreamingVideoRtmp) {
      throw CameraException(
        'No camera is streaming images',
        'stopImageStream was called when no camera is streaming images.',
      );
    }

    try {
      var data = await _channel
          .invokeMapMethod<String, dynamic>('getStreamStatistics');
      return StreamStatistics(
        sentAudioFrames:
            data!["sentAudioFrames"] != null ? data["sentAudioFrames"] : 0,
        sentVideoFrames:
            data["sentVideoFrames"] != null ? data["sentVideoFrames"] : 0,
        height: data["height"] != null ? data["height"] : 0,
        width: data["width"] != null ? data["width"] : 0,
        bitrate: data["bitrate"] != null ? data["bitrate"] : 0,
        isAudioMuted:
            data["isAudioMuted"] != null ? data["isAudioMuted"] : false,
        cacheSize: data["cacheSize"] != null ? data["cacheSize"] : 0,
        droppedAudioFrames:
            data["drpppedAudioFrames"] != null ? data["drpppedAudioFrames"] : 0,
        droppedVideoFrames:
            data["droppedVideoFrames"] != null ? data["droppedVideoFrames"] : 0,
      );
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message.toString());
    }
  }

  /// Start a video recording and save the file to [path].
  ///
  /// A path can for example be obtained using
  /// [path_provider](https://pub.dartlang.org/packages/path_provider).
  ///
  /// The file is written on the flight as the video is being recorded.
  /// If a file already exists at the provided path an error will be thrown.
  /// The file can be read as soon as [stopVideoRecording] returns.
  ///
  /// Throws a [CameraException] if the capture fails.
  Future<void> startVideoRecording(String filePath) async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController',
        'startVideoRecording was called on uninitialized CameraController',
      );
    }
    if (value.isRecordingVideo) {
      throw CameraException(
        'A video recording is already started.',
        'startVideoRecording was called when a recording is already started.',
      );
    }
    if (value.isStreamingImages) {
      throw CameraException(
        'A camera has started streaming images.',
        'startVideoRecording was called while a camera was streaming images.',
      );
    }

    try {
      await _channel.invokeMethod<void>(
        'startVideoRecording',
        <String, dynamic>{'textureId': _textureId, 'filePath': filePath},
      );
      value = value.copyWith(isRecordingVideo: true, isRecordingPaused: false);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message.toString());
    }
  }

  /// Stop recording.
  Future<void> stopVideoRecording() async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController',
        'stopVideoRecording was called on uninitialized CameraController',
      );
    }
    if (!value.isRecordingVideo) {
      throw CameraException(
        'No video is recording',
        'stopVideoRecording was called when no video is recording.',
      );
    }
    try {
      value =
          value.copyWith(isRecordingVideo: false, isStreamingVideoRtmp: false);
      await _channel.invokeMethod<void>(
        'stopRecordingOrStreaming',
        <String, dynamic>{'textureId': _textureId},
      );
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message.toString());
    }
  }

  /// Pause video recording.
  ///
  /// This feature is only available on iOS and Android sdk 24+.
  Future<void> pauseVideoRecording() async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController',
        'pauseVideoRecording was called on uninitialized CameraController',
      );
    }
    if (!value.isRecordingVideo) {
      throw CameraException(
        'No video is recording',
        'pauseVideoRecording was called when no video is recording.',
      );
    }
    try {
      value = value.copyWith(isRecordingPaused: true);
      await _channel.invokeMethod<void>(
        'pauseVideoRecording',
        <String, dynamic>{'textureId': _textureId},
      );
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message.toString());
    }
  }

  /// Resume video recording after pausing.
  ///
  /// This feature is only available on iOS and Android sdk 24+.
  Future<void> resumeVideoRecording() async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController',
        'resumeVideoRecording was called on uninitialized CameraController',
      );
    }
    if (!value.isRecordingVideo) {
      throw CameraException(
        'No video is recording',
        'resumeVideoRecording was called when no video is recording.',
      );
    }
    try {
      value = value.copyWith(isRecordingPaused: false);
      await _channel.invokeMethod<void>(
        'resumeVideoRecording',
        <String, dynamic>{'textureId': _textureId},
      );
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message.toString());
    }
  }

  /// Start a video streaming to the url in [url`].
  ///
  /// This uses rtmp to do the sending the remote side.
  ///
  /// Throws a [CameraException] if the capture fails.
  Future<void> startVideoRecordingAndStreaming(String filePath, String url,
      {int bitrate = 1200 * 1024, bool? androidUseOpenGL}) async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController',
        'startVideoStreaming was called on uninitialized CameraController',
      );
    }

    if (value.isRecordingVideo) {
      throw CameraException(
        'A video recording is already started.',
        'startVideoStreaming was called when a recording is already started.',
      );
    }
    if (value.isStreamingVideoRtmp) {
      throw CameraException(
        'A video streaming is already started.',
        'startVideoStreaming was called when a recording is already started.',
      );
    }
    if (value.isStreamingImages) {
      throw CameraException(
        'A camera has started streaming images.',
        'startVideoStreaming was called while a camera was streaming images.',
      );
    }

    // ignore: unnecessary_null_comparison
    if (filePath == null || url == null) {
      throw CameraException(
          "Null arguments",
          "URL $url and path $filePath need to be not null to start "
              "streaming and recording");
    }

    try {
      await _channel.invokeMethod<void>(
          'startVideoRecordingAndStreaming', <String, dynamic>{
        'textureId': _textureId,
        'url': url,
        'filePath': filePath,
        'bitrate': bitrate,
      });
      value =
          value.copyWith(isStreamingVideoRtmp: true, isStreamingPaused: false);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message.toString());
    }
  }

  /// Start a video streaming to the url in [url`].
  ///
  /// This uses rtmp to do the sending the remote side.
  ///
  /// Throws a [CameraException] if the capture fails.
  Future<void> startVideoStreaming(String url,
      {int bitrate = 1200 * 1024, bool? androidUseOpenGL}) async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController',
        'startVideoStreaming was called on uninitialized CameraController',
      );
    }
    if (value.isRecordingVideo) {
      throw CameraException(
        'A video recording is already started.',
        'startVideoStreaming was called when a recording is already started.',
      );
    }
    if (value.isStreamingVideoRtmp) {
      throw CameraException(
        'A video streaming is already started.',
        'startVideoStreaming was called when a recording is already started.',
      );
    }
    if (value.isStreamingImages) {
      throw CameraException(
        'A camera has started streaming images.',
        'startVideoStreaming was called while a camera was streaming images.',
      );
    }

    try {
      await _channel
          .invokeMethod<void>('startVideoStreaming', <String, dynamic>{
        'textureId': _textureId,
        'url': url,
        'bitrate': bitrate,
      });
      value =
          value.copyWith(isStreamingVideoRtmp: true, isStreamingPaused: false);
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message.toString());
    }
  }

  /// Stop streaming.
  Future<void> stopVideoStreaming() async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController',
        'stopVideoStreaming was called on uninitialized CameraController',
      );
    }
    if (!value.isStreamingVideoRtmp) {
      throw CameraException(
        'No video is recording',
        'stopVideoStreaming was called when no video is streaming.',
      );
    }
    try {
      value =
          value.copyWith(isStreamingVideoRtmp: false, isRecordingVideo: false);
      print("Stop video streaming call");
      await _channel.invokeMethod<void>(
        'stopRecordingOrStreaming',
        <String, dynamic>{'textureId': _textureId},
      );
    } on PlatformException catch (e) {
      print("GOt exception " + e.toString());
      throw CameraException(e.code, e.message.toString());
    }
  }

  /// Stop streaming.
  Future<void> stopEverything() async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController',
        'stopVideoStreaming was called on uninitialized CameraController',
      );
    }
    try {
      value = value.copyWith(isStreamingVideoRtmp: false);
      if (value.isRecordingVideo || value.isStreamingVideoRtmp) {
        value = value.copyWith(
            isRecordingVideo: false, isStreamingVideoRtmp: false);
        await _channel.invokeMethod<void>(
          'stopRecordingOrStreaming',
          <String, dynamic>{'textureId': _textureId},
        );
      }
      if (value.isStreamingImages) {
        value = value.copyWith(isStreamingImages: false);
        await _channel.invokeMethod<void>('stopImageStream');
      }
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message.toString());
    }
  }

  /// Pause video recording.
  ///
  /// This feature is only available on iOS and Android sdk 24+.
  Future<void> pauseVideoStreaming() async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController',
        'pauseVideoStreaming was called on uninitialized CameraController',
      );
    }
    if (!value.isStreamingVideoRtmp) {
      throw CameraException(
        'No video is recording',
        'pauseVideoStreaming was called when no video is streaming.',
      );
    }
    try {
      value = value.copyWith(isStreamingPaused: true);
      await _channel.invokeMethod<void>(
        'pauseVideoStreaming',
        <String, dynamic>{'textureId': _textureId},
      );
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message.toString());
    }
  }

  /// Resume video streaming after pausing.
  ///
  /// This feature is only available on iOS and Android sdk 24+.
  Future<void> resumeVideoStreaming() async {
    if (!value.isInitialized || _isDisposed) {
      throw CameraException(
        'Uninitialized CameraController',
        'resumeVideoStreaming was called on uninitialized CameraController',
      );
    }
    if (!value.isStreamingVideoRtmp) {
      throw CameraException(
        'No video is recording',
        'resumeVideoStreaming was called when no video is streaming.',
      );
    }
    try {
      value = value.copyWith(isStreamingPaused: false);
      await _channel.invokeMethod<void>(
        'resumeVideoStreaming',
        <String, dynamic>{'textureId': _textureId},
      );
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message.toString());
    }
  }

  /// Releases the resources of this camera.
  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    super.dispose();
    // ignore: unnecessary_null_comparison
    if (_creatingCompleter != null) {
      await _creatingCompleter.future;
      await _channel.invokeMethod<void>(
        'dispose',
        <String, dynamic>{'textureId': _textureId},
      );
      await _eventSubscription.cancel();
    }
  }
}
