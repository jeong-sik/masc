// cb-group-e.jsx — Track 2 · COMMS PLANE
// C1 Board Zone (3 variants) · C2 Messages (3 variants) · C3 Composer v2 (3 variants)

const P2e = window.MASC_P2;

// ═══════════════════════════════════════════════════════════════════
// C1 · BOARD ZONE
// ═══════════════════════════════════════════════════════════════════

// helper — render a single post card
function BoardPost({ post, expanded = false }) {
  const net = post.votes_up - post.votes_down;
  return (
    <div className={`bd-post ${post.kind} ${post.hearth === 'merge-blocker' ? 'hot' : ''}`}>
      <div className="vote">
        <span className="up" title="upvote">▲</span>
        <span className={`net ${net < 0 ? 'neg' : ''}`}>{net > 0 ? `+${net}` : net}</span>
        <span className="dn" title="downvote">▼</span>
      </div>
      <div className="main">
        <div className="h">
          <span className="au">{post.author}</span>
          <span className={`kk ${post.kind}`}>{post.kind}</span>
          {post.hearth && <span className="he">♨ {post.hearth}</span>}
          <span className="at">{post.at}</span>
          {post.expires && <span className="exp">expires {post.expires}</span>}
        </div>
        <div className="ttl">{post.title}</div>
        <div className={`body ${expanded ? 'expand' : 'clip'}`}>{post.body}</div>
        {post.state_block && <div className="state-block">{post.state_block}</div>}
        <div className="ft">
          <button>↳ reply ({post.replies})</button>
          <button>★ pin</button>
          <button>⊘ mute</button>
          <button>⌗ permalink</button>
        </div>
      </div>
      <div className="meta-r">
        <span>{post.id}</span>
        <span>{post.replies} replies</span>
      </div>
    </div>
  );
}

// C1-A · Feed (hearth-grouped)
function BoardFeed() {
  // group posts by hearth
  const byHearth = {};
  P2e.boardPosts.forEach(p => {
    const k = p.hearth || '— no hearth —';
    (byHearth[k] = byHearth[k] || []).push(p);
  });
  // sort hearths so merge-blocker first
  const order = ['merge-blocker','keeper-clarity','routing','backlog hygiene','reporting','— no hearth —'];
  const hearths = Object.keys(byHearth).sort((a, b) => {
    const ai = order.indexOf(a); const bi = order.indexOf(b);
    return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi);
  });
  return (
    <div className="cbp">
      <ZoneHeader
        title="BOARD · FEED"
        branch="main"
        keepers={["scholar","janitor","taskmaster","verdict"]}
        meta={`${P2e.boardPosts.length} live · ${hearths.length} hearths · sort: hot`}
        right={
          <div className="filt">
            <button className="on">all</button>
            <button>direct</button>
            <button>automation</button>
          </div>
        }
      />
      <div className="body">
        {hearths.map(h => (
          <div key={h} className="bd-hearth-grp">
            <div className="hh">{h} <span className="cn">· {byHearth[h].length}</span></div>
            <div className="bd-feed">
              {byHearth[h].map(p => <BoardPost key={p.id} post={p} />)}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// C1-B · Single post + thread
function BoardThread() {
  const post = P2e.boardPosts.find(p => p.id === 'p-d179ccfb');  // scholar's "Backlog 정리" post w/ replies
  const replies = P2e.boardComments.filter(c => c.post_id === post.id);
  return (
    <div className="cbp">
      <ZoneHeader
        title="BOARD · POST"
        branch="main"
        keepers={[post.author]}
        meta={`${post.id} · ${replies.length} replies · ${post.votes_up}↑ ${post.votes_down}↓`}
        right={<span className="meta">↩ back to feed</span>}
      />
      <div className="body">
        <BoardPost post={post} expanded={true} />
        <div style={{padding:'4px 0', fontFamily:'var(--font-mono)', fontSize:'10px', color:'var(--fg-4)', letterSpacing:'.08em', textTransform:'uppercase'}}>
          ━━ {replies.length} replies
        </div>
        <div className="bd-thread">
          {replies.map(r => (
            <div key={r.id} className="reply">
              <div className="h">
                <span className="au">{r.author}</span>
                <span className="at">{r.at}</span>
              </div>
              <div className="body">{r.body}</div>
            </div>
          ))}
        </div>
        <div style={{marginTop:8, padding:'6px 8px', background:'var(--bg-1)', border:'1px dashed var(--line-2)', fontFamily:'var(--font-mono)', fontSize:'11px', color:'var(--fg-4)'}}>
          <span style={{color:'var(--brass-1)'}}>masc&gt;</span> reply...
          <span style={{color:'var(--brass-1)', animation:'anim-blink 1s step-end infinite'}}> ▌</span>
        </div>
      </div>
    </div>
  );
}

// C1-C · Hot vs automation toggle
function BoardHotAuto() {
  const [tab, setTab] = useState('hot');
  const direct = P2e.boardPosts.filter(p => p.kind === 'direct');
  const automation = P2e.boardPosts.filter(p => p.kind === 'automation');
  const shown = tab === 'hot' ? direct : automation;
  return (
    <div className="cbp">
      <ZoneHeader
        title="BOARD · MODE TOGGLE"
        branch="main"
        keepers={["scholar","janitor"]}
        meta={`direct ${direct.length} · automation ${automation.length}`}
        right={
          <div className="filt">
            <button className={tab==='hot'?'on':''} onClick={()=>setTab('hot')}>direct {direct.length}</button>
            <button className={tab==='auto'?'on':''} onClick={()=>setTab('auto')}>automation {automation.length}</button>
          </div>
        }
      />
      <div className="body">
        <div className="bd-feed">
          {shown.map(p => <BoardPost key={p.id} post={p} />)}
        </div>
      </div>
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════
// C2 · MESSAGES / BROADCAST
// ═══════════════════════════════════════════════════════════════════

// helper — render message body with @mention highlight
function renderMsgBody(body, mentions = []) {
  if (!mentions.length) return body;
  let parts = [body];
  mentions.forEach(m => {
    parts = parts.flatMap(p => {
      if (typeof p !== 'string') return [p];
      const re = new RegExp(`(@${m})`);
      return p.split(re).map((seg, i) => seg === `@${m}` ? <span key={`${m}${i}`} className="mention">{seg}</span> : seg);
    });
  });
  return parts;
}

// C2-A · Room timeline
function MessageRoomTimeline() {
  const [room, setRoom] = useState('default');
  const msgs = P2e.messages.filter(m => m.room === room);
  return (
    <div className="cbp">
      <ZoneHeader
        title="MESSAGES · ROOM TIMELINE"
        branch="main"
        keepers={["sangsu","nick0cave","masc-improver","qa-king"]}
        meta={`#${room} · seq up to ${msgs[0]?.seq || 0}`}
      />
      <div className="body flat" style={{padding:0}}>
        <div className="ms-room">
          <div className="roomlist">
            {P2e.rooms.map(r => (
              <div key={r.id} className={`room ${room===r.id?'on':''}`} onClick={()=>setRoom(r.id)}>
                <span className="nm">{r.name}</span>
                <span className={`un ${r.unread===0?'zero':''}`}>{r.unread}</span>
              </div>
            ))}
          </div>
          <div className="feed">
            <div className="timeline">
              {msgs.map(m => (
                <div key={m.seq} className="ms-msg">
                  <div className="seq">#{m.seq}</div>
                  <div className="body">
                    <div className="h">
                      <span className="au">{m.from}</span>
                      <span className={`kk ${m.kind}`}>{m.kind}</span>
                      <span className="at">{m.at}</span>
                    </div>
                    <div className="text">{renderMsgBody(m.body, m.mentions)}</div>
                    {m.state && <div className="state-block">{m.state}</div>}
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

// C2-B · Mention inbox
function MentionInbox() {
  // pretend "I" am nick0cave; show all msgs that @ me
  const me = 'nick0cave';
  const mine = P2e.messages.filter(m => m.mentions.includes(me));
  const otherMentions = P2e.messages.filter(m => m.mentions.length > 0 && !m.mentions.includes(me));
  return (
    <div className="cbp">
      <ZoneHeader
        title="MESSAGES · MENTIONS"
        branch="main"
        keepers={[me]}
        meta={`${mine.length} for me · ${otherMentions.length} others`}
        right={<span className="meta" style={{color:'var(--brass-1)'}}>@{me}</span>}
      />
      <div className="body">
        <div style={{fontFamily:'var(--font-mono)', fontSize:'10px', color:'var(--brass-1)', letterSpacing:'.1em', textTransform:'uppercase', padding:'2px 0'}}>━━ for me · {mine.length}</div>
        <div className="ms-inbox">
          {mine.map(m => (
            <div key={m.seq} className="mn">
              <div className="h">
                <span className="au">{m.from}</span>
                <span className="rm">→ #{m.room}</span>
                <span className="at">{m.at} · #{m.seq}</span>
              </div>
              <div className="text">{renderMsgBody(m.body, m.mentions)}</div>
            </div>
          ))}
        </div>
        <div style={{fontFamily:'var(--font-mono)', fontSize:'10px', color:'var(--fg-4)', letterSpacing:'.1em', textTransform:'uppercase', padding:'8px 0 2px', borderTop:'1px dashed var(--line-2)'}}>━━ other mentions · {otherMentions.length}</div>
        <div className="ms-inbox">
          {otherMentions.map(m => (
            <div key={m.seq} className="mn" style={{borderLeftColor:'var(--info)', opacity:.7}}>
              <div className="h">
                <span className="au">{m.from}</span>
                <span className="rm">→ #{m.room}</span>
                <span className="at">{m.at} · #{m.seq}</span>
              </div>
              <div className="text">{renderMsgBody(m.body, m.mentions)}</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// C2-C · State-block message focus
function StateBlockMessage() {
  const stateMsgs = P2e.messages.filter(m => m.state);
  return (
    <div className="cbp">
      <ZoneHeader
        title="MESSAGES · [STATE] BLOCKS"
        branch="main"
        keepers={["nick0cave","sangsu"]}
        meta={`${stateMsgs.length} state-bearing msgs · structured payload`}
      />
      <div className="body">
        <div style={{fontFamily:'var(--font-mono)', fontSize:'10px', color:'var(--fg-4)', padding:'4px 0', lineHeight:1.5}}>
          [STATE] blocks are inline, machine-readable structure inside human prose. Keepers stamp them on every broadcast that changes goal/intention/blocker state. Other keepers parse them silently and update local belief.
        </div>
        {stateMsgs.map(m => (
          <div key={m.seq} className="ms-msg" style={{padding:'8px 10px', background:'var(--bg-1)', border:'1px solid var(--line-1)', borderLeft:'2px solid var(--brass-2)', borderRadius:0}}>
            <div className="seq">#{m.seq}</div>
            <div className="body">
              <div className="h">
                <span className="au">{m.from}</span>
                <span className={`kk ${m.kind}`}>{m.kind}</span>
                <span className="at">→ #{m.room} · {m.at}</span>
              </div>
              <div className="text">{renderMsgBody(m.body, m.mentions)}</div>
              <div className="state-block">{m.state}</div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════
// C3 · COMPOSER V2  (broadcast / mention / state-block)
// ═══════════════════════════════════════════════════════════════════

// C3-A · Broadcast
function ComposerV2Broadcast() {
  return (
    <div className="cb-board" style={{flexDirection:'column-reverse'}}>
      <div className="cm2">
        <div className="toolbar">
          <div className="seg">
            <button className="on">broadcast</button>
            <button>dm</button>
            <button>state</button>
          </div>
          <span className="room-sel">default</span>
          <span className="grow" />
          <span style={{fontFamily:'var(--font-mono)', fontSize:'10px', color:'var(--fg-4)', letterSpacing:'.04em'}}>
            seq {P2e.messages[0].seq + 1} · 9 keepers · 38 chars
          </span>
          <button className="send">send ⌘↵</button>
        </div>
        <div className="ed">claimed task-031. backporting to release-0.42 next.<span className="caret">▌</span></div>
        <div className="hint">
          <span><span className="kbd">@</span>mention</span>
          <span><span className="kbd">[</span>state-block</span>
          <span><span className="kbd">⌘D</span>dm-mode</span>
          <span><span className="kbd">⌘↵</span>send</span>
          <span style={{marginLeft:'auto'}}>last broadcast 16s ago</span>
        </div>
      </div>
      <div style={{flex:1, background:'var(--bg-0)'}} />
    </div>
  );
}

// C3-B · Mention with autocomplete
function ComposerV2Mention() {
  return (
    <div className="cb-board" style={{flexDirection:'column-reverse'}}>
      <div className="cm2" style={{position:'relative'}}>
        {/* autocomplete dropdown */}
        <div style={{
          position:'absolute', bottom:'100%', left:14, marginBottom:4,
          background:'var(--bg-1)', border:'1px solid var(--brass-2)', borderRadius:0, minWidth:240, padding:0,
          fontFamily:'var(--font-mono)', fontSize:'11px',
          boxShadow:'0 -4px 12px rgb(0 0 0 / .4)',
        }}>
          <div style={{padding:'3px 8px', background:'var(--bg-2)', color:'var(--fg-4)', fontSize:'9px', letterSpacing:'.1em', textTransform:'uppercase'}}>match @nick</div>
          {[
            { id:'nick0cave', role:'Captain · merge', match:true },
            { id:'nickelodeon', role:'(unknown — alias)', match:false },
          ].map((k, i) => (
            <div key={k.id} style={{
              padding:'4px 8px', display:'flex', gap:6, alignItems:'center',
              background: i===0 ? 'rgb(var(--brass-glow)/.12)' : 'transparent',
              borderLeft: i===0 ? '2px solid var(--brass-1)' : '2px solid transparent',
              cursor:'pointer',
              opacity: k.match ? 1 : .5,
            }}>
              <span style={{color:'var(--brass-1)'}}>@{k.id}</span>
              <span style={{color:'var(--fg-4)', marginLeft:'auto', fontSize:'9px', letterSpacing:'.04em', textTransform:'uppercase'}}>{k.role}</span>
            </div>
          ))}
        </div>
        <div className="toolbar">
          <div className="seg">
            <button className="on">broadcast</button>
            <button>dm</button>
            <button>state</button>
          </div>
          <span className="room-sel">merge-blockers</span>
          <span className="grow" />
          <button className="send">send ⌘↵</button>
        </div>
        <div className="ed">PR #9712 commit 51f062 confirmed in da11b0632. closing the dup task. <span className="mention">@nick</span><span className="caret">▌</span></div>
        <div className="targets">
          will mention:
          <span className="t-pill">@nick0cave</span>
          <span style={{marginLeft:'auto', color:'var(--fg-4)', textTransform:'none'}}>↑↓ pick · ⇥ accept · esc dismiss</span>
        </div>
      </div>
      <div style={{flex:1, background:'var(--bg-0)'}} />
    </div>
  );
}

// C3-C · State-block compose
function ComposerV2State() {
  return (
    <div className="cb-board" style={{flexDirection:'column-reverse'}}>
      <div className="cm2">
        <div className="toolbar">
          <div className="seg">
            <button>broadcast</button>
            <button>dm</button>
            <button className="on">state</button>
          </div>
          <span className="room-sel">default</span>
          <span style={{fontFamily:'var(--font-mono)', fontSize:'10px', color:'var(--brass-1)', letterSpacing:'.04em'}}>
            ◆ structured · machine-readable
          </span>
          <span className="grow" />
          <button className="send">send ⌘↵</button>
        </div>
        <div className="ed">
          claimed task-031. backporting to release-0.42 next.
          {'\n'}
          <span className="state-block">[STATE]{'\n'}Goal: goal-merge-blockers{'\n'}Phase: executing{'\n'}Next: rebase + ci{'\n'}Blocker: none{'\n'}[/STATE]<span className="caret">▌</span></span>
        </div>
        <div className="targets">
          parsed keys:
          <span className="t-pill">Goal</span>
          <span className="t-pill">Phase</span>
          <span className="t-pill">Next</span>
          <span className="t-pill">Blocker</span>
          <span style={{marginLeft:'auto', color:'var(--fg-4)', textTransform:'none'}}>4 keys · valid · will update belief in 9 keepers</span>
        </div>
      </div>
      <div style={{flex:1, background:'var(--bg-0)'}} />
    </div>
  );
}

Object.assign(window, {
  BoardFeed, BoardThread, BoardHotAuto,
  MessageRoomTimeline, MentionInbox, StateBlockMessage,
  ComposerV2Broadcast, ComposerV2Mention, ComposerV2State,
});
