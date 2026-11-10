# Goal·Task·Board·Memory 읽기 화면 관측

37개의 선택한 TTY 프레임과 대응 ANSI, native Memory GET 5개를 보존한 관측 기록입니다. 모두 합성 입력을 넣은 별도 private workspace에서 관측했습니다. 원본 파일은 유지했고 복사본은 기존 sanitized bytes와 같습니다. UI 문구·배치·행순서 assertion을 새로 만들지 않았습니다.

| 관측 | 실제 바이너리 source | 선택 프레임 |
| --- | --- | --- |
| 설치본 KO 120×35 | `e2c38ca5ad1d850f2890b4e17d0ace08f7eea6b0` | [8개 목록·상세](baseline-e2c-ko-120x35/) |
| A0 KO 120×35 | `a0b0461a7730335c7dbd59a3113ee5e156dcda3e` | [8개 목록·상세 + Memory health](candidate-a0-ko-120x35/) |
| A0 EN 120×35 | 같은 A0 | [8개 목록·상세 + 열린 글·댓글](candidate-a0-en-120x35/) |
| A0 KO 80×24 | 같은 A0 | [4개 상세 + Goal·Task 목록](candidate-a0-ko-80x24/) |
| A0 EN 80×24 | 같은 A0 | [4개 상세 + Memory health](candidate-a0-en-80x24/) |

최종 검토 source는 `db182da9c2529fcda92bbf6cfe8129ad7f80dcec`입니다. A0 native 이후 Goal 테스트 정리, 한국어·canonical category 검색과 helper 이동, 실제 Memory pass 결과를 보존하는 label 수정이 들어갔습니다. 차이는 `masc_tui_render_memory.ml`, `masc_tui_types.ml`과 테스트 2개입니다. 이 최종 source를 실행한 화면이라고 주장하지 않습니다. 특히 보존한 A0 Memory health의 `Librarian 실패/failed`와 `pass stopped` 표시는 원래 관측 그대로이며, 마지막 label 수정의 실행 증거가 아닙니다.

실제로 읽은 범위는 [panel-review.json](panel-review.json)에 프레임별 시각·파일·관측으로 적었습니다. Goal은 긴 성공 조건을 목록 preview와 상세에서 읽습니다. Task 상세 비교는 양쪽 모두 `task-surface-active`입니다. 설치본은 ID·연결 목표·시각 등의 정보 뒤에 요청이 나오고, A0는 요청·상태·담당을 먼저 보여줍니다. Board는 본문, 종료 결론·후속 글과 실제 댓글을 보존합니다. Memory는 일반/출처 사실, 나이, 저장 시각, 실제 처리 상태를 구분하며 원래 한·영 본문은 UI 언어와 별개로 남습니다.

서로 다른 private fixture의 생성 시각과 목록 순서·선택은 다릅니다. 시각·age·행순서를 성능 비교로 해석하지 않습니다. Task 이력은 실제 `HTTP 503: task_history_unavailable`, Librarian은 실제 Addon-unattached 경고와 중단 결과가 보입니다. 원장 없음, 미기록 검증과 일정 경고도 지우지 않았습니다. 정적 프레임은 모든 scroll 행·상태 전이·Goal 최종 확인 동작을 검증하지 않습니다.

다섯 controller의 완료 manifest는 모두 실패 없음이며 live/private 설정 byte 감시가 유지됐습니다. 기록된 navigation에 R refresh는 없고 transport fault도 켜지 않았습니다. GET-only proxy는 mutation을 전달하지 않았습니다. 설치본·KO·EN 세 native 서버는 각각 소유권을 확인한 정리에서 exit 0과 process absence를 기록했습니다. 이는 controller/native 정리의 범위이며 TUI 자체의 자연 종료 코드나 production 배포 증거는 아닙니다.

Native artifact는 `Minimal manual checks / Native TUI artifact` run `42633341390`, attempt 1, workflow head `beb1d2d4b538e87ea2ddeed1b74dc54e7043fde9`, source A0입니다. 추출 checksum과 두 바이너리의 실제 embedded source를 별도로 확인한 영수증을 compact provenance에 연결합니다. 내려받은 artifact `13683830880` ZIP은 186,782,903 bytes이며 SHA-256 `7a2778da854f876ca0b03aba642fb5042d5288a9273b56ce3f0b11db92ec0cb9`를 확인했습니다. ZIP 해시와 추출된 payload checksum은 서로 다른 확인입니다. 최종 head의 [focused Memory/category 검사](https://github.com/jeong-sik/masc/actions/runs/42639867713)는 root가 실제 `db182da9…` head와 job `129237797433` 로그의 9 cases 성공을 확인했습니다. 앞선 A0 7 suites/79 cases와 테스트 정리 후 Goal 8 cases의 source·run도 provenance에 구분합니다. A0 run의 기존 Goal UI assertion 실패를 전체 성공으로 바꾸지 않았습니다. 이 번들은 Full CI, 공식 승인·병합, 최종 head native 실행, 설치본 교체나 production 재시작을 증명하지 않습니다.

[captured-digests.json](captured-digests.json)은 원본 sanitized 파일의 경로·hash이고 [current-locations.json](current-locations.json)은 현재 복사본을 연결합니다. [provenance.json](provenance.json)은 원본 manifest/identity/정리 영수증의 hash와 필요한 필드만 추린 파생 기록입니다. 큰 nested request manifest, 토큰·raw login·config·개인 대화는 복사하지 않았습니다. 실제 host home 경로·인증 문자열·키 패턴·이메일 검사에서 선택 파일의 일치를 찾지 못했습니다. 캡처의 `<user>` 등 익명 placeholder는 유지했으며 그 행을 재배치하지 않았습니다.

`docs/evidence/four-surface-reading-20261109/`에 보존하며 원본 hash 의미는 유지하고 current-locations는 현재 복사본 경로를 연결합니다. 원본 실패한 baseline 1차 EOFError와 선택하지 않은 startup/reentry/중복 프레임은 작업 artifact에 그대로 있습니다.
