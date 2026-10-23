# Independent source review

The reviewer found and the author repaired three WIP P2 findings: missing lane publication, unequal common context, and unread source reinclusion. The initial report is retained in the working evidence directory; the final source verdict follows.

Historical full review SHA256: `5bb33c6fd3f721f7f564b9b5d539da61ec56256fbfbc5358530688840fb17d40`.

## Closing addendum — exact head 9ed280ba2a16b5f82e58b3201eaddb9b77560a6a

**이 head의 최종 소스 검토에서 앞서 보고한 P2는 모두 해소됐고 추가 P0/P1/P2를 찾지 못했다.** 이 절은 위 초기 WIP의 “P2 한 건이 남음”을 최신 상태에서 대체한다. 초기 발견과 근거는 이력으로 보존한다. Draft PR #45651/Stack #45642 position3이라는 root의 게시 보고와 별개로, 이번 결속 대상은 실제 로컬 Git commit과 blob이다. GitHub APPROVE를 게시하거나 독립 remote footer를 만들지 않았다.

### unread 수리 재검토

`lib/librarian_production_evaluation.ml:110-145`를 direct-read했다. 순서는 실제 boundary/range 결정 → U.validate_atom_history → U.sources_for_atom_range → 같은 Window.annotate 원문 순회다. sources_for_atom_range는 shared atom/message 좌표와 actual message digest를 만든다. 검증된 private hole.source와 그 identity가 같을 때만 제외하므로 같은 텍스트를 가진 다른 source를 우연히 지우지 않는다. pinned는 atom/hole이 아니며 actual Queue의 source 선택처럼 추론에서는 제외한다.

kept-count offsets는 원래 source.messages의 모든 위치에 대해 만든다. historical first/after_message는 이 배열로 remap하고 원래 scope/trace/atom/attribution을 보존한다. negative/reversed/out-of-range message 및 tool-observation spans는 Error로 거절하고 clamp하지 않는다. 관련 없는 tool/counterpart/common context를 재번호 매기거나 지우지 않는다.

parse_case도 selection 검증을 하고, public evaluate_case도 `:178`에서 selection을 다시 통과한 뒤 Work_started와 selected_source를 저장하므로 직접 typed case 호출도 검증 전 provider 효과를 내지 않는다. 실제 infer는 selected source를 받는다. full source는 그대로 case/report에 남고, `:187-193`의 S.capture/restore와 양 arm의 동일 judge reference는 original prefix/coordinates/digest를 계속 사용한다. `progress.selected_source`는 실제 추론 입력을 별도로 보여준다. 임의 cap이나 strings-as-policy, empty-only 지원 제한은 도입되지 않았다.

### 새 회귀와 codec

`test_unread_hole_and_independent_judges`(`test/test_librarian_production_evaluation.ml:108-158`)는 actual unread codec으로 한 메시지 전체를 hole로 만들고 실제 Runtime→loopback HTTP peer 경로에 빈 source를 보낸다. actual production preparation에서 hole 본문 부재, remapped historical offsets, 실제 snapshot의 hole 보존을 확인하도록 작성되어 있다. baseline judge 실패와 restored judge 성공을 따로 보존한다. 고정 설명/answer/judge 응답을 쓰므로 의미 품질 측정은 아니다. **이번 리뷰에서 native fixture를 실행하지 않았다.**

complete source/message codec ML/MLI도 읽었다. strict complete fields, ordered metadata, JSON-valued option의 []/[value] 구분, actual fact/Goal/Task/Turn codecs 재사용이 유지된다. evaluator는 이 codec으로 source와 suffix를 읽고, unread는 자체 strict codec 및 history hash로 검증한다. metadata JSON payload를 provider projection으로 줄여 저장하지 않는다. 이 data decode가 physical owner/source freshness/effect authority를 부여하지 않는다는 MLI 한계도 정확하다.

### 문서와 샘플

`docs/librarian-production-evaluation.md` 전체 및 `docs/librarian-continuity-snapshot.md`의 새 연결 문구를 읽었다. 다음 사실과 소스가 일치한다.

- --runtime은 두 answer arm의 Agent Core provider이며 production inference 후보는 실제 configured Librarian exact lane이다.
- actual immutable config observation으로 기존 publisher 정책을 사용한다. 새 기본 lane을 합성하지 않고 설정 파일을 전후 재읽어 source revision을 꾸미지 않는다.
- fresh evaluation workspace와 run registry, explicit prompt directory를 쓰며 live Keeper history/override를 발견하는 경로를 추가하지 않는다.
- prior state는 opaque input이며 earlier source coverage라고 주장하지 않는다. actual filtered source와 full capture, snapshot/unread, raw JEV outcomes를 구분한다.
- preparation은 base prompt/requirement의 증거이며 wire/dispatch 증거가 아니다. all_cases_scored는 판단 완료이지 품질 합격이 아니다. 공식 fragment·설치·visible I4·전역 marks 전환의 잔여 요구를 완료로 축소하지 않는다.

두 합성 sample의 source prefix, future suffix, question을 읽었다. pending approval과 corrected destination을 구분하며 provenance는 Synthetic이다. canonical JSON을 읽었지만 실제 ML decoder 실행 또는 production model measurement를 수행했다고 주장하지 않는다.

### 결속과 검증 한계

`production-evaluation-source-review-addendum-source.json`은 final own delta의14개 변경 파일을 exact Git blob·SHA256로 기록하고, 읽은 working tree bytes와 commit blobs의 일치를 확인한다. 전체 delta SHA256도 보존한다. 이 리뷰는 소스 검토이며 bounded probe/typecheck/native test/실제 모델/JEV/배포/UI 실행의 receipt가 아니다. 외부 GitHub 승인이나 이슈 전체 완료를 대신하지 않는다. 이후 head가 바뀌면 그 actual delta를 다시 검토해야 한다.


---

## Additional delta — observation wire regression and changelog

기준 product commit `9ed280ba2a16b5f82e58b3201eaddb9b77560a6a` 뒤의 uncommitted `test/test_exact_output_binding_wire.ml` diff와 새 `changelog.d/45651.md`를 직독했다. 앞서 검토한14개 source files는 그 commit의 actual Git blobs와 byte 동일함을 다시 확인했다. **이 두 파일 델타에서 추가 P0/P1/P2는 찾지 못했다.** 결과는 working-content hash에 결속하며 이후 commit head를 미리 승인한 것은 아니다.

새 helper의 `Boot_config | Explicit_file | Captured_observation`은 기존 bool의 두 경로를 명시적으로 보존한다. 기존 boot 세 사례와 explicit-file 한 사례는 각각 원래 Runtime.init_default 및 publication 경계를 사용한다. 새 observation 사례는 실제 Runtime.load_config_observation→init_default_degraded_observation 뒤 source path를 invalid TOML로 바꾼다. publisher에는 그 captured observation을 주고, 실제 registry의 유일한 admitted Librarian target을 읽어 loaded Keeper provider와 provider kind/endpoint/request_path를 기존 check_wire로 대조한다. 단순 parse fixture나 source 문자열 검사로 publication을 대신하지 않는다. 구현이 파일을 다시 읽거나 ambient의 잘못된 slot을 쓰면 해당 경계에서 실패하는 구성이다.

시험의 projection은 native OCaml Runtime/registry/wire 경계를 대상으로 하고, 새 모델 HTTP 요청을 발행하는 시험은 아니다. 이 리뷰에서 해당 native 시험을 실행하지 않았다. root가 보고한 syntax PASS를 독립 실행 결과로 이월하지 않는다. child가 수행한 검사는 `git diff --check` exit0뿐이다. 기존4개 사례가 새 helper를 사용한다고 해서 새 regression이나 전체 suite 실행을 완료한 것으로 세지 않는다.

changelog의 production compare capability, actual prompt preparation/accepted slot, verified unread 제외, shared Memory/raw JEV 및 immutable config observation 초기화 설명은 현재 구현과 일치한다. 실제 모델 측정·성능·설치·visible UI 완료를 주장하지 않는다.

`production-evaluation-observation-regression-source.json`은 두 실제 파일의 SHA256, regression diff SHA256,14개 product blob의 불변 확인을 기록한다. GitHub 승인·모델 실행·Dune·CI는 수행하지 않았다.
