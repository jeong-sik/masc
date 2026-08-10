# RFC-OAS-010: release-please Adoption

| | |
|---|---|
| Status | Draft |
| Author | jeong-sik (with Claude analysis) |
| Created | 2026-05-08 |
| Target | `agent_sdk` (oas) v0.193+ |
| Supersedes | None |
| Related | None |

## 0. Summary

Version bump + CHANGELOG 작성 + tag 발행을 분리된 수동 작업에서 **`release-please-action` 단일 GitHub Actions 파이프라인**으로 통합한다. 변환 범위는 (1) `release-please-config.json` + `.release-please-manifest.json` 추가, (2) `.github/workflows/release-please.yml` 추가, (3) `dune-project` / `agent_sdk.opam` / `lib/sdk_version.ml` 에 `x-release-please-version` annotation 삽입, (4) 누락된 `[0.192.0]` + `[0.192.1]` CHANGELOG entry backfill 이다.

본 RFC의 의도는 *CHANGELOG 부채 청산 + 이후 누락 재발 차단 + tag 발행 자동화*이다.

## 1. Problem Statement

### 1.1 검증된 사실 (commit-pinned)

- `CHANGELOG.md` 헤더 검사: 가장 최근 entry 가 `[0.191.0] - 2026-05-07`. `[0.192.0]` (PR #1465-#1467 머지본) 과 `[0.192.1]` (PR #1469-#1474 머지본) 모두 부재.
- `dune-project:3` `(version 0.192.1)` — `lib/sdk_version.ml:4` 와 일치.
- `scripts/check-tag-drift.sh --strict --allow-current-untagged` exit code = 1 (verified 2026-05-08): `Current version lacks a CHANGELOG entry: dune-project version: 0.192.1, expected header: ## [0.192.1] - YYYY-MM-DD`.
- `.github/workflows/ci.yml:280-281` "Enforce tag drift (strict)" gate 가 위 스크립트를 호출 → main 의 모든 후속 PR 가 같은 fail 을 상속.
- `.github/workflows/release.yml` 부재 (직접 `find` 검증 2026-05-08). 즉 *tag push → artifact* 자동화 파이프라인은 이미 사라졌고 복원/재작성 필요.
- 누락된 entry 가 #1466 ("chore release 0.190.26 → 0.191.0") 머지 시점부터 누적.

### 1.2 무엇이 망가지나

1. **PR fail 사슬**: CHANGELOG 갱신을 누락한 채 bump PR 이 머지되면, 그 다음 모든 PR 의 `Release Tag Drift` gate 가 fail. 사용자 admin merge 가 일상화 → 메모리 `feedback_main_blocker_chain_4x_session.md` 에 기록된 회피 패턴 5회차.
2. **사람-주도 CHANGELOG 가 망각 위험**: bump PR 작성자가 이전 두 minor/patch range 의 변경을 직접 정리해야 하며, AI agent 가 자동 작성하면 hype words / 누락 위험.
3. **tag 발행 수동성**: `git tag` + `git push origin <tag>` 는 사람이 직접 했으나 release.yml 가 사라진 후로 artifact / smoke test 도 자동화되지 않음.

### 1.3 비-목표

- 모든 repo 일괄 적용 (masc-mcp, mcp-protocol-sdk, kirin 등) 은 본 RFC 범위 밖. 별도 RFC.
- `scripts/check-tag-drift.sh` 의 점진 deprecation 은 본 RFC 후속 PR. 일단 두 SSOT 가 공존하되 release-please 가 master 가 됨.

## 2. Proposal

### 2.1 도구 선택: release-please

근거 (출처: <https://github.com/googleapis/release-please/blob/main/docs/customizing.md>, 2026-05-08 확인):

- `release-type: simple` 이 language-agnostic 이며 OCaml 프로젝트에 적용 가능.
- `extra-files` 의 `type: generic` + 인라인 `x-release-please-version` annotation 으로 임의 파일에서 version 자동 bump.
- 기존 CHANGELOG entry 를 보존 (extend 방식).
- GitHub Actions 표준 액션 `googleapis/release-please-action` 으로 1 step 실행.

대안 비교 (간단):

| 도구 | 장점 | 단점 | 결정 |
|---|---|---|---|
| **release-please** | language-agnostic, GitHub native, CHANGELOG + version + tag 한 번에 | 외부 의존 (Google 메인테너) | **채택** |
| git-cliff | Rust CLI, simple | version bump 별도 스크립트 필요, release pipeline 직접 작성 | reject |
| 자체 구현 (`scripts/release.sh` 확장) | 외부 의존 0 | 유지보수 책임 자체 부담 | reject |

### 2.2 적용 범위

- `release-please-config.json`: `release-type: simple`, package root `.`, `extra-files` 로 `dune-project` / `agent_sdk.opam` / `lib/sdk_version.ml` 등록.
- `.release-please-manifest.json`: 현재 버전 `0.192.1` 기록.
- `.github/workflows/release-please.yml`: `on: push: branches: [main]` 트리거. release-please 가 PR 자동 생성 → 머지 시 tag + GitHub Release 생성.
- 인라인 annotation 추가:
  - `dune-project`: `(version 0.192.1) ; x-release-please-version`
  - `agent_sdk.opam`: `version: "0.192.1" # x-release-please-version`
  - `lib/sdk_version.ml`: `let version = "0.192.1" (* x-release-please-version *)`
- `CHANGELOG.md`: `[0.192.0]` + `[0.192.1]` entry backfill, PR 인용 기반, 동작 기술 (hype 금지, `tone.md` 준수).

### 2.3 검증

- 본 PR 머지 후 release-please 가 `Unreleased` 가 비어있다고 인지 → 다음 의미 있는 conventional-commit PR 가 머지될 때 release PR 자동 생성.
- 첫 자동 release PR 가 머지되면 `git tag v0.X.Y` + GitHub Release 자동 생성 → manual `git tag` 워크플로우는 deprecation.
- `scripts/check-tag-drift.sh` 는 한동안 보조 SSOT 로 유지. 후속 PR 에서 release-please-manifest 와의 cross-check 모드로 변경 검토.

## 3. Migration

### 3.1 본 PR (이번 단계)

- 위 §2.2 변경 일체 + CHANGELOG backfill.
- `ci.yml` 의 `Release Tag Drift` gate 는 **건드리지 않는다**. backfill 으로 `0.192.1` entry 가 추가되면 gate 가 자연 통과.

### 3.2 후속 PR (별도)

1. release-please 첫 자동 PR 가 정상 동작하는지 한 cycle 확인 (의미 있는 conventional commit 이 들어가는 다음 PR 이후).
2. `scripts/check-tag-drift.sh` 점진 deprecation: release-please-manifest 와 cross-check 하는 모드 추가, 또는 archive.
3. tag 시점 release artifact / binary smoke test (이전 `release.yml` 기능) 복원 필요 시 별도 RFC.
4. 다른 repo (masc-mcp 등) 도입 결정.

## 4. Risks

- **release-please-action 의 외부 의존**: Google 메인테너가 deprecate 할 위험. 완화: action 을 pin SHA 로 고정, manifest 가 vendor-independent JSON 이라 fallback 시 git-cliff 로 마이그레이션 가능.
- **첫 자동 PR 까지의 대기**: 본 PR 머지 후 의미 있는 conventional commit 이 main 에 들어가야 첫 release PR 가 생성됨. 그 사이 수동 tag 가 필요한 경우 기존 `git tag` 워크플로우 사용 (deprecated 라벨로 표시).
- **annotation drift**: `x-release-please-version` 마커 위치를 누군가 무심코 삭제하면 bump 가 누락됨. 완화: PR-time grep 검사 hook 추가 검토 (별도 후속).

## 5. References

- release-please customizing docs: <https://github.com/googleapis/release-please/blob/main/docs/customizing.md> (확인 2026-05-08)
- release-please-action: <https://github.com/googleapis/release-please-action>
- 메모리 `feedback_main_blocker_chain_4x_session.md` (이번 사건 5회차)
- PR #1466 (마지막 수동 CHANGELOG 갱신 시점)
