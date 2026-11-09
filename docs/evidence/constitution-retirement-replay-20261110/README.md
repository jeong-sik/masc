# 미확인 원장 기록 뒤의 규범 재활성화 재현

이 기록은 합성 입력으로 실행한 순수 원장 fold의 전후 비교다. 운영 원장,
Keeper 대화, System 원문, 메모리나 인증 정보는 포함하지 않는다.

기준 소스는 `4b75311e12ce4aeecf51c77fe96f88ec64096510`이다. 수정본은
[영수증](fold-probe-receipt.json)의 파일별 SHA-256으로 식별한다. 소스의
타입·wire 파일은 그대로 복사하고 Store의 `type line_end`부터
`read_contents` 직전까지를 그대로 추출했다. 사용하지 않는 ID 생성만
명시적 stub으로 바꿨다. decoder와 fold는 실제 소스다.

| 합성 시나리오 | 수정 전 | 수정 후 |
| --- | --- | --- |
| Added 뒤 remover가 현재 명부에 없음 | 실패 | 통과 |
| 미확인 교체와 기존 replacement id 충돌 | 실패 | 통과 |
| 미확인 author가 같은 id를 수정 | 실패 | 통과 |
| 확인된 mover와 미확인 replacement author | 실패 | 통과 |
| 보류 뒤 확인된 명시적 재채택의 순서 | 실패 | 통과 |
| 미등록 신규 규범을 채택하지 않음 | 통과 | 통과 |
| 확인된 주체의 정상 삭제 | 통과 | 통과 |

각 경우는 전체 history fold와 history를 만들지 않는 fold의 활성 목록,
decoded 이력 보존, 격리 수와 decode 거절 부재도 비교한다. 수정 전 실행은
exit 1, 수정 후 실행은 exit 0이다. 양쪽 compile은 exit 0이다.

OCaml **5.5.1**, `yojson`, `re.pcre`, `eio`를 사용했다. 저장소 target인
5.5.2의 전체 타입 검사·warning 검사와 구별한다. 실행 명령, 실제 결과,
추출 구간과 소스 hash는 영수증에 있다. 재현은 저장소 루트에서 다음처럼 한다.

```sh
python3 docs/evidence/constitution-retirement-replay-20261110/reproduce.py \
  --source . --output artifacts/constitution-retirement-replay-rerun
```

전체 Store의 파일 읽기·append·CAS, Keeper 준비와 cached/native System,
provider 요청, 설치나 배포를 실행한 증거가 아니다. 별도의 저장소 회귀
시험은 네 조회 경로, durable roster와 tool의 변경 거절, 재해석된 native
basis, 미확인 basis·override·후속 tool round의 현재 보류 안내를 다룬다.
이 순수 fold 실행 결과를 그 시험들의 실행 결과로 확장하지 않는다.

RFC-0504의 기존 정책은 미확인 삭제를 건너뛰도록 명시했다. 이번 변경은
그 정책도 수리한다. 미확인 기록을 승인하거나 과거 주체를 소급 인증하지
않으며, 영향을 받은 id를 현재 규범으로 확정하지 않고 보류한다. 원장
파일 쓰기 권한은 기존 신뢰 경계다. 현재 명부의 이름 확인이 과거의 승인이나
파일 작성자를 인증한다는 주장은 하지 않는다.
