# Baseline / native batch / public derivative — independent evidence audit v2

2026-10-27 KST, reviewer `/root/concurrent_probe_review`.

**PASS — 새 완료 raw packet 4개와 지정된 공개 문서 4개의 증거 정합성·수치 대조. P0/P1/P2 정합성 결함 미발견.** 기존 candidate 2/30/300의 v1 판정은 그대로 유지한다. 이 v2는 baseline 1ce158의 2/30/300 및 candidate c3cb의 2×3 packet만 새로 offline 감사했다. native 개선이 확립됐다는 판정은 하지 않는다.

검토자는 native/workload 실행, Dune build, CI/API/live 서버 요청, 네트워크 변경, 대상 소스/원본 packet 수정을 하지 않았다. 정확 reviewed reader를 이용한 offline read-only Python/SQLite 검사와 독립 산술 검산만 실행했다. reader의 derived write는 새 감사 output으로 우회했고 재생성한 report는 원래 report와 값 전체가 같았다. private credential·실행파일은 복사하지 않았다.

## 새 raw packet 감사

| packet | 원래 operation 성공 | 실제 provider calls / peak | valid live-health | 429 / 실제 대기초 | held / terminal member |
|---|---:|---:|---:|---:|---:|
| owned-concurrent-1ce158-2-v3 | 4 | 4 / 2 | 5/5 | 0 / 0 | 0 / 0 |
| owned-concurrent-1ce158-30-v3 | 60 | 60 / 30 | 82/82 | 5 / 5.033641165 | 0 / 0 |
| owned-concurrent-1ce158-300-v3 | 600 | 600 / 300 | 1010/1010 | 68 / 68.454228756 | 0 / 0 |
| owned-concurrent-c3cb371-2x3-v3 | 6 | 4 / 2 | 5/5 | 0 / 0 | 0 / 4 |

각 새 packet에서 원래 성공 enqueue RPC의 정확 name/message와 owner-scoped operation ID를 canonical source/input/admission·execution·member digest, held SQL/public raw status, actual provider request/outcome, public terminal/reply, 보존 원본/backup SQL 및 기록된 cleanup으로 연결했다. 원본/backup은 mode=ro/integrity/전체 typed rows로 확인했다. source/input/digest 및 raw request 해시를 의미 대조했고 원래 입력 중복·누락이 없다. provider overlap은 실제 raw interval과 release crossing으로 재계산했다.

모든 새 packet의 기록된 cleanup은 server returncode0/reaped true/forced kill false, sampler/provider stopped, active provider/handler0, base retained이다. 원래 harness exit0는 root의 실행 관측이며, 검토자는 저장 데이터·원문 receipt와 offline audit를 확인했다. 현재 live process에 새로 질의하지 않았다. 모든 known raw/verdict/원본·backup DB의 감사 전후 해시는 같고 SQLite sidecar inventory도 같았다. 감사 시 sidecar는 0개였다.

baseline 검산은 [baseline-audit/audit-result.json](baseline-audit/audit-result.json), native batch 검산은 [batch-audit/audit-result.json](batch-audit/audit-result.json)에 있다. 각 cohort 하위 `input-hashes.json`과 `audit-summary.json`에 실제 입력 해시와 세부 수치를 결속했다. [additional-read-only-checks.json](additional-read-only-checks.json)은 실제 live-health body/hash/size/status, refuse126 guard, fixture credential의 일치 여부 및 7개 runtime instance/base가 서로 다름을 확인한 기록이다. actual credential 값은 복사하지 않았다.

## baseline binary와 support fixture를 분리한 자격

baseline app source는 **`1ce158d50d3eb48648e6deea7f668172f914fea3`**, server SHA256은 **`e5e30b8ffd632910eb8b8ed023fddb3a8e10742720c26d4b7f0a3561ede5820c`**이다. `native-baseline-1ce158`의 실제 server/TUI 파일, receipt SHA `662ec19743c1b209d37a25263b857d03124af5dba2e51e959c9ebdc4d6a69d9b`, identity command 원문, 4-suite TSV/receipt를 직접 대조했다. baseline TUI SHA는 `1811d5e657306ff3c21552a32687e69ae7608228b740c651ecfc514c6c1e501a`다. 기록된 embedded identity 및 suite/log exits는0이며 해당 명령을 검토자가 재실행하지 않았다.

candidate c3cb와 같은 workflow source **`6a2d8dd6171e1d732ca15f918fb084e462e4d371`**에 결속된다. 이는 같은 host 상태·동일 시간 조건 또는 반복 성능 비교를 증명하지 않는다. shared installation/visible UI verified false도 유지한다.

baseline의 support checkout과 app source는 별개다. harness가 직접 읽는 `scripts/fixtures/release-evidence/runtime.toml`을 **git 1ce158 및 git c3cb에서 각각 직접 추출**하여 바이트 전체가 같음을 확인했다. 두 SHA256 모두 **`ccbe65e399f47a3abddbf4299e15dd0fd55001dd785b2e0d75948ad86acf7cfd`**이며 baseline identity receipt와도 맞는다. support checkout 전체를 baseline source와 같다고 주장하지 않는다. [scope-manifest.json](scope-manifest.json)에 이 구분과 SHA를 보존했다.

frozen native pair의 `comparison_executed:false`는 population 실험 이전 qualification snapshot의 값이다. 공개 README가 그 선행 시점을 명시하므로 이후 실제 baseline 완료 증거와 충돌하지 않는다.

## 새 native batch가 증명하는 범위

2×3 실행에서 각 owner의 actual provider sequence groups는 정확히 `[1]`과 `[2,3]`이다. 첫 원래 입력 두 개는 각각 처리되고, 뒤의 입력 네 개가 owner별 두 입력씩 합쳐져 **총 6개 operation / 4개 model call**이 됐다. terminal DB의 member4행은 **leader2 + follower2**이며 각각의 original admission/member digest와 merged leader execution digest 및 complete reply coverage가 맞는다. 원래 ID가 collapse되어 입력을 잃은 결과가 아니다. 원본/backup의 실제 terminal member 행과 공개 `native-batch-qualification.json`의 행·digest가 모두 일치했다.

held snapshot의 member는 **0**이고 public held 상태는 Running2/Queued4다. 따라서 이 추가 실행은 terminal batch의 native 증거를 보완하며, raw queued/public Running follower를 held SQLite와 동시에 결속한 native 증거까지 추가하지 않는다. **held projection 경계는 계속 source/Python 검증**이다. terminal에서 input/admitted_input_json이 NULL인 것은 c3cb의 정상 규약이며 원래 입력 바이트를 terminal SQL에서 직접 reread했다는 뜻이 아니다.

## 공개 문서 4개 전수 대조

`docs/evidence/performance-keeper-scale-retention-20261026`의 아래 4파일을 전체 읽고 새 output의 `reviewed-documents/`에 동결했다. 공개 문서의 selected values/IDs/digests만 복사했으며 private raw packet, credential, 실행파일은 복사하지 않았다.

| 파일 | SHA256 |
|---|---|
| README.md | `f0a342ea9fe5c114c50d43e9e532ebf56e1384e32c40c4afffa00394327f19cf` |
| native-cohorts-derivative.json | `9caadf6c5028e9cff2b83f1fa90a502e282b3912205f0bc90faf1d41a89507e3` |
| native-cohort-before-after-observations.json | `2e090a0dda2c13572ea6ea8236fc493fa077a39df0e96e4a8fe1d04b8ffe8983` |
| native-batch-qualification.json | `1ec0cab805abf0f6aab4167b8fdcfb18e096153ed0dd7e2e29a1d289025addc6` |

[audit_documents.py](audit_documents.py)는 candidate derivative의 **cohort 객체 전체**를 원래 summary/audit/identity/health/cleanup 및 raw hashes에서 재구성해 exact equality로 비교했다. before-after JSON의 **6개 행 전체**도 원본에서 재구성해 같음을 확인했다. batch JSON의 선택된 모든 수치·member rows·raw hashes도 대조했다. 기존 candidate v1의 원문 receipt hash는 그대로 맞는다. 공개 faults/canonical receipt/native-pair 링크도 각각 기존 원문과 exact-copy hash가 같다. 결과는 [documents-audit.json](documents-audit.json)에 있다.

관측 대상 HEAD는 `a8183cfa901dcdb9bf8bfa1e8bbdf953b058c387`이고 README 수정 및 신규 before-after/batch JSON이 포함된 **working tree bytes**를 감사했다. README는 106행 snapshot이며 마지막 확인까지 4파일 바이트가 같았다. 이것은 해당 HEAD 전체 source review 또는 formal GitHub approval이 아니다. runner/reader/fault probe/하네스 README SHA는 기존 a6df19…/be6b0a…/d8d2bb…/0ab3b9…와 같아 이전 source review 범위를 이월했다. 정확한 전체 SHA는 scope manifest에 있다.

## 수치 해석과 남는 경계

300 population의 baseline/candidate 비교는 다음과 같다. 앞 값이 baseline이며 뒤 값이 candidate다.

| 원본 지표 | baseline 1ce158 | candidate c3cb |
|---|---:|---:|
| admission success wire p50 ms | 22.478375 | 22.22875 |
| exact-status settlement wire max ms | **9582.334** | **13209.662667** |
| released live-health wire max ms | **2546.932208** | **3599.31575** |
| recorded rate wait seconds | 68.454228756 | 70.389767666 |
| after RSS bytes | 2,596,519,936 | 2,097,364,992 |
| before/after GC counter allocation delta bytes | 67,548,205,824 | 67,544,518,400 |

GC 산술은 full-health의 before/after에서 `8*(minor_words+major_words-promoted_words)` 차를 직접 계산했다. 공개 README의 decimal GB 67.548/67.545와 맞는다. 차이는 **−3,687,424 bytes, 약 −0.00545895%**다. 이는 native process의 관측 counter delta이며 sampled Memprof attribution, changed Lane read path의 allocation, CPU-only turn 비용 또는 안정적인 native 개선 증거가 아니다. owner 생성·health/control-plane 처리 등 관측 창의 작업도 포함한다.

candidate 2/30/300 다음 baseline 2/30/300의 시작 wall anchors 순서가 기록과 맞는다. **각 source/population에서 한 번, shared host에서 순차 관측**한 설계다. 유리한 RSS/median이나 불리한 max/status 값을 골라 speedup/regression의 인과 효과로 선언할 수 없다. 공개 문서의 “no established native performance gain”과 changed large retained Lane path 실행을 입증하지 못한다는 경계는 맞다. 0.1ms 목표가 달성됐다는 증거도 없다.

새 baseline 3개 및 2×3의 held/after full-health도 모두 `degraded`, `operator_action_required:true`, `keeper_memory_execution:addon_unattached`다. valid live-health는 full readiness가 아니다. 13.2초/9.6초 exact-status 응답 시간은 durable turn 완료 시각과 분리해야 한다. shared host·단일 admin·quota 대기·의도적 provider hold·순차 상태 관측과 closed-loop health sampling, deny126 inventory, client/OS/I/O 비용을 포함한다. 실제 external model/guest tool/peer/Add-on 업무, TUI 또는 production 설치·전체 readiness 성공으로 확대하지 않는다.

이 v2는 지정된 새 raw와 동결된 공개 문서에 대한 증거 감사로 종료한다. 새 native 측정이나 PR 게시·승인·merge 판정이 아니다.
