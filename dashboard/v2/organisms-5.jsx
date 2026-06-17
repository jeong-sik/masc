// @ds-adherence-ignore -- v2 skin organism (batch 5): Keeper Config drawer + shared empty/error/loading state surfaces — composed from primitives/molecules
/* ══════════════════════════════════════════════════════════════
   MASC v2 — Organisms, batch 5
   · KeeperConfigPanel — the per-keeper config drawer (identity facts,
     inherited base prompts, persona + instruction editors, model /
     runtime segmented controls, tool-permission toggles). Data-driven
     re-expression of app.jsx's KeeperConfig, built from KV atoms +
     the SetRow molecule.
   · State surfaces — EmptyState / ErrorState / LoadingState: the
     empty/error/loading variants every surface needs but the catalog
     never componentized. Reusable across Fleet, Board, Logs, etc.
   Exported onto window + window.KVO5.
   ══════════════════════════════════════════════════════════════ */

const { useState: use5 } = React;
const K5 = window.KV;
const { Sigil, Button, TraitPill, Toggle, Segmented } = K5;
const { SetRow } = window.KVO2;
const o5 = (...a) => a.filter(Boolean).join(' ');

/* ── small shared bits ── */
function TurnSec({ title, children }) {
  return <div className="turn-sec"><h4>{title}</h4>{children}</div>;
}
function KvRows({ rows = [] }) {
  return (
    <div className="kc-codectx">
      {rows.map((r, i) => <div key={i} className="kc-cc-row"><span className="sub-k">{r.k}</span><span className="mono">{r.v}</span></div>)}
    </div>
  );
}
function InheritRows({ rows = [], note }) {
  return (
    <div className="kc-inherit">
      {rows.map((r, i) => <div key={i} className="kc-inh-row"><span className="kc-inh-tag">{r.tag}</span><span className="kc-inh-txt mono">{r.txt}</span></div>)}
      {note ? <div className="kc-inh-note">{note}</div> : null}
    </div>
  );
}

/* ════════════════════════════════════════════════════════════════
   KEEPER CONFIG — drawer (renders inline here; asOverlay for the app)
   ════════════════════════════════════════════════════════════════ */
function KeeperConfigPanel({
  keeper = {}, base = {}, inherit = [],
  models = ['claude-haiku-4', 'claude-sonnet-4', 'claude-opus-4'],
  runtimes = ['oas·seoul-1', 'oas·tokyo-2', 'local·docker'],
  permissions = { '읽기': true, '쓰기': true, 'git': false, '외부 호출': false },
  asOverlay = false, onClose, onPromptsLink, style,
}) {
  const [persona, setPersona] = use5(base.persona || '');
  const [instr, setInstr] = use5(base.instructions || '');
  const [model, setModel] = use5(keeper.model || models[1]);
  const [rt, setRt] = use5((keeper.runtime || runtimes[0]).split('·')[0] === 'oas' ? (keeper.runtime || runtimes[0]) : runtimes[0]);
  const [perm, setPerm] = use5(permissions);

  const inner = (
    <div className="turn-drawer" onClick={e => e.stopPropagation()}
      style={asOverlay ? style : { position: 'static', width: '100%', height: '100%', boxShadow: 'none', borderRadius: 0, ...style }}>
      <div className="turn-hd">
        <h3>keeper 설정</h3>
        <span className="tid">{keeper.id}</span>
        {onClose ? <button className="turn-close" onClick={onClose} title="닫기 (Esc)">{'\u2715'}</button> : null}
      </div>
      <div className="turn-body">
        <TurnSec title="정체성 · 배정">
          <div className="kc-fact-note">아래는 배정·파생된 사실 — 여기서 바꾸지 않습니다. worktree는 keeper가 basepath 아래에 자동 생성·관리합니다.</div>
          <KvRows rows={[
            { k: 'namespace', v: keeper.ns },
            { k: 'repo · branch', v: `masc-mcp · keeper/${keeper.id}` },
          ]} />
        </TurnSec>
        <TurnSec title="상속 — 공유 베이스 (read-only)">
          <InheritRows rows={inherit}
            note={<>전 keeper 공유 · <button className="set-link" onClick={onPromptsLink}>operator 설정 · Keeper 기본 · 프롬프트 →</button></>} />
        </TurnSec>
        <TurnSec title="③ 성격 (persona) — 이 keeper">
          <textarea className="kc-text" rows={2} value={persona} onChange={e => setPersona(e.target.value)} />
          <div className="kc-traits">{(base.traits || []).map((t, i) => <TraitPill key={i}>{t}</TraitPill>)}</div>
        </TurnSec>
        <TurnSec title="④ 지침 (instructions) — 이 keeper">
          <textarea className="kc-text" rows={5} value={instr} onChange={e => setInstr(e.target.value)} />
        </TurnSec>
        <TurnSec title="모델">
          <Segmented options={models} value={model} onChange={setModel} />
        </TurnSec>
        <TurnSec title="기본 런타임">
          <Segmented options={runtimes} value={rt} onChange={setRt} />
        </TurnSec>
        <TurnSec title="도구 권한">
          {Object.keys(perm).map(k => (
            <SetRow key={k} label={k}>
              <Toggle on={perm[k]} onChange={v => setPerm(p => ({ ...p, [k]: v }))} />
            </SetRow>
          ))}
        </TurnSec>
        <button className="kc-save">저장 · 재시작 없이 적용</button>
      </div>
    </div>
  );
  if (asOverlay) return <div className="turn-overlay" onClick={onClose}>{inner}</div>;
  return inner;
}

/* ════════════════════════════════════════════════════════════════
   STATE SURFACES — empty / error / loading (the missing variants)
   ════════════════════════════════════════════════════════════════ */
function EmptyState({ glyph = '◌', title, hint, action, onAction, style }) {
  return (
    <div className="kv-state empty" style={style}>
      <div className="kv-state-g">{glyph}</div>
      <div className="kv-state-t">{title}</div>
      {hint ? <div className="kv-state-h">{hint}</div> : null}
      {action ? <Button variant="primary" onClick={onAction}>{action}</Button> : null}
    </div>
  );
}
function ErrorState({ glyph = '⚠', title, detail, action = '다시 시도', onAction, style }) {
  return (
    <div className="kv-state error" style={style}>
      <div className="kv-state-g">{glyph}</div>
      <div className="kv-state-t">{title}</div>
      {detail ? <div className="kv-state-h mono">{detail}</div> : null}
      {action ? <Button onClick={onAction}>{action}</Button> : null}
    </div>
  );
}
function LoadingState({ title = '불러오는 중…', rows = 3, style }) {
  return (
    <div className="kv-state loading" style={style}>
      <window.KV.LoadingBar />
      <div className="kv-skel-list">
        {Array.from({ length: rows }).map((_, i) => (
          <div key={i} className="kv-skel-row"><span className="kv-skel-av" /><span className="kv-skel-lines"><span className="kv-skel-line" /><span className="kv-skel-line short" /></span></div>
        ))}
      </div>
      <div className="kv-state-h">{title}</div>
    </div>
  );
}

const KVO5 = { TurnSec, KvRows, InheritRows, KeeperConfigPanel, EmptyState, ErrorState, LoadingState };
Object.assign(window, KVO5);
window.KVO5 = KVO5;
