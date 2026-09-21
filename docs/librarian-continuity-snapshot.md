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


## 이미 실행 중이던 Keeper의 첫 저장본

운영 초기화는 `Captured_checkpoint_prefix` 출처로 잠긴 checkpoint의 실제 원문을 읽는다. 재시작 기록을 만들지 않는다. 실제 완료된 turn boundary가 전체 읽기 가능 범위를 보증하고, 저장본의 `end_atom`은 그 안에서 정리한 마지막 atom의 다음 위치다. `covering_end_atom`과 완료 경계의 digest는 그 범위를 보증하는 원래 경계를 남긴다. 도구 호출과 결과는 한 atom으로 유지한다.

기존 Librarian lane에서 하던 일과 새 원문을 처리한다. 처리 단위는 저장 지점 다음의 실제 완료된 턴까지이며, 남은 턴을 용량에 맞춰 한꺼번에 채워 넣지 않는다. Codex가 구조화된 입력 초과 응답으로 글자 수 한도를 알려주면, 같은 처리 회차에서는 그 한도를 다음 조각에도 재사용한다. 매 조각마다 이전 요약, 현재 Memory, queued context, 출력 형식 지시문을 포함한 실제 제출 프롬프트를 다시 구성하고 Unicode scalar 수를 센다. 선택한 작업 단위가 한도 안이면 그대로 보낸다. 초과할 때만 atom 경계에서 둘로 나누며, 들어가는 첫 조각에서 멈추고 한도까지 다시 늘리지 않는다. 이전 조각의 atom 개수를 용량으로 추측하지 않으며, 해당 runtime이 lane에서 빠지면 그 한도는 적용하지 않는다. 관측한 한도는 이 처리 회차에만 존재하고 영속 설정이나 Memory에 저장하지 않는다.

한도를 알 수 없는 typed 용량 거절에는 원문 범위를 atom 중간 지점으로 줄이는 복구 경로를 쓴다. 429, 인증, 출력 형식, 저장 실패는 범위를 줄이는 근거가 아니다. 한 atom이나 이미 Memory에 저장한 복구 범위는 더 줄이지 않는다. 관측한 Codex 한도에 맞지 않더라도 다른 provider의 실행 기회를 막지는 않으며, 정상 lane 순회를 거친 최종 실패를 남긴다. 고정 prompt 자체가 큰 경우도 이 경계에서 멈춘다. 최초 한도 관측을 위한 거절과 큰 입력의 로컬 직렬화 비용까지 없애는 것은 아니다. 재시작이나 처리 회차 종료 뒤에는 한도를 다시 관측한다.

이미 일반 Memory consumer가 읽었다는 근거가 있는 범위는 하던 일만 저장한다. 그 밖의 실제 새 source는 Memory와 하던 일을 같은 회차에서 생성한다. Memory WAL의 receipt scope를 continuity 파일 경로로 분리하므로 부분 처리가 일반 consumer의 위치를 전진시키지 않는다. Memory 저장 뒤 하던 일 저장이 실패하면, 다음 wake는 그 정확한 범위를 먼저 복구하며 Memory에 다시 적용하지 않는다. 완료된 checkpoint prefix는 기존 durable consumer와 동일하게 이후 변경되지 않는다는 전제를 쓴다.

입력에서 원문을 제외할 수 있는 위치는 하던 일 저장본의 원자적 쓰기가 성공한 뒤에만 움직인다. 원본 checkpoint는 계속 남는다. snapshot codec에는 출처와 covering boundary가 필수이며, 이전 artifact를 위한 변환 reader는 제공하지 않는다. 새 배포에서 생성한 저장본으로 검증한다.


## 선택 가능한 작은 입력

Keeper 설정 `input_policy`는 `small`(기본)과 `wide` 중 하나다. `keeper_up`과 설정 API,
대시보드 및 TUI에서 변경한다. `small`은 검증된 완료 턴의 도구 결과 본문을 기존 원문
보관소에 저장하고 조회 참조로 보낸다. 실제로 제공된 원문 조회 도구가 있어야 적용한다.
저장에 실패하면 해당 본문을 유지한다. 완료 경계 뒤의 진행 중인 작업, 일반 대화와
아직 정리되지 않은 의무는 생략하지 않는다. `wide`는 남은 도구 결과 본문도 함께 보낸다.
두 방식 모두 저장된 요약의 보존 범위를 검증하며 원본 checkpoint를 바꾸지 않는다.

`max_context_override`는 기존 토큰 Cap이다. 낮게 설정하는 것과 작은 입력을 구성하는
것은 별개이며, 남은 용량을 채우기 위해 이력을 늘리지 않는다. 비도구 원문이나 진행 중인
작업 자체가 크면 작은 방식에서도 요청이 클 수 있다. 공식 클라이언트에는 이 Agent Core
본문 투영을 적용하지 않으며, 로그의 `context_owner`와 적용 여부로 구분한다.
