# task-1535 evidence — cohttp-eio 핀 제거 조건 판정: 불충족 (유지)

- task: task-1535. 브랜치 polish/task-1535-cohttp-eio-floor @ 51aa016 (main tip)
- 결론: **저장소 변경 0건 — 핀은 오늘도 유효**. 등기한 "6.2.1→6.3.0 상향"은
  전제가 반증됨. 이 evidence는 판정 기록이며 코드 변경 task가 아님.

## 판정 근거 (gh 원문 실측, 2026-09-11 20:5xZ)

- 핀 원문(scripts/opam-pin-external-deps.sh:124–129): "cohttp-eio 6.2.1 +
  one line: Reader_flow.single_read continues a partial body delivery from
  the position already delivered… **Remove the pin when a cohttp-eio release
  carries the fix (upstream PR from this fork)**" — SHA 45ecbe94
  (jeong-sik/ocaml-cohttp).
- upstream 흡수 확인: mirage/ocaml-cohttp **PR #1149** "cohttp-eio: continue
  a partial body delivery from the position already delivered" —
  **merged 2026-09-08T14:57:57Z** (제목이 핀 코멘트와 단어 단위 일치).
- 릴리스 원문: v6.2.2 tag commit **2026-07-26**, v6.3.0 tag commit
  **2026-08-20** — **둘 다 #1149(09-08) 이전** → 어느 릴리스에도 수리 미포함.
  v6.2.1..v6.2.2 / v6.2.1..v6.3.0 compare에서 partial-body 커밋 0건(재확인).
- 잠금 원문: masc.opam.locked:44 `"cohttp-eio" {= "6.2.1"}` — 핀이 6.2.1로
  유지하는 구조와 정합. dune-project:87 / masc.opam:33 하한 >= 6.0 (변경 불요).

## 부수 실측 — 로컬 스위치 드리프트 확인 (01-pin-check.log)

- `bash scripts/opam-pin-external-deps.sh --check` → **exit=1**:
  - "OCaml 5.5.0 detected; MASC requires exactly 5.5.1" (로컬 스위치 위반)
  - "cohttp-eio: not pinned; expected …#45ecbe94" — 로컬은 스톡 6.2.1.
- 귀속 정밀화: 어제 내가 관측한 cohttp_eio_body_flow 1/3 red는 **핀 미적용
  로컬 스위치의 드리프트** 소견. 17:43Z main Test 실패(run 34629337955)의
  11 suite에 cohttp_eio_body_flow가 없는 것과 정합 — **CI는 핀 적용 스위치**라
  이 테스트는 통과. 즉 이 red는 main 상속 red가 아니라 내 환경 소견.
  (task-1533/NOTES의 "업스트림 버그" 판정은 유지 — 재현 자체는 정확했음)

## 후속 좌표

- 핀 제거는 **#1149를 포함하는 최초 릴리스(6.3.1+ 예상)에서** — 본 task의
  재판정 트리거로 남김.
- 로컬 스위치 정합(5.5.1 + 핀 --install)은 운영자/공유 인프라 축 권고 사항.
