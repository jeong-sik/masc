---
rfc: "outlive-process-adoption"
title: "턴보다 오래 사는 프로세스가 머지됐는데도 죽는다 — 채택 갭을 먼저 진단한다"
status: Draft
created: 2026-09-01
updated: 2026-09-02
author: claude
supersedes: []
superseded_by: null
related: ["keeper-writes-own-compositions", "tools-as-shell-commands"]
implementation_prs: []
---

# RFC: outlive 프로세스의 채택 갭 (outlive-process-adoption)

## 0. Summary

"호출보다 오래 사는 프로세스"는 8/24에 머지됐다(#30244 코어, #30265 네 도구). 그런데
그 후 1주일(08-25~09-01)에도 `keeper_spawn_read` 실패의 **91%**(92건 중 84건)가
"no process is held under X. It ended with the turn that spawned it"이다. 기능은
살아 있고 채택이 죽어 있다. 원인을 진단한 뒤 원인별로 답한다.

## 1. 배경

- #30244: `Process_eio`의 run-to-completion 모델을 넘어, 종료되지 않은 프로세스를
  담는 registry(`keeper_subprocess_registry`)와 네 개의 spawn 도구. 8/25 감사에서
  "헌법을 코드로 실음"으로 평가된 구현이다.
- 실측: 배포된 런타임에서 실패 문구가 계속 나온다 — 기능-채택 갭이지 배선 누락이
  아니다(서버는 최신).

## 2. 진단 순서 (구현에 앞선다)

실패 84건을 먼저 분해한다. 원인 후보 셋:

| 후보 | 확인 방법 | 답 |
|---|---|---|
| (a) keeper가 유지 옵션을 안 쓴다 | keeper_spawn 호출 인자의 모드 분포 — outlive 요청 비율 | 프롬프트/도구 설명 개선, 필요 시 기본값 논의 |
| (b) 유지했어도 후속 턴 전에 정리된다 | registry 등록→소멸 시각 분포 vs read 시도 시각 | 수명 규칙 수정(등록은 미래 사실이지 과거 게이트가 아니다) |
| (c) 경로 조합(sandbox 프로필·lane)마다 registry가 다르다 | 실패 84건의 keeper·프로필 분포 | 해당 경로의 등록 누락 수정 |

(a)이면 채택 문제, (b)이면 수명 설계 문제, (c)이면 구현 결함 — 세 답이 완전히 다르므로
측정이 먼저다.

## 3. PoC 판정 기준

- keeper가 spawn → 이후 턴(또는 분 뒤)에서 read가 성공하는 라이브 세션.
- 통과선: "ended with the turn" 실패가 주 단위 관측에서 91% → 관측 0건 근처.

## 4. 단계

- **PR-0**(측정): 84건 분해 + registry 수명 분포. 결과를 본문에 기록.
- **PR-1**: 원인별 수정(위 표의 답 열). (a)의 경우 tools-as-shell-commands의 셸
  라인(`masc spawn … &`)이 자연스러운 진입 경로가 될 수 있다.

## 5. 반론과 답

- **"진단만으로 끝나는 게 아닌가"** — 그렇지 않다. 91%가 계속 나온다는 건 이미
  라이브가 진단 데이터를 주고 있다는 뜻이다. 이 RFC는 그 데이터를 한 번 정리해
  세 갈래 중 하나로 좁히는 작업이다.
- **"옵트인 기본값을 키우면 되지 않나"** — 임의 기본 변경은 관측 없이 하지
  않는다. (a)로 판명되면 그때 실측과 함께 논의한다.

## 6. 근거

- 내부: `.tmp/toolstudy/masc-gap.md` §4 (실패 92건 중 84건)
- 코드: `lib/keeper/keeper_subprocess_registry.ml`(#30244), #30265 네 도구
- 백로그: issue #32369 작전 6

---

## 7. 측정 결과 (2026-09-02) — 세 후보 전부 기각, 실체는 기능 부재

§2의 진단을 수행했다(원본: `.tmp/toolstudy/pr0-measurements.md` §2).

- **(a) 기각**: `keeper_spawn` 스키마에 유지 옵션이 **존재하지 않는다**
  (argv/cwd 뿐, `additional_properties=false`, description이 "The process ends
  when the turn does"라고 명시). 실측 2,545건 호출에서 outlive/hold류 키 **0건**.
  "옵션을 안 쓴다"가 아니라 쓸 옵션이 없었다.
- **(b) 기각**: registry는 런 스코프이고 같은 런 안의 read는 2,708건 전부 성공
  (`spawn_registry`에 remove 경로가 없음 — 코드로 확인). 실패 86건 전부가
  **다른 런에서의 read**였다(spawn→read p50 643초, 그 사이 런이 종료).
- **(c) 기각**: registry 구현은 전 keeper·전 프로필 동일. 편중은 행동 편중
  (polisher 43, lane-smith 18, code-reviewer 18 — 후자는 remote_ssh에서 spawn
  자체가 경계 거부되는 프로필).

**실체**: keeper는 런을 넘어 프로세스를 읽으려 시도하고 있다 — 49건은 이전
handle을 기억에서 재구성한 오염 문자열(`allama`, `deeplist`…)까지 보인다. 이것은
채택 갭이 아니라 **기능 부재**다. 배경 서술의 "8/24에 머지됐는데도"도 정정한다:
#30244는 "outlive the **call**"(호출 반환 후, 런 내 생존)이고, 런 넘어 생존은
`keeper_agent_run`의 설계와 `keeper_spawn.toml` 문서 모두에서 처음부터 없다.

**PR-1 재정의**: 프롬프트/설명 개선이 아니라 **outlive-the-run 기능을 만들 것인가
말 것인가의 결정**이어야 한다. 필요 측정도 이미 답했다 — 런 넘어 read 시도가
86건(성공 2,708건의 약 3%)이고 필요 경과는 p50 11분. 이 수요를 닫을 축은
(1) registry의 런 간 이양(keeper 재개 시 재부착), (2) read의 "이미 종료된
프로세스" 명시적 안내(오염 handle 49건의 루프 끊기) 중 하나다. §2의 후보 표는
폐기한다.
