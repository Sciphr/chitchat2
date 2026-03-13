#include "wasapi_loopback_capture.h"

#include <cstring>
#include <vector>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "avrt.lib")

namespace flutter_webrtc_plugin {

WasapiLoopbackCapture::WasapiLoopbackCapture(
    libwebrtc::scoped_refptr<libwebrtc::RTCAudioSource> source)
    : source_(source) {}

WasapiLoopbackCapture::~WasapiLoopbackCapture() {
  Stop();
}

bool WasapiLoopbackCapture::Start() {
  if (running_.load()) return true;

  HRESULT hr;

  // Initialize COM for this call (best-effort; may already be initialized).
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);

  // Get the default audio render endpoint (speakers / headphones).
  IMMDeviceEnumerator* enumerator = nullptr;
  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        __uuidof(IMMDeviceEnumerator),
                        reinterpret_cast<void**>(&enumerator));
  if (FAILED(hr)) return false;

  hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device_);
  enumerator->Release();
  if (FAILED(hr)) return false;

  // Activate the audio client.
  hr = device_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                         reinterpret_cast<void**>(&audio_client_));
  if (FAILED(hr)) {
    device_->Release();
    device_ = nullptr;
    return false;
  }

  // Query the mix format (native sample rate / channel count).
  hr = audio_client_->GetMixFormat(&mix_format_);
  if (FAILED(hr)) {
    audio_client_->Release();
    audio_client_ = nullptr;
    device_->Release();
    device_ = nullptr;
    return false;
  }

  // Request a 50 ms buffer.
  const REFERENCE_TIME requested_duration = 500000;  // 100-ns units → 50 ms

  hr = audio_client_->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                 AUDCLNT_STREAMFLAGS_LOOPBACK |
                                     AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                                 requested_duration, 0, mix_format_, nullptr);
  if (FAILED(hr)) {
    CoTaskMemFree(mix_format_);
    mix_format_ = nullptr;
    audio_client_->Release();
    audio_client_ = nullptr;
    device_->Release();
    device_ = nullptr;
    return false;
  }

  // Set up event-driven buffering.
  ready_event_ = CreateEvent(nullptr, FALSE, FALSE, nullptr);
  stop_event_ = CreateEvent(nullptr, TRUE, FALSE, nullptr);

  hr = audio_client_->SetEventHandle(ready_event_);
  if (FAILED(hr)) {
    CloseHandle(ready_event_);
    CloseHandle(stop_event_);
    ready_event_ = stop_event_ = nullptr;
    CoTaskMemFree(mix_format_);
    mix_format_ = nullptr;
    audio_client_->Release();
    audio_client_ = nullptr;
    device_->Release();
    device_ = nullptr;
    return false;
  }

  // Get the capture client.
  hr = audio_client_->GetService(__uuidof(IAudioCaptureClient),
                                 reinterpret_cast<void**>(&capture_client_));
  if (FAILED(hr)) {
    CloseHandle(ready_event_);
    CloseHandle(stop_event_);
    ready_event_ = stop_event_ = nullptr;
    CoTaskMemFree(mix_format_);
    mix_format_ = nullptr;
    audio_client_->Release();
    audio_client_ = nullptr;
    device_->Release();
    device_ = nullptr;
    return false;
  }

  running_.store(true);
  capture_thread_ = std::thread(&WasapiLoopbackCapture::CaptureLoop, this);

  audio_client_->Start();
  return true;
}

void WasapiLoopbackCapture::Stop() {
  if (!running_.load()) return;

  running_.store(false);
  if (stop_event_) SetEvent(stop_event_);

  if (capture_thread_.joinable()) capture_thread_.join();

  if (audio_client_) {
    audio_client_->Stop();
    audio_client_->Release();
    audio_client_ = nullptr;
  }
  if (capture_client_) {
    capture_client_->Release();
    capture_client_ = nullptr;
  }
  if (device_) {
    device_->Release();
    device_ = nullptr;
  }
  if (mix_format_) {
    CoTaskMemFree(mix_format_);
    mix_format_ = nullptr;
  }
  if (ready_event_) {
    CloseHandle(ready_event_);
    ready_event_ = nullptr;
  }
  if (stop_event_) {
    CloseHandle(stop_event_);
    stop_event_ = nullptr;
  }
}

void WasapiLoopbackCapture::CaptureLoop() {
  if (!mix_format_ || !source_) return;

  const int sample_rate = static_cast<int>(mix_format_->nSamplesPerSec);
  const size_t channels = static_cast<size_t>(mix_format_->nChannels);

  // Determine bits-per-sample and whether input is float32.
  bool is_float = false;
  int bits_per_sample = 16;
  if (mix_format_->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
      mix_format_->cbSize >= 22) {
    WAVEFORMATEXTENSIBLE* ext =
        reinterpret_cast<WAVEFORMATEXTENSIBLE*>(mix_format_);
    if (ext->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) {
      is_float = true;
      bits_per_sample = 32;
    } else {
      bits_per_sample = static_cast<int>(mix_format_->wBitsPerSample);
    }
  } else if (mix_format_->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    is_float = true;
    bits_per_sample = 32;
  } else {
    bits_per_sample = static_cast<int>(mix_format_->wBitsPerSample);
  }

  // If float32, we convert to int16 before pushing to WebRTC.
  const int push_bits = is_float ? 16 : bits_per_sample;
  std::vector<int16_t> conversion_buf;

  HANDLE wait_handles[2] = {ready_event_, stop_event_};

  while (running_.load()) {
    DWORD result = WaitForMultipleObjects(2, wait_handles, FALSE, 200);
    if (result == WAIT_OBJECT_0 + 1 || result == WAIT_TIMEOUT) {
      // Stop event or timeout — check running flag.
      if (!running_.load()) break;
      if (result == WAIT_TIMEOUT) continue;
      break;
    }
    if (result != WAIT_OBJECT_0) break;

    UINT32 packet_size = 0;
    if (FAILED(capture_client_->GetNextPacketSize(&packet_size))) break;

    while (packet_size > 0 && running_.load()) {
      BYTE* data = nullptr;
      UINT32 num_frames = 0;
      DWORD flags = 0;
      HRESULT hr =
          capture_client_->GetBuffer(&data, &num_frames, &flags, nullptr, nullptr);
      if (FAILED(hr)) break;

      if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
        // Silent — push zeroes.
        size_t total_samples = static_cast<size_t>(num_frames) * channels;
        conversion_buf.assign(total_samples, 0);
        source_->CaptureFrame(conversion_buf.data(), 16, sample_rate, channels,
                              static_cast<size_t>(num_frames));
      } else if (data && num_frames > 0) {
        if (is_float) {
          // Convert float32 → int16.
          const float* src = reinterpret_cast<const float*>(data);
          size_t total_samples = static_cast<size_t>(num_frames) * channels;
          conversion_buf.resize(total_samples);
          for (size_t i = 0; i < total_samples; ++i) {
            float sample = src[i];
            if (sample > 1.0f) sample = 1.0f;
            if (sample < -1.0f) sample = -1.0f;
            conversion_buf[i] = static_cast<int16_t>(sample * 32767.0f);
          }
          source_->CaptureFrame(conversion_buf.data(), 16, sample_rate,
                                channels, static_cast<size_t>(num_frames));
        } else {
          source_->CaptureFrame(data, push_bits, sample_rate, channels,
                                static_cast<size_t>(num_frames));
        }
      }

      capture_client_->ReleaseBuffer(num_frames);
      if (FAILED(capture_client_->GetNextPacketSize(&packet_size))) {
        packet_size = 0;
      }
    }
  }
}

}  // namespace flutter_webrtc_plugin
