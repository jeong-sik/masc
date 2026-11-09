# Memory 팩트 브라우저: 팩트가 없을 때 (PR #50278)

## 실측

고정 서버 위 증명 빌드 둘로 같은 걸음을 걸었어요. 앞은 main(`0a7164246935`), 뒤는 이 PR(`deafbe5161c7`)이에요. 키퍼 `imp` 에 팩트가 없는 상태에서 `go Memory` → `Enter`(키퍼 행에서 팩트 브라우저 열기) → `Enter` 순서예요.

**팩트 브라우저 푸터** (몸통 줄은 두 빌드가 글자까지 같고 푸터 줄만 달라요. 시계와 실행마다 바뀌는 값은 가렸어요)

| 크기 | 빠진 키 | 새로 들어온 키 |
|---|---|---|
| 80x24 | `j/k`, `Enter` | `c / C`, `s` |
| 100x30 | `j/k`, `Home/End`, `Enter` | — |
| 120x34 | `Enter` | `c / C` |

**팩트가 없는 브라우저에서 `Enter`**

| 크기 | 앞(`Enter` 뒤) | 뒤(`Enter` 뒤) |
|---|---|---|
| 80x24 | 전체 화면 창 열림 | 목록 그대로 |
| 100x30 | 전체 화면 창 열림 | 목록 그대로 |
| 120x34 | 전체 화면 창 열림 | 목록 그대로 |

건강 표(키퍼 목록)는 세 크기 모두 두 빌드가 글자까지 같아요.

## 푸터 줄 전문

- 80x24
  - 앞: `ACTION NEEDED 3  j/k:move  Enter:detail  Esc:close / clear  q:quit  …?`
  - 뒤: `ACTION NEEDED 3  c / C:category  s:sort  Esc:close / clear  q:quit  …?`
- 100x30
  - 앞: `ACTION NEEDED 3  j/k:move  Home/End:top/bottom  Enter:detail  Esc:close / clear  q:quit  …?`
  - 뒤: `ACTION NEEDED 3 · keeper_fleet_safety:no_executable_keeper_fibers  Esc:close / clear  q:quit  …?`
- 120x34
  - 앞: `ACTION NEEDED 3 · keeper_fleet_safety:no_executable_keeper_fibers  Enter:detail  Esc:close / clear  q:quit  …?`
  - 뒤: `ACTION NEEDED 3 · keeper_fleet_safety:no_executable_keeper_fibers  c / C:category  Esc:close / clear  q:quit  …?`
