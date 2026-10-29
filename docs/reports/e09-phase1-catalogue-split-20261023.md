# E09 Phase 1 — Voice 카탈로그 층 분리 (task-2526)

작성: music-sensei · 2026-10-23 · base: e09-wt @ f5998357 + #45448 병합분 로컬 변경
설계 근거: `reports/e09-voice-addon-boundary-design-20261023.md`
최종 갱신: 2026-10-23 말 — alias 순서 교정(정의 전 참조 해소)·scratch 정리 완료

## 무엇을 했나

`voice_bridge.ml` 2,254줄에서 **순수 카탈로그 로직 층을 독립 모듈 `Voice_catalogue`로 추출**했다 (E09 설계 6경계 중 첫 번째).

### 이동된 정의 (voice_bridge.ml → voice_catalogue.ml)

| 이름 | 성격 |
|---|---|
| `spoke_detail` | TTS 응답 요약 문자열 |
| `transcript_of_stt_json` | STT JSON 파싱 |
| `catalogue_voice` (type) + `catalogue_voice_json` | 카탈로그 항목 표현 |
| `say_catalogue_of_output` | macOS say -v ? 파싱 |
| `espeak_aliases_of_line` / `espeak_spoken_name` / `espeak_catalogue_of_output` | espeak-ng --voices 파싱 |
| `say_voice` (type) / `say_voice_in_catalogue` | say 조회 판정 |
| `espeak_base_voice_in_catalogue` / `espeak_voice_in_catalogue` | espeak 조회 판정 |
| `check_say_voice` / `check_espeak_voice` / `check_command_voice` | 검증 (transport 인자 주입형으로 파라미터화) |

### 경계 원칙

- **카탈로그 모듈은 transport 0참조**: `Voice_bridge_transport`를 일절 부르지 않는다.
- **검증 함수는 `~lister` 인자로 카탈로그 취득을 주입**받는다 (`check_say_voice ~lister endpoint ~voice`). 콜백으로 순환 의존 제거.
- **bridge는 alias 재수출**로 기존 호출자·테스트(`test/voice_probe/test_voice_probe.ml`의 `Masc.Voice_bridge.spoke_detail` 등)의 이름을 그대로 유지한다.
- `list_voices_via_command_endpoint`는 transport를 소유한 bridge에 남는다.

## 파일 변화

- 신규: `lib/voice/voice_catalogue.ml` (311줄)
- 수정: `lib/voice/voice_bridge.ml` 2,254 → 1,949+31(alias) = 1,980줄
- 도구 스크립트: `scratch/split_catalogue.py`, `scratch/fix_alias_order.py` (재현용)

## 검증 상태 (정직하게)

- ✅ 정적: 이동 함수 15종의 bridge 내 정의 잔존 0건, 카탈로그 모듈 transport 참조 0건, 의존은 stdlib + Voice_config + Voice_runtime_overlay(같은 라이브러리), .mli 시그니처 호환, alias 순서(정의 후 사용) 교정 완료
- ✅ base 동일성: 작업 기반 voice_bridge.ml이 병합 시점 main과 sha256 동일(`b9519d42…`) — 이후 main 커밋들이 이 파일을 건드리지 않았다면 패치는 깨끗하게 적용된다
- ⚠️ **컴파일·테스트 미실행**: 이 레인에 OCaml 툴체인·GitHub 자격증명이 없다(opam 스위치 부재 확인, gh not logged in). dune build는 CI 또는 툴체인 있는 세션에서 확정 필요.

## 다음 단계

1. 툴체인 있는 세션에서 `dune build` + voice 슈트 실행 (또는 PR 오픈 후 CI)
2. Phase 2 (설계 문서 참조): speak 파이프라인(대기/재시도) 분리
3. main `voice_bridge.ml`이 이후 커밋에서 변경되면 rebase 확인
