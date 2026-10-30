/* MASC v2 — composer: multimodal message input (text · 이미지/파일 첨부 · 음성 받아쓰기)
   Extracted from app.jsx so the input surface is one self-contained component.
   onSend({ blocks }) is called with an ordered blocks[] (attach… · voice? · p?). */
const { useState: useCS, useRef: useCRef, useEffect: useCEff } = React;

let __attUid = 0;
const nextAttId = () => 'att' + (++__attUid) + '-' + Date.now().toString(36);

// File → { src(dataURL), dims } for images; dims null for non-images.
function readDropFile(file) {
  return new Promise((resolve) => {
    if (!file.type.startsWith('image/')) { resolve({ src: null, dims: null }); return; }
    const r = new FileReader();
    r.onload = () => {
      const img = new Image();
      img.onload = () => resolve({ src: r.result, dims: `${img.naturalWidth}×${img.naturalHeight}` });
      img.onerror = () => resolve({ src: r.result, dims: null });
      img.src = r.result;
    };
    r.onerror = () => resolve({ src: null, dims: null });
    r.readAsDataURL(file);
  });
}

const fmtSize = (b) => b < 1024 ? `${b} B` : b < 1024 * 1024 ? `${(b / 1024).toFixed(0)} KB` : `${(b / 1048576).toFixed(1)} MB`;
const fmtClock = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;

// ── pending attachment chip (above the textarea, before send) ──
function AttachDraft({ a, onRemove }) {
  return (
    <div className="cdraft att">
      <div className="cdraft-thumb">
        {a.src ? <img src={a.src} alt={a.name} /> : <span className="cdraft-glyph">{'\u25EB'}</span>}
      </div>
      <div className="cdraft-meta">
        <span className="cdraft-name mono">{a.name}</span>
        <span className="cdraft-sub mono">{[a.dims, a.size].filter(Boolean).join(' · ')}</span>
      </div>
      <button className="cdraft-x" title="첨부 제거" onClick={onRemove}>{'\u2715'}</button>
    </div>
  );
}

// ── captured voice draft (waveform + STT transcript, before send) ──
function VoiceDraft({ v, onRemove }) {
  return (
    <div className="cdraft voice">
      <span className="cdraft-glyph mic">{'\u25CC'}</span>
      <div className="cdraft-wave">
        {v.wave.map((h, i) => <span key={i} className="vbar on" style={{ height: `${Math.round(4 + h * 18)}px` }}></span>)}
      </div>
      <span className="cdraft-dur mono">{fmtClock(v.secs)}</span>
      <div className="cdraft-tx">
        <span className="cdraft-tx-k">받아쓰기</span>
        <span className="cdraft-tx-v">{v.transcript}</span>
      </div>
      <button className="cdraft-x" title="음성 제거" onClick={onRemove}>{'\u2715'}</button>
    </div>
  );
}

// ── live recording bar (replaces the toolbar while recording) ──
function RecordBar({ onStop, onCancel }) {
  const [secs, setSecs] = useCS(0);
  const [wave, setWave] = useCS([]);
  useCEff(() => {
    const t0 = performance.now();
    const id = setInterval(() => {
      setSecs((performance.now() - t0) / 1000);
      setWave(w => [...w.slice(-46), 0.2 + Math.random() * 0.78]);
    }, 110);
    return () => clearInterval(id);
  }, []);
  return (
    <div className="rec-bar">
      <span className="rec-dot"></span>
      <span className="rec-lbl">녹음 중</span>
      <span className="rec-clock mono">{fmtClock(secs)}</span>
      <div className="rec-wave">
        {wave.map((h, i) => <span key={i} className="rbar" style={{ height: `${Math.round(3 + h * 20)}px` }}></span>)}
      </div>
      <button className="rec-btn cancel" title="취소" onClick={onCancel}>취소</button>
      <button className="rec-btn stop" title="녹음 종료 — 받아쓰기" onClick={() => onStop(Math.max(1, secs))}>{'\u25A0'} 완료</button>
    </div>
  );
}

function Composer({ keeper, onSend, onAction, onNav }) {
  const [val, setVal] = useCS('');
  const [focus, setFocus] = useCS(false);
  const [atts, setAtts] = useCS([]);
  const [voice, setVoice] = useCS(null);
  const [recording, setRecording] = useCS(false);
  const [drag, setDrag] = useCS(false);
  const [slashIdx, setSlashIdx] = useCS(0);
  const ref = useCRef(null);
  const fileRef = useCRef(null);

  // slash-command palette: lifecycle (real FSM actions for this phase) + go-to nav
  const lifeCmds = ((window.FSM_ACTIONS && window.FSM_ACTIONS[keeper.phase]) || []).map(a => ({
    group: '명령', id: a.id, label: a.label, glyph: a.glyph, hint: a.hint, danger: a.danger,
    run: () => onAction && onAction(keeper.id, a),
  }));
  const navCmds = onNav ? [
    { group: '이동', id: 'work', label: '작업·목표', glyph: '◈', hint: 'Goal·Task 보기', run: () => onNav('work') },
    { group: '이동', id: 'approvals', label: 'Gate', glyph: '⚠', hint: 'HITL 결재', run: () => onNav('approvals') },
    { group: '이동', id: 'schedule', label: '예약', glyph: '◷', hint: '예약 자동화 큐', run: () => onNav('schedule') },
    { group: '이동', id: 'logs', label: '로그', glyph: '▤', hint: '이벤트 트레이스', run: () => onNav('logs') },
  ] : [];
  const allCmds = [...lifeCmds, ...navCmds];
  const slashQuery = val.startsWith('/') && !val.includes(' ') ? val.slice(1).toLowerCase() : null;
  const slashMatches = slashQuery !== null
    ? allCmds.filter(c => c.id.toLowerCase().includes(slashQuery) || c.label.toLowerCase().includes(slashQuery))
    : [];
  const slashOpen = slashQuery !== null && slashMatches.length > 0;
  useCEff(() => { setSlashIdx(0); }, [val]);

  const runSlash = (c) => {
    if (!c) return;
    setVal('');
    if (ref.current) ref.current.style.height = 'auto';
    c.run();
  };

  const canSend = !!(val.trim() || atts.length || voice);

  const reset = () => {
    setVal(''); setAtts([]); setVoice(null);
    if (ref.current) ref.current.style.height = 'auto';
  };

  const send = () => {
    if (!canSend) return;
    const blocks = [];
    atts.forEach(a => blocks.push({
      t: 'attach', kind: a.kind, name: a.name, dims: a.dims, size: a.size, src: a.src,
      via: 'Dashboard 업로드', ph: a.src ? undefined : a.name,
    }));
    if (voice) blocks.push({
      t: 'voice', secs: Math.round(voice.secs), wave: voice.wave, size: voice.size,
      via: '음성 입력 · 받아쓰기', transcript: voice.transcript,
    });
    const text = val.trim();
    if (text) blocks.push({ t: 'p', html: text.replace(/</g, '&lt;') });
    onSend({ blocks });
    reset();
  };

  const onKey = (e) => {
    if (slashOpen) {
      if (e.key === 'ArrowDown') { e.preventDefault(); setSlashIdx(i => (i + 1) % slashMatches.length); return; }
      if (e.key === 'ArrowUp') { e.preventDefault(); setSlashIdx(i => (i - 1 + slashMatches.length) % slashMatches.length); return; }
      if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); runSlash(slashMatches[slashIdx]); return; }
      if (e.key === 'Escape') { e.preventDefault(); setVal(''); return; }
    }
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send(); }
  };
  const grow = (e) => {
    setVal(e.target.value);
    e.target.style.height = 'auto';
    e.target.style.height = Math.min(e.target.scrollHeight, 160) + 'px';
  };

  const ingest = async (files) => {
    const list = Array.from(files).slice(0, 6);
    const made = await Promise.all(list.map(async (f) => {
      const { src, dims } = await readDropFile(f);
      return { id: nextAttId(), name: f.name, size: fmtSize(f.size), kind: f.type.startsWith('image/') ? 'image' : 'file', src, dims };
    }));
    setAtts(prev => [...prev, ...made].slice(0, 6));
  };
  const onPick = (e) => { if (e.target.files && e.target.files.length) ingest(e.target.files); e.target.value = ''; };
  const onDrop = (e) => {
    e.preventDefault(); setDrag(false);
    if (e.dataTransfer.files && e.dataTransfer.files.length) ingest(e.dataTransfer.files);
  };

  const stopRecording = (secs) => {
    setRecording(false);
    const n = Math.min(40, Math.max(14, Math.round(secs * 2.2)));
    setVoice({
      secs,
      size: fmtSize(Math.round(secs * 3400)),
      wave: Array.from({ length: n }, () => 0.22 + Math.random() * 0.74),
      transcript: '스케줄러 p99 스파이크 건, compact 도는 타이밍이랑 겹치는지 확인하고 결과만 알려줘.',
    });
  };

  return (
    <div className="composer"
      onDragOver={(e) => { e.preventDefault(); if (!drag) setDrag(true); }}
      onDragLeave={(e) => { if (e.currentTarget === e.target) setDrag(false); }}
      onDrop={onDrop}>
      <div className="composer-inner">
        {(atts.length > 0 || voice) && (
          <div className="composer-tray">
            {atts.map(a => <AttachDraft key={a.id} a={a} onRemove={() => setAtts(prev => prev.filter(x => x.id !== a.id))} />)}
            {voice && <VoiceDraft v={voice} onRemove={() => setVoice(null)} />}
          </div>
        )}
        <div className={`composer-box ${focus ? 'focus' : ''} ${drag ? 'drag' : ''}`}>
          {slashOpen && (
            <div className="slashmenu">
              <div className="slashmenu-h">{keeper.id} · 명령</div>
              {slashMatches.map((c, i) => (
                <button key={c.group + c.id} className={`slashmenu-i ${i === slashIdx ? 'on' : ''} ${c.danger ? 'danger' : ''}`}
                  onMouseEnter={() => setSlashIdx(i)} onClick={() => runSlash(c)}>
                  <span className="slashmenu-gl">{c.glyph}</span>
                  <span className="slashmenu-cmd mono">/{c.id}</span>
                  <span className="slashmenu-lbl">{c.label}</span>
                  <span className="slashmenu-hint">{c.hint}</span>
                  <span className="slashmenu-grp">{c.group}</span>
                </button>
              ))}
            </div>
          )}
          {recording ? (
            <RecordBar onStop={stopRecording} onCancel={() => setRecording(false)} />
          ) : (
            <React.Fragment>
              <textarea
                ref={ref} rows={1} value={val}
                placeholder={drag ? '여기에 놓아 첨부…' : `${keeper.id} 에게 메시지…  (/ 명령 · ⌘+Enter 전송)`}
                onChange={grow} onKeyDown={onKey}
                onFocus={() => setFocus(true)} onBlur={() => setFocus(false)} />
              <div className="composer-tools">
                <input ref={fileRef} type="file" accept="image/*,.pdf,.txt,.log,.json,.csv,.md" multiple
                  style={{ display: 'none' }} onChange={onPick} />
                <button className="ctool" title="이미지·파일 첨부 — 멀티모달 입력 (스크린샷, 로그, 다이어그램)"
                  onClick={() => fileRef.current && fileRef.current.click()}>{'\u2295'}</button>
                <button className="ctool" title="음성 입력 — 받아쓰기로 메시지 작성"
                  onClick={() => setRecording(true)}>
                  <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0"/><path d="M12 18v3"/></svg>
                </button>
                <button className="send" disabled={!canSend} onClick={send}>전송 {'\u2191'}</button>
              </div>
            </React.Fragment>
          )}
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { Composer, AttachDraft, VoiceDraft, RecordBar });
