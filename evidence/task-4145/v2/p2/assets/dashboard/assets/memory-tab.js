import{d as k,y as M,T,m as s}from"./vendor.js";import{M as q}from"./markdown-renderer.js";import{a as K,O as H,_ as Z,s as me,z as C,K as ve,X as be,F as ee,T as oe,A as $e,B as se,Q as fe,o as ge}from"./index.js";import{I as he}from"./inline-spinner.js";import{K as O}from"./core.js";import{D as te}from"./data-table.js";import{R as ye}from"./refresh-button.js";import{U as we}from"./uplot-chart.js";import{buildMemoryFlowSeries as Ce,formatBytes as Se,decodeWorldMemory as _e,decodeWorkspaceInventoryFallback as Ae,decodeWorldDiff as Me,buildWorldMemoryDiffUrl as We,buildMemoryRecoveryPayload as Re}from"./index2.js";import"./markdown.js";import"./type-guards.js";import"./table.js";import"./useSelector.js";import"./virtual-list.js";import"./lazy-component.js";import"./attachment-gallery.js";import"./copyable-code.js";import"./toast.js";import"./master-detail.js";const Ie=[{label:"Added ▲",colorToken:"--ok-fg",width:1.75,fillAlpha:.14},{label:"Retracted ▼",colorToken:"--err-fg",width:1.75,fillAlpha:.12},{label:"Net Total",colorToken:"--info-fg",width:2}],ie="kn:memory:world",re=["memory","world_memory","librarian"];function le(l){return`kn:memory:diff:${l}`}function ae(l){return C.fetch(ie,async m=>{const r=await oe("/api/v1/memory/world",{signal:m,decode:n=>{const i=_e(n);if(!i.ok)throw new Error(i.error);return i.value}});return r.ok||r.error.kind!=="not_found"&&r.error.status!==404||K.peek().kind!=="single_user_local"?r:$e("/api/v1/dashboard/workspace-memory-inventory",{signal:m,decode:n=>{const i=Ae(n);if(!i.ok)throw new Error(i.error);return i.value}})},{ttlMs:12e3,topics:re,reason:l})}function ne(l,m){return C.fetch(le(l),r=>oe(We(l),{signal:r,decode:n=>{const i=Me(n);if(!i.ok)throw new Error(i.error);if(i.value.window!==l)throw new Error(`서버가 ${l} 기간에 해당하는 Diff를 반환하지 않았습니다.`);return i.value}}),{ttlMs:12e3,topics:re,reason:m})}function De(l,m){if(typeof l=="string"){const r=l.trim();return r?r.slice(0,96):`항목 #${m+1}`}if(l!==null&&typeof l=="object"&&!Array.isArray(l)){const r=l,n=[];for(const i of["claim","summary","title","claim_id","id","path","keeper","category"]){const c=r[i];if(typeof c=="string"&&c.trim()&&(n.push(c.trim()),n.length>=2))break}if(n.length>0)return n.join(" · ").slice(0,120)}return`항목 #${m+1}`}function qe(l){const m=K.value,r=m.kind==="single_user_local"&&!H("admin",m),n=Z.value,i=me.value,c=C.observe(ie).value,d=C.observe(le(n)).value,t=c.kind==="value"?c.data:null,o=d.kind==="value"?d.data:null,[ce,S]=k("claims"),v=t===null?"diff":ce,[$,W]=k("added"),[_,A]=k(null),[b,x]=k("adopt"),[B,E]=k(""),[F,N]=k(""),[P,V]=k("0"),[R,z]=k(""),[U,j]=k("0"),[J,Y]=k("0"),[h,I]=k(null),[D,y]=k(null);M(()=>{ae("mount"),I(null),y(null),A(null)},[i]),M(()=>{ne(n,"mount")},[n,i]),M(()=>{c.kind==="value"&&!c.stale&&d.kind==="value"&&!d.stale&&ve()},[c,d]),M(()=>{r||A(null)},[r]);const G=()=>Promise.all([ae("manual"),ne(Z.peek(),"manual")]),L=async(e,a,p)=>{const f=K.peek();if(f.kind!=="single_user_local"||H("admin",f)||!se(i))return;const u=Re({action:a,observed:p?.observed??B,turnLog:p?.turnLog??F,line:p?.line??Number(P),store:p?.store??R,at:p?.at??(R.trim()?Number(U):void 0),offset:p?.offset??Number(J)});if(!u.ok){y({kind:"err",message:u.error});return}I(`${e}:${a}`),y(null);const g=await fe("POST",`/api/v1/keepers/${encodeURIComponent(e)}/memory/act`,u.value);if(!se(i))return;if(I(null),!g.ok){const X=g.error.status===409;y({kind:X?"warn":"err",message:`${e} (${a}) ${X?"거부됨":"실패"}: ${g.error.message}`});return}const ke=typeof g.value=="string"?g.value:JSON.stringify(g.value);y(null),ge(`${e} → ${a}: ${ke}`,"success"),C.invalidateTopic("memory"),await G()},de=T(()=>{if(!o)return[[],[],[],[]];const e=Ce(o);return[e.timestamps,e.added,e.retracted,e.netTotal]},[o]),pe=T(()=>[{id:"claim",header:"Claim",sortable:!0,sortValue:e=>e.claim,cell:e=>s`
        <div class="kn-stack-1">
          <span>${e.claim}</span>
          <span class="mono kn-sub-id">
            ${e.claimId}${e.category?` · ${e.category}`:""}${e.scope?` · ${e.scope}`:""}
          </span>
        </div>
      `},{id:"stage",header:"Stage",sortable:!0,accessor:e=>e.stage,cell:e=>s`<span class="kn-badge">${e.stage}</span>`},{id:"supportCount",header:"Support",numeric:!0,sortable:!0,sortValue:e=>e.supportCount,observed:e=>be(e.supportCount)},{id:"sourceBound",header:"근거 유형",cell:e=>e.hasSourceBound?s`<span class="kn-badge kn-badge--ok">Source-Bound</span>`:s`<span class="kn-badge kn-badge--idle">Ordinary</span>`},{id:"keepers",header:"지지 Keeper",cell:e=>e.supportingKeepers.length===0?s`<span class="dtable-absent">없음</span>`:s`
            <div class="kn-chips">
              ${e.supportingKeepers.slice(0,4).map(a=>s`<${O} key=${a} id=${a} size="sm" />`)}
              ${e.supportingKeepers.length>4&&s`<span class="kn-chip-count">+${e.supportingKeepers.length-4}</span>`}
            </div>
          `}],[]),ue=T(()=>[{id:"keeper",header:"Keeper",sortable:!0,sortValue:e=>e.keeper,cell:e=>s`<${O} id=${e.keeper} portrait=${!0} size="sm" />`},{id:"state",header:"Writer State",sortable:!0,accessor:e=>e.state,cell:e=>{const a=e.state==="open"||e.state==="idle"?"ok":e.state==="stopped"||e.state==="refused_at_bottom"?"err":"warn";return s`
          <span class=${`kn-badge kn-badge--${a}`}>
            ${e.state}${e.stopReason?` (${e.stopReason})`:""}
          </span>
        `}},{id:"snapshot",header:"Snapshot File",cell:e=>e.snapshotFault?s`<span class="kn-badge kn-badge--err">Fault: ${e.snapshotFault}</span>`:e.snapshotSha?s`<span class="mono kn-sub-id">${e.snapshotSha.slice(0,12)}… (${Se(e.snapshotBytes)})</span>`:s`<span class="dtable-absent">없음</span>`},{id:"recovery",header:"Recovery Acts",cell:e=>r?s`
            <div class="kn-actions">
              <button
                type="button"
                class="btn-ghost kn-btn-compact"
                disabled=${h!==null}
                onClick=${()=>{L(e.keeper,"resume")}}
              >
                resume
              </button>
              ${e.snapshotSha&&s`
                <button
                  type="button"
                  class="kn-btn-warn kn-btn-compact"
                  disabled=${h!==null}
                  onClick=${()=>{L(e.keeper,"adopt",{observed:e.snapshotSha})}}
                >
                  adopt
                </button>
              `}
              <button
                type="button"
                class="btn-ghost kn-btn-compact"
                onClick=${()=>{A(e.keeper),x(e.snapshotSha?"adopt":"restart_reading"),E(e.snapshotSha??""),N(""),V("0"),z(""),j("0"),Y("0")}}
              >
                고급 복구…
              </button>
            </div>
          `:s`<span class="dtable-absent" data-testid="memory-recovery-admin-locked">싱글유저 관리자 전용</span>`}],[h,i,r]),Q=o?$==="added"?o.added:$==="updated"?o.updated:o.retracted:[],w=(()=>{const e=c.kind==="loading",a=d.kind==="loading",p=c.kind==="value"&&c.stale,f=d.kind==="value"&&d.stale,u=[];return e&&a?u.push("World Memory · Diff 불러오는 중…"):e?u.push("World Memory 불러오는 중…"):a&&u.push(`${n} 메모리 Diff 불러오는 중…`),p&&f?u.push("마지막 조회"):p?u.push("World Memory · 마지막 조회"):f&&u.push(`${n} Diff · 마지막 조회`),u.length===0?null:{tone:p||f?"warn":"info",loading:e||a,text:u.join(" · ")}})();return s`
    <div class="kn-scroll-body">
      <div class="kn-toolbar">
        <div class="kn-chips">
          ${t&&s`<span class="kn-badge kn-badge--info">
            ${t.sourceKind==="world_memory_db"?"MVCC World DB":t.sourceKind==="workspace_inventory_fallback"?"Legacy Inventory Fallback":"Legacy Ledger"}
          </span>`}
          ${t?.ledgerSha256&&s`
            <span class="mono kn-sub-id">
              sha256:${t.ledgerSha256.slice(0,12)}
            </span>
          `}
        </div>
        <div class="kn-toolbar-status-slot">
          ${w&&s`
            <span class=${`kn-status-pill kn-status-pill--${w.tone}`} role="status" title=${w.text}>
              ${w.loading&&s`<${he} size="xs" />`}
              <span class="kn-status-pill-text">${w.text}</span>
            </span>
          `}
        </div>
        <div class="kn-actions">
          <${ye} onRefresh=${G} />
        </div>
      </div>

      ${c.kind==="failed"&&s`<div class="kn-notice kn-notice--err" role="alert">World Memory 조회 실패. ${c.error.message}</div>`}
      ${(c.kind==="absent"||c.kind==="unreported")&&s`<p role="status">서버에서 World Memory를 확인할 수 없습니다.</p>`}

      ${d.kind==="failed"&&s`<div class="kn-notice kn-notice--err" role="alert">${n} 메모리 Diff 조회 실패. ${d.error.message}</div>`}
      ${(d.kind==="absent"||d.kind==="unreported")&&s`<p role="status">서버에서 ${n} 메모리 Diff를 확인할 수 없습니다.</p>`}

      ${(t||o)&&s`
        <div class="ov-kpis">
          ${t&&s`
            <div class="ov-kpi">
              <div class="ov-kpi-k">Claims</div>
              <div class="ov-kpi-v">${t.ledgerState==="missing"?"없음":String(t.claimsCount)}</div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">Facts</div>
              <div class="ov-kpi-v">${t.ledgerState==="missing"?"없음":String(t.factsCount)}</div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">Active Conflicts</div>
              <div class=${`ov-kpi-v ${t.conflictsCount>0?"warn":"ok"}`}>${String(t.conflictsCount)}</div>
            </div>
          `}
          <div class="ov-kpi">
            <div class="ov-kpi-k">Window Diff (${n})</div>
            <div class="ov-kpi-v kn-kpi-compact">
              ${ee(d,e=>`+${e.counts.added} / ~${e.counts.updated} / -${e.counts.retracted}`)}
            </div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">Retrieval Heat (H/W/C/0x)</div>
            <div class="ov-kpi-v kn-kpi-compact">
              ${ee(d,({retrievalHeat:e})=>`${e.hot}/${e.warm}/${e.cold}/${e.neverRetrieved}`)}
            </div>
          </div>
          ${t?.worldMvcc&&s`
            <div class="ov-kpi">
              <div class="ov-kpi-k">MVCC Rev / Edges</div>
              <div class="ov-kpi-v kn-kpi-compact">
                r${t.worldMvcc.digestRevision??"없음"} · ${t.worldMvcc.edgesCount}
              </div>
            </div>
          `}
        </div>
      `}

      ${o&&s`<${we}
          id="world-memory-flow"
          title=${`Memory Flow (Added ▲ / Retracted ▼ vs Net Total · ${n})`}
          subtitle=${s`<span class="mono kn-sub-id">scope=world · window=${n}</span>`}
          data=${de}
          series=${Ie}
          height=${210}
          emptyLabel="선택한 기간 내 메모리 변동 틱이 없습니다."
      />`}

      ${t&&s`
        <section class="kn-section" aria-label="World Briefing">
          <div class="kn-section-head">
            <h3 class="kn-section-title">World Briefing</h3>
            <div class="kn-chips">
              <span class=${`kn-badge ${t.briefing.status==="current"?"kn-badge--ok":t.briefing.status==="stale"?"kn-badge--warn":"kn-badge--idle"}`}>
                ${t.briefing.status}
              </span>
              <span class="kn-badge">Sources: ${t.briefing.sourceIdsCount}</span>
              ${t.briefing.buildingTarget!==null&&s`
                <span class="kn-badge kn-badge--info">
                  ${t.briefing.buildingRemaining===null?"브리핑 생성 중":`브리핑 생성 중 · ${t.briefing.buildingTarget-t.briefing.buildingRemaining}/${t.briefing.buildingTarget}`}
                </span>
              `}
            </div>
          </div>
          ${t.briefing.error&&s`<div class="kn-notice kn-notice--err">${t.briefing.error}</div>`}
          ${t.briefing.text?s`<${q} class="kn-body-md" text=${t.briefing.text} />`:s`<span class="dtable-absent">World Briefing 본문이 아직 생성되지 않았습니다.</span>`}
        </section>
      `}

      ${(t||o)&&s`
        <div class="kn-chips" role="tablist" aria-label="World Memory 상세 섹션">
          ${t&&s`
            <button type="button" role="tab" class="kn-chip" aria-selected=${v==="claims"} onClick=${()=>S("claims")}>
              Claims <span class="kn-chip-count">${t.claims.length}</span>
            </button>
            <button type="button" role="tab" class="kn-chip" aria-selected=${v==="conflicts"} onClick=${()=>S("conflicts")}>
              Active Conflicts <span class="kn-chip-count">${t.activeConflicts.length}</span>
            </button>
          `}
          <button type="button" role="tab" class="kn-chip" aria-selected=${v==="diff"} onClick=${()=>S("diff")}>
            Temporal Diff (${n})
          </button>
          ${t&&s`<button type="button" role="tab" class="kn-chip" aria-selected=${v==="writers"} onClick=${()=>S("writers")}>
            Librarian Writers <span class="kn-chip-count">${t.writers.length}</span>
          </button>`}
        </div>

        ${t&&v==="claims"&&s`
          <${te}
            data=${t.claims}
            columns=${pe}
            getRowId=${e=>e.claimId}
            caption="World Memory Claims 목록"
            emptyLabel="기록된 World Claim이 없습니다."
          />
        `}

        ${t&&v==="conflicts"&&s`
          <div class="kn-stack-2" role="region" aria-label="Side-by-Side Active Conflicts Inspector">
            <div class="kn-notice kn-notice--info" role="note">
              읽기 전용 충돌 검사기 (Read-Only): 현재 서버에는 World Memory 충돌 해소 쓰기 API가 노출되어 있지 않습니다. 허위 해소 버튼을 제공하지 않으며, 각 Keeper의 원천 사실과 경합 주장을 나란히 비교할 수 있습니다.
            </div>
            ${t.activeConflicts.length===0?s`<div class="kn-section"><span class="dtable-absent">활성 메모리 충돌이 없습니다 (0).</span></div>`:t.activeConflicts.map(e=>s`
                  <section key=${e.conflictId} class="kn-section">
                    <div class="kn-section-head">
                      <strong>${e.description||e.conflictId}</strong>
                      <span class="kn-badge kn-badge--warn">경합 주장 ${e.memberCount}건</span>
                    </div>
                    <div class="kn-conflict-grid">
                      ${e.competingClaims.map((a,p)=>s`
                        <article key=${`${a.keeperId}-${a.claimSha256}-${p}`} class="kn-conflict-card">
                          <div class="kn-row-top">
                            <${O} id=${a.keeperId} size="sm" />
                            <span class="kn-badge">${a.storeKind}</span>
                          </div>
                          <${q} class="kn-body-md" text=${a.claim??"(원문 미해석)"} />
                          <div class="kn-row-meta mono">
                            <span>sha:${a.claimSha256.slice(0,10)}</span>
                            ${a.path&&s`<span>${a.path}</span>`}
                            ${a.resolved&&s`<span class="kn-badge kn-badge--ok">resolved</span>`}
                          </div>
                        </article>
                      `)}
                    </div>
                  </section>
                `)}
          </div>
        `}

        ${v==="diff"&&s`
          <section class="kn-section" aria-label="Temporal Memory Diff">
            <div class="kn-toolbar">
              <div class="kn-chips" role="group" aria-label="Diff 유형">
                <button type="button" class="kn-chip" aria-pressed=${$==="added"} onClick=${()=>W("added")}>
                  Added <span class="kn-chip-count">${o?o.counts.added:"—"}</span>
                </button>
                <button type="button" class="kn-chip" aria-pressed=${$==="updated"} onClick=${()=>W("updated")}>
                  Updated <span class="kn-chip-count">${o?o.counts.updated:"—"}</span>
                </button>
                <button type="button" class="kn-chip" aria-pressed=${$==="retracted"} onClick=${()=>W("retracted")}>
                  Retracted <span class="kn-chip-count">${o?o.counts.retracted:"—"}</span>
                </button>
              </div>
              ${o&&(o.counts.incompleteBatches>0||o.counts.abortedBatches>0)&&s`
                <span class="kn-badge kn-badge--warn">
                  Incomplete: ${o.counts.incompleteBatches} · Aborted: ${o.counts.abortedBatches}
                </span>
              `}
            </div>
            ${o!==null&&(Q.length===0?s`<span class="dtable-absent">${n} 기간 내 ${$} 항목이 없습니다.</span>`:Q.map((e,a)=>s`
                  <details key=${a} class="ap-disclosure" data-testid="memory-diff-entry">
                    <summary class="ap-disclosure-trigger">
                      <span class="kn-diff-summary-text">${De(e,a)}</span>
                      <span class="mono kn-sub-id">JSON ▸</span>
                    </summary>
                    <div class="ap-disclosure-body">
                      <pre class="kn-diff-box">${JSON.stringify(e,null,2)}</pre>
                    </div>
                  </details>
                `))}
          </section>
        `}

        ${t&&v==="writers"&&s`
          <section class="kn-section" aria-label="Librarian Writers 상태 및 복구">
            <div class="kn-section-head">
              <h3 class="kn-section-title">Librarian Writers Status & 1-Click Recovery Acts</h3>
              <div class="kn-chips">
                <span class=${`kn-badge ${t.writersMode==="running"?"kn-badge--ok":"kn-badge--idle"}`}>
                  ${t.writersMode}
                </span>
                <span class="kn-badge kn-badge--err">Errors: ${t.writersErrorCount}</span>
                <span class="kn-badge kn-badge--warn">Warns: ${t.writersWarnCount}</span>
              </div>
            </div>

            ${D&&s`
              <div class=${`kn-notice kn-notice--${D.kind}`} role="alert">${D.message}</div>
            `}

            <${te}
              data=${t.writers}
              columns=${ue}
              getRowId=${e=>e.keeper}
              caption="Librarian Writer 상태 및 복구 작업"
              emptyLabel="이 프로세스에서 실행 중인 Librarian Writer가 없습니다."
            />

            ${r&&_&&s`
              <form
                class="kn-section kn-recovery-box"
                onSubmit=${e=>{e.preventDefault(),L(_,b)}}
              >
                <div class="kn-section-head">
                  <strong>Recovery Act — ${_} (POST /api/v1/keepers/${_}/memory/act)</strong>
                  <button type="button" class="btn-ghost" onClick=${()=>A(null)}>닫기</button>
                </div>
                <div class="kn-grid-auto">
                  <select
                    class="kn-select"
                    value=${b}
                    onChange=${e=>x(e.target.value)}
                    aria-label="복구 액션 선택"
                  >
                    <option value="resume">resume</option>
                    <option value="adopt">adopt (snapshot sha256)</option>
                    <option value="restart_reading">restart_reading (turn_log id)</option>
                    <option value="skip_item">skip_item (target)</option>
                    <option value="skip_line">skip_line (byte offset)</option>
                  </select>

                  ${(b==="adopt"||b==="restart_reading")&&s`
                    <input
                      type="text"
                      class="kn-input mono"
                      placeholder=${b==="adopt"?"snapshot SHA-256":"turn_log Log_started ID"}
                      value=${B}
                      onInput=${e=>E(e.target.value)}
                      aria-label="observed 값"
                    />
                  `}

                  ${b==="skip_item"&&s`
                    <input
                      type="text"
                      class="kn-input mono"
                      placeholder="turn_log ID"
                      value=${F}
                      onInput=${e=>N(e.target.value)}
                      aria-label="turn_log ID"
                    />
                    <input
                      type="number"
                      min="0"
                      class="kn-input tnum"
                      placeholder="line offset"
                      value=${P}
                      onInput=${e=>V(e.target.value)}
                      aria-label="line offset"
                    />
                    <input
                      type="text"
                      class="kn-input mono"
                      placeholder="store (head_item일 때만)"
                      value=${R}
                      onInput=${e=>z(e.target.value)}
                      aria-label="store"
                    />
                    <input
                      type="number"
                      min="0"
                      class="kn-input tnum"
                      placeholder="at index (head_item일 때만)"
                      value=${U}
                      onInput=${e=>j(e.target.value)}
                      aria-label="at index"
                    />
                  `}

                  ${b==="skip_line"&&s`
                    <input
                      type="number"
                      min="0"
                      class="kn-input tnum"
                      placeholder="byte offset"
                      value=${J}
                      onInput=${e=>Y(e.target.value)}
                      aria-label="byte offset"
                    />
                  `}
                </div>
                <div class="kn-actions">
                  <button type="submit" class="kn-btn-warn" disabled=${h!==null}>
                    ${h?"실행 중…":`${b} 실행`}
                  </button>
                </div>
              </form>
            `}
          </section>
        `}
      `}
    </div>
  `}export{qe as MemoryTab};
