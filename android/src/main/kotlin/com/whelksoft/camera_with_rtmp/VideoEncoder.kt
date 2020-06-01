package com.whelksoft.camera_with_rtmp

import android.graphics.ImageFormat
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Pair
import android.view.Surface
import androidx.annotation.RequiresApi
import com.pedro.encoder.BaseEncoder
import com.pedro.encoder.Frame
import com.pedro.encoder.input.video.FpsLimiter
import com.pedro.encoder.input.video.GetCameraData
import com.pedro.encoder.utils.CodecUtil
import com.pedro.encoder.utils.yuv.YUVUtil
import com.pedro.encoder.video.FormatVideoEncoder
import com.pedro.encoder.video.GetVideoData
import java.io.IOException
import java.nio.ByteBuffer
import java.util.ArrayList
import java.util.List
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.BlockingQueue

class VideoEncoder(val getVideoData: GetVideoData, val width: Int, val height: Int, var fps: Int, var bitrate: Int, val rotation: Int, val doRotation: Boolean, val iFrameInterval: Int, val formatVideoEncoder: FormatVideoEncoder, val avcProfile: Int = -1, val avcProfileLevel: Int = -1) {
    private var spsPpsSetted = false

    // surface to buffer encoder
    var surface: Surface? = null

    // for disable video
    private val fpsLimiter: FpsLimiter = FpsLimiter()
    var type: String = CodecUtil.H264_MIME
    private var handlerThread: HandlerThread = HandlerThread(TAG)
    private val queue: BlockingQueue<Frame> = ArrayBlockingQueue(80)
    protected var codec: MediaCodec? = null
    private var callback: MediaCodec.Callback? = null
    private var isBufferMode: Boolean = false
    protected var presentTimeUs: Long = 0
    var force: CodecUtil.Force = CodecUtil.Force.FIRST_COMPATIBLE_FOUND
    private val bufferInfo: MediaCodec.BufferInfo = MediaCodec.BufferInfo()

    @kotlin.jvm.Volatile
    protected var running = false

    // The fps to limit at
    var limitFps = fps

    /**
     * Prepare encoder.
     */
    @kotlin.jvm.JvmOverloads
    fun prepare(): Boolean {
        val encoder: MediaCodecInfo? = chooseEncoder(type)
        var videoEncoder: FormatVideoEncoder? = this.formatVideoEncoder
        return try {
            if (encoder != null) {
                codec = MediaCodec.createByCodecName(encoder.getName())
                if (videoEncoder == FormatVideoEncoder.YUV420Dynamical) {
                    videoEncoder = chooseColorDynamically(encoder)
                    if (videoEncoder == null) {
                        Log.e(TAG, "YUV420 dynamical choose failed")
                        return false
                    }
                }
            } else {
                Log.e(TAG, "Valid encoder not found")
                return false
            }
            val videoFormat: MediaFormat
            //if you dont use mediacodec rotation you need swap width and height in rotation 90 or 270
            // for correct encoding resolution
            val resolution: String
            resolution = height.toString() + "x" + width
            videoFormat = MediaFormat.createVideoFormat(type, height, width)
            Log.i(TAG, "Prepare video info: " + videoEncoder!!.name.toString() + ", " + resolution)
            videoFormat.setInteger(MediaFormat.KEY_COLOR_FORMAT,
                    videoEncoder!!.getFormatCodec())
            videoFormat.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 0)
            videoFormat.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            videoFormat.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            videoFormat.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, iFrameInterval)
            videoFormat.setInteger(MediaFormat.KEY_ROTATION, rotation)
            if (this.avcProfile > 0 && this.avcProfileLevel > 0) {
                // MediaFormat.KEY_PROFILE, API > 21
                videoFormat.setInteger(MediaFormat.KEY_PROFILE, this.avcProfile)
                // MediaFormat.KEY_LEVEL, API > 23
                videoFormat.setInteger(MediaFormat.KEY_LEVEL, this.avcProfileLevel)
            }
            codec!!.configure(videoFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            running = false
            if (videoEncoder === FormatVideoEncoder.SURFACE) {
                isBufferMode = false
                surface = codec!!.createInputSurface()
            }
            Log.i(TAG, "prepared")
            true
        } catch (e: IOException) {
            Log.e(TAG, "Create VideoEncoder failed.", e)
            false
        } catch (e: IllegalStateException) {
            Log.e(TAG, "Create VideoEncoder failed.", e)
            false
        }
    }

    fun start() {
        spsPpsSetted = false
        presentTimeUs = System.nanoTime() / 1000
        fpsLimiter.setFPS(limitFps)
        if (formatVideoEncoder !== FormatVideoEncoder.SURFACE) {
            YUVUtil.preAllocateBuffers(width * height * 3 / 2)
        }
        handlerThread.start()
        val handler = Handler(handlerThread.getLooper())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            createAsyncCallback()
            codec!!.setCallback(callback, handler)
            codec!!.start()
        } else {
            codec!!.start()
            handler.post(Runnable {
                while (running) {
                    try {
                        getDataFromEncoder(null)
                    } catch (e: IllegalStateException) {
                        Log.i(TAG, "Encoding error", e)
                    }
                }
            })
        }
        running = true
        Log.i(TAG, "started")
    }

    protected fun stopImp() {
        if (handlerThread != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
                handlerThread.quitSafely()
            } else {
                handlerThread.quit()
            }
        }
        queue.clear()
        spsPpsSetted = false
        surface = null
        Log.i(TAG, "stopped")
    }

    fun stop() {
        running = false
        codec = try {
            codec!!.stop()
            codec!!.release()
            stopImp()
            null
        } catch (e: IllegalStateException) {
            null
        } catch (e: NullPointerException) {
            null
        }
    }

    fun reset() {
        stop()
        prepare()
        start()
    }

    private fun chooseColorDynamically(mediaCodecInfo: MediaCodecInfo): FormatVideoEncoder? {
        for (color in mediaCodecInfo.getCapabilitiesForType(type).colorFormats) {
            if (color == FormatVideoEncoder.YUV420PLANAR.getFormatCodec()) {
                return FormatVideoEncoder.YUV420PLANAR
            } else if (color == FormatVideoEncoder.YUV420SEMIPLANAR.getFormatCodec()) {
                return FormatVideoEncoder.YUV420SEMIPLANAR
            }
        }
        return null
    }

    @RequiresApi(api = Build.VERSION_CODES.KITKAT)
    fun setVideoBitrateOnFly(bitrate: Int) {
        if (running) {
            this.bitrate = bitrate
            val bundle = Bundle()
            bundle.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrate)
            try {
                codec!!.setParameters(bundle)
            } catch (e: IllegalStateException) {
                Log.e(TAG, "encoder need be running", e)
            }
        }
    }

    @RequiresApi(api = Build.VERSION_CODES.KITKAT)
    fun forceSyncFrame() {
        if (running) {
            val bundle = Bundle()
            bundle.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            try {
                codec!!.setParameters(bundle)
            } catch (e: IllegalStateException) {
                Log.e(TAG, "encoder need be running", e)
            }
        }
    }

    fun getInputSurface(): Surface? {
        return surface
    }

    fun setInputSurface(inputSurface: Surface?) {
        this.surface = surface
    }

    fun inputYUVData(frame: Frame?) {
        if (running && !queue.offer(frame)) {
            Log.i(TAG, "frame discarded")
        }
    }

    private fun sendSPSandPPS(mediaFormat: MediaFormat) {
        //H265
        if (type!!.equals(CodecUtil.H265_MIME)) {
            val byteBufferList = extractVpsSpsPpsFromH265(mediaFormat.getByteBuffer("csd-0"))
            getVideoData.onSpsPpsVps(byteBufferList!![1], byteBufferList[2], byteBufferList[0])
            //H264
        } else {
            getVideoData.onSpsPps(mediaFormat.getByteBuffer("csd-0"), mediaFormat.getByteBuffer("csd-1"))
        }
    }

    /**
     * choose the video encoder by mime.
     */
    protected fun chooseEncoder(mime: String): MediaCodecInfo? {
        val mediaCodecInfoList: List<MediaCodecInfo>? = if (force === CodecUtil.Force.HARDWARE) {
            CodecUtil.getAllHardwareEncoders(mime) as List<MediaCodecInfo>
        } else if (force === CodecUtil.Force.SOFTWARE) {
            CodecUtil.getAllSoftwareEncoders(mime) as List<MediaCodecInfo>
        } else {
            CodecUtil.getAllEncoders(mime) as List<MediaCodecInfo>
        }
        for (mci in mediaCodecInfoList!!) {
            Log.i(TAG, String.format("VideoEncoder %s", mci.getName()))
            val codecCapabilities: MediaCodecInfo.CodecCapabilities = mci.getCapabilitiesForType(mime)
            for (color in codecCapabilities.colorFormats) {
                Log.i(TAG, "Color supported: $color")
                if (formatVideoEncoder === FormatVideoEncoder.SURFACE) {
                    if (color == FormatVideoEncoder.SURFACE.getFormatCodec()) return mci
                } else {
                    //check if encoder support any yuv420 color
                    if (color == FormatVideoEncoder.YUV420PLANAR.getFormatCodec()
                            || color == FormatVideoEncoder.YUV420SEMIPLANAR.getFormatCodec()) {
                        return mci
                    }
                }
            }
        }
        return null
    }

    /**
     * decode sps and pps if the encoder never call to MediaCodec.INFO_OUTPUT_FORMAT_CHANGED
     */
    private fun decodeSpsPpsFromBuffer(outputBuffer: ByteBuffer, length: Int): Pair<ByteBuffer, ByteBuffer>? {
        var mSPS: ByteArray? = null
        var mPPS: ByteArray? = null
        val csd = ByteArray(length)
        outputBuffer.get(csd, 0, length)
        var i = 0
        var spsIndex = -1
        var ppsIndex = -1
        while (i < length - 4) {
            if (csd[i].toInt() == 0 && csd[i + 1].toInt() == 0 && csd[i + 2].toInt() == 0 && csd[i + 3].toInt() == 1) {
                if (spsIndex.toInt() == -1) {
                    spsIndex = i
                } else {
                    ppsIndex = i
                    break
                }
            }
            i++
        }
        if (spsIndex != -1 && ppsIndex != -1) {
            mSPS = ByteArray(ppsIndex)
            System.arraycopy(csd, spsIndex, mSPS, 0, ppsIndex)
            mPPS = ByteArray(length - ppsIndex)
            System.arraycopy(csd, ppsIndex, mPPS, 0, length - ppsIndex)
        }
        return if (mSPS != null && mPPS != null) {
            Pair(ByteBuffer.wrap(mSPS), ByteBuffer.wrap(mPPS))
        } else null
    }

    /**
     * You need find 0 0 0 1 byte sequence that is the initiation of vps, sps and pps
     * buffers.
     *
     * @param csd0byteBuffer get in mediacodec case MediaCodec.INFO_OUTPUT_FORMAT_CHANGED
     * @return list with vps, sps and pps
     */
    private fun extractVpsSpsPpsFromH265(csd0byteBuffer: ByteBuffer): List<ByteBuffer> {
        val byteBufferList: MutableList<ByteBuffer> = mutableListOf<ByteBuffer>()
        var vpsPosition = -1
        var spsPosition = -1
        var ppsPosition = -1
        var contBufferInitiation = 0
        val csdArray: ByteArray = csd0byteBuffer.array()
        for (i in csdArray.indices) {
            if (contBufferInitiation.toInt() == 3 && csdArray[i].toInt() == 1) {
                if (vpsPosition.toInt() == -1) {
                    vpsPosition = i - 3
                } else if (spsPosition.toInt() == -1) {
                    spsPosition = i - 3
                } else {
                    ppsPosition = i - 3
                }
            }
            if (csdArray[i].toInt() == 0) {
                contBufferInitiation++
            } else {
                contBufferInitiation = 0
            }
        }
        val vps = ByteArray(spsPosition)
        val sps = ByteArray(ppsPosition - spsPosition)
        val pps = ByteArray(csdArray.size - ppsPosition)
        for (i in csdArray.indices) {
            if (i < spsPosition) {
                vps[i] = csdArray[i]
            } else if (i < ppsPosition) {
                sps[i - spsPosition] = csdArray[i]
            } else {
                pps[i - ppsPosition] = csdArray[i]
            }
        }
        byteBufferList.add(ByteBuffer.wrap(vps))
        byteBufferList.add(ByteBuffer.wrap(sps))
        byteBufferList.add(ByteBuffer.wrap(pps))
        return byteBufferList as List<ByteBuffer>
    }

    @kotlin.jvm.Throws(IllegalStateException::class)
    protected fun getDataFromEncoder(frame: Frame?) {
        if (isBufferMode) {
            val inBufferIndex: Int = codec!!.dequeueInputBuffer(0)
            if (inBufferIndex >= 0) {
                inputAvailable(codec!!, inBufferIndex, frame)
            }
        }
        while (running) {
            val outBufferIndex: Int = codec!!.dequeueOutputBuffer(bufferInfo, 0)
            if (outBufferIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val mediaFormat: MediaFormat = codec!!.getOutputFormat()
                formatChanged(codec!!, mediaFormat)
            } else if (outBufferIndex >= 0) {
                outputAvailable(codec!!, outBufferIndex, bufferInfo)
            } else {
                break
            }
        }
    }

    protected fun getInputFrame(): Frame {
        val frame: Frame = queue.take()
        if (fpsLimiter.limitFPS()) return getInputFrame()
        var buffer: ByteArray = frame.getBuffer()
        val isYV12 = frame.getFormat() === ImageFormat.YV12
        if (!doRotation) {
            var orientation: Int = if (frame.isFlip()) frame.getOrientation() + 180 else frame.getOrientation()
            if (orientation >= 360) orientation -= 360
            buffer = if (isYV12) {
                YUVUtil.rotateYV12(buffer, width, height, orientation)
            } else {
                YUVUtil.rotateNV21(buffer, width, height, orientation)
            }
        }
        buffer = if (isYV12) {
            YUVUtil.YV12toYUV420byColor(buffer, width, height, formatVideoEncoder)
        } else {
            YUVUtil.NV21toYUV420byColor(buffer, width, height, formatVideoEncoder)
        }
        frame.setBuffer(buffer)
        return frame
    }

    @kotlin.jvm.Throws(IllegalStateException::class)
    private fun processInput(byteBuffer: ByteBuffer, mediaCodec: MediaCodec,
                             inBufferIndex: Int, frame: Frame?) {
        var myFrame: Frame? = frame
        try {
            if (myFrame == null) myFrame = getInputFrame()
            byteBuffer.clear()
            byteBuffer.put(myFrame.getBuffer(), myFrame.getOffset(), myFrame.getSize())
            val pts: Long = System.nanoTime() / 1000 - presentTimeUs
            mediaCodec.queueInputBuffer(inBufferIndex, 0, myFrame.getSize(), pts, 0)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }


    fun formatChanged(mediaCodec: MediaCodec, mediaFormat: MediaFormat) {
        getVideoData.onVideoFormat(mediaFormat)
        sendSPSandPPS(mediaFormat)
        spsPpsSetted = true
    }

    protected fun checkBuffer(byteBuffer: ByteBuffer,
                              bufferInfo: MediaCodec.BufferInfo) {
        if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG !== 0) {
            if (!spsPpsSetted) {
                val buffers: Pair<ByteBuffer, ByteBuffer>? = decodeSpsPpsFromBuffer(byteBuffer.duplicate(), bufferInfo.size)
                if (buffers != null) {
                    getVideoData.onSpsPps(buffers.first, buffers.second)
                    spsPpsSetted = true
                }
            }
        }
    }

    protected fun sendBuffer(byteBuffer: ByteBuffer,
                             bufferInfo: MediaCodec.BufferInfo) {
        bufferInfo.presentationTimeUs = System.nanoTime() / 1000 - presentTimeUs
        getVideoData.getVideoData(byteBuffer, bufferInfo)
    }

    @kotlin.jvm.Throws(IllegalStateException::class)
    private fun processOutput(byteBuffer: ByteBuffer, mediaCodec: MediaCodec,
                              outBufferIndex: Int, bufferInfo: MediaCodec.BufferInfo) {
        checkBuffer(byteBuffer, bufferInfo)
        sendBuffer(byteBuffer, bufferInfo)
        mediaCodec.releaseOutputBuffer(outBufferIndex, false)
    }


    @RequiresApi(api = Build.VERSION_CODES.M)
    private fun createAsyncCallback() {
        callback = object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(mediaCodec: MediaCodec, inBufferIndex: Int) {
                try {
                    inputAvailable(mediaCodec, inBufferIndex, null)
                } catch (e: IllegalStateException) {
                    Log.i(TAG, "Encoding error", e)
                }
            }

            override fun onOutputBufferAvailable(mediaCodec: MediaCodec, outBufferIndex: Int,
                                                 bufferInfo: MediaCodec.BufferInfo) {
                try {
                    outputAvailable(mediaCodec, outBufferIndex, bufferInfo)
                } catch (e: IllegalStateException) {
                    Log.i(TAG, "Encoding error", e)
                }
            }

            override fun onError(mediaCodec: MediaCodec, e: MediaCodec.CodecException) {
                Log.e(TAG, "Error", e)
            }

            override fun onOutputFormatChanged(mediaCodec: MediaCodec,
                                               mediaFormat: MediaFormat) {
                formatChanged(mediaCodec, mediaFormat)
            }
        }
    }

    fun inputAvailable(mediaCodec: MediaCodec, inBufferIndex: Int, frame: Frame?) {
        val byteBuffer: ByteBuffer
        byteBuffer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            mediaCodec.getInputBuffer(inBufferIndex)
        } else {
            mediaCodec.getInputBuffers().get(inBufferIndex)
        }
        processInput(byteBuffer, mediaCodec, inBufferIndex, frame)
    }

    fun outputAvailable(mediaCodec: MediaCodec, outBufferIndex: Int,
                        bufferInfo: MediaCodec.BufferInfo) {
        val byteBuffer: ByteBuffer
        byteBuffer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            mediaCodec.getOutputBuffer(outBufferIndex)
        } else {
            mediaCodec.getOutputBuffers().get(outBufferIndex)
        }
        processOutput(byteBuffer, mediaCodec, outBufferIndex, bufferInfo)
    }

    companion object {
        private val TAG: String? = "WSVideoEncoder"
    }
}