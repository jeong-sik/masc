# Candle container qualification — independent evidence review

verdict: PASS source: d35d2559c56814b38615545a5f4f081304bccc05 by: bidi_partial_failure_response

**판정 범위는 실제 Docker worker의 정상 프로세스 종료·container 교체와 persistent volume/원래 요청/terminal 결과 보존이다. E01 전체 완료, host installation Off/On, 실제 provider 또는 원장 정산의 PASS가 아니다.** 이 근거에서 현재 제품 버그를 확정하지 않았다.

## 직접 읽은 원본과 수행 경계

- session: `/tmp/masc-addon-goal-resume-20261021/candle-container-session-20261022.json`
- driver: `/tmp/masc-addon-goal-resume-20261021/candle_container_qualification.py` (실행하지 않고 전체 읽음)
- 원본 root: `/var/folders/bv/cjrbl01x52s6j80krdfb63400000gp/T/masc-candle-container-qualification-20261022-gwrm03w4`
- root의 receipt/image-build/image-inspect/docker-commands, 세 requests/replies/container-inspect, volume-created/after-first-removal/before-final-cleanup, 두 retained-state JSON, cleanup-observed를 읽었다.
- source snapshot 7개 파일을 고정 git object와 byte 비교하고 session의 SHA256/blob ID와 비교했다. 일곱 항목 모두 일치했다. driver나 Docker/CI/worker를 새로 실행하지 않았고 cleanup이나 제품 소스도 변경하지 않았다. 확인용으로 JSON과 hash를 계산한 것만 새 감사 작업이다.
- 감사는 보존된 원본에 대한 사후 독립 검토다. 외부 서명·tamper-proof execution attestation이나 감사를 수행한 시각의 Docker 상태 조회가 아니다.

## source → image → 실제 세 container 결속

검사한 source 항목은 `addons/protocol.py`, Candle Dockerfile, lane.toml, server.py, grade/relation/weights schema다. 실제 snapshot은 모두 d35 source와 같고, manifest는 기존 persistent container package다.

`image-build.log`와 session의 build argv는 이 root의 기존 Dockerfile과 addons context를 사용해 별도 tag `masc-candle-proof:d35d2559-0c67b092c532`를 만들었다고 기록한다. 기존 base는 Python3.12-slim digest `a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1`다. COPY protocol.py와 WORKDIR 단계는 BuildKit cache 사용을 그대로 기록한다. build exit0이며 결과 OCI index/image identity는 다음과 같다.

`sha256:dfa4491a3c5c6ffac467e2e2ac2aa58cd46109d38fafea0f2ec0b492ce6ee00a`

image-inspect와 세 container의 `Image`가 모두 이 ID에 일치한다. image의 원래 Created 값은 과거 cached base/layer에 기인할 수 있으므로 이를 이번 최초 빌드 시각으로 쓰지 않는다. 이번 build 기록/LastTagTime/Identity.Build는 별도로 남아 있다. 이미지 내부 `/protocol.py`를 별도 추출해 hash한 영수증은 없다. 여기서 source 결속은 원본 build context/Dockerfile/COPY 기록과 실제 사용 image identity의 연결까지다.

| fixture incarnation | 실제 container ID | 정상 종료 |
|---|---|---|
| first | `a63e79582f7d334141e14726ade452d1ef221452e1b64152b8b90e6edcf24409` | exited, ExitCode0, OOMKilled=false |
| second | `a7eba40ee92bfd141f59883c6dfab2bc68ebe2f2edb79c9ceb41a4f91a866033` | exited, ExitCode0, OOMKilled=false |
| third | `1e4e6d084f0385733faa4019b452d06a282a29b29d22e7f48b387a65644eea1a` | exited, ExitCode0, OOMKilled=false |

각 inspect는 다음을 공통으로 보존한다.

- `/addon`: 해당 source snapshot의 `addons/candle-appraiser` bind mount, `RW=false`.
- `/state`: **같은** local named volume `masc-candle-proof-state-0c67b092c532`, 같은 mountpoint, `RW=true`.
- owner label `candle-container-proof-0c67b092c532`, 서로 다른 first/second/third label, source revision label d35.
- 실제 `python3 server.py --state /state`, workdir `/addon`, read-only rootfs, network none, cap-drop ALL, no-new-privileges, 0.5CPU/128MiB/pids16.

`docker-commands.json`에는 22개 command가 전부 exit0으로 남아 있다. 세 start command stdout은 각각 저장된 replies.jsonl과 byte-identical이다. 저장된 inspect도 원 command stdout JSON과 모두 같다. 요청/응답 수는 순서대로 5/5, 8/8, 9/9이며 ID1..N이 대응한다. image tag만 같다고 동일 실행을 추정한 것이 아니라 각 immutable image/container ID와 raw command output을 대조했다.

## 실제 관측한 요청·상태 경계

1. first requests id3/id4가 `container-grade-1`과 `container-unknown-1`을 submit한다. 둘 모두 **pending** 성공이다. id5 listing은 이 두 원래 ID, 동일 schema, 원래 단일 user prompt를 그대로 반환한다. first가 stdio EOF로 정상 종료한 뒤 exact container ID inspect→rm exit0이 있다.
2. first 제거 후 volume inspect의 Name/CreatedAt/owner label/Mountpoint가 원래 것과 같다. second는 같은 volume에서 observe pending2/finished0과 listing의 원래 두 요청을 읽는다. second에는 submit이 전혀 없으므로 이 pending은 새 container가 다시 만든 것이 아니다.
3. second id4는 Grade `A`, slot `scripted-container-slot`, usage11/3을 **script가 직접** lane_host_result로 전달하고 accepted=true를 받는다. id5 read가 동일 answered 값을 반환한다. id6/id7은 직접 전달한 outcome_unknown의 accepted/read를 보존한다. id8 listing은 empty다.
4. second 제거 후 third observe는 pending0/finished2와 원래 두 ID다. id3 read와 id4 동일 요청 submit은 기존 answered를 반환한다. id5 같은 terminal redelivery는 accepted=true다. id6 다른 terminal Grade B와 id7 같은 ID의 prompt 변경은 각각 실제 MCP isError=true로 거절된다. id8은 원래 unknown을 그대로 읽고 id9 listing은 empty다.
5. 두 exported state record는 version1, 원래 synthetic payout/goal/proof identity, 원래 input/schema/prompt/request ID, original digest와 각 terminal을 보존한다. 두 record의 canonical request SHA256과 request ID 기반 leaf filename도 독립 계산해 각각 일치했다. named volume을 최종 제거하기 전에 third의 `/state/.`를 원본 root로 복사했다.

원본 작업 시간은 receipt상 `2026-10-21T15:45:36.845085Z`–`15:45:39.364359Z`다. 명칭의 20261022는 KST 날짜와 맞으며 UTC 실행일과 혼동하지 않는다.

## 정리 소유권과 한계

- driver는 **생성 결과로 받은 exact container ID**를 owned 목록에 넣고, 삭제 직전 inspect에서 그 ID와 원래 proof-owner label을 확인한다. running=false일 때만 rm한다. 다른 이름의 container를 탐색해 채택하거나 `rm --volumes`로 원래 state를 함께 지우지 않는다.
- 실제 명령 기록에는 first/second/third 각각의 inspect→exact-ID rm 성공이 있다. 최종 volume도 원래 고유 name과 owner label을 다시 확인한 뒤 별도 `volume rm`을 수행한다. 모든 worker state를 export한 후의 최종 qualification 정리다. **제품 Runtime의 Off가 persistent volume을 삭제한다는 증거가 아니다.**
- `cleanup-observed.json`은 owned-container 목록 empty와 원래 volume inspect exit1/no-such-volume을 보존한다. 다만 이 보조 파일 자체에는 원 argv/시각/Docker engine UUID가 없다. command journal에는 각 rm 성공이 있고, 보조 absence 기록은 그 보존된 범위로 읽는다.
- Docker engine UUID/context 전후 영수증은 이번 묶음에 없다. 같은 CLI 경로·volume name/labels/mountpoint/CreatedAt과 실제 data continuity는 확인했지만, production Runtime의 original-engine lease/authority 검증을 거쳤다고 부르지 않는다. unique image의 삭제 기록은 없으며 컨테이너/volume 정리와 구분한다.

## 과장하면 안 되는 범위

- synthetic request ID와 `caller={kind:operator}`를 직접 stdio로 보냈다. 실제 Runtime이 검증한 principal/export owner admission, configuration installation ID, source revision application, stale original export 거부를 실행한 것이 아니다. first/second/third는 fixture incarnation 표기이며 실제 MASC UUID가 아니다.
- actual container 종료는 원본 stdin을 다 읽은 뒤의 정상 EOF다. 실행 중 detach/kill, crash/durability power-loss, 모델 대기 중 Off의 cleanup/cancellation을 관측하지 않았다.
- unknown은 공통 Exact의 불확실 dispatch가 만든 것이 아니라 script가 terminal JSON을 직접 전달했다. 입증한 것은 **그 terminal의 보존과 재listing 방지**다. interruption→Unknown 생산 경로를 완료했다고 부르지 않는다.
- answered/usage도 script 입력이다. network none과 command body 모두 실제 provider/LLM을 호출하지 않은 범위와 일치한다. Grade 판단 품질·Relation/Weights 전체 단계·동적 request-schema host grant/완전 Candle decode는 이번 container 실행 경로 밖이다.
- terminal idempotent ACK/reuse 거부는 worker journal의 중복 방지다. provider 재호출 방지, immutable logical installation A→B fence, host Paid exactly once, confirmed obligation 보존·정산, 실제 Dashboard/TUI는 아직 이번 증거가 아니다.
- receipt의 `scope`와 `provider` 문구는 위 한계를 정확히 명시한다. 이 증거를 E01 실제 Runtime Off/On 또는 full54 완료로 확대할 P0–P2 기록 오류는 확인하지 않았다.

기존 Python subprocess13 PASS보다 **실제 Docker image/container/named-volume 교체 경계**가 하나 추가된 독립 근거로 사용할 수 있다. 다음 기존 두 OCaml suite의 compiled 결과 및 실제 host Runtime/원장/provider/UI 확인은 여전히 별도다. 새 실행이나 source 수리는 이 감사에서 요청하지 않는다.
