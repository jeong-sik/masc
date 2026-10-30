# E09 Phase 2d 진행 보고 — Voice_capture 분리 (완)

작성: music-sensei · 2026-10-25 · task-2526

## 이번 세션 커밋

- **561834d6** — `lib/voice/voice_capture.ml` 637줄(본체 628줄 verbatim): capture_config, noise floor 캘리브레이션(measure_noise_floor/with_noise_reduced_audio), level watch 상태머신(level_phase/advance_phase/end_at_deadline/end_at_operator_stop/watch_capture_level), rec_argv·recorder spawn·refusal 메시지, record_and_transcribe 진입점.
- voice_bridge.ml 은 재노출만 남음: **766 → 182줄, 본체 정의 0.**

## 분리 구조 최종 상태 (lib/voice/)

| 모듈 | 줄 | 책임 |
|---|---|---|
| voice_bridge.ml | 182 | 재노출 전용 (역사적 표면 유지) |
| voice_catalogue.ml | 333 | 순수 카탈로그·transcriber 코덱 |
| voice_probe.ml | 368 | probe_stt·list_voices·public_config·transcribe_audio |
| voice_player.ml | 83 | play_tone·cleanup_old_audio_files |
| voice_speak.ml | 839 | TTS 파이프라인·agent_speak 계약·probe_tts |
| voice_capture.ml | 637 | 마이크 녹음→전사 상태머신 |
| voice_session_manager.ml | 423 | (선행 #45448) |
| voice_pcm.ml | 74 | PCM 코덱 |

원본 단일 파일 1569줄 → 7 모듈 2939줄(주석 헤더 포함). 의존 방향: bridge → {catalogue, probe, player, speak, capture} → {core, transport} → config. 순환 없음.

## Phase 2d 특이사항

- stop_request/capture_level/capture_end 은 원본이 배리언트 타입이라 재노출을 `type x = Voice_capture.x = | ...` 형태로 원문 그대로 옮김 (첫 시도에 레코드로 잘못 적어 정정).
- For_testing.with_timeout 은 speak 소속이라 `Voice_speak.with_timeout` 전달로 유지 (test_voice_bridge_watched_work.ml 2건 호출자 불변).
- capture → probe(transcribe_audio)·player(play_tone) 의존은 헤더 별칭으로 명시.

## 검증

- 정적: 괄호/브래이스 밸런스 0, 충돌 마커 0, mli val/type 전수 대조 — mli 요구 전부 ml 에 존재 (누락 0).
- 컴파일: 이 레인 opam/dune 부재로 불가 — **컴파일 위임 대기 중** (p-9aeb5da34a64ee670461c1ab7a0a56a3, 스택 Phase 1+2a+2b+2c+2d 5커밋).

## 다음 단계

1. 컴파일 위임 세션의 dune build 결과 회신 → 오류 수정 (있으면)
2. 빌드 녹색 확인 후 브랜치 push·PR 개설 (이 레인 gh 미인증, 별도 세션 필요 가능)
3. 검증 재제출 (기각 vrf-438a3e8 이후 재도전)
