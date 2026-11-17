# Farm 미디어 도구 응답 보존

외부 도구가 답을 돌려준 뒤 저장 확인을 잃거나 채널 종료 중 예외가 나도,
다시 호출하면 안 된다. 이번 변경은 받은 응답 전체를 기존 미디어 원본에
연결해 보관하고 같은 응답의 저장만 재개할 수 있는 기능을 추가한다.

## 보관하는 값

`Keeper_media_reading_reply`는 공식 MCP SDK의 serializer로 반환값을 JSON으로
만들고 canonical bytes를 보관한다. content 전체와 `isError`,
`structuredContent`, `_meta`가 대상이다. SDK 값에 명시적인 null이 있으면
필드가 없는 경우와 구분한다. 복원할 때 null을 생략으로 바꾸는 SDK 역변환을
거치지 않는다.

이미 SDK가 해석하면서 버린 wire 필드는 복원할 수 없다. 이 보장은 반환된
SDK 값의 보존이며, 원래 JSON-RPC 바이트나 오류 envelope 전체의 기록은 아니다.

응답 본문은 기존 `Tool_blob_store.put_durable`로 저장한다. MIME은 일반
`application/json`이다. 원본의 기존 `Judgment_retained`에는 원본 ID, 원본
본문 digest, 예약된 실행 ID와 정규 blob 참조만 넣는다. 미리보기는 비워 둔다.
이 기록은 응답을 보관했다는 사실이지 변환 성공이나 프로세스 종료 증거가 아니다.

응답의 임의 JSON을 owner 기록 안에 넣지 않는다. 그 안의 `_blob`이나
Stored 모양 데이터가 다른 파일의 보존 참조로 오인될 수 있기 때문이다.
기존 정리 기능은 일반 JSON blob 내부를 순회하지 않는다. 새로운 저장소,
정리 대상 등록부나 journal은 추가하지 않았다.

## 저장과 복구

기존 media owner가 현재 workspace의 물리 identity와 원본을 다시 읽는다.
알고 있던 진행 이력이 사라졌으면 거부한다. 처음 받은 응답은 정확한
`Dispatch_pending` 기록에서만 저장할 수 있다. blob을 먼저 영속화하고
원본에 참조를 연결한다. caller는 기존 workspace lease와 직렬 실행 소유권을
두 단계 동안 유지해야 한다. 이 API가 별도 프로세스 잠금을 얻지는 않는다.

원본 참조 저장이 불확실하면 `Unconfirmed`를 반환한다. 같은 원본을 다시 읽어
응답이 이미 연결됐는지 확인한다. 같은 응답은 이후 진행 이력을 보존하고
확인만 반환한다. 다른 두 번째 응답은 첫 응답을 덮어쓰지 않는다. 연결된 blob이
없거나 손상됐으면 오류이며, 재호출하거나 조용히 다시 쓰지 않는다. 참조가 없는
blob 하나만으로는 응답 저장 완료를 판단하지 않는다.

blob 저장의 `Sys_error`는 별도 오류로 반환한다. 취소는 전파한다. 호출자는
받은 응답을 가능한 동안 메모리에 유지하고 저장만 다시 시도해야 한다.
저장되지 않은 채 프로세스가 죽으면 결과는 여전히 불확실하다.

## 검증 범위와 남은 작업

일곱 테스트를 작성했다. 실제 원본·blob 저장소의 재열기, 명시적 null,
첫 응답 불변성, 저장 실패와 확인 유실, 진행 이력 회귀, 잘못된 owner·참조,
blob 누락·손상·길이 불일치, 실제 정리 스캔의 JSON 불투명성을 다룬다.

그중 두 사례는 기존 로컬 carrier와 실제 shim의 MCP 채널에서 한 번 응답을
받고 저장 실패 후 저장만 재시도한다. 이후 receipt callback의 예외 또는
callback 취소에도 응답이 남는지 확인한다. 전송 drain 실패나 SSH/VM 실행을
주입한 검사는 아니다. suite는 실제 shim을 인자로 받는 Linux 실행 대상이다.
구문 검사와 독립 소스 검토는 실행 결과와 구분하며, 이 테스트들은 아직 미실행이다.

실제 media reader producer에는 아직 연결하지 않았다. Gate의 one-shot grant,
dispatch 전 저장, 반환값 보존, 해석과 cache 정산을 이어 붙이는 작업이 남는다.
cache에 텍스트만 저장했다고 원본을 정리해서도 안 된다. 원본을 정리하려면
응답 blob을 보존하는 다른 실제 durable owner가 먼저 참조를 가져야 한다.
실제 DOCX의 SSH/Guest 변환과 재시작 후 중복 실행 방지는 별도 실행 증거가 필요하다.
