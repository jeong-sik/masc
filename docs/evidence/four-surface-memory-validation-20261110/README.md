# Memory 수리의 최소 실행 검사

이 기록은 #50708의 상태어 검색과 fleet 누락 범위 수리를 검증한다.
기존 A0 native 캡처, 전체 TUI 회귀 또는 설치된 실행 파일의 증거와 구분한다.

| 실행 | 실제 source | 범위 | 결과 |
| --- | --- | --- | --- |
| [42647821236](https://github.com/jeong-sik/masc/actions/runs/42647821236) | `671cf26047fdb8a8785bff33355972b3a1f03d66` | decode·Memory | failure. decode 407개 성공, Memory 14개 중 11개 성공·기존 UI 검사 3개 실패 |
| [42652183034](https://github.com/jeong-sik/masc/actions/runs/42652183034) | `b56552704a5b1350d636449d57c1ff0d920c8adc` | decode·Memory, `minimal=true` | failure. Memory 13개 성공, decode 407개 중 406개 성공·집계가 불일치하는 fixture 1개 실패 |
| [42654972273](https://github.com/jeong-sik/masc/actions/runs/42654972273) | `f35a50b9ec9ba4d3cdd03cf0d03ea57f5924f657` | decode만, `minimal=true` | completed/success. 407개 모두 성공 |

`initial-result.json`은 첫 실행의 terminal 결과다. `initial-selected.txt`는
선택된 결과 행과 세 실패의 기대·관측값을 원래 runner 시각과 함께 보존한다.
전체 로그를 대신하지 않는다. `rerun-request.json`은 두 번째 요청 직후 실제
head를 확인한 기록이며 완료 성공을 증명하지 않는다.
`restacked-result.json`과 `restacked-selected.txt`는 이 요청이 끝난 뒤의
terminal 결과와 선택 로그다. Memory 13개 성공과 실행 전체 failure를 구분한다.

첫 실패 뒤 UI 문구·배치 단언을 선택 ID·typed 분류 필터·이전 관측과 누락 범위·
원문·제어문자 안전성 검사로 정리했다. 수정 suite는 13개 사례다.
갱신 실패 뒤 실제 fleet 병합의 `Some unread_summary`가 facts와 함께 남고
미확인 수량이 0이 되지 않는지를 검사한다. 새 base의 v12 health·pending
payload·admission 대기에 맞춰 공통 표현과 검색을 결합했으므로 초기 decode
성공을 새 source의 실행 증거로 재사용하지 않는다.

두 번째 실패는 admission fixture가 미관측 durable 행의 unread 두 값을
`null`로 바꾸고도 fleet 합계를 `0`으로 둔 문제였다. SSOT는 하나라도
미측정이면 합계를 `None`으로 만든다. fixture의 합계를 시나리오별
`Some 0`/`None`으로 맞추고 decode 결과도 검사하도록 고쳤다. 제품 decoder의
엄격한 검증과 unknown을 0으로 보고하면 거절하는 기존 음성 검사는 유지한다.
이후 변경은 `test/test_tui_decode.ml` 한 파일뿐이다. 이미 성공한 Memory는
반복하지 않고 decoder suite만 다시 요청했다. `decoder-recheck-request.json`은
그 요청 직후의 실제 source 확인이다.
`decoder-recheck-result.json`과 `decoder-recheck-selected.txt`는 완료 뒤
API 결론과 runner의 407개 성공을 기록한다. 미관측 합계 보존과 잘못된 0의
거절 검사도 이 실행의 선택 로그에 있다. Memory 13개 성공은 앞 실행에,
decode 407개 성공은 후속 실행에 결속한다.

`source-binding.json`은 실행 source의 Git entries에서 `docs/`와
`changelog.d/`를 제외한 SHA-256이다. 후속 문서 커밋에서 소스·검사 입력이
같은지 대조하기 위한 값이며 빌드된 바이너리나 실행 증거가 아니다.
이 값의 source는 `b565527…`다. `decoder-recheck-source-binding.json`에는
후속 `f35a50b…`의 별도 digest와 두 source 사이에서 바뀐 파일을 기록했다.
이는 제품과 Memory suite가 그대로임을 결속하며, 이후 Usage 층의 코드가
이 최소 검사에 포함됐다는 주장은 아니다.

`published-native12-vector.json`은 문서 층을 더하기 직전 공개된 12개 PR의
head·base 기록이다. 새로 추가된 Usage #50730도 native rebase와 한 번의
atomic lease push에 포함했다. `usage-restack-preservation.json`은 Usage의
전체 diff가 재배치 전후 동일하다는 별도 소스 검토 결과다. Usage 구현의
새 승인이나 실행 결과로 확대하지 않는다.

선택한 test executable과 그 의존성의 실행만 다룬다. 전체 TUI/main 빌드,
Full CI, native 화면, 실제 Enter 이벤트, 설치·재시작·병합·배포는 검증하지 않았다.
