# 첫 요청의 캐시 미스: 접두사를 깨는 것은 무엇인가 — 실측과 순서

작성: 2026-09-17 (KST 02:00). 읽기 전용 실측.
데이터: `costs`, `keepers/*/turn-records`, `keepers/*/provider-inputs`, `keepers/*/execution-receipts` 의 2026-09-15·16(UTC) 파일 83개. 파일별 바이트·SHA-256 은 [증거 JSON](../evidence/prefix-cache-first-round-20260917.json)에 있다. 프롬프트 본문은 보고서에 넣지 않았다. 스냅샷 비교는 blob 참조가 이미 들고 있는 SHA-256 으로만 했다.
재현: `python3 scripts/analysis/prefix-cache-first-round.py --masc-root <base> --date 2026-09-15 --date 2026-09-16 --deploy-at 2026-09-16T13:21:56Z --output <json>`.
서버: 1c5645873e, 2026-09-16 13:21:56Z 시작. "배포 전/후" 는 이 시각으로 가른다.
토큰: 공급자가 센 `input_tokens` 는 그대로 적었다. 거절돼 세어지지 않은 요청은 그 런타임의 실측 밀도로 ≈ 환산했다(완료 요청의 request_body_bytes ÷ input_tokens 중앙값, 2026-09-16: deepseek 3.65, glm 3.39, kimi 4.15 B/tok — kimi 는 완료 2건뿐).

## 판단

1. **세 Agent Core 레인 모두 캐시 읽기를 보고한다.** 2026-09-16 의 앞선 답("ollama_cloud·glm 은 cached_tokens 를 안 준다, 측정 불가")은 틀렸다. turn record 의 `cache_read_input_tokens` 와 costs 원장의 `cache_read_tokens` 를 잘못된 키로 세었다. 정정한 값: cache_read/input 이 ollama_cloud(deepseek) 80.7%, glm 70.8%, claude_code 98.1%.
2. **미스는 턴의 첫 라운드에 몰린다.** 같은 턴의 두 번째 요청부터는 1.6~6% 만 미스다. 첫 라운드는 배포 전 glm 88%, deepseek 77% 가 미스였다.
3. **배포 전 첫 라운드 미스의 원인은 툴 배열이 아니라 이력의 머리가 매 턴 움직인 것이다.** 연속 두 턴의 요청 스냅샷에서 메시지 SHA 가 같은 접두사 길이(LCP)는 lane-smith 144쌍 중앙값 0.02, analyst 66쌍 0.02, pr-updater 52쌍 0.03 이었다. 첫 번째 메시지부터 달랐다. 바이트 예산으로 정확히 자르는 컷이 1~2 atom 씩 앞뒤로 흔들렸기 때문이다. 60 atom 단위의 quantized cut 은 방이 60 atom 보다 작아(lane-smith 11 atom) 한 번도 적용되지 않았다.
4. **#36823 의 carried front 가 그것을 고쳤다.** 배포 후 deepseek 레인: lane-smith LCP 0.99(18쌍), pr-updater 0.99(30쌍), kidsnote-slack-context-collector 0.99(16쌍). 첫 라운드 미스 중앙값 77.2% → 31.7%(n=131), 미스 토큰 69k → 42k.
5. **배포 후 남는 첫 라운드 미스는 꼬리·툴 변화·공급자 TTL 세 가지다.** 15분 이내에 툴이 같았던 59건은 중앙값 21% 미스로, `[system context]`(memory recall 약 40k 토큰)와 직전 턴의 마지막 메시지 크기다. 툴 배열이 달라진 12건은 83% 미스. 15분 넘게 쉰 뒤의 첫 라운드는 공급자 캐시가 죽어 전량 미스다(deepseek 15~60분 53%, 1시간+ 80%; glm 은 5~15분에서 이미 47%).
6. **캐시보다 급한 것이 있다.** 배포 후 3.5시간, glm 머리 레인 keeper 의 완료가 jazz-developer 0/25, goo-yang-bong 0/18, analyst 0/10, msx-retro-mania 0/9 다. 원인 셋은 이슈로 냈다: kimi 후보가 매 턴 이력 전체(≈1.2M~3.1M 토큰)를 받고 거절된다(#36860 — #36857 이 고쳤다, 아래 eee8f6aee8 절), deepseek 턴 27% 가 반복 생성으로 끝난다(#36861), glm 턴 35% 가 429 로 끝난다(#36862). 실패한 턴도 요청을 다 보낸 뒤 끝나므로, 이 셋을 두고 캐시를 다듬는 것은 새는 통에 물 붓기다.

## 숫자

### 캐시 읽기 (완료된 turn record, 2일)

| family | rows | 완료 | cache_read > 0 | cache_read / input |
|---|---:|---:|---:|---:|
| claude_code | 1,846 | 1,730 | 1,706 | 98.1% |
| ollama_cloud (deepseek-v4.1-flash) | 898 | 636 | 620 | 80.7% |
| glm-coding (glm-5.3-flash) | 751 | 473 | 437 | 70.8% |
| kimi_coding (kimi-k3) | 151 | 1 | 1 | 85.9% |

### 첫 라운드와 이후 라운드 (costs `raw_observation`, 요청 단위)

| family | 시기 | 첫 라운드 n | 미스 중앙값 | 미스 토큰 중앙값 | 입력 중앙값 | 전량 미스(>90%) | 이후 라운드 n | 미스 중앙값 | 첫 라운드가 낸 미스 토큰 몫 | 턴당 입력 증가 중앙값 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| ollama_cloud | 배포 전 | 828 | 77.2% | 69,284 | 94,535 | 27.2% | 8,958 | 6.2% | 28.1% | 4,234 |
| ollama_cloud | 배포 후 | 131 | 31.7% | 42,194 | 105,633 | 15.3% | 438 | 3.0% | 58.5% | 6,248 |
| glm-coding | 배포 전 | 744 | 87.7% | 83,202 | 96,218 | 44.2% | 4,853 | 1.6% | 51.2% | 3,705 |
| glm-coding | 배포 후 | 18 | 100% | 107,716 | 108,486 | 83.3% | 162 | 1.4% | 68.3% | 6,004 |

glm 배포 후 18건은 표본이 작고 그중 대부분이 429 로 끝난 턴의 첫 요청이다. glm 이 배포 후에도 100% 미스인 이유는 아래 "공백" 표가 말한다: glm 캐시는 분 단위로 죽는다.

### 연속 두 턴의 요청 스냅샷: 메시지 접두사가 같은가

스냅샷은 턴의 마지막 요청이다. `prev is prefix` 는 앞 턴의 메시지 목록 전체가 뒤 턴 목록의 접두사였던 쌍의 수. LCP 는 같은 접두사 길이를 앞 턴 길이로 나눈 값.

| keeper | lane | 시기 | 쌍 | LCP 중앙값 | 첫 차이 위치 중앙값 | 본문 중앙값 (≈토큰) |
|---|---|---|---:|---:|---:|---:|
| lane-smith | ollama_cloud | 배포 전 | 144 | 0.02 | 1 | ≈77.4k (282,518 B) |
| lane-smith | ollama_cloud | 배포 후 | 18 | 0.99 | 80 | ≈67.1k (244,840 B) |
| pr-updater | ollama_cloud | 배포 전 | 52 | 0.03 | 1 | ≈83.7k (305,328 B) |
| pr-updater | ollama_cloud | 배포 후 | 30 | 0.99 | 7,702 | ≈3.54M (12,911,403 B) |
| analyst | ollama_cloud | 배포 전 | 66 | 0.02 | 1 | ≈75.2k (274,525 B) |
| analyst | ollama_cloud | 배포 후 | 8 | 0.06 | 1 | ≈71.4k (260,542 B) |
| goo-yang-bong | glm-coding | 배포 전 | 27 | 0.69 | 73 | ≈78.4k (265,609 B) |
| goo-yang-bong | glm-coding | 배포 후 | 7 | 0.04 | 1 | ≈166.5k (564,378 B) |
| kidsnote-slack-context-collector | ollama_cloud | 배포 전 | 73 | 0.96 | 66 | ≈65.6k (239,379 B) |
| kidsnote-slack-context-collector | ollama_cloud | 배포 후 | 16 | 0.99 | 96 | ≈93.3k (340,632 B) |

읽는 법. 배포 전 LCP 0.02 인 keeper 는 이력이 방보다 커서 정확 컷을 받던 keeper 다. 이력이 방에 다 들어가던 keeper(kidsnote-slack, geek-scout, critic)는 배포 전에도 0.95 였다. 배포 후 pr-updater 의 "0.99" 는 이력 전체(≈3.5M 토큰)를 매 턴 그대로 보낸 결과라 의미가 없다(#36860). analyst·goo-yang-bong 의 배포 후 0.04~0.06 은 거절 뒤 절반 내기가 매 턴 다른 위치에서 시작하기 때문이다(같은 이슈).

턴 3636→3637 의 lane-smith 스냅샷 머리를 보면 무엇이 흔들렸는지 보인다. 앞 턴은 `user 191B(wake), assistant 1656, tool 1067, assistant 4002, tool 963, assistant 5084, …`, 뒤 턴은 `user 302B([context window]), assistant 5084, tool 1087, …`. 다음 턴은 다시 두 메시지 앞으로, 그 다음은 wake 까지 돌아갔다.

### 공백과 첫 라운드 미스 (2일 전체)

| family | 직전 요청과의 공백 | n | 미스 중앙값 | 전량 미스 |
|---|---|---:|---:|---:|
| ollama_cloud | 0~60초 | 200 | 76.9% | 9.0% |
| ollama_cloud | 1~5분 | 284 | 73.2% | 13.0% |
| ollama_cloud | 5~15분 | 253 | 66.2% | 22.1% |
| ollama_cloud | 15~60분 | 158 | 95.0% | 53.2% |
| ollama_cloud | 1시간+ | 40 | 97.0% | 80.0% |
| glm-coding | 0~60초 | 46 | 82.8% | 17.4% |
| glm-coding | 1~5분 | 172 | 85.7% | 25.6% |
| glm-coding | 5~15분 | 228 | 87.4% | 46.9% |
| glm-coding | 15~60분 | 212 | 100% | 58.5% |
| glm-coding | 1시간+ | 90 | 98.1% | 56.7% |

중앙값 열은 배포 전 흔들림이 섞여 높다. 전량 미스 열의 기울기가 공급자 TTL 이다. deepseek(ollama cloud)는 15분을 넘기면 반, 1시간을 넘기면 대부분 잃는다. glm 은 5분부터 잃기 시작한다.

### 배포 후 deepseek 첫 라운드: 무엇이 남는가

| 공백 | 툴 배열 | n | 미스 중앙값 | 전량 미스 |
|---|---|---:|---:|---:|
| 15분 이내 | 직전 턴과 같음 | 59 | 21.4% | 3 |
| 15분 이내 | 달라짐 | 12 | 82.6% | 2 |
| 15분 이내 | 알 수 없음 | 40 | 33.6% | 3 |
| 15분 이상 | 같음 | 9 | 96.1% | 5 |
| 15분 이상 | 달라짐 | 1 | 69.4% | 0 |
| 15분 이상 | 알 수 없음 | 10 | 97.0% | 7 |

("알 수 없음" 은 앞 턴의 record 에 tool_surface_ref 가 없던 경우.)

### 툴 배열은 언제, 어떻게 달라지나 (배포 후 109쌍)

| 모양 | 쌍 |
|---|---:|
| 완전히 같음 | 102 |
| 뒤에 붙기만 함 (턴 안의 로드) | 2 |
| 빠짐 + 순서 바뀜 + `keeper_tool_search` 스키마 바뀜 | 2 |
| 빠짐 + `keeper_tool_search` 스키마 바뀜 | 2 |
| `keeper_tool_search` 스키마만 바뀜 | 1 |

`keeper_tool_search` 의 description 은 실리지 않은 도구 이름을 나열한다(`lib/keeper/keeper_identity_tool_search.ml:118`, `description_of`). carry 가 바뀌면 이 도구의 스키마 바이트가 바뀐다. lane-smith 의 배열에서 이 도구는 58개 중 45번째다. 그 뒤의 13개 스키마와 모든 메시지가 다시 prefill 된다. 턴 안에서 로드된 도구는 배열 끝에 붙고(`Agent_core.Agent.extend_tools`), 다음 턴에는 `entries` 순서의 제자리로 옮겨진다(`already_used_from_history` 의 주석). 그 이동도 접두사를 깬다.

### 응답 시작까지 (TTFRC) 와 캐시되지 않은 토큰

| family | 미캐시 토큰 | n | TTFRC 중앙값 | p90 |
|---|---|---:|---:|---:|
| ollama_cloud | 0~2k | 199 | 2.7초 | 4.9초 |
| ollama_cloud | 8~20k | 70 | 3.7초 | 8.5초 |
| ollama_cloud | 50k+ | 135 | 6.4초 | 18.9초 |
| glm-coding | 0~2k | 275 | 6.7초 | 8.6초 |
| glm-coding | 50k+ | 109 | 8.7초 | 30.0초 |

100k 토큰의 prefill 은 deepseek 에서 약 4초, glm 에서 약 2초다. 요청 전체 지연 중앙값은 14.3초(deepseek)·34.8초(glm)라 생성이 지연을 지배한다. 캐시는 비용에 크게, 지연에 조금 작용한다.

### 턴이 끝난 사유 (execution receipts, selected_model 기준, 2일)

| 모델 | receipts | success | 그 다음 |
|---|---:|---:|---|
| claude-sonnet-5 | 1,731 | 1,714 | — |
| glm-5.3-flash | 946 | 428 | api_error_rate_limited 331, api_error_network 23 |
| deepseek-v4.1-flash:cloud | 849 | 475 | repeated_reasoning_cycle 230, sse:repeating_generation 25 |
| k3 | 150 | 0 | api_error_invalid_request 136 (토큰 한도 86, 온도 50) |

### 새 빌드 805a61bd0e (2026-09-16 16:54:39Z 시작) 이후 21분

위 표는 1c5645873e 기준이다. 그 뒤 805a61bd0e(#36854 조립 순서, #36782 부트스트랩 뷰 보존 포함)가 떴다. 17:16Z 까지 21분치는 표본이 작아 표로 만들지 않고 그대로 적는다.

- `/next-request` 가 v3 스키마로 `assembly` 를 낸다. pr-updater deepseek 은 ledger 에서 seed 를 읽어 22/7,929 atom·≈48k 토큰을 실을 예정이고, lane-smith 도 ledger 에서 20/5,083 atom·≈69k 토큰이다.
- glm 머리 keeper 는 아직 옛 완료 record 에서 seed 를 읽는다: jazz-developer 312/3,626 atom·≈784k 토큰, goo-yang-bong 118/7,353 atom·≈303k 토큰. marks 가 선언되기 전의 record 라 앞선이 넓다. 세어진 응답이 한 번 오면 low-water 로 비워지므로 재시작마다 pair 당 큰 요청 하나가 든다.
- kimi 후보는 여전히 이력 전체를 받는다: pr-updater 1건, 7,927/7,927 atom, ≈3.12M 토큰 (#36860).
- receipts 74건: claude-sonnet-5 55(성공 54), deepseek 10(repeated_reasoning_cycle 6, 성공 2, #36861), glm 7(429 가 6, 성공 1, #36862), k3 1(invalid_request).

### 새 빌드 eee8f6aee8 (2026-09-16 17:21:25Z 시작, #36857 포함) 이후 25분

#36857 은 냉시동 seed 를 (keeper, 런타임) 쌍의 완료 record 가 아니라 이력(trace)의 마지막 Agent Core 완료 record 에서 읽는다. 그래서 레인이 다음 후보로 넘어가도 이력 전체를 보내지 않는다. 25분치(17:21~17:46Z):

| keeper | 요청 레인 | atom | 입력 토큰 | 끝 |
|---|---|---:|---:|---|
| pr-updater | deepseek | 20/7,930 | ≈33k | 거절 |
| pr-updater | glm | 22~28/7,93x | ≈34k~37k | 429 ×3 |
| analyst | deepseek | 32/6,368 | 64,543 (센 값) | 완료 |
| won-chik | deepseek | 5/5 | 27,548 (센 값) | 완료 |
| lane-smith | glm | 184/5,084 | ≈109k | 429 |
| polisher | glm | 65/7,214 | ≈118k | 거절 |
| lane-smith | **kimi** | 8/5,093 | 110,546 → 27,757 (센 값) | 완료 |

- kimi 걸음이 확인됐다. lane-smith 턴 3794 는 kimi 에게 8 atom 을 보냈고 아홉 라운드 뒤 완료했다. 고치기 전 pr-updater 의 마지막 kimi 요청은 7,927/7,927 atom·≈3.12M 토큰이었다. #36860 은 닫았다.
- 그 턴 안에서 marks 가 처음 실제로 움직이는 것이 보였다: 라운드 입력이 110,546 → 96k~101k 로 이어지다 101,176(고수위 100k 초과) 다음 라운드에 27,757 로 떨어졌다. Kimi 도 캐시를 읽는다(첫 라운드 110,546 중 93,440).
- glm 429 와 deepseek 반복 생성은 그대로다(receipts: glm 3/3 429, deepseek 2 완료·1 반복).

## 기전

- 요청은 system prompt → tools → `[context window]` → 이력 → wake → `[system context]` 순으로 실린다(#36854 의 assembly). 공급자 캐시는 이 바이트열의 접두사에 붙는다. 앞에서 한 바이트가 달라지면 그 뒤는 전부 다시 계산된다.
- 배포 전 컷: `Runtime_model_input_tail_window.project_target` 는 방이 허락하면 60 atom 배수에서 자르고, 아니면 정확히 자른다. 방이 60 atom 보다 작으면 늘 정확 컷이고, 방은 pinned 블록 크기와 밀도에 따라 턴마다 달라서 컷이 흔들렸다.
- 배포 후 앞선: `Keeper_carried_front` 는 pair 의 ledger 에서, 없으면 그 런타임의 최근 완료 record 에서 읽고, 새 atom 쪽으로만 움직인다. 그래서 접두사가 선다. 완료 record 가 없는 런타임(kimi)은 이력 전체다.
- marks: 100k/70k 가 라이브의 각 바인딩 표에 선언돼 있다(`runtime.toml`, `context-high-water-tokens` / `context-low-water-tokens`). 비우기는 세어진 응답 뒤에만 일어난다. 턴당 입력 증가 중앙값이 6k 토큰이니 30k 의 간격은 다섯 턴에 한 번 앞선을 옮긴다. 옮길 때마다 첫 라운드는 전량 미스다.

## 공급자 문서 대조 (2026-09-16 확인)

| 공급자 | 문서 | 캐시 | usage 필드 | 조건·수명 | 확신 |
|---|---|---|---|---|---|
| DeepSeek | [api-docs.deepseek.com/guides/kv_cache](https://api-docs.deepseek.com/guides/kv_cache) | 자동 | `prompt_cache_hit_tokens`, `prompt_cache_miss_tokens` | 접두사 단위가 완전히 같을 때. 수 시간~수 일 뒤 지움 | High |
| Ollama cloud (deepseek-v4.1-flash) | [docs.ollama.com/api/openai-compatibility](https://docs.ollama.com/api/openai-compatibility), [ollama.com/library/deepseek-v4.1-flash](https://ollama.com/library/deepseek-v4.1-flash) | API 문서는 침묵. 모델 페이지는 cached 입력 $0.003/M 를 적음 | 원장에는 읽기가 온다 (80.9%) | 실측으로만 안다 | Medium |
| Z.ai GLM | [docs.z.ai/guides/capabilities/cache](https://docs.z.ai/guides/capabilities/cache) | 자동("implicit") | `usage.prompt_tokens_details.cached_tokens` | "reasonable time limits". 툴 언급 없음 | High |
| Moonshot Kimi | [forum.moonshot.ai/t/216](https://forum.moonshot.ai/t/cached-tokens-drop-when-tool-has-interleaved-thinking/216) (직원 답변) | 자동 | `cached_tokens` | 바이트 단위로 같아야 함(reasoning_content, 툴 JSON 공백·순서 포함). `prompt_cache_key` 로 같은 클러스터에 붙임 | Medium (포럼) |

이전 지식과의 차이: RFC-0382 §3.2(08-15)는 ollama_cloud deepseek 의 캐시 히트를 0% 로 측정했다. 지금은 80.9% 다. `keeper_config.ml:284` 의 "58% 요청이 캐시 없는 모델" 은 그때의 사실이고 지금은 아니다. carry window(300 호출)를 정한 저울이 바뀌었다.

## 순서

**P0 — fleet 이 턴을 끝내게 한다.** #36860(kimi 후보의 이력 전체)은 #36857 이 고쳤고 eee8f6aee8 에서 확인했다. 남은 것은 #36861(deepseek 반복 생성)과 #36862(glm 429)다. 캐시 수치는 실패한 요청도 다 세므로, 이 셋이 있는 한 어떤 캐시 개선도 측정할 수 없다.

**P1 — marks 값.** 지금 100k/70k. 비우기 간격 30k ÷ 턴당 6k = 다섯 턴마다 앞선 이동 = 첫 라운드 다섯 번 중 한 번 전량 미스. deepseek 는 1M 컨텍스트에 cached 입력이 싸므로 간격을 넓힐 여지가 있다(예: 200k/120k 면 열세 턴). glm 은 캐시가 분 단위로 죽어 큰 창이 매 턴 전액 과금이니 지금 값을 두거나 줄인다. 값은 사용자가 정한다. 검증: 배포 후 첫 라운드 전량 미스 비율(지금 deepseek 15.3%).

**P2 — 툴 배열.** 두 가지 작은 변경. (a) `keeper_tool_search` 의 description 에서 이름 목록을 뺀다. 목록은 호출 결과로 준다. 배포 후 툴 변화 7쌍 중 5쌍이 이것이다. (b) carry 를 다음 턴에 `entries` 순서로 옮기지 않고, 로드된 순서대로 뒤에 둔다. 로드 뒤 턴 경계에서 접두사가 살아남는다. 빠지는 도구는 어차피 그 자리부터 깨지므로 순서 규칙이 더 손해를 보지 않는다. 기대: deepseek 첫 라운드 전량 미스 15% 중 툴 몫(약 1/4)이 준다. 검증: `tool_list_changes_after_deploy.identical` 비율과 첫 라운드 전량 미스. RFC 없이 갈 수 있는 크기지만 (b) 는 `already_used_from_history` 주석의 근거("떠난 자리로 돌아온다")를 뒤집으므로 PR 본문에 그 근거를 적는다.

**P3 — 꼬리.** 15분 이내·툴 동일 첫 라운드의 21% 미스는 `[system context]` 다. memory recall 을 줄이는 일(#36687)이 곧 이 몫이다. 접두사 안정과 무관하다.

**P4 — 공백.** 15분 넘게 쉰 keeper 는 deepseek 캐시를 절반 잃는다. 정책이 아니라 사실로 둔다. 예약 간격을 정할 때 참고한다.

## 하지 않는 것

- 캐시 히트율로 게이트·차단·재시도를 만들지 않는다. 관측치다.
- 바이트→토큰 환산 상수를 넣지 않는다. 표의 토큰은 공급자가 센 값이다.
- 공급자 이름 문자열로 분기하지 않는다.
- 이 문서로 코드를 바꾸지 않는다. P2 는 별도 PR, P1 은 사용자 결정.
