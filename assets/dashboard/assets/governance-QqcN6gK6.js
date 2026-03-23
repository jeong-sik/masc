import{m as n,B as K,D as O,F as N,G as $,H as z,I as J,J as Y,K as H,C as h,E as v,T as w,A as Q}from"./index-BB0zaaHQ.js";import{c as l,y as U}from"./vendor-Chwn_OlE.js";import{F as V}from"./filter-chips-Cu5kYIK3.js";import{g as G,T as W}from"./input-DWPrIiMN.js";import{L as X}from"./feedback-state-DiW1_ueY.js";function y({label:e,value:t,hint:a,tone:s,class:r}){return n`
    <div class="flex flex-col gap-1 p-3 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] ${r??""}">
      <span class="text-[10px] text-[var(--text-muted)] uppercase tracking-[0.06em] font-medium">${e}</span>
      <span class="text-[20px] font-semibold tabular-nums leading-none ${s??"text-[var(--text-strong)]"}">${t}</span>
      ${a?n`<span class="text-[11px] text-[var(--text-dim)] mt-0.5">${a}</span>`:null}
    </div>
  `}function k(e){return`${e.kind}:${e.id}`}function L(e,t){return e?t.find(a=>k(a)===e)??null:null}function Z(e){const t=e.trim().toLowerCase();return t!=="executed"&&t!=="blocked"&&t!=="closed"}function M(e,t){switch(e){case"pending_ruling":return t.filter(a=>a.status==="pending_ruling");case"needs_human_gate":return t.filter(a=>a.status==="needs_human_gate");case"executed":return t.filter(a=>a.status==="executed");case"blocked":return t.filter(a=>a.status==="blocked"||a.status==="closed");case"open":default:return t.filter(a=>Z(a.status))}}function ee(e){if(e==null)return"없음";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function T(e){switch((e??"").trim().toLowerCase()){case"pending":case"pending_ruling":return"판정 대기";case"ready_auto_execute":return"자동집행 준비";case"needs_human_gate":return"승인 대기";case"executed":return"집행 완료";case"blocked":return"보류";case"closed":return"종결";default:return(e==null?void 0:e.trim())||"확인 필요"}}function R(e){switch((e??"").trim().toLowerCase()){case"queued_auto":return"자동 대기";case"needs_human_gate":return"승인 대기";case"auto_executed":return"자동 집행됨";case"done":return"완료";case"denied":return"거부됨";case"blocked":return"보류";case"none":return"없음";default:return(e==null?void 0:e.trim())||"없음"}}function j(e){switch(e){case"support":return"찬성";case"oppose":return"반대";case"neutral":return"중립";default:return e}}function te(e){switch(e){case"case":return"사건";case"petition":return"청원";default:return e}}function ae(e){switch(e){case"petition_submitted":return"청원 접수";case"brief_submitted":return"의견 제출";case"ruling_issued":return"판정 발행";case"execution_order":return"집행 명령";default:return e}}function ne(e){return typeof e!="number"||Number.isNaN(e)?"판정 대기":`${Math.round(e*100)}%`}function P(e){return e==null?null:e<3600?`${Math.floor(e/60)}분`:e<86400?`${Math.floor(e/3600)}시간`:`${Math.floor(e/86400)}일`}const S=l(!1),b=l(!1),g=l(!1),E=l(!1),i=l(""),m=l(""),_=l(""),D=l("support"),B=l("open"),x=l(null),p=l(null),C=l(null),A=l(!1),se=l([]),re=l([]),I=l(!1);async function q(e){if(C.value=null,!!e){A.value=!0,i.value="";try{C.value=await O(e.id)}catch(t){i.value=t instanceof Error?t.message:"거버넌스 상세를 불러오지 못했습니다"}finally{A.value=!1}}}async function oe(e){p.value=k(e),await q(e)}async function f(){S.value=!0,i.value="";try{const e=await K();x.value=e;const t=M(B.value,e.items??[]),a=p.value,s=t.find(r=>k(r)===a)??t[0]??null;p.value=s?k(s):null,await q(s)}catch(e){i.value=e instanceof Error?e.message:"거버넌스 상태를 불러오지 못했습니다"}finally{S.value=!1}}H(f);async function F(){const e=m.value.trim();if(e){b.value=!0;try{const t=await J(e);m.value="",$(t!=null&&t.case.id?`청원을 접수했습니다: ${t.case.id}`:"청원을 접수했습니다","success"),await f()}catch(t){const a=t instanceof Error?t.message:"청원 접수에 실패했습니다";i.value=a,$(a,"error")}finally{b.value=!1}}}async function le(){var s;const e=((s=x.value)==null?void 0:s.items)??[],t=L(p.value,e),a=_.value.trim();if(!(!t||!a)){E.value=!0;try{const r=await N(t.id,D.value,a);_.value="",C.value=r,$("심의 의견을 기록했습니다","success"),await f()}catch(r){const o=r instanceof Error?r.message:"심의 기록에 실패했습니다";i.value=o,$(o,"error")}finally{E.value=!1}}}async function ce(e){var s;const t=((s=x.value)==null?void 0:s.items)??[],a=L(p.value,t);if(a){g.value=!0;try{await z(a.id,e),$(e==="confirm"?"집행을 승인했습니다":"집행을 거부했습니다","success"),await f()}catch(r){const o=r instanceof Error?r.message:"집행 결정을 처리하지 못했습니다";i.value=o,$(o,"error")}finally{g.value=!1}}}async function Se(){I.value=!0;try{const e=await Y();se.value=e.parameters??[],re.value=e.surfaces??[]}catch{}finally{I.value=!1}}function de(){var a;const e=(((a=x.value)==null?void 0:a.activity)??[]).slice(0,20),t=new Map;for(const s of e){const r=s.item_id||s.topic||"unknown",o=t.get(r);o?o.events.push(s):t.set(r,{topic:s.topic||r,events:[s]})}return n`
    <${h} title="활동 타임라인" class="section mb-4">
      <div class="flex flex-col gap-2">
        ${t.size===0?n`<${v} message="거버넌스 활동이 아직 없습니다." compact />`:Array.from(t.entries()).map(([,s])=>n`
              <div class="governance-case-group rounded-lg">
                <div class="flex items-center justify-between mb-2 gap-2">
                  <span class="governance-case-topic">${s.topic}</span>
                  <${pe} events=${s.events} />
                </div>
                <div class="governance-case-events">
                  ${s.events.map(r=>n`
                    <div class="governance-activity-row">
                      <span class="governance-badge rounded-full ${G(r.kind)}">${ae(r.kind)}</span>
                      <span class="governance-event-summary">${r.summary||""}</span>
                      ${r.created_at?n`<span class="governance-event-time"><${w} timestamp=${r.created_at} /></span>`:null}
                    </div>
                  `)}
                </div>
              </div>
            `)}
      </div>
    <//>
  `}const ie={petition_submitted:0,brief_submitted:1,ruling_issued:2,execution_order:3},ue=["청원","의견","판정","집행"];function pe({events:e}){const t=new Set(e.map(s=>ie[s.kind]??-1)),a=Math.max(...Array.from(t),-1);return n`
    <div class="flex items-center gap-0.5 shrink-0">
      ${ue.map((s,r)=>{const o=t.has(r),c=o?r===a?"lifecycle-current":"lifecycle-done":"lifecycle-pending";return n`
          ${r>0?n`<span class="lifecycle-arrow ${o?"done":""}">-></span>`:null}
          <span class="lifecycle-step ${c}">${s}</span>
        `})}
    </div>
  `}function xe({petition:e}){return n`
    <div class="governance-ledger-row">
      <div class="flex flex-wrap items-center gap-2 text-[#9ab3de] text-[11px]">
        <span class="governance-badge rounded-full text-[#b7cbee]">청원</span>
        <strong>${e.created_by||e.origin||"system"}</strong>
        ${e.created_at?n`<span><${w} timestamp=${e.created_at} /></span>`:null}
      </div>
      <div class="mt-2 text-[#d7e7ff] leading-[1.5] break-words">${e.title}</div>
      <div class="governance-chip rounded-full-row">
        ${e.source_refs.map(t=>n`<span class="governance-chip rounded-full">${t}</span>`)}
      </div>
    </div>
  `}function ve({brief:e}){return n`
    <div class="governance-ledger-row">
      <div class="flex flex-wrap items-center gap-2 text-[#9ab3de] text-[11px]">
        <span class="governance-badge rounded-full ${G(e.stance)}">${j(e.stance)}</span>
        <strong>${e.author}</strong>
        ${e.created_at?n`<span><${w} timestamp=${e.created_at} /></span>`:null}
      </div>
      <div class="mt-2 text-[#d7e7ff] leading-[1.5] break-words">${e.summary}</div>
      <div class="governance-chip rounded-full-row">
        ${e.evidence_refs.map(t=>n`<span class="governance-chip rounded-full">${t}</span>`)}
      </div>
    </div>
  `}function fe(){var o,d;const e=((o=x.value)==null?void 0:o.items)??[],t=L(p.value,e),a=C.value,s=(a==null?void 0:a.petitions)??[],r=(a==null?void 0:a.case.briefs)??[];return n`
    <${h}
      title=${t?"사건 상세":"거버넌스 상세"}
      class="section mb-4"
     
    >
      ${A.value?n`<${X}>거버넌스 상세 불러오는 중...<//>`:!t||!a?n`<${v} message="왼쪽 수신함에서 사건을 선택하면 청원, 심의, 판정, 집행 기록이 여기에 표시됩니다." compact />`:n`
              <div class="flex justify-between items-start gap-4 mb-4">
                <div>
                  <h3>${a.case.title}</h3>
                  <div class="mt-1 flex flex-wrap gap-2 text-[#8ea9d6] text-[11px]">
                    <span>${a.case.id}</span>
                    <span>${T(a.case.status)}</span>
                    ${a.case.updated_at?n`<span><${w} timestamp=${a.case.updated_at} /></span>`:null}
                  </div>
                </div>
                <div class="grid grid-cols-[repeat(2,minmax(90px,1fr))] gap-2">
                  <span class="border border-[var(--card-border)] rounded-[10px] py-2 px-2.5 bg-[var(--white-4)] text-[#c8daf7] text-[13px]"><strong>${s.length}</strong>건 청원</span>
                  <span class="border border-[var(--card-border)] rounded-[10px] py-2 px-2.5 bg-[var(--white-4)] text-[#c8daf7] text-[13px]"><strong>${r.length}</strong>건 의견</span>
                  <span class="border border-[var(--card-border)] rounded-[10px] py-2 px-2.5 bg-[var(--white-4)] text-[#c8daf7] text-[13px]"><strong>${t.confidence!=null?Math.round(t.confidence*100):0}</strong>% 확신도</span>
                  <span class="border border-[var(--card-border)] rounded-[10px] py-2 px-2.5 bg-[var(--white-4)] text-[#c8daf7] text-[13px]"><strong>${R((d=a.execution_order)==null?void 0:d.status)}</strong></span>
                </div>
              </div>
              <div class="flex flex-col gap-3">
                ${s.length===0?n`<${v} message="기록된 청원이 없습니다." compact />`:s.map(c=>n`<${xe} key=${c.id} petition=${c} />`)}
              </div>
              <div class="flex flex-col gap-3">
                ${r.length===0?n`<${v} message="심의 의견이 아직 없습니다." compact />`:r.map(c=>n`<${ve} key=${c.id} brief=${c} />`)}
              </div>
              <${de} />
            `}
    <//>
  `}function be({submitBrief:e,respondToExecutionOrder:t}){var c;const a=((c=x.value)==null?void 0:c.items)??[],s=L(p.value,a),r=C.value,o=r==null?void 0:r.ruling,d=r==null?void 0:r.execution_order;return n`
    <div class="flex flex-col gap-6">
      <${h} title="판정 / 집행" class="section mb-2">
        ${!s||!r?n`<${v} message="사건을 고르면 판정과 집행 경로가 보입니다." compact />`:n`
              <div class="flex flex-col gap-3">
                <h4 class="text-[11px] font-bold uppercase tracking-widest text-accent mb-1 flex items-center gap-2">
                  <span class="w-1.5 h-1.5 rounded-full bg-accent/50 shadow-[0_0_8px_rgba(71,184,255,0.6)]"></span>
                  판정 요약
                </h4>
                <div class="flex flex-wrap gap-2.5 text-text-muted text-[11px] font-medium">
                  <span class="px-2 py-0.5 rounded-md bg-white/5 border border-white/10">${T((o==null?void 0:o.status)||"pending")}</span>
                  <span class="px-2 py-0.5 rounded-md bg-white/5 border border-white/10">${ne(o==null?void 0:o.confidence)}</span>
                  ${o!=null&&o.generated_at?n`<span class="px-2 py-0.5 rounded-md bg-white/5 border border-white/10"><${w} timestamp=${o.generated_at} /></span>`:null}
                </div>
                ${o!=null&&o.summary?n`<div class="mt-2 mb-4 border border-accent/20 rounded-xl bg-accent/10 text-text-strong p-4 leading-relaxed text-[13px] shadow-sm">${o.summary}</div>`:n`<div class="mt-2 text-text-muted text-[13px] italic bg-card/40 p-4 rounded-xl border border-card-border/50 text-center">아직 판정이 생성되지 않았습니다.</div>`}
                <div class="flex gap-2 flex-wrap mb-2">
                  ${s.provenance?n`<span class="inline-flex items-center px-2 py-1 rounded-lg text-[10px] font-medium border border-white/10 bg-white/5 text-text-muted shadow-sm">${s.provenance}</span>`:null}
                  ${s.risk_class?n`<span class="inline-flex items-center px-2 py-1 rounded-lg text-[10px] font-medium border border-bad/20 bg-bad/10 text-bad shadow-sm">${s.risk_class}</span>`:null}
                  ${s.subject_type?n`<span class="inline-flex items-center px-2 py-1 rounded-lg text-[10px] font-medium border border-white/10 bg-white/5 text-text-dim shadow-sm">${s.subject_type}</span>`:null}
                </div>
              </div>
              
              <div class="mt-4 pt-4 border-t border-card-border/50">
                <${ge} order=${d} />
              </div>
              
              ${(d==null?void 0:d.status)==="needs_human_gate"?n`
                    <div class="flex flex-col gap-3 mt-5 p-5 border border-warn/30 bg-warn/10 rounded-xl shadow-inner">
                      <h4 class="text-[12px] font-bold text-warn uppercase tracking-wider">⚠️ 관리자 승인 대기</h4>
                      <div class="text-text-strong text-[13px] leading-relaxed">이 집행 명령은 고위험 작업으로 분류되어 승인이 필요합니다.</div>
                      <div class="flex gap-3 mt-2">
                        <button class="px-5 py-2.5 rounded-xl text-[13px] font-semibold transition-all duration-200 shadow-sm shadow-black/20 disabled:opacity-50 border border-ok/30 bg-ok/20 text-ok hover:bg-ok/30" onClick=${()=>t("confirm")} disabled=${g.value}>
                          ${g.value?"처리 중...":"명령 승인"}
                        </button>
                        <button class="px-5 py-2.5 rounded-xl text-[13px] font-semibold transition-all duration-200 shadow-sm shadow-black/20 disabled:opacity-50 border border-bad/30 bg-bad/20 text-bad hover:bg-bad/30" onClick=${()=>t("deny")} disabled=${g.value}>
                          ${g.value?"처리 중...":"집행 거부"}
                        </button>
                      </div>
                    </div>
                  `:null}
            `}
      <//>
      
      <${h} title="심의 의견 제출" class="section mb-4">
        ${s?n`
              <div class="flex flex-col gap-4">
                <div class="flex flex-wrap gap-2 p-1.5 bg-card/40 backdrop-blur-md rounded-xl border border-card-border/50 w-fit">
                  ${["support","oppose","neutral"].map(u=>n`
                    <button
                      class="px-4 py-2 rounded-lg text-[12px] font-bold transition-all duration-200 border cursor-pointer
                        ${D.value===u?"bg-accent/20 text-accent border-accent/30 shadow-sm":"bg-transparent text-text-muted border-transparent hover:bg-white/5 hover:text-text-body"}"
                      onClick=${()=>{D.value=u}}
                    >
                      ${j(u)}
                    </button>
                  `)}
                </div>
                <${W}
                  rows=${5}
                  placeholder="이 사건에 대한 심의 의견을 입력하세요..."
                  value=${_.value}
                  onInput=${u=>{_.value=u.target.value}}
                />
                <div class="flex gap-2">
                  <${Q}
                    onClick=${e}
                    disabled=${E.value||_.value.trim()===""}
                  >
                    ${E.value?"기록 중...":"의견 추가"}
                  <//>
                </div>
              </div>
            `:n`<${v} message="사건을 선택한 뒤 의견을 추가하세요." compact />`}
      <//>
    </div>
  `}function ge({order:e}){if(!(e!=null&&e.action_request))return null;const t=e.action_request;return n`
    <div class="flex flex-col gap-2">
      <h4>집행 명령</h4>
      <div class="mt-1 flex flex-wrap gap-2 text-[#8ea9d6] text-[11px]">
        <span>${t.resolved_tool||t.action_kind||t.target_type||"action"}</span>
        <span>${R(e.status)}</span>
      </div>
      ${t.target_type?n`<div class="text-[#c8daf7] text-[13px] leading-[1.45]">대상 ${t.target_type}${t.target_id?`:${t.target_id}`:""}</div>`:null}
      ${t.reason?n`<div class="text-[#c8daf7] text-[13px] leading-[1.45]">${t.reason}</div>`:null}
      ${t.payload_preview?n`<pre class="whitespace-pre-wrap border border-[var(--card-border)] rounded-[9px] bg-[rgba(0,0,0,0.28)] text-[#d3e3ff] p-3 text-[13px] leading-[1.5] font-mono mt-0 text-[11px] max-h-[180px] overflow-auto">${ee(t.payload_preview)}</pre>`:null}
      ${e.execution_ref?n`<div class="text-[#c8daf7] text-[13px] leading-[1.45]">결과 참조 ${e.execution_ref}</div>`:null}
      ${e.result_summary?n`<div class="text-[#c8daf7] text-[13px] leading-[1.45]">${e.result_summary}</div>`:null}
    </div>
  `}function me(){var c,u;const e=x.value,t=e==null?void 0:e.summary,a=t==null?void 0:t.oldest_open_case_age_s,s=t==null?void 0:t.last_activity_age_s,r=a!=null&&a>86400||s!=null&&s>86400,o=((c=e==null?void 0:e.items)==null?void 0:c.length)??0,d=((u=e==null?void 0:e.activity)==null?void 0:u.length)??0;return n`
    ${r?n`
      <div class="mb-4 p-4 rounded-xl border border-warn/30 bg-warn/10 text-[13px] text-warn font-medium shadow-sm flex items-center gap-3">
        <span class="text-lg">⚠️</span>
        <div>
          모든 열린 케이스가 ${P(a)} 이상 경과됨.
          ${s!=null?n` 마지막 활동: ${P(s)} 전.`:null}
          <span class="opacity-80 ml-1">테스트 잔재일 가능성이 높습니다.</span>
        </div>
      </div>
    `:null}
    <div class="flex items-center justify-between mb-3 px-1">
      <div class="flex items-center gap-3">
        <h2 class="text-lg font-bold text-text-strong tracking-wide">Governance</h2>
        <span class="text-[11px] font-medium px-2.5 py-1 bg-white/5 rounded-md text-text-muted border border-white/5 shadow-inner">진행 중 ${o}건 / 활동 ${d}건</span>
      </div>
      ${e!=null&&e.generated_at?n`<span class="text-[11px] text-text-dim font-mono">${e.generated_at}</span>`:null}
    </div>
    <div class="grid grid-cols-[repeat(auto-fit,minmax(160px,1fr))] gap-4 mb-6">
      <${y} label="열린 케이스" value=${(t==null?void 0:t.cases_open)??o} />
      <${y} label="판정 대기" value=${(t==null?void 0:t.pending_ruling)??0} />
      <${y} label="자동집행 준비" value=${(t==null?void 0:t.ready_auto_execute)??0} />
      <${y} label="관리자 승인 대기" value=${(t==null?void 0:t.needs_human_gate)??0} />
      <${y} label="집행 완료" value=${(t==null?void 0:t.executed)??0} />
    </div>
  `}function $e(){return n`
    <div class="mb-6">
      <${h} title="청원 콘솔">
        <div class="flex flex-col gap-4 mt-2">
          <div class="grid grid-cols-[minmax(0,1fr)_auto_auto] gap-3 items-center">
            <input
              class="w-full py-2.5 px-4 rounded-xl bg-card/60 backdrop-blur-md border border-card-border text-text-strong text-[13px] font-sans placeholder:text-text-dim focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/50 transition-all duration-200 shadow-inner"
              type="text"
              placeholder="청원 제목을 입력하세요..."
              value=${m.value}
              onInput=${e=>{m.value=e.target.value}}
              onKeyDown=${e=>{e.key==="Enter"&&F()}}
              disabled=${b.value}
            />
            <button
              class="px-5 py-2.5 rounded-xl text-[13px] font-semibold border transition-all duration-200 cursor-pointer shadow-sm
                ${b.value||m.value.trim()===""?"bg-card/40 text-text-muted border-card-border opacity-50 cursor-not-allowed":"bg-accent/10 text-accent border-accent/20 hover:bg-accent/20 hover:shadow-md"}"
              onClick=${F}
              disabled=${b.value||m.value.trim()===""}
            >
              ${b.value?"접수 중...":"청원 접수"}
            </button>
            <button
              class="px-4 py-2.5 rounded-xl text-[13px] font-semibold border border-transparent bg-white/5 text-text-muted hover:bg-white/10 hover:text-text-strong transition-all duration-200 cursor-pointer shadow-sm disabled:opacity-50 disabled:cursor-not-allowed"
            onClick=${f}
            disabled=${S.value}
          >
            ${S.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
        <${V}
          chips=${[{key:"open",label:"진행 중"},{key:"pending_ruling",label:"판정 대기"},{key:"needs_human_gate",label:"승인 대기"},{key:"executed",label:"집행 완료"},{key:"blocked",label:"보류/종결"}]}
          active=${B}
          onChange=${()=>{f()}}
        />
        ${i.value?n`<div class="mt-2 p-2.5 rounded-lg border border-[rgba(239,68,68,0.35)] bg-[var(--bad-8)] text-[#f7b6b6] text-[12px]">${i.value}</div>`:null}
      </div>
    <//>
  `}function he(){var t;const e=M(B.value,((t=x.value)==null?void 0:t.items)??[]);return n`
    <${h} title="사건 수신함" class="section mb-6">
      <div class="flex flex-col gap-3 governance-inbox">
        ${e.length===0?n`<${v} message="이 필터에 해당하는 사건이 없습니다. 청원을 접수하거나 필터를 변경해 보세요." />`:e.map(a=>{const s=p.value===k(a);return n`
                <button
                  class="w-full text-left flex gap-4 p-5 rounded-2xl border cursor-pointer transition-all duration-200 shadow-sm shadow-black/10 group hover:-translate-y-0.5 hover:shadow-md
                    ${s?"border-accent/40 bg-accent/10 shadow-[0_0_15px_rgba(71,184,255,0.15)]":"border-card-border bg-card/40 backdrop-blur-md hover:border-accent/30 hover:bg-card/60"}"
                  onClick=${()=>oe(a)}
                >
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-3 min-w-0 mb-2">
                      <span class="inline-flex items-center px-2.5 py-1 rounded-lg text-[10px] font-bold bg-accent/10 text-accent border border-accent/20 shadow-sm">${te(a.kind)}</span>
                      <span class="text-[15px] font-bold text-text-strong break-words group-hover:text-accent transition-colors leading-tight tracking-wide">${a.topic}</span>
                    </div>
                    <div class="mt-2 flex flex-wrap gap-3 text-[12px] text-text-muted/90 font-medium">
                      <span class="leading-relaxed opacity-90">${a.truth_summary||"사실 요약이 아직 없습니다"}</span>
                      ${a.last_activity_at?n`<span class="text-text-dim flex items-center gap-1.5"><span class="w-1 h-1 rounded-full bg-text-dim/50"></span><${w} timestamp=${a.last_activity_at} /></span>`:null}
                    </div>
                    <div class="flex gap-2 flex-wrap mt-3.5">
                      ${a.origin?n`<span class="inline-flex items-center px-2 py-0.5 rounded-md text-[10px] font-medium border border-white/10 bg-white/5 text-text-muted shadow-sm">${a.origin}</span>`:null}
                      ${a.risk_class?n`<span class="inline-flex items-center px-2 py-0.5 rounded-md text-[10px] font-medium border border-bad/20 bg-bad/10 text-bad shadow-sm">${a.risk_class}</span>`:null}
                      ${a.provenance?n`<span class="inline-flex items-center px-2 py-0.5 rounded-md text-[10px] font-medium border border-white/10 bg-white/5 text-text-muted shadow-sm">${a.provenance}</span>`:null}
                      ${a.status==="needs_human_gate"?n`<span class="inline-flex items-center px-2 py-0.5 rounded-md text-[10px] font-bold border border-warn/30 bg-warn/20 text-warn shadow-sm animate-pulse">승인 대기</span>`:null}
                      ${a.status==="executed"?n`<span class="inline-flex items-center px-2 py-0.5 rounded-md text-[10px] font-bold border border-ok/30 bg-ok/10 text-ok shadow-sm">집행 완료</span>`:null}
                    </div>
                  </div>
                  <div class="flex flex-col items-end justify-between flex-shrink-0 pt-0.5">
                    <span class="inline-flex items-center px-3 py-1 rounded-full text-[11px] font-bold border shadow-sm ${G(a.status)}">${T(a.status)}</span>
                    <span class="text-[11px] font-medium text-text-dim px-2 py-1 bg-white/5 rounded-md border border-white/5 mt-auto">의견 ${a.brief_count??0}</span>
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function Ee(){return U(()=>{f()},[]),n`
    <div class="flex flex-col gap-1">
      <${me} />
      <${$e} />
      <div class="governance-layout">
        <${he} />
        <${fe} />
        <${be}
          submitBrief=${le}
          respondToExecutionOrder=${ce}
        />
      </div>
    </div>
  `}export{Ee as Governance,Se as loadRuntimeParams,f as refreshGovernance};
