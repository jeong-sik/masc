# RFC-0383 코퍼스 acceptance 라이브 실측 (2026-08-16)

- **Evidence**: :8949 격리 인스턴스 (`/private/tmp/.../scratchpad/mascroot`, masc-e8 세션 소유), 실측 전반부 commit `11401927ef` → 재기동 후 `523db18df2` (0.23.0). 로그 `<base>/.masc/logs/system_log_2026-08-16.jsonl`, trace `trace-1786546240916-00000`.
- **Timestamp**: 2026-08-16T02:31Z ~ 03:32Z
- **Confidence**: High (서버 로그 + 파일시스템 + keeper trace 3중 교차)
- **Delta**: acceptance 1은 keeper 턴에서 라이브 검증 완료. acceptance 3은 keeper 레인에서 2단계 모두 해석 불가로 판명(#28820) — RFC-0383 문서의 소비 계약은 agent 레인만 성립. 부산물로 HITL resolution 배달 기아 결함 발견·수정(#28809 → PR #28818).

## 1. acceptance 1 — 오프로드마다 index 행 (라이브 PASS)

자극: `@rtprobe WebSearch("OCaml 5.5 effect handlers tutorial", includeContent=true, limit=5)` (02:41:13Z 발화, wmsg-bafc21e6).

경로가 특이했다: 호출은 auto_judge 게이트에 유예 → 승인 → **배달 기아(#28809, 아래 §3)** → 인스턴스 재기동(마침 #28788 반영 재기동) 후 pending `Hitl_resolved`가 배달되며 RFC-0356 host replay가 실행:

```
03:12:52Z turn entry: hitl resolution delivered approval=appr_c055a52f-… decision=approve (keeper=rtprobe)
03:13:01Z gate replay approval=appr_c055a52f-… applied operation=network_read journal=recorded output_bytes=31614 output_sha256=31d6b2b0…
```

그 network_read 안의 includeContent 절단 경로가 코퍼스를 만들었다 (03:12:54~13:01Z):

- `<base>/.masc/artifacts/web-fetch/index.jsonl` — **5행**, 전부 `masc.web_artifact.v1`, sha256=파일명, title/bytes/fetched_at 채워짐.
- 본문 4파일 (28,975 / 36,909 / 6,757 / 14,309 bytes).
- **내용 주소 dedup 관측**: `github.com/ocaml-multicore/ocaml-effects-tutorial`와 그 `blob/master/README.md` 두 URL이 같은 sha `2dd3ef61…` 한 파일을 가리키는 index 2행 — 설계대로 파일은 진실, index는 projection.

## 2. acceptance 3 — 웹 왕복 없는 재질의 (keeper 레인 FAIL → #28820)

자극: `@rtprobe` (1) `Grep(pattern=ocaml.org, path=.masc/artifacts/web-fetch/index.jsonl)` (2) `keeper_artifact_read(sha256=f2c0826c…, offset=0, max_bytes=600)`.

| 단계 | 결과 | 근거 |
|---|---|---|
| index Grep | **실패** — sandbox cwd 이중 결합 `<base>/.masc/playground/rtprobe/.masc/artifacts/...`, rg exit 2 | trace tool_result (`ok:false, via:host`) |
| artifact_read | 지시한 web-fetch sha 대신 컨텍스트의 replay blob `31d6b2b0…`로 **대체 호출** (out_len=20775, ok). 지시 sha `f2c0826c…`는 `tool_blobs/`에 부재 (`f2` shard 없음) → 호출했다면 "artifact does not exist" | 로그 tool_call + `ls tool_blobs/` |

정적 교차: `keeper_artifact_read.ml`은 `Tool_blob_store`(`.masc/tool_blobs/`)만 resolve, 오프로드는 `.masc/artifacts/web-fetch/`에 기록 — 저장소 분리. 상세와 수정 방향(본문 저장 단일화 + discovery 표면 결정)은 #28820.

**agent 레인**은 두 단계 모두 성립한다(임의 경로 Grep 가능 + 운영자가 파일 직접 읽기) — RFC 문서의 계약 문구를 keeper/agent 레인으로 분리 정정해야 한다.

## 3. 부산물 — HITL resolution 배달 기아 (#28809, PR #28818)

02:41:51Z approve 커밋 직후 keeper가 깨어났으나 wake 사유는 재배달 workspace message뿐 → `hitl_resolution=None`으로 checkpoint 재개 → replay 미발화 → deepseek-v4-flash가 `keeper_surface_read` ~660회 루프로 20분+ 방황(turn_limit=unlimited, single-flight 점유) → 큐의 `Hitl_resolved` 기아. 재기동이 우연히 배달을 복구했고(§1), 그 배달-즉시-replay 성공이 "배달만이 결여였다"는 근본 원인 판정을 실증했다. 수정은 PR #28818 (턴 시작 projection + post-tool boundary 선점).

## 재현 명령 (요지)

```bash
# 자극 (rtprobe 토큰으로)
masc_broadcast '{"agent_name":"claude","message":"@rtprobe WebSearch 도구를 호출해 주세요. 인자: query=\"…\", includeContent=true, limit=5. …"}'
# 관측
rg 'gate replay approval|hitl resolution delivered' <base>/.masc/logs/system_log_2026-08-16.jsonl
cat <base>/.masc/artifacts/web-fetch/index.jsonl
```

## 4. 재실측 — #28818·#28826 병합 후 (05:39–06:16Z, :8949 scratch)

환경: scratch 인스턴스가 05:39:05Z에 신 바이너리(#28818+#28826 포함)로 재기동. 프로덕션(:8935)도 05:55:53Z에 신 바이너리로 재기동 (`--base-path=/Users/dancer/me`).

### #28818 야생 실증 3건 — 배달 기아 0초

| 시각(Z) | approval | decision | projection | 큐 배달 |
|---|---|---|---|---|
| 05:45:26 | appr_5fed3255 | reject | **같은 초** (`hitl resolution projected from pending queue`) | 05:49:54 |
| 05:56:10 | appr_eec08643 | reject | 같은 초 | 06:01:16 |
| ≈06:13 | appr_11fef7f1 | reject | 같은 턴 (proj 카운트 3→4) | — |

approve 경로는 프로덕션 04:25:41Z(appr_2361efbf, memory_write)에서 이미 실증 — 두 decision 모두 재기동 없이 배달된다. §3의 기아(재기동으로만 복구)와 대조.

### acceptance 3 — keeper 레인 첫 라이브 PASS

06:12:22Z, 활성 task-001 앵커 하에 `keeper_artifact_read(sha256=31d6b2b0…, offset=0, max_bytes=400)`:

```
tool_call tool=keeper_artifact_read input_shape=[max_bytes=int,offset=int,sha256=string:64] outcome=ok out_len=613
```

tool_error 누적 2건(§2, #28820 결함 증거)에서 증가 없음. §2의 FAIL(저장소 분리)이 #28826(put_durable 단일화)로 닫혔음을 keeper 레인에서 확인.

### acceptance 1 (신 레인) — 라이브 미측정, 게이트 차단 기록

auto-judge가 web_search 유예를 3회 reject (05:45:26 / 05:56:10 / ≈06:13). 3차는 judge가 요구한 활성 task 앵커(task-001, add 06:10:50 → claim/start 06:11, reject 시점에 in_progress; rtprobe 자율 release는 06:15:00)를 갖춘 상태였다. 3차 사유에는 검증 가능한 허위 포렌식("empty-string hash" — 실제 입력은 string:64, 빈 문자열 sha `e3b0c442…`와 불일치)이 포함 → #28842. 3회 시점에서 재시도 중단(게이트 판정 존중).

신 레인 저장 경로의 대체 근거: (a) CI `test_tool_misc_web_fetch` — `put_durable` 후 reader와 같은 `Tool_blob_store.fetch`로 sha 동일성 핀, (b) 구 레인 라이브 PASS(§1, 메커니즘 동일·백엔드만 상이), (c) 프로덕션 유기 트래픽 후속 관측 — 신 바이너리 기동(05:55:53Z) 이후 첫 오프로드가 `tool_blobs/` blob + `full_text_sha256` 마커로 남는지 확인 (구 레인 마지막 오프로드는 04:33:12Z).

부산물: 발신 주체(운영자 대리 발신 vs keeper 자율 발화 vs auto-judge)가 UI에서 구분되지 않는 문제를 #28841로 분리.

## 5. acceptance 1 신 레인 — 유기적 라이브 PASS (07:30Z, 프로덕션)

§4에서 예고한 (c) 유기 트래픽 관측이 닫혔다. 프로덕션(:8935, 신 바이너리 05:55:53Z 기동)에서 keeper 유기 트래픽의 web-fetch 오프로드 2건:

| fetched_at(Z) | sha256(전위) | bytes | source |
|---|---|---|---|
| 07:30:42 | `7a0bdcd1d753c925` | 8,137 | kofic.or.kr 박스오피스 |
| 07:30:44 | `995b6c0107359ffe` | 15,748 | dategom.com 8월 개봉작 |

판정 근거 3중:

1. **신 레인 상륙**: 두 본문 모두 `tool_blobs/<aa>/<sha>`에 존재 — `keeper_artifact_read`가 읽는 바로 그 store.
2. **구 레인 무생성**: `artifacts/web-fetch/`에 새 `.md` 없음 (index.jsonl만 2행 증가, 5행) — hard cut 유지.
3. **무결성**: 두 blob 모두 `shasum -a 256` = 파일명, bytes = index 행 값.

이로써 acceptance 1은 CI 테스트·구 레인 라이브·**신 레인 유기 라이브** 세 겹으로 닫혔고, §4의 "라이브 미측정"은 계측용 자극 한정으로 좁혀진다 — 유기 트래픽은 게이트와 무관하게 경로를 실증했다.
