# E09 Phase 2a·2b 진행 보고 — Voice_probe·Voice_player 분리

작성: music-sensei · 2026-10-25 · task-2526

## 이번 세션 결과

base: main 8d872e10 (fetch 직접 확인, 2026-10-25T12:4xZ)
워크트리: e09-wt (detached → 3 커밋)

| 커밋 | 내용 |
|---|---|
| 0d2fd6f5 | Phase 1 Voice_catalogue 분리를 main 위로 rebase (충돌 6+8개 전부 #45448 성숙본 채택) + **Phase 1 버그 수정: catalogue 재노출 블록이 voice_catalogue.ml 안에 섞여 자기참조하던 것 정리** |
| 3130fc99 | Phase 2a: probe_outcome/probe_attempt·list_voices·probe_stt·public_config_json·transcribe_audio·capture_status 코덱 → lib/voice/voice_probe.ml (368줄). transcriber/transcriber_of_kind 는 순수 카탈로그 논리라 Voice_catalogue 로 하향. probe_tts 는 speak 계층 의존(mcp 호출: call_voice_mcp_endpoint/mcp_spoke_detail/with_voice_output_turn) 때문에 2c로 이월 |
| 21e0d502 | Phase 2b: play_tone·cleanup_old_audio_files → lib/voice/voice_player.ml (85줄) |

패치: e09-patches/0001~0003 + 통합 diff(e09-phase1-2a-2b-vs-main-8d872e10.patch, 80,682 bytes)

## 검증 상태 (정직하게)

- **정적 검사만 수행**: 괄호/브래이스/브레이스 밸런스(주석·문자열 제거 후), mli↔ml val/type 전수 대조(누락 0), probe 모듈 미해결 외부 심볼 0, 라이브러리 의존 해석(lib/voice = masc lib 내부, masc.config·time_compat 포함 확인).
- **컴파일·테스트 미실행**: 이 레인 opam/dune 없음(실측), GitHub 자격증명 없음(GH_CONFIG_DIR 빈, gh auth 미로그인 — push 시도 fatal 확인).
- 근거 규칙: "실패 문구 부재 ≠ 통과" — 위 정적 검사는 통과 기준이 아니라 컴파일 위임 전 인내 검사다.

## 남은 단계

1. **2c**: Voice_speak(attempt_tts_endpoint·agent_speak·get_agent_voice·audio payload 일동) + probe_tts 를 probe 로 이관. 이때 probe_tts 의 mcp 의존이 speak 를 거치므로 speak 먼저.
2. **2d**: Voice_capture·Voice_device(resolved_audio_device·recorder_refusal 매핑).
3. **컴파일 영수증**: 툴체인 있는 세션에서 `dune build` + voice 관련 테스트(voice_probe·voice_say_voice_probe·voice_runtime_overlay). 이 레인은 불가.
4. **PR 개설**: 자격증명 있는 세션이 e09-patches 를 브랜치로 올려 Native Stack 구성.

## 재현

```
cd e09-wt
git log --oneline -4
# 21e0d502 / 3130fc99 / 0d2fd6f5 / 8d872e10(origin/main)
git diff 8d872e10..21e0d502 --stat
```
