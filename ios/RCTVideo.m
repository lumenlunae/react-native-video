#import <React/RCTConvert.h>
#import "RCTVideo.h"
#import <React/RCTBridgeModule.h>
#import <React/RCTEventDispatcher.h>
#import <React/UIView+React.h>

static NSString *const statusKeyPath = @"status";
static NSString *const playbackLikelyToKeepUpKeyPath = @"playbackLikelyToKeepUp";
static NSString *const playbackBufferEmptyKeyPath = @"playbackBufferEmpty";
static NSString *const readyForDisplayKeyPath = @"readyForDisplay";
static NSString *const playbackRate = @"rate";
static NSString *const timedMetadata = @"timedMetadata";

@implementation RCTVideo
{
  AVPlayer *_player;
  int _playingClipIndex;
  NSMutableArray *_clipAssets;
  NSMutableArray *_clipEndOffsets;
  NSMutableArray *_clipDurations;
  AVPlayerItem *_playerItem;
  BOOL _playerItemObserversSet;
  BOOL _playerBufferEmpty;
  AVPlayerLayer *_playerLayer;
  AVPlayerViewController *_playerViewController;
  NSURL *_videoURL;
  dispatch_queue_t _queue;
  NSArray *_pendingSource;
  BOOL _preparationInProgress;
  
  
  /* This is used to prevent the async initialization of the player from proceeding
   * when removeFromSuperview has already been called. Under certain circumstances,
   * this caused audio playback to continue in the background after the view was
   * unmounted. */
  BOOL _removed;
  
  /* To buffer multiple videos (AVMutableComposition doesn't do this properly).
   * See the comments below the Buffering pragma mark for more details. */
  BOOL _bufferingStarted;
  NSTimer *_bufferingTimer;
  AVPlayer *_bufferingPlayerA;
  AVPlayer *_bufferingPlayerB;
  AVPlayer *_mainBufferingPlayer;
  AVPlayerItem *_bufferingPlayerItemA;
  AVPlayerItem *_bufferingPlayerItemB;
  NSNumber *_currentlyBufferingIndexA;
  NSNumber *_currentlyBufferingIndexB;
  NSNumber *_nextIndexToBuffer;
  NSMutableArray *_bufferedClipIndexes;
  BOOL _pausedForBuffering;

  /* Required to publish events */
  RCTEventDispatcher *_eventDispatcher;
  BOOL _playbackRateObserverRegistered;

  bool _pendingSeek;
  float _pendingSeekTime;
  float _lastSeekTime;

  /* For sending videoProgress events */
  Float64 _progressUpdateInterval;
  BOOL _controls;
  id _timeObserver;

  /* Keep track of any modifiers, need to be applied after each play */
  float _volume;
  float _rate;
  BOOL _muted;
  BOOL _paused;
  BOOL _repeat;
  BOOL _shouldBuffer;
  BOOL _playbackStalled;
  BOOL _playInBackground;
  BOOL _playWhenInactive;
  NSString * _ignoreSilentSwitch;
  NSString * _resizeMode;
  BOOL _fullscreenPlayerPresented;
  UIViewController * _presentingViewController;
}

- (instancetype)initWithEventDispatcher:(RCTEventDispatcher *)eventDispatcher
{
  if ((self = [super init])) {
    _eventDispatcher = eventDispatcher;

    _playbackRateObserverRegistered = NO;
    _playbackStalled = NO;
    _rate = 1.0;
    _volume = 1.0;
    _preparationInProgress = NO;
    _bufferingStarted = NO;
    _resizeMode = @"AVLayerVideoGravityResizeAspectFill";
    _pendingSeek = false;
    _pendingSeekTime = 0.0f;
    _lastSeekTime = 0.0f;
    _progressUpdateInterval = 250;
    _controls = NO;
    _pausedForBuffering = NO;
    _removed = NO;
    _playerBufferEmpty = YES;
    _playInBackground = false;
    _playWhenInactive = false;
    _ignoreSilentSwitch = @"inherit"; // inherit, ignore, obey

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
  }

  return self;
}

- (AVPlayerViewController*)createPlayerViewController:(AVPlayer*)player withPlayerItem:(AVPlayerItem*)playerItem {
    RCTVideoPlayerViewController* playerLayer= [[RCTVideoPlayerViewController alloc] init];
    playerLayer.showsPlaybackControls = NO;
    playerLayer.rctDelegate = self;
    playerLayer.view.frame = self.bounds;
    playerLayer.player = _player;
    playerLayer.view.frame = self.bounds;
    return playerLayer;
}

/* ---------------------------------------------------------
 **  Get the duration for a AVPlayerItem.
 ** ------------------------------------------------------- */

- (CMTime)playerItemDuration
{
    AVPlayerItem *playerItem = [_player currentItem];
    if (playerItem.status == AVPlayerItemStatusReadyToPlay)
    {
        return([playerItem duration]);
    }

    return(kCMTimeInvalid);
}

- (CMTime)otherPlayerItemDuration:(AVPlayer *)player
{
    AVPlayerItem *playerItem = [player currentItem];
    if (playerItem.status == AVPlayerItemStatusReadyToPlay)
    {
        return([playerItem duration]);
    }
    
    return(kCMTimeInvalid);
}

- (CMTimeRange)playerItemSeekableTimeRange
{
    AVPlayerItem *playerItem = [_player currentItem];
    if (playerItem.status == AVPlayerItemStatusReadyToPlay)
    {
        return [playerItem seekableTimeRanges].firstObject.CMTimeRangeValue;
    }

    return (kCMTimeRangeZero);
}


/* Cancels the previously registered time observer. */
-(void)removePlayerTimeObserver
{
    if (_timeObserver)
    {
        [_player removeTimeObserver:_timeObserver];
        _timeObserver = nil;
    }
}

/* Cancels the previously registered buffering progress observer */
-(void)removebufferingTimer
{
  if (_bufferingTimer) {
    [_bufferingTimer invalidate];
    _bufferingTimer = nil;
    _bufferingStarted = NO;
  }
}

#pragma mark - Progress

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self removePlayerLayer];
  [self removePlayerItemObservers];
  [_player removeObserver:self forKeyPath:playbackRate context:nil];
}

#pragma mark - App lifecycle handlers

- (void)applicationWillResignActive:(NSNotification *)notification
{
  if (_playInBackground || _playWhenInactive || _paused) return;

  [_player pause];
  [_player setRate:0.0];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
  if (_playInBackground) {
    // Needed to play sound in background. See https://developer.apple.com/library/ios/qa/qa1668/_index.html
    [_playerLayer setPlayer:nil];
  }
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
  [self applyModifiers];
  if (_playInBackground) {
    [_playerLayer setPlayer:_player];
  }
}

#pragma mark - Progress

- (void)sendProgressUpdate
{
   AVPlayerItem *video = [_player currentItem];
   if (video == nil || video.status != AVPlayerItemStatusReadyToPlay) {
     return;
   }

   CMTime playerDuration = [self playerItemDuration];
   if (CMTIME_IS_INVALID(playerDuration)) {
      return;
   }

  int newPlayingClipIndex = [self playingClipIndex];
  if (_playingClipIndex < newPlayingClipIndex) {
    self.onVideoClipEnd(@{
                          @"playingClipIndex": [NSNumber numberWithInt:newPlayingClipIndex],
                          @"target": self.reactTag
                          });
  }

  _playingClipIndex = newPlayingClipIndex;
  
   CMTime currentTime = _player.currentTime;
   const Float64 duration = CMTimeGetSeconds(playerDuration);
   const Float64 currentTimeSecs = CMTimeGetSeconds(currentTime);

   [[NSNotificationCenter defaultCenter] postNotificationName:@"RCTVideo_progress" object:nil userInfo:@{@"progress": [NSNumber numberWithDouble: currentTimeSecs / duration]}];

   if( currentTimeSecs >= 0 && self.onVideoProgress) {
      self.onVideoProgress(@{
                             @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(currentTime)],
                             @"playingClipCurrentTime": [self playingClipCurrentTime:CMTimeGetSeconds(currentTime)],
                             @"playingClipIndex": [NSNumber numberWithInt:_playingClipIndex],
                             @"playableDuration": [self calculatePlayableDuration],
                             @"atValue": [NSNumber numberWithLongLong:currentTime.value],
                             @"atTimescale": [NSNumber numberWithInt:currentTime.timescale],
                             @"target": self.reactTag,
                             @"seekableDuration": [self calculateSeekableDuration],
                            });
   }
}

- (NSNumber*)playingClipCurrentTime:(float)currentTime
{
  float time;
  int playingClipIndex = [self playingClipIndex];
  if (playingClipIndex > 0) {
    time = currentTime - [_clipEndOffsets[playingClipIndex - 1] floatValue];
  } else {
    time = currentTime;
  }
  return [NSNumber numberWithFloat:time];
}

/*!
 * Calculates and returns the index of the clip being played by _player.
 *
 * \returns The index of the clip currently being played.
 */
- (int)playingClipIndex
{
  AVPlayerItem *video = _player.currentItem;
  if (video.status == AVPlayerItemStatusReadyToPlay) {
    float playerTimeSeconds = CMTimeGetSeconds([_player currentTime]);
    __block NSUInteger playingClipIndex = 0;
    
    [_clipEndOffsets enumerateObjectsUsingBlock:^(id offset, NSUInteger idx, BOOL *stop) {
      if (playerTimeSeconds < [offset floatValue]) {
        playingClipIndex = idx;
        *stop = YES;
      }
    }];
    return playingClipIndex;
  }
  return 0;
}

/*!
 * Calculates and returns the playable duration of the current player item using its loaded time ranges.
 *
 * \returns The playable duration of the current player item in seconds.
 */
- (NSNumber *)calculatePlayableDuration
{
  AVPlayerItem *video = _player.currentItem;
  if (video.status == AVPlayerItemStatusReadyToPlay) {
    __block CMTimeRange effectiveTimeRange;
    [video.loadedTimeRanges enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
      CMTimeRange timeRange = [obj CMTimeRangeValue];
      if (CMTimeRangeContainsTime(timeRange, video.currentTime)) {
        effectiveTimeRange = timeRange;
        *stop = YES;
      }
    }];
    Float64 playableDuration = CMTimeGetSeconds(CMTimeRangeGetEnd(effectiveTimeRange));
    if (playableDuration > 0) {
      return [NSNumber numberWithFloat:playableDuration];
    }
  }
  return [NSNumber numberWithInteger:0];
}

- (NSNumber *)calculateSeekableDuration
{
    CMTimeRange timeRange = [self playerItemSeekableTimeRange];
    if (CMTIME_IS_NUMERIC(timeRange.duration))
    {
        return [NSNumber numberWithFloat:CMTimeGetSeconds(timeRange.duration)];
    }
    return [NSNumber numberWithInteger:0];
}

- (void)addPlayerItemObservers
{
  [_playerItem addObserver:self forKeyPath:statusKeyPath options:0 context:nil];
  [_playerItem addObserver:self forKeyPath:playbackBufferEmptyKeyPath options:0 context:nil];
  [_playerItem addObserver:self forKeyPath:playbackLikelyToKeepUpKeyPath options:0 context:nil];
  [_playerItem addObserver:self forKeyPath:timedMetadata options:NSKeyValueObservingOptionNew context:nil];
  _playerItemObserversSet = YES;
}

/* Fixes https://github.com/brentvatne/react-native-video/issues/43
 * Crashes caused when trying to remove the observer when there is no
 * observer set */
- (void)removePlayerItemObservers
{
  if (_playerItemObserversSet) {
    [_playerItem removeObserver:self forKeyPath:statusKeyPath];
    [_playerItem removeObserver:self forKeyPath:playbackBufferEmptyKeyPath];
    [_playerItem removeObserver:self forKeyPath:playbackLikelyToKeepUpKeyPath];
    [_playerItem removeObserver:self forKeyPath:timedMetadata];
    _playerItemObserversSet = NO;
  }
}

#pragma mark - Player and source

- (void)setSrc:(NSArray *)source
{
  if (!_queue) {
    _queue = dispatch_queue_create(nil, nil);
  }
  
  if (_preparationInProgress) {
    _pendingSource = source;
  } else {
    dispatch_async(_queue, ^{
      // This heavy lifting is done asynchronously to avoid burdening the UI thread.
      [self preparePlayer:source];
      if (_pendingSource) {
        NSArray *ps = _pendingSource;
        _pendingSource = nil;
        [self preparePlayer:ps];
      }
    });
  }
}

- (void)preparePlayer:(NSArray *)source
{
  [self removePlayerLayer];
  [self removePlayerTimeObserver];
  [self removePlayerItemObservers];
  [self removebufferingTimer];

  _preparationInProgress = YES;
  __weak RCTVideo *weakSelf = self;
  const Float64 progressUpdateIntervalMS = _progressUpdateInterval / 1000;
  
  if (!_clipAssets || [_clipAssets count] < [source count]) {
    [self prepareAssetsForSources:source];
  }
  _playerItem = [self playerItemForAssets:_clipAssets];
  _playingClipIndex = 0;
  
  if ([_clipAssets count] > 0) {
    [self startBufferingClips];
  }

  [_player pause];
  [_playerViewController.view removeFromSuperview];
  _playerViewController = nil;

  if (_playbackRateObserverRegistered) {
    [_player removeObserver:self forKeyPath:playbackRate context:nil];
    _playbackRateObserverRegistered = NO;
  }

  _player = [AVPlayer playerWithPlayerItem:_playerItem];
  _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
  
  if ([_clipAssets count] > 0) {
    [self addPlayerItemObservers];
    if (_removed == YES) {
      /* In case the view was removed while this async block was setting things up,
       * we trigger the lifecycle cleanup logic, e.g. to prevent the player from
       * playing on in the background afer the view is unmounted.  */
      [self removeFromSuperview];
    } else {
      [_player addObserver:self forKeyPath:playbackRate options:0 context:nil];
      _playbackRateObserverRegistered = YES;

      const Float64 progressUpdateIntervalMS = _progressUpdateInterval / 1000;
      // @see endScrubbing in AVPlayerDemoPlaybackViewController.m of https://developer.apple.com/library/ios/samplecode/AVPlayerDemo/Introduction/Intro.html
      __weak RCTVideo *weakSelf = self;
      _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(progressUpdateIntervalMS, NSEC_PER_SEC)
                                                            queue:NULL
                                                      usingBlock:^(CMTime time) { [weakSelf sendProgressUpdate]; }
                      ];

      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        _bufferingTimer = [NSTimer scheduledTimerWithTimeInterval:(_progressUpdateInterval / 1000)
                                                          target:weakSelf
                                                          selector:@selector(updateBufferingProgress)
                                                          userInfo:nil
                                                          repeats:true];
        [[NSRunLoop currentRunLoop] addTimer:_bufferingTimer forMode:UITrackingRunLoopMode];
        //Perform on next run loop, otherwise onVideoLoadStart is nil
        // Note: Currently doesn't handle heterogeneous clips.
        NSDictionary *firstSource = source[0];
        if(self.onVideoLoadStart) {
          id uri = [firstSource objectForKey:@"uri"];
          id type = [firstSource objectForKey:@"type"];
          self.onVideoLoadStart(@{@"src": @{
                                            @"uri": uri ? uri : [NSNull null],
                                            @"type": type ? type : [NSNull null],
                                            @"isNetwork": [NSNumber numberWithBool:(bool)[firstSource objectForKey:@"isNetwork"]]},
                                            @"target": self.reactTag
                                            });
        }
      });
    }
  }
  _preparationInProgress = NO;
}

- (void)prepareAssetsForSources:(NSArray *)sources
{
  int prepCount;
  int nextClipIndex;
  int firstClipIndexToPrepare;
  
  NSMutableArray *sourcesToPrepare;
  float currentOffset;
  
  if (_clipAssets) {
    // Then we only prepare assets for clips just appended
    sourcesToPrepare = [[NSMutableArray alloc] init];
    prepCount = [sources count] - [_clipAssets count];
    for (int i = [_clipAssets count]; i < [sources count]; i++) {
      [sourcesToPrepare addObject:[sources objectAtIndex:i]];
    }
    currentOffset = [[_clipEndOffsets lastObject] floatValue];
    nextClipIndex = [_clipAssets count];
    firstClipIndexToPrepare = [_clipAssets count];
  } else {
    sourcesToPrepare = [NSMutableArray arrayWithArray:sources];
    _clipAssets     = [[NSMutableArray alloc] init];
    _clipEndOffsets = [[NSMutableArray alloc] init];
    _clipDurations  = [[NSMutableArray alloc] init];
    prepCount = [sourcesToPrepare count];
    _bufferedClipIndexes = [[NSMutableArray alloc] init];
    currentOffset = 0.0;
    nextClipIndex = 0;
    firstClipIndexToPrepare = 0;
  }
  for (int i = 0; i < prepCount; i++) {
    [_clipAssets     addObject:kCFNull];
    [_clipEndOffsets addObject:kCFNull];
    [_clipDurations  addObject:kCFNull];
  }
  
  // We initialise the assets concurrently to avoid blocking while metadata is loaded
  dispatch_group_t assetGroup = dispatch_group_create();
  for (NSDictionary* source in sourcesToPrepare) {
    [_bufferedClipIndexes addObject:[NSNumber numberWithInt:0]];
    bool isNetwork = [RCTConvert BOOL:[source objectForKey:@"isNetwork"]];
    bool isAsset = [RCTConvert BOOL:[source objectForKey:@"isAsset"]];
    NSString *uri = [source objectForKey:@"uri"];
    NSString *type = [source objectForKey:@"type"];
    
    NSURL *url = (isNetwork || isAsset) ?
      [NSURL URLWithString:uri] :
      [[NSURL alloc] initFileURLWithPath:[[NSBundle mainBundle] pathForResource:uri ofType:type]];
    
    dispatch_group_enter(assetGroup);
    AVURLAsset *asset;
    if (isNetwork) {
      NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
      asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetHTTPCookiesKey : cookies,
                                                                    AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    } else {
      asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    }
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"]
                         completionHandler:^{
                           NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
                           NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
                           
                           if ([videoTracks count] > 0) {
                             AVAssetTrack *firstVideoTrack = videoTracks[0];
                             
                             CMTime dur = firstVideoTrack.timeRange.duration;
                             [_clipAssets replaceObjectAtIndex:nextClipIndex withObject:asset];
                             [_clipDurations replaceObjectAtIndex:nextClipIndex withObject:[NSNumber numberWithFloat:CMTimeGetSeconds(dur)]];
                           } else {
                             NSLog(@"RCTVideo: WARNING - no audio or video tracks for asset %@ (uri: %@), skipping...", asset, uri);
                           }
                           dispatch_group_leave(assetGroup);
                         }];
    
    nextClipIndex++;
  }

  dispatch_group_wait(assetGroup, DISPATCH_TIME_FOREVER);

  // Fill in any new values in _clipEndOffsets
  for (int i = firstClipIndexToPrepare; i < [_clipAssets count]; i++) {
    NSNumber *duration = [_clipDurations objectAtIndex:i];
    if (duration != kCFNull) {
      currentOffset += [duration floatValue];
      [_clipEndOffsets replaceObjectAtIndex:i withObject:[NSNumber numberWithFloat:currentOffset]];
    }
  }

  // Clips without video tracks will have resulted in a nil entry in
  // _clipAssets / _clipEndOffsets / _clipDurations, so before we finish
  // we'll remove those entries.
  for (int i = 0; i < [_clipAssets count]; i++) {
    if ([_clipAssets objectAtIndex:i] == kCFNull) {
       [_clipAssets     removeObjectAtIndex:i];
       [_clipEndOffsets removeObjectAtIndex:i];
       [_clipDurations  removeObjectAtIndex:i];
    }
  }
}

- (AVPlayerItem*)playerItemForAssets:(NSMutableArray *)assets
{
  AVMutableComposition* composition = [AVMutableComposition composition];
  AVMutableCompositionTrack *compVideoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo
                                                                       preferredTrackID:kCMPersistentTrackID_Invalid];
  AVMutableCompositionTrack *compAudioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                       preferredTrackID:kCMPersistentTrackID_Invalid];
  CMTime timeOffset = kCMTimeZero;
  for (AVAsset* asset in assets) {
    NSError *editError;
    
    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    AVAssetTrack *firstVideoTrack = videoTracks[0];
    
    CMTime dur = firstVideoTrack.timeRange.duration;
    
    CMTimeRange editRange = CMTimeRangeMake(CMTimeMake(0, 600), dur);
    
    if ([videoTracks count] > 0) {
      AVAssetTrack *videoTrack = [videoTracks objectAtIndex:0];
      [compVideoTrack insertTimeRange:editRange
                              ofTrack:videoTrack
                               atTime:timeOffset
                                error:&editError];
    }
    
    if ([audioTracks count] > 0) {
      AVAssetTrack *audioTrack = [audioTracks objectAtIndex:0];
      [compAudioTrack insertTimeRange:editRange
                              ofTrack:audioTrack
                               atTime:timeOffset
                                error:&editError];
    }
    
    if ([videoTracks count] > 0 || [audioTracks count] > 0) {
      timeOffset = CMTimeAdd(timeOffset, dur);
    }
  }
  AVPlayerItem* playerItem = [AVPlayerItem playerItemWithAsset:composition];
  return playerItem;
}


- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
   if (object == _playerItem) {

    // When timeMetadata is read the event onTimedMetadata is triggered
    if ([keyPath isEqualToString: timedMetadata])
    {


        NSArray<AVMetadataItem *> *items = [change objectForKey:@"new"];
        if (items && ![items isEqual:[NSNull null]] && items.count > 0) {

            NSMutableArray *array = [NSMutableArray new];
            for (AVMetadataItem *item in items) {

                NSString *value = item.value;
                NSString *identifier = item.identifier;

                if (![value isEqual: [NSNull null]]) {
                    NSDictionary *dictionary = [[NSDictionary alloc] initWithObjects:@[value, identifier] forKeys:@[@"value", @"identifier"]];

                    [array addObject:dictionary];
                }
            }

            self.onTimedMetadata(@{
                                   @"target": self.reactTag,
                                   @"metadata": array
                                   });
        }
    }

    if ([keyPath isEqualToString:statusKeyPath]) {
      // Handle player item status change.
      if (_playerItem.status == AVPlayerItemStatusReadyToPlay) {
        float duration = CMTimeGetSeconds(_playerItem.asset.duration);

        if (isnan(duration)) {
          duration = 0.0;
        }

        NSObject *width = @"undefined";
        NSObject *height = @"undefined";
        NSString *orientation = @"undefined";

        if ([_playerItem.asset tracksWithMediaType:AVMediaTypeVideo].count > 0) {
          AVAssetTrack *videoTrack = [[_playerItem.asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
          width = [NSNumber numberWithFloat:videoTrack.naturalSize.width];
          height = [NSNumber numberWithFloat:videoTrack.naturalSize.height];
          CGAffineTransform preferredTransform = [videoTrack preferredTransform];

          if ((videoTrack.naturalSize.width == preferredTransform.tx
            && videoTrack.naturalSize.height == preferredTransform.ty)
            || (preferredTransform.tx == 0 && preferredTransform.ty == 0))
          {
            orientation = @"landscape";
          } else
            orientation = @"portrait";
        }

      if(self.onVideoLoad) {
          self.onVideoLoad(@{@"duration": [NSNumber numberWithFloat:duration],
                             @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(_playerItem.currentTime)],
                             @"canPlayReverse": [NSNumber numberWithBool:_playerItem.canPlayReverse],
                             @"canPlayFastForward": [NSNumber numberWithBool:_playerItem.canPlayFastForward],
                             @"canPlaySlowForward": [NSNumber numberWithBool:_playerItem.canPlaySlowForward],
                             @"canPlaySlowReverse": [NSNumber numberWithBool:_playerItem.canPlaySlowReverse],
                             @"canStepBackward": [NSNumber numberWithBool:_playerItem.canStepBackward],
                             @"canStepForward": [NSNumber numberWithBool:_playerItem.canStepForward],
                             @"naturalSize": @{
                                     @"width": width,
                                     @"height": height,
                                     @"orientation": orientation
                                     },
                             @"target": self.reactTag});
      }


        [self attachListeners];
        [self applyModifiers];
      } else if(_playerItem.status == AVPlayerItemStatusFailed && self.onVideoError) {
        self.onVideoError(@{@"error": @{@"code": [NSNumber numberWithInteger: _playerItem.error.code],
                                        @"domain": _playerItem.error.domain},
                                        @"target": self.reactTag});
      }
    } else if ([keyPath isEqualToString:playbackBufferEmptyKeyPath]) {
      _playerBufferEmpty = YES;
      self.onVideoBuffer(@{@"isBuffering": @(YES), @"target": self.reactTag});
    } else if ([keyPath isEqualToString:playbackLikelyToKeepUpKeyPath]) {
      // Continue playing (or not if paused) after being paused due to hitting an unbuffered zone.
      if ((!(_controls || _fullscreenPlayerPresented) || _playerBufferEmpty) && _playerItem.playbackLikelyToKeepUp) {
        [self setPaused:_paused];
        _pausedForBuffering = _paused;
      }
      _playerBufferEmpty = NO;
      self.onVideoBuffer(@{@"isBuffering": @(NO), @"target": self.reactTag});
    }
   } else if (object == _playerLayer) {
      if([keyPath isEqualToString:readyForDisplayKeyPath] && [change objectForKey:NSKeyValueChangeNewKey]) {
        if([change objectForKey:NSKeyValueChangeNewKey] && self.onReadyForDisplay) {
          self.onReadyForDisplay(@{@"target": self.reactTag});
        }
    }
  } else if (object == _player) {
      if([keyPath isEqualToString:playbackRate]) {
          if(self.onPlaybackRateChange) {
              self.onPlaybackRateChange(@{@"playbackRate": [NSNumber numberWithFloat:_player.rate],
                                          @"target": self.reactTag});
          }
          if(_playbackStalled && _player.rate > 0) {
              if(self.onPlaybackResume) {
                  self.onPlaybackResume(@{@"playbackRate": [NSNumber numberWithFloat:_player.rate],
                                          @"target": self.reactTag});
              }
              _playbackStalled = NO;
          }
      }
  } else {
      [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
  }
}

- (void)attachListeners
{
  // listen for end of file
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(playerItemDidReachEnd:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:[_player currentItem]];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(playbackStalled:)
                                               name:AVPlayerItemPlaybackStalledNotification
                                             object:nil];
}

- (NSNumber*)totalDuration
{
  float total = 0.0;
  for (NSNumber *duration in _clipDurations) {
    total += [duration floatValue];
  }
  return [NSNumber numberWithFloat:total];
}


- (void)playbackStalled:(NSNotification *)notification
{
  if(self.onPlaybackStalled) {
    self.onPlaybackStalled(@{@"target": self.reactTag});
  }
  _playbackStalled = YES;
}

- (void)playerItemDidReachEnd:(NSNotification *)notification
{
  if(self.onVideoEnd) {
      self.onVideoEnd(@{@"target": self.reactTag});
  }

  if (_repeat) {
    AVPlayerItem *item = [notification object];
    [item seekToTime:kCMTimeZero];
    [self applyModifiers];
  }
}

#pragma mark - Buffering

/* AVMutableComposition has several desirable properties for multiple-video playback:
 * It allows continuous scrubbing between clips, presenting the composite video's
 * duration as the sum of the component clips' duration.
 *
 * However, when this code was written (Feb '16), an AVPlayer loaded with an AVPlayerItem
 * whose asset was a AVMutableComposition buffered the video assets very slowly, and its
 * buffering progress was not correctly reflected in loadedTimeRanges or
 * playbackLikelyToKeepUp (the former was set to the full duration from the start, and
 * the latter was always true, despite very choppy playback during buffering).
 *
 * To address this, two (or one, for clip lists of length <= 2) additional AVPlayers
 * are maintained. They buffer the assets much faster and more reliably than the _player,
 * since it's loaded with an AVMutableComposition.
 *
 * The logic below and associated bookkeeping variables track the buffering progress for
 * the buffering players via loadedTimeRanges, proceeding to load the lowest-indexed
 * clip that's not yet been buffered, stopping playback when it reaches a clip that's
 * currently being buffered.
 *
 * To begin with, only one player is buffering. When 88% of the first clip has been buffered,
 * the second buffering player starts working on the second clip, with the two players
 * "leapfrogging" until all clips have been buffered. This avoids slowing down the buffering
 * of any single clip by too much, while also aiming for smooth playback between clips.
 * */

- (void)startBufferingClips
{
  if (_bufferingStarted == NO && _shouldBuffer == YES) {
    _bufferingStarted = YES;
    _bufferingPlayerItemA = [AVPlayerItem playerItemWithAsset:_clipAssets[0]
                                 automaticallyLoadedAssetKeys:@[@"tracks"]];
    _bufferingPlayerA = [AVPlayer playerWithPlayerItem:_bufferingPlayerItemA];
    _mainBufferingPlayer = _bufferingPlayerA;
    _currentlyBufferingIndexA = [NSNumber numberWithInt:0];
  }
  
  // For the case when setSrc was initially called with one clip, and then again
  // with more than one clip.
  if ([_clipAssets count] > 1 &&
      (_bufferingStarted == NO || (_bufferingStarted == YES && !_bufferingPlayerB))) {
    _nextIndexToBuffer = [NSNumber numberWithInt:1];
    _currentlyBufferingIndexB = [NSNumber numberWithInt:1];
  }
}

- (void)updateBufferingProgress
{
  if (_shouldBuffer == YES) {
    if (_bufferingStarted == NO) {
      [self startBufferingClips];
    }
    [self updateBufferingProgressForPlayer :_mainBufferingPlayer];
  }
}

- (void)updateBufferingProgressForPlayer:(AVPlayer*)bufferingPlayer
{
  Float64 playableDurationForMainBufferingItem = [self bufferedDurationForItem :bufferingPlayer];
  Float64 bufferingItemDuration = CMTimeGetSeconds([self otherPlayerItemDuration:bufferingPlayer]);
  bool singleClip = !_currentlyBufferingIndexB;
  // This margin is to cover the case where the audio channel has a slightly
  // shorter duration than the video channel.
  bool bufferingComplete = 0.95 * (bufferingItemDuration - playableDurationForMainBufferingItem) < 0.2;
  
  if (singleClip) {
    if (playableDurationForMainBufferingItem < bufferingItemDuration) {
      [self setPaused :true];
      _pausedForBuffering = YES;
    } else {
      if (_pausedForBuffering == YES) {
        [self setPaused :false];
        _pausedForBuffering = NO;
      }
    }
    return;
  }
  
  // Now compute the same for the alt buffering player
  AVPlayer* altBufferingPlayer;
  int currentlyBufferingIndexAlt;
  if (bufferingPlayer == _bufferingPlayerA) {
    altBufferingPlayer = _bufferingPlayerB;
    currentlyBufferingIndexAlt = [_currentlyBufferingIndexB intValue];
  } else {
    altBufferingPlayer = _bufferingPlayerA;
    currentlyBufferingIndexAlt = [_currentlyBufferingIndexA intValue];
  }
  Float64 playableDurationForAltBufferingItem = [self bufferedDurationForItem :altBufferingPlayer];
  
  Float64 altBufferingItemDuration = CMTimeGetSeconds([self otherPlayerItemDuration:altBufferingPlayer]);
  
  bool altBufferingComplete = (0.95 * (altBufferingItemDuration - playableDurationForAltBufferingItem) < 0.2);
  
  bool startBufferingNextClip = (0.88 * bufferingItemDuration - playableDurationForMainBufferingItem) < 0.0;
  float playerTimeSeconds = CMTimeGetSeconds([_player currentTime]);
  
  NSUInteger currentlyBufferingIndex = [(bufferingPlayer == _bufferingPlayerA ? _currentlyBufferingIndexA : _currentlyBufferingIndexB) intValue];
  
  const int MAX_IDX = 99999;
  __block int firstUnbufferedIdx = MAX_IDX;
  NSNumber *zero = [NSNumber numberWithInt:0];
  [_bufferedClipIndexes enumerateObjectsUsingBlock:^(id buffered, NSUInteger idx, BOOL *stop) {
    if ([buffered isEqualToNumber:zero]) {
      firstUnbufferedIdx = idx;
      *stop = YES;
    }
  }];
  
  if (firstUnbufferedIdx < MAX_IDX) {
    float bufferedOffset = firstUnbufferedIdx == 0 ? 0.0 : [_clipEndOffsets[firstUnbufferedIdx] floatValue];
    float totalBufferedSeconds = bufferedOffset + playableDurationForAltBufferingItem;
    
    if (totalBufferedSeconds < playerTimeSeconds) {
      [self setPaused :true];
      _pausedForBuffering = YES;
    } else {
      if (_pausedForBuffering == YES) {
        [self setPaused :false];
        _pausedForBuffering = NO;
      }
    }
  } else {
    if (_pausedForBuffering == YES) {
      [self setPaused :false];
      _pausedForBuffering = NO;
    }
  }
  
  if (bufferingComplete) {
    [_bufferedClipIndexes replaceObjectAtIndex:currentlyBufferingIndex withObject:@(YES)];
  }
  
  if (altBufferingComplete && currentlyBufferingIndexAlt < [_clipAssets count]) {
    [_bufferedClipIndexes replaceObjectAtIndex:currentlyBufferingIndexAlt withObject:@(YES)];
  }
  
  if (startBufferingNextClip && [_nextIndexToBuffer intValue] < [_clipAssets count]) {
    if (bufferingPlayer == _bufferingPlayerA) {
      _currentlyBufferingIndexB = [_nextIndexToBuffer copy];
      _bufferingPlayerItemB = [AVPlayerItem playerItemWithAsset:_clipAssets[[_nextIndexToBuffer intValue]]
                                   automaticallyLoadedAssetKeys:@[@"tracks"]];
      
      _bufferingPlayerB = [AVPlayer playerWithPlayerItem:_bufferingPlayerItemB];
      _mainBufferingPlayer = _bufferingPlayerB;
    } else {
      _currentlyBufferingIndexA = [_nextIndexToBuffer copy];
      _bufferingPlayerItemA = [AVPlayerItem playerItemWithAsset:_clipAssets[[_nextIndexToBuffer intValue]]
                                   automaticallyLoadedAssetKeys:@[@"tracks"]];
      
      _bufferingPlayerA = [AVPlayer playerWithPlayerItem:_bufferingPlayerItemA];
      _mainBufferingPlayer = _bufferingPlayerA;
    }
    _nextIndexToBuffer = [NSNumber numberWithInt:([_nextIndexToBuffer intValue] + 1)];
  }
}

- (Float64)bufferedDurationForItem:(AVPlayer*)bufferingPlayer
{
  AVPlayerItem *video = bufferingPlayer.currentItem;
  if (video.status == AVPlayerItemStatusReadyToPlay) {
    __block Float64 longestPlayableRangeSeconds;
    [video.loadedTimeRanges enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
      CMTimeRange timeRange = [obj CMTimeRangeValue];
      Float64 seconds = CMTimeGetSeconds(CMTimeRangeGetEnd(timeRange));
      if (seconds && seconds > 0.1) {
        if (!longestPlayableRangeSeconds) {
          longestPlayableRangeSeconds = seconds;
        } else if (seconds > longestPlayableRangeSeconds) {
          longestPlayableRangeSeconds = seconds;
        }
      }
    }];
    if (longestPlayableRangeSeconds && longestPlayableRangeSeconds > 0) {
      return longestPlayableRangeSeconds;
    }
  }
  return 0.0;
}

#pragma mark - Prop setters

- (void)setResizeMode:(NSString*)mode
{
  if( _controls )
  {
    _playerViewController.videoGravity = mode;
  }
  else
  {
    _playerLayer.videoGravity = mode;
  }
  _resizeMode = mode;
}

- (void)setPlayInBackground:(BOOL)playInBackground
{
  _playInBackground = playInBackground;
}

- (void)setPlayWhenInactive:(BOOL)playWhenInactive
{
  _playWhenInactive = playWhenInactive;
}

- (void)setIgnoreSilentSwitch:(NSString *)ignoreSilentSwitch
{
  _ignoreSilentSwitch = ignoreSilentSwitch;
  [self applyModifiers];
}

- (void)setPaused:(BOOL)paused
{
  if (paused) {
    [_player pause];
    [_player setRate:0.0];
  } else {
    if([_ignoreSilentSwitch isEqualToString:@"ignore"]) {
      [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    } else if([_ignoreSilentSwitch isEqualToString:@"obey"]) {
      [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil];
    }
    [_player play];
    [_player setRate:_rate];
  }

  _paused = paused;
}

- (float)getCurrentTime
{
  return _playerItem != NULL ? CMTimeGetSeconds(_playerItem.currentTime) : 0;
}

- (void)setCurrentTime:(float)currentTime
{
  [self setSeek: currentTime];
}

- (void)setSeek:(float)seekTime
{
  int timeScale = 10000;

  AVPlayerItem *item = _player.currentItem;
  if (item && item.status == AVPlayerItemStatusReadyToPlay) {
    // TODO check loadedTimeRanges

    CMTime cmSeekTime = CMTimeMakeWithSeconds(seekTime, timeScale);
    CMTime current = item.currentTime;
    // TODO figure out a good tolerance level
    CMTime tolerance = CMTimeMake(1000, timeScale);
    BOOL wasPaused = _paused;

    if (CMTimeCompare(current, cmSeekTime) != 0) {
      if (!wasPaused) [_player pause];
      [_player seekToTime:cmSeekTime toleranceBefore:tolerance toleranceAfter:tolerance completionHandler:^(BOOL finished) {
        _playingClipIndex = [self playingClipIndex];
        if (!wasPaused) [_player play];
        if(self.onVideoSeek) {
            self.onVideoSeek(@{@"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(item.currentTime)],
                               @"seekTime": [NSNumber numberWithFloat:seekTime],
                               @"target": self.reactTag});
        }
      }];

      _pendingSeek = false;
    }

  } else {
    // TODO: See if this makes sense and if so, actually implement it
    _pendingSeek = true;
    _pendingSeekTime = seekTime;
  }
}

- (void)setSeekClip:(NSDictionary*)seekParams
{
  int clipIndex = [[seekParams objectForKey:@"index"] intValue];
  float time = ([[seekParams objectForKey:@"time"] floatValue] || 0.0);
  float position;
  if (clipIndex == 0) {
    [self setSeek: time];
  } else {
    NSNumber *offset = [_clipEndOffsets objectAtIndex:(clipIndex - 1)];
    if (offset != kCFNull) {
      [self setSeek: ([offset floatValue] + time)];
    }
    // if offset is nil, the clips' metadata hasn't been loaded, so we do nothing.
  }
  
}

- (void)setRate:(float)rate
{
  _rate = rate;
  [self applyModifiers];
}

- (void)setMuted:(BOOL)muted
{
  _muted = muted;
  [self applyModifiers];
}

- (void)setVolume:(float)volume
{
  _volume = volume;
  [self applyModifiers];
}

- (void)setBuffering:(BOOL)shouldBuffer
{
  _shouldBuffer = (shouldBuffer || NO);
}

- (void)applyModifiers
{
  if (_muted) {
    [_player setVolume:0];
    [_player setMuted:YES];
  } else {
    [_player setVolume:_volume];
    [_player setMuted:NO];
  }

  [self setResizeMode:_resizeMode];
  [self setRepeat:_repeat];
  [self setPaused:_paused];
  [self setControls:_controls];
}

- (void)setRepeat:(BOOL)repeat {
  _repeat = repeat;
}

- (BOOL)getFullscreen
{
    return _fullscreenPlayerPresented;
}

- (void)setFullscreen:(BOOL)fullscreen
{
    if( fullscreen && !_fullscreenPlayerPresented )
    {
        // Ensure player view controller is not null
        if( !_playerViewController )
        {
            [self usePlayerViewController];
        }
        // Set presentation style to fullscreen
        [_playerViewController setModalPresentationStyle:UIModalPresentationFullScreen];

        // Find the nearest view controller
        UIViewController *viewController = [self firstAvailableUIViewController];
        if( !viewController )
        {
            UIWindow *keyWindow = [[UIApplication sharedApplication] keyWindow];
            viewController = keyWindow.rootViewController;
            if( viewController.childViewControllers.count > 0 )
            {
                viewController = viewController.childViewControllers.lastObject;
            }
        }
        if( viewController )
        {
            _presentingViewController = viewController;
            if(self.onVideoFullscreenPlayerWillPresent) {
                self.onVideoFullscreenPlayerWillPresent(@{@"target": self.reactTag});
            }
            [viewController presentViewController:_playerViewController animated:true completion:^{
                _playerViewController.showsPlaybackControls = YES;
                _fullscreenPlayerPresented = fullscreen;
                if(self.onVideoFullscreenPlayerDidPresent) {
                    self.onVideoFullscreenPlayerDidPresent(@{@"target": self.reactTag});
                }
            }];
        }
    }
    else if ( !fullscreen && _fullscreenPlayerPresented )
    {
        [self videoPlayerViewControllerWillDismiss:_playerViewController];
        [_presentingViewController dismissViewControllerAnimated:true completion:^{
            [self videoPlayerViewControllerDidDismiss:_playerViewController];
        }];
    }
}

- (void)usePlayerViewController
{
    if( _player )
    {
        _playerViewController = [self createPlayerViewController:_player withPlayerItem:_playerItem];
        // to prevent video from being animated when resizeMode is 'cover'
        // resize mode must be set before subview is added
        [self setResizeMode:_resizeMode];
        [self addSubview:_playerViewController.view];
    }
}

- (void)usePlayerLayer
{
    if( _player )
    {
      _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
      _playerLayer.frame = self.bounds;
      _playerLayer.needsDisplayOnBoundsChange = YES;

      // to prevent video from being animated when resizeMode is 'cover'
      // resize mode must be set before layer is added
      [self setResizeMode:_resizeMode];
      [_playerLayer addObserver:self forKeyPath:readyForDisplayKeyPath options:NSKeyValueObservingOptionNew context:nil];

      [self.layer addSublayer:_playerLayer];
      self.layer.needsDisplayOnBoundsChange = YES;
    }
}

- (void)setControls:(BOOL)controls
{
    if( _controls != controls || (!_playerLayer && !_playerViewController) )
    {
        _controls = controls;
        if( _controls )
        {
            [self removePlayerLayer];
            [self usePlayerViewController];
        }
        else
        {
            [_playerViewController.view removeFromSuperview];
            _playerViewController = nil;
            [self usePlayerLayer];
        }
    }
}

- (void)setProgressUpdateInterval:(float)progressUpdateInterval
{
  _progressUpdateInterval = progressUpdateInterval;
}

- (void)removePlayerLayer
{
    [_playerLayer removeFromSuperlayer];
    [_playerLayer removeObserver:self forKeyPath:readyForDisplayKeyPath];
    _playerLayer = nil;
}

#pragma mark - RCTVideoPlayerViewControllerDelegate

- (void)videoPlayerViewControllerWillDismiss:(AVPlayerViewController *)playerViewController
{
    if (_playerViewController == playerViewController && _fullscreenPlayerPresented && self.onVideoFullscreenPlayerWillDismiss)
    {
        self.onVideoFullscreenPlayerWillDismiss(@{@"target": self.reactTag});
    }
}

- (void)videoPlayerViewControllerDidDismiss:(AVPlayerViewController *)playerViewController
{
    if (_playerViewController == playerViewController && _fullscreenPlayerPresented)
    {
        _fullscreenPlayerPresented = false;
        _presentingViewController = nil;
        _playerViewController = nil;
        [self applyModifiers];
        if(self.onVideoFullscreenPlayerDidDismiss) {
            self.onVideoFullscreenPlayerDidDismiss(@{@"target": self.reactTag});
        }
    }
}

#pragma mark - React View Management

- (void)insertReactSubview:(UIView *)view atIndex:(NSInteger)atIndex
{
  // We are early in the game and somebody wants to set a subview.
  // That can only be in the context of playerViewController.
  if( !_controls && !_playerLayer && !_playerViewController )
  {
    [self setControls:true];
  }

  if( _controls )
  {
     view.frame = self.bounds;
     [_playerViewController.contentOverlayView insertSubview:view atIndex:atIndex];
  }
  else
  {
     RCTLogError(@"video cannot have any subviews");
  }
  return;
}

- (void)removeReactSubview:(UIView *)subview
{
  if( _controls )
  {
      [subview removeFromSuperview];
  }
  else
  {
    RCTLogError(@"video cannot have any subviews");
  }
  return;
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  if( _controls )
  {
    _playerViewController.view.frame = self.bounds;

    // also adjust all subviews of contentOverlayView
    for (UIView* subview in _playerViewController.contentOverlayView.subviews) {
      subview.frame = self.bounds;
    }
  }
  else
  {
      [CATransaction begin];
      [CATransaction setAnimationDuration:0];
      _playerLayer.frame = self.bounds;
      [CATransaction commit];
  }
}

#pragma mark - Lifecycle

- (void)removeFromSuperview
{
  [_player pause];
  if (_playbackRateObserverRegistered) {
    [_player removeObserver:self forKeyPath:playbackRate context:nil];
    _playbackRateObserverRegistered = NO;
  }
  _player = nil;
  _bufferingPlayerA = nil;
  _bufferingPlayerB = nil;

  [self removePlayerLayer];

  [_playerViewController.view removeFromSuperview];
  _playerViewController = nil;

  [self removePlayerTimeObserver];
  [self removePlayerItemObservers];
  [self removebufferingTimer];
  _queue = nil;

  _eventDispatcher = nil;
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  _removed = YES;

  [super removeFromSuperview];
}

@end
