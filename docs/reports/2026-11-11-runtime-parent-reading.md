# Runtime 부모 편집 화면

기준 main은 `90ec37b2a3445b5b35452df106ef6cb0858756d4`다. 활성 편집기를 일반 Runtime 목록의 probe·default·표·진단 뒤에 붙이던 구조를 고친다. 앞부분만 남는 좁은 창에서는 이름 초안과 선택한 미디어 slot이 보이지 않았다. footer는 일반 Enter/detail을 광고했고, Media의 Page/Home/End는 뒤 목록 cursor와 안내를 바꿨다.

현재 `runtime_lane_prompt`, `slot_editor`와 picker/detail 소유자에서 매번 순수한 부모 projection을 만든다. 새 저장 상태는 없다. picker와 상세 읽기가 먼저이며, 그 외 활성 부모만 일반 목록을 대신한다. 편집기를 닫으면 기존 목록으로 돌아간다.

- Media는 기존 선언 순서와 정확한 slot identity를 사용한다. 현재 선택을 포함한 window, 실제 남은 행 수와 Page/Home/End가 같은 projection을 쓴다. 부모의 Enter는 뒤 목록의 다른 Runtime 상세를 열지 않는다. 추가·제거·재정렬·맨 앞으로 이동은 기존 동작이며, `!`는 마지막 관측에서 수락되지 않은 선언 slot이다.
- 이름 입력은 label과 원래 초안의 최신 Unicode suffix·caret를 먼저 표시한다. Rename은 원래 target도 별도로 둔다. 긴 ID와 초안·진단 전체는 새 읽기 동작인 `PgUp`으로 기존 Routes reader에서 읽는다. reader 동안 이름 text owner를 잠시 제외하고, Esc/Left로 돌아오면 원래 초안과 rename target이 다시 입력을 소유한다. 문자 `v/q/j`와 붙여넣기는 입력 중에는 계속 초안이다.
- 제거 확인은 원래 두 번째 `D`를 유지한다. 다른 입력이 arm을 해제하는 정책도 유지하며, `v`는 확인을 해제하고 전체 진단을 읽는다. Media의 `v`는 부모를 보존한 채 읽고 Esc/Left로 복귀한다.
- 본문은 현재 입력 또는 선택 slot을 먼저 예약한다. body 1행에서는 그 행을 유지하고 안내 개수·전체 읽기 경로는 제목에 남긴다. Rename의 body 2행은 초안과 원래 target에 쓴다. 여유가 있을 때 실제 진단 한 행을 표시하며, 긴 문장이나 나머지 안내는 같은 원문 reader에 남긴다. 미관측, 정상 빈 선언, 선택 없음과 보존·실패를 구분한다.

새 이름 Enter는 첫 후보 선택을 열며 이름 입력만으로 lane을 생성하지 않는다. Rename의 pending 거절, 참조 rewrite, 미디어 whole-order의 fresh-read 검사, 마지막 slot/제거 거절, HTTP/CAS·재조회·영수증·workspace 철회는 바꾸지 않는다. Lanes Exact slot 편집기와 worker도 변경하지 않는다. 부모의 projection은 표시·선택 이동이며 쓰기 권한의 근거가 아니다.

기존 네이티브에서 관측한 부모 유실과 뒤 목록 이동이 수리의 근거다. 수정본은 OCaml 5.5.1 구문과 diffcheck만 확인했다. 타입·빌드·동작 시험·수정본 native·설치 GUI는 미검증이며, 화면 문구·배치 단언 검사는 추가하지 않았다. canonical Keys의 PgUp/m 설명이 바뀌므로 `TUI-KEYS.md`는 실제 generator 전체 산출물로 별도 동기화해야 한다. 수작업으로 편집하지 않았다.

후보가 없는 필터의 Enter 안내(P3)는 별도 후속으로 남긴다. 전체 6가족·23화면과 모든 child/form/overlay, 정상·실패·보존·불확실, wide/narrow 및 installed GUI 감사는 계속 열린 범위다.
