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

이 하네스는 저장·복원 경계를 검증한다. 실제 Librarian이 만든 설명으로 JEV 연속성을 측정하고, 공식 fragment 경계까지 검증한 뒤에 운영 요청 조립에 연결한다. 지금 운영의 carried front를 이 파일이나 Librarian read position으로 대체하지 않는다.
