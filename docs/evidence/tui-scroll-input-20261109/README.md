# 채팅 스크롤과 입력 지연 관측

긴 Keeper 대화를 스크롤하면서 입력하면 지연되는 문제를 조사했다.
측정값은 PTY에 입력을 쓴 시각부터 같은 draft prefix가 TUI 출력에서 처음
관측된 시각까지다. 터미널의 실제 화면 갱신이나 macOS IME 조합 중 지연은
측정하지 않았다. 공개 Codex·Claude Code와 같은 조건의 비교도 하지 않았다.

## 수정과 원인

- #50493은 TUI의 백그라운드 작업 domain을 1개로 두고, 닫힌 명령창의 상태
  투영과 live-edge의 불필요한 전체 source-point 수집을 없앴다. 이전의 서버용
  domain 기본값은 이 16-core 호스트에서 worker 14개를 만들었다. 느린 파일
  읽기와 응답 decode가 하나의 worker에서 대기할 수 있는 절충이 있다.
- #50502는 변하지 않은 immutable message/entry 리스트의 tagged projection을
  재사용한다. 매 프레임 리스트를 다시 만들면서 search-anchor 인덱스까지
  무효화하던 할당을 줄였다. 원본 리스트 중 하나가 바뀌면 다시 계산한다.
- 후속 C는 정상 프레임의 Build와 presentation이 반환된 시각을 기록한다.
  기존에는 16ms보다 오래 걸린 프레임 뒤에 입력이 더 남아 있어도 이미 지난
  시작 시각의 deadline으로 바로 다음 프레임을 만들었다. C는 이 경우 완료
  시각부터 coalescing 간격을 두어 쌓인 입력을 먼저 읽을 수 있게 한다.
  마지막 입력과 Force는 즉시 그리고, Background는 기존 시작 시각을 쓴다.

소스만 추출한 [상태 재현기](reviews/schedule-reproducer/result.json)는 64ms
프레임 뒤 65ms의 queued Input에서 기존 Render와 C의 Wait_until 80ms를
재현한다. 네이티브 빌드나 실제 latency 결과를 대신하지 않는다.

## 고정 소스와 실행 파일

| 대상 | 소스 head | 바이너리 SHA-256 |
| --- | --- | --- |
| 조사 시작 시 설치본 | eb4e550c0450f21f22ffe712aeac9a4e9a1a752d | ebcbe53ff38f8a60ce456bd20d8f05a9542f8deb7fa450400475505078fdb93b |
| A | bae45a3e0e70de9c238e2a16410ccf15d295a4be | 85c7d5bc40b0b99de9bfd9492604f0c3b4176d7cd4f53d85a34d4bd5a1924139 |
| B | 16dd4aa47803259dc516a1c2acbc244d9985c0cd | 1da7154fb6651e021dcf14bed099f8d4e08b45d981aef83804d945b61dcad658 |
| C 측정 후보 | b7d717df36de2aa91b62b413df3cad67739c499d | 9941db5ae67c7da195ae220a8f75ec4988c0a8b09ebb28ca8e7c4990e952f6df |

C의 base d4ae1ead에는 A/B 이후 다른 TUI 수정도 포함된다. 아래 표는 설치본에서
C 후보로의 업그레이드 비교이며 C 패치 하나의 효과를 분리한 실험이 아니다.
뒤의 whole-stack rebase는 C를 ff1cc7700b081c6ce7f1abebea42ef352d518ed5,
base e26416eace6d3f1bc7f47e751b6f27041e1d225e로 옮겼다.
[새 base 소스 리뷰](reviews/independent-source-review-ff1cc770.md)는 의미 변화나
미해결 P0–P2를 찾지 못했다. b7의 빌드와 실측을 ff1의 결과로 이월하지 않는다.

## 원본 100회 교대 측정

각 조건마다 before/after process-run 5쌍을 실행했다. 쌍마다 실행 순서를 바꾸고
조건 순서도 회전했다. 각 process에 32자 ASCII 입력이 있어 조건·바이너리당
160개 관측이다. 같은 process의 문자들은 서로 상관되므로 독립 표본 160개로
해석하면 안 된다. paired 방향은 5쌍을 단위로 센다.

150×45 PTY, 합성 대화 800개×8개 Markdown/Hangul 목록 줄을 사용했다.
history SHA-256은 b1d4d6fa6c3ffc1a1ee129bd2057d57f0460ee5ccc30b138e2dcaca7b584703b,
probe SHA-256은 b43594f33f14edbe18d07eb98fac62e8a99c3803f74b0a04fd215ed0e0d30efd다.
reader에서는 bytes를 읽어 timestamp와 함께 보관하고 ANSI 분석은 종료 후 했다.
PTY ECHO가 꺼져 있는지도 확인했다. 누락·미완료·오류를 버리지 않고 모두 센다.
100회 모두 완료했고, 3,200개의 입력 문자 prefix와 100개 nonce가 관측됐다.

일반 조건은 typing 간격 50ms와 scroll 간격 20ms를 요청했다. 실제 run별 평균
간격의 중앙값은 각각 54.12ms, 24.08ms였다. 빠른 조건은 25ms/5ms를 요청했고
실제 중앙값은 28.59ms/6.20ms였다. 실행 전후 호스트 1분 load는 일반 조건 66.6–259.7,
빠른 조건 48.5–303.4로 변했다. 조용한 호스트에서의 결과가 아니다.

아래 pooled p95는 `(n-1)*.95` 위치의 내림 정렬값이다. 유의성이나 전체 사용자
경험의 판정이 아니라 관측한 값의 요약이다. paired delta는 각 run의 p95 차이의
중앙값이며, pooled 차이와 다를 수 있다.

| 일반 조건 | pooled p95 before→after (ms) | 개선된 쌍/5 | paired p95 delta 중앙값 (ms) |
| --- | --- | --- | --- |
| 입력만 | 25.57→8.16 | 5 | -10.20 |
| PageUp | 110.04→96.94 | 3 | -15.71 |
| PageDown | 37.84→73.27 | 3 | -6.30 |
| WheelUp | 47.66→28.80 | 3 | -3.94 |
| WheelDown | 20.37→16.25 | 3 | -2.48 |

| 빠른 조건 | pooled p95 before→after (ms) | 개선된 쌍/5 | paired p95 delta 중앙값 (ms) |
| --- | --- | --- | --- |
| 입력만 | 5.96→13.33 | 2 | +4.59 |
| PageUp | 215.97→138.10 | 3 | -31.24 |
| PageDown* | 30.10→8.81 | 4 | -5.51 |
| WheelUp | 79.67→65.67 | 4 | -2.32 |
| WheelDown* | 54.43→11.34 | 4 | -36.87 |

**별표 두 조건은 후반에 아래 경계에 도달한다. 전 구간 실제 스크롤 중의
개선치로 인용하지 않는다.** PageDown은 선행 PageUp 100회 뒤 141–151회
내려갔고, WheelDown은 선행 PageUp 10회 뒤 145–152회×3행 내려갔다.
독립 리뷰에서 이를 발견해 앞서 보고한 해석을 정정했다. 원본은 유지한다.
일반 PageDown의 pooled p95 증가와 빠른 입력만 조건의 증가도 함께 남긴다.
모든 조건에서 좋아졌다거나 완전히 부드러워졌다는 결론은 내리지 않는다.

두 cohort의 50쌍 모두 child lifecycle CPU가 줄었다. 이는 시작·warm-up·측정·종료의
user+system CPU 합계이며 입력 처리만의 CPU나 frame별 CPU가 아니다.
전체 결과는 [일반 조건](paired-final-normal/paired-summary.json),
[빠른 조건](paired-final-burst/paired-summary.json)에 있다.

## 요청 보존과 선택 검사

한글·이모지·결합문자 `한글입력🙂결합é확인12345`를 C 네이티브 후보로 네 방향에서
입력했다. 각각 16개 Unicode scalar prefix가 관측됐고, 합성 chat/stream peer에
도착한 단 한 건의 POST message가 입력 전체와 일치했다. peer는 HTTP 503으로
거절하며 모델이나 Keeper를 실행하지 않는다. 실제 IME preedit 증거는 아니다.
종료 때 합성 peer의 keep-alive 연결에 ConnectionResetError가 찍힌 경우도
있었지만 네 요청의 완전한 본문과 관측 결과를 모두 보존했다.

| workflow / run | 실행 ref와 workflow head | 실제 검사 소스·범위 | conclusion |
| --- | --- | --- | --- |
| Minimal manual checks / 42578002082 | main / e04036c538bf1fabff497d5f0358fab012379719 | A, detail-ownership native | success |
| Minimal manual checks / 42579960781 | main / 9ce200e7448e5da6b55c688f58387a78c330e471 | B, detail-ownership native | success |
| Test / 42579964212 | perf/tui-committed-identities-20261109 / 16dd4aa47803259dc516a1c2acbc244d9985c0cd | chat_search_projection 46 + child_projection 3 | success |
| Minimal manual checks / 42581923698 | main / 2be9b9131e110e57ce865e338e5ea3f062a3f922 | C b7, detail-ownership native | success |
| Test / 42581927332 | perf/tui-overrun-input-drain-20261109 / b7d717df36de2aa91b62b413df3cad67739c499d | render_schedule 21 + chat_search_projection 46 | success |

`detail-ownership`는 macOS arm64 TUI·keydoc 빌드와 detail_reading,
board_successor, usage_scope 세 suite다. [영수증과 metadata](provenance/)가 실제
source/workflow/binary를 연결한다. 전체 회귀·Release Full CI는 실행하지 않았다.
코드 세부 내용과 해시를 읽은 [독립 리뷰들](reviews/)은 GitHub 정식 승인을 대신하지
않는다. 같은 GitHub 계정 이름만으로 Keeper 세션 독립성도 증명하지 않는다.

A/B는 별도 repository flow에서 07:42:00/07:42:02 UTC에 병합됐다. 이 세션이
Ready 전환하거나 병합한 것은 아니다. 병합 커밋은 각각 a3f324e3dc960658402b62a03e017fd13c3f1621,
cda4dd1302da3a466c83a18cd18bec85627e6d74다. 설치·실행 검증은 별도 기록한다.

## 보정한 최종 소스의 추가 50회

소스 ff1cc7700b081c6ce7f1abebea42ef352d518ed5의 새 macOS arm64 바이너리
SHA-256은 1181f65f190aa4894aa6d1067448159cdd3acd4b06bf6eaf4af1223a078e4bd6다.
**Minimal manual checks 42585592312**, 실행 ref main/workflow head
e26416eace6d3f1bc7f47e751b6f27041e1d225e는 **completed/success**였고, 영수증은
source ff1과 바이너리를 별도로 결속한다. TUI·keydoc와 세 ownership suite 범위다.
이후 c379de5e39ef11a2f26a2b0bb8cd89f187fe47d9까지 추가된 파일은 증거 문서와
changelog뿐이다. [비교 기록](followup/source-equivalence-ff1-c379.json)은 모든
non-documentation Git file entry가 native source와 동일함을 보인다. 바이너리의
build-commit은 문서 head가 아니라 ff1이다.

원본과 같은 800개 history·32자 입력·25ms/5ms 요청 간격을 유지하고, 선행
PageUp write를 PageDown에서 200회, WheelDown에서 50회로 늘렸다. 새 helper
SHA-256은 6f4332edf51fad53d73ebbcb1908f1bcb07b322a952583b413c2a5749a6b1428이다.
각 조건 5쌍, 총 50개 process-run을 모두 보존했으며 1,600개 문자 prefix와
50개 nonce가 빠짐없이 관측됐다. source·history·probe hash, 실제 send 간격,
누락과 오류를 다시 확인했다. 이전 100회와 합쳐 하나의 pooled 수치로 만들지 않는다.

| 보정한 빠른 조건 | pooled p95 before→after (ms) | 개선된 쌍/5 | paired p95 delta 중앙값 (ms) |
| --- | --- | --- | --- |
| 입력만 | 13.58→6.20 | 3 | -4.81 |
| PageUp | 61.49→47.04 | 4 | -13.47 |
| PageDown | 22.73→27.13 | 3 | -4.23 |
| WheelUp | 39.64→20.93 | 3 | -23.49 |
| WheelDown | 23.83→13.88 | 3 | -11.49 |

PageDown pooled p95 증가는 그대로 남긴다. 모든 paired 중앙값이 음수여도 전 조건
개선이나 무회귀가 증명되지는 않는다. child lifecycle CPU는 25/25쌍에서 감소했고
합계 28.3251→19.4368초(31.4% 감소)였다. 입력만의 CPU가 아니라 process 시작부터
종료까지다. 1분 load는 162.8–263.9였다. 이 수치도 조사 시작 설치본 eb4에서 최종
후보 ff1로의 업그레이드 비교이며, C만의 인과 효과를 분리하지 않았다.
[전체 집계](followup/paired-summary.json)에 각 쌍의 수치가 있다.

실제 timed scroll write 최대치는 153이었다. 151을 전제한 초기 source 리뷰는
그대로 보존하고 이를 다시 계산했다. 안정된 page 크기 P≤37과 6400개 이상 body
row에서 PgDown은 최소 min(47P,702)행, PgUp은 최소 332행의 경계 여유가 있다.
WheelDown의 page-size 조건과 history 적용 여부는 write 수만으로 확정하지 않았다.

추가로 원본 ANSI를 [pyte의 Screen/ByteStream](https://github.com/selectel/pyte/blob/master/docs/tutorial.rst)
0.8.2, wcwidth 0.9.4로 종료 후 재생했다. 네 방향 40개 run 모두 선행 위치의
Record 식별자가 있었고, 측정 중 식별자 집합이 바뀌었다. 관측된 범위는 PgUp
519–781, PgDown 453–718, WheelUp 758–782, WheelDown 712–736으로 양쪽 경계
0/799에 닿지 않았다. 마지막 scroll write 반환 후 read 시각에 실제 present 종료
표식도 모든 scroll run에서 관측됐다. read 시각은 emission의 상한이며, 늦게 보낸
모든 키가 소비됐다는 뜻은 아니다. 정확한 row offset이나 물리 화면 지연도 아니다.

초기 재생기는 종료 cleanup의 wrap-enable 표식까지 frame으로 셌다. 원본 결과와
재생기를 보존하고, 대응하는 wrap-disable/enable만 세는 v2에서 제외했다.
[v2 관측](followup/viewport-observations-v2.json)을 현재 근거로 쓰고, v1은 정정
전 기록이다. 입력 prefix 시각과 원본 latency 집계는 이 정정으로 바꾸지 않았다.

ff1 바이너리의 네 방향 Unicode 요청도 각각 16개 scalar prefix와 POST 본문이
정확히 일치했다. 합성 peer가 거절한 요청이며 실제 Keeper나 모델을 실행하지 않았다.
같은 SHA-256 바이너리를 설치 직전 설치본 9d67e41d1c4f43fa7522e41a5f4dbd0fe8f3302a와
조상 관계를 확인하고 백업한 뒤 실행 파일 하나만 atomic replace했다.
[설치 영수증](followup/installed-receipt-ff1cc770.json)에 실제 전후 hash와 백업이 있다.
기존에 실행 중이던 TUI는 재시작하거나 신호를 보내지 않았다.

설치 후 실제 127.0.0.1:8935 서버에서 새 소유 PTY로 채팅 진입과 각 20회
navigation을 관측했다. 측정 전후 서버 runtime과 base /Users/dancer/me,
설치 바이너리 hash가 같았고 keeper-message surface가 기록됐다.
[필드를 추린 관측](followup/installed-smoke-observation.json)은 원본 hash와 생략한
범위를 표시한다. private chat screen은 저장하지 않았다. 이 확인은 실제 서버의
진입·탐색 증거이며 causal typing, 물리 터미널 paint, 전체 회귀의 대체가 아니다.

## 보존과 재현

[observations-original.zip](observations-original.zip)은 원본 result.json,
timestamp별 chunk 크기와 입력 기록, 합성 PTY capture, frame timing을 보존한다.
316개 member의 원본 경로·SHA-256·크기는 [archive-members.json](archive-members.json)에
있다. history와 helper/fixture는 동일한 파일 하나씩만 중복 없이 넣었다.
압축을 풀기 전에 member 해시와 capture의 byte 합계를 확인할 수 있다.
private runtime 대화나 인증 토큰, 대용량 실행 파일은 넣지 않았다.

[recorded-paths.json](recorded-paths.json)의 기록 경로·digest를 바꾸지 않고
[current-locations.json](current-locations.json)으로 현재 보존 위치를 연결한다.
다음 명령은 이 bundle의 보존 파일만 확인한다.

```sh
python3 scripts/check-evidence-locations.py \
  docs/evidence/tui-scroll-input-20261109/current-locations.json
```

새 native 관측은 [replay](replay/artifacts/tui-scroll-input-20261109/)의 고정 helper로
시작할 수 있다. fixture import를 위한 `replay/test` 상대 구조를 유지한다.
`--output`은 비어 있는 `artifacts/<new-run>`을 지정한다. 원본 driver의 빠른
down 조건은 위 경계 문제가 있어 그대로 재현해도 active-scroll 증명이 되지 않는다.
새로운 positioning과 실제 write 수 감사 결과는 후속 기록으로 분리한다.

보정한 50회와 ff1 Unicode 4회의 raw result·PTY capture·frame timing은
[followup ZIP](followup/observations-ff1-active.zip)에 별도로 보존한다.
새 helper·재생기와 독립 감사는 [followup](followup/)에 있으며 원본과 섞거나
실패한 관측을 제거하지 않았다. [후속 위치 색인](followup/current-locations.json)도
같은 위치 검사기로 확인한다. 압축 member의 hash는 별도 archive-members.json을
따른다. absolute path는 캡처 당시 값이며, 다른 환경의 재분석은 별도 경로 연결을
만들고 원본 order/result를 덮어쓰지 않는다. 공개 bundle에는 이 호스트의 홈 경로가
포함돼 있다. 검사한 credential 패턴의 부재를 모든 민감정보의 부재로 일반화하지 않는다.

이전 reader가 ANSI 분석으로 PTY drain을 막던 trial, 선행 이동이 부족했던
PageDown trial, profiler 실행은 비교값에서 제외했다. 실패와 원본은 로컬
`artifacts/tui-scroll-input-20261109`에 남아 있고 원인별 구분은 WORKING-NOTES.md에
있다. A만의 50회에서는 전반적인 입력 지연 개선이 확인되지 않아 B/C를 이어 갔다.
