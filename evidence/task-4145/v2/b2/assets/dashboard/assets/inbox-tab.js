import{d as L,A as qe,q as Xe,y as U,T as ae,m as i}from"./vendor.js";import{I as ge}from"./inline-spinner.js";import{M as F}from"./markdown-renderer.js";import{s as wt,a as De,R as ot,c as it,S as Pe,z as T,B as G,K as yt,C as It,D as At,L as xt,M as St,N as Ye,A as rt,j as Tt,Q as ve,r as Y}from"./index.js";import{K as ne}from"./core.js";import{d as Rt,r as Ct,a as jt,b as Gt}from"./hitl-decoders.js";import{i as lt}from"./type-guards.js";import{K as Ke,i as A,d as b,g as qt,r as Dt,u as Et,a as Pt,k as Kt,J as Lt,y as Ot}from"./types.js";import"./dashboard-goals.js";import{c as me}from"./format-time.js";import{D as Nt}from"./data-table.js";import{M as Ht}from"./master-detail.js";import{R as Ft}from"./refresh-button.js";import{T as fe}from"./target-locked-action.js";import{V as Mt}from"./virtual-list.js";import"./markdown.js";import"./keeper-state.js";import"./format-string.js";import"./table.js";import"./useSelector.js";function Ee(t,a){const n=Object.keys(t);return n.length===a.length&&n.every(r=>a.includes(r))}function zt(t){if(!lt(t)||typeof t.code!="string")return null;switch(t.code){case"ready":case"in_flight":case"settled":return Ee(t,["code"])?{code:t.code}:null;case"identity_unbound":case"persistence_uncertain":{const a=Ke(t.operator_detail,"").trim(),n=t.code==="identity_unbound"?"Exact-output terminalization stopped before an attempt identity was bound.":"Exact-output terminalization durability is not confirmed.";return a===n&&Ee(t,["code","operator_detail"])?{code:t.code,operator_detail:a}:null}case"pre_worker_unavailable":{const a=t.reason_code,n=t.operator_detail;return(a==="auto_judge_unavailable"||a==="mode_state_invalid"||a==="start_reserved")&&typeof n=="string"&&n.length>0&&n.trim()===n&&Ee(t,["code","reason_code","operator_detail"])?{code:t.code,reason_code:a,operator_detail:n}:null}default:return null}}function Bt(t){return t==="queued"||t==="judging"||t==="human_required"||t==="blocked"?t:null}function Ze(t,a){const n=Object.keys(t).sort(),r=[...a].sort();return n.length===r.length&&n.every((d,_)=>d===r[_])}function Jt(t){if(!lt(t))return{ok:!1,detail:"hitl.judge_lane is not an object"};const a=Ke(t.lane_id,"").trim();if(!a)return{ok:!1,detail:"hitl.judge_lane.lane_id is invalid"};if(t.status==="available"&&Array.isArray(t.slots)&&Ze(t,["status","lane_id","slots"])){const n=t.slots.filter(r=>typeof r=="string"&&r.trim()!=="");return n.length===0||n.length!==t.slots.length?{ok:!1,detail:"hitl.judge_lane.slots is invalid"}:{ok:!0,lane:{status:"available",lane_id:a,slots:n}}}if(t.status==="unavailable"&&Ze(t,["status","lane_id","reason"])){const n=Ke(t.reason,"").trim();if(n)return{ok:!0,lane:{status:"unavailable",lane_id:a,reason:n}}}return{ok:!1,detail:"hitl.judge_lane is not a current closed variant"}}function Qt(t){return t==="always_allowed"||t==="auto_judge"||t==="human_operator"?t:null}function Ut(t,a){if(t!==500||typeof a!="object"||a===null||Array.isArray(a))return!1;const n=a;return n.recorded===!0&&n.state!=="recording_unconfirmed"}function ct(t){switch(t){case"blocked":return{key:"blocked",label:"● Auto Judge blocked",detail:"Auto Judge 종료 실패 · 재개나 Human 판단 필요",severity:"sev-bad"};case"human_required":return{key:"human_required",label:"● Human required",detail:"Auto Judge 완료 · Human 판단 필요",severity:"sev-warn"};case"judging":return{key:"judging",label:"● Auto Judging",detail:"Auto Judge 판정 중",severity:"sev-info"};case"queued":return{key:"queued",label:"● Queue waiting",detail:"판정 시작 대기",severity:"sev-warn"}}}function Vt(t){switch(t){case"always_allowed":return"Always Allowed";case"auto_judge":return"Auto Judge";case"human_operator":return"Human";default:return"판단 주체 미확인"}}function Wt(t){return t.status==="available"?`판정 모델 ${t.slots[0]}${t.slots.length>1?` (+${t.slots.length-1} failover)`:""}`:`판정 lane ${t.lane_id} 확인 불가: ${t.reason}`}const Xt=["tool_approval","keeper_ask","channel_gate","goal_confirmation"],Yt=["goal_confirmation"],se=[];function Zt(t){if(!A(t)||!Array.isArray(t.pending))throw new Error("도구 승인 응답에서 대기 목록을 확인할 수 없습니다.");const a=[];for(const n of Gt(t))n.toolCallId&&a.push({approvalId:n.approvalId,toolCallId:n.toolCallId,keeper:n.keeper,tool:n.tool||"tool",argsPreview:n.args||"{}",question:n.question,because:n.because||null,askedAt:n.askedAt,timeoutSec:n.timeoutSec,revision:n.revision});return a}function ea(t){const a=jt(t);if(!a.ok)throw new Error(a.error);const n=[];for(const r of a.asks)r.questions.length!==0&&n.push({askId:r.askId,keeper:r.keeper,context:r.context,questions:r.questions.map(d=>({questionId:d.questionId,header:d.header,prompt:d.prompt,mode:d.mode,allowFreeText:d.allowFreeText,freeTextHint:d.freeTextHint,choices:d.choices.map(_=>({choiceId:_.choiceId,label:_.label,description:_.description}))})),revision:r.revision});return n}function ta(t){switch(t){case"approve":case"reject":return t;default:return null}}function aa(t){if(!A(t))return null;const a=b(t.id),n=b(t.keeper_name),r=b(t.tool_name),d=ta(t.decision_kind),_=Ot(t.resolved_at),$=_===null||_<0?null:new Date(_*1e3);if(!a||!n||!r||d===null||$===null||Number.isNaN($.getTime()))return null;const x=b(t.decision_reason);return(d==="approve"?t.decision_reason===null:x!==null)?{id:a,keeper:n,toolName:r,decision:d,decisionSource:Qt(t.decision_source),reason:x,actor:b(t.actor),resolvedAt:$.toISOString()}:null}function na(t){if(!A(t))throw new Error("Channel Gate 응답 형식이 잘못되었습니다.");const a=Rt(t),n=a.ok?null:a.error;let r=Ct(t.recent_resolved_state)??(Array.isArray(t.recent_resolved)?null:"응답에서 결정 이력을 확인할 수 없습니다.");const d=a.ok?a.rows.map(y=>{const v=y.raw,V=A(v.summary_status)?v.summary_status:null,g=V&&A(V.summary)?V.summary:null;return{id:y.id,keeper:y.keeper,toolName:y.toolName,inputPreview:b(v.input_preview)??(v.input?JSON.stringify(v.input):null),waitingSec:y.waitingSec,phase:Bt(v.phase),disposition:zt(v.summary_attempt_disposition),sequence:y.sequence,taskId:b(v.task_id),goalId:b(v.goal_id),summaryText:g?b(g.context_summary):null,rationale:g?b(g.rationale):null,keyQuestions:Array.isArray(g?.key_questions)?g.key_questions.flatMap(B=>typeof B=="string"&&B.trim()?[B]:[]):[]}}):[];let _=[];if(r===null&&Array.isArray(t.recent_resolved))for(const y of t.recent_resolved){const v=aa(y);if(v===null){r="결정 이력에 서버 계약과 다른 줄이 있어요(id·keeper_name·tool_name·decision_kind·resolved_at).",_=[];break}_.push(v)}const $=A(t.recent_resolved_page)?t.recent_resolved_page:null,x=$?.truncated===!0||$?.scan_exhausted===!0,O=A(t.hitl)?Jt(t.hitl.judge_lane):null,z=O?.ok?O.lane:null;return{pending:d,resolved:_,queueError:n,auditError:r,auditPartial:x,judgeLane:z}}function sa(t){if(!A(t)||!Array.isArray(t.goals)){const n=A(t)&&t.ok===!1?b(t.reason):null;throw new Error(n??"계획 응답에서 Goal 목록을 확인할 수 없습니다.")}const a=[];for(const n of t.goals){const r=Kt(n);r.ok&&r.value.phase==="Awaiting_confirmation"&&a.push(r.value)}return a}const q={tool_approval:{key:"work:inbox:tool-approvals",label:"도구 승인",path:"/api/v1/keepers/tool-approvals",topics:["approval","tool_approval","keeper_tool_approval_waits_changed","keeper_waiting_inventory_changed"],decode:Zt},keeper_ask:{key:"work:inbox:keeper-asks",label:"Keeper 질문",path:"/api/v1/keepers/asks?include_resolved=false",topics:["ask","keeper_ask","keeper_asks_changed","keeper_waiting_inventory_changed"],decode:ea},channel_gate:{key:"work:inbox:channel-gate",label:"Channel Gate 대기열",path:"/api/v1/dashboard/gate",topics:["gate","approval:pending","approval:resolved","approval:summary_updated"],decode:na},goal_confirmation:{key:"work:inbox:goal-confirmations",label:"Goal 완료 확인",path:"/api/v1/dashboard/planning",topics:["goal","goals","planning","goal_projection_changed","pending_confirms_changed"],decode:sa}};function et(t){return t===null?"● 단계 확인 불가":ct(t).label}function oa(t){return t===null?"확인 불가":"operator_detail"in t?`${t.code} · ${t.operator_detail}`:t.code}function ia(t,a){const n=Lt(t,a);switch(n.kind){case"unknown":return"대기 한도 확인 불가";case"pending":return`${me(n.remainingSec)} 뒤 시간 초과 (대기 한도 ${me(n.timeoutSec)})`;case"expired":return`${me(n.overdueSec)} 전에 대기 한도 지남 (대기 한도 ${me(n.timeoutSec)})`}}const tt={tool_approval:"tool",keeper_ask:"ask",channel_gate:"gate",goal_confirmation:"goal"};function ra(t,a){switch(t){case"tool_approval":return b(a.approval_id)??b(a.tool_call_id);case"keeper_ask":return b(a.ask_id);case"channel_gate":return b(a.id);case"goal_confirmation":return b(a.goal_id)??b(a.id)}}function la(t,a){const n=q[t];return T.fetch(n.key,r=>rt(n.path,{signal:r,decode:n.decode}),{ttlMs:8e3,topics:n.topics,reason:a})}function E(t,a){return t.kind==="value"&&!t.stale&&a==null}function at(t,a,n,r=!0){if(a.kind==="loading")return null;const d=a.kind==="failed"?a.error.message:a.kind==="absent"||a.kind==="unreported"?a.reason:n;return d||a.kind!=="value"?i`<div class=${r?"wk-notice wk-notice--err wk-inset":"wk-notice wk-notice--err"} role="alert">${t} 조회 불가${d?` · ${d}`:""}</div>`:null}function nt(t){const a=[],n=[];for(const $ of t)$.observation.kind==="loading"?a.push($.label):$.observation.kind==="value"&&$.observation.stale&&$.problem==null&&n.push($.label);const r=[];if(a.length>0&&r.push(`${a.join(", ")} 불러오는 중…`),n.length>0&&r.push(`${n.join(", ")} · 마지막 조회 결과`),r.length===0)return null;const d=r.join(" · "),_=n.length>0?"warn":"info";return i`
    <span class=${`wk-status-pill wk-status-pill--${_}`} role="status" title=${d}>
      ${a.length>0&&i`<${ge} />`}
      <span class="wk-status-pill-text">${d}</span>
    </span>
  `}function st(t,a){return t==="tool_approval"||t==="keeper_ask"?ot(a)&&it(a):Pe(a)}function Ca(t){const a=wt.value,n=De.value,r=ot(n),d=!r,_=r&&it(n),$=Pe(n),x=r?Xt:n.kind==="multi_account_signed_in"?Yt:[],O=T.observe(q.tool_approval.key).value,z=T.observe(q.keeper_ask.key).value,y=T.observe(q.channel_gate.key).value,v=T.observe(q.goal_confirmation.key).value,V={tool_approval:O,keeper_ask:z,channel_gate:y,goal_confirmation:v},g=!d&&y.kind==="value"?y.data:null,B=!d&&O.kind==="value"?O.data:se,$e=!d&&z.kind==="value"?z.data:se,he=g?.pending??se,oe=g?.resolved??se,be=v.kind==="value"?v.data:se,D={tool_approval:!d&&E(O),keeper_ask:!d&&E(z),channel_gate:!d&&E(y,g?.queueError),goal_confirmation:E(v),audit:!d&&E(y,g?.auditError)},[Le,dt]=L("all"),w=d&&Le!=="goal_confirmation"?"all":Le,ie=w==="all"?x.every(e=>D[e]):D[w],[Z,_e]=L(null),[J,re]=L({}),we=qe(J);we.current=J;const[ye,Ie]=L(""),[Oe,Ae]=L(!1),[Ne,xe]=L({}),[Se,ee]=L(null),[le,N]=L(!1),[te,h]=L(null),Te=qe(null),He=qe(new Set),S=Xe(async(e,o=x)=>{if(!G(a))return;const l=we.current;await Promise.all(o.map(async p=>{const u=await la(p,e);e==="sse"||p==="goal_confirmation"||!G(a)||!E(u)||p==="channel_gate"&&u.kind==="value"&&A(u.data)&&u.data.queueError!==null||re(m=>{const c={...m};let k=!1;for(const R of Object.keys(m))!R.startsWith(`${tt[p]}:`)||m[R]!==l[R]||(delete c[R],k=!0);return k?c:m})}))},[x,a]);U(()=>{re({}),N(!1),h(null),xe({}),_e(null),S("mount")},[S]),U(()=>{ie&&yt()},[w,ie,O,z,y,v]),U(()=>{let e=null;const o=new Set,l=I=>{for(const C of I)o.add(C);e!==null||o.size===0||(e=setTimeout(()=>{e=null;const C=[...o];o.clear(),S("sse",C)},450))},p=()=>{if(G(a))for(const I of x)T.invalidateKey(q[I].key)},u=It(I=>{if(!G(a))return;const C=At(I),pe=x.filter(f=>C.some(j=>q[f].topics.includes(j))),M=A(I.data)?I.data:null,H=A(M?.payload)?M.payload:M;if(H!==null){const f=b(H.revision)??qt(H.sequence)??b(H.criterion_revision)??`sse-${Date.now()}`,j={};for(const ke of pe){const Ve=ra(ke,H);if(Ve===null)continue;const We=`${tt[ke]}:${Ve}`;He.current.has(We)&&(j[We]=f)}Object.keys(j).length>0&&re(ke=>({...ke,...j}))}l(pe)}),m=xt(I=>{p(),I==="observer_resync_required"&&l(x)}),c=St(()=>l(x));let k=Ye.peek();const R=Ye.subscribe(I=>{I&&!k&&(p(),l(x)),k=I});return()=>{u(),m(),c(),R(),e!==null&&clearTimeout(e)}},[x,a,S]);const W=ae(()=>{const e=[];for(const o of B)e.push({kind:"tool_approval",key:`tool:${o.approvalId}`,item:o});for(const o of $e)e.push({kind:"keeper_ask",key:`ask:${o.askId}`,item:o});for(const o of he)e.push({kind:"channel_gate",key:`gate:${o.id}`,item:o});for(const o of be)e.push({kind:"goal_confirmation",key:`goal:${o.id}`,goal:o});return e},[B,$e,he,be]);He.current=ae(()=>new Set(W.map(e=>e.key)),[W]);const Q=ae(()=>w==="all"?W:w==="audit"?[]:W.filter(e=>e.kind===w),[W,w]);U(()=>{w!=="audit"&&_e(e=>e&&Q.some(o=>o.key===e)?e:Q[0]?.key??null)},[w,Q]);const s=ae(()=>Q.find(e=>e.key===Z)??null,[Q,Z]),Fe=s?.kind==="tool_approval",[ut,Me]=L(()=>Date.now());U(()=>{if(!Fe)return;Me(Date.now());const e=setInterval(()=>Me(Date.now()),1e3);return()=>clearInterval(e)},[Fe]);const ce=s?.kind==="goal_confirmation"?s.goal:null,P=Se?.epoch===a&&Se.goalId===ce?.id?Se:null,K=P?.evidence??null,ze=P?.kind==="value"&&P.planning===v&&E(v),Re=Xe(async(e,o,l=!1)=>{if(!Pe(De.peek())||!G(a)||!E(o))return;Te.current?.abort();const p=new AbortController;Te.current=p;const u=p.signal,m={epoch:a,goalId:e,planning:o},c=`goal:${e}`,k=we.current[c],R=f=>f?.epoch===a&&f.goalId===e?f.evidence:null,I=f=>f==="network"||f==="timeout"||f==="server";ee(f=>({...m,kind:"loading",evidence:R(f)}));const C=await Dt();if(u.aborted||!G(a))return;if(!C.ok){const f=I(C.error.kind);ee(j=>({...m,kind:"failed",reason:C.error.message,evidence:f?R(j):null}));return}const pe=new URLSearchParams({goal_id:e,expected_base_path:C.value.base_path,expected_masc_root:C.value.masc_root}),M=await rt(`/api/v1/goals/confirmation?${pe.toString()}`,{signal:u});if(u.aborted||!G(a))return;if(!M.ok){const f=I(M.error.kind);ee(j=>({...m,kind:"failed",reason:M.error.message,evidence:f?R(j):null}));return}const H=Et(M.value,e,C.value);if(!H.ok){ee({...m,kind:"failed",reason:H.error,evidence:null});return}ee({...m,kind:"value",evidence:H.value}),l&&T.peek(q.goal_confirmation.key)===o&&re(f=>{if(f[c]===void 0||f[c]!==k)return f;const j={...f};return delete j[c],j})},[a,$]);U(()=>{Ie(""),Ae(!1)},[Z]),U(()=>{if(!(!ce?.id||w==="audit"||!$||!E(v)))return Re(ce.id,v),()=>Te.current?.abort()},[ce?.id,v,w==="audit",Re,$]);const de=e=>{const o=De.peek();if(!st(e,o)||le||!G(a))return!1;const l=T.peek(q[e].key);return!l||!E(l)?!1:e!=="channel_gate"||l.kind==="value"&&A(l.data)&&l.data.queueError===null},Be=async(e,o)=>{if(!de("tool_approval"))return;N(!0),h(null);const l=await ve("POST","/api/v1/keepers/tool-approval",{name:e.keeper,tool_call_id:e.toolCallId,approval_id:e.approvalId,decision:o});if(!G(a))return;if(N(!1),!l.ok){h({kind:"err",message:`도구 승인 처리 실패: ${l.error.message}`});return}const p=A(l.value)?l.value:null,u=`${e.keeper} / ${e.tool}`;p?.settled===!0?h({kind:"ok",message:`${u} → ${o==="approve"?"승인됨":"거부됨"}`}):p?.remembered===!0?h({kind:"ok",message:`${u} · 같은 호출이 재시도될 때 적용할 결정으로 저장했습니다.`}):h({kind:"err",message:`${u} · 결정 접수를 확인하지 못했습니다.`}),T.invalidateTopic("tool_approval"),await S("manual",["tool_approval"]),Y()},Je=async(e,o)=>{if(!de("channel_gate"))return;if(o==="reject"&&!ye.trim()){h({kind:"err",message:"Gate 거절(reject) 시 사유를 입력하세요."});return}N(!0),h(null);const l={id:e.id,decision:o,remember_rule:o==="approve"?Oe:!1};o==="reject"&&(l.reason=ye.trim());const p=await ve("POST","/api/v1/dashboard/gate/resolve",l);if(!G(a))return;if(N(!1),!p.ok){h({kind:"err",message:`Gate 결정 실패: ${p.error.message}`});return}Ie(""),Ae(!1);const m=(A(p.value)&&Array.isArray(p.value.audit_receipts)?p.value.audit_receipts:[]).some(c=>A(c)&&c.recorded===!1);h({kind:m?"err":"ok",message:m?`Gate ${e.id} (${e.toolName}) → ${o} · 감사 기록 저장 실패`:`Gate ${e.id} (${e.toolName}) → ${o}`}),T.invalidateTopic("gate"),await S("manual",["channel_gate"]),Y()},Ce=e=>{xe(o=>{if(!(e in o))return o;const l={...o};return delete l[e],l})},pt=async e=>{if(!de("keeper_ask"))return;const o=Ne[e.askId]??{},l=e.questions.filter(c=>{const k=o[c.questionId];return k?k.kind==="wrote"?k.text.trim()==="":k.kind==="chose"?k.choiceIds.length===0:!1:!0});if(l.length>0){h({kind:"err",message:`미응답 질문이 ${l.length}개 있습니다.`});return}const p=e.questions.map(c=>{const k=o[c.questionId];return k.kind==="chose"?{question_id:c.questionId,response:{kind:"chose",choice_ids:k.choiceIds}}:k.kind==="wrote"?{question_id:c.questionId,response:{kind:"wrote",text:k.text.trim()}}:{question_id:c.questionId,response:{kind:"skipped"}}});N(!0),h(null);const u=await ve("POST","/api/v1/keepers/ask-answer",{name:e.keeper,ask_id:e.askId,answers:p});if(!G(a))return;if(N(!1),!u.ok){if(Ut(u.error.status,u.error.body)){Ce(e.askId),h({kind:"ok",message:`${e.keeper} 질문(${e.askId}) 답변이 기록되었습니다. Keeper 깨움 전달은 자동 복구 대기 중입니다.`}),T.invalidateTopic("ask"),await S("manual",["keeper_ask"]),Y();return}if(u.error.kind==="conflict_cas"||u.error.status===409){Ce(e.askId),h({kind:"err",message:"다른 사람이 먼저 답변했습니다. 목록을 새로 읽었습니다."}),T.invalidateTopic("ask"),await S("manual",["keeper_ask"]),Y();return}h({kind:"err",message:`Ask 답변 제출 실패: ${u.error.message}`});return}Ce(e.askId);const m=A(u.value)&&u.value.delivered===!1;h({kind:"ok",message:m?`${e.keeper} 질문(${e.askId}) 답변이 기록되었습니다. Keeper 깨움 전달은 자동 복구 대기 중입니다.`:`${e.keeper} 질문(${e.askId})에 답변을 전달했습니다.`}),T.invalidateTopic("ask"),await S("manual",["keeper_ask"]),Y()},kt=async e=>{if(!de("goal_confirmation")||P?.kind!=="value"||T.peek(q.goal_confirmation.key)!==P.planning)return;N(!0),h(null);const o=await ve("POST","/api/v1/goals/confirmation",{goal_id:e.goalId,criterion_revision:e.criterionRevision,request_id:e.requestId,verification_run_id:e.verificationRunId,expected_workspace:e.workspace,expected_operator_id:e.inspectionOperatorId,expected_runtime_instance_id:e.runtimeInstanceId});if(G(a)){if(N(!1),!o.ok){h({kind:"err",message:`목표 완료 확정 실패: ${o.error.message}`});return}h({kind:"ok",message:`목표 ${e.goalId} 완료 확정됨`}),T.invalidateTopic("goals"),await S("manual",["goal_confirmation"]),Y()}},je=(e,o,l)=>{xe(p=>{const u={...p[e]??{}};return l===null?delete u[o]:u[o]=l,{...p,[e]:u}})},vt=ae(()=>[{id:"resolvedAt",header:"시각",accessor:e=>Pt(e.resolvedAt),sortValue:e=>e.resolvedAt,sortable:!0},{id:"keeper",header:"Keeper",cell:e=>i`<${ne} id=${e.keeper} size="sm" />`},{id:"tool",header:"Tool",accessor:e=>e.toolName},{id:"decision",header:"판정",cell:e=>i`
        <span class=${`wk-badge ${e.decision==="approve"?"wk-badge--ok":"wk-badge--err"}`}>
          ${e.decision}
        </span>
      `},{id:"source",header:"출처",accessor:e=>Vt(e.decisionSource)},{id:"actor",header:"처리자",accessor:e=>e.actor},{id:"reason",header:"사유",accessor:e=>e.reason}],[]),ue=Tt.value,X=!(s===null?_||$:st(s.kind,n))||le||s!==null&&!D[s.kind],mt=()=>w==="all"?S("manual"):S("manual",[w==="audit"?"channel_gate":w]),ft=[{id:"all",label:"All Open",count:W.length,ready:x.every(e=>D[e])},...d?[]:[{id:"tool_approval",label:"Tool Approvals",count:B.length,ready:D.tool_approval},{id:"keeper_ask",label:"Keeper Asks",count:$e.length,ready:D.keeper_ask},{id:"channel_gate",label:"Channel Gate",count:he.length,ready:D.channel_gate}],{id:"goal_confirmation",label:"Goal Confirm",count:be.length,ready:D.goal_confirmation},...d?[]:[{id:"audit",label:"24h Decisions",count:oe.length,ready:D.audit&&!g?.auditPartial}]],gt=le?i`<span class="wk-status-pill wk-status-pill--info" role="status" title="결정 응답을 기다리는 중…"><${ge} /><span class="wk-status-pill-text">결정 응답을 기다리는 중…</span></span>`:te?.kind==="ok"?i`<span class="wk-status-pill wk-status-pill--ok" role="status" title=${te.message}><span class="wk-status-pill-text">${te.message}</span></span>`:null,Ge=!le&&te?.kind==="err"?i`<div class="wk-notice wk-notice--err" role="alert">${te.message}</div>`:null,Qe=i`
    <div class="wk-toolbar">
      <div class="wk-chips" role="group" aria-label="인박스 필터">
        ${ft.map(e=>i`
          <button key=${e.id} type="button" class="wk-chip" aria-pressed=${w===e.id} onClick=${()=>dt(e.id)}>
            ${e.label} <span class="wk-chip-count">${e.ready?e.count:"—"}</span>
          </button>
        `)}
      </div>
      <div class="wk-toolbar-end">
        ${gt}
        <${Ft} onRefresh=${mt} />
      </div>
    </div>
  `,$t=d?i`<div class="wk-notice wk-notice--info" role="note">멀티 계정 모드의 Inbox에는 Goal 완료 확인이 표시됩니다.</div>`:!_&&!$?i`<div class="wk-notice wk-notice--info" data-testid="inbox-admin-locked" role="status">HITL 승인·거절·답변·확정 결정은 관리자 전용입니다.</div>`:$?null:i`<div class="wk-notice wk-notice--info" data-testid="inbox-token-admin-partial" role="status">Channel Gate 및 Goal 최종 확정은 토큰 인증 관리자 전용입니다. Tool Approval·Keeper Ask 결정은 로컬 관리자 세션에서 실행할 수 있습니다.</div>`;if(w==="audit"){const e=nt([{label:"Channel Gate 결정 이력",observation:y,problem:g?.auditError}]);return i`
      <div class="wk-scroll-body">
        ${Qe}
        ${Ge}
        <div class="wk-pane-head">
          <h2 class="wk-pane-title">24h Decisions <span class="wk-chip-count">(${D.audit&&!g?.auditPartial?oe.length:"—"})</span></h2>
          <div class="wk-pane-status-slot" data-testid="inbox-audit-sync-slot">
            ${e}
          </div>
        </div>
        ${at("Channel Gate 결정 이력",y,g?.auditError,!1)}
        ${g?.auditPartial&&i`
          <div class="wk-notice wk-notice--warn" role="note">조회 범위 제한으로 최근 24시간의 결정 이력이 일부만 표시됩니다.</div>
        `}
        ${(D.audit||oe.length>0)&&i`
          <${Nt}
            data=${oe}
            columns=${vt}
            initialSort=${{id:"resolvedAt",desc:!0}}
            getRowId=${o=>`${o.id}-${o.resolvedAt}`}
            caption="최근 24시간 HITL 결정 감사 로그"
            emptyLabel=${g?.auditPartial?"조회된 범위에 결정 기록이 없습니다.":"최근 24시간 내 처리된 결정 기록이 없습니다."}
          />
        `}
      </div>
    `}const Ue=w==="all"?x:[w],ht=nt(Ue.map(e=>({label:q[e].label,observation:V[e],problem:e==="channel_gate"?g?.queueError:null}))),bt=i`
    <div class="wk-pane-col">
      <div class="wk-pane-head">
        <h2 class="wk-pane-title">Unified HITL Queue
          <span class="wk-chip-count">(${ie?Q.length:"—"})</span>
        </h2>
        <div class="wk-pane-status-slot" data-testid="inbox-queue-sync-slot">
          ${ht}
        </div>
      </div>
      ${Ue.map(e=>at(q[e].label,V[e],e==="channel_gate"?g?.queueError:null))}
      <${Mt}
        items=${Q}
        estimateSize=${76}
        height="100%"
        ariaLabel="통합 HITL 대기열"
        getItemKey=${e=>e.key}
        empty=${ie?i`<div class="wk-detail-pad"><span class="dtable-absent">처리가 필요한 항목이 없습니다.</span></div>`:null}
        renderItem=${e=>{const o=e.kind==="tool_approval"?"Tool Approval":e.kind==="keeper_ask"?"Keeper Ask":e.kind==="channel_gate"?"Channel Gate":"Goal Confirm",l=e.kind==="tool_approval"?`${e.item.tool} — ${e.item.question||"도구 실행 승인"}`:e.kind==="keeper_ask"?e.item.questions[0]?.header??e.item.askId:e.kind==="channel_gate"?`${e.item.toolName} · ${et(e.item.phase)}`:e.goal.title,p=e.kind==="tool_approval"||e.kind==="keeper_ask"||e.kind==="channel_gate"?e.item.keeper:"verifier";return i`
            <button
              type="button"
              class="wk-row-btn"
              data-selected=${Z===e.key?"true":"false"}
              onClick=${()=>_e(e.key)}
            >
              <div class="wk-row-top">
                <span class="wk-row-title">${l}</span>
                <span class="wk-badge wk-badge--warn">${o}</span>
              </div>
              <div class="wk-row-meta">
                <${ne} id=${p} size="sm" />
                ${J[e.key]!==void 0&&i`<span class="wk-badge wk-badge--err">SSE 변경 감지됨</span>`}
              </div>
            </button>
          `}}
      />
    </div>
  `,_t=s?i`
        <div class="wk-detail-pad">
          ${Ge}
          ${s.kind==="tool_approval"&&i`
            <div class="wk-section-head">
              <div class="wk-min-w-0">
                <span class="wk-badge wk-badge--warn">Tool Approval</span>
                <h2 class="wk-heading">${s.item.tool}</h2>
              </div>
              <${ne} id=${s.item.keeper} portrait=${!0} />
            </div>
            ${s.item.question&&i`<${F} class="wk-prose" text=${s.item.question} />`}
            ${s.item.because&&i`
              <div class="wk-notice">
                <strong>정책 사유</strong>
                <${F} text=${s.item.because} />
              </div>
            `}
            <div class="wk-kv-grid">
              <div class="wk-kv">
                <span class="wk-kv-k">응답 기한</span>
                <span class="wk-kv-v tnum">${ia(s.item,ut)}</span>
              </div>
            </div>
            <pre class="wk-code-preview">${s.item.argsPreview}</pre>
            <${fe}
              target=${{workspaceId:ue,keeper:s.item.keeper,requestId:s.item.approvalId,revision:s.item.revision}}
              currentRevision=${J[s.key]??s.item.revision}
              lockedEpoch=${a}
              onRefresh=${()=>{S("manual",["tool_approval"])}}
            >
              <button type="button" class="wk-btn-ok" disabled=${X} onClick=${()=>{Be(s.item,"approve")}}>
                승인 (Approve)
              </button>
              <button type="button" class="wk-btn-danger" disabled=${X} onClick=${()=>{Be(s.item,"deny")}}>
                거부 (Deny)
              </button>
            <//>
          `}

          ${s.kind==="keeper_ask"&&i`
            <div class="wk-section-head">
              <div class="wk-min-w-0">
                <span class="wk-badge wk-badge--info">Keeper Ask</span>
                <h2 class="wk-heading">${s.item.askId}</h2>
              </div>
              <${ne} id=${s.item.keeper} portrait=${!0} />
            </div>
            ${s.item.context&&i`<${F} class="wk-notice" text=${s.item.context} />`}
            ${s.item.questions.map(e=>{const o=Ne[s.item.askId]?.[e.questionId],l=o?.kind==="chose"?o.choiceIds:[],p=o?.kind==="wrote"?o.text:"";return i`
                <section key=${e.questionId} class="wk-section">
                  <div class="wk-section-head">
                    <strong>${e.header}</strong>
                    <span class="wk-badge">${e.mode==="multi"?"복수 선택":"단일 선택"}</span>
                  </div>
                  <${F} class="wk-prose" text=${e.prompt} />
                  ${e.choices.length>0&&(()=>{const u=e.choices.some(c=>!!c.description),m=(c,k)=>{const R=e.mode==="single"?k?[]:[c]:k?l.filter(I=>I!==c):[...l,c];je(s.item.askId,e.questionId,R.length===0?null:{kind:"chose",choiceIds:R})};return u?i`
                          <div class="wk-ask-choices">
                            ${e.choices.map(c=>{const k=l.includes(c.choiceId);return i`
                                <div key=${c.choiceId} class="wk-ask-choice-card" data-selected=${k?"true":"false"}>
                                  <button
                                    type="button"
                                    class="wk-chip"
                                    aria-pressed=${k}
                                    onClick=${()=>m(c.choiceId,k)}
                                  >
                                    ${c.label}
                                  </button>
                                  ${c.description&&i`<${F} class="wk-prose" text=${c.description} />`}
                                </div>
                              `})}
                          </div>
                        `:i`
                          <div class="wk-chips">
                            ${e.choices.map(c=>{const k=l.includes(c.choiceId);return i`
                                <button
                                  key=${c.choiceId}
                                  type="button"
                                  class="wk-chip"
                                  aria-pressed=${k}
                                  onClick=${()=>m(c.choiceId,k)}
                                >
                                  ${c.label}
                                </button>
                              `})}
                          </div>
                        `})()}
                  <div class="wk-field">
                    <label for=${`ask-text-${e.questionId}`}>직접 입력 ${e.freeTextHint?`(${e.freeTextHint})`:"(선택)"}</label>
                    <input
                      id=${`ask-text-${e.questionId}`}
                      type="text"
                      class="wk-input"
                      value=${p}
                      onInput=${u=>{const m=u.target.value;je(s.item.askId,e.questionId,m===""?null:{kind:"wrote",text:m})}}
                    />
                  </div>
                  <div>
                    <button
                      type="button"
                      class="btn-ghost"
                      aria-pressed=${o?.kind==="skipped"}
                      onClick=${()=>je(s.item.askId,e.questionId,o?.kind==="skipped"?null:{kind:"skipped"})}
                    >
                      ${o?.kind==="skipped"?"건너뛰기 선택됨":"이 질문 건너뛰기"}
                    </button>
                  </div>
                </section>
              `})}
            <${fe}
              target=${{workspaceId:ue,keeper:s.item.keeper,requestId:s.item.askId,revision:s.item.revision}}
              currentRevision=${J[s.key]??s.item.revision}
              lockedEpoch=${a}
              onRefresh=${()=>{S("manual",["keeper_ask"])}}
            >
              <button type="button" class="btn-primary" disabled=${X} onClick=${()=>{pt(s.item)}}>
                답변 제출 (Submit Answer)
              </button>
            <//>
          `}

          ${s.kind==="channel_gate"&&i`
            <div class="wk-section-head">
              <div class="wk-min-w-0">
                <span class="wk-badge wk-badge--warn">Channel Gate · ${et(s.item.phase)}</span>
                <h2 class="wk-heading">${s.item.toolName}</h2>
              </div>
              <${ne} id=${s.item.keeper} portrait=${!0} />
            </div>
            <div class="wk-kv-grid">
              <div class="wk-kv">
                <span class="wk-kv-k">상태</span>
                <span class="wk-kv-v">${s.item.phase===null?"서버 응답에서 단계를 읽을 수 없음":ct(s.item.phase).detail}</span>
              </div>
              <div class="wk-kv">
                <span class="wk-kv-k">Auto Judge</span>
                <span class="wk-kv-v mono">${oa(s.item.disposition)}</span>
              </div>
              <div class="wk-kv">
                <span class="wk-kv-k">판정 lane</span>
                <span class="wk-kv-v mono">${g?.judgeLane?Wt(g.judgeLane):"판정 lane 확인 불가"}</span>
              </div>
            </div>
            ${s.item.summaryText&&i`<${F} class="wk-notice" text=${s.item.summaryText} />`}
            ${s.item.keyQuestions.length>0&&i`
              <ul class="wk-prose">
                ${s.item.keyQuestions.map((e,o)=>i`
                  <li key=${o}><${F} text=${e} /></li>
                `)}
              </ul>
            `}
            ${s.item.rationale&&i`<${F} class="wk-prose" text=${s.item.rationale} />`}
            ${s.item.inputPreview&&i`<pre class="wk-code-preview">${s.item.inputPreview}</pre>`}
            <div class="wk-field">
              <label for="gate-reject-reason">거절 사유 (Reject 시 필수)</label>
              <input
                id="gate-reject-reason"
                type="text"
                class="wk-input"
                value=${ye}
                onInput=${e=>Ie(e.target.value)}
              />
            </div>
            <label class="wk-check-label">
              <input
                type="checkbox"
                checked=${Oe}
                onChange=${e=>Ae(e.target.checked)}
              />
              동일 요청 규칙 기억하기 (remember_rule)
            </label>
            <${fe}
              target=${{workspaceId:ue,keeper:s.item.keeper,requestId:s.item.id,revision:s.item.sequence}}
              currentRevision=${J[s.key]??s.item.sequence}
              lockedEpoch=${a}
              onRefresh=${()=>{S("manual",["channel_gate"])}}
            >
              <button type="button" class="wk-btn-ok" disabled=${X} onClick=${()=>{Je(s.item,"approve")}}>
                승인 (Approve)
              </button>
              <button type="button" class="wk-btn-danger" disabled=${X} onClick=${()=>{Je(s.item,"reject")}}>
                거절 (Reject)
              </button>
            <//>
          `}

          ${s.kind==="goal_confirmation"&&i`
            <div class="wk-section-head">
              <div class="wk-min-w-0">
                <span class="wk-badge wk-badge--warn">Goal Confirmation</span>
                <h2 class="wk-heading">${s.goal.title}</h2>
              </div>
              ${!d&&i`
                <div class="wk-pane-status-slot" data-testid="goal-conf-evidence-slot">
                  ${K&&P?.kind==="loading"&&i`
                    <span class="wk-status-pill wk-status-pill--info" role="status" title="확인 근거 확인 중…">
                      <${ge} size="xs" />
                      <span class="wk-status-pill-text">증거 확인 중…</span>
                    </span>
                  `}
                  ${K&&P?.kind!=="loading"&&!ze&&i`
                    <span class="wk-status-pill wk-status-pill--warn" role="status" title="확인 근거 · 마지막 조회">
                      <span class="wk-status-pill-text">증거 · 마지막 조회</span>
                    </span>
                  `}
                </div>
              `}
              <div class="wk-actions">
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${()=>t.onNavigate(`/work/goals/${encodeURIComponent(s.goal.id)}`)}
                >
                  목표 상세로 이동 →
                </button>
              </div>
            </div>
            ${d&&i`<div class="wk-notice" role="note">이 연결에서는 Goal 목록과 상세를 열 수 있습니다.</div>`}
            ${!K&&P?.kind==="loading"&&i`
              <div class="wk-notice wk-notice--info" role="status"><${ge} /> 확인 근거 불러오는 중…</div>
            `}
            ${P?.kind==="failed"&&i`
              <div class="wk-notice wk-notice--err" role="alert">${P.reason}</div>
            `}
            ${K&&i`
              <${F} class="wk-prose" text=${K.evidence} />
              <${fe}
                target=${{workspaceId:ue,keeper:K.actor,requestId:K.requestId,revision:K.criterionRevision}}
                currentRevision=${J[s.key]??K.criterionRevision}
                lockedEpoch=${a}
                onRefresh=${()=>{E(v)?Re(s.goal.id,v,!0):S("manual",["goal_confirmation"])}}
              >
                <button type="button" class="wk-btn-ok" disabled=${X||!ze} onClick=${()=>{kt(K)}}>
                  목표 완료 최종 확정 (Confirm)
                </button>
              <//>
            `}
          `}
        </div>
      `:null;return i`
    <div class="wk-inbox-shell">
      ${Qe}
      ${$t}
      <div class="wk-pane-grow">
        <${Ht}
          master=${bt}
          detail=${_t}
          hasSelection=${s!==null}
          selectionKey=${Z}
          masterLabel="HITL 대기열"
          detailLabel="HITL 승인 상세"
          emptyDetail=${i`<div class="wk-detail-pad">${Ge}<span class="dtable-absent">승인할 항목을 선택하세요. 모든 결정은 TargetLockedAction으로 보호됩니다.</span></div>`}
        />
      </div>
    </div>
  `}export{Ca as InboxTab,na as decodeGatePayload,Zt as decodeToolApprovals,oa as gateDispositionText,et as gatePhaseLabel,ia as toolApprovalTimeoutText};
