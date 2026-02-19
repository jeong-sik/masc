(** Dashboard Keeper/Perpetual Agent JavaScript — extracted from web_dashboard.ml *)

let content = {|    // === Live Agent Rendering (Keepers / Perpetual) ===
    function isNum(x) { return typeof x === 'number' && !isNaN(x); }
    function clamp(n, lo, hi) { return Math.max(lo, Math.min(hi, n)); }
    function fmtSecShort(s) {
      if (!isNum(s) || s <= 0) return 'never';
      if (s < 60) return Math.round(s) + 's';
      if (s < 3600) return Math.round(s / 60) + 'm';
      if (s < 86400) return Math.round(s / 3600) + 'h';
      return Math.round(s / 86400) + 'd';
    }
    function fmtPct(r) { return isNum(r) ? (Math.round(r * 100) + '%') : '-'; }
    function fmtCascade(models) {
      const xs = Array.isArray(models) ? models : [];
      if (xs.length === 0) return '-';
      if (xs.length <= 2) return xs.join(' → ');
      return xs[0] + ' → ' + xs[1] + ' +' + (xs.length - 2);
    }
    function ctxClass(r) {
      if (!isNum(r)) return '';
      if (r >= 0.85) return 'bad';
      if (r >= 0.70) return 'warn';
      return '';
    }

    function sparkSvg(series, opts) {
      const pts = Array.isArray(series) ? series : [];
      if (pts.length < 2) return '';
      const w = (opts && isNum(opts.w)) ? opts.w : 160;
      const h = (opts && isNum(opts.h)) ? opts.h : 28;
      const threshold = (opts && isNum(opts.threshold)) ? opts.threshold : null;
      const ratios = pts.map(p => (p && isNum(p.context_ratio)) ? p.context_ratio : 0);
      const maxSeen = ratios.reduce((m, v) => Math.max(m, v), 0);
      const yMax = Math.max(maxSeen * 1.05, threshold || 0, 0.01);
      const x = (i) => (pts.length <= 1 ? 0 : (w * i / (pts.length - 1)));
      const y = (r) => h - clamp((r / yMax) * h, 0, h);
      const poly = ratios.map((r, i) => `${x(i).toFixed(2)},${y(r).toFixed(2)}`).join(' ');
      const thrLine = (threshold !== null && threshold <= yMax)
        ? `<line x1="0" y1="${y(threshold).toFixed(2)}" x2="${w}" y2="${y(threshold).toFixed(2)}" stroke="rgba(251,191,36,0.55)" stroke-width="1" stroke-dasharray="4 3" />`
        : '';
      const marks = pts.map((p, i) => {
        if (!p) return '';
        const cx = x(i).toFixed(2);
        const cy = y(ratios[i]).toFixed(2);
        const isHandoff = !!p.handoff;
        const isProactive = p.channel === 'proactive';
        const isCompaction = !!p.compacted;
        let out = '';
        if (isCompaction) {
          out += `<rect x="${(Number(cx) - 1.8).toFixed(2)}" y="${(Number(cy) - 1.8).toFixed(2)}" width="3.6" height="3.6" fill="#f97316" rx="0.8" />`;
        }
        if (isProactive) {
          out += `<circle cx="${cx}" cy="${cy}" r="1.9" fill="#4ade80" />`;
        }
        if (isHandoff) {
          out += `<circle cx="${cx}" cy="${cy}" r="2.5" fill="#fbbf24" />`;
        }
        return out;
      }).join('');
      return `
        <svg class="spark-svg" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
          <polyline points="${poly}" fill="none" stroke="rgba(34,211,238,0.9)" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
          ${thrLine}
          ${marks}
        </svg>
      `.trim();
    }

    function etaTurns(series, threshold) {
      const pts = Array.isArray(series) ? series : [];
      if (pts.length < 3) return null;
      if (!isNum(threshold)) return null;
      const last = pts[pts.length - 1] || {};
      const lastR = last.context_ratio;
      if (!isNum(lastR)) return null;
      if (lastR >= threshold) return 0;
      const n = Math.min(10, pts.length);
      const first = pts[pts.length - n] || {};
      const firstR = first.context_ratio;
      if (!isNum(firstR)) return null;
      const slope = (lastR - firstR) / Math.max(1, (n - 1));
      if (!(slope > 0)) return null;
      const eta = Math.ceil((threshold - lastR) / slope);
      if (!isFinite(eta) || eta < 0) return null;
      return Math.min(eta, 9999);
    }
    function stddev(values) {
      const xs = Array.isArray(values) ? values.filter(isNum) : [];
      if (xs.length <= 1) return 0;
      const mean = xs.reduce((a, b) => a + b, 0) / xs.length;
      const variance = xs.reduce((a, v) => a + ((v - mean) * (v - mean)), 0) / xs.length;
      return Math.sqrt(Math.max(variance, 0));
    }
    function handoffRiskMetrics(series, threshold) {
      const pts = Array.isArray(series) ? series : [];
      if (pts.length < 3 || !isNum(threshold) || threshold <= 0) {
        return { score: null, confidence: null, eta: null, slope: null, volatility: null, level: 'unknown' };
      }
      const ratios = pts
        .map(p => (p && isNum(p.context_ratio)) ? Number(p.context_ratio) : null)
        .filter(v => v !== null);
      if (ratios.length < 3) {
        return { score: null, confidence: null, eta: null, slope: null, volatility: null, level: 'unknown' };
      }
      const last = ratios[ratios.length - 1];
      const n = Math.min(12, ratios.length);
      const first = ratios[ratios.length - n];
      const slope = (last - first) / Math.max(1, n - 1);
      const diffs = [];
      for (let i = Math.max(1, ratios.length - n); i < ratios.length; i++) {
        diffs.push(ratios[i] - ratios[i - 1]);
      }
      const volatility = stddev(diffs);
      const eta = etaTurns(pts, threshold);
      const ratioComponent = clamp((last / threshold) * 55, 0, 55);
      const slopeComponent = clamp((Math.max(0, slope) / 0.03) * 20, 0, 20);
      const volatilityComponent = clamp((volatility / 0.02) * 15, 0, 15);
      const etaComponent =
        (eta === 0) ? 10 :
        (isNum(eta) ? clamp(((10 - Math.min(10, eta)) / 10) * 10, 0, 10) : 0);
      const score = Math.round(clamp(ratioComponent + slopeComponent + volatilityComponent + etaComponent, 0, 100));
      const confidence = Math.round(clamp(100 - ((volatility / 0.03) * 100), 15, 99));
      const level = score >= 80 ? 'critical' : score >= 65 ? 'high' : score >= 45 ? 'medium' : 'low';
      return { score, confidence, eta, slope, volatility, level };
    }
    function fmtPct1(v) {
      return isNum(v) ? (Math.round(v * 1000) / 10).toFixed(1) + '%' : '-';
    }
    function topCountsText(items, keyName, emptyText = '-') {
      const xs = Array.isArray(items) ? items : [];
      if (xs.length === 0) return emptyText;
      const parts = xs.map((it) => {
        if (!it) return null;
        const name = it[keyName];
        const count = it.count;
        if (!name) return null;
        return `${name} (${fmtInt(count)})`;
      }).filter(Boolean);
      return parts.length > 0 ? parts.join(', ') : emptyText;
    }
    function topCountName(items, keyName, emptyText = '-') {
      const xs = Array.isArray(items) ? items : [];
      if (xs.length === 0) return emptyText;
      const first = xs[0] || {};
      return first[keyName] || emptyText;
    }
    function generationEquipmentHtml(rows) {
      const xs = Array.isArray(rows) ? rows : [];
      if (xs.length === 0) return `<div class="empty">${escHtml(keeperText('no_generation_data'))}</div>`;
      return `<div class="keeper-equipment-list">` + xs.map((row) => {
        if (!row) return '';
        const gen = isNum(row.generation) ? row.generation : '-';
        const turns = fmtInt(row.turns);
        const handoffs = fmtInt(row.handoffs);
        const compactions = fmtInt(row.compactions);
        const memoryCompactions = fmtInt(row.memory_compactions);
        const memoryTrimmed = fmtInt(row.memory_trimmed);
        const mem = isNum(row.memory_pass_rate) ? fmtPct1(row.memory_pass_rate) : '-';
        const memNotes = fmtInt(row.memory_notes);
        const topModel = ((row.top_model || {}).name) || '-';
        const topTool = ((row.top_tool || {}).name) || '-';
        const tokenText = `${fmtInt(row.input_tokens)} / ${fmtInt(row.output_tokens)}`;
        return `
          <div class="keeper-equipment-row">
            <span class="keeper-equipment-gen">g${gen}</span>
            <span>turns ${turns}</span>
            <span>io ${tokenText}</span>
            <span>handoff ${handoffs}</span>
            <span>compact ${compactions}</span>
            <span>m-compact ${memoryCompactions}</span>
            <span>m-trim ${memoryTrimmed}</span>
            <span>memory ${mem}</span>
            <span>notes ${memNotes}</span>
            <span>model ${escHtml(topModel)}</span>
            <span>tool ${escHtml(topTool)}</span>
          </div>
        `;
      }).join('') + `</div>`;
    }
    function keeperMemoryNotesHtml(notes) {
      const xs = Array.isArray(notes) ? notes : [];
      if (xs.length === 0) return `<div class="empty">${escHtml(keeperText('no_long_term_memory_notes'))}</div>`;
      return `<div class="keeper-memory-list">` + xs.map((row) => {
        if (!row) return '';
        const kind = row.kind || '-';
        const text = row.text || '';
        const pr = isNum(row.priority) ? row.priority : null;
        const ts = isNum(row.ts_unix) ? fmtTs(row.ts_unix) : '-';
        return `
          <div class="keeper-memory-item">
            <div class="keeper-memory-kind">${escHtml(kind)}</div>
            <div class="keeper-memory-text">${escHtml(text)}</div>
            <div class="keeper-memory-meta">priority ${pr === null ? '-' : pr} · ${escHtml(ts)}</div>
          </div>
        `;
      }).join('') + `</div>`;
    }
    function keeperConversationHtml(rows) {
      const xs = Array.isArray(rows) ? rows : [];
      if (xs.length === 0) return `<div class="empty">${escHtml(keeperText('no_conversation_logs'))}</div>`;
      return `<div class="keeper-conversation-list">` + xs.slice(-20).map((row) => {
        if (!row) return '';
        const role = String(row.role || '').trim().toLowerCase();
        const roleClass = role === 'user' ? 'user' : (role === 'assistant' ? 'assistant' : '');
        const roleText = role || keeperText('unknown');
        const text = row.preview || row.content || '';
        const tsUnix = isNum(row.ts_unix)
          ? Number(row.ts_unix)
          : (isNum(row.timestamp) ? Number(row.timestamp) : null);
        const timeText = (tsUnix === null || tsUnix <= 0) ? '-' : `${fmtTs(tsUnix)} · ${timeAgo(tsUnix)}`;
        const mentions = Array.isArray(row.mentions) ? row.mentions : [];
        const isK2k = !!row.k2k;
        const isFragment = !!row.is_fragment;
        const mentionsHtml = mentions.length === 0
          ? ''
          : `<div class="keeper-mentions">${mentions.map((name) => `<span class="keeper-mention-chip">${escHtml(name)}</span>`).join('')}</div>`;
        return `
          <div class="keeper-conversation-item ${isFragment ? 'fragment' : ''}">
            <div class="keeper-conversation-head">
              <span class="keeper-role-chip ${roleClass}">${escHtml(roleText)}</span>
              <span class="keeper-role-chip">${escHtml(timeText)}</span>
              ${isFragment ? '<span class="keeper-role-chip warn">fragment</span>' : ''}
              ${isK2k ? '<span class="keeper-k2k-chip">k2k</span>' : ''}
            </div>
            <div class="keeper-conversation-text">${escHtml(text)}</div>
            ${mentionsHtml}
          </div>
        `;
      }).join('') + `</div>`;
    }
    function keeperK2kHtml(rows) {
      const xs = Array.isArray(rows) ? rows : [];
      if (xs.length === 0) return `<div class="empty">${escHtml(keeperText('no_k2k_logs_recent_window'))}</div>`;
      return `<div class="keeper-k2k-list">` + xs.slice(-20).map((row) => {
        if (!row) return '';
        const keeper = row.keeper || '-';
        const mentioned = row.mentioned || '-';
        const role = row.role || '-';
        const text = row.preview || '';
        const tsUnix = isNum(row.ts_unix)
          ? Number(row.ts_unix)
          : (isNum(row.timestamp) ? Number(row.timestamp) : null);
        const timeText = (tsUnix === null || tsUnix <= 0) ? '-' : `${fmtTs(tsUnix)} · ${timeAgo(tsUnix)}`;
        return `
          <div class="keeper-k2k-item">
            <div class="keeper-k2k-route">${escHtml(keeper)} ${escHtml(keeperText('mentions'))} ${escHtml(mentioned)} (${escHtml(role)}) · ${escHtml(timeText)}</div>
            <div class="keeper-k2k-text">${escHtml(text)}</div>
          </div>
        `;
      }).join('') + `</div>`;
    }
    function shortTraceId(value) {
      const s = String(value == null ? '' : value).trim();
      if (!s) return '-';
      if (s.length <= 28) return s;
      return s.slice(0, 18) + '...' + s.slice(-7);
    }

    function escHtml(s) {
      return String(s == null ? '' : s)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
    }
    function fmtInt(n) {
      return isNum(n) ? Math.round(n).toLocaleString() : '-';
    }
    function fmtUsd(v) {
      return isNum(v) ? ('$' + Number(v).toFixed(4)) : '-';
    }
    function fmtTs(tsUnix) {
      if (!isNum(tsUnix) || tsUnix <= 0) return '-';
      return new Date(tsUnix * 1000).toLocaleString();
    }
    function fmtIso(tsIso) {
      if (!tsIso) return '-';
      const d = new Date(tsIso);
      if (!isFinite(d.getTime())) return String(tsIso);
      return d.toLocaleString();
    }
    function shortText(s, maxLen = 60) {
      const v = String(s == null ? '' : s).trim();
      if (!v) return '-';
      if (v.length <= maxLen) return v;
      return v.slice(0, Math.max(0, maxLen - 1)) + '…';
    }
    function keeperColorByRatio(ratio) {
      if (!isNum(ratio)) return '#22d3ee';
      if (ratio >= 0.85) return '#f87171';
      if (ratio >= 0.70) return '#fbbf24';
      return '#22d3ee';
    }
    function normalizeModelName(s) {
      if (!s) return '';
      let v = String(s).trim();
      const idx = v.indexOf(':');
      if (idx > 0) {
        const prefix = v.slice(0, idx).toLowerCase();
        if (['ollama', 'glm', 'claude', 'gemini', 'openrouter'].includes(prefix)) {
          v = v.slice(idx + 1);
        }
      }
      if (v.endsWith(':latest')) v = v.slice(0, -7);
      return v;
    }
    const keeperLangText = {
      en: {
        metric_glossary: 'Metric Glossary',
        field_dictionary_detailed: 'Field Dictionary (Detailed)',
        field_search_placeholder: 'Search by field key, label, formula...',
        filtered_count: '{shown} / {total} shown',
        clear: 'Clear',
        no_match: 'No fields match the current search',
        kpi_detail: 'KPI Detail',
        selected_field: 'Selected Field',
        current_value: 'Current Value',
        numerator: 'Numerator',
        denominator: 'Denominator',
        trend_24h: '24h Trend',
        no_24h_data: 'No 24h data',
        unknown: 'unknown',
        mentions: 'mentions',
        no_generation_data: 'No generation data',
        no_long_term_memory_notes: 'No long-term memory notes yet',
        no_conversation_logs: 'No conversation logs yet',
        no_k2k_logs_recent_window: 'No K2K relay logs in recent window',
        no_series: 'no series',
        not_enough_points_for_compare: 'not enough points for compare',
        no_handoff_compaction_events: 'No handoff/compaction events yet',
        no_handoff_events_for_selected_filters: 'No handoff events for selected filters',
        event_handoff_to_next_generation: 'handoff to next generation (gen {gen})',
        event_context_compaction_at: 'context compaction at {ratio}%',
        event_memory_compaction_dropped: 'memory compaction dropped {dropped}/{before} notes',
        no_keeper_selected: 'No keeper selected',
        keeper_data_not_available: 'Keeper data is not available yet. Wait for next refresh.',
        select_keeper: 'Select keeper',
        compare_context_ratio: 'Compare (Context Ratio)',
        compare_select_other: 'Select another keeper from the compare dropdown.',
        handoff_timeline: 'Handoff Timeline',
        chart_context_ratio_threshold: 'Context Ratio (with handoff threshold)',
        chart_context_tokens: 'Context Tokens',
        chart_turn_io_tokens: 'Turn I/O Tokens (input vs output)',
        chart_memory_recall_score: 'Memory Recall Score',
        chart_drift_applied: 'Drift Applied (0/1)',
        chart_intervention_vs_drift: 'Intervention vs Drift (0/1)',
        chart_compaction_timeline: 'Compaction Timeline (Events + Saved Tokens)',
        chart_24h_trend: '24h Trend (Hourly)',
        chart_lifecycle: 'Lifecycle',
        chart_metric_formula: 'Metric Formula',
        chart_work_equipment: 'Work & Equipment',
        chart_memory_bank: 'Long-term Memory Bank',
        chart_recent_conversation: 'Recent Conversation (User/Assistant)',
        chart_k2k_relay_trail: 'K2K Relay Trail',
        chart_recent_lifecycle_events: 'Recent Lifecycle Events',
        trend_latest_delta: 'latest {latest} · Δ {delta}',
        all_generations: 'All generations',
        all_models: 'All models',
        from_gen: 'From Gen',
        model: 'Model',
        events: 'events',
        filtered: 'filtered',
        latest: 'latest',
        last_model: 'last model',
        threshold: 'threshold',
        window: 'window',
        delta: 'delta',
        risk: 'risk',
        definition: 'Definition',
        formula: 'Formula',
        source: 'Source',
        interpret: 'Interpret',
      },
      ko: {
        metric_glossary: '메트릭 요약',
        field_dictionary_detailed: '필드 사전 (상세)',
        field_search_placeholder: '필드 키/라벨/공식으로 검색...',
        filtered_count: '{shown} / {total} 표시',
        clear: '초기화',
        no_match: '현재 검색 조건과 일치하는 필드가 없습니다',
        kpi_detail: 'KPI 상세',
        selected_field: '선택 필드',
        current_value: '현재 값',
        numerator: '분자',
        denominator: '분모',
        trend_24h: '최근 24시간 추이',
        no_24h_data: '24시간 데이터 없음',
        unknown: '알수없음',
        mentions: '언급',
        no_generation_data: '세대 데이터가 없습니다',
        no_long_term_memory_notes: '장기 메모리 노트가 아직 없습니다',
        no_conversation_logs: '대화 로그가 아직 없습니다',
        no_k2k_logs_recent_window: '최근 윈도우에 K2K 릴레이 로그가 없습니다',
        no_series: '시계열 데이터 없음',
        not_enough_points_for_compare: '비교용 포인트가 부족합니다',
        no_handoff_compaction_events: '핸드오프/컴팩션 이벤트가 아직 없습니다',
        no_handoff_events_for_selected_filters: '선택한 필터에 해당하는 핸드오프 이벤트가 없습니다',
        event_handoff_to_next_generation: '다음 세대로 핸드오프 (gen {gen})',
        event_context_compaction_at: '컨텍스트 컴팩션 @ {ratio}%',
        event_memory_compaction_dropped: '메모리 컴팩션으로 노트 {dropped}/{before} 제거',
        no_keeper_selected: '선택된 키퍼가 없습니다',
        keeper_data_not_available: '키퍼 데이터가 아직 없습니다. 다음 갱신을 기다려주세요.',
        select_keeper: '키퍼 선택',
        compare_context_ratio: '비교 (컨텍스트 비율)',
        compare_select_other: '비교 드롭다운에서 다른 키퍼를 선택하세요.',
        handoff_timeline: '핸드오프 타임라인',
        chart_context_ratio_threshold: '컨텍스트 비율 (핸드오프 임계치 포함)',
        chart_context_tokens: '컨텍스트 토큰',
        chart_turn_io_tokens: '턴 I/O 토큰 (입력 vs 출력)',
        chart_memory_recall_score: '메모리 회상 점수',
        chart_drift_applied: '드리프트 적용 (0/1)',
        chart_intervention_vs_drift: '개입 vs 드리프트 (0/1)',
        chart_compaction_timeline: '컴팩션 타임라인 (이벤트 + 절감 토큰)',
        chart_24h_trend: '24시간 추이 (시간별)',
        chart_lifecycle: '라이프사이클',
        chart_metric_formula: '메트릭 계산식',
        chart_work_equipment: '작업 & 장비',
        chart_memory_bank: '장기 메모리 뱅크',
        chart_recent_conversation: '최근 대화 (User/Assistant)',
        chart_k2k_relay_trail: 'K2K 릴레이 트레일',
        chart_recent_lifecycle_events: '최근 라이프사이클 이벤트',
        trend_latest_delta: '최근 {latest} · Δ {delta}',
        all_generations: '모든 세대',
        all_models: '모든 모델',
        from_gen: '출발 세대',
        model: '모델',
        events: '이벤트',
        filtered: '필터 적용',
        latest: '최신',
        last_model: '마지막 모델',
        threshold: '임계치',
        window: '윈도우',
        delta: '차이',
        risk: '위험도',
        definition: '정의',
        formula: '계산식',
        source: '데이터 소스',
        interpret: '해석',
      },
    };
    function keeperText(key) {
      const lang =
        keeperFieldLang === 'ko'
          ? keeperLangText.ko
          : keeperLangText.en;
      const fallback = keeperLangText.en;
      const v = lang ? lang[key] : null;
      if (typeof v === 'string' && v.trim() !== '') return v;
      const vf = fallback ? fallback[key] : null;
      if (typeof vf === 'string' && vf.trim() !== '') return vf;
      return key;
    }
    function keeperFormat(key, vars = {}) {
      let out = keeperText(key);
      Object.entries(vars).forEach(([k, v]) => {
        out = out.replaceAll(`{${k}}`, String(v == null ? '' : v));
      });
      return out;
    }
    function normalizeKeeperKpiKey(value) {
      const v = String(value == null ? '' : value).trim();
      if (!v) return '';
      return /^[a-z0-9_]+$/.test(v) ? v : '';
    }
    const keeperMetaLabelKo = {
      events: '이벤트',
      filtered: '필터 적용',
      latest: '최신',
      'last model': '마지막 모델',
      threshold: '임계치',
      window: '윈도우',
      delta: '차이',
      risk: '위험도',
      current: '현재',
      max: '최대',
      source: '소스',
      'input total': '입력 합계',
      'output total': '출력 합계',
      'last turn': '마지막 턴',
      'model fallback': '모델 폴백',
      'memory pass': '메모리 통과',
      weather: '날씨 회상',
      work: '작업',
      'tool calls': '도구 호출',
      primary: '주 모델',
      avg: '평균',
      pass: '통과',
      fail: '실패',
      correct: '정정',
      'window drift': '윈도우 드리프트',
      rate: '비율',
      enabled: '활성화',
      gap: '간격',
      'top reason': '주요 이유',
      reasons: '이유 분포',
      'proactive points': '사전개입 포인트',
      'intervention share': '개입 비중',
      'per-turn': '턴당',
      'drift points': '드리프트 포인트',
      saved: '절감',
      'avg/event': '이벤트당 평균',
      'top trigger': '주요 트리거',
      spread: '분포',
      profile: '프로필',
      gate: '게이트',
      buckets: '버킷',
      points: '포인트',
      coverage: '커버리지',
      range: '범위',
      state: '상태',
      'warn/bad': '경고/위험',
      trace: '트레이스',
      keepalive: '하트비트',
      born: '생성',
      updated: '갱신',
      age: '가동 시간',
      'last handoff': '마지막 핸드오프',
      'last compaction': '마지막 컴팩션',
      proactive: '사전개입',
      'last proactive': '최근 사전개입',
      'proactive reason': '개입 이유',
      'proactive preview': '개입 프리뷰',
      drift: '드리프트',
      'drift total': '드리프트 누적',
      'last drift reason': '최근 드리프트 이유',
      'skill route': '스킬 라우트',
      'skill reason': '스킬 이유',
      'proactive template fallback': '사전개입 템플릿 폴백',
      'proactive similarity': '사전개입 유사도',
      'last handoff model': '최근 핸드오프 모델',
      'last compaction saved': '최근 컴팩션 절감',
      'compaction efficiency': '컴팩션 효율',
      'compaction gate': '컴팩션 게이트',
      'top compaction trigger': '주요 컴팩션 트리거',
      'trigger spread': '트리거 분포',
      'risk confidence': '위험도 신뢰도',
      'window interactions': '윈도우 상호작용',
      'template fallback': '템플릿 폴백',
      'similarity avg/max': '유사도 평균/최대',
      'similarity pairs': '유사도 페어',
      'similarity method': '유사도 방식',
      'metrics window': '메트릭 윈도우',
      'window source cap': '윈도우 수집 제한',
      'display zoom': '표시 줌',
      'window points': '윈도우 포인트',
      'window handoff/compaction': '윈도우 핸드오프/컴팩션',
      'window compaction saved': '윈도우 컴팩션 절감',
      'top work': '주요 작업',
      'top model': '주요 모델',
      'top tool': '주요 도구',
      'memory window': '메모리 윈도우',
      'memory bank': '메모리 뱅크',
      notes: '노트',
      'top kind': '주요 종류',
      'window kinds': '윈도우 종류',
      'auto compact': '자동 컴팩션',
      trimmed: '정리됨',
      rows: '행 수',
      raw: '원본',
      fragments: '조각',
      'k2k edges': 'K2K 엣지',
      mentions: '멘션',
      edges: '엣지',
    };
    function localizeKeeperMetaLabels(rootEl) {
      if (!rootEl || keeperFieldLang !== 'ko') return;
      Array.from(rootEl.querySelectorAll('.keeper-chart-meta b')).forEach((el) => {
        const raw = String(el.textContent || '').trim().toLowerCase();
        const translated = keeperMetaLabelKo[raw];
        if (translated) el.textContent = translated;
      });
    }
    function setKeeperQueryState() {
      const url = new URL(window.location.href);
      if (selectedKeeperName) url.searchParams.set('keeper', selectedKeeperName);
      else url.searchParams.delete('keeper');
      if (keeperZoomTurns && keeperZoomTurns !== 120) url.searchParams.set('keeper_zoom', String(keeperZoomTurns));
      else url.searchParams.delete('keeper_zoom');
      if (compareKeeperName && compareKeeperName !== selectedKeeperName) {
        url.searchParams.set('compare_keeper', compareKeeperName);
      } else {
        url.searchParams.delete('compare_keeper');
      }
      if (keeperHandoffGenFilter && keeperHandoffGenFilter !== 'all') {
        url.searchParams.set('handoff_gen', keeperHandoffGenFilter);
      } else {
        url.searchParams.delete('handoff_gen');
      }
      if (keeperHandoffModelFilter && keeperHandoffModelFilter !== 'all') {
        url.searchParams.set('handoff_model', keeperHandoffModelFilter);
      } else {
        url.searchParams.delete('handoff_model');
      }
      if (keeperFieldLang && keeperFieldLang !== defaultKeeperFieldLang) {
        url.searchParams.set('keeper_lang', keeperFieldLang);
      } else {
        url.searchParams.delete('keeper_lang');
      }
      const fieldQuery = String(keeperFieldQuery || '').trim();
      if (fieldQuery !== '') url.searchParams.set('keeper_field_query', fieldQuery);
      else url.searchParams.delete('keeper_field_query');
      if (keeperSelectedKpiKey && keeperSelectedKpiKey !== 'context_ratio') {
        url.searchParams.set('keeper_kpi', keeperSelectedKpiKey);
      } else {
        url.searchParams.delete('keeper_kpi');
      }
      history.replaceState(history.state || {}, '', url.pathname + url.search + url.hash);
    }
    function setKeeperZoom(turns) {
      const n = Number(turns);
      if (![20, 50, 120].includes(n)) return;
      keeperZoomTurns = n;
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function setKeeperCompare(name) {
      const next = (name || '').trim();
      compareKeeperName = (next && next !== selectedKeeperName) ? next : null;
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function clearKeeperCompare() {
      compareKeeperName = null;
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function setKeeperHandoffGenFilter(value) {
      const next = (value || '').trim();
      keeperHandoffGenFilter = next !== '' ? next : 'all';
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function setKeeperHandoffModelFilter(value) {
      const next = (value || '').trim();
      keeperHandoffModelFilter = next !== '' ? next : 'all';
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function clearKeeperHandoffFilters() {
      keeperHandoffGenFilter = 'all';
      keeperHandoffModelFilter = 'all';
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function setKeeperFieldLang(lang) {
      const next = String(lang || '').trim().toLowerCase();
      if (!['ko', 'en'].includes(next)) return;
      try { localStorage.setItem(keeperFieldLangStorageKey, next); } catch (_e) {}
      if (keeperFieldLang === next) {
        setKeeperQueryState();
        return;
      }
      keeperFieldLang = next;
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function setKeeperFieldQuery(value) {
      keeperFieldQuery = String(value == null ? '' : value);
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function clearKeeperFieldQuery() {
      if (!keeperFieldQuery) return;
      keeperFieldQuery = '';
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function setKeeperSelectedKpi(key) {
      const next = normalizeKeeperKpiKey(key);
      if (!next) return;
      if (keeperSelectedKpiKey === next) return;
      keeperSelectedKpiKey = next;
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function applyKeeperZoomButtons() {
      [20, 50, 120].forEach((n) => {
        const el = document.getElementById('keeper-zoom-' + n);
        if (!el) return;
        el.classList.toggle('active', keeperZoomTurns === n);
      });
    }
    function applyKeeperLangButtons() {
      ['ko', 'en'].forEach((lang) => {
        const el = document.getElementById('keeper-lang-' + lang);
        if (!el) return;
        el.classList.toggle('active', keeperFieldLang === lang);
      });
    }
    function windowSeries(series) {
      const pts = Array.isArray(series) ? series : [];
      if (!keeperZoomTurns || pts.length <= keeperZoomTurns) return pts;
      return pts.slice(Math.max(0, pts.length - keeperZoomTurns));
    }
    function keeperLineSvg(series, key, opts) {
      const pts = Array.isArray(series) ? series : [];
      const values = pts.map((p) => {
        if (!p) return 0;
        const v = p[key];
        if (isNum(v)) return Number(v);
        if (typeof v === 'boolean') return v ? 1 : 0;
        return 0;
      });
      if (values.length < 2) return `<div class="spark-empty">${escHtml(keeperText('no_series'))}</div>`;
      const w = 860;
      const h = 150;
      const threshold = opts && isNum(opts.threshold) ? Number(opts.threshold) : null;
      let maxV = values.reduce((m, v) => Math.max(m, v), 0);
      if (threshold !== null) maxV = Math.max(maxV, threshold);
      maxV = Math.max(maxV, 1e-9);
      const minV = 0;
      const span = Math.max(maxV - minV, 1e-9);
      const x = (i) => (values.length <= 1 ? 0 : (w * i / (values.length - 1)));
      const y = (v) => h - clamp(((v - minV) / span) * h, 0, h);
      const poly = values.map((v, i) => `${x(i).toFixed(2)},${y(v).toFixed(2)}`).join(' ');
      const color = (opts && opts.color) ? opts.color : '#22d3ee';
      const thrLine = (threshold !== null && threshold >= minV && threshold <= maxV)
        ? `<line x1="0" y1="${y(threshold).toFixed(2)}" x2="${w}" y2="${y(threshold).toFixed(2)}" stroke="rgba(251,191,36,0.7)" stroke-width="1.2" stroke-dasharray="5 4" />`
        : '';
      const handoffMarks = pts.map((p, i) => {
        if (!(p && p.handoff)) return '';
        return `<circle cx="${x(i).toFixed(2)}" cy="${y(values[i]).toFixed(2)}" r="2.8" fill="#fbbf24" />`;
      }).join('');
      const compactMarks = pts.map((p, i) => {
        if (!(p && p.compacted)) return '';
        const xx = x(i).toFixed(2);
        const yy = y(values[i]).toFixed(2);
        return `<rect x="${(Number(xx) - 2).toFixed(2)}" y="${(Number(yy) - 2).toFixed(2)}" width="4" height="4" fill="#4ade80" />`;
      }).join('');
      return `
        <svg viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
          <polyline points="${poly}" fill="none" stroke="${color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
          ${thrLine}
          ${handoffMarks}
          ${compactMarks}
        </svg>
      `.trim();
    }
    function keeperDualLineSvg(series, keyA, keyB, opts) {
      const pts = Array.isArray(series) ? series : [];
      const readVal = (p, key) => {
        if (!p) return 0;
        const v = p[key];
        if (isNum(v)) return Number(v);
        if (typeof v === 'boolean') return v ? 1 : 0;
        return 0;
      };
      const aVals = pts.map((p) => readVal(p, keyA));
      const bVals = pts.map((p) => readVal(p, keyB));
      if (aVals.length < 2) return `<div class="spark-empty">${escHtml(keeperText('no_series'))}</div>`;
      const w = 860;
      const h = 150;
      const maxV = Math.max(
        aVals.reduce((m, v) => Math.max(m, v), 0),
        bVals.reduce((m, v) => Math.max(m, v), 0),
        1
      );
      const x = (i) => (aVals.length <= 1 ? 0 : (w * i / (aVals.length - 1)));
      const y = (v) => h - clamp((v / maxV) * h, 0, h);
      const pa = aVals.map((v, i) => `${x(i).toFixed(2)},${y(v).toFixed(2)}`).join(' ');
      const pb = bVals.map((v, i) => `${x(i).toFixed(2)},${y(v).toFixed(2)}`).join(' ');
      const handoffLines = pts.map((p, i) => {
        if (!(p && p.handoff)) return '';
        const xx = x(i).toFixed(2);
        return `<line x1="${xx}" y1="0" x2="${xx}" y2="${h}" stroke="rgba(251,191,36,0.45)" stroke-width="1" stroke-dasharray="4 4" />`;
      }).join('');
      const aColor = (opts && opts.colorA) ? opts.colorA : '#22d3ee';
      const bColor = (opts && opts.colorB) ? opts.colorB : '#a78bfa';
      return `
        <svg viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
          ${handoffLines}
          <polyline points="${pa}" fill="none" stroke="${aColor}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
          <polyline points="${pb}" fill="none" stroke="${bColor}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
      `.trim();
    }
    function keeperCompareRatioSvg(primarySeries, compareSeries, opts) {
      const aPts = Array.isArray(primarySeries) ? primarySeries : [];
      const bPts = Array.isArray(compareSeries) ? compareSeries : [];
      if (aPts.length < 2 || bPts.length < 2) return `<div class="spark-empty">${escHtml(keeperText('not_enough_points_for_compare'))}</div>`;
      const aVals = aPts.map(p => (p && isNum(p.context_ratio)) ? Number(p.context_ratio) : 0);
      const bVals = bPts.map(p => (p && isNum(p.context_ratio)) ? Number(p.context_ratio) : 0);
      const w = 860;
      const h = 150;
      const threshold = opts && isNum(opts.threshold) ? Number(opts.threshold) : null;
      const maxV = Math.max(
        aVals.reduce((m, v) => Math.max(m, v), 0),
        bVals.reduce((m, v) => Math.max(m, v), 0),
        threshold || 0,
        0.01
      );
      const toLine = (values) => {
        const x = (i) => (values.length <= 1 ? 0 : (w * i / (values.length - 1)));
        const y = (v) => h - clamp((v / maxV) * h, 0, h);
        return values.map((v, i) => `${x(i).toFixed(2)},${y(v).toFixed(2)}`).join(' ');
      };
      const primaryLine = toLine(aVals);
      const compareLine = toLine(bVals);
      const primaryColor = (opts && opts.primaryColor) ? opts.primaryColor : '#22d3ee';
      const compareColor = (opts && opts.compareColor) ? opts.compareColor : '#f97316';
      const thrLine = (threshold !== null && threshold <= maxV)
        ? `<line x1="0" y1="${(h - (threshold / maxV) * h).toFixed(2)}" x2="${w}" y2="${(h - (threshold / maxV) * h).toFixed(2)}" stroke="rgba(251,191,36,0.65)" stroke-width="1.2" stroke-dasharray="5 4" />`
        : '';
      return `
        <svg viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
          ${thrLine}
          <polyline points="${primaryLine}" fill="none" stroke="${primaryColor}" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round" />
          <polyline points="${compareLine}" fill="none" stroke="${compareColor}" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
      `.trim();
    }
    function keeperEventsHtml(series) {
      const pts = Array.isArray(series) ? series : [];
      const events = [];
      pts.forEach((p) => {
        if (!p) return;
        if (p.handoff) {
          events.push({
            type: 'handoff',
            ts: isNum(p.ts_unix) ? p.ts_unix : 0,
            text: keeperFormat('event_handoff_to_next_generation', {
              gen: (isNum(p.generation) ? p.generation + 1 : '?'),
            })
          });
        }
        if (p.compacted) {
          events.push({
            type: 'compaction',
            ts: isNum(p.ts_unix) ? p.ts_unix : 0,
            text: keeperFormat('event_context_compaction_at', {
              ratio: (isNum(p.context_ratio) ? Math.round(p.context_ratio * 100) : '?'),
            })
          });
        }
        if (p.memory_compaction_performed) {
          const dropped = isNum(p.memory_compaction_dropped_notes) ? Number(p.memory_compaction_dropped_notes) : 0;
          const before = isNum(p.memory_compaction_before_notes) ? Number(p.memory_compaction_before_notes) : 0;
          events.push({
            type: 'compaction',
            ts: isNum(p.ts_unix) ? p.ts_unix : 0,
            text: keeperFormat('event_memory_compaction_dropped', { dropped, before })
          });
        }
      });
      if (events.length === 0) return `<div class="empty">${escHtml(keeperText('no_handoff_compaction_events'))}</div>`;
      events.sort((a, b) => b.ts - a.ts);
      return events.slice(0, 20).map(e => `
        <div class="keeper-event ${e.type}">
          <span class="keeper-event-time">${e.ts > 0 ? (fmtTs(e.ts) + ' · ' + timeAgo(e.ts)) : '-'}</span>${escHtml(e.text)}
        </div>
      `).join('');
    }
    function keeperHandoffTimelineHtml(series, opts = {}) {
      const pts = Array.isArray(series) ? series : [];
      const limit = isNum(opts.limit) ? Number(opts.limit) : 12;
      const genFilter = (opts.genFilter || 'all').trim();
      const modelFilter = (opts.modelFilter || 'all').trim();
      const events = pts
        .filter((p) => p && p.handoff)
        .filter((p) => {
          if (genFilter !== 'all') {
            const fromGen = isNum(p.generation) ? String(Number(p.generation)) : '';
            if (fromGen !== genFilter) return false;
          }
          if (modelFilter !== 'all') {
            const model = (p.handoff_to_model || p.model_used || '').trim();
            if (model !== modelFilter) return false;
          }
          return true;
        })
        .map((p) => {
          const fromGen = isNum(p.generation) ? Number(p.generation) : null;
          const toGen = isNum(p.handoff_new_generation)
            ? Number(p.handoff_new_generation)
            : (fromGen === null ? null : (fromGen + 1));
          const genText = (fromGen === null || toGen === null)
            ? 'generation -'
            : `g${fromGen} -> g${toGen}`;
          const model = p.handoff_to_model || p.model_used || '-';
          const fromTrace = p.handoff_prev_trace_id || p.trace_id || '-';
          const toTrace = p.handoff_new_trace_id || '-';
          const ratio = isNum(p.context_ratio)
            ? ((Math.round(Number(p.context_ratio) * 1000) / 10).toFixed(1) + '%')
            : '-';
          const ioText = `${fmtInt(p.input_tokens)} / ${fmtInt(p.output_tokens)}`;
          const totalText = fmtInt(p.total_tokens);
          const latencyText = isNum(p.latency_ms) ? (fmtInt(p.latency_ms) + 'ms') : '-';
          const tokensText = `${fmtInt(p.context_tokens)} / ${fmtInt(p.context_max)}`;
          const msgText = fmtInt(p.message_count);
          const memText = p.memory_performed
            ? `${p.memory_passed ? 'pass' : 'fail'} (${isNum(p.memory_final_score) ? Number(p.memory_final_score).toFixed(3) : '-'}/${isNum(p.memory_threshold) ? Number(p.memory_threshold).toFixed(3) : '-'})`
            : 'n/a';
          const toolCallsText = fmtInt(p.tool_call_count);
          const toolsText = Array.isArray(p.tools_used) && p.tools_used.length > 0
            ? p.tools_used.join(', ')
            : '-';
          const costText = isNum(p.cost_usd) ? ('$' + Number(p.cost_usd).toFixed(6)) : '-';
          return {
            ts: isNum(p.ts_unix) ? Number(p.ts_unix) : 0,
            genText,
            model,
            fromTrace,
            toTrace,
            ratio,
            ioText,
            totalText,
            latencyText,
            workKind: p.work_kind || '-',
            tokensText,
            msgText,
            memText,
            toolCallsText,
            toolsText,
            costText,
          };
        })
        .sort((a, b) => b.ts - a.ts);

      if (events.length === 0) {
        return `<div class="empty">${escHtml(keeperText('no_handoff_events_for_selected_filters'))}</div>`;
      }
      return `<div class="keeper-handoff-list">` + events.slice(0, limit).map((ev) => `
        <details class="keeper-handoff-row">
          <summary class="keeper-handoff-summary">
            <div class="keeper-handoff-head">
              <span class="keeper-handoff-gen">${escHtml(ev.genText)}</span>
              <span class="keeper-handoff-time">${fmtTs(ev.ts)}</span>
            </div>
            <div class="keeper-handoff-meta">
              <span><b>model</b> ${escHtml(ev.model)}</span>
              <span><b>ctx</b> ${escHtml(ev.ratio)}</span>
              <span><b>io</b> ${escHtml(ev.ioText)}</span>
              <span><b>latency</b> ${escHtml(ev.latencyText)}</span>
              <span><b>work</b> ${escHtml(ev.workKind)}</span>
            </div>
            <div class="keeper-handoff-trace">
              trace ${escHtml(shortTraceId(ev.fromTrace))} -> ${escHtml(shortTraceId(ev.toTrace))}
            </div>
          </summary>
          <div class="keeper-handoff-extra">
            <div class="keeper-handoff-extra-grid">
              <span><b>context tokens</b> ${escHtml(ev.tokensText)}</span>
              <span><b>messages</b> ${escHtml(ev.msgText)}</span>
              <span><b>turn total</b> ${escHtml(ev.totalText)}</span>
              <span><b>tool calls</b> ${escHtml(ev.toolCallsText)}</span>
              <span><b>memory</b> ${escHtml(ev.memText)}</span>
              <span><b>cost</b> ${escHtml(ev.costText)}</span>
            </div>
            <div class="keeper-handoff-tools"><b>tools</b> ${escHtml(ev.toolsText)}</div>
          </div>
        </details>
      `).join('') + `</div>`;
    }
    function renderKeeperDetail() {
      const modal = document.getElementById('keeper-detail-modal');
      const title = document.getElementById('keeper-detail-title');
      const sub = document.getElementById('keeper-detail-sub');
      const etaPill = document.getElementById('keeper-detail-eta');
      const content = document.getElementById('keeper-detail-content');
      const compareSelect = document.getElementById('keeper-compare-select');
      if (!modal || !title || !sub || !content) return;
      applyKeeperZoomButtons();
      applyKeeperLangButtons();
      if (!selectedKeeperName) {
        content.innerHTML = `<div class="empty">${escHtml(keeperText('no_keeper_selected'))}</div>`;
        if (etaPill) etaPill.textContent = 'ETA -';
        return;
      }
      const keepers = normalizeKeeperPayload(_dashboardLatest && _dashboardLatest.keepers);
      const keeper = keepers.find(k => (k && k.name) === selectedKeeperName);
      if (!keeper) {
        title.textContent = 'Keeper Detail';
        sub.textContent = selectedKeeperName;
        content.innerHTML = `<div class="empty">${escHtml(keeperText('keeper_data_not_available'))}</div>`;
        if (etaPill) etaPill.textContent = 'ETA -';
        if (compareSelect) compareSelect.innerHTML = `<option value="">${escHtml(keeperText('select_keeper'))}</option>`;
        return;
      }

      const compareCandidates = keepers
        .filter(k => k && k.name && k.name !== selectedKeeperName)
        .map(k => k.name);
      if (compareKeeperName && !compareCandidates.includes(compareKeeperName)) {
        compareKeeperName = null;
      }
      if (compareSelect) {
        const options = [`<option value="">${escHtml(keeperText('select_keeper'))}</option>`].concat(
          compareCandidates.map(name =>
            `<option value="${escHtml(name)}"${compareKeeperName === name ? ' selected' : ''}>${escHtml(name)}</option>`
          )
        );
        compareSelect.innerHTML = options.join('');
      }

      const ctx = keeper.context || {};
      const ratio = isNum(ctx.context_ratio) ? ctx.context_ratio : null;
      const ratioPct = ratio === null ? '-' : (Math.round(ratio * 100) + '%');
      const age = fmtSecShort(keeper.keeper_age_s);
      const th = isNum(keeper.handoff_threshold) ? keeper.handoff_threshold : 0.85;
      const alertThresholds = currentAlertThresholds();
      const lifeState = keeperLifeState(keeper, alertThresholds);
      const soulProfile = (keeper.soul_profile || 'balanced');
      const goalBaseText =
        (typeof keeper.goal === 'string' && keeper.goal.trim() !== '')
          ? keeper.goal.trim()
          : '-';
      const shortGoalText =
        (typeof keeper.short_goal === 'string' && keeper.short_goal.trim() !== '')
          ? keeper.short_goal.trim()
          : goalBaseText;
      const midGoalText =
        (typeof keeper.mid_goal === 'string' && keeper.mid_goal.trim() !== '')
          ? keeper.mid_goal.trim()
          : goalBaseText;
      const longGoalText =
        (typeof keeper.long_goal === 'string' && keeper.long_goal.trim() !== '')
          ? keeper.long_goal.trim()
          : goalBaseText;
      const shortGoalKpi = shortText(shortGoalText, 72);
      const midGoalKpi = shortText(midGoalText, 72);
      const longGoalKpi = shortText(longGoalText, 72);
      const willText = (typeof keeper.will === 'string' && keeper.will.trim() !== '') ? keeper.will.trim() : '-';
      const needsText = (typeof keeper.needs === 'string' && keeper.needs.trim() !== '') ? keeper.needs.trim() : '-';
      const desiresText = (typeof keeper.desires === 'string' && keeper.desires.trim() !== '') ? keeper.desires.trim() : '-';
      const willKpi = shortText(willText, 72);
      const needsKpi = shortText(needsText, 72);
      const desiresKpi = shortText(desiresText, 72);
      const modelUsed = keeper.active_model || keeper.last_model_used || '-';
      const nextModel = keeper.next_model_hint || '-';
      const skillPrimary =
        (typeof keeper.skill_primary === 'string' && keeper.skill_primary.trim() !== '')
          ? keeper.skill_primary.trim()
          : '-';
      const skillSecondary =
        Array.isArray(keeper.skill_secondary)
          ? keeper.skill_secondary
              .filter((s) => typeof s === 'string' && s.trim() !== '')
              .map((s) => s.trim())
          : [];
      const skillReason =
        (typeof keeper.skill_reason === 'string' && keeper.skill_reason.trim() !== '')
          ? keeper.skill_reason.trim()
          : '-';
      const skillRouteText =
        skillSecondary.length > 0
          ? `${skillPrimary} (+${skillSecondary.join(', ')})`
          : skillPrimary;
      const fullSeries = Array.isArray(keeper.metrics_series) ? keeper.metrics_series : [];
      const series = windowSeries(fullSeries);
      const windowStats = keeper.metrics_window || {};
      const metrics24h = Array.isArray(keeper.metrics_24h) ? keeper.metrics_24h : [];
      const metrics24hSummary = (keeper.metrics_24h_summary && typeof keeper.metrics_24h_summary === 'object')
        ? keeper.metrics_24h_summary
        : {};
      const ratioColor = keeperColorByRatio(ratio);
      const primaryModel = windowStats.primary_model || keeper.primary_model || ((Array.isArray(keeper.models) && keeper.models[0]) ? keeper.models[0] : '-');
      const metricGlossary = {
        life_status: {
          label: 'Life Status',
          short: 'Overall keeper liveness and health from keepalive/staleness/probe signals.',
          definition: 'Classifies keeper health as active, warn, dead, or inactive.',
          formula: 'statusClass from existence/keepalive/recentSignal + stale/keepalive windows',
          source: 'keeper.keepalive_running, keeper.last_seen_ago_s, keeper.metrics_series',
          interpretation: 'Warn means near-threshold life conditions. Dead means no meaningful refresh in staleness or keepalive windows.',
        },
        life_keepalive_status: {
          label: 'Keepalive',
          short: 'Whether periodic keepalive is running for this keeper.',
          definition: 'on means keepalive worker is active, off means paused or missing.',
          formula: 'keeper.keepalive_running',
          source: 'keeper.keepalive_running',
          interpretation: 'off shortens life confidence, especially with stale context metrics.',
        },
        life_pulse: {
          label: 'Life Pulse',
          short: 'Recent signal activity from turns, proactive events, or metrics.',
          definition: 'Recent activity within last 10 minutes is treated as a live pulse.',
          formula: 'last_turn_ago_s / last_proactive_ago_s / metrics_series.ts_unix',
          source: 'keeper.last_turn_ago_s, keeper.last_proactive_ago_s, keeper.metrics_series',
          interpretation: 'quiet indicates that lifecycle state may rely on keepalive and staleness checks.',
        },
        life_stale: {
          label: 'Last Seen',
          short: 'How long ago the keeper was last updated.',
          definition: 'Age at last heartbeat/turn/proactive signal.',
          formula: 'keeper.last_seen_ago_s',
          source: 'keeper.last_seen_ago_s',
          interpretation: 'Large values may indicate stalled heartbeat or delayed persistence.',
        },
        context_ratio: {
          label: 'Context',
          short: 'Current context usage ratio and tokens used/max for this keeper.',
          definition: 'How full the live context window is for the current keeper generation.',
          formula: 'context_tokens / context_max',
          source: 'keeper.context.context_tokens, keeper.context.context_max',
          interpretation: `Lower is safer. Watch >= 70%, high pressure near threshold (${Math.round(th * 100)}%).`,
        },
        handoff_threshold: {
          label: 'Handoff Threshold',
          short: 'Context ratio limit where handoff is recommended/triggered.',
          definition: 'Configured upper bound for safe context occupancy.',
          formula: 'keeper.handoff_threshold (fallback 0.85)',
          source: 'keeper.handoff_threshold',
          interpretation: 'Crossing this value means successor handoff should happen immediately.',
        },
        handoff_risk: {
          label: 'Handoff Risk',
          short: 'Composite handoff pressure score (0-100).',
          definition: 'Risk score from context ratio, recent growth trend, and proximity to threshold.',
          formula: 'handoffRiskMetrics(series, threshold).score',
          source: 'windowSeries + handoffRiskMetrics()',
          interpretation: '0-39 low, 40-64 watch, 65-79 high, >=80 urgent.',
        },
        risk_confidence: {
          label: 'Risk Confidence',
          short: 'Signal confidence of current risk estimate.',
          definition: 'Reliability of risk score based on sample quality in the recent window.',
          formula: 'handoffRiskMetrics(series, threshold).confidence',
          source: 'windowSeries + handoffRiskMetrics()',
          interpretation: 'Low confidence means sparse/noisy window data; use trend with caution.',
        },
        handoff_eta: {
          label: 'Handoff ETA',
          short: 'Estimated turns until threshold breach.',
          definition: 'Projected turns remaining before context crosses threshold using recent growth.',
          formula: 'handoffRiskMetrics(series, threshold).eta',
          source: 'windowSeries + handoffRiskMetrics()',
          interpretation: 'ETA now or <=3 turns should be treated as immediate handoff zone.',
        },
        display_zoom: {
          label: 'Display Zoom',
          short: 'Chart-only sampling range (last N points).',
          definition: 'UI zoom level for charts and visual comparisons.',
          formula: 'keeperZoomTurns',
          source: 'dashboard query state',
          interpretation: 'Affects rendering only; backend metrics window aggregation stays unchanged.',
        },
        metrics_window: {
          label: 'Metrics Window',
          short: 'Recent keeper metric rows loaded under source caps.',
          definition: 'Windowed dataset used for KPI aggregation and charts.',
          formula: 'windowSeries(fullSeries) with max_lines/max_bytes caps',
          source: 'keeper.metrics_series + metrics_window caps',
          interpretation: 'If window is too small, rates can swing heavily between refreshes.',
        },
        window_points: {
          label: 'Window Points',
          short: 'Sampled rows in current metrics window.',
          definition: 'Total count of turn/proactive/heartbeat points included in calculations.',
          formula: 'window_sample_points = turn_points + proactive_points + heartbeat_points',
          source: 'keeper.metrics_window.*_points',
          interpretation: 'More points mean more stable ratios; very low points can distort percentages.',
        },
        model_fallback: {
          label: 'Model Fallback Rate',
          short: 'How often model selection diverged from primary route.',
          definition: 'Fallback ratio for interaction points in current window.',
          formula: 'model_fallback_count / model_fallback_denominator',
          source: 'keeper.metrics_window.model_fallback_*',
          interpretation: 'High fallback means routing instability or model availability pressure.',
        },
        proactive_template_fallback: {
          label: 'Proactive Template Fallback',
          short: 'Fallback rate in proactive generation path only.',
          definition: 'How often proactive generation fell back to template instead of normal path.',
          formula: 'proactive_template_fallback_count / proactive_template_fallback_denominator',
          source: 'keeper.metrics_window.proactive_template_fallback_*',
          interpretation: `Warn >= ${fmtPct1(alertThresholds.proactive_fallback_warn)}, bad >= ${fmtPct1(alertThresholds.proactive_fallback_bad)}.`,
        },
        proactive_similarity: {
          label: 'Proactive Similarity',
          short: 'Similarity between adjacent proactive preview texts.',
          definition: 'Repetition detector for proactive outputs (avg/max pair similarity).',
          formula: 'similarity(avg,max) over adjacent proactive preview pairs',
          source: 'keeper.metrics_window.proactive_preview_similarity_*',
          interpretation: `Warn >= ${fmtPct1(alertThresholds.proactive_similarity_warn)}, bad >= ${fmtPct1(alertThresholds.proactive_similarity_bad)}.`,
        },
        drift_window: {
          label: 'Drift Window',
          short: 'Drift applied ratio in current interaction window.',
          definition: 'Frequency of drift policy application on turn/proactive interactions.',
          formula: 'drift_applied_count / window_interactions',
          source: 'keeper.metrics_window.drift_applied_*',
          interpretation: 'Rising drift can be healthy adaptation or unstable behavior, check top reason.',
        },
        intervention_share: {
          label: 'Intervention Share',
          short: 'Proactive share among interaction points.',
          definition: 'How proactively the keeper acts relative to interactive workload.',
          formula: 'proactive_points / window_interactions (per-turn = proactive_points / turn_points)',
          source: 'keeper.metrics_window.proactive_points, turn_points',
          interpretation: 'Higher share means more proactive behavior; too high may look noisy.',
        },
        top_drift_reason: {
          label: 'Top Drift Reason',
          short: 'Most frequent drift trigger reason in current window.',
          definition: 'Dominant cause category for drift applications.',
          formula: 'argmax(top_drift_reasons.count)',
          source: 'keeper.metrics_window.top_drift_reasons[]',
          interpretation: 'Use together with drift rate to decide if guardrail or policy tuning is needed.',
        },
        top_compaction_trigger: {
          label: 'Top Compact Trigger',
          short: 'Most frequent compaction trigger reason in current window.',
          definition: 'Dominant reason category that caused compaction events.',
          formula: 'argmax(top_compaction_triggers.count)',
          source: 'keeper.metrics_window.top_compaction_triggers[]',
          interpretation: 'Helps verify whether compaction is threshold-driven or policy-driven.',
        },
        window_handoff_compaction: {
          label: 'Window Handoff/Compaction',
          short: 'Handoff and compaction event counts in current window.',
          definition: 'Event volume view for handoff and compaction activity.',
          formula: 'handoff_count / compaction_events',
          source: 'keeper.metrics_window.handoff_count, compaction_events',
          interpretation: 'Compaction without handoff may indicate successful pressure relief.',
        },
        window_compaction_saved: {
          label: 'Window Compaction Saved',
          short: 'Total tokens removed by compaction in current window.',
          definition: 'Absolute amount of context tokens reduced by compaction events.',
          formula: 'sum(compaction_saved_tokens)',
          source: 'keeper.metrics_window.compaction_saved_tokens',
          interpretation: 'Large saved tokens with low event count means high-impact compaction.',
        },
        compaction_efficiency: {
          label: 'Compaction Efficiency',
          short: 'Token reduction efficiency of compaction.',
          definition: 'How much of pre-compaction tokens were removed.',
          formula: 'compaction_saved_tokens / compaction_before_tokens',
          source: 'keeper.metrics_window.compaction_*_tokens',
          interpretation: 'Higher is stronger compression; too high can degrade memory continuity.',
        },
        memory_pass: {
          label: 'Memory Pass',
          short: 'Recall check pass rate in current window.',
          definition: 'Accuracy rate for memory recall validations.',
          formula: 'memory_passed / memory_checks',
          source: 'keeper.metrics_window.memory_checks, memory_passed',
          interpretation: 'Low pass rate suggests recall drift or weak note quality.',
        },
        memory_score: {
          label: 'Memory Score',
          short: 'Average recall score vs pass threshold.',
          definition: 'Mean final memory score compared against configured threshold.',
          formula: 'memory_avg_score vs memory_threshold',
          source: 'keeper.metrics_window.memory_avg_score, memory_threshold',
          interpretation: 'Score consistently below threshold implies recall quality regression.',
        },
        weather_recall: {
          label: 'Weather Recall',
          short: 'Recall pass rate for weather-tagged checks only.',
          definition: 'Topic-specific recall quality for expected_topic=weather.',
          formula: 'memory_weather_passed / memory_weather_checks',
          source: 'keeper.metrics_window.memory_weather_*',
          interpretation: 'Use as a narrow topic probe; not representative of all memory topics.',
        },
        memory_corrections: {
          label: 'Corrections',
          short: 'Recall correction attempts and successes.',
          definition: 'Count of corrective actions applied after recall mismatch detection.',
          formula: 'memory_corrections / memory_correction_success',
          source: 'keeper.metrics_window.memory_corrections, memory_correction_success',
          interpretation: 'High attempts with low success means correction policy needs tuning.',
        },
        memory_notes: {
          label: 'Memory Notes',
          short: 'Total long-term notes plus notes added in window.',
          definition: 'Current memory-bank size with incremental growth in this window.',
          formula: 'memory_note_count (+ memory_notes_added)',
          source: 'keeper.memory_note_count, keeper.metrics_window.memory_notes_added',
          interpretation: 'Fast growth without compaction usually raises future context pressure.',
        },
        memory_compact: {
          label: 'Memory Compact',
          short: 'Note-level compaction events and dropped note counts.',
          definition: 'How often memory-note compaction ran and how many notes it trimmed.',
          formula: 'memory_compaction_events / memory_compaction_dropped_notes',
          source: 'keeper.metrics_window.memory_compaction_*',
          interpretation: 'Frequent note trimming may protect context but can reduce recall coverage.',
        },
        memory_trim_rate: {
          label: 'Memory Trim Rate',
          short: 'Ratio of dropped notes during memory compaction.',
          definition: 'Relative aggressiveness of note compaction.',
          formula: 'memory_compaction_dropped_notes / memory_compaction_before_notes',
          source: 'keeper.metrics_window.memory_compaction_before_notes, memory_compaction_dropped_notes',
          interpretation: 'Higher trim rate means stronger pruning; watch memory pass for side effects.',
        },
        tool_calls: {
          label: 'Tool Calls',
          short: 'Total tool invocations observed in current metrics window.',
          definition: 'Execution volume of external/tool operations by this keeper.',
          formula: 'tool_call_count',
          source: 'keeper.metrics_window.tool_call_count',
          interpretation: 'Sudden spikes can indicate workload changes or retry loops.',
        },
        soul_profile: {
          label: 'SOUL Profile',
          short: 'Behavior profile currently applied to this keeper.',
          definition: 'Configured persona/control profile guiding style and priorities.',
          formula: 'keeper.soul_profile',
          source: 'keeper.soul_profile',
          interpretation: 'Treat this as the operating stance that influences behavior drift.',
        },
        will: {
          label: 'Will (의지)',
          short: 'Current will statement of the keeper.',
          definition: 'Primary intent that the keeper is trying to preserve while acting.',
          formula: 'keeper.will',
          source: 'keeper.will',
          interpretation: 'Large will shifts often appear before behavioral direction changes.',
        },
        needs: {
          label: 'Needs (니즈)',
          short: 'Current operational needs declared by keeper.',
          definition: 'Short-term requirements needed for stable operation or progress.',
          formula: 'keeper.needs',
          source: 'keeper.needs',
          interpretation: 'Use this to infer immediate constraints (tools, context, safety).',
        },
        desires: {
          label: 'Desires (욕구)',
          short: 'Current desire statement of keeper.',
          definition: 'Preference-level direction beyond strict operational needs.',
          formula: 'keeper.desires',
          source: 'keeper.desires',
          interpretation: 'Drives proactive behavior intensity and exploration tendency.',
        },
        short_goal: {
          label: 'Short Goal',
          short: 'Immediate execution target in current keeper horizon.',
          definition: 'Near-term objective the keeper should complete in the next turns.',
          formula: 'keeper.short_goal (fallback keeper.goal)',
          source: 'keeper.short_goal, keeper.goal',
          interpretation: 'Use this to validate tactical focus and short-loop continuity.',
        },
        mid_goal: {
          label: 'Mid Goal',
          short: 'Mid-range mission objective for this keeper lifecycle.',
          definition: 'Bridge objective between immediate actions and long-term identity.',
          formula: 'keeper.mid_goal (fallback keeper.goal)',
          source: 'keeper.mid_goal, keeper.goal',
          interpretation: 'Shows whether day-scale planning aligns with active work.',
        },
        long_goal: {
          label: 'Long Goal',
          short: 'Long-horizon purpose keeper should preserve across handoffs.',
          definition: 'Persistent strategic direction expected to survive compaction/handoff.',
          formula: 'keeper.long_goal (fallback keeper.goal)',
          source: 'keeper.long_goal, keeper.goal',
          interpretation: 'Use as continuity anchor across generations and drift checks.',
        },
        active_model: {
          label: 'Active Model',
          short: 'Model used on the latest turn/operation.',
          definition: 'Current live model handling responses for this keeper.',
          formula: 'keeper.active_model || keeper.last_model_used',
          source: 'keeper.active_model, keeper.last_model_used',
          interpretation: 'Changes here indicate immediate routing/fallback effects.',
        },
        next_model: {
          label: 'Next Model',
          short: 'Next model hint selected by router.',
          definition: 'Planned next-hop model if routing policy changes on upcoming turn.',
          formula: 'keeper.next_model_hint',
          source: 'keeper.next_model_hint',
          interpretation: 'Useful as an early warning for upcoming model transition.',
        },
        primary_model: {
          label: 'Primary Model',
          short: 'Baseline preferred model for current window.',
          definition: 'Primary route model used as fallback baseline comparison.',
          formula: 'metrics_window.primary_model || keeper.primary_model || keeper.models[0]',
          source: 'keeper.metrics_window.primary_model, keeper.primary_model',
          interpretation: 'Model fallback is interpreted relative to this primary model.',
        },
        skill_route: {
          label: 'Skill Route',
          short: 'Primary and secondary skill routing path.',
          definition: 'Current capability routing composition for this keeper.',
          formula: 'skill_primary (+ skill_secondary[])',
          source: 'keeper.skill_primary, keeper.skill_secondary',
          interpretation: 'Route drift may explain tool usage and output style changes.',
        },
        total_turns: {
          label: 'Total Turns',
          short: 'Cumulative turn count in keeper lifecycle.',
          definition: 'Total number of turns processed by this keeper lineage segment.',
          formula: 'keeper.total_turns',
          source: 'keeper.total_turns',
          interpretation: 'Higher values generally increase memory pressure and drift potential.',
        },
        io_tokens: {
          label: 'Input / Output',
          short: 'Cumulative input and output token counts.',
          definition: 'Total prompt tokens and generated tokens consumed by this keeper.',
          formula: 'total_input_tokens / total_output_tokens',
          source: 'keeper.total_input_tokens, keeper.total_output_tokens',
          interpretation: 'Input-dominant vs output-dominant balance reveals workload type.',
        },
        total_tokens: {
          label: 'Total Tokens',
          short: 'Cumulative token consumption total.',
          definition: 'Combined token usage across all turns for this keeper.',
          formula: 'keeper.total_tokens',
          source: 'keeper.total_tokens',
          interpretation: 'Strong proxy for lifecycle workload and eventual handoff pressure.',
        },
        total_cost: {
          label: 'Total Cost',
          short: 'Accumulated model cost for this keeper.',
          definition: 'Estimated cumulative USD cost from model usage.',
          formula: 'keeper.total_cost_usd',
          source: 'keeper.total_cost_usd',
          interpretation: 'Use with total tokens to spot expensive routing patterns.',
        },
        born_at: {
          label: 'Born At',
          short: 'Keeper generation birth timestamp.',
          definition: 'Timestamp when current keeper generation started.',
          formula: 'keeper.born_at',
          source: 'keeper.born_at',
          interpretation: 'Together with age, indicates lifecycle phase of this generation.',
        },
        updated_at: {
          label: 'Updated At',
          short: 'Most recent keeper state update time.',
          definition: 'Last persisted state update timestamp.',
          formula: 'keeper.updated_at',
          source: 'keeper.updated_at',
          interpretation: 'Stale timestamp with active heartbeat may indicate update lag.',
        },
        handoffs_total: {
          label: 'Handoffs (Total)',
          short: 'Total completed handoff count.',
          definition: 'Number of successor transitions completed in lifecycle.',
          formula: 'keeper.handoff_count_total',
          source: 'keeper.handoff_count_total',
          interpretation: 'Rising quickly implies high pressure or aggressive rotation policy.',
        },
        compactions_total: {
          label: 'Compactions (Total)',
          short: 'Total compaction execution count.',
          definition: 'Number of compaction runs in keeper lifecycle.',
          formula: 'keeper.compaction_count',
          source: 'keeper.compaction_count',
          interpretation: 'High count with low efficiency means tune compaction policy.',
        },
        compaction_profile: {
          label: 'Compaction Profile',
          short: 'Named compaction policy profile.',
          definition: 'Configured strategy preset used for context/memory compaction.',
          formula: 'keeper.compaction_profile',
          source: 'keeper.compaction_profile',
          interpretation: 'Profile change can shift trim aggressiveness and memory continuity.',
        },
        proactive_total: {
          label: 'Proactive (Total)',
          short: 'Total proactive action count.',
          definition: 'Cumulative number of proactive interventions by keeper.',
          formula: 'keeper.proactive_count_total',
          source: 'keeper.proactive_count_total',
          interpretation: 'High total suggests initiative-heavy behavior trajectory.',
        },
        drift_total: {
          label: 'Drift (Total)',
          short: 'Total drift application count.',
          definition: 'Cumulative drift events applied to behavior/policy.',
          formula: 'keeper.drift_count_total',
          source: 'keeper.drift_count_total',
          interpretation: 'Track with top drift reason to understand adaptation direction.',
        },
        last_proactive: {
          label: 'Last Proactive',
          short: 'Elapsed time since latest proactive action.',
          definition: 'Recency indicator of proactive activity.',
          formula: 'keeper.last_proactive_ago_s -> humanized text',
          source: 'keeper.last_proactive_ago_s',
          interpretation: 'Long gap with high proactive target may indicate proactive stall.',
        },
        last_drift: {
          label: 'Last Drift',
          short: 'Most recent drift turn and reason snapshot.',
          definition: 'Latest drift position in turn timeline with its reason.',
          formula: 'last_drift_turn + last_drift_reason',
          source: 'keeper.last_drift_turn, keeper.last_drift_reason',
          interpretation: 'Recent drift reason often explains abrupt behavior changes.',
        },
        memory_focus: {
          label: 'Memory Focus',
          short: 'Top memory kind currently dominant.',
          definition: 'Most frequent memory kind in current memory bank/window.',
          formula: 'memory_top_kind',
          source: 'keeper.memory_top_kind / memory_bank.top_kind',
          interpretation: 'Helps identify what this keeper prioritizes remembering now.',
        },
        most_work: {
          label: 'Most Work',
          short: 'Most frequent work kind in current window.',
          definition: 'Dominant work category in recent operations.',
          formula: 'argmax(top_work_kinds.count)',
          source: 'keeper.metrics_window.top_work_kinds[]',
          interpretation: 'Useful for quickly identifying recent workload orientation.',
        },
        most_model: {
          label: 'Most Model',
          short: 'Most used model in current window.',
          definition: 'Dominant model by usage count in recent window.',
          formula: 'argmax(top_models.count)',
          source: 'keeper.metrics_window.top_models[]',
          interpretation: 'Confirms practical model usage beyond configured primary model.',
        },
        most_tool: {
          label: 'Most Tool',
          short: 'Most frequently invoked tool in current window.',
          definition: 'Dominant tool by call count in recent operations.',
          formula: 'argmax(top_tools.count)',
          source: 'keeper.metrics_window.top_tools[]',
          interpretation: 'Highlights operational bottleneck or preferred execution path.',
        },
        conversation_rows: {
          label: 'Conversation Rows',
          short: 'Tail rows shown vs raw rows collected.',
          definition: 'Displayed conversation tail volume compared to raw captured rows.',
          formula: 'conversation_tail_count / conversation_raw_count',
          source: 'keeper.conversation_tail_count, keeper.conversation_raw_count',
          interpretation: 'Large gap means heavy truncation/filtering in visible conversation.',
        },
        conversation_fragments: {
          label: 'Conversation Fragments',
          short: 'Fragment parse/filter status in conversation tail.',
          definition: 'Quality indicator for split/fragmented conversation rows.',
          formula: 'fragment badge + filtered fragment count',
          source: 'keeper.conversation_fragment_*',
          interpretation: 'High filtered fragments may reduce recall trace readability.',
        },
        k2k_edges: {
          label: 'K2K Edges',
          short: 'Keeper-to-keeper relay edge count.',
          definition: 'Number of detected inter-keeper relay edges in conversation.',
          formula: 'k2k_count',
          source: 'keeper.k2k_count',
          interpretation: 'Higher values indicate stronger inter-agent interaction density.',
        },
        k2k_mentions: {
          label: 'K2K Mentions',
          short: 'Top mention targets in K2K relay data.',
          definition: 'Most frequent keeper mentions extracted from K2K trails.',
          formula: 'topCounts(k2k_mentions)',
          source: 'keeper.k2k_mentions',
          interpretation: 'Shows which peers this keeper interacts with most.',
        },
        };
      const metricGlossaryKo = {
        life_status: {
          label: '생존 상태',
          short: 'keepalive/최근 활동/오래된 상태 신호를 합쳐 본 생존성 지표입니다.',
          definition: 'active/warn/dead/inactive로 키퍼의 현재 생존 상태를 표시합니다.',
          interpretation: 'warn는 경계 구간, dead는 최근 갱신이 오래된 치명적 상태로 봅니다.',
        },
        life_keepalive_status: {
          label: '키퍼 비트',
          short: '현재 keepalive 동작 여부입니다.',
          definition: 'on이면 주기 갱신 중, off이면 keepalive가 멈췄음을 뜻합니다.',
          interpretation: 'off가 길어지면 생존 판단 신뢰도가 떨어집니다.',
        },
        life_pulse: {
          label: '라이프 패킷',
          short: '최근 10분 내 턴/프로액티브/메트릭 수신 유무입니다.',
          definition: '최근 신호가 없으면 상태 반영이 정적일 수 있습니다.',
          interpretation: 'quiet는 keepalive 기반 판단으로의 전환이 필요할 수 있습니다.',
        },
        life_stale: {
          label: '최종 갱신',
          short: '최근 상태 업데이트로부터 경과한 시간입니다.',
          definition: 'last_seen_ago_s 기반입니다.',
          interpretation: '값이 크면 생존성 저하 또는 반응 지연을 의심할 수 있습니다.',
        },
        context_ratio: {
          label: '컨텍스트',
          short: '현재 컨텍스트 사용률과 사용 토큰/최대 토큰입니다.',
          definition: '현재 세대 키퍼의 라이브 컨텍스트가 얼마나 찼는지 나타냅니다.',
          interpretation: `낮을수록 안전합니다. 70% 이상은 주시, 임계치(${Math.round(th * 100)}%) 근처는 고위험입니다.`,
        },
        handoff_threshold: {
          label: '핸드오프 임계치',
          short: '핸드오프를 권장하거나 트리거하는 컨텍스트 비율 한계입니다.',
          definition: '안전한 컨텍스트 점유를 위한 상한 비율 설정값입니다.',
          interpretation: '이 값을 넘기면 후계 세대로 즉시 승계하는 것이 좋습니다.',
        },
        handoff_risk: {
          label: '핸드오프 위험도',
          short: '핸드오프 압력을 0-100 점수로 합성한 값입니다.',
          definition: '컨텍스트 비율, 최근 증가 추세, 임계치 근접도를 조합한 점수입니다.',
          interpretation: '0-39 낮음, 40-64 주시, 65-79 높음, 80 이상 긴급으로 봅니다.',
        },
        risk_confidence: {
          label: '위험도 신뢰도',
          short: '현재 위험도 추정의 신호 신뢰도입니다.',
          definition: '최근 윈도우 샘플 품질에 기반한 위험도 점수의 신뢰 수준입니다.',
          interpretation: '신뢰도가 낮으면 표본이 적거나 노이즈가 높을 수 있어 해석에 주의가 필요합니다.',
        },
        handoff_eta: {
          label: '핸드오프 ETA',
          short: '임계치 도달까지 남은 예상 턴 수입니다.',
          definition: '최근 증가 추세를 기반으로 임계치 초과까지 남은 턴을 추정합니다.',
          interpretation: 'ETA가 now 이거나 3턴 이하면 즉시 승계 구간으로 봅니다.',
        },
        display_zoom: {
          label: '표시 줌',
          short: '차트에서 마지막 N개 포인트만 보여주는 표시 범위입니다.',
          definition: '차트와 비교 시각화에만 적용되는 UI 줌입니다.',
          interpretation: '백엔드 집계 윈도우는 바뀌지 않고 화면 표시만 바뀝니다.',
        },
        metrics_window: {
          label: '메트릭 윈도우',
          short: '소스 캡 기준으로 로드된 최근 메트릭 행 집합입니다.',
          definition: 'KPI 집계와 차트 계산에 쓰는 윈도우 데이터셋입니다.',
          interpretation: '윈도우가 너무 작으면 비율 지표 변동성이 커질 수 있습니다.',
        },
        window_points: {
          label: '윈도우 포인트',
          short: '현재 윈도우에 포함된 샘플 행 개수입니다.',
          definition: 'turn/proactive/heartbeat 포인트 합계입니다.',
          interpretation: '포인트가 많을수록 지표가 안정적이며, 적으면 왜곡되기 쉽습니다.',
        },
        model_fallback: {
          label: '모델 폴백 비율',
          short: '기본 라우트에서 이탈한 모델 사용 비율입니다.',
          definition: '현재 상호작용 포인트 기준 모델 폴백 비율입니다.',
          interpretation: '높으면 라우팅 불안정 또는 모델 가용성 압력을 의심할 수 있습니다.',
        },
        proactive_template_fallback: {
          label: '프로액티브 템플릿 폴백',
          short: '프로액티브 경로에서 템플릿 폴백된 비율입니다.',
          definition: '프로액티브 생성이 정상 경로 대신 템플릿으로 내려간 빈도입니다.',
          interpretation: `warn ${fmtPct1(alertThresholds.proactive_fallback_warn)} 이상, bad ${fmtPct1(alertThresholds.proactive_fallback_bad)} 이상으로 봅니다.`,
        },
        proactive_similarity: {
          label: '프로액티브 유사도',
          short: '인접 프로액티브 프리뷰 텍스트의 유사도입니다.',
          definition: '프로액티브 출력의 반복성을 평균/최대 유사도로 측정합니다.',
          interpretation: `warn ${fmtPct1(alertThresholds.proactive_similarity_warn)} 이상, bad ${fmtPct1(alertThresholds.proactive_similarity_bad)} 이상으로 봅니다.`,
        },
        drift_window: {
          label: '드리프트 윈도우',
          short: '현재 상호작용 구간에서 드리프트 적용 비율입니다.',
          definition: 'turn/proactive 상호작용에서 드리프트 정책이 적용된 빈도입니다.',
          interpretation: '증가는 적응일 수 있지만 불안정 신호일 수도 있어 사유와 함께 봐야 합니다.',
        },
        intervention_share: {
          label: '개입 비중',
          short: '상호작용 대비 proactive 비중입니다.',
          definition: '최근 작업에서 키퍼가 얼마나 선제적으로 개입하는지 나타냅니다.',
          interpretation: '비중이 높을수록 선제 행동이 많으며, 과하면 노이즈가 늘 수 있습니다.',
        },
        top_drift_reason: {
          label: '주요 드리프트 사유',
          short: '현재 윈도우에서 가장 빈번한 드리프트 트리거 사유입니다.',
          definition: '드리프트를 가장 많이 유발한 원인 카테고리입니다.',
          interpretation: '드리프트 비율과 함께 보면 가드레일 튜닝 포인트를 찾기 쉽습니다.',
        },
        top_compaction_trigger: {
          label: '주요 컴팩션 트리거',
          short: '현재 윈도우에서 가장 빈번한 컴팩션 트리거 사유입니다.',
          definition: '컴팩션 이벤트를 가장 많이 유발한 원인 카테고리입니다.',
          interpretation: '임계치 기반인지 정책 기반인지 운영 성격을 확인할 수 있습니다.',
        },
        window_handoff_compaction: {
          label: '윈도우 핸드오프/컴팩션',
          short: '현재 윈도우의 핸드오프와 컴팩션 이벤트 수입니다.',
          definition: '승계와 압축의 이벤트 볼륨을 함께 보여줍니다.',
          interpretation: '핸드오프 없이 컴팩션이 많다면 압축으로 압력을 해소 중일 수 있습니다.',
        },
        window_compaction_saved: {
          label: '윈도우 컴팩션 절감 토큰',
          short: '현재 윈도우에서 컴팩션으로 줄인 토큰 총합입니다.',
          definition: '컴팩션 이벤트로 절감된 컨텍스트 토큰의 절대량입니다.',
          interpretation: '이벤트 수 대비 절감량이 크면 고효율 컴팩션입니다.',
        },
        compaction_efficiency: {
          label: '컴팩션 효율',
          short: '컴팩션 전 토큰 대비 절감 비율입니다.',
          definition: '컴팩션이 얼마나 강하게 토큰을 줄였는지 나타냅니다.',
          interpretation: '높을수록 강한 압축입니다. 과도하면 기억 연속성이 약해질 수 있습니다.',
        },
        memory_pass: {
          label: '메모리 패스율',
          short: '현재 윈도우의 메모리 회상 검사 통과율입니다.',
          definition: '회상 검증에서 정답으로 판정된 비율입니다.',
          interpretation: '낮으면 회상 드리프트 또는 노트 품질 저하를 의심할 수 있습니다.',
        },
        memory_score: {
          label: '메모리 점수',
          short: '평균 회상 점수와 임계치 비교값입니다.',
          definition: '최종 회상 점수 평균이 threshold 대비 어떤 수준인지 나타냅니다.',
          interpretation: '임계치 이하가 지속되면 회상 품질 저하로 판단합니다.',
        },
        weather_recall: {
          label: '날씨 회상',
          short: 'expected_topic=weather 에 한정한 회상 통과율입니다.',
          definition: '날씨 주제에 대한 토픽 한정 회상 품질 지표입니다.',
          interpretation: '특정 토픽 프로브이므로 전체 메모리 품질과 동일시하면 안 됩니다.',
        },
        memory_corrections: {
          label: '보정',
          short: '회상 보정 시도 횟수와 성공 횟수입니다.',
          definition: '회상 불일치 후 보정 정책이 적용된 횟수와 성공 결과입니다.',
          interpretation: '시도 대비 성공이 낮으면 보정 정책 튜닝이 필요합니다.',
        },
        memory_notes: {
          label: '메모리 노트',
          short: '장기 메모리 노트 총량과 윈도우 증가량입니다.',
          definition: '현재 메모리 뱅크 크기와 최근 증가 추세를 함께 보여줍니다.',
          interpretation: '증가 속도가 빠른데 컴팩션이 없으면 이후 컨텍스트 압력이 커집니다.',
        },
        memory_compact: {
          label: '메모리 컴팩트',
          short: '노트 단위 컴팩션 실행 횟수와 제거 노트 수입니다.',
          definition: '메모리 노트 정리 작업이 얼마나 자주 수행됐는지 보여줍니다.',
          interpretation: '과도한 노트 정리는 컨텍스트 보호에 유리하지만 회상 범위를 줄일 수 있습니다.',
        },
        memory_trim_rate: {
          label: '메모리 트림 비율',
          short: '메모리 컴팩션에서 제거된 노트 비율입니다.',
          definition: '노트 정리 강도를 상대 비율로 나타낸 지표입니다.',
          interpretation: '높을수록 공격적 정리입니다. 패스율과 함께 보며 균형을 잡아야 합니다.',
        },
        tool_calls: {
          label: '도구 호출 수',
          short: '현재 윈도우에서 관측된 총 도구 호출 횟수입니다.',
          definition: '이 키퍼가 외부 도구를 실행한 총량입니다.',
          interpretation: '급격한 증가 시 워크로드 변화나 재시도 루프 가능성을 확인하세요.',
        },
        soul_profile: {
          label: 'SOUL 프로필',
          short: '현재 키퍼에 적용된 행동 프로필입니다.',
          definition: '스타일과 우선순위를 규정하는 페르소나/제어 프로필입니다.',
          interpretation: '프로필 변화는 행동 방향 드리프트의 선행 신호일 수 있습니다.',
        },
        will: {
          label: '의지',
          short: '현재 키퍼의 핵심 의지 문장입니다.',
          definition: '행동 과정에서 유지하려는 중심 목적입니다.',
          interpretation: '의지가 크게 바뀌면 곧 행동 방향이 달라질 가능성이 큽니다.',
        },
        needs: {
          label: '니즈',
          short: '현재 키퍼가 선언한 운영상 필요 조건입니다.',
          definition: '안정 동작이나 진행을 위해 필요한 단기 요구사항입니다.',
          interpretation: '도구, 컨텍스트, 안전 제약 같은 즉시 조건을 파악할 수 있습니다.',
        },
        desires: {
          label: '욕구',
          short: '현재 키퍼의 선호/욕구 방향입니다.',
          definition: '운영 니즈를 넘어선 선호 기반 추진 방향입니다.',
          interpretation: '프로액티브 강도와 탐색 성향에 영향을 줍니다.',
        },
        short_goal: {
          label: '단기 목표',
          short: '현재 구간에서 바로 달성해야 하는 실행 목표입니다.',
          definition: '다음 몇 턴 안에 완료되어야 하는 근거리 목표입니다.',
          interpretation: '전술적 집중도와 단기 연속성 점검에 사용합니다.',
        },
        mid_goal: {
          label: '중기 목표',
          short: '단기 실행과 장기 방향을 잇는 중간 목적입니다.',
          definition: '현재 생애 구간에서 유지할 중간 범위의 진행 목표입니다.',
          interpretation: '일 단위 계획과 실제 행동의 정렬 상태를 보여줍니다.',
        },
        long_goal: {
          label: '장기 목표',
          short: '승계/컴팩팅 이후에도 유지해야 하는 장기 목적입니다.',
          definition: '세대 전환을 거쳐도 보존되어야 하는 전략적 방향입니다.',
          interpretation: '세대 간 연속성 검증의 기준점으로 사용합니다.',
        },
        active_model: {
          label: '활성 모델',
          short: '가장 최근 턴에서 실제 사용된 모델입니다.',
          definition: '현재 응답 처리를 담당하는 라이브 모델입니다.',
          interpretation: '여기 변화는 즉각적인 라우팅 변화의 신호입니다.',
        },
        next_model: {
          label: '다음 모델',
          short: '라우터가 제안한 다음 모델 힌트입니다.',
          definition: '다음 턴에서 전환 가능성이 있는 모델 경로입니다.',
          interpretation: '사전 경고 지표로 활용해 모델 전환을 예측할 수 있습니다.',
        },
        primary_model: {
          label: '기본 모델',
          short: '현재 윈도우에서 기준으로 보는 기본 모델입니다.',
          definition: '폴백 해석 기준이 되는 우선 모델입니다.',
          interpretation: '폴백 비율은 이 모델 대비 이탈 정도로 해석합니다.',
        },
        skill_route: {
          label: '스킬 라우트',
          short: '현재 스킬 라우팅 경로입니다.',
          definition: '주/보조 스킬 조합으로 구성된 실행 경로입니다.',
          interpretation: '라우트 변화는 도구 사용 패턴과 출력 스타일 변화를 유발할 수 있습니다.',
        },
        total_turns: {
          label: '총 턴 수',
          short: '현재 생애 구간에서 처리한 누적 턴 수입니다.',
          definition: '키퍼가 처리한 전체 턴 볼륨입니다.',
          interpretation: '값이 커질수록 메모리 압력과 드리프트 가능성이 커집니다.',
        },
        io_tokens: {
          label: '입력/출력 토큰',
          short: '누적 입력 토큰과 출력 토큰입니다.',
          definition: '프롬프트 소비량과 생성량의 누적합입니다.',
          interpretation: '입출력 비율로 업무 성격을 빠르게 파악할 수 있습니다.',
        },
        total_tokens: {
          label: '총 토큰',
          short: '누적 토큰 소비 총합입니다.',
          definition: '모든 턴의 토큰 사용량을 합친 값입니다.',
          interpretation: '핸드오프 압력의 장기 지표로 활용하기 좋습니다.',
        },
        total_cost: {
          label: '총 비용',
          short: '누적 모델 비용 추정치입니다.',
          definition: '모델 사용량 기반 누적 비용입니다.',
          interpretation: '토큰과 함께 보면 비싼 라우팅 패턴을 찾기 쉽습니다.',
        },
        born_at: {
          label: '생성 시각',
          short: '현재 세대 키퍼가 시작된 시각입니다.',
          definition: '세대 시작 타임스탬프입니다.',
          interpretation: 'age 와 함께 보면 라이프사이클 단계 파악이 쉽습니다.',
        },
        updated_at: {
          label: '업데이트 시각',
          short: '가장 최근 상태 저장 시각입니다.',
          definition: '키퍼 상태가 마지막으로 갱신된 시점입니다.',
          interpretation: 'heartbeat 대비 갱신이 오래되면 상태 반영 지연일 수 있습니다.',
        },
        handoffs_total: {
          label: '총 핸드오프',
          short: '완료된 승계 횟수 누적치입니다.',
          definition: '후계 세대로 전환된 총 횟수입니다.',
          interpretation: '급격히 증가하면 압력 과다 또는 회전 정책 과민 가능성이 있습니다.',
        },
        compactions_total: {
          label: '총 컴팩션',
          short: '컴팩션 실행 누적 횟수입니다.',
          definition: '컨텍스트/메모리 압축 작업의 누적 실행량입니다.',
          interpretation: '횟수가 많은데 효율이 낮으면 정책 재조정이 필요합니다.',
        },
        compaction_profile: {
          label: '컴팩션 프로필',
          short: '적용 중인 컴팩션 정책 프로필입니다.',
          definition: '정리 강도와 조건을 정의한 전략 프리셋입니다.',
          interpretation: '프로필 전환은 메모리 연속성과 정리 강도에 큰 영향을 줍니다.',
        },
        proactive_total: {
          label: '총 프로액티브',
          short: '프로액티브 개입 누적 횟수입니다.',
          definition: '키퍼가 선제적으로 수행한 행동의 총량입니다.',
          interpretation: '값이 높으면 주도적 성향의 운영 궤적입니다.',
        },
        drift_total: {
          label: '총 드리프트',
          short: '드리프트 적용 누적 횟수입니다.',
          definition: '정책/행동 드리프트가 누적 적용된 횟수입니다.',
          interpretation: '주요 드리프트 사유와 함께 보면 적응 방향을 파악하기 쉽습니다.',
        },
        last_proactive: {
          label: '마지막 프로액티브',
          short: '최근 프로액티브 이후 경과 시간입니다.',
          definition: '프로액티브 활동 최신성 지표입니다.',
          interpretation: '간격이 길면 proactive 정체 신호일 수 있습니다.',
        },
        last_drift: {
          label: '마지막 드리프트',
          short: '가장 최근 드리프트 턴과 사유입니다.',
          definition: '최근 드리프트 위치와 원인을 함께 보여줍니다.',
          interpretation: '최근 사유는 행동 변화 해석의 핵심 단서가 됩니다.',
        },
        memory_focus: {
          label: '메모리 포커스',
          short: '현재 가장 우세한 메모리 종류입니다.',
          definition: '메모리 뱅크/윈도우에서 가장 빈번한 kind 입니다.',
          interpretation: '지금 이 키퍼가 무엇을 중요하게 기억하는지 보여줍니다.',
        },
        most_work: {
          label: '주요 작업',
          short: '현재 윈도우에서 가장 빈번한 작업 종류입니다.',
          definition: '최근 실행된 업무 카테고리의 최빈값입니다.',
          interpretation: '최근 워크로드 방향을 빠르게 파악하는 지표입니다.',
        },
        most_model: {
          label: '주요 모델',
          short: '현재 윈도우에서 가장 많이 사용한 모델입니다.',
          definition: '최근 사용 모델의 최빈값입니다.',
          interpretation: '설정값이 아니라 실제 사용 우위를 보여줍니다.',
        },
        most_tool: {
          label: '주요 도구',
          short: '현재 윈도우에서 가장 많이 호출한 도구입니다.',
          definition: '최근 도구 호출의 최빈값입니다.',
          interpretation: '주요 실행 경로나 병목 지점을 빠르게 파악할 수 있습니다.',
        },
        conversation_rows: {
          label: '대화 행 수',
          short: '표시되는 tail 행 수와 raw 행 수 비교입니다.',
          definition: '현재 화면에 보여주는 대화량과 원본 수집량의 차이를 나타냅니다.',
          interpretation: '격차가 크면 표시 단계에서 절단/필터링이 많이 발생한 상태입니다.',
        },
        conversation_fragments: {
          label: '대화 프래그먼트',
          short: '프래그먼트 파싱/필터 상태 지표입니다.',
          definition: '분절된 대화 조각의 발생과 필터링 상태를 보여줍니다.',
          interpretation: '필터 프래그먼트가 많으면 회상 추적 가독성이 떨어질 수 있습니다.',
        },
        k2k_edges: {
          label: 'K2K 엣지',
          short: '키퍼 간 릴레이 연결 수입니다.',
          definition: '대화에서 감지된 inter-keeper 연결 밀도입니다.',
          interpretation: '값이 높을수록 에이전트 간 상호작용이 활발합니다.',
        },
        k2k_mentions: {
          label: 'K2K 멘션',
          short: 'K2K 로그에서 자주 언급된 대상입니다.',
          definition: '릴레이 경로에서 빈번히 호출된 키퍼 목록입니다.',
          interpretation: '어떤 피어와 가장 자주 상호작용하는지 보여줍니다.',
        },
      };
      const glossaryEntry = (key) => {
        const base = metricGlossary[key];
        if (!(base && typeof base === 'object')) return null;
        if (keeperFieldLang !== 'ko') return base;
        const ko = metricGlossaryKo[key];
        if (!(ko && typeof ko === 'object')) return base;
        return {
          ...base,
          label: (typeof ko.label === 'string' && ko.label.trim() !== '') ? ko.label : base.label,
          short: (typeof ko.short === 'string' && ko.short.trim() !== '') ? ko.short : base.short,
          definition: (typeof ko.definition === 'string' && ko.definition.trim() !== '') ? ko.definition : base.definition,
          formula: (typeof ko.formula === 'string' && ko.formula.trim() !== '') ? ko.formula : base.formula,
          source: (typeof ko.source === 'string' && ko.source.trim() !== '') ? ko.source : base.source,
          interpretation: (typeof ko.interpretation === 'string' && ko.interpretation.trim() !== '')
            ? ko.interpretation
            : base.interpretation,
        };
      };
      const glossaryTip = (key) => {
        const entry = glossaryEntry(key);
        if (!entry) return '';
        const shortValue = (typeof entry.short === 'string' && entry.short.trim() !== '')
          ? entry.short.trim()
          : '';
        if (shortValue !== '') return shortValue;
        return (typeof entry.definition === 'string' && entry.definition.trim() !== '')
          ? entry.definition.trim()
          : '';
      };
      const glossaryFieldItemHtml = (label, value) => {
        if (typeof value !== 'string' || value.trim() === '') return '';
        return `<div class="keeper-field-item"><span class="keeper-field-item-label">${escHtml(label)}</span><span class="keeper-field-item-value">${escHtml(value.trim())}</span></div>`;
      };
      const glossaryFieldDetailHtml = (keys) =>
        keys.map((key) => {
          const entry = glossaryEntry(key);
          if (!entry) return '';
          const label = (typeof entry.label === 'string' && entry.label.trim() !== '')
            ? entry.label.trim()
            : key;
          const body = [
            glossaryFieldItemHtml(keeperText('definition'), entry.definition),
            glossaryFieldItemHtml(keeperText('formula'), entry.formula),
            glossaryFieldItemHtml(keeperText('source'), entry.source),
            glossaryFieldItemHtml(keeperText('interpret'), entry.interpretation),
          ].filter((x) => x !== '').join('');
          if (body === '') return '';
          return `<div class="keeper-field-row"><div class="keeper-field-head"><span class="keeper-field-title">${escHtml(label)}</span><code class="keeper-field-key">${escHtml(key)}</code></div>${body}</div>`;
        }).filter((x) => x !== '').join('');
      const glossaryKeys = [
        'life_status',
        'life_keepalive_status',
        'life_pulse',
        'life_stale',
        'context_ratio',
        'handoff_threshold',
        'handoff_risk',
        'risk_confidence',
        'handoff_eta',
        'display_zoom',
        'metrics_window',
        'window_points',
        'model_fallback',
        'proactive_template_fallback',
        'proactive_similarity',
        'drift_window',
        'intervention_share',
        'top_drift_reason',
        'top_compaction_trigger',
        'window_handoff_compaction',
        'window_compaction_saved',
        'compaction_efficiency',
        'memory_pass',
        'memory_score',
        'weather_recall',
        'memory_corrections',
        'memory_notes',
        'memory_compact',
        'memory_trim_rate',
        'tool_calls',
        'soul_profile',
        'will',
        'needs',
        'desires',
        'short_goal',
        'mid_goal',
        'long_goal',
        'active_model',
        'next_model',
        'primary_model',
        'skill_route',
        'total_turns',
        'io_tokens',
        'total_tokens',
        'total_cost',
        'born_at',
        'updated_at',
        'handoffs_total',
        'compactions_total',
        'compaction_profile',
        'proactive_total',
        'drift_total',
        'last_proactive',
        'last_drift',
        'memory_focus',
        'most_work',
        'most_model',
        'most_tool',
        'conversation_rows',
        'conversation_fragments',
        'k2k_edges',
        'k2k_mentions',
      ];
      const fieldQueryNormalized = String(keeperFieldQuery || '').trim().toLowerCase();
      const glossaryVisibleKeys = glossaryKeys.filter((key) => {
        if (!fieldQueryNormalized) return true;
        const entry = glossaryEntry(key);
        if (!entry) return false;
        const haystack = [
          key,
          entry.label || '',
          entry.short || '',
          entry.definition || '',
          entry.formula || '',
          entry.source || '',
          entry.interpretation || '',
        ].join('\n').toLowerCase();
        return haystack.includes(fieldQueryNormalized);
      });
      const glossaryDetailHtml =
        glossaryVisibleKeys.length > 0
          ? glossaryFieldDetailHtml(glossaryVisibleKeys)
          : `<div class="empty">${escHtml(keeperText('no_match'))}</div>`;
      const glossaryCountText = keeperFormat('filtered_count', {
        shown: fmtInt(glossaryVisibleKeys.length),
        total: fmtInt(glossaryKeys.length),
      });
      const kpiLabelHtml = (label, key) => {
        const entry = glossaryEntry(key);
        const labelText =
          (entry && typeof entry.label === 'string' && entry.label.trim() !== '')
            ? entry.label.trim()
            : label;
        const tip = glossaryTip(key);
        const keyAttr = escHtml(String(key || ''));
        if (!tip) return `<div class="keeper-kpi-label" data-kpi-key="${keyAttr}">${escHtml(labelText)}</div>`;
        return `<div class="keeper-kpi-label" data-kpi-key="${keyAttr}">${escHtml(labelText)} <span class="keeper-hint" title="${escHtml(tip)}">?</span></div>`;
      };

      let modelFallbackCount = isNum(windowStats.model_fallback_count)
        ? Number(windowStats.model_fallback_count)
        : (isNum(windowStats.fallback_count) ? Number(windowStats.fallback_count) : null);
      if (modelFallbackCount === null) {
        const normPrimary = normalizeModelName(primaryModel);
        modelFallbackCount = series.reduce((acc, p) => {
          const used = normalizeModelName(p && p.model_used ? p.model_used : '');
          if (!normPrimary || !used) return acc;
          return used === normPrimary ? acc : (acc + 1);
        }, 0);
      }

      const compactionEvents = isNum(windowStats.compaction_events) ? Number(windowStats.compaction_events) : 0;
      const compactionSavedTokens = isNum(windowStats.compaction_saved_tokens) ? Number(windowStats.compaction_saved_tokens) : 0;
      const compactionBeforeTokens = isNum(windowStats.compaction_before_tokens) ? Number(windowStats.compaction_before_tokens) : 0;
      const compactionSavedRatio = isNum(windowStats.compaction_saved_ratio)
        ? Number(windowStats.compaction_saved_ratio)
        : (compactionBeforeTokens > 0 ? (compactionSavedTokens / compactionBeforeTokens) : null);
      const avgCompactionSaved = isNum(windowStats.avg_compaction_saved_tokens)
        ? Number(windowStats.avg_compaction_saved_tokens)
        : (compactionEvents > 0 ? (compactionSavedTokens / compactionEvents) : null);
      const memoryChecks = isNum(windowStats.memory_checks)
        ? Number(windowStats.memory_checks)
        : series.filter(p => p && p.memory_performed).length;
      const memoryPassed = isNum(windowStats.memory_passed)
        ? Number(windowStats.memory_passed)
        : series.filter(p => p && p.memory_performed && p.memory_passed).length;
      const memoryFailed = isNum(windowStats.memory_failed)
        ? Number(windowStats.memory_failed)
        : Math.max(0, memoryChecks - memoryPassed);
      const memoryPassRate = isNum(windowStats.memory_pass_rate)
        ? Number(windowStats.memory_pass_rate)
        : (memoryChecks > 0 ? (memoryPassed / memoryChecks) : null);
      const memoryAvgScore = isNum(windowStats.memory_avg_score)
        ? Number(windowStats.memory_avg_score)
        : (() => {
            const vals = series
              .filter(p => p && p.memory_performed && isNum(p.memory_final_score))
              .map(p => Number(p.memory_final_score));
            if (vals.length === 0) return null;
            return vals.reduce((a, b) => a + b, 0) / vals.length;
          })();
      const memoryThreshold = isNum(windowStats.memory_threshold)
        ? Number(windowStats.memory_threshold)
        : 0.18;
      const memoryCorrections = isNum(windowStats.memory_corrections)
        ? Number(windowStats.memory_corrections)
        : series.filter(p => p && p.memory_correction_applied).length;
      const memoryCorrectionSuccess = isNum(windowStats.memory_correction_success)
        ? Number(windowStats.memory_correction_success)
        : series.filter(p => p && p.memory_correction_success).length;
      const memoryWeatherChecks = isNum(windowStats.memory_weather_checks)
        ? Number(windowStats.memory_weather_checks)
        : series.filter(p => p && p.memory_performed && p.memory_expected_topic === 'weather').length;
      const memoryWeatherPassed = isNum(windowStats.memory_weather_passed)
        ? Number(windowStats.memory_weather_passed)
        : series.filter(p => p && p.memory_performed && p.memory_expected_topic === 'weather' && p.memory_passed).length;
      const memoryWeatherPassRate = isNum(windowStats.memory_weather_pass_rate)
        ? Number(windowStats.memory_weather_pass_rate)
        : (memoryWeatherChecks > 0 ? (memoryWeatherPassed / memoryWeatherChecks) : null);
      const memoryBank = keeper.memory_bank || {};
      const memoryNoteCount = isNum(keeper.memory_note_count)
        ? Number(keeper.memory_note_count)
        : (isNum(memoryBank.total_notes) ? Number(memoryBank.total_notes) : 0);
      const memoryTopKind = keeper.memory_top_kind || memoryBank.top_kind || '-';
      const memoryRecentNotes = Array.isArray(memoryBank.recent_notes)
        ? memoryBank.recent_notes
        : [];
      const memoryRecentNote =
        keeper.memory_recent_note
        || ((memoryRecentNotes[0] && memoryRecentNotes[0].text) ? memoryRecentNotes[0].text : '-');
      const memoryKindCounts = Array.isArray(memoryBank.kind_counts)
        ? memoryBank.kind_counts
        : [];
      const topWorkKinds = Array.isArray(windowStats.top_work_kinds) ? windowStats.top_work_kinds : [];
      const topModels = Array.isArray(windowStats.top_models) ? windowStats.top_models : [];
      const topTools = Array.isArray(windowStats.top_tools) ? windowStats.top_tools : [];
      const topMemoryKindsWindow = Array.isArray(windowStats.top_memory_kinds)
        ? windowStats.top_memory_kinds
        : [];
      const generationEquipment = Array.isArray(windowStats.generation_equipment)
        ? windowStats.generation_equipment : [];
      const topWorkText = topCountsText(topWorkKinds, 'kind');
      const topWorkName = topCountName(topWorkKinds, 'kind');
      const topModelText = topCountsText(topModels, 'model');
      const topModelName = topCountName(topModels, 'model');
      const topToolText = topCountsText(topTools, 'tool');
      const topToolName = topCountName(topTools, 'tool');
      const topMemoryKindsText = topCountsText(topMemoryKindsWindow, 'kind');
      const memoryBankKindsText = topCountsText(memoryKindCounts, 'kind');
      const toolCallCount = isNum(windowStats.tool_call_count) ? Number(windowStats.tool_call_count) : 0;
      const memoryNotesAddedWindow = isNum(windowStats.memory_notes_added)
        ? Number(windowStats.memory_notes_added)
        : 0;
      const memoryCompactionEvents = isNum(windowStats.memory_compaction_events)
        ? Number(windowStats.memory_compaction_events)
        : series.filter(p => p && p.memory_compaction_performed).length;
      const memoryCompactionBeforeNotes = isNum(windowStats.memory_compaction_before_notes)
        ? Number(windowStats.memory_compaction_before_notes)
        : series.reduce((acc, p) => {
            if (!p || !p.memory_compaction_performed || !isNum(p.memory_compaction_before_notes)) return acc;
            return acc + Number(p.memory_compaction_before_notes);
          }, 0);
      const memoryCompactionDroppedNotes = isNum(windowStats.memory_compaction_dropped_notes)
        ? Number(windowStats.memory_compaction_dropped_notes)
        : series.reduce((acc, p) => {
            if (!p || !p.memory_compaction_performed || !isNum(p.memory_compaction_dropped_notes)) return acc;
            return acc + Number(p.memory_compaction_dropped_notes);
          }, 0);
      const memoryCompactionInvalidDropped = isNum(windowStats.memory_compaction_invalid_dropped)
        ? Number(windowStats.memory_compaction_invalid_dropped)
        : series.reduce((acc, p) => {
            if (!p || !p.memory_compaction_performed || !isNum(p.memory_compaction_invalid_dropped)) return acc;
            return acc + Number(p.memory_compaction_invalid_dropped);
          }, 0);
      const memoryCompactionDropRatio = isNum(windowStats.memory_compaction_drop_ratio)
        ? Number(windowStats.memory_compaction_drop_ratio)
        : (memoryCompactionBeforeNotes > 0 ? (memoryCompactionDroppedNotes / memoryCompactionBeforeNotes) : null);
      const memoryCompactionDropAvg = isNum(windowStats.memory_compaction_drop_avg)
        ? Number(windowStats.memory_compaction_drop_avg)
        : (memoryCompactionEvents > 0 ? (memoryCompactionDroppedNotes / memoryCompactionEvents) : null);
      const turnPoints = isNum(windowStats.turn_points)
        ? Number(windowStats.turn_points)
        : series.filter(p => p && p.channel === 'turn').length;
      const heartbeatPoints = isNum(windowStats.heartbeat_points)
        ? Number(windowStats.heartbeat_points)
        : series.filter(p => p && p.channel === 'heartbeat').length;
      const proactivePoints = isNum(windowStats.proactive_points)
        ? Number(windowStats.proactive_points)
        : series.filter(p => p && p.channel === 'proactive').length;
      const windowSamplePoints = isNum(windowStats.window_sample_points)
        ? Number(windowStats.window_sample_points)
        : (isNum(windowStats.sample_points) ? Number(windowStats.sample_points) : series.length);
      const windowSeriesMaxLines = isNum(windowStats.window_series_max_lines)
        ? Number(windowStats.window_series_max_lines)
        : 120;
      const windowSeriesMaxBytes = isNum(windowStats.window_series_max_bytes)
        ? Number(windowStats.window_series_max_bytes)
        : 200000;
      const driftAppliedCount = isNum(windowStats.drift_applied_count)
        ? Number(windowStats.drift_applied_count)
        : series.filter(p => p && p.drift_applied).length;
      const interactionPoints = turnPoints + proactivePoints;
      const windowInteractions = isNum(windowStats.window_interactions)
        ? Number(windowStats.window_interactions)
        : interactionPoints;
      const modelFallbackNumerator = isNum(windowStats.model_fallback_numerator)
        ? Number(windowStats.model_fallback_numerator)
        : modelFallbackCount;
      const modelFallbackDenominator = isNum(windowStats.model_fallback_denominator)
        ? Number(windowStats.model_fallback_denominator)
        : interactionPoints;
      const modelFallbackRate = isNum(windowStats.model_fallback_rate)
        ? Number(windowStats.model_fallback_rate)
        : (isNum(windowStats.fallback_rate)
            ? Number(windowStats.fallback_rate)
            : (modelFallbackDenominator > 0 ? (modelFallbackNumerator / modelFallbackDenominator) : null));
      const driftAppliedRate = isNum(windowStats.drift_applied_rate)
        ? Number(windowStats.drift_applied_rate)
        : (interactionPoints > 0 ? (driftAppliedCount / interactionPoints) : null);
      const interventionShare = isNum(windowStats.intervention_share)
        ? Number(windowStats.intervention_share)
        : (interactionPoints > 0 ? (proactivePoints / interactionPoints) : null);
      const interventionPerTurn = isNum(windowStats.intervention_per_turn)
        ? Number(windowStats.intervention_per_turn)
        : (turnPoints > 0 ? (proactivePoints / turnPoints) : null);
      const topDriftReasons = Array.isArray(windowStats.top_drift_reasons)
        ? windowStats.top_drift_reasons
        : [];
      const topDriftReason = topCountName(topDriftReasons, 'reason');
      const driftReasonText = topCountsText(topDriftReasons, 'reason');
      const topCompactionTriggers = Array.isArray(windowStats.top_compaction_triggers)
        ? windowStats.top_compaction_triggers
        : [];
      const topCompactionTrigger = topCountName(topCompactionTriggers, 'reason');
      const compactionTriggerText = topCountsText(topCompactionTriggers, 'reason');
      const proactiveTemplateFallbackCount = isNum(windowStats.proactive_template_fallback_count)
        ? Number(windowStats.proactive_template_fallback_count)
        : (isNum(windowStats.proactive_fallback_count)
            ? Number(windowStats.proactive_fallback_count)
            : series.filter(p => p && p.channel === 'proactive' && p.proactive_fallback_applied).length);
      const proactiveTemplateFallbackNumerator = isNum(windowStats.proactive_template_fallback_numerator)
        ? Number(windowStats.proactive_template_fallback_numerator)
        : proactiveTemplateFallbackCount;
      const proactiveTemplateFallbackDenominator = isNum(windowStats.proactive_template_fallback_denominator)
        ? Number(windowStats.proactive_template_fallback_denominator)
        : proactivePoints;
      const proactiveTemplateFallbackRate = isNum(windowStats.proactive_template_fallback_rate)
        ? Number(windowStats.proactive_template_fallback_rate)
        : (isNum(windowStats.proactive_fallback_rate)
            ? Number(windowStats.proactive_fallback_rate)
            : (proactiveTemplateFallbackDenominator > 0
                ? (proactiveTemplateFallbackNumerator / proactiveTemplateFallbackDenominator)
                : null));
      const proactivePreviewSampleCount = isNum(windowStats.proactive_preview_sample_count)
        ? Number(windowStats.proactive_preview_sample_count)
        : 0;
      const proactivePreviewPairCount = isNum(windowStats.proactive_preview_pair_count)
        ? Number(windowStats.proactive_preview_pair_count)
        : 0;
      const proactivePreviewSimilarityAvg = isNum(windowStats.proactive_preview_similarity_avg)
        ? Number(windowStats.proactive_preview_similarity_avg)
        : null;
      const proactivePreviewSimilarityMax = isNum(windowStats.proactive_preview_similarity_max)
        ? Number(windowStats.proactive_preview_similarity_max)
        : null;
      const proactivePreviewSimilarityMethod =
        (typeof windowStats.proactive_preview_similarity_method === 'string'
          && windowStats.proactive_preview_similarity_method.trim() !== '')
          ? windowStats.proactive_preview_similarity_method.trim()
          : 'jaccard_adjacent_preview';
      const proactivePreviewSimilarityMethodLabel =
        proactivePreviewSimilarityMethod === 'jaccard_adjacent_preview'
          ? 'Jaccard(adjacent proactive previews)'
          : proactivePreviewSimilarityMethod;
      const proactivePreviewSimilarityWindow = isNum(windowStats.proactive_preview_similarity_window)
        ? Number(windowStats.proactive_preview_similarity_window)
        : 8;
      const proactivePreviewSimilarityWarn =
        !!windowStats.proactive_preview_similarity_warn
        || (isNum(proactivePreviewSimilarityMax) && proactivePreviewSimilarityMax >= alertThresholds.proactive_similarity_warn);
      const compactionRatioGate = isNum(keeper.compaction_ratio_gate)
        ? Number(keeper.compaction_ratio_gate)
        : 0.5;
      const compactionMessageGate = isNum(keeper.compaction_message_gate)
        ? Number(keeper.compaction_message_gate)
        : 240;
      const compactionTokenGate = isNum(keeper.compaction_token_gate)
        ? Number(keeper.compaction_token_gate)
        : 0;
      const proactiveSimilarityText =
        proactivePreviewPairCount > 0
          ? `avg ${fmtPct1(proactivePreviewSimilarityAvg)} / max ${fmtPct1(proactivePreviewSimilarityMax)}`
          : '-';
      const proactiveSimilarityState =
        (isNum(proactivePreviewSimilarityMax) && proactivePreviewSimilarityMax >= alertThresholds.proactive_similarity_bad)
          ? 'bad'
          : (proactivePreviewSimilarityWarn ? 'warn' : 'ok');
      const proactiveFallbackState =
        (isNum(proactiveTemplateFallbackRate) && proactiveTemplateFallbackRate >= alertThresholds.proactive_fallback_bad)
          ? 'bad'
          : ((isNum(proactiveTemplateFallbackRate) && proactiveTemplateFallbackRate >= alertThresholds.proactive_fallback_warn) ? 'warn' : 'ok');
      const proactiveFallbackKpiClass =
        proactiveFallbackState === 'ok' ? 'keeper-kpi-value' : `keeper-kpi-value ${proactiveFallbackState}`;
      const proactiveSimilarityKpiClass =
        proactiveSimilarityState === 'ok' ? 'keeper-kpi-value' : `keeper-kpi-value ${proactiveSimilarityState}`;
      const proactiveFallbackBadge =
        proactiveFallbackState === 'ok'
          ? '<span class="keeper-role-chip">ok</span>'
          : `<span class="keeper-role-chip ${proactiveFallbackState}">${proactiveFallbackState}</span>`;
      const proactiveSimilarityBadge =
        proactiveSimilarityState === 'ok'
          ? '<span class="keeper-role-chip">ok</span>'
          : `<span class="keeper-role-chip ${proactiveSimilarityState}">${proactiveSimilarityState}</span>`;
      const conversationTail = Array.isArray(keeper.conversation_tail)
        ? keeper.conversation_tail
        : [];
      const conversationTailCount = isNum(keeper.conversation_tail_count)
        ? Number(keeper.conversation_tail_count)
        : conversationTail.length;
      const conversationRawCount = isNum(keeper.conversation_raw_count)
        ? Number(keeper.conversation_raw_count)
        : conversationTailCount;
      const conversationFragmentCount = isNum(keeper.conversation_fragment_count)
        ? Number(keeper.conversation_fragment_count)
        : conversationTail.filter((row) => !!(row && row.is_fragment)).length;
      const conversationFragmentFilteredCount = isNum(keeper.conversation_fragment_filtered_count)
        ? Number(keeper.conversation_fragment_filtered_count)
        : 0;
      const conversationFragmentFilterEnabled = !!keeper.conversation_fragment_filter_enabled;
      const fragmentBadgeText =
        conversationFragmentCount > 0
          ? `frag ${fmtInt(conversationFragmentCount)}`
          : '-';
      const k2kRecent = Array.isArray(keeper.k2k_recent)
        ? keeper.k2k_recent
        : [];
      const k2kCount = isNum(keeper.k2k_count)
        ? Number(keeper.k2k_count)
        : k2kRecent.length;
      const k2kMentions = Array.isArray(keeper.k2k_mentions)
        ? keeper.k2k_mentions
        : [];
      const k2kMentionsText = topCountsText(k2kMentions, 'keeper');
      const bornAtText = fmtIso(keeper.created_at);
      const updatedAtText = fmtIso(keeper.updated_at);
      const proactiveLastAgoText = isNum(keeper.last_proactive_ago_s)
        ? (fmtSecShort(keeper.last_proactive_ago_s) + ' ago')
        : '-';
      const proactiveReasonText =
        (typeof keeper.last_proactive_reason === 'string' && keeper.last_proactive_reason.trim() !== '')
          ? keeper.last_proactive_reason.trim()
          : '-';
      const proactivePreviewText =
        (typeof keeper.last_proactive_preview === 'string' && keeper.last_proactive_preview.trim() !== '')
          ? keeper.last_proactive_preview.trim()
          : '-';
      const metrics24hBuckets = isNum(metrics24hSummary.buckets)
        ? Number(metrics24hSummary.buckets)
        : metrics24h.length;
      const metrics24hPoints = isNum(metrics24hSummary.points)
        ? Number(metrics24hSummary.points)
        : metrics24h.reduce((acc, row) => {
            if (!row || !isNum(row.sample_points)) return acc;
            return acc + Number(row.sample_points);
          }, 0);
      const metrics24hCoverage = isNum(metrics24hSummary.coverage_ratio)
        ? Number(metrics24hSummary.coverage_ratio)
        : null;
      const metrics24hProactivePoints = isNum(metrics24hSummary.proactive_points)
        ? Number(metrics24hSummary.proactive_points)
        : metrics24h.reduce((acc, row) => {
            if (!row || !isNum(row.proactive_points)) return acc;
            return acc + Number(row.proactive_points);
          }, 0);
      const metrics24hFallbackCount = isNum(metrics24hSummary.proactive_template_fallback_count)
        ? Number(metrics24hSummary.proactive_template_fallback_count)
        : (isNum(metrics24hSummary.proactive_fallback_count)
            ? Number(metrics24hSummary.proactive_fallback_count)
            : metrics24h.reduce((acc, row) => {
                const v = isNum(row && row.proactive_template_fallback_count)
                  ? Number(row.proactive_template_fallback_count)
                  : (isNum(row && row.proactive_fallback_count) ? Number(row.proactive_fallback_count) : 0);
                return acc + v;
              }, 0));
      const metrics24hFallbackNumerator = isNum(metrics24hSummary.proactive_template_fallback_numerator)
        ? Number(metrics24hSummary.proactive_template_fallback_numerator)
        : metrics24hFallbackCount;
      const metrics24hFallbackDenominator = isNum(metrics24hSummary.proactive_template_fallback_denominator)
        ? Number(metrics24hSummary.proactive_template_fallback_denominator)
        : metrics24hProactivePoints;
      const metrics24hFallbackRate = isNum(metrics24hSummary.proactive_template_fallback_rate)
        ? Number(metrics24hSummary.proactive_template_fallback_rate)
        : (isNum(metrics24hSummary.proactive_fallback_rate)
            ? Number(metrics24hSummary.proactive_fallback_rate)
            : (metrics24hFallbackDenominator > 0
                ? (metrics24hFallbackNumerator / metrics24hFallbackDenominator)
                : null));
      const metrics24hStartTs =
        metrics24h.length > 0 && isNum(metrics24h[0].bucket_ts_unix)
          ? Number(metrics24h[0].bucket_ts_unix)
          : null;
      const metrics24hEndTs =
        metrics24h.length > 0 && isNum(metrics24h[metrics24h.length - 1].bucket_ts_unix)
          ? Number(metrics24h[metrics24h.length - 1].bucket_ts_unix)
          : null;
      const metrics24hFallbackState =
        (isNum(metrics24hFallbackRate) && metrics24hFallbackRate >= alertThresholds.proactive_fallback_bad)
          ? 'bad'
          : ((isNum(metrics24hFallbackRate) && metrics24hFallbackRate >= alertThresholds.proactive_fallback_warn) ? 'warn' : 'ok');
      const metrics24hFallbackClass =
        metrics24hFallbackState === 'bad'
          ? 'bad-metric'
          : (metrics24hFallbackState === 'warn' ? 'warn-metric' : '');

      const contextRatioChart = keeperLineSvg(series, 'context_ratio', { threshold: th, color: ratioColor });
      const contextTokenChart = keeperLineSvg(series, 'context_tokens', { color: '#4ade80' });
      const ioChart = keeperDualLineSvg(series, 'input_tokens', 'output_tokens', { colorA: '#22d3ee', colorB: '#a78bfa' });
      const memoryChart = keeperLineSvg(series, 'memory_final_score', { threshold: memoryThreshold, color: '#f59e0b' });
      const driftChart = keeperLineSvg(series, 'drift_applied', { color: '#fb7185' });
      const interventionChart = keeperDualLineSvg(series, 'proactive_fallback_applied', 'drift_applied', { colorA: '#22c55e', colorB: '#fb7185' });
      const compactionEventChart = keeperLineSvg(series, 'compacted', { color: '#f97316' });
      const compactionSavedChart = keeperLineSvg(series, 'compaction_saved_tokens', { color: '#f59e0b' });
      const metrics24hRatioChart = keeperLineSvg(metrics24h, 'context_ratio_avg', { threshold: th, color: '#14b8a6' });
      const metrics24hFallbackChart = keeperLineSvg(metrics24h, 'proactive_template_fallback_rate', {
        threshold: alertThresholds.proactive_fallback_warn,
        color: '#f97316',
      });
      const eventsHtml = keeperEventsHtml(series);
      const memoryNotesHtml = keeperMemoryNotesHtml(memoryRecentNotes);
      const conversationHtml = keeperConversationHtml(conversationTail);
      const k2kHtml = keeperK2kHtml(k2kRecent);
      const handoffEventsAll = fullSeries.filter((p) => p && p.handoff);
      const handoffFromGenerations = Array.from(new Set(
        handoffEventsAll
          .map((p) => (isNum(p.generation) ? String(Number(p.generation)) : ''))
          .filter((v) => v !== '')
      )).sort((a, b) => Number(a) - Number(b));
      const handoffModels = Array.from(new Set(
        handoffEventsAll
          .map((p) => (p.handoff_to_model || p.model_used || '').trim())
          .filter((v) => v !== '')
      )).sort((a, b) => a.localeCompare(b));
      let handoffFilterAdjusted = false;
      if (keeperHandoffGenFilter !== 'all' && !handoffFromGenerations.includes(keeperHandoffGenFilter)) {
        keeperHandoffGenFilter = 'all';
        handoffFilterAdjusted = true;
      }
      if (keeperHandoffModelFilter !== 'all' && !handoffModels.includes(keeperHandoffModelFilter)) {
        keeperHandoffModelFilter = 'all';
        handoffFilterAdjusted = true;
      }
      if (handoffFilterAdjusted) setKeeperQueryState();
      const handoffTimelineHtml = keeperHandoffTimelineHtml(fullSeries, {
        limit: 12,
        genFilter: keeperHandoffGenFilter,
        modelFilter: keeperHandoffModelFilter,
      });
      const handoffTimelineCount = handoffEventsAll.length;
      const handoffTimelineFilteredCount = handoffEventsAll.filter((p) => {
        const genOk =
          keeperHandoffGenFilter === 'all'
            || (isNum(p.generation) && String(Number(p.generation)) === keeperHandoffGenFilter);
        const modelValue = (p.handoff_to_model || p.model_used || '').trim();
        const modelOk =
          keeperHandoffModelFilter === 'all'
            || modelValue === keeperHandoffModelFilter;
        return genOk && modelOk;
      }).length;
      const handoffGenOptionsHtml = [`<option value="all">${escHtml(keeperText('all_generations'))}</option>`]
        .concat(handoffFromGenerations.map((fromGen) => {
          const row =
            handoffEventsAll.find((p) => isNum(p.generation) && String(Number(p.generation)) === fromGen)
            || null;
          const toGen =
            row && isNum(row.handoff_new_generation)
              ? Number(row.handoff_new_generation)
              : (Number(fromGen) + 1);
          const label = `g${fromGen} -> g${toGen}`;
          const selected = keeperHandoffGenFilter === fromGen ? ' selected' : '';
          return `<option value="${escHtml(fromGen)}"${selected}>${escHtml(label)}</option>`;
        }))
        .join('');
      const handoffModelOptionsHtml = [`<option value="all">${escHtml(keeperText('all_models'))}</option>`]
        .concat(handoffModels.map((model) => {
          const selected = keeperHandoffModelFilter === model ? ' selected' : '';
          return `<option value="${escHtml(model)}"${selected}>${escHtml(model)}</option>`;
        }))
        .join('');
      const handoffLatestTs = (() => {
        const xs = fullSeries.filter((p) => p && p.handoff && isNum(p.ts_unix));
        if (xs.length === 0) return null;
        return Number(xs[xs.length - 1].ts_unix);
      })();
      const risk = handoffRiskMetrics(series, th);
      const eta = risk.eta;
      let etaText = 'ETA n/a';
      let etaClass = 'keeper-eta-pill';
      if (eta === 0) {
        etaText = 'ETA now';
        etaClass += ' now';
      } else if (isNum(eta)) {
        etaText = `ETA ~${eta} turns`;
        if (eta <= 3) etaClass += ' warn';
      }
      const riskText = (risk.score === null) ? 'Risk -/100' : `Risk ${risk.score}/100`;
      const riskLevelText = (risk.level || 'unknown').toUpperCase();
      const confidenceText = (risk.confidence === null) ? '-' : (risk.confidence + '%');
      const metrics24hFirstRow = metrics24h.length > 0 ? (metrics24h[0] || {}) : {};
      const metrics24hLastRow = metrics24h.length > 0 ? (metrics24h[metrics24h.length - 1] || {}) : {};
      const trendSummaryText = (latest, first, formatter) => {
        if (!isNum(latest) || !isNum(first)) return keeperText('no_24h_data');
        const delta = Number(latest) - Number(first);
        const sign = delta > 0 ? '+' : '';
        return keeperFormat('trend_latest_delta', {
          latest: formatter(Number(latest)),
          delta: `${sign}${formatter(delta)}`,
        });
      };
      const trendPct1 = (v) => `${(Math.round(Number(v) * 1000) / 10).toFixed(1)}%`;
      const trendPoint = (v) => `${(Math.round(Number(v) * 1000) / 10).toFixed(1)}pp`;
      const contextTrend24hText = trendSummaryText(
        metrics24hLastRow.context_ratio_avg,
        metrics24hFirstRow.context_ratio_avg,
        trendPoint,
      );
      const proactiveFallbackTrend24hText = trendSummaryText(
        metrics24hLastRow.proactive_template_fallback_rate,
        metrics24hFirstRow.proactive_template_fallback_rate,
        trendPct1,
      );
      const kpiSnapshot = {
        context_ratio: { current: ratioPct, numerator: fmtInt(ctx.context_tokens), denominator: fmtInt(ctx.context_max), trend24h: contextTrend24hText },
        handoff_threshold: { current: `${Math.round(th * 100)}%`, numerator: '-', denominator: '-', trend24h: keeperText('no_24h_data') },
        handoff_risk: { current: `${riskText} (${riskLevelText})`, numerator: '-', denominator: '-', trend24h: keeperText('no_24h_data') },
        risk_confidence: { current: confidenceText, numerator: '-', denominator: '-', trend24h: keeperText('no_24h_data') },
        handoff_eta: { current: etaText, numerator: '-', denominator: '-', trend24h: keeperText('no_24h_data') },
        model_fallback: { current: modelFallbackRate === null ? '-' : fmtPct1(modelFallbackRate), numerator: fmtInt(modelFallbackNumerator), denominator: fmtInt(modelFallbackDenominator), trend24h: keeperText('no_24h_data') },
        proactive_template_fallback: { current: proactiveTemplateFallbackRate === null ? '-' : fmtPct1(proactiveTemplateFallbackRate), numerator: fmtInt(proactiveTemplateFallbackNumerator), denominator: fmtInt(proactiveTemplateFallbackDenominator), trend24h: proactiveFallbackTrend24hText },
        proactive_similarity: { current: proactiveSimilarityText, numerator: fmtInt(proactivePreviewPairCount), denominator: fmtInt(proactivePreviewSampleCount), trend24h: keeperText('no_24h_data') },
        drift_window: { current: driftAppliedRate === null ? '-' : fmtPct1(driftAppliedRate), numerator: fmtInt(driftAppliedCount), denominator: fmtInt(interactionPoints), trend24h: keeperText('no_24h_data') },
        intervention_share: { current: interventionShare === null ? '-' : fmtPct1(interventionShare), numerator: fmtInt(proactivePoints), denominator: fmtInt(interactionPoints), trend24h: keeperText('no_24h_data') },
        window_handoff_compaction: { current: `${fmtInt(windowStats.handoff_count)} / ${fmtInt(windowStats.compaction_events)}`, numerator: fmtInt(windowStats.handoff_count), denominator: fmtInt(windowStats.compaction_events), trend24h: keeperText('no_24h_data') },
        window_compaction_saved: { current: fmtInt(windowStats.compaction_saved_tokens), numerator: fmtInt(windowStats.compaction_saved_tokens), denominator: '-', trend24h: keeperText('no_24h_data') },
        compaction_efficiency: { current: compactionSavedRatio === null ? '-' : fmtPct1(compactionSavedRatio), numerator: fmtInt(compactionSavedTokens), denominator: fmtInt(compactionBeforeTokens), trend24h: keeperText('no_24h_data') },
        memory_pass: { current: memoryPassRate === null ? '-' : fmtPct1(memoryPassRate), numerator: fmtInt(memoryPassed), denominator: fmtInt(memoryChecks), trend24h: keeperText('no_24h_data') },
        memory_score: { current: memoryAvgScore === null ? '-' : (Math.round(memoryAvgScore * 1000) / 1000).toFixed(3), numerator: memoryAvgScore === null ? '-' : (Math.round(memoryAvgScore * 1000) / 1000).toFixed(3), denominator: memoryThreshold.toFixed(3), trend24h: keeperText('no_24h_data') },
        weather_recall: { current: memoryWeatherPassRate === null ? '-' : fmtPct1(memoryWeatherPassRate), numerator: fmtInt(memoryWeatherPassed), denominator: fmtInt(memoryWeatherChecks), trend24h: keeperText('no_24h_data') },
        memory_corrections: { current: `${fmtInt(memoryCorrections)} / ${fmtInt(memoryCorrectionSuccess)}`, numerator: fmtInt(memoryCorrections), denominator: fmtInt(memoryCorrectionSuccess), trend24h: keeperText('no_24h_data') },
        memory_notes: { current: `${fmtInt(memoryNoteCount)} (+${fmtInt(memoryNotesAddedWindow)} window)`, numerator: fmtInt(memoryNoteCount), denominator: '-', trend24h: keeperText('no_24h_data') },
        memory_compact: { current: `${fmtInt(memoryCompactionEvents)} events / ${fmtInt(memoryCompactionDroppedNotes)} dropped`, numerator: fmtInt(memoryCompactionDroppedNotes), denominator: fmtInt(memoryCompactionBeforeNotes), trend24h: keeperText('no_24h_data') },
        memory_trim_rate: { current: memoryCompactionDropRatio === null ? '-' : fmtPct1(memoryCompactionDropRatio), numerator: fmtInt(memoryCompactionDroppedNotes), denominator: fmtInt(memoryCompactionBeforeNotes), trend24h: keeperText('no_24h_data') },
        tool_calls: { current: fmtInt(toolCallCount), numerator: fmtInt(toolCallCount), denominator: '-', trend24h: keeperText('no_24h_data') },
        window_points: { current: `${fmtInt(windowSamplePoints)} total`, numerator: fmtInt(windowSamplePoints), denominator: '-', trend24h: keeperText('no_24h_data') },
        conversation_rows: { current: `${fmtInt(conversationTailCount)} / raw ${fmtInt(conversationRawCount)}`, numerator: fmtInt(conversationTailCount), denominator: fmtInt(conversationRawCount), trend24h: keeperText('no_24h_data') },
        k2k_edges: { current: fmtInt(k2kCount), numerator: fmtInt(k2kCount), denominator: '-', trend24h: keeperText('no_24h_data') },
      };
      if (!glossaryKeys.includes(keeperSelectedKpiKey)) {
        keeperSelectedKpiKey = 'context_ratio';
        setKeeperQueryState();
      }
      const selectedKpiEntry = glossaryEntry(keeperSelectedKpiKey) || glossaryEntry('context_ratio');
      const selectedKpiData = kpiSnapshot[keeperSelectedKpiKey] || {
        current: '-',
        numerator: '-',
        denominator: '-',
        trend24h: keeperText('no_24h_data'),
      };
      const kpiDetailHtml = `
        <div class="keeper-chart-card">
          <div class="keeper-chart-title">${escHtml(keeperText('kpi_detail'))}</div>
          <div class="keeper-kpi-detail-grid">
            <div class="keeper-kpi-detail-item">
              <div class="keeper-kpi-detail-label">${escHtml(keeperText('selected_field'))}</div>
              <div class="keeper-kpi-detail-value">${escHtml((selectedKpiEntry && selectedKpiEntry.label) ? selectedKpiEntry.label : keeperSelectedKpiKey)} <code class="keeper-field-key">${escHtml(keeperSelectedKpiKey)}</code></div>
            </div>
            <div class="keeper-kpi-detail-item">
              <div class="keeper-kpi-detail-label">${escHtml(keeperText('current_value'))}</div>
              <div class="keeper-kpi-detail-value">${escHtml(selectedKpiData.current || '-')}</div>
            </div>
            <div class="keeper-kpi-detail-item">
              <div class="keeper-kpi-detail-label">${escHtml(keeperText('numerator'))}</div>
              <div class="keeper-kpi-detail-value">${escHtml(selectedKpiData.numerator || '-')}</div>
            </div>
            <div class="keeper-kpi-detail-item">
              <div class="keeper-kpi-detail-label">${escHtml(keeperText('denominator'))}</div>
              <div class="keeper-kpi-detail-value">${escHtml(selectedKpiData.denominator || '-')}</div>
            </div>
            <div class="keeper-kpi-detail-item">
              <div class="keeper-kpi-detail-label">${escHtml(keeperText('formula'))}</div>
              <div class="keeper-kpi-detail-value">${escHtml((selectedKpiEntry && selectedKpiEntry.formula) ? selectedKpiEntry.formula : '-')}</div>
            </div>
            <div class="keeper-kpi-detail-item">
              <div class="keeper-kpi-detail-label">${escHtml(keeperText('trend_24h'))}</div>
              <div class="keeper-kpi-detail-value">${escHtml(selectedKpiData.trend24h || keeperText('no_24h_data'))}</div>
            </div>
          </div>
        </div>
      `;
      if (risk.score !== null && risk.score >= 80) etaClass += ' now';
      else if (risk.score !== null && risk.score >= 65) etaClass += ' warn';
      if (etaPill) {
        etaPill.className = etaClass;
        etaPill.textContent = `${etaText} · ${riskText}`;
      }

      title.textContent = keeper.name || selectedKeeperName;
      const lifeStatusText = lifeState.statusClass === 'dead'
        ? `dead${lifeState.reasons.length > 0 ? `: ${lifeState.reasons.join(', ')}` : ''}`
        : (lifeState.statusClass === 'warn'
            ? `warn${lifeState.reasons.length > 0 ? `: ${lifeState.reasons.join(', ')}` : ''}`
            : (lifeState.statusClass === 'active' ? 'active' : 'inactive'));
      const lifeStatusClass = lifeState.statusClass === 'dead' ? 'bad'
        : (lifeState.statusClass === 'warn' ? 'warn' : '');
      const keepaliveStatusText = lifeState.keepalive ? 'on' : 'off';
      const staleText = lifeState.staleAge === null ? '-' : `${lifeState.staleAge} ago`;
      const lifePulseText = lifeState.recentSignal ? 'recent' : 'quiet';
      sub.textContent = `${keeper.agent_name || ''} · gen ${isNum(keeper.generation) ? keeper.generation : 0} · age ${age} · zoom ${keeperZoomTurns} turns · metrics ${fmtInt(windowSamplePoints)} pts · life ${lifeStatusText}`;

      let compareHtml = `
        <div class="keeper-chart-card keeper-compare-block">
          <div class="keeper-chart-title">${escHtml(keeperText('compare_context_ratio'))}</div>
          <div class="empty">${escHtml(keeperText('compare_select_other'))}</div>
        </div>
      `;
      if (compareKeeperName) {
        const compareKeeper = keepers.find(k => k && k.name === compareKeeperName);
        if (compareKeeper) {
          const compareSeries = windowSeries(Array.isArray(compareKeeper.metrics_series) ? compareKeeper.metrics_series : []);
          const compareChart = keeperCompareRatioSvg(series, compareSeries, {
            threshold: th,
            primaryColor: ratioColor,
            compareColor: '#f97316',
          });
          const compareRisk = handoffRiskMetrics(compareSeries, th);
          const lastPrimary = (series.length > 0 && isNum(series[series.length - 1].context_ratio))
            ? series[series.length - 1].context_ratio : null;
          const lastCompare = (compareSeries.length > 0 && isNum(compareSeries[compareSeries.length - 1].context_ratio))
            ? compareSeries[compareSeries.length - 1].context_ratio : null;
          const deltaPct = (lastPrimary !== null && lastCompare !== null)
            ? Math.round((lastPrimary - lastCompare) * 100) : null;
          const deltaText = (deltaPct === null)
            ? '-'
            : (deltaPct === 0 ? '0pp' : (deltaPct > 0 ? `+${deltaPct}pp` : `${deltaPct}pp`));
          compareHtml = `
            <div class="keeper-chart-card keeper-compare-block">
              <div class="keeper-chart-title">${escHtml(keeperText('compare_context_ratio'))}: ${escHtml(keeper.name || selectedKeeperName)} vs ${escHtml(compareKeeperName)}</div>
              <div class="keeper-chart">${compareChart}</div>
              <div class="keeper-chart-meta">
                <span><b>${escHtml(keeper.name || selectedKeeperName)}</b> ${lastPrimary === null ? '-' : (Math.round(lastPrimary * 100) + '%')}</span>
                <span><b>${escHtml(compareKeeperName)}</b> ${lastCompare === null ? '-' : (Math.round(lastCompare * 100) + '%')}</span>
                <span><b>${escHtml(keeperText('delta'))}</b> ${deltaText}</span>
                <span><b>${escHtml(keeperText('risk'))}</b> ${risk.score === null ? '-' : risk.score} vs ${compareRisk.score === null ? '-' : compareRisk.score}</span>
                <span><b>${escHtml(keeperText('window'))}</b> ${keeperZoomTurns} turns</span>
              </div>
            </div>
          `;
        }
      }

      content.innerHTML = `
        <div class="keeper-kpis">
          <div class="keeper-kpi">${kpiLabelHtml('Life Status', 'life_status')}<div class="keeper-kpi-value ${lifeStatusClass}">${escHtml(lifeStatusText)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Keepalive', 'life_keepalive_status')}<div class="keeper-kpi-value">${escHtml(keepaliveStatusText)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Life Pulse', 'life_pulse')}<div class="keeper-kpi-value">${escHtml(lifePulseText)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Last Seen', 'life_stale')}<div class="keeper-kpi-value">${escHtml(staleText)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('SOUL Profile', 'soul_profile')}<div class="keeper-kpi-value">${escHtml(soulProfile)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Will (의지)', 'will')}<div class="keeper-kpi-value">${escHtml(willKpi)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Needs (니즈)', 'needs')}<div class="keeper-kpi-value">${escHtml(needsKpi)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Desires (욕구)', 'desires')}<div class="keeper-kpi-value">${escHtml(desiresKpi)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Short Goal', 'short_goal')}<div class="keeper-kpi-value">${escHtml(shortGoalKpi)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Mid Goal', 'mid_goal')}<div class="keeper-kpi-value">${escHtml(midGoalKpi)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Long Goal', 'long_goal')}<div class="keeper-kpi-value">${escHtml(longGoalKpi)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Active Model', 'active_model')}<div class="keeper-kpi-value">${escHtml(modelUsed)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Next Model', 'next_model')}<div class="keeper-kpi-value">${escHtml(nextModel)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Primary Model', 'primary_model')}<div class="keeper-kpi-value">${escHtml(primaryModel || '-')}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Skill Route', 'skill_route')}<div class="keeper-kpi-value">${escHtml(skillRouteText)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Context', 'context_ratio')}<div class="keeper-kpi-value">${escHtml(ratioPct)} (${fmtInt(ctx.context_tokens)}/${fmtInt(ctx.context_max)})</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Handoff Threshold', 'handoff_threshold')}<div class="keeper-kpi-value">${Math.round(th * 100)}%</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Handoff Risk', 'handoff_risk')}<div class="keeper-kpi-value">${riskText} (${riskLevelText})</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Risk Confidence', 'risk_confidence')}<div class="keeper-kpi-value">${escHtml(confidenceText)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Total Turns', 'total_turns')}<div class="keeper-kpi-value">${fmtInt(keeper.total_turns)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Input / Output', 'io_tokens')}<div class="keeper-kpi-value">${fmtInt(keeper.total_input_tokens)} / ${fmtInt(keeper.total_output_tokens)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Total Tokens', 'total_tokens')}<div class="keeper-kpi-value">${fmtInt(keeper.total_tokens)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Total Cost', 'total_cost')}<div class="keeper-kpi-value">${fmtUsd(keeper.total_cost_usd)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Born At', 'born_at')}<div class="keeper-kpi-value">${escHtml(bornAtText)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Updated At', 'updated_at')}<div class="keeper-kpi-value">${escHtml(updatedAtText)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Handoffs (Total)', 'handoffs_total')}<div class="keeper-kpi-value">${fmtInt(keeper.handoff_count_total)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Compactions (Total)', 'compactions_total')}<div class="keeper-kpi-value">${fmtInt(keeper.compaction_count)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Compaction Profile', 'compaction_profile')}<div class="keeper-kpi-value">${escHtml(keeper.compaction_profile || 'custom')}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Proactive (Total)', 'proactive_total')}<div class="keeper-kpi-value">${fmtInt(keeper.proactive_count_total)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Drift (Total)', 'drift_total')}<div class="keeper-kpi-value">${fmtInt(keeper.drift_count_total)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Last Proactive', 'last_proactive')}<div class="keeper-kpi-value">${escHtml(proactiveLastAgoText)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Last Drift', 'last_drift')}<div class="keeper-kpi-value">${fmtInt(keeper.last_drift_turn)} / ${escHtml(shortText(keeper.last_drift_reason || '-', 36))}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Proactive Template Fallback', 'proactive_template_fallback')}<div class="${proactiveFallbackKpiClass}" title="formula: proactive_template_fallback_count / proactive_template_fallback_denominator">${fmtInt(proactiveTemplateFallbackNumerator)} / ${fmtInt(proactiveTemplateFallbackDenominator)} (${proactiveTemplateFallbackRate === null ? '-' : fmtPct1(proactiveTemplateFallbackRate)}) ${proactiveFallbackBadge}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Proactive Similarity', 'proactive_similarity')}<div class="${proactiveSimilarityKpiClass}" title="formula: ${escHtml(proactivePreviewSimilarityMethodLabel)}, window<=${fmtInt(proactivePreviewSimilarityWindow)}">${escHtml(proactiveSimilarityText)} (${proactiveSimilarityState}; pairs ${fmtInt(proactivePreviewPairCount)}) ${proactiveSimilarityBadge}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Drift Window', 'drift_window')}<div class="keeper-kpi-value">${fmtInt(driftAppliedCount)} / ${fmtInt(interactionPoints)} (${driftAppliedRate === null ? '-' : fmtPct1(driftAppliedRate)})</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Intervention Share', 'intervention_share')}<div class="keeper-kpi-value">${interventionShare === null ? '-' : fmtPct1(interventionShare)} (per-turn ${interventionPerTurn === null ? '-' : interventionPerTurn.toFixed(2)})</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Top Drift Reason', 'top_drift_reason')}<div class="keeper-kpi-value">${escHtml(topDriftReason)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Top Compact Trigger', 'top_compaction_trigger')}<div class="keeper-kpi-value">${escHtml(topCompactionTrigger)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Window Handoff/Compaction', 'window_handoff_compaction')}<div class="keeper-kpi-value">${fmtInt(windowStats.handoff_count)}/${fmtInt(windowStats.compaction_events)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Window Compaction Saved', 'window_compaction_saved')}<div class="keeper-kpi-value">${fmtInt(windowStats.compaction_saved_tokens)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Compaction Efficiency', 'compaction_efficiency')}<div class="keeper-kpi-value">${compactionSavedRatio === null ? '-' : fmtPct1(compactionSavedRatio)} (${avgCompactionSaved === null ? '-' : fmtInt(avgCompactionSaved) + '/event'})</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Model Fallback Rate', 'model_fallback')}<div class="keeper-kpi-value" title="formula: model_fallback_count / model_fallback_denominator">${modelFallbackRate === null ? '-' : fmtPct1(modelFallbackRate)} (${fmtInt(modelFallbackNumerator)}/${fmtInt(modelFallbackDenominator)})</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Memory Pass', 'memory_pass')}<div class="keeper-kpi-value">${memoryPassRate === null ? '-' : fmtPct1(memoryPassRate)} (${fmtInt(memoryPassed)}/${fmtInt(memoryChecks)})</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Memory Score', 'memory_score')}<div class="keeper-kpi-value">${memoryAvgScore === null ? '-' : (Math.round(memoryAvgScore * 1000) / 1000).toFixed(3)} / ${memoryThreshold.toFixed(2)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Weather Recall', 'weather_recall')}<div class="keeper-kpi-value">${memoryWeatherPassRate === null ? '-' : fmtPct1(memoryWeatherPassRate)} (${fmtInt(memoryWeatherPassed)}/${fmtInt(memoryWeatherChecks)})</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Corrections', 'memory_corrections')}<div class="keeper-kpi-value">${fmtInt(memoryCorrections)} / ${fmtInt(memoryCorrectionSuccess)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Memory Notes', 'memory_notes')}<div class="keeper-kpi-value">${fmtInt(memoryNoteCount)} (+${fmtInt(memoryNotesAddedWindow)} window)</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Memory Compact', 'memory_compact')}<div class="keeper-kpi-value">${fmtInt(memoryCompactionEvents)} events / ${fmtInt(memoryCompactionDroppedNotes)} dropped</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Memory Trim Rate', 'memory_trim_rate')}<div class="keeper-kpi-value">${memoryCompactionDropRatio === null ? '-' : fmtPct1(memoryCompactionDropRatio)} (${memoryCompactionDropAvg === null ? '-' : fmtInt(memoryCompactionDropAvg) + '/event'})</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Memory Focus', 'memory_focus')}<div class="keeper-kpi-value">${escHtml(memoryTopKind)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Most Work', 'most_work')}<div class="keeper-kpi-value">${escHtml(topWorkName)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Most Model', 'most_model')}<div class="keeper-kpi-value">${escHtml(topModelName)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Most Tool', 'most_tool')}<div class="keeper-kpi-value">${escHtml(topToolName)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Tool Calls', 'tool_calls')}<div class="keeper-kpi-value">${fmtInt(toolCallCount)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Window Points', 'window_points')}<div class="keeper-kpi-value">${fmtInt(windowSamplePoints)} total · ${fmtInt(turnPoints)}t / ${fmtInt(proactivePoints)}p / ${fmtInt(heartbeatPoints)}h</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Conversation Rows', 'conversation_rows')}<div class="keeper-kpi-value">${fmtInt(conversationTailCount)} / raw ${fmtInt(conversationRawCount)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Conversation Fragments', 'conversation_fragments')}<div class="keeper-kpi-value">${escHtml(fragmentBadgeText)}${conversationFragmentFilterEnabled ? ` (filtered ${fmtInt(conversationFragmentFilteredCount)})` : ''}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('K2K Edges', 'k2k_edges')}<div class="keeper-kpi-value">${fmtInt(k2kCount)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('K2K Mentions', 'k2k_mentions')}<div class="keeper-kpi-value">${escHtml(k2kMentionsText)}</div></div>
          <div class="keeper-kpi">${kpiLabelHtml('Handoff ETA', 'handoff_eta')}<div class="keeper-kpi-value">${escHtml(etaText)}</div></div>
        </div>
        ${kpiDetailHtml}
        ${compareHtml}
        <div class="keeper-chart-card keeper-handoff-timeline">
          <div class="keeper-chart-title">${escHtml(keeperText('handoff_timeline'))}</div>
          <div class="keeper-chart-meta">
            <span><b>${escHtml(keeperText('events'))}</b> ${fmtInt(handoffTimelineCount)}</span>
            <span><b>${escHtml(keeperText('filtered'))}</b> ${fmtInt(handoffTimelineFilteredCount)}</span>
            <span><b>${escHtml(keeperText('latest'))}</b> ${handoffLatestTs === null ? '-' : fmtTs(handoffLatestTs)}</span>
            <span><b>${escHtml(keeperText('last_model'))}</b> ${escHtml((keeper.last_handoff_event || {}).to_model || '-')}</span>
            <span><b>${escHtml(keeperText('threshold'))}</b> ${Math.round(th * 100)}%</span>
            <span><b>${escHtml(keeperText('window'))}</b> ${keeperZoomTurns} turns</span>
          </div>
          <div class="keeper-handoff-controls">
            <span class="keeper-toolbar-label">${escHtml(keeperText('from_gen'))}</span>
            <select class="keeper-select" onchange="setKeeperHandoffGenFilter(this.value)">${handoffGenOptionsHtml}</select>
            <span class="keeper-toolbar-label">${escHtml(keeperText('model'))}</span>
            <select class="keeper-select" onchange="setKeeperHandoffModelFilter(this.value)">${handoffModelOptionsHtml}</select>
            <button class="keeper-toolbar-btn" onclick="clearKeeperHandoffFilters()">${escHtml(keeperText('clear'))}</button>
          </div>
          ${handoffTimelineHtml}
        </div>
        <div class="keeper-detail-grid">
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('chart_context_ratio_threshold'))}</div>
            <div class="keeper-chart">${contextRatioChart}</div>
            <div class="keeper-chart-meta">
              <span><b>threshold</b> ${Math.round(th * 100)}%</span>
              <span><b>latest</b> ${escHtml(ratioPct)}</span>
              <span><b>points</b> ${fmtInt(turnPoints)}t / ${fmtInt(proactivePoints)}p / ${fmtInt(heartbeatPoints)}h</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('chart_context_tokens'))}</div>
            <div class="keeper-chart">${contextTokenChart}</div>
            <div class="keeper-chart-meta">
              <span><b>current</b> ${fmtInt(ctx.context_tokens)}</span>
              <span><b>max</b> ${fmtInt(ctx.context_max)}</span>
              <span><b>source</b> ${escHtml(keeper.context_source || ctx.source || '-')}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('chart_turn_io_tokens'))}</div>
            <div class="keeper-chart">${ioChart}</div>
            <div class="keeper-chart-meta">
              <span><b>input total</b> ${fmtInt(keeper.total_input_tokens)}</span>
              <span><b>output total</b> ${fmtInt(keeper.total_output_tokens)}</span>
              <span><b>last turn</b> ${fmtInt((keeper.last_usage || {}).input_tokens)} / ${fmtInt((keeper.last_usage || {}).output_tokens)}</span>
              <span title="formula: model_fallback_count / model_fallback_denominator"><b>model fallback</b> ${modelFallbackRate === null ? '-' : fmtPct1(modelFallbackRate)}</span>
              <span><b>memory pass</b> ${memoryPassRate === null ? '-' : fmtPct1(memoryPassRate)}</span>
              <span><b>weather</b> ${memoryWeatherPassRate === null ? '-' : fmtPct1(memoryWeatherPassRate)}</span>
              <span><b>work</b> ${escHtml(topWorkName)}</span>
              <span><b>tool calls</b> ${fmtInt(toolCallCount)}</span>
              <span><b>primary</b> ${escHtml(primaryModel || '-')}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('chart_memory_recall_score'))}</div>
            <div class="keeper-chart">${memoryChart}</div>
            <div class="keeper-chart-meta">
              <span><b>threshold</b> ${(Math.round(memoryThreshold * 1000) / 1000).toFixed(3)}</span>
              <span><b>avg</b> ${memoryAvgScore === null ? '-' : (Math.round(memoryAvgScore * 1000) / 1000).toFixed(3)}</span>
              <span><b>pass</b> ${memoryPassRate === null ? '-' : fmtPct1(memoryPassRate)}</span>
              <span><b>fail</b> ${fmtInt(memoryFailed)}</span>
              <span><b>correct</b> ${fmtInt(memoryCorrections)} / ${fmtInt(memoryCorrectionSuccess)}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('chart_drift_applied'))}</div>
            <div class="keeper-chart">${driftChart}</div>
            <div class="keeper-chart-meta">
              <span><b>window drift</b> ${fmtInt(driftAppliedCount)} / ${fmtInt(interactionPoints)}</span>
              <span><b>rate</b> ${driftAppliedRate === null ? '-' : fmtPct1(driftAppliedRate)}</span>
              <span><b>enabled</b> ${keeper.drift_enabled ? 'on' : 'off'}</span>
              <span><b>gap</b> ${fmtInt(keeper.drift_min_turn_gap)} turns</span>
              <span><b>top reason</b> ${escHtml(topDriftReason)}</span>
              <span><b>reasons</b> ${escHtml(shortText(driftReasonText, 72))}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('chart_intervention_vs_drift'))}</div>
            <div class="keeper-chart">${interventionChart}</div>
            <div class="keeper-chart-meta">
              <span><b>proactive points</b> ${fmtInt(proactivePoints)}</span>
              <span><b>intervention share</b> ${interventionShare === null ? '-' : fmtPct1(interventionShare)}</span>
              <span><b>per-turn</b> ${interventionPerTurn === null ? '-' : interventionPerTurn.toFixed(2)}</span>
              <span><b>drift points</b> ${fmtInt(driftAppliedCount)}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('chart_compaction_timeline'))}</div>
            <div class="keeper-chart">${compactionEventChart}</div>
            <div class="keeper-chart-meta">
              <span><b>events</b> ${fmtInt(windowStats.compaction_events)}</span>
              <span><b>saved</b> ${fmtInt(windowStats.compaction_saved_tokens)}</span>
              <span><b>avg/event</b> ${avgCompactionSaved === null ? '-' : fmtInt(avgCompactionSaved)}</span>
              <span><b>top trigger</b> ${escHtml(topCompactionTrigger)}</span>
              <span><b>spread</b> ${escHtml(shortText(compactionTriggerText, 72))}</span>
            </div>
            <div class="keeper-chart" style="margin-top:8px">${compactionSavedChart}</div>
            <div class="keeper-chart-meta">
              <span><b>profile</b> ${escHtml(keeper.compaction_profile || 'custom')}</span>
              <span><b>gate</b> ratio ${fmtPct1(compactionRatioGate)} / msg ${fmtInt(compactionMessageGate)} / tok ${compactionTokenGate > 0 ? fmtInt(compactionTokenGate) : 'off'}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('chart_24h_trend'))}</div>
            <div class="keeper-chart">${metrics24hRatioChart}</div>
            <div class="keeper-chart-meta">
              <span><b>buckets</b> ${fmtInt(metrics24hBuckets)}</span>
              <span><b>points</b> ${fmtInt(metrics24hPoints)}</span>
              <span><b>coverage</b> ${metrics24hCoverage === null ? '-' : fmtPct1(metrics24hCoverage)}</span>
              <span><b>range</b> ${metrics24hStartTs === null ? '-' : fmtTs(metrics24hStartTs)} ~ ${metrics24hEndTs === null ? '-' : fmtTs(metrics24hEndTs)}</span>
              <span><b>threshold</b> ${Math.round(th * 100)}%</span>
            </div>
            <div class="keeper-chart" style="margin-top:8px">${metrics24hFallbackChart}</div>
            <div class="keeper-chart-meta">
              <span title="formula: proactive_template_fallback_count / proactive_template_fallback_denominator (24h buckets)"><b>proactive template fallback</b> <span class="${metrics24hFallbackClass}">${fmtInt(metrics24hFallbackNumerator)} / ${fmtInt(metrics24hFallbackDenominator)} (${metrics24hFallbackRate === null ? '-' : fmtPct1(metrics24hFallbackRate)})</span></span>
              <span><b>state</b> ${metrics24hFallbackState}</span>
              <span><b>warn/bad</b> ${fmtPct1(alertThresholds.proactive_fallback_warn)} / ${fmtPct1(alertThresholds.proactive_fallback_bad)}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('chart_lifecycle'))}</div>
            <div class="keeper-chart-meta">
              <span><b>trace</b> ${escHtml(keeper.trace_id || '-')}</span>
              <span><b>keepalive</b> ${(keeper.keepalive_running ? 'on' : 'off')}</span>
              <span><b>born</b> ${escHtml(bornAtText)}</span>
              <span><b>updated</b> ${escHtml(updatedAtText)}</span>
              <span><b>age</b> ${escHtml(age)}</span>
              <span><b>last turn</b> ${escHtml(isNum(keeper.last_turn_ago_s) ? (fmtSecShort(keeper.last_turn_ago_s) + ' ago') : 'never')}</span>
              <span><b>last handoff</b> ${escHtml(isNum(keeper.last_handoff_ago_s) ? (fmtSecShort(keeper.last_handoff_ago_s) + ' ago') : '-')}</span>
              <span><b>last compaction</b> ${escHtml(isNum(keeper.last_compaction_ago_s) ? (fmtSecShort(keeper.last_compaction_ago_s) + ' ago') : '-')}</span>
              <span><b>proactive</b> ${(keeper.proactive_enabled ? 'on' : 'off')} (idle ${fmtInt(keeper.proactive_idle_sec)}s / cd ${fmtInt(keeper.proactive_cooldown_sec)}s)</span>
              <span><b>last proactive</b> ${escHtml(proactiveLastAgoText)}</span>
              <span><b>proactive reason</b> ${escHtml(proactiveReasonText)}</span>
              <span><b>proactive preview</b> ${escHtml(proactivePreviewText)}</span>
              <span><b>drift</b> ${(keeper.drift_enabled ? 'on' : 'off')} (gap ${fmtInt(keeper.drift_min_turn_gap)} turns)</span>
              <span><b>drift total</b> ${fmtInt(keeper.drift_count_total)}</span>
              <span><b>last drift reason</b> ${escHtml(shortText(keeper.last_drift_reason || '-', 60))}</span>
              <span><b>skill route</b> ${escHtml(skillRouteText)}</span>
              <span><b>skill reason</b> ${escHtml(skillReason)}</span>
              <span title="formula: proactive_template_fallback_count / proactive_template_fallback_denominator"><b>proactive template fallback</b> <span class="${proactiveFallbackState === 'bad' ? 'bad-metric' : (proactiveFallbackState === 'warn' ? 'warn-metric' : '')}">${fmtInt(proactiveTemplateFallbackNumerator)} / ${fmtInt(proactiveTemplateFallbackDenominator)} (${proactiveTemplateFallbackRate === null ? '-' : fmtPct1(proactiveTemplateFallbackRate)})</span></span>
              <span title="formula: ${escHtml(proactivePreviewSimilarityMethodLabel)}, window<=${fmtInt(proactivePreviewSimilarityWindow)}"><b>proactive similarity</b> <span class="${proactiveSimilarityState === 'bad' ? 'bad-metric' : (proactiveSimilarityState === 'warn' ? 'warn-metric' : '')}">${escHtml(proactiveSimilarityText)} (${proactiveSimilarityState}; samples ${fmtInt(proactivePreviewSampleCount)})</span></span>
              <span><b>last handoff model</b> ${escHtml((keeper.last_handoff_event || {}).to_model || '-')}</span>
              <span><b>last compaction saved</b> ${fmtInt(keeper.last_compaction_saved_tokens)}</span>
              <span><b>compaction efficiency</b> ${compactionSavedRatio === null ? '-' : fmtPct1(compactionSavedRatio)}</span>
              <span><b>compaction gate</b> ratio ${fmtPct1(compactionRatioGate)} / msg ${fmtInt(compactionMessageGate)} / tok ${compactionTokenGate > 0 ? fmtInt(compactionTokenGate) : 'off'}</span>
              <span><b>top compaction trigger</b> ${escHtml(topCompactionTrigger)}</span>
              <span><b>trigger spread</b> ${escHtml(shortText(compactionTriggerText, 72))}</span>
              <span><b>risk confidence</b> ${escHtml(confidenceText)}</span>
              <span><b>window interactions</b> ${fmtInt(windowInteractions)}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('chart_metric_formula'))}</div>
            <div class="keeper-chart-meta">
              <span><b>model fallback</b> ${modelFallbackRate === null ? '-' : fmtPct1(modelFallbackRate)} = ${fmtInt(modelFallbackNumerator)} / ${fmtInt(modelFallbackDenominator)}</span>
              <span><b>template fallback</b> ${proactiveTemplateFallbackRate === null ? '-' : fmtPct1(proactiveTemplateFallbackRate)} = ${fmtInt(proactiveTemplateFallbackNumerator)} / ${fmtInt(proactiveTemplateFallbackDenominator)}</span>
              <span><b>similarity avg/max</b> ${proactiveSimilarityText}</span>
              <span><b>similarity pairs</b> ${fmtInt(proactivePreviewPairCount)} from ${fmtInt(proactivePreviewSampleCount)} samples (window <= ${fmtInt(proactivePreviewSimilarityWindow)})</span>
              <span><b>similarity method</b> ${escHtml(proactivePreviewSimilarityMethodLabel)} (${escHtml(proactivePreviewSimilarityMethod)})</span>
              <span><b>metrics window</b> ${fmtInt(windowSamplePoints)} points (${fmtInt(turnPoints)} turn / ${fmtInt(proactivePoints)} proactive / ${fmtInt(heartbeatPoints)} heartbeat)</span>
              <span><b>window source cap</b> max_lines ${fmtInt(windowSeriesMaxLines)} / max_bytes ${fmtInt(windowSeriesMaxBytes)}</span>
              <span><b>display zoom</b> last ${fmtInt(keeperZoomTurns)} points (charts only)</span>
              <span><b>warn/bad threshold</b> template ${fmtPct1(alertThresholds.proactive_fallback_warn)}/${fmtPct1(alertThresholds.proactive_fallback_bad)}, similarity ${fmtPct1(alertThresholds.proactive_similarity_warn)}/${fmtPct1(alertThresholds.proactive_similarity_bad)}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('metric_glossary'))}</div>
            <div class="keeper-chart-meta">
              <span><b>display zoom</b> ${escHtml(glossaryTip('display_zoom'))}</span>
              <span><b>metrics window</b> ${escHtml(glossaryTip('metrics_window'))}</span>
              <span><b>window points</b> ${escHtml(glossaryTip('window_points'))}</span>
              <span><b>model fallback</b> ${escHtml(glossaryTip('model_fallback'))}</span>
              <span><b>template fallback</b> ${escHtml(glossaryTip('proactive_template_fallback'))}</span>
              <span><b>proactive similarity</b> ${escHtml(glossaryTip('proactive_similarity'))}</span>
              <span><b>drift window</b> ${escHtml(glossaryTip('drift_window'))}</span>
              <span><b>window handoff/compaction</b> ${escHtml(glossaryTip('window_handoff_compaction'))}</span>
              <span><b>window compaction saved</b> ${escHtml(glossaryTip('window_compaction_saved'))}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('field_dictionary_detailed'))}</div>
            <div class="keeper-field-search">
              <input
                type="text"
                value="${escHtml(keeperFieldQuery)}"
                placeholder="${escHtml(keeperText('field_search_placeholder'))}"
                oninput="setKeeperFieldQuery(this.value)"
              />
              <button class="keeper-toolbar-btn" onclick="clearKeeperFieldQuery()">${escHtml(keeperText('clear'))}</button>
              <span class="keeper-field-search-count">${escHtml(glossaryCountText)}</span>
            </div>
            <div class="keeper-field-dictionary">
              ${glossaryDetailHtml}
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('chart_work_equipment'))}</div>
            <div class="keeper-chart-meta">
              <span><b>top work</b> ${escHtml(topWorkText)}</span>
              <span><b>top model</b> ${escHtml(topModelText)}</span>
              <span><b>top tool</b> ${escHtml(topToolText)}</span>
              <span><b>memory window</b> ${escHtml(topMemoryKindsText)}</span>
              <span><b>memory bank</b> ${escHtml(memoryBankKindsText)}</span>
              <span><b>tool calls</b> ${fmtInt(toolCallCount)}</span>
              <span><b>points</b> ${fmtInt(turnPoints)}t / ${fmtInt(proactivePoints)}p / ${fmtInt(heartbeatPoints)}h</span>
            </div>
            <div class="keeper-equipment-wrap">
              ${generationEquipmentHtml(generationEquipment)}
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('chart_memory_bank'))}</div>
            <div class="keeper-chart-meta">
              <span><b>notes</b> ${fmtInt(memoryNoteCount)}</span>
              <span><b>top kind</b> ${escHtml(memoryTopKind)}</span>
              <span><b>window kinds</b> ${escHtml(topMemoryKindsText)}</span>
              <span><b>auto compact</b> ${fmtInt(memoryCompactionEvents)} events</span>
              <span><b>trimmed</b> ${fmtInt(memoryCompactionDroppedNotes)} (+invalid ${fmtInt(memoryCompactionInvalidDropped)})</span>
              <span><b>latest</b> ${escHtml(memoryRecentNote)}</span>
            </div>
            <div class="keeper-memory-wrap">
              ${memoryNotesHtml}
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('chart_recent_conversation'))}</div>
            <div class="keeper-chart-meta">
              <span><b>rows</b> ${fmtInt(conversationTailCount)}</span>
              <span><b>raw</b> ${fmtInt(conversationRawCount)}</span>
              <span><b>fragments</b> ${fmtInt(conversationFragmentCount)}</span>
              <span><b>filtered</b> ${conversationFragmentFilterEnabled ? fmtInt(conversationFragmentFilteredCount) : '-'}</span>
              <span><b>k2k edges</b> ${fmtInt(k2kCount)}</span>
              <span><b>mentions</b> ${escHtml(k2kMentionsText)}</span>
            </div>
            <div class="keeper-conversation-wrap">
              ${conversationHtml}
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">${escHtml(keeperText('chart_k2k_relay_trail'))}</div>
            <div class="keeper-chart-meta">
              <span><b>edges</b> ${fmtInt(k2kCount)}</span>
              <span><b>window</b> recent history tail</span>
            </div>
            <div class="keeper-k2k-wrap">
              ${k2kHtml}
            </div>
          </div>
        </div>
        <div class="keeper-events">
          <div class="keeper-chart-title">${escHtml(keeperText('chart_recent_lifecycle_events'))}</div>
          <div class="keeper-events-list">${eventsHtml}</div>
        </div>
      `;
      Array.from(content.querySelectorAll('.keeper-kpi')).forEach((card) => {
        const labelEl = card.querySelector('.keeper-kpi-label[data-kpi-key]');
        if (!labelEl) return;
        const key = String(labelEl.getAttribute('data-kpi-key') || '').trim();
        if (!key) return;
        card.classList.toggle('selected', key === keeperSelectedKpiKey);
        card.setAttribute('role', 'button');
        card.setAttribute('tabindex', '0');
        card.addEventListener('click', () => setKeeperSelectedKpi(key));
        card.addEventListener('keydown', (ev) => {
          if (ev.key !== 'Enter' && ev.key !== ' ') return;
          ev.preventDefault();
          setKeeperSelectedKpi(key);
        });
      });
      localizeKeeperMetaLabels(content);
    }
    function openKeeperDetail(name) {
      if (!name) return;
      selectedKeeperName = String(name);
      if (compareKeeperName === selectedKeeperName) compareKeeperName = null;
      setKeeperQueryState();
      renderKeeperDetail();
      const modal = document.getElementById('keeper-detail-modal');
      if (modal) modal.classList.add('active');
    }
    function closeKeeperDetail() {
      selectedKeeperName = null;
      compareKeeperName = null;
      setKeeperQueryState();
      const modal = document.getElementById('keeper-detail-modal');
      if (modal) modal.classList.remove('active');
    }

    function keeperLifeState(keeper, thresholds) {
      const agent = (keeper && keeper.agent) ? keeper.agent : {};
      const exists = !!agent.exists;
      const keepalive = !!(keeper && keeper.keepalive_running);
      const zombie = !!agent.is_zombie;
      const lastTurnAgoS = isNum(keeper && keeper.last_turn_ago_s) ? Number(keeper.last_turn_ago_s) : null;
      const lastProactiveAgoS = isNum(keeper && keeper.last_proactive_ago_s) ? Number(keeper.last_proactive_ago_s) : null;
      const lastSeenSource = isNum(keeper && keeper.last_seen_ago_s)
        ? Number(keeper.last_seen_ago_s)
        : lastTurnAgoS;
      const nowUnix = Date.now() / 1000;

      const seriesForLiveness = Array.isArray(keeper.metrics_series) ? keeper.metrics_series : [];
      const latestSeriesTs = (() => {
        if (seriesForLiveness.length === 0) return null;
        const lastRow = seriesForLiveness[seriesForLiveness.length - 1];
        return (lastRow && isNum(lastRow.ts_unix)) ? Number(lastRow.ts_unix) : null;
      })();
      const latestSeriesAgoS = (latestSeriesTs !== null) ? Math.max(0, nowUnix - latestSeriesTs) : null;
      const recentSignal =
        (lastTurnAgoS !== null && lastTurnAgoS <= 600)
        || (lastProactiveAgoS !== null && lastProactiveAgoS <= 600)
        || (latestSeriesAgoS !== null && latestSeriesAgoS <= 600);

      let statusClass = (exists || keepalive || recentSignal) ? 'active' : 'inactive';
      let alertLevel = 'ok';
      let staleState = 'ok';
      let staleAge = null;
      const reasons = [];
      let keepaliveState = keepalive ? 'ok' : 'warn';
      if (zombie) {
        statusClass = 'dead';
        alertLevel = 'bad';
        reasons.push('zombie');
      } else {
        if (isNum(lastSeenSource)) {
          const ageText = fmtSecShort(lastSeenSource);
          staleAge = ageText;
          if (lastSeenSource >= thresholds.keeper_stale_bad_sec) {
            statusClass = 'dead';
            alertLevel = 'bad';
            staleState = 'bad';
            reasons.push(`stale ${ageText}`);
          } else if (lastSeenSource >= thresholds.keeper_stale_warn_sec) {
            statusClass = statusClass === 'dead' ? 'dead' : 'warn';
            alertLevel = alertLevel === 'bad' ? 'bad' : 'warn';
            staleState = 'warn';
            reasons.push(`stale ${ageText}`);
          }
        }
        if (!keepalive) {
          if (isNum(lastSeenSource)) {
            const ageText = fmtSecShort(lastSeenSource);
            if (lastSeenSource >= thresholds.keeper_keepalive_bad_sec) {
              statusClass = 'dead';
              alertLevel = 'bad';
              reasons.push(`keepalive off ${ageText}`);
              keepaliveState = 'bad';
            } else if (lastSeenSource >= thresholds.keeper_keepalive_warn_sec) {
              if (statusClass !== 'dead') statusClass = 'warn';
              alertLevel = alertLevel === 'bad' ? 'bad' : 'warn';
              reasons.push(`keepalive off ${ageText}`);
              keepaliveState = 'warn';
            } else {
              keepaliveState = 'warn';
            }
          } else if (statusClass === 'inactive') {
            statusClass = 'warn';
            alertLevel = 'warn';
            reasons.push('keepalive off');
            keepaliveState = 'warn';
          }
        }
      }

      return {
        statusClass,
        alertLevel,
        keepalive,
        staleState,
        staleAge,
        keepaliveState,
        exists,
        zombie,
        lastSeenAgoS: lastSeenSource,
        recentSignal,
        reasons,
      };
    }

    function updateKeepers(data) {
      const list = document.getElementById('keeper-list');
      if (!list) return;
      const keepers = normalizeKeeperPayload(data);
      if (keepers.length === 0) {
        list.innerHTML = '<div class="empty">No keepers</div>';
        return;
      }
      const alertThresholds = currentAlertThresholds();
      list.innerHTML = keepers.map(k => {
        const lifeState = keeperLifeState(k, alertThresholds);
        const statusClass = lifeState.statusClass;
        const exists = lifeState.exists;
        const zombie = lifeState.zombie;
        const keepalive = lifeState.keepalive;
        const stalePill = lifeState.staleState === 'bad'
          ? `<span class="pill bad">stale ${lifeState.staleAge || '-'}</span>`
          : (lifeState.staleState === 'warn'
              ? `<span class="pill warn">stale ${lifeState.staleAge || '-'}</span>`
              : '');

        const ctx = k.context || {};
        const ratio = ctx.context_ratio;
        const tokens = ctx.context_tokens;
        const max = ctx.context_max;
        const pct = fmtPct(ratio);
        const fillPct = isNum(ratio) ? clamp(ratio * 100, 0, 100) : 0;
        const fillClass = ctxClass(ratio);

        const keepalivePill = keepalive
          ? '<span class="pill">keepalive</span>'
          : `<span class="pill ${lifeState.keepaliveState}">no-keepalive</span>`;
        const runtimePill =
          (!exists && lifeState.recentSignal)
            ? '<span class="pill">keeper-runtime</span>'
            : '';
        const zombiePill = zombie ? '<span class="pill bad">zombie</span>' : '';
        const handoffTh = isNum(k.handoff_threshold) ? k.handoff_threshold : 0.85;
        const handoffSoon = (isNum(ratio) && isNum(handoffTh) && ratio >= handoffTh * 0.95)
          ? '<span class="pill warn">handoff-soon</span>' : '';

        const modelUsed = k.active_model || k.last_model_used || '-';
        const nextModel = k.next_model_hint || '-';
        const skillPrimaryQuick =
          (typeof k.skill_primary === 'string' && k.skill_primary.trim() !== '')
            ? k.skill_primary.trim()
            : '-';
        const skillSecondaryQuick =
          Array.isArray(k.skill_secondary)
            ? k.skill_secondary
                .filter((s) => typeof s === 'string' && s.trim() !== '')
                .map((s) => s.trim())
            : [];
        const skillQuick =
          skillSecondaryQuick.length > 0
            ? `${skillPrimaryQuick} (+${skillSecondaryQuick.join(', ')})`
            : skillPrimaryQuick;
        const soulProfile = (k.soul_profile || 'balanced');
        const willQuick = shortText(k.will, 36);
        const needsQuick = shortText(k.needs, 36);
        const desiresQuick = shortText(k.desires, 36);
        const cascade = fmtCascade(k.models);
        const gen = isNum(k.generation) ? k.generation : 0;
        const genPill = `<span class="pill">gen ${gen}</span>`;
        const contextSource = k.context_source || ctx.source || '-';

        const usage = k.last_usage || {};
        const io = (isNum(usage.input_tokens) && isNum(usage.output_tokens))
          ? `io ${usage.input_tokens}/${usage.output_tokens}`
          : '';

        const age = fmtSecShort(k.keeper_age_s);
        const last = isNum(k.last_turn_ago_s) ? (fmtSecShort(k.last_turn_ago_s) + ' ago') : 'never';
        const lastHandoffAgo = isNum(k.last_handoff_ago_s) ? (fmtSecShort(k.last_handoff_ago_s) + ' ago') : '-';
        const lastCompactionAgo = isNum(k.last_compaction_ago_s) ? (fmtSecShort(k.last_compaction_ago_s) + ' ago') : '-';
        const ctxText = (isNum(tokens) && isNum(max) && max > 0) ? `${pct} (${tokens}/${max})` : pct;
        const handoffTotal = isNum(k.handoff_count_total) ? k.handoff_count_total : 0;
        const compactionSavedLast = isNum(k.last_compaction_saved_tokens) ? k.last_compaction_saved_tokens : 0;

        const series = Array.isArray(k.metrics_series) ? k.metrics_series : [];
        const spark = sparkSvg(series, { threshold: handoffTh });
        const eta = etaTurns(series, handoffTh);
        const etaText = (eta === 0) ? 'now'
          : (isNum(eta) ? (`~${eta} turns`) : '-');
        const seriesText = series.length > 0 ? `${series.length} pts` : 'no metrics';
        const handoffPct = isNum(handoffTh) ? (Math.round(handoffTh * 100) + '%') : '-';
        const windowStats = k.metrics_window || {};
        const handoffWindow = isNum(windowStats.handoff_count) ? windowStats.handoff_count : 0;
        const compactionWindow = isNum(windowStats.compaction_events) ? windowStats.compaction_events : 0;
        const savedWindow = isNum(windowStats.compaction_saved_tokens) ? windowStats.compaction_saved_tokens : 0;
        const fallbackWindowRate = isNum(windowStats.model_fallback_rate)
          ? windowStats.model_fallback_rate
          : (isNum(windowStats.fallback_rate) ? windowStats.fallback_rate : null);
        const fallbackWindowText = fallbackWindowRate === null ? '-' : fmtPct1(fallbackWindowRate);
        const compactionEffWindow = isNum(windowStats.compaction_saved_ratio) ? windowStats.compaction_saved_ratio : null;
        const compactionEffText = compactionEffWindow === null ? '-' : fmtPct1(compactionEffWindow);
        const memoryPassWindow = isNum(windowStats.memory_pass_rate) ? windowStats.memory_pass_rate : null;
        const memoryPassText = memoryPassWindow === null ? '-' : fmtPct1(memoryPassWindow);
        const weatherPassWindow = isNum(windowStats.memory_weather_pass_rate) ? windowStats.memory_weather_pass_rate : null;
        const weatherPassText = weatherPassWindow === null ? '-' : fmtPct1(weatherPassWindow);
        const topWorkQuick = topCountName(windowStats.top_work_kinds, 'kind');
        const topToolQuick = topCountName(windowStats.top_tools, 'tool');
        const topMemoryQuick =
          k.memory_top_kind
          || topCountName(windowStats.top_memory_kinds, 'kind');
        const memoryNoteCountQuick = isNum(k.memory_note_count) ? k.memory_note_count : 0;
        const memoryCompactEventsQuick = isNum(windowStats.memory_compaction_events)
          ? windowStats.memory_compaction_events : 0;
        const memoryTrimQuick = isNum(windowStats.memory_compaction_dropped_notes)
          ? windowStats.memory_compaction_dropped_notes : 0;
        const memoryTrimRateQuick = isNum(windowStats.memory_compaction_drop_ratio)
          ? fmtPct1(windowStats.memory_compaction_drop_ratio)
          : '-';
        const turnPointsQuick = isNum(windowStats.turn_points) ? windowStats.turn_points : null;
        const proactivePointsQuick = isNum(windowStats.proactive_points) ? windowStats.proactive_points : null;
        const heartbeatPointsQuick = isNum(windowStats.heartbeat_points) ? windowStats.heartbeat_points : null;
        const proactiveFallbackQuick = isNum(windowStats.proactive_template_fallback_count)
          ? windowStats.proactive_template_fallback_count
          : (isNum(windowStats.proactive_fallback_count)
              ? windowStats.proactive_fallback_count
              : 0);
        const proactiveFallbackQuickRate = isNum(windowStats.proactive_template_fallback_rate)
          ? windowStats.proactive_template_fallback_rate
          : (isNum(windowStats.proactive_fallback_rate)
              ? windowStats.proactive_fallback_rate
              : (isNum(proactivePointsQuick) && proactivePointsQuick > 0
                  ? (proactiveFallbackQuick / proactivePointsQuick)
                  : null));
        const proactiveFallbackQuickState =
          (isNum(proactiveFallbackQuickRate) && proactiveFallbackQuickRate >= alertThresholds.proactive_fallback_bad)
            ? 'bad'
            : ((isNum(proactiveFallbackQuickRate) && proactiveFallbackQuickRate >= alertThresholds.proactive_fallback_warn) ? 'warn' : 'ok');
        const proactiveFallbackQuickClass =
          proactiveFallbackQuickState === 'bad' ? 'bad-metric'
          : (proactiveFallbackQuickState === 'warn' ? 'warn-metric' : '');
        const proactiveSimMaxQuick = isNum(windowStats.proactive_preview_similarity_max)
          ? windowStats.proactive_preview_similarity_max
          : null;
        const proactiveSimWarnQuick =
          !!windowStats.proactive_preview_similarity_warn
          || (isNum(proactiveSimMaxQuick) && proactiveSimMaxQuick >= alertThresholds.proactive_similarity_warn);
        const proactiveSimQuickState =
          (isNum(proactiveSimMaxQuick) && proactiveSimMaxQuick >= alertThresholds.proactive_similarity_bad)
            ? 'bad'
            : (proactiveSimWarnQuick ? 'warn' : 'ok');
        const proactiveSimQuickClass =
          proactiveSimQuickState === 'bad' ? 'bad-metric'
          : (proactiveSimQuickState === 'warn' ? 'warn-metric' : '');
        const proactiveSimQuickText =
          proactiveSimMaxQuick === null
            ? '-'
            : `${fmtPct1(proactiveSimMaxQuick)}${proactiveSimWarnQuick ? ' !' : ''}`;
        const pointMixText =
          (turnPointsQuick === null && proactivePointsQuick === null && heartbeatPointsQuick === null)
            ? '-'
            : `${fmtInt(turnPointsQuick)}t/${fmtInt(proactivePointsQuick)}p/${fmtInt(heartbeatPointsQuick)}h`;
        const riskQuick = handoffRiskMetrics(series, handoffTh);
        const riskQuickText = riskQuick.score === null ? '-' : (riskQuick.score + '/100');
        const lastHandoffEvent = k.last_handoff_event || {};
        const handoffTo = lastHandoffEvent.to_model || '-';
        const bornQuick = fmtIso(k.created_at);
        const k2kCountQuick = isNum(k.k2k_count) ? k.k2k_count : 0;
        const convoCountQuick = isNum(k.conversation_tail_count) ? k.conversation_tail_count : 0;
        const convoRawQuick = isNum(k.conversation_raw_count) ? k.conversation_raw_count : convoCountQuick;
        const convoFragQuick = isNum(k.conversation_fragment_count) ? k.conversation_fragment_count : 0;
        const convoFragFilteredQuick = isNum(k.conversation_fragment_filtered_count)
          ? k.conversation_fragment_filtered_count : 0;
        const convoFragFilterOnQuick = !!k.conversation_fragment_filter_enabled;
        const convoFragQuickText =
          convoFragQuick > 0
            ? `${fmtInt(convoFragQuick)}${convoFragFilterOnQuick ? ` (f${fmtInt(convoFragFilteredQuick)})` : ''}`
            : '-';
        const proactiveTotalQuick = isNum(k.proactive_count_total) ? k.proactive_count_total : 0;
        const proactiveAgoQuick = isNum(k.last_proactive_ago_s)
          ? (fmtSecShort(k.last_proactive_ago_s) + ' ago')
          : '-';
        const driftTotalQuick = isNum(k.drift_count_total) ? k.drift_count_total : 0;
        const driftWindowQuick = isNum(windowStats.drift_applied_count)
          ? windowStats.drift_applied_count
          : series.filter((p) => p && p.drift_applied).length;
        const interactionPointsQuick = (isNum(turnPointsQuick) ? turnPointsQuick : 0)
          + (isNum(proactivePointsQuick) ? proactivePointsQuick : 0);
        const driftWindowRateQuick = isNum(windowStats.drift_applied_rate)
          ? windowStats.drift_applied_rate
          : (interactionPointsQuick > 0 ? (driftWindowQuick / interactionPointsQuick) : null);
        const interventionShareQuick = isNum(windowStats.intervention_share)
          ? windowStats.intervention_share
          : (interactionPointsQuick > 0 && isNum(proactivePointsQuick)
              ? (proactivePointsQuick / interactionPointsQuick)
              : null);

        const selectedClass = (selectedKeeperName && selectedKeeperName === k.name) ? 'selected' : '';
        return `
          <div class="live-agent keeper-card ${selectedClass}" onclick="openKeeperDetail('${k.name || ''}')">
            <div class="agent-status ${statusClass}"></div>
            <div class="live-agent-main">
              <div class="live-agent-title">
                <span class="live-agent-name">${k.name || 'keeper'}</span>
                <span class="live-agent-sub">${k.agent_name || ''}</span>
                ${genPill}
                ${stalePill}
                ${keepalivePill}
                ${runtimePill}
                ${zombiePill}
                ${handoffSoon}
              </div>
              <div class="live-agent-meta">
                <span>model ${modelUsed}</span>
                <span>next ${nextModel}</span>
                <span>skill ${escHtml(shortText(skillQuick, 44))}</span>
                <span>soul ${escHtml(soulProfile)}</span>
                <span>will ${escHtml(willQuick)}</span>
                <span>needs ${escHtml(needsQuick)}</span>
                <span>desire ${escHtml(desiresQuick)}</span>
                <span>cascade ${cascade}</span>
                <span>ctx ${ctxText}</span>
                <span>src ${contextSource}</span>
                <span>${io}</span>
                <span>last ${last}</span>
                <span>age ${age}</span>
                <span>born ${escHtml(bornQuick)}</span>
                <span>handoffs ${handoffTotal}</span>
                <span>compactions ${k.compaction_count || 0}</span>
                <span>save ${compactionSavedLast}</span>
                <span>eff ${compactionEffText}</span>
                <span>mfb ${fallbackWindowText}</span>
                <span>mem ${memoryPassText}</span>
                <span>weather ${weatherPassText}</span>
                <span>notes ${fmtInt(memoryNoteCountQuick)}</span>
                <span>m-compact ${fmtInt(memoryCompactEventsQuick)}</span>
                <span>m-trim ${fmtInt(memoryTrimQuick)} (${memoryTrimRateQuick})</span>
                <span>focus ${escHtml(topMemoryQuick)}</span>
                <span>work ${escHtml(topWorkQuick)}</span>
                <span>tool ${escHtml(topToolQuick)}</span>
                <span>pts ${pointMixText}</span>
                <span${proactiveFallbackQuickClass ? ` class="${proactiveFallbackQuickClass}"` : ''}>ptfb ${fmtInt(proactiveFallbackQuick)}</span>
                <span${proactiveSimQuickClass ? ` class="${proactiveSimQuickClass}"` : ''}>psim ${proactiveSimQuickText}</span>
                <span>logs ${fmtInt(convoCountQuick)}</span>
                <span>raw ${fmtInt(convoRawQuick)}</span>
                <span>frag ${convoFragQuickText}</span>
                <span>k2k ${fmtInt(k2kCountQuick)}</span>
                <span>proactive ${fmtInt(proactiveTotalQuick)}</span>
                <span>p-last ${escHtml(proactiveAgoQuick)}</span>
                <span>drift ${fmtInt(driftTotalQuick)}</span>
                <span>d-win ${fmtInt(driftWindowQuick)} (${driftWindowRateQuick === null ? '-' : fmtPct1(driftWindowRateQuick)})</span>
                <span>intervene ${interventionShareQuick === null ? '-' : fmtPct1(interventionShareQuick)}</span>
                <span>risk ${riskQuickText}</span>
                <span>handoff ${lastHandoffAgo}</span>
                <span>compact ${lastCompactionAgo}</span>
              </div>
              <div class="ctx-bar"><div class="ctx-fill ${fillClass}" style="width:${fillPct}%"></div></div>
              <div class="ctx-spark">
                <div class="sparkline">${spark || '<div class=\"spark-empty\">no series</div>'}</div>
                <div class="spark-meta">
                  <span><b>handoff</b> ${handoffPct}</span>
                  <span><b>eta</b> ${etaText}</span>
                  <span><b>window</b> h${handoffWindow}/c${compactionWindow}/p${fmtInt(proactivePointsQuick)}</span>
                  <span><b>saved</b> ${savedWindow}</span>
                  <span><b>to</b> ${handoffTo}</span>
                  <span><b>marks</b> P/C/H</span>
                  <span>${seriesText}</span>
                </div>
              </div>
            </div>
          </div>
        `;
      }).join('');
    }

    function updatePerpetual(data) {
      const list = document.getElementById('perpetual-list');
      if (!list) return;
      const agents = (data && data.agents) ? data.agents : [];
      if (agents.length === 0) {
        list.innerHTML = '<div class="empty">No perpetual agents</div>';
        return;
      }
      list.innerHTML = agents.map(a => {
        const running = !!a.running;
        const statusClass = running ? 'active' : 'inactive';

        const ratio = a.context_ratio;
        const tokens = a.context_tokens;
        const max = a.context_max;
        const pct = fmtPct(ratio);
        const fillPct = isNum(ratio) ? clamp(ratio * 100, 0, 100) : 0;
        const fillClass = ctxClass(ratio);
        const ctxText = (isNum(tokens) && isNum(max) && max > 0) ? `${pct} (${tokens}/${max})` : pct;

        const age = fmtSecShort(a.age_s);
        const last = isNum(a.last_turn_ago_s) ? (fmtSecShort(a.last_turn_ago_s) + ' ago') : 'never';

        const usage = a.last_usage || {};
        const io = (isNum(usage.input_tokens) && isNum(usage.output_tokens))
          ? `io ${usage.input_tokens}/${usage.output_tokens}`
          : '';

        const cascade = Array.isArray(a.model_cascade)
          ? fmtCascade(a.model_cascade.map(m => (m.provider ? (m.provider + ':' + m.model_id) : m.model_id)))
          : '-';

        const gen = isNum(a.generation) ? a.generation : 0;
        const genPill = gen > 0 ? `<span class="pill warn">gen ${gen}</span>` : `<span class="pill">gen 0</span>`;

        return `
          <div class="live-agent">
            <div class="agent-status ${statusClass}"></div>
            <div class="live-agent-main">
              <div class="live-agent-title">
                <span class="live-agent-name">${(a.trace_id || 'trace').slice(0, 24)}</span>
                <span class="live-agent-sub">${a.last_model_used || ''}</span>
                ${genPill}
              </div>
              <div class="live-agent-meta">
                <span>running ${running ? 'yes' : 'no'}</span>
                <span>turns ${a.turn_count || 0}</span>
                <span>ctx ${ctxText}</span>
                <span>${io}</span>
                <span>last ${last}</span>
                <span>age ${age}</span>
                <span>cost $${isNum(a.total_cost_usd) ? a.total_cost_usd.toFixed(4) : '0.0000'}</span>
                <span>cascade ${cascade}</span>
              </div>
              <div class="ctx-bar"><div class="ctx-fill ${fillClass}" style="width:${fillPct}%"></div></div>
            </div>
          </div>
        `;
      }).join('');
    }

    function updateTempo(status) {
      // Convert tempo_interval_s to mode: <120s=fast, <400s=normal, else=slow
      const interval = status.tempo_interval_s || 300;
      let mode = 'normal';
      if (status.paused) mode = 'paused';
      else if (interval < 120) mode = 'fast';
      else if (interval > 400) mode = 'slow';
      tempoBadge.className = 'tempo-badge ' + mode;
      tempoBadge.textContent = mode.charAt(0).toUpperCase() + mode.slice(1) + ' (' + Math.round(interval) + 's)';
    }

    // === Toast notifications ===
    function showToast(message, type = 'info') {
      const container = document.getElementById('toast-container');
      const toast = document.createElement('div');
      toast.className = 'toast ' + type;
      toast.textContent = message;
      container.appendChild(toast);
      setTimeout(() => toast.remove(), 4000);
    }

    function keeperAlertState(keeper, thresholds) {
      const life = keeperLifeState(keeper, thresholds);
      const ws = (keeper && keeper.metrics_window) ? keeper.metrics_window : {};
      const reasons = life.reasons.map((r) => `life ${r}`);
      let level = life.alertLevel;
      const fallbackRate = isNum(ws.proactive_template_fallback_rate)
        ? Number(ws.proactive_template_fallback_rate)
        : (isNum(ws.proactive_fallback_rate) ? Number(ws.proactive_fallback_rate) : null);
      const similarityMax = isNum(ws.proactive_preview_similarity_max)
        ? Number(ws.proactive_preview_similarity_max)
        : null;
      const similarityWarn = !!ws.proactive_preview_similarity_warn;

      if (isNum(fallbackRate)) {
        if (fallbackRate >= thresholds.proactive_fallback_bad) {
          level = 'bad';
          reasons.push(`template-fallback ${fmtPct1(fallbackRate)}`);
        } else if (fallbackRate >= thresholds.proactive_fallback_warn) {
          if (level !== 'bad') level = 'warn';
          reasons.push(`template-fallback ${fmtPct1(fallbackRate)}`);
        }
      }
      if (isNum(similarityMax)) {
        if (similarityMax >= thresholds.proactive_similarity_bad) {
          level = 'bad';
          reasons.push(`similarity ${fmtPct1(similarityMax)}`);
        } else if (similarityMax >= thresholds.proactive_similarity_warn || similarityWarn) {
          if (level !== 'bad') level = 'warn';
          reasons.push(`similarity ${fmtPct1(similarityMax)}`);
        }
      } else if (similarityWarn) {
        if (level !== 'bad') level = 'warn';
        reasons.push('similarity warn');
      }
      return { level, reasons, fallbackRate, similarityMax };
    }

    function notifyKeeperAlerts(keepersPayload) {
      const keepers = normalizeKeeperPayload(keepersPayload);
      const thresholds = currentAlertThresholds();
      const cooldownMs = thresholds.toast_cooldown_sec * 1000;
      const now = Date.now();
      const activeNames = new Set();

      keepers.forEach((keeper) => {
        if (!keeper || !keeper.name) return;
        const name = String(keeper.name);
        activeNames.add(name);
        const st = keeperAlertState(keeper, thresholds);
        const signature = `${st.level}|${st.reasons.join('|')}`;
        const prev = keeperAlertMemory.get(name) || { level: 'ok', signature: '', lastToastMs: 0 };
        let nextLastToastMs = prev.lastToastMs || 0;

        if (st.level === 'ok') {
          if (prev.level !== 'ok') {
            showToast(`[OK] ${name} recovered`, 'success');
          }
        } else {
          const shouldToast =
            prev.level !== st.level
            || prev.signature !== signature
            || ((now - (prev.lastToastMs || 0)) >= cooldownMs);
          if (shouldToast) {
            const reasonText = st.reasons.length > 0 ? st.reasons.join(', ') : 'risk detected';
            const prefix = st.level === 'bad' ? '[BAD]' : '[WARN]';
            showToast(`${prefix} ${name}: ${reasonText}`, st.level === 'bad' ? 'error' : 'warning');
            nextLastToastMs = now;
          }
        }
        keeperAlertMemory.set(name, {
          level: st.level,
          signature,
          lastToastMs: nextLastToastMs,
        });
      });

      Array.from(keeperAlertMemory.keys()).forEach((name) => {
        if (!activeNames.has(name)) keeperAlertMemory.delete(name);
      });
    }|}
