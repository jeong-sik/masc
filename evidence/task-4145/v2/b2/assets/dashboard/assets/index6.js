import{n as ge,d as le,A as ye,y as ee,q as xe,T as B,m as u}from"./vendor.js";import{d as we,a as Se,i as Ce,f as Ae,c as Me,p as Te,g as Ke}from"./keeper-state.js";import{a as pe,z as C,W as P,l as Pe,A as q,T as ie,V as Ee,an as Ie,X as W,ao as ue,ap as Re,aq as Y,_ as te,s as Ne,C as Fe,M as qe,L as We,F as O,Y as ce,K as Ge,D as Ue}from"./index.js";import{K as se}from"./core.js";import{R as Oe}from"./refresh-button.js";import{U as Le}from"./uplot-chart.js";import{b as De,a as je}from"./hitl-decoders.js";import{g as ze,G as Be}from"./dashboard-goals.js";import{i as Ve}from"./type-guards.js";import{d as He}from"./turn-context.js";import{d as _e}from"./format-time.js";import{i as Qe}from"./quota-window.js";import"./format-string.js";function Ze(e){return Ve(e)?e.state==="ready"&&Object.keys(e).length===1?{state:"ready"}:e.state==="unavailable"&&e.code==="reset_required"&&typeof e.title=="string"&&e.title.trim()!==""&&typeof e.operator_detail=="string"&&e.operator_detail.trim()!==""&&e.severity==="bad"&&e.icon==="!"&&Object.keys(e).length===6?{state:"unavailable",code:"reset_required",title:e.title.trim(),operator_detail:e.operator_detail.trim(),severity:"bad",icon:"!"}:null:null}function b(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function _(e){return typeof e=="string"&&e.trim().length>0?e.trim():null}function p(e){return typeof e=="number"&&Number.isFinite(e)?e:null}function Xe(e){const s=b(e)?e:{},a=b(s.counts)?s.counts:{},t=b(s.scorecard_24h)?s.scorecard_24h:{},n=b(s.status)?s.status:{},d=Array.isArray(s.groups)?s.groups:[],i=[];for(const o of d){if(!b(o))continue;const l=_(o.group);if(!l)continue;const c=Array.isArray(o.keepers)?o.keepers.filter(f=>typeof f=="string"&&f.trim().length>0):[];i.push({group:l,keeper_count:p(o.keeper_count)??c.length,keepers:c})}return{generated_at:_(s.generated_at),project:_(n.project)??_(s.project),version:_(n.version)??_(s.version),counts:{agents:p(a.agents),tasks:p(a.tasks),tasks_done_24h:p(a.tasks_done_24h),keepers:p(a.keepers),configured_keepers:p(s.configured_keepers)??p(a.configured_keepers),total_runtimes:p(a.total_runtimes)},scorecard:{tasks_done_24h:p(t.tasks_done_24h),tasks_awaiting_verification:p(t.tasks_awaiting_verification),tasks_in_progress:p(t.tasks_in_progress),turns_24h:p(t.turns_24h),cost_24h_usd:p(t.cost_24h_usd),verifications_passed_24h:p(t.verifications_passed_24h),verifications_rejected_24h:p(t.verifications_rejected_24h),goals_completed_24h:p(t.goals_completed_24h)},groups:i}}function Ye(e){return He(e,{requireStartsAt:!0})}function Je(e){const s=b(e)?e:{},a=Array.isArray(s.keepers)?s.keepers:[],t=[];for(const n of a){if(!b(n))continue;const d=_(n.name);if(!d)continue;const i=b(n.meta)?n.meta:null,o=b(n.effective_meta_error)?_(n.effective_meta_error.message):null,l=b(n.last_failure)?n.last_failure:null,c=l&&_(l.cause)?{cause:_(l.cause),at_unix:p(l.at_unix)}:null,f=typeof n.candle_balance_milli=="string"||typeof n.candle_balance_milli=="number"?n.candle_balance_milli:null,A=_(n.context_provenance),K=A==="measured"||A==="estimated"||A==="unavailable"?A:null;t.push({name:d,status:_(n.status)??"unknown",phase:_(n.phase)??(o?"error":"idle"),health:_(n.health)??(o?"failing":"unknown"),paused:n.paused===!0,keepalive_running:n.keepalive_running===!0,runtime_id:_(n.runtime_id)??"unassigned",sandbox_profile:i?_(i.sandbox_profile):null,context_ratio:p(n.context_ratio),context_tokens:p(n.context_tokens),context_max:p(n.context_max),context_provenance:K,estimated_context_ratio:p(n.estimated_context_ratio),context_unavailable_reason:_(n.context_metrics_unavailable_reason),next_action:_(n.next_action),runtime_blocker_summary:_(n.runtime_blocker_summary),runtime_blocker_signature:_(n.runtime_blocker_signature),runtime_blocker_class:_(n.runtime_blocker_class),runtime_path_rest:Se(n.runtime_path_rest),operator_disposition:_(n.operator_disposition),operator_disposition_reason:_(n.operator_disposition_reason),failing_since:p(n.failing_since),runtime_lane_failures:we(n.runtime_lane_observation),last_failure:c,recent_turns:Ye(n.recent_turns),candle_balance_milli:f,directory_issue:o})}return t}function et(e){const s=b(e)?e:{},a=Array.isArray(s.keepers)?s.keepers:[],t=[];for(const n of a){if(!b(n))continue;const d=_(n.keeper_name);d&&t.push({keeper_name:d,total_cost_usd:p(n.total_cost_usd),cost_reported_samples:p(n.cost_reported_samples)??0,cost_unreported_samples:p(n.cost_unreported_samples)??0,total_tokens:p(n.total_tokens),sample_count:p(n.sample_count)??0})}return t}function tt(e){switch(e.unit){case"fraction":{const s=p(e.value);return s===null?null:{unit:"fraction",value:s}}case"percent":{const s=p(e.value);return s===null?null:{unit:"percent",value:s}}case"usd":{const s=p(e.value);return s===null||e.limit!==null&&e.limit!==void 0&&p(e.limit)===null?null:{unit:"usd",value:s,limit:p(e.limit)}}case"credit_balance":{const s=p(e.remaining);return s===null?null:{unit:"credit_balance",remaining:s}}case"credit_unlimited":return{unit:"credit_unlimited"};default:return null}}function st(e){if(!b(e))return null;const s=_(e.scope_id),a=_(e.source),t=_(e.kind),n=p(e.observed_at),d=tt(e);return!s||!a||!t||n===null||!d||e.resets_at!==null&&e.resets_at!==void 0&&p(e.resets_at)===null?null:{scope_id:s,source:a,kind:t,limit_id:_(e.limit_id),observed_at:n,resets_at:p(e.resets_at),utilization:d}}function nt(e){if(!b(e))return{state:"unavailable",reason:"invalid_provider_usage"};if(e.state==="unavailable")return{state:"unavailable",reason:_(e.reason)??"provider usage unavailable"};if(!Array.isArray(e.points))return{state:"unavailable",reason:"provider usage response has no points"};const s=[];let a=0;for(const n of e.points){const d=st(n);d?s.push(d):a+=1}const t=[];if(Array.isArray(e.reported_no_windows))for(const n of e.reported_no_windows){if(!b(n))continue;const d=_(n.scope_id),i=p(n.observed_at);d&&i!==null&&t.push({scope_id:d,observed_at:i})}return{state:"available",days:p(e.days)??1,points:s,reported_no_windows:t,undecodable_points:a}}function at(e){const s=[];for(const a of De(e))a.hasExplicitApprovalId&&s.push({approval_id:a.approvalId,keeper:a.keeper,tool_call_id:a.toolCallId,tool:a.tool,question:a.question,because:a.because===""?null:a.because,asked_at:a.askedAt,timeout_sec:a.timeoutSec});return s}function ot(e){const s=je(e);if(!s.ok)throw new Error(s.error);return s.asks.map(a=>({ask_id:a.askId,keeper:a.keeper,summary:a.promptSummary??"Keeper 응답 대기",created_at:a.askedAt,question_count:a.questionCount}))}function ve(e){if(!b(e))return null;const s=_(e.id),a=_(e.title);if(!s||!a)return null;const t=b(e.task_summary)?e.task_summary:null,n=b(e.verification)?e.verification:null,d=Array.isArray(e.linked_keeper_names)?e.linked_keeper_names.filter(c=>typeof c=="string"&&c.trim().length>0):[],i=Array.isArray(e.children)?e.children:[];let o=p(e.pending_approval_count)??0,l=0;for(const c of i){const f=ve(c);f&&(l+=1+f.sub_goal_count,o+=f.pending_approval_count)}return{id:s,title:a,phase:_(e.phase),task_count:p(e.task_count)??p(t?.total)??0,task_done_count:p(e.task_done_count)??p(t?.done)??0,awaiting_verification_count:p(t?.awaiting_verification)??0,pending_approval_count:o,sub_goal_count:l,verification_status:n?_(n.status)??_(n.verdict):null,linked_keeper_names:d,updated_at:_(e.updated_at)}}function rt(e){const s=ze(e);if(s)throw new Be(s);if(!b(e))throw new Error("Goal 응답 형식이 잘못되었습니다.");const a=Ze(e.approval_queue_state);if(!a)throw new Error("Goal 응답의 approval_queue_state 를 읽지 못했습니다.");if(a.state==="unavailable")return{state:"approval_queue_unavailable",title:a.title,detail:a.operator_detail};if(!Array.isArray(e.tree))throw new Error("Goal 응답에서 목표 목록을 확인할 수 없습니다.");const t=[];for(const d of e.tree){const i=ve(d);i&&t.push(i)}const n=b(e.summary)?e.summary:null;return{state:"ready",goals:t,pending_approval_total:n?p(n.pending_approvals):null}}function lt(e){const s=b(e)?e:{},a=Array.isArray(s.posts)?s.posts:[],t=[];for(const n of a){if(!b(n))continue;const d=_(n.id),i=_(n.author)??_(n.agent_name);if(!d||!i)continue;const o=Array.isArray(n.mentions)?n.mentions.filter(f=>typeof f=="string"):[],l=b(n.meta)?n.meta:null,c=_(n.succession_parent_id)??(l?_(l.succession_parent_id):null);t.push({id:d,title:_(n.title)??"",body:_(n.body)??_(n.content)??"",author:i,hearth:_(n.hearth)??_(n.sub_board),created_at:_(n.created_at),reply_count:p(n.comment_count)??p(n.reply_count)??0,mentions:o,succession_parent_id:c})}return t}function it(e){if(!b(e))throw new Error("World Memory 응답 형식이 잘못되었습니다.");if(e.ledger_state!=="available"&&e.ledger_state!=="missing")throw new Error("World Memory ledger_state 값을 확인할 수 없습니다.");const s=b(e.inventory)?e.inventory:{},a=b(e.world_mvcc)?e.world_mvcc:null,t=b(e.briefing)?e.briefing:{};return{source:_(e.source),ledger_state:e.ledger_state,claims_count:p(s.claims_count)??0,facts_count:p(s.facts_count)??0,conflicts_count:p(s.conflicts_count)??0,briefing_status:_(t.status)??"absent",briefing_text:_(t.text),wiki_count:a?p(a.wiki_count):null,artifact_count:a?p(a.artifact_count):null}}function ut(e){if(!b(e))throw new Error("Candle 원장 응답 형식이 잘못되었습니다.");if(e.ledger_state!=="present"&&e.ledger_state!=="missing")throw new Error("Candle 원장 ledger_state 값을 확인할 수 없습니다.");const s=b(e.policy)?e.policy:{},a=b(s.half_life)?s.half_life:{},t=b(e.supply)?e.supply:{},n=s.configuration,d=n==="enabled"?"enabled":n==="disabled"?"disabled":"off",i=o=>typeof o=="string"&&o.trim().length>0?o.trim():typeof o=="number"&&Number.isFinite(o)?String(Math.trunc(o)):"0";return{ledger_state:e.ledger_state,total_events:p(e.total_events)??0,policy_configuration:d,disabled_reason:_(s.disabled_reason),pricing_mode:_(s.pricing_mode)??"off",half_life_hours:p(a.half_life_hours),issued_milli:i(t.issued_milli),burned_milli:i(t.burned_milli),circulating_milli:i(t.circulating_milli),active_keepers:p(t.active_keepers)??0}}const ct=1440,M={shell:"pulse:shell",keepers:"pulse:keepers",costs:"pulse:costs:24h",usage:e=>`pulse:usage:${e}`,approvals:"pulse:approvals",asks:"pulse:asks",goals:"pulse:goals",board:"pulse:board",worldMemory:"pulse:world-memory",candle:"pulse:candle"};function N(e){return e.then(s=>s.ok?Ee(s.value):s)}function dt(e){const s=pe.value.kind==="multi_account_signed_in";return{shell:C.observe(M.shell).value,keepers:s?P("multi_account_unbridged"):C.observe(M.keepers).value,costs:s?P("multi_account_unbridged"):C.observe(M.costs).value,usage:s?P("multi_account_unbridged"):C.observe(M.usage(e)).value,approvals:s?P("multi_account_unbridged"):C.observe(M.approvals).value,asks:s?P("multi_account_unbridged"):C.observe(M.asks).value,goals:C.observe(M.goals).value,board:C.observe(M.board).value,worldMemory:C.observe(M.worldMemory).value,candle:C.observe(M.candle).value}}const T={shell:["keeper","keeper_row_changed","keeper_roster_changed","task","goal","goal_projection_changed","shell"],keepers:["keeper","keeper_row_changed","keeper_roster_changed","keeper_turn_complete","provider_standing","keeper_turn","keeper_lifecycle"],costs:["keeper_turn","keeper_turn_complete","cost"],usage:["provider","provider_standing","provider_usage","quota"],approvals:["tool_approval","keeper_tool_approval_waits_changed","keeper_turn"],asks:["keeper_ask","keeper_asks_changed","ask"],goals:["goal","goals","goal_projection_changed","verification_requests","task"],board:["board","board_changed","board_post","board_comment"],worldMemory:["memory","world_memory"],candle:["candle","goal"]},pt=new Set([...T.shell,...T.keepers,...T.costs,...T.usage,...T.approvals,...T.asks,...T.goals,...T.board,...T.worldMemory,...T.candle]);async function _t(e,s="mount"){const a=pe.peek();if(!Pe(a))return;const t=Ie(e),n=a.kind==="multi_account_signed_in",d=ge(()=>[C.fetch(M.shell,i=>N(q("/api/v1/dashboard/shell",{signal:i,decode:Xe})),{ttlMs:15e3,topics:T.shell,reason:s}),n?Promise.resolve(P("multi_account_unbridged")):C.fetch(M.keepers,i=>N(q("/api/v1/gate/keepers?detailed=true",{signal:i,decode:Je})),{ttlMs:12e3,topics:T.keepers,reason:s}),n?Promise.resolve(P("multi_account_unbridged")):C.fetch(M.costs,i=>N(q(`/api/v1/dashboard/keeper-costs?window=${ct}`,{signal:i,decode:et})),{ttlMs:3e4,topics:T.costs,reason:s}),n?Promise.resolve(P("multi_account_unbridged")):C.fetch(M.usage(e),i=>N(q(`/api/v1/dashboard/provider-usage-history?days=${t}`,{signal:i,decode:nt})),{ttlMs:6e4,topics:T.usage,reason:s}),n?Promise.resolve(P("multi_account_unbridged")):C.fetch(M.approvals,i=>N(q("/api/v1/keepers/tool-approvals",{signal:i,decode:at})),{ttlMs:1e4,topics:T.approvals,reason:s}),n?Promise.resolve(P("multi_account_unbridged")):C.fetch(M.asks,i=>N(q("/api/v1/keepers/asks?include_resolved=false",{signal:i,decode:ot})),{ttlMs:1e4,topics:T.asks,reason:s}),C.fetch(M.goals,i=>N(q("/api/v1/dashboard/goals",{signal:i,decode:rt})),{ttlMs:2e4,topics:T.goals,reason:s}),C.fetch(M.board,i=>N(q("/api/v1/dashboard/board?sort_by=recent&limit=24&exclude_system=true",{signal:i,decode:lt})),{ttlMs:2e4,topics:T.board,reason:s}),C.fetch(M.worldMemory,i=>N(ie("/api/v1/memory/world",{signal:i,decode:it})),{ttlMs:3e4,topics:T.worldMemory,reason:s}),C.fetch(M.candle,i=>N(ie("/api/v1/candle/ledger?limit=20",{signal:i,decode:ut})),{ttlMs:3e4,topics:T.candle,reason:s})]);await Promise.all(d)}function vt(e,s){const a=Qe(e.utilization);return a===null?{kind:"no_limit"}:a?e.resets_at===null?{kind:"spent_reset_unknown",observedAt:e.observed_at}:e.resets_at>s?{kind:"exhausted",resetsAt:e.resets_at}:e.observed_at>=e.resets_at?{kind:"spent_reset_unknown",observedAt:e.observed_at}:{kind:"reset_since_report",resetsAt:e.resets_at}:{kind:"room_left"}}function ft(e){const s=e.limit_id===null?"null":`${e.limit_id.length}:${e.limit_id}`;return`${e.scope_id.length}:${e.scope_id}|${e.kind.length}:${e.kind}|${s}`}function kt(e){const s=new Map;for(const t of e.points){const n=ft(t),d=s.get(n);(!d||t.observed_at>d.observed_at)&&s.set(n,t)}const a=new Map;for(const t of e.reported_no_windows){const n=a.get(t.scope_id);(n===void 0||t.observed_at>n)&&a.set(t.scope_id,t.observed_at)}return[...s.values()].filter(t=>{const n=a.get(t.scope_id);return n===void 0||n<=t.observed_at})}function mt(e,s){let a=0,t=null,n=0,d=0;if(e.kind==="value"&&e.data.state==="available")for(const i of kt(e.data)){const o=vt(i,s),l=i.utilization.unit;switch(o.kind){case"exhausted":a+=1,t=t===null?o.resetsAt:Math.min(t,o.resetsAt);break;case"spent_reset_unknown":n+=1;break;case"room_left":case"reset_since_report":(l==="fraction"||l==="percent"||l==="credit_unlimited")&&(d+=1);break}}return{exhausted:a,nextReturnAt:t,spentResetUnknown:n,subscription:d}}function ne(e,s){const a=[];return e.exhausted>0&&(a.push(`한도 소진 ${e.exhausted}`),e.nextReturnAt!==null&&a.push(`${_e(e.nextReturnAt-s)} 복귀`)),e.spentResetUnknown>0&&a.push(`소진(복귀 시각 미확인) ${e.spentResetUnknown}`),a.join(" · ")}const ht=1800,de=/@([a-zA-Z0-9_-]{2,48})/g;function G(e){if(!Number.isFinite(e))return{short:"0",exact:"0"};const s=Math.round(e).toLocaleString("en-US"),a=Math.abs(e),t=e<0?"-":"";if(a>=1e9){const n=a/1e9;return{short:`${t}${J(n.toFixed(n>=100?0:1))}B`,exact:s}}if(a>=1e6){const n=a/1e6;return{short:`${t}${J(n.toFixed(n>=100?0:1))}M`,exact:s}}if(a>=1e3){const n=a/1e3;return{short:`${t}${J(n.toFixed(n>=100?0:1))}k`,exact:s}}return{short:`${t}${Math.round(a)}`,exact:s}}function J(e){return e.endsWith(".0")?e.slice(0,-2):e}function bt(e){if(!Number.isFinite(e))return"$0.00";const s=Math.abs(e),a=e<0?"-":"";return s>=1e3?`${a}$${J((s/1e3).toFixed(1))}k`:s>=100?`${a}$${s.toFixed(1)}`:`${a}$${s.toFixed(2)}`}function $t(e){return Ae(e)}function gt(e){if(typeof e.context_ratio=="number"&&Number.isFinite(e.context_ratio)){const s=Math.max(0,Math.min(100,Math.round(e.context_ratio*100)));return W(s)}if(e.context_provenance==="estimated"&&typeof e.estimated_context_ratio=="number"&&Number.isFinite(e.estimated_context_ratio)){const s=Math.max(0,Math.min(100,Math.round(e.estimated_context_ratio*100)));return W(s)}return e.context_unavailable_reason?P(e.context_unavailable_reason):P()}function Q(e){if(e.runtime_path_rest?.status!=="resting"||e.paused||!e.keepalive_running)return!1;const s=e.health.toLowerCase(),a=e.phase.toLowerCase();return s!=="offline"&&a!=="offline"&&a!=="stopped"&&a!=="paused"}function ae(e){if(e.paused||Z(e)||Q(e))return!1;const s=e.health.toLowerCase(),a=e.phase.toLowerCase(),t=e.status.toLowerCase();return s==="failing"||s==="failed"||s==="offline"||a==="stopped"||a==="paused"||a==="offline"||a==="crashed"||a==="failing"?!1:e.keepalive_running||s==="healthy"||s==="working"||s==="idle"||t==="running"||t==="active"}function Z(e){return Ce(e)}function yt(e,s,a,t){const n=mt(s,t);if(e.kind==="value"){const d=e.data;let i=0,o=0,l=0;for(const c of d)o+=c.cost_reported_samples,l+=c.cost_unreported_samples,c.total_cost_usd!==null&&(i+=c.total_cost_usd);if(o>0&&i>0)return{kind:"reported",usd:i,quota:n,unreportedCount:l};if(n.exhausted>0&&i===0)return{kind:"exhausted_zero",quota:n};if((n.subscription>0||l>0)&&i===0)return n.subscription>0?{kind:"subscription_zero",quota:n}:{kind:"unreported",reason:`${l}건 비용 미보고 (구독/로컬 레인)`};if(o>0)return{kind:"reported",usd:0,quota:n,unreportedCount:l};if(d.length===0&&a===null)return{kind:"absent"}}return a!==null&&Number.isFinite(a)?a===0&&n.exhausted>0?{kind:"exhausted_zero",quota:n}:a===0&&n.subscription>0?{kind:"subscription_zero",quota:n}:{kind:"reported",usd:a,quota:n,unreportedCount:0}:s.kind==="value"&&s.data.state==="unavailable"?{kind:"unreported",reason:s.data.reason}:{kind:"unreported",reason:"비용 원장 미보고"}}function xt(e){const{shell:s,keepers:a,costs:t,usage:n,window:d,nowSec:i}=e;let o;if(a.kind==="value"){const v=a.data.length;let k=0,y=0,m=0;for(let U=0;U<v;U++){const L=a.data[U];Z(L)?y+=1:Q(L)?m+=1:ae(L)&&(k+=1)}const S=s.kind==="value"?s.data.counts.configured_keepers:null,E=S!==null&&S>v?S:v,I=[];y>0&&I.push(`${y} 주의 필요`),m>0&&I.push(`${m} 경로 휴식`),I.length===0&&I.push(`${v-k} 대기/정지`),o={id:"active_keepers",label:"Active Keepers",value:W(`${k} / ${E}`),exactTooltip:`실행 중 ${k} · 전체 ${v}${S!==null?` · 설정 ${S}`:""}${y>0?` · 주의 ${y}`:""}${m>0?` · 경로 휴식 ${m}`:""}`,secondary:I.join(" · "),tone:y>0||m>0?"warn":k>0?"ok":"default",route:"/keepers"}}else a.kind==="loading"?o={id:"active_keepers",label:"Active Keepers",value:Y(),exactTooltip:null,secondary:null,tone:"default",route:"/keepers"}:o={id:"active_keepers",label:"Active Keepers",value:a.kind==="failed"?a:P(),exactTooltip:null,secondary:null,tone:a.kind==="failed"?"bad":"default",route:"/keepers"};let l;if(s.kind==="value"){const v=s.data.scorecard.tasks_done_24h??s.data.counts.tasks_done_24h,k=s.data.scorecard.tasks_awaiting_verification;if(v===null&&k===null)l={id:"tasks_24h",label:"Tasks Done / Verify",value:P(),exactTooltip:null,secondary:null,tone:"default",route:"/work/tasks"};else{const y=G(v??0),m=k!==null?G(k):null,S=s.data.scorecard.verifications_rejected_24h??0,E=[];E.push(m!==null?`검증 대기 ${m.short}`:"검증 대기 없음"),S>0&&E.push(`거절 ${S}`),l={id:"tasks_24h",label:"Tasks Done/24h & Verify",value:W(y.short),exactTooltip:`24h 완료 ${y.exact}건${m?` · 검증 대기 ${m.exact}건`:""}${S>0?` · 24h 거절 ${S}건`:""}`,secondary:E.join(" · "),tone:S>0?"bad":(k??0)>0?"warn":(v??0)>0?"ok":"default",route:"/work/tasks"}}}else s.kind==="loading"?l={id:"tasks_24h",label:"Tasks Done/24h & Verify",value:Y(),exactTooltip:null,secondary:null,tone:"default",route:"/work/tasks"}:l={id:"tasks_24h",label:"Tasks Done/24h & Verify",value:s.kind==="failed"?s:P(),exactTooltip:null,secondary:null,tone:s.kind==="failed"?"bad":"default",route:"/work/tasks"};let c=null,f=null;if(s.kind==="value"&&s.data.scorecard.turns_24h!==null)c=s.data.scorecard.turns_24h;else if(a.kind==="value"){let v=0,k=!1;for(const y of a.data)if(y.recent_turns){k=!0;for(const m of y.recent_turns.slots)v+=m.ok+m.rested+m.failed}k&&(c=v)}if(t.kind==="value"){let v=0,k=!1;for(const y of t.data)y.total_tokens!==null&&(v+=y.total_tokens,k=!0);k&&(f=v)}const A=c===null&&(s.kind==="loading"||a.kind==="loading")?{id:"turns_24h",label:"Turns / 24h",value:Y(),exactTooltip:null,secondary:null,tone:"default",route:"/runtime/efficiency"}:c===null&&s.kind==="failed"&&a.kind==="failed"?{id:"turns_24h",label:"Turns / 24h",value:ue(s.error),exactTooltip:s.error.message,secondary:"조회 실패",tone:"bad",route:"/runtime/efficiency"}:c===null?{id:"turns_24h",label:"Turns / 24h",value:P(),exactTooltip:null,secondary:null,tone:"default",route:"/runtime/efficiency"}:(()=>{const v=G(c),k=f!==null?G(f):null;return{id:"turns_24h",label:"Turns / 24h",value:W(v.short),exactTooltip:`24h 턴 ${v.exact}${k?` · 24h 토큰 ${k.exact}`:""}`,secondary:k?`${k.short} tokens`:"토큰 미보고",tone:"brass",route:"/runtime/efficiency"}})(),K=s.kind==="value"?s.data.scorecard.cost_24h_usd:null,$=yt(t,n,K,i),h=d==="24h"?"":` (비용 24h · 쿼터 ${d==="7d"?"7d":"14d"})`;let w;if(($.kind==="absent"||$.kind==="unreported")&&(t.kind==="loading"||s.kind==="loading"||n.kind==="loading"))w={id:"spend_24h",label:"Spend / 24h",value:Y(),exactTooltip:null,secondary:null,tone:"default",route:"/runtime/quotas"};else if(t.kind==="failed"&&s.kind==="failed"&&n.kind!=="value")w={id:"spend_24h",label:"Spend / 24h",value:ue(t.error),exactTooltip:t.error.message,secondary:`조회 실패${h}`,tone:"bad",route:"/runtime/quotas"};else switch($.kind){case"reported":{const v=ne($.quota,i);w={id:"spend_24h",label:"Spend / 24h",value:W(bt($.usd)),exactTooltip:`24h 정확한 비용 $${$.usd.toFixed(4)} · 구독 레인 ${$.quota.subscription} · 미보고 ${$.unreportedCount}${v?` · ${v}`:""}${h}`,secondary:v?`${v}${h}`:$.quota.subscription>0?`구독 ${$.quota.subscription} 병행${h}`:$.unreportedCount>0?`? 미보고 ${$.unreportedCount} 포함${h}`:`API 과금 측정${h}`,tone:v?"warn":"default",route:"/runtime/quotas"};break}case"subscription_zero":{const v=ne($.quota,i);w={id:"spend_24h",label:"Spend / 24h",value:W("$0 Sub"),exactTooltip:`구독 플랜 레인 ${$.quota.subscription}개 활성 (24h API 직접 과금 $0.00)${v?` · ${v}`:""}${h}`,secondary:v?`구독 ${$.quota.subscription} · ${v}${h}`:`구독 플랜 ${$.quota.subscription}개 활성${h}`,tone:v?"warn":"ok",route:"/runtime/quotas"};break}case"exhausted_zero":{const v=ne($.quota,i);w={id:"spend_24h",label:"Spend / 24h",value:W("$0 Exhausted"),exactTooltip:`${v}${h}`,secondary:`${v}${h}`,tone:"bad",route:"/runtime/quotas"};break}case"unreported":w={id:"spend_24h",label:"Spend / 24h",value:Re($.reason),exactTooltip:`${$.reason}${h}`,secondary:`? Unreported${h}`,tone:"default",route:"/runtime/quotas"};break;case"absent":w={id:"spend_24h",label:"Spend / 24h",value:P(),exactTooltip:`24h 비용 기록 없음${h}`,secondary:`24h 기록 없음${h}`,tone:"default",route:"/runtime/quotas"};break}return[o,l,A,w]}function wt(e){const{approvals:s,asks:a,keepers:t,nowSec:n}=e,d=[];for(const o of s){const l=o.question||`call ${o.tool_call_id}`;d.push({id:`approval:${o.approval_id}`,kind:"approval",severity:"critical",keeper:o.keeper,title:`도구 승인 요청 · ${o.tool||"tool"}`,detail:o.because?`${l} · 보류 이유: ${o.because}`:l,ageSec:o.asked_at!==null?Math.max(0,Math.round(n-o.asked_at)):null,expiresInSec:o.asked_at!==null&&o.timeout_sec!==null?Math.round(o.asked_at+o.timeout_sec-n):null,route:"/work/inbox",raw:o})}for(const o of a)d.push({id:`ask:${o.ask_id}`,kind:"ask",severity:"warn",keeper:o.keeper,title:`Keeper 질문 (${o.question_count})`,detail:o.summary,ageSec:o.created_at!==null?Math.max(0,Math.round(n-o.created_at)):null,expiresInSec:null,route:"/work/inbox",raw:o});for(const o of t)if(Z(o)){const l=o.directory_issue??o.runtime_blocker_summary??(o.runtime_lane_failures&&o.runtime_lane_failures.length>0?o.runtime_lane_failures.map($=>`${$.runtime_id??"lane"}: ${$.summary}`).join(" → "):null)??(o.last_failure?`최근 실패: ${o.last_failure.cause}`:`상태: ${o.health}`),c=o.operator_disposition&&o.operator_disposition!=="pass"?o.operator_disposition:null,f=c?`${l} · 조치: ${c}`:l,A=o.failing_since??o.last_failure?.at_unix??null,K=A!=null?Math.max(0,Math.round(n-A)):null;d.push({id:`keeper:${o.name}`,kind:"keeper_failure",severity:o.health.toLowerCase()==="degraded"?"warn":"critical",keeper:o.name,title:`${o.name} · ${o.directory_issue?"설정 오류":o.health}`,detail:f,ageSec:K,expiresInSec:null,route:`/keepers/${encodeURIComponent(o.name)}/chat`,raw:o})}else if(Q(o)){const l=o.runtime_path_rest,c=`경로 휴식 (${l.runtime_id??o.runtime_id})${l.release_at?` · 해제 ${l.release_at}`:""}${l.release_basis?` · ${l.release_basis}`:""}`;d.push({id:`keeper-rest:${o.name}`,kind:"keeper_failure",severity:"warn",keeper:o.name,title:`${o.name} · 경로 휴식`,detail:c,ageSec:null,expiresInSec:null,route:`/keepers/${encodeURIComponent(o.name)}/chat`,raw:o})}const i={critical:0,warn:1,info:2};return d.sort((o,l)=>{const c=i[o.severity]-i[l.severity];return c!==0?c:(l.ageSec??0)-(o.ageSec??0)})}function St(e,s){const a=s.get(e);return a&&a.trim()?a.trim():"General"}function Ct(e,s,a){const t=ht,n=48,i=Math.floor(a/t)*t-(n-1)*t;let o=null;for(const h of e){if(!h.recent_turns)continue;const w=h.recent_turns.known_since;(o===null||w<o)&&(o=w)}const l=new Array(n),c=new Array(n);for(let h=0;h<n;h+=1){const w=i+h*t;l[h]=w;const v=o!==null&&w+t>o;c[h]=v?0:null}let f=0,A=0,K=0,$=0;for(let h=0;h<e.length;h+=1){const w=e[h].recent_turns;if(!w)continue;const v=w.slots;for(let k=0;k<v.length;k+=1){const y=v[k],m=Math.floor((y.starts_at-i)/t);if(!(m>=0&&m<n))continue;const S=y.ok+y.rested+y.failed;c[m]=(c[m]??0)+S,f+=S,A+=y.ok,K+=y.rested,$+=y.failed}}return{aligned:[l,c],totalTurns:f,okTurns:A,restedTurns:K,failedTurns:$}}function At(e){const{keepers:s,shellGroups:a,window:t,nowSec:n}=e,d=new Map;for(const l of a)for(const c of l.keepers)d.set(c,l.group);const i=new Map;for(const l of s){const c=St(l.name,d),f=i.get(c)??[];f.push(l),i.set(c,f)}const o=[];for(const[l,c]of i.entries()){const f=[...c].sort((m,S)=>m.name.localeCompare(S.name)),{aligned:A,totalTurns:K,okTurns:$,restedTurns:h,failedTurns:w}=Ct(f,t,n);let v=0,k=0,y=0;for(let m=0;m<f.length;m+=1){const S=f[m];Z(S)?k+=1:Q(S)?y+=1:ae(S)&&(v+=1)}o.push({company:l,keepers:f,activeCount:v,failingCount:k,restingCount:y,turnsInWindow:K,okTurnsInWindow:$,restedTurnsInWindow:h,failedTurnsInWindow:w,sparklineData:A,window:"24h"})}return o.sort((l,c)=>l.company==="General"&&c.company!=="General"?1:c.company==="General"&&l.company!=="General"?-1:c.activeCount!==l.activeCount?c.activeCount-l.activeCount:l.company.localeCompare(c.company))}function Mt(e,s,a=8){const t=new Set(s.map(i=>i.name)),n=[],d=(i,o,l)=>{if(i.indexOf("@")===-1)return;de.lastIndex=0;let c;for(;(c=de.exec(i))!==null;){const f=c[1];f&&f!==o&&(t.size===0||t.has(f))&&l.add(f)}};for(const i of e){if(n.length>=a)break;const o=new Set;for(const A of i.mentions)A&&A!==i.author&&o.add(A);d(i.title,i.author,o),d(i.body,i.author,o);const l=[...o],f=i.succession_parent_id!==null?"succession":l.length>0?"handoff":"collab";f==="collab"&&i.reply_count===0&&!t.has(i.author)||n.push({id:i.id,fromKeeper:i.author,toKeepers:l.slice(0,3),kind:f,title:i.title||i.body.slice(0,72),hearth:i.hearth,replyCount:i.reply_count,createdAt:i.created_at,route:`/knowledge/board/${encodeURIComponent(i.id)}`})}return n}function Tt(e){return e>0?`${_e(e)} 만료`:"만료 시각 지남"}function Kt(e){return e===null||!Number.isFinite(e)?"없음":e<60?`${Math.max(0,Math.round(e))}s`:e<3600?`${Math.floor(e/60)}m`:e<86400?`${Math.floor(e/3600)}h`:`${Math.floor(e/86400)}d`}const Pt=[{label:"Turns",colorToken:"--brass-1",width:1.75,fillAlpha:.16}];function Et(e){return typeof e=="object"&&e!==null&&typeof e.name=="string"}function It(e){const s=e.runtime_lane_failures??[],a=e.runtime_blocker_summary!=null,t=e.runtime_path_rest!=null,n=e.directory_issue!=null,d=s.length>0,i=e.last_failure!=null,o=a||t||n||d||i;return u`
    <div class="pulse-keeper-error">
      <div class="pulse-kv-grid">
        <div class="pulse-kv">
          <span class="pulse-kv-k">Keeper</span>
          <span class="pulse-kv-v">${e.name}</span>
        </div>
        <div class="pulse-kv">
          <span class="pulse-kv-k">health / phase</span>
          <span class="pulse-kv-v">${e.health} / ${e.phase}</span>
        </div>
        <div class="pulse-kv">
          <span class="pulse-kv-k">status</span>
          <span class="pulse-kv-v">${e.status}</span>
        </div>
        <div class="pulse-kv">
          <span class="pulse-kv-k">runtime</span>
          <span class="pulse-kv-v">${e.runtime_id}</span>
        </div>
      </div>
      ${o?u`
          <div class="pulse-keeper-error-body">
            ${e.runtime_blocker_summary&&u`
              <div class="pulse-keeper-error-row">
                <strong>차단 사유</strong>: ${e.runtime_blocker_summary}
                ${e.runtime_blocker_signature?u` <span class="mono">(${e.runtime_blocker_signature})</span>`:null}
                ${e.runtime_blocker_class?u` <span class="mono">[${e.runtime_blocker_class}]</span>`:null}
              </div>
            `}
            ${e.runtime_path_rest&&u`
              <div class="pulse-keeper-error-row">
                <strong>경로 휴식</strong>: ${e.runtime_path_rest.runtime_id??e.runtime_id}
                ${e.runtime_path_rest.release_at?` · 해제 ${e.runtime_path_rest.release_at}`:""}
                ${e.runtime_path_rest.release_basis?` (${e.runtime_path_rest.release_basis})`:""}
              </div>
            `}
            ${e.directory_issue&&u`
              <div class="pulse-keeper-error-row"><strong>설정 오류</strong>: ${e.directory_issue}</div>
            `}
            ${e.last_failure&&u`
              <div class="pulse-keeper-error-row">
                <strong>최근 실패</strong>: ${e.last_failure.cause}
                ${e.last_failure.at_unix!=null?u` <span class="mono">(@${e.last_failure.at_unix})</span>`:null}
              </div>
            `}
            ${d&&u`
              <div class="pulse-keeper-error-row">
                <strong>폴백 시도</strong>:
                <div class="pulse-keeper-lane-list">
                  ${s.map((l,c)=>u`
                    <div class="pulse-keeper-lane" key=${`${l.runtime_id??"lane"}:${l.attempt??c}:${l.summary}`}>
                      <div>
                        <span class="mono">${l.runtime_id??"lane"}${l.fault_kind?`[${l.fault_kind}]`:""}${l.dispatch?` · ${l.dispatch}`:""}${l.attempt!=null?` · attempt ${l.attempt}`:""}</span>
                      </div>
                      <div>${l.summary}</div>
                      ${l.failure_kind||l.failure_detail||l.provider||l.network_kind?u`
                          <div class="pulse-keeper-lane-meta">
                            ${l.failure_kind?u`<span>kind:${l.failure_kind}</span>`:null}
                            ${l.provider?u`<span>provider:${l.provider}</span>`:null}
                            ${l.network_kind?u`<span>network:${l.network_kind}</span>`:null}
                            ${l.failure_detail?u`<span class="mono">${l.failure_detail}</span>`:null}
                          </div>
                        `:null}
                    </div>
                  `)}
                </div>
              </div>
            `}
            ${e.operator_disposition&&e.operator_disposition!=="pass"||e.next_action?u`
                <div class="pulse-keeper-error-row">
                  ${e.operator_disposition&&e.operator_disposition!=="pass"?u`<span><strong>조치</strong>: ${e.operator_disposition}${e.operator_disposition_reason?` (${e.operator_disposition_reason})`:""}</span>`:null}
                  ${e.next_action?u`<span><strong>다음 단계</strong>: ${e.next_action}</span>`:null}
                </div>
              `:null}
          </div>
        `:u`<div class="pulse-empty">표시할 오류 상세 없음 (summary/signature/lane/last_failure 모두 없음)</div>`}
    </div>
  `}function Rt(e){const s=Te(e);if(s===null)return"default";switch(Ke(s)){case"ok":return"ok";case"info":return"info";case"stalled":return"brass";case"warn":return"warn";case"err":return"bad";case"idle":return"default"}}function Nt(e){if(e.kind!=="value")return"default";const s=Me(e.data);return s==="absent"?"default":s}function Qt(e){const s=te.value,a=Ne.value,t=dt(s),[n,d]=le(()=>Math.floor(Date.now()/1e3)),[i,o]=le(()=>new Set),l=ye(!0);ee(()=>(l.current=!0,()=>{l.current=!1}),[]);const c=xe(async r=>{const x=ce(),F=te.peek();await _t(F,r),!(!l.current||ce()!==x||te.peek()!==F)&&(d(Math.floor(Date.now()/1e3)),Ge())},[]);ee(()=>{c("mount")},[s,a,c]),ee(()=>{let r=null;const x=Fe(j=>{const V=Ue(j);let g=!1;for(let R=0;R<V.length;R++)if(pt.has(V[R])){g=!0;break}g&&(r||(r=setTimeout(()=>{r=null,c("sse")},450)))}),F=qe(()=>{c("sse")}),X=We(()=>{C.invalidateAll(),c("sse")});return()=>{x(),F(),X(),r&&clearTimeout(r)}},[c]);const f=n,A=B(()=>xt({shell:t.shell,keepers:t.keepers,costs:t.costs,usage:t.usage,window:s,nowSec:f}),[t.shell,t.keepers,t.costs,t.usage,s,f]),K=t.keepers.kind==="value"?t.keepers.data:[],$=B(()=>new Set(K.map(r=>r.name)),[K]),h=B(()=>wt({approvals:t.approvals.kind==="value"?t.approvals.data:[],asks:t.asks.kind==="value"?t.asks.data:[],keepers:K,nowSec:f}),[t.approvals,t.asks,K,f]),w=B(()=>At({keepers:K,shellGroups:t.shell.kind==="value"?t.shell.data.groups:[],window:s,nowSec:f}),[K,t.shell,s,f]),v=B(()=>Mt(t.board.kind==="value"?t.board.data:[],K,8),[t.board,K]),k=t.goals.kind==="value"?t.goals.data:null,y=B(()=>k===null||k.state!=="ready"?[]:k.goals.filter(r=>{const x=r.phase?.toLowerCase()??null;return x!=="completed"&&x!=="dropped"}).slice(0,6),[k]),m=t.candle.kind==="value"?t.candle.data:null,S=m!==null&&m.policy_configuration==="enabled"&&(m.total_events>0||m.circulating_milli!=="0"),E=[];t.approvals.kind==="failed"&&E.push(`도구 승인 조회 실패: ${t.approvals.error.message}`),t.asks.kind==="failed"&&E.push(`Keeper 질문 조회 실패: ${t.asks.error.message}`),t.keepers.kind==="failed"&&E.push(`Keeper 상태 조회 실패: ${t.keepers.error.message}`);const I=[];(t.approvals.kind==="absent"||t.approvals.kind==="unreported")&&I.push(t.approvals.kind==="absent"&&t.approvals.reason==="multi_account_unbridged"?"도구 승인 (멀티 계정 미지원)":"도구 승인 (미확인)"),(t.asks.kind==="absent"||t.asks.kind==="unreported")&&I.push(t.asks.kind==="absent"&&t.asks.reason==="multi_account_unbridged"?"Keeper 질문 (멀티 계정 미지원)":"Keeper 질문 (미확인)"),(t.keepers.kind==="absent"||t.keepers.kind==="unreported")&&I.push(t.keepers.kind==="absent"&&t.keepers.reason==="multi_account_unbridged"?"Keeper 상태 (멀티 계정 미지원)":"Keeper 상태 (미확인)");const U=t.approvals.kind==="loading"||t.asks.kind==="loading"||t.keepers.kind==="loading",L=t.approvals.kind==="value"&&t.approvals.stale||t.asks.kind==="value"&&t.asks.stale||t.keepers.kind==="value"&&t.keepers.stale,fe=E.length>0?"bad":h.length>0||I.length>0?"warn":U?"info":"ok",ke=E.length>0?"조회 오류":I.length>0?h.length>0?`${h.length}건 · 일부 미확인`:"일부 미확인":U&&h.length===0?"확인 중":`${h.length}건`,D=t.worldMemory.kind==="value"?t.worldMemory.data:null;return u`
    <div class="pulse-root" data-workspace="pulse">
      <header class="pulse-header">
        <div class="pulse-header-title">
          <span class="ov-eyebrow">1 PULSE · OPERATIONS OVERVIEW</span>
          <h1>Fleet Pulse</h1>
        </div>
        <div class="pulse-header-meta">
          <${Oe} onRefresh=${()=>c("manual")} />
        </div>
      </header>

      <!-- 4-KPI Hero Strip -->
      <section class="pulse-kpis" aria-label="핵심 지표">
        ${A.map(r=>{const x=O(r.value),F=r.value.kind==="absent"||r.value.kind==="unreported";return u`
            <button
              key=${r.id}
              type="button"
              class="pulse-kpi"
              data-kpi-id=${r.id}
              title=${r.exactTooltip??x}
              onClick=${()=>e.onNavigate(r.route)}
            >
              <span class="pulse-kpi-label">${r.label}</span>
              <span
                class="pulse-kpi-value tnum"
                data-tone=${r.tone}
                data-absent=${F?"true":"false"}
              >
                ${x}
              </span>
              <span class="pulse-kpi-sub">${r.secondary??"상세 보기 →"}</span>
            </button>
          `})}
      </section>

      <div class="pulse-grid">
        <div class="pulse-col">
          <!-- Company Fleet 24h Sparklines -->
          <section class="pulse-card" aria-label="회사별 Keeper 플릿">
            <div class="pulse-card-head">
              <div class="pulse-card-title-group">
                <h2>Company Fleet · 24h Activity</h2>
                <span class="pulse-pill" data-tone="warn" data-stale=${t.keepers.kind==="value"&&t.keepers.stale?"true":"false"} aria-hidden=${t.keepers.kind==="value"&&t.keepers.stale?void 0:"true"}>지연됨</span>
              </div>
              <button type="button" class="btn-ghost" onClick=${()=>e.onNavigate("/keepers")}>
                전체 Keeper →
              </button>
            </div>
            ${t.keepers.kind==="loading"?u`<div class="pulse-empty">플릿 상태 불러오는 중…</div>`:t.keepers.kind==="failed"?u`<div class="ap-error" role="alert">플릿 조회 실패: ${t.keepers.error.message}</div>`:t.keepers.kind==="absent"&&t.keepers.reason==="multi_account_unbridged"?u`<div class="pulse-empty" data-testid="pulse-fleet-multi-account-unbridged" role="status">멀티 계정 모드에서는 로컬 Keeper 플릿을 조회하지 않습니다.</div>`:t.keepers.kind==="absent"||t.keepers.kind==="unreported"?u`<div class="pulse-empty">${O(t.keepers)}</div>`:w.length===0?u`<div class="pulse-empty">등록된 Keeper 없음</div>`:u`
                      <div class="pulse-fleet-groups">
                        ${w.map(r=>{const x=G(r.turnsInWindow),F=r.okTurnsInWindow??r.turnsInWindow,X=r.restedTurnsInWindow??0,j=r.failedTurnsInWindow??0,V=r.restingCount??0;return u`
                            <article key=${r.company} class="pulse-fleet-group">
                              <div class="pulse-fleet-group-head">
                                <span class="pulse-fleet-group-name">${r.company}</span>
                                <div class="pulse-header-meta">
                                  <span class="pulse-pill" data-tone=${r.activeCount>0?"ok":"default"}>
                                    ${r.activeCount}/${r.keepers.length} active
                                  </span>
                                  ${r.failingCount>0&&u`
                                    <span class="pulse-pill" data-tone="bad">
                                      ⚠ ${r.failingCount} fault
                                    </span>
                                  `}
                                  ${V>0&&u`
                                    <span class="pulse-pill" data-tone="warn">
                                      ⏸ ${V} rest
                                    </span>
                                  `}
                                  ${j>0&&u`
                                    <span class="pulse-pill" data-tone="bad" title=${`성공 ${F} · 휴식 ${X} · 실패 ${j}`}>
                                      ✕ ${G(j).short} fail
                                    </span>
                                  `}
                                  <span
                                    class="pulse-pill"
                                    data-tone="brass"
                                    title=${`24h 턴 총 ${x.exact} (성공 ${F} · 휴식 ${X} · 실패 ${j})`}
                                  >
                                    ${x.short} turns/24h
                                  </span>
                                </div>
                              </div>

                              <div class="pulse-keeper-grid">
                                ${r.keepers.map(g=>{const R=gt(g),z=g.context_ratio==null&&g.context_provenance==="estimated"&&g.estimated_context_ratio!=null,H=R.kind==="value"?`${z?"~":""}${R.data}%`:O(R,$e=>`${$e}%`),me=g.context_tokens!=null&&g.context_max!=null?`${g.context_tokens.toLocaleString("en-US")} / ${g.context_max.toLocaleString("en-US")} tok`:z?`추정 컨텍스트 (~${R.kind==="value"?R.data:"?"}%)`:g.context_unavailable_reason?`컨텍스트 미측정 (${g.context_unavailable_reason})`:"Context 비율",he=ae(g),oe=Z(g),be=!oe&&Q(g),re=oe?`⚠ ${g.runtime_blocker_summary??g.last_failure?.cause??g.directory_issue??g.health}`:be?`⏸ 휴식${g.runtime_path_rest?.runtime_id?` · ${g.runtime_path_rest.runtime_id}`:""}`:g.paused?"paused":g.phase;return u`
                                    <button
                                      key=${g.name}
                                      type="button"
                                      class="pulse-keeper-tile"
                                      title=${re}
                                      onClick=${()=>e.onNavigate(`/keepers/${encodeURIComponent(g.name)}/chat`)}
                                    >
                                      <div class="pulse-keeper-tile-left">
                                        <${se}
                                          id=${g.name}
                                          size="md"
                                          variant="sigil"
                                          portrait=${!0}
                                          beat=${he}
                                        />
                                        <div class="pulse-keeper-tile-meta">
                                          <span class="pulse-keeper-tile-name">${g.name}</span>
                                          <span class="pulse-keeper-tile-sub">
                                            ${re}
                                          </span>
                                        </div>
                                      </div>
                                      <span
                                        class="pulse-pill"
                                        data-ctx="true"
                                        data-tone=${Nt(R)}
                                        title=${me}
                                      >
                                        Ctx ${H}
                                      </span>
                                    </button>
                                  `})}
                              </div>

                              <details
                                class="ap-disclosure pulse-spark-disclosure"
                                data-testid="pulse-sparkline-disclosure"
                                open=${i.has(r.company)||void 0}
                                onToggle=${g=>{const R=g.currentTarget.open;o(z=>{if(z.has(r.company)===R)return z;const H=new Set(z);return R?H.add(r.company):H.delete(r.company),H})}}
                              >
                                <summary class="ap-disclosure-trigger">
                                  <span>추이 보기 · ${r.company} (${x.short} turns/24h)</span>
                                  <span aria-hidden="true">${i.has(r.company)?"▾":"▸"}</span>
                                </summary>
                                <div class="ap-disclosure-body">
                                  ${i.has(r.company)&&u`
                                    <div class="pulse-spark-wrap">
                                      <${Le}
                                        id=${`pulse-spark-${r.company}`}
                                        title=${`${r.company} · 24h 턴 추이`}
                                        data=${r.sparklineData}
                                        series=${Pt}
                                        height=${92}
                                        syncCrosshair=${!0}
                                        emptyLabel="해당 구간 턴 기록 없음"
                                      />
                                    </div>
                                  `}
                                </div>
                              </details>
                            </article>
                          `})}
                      </div>
                    `}
          </section>

          <!-- Multi-Keeper Team Handoff & Succession Strip (Zero Cytoscape) -->
          <section class="pulse-card" aria-label="팀 핸드오프 및 협업 펄스">
            <div class="pulse-card-head">
              <div class="pulse-card-title-group">
                <h2>Team Handoff & Succession Pulse</h2>
                <span class="pulse-pill" data-tone="warn" data-stale=${t.board.kind==="value"&&t.board.stale?"true":"false"} aria-hidden=${t.board.kind==="value"&&t.board.stale?void 0:"true"}>지연됨</span>
              </div>
              <button type="button" class="btn-ghost" onClick=${()=>e.onNavigate("/knowledge/board")}>
                Board 열기 →
              </button>
            </div>
            ${t.board.kind==="loading"?u`<div class="pulse-empty">Board 신호 불러오는 중…</div>`:t.board.kind==="failed"?u`<div class="ap-error" role="alert">Board 조회 실패: ${t.board.error.message}</div>`:v.length===0?u`<div class="pulse-empty">최근 다중 Keeper 핸드오프/승계 신호 없음</div>`:u`
                  <div class="pulse-handoff-list">
                    ${v.map(r=>u`
                      <button
                        key=${r.id}
                        type="button"
                        class="pulse-handoff-row"
                        onClick=${()=>e.onNavigate(r.route)}
                      >
                        <${se} id=${r.fromKeeper} size="sm" portrait=${$.has(r.fromKeeper)} />
                        ${r.toKeepers.length>0&&u`
                          <span class="pulse-handoff-arrow" aria-hidden="true">
                            ${r.kind==="succession"?"⇒":"→"}
                          </span>
                          ${r.toKeepers.map(x=>u`
                            <${se} key=${x} id=${x} size="sm" portrait=${$.has(x)} />
                          `)}
                        `}
                        <span class="pulse-handoff-title">${r.title}</span>
                        <span class="pulse-pill" data-tone=${r.kind==="succession"?"brass":"info"}>
                          ${r.kind==="succession"?"Succession":r.kind==="handoff"?"Handoff":`${r.replyCount} replies`}
                        </span>
                      </button>
                    `)}
                  </div>
                `}
          </section>
        </div>

        <div class="pulse-col">
          <!-- Attention Queue Card -->
          <section class="pulse-card" aria-label="주의 필요 대기열">
            <div class="pulse-card-head">
              <div class="pulse-card-title-group">
                <h2>Attention Queue</h2>
                <span class="pulse-pill" data-tone="warn" data-stale=${L?"true":"false"} aria-hidden=${L?void 0:"true"}>지연됨</span>
              </div>
              <div class="pulse-header-meta">
                <span class="pulse-pill" data-tone=${fe}>
                  ${ke}
                </span>
                <button type="button" class="btn-ghost" onClick=${()=>e.onNavigate("/work/inbox")}>
                  Inbox →
                </button>
              </div>
            </div>
            ${E.length>0&&u`
              <div class="ap-error" role="alert">${E.join(" · ")}</div>
            `}
            ${I.length>0&&u`
              <div class="pulse-empty" role="note" data-attention-unchecked="true">
                미확인 소스: ${I.join(" · ")}
              </div>
            `}
            ${U&&h.length===0?u`<div class="pulse-empty">대기열 불러오는 중…</div>`:h.length===0?E.length>0?u`<div class="pulse-empty">일부 소스 조회 실패로 대기열을 확정할 수 없습니다</div>`:I.length>0?u`<div class="pulse-empty">확인된 Keeper 오류는 없으나 미확인 대기열이 있어 비어 있음으로 확정할 수 없습니다</div>`:u`<div class="pulse-empty">대기 중인 승인·질문·오류 없음</div>`:u`
                  <div class="pulse-attn-list">
                    ${h.slice(0,10).map(r=>u`
                      <div key=${r.id} class="pulse-attn-row" data-sev=${r.severity}>
                        <div class="pulse-attn-main">
                          <span class="pulse-attn-title" title=${r.title}>
                            ${r.severity==="critical"?"⚠ ":""}${r.title}
                          </span>
                          <span class="pulse-attn-detail" title=${`${r.keeper} · ${r.detail}`}>${r.keeper} · ${r.detail}</span>
                        </div>
                        <div class="pulse-attn-actions">
                          <span class="pulse-pill">${Kt(r.ageSec)}</span>
                          ${r.expiresInSec!==null&&u`
                            <span class="pulse-pill" data-tone=${r.expiresInSec>0?"warn":"bad"}>
                              ${Tt(r.expiresInSec)}
                            </span>
                          `}
                          <button
                            type="button"
                            class="btn-ghost"
                            onClick=${()=>{const x=r.raw;r.kind==="keeper_failure"&&Et(x)?e.onInspect({title:r.title,subtitle:r.keeper,kind:r.kind,data:x,render:()=>It(x)}):e.onInspect({title:r.title,subtitle:r.keeper,kind:r.kind,data:x})}}
                          >
                            미리보기
                          </button>
                          <button
                            type="button"
                            class="btn-primary"
                            onClick=${()=>e.onNavigate(r.route)}
                          >
                            이동
                          </button>
                        </div>
                      </div>
                    `)}
                  </div>
                `}
          </section>

          <!-- Active Goals -->
          <section class="pulse-card" aria-label="진행 중인 Goals">
            <div class="pulse-card-head">
              <div class="pulse-card-title-group">
                <h2>Active Goals</h2>
                <span class="pulse-pill" data-tone="warn" data-stale=${t.goals.kind==="value"&&t.goals.stale?"true":"false"} aria-hidden=${t.goals.kind==="value"&&t.goals.stale?void 0:"true"}>지연됨</span>
              </div>
              <div class="pulse-header-meta">
                ${k?.state==="approval_queue_unavailable"&&u`
                  <span class="pulse-pill" data-tone="bad">승인 대기열 읽기 실패</span>
                `}
                ${k?.state==="ready"&&k.pending_approval_total!==null&&u`
                  <span class="pulse-pill" data-tone=${k.pending_approval_total>0?"warn":"default"}>
                    승인 대기 ${k.pending_approval_total}
                  </span>
                `}
                <button type="button" class="btn-ghost" onClick=${()=>e.onNavigate("/work/goals")}>
                  Goals →
                </button>
              </div>
            </div>
            ${t.goals.kind==="loading"?u`<div class="pulse-empty">Goal 목록 불러오는 중…</div>`:t.goals.kind==="failed"?u`<div class="ap-error" role="alert">Goal 조회 실패: ${t.goals.error.message}</div>`:k?.state==="approval_queue_unavailable"?u`<div class="ap-error" role="alert">승인 대기열을 읽지 못해 Goal 목록과 승인 수를 확인할 수 없습니다: ${k.title} (${k.detail})</div>`:k===null?u`<div class="pulse-empty">${O(t.goals)}</div>`:y.length===0?u`<div class="pulse-empty">활성 Goal 없음</div>`:u`
                    <div class="pulse-goal-list">
                      ${y.map(r=>u`
                        <button
                          key=${r.id}
                          type="button"
                          class="pulse-goal-row"
                          onClick=${()=>e.onNavigate(`/work/goals/${encodeURIComponent(r.id)}`)}
                        >
                          <span class="pulse-goal-title" title=${r.title}>${r.title}</span>
                          <div class="pulse-goal-badges">
                            <span class="pulse-pill" data-tone=${r.phase===null?"default":Rt(r.phase)} title=${r.phase??"서버가 phase 를 보내지 않음"}>
                              ${r.phase??"phase 미확인"}
                            </span>
                            <span class="pulse-pill">
                              ${r.task_done_count}/${r.task_count}
                            </span>
                            ${r.pending_approval_count>0&&u`
                              <span class="pulse-pill" data-tone="warn" title=${r.sub_goal_count>0?`하위 Goal ${r.sub_goal_count}개 포함`:"이 Goal 의 승인 대기"}>
                                승인 ${r.pending_approval_count}
                              </span>
                            `}
                            ${r.awaiting_verification_count>0&&u`
                              <span class="pulse-pill" data-tone="warn">
                                검증 ${r.awaiting_verification_count}
                              </span>
                            `}
                          </div>
                        </button>
                      `)}
                    </div>
                  `}
          </section>

          <!-- World Memory & Candle Pulse Digest (flat cards, no nested h2 or double padding) -->
          ${(()=>{const r=u`
              <section class="pulse-card" aria-label="World Memory">
                <div class="pulse-card-head">
                  <h2>World Memory</h2>
                  <button type="button" class="btn-ghost" onClick=${()=>e.onNavigate("/knowledge/memory")}>
                    Memory →
                  </button>
                </div>
                ${t.worldMemory.kind==="failed"?u`<div class="ap-error" role="alert">World Memory 조회 실패: ${t.worldMemory.error.message}</div>`:D===null?u`<div class="pulse-empty">${O(t.worldMemory)}</div>`:u`
                      <div class="pulse-kv-grid">
                        <div class="pulse-kv">
                          <span class="pulse-kv-k">Claims</span>
                          <span class="pulse-kv-v">${G(D.claims_count).short}</span>
                        </div>
                        <div class="pulse-kv">
                          <span class="pulse-kv-k">Facts</span>
                          <span class="pulse-kv-v">${G(D.facts_count).short}</span>
                        </div>
                        <div class="pulse-kv">
                          <span class="pulse-kv-k">Conflicts</span>
                          <span class="pulse-kv-v">${D.conflicts_count}</span>
                        </div>
                        <div class="pulse-kv">
                          <span class="pulse-kv-k">Wiki Pages</span>
                          <span class="pulse-kv-v">
                            ${D.wiki_count!==null?D.wiki_count:"없음"}
                          </span>
                        </div>
                      </div>
                    `}
              </section>
            `;if(S&&m!==null)return u`
                <div class="pulse-digest-grid" aria-label="World Memory 및 Candle 요약">
                  ${r}
                  <section class="pulse-card" data-accent="brass" aria-label="Candle Economy">
                    <div class="pulse-card-head">
                      <h2>Candle Economy</h2>
                      <button type="button" class="btn-ghost" onClick=${()=>e.onNavigate("/work/candle")}>
                        Candle →
                      </button>
                    </div>
                    <div class="pulse-kv-grid">
                      <div class="pulse-kv">
                        <span class="pulse-kv-k">Circulating</span>
                        <span class="pulse-kv-v">
                          ${O($t(m.circulating_milli))} C
                        </span>
                      </div>
                      <div class="pulse-kv">
                        <span class="pulse-kv-k">Holders</span>
                        <span class="pulse-kv-v">${m.active_keepers}</span>
                      </div>
                      <div class="pulse-kv">
                        <span class="pulse-kv-k">Events</span>
                        <span class="pulse-kv-v">${m.total_events}</span>
                      </div>
                      <div class="pulse-kv">
                        <span class="pulse-kv-k">Half-life</span>
                        <span class="pulse-kv-v">
                          ${m.half_life_hours!==null?`${m.half_life_hours}h`:"없음"}
                        </span>
                      </div>
                    </div>
                  </section>
                </div>
              `;const x=t.candle.kind==="failed"?`조회 실패: ${t.candle.error.message}`:m===null?O(t.candle):m.policy_configuration==="enabled"?"발행된 Candle 원장 기록 없음":`Candle 정책 비활성 (${m.policy_configuration}${m.disabled_reason?`: ${m.disabled_reason}`:""})`;return u`
              ${r}
              <details
                class="ap-disclosure pulse-candle-disclosure"
                data-testid="pulse-candle-disclosure"
                aria-label="Candle Economy"
              >
                <summary class="ap-disclosure-trigger">
                  <span>Candle Economy · ${x}</span>
                  <span aria-hidden="true">▸</span>
                </summary>
                <div class="ap-disclosure-body">
                  <div class="pulse-card-head">
                    ${t.candle.kind==="failed"?u`<div class="ap-error" role="alert">Candle 조회 실패: ${t.candle.error.message}</div>`:u`<span class="pulse-empty">${x}</span>`}
                    <button type="button" class="btn-ghost" onClick=${()=>e.onNavigate("/work/candle")}>
                      Candle →
                    </button>
                  </div>
                </div>
              </details>
            `})()}
        </div>
      </div>
    </div>
  `}export{Qt as PulseWorkspace,Qt as default};
