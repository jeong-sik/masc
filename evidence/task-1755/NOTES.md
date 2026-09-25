# task-1755 — approve-guard `--replace-own-cr` → `--replaces` 개명

이 폴리싱은 순수 개명이다. 실질 CR-지목 판정 로직은 **#38950(`pangyo-preachers`, head `20ebfe5`)**로 이미 main에
병합됐고, 그 PR의 본문에 "This PR does task-1755"라고 명시돼 있다. 이 PR은 그 옛 철자 `--replace-own-cr`를
계약 철자 `--replaces`로 옮긴다. 열린 pangyo CR PR은 없다(현재 열린 pangyo CR은 이 개명과 무관한
#39001의 `jeong-sik` 소유 CR).

## 실행 영수증
- `bash scripts/review/approve-guard-selftest.sh` → **pass=46 fail=0, rc=0** (01-selftest.log)
  - `red-control-main-guard-refuses` 이제 실제 실행됨(이전엔 조용히 skip, 루트원인은 REPO_ROOT 의 cd stdout 유실).
  - 목록에 `--check`·`--replace-own-cr` 거절 케이스가 포함돼 있음:
    `replaces-not-digits`, `legacy-replace-own-cr-flag-exits-1`.

## live `--check` / 거절 출력 (verifier 요구 2)
셀프테스트가 이미 live 거절을 고정해 포함한다:
- 새 철자 유효성 검사(`--replaces abc`): `--replaces must be a review id (digits)` → rc=2 (04-replaces-not-digits-refusal.log)
- 옛 철자 거절(`--replace-own-cr 50`): `unknown argument: --replace-own-cr` → rc=1 (03-old-spelling-refusal.log)

## red control (변경 전 가드)
- `origin/main` 가드(sha256 `7a95bafbd979f50d9048cbc46e61b023cc980752a5902b0e4140b746aaa8c3f2`)는 `--replaces`를
  모른다 → `unknown argument: --replaces`, rc=1 (02-main-guard-unknown-argument.log). 변경 전 가드가 새 케이스를 거절함.

## 변경 파일
- `scripts/review/approve-guard.sh` (개명 + usage/주석/푸터)
- `scripts/review/approve-guard-selftest.sh` (케이스·리뷰 id + red-control skip 버그 수정)
- `changelog.d/39001.md` (`### Internal`, 기존 38974.md 조각 rename)
- `changelog.d/38950.md` 제거(대체)

## 출처 좌표
- PR #39001 (Draft, head d5a7e2cd): https://github.com/jeong-sik/masc/pull/39001
- CR-지목 로직 main 병합: #38950 (head 20ebfe5, base d6d26153)
