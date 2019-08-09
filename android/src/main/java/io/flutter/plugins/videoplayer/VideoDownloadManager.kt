package io.flutter.plugins.videoplayer

import android.annotation.SuppressLint
import android.content.Context
import android.util.Log
import com.google.android.exoplayer2.database.DatabaseProvider
import com.google.android.exoplayer2.database.ExoDatabaseProvider
import com.google.android.exoplayer2.offline.DefaultDownloadIndex
import com.google.android.exoplayer2.offline.DefaultDownloaderFactory
import com.google.android.exoplayer2.offline.DownloadManager
import com.google.android.exoplayer2.offline.DownloaderConstructorHelper
import com.google.android.exoplayer2.upstream.DefaultHttpDataSourceFactory
import com.google.android.exoplayer2.upstream.HttpDataSource
import com.google.android.exoplayer2.upstream.cache.Cache
import com.google.android.exoplayer2.upstream.cache.NoOpCacheEvictor
import com.google.android.exoplayer2.upstream.cache.SimpleCache
import com.google.android.exoplayer2.util.Util
import java.io.File

/**
 * Created by cnting on 2019-08-05
 *
 */
class VideoDownloadManager private constructor(private val context: Context) {

    private val DOWNLOAD_CONTENT_DIRECTORY = "downloads"
    private val userAgent = Util.getUserAgent(context, "ExoPlayerDemo")

    companion object {
        @SuppressLint("StaticFieldLeak")
        @Volatile
        private var instance: VideoDownloadManager? = null

        fun getInstance(context: Context) = instance ?: synchronized(this) {
            instance ?: VideoDownloadManager(context).also { instance = it }
        }
    }


    val downloadManager: DownloadManager by lazy {
        val downloadIndex = DefaultDownloadIndex(databaseProvider)
        val downloaderConstructorHelper = DownloaderConstructorHelper(downloadCache, buildHttpDataSourceFactory)
        val downloadManager = DownloadManager(
                context, downloadIndex, DefaultDownloaderFactory(downloaderConstructorHelper)
        )
        downloadManager
    }

    val downloadTracker: VideoDownloadTracker by lazy {
        val downloadTracker = VideoDownloadTracker(downloadManager)
        downloadTracker
    }

    private val databaseProvider: DatabaseProvider by lazy {
        val p = ExoDatabaseProvider(context)
        p
    }

    private val downloadDirectory: File by lazy {
        var directionality = context.getExternalFilesDir(null)
        if (directionality == null) {
            directionality = context.filesDir
        }
        directionality!!
    }

    val downloadCache: Cache by lazy {
        val downloadContentDirectory = File(downloadDirectory, DOWNLOAD_CONTENT_DIRECTORY)
        val downloadCache = SimpleCache(downloadContentDirectory, NoOpCacheEvictor(), databaseProvider)
        downloadCache
    }

    val buildHttpDataSourceFactory: HttpDataSource.Factory by lazy {
        val factory = DefaultHttpDataSourceFactory(userAgent)
        factory
    }


}