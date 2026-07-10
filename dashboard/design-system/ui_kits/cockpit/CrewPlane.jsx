/* global React */
// CrewPlane.jsx — Phase C-2: synthetic fleet view
// ─────────────────────────────────────────────────────────────────────
// Two layouts: SOLO (1 keeper computer) and SWARM (2x2 grid w/ pagination).
// Roster on the left lists all 14 keepers as persona cards.
// Stage on the right is the keeper's "computer" — header + action stream + memory.
// All data comes from window.MASC_CREW. Repository previews intentionally do
// not ship .masc dumps, keeper prompts, runtime profiles, or decision logs.

const { useState: cpUseState, useMemo: cpUseMemo, useEffect: cpUseEffect } = React;

// ─── helpers ──────────────────────────────────────────────────────────
const CREW = () => window.MASC_CREW || { keepers: [], decisions: {}, memory: {}, bash: {}, keeper_events: {}, fleet_events: [] };

function timeAgo(iso) {
  if (!iso) return "—";
  const t = typeof iso === "number" ? iso : Date.parse(iso);
  if (!t) return "—";
  const s = (Date.now() - t) / 1000;
  if (s < 60) return Math.floor(s) + "s ago";
  if (s < 3600) return Math.floor(s/60) + "m ago";
  if (s < 86400) return Math.floor(s/3600) + "h ago";
  return Math.floor(s/86400) + "d ago";
}

function fmtCost(n) {
  if (!n) return "$0";
  if (n < 0.01) return "<$0.01";
  if (n < 1) return "$" + n.toFixed(2);
  return "$" + n.toFixed(0);
}

function statusOf(k) {
  if (k.paused) return "paused";
  if (k.last_blocker) return "blocked";
  if (k.status === "busy") return "busy";
  return "idle";
}

const TOOL_KIND = (name) => {
  if (!name) return "act";
  const n = name.toLowerCase();
  if (n.includes("bash") || n.includes("shell")) return "shell";
  if (n.includes("web")) return "web";
  if (n.includes("mcp__") || n.includes("masc_")) return "mcp";
  if (n.includes("read") || n.includes("file")) return "fs";
  if (n.includes("board") || n.includes("message") || n.includes("broadcast")) return "comm";
  if (n.includes("task") || n.includes("plan")) return "plan";
  if (n.includes("git")) return "git";
  return "tool";
};

const TOOL_ICON = {
  shell: "▶", web: "◐", mcp: "◆", fs: "▤", comm: "◉",
  plan: "▢", git: "⎇", tool: "·", act: "·"
};

// ─── persona avatar (initial-based, deterministic color) ──────────────
function PersonaAvatar({ name, size = 40 }) {
  const initial = (name || "?")[0].toUpperCase();
  // hash → hue
  let h = 0;
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0;
  const hue = h % 360;
  const bg = `oklch(0.42 0.12 ${hue})`;
  const fg = `oklch(0.92 0.06 ${hue})`;
  return (
    <div className="cp-avatar" style={{
      width: size, height: size, background: bg, color: fg,
      fontSize: size * 0.42, lineHeight: size + "px",
    }}>{initial}</div>
  );
}

// ─── roster card ──────────────────────────────────────────────────────
function RosterCard({ k, active, onSelect, onPick, picked }) {
  const st = statusOf(k);
  return (
    <button
      type="button"
      className={`cp-roster-card st-${st} ${active ? "active" : ""}`}
      onClick={() => onSelect(k.id)}
      title={k.motto}>
      <div className="cp-rc-top">
        <PersonaAvatar name={k.name} size={36} />
        <div className="cp-rc-id">
          <div className="cp-rc-name">{k.name}</div>
          <div className="cp-rc-motto">{k.motto || "—"}</div>
        </div>
        <span className={`cp-dot st-${st}`} title={st} />
      </div>
      <div className="cp-rc-meta">
        <span className="cp-chip">{k.runtime}</span>
        {k.current_task && <span className="cp-chip">⊙ {k.current_task}</span>}
        <span className="cp-chip cost">{fmtCost(k.total_cost_usd)}</span>
      </div>
      {k.last_blocker && <div className="cp-rc-blocker">⚠ {k.last_blocker}</div>}
    </button>
  );
}

// ─── action stream item ───────────────────────────────────────────────
function ActionItem({ ev, expanded, onToggle }) {
  const kind = TOOL_KIND(ev.tool || ev.kind);
  const icon = TOOL_ICON[kind];
  const ok = ev.ok !== false;
  const label =
    ev.tool ? ev.tool :
    ev.kind ? ev.kind :
    "action";

  const detail =
    ev.cmd || ev.err || ev.content || (ev.dur ? `${ev.dur}ms` : "");

  return (
    <div className={`cp-act ${ok ? "ok" : "err"} kind-${kind}`} onClick={onToggle}>
      <span className="cp-act-icon">{icon}</span>
      <span className="cp-act-tool">{label}</span>
      {detail && <span className="cp-act-detail">{detail}</span>}
      <span className="cp-act-time">{ev.ts ? timeAgo(ev.ts) : ""}</span>
    </div>
  );
}

// ─── decision card (richer than tool event) ───────────────────────────
function DecisionRow({ d }) {
  const ok = d.outcome !== "error" && d.outcome !== "failure";
  const tools = d.tools || [];
  return (
    <div className={`cp-decision ${ok ? "ok" : "err"}`}>
      <div className="cp-dc-row1">
        <span className="cp-dc-channel">{d.channel || "turn"}</span>
        <span className="cp-dc-arrow">→</span>
        <span className={`cp-dc-mode mode-${d.selected_mode || "n"}`}>{d.selected_mode || "—"}</span>
        <span className="cp-dc-time">{timeAgo(d.ts)}</span>
      </div>
      {(d.signals || []).length > 0 && (
        <div className="cp-dc-signals">
          {d.signals.map((s, i) => <span key={i} className="cp-sig">{s}</span>)}
        </div>
      )}
      {tools.length > 0 && (
        <div className="cp-dc-tools">
          {tools.map((t, i) => <span key={i} className="cp-tool-chip">{TOOL_ICON[TOOL_KIND(t)]} {t}</span>)}
          {d.tool_count > tools.length && <span className="cp-tool-chip more">+{d.tool_count - tools.length}</span>}
        </div>
      )}
      {d.response && <div className="cp-dc-resp">↳ {d.response}</div>}
      {d.blocker && <div className="cp-dc-blocker">⚠ {d.blocker}</div>}
    </div>
  );
}

// ─── memory entry ─────────────────────────────────────────────────────
function MemoryRow({ m }) {
  return (
    <div className={`cp-mem hz-${m.horizon || "mid"}`}>
      <div className="cp-mem-head">
        <span className={`cp-mem-kind k-${m.kind || "note"}`}>{m.kind || "note"}</span>
        <span className="cp-mem-hz">{m.horizon || "mid"}</span>
        <span className="cp-mem-pri">P{m.priority || "—"}</span>
        <span className="cp-mem-time">{timeAgo(m.ts)}</span>
      </div>
      <div className="cp-mem-text">{m.text}</div>
    </div>
  );
}

// ─── stage (one keeper's "computer") ──────────────────────────────────
function KeeperStage({ id, compact = false }) {
  const C = CREW();
  const k = C.keepers.find(x => x.id === id);
  const [tab, setTab] = cpUseState("stream");

  if (!k) return <div className="cp-stage empty">no keeper selected</div>;

  const events = (C.keeper_events[id] || []).slice().reverse();
  const decisions = (C.decisions[id] || []).slice().reverse();
  const memory = (C.memory[id] || []).slice().reverse();
  const st = statusOf(k);

  return (
    <div className={`cp-stage ${compact ? "compact" : ""} st-${st}`}>
      <div className="cp-stage-head">
        <PersonaAvatar name={k.name} size={compact ? 32 : 48} />
        <div className="cp-sh-id">
          <div className="cp-sh-name-row">
            <span className="cp-sh-name">{k.name}</span>
            <span className={`cp-dot st-${st}`} />
            <span className="cp-sh-status">{st}</span>
            {k.current_task && <span className="cp-sh-task">⊙ {k.current_task}</span>}
          </div>
          <div className="cp-sh-motto">{k.motto || "—"}</div>
        </div>
        {!compact && (
          <div className="cp-sh-meta">
            <div><b>runtime</b> {k.runtime}</div>
            <div><b>sandbox</b> {k.sandbox} · {k.network}</div>
            <div><b>turns</b> {k.total_turns} · <b>cost</b> {fmtCost(k.total_cost_usd)}</div>
            <div><b>last seen</b> {timeAgo(k.last_seen)}</div>
          </div>
        )}
      </div>

      {!compact && k.last_blocker && (
        <div className="cp-stage-blocker">
          <span className="lbl">blocked</span>
          <span className="msg">{k.last_blocker}</span>
        </div>
      )}

      <div className="cp-stage-tabs">
        <button className={tab==="stream"?"active":""} onClick={()=>setTab("stream")}>actions <span className="cnt">{events.length}</span></button>
        <button className={tab==="decisions"?"active":""} onClick={()=>setTab("decisions")}>decisions <span className="cnt">{decisions.length}</span></button>
        <button className={tab==="memory"?"active":""} onClick={()=>setTab("memory")}>memory <span className="cnt">{memory.length}</span></button>
        {!compact && <button className={tab==="instructions"?"active":""} onClick={()=>setTab("instructions")}>persona</button>}
      </div>

      <div className="cp-stage-body">
        {tab === "stream" && (
          <div className="cp-stream">
            {events.length === 0 && <div className="cp-empty">no recorded actions</div>}
            {events.map((ev, i) => <ActionItem key={ev.seq || i} ev={ev} />)}
          </div>
        )}
        {tab === "decisions" && (
          <div className="cp-decisions">
            {decisions.length === 0 && <div className="cp-empty">no decisions logged</div>}
            {decisions.map((d, i) => <DecisionRow key={i} d={d} />)}
          </div>
        )}
        {tab === "memory" && (
          <div className="cp-memory">
            {memory.length === 0 && <div className="cp-empty">no memory entries</div>}
            {memory.map((m, i) => <MemoryRow key={i} m={m} />)}
          </div>
        )}
        {tab === "instructions" && !compact && (
          <div className="cp-persona">
            <section><h4>goal</h4><p>{k.goal || "—"}</p></section>
            <section><h4>instructions</h4><p className="instr">{k.instructions_preview || "—"}</p></section>
            <section className="cp-persona-meta">
              <div><b>agent</b> {k.agent_name}</div>
              <div><b>capabilities</b> {(k.capabilities||[]).join(", ") || "—"}</div>
              <div><b>mention</b> {(k.mention_targets||[]).join(", ") || "—"}</div>
              <div><b>workspaces</b> {(k.joined_workspaces||[]).join(", ") || "—"}</div>
              <div><b>last model</b> {k.last_model || "—"}</div>
              <div><b>autonomous</b> {k.autonomous_turns} turns / {k.autonomous_actions} actions</div>
            </section>
          </div>
        )}
      </div>
    </div>
  );
}

// ─── swarm grid (2x2 with pagination) ─────────────────────────────────
function SwarmGrid({ ids, onSelect }) {
  const [page, setPage] = cpUseState(0);
  const PAGE_SIZE = 4;
  const pages = Math.max(1, Math.ceil(ids.length / PAGE_SIZE));
  const safePage = Math.min(page, pages - 1);
  const slice = ids.slice(safePage * PAGE_SIZE, safePage * PAGE_SIZE + PAGE_SIZE);
  return (
    <div className="cp-swarm">
      <div className="cp-swarm-grid">
        {slice.map(id => (
          <div key={id} className="cp-swarm-cell" onDoubleClick={() => onSelect && onSelect(id)}>
            <KeeperStage id={id} compact />
          </div>
        ))}
        {Array.from({length: PAGE_SIZE - slice.length}, (_, i) => (
          <div key={"e"+i} className="cp-swarm-cell empty">—</div>
        ))}
      </div>
      <div className="cp-swarm-pager">
        <button onClick={()=>setPage(Math.max(0, safePage-1))} disabled={safePage===0}>‹</button>
        <span className="cp-pg-lbl">page {safePage+1} / {pages} · {ids.length} keepers</span>
        <button onClick={()=>setPage(Math.min(pages-1, safePage+1))} disabled={safePage>=pages-1}>›</button>
      </div>
    </div>
  );
}

// ─── main plane ───────────────────────────────────────────────────────
function CrewPlane({ branch, keepers: selKeepers }) {
  const C = CREW();
  const ids = C.keepers.map(k => k.id);
  const [view, setView] = cpUseState("solo");          // solo | swarm
  const [selId, setSelId] = cpUseState(ids[0] || null);
  const [filter, setFilter] = cpUseState("all");       // all | busy | blocked | idle

  cpUseEffect(() => {
    // if URL has cs.crewKeeper, honour it (best-effort)
    const hashKeeper = (window.useCockpitState ? window.useCockpitState()[0]?.crewKeeper : null);
    if (hashKeeper && ids.includes(hashKeeper)) setSelId(hashKeeper);
  }, []);

  const filtered = cpUseMemo(() => {
    const all = C.keepers;
    if (filter === "all") return all;
    return all.filter(k => statusOf(k) === filter);
  }, [filter, C]);

  if (!C.keepers.length) {
    return (
      <div className="plane">
        <div className="plane-hdr"><span className="ti">Crew</span><span className="sub">· no repository seed</span></div>
        <div style={{padding:24, color:"var(--ink-2)"}}>Crew seed data is intentionally omitted from repository previews.</div>
      </div>
    );
  }

  const counts = {
    all: C.keepers.length,
    busy: C.keepers.filter(k => statusOf(k) === "busy").length,
    blocked: C.keepers.filter(k => statusOf(k) === "blocked").length,
    idle: C.keepers.filter(k => statusOf(k) === "idle").length,
    paused: C.keepers.filter(k => statusOf(k) === "paused").length,
  };

  return (
    <div className="plane cp-plane" data-screen-label="Crew Plane">
      <div className="plane-hdr">
        <span className="ti">Crew</span>
        <span className="sub">· {C.keeper_count} keepers · {C.generated_at ? new Date(C.generated_at).toISOString().slice(0,16).replace("T"," ") : "?"}</span>
        <span className="ctx">
          <span>⎇ <span className="br">{branch || "main"}</span></span>
          <span>·</span>
          <span><span className="kp">{(selKeepers||new Set()).size}</span> selected</span>
        </span>
      </div>

      <div className="cp-bar">
        <div className="cp-bar-views" role="tablist">
          <button className={view==="solo"?"active":""} onClick={()=>setView("solo")} role="tab">solo</button>
          <button className={view==="swarm"?"active":""} onClick={()=>setView("swarm")} role="tab">swarm</button>
        </div>
        <div className="cp-bar-filters">
          {["all","busy","blocked","idle","paused"].map(f => (
            <button key={f} className={`cp-flt f-${f} ${filter===f?"active":""}`} onClick={()=>setFilter(f)}>
              {f} <span className="cnt">{counts[f]}</span>
            </button>
          ))}
        </div>
      </div>

      <div className={`cp-body view-${view}`}>
        <aside className="cp-roster">
          {filtered.map(k => (
            <RosterCard key={k.id} k={k} active={k.id === selId} onSelect={setSelId} />
          ))}
          {filtered.length === 0 && <div className="cp-empty">no keepers match filter</div>}
        </aside>
        <main className="cp-main">
          {view === "solo" && <KeeperStage id={selId} />}
          {view === "swarm" && <SwarmGrid ids={filtered.map(k=>k.id)} onSelect={(id)=>{setSelId(id); setView("solo");}} />}
        </main>
      </div>
    </div>
  );
}

Object.assign(window, { CrewPlane, KeeperStage, RosterCard, PersonaAvatar });
