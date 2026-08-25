// @ds-adherence-ignore -- v2 skin surface: the Keepers surface (roster + chat thread + context rail) and the keeper-config glue
/* ══════════════════════════════════════════════════════════════
   MASC v2 — Keepers surface
   The keeper-chat surface lifted out of app.jsx: the three-pane
   roster / thread / context-rail layout, the live model reply loop
   (window.claude.complete + canned fallback), regenerate, and the
   per-keeper config drawer glue (prompt-fill + nav) that delegates
   to window.KVO5.KeeperConfigPanel.

     · KeeperConfig    — app glue around the shared config drawer organism
     · KeepersSurface  — Roster · chat thread · ContextRail (+ mobile panes)

   Top-level fn decls become globals; app.jsx renders <KeepersSurface/>
   and <KeeperConfig/> bare. Load AFTER shell.jsx (ChatHeader/EmptyThread),
   rails.jsx (Roster/ContextRail), messages.jsx (Message/Avatar),
   composer.jsx (Composer), data.jsx; BEFORE app.jsx.
   ══════════════════════════════════════════════════════════════ */

const { useState: useKpS, useRef: useKpRef, useEffect: useKpEffect } = React;

function KeeperConfig({ keeper, onClose, onNav }) {
  useKpEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  // full-screen detail surface (keeper-config.jsx) — replaces the old right drawer.
  return React.createElement(window.KeeperConfigFull, { keeper, onClose, onNav });
}

// ── Markdown → block vocabulary ─────────────────────────────────
// window.claude.complete returns Markdown; the bubble renders structured
// blocks (p/h4/ul/code/callout w/ inline strong·em·code). Parse rather
// than dump raw, so **bold**, `code`, lists and fences render as rich text.
function mdInline(s) {
  // s is ALREADY html-escaped. Protect code spans, then apply inline marks.
  const codes = [];
  s = s.replace(/`([^`]+)`/g, (m, c) => { codes.push(c); return `\u0000${codes.length - 1}\u0000`; });
  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (m, txt, url) => `<a href="${url}" target="_blank" rel="noopener">${txt}</a>`);
  s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  s = s.replace(/__([^_]+)__/g, '<strong>$1</strong>');
  s = s.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
  s = s.replace(/\u0000(\d+)\u0000/g, (m, i) => `<code>${codes[+i]}</code>`);
  return s;
}
function mdToBlocks(text) {
  const esc = (x) => x.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const lines = (text || '').replace(/\r\n/g, '\n').split('\n');
  const blocks = [];
  let i = 0, para = [];
  const flush = () => { if (para.length) { blocks.push({ t: 'p', html: para.map(l => mdInline(esc(l))).join('<br>') }); para = []; } };
  while (i < lines.length) {
    const raw = lines[i], tl = raw.trim();
    const fence = tl.match(/^```(\w*)/);
    if (fence) { flush(); i++; const buf = []; while (i < lines.length && !lines[i].trim().startsWith('```')) { buf.push(lines[i]); i++; } i++; blocks.push({ t: 'code', cap: null, html: esc(buf.join('\n')) }); continue; }
    const h = tl.match(/^#{1,6}\s+(.*)$/);
    if (h) { flush(); blocks.push({ t: 'h4', html: mdInline(esc(h[1])) }); i++; continue; }
    if (/^>\s?/.test(tl)) { flush(); const buf = []; while (i < lines.length && /^>\s?/.test(lines[i].trim())) { buf.push(lines[i].trim().replace(/^>\s?/, '')); i++; } blocks.push({ t: 'callout', html: mdInline(esc(buf.join(' '))) }); continue; }
    if (/^([-*+]\s+|\d+[.)]\s+)/.test(tl)) { flush(); const items = []; while (i < lines.length && /^([-*+]\s+|\d+[.)]\s+)/.test(lines[i].trim())) { items.push(mdInline(esc(lines[i].trim().replace(/^([-*+]\s+|\d+[.)]\s+)/, '')))); i++; } blocks.push({ t: 'ul', items }); continue; }
    if (tl === '') { flush(); i++; continue; }
    para.push(tl); i++;
  }
  flush();
  return blocks.length ? blocks : [{ t: 'p', html: '…' }];
}
// expose the md→blocks parser so other surfaces (e.g. Fusion resolved_answer)
// render the same rich-text vocabulary from one source.
Object.assign(window, { mdToBlocks, mdInline });

function KeepersSurface({ t, setTweak, sel, setSel, keepers, onAction, threads, setThreads, typing, setTyping, isMobile, mobilePane, setMobilePane, ctxDrawer, setCtxDrawer, drawerCtx, onConfig, backTo, onBackTo, onNav, apprStatus }) {
  const threadRef = useKpRef(null);
  const keeper = keepers.find(k => k.id === sel);
  const msgs = threads[sel] || [];
  const rosterOpen = t.rosterOpen !== false;
  const ctxOpen = t.ctxOpen !== false;

  useKpEffect(() => {
    const el = threadRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [sel, msgs.length, typing]);

  const pushUser = (input) => {
    const blocks = typeof input === 'string'
      ? [{ t: 'p', html: input.replace(/</g, '&lt;') }]
      : (input && input.blocks);
    if (!blocks || !blocks.length) return;
    const um = { id: 'u' + Date.now(), role: 'user', source: 'dashboard', ts: nowHM(), blocks };
    setThreads(prev => ({ ...prev, [sel]: [...(prev[sel] || []), um] }));
    setTyping(true);
    respond([...(threads[sel] || []), um]);
  };

  // Real model reply via window.claude.complete, with a graceful canned
  // fallback when the API isn't available (e.g. offline / catalog).
  const respond = async (history, regen) => {
    const stripTags = (h) => (h || '').replace(/<[^>]+>/g, '');
    const blockText = (m) => (m.blocks || []).map(b =>
      (b.t === 'p' || b.t === 'h4') ? stripTags(b.html)
        : b.t === 'ul' ? (b.items || []).map(stripTags).join(' ')
        : b.t === 'voice' ? `(음성) ${b.transcript || ''}`
        : b.t === 'attach' ? `(첫부 ${b.name || ''})`
        : b.t === 'callout' ? stripTags(b.html) : '').filter(Boolean).join(' ');
    const persona = (window.PERSONAS && PERSONAS[keeper.id]) || {};
    const sys = `너는 '${keeper.id}'(이)라는 MASC 멀티에이전트 코딩 에이전트(keeper)다. namespace=${keeper.ns}, 모델=${keeper.model}, 상태=${keeper.phase}. ${persona.persona || ''} ${persona.instructions || ''} 한국어로, 엔지니어답게 간결하게(2~5문장) 답하라. 과한 수시·이모지 금지.`;
    const transcript = history.slice(-7).map(m => `${m.role === 'user' ? 'operator' : keeper.id}: ${blockText(m)}`).join('\n');
    const finish = (msg) => {
      setTyping(false);
      setThreads(prev => ({ ...prev, [sel]: [...(prev[sel] || []), msg] }));
    };
    try {
      if (!(window.claude && window.claude.complete)) throw new Error('no-api');
      const text = await window.claude.complete(`${sys}\n\n[최근 대화]\n${transcript}\n\n${keeper.id}로서 다음 메시지에 답하라:`);
      finish({ id: 'a' + Date.now(), role: 'assistant', source: 'dashboard', ts: nowHM(), blocks: mdToBlocks(text || '…'), live: true, regen });
    } catch (e) {
      finish({ ...CANNED_REPLY(keeper), regen });
    }
  };

  const selectKeeper = (id) => { setSel(id); if (isMobile) setMobilePane('chat'); };

  const regenerate = (mid) => {
    const remaining = (threads[sel] || []).filter(x => x.id !== mid);
    setThreads(prev => ({ ...prev, [sel]: remaining }));
    setTyping(true);
    respond(remaining, true);
  };

  // drag-to-resize a rail. side 'roster' clamps 200..420; 'ctx' clamps 240..460.
  const startResize = (which) => (e) => {
    e.preventDefault();
    const key = which === 'roster' ? 'rosterW' : 'ctxW';
    const min = which === 'roster' ? 200 : 240;
    const max = which === 'roster' ? 440 : 480;
    const startX = e.clientX;
    const startW = (which === 'roster' ? (t.rosterW || 286) : (t.ctxW || 312));
    const dir = which === 'roster' ? 1 : -1; // ctx grows when dragging left
    document.body.classList.add('rail-resizing');
    const onMove = (ev) => {
      const w = Math.max(min, Math.min(max, startW + dir * (ev.clientX - startX)));
      setTweak(key, w);
    };
    const onUp = () => { document.body.classList.remove('rail-resizing'); window.removeEventListener('pointermove', onMove); window.removeEventListener('pointerup', onUp); };
    window.addEventListener('pointermove', onMove);
    window.addEventListener('pointerup', onUp);
  };

  return (
    <React.Fragment>
      <Roster keepers={keepers} selected={sel} onSelect={selectKeeper} mini={!rosterOpen && !isMobile} onConfig={onConfig} onAction={onAction} />
      <div className="chat-wrap" data-screen-label="Keeper 대화">
        {!isMobile && <button className="rail-toggle left" title={rosterOpen ? '로스터 접기' : '로스터 펼치기'}
          onClick={() => setTweak('rosterOpen', !rosterOpen)}>{rosterOpen ? '◂' : '▸'}</button>}
        {!isMobile && rosterOpen && <div className="rail-resizer left" title="드래그하여 로스터 폭 조절" onPointerDown={startResize('roster')}></div>}
        <main className="chat">
          <ChatHeader keeper={keeper} mobile={isMobile}
            onBack={() => setMobilePane('roster')}
            onOpenCtx={() => setCtxDrawer(true)}
            onOpenConfig={onConfig} onAction={onAction} />
          {backTo && !isMobile && (
            <button className="chat-backctx" onClick={onBackTo} title={`${(window.SURFACE_LABEL && SURFACE_LABEL[backTo]) || backTo} 으로 돌아가기`}>
              {'\u2190'} {(window.SURFACE_LABEL && SURFACE_LABEL[backTo]) || backTo} 으로
            </button>
          )}
          <div className="thread" ref={threadRef}>
            {(() => {
              // RFC keeper-conversation-hitl-flow §4.1-A (PR #22230): when this keeper
              // is awaiting a decision, surface a slim pending-review cue in the
              // conversation linking back to the approvals queue (the sole act-point).
              const pend = (window.APPROVALS || []).find(a => a.keeper === sel && (!apprStatus || (apprStatus[a.id] || 'open') === 'open'));
              if (!pend) return null;
              return (
                <button className="chat-pendcue" onClick={() => onNav && onNav('approvals')} title="결재 큐에서 처리">
                  <span className="chat-pendcue-dot"></span>
                  <span className="chat-pendcue-tx">이 keeper는 <b>승인 대기</b> 중 · <span className="mono">{pend.tool}</span></span>
                  <span className="chat-pendcue-arr">결재 큐에서 처리 →</span>
                </button>
              );
            })()}
            {msgs.length === 0
              ? <EmptyThread />
              : (
                <div className="thread-inner">
                  <div className="daydiv">오늘</div>
                  {msgs.map(m => <Message key={m.id} m={m} keeper={keeper} onPickSuggestion={pushUser} onRegenerate={() => regenerate(m.id)} />)}
                  {typing && <TypingMessage keeper={keeper} />}
                </div>
              )}
          </div>
          <Composer keeper={keeper} onSend={pushUser} onAction={onAction} onNav={onNav} />
        </main>
        {!isMobile && <button className="rail-toggle right" title={drawerCtx ? '컨텍스트 열기' : (ctxOpen ? '컨텍스트 레일 접기' : '컨텍스트 레일 펼치기')}
          onClick={() => drawerCtx ? setCtxDrawer(true) : setTweak('ctxOpen', !ctxOpen)}>{drawerCtx ? '◂' : (ctxOpen ? '▸' : '◂')}</button>}
        {!isMobile && !drawerCtx && ctxOpen && <div className="rail-resizer right" title="드래그하여 컨텍스트 폭 조절" onPointerDown={startResize('ctx')}></div>}
      </div>
      {!isMobile && !drawerCtx && ctxOpen && <ContextRail keeper={keeper} onAction={onAction} onNav={onNav} />}
      {(isMobile || drawerCtx) && ctxDrawer && (
        <div className="ctx-overlay" onClick={() => setCtxDrawer(false)}>
          <div className="ctx-drawer" onClick={(e) => e.stopPropagation()}>
            <button className="ctx-drawer-close" onClick={() => setCtxDrawer(false)} title="닫기">{'\u2715'}</button>
            <ContextRail keeper={keeper} onAction={onAction} onNav={onNav} />
          </div>
        </div>
      )}
    </React.Fragment>
  );
}
