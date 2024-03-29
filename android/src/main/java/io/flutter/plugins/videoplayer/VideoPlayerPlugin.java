// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.net.Uri;
import android.util.LongSparseArray;
import android.view.Surface;

import com.google.android.exoplayer2.C;
import com.google.android.exoplayer2.DefaultRenderersFactory;
import com.google.android.exoplayer2.Format;
import com.google.android.exoplayer2.MediaItem;
import com.google.android.exoplayer2.PlaybackException;
import com.google.android.exoplayer2.PlaybackParameters;
import com.google.android.exoplayer2.Player;
import com.google.android.exoplayer2.RenderersFactory;
import com.google.android.exoplayer2.SimpleExoPlayer;
import com.google.android.exoplayer2.Timeline;
import com.google.android.exoplayer2.audio.AudioAttributes;
import com.google.android.exoplayer2.offline.Download;
import com.google.android.exoplayer2.offline.DownloadHelper;
import com.google.android.exoplayer2.offline.DownloadRequest;
import com.google.android.exoplayer2.offline.DownloadService;
import com.google.android.exoplayer2.source.MediaSource;
import com.google.android.exoplayer2.source.ProgressiveMediaSource;
import com.google.android.exoplayer2.source.TrackGroupArray;
import com.google.android.exoplayer2.source.dash.DashMediaSource;
import com.google.android.exoplayer2.source.dash.DefaultDashChunkSource;
import com.google.android.exoplayer2.source.hls.HlsManifest;
import com.google.android.exoplayer2.source.hls.HlsMediaSource;
import com.google.android.exoplayer2.source.hls.playlist.HlsMasterPlaylist;
import com.google.android.exoplayer2.source.smoothstreaming.DefaultSsChunkSource;
import com.google.android.exoplayer2.source.smoothstreaming.SsMediaSource;
import com.google.android.exoplayer2.trackselection.DefaultTrackSelector;
import com.google.android.exoplayer2.trackselection.MappingTrackSelector;
import com.google.android.exoplayer2.trackselection.TrackSelectionArray;
import com.google.android.exoplayer2.upstream.DataSource;
import com.google.android.exoplayer2.upstream.DefaultDataSourceFactory;
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource;
import com.google.android.exoplayer2.util.Util;

import org.jetbrains.annotations.NotNull;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Timer;
import java.util.TimerTask;

import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.PluginRegistry.Registrar;
import io.flutter.view.TextureRegistry;

import static com.google.android.exoplayer2.Player.REPEAT_MODE_ALL;
import static com.google.android.exoplayer2.Player.REPEAT_MODE_OFF;

public class VideoPlayerPlugin implements MethodCallHandler {

    public static void registerWith(Registrar registrar) {
        final VideoPlayerPlugin plugin = new VideoPlayerPlugin(registrar);
        final MethodChannel channel =
                new MethodChannel(registrar.messenger(), "flutter.io/videoPlayer");
        channel.setMethodCallHandler(plugin);
        registrar.addViewDestroyListener(
                view -> {
                    plugin.onDestroy();
                    return false; // We are not interested in assuming ownership of the NativeView.
                });
    }

    private VideoPlayerPlugin(Registrar registrar) {
        this.registrar = registrar;
        this.videoPlayers = new LongSparseArray<>();
        this.videoDownloadManager = VideoDownloadManager.Companion.getInstance(registrar.activeContext().getApplicationContext());
    }

    private final LongSparseArray<VideoPlayer> videoPlayers;
    private final Registrar registrar;
    private final VideoDownloadManager videoDownloadManager;

    private void disposeAllPlayers() {
        for (int i = 0; i < videoPlayers.size(); i++) {
            videoPlayers.valueAt(i).dispose();
        }
        videoPlayers.clear();
    }

    private void onDestroy() {
        // The whole FlutterView is being destroyed. Here we release resources acquired for all instances
        // of VideoPlayer. Once https://github.com/flutter/flutter/issues/19358 is resolved this may
        // be replaced with just asserting that videoPlayers.isEmpty().
        // https://github.com/flutter/flutter/issues/20989 tracks this.
        disposeAllPlayers();
    }

    @Override
    public void onMethodCall(@NotNull MethodCall call, @NotNull Result result) {
        TextureRegistry textures = registrar.textures();
        if (textures == null) {
            result.error("no_activity", "video_player plugin requires a foreground activity", null);
            return;
        }
        switch (call.method) {
            case "init":
                disposeAllPlayers();
                break;
            case "create": {
                TextureRegistry.SurfaceTextureEntry handle = textures.createSurfaceTexture();
                EventChannel eventChannel =
                        new EventChannel(
                                registrar.messenger(), "flutter.io/videoPlayer/videoEvents" + handle.id());

                VideoPlayer player;
                if (call.argument("asset") != null) {
                    String assetLookupKey;
                    if (call.argument("package") != null) {
                        assetLookupKey =
                                registrar.lookupKeyForAsset(call.argument("asset"), call.argument("package"));
                    } else {
                        assetLookupKey = registrar.lookupKeyForAsset(call.argument("asset"));
                    }
                    player =
                            new VideoPlayer(
                                    registrar.context(),
                                    eventChannel,
                                    handle,
                                    "asset:///" + assetLookupKey,
                                    result, videoDownloadManager);
                    videoPlayers.put(handle.id(), player);
                } else {
                    player =
                            new VideoPlayer(
                                    registrar.context(), eventChannel, handle, call.argument("uri"), result, videoDownloadManager);
                    videoPlayers.put(handle.id(), player);
                }
                player.initDownloadState(videoDownloadManager);
                break;
            }
            default: {
                long textureId = ((Number) call.argument("textureId")).longValue();
                VideoPlayer player = videoPlayers.get(textureId);
                if (player == null) {
                    result.error(
                            "Unknown textureId",
                            "No video player associated with texture id " + textureId,
                            null);
                    return;
                }
                onMethodCall(call, result, textureId, player);
                break;
            }
        }
    }

    private void onMethodCall(MethodCall call, Result result, long textureId, VideoPlayer player) {
        switch (call.method) {
            case "setLooping":
                player.setLooping(call.argument("looping"));
                result.success(null);
                break;
            case "setVolume":
                player.setVolume(call.argument("volume"));
                result.success(null);
                break;
            case "play":
                player.play();
                result.success(null);
                break;
            case "pause":
                player.pause();
                result.success(null);
                break;
            case "seekTo":
                int location = ((Number) call.argument("location")).intValue();
                player.seekTo(location);
                result.success(null);
                break;
            case "position":
                result.success(player.getPosition());
                player.sendBufferingUpdate();
                break;
            case "dispose":
                player.dispose();
                videoPlayers.remove(textureId);
                result.success(null);
                break;
            case "switchResolutions":  //切换分辨率
                player.switchResolution(((Number) call.argument("trackIndex")).intValue());
                result.success(null);
                break;
            case "download": //缓存视频
                int trackIndex = ((Number) call.argument("trackIndex")).intValue();
                String name = call.argument("name");
                player.download(trackIndex, name);
                result.success(null);
                break;
            case "removeDownload": //删除视频
                player.removeDownload();
                result.success(null);
                break;
            case "setSpeed":
                double speed = ((Number) call.argument("speed")).doubleValue();
                player.setSpeed(speed);
                result.success(null);
                break;
            default:
                result.notImplemented();
                break;
        }
    }

    private static class VideoPlayer {

        private final SimpleExoPlayer exoPlayer;
        private final DefaultTrackSelector trackSelector;
        private final DataSource.Factory dataSourceFactory;
        private final RenderersFactory renderersFactory;
        private Surface surface;
        private final TextureRegistry.SurfaceTextureEntry textureEntry;
        private final QueuingEventSink eventSink = new QueuingEventSink();
        private final EventChannel eventChannel;
        private boolean isInitialized = false;
        private final Uri dataSourceUri;
        private DownloadHelper downloadHelper;
        private final Context context;
        private final VideoDownloadManager videoDownloadManager;
        private Timer refreshProgressTimer;

        VideoPlayer(
                Context context,
                EventChannel eventChannel,
                TextureRegistry.SurfaceTextureEntry textureEntry,
                String dataSource,
                Result result, VideoDownloadManager videoDownloadManager) {
            this.eventChannel = eventChannel;
            this.textureEntry = textureEntry;
            this.dataSourceUri = Uri.parse(dataSource);
            this.context = context.getApplicationContext();
            this.videoDownloadManager = videoDownloadManager;

            renderersFactory = new DefaultRenderersFactory(context);
            trackSelector = new DefaultTrackSelector(context);
            exoPlayer = new SimpleExoPlayer.Builder(context, renderersFactory)
                    .setTrackSelector(trackSelector)
                    .build();

            if (isFileOrAsset(dataSourceUri)) {
                dataSourceFactory = new DefaultDataSourceFactory(context, "ExoPlayer");
            } else {
                dataSourceFactory =
                        new DefaultHttpDataSource.Factory()
                                .setUserAgent("ExoPlayer")
                                .setAllowCrossProtocolRedirects(true);
            }

            MediaSource mediaSource = buildMediaSource(dataSourceUri, dataSourceFactory, context);
            exoPlayer.prepare(mediaSource);

            setupVideoPlayer(eventChannel, textureEntry, result);
        }

        private static boolean isFileOrAsset(Uri uri) {
            if (uri == null || uri.getScheme() == null) {
                return false;
            }
            String scheme = uri.getScheme();
            return scheme.equals("file") || scheme.equals("asset");
        }

        private MediaSource buildMediaSource(
                Uri uri, DataSource.Factory mediaDataSourceFactory, Context context) {

            Download download = videoDownloadManager.getDownloadTracker().getDownload(uri);
            if (download != null && download.state == Download.STATE_COMPLETED) {
                DownloadRequest downloadRequest = download.request;
                return DownloadHelper.createMediaSource(downloadRequest, videoDownloadManager.getLocalDataSourceFactory());
            }

            @C.ContentType int type = Util.inferContentType(uri);
            switch (type) {
                case C.TYPE_SS:
                    return new SsMediaSource.Factory(
                            new DefaultSsChunkSource.Factory(mediaDataSourceFactory),
                            new DefaultDataSourceFactory(context, null, mediaDataSourceFactory))
                            .createMediaSource(MediaItem.fromUri(uri));
                case C.TYPE_DASH:
                    return new DashMediaSource.Factory(
                            new DefaultDashChunkSource.Factory(mediaDataSourceFactory),
                            new DefaultDataSourceFactory(context, null, mediaDataSourceFactory))
                            .createMediaSource(MediaItem.fromUri(uri));
                case C.TYPE_HLS:
                    return new HlsMediaSource.Factory(mediaDataSourceFactory).createMediaSource(MediaItem.fromUri(uri));
                case C.TYPE_OTHER:
                    return new ProgressiveMediaSource.Factory(mediaDataSourceFactory)
                            .createMediaSource(MediaItem.fromUri(uri));
                default: {
                    throw new IllegalStateException("Unsupported type: " + type);
                }
            }
        }

        private void setupVideoPlayer(
                EventChannel eventChannel,
                TextureRegistry.SurfaceTextureEntry textureEntry,
                Result result) {

            eventChannel.setStreamHandler(
                    new EventChannel.StreamHandler() {
                        @Override
                        public void onListen(Object o, EventChannel.EventSink sink) {
                            eventSink.setDelegate(sink);
                        }

                        @Override
                        public void onCancel(Object o) {
                            eventSink.setDelegate(null);
                        }
                    });

            surface = new Surface(textureEntry.surfaceTexture());
            exoPlayer.setVideoSurface(surface);
            setAudioAttributes(exoPlayer);

            exoPlayer.addListener(
                    new Player.Listener() {

                        @Override
                        public void onPlaybackStateChanged(int playbackState) {
                            if (playbackState == Player.STATE_BUFFERING) {
                                sendBufferingStart();
                                sendBufferingUpdate();
                            } else if (playbackState == Player.STATE_READY) {
                                sendBufferingEnd();
                                if (!isInitialized) {
                                    isInitialized = true;
                                    sendInitialized();
                                }
                            } else if (playbackState == Player.STATE_ENDED) {
                                Map<String, Object> event = new HashMap<>();
                                event.put("event", "completed");
                                eventSink.success(event);
                            }
                        }

                        @Override
                        public void onPlayWhenReadyChanged(boolean playWhenReady, int reason) {
                            sendPlayStateChange(playWhenReady);
                        }

                        @Override
                        public void onPlayerError(@NotNull PlaybackException error) {
                            eventSink.error("VideoError", "Video player had error " + error, null);
                        }

                        @Override
                        public void onTimelineChanged(@NotNull Timeline timeline, int reason) {
                            parseManifest(exoPlayer.getCurrentManifest());
                        }

                        @Override
                        public void onTracksChanged(@NotNull TrackGroupArray trackGroups, @NotNull TrackSelectionArray trackSelections) {
                            if (trackSelections != null && trackSelections.length > 0 && trackSelections.get(0) != null) {
                                sendResolutionChange(trackSelections.get(0).getIndexInTrackGroup(0));   //todo 还不知道怎么改
                            }
                        }
                    });

            Map<String, Object> reply = new HashMap<>();
            reply.put("textureId", textureEntry.id());
            result.success(reply);
        }


        private void parseManifest(Object manifest) {
            if (manifest instanceof HlsManifest) {
                HlsManifest hlsManifest = (HlsManifest) manifest;
                Map<Integer, String> map = new HashMap<>();
                for (int i = 0; i < hlsManifest.masterPlaylist.variants.size(); i++) {
                    HlsMasterPlaylist.Variant variant = hlsManifest.masterPlaylist.variants.get(i);
                    String resolution = variant.format.width + "x" + variant.format.height;
                    map.put(i, resolution);
                }
                sendResolutions(map);
            }
        }

        private void sendResolutions(Map<Integer, String> map) {
            Map<String, Object> event = new HashMap<>();
            event.put("event", "resolutions");
            event.put("map", map);
            eventSink.success(event);
        }

        private void sendResolutionChange(int trackIndex) {
            Map<String, Object> event = new HashMap<>();
            event.put("event", "resolutionChange");
            event.put("index", trackIndex);
            eventSink.success(event);
        }

        private void sendBufferingStart() {
            Map<String, Object> event = new HashMap<>();
            event.put("event", "bufferingStart");
            eventSink.success(event);
        }

        private void sendBufferingEnd() {
            Map<String, Object> event = new HashMap<>();
            event.put("event", "bufferingEnd");
            eventSink.success(event);
        }

        private void sendBufferingUpdate() {
            Map<String, Object> event = new HashMap<>();
            event.put("event", "bufferingUpdate");
            List<? extends Number> range = Arrays.asList(0, exoPlayer.getBufferedPosition());
            // iOS supports a list of buffered ranges, so here is a list with a single range.
            event.put("values", Collections.singletonList(range));
            eventSink.success(event);
        }

        private void sendPlayStateChange(boolean playWhenReady) {
            Map<String, Object> event = new HashMap<>();
            event.put("event", "playStateChanged");
            event.put("isPlaying", playWhenReady);
            eventSink.success(event);
        }

        private static void setAudioAttributes(SimpleExoPlayer exoPlayer) {
            exoPlayer.setAudioAttributes(
                    new AudioAttributes.Builder().setContentType(C.CONTENT_TYPE_MOVIE).build(), true);
        }

        void play() {
            if (exoPlayer.getPlaybackState() == Player.STATE_IDLE) {
                exoPlayer.retry();
            } else if (exoPlayer.getPlaybackState() == Player.STATE_ENDED) {
                seekTo(0);
            }
            exoPlayer.setPlayWhenReady(true);
        }

        void pause() {
            exoPlayer.setPlayWhenReady(false);
        }

        void setLooping(boolean value) {
            exoPlayer.setRepeatMode(value ? REPEAT_MODE_ALL : REPEAT_MODE_OFF);
        }

        void setVolume(double value) {
            float bracketedValue = (float) Math.max(0.0, Math.min(1.0, value));
            exoPlayer.setVolume(bracketedValue);
        }

        void seekTo(int location) {
            exoPlayer.seekTo(location);
        }

        long getPosition() {
            return exoPlayer.getCurrentPosition();
        }

        @SuppressWarnings("SuspiciousNameCombination")
        private void sendInitialized() {
            if (isInitialized) {
                Map<String, Object> event = new HashMap<>();
                event.put("event", "initialized");
                event.put("duration", exoPlayer.getDuration());

                if (exoPlayer.getVideoFormat() != null) {
                    Format videoFormat = exoPlayer.getVideoFormat();
                    int width = videoFormat.width;
                    int height = videoFormat.height;
                    int rotationDegrees = videoFormat.rotationDegrees;
                    // Switch the width/height if video was taken in portrait mode
                    if (rotationDegrees == 90 || rotationDegrees == 270) {
                        width = exoPlayer.getVideoFormat().height;
                        height = exoPlayer.getVideoFormat().width;
                    }
                    event.put("width", width);
                    event.put("height", height);
                }
                eventSink.success(event);
            }
        }

        void dispose() {
            if (isInitialized) {
                exoPlayer.stop();
            }
            textureEntry.release();
            eventChannel.setStreamHandler(null);
            if (surface != null) {
                surface.release();
            }
            if (exoPlayer != null) {
                exoPlayer.release();
            }
            if (downloadHelper != null) {
                downloadHelper.release();
            }
            cancelRefreshProgressTimer();
        }

        void setSpeed(double speed) {
            if (!isInitialized) {
                return;
            }
            PlaybackParameters playbackParameters = new PlaybackParameters((float) speed);
            exoPlayer.setPlaybackParameters(playbackParameters);
        }

        /**
         * 切换清晰度
         * https://exoplayer.dev/doc/reference/com/google/android/exoplayer2/trackselection/DefaultTrackSelector.html
         */
        void switchResolution(int trackIndex) {
            if (!isInitialized) {
                return;
            }
            DefaultTrackSelector.Parameters parameters = trackSelector.getParameters();
            MappingTrackSelector.MappedTrackInfo currentMappedTrackInfo = trackSelector.getCurrentMappedTrackInfo();
            if (currentMappedTrackInfo == null || parameters == null) {
                return;
            }
            int videoRendererIndex = 0;
            TrackGroupArray trackGroups = currentMappedTrackInfo.getTrackGroups(videoRendererIndex);
            DefaultTrackSelector.ParametersBuilder parametersBuilder = parameters.buildUpon();
            parametersBuilder.clearSelectionOverrides();
            DefaultTrackSelector.SelectionOverride selectionOverride = new DefaultTrackSelector.SelectionOverride(0, trackIndex);
            parametersBuilder.setSelectionOverride(videoRendererIndex, trackGroups, selectionOverride);
            trackSelector.setParameters(parametersBuilder);
        }

        void initDownloadState(VideoDownloadManager videoDownloadManager) {
            Download download = sendDownloadState(videoDownloadManager);
            if (download != null) {
                //如果在STATE_DOWNLOADING状态，直到下载完成onDownloadsChanged才会回调，所以不能用startRefreshProgressTask()方法
                startRefreshProgressTimer(null);
            }
        }

        private Download sendDownloadState(VideoDownloadManager videoDownloadManager) {
            Download download = videoDownloadManager.getDownloadTracker().getDownload(dataSourceUri);

            Map<String, Object> event = new HashMap<>();
            event.put("event", "downloadState");

            @Download.State int state = download != null ? download.state : Download.STATE_QUEUED;
            if (state == Download.STATE_COMPLETED) {
                event.put("state", GpDownloadState.COMPLETED);
            } else if (state == Download.STATE_DOWNLOADING) {
                event.put("state", GpDownloadState.DOWNLOADING);
                event.put("progress", download.getPercentDownloaded());
            } else if (state == Download.STATE_FAILED) {
                event.put("state", GpDownloadState.ERROR);
            } else {
                event.put("state", GpDownloadState.UNDOWNLOAD);
            }

            eventSink.success(event);

            return download;
        }

        /**
         * 下载指定分辨率视频，暂时只支持hls
         */
        void download(int trackIndex, String downloadNotificationName) {
            if (isFileOrAsset(dataSourceUri)) {
                return;
            }
            int type = Util.inferContentType(dataSourceUri);
            switch (type) {
                case C.TYPE_HLS:
                    downloadHls(trackIndex, downloadNotificationName);
                    break;
                case C.TYPE_DASH:
                case C.TYPE_OTHER:
                case C.TYPE_SS:
                    break;
                default: {
                }
            }
        }

        private void downloadHls(int trackIndex, String downloadNotificationName) {
            if (downloadHelper != null) {
                downloadHelper.release();
            }
            downloadHelper = DownloadHelper.forHls(context, dataSourceUri, dataSourceFactory, renderersFactory);
            downloadHelper.prepare(new DownloadHelper.Callback() {
                @Override
                public void onPrepared(DownloadHelper helper) {
                    MappingTrackSelector.MappedTrackInfo mappedTrackInfo = helper.getMappedTrackInfo(0);
                    for (int periodIndex = 0; periodIndex < helper.getPeriodCount(); periodIndex++) {
                        helper.clearTrackSelections(periodIndex);
                        if (mappedTrackInfo != null) {
                            DefaultTrackSelector.SelectionOverride selectionOverride = new DefaultTrackSelector.SelectionOverride(0, trackIndex);
                            List<DefaultTrackSelector.SelectionOverride> list = new ArrayList<>();
                            list.add(selectionOverride);
                            helper.addTrackSelectionForSingleRenderer(periodIndex, 0, DownloadHelper.getDefaultTrackSelectorParameters(context), list);
                        }
                    }
                    DownloadRequest downloadRequest = helper.getDownloadRequest(Util.getUtf8Bytes(downloadNotificationName));
                    DownloadService.sendAddDownload(context, VideoDownloadService.class, downloadRequest, 0, false);
                }

                @Override
                public void onPrepareError(DownloadHelper helper, IOException e) {
                    e.printStackTrace();
                }
            });

            startRefreshProgressTask();
        }

        private void startRefreshProgressTask() {
            final boolean[] isRunTask = {false};
            videoDownloadManager.getDownloadTracker().addListener(new VideoDownloadTracker.Listener() {
                @Override
                public void onDownloadsChanged() {
                    if (!isRunTask[0]) {
                        startRefreshProgressTimer(this);
                        isRunTask[0] = true;
                    }
                }
            });
        }

        private void startRefreshProgressTimer(VideoDownloadTracker.Listener listener) {
            if (refreshProgressTimer != null) {
                refreshProgressTimer.cancel();
            }
            refreshProgressTimer = new Timer();
            TimerTask timerTask = new TimerTask() {
                @Override
                public void run() {
                    Download download = videoDownloadManager.getDownloadTracker().getDownload(dataSourceUri);
                    sendDownloadState(videoDownloadManager);

                    if (download != null && download.isTerminalState()) {
                        cancelRefreshProgressTimer();
                        if (listener != null) {
                            videoDownloadManager.getDownloadTracker().removeListener(listener);
                        }
                    }
                }
            };
            refreshProgressTimer.schedule(timerTask, 1000, 1000);
        }

        private void cancelRefreshProgressTimer() {
            if (refreshProgressTimer != null) {
                refreshProgressTimer.cancel();
                refreshProgressTimer = null;
            }
        }

        void removeDownload() {
            Download download = videoDownloadManager.getDownloadTracker().getDownload(dataSourceUri);
            if (download != null) {
                DownloadService.sendRemoveDownload(context, VideoDownloadService.class, download.request.id, false);
                videoDownloadManager.getDownloadTracker().addListener(new VideoDownloadTracker.Listener() {
                    @Override
                    public void onDownloadsChanged() {
                        if (videoDownloadManager.getDownloadTracker().getDownloadState(dataSourceUri) == Download.STATE_QUEUED) {
                            sendDownloadState(videoDownloadManager);
                            videoDownloadManager.getDownloadTracker().removeListener(this);
                        }
                    }
                });
//                startRefreshProgressTask();
            }
        }
    }
}
