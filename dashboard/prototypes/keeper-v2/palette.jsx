/* MASC v2 — Command palette (⌘K).
   keeper 전환 · 표면 이동 · 빠른 명령을 한 곳에서. app 이 open 상태를 들고
   (paletteOpen) 렌더하며, ⌘K 토글·Esc 닫기는 app 의 전역 키 핸들러가 건다.
   여기서는 목록·필터·방향키 선택만 담당한다. */
const { useState: usePalS, useEffect: usePalEffect, useRef: usePalRef, useMemo: usePalMemo } = React;

function CommandPalette({ open, onClose, keepers, onNav, onOpenKeeper, onToggleDock, openApprovals, apprStatus }) {
  const [q, setQ] = usePalS('');
  const [sel, setSel] = usePalS(0);
  const inputRef = usePalRef(null);
  const listRef = usePalRef(null);

  const surfaces = (window.SURFACES || []).filter(s => !s[3]); // drop external-link surfaces (Monitor)

  const base = usePalMemo(() => {
    const cmds = [];
    // 빠른 명령
    cmds.push({ group: '명령', kind: 'action', t: 'Chat 열기', sub: '⌘J · 보조 패널', glyph: '\u25C8', run: () => onToggleDock() });
    cmds.push({ group: '명령', kind: 'action', t: 'Gate 큐 열기', sub: openApprovals ? `${openApprovals}건 대기` : '비어 있음', glyph: '\u2713', run: () => onNav('approvals') });
    // 표면 이동
    surfaces.forEach(([id, lbl]) => {
      cmds.push({ group: '이동', kind: 'surface', t: lbl, sub: `${id} 표면으로`, glyph: '\u2192', run: () => onNav(id) });
    });
    // keeper 전환
    (keepers || []).forEach(k => {
      cmds.push({ group: 'Keeper', kind: 'keeper', t: k.id, sub: k.phase, k, run: () => onOpenKeeper(k.id) });
    });
    return cmds;
  }, [keepers, openApprovals]);

  // deep index — task·goal·승인·fusion·보드·커넥터로 점프 (쿼리 있을 때만 합쳐 보임)
  const deep = usePalMemo(() => {
    const cmds = [];
    const TS = window.TASK_STATUS || {};
    (window.GOALS || []).forEach(g => {
      cmds.push({ group: '목표', kind: 'goal', t: g.title, sub: `${g.id} · P${g.priority}`, glyph: '\u25CE', run: () => (window.__navWork ? window.__navWork(g.id) : onNav('work')) });
      (g.tasks || []).forEach(tk => {
        cmds.push({ group: 'Task', kind: 'task', t: tk.title, sub: `${tk.id} · ${(TS[tk.status] || {}).lbl || tk.status} · ${tk.assignee || '미배정'}`, glyph: '\u25A3', run: () => (window.__navWork ? window.__navWork(g.id) : onNav('work')) });
      });
    });
    (window.APPROVALS || []).forEach(a => {
      const st = (apprStatus || {})[a.id] || 'open';
      cmds.push({ group: 'Gate', kind: 'approval', t: a.title, sub: `${a.id} · ${a.keeper} · ${st === 'open' ? '대기' : st}`, glyph: '\u2713', run: () => onNav('approvals') });
    });
    (window.FUSION_RUNS || []).forEach(r => {
      cmds.push({ group: 'Fusion', kind: 'fusion', t: r.prompt ? r.prompt.slice(0, 56) : r.run_id, sub: `${r.run_id} · ${r.keeper} · ${r.status}`, glyph: '\u25C8', run: () => (window.__navFusion ? window.__navFusion(r.run_id) : onNav('fusion')) });
    });
    (window.BOARD_POSTS || []).forEach(p => {
      cmds.push({ group: '보드', kind: 'post', t: p.title || (p.body || '').replace(/<[^>]+>/g, '').slice(0, 56), sub: `${p.board} · ${p.author} · ${p.ts}`, glyph: '\u2317', run: () => onNav('board') });
    });
    (window.CONNECTORS || []).forEach(c => {
      cmds.push({ group: '커넥터', kind: 'connector', t: c.name, sub: `${c.channel} · ${c.stale ? 'stale' : c.status}`, glyph: c.glyph || '\u2317', run: () => onNav('connectors') });
    });
    return cmds;
  }, [apprStatus]);

  const items = usePalMemo(() => {
    const ql = q.trim().toLowerCase();
    if (!ql) return base;
    return base.concat(deep).filter(c =>
      c.t.toLowerCase().includes(ql) || c.sub.toLowerCase().includes(ql) || c.group.toLowerCase().includes(ql));
  }, [q, base, deep]);

  usePalEffect(() => {
    if (open) { setQ(''); setSel(0); setTimeout(() => inputRef.current && inputRef.current.focus(), 20); }
  }, [open]);
  usePalEffect(() => { setSel(0); }, [q]);
  usePalEffect(() => {
    const el = listRef.current && listRef.current.querySelector('.cmdk-item.sel');
    if (el) el.scrollIntoView({ block: 'nearest' });
  }, [sel]);

  if (!open) return null;

  const fire = (c) => { if (c) { c.run(); onClose(); } };
  const onKey = (e) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); setSel(s => Math.min(items.length - 1, s + 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setSel(s => Math.max(0, s - 1)); }
    else if (e.key === 'Enter') { e.preventDefault(); fire(items[sel]); }
    else if (e.key === 'Escape') { e.preventDefault(); onClose(); }
  };

  // group headers inline
  let lastGroup = null;

  return (
    <div className="cmdk-backdrop" onClick={onClose}>
      <div className="cmdk" onClick={(e) => e.stopPropagation()}>
        <div className="cmdk-input-row">
          <span className="cmdk-glyph">{'\u2318K'}</span>
          <input ref={inputRef} className="cmdk-input" placeholder="keeper · task · 승인 · fusion · 보드 … 검색"
            value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={onKey} />
          <kbd className="cmdk-esc">esc</kbd>
        </div>
        <div className="cmdk-list" ref={listRef}>
          {items.length === 0 && <div className="cmdk-empty">일치하는 명령이 없습니다</div>}
          {items.map((c, i) => {
            const head = c.group !== lastGroup ? c.group : null;
            lastGroup = c.group;
            return (
              <React.Fragment key={c.t + i}>
                {head && <div className="cmdk-group">{head}</div>}
                <div className={`cmdk-item ${c.kind} ${i === sel ? 'sel' : ''}`}
                  onMouseEnter={() => setSel(i)} onClick={() => fire(c)}>
                  {c.k ? <SigilBadge k={c.k} size={22} /> : <span className="cmdk-item-glyph">{c.glyph}</span>}
                  <div className="cmdk-item-body">
                    <div className="cmdk-item-t">{c.t}</div>
                    <div className="cmdk-item-sub">{c.sub}</div>
                  </div>
                  <span className="cmdk-chord">{i === sel ? '\u21B5' : ''}</span>
                </div>
              </React.Fragment>
            );
          })}
        </div>
        <div className="cmdk-foot">
          <span><kbd>↑</kbd><kbd>↓</kbd> 이동</span>
          <span><kbd>↵</kbd> 실행</span>
          <span><kbd>esc</kbd> 닫기</span>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { CommandPalette });
