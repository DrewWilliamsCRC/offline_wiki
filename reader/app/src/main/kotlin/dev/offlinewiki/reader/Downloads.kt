package dev.offlinewiki.reader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import java.io.IOException
import java.net.HttpURLConnection
import java.security.MessageDigest
import kotlin.concurrent.thread

/**
 * Downloads a book from the [Catalog] into the reader's [Folder], where [Library] looks for
 * Wikipedia. One book at a time, in [DownloadService], so that it carries on with the app out of
 * sight; this object holds what the screens show of it.
 *
 * Each file arrives as `<name>.part`, and becomes `<name>` only once it is whole and its SHA-256
 * matches the catalog. A `.part` left by a stopped download is carried on from where it ended,
 * with an HTTP range, the next time. The index comes before Wikipedia: alone it is harmless, as
 * the app looks for a .zim, and the .zim then arrives last, complete.
 *
 * A book's older snapshots (the same `<book>_<flavor>`, an earlier date) are an update's to
 * replace: once the new one is in place they are deleted. [Library] reads only the newest anyway.
 */
object Downloads {
    /** What is going on, for the screens. [done] and [total] are bytes of the whole book. */
    class Status(val book: Catalog.Book, val doing: String, val done: Long, val total: Long, val problem: String? = null)

    /** Null when nothing has happened since the app started. Kept after a download ends or fails. */
    @Volatile
    var status: Status? = null
        private set

    @Volatile
    var running = false
        private set

    @Volatile
    private var stopping = false

    @Volatile
    private var connection: HttpURLConnection? = null

    /** The reader's folder, where downloads go; null until one is chosen. The app sets it. */
    @Volatile
    var folder: Folder? = null

    private fun sizeOf(name: String): Long = folder?.size(name) ?: 0
    private fun partOf(file: Catalog.Remote) = file.name + ".part"

    /** The Wikipedia file of [book], as opposed to its index. */
    fun zimOf(book: Catalog.Book): Catalog.Remote = book.files.last { it.name.endsWith(".zim") }

    fun snapshotOf(book: Catalog.Book): Snapshot? = Snapshot.of(zimOf(book).name)

    /** Names of the Wikipedia files of [book] here that are older snapshots than the catalog's, newest first. */
    fun older(book: Catalog.Book): List<String> {
        val date = snapshotOf(book)?.date ?: return emptyList()
        return (folder?.list() ?: emptyList()).map { it.name }.filter { name ->
            val snapshot = Snapshot.of(name)
            snapshot != null && snapshot.book == book.id && snapshot.date < date
        }.sortedDescending()
    }

    /** A Wikipedia file with everything that goes with it: its index, and parts of either. */
    private fun withCompanions(zim: String): List<String> = listOf("", ".idx", ".part", ".idx.part").map { zim + it }

    /** Every file [deleteOlder] or [delete] would remove for [book], whether there or not. */
    fun filesOf(book: Catalog.Book): List<String> =
        older(book).flatMap(::withCompanions) + withCompanions(zimOf(book).name)

    /** Deletes [book]'s older snapshots, to make room for the new one or once it is in place. */
    fun deleteOlder(book: Catalog.Book) = older(book).flatMap(::withCompanions).forEach { folder?.delete(it) }

    /** Deletes all of [book] that is here: every snapshot of it, and any part. */
    fun delete(book: Catalog.Book) = filesOf(book).forEach { folder?.delete(it) }

    /** Bytes the older snapshots of [book] take up, index and all. */
    fun olderSize(book: Catalog.Book): Long = older(book).flatMap(::withCompanions).sumOf(::sizeOf)

    private fun free(): Long = folder?.free() ?: 0

    /** Whether [book] can be downloaded beside what is here, leaving the margin free. */
    fun roomFor(book: Catalog.Book): Boolean = free() >= book.size - have(book) + MARGIN

    /** Whether [book] would fit if its older snapshots were deleted first. */
    fun roomIfReplaced(book: Catalog.Book): Boolean = free() + olderSize(book) >= book.size - have(book) + MARGIN

    /** Whether all of [book] is here: each file at its full size. One copied over USB counts too. */
    fun complete(book: Catalog.Book): Boolean = book.files.all { sizeOf(it.name) == it.size }

    /** How many of [book]'s bytes are here, whole or in a part left by a stopped download. */
    fun have(book: Catalog.Book): Long = book.files.sumOf { file ->
        if (sizeOf(file.name) == file.size) file.size else minOf(sizeOf(partOf(file)), file.size)
    }

    /** Starts downloading [book] in the background, unless a download is already running. */
    fun start(context: Context, book: Catalog.Book) {
        if (running) return
        running = true
        stopping = false
        status = Status(book, "Starting", have(book), book.size)
        val intent = Intent(context, DownloadService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        } catch (e: IllegalStateException) {
            // Android refuses a background download it has given its daily time to already.
            running = false
            status = Status(book, "Stopped", have(book), book.size, "Android will not run the download now: ${e.message ?: e}. Try again later.")
        }
    }

    /** Stops the download as soon as it can. What has arrived is kept, to carry on from. */
    fun stop(why: String? = null) {
        stopping = true
        stoppedFor = why
        // A read waiting on the network ends now, not at its timeout. Off the main thread, which
        // must not touch the network.
        connection?.let { thread { it.disconnect() } }
    }

    @Volatile
    private var stoppedFor: String? = null

    /** The work itself, on the service's thread. */
    internal fun run(context: Context) {
        val book = status?.book ?: return
        try {
            val folder = Folder.chosen(context) ?: throw IOException("Choose a folder for Wikipedia first.")
            this.folder = folder
            ready(context, book)
            for (file in book.files) {
                if (folder.size(file.name) == file.size) continue
                fetch(folder, book, file)
                if (stopping) break
                check(folder, book, file)
                if (stopping) break
                // On the disk before it takes its name: a device that loses power just after
                // must not be left with an empty file that looks finished.
                folder.sync(partOf(file))
                folder.rename(partOf(file), file.name)
            }
            if (!stopping) deleteOlder(book) // an update: the new snapshot is in place and checked
            status = when {
                stopping -> Status(book, "Paused", have(book), book.size, stoppedFor)
                else -> Status(book, "Done", book.size, book.size)
            }
        } catch (e: Exception) {
            status = Status(book, "Stopped", have(book), book.size, e.message ?: e.toString())
        } finally {
            connection = null
            stoppedFor = null
            running = false
        }
    }

    /** Refuses to start without Wi-Fi or without room for what is still to come. */
    private fun ready(context: Context, book: Catalog.Book) {
        val network = context.getSystemService(ConnectivityManager::class.java)
        val capabilities = network.getNetworkCapabilities(network.activeNetwork)
            ?: throw IOException("There is no network. Connect to Wi-Fi and try again.")
        if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) {
            throw IOException("Connect to Wi-Fi first: Wikipedia is too big to download over mobile data.")
        }
        val needed = book.size - have(book) + MARGIN
        val free = free()
        if (free < needed) {
            throw IOException("There is not enough room: this needs ${gb(needed)} more, and ${gb(free)} is free.")
        }
    }

    /** Brings [file]'s part up to its full size, carrying on from what is there. */
    private fun fetch(folder: Folder, book: Catalog.Book, file: Catalog.Remote) {
        val part = partOf(file)
        var failures = 0
        while (!stopping) {
            // Always the size as it is now, never a listing kept from a moment ago: carrying on
            // from the wrong place would put bytes where they do not belong.
            folder.forget()
            var have = folder.size(part)
            if (have > file.size) {
                folder.delete(part)
                have = 0
            }
            if (have == file.size) return
            try {
                val from = have
                val http = Http.open(file.url, from)
                connection = http
                try {
                    val append = when (val code = http.responseCode) {
                        206 -> true
                        200 -> false
                        // A refusal (gone, forbidden) will not change by waiting; anything else may.
                        in 400..499 -> throw Refused("${file.name} cannot be downloaded: the server answered $code")
                        else -> throw IOException("${file.name}: the server answered $code")
                    }
                    if (append && http.getHeaderField("Content-Range")?.startsWith("bytes $from-") != true) {
                        folder.delete(part) // not the part asked for: start again from the beginning
                        continue
                    }
                    val start = if (append) from else 0 // a 200 is everything again, from the start
                    val base = have(book) - have
                    var written = start
                    folder.output(part, fresh = !append).use { out ->
                        http.inputStream.use { input ->
                            val buffer = ByteArray(BUFFER)
                            var shown = 0L
                            while (!stopping) {
                                val n = input.read(buffer)
                                if (n < 0) break
                                out.write(buffer, 0, n)
                                written += n
                                if (written - shown >= STEP) {
                                    shown = written
                                    status = Status(book, "Downloading ${what(file)}", base + written, book.size)
                                }
                            }
                        }
                    }
                    // An answer that brought nothing counts as a failure, so it is not asked again at once.
                    if (written == start && !stopping) throw IOException("${file.name}: the server sent nothing")
                    failures = 0
                } finally {
                    http.disconnect()
                    connection = null
                }
            } catch (e: Refused) {
                throw e
            } catch (e: IOException) {
                if (stopping) return
                // The network comes and goes over hours; give it a while before giving up.
                if (++failures > RETRIES) throw IOException("The download keeps failing: ${e.message}")
                status = Status(book, "Waiting for the network", have(book), book.size)
                val until = System.currentTimeMillis() + minOf(60_000L, 5_000L * failures)
                while (!stopping && System.currentTimeMillis() < until) Thread.sleep(250)
            }
        }
    }

    /** Reads the finished part back and compares its SHA-256 with the catalog's. */
    private fun check(folder: Folder, book: Catalog.Book, file: Catalog.Remote) {
        val part = partOf(file)
        val digest = MessageDigest.getInstance("SHA-256")
        folder.input(part).use { input ->
            val buffer = ByteArray(BUFFER)
            var read = 0L
            var shown = 0L
            while (!stopping) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
                read += n
                if (read - shown >= STEP) {
                    shown = read
                    status = Status(book, "Checking ${what(file)}: ${read * 100 / file.size}%", have(book), book.size)
                }
            }
        }
        if (stopping) return
        val sum = digest.digest().joinToString("") { "%02x".format(it) }
        if (sum != file.sha256) {
            folder.delete(part)
            throw IOException("${file.name} arrived damaged and was deleted. Try again.")
        }
    }

    /** A server's refusal, which retrying will not change. */
    private class Refused(message: String) : IOException(message)

    private fun what(file: Catalog.Remote) = if (file.name.endsWith(".idx")) "the index" else "Wikipedia"

    fun gb(bytes: Long): String = if (bytes >= 1_000_000_000) "%.1f GB".format(bytes / 1e9) else "%.0f MB".format(bytes / 1e6)

    private const val BUFFER = 1 shl 20
    private const val STEP = 4L shl 20        // how often the status changes, in bytes
    private const val RETRIES = 8
    private const val MARGIN = 100_000_000L   // left free, so the device is not filled to the brim
}

/**
 * Runs [Downloads] with the app out of sight: a foreground service, which Android lets live on
 * and shows as a notification, and a wake lock, since a large download outlasts the screen.
 */
class DownloadService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var notifications: NotificationManager

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(
            NotificationChannel(CHANNEL, "Downloads", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) },
        )
    }

    /**
     * Android 15 and later give a download like this six hours a day in the background, then call
     * this; the service must stop within seconds. What has arrived is kept, and Carry on picks it
     * up, which Android allows again once the app has been on screen.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Downloads.stop("Android pauses a download after six hours in the background. Tap Carry on to go on.")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(ONGOING, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(ONGOING, notification())
        }
        val lock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "WikiReader:download")
        lock.acquire(24 * 60 * 60 * 1000L) // released at the end; the limit only guards against a hang
        update()
        thread(name = "download") {
            try {
                Downloads.run(this)
            } finally {
                lock.release()
                main.post(::finish)
            }
        }
        // Not restarted by Android if it is stopped: the download is carried on from the app.
        return START_NOT_STICKY
    }

    /** Keeps the notification's line in step with the download, every few seconds. */
    private fun update() {
        if (!Downloads.running) return
        notifications.notify(ONGOING, notification())
        main.postDelayed(::update, 3_000)
    }

    private fun finish() {
        main.removeCallbacksAndMessages(null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        // Said when it ends, and when Android paused it; not when the reader did.
        Downloads.status?.takeIf { it.doing != "Paused" || it.problem != null }?.let { notifications.notify(ENDED, notification()) }
        stopSelf()
    }

    private fun notification(): Notification {
        val status = Downloads.status
        // As the launcher opens the app: back to where it was, not a second window on top.
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val open = PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE)
        val text = when {
            status == null -> "Starting"
            status.problem != null -> status.problem
            status.doing == "Done" -> "${status.book.title} is ready to read."
            else -> "${status.doing}: ${Downloads.gb(status.done)} of ${Downloads.gb(status.total)}"
        }
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(if (Downloads.running) android.R.drawable.stat_sys_download else android.R.drawable.stat_sys_download_done)
            .setContentTitle(status?.book?.title ?: "Wikipedia")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(Downloads.running)
            .setOnlyAlertOnce(true)
            .setAutoCancel(!Downloads.running)
            .build()
    }

    private companion object {
        const val CHANNEL = "downloads"
        const val ONGOING = 1
        const val ENDED = 2
    }
}
