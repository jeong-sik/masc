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

## 합성 입력의 두 조건 비교

`compare`는 명시적으로 고른 모델로 prefix의 후보 설명을 만든 뒤 파일에 저장하고 다시 읽는다. 같은 질문과 Memory facts에 대해 전체 prefix+suffix를 받은 답변과 저장된 설명+suffix를 받은 답변을 각각 생성해 JEV에 보낸다. 후보 설명을 만드는 요청에는 질문, 미래 suffix, 별도 Memory facts를 넣지 않는다. 두 답변의 모델도 동일하다.

```sh
masc-librarian-continuity compare \
  --input benchmarks/data/librarian_working_state_synthetic.json \
  --output "$new_report_path" \
  --config "$runtime_toml" --runtime "$exact_runtime_id"
```

이 명령은 설정한 모델과 JEV를 실제 호출한다. 입력은 `Synthetic` provenance와 canonical Checkpoint message 형식의 `prefix`·`suffix`를 사용한다. 실행 파일의 현재 Checkpoint message 계약에 맞지 않는 입력은 거절한다. 보고서와 옆의 `.snapshot-<case-id-sha256>.json` 파일에는 원문, 후보 설명, 답변이 들어간다. 기존 출력이나 snapshot 파일은 덮어쓰지 않는다.

보고서는 두 조건의 원시 probability와 개별 실패를 보존한다. 임계값이나 합격 판정은 없으며 JEV 오류를 0점으로 바꾸지 않는다. 한 조건의 답변·판정 실패가 다른 조건 실행을 막지는 않는다. `all_cases_scored`는 모든 판정을 받았다는 뜻이고, 품질 합격을 뜻하지 않는다. 종료 코드는 모두 판정 완료이면 0, 일부 미완료이면 1, 입력·설정·보고서 저장 실패이면 2다.

`test_librarian_working_state_cli.py`는 로컬 HTTP 응답으로 이 연결을 검사한다. 그 고정 점수는 실제 JEV 측정값이 아니다. `compare` 또한 합성 경계를 사용하는 별도 실험이며 운영 Keeper의 요약 생성·front 전진·다음 요청 조립을 연결하지 않는다. 현재 구현만으로 연속성 개선이나 운영 적용을 입증했다고 주장하지 않는다.
