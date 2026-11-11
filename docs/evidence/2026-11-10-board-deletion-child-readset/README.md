# 삭제 결정의 댓글 원본 보호

[#51116의 P2](https://github.com/jeong-sik/masc/pull/51116#pullrequestreview-5841259590)는 유효했습니다. 다른 store가 결정 전에 저장한 댓글을 캐시가 빠뜨려, 복구가 이를 나중에 생긴 댓글로 잘못 보존할 수 있었습니다. 이전 로컬 소스 검토와 stale-comments 회귀가 이 경계를 놓쳤습니다. 이전 두 증거 bundle의 원본·해시는 당시 범위로 보존하며, 이 기록이 새 수리 범위를 설명합니다.

## 바뀐 경계

`Comments_readable`의 정확한 source snapshot을 canonical codec으로 읽습니다. 같은 ID의 마지막 행에 따라 대상 집합을 추가·제거하고 정렬·중복 제거합니다. 캐시의 댓글 목록이나 model rewrite snapshot을 원본으로 대신 쓰지 않습니다. Publishing·Unsettled·Recovered·Refused·Unobserved는 계속 거절합니다.

Posts→Comments→marker 순서로 잠급니다. 두 source의 path/workspace를 확인하고 marker IO까지 잠금을 유지합니다. worker는 미리 캡처한 IO/path/snapshot으로 filesystem 효과만 수행합니다. 어느 guard든 거절하면 marker는 미실행입니다. 둘 다 실행했을 때만 실제 marker 결과로 known/unknown을 판정하고, Comments·Posts 정리 증거를 보존한 뒤 원 reserved cause를 전파합니다.

삭제 결정 전에 수락된 댓글은 대상에 포함하거나 오래된 삭제를 기록 전에 거절합니다. 결정 후 수락된 새 댓글은 원래 ID 집합에 추가하지 않습니다.

## 소스와 확인 범위

production `77b32c9e7a5660f4060862a0c9599f7cd27a5cef`, 사례를 포함한 source `93981bc1cf8fc6617d31fc8638f825ed2c25aa40`, 구현 base `b43d447c62338fca8e2ec32047bac00b99d14aaa`입니다. 이후 evidence-only commit은 이 source 입력을 바꾸지 않습니다.

- 최종 OCaml 40개 입력은 5.5.1에서 구문 검사만 exit 0입니다. 저장소 목표는 5.5.2이며 타입·경고 검증이 아닙니다. [입력별 해시·명령·결과](validation.json)를 보존했습니다.
- 전체 Dashboard tree와 이전 네 프런트 입력은 같습니다. 이전 88/88, tsc와 lint의 실행 범위를 재사용했으며 이 댓글 수리의 backend 실행 증거로 부르지 않습니다.
- 두 독립 로컬 검토는 canonical 집합, 상태, 잠금 순서, known/unknown과 실제 fault 도달 경계를 읽고 이번 delta에서 추가 P0–P2를 찾지 못했습니다. [읽은 범위](local-source-reviews.txt)는 정식 GitHub 승인이나 실행 결과가 아닙니다.

## 사례 소스

기존 pre-decision 외래 댓글 사례는 Error·marker 없음·부모/댓글/투표/리액션 보존으로 바로잡았습니다. 최신 store의 명시적 새 삭제는 그 댓글과 의존 항목도 제거해야 합니다. 호출 전에 글/댓글 경로를 막은 사례도 결정 전 거절로 바꿨습니다. 저장 순서는 결정이 기록된 뒤 실제 comments rewrite parent-sync를 실패시켜 뒤 원본이 유지되는지 확인하도록 바꿨습니다.

새 upper 4사례는 Comments guard 정리 실패 뒤 known 결정 보존, 실제 `Decision_recorded` 이후 외래 댓글·투표·리액션 보존, Comments 거절과 바깥 Posts cleanup 실패의 동시 보존, marker rename 후 parent-sync 직전에 별도 exec process가 실제 Comments stable append와 경합하는 경계입니다. 마지막 경우 `Stable_lock_contended`만 성공으로 인정합니다.

삭제 복구 16 + Fs guard 5 사례는 **모두 미실행**입니다. 새 backend red/green 실행을 주장하지 않습니다. Dune·타입/경고·backend·HTTP 통합·삭제 pending 브라우저·CI·설치·배포는 미실행입니다.

[#26378](https://github.com/jeong-sik/masc/issues/26378)은 open입니다. 다른 mutation의 부모/정책 read-set, sub-board/hearth 중단 복구, cleanup 후보 조건과 일반 Posts source-only settlement/model 불일치는 남습니다. 이 수리는 삭제 결정의 댓글 집합 경계에 한정됩니다.
