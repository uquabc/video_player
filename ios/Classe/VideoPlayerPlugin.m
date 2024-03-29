// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "VideoPlayerPlugin.h"
#import <AVFoundation/AVFoundation.h>
#import <GLKit/GLKit.h>
#import "VideoPlayerPluginManager.h"
#import "ZBLM3u8FileManager.h"
#import "ZBLM3u8Manager.h"

static NSString* const METHOD_CHANGE_ORIENTATION = @"change_screen_orientation";
static NSString* const ORIENTATION_PORTRAIT_UP = @"portraitUp";
static NSString* const ORIENTATION_PORTRAIT_DOWN = @"portraitDown";
static NSString* const ORIENTATION_LANDSCAPE_LEFT = @"landscapeLeft";
static NSString* const ORIENTATION_LANDSCAPE_RIGHT = @"landscapeRight";

int64_t FLTCMTimeToMillis(CMTime time) {
  if (time.timescale == 0) return 0;
  return time.value * 1000 / time.timescale;
}

@interface FLTFrameUpdater : NSObject
@property(nonatomic) int64_t textureId;
@property(nonatomic, readonly) NSObject<FlutterTextureRegistry>* registry;
- (void)onDisplayLink:(CADisplayLink*)link;
@end

@implementation FLTFrameUpdater
- (FLTFrameUpdater*)initWithRegistry:(NSObject<FlutterTextureRegistry>*)registry {
  NSAssert(self, @"super init cannot be nil");
  if (self == nil) return nil;
  _registry = registry;
  return self;
}

- (void)onDisplayLink:(CADisplayLink*)link {
  [_registry textureFrameAvailable:_textureId];
}

@end

@interface FLTVideoPlayer : NSObject <FlutterTexture, FlutterStreamHandler,ZBLM3u8ManagerDownloadDelegate>
@property(readonly, nonatomic) AVPlayer* player;
@property(readonly, nonatomic) AVPlayerItemVideoOutput* videoOutput;
@property(readonly, nonatomic) CADisplayLink* displayLink;
@property (nonatomic, strong) VideoPlayerPluginManager * playerManager;
@property(nonatomic) FlutterEventChannel* eventChannel;
@property(nonatomic) FlutterEventSink eventSink;
@property(nonatomic) CGAffineTransform preferredTransform;
@property(nonatomic, readonly) bool disposed;
@property(nonatomic, readonly) bool isPlaying;
@property(nonatomic) bool isLooping;
@property(nonatomic, readonly) bool isInitialized;
- (instancetype)initWithURL:(NSURL*)url frameUpdater:(FLTFrameUpdater*)frameUpdater;
- (void)play;
- (void)pause;
- (void)setIsLooping:(bool)isLooping;
- (void)updatePlayingState;
@end

static void* timeRangeContext = &timeRangeContext;
static void* statusContext = &statusContext;
static void* playbackLikelyToKeepUpContext = &playbackLikelyToKeepUpContext;
static void* playbackBufferEmptyContext = &playbackBufferEmptyContext;
static void* playbackBufferFullContext = &playbackBufferFullContext;

@implementation FLTVideoPlayer
- (instancetype)initWithAsset:(NSString*)asset frameUpdater:(FLTFrameUpdater*)frameUpdater {
  NSString* path = [[NSBundle mainBundle] pathForResource:asset ofType:nil];
  return [self initWithURL:[NSURL fileURLWithPath:path] frameUpdater:frameUpdater];
}

- (void)addObservers:(AVPlayerItem*)item {
  [item addObserver:self
         forKeyPath:@"loadedTimeRanges"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:timeRangeContext];
  [item addObserver:self
         forKeyPath:@"status"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:statusContext];
  [item addObserver:self
         forKeyPath:@"playbackLikelyToKeepUp"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackLikelyToKeepUpContext];
  [item addObserver:self
         forKeyPath:@"playbackBufferEmpty"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackBufferEmptyContext];
  [item addObserver:self
         forKeyPath:@"playbackBufferFull"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackBufferFullContext];

  // Add an observer that will respond to itemDidPlayToEndTime
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(itemDidPlayToEndTime:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:item];
}

- (void)itemDidPlayToEndTime:(NSNotification*)notification {
  if (_isLooping) {
    AVPlayerItem* p = [notification object];
    [p seekToTime:kCMTimeZero completionHandler:nil];
  } else {
    if (_eventSink) {
      _eventSink(@{@"event" : @"completed"});
    }
  }
}

static inline CGFloat radiansToDegrees(CGFloat radians) {
  // Input range [-pi, pi] or [-180, 180]
  CGFloat degrees = GLKMathRadiansToDegrees((float)radians);
  if (degrees < 0) {
    // Convert -90 to 270 and -180 to 180
    return degrees + 360;
  }
  // Output degrees in between [0, 360[
  return degrees;
};

- (AVMutableVideoComposition*)getVideoCompositionWithTransform:(CGAffineTransform)transform
                                                     withAsset:(AVAsset*)asset
                                                withVideoTrack:(AVAssetTrack*)videoTrack {
  AVMutableVideoCompositionInstruction* instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
  instruction.timeRange = CMTimeRangeMake(kCMTimeZero, [asset duration]);
  AVMutableVideoCompositionLayerInstruction* layerInstruction =
      [AVMutableVideoCompositionLayerInstruction
          videoCompositionLayerInstructionWithAssetTrack:videoTrack];
  [layerInstruction setTransform:_preferredTransform atTime:kCMTimeZero];

  AVMutableVideoComposition* videoComposition = [AVMutableVideoComposition videoComposition];
  instruction.layerInstructions = @[ layerInstruction ];
  videoComposition.instructions = @[ instruction ];

  // If in portrait mode, switch the width and height of the video
  CGFloat width = videoTrack.naturalSize.width;
  CGFloat height = videoTrack.naturalSize.height;
  NSInteger rotationDegrees =
      (NSInteger)round(radiansToDegrees(atan2(_preferredTransform.b, _preferredTransform.a)));
  if (rotationDegrees == 90 || rotationDegrees == 270) {
    width = videoTrack.naturalSize.height;
    height = videoTrack.naturalSize.width;
  }
  videoComposition.renderSize = CGSizeMake(width, height);

  // TODO(@recastrodiaz): should we use videoTrack.nominalFrameRate ?
  // Currently set at a constant 30 FPS
  videoComposition.frameDuration = CMTimeMake(1, 30);

  return videoComposition;
}

- (void)createVideoOutputAndDisplayLink:(FLTFrameUpdater*)frameUpdater {
  NSDictionary* pixBuffAttributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
  };
  _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixBuffAttributes];

  _displayLink = [CADisplayLink displayLinkWithTarget:frameUpdater
                                             selector:@selector(onDisplayLink:)];
  [_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
  _displayLink.paused = YES;
}

- (instancetype)initWithURL:(NSURL*)url frameUpdater:(FLTFrameUpdater*)frameUpdater {
//  AVPlayerItem* item = [AVPlayerItem playerItemWithURL:url];
    NSString * urlStr = url.absoluteString;//@"http://vedio-pro.iwordnet.com/bf42c73349f74ad8b3a6b760739ef32c/451287bd3e8645868e6de273d05676cc.m3u8";
    _playerManager = [[VideoPlayerPluginManager alloc] initWithOriginPlayerUrl:urlStr];
    NSString * cacheUrlStr = [ZBLM3u8FileManager exitCacheTemporaryWithUrl:_playerManager.resolutionDownloadUrlArray];
    if (![cacheUrlStr isEqualToString:@""]) {
        ///已缓存对应文件
        urlStr = [[ZBLM3u8Manager shareInstance] localPlayUrlWithOriUrlString:cacheUrlStr];
        //开启本地服务器
        [[ZBLM3u8Manager shareInstance] tryStartLocalService];
        [self sendDownloadState:COMPLETED progress:0];
//        NSLog(@">>>>>>>>>>>本地视频已经缓存");
    } else {
        [[ZBLM3u8Manager shareInstance] tryStopLocalService];
        [self sendDownloadState:UNDOWNLOAD progress:0];
    }
    AVPlayerItem* item = [AVPlayerItem playerItemWithURL:[NSURL URLWithString:urlStr]];
    
  return [self initWithUrl:url.absoluteString PlayerItem:item frameUpdater:frameUpdater];
}

- (CGAffineTransform)fixTransform:(AVAssetTrack*)videoTrack {
  CGAffineTransform transform = videoTrack.preferredTransform;
  // TODO(@recastrodiaz): why do we need to do this? Why is the preferredTransform incorrect?
  // At least 2 user videos show a black screen when in portrait mode if we directly use the
  // videoTrack.preferredTransform Setting tx to the height of the video instead of 0, properly
  // displays the video https://github.com/flutter/flutter/issues/17606#issuecomment-413473181
  if (transform.tx == 0 && transform.ty == 0) {
    NSInteger rotationDegrees = (NSInteger)round(radiansToDegrees(atan2(transform.b, transform.a)));
    NSLog(@"TX and TY are 0. Rotation: %ld. Natural width,height: %f, %f", (long)rotationDegrees,
          videoTrack.naturalSize.width, videoTrack.naturalSize.height);
    if (rotationDegrees == 90) {
      NSLog(@"Setting transform tx");
      transform.tx = videoTrack.naturalSize.height;
      transform.ty = 0;
    } else if (rotationDegrees == 270) {
      NSLog(@"Setting transform ty");
      transform.tx = 0;
      transform.ty = videoTrack.naturalSize.width;
    }
  }
  return transform;
}

- (instancetype)initWithUrl:(NSString *)urlStr PlayerItem:(AVPlayerItem*)item frameUpdater:(FLTFrameUpdater*)frameUpdater {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _isInitialized = false;
  _isPlaying = false;
  _disposed = false;

  AVAsset* asset = [item asset];
  void (^assetCompletionHandler)(void) = ^{
    if ([asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
      NSArray* tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
      if ([tracks count] > 0) {
        AVAssetTrack* videoTrack = tracks[0];
        void (^trackCompletionHandler)(void) = ^{
          if (self->_disposed) return;
          if ([videoTrack statusOfValueForKey:@"preferredTransform"
                                        error:nil] == AVKeyValueStatusLoaded) {
            // Rotate the video by using a videoComposition and the preferredTransform
            self->_preferredTransform = [self fixTransform:videoTrack];
            // Note:
            // https://developer.apple.com/documentation/avfoundation/avplayeritem/1388818-videocomposition
            // Video composition can only be used with file-based media and is not supported for
            // use with media served using HTTP Live Streaming.
            AVMutableVideoComposition* videoComposition =
                [self getVideoCompositionWithTransform:self->_preferredTransform
                                             withAsset:asset
                                        withVideoTrack:videoTrack];
            item.videoComposition = videoComposition;
          }
        };
        [videoTrack loadValuesAsynchronouslyForKeys:@[ @"preferredTransform" ]
                                  completionHandler:trackCompletionHandler];
      }
    }
  };
  _player = [AVPlayer playerWithPlayerItem:item];
  _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

  [self createVideoOutputAndDisplayLink:frameUpdater];

  [self addObservers:item];

  [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:assetCompletionHandler];

  return self;
}

- (void)observeValueForKeyPath:(NSString*)path
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {
    
  if (context == timeRangeContext) {
    if (_eventSink != nil) {
      NSMutableArray<NSArray<NSNumber*>*>* values = [[NSMutableArray alloc] init];
      for (NSValue* rangeValue in [object loadedTimeRanges]) {
        CMTimeRange range = [rangeValue CMTimeRangeValue];
        int64_t start = FLTCMTimeToMillis(range.start);
        [values addObject:@[ @(start), @(start + FLTCMTimeToMillis(range.duration)) ]];
      }
      _eventSink(@{@"event" : @"bufferingUpdate", @"values" : values});
    }
      if (@available(iOS 11.0, *)) {
          CGFloat videoWidth = 0.0;
          if (self.player.currentItem.preferredMaximumResolution.width == 0) {
              videoWidth = self.player.currentItem.presentationSize.width;
          } else {
              videoWidth = self.player.currentItem.preferredMaximumResolution.width;
          }
          [self sendResolutionChange:[_playerManager getVideoPlayerResulotionTrackIndex:videoWidth]];
//          NSLog(@"11111>>>>>>>>>>>>>>>>%f     >>>>>>>>>>>%f",self.player.currentItem.presentationSize.width,self.player.currentItem.preferredMaximumResolution.width);
      } else {
          // Fallback on earlier versions
      }
  } else if (context == statusContext) {
    AVPlayerItem* item = (AVPlayerItem*)object;
    switch (item.status) {
      case AVPlayerItemStatusFailed:
        if (_eventSink != nil) {
            [self sendVideoError];
        }
        break;
      case AVPlayerItemStatusUnknown:
          [self sendPlayStateChanged:false];
        break;
      case AVPlayerItemStatusReadyToPlay:
        [item addOutput:_videoOutput];
        [self sendInitialized];
        [self updatePlayingState];
        break;
    }
  } else if (context == playbackLikelyToKeepUpContext) {
    if ([[_player currentItem] isPlaybackLikelyToKeepUp]) {
      [self updatePlayingState];
      if (_eventSink != nil) {
        _eventSink(@{@"event" : @"bufferingEnd"});
      }
    }
  } else if (context == playbackBufferEmptyContext) {
    if (_eventSink != nil) {
      _eventSink(@{@"event" : @"bufferingStart"});
    }
  } else if (context == playbackBufferFullContext) {
    if (_eventSink != nil) {
      _eventSink(@{@"event" : @"bufferingEnd"});
    }
  }
}

- (void)updatePlayingState {
  if (!_isInitialized) {
    return;
  }
  if (_isPlaying) {
    [self sendPlayStateChanged:true];
      CGFloat progress = CMTimeGetSeconds(_player.currentItem.currentTime) / CMTimeGetSeconds(_player.currentItem.duration);
      if (progress >= 1.0) {
          ///修改当视频播放完成，再次点击播放按钮需要重新开始播放
          [self seekTo:0];
      }
    [_player play];
  } else {
    [self sendPlayStateChanged:false];
    [_player pause];
  }
  _displayLink.paused = !_isPlaying;
}

- (void)sendVideoError {
    NSString * cacheUrlStr = [ZBLM3u8FileManager exitCacheTemporaryWithUrl:_playerManager.resolutionDownloadUrlArray];
    if ([cacheUrlStr isEqualToString:@""]) {
        if (_eventSink != nil) {
            [self sendPlayStateChanged:false];
            _eventSink([FlutterError
                        errorWithCode:@"VideoError"
                        message:@"Failed to load video: "
                        details:nil]);
        }
    }
}

- (void)sendPlayStateChanged:(BOOL)isPlaying {
    if (_eventSink != nil) {
        _eventSink(@{@"event" : @"playStateChanged",
                     @"isPlaying":[NSNumber numberWithBool:isPlaying]
                     });
    }
    if (isPlaying) {
        [self sendResolutions:[_playerManager getVideoResulotions]];
    }
}

- (void)sendResolutions:(NSDictionary *)dic {
    if (_eventSink != nil) {
        _eventSink(@{@"event":@"resolutions",
                     @"map":dic});
    }
}

- (void)sendResolutionChange:(NSInteger)trackIndex {
    if (_eventSink != nil) {
        _eventSink(@{@"event":@"resolutionChange",
                     @"index":[NSNumber numberWithInteger:trackIndex]});
    }
}

- (void)switchResolution:(int)trackIndex {
    if (@available(iOS 11.0, *)) {
        NSArray * array = [_playerManager getSwithResolution:trackIndex];
        if (array.count != 0) {
            CGSize size = CGSizeMake([array[0] floatValue], [array[1] floatValue]);
            [self.player.currentItem setPreferredMaximumResolution:size];
        }
    } else {
        NSArray * array = [_playerManager getSwithResolution:trackIndex];
        if (array.count != 0) {
            CGSize size = CGSizeMake([array[0] floatValue], [array[1] floatValue]);
            [self sendResolutionChange:[_playerManager getVideoPlayerResulotionTrackIndex:size.width]];
        }
    }
}

- (void)sendDownloadState:(GpDownloadState)videoDownloadState progress:(float)downloadPregress {
    if (_eventSink != nil) {
        NSMutableDictionary * dic = [[NSMutableDictionary alloc] init];
        [dic setObject:@"downloadState" forKey:@"event"];
        [dic setObject:[NSNumber numberWithInteger:videoDownloadState] forKey:@"state"];
        if (videoDownloadState == DOWNLOADING) {
            [dic setObject:[NSNumber numberWithFloat:downloadPregress] forKey:@"progress"];
        }
        _eventSink(dic);
    }
}

- (void)download:(int)trackIndex name:(NSString *)name {
    NSString * downloadUrl = [_playerManager getDownloadUrl:trackIndex];
    if (![downloadUrl isEqualToString:@""]) {
        ///开始下载
        [ZBLM3u8Manager shareInstance].delegate = self;
        [[ZBLM3u8Manager shareInstance] startDownloadUrl:downloadUrl];
    }
}

- (void)removeAllVideoCache {
    ///删除本地缓存
    [_playerManager removeVideoAllCache];
    [self sendDownloadState:UNDOWNLOAD progress:0];
    if (@available(iOS 11.0, *)) {
        
    } else {
        [[_player currentItem] removeObserver:self forKeyPath:@"status" context:statusContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"loadedTimeRanges"
                                      context:timeRangeContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"playbackLikelyToKeepUp"
                                      context:playbackLikelyToKeepUpContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"playbackBufferEmpty"
                                      context:playbackBufferEmptyContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"playbackBufferFull"
                                      context:playbackBufferFullContext];
        [_player replaceCurrentItemWithPlayerItem:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
    if (_playerManager.isPlayingCacheVideoUrl) {
        ///当前正在播放本地视频
        NSString * playValue = [NSString stringWithFormat:@"%.0f",CMTimeGetSeconds(self.player.currentItem.currentTime)];
        ///关闭本地服务器
        [[ZBLM3u8Manager shareInstance] tryStopLocalService];
        ///通知UI当前视频未缓存
        ///切换视频源
        @try {
            AVPlayerItem* item = [AVPlayerItem playerItemWithURL:[NSURL URLWithString:_playerManager.playerUrl]];
            [_player replaceCurrentItemWithPlayerItem:item];
            //代码中分母为1000，因此，分子*1000
            [self seekTo:[playValue intValue] * 1000];
            [self addObservers:item];
        } @catch (NSException *exception) {
            NSLog(@">>>>>exception:%@",exception);
        } @finally {
            
        }
    } else {
        [self sendResolutions:[_playerManager getVideoResulotions]];
    }
}

#pragma mark - downloadVideo delegate
- (void)m3u8DownloadSuccess:(NSString *)normalDownloadUrl {
    if ([_playerManager containsDownloadUrl:normalDownloadUrl]) {
        [self sendDownloadState:COMPLETED progress:0];
        [_playerManager downloadSuccessAndDeleteDifferentResolutionCaches:_playerManager.resolutionDownloadUrlArray];
    }
}

- (void)m3u8DownloadFailed:(NSString *)normalDownloadUrl error:(NSError *)error {
    if ([_playerManager containsDownloadUrl:normalDownloadUrl]) {
        [self sendDownloadState:ERROR progress:0];
    }
}

- (void)m3u8Downloading:(NSString *)normalDownloadUrl progress:(float)progress {
    if ([_playerManager containsDownloadUrl:normalDownloadUrl]) {
        [self sendDownloadState:DOWNLOADING progress:progress * 100.0];
    }
}

- (void)sendInitialized {
  if (_eventSink && !_isInitialized) {
      NSString * cacheUrlStr = [ZBLM3u8FileManager exitCacheTemporaryWithUrl:_playerManager.resolutionDownloadUrlArray];
      if (![cacheUrlStr isEqualToString:@""]) {
          ///已缓存对应文件
          [self sendDownloadState:COMPLETED progress:0];
      } else if ([[ZBLM3u8Manager shareInstance] downloadingUrl:_playerManager.resolutionDownloadUrlArray]) {
          ///内存中存在这个视频，但是没有下载成功
//          NSLog(@">>>>>>>>>>当前视频正在下载中");
          [ZBLM3u8Manager shareInstance].delegate = self;
      } else {
          [self sendDownloadState:UNDOWNLOAD progress:0];
      }
    CGSize size = [self.player currentItem].presentationSize;
    CGFloat width = size.width;
    CGFloat height = size.height;
    // The player has not yet initialized.
    if (height == CGSizeZero.height && width == CGSizeZero.width) {
      return;
    }
    // The player may be initialized but still needs to determine the duration.
    if ([self duration] == 0) {
      return;
    }

    _isInitialized = true;
    _eventSink(@{
      @"event" : @"initialized",
      @"duration" : @([self duration]),
      @"width" : @(width),
      @"height" : @(height)
    });
  }
}

- (void)play {
  _isPlaying = true;
  [self updatePlayingState];
}

- (void)pause {
  _isPlaying = false;
  [self updatePlayingState];
}

- (void)setRote:(float)rote {
    [_player setRate:rote];
}

- (int64_t)position {
  return FLTCMTimeToMillis([_player currentTime]);
}

- (int64_t)duration {
  return FLTCMTimeToMillis([[_player currentItem] duration]);
}

- (void)seekTo:(int)location {
  [_player seekToTime:CMTimeMake(location, 1000)
      toleranceBefore:kCMTimeZero
       toleranceAfter:kCMTimeZero];
}

- (void)setIsLooping:(bool)isLooping {
  _isLooping = isLooping;
}

- (void)setVolume:(double)volume {
  _player.volume = (float)((volume < 0.0) ? 0.0 : ((volume > 1.0) ? 1.0 : volume));
}

- (CVPixelBufferRef)copyPixelBuffer {
  CMTime outputItemTime = [_videoOutput itemTimeForHostTime:CACurrentMediaTime()];
  if ([_videoOutput hasNewPixelBufferForItemTime:outputItemTime]) {
    return [_videoOutput copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL];
  } else {
    return NULL;
  }
}

- (FlutterError* _Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  return nil;
}

- (FlutterError* _Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
  _eventSink = events;
  // TODO(@recastrodiaz): remove the line below when the race condition is resolved:
  // https://github.com/flutter/flutter/issues/21483
  // This line ensures the 'initialized' event is sent when the event
  // 'AVPlayerItemStatusReadyToPlay' fires before _eventSink is set (this function
  // onListenWithArguments is called)
  [self sendInitialized];
  return nil;
}

- (void)dispose {
  _disposed = true;
  [_displayLink invalidate];
  [[_player currentItem] removeObserver:self forKeyPath:@"status" context:statusContext];
  [[_player currentItem] removeObserver:self
                             forKeyPath:@"loadedTimeRanges"
                                context:timeRangeContext];
  [[_player currentItem] removeObserver:self
                             forKeyPath:@"playbackLikelyToKeepUp"
                                context:playbackLikelyToKeepUpContext];
  [[_player currentItem] removeObserver:self
                             forKeyPath:@"playbackBufferEmpty"
                                context:playbackBufferEmptyContext];
  [[_player currentItem] removeObserver:self
                             forKeyPath:@"playbackBufferFull"
                                context:playbackBufferFullContext];
  [_player replaceCurrentItemWithPlayerItem:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_eventChannel setStreamHandler:nil];
}

@end

@interface FLTVideoPlayerPlugin ()
@property(readonly, nonatomic) NSObject<FlutterTextureRegistry>* registry;
@property(readonly, nonatomic) NSObject<FlutterBinaryMessenger>* messenger;
@property(readonly, nonatomic) NSMutableDictionary* players;
@property(readonly, nonatomic) NSObject<FlutterPluginRegistrar>* registrar;

@end

@implementation FLTVideoPlayerPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel =
      [FlutterMethodChannel methodChannelWithName:@"flutter.io/videoPlayer"
                                  binaryMessenger:[registrar messenger]];
  FLTVideoPlayerPlugin* instance = [[FLTVideoPlayerPlugin alloc] initWithRegistrar:registrar];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _registry = [registrar textures];
  _messenger = [registrar messenger];
  _registrar = registrar;
  _players = [NSMutableDictionary dictionaryWithCapacity:1];
  return self;
}

- (void)onPlayerSetup:(FLTVideoPlayer*)player
         frameUpdater:(FLTFrameUpdater*)frameUpdater
               result:(FlutterResult)result {
  int64_t textureId = [_registry registerTexture:player];
  frameUpdater.textureId = textureId;
  FlutterEventChannel* eventChannel = [FlutterEventChannel
      eventChannelWithName:[NSString stringWithFormat:@"flutter.io/videoPlayer/videoEvents%lld",
                                                      textureId]
           binaryMessenger:_messenger];
  [eventChannel setStreamHandler:player];
  player.eventChannel = eventChannel;
  _players[@(textureId)] = player;
  result(@{@"textureId" : @(textureId)});
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([@"init" isEqualToString:call.method]) {
    // Allow audio playback when the Ring/Silent switch is set to silent
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];

    for (NSNumber* textureId in _players) {
      [_registry unregisterTexture:[textureId unsignedIntegerValue]];
      [_players[textureId] dispose];
    }
    [_players removeAllObjects];
    result(nil);
  } else if ([@"create" isEqualToString:call.method]) {
    NSDictionary* argsMap = call.arguments;
    FLTFrameUpdater* frameUpdater = [[FLTFrameUpdater alloc] initWithRegistry:_registry];
    NSString* assetArg = argsMap[@"asset"];
    NSString* uriArg = argsMap[@"uri"];
    FLTVideoPlayer* player;
    if (assetArg) {
      NSString* assetPath;
      NSString* package = argsMap[@"package"];
      if (![package isEqual:[NSNull null]]) {
        assetPath = [_registrar lookupKeyForAsset:assetArg fromPackage:package];
      } else {
        assetPath = [_registrar lookupKeyForAsset:assetArg];
      }
      player = [[FLTVideoPlayer alloc] initWithAsset:assetPath frameUpdater:frameUpdater];
      [self onPlayerSetup:player frameUpdater:frameUpdater result:result];
    } else if (uriArg) {
      player = [[FLTVideoPlayer alloc] initWithURL:[NSURL URLWithString:uriArg]
                                      frameUpdater:frameUpdater];
      [self onPlayerSetup:player frameUpdater:frameUpdater result:result];
    } else {
      result(FlutterMethodNotImplemented);
    }

  }else if ([METHOD_CHANGE_ORIENTATION isEqualToString:call.method]) {
      NSArray *arguments = call.arguments;
      NSString *orientation = arguments[0];
      bool isLandscape = NO;
      NSInteger iOSOrientation;
      if ([orientation isEqualToString:ORIENTATION_LANDSCAPE_LEFT]){
          iOSOrientation = UIDeviceOrientationLandscapeLeft;
          isLandscape = YES;
      }else if([orientation isEqualToString:ORIENTATION_LANDSCAPE_RIGHT]){
          iOSOrientation = UIDeviceOrientationLandscapeRight;
          isLandscape = YES;
      }else if ([orientation isEqualToString:ORIENTATION_PORTRAIT_DOWN]){
          iOSOrientation = UIDeviceOrientationPortraitUpsideDown;
          isLandscape = NO;
      }else{
          iOSOrientation = UIDeviceOrientationPortrait;
          isLandscape = NO;
      }
      [[NSUserDefaults standardUserDefaults] setBool:isLandscape forKey:@"videoPlayerPlugin_isLandscape"];
      [[NSUserDefaults standardUserDefaults] synchronize];
      [[UIDevice currentDevice] setValue:@(iOSOrientation) forKey:@"orientation"];
      result(nil);
      
  } else {
    NSDictionary* argsMap = call.arguments;
    int64_t textureId = ((NSNumber*)argsMap[@"textureId"]).unsignedIntegerValue;
    FLTVideoPlayer* player = _players[@(textureId)];
    if ([@"dispose" isEqualToString:call.method]) {
      [_registry unregisterTexture:textureId];
      [_players removeObjectForKey:@(textureId)];
      [player dispose];
      result(nil);
    } else if ([@"setLooping" isEqualToString:call.method]) {
      [player setIsLooping:[argsMap[@"looping"] boolValue]];
      result(nil);
    } else if ([@"setVolume" isEqualToString:call.method]) {
      [player setVolume:[argsMap[@"volume"] doubleValue]];
      result(nil);
    } else if ([@"play" isEqualToString:call.method]) {
      [player play];
      result(nil);
    } else if ([@"position" isEqualToString:call.method]) {
      result(@([player position]));
    } else if ([@"seekTo" isEqualToString:call.method]) {
      [player seekTo:[argsMap[@"location"] intValue]];
      result(nil);
    } else if ([@"pause" isEqualToString:call.method]) {
      [player pause];
      result(nil);
    } else if ([@"setSpeed" isEqualToString:call.method]) {
        [player setRote:[argsMap[@"speed"] floatValue]];
    } else if ([@"switchResolutions" isEqualToString:call.method]) {
        NSNumber * trackIndex = (NSNumber *)call.arguments[@"trackIndex"];
        [player switchResolution:[trackIndex intValue]];
        result(nil);
    } else if ([@"download" isEqualToString:call.method]) {
        NSNumber * trackIndex = (NSNumber *)call.arguments[@"trackIndex"];
        NSString * name = call.arguments[@"name"];
        [player download:[trackIndex intValue] name:name];
        result(nil);
    } else if ([@"removeDownload" isEqualToString:call.method]) {
        [player removeAllVideoCache];
        result(nil);
    } else {
        result(FlutterMethodNotImplemented);
    }
  }
}

@end
