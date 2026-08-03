package io.github.micw.openphotoframe

import android.os.Handler
import android.os.Looper
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
import java.util.concurrent.Executors
import java.security.Security
import org.bouncycastle.jce.provider.BouncyCastleProvider

class SmbHandler {
    companion object {
        private const val TAG = "SmbHandler"
        private const val CHANNEL = "io.github.micw.openphotoframe/smb"
    }

    private val executor = Executors.newFixedThreadPool(4)
    private val mainHandler = Handler(Looper.getMainLooper())

    private var cachedKey: String? = null
    private var cachedContext: CIFSContext? = null

    init {
        try {
            if (Security.getProvider("BC")?.javaClass?.name != "org.bouncycastle.jce.provider.BouncyCastleProvider") {
                Security.removeProvider("BC")
                Security.insertProviderAt(BouncyCastleProvider(), 1)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to setup BouncyCastleProvider", e)
        }
    }

    fun configureChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            executor.execute {
                try {
                    when (call.method) {
                        "testConnection" -> {
                            val context = getOrCreateContext(call.arguments as Map<*, *>)
                            val root = buildRootUrl(call.arguments as Map<*, *>)
                            SmbFile(root, context).listFiles()
                            mainHandler.post { result.success(true) }
                        }
                        "listDirectory" -> {
                            val args = call.arguments as Map<*, *>
                            val context = getOrCreateContext(args)
                            val path = normalizePath(args["path"] as String? ?: "")
                            val url = buildFileUrl(args, path, true)
                            val rawFiles = try {
                                SmbFile(url, context).listFiles().orEmpty()
                            } catch (e: Exception) {
                                Log.w(TAG, "listFiles failed for url: $url", e)
                                throw e
                            }
                            val files = mutableListOf<Map<String, Any?>>()
                            for (it in rawFiles) {
                                try {
                                    val name = it.name.trimEnd('/')
                                    if (name.isEmpty() || name.startsWith(".") || name.startsWith("~$") || name.equals("@eaDir", ignoreCase = true)) {
                                        continue
                                    }
                                    val isDir = try {
                                        it.isDirectory || it.name.endsWith("/")
                                    } catch (e: Exception) {
                                        it.name.endsWith("/")
                                    }
                                    val size = if (isDir) null else try { it.length() } catch (e: Exception) { null }
                                    val modifiedAt = try {
                                        java.time.Instant.ofEpochMilli(it.lastModified()).toString()
                                    } catch (e: Exception) {
                                        null
                                    }
                                    files.add(
                                        mapOf(
                                            "path" to normalizePath(pathJoin(path, name)),
                                            "name" to name,
                                            "isDirectory" to isDir,
                                            "size" to size,
                                            "modifiedAt" to modifiedAt,
                                        )
                                    )
                                } catch (e: Exception) {
                                    Log.w(TAG, "Failed to inspect SMB entry ${it.name}", e)
                                }
                            }
                            mainHandler.post { result.success(files) }
                        }
                        "downloadFile" -> {
                            val args = call.arguments as Map<*, *>
                            val context = getOrCreateContext(args)
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
                            mainHandler.post { result.success(true) }
                        }
                        else -> mainHandler.post { result.notImplemented() }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "SMB call failed", e)
                    mainHandler.post { result.error("SMB_ERROR", e.toString(), null) }
                }
            }
        }
    }

    @Synchronized
    private fun getOrCreateContext(args: Map<*, *>): CIFSContext {
        val host = args["host"] as String? ?: ""
        val port = (args["port"] as Number?)?.toInt() ?: 445
        val username = args["username"] as String? ?: ""
        val password = args["password"] as String? ?: ""
        val domain = args["domain"] as String? ?: ""
        val anonymous = args["anonymous"] as Boolean? ?: false

        val key = "$host:$port:$username:$password:$domain:$anonymous"
        val existing = cachedContext
        if (existing != null && cachedKey == key) {
            return existing
        }

        try {
            existing?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error closing previous CIFSContext", e)
        }

        val properties = Properties().apply {
            setProperty("jcifs.smb.client.port139.enabled", "false")
            setProperty("jcifs.smb.client.responseTimeout", "30000")
            setProperty("jcifs.smb.client.connTimeout", "15000")
            setProperty("jcifs.smb.client.soTimeout", "30000")
            setProperty("jcifs.smb.client.attrExpirationPeriod", "30000")
            setProperty("jcifs.smb.client.maxBuffers", "16")
        }
        val config: Configuration = PropertyConfiguration(properties)
        val base = BaseContext(config)

        val ctx = if (anonymous) {
            base.withCredentials(NtlmPasswordAuthenticator("", "guest", ""))
        } else {
            base.withCredentials(NtlmPasswordAuthenticator(domain, username, password))
        }

        cachedKey = key
        cachedContext = ctx
        return ctx
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
