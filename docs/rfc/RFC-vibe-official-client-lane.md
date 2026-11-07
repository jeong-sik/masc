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

### 2.1 lane 종류 — claude_code 패턴, 단 착수 조건이 있다

- lane 종류는 **command transport**(공식 CLI 감싸기)로 한다. 새 wire/HTTP
  codec 을 만들지 않는다: 응답 해석·도구 실행은 Vibe CLI 가 하고, masc 는
  프로세스 조종·턴 원장·관측만 소유한다. claude_code lane
  (lib/runtime/runtime_claude_code.ml)이 참조 구현이다.
- **착수 조건**: CLI 의 무인 1-shot 호출(`claude -p` 상당)이 존재해야 한다.
  문서상 headless 는 확인되지 않았다(연구 §3). 구현 Task 의 첫 층은
  `vibe --help` 전수 촬영과 1-shot 실행 실측이고, 무인 호출이 없으면 lane 을
  만들지 않고 이 RFC 를 Deferred 로 되돌린다. 세션형(`/branch`, `--resume`)
  조종을 masc 가 흉내 내는 우회는 만들지 않는다(워크어라운드 거부: 대화형
  TTY 조종은 취약하고 문서화 안 된 내부다).
- antigravity 패턴(OAuth 자격 증명 모듈 9개)은 Vibe CLI 가 자격 증명을 스스로
  provisioning 하므로 채택하지 않는다. masc 는 로그인 절차를 소유하지 않는다.

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
  Reasoning_effort `none/low/medium/high/xhigh/max`. 이름만 다른 `off`↔`none`
  은 lane 경계에서 한 번 바꾼다(문자열 비교 분기가 아니라 어휘표 한 줄).

### 2.4 사용량 관측

- Admin usage API 의 `vibe_usage` 는 Enterprise 전용이라 Pro 운영에서 못
  쓴다. lane 은 turn 단위 관측(세션/지연/출력 크기)으로 operator 뷰를 채우고,
  콘솔의 두 막대는 사람이 읽는 원장으로 남긴다. 예측 비용 계산을 lane 이
  발명하지 않는다.

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

1. 구현 Task(MASC 별도 등록)의 첫 층: headless 실측. 없으면 이 RFC Deferred.
2. 있으면: lane 뼈대(프로세스 조종+1-shot) → 준비 상태/실패 분류 →
   카탈로그·배정 표면 → keeper 1곳 시범 배정.
3. 각 층은 스택 PR 이고, 계약 시험은 준비 검사·실패 분류·인자 조립만 둔다
   (TUI 문구·화면 시험 금지 규칙 그대로).

## 5. 리스크

- headless 부재로 lane 전체가 Deferred 될 수 있다(가장 큰 리스크).
- 문서의 "shared usage" 문장이 참이면 pool 분리 전제가 흔들린다 — 실측
  (콘솔 두 막대의 소진 곡선)으로 1차 검증한다.
- CLI 자동 업그레이드(`--check-upgrade`)로 인자·출력이 바뀔 수 있다 —
  lane 은 버전을 고정해 시작하고 변경 시 실측을 다시 돌린다.
