package com.edde746.plezy.vex

import androidx.work.NetworkType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE)
class RefillScheduleTest {
  @Test
  fun permitsMeteredWifiAndLeavesWifiPolicyToUpstreamsDownloader() {
    val spec = RefillBridge.request().workSpec
    // UNMETERED would silently change the user's Wi-Fi-only setting.
    assertEquals(NetworkType.CONNECTED, spec.constraints.requiredNetworkType)
    assertTrue(spec.constraints.requiresBatteryNotLow())
    assertEquals(TimeUnit.HOURS.toMillis(6), spec.intervalDuration)
    assertEquals(RefillWorker::class.java.name, spec.workerClassName)
  }
}
