/* MASC v2 — IDE surface: file tree · editor with keeper cursors/annotations · split diff ·
   activity rail (tool/turn/PR events) · execute output drawer.
   Grounded in components/ide/* and api/ide.ts (cursors.focus_mode, annotations, bridge events). */
const { useState: useIdeState } = React;

const FOCUS_KR = { reading: '읽는 중', editing: '편집 중', reviewing: '리뷰 중', planning: '계획 중' };

function IdeTree({ open, file, onPick }) {
  if (!open) return <div></div>;
  return (
    <nav className="ide-tree">
      <h4>{IDE_REPO.name}</h4>
      {IDE_TREE.map((n, i) => {
        const pad = 8 + n.d * 13;
        if (n.type === 'dir') {
          return (
            <button key={i} className="ide-fnode" style={{ paddingLeft: pad }}>
              <span className="tw">{n.open ? '▾' : '▸'}</span>{n.name}/
            </button>
          );
        }
        const curs = (n.cursors || []).map(id => KEEPERS.find(k => k.id === id)).filter(Boolean);
        return (
          <button key={i} className={`ide-fnode ${file === n.path ? 'on' : ''}`} style={{ paddingLeft: pad }} onClick={() => onPick(n.path)}>
            <span className="tw">·</span>{n.name}
            {curs.length > 0 && (
              <span className="kcur" style={{ display: 'inline-flex', gap: 3 }}>
                {curs.map(k => <SigilBadge key={k.id} k={k} size={13} />)}
              </span>
            )}
            {n.dirty && <span className="dirty" title="수정됨"></span>}
          </button>
        );
      })}
    </nav>
  );
}

function CursorTag({ cur }) {
  const k = KEEPERS.find(kk => kk.id === cur.keeper);
  if (!k) return null;
  return (
    <span className="cursor-tag" style={{ '--kc': `var(--kp${k.slot})`, background: `var(--kp${k.slot})` }}>
      <SigilBadge k={k} size={12} />
      {k.id}
      <span className="fm">· {FOCUS_KR[cur.focus]}{cur.tool ? ` · ${cur.tool}` : ''}</span>
    </span>
  );
}

function IdeEditor({ file, findQ, onJumpAnn }) {
  const isRound = file === 'lib/scheduler/round.ml';
  const cursorsByLine = {};
  const annByLine = {};
  if (isRound) {
    IDE_CURSORS.forEach(c => { cursorsByLine[c.line] = c; });
    IDE_ANNOTATIONS.forEach(a => { annByLine[a.line] = a; });
  }
  return (
    <div className="ide-code">
      {isRound ? IDE_CODE.map(([ln, html]) => {
        const cur = cursorsByLine[ln];
        const ann = annByLine[ln];
        const k = cur ? KEEPERS.find(kk => kk.id === cur.keeper) : null;
        const matched = findQ && (html || '').replace(/<[^>]+>/g, '').toLowerCase().includes(findQ.toLowerCase());
        return (
          <div key={ln} className={`cl ${cur ? 'hl-cursor' : ''} ${ann ? 'hl-ann' : ''}`}
            style={{ ...(k ? { '--kc': `var(--kp${k.slot})` } : null), ...(matched ? { background: 'var(--volt-wash)', boxShadow: 'inset 2.5px 0 0 var(--volt)' } : null) }}>
            <span className="ln">{ln}</span>
            <span className="lc" dangerouslySetInnerHTML={{ __html: html || '\u00a0' }}></span>
            {cur && <CursorTag cur={cur} />}
            {ann && (
              <button className={`ann-pin ${ann.kind === 'risk' ? 'risk' : ''}`} onClick={() => onJumpAnn(ann.id)}>
                {ann.kind === 'risk' ? '⚠ risk' : '◈ note'} · {ann.keeper}
              </button>
            )}
          </div>
        );
      }) : (
        <div className="empty2" style={{ height: '100%' }}>
          <div className="ico">◇</div>
          <h3>{file.split('/').pop()}</h3>
          <div style={{ fontSize: 12.5, color: 'var(--text-dim)' }}>이 파일은 프리뷰에 샘플이 없습니다 — <span className="mono">round.ml</span> 을 선택해 보세요.</div>
        </div>
      )}
    </div>
  );
}

function IdeDiff() {
  return (
    <div className="ide-diff">
      <div className="pane">
        <div className="pane-h">base <span className="sha">{IDE_DIFF.base}</span></div>
        {IDE_DIFF.left.map(([ln, html, cls], i) => (
          <div key={i} className={`dl ${cls}`}>
            <span className="ln">{cls === 'pad' ? '' : ln}</span>
            <span className="lc" dangerouslySetInnerHTML={{ __html: html || '\u00a0' }}></span>
          </div>
        ))}
      </div>
      <div className="pane">
        <div className="pane-h">head <span className="sha">{IDE_DIFF.head}</span></div>
        {IDE_DIFF.right.map(([ln, html, cls], i) => (
          <div key={i} className={`dl ${cls}`}>
            <span className="ln">{cls === 'pad' ? '' : ln}</span>
            <span className="lc" dangerouslySetInnerHTML={{ __html: html || '\u00a0' }}></span>
          </div>
        ))}
      </div>
    </div>
  );
}

function IdeRail({ tab, setTab }) {
  return (
    <aside className="ide-rail">
      <div className="ide-rail-tabs">
        {[['act', '활동'], ['ann', '어노테이션'], ['cur', '커서']].map(([k, l]) => (
          <button key={k} className={`ide-rail-tab ${tab === k ? 'on' : ''}`} onClick={() => setTab(k)}>{l}</button>
        ))}
      </div>
      <div className="ide-rail-scroll">
        {tab === 'act' && IDE_EVENTS.map((e, i) => {
          const k = KEEPERS.find(kk => kk.id === e.keeper);
          if (e.type === 'pr') {
            return (
              <div key={i} className="ide-ev pr">
                <span className="ico">⇡</span>
                <div style={{ minWidth: 0 }}>
                  <div className="hd">PR #{e.pr} <span className={`prstate ${e.state}`}>{e.state}</span><span className="ts">{e.ts}</span></div>
                  <div className="sum">{e.title}</div>
                  <div className="fp">{e.repo} · 댓글 {e.comments} · {e.review}{k ? ` · ${k.id}` : ''}</div>
                </div>
              </div>
            );
          }
          if (e.type === 'turn') {
            return (
              <div key={i} className="ide-ev turn">
                <span className="ico">◌</span>
                <div style={{ minWidth: 0 }}>
                  <div className="hd">turn · {e.phase} <span className="lat">{e.dur}</span><span className="ts">{e.ts}</span></div>
                  <div className="sum">{e.keeper} · {e.model} · 도구 {e.tools.join(', ')} · {e.stop}</div>
                </div>
              </div>
            );
          }
          return (
            <div key={i} className="ide-ev tool">
              <span className="ico">⚙</span>
              <div style={{ minWidth: 0 }}>
                <div className="hd">{e.name} <span className="lat">{e.lat}</span><span className="ts">{e.ts}</span></div>
                <div className="sum">{e.keeper} · {e.sum}</div>
                <div className="fp">{e.fp}</div>
              </div>
            </div>
          );
        })}
        {tab === 'ann' && IDE_ANNOTATIONS.map(a => (
          <div key={a.id} className="ide-ann-card" id={`ann-${a.id}`}>
            <div className="hd">
              <span className={`kind ${a.kind}`}>{a.kind}</span>
              <span>L{a.line}</span><span>· {a.keeper}</span>
            </div>
            <div className="bd">{a.content}</div>
            <div className="lk">{a.links.map((l, i) => <span key={i}>{l}</span>)}</div>
          </div>
        ))}
        {tab === 'cur' && IDE_CURSORS.map((c, i) => {
          const k = KEEPERS.find(kk => kk.id === c.keeper);
          return (
            <div key={i} className="ide-ev">
              <span className="ico" style={{ background: 'transparent', border: 0 }}><SigilBadge k={k} size={20} /></span>
              <div style={{ minWidth: 0 }}>
                <div className="hd">{c.keeper} <span className="ts">L{c.line}</span></div>
                <div className="sum">{FOCUS_KR[c.focus]}{c.tool ? ` · ${c.tool}` : ''} · round.ml</div>
              </div>
            </div>
          );
        })}
      </div>
    </aside>
  );
}

function IdeSurface() {
  const [view, setView] = useIdeState('source');
  const [file, setFile] = useIdeState('lib/scheduler/round.ml');
  const [treeOpen, setTreeOpen] = useIdeState(true);
  const [railOpen, setRailOpen] = useIdeState(true);
  const [railTab, setRailTab] = useIdeState('act');
  const [drawerOpen, setDrawerOpen] = useIdeState(true);
  const [findQ, setFindQ] = useIdeState('compact');

  const segs = file.split('/');
  const owner = KEEPERS.find(k => k.id === 'sangsu');

  return (
    <main className="ide" data-screen-label="IDE">
      <div className="ide-top">
        <button className="act icon" title={treeOpen ? '파일 트리 접기' : '파일 트리 펼치기'} onClick={() => setTreeOpen(o => !o)}>{treeOpen ? '⊟' : '⊞'}</button>
        <span className="ide-repo" title={`이 keeper 워크트리의 origin (git remote) — 워크트리마다 다름 · ${IDE_REPO.worktree}`}>
          <button className="ide-remote mono" title="origin 클론 URL 복사" onClick={(e) => {
            navigator.clipboard && navigator.clipboard.writeText(IDE_REPO.origin);
            const el = e.currentTarget; const t = el.textContent; el.textContent = '✓ 복사됨'; setTimeout(() => { el.textContent = t; }, 1100);
          }}>{IDE_REPO.origin}</button>
          <a className="ide-web" href={IDE_REPO.web} target="_blank" rel="noreferrer" title="GitHub에서 보기 ↗">↗</a>
          <span className="br">{IDE_REPO.branch}</span> · 변경 {IDE_REPO.dirty}건
        </span>
        <div className="ide-views">
          {[['source', 'Source'], ['split', 'Split Diff'], ['find', '검색']].map(([k, l]) => (
            <button key={k} className={`ide-view ${view === k ? 'on' : ''}`} onClick={() => setView(k)}>{l}</button>
          ))}
        </div>
        <span className="spacer"></span>
        <div className="ide-presence">
          <span className="lbl">Presence</span>
          {IDE_CURSORS.map((c, i) => {
            const k = KEEPERS.find(kk => kk.id === c.keeper);
            return <SigilBadge key={i} k={k} size={20} beat={c.focus === 'editing'} />;
          })}
        </div>
        <button className="act icon" title={railOpen ? '활동 레일 접기' : '활동 레일 펼치기'} onClick={() => setRailOpen(o => !o)}>{railOpen ? '⊣' : '⊢'}</button>
      </div>

      <div className={`ide-body ${treeOpen ? '' : 'no-tree'} ${railOpen ? '' : 'no-rail'}`}>
        <IdeTree open={treeOpen} file={file} onPick={setFile} />
        <section className="ide-ed">
          <div className="ide-crumb">
            {segs.map((s, i) => (
              <React.Fragment key={i}>
                <span className={`seg ${i === segs.length - 1 ? 'last' : ''}`}>{s}</span>
                {i < segs.length - 1 && <span>/</span>}
              </React.Fragment>
            ))}
            <span className="own">
              소유 {owner && <SigilBadge k={owner} size={14} />} sangsu · blame <span style={{ color: 'var(--volt-strong)' }}>c7be26acfb</span>
            </span>
          </div>
          {view === 'find' && (
            <div style={{ flex: 'none', display: 'flex', alignItems: 'center', gap: 9, padding: '7px 14px', borderBottom: '1px solid var(--border-soft)', background: 'var(--bg-panel-alt)' }}>
              <span style={{ fontSize: 10, letterSpacing: '0.14em', textTransform: 'uppercase', color: 'var(--text-dim)' }}>찾기</span>
              <input className="roster-search" style={{ width: 240 }} value={findQ} onChange={e => setFindQ(e.target.value)} placeholder="패턴…" />
              <span className="mono" style={{ fontSize: 10.5, color: 'var(--text-dim)' }}>
                {findQ ? `${IDE_CODE.filter(([, h]) => (h || '').replace(/<[^>]+>/g, '').toLowerCase().includes(findQ.toLowerCase())).length}개 라인 일치 · round.ml` : '패턴을 입력하세요'}
              </span>
            </div>
          )}
          {view === 'split' ? <IdeDiff /> : <IdeEditor file={file} findQ={view === 'find' ? findQ : ''} onJumpAnn={() => { setRailOpen(true); setRailTab('ann'); }} />}
          <div className={`ide-drawer ${drawerOpen ? '' : 'closed'}`}>
            <div className="ide-drawer-h" onClick={() => setDrawerOpen(o => !o)}>
              <span className="chev">▾</span>
              <span>실행 출력 — dune test</span>
              <span className="ok">84/84 ok</span>
              <span style={{ marginLeft: 'auto' }}>oas·seoul-1 · sangsu</span>
            </div>
            <div className="ide-drawer-body">
              {IDE_OUTPUT.map((l, i) => <div key={i} dangerouslySetInnerHTML={{ __html: l }}></div>)}
            </div>
          </div>
        </section>
        {railOpen ? <IdeRail tab={railTab} setTab={setRailTab} /> : <div></div>}
      </div>
    </main>
  );
}

Object.assign(window, { IdeSurface });
