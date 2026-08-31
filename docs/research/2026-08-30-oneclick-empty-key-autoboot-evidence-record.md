# One-click empty-key autoboot 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T18:25:20+09:00`
- 작성자: `Codex`
- 결정 ID: `oneclick-empty-key-autoboot-linux-r1`
- 적용 대상: one-click classic preset provider prerequisite gate
- 결정 상태: `추적 필요`

## 근거

- 항목: shipped classic provider key가 없고 operator override도 없으면 autonomous
  keeper turns를 provider dispatch 전에 막아야 한다.
- 출처: exact-head fresh/restart/explicit-override Linux logs와 health
- 확인일시: `2026-08-30T18:25:20+09:00`
- 신뢰도: `High`
- 제한조건: classic preset과 empty Ollama Cloud key에서 측정했다.
- Delta: entrypoint가 implicit global keeper bootstrap을 false로 설정한다.

## 검증

- 1차: baseline이 네 401 provider turn과 네 keeper failure를 만드는 것을 확인했다.
- 2차: focused static test와 shell syntax가 implicit guard/explicit override 조건을
  고정했다.
- 3차: fixed fresh 35초와 restart는 provider request 0, override control은 4/4
  autoboot와 401을 유지했다.
- 재현 결과: 성공. implicit known-bad turns만 차단되고 explicit choice는 보존됐다.

## 불확실성

- 미확인 항목: volume에서 default runtime을 local/다른 provider로 변경한 classic
  team.
- 영향: Ollama key가 없어도 실행 가능한 operator config는 implicit guard 때문에
  bootstrap override가 필요하다.
- 추가 확인 필요: preset manifest에 typed provider prerequisite를 선언해 entrypoint
  shell 조건을 대체할지 별도 설계한다.

## 적용범위

- 영향 받는 영역: one-click docker entrypoint의 classic preset startup gate와
  focused static test.
- 제약/배제: global provider credential resolver, runtime TOML parsing, other presets,
  explicit bootstrap override, deployed runtime은 바꾸지 않았다.
- 롤백 조건: empty-key implicit 경로가 provider request를 보내거나, explicit true가
  무시되거나, server/dashboard까지 종료되면 롤백한다.
