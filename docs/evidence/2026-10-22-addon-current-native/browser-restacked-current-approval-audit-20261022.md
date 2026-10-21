integration_status: BLOCKED — restacked-current metadata census, not source or merge approval

# A06 Browser Native Stack #44168: whole rebase 이후 현재 승인 감사

관측 창 UTC `2026-10-21T16:08:49.007780+00:00` → `2026-10-21T16:11:04.390392+00:00` (KST 2026-10-22). REST Stacks API와 각 PR 상세, 모든 reviews/comments 페이지, GraphQL reviewThreads를 독립 조회했다. API 동시수는 최대4이며 모든 응답을 확인했다. Actions API/guard/CI는 호출하지 않았다.

## 정확한 새 벡터와 이전 조사 비교

- 현재 top #44702: `aa0e05f6fcdfb4d0e5d35650dbbe07f169515971`. 처음/마지막 Stacks API가 같은 67개 순서·head·base를 반환했다. 모두 open/Ready이다.
- 이전 census top: `d35d2559c56814b38615545a5f4f081304bccc05`. 순서는 같지만 **67개 head와67개 direct base가 모두 바뀌었다**. 이전29/38 집계를 새 후보로 이월하지 않았다.
- 현재 Native metadata/bottom REST base: `21515629d2007c58403e6eb5d790d5f5c1cfaaec`. bottom의 실제 local Git 3-dot source merge-base: `003f52e210d31abe087f0edeba335e5bb095f4af`. bottom을 제외한66층의 merge-base는 각 direct base와 같았다.
- 이번 조회의 실제 branches/main: `c3efec4db0a32c1bac8d298ccadd7506e06ec16f`. Native metadata의 선택된 base, source fork, 당시 actual main을 같은 값으로 취급하지 않았다. 이후 main 이동을 자동 추정하지 않는다.
- 이전과 현재 canonical whole-layer diff identity는36층 동일/31층 변경이다. 이것은 raw tree diff 식별자 비교이며 소스/동작 동치 증명이나 승인의 head 재결속이 아니다. source diff 전체를 읽은 것으로 세지 않았다.

## 현재 남은 blocker

**현재 head 결속 formal approval: 0/67층.** 모든67층에 새 head/base/diff 범위의 정식 승인이 필요하다. 계정별 최신 APPROVED 자체가 없는24층과 과거 head의 APPROVED만 남은43층으로 나뉜다. 이전 current-bound29층도 이번 후보에는0건이다.

계정별 최신 APPROVED 없음(24):

#44301, #44324, #44335, #44341, #44347, #44353, #44364, #44376, #44407, #44418, #44424, #44431, #44451, #44483, #44498, #44520, #44533, #44545, #44552, #44556, #44563, #44603, #44617, #44621

APPROVED가 있지만 과거 head에만 결속(43):

#44153, #44167, #44175, #44183, #44192, #44198, #44214, #44235, #44258, #44277, #44295, #44390, #44400, #44438, #44470, #44476, #44489, #44494, #44501, #44502, #44504, #44506, #44510, #44512, #44527, #44539, #44550, #44571, #44574, #44578, #44582, #44592, #44596, #44607, #44609, #44631, #44634, #44636, #44642, #44653, #44695, #44698, #44702

**현재 top #44702에 충돌 신호가 남았다.** 최초 상세와 마지막 경계 GET 모두 현재 head aa0e05f6...에서 `mergeable=false`, `mergeable_state=dirty`였다. 나머지66층은 `mergeable=true`다. 상태 분포는 clean42/blocked24/dirty1. 이전 census의 #44192는 이제 충돌 신호가 없고 top으로 위치가 바뀌었다. updater의 whole rebase/push 완료 보고를 이 서버 상태와 동일시하지 않았다. 이것은 Native Stack의 통합 차단 신호이지 #44702만 별도 병합/retarget할 사유가 아니다. 이 조사에서 실제 충돌 파일/해결책을 source로 재현한 것은 아니며 `blocked`24건의 branch-protection 원인도 독립 조사하지 않았다.

## 현재 negative/review 상태

- 현재 head를 지목하는 최신 structured FAIL/HOLD/INVALID/UNTRUSTED:0. 현재 structured PASS도0이고 67층 모두 현재-head structured verdict가 없다. old-head PASS/FAIL/HOLD와 본문을 그대로 원본 JSON에 보존했다.
- 계정별 최신 formal CHANGES_REQUESTED:0. Draft:0.
- GraphQL67개가 마지막 페이지까지 성공했고 reviewThreads 자체0/미해결0이다. issue comments의 모든 질문이 소스에서 해소됐다는 의미는 아니다.
- 새 formal APPROVED2건도 현재 승인이 아니다. #44153 review5602254295는 API commit_id가0e3afbc2...지만 본문 첫 줄/footer는 c9734c4c...; #44167 review5602312315는 API commit_id가8b8be93b...지만 본문/footer는890b7b5a...다. 두 본문을 직접 읽었고 old-head 소스 리뷰임을 확인했다.
- #44175/#44183 등도 API commit_id가 새 head로 옮겨졌더라도 불변 본문/footer가 old head이므로 제외했다. body first-line/footer 검사를 API commit_id로 대체하지 않았다.
- 과거 retraction·실행 FAIL·dismissed CR은 역사적 증거로 남겨두었다. 새 source가 그 실패를 실제 수리했다거나 실행 성공했다고 이 census가 판정하지 않았다. 현재 formal CR0이라는 사실만으로 제품 결함 없음도 주장하지 않는다.

## 검증 방식과 범위

REST201개 endpoint 수신:67 PR 상세·140 formal reviews·203 issue comments. reviews/comments는 `--paginate --slurp`로 모든 페이지를 읽었다. GraphQL67개 thread 조회, fresh Stack API2회, actual main1회, current top 경계GET을 별도 보존했다. API 오류·canonical identity 미확인·잘린 thread 페이지는 없다.

승인 후보는 계정별 최신 APPROVED/CHANGES_REQUESTED/DISMISSED를 review ID순으로 집계했다. PR author와 다른 trusted 계정 여부, run 없는 정확한 첫 줄 `verdict: PASS head: <40hex> by: <name>`, 마지막 nonempty approve-guard footer의 head/current complete diff, review-scope의 base_ref/base_sha/Native Stack 번호·position·base를 대조했다. 각 층의 현재 full raw Git 3-dot delta로 canonical identity를 계산했다. 모든 후보의 첫 줄/footer/scope와 제외 이유를 primary JSON에 남겼다. 전체 diff의 내용/직접 consumer를 직접 소스 리뷰했다는 뜻은 아니다.

constitution·Contributor·Native Stacks guide·approve-guard/refusal/scope/verdict7파일을 이번에 독립 조회한 actual main c3efec4d...의 Contents API 원문과 다시 대조했고 읽었던 로컬 정책과 byte-identical이었다. 정책 parser는 그 확인된 버전에 따른 census에만 사용했다. `approve-guard.sh`나 `merge-guard.sh`는 실행하지 않았다. trusted non-author 계정이라는 API 증거와 footer 선언을 확인했을 뿐 각 세션의 author/push 독립성 이력까지 재입증하지 않았다.

## 이전 canonical과 다른31층

#44167, #44175, #44183, #44192, #44198, #44214, #44235, #44258, #44277, #44295, #44301, #44341, #44353, #44364, #44376, #44390, #44400, #44407, #44424, #44438, #44451, #44470, #44483, #44498, #44520, #44533, #44539, #44607, #44631, #44653, #44702

위 목록은 변경 검토를 좁히는 식별 자료다. 새 후보의31층을 source 리뷰 완료했다고 주장하지 않는다. canonical이 동일한36층도 head가 다르므로 과거 승인을 현재 승인으로 셀 수 없다. 리뷰 재사용은 이전 head/base/diff와 실제 delta를 직접 읽은 범위에 한정하고 새 footer로 결속해야 한다. 일반 스택에 CI 미실행만을 이유로 새 gate를 추가하지 않았다.

## PR별 exact-vector census

SHA와 canonical은 표에서12자리로 줄였고 JSON에는 모든40/64자리 identity와 원래 승인 본문 첫 줄/footer가 있다. STALE은 old-head APPROVED만, MISSING은 계정별 최신 APPROVED가 없다. 이전 결속 승인 count는 이 표에 이월하지 않았다.

| 순서 | PR | 현재 head | 현재 direct base | 현재 canonical | old 대비 canonical | 승인 | REST 상태 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | #44153 | `0e3afbc2bfea` | `21515629d200` | `d365f42d8c2b` | same | STALE | clean |
| 2 | #44167 | `8b8be93be634` | `0e3afbc2bfea` | `87b296b9362e` | changed | STALE | clean |
| 3 | #44175 | `377a4b80f0ec` | `8b8be93be634` | `ed796fdd7258` | changed | STALE | clean |
| 4 | #44183 | `d41be6dd197d` | `377a4b80f0ec` | `3ed0574c3c82` | changed | STALE | clean |
| 5 | #44192 | `a1ad8e4fa9b9` | `d41be6dd197d` | `6b9b76e0d6e2` | changed | STALE | clean |
| 6 | #44198 | `f4cb0ca5395e` | `a1ad8e4fa9b9` | `49056d81f250` | changed | STALE | clean |
| 7 | #44214 | `b27d67dc539f` | `f4cb0ca5395e` | `8ac2d1bea03c` | changed | STALE | clean |
| 8 | #44235 | `ea7cd8bd17ad` | `b27d67dc539f` | `3db732a0e052` | changed | STALE | clean |
| 9 | #44258 | `c666a871b70e` | `ea7cd8bd17ad` | `1fa72501c8fc` | changed | STALE | clean |
| 10 | #44277 | `0232543a73c2` | `c666a871b70e` | `5831359cf22c` | changed | STALE | clean |
| 11 | #44295 | `5379dc73546a` | `0232543a73c2` | `2fbde97f2d6c` | changed | STALE | clean |
| 12 | #44301 | `9249c4f9c224` | `5379dc73546a` | `c5e31028a0ed` | changed | MISSING | blocked |
| 13 | #44324 | `efd9d1a39e1e` | `9249c4f9c224` | `aa23af55dcfc` | same | MISSING | blocked |
| 14 | #44335 | `8ba2acd6bf70` | `efd9d1a39e1e` | `ff9cb3f3cdf5` | same | MISSING | blocked |
| 15 | #44341 | `30e9ff316bbd` | `8ba2acd6bf70` | `f84b323472cc` | changed | MISSING | blocked |
| 16 | #44347 | `44a7f114491c` | `30e9ff316bbd` | `864366eb789a` | same | MISSING | blocked |
| 17 | #44353 | `dc9d2dc65b07` | `44a7f114491c` | `7471026743b3` | changed | MISSING | blocked |
| 18 | #44364 | `ccc2f02b7160` | `dc9d2dc65b07` | `26a921f9d268` | changed | MISSING | blocked |
| 19 | #44376 | `f38819e9ac07` | `ccc2f02b7160` | `9205490cca3a` | changed | MISSING | blocked |
| 20 | #44390 | `0f5197ef0500` | `f38819e9ac07` | `478374dc440a` | changed | STALE | clean |
| 21 | #44400 | `01abd70dd446` | `0f5197ef0500` | `c230c9df6460` | changed | STALE | clean |
| 22 | #44407 | `176f7937342c` | `01abd70dd446` | `61f76c481074` | changed | MISSING | blocked |
| 23 | #44418 | `a8ccfe68bbb2` | `176f7937342c` | `ff0e97bc7c70` | same | MISSING | blocked |
| 24 | #44424 | `e222c719f1c1` | `a8ccfe68bbb2` | `c5e07469e00a` | changed | MISSING | blocked |
| 25 | #44431 | `c0e484e311a5` | `e222c719f1c1` | `dcbc16c2d523` | same | MISSING | blocked |
| 26 | #44438 | `cde013852b60` | `c0e484e311a5` | `614064a0fa54` | changed | STALE | clean |
| 27 | #44451 | `048a0d641162` | `cde013852b60` | `4dc9d5715939` | changed | MISSING | blocked |
| 28 | #44470 | `e8fbc7ec7293` | `048a0d641162` | `78dbbbaf6e97` | changed | STALE | clean |
| 29 | #44476 | `76ee18c0a8e5` | `e8fbc7ec7293` | `7803791de3c8` | same | STALE | clean |
| 30 | #44483 | `287d4d82a6a5` | `76ee18c0a8e5` | `3bdb2c226247` | changed | MISSING | blocked |
| 31 | #44489 | `4f818d7f7ed8` | `287d4d82a6a5` | `a66b7039e855` | same | STALE | clean |
| 32 | #44494 | `535f3388739a` | `4f818d7f7ed8` | `291620397d1f` | same | STALE | clean |
| 33 | #44498 | `ff2c7c84fafc` | `535f3388739a` | `8fc54007c084` | changed | MISSING | blocked |
| 34 | #44501 | `769264b9e6b9` | `ff2c7c84fafc` | `26102cff9112` | same | STALE | clean |
| 35 | #44502 | `cb5437f3e41b` | `769264b9e6b9` | `56becf1a3ff2` | same | STALE | clean |
| 36 | #44504 | `e8de981daf3c` | `cb5437f3e41b` | `fe9ea86cc896` | same | STALE | clean |
| 37 | #44506 | `4c8acf55daf1` | `e8de981daf3c` | `e062dfd671ac` | same | STALE | clean |
| 38 | #44510 | `03c2a91b84d9` | `4c8acf55daf1` | `ec5d01ea04e1` | same | STALE | clean |
| 39 | #44512 | `e2ace3e60257` | `03c2a91b84d9` | `cba9fad5d43a` | same | STALE | clean |
| 40 | #44520 | `ee17cd62637a` | `e2ace3e60257` | `10c053281787` | changed | MISSING | blocked |
| 41 | #44527 | `eeb0b4cafd1e` | `ee17cd62637a` | `6ccbd34b0acc` | same | STALE | clean |
| 42 | #44533 | `31c6066b3276` | `eeb0b4cafd1e` | `6c119c5add8d` | changed | MISSING | blocked |
| 43 | #44539 | `acf59030565c` | `31c6066b3276` | `18d9b1674df8` | changed | STALE | clean |
| 44 | #44545 | `279828f803a1` | `acf59030565c` | `5c74fe520890` | same | MISSING | blocked |
| 45 | #44550 | `83bf20821f87` | `279828f803a1` | `2e8a1069c66e` | same | STALE | clean |
| 46 | #44552 | `8e4a9fb56558` | `83bf20821f87` | `f93dbe3186d1` | same | MISSING | blocked |
| 47 | #44556 | `3df09e9bd03f` | `8e4a9fb56558` | `b66e8a619e70` | same | MISSING | blocked |
| 48 | #44563 | `8b5b52245e3d` | `3df09e9bd03f` | `005aec64f0c4` | same | MISSING | blocked |
| 49 | #44571 | `07ae669daa37` | `8b5b52245e3d` | `1afa14041444` | same | STALE | clean |
| 50 | #44574 | `af2cf6c37f20` | `07ae669daa37` | `500da8f3781a` | same | STALE | clean |
| 51 | #44578 | `f9d3a5ef629a` | `af2cf6c37f20` | `592d5c5dd96e` | same | STALE | clean |
| 52 | #44582 | `dc9ac8efd9b3` | `f9d3a5ef629a` | `51735af0264f` | same | STALE | clean |
| 53 | #44592 | `50991f95ced0` | `dc9ac8efd9b3` | `908dbf0f4537` | same | STALE | clean |
| 54 | #44596 | `f38b94111986` | `50991f95ced0` | `401d3f2a9ab1` | same | STALE | clean |
| 55 | #44603 | `562da7bb86e4` | `f38b94111986` | `0468ee87a8e5` | same | MISSING | blocked |
| 56 | #44607 | `c4b56650f029` | `562da7bb86e4` | `a4ef4b9e48b4` | changed | STALE | clean |
| 57 | #44609 | `0972f30224f9` | `c4b56650f029` | `861f0a49175e` | same | STALE | clean |
| 58 | #44617 | `7670154b2dbd` | `0972f30224f9` | `6bb13cdea6df` | same | MISSING | blocked |
| 59 | #44621 | `21fbcc404324` | `7670154b2dbd` | `0deb19e99332` | same | MISSING | blocked |
| 60 | #44631 | `ae1c6b0d9b39` | `21fbcc404324` | `b5d419d5f548` | changed | STALE | clean |
| 61 | #44634 | `73f32144f5fd` | `ae1c6b0d9b39` | `54f4502a7b90` | same | STALE | clean |
| 62 | #44636 | `0a655d3235fd` | `73f32144f5fd` | `0507624bc687` | same | STALE | clean |
| 63 | #44642 | `865ccc04454a` | `0a655d3235fd` | `301696c13c8a` | same | STALE | clean |
| 64 | #44653 | `d2df6ca34e0d` | `865ccc04454a` | `f1249fab4704` | changed | STALE | clean |
| 65 | #44695 | `49cd2a3e5907` | `d2df6ca34e0d` | `acc927c6d1df` | same | STALE | clean |
| 66 | #44698 | `b87f298f3585` | `49cd2a3e5907` | `83a45a87485a` | same | STALE | clean |
| 67 | #44702 | `aa0e05f6fcdf` | `b87f298f3585` | `9092b6135616` | changed | STALE | dirty |

## 보존 자료 및 수행하지 않은 일

- `.json`: exact67 head/base/canonical, 이전d35 벡터와의 identity 비교, approval 후보와 거부 이유, current/historical verdict, 개별 status와 최신 comments.
- `.raw.json` 및 `.raw/`: endpoint·수신 시각·exit code를 포함한 원본 REST/GraphQL/정책 blob 자료.

이는 원자적 승인 lock이 아닌 위 조회 창의 census다. 마지막 Stack API는 동일 벡터를 확인했으나 리뷰/서버 상태가 이후 바뀌면 소비 직전에 다시 읽어야 한다. source/ref/GitHub/runtime 수정, Keeper/리뷰 메시지 전송, rebase/push/merge, Dune/타입/실행 검사, Actions 조회/dispatch/watch, approve-guard/merge-guard/정식승인 모두 수행하지 않았다. 조사용 /tmp 파일만 작성했다. Git 객체/전체 diff는 identity 산출을 위해 읽었으며 source 전체 리뷰로 세지 않았다.

판단: 현재 exact aa0e05f6... Native Stack은 승인 결속0/67과 top dirty 때문에 A06 통합 판단을 진행할 수 없다. 일반 CI 미실행은 여기서 추가 차단으로 삼지 않는다. updater 완료 보고, source 변화, 실제 새 main과의 통합, guard/승인, 실행/설치/UI는 각각 별도로 남아 있다.
