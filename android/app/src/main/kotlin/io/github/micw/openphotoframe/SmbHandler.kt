package io.github.micw.openphotoframe

import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import jcifs.CIFSContext
import jcifs.Configuration
import jcifs.config.PropertyConfiguration
import jcifs.context.BaseContext
import jcifs.smb.NtlmPasswordAuthenticator
import jcifs.smb.SmbFile
import java.io.File
import java.io.FileOutputStream
import java.util.Properties

class SmbHandler {
    companion object {
        private const val TAG = "SmbHandler"
        private const val CHANNEL = "io.github.micw.openphotoframe/smb"
    }

    fun configureChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "testConnection" -> {
                        val context = buildContext(call.arguments as Map<*, *>)
                        val root = buildRootUrl(call.arguments as Map<*, *>)
                        SmbFile(root, context).listFiles()
                        result.success(true)
                    }
                    "listDirectory" -> {
                        val args = call.arguments as Map<*, *>
                        val context = buildContext(args)
                        val path = normalizePath(args["path"] as String? ?: "")
                        val url = buildFileUrl(args, path, true)
                        val files = SmbFile(url, context).listFiles().orEmpty().map {
                            mapOf(
                                "path" to normalizePath(pathJoin(path, it.name.trimEnd('/'))),
                                "name" to it.name.trimEnd('/'),
                                "isDirectory" to it.isDirectory,
                                "size" to if (it.isDirectory) null else it.length(),
                                "modifiedAt" to java.time.Instant.ofEpochMilli(it.lastModified()).toString(),
                            )
                        }
                        result.success(files)
                    }
                    "downloadFile" -> {
                        val args = call.arguments as Map<*, *>
                        val context = buildContext(args)
                        val remotePath = normalizePath(args["remotePath"] as String? ?: "")
                        val localPath = args["localPath"] as String? ?: throw IllegalArgumentException("localPath is required")
                        val smbFile = SmbFile(buildFileUrl(args, remotePath, false), context)
                        val localFile = File(localPath)
                        localFile.parentFile?.mkdirs()
                        smbFile.inputStream.use { input ->
                            FileOutputStream(localFile).use { output ->
                                input.copyTo(output)
                            }
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.e(TAG, "SMB call failed", e)
                result.error("SMB_ERROR", e.message, null)
            }
        }
    }

    private fun buildContext(args: Map<*, *>): CIFSContext {
        val properties = Properties().apply {
            setProperty("jcifs.smb.client.port139.enabled", "false")
            setProperty("jcifs.smb.client.responseTimeout", "30000")
            setProperty("jcifs.smb.client.connTimeout", "15000")
            setProperty("jcifs.smb.client.soTimeout", "30000")
        }
        val config: Configuration = PropertyConfiguration(properties)
        val base = BaseContext(config)

        val anonymous = args["anonymous"] as Boolean? ?: false
        if (anonymous) {
            return base.withCredentials(NtlmPasswordAuthenticator("", "guest", ""))
        }

        val domain = args["domain"] as String? ?: ""
        val username = args["username"] as String? ?: ""
        val password = args["password"] as String? ?: ""
        return base.withCredentials(NtlmPasswordAuthenticator(domain, username, password))
    }

    private fun buildRootUrl(args: Map<*, *>): String {
        val host = args["host"] as String? ?: throw IllegalArgumentException("host is required")
        val port = (args["port"] as Number?)?.toInt() ?: 445
        val share = (args["share"] as String? ?: throw IllegalArgumentException("share is required")).trim('/')
        return "smb://$host:$port/$share/"
    }

    private fun buildFileUrl(args: Map<*, *>, path: String, directory: Boolean): String {
        val root = buildRootUrl(args)
        if (path.isEmpty()) {
            return root
        }
        val suffix = if (directory) "/" else ""
        return "$root$path$suffix"
    }

    private fun normalizePath(path: String): String {
        var result = path.trim().replace('\\', '/')
        while (result.contains("//")) {
            result = result.replace("//", "/")
        }
        result = result.trim('/')
        return result
    }

    private fun pathJoin(parent: String, name: String): String {
        if (parent.isEmpty()) {
            return name
        }
        return "$parent/$name"
    }
}

