# Keeper 턴 경유 WebSearch 전/후 실측 (Iteration 5)

측정일: 2026-08-15 18:07–18:08 UTC (2026-08-16 03:07–03:08 KST)
대상 keeper: `sangsu` (GLM-5-Turbo 런타임, active)
자극: `masc_broadcast` @sangsu mention — "WebSearch 도구로 \"OCaml 5.5 effect handlers tutorial\"을 includeContent를 켜고 검색"
서버: main HEAD `4f3cf7ae7d` (RFC-0381 스택 전체 반영), `OLLAMA_API_KEY` 프로세스 env 상속 확인.

## "전" 표본 — 옛 바이너리 (2026-08-15 16:17 UTC 이전 로그)

`system_log_2026-08-15.jsonl`에서 `tool_call tool=WebSearch`, includeContent=true, outcome=ok:

- n=33
- out_len: min 348 / p25 20,206 / median 29,433 / p75 36,325 / max 49,807 / mean 28,092

전부 keeper `sangsu`. 이 구간의 코드는 본문 이중 적재(`results[].page_content` + `content_text`)를
포함하고, 절단·오프로드가 없다.

### "전"의 실패 모드 (로그 원문)

검색 4연발(각 includeContent=true) 직후의 턴:

```
Keeper request failed: Hook model_input_projection failed at turn:parse:
newest conversation atom does not fit the model input budget:
available_bytes=135852 newest_atom_bytes=148330
```

148,330바이트 대화 원자 — 검색 결과가 입력 예산을 초과해 턴 자체가 죽었다.

## "후" 실측 — 새 바이너리 (2026-08-15 18:08 UTC)

로그 타임라인 (`system_log_2026-08-15.jsonl`):

```
18:08:02Z keeper:sangsu tool_call tool=WebSearch params=[query,includeContent,limit]
          input_shape=[includeContent=bool,limit=int,query=string:34] outcome=ok out_len=348
18:08:10Z keeper:sangsu tool_call tool=keeper_artifact_read params=[sha256,offset,max_bytes]
          input_shape=[max_bytes=int,offset=int,sha256=string:64] outcome=ok out_len=65536
```

같은 초(18:07:59–18:08:02Z)에 생성된 오프로드 아티팩트:

```
.masc/artifacts/web-fetch/2dd3ef61cfed54ed66db0efb5a11848d3a19049bb94c60a5cfd433b2dbc58abd.md  36,909 B
.masc/artifacts/web-fetch/54a9a7b44b366da78257aaf1d44e8f5dcd3d9d90cfd7ee650b1c79989991323d.md  14,309 B
.masc/artifacts/web-fetch/f2c0826c9d19c36668d1da11283fce83cfaedb0741c7479db82e903342cd45a9.md  28,975 B
                                                                                    합계  80,193 B
```

첫 파일 head는 "Playing with OCaml Effects" (lewinb.net) — 검색 주제와 일치하는 실제 웹 본문.

같은 시각 SearXNG 직접 프로브는 0건×3 (r7) — 본문 3건은 Ollama 폴백 경로의 산출이다.
0건 응답이 `Parse "no results"`로 기록되고 다음 provider로 넘어가는 체인 순회는
`lib/tool_misc_web_search.ml`의 `search_impl` 판독으로 교차 확인.

## 비교

| 축 | 전 | 후 |
|---|---|---|
| 도구 응답이 컨텍스트에 강제 적재하는 크기 | median 29,433자 (max 49,807) | **348자** |
| 본문의 위치 | payload 안 (이중 적재) | 디스크 (`artifacts/web-fetch/<sha256>.md`) |
| keeper의 본문 접근 | 선택 불가, 전량 수신 | `keeper_artifact_read(sha256, offset, max_bytes)` 페이지 단위 선택 |
| 4연발 검색 시 | 148,330 B 원자 → 턴 사망 (실측) | ~1,400자 |
| 강제 적재 감소율 (중앙값 기준) | — | **98.8%** |

주의: 후속 `keeper_artifact_read`(65,536 B)는 keeper의 선택적 재적재로, 강제 적재가 아니다.
이 선택권 자체가 구조 변화의 내용이다.

각주: 해당 턴은 18:08:28Z `keeper cycle OK runtime_lane=runtime tokens=98523 mode=tool_use
stop=completed`로 완주했다. keeper의 채팅 응답 발화는 관측되지 않았는데, 직후(18:25Z) 운영
supervisor가 서버를 교체 재기동해 후속 턴이 끊겼다. 측정 대상(도구 왕복·오프로드·선택 재적재)은
전부 완주 이후가 아니라 완주 이내의 사건이므로 수치에 영향이 없다.
