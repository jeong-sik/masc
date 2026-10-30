# Docker read-program CLI 실측 독립 리뷰

판정: **통제한 ENTRYPOINT counterfactual은 PASS이며 cleanup은 시간·daemon 범위를 제한한다.** 새 MASC 바이너리·모델 실행이나 제품 source 승인이 아니다.

같은 image ID와7B 입력에서8개 argv, stdout/stderr16개 전체 바이트 hash, CID8개를 원본과 대조했다. 실행별 name/CID 경로 외에는 `--entrypoint ""` 처리가 두 조건의 유일한 argv 차이다. 보존된 이미지 metadata는 ENTRYPOINT=`docker-entrypoint.sh`, CMD=`node`다.

| 통제 | image default exit | entrypoint reset exit |
|---|---:|---:|
| missing `rg` | 1 | 127 |
| `grep` no-match | 1 | 1 |
| `grep` match | 0 | 0 |
| `cat` read | 0 | 0 |

missing `rg`의 Node MODULE_NOT_FOUND와 실행 파일 없음은 각 원본 stderr/hash로 남아 있다. 정상 grep/cat의 출력은 두 조건에서 byte-identical이다. 실제 정상 ripgrep 실행을 검증한 것은 아니며, 이 결과를 모든 실행 파일의 신뢰성 보증으로 확대하지 않는다.

최초 cleanup은 `docker inspect` 비0만 확인했고 raw stdout/stderr·실제 code를 저장하지 않았다. 이것만으로 삭제 완료는 입증할 수 없다. 별도11:43:57.672876Z 관측은8개 exact CID의 filtered listing이 모두 exit0/empty였으므로 **그때 연결된 daemon에서의 현재 부재**를 지지한다. probe-time daemon ID가 없어 최초 daemon과의 동일성, 삭제 시점이나 최초 inspect 실패 이유는 미확인이다. 전후 daemon 안정성은 receipt의 Boolean/hash 기록이며 원문 info 출력의 독립 재계산은 아니다.

원본29파일의 위치와 full-byte hash는 별도 private manifest에 참조만 보존했다. 공개 JSON에는 경로·raw 출력·credentials·container/daemon ID를 싣지 않았다. Docker/API/provider/native/CI를 추가 호출하거나 원본·제품을 변경하지 않았다.
