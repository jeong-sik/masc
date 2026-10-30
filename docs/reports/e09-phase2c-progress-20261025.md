# E09 Phase 2c 진행 보고 — Voice_speak 분리

작성: music-sensei · 2026-10-25 · task-2526

## 이번 세션 커밋

- **d6a01d9e** — `lib/voice/voice_speak.ml` 839줄 신설. voice_bridge.ml 은 1569→766줄.

이동한 것(전부 재노출로 Voice_bridge 표면 유지):

- `clip_format_for_kind`, `audio_url_of_file`, `audio_payload_fields`, `message_preview(_max_bytes)`
- `available_tts_endpoints`, `try_http_tts_for_dashboard`
- `agent_speak_completion`, `agent_speak_result`(completion/payload 레코드), `mcp_call_error`(Timed_out/Connection_failed/Http_status/Malformed_body) — 원문 정의 그대로
- `with_timeout`(Watched_work 기반), `parse_json_response`, `single_voice_mcp_call`, `extract_mcp_result`, `call_voice_mcp_endpoint`
- `mcp_spoke_detail`, **`probe_tts`**, `attempt_tts_endpoint`, `try_http_tts_for_browser_audio`, `result_has_audio_file`, `merge_browser_audio_fields`
- `agent_speak_json`, `decode_agent_speak_result`, `agent_speak`, `get_agent_voice`

## 설계 판정: probe_tts 의 소속

2a 때 probe_tts 를 Voice_probe 로 이월한다고 적었는데, 실제 의존을 펼쳐 보니 `attempt_tts_endpoint`, `call_voice_mcp_endpoint`, `mcp_spoke_detail`, `clip_format_for_kind`, `message_preview`, `audio_payload_fields` — speak 파이프라인 전부를 당긴다. probe_stt(자립)와 달리 probe_tts 는 "speak 를 쏴 보고 보고하는" 진단이라 소속이 speak 다. Voice_speak 에 두고 Voice_bridge 재노출로 기존 호출자(`Voice_bridge.probe_tts`)를 유지한다. 이월 목록을 정정한다.

## 의존 방향 (현재)

```
voice_catalogue (순수)
voice_bridge_core ← voice_bridge_transport ← voice_probe (STT 체인+probe_stt)
                                        ← voice_player (play_tone, cleanup)
voice_speak → core, transport, player(cleanup_old_audio_files), overlay, json_util
voice_bridge = core include + catalogue/probe/player/speak 재노출 + capture(2d 대상)
```

## 정적 검증 범위 (컴파일 아님)

- 5개 voice 모듈 괄호·브래이스 밸런스 0 (주석/문자열 제거 후)
- voice_bridge.mli val 38개·type 15개 전수 대조 — 누락 0
- speak 영역 미해결 외부 심볼: 없음 (try_endpoints 는 내부 rec, endpoint/operation/voice 는 라벨·인자)
- bridge 에 speak 원본 정의 잔여 없음(전부 `= Voice_speak.` 재노출 확인)

## 남은 단계

1. **2d**: capture 상태머신(capture_config ~ record_and_transcribe, bridge 잔여 620줄) → Voice_capture. `resolved_audio_device` 는 device 해결이라 여기 포함.
2. **컴파일 영수증**: 툴체인 있는 세션 필요 — 이 레인 opam/dune 부재·GitHub 자격증명 없음 (직전 세션 실측과 동일)
3. PR 개설 + Native Stack 구성 (자격증명 있는 세션)

## 관련

- Board: p-9aeb5da34a64ee670461c1ab7a0a56a3 (2a·2b 게시글, 컴파일 위임 요청 중)
- 검증 기각 이력: vrf-438a3e8 (레인 한계 증명 없이 완료 주장)
