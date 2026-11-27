import{d,A as de,q as N,y as J,T as D,m as s}from"./vendor.js";import{a as S,R as re,S as H,l as ce,z as Q,T as ue,U as pe,V as ve,K as ke,j as X,s as $,A as be,W as ge,X as K,Q as we,o as $e}from"./index.js";import{K as me}from"./core.js";import{D as he}from"./data-table.js";import{R as fe}from"./refresh-button.js";import{T as Y}from"./target-locked-action.js";import{U as ye}from"./uplot-chart.js";import{m as Ce,r as Ie,i as L,d as Z,n as _e,o as m,a as Se}from"./types.js";import"./type-guards.js";import"./table.js";import"./useSelector.js";import"./virtual-list.js";import"./keeper-state.js";import"./format-string.js";const Le=[{label:"누적 발행 (Issued)",colorToken:"--info-fg",width:1.75,unit:"C"},{label:"감쇠 유통량 (Decayed)",colorToken:"--brass-1",width:2,fillAlpha:.16,unit:"C"}];function qe(c){const W=S.value,ee=re(W),u=H(W),ae=u,[a,se]=d(null),[le,M]=d(!0),[q,P]=d(null),[h,R]=d(c.entityId??""),[F,f]=d(null),[O,p]=d(!1),[G,v]=d(null),[k,j]=d(null),[E,T]=d(null),b=de(null),y=N(async(e="mount")=>{if(!ce(S.peek())){M(!1);return}M(!0),P(null);const i=await Q.fetch("work:candle:ledger",async o=>{const l=await ue("/api/v1/candle/ledger?limit=100",{signal:o});if(!l.ok)return l;const n=Ce(l.value);return n.ok?ve(n.value):pe({kind:"decode",status:200,code:"candle_decode_error",message:n.error,retryable:!1})},{ttlMs:15e3,topics:["candle","goals"],reason:e});M(!1),i.kind==="value"?(se(i.data),ke()):i.kind==="failed"&&P(i.error.message)},[]);J(()=>{y("mount")},[y]);const r=N(async e=>{if(!H(S.peek()))return;const i=e.trim();if(!i)return;b.current?.abort();const o=new AbortController;b.current=o;const{signal:l}=o,n=X.peek(),g=$.peek();p(!0),v(null),f(null);const _=await Ie(l);if(l.aborted)return;if($.peek()!==g){p(!1);return}if(!_.ok){p(!1),v(_.error.message);return}const B={base_path:_.value.base_path,masc_root:_.value.masc_root},oe=new URLSearchParams({goal_id:i,expected_base_path:B.base_path,expected_masc_root:B.masc_root}),w=await be(`/api/v1/dashboard/goals/candle?${oe.toString()}`,{signal:l});l.aborted||(p(!1),$.peek()===g&&(w.ok?!L(w.value)||w.value.goal_id!==i?v("요청한 Goal의 Candle 지급 상태를 확인할 수 없습니다."):f({goalId:i,workspace:B,workspaceId:n,epoch:g,data:w.value}):v(w.error.message)))},[]);J(()=>(c.entityId&&u?(R(c.entityId),r(c.entityId)):u||(b.current?.abort(),f(null),p(!1),v(null)),()=>b.current?.abort()),[c.entityId,u,r]);const t=F?.goalId===h.trim()?F:null,x=t?.data.ledger,C=L(x)&&x.state==="observed"?x.payout:null,z=L(C)&&C.state==="held"&&C.origin==="stored"?C:null,U=Z(z?.request_id),V=Z(z?.verification_run_id),ie=async(e,i,o)=>{if(!H(S.peek())||k!==null||$.peek()!==e.epoch||X.peek()!==e.workspaceId||t!==e)return;const{goalId:l}=e;j(l),T(null);const n=await we("POST","/api/v1/dashboard/goals/candle/hold/release",{goal_id:l,expected_workspace:e.workspace,expected_hold:{request_id:i,verification_run_id:o}});if(j(null),$.peek()===e.epoch){if(!n.ok||!L(n.value)||n.value.outcome!=="released"||n.value.goal_id!==l){const g=n.ok?"서버가 보류 해제를 확인하지 않았습니다.":n.error.message;T({kind:"err",message:`보류 해제 실패 (${l}): ${g}`}),await r(l);return}T(null),$e(`Goal ${l} Candle 지급 보류 해제됨`,"success"),Q.invalidateTopic("candle"),await Promise.all([y("manual"),r(l)])}},ne=D(()=>{if(!a)return[[],[],[]];const e=_e(a);return[e.timestamps,e.cumulativeIssued,e.decayedSupply]},[a]),A=D(()=>{if(!a)return null;const e=a.supply.issuedMilli,i=a.supply.circulatingMilli;return e===null||i===null||e<=0?null:Math.max(0,Math.min(100,Math.round(i/e*100)))},[a]),te=D(()=>[{id:"keeper",header:"Keeper",sortable:!0,sortValue:e=>e.keeper,cell:e=>s`<${me} id=${e.keeper} portrait=${!0} size="sm" />`},{id:"decayed",header:"감쇠 잔액 (Candle)",numeric:!0,sortable:!0,sortValue:e=>e.decayedMilli??-1,observed:e=>e.decayedMilli===null?ge():K(e.decayedMilli),formatValue:e=>m(e)},{id:"raw",header:"원장 잔액 (Candle)",numeric:!0,sortable:!0,sortValue:e=>e.balanceMilli,observed:e=>K(e.balanceMilli),formatValue:e=>m(e)},{id:"owned",header:"보유 장신구",numeric:!0,sortable:!0,sortValue:e=>e.ownedItems.length,observed:e=>K(e.ownedItems.length)},{id:"equipped",header:"장착 슬롯",cell:e=>{const i=Object.entries(e.equipped).filter(([,o])=>o!==null).map(([o,l])=>`${o}:${l}`);return i.length>0?s`<span class="mono wk-sub-id">${i.join(", ")}</span>`:s`<span class="dtable-absent">없음</span>`}},{id:"lastEvent",header:"최근 변동",accessor:e=>Se(e.lastEventUnix)}],[]),I=a?.ledgerState==="missing";return s`
    <div class="wk-scroll-body">
      <div class="wk-toolbar">
        <div>
          <span class="wk-badge wk-badge--brass">Candle Economy</span>
          <span class="wk-caption-inline">
            Goal 완료 보상 화폐 · 초상화 장신구 전용 (constitution.xml)
          </span>
        </div>
        <${fe} onRefresh=${()=>y("manual")} />
      </div>

      ${q&&s`<div class="wk-notice wk-notice--err" role="alert">${q}</div>`}
      ${a?.balanceError&&s`<div class="wk-notice wk-notice--warn" role="alert">잔액 계산 오류: ${a.balanceError}</div>`}
      ${le&&!a&&s`<span class="dtable-absent">Candle 원장 불러오는 중…</span>`}

      ${a&&s`
        <div class="ov-kpis">
          <div class="ov-kpi">
            <div class="ov-kpi-k">유통량 (Circulating)</div>
            <div class="ov-kpi-v volt">${I?"없음":m(a.supply.circulatingMilli)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">누적 발행 (Issued)</div>
            <div class="ov-kpi-v">${I?"없음":m(a.supply.issuedMilli)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">소각량 (Burned)</div>
            <div class="ov-kpi-v">${I?"없음":m(a.supply.burnedMilli)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">참여 Keeper</div>
            <div class="ov-kpi-v">${I?"없음":String(a.supply.activeKeepers)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">원장 이벤트</div>
            <div class="ov-kpi-v">${String(a.totalEvents)}</div>
          </div>
        </div>

        <div class="wk-2col">
          <${ye}
            id="candle-supply-trend"
            title="Decayed Supply vs Cumulative Issuance"
            subtitle=${s`<span class="mono wk-sub-id">events: ${a.recentEvents.length}</span>`}
            data=${ne}
            series=${Le}
            height=${210}
            emptyLabel="발행/감쇠 추이 이벤트가 아직 없습니다."
          />

          <section class="wk-section" aria-label="반감기 감쇠 정책">
            <div class="wk-section-head">
              <h3 class="wk-section-title">Half-Life Decay Policy</h3>
              <span class=${`wk-badge ${a.policy.configuration==="enabled"?"wk-badge--brass":"wk-badge--idle"}`}>
                ${a.policy.configuration} · ${a.policy.pricingMode}
              </span>
            </div>
            ${a.policy.disabledReason&&s`
              <div class="wk-notice wk-notice--warn">비활성 사유: ${a.policy.disabledReason}</div>
            `}
            <div class="wk-kv-grid">
              <div class="wk-kv">
                <span class="wk-kv-k">감쇠 모드</span>
                <span class="wk-kv-v">${a.policy.halfLifeMode}</span>
              </div>
              <div class="wk-kv">
                <span class="wk-kv-k">반감기</span>
                <span class="wk-kv-v tnum">
                  ${a.policy.halfLifeHours!==null?`${a.policy.halfLifeHours}h`:a.policy.halfLifeSec!==null?`${Math.round(a.policy.halfLifeSec)}s`:"없음"}
                </span>
              </div>
              <div class="wk-kv">
                <span class="wk-kv-k">잔존 비율 (Circulating / Issued)</span>
                <span class="wk-kv-v tnum">${A===null?"없음":`${A}%`}</span>
              </div>
            </div>
            <progress
              class="wk-gauge"
              value=${A??0}
              max="100"
              aria-label="유통 잔존 게이지"
            />
          </section>
        </div>

        <section class="wk-section" aria-label="Keeper Candle 리더보드">
          <div class="wk-section-head">
            <h3 class="wk-section-title">Keeper Candle Leaderboard (<span class="tnum">${a.balances.length}</span>)</h3>
          </div>
          <${he}
            data=${a.balances}
            columns=${te}
            getRowId=${e=>e.keeper}
            caption="Keeper별 Candle 원장 잔액 및 감쇠 잔액"
            emptyLabel="잔액이 기록된 Keeper가 없습니다."
          />
        </section>

        <details
          class="ap-disclosure"
          data-testid="candle-diagnostics-disclosure"
          aria-label="지급 진단 및 보류 해제"
          open=${a.diagnostics.heldWindowsCount>0||a.diagnostics.unattributedCount>0||a.diagnostics.items.length>0||!!c.entityId||t!==null||!!G||!!E||void 0}
        >
          <summary class="ap-disclosure-trigger">
            <span>Unattributed / Backlog-Fenced Diagnostics & Hold Release</span>
            <span class="wk-sub-id tnum">
              Held ${a.diagnostics.heldWindowsCount} · Unattributed ${a.diagnostics.unattributedCount} ▸
            </span>
          </summary>
          <div class="ap-disclosure-body">
            <div class="wk-chips">
              <span class="wk-badge wk-badge--warn tnum">Held Windows: ${a.diagnostics.heldWindowsCount}</span>
              <span class="wk-badge wk-badge--err tnum">Unattributed: ${a.diagnostics.unattributedCount}</span>
              <span class="wk-badge wk-badge--idle tnum">Backlog Fenced: ${a.diagnostics.backlogFencedCount}</span>
              <span class="wk-badge wk-badge--idle tnum">0-Task Goals: ${a.diagnostics.zeroLinkedTasksGoals}</span>
            </div>

            ${E&&s`
              <div class="wk-notice wk-notice--err" role="alert">
                ${E.message}
              </div>
            `}

            ${u?s`
                  <div class="wk-row-wrap">
                    <input
                      type="text"
                      class="wk-input wk-flex-input"
                      placeholder="Goal ID로 지급 상태 조회 (GET /api/v1/dashboard/goals/candle)…"
                      value=${h}
                      disabled=${k!==null}
                      onInput=${e=>{b.current?.abort(),R(e.target.value),f(null),p(!1),v(null)}}
                      aria-label="Goal Candle 조회 ID"
                    />
                    <button
                      type="button"
                      class="btn-ghost"
                      style=${{minWidth:"112px"}}
                      disabled=${O||k!==null||!h.trim()}
                      onClick=${()=>{r(h)}}
                    >
                      ${O?"조회 중…":"Goal 지급 관측"}
                    </button>
                  </div>
                `:ee?s`
                    <div class="wk-notice wk-notice--info" data-testid="candle-goal-admin-locked" role="status">
                      Goal별 Candle 지급 진단 및 보류 해제는 관리자(토큰 인증) 세션 전용입니다.
                    </div>
                  `:s`
                    <div class="wk-notice wk-notice--info" data-testid="candle-goal-mode-notice" role="status">
                      Goal별 Candle 지급 진단 및 보류 해제는 싱글유저 로컬 세션 전용입니다.
                    </div>
                  `}

            ${G&&s`<div class="wk-notice wk-notice--err" role="alert">${G}</div>`}
            ${t&&s`
              <pre class="wk-code-preview">${JSON.stringify(t.data,null,2)}</pre>
            `}

            ${t&&U&&V&&(ae?s`
                  <${Y}
                    target=${{workspaceId:t.workspaceId,keeper:"—",requestId:U,revision:V}}
                    lockedEpoch=${t.epoch}
                    onRefresh=${()=>{r(t.goalId)}}
                  >
                    <p>Goal <code>${t.goalId}</code> · Candle 지급 보류 중</p>
                    <button
                      type="button"
                      class="wk-btn-warn"
                      style=${{minWidth:"108px"}}
                      disabled=${k!==null}
                      onClick=${()=>{ie(t,U,V)}}
                    >
                      ${k?"해제 중…":"Hold Release"}
                    </button>
                  </${Y}>
                `:s`
                  <div class="wk-notice wk-notice--info" data-testid="candle-hold-admin-locked" role="status">
                    Candle 지급 보류 해제는 관리자 전용입니다.
                  </div>
                `)}

            ${a.diagnostics.items.length===0?s`<span class="dtable-absent">현재 진단 경고가 없습니다.</span>`:s`
                  <div class="wk-stack-2">
                    ${a.diagnostics.items.map(e=>s`
                      <div key=${`${e.goalId}-${e.kind}-${e.atUnix}`} class="wk-diag-row">
                        <div class="wk-diag-main">
                          <div class="wk-diag-title">
                            <span class=${`wk-badge ${e.kind==="candidate_window_held"?"wk-badge--warn":"wk-badge--err"}`}>
                              ${e.kind}
                            </span>
                            <strong>${e.title??e.goalId}</strong>
                            <span class="mono wk-sub-id">${e.goalId}</span>
                          </div>
                          <div class="wk-diag-hint">
                            ${e.diagnosticHint||e.observation}
                          </div>
                        </div>
                        ${u&&s`
                          <div class="wk-actions">
                            <button
                              type="button"
                              class="btn-ghost"
                              disabled=${k!==null}
                              onClick=${()=>{R(e.goalId),r(e.goalId)}}
                            >
                              ${e.kind==="candidate_window_held"?"보류 확인":"관측"}
                            </button>
                          </div>
                        `}
                      </div>
                    `)}
                  </div>
                `}
          </div>
        </details>
      `}
    </div>
  `}export{qe as CandleTab};
