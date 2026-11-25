// https://github.com/FFmpeg/FFmpeg/blob/master/doc/examples/hw_decode.c
// https://github.com/FFmpeg/FFmpeg/blob/master/doc/examples/decode_video.c

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/log.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/time.h>
#ifdef __ANDROID__
#include <libavcodec/mediacodec.h>
#include <libavutil/hwcontext_mediacodec.h>
#endif
}

#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <stdbool.h>

#define LOG_MODULE "FFMPEG_RAM_DEC"
#include <log.h>
#include <util.h>

#ifdef _WIN32
#include <libavutil/hwcontext_d3d11va.h>
#endif

#include "common.h"
#include "system.h"

// #define CFG_PKG_TRACE

#ifdef __ANDROID__
static_assert(AV_PIX_FMT_MEDIACODEC == 164, "common/ffmpeg_ffi.h has its value");
#endif

namespace {
class FFmpegRamDecoder;
// a decoder's video surface (Android: a JNI global ref to an android.view.Surface,
// the caller's to keep alive while set, one per session shown): a MediaCodec
// decoder opened while its surface is set renders its frames into it
// (ffmpeg_ram_decode_set_surface). A surface takes one decoder: the last one
// opened (at a key frame) takes it over, the one before goes back to waiting
// for its next key frame (a display switch: the old display's decoder stays,
// idle). MediaCodec decoders decode, open and close under mc_mutex, so that a
// takeover never meets a decode.
std::mutex mc_mutex;
std::map<void *, FFmpegRamDecoder *> surface_owners;

typedef void (*RamDecodeCallback)(const void *obj, int width, int height,
                                  enum AVPixelFormat pixfmt,
                                  int linesize[AV_NUM_DATA_POINTERS],
                                  uint8_t *data[AV_NUM_DATA_POINTERS], int key);

class FFmpegRamDecoder {
public:
  AVCodecContext *c_ = NULL;
  AVBufferRef *hw_device_ctx_ = NULL;
  AVFrame *sw_frame_ = NULL;
  AVFrame *frame_ = NULL;
  AVPacket *pkt_ = NULL;
  bool hwaccel_ = true;

  std::string name_;
  AVHWDeviceType device_type_ = AV_HWDEVICE_TYPE_NONE;
  int thread_count_ = 1;
  RamDecodeCallback callback_ = NULL;
  DataFormat data_format_;
  // MediaCodec (FFmpeg 7: its init needs the parameter sets): opened at the
  // first packet that carries them, with that packet as the extradata
  const AVCodec *lazy_codec_ = NULL;
  bool lazy_failed_ = false;
  bool no_surface_ = false; // the surface would not take this decoder
  void *surface_ = NULL;    // the surface to open to
  void *on_surface_ = NULL; // the surface it is open to
  bool mc_ = false;         // a MediaCodec decoder

#ifdef CFG_PKG_TRACE
  int in_ = 0;
  int out_ = 0;
#endif

  FFmpegRamDecoder(const char *name, int device_type, int thread_count,
                   RamDecodeCallback callback) {
    this->name_ = name;
    this->device_type_ = (AVHWDeviceType)device_type;
    this->thread_count_ = thread_count;
    this->callback_ = callback;
  }

  ~FFmpegRamDecoder() {}

  void free_decoder() {
    if (frame_)
      av_frame_free(&frame_);
    if (pkt_)
      av_packet_free(&pkt_);
    if (sw_frame_)
      av_frame_free(&sw_frame_);
    if (c_)
      avcodec_free_context(&c_);
    if (hw_device_ctx_)
      av_buffer_unref(&hw_device_ctx_);

    frame_ = NULL;
    pkt_ = NULL;
    sw_frame_ = NULL;
    c_ = NULL;
    hw_device_ctx_ = NULL;
  }
  int reset() {
    if (name_.find("h264") != std::string::npos) {
      data_format_ = DataFormat::H264;
    } else if (name_.find("hevc") != std::string::npos) {
      data_format_ = DataFormat::H265;
    } else {
      LOG_ERROR(std::string("unsupported data format:") + name_);
      return -1;
    }
    free_decoder();
    const AVCodec *codec = NULL;
    hwaccel_ = device_type_ != AV_HWDEVICE_TYPE_NONE;
    int ret;
    if (!(codec = avcodec_find_decoder_by_name(name_.c_str()))) {
      LOG_ERROR(std::string("avcodec_find_decoder_by_name ") + name_ + " failed");
      return -1;
    }
    if (!(c_ = avcodec_alloc_context3(codec))) {
      LOG_ERROR(std::string("Could not allocate video codec context"));
      return -1;
    }

    c_->flags |= AV_CODEC_FLAG_LOW_DELAY;
    c_->thread_count =
        device_type_ != AV_HWDEVICE_TYPE_NONE ? 1 : thread_count_;
    c_->thread_type = FF_THREAD_SLICE;

    if (name_.find("qsv") != std::string::npos) {
      if ((ret = av_opt_set(c_->priv_data, "async_depth", "1", 0)) < 0) {
        LOG_ERROR(std::string("qsv set opt async_depth 1 failed"));
        return -1;
      }
      // https://github.com/FFmpeg/FFmpeg/blob/c6364b711bad1fe2fbd90e5b2798f87080ddf5ea/libavcodec/qsvdec.c#L932
      // for disable warning
      c_->pkt_timebase = av_make_q(1, 30);
    }

    if (hwaccel_) {
      ret =
          av_hwdevice_ctx_create(&hw_device_ctx_, device_type_, NULL, NULL, 0);
      if (ret < 0) {
        LOG_ERROR(std::string("av_hwdevice_ctx_create failed, ret = ") + av_err2str(ret));
        return -1;
      }
      c_->hw_device_ctx = av_buffer_ref(hw_device_ctx_);
      if (!check_support()) {
        LOG_ERROR(std::string("check_support failed"));
        return -1;
      }
      if (!(sw_frame_ = av_frame_alloc())) {
        LOG_ERROR(std::string("av_frame_alloc failed"));
        return -1;
      }
    }

    if (!(pkt_ = av_packet_alloc())) {
      LOG_ERROR(std::string("av_packet_alloc failed"));
      return -1;
    }

    if (!(frame_ = av_frame_alloc())) {
      LOG_ERROR(std::string("av_frame_alloc failed"));
      return -1;
    }

    lazy_codec_ = NULL;
    lazy_failed_ = false;
    lazy_mc_ = false;
    mc_ = name_.find("mediacodec") != std::string::npos;
    if (mc_) {
      lazy_codec_ = codec;
      return 0;
    }
    if ((ret = avcodec_open2(c_, codec, NULL)) != 0) {
      LOG_ERROR(std::string("avcodec_open2 failed, ret = ") + av_err2str(ret));
      return -1;
    }
#ifdef CFG_PKG_TRACE
    in_ = 0;
    out_ = 0;
#endif

    return 0;
  }

  int decode(const uint8_t *data, int length, const void *obj) {
    int ret = -1;
#ifdef CFG_PKG_TRACE
    in_++;
    LOG_DEBUG(std::string("delay DI: in:") + in_ + " out:" + out_);
#endif

    if (!data || !length || !c_) {
      LOG_ERROR(std::string("illegal decode parameter"));
      return -1;
    }
    if (lazy_codec_) {
      if (lazy_failed_)
        return -1;
      if (!has_parameter_sets(data, length))
        return 0; // nothing to decode until a key frame
      if (lazy_open(data, length) != 0) {
        lazy_failed_ = true;
        return -1;
      }
    }
    pkt_->data = (uint8_t *)data;
    pkt_->size = length;
    ret = do_decode(obj);
    return ret;
  }

private:
  // an Annex B packet with the SPS (H.264 NAL 7, H.265 NAL 33)
  bool has_parameter_sets(const uint8_t *p, int n) {
    for (int i = 0; i + 3 < n; i++) {
      if (p[i] || p[i + 1] || p[i + 2] != 1)
        continue;
      uint8_t h = p[i + 3];
      if (data_format_ == DataFormat::H264 ? (h & 0x1f) == 7
                                           : ((h >> 1) & 0x3f) == 33)
        return true;
    }
    return false;
  }

  int lazy_open(const uint8_t *data, int length) {
    int ret;
    c_->extradata = (uint8_t *)av_mallocz(length + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!c_->extradata)
      return -1;
    memcpy(c_->extradata, data, length);
    c_->extradata_size = length;
    // MediaCodec refuses 0x0; the stream's own size comes with its frames
    if (c_->width == 0 || c_->height == 0) {
      c_->width = 1920;
      c_->height = 1080;
    }
    bool to_surface = false;
#ifdef __ANDROID__
    if (surface_ && !no_surface_) {
      auto owner = surface_owners.find(surface_);
      if (owner != surface_owners.end()) {
        FFmpegRamDecoder *o = owner->second;
        surface_owners.erase(owner);
        if (o != this)
          o->give_up_surface();
      }
      AVBufferRef *dev = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_MEDIACODEC);
      if (dev) {
        AVHWDeviceContext *d = (AVHWDeviceContext *)dev->data;
        ((AVMediaCodecDeviceContext *)d->hwctx)->surface = surface_;
        if (av_hwdevice_ctx_init(dev) == 0) {
          c_->hw_device_ctx = dev;
          to_surface = true;
        } else {
          av_buffer_unref(&dev);
        }
      }
    }
#endif
    if ((ret = avcodec_open2(c_, lazy_codec_, NULL)) != 0) {
      LOG_ERROR(std::string("avcodec_open2 failed, ret = ") + av_err2str(ret) +
                ", name: " + name_);
      if (!to_surface)
        return -1;
      no_surface_ = true; // again, frames returned
      if (reset() != 0)
        return -1;
      return lazy_open(data, length);
    }
    LOG_INFO(std::string("opened ") + name_ +
             (to_surface ? " (to the surface)" : ""));
    if (to_surface) {
      surface_owners[surface_] = this;
      on_surface_ = surface_;
    }
    lazy_codec_ = NULL;
    lazy_mc_ = true;
    return 0;
  }
public:
  // another decoder takes the surface over (or it has another one): closed,
  // opened again at the next key frame (taking the surface back)
  void give_up_surface() {
    LOG_INFO(std::string("surface taken over: ") + name_ + " closed till its next key frame");
    on_surface_ = NULL;
    if (reset() != 0) {
      free_decoder();
      lazy_failed_ = true;
    }
  }

private:
  bool lazy_mc_ = false; // MediaCodec: a packet may give its frame later
  unsigned mc_frames_ = 0; // its frames so far


  int do_decode(const void *obj) {
    int ret;
    AVFrame *tmp_frame = NULL;
    bool decoded = false;

    ret = avcodec_send_packet(c_, pkt_);
    if (ret < 0) {
      LOG_ERROR(std::string("avcodec_send_packet failed, ret = ") + av_err2str(ret));
      return ret;
    }
    auto start = util::now();
    while (ret >= 0 && util::elapsed_ms(start) < ENCODE_TIMEOUT_MS) {
      if ((ret = avcodec_receive_frame(c_, frame_)) != 0) {
        // MediaCodec gives a packet's frame a few ms later: wait for it, so
        // that a frame in gives its picture (the first one too)
        if (lazy_mc_ && ret == AVERROR(EAGAIN) && !decoded &&
            util::elapsed_ms(start) < (mc_frames_ ? 40 : 200)) {
          av_usleep(1000);
          ret = 0;
          continue;
        }
        if (ret != AVERROR(EAGAIN)) {
          LOG_ERROR(std::string("avcodec_receive_frame failed, ret = ") + av_err2str(ret));
        }
        goto _exit;
      }

      if (hwaccel_) {
        if (!frame_->hw_frames_ctx) {
          LOG_ERROR(std::string("hw_frames_ctx is NULL"));
          goto _exit;
        }
        if ((sw_frame_->width != 0 || sw_frame_->height != 0) &&
            (sw_frame_->width != frame_->width ||
             sw_frame_->height != frame_->height)) {
          av_frame_unref(sw_frame_);
        }
        if ((ret = av_hwframe_transfer_data(sw_frame_, frame_, 0)) < 0) {
          LOG_ERROR(std::string("av_hwframe_transfer_data failed, ret = ") +
                    av_err2str(ret));
          goto _exit;
        }

        tmp_frame = sw_frame_;
      } else {
        tmp_frame = frame_;
      }
      decoded = true;
      mc_frames_ += lazy_mc_;
#ifdef __ANDROID__
      // shown on the surface; the frame tells only its size
      if (frame_->format == AV_PIX_FMT_MEDIACODEC)
        av_mediacodec_release_buffer((AVMediaCodecBuffer *)frame_->data[3], 1);
#endif
#ifdef CFG_PKG_TRACE
      out_++;
      LOG_DEBUG(std::string("delay DO: in:") + in_ + " out:" + out_);
#endif
#if FF_API_FRAME_KEY
      int key_frame = frame_->flags & AV_FRAME_FLAG_KEY;
#else
      int key_frame = frame_->key_frame;
#endif

      callback_(obj, tmp_frame->width, tmp_frame->height,
                (AVPixelFormat)tmp_frame->format, tmp_frame->linesize,
                tmp_frame->data, key_frame);
    }
  _exit:
    av_packet_unref(pkt_);
    return decoded || (lazy_mc_ && ret == AVERROR(EAGAIN)) ? 0 : -1;
  }

  bool check_support() {
#ifdef _WIN32
    if (device_type_ == AV_HWDEVICE_TYPE_D3D11VA) {
      if (!c_->hw_device_ctx) {
        LOG_ERROR(std::string("hw_device_ctx is NULL"));
        return false;
      }
      AVHWDeviceContext *deviceContext =
          (AVHWDeviceContext *)hw_device_ctx_->data;
      if (!deviceContext) {
        LOG_ERROR(std::string("deviceContext is NULL"));
        return false;
      }
      AVD3D11VADeviceContext *d3d11vaDeviceContext =
          (AVD3D11VADeviceContext *)deviceContext->hwctx;
      if (!d3d11vaDeviceContext) {
        LOG_ERROR(std::string("d3d11vaDeviceContext is NULL"));
        return false;
      }
      ID3D11Device *device = d3d11vaDeviceContext->device;
      if (!device) {
        LOG_ERROR(std::string("device is NULL"));
        return false;
      }
      std::unique_ptr<NativeDevice> native_ = std::make_unique<NativeDevice>();
      if (!native_) {
        LOG_ERROR(std::string("Failed to create native device"));
        return false;
      }
      if (!native_->Init(0, (ID3D11Device *)device, 0)) {
        LOG_ERROR(std::string("Failed to init native device"));
        return false;
      }
      if (!native_->support_decode(data_format_)) {
        LOG_ERROR(std::string("Failed to check support ") + name_);
        return false;
      }
      return true;
    } else {
      return true;
    }
#else
    return true;
#endif
  }
};

} // namespace

extern "C" void ffmpeg_ram_decode_set_surface(FFmpegRamDecoder *decoder, void *s) {
  std::lock_guard<std::mutex> lock(mc_mutex);
  if (!decoder || decoder->surface_ == s)
    return;
  decoder->surface_ = s;
  decoder->no_surface_ = false; // another one may take it
  if (!decoder->on_surface_)
    return;
  // open to another one: opened again at the next key frame
  auto owner = surface_owners.find(decoder->on_surface_);
  if (owner != surface_owners.end() && owner->second == decoder)
    surface_owners.erase(owner);
  decoder->give_up_surface();
}

extern "C" void ffmpeg_ram_free_decoder(FFmpegRamDecoder *decoder) {
  try {
    if (!decoder)
      return;
    std::unique_lock<std::mutex> lock(mc_mutex, std::defer_lock);
    if (decoder->mc_)
      lock.lock();
    if (decoder->on_surface_) {
      auto owner = surface_owners.find(decoder->on_surface_);
      if (owner != surface_owners.end() && owner->second == decoder)
        surface_owners.erase(owner);
    }
    decoder->free_decoder();
    delete decoder;
    decoder = NULL;
  } catch (const std::exception &e) {
    LOG_ERROR(std::string("ffmpeg_ram_free_decoder exception:") + e.what());
  } catch (...) {
    LOG_ERROR("ffmpeg_ram_free_decoder: unknown exception");
  }
}

extern "C" FFmpegRamDecoder *
ffmpeg_ram_new_decoder(const char *name, int device_type, int thread_count,
                       RamDecodeCallback callback) {
  FFmpegRamDecoder *decoder = NULL;
  try {
    decoder = new FFmpegRamDecoder(name, device_type, thread_count, callback);
    if (decoder) {
      if (decoder->reset() == 0) {
        return decoder;
      }
    }
  } catch (std::exception &e) {
    LOG_ERROR(std::string("new decoder exception:") + e.what());
  } catch (...) {
    LOG_ERROR("ffmpeg_ram_new_decoder: unknown exception");
  }
  if (decoder) {
    decoder->free_decoder();
    delete decoder;
    decoder = NULL;
  }
  return NULL;
}

extern "C" int ffmpeg_ram_decode(FFmpegRamDecoder *decoder, const uint8_t *data,
                                 int length, const void *obj) {
  try {
    std::unique_lock<std::mutex> lock(mc_mutex, std::defer_lock);
    if (decoder->mc_)
      lock.lock();
    int ret = decoder->decode(data, length, obj);
    if (DataFormat::H265 == decoder->data_format_ && util_decode::has_flag_could_not_find_ref_with_poc()) {
      return HWCODEC_ERR_HEVC_COULD_NOT_FIND_POC;
    } else {
      return ret == 0 ? HWCODEC_SUCCESS : HWCODEC_ERR_COMMON;
    }
  } catch (const std::exception &e) {
    LOG_ERROR(std::string("ffmpeg_ram_decode exception:") + e.what());
  } catch (...) {
    LOG_ERROR("ffmpeg_ram_decode: unknown exception");
  }
  return HWCODEC_ERR_COMMON;
}
