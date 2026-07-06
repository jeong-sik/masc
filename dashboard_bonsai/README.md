# dashboard_bonsai

Jane Street **Bonsai** (OCaml + js_of_ocaml) 기반 masc 대시보드 island.
기존 Preact 대시보드(`../dashboard/`)와 URL prefix로 공존 — 점진 이전(lift-and-shift) 중.

- **Preact**: `/dashboard/*` (기존)
- **Bonsai**: `/dashboard/b/*` (이 디렉토리)

## Design system SSOT

본 surface는 [`../dashboard/design-system/SPEC.md`](../dashboard/design-system/SPEC.md)의 canonical design system을 따릅니다.

- Token vocabulary (raw/semantic/role) 및 5 named theme variants(`dark-fantasy`/`cyberpunk`/`terminal`/`parchment`/`paper`)는 SPEC §3, §4에 정의.
- ARIA 패턴(region · list · tablist · radiogroup · log · dialog)은 [`../dashboard/design-system/patterns/a11y/`](../dashboard/design-system/patterns/a11y/)에 JSX + Bonsai 예시로 카탈로그화.
- bonsai 자체 raw token은 점진적으로 SPEC canonical로 정렬 중. 새 token/패턴 추가는 SPEC PR 선행.

## 현재 상태 (Phase 0 ~ 1 진행)

- `/dashboard/b/hello` — Bonsai 부트 확인용 (logs_view 전체 렌더)
- Mock 섹션: moonrise narrative · focus card · roster · cycle activity · context pressure
- Live 섹션: 3s polling logs stream (`Logs_var` + `Logs_fetch`)
- 5 테마: `dark-fantasy` (default) · `cyberpunk` · `terminal` · `parchment` · `paper`

## Toolchain

OCaml 5.5.0+options + Jane Street v0.18 preview 패키지.

- 컴파일러: `ocaml-variants.5.5.0+options`
- Bonsai: `v0.18~preview.130.83+317` (OxCaml repo)
- 이전 stock OCaml 5.3/5.4 + janestreet-bleeding 조합은 macOS 26 SDK(`dispatch/base.h`
  `fallthrough` 매크로 충돌)와 충돌했으므로 사용하지 않는다.

### 1회 switch 셋업

```bash
opam switch create bonsai-dashboard ocaml-variants.5.5.0+options \
    --repos ox=git+https://github.com/oxcaml/opam-repository.git,default \
    --no-install
opam install --switch=bonsai-dashboard \
    bonsai ppx_css virtual_dom brr ppx_yojson_conv
```

OxCaml 레포를 전역 등록하지 않고 switch 내부에만 두는 격리 설정.

## 빌드

프로젝트 루트 Makefile에 통합:

```bash
make bonsai-dashboard          # 전체: ml → main.bc.js + CSS 토큰
make bonsai-dashboard-tokens   # CSS 토큰만 빠른 재배포
```

둘 다 결과를 `../assets/dashboard_bonsai/`에 복사 → 서버가 정적 서빙.
수동 빌드는:

```bash
eval $(opam env --switch=bonsai-dashboard --set-switch)
dune build --root .
```

컴파일 산출물: `_build/default/bin/main.bc.js` (~62MB debug 빌드, js_of_ocaml 통상적).

## 서빙

- `lib/server/server_routes_http_pages.ml` — `/dashboard/b/*` 라우트 등록
- `lib/server/server_routes_http_routes_frontend.ml` — `assets/dashboard_bonsai/*` 정적
- 번들 캐시 버스트: `main.bc.js?v=<mtime>` · `colors_and_type.generated.css?v=<mtime>`

## 레이아웃

```
dashboard_bonsai/
├── bin/
│   ├── main.ml           # Bonsai entry, theme listener, moon clock tick
│   └── dune
├── src/
│   ├── app.ml            # root component
│   ├── logs_view.ml      # dashboard shell (ppx_css + view 함수)
│   ├── logs_types.ml     # JSON response record + of_yojson
│   ├── logs_var.ml       # Bonsai.Expert.Var for logs stream
│   ├── logs_fetch.ml     # fetch + 3s polling
│   ├── hello_view.ml     # legacy smoke page
│   ├── sse.ml            # EventSource helper (Phase 0.4)
│   └── dune
├── static/
│   ├── colors_and_type.generated.css   # DS token SSOT — codegen 출력
│   │                                    # (dashboard/design-system/tokens/source.ts)
│   └── themes/archive/                  # 보존된 brand-voice 테마 (cyberpunk/terminal/parchment, link 안 됨)
└── dune-project
```

## 스타일

- **ppx_css 블록** inline (각 view 파일 내부)
- **`static/colors_and_type.generated.css`**: DS token SSOT — `--bg-*` / `--text-*` / `--accent-*` / `--status-*` / `--t-*`. 편집 금지 (`pnpm tokens:build` 산출물, source: `dashboard/design-system/tokens/source.ts`).
- Tailwind는 Preact 잔존 탭에서만 사용 (`../dashboard/`)

테마 전환:
- 활성 테마: `dark-fantasy` (default) / `paper` (light surface)
- URL hash: `#paper` (또는 `#dark-fantasy`)
- localStorage: `masc.bonsai.theme` 키로 영속화
- 하단 theme chip 클릭 → `<html data-theme>` 속성 교체
- 보존된 brand-voice 테마(`cyberpunk` / `terminal` / `parchment`)는 `static/themes/archive/`에 reference 로 남김. codegen SSOT 에 포함되지 않으므로 hash 로 전환해도 fallback 됨.

## 아직 mock (pending 표시)

| 섹션 | 필요한 endpoint |
|------|----------------|
| focus card (ctx / turn / mem / latency) | keeper status |
| cycle activity swimlane | session tool-span trace |
| context pressure chart | keeper status (per-cycle ctx %) |
| roster 4 slot | keeper status |
| moonrise `base=` / `operator` | server config + identity |
| nav crumbs | router |

## Phase 계획

`~/me/planning/claude-plans/masc-eventual-parrot.md` 참조. 요약:

- **Phase 0**: foundation (hello world, SSE helper 스파이크) — 완료
- **Phase 1**: shared types + logs island — 진행 중 (3s polling 동작 중)
- **Phase 2**: connectors / workspace (차트 없는 탭)
- **Phase 3**: 차트 바인딩 (mermaid → d3 → vis-timeline → cytoscape → vis-network)
- **Phase 4**: monitoring / command (차트 의존 탭)
- **Phase N**: `/dashboard/b/*` → `/dashboard/*` 승격, Preact 폐기

## 원칙

- **Lift-and-shift, not redesign**: 레이아웃/IA 변경 금지. UI 개편은 Phase N+1.
- **Pixel parity**: ±2px / hex 동일. 그 외는 버그.
- **OAS 경계**: `agent_sdk` 무변경. 프론트-서버는 JSON over HTTP + SSE만.
- **핸들러 JSON 계약 고정**: `lib/dashboard/*.ml`은 수정 금지, typed record로만 refactor.
