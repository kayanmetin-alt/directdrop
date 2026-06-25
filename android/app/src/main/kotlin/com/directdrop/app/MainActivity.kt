package com.directdrop.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val mediaExecutor = Executors.newSingleThreadExecutor()
    private var mediaPickerResult: MethodChannel.Result? = null
    private var activeExportResult: MethodChannel.Result? = null
    private var exportCancelled = false
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.directdrop.app/media_picker_events"
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.directdrop.app/media_picker"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFromPhotos" -> launchMediaPicker(result)
                "cancelPhotoExport" -> {
                    exportCancelled = true
                    activeExportResult?.error("cancelled", "Medya hazırlığı iptal edildi.", null)
                    activeExportResult = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.directdrop.app/files"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openDownloadsFolder" -> {
                    val path = call.argument<String>("path")
                    result.success(openDownloadsFolder(path))
                }
                "getDownloadsDirectory" -> {
                    result.success(defaultDownloadsDirectory().absolutePath)
                }
                "openSavedFile" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_args", "Dosya yolu gerekli.", null)
                    } else {
                        result.success(openSavedFile(path))
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.directdrop.app/transfer_session"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startForeground" -> {
                    startTransferForegroundService()
                    result.success(true)
                }
                "stopForeground" -> {
                    stopTransferForegroundService()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun emitExportProgress(
        completed: Int,
        total: Int,
        fraction: Double,
        fileName: String?
    ) {
        runOnUiThread {
            val payload = hashMapOf<String, Any>(
                "phase" to "exporting",
                "completed" to completed,
                "total" to total.coerceAtLeast(1),
                "fraction" to fraction.coerceIn(0.0, 1.0)
            )
            if (!fileName.isNullOrBlank()) {
                payload["fileName"] = fileName
            }
            eventSink?.success(payload)
        }
    }

    private fun startTransferForegroundService() {
        val intent = Intent(this, TransferForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopTransferForegroundService() {
        val intent = Intent(this, TransferForegroundService::class.java).apply {
            action = TransferForegroundService.ACTION_STOP
        }
        startService(intent)
    }

    private fun launchMediaPicker(result: MethodChannel.Result) {
        if (mediaPickerResult != null) {
            result.error("busy", "Seçim zaten açık.", null)
            return
        }
        exportCancelled = false
        mediaPickerResult = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        startActivityForResult(intent, REQUEST_PICK_MEDIA)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_PICK_MEDIA) {
            val pending = mediaPickerResult
            mediaPickerResult = null
            if (pending == null) {
                super.onActivityResult(requestCode, resultCode, data)
                return
            }
            if (resultCode != Activity.RESULT_OK || data == null) {
                pending.success(null)
                return
            }

            val uris = mutableListOf<Uri>()
            data.data?.let { uris.add(it) }
            data.clipData?.let { clip ->
                for (i in 0 until clip.itemCount) {
                    uris.add(clip.getItemAt(i).uri)
                }
            }

            if (uris.isEmpty()) {
                pending.success(null)
                return
            }

            exportCancelled = false
            activeExportResult = pending
            mediaExecutor.execute {
                val paths = mutableListOf<String>()
                val total = uris.size
                emitExportProgress(0, total, 0.0, null)

                for ((index, uri) in uris.withIndex()) {
                    if (exportCancelled) {
                        runOnUiThread {
                            activeExportResult?.error(
                                "cancelled",
                                "Medya hazırlığı iptal edildi.",
                                null
                            )
                            activeExportResult = null
                        }
                        return@execute
                    }

                    val displayName = queryDisplayName(uri)
                    exportUriToCache(uri, index, total, displayName)?.let { paths.add(it) }

                    val overall = (index + 1).toDouble() / total.toDouble()
                    emitExportProgress(index + 1, total, overall, displayName)
                }

                if (exportCancelled) {
                    runOnUiThread {
                        activeExportResult?.error(
                            "cancelled",
                            "Medya hazırlığı iptal edildi.",
                            null
                        )
                        activeExportResult = null
                    }
                    return@execute
                }

                runOnUiThread {
                    activeExportResult?.success(if (paths.isEmpty()) null else paths)
                    activeExportResult = null
                }
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun exportUriToCache(
        uri: Uri,
        index: Int,
        total: Int,
        displayName: String?
    ): String? {
        return try {
            val resolver = applicationContext.contentResolver
            val mime = resolver.getType(uri) ?: "application/octet-stream"
            val extension = when {
                mime.startsWith("video/") -> mime.substringAfter('/').ifBlank { "mp4" }
                mime.contains("jpeg") || mime.contains("jpg") -> "jpg"
                mime.contains("png") -> "png"
                mime.contains("heic") -> "heic"
                mime.contains("webp") -> "webp"
                else -> {
                    val name = displayName
                    name?.substringAfterLast('.', "")?.ifBlank { null } ?: "bin"
                }
            }
            val stamp = SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(Date())
            val name = "${stamp}_${UUID.randomUUID()}.$extension"
            val dir = File(cacheDir, "DirectDrop/MediaPicker").apply { mkdirs() }
            val out = File(dir, name)

            val totalBytes = querySize(uri).coerceAtLeast(0L)
            val input = resolver.openInputStream(uri) ?: return null
            input.use { stream ->
                FileOutputStream(out).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var copied = 0L
                    while (true) {
                        if (exportCancelled) return null
                        val read = stream.read(buffer)
                        if (read <= 0) break
                        output.write(buffer, 0, read)
                        copied += read
                        val itemFraction = if (totalBytes > 0) {
                            copied.toDouble() / totalBytes.toDouble()
                        } else {
                            0.0
                        }
                        val overall = if (total > 0) {
                            (index + itemFraction) / total.toDouble()
                        } else {
                            0.0
                        }
                        emitExportProgress(index, total, overall, displayName)
                    }
                }
            }

            out.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun querySize(uri: Uri): Long {
        val resolver = applicationContext.contentResolver
        resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (index >= 0 && !cursor.isNull(index)) {
                        return cursor.getLong(index)
                    }
                }
            }
        return -1L
    }

    private fun queryDisplayName(uri: Uri): String? {
        val resolver = applicationContext.contentResolver
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) return cursor.getString(index)
                }
            }
        return null
    }

    private fun defaultDownloadsDirectory(): File {
        val publicDownloads = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS
        )
        if (publicDownloads != null) {
            return File(publicDownloads, "DirectDrop").apply { mkdirs() }
        }
        return File(File(filesDir, "app_flutter"), "DirectDrop").apply { mkdirs() }
    }

    private fun downloadsDirectory(customPath: String? = null): File {
        if (!customPath.isNullOrBlank()) {
            return File(customPath).apply { mkdirs() }
        }
        return defaultDownloadsDirectory()
    }

    private fun isPublicDownloadsDirectory(dir: File): Boolean {
        val path = dir.absolutePath.replace('\\', '/')
        if (!path.contains("/Download")) return false
        return !path.contains("/Android/data/")
    }

    private fun openDownloadsFolder(customPath: String? = null): Boolean {
        val downloadsDir = downloadsDirectory(customPath)
        downloadsDir.mkdirs()

        if (isPublicDownloadsDirectory(downloadsDir) &&
            tryOpenPublicDownloadsInFilesApp(downloadsDir)
        ) {
            return true
        }

        val latest = downloadsDir.listFiles()
            ?.filter { it.isFile && !it.name.startsWith('.') }
            ?.maxByOrNull { it.lastModified() }
        if (latest != null && openSavedFile(latest.absolutePath)) return true

        return tryOpenViaFileProvider(downloadsDir)
    }

    private fun tryOpenPublicDownloadsInFilesApp(dir: File): Boolean {
        if (!isPublicDownloadsDirectory(dir)) return false
        val relative = relativeDownloadPath(dir) ?: return false

        val docIds = listOf(
            "primary:Download/$relative",
            "primary:Download"
        )

        for (docId in docIds) {
            val uri = DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents",
                docId
            )
            if (launchViewIntent(uri, DocumentsContract.Document.MIME_TYPE_DIR)) {
                return true
            }
            if (launchViewIntent(uri, "*/*")) {
                return true
            }
        }
        return false
    }

    private fun relativeDownloadPath(dir: File): String? {
        val normalized = dir.absolutePath.replace('\\', '/')
        if (normalized.contains("/Android/data/")) {
            val marker = "/files/Download/"
            val index = normalized.indexOf(marker)
            if (index >= 0) {
                return normalized.substring(index + marker.length).trim('/')
            }
            return null
        }
        val marker = "/Download/"
        val index = normalized.indexOf(marker)
        if (index < 0) return null
        return normalized.substring(index + marker.length).trim('/')
    }

    private fun tryOpenViaFileProvider(dir: File): Boolean {
        return try {
            val marker = File(dir, ".directdrop_folder").apply {
                if (!exists()) writeText("DirectDrop")
            }
            val uri = FileProvider.getUriForFile(
                this,
                "${applicationContext.packageName}.fileprovider",
                marker
            )
            launchViewIntent(uri, "*/*")
        } catch (_: Exception) {
            false
        }
    }

    private fun launchViewIntent(uri: Uri, mime: String): Boolean {
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (intent.resolveActivity(packageManager) == null) return false
        return try {
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun openSavedFile(path: String): Boolean {
        return try {
            val file = File(path)
            if (!file.exists() || !file.isFile) return false

            val uri = FileProvider.getUriForFile(
                this,
                "${applicationContext.packageName}.fileprovider",
                file
            )
            val mime = contentResolver.getType(uri)
                ?: android.webkit.MimeTypeMap.getSingleton()
                    .getMimeTypeFromExtension(file.extension.lowercase(Locale.US))
                ?: "*/*"

            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (intent.resolveActivity(packageManager) == null) return false
            startActivity(Intent.createChooser(intent, file.name))
            true
        } catch (_: Exception) {
            false
        }
    }

    companion object {
        private const val REQUEST_PICK_MEDIA = 1001
    }
}
