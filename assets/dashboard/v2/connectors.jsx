/* MASC v2 — Connectors surface: gate connectors, bindings, audit ledger */

function CnCard({ c }) {
  const dotStatus = c.stale ? 'pause' : c.status === 'connected' ? 'run' : 'off';
  const pillCls = c.stale ? 'pause' : c.status === 'connected' ? 'run' : 'off';
  const pillLbl = c.stale ? 'Stale' : c.status === 'connected' ? 'Connected' : 'Down';
  return (
    <article className={`cn-card ${c.stale ? 'stale' : ''}`}>
      <div className="cn-h">
        <span className="cn-glyph">{c.glyph}</span>
        <div className="meta">
          <div className="nm">{c.name}</div>
          <div className="ch">{c.id} · channel: {c.channel}</div>
        </div>
        <span className={`state-pill ${pillCls}`}><StatusDot status={dotStatus} pulse={dotStatus === 'run'} />{pillLbl}</span>
      </div>
      <div className="cn-kv">
        <div className="cell"><div className="k">Bot</div><div className="v hl">{c.bot}</div></div>
        <div className="cell"><div className="k">Reply mode</div><div className="v">{c.replyMode}</div></div>
        <div className="cell"><div className="k">{c.channel === 'webhook' ? 'Base URL' : 'Guilds'}</div><div className="v">{c.baseUrl || c.guilds}</div></div>
        <div className="cell"><div className="k">PID</div><div className="v">{c.pid}</div></div>
        <div className="cell"><div className="k">Last ready</div><div className="v">{c.lastReady}</div></div>
        <div className="cell"><div className="k">Updated</div><div className="v">{c.updated}</div></div>
      </div>
      <div className="cn-caps">
        {c.caps.map((cap, i) => <span key={i} className="cn-cap">{cap}</span>)}
      </div>
      <div className="cn-bind">
        <h5>바인딩 — 채널 → keeper ({c.bindings.length})</h5>
        {c.bindings.length ? c.bindings.map((b, i) => {
          const k = KEEPERS.find(kk => kk.id === b[1]);
          return (
            <div key={i} className="cn-bind-row">
              <span className="chn">{b[0]}</span>
              <span className="arr">→</span>
              {k && <SigilBadge k={k} size={16} />}
              <span style={{ color: 'var(--text-bright)' }}>{b[1]}</span>
            </div>
          );
        }) : <div className="cn-bind-none">바인딩 없음 — 이 게이트는 알림 전용입니다.</div>}
        {c.error && (
          <div className="callout" style={{ marginTop: 10, marginBottom: 0 }}>
            <span className="ico">⚠</span><span>{c.error}</span>
          </div>
        )}
      </div>
    </article>
  );
}

function ConnectorsSurface() {
  const active = CONNECTORS.filter(c => c.status === 'connected' && !c.stale).length;
  return (
    <main className="surf" data-screen-label="커넥터">
      <div className="surf-scroll" style={{ maxWidth: 1280, width: '100%', margin: '0 auto' }}>
        <header className="surf-head">
          <div>
            <div className="eyebrow">Gate</div>
            <h1>커넥터</h1>
            <div className="surf-sub">외부 게이트 {CONNECTORS.length}개 · <b>{active} active</b> · <span className="mono">GET /api/v1/gate/connectors</span></div>
          </div>
          <button className="act">게이트 새로고침 ↻</button>
        </header>

        <div className="gate-strip">
          <span><StatusDot status="run" pulse /> gate <b>healthy</b></span>
          <span className="sep"></span>
          <span className="mono">base https://gate.masc.local</span>
          <span className="sep"></span>
          <span>health check <b className="mono" style={{ fontWeight: 500 }}>14:29:14</b></span>
          <span className="sep"></span>
          <span>binding source <b>store + runtime</b></span>
          <span style={{ marginLeft: 'auto' }} className="mono">generated_at 2026-06-10T14:29:14+09:00</span>
        </div>

        <div className="cn-grid">
          {CONNECTORS.map(c => <CnCard key={c.id} c={c} />)}
        </div>

        <section className="cn-audit">
          <div className="ov-card-h">
            <h3>최근 감사 로그</h3>
            <span className="ov-legend mono">recent_audit · last 5</span>
          </div>
          <table>
            <thead>
              <tr><th>시각</th><th>액션</th><th>대상</th><th>Keeper</th><th>Actor</th><th>이전 keeper</th></tr>
            </thead>
            <tbody>
              {CONNECTOR_AUDIT.map((a, i) => (
                <tr key={i}>
                  <td>{a[0]}</td>
                  <td className="act">{a[1]}</td>
                  <td>{a[2]}</td>
                  <td>{a[3]}</td>
                  <td>{a[4]}</td>
                  <td>{a[5]}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      </div>
    </main>
  );
}

Object.assign(window, { ConnectorsSurface });
