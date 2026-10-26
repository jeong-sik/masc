# 아티팩트 공동 편집

관련 목표: #45940. 원고 편집·파일 가져오기는 #45957이며, 이 문서는 그다음 공동 편집 층의 계약을 다룹니다.

## 문서와 위치

게시한 HTML·Markdown 버전은 바꾸지 않습니다. 공동 편집은 별도의 공유 원고에서 합니다. 게시할 때만 공유 원고를 읽어 기존 아티팩트의 새 버전으로 저장합니다. 게시 기준 버전이 달라졌다면 기존 publication CAS가 덮어쓰기를 거절합니다.

공유 원고의 본문은 Yjs `Y.Text('content')` 하나입니다. 여러 편집자가 보낸 update는 서버에 저장되고 다른 편집자에게 전달됩니다. 서버가 원고를 처음 만들 때 게시 버전의 본문을 한 번만 넣습니다. 각 브라우저가 같은 초기 텍스트를 독립적으로 삽입하지 않습니다.

Keeper는 문서를 읽은 뒤 받은 상대 위치와 읽었던 문장을 함께 보내 수정합니다. 다른 편집자가 앞에 문장을 넣으면 상대 위치도 원래 문장을 따라갑니다. 선택한 문장 안이 달라졌다면 수정을 거절하고 새로 읽도록 응답합니다. 한글·이모지를 자르는 UTF-16 위치도 거절합니다.

## 현재 위치와 과거 기록

현재 위치는 문서·편집 세션·커서·선택 영역·읽기/편집 상태로 표시합니다. 사용자 이름과 Keeper 이름은 인증된 호출자에서 가져옵니다. CRDT update 안에 actor나 권한을 넣어 신뢰하지 않습니다.

연결이 살아 있는 편집 세션과 Keeper의 실제 실행 문맥을 현재 위치의 근거로 사용합니다. 연결 종료·문서 이탈·Keeper 실행 종료 때 해당 위치를 거둡니다. 재시작 후 과거 위치를 현재 위치로 복원하지 않습니다. 마지막으로 관측한 위치만 있을 때는 관측 시각을 붙인 과거 기록으로 표시합니다.

댓글은 문서 ID·원고 세대·상대 위치·작성 당시 인용문에 연결합니다. 댓글 작성자는 서버가 기록합니다. 텍스트가 지워져 범위가 접히면 원래 인용문을 유지하며, 비슷한 문장을 검색해 다른 위치에 붙이지 않습니다.

## 변환 프로세스

`dashboard/src/lib/artifact-shared-document.ts`가 브라우저와 변환 프로세스에서 쓰는 Yjs 로직입니다. `src/workers/artifact-document.ts`는 stdin으로 JSON 요청 하나를 받아 stdout으로 결과 하나를 반환합니다. 변환 프로세스에는 파일 경로·네트워크 주소·인증 정보·작성자 권한을 주지 않습니다. OCaml 호출자가 작업 공간·인증·문서 잠금·저장·전달을 담당합니다.

`scripts/install-artifact-document.sh`로 self-contained transformer를 설치합니다. Node와 Dashboard의 고정 의존성이 필요합니다. 생성한 bundle은 커밋하지 않습니다. 설치본은 bundle 해시별 디렉터리에 보관하고 launcher를 교체합니다. 이 설치는 서버 바이너리를 갱신하지 않습니다.

## 현재 구현 범위

공유 텍스트 병합, 상대 선택 영역, Keeper의 선택 영역 교체, JSON 변환 프로세스와 focused 검사가 구현되어 있습니다. `masc.artifact_document_engine`은 OCaml 호출자에게 snapshot·상대 선택 영역·오류를 타입으로 돌려줍니다. 변환 프로세스에는 PATH만 전달하며 공급자 인증 정보나 Node 옵션을 넘기지 않습니다. stdout 전체를 별도 파일에서 읽으므로 일반 도구 출력의 미리보기 제한으로 원고가 잘리지 않습니다. 위치는 UTF-8 바이트 수가 아닌 UTF-16 단위로 검사합니다.

독립 경계 검사는 `scripts/dune-local.sh build test/artifact_document_engine/test_artifact_document_engine.exe`로 컴파일합니다. 설치된 실제 변환 프로세스를 포함하려면 실행 파일에 `--transformer /path/to/masc-artifact-document`를 넘깁니다. 인자를 생략하면 요청·응답 경계 검사만 실행합니다.

### 공유 원고 저장과 API

`Artifact_draft_store`는 `<effective MASC root>/artifact_drafts/<artifact-id>.json`에 Yjs 상태를 저장합니다. 본문은 이 상태에서 읽으며 별도 권위로 중복 저장하지 않습니다. 게시 기준 버전·본문 digest·원고 세대·변경 순번·인증된 수정자는 manifest에 남습니다. 원고가 이미 있으면 `open`은 그 원고를 돌려주며 최신 게시물로 덮어쓰지 않습니다.

기존 owned-path·stable-lock·cursor 조건부 rewrite로 저장합니다. 다른 작성자가 먼저 저장한 것이 확인되면 새 상태에 수정을 다시 계산합니다. 선택한 문장이 달라졌으면 교체를 거절합니다. 저장 여부가 불확실한 경우에는 이 재시도를 하지 않고 원고 세대와 시도한 순번을 반환합니다. 메타데이터 손상이나 안전하지 않은 파일 경로는 새 원고 생성으로 숨기지 않습니다.

`GET /api/v1/artifact-drafts/<artifact-id>`는 저장된 공유 원고를 읽습니다. `POST /api/v1/artifact-drafts`는 닫힌 action 계약으로 `open`·`merge`·`select`·`edit`를 받습니다. 모든 경로는 `CanAdmin` 인증이 필요하며 작업 공간 precondition 헤더도 기존 요청 진입점에서 검사합니다. 클라이언트가 작성자 이름을 지정하는 필드는 없습니다.

`select`는 문서 ID·원고 세대·상대 위치가 묶인 selection을 반환합니다. `edit`는 이 selection과 읽었던 문장을 받아 그 문서에 적용합니다. Yjs의 원고 끝 위치는 다른 문서에서도 해석될 수 있으므로 원시 상대 위치만으로 문서를 선택하지 않습니다. Dashboard API 호출부도 응답의 문서·세대·selection 대상이 일치하는지 검사합니다.

실제 transformer와 영속 저장을 포함한 검사는 `scripts/dune-local.sh build test/test_artifact_drafts.exe` 후 `_build/default/test/test_artifact_drafts.exe --transformer /path/to/masc-artifact-document`로 실행합니다. 인자가 없으면 schema 검사만 실행합니다.

실시간 전달·댓글·Keeper 도구·편집 화면 연결은 후속 작업입니다. 이 층의 테스트 성공은 공동 편집 제품 완료나 운영 설치 증명이 아닙니다.

설계 근거: [Yjs document updates](https://docs.yjs.dev/api/document-updates), [relative positions](https://docs.yjs.dev/api/relative-positions). 공식 문서에서 update의 순서 독립성과 상대 위치 동작을 2026-10-25에 확인했습니다.
