# 하던 일 저장본의 저장·복원 검증

`masc-librarian-continuity`의 `capture`와 `restore`는 RFC-librarian-lifecycle §7(라)의 파일 경계를 검증한다. 실제 Memory나 Librarian 진행 파일을 바꾸지 않는다. 모델을 호출하지 않으며, 사람이 제공한 후보 설명의 정확성을 판정하지도 않는다.

먼저 합성 입력과 별도 artifact 디렉터리를 준비한다. `--keepers-dir`는 턴 끝 기록이 있는 runtime Keeper 디렉터리이고, `--session-dir`는 지정한 trace의 checkpoint 디렉터리다. 후보 설명 파일에는 완료된 prefix에서 이어서 할 일을 적는다.

```sh
masc-librarian-continuity capture \
  --session-dir "$session_dir" --trace "$trace_id" \
  --keepers-dir "$keepers_dir" --keeper "$keeper_name" \
  --working-state "$candidate_state_file" --output "$capture_file"

masc-librarian-continuity restore \
  --session-dir "$session_dir" --trace "$trace_id" \
  --keepers-dir "$keepers_dir" --keeper "$keeper_name" \
  --snapshot "$capture_file" --output "$restored_file"
```

출력 경로는 존재하지 않는 파일을 지정한다. stdout에는 출력 경로와 SHA256, `semantic_continuity_evaluated: false`만 나오며 원문과 하던 일은 지정한 파일에 저장된다. 그 파일에는 Context 원문이 들어가므로 검증용 합성 데이터부터 사용한다.

저장본의 끝은 exclusive atom 위치다. 같은 저장본에서 설명과 위치를 함께 읽고, 해당 위치 뒤의 메시지를 붙인다. checkpoint 뒤에 턴이 추가돼도 사용할 수 있지만, 다른 trace·새 history 시작·끝 경계의 줄이나 Turn_ref 교체·기존 prefix 변경에는 사용할 수 없다. prefix digest는 도구 결과 본문까지 포함한다. 끝 atom의 첫 메시지가 같다는 이유로 바뀐 도구 결과를 지나치지 않는다. baseline만 설정된 이력은 처음부터 보존됐다고 가정하지 않는다.

이 하네스는 저장·복원 경계를 검증한다. 설명이 뜻을 보존했는지는 별도 평가가 필요하며, 파일 검증 성공이 의미 보존 성공을 뜻하지 않는다.

## Agent Core의 다음 턴 입력

운영 Librarian은 runtime Keeper 디렉터리의 `librarian-continuity.json`에 하던 일과 정확한 완료 위치를 함께 쓴다. Agent Core dispatch는 이 파일을 한 번 읽고, 같은 trace·history·완료 경계·원문 prefix인지 확인한다. 다음 요청은 저장된 하던 일과 그 위치 뒤의 원문, 현재 pinned context를 함께 보낸다. checkpoint 원문과 Librarian의 Memory 진행 위치는 바꾸지 않는다.

한 dispatch에서 저장본은 고정된다. tool loop의 각 요청에서도 덮은 prefix가 같은지 검사한다. 새 도구 결과와 사용자 입력은 뒤에 그대로 붙으며, 뒤쪽 원문에는 demotion이나 기존 ledger의 더 앞선 cut을 적용하지 않는다. 용량 초과가 나면 이 경로는 원문을 추가로 잘라 같은 provider에 재시도하지 않고 기존 runtime 실패 처리에 넘긴다.

다른 trace나 새 history에는 옛 저장본을 쓰지 않는다. 현재 history 전체를 전송하고, Librarian이 새 완료 구간을 저장한 다음 dispatch에서 줄인다. 파일 손상·읽기 실패·같은 prefix의 내용 변경은 명시적 오류가 된다. 저장본 자체가 없는 Keeper는 기존 입력 경로를 유지한다.

이 연결은 Agent Core 경로에 한정된다. 공식 client의 session과 fragment는 아직 연결하지 않는다. `recovery_view`가 있는 실행은 해당 복원 경로를 우선하며 두 변환을 겹치지 않는다. 로그의 `origin=librarian_snapshot`, `first_atom`, `atoms`, `transmitted_bytes`로 실제 입력 범위를 확인할 수 있다. TUI 전용 표시와 실서비스 연속 턴 검증은 별도 작업이다.
