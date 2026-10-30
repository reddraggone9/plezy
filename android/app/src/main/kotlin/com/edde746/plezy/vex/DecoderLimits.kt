package com.edde746.plezy.vex

import android.app.Activity
import android.content.Context
import android.hardware.display.DisplayManager
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build
import android.view.Display
import com.edde746.plezy.shared.MediaCodecQuery
import java.util.Locale
import kotlin.math.max
import kotlin.math.min

/**
 * Vex fork: what the device's *hardware* video decoders can actually play, per codec, plus the
 * physical display size. The Dart side turns this into Jellyfin `CodecProfiles`, so the server
 * transcodes anything the hardware cannot decode instead of mpv falling back to a software decode.
 */
internal object DecoderLimits {
  private val MIME_TYPES = linkedMapOf(
    "h264" to "video/avc",
    "hevc" to "video/hevc",
    "av1" to "video/av01",
    "vp9" to "video/x-vnd.on2.vp9",
    "vp8" to "video/x-vnd.on2.vp8",
    "mpeg2video" to "video/mpeg2",
    "mpeg4" to "video/mp4v-es"
  )

  fun probe(context: Context): Map<String, Any> {
    val codecs = HashMap<String, Any>()
    val infos = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
    for ((codec, mime) in MIME_TYPES) {
      val limits = infos
        .filter { !it.isEncoder && MediaCodecQuery.isHardwareAccelerated(it) }
        .filter { info -> info.supportedTypes.any { it.equals(mime, ignoreCase = true) } }
        .mapNotNull { info -> limitsFor(info, info.supportedTypes.first { it.equals(mime, ignoreCase = true) }) }
        .maxByOrNull { (it["maxWidth"] as Int) * (it["maxHeight"] as Int) }
      if (limits != null) codecs[codec] = limits
    }
    return mapOf("codecs" to codecs, "display" to displayInfo(context))
  }

  private fun limitsFor(info: MediaCodecInfo, type: String): Map<String, Any>? {
    val caps = try {
      info.getCapabilitiesForType(type)
    } catch (e: IllegalArgumentException) {
      return null
    }
    val video = caps.videoCapabilities ?: return null
    fun supports(w: Int, h: Int, fps: Double) = try {
      video.areSizeAndRateSupported(w, h, fps)
    } catch (e: IllegalArgumentException) {
      false
    }
    val profiles = caps.profileLevels.map { it.profile }.toSet()
    val tenBit = when (type.lowercase(Locale.ROOT)) {
      "video/hevc" -> MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10 in profiles
      "video/avc" -> MediaCodecInfo.CodecProfileLevel.AVCProfileHigh10 in profiles
      "video/av01" -> MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10 in profiles
      "video/x-vnd.on2.vp9" -> MediaCodecInfo.CodecProfileLevel.VP9Profile2 in profiles
      else -> false
    }
    return mapOf(
      "name" to info.name,
      "maxWidth" to video.supportedWidths.upper,
      "maxHeight" to video.supportedHeights.upper,
      "uhd60" to supports(3840, 2160, 60.0),
      "uhd30" to supports(3840, 2160, 30.0),
      "fhd60" to supports(1920, 1080, 60.0),
      "fhd30" to supports(1920, 1080, 30.0),
      "tenBit" to tenBit
    )
  }

  @Suppress("DEPRECATION")
  private fun displayInfo(context: Context): Map<String, Any> {
    val display: Display? = if (context is Activity && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) context.display
      else context.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
    var longSide = 0
    var shortSide = 0
    val hdr = ArrayList<String>()
    if (display != null) {
      // TVs switch modes for playback, so the largest supported mode is the real ceiling.
      for (mode in display.supportedModes + display.mode) {
        val l = max(mode.physicalWidth, mode.physicalHeight)
        val s = min(mode.physicalWidth, mode.physicalHeight)
        if (l * s > longSide * shortSide) {
          longSide = l
          shortSide = s
        }
      }
      display.hdrCapabilities?.supportedHdrTypes?.forEach { type ->
        when (type) {
          Display.HdrCapabilities.HDR_TYPE_HDR10 -> hdr.add("HDR10")
          Display.HdrCapabilities.HDR_TYPE_HLG -> hdr.add("HLG")
          Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION -> hdr.add("DOVI")
          Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS -> hdr.add("HDR10Plus")
        }
      }
    }
    return mapOf("longSide" to longSide, "shortSide" to shortSide, "hdr" to hdr)
  }
}
