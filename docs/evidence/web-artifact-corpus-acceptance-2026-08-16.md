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
