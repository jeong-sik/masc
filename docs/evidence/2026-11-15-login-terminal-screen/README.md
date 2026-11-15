# 터미널 로그인 화면 실측 (2026-11-15)

Antigravity CLI(`agy` 1.5.9)는 `login` 명령이 없어서 masc 가 PTY 에서 전체 화면으로
띄워요. 이 기록은 그 화면이 서버의 가상 터미널(`matrix.vte` 0.2.0)을 거쳐 TUI·대시보드에
어떻게 닿는지 잰 결과예요.

## 무엇을 쟀나

| 파일 | 내용 | 어떻게 |
|---|---|---|
| `agy-raw-pty-output.txt` | 빈 HOME 에서 `agy` 를 PTY 로 5초 띄웠을 때 나온 바이트(파이썬 repr) | `pty.fork` 로 직접 띄움, `TERM=xterm-256color` |
| `agy-screen.ansi` | 같은 `agy` 를 `Runtime_setup_login_session.run ~terminal:true` 로 띄우고, 4초 뒤 아래 화살표를 보낸 다음 1.5초 뒤 취소했을 때 마지막 `Screen` | 임시 실행 파일로 헬퍼·PTY·VTE 를 실제 경로대로 거침 |
| `agy-screen.txt` | 위 화면에서 SGR 만 뺀 글자 | `\x1b[...m` 제거 |
| `dashboard-setup-login-antigravity.png` | 설정의 로그인 패널이 `screen` 두 번(스피너 → 위 화면)을 받은 뒤 | `screen-proof.mjs`, Playwright headless, 1280 x 1000 |

## 결과

- 날 바이트에는 `\r`, 커서 위로(`\x1b[3A`), 한 줄 위로(`\x1bM`)가 들어 있어요. 줄 단위로
  읽으면 이 화면들이 겹쳐요.
- `agy-screen.txt` 에는 CR·탭·백스페이스·ESC 가 하나도 없어요(각 0개).
  "Signing in..." 줄은 `\r` 로 덮여 사라졌고, 아래 화살표 뒤 `>` 는 2번 항목에 있어요.
- `Screen` 은 3번 왔어요. 아래 화살표 전에 2번, 뒤에 1번이에요.
- 대시보드 패널은 마지막 화면만 보여 줘요. 스피너 글자가 남지 않았고, 24줄 화면 전체가
  높이 제한 없이 보여요.

## 한계

- 대시보드 실측은 브라우저 안에서 `fetch` 를 바꾼 모의 API 로 했어요(`dashboard/e2e/setup-account-login.mjs` 와 같은 방식).
  실제 서버를 띄워 잰 것이 아니에요. 화면 글자는 위의 실제 `agy` 화면을 그대로 썼어요.
- 로그인 뒤 나오는 화면(색 고르기, 약관)은 계정이 없어 재지 못했어요. 그 화면이 80 x 24 안에 다 들어가는지는 확인 필요예요.
- TUI 화면은 사람 눈으로만 볼 수 있어요. TUI 시험은 `screen` 이벤트 해석과 앞 화면 교체(저장한 상태)만 봐요.
