측정 helper 수정본 `b43594f33f14edbe18d07eb98fac62e8a99c3803f74b0a04fd215ed0e0d30efd`을 독립 검토했습니다. 이 helper 범위에 남은 P0/P1/P2를 발견하지 않았습니다. 제품 후보 `bae45a3e`의 성능이나 GC 개선을 증명하는 판정은 아닙니다.

네 가지 대응은 원래의 「PTY 입력 쓰기에서 같은 draft prefix 출력 관측까지」 의미를 유지합니다.

- ANSI 해석·prefix 검색은 자식 종료 뒤로 이동했고, reader는 chunk timestamp·bytes 보관과 짧은 frame marker 확인만 합니다. PTY draining에 무거운 해석이 끼던 경계를 제거합니다. observer scheduling 비용이 사라졌다는 뜻은 아닙니다.
- PageDown preposition은100 PageUp writes로 늘었습니다. 보존된 corrected run에서 실제 write 수100, 이후 PageDown writes73을 확인했습니다. 이것은 입력 workload의 증거이며 적용된 viewport offset을 직접 관측한 증거는 아닙니다.
- 5-byte frame-end marker를 4-byte carry로 검사해 모든6개 단일 split 위치를 인식했습니다.
- streaming decoder는 OSC BEL/ST, DCS/PM/APC의 숨은 payload를 어떤 split에서도 draft prefix로 세지 않았습니다. 모든 단일 split 및 한 byte씩 feed하는 경우와 CSI 분할도 통과했습니다.

추가 P2 하나를 발견해 root에게 전달했고 수정 후 독립 재확인했습니다. 이전6254b195 버전은 decoder 결과를16KB로 자르고 검색해서 유효 prefix 뒤17,000 bytes를 한 read로 받으면 ACK를 놓쳤습니다. 같은 byte stream을 같은 timestamp의 두 read로 나누면 ACK가 생기는 반례였습니다. 수정본은 전체 feed를 먼저 검색하고 `max(prefix UTF-8 length)-1`의 boundary carry만 그 뒤 보존합니다. 원래17,013-byte 단일 read 반례는 이제 ACK2.0이며, 분할형도2.0입니다. Unicode25-byte prefix의 모든26개 byte split과 prefix 자체17,012-byte인 cross-chunk fixture도 통과했습니다. [전후 fixture 결과](pure-byte-fixture-results.after.json)에 실제 helper AST로 실행한 기록이 있습니다.

기존 synthetic capture13개, ACK record413개를 원래 chunk 크기·timestamp대로 재생했습니다. 수정본과 원래 ACK timestamp 차이는0개였고, 전체 feed를 먼저 검색하는 독립 기준과의 차이도0개였습니다. 따라서 보존된 run의 수치를 수정해야 하는 사례는 발견하지 못했습니다. 초기 반례와 이후 수정 증거는 둘 다 보존했습니다. [실제 capture 재생 결과](capture-replay-results.after.json).

`WORKING-NOTES.md`의 no-Enter 절대 표현은 optional `--verify-submit`을 설명하도록 정정됐습니다. 보존된 `submit-unicode-eb4/pageup/result.json`에서 chat-stream POST는 정확히1회이고 `body.message`가 마지막 prefix와 정확히 같습니다. 이는 설치된 baseline의 그 Unicode/PageUp scenario에서 editor→serialized request까지 보존됐다는 추가 증거입니다. 실제 Keeper/model 수신, candidate 입력 손실 일반 부재, physical paint로 확대하지 않습니다. 이전 profile run은33개 ACK가 모두 있더라도 final ready suffix timeout으로 incomplete였고, 이를 기능 실패로 해석하지 않는 notes 설명과 맞습니다.

P3 표현 보완은 남습니다. 「PageDown starts100 pages back」보다 「100번 PageUp positioning write를 보낸다」가 직접 증거와 같습니다. 최종 A/B는 같은 helper hash·합성 history·positioning·실제 key gap을 맞추고 profiler/alloc run을 별도로 세어야 합니다. 한 쌍의 quantile만으로 GC/latency 개선을 확정할 수 없습니다.

이 리뷰는 source와 보존 byte 재생 및 순수 byte fixture만 사용했습니다. 실제 TUI/PTY, 네트워크 서버, 빌드, CI, 제품 수정, 외부 게시를 실행하지 않았습니다. 원문 snapshot과 각 hash는 [REVIEW-RESPONSE.json](REVIEW-RESPONSE.json)에 결속했습니다.
