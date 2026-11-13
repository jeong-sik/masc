# 구독 패널 — 콘솔의 첫 패널 (2026-11-13)

로그인한 사람의 콘솔에 구독 패널을 더한 층(#51797)의 기록이에요. 패널은 서버가 주는 구독(`GET /api/v1/auth/integrations`)과 그 사람의 계정·Runtime(`GET /api/v1/auth/provider-accounts`, #51794)을 읽어요. 그리고 계정마다 할 수 있는 일을 누르기 전에 보여 줘요. 재는 값과 브라우저는 위 폴더 README 의 "방법" 절과 같아요.

## 방법

- 바이너리. sha256 앞 12자리 `f1f1316dbfff` 이고, 커밋 `ed8976270ee4` 에서 빌드했어요. 콘솔을 싣는 서버 파일(`lib/server/server_account_console.ml`, `lib/server/server_accounts.ml`, `lib/auth/account_base.css`, `lib/auth/account_page.ml`)은 그 커밋과 #51797 head `966d142c3368` 사이에 차이가 없어요.
- bundle. #51797 head `966d142c3368` 의 `dashboard/` 에서 `vite build --config vite.accounts.config.ts --outDir <assets>/dashboard/accounts` 로 만들었어요. `index.html` 760 B, `assets/index-ByqZCjbU.js` 37,372 B(gzip 13.54 kB), `assets/index-Dpsqw0xz.css` 1,151 B 예요.
- 로그인 없이 실제 서버로 잰 상태 둘(`console_signed_out`, `console_no_bundle`)은 콘솔 폴더 README 와 같아요.
- 로그인한 상태 넷은 실제 서버가 답한 콘솔·sheet·빌드 파일의 header 와 바이트를 그대로 주고, 세션 경로와 패널의 두 JSON 경로만 대역(`harness/console-mock.mjs`)이 답해요. 서버의 두 JSON 경로를 본 것은 아니에요. 대역의 답 모양은 `lib/server/server_person_integrations.ml` 과 #51794 의 `lib/auth_preview.ml`(`provider_accounts`)을 따라요.
  - `panel_none`: 연결한 계정이 없어요.
  - `panel_each`: 계정 다섯이에요. Claude Code(모델 셋, 그중 하나는 한 단어로 된 긴 id, 하나는 서버 설정에 없음), Codex(서버가 Keeper 실행을 막음), 서버가 더는 주지 않는 구독(muse), 로그인 기록이 없는 계정, 모델을 아직 확인하지 않은 Claude Code 예요.
  - `panel_each_admin`: 같은 계정 다섯을 Admin 이 봐요.
  - `panel_unread`: 구독 목록이 503 이에요.
- 대조군(`control_no_style_source`). `panel_each` 와 같은 저장 화면을, 정책에서 `style-src 'self'` 만 빼고 줘요.
- 운영 중인 설치는 쓰지 않았어요.

다시 재려면 `axe.min.js`(axe-core 4.14.0)를 `harness/` 안에 두고 아래를 돌려요. 마지막 인자 `panel` 이 위 상태들을 골라요. 이 인자가 없으면 콘솔 틀의 상태(`console/README.md`)를 재요.

```sh
sh harness/console-layer.sh <masc 바이너리> panel <출력 폴더> <빈 포트> <assets> panel
python3 harness/console-table.py <출력 폴더>/panel-answers.json <출력 폴더>/panel-measure.json
```

## 결과

수치는 `panel-measure.json`, 서버의 답은 `panel-answers.json` 이에요. 표는 `harness/console-table.py` 가 만든 그대로예요.

| 상태 | 도착한 주소 | axe 위반 | incomplete | CSS 규칙 | 정책 위반 | `style` 속성 | 24px 미만 대상 | 가장 낮은 대상 | 보이는 조작 대상 | 첫 Tab | 320px 가로 넘침 | 시도 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| console_signed_out | `/` | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 1 | `button#go` | none | 1 |
| console_no_bundle | `/accounts/console` | 0 | 0 | 34 | 0 | 0 | 0 | 44px | 1 | `a` | none | 1 |
| panel_none | `/accounts/console` | 0 | 0 | 42 | 0 | 0 | 0 | 44px | 2 | `button` | none | 1 |
| panel_each | `/accounts/console` | 0 | 0 | 42 | 0 | 0 | 0 | 44px | 2 | `button` | none | 1 |
| panel_each_admin | `/accounts/console` | 0 | 0 | 42 | 0 | 0 | 0 | 44px | 2 | `button` | none | 1 |
| panel_unread | `/accounts/console` | 0 | 0 | 42 | 0 | 0 | 0 | 44px | 3 | `button` | none | 1 |
| control_no_style_source | `/accounts/console` | 0 | 0 | 0 | 2 | 0 | 2 | 20px | 2 | `button` | none | 1 |

- 일곱 상태 모두 보이는 경로 답 원문(HTTP 상태나 JSON)과 자유 입력 칸이 0 이에요.
- 대조군은 CSS 규칙 0, 측정 도구가 돌기 전 정책 위반 2건(sheet 둘), 24px 미만 대상 2개예요. 그래서 이 측정이 sheet 거절을 잡는다는 것도 확인돼요.
- `panel-panel_each-320.png`(폭 320px)에서 본 것:
  - 카드 위 한 줄이 Keeper 를 실행할 수 있는 구독으로 Claude Code 만 대요. Codex 는 서버가 막아요.
  - 모델을 확인하지 않은 Claude Code 계정에는 `모델 확인 필요` 만 있고 Keeper 칸이 없어요.
  - Codex 계정은 `Keeper 실행 불가` 와 까닭 한 문장을 보여 줘요.
  - 서버가 더는 주지 않는 구독과 로그인 기록이 없는 계정은 `여기서 쓸 수 없음` 하나만 둬요.
  - 긴 모델 id 는 하이픈에서 줄을 바꿔요. 가로로 넘치지 않아요.
- 다른 캡처(데스크톱, 다른 상태)는 저장소에 넣지 않았어요.

## 변이 검사

`mutants.py` 는 패널 코드(`dashboard/src/accounts/subscriptions.ts`, `wire.ts`)를 한 군데씩 바꾸고 `vitest run src/accounts` 를 돌려요. 시험이 못 잡은 변이는 `tsc --noEmit` 를 한 번 더 돌려 컴파일러가 막는지 봐요. worktree 가 아니라 `dashboard/` 복사본에서 돌려요.

```sh
python3 -I mutants.py <dashboard 복사본> <출력 tsv>
```

#51797 head `966d142c3368` 에서 35개 가운데 32개를 시험이 잡아요(`mutants-966d142c3368.tsv`). 남은 셋은 사실을 화면 글로 옮기는 자리예요. 화면 문구는 시험하지 않아서 위 캡처로 봤어요.

- `n06b`: 모델을 확인하지 않은 계정에도 `Keeper 실행 가능` 칸을 둬요.
- `n07b`: 늘 `모델 확인됨` 이라고 말해요.
- `p11`: 카드 위 한 줄이 서버가 막는 구독까지 대요.

이 변이들은 #51797 을 만드는 동안 세 번에 나눠 돌린 것을 모았어요. 앞선 실행의 결과는 저장소에 넣지 않았어요. 앞선 실행의 변이 가운데 이번에 뺀 여덟과 그 까닭은 `mutants.py` 의 `LEFT_OUT` 에 있어요.

## 확인하지 못한 것

- 실제 서버의 두 JSON 경로. 그 답은 #51754·#51794 의 OCaml 시험이 봐요.
- 실제 GitHub 로그인으로 끝까지 가는 흐름(시험용 OAuth App 필요), 스크린 리더 낭독.
- 다른 탭에서 로그인한 사람이 바뀐 경우. 이슈 #51821 이에요.
