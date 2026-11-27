import{d as J,A as M,y as w,q as Z,m as s}from"./vendor.js";import{I as D}from"./inline-spinner.js";import{M as H}from"./markdown-renderer.js";import{a as ee,l as se,s as ae,p as F,b as B,d as ne,e as te,w as le,x as oe,y as re,i as ie,z as Q,A as U,B as N,r as pe,C as ce,D as ue,k as de,u as W,E as f,n as b,F as ke}from"./index.js";import{f as me}from"./format-time.js";import"./markdown.js";import"./format-string.js";const z="shell:queue-context",he=["schedules","schedule_store_changed","scheduled_automation_changed","scheduled_automation"];function I(a){return typeof a=="object"&&a!==null&&!Array.isArray(a)}function C(a){return typeof a=="number"&&Number.isFinite(a)?a:null}function h(a){return typeof a=="string"&&a.trim().length>0?a.trim():null}function $e(a){const t=I(a)&&I(a.counts)?a.counts:null;return{keepers:C(t?.keepers),tasks:C(t?.tasks),agents:C(t?.agents),pendingApprovals:F.peek().length,pendingAsks:B.peek().length}}const r=10,ge=5;function V(a,t){const l=h(a);if(l)return l;const i=C(t);if(i!==null&&i>0)try{return new Date(i*1e3).toISOString()}catch{return null}return null}function ve(a){if(!I(a))return[];const t=h(a.schedule_id);if(!t)return[];const l=h(a.payload_summary);return[{id:t,summary:l??t,summaryIsProse:l!==null&&a.payload_kind==="masc.keeper_wake",keeper:h(a.payload_keeper_name)??h(a.payload_target),dueAt:V(a.next_due_at_iso,a.next_due_at)??V(a.due_at_iso,a.due_at),status:h(a.status)??"미보고"}]}function fe(a){if(!I(a))return{state:"unavailable",reason:"예약 자동화 응답 형식이 잘못되었습니다."};const t=h(a.schedule_store_read_error);if(t)return{state:"unavailable",reason:t};if(a.schedule_store_known===!1||a.status==="unknown")return{state:"unavailable",reason:"예약 저장소 상태를 확인할 수 없습니다."};if(!Array.isArray(a.requests))return{state:"unavailable",reason:"예약 자동화 응답 형식이 잘못되었습니다."};const l=a.requests.flatMap(ve),i=C(a.request_count),m=i!==null&&Number.isSafeInteger(i)&&i>=0?i:l.length;return{state:"available",rows:l,totalCount:m,truncated:a.truncated===!0,observedAt:Date.now()}}function Ae(){const a=ee.value,t=se(a),l=ae.value,i=F.value,m=B.value,$=ne.value,g=te.value,d=le.value,X=oe.value,n=re.value,j=ie.value,v=Q.observe(z).value,[T,q]=J(()=>({epoch:l,sample:null,loading:!1,error:null})),k=M(null),x=M(!0);w(()=>(x.current=!0,()=>{x.current=!1,k.current?.abort(),k.current=null}),[]);const O=T.epoch===l?T:{sample:null,loading:!1,error:null},o=O.sample,y=O.loading,S=O.error,P=o?o.rows.slice(0,ge):[],E=o!==null&&(y||S!==null),G=o?`${o.totalCount}${E?" · 마지막 확인":""}`:S?"조회 실패":"…",_=(e,u)=>{if(u.kind==="ok")return String(e);const p=W(u);return e>0?`${e} · ${p}`:p},A=Z(async e=>{k.current?.abort();const u=new AbortController;k.current=u,q(c=>({epoch:e,sample:c.epoch===e?c.sample:null,loading:!0,error:c.epoch===e?c.error:null}));const p=await U("/api/v1/dashboard/scheduled-automation?active_only=true",{signal:u.signal,decode:fe});if(!(!x.current||u.signal.aborted||!N(e))){if(!p.ok){if(p.error.kind==="aborted"||p.error.kind==="epoch_stale")return;q(c=>({epoch:e,sample:c.epoch===e?c.sample:null,loading:!1,error:p.error.message}));return}if(p.value.state==="unavailable"){const c=p.value.reason;q(K=>({epoch:e,sample:K.epoch===e?K.sample:null,loading:!1,error:c}));return}q({epoch:e,sample:p.value,loading:!1,error:null})}},[]),L=M(A);L.current=A,w(()=>{if(!t){k.current?.abort(),k.current=null,q({epoch:l,sample:null,loading:!1,error:null});return}return Q.fetch(z,e=>U("/api/v1/dashboard/shell",{signal:e,decode:$e}),{ttlMs:1e4,topics:["workspace_dataset_changed","keeper_heartbeat"],reason:"mount"}),A(l),pe(),()=>{k.current?.abort(),k.current=null}},[t,l,A]),w(()=>{if(!t)return;let e=!1,u=!1;const p=ce(c=>{ue(c).some(Y=>he.includes(Y))&&(u||(u=!0,queueMicrotask(()=>{u=!1,!(e||!x.current||!N(l))&&L.current(l)})))});return()=>{e=!0,p()}},[t,l]);const R=e=>v.kind!=="value"?ke(v):e==null?"미보고":String(e);return s`
    <div class="ap-qpeek-stack" data-testid="queue-context-overlay">
      <div class="ap-qpeek-banner">
        Read-Only Queue & Context Quick-Peek — mutations live in Unified Inbox & Keepers.
      </div>

      ${t?s`
            <div class="ap-mini-kpis">
              <div class="ap-mini-kpi">
                <span class="ap-mini-kpi-k">Keepers</span>
                <strong class="ap-mini-kpi-v tnum">${R(v.kind==="value"?v.data.keepers:null)}</strong>
              </div>
              <div class="ap-mini-kpi">
                <span class="ap-mini-kpi-k">Tasks</span>
                <strong class="ap-mini-kpi-v tnum">${R(v.kind==="value"?v.data.tasks:null)}</strong>
              </div>
              <div class="ap-mini-kpi">
                <span class="ap-mini-kpi-k">HITL Queue</span>
                <strong class="ap-mini-kpi-v tnum">
                  ${de(X,j.length>0)}
                </strong>
                ${d.length>0&&s`
                  <span class="ap-mini-kpi-sub tnum">+${d.length} verif</span>
                `}
                ${n.verification.kind!=="ok"&&s`
                  <span class="ap-mini-kpi-sub">
                    검증 ${W(n.verification)}
                  </span>
                `}
              </div>
              <div class="ap-mini-kpi">
                <span class="ap-mini-kpi-k">Schedules</span>
                <strong class="ap-mini-kpi-v tnum">
                  ${G}
                </strong>
              </div>
            </div>

            <section class="ap-qpeek-section">
              <header class="ap-qpeek-section-head">
                <h3>Pending Tool Approvals (${_(i.length,n.approvals)})</h3>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${()=>{f(),b("/work/inbox")}}
                >
                  Open Inbox →
                </button>
              </header>
              ${n.approvals.kind==="failed"&&s`
                <p class="ap-error" role="alert">도구 승인 조회 실패: ${n.approvals.message}</p>
              `}
              ${n.approvals.kind==="unbridged"?s`<p class="ap-muted" role="note">멀티 계정 세션에서는 도구 승인 대기열을 조회할 수 없어 미확인 상태입니다.</p>`:i.length===0?n.approvals.kind==="ok"?s`<p class="ap-muted">대기 중인 도구 승인 요청이 없습니다.</p>`:null:s`
                      <ul class="ap-qpeek-list">
                        ${i.slice(0,r).map(e=>s`
                          <li key=${e.approvalId} class="ap-qpeek-card">
                            <div class="ap-qpeek-card-top">
                              <strong>${e.keeper}</strong>
                              <code class="mono">${e.tool||e.toolCallId}</code>
                            </div>
                            ${e.question&&s`<${H} class="ap-qpeek-card-text" text=${e.question} />`}
                            <div class="ap-qpeek-card-meta mono">
                              req=${e.approvalId} · rev=${e.revision}
                            </div>
                          </li>
                        `)}
                      </ul>
                      ${i.length>r&&s`
                        <p class="ap-muted">상위 ${r}건 표시 (전체 ${i.length}건)</p>
                      `}
                    `}
            </section>

            <section class="ap-qpeek-section">
              <header class="ap-qpeek-section-head">
                <h3>Open Keeper Asks (${_(m.length,n.asks)})</h3>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${()=>{f(),b("/keepers")}}
                >
                  Open Keepers →
                </button>
              </header>
              ${n.asks.kind==="failed"&&s`
                <p class="ap-error" role="alert">Keeper 질문 조회 실패: ${n.asks.message}</p>
              `}
              ${n.asks.kind==="unbridged"?s`<p class="ap-muted" role="note">멀티 계정 세션에서는 Keeper 질문 대기열을 조회할 수 없어 미확인 상태입니다.</p>`:m.length===0?n.asks.kind==="ok"?s`<p class="ap-muted">대기 중인 Keeper 질문이 없습니다.</p>`:null:s`
                      <ul class="ap-qpeek-list">
                        ${m.slice(0,r).map(e=>s`
                          <li key=${e.askId} class="ap-qpeek-card">
                            <div class="ap-qpeek-card-top">
                              <strong>${e.keeper}</strong>
                              <span class="mono ap-muted">${e.askId}</span>
                            </div>
                            <${H} class="ap-qpeek-card-text" text=${e.prompt} />
                          </li>
                        `)}
                      </ul>
                      ${m.length>r&&s`
                        <p class="ap-muted">상위 ${r}건 표시 (전체 ${m.length}건)</p>
                      `}
                    `}
            </section>

            ${($.length>0||n.gate.kind!=="ok")&&s`
              <section class="ap-qpeek-section">
                <header class="ap-qpeek-section-head">
                  <h3>Channel Gate Approvals (${_($.length,n.gate)})</h3>
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${()=>{f(),b("/work/inbox")}}
                  >
                    Open Inbox →
                  </button>
                </header>
                ${n.gate.kind==="failed"&&s`
                  <p class="ap-error" role="alert">Channel Gate 조회 실패: ${n.gate.message}</p>
                `}
                ${n.gate.kind==="unbridged"&&s`
                  <p class="ap-muted" role="note">멀티 계정 세션에서는 Channel Gate 대기열을 조회할 수 없어 미확인 상태입니다.</p>
                `}
                ${$.length>0&&s`
                  <ul class="ap-qpeek-list">
                    ${$.slice(0,r).map(e=>s`
                      <li key=${e.id} class="ap-qpeek-card">
                        <div class="ap-qpeek-card-top">
                          <strong>${e.keeper}</strong>
                          <code class="mono">${e.toolName}</code>
                        </div>
                        <div class="ap-qpeek-card-meta mono">
                          phase=${e.phase}${e.waitingSec!==null?` · wait ${Math.round(e.waitingSec)}s`:""}
                        </div>
                      </li>
                    `)}
                  </ul>
                  ${$.length>r&&s`
                    <p class="ap-muted">상위 ${r}건 표시 (전체 ${$.length}건)</p>
                  `}
                `}
              </section>
            `}

            ${(g.length>0||n.planning.kind!=="ok")&&s`
              <section class="ap-qpeek-section">
                <header class="ap-qpeek-section-head">
                  <h3>Goal Confirmations (${_(g.length,n.planning)})</h3>
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${()=>{f(),b("/work/inbox")}}
                  >
                    Open Inbox →
                  </button>
                </header>
                ${n.planning.kind==="failed"&&s`
                  <p class="ap-error" role="alert">Goal 확인 대기열 조회 실패: ${n.planning.message}</p>
                `}
                ${g.length>0&&s`
                  <ul class="ap-qpeek-list">
                    ${g.slice(0,r).map(e=>s`
                      <li key=${e.goalId} class="ap-qpeek-card">
                        <div class="ap-qpeek-card-top">
                          <strong>${e.title}</strong>
                          <span class="mono ap-muted">${e.goalId}</span>
                        </div>
                      </li>
                    `)}
                  </ul>
                  ${g.length>r&&s`
                    <p class="ap-muted">상위 ${r}건 표시 (전체 ${g.length}건)</p>
                  `}
                `}
              </section>
            `}

            ${(d.length>0||n.verification.kind!=="ok")&&s`
              <section class="ap-qpeek-section">
                <header class="ap-qpeek-section-head">
                  <h3>Awaiting Verifications (${_(d.length,n.verification)})</h3>
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${()=>{f(),b("/work/tasks")}}
                  >
                    Open Tasks →
                  </button>
                </header>
                ${n.verification.kind==="failed"&&s`
                  <p class="ap-error" role="alert">검증 대기열 조회 실패 · ${n.verification.message}</p>
                  ${d.length>0&&s`<p class="ap-muted">마지막으로 읽은 검증 대기열을 표시합니다.</p>`}
                `}
                ${(n.verification.kind==="partial"||n.verification.kind==="recovered")&&s`
                  <p class="ap-muted" role="status">${n.verification.message}</p>
                `}
                ${n.verification.kind==="unbridged"&&s`
                  <p class="ap-muted" role="note">멀티 계정 세션에서는 검증 대기열을 조회할 수 없어 미확인 상태입니다.</p>
                `}
                ${d.length>0&&s`
                  <ul class="ap-qpeek-list">
                    ${d.slice(0,r).map(e=>s`
                      <li key=${e.requestId} class="ap-qpeek-card">
                        <div class="ap-qpeek-card-top">
                          <strong>${e.title}</strong>
                          <span class="mono ap-muted">${e.taskId}</span>
                        </div>
                        ${e.worker&&s`<div class="ap-qpeek-card-meta mono">by=${e.worker}</div>`}
                      </li>
                    `)}
                  </ul>
                  ${d.length>r&&s`
                    <p class="ap-muted">조회한 ${d.length}건 중 ${r}건 표시</p>
                  `}
                `}
              </section>
            `}

            <section class="ap-qpeek-section">
              <header class="ap-qpeek-section-head">
                <div style=${{display:"flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap",minWidth:0}}>
                  <h3>Upcoming Schedules (<span class="tnum">${G}</span>)</h3>
                  ${y&&o&&s`
                    <span class="ap-muted" role="status" style=${{fontSize:"var(--fs-11)",display:"inline-flex",alignItems:"center",gap:"var(--sp-1)"}}>
                      <${D} size="xs" /> 예약 갱신 중…
                    </span>
                  `}
                  ${!y&&o&&E&&s`
                    <span class="ap-muted tnum" style=${{fontSize:"var(--fs-11)"}}>
                      마지막 확인 · <time dateTime=${new Date(o.observedAt).toISOString()}>
                        ${me(o.observedAt/1e3)}
                      </time>
                    </span>
                  `}
                </div>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${()=>{f(),b("/work/tasks?view=schedules")}}
                >
                  Open Schedules →
                </button>
              </header>
              ${y&&!o&&s`
                <p class="ap-muted" role="status">
                  <${D} /> 예약 불러오는 중…
                </p>
              `}
              ${S&&s`<p class="ap-error" role="alert">예약 조회 실패 · ${S}</p>`}
              ${!o&&!y&&!S&&s`
                <p class="ap-muted">예약 조회 대기 중</p>
              `}
              ${o&&o.totalCount===0&&s`
                <p class="ap-muted">${E?"마지막 조회에 활성 예약이 없었습니다.":"활성 예약 자동화가 없습니다."}</p>
              `}
              ${P.length>0&&s`
                <ul class="ap-qpeek-list">
                  ${P.map(e=>s`
                    <li key=${e.id} class="ap-qpeek-card">
                      <div class="ap-qpeek-card-top">
                        <strong>${e.keeper??e.id}</strong>
                        <span class="mono ap-muted">${e.status}</span>
                      </div>
                      ${e.summaryIsProse?s`<${H} class="ap-qpeek-card-text" text=${e.summary} />`:s`<p class="ap-qpeek-card-text">${e.summary}</p>`}
                      ${e.dueAt&&s`<div class="ap-qpeek-card-meta mono">due=${e.dueAt}</div>`}
                    </li>
                  `)}
                </ul>
              `}
              ${o&&(o.truncated||P.length<o.totalCount)&&s`
                <p class="ap-muted">표시 제한으로 일부 예약만 표시됩니다. 전체 목록은 Schedules에서 확인하세요.</p>
              `}
            </section>
          `:s`<p class="ap-muted">${a.kind==="single_user_local"&&a.role==="player"?"플레이어 세션에서는 작업 공간 큐와 컨텍스트 요약을 조회할 수 없습니다.":"인증 후 활성 큐와 컨텍스트 요약을 표시합니다."}</p>`}
    </div>
  `}export{Ae as QueueContextOverlayBody};
