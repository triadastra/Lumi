# Voice

## Overview

Lumi supports three voice modes:

1. **Push-to-talk Whisper** — record a clip, transcribe it via OpenAI Whisper, and send as a chat message
2. **Realtime VAD** — stream audio over a WebSocket to OpenAI's Realtime API with server-side voice activity detection; automatically stops when you stop speaking
3. **TTS (Text-to-Speech)** — have the agent speak its response aloud via OpenAI TTS

All voice features require an OpenAI API key (even if the chat agent uses a different provider) and the Microphone permission on macOS.

## Push-to-Talk Transcription

In any chat view, tap or click the microphone button to start recording. Audio is captured using `AVAudioRecorder` to a temporary `.wav` file. Tap again to stop, or wait for the silence-detection auto-stop.

On stop, the recording is sent to OpenAI's Whisper API (`whisper-1`). The transcribed text is placed in the message input field and sent automatically.

**Silence detection**: the recording loop monitors the audio meter every 0.5 seconds. If the level stays below the silence threshold for 2 seconds, recording stops automatically.

## Realtime Voice Activity Detection

The realtime path opens a WebSocket to `wss://api.openai.com/v1/realtime?model=gpt-realtime`. PCM audio is streamed as base64-encoded chunks. The server detects speech start and end events and returns a transcript when speech ends.

This mode gives lower latency than push-to-talk because transcription happens continuously as you speak, not as a batch after recording ends.

The realtime path is used automatically when available; the push-to-talk path is the fallback.

## Text-to-Speech

Call `speak(text:)` on `OpenAIVoiceManager` to synthesize and play a response. The request goes to OpenAI's TTS endpoint with model `gpt-4o-mini-tts` and voice `alloy`. The returned audio is played via `AVAudioPlayer`.

TTS can be enabled or disabled per conversation. When enabled, each agent response is read aloud after streaming completes.

## OpenAIVoiceManager

`OpenAIVoiceManager` (`Infrastructure/Audio/OpenAIVoiceManager.swift`) is the single class responsible for all voice I/O:

- `startRecording()` — begins AVAudioRecorder capture
- `stopRecordingAndTranscribe()` — stops recording, sends to Whisper, returns transcript
- `startRealtimeSession()` — opens the WebSocket session
- `speak(text:)` — calls TTS and plays the result

The manager publishes `@Published isRecording: Bool` and `@Published isPlaying: Bool` for UI binding.

## Permissions

The Microphone permission (`NSMicrophoneUsageDescription`) is required. On first use, macOS shows a system prompt. You can verify the grant in **System Settings → Privacy & Security → Microphone**.

On iOS, `AVAudioSession` must be activated with `.record` category before recording. The iOS app handles this automatically when the voice button is tapped.
