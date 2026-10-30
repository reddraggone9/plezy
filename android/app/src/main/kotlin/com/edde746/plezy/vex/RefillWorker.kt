package com.edde746.plezy.vex

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.edde746.plezy.UserCertificateChannel
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.util.concurrent.TimeUnit

/** Only prepares/enqueues downloads. background_downloader owns the actual transfers. */
class RefillWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
  override suspend fun doWork(): Result = withContext(Dispatchers.Main) {
    var engine: FlutterEngine? = null
    try {
      val ok = withTimeout(TimeUnit.MINUTES.toMillis(8)) {
        val existing = RefillBridge.foreground
        if (existing != null) {
          val result = CompletableDeferred<Boolean>()
          existing.invokeMethod("refill", null, object : MethodChannel.Result {
            override fun success(value: Any?) { result.complete(value == true) }
            override fun error(code: String, message: String?, details: Any?) { result.complete(false) }
            override fun notImplemented() { result.complete(false) }
          })
          result.await()
        } else {
          val done = CompletableDeferred<Boolean>()
          RefillBridge.headless = done
          val loader = FlutterInjector.instance().flutterLoader()
          loader.startInitialization(applicationContext)
          loader.ensureInitializationComplete(applicationContext, null)
          val headlessEngine = FlutterEngine(applicationContext)
          engine = headlessEngine
          UserCertificateChannel().attach(headlessEngine.dartExecutor.binaryMessenger)
          MethodChannel(headlessEngine.dartExecutor.binaryMessenger, "com.plezy/device").setMethodCallHandler { call, result ->
            when (call.method) {
              "vexGetDecoderLimits" -> result.success(DecoderLimits.probe(applicationContext))
              else -> result.notImplemented()
            }
          }
          RefillBridge.attach(headlessEngine, applicationContext, foregroundEngine = false)
          headlessEngine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "vexBackgroundRefill")
          )
          done.await()
        }
      }
      Log.i("VexRefill", "Background refill finished: success=$ok, headless=${engine != null}")
      if (ok) Result.success() else retryOrFail()
    } catch (error: Exception) {
      Log.w("VexRefill", "Background refill stopped", error)
      retryOrFail()
    } finally {
      engine?.destroy()
      if (engine != null || RefillBridge.headless != null) {
        RefillBridge.headless?.complete(false)
        RefillBridge.headless = null
      }
    }
  }

  private fun retryOrFail(): Result = if (runAttemptCount < 2) Result.retry() else Result.failure()
}

/** The UI and worker share one downloader owner, never two simultaneous engines. */
internal object RefillBridge {
  const val WORK_NAME = "vex_keep_synced_refill"
  var foreground: MethodChannel? = null
  var headless: CompletableDeferred<Boolean>? = null

  fun request() = PeriodicWorkRequestBuilder<RefillWorker>(6, TimeUnit.HOURS)
    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).setRequiresBatteryNotLow(true).build())
    .build()

  fun attach(engine: FlutterEngine, context: Context, foregroundEngine: Boolean = true) {
    val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.plezy.vex/refill")
    if (foregroundEngine) foreground = channel
    channel.setMethodCallHandler { call, result ->
      when (call.method) {
        "schedule" -> {
          // WorkManager cannot express Wi-Fi-only without wrongly excluding
          // metered Wi-Fi. Use CONNECTED; upstream's Dart gate and the native
          // downloader's requiresWiFi enforce the *existing* setting.
          WorkManager.getInstance(context.applicationContext).enqueueUniquePeriodicWork(
            WORK_NAME,
            ExistingPeriodicWorkPolicy.KEEP,
            request()
          )
          result.success(null)
        }
        "awaitHeadless" -> {
          val pending = headless
          if (pending == null) result.success(null)
          else pending.invokeOnCompletion { android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(null) } }
        }
        "finish" -> { headless?.complete(call.arguments == true); result.success(null) }
        else -> result.notImplemented()
      }
    }
    engine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
      override fun onPreEngineRestart() {}
      override fun onEngineWillDestroy() { if (foreground === channel) foreground = null }
    })
  }
}
