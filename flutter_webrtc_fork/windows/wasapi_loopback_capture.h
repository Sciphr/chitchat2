#pragma once

#include <atomic>
#include <thread>

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audiopolicy.h>
#include <functiondiscoverykeys_devpkey.h>

#include "rtc_audio_source.h"
#include "rtc_types.h"

namespace flutter_webrtc_plugin {

// Captures system audio (loopback) from the default render endpoint and feeds
// it into an RTCAudioSource so it can be transmitted via WebRTC.
class WasapiLoopbackCapture {
 public:
  explicit WasapiLoopbackCapture(
      libwebrtc::scoped_refptr<libwebrtc::RTCAudioSource> source);
  ~WasapiLoopbackCapture();

  // Starts the capture thread. Returns true on success.
  bool Start();

  // Stops the capture thread and releases resources.
  void Stop();

  bool IsRunning() const { return running_.load(); }

 private:
  void CaptureLoop();

  libwebrtc::scoped_refptr<libwebrtc::RTCAudioSource> source_;
  std::atomic<bool> running_{false};
  std::thread capture_thread_;

  IMMDevice* device_ = nullptr;
  IAudioClient* audio_client_ = nullptr;
  IAudioCaptureClient* capture_client_ = nullptr;
  WAVEFORMATEX* mix_format_ = nullptr;
  HANDLE ready_event_ = nullptr;
  HANDLE stop_event_ = nullptr;
};

}  // namespace flutter_webrtc_plugin
