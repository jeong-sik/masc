# 수신 확인 뒤의 도구 결과 보관

도구 결과의 전달 완료와 원본의 보관은 서로 다른 상태다. 모델이 결과를 받은 뒤에도
그 결과가 가리킨 파일을 읽을 수 있어야 한다. 결과를 대기 목록에서 지웠다는 이유로
원본 파일의 마지막 보관 근거를 없애지 않는다.

이 변경 전에는 `acknowledge`가 읽었던 receipt 파일을 삭제했다. 일반 Add-on의
오디오·그림 결과는 이 파일만 blob을 가리킬 수 있었다. 일반 도구 로그와 raw trace는
결과의 텍스트와 별도로 등록한 참조를 기록하며, 모든 Base64 미디어에서 참조를 만들지는
않는다. MCP bridge처럼 따로 참조를 등록하는 생산자와 구분해야 한다.
ACK 뒤의 blob 정리 가능성은 기존
[묶음 축소 RFC](../rfc/RFC-retained-results-carrier-shrinks-to-an-address.md#9-남는-대가)에도
기록돼 있었다. 이번 변경은 그 원본 보관 기간을 늘리는 계약이다.

## 저장 위치와 전이

두 위치는 같은 Keeper의
`<base-path>/.masc/keepers/<keeper>/official-client-runtime/` 아래에 있다.

| 위치 | 역할 |
| --- | --- |
| `undelivered-tools/` | 모델에 전달할 대기 결과 |
| `consumed-tool-results/` | 수신 확인한 원본 결과와 artifact 보관 근거 |

수신 확인은 다음 순서로 진행한다.

1. 대기 파일이 snapshot의 원본과 같은지 확인한다.
2. 같은 내용 주소와 원본 JSON을 `consumed-tool-results`에 내구 저장한다.
3. 저장 결과를 다시 읽고 원본 및 receipt codec과 대조한다.
4. 대기 파일을 다시 확인한 뒤 삭제하고 부모 디렉터리를 fsync한다.

목적지에 같은 결과가 있어도 내구 저장을 다시 수행한다. 직전 실행이 rename 뒤
fsync에서 실패했을 수 있으므로 파일이 보인다는 사실만으로 완료를 판단하지 않는다.
목적지의 내용이 다르거나 읽을 수 없으면 대기 결과를 삭제하지 않는다. snapshot이
보유한 대기 파일이 이미 없을 때에도 원본을 내구 저장한 뒤 idempotent 삭제를 확인한다.
서로 다른 수신 확인은 같은 immutable receipt를 공유할 수 있다. 결과 namespace는
기존 retention과 마찬가지로 프로세스가 소유하며, 같은 UID의 임의 파일 변경까지
원자적 CAS로 보호하는 새 프로토콜은 아니다.

새 결과는 별도의 내용 주소를 갖는다. 이전 snapshot의 수신 확인이 새 결과를
소비하지 않는다. `load`, viewer 필터와 생산자 lease 검사는 대기 디렉터리만 읽는다.
보관한 결과를 모델에 자동 재전달하거나 도구 실행으로 바꾸지 않는다. 중단 시 두
디렉터리에 같은 결과가 남을 수 있어 결과 전달이 한 번뿐이라고 보장하지는 않는다.

GC는 두 위치의 정확한 직접 파일만 같은 receipt codec으로 해석한다. 실제 artifact
참조는 원본을 보존하지만, arguments/response의 임의 JSON이 history media 소유권을
만들지는 않는다. 다른 경로나 중첩 객체, 잘못된 filename/envelope는 이 권한을 얻지 않는다.

## 비용과 남은 범위

모든 소비 결과를 보관하므로 파일 수와 원본 blob 보관량이 누적된다. ACK마다 원본을
게시하고 fsync하는 I/O가 추가되며 오프라인 GC의 읽기량도 늘어난다. 매 요청의 pending
조회 범위는 늘어나지 않는다. 이 변경은 시간이나 개수로 원본을 자동 삭제하지 않으며,
대규모 보관·스캔 비용은 아직 측정하지 않았다.

원본 결과의 참조와 `By_address` 묶음의 임시 blob은 다르다. 원본 receipt는 묶음 blob을
가리키지 않으므로 그 과거 주소의 수명은 이 변경으로 보장되지 않는다. H5 reading cache도
현재 typed history media만 소유권으로 인정한다. 원본 artifact가 남는다는 사실이 reading
cache의 보존이나 재시작 후 같은 읽기를 증명하지는 않는다.

Keeper-history 요청은 실제 host가 저장한 Audio/Document 참조에 H5 읽기를 붙인다.
Core·Codex·Claude·Antigravity·Muse가 같은 walk의 원문 읽기와 deadline을 공유한다.
읽기 결과는 receipt 내용 주소와 첨부 slot으로 구별한 JSON이며, 원본·성공 여부·ACK
조건을 바꾸지 않는다. 임의 response JSON이나 vendor 데이터에서 첨부를 추정하지 않는다.
완료 심사에는 새 읽기를 켜지 않는다.

Core·Codex·Claude의 주소 축소는 원본과 읽기를 모두 포함한 실제 묶음을 저장한다.
Antigravity·Muse에는 그 축소 재시도 기능이 없어 긴 읽기가 요청을 늘릴 수 있다.
그림, 일반 비-PDF 해석, 참조 URL 가져오기, 실제 provider의 수신·서명 prefix와 재시작
연속성은 별도 검증이 필요하다. 이 문서는 소스 계약이며 실제 서버·설치 또는 장애
복구의 실행 기록이 아니다.
