package com.example.flutter_app

import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.healthvault/download"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "saveToDownloads") {
                val fileName = call.argument<String>("fileName")
                val bytes = call.argument<ByteArray>("bytes")

                if (fileName != null && bytes != null) {
                    val success = saveExcelToDownloads(fileName, bytes)
                    if (success) {
                        result.success(true)
                    } else {
                        result.error("SAVE_FAILED", "Could not save file to Downloads", null)
                    }
                } else {
                    result.error("INVALID_ARGUMENTS", "Filename or bytes were null", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun saveExcelToDownloads(fileName: String, bytes: ByteArray): Boolean {
        return try {
            val nameWithExt = if (fileName.endsWith(".xlsx")) fileName else "$fileName.xlsx"
            val mimeType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Android 10 (Q) and above: Use MediaStore
                val resolver = contentResolver
                val contentValues = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, nameWithExt)
                    put(MediaStore.Downloads.MIME_TYPE, mimeType)
                    put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }

                val uri: Uri? = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
                uri?.let {
                    resolver.openOutputStream(it)?.use { outputStream ->
                        outputStream.write(bytes)
                    }
                    contentValues.clear()
                    contentValues.put(MediaStore.Downloads.IS_PENDING, 0)
                    resolver.update(it, contentValues, null, null)
                    true
                } ?: false
            } else {
                // Android 9 and below: Use direct file access (requires permission handled in Flutter)
                val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                if (!downloadsDir.exists()) {
                    downloadsDir.mkdirs()
                }
                val file = File(downloadsDir, nameWithExt)
                FileOutputStream(file).use { outputStream ->
                    outputStream.write(bytes)
                }
                true
            }
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }
}
