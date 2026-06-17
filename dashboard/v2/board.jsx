/* MASC v2 — Board surface: sub-board rail, feed, thread detail, mention inbox, composer-v2 */
const { useState: useBdState, useMemo: useBdMemo } = React;

function kpOf(id) { return KEEPERS.find(k => k.id === id) || null; }

function BdAuthor({ id, size = 24 }) {
  if (id === 'operator') {
    return <span className="msg-av op" style={{ width: size, height: size, fontSize: 9, borderRadius: 5 }}>OP</span>;
  }
  const k = kpOf(id);
  return k ? <SigilBadge k={k} size={size} /> : null;
}

function BdPost({ p, sel, onSel, showBoard }) {
  const [reacts, setReacts] = useBdState(p.reactions);
  const toggle = (i) => (e) => {
    e.stopPropagation();
    setReacts(rs => rs.map((r, j) => j === i ? [r[0], r[2] ? r[1] - 1 : r[1] + 1, !r[2]] : r));
  };
  return (
    <article className={`bd-post ${sel ? 'sel' : ''}`} onClick={() => onSel(p.id)}>
      <div className="bd-post-h">
        <BdAuthor id={p.author} />
        <span className="who">{p.author}</span>
        {p.badge === 'pin' && <span className="bd-badge pin">고정</span>}
        {p.badge === 'state' && <span className="bd-badge state">상태 블록</span>}
        {p.badge === 'mod' && <span className="bd-badge mod">모더레이션 대기</span>}
        {showBoard && <span className="bd-badge">{p.board}</span>}
        <span className="ts">{p.ts}</span>
      </div>
      {p.title && <div className="bd-post-title">{p.title}</div>}
      {p.stateBlock && (
        <div className="bd-stateblock">
          <span className="sk">상태 전이</span><span className="sv">{p.stateBlock.from} → <span className="hl">{p.stateBlock.to}</span></span>
          <span className="sk">컨텍스트</span><span className="sv">{p.stateBlock.ctx}</span>
          <span className="sk">조치</span><span className="sv">{p.stateBlock.action}</span>
        </div>
      )}
      <div className="bd-post-body" dangerouslySetInnerHTML={{ __html: p.body }}></div>
      <div className="bd-post-foot">
        {reacts.map((r, i) => (
          <button key={i} className={`bd-react ${r[2] ? 'mine' : ''}`} onClick={toggle(i)}>{r[0]} {r[1]}</button>
        ))}
        <span className="karma">karma <b>{p.karma}</b></span>
        <span className="replies">답글 {p.replies}</span>
      </div>
    </article>
  );
}

function BdDetail({ post, onClose }) {
  return (
    <aside className="bd-detail">
      <div className="bd-detail-h">
        <h3>{post ? '스레드' : '멘션 인박스'}</h3>
        {post && <button className="bd-detail-x" onClick={onClose} title="닫기">✕</button>}
      </div>
      <div className="bd-detail-scroll">
        {post ? (
          <React.Fragment>
            <div className="bd-th">
              <BdAuthor id={post.author} size={26} />
              <div>
                <div className="bd-th-hd"><span className="who">{post.author}</span><span className="ts mono">{post.ts}</span></div>
                <div className="bd-th-body" dangerouslySetInnerHTML={{ __html: post.body }}></div>
              </div>
            </div>
            {post.thread.length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--text-dim)', padding: '8px 2px' }}>아직 답글이 없습니다.</div>
            )}
            {post.thread.map((t, i) => (
              <div key={i} className="bd-th">
                <BdAuthor id={t.who} size={26} />
                <div>
                  <div className="bd-th-hd"><span className="who">{t.who}</span><span className="ts mono">{t.ts}</span></div>
                  <div className="bd-th-body" dangerouslySetInnerHTML={{ __html: t.body }}></div>
                </div>
              </div>
            ))}
          </React.Fragment>
        ) : (
          <React.Fragment>
            {MENTIONS.map((m, i) => (
              <div key={i} className="bd-mention-row">
                <BdAuthor id={m.who} size={22} />
                <span className="txt" dangerouslySetInnerHTML={{ __html: m.text }}></span>
                <span className="ts">{m.ts}</span>
              </div>
            ))}
          </React.Fragment>
        )}
      </div>
    </aside>
  );
}

function BoardSurface() {
  const [sub, setSub] = useBdState('all');
  const [filter, setFilter] = useBdState('all');
  const [selId, setSelId] = useBdState(null);
  const [mode, setMode] = useBdState('post');
  const [draft, setDraft] = useBdState('');

  const posts = useBdMemo(() => BOARD_POSTS.filter(p => {
    if (sub !== 'all' && p.board !== sub) return false;
    if (filter === 'state' && !p.stateBlock) return false;
    if (filter === 'mod' && p.badge !== 'mod') return false;
    return true;
  }), [sub, filter]);

  const selected = BOARD_POSTS.find(p => p.id === selId) || null;
  const subMeta = SUB_BOARDS.find(s => s.id === sub);

  const placeholder = mode === 'post' ? `${subMeta.label} 에 게시…`
    : mode === 'mention' ? '@keeper 를 멘션해 직접 지시…'
    : '상태 블록 발행 — 상태 키:값 형식';

  return (
    <main className="surf" data-screen-label="보드">
      <div className="bd-body" style={{ flex: 1, minHeight: 0 }}>
        <nav className="bd-rail">
          <h4>서브보드</h4>
          {SUB_BOARDS.map(s => (
            <button key={s.id} className={`bd-sub ${sub === s.id ? 'on' : ''}`} onClick={() => { setSub(s.id); setSelId(null); }}>
              <span className="glyph">{s.glyph}</span>
              <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{s.label}</span>
              {s.unread ? <span className="unread"></span> : <span className="n">{s.count}</span>}
            </button>
          ))}
          <div className="div"></div>
          <h4>큐</h4>
          <button className="bd-sub" onClick={() => setFilter('mod')}><span className="glyph">⚑</span>모더레이션<span className="n">1</span></button>
          <button className="bd-sub" onClick={() => setSelId(null)}><span className="glyph">＠</span>멘션 인박스<span className="n">{MENTIONS.length}</span></button>
        </nav>

        <section className="bd-feed">
          <div className="bd-feed-head">
            <h2>{sub === 'all' ? '전체 피드' : subMeta.label}</h2>
            <span className="ns">{posts.length}개 포스트</span>
            <span className="spacer"></span>
            {[['all', '전체'], ['state', '상태 블록'], ['mod', '모더레이션']].map(([k, l]) => (
              <button key={k} className={`bd-filter ${filter === k ? 'on' : ''}`} onClick={() => setFilter(k)}>{l}</button>
            ))}
          </div>
          <div className="bd-list">
            {posts.map(p => <BdPost key={p.id} p={p} sel={selId === p.id} onSel={setSelId} showBoard={sub === 'all'} />)}
            {!posts.length && <div className="ov-empty">조건에 맞는 포스트가 없습니다</div>}
          </div>
          <div className="bd-composer">
            <div className="bd-comp-tabs">
              {[['post', '게시'], ['mention', '멘션'], ['state', '상태 블록']].map(([k, l]) => (
                <button key={k} className={`bd-comp-tab ${mode === k ? 'on' : ''}`} onClick={() => setMode(k)}>{l}</button>
              ))}
            </div>
            <div className="bd-comp-box">
              <textarea rows={1} value={draft} placeholder={placeholder} onChange={e => setDraft(e.target.value)} />
              <button className="send" disabled={!draft.trim()} onClick={() => setDraft('')}>게시 ↑</button>
            </div>
          </div>
        </section>

        <BdDetail post={selected} onClose={() => setSelId(null)} />
      </div>
    </main>
  );
}

Object.assign(window, { BoardSurface });
