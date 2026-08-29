---
rfc: "keeper-github-apps"
title: "keeper별 GitHub App 신원 — 공유 봇 계정을 App installation 토큰으로 교체"
status: Draft
created: 2026-08-29
updated: 2026-08-29
author: claude
supersedes: []
superseded_by: null
related: []
---

# keeper별 GitHub App 신원

## 현재 상태 (2026-08-29 실측)

keeper 전원이 단일 봇 계정 `anyang-keepers`의 OAuth 토큰 하나를 공유한다.
keeper별 `keepers/<name>/github-cli/` (0700)에 같은 자격이 복제되어 있고
(`keeper_github_identity.ml`, task-849 증거), 토큰 스코프는
`gist, read:org, repo`다.

동작은 한다. 문제는 신원 모델이다.

| 문제 | 실태 |
|---|---|
| attribution 불가 | 커밋·PR·리뷰가 전부 `anyang-keepers` — 어느 keeper의 행동인지 GitHub 쪽 기록으로 구분 불가 |
| 권한 회수 단위 | 토큰 1개 = 함대 전체. keeper 하나를 끊으려면 전부 끊긴다 |
| 토큰 수명 | 장수 OAuth 토큰, 수동 회전. 유출 시 blast = 계정 전체의 `repo` 스코프 |
| 권한 범위 | 계정 전역 — repo별·권한별 최소화 불가 |
| 저장소 생성 소유 | 항상 `anyang-keepers` 개인 네임스페이스. `jeong-sik`(개인 계정) 아래 생성은 구조적으로 불가 |

## 제안

keeper당 GitHub App 1개. 인증은 App private key → JWT → **installation
access token(1시간 만료)**.

- attribution: 커밋·PR이 `<keeper>[bot]`으로 남는다. 감사·리뷰·차단이 keeper 단위가 된다.
- 권한: App 권한 선언(contents, pull_requests, issues, metadata …)과 installation 대상 repo 선택으로 이중 최소화.
- 수명: 토큰이 1시간짜리라 회전이 구조에 내장된다. 유출 blast가 keeper 1 × 1시간으로 준다.
- 저장소 생성: App은 사용자 소유 repo를 만들 수 없다. **org가 필요하다** — org에 installation + repo `administration` 권한이면 `POST /orgs/{org}/repos`로 생성 가능. keeper 산출물의 귀속처가 자연히 org로 정리된다 (소유가 계정을 따라간다는 결론의 구현형).

## masc 쪽 구현

1. **저장 계약** — `keepers/<name>/github-app/`: `app-id`, `installation-id`,
   `private-key.pem` (0600). 기존 `github-cli/` 디렉터리 계약과 병렬.
2. **token broker** — turn 시작 시(또는 만료 5분 전) JWT(RS256, iss=app-id,
   10분) 서명 → `POST /app/installations/{id}/access_tokens` → `ghs_…` 토큰을
   keeper의 `github-cli/hosts.yml`에 갱신 기록. 현재 계약(토큰 env 미투영,
   config-dir 단일 경로)을 그대로 유지하므로 exec/ssh 레인의 `GH_CONFIG_DIR`
   주입은 무변경. RS256 서명은 mirage-crypto-pk로 구현(신규 외부 의존 없음).
3. **`keeper_github_identity` 확장** — observation에 신원 모드
   (`Shared_oauth | App_installation`)와 만료 시각을 추가. 프로브가
   `<keeper>[bot]` 로그인을 확인한다.
4. **실패 계약** — mint 실패는 typed error로 turn에 보고(fail-closed).
   만료 토큰으로 조용히 진행하지 않는다.
5. **하드컷** — 전환은 keeper 단위로 한다(App 자격이 배치된 keeper는 App
   경로, 아니면 기존 공유 경로). 전 keeper 배치 완료 후 공유 계정 경로를
   제거한다. 호환 reader는 만들지 않는다.

## 운영자(GitHub 쪽) 절차 — 코드가 대신 못 하는 부분

1. org 생성 또는 선택 (예: `anyang-keepers-org`). 저장소 생성 소유처.
2. keeper별 App 등록 — manifest flow로 반자동화 가능
   (`https://github.com/organizations/<org>/settings/apps/new` + manifest
   POST). 권한: contents rw, pull_requests rw, issues rw, metadata ro,
   (생성 허용 keeper만) administration rw. webhook 없음.
3. App private key 발급 → `keepers/<name>/github-app/private-key.pem` 배치.
4. org에 install, installation id 기록.

keeper 9기 기준 등록 9회. manifest flow 스크립트를 masc `scripts/`에 두면
회당 1–2분.

## 단점·트레이드오프

- App 9개 관리 부담 (키 9개, 만료 없는 PEM — 유출 시 회수는 App 단위로 즉시).
- installation 토큰은 1시간마다 broker가 돌아야 한다 — broker 장애 = 함대 GitHub 작업 정지. 현재 모델(장수 토큰)에는 없는 가용성 의존.
- `gist` 스코프에 해당하는 App 권한이 없다 — gist를 쓰는 keeper 워크플로가 있으면 별도 경로 필요 (현재 사용처 미확인).
- 기존 `anyang-keepers` 소유 저장소들의 이관은 별도 작업.

## 검증 계획

- broker 단위 테스트: JWT 형식, 만료 갱신, mint 실패 typed 보고.
- 라이브 증거: keeper별 `gh api user` → `<keeper>[bot]`, PR 1건을 App 신원으로 생성, `keeper-github-identity-live` 증거 스키마에 모드 필드 추가.
