# E09 Voice·VST 실행 소유 경계 분리 — 설계 (v1)

작성: music-sensei · 2026-10-23 · base: e09-wt @ f5998357 (+ #45448 병합분 반영 로컬 변경)

## 0. 상태와 경위

- PR #45448(realtime 세션 복구, merge 299542e6)은 착지. 이것은 **session/realtime 수명 분리만** 마친 상태다.
- task-2526 검증 기각(vrf-438a3e8) 사유 그대로: ① TTS/STT/player/device의 경계 분리 미실시 ② 실행 영수증 0건.
- 본 문서는 기각 사유 ①에 대한 설계 산출물이다. E09행 완료 기준 "TTS/STT/realtime/session/player/device 수명과 결과·오류를 분리; 실제 입출력과 해제 정리 확인" 중 설계→구현 순서의 첫 단계.

## 1. 현재 재고 (직독 기준)

| 모듈 | 규모 | 책임 | 비고 |
|---|---|---|---|
| `lib/voice/voice_session_manager.ml/.mli` | 412/97 | session 수명·대화모드(Turn_based/Realtime_bridge/Realtime_unavailable)·영속화 | **분리 완료** (#45448) |
| `lib/voice_bridge_core/` (voice_bridge_transport) | — | http TTS/STT·command STT 전송 | **이미 분리됨** |
| `lib/voice/voice_bridge.ml` | 2254 | 카탈로그·프로브·스피크 파이프라인·캡처 상태머신·재생·디바이스 **혼재** | 본 설계의 분리 대상 |
| `lib/keeper/keeper_tool_voice_runtime.ml/.mli` | 458/69 | Keeper 도구 표면 + TTS 리프에서의 Gate 승인 | 유지 (host authority) |
| `lib/voice_config/` | — | tts/stt/session/capture 설정 | 유지 |

`voice_bridge.ml` 내 구획(읽은 줄 좌표, head f5998357 기준):
- L19–410: 순수 카탈로그/조회 (transcriber, catalogue_voice, espeak/say 파서, voice-in-catalogue 검사, clip_format, message_preview)
- L436–866: 프로브/진단 (transcribe_audio, probe_outcome/attempt, list_voices_*, probe_stt, public_config_json, cleanup_old_audio_files)
- L868–1597: 스피크 파이프라인 (agent_speak_completion/result, mcp_call_error, with_timeout, call_voice_mcp_endpoint, probe_tts, attempt_tts_endpoint, agent_speak, get_agent_voice)
- L1599–1630: 재생 (play_tone) + L384–404 audio_url_of_file/audio_payload_fields
- L1630–2251: 캡처 상태머신 (level_phase/stop_request/capture_end/level_step, advance_phase, watch_capture_level, capture_outcome, rec_argv, resolved_audio_device, record_and_transcribe, noise reduction)

## 2. 목표 경계 (모듈 이동만. 새 singleton/registry/런타임 없음 — 계약 요구)

1. **Voice_catalogue** (순수): L19–410 이동. 입력·출력·시계·파일 전무 → 어디서든 테스트 가능.
2. **Voice_probe**: L436–866 이동. probe_outcome/attempt의 닫힌 변형이 결과 계약 그대로 승계.
3. **Voice_speak** (TTS 출력 파이프라인): L868–1597 이동. `agent_speak_result`(닫힘)가 오류 계약. Gate 리프 호출은 `keeper_tool_voice_runtime`의 `external_effect_authorizer`를 그대로 통과.
4. **Voice_player**: play_tone, audio_url_of_file, audio_payload_fields, cleanup_old_audio_files 이동. **추가 계약**: 정리(cleanup) 결과를 unit가 아닌 명시적 outcome(삭제/실패/대상 수)으로.
5. **Voice_capture** (STT 입력): L1630–2251의 상태머신+녹음+노이즈감쇠 이동. `capture_outcome`(L1985)이 이미 닫힌 결과 계약 — 승계하고 `recorder_refusal_message`/`spawn_refusal` 매핑을 한 곳에.
6. **Voice_device**: resolved_audio_device(L2103), audio_device payload 필드(L390), recorder 거부 매핑을 캡처에서 분리. **디바이스 해제 정리**가 이 경계의 완료 기준.
7. **session/realtime**: `voice_session_manager`에 그대로 (완료됨).

## 3. 결과·오류 분리 계약 (경계별)

- speak: `agent_speak_result` (닫힘) — 이미 존재, 문서화만.
- capture: `capture_outcome` (닫힘) + discarded_json — 승계.
- device: `resolved_audio_device`의 option 결과 + `spawn_refusal` 변환 계층 명시.
- player: 신규 명시적 cleanup outcome.
- 프로브: `probe_outcome`/`probe_attempt` 승계.
- 오류는 예외가 아니라 Result+닫힌 변형 (ocaml-coding 스킬 계약 준수).

## 4. host authority 불변식

- transcript/session 기록은 host(서버) 소유 유지 — Addon 경계는 오디오 프레임/파일만.
- Gate 승인은 TTS/재생 리프에서만 (`keeper_tool_voice_runtime.external_effect_authorizer` 그대로).
- 유료 provider 호출·설정 변경·운영 서버 교체는 본 설계 범위 밖.

## 5. 검증 계획 (기각 사유 ② 대응)

1. 경계별 단위 테스트: Voice_catalogue/Voice_device 순수 테스트는 툴체인 불필요 로직만 대상(실행은 툴체인 필요).
2. 실행 영수증: **이 레인은 OCaml 툴체인·GitHub 자격증명 없음(opam 스위치 미존재 확인)** → 툴체인 있는 레인/러너에서 `scratch/` 격리 실행(pinned-test-module-isolated-run 절차) + Dune build.
3. 시나리오: 재시작(restore), Off(Realtime_unavailable 강제), reconnect(bridge 단절→복귀) — 각각 원문 로그 증거.
4. Native Stacked PR로 착지, 각 층 독립 승인.

## 6. 비목표

- 새 런타임/레지스트리/모델 broker 없음.
- VST는 관측만(정본 요구) — 본 설계 범위 밖.
- 실제 provider 호출·설치·운영 UI 변경 없음.
