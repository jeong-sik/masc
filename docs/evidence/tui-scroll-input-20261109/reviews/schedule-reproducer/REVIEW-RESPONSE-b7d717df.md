C `b7d717df36de2aa91b62b413df3cad67739c499d`의 실제 `.mli`·`.ml`과 main 호출 위치를 대조했습니다. 두 시각 설계와 일치하며, 이 확인 범위에서 P0/P1/P2를 발견하지 않았습니다.

Input+ready만 Completed가 있으면 완료 시각, 없으면 Started를 기준으로 기존 interval을 더합니다. Background take와 input timeout은 모두 Started 기준입니다. Input+drained 및 Force의 즉시 Render, Input/Force timeout0은 유지됐습니다. Render 선택 때 Started를 새로 기록하고 이전 Completed를 비우며, completed는 완료 시각만 바꿉니다. pending과 Started를 덮어쓰지 않습니다. 실제 mli signature와 구현도 맞습니다.

production take는 main42671, completed는42799의 각각 한 곳입니다. 완료 호출은 normal Render의 동기 Build와 `time_present` 반환 뒤에만 있습니다. image/MSX, owned-frame deferral, Idle/Wait는 이 호출을 지나지 않습니다. Unchanged도 normal Build를 마친 뒤 여기에 도달하므로 비용은 pace하되 기존 presented authority를 새로 만들지 않습니다. 예외가 나면 이 완료 호출에 도달하지 않는 기존 흐름입니다.

source-extracted reproducer의 before/after schedule prefix는 각각 고정 Git 원문의 prefix와 byte 단위로 정확히 같습니다. before16dd4aa4의 전체 scheduler source도 C의 실제 parent d4ae1ead의 같은 파일과 같습니다. result.json의 전체 source SHA-256은 before `a09123bf5672e97e1daa06b5b21d7eccf000a3bfcd5c3c32dbdef599a57aec4f`, after `8fb5349d996dd00756e94c6335b776f4dd463cee41c94ede6f58d15437ac7482`로 둘 다 원본 Git 객체와 일치합니다. 추출 파일에는 원본 decision API 뒤에 별도 harness가 붙었으므로 추출 파일 자체의 hash와 전체 원본 hash는 서로 다른 값이라는 점도 따로 기록했습니다.

기록된 old Render / new `wait:80000000`의 의미도 맞습니다. interval16ms, 첫 take0ms, 다음 pending Input65ms일 때 old deadline은16ms여서 이미 지났습니다. new는 harness가 completed64ms를 기록하므로 deadline80ms이고65ms에는 Wait_until을 냅니다. 80,000,000은 ns이며80ms입니다. 이는 가정한64ms frame 완료 뒤의 순수 scheduling 결정 재현이고, 실제 frame이64ms 걸렸다는 측정이나 입력 latency 개선 증거는 아닙니다.

`independent-source-review-b7d717df.md`/json의5개 frozen file hash, head/base, 분기 설명, pending 보존, 동기 단일 호출 순서와 세 가지 새 tests 설명은 실제 source와 일치합니다. 세 tests는 state decision을 검사하며 화면 문구·row 배치 검사가 아닙니다. 별도 검토 기록과 마찬가지로 이 확인에서도 제품 tests를 실행하지 않았습니다.

[hash·추출 대조 결과](review-response-hash-checks.json), [고정 main 분기 원문](review-response-main-source.txt)에 증거를 남겼습니다. 이 reviewer는 바이너리 실행·재컴파일·제품 수정·빌드·CI 조회·실제 TUI를 실행하지 않았습니다. native dispatch의 완료·성공이나 B/C 성능 차이는 이 기록이 판정하지 않습니다.
