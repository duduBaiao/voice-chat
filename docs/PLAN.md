# Local Mac Voice Chat Plan

## Milestone 0: Planning Checklist

- [x] Create `docs/PLAN.md`.
- [x] Include sub-checkmarks for implementation, tests, and acceptance verification.
- [x] Verify the checklist is tracked with the project.

## Milestone 1: Swift Project Scaffold + Core Architecture

- [x] Create the Swift package layout.
- [x] Add `VoiceChatCore`.
- [x] Add `VoiceChatCLI`.
- [x] Add `VoiceChatMacApp`.
- [x] Define `SpeechRecognizer`, `LLMClient`, `SpeechSynthesizer`, `ConversationStore`, and `FinalTranscriptCorrector`.
- [x] Define conversation statuses: `idle`, `listening`, `transcribing`, `waitingForLLM`, `speaking`, and `stopped`.
- [x] Add tests for conversation state transitions.
- [x] Add tests for chat message ordering and interim/final replacement.
- [x] Add mock composition tests for STT, LLM, and TTS.
- [x] Verify `swift test` passes for the scaffold.

## Milestone 2: LM Studio Client

- [x] Add OpenAI-compatible `/v1/chat/completions` client.
- [x] Default base URL to `http://100.127.238.44:1234`.
- [x] Default model to `google/gemma-4-26b-a4b-qat`.
- [x] Support non-streaming responses.
- [x] Support streaming responses.
- [x] Add timeout, cancellation, and readable errors.
- [x] Add mocked URL tests for success.
- [x] Add mocked URL tests for unavailable server.
- [x] Add mocked URL tests for malformed JSON.
- [x] Add mocked URL tests for timeout and cancellation.
- [x] Add optional real integration test gated by `RUN_LM_STUDIO_TESTS=1`.
- [x] Verify the real integration test passes against the configured LM Studio server.

## Milestone 3: TTS Backends

- [x] Add Apple CLI TTS backend using `/usr/bin/say`.
- [x] Add optional Piper backend using `PIPER_BIN`, `PIPER_MODEL`, and optional `PIPER_CONFIG`.
- [x] Mark Piper unavailable when not configured.
- [x] Support TTS cancellation.
- [x] Add backend selection tests.
- [x] Add process-runner mock tests for success, failure, and cancellation.

## Milestone 4: Apple Speech Live Transcription

- [x] Add Apple Speech recognizer using Apple Speech and `AVAudioEngine`.
- [x] Show live interim transcript events.
- [x] Commit final transcript as a user message.
- [x] Auto-stop when no speech occurs for 5 seconds after Start.
- [x] Treat standalone spoken `stop` as a Stop command.
- [x] Keep the session alive after ordinary turn-finalizing silence.
- [x] Add mock speech event tests.
- [x] Add timer tests for 5-second idle auto-stop.
- [x] Add interim-to-final transcript replacement tests.
- [x] Add spoken stop-command tests.

## Milestone 5: End-to-End CLI Voice Chat

- [x] Compose Apple Speech, LM Studio streaming, and selected TTS.
- [x] Use half-duplex flow: listen, transcribe, ask LLM, speak, resume listening.
- [x] Make Stop cancel listening, LLM streaming, and TTS.
- [x] Add end-to-end controller tests with mocked STT, LLM, and TTS.
- [x] Add Stop/cancel tests during listening, LLM, and TTS.
- [x] Add empty transcript suppression tests.
- [x] Add multi-turn session tests.
- [x] Verify the CLI help smoke test.

## Milestone 6: SwiftUI Mac Chat App

- [x] Add native SwiftUI app target.
- [x] Show chat transcript with user and assistant bubbles.
- [x] Show live interim user bubble.
- [x] Show streaming assistant bubble.
- [x] Add `Start talking` / `Stop talking` button.
- [x] Add status label for listening, thinking, speaking, and stopped.
- [x] Add TTS backend picker.
- [x] Use `AVSpeechSynthesizer` for Apple TTS in the app.
- [x] Add view model tests for button state and status transitions.
- [x] Add chat update tests.
- [x] Add manual QA notes for mic permission, speech permission, LM Studio unavailable, and TTS cancellation.

## Milestone 7: Whisper Final Correction

- [x] Add `FinalTranscriptCorrector`.
- [x] Add Whisper CLI backend.
- [x] Record utterance audio to temporary WAV.
- [x] Use Apple Speech for interim text.
- [x] Use Whisper to correct final text before sending to LM Studio.
- [x] Fall back to Apple final text on timeout, failure, or missing config.
- [x] Add correction timeout tests.
- [x] Add fallback tests.
- [x] Add mock Whisper process tests for success, empty output, failure, and cancellation.

## Verification

- [x] `swift test`
- [x] `RUN_LM_STUDIO_TESTS=1 swift test --filter LMStudioClientTests/testOptionalRealLMStudioIntegration`
- [x] `swift run voice-chat`
- [ ] Manual hardware QA: run `swift run voice-chat listen` and/or `swift run VoiceChatMacApp`, grant microphone and speech permissions, speak a real prompt, confirm live interim text, final text, LM Studio answer, TTS playback, Stop cancellation, and the LM Studio-unavailable error path.
