// cb-group-a.jsx — Topbar, Ticker, KPI Strip, Lifeline (with variants)
const D = window.MASC_DATA;

// ─── TOPBAR variants ───────────────────────────────────────────────
function TopbarStandard() {
  const [mode, setMode] = useState('dash');
  const [density, setDensity] = useState('n');
  return (
    <div className="cb-board">
      <header className="cb-topbar">
        <div className="brand">
          <span className="brand-mark" />
          <span className="brand-name">MASC</span>
          <span className="ver">v0.42.1</span>
        </div>
        <div className="sep" />
        <button className="goal-switch">
          <Dot kind="brass" size="sm" />
          <span>goal-merge-blockers</span>
          <span className="caret">▾</span>
        </button>
        <div className="mode-tabs">
          {[['dash','Dash'],['code','Code'],['split','Split']].map(([k,l]) => (
            <button key={k} className={mode===k?'on':''} onClick={()=>setMode(k)}>{l}</button>
          ))}
        </div>
        <div className="right">
          <div className="density">
            {['c','n','l'].map(d => <button key={d} className={density===d?'on':''} onClick={()=>setDensity(d)}>{d}</button>)}
          </div>
          <span className="stamp">BUILD 2604 · 16:32:45Z</span>
        </div>
      </header>
      <div style={{flex:1, background:'var(--bg-0)'}} />
    </div>
  );
}

function TopbarExpanded() {
  const [mode, setMode] = useState('split');
  return (
    <div className="cb-board">
      <header className="cb-topbar">
        <div className="brand">
          <span className="brand-mark" />
          <span className="brand-name">MASC</span>
          <span className="ver">v0.42.1</span>
        </div>
        <div className="sep" />
        <button className="goal-switch">
          <Dot kind="brass" size="sm" />
          <span>goal-merge-blockers</span>
          <span className="caret">▾</span>
        </button>
        <span className="branch">release-0.42</span>
        <div className="sep" />
        <div className="mode-tabs">
          {[['dash','Dash'],['code','Code'],['split','Split']].map(([k,l]) => (
            <button key={k} className={mode===k?'on':''} onClick={()=>setMode(k)}>{l}</button>
          ))}
        </div>
        <div className="right">
          <div className="avatars">
            <span className="av" style={{background:'var(--k-nick)'}} />
            <span className="av" style={{background:'var(--k-masc)'}} />
            <span className="av" style={{background:'var(--k-sangsu)'}} />
            <span className="av" style={{background:'var(--k-qa)'}} />
            <span className="av" style={{background:'var(--k-rama)'}} />
          </div>
          <span className="stamp">5 ACTIVE · 2 IDLE</span>
        </div>
      </header>
      <div style={{flex:1, background:'var(--bg-0)'}} />
    </div>
  );
}

function TopbarMinimal() {
  return (
    <div className="cb-board">
      <header className="cb-topbar minimal">
        <div className="brand">
          <span className="brand-mark" />
          <span className="brand-name">MASC</span>
        </div>
        <div className="mode-tabs">
          <button className="on">Dash</button>
          <button>Code</button>
        </div>
        <div className="right">
          <span className="stamp">16:32:45Z</span>
        </div>
      </header>
      <div style={{flex:1, background:'var(--bg-0)'}} />
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
      <div className="cb-ticker">
        <div className="tape">
          {evs.map((e, i) => (
            <span key={i} className={`evt ${e.kind}`}>
              <Dot kind={kClass(e.keeper)} size="sm" />
              <span className="k">{e.keeper}</span>
              <span className="body">{e.text}</span>
              <span className="t">{e.t.slice(0,8)}</span>
            </span>
          ))}
        </div>
      </div>
      <div style={{flex:1, background:'var(--bg-0)'}} />
    </div>
  );
}
function TickerChunks() {
  const evs = [...tickerEvents(), ...tickerEvents()];
  return (
    <div className="cb-board">
      <div className="cb-ticker chunks">
        <div className="tape">
          {evs.map((e, i) => (
            <span key={i} className={`evt ${e.kind}`}>
              <Dot kind={kClass(e.keeper)} size="sm" />
              <span className="k">{e.keeper}</span>
              <span className="body">{e.text.slice(0, 40)}</span>
            </span>
          ))}
        </div>
      </div>
      <div style={{flex:1, background:'var(--bg-0)'}} />
    </div>
  );
}
function TickerVertical() {
  const evs = [...tickerEvents(), ...tickerEvents()];
  return (
    <div className="cb-board">
      <div className="cb-ticker vertical">
        <div className="tape">
          {evs.map((e, i) => (
            <span key={i} className={`evt ${e.kind}`} style={{display:'flex', alignItems:'center', gap:6}}>
              <span className="t">{e.t.slice(0,8)}</span>
              <Dot kind={kClass(e.keeper)} size="sm" />
              <span className="k">{e.keeper}</span>
              <span className="body">{e.text}</span>
            </span>
          ))}
        </div>
      </div>
      <div style={{flex:1, background:'var(--bg-0)'}} />
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
function KpiStandard() {
  return (
    <div className="cb-board">
      <div className="cb-kpi">
        {KPI_CELLS.map((c, i) => (
          <div key={i} className={`cell ${c.live?'live':''} ${c.kind?`is-${c.kind}`:''}`}>
            <span className="lbl">{c.lbl}</span>
            <span className="val">{c.val}</span>
            <span className="cap">{c.cap}{c.delta ? <> · <span className={`delta ${c.deltaKind}`}>{c.delta}</span></> : null}</span>
            {c.spark ? <Spark color={c.live?'brass':'brass'} bars={14} /> : null}
          </div>
        ))}
      </div>
      <div style={{flex:1, background:'var(--bg-0)'}} />
    </div>
  );
}
function KpiCompact() {
  return (
    <div className="cb-board">
      <div className="cb-kpi compact">
        {KPI_CELLS.map((c, i) => (
          <div key={i} className={`cell ${c.live?'live':''} ${c.kind?`is-${c.kind}`:''}`}>
            <span className="lbl">{c.lbl}</span>
            <span className="val">{c.val}</span>
          </div>
        ))}
      </div>
      <div style={{flex:1, background:'var(--bg-0)'}} />
    </div>
  );
}
function KpiStacked() {
  return (
    <div className="cb-board">
      <div className="cb-kpi stacked">
        {KPI_CELLS.slice(0,6).map((c, i) => (
          <div key={i} className={`cell ${c.live?'live':''} ${c.kind?`is-${c.kind}`:''}`}>
            <span className="lbl">{c.lbl}</span>
            <span className="val big">{c.val}</span>
            <span className="cap">{c.cap}</span>
          </div>
        ))}
      </div>
      <div style={{flex:1, background:'var(--bg-0)'}} />
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
      <div className="cb-lifeline">
        <span className="label">LIFELINE</span>
        <Heartbeat phase={phase} />
        <span className="bpm"><span className="n">72</span> BPM · 60s</span>
      </div>
      <div style={{flex:1, background:'var(--bg-0)'}} />
    </div>
  );
}
function LifelineStacked() {
  const [phase, setPhase] = useState(0);
  useEffect(() => { const t = setInterval(() => setPhase(p => (p + 0.02) % 1), 50); return () => clearInterval(t); }, []);
  const fleet = D.keepers.slice(0, 5);
  return (
    <div className="cb-board">
      <div className="cb-lifeline stack">
        {fleet.map((k, i) => (
          <div className="row" key={k.id}>
            <span className="name">{k.id}</span>
            <Heartbeat width={240} height={14} phase={(phase + i*0.07) % 1} />
            <Dot kind={kClass(k.id)} size="sm" beat={k.status==='running'} />
          </div>
        ))}
      </div>
      <div style={{flex:1, background:'var(--bg-0)'}} />
    </div>
  );
}

Object.assign(window, { TopbarStandard, TopbarExpanded, TopbarMinimal, TickerMarquee, TickerChunks, TickerVertical, KpiStandard, KpiCompact, KpiStacked, LifelineBeat, LifelineStacked });
