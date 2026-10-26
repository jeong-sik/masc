# One-click dashboard build stamp Linux runtime R1

## 결과

one-click image는 dashboard SPA의 `index.html`을 포함했지만
`/app/assets/dashboard/.build-stamp`를 만들지 않았다. 서버는 실제로 제공 가능한
bundle을 매 boot마다 `missing`으로 판정하고 잘못된 build-in-place recovery를
제안했다.

runtime stage가 dashboard bundle을 복사한 직후 `.build-stamp`를 생성하도록
바꿨다. 이 layer의 parent에는 server binary copy가 포함되므로 binary가 바뀌면
stamp layer도 다시 생성된다. 최종 image 안에서 stamp는 binary보다 오래되지
않는다.

## exact identity

- source change commit: `5dff3418b93a2d42e700ab0637fca7da66718de7`
- Linux measurement composition/embedded commit:
  `f0177475827fe7de25cd78edd6182607a628f8f0`
- Linux/arm64 image digest:
  `sha256:cbfd831f9fbfe856ac55485ee4adc47fbb5a8c2f39fe06817a9c20dcce8cff3f`
- binary SHA-256:
  `55221b8df5ecc16110a81b912bd2138b26dbf9ae88e024033534f2c43b384af5`
- first runtime instance: `01a051bb-10eb-7000-a5a4-30c73f14838d`
- restarted runtime instance: `01a051bb-5d5c-7000-b244-e7ada5003250`
- effective base path: `/app`
- effective MASC root: `/app/.masc`

Git remote context와 `BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 이미지를 만들었다.
container `build-commit`, `/health?full=1`, binary hash가 같은 source head를
가리켰다.

## baseline

직전 composition `bc24e2872aba9effc70cab75b23ae23656ff9c00`의 r12는
fresh boot와 실제 restart에서 아래 warning을 각각 기록했다.

```text
bundle build-stamp unavailable at /app/assets/dashboard/.build-stamp — dashboard assets may be missing or unbuilt
```

`/health?full=1`은 `index_present=true`와 index SHA-256을 제공하면서도
`dashboard_surface.status=missing`, recovery
`build_in_place/unbound_assets_missing`을 반환했다. baseline image digest는
`sha256:7688c5ab6c64f9ae4db31de0c9e0f20e622d0729cb6d89fc6c645182d9fd9eda`,
binary SHA-256은
`d3e7c5e13f79c8ad6e00e3132621884fe3019b8b74fba700ad3998cd5055ce65`였다.

## fixed 실측

fresh r13 health는 `dashboard_surface.status=ok`, `index_present=true`, recovery
`none/surface_ready`였다. build-stamp missing/stale warning은 0건이었다.

같은 exact-head container를 실제 restart해 runtime instance가
`01a051bb-10eb-...`에서 `01a051bb-5d5c-...`로 바뀌었다. restart health도 status
`ok`, recovery `none`을 유지했고 warning은 0건이었다. container filesystem에서
binary mtime은 `1788077592`, stamp mtime은 `1788077593`으로 stamp가 1초
새로웠다. served `index.html` SHA-256은 health의
`aec4425c27f2f8a3de910fa00f5064190ee472e2fbdab0e6d392fd17e68a9eda`와 같았다.

Keeper와 provider turn은 실행하지 않았다. container
`masc-dashboard-stamp-fixed-r13`과 volume
`masc-dashboard-stamp-fixed-r13-data`는 정지·보존했다.

## 검증

- `scripts/dune-local.sh build test/test_install_script.exe`
- one-click stamp static contract exact test 1/1
- config_seed group 10/11
  - 변경 관련 새 케이스는 통과
  - 기존 `--force refreshes same-version existing binary`는 이 worktree에 local
    `main_eio.exe` prerequisite가 없어 실패
- fresh Linux/arm64 health/status/mtime/warning 판정
- 같은 container의 실제 restart 뒤 동일 판정

## 남은 경계

one-click은 exact dashboard asset manifest/receipt를 싣지 않으므로 health의
`dashboard_manifest_root`와 build-input provenance 필드는 계속 `null`이다. 이번
수정은 unbound one-click bundle의 freshness stamp만 복구한다. exact bound-asset
deployment 계약은 바꾸지 않았다. deployed `/Users/dancer/me/.masc`는 바꾸지
않았다.

## 근거

- [근거] Git remote-context build log, image inspect, container `build-commit`,
  `/health?full=1`, binary/index SHA-256, filesystem mtimes, fresh/restart logs,
  2026-08-30T17:14:24+09:00 확인, 신뢰도 High.
