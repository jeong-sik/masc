/* MASC v2 — Fusion (RFC-0252) deliberation data.
   A keeper calls masc_fusion(request) → out-of-band job: gate → panel(N models,
   parallel) → judge(1 model, Structured.extract) → sink(keeper chat lane + board post).
   judge_synthesis = { consensus, contradictions, partial_coverage, unique_insights,
   blind_spots, resolved_answer, decision }. decision ∈ Answer | Recommend | Insufficient.
   Grounded in the scheduler world (T-3902 compact-lock fix) + the existing roster.
   v1 dashboard meta viewer is the RFC's named gap (§8.2/§14.3) — this surface fills it. */

// runtime.toml [fusion.presets.*] — 단일 trio 프리셋 (config 1:1).
// 패널은 서로 다른 모델 패밀리로 관점 다양성 확보, 심판은 Pro 전용.
const FUSION_PRESETS = {
  trio: { panel: ['deepseek-v4-flash', 'glm-5-turbo', 'minimax-m3'], judge: 'deepseek-v4-pro' },
};

// runtime.toml [fusion] — 활성 심의 정책 (코드 default 아님, config에서 주입).
const FUSION_POLICY = {
  enabled: true,
  default_preset: 'trio',
  max_concurrent_panels: 2,   // Async_agent.all max_fibers 상한
  panel_timeout_s: 300,
  judge_timeout_s: 300,
  web_tools: false,           // 패널/심판에 web_search·web_fetch 주입 여부
  max_tool_calls_per_panel: 0, // 0 = 무제한 (OpenRouter 허용 0..16)
};

// fusion_trigger — 발동 이유 라벨 (적격성 판정엔 쓰이지 않음, board meta·로그용)
// fusion topology (RFC-0283/0284) — judges[] 관측 record의 shape가 위상을 결정:
// 1노드=simple, 2=refine, N개 first+meta=judge_of_judges. 이름을 하드코딩하지 않고
// shape로 렌더하는 게 원칙이지만, 프로토타입은 라벨을 명시해 가독성을 높인다.
const FUSION_TOPOLOGY = {
  simple:          { lbl: 'simple', desc: 'panel → judge → sink' },
  refine:          { lbl: 'refine', desc: 'panel → judge → judge′ 재검토' },
  conditional:     { lbl: 'conditional', desc: 'Insufficient일 때만 refine' },
  judge_of_judges: { lbl: 'judge-of-judges', desc: 'panel → 1차 심판 ×N → meta reconcile' },
};

const FUSION_TRIGGER = {
  explicit:   { lbl: 'masc_fusion 직접 호출', glyph: '◈' },
  low_conf:   { lbl: '낮은 확신', glyph: '◌' },
  high_stakes:{ lbl: '고위험 결정', glyph: '⚑' },
  contested:  { lbl: '논쟁 중인 보드', glyph: '⌗' },
  operator:   { lbl: 'operator 요청', glyph: 'OP' },
  harness:    { lbl: 'eval 하네스', glyph: '⌗' },
};

const PANEL_FAIL = {
  Timeout:          '타임아웃',
  Provider_error:   '프로바이더 오류',
  Empty_response:   '빈 응답',
  Budget_exhausted: '토큰 예산 소진',
};

// decision badge meta
const FUSION_DECISION = {
  Answer:       { lbl: '해결 답안', cls: 'ok',   glyph: '\u2713' },
  Recommend:    { lbl: '권고 (advisory)', cls: 'volt', glyph: '\u25B8' },
  Insufficient: { lbl: '심의 무효 · 부족', cls: 'warn', glyph: '\u26A0' },
};

const DENY_REASON = {
  Disabled:          'fusion 비활성 (enabled=false)',
  Preset_unknown:    '알 수 없는 preset',
  Depth_exceeded:    '재귀 깊이 초과 (Nested)',
  Over_hourly_budget:'시간당 발동 예산 초과',
};

const FUSION_RUNS = [
  // ── 1) DONE · decision=Answer — the hero deliberation ──
  {
    run_id: 'fus-7f3a91', keeper: 'nick0cave', preset: 'trio', trigger: 'high_stakes',
    topology: 'simple',
    params: { temperature: 0.7, top_p: 0.95, top_k: null, max_tokens: 4096 },
    status: 'done', ts: '14:18', age: '12분 전', latency_ms: 41200,
    prompt: 'compact() 호출을 round lock 밖으로 빼는 게 맞나? round.ml 의 lock 재진입(T-3902)을 고치는 세 방향 — (A) unlock 후 compact, (B) lock-free 증분 compact, (C) 더블 체크 락 — 중 p99 회귀 없이 가장 안전한 선택과 그 근거는?',
    panel: [
      { model: 'deepseek-v4-flash', conf: 0.82, usage: { in: 3140, out: 880 },
        answer: '(A) unlock 후 compact 가 정답. lock 보유 중 압축은 라운드 진행을 막아 p99 꼬리를 만든다. compact 를 lock 경계 밖으로 옮기고, 라운드 epoch 를 읽어 stale compact 를 폐기하면 일관성도 보존된다. (B)는 증분 자료구조 재작성 비용이 위험 대비 과하다.' },
      { model: 'minimax-m3', conf: 0.74, usage: { in: 3140, out: 640 },
        answer: '(A) 지지. 단 unlock→compact 사이 TOCTOU 윈도우에서 새 라운드가 들어올 수 있으니, compact 진입 시 round epoch 를 캡처하고 끝에서 재검증해야 한다. epoch 불일치면 compact 결과를 버린다. (C)는 재진입을 못 막고 데드락 표면만 키운다.' },
      { model: 'glm-5-turbo', conf: 0.69, usage: { in: 3140, out: 590 },
        answer: '(A)가 합리적이나 롤백 경로가 빠졌다. compact 가 실패해 부분 상태가 남으면 라운드 큐가 손상될 수 있다 — compact 를 트랜잭션으로 감싸 all-or-nothing 으로 만들거나, shadow 버퍼에 쓰고 atomic swap 해야 한다.' },
    ],
    judge: {
      model: 'deepseek-v4-pro', usage: { in: 2980, out: 1240 },
      consensus: [
        { text: 'compact() 를 round lock 경계 밖으로 이동한다 (방향 A).', models: ['deepseek-v4-flash', 'minimax-m3', 'glm-5-turbo'] },
        { text: '(C) 더블 체크 락은 재진입을 못 막고 데드락 표면만 키우므로 기각.', models: ['deepseek-v4-flash', 'minimax-m3'] },
      ],
      contradictions: [
        { topic: '재진입 일관성 보장 방식', positions: [['deepseek-v4-flash', 'epoch read 만으로 충분'], ['minimax-m3', 'epoch 캡처+끝단 재검증 필수']] },
      ],
      partial_coverage: [
        { topic: 'compact 실패 시 롤백', addressed_by: ['glm-5-turbo'], missing: 'sonnet·deepseek 은 부분 상태 손상 경로를 다루지 않음 — shadow 버퍼 atomic swap 미검토' },
      ],
      unique_insights: [
        { text: 'unlock→compact 사이 TOCTOU 윈도우 — round epoch 캡처+재검증으로 닫는다.', model: 'minimax-m3' },
        { text: 'compact 를 트랜잭션/shadow-swap 으로 감싸 all-or-nothing 보장.', model: 'glm-5-turbo' },
      ],
      blind_spots: [
        '동시 compact 케이스의 테스트 커버리지 — 세 패널 모두 회귀 테스트 설계는 언급하지 않음.',
        'epoch 카운터 오버플로/래핑 처리.',
      ],
      resolved_answer: '## 결론 — 방향 A 채택 (가드 2종 동반)\n\n`compact()` 를 round lock 경계 **밖**으로 옮긴다. 단독 이동은 두 개의 안전성 구멍을 남기므로, 아래 두 가드를 함께 머지하는 것을 전제로 한다.\n\n### 추가 가드\n1. **Epoch 재검증 — TOCTOU 차단.** compact 진입 시 `round.epoch` 를 캡처하고 종료 직전 다시 읽는다. 불일치면 산출물을 폐기해 stale compact 를 막는다.\n2. **Shadow-swap — 롤백 안전.** compact 산출물을 shadow 버퍼에 쓰고 `atomic_swap` 으로 교체한다. 실패 시 부분 상태가 라운드 큐를 손상시키지 않는다.\n\n```ocaml\nlet compact_outside_lock t =\n  let epoch = Round.epoch t.round in\n  let shadow = Compact.run t.store in        (* lock 밖에서 수행 *)\n  if Round.epoch t.round = epoch\n  then Store.atomic_swap t.store shadow      (* 동일 epoch — 반영 *)\n  else Compact.discard shadow                (* 새 라운드 진입 — 폐기 *)\n```\n\n### 기각 근거\n- **(C) 더블 체크 락** — 재진입을 막지 못하고 데드락 표면만 키운다.\n- **(B) lock-free 증분 compact** — 자료구조 재작성 비용이 위험 대비 과하다.\n\n> 머지 게이트: 동시 compact 회귀 테스트(mock clock + 2-fiber 경합)를 필수 가드로 추가하고, epoch 카운터 래핑 처리도 같은 PR 에서 다룬다.',
      decision: 'Answer',
    },
    cost_usd: 0.0412, board_post: 'p-2207',
  },

  // ── 2) RUNNING · panel still streaming, judge pending ──
  {
    run_id: 'fus-8b1c04', keeper: 'sangsu', preset: 'trio', trigger: 'low_conf',
    topology: 'simple',
    params: { temperature: null, top_p: null, top_k: null, max_tokens: null },
    status: 'running', ts: '14:29', age: '방금', latency_ms: null,
    prompt: 'round_test.ml 의 jitter 회귀 가드를 어디에 둬야 하나 — 단위 테스트(결정론 mock clock) vs 통합 테스트(실 Eio clock + 부하)? 둘 다면 어느 쪽을 머지 게이트로?',
    panel: [
      { model: 'deepseek-v4-flash', conf: 0.71, usage: { in: 2010, out: 410 },
        answer: '단위 테스트를 머지 게이트로. mock clock 으로 결정론적이라 CI 플레이크가 없다. 통합 테스트는 nightly 로 돌려 실 부하 회귀를 잡되 게이트엔 안 건다 — 부하 변동으로 false-fail 위험.' },
      { model: 'glm-5-turbo', conf: 0.66, usage: { in: 2010, out: 380 },
        answer: '둘 다 필요. 단위는 로직, 통합은 실제 스케줄러 타이밍. 단, 통합을 게이트에 넣되 p95 임계에 여유 밴드를 둬 플레이크를 흡수.' },
      { model: 'minimax-m3', conf: null, usage: null, status: 'running' },
    ],
    judge: null,
    cost_usd: null, board_post: null,
  },

  // ── 3) DONE · decision=Recommend (advisory) ──
  {
    run_id: 'fus-5d2e77', keeper: 'analyst', preset: 'trio', trigger: 'explicit',
    topology: 'conditional',
    params: { temperature: null, top_p: null, top_k: null, max_tokens: null },
    status: 'done', ts: '13:55', age: '35분 전', latency_ms: 38900,
    prompt: 'search/index 재색인 실패가 반복된다 — 전체 재색인 vs 실패 샤드만 부분 재색인 vs 색인 스키마 마이그레이션 후 재색인. 운영 중단 최소화 기준 권고는?',
    panel: [
      { model: 'deepseek-v4-flash', conf: 0.78, usage: { in: 2760, out: 720 },
        answer: '실패 샤드만 부분 재색인부터. 로그상 실패가 3개 샤드에 집중 — 전체 재색인은 중단 시간이 과하다. 부분 재색인 후에도 재발하면 스키마 드리프트를 의심하고 마이그레이션.' },
      { model: 'minimax-m3', conf: 0.72, usage: { in: 2760, out: 560 },
        answer: '먼저 실패 원인 분류가 우선. 부분 재색인은 원인이 일시적(OOM/타임아웃)일 때만 유효. 스키마 드리프트면 부분 재색인은 같은 실패를 반복한다.' },
      { model: 'glm-5-turbo', conf: 0.64, usage: { in: 2760, out: 480 },
        answer: '부분 재색인 + 카나리. 한 샤드만 재색인해 성공률을 보고 나머지에 확대. 전체 재색인/마이그레이션은 카나리 실패 시에만.' },
    ],
    judge: {
      model: 'deepseek-v4-pro', usage: { in: 2510, out: 940 },
      consensus: [
        { text: '실패 샤드 부분 재색인을 먼저 시도 (전체 재색인은 중단 과다).', models: ['deepseek-v4-flash', 'minimax-m3', 'glm-5-turbo'] },
      ],
      contradictions: [
        { topic: '부분 재색인의 전제', positions: [['deepseek-v4-flash', '바로 부분 재색인'], ['minimax-m3', '원인 분류가 선행되어야']] },
      ],
      partial_coverage: [
        { topic: '실패 원인 진단', addressed_by: ['minimax-m3'], missing: 'sonnet·glm 은 원인 분류 단계를 건너뜀 — 스키마 드리프트면 부분 재색인이 무의미' },
      ],
      unique_insights: [
        { text: '한 샤드 카나리로 성공률 확인 후 확대 — blast radius 최소화.', model: 'glm-5-turbo' },
      ],
      blind_spots: ['재색인 중 신규 쓰기 트래픽의 dual-write/큐잉 전략 미검토.'],
      resolved_answer: '먼저 실패 3개 샤드의 원인을 로그로 분류(OOM·타임아웃·스키마 드리프트)하고, 일시적 원인이면 한 샤드 카나리 부분 재색인 → 성공 시 나머지로 확대. 스키마 드리프트가 확인되면 마이그레이션 후 재색인. 전체 재색인은 카나리가 실패할 때만.',
      decision: 'Recommend',
      recommend: { action: '실패 샤드 1개 카나리 부분 재색인', rationale: '원인 분류 후 blast radius 를 최소화한 점진 확대 — analyst 가 평소대로 수행' },
    },
    cost_usd: 0.0331, board_post: 'p-2188',
  },

  // ── 4) DENIED · gate Over_hourly_budget ──
  {
    run_id: 'fus-9a44b2', keeper: 'drifter', preset: 'trio', trigger: 'low_conf',
    topology: 'simple',
    params: { temperature: null, top_p: null, top_k: null, max_tokens: null },
    status: 'denied', ts: '14:31', age: '방금', latency_ms: null,
    prompt: 'core/runtime fiber 취소 전파가 누락되는 경로가 있나? Switch 수명과 root_sw 하위 fiber 정리 순서를 교차검증.',
    deny: 'Over_hourly_budget',
    deny_detail: '이번 UTC 시간대 발동 20/20 도달 — per_hour_budget cap 이 막았다. 게이트는 심의 가치를 score 로 재판정하지 않고 시간당 cap 만 강제한다(판단=LLM, 억제=구조적 cap). 다음 시간대에 재요청하거나 operator 가 cap 을 조정.',
    panel: null, judge: null, cost_usd: null, board_post: null,
  },

  // ── 5) DONE · decision=Insufficient ──
  {
    run_id: 'fus-3c08de', keeper: 'qa-king', preset: 'trio', trigger: 'contested',
    topology: 'simple',
    params: { temperature: null, top_p: null, top_k: null, max_tokens: null },
    status: 'done', ts: '13:40', age: '50분 전', latency_ms: 35100,
    contested_post: 'p-2201',
    prompt: 'docs/site 배포 파이프라인의 캐시 무효화 버그 — CDN edge 캐시 vs 빌드 산출물 해시 불일치 중 무엇이 root cause 인가?',
    panel: [
      { model: 'deepseek-v4-flash', conf: 0.41, usage: { in: 1980, out: 320 },
        answer: '정보 부족. 제공된 컨텍스트엔 CDN 캐시 헤더도, 빌드 해시 로그도 없다. 둘 다 가능성이 있으나 확정 불가.' },
      { model: 'glm-5-turbo', conf: 0.38, usage: { in: 1980, out: 290 },
        answer: 'edge 캐시 TTL 과 빌드 해시 둘 다 의심되지만, 실제 응답 헤더(Cache-Control, ETag)와 배포 매니페스트 없이는 판단 불가.' },
      { model: 'minimax-m3', conf: 0.44, usage: { in: 1980, out: 350 },
        answer: '해시 불일치 쪽에 약간 무게. 다만 재현 로그가 없어 추정. edge 캐시 purge 로그가 있어야 확정.' },
    ],
    judge: {
      model: 'deepseek-v4-pro', usage: { in: 1740, out: 560 },
      consensus: [
        { text: '제공된 컨텍스트만으로는 root cause 확정 불가 (응답 헤더·배포 매니페스트 부재).', models: ['deepseek-v4-flash', 'glm-5-turbo', 'minimax-m3'] },
      ],
      contradictions: [],
      partial_coverage: [
        { topic: 'root cause 후보', addressed_by: ['minimax-m3'], missing: '재현 로그·purge 로그 없이는 해시 불일치 가설도 미검증' },
      ],
      unique_insights: [],
      blind_spots: ['Cache-Control/ETag 응답 헤더', '배포 매니페스트(빌드 해시)', 'CDN edge purge 로그'],
      resolved_answer: '패널 전원이 컨텍스트 부족을 보고했다 — 심의를 진행할 근거가 없다. 확정 전 다음을 수집할 것: ① 실패 URL 의 Cache-Control/ETag 응답 헤더, ② 배포 매니페스트의 빌드 산출물 해시, ③ CDN edge purge 로그.',
      decision: 'Insufficient',
      missing: ['Cache-Control/ETag 응답 헤더', '배포 매니페스트 빌드 해시', 'CDN edge purge 로그'],
    },
    cost_usd: 0.0098, board_post: 'p-2175',
  },

  // ── 6) DONE · topology=judge_of_judges (RFC-0283/0284) ──
  // 같은 패널 답을 서로 다른 3개 1차 심판(lens·모델 상이)이 독립 종합 → meta가 reconcile.
  // judges[] = 관측 record (사후 실행 사실). run.judge = canonical = meta 심판.
  {
    run_id: 'fus-2e9d50', keeper: 'sangsu', preset: 'trio', trigger: 'high_stakes',
    params: { temperature: 0.4, top_p: 0.9, top_k: 40, max_tokens: 8192 },
    status: 'done', ts: '14:34', age: '4분 전', latency_ms: 58700,
    prompt: 'round.ml 재설계 — (A) epoch 기반 lock-free 라운트 큐 전면 재작성 vs (B) 현행 lock + compact 격리 패치. 장기 유지보수성·p99·회귀 위험을 종합해 어느 쪽을 머지는 게 맞나?',
    panel: [
      { model: 'deepseek-v4-flash', conf: 0.79, usage: { in: 3480, out: 910 },
        answer: '(B) 격리 패치. 이번 분기의 문제는 compact 위치이지 큐 구조가 아니다. 전면 재작성은 검증된 lock 경로를 버리고 새 회귀표면을 연다.' },
      { model: 'glm-5-turbo', conf: 0.71, usage: { in: 3480, out: 760 },
        answer: '(A) 장기적으로 lock-free가 맞다. 현행 lock 재진입 버그가 반복되는 건 구조적 한계 — 패치는 같은 계열의 버그를 또 만든다. 단 이주는 단계적으로.' },
      { model: 'minimax-m3', conf: 0.68, usage: { in: 3480, out: 640 },
        answer: '둘 다 위험. (A)는 검증 비용이 크고 (B)는 기술부채를 남긴다. 실측 데이터(p99 회귀 프로파일) 없이 확정은 이르다.' },
    ],
    judges: [
      { role: 'first', identity: 'skeptic', lens: '회의론자 — 검증 공백·회귀 위험 우선', model: 'deepseek-v4-pro', usage: { in: 3010, out: 980 },
        decision: 'Recommend',
        summary: '전면 재작성(A)은 p99 회귀 데이터 없이 정당화 불가. 검증된 lock 경로를 버리는 비용이 과다 — (B) 격리 패치 후 재측이 안전.' },
      { role: 'first', identity: 'pragmatist', lens: '실용주의 — 유지보수·부채 균형', model: 'glm-5-turbo', usage: { in: 3010, out: 870 },
        decision: 'Recommend',
        summary: 'lock 재진입은 구조적 부채 — 패치는 같은 계열 버그를 재생산한다. (A) 방향이 올바르나 단계적 이주(feature flag + shadow)로 위험 분산.' },
      { role: 'first', identity: 'literalist', lens: '문자주의 — 제공된 근거만 판단', model: 'minimax-m3', usage: { in: 3010, out: 720 },
        decision: 'Insufficient',
        summary: '두 안 모두 정량 근거가 부족 — p99 회귀 프로파일·재작성 공수 추정치 없이는 채택 권고 불가. 벤치마크 먼저.' },
    ],
    judge: {
      model: 'deepseek-v4-pro', role: 'meta', usage: { in: 4120, out: 1510 },
      consensus: [
        { text: '현재 회귀(T-3902)는 compact 격리(B)로 먼저 멈춘다 — 전면 재작성과 묶지 않는다.', models: ['skeptic', 'pragmatist', 'literalist'] },
        { text: 'lock-free(A)는 방향으로는 올바르나 정량 근거(p99 프로파일) 없이 지금 착수하면 안 된다.', models: ['skeptic', 'pragmatist'] },
      ],
      contradictions: [
        { topic: 'A를 장기 로드맵에 넣을지', positions: [['pragmatist', '단계적 이주로 채택'], ['literalist', '근거 부족 — 보류']] },
      ],
      partial_coverage: [
        { topic: '이주 안전망', addressed_by: ['pragmatist'], missing: 'skeptic·literalist는 feature-flag/shadow 롤백 경로를 다루지 않음' },
      ],
      unique_insights: [
        { text: '1차 심판 3인 중 2인이 Recommend, 1인이 Insufficient — meta는 근거 수준 차이를 조건부 결론으로 reconcile.', model: 'meta' },
      ],
      blind_spots: ['전면 재작성 시 데이터 마이그레이션 경로를 세 심판 모두 미검토.'],
      resolved_answer: '## 결론 — (B) compact 격리 패치를 먼저, (A)는 데이터 수집 후 로드맵으로\n\n세 1차 심판이 독립 종합했고(회의론·실용·문자주의 lens), meta가 근거 수준 차이를 reconcile했다.\n\n- **지금**: T-3902는 (B) 격리 패치 + epoch 가드 + shadow-swap으로 해결 — 검증된 lock 경로 유지.\n- **다음**: lock-free(A)는 p99 회귀 프로파일·재작성 공수 추정을 수집한 뒤 feature-flag + shadow 단계적 이주로 재평가.\n\n> literalist가 단독으로 Insufficient를 냈지만, 2인의 Recommend와 검증 공백 지적이 서로 보강되어 meta는 조건부 Answer로 수렴.',
      decision: 'Answer',
    },
    cost_usd: 0.0689, board_post: 'p-2214',
  },

  // ── 7) DONE · topology=judge_of_judges · 비대칭(N≠M) + 1차 심판 1개 실패 ──
  // 패널 3 → 1차 심판 4 (심판 수가 패널 수와 무관 · RFC-0283 §1.1). domain 심판이
  // 타임아웃 → 격리(§2.3): 나머지 3개로 meta가 reconcile. usage = 성공 1차 3 + meta 합산.
  {
    run_id: 'fus-6c71a8', keeper: 'nick0cave', preset: 'trio', trigger: 'contested',
    params: { temperature: 0.5, top_p: 0.92, top_k: null, max_tokens: 8192 },
    status: 'done', ts: '14:41', age: '방금', latency_ms: 47200,
    prompt: 'board p-2150 논쟁 — 승인 큐 SLA를 (A) keeper별 자동 에스컬레이션(15분 무응답 시 operator 호출) vs (B) 현행 수동 폴링 유지. 운영 부하·실수 위험·자율성 훼손을 종합해 어느 쪽?',
    panel: [
      { model: 'deepseek-v4-flash', conf: 0.74, usage: { in: 2980, out: 720 },
        answer: '(A) 자동 에스컬레이션. 무응답 15분은 이미 SLA 위반 — 사람이 폴링으로 잡는 건 비결정적. 단 에스컬레이션 자체가 승인 액션은 아니므로 자율성 훼손 아님.' },
      { model: 'glm-5-turbo', conf: 0.66, usage: { in: 2980, out: 640 },
        answer: '(A)에 가깝지만 임계값 15분은 근거 없음. 큐 길이 기반 적응형이어야. 고정 타이머는 야간 배치에서 오탐 폭증.' },
      { model: 'minimax-m3', conf: 0.58, usage: { in: 2980, out: 560 },
        answer: '판단 보류. 현 승인 큐 무응답 분포 데이터가 없다. (B) 유지하며 1주 계측 먼저.' },
    ],
    // 1차 심판 4개 구성(judges: judge_spec list) — 패널 수(3)와 독립. domain은 실패.
    judges: [
      { role: 'first', identity: 'skeptic', lens: '회의론자 — 자동화 오탐·역효과 우선', model: 'deepseek-v4-pro', usage: { in: 2640, out: 880 },
        decision: 'Recommend',
        summary: '에스컬레이션은 승인이 아닌 알림이므로 자율성 위험은 낮음. 단 고정 15분은 야간 오탐 위험 — glm 지적이 타당. 적응형 임계값 전제하 (A) 권고.' },
      { role: 'first', identity: 'pragmatist', lens: '실용주의 — 운영 부하 절감 우선', model: 'glm-5-turbo', usage: { in: 2640, out: 760 },
        decision: 'Recommend',
        summary: '수동 폴링은 operator 인지 부하의 주 원인. (A)로 부하를 시스템에 이전 — 큐 길이 적응형으로 오탐 억제하면 순이득.' },
      { role: 'first', identity: 'literalist', lens: '문자주의 — 제공 근거만 판단', model: 'minimax-m3', usage: { in: 2640, out: 690 },
        decision: 'Insufficient',
        summary: '무응답 분포·오탐률 데이터 부재. 15분이든 적응형이든 임계값 정당화 근거가 패널·프롬프트 어디에도 없음 — 계측 선행이 맞다.' },
      // 4번째 1차 심판 — 격리되어 meta에서 제외됨
      { role: 'first', identity: 'domain', lens: '도메인 전문가 — SLA 운영 관행', model: 'deepseek-v4-pro', status: 'failed', fail: 'Timeout' },
    ],
    judge: {
      model: 'deepseek-v4-pro', role: 'meta', usage: { in: 3580, out: 1240 }, degraded: false,
      consensus: [
        { text: '에스컬레이션은 알림이지 승인 대리가 아니므로 keeper 자율성 훼손 우려는 약하다.', models: ['skeptic', 'pragmatist'] },
        { text: '고정 15분 임계값은 정당화 근거가 없다 — 채택하더라도 임계값은 분리 결정.', models: ['skeptic', 'pragmatist', 'literalist'] },
      ],
      contradictions: [
        { topic: '지금 (A)를 켤지', positions: [['pragmatist', '적응형 전제로 즉시'], ['literalist', '계측 1주 선행']] },
      ],
      partial_coverage: [
        { topic: '임계값 산정식', addressed_by: ['skeptic'], missing: '적응형 공식(큐 길이→타이머)을 누구도 구체화 못함' },
      ],
      unique_insights: [
        { text: '4개 1차 심판 중 domain이 타임아웃 — meta는 격리하고 3개 종합만으로 reconcile(전원 일치 아님을 명시).', model: 'meta' },
      ],
      blind_spots: ['domain(SLA 운영 관행) lens가 빠져, 업계 표준 에스컬레이션 패턴과의 정합성은 미검토.'],
      resolved_answer: '## 결론 — (A) 자동 에스컬레이션 채택, 단 임계값은 분리 결정 + 계측 병행\n\n1차 심판 4개 중 domain이 타임아웃으로 격리되어, 3개 종합(회의론·실용·문자주의)으로 reconcile했다.\n\n- **합의**: 에스컬레이션은 알림이므로 자율성 훼손 아님. 고정 15분 임계값은 근거 없음.\n- **결정**: (A)를 켜되 임계값은 큐 길이 기반 적응형으로 별도 산정 — 동시에 1주 무응답 분포 계측.\n\n> literalist의 "계측 선행"과 pragmatist의 "즉시 도입"은 임계값을 분리하면 양립한다. domain lens 부재로 업계 표준 정합성은 후속 검토.',
      decision: 'Answer',
    },
    cost_usd: 0.0521, board_post: 'p-2231',
  },
];

Object.assign(window, { FUSION_PRESETS, FUSION_POLICY, FUSION_TOPOLOGY, FUSION_TRIGGER, PANEL_FAIL, FUSION_DECISION, DENY_REASON, FUSION_RUNS });
