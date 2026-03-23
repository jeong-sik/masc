import{m as n,g as c}from"./index-BB0zaaHQ.js";import{u as g,c as t}from"./vendor-Chwn_OlE.js";const x=t([]),d=t(0),l=t(!1),s=t(null),r=t("INFO"),p=t(""),o=t(!0),i=t(500),u={DEBUG:"var(--text-muted)",INFO:"var(--text-body)",WARN:"#e6a700",ERROR:"#e05050"};async function a(){l.value=!0,s.value=null;try{const e=await c({limit:i.value,level:r.value,module:p.value||void 0});x.value=e.entries,d.value=e.total}catch(e){s.value=e instanceof Error?e.message:String(e)}finally{l.value=!1}}function m(){return g(()=>{if(a(),!o.value)return;const e=setInterval(()=>{a()},3e3);return()=>clearInterval(e)}),n`
    <div class="logs-viewer flex h-full min-h-0 flex-col gap-4">
      <section class="rounded-[26px] border border-[rgba(138,163,211,0.16)] bg-[linear-gradient(135deg,rgba(9,22,42,0.95),rgba(7,13,24,0.92))] px-5 py-5 shadow-[inset_0_1px_0_rgba(255,255,255,0.04)]">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="min-w-0 max-w-[760px]">
            <div class="text-[10px] font-semibold uppercase tracking-[0.22em] text-[rgba(154,217,255,0.72)]">Observer</div>
            <h2 class="mt-2 text-[26px] font-semibold tracking-[-0.04em] text-[var(--text-strong)]">Execution Log Stream</h2>
            <p class="mt-2 text-[13px] leading-relaxed text-[var(--text-muted)]">
              backend stdout/stderr와 구조화된 런타임 로그를 같은 흐름에서 읽습니다. 에러는 빠르게 띄우고, 나머지는 모듈과 수준으로 좁혀서 봅니다.
            </p>
          </div>

          <div class="grid min-w-[240px] gap-2 rounded-[20px] border border-[rgba(255,255,255,0.07)] bg-[rgba(255,255,255,0.04)] p-3">
            <div class="flex items-center justify-between gap-3 text-[11px] text-[var(--text-muted)]">
              <span>현재 필터</span>
              <strong class="text-[var(--text-strong)]">${r.value}+</strong>
            </div>
            <div class="flex items-center justify-between gap-3 text-[11px] text-[var(--text-muted)]">
              <span>조회 건수</span>
              <strong class="text-[var(--text-strong)] tabular-nums">${(d.value??0).toLocaleString()}</strong>
            </div>
            <div class="flex items-center justify-between gap-3 text-[11px] text-[var(--text-muted)]">
              <span>새로고침</span>
              <strong class="${o.value?"text-[#92f3b4]":"text-[var(--text-strong)]"}">${o.value?"auto":"manual"}</strong>
            </div>
          </div>
        </div>
      </section>

      <section class="flex min-h-0 flex-1 flex-col overflow-hidden rounded-[26px] border border-[rgba(138,163,211,0.16)] bg-[rgba(7,13,24,0.86)]">
        <div class="logs-toolbar flex shrink-0 flex-wrap items-center justify-between gap-4 border-b border-[rgba(255,255,255,0.06)] px-4 py-4">
          <div class="logs-filters flex flex-wrap gap-2 items-center">
          <select
            class="logs-select rounded-[14px] border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.04)] px-3 py-2 text-[12px] text-[var(--text-body)]"
            value=${r.value}
            onChange=${e=>{r.value=e.target.value,a()}}
          >
            <option value="DEBUG">DEBUG+</option>
            <option value="INFO">INFO+</option>
            <option value="WARN">WARN+</option>
            <option value="ERROR">ERROR</option>
          </select>

          <input
            class="logs-module-input min-w-[220px] rounded-[14px] border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.04)] px-3 py-2 text-[12px] text-[var(--text-body)]"
            type="text"
            placeholder="module filter"
            value=${p.value}
            onInput=${e=>{p.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&a()}}
          />

          <select
            class="logs-select rounded-[14px] border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.04)] px-3 py-2 text-[12px] text-[var(--text-body)]"
            value=${String(i.value)}
            onChange=${e=>{i.value=parseInt(e.target.value,10),a()}}
          >
            <option value="100">100</option>
            <option value="500">500</option>
            <option value="1000">1000</option>
            <option value="3000">3000</option>
          </select>
        </div>

        <div class="logs-actions flex flex-wrap gap-3 items-center text-[11px] text-[color:var(--text-muted)]">
          <span class="rounded-full border border-[rgba(255,255,255,0.08)] bg-[rgba(255,255,255,0.04)] px-2.5 py-1 tabular-nums">${(d.value??0).toLocaleString()} total</span>
          <label class="logs-auto-label flex items-center gap-1.5 cursor-pointer">
            <input
              type="checkbox"
              checked=${o.value}
              onChange=${()=>{o.value=!o.value}}
            />
            자동
          </label>
          <button class="logs-refresh-btn rounded-[14px] border border-[rgba(71,184,255,0.22)] bg-[rgba(71,184,255,0.12)] px-3 py-2 text-[11px] font-medium text-[#dff3ff]" onClick=${()=>{a()}}
            disabled=${l.value}>
            ${l.value?"...":"새로고침"}
          </button>
        </div>
        </div>

        ${s.value?n`
          <div class="mx-4 mt-4 rounded-[18px] border border-solid border-[#e05050] bg-[rgba(224,80,80,0.12)] px-4 py-3 text-[12px] text-[#ffb3b3]">${s.value}</div>
        `:null}

        <div class="logs-table-wrap min-h-0 flex-1 overflow-auto px-3 pb-3">
          <table class="logs-table w-full border-separate border-spacing-y-2">
          <thead>
            <tr>
              <th class="logs-col-ts w-44 whitespace-nowrap px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-[0.14em] text-[color:var(--text-muted)]">timestamp</th>
              <th class="logs-col-level w-20 whitespace-nowrap px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-[0.14em] text-[var(--text-muted)]">level</th>
              <th class="logs-col-module w-40 whitespace-nowrap px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-[0.14em] text-[var(--text-muted)]">module</th>
              <th class="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-[0.14em] text-[var(--text-muted)]">message</th>
            </tr>
          </thead>
          <tbody>
            ${x.value.map(e=>n`
              <tr
                key=${e.seq}
                class="logs-row ${e.level==="ERROR"?"bg-[rgba(224,80,80,0.08)]":e.level==="WARN"?"bg-[rgba(230,167,0,0.05)]":"bg-[rgba(255,255,255,0.02)]"}"
              >
                <td class="logs-col-ts rounded-l-[18px] border-y border-l border-[rgba(255,255,255,0.05)] px-3 py-3 align-top font-mono text-[11px] whitespace-nowrap text-[color:var(--text-muted)]">
                  ${e.ts.replace("T"," ").replace("Z","")}
                </td>
                <td class="logs-col-level border-y border-[rgba(255,255,255,0.05)] px-3 py-3 align-top font-mono text-[11px] font-semibold whitespace-nowrap" style="color: ${u[e.level]??"inherit"}">
                  ${e.level}
                </td>
                <td class="logs-col-module border-y border-[rgba(255,255,255,0.05)] px-3 py-3 align-top font-mono text-[11px] whitespace-nowrap text-[color:var(--accent)]">
                  ${e.module}
                </td>
                <td class="rounded-r-[18px] border-y border-r border-[rgba(255,255,255,0.05)] px-3 py-3 align-top font-mono text-[12px] leading-relaxed break-words text-[var(--text-body)]">
                  ${e.message}
                </td>
              </tr>
            `)}
          </tbody>
        </table>
        </div>
      </section>
    </div>
  `}export{m as LogViewer};
