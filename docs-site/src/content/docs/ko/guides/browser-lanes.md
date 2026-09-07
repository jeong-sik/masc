---
title: 브라우저 레인 매뉴얼
description: 운영자의 실제 Firefox(live 레인)와 Keeper 소유 브라우저(automation 레인)를 masc에서 읽는 방법 — 설정, 도구, TUI 리더.
---

레인(lane)은 연결된 브라우저 백엔드 하나를 뜻합니다. masc에는 두 개가 있습니다.

- **live** — 운영자의 실제 Firefox를 브라우저 레인 확장과 native messaging host로 읽습니다. 확장이 로드된 Firefox가 켜져 있는 동안만 존재하며, 열려 있는 탭을 운영자 눈에 보이는 그대로 읽습니다. **읽기 전용**입니다. live 레인은 `tabs.list`와 `page.read`만 노출하고 이동(내비게이션) 동사는 거부합니다.
- **automation** — Keeper 소유의 Playwright Firefox로, 운영자 프로필과 분리됩니다. URL 이동(`page.goto`)과 세션 열기/닫기는 이쪽에서만 동작합니다.

## 설정 (live 레인)

서버 쪽은 masc에 포함되어 있습니다. 운영자 머신에서 동작하는 조각은 두 가지입니다.

1. **native messaging host** — 빌드된 host를 Firefox의 NativeMessagingHosts 디렉터리에 설치합니다:

   ```bash
   ./connectors/browser/install-host.sh --base-path <.masc base 경로>
   ```

2. **확장** — `connectors/browser/extension/`을 `about:debugging` → *임시 부가 기능 로드*로 불러옵니다. 임시 로드는 Firefox를 끄면 사라지므로, 영구 설치에는 서명된 빌드가 필요합니다.

Firefox가 켜져 있으면 host가 masc 서버를 long-poll하고 레인이 `[connected]`로 표시됩니다.

## Keeper 도구

| 도구 | 레인 | 읽는 것 |
| --- | --- | --- |
| `masc_browser_tabs` | live, automation | 열린 탭 목록: id, 제목, url, 활성 여부 |
| `masc_browser_read` | live, automation | 한 페이지의 보이는 텍스트(50k 상한, `[TRUNCATED]` 표시) |

둘 다 읽기입니다. 최근 poll이 없는 레인은 "not connected"로 즉시 답합니다 — 운영자의 브라우저가 항상 켜져 있는 것은 아니기 때문입니다.

## TUI 리더

`:` → `go Browser Lane`, 또는 Connectors에서 `B`를 누릅니다. 리더는 live 레인으로 시작해 열린 탭을 보여주고, `[`/`]`로 탭을 옮기며 페이지를 읽습니다. `l`/`a`는 live/automation 전환, automation에서 `g`는 URL 입력, `o`/`x`는 세션 열기/닫기, `Ctrl-O`는 선택 탭의 PNG 미리보기입니다. `Ctrl-^`로 리더를 숨기면 선택 탭, 스크롤, 작성 중이던 채팅 임시본은 그대로 남습니다.

Browser 진입은 연속 음성 모드를 종료하고 전송 대기 중인 녹취도 버립니다.

| 키 | 동작 |
| --- | --- |
| `l` / `a` | live / automation Firefox |
| `[` / `]` | 이전 / 다음 탭 이동하며 읽기 |
| `j` / `k`, 방향키 | 페이지 텍스트 스크롤 |
| Page Up / Page Down, Home | 페이지 스크롤 / 맨 위 |
| `r` | 탭 재탐색 및 페이지 새로고침 |
| `Ctrl-O` | 선택 탭 PNG 미리보기 |
| `g` | URL 입력(automation), Enter로 열고 Esc로 취소 |
| `o` / `x` | automation 세션 열기 / 닫기 |
| `Ctrl-^` / Esc / Left | 리더 숨기고 이전 화면으로 |

## 운영자 세션으로 읽기

live 레인은 Keeper가 운영자 눈으로 페이지를 읽는 방법입니다 — 운영자가 로그인한 페이지까지, 앱 토큰도 API 자격증명도 쓰기 경로도 없이. Firefox에 열려 있으면 읽을 수 있고, 열려 있지 않으면 읽을 수 없으며, 운영자 대신 무언가를 여는 일도 없습니다.
