// @ds-adherence-ignore -- v2 skin organism (batch 5): Keeper Config drawer + shared empty/error/loading state surfaces — composed from primitives/molecules
/* ══════════════════════════════════════════════════════════════
   MASC v2 — Organisms, batch 5
   · KeeperConfigPanel — the per-keeper config drawer (identity facts,
     inherited base prompts, persona + instruction editors, model /
     runtime segmented controls, tool-permission toggles). Data-driven
     re-expression of app.jsx's KeeperConfig, built from KV atoms +
     the SetRow molecule.
   Exported onto window + window.KVO5.
   ══════════════════════════════════════════════════════════════ */

const { useState: use5 } = React;
const K5 = window.KV;
const { Sigil, Button, TraitPill, Toggle, Segmented } = K5;
const { SetRow } = window.KVM;
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
  models = ['deepseek-v4-flash', 'deepseek-v4-pro', 'gemma4-26b-a4b-qat'],
  runtimes = ['ollama_cloud.deepseek-v4-flash', 'deepseek.deepseek-v4-pro', 'ollama.gemma4-26b-a4b-qat'],
  grant = null,
  asOverlay = false, onClose, onPromptsLink, onPolicyLink, style,
}) {
  const tools = window.MASC_TOOLS || [];
  const g0 = grant || (window.DEFAULT_GRANT || { fs: 'worktree', git: false, net: false, tools: [] });
  // real runtime stays selected — stopped keepers ('—') fall back to the default;
  // an off-list runtime is appended so the segmented control can show it.
  const liveRt = keeper.runtime && keeper.runtime !== '—' ? keeper.runtime : null;
  const rtOptions = liveRt && !runtimes.includes(liveRt) ? [...runtimes, liveRt] : runtimes;
  const [persona, setPersona] = use5(base.persona || '');
  const [instr, setInstr] = use5(base.instructions || '');
  const [model, setModel] = use5(keeper.model || models[1]);
  const [rt, setRt] = use5(liveRt || runtimes[0]);
  const [fs, setFs] = use5(g0.fs);
  const [git, setGit] = use5(!!g0.git);
  const [net, setNet] = use5(!!g0.net);
  const [grants, setGrants] = use5(() => Object.fromEntries(tools.map(t => [t.id, g0.tools.includes(t.id)])));
  const toggleTool = (id) => setGrants(p => ({ ...p, [id]: !p[id] }));

  const inner = (
    <div className="turn-drawer" onClick={e => e.stopPropagation()}
      style={asOverlay ? style : { position: 'static', width: '100%', height: '100%', boxShadow: 'none', borderRadius: 0, ...style }}>
      <div className="turn-hd kc-hd">
        {keeper.slot != null ? <SigilBadge k={keeper} size={26} /> : null}
        <h3>keeper 설정</h3>
        <span className="tid">{keeper.id}</span>
        {keeper.phase ? <span className="kc-hd-phase"><StatusDot status={keeper.status} pulse={keeper.status === 'run'} />{keeper.phase}</span> : null}
        {onClose ? <button className="turn-close" onClick={onClose} title="닫기 (Esc)">{'\u2715'}</button> : null}
      </div>
      <div className="turn-body">
        <TurnSec title="정체성 · 배정">
          <div className="kc-fact-note">아래는 배정·파생된 사실 — 여기서 바꾸지 않습니다. worktree는 keeper가 basepath 아래에 자동 생성·관리합니다.</div>
          <KvRows rows={[
            { k: 'sandbox', v: keeper.sandbox ? `${keeper.sandbox} 격리` : '— 비활성' },
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
          <Segmented options={rtOptions} value={rt} onChange={setRt} />
        </TurnSec>
        <TurnSec title="권한 · 범위">
          <div className="kc-fact-note">이 keeper가 뭐에 쓸 수 있는가 — 샌드박스 경계(설정 · Sandbox)보다 위 계층의 행동 권한.</div>
          <SetRow label="파일시스템 범위" hint="none 읽기 전용 · worktree 자기 워크트리 · namespace 소유 ns 전체">
            <Segmented options={['none', 'worktree', 'namespace']} value={fs} onChange={setFs} />
          </SetRow>
          <SetRow label="git push / merge" hint="원격 브랜치에 쓰기 — always 정책">
            <Toggle on={git} onChange={setGit} />
          </SetRow>
          <SetRow label="외부 호출" hint="Slack·Discord 발신 등 외부로 메시지">
            <Toggle on={net} onChange={setNet} />
          </SetRow>
        </TurnSec>
        <TurnSec title="도구 권한 · masc_*">
          <div className="kc-fact-note">이 keeper가 호출할 수 있는 MCP 도구. 서버에 노출된 도구와 이 목록이 모두 켜져야 호출됩니다.</div>
          <div className="kc-tools">
            {tools.map(t => (
              <div key={t.id} className={o5('kc-tool', grants[t.id] && 'on')}>
                <Toggle on={!!grants[t.id]} onChange={() => toggleTool(t.id)} />
                <span className="kc-tool-id mono">{t.id}</span>
                <span className={o5('kc-tool-risk', t.risk)}>{t.risk === 'read' ? '읽기' : t.risk === 'write' ? '쓰기' : '수명'}</span>
                <span className="kc-tool-desc">{t.desc}</span>
              </div>
            ))}
          </div>
          <div className="kc-inh-note">외부 효과 호출은 <button className="set-link" onClick={onPolicyLink}>Gate 큐</button>로 갑니다.</div>
        </TurnSec>
        <button className="kc-save">저장 · 다음 턴부터 적용</button>
      </div>
    </div>
  );
  if (asOverlay) return <div className="turn-overlay" onClick={onClose}>{inner}</div>;
  return inner;
}

const KVO5 = { TurnSec, KvRows, InheritRows, KeeperConfigPanel };
Object.assign(window, KVO5);
window.KVO5 = KVO5;
