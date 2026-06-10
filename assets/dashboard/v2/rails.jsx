/* MASC v2 — Roster rail (left) and Context rail (right) */
const { useState: useStateP } = React;

function fsmGroupOf(k) {
  if (k.status === 'run') return '실행 중';
  if (k.status === 'pause') return '대기 · 일시정지';
  return '중지 · 종료됨';
}

function Roster({ keepers, selected, onSelect, mini }) {
  const [q, setQ] = useStateP('');
  const [filter, setFilter] = useStateP('all');

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

  return (
    <aside className={`roster ${mini ? 'mini' : ''}`}>
      <div className="roster-head">
        <div className="roster-title">
          <h3>Keepers</h3>
          <span className="count mono">{counts.run}/{counts.all}</span>
        </div>
        <input className="roster-search" placeholder="이름·네임스페이스 검색…" value={q} onChange={e => setQ(e.target.value)} />
      </div>
      <div className="roster-filters">
        {[['all', '전체'], ['run', '실행중'], ['att', '주의']].map(([key, lbl]) => (
          <button key={key} className={`rfilter ${filter === key ? 'on' : ''}`} onClick={() => setFilter(key)}>
            {lbl}<span className="n">{counts[key]}</span>
          </button>
        ))}
      </div>
      <div className="roster-list">
        {order.filter(g => groups[g]).map(g => (
          <div key={g}>
            <div className="roster-group">{g}</div>
            {groups[g].map(k => (
              <div key={k.id} className={`kp-row ${selected === k.id ? 'sel' : ''}`} onClick={() => onSelect(k.id)}>
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
                  {k.att > 0 && <span className="kp-att">{k.att}</span>}
                </div>
              </div>
            ))}
          </div>
        ))}
        {!list.length && <div style={{ padding: '30px 12px', textAlign: 'center', color: 'var(--text-dim)', fontSize: '12px' }}>일치하는 Keeper가 없습니다</div>}
      </div>
    </aside>
  );
}

function ContextRail({ keeper }) {
  const tasks = OWNED_TASKS[keeper.id] || [];
  const ctxPct = Math.round(keeper.ctx * 100);
  const hot = keeper.ctx >= 0.85;

  // build a small fsm path around current
  const path = ['Restarting', 'Running', 'Compacting', 'HandingOff'];
  const curIdx = path.indexOf(keeper.phase) === -1 ? 1 : path.indexOf(keeper.phase);

  return (
    <aside className="ctx">
      <div className="ctx-scroll">
        <div className="ctx-sec">
          <h4>활력 지표</h4>
          <div className="vitals">
            <div className="vital"><div className="vk">모델</div><div className="vv" style={{ fontSize: '11.5px' }}>{keeper.model}</div></div>
            <div className="vital"><div className="vk">런타임</div><div className="vv" style={{ fontSize: '11.5px' }}>{keeper.runtime}</div></div>
            <div className="vital"><div className="vk">역할</div><div className="vv" style={{ fontSize: '12px' }}>{keeper.role}</div></div>
            <div className="vital"><div className="vk">가동시간</div><div className="vv" style={{ fontSize: '12px' }}>{keeper.uptime}</div></div>
            <div className="vital"><div className="vk">누적 trace</div><div className="vv">{keeper.traces}</div></div>
            <div className="vital"><div className="vk">소유 태스크</div><div className="vv volt">{keeper.tasks}</div></div>
          </div>
        </div>

        <div className="ctx-sec">
          <h4>컨텍스트 점유</h4>
          <div className="ctx-card">
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
              <span style={{ fontSize: '12px', color: 'var(--text-mid)' }}>윈도우 사용량</span>
              <span className="mono" style={{ fontSize: '14px', color: hot ? 'var(--status-bad)' : 'var(--volt-strong)' }}>{ctxPct}%</span>
            </div>
            <div className={`meter ${hot ? 'hot' : ''}`}><span style={{ width: ctxPct + '%' }}></span></div>
            {hot && <div style={{ marginTop: '8px', fontSize: '11px', color: 'var(--status-warn)' }}>{'\u26A0'} 곧 Compact 트리거</div>}
          </div>
        </div>

        <div className="ctx-sec">
          <h4>상태 머신</h4>
          <div className="ctx-card">
            <div className="fsm">
              {path.map((s, i) => (
                <div key={s} className={`fsm-step ${i < curIdx ? 'done' : ''} ${i === curIdx ? 'cur' : ''}`}>
                  <span className="pip"></span>{s}
                </div>
              ))}
            </div>
            <div style={{ marginTop: '8px', fontSize: '10.5px', color: 'var(--text-dim)' }}>
              12-state 머신 · 현재 <span className="mono" style={{ color: 'var(--volt-strong)' }}>{keeper.phase}</span>
            </div>
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
            {RECENT_TOOLS.map((t, i) => (
              <div key={i} className="ctx-item">
                <StatusDot status="run" />
                <span className="ci-name">{t.name}</span>
                <span className="ci-meta">{t.dur} · {t.ago}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </aside>
  );
}

Object.assign(window, { Roster, ContextRail });
