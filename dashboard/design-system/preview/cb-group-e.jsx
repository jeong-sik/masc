// cb-group-e.jsx — Track 2 · COMMS PLANE
// C1 Board Zone (3 variants) · C2 Messages (3 variants) · C3 Composer v2 (3 variants)

const P2e = window.MASC_P2;

// ═══════════════════════════════════════════════════════════════════
// C1 · BOARD ZONE
// ═══════════════════════════════════════════════════════════════════

// helper — render a single post card
function BoardPost({ post, expanded = false }) {
  const net = post.votes_up - post.votes_down;
  const summary = `${post.author} · ${post.kind}${post.hearth ? ' · ' + post.hearth : ''} · ${post.title} · ${net > 0 ? '+' + net : net} net votes · ${post.replies} replies · ${post.at}`;
  return (
    <article className={`bd-post ${post.kind} ${post.hearth === 'merge-blocker' ? 'hot' : ''}`} aria-label={summary}>
      <div className="vote" role="group" aria-label="Vote controls">
        <button type="button" className="up" aria-label="Upvote">▲</button>
        <span className={`net ${net < 0 ? 'neg' : ''}`} aria-label={`${net > 0 ? '+' + net : net} net votes`}>{net > 0 ? `+${net}` : net}</span>
        <button type="button" className="dn" aria-label="Downvote">▼</button>
      </div>
      <div className="main">
        <div className="h" aria-hidden="true">
          <span className="au">{post.author}</span>
          <span className={`kk ${post.kind}`}>{post.kind}</span>
          {post.hearth && <span className="he">♨ {post.hearth}</span>}
          <span className="at">{post.at}</span>
          {post.expires && <span className="exp">expires {post.expires}</span>}
        </div>
        <div className="ttl" role="heading" aria-level={4}>{post.title}</div>
        <div className={`body ${expanded ? 'expand' : 'clip'}`}>{post.body}</div>
        {post.state_block && <div className="state-block" aria-label={`State block: ${post.state_block}`}>{post.state_block}</div>}
        <div className="ft" role="toolbar" aria-label={`Actions for ${post.id}`}>
          <button type="button">↳ reply ({post.replies})</button>
          <button type="button">★ pin</button>
          <button type="button">⊘ mute</button>
          <button type="button">⌗ permalink</button>
        </div>
      </div>
      <div className="meta-r" aria-hidden="true">
        <span>{post.id}</span>
        <span>{post.replies} replies</span>
      </div>
    </article>
  );
}

// C1-A · Feed (hearth-grouped)
function BoardFeed() {
  const [filter, setFilter] = useState('all');
  const byHearth = {};
  P2e.boardPosts.forEach(p => {
    const k = p.hearth || '— no hearth —';
    (byHearth[k] = byHearth[k] || []).push(p);
  });
  const order = ['merge-blocker','keeper-clarity','routing','backlog hygiene','reporting','— no hearth —'];
  const hearths = Object.keys(byHearth).sort((a, b) => {
    const ai = order.indexOf(a); const bi = order.indexOf(b);
    return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi);
  });
  return (
    <section className="cbp" aria-label="Board feed (hearth-grouped)">
      <ZoneHeader
        title="BOARD · FEED"
        branch="main"
        keepers={["scholar","janitor","taskmaster","verdict"]}
        meta={`${P2e.boardPosts.length} live · ${hearths.length} hearths · sort: hot`}
        right={
          <div className="filt" role="radiogroup" aria-label="Post filter">
            {['all','direct','automation'].map(f => (
              <button key={f} type="button" role="radio" aria-checked={filter===f} className={filter===f ? 'on' : ''} onClick={()=>setFilter(f)}>{f}</button>
            ))}
          </div>
        }
      />
      <div className="body">
        {hearths.map(h => (
          <div key={h} className="bd-hearth-grp" role="group" aria-label={`${h} · ${byHearth[h].length} posts`}>
            <div className="hh" role="heading" aria-level={3}>{h} <span className="cn" aria-hidden="true">· {byHearth[h].length}</span></div>
            <div className="bd-feed" role="list" aria-label={`${h} posts`}>
              {byHearth[h].map(p => <div key={p.id} role="listitem"><BoardPost post={p} /></div>)}
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

// C1-B · Single post + thread
function BoardThread() {
  const post = P2e.boardPosts.find(p => p.id === 'p-d179ccfb');
  const replies = P2e.boardComments.filter(c => c.post_id === post.id);
  return (
    <section className="cbp" aria-label={`Board post · ${post.id} · ${replies.length} replies`}>
      <ZoneHeader
        title="BOARD · POST"
        branch="main"
        keepers={[post.author]}
        meta={`${post.id} · ${replies.length} replies · ${post.votes_up}↑ ${post.votes_down}↓`}
        right={<button type="button" className="meta" aria-label="Back to feed">↩ back to feed</button>}
      />
      <div className="body">
        <BoardPost post={post} expanded={true} />
        <div role="heading" aria-level={3} style={{padding:'4px 0', fontFamily:'var(--font-mono)', fontSize:'10px', color:'var(--color-fg-disabled)', letterSpacing:'.08em', textTransform:'uppercase'}}>
          ━━ {replies.length} replies
        </div>
        <div className="bd-thread" role="log" aria-live="polite" aria-label={`${replies.length} replies on ${post.id}`}>
          {replies.map(r => (
            <article key={r.id} className="reply" aria-label={`${r.author} at ${r.at}: ${r.body}`}>
              <div className="h" aria-hidden="true">
                <span className="au">{r.author}</span>
                <span className="at">{r.at}</span>
              </div>
              <div className="body">{r.body}</div>
            </article>
          ))}
        </div>
        <div role="textbox" aria-label="Reply composer (placeholder)" style={{marginTop:8, padding:'6px 8px', background:'var(--color-bg-surface)', border:'1px dashed var(--color-border-strong)', fontFamily:'var(--font-mono)', fontSize:'11px', color:'var(--color-fg-disabled)'}}>
          <span aria-hidden="true" style={{color:'var(--brass-1)'}}>masc&gt;</span> reply...
          <span aria-hidden="true" style={{color:'var(--brass-1)', animation:'anim-blink 1s step-end infinite'}}> ▌</span>
        </div>
      </div>
    </section>
  );
}

// C1-C · Hot vs automation toggle
function BoardHotAuto() {
  const [tab, setTab] = useState('hot');
  const direct = P2e.boardPosts.filter(p => p.kind === 'direct');
  const automation = P2e.boardPosts.filter(p => p.kind === 'automation');
  const shown = tab === 'hot' ? direct : automation;
  return (
    <section className="cbp" aria-label="Board · direct vs automation toggle">
      <ZoneHeader
        title="BOARD · MODE TOGGLE"
        branch="main"
        keepers={["scholar","janitor"]}
        meta={`direct ${direct.length} · automation ${automation.length}`}
        right={
          <div className="filt" role="tablist" aria-label="Post category">
            <button type="button" role="tab" aria-selected={tab==='hot'} aria-controls="board-mode-panel" tabIndex={tab==='hot'?0:-1} className={tab==='hot'?'on':''} onClick={()=>setTab('hot')}>direct {direct.length}</button>
            <button type="button" role="tab" aria-selected={tab==='auto'} aria-controls="board-mode-panel" tabIndex={tab==='auto'?0:-1} className={tab==='auto'?'on':''} onClick={()=>setTab('auto')}>automation {automation.length}</button>
          </div>
        }
      />
      <div className="body" id="board-mode-panel" role="tabpanel" aria-label={tab==='hot' ? 'Direct posts' : 'Automation posts'}>
        <div className="bd-feed" role="list" aria-label={`${shown.length} posts`}>
          {shown.map(p => <div key={p.id} role="listitem"><BoardPost post={p} /></div>)}
        </div>
      </div>
    </section>
  );
}

// ═══════════════════════════════════════════════════════════════════
// C2 · MESSAGES / BROADCAST
// ═══════════════════════════════════════════════════════════════════

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
    <section className="cbp" aria-label="Message room timeline">
      <ZoneHeader
        title="MESSAGES · ROOM TIMELINE"
        branch="main"
        keepers={["sangsu","nick0cave","masc-improver","qa-king"]}
        meta={`#${room} · seq up to ${msgs[0]?.seq || 0}`}
      />
      <div className="body flat" style={{padding:0}}>
        <div className="ms-room">
          <div className="roomlist" role="tablist" aria-label="Rooms" aria-orientation="vertical">
            {P2e.rooms.map(r => (
              <button key={r.id}
                      type="button"
                      role="tab"
                      aria-selected={room===r.id}
                      aria-controls="ms-room-panel"
                      tabIndex={room===r.id ? 0 : -1}
                      aria-label={`#${r.name}, ${r.unread} unread`}
                      className={`room ${room===r.id?'on':''}`}
                      onClick={()=>setRoom(r.id)}>
                <span className="nm" aria-hidden="true">{r.name}</span>
                <span className={`un ${r.unread===0?'zero':''}`} aria-hidden="true">{r.unread}</span>
              </button>
            ))}
          </div>
          <div className="feed" id="ms-room-panel" role="tabpanel" aria-label={`#${room} timeline · ${msgs.length} messages`}>
            <div className="timeline" role="log" aria-live="polite">
              {msgs.map(m => (
                <article key={m.seq} className="ms-msg" aria-label={`#${m.seq} · ${m.from} ${m.kind} at ${m.at}: ${m.body}`}>
                  <div className="seq" aria-hidden="true">#{m.seq}</div>
                  <div className="body">
                    <div className="h" aria-hidden="true">
                      <span className="au">{m.from}</span>
                      <span className={`kk ${m.kind}`}>{m.kind}</span>
                      <span className="at">{m.at}</span>
                    </div>
                    <div className="text">{renderMsgBody(m.body, m.mentions)}</div>
                    {m.state && <div className="state-block" aria-label={`State block: ${m.state}`}>{m.state}</div>}
                  </div>
                </article>
              ))}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

// C2-B · Mention inbox
function MentionInbox() {
  const me = 'nick0cave';
  const mine = P2e.messages.filter(m => m.mentions.includes(me));
  const otherMentions = P2e.messages.filter(m => m.mentions.length > 0 && !m.mentions.includes(me));
  return (
    <section className="cbp" aria-label={`Mention inbox · ${mine.length} for me, ${otherMentions.length} others`}>
      <ZoneHeader
        title="MESSAGES · MENTIONS"
        branch="main"
        keepers={[me]}
        meta={`${mine.length} for me · ${otherMentions.length} others`}
        right={<span className="meta" style={{color:'var(--brass-1)'}}>@{me}</span>}
      />
      <div className="body">
        <div role="heading" aria-level={3} style={{fontFamily:'var(--font-mono)', fontSize:'10px', color:'var(--brass-1)', letterSpacing:'.1em', textTransform:'uppercase', padding:'2px 0'}}>━━ for me · {mine.length}</div>
        <div className="ms-inbox" role="log" aria-live="polite" aria-label={`${mine.length} mentions for me`}>
          {mine.map(m => (
            <article key={m.seq} className="mn" aria-label={`#${m.seq} · ${m.from} in #${m.room} at ${m.at}: ${m.body}`}>
              <div className="h" aria-hidden="true">
                <span className="au">{m.from}</span>
                <span className="rm">→ #{m.room}</span>
                <span className="at">{m.at} · #{m.seq}</span>
              </div>
              <div className="text">{renderMsgBody(m.body, m.mentions)}</div>
            </article>
          ))}
        </div>
        <div role="heading" aria-level={3} style={{fontFamily:'var(--font-mono)', fontSize:'10px', color:'var(--color-fg-disabled)', letterSpacing:'.1em', textTransform:'uppercase', padding:'8px 0 2px', borderTop:'1px dashed var(--color-border-strong)'}}>━━ other mentions · {otherMentions.length}</div>
        <div className="ms-inbox" role="log" aria-live="polite" aria-label={`${otherMentions.length} other mentions`}>
          {otherMentions.map(m => (
            <article key={m.seq} className="mn" aria-label={`#${m.seq} · ${m.from} in #${m.room} at ${m.at}: ${m.body}`} style={{borderLeftColor:'var(--info)', opacity:.7}}>
              <div className="h" aria-hidden="true">
                <span className="au">{m.from}</span>
                <span className="rm">→ #{m.room}</span>
                <span className="at">{m.at} · #{m.seq}</span>
              </div>
              <div className="text">{renderMsgBody(m.body, m.mentions)}</div>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}

// C2-C · State-block message focus
function StateBlockMessage() {
  const stateMsgs = P2e.messages.filter(m => m.state);
  return (
    <section className="cbp" aria-label="State-block messages">
      <ZoneHeader
        title="MESSAGES · [STATE] BLOCKS"
        branch="main"
        keepers={["nick0cave","sangsu"]}
        meta={`${stateMsgs.length} state-bearing msgs · structured payload`}
      />
      <div className="body">
        <p style={{fontFamily:'var(--font-mono)', fontSize:'10px', color:'var(--color-fg-disabled)', padding:'4px 0', lineHeight:1.5}}>
          [STATE] blocks are inline, machine-readable structure inside human prose. Keepers stamp them on every broadcast that changes goal/intention/blocker state. Other keepers parse them silently and update local belief.
        </p>
        <div role="list" aria-label={`${stateMsgs.length} state messages`}>
          {stateMsgs.map(m => (
            <article key={m.seq}
                     role="listitem"
                     className="ms-msg"
                     aria-label={`#${m.seq} · ${m.from} ${m.kind} → #${m.room} · ${m.at}: ${m.body} · state: ${m.state}`}
                     style={{padding:'8px 10px', background:'var(--color-bg-surface)', border:'1px solid var(--color-border-default)', borderLeft:'2px solid var(--brass-2)', borderRadius:0}}>
              <div className="seq" aria-hidden="true">#{m.seq}</div>
              <div className="body">
                <div className="h" aria-hidden="true">
                  <span className="au">{m.from}</span>
                  <span className={`kk ${m.kind}`}>{m.kind}</span>
                  <span className="at">→ #{m.room} · {m.at}</span>
                </div>
                <div className="text">{renderMsgBody(m.body, m.mentions)}</div>
                <div className="state-block" aria-label={`State block: ${m.state}`}>{m.state}</div>
              </div>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}

// ═══════════════════════════════════════════════════════════════════
// C3 · COMPOSER V2  (broadcast / mention / state-block)
// ═══════════════════════════════════════════════════════════════════

// C3-A · Broadcast
function ComposerV2Broadcast() {
  return (
    <div className="cb-board" style={{flexDirection:'column-reverse'}}>
      <div className="cm2" role="region" aria-label="Composer v2 · broadcast">
        <div className="toolbar" role="toolbar" aria-label="Composer toolbar">
          <div className="seg" role="radiogroup" aria-label="Message kind">
            <button type="button" role="radio" aria-checked="true" className="on">broadcast</button>
            <button type="button" role="radio" aria-checked="false">dm</button>
            <button type="button" role="radio" aria-checked="false">state</button>
          </div>
          <span className="room-sel" aria-label="Target room: default">default</span>
          <span className="grow" aria-hidden="true" />
          <span aria-label="Sequence 9 keepers, 38 chars" style={{fontFamily:'var(--font-mono)', fontSize:'10px', color:'var(--color-fg-disabled)', letterSpacing:'.04em'}}>
            seq {P2e.messages[0].seq + 1} · 9 keepers · 38 chars
          </span>
          <button type="button" className="send">send ⌘↵</button>
        </div>
        <div className="ed" role="textbox" aria-label="Broadcast composer" aria-multiline="true">claimed task-031. backporting to release-0.42 next.<span className="caret" aria-hidden="true">▌</span></div>
        <div className="hint" aria-hidden="true">
          <span><span className="kbd">@</span>mention</span>
          <span><span className="kbd">[</span>state-block</span>
          <span><span className="kbd">⌘D</span>dm-mode</span>
          <span><span className="kbd">⌘↵</span>send</span>
          <span style={{marginLeft:'auto'}}>last broadcast 16s ago</span>
        </div>
      </div>
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
    </div>
  );
}

// C3-B · Mention with autocomplete
function ComposerV2Mention() {
  return (
    <div className="cb-board" style={{flexDirection:'column-reverse'}}>
      <div className="cm2" role="region" aria-label="Composer v2 · mention with autocomplete" style={{position:'relative'}}>
        <div role="listbox" aria-label="Mention autocomplete (match @nick)" style={{
          position:'absolute', bottom:'100%', left:14, marginBottom:4,
          background:'var(--color-bg-surface)', border:'1px solid var(--brass-2)', borderRadius:0, minWidth:240, padding:0,
          fontFamily:'var(--font-mono)', fontSize:'11px',
          boxShadow:'0 -4px 12px rgb(0 0 0 / .4)',
        }}>
          <div role="presentation" style={{padding:'3px 8px', background:'var(--color-bg-panel-alt)', color:'var(--color-fg-disabled)', fontSize:'9px', letterSpacing:'.1em', textTransform:'uppercase'}}>match @nick</div>
          {[
            { id:'nick0cave', role:'Captain · merge', match:true },
            { id:'nickelodeon', role:'(unknown — alias)', match:false },
          ].map((k, i) => (
            <div key={k.id}
                 role="option"
                 aria-selected={i===0}
                 aria-label={`@${k.id} · ${k.role}${k.match ? '' : ' · no match'}`}
                 style={{
                   padding:'4px 8px', display:'flex', gap:6, alignItems:'center',
                   background: i===0 ? 'rgb(var(--brass-glow)/.12)' : 'transparent',
                   borderLeft: i===0 ? '2px solid var(--brass-1)' : '2px solid transparent',
                   cursor:'pointer',
                   opacity: k.match ? 1 : .5,
                 }}>
              <span aria-hidden="true" style={{color:'var(--brass-1)'}}>@{k.id}</span>
              <span aria-hidden="true" style={{color:'var(--color-fg-disabled)', marginLeft:'auto', fontSize:'9px', letterSpacing:'.04em', textTransform:'uppercase'}}>{k.role}</span>
            </div>
          ))}
        </div>
        <div className="toolbar" role="toolbar" aria-label="Composer toolbar">
          <div className="seg" role="radiogroup" aria-label="Message kind">
            <button type="button" role="radio" aria-checked="true" className="on">broadcast</button>
            <button type="button" role="radio" aria-checked="false">dm</button>
            <button type="button" role="radio" aria-checked="false">state</button>
          </div>
          <span className="room-sel" aria-label="Target room: merge-blockers">merge-blockers</span>
          <span className="grow" aria-hidden="true" />
          <button type="button" className="send">send ⌘↵</button>
        </div>
        <div className="ed" role="textbox" aria-label="Composer with mention" aria-multiline="true">PR #9712 commit 51f062 confirmed in da11b0632. closing the dup task. <span className="mention">@nick</span><span className="caret" aria-hidden="true">▌</span></div>
        <div className="targets" aria-label="Will mention: @nick0cave">
          <span aria-hidden="true">will mention:</span>
          <span className="t-pill" aria-hidden="true">@nick0cave</span>
          <span aria-hidden="true" style={{marginLeft:'auto', color:'var(--color-fg-disabled)', textTransform:'none'}}>↑↓ pick · ⇥ accept · esc dismiss</span>
        </div>
      </div>
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
    </div>
  );
}

// C3-C · State-block compose
function ComposerV2State() {
  return (
    <div className="cb-board" style={{flexDirection:'column-reverse'}}>
      <div className="cm2" role="region" aria-label="Composer v2 · state-block compose">
        <div className="toolbar" role="toolbar" aria-label="Composer toolbar">
          <div className="seg" role="radiogroup" aria-label="Message kind">
            <button type="button" role="radio" aria-checked="false">broadcast</button>
            <button type="button" role="radio" aria-checked="false">dm</button>
            <button type="button" role="radio" aria-checked="true" className="on">state</button>
          </div>
          <span className="room-sel" aria-label="Target room: default">default</span>
          <span aria-label="Structured · machine-readable" style={{fontFamily:'var(--font-mono)', fontSize:'10px', color:'var(--brass-1)', letterSpacing:'.04em'}}>
            ◆ structured · machine-readable
          </span>
          <span className="grow" aria-hidden="true" />
          <button type="button" className="send">send ⌘↵</button>
        </div>
        <div className="ed" role="textbox" aria-label="State-block composer · 4 keys: Goal, Phase, Next, Blocker" aria-multiline="true">
          claimed task-031. backporting to release-0.42 next.
          {'\n'}
          <span className="state-block">[STATE]{'\n'}Goal: goal-merge-blockers{'\n'}Phase: executing{'\n'}Next: rebase + ci{'\n'}Blocker: none{'\n'}[/STATE]<span className="caret" aria-hidden="true">▌</span></span>
        </div>
        <div className="targets" aria-label="Parsed keys: Goal, Phase, Next, Blocker · 4 keys valid · will update belief in 9 keepers">
          <span aria-hidden="true">parsed keys:</span>
          <span className="t-pill" aria-hidden="true">Goal</span>
          <span className="t-pill" aria-hidden="true">Phase</span>
          <span className="t-pill" aria-hidden="true">Next</span>
          <span className="t-pill" aria-hidden="true">Blocker</span>
          <span aria-hidden="true" style={{marginLeft:'auto', color:'var(--color-fg-disabled)', textTransform:'none'}}>4 keys · valid · will update belief in 9 keepers</span>
        </div>
      </div>
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
    </div>
  );
}

Object.assign(window, {
  BoardFeed, BoardThread, BoardHotAuto,
  MessageRoomTimeline, MentionInbox, StateBlockMessage,
  ComposerV2Broadcast, ComposerV2Mention, ComposerV2State,
});
