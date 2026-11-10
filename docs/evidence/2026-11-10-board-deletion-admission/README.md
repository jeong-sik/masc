# Board 삭제 권한과 결정 기록

원 요청자의 author/reader 권한을 현재 모델과 관측 원본의 최신 부모 글 양쪽에 검사합니다. 원본의 정확한 bytes/cursor를 잠근 상태에서 삭제 결정을 기록합니다. callback은 파일 IO만 수행하고 모델·Source 상태는 호출 fiber가 반영합니다. 결정 쓰기의 known/unknown 결과와 이후 guard 정리 실패는 따로 보존합니다.

이전 로컬 후보 `92c92a177c5cb173106f8e11f9d36a612ae125d7`에는 stale 작성자가 새 소유자의 글을 지우는 결정을 기록할 수 있는 P2가 있었습니다. 이전의 추가 P2 없음 판단을 이 상호작용까지 확장하지 않습니다. [공개 정정](https://github.com/jeong-sik/masc/issues/26378#issuecomment-6765015197)과 이 기록은 이전 캡처를 교체하지 않습니다.

이번 소스 기준은 production `3756627794545fb3eb0002ef458fc6b9e1a50bc8`, 사례를 포함한 upper `8ed23cbd9844d809c79655888f9dc0d49cf9beb7`, 구현 base `b43d447c62338fca8e2ec32047bac00b99d14aaa`입니다. 이후 문서·fragment commit은 이 기록의 소스 입력을 바꾸지 않습니다. Native Stack의 현재 main base와 구현 당시 base는 구분합니다.

## 확인한 범위

- main 위로 옮길 때 충돌은 없었습니다. 후보의 53개 경로 중 52개의 blob이 같고, `test/dune`만 main의 별도 stanza 변경을 보존했습니다. 이후 거절 문구와 저장 계약을 바로잡았습니다.
- 최종 소스의 OCaml 40개 입력을 5.5.1에서 구문 검사했습니다. 모두 exit 0이고 저장소 목표는 5.5.2입니다. 타입·경고 검증이나 백엔드 실행은 아닙니다. [파일별 해시와 명령](validation.json)에 범위를 고정했습니다.
- 이전 [프런트 기록](../2026-11-10-board-deletion-recovery/README.md)의 88/88, Dashboard 타입 검사와 네 파일 lint는 과거 실제 실행입니다. 네 입력 해시와 전체 Dashboard tree가 이번 소스와 같음을 확인했으며 실행을 반복하지 않았습니다. 이 결과는 새 백엔드 권한 검사의 실행 증거가 아닙니다.
- 두 독립 로컬 검토가 actor 전달·canonical parent·worker 경계·known/unknown·원인 보존과 사례 API를 읽었습니다. [읽은 범위와 남은 문제](local-source-reviews.txt)를 기록했으며 현재 head의 정식 GitHub 승인으로 간주하지 않습니다.

## 작성했지만 실행하지 않은 사례

삭제 복구 파일 12개 사례와 Fs guard 5개 사례는 모두 미실행입니다. 이번에 추가한 9개는 foreign 작성자 변경, 같은 store의 원 actor 재검사, 파일만 settle된 뒤 옛 모델 소유자 거절, marker가 확인된 뒤 parent guard 정리 실패, stale cursor/동일 cursor 바이트 변경, 별도 process의 실제 lock 경합, known/unknown child와 원 cleanup cause/backtrace 보존입니다. 기존 fixture의 실패 지점도 결정 이전 거절과 이후 저장 재시도로 나눴습니다.

Dune·OCaml 타입/경고·백엔드·HTTP 통합·삭제 pending 브라우저·CI·설치·배포는 미실행입니다. 투표·반응의 이전 브라우저 캡처를 삭제 경로 검증으로 사용하지 않습니다.

## 남은 범위

[루트 #26378](https://github.com/jeong-sik/masc/issues/26378)은 open입니다. 정책·부모 read-set, sub-board/hearth 중단 복구, cleanup 후보 선정 뒤 조건 변경이 남습니다. 공개 Posts settlement는 원본만 증명하고 모델은 갱신하지 않으므로, 다른 행의 후속 전체 snapshot이 미반영 변경을 덮을 위험도 별도로 남습니다. runtime 자동 settle consumer는 확인되지 않았으며 이번 actor 수정으로 이 일반 경계를 해결했다고 주장하지 않습니다.

[manifest](manifest.json)는 이번에 선택한 검증·리뷰 기록의 바이트 해시입니다. 이전 증거의 캡처 시점 해시는 그대로 유지합니다.
