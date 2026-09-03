# Skill activation evidence record

`2026-09-04-skill-activation-research-r1.md` 의 근거. 확인 시각은 전부
2026-09-04 KST, 라이브 base-path `/Users/dancer/me`, 서버 PID 81077
(01:08:06 KST 기동, port 8935).

## 실측 (masc 라이브)

| Evidence | Timestamp | Confidence | Delta |
|---|---|---|---|
| `GET /api/v1/skills` (admin.token). `state`, `sources`, `skills` 길이와 각 항목 JSON 바이트를 셈 | 01:2x | High | ready / 소스 4 / 스킬 10. 스냅샷 전체 16,961B, 스킬 항목 합 3,362B |
| 키퍼 11명 `<base>/.masc/keepers/*/last-prompt.json` 의 `assembled` 에서 `skill` 대소문자 무시 카운트 | 01:3x | High | 8명 0건, lane-smith·polisher·sangsu 각 1건. 그 1건은 전부 메모리 행(원문 확인) |
| `.masc/tasks/backlog.json` 800건. 필드 모양 정규식 `"([A-Za-z_]*[Ss]kill[A-Za-z_]*)"\s*:` 로 0건, 문자열 `skill` 은 115건 | 01:3x | High | task 의 skill 선택 필드는 라이브에 존재하지 않음. 115건은 description 산문 |
| `config/tools/masc_add_task.toml:85` `skills` 배열 파라미터 선언, `config/tools/keeper_skill.toml` 의 required 필드 | 01:3x | High | 쓰기 경로는 선언돼 있음. `keeper_skill` 은 identity 3필드 + content_revision 모두 required |
| `.masc/tool_calls/2026-09/03.jsonl` 을 `tool` 필드로 집계 | 01:2x | High | 8,160행 / 82종 / 턴 1,770 / `keeper_skill` 2건 = 0.025% |
| 그 2건의 입력·출력·성공 여부 | 01:2x | High | pr-updater→ci-red-attribution 2,180B, polisher→content_revision 지정 8,359B. 둘 다 success |
| 프롬프트 슬롯 `keeper.current_task.skills` 의 `current`/`effective`/`file_value` (`GET /api/v1/prompts`) | 01:3x | High | 셋 다 동일. "rows selected by this task" 로 시작하는 조건부 fragment |
| `gh issue list --search 'skill in:title'` 20건, 2026-08-24 ~ 09-02 | 01:1x | High | 목록만 |

주: 시각은 분 단위까지만 적는다. 같은 명령을 다시 돌려도 라이브 값은 변한다 —
비교하려면 같은 파일(`tool_calls/2026-09/03.jsonl`)을 고정해서 재야 한다.

## 외부 시스템 (검색 결과 및 공식 문서)

| Evidence | Timestamp | Confidence | Delta |
|---|---|---|---|
| Anthropic Agent Skills 3단 점진 공개, discovery 는 name+description 만 | 01:4x | High (공식 문서 요지) / Medium (토큰 수치) | 스킬당 약 80토큰 중앙값(55~235) 또는 약 100토큰. 두 수치는 2차 출처(뉴스레터·블로그)이며 공식 문서에서 직접 확인하지 못했다 |
| `platform.claude.com` Agent Skills overview / best-practices — description 이 discovery 를 좌우하고 "what + when" 을 담아야 함 | 01:4x | High | 공식 문서 |
| Hermes Agent 공식 문서 `website/docs/user-guide/features/skills.md` | 01:5x | High (인용문) | `skills_list()` 가 Level 0 이고 약 3k 토큰. 슬래시 명령 자동 노출, 한 메시지 최대 5개. 우선순위 project>profile>bundled, 번들>개별, local>external |
| Hermes 학습 루프 (observe→distill→reuse→refine), 유사 패턴 3회 이상 성공 시 SKILL.md 생성 | 01:5x | Medium | 검색 결과 요약 기준. 공식 문서 원문에서 "3+" 표현을 직접 보지 못했다 |
| Codex 스킬 `~/.agents/skills/`, 명시 호출과 description 매칭 자동 선택 병존, 항상-켜진 규칙은 AGENTS.md | 01:4x | Medium | 2차 출처(가이드 글) 다수 일치 |
| OpenClaw 가 Pi SDK(`@earendil-works/pi-agent-core`, `createAgentSession()`)를 하네스로 임베드 | 01:5x | Medium | 검색 결과 기준. 저장소 코드 직접 확인 안 함 |
| Orca 가 Claude Code·Codex·Hermes·Pi·Antigravity 등을 오케스트레이션 | 01:5x | Medium | `github.com/stablyai/orca` 설명 기준 |
| skillfold — YAML 매니페스트 + lockfile 에 exact revision 핀, codex 타깃은 `.agents/skills`, 규칙은 AGENTS.md 마커 블록 | 01:5x | Medium | `github.com/byronxlg/skillfold` 설명 기준. 코드 직접 확인 안 함 |
| Anthropic Tool Search Tool (`defer_loading`) — 도구 정의 토큰 85% 감소, 50+ 도구에서 약 77K→8.7K, 정확도 Opus 4 49%→74% / Opus 4.5 79.5%→88.1%, 검색 도구 오버헤드 약 500토큰 | 01:5x | Medium | 2차 출처 복수 일치. Anthropic 공식 페이지에서 직접 확인하지 못했다 |

## 논문 (arXiv abs/html 페이지 확인)

| Evidence | Timestamp | Confidence | Delta |
|---|---|---|---|
| https://arxiv.org/html/2602.12430v3 Agent Skills survey | 01:4x | Medium | §3.1 점진 공개, §7 Challenge 2 "Skill Selection at Scale", §4.6 인용의 phase transition. 본문은 에이전트가 읽어 옮긴 것이라 절 번호는 재확인 필요 |
| https://arxiv.org/abs/2606.20659 Skill Coverage | 01:5x | High (abstract) | 38.66~45.51% 커버, 강조 후 실패 task 16.0% 회복 — 둘 다 abstract 원문 |
| https://arxiv.org/abs/2605.15215 SkillSmith | 01:5x | High (abstract 정의) / Medium (수치) | 경계 우선 컴파일러-런타임. 57.44% / 42.99% / 2.02배 는 abstract 외 위치일 수 있어 재확인 필요 |
| https://arxiv.org/abs/2603.14805 Knowledge Activation | 01:5x | High (abstract) | AKU. Yahoo 배포 엔지니어 67명, 주당 2.6시간, NPS +35 — abstract 원문 |

## 확인하지 못한 것

- Anthropic 공식 문서에서 "스킬당 토큰 수"를 명시한 문장을 찾지 못했다. 80/100
  토큰은 2차 출처다. 안 A 의 비용 추정은 이 값에 의존하므로, RFC 로 가기 전에
  masc 프롬프트에 실제로 넣어보고 바이트를 재는 편이 낫다.
- Tool Search Tool 수치도 2차 출처다. 방향(줄고 정확해진다)은 여러 출처가
  일치하지만 정확한 값은 Anthropic 공식 발표로 확인이 필요하다.
- Hermes 의 "3회 이상" 임계값은 검색 요약에서 왔다.
- SkillSmith 의 세 수치는 abstract 에 없을 수 있다.
- Skill Coverage 를 masc 원장에 적용할 수 있는지는 판단만 적었고 실제로
  constraint 를 뽑아보지 않았다.

## 정정 (코드 레벨 확인 후)

첫 판(`success` 필드를 `keeper_skill` 하나로만 셌다)의 수치가 틀렸다.

| Evidence | Timestamp | Confidence | Delta |
|---|---|---|---|
| `tool_calls/2026-09/03.jsonl` 을 `keeper_skill` + `keeper_compose*` 두 계열로 다시 집계 | 02:0x | High | 2건이 아니라 13건. 8,236행 / 턴 1,796. 첫 판의 0.025% 는 한 계열만 센 값 |
| 같은 파일의 성공 여부 | 02:0x | High | `keeper_compose_work-intake` 8건 전부 `success=False`. 나머지(mission-snapshot 2, background-snapshot 1, keeper_skill 2)는 전부 성공 |
| 실패 payload 의 키 모양 대조 | 02:1x | High | 실패는 `settled`/`cause`/`effect_disposition`, 성공은 `actions`. 전자는 `keeper_tool_composition_surface.ml:570` `failure_data` 가 Error 분기에서만 내는 모양 |
| `result_bytes` 11,858~12,004 vs 기록된 output 3,557자 + `...(truncated)` | 02:1x | High | 절단은 telemetry 전용(`observability_redact.ml:34`). 키퍼는 온전한 결과를 받았다. 다만 `cause` 가 `settled` 뒤라 저장소로는 원인을 못 읽는다 |
| `lib/keeper/keeper_effective_tool_surface.ml:241` 부근 `selection_reason` | 02:0x | High | `skill_names` 가 있으면 `Keeper_profile`, 없으면 `global_references` 매칭 시 `Catalog_default`. 즉 선언 없이도 조합 도구가 스키마에 들어가는 경로가 있다 |
| `lib/keeper/keeper_types_profile_toml_normalizers.mli:71` `skill_names : string list option` | 02:0x | High | 키퍼 프로필 TOML 필드. 라이브 `config/keepers/*.toml` 에서 이 키를 쓰는 키퍼 0명 |
| `.masc/skills/ci-red-attribution/SKILL.md` 원문 | 02:0x | High | `name` + `description` frontmatter. Anthropic 표준 모양 그대로이고 description 은 "무엇을/언제" 를 담고 있다 |

읽지 못한 것: `keeper_compose_work-intake` 실패의 `cause` 값. 저장소가 그 자리에서
잘린다. raw-traces 에서도 해당 `tool_execution_finished` 행을 특정하지 못했다.
