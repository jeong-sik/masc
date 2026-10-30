/* MASC v2 — Connectors surface: gate connectors, bindings, audit ledger */
const { useState: useCnState } = React;

function ConnectorConfig({ c, onClose }) {
  const [bot, setBot] = useCnState(c.bot);
  const [replyMode, setReplyMode] = useCnState(c.replyMode);
  const [enabled, setEnabled] = useCnState(c.status === 'connected');
  const [binds, setBinds] = useCnState(() => c.bindings.map((b, i) => ({
    id: 'b' + i, channel: b[0], keeper: b[1],
    dir: c.channel === 'webhook' ? 'inbound' : 'both', on: true,
  })));
  const freeKeepers = KEEPERS.map(k => k.id);
  const setBind = (id, patch) => setBinds(bs => bs.map(b => b.id === id ? { ...b, ...patch } : b));
  const addBind = () => setBinds(bs => [...bs, { id: 'b' + Date.now(), channel: c.channel === 'webhook' ? '/hooks/new' : '#new-channel', keeper: KEEPERS[0].id, dir: c.channel === 'webhook' ? 'inbound' : 'both', on: true }]);
  const delBind = (id) => setBinds(bs => bs.filter(b => b.id !== id));
  React.useEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  const dirOpts = c.channel === 'webhook' ? ['inbound', 'post-back'] : ['both', 'inbound', 'outbound'];
  return (
    <div className="turn-overlay" onClick={onClose}>
      <div className="turn-drawer" onClick={(e) => e.stopPropagation()}>
        <div className="turn-hd">
          <h3>{c.glyph} {c.name} 설정</h3>
          <span className="tid mono">{c.id}</span>
          <button className="turn-close" onClick={onClose} title="닫기 (Esc)">{'\u2715'}</button>
        </div>
        <div className="turn-body">
          <div className="turn-sec">
            <h4>연결</h4>
            <div className="set-row"><div className="set-row-l"><div className="set-label">게이트 활성화</div><div className="set-hint">{enabled ? '연결됨' : '비활성'}</div></div>
              <div className="set-row-c"><button className={`set-toggle ${enabled ? 'on' : ''}`} onClick={() => setEnabled(e => !e)}><span className="knob"></span></button></div></div>
            <div className="set-row"><div className="set-row-l"><div className="set-label">Bot</div></div><div className="set-row-c"><input className="set-input mono" value={bot} onChange={e => setBot(e.target.value)} /></div></div>
            <div className="set-row"><div className="set-row-l"><div className="set-label">{CN_SCOPE[c.channel] ? CN_SCOPE[c.channel][0] : '범위'}</div></div><div className="set-row-c"><span className="mono" style={{ fontSize: 12, color: 'var(--text-mid)' }}>{c.baseUrl || c.guilds}</span></div></div>
            <div className="set-row"><div className="set-row-l"><div className="set-label">토큰</div></div><div className="set-row-c"><div className="set-path"><input className="set-input mono" readOnly value="••••••••••" style={{ width: 150 }} /><button className="set-verify idle">재발급</button></div></div></div>
          </div>
          <div className="turn-sec">
            <h4>기본 응답 모드</h4>
            <div className="set-hint" style={{ marginBottom: 8 }}>바인딩별로 재정의하지 않으면 이 값을 따릅니다.</div>
            <div className="set-seg">{['mention', 'all', 'manual'].map(o => <button key={o} className={`set-seg-b ${replyMode === o ? 'on' : ''}`} onClick={() => setReplyMode(o)}>{o}</button>)}</div>
          </div>
          <div className="turn-sec">
            <h4>채널 → keeper 바인딩 ({binds.length})</h4>
            <div className="set-hint" style={{ marginBottom: 10 }}>어떤 채널이 어떤 keeper에 연결되는지 — 이 매핑이 게이트의 핵심입니다. 한 keeper가 여러 채널을 받거나, 채널마다 다른 keeper로 라우팅할 수 있습니다.</div>
            {binds.length ? binds.map(b => {
              const k = KEEPERS.find(kk => kk.id === b.keeper);
              return (
                <div key={b.id} className={`cn-be ${b.on ? '' : 'off'}`}>
                  <div className="cn-be-main">
                    <input className="cn-be-chn mono" value={b.channel} onChange={e => setBind(b.id, { channel: e.target.value })} />
                    <span className="cn-be-arr">{'\u2192'}</span>
                    <span className="cn-be-kp">
                      {k && <SigilBadge k={k} size={18} />}
                      <select className="cn-be-sel mono" value={b.keeper} onChange={e => setBind(b.id, { keeper: e.target.value })}>
                        {freeKeepers.map(id => <option key={id} value={id}>{id}</option>)}
                      </select>
                    </span>
                    <button className="cn-be-del" title="바인딩 삭제" onClick={() => delBind(b.id)}>{'\u2715'}</button>
                  </div>
                  <div className="cn-be-opts">
                    <div className="cn-be-dir">{dirOpts.map(d => <button key={d} className={`cn-dir-b ${b.dir === d ? 'on' : ''}`} onClick={() => setBind(b.id, { dir: d })}>{d}</button>)}</div>
                    <button className={`set-toggle sm ${b.on ? 'on' : ''}`} title={b.on ? '활성' : '일시중지'} onClick={() => setBind(b.id, { on: !b.on })}><span className="knob"></span></button>
                  </div>
                </div>
              );
            }) : <div className="cn-bind-none">바인딩 없음 — 알림 전용 게이트</div>}
            <button className="set-add" style={{ marginTop: 10 }} onClick={addBind}>＋ 바인딩 추가</button>
          </div>
          {c.error && <div className="callout" style={{ marginBottom: 0 }}><span className="ico">⚠</span><span>{c.error}</span></div>}
        </div>
      </div>
    </div>
  );
}

// 채널마다 '범위'의 뜻이 다르다 — 디스코드만 길드(서버)다.
const CN_SCOPE = {
  discord:  ['서버 (길드)', c => `${c.guilds}개`],
  slack:    ['워크스페이스', c => `${c.guilds}개`],
  imessage: ['대상', c => c.selfChat ? '본인 채팅' : '—'],
  webhook:  ['Base URL', c => c.baseUrl || '—'],
  telegram: ['채팅', c => `${c.guilds}개`],
};

function CnCard({ c, onConfig, onOpenKeeper }) {
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
        <Pill tone={pillCls === 'run' ? 'ok' : pillCls === 'pause' ? 'warn' : 'neutral'} dot={pillCls === 'run' ? 'ok' : pillCls === 'pause' ? 'warn' : 'idle'} dotPulse={dotStatus === 'run'}>{pillLbl}</Pill>
        <button className="cn-config" title="이 게이트 상세 설정" onClick={() => onConfig && onConfig(c)}>⚙</button>
      </div>
      <div className="cn-kv">
        <div className="cell"><div className="k">Bot</div><div className="v hl">{c.bot}</div></div>
        <div className="cell"><div className="k">Reply mode</div><div className="v">{c.replyMode}</div></div>
        <div className="cell"><div className="k">{CN_SCOPE[c.channel] ? CN_SCOPE[c.channel][0] : '범위'}</div><div className="v">{c.baseUrl || (CN_SCOPE[c.channel] ? CN_SCOPE[c.channel][1](c) : '—')}</div></div>
        <div className="cell"><div className="k">Transport</div><div className="v">{c.transport === 'in-process' ? 'in-process WSS' : c.transport === 'sidecar' ? 'sidecar' : c.transport === 'http' ? 'HTTP 엔드포인트' : `PID ${c.pid}`}</div></div>
        <div className="cell"><div className="k">Last ready</div><div className="v">{c.lastReady}</div></div>
        <div className="cell"><div className="k">Updated</div><div className="v">{c.updated}</div></div>
      </div>
      <div className="cn-caps">
        {c.caps.map((cap, i) => <span key={i} className="cn-cap">{cap}</span>)}
      </div>
      {c.note && <div className="cn-note">{c.note}</div>}
      <div className="cn-bind">
        <h5>바인딩 — 채널 → keeper ({c.bindings.length})</h5>
        {c.bindings.length ? c.bindings.map((b, i) => {
          const k = KEEPERS.find(kk => kk.id === b[1]);
          const row = (
            <React.Fragment>
              <span className="chn">{b[0]}</span>
              <span className="arr">→</span>
              {k && <SigilBadge k={k} size={16} />}
              <span style={{ color: 'var(--text-bright)' }}>{b[1]}</span>
              {k && onOpenKeeper && <span className="cn-bind-go">▸</span>}
            </React.Fragment>
          );
          return (k && onOpenKeeper)
            ? <button key={i} type="button" className="cn-bind-row link" title={`${b[1]} 대화 열기`} onClick={() => onOpenKeeper(b[1])}>{row}</button>
            : <div key={i} className="cn-bind-row">{row}</div>;
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

function ConnectorsSurface({ onNav, onOpenKeeper }) {
  const active = CONNECTORS.filter(c => c.status === 'connected' && !c.stale).length;
  const [cfg, setCfg] = useCnState(null);
  return (
    <main className="surf" data-screen-label="커넥터">
      <div className="surf-scroll">
        <header className="surf-head">
          <div>
            <h1>외부 커넥터</h1>
            <div className="surf-sub">{CONNECTORS.length}개 연결 · <b>{active}개 동작 중</b></div>
          </div>
          <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
            <button className="act" onClick={() => { onNav && onNav('settings'); }}>설정 열기 →</button>
            <button className="act">게이트 새로고침 ↻</button>
          </div>
        </header>

        <div className="gate-strip">
          <span><StatusDot status="run" pulse /> 게이트 <b>정상</b></span>
          <span className="sep"></span>
          <span>마지막 확인 <b className="mono" style={{ fontWeight: 500 }}>14:29:14</b></span>
        </div>

        <div className="cn-grid">
          {CONNECTORS.map(c => <CnCard key={c.id} c={c} onConfig={setCfg} onOpenKeeper={onOpenKeeper} />)}
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
      {cfg && <ConnectorConfig c={cfg} onClose={() => setCfg(null)} />}
    </main>
  );
}

Object.assign(window, { ConnectorsSurface });
