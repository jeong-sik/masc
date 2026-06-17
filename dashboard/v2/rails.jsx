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
        <span className="tps-spark-rt mono">{keeper.runtime}</span>
      </div>
    </div>
  );
}

function fsmGroupOf(k) {
  if (k.status === 'run') return '실행 중';
  if (k.status === 'pause') return '대기 · 일시정지';
  return '중지 · 종료됨';
}

function Roster({ keepers, selected, onSelect, mini, onConfig }) {
  const [q, setQ] = useStateP('');
  const [filter, setFilter] = useStateP('all');
  const [menu, setMenu] = useStateP(null); // { keeper, x, y }

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
    if (q && !(`${k.id} ${k.kr} ${k.ns} ${k.model}`.toLowerCase().includes(q.toLowerCase()))) return false;
    return true;
  });

  // group by status
  const order = ['실행 중', '대기 · 일시정지', '중지 · 종료됨'];
  const groups = {};
  list.forEach(k => { (groups[fsmGroupOf(k)] = groups[fsmGroupOf(k)] || []).push(k); });

  // one keeper row — shared by the normal and windowed render paths
  const renderKeeper = (k) => (
    <div key={k.id} className={`kp-row ${selected === k.id ? 'sel' : ''}`} onClick={() => onSelect(k.id)} onContextMenu={(e) => openMenu(e, k)} style={{ contentVisibility: 'auto', containIntrinsicSize: 'auto 58px' }}>
      <SigilBadge k={k} size={38} beat={k.status === 'run'} />
      <div className="kp-meta">
        <div className="kp-name">{k.id}</div>
        <div className="kp-sub">
          <span className="kp-state"><StatusDot status={k.status} pulse={k.status === 'run'} />{k.phase}</span>
          <span>·</span>
          <span className="kp-handle">{k.ns}</span>
        </div>
      </div>
      <div className="kp-right">
        <span className="kp-time">{k.last}</span>
        {k.att > 0 && <span className="kp-att" title={`주의 ${k.att}건 — 컨텍스트 레일에서 확인`}>{k.att}</span>}
      </div>
      <button className="kp-more" title="명령 메뉴" onClick={(e) => openMenu(e, k)}>⋯</button>
    </div>
  );

  // flatten groups → [{t:'h'|'r', ...}] for windowing
  const flat = [];
  order.filter(g => groups[g]).forEach(g => {
    flat.push({ t: 'h', g });
    groups[g].forEach(k => flat.push({ t: 'r', k }));
  });
  // window only when the roster is long enough to matter (keeps DOM
  // structure identical for the common small case → zero regression)
  const WINDOW_AT = 60;
  const windowed = flat.length > WINDOW_AT && window.KVP && window.KVP.VirtualList;
  const ROW_H = 58, HEAD_H = 30;

  return (
    <aside className={`roster ${mini ? 'mini' : ''}`}>
      <div className="roster-head">
        <input className="roster-search" placeholder="이름·네임스페이스 검색…" value={q} onChange={e => setQ(e.target.value)} />
      </div>
      <div className="roster-filters">
        {[['all', '전체'], ['run', '실행중'], ['att', '주의']].map(([key, lbl]) => (
          <button key={key} className={`rfilter ${filter === key ? 'on' : ''}`} onClick={() => setFilter(key)}>
            {lbl}<span className="n">{counts[key]}</span>
          </button>
        ))}
      </div>
      {windowed ? (
        <window.KVP.VirtualList
          className="roster-list"
          items={flat}
          rowHeight={(it) => (it.t === 'h' ? HEAD_H : ROW_H)}
          getKey={(it) => (it.t === 'h' ? 'h:' + it.g : it.k.id)}
          renderRow={(it) => (it.t === 'h' ? <div className="roster-group">{it.g}</div> : renderKeeper(it.k))}
        />
      ) : (
        <div className="roster-list">
          {order.filter(g => groups[g]).map(g => (
            <div key={g}>
              <div className="roster-group">{g}</div>
              {groups[g].map(renderKeeper)}
            </div>
          ))}
          {!list.length && <div style={{ padding: '30px 12px', textAlign: 'center', color: 'var(--text-dim)', fontSize: '12px' }}>일치하는 Keeper가 없습니다</div>}
        </div>
      )}
      {menu && (
        <div className="kp-menu" style={{ left: menu.x, top: menu.y }} onClick={(e) => e.stopPropagation()}>
          <div className="kp-menu-h"><SigilBadge k={menu.keeper} size={20} /><span className="mono">{menu.keeper.id}</span></div>
          <button className="kp-menu-i" onClick={() => { onSelect(menu.keeper.id); setMenu(null); }}>{'\u25C8'} 대화 열기</button>
          {menu.keeper.status === 'run'
            ? <button className="kp-menu-i" onClick={() => setMenu(null)}>{'\u23F8'} 일시정지</button>
            : <button className="kp-menu-i" onClick={() => setMenu(null)}>{'\u25B6'} 재개</button>}
          <button className="kp-menu-i" onClick={() => setMenu(null)}>{'\u21C4'} 핸드오프…</button>
          <button className="kp-menu-i" onClick={() => setMenu(null)}>{'\u25C9'} 컴팩션 실행</button>
          <div className="kp-menu-sep"></div>
          <button className="kp-menu-i" onClick={() => { onConfig && onConfig(menu.keeper); setMenu(null); }}>{'\u2699'} keeper 설정</button>
          <button className="kp-menu-i danger" onClick={() => setMenu(null)}>{'\u23F9'} 중지</button>
        </div>
      )}
    </aside>
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
  useEffectP(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  const ev = events[idx];
  const reduction = ev ? Math.round((1 - ev.after.tok / ev.before.tok) * 100) : 0;

  return (
    <div className="turn-overlay" onClick={onClose}>
      <div className="turn-drawer" onClick={(e) => e.stopPropagation()}>
        <div className="turn-hd">
          <h3>컴팩션 스냅샷</h3>
          <span className="tid">{keeper.id}</span>
          <button className="turn-close" onClick={onClose} title="닫기 (Esc)">{'\u2715'}</button>
        </div>

        {events.length === 0 ? (
          <div className="turn-body"><div className="cmp-empty">아직 이 keeper에서 실행된 컴팩션이 없습니다.<br />컨텍스트가 임계치(85%)를 넘으면 자동으로 기록됩니다.</div></div>
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
              <div className="cmp-trigger"><span className="sub-k">수행 런타임</span><span className="mono">{ev.runtime}</span></div>

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

function ContextRail({ keeper }) {
  const tasks = OWNED_TASKS[keeper.id] || [];
  const COMPACT_AT = 85;
  const att = ATTENTION[keeper.id] || [];
  const cmps = (window.COMPACTIONS && COMPACTIONS[keeper.id]) || [];
  const [cmpOpen, setCmpOpen] = useStateP(false);
  const [ctxLive, setCtxLive] = useStateP(null);   // post-manual-compact override (0..1)
  const [compacting, setCompacting] = useStateP(false);
  const [justRan, setJustRan] = useStateP(false);
  useEffectP(() => { setCmpOpen(false); setCtxLive(null); setCompacting(false); setJustRan(false); }, [keeper.id]);

  const effCtx = ctxLive != null ? ctxLive : keeper.ctx;
  const ctxPct = Math.round(effCtx * 100);
  const hot = effCtx >= 0.85;

  const runCompact = () => {
    if (compacting) return;
    setCompacting(true);
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
        kept: ['활성 태스크 소유권·상태', '직전 3턴 원문', 'namespace 스냅샷'],
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
            <h4>주의 <CountBadge style={{ marginLeft: 7, verticalAlign: 'middle' }}>{att.length}</CountBadge></h4>
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
        <div className="ctx-sec">
          <h4>런타임 · 처리량</h4>
          <div className="vitals">
            <div className="vital"><div className="vk">모델</div><div className="vv" style={{ fontSize: '11.5px' }}>{keeper.model}</div></div>
            <div className="vital"><div className="vk">런타임</div><div className="vv" style={{ fontSize: '11.5px' }}>{keeper.runtime.split('·')[0]}</div></div>
          </div>
          <div style={{ marginTop: '8px' }}><RailTps keeper={keeper} /></div>
        </div>

        <div className="ctx-sec">
          <h4>컨텍스트</h4>
          <div className="ctx-card">
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
              <span style={{ fontSize: '12px', color: 'var(--text-mid)' }}>윈도우 사용량</span>
              <span className="mono" style={{ fontSize: '14px', color: hot ? 'var(--status-bad)' : 'var(--volt-strong)' }}>{ctxPct}%</span>
            </div>
            <div className="meter-wrap">
              <div className={`meter ${hot ? 'hot' : ''}`}><span style={{ width: ctxPct + '%' }}></span></div>
              <span className={`meter-mark ${hot ? 'hot' : ''}`} style={{ left: COMPACT_AT + '%' }} title={`자동 compact 임계치 ${COMPACT_AT}%`}><i className="meter-mark-lbl">compact {COMPACT_AT}%</i></span>
            </div>
            <div className="ctx-tok">
              <span className="mono">{(effCtx * 200).toFixed(1)}k</span>
              <span className="ctx-tok-sep">/</span>
              <span className="mono ctx-tok-full">200k</span>
              <span className="ctx-tok-lbl">사용 / 전체 윈도우</span>
            </div>
            <div className="cmp-actions">
              <window.KVM.CompactButton state={compacting ? 'busy' : justRan ? 'done' : 'idle'} onClick={runCompact} />
            </div>
            <button className="cmp-open" onClick={() => setCmpOpen(true)}>
              {'\u25C9'} 컴팩션 스냅샷{cmps.length ? ` · ${cmps.length}` : ''} <span className="cmp-open-sub">before/after 보기</span>
            </button>
          </div>
        </div>

        <div className="ctx-sec">
          <h4>소유 태스크</h4>
          <div className="ctx-list">
            {tasks.length ? tasks.map(t => (
              <div key={t.id} className="tasktag">
                <span className="tid">{t.id}</span>
                <span className="ttl">{t.title}</span>
                <span style={{ marginLeft: 'auto', flex: 'none', fontSize: '10px', color: t.state === 'blocked' ? 'var(--status-bad)' : t.state === 'review' ? 'var(--status-warn)' : 'var(--text-dim)' }}>{t.state}</span>
              </div>
            )) : <div style={{ fontSize: '12px', color: 'var(--text-dim)' }}>할당된 태스크 없음</div>}
          </div>
        </div>

        <div className="ctx-sec">
          <h4>최근 도구 호출</h4>
          <div className="ctx-list">
            {RECENT_TOOLS.map((t, i) => <RecentTool key={i} t={t} />)}
          </div>
        </div>
      </div>
      {cmpOpen && <CompactionInspector keeper={keeper} onClose={() => setCmpOpen(false)} />}
    </aside>
  );
}

Object.assign(window, { Roster, ContextRail });
