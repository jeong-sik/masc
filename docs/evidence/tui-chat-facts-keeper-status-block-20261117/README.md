# 채팅 아래 키퍼 상태 묶음: 고치기 전후

RFC `tui-one-screen-grammar` §5.5 의 첫 구현 층이 Keeper 채팅 입력 줄 아래의 키퍼 상태
묶음을 어떻게 바꿨는지 보여 준다.

## 무엇을 찍었나

같은 서버(`localhost:8935`)에 TUI 두 개를 차례로 붙여 같은 Keeper(`code-reviewer-mother`,
턴이 도는 중)의 채팅을 열고 창 폭 155·100·60열에서 찍었다. 전은 2026-11-17 00:5x KST, 후는
같은 날 09:4x KST 에 찍었다. 후는 항목 순서를 바꾼 뒤(상태 → 컨텍스트 → 다음 행동 → 런타임 →
토큰) 다시 찍은 것이다.

- `before.txt`: main(`ea0b8d1fd284`)을 빌드한 `masc_tui.exe`
- `after.txt`: 이 층을 빌드한 `masc_tui.exe`

두 파일 모두 입력 줄(`>`) 아래에서 키 안내 줄 앞까지만 담았다. 대화 본문과 키 안내 줄은
뺐다.

## 보이는 차이

| | 전 | 후 |
|---|---|---|
| 기본 보기(Ctrl-F 를 누르지 않음) | 키퍼 이름, 단계, 런타임, 토큰이 없다 | 어느 보기에서나 같은 항목이 나온다 |
| 런타임 ID | 155열에서 가운데를 자른다(`turn: glm-codi…red: glm-coding.glm-5.3-flash`) | 자르지 않는다 |
| 스트림 토큰, 멈춘 이유 | 155열에서도 나오지 않는다 | `tokens in: 73,715 · tokens out: 1,202 · cache read: 66,752 · stopped: tool_use` |
| 155열 | 한 줄 | 두 줄: 첫 줄은 상태·컨텍스트·다음 행동, 둘째 줄은 런타임·토큰 |
| 100열 | `running…` 뒤가 없다 | 네 줄에 모든 항목 |
| 60열 | 키퍼 이름도 자른다(`code-r…iewer-mother`) | 여섯 줄에 모든 항목 |
| 컨텍스트 | 폭에 따라 `18% 사용` 또는 `18% · 92,000/500,000 토큰` | 늘 `36% (181,681/500,000 토큰)` 꼴 |
| 컨텍스트 내역 키 | `Ctrl-X` | `Ctrl-X:컨텍스트 내역` |
| `● 정상` 의 색 | 다음 행동의 색(직접 메시지면 `95`) | 상태 색(정상 `92`) |

## 한계

- 색은 담지 않았다. tmux 를 설정 없이(`-f /dev/null`) 띄워 터미널 팔레트를 못 읽었고, 그때
  흐린 글자는 기본 글자색으로 나온다. 종류 색(슬롯 1·2)이 붙는 것은 `capture-pane -e` 로
  확인했다: 키퍼 이름·모드·gate·런타임은 `94`, 토큰 수와 컨텍스트는 `95`, `● 정상` 은 `92`.
- 전과 후는 아홉 시간쯤 떨어져 있다. 그 사이 값이 달라졌다(컨텍스트 92,000 → 181,681,
  토큰 수). 항목의 종류와 이름표는 같다.
- 줄 수는 값의 길이를 따른다. 100열에서 컨텍스트 항목이 첫 줄 끝에 3칸 모자라 다음 줄로
  갔고, 그래서 네 줄이다.
- 묶음이 창 높이에 눌려 `외 N` 으로 줄어드는 경우는 찍지 않았다. 그 결정은
  `test/test_tui_chat_facts.ml` 이 확인한다. 뒤쪽 항목부터 빠지므로 토큰 수가 먼저 빠지고
  Librarian 실패와 컨텍스트는 남는다.
- 뒤쪽 공백은 지웠다.

## 다시 만들기

```bash
tmux -L cap -f /dev/null new-session -d -s cap -x 155 -y 46 \
  "_build/default/bin/masc_tui.exe --base-path <base-path> --port 8935"
tmux -L cap send-keys -t cap Escape Tab Tab   # 키퍼 화면
tmux -L cap send-keys -t cap c                # 고른 키퍼의 채팅
tmux -L cap send-keys -t cap C-g              # 다음 키퍼 (원하는 키퍼까지)
tmux -L cap resize-window -t cap -x 100 -y 46
tmux -L cap capture-pane -t cap -p
```

전 화면의 Ctrl-F 보기는 `tmux -L cap send-keys -t cap C-f` 를 두 번 보낸 뒤 찍었다.
