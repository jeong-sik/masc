import{d,m as e}from"./vendor.js";import{G as p,H as u,I as $}from"./index.js";function m(t){const a=new Date(t),n=String(a.getHours()).padStart(2,"0"),o=String(a.getMinutes()).padStart(2,"0"),i=String(a.getSeconds()).padStart(2,"0");return`${n}:${o}:${i}`}function g(){const[t,a]=d(""),[n,o]=d(!1),i=p.value,c=t.trim().toLowerCase(),l=i.filter(s=>!n&&s.dismissed?!1:c?s.summary.toLowerCase().includes(c)||s.source.toLowerCase().includes(c)||(s.detail?.toLowerCase().includes(c)??!1):!0),r=i.filter(s=>s.dismissed).length;return e`
    <div class="ap-qpeek-stack" data-testid="incidents-overlay">
      <div class="ap-qpeek-banner">
        Channel 3 Historical Log — isolated from Channel 2 Live SSOT.
      </div>

      <div class="ap-inc-toolbar">
        <input
          type="search"
          class="ap-input"
          placeholder="Filter incidents by source or message…"
          aria-label="장애 이력 필터"
          value=${t}
          onInput=${s=>a(s.currentTarget.value)}
        />
        <label class="ap-inc-toggle">
          <input
            type="checkbox"
            checked=${n}
            onChange=${s=>o(s.currentTarget.checked)}
          />
          <span>숨김 포함 (${r})</span>
        </label>
        ${r>0&&e`
          <button type="button" class="btn-ghost" onClick=${u}>
            숨김 비우기
          </button>
        `}
      </div>

      ${l.length===0?e`<p class="ap-muted">기록된 Channel 3 이력이 없습니다.</p>`:e`
            <ul class="ap-qpeek-list">
              ${l.map(s=>e`
                <li
                  key=${s.id}
                  class=${`ap-qpeek-card ap-inc-card ap-inc--${s.severity}${s.dismissed?" is-dismissed":""}`}
                >
                  <div class="ap-qpeek-card-top">
                    <span class="ap-inc-sev">${s.severity.toUpperCase()}</span>
                    <span class="mono ap-muted">${s.source}</span>
                    <span class="mono ap-muted tnum">${m(s.ts)}</span>
                  </div>
                  <div class="ap-inc-summary">${s.summary}</div>
                  ${s.detail&&e`<pre class="ap-inc-detail mono">${s.detail}</pre>`}
                  ${!s.dismissed&&e`
                    <div class="ap-inc-actions">
                      <button
                        type="button"
                        class="btn-ghost"
                        onClick=${()=>$(s.id)}
                      >
                        숨김
                      </button>
                    </div>
                  `}
                </li>
              `)}
            </ul>
          `}
    </div>
  `}export{g as IncidentsOverlayBody};
