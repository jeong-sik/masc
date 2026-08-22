/* MASC v2 — Keeper memory inspector (read-only overlay).
   Opened from the context rail, mirrors the CompactionInspector shell
   (.turn-overlay / .turn-drawer). Scope toggle: 이 keeper / 전체.
   Re-derived from the real Memory OS model (RFC keeper-memory-panel-real-data):
   composition = measured prompt-block bytes + turn tokens; store rows carry
   real category / provenance / age / current — no salience / uses / pins. */
const { useState: useMemS, useEffect: useMemE } = React;

function memFmtTok(n) {
  const a = Math.abs(n);
  const s = a >= 1000 ? (a / 1000).toFixed(1) + 'k' : String(a);
  return (n < 0 ? '−' : '') + s;
}
function memFmtBytes(n) {
  if (n >= 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + 'MB';
  if (n >= 1024) return (n / 1024).toFixed(1) + 'KB';
  return n + 'B';
}

function MemBar({ parts, total }) {
  return (
    <div className="mem-bar" title="프롬프트 블록 구성 (측정 bytes)">
      {parts.map(p => <span key={p.key} style={{ width: (p.bytes / total * 100) + '%', background: p.color }}></span>)}
    </div>
  );
}

function MemCompo({ keeper }) {
  const { totalBytes, parts, usage } = window.memComposition(keeper);
  if (!totalBytes) return <div className="mem-empty">중지된 keeper — 활성 컨텍스트 없음.</div>;
  const pct = usage && usage.context_window ? Math.round(usage.input_tokens / usage.context_window * 100) : Math.round((keeper.ctx || 0) * 100);
  return (
    <div className="mem-compo">
      <div className="mem-compo-head">
        {usage
          ? <React.Fragment>
              <span className="mono mem-compo-tot">{memFmtTok(usage.input_tokens)}</span>
              <span className="mem-compo-sub">/ {memFmtTok(usage.context_window)} tok · {pct}% · 블록 {memFmtBytes(totalBytes)}</span>
            </React.Fragment>
          : <span className="mem-compo-sub">블록 {memFmtBytes(totalBytes)}</span>}
      </div>
      <MemBar parts={parts} total={totalBytes} />
      <div className="mem-legend">
        {parts.map(p => (
          <div key={p.key} className="mem-leg">
            <span className="mem-leg-sw" style={{ background: p.color }}></span>
            <span className="mem-leg-lbl">{p.lbl}{p.mem && <span className="mem-leg-tag">메모리</span>}</span>
            <span className="mem-leg-v mono">{memFmtBytes(p.bytes)}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function MemStoreRow({ s, srcOverride }) {
  const c = window.MEM_CATEGORY[s.category] || { lbl: s.category, glyph: '·', cls: 'unknown' };
  const prov = s.prov || {};
  return (
    <div className="mem-store-row">
      <span className={`mem-kind ${c.cls}`}>{c.glyph} {c.lbl}</span>
      <div className="mem-store-main">
        <div className="mem-store-text">{s.claim}</div>
        <div className="mem-store-meta">
          {s.current === false
            ? <span className="mem-ttl expired">{s.ttl || '만료'}</span>
            : <span className="mem-ttl current">유효</span>}
          {s.age && <span title="reference_time 이후 경과">확인 {s.age} 전</span>}
          <span className="mem-src mono">{srcOverride || (prov.trace ? `${prov.trace}${prov.turn != null ? ' · t' + prov.turn : ''}` : '—')}</span>
        </div>
      </div>
    </div>
  );
}

function OneKeeperMemory({ keeper }) {
  const m = window.getKeeperMemory(keeper);
  const comps = (window.COMPACTIONS && window.COMPACTIONS[keeper.id]) || [];
  const lastCmp = comps[0];
  const [catFilter, setCatFilter] = useMemS('all');
  const cats = [...new Set(m.store.map(s => s.category))];
  const store = catFilter === 'all' ? m.store : m.store.filter(s => s.category === catFilter);
  return (
    <React.Fragment>
      <div className="turn-sec">
        <h4>컨텍스트 구성 <span className="mem-hint">측정 prompt_block bytes (RFC-0233)</span></h4>
        <MemCompo keeper={keeper} />
      </div>

      <div className="turn-sec">
        <div className="mem-sec-head">
          <h4>장기 메모리 스토어 · memory-os</h4>
          <span className="mem-n mono">{m.store.length}</span>
        </div>
        <div className="mem-retain mono">GC = <b>valid_until</b> 지난 행만 삭제<span className="mem-retain-g">주기적 full-store LLM 통합(consolidation)은 런타임·라우트·대시보드 프로젝션과 함개 제거되었습니다. bounded Librarian 이 producer 가 제출한 fact 만 upsert 하고, semantic supersession/tombstone 경로가 없어 만료 전 행은 유지됩니다.</span></div>
        {m.store.length ? (
          <React.Fragment>
            {cats.length > 1 && (
              <div className="mem-filters">
                <button className={`mem-filter ${catFilter === 'all' ? 'on' : ''}`} onClick={() => setCatFilter('all')}>전체</button>
                {cats.map(cc => {
                  const d = window.MEM_CATEGORY[cc] || { lbl: cc, glyph: '·' };
                  return <button key={cc} className={`mem-filter ${catFilter === cc ? 'on' : ''}`} onClick={() => setCatFilter(cc)}>{d.glyph} {d.lbl}</button>;
                })}
              </div>
            )}
            <div className="mem-store">{store.map(s => <MemStoreRow key={s.id} s={s} />)}</div>
          </React.Fragment>
        ) : <div className="mem-empty">장기 메모리 항목 없음.</div>}
      </div>

      <div className="turn-sec">
        <h4>메모리 형성 에피소드 <span className="mem-hint">압축·요약 경계 (관측 이벤트)</span></h4>
        {m.episodes && m.episodes.length ? (
          <div className="mem-timeline">
            {m.episodes.map((e) => {
              const o = window.MEM_EPISODE[e.role] || { lbl: e.role, glyph: '·', cls: '' };
              return (
                <div key={e.id} className="mem-tl-row">
                  <span className="mem-tl-at mono">{e.at}</span>
                  <span className={`mem-op ${o.cls}`}>{o.glyph} {o.lbl}</span>
                  <span className="mem-tl-text">{e.summary}<span className="mem-tl-range mono">{e.range} · {e.claims} claim</span></span>
                  {e.freed != null && <span className="mem-tl-tok mono neg">−{memFmtTok(e.freed)}</span>}
                </div>
              );
            })}
          </div>
        ) : <div className="mem-empty">압축·요약 에피소드 없음.</div>}
      </div>

      <div className="turn-sec">
        <h4>압축 유지 · 요약 · 폐기</h4>
        {lastCmp ? (
          <React.Fragment>
            <div className="cmp-trigger"><span className="sub-k">최근 컴팩션</span>{lastCmp.at} · {lastCmp.trigger}</div>
            <div className="cmp-diff">
              <div className="cmp-col kept"><div className="cmp-col-h">{'\u25C8'} 유지</div>{lastCmp.kept.map((x, i) => <div key={i} className="cmp-li">{x}</div>)}</div>
              <div className="cmp-col summ"><div className="cmp-col-h">{'\u25C9'} 요약</div>{lastCmp.summarized.map((x, i) => <div key={i} className="cmp-li">{x}</div>)}</div>
              <div className="cmp-col drop"><div className="cmp-col-h">{'\u25CC'} 폐기</div>{lastCmp.dropped.map((x, i) => <div key={i} className="cmp-li">{x}</div>)}</div>
            </div>
          </React.Fragment>
        ) : <div className="mem-empty">컴팩션 이력 없음 — 메모리가 압축된 적 없음.</div>}
      </div>
    </React.Fragment>
  );
}

function AllKeepersMemory({ keepers, onPick }) {
  const agg = window.memAggregate(keepers);
  const maxMem = Math.max(1, ...agg.rows.map(r => r.memBytes));
  return (
    <React.Fragment>
      <div className="turn-sec">
        <h4>집계</h4>
        <div className="mem-stats">
          <div className="mem-stat"><span className="v mono">{agg.keeperCount}</span><span className="k">keeper</span></div>
          <div className="mem-stat"><span className="v mono">{agg.store}</span><span className="k">스토어 항목</span></div>
          <div className="mem-stat"><span className="v mono">{memFmtBytes(agg.memBytes)}</span><span className="k">메모리 블록</span></div>
        </div>
      </div>

      <div className="turn-sec">
        <h4>category별 분포 <span className="mem-hint">실제 fact.category</span></h4>
        <div className="mem-kinds-dist">
          {Object.entries(agg.catTotals).sort((a, b) => b[1] - a[1]).map(([cc, n]) => {
            const d = window.MEM_CATEGORY[cc] || { lbl: cc, glyph: '·', cls: 'unknown' };
            return (
              <div key={cc} className="mem-kd-row">
                <span className={`mem-kind ${d.cls}`}>{d.glyph} {d.lbl}</span>
                <div className="mem-kd-bar"><span style={{ width: (n / agg.store * 100) + '%' }}></span></div>
                <span className="mono mem-kd-n">{n}</span>
              </div>
            );
          })}
        </div>
      </div>

      <div className="turn-sec">
        <h4>keeper별 메모리 <span className="mem-hint">행을 누르면 개별 보기</span></h4>
        <div className="mem-table">
          <div className="mem-tr mem-th"><span>keeper</span><span>ctx</span><span>스토어</span><span>mem bytes</span></div>
          {agg.rows.map(r => (
            <button key={r.id} className="mem-tr" onClick={() => onPick && onPick(r.id)}>
              <span className="mem-td-id"><StatusDot status={r.status === 'run' ? 'run' : r.status === 'pause' ? 'idle' : 'bad'} /><span className="mono">{r.id}</span></span>
              <span className="mono">{Math.round(r.ctx * 100)}%</span>
              <span className="mono">{r.store}</span>
              <span className="mem-td-bar"><i style={{ width: (r.memBytes / maxMem * 100) + '%' }}></i><b className="mono">{memFmtBytes(r.memBytes)}</b></span>
            </button>
          ))}
        </div>
      </div>

      <div className="turn-sec">
        <h4>최근 확인된 사실 · 전체 <span className="mem-hint">salience 정렬 아님 (RFC-0247)</span></h4>
        <div className="mem-store">
          {agg.recentFacts.map(s => <MemStoreRow key={s.keeper + s.id} s={s} srcOverride={s.keeper} />)}
        </div>
      </div>
    </React.Fragment>
  );
}

function MemoryInspector({ keeper, onClose }) {
  const [scope, setScope] = useMemS('one');
  const [pickId, setPickId] = useMemS(keeper.id);
  useMemE(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  const keepers = window.KEEPERS || [];
  const active = keepers.find(k => k.id === pickId) || keeper;
  return (
    <div className="turn-overlay" onClick={onClose}>
      <div className="turn-drawer mem-drawer" onClick={(e) => e.stopPropagation()}>
        <div className="turn-hd">
          <h3>Keeper 메모리</h3>
          <span className="tid">{scope === 'one' ? active.id : '전체 keeper'}</span>
          <div className="mem-scope">
            <button className={scope === 'one' ? 'on' : ''} onClick={() => setScope('one')}>이 keeper</button>
            <button className={scope === 'all' ? 'on' : ''} onClick={() => setScope('all')}>전체</button>
          </div>
          <button className="turn-close" onClick={onClose} title="닫기 (Esc)">{'\u2715'}</button>
        </div>
        <div className="turn-body">
          {scope === 'one'
            ? <OneKeeperMemory keeper={active} />
            : <AllKeepersMemory keepers={keepers} onPick={(id) => { setPickId(id); setScope('one'); }} />}
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { MemoryInspector });
