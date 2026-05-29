package com.directdrop.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.directdrop.app/media_picker"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFromPhotos" -> launchMediaPicker(result)
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
    }

    private fun launchMediaPicker(result: MethodChannel.Result) {
        if (mediaPickerResult != null) {
            result.error("busy", "Seçim zaten açık.", null)
            return
        }
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

            mediaExecutor.execute {
                val paths = mutableListOf<String>()
                for (uri in uris) {
                    exportUriToCache(uri)?.let { paths.add(it) }
                }
                runOnUiThread {
                    pending.success(if (paths.isEmpty()) null else paths)
                }
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun exportUriToCache(uri: Uri): String? {
        return try {
            val resolver = applicationContext.contentResolver
            var mime = resolver.getType(uri) ?: "application/octet-stream"
            val extension = when {
                mime.startsWith("video/") -> mime.substringAfter('/').ifBlank { "mp4" }
                mime.contains("jpeg") || mime.contains("jpg") -> "jpg"
                mime.contains("png") -> "png"
                mime.contains("heic") -> "heic"
                mime.contains("webp") -> "webp"
                else -> {
                    val name = queryDisplayName(uri)
                    name?.substringAfterLast('.', "")?.ifBlank { null } ?: "bin"
                }
            }
            val stamp = SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(Date())
            val name = "${stamp}_${UUID.randomUUID()}.$extension"
            val dir = File(cacheDir, "DirectDrop/MediaPicker").apply { mkdirs() }
            val out = File(dir, name)

            resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(out).use { output ->
                    input.copyTo(output)
                }
            } ?: return null

            out.absolutePath
        } catch (_: Exception) {
            null
        }
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

    private fun downloadsDirectory(customPath: String? = null): File {
        if (!customPath.isNullOrBlank()) {
            return File(customPath).apply { mkdirs() }
        }
        // path_provider getApplicationDocumentsDirectory() → filesDir/app_flutter
        return File(File(filesDir, "app_flutter"), "DirectDrop/Downloads").apply { mkdirs() }
    }

    private fun openDownloadsFolder(customPath: String? = null): Boolean {
        return try {
            val downloadsDir = downloadsDirectory(customPath)
            val uri = FileProvider.getUriForFile(
                this,
                "${applicationContext.packageName}.fileprovider",
                downloadsDir
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                true
            } else {
                openDownloadsFallback(downloadsDir)
            }
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

    private fun openDownloadsFallback(downloadsDir: File): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "*/*"
                addCategory(Intent.CATEGORY_OPENABLE)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(Intent.createChooser(intent, "İndirilen dosyalar"))
            true
        } catch (_: Exception) {
            false
        }
    }

    companion object {
        private const val REQUEST_PICK_MEDIA = 1001
    }
}
