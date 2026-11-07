---
rfc: "vibe-official-client-lane"
title: "Mistral Vibe 구독 pool 을 official-client lane 으로 쓴다"
status: Draft
created: 2026-11-07
updated: 2026-11-07
author: claude
supersedes: []
superseded_by: null
related: ["49352", "49200"]
---

# RFC: Vibe official-client lane (vibe-official-client-lane)

## 0. 요약

Mistral Pro 이상의 요금제는 Vibe Code 전용 월간 pool(콘솔 기준 US$300)을
API pool(US$30)과 따로 준다. API 키 경로는 $30 pool 에만 닿으므로(근거는
`docs/research/vibe-official-client-lane-20261107.md`), $300 pool 을 쓰려면
Vibe 제품 표면을 감싸는 official-client lane 이 필요하다. 이 RFC 는 그 lane 의
종류·자격 증명·계약·관측·실패 처리를 정하고, 구현 착수 조건을 명시한다.

## 1. 배경과 근거

- 계량 분리: admin usage API 가 `vibe_usage` 를 `completion` 과 별도 항목으로
  잡고, 콘솔도 두 막대로 나눠 보여준다. 문서 한 곳(api-keys-profiles)의
  "shared monthly usage" 문장과 충돌하지만 운영 관찰(두 막대)이 우선한다.
- 인증 분리: Vibe CLI 는 브라우저 계정 로그인으로 자격 증명을 provisioning
  하며 API 키 없이 유료 플랜에서 동작한다. 제3자가 구독 pool 에 닿는 공개
  엔드포인트는 없다.
- 자세한 출처와 미확인 목록: 연구 문서 §1–§6.

## 2. 결정

### 2.1 lane 종류 — claude_code 패턴의 command transport 와 소유 코덱

- lane 종류는 **command transport**(공식 CLI 감싸기)다. 새 HTTP codec 을
  만들지 않는다. 단 "masc 는 프로세스 조종·관측만 한다"는 초판 문장은 옳지
  않았다: 참조 구현 claude_code lane 자체가 stream_event 15-생성자 코덱,
  MCP 도구 브리지, resume 세션을 소유한다. 소유 경계는 같은 선에 선다.
- **masc 가 소유하는 계약** — programmatic 표면의 소비 계약(work-with-cli.md
  Programmatic mode):
  - `--output json`(종료 시 메시지 배열) / `--output streaming`(메시지별 한 줄)
    프레임을 읽는 출력 코덱.
  - `--output-dir` 의 `export.json`(토큰 사용량·비용·stop reason·outcome·
    subagent별 기록) 파싱 — usage 관측(§2.4)의 1차 원천.
  - exit code 0-3 의 typed 분류(0 완료 / 1 시작 실패 / 2 모델 API·런타임
    실패 / 3 한도·중단·거절).
  - 세션 재개: `-p --continue`·`-p --resume SESSION_ID`(문서화된 표면).
- **착수 조건**: 무인 호출의 존재는 문서로 확정됐다(연구 §3). 구현 Task 의
  첫 층은 우리 계정에서의 **호출 계약 실측**이다 — `--output json`/`streaming`
  프레임과 `export.json` 을 fixture 로 촬영해 필드 수준 계약을 문서화한다.
  문서와 실제가 어긋나 코덱을 세울 수 없으면 그 층에서 이 RFC 를 Deferred 로
  되돌린다.
- **우회의 금지는 문서화되지 않은 TTY 조종에 한한다**(초판은 문서화된
  --resume 까지 금지했다 — 리뷰 S3). 문서화된 programmatic 표면이면 resume
  도 lane 의 정당한 원시다.
- antigravity 패턴(OAuth 자격 증명을 저마다 모듈로 소유하는 패밀리)은 Vibe
  CLI 가 자격 증명을 스스로 provisioning 하므로 채택하지 않는다. masc 는
  로그인 절차를 소유하지 않는다.

### 2.2 자격 증명 — CLI 소유, masc 는 준비 상태만 관측

- 브라우저 로그인 자격 증명의 저장·수명·갱신은 Vibe CLI 소유다. masc 는
  `vibe /whoami`(또는 동등한 비출력 명령) 로 "로그인 됨/플랜"만 읽어 lane
  준비 상태로 노출한다. 토큰 파일을 직접 읽거나 재발급하지 않는다.
- 다계정: Vibe CLI 의 profile 기능(config.toml `[[providers]]`, api-keys
  페이지의 profile)이 있는지 실측 뒤 #49200 C2a 계열(계정 스택)에 합류
  여부를 정한다. 이 RFC 는 단일 계정만 약속한다.
- API 키 방식(`MISTRAL_API_KEY`)은 이 lane 의 자격 증명이 아니다 — 그 경로는
  기존 mistral HTTP 레인($30 pool)이다.

### 2.3 모델·thinking 계약

- lane 이 노출하는 모델은 CLI 내장 목록을 실측해 카탈로그에 옮긴다.
  mistral-large-4 의 chunk-list content/thinking 계약은 이미 HTTP 레인에서
  실측·구현됐다(#49350, #49554). lane 은 CLI 가 content 를 이미 해석해
  내주므로 우리 wire 파서를 재사용하지 않는다.
- thinking 수준 매핑: Vibe `off/low/medium/high/xhigh/max` → masc
  Reasoning_effort(8값) 의 대응값. 이름만 다른 `off`↔`none` 은 lane 경계에서
  어휘표 한 줄로 바꾼다(문자열 비교 분기가 아니다). 단 CLI 표면이 `off`/
  `none` 을 실제로 받는지는 미실측이다(API wire 는 `none` 을 거부한다는
  실측이 있다) — 첫 층 실측 항목에 넣는다.

### 2.4 사용량 관측

- usage 의 1차 원천은 `--output-dir` 의 `export.json`(토큰 사용량·비용·
  subagent별 기록)이다 — 호출마다 확정적으로 얻는다. Admin usage API 의
  `vibe_usage` 는 Enterprise 전용이라 Pro 운영에서 못 쓴다. 콘솔의 두 막대는
  사람이 읽는 원장으로 남기고, lane 이 예측 비용 모델을 발명하지 않는다.

### 2.5 실패 양상의 typed 처리

- 포함분 소진은 "Vibe Code stops until the next billing period"(제품 차단)으로
  나타난다. lane 은 이 차단 출력을 실측해 typed 실패(Quota_exhausted 상당의
  기존 분류에 붙인다)로 매핑한다. 실측 전에는 미분류로 두고 추측 분류를
  만들지 않는다.
- 세션 만료/재로그인 필요: `vibe /whoami` 준비 검사가 실패하는 것으로
  감지해 lane 상태에 반영한다(운영자 알림). 자동 재로그인을 시도하지
  않는다.

## 3. 변경되는 것

- 새 runtime lane 모듈(참조: runtime_claude_code.ml 구조)과 카탈로그/런타임
  표면, keeper 배정 가능 항목 추가. runtime.toml 스키마는 provider 표 한 줄
  추가 외에 바뀌지 않는다.
- 기존 mistral HTTP 레인($30 pool)은 그대로 둔다. 두 레인은 pool 이 다른
  별개 레인이고, 배정이 둘 중 하나를 고른다.

## 4. 순서

1. 구현 Task(MASC 별도 등록)의 첫 층: programmatic 호출 계약 실측 —
   fixture 촬영(`--output json`, `streaming`, `export.json`, exit code 0-3,
   `off`/`none` 수용). 문서와 실제가 어긋나면 이 RFC Deferred.
2. 있으면: 출력 코덱(json/streaming/export.json) → exit code typed 분류와
   준비 검사 → 카탈로그·배정 표면 → keeper 1곳 시범 배정.
3. 각 층은 스택 PR 이고, 계약 시험은 코덱 파싱·분류·인자 조립만 둔다
   (TUI 문구·화면 시험 금지 규칙 그대로).
4. 연기 항목의 소유: 다계정 스택은 첫 층 실측 뒤 #49200 계열로 MASC task
   를 따로 등록해 소유자를 정한다(이 RFC 는 단일 계정만 약속). 콘솔 막대
   의미 확인은 운영자 확인 사항으로 연구 문서 §6 에 남긴다.

## 5. 리스크

- `--output json`/`streaming` 프레임과 `export.json` 의 필드 수준 스키마는
  문서가 개요만 적는다 — 첫 층 fixture 없이 코덱을 세우면 계약이 상상이
  된다(최대 리스크. 초판의 "headless 부재" 리스크는 문서 확인으로 해소).
- 문서의 "shared usage" 문장이 참이면 pool 분리 전제가 흔들린다 — 실측
  (콘솔 두 막대의 소진 곡선)으로 1차 검증한다.
- CLI 자동 업그레이드(`--check-upgrade`)로 인자·출력이 바뀔 수 있다 —
  lane 은 버전을 고정해 시작하고 변경 시 실측을 다시 돌린다.
