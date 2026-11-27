const __vite__mapDeps=(i,m=__vite__mapDeps,d=(m.f||(m.f=["assets/tasks-tab.js","assets/vendor.js","assets/markdown-renderer.js","assets/index.js","assets/markdown.js","assets/inline-spinner.js","assets/verification-coverage.js","assets/core.js","assets/type-guards.js","assets/master-detail.js","assets/refresh-button.js","assets/virtual-list.js","assets/table.js","assets/useSelector.js","assets/types.js","assets/keeper-state.js","assets/format-string.js","assets/index6.css","assets/markdown-renderer.css","assets/inbox-tab.js","assets/hitl-decoders.js","assets/dashboard-goals.js","assets/format-time.js","assets/data-table.js","assets/target-locked-action.js","assets/candle-tab.js","assets/uplot-chart.js"])))=>i.map(i=>d[i]);
import{Y as Jt,a as q,O as re,z as h,K as Yt,C as ot,M as Xt,L as Zt,N as rt,B as $,P as lt,F as ct,j as es,D as dt,A as de,o as J,Q as he,s as ts,ae as Le,am as ss}from"./index.js";import{m as n,d as p,A as Te,q as ut,y as U,_ as Ie,T as Y,P as as}from"./vendor.js";import{c as Re}from"./lazy-component.js";import{M as K}from"./markdown-renderer.js";import{c as ns}from"./copyable-code.js";import{g as is,G as os}from"./dashboard-goals.js";import{K as pt}from"./core.js";import{b as xe,f as Pe,c as rs}from"./format-time.js";import{c as ls}from"./shared-ticker.js";import{I as Ae}from"./inline-spinner.js";import{M as cs}from"./master-detail.js";import{R as ds}from"./refresh-button.js";import{T as us}from"./target-locked-action.js";import{V as ps}from"./virtual-list.js";import{G as vt,p as le,q as kt,s as vs,a as mt,r as ye,u as ks,v as ms,j as $s,t as $t,w as fs,i as N,d as R,h as ft,e as wt,g as bt,k as ws,x as It}from"./types.js";import{y as na,n as ia,b as oa,c as ra,m as la,z as ca,A as da,B as ua,C as pa,l as va,f as ka,D as ma,E as $a,o as fa,F as wa,H as ba,I as ga,J as ha}from"./types.js";import"./markdown.js";import"./toast.js";import"./type-guards.js";import"./keeper-state.js";import"./format-string.js";import"./table.js";import"./useSelector.js";const bs=3e4,At=ls(bs),gs=At.signal;function X(t){return typeof t=="string"?new Date(t).getTime():Number.isFinite(t)?t<1e12?t*1e3:t:Number.NaN}function hs(t){const s=X(t);return Number.isFinite(s)?new Date(s).toISOString():""}function ys(t){const s=X(t);return Number.isFinite(s)?Math.floor(s/1e3):Number.NaN}function _s(t){const s=X(t);return Number.isFinite(s)?`${xe(t)} (${Pe(Math.floor(s/1e3))})`:"—"}function Cs(t){const s=X(t);return Number.isFinite(s)?`${xe(t)} (${Pe(Math.floor(s/1e3))})`:"—"}function Ts(t,s){const o=X(t);if(!Number.isFinite(o))return"—";const c=xe(t);if(s==="relative")return c;const l=Pe(ys(t));return s==="absolute"?l:`${c} · ${l}`}function Is({timestamp:t,mode:s="relative",class:o}){At.use(),gs.value;const c=Ts(t,s),l=hs(t),f=_s(t),v=Cs(t),C=o?`time-ago ${o}`:"time-ago";return n`<time class=${C} datetime=${l||void 0} title=${v} aria-label=${f}>${c}</time>`}const z="work:goals:list",ce="work:goals:verification",Se=["goal","goals","goal_updated","planning"],St=["verification","verification_requests","backlog","task","tasks"],gt=[];function As(t){return t.kind!=="observed"||t.lastActivityAt===null||Number.isNaN(Date.parse(t.lastActivityAt))?null:t.lastActivityAt}function Lt({activity:t}){const s=As(t);return s===null?n`${rs(t.stagnationSeconds)} 전`:n`<${Is} timestamp=${s} />`}function Ss(t){switch(t.kind){case"observed":return n`<${Lt} activity=${t} /> · ${fs(t.source)}`;case"unavailable":return"기록된 활동 없음";case"unknown":return"확인 불가"}}function Rt(t,s){for(const o of t){const c=ws(o);if(c.ok){const l=c.value;s.goals.push(l);const f=N(o)&&Array.isArray(o.tasks)?o.tasks:null,v=l.linkedTaskCount;(f!==null?f.length!==l.linkedTasks.length||v.kind==="value"&&v.data!==l.linkedTasks.length:v.kind!=="value"||v.data!==0)&&s.incompleteTaskLinks.add(l.id)}else s.rejectedCount+=1;N(o)&&Array.isArray(o.children)&&Rt(o.children,s)}}function ht(t,s){const o=is(t);if(o)throw new os(o);const c=N(t)?t[s]:null;if(!Array.isArray(c))throw new Error("응답에서 목표 목록을 확인할 수 없습니다.");const l={goals:[],rejectedCount:0,incompleteTaskLinks:new Set};return Rt(c,l),l}function Ls(t){if(!N(t))throw new Error("검증 목록 응답 형식이 잘못되었습니다.");if(t.backlog_error!=null)throw new Error(R(t.backlog_error)??"태스크 대기열을 읽지 못했습니다.");if(!Array.isArray(t.requests))throw new Error("응답에서 검증 목록을 확인할 수 없습니다.");const s=[];for(const o of t.requests){if(!N(o))continue;const c=R(o.request_id),l=R(o.task_id);if(!c||!l)continue;const f=N(o.review_observation)?o.review_observation:null;s.push({requestId:c,taskId:l,taskTitle:wt(o.task_title,l),submittedBy:wt(o.submitted_by,"unknown"),createdAt:typeof o.created_at=="string"||typeof o.created_at=="number"?o.created_at:null,completionContract:ft(o.completion_contract),submittedEvidence:ft(o.submitted_evidence),reviewState:f?R(f.state):null,reviewDetail:f?R(f.detail):null})}return{rows:s,incomplete:t.truncated===!0||(bt(t.awaiting_unresolved_total)??0)>0||(bt(t.unreadable_total)??0)>0||s.length<t.requests.length,recovery:R(t.backlog_recovery)}}function yt(t){return h.fetch(z,async s=>{const o=await de("/api/v1/dashboard/goals",{signal:s,decode:c=>ht(c,"tree")});return o.ok||s.aborted||o.error.kind==="epoch_stale"?o:de("/api/v1/dashboard/planning",{signal:s,decode:c=>ht(c,"goals")})},{ttlMs:1e4,topics:Se,reason:t})}function _e(t){return h.fetch(ce,s=>de("/api/v1/verification/requests?view=awaiting&limit=50&offset=0",{signal:s,decode:Ls}),{ttlMs:1e4,topics:St,reason:t})}function _t(t){const s=Te(null);return Ie(()=>{t.kind==="value"&&(s.current=t.data)},[t]),t.kind==="value"?t.data:s.current}function Ct(t,s){return s.kind==="loading"?{tone:"info",text:`${t} 불러오는 중…`}:s.kind==="value"&&s.stale?{tone:"warn",text:`${t} · 마지막 조회`}:null}function Ce(t){return t?n`
    <span class=${`wk-status-pill wk-status-pill--${t.tone}`} role="status" title=${t.text}>
      ${t.tone==="info"&&n`<${Ae} size="xs" />`}
      <span class="wk-status-pill-text">${t.text}</span>
    </span>
  `:null}function Tt(t,s,o){switch(s.kind){case"loading":case"value":return null;case"failed":case"unreported":case"absent":{const c=s.kind==="failed"?s.error.message:s.reason;return n`<div class="wk-notice wk-notice--err" role="alert">
        ${t} 조회 불가${o?" · 마지막 조회 표시 중":""}${c?` · ${c}`:""}
      </div>`}}}function Rs(t){switch(t){case"request_complete":return"완료 검증 요청";case"pause":return"일시정지";case"resume":return"재개";case"block":return"차단";case"unblock":return"차단 해제";case"drop":return"중단(Drop)";case"reopen":return"다시 열기"}}function xs(t){const s=Jt(),o=q.value,c=o.kind==="single_user_local",l=!c,f=c&&!re("admin",o),v=h.observe(z).value,C=h.observe(ce).value,T=_t(v),E=_t(C),x=T?.goals??gt,Ve=E?.rows??gt,m=v.kind==="value"&&!v.stale,Z=m&&T?.rejectedCount===0,O=!l&&C.kind==="value"&&!C.stale&&C.data.recovery===null,[P,De]=p("ALL"),[ue,Dt]=p(""),[F,pe]=p(t.entityId??null),ee=Te(null),[Ge,ve]=p(!1),[Ne,Ee]=p(""),[W,Gt]=p("done_when"),[Me,Ke]=p(""),[Oe,Fe]=p(""),[Be,Nt]=p("1"),[je,Et]=p(""),[qe,Mt]=p("at_least"),[Ue,Kt]=p("1"),[ze,We]=p(""),[He,Ot]=p(2),[Qe,te]=p(null),[se,ke]=p(!1),[me,$e]=p(""),[I,V]=p(null),[Je,g]=p(null),[fe,B]=p(null),[Ye,Xe]=p(null),ae=Te(null),[Ze,Ft]=p({}),D=ut(e=>$(s)?Promise.all([yt(e),l?null:_e(e)]):Promise.resolve(),[s,l]);U(()=>{D("mount")},[D]),U(()=>{m&&Yt()},[m]),U(()=>{let e=null,i=!1,r=!1;const d=(_,L)=>{$(s)&&(i||=_,r||=L&&!l,!(e!==null||!i&&!r)&&(e=setTimeout(()=>{e=null,$(s)&&(i&&yt("sse"),r&&_e("sse")),i=!1,r=!1},450)))},u=()=>{$(s)&&(h.invalidateKey(z),l||h.invalidateKey(ce))},b=ot(_=>{const L=dt(_);d(L.some(w=>Se.includes(w)),L.some(w=>St.includes(w)))}),A=Xt(()=>d(!0,!0)),G=Zt(_=>{u(),_==="observer_resync_required"&&d(!0,!0)});let S=rt.peek();const be=rt.subscribe(_=>{_&&!S&&(u(),d(!0,!0)),S=_});return()=>{b(),A(),G(),be(),e!==null&&clearTimeout(e)}},[s,l]),Ie(()=>{pe(t.entityId??null)},[t.entityId]);const et=Y(()=>{const e=ue.trim().toLowerCase();return x.filter(i=>!(P!=="ALL"&&i.phase!==P||e&&!i.title.toLowerCase().includes(e)&&!i.id.toLowerCase().includes(e)&&!i.measureText.toLowerCase().includes(e)))},[x,P,ue]),we=Y(()=>{const e={ALL:x.length};for(const i of vt)e[i]=0;for(const i of x)e[i.phase]=(e[i.phase]??0)+1;return e},[x]),a=Y(()=>F===null?x[0]??null:x.find(e=>e.id===F)??null,[x,F]);Ie(()=>{ee.current=a?.id??null,F===null&&m&&a&&pe(a.id)},[F,a,m]);const j=a!==null&&(T?.incompleteTaskLinks.has(a.id)===!0||!!E?.recovery),M=fe?.epoch===s&&fe.goalId===a?.id?fe:null,k=M?.evidence??null,ne=M?.kind==="ready"&&M.source===v&&m;U(()=>ot(e=>{if(!k||!$(s)||!dt(e).some(b=>Se.includes(b)))return;const r=N(e.data)?e.data:null,d=N(r?.payload)?r.payload:r,u=R(d?.goal_id);if(!u||u===k.goalId){const b=R(d?.criterion_revision)??R(d?.revision);Xe(b??`${k.criterionRevision}:sse-${Date.now()}`)}}),[k,s]);const H=a?.verification,y=H?.state==="stale"?H.historical:H?.state==="current"&&a?.phase!=="Awaiting_confirmation"?H.completion:null,tt=H?.state==="stale",Bt=tt?"이전 기준 검증 기록":y?.state==="refuted"?"검증 반증 사유":"검증 증거",ie=ut(async(e,i)=>{const r=q.peek();if(r.kind!=="single_user_local"||re("admin",r)||!$(s)||i.kind!=="value"||i.stale)return;ae.current?.abort();const d=new AbortController;ae.current=d;const{signal:u}=d,b={epoch:s,goalId:e,source:i},A=w=>w?.epoch===s&&w.goalId===e?w.evidence:null,G=w=>w==="network"||w==="timeout"||w==="server";B(w=>({...b,kind:"loading",evidence:A(w)}));const S=await ye();if(u.aborted||!$(s))return;if(!S.ok){const w=G(S.error.kind);B(ge=>({...b,kind:"failed",message:S.error.message,evidence:w?A(ge):null}));return}const be=new URLSearchParams({goal_id:e,expected_base_path:S.value.base_path,expected_masc_root:S.value.masc_root}),_=await de(`/api/v1/goals/confirmation?${be.toString()}`,{signal:u});if(u.aborted||!$(s))return;if(!_.ok){const w=G(_.error.kind);B(ge=>({...b,kind:"failed",message:_.error.message,evidence:w?A(ge):null}));return}const L=ks(_.value,e,S.value);if(!L.ok){B({...b,kind:"failed",message:L.error,evidence:null});return}B({...b,kind:"ready",evidence:L.value}),Xe(L.value.criterionRevision)},[s,f]);U(()=>{$e(""),g(null)},[a?.id]),U(()=>(f&&a&&a.phase==="Awaiting_confirmation"?ie(a.id,v):f||(ae.current?.abort(),B(null)),()=>ae.current?.abort()),[a?.id,a?.phase,v,ie,f]);const st=async e=>{if(e.preventDefault(),q.peek().kind!=="single_user_local"||!$(s)||se)return;te(null);const i=ms({title:Ne,measureKind:W,condition:Me,noun:Oe,total:Be,unit:je,direction:qe,target:Ue,procedure:ze,priority:He});if(!i.ok){te(i.error);return}ke(!0);const r=await ye();if(!$(s))return;if(!r.ok){ke(!1),te(r.error.message);return}const d=`goal-${Date.now().toString(36)}-${Math.random().toString(36).slice(2,8)}`,u=await $s("masc_goal_upsert",{id:d,if_absent:!0,expected_workspace:$t(r.value),title:i.value.title,measure:i.value.measure,procedure:i.value.procedure,priority:i.value.priority});if($(s)){if(ke(!1),!u.ok){te(u.error.message);return}J(`목표 "${i.value.title}" 생성 완료`,"success"),Ee(""),Ke(""),Fe(""),We(""),ve(!1),h.invalidateTopic("goals"),D("manual")}},jt=async(e,i)=>{if(q.peek().kind!=="single_user_local"||!$(s)||!m||I!==null)return;V(i),g(null);const r=await ye();if(!$(s))return;if(h.peek(z)!==v||ee.current!==e.id){V(null),g({kind:"err",message:"목표 정보가 변경되었습니다. 최신 상태를 확인한 뒤 다시 실행하세요."});return}if(!r.ok){V(null),g({kind:"err",message:r.error.message});return}const d={goal_id:e.id,action:i,expected_workspace:$t(r.value)};me.trim()&&(d.note=me.trim());const u=await he("POST","/api/v1/tools/masc_goal_transition",d);if($(s)){if(V(null),!u.ok){g({kind:"err",message:`전이 실패 (${i}): ${u.error.message}`});return}$e(""),g(null),J(`${e.id} → ${i} 전이 적용됨`,"success"),h.invalidateTopic("goals"),D("manual")}},qt=async()=>{const e=q.peek();if(e.kind!=="single_user_local"||re("admin",e))return;const i=k;if(!i||!ne||!$(s)||I!==null||h.peek(z)!==v||ee.current!==i.goalId||Ye!==i.criterionRevision)return;V("confirm"),g(null);const r=await he("POST","/api/v1/goals/confirmation",{goal_id:i.goalId,criterion_revision:i.criterionRevision,request_id:i.requestId,verification_run_id:i.verificationRunId,expected_workspace:i.workspace,expected_operator_id:i.inspectionOperatorId,expected_runtime_instance_id:i.runtimeInstanceId});if($(s)){if(V(null),!r.ok){g({kind:"err",message:`완료 확정 실패: ${r.error.message}`});return}g(null),J(`목표 ${i.goalId} 최종 완료 확정됨`,"success"),h.invalidateTopic("goals"),D("manual")}},oe=async(e,i)=>{i&&(await ns(i)?(g(null),J(`${e} 복사됨`,"success")):g({kind:"err",message:`${e} 복사에 실패했습니다. 직접 선택해 복사해 주세요.`}))},at=async(e,i)=>{const r=q.peek();if(r.kind!=="single_user_local"||re("admin",r)||!$(s)||!m||!O||I!==null||h.peek(z)!==v||h.peek(ce)!==C||ee.current!==a?.id)return;const d=(Ze[e.requestId]??"").trim();if(i==="reject"&&!d){g({kind:"err",message:"반려(reject) 시 사유를 반드시 입력해야 합니다."});return}V(`verif:${e.requestId}`),g(null);const u={task_id:e.taskId,verification_id:e.requestId,verdict:i};i==="reject"&&(u.reason=d);const b=await he("POST","/api/v1/verification/verdict",u);if($(s)){if(V(null),!b.ok){g({kind:"err",message:`검증 판정 실패: ${b.error.message}`});return}g(null),J(`검증 ${e.requestId} (${e.taskId}) ${i==="approve"?"승인":"반려"} 완료`,"success"),h.invalidateTopic("verification"),D("manual")}},Q=Y(()=>{if(!a)return[];const e=new Set(a.linkedTasks.map(i=>i.id));return Ve.filter(i=>e.has(i.taskId))},[Ve,a]),nt=O&&m&&!E?.incomplete&&!j,it=Y(()=>{if(!a)return"—";const e=a.linkedTasks,i=e.length;let r=0,d=0,u=0;for(let A=0;A<i;A++){const G=e[A].status;G==="Done"?r+=1:G==="AwaitingVerification"?d+=1:G==="Cancelled"&&(u+=1)}const b=i-r-d-u;return`태스크 ${i}개 · 완료 ${r} · 검증 대기 ${d} · 취소 ${u} · 그 외 ${b}`},[a]),Ut=Ct("목표 목록",v),zt=l?null:Ct("검증 목록",C),Wt=!l&&k!==null?M?.kind==="loading"?{tone:"info",text:"증거 확인 중…"}:ne?null:{tone:"warn",text:"증거 · 마지막 조회"}:null,Ht=n`
    <div class="wk-pane-col">
      <div class="wk-pane-head">
        <h2 class="wk-pane-title">Goals <span class="wk-chip-count">(${Z?et.length:"—"})</span></h2>
        <div class="wk-pane-status-slot">
          ${Ce(Ut)}
        </div>
        <div class="wk-actions">
          ${!l&&n`
            <button type="button" class="btn-primary" onClick=${()=>ve(e=>!e)}>
              ${Ge?"닫기":"+ 새 목표"}
            </button>
          `}
          <${ds} onRefresh=${()=>D("manual")} />
        </div>
      </div>

      <div class="wk-filter-bar">
        <div class="wk-filter-row">
          <${lt}
            triggerLabel=${`단계: ${P==="ALL"?"전체":le(P)} (${Z?we[P]:"—"}) ▾`}
            triggerClassName="btn-ghost"
            triggerTestId="goals-phase-filter"
            popoverTestId="goals-phase-filter-menu"
            ariaLabel="목표 단계 필터"
            items=${[{id:"ALL",testId:"goals-phase-ALL",label:`전체 (${Z?we.ALL:"—"})`,active:P==="ALL",onSelect:()=>De("ALL")},...vt.map(e=>({id:e,testId:`goals-phase-${e}`,label:`${le(e)} (${Z?we[e]:"—"})`,active:P===e,onSelect:()=>De(e)}))]}
          />
          <input
            type="search"
            class="wk-input wk-filter-search"
            placeholder="목표 제목, ID, 측정 조건 검색…"
            value=${ue}
            onInput=${e=>Dt(e.target.value)}
            aria-label="목표 검색"
          />
        </div>
        ${T&&T.rejectedCount>0&&n`
          <div class="wk-notice wk-notice--warn" role="status">
            형식이 올바르지 않은 목표 ${T.rejectedCount}건을 읽지 못했습니다.
          </div>
        `}
      </div>

      ${Ge&&n`
        <form class="wk-form wk-inset" onSubmit=${st}>
          <div class="wk-section-title">새 목표 생성 (measure + procedure 필수)</div>
          <div class="wk-field">
            <label for="goal-title">제목</label>
            <input
              id="goal-title"
              class="wk-input"
              required
              value=${Ne}
              onInput=${e=>Ee(e.target.value)}
              placeholder="예: 대시보드 DOM 1,200 이하 달성"
            />
          </div>
          <div class="wk-form-grid">
            <div class="wk-field">
              <label for="goal-measure-kind">성공 조건 유형 (measure)</label>
              <select
                id="goal-measure-kind"
                class="wk-select"
                value=${W}
                onChange=${e=>Gt(e.target.value)}
              >
                <option value="done_when">완료 조건 (done_when)</option>
                <option value="count">개수 달성 (count)</option>
                <option value="quantity">수량 기준 (quantity)</option>
              </select>
            </div>
            <div class="wk-field">
              <label for="goal-priority">우선순위 (1=최고)</label>
              <input
                id="goal-priority"
                type="number"
                min="1"
                max="5"
                class="wk-input tnum"
                value=${He}
                onInput=${e=>Ot(Number(e.target.value))}
              />
            </div>
          </div>

          ${W==="done_when"&&n`
            <div class="wk-field">
              <label for="goal-measure-cond">완료 조건</label>
              <input
                id="goal-measure-cond"
                class="wk-input"
                value=${Me}
                onInput=${e=>Ke(e.target.value)}
                placeholder="참/거짓으로 판정 가능한 한 줄 조건"
              />
            </div>
          `}
          ${W==="count"&&n`
            <div class="wk-form-grid">
              <div class="wk-field">
                <label for="goal-measure-noun">단위 명사 (noun)</label>
                <input id="goal-measure-noun" class="wk-input" value=${Oe} onInput=${e=>Fe(e.target.value)} placeholder="예: PR" />
              </div>
              <div class="wk-field">
                <label for="goal-measure-total">목표 개수 (total)</label>
                <input id="goal-measure-total" type="number" min="1" class="wk-input tnum" value=${Be} onInput=${e=>Nt(e.target.value)} />
              </div>
            </div>
          `}
          ${W==="quantity"&&n`
            <div class="wk-form-grid">
              <div class="wk-field">
                <label for="goal-measure-dir">방향</label>
                <select id="goal-measure-dir" class="wk-select" value=${qe} onChange=${e=>Mt(e.target.value)}>
                  <option value="at_least">이상 (≥)</option>
                  <option value="at_most">이하 (≤)</option>
                </select>
              </div>
              <div class="wk-field">
                <label for="goal-measure-target">목표 수치</label>
                <input id="goal-measure-target" type="number" step="any" class="wk-input tnum" value=${Ue} onInput=${e=>Kt(e.target.value)} />
              </div>
              <div class="wk-field">
                <label for="goal-measure-unit">단위 (unit)</label>
                <input id="goal-measure-unit" class="wk-input" value=${je} onInput=${e=>Et(e.target.value)} placeholder="예: ms, KB" />
              </div>
            </div>
          `}

          <div class="wk-field">
            <label for="goal-procedure">측정 절차 (procedure — 필수)</label>
            <textarea
              id="goal-procedure"
              class="wk-textarea"
              value=${ze}
              onInput=${e=>We(e.target.value)}
              onKeyDown=${e=>{e.isComposing||e.keyCode===229||(e.metaKey||e.ctrlKey)&&e.key==="Enter"&&!se&&(e.preventDefault(),st(e))}}
              placeholder="Verifier가 실재성·도달 가능성을 검증할 수 있는 구체적 측정 절차"
            />
          </div>
          ${Qe&&n`<div class="wk-notice wk-notice--err" role="alert">${Qe}</div>`}
          <div class="wk-actions">
            <button type="submit" class="btn-primary" disabled=${se}>
              ${se?"생성 중…":"목표 저장"}
            </button>
            <button type="button" class="btn-ghost" onClick=${()=>ve(!1)}>취소</button>
          </div>
        </form>
      `}

      ${Tt("목표 목록",v,T!==null)}

      ${T&&n`
            <${ps}
              items=${et}
              estimateSize=${96}
              height="100%"
              ariaLabel="목표 목록"
              getItemKey=${e=>e.id}
              empty=${m&&n`<div class="wk-detail-pad"><span class="dtable-absent">${T.rejectedCount>0?"읽은 범위에 표시할 목표가 없습니다.":"표시할 목표가 없습니다."}</span></div>`}
              renderItem=${e=>n`
                <button
                  type="button"
                  class="wk-row-btn wk-goal-row"
                  data-selected=${a?.id===e.id?"true":"false"}
                  onClick=${()=>pe(e.id)}
                >
                  <div class="wk-row-top">
                    <span class="wk-row-title" title=${e.title}>${e.title}</span>
                    <span class=${`wk-badge wk-badge--${kt(e.phase)}`}>
                      ${le(e.phase)}
                      ${e.resumePhase?` ↩ ${e.resumePhase}`:""}
                    </span>
                  </div>
                  ${e.measureText&&n`
                    <div class="wk-goal-measure" title=${e.measureText}>${e.measureText}</div>
                  `}
                  <div class="wk-row-meta">
                    <span class="mono">P${e.priority}</span>
                    <span class="tnum">Tasks: ${ct(e.linkedTaskCount)}</span>
                    ${e.pendingApprovalCount!==null&&e.pendingApprovalCount>0&&n`
                      <span class="wk-badge wk-badge--warn tnum">승인 대기 ${e.pendingApprovalCount}</span>
                    `}
                    ${e.activity.kind==="observed"&&n`
                      <span class="tnum">마지막 활동 <${Lt} activity=${e.activity} /></span>
                    `}
                    ${e.criterionVerdict.kind==="viable"&&n`<span class="wk-badge wk-badge--ok">기준 적합</span>`}
                    ${e.criterionVerdict.kind==="needs_revision"&&n`<span class="wk-badge wk-badge--err">기준 수정 필요</span>`}
                  </div>
                </button>
              `}
            />
          `}
    </div>
  `,Qt=a?n`
        <div class="wk-detail-pad">
          <div class="wk-section-head">
            <div class="wk-min-w-0">
              <div class="mono wk-sub-id">${a.id}</div>
              <h2 class="wk-heading">${a.title}</h2>
            </div>
            <div class="wk-actions">
              <span class=${`wk-badge wk-badge--${kt(a.phase)}`}>
                ${le(a.phase)}
                ${a.resumePhase?` (보존: ${a.resumePhase})`:""}
              </span>
              <${lt}
                align="right"
                triggerLabel="⋯"
                triggerClassName="btn-ghost"
                triggerTestId="goal-detail-actions"
                popoverTestId="goal-detail-actions-menu"
                ariaLabel="목표 추가 작업"
                items=${[{id:"copy-id",testId:"goal-action-copy-id",label:"ID 복사",description:a.id,onSelect:()=>{oe("목표 ID",a.id)}},{id:"candle",testId:"goal-action-candle",label:"Candle 지급 보기 →",onSelect:()=>t.onNavigate(`/work/candle/${encodeURIComponent(a.id)}`)},{id:"inspect",testId:"goal-action-inspect",label:"원본 검사",onSelect:()=>t.onInspect({title:`Goal: ${a.title}`,subtitle:`${a.id} · ${a.phase}`,kind:"goal",data:a})}]}
              />
            </div>
          </div>

          ${Je&&n`
            <div class="wk-notice wk-notice--err" role="alert">
              ${Je.message}
            </div>
          `}

          <div class="wk-kv-grid">
            <div class="wk-kv">
              <span class="wk-kv-k">성공 조건 (measure)</span>
              <span class="wk-kv-v">${a.measureText}</span>
            </div>
            <div class="wk-kv">
              <span class="wk-kv-k">우선순위 / 마감</span>
              <span class="wk-kv-v tnum">P${a.priority} · ${a.dueDate??"없음"}</span>
            </div>
            <div class="wk-kv">
              <span class="wk-kv-k">연결 태스크</span>
              <span class="wk-kv-v tnum">${ct(a.linkedTaskCount)}</span>
            </div>
            <div class="wk-kv">
              <span class="wk-kv-k">기준 리비전</span>
              <span class="wk-kv-v mono">${a.criterionRevision??"없음"}</span>
            </div>
            <div class="wk-kv">
              <span class="wk-kv-k">승인 대기</span>
              <span class="wk-kv-v tnum">${a.pendingApprovalCount===null?"확인 불가":`${a.pendingApprovalCount}건`}</span>
            </div>
            <div class="wk-kv">
              <span class="wk-kv-k">마지막 활동</span>
              <span class="wk-kv-v tnum">${Ss(a.activity)}</span>
            </div>
          </div>

          <div class="wk-notice" role="status">
            ${j||!m?"태스크 목록 확인 중 — 아래 연결된 태스크와 검증 목록을 함께 보세요.":nt?`${it} · 검증 제출 ${Q.length}건${Q.length>0?" (아래 목록)":""}`:`${it} · 검증 제출 —`}
          </div>

          <section class="wk-section" aria-label="측정 절차 및 기준 심사">
            <div class="wk-section-head">
              <h3 class="wk-section-title">측정 절차 (procedure) & Criterion Review</h3>
              ${a.criterionVerdict.kind==="viable"&&n`<span class="wk-badge wk-badge--ok">Viable</span>`}
              ${a.criterionVerdict.kind==="needs_revision"&&n`<span class="wk-badge wk-badge--err">Needs Revision</span>`}
              ${a.criterionVerdict.kind==="pending"&&n`<span class="wk-badge wk-badge--idle">${a.criterionVerdict.state}</span>`}
              ${a.criterionVerdict.kind==="unavailable"&&n`<span class="wk-badge wk-badge--warn">Unavailable</span>`}
              <button
                type="button"
                class="btn-ghost"
                aria-label="측정 절차 복사"
                title="측정 절차 복사"
                disabled=${!a.procedure}
                onClick=${()=>{oe("측정 절차",a.procedure)}}
              >
                복사
              </button>
              ${a.phase==="Awaiting_confirmation"&&k&&n`
                <span class="wk-muted-sm">
                  ${ne?"최신 증거":"마지막 조회 증거"}는 아래 Goal Completion Confirmation 참조 (기준 ${k.criterionRevision})
                </span>
              `}
            </div>
            <${K} class="wk-prose" text=${a.procedure||"측정 절차 없음"} />
            <${K} class="wk-muted-sm" text=${a.criterionVerdict.kind==="viable"||a.criterionVerdict.kind==="needs_revision"?a.criterionVerdict.reason:a.criterionVerdict.kind==="unavailable"?a.criterionVerdict.detail:a.criterionVerdict.detail??"Verifier 기준 심사 대기 중"} />
            ${a.lastReviewNote&&n`
              <div class="wk-notice">최근 전환 메모<${K} text=${a.lastReviewNote} /></div>
            `}
          </section>

          ${!l&&n`<section class="wk-section" aria-label="목표 단계 전환">
            <h3 class="wk-section-title">Phase Transition (POST /api/v1/tools/masc_goal_transition)</h3>
            <input
              type="text"
              class="wk-input"
              placeholder="전환 사유/메모 (선택, Drop 등 취소 사유는 last_review_note에 기록)"
              value=${me}
              onInput=${e=>$e(e.target.value)}
              aria-label="단계 전환 메모"
            />
            <div class="wk-actions">
              ${vs(a.phase).map(e=>n`
                <button
                  key=${e}
                  type="button"
                  class=${e==="drop"||e==="block"?"wk-btn-danger":e==="request_complete"?"btn-primary":"btn-ghost"}
                  disabled=${I!==null||!m}
                  onClick=${()=>{jt(a,e)}}
                >
                  ${I===e?"처리 중…":Rs(e)}
                </button>
              `)}
            </div>
          </section>`}

          ${a.phase==="Awaiting_confirmation"&&n`
            <section class="wk-section" aria-label="목표 최종 완료 확인">
              <div class="wk-section-head">
                <h3 class="wk-section-title">Goal Completion Confirmation</h3>
                <div class="wk-pane-status-slot">
                  ${Ce(Wt)}
                </div>
                ${k&&n`
                  <button
                    type="button"
                    class="btn-ghost"
                    aria-label="완료 증거 복사"
                    title="완료 증거 복사"
                    onClick=${()=>{oe("완료 증거",k.evidence)}}
                  >
                    증거 복사
                  </button>
                `}
                ${f&&n`
                  <button type="button" class="btn-ghost" disabled=${!m} onClick=${()=>{ie(a.id,v)}}>
                    증거 다시 읽기
                  </button>
                `}
              </div>
              ${!f&&n`
                <div class="wk-notice wk-notice--info" data-testid="goal-confirm-admin-locked">
                  ${c?"목표 완료 확인 증거 조회 및 확정은 관리자 전용입니다.":"이 세션에서는 완료 확인 증거를 조회할 수 없습니다."}
                </div>
              `}
              ${!k&&M?.kind==="loading"&&n`
                <span class="dtable-absent" role="status"><${Ae} /> Verifier 증명 증거 불러오는 중…</span>
              `}
              ${M?.kind==="failed"&&n`
                <div class="wk-notice wk-notice--err" role="alert">${M.message}</div>
              `}
              ${k&&n`
                <div class="wk-muted-sm">
                  증명 주체: <strong>${k.actor}</strong> (${k.authorityKind}) · 기록: ${mt(k.recordedAt)}
                </div>
                <${K} class="wk-prose" text=${k.evidence} />
                <${us}
                  target=${{workspaceId:es.peek(),keeper:k.actor,requestId:k.requestId,revision:k.criterionRevision}}
                  currentRevision=${Ye??k.criterionRevision}
                  lockedEpoch=${s}
                  onRefresh=${()=>{m?ie(a.id,v):D("manual")}}
                >
                  <button
                    type="button"
                    class="wk-btn-ok"
                    disabled=${I!==null||!ne}
                    onClick=${()=>{qt()}}
                  >
                    ${I==="confirm"?"확정 중…":"최종 완료 확정 (Confirm Completion)"}
                  </button>
                <//>
              `}
            </section>
          `}

          ${(y?.state==="proven"||y?.state==="refuted")&&n`
            <details
              key=${a.id}
              class="ap-disclosure"
              data-testid="goal-verification-evidence-disclosure"
              aria-label=${tt?"이전 기준 검증 기록":"목표 검증 증거"}
              open=${y.state==="refuted"}
            >
              <summary class="ap-disclosure-trigger">
                <span>
                  ${Bt} · ${y.state==="proven"?"증명됨":"반증됨"} (${y.actor})
                </span>
                <span aria-hidden="true">▸</span>
              </summary>
              <div class="ap-disclosure-body">
                <div class="wk-section-head">
                  <div class="wk-muted-sm">
                    ${y.state==="proven"?"증명됨":"반증됨"} · ${y.actor} · ${mt(y.recordedAt)}
                  </div>
                  <button
                    type="button"
                    class="btn-ghost"
                    aria-label="검증 증거 복사"
                    title="검증 증거 복사"
                    onClick=${()=>{oe("검증 증거",y.evidence)}}
                  >
                    증거 복사
                  </button>
                </div>
                <${K} class="wk-prose" text=${y.evidence} />
                ${y.state==="refuted"&&n`<${K} class="wk-notice" text=${y.reason} />`}
              </div>
            </details>
          `}

          <section class="wk-section" aria-label="연결된 태스크">
            <div class="wk-section-head">
              <h3 class="wk-section-title">연결된 태스크 (${j||!m?"—":a.linkedTasks.length})</h3>
              <button
                type="button"
                class="btn-ghost"
                onClick=${()=>t.onNavigate("/work/tasks")}
              >
                전체 태스크 보기 →
              </button>
            </div>
            ${j&&n`
              <div class="wk-notice wk-notice--warn" role="status">연결된 태스크 목록을 모두 확인하지 못했습니다.</div>
            `}
            ${a.linkedTasks.length===0?!j&&m&&n`<span class="dtable-absent">연결된 태스크가 없습니다.</span>`:n`
                  <div class="wk-stack-1">
                    ${a.linkedTasks.map(e=>n`
                      <button
                        key=${e.id}
                        type="button"
                        class="wk-row-btn wk-linked-row"
                        onClick=${()=>t.onNavigate(`/work/tasks/${encodeURIComponent(e.id)}`)}
                      >
                        <div class="wk-row-top">
                          <span class="wk-row-title">${e.title}</span>
                          <span class="wk-badge">${e.status}</span>
                        </div>
                        <div class="wk-row-meta">
                          <span class="mono">${e.id}</span>
                          ${e.assignee?n`<${pt} id=${e.assignee} size="sm" />`:n`<span>미배정</span>`}
                        </div>
                      </button>
                    `)}
                  </div>
                `}
          </section>

          <section class="wk-section" aria-label="연결 태스크 검증 판정">
            <div class="wk-section-head">
              <h3 class="wk-section-title">Verification Verdicts <span class="wk-chip-count">(${nt?Q.length:"—"})</span></h3>
              <div class="wk-pane-status-slot">
                ${Ce(zt)}
              </div>
              ${!l&&n`
                <button type="button" class="btn-ghost" onClick=${()=>{_e("manual")}}>검증 다시 읽기</button>
              `}
            </div>
            ${l?n`<div class="wk-notice wk-notice--info">이 세션에서는 검증 대기열을 조회할 수 없습니다.</div>`:n`
                  ${Tt("검증 목록",C,E!==null)}
                  ${E?.recovery&&n`
                    <div class="wk-notice wk-notice--warn" role="status">현재 검증 목록 조회 불가 · 복구 스냅샷 표시 중</div>
                  `}
                  ${E?.incomplete&&n`
                    <div class="wk-notice wk-notice--warn" role="status">검증 목록의 일부만 확인되었습니다.</div>
                  `}
                  ${Q.length===0&&O&&m&&n`
                    <span class="dtable-absent">${E?.incomplete||j?"읽은 범위에 이 목표의 검증 제출이 없습니다.":"이 목표에 연결된 태스크의 대기 중인 검증 제출이 없습니다."}</span>
                  `}
                  ${Q.map(e=>n`
                    <div key=${e.requestId} class="wk-subcard">
                      <div class="wk-row-top">
                        <strong>${e.taskTitle}</strong>
                        <span class="mono wk-sub-id">${e.requestId}</span>
                      </div>
                      <div class="wk-row-meta">
                        <span>제출: <${pt} id=${e.submittedBy} size="sm" /></span>
                        <span>태스크: <span class="mono">${e.taskId}</span></span>
                        ${e.reviewState==="running"&&O?n`<span class="wk-badge wk-badge--info"><${Ae} /> 검토 중</span>`:e.reviewState&&n`<span class="wk-badge">${e.reviewState==="running"?"마지막 관측 · 검토 중":e.reviewState}</span>`}
                      </div>
                      ${e.reviewDetail&&n`<div class="wk-muted-sm">${e.reviewDetail}</div>`}
                      ${e.submittedEvidence.length>0&&n`
                        <div class="wk-muted-sm">
                          증거
                          <ul>${e.submittedEvidence.map((i,r)=>n`
                            <li key=${r}><${K} text=${i} /></li>
                          `)}</ul>
                        </div>
                      `}
                      ${f?n`
                            <input
                              type="text"
                              class="wk-input"
                              placeholder="반려 사유 (reject 시 필수)"
                              value=${Ze[e.requestId]??""}
                              onInput=${i=>Ft(r=>({...r,[e.requestId]:i.target.value}))}
                              aria-label=${`검증 ${e.requestId} 반려 사유`}
                            />
                            <div class="wk-actions">
                              <button
                                type="button"
                                class="wk-btn-ok"
                                disabled=${I!==null||!m||!O}
                                onClick=${()=>{at(e,"approve")}}
                              >
                                검증 승인
                              </button>
                              <button
                                type="button"
                                class="wk-btn-danger"
                                disabled=${I!==null||!m||!O}
                                onClick=${()=>{at(e,"reject")}}
                              >
                                검증 반려
                              </button>
                            </div>
                          `:n`<div class="wk-muted-sm" data-testid="goal-verdict-admin-locked">검증 판정(승인/반려)은 관리자 전용입니다.</div>`}
                    </div>
                  `)}
                `}
          </section>
        </div>
      `:null;return n`
    <${cs}
      master=${Ht}
      detail=${Qt}
      hasSelection=${a!==null}
      selectionKey=${F}
      linkedKey=${t.entityId??null}
      masterLabel="목표 목록"
      detailLabel="목표 상세"
      emptyDetail=${n`<div class="wk-detail-pad"><span class="dtable-absent">목표를 선택하면 단계 전환, 기준 심사, 검증 판정 및 연결 태스크를 확인할 수 있습니다.</span></div>`}
    />
  `}const xt=Re(async()=>(await Le(async()=>{const{TasksTab:t}=await import("./tasks-tab.js");return{TasksTab:t}},__vite__mapDeps([0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18]))).TasksTab),Pt=Re(async()=>(await Le(async()=>{const{InboxTab:t}=await import("./inbox-tab.js");return{InboxTab:t}},__vite__mapDeps([19,1,5,2,3,4,7,8,20,14,15,16,21,22,23,12,13,11,9,10,24,17,18]))).InboxTab),Vt=Re(async()=>(await Le(async()=>{const{CandleTab:t}=await import("./candle-tab.js");return{CandleTab:t}},__vite__mapDeps([25,1,3,7,8,23,12,13,11,10,24,26,14,15,16,17]))).CandleTab);function Ps(t){switch(It(t)){case"tasks":return xt.preload();case"inbox":return Pt.preload();case"candle":return Vt.preload();default:return Promise.resolve()}}ss("work",t=>{Ps(t).catch(()=>{})});function ta(t){const s=It(t.subroute);return n`
    <section class="wk-root" aria-label="Work workspace">
      <div class="wk-body">
        ${s==="goals"&&n`<${xs} key=${ts.value} ...${t} />`}
        ${s!=="goals"&&n`
          <${as} fallback=${null}>
            ${s==="tasks"&&n`<${xt.Component} ...${t} />`}
            ${s==="inbox"&&n`<${Pt.Component} ...${t} />`}
            ${s==="candle"&&n`<${Vt.Component} ...${t} />`}
          <//>
        `}
      </div>
    </section>
  `}export{vt as GOAL_PHASES,xs as GoalsTab,ta as WorkWorkspace,na as asFiniteNumber,R as asNonEmptyString,bt as asSafeInt,wt as asString,ft as asStringArray,vs as availableGoalActions,ia as buildCandleTrendSeries,$s as callMcpToolViaCore,oa as checkTaskGoalLinkable,ra as computeTaskFilterCounts,la as decodeCandleLedger,ca as decodeCriterionVerdict,da as decodeGoalActivity,ks as decodeGoalConfirmation,ws as decodeGoalItem,ua as decodeGoalMeasureStrict,pa as decodeGoalPhaseStrict,va as decodeTaskItem,ka as filterTasksByChip,ma as formatCompactCount,$a as formatGoalMeasure,fa as formatMilliCandles,mt as formatRelativeTime,fs as goalActivitySourceLabel,le as goalPhaseLabel,kt as goalPhaseTone,wa as isMultiAccountSession,N as isRecord,It as normalizeWorkSubroute,ba as parseCandleMilli,ga as parseTaskStatus,Ps as preloadWorkSubroute,ye as readWorkspacePrecondition,$t as toExpectedWorkspaceBody,ha as toolApprovalTimeout,ms as validateNewGoalInput};
