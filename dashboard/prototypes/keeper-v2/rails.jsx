/* MASC v2 — Roster rail (left) and Context rail (right) */
const { useState: useStateP, useEffect: useEffectP, useRef: useRefP } = React;

// live tok/s throughput card with selectable time range + rolling sparkline
function makeTpsSeries(base, n, variance) {
  const out = [];
  for (let i = 0; i < n; i++) {
    const wob = Math.sin(i * 0.6) * 0.4 + (Math.random() - 0.5);
    out.push(Math.max(6, Math.round(base + wob * base * variance)));
  }
  return out;
}

const TPS_RANGES = [['15m', 30, 0.16], ['1h', 30, 0.10], ['6h', 30, 0.06]];

function RailTps({ keeper }) {
  const live = keeper.status === 'run';
  const base = keeper.tps;
  const [range, setRange] = useStateP('15m');
  const [v, setV] = useStateP(base);
  const [hist, setHist] = useStateP(() => makeTpsSeries(base || 0, 30, 0.16));

  useEffectP(() => {
    const cfg = TPS_RANGES.find(r => r[0] === range);
    setHist(live ? makeTpsSeries(base, cfg[1], cfg[2]) : Array(cfg[1]).fill(0));
    setV(live ? base : 0);
    if (!live || range !== '15m') return;
    const id = setInterval(() => {
      const next = Math.max(8, Math.round(base + (Math.random() * 2 - 1) * base * 0.16));
      setV(next);
      setHist(h => [...h.slice(1), next]);
    }, 1100);
    return () => clearInterval(id);
  }, [keeper.id, keeper.status, base, range]);

  const peak = Math.max(1, ...hist);
  const avg = live ? Math.round(hist.reduce((a, b) => a + b, 0) / hist.length) : 0;

  return (
    <div className="tps-card">
      <div className="tps-now">
        <span className={`tps-val ${live ? '' : 'idle'}`}>{live ? v : '—'}</span>
        <span className="tps-unit">tok/s</span>
        {live && <span className="tps-flag"><span className="tps-dot"></span>live</span>}
      </div>
      <div className="tps-ranges">
        {TPS_RANGES.map(([r]) => (
          <button key={r} className={`tps-range ${range === r ? 'on' : ''}`} onClick={() => setRange(r)}>{r}</button>
        ))}
        <span className="tps-avg">{live ? `평균 ${avg}` : '유휴'}</span>
      </div>
      <div className="tps-spark" title={`런타임 ${keeper.runtime}`}>
        {hist.map((h, i) => <span key={i} style={{ height: (8 + (h / peak) * 92) + '%', opacity: live ? (0.3 + 0.7 * (i / hist.length)) : 0.15 }}></span>)}
      </div>
    </div>
  );
}

// current keeper's runtime capability readout (multimodal? effort adjustable?)
function RailRuntime({ keeper }) {
  const cap = window.rtCaps ? window.rtCaps(keeper.runtime) : null;
  const [effort, setEffort] = useStateP('medium');
  const [open, setOpen] = useStateP(false);  // collapsed to just the runtime name by default
  if (!cap) return (
    <div className="rtc-card">
      <div className="rtc-head"><span className="rtc-id mono">{keeper.runtime}</span></div>
      <div className="rtc-na">능력 정보 없음</div>
    </div>
  );
  const m = cap.model;
  return (
    <div className={`rtc-card ${open ? 'open' : ''}`}>
      <button className="rtc-head" onClick={() => setOpen(o => !o)} title={open ? '접기' : '런타임 상세 펼치기'}>
        <span className="rtc-id mono">{cap.runtimeId}</span>
        <span className="rtc-chev">{'\u25B8'}</span>
      </button>
      {open && (
        <div className="rtc-detail">
          <div className="rtc-model mono">{m.api_name}</div>
          <div className="rtc-spec mono">최대 컨텍스트 {(m.max_context / 1000).toFixed(0)}k · 최대 출력 {m.caps && m.caps.maxOut ? (m.caps.maxOut / 1000).toFixed(0) + 'k' : '—'}</div>
          <div className="rtc-spec mono">샘플링 temp 0.3 · top_p 0.95 · max_tokens 4,096</div>
          <div className="rtc-flags">
            <span className={`rtc-flag ${cap.multimodal ? 'on' : 'off'}`}>{cap.multimodal ? '✓' : '✕'} multimodal</span>
            <span className={`rtc-flag ${cap.json ? 'on' : 'off'}`}>{cap.json ? '✓' : '✕'} json</span>
            <span className={`rtc-flag ${m.caps.toolChoice ? 'on' : 'off'}`}>{m.caps.toolChoice ? '✓' : '✕'} tool-choice</span>
          </div>
          <div className="rtc-effort">
            <span className="rtc-effort-k">effort</span>
            {cap.effortAdjustable
              ? <div className="rtc-eff-seg">{['low', 'medium', 'high'].map(e => <button key={e} className={`rtc-eff ${effort === e ? 'on' : ''}`} onClick={() => setEffort(e)}>{e}</button>)}</div>
              : <span className="rtc-eff-na" title={`thinking-control-format = ${cap.effortMode}`}>조정 불가 · {window.RT_TCF[cap.effortMode] || cap.effortMode}</span>}
          </div>
        </div>
      )}
    </div>
  );
}

// persistent width (localStorage) + a drag handle, shared by board/IDE rails
function usePersistentW(key, def) {
  const [w, setW] = useStateP(() => { const v = +(typeof localStorage !== 'undefined' && localStorage.getItem(key)); return v || def; });
  const set = (nv) => { setW(nv); try { localStorage.setItem(key, String(nv)); } catch (e) {} };
  return [w, set];
}
function ColResizer({ getW, onResize, min, max }) {
  const start = (e) => {
    e.preventDefault();
    const startX = e.clientX; const startW = getW();
    document.body.classList.add('rail-resizing');
    const move = (ev) => onResize(Math.max(min, Math.min(max, startW + (ev.clientX - startX))));
    const up = () => { document.body.classList.remove('rail-resizing'); window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up); };
    window.addEventListener('pointermove', move); window.addEventListener('pointerup', up);
  };
  return <div className="col-resizer" onPointerDown={start} title="드래그하여 폭 조절"></div>;
}

function groupCls(g) {
  if (g === '실행 중') return 'run';
  if (g === '대기 · 일시정지') return 'pause';
  return 'off';
}
// concise display label for roster group headers (keys stay verbose for grouping)
function groupLabel(g) {
  if (g === '실행 중') return '실행 중';
  if (g === '대기 · 일시정지') return '대기';
  if (g === '중지 · 종료됨') return '중지';
  return g;
}

function fsmGroupOf(k) {
  if (k.status === 'run') return '실행 중';
  if (k.status === 'pause') return '대기 · 일시정지';
  return '중지 · 종료됨';
}

function Roster({ keepers, selected, onSelect, mini, onConfig, onAction }) {
  const [q, setQ] = useStateP('');
  const [searchOpen, setSearchOpen] = useStateP(false);
  const [peek, setPeek] = useStateP(false);
  const [filter, setFilter] = useStateP('all');
  const [sort, setSort] = useStateP('status');
  const [menu, setMenu] = useStateP(null); // { keeper, x, y }
  const [hover, setHover] = useStateP(null); // mini-roster identity flyout
  const [bcast, setBcast] = useStateP(false); // 전체 브로드캐스트 작성기

  useEffectP(() => {
    if (!menu) return;
    const close = () => setMenu(null);
    const esc = (e) => { if (e.key === 'Escape') setMenu(null); };
    window.addEventListener('click', close);
    window.addEventListener('scroll', close, true);
    window.addEventListener('keydown', esc);
    return () => { window.removeEventListener('click', close); window.removeEventListener('scroll', close, true); window.removeEventListener('keydown', esc); };
  }, [menu]);

  const openMenu = (e, k) => {
    e.preventDefault();
    e.stopPropagation();
    const x = Math.min(e.clientX, window.innerWidth - 196);
    const y = Math.min(e.clientY, window.innerHeight - 230);
    setMenu({ keeper: k, x, y });
  };

  const counts = {
    all: keepers.length,
    run: keepers.filter(k => k.status === 'run').length,
    att: keepers.filter(k => k.att > 0).length,
  };

  let list = keepers.filter(k => {
    if (filter === 'run' && k.status !== 'run') return false;
    if (filter === 'att' && k.att === 0) return false;
    if (q && !(`${k.id} ${k.kr} ${k.cwd} ${k.model}`.toLowerCase().includes(q.toLowerCase()))) return false;
    return true;
  });

  // group by status (default) — or a flat sorted list for name / attention
  let order, groups;
  if (sort === 'status') {
    order = ['실행 중', '대기 · 일시정지', '중지 · 종료됨'];
    groups = {};
    list.forEach(k => { (groups[fsmGroupOf(k)] = groups[fsmGroupOf(k)] || []).push(k); });
  } else {
    const sorted = [...list].sort((a, b) =>
      sort === 'name' ? a.id.localeCompare(b.id)
        : /* att */ (b.att - a.att) || a.id.localeCompare(b.id));
    order = [''];
    groups = { '': sorted };
  }

  // one keeper row — shared by the normal and windowed render paths
  const renderKeeper = (k) => (
    <div key={k.id} className={`kp-row ${selected === k.id ? 'sel' : ''}`} onClick={() => onSelect(k.id)} onContextMenu={(e) => openMenu(e, k)} onMouseEnter={(e) => { if (mini) { const r = e.currentTarget.getBoundingClientRect(); setHover({ k, x: r.right, y: r.top + r.height / 2 }); } }} onMouseLeave={() => setHover(null)} style={{ contentVisibility: 'auto', containIntrinsicSize: 'auto 58px' }}>
      <SigilBadge k={k} size={38} beat={!!(window.PHASE_PULSE && PHASE_PULSE[k.phase])} />
      <div className="kp-meta">
        <div className="kp-name">{k.id}</div>
        <div className="kp-sub">
          <span className="kp-state"><StatusDot status={(window.PHASE_TONE && PHASE_TONE[k.phase]) || 'idle'} pulse={!!(window.PHASE_PULSE && PHASE_PULSE[k.phase])} />{k.phase}</span>
          {k.sandbox && <span className="kp-sandbox" title="이 keeper 전용 작업 폴더 — git worktree 로 갈라 놔서 다른 keeper 와 파일이 섞이지 않습니다 (OS·컨테이너 샌드박스는 아님)">⬡</span>}
        </div>
      </div>
      <div className="kp-right">
        <span className="kp-time">{k.last}</span>
        {k.att > 0 && <span className="kp-att" title={`주의 ${k.att}건 — 컨텍스트 레일에서 확인`}>{'\u25B2'} {k.att}</span>}
      </div>
      <button className="kp-more" title="명령 메뉴" onClick={(e) => openMenu(e, k)}>⋯</button>
    </div>
  );

  // flatten groups → [{t:'h'|'r', ...}] for windowing
  const flat = [];
  order.filter(g => groups[g]).forEach(g => {
    if (g) flat.push({ t: 'h', g });
    groups[g].forEach(k => flat.push({ t: 'r', k }));
  });
  // window only when the roster is long enough to matter (keeps DOM
  // structure identical for the common small case → zero regression)
  const WINDOW_AT = 60;
  const windowed = flat.length > WINDOW_AT && window.KVP && window.KVP.VirtualList;
  const ROW_H = 58, HEAD_H = 30;

  // mini rail expands to full content on hover (Notion-style peek)
  const compact = mini && !peek;

  return (
    <aside className={`roster ${mini ? 'mini' : ''} ${peek ? 'peek' : ''}`}
      onMouseEnter={mini ? () => setPeek(true) : undefined}
      onMouseLeave={mini ? () => { setPeek(false); setHover(null); } : undefined}>
      <div className="roster-filters">
        {[['all', '전체'], ['run', '실행'], ['att', '주의']].map(([key, lbl]) => (
          <button key={key} className={`rfilter ${filter === key ? 'on' : ''}`} onClick={() => setFilter(key)}>
            {lbl}<span className="n">{counts[key]}</span>
          </button>
        ))}
        <button className={`rfilter-icon ${searchOpen ? 'on' : ''}`} title="검색" onClick={() => { setSearchOpen(v => !v); if (searchOpen) setQ(''); }}>{'\u2315'}</button>
        <button className="rfilter-icon" title="전체 브로드캐스트 — 모든 keeper에게 동일 메시지" onClick={() => setBcast(true)}>{'\u229A'}</button>
        <select className="roster-sort" value={sort} onChange={e => setSort(e.target.value)} title="정렬 기준">
          <option value="status">상태순</option>
          <option value="name">이름순</option>
          <option value="att">주의순</option>
        </select>
      </div>
      {searchOpen && (
        <div className="roster-head">
          <input className="roster-search" placeholder="이름·모델 검색…" value={q} onChange={e => setQ(e.target.value)} autoFocus />
        </div>
      )}
      {windowed ? (
        <window.KVP.VirtualList
          className="roster-list"
          items={flat}
          rowHeight={(it) => (it.t === 'h' ? HEAD_H : ROW_H)}
          getKey={(it) => (it.t === 'h' ? 'h:' + it.g : it.k.id)}
          renderRow={(it) => (it.t === 'h' ? <div className={`roster-group ${groupCls(it.g)}`}><span className="rg-dot"></span>{groupLabel(it.g)}<span className="rg-n">{(groups[it.g] || []).length}</span></div> : renderKeeper(it.k))}
        />
      ) : (
        <div className="roster-list">
          {order.filter(g => groups[g]).map(g => (
            <div key={g}>
              <div className={`roster-group ${groupCls(g)}`} title={g}>{compact ? groups[g].length : <React.Fragment><span className="rg-dot"></span>{groupLabel(g)}<span className="rg-n">{groups[g].length}</span></React.Fragment>}</div>
              {groups[g].map(renderKeeper)}
            </div>
          ))}
          {!list.length && <div style={{ padding: '30px 12px', textAlign: 'center', color: 'var(--text-dim)', fontSize: '12px' }}>일치하는 Keeper가 없습니다</div>}
        </div>
      )}
      {hover && compact && (
        <div className="kp-flyout" style={{ left: hover.x + 10, top: hover.y }}>
          <div className="kpf-h">
            <SigilBadge k={hover.k} size={26} />
            <div className="kpf-id">
              <div className="kpf-name">{hover.k.id}</div>
              <div className="kpf-phase"><StatusDot status={(window.PHASE_TONE && PHASE_TONE[hover.k.phase]) || 'idle'} />{hover.k.phase}</div>
            </div>
          </div>
          <div className="kpf-row"><span className="kpf-k">작업 폴더</span><span className="mono">{hover.k.sandbox ? `${hover.k.sandbox} 격리` : '—'}</span></div>
          <div className="kpf-row"><span className="kpf-k">런타임</span><span className="mono">{hover.k.runtime}</span></div>
          {hover.k.att > 0 && <div className="kpf-att">{'\u26A0'} 주의 {hover.k.att}건</div>}
        </div>
      )}
      {bcast && <BroadcastComposer keepers={keepers} onClose={() => setBcast(false)} />}
      {menu && (
        <div className="kp-menu" style={{ left: menu.x, top: menu.y }} onClick={(e) => e.stopPropagation()}>
          <div className="kp-menu-h"><SigilBadge k={menu.keeper} size={20} /><span className="mono">{menu.keeper.id}</span></div>
          <button className="kp-menu-i" onClick={() => { onSelect(menu.keeper.id); setMenu(null); }}>{'\u25C8'} 대화 열기</button>
          {((window.FSM_ACTIONS && FSM_ACTIONS[menu.keeper.phase]) || []).map(a => (
            <button key={a.id} className={`kp-menu-i ${a.danger ? 'danger' : ''}`} onClick={() => { onAction && onAction(menu.keeper.id, a); setMenu(null); }}>{a.glyph} {a.label}</button>
          ))}
          {!((window.FSM_ACTIONS && FSM_ACTIONS[menu.keeper.phase]) || []).length && <div className="kp-menu-note">{menu.keeper.phase === 'Dead' ? '복구 불가 — 명령 없음' : '전이 중 — 잠시 후'}</div>}
          <div className="kp-menu-sep"></div>
          <button className="kp-menu-i" onClick={() => { onConfig && onConfig(menu.keeper); setMenu(null); }}>{'\u2699'} keeper 설정</button>
        </div>
      )}
    </aside>
  );
}

// 전체 브로드캐스트 작성기 — masc_broadcast: operator가 여러 keeper에게 동일 메시지 발신
function BroadcastComposer({ keepers, onClose }) {
  const [scope, setScope] = useStateP('all');
  const [via, setVia] = useStateP('discord');
  const [msg, setMsg] = useStateP('');
  useEffectP(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  const SCOPES = [
    ['all', '전체', () => true],
    ['run', '실행 중만', k => k.status === 'run'],
    ['att', '주의 필요', k => k.att > 0],
  ];
  const VIAS = [
    ['discord', 'discord-gate · #broadcast'],
    ['board', 'board 공지'],
    ['direct', 'direct mention'],
  ];
  const scopeDef = SCOPES.find(s => s[0] === scope) || SCOPES[0];
  const viaDef = VIAS.find(v => v[0] === via) || VIAS[0];
  const recipients = keepers.filter(scopeDef[2]);
  const send = () => {
    if (!msg.trim() || !recipients.length) return;
    if (window.pushToast) window.pushToast({ tone: 'ok', msg: `${recipients.length} keeper에게 브로드캐스트`, sub: `masc_broadcast · ${scopeDef[1]} · ${viaDef[1]}` });
    onClose();
  };
  return (
    <div className="turn-overlay" onClick={onClose}>
      <div className="turn-drawer bcc-drawer" onClick={(e) => e.stopPropagation()}>
        <div className="turn-hd">
          <h3>전체 브로드캐스트</h3>
          <span className="tid mono">masc_broadcast</span>
          <span style={{ marginLeft: 'auto' }}></span>
          <button className="turn-close" onClick={onClose} title="닫기 (Esc)">{'\u2715'}</button>
        </div>
        <div className="turn-body">
          <div className="turn-sec">
            <h4>수신 범위</h4>
            <div className="bcc-seg">
              {SCOPES.map(([id, lbl, fn]) => (
                <button key={id} className={`bcc-opt ${scope === id ? 'on' : ''}`} onClick={() => setScope(id)}>{lbl}<span className="mono">{keepers.filter(fn).length}</span></button>
              ))}
            </div>
            <div className="bcc-recips">
              {recipients.length === 0
                ? <span className="bcc-empty mono">대상 keeper 없음</span>
                : recipients.map(k => <span key={k.id} className="bcc-chip"><SigilBadge k={k} size={16} /><span className="mono">{k.id}</span></span>)}
            </div>
          </div>
          <div className="turn-sec">
            <h4>경로 · via</h4>
            <div className="bcc-seg wrap">
              {VIAS.map(([id, lbl]) => (<button key={id} className={`bcc-opt ${via === id ? 'on' : ''}`} onClick={() => setVia(id)}>{lbl}</button>))}
            </div>
          </div>
          <div className="turn-sec">
            <h4>메시지 · 모든 대상에게 동일</h4>
            <textarea className="bcc-text" placeholder="모든 대상 keeper에게 전달할 동일 메시지…" value={msg} onChange={(e) => setMsg(e.target.value)} autoFocus rows={4}></textarea>
            <div className="bcc-hint mono">keeper는 board에서 broadcast를 읽고 ack합니다 · 비가역 행동 지시는 승인 큐를 거칩니다</div>
          </div>
          <div className="turn-sec bcc-actions">
            <button className="bcc-send" disabled={!msg.trim() || !recipients.length} onClick={send}>{'\u229A'} {recipients.length}명에게 보내기</button>
            <button className="sch-act ghost" onClick={onClose}>취소</button>
          </div>
        </div>
      </div>
    </div>
  );
}

function CmpStat({ label, a, b, unit, max }) {
  const pa = Math.min(100, (a / max) * 100);
  const pb = Math.min(100, (b / max) * 100);
  const fmt = (n) => unit === 'k' ? (n >= 1000 ? (n / 1000).toFixed(1) + 'k' : n) : n;
  return (
    <div className="cmp-stat">
      <div className="cmp-stat-k">{label}</div>
      <div className="cmp-bars">
        <div className="cmp-line"><span className="t">이전</span><b className="v">{fmt(a)}</b></div>
        <div className="cmp-bar before"><span style={{ width: pa + '%' }}></span></div>
        <div className="cmp-line"><span className="t">이후</span><b className="v ok">{fmt(b)}</b></div>
        <div className="cmp-bar after"><span style={{ width: pb + '%' }}></span></div>
      </div>
    </div>
  );
}

function cmpFullCtx(ev, side) {
  const m = side === 'before' ? ev.before : ev.after;
  const head = `# 주입 컨텍스트 — ${side === 'before' ? '압축 전' : '압축 후'}\n# ${m.msgs} messages · ${m.traces} traces · ${(m.tok / 1000).toFixed(1)}k tokens\n# runtime ${ev.runtime}\n`;
  const kept = '\n## 유지 (그대로 보존)\n' + ev.kept.map(x => '  • ' + x).join('\n');
  if (side === 'before') {
    return head + kept
      + '\n\n## 원본 — 요약 전 전체 로그\n' + ev.summarized.map(x => '  • ' + x.split('→')[0].trim() + ' — [원본 전체 보존]').join('\n')
      + '\n' + ev.dropped.map(x => '  • ' + x + ' — [전체 보존]').join('\n');
  }
  return head + kept
    + '\n\n## 요약본 (모델 생성)\n' + ev.summarized.map(x => '  • ' + x).join('\n')
    + '\n\n## 폐기됨 (컨텍스트에서 제거)\n' + ev.dropped.map(x => '  • ' + x).join('\n');
}

function CompactionInspector({ keeper, onClose }) {
  const events = (window.COMPACTIONS && COMPACTIONS[keeper.id]) || [];
  const [idx, setIdx] = useStateP(0);
  const [side, setSide] = useStateP('after');
  const [rolledBack, setRolledBack] = useStateP(null);  // event id with a pending rollback (mockup)
  useEffectP(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  const ev = events[idx];
  const reduction = ev ? Math.round((1 - ev.after.tok / ev.before.tok) * 100) : 0;
  // how far the window regrew after this compaction — to 'now' for the latest
  // snapshot, or to the point just before the next compaction for older ones.
  // 이후 재증가 = 다음 압축 직전 관측값만. 최신 스냅샷은 현재 점유율을 알 수 없음
  // (occupancy = not_observed) — 관측된 다음 기준이 없으므로 그대로 표기한다.
  const regrewTo = ev && idx > 0 ? events[idx - 1].before.tok : null;
  const regrowLbl = idx === 0 ? '다음 압축 전까지 남은 기록 없음' : `다음 압축 직전 (${events[idx - 1] ? events[idx - 1].at : ''})`;
  const doRollback = () => {
    setRolledBack(ev.id);
    if (window.pushToast) window.pushToast({ tone: 'warn', msg: `컴팩션 롤백 · ${keeper.id}`, sub: `${ev.at} 지점 — 압축 전 ${(ev.before.tok / 1000).toFixed(1)}k 컨텍스트로 복원 예약`, undo: () => setRolledBack(null) });
  };

  return (
    <div className="turn-overlay" onClick={onClose}>
      <div className="turn-drawer" onClick={(e) => e.stopPropagation()}>
        <div className="turn-hd">
          <h3>컴팩션 스냅샷</h3>
          <span className="tid">{keeper.id}</span>
          <button className="turn-close" onClick={onClose} title="닫기 (Esc)">{'\u2715'}</button>
        </div>

        {events.length === 0 ? (
          <div className="turn-body"><div className="cmp-empty">아직 이 keeper에서 실행된 컴팩션이 없습니다.<br />provider overflow 복구나 owner-lane 실행 시 <span className="mono">Compaction_started</span> 이벤트로 기록됩니다.</div></div>
        ) : (
          <React.Fragment>
            <div className="turn-tabs">
              {events.map((e, i) => (
                <button key={e.id} className={`turn-tab ${idx === i ? 'on' : ''}`} onClick={() => setIdx(i)}>
                  {e.at} <span className="mono" style={{ opacity: 0.6 }}>{e.id}</span>
                </button>
              ))}
            </div>
            <div className="turn-body">
              <div className="cmp-trigger"><span className="sub-k">트리거</span>{ev.trigger}</div>
              <div className="cmp-trigger"><span className="sub-k">압축 수행 모델</span><span className="mono">{ev.runtime}</span></div>
              <div className="cmp-rollback-row">
                {rolledBack === ev.id
                  ? <span className="cmp-rolled">{'\u21A9'} 롤백 예약됨 · 압축 전 {(ev.before.tok / 1000).toFixed(1)}k 컨텍스트로 복원</span>
                  : <button className="cmp-rollback" onClick={doRollback} title="이 압축을 되돌려 압축 전 컨텍스트를 복원">
                      {'\u21A9'} 이 지점으로 롤백<span className="cmp-rollback-sub">압축 전 {(ev.before.tok / 1000).toFixed(1)}k 상태 복원</span>
                    </button>}
              </div>

              <div className="turn-sec">
                <h4>Before → After</h4>
                <div className="cmp-headline">
                  <span className="mono">{(ev.before.tok / 1000).toFixed(1)}k</span>
                  <span className="cmp-arrow">{'\u2192'}</span>
                  <span className="mono" style={{ color: 'var(--status-ok)' }}>{(ev.after.tok / 1000).toFixed(1)}k</span>
                  <span className="cmp-reduce">{'\u2212'}{reduction}%</span>
                </div>
                <CmpStat label="토큰" a={ev.before.tok} b={ev.after.tok} unit="k" max={200000} />
                <CmpStat label="메시지" a={ev.before.msgs} b={ev.after.msgs} max={Math.max(ev.before.msgs, 1)} />
                <CmpStat label="trace" a={ev.before.traces} b={ev.after.traces} max={Math.max(ev.before.traces, 1)} />
                <div className="cmp-regrow">
                  <span className="sub-k">이후 재증가</span>
                  <span className="mono">{(ev.after.tok / 1000).toFixed(1)}k</span>
                  {regrewTo != null && <React.Fragment><span className="cmp-arrow">{'\u2192'}</span><span className="mono cmp-regrow-now">{(regrewTo / 1000).toFixed(1)}k</span></React.Fragment>}
                  <span className="cmp-regrow-lbl">{regrowLbl}</span>
                </div>
              </div>

              <div className="turn-sec">
                <h4>유지 · 요약 · 폐기</h4>
                <div className="cmp-diff">
                  <div className="cmp-col kept">
                    <div className="cmp-col-h">{'\u25C8'} 유지</div>
                    {ev.kept.map((x, i) => <div key={i} className="cmp-li">{x}</div>)}
                  </div>
                  <div className="cmp-col summ">
                    <div className="cmp-col-h">{'\u25C9'} 요약</div>
                    {ev.summarized.map((x, i) => <div key={i} className="cmp-li">{x}</div>)}
                  </div>
                  <div className="cmp-col drop">
                    <div className="cmp-col-h">{'\u25CC'} 폐기</div>
                    {ev.dropped.map((x, i) => <div key={i} className="cmp-li">{x}</div>)}
                  </div>
                </div>
              </div>
              <div className="turn-sec">
                <h4>전체 컨텍스트 (실제 프롬프트)</h4>
                <div className="cmp-side-toggle">
                  <button className={`cmp-side ${side === 'before' ? 'on' : ''}`} onClick={() => setSide('before')}>압축 전 · {(ev.before.tok / 1000).toFixed(1)}k</button>
                  <button className={`cmp-side ${side === 'after' ? 'on' : ''}`} onClick={() => setSide('after')}>압축 후 · {(ev.after.tok / 1000).toFixed(1)}k</button>
                </div>
                <pre className="turn-pre cmp-ctx-pre">{cmpFullCtx(ev, side)}</pre>
              </div>
            </div>
          </React.Fragment>
        )}
      </div>
    </div>
  );
}

function RecentTool({ t }) {
  const [open, setOpen] = useStateP(false);
  const hasDetail = t.args || t.result;
  return (
    <div className={`ctx-item-wrap ${open ? 'open' : ''}`}>
      <div className={`ctx-item ${hasDetail ? 'click' : ''}`} onClick={() => hasDetail && setOpen(o => !o)}>
        <StatusDot status={t.status === 'ok' ? 'run' : t.status === 'bad' ? 'bad' : 'run'} />
        <span className="ci-name">{t.name}</span>
        <span className="ci-meta">{t.dur} · {t.ago}</span>
        {hasDetail && <span className="ci-chev">{'\u25B8'}</span>}
      </div>
      {open && hasDetail && (
        <div className="ci-detail">
          {t.args && <React.Fragment><div className="tk">args</div><pre>{JSON.stringify(t.args, null, 2)}</pre></React.Fragment>}
          {t.result && <React.Fragment><div className="tk">result</div><pre>{t.result}</pre></React.Fragment>}
        </div>
      )}
    </div>
  );
}

function ContextRail({ keeper, onAction, onNav }) {
  const tasks = OWNED_TASKS[keeper.id] || [];
  const evq = window.keeperQueue ? window.keeperQueue(keeper.id) : null;
  const EK = window.EVENT_KIND || {};
  const att = ATTENTION[keeper.id] || [];
  const cmps = (window.COMPACTIONS && COMPACTIONS[keeper.id]) || [];
  const mem = window.getKeeperMemory ? window.getKeeperMemory(keeper) : { store: [], episodes: [] };
  const [cmpOpen, setCmpOpen] = useStateP(false);
  const [memOpen, setMemOpen] = useStateP(false);
  const [confirmCompact, setConfirmCompact] = useStateP(false);
  const [tpsOpen, setTpsOpen] = useStateP(false);  // throughput card hidden by default
  const [ctxLive, setCtxLive] = useStateP(null);   // post-manual-compact override (0..1)
  const [compacting, setCompacting] = useStateP(false);
  const [justRan, setJustRan] = useStateP(false);
  useEffectP(() => { setCmpOpen(false); setMemOpen(false); setCtxLive(null); setCompacting(false); setJustRan(false); setConfirmCompact(false); }, [keeper.id]);

  const effCtx = ctxLive != null ? ctxLive : keeper.ctx;
  // provider 가 보고한 마지막 턴 usage 만 남음. 현재 점유율은 관측되지 않으므로
  // (typed not_observed) 게이지와 자동 compact 임계선 마컛은 삭제되었다.
  const usageMem = window.KEEPER_MEMORY && window.KEEPER_MEMORY[keeper.id] && window.KEEPER_MEMORY[keeper.id].usage;
  const ctxWindow = (usageMem && usageMem.context_window) || 200000;
  const lastIn = ctxLive != null ? Math.round(ctxLive * ctxWindow) : (usageMem ? usageMem.input_tokens : (keeper.ctx ? Math.round(keeper.ctx * ctxWindow) : null));

  const runCompact = () => {
    if (compacting) return;
    setCompacting(true);
    // also drive the keeper FSM (Running/Overflowed → Compacting → back) so the
    // header pill reflects the manual compaction while it runs.
    const compactAct = ((window.FSM_ACTIONS && FSM_ACTIONS[keeper.phase]) || []).find(a => a.id === 'compact');
    if (compactAct && onAction) onAction(keeper.id, compactAct);
    setTimeout(() => {
      const before = effCtx;
      const after = Math.max(0.16, +(before * (0.36 + Math.random() * 0.1)).toFixed(3));
      const bTok = Math.round(before * 200000), aTok = Math.round(after * 200000);
      const bMsg = Math.max(8, Math.round(before * 120)), aMsg = Math.max(4, Math.round(bMsg * 0.45));
      const bTr = Math.max(3, Math.round(before * 24)), aTr = Math.max(1, Math.round(bTr * 0.4));
      const list = (window.COMPACTIONS[keeper.id] = (window.COMPACTIONS[keeper.id] || []).slice());
      list.unshift({
        id: 'cmp-m' + (list.length + 1), at: nowHM(), trigger: '수동 — operator 요청 (지금 컴팩트)', runtime: keeper.runtime,
        before: { tok: bTok, msgs: bMsg, traces: bTr },
        after: { tok: aTok, msgs: aMsg, traces: aTr },
        kept: ['활성 태스크 소유권·상태', '직전 3턴 원문', 'keeper 상태 스냅샷'],
        summarized: ['초기 분석 turn → 핵심 결론 1줄 요약', '도구 호출 로그 → 성공/실패 집계만 보존'],
        dropped: ['중복된 사고(thinking) 블록', '취소된 후보 경로 trace'],
      });
      setCtxLive(after);
      setCompacting(false);
      setJustRan(true);
      setTimeout(() => setJustRan(false), 2600);
    }, 1500);
  };

  return (
    <aside className="ctx">
      <div className="ctx-scroll">
        {att.length > 0 && (
          <div className="ctx-sec">
            <h4 style={{ display: 'flex', alignItems: 'center', gap: '7px' }}>주의 <CountBadge>{att.length}</CountBadge></h4>
            <div className="att-list">
              {att.map((a, i) => (
                <div key={i} className={`att-item ${a.sev}`}>
                  <span className="att-dot"></span>
                  <span className="att-text">{a.text}</span>
                </div>
              ))}
            </div>
          </div>
        )}

        {(keeper.phase === 'Draining' || keeper.phase === 'HandingOff') && (
          <div className="ctx-sec">
            <h4>{keeper.phase === 'Draining' ? '드레인 큐' : '핸드오프 진행'}</h4>
            <div className="drain-card" data-phase={keeper.phase}>
              <div className="drain-head">
                <span className="drain-badge">{keeper.phase}</span>
                <span className="drain-gloss">{keeper.phase === 'Draining' ? '작업을 비우고 정상 종료 중' : '소유 태스크를 다른 keeper 에게 인계 중'}</span>
              </div>
              <div className="drain-count"><span className="mono">{tasks.length || keeper.tasks || 0}</span>건 {keeper.phase === 'Draining' ? '비우는 중' : '인계 중'}</div>
              {tasks.length > 0 && (
                <div className="drain-list">
                  {tasks.map(t => (
                    <div key={t.id} className="drain-item">
                      <span className="drain-spin"></span>
                      <span className="drain-t-id mono">{t.id}</span>
                      <span className="drain-t-title">{t.title}</span>
                      <span className="drain-t-state mono">{t.state}</span>
                    </div>
                  ))}
                </div>
              )}
              {keeper.phase === 'Draining' && evq && (evq.draining || []).length > 0 && (
                <div className="drain-eventq">
                  <div className="drain-eventq-h">대기 자극 flush</div>
                  {(evq.draining || []).map((e, i) => { const m = EK[e.kind] || { lbl: e.kind, glyph: '\u00B7' }; return (
                    <div key={i} className="drain-ev">
                      <span className="drain-ev-gl mono">{m.glyph}</span>
                      <span className="drain-ev-kind mono">{m.lbl}</span>
                      <span className="drain-ev-from">{e.from}</span>
                      <span className="drain-ev-at mono">{e.at}</span>
                    </div>
                  ); })}
                </div>
              )}
            </div>
          </div>
        )}

        <div className="ctx-sec">
          <h4>런타임</h4>
          <RailRuntime keeper={keeper} />
          {keeper.hb != null && (
            <div className="rail-hb"><span className="rail-hb-dot"></span>heartbeat {keeper.hb}s <span className="rail-hb-sep">·</span> 다음 wake ~{keeper.hbNext}s<span className="rail-hb-note mono">poll</span></div>
          )}
        </div>

        <div className="ctx-sec">
          <h4>컨텍스트</h4>
          <div className="ctx-card">
            <div className="ctx-usage">
              <span className="ctx-usage-k">마지막 턴 input</span>
              <span className="mono ctx-usage-v">{lastIn != null ? (lastIn / 1000).toFixed(1) + 'k' : '—'}</span>
              <span className="ctx-tok-sep">/</span>
              <span className="mono ctx-tok-full">{(ctxWindow / 1000).toFixed(0)}k</span>
              <span className="ctx-tok-lbl">마지막 턴 · 창 크기</span>
            </div>
            <div className="ctx-notobs mono">지금 쓰는 양 <b>알 수 없음</b><span className="ctx-notobs-g">마지막 턴 기준 · 재시작하면 초기화</span></div>
            <div className="cmp-actions">
              {confirmCompact ? (
                <div className="cmp-confirm">
                  <span className="cmp-confirm-q">지금 컨텍스트를 압축할까요? 현재 윈도우가 요약·정리됩니다.</span>
                  <div className="cmp-confirm-btns">
                    <button className="cmp-confirm-yes" onClick={() => { setConfirmCompact(false); runCompact(); }}>확인 · 압축</button>
                    <button className="cmp-confirm-no" onClick={() => setConfirmCompact(false)}>취소</button>
                  </div>
                </div>
              ) : (
                <window.KVM.CompactButton state={compacting ? 'busy' : justRan ? 'done' : 'idle'} onClick={() => setConfirmCompact(true)} />
              )}
            </div>
            <button className="cmp-open" onClick={() => setCmpOpen(true)}>
              {'\u25C9'} 컴팩션 스냅샷{cmps.length ? ` · ${cmps.length}` : ''} <span className="cmp-open-sub">before/after 보기</span>
            </button>
            <button className="cmp-open" onClick={() => setMemOpen(true)}>
              {'\u25C8'} 메모리 보기 <span className="cmp-open-sub">스토어 {(mem.store || []).length} · 에피소드 {(mem.episodes || []).length}</span>
            </button>
          </div>
        </div>

        {window.KeeperWaitQueue && <window.KeeperWaitQueue keeper={keeper} />}

        <div className="ctx-sec">
          <h4>소유 태스크</h4>
          <div className="ctx-list">
            {tasks.length ? tasks.map(t => (
              <button key={t.id} className="tasktag" onClick={() => onNav && onNav('work')} title={`작업으로 이동 · ${t.id}`}>
                <div className="tasktag-top">
                  <span className="tid">{t.id}</span>
                  <span className={`tasktag-state ${t.state}`}>{t.state}</span>
                </div>
                <span className="ttl">{t.title}</span>
              </button>
            )) : <div style={{ fontSize: '12px', color: 'var(--text-dim)' }}>할당된 태스크 없음</div>}
          </div>
        </div>
      </div>
      {cmpOpen && <CompactionInspector keeper={keeper} onClose={() => setCmpOpen(false)} />}
      {memOpen && window.MemoryInspector && <window.MemoryInspector keeper={keeper} onClose={() => setMemOpen(false)} />}
    </aside>
  );
}

Object.assign(window, { Roster, ContextRail, usePersistentW, ColResizer });
