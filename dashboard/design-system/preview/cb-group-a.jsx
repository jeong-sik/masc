// cb-group-a.jsx — Topbar, Ticker, KPI Strip, Lifeline (with variants)
const D = window.MASC_DATA;

// ─── density label helper ──────────────────────────────────────────
const DENSITY_LABEL = { c: 'Compact', n: 'Normal', l: 'Loose' };

// ─── TOPBAR variants ───────────────────────────────────────────────
function TopbarStandard() {
  const [mode, setMode] = useState('dash');
  const [density, setDensity] = useState('n');
  return (
    <div className="cb-board">
      <header className="cb-topbar" role="banner" aria-label="MASC topbar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <span className="brand-name">MASC</span>
          <span className="ver" aria-label="Build version 0.42.1">v0.42.1</span>
        </div>
        <div className="sep" aria-hidden="true" />
        <button type="button" className="goal-switch" aria-haspopup="menu" aria-label="Switch goal: goal-merge-blockers">
          <Dot kind="brass" size="sm" />
          <span>goal-merge-blockers</span>
          <span className="caret" aria-hidden="true">▾</span>
        </button>
        <div className="mode-tabs" role="tablist" aria-label="View mode">
          {[['dash','Dash'],['code','Code'],['split','Split']].map(([k,l]) => (
            <button key={k} type="button" role="tab" aria-selected={mode===k} tabIndex={mode===k?0:-1} className={mode===k?'on':''} onClick={()=>setMode(k)}>{l}</button>
          ))}
        </div>
        <div className="right">
          <div className="density" role="radiogroup" aria-label="Display density">
            {['c','n','l'].map(d => (
              <button key={d} type="button" role="radio" aria-checked={density===d} aria-label={DENSITY_LABEL[d]} className={density===d?'on':''} onClick={()=>setDensity(d)}>{d}</button>
            ))}
          </div>
          <span className="stamp" aria-label="Build 2604, 16:32:45 UTC">BUILD 2604 · 16:32:45Z</span>
        </div>
      </header>
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
    </div>
  );
}

function TopbarExpanded() {
  const [mode, setMode] = useState('split');
  return (
    <div className="cb-board">
      <header className="cb-topbar" role="banner" aria-label="MASC topbar with branch and fleet">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <span className="brand-name">MASC</span>
          <span className="ver" aria-label="Build version 0.42.1">v0.42.1</span>
        </div>
        <div className="sep" aria-hidden="true" />
        <button type="button" className="goal-switch" aria-haspopup="menu" aria-label="Switch goal: goal-merge-blockers">
          <Dot kind="brass" size="sm" />
          <span>goal-merge-blockers</span>
          <span className="caret" aria-hidden="true">▾</span>
        </button>
        <span className="branch" aria-label="Active branch: release-0.42">release-0.42</span>
        <div className="sep" aria-hidden="true" />
        <div className="mode-tabs" role="tablist" aria-label="View mode">
          {[['dash','Dash'],['code','Code'],['split','Split']].map(([k,l]) => (
            <button key={k} type="button" role="tab" aria-selected={mode===k} tabIndex={mode===k?0:-1} className={mode===k?'on':''} onClick={()=>setMode(k)}>{l}</button>
          ))}
        </div>
        <div className="right">
          <div className="avatars" role="list" aria-label="Active keepers: nick0cave, masc-improver, sangsu, qa-king, rama">
            <span className="av" role="listitem" aria-label="nick0cave" style={{background:'var(--k-nick)'}} />
            <span className="av" role="listitem" aria-label="masc-improver" style={{background:'var(--k-masc)'}} />
            <span className="av" role="listitem" aria-label="sangsu" style={{background:'var(--k-sangsu)'}} />
            <span className="av" role="listitem" aria-label="qa-king" style={{background:'var(--k-qa)'}} />
            <span className="av" role="listitem" aria-label="rama" style={{background:'var(--k-rama)'}} />
          </div>
          <span className="stamp" aria-label="5 active keepers, 2 idle">5 ACTIVE · 2 IDLE</span>
        </div>
      </header>
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
    </div>
  );
}

function TopbarMinimal() {
  return (
    <div className="cb-board">
      <header className="cb-topbar minimal" role="banner" aria-label="MASC topbar (minimal)">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <span className="brand-name">MASC</span>
        </div>
        <div className="mode-tabs" role="tablist" aria-label="View mode">
          <button type="button" role="tab" aria-selected="true" tabIndex={0} className="on">Dash</button>
          <button type="button" role="tab" aria-selected="false" tabIndex={-1}>Code</button>
        </div>
        <div className="right">
          <span className="stamp" aria-label="16:32:45 UTC">16:32:45Z</span>
        </div>
      </header>
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
    </div>
  );
}

// ─── TICKER variants ───────────────────────────────────────────────
function tickerEvents() {
  return D.events.map(e => ({...e}));
}
function TickerMarquee() {
  const evs = [...tickerEvents(), ...tickerEvents()];
  return (
    <div className="cb-board">
      <div className="cb-ticker" role="log" aria-live="polite" aria-label="Fleet event ticker (marquee)">
        <div className="tape">
          {evs.map((e, i) => (
            <span key={i} className={`evt ${e.kind}`} role="listitem" aria-label={`${e.keeper} ${e.kind}: ${e.text}, at ${e.t.slice(0,8)}`}>
              <Dot kind={kClass(e.keeper)} size="sm" />
              <span className="k" aria-hidden="true">{e.keeper}</span>
              <span className="body" aria-hidden="true">{e.text}</span>
              <span className="t" aria-hidden="true">{e.t.slice(0,8)}</span>
            </span>
          ))}
        </div>
      </div>
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
    </div>
  );
}
function TickerChunks() {
  const evs = [...tickerEvents(), ...tickerEvents()];
  return (
    <div className="cb-board">
      <div className="cb-ticker chunks" role="log" aria-live="polite" aria-label="Fleet event ticker (chunked)">
        <div className="tape">
          {evs.map((e, i) => (
            <span key={i} className={`evt ${e.kind}`} role="listitem" aria-label={`${e.keeper} ${e.kind}: ${e.text.slice(0,40)}`}>
              <Dot kind={kClass(e.keeper)} size="sm" />
              <span className="k" aria-hidden="true">{e.keeper}</span>
              <span className="body" aria-hidden="true">{e.text.slice(0, 40)}</span>
            </span>
          ))}
        </div>
      </div>
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
    </div>
  );
}
function TickerVertical() {
  const evs = [...tickerEvents(), ...tickerEvents()];
  return (
    <div className="cb-board">
      <div className="cb-ticker vertical" role="log" aria-live="polite" aria-label="Fleet event ticker (vertical)">
        <div className="tape">
          {evs.map((e, i) => (
            <span key={i} className={`evt ${e.kind}`} role="listitem" aria-label={`${e.t.slice(0,8)} ${e.keeper} ${e.kind}: ${e.text}`} style={{display:'flex', alignItems:'center', gap:6}}>
              <span className="t" aria-hidden="true">{e.t.slice(0,8)}</span>
              <Dot kind={kClass(e.keeper)} size="sm" />
              <span className="k" aria-hidden="true">{e.keeper}</span>
              <span className="body" aria-hidden="true">{e.text}</span>
            </span>
          ))}
        </div>
      </div>
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
    </div>
  );
}

// ─── KPI STRIP variants ────────────────────────────────────────────
const KPI_CELLS = [
  { lbl:'FLEET',  val:'5', cap:'ACTIVE', live:false },
  { lbl:'TPS',    val:'1.24', cap:'SEC/TOK', live:true, delta:'+0.1', deltaKind:'pos', spark:true },
  { lbl:'PASS',   val:'87%', cap:'47 / 54', live:false, kind:'ok' },
  { lbl:'FAIL',   val:'3', cap:'SUITE-MB', live:false, kind:'err' },
  { lbl:'TASKS',  val:'12', cap:'IN FLIGHT', live:false },
  { lbl:'CASCADE',val:'2', cap:'HIT @STEP', live:false, spark:true },
];

function kpiCellAriaLabel(c) {
  const live = c.live ? ' (live)' : '';
  const delta = c.delta ? `, ${c.deltaKind === 'pos' ? 'up' : 'down'} ${c.delta}` : '';
  const kind = c.kind === 'ok' ? ' (passing)' : c.kind === 'err' ? ' (failing)' : '';
  return `${c.lbl}: ${c.val} ${c.cap}${delta}${kind}${live}`;
}

function KpiStandard() {
  return (
    <div className="cb-board">
      <div className="cb-kpi" role="list" aria-label="Fleet KPI strip">
        {KPI_CELLS.map((c, i) => (
          <div key={i} role="listitem" aria-label={kpiCellAriaLabel(c)} className={`cell ${c.live?'live':''} ${c.kind?`is-${c.kind}`:''}`}>
            <span className="lbl" aria-hidden="true">{c.lbl}</span>
            <span className="val" aria-hidden="true">{c.val}</span>
            <span className="cap" aria-hidden="true">{c.cap}{c.delta ? <> · <span className={`delta ${c.deltaKind}`}>{c.delta}</span></> : null}</span>
            {c.spark ? <Spark color={c.live?'brass':'brass'} bars={14} /> : null}
          </div>
        ))}
      </div>
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
    </div>
  );
}
function KpiCompact() {
  return (
    <div className="cb-board">
      <div className="cb-kpi compact" role="list" aria-label="Fleet KPI strip (compact)">
        {KPI_CELLS.map((c, i) => (
          <div key={i} role="listitem" aria-label={kpiCellAriaLabel(c)} className={`cell ${c.live?'live':''} ${c.kind?`is-${c.kind}`:''}`}>
            <span className="lbl" aria-hidden="true">{c.lbl}</span>
            <span className="val" aria-hidden="true">{c.val}</span>
          </div>
        ))}
      </div>
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
    </div>
  );
}
function KpiStacked() {
  return (
    <div className="cb-board">
      <div className="cb-kpi stacked" role="list" aria-label="Fleet KPI strip (stacked)">
        {KPI_CELLS.slice(0,6).map((c, i) => (
          <div key={i} role="listitem" aria-label={kpiCellAriaLabel(c)} className={`cell ${c.live?'live':''} ${c.kind?`is-${c.kind}`:''}`}>
            <span className="lbl" aria-hidden="true">{c.lbl}</span>
            <span className="val big" aria-hidden="true">{c.val}</span>
            <span className="cap" aria-hidden="true">{c.cap}</span>
          </div>
        ))}
      </div>
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
    </div>
  );
}

// ─── LIFELINE variants ─────────────────────────────────────────────
function LifelineBeat() {
  const [phase, setPhase] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setPhase(p => (p + 0.02) % 1), 50);
    return () => clearInterval(t);
  }, []);
  return (
    <div className="cb-board">
      <div className="cb-lifeline" role="img" aria-label="Lifeline heartbeat at 72 BPM, 60 second window">
        <span className="label" aria-hidden="true">LIFELINE</span>
        <Heartbeat phase={phase} />
        <span className="bpm" aria-hidden="true"><span className="n">72</span> BPM · 60s</span>
      </div>
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
    </div>
  );
}
function LifelineStacked() {
  const [phase, setPhase] = useState(0);
  useEffect(() => { const t = setInterval(() => setPhase(p => (p + 0.02) % 1), 50); return () => clearInterval(t); }, []);
  const fleet = D.keepers.slice(0, 5);
  return (
    <div className="cb-board">
      <div className="cb-lifeline stack" role="list" aria-label="Per-keeper heartbeat lifelines">
        {fleet.map((k, i) => (
          <div className="row" key={k.id} role="listitem" aria-label={`${k.id} heartbeat, ${k.status === 'running' ? 'running' : k.status}`}>
            <span className="name" aria-hidden="true">{k.id}</span>
            <Heartbeat width={240} height={14} phase={(phase + i*0.07) % 1} />
            <Dot kind={kClass(k.id)} size="sm" beat={k.status==='running'} />
          </div>
        ))}
      </div>
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
    </div>
  );
}

Object.assign(window, { TopbarStandard, TopbarExpanded, TopbarMinimal, TickerMarquee, TickerChunks, TickerVertical, KpiStandard, KpiCompact, KpiStacked, LifelineBeat, LifelineStacked });
