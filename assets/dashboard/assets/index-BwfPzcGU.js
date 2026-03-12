var Dd=Object.defineProperty;var qd=(t,e,n)=>e in t?Dd(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var De=(t,e,n)=>qd(t,typeof e!="symbol"?e+"":e,n);import{e as wd,_ as Fd,c as g,b as Rt,A as An,y as nt,d as qn,G as Kd}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const l of o.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=wd.bind(Fd);const Bd=["mission","proof","execution","tools","live","memory","governance","planning","intervene","command","lab"],vl={tab:"mission",params:{},postId:null};function _r(t){return!!t&&Bd.includes(t)}function wi(t){try{return decodeURIComponent(t)}catch{return t}}function Fi(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Ud(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function fl(t,e){if(t[0]==="chains"){const o={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(o.operation=wi(t[2])),{tab:"command",params:o,postId:null}}if(t[0]==="lab"){const o={...e};return t[1]&&(o.surface=wi(t[1])),{tab:"lab",params:o,postId:null}}const n=t[0],s=e.tab;return{tab:_r(n)?n:_r(s)?s:"mission",params:e,postId:null}}function sa(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return vl;const n=wi(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=Fi(a),l=Ud(s);return fl(l,o)}function Hd(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...vl,params:Fi(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Fi(e.replace(/^\?/,""));return fl(s,a)}function gl(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const D=g(sa(window.location.hash));window.addEventListener("hashchange",()=>{D.value=sa(window.location.hash)});function ot(t,e){const n={tab:t,params:e??{}};window.location.hash=gl(n)}function Wd(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function Gd(){if(window.location.hash&&window.location.hash!=="#"){D.value=sa(window.location.hash);return}const t=Hd(window.location.pathname,window.location.search);if(t){D.value=t;const e=gl(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",D.value=sa(window.location.hash)}const vr="masc_dashboard_sse_session_id",Jd=1e3,Yd=15e3,ue=g(!1),Ha=g(0),$l=g(null),aa=g([]);function Xd(){let t=sessionStorage.getItem(vr);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(vr,t)),t}const Vd=200;function Qd(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};aa.value=[a,...aa.value].slice(0,Vd)}function Ki(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function fr(t,e){const n=Ki(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function At(t,e,n,s,a={}){Qd(t,e,n,{eventType:s,...a})}let Nt=null,Ye=null,Bi=0;function hl(){Ye&&(clearTimeout(Ye),Ye=null)}function Zd(){if(Ye)return;Bi++;const t=Math.min(Bi,5),e=Math.min(Yd,Jd*Math.pow(2,t));Ye=setTimeout(()=>{Ye=null,yl()},e)}function yl(){hl(),Nt&&(Nt.close(),Nt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Xd());const a=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(a);Nt=o,o.onopen=()=>{Nt===o&&(Bi=0,ue.value=!0)},o.onerror=()=>{Nt===o&&(ue.value=!1,o.close(),Nt=null,Zd())},o.onmessage=l=>{try{const c=JSON.parse(l.data);Ha.value++,$l.value=c,tu(c)}catch{}}}function tu(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":At(n,"Joined","system","agent_joined");break;case"agent_left":At(n,"Left","system","agent_left");break;case"broadcast":At(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":At(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":At(n,fr("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Ki(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":At(n,fr("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Ki(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":At(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":At(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":At(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":At(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:At(n,e,"system","unknown")}}function eu(){hl(),Nt&&(Nt.close(),Nt=null),ue.value=!1}function _(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function r(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function d(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function N(t){return typeof t=="boolean"?t:void 0}function F(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function pt(t,e=[]){if(Array.isArray(t))return t;if(!_(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function rt(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}const ia="[STATE]",Ui="[/STATE]";function nu(t){const e=t.indexOf(ia);if(e<0)return null;const n=e+ia.length,s=t.indexOf(Ui,n);return s<0?null:t.slice(n,s).trim()||null}function su(t){let e=t;for(;;){const n=e.indexOf(ia);if(n<0)return e;const s=e.indexOf(Ui,n+ia.length);if(s<0)return e.slice(0,n);e=`${e.slice(0,n)}${e.slice(s+Ui.length)}`}}function au(t){return t.split(`
`).filter(e=>{const n=e.trim();return!n.startsWith("SKILL:")&&!n.startsWith("SKILL_REASON:")}).join(`
`)}function Us(t){const e=au(t);return su(e).replace(/\n{3,}/g,`

`).trim()}function bl(t){const e=(()=>{if(!_(t))return null;const o=t.raw_payload;return _(o)?o:t})();if(!e)return null;const n=r(e.reply)??"",s=n?nu(n):null,a=_(e.usage)?{inputTokens:d(e.usage.input_tokens)??null,outputTokens:d(e.usage.output_tokens)??null,totalTokens:d(e.usage.total_tokens)??null}:null;return{traceId:r(e.trace_id)??null,generation:d(e.generation)??null,modelUsed:r(e.model_used)??null,latencyMs:d(e.latency_ms)??null,costUsd:d(e.cost_usd)??null,usage:a,skillPrimary:r(e.skill_primary)??null,skillReason:r(e.skill_reason)??null,stateBlock:s,rawPayload:e}}function iu(t){const e=t.trim();if(!e.startsWith("{"))return{text:Us(e),details:null};try{const n=JSON.parse(e),s=bl(n),a=_(n)?r(n.reply)??e:e;return{text:Us(a),details:s}}catch{return{text:Us(e),details:null}}}function xo(){return new URLSearchParams(window.location.search)}const ou="masc_dashboard_agent_name";function kl(){var t;try{return((t=localStorage.getItem(ou))==null?void 0:t.trim())||null}catch{return null}}function xl(){var e,n;const t=xo();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||kl()||"dashboard"}function Sl(){const t=xo(),e={},n=t.get("token"),s=kl(),a=t.get("agent")??t.get("agent_name")??s;return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function So(){return{...Sl(),"Content-Type":"application/json"}}const ru=15e3,Co=3e4,lu=6e4,gr=new Set([408,425,429,500,502,503,504]);class rs extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);De(this,"method");De(this,"path");De(this,"status");De(this,"statusText");De(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function Ao(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const l=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new rs({method:l,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function cu(){var e,n;const t=xo();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function st(t){const e=await Ao(t,{headers:Sl()},ru);if(!e.ok)throw new rs({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function du(t){return new Promise(e=>setTimeout(e,t))}function uu(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function pu(t){if(t instanceof rs)return t.timeout||typeof t.status=="number"&&gr.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=uu(t.message);return e!==null&&gr.has(e)}async function Wa(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!pu(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${o}ms`,a),await du(o),s+=1}}async function Ft(t,e,n,s=Co){const a=await Ao(t,{method:"POST",headers:{...So(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new rs({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function mu(t,e,n,s=Co){const a=await Ao(t,{method:"POST",headers:{...So(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new rs({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function _u(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function vu(t){var e,n,s,a,o,l,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const p=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(p)}return((c=(l=(o=t.result)==null?void 0:o.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function _e(t,e){const n=await mu("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},lu),s=_u(n);return vu(s)}async function fu(t,e,n){return _e("masc_keeper_msg",{name:t,message:e})}async function gu(t,e,n){const s=await fu(t,e);return iu(s)}function $u(t){const e=t.replace(/\r\n/g,`
`),n=[];let s=0;for(;;){const a=e.indexOf(`

`,s);if(a<0)return{frames:n,rest:e.slice(s)};n.push(e.slice(s,a)),s=a+2}}function $r(t){const e=t.split(`
`).filter(n=>n.startsWith("data:")).map(n=>n.slice(5).trimStart());if(e.length===0)return null;try{return JSON.parse(e.join(`
`))}catch{return null}}async function hu(t,e,n,{signal:s,onEvent:a}){var m;const o=await fetch("/api/v1/keepers/chat/stream",{method:"POST",headers:{...So(),Accept:"text/event-stream"},body:JSON.stringify({name:t,message:e}),signal:s});if(!o.ok){const u=await o.text();let v=u||`Streaming request failed (${o.status})`;try{const f=JSON.parse(u);v=((m=f.error)==null?void 0:m.message)??f.message??v}catch{}throw new Error(v)}if(!o.body)throw new Error("Streaming response body is unavailable");const l=o.body.getReader(),c=new TextDecoder;let p="";try{for(;;){const{done:v,value:f}=await l.read();p+=c.decode(f??new Uint8Array,{stream:!v});const{frames:$,rest:C}=$u(p);p=C;for(const b of $){const k=$r(b);k&&a(k)}if(v)break}const u=p.trim();if(u){const v=$r(u);v&&a(v)}}finally{l.releaseLock()}}function yu(){return st("/api/v1/dashboard/shell")}function bu(){return st("/api/v1/dashboard/room-truth")}function ku(){return st("/api/v1/dashboard/execution")}function xu(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),st(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function Su(){return Wa("fetchDashboardGovernance",async()=>{const t=await st("/api/v1/dashboard/governance"),e=Array.isArray(t.items)?t.items.map(o=>Bu(o)).filter(o=>o!==null):[],n=Array.isArray(t.pending_actions)?t.pending_actions.map(o=>Tl(o)).filter(o=>o!==null):[],s=e.filter(o=>o.kind==="debate").map(o=>({id:o.id,topic:o.topic,status:o.status,argument_count:o.evidence_refs.length,created_at:o.last_activity_at??void 0})),a=e.filter(o=>o.kind==="consensus").map(o=>({id:o.id,topic:o.topic,initiator:o.related_agents[0]||"system",votes:o.votes??0,quorum:o.quorum??0,threshold:o.threshold,state:o.status,created_at:o.last_activity_at??void 0}));return{generated_at:dt(t.generated_at)??void 0,summary:_(t.summary)?{debates:_t(t.summary.debates)??void 0,voting_sessions:_t(t.summary.voting_sessions)??void 0,debates_open:_t(t.summary.debates_open)??void 0,sessions_active:_t(t.summary.sessions_active)??void 0,sessions_without_quorum:_t(t.summary.sessions_without_quorum)??void 0,ready_to_execute:_t(t.summary.ready_to_execute)??void 0,oldest_open_debate_age_s:typeof t.summary.oldest_open_debate_age_s=="number"?t.summary.oldest_open_debate_age_s:null,last_activity_age_s:typeof t.summary.last_activity_age_s=="number"?t.summary.last_activity_age_s:null,judge_online:typeof t.summary.judge_online=="boolean"?t.summary.judge_online:void 0,judge_last_seen_at:dt(t.summary.judge_last_seen_at)}:void 0,debates:s,sessions:a,items:e,activity:Array.isArray(t.activity)?t.activity.map(o=>Uu(o)).filter(o=>o!==null):[],judge:Hu(t.judge),pending_actions:n}})}function Cu(){return st("/api/v1/dashboard/semantics")}function Au(){return st("/api/v1/dashboard/mission")}function Tu(t){const e=`?session_id=${encodeURIComponent(t)}`;return st(`/api/v1/dashboard/session${e}`)}function Iu(t=!1){return st(`/api/v1/dashboard/mission/briefing${t?"?force=1":""}`)}function Ru(t,e){const n=new URLSearchParams;t&&n.set("session_id",t),e&&n.set("operation_id",e);const s=n.toString();return st(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function Mu(){return st("/api/v1/dashboard/planning")}function Eu(){return st("/api/v1/tool-metrics")}function Lu(){return st("/api/v1/dashboard/tools")}function Pu(){return st("/api/v1/operator")}function Cl(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return st(`/api/v1/operator/digest${n?`?${n}`:""}`)}function zu(){return st("/api/v1/command-plane")}function Nu(){return st("/api/v1/command-plane/summary")}function ju(){return st("/api/v1/chains/summary")}function Ou(t){return st(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Du(){return st("/api/v1/command-plane/help")}function qu(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return st(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function wu(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return st(`/api/v1/command-plane/orchestra${s?`?${s}`:""}`)}function Fu(t,e){return Ft(t,e)}function Ku(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"swarm_run_continue":return 6e4;case"swarm_run_rerun":return 12e4;case"swarm_run_abandon":return 3e4;case"lodge_tick":return 45e3;default:return Co}}function Ga(t){return Ft("/api/v1/operator/action",t,void 0,Ku(t))}function Al(t,e,n="confirm"){return Ft("/api/v1/operator/confirm",{actor:t,confirm_token:e,decision:n})}function Hs(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function dt(t){if(typeof t=="string"){const e=t.trim();return e||null}if(typeof t=="number"&&Number.isFinite(t)){const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}return null}function K(t){if(typeof t!="string")return null;const e=t.trim();return e||null}function Tl(t){if(!_(t))return null;const e=x(t.confirm_token??t.token,"").trim();return e?{confirm_token:e,actor:K(t.actor)??void 0,action_type:K(t.action_type)??void 0,target_type:K(t.target_type)??void 0,target_id:K(t.target_id),delegated_tool:K(t.delegated_tool)??void 0,created_at:dt(t.created_at)??void 0,preview:t.preview}:null}function To(t){return _(t)?{board_post_id:K(t.board_post_id),task_id:K(t.task_id),operation_id:K(t.operation_id),team_session_id:K(t.team_session_id)}:{}}function Il(t){if(!_(t))return null;const e=K(t.action_kind),n=K(t.resolved_tool),s=K(t.target_type),a=K(t.target_id),o=K(t.reason);return!e&&!n&&!s&&!o?null:{action_kind:e??void 0,resolved_tool:n,target_type:s,target_id:a,reason:o??void 0,payload_preview:t.payload_preview}}function Rl(t){if(!_(t))return null;const e=K(t.action_type),n=K(t.delegated_tool),s=K(t.confirmation_state),a=dt(t.created_at);return!e&&!n&&!s&&!a?null:{action_type:e??void 0,delegated_tool:n,confirmation_state:s??void 0,created_at:a}}function Ml(t){if(!_(t))return null;const e=Tl(t.pending_confirm),n=K(t.pending_confirm_token)??(e==null?void 0:e.confirm_token)??null;return{requires_human_gate:typeof t.requires_human_gate=="boolean"?t.requires_human_gate:void 0,pending_confirm:e,pending_confirm_token:n,ready_to_execute:typeof t.ready_to_execute=="boolean"?t.ready_to_execute:void 0}}function El(t){if(!_(t))return null;const e=K(t.summary),n=K(t.target_id);return!e&&!n?null:{judgment_id:K(t.judgment_id)??void 0,target_kind:K(t.target_kind)??void 0,target_id:n??void 0,status:K(t.status)??void 0,summary:e??void 0,confidence:typeof t.confidence=="number"?t.confidence:null,generated_at:dt(t.generated_at),expires_at:dt(t.expires_at),model_used:K(t.model_used),keeper_name:K(t.keeper_name),evidence_refs:jt(t.evidence_refs),recommended_action:Il(t.recommended_action),guardrail_state:Ml(t.guardrail_state),executed_route:Rl(t.executed_route)}}function Bu(t){if(!_(t))return null;const e=x(t.id,"").trim(),n=x(t.topic,"").trim();if(!e||!n)return null;const s=To(t.context);return{kind:x(t.kind,"debate"),id:e,topic:n,status:x(t.status??t.state,"open"),last_activity_at:dt(t.last_activity_at),truth_summary:K(t.truth_summary)??void 0,judgment_summary:K(t.judgment_summary),confidence:typeof t.confidence=="number"?t.confidence:null,related_agents:jt(t.related_agents),context:s,linked_board_post_id:K(t.linked_board_post_id)??s.board_post_id??null,linked_task_id:K(t.linked_task_id)??s.task_id??null,linked_operation_id:K(t.linked_operation_id)??s.operation_id??null,linked_session_id:K(t.linked_session_id)??s.team_session_id??null,recommended_action:Il(t.recommended_action),executed_route:Rl(t.executed_route),guardrail_state:Ml(t.guardrail_state),evidence_refs:jt(t.evidence_refs),approve_count:_t(t.approve_count),reject_count:_t(t.reject_count),abstain_count:_t(t.abstain_count),votes:_t(t.votes),quorum:_t(t.quorum),threshold:typeof t.threshold=="number"?t.threshold:void 0}}function Uu(t){if(!_(t))return null;const e=x(t.kind,"").trim();return e?{kind:e,item_kind:K(t.item_kind)??void 0,item_id:K(t.item_id)??void 0,topic:K(t.topic)??void 0,created_at:dt(t.created_at),summary:K(t.summary)??void 0,actor:K(t.actor),index:_t(t.index),decision:K(t.decision)}:null}function Hu(t){if(_(t))return{judge_online:typeof t.judge_online=="boolean"?t.judge_online:void 0,refreshing:typeof t.refreshing=="boolean"?t.refreshing:void 0,generated_at:dt(t.generated_at),expires_at:dt(t.expires_at),model_used:K(t.model_used),keeper_name:K(t.keeper_name),last_error:K(t.last_error)}}function Wu(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Gu(t){if(!_(t))return null;const e=x(t.source,"").trim()||null,n=x(t.state_block,"").trim()||null;return!e&&!n?null:{source:e,state_block:n}}function Ju(t){if(!_(t))return null;const e=x(t.id,"").trim(),n=x(t.author,"").trim(),s=x(t.body,"").trim()||x(t.content,"").trim(),a=s;if(!e||!n)return null;const o=U(t.score,0),l=U(t.votes_up,0),c=U(t.votes_down,0),p=U(t.votes,o||l-c),m=U(t.comment_count,U(t.reply_count,0)),u=(()=>{const k=t.flair;if(typeof k=="string"&&k.trim())return k.trim();if(_(k)){const S=x(k.name,"").trim();if(S)return S}return x(t.flair_name,"").trim()||void 0})(),v=x(t.created_at_iso,"").trim()||Hs(t.created_at),f=x(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Hs(t.updated_at):v),C=x(t.title,"").trim()||Wu(s),b=Array.isArray(t.tags)?t.tags.filter(k=>typeof k=="string"&&k.trim()!==""):[];return{id:e,author:n,post_kind:(()=>{const k=x(t.post_kind,"").trim().toLowerCase();return k==="automation"||k==="system"||k==="human"?k:void 0})(),title:C,body:s,content:a,meta:Gu(t.meta),tags:b,votes:p,vote_balance:o,comment_count:m,created_at:v,updated_at:f,flair:u,hearth:x(t.hearth,"").trim()||null,visibility:x(t.visibility,"").trim()||void 0,expires_at:x(t.expires_at_iso,"").trim()||(t.expires_at!==void 0&&t.expires_at!==0?Hs(t.expires_at):"")||null,hearth_count:U(t.hearth_count,0)}}function Yu(t){if(!_(t))return null;const e=x(t.id,"").trim(),n=x(t.post_id,"").trim(),s=x(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:x(t.content,""),created_at:Hs(t.created_at)}}async function Xu(t){return Wa("fetchBoardPost",async()=>{const e=await st(`/api/v1/board/${t}?format=flat`),n=_(e.post)?e.post:e,s=Ju(n)??{id:t,author:"unknown",post_kind:"human",title:"Post",body:"",content:"",meta:null,tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(e.comments)?e.comments:[]).map(Yu).filter(l=>l!==null);return{...s,comments:o}})}function Ll(t,e){return Ft("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:cu()})}function Vu(t,e,n){return Ft("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Qu(t){const e=x(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function ut(...t){for(const e of t){const n=x(e,"");if(n.trim())return n.trim()}return""}function hr(t){const e=Qu(ut(t.outcome,t.result,t.result_code));if(!e)return;const n=ut(t.reason,t.reason_code,t.description,t.detail),s=ut(t.summary,t.summary_ko,t.summary_en,t.note),a=ut(t.details,t.details_text,t.text,t.note),o=ut(t.winner,t.winner_name,t.actor_winner,t.winner_actor),l=ut(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=ut(t.raw_reason,t.raw_reason_code,t.error_message),p=(()=>{const v=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof v=="string"?[v]:Array.isArray(v)?v.map(f=>{if(typeof f=="string")return f.trim();if(_(f)){const $=x(f.summary,"").trim();if($)return $;const C=x(f.text,"").trim();if(C)return C;const b=x(f.type,"").trim();return b||x(f.event_id,"").trim()}return""}).filter(f=>f.length>0):[]})(),m=(()=>{const v=U(t.turn,Number.NaN);if(Number.isFinite(v))return v;const f=U(t.turn_number,Number.NaN);if(Number.isFinite(f))return f;const $=U(t.current_turn,Number.NaN);if(Number.isFinite($))return $;const C=U(t.round,Number.NaN);return Number.isFinite(C)?C:void 0})(),u=ut(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:l||void 0,evidence:p.length>0?p:void 0,raw_reason:c||void 0,turn:m,phase:u||void 0}}function Zu(t,e){const n=_(t.state)?t.state:{};if(x(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(l=>_(l)?x(l.type,"")==="session.outcome":!1),o=_(n.session_outcome)?n.session_outcome:{};if(_(o)&&Object.keys(o).length>0){const l=hr(o);if(l)return l}if(_(a))return hr(_(a.payload)?a.payload:{})}function x(t,e=""){return typeof t=="string"?t:e}function U(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function _t(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function oa(t,e=!1){return typeof t=="boolean"?t:e}function jt(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(_(e)){const n=x(e.name,"").trim(),s=x(e.id,"").trim(),a=x(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function tp(t){const e={};if(!_(t)&&!Array.isArray(t))return e;if(_(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),o=x(s,"").trim();!a||!o||(e[a]=o)}),e;for(const n of t){if(!_(n))continue;const s=ut(n.to,n.target,n.actor_id,n.name,n.id),a=ut(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function ep(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function xt(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const np=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function sp(t){const e=_(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const o=s.trim();o&&(np.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function ap(t,e){if(t!=="dice.rolled")return;const n=U(e.raw_d20,0),s=U(e.total,0),a=U(e.bonus,0),o=x(e.action,"roll"),l=U(e.dc,0);return{notation:l>0?`${o} (DC ${l})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function ip(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function op(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function rp(t,e,n,s){const a=n||e||x(s.actor_id,"")||x(s.actor_name,"");switch(t){case"turn.action.proposed":{const o=x(s.proposed_action,x(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=x(s.reply,x(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return x(s.reply,x(s.content,x(s.text,"Narration")));case"dice.rolled":{const o=x(s.action,"roll"),l=U(s.total,0),c=U(s.dc,0),p=x(s.label,""),m=a||"actor",u=c>0?` vs DC ${c}`:"",v=p?` (${p})`:"";return`${m} ${o}: ${l}${u}${v}`}case"turn.started":return`Turn ${U(s.turn,1)} started`;case"phase.changed":return`Phase: ${x(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${x(s.name,_(s.actor)?x(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${x(s.keeper_name,x(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${x(s.keeper_name,x(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${U(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${U(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||x(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||x(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${x(s.reason_code,"unknown")}`;case"memory.signal":{const o=_(s.entity_refs)?s.entity_refs:{},l=x(o.requested_tier,""),c=x(o.effective_tier,""),p=oa(o.guardrail_applied,!1),m=x(s.summary_en,x(s.summary_ko,"Memory signal"));if(!l&&!c)return m;const u=l&&c?`${l}->${c}`:c||l;return`${m} [${u}${p?" (guardrail)":""}]`}case"world.event":{if(x(s.event_type,"")==="canon.check"){const l=x(s.status,"unknown"),c=x(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return x(s.description,x(s.summary,"World event"))}case"combat.attack":return x(s.summary,x(s.result,"Attack resolved"));case"combat.defense":return x(s.summary,x(s.result,"Defense resolved"));case"session.outcome":return x(s.summary,x(s.outcome,"Session ended"));default:{const o=ip(s);return o?`${t}: ${o}`:t}}}function lp(t,e){const n=_(t)?t:{},s=x(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=x(n.actor_name,"").trim()||e[a]||x(_(n.payload)?n.payload.actor_name:"",""),l=_(n.payload)?n.payload:{},c=x(n.ts,x(n.timestamp,new Date().toISOString())),p=x(n.phase,x(l.phase,"")),m=x(n.category,"");return{type:s,actor:o||a||x(l.actor_name,""),actor_id:a||x(l.actor_id,""),actor_name:o,seq:n.seq,room_id:x(n.room_id,""),phase:p||void 0,category:m||op(s),visibility:x(n.visibility,x(l.visibility,"public")),event_id:x(n.event_id,""),content:rp(s,a,o,l),dice_roll:ap(s,l),timestamp:c}}function cp(t,e,n){var V,it;const s=x(t.room_id,"")||n||"default",a=_(t.state)?t.state:{},o=_(a.party)?a.party:{},l=_(a.actor_control)?a.actor_control:{},c=_(a.join_gate)?a.join_gate:{},p=_(a.contribution_ledger)?a.contribution_ledger:{},m=Object.entries(o).map(([z,T])=>{const A=_(T)?T:{},Q=xt(A,"max_hp",void 0,10),at=xt(A,"hp",void 0,Q),J=xt(A,"max_mp",void 0,0),Bt=xt(A,"mp",void 0,0),B=xt(A,"level",void 0,1),Et=xt(A,"xp",void 0,0),$e=oa(A.alive,at>0),fn=l[z],gn=typeof fn=="string"?fn:void 0,fs=ep(A.role,z,gn),gs=_t(A.generation),$s=ut(A.joined_at,A.joinedAt,A.started_at,A.startedAt),hs=ut(A.claimed_at,A.claimedAt,A.assigned_at,A.assignedAt,A.assigned_time),ys=ut(A.last_seen,A.lastSeen,A.last_seen_at,A.lastSeenAt,A.last_active,A.lastActive),bs=ut(A.scene,A.current_scene,A.currentScene,A.world_scene,A.scene_name,A.sceneName),ks=ut(A.location,A.current_location,A.currentLocation,A.position,A.zone,A.area);return{id:z,name:x(A.name,z),role:fs,keeper:gn,archetype:x(A.archetype,""),persona:x(A.persona,""),portrait:x(A.portrait,"")||void 0,background:x(A.background,"")||void 0,traits:jt(A.traits),skills:jt(A.skills),stats_raw:sp(A),status:$e?"active":"dead",generation:gs,joined_at:$s||void 0,claimed_at:hs||void 0,last_seen:ys||void 0,scene:bs||void 0,location:ks||void 0,inventory:jt(A.inventory),notes:jt(A.notes),relationships:tp(A.relationships),stats:{hp:at,max_hp:Q,mp:Bt,max_mp:J,level:B,xp:Et,strength:xt(A,"strength","str",10),dexterity:xt(A,"dexterity","dex",10),constitution:xt(A,"constitution","con",10),intelligence:xt(A,"intelligence","int",10),wisdom:xt(A,"wisdom","wis",10),charisma:xt(A,"charisma","cha",10)}}}),u=m.filter(z=>z.status!=="dead"),v=Zu(t,e),f={phase_open:oa(c.phase_open,!0),min_points:U(c.min_points,3),window:x(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},$=Object.entries(p).map(([z,T])=>{const A=_(T)?T:{};return{actor_id:z,score:U(A.score,0),last_reason:x(A.last_reason,"")||null,reasons:jt(A.reasons)}}),C=m.reduce((z,T)=>(z[T.id]=T.name,z),{}),b=e.map(z=>lp(z,C)),k=U(a.turn,1),h=x(a.phase,"round"),S=x(a.map,""),E=_(a.world)?a.world:{},M=S||x(E.ascii_map,x(E.map,"")),P=b.filter((z,T)=>{const A=e[T];if(!_(A))return!1;const Q=_(A.payload)?A.payload:{};return U(Q.turn,-1)===k}),W=(P.length>0?P:b).slice(-12),I=x(a.status,"active");return{session:{id:s,room:s,status:I==="ended"?"ended":I==="paused"?"paused":"active",round:k,actors:u,created_at:((V=b[0])==null?void 0:V.timestamp)??new Date().toISOString()},current_round:{round_number:k,phase:h,events:W,timestamp:((it=b[b.length-1])==null?void 0:it.timestamp)??new Date().toISOString()},map:M||void 0,join_gate:f,contribution_ledger:$,outcome:v,party:u,story_log:b,history:[]}}async function dp(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await st(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function up(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([st(`/api/v1/trpg/state${e}`),dp(t)]);return cp(n,s,t)}function pp(t){return Ft("/api/v1/trpg/rounds/run",{room_id:t})}function mp(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function _p(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Ft("/api/v1/trpg/dice/roll",e)}function vp(t,e){const n=mp();return Ft("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function fp(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Ft("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function gp(t,e,n){return Ft("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function $p(t,e,n){const s=await _e("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function hp(t){const e=await _e("trpg.mid_join.request",t);return JSON.parse(e)}async function yp(t,e){await _e("masc_broadcast",{agent_name:t,message:e})}async function bp(t=40){return(await _e("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function kp(t,e=20){return _e("masc_task_history",{task_id:t,limit:e})}async function xp(t){const e=await _e("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Sp(t){return Wa("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await st(`/api/v1/council/debates/${e}/summary`);if(!_(n))return null;const s=_(n.debate)?n.debate:n,a=x(s.id,"").trim(),o=x(s.topic,"").trim();return!a||!o?null:{debate:{id:a,topic:o,status:x(s.status,"open"),created_at:dt(s.created_at_iso??s.created_at),closed_at:dt(s.closed_at)},arguments:Array.isArray(n.arguments)?n.arguments.flatMap(l=>_(l)?[{index:U(l.index,0),agent:x(l.agent,"unknown"),position:x(l.position,"neutral"),content:x(l.content,""),evidence:jt(l.evidence),reply_to:_t(l.reply_to)??null,mentions:jt(l.mentions),archetype:K(l.archetype),created_at:dt(l.created_at)}]:[]):[],summary:{support_count:_(n.summary)?U(n.summary.support_count,0):U(n.support_count,0),oppose_count:_(n.summary)?U(n.summary.oppose_count,0):U(n.oppose_count,0),neutral_count:_(n.summary)?U(n.summary.neutral_count,0):U(n.neutral_count,0),total_arguments:_(n.summary)?U(n.summary.total_arguments,0):U(n.total_arguments,0),summary_text:_(n.summary)?x(n.summary.summary_text,""):x(n.summary_text,"")},context:To(n.context),judgment:El(n.judgment)}})}async function Cp(t){return Wa("fetchConsensusSessionSummary",async()=>{const e=encodeURIComponent(t),n=await st(`/api/v1/council/sessions/${e}/summary`);if(!_(n)||!_(n.session))return null;const s=n.session,a=x(s.id,"").trim(),o=x(s.topic,"").trim();return!a||!o?null:{session:{id:a,topic:o,state:x(s.state,"open"),initiator:x(s.initiator,"system"),quorum:U(s.quorum,0),threshold:U(s.threshold,0),created_at:dt(s.created_at),closed_at:dt(s.closed_at)},votes:Array.isArray(n.votes)?n.votes.flatMap(l=>_(l)?[{agent:x(l.agent,"unknown"),decision:x(l.decision,"abstain"),reason:x(l.reason,""),timestamp:dt(l.timestamp),weight:typeof l.weight=="number"?l.weight:void 0,archetype:K(l.archetype)}]:[]):[],summary:{approve_count:_(n.summary)?U(n.summary.approve_count,0):0,reject_count:_(n.summary)?U(n.summary.reject_count,0):0,abstain_count:_(n.summary)?U(n.summary.abstain_count,0):0,quorum_met:_(n.summary)?oa(n.summary.quorum_met,!1):!1,result:_(n.summary)?K(n.summary.result):null},context:To(n.context),judgment:El(n.judgment)}})}const Ap=g(""),Xt=g({}),ft=g({}),Hi=g({}),ra=g({}),Wi=g({}),Gi=g({}),Dt=g({}),Io=new Map,Ro=new Map;function lt(t,e,n){t.value={...t.value,[e]:n}}function Tp(t){var n;const e=(n=r(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Ip(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function ai(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!_(s))continue;const a=r(s.name);if(!a)continue;const o=r(s[e]);e==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function Rp(t){if(!_(t))return null;const e=r(t.name);return e?{name:e,trigger:r(t.trigger),outcome:r(t.outcome),summary:r(t.summary),reason:r(t.reason)}:null}function Mp(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Ep(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Pl(t,e,n){return r(t)??Ep(e,n)}function zl(t,e){return typeof t=="boolean"?t:e==="recover"}function la(t){if(!_(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:r(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:rt(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:d(t.next_eligible_at_s)??null,recoverable:zl(t.recoverable,n),summary:Pl(t.summary,e,r(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Nl(t){return _(t)?{hour:d(t.hour),checked:d(t.checked)??0,acted:d(t.acted)??0,acted_names:F(t.acted_names),activity_report:r(t.activity_report),quiet_hours_overridden:N(t.quiet_hours_overridden),skipped_reason:r(t.skipped_reason),acted_rows:ai(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:ai(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:ai(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Rp).filter(e=>e!==null):[]}:null}function Lp(t){return _(t)?{enabled:N(t.enabled)??!1,interval_s:d(t.interval_s)??0,quiet_start:d(t.quiet_start),quiet_end:d(t.quiet_end),quiet_active:N(t.quiet_active),use_planner:N(t.use_planner),delegate_llm:N(t.delegate_llm),agent_count:d(t.agent_count),agents:F(t.agents),last_tick_ago_s:d(t.last_tick_ago_s)??null,last_tick_ago:r(t.last_tick_ago),total_ticks:d(t.total_ticks),total_checkins:d(t.total_checkins),last_skip_reason:r(t.last_skip_reason)??null,last_tick_result:Nl(t.last_tick_result),active_self_heartbeats:F(t.active_self_heartbeats)}:null}function Pp(t){return _(t)?{status:t.status,diagnostic:la(t.diagnostic)}:null}function zp(t){return _(t)?{recovered:N(t.recovered)??!1,skipped_reason:r(t.skipped_reason)??null,before:la(t.before),after:la(t.after),down:t.down,up:t.up}:null}function Np(t,e){var S,E;if(!(t!=null&&t.name))return null;const n=r((S=t.agent)==null?void 0:S.status)??r(t.status)??"unknown",s=r((E=t.agent)==null?void 0:E.error)??null,a=t.presence_keepalive??!0,o=t.keepalive_running??!1,l=t.turn_count??0,c=t.last_turn_ago_s??null,p=t.proactive_enabled??!1,m=t.proactive_cooldown_sec??0,u=t.last_proactive_ago_s??null,v=p&&u!=null?Math.max(0,m-u):null,f=l<=0||c==null?"never":c>900?"stale":"fresh",$=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,C=s??(a&&!o?"keeper keepalive is not running":null),b=n==="offline"||n==="inactive"?"offline":C?"degraded":f==="stale"?"stale":f==="never"?"idle":"healthy",k=C?Mp(C):e!=null&&e.quiet_active&&f!=="fresh"?"quiet_hours":a&&!o?"disabled":l<=0?"never_started":v!=null&&v>0?"min_gap":f==="fresh"||f==="stale"?"no_recent_activity":"unknown",h=b==="offline"||b==="degraded"||b==="stale"?"recover":k==="quiet_hours"?"manual_lodge_poke":k==="unknown"?"probe":"direct_message";return{health_state:b,quiet_reason:k,next_action_path:h,last_reply_status:f,last_reply_at:$,last_reply_preview:null,last_error:C,next_eligible_at_s:v!=null&&v>0?v:null,recoverable:zl(void 0,h),summary:Pl(void 0,b,k),keepalive_running:o}}function jp(t,e){if(!_(t))return null;const n=Tp(t.role),s=r(t.content)??r(t.preview);if(!s)return null;const a=Us(s);if(!a)return null;const o=rt(t.ts_unix)??rt(t.timestamp);return{id:`${n}-${o??"entry"}-${e}`,role:n,label:Ip(n),text:a,timestamp:o,delivery:"history",streamState:null,details:null}}function Op(t,e,n){const s=_(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,l)=>jp(o,l)).filter(o=>o!==null):[];return{name:t,diagnostic:la(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function yr(t,e){const n=ft.value[t]??[];ft.value={...ft.value,[t]:[...n,e].slice(-50)}}function Mo(t,e,n){const s=ft.value[t]??[];ft.value={...ft.value,[t]:s.map(a=>a.id===e?n(a):a)}}function ii(t,e,n,s){Mo(t,e,a=>({...a,streamState:n,delivery:s}))}function Dp(t,e,n){Mo(t,e,s=>({...s,text:`${s.text}${n}`,streamState:"streaming",delivery:"streaming"}))}function Ut(t,e,n){Mo(t,e,s=>({...s,...n}))}function qp(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function wp(t,e){const s=(ft.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(o=>qp(a,o)));ft.value={...ft.value,[t]:[...e,...s].slice(-50)}}function Ja(t,e){Xt.value={...Xt.value,[t]:e},wp(t,e.history)}function Ss(t,e){const n=Xt.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ja(t,{...n,diagnostic:{...s,...e}})}function Fp(t,e,n){Ro.set(t,e),Io.set(t,n)}function jl(t){Ro.delete(t),Io.delete(t)}function Kp(t){return Ro.get(t)??null}function Ol(t){const e=t.trim();if(!e)return;const n=Io.get(e),s=Kp(e);n&&n.abort(),s&&Ut(e,s,{delivery:"timeout",streamState:null,error:"Stream cancelled",timestamp:new Date().toISOString()}),jl(e),lt(ra,e,!1)}function Bp(t,e,n){switch(n.type){case"RUN_STARTED":return ii(t,e,"opening","sending"),null;case"TEXT_MESSAGE_START":return ii(t,e,"streaming","streaming"),null;case"TEXT_MESSAGE_CONTENT":{const s=typeof n.delta=="string"?n.delta:"";return s&&Dp(t,e,s),null}case"TEXT_MESSAGE_END":return ii(t,e,"finalizing","streaming"),null;case"CUSTOM":if(n.name==="KEEPER_REPLY_DETAILS"){const s=bl(n.value);s&&Ut(t,e,{details:s})}return null;case"RUN_ERROR":return typeof n.value=="string"?n.value:(_(n.value)?r(n.value.message):null)??"Keeper stream failed";default:return null}}async function ca(){try{await ls()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Up(t){Ap.value=t.trim()}async function Dl(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Xt.value[n])return Xt.value[n];lt(Hi,n,!0),lt(Dt,n,null);try{const s=await _e("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=Op(n,s,a);return Ja(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return lt(Dt,n,a),null}finally{lt(Hi,n,!1)}}async function Hp(t,e){var c;const n=t.trim(),s=e.trim();if(!n||!s)return;Ol(n);const a=`local-${Date.now()}`,o=`reply-${Date.now()}`;yr(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending",streamState:null,details:null}),yr(n,{id:o,role:"assistant",label:n,text:"",timestamp:null,delivery:"sending",streamState:"opening",details:null}),lt(ra,n,!0),lt(Dt,n,null);const l=new AbortController;Fp(n,o,l);try{Ut(n,a,{delivery:"delivered"}),await hu(n,s,void 0,{signal:l.signal,onEvent:u=>{const v=Bp(n,o,u);if(v)throw new Error(v)}});const p=(ft.value[n]??[]).find(u=>u.id===o)??null,m=(p==null?void 0:p.text.trim())||"(empty reply)";Ut(n,o,{text:m,delivery:"delivered",streamState:null,timestamp:new Date().toISOString(),error:null}),Ss(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:m.slice(0,200),last_error:null})}catch(p){if(p instanceof Error&&p.name==="AbortError")throw Ut(n,o,{delivery:"timeout",streamState:null,error:"Stream cancelled",timestamp:new Date().toISOString()}),Ss(n,{last_reply_status:"error",last_error:"Stream cancelled"}),lt(Dt,n,"Stream cancelled"),p;if(!((c=(ft.value[n]??[]).find(f=>f.id===o))!=null&&c.text.trim()))try{const f=await gu(n,s);Ut(n,o,{text:f.text.trim()||"(empty reply)",delivery:"delivered",streamState:null,details:f.details,error:null,timestamp:new Date().toISOString()}),Ut(n,a,{delivery:"delivered",error:null}),Ss(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(f.text.trim()||"(empty reply)").slice(0,200),last_error:null}),await ca();return}catch{}const v=p instanceof Error?p.message:`Failed to send direct message to ${n}`;throw Ut(n,o,{delivery:"error",streamState:null,error:v,timestamp:new Date().toISOString()}),Ut(n,a,{delivery:"error",error:v}),Ss(n,{last_reply_status:"error",last_error:v}),lt(Dt,n,v),p}finally{jl(n),lt(ra,n,!1),await ca()}}async function Wp(t,e){const n=t.trim();if(!n)return null;lt(Wi,n,!0),lt(Dt,n,null);try{const s=await Ga({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=Pp(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const l=Xt.value[n];Ja(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??ft.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ca(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw lt(Dt,n,a),s}finally{lt(Wi,n,!1)}}async function Gp(t,e){const n=t.trim();if(!n)return null;lt(Gi,n,!0),lt(Dt,n,null);try{const s=await Ga({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=zp(s.result),o=(a==null?void 0:a.after)??null;if(o){const l=Xt.value[n];Ja(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??ft.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ca(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw lt(Dt,n,a),s}finally{lt(Gi,n,!1)}}function he(t){return(t??"").trim().toLowerCase()}function gt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Ws(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Cs(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function $n(t){return t.last_heartbeat??Cs(t.last_turn_ago_s)??Cs(t.last_proactive_ago_s)??Cs(t.last_handoff_ago_s)??Cs(t.last_compaction_ago_s)}function Jp(t){const e=t.title.trim();return e||Ws(t.content)}function Yp(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Xp(t,e,n,s,a={}){var E;const o=he(t),l=e.filter(M=>he(M.assignee)===o&&(M.status==="claimed"||M.status==="in_progress")).length,c=n.filter(M=>he(M.from)===o).sort((M,P)=>gt(P.timestamp)-gt(M.timestamp))[0],p=s.filter(M=>he(M.agent)===o||he(M.author)===o).sort((M,P)=>gt(P.timestamp)-gt(M.timestamp))[0],m=(a.boardPosts??[]).filter(M=>he(M.author)===o).sort((M,P)=>gt(P.updated_at||P.created_at)-gt(M.updated_at||M.created_at))[0],u=(a.keepers??[]).filter(M=>he(M.name)===o&&$n(M)!==null).sort((M,P)=>gt($n(P)??0)-gt($n(M)??0))[0],v=c?gt(c.timestamp):0,f=p?gt(p.timestamp):0,$=m?gt(m.updated_at||m.created_at):0,C=u?gt($n(u)??0):0,b=a.lastSeen?gt(a.lastSeen):0,k=((E=a.currentTask)==null?void 0:E.trim())||(l>0?`${l} claimed tasks`:null);if(v===0&&f===0&&$===0&&C===0&&b===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:k};const S=[c?{timestamp:c.timestamp,ts:v,text:Ws(c.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:$,text:`Post: ${Ws(Jp(m))}`}:null,u?{timestamp:$n(u),ts:C,text:Yp(u)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:f,text:Ws(p.text)}:null].filter(M=>M!==null).sort((M,P)=>P.ts-M.ts)[0];return S&&S.ts>=b?{activeAssignedCount:l,lastActivityAt:S.timestamp,lastActivityText:S.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:k??"Presence heartbeat"}}const Vt=g([]),ae=g([]),Ji=g([]),ve=g([]),vt=g(null),Vp=g(null),ql=g([]),wl=g([]),Fl=g([]),Kl=g([]),Bl=g(null),Ul=g([]),Eo=g([]),Hl=g([]),Yi=g(new Map),Ya=g([]),wn=g("recent"),Ae=g(!0),Wl=g(null),Jt=g(""),Xe=g([]),Tn=g(!1),Gl=g(new Map),Lo=g("unknown"),Ve=g(null),Xi=g(!1),Fn=g(!1),Vi=g(!1),In=g(!1),Po=g(null),da=g(!1),ua=g(null),Jl=g(null),Qi=g(null),Qp=g(null),Zp=g(null),tm=g(null);Rt(()=>Vt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const Yl=Rt(()=>{const t=ae.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Xl=Rt(()=>{const t=new Map,e=ae.value,n=Ji.value,s=aa.value,a=Ya.value,o=ve.value;for(const l of Vt.value)t.set(l.name.trim().toLowerCase(),Xp(l.name,e,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:o}));return t});function em(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}Rt(()=>{const t=new Map;for(const e of ve.value)t.set(e.name,em(e));return t});const nm=12e4;function sm(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}Rt(()=>{const t=Date.now(),e=new Set,n=Yi.value;for(const s of ve.value){const a=sm(s,n);a!=null&&t-a>nm&&e.add(s.name)}return e});function am(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function Vl(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function im(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function om(t){if(!_(t))return null;const e=r(t.name);return e?{name:e,agent_type:r(t.agent_type),status:Vl(t.status),current_task:r(t.current_task)??null,joined_at:r(t.joined_at),last_seen:r(t.last_seen),capabilities:F(t.capabilities),emoji:r(t.emoji),koreanName:r(t.koreanName)??r(t.korean_name),model:r(t.model),traits:F(t.traits),interests:F(t.interests),activityLevel:d(t.activityLevel)??d(t.activity_level),primaryValue:r(t.primaryValue)??r(t.primary_value)}:null}function rm(t){if(!_(t))return null;const e=r(t.id),n=r(t.title);return!e||!n?null:{id:e,title:n,status:im(t.status),priority:d(t.priority),assignee:r(t.assignee),description:r(t.description),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function lm(t){if(!_(t))return null;const e=r(t.from)??r(t.from_agent)??"system",n=r(t.content)??"",s=r(t.timestamp)??new Date().toISOString();return{id:r(t.id),seq:d(t.seq),from:e,content:n,timestamp:s,type:r(t.type)}}function zo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="ok"||e==="warn"||e==="bad"?e:"ok"}function ie(t){if(!_(t))return null;const e=r(t.surface),n=r(t.label),s=r(t.target_type),a=r(t.target_id),o=r(t.focus_kind);return!e||!n||!s||!a||!o?null:{surface:e==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:o,operation_id:r(t.operation_id)??null,command_surface:r(t.command_surface)??null}}function cm(t){if(!_(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.summary),a=r(t.target_type),o=r(t.target_id);return!e||!s||!a||!o||n!=="session"&&n!=="operation"?null:{id:e,kind:n,severity:zo(t.severity),status:r(t.status),summary:s,target_type:a,target_id:o,linked_session_id:r(t.linked_session_id)??null,linked_operation_id:r(t.linked_operation_id)??null,last_seen_at:r(t.last_seen_at)??null,top_handoff:ie(t.top_handoff),intervene_handoff:ie(t.intervene_handoff),command_handoff:ie(t.command_handoff)}}function dm(t){if(!_(t))return null;const e=r(t.session_id),n=r(t.goal);return!e||!n?null:{session_id:e,goal:n,room:r(t.room)??null,status:r(t.status),health:r(t.health),member_names:F(t.member_names),linked_operation_id:r(t.linked_operation_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,runtime_blocker:r(t.runtime_blocker)??null,worker_gap_summary:r(t.worker_gap_summary)??null,last_activity_at:r(t.last_activity_at)??null,last_activity_summary:r(t.last_activity_summary)??null,communication_summary:r(t.communication_summary)??null,active_count:d(t.active_count),required_count:d(t.required_count),top_handoff:ie(t.top_handoff),intervene_handoff:ie(t.intervene_handoff),command_handoff:ie(t.command_handoff)}}function um(t){if(!_(t))return null;const e=r(t.operation_id),n=r(t.objective);return!e||!n?null:{operation_id:e,objective:n,status:r(t.status),stage:r(t.stage)??null,assigned_unit_id:r(t.assigned_unit_id)??null,assigned_unit_label:r(t.assigned_unit_label)??null,linked_session_id:r(t.linked_session_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,blocker_summary:r(t.blocker_summary)??null,search_status:r(t.search_status)??null,next_tool:r(t.next_tool)??null,updated_at:r(t.updated_at)??null,top_handoff:ie(t.top_handoff),command_handoff:ie(t.command_handoff)}}function br(t){if(!_(t))return null;const e=r(t.name)??r(t.agent_name),n=r(t.note),s=r(t.focus),a=r(t.state);return!e||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline"?null:{name:e,agent_name:r(t.agent_name),status:r(t.status),tone:zo(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,active_task_count:d(t.active_task_count),related_session_id:r(t.related_session_id)??null,related_operation_id:r(t.related_operation_id)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),model:r(t.model)??null,recent_output_preview:r(t.recent_output_preview)??null,recent_event:r(t.recent_event)??null}}function pm(t){return _(t)?{checked:d(t.checked),acted:d(t.acted),passed:d(t.passed),skipped:d(t.skipped),failed:d(t.failed),last_tick_at:r(t.last_tick_at)??null,last_skip_reason:r(t.last_skip_reason)??null,activity_report:r(t.activity_report)??null}:null}function mm(t){if(!_(t))return null;const e=r(t.agent_name),n=r(t.outcome);return!e||!n?null:{agent_name:e,trigger:r(t.trigger)??null,outcome:n,summary:r(t.summary)??null,reason:r(t.reason)??null,allowed_tool_names:F(t.allowed_tool_names)??[],used_tool_names:F(t.used_tool_names)??[],used_tool_call_count:d(t.used_tool_call_count)??null,action_kind:r(t.action_kind)??"none",tool_audit_source:r(t.tool_audit_source)??null,tool_audit_at:r(t.tool_audit_at)??null,checked_at:r(t.checked_at)??null,decision_reason:r(t.decision_reason)??null,worker_name:r(t.worker_name)??null,failure_reason:r(t.failure_reason)??null}}function _m(t){if(!_(t))return null;const e=r(t.name),n=r(t.note),s=r(t.focus),a=r(t.state);return!e||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:e,agent_name:r(t.agent_name)??null,status:r(t.status),tone:zo(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,last_autonomous_action_at:r(t.last_autonomous_action_at)??null,generation:d(t.generation),turn_count:d(t.turn_count),context_ratio:d(t.context_ratio)??null,continuity:r(t.continuity)??null,lifecycle:r(t.lifecycle)??null,related_session_id:r(t.related_session_id)??null,model:r(t.model)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),skill_reason:r(t.skill_reason)??null,recent_input_preview:r(t.recent_input_preview)??null,recent_output_preview:r(t.recent_output_preview)??null,recent_tool_names:F(t.recent_tool_names)??[],allowed_tool_names:F(t.allowed_tool_names)??[],latest_tool_names:F(t.latest_tool_names)??[],latest_tool_call_count:d(t.latest_tool_call_count)??null,tool_audit_source:r(t.tool_audit_source)??null,tool_audit_at:r(t.tool_audit_at)??null,last_proactive_preview:r(t.last_proactive_preview)??null,continuity_summary:r(t.continuity_summary)??null,skill_route_summary:r(t.skill_route_summary)??null}}function kr(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function vm(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>kr(s)-kr(a)).slice(-500)}function fm(t){return Array.isArray(t)?t.map(e=>{if(!_(e))return null;const n=d(e.ts_unix);if(n==null)return null;const s=_(e.handoff)?e.handoff:null;return{ts:n,context_ratio:d(e.context_ratio)??0,context_tokens:d(e.context_tokens)??0,context_max:d(e.context_max)??0,latency_ms:d(e.latency_ms)??0,generation:d(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:d(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:d(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?d(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function xr(t){if(!_(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);if(!e||!n||!s)return null;const a=r(t.quiet_reason)??null,o=r(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:rt(t.last_reply_at)??r(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:d(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function gm(t,e){return(Array.isArray(t)?t:_(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!_(s))return null;const a=_(s.agent)?s.agent:null,o=_(s.context)?s.context:null,l=_(s.metrics_window)?s.metrics_window:void 0,c=r(s.name);if(!c)return null;const p=d(s.context_ratio)??d(o==null?void 0:o.context_ratio),m=r(s.status)??r(a==null?void 0:a.status)??"offline",u=Vl(m),v=r(s.model)??r(s.active_model)??r(s.primary_model),f=F(s.skill_secondary),$=o?{source:r(o.source),context_ratio:d(o.context_ratio),context_tokens:d(o.context_tokens),context_max:d(o.context_max),message_count:d(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,C=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:d(a.last_seen_ago_s),capabilities:F(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,b=fm(s.metrics_series),k={name:c,runtime_class:s.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:typeof s.desired=="boolean"?s.desired:void 0,resident_registered:typeof s.resident_registered=="boolean"?s.resident_registered:void 0,reconcile_status:r(s.reconcile_status)??null,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:v,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:u,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:d(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:d(s.proactive_idle_sec),proactive_cooldown_sec:d(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:d(s.generation),turn_count:d(s.turn_count)??d(s.total_turns),keeper_age_s:d(s.keeper_age_s),last_turn_ago_s:d(s.last_turn_ago_s),last_handoff_ago_s:d(s.last_handoff_ago_s),last_compaction_ago_s:d(s.last_compaction_ago_s),last_proactive_ago_s:d(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:p,context_tokens:d(s.context_tokens)??d(o==null?void 0:o.context_tokens),context_max:d(s.context_max)??d(o==null?void 0:o.context_max),context_source:r(s.context_source)??r(o==null?void 0:o.source),context:$,traits:F(s.traits),interests:F(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:d(s.activityLevel)??d(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:F(s.recent_tool_names)??[],allowed_tool_names:F(s.allowed_tool_names)??[],latest_tool_names:F(s.latest_tool_names)??[],latest_tool_call_count:d(s.latest_tool_call_count)??null,tool_audit_source:r(s.tool_audit_source)??null,tool_audit_at:rt(s.tool_audit_at)??r(s.tool_audit_at)??null,conversation_tail_count:d(s.conversation_tail_count),k2k_count:d(s.k2k_count),handoff_count_total:d(s.handoff_count_total)??d(s.trace_history_count),compaction_count:d(s.compaction_count),last_compaction_saved_tokens:d(s.last_compaction_saved_tokens),diagnostic:xr(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:f,skill_reason:r(s.skill_reason)??null,metrics_series:b.length>0?b:void 0,metrics_window:l,agent:C};return k.diagnostic=xr(s.diagnostic)??Np(k,(e==null?void 0:e.lodge)??null),k}).filter(s=>s!==null)}function $m(t){if(!_(t))return;const e=r(t.release_version),n=rt(t.started_at),s=d(t.uptime_seconds);if(!(!e||!n||s==null))return{release_version:e,commit:r(t.commit)??null,started_at:n,uptime_seconds:s}}function hm(t){if(_(t))return{enabled:t.enabled===!0,alive:t.alive===!0,status:r(t.status)??void 0,tick_in_progress:typeof t.tick_in_progress=="boolean"?t.tick_in_progress:void 0,tick_count:d(t.tick_count)??void 0,check_interval_sec:d(t.check_interval_sec)??void 0,last_tick_started_at:rt(t.last_tick_started_at)??r(t.last_tick_started_at)??null,last_tick_completed_at:rt(t.last_tick_completed_at)??r(t.last_tick_completed_at)??null,next_tick_due_at:rt(t.next_tick_due_at)??r(t.next_tick_due_at)??null,last_health_check_at:rt(t.last_health_check_at)??r(t.last_health_check_at)??null,last_intervention:r(t.last_intervention)??void 0,last_decision_source:r(t.last_decision_source)??void 0,last_action:r(t.last_action)??void 0,last_target:r(t.last_target)??null,last_reason:r(t.last_reason)??null,last_error:r(t.last_error)??null,circuit_open:typeof t.circuit_open=="boolean"?t.circuit_open:void 0,circuit_open_until:rt(t.circuit_open_until)??r(t.circuit_open_until)??null,can_spawn:typeof t.can_spawn=="boolean"?t.can_spawn:void 0,can_retire:typeof t.can_retire=="boolean"?t.can_retire:void 0,last_spawn_attempt_at:rt(t.last_spawn_attempt_at)??r(t.last_spawn_attempt_at)??null,last_retirement_attempt_at:rt(t.last_retirement_attempt_at)??r(t.last_retirement_attempt_at)??null,spawns_today:d(t.spawns_today)??void 0,retirements_today:d(t.retirements_today)??void 0,health_summary:_(t.health_summary)?{total_agents:d(t.health_summary.total_agents)??void 0,active_agents:d(t.health_summary.active_agents)??void 0,idle_agents:d(t.health_summary.idle_agents)??void 0,todo_count:d(t.health_summary.todo_count)??void 0,high_priority_todo:d(t.health_summary.high_priority_todo)??void 0,orphan_count:d(t.health_summary.orphan_count)??void 0,homeostatic_score:d(t.health_summary.homeostatic_score)??void 0,needs_workers:typeof t.health_summary.needs_workers=="boolean"?t.health_summary.needs_workers:void 0}:void 0}}function ym(t){if(_(t))return{enabled:t.enabled===!0,mode:r(t.mode)??void 0,masc_enabled:typeof t.masc_enabled=="boolean"?t.masc_enabled:void 0,masc_loops_running:typeof t.masc_loops_running=="boolean"?t.masc_loops_running:void 0,runtime_owner:r(t.runtime_owner)??null,zombie_loop_running:typeof t.zombie_loop_running=="boolean"?t.zombie_loop_running:void 0,gc_loop_running:typeof t.gc_loop_running=="boolean"?t.gc_loop_running:void 0,lodge_enabled:typeof t.lodge_enabled=="boolean"?t.lodge_enabled:void 0,lodge_loop_started:typeof t.lodge_loop_started=="boolean"?t.lodge_loop_started:void 0,lodge_running:typeof t.lodge_running=="boolean"?t.lodge_running:void 0,last_zombie_cleanup:rt(t.last_zombie_cleanup)??r(t.last_zombie_cleanup)??null,last_gc:rt(t.last_gc)??r(t.last_gc)??null,last_lodge:rt(t.last_lodge)??r(t.last_lodge)??null,last_zombie_result:r(t.last_zombie_result)??null,last_gc_result:r(t.last_gc_result)??null,last_lodge_result:_(t.last_lodge_result)?{ok:typeof t.last_lodge_result.ok=="boolean"?t.last_lodge_result.ok:void 0,message:r(t.last_lodge_result.message)??void 0}:null}}function bm(t){if(_(t))return{enabled:t.enabled===!0,started:t.started===!0,agent_name:r(t.agent_name)??null,llm_enabled:typeof t.llm_enabled=="boolean"?t.llm_enabled:void 0,uptime_s:d(t.uptime_s)??void 0,embedded_guardian_loops_running:typeof t.embedded_guardian_loops_running=="boolean"?t.embedded_guardian_loops_running:void 0,guardian_runtime_owner:r(t.guardian_runtime_owner)??null,consumers:F(t.consumers)}}function Ql(t,e){return _(t)?{...t,generated_at:e??rt(t.generated_at)??void 0,build:$m(t.build),lodge:Lp(t.lodge)??void 0,gardener:hm(t.gardener)??void 0,guardian:ym(t.guardian)??void 0,sentinel:bm(t.sentinel)??void 0}:null}function Zl(t,e){return e?t?{...t,...e,build:e.build??t.build,generated_at:e.generated_at??t.generated_at}:e:t}function km(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function xm(t){if(!_(t))return null;const e=d(t.iteration);if(e==null)return null;const n=d(t.metric_before)??0,s=d(t.metric_after)??n,a=_(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:d(t.delta)??s-n,changes:r(t.changes)??"",failed_attempts:r(t.failed_attempts)??"",next_suggestion:r(t.next_suggestion)??"",elapsed_ms:d(t.elapsed_ms)??0,cost_usd:d(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:d(a.tool_call_count)??0,tool_names:F(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function Sm(t){var o,l;if(!_(t))return null;const e=r(t.loop_id);if(!e)return null;const n=d(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(xm).filter(c=>c!==null):[],a=d(t.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:r(t.profile)??"unknown",status:km(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:r(t.error_message)??r(t.error_reason)??null,stop_reason:r(t.stop_reason)??r(t.reason)??null,current_iteration:d(t.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:d(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(t.target)??"",stagnation_streak:d(t.stagnation_streak)??0,stagnation_limit:d(t.stagnation_limit)??0,elapsed_seconds:d(t.elapsed_seconds)??0,updated_at:rt(t.updated_at)??null,stopped_at:rt(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:d(t.latest_tool_call_count)??0,latest_tool_names:F(t.latest_tool_names)??[],session_id:r(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function ls(){Xi.value=!0;try{await Promise.all([ec(),Te()]),Jl.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{Xi.value=!1}}async function tc(){da.value=!0,ua.value=null;try{const t=await Cu();Po.value=t,tm.value=new Date().toISOString()}catch(t){ua.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{da.value=!1}}function Cm(t){var e;return((e=Po.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function Am(t){var n;const e=((n=Po.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(o=>o.id===t);if(a)return a}return null}function Tm(t){var s,a;Xe.value=(Array.isArray(t.goals)?t.goals:[]).map(o=>{if(!_(o))return null;const l=r(o.id),c=r(o.title),p=r(o.horizon),m=r(o.status),u=r(o.created_at),v=r(o.updated_at);return!l||!c||!p||!m||!u||!v?null:{id:l,horizon:p,title:c,metric:r(o.metric)??null,target_value:r(o.target_value)??null,due_date:r(o.due_date)??null,priority:d(o.priority)??3,status:m,parent_goal_id:r(o.parent_goal_id)??null,last_review_note:r(o.last_review_note)??null,last_review_at:r(o.last_review_at)??null,created_at:u,updated_at:v}}).filter(o=>o!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const o of n){const l=Sm(o);l&&e.set(l.loop_id,l)}Gl.value=e,Ve.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,Lo.value=Ve.value?"error":e.size===0?"idle":"ready"}async function ec(){try{const t=await yu(),e=Ql(t.status,t.generated_at);e&&(vt.value=Zl(vt.value,e))}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Te(){var t;try{const e=await ku(),n=Ql(e.status,e.generated_at),s=(t=vt.value)==null?void 0:t.room;n&&(vt.value=Zl(vt.value,n));const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Vt.value=(Array.isArray(e.agents)?e.agents:[]).map(om).filter(l=>l!==null),ae.value=(Array.isArray(e.tasks)?e.tasks:[]).map(rm).filter(l=>l!==null);const o=(Array.isArray(e.messages)?e.messages:[]).map(lm).filter(l=>l!==null);Ji.value=a?o:vm(Ji.value,o),ve.value=gm(e.keepers,n??vt.value),Bl.value=pm(e.lodge_tick),Ul.value=(Array.isArray(e.lodge_checkins)?e.lodge_checkins:[]).map(mm).filter(l=>l!==null),ql.value=(Array.isArray(e.execution_queue)?e.execution_queue:Array.isArray(e.priority_queue)?e.priority_queue:[]).map(cm).filter(l=>l!==null),wl.value=(Array.isArray(e.session_briefs)?e.session_briefs:[]).map(dm).filter(l=>l!==null),Fl.value=(Array.isArray(e.operation_briefs)?e.operation_briefs:[]).map(um).filter(l=>l!==null),Kl.value=(Array.isArray(e.worker_support_briefs)?e.worker_support_briefs:Array.isArray(e.worker_briefs)?e.worker_briefs:[]).map(br).filter(l=>l!==null),Eo.value=(Array.isArray(e.continuity_briefs)?e.continuity_briefs:[]).map(_m).filter(l=>l!==null),Hl.value=(Array.isArray(e.offline_worker_briefs)?e.offline_worker_briefs:[]).map(br).filter(l=>l!==null),Vp.value=null,Jl.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function oe(){Fn.value=!0;try{const t=await xu(wn.value,{excludeSystem:Ae.value});Ya.value=t.posts??[],Qi.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Fn.value=!1}}async function re(){var t;Vi.value=!0;try{const e=Jt.value||((t=vt.value)==null?void 0:t.room)||"default";Jt.value||(Jt.value=e);const n=await up(e);Wl.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Vi.value=!1}}async function No(){Tn.value=!0,In.value=!0;try{const t=await Mu();Tm(t),Qp.value=new Date().toISOString(),Zp.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),Lo.value="error",Ve.value=t instanceof Error?t.message:String(t)}finally{Tn.value=!1,In.value=!1}}async function nc(){return No()}const jo=g(null),Zi=g(!1),pa=g(null);function Im(t){return _(t)?{room:r(t.room)??r(t.current_room),room_base_path:r(t.room_base_path),cluster:r(t.cluster),project:r(t.project),paused:N(t.paused),version:r(t.version),generated_at:r(t.generated_at),tempo_interval_s:d(t.tempo_interval_s)}:null}function Rm(t){return _(t)?{active_sessions:d(t.active_sessions),blocked_sessions:d(t.blocked_sessions),active_operations:d(t.active_operations),blocked_operations:d(t.blocked_operations),runtime_pressure:d(t.runtime_pressure),worker_alerts:d(t.worker_alerts),continuity_alerts:d(t.continuity_alerts),priority_items:d(t.priority_items),keepers:d(t.keepers)}:null}function Mm(t){if(!_(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.severity),a=r(t.summary),o=r(t.target_type),l=r(t.target_id);return!e||!n||!s||!a||!o||!l?null:{id:e,kind:n,severity:s,summary:a,target_type:o,target_id:l,status:r(t.status),linked_session_id:r(t.linked_session_id)??null,linked_operation_id:r(t.linked_operation_id)??null,last_seen_at:r(t.last_seen_at)??null,top_handoff:_(t.top_handoff)?t.top_handoff:null,intervene_handoff:_(t.intervene_handoff)?t.intervene_handoff:null,command_handoff:_(t.command_handoff)?t.command_handoff:null}}function Em(t){if(!_(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function Lm(t){if(!_(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:N(t.confirm_required),suggested_payload:_(t.suggested_payload)?t.suggested_payload:void 0,preview:t.preview}}function Pm(t){return _(t)?{actor_filter:r(t.actor_filter)??null,filter_active:N(t.filter_active)??!1,visible_count:d(t.visible_count)??0,total_count:d(t.total_count)??0,hidden_count:d(t.hidden_count)??0,hidden_actors:F(t.hidden_actors),confirm_required_actions:pt(t.confirm_required_actions).flatMap(e=>{if(!_(e))return[];const n=r(e.action_type),s=r(e.target_type);return!n||!s?[]:[{action_type:n,target_type:s,description:r(e.description),confirm_required:N(e.confirm_required)}]})}:null}function zm(t){return _(t)?{count:d(t.count)??0,bad_count:d(t.bad_count)??0,warn_count:d(t.warn_count)??0,provenance:r(t.provenance)??null,top_item:Em(t.top_item)}:null}function Nm(t){return _(t)?{count:d(t.count)??0,provenance:r(t.provenance)??null,top_action:Lm(t.top_action)}:null}function jm(t){if(!_(t))return null;const e=r(t.label),n=r(t.reason),s=r(t.source),a=r(t.provenance);return!e||!n||!s||!a?null:{label:e,reason:n,source:s,provenance:a,target_kind:r(t.target_kind)??null,target_id:r(t.target_id)??null,suggested_tab:r(t.suggested_tab)??null,suggested_surface:r(t.suggested_surface)??null,suggested_params:_(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([o,l])=>{const c=r(l);return c?[o,c]:null}).filter(o=>o!==null)):{}}}function Om(t){const e=_(t)?t:{},n=_(e.room)?e.room:{},s=_(e.execution)?e.execution:{},a=_(e.command)?e.command:{},o=_(e.operator)?e.operator:{};return{generated_at:r(e.generated_at),room:{status:Im(n.status),counts:_(n.counts)?{agents:d(n.counts.agents),tasks:d(n.counts.tasks),keepers:d(n.counts.keepers)}:void 0,provenance:r(n.provenance)??null},execution:{summary:Rm(s.summary),top_queue:Mm(s.top_queue),provenance:r(s.provenance)??null},command:{active_operations:d(a.active_operations),active_detachments:d(a.active_detachments),pending_approvals:d(a.pending_approvals),bad_alerts:d(a.bad_alerts),warn_alerts:d(a.warn_alerts),moving_lanes:d(a.moving_lanes),active_lanes:d(a.active_lanes),provenance:r(a.provenance)??null},operator:{health:r(o.health)??null,attention_summary:zm(o.attention_summary),recommendation_summary:Nm(o.recommendation_summary),pending_confirm_summary:Pm(o.pending_confirm_summary),provenance:r(o.provenance)??null},focus:jm(e.focus)}}async function Ie(){Zi.value=!0,pa.value=null;try{const t=await bu();jo.value=Om(t)}catch(t){pa.value=t instanceof Error?t.message:"Failed to load room truth"}finally{Zi.value=!1}}let Gs=null;function Dm(t){Gs=t}let Js=null;function qm(t){Js=t}let Ys=null;function wm(t){Ys=t}const Re={};let oi=null;function ye(t,e,n=500){Re[t]&&clearTimeout(Re[t]),Re[t]=setTimeout(()=>{e(),delete Re[t]},n)}function Fm(){const t=$l.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Yi.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Yi.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&ye("execution",Te),am(e.type)&&(oi||(oi=setTimeout(()=>{ls(),Js==null||Js(),Ys==null||Ys(),oi=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&ye("execution",Te),e.type==="broadcast"&&ye("execution",Te),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&ye("execution",Te),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&ye("board",oe),e.type.startsWith("decision_")&&ye("council",()=>Gs==null?void 0:Gs()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&ye("mdal",nc,350)}});return()=>{t();for(const e of Object.keys(Re))clearTimeout(Re[e]),delete Re[e]}}let Rn=null;function Km(){Rn||(Rn=setInterval(()=>{ue.value,ls()},1e4))}function Bm(){Rn&&(clearInterval(Rn),Rn=null)}const Mt=g(null),Oo=g(null),wt=g(null),Kn=g(!1),pe=g(null),Bn=g(!1),rn=g(null),Z=g(!1),ma=g([]);let Um=1;function Hm(t){return _(t)?{id:r(t.id),seq:d(t.seq),from:r(t.from)??r(t.from_agent)??"system",content:r(t.content)??"",timestamp:r(t.timestamp)??new Date().toISOString(),type:r(t.type)}:null}function Wm(t){if(!_(t))return{};const e=r(t.current_room)??r(t.room);return{room_id:r(t.room_id)??e,current_room:e,project:r(t.project),cluster:r(t.cluster),paused:N(t.paused),pause_reason:r(t.pause_reason)??null,paused_by:r(t.paused_by)??null,paused_at:r(t.paused_at)??null}}function Sr(t){if(!_(t))return;const e=Object.entries(t).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function sc(t){if(!_(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function Mn(t){if(!_(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:N(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function ac(t){return _(t)?{enabled:N(t.enabled),judge_online:N(t.judge_online),refreshing:N(t.refreshing),generated_at:r(t.generated_at)??null,expires_at:r(t.expires_at)??null,model_used:r(t.model_used)??null,keeper_name:r(t.keeper_name)??null,last_error:r(t.last_error)??null}:null}function ri(t){return _(t)?{summary:r(t.summary)??null,confidence:d(t.confidence)??null,provenance:r(t.provenance)??null,authoritative:N(t.authoritative),surface:r(t.surface)??null,fresh_until:r(t.fresh_until)??null,keeper_name:r(t.keeper_name)??null,fallback_used:N(t.fallback_used),disagreement_with_truth:N(t.disagreement_with_truth)}:null}function Gm(t){return _(t)?{judgment_id:r(t.judgment_id)??void 0,surface:r(t.surface)??null,target_type:r(t.target_type)??null,target_id:r(t.target_id)??null,status:r(t.status)??null,summary:r(t.summary)??null,confidence:d(t.confidence)??null,generated_at:r(t.generated_at)??null,fresh_until:r(t.fresh_until)??null,keeper_name:r(t.keeper_name)??null,model_name:r(t.model_name)??null,runtime_name:r(t.runtime_name)??null,evidence_refs:F(t.evidence_refs),recommended_action:Mn(t.recommended_action),supersedes:F(t.supersedes),fallback_used:N(t.fallback_used),disagreement_with_truth:N(t.disagreement_with_truth),provenance:r(t.provenance)??null}:null}function Jm(t){return _(t)?{actor:r(t.actor)??null,spawn_agent:r(t.spawn_agent)??null,spawn_role:r(t.spawn_role)??null,spawn_model:r(t.spawn_model)??null,worker_class:r(t.worker_class)??null,parent_actor:r(t.parent_actor)??null,capsule_mode:r(t.capsule_mode)??null,runtime_pool:r(t.runtime_pool)??null,lane_id:r(t.lane_id)??null,controller_level:r(t.controller_level)??null,control_domain:r(t.control_domain)??null,supervisor_actor:r(t.supervisor_actor)??null,model_tier:r(t.model_tier)??null,task_profile:r(t.task_profile)??null,risk_level:r(t.risk_level)??null,routing_confidence:d(t.routing_confidence)??null,routing_reason:r(t.routing_reason)??null,status:r(t.status)??"unknown",turn_count:d(t.turn_count)??0,empty_note_turn_count:d(t.empty_note_turn_count)??0,has_turn:N(t.has_turn)??!1,last_turn_ts_iso:r(t.last_turn_ts_iso)??null}:null}function Ym(t){if(!_(t))return null;const e=r(t.session_id);return e?{session_id:e,goal:r(t.goal),status:r(t.status),health:r(t.health),scale_profile:r(t.scale_profile),control_profile:r(t.control_profile),planned_worker_count:d(t.planned_worker_count),active_agent_count:d(t.active_agent_count),last_turn_age_sec:d(t.last_turn_age_sec)??null,attention_count:d(t.attention_count),recommended_action_count:d(t.recommended_action_count),top_attention:sc(t.top_attention),top_recommendation:Mn(t.top_recommendation)}:null}function ic(t){const e=_(t)?t:{};return{trace_id:r(e.trace_id),target_type:r(e.target_type)??"room",target_id:r(e.target_id)??null,health:r(e.health),judgment_owner:r(e.judgment_owner)??null,authoritative_judgment_available:N(e.authoritative_judgment_available),resident_judge_runtime:ac(e.resident_judge_runtime),judgment:Gm(e.judgment),active_guidance_layer:r(e.active_guidance_layer)??null,active_summary:ri(e.active_summary),active_recommended_actions:pt(e.active_recommended_actions).map(Mn).filter(n=>n!==null),active_recommendation_source:r(e.active_recommendation_source)??null,active_recommendation_summary:ri(e.active_recommendation_summary),fallback_recommended_actions:pt(e.fallback_recommended_actions).map(Mn).filter(n=>n!==null),recommendation_summary:ri(e.recommendation_summary),swarm_status:_(e.swarm_status)?e.swarm_status:void 0,attention_items:pt(e.attention_items).map(sc).filter(n=>n!==null),recommended_actions:pt(e.recommended_actions).map(Mn).filter(n=>n!==null),session_cards:pt(e.session_cards).map(Ym).filter(n=>n!==null),worker_cards:pt(e.worker_cards).map(Jm).filter(n=>n!==null)}}function Xm(t){if(!_(t))return null;const e=_(t.status)?t.status:void 0,n=_(t.summary)?t.summary:_(e==null?void 0:e.summary)?e.summary:void 0,s=_(t.session)?t.session:_(e==null?void 0:e.session)?e.session:void 0,a=r(t.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const o=Sr(t.report_paths)??Sr(e==null?void 0:e.report_paths),l=pt(t.recent_events,["events"]).filter(_);return{session_id:a,status:r(t.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:d(t.progress_pct)??d(n==null?void 0:n.progress_pct),elapsed_sec:d(t.elapsed_sec)??d(n==null?void 0:n.elapsed_sec),remaining_sec:d(t.remaining_sec)??d(n==null?void 0:n.remaining_sec),done_delta_total:d(t.done_delta_total)??d(n==null?void 0:n.done_delta_total),summary:n,team_health:_(t.team_health)?t.team_health:_(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:_(t.communication_metrics)?t.communication_metrics:_(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:_(t.orchestration_state)?t.orchestration_state:_(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:_(t.cascade_metrics)?t.cascade_metrics:_(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,linked_autoresearch:_(t.linked_autoresearch)?t.linked_autoresearch:_(e==null?void 0:e.linked_autoresearch)?e.linked_autoresearch:void 0,session:s,recent_events:l}}function Cr(t){if(!_(t))return null;const e=r(t.name);if(!e)return null;const n=_(t.context)?t.context:void 0;return{name:e,runtime_class:t.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:N(t.desired),resident_registered:N(t.resident_registered),agent_name:r(t.agent_name),status:r(t.status),autonomy_level:r(t.autonomy_level),context_ratio:d(t.context_ratio)??d(n==null?void 0:n.context_ratio),generation:d(t.generation),active_goal_ids:F(t.active_goal_ids),last_autonomous_action_at:r(t.last_autonomous_action_at)??null,last_turn_ago_s:d(t.last_turn_ago_s),model:r(t.model)??r(t.active_model)??r(t.primary_model)}}function Vm(t){if(!_(t))return null;const e=r(t.confirm_token)??r(t.token);return e?{confirm_token:e,actor:r(t.actor),action_type:r(t.action_type),target_type:r(t.target_type),target_id:r(t.target_id)??null,delegated_tool:r(t.delegated_tool),created_at:r(t.created_at),preview:t.preview}:null}function oc(t){if(!_(t))return null;const e=r(t.action_type),n=r(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:r(t.description),confirm_required:N(t.confirm_required)}}function Qm(t){return _(t)?{actor_filter:r(t.actor_filter)??null,filter_active:N(t.filter_active)??!1,visible_count:d(t.visible_count)??0,total_count:d(t.total_count)??0,hidden_count:d(t.hidden_count)??0,hidden_actors:F(t.hidden_actors),confirm_required_actions:pt(t.confirm_required_actions).map(oc).filter(e=>e!==null)}:null}function Zm(t){const e=_(t)?t:{};return{room:Wm(e.room),sessions:pt(e.sessions,["items","sessions"]).map(Xm).filter(n=>n!==null),keepers:pt(e.keepers,["items","keepers"]).map(Cr).filter(n=>n!==null),resident_judge_runtime:ac(e.resident_judge_runtime),persistent_agents:pt(e.persistent_agents,["items","persistent_agents"]).map(Cr).filter(n=>n!==null),recent_messages:pt(e.recent_messages,["messages"]).map(Hm).filter(n=>n!==null),pending_confirms:pt(e.pending_confirms,["items","confirms"]).map(Vm).filter(n=>n!==null),pending_confirm_summary:Qm(e.pending_confirm_summary)??void 0,available_actions:pt(e.available_actions,["actions"]).map(oc).filter(n=>n!==null)}}function As(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Ar(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function _a(t){ma.value=[{...t,id:Um++,at:new Date().toISOString()},...ma.value].slice(0,20)}function rc(t){return t.confirm_required?As(t.preview)||"Confirmation required":As(t.result)||As(t.executed_action)||As(t.delegated_tool_result)||t.status}async function bt(){Kn.value=!0,pe.value=null;try{const t=await Pu();Mt.value=Zm(t)}catch(t){pe.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Kn.value=!1}}async function ze(){Bn.value=!0,rn.value=null;try{const t=await Cl({targetType:"room"});Oo.value=ic(t)}catch(t){rn.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{Bn.value=!1}}async function ln(t){if(!t){wt.value=null;return}Bn.value=!0,rn.value=null;try{const e=await Cl({targetType:"team_session",targetId:t,includeWorkers:!0});wt.value=ic(e)}catch(e){rn.value=e instanceof Error?e.message:"Failed to load session digest"}finally{Bn.value=!1}}async function lc(t){var e;Z.value=!0,pe.value=null;try{const n=await Ga(t);return _a({actor:t.actor,action_type:t.action_type,target_label:Ar(t),outcome:n.confirm_required?"preview":"executed",message:rc(n),delegated_tool:n.delegated_tool}),await bt(),await ze(),(e=wt.value)!=null&&e.target_id&&await ln(wt.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw pe.value=s,_a({actor:t.actor,action_type:t.action_type,target_label:Ar(t),outcome:"error",message:s}),n}finally{Z.value=!1}}async function cc(t,e,n="confirm"){var s;Z.value=!0,pe.value=null;try{const a=await Al(t,e,n);return _a({actor:t,action_type:n,target_label:e,outcome:"confirmed",message:rc(a),delegated_tool:a.delegated_tool}),await bt(),await ze(),(s=wt.value)!=null&&s.target_id&&await ln(wt.value.target_id),a}catch(a){const o=a instanceof Error?a.message:"Operator confirmation failed";throw pe.value=o,_a({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:o}),a}finally{Z.value=!1}}wm(()=>{var t;bt(),ze(),(t=wt.value)!=null&&t.target_id&&ln(wt.value.target_id)});const Xa=g(null),to=g(!1),va=g(null),dc=g(null),Fe=g(!1),Ce=g(null),eo=g(null),Xs=g(!1),Vs=g(null);let Qe=null;function Tr(){Qe!==null&&(window.clearTimeout(Qe),Qe=null)}function t_(t=1500){Qe===null&&(Qe=window.setTimeout(()=>{Qe=null,fa(!1)},t))}function O(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function y(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function q(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ze(t){return typeof t=="boolean"?t:void 0}function H(t,e=[]){if(Array.isArray(t))return t;if(!O(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function mn(t){if(!O(t))return null;const e=y(t.kind),n=y(t.summary),s=y(t.target_type);return!e||!n||!s?null:{kind:e,severity:y(t.severity)??"warn",summary:n,target_type:s,target_id:y(t.target_id)??null,actor:y(t.actor)??null,evidence:t.evidence}}function je(t){if(!O(t))return null;const e=y(t.action_type),n=y(t.target_type),s=y(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:y(t.target_id)??null,severity:y(t.severity)??"warn",reason:s,confirm_required:Ze(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function e_(t){if(!O(t))return null;const e=y(t.session_id);return e?{session_id:e,goal:y(t.goal),status:y(t.status),health:y(t.health),scale_profile:y(t.scale_profile),control_profile:y(t.control_profile),planned_worker_count:q(t.planned_worker_count),active_agent_count:q(t.active_agent_count),last_turn_age_sec:q(t.last_turn_age_sec)??null,attention_count:q(t.attention_count),recommended_action_count:q(t.recommended_action_count),top_attention:mn(t.top_attention),top_recommendation:je(t.top_recommendation)}:null}function n_(t){if(!O(t))return null;const e=y(t.session_id);if(!e)return null;const n=O(t.status)?t.status:t,s=O(n.summary)?n.summary:void 0;return{session_id:e,status:y(t.status)??y(s==null?void 0:s.status)??(O(n.session)?y(n.session.status):void 0),progress_pct:q(t.progress_pct)??q(s==null?void 0:s.progress_pct),elapsed_sec:q(t.elapsed_sec)??q(s==null?void 0:s.elapsed_sec),remaining_sec:q(t.remaining_sec)??q(s==null?void 0:s.remaining_sec),done_delta_total:q(t.done_delta_total)??q(s==null?void 0:s.done_delta_total),summary:O(t.summary)?t.summary:s,team_health:O(t.team_health)?t.team_health:O(n.team_health)?n.team_health:void 0,communication_metrics:O(t.communication_metrics)?t.communication_metrics:O(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:O(t.orchestration_state)?t.orchestration_state:O(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:O(t.cascade_metrics)?t.cascade_metrics:O(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:O(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,o])=>{const l=y(o);return l?[a,l]:null}).filter(a=>a!==null)):O(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const l=y(o);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:O(t.session)?t.session:O(n.session)?n.session:void 0,recent_events:H(t.recent_events,["events"]).filter(O)}}function s_(t){if(!O(t))return null;const e=y(t.name);return e?{name:e,agent_name:y(t.agent_name),status:y(t.status),autonomy_level:y(t.autonomy_level),context_ratio:q(t.context_ratio),generation:q(t.generation),active_goal_ids:H(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:y(t.last_autonomous_action_at)??null,last_turn_ago_s:q(t.last_turn_ago_s),model:y(t.model)}:null}function a_(t){if(!O(t))return null;const e=y(t.confirm_token)??y(t.token);return e?{confirm_token:e,actor:y(t.actor),action_type:y(t.action_type),target_type:y(t.target_type),target_id:y(t.target_id)??null,delegated_tool:y(t.delegated_tool),created_at:y(t.created_at),preview:t.preview}:null}function i_(t){if(!O(t))return null;const e=y(t.action_type),n=y(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:y(t.description),confirm_required:Ze(t.confirm_required)}}function o_(t){const e=O(t)?t:{};return{room_health:y(e.room_health),cluster:y(e.cluster),project:y(e.project),current_room:y(e.current_room)??y(e.room)??null,paused:Ze(e.paused),tempo_interval_s:q(e.tempo_interval_s),active_agents:q(e.active_agents),keeper_pressure:q(e.keeper_pressure),active_operations:q(e.active_operations),pending_approvals:q(e.pending_approvals),incident_count:q(e.incident_count),recommended_action_count:q(e.recommended_action_count),top_attention:mn(e.top_attention),top_action:je(e.top_action)}}function r_(t){const e=O(t)?t:{},n=O(e.swarm_overview)?e.swarm_overview:{};return{health:y(e.health),active_operations:q(e.active_operations),pending_approvals:q(e.pending_approvals),swarm_overview:{active_lanes:q(n.active_lanes),moving_lanes:q(n.moving_lanes),stalled_lanes:q(n.stalled_lanes),projected_lanes:q(n.projected_lanes),last_movement_at:y(n.last_movement_at)??null},top_attention:mn(e.top_attention),top_action:je(e.top_action),session_cards:H(e.session_cards).map(e_).filter(s=>s!==null)}}function l_(t){const e=O(t)?t:{};return{sessions:H(e.sessions,["items"]).map(n_).filter(n=>n!==null),keepers:H(e.keepers,["items"]).map(s_).filter(n=>n!==null),pending_confirms:H(e.pending_confirms).map(a_).filter(n=>n!==null),available_actions:H(e.available_actions).map(i_).filter(n=>n!==null)}}function c_(t){if(!O(t))return null;const e=y(t.id),n=y(t.kind),s=y(t.summary),a=y(t.target_type);return!e||!n||!s||!a?null:{id:e,kind:n,severity:y(t.severity)??"warn",summary:s,target_type:a,target_id:y(t.target_id)??null,top_action:je(t.top_action),related_session_ids:H(t.related_session_ids).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),related_agent_names:H(t.related_agent_names).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),evidence_preview:H(t.evidence_preview).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),last_seen_at:y(t.last_seen_at)??null}}function uc(t){if(!O(t))return null;const e=y(t.session_id),n=y(t.goal);return!e||!n?null:{session_id:e,goal:n,room:y(t.room)??null,status:y(t.status),health:y(t.health),member_names:H(t.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:y(t.started_at)??null,elapsed_sec:q(t.elapsed_sec)??null,operation_id:y(t.operation_id)??null,blocker_summary:y(t.blocker_summary)??null,last_event_at:y(t.last_event_at)??null,last_event_summary:y(t.last_event_summary)??null,communication_summary:y(t.communication_summary)??null,active_count:q(t.active_count),required_count:q(t.required_count),related_attention_count:q(t.related_attention_count)??0,top_attention:mn(t.top_attention),top_recommendation:je(t.top_recommendation)}}function pc(t){if(!O(t))return null;const e=y(t.agent_name);return e?{agent_name:e,display_name:y(t.display_name)??null,is_live:typeof t.is_live=="boolean"?t.is_live:void 0,current_work:y(t.current_work)??null,recent_input_preview:y(t.recent_input_preview)??null,recent_output_preview:y(t.recent_output_preview)??null,recent_tool_names:H(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_activity_at:y(t.last_activity_at)??null}:null}function mc(t){if(!O(t))return null;const e=y(t.operation_id);return e?{operation_id:e,status:y(t.status),stage:y(t.stage)??null,detachment_status:y(t.detachment_status)??null,objective:y(t.objective)??null,updated_at:y(t.updated_at)??null}:null}function _c(t){if(!O(t))return null;const e=y(t.name);return e?{name:e,agent_name:y(t.agent_name)??null,status:y(t.status),generation:q(t.generation),context_ratio:q(t.context_ratio)??null,last_turn_ago_s:q(t.last_turn_ago_s)??null,current_work:y(t.current_work)??null}:null}function vc(t){const e=uc(t);return e?{...e,member_previews:H(O(t)?t.member_previews:void 0).map(pc).filter(n=>n!==null),operation_badges:H(O(t)?t.operation_badges:void 0).map(mc).filter(n=>n!==null),keeper_refs:H(O(t)?t.keeper_refs:void 0).map(_c).filter(n=>n!==null)}:null}function d_(t){if(!O(t))return null;const e=y(t.agent_name);return e?{agent_name:e,display_name:y(t.display_name)??null,is_live:typeof t.is_live=="boolean"?t.is_live:void 0,archived_reason:y(t.archived_reason)??null,status:y(t.status),where:y(t.where)??null,with_whom:H(t.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:y(t.current_work)??null,related_session_id:y(t.related_session_id)??null,related_attention_count:q(t.related_attention_count)??0,last_activity_at:y(t.last_activity_at)??null,recent_output_preview:y(t.recent_output_preview)??null,recent_input_preview:y(t.recent_input_preview)??null,recent_tool_names:H(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean)}:null}function u_(t){if(!O(t))return null;const e=y(t.name);return e?{name:e,agent_name:y(t.agent_name)??null,status:y(t.status),generation:q(t.generation),context_ratio:q(t.context_ratio)??null,last_turn_ago_s:q(t.last_turn_ago_s)??null,current_work:y(t.current_work)??null,last_autonomous_action_at:y(t.last_autonomous_action_at)??null,allowed_tool_names:H(t.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:H(t.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:q(t.latest_tool_call_count)??null,tool_audit_source:y(t.tool_audit_source)??null,tool_audit_at:y(t.tool_audit_at)??null}:null}function p_(t){if(!O(t))return null;const e=y(t.id),n=y(t.signal_type),s=y(t.summary),a=y(t.target_type);return!e||!n||!s||!a?null:{id:e,signal_type:n==="action"?"action":"attention",severity:y(t.severity)??"warn",summary:s,target_type:a,target_id:y(t.target_id)??null,attention:mn(t.attention),action:je(t.action)}}function m_(t){const e=O(t)?t:{},n=H(e.session_briefs).map(uc).filter(a=>a!==null),s=H(e.sessions).map(vc).filter(a=>a!==null);return{generated_at:y(e.generated_at),summary:o_(e.summary),incidents:H(e.incidents).map(mn).filter(a=>a!==null),recommended_actions:H(e.recommended_actions).map(je).filter(a=>a!==null),command_focus:r_(e.command_focus),operator_targets:l_(e.operator_targets),attention_queue:H(e.attention_queue).map(c_).filter(a=>a!==null),sessions:s.length>0?s:n.map(a=>({...a,member_previews:[],operation_badges:[],keeper_refs:[]})),session_briefs:n,agent_briefs:H(e.agent_briefs).map(d_).filter(a=>a!==null),keeper_briefs:H(e.keeper_briefs).map(u_).filter(a=>a!==null),internal_signals:H(e.internal_signals).map(p_).filter(a=>a!==null)}}function __(t){if(!O(t))return null;const e=y(t.id),n=y(t.summary);return!e||!n?null:{id:e,timestamp:y(t.timestamp)??null,event_type:y(t.event_type),actor:y(t.actor)??null,summary:n}}function v_(t){const e=O(t)?t:{};return{generated_at:y(e.generated_at),session_id:y(e.session_id)??"",session:vc(e.session),timeline:H(e.timeline).map(__).filter(n=>n!==null),participants:H(e.participants).map(pc).filter(n=>n!==null),operations:H(e.operations).map(mc).filter(n=>n!==null),keepers:H(e.keepers).map(_c).filter(n=>n!==null),error:y(e.error)??null}}function f_(t){if(!O(t))return null;const e=y(t.id),n=y(t.label),s=y(t.summary);if(!e||!n||!s)return null;const a=y(t.status)??"unclear";return{id:e,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:y(t.signal_class)==="metadata_gap"||y(t.signal_class)==="mixed"||y(t.signal_class)==="operational_risk"?y(t.signal_class):void 0,evidence_quality:y(t.evidence_quality)==="strong"||y(t.evidence_quality)==="partial"||y(t.evidence_quality)==="missing"?y(t.evidence_quality):void 0,evidence:H(t.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function g_(t){if(!O(t))return null;const e=y(t.kind),n=y(t.summary),s=y(t.scope_type),a=y(t.severity);return!e||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:e,summary:n,scope_type:s,scope_id:y(t.scope_id)??null,severity:a}}function $_(t){const e=O(t)?t:{},n=O(e.basis)?e.basis:{},s=y(e.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:y(e.generated_at),cached:Ze(e.cached),stale:Ze(e.stale),refreshing:Ze(e.refreshing),status:a,summary:y(e.summary)??null,model:y(e.model)??null,ttl_sec:q(e.ttl_sec),criteria:H(e.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:y(n.current_room)??null,crew_count:q(n.crew_count),agent_count:q(n.agent_count),keeper_count:q(n.keeper_count)},metadata_gap_count:q(e.metadata_gap_count),metadata_gaps:H(e.metadata_gaps).map(g_).filter(o=>o!==null),sections:H(e.sections).map(f_).filter(o=>o!==null),error:y(e.error)??null,last_error:y(e.last_error)??null}}async function fc(){to.value=!0,va.value=null;try{const t=await Au();Xa.value=m_(t)}catch(t){va.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{to.value=!1}}async function h_(t){if(!t){eo.value=null,Vs.value=null,Xs.value=!1;return}Xs.value=!0,Vs.value=null;try{const e=await Tu(t);eo.value=v_(e)}catch(e){Vs.value=e instanceof Error?e.message:"Failed to load session detail"}finally{Xs.value=!1}}async function fa(t=!1){Fe.value=!0,Ce.value=null;try{const e=await Iu(t),n=$_(e);dc.value=n,n.refreshing||n.status==="pending"?t_():Tr()}catch(e){Ce.value=e instanceof Error?e.message:"Failed to load mission briefing",Tr()}finally{Fe.value=!1}}const gc=g(null),no=g(!1),Ke=g(null);async function $c(t,e){no.value=!0,Ke.value=null;try{gc.value=await Ru(t,e)}catch(n){Ke.value=n instanceof Error?n.message:String(n)}finally{no.value=!1}}const Do=g(null),Kt=g(null),ga=g(!1),$a=g(!1),ha=g(null),ya=g(null),so=g(null),ba=g(null),Y=g("warroom"),cs=g(null),ao=g(!1),ka=g(null),Oe=g(null),xa=g(!1),Sa=g(null),qo=g(null),io=g(!1),Ca=g(null),ds=g(null),oo=g(!1),Aa=g(null),Un=g(null),Ta=g(!1),Hn=g(null),tn=g(null);let xn=null;function wo(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"&&t!=="orchestra"}function hc(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function yc(){const e=hc().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function bc(){const e=hc().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function y_(t){if(_(t))return{policy_class:r(t.policy_class),approval_class:r(t.approval_class),tool_allowlist:F(t.tool_allowlist),model_allowlist:F(t.model_allowlist),requires_human_for:F(t.requires_human_for),autonomy_level:r(t.autonomy_level),escalation_timeout_sec:d(t.escalation_timeout_sec),kill_switch:N(t.kill_switch),frozen:N(t.frozen)}}function b_(t){if(_(t))return{headcount_cap:d(t.headcount_cap),active_operation_cap:d(t.active_operation_cap),max_cost_usd:d(t.max_cost_usd),max_tokens:d(t.max_tokens)}}function Fo(t){if(!_(t))return null;const e=r(t.unit_id),n=r(t.label),s=r(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:r(t.parent_unit_id)??null,leader_id:r(t.leader_id)??null,roster:F(t.roster),capability_profile:F(t.capability_profile),source:r(t.source),created_at:r(t.created_at),updated_at:r(t.updated_at),policy:y_(t.policy),budget:b_(t.budget)}}function kc(t){if(!_(t))return null;const e=Fo(t.unit);return e?{unit:e,leader_status:r(t.leader_status),roster_total:d(t.roster_total),roster_live:d(t.roster_live),active_operation_count:d(t.active_operation_count),health:r(t.health),reasons:F(t.reasons),children:Array.isArray(t.children)?t.children.map(kc).filter(n=>n!==null):[]}:null}function k_(t){if(_(t))return{total_units:d(t.total_units),company_count:d(t.company_count),platoon_count:d(t.platoon_count),squad_count:d(t.squad_count),leaf_agent_unit_count:d(t.leaf_agent_unit_count),live_agent_count:d(t.live_agent_count),managed_unit_count:d(t.managed_unit_count),active_operation_count:d(t.active_operation_count)}}function xc(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),source:r(e.source),summary:k_(e.summary),units:Array.isArray(e.units)?e.units.map(kc).filter(n=>n!==null):[]}}function x_(t){if(!_(t))return null;const e=r(t.kind),n=r(t.status);return!e||!n?null:{kind:e,chain_id:r(t.chain_id)??null,goal:r(t.goal)??null,run_id:r(t.run_id)??null,status:n,viewer_path:r(t.viewer_path)??null,last_sync_at:r(t.last_sync_at)??null}}function Va(t){if(!_(t))return null;const e=r(t.operation_id),n=r(t.objective),s=r(t.assigned_unit_id),a=r(t.trace_id),o=r(t.status);return!e||!n||!s||!a||!o?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:r(t.autonomy_level),policy_class:r(t.policy_class),budget_class:r(t.budget_class),detachment_session_id:r(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(t.checkpoint_ref)??null,active_goal_ids:F(t.active_goal_ids),note:r(t.note)??null,created_by:r(t.created_by),source:r(t.source),status:o,chain:x_(t.chain),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function S_(t){if(!_(t))return null;const e=Va(t.operation);return e?{operation:e,assigned_unit_label:r(t.assigned_unit_label)}:null}function hn(t){if(_(t))return{tone:r(t.tone),pending_ops:d(t.pending_ops),blocked_ops:d(t.blocked_ops),in_flight_ops:d(t.in_flight_ops),pipeline_stalls:d(t.pipeline_stalls),bus_traffic:d(t.bus_traffic),l1_hit_rate:d(t.l1_hit_rate),invalidation_count:d(t.invalidation_count),current_pending:d(t.current_pending),current_in_flight:d(t.current_in_flight),cdb_wakeups:d(t.cdb_wakeups),total_stolen:d(t.total_stolen),avg_best_score:d(t.avg_best_score),avg_candidate_count:d(t.avg_candidate_count),best_first_operations:d(t.best_first_operations),active_sessions:d(t.active_sessions),commit_rate:d(t.commit_rate),total_speculations:d(t.total_speculations)}}function C_(t){if(!_(t))return;const e=_(t.pipeline)?t.pipeline:void 0,n=_(t.cache)?t.cache:void 0,s=_(t.ooo)?t.ooo:void 0,a=_(t.speculative)?t.speculative:void 0,o=_(t.search_fabric)?t.search_fabric:void 0,l=_(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:d(e.total_ops),completed_ops:d(e.completed_ops),stalled_cycles:d(e.stalled_cycles),hazards_detected:d(e.hazards_detected),forwarding_used:d(e.forwarding_used),pipeline_flushes:d(e.pipeline_flushes),ipc:d(e.ipc)}:void 0,cache:n?{total_reads:d(n.total_reads),total_writes:d(n.total_writes),l1_hit_rate:d(n.l1_hit_rate),invalidation_count:d(n.invalidation_count),writeback_count:d(n.writeback_count),bus_traffic:d(n.bus_traffic)}:void 0,ooo:s?{agent_count:d(s.agent_count),total_added:d(s.total_added),total_issued:d(s.total_issued),total_completed:d(s.total_completed),total_stolen:d(s.total_stolen),cdb_wakeups:d(s.cdb_wakeups),stall_cycles:d(s.stall_cycles),global_cdb_events:d(s.global_cdb_events),current_pending:d(s.current_pending),current_in_flight:d(s.current_in_flight)}:void 0,speculative:a?{total_speculations:d(a.total_speculations),total_commits:d(a.total_commits),total_aborts:d(a.total_aborts),commit_rate:d(a.commit_rate),total_fast_calls:d(a.total_fast_calls),total_cost_usd:d(a.total_cost_usd),active_sessions:d(a.active_sessions)}:void 0,search_fabric:o?{total_operations:d(o.total_operations),best_first_operations:d(o.best_first_operations),legacy_operations:d(o.legacy_operations),blocked_operations:d(o.blocked_operations),ready_operations:d(o.ready_operations),research_pipeline_operations:d(o.research_pipeline_operations),avg_candidate_count:d(o.avg_candidate_count),avg_best_score:d(o.avg_best_score),top_stage:r(o.top_stage)??null}:void 0,signals:l?{issue_pressure:hn(l.issue_pressure),cache_contention:hn(l.cache_contention),scheduler_efficiency:hn(l.scheduler_efficiency),routing_confidence:hn(l.routing_confidence),speculative_posture:hn(l.speculative_posture)}:void 0}}function Sc(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),active:d(n.active),paused:d(n.paused),managed:d(n.managed),projected:d(n.projected)}:void 0,microarch:C_(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(S_).filter(s=>s!==null):[]}}function Cc(t){if(!_(t))return null;const e=r(t.detachment_id),n=r(t.operation_id),s=r(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:r(t.leader_id)??null,roster:F(t.roster),session_id:r(t.session_id)??null,checkpoint_ref:r(t.checkpoint_ref)??null,runtime_kind:r(t.runtime_kind)??null,runtime_ref:r(t.runtime_ref)??null,source:r(t.source),status:r(t.status),last_event_at:r(t.last_event_at)??null,last_progress_at:r(t.last_progress_at)??null,heartbeat_deadline:r(t.heartbeat_deadline)??null,created_at:r(t.created_at),updated_at:r(t.updated_at)}}function A_(t){if(!_(t))return null;const e=Cc(t.detachment);return e?{detachment:e,assigned_unit_label:r(t.assigned_unit_label),operation:Va(t.operation)}:null}function Ac(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),active:d(n.active),projected:d(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(A_).filter(s=>s!==null):[]}}function T_(t){if(!_(t))return null;const e=r(t.decision_id),n=r(t.trace_id),s=r(t.requested_action),a=r(t.scope_type),o=r(t.scope_id);return!e||!n||!s||!a||!o?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:r(t.operation_id)??null,target_unit_id:r(t.target_unit_id)??null,requested_by:r(t.requested_by),status:r(t.status),reason:r(t.reason)??null,source:r(t.source),detail:t.detail,created_at:r(t.created_at),decided_at:r(t.decided_at)??null,expires_at:r(t.expires_at)??null}}function Tc(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),pending:d(n.pending),approved:d(n.approved),denied:d(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(T_).filter(s=>s!==null):[]}}function I_(t){if(!_(t))return null;const e=Fo(t.unit);return e?{unit:e,roster_total:d(t.roster_total),roster_live:d(t.roster_live),headcount_cap:d(t.headcount_cap),active_operations:d(t.active_operations),active_operation_cap:d(t.active_operation_cap),utilization:d(t.utilization)}:null}function R_(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(I_).filter(n=>n!==null):[]}}function M_(t){if(!_(t))return null;const e=r(t.alert_id);return e?{alert_id:e,severity:r(t.severity),kind:r(t.kind),scope_type:r(t.scope_type),scope_id:r(t.scope_id),title:r(t.title),detail:r(t.detail),timestamp:r(t.timestamp)}:null}function Ic(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),bad:d(n.bad),warn:d(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(M_).filter(s=>s!==null):[]}}function Rc(t){if(!_(t))return null;const e=r(t.event_id),n=r(t.trace_id),s=r(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:r(t.operation_id)??null,unit_id:r(t.unit_id)??null,actor:r(t.actor)??null,source:r(t.source),timestamp:r(t.timestamp),detail:t.detail}}function E_(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),events:Array.isArray(e.events)?e.events.map(Rc).filter(n=>n!==null):[]}}function L_(t){if(!_(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function P_(t){if(!_(t))return null;const e=r(t.lane_id),n=r(t.label),s=r(t.kind),a=r(t.phase),o=r(t.motion_state),l=r(t.source_of_truth),c=r(t.movement_reason),p=r(t.current_step);if(!e||!n||!s||!a||!o||!l||!c||!p)return null;const m=_(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:N(t.present)??!1,phase:a,motion_state:o,source_of_truth:l,last_movement_at:r(t.last_movement_at)??null,movement_reason:c,current_step:p,blockers:F(t.blockers),counts:{operations:d(m.operations),detachments:d(m.detachments),workers:d(m.workers),approvals:d(m.approvals),alerts:d(m.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(L_).filter(u=>u!==null):[]}}function z_(t){if(!_(t))return null;const e=r(t.event_id),n=r(t.lane_id),s=r(t.kind),a=r(t.timestamp),o=r(t.title),l=r(t.detail),c=r(t.tone),p=r(t.source);return!e||!n||!s||!a||!o||!l||!c||!p?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:o,detail:l,tone:c,source:p}}function N_(t){if(!_(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,why_it_matters:r(t.why_it_matters)??void 0,next_tool:r(t.next_tool)??void 0,next_step:r(t.next_step)??void 0,lane_ids:F(t.lane_ids),count:d(t.count)??0}}function Ko(t){if(!_(t))return;const e=_(t.overview)?t.overview:{},n=_(t.gaps)?t.gaps:{},s=_(t.narrative)?t.narrative:{},a=_(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:r(t.generated_at),narrative:{state:r(s.state)??void 0,started:r(s.started)??void 0,active_work:r(s.active_work)??void 0,completion:r(s.completion)??void 0,lane_id:r(s.lane_id)??null},overview:{active_lanes:d(e.active_lanes),moving_lanes:d(e.moving_lanes),stalled_lanes:d(e.stalled_lanes),projected_lanes:d(e.projected_lanes),last_movement_at:r(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(P_).filter(o=>o!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(z_).filter(o=>o!==null):[],gaps:{count:d(n.count),items:Array.isArray(n.items)?n.items.map(N_).filter(o=>o!==null):[]},recommended_next_action:a?{tool:r(a.tool)??"masc_operator_snapshot",label:r(a.label)??"Observe operator state",reason:r(a.reason)??"",lane_id:r(a.lane_id)??null}:void 0}}function Mc(t){if(!_(t))return;const e=_(t.workers)?t.workers:{},n=N(t.pass);return{status:r(t.status)??"missing",source:r(t.source)??"none",reason_code:r(t.reason_code)??null,status_summary:r(t.status_summary)??null,run_id:r(t.run_id)??null,captured_at:r(t.captured_at)??null,...n!==void 0?{pass:n}:{},...d(t.peak_hot_slots)!=null?{peak_hot_slots:d(t.peak_hot_slots)}:{},...d(t.ctx_per_slot)!=null?{ctx_per_slot:d(t.ctx_per_slot)}:{},workers:{expected:d(e.expected),joined:d(e.joined),current_task_bound:d(e.current_task_bound),fresh_heartbeats:d(e.fresh_heartbeats),done:d(e.done),final:d(e.final)},expected_artifact_dir:r(t.expected_artifact_dir)??null,artifact_ref:r(t.artifact_ref)??null,missing_reason:r(t.missing_reason)??null}}function j_(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),topology:xc(e.topology),operations:Sc(e.operations),detachments:Ac(e.detachments),alerts:Ic(e.alerts),decisions:Tc(e.decisions),capacity:R_(e.capacity),traces:E_(e.traces),swarm_status:Ko(e.swarm_status)}}function O_(t){const e=_(t)?t:{},n=xc(e.topology),s=Sc(e.operations),a=Ac(e.detachments),o=Ic(e.alerts),l=Tc(e.decisions);return{version:r(e.version),generated_at:r(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:Ko(e.swarm_status),swarm_proof:Mc(e.swarm_proof)}}function D_(t){return _(t)?{chain_id:r(t.chain_id)??null,started_at:d(t.started_at)??null,progress:d(t.progress)??null,elapsed_sec:d(t.elapsed_sec)??null}:null}function Ec(t){if(!_(t))return null;const e=r(t.event);return e?{event:e,chain_id:r(t.chain_id)??null,timestamp:r(t.timestamp)??null,duration_ms:d(t.duration_ms)??null,message:r(t.message)??null,tokens:d(t.tokens)??null}:null}function q_(t){if(!_(t))return null;const e=Va(t.operation);return e?{operation:e,runtime:D_(t.runtime),history:Ec(t.history),mermaid:r(t.mermaid)??null,preview_run:Lc(t.preview_run)}:null}function w_(t){const e=_(t)?t:{};return{status:r(e.status)??"disconnected",base_url:r(e.base_url)??null,message:r(e.message)??null}}function F_(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),connection:w_(e.connection),summary:n?{linked_operations:d(n.linked_operations),active_chains:d(n.active_chains),running_operations:d(n.running_operations),recent_failures:d(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(q_).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(Ec).filter(s=>s!==null):[]}}function K_(t){if(!_(t))return null;const e=r(t.id);return e?{id:e,type:r(t.type),status:r(t.status),duration_ms:d(t.duration_ms)??null,error:r(t.error)??null}:null}function Lc(t){if(!_(t))return null;const e=r(t.run_id),n=r(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:d(t.duration_ms),success:N(t.success),mermaid:r(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(K_).filter(s=>s!==null):[]}:null}function B_(t){const e=_(t)?t:{};return{run:Lc(e.run)}}function U_(t){if(!_(t))return null;const e=r(t.title),n=r(t.path);return!e||!n?null:{title:e,path:n}}function H_(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function W_(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.tool),a=r(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:F(t.success_signals),pitfalls:F(t.pitfalls)}}function G_(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary),a=r(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(W_).filter(o=>o!==null):[]}}function J_(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:F(t.tools)}}function Y_(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.symptom),a=r(t.why),o=r(t.fix_tool),l=r(t.fix_summary);return!e||!n||!s||!a||!o||!l?null:{id:e,title:n,symptom:s,why:a,fix_tool:o,fix_summary:l}}function X_(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.path_id),a=r(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:F(t.notes)}}function V_(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(U_).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(H_).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(G_).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(J_).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Y_).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(X_).filter(n=>n!==null):[]}}function Q_(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.status),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{id:e,title:n,status:s,detail:a,next_tool:o}}function Z_(t){if(!_(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.title),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{code:e,severity:n,title:s,detail:a,next_tool:o}}function tv(t){if(!_(t))return null;const e=r(t.from),n=r(t.content),s=r(t.timestamp),a=d(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function ev(t){if(!_(t))return null;const e=r(t.name),n=r(t.role),s=r(t.lane),a=r(t.status),o=r(t.claim_marker),l=r(t.done_marker),c=r(t.final_marker);if(!e||!n||!s||!a||!o||!l||!c)return null;const p=(()=>{if(!_(t.last_message))return null;const m=d(t.last_message.seq),u=r(t.last_message.content),v=r(t.last_message.timestamp);return m==null||!u||!v?null:{seq:m,content:u,timestamp:v}})();return{name:e,role:n,lane:s,joined:N(t.joined)??!1,live_presence:N(t.live_presence)??!1,completed:N(t.completed)??!1,status:a,current_task:r(t.current_task)??null,bound_task_id:r(t.bound_task_id)??null,bound_task_title:r(t.bound_task_title)??null,bound_task_status:r(t.bound_task_status)??null,current_task_matches_run:N(t.current_task_matches_run)??!1,squad_member:N(t.squad_member)??!1,detachment_member:N(t.detachment_member)??!1,last_seen:r(t.last_seen)??null,heartbeat_age_sec:d(t.heartbeat_age_sec)??null,heartbeat_fresh:N(t.heartbeat_fresh)??!1,claim_marker_seen:N(t.claim_marker_seen)??!1,done_marker_seen:N(t.done_marker_seen)??!1,final_marker_seen:N(t.final_marker_seen)??!1,claim_marker:o,done_marker:l,final_marker:c,last_message:p}}function nv(t){if(!_(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!_(n))return null;const s=r(n.timestamp),a=d(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:r(t.slot_url)??null,provider_base_url:r(t.provider_base_url)??null,provider_reachable:N(t.provider_reachable)??null,provider_status_code:d(t.provider_status_code)??null,provider_model_id:r(t.provider_model_id)??null,actual_model_id:r(t.actual_model_id)??null,expected_slots:d(t.expected_slots),actual_slots:d(t.actual_slots),expected_ctx:d(t.expected_ctx),actual_ctx:d(t.actual_ctx),configured_capacity:d(t.configured_capacity),slot_reachable:N(t.slot_reachable)??null,slot_status_code:d(t.slot_status_code)??null,runtime_blocker:r(t.runtime_blocker)??null,detail:r(t.detail)??null,checked_at:r(t.checked_at)??null,total_slots:d(t.total_slots),ctx_per_slot:d(t.ctx_per_slot),active_slots_now:d(t.active_slots_now),peak_active_slots:d(t.peak_active_slots),sample_count:d(t.sample_count),last_sample_at:r(t.last_sample_at)??null,timeline:e}}function sv(t){if(!_(t))return null;const e=r(t.run_id),n=r(t.status),s=r(t.decided_by),a=r(t.decided_at),o=r(t.reason);if(!e||!n||!s||!a||!o)return null;const l=[];return Array.isArray(t.history)&&t.history.forEach(c=>{if(!_(c))return;const p=r(c.status),m=r(c.decided_by),u=r(c.decided_at),v=r(c.reason);!p||!m||!u||!v||l.push({status:p,decided_by:m,decided_at:u,reason:v,operation_id:r(c.operation_id)??null,detachment_id:r(c.detachment_id)??null,note:r(c.note)??null})}),{run_id:e,status:n,decided_by:s,decided_at:a,reason:o,operation_id:r(t.operation_id)??null,detachment_id:r(t.detachment_id)??null,note:r(t.note)??null,history:l}}function av(t){if(!_(t))return null;const e=r(t.run_id),n=r(t.recommended_kind),s=r(t.reason);return!e||!n||!s?null:{run_id:e,recommended_kind:n,continue_available:N(t.continue_available)??!1,rerun_available:N(t.rerun_available)??!1,abandon_available:N(t.abandon_available)??!1,reason:s,evidence:_(t.evidence)?{operation_id:r(t.evidence.operation_id)??null,detachment_id:r(t.evidence.detachment_id)??null,joined_workers:d(t.evidence.joined_workers),current_task_bound:d(t.evidence.current_task_bound),fresh_heartbeats:d(t.evidence.fresh_heartbeats),trace_events:d(t.evidence.trace_events),message_events:d(t.evidence.message_events),runtime_blocker:r(t.evidence.runtime_blocker)??null}:void 0,provenance:r(t.provenance),decision_engine:r(t.decision_engine),authoritative:N(t.authoritative)}}function iv(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),run_id:r(e.run_id),room_id:r(e.room_id),operation_id:r(e.operation_id)??null,run_resolution:sv(e.run_resolution),resolution_recommendation:av(e.resolution_recommendation),recommended_next_tool:r(e.recommended_next_tool),summary:n?{expected_workers:d(n.expected_workers),joined_workers:d(n.joined_workers),live_workers:d(n.live_workers),squad_roster_size:d(n.squad_roster_size),detachment_roster_size:d(n.detachment_roster_size),current_task_bound:d(n.current_task_bound),fresh_heartbeats:d(n.fresh_heartbeats),claim_markers_seen:d(n.claim_markers_seen),done_markers_seen:d(n.done_markers_seen),final_markers_seen:d(n.final_markers_seen),completed_workers:d(n.completed_workers),peak_hot_slots:d(n.peak_hot_slots),hot_window_ok:N(n.hot_window_ok),pass_hot_concurrency:N(n.pass_hot_concurrency),pass_end_to_end:N(n.pass_end_to_end),pending_decisions:d(n.pending_decisions),pass:N(n.pass)}:void 0,provider:nv(e.provider),operation:Va(e.operation),squad:Fo(e.squad),detachment:Cc(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(ev).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Q_).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Z_).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(tv).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(Rc).filter(s=>s!==null):[],truth_notes:F(e.truth_notes)}}function ov(t){if(!_(t))return null;const e=r(t.label),n=r(t.value);return!e||!n?null:{label:e,value:n}}function rv(t){if(!_(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.label),a=r(t.tone),o=r(t.provenance);return!e||!n||!s||!a||!o?null:{id:e,kind:n,label:s,subtitle:r(t.subtitle)??null,status:r(t.status)??null,tone:a,pulse:r(t.pulse)??null,provenance:o,visual_class:r(t.visual_class)??void 0,glyph:r(t.glyph)??void 0,parent_id:r(t.parent_id)??null,lane_id:r(t.lane_id)??null,link_tab:r(t.link_tab)??null,link_surface:r(t.link_surface)??null,link_params:_(t.link_params)?Object.fromEntries(Object.entries(t.link_params).map(([l,c])=>{const p=r(c);return p?[l,p]:null}).filter(l=>l!==null)):{},facts:Array.isArray(t.facts)?t.facts.map(ov).filter(l=>l!==null):[]}}function lv(t){if(!_(t))return null;const e=r(t.id),n=r(t.source),s=r(t.target),a=r(t.kind),o=r(t.tone),l=r(t.provenance);return!e||!n||!s||!a||!o||!l?null:{id:e,source:n,target:s,kind:a,label:r(t.label)??null,tone:o,provenance:l,animated:N(t.animated)}}function cv(t){if(!_(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.label),a=r(t.tone),o=r(t.provenance);return!e||!n||!s||!a||!o?null:{id:e,kind:n,label:s,detail:r(t.detail)??null,tone:a,provenance:o,source_id:r(t.source_id)??null,target_id:r(t.target_id)??null,suggested_surface:r(t.suggested_surface)??null,suggested_params:_(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([l,c])=>{const p=r(c);return p?[l,p]:null}).filter(l=>l!==null)):{}}}function dv(t){if(!_(t))return null;const e=r(t.target_kind),n=r(t.target_id),s=r(t.label),a=r(t.reason);return!e||!n||!s||!a?null:{target_kind:e,target_id:n,label:s,reason:a,suggested_surface:r(t.suggested_surface)??null,suggested_params:_(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([o,l])=>{const c=r(l);return c?[o,c]:null}).filter(o=>o!==null)):{}}}function uv(t){const e=_(t)?t:{},n=_(e.room)?e.room:{},s=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),room:{room_id:r(n.room_id),project:r(n.project),cluster:r(n.cluster),paused:N(n.paused),pause_reason:r(n.pause_reason)??null,agent_count:d(n.agent_count),task_count:d(n.task_count),message_count:d(n.message_count)},summary:s?{session_count:d(s.session_count),operation_count:d(s.operation_count),detachment_count:d(s.detachment_count),lane_count:d(s.lane_count),worker_count:d(s.worker_count),keeper_count:d(s.keeper_count),signal_count:d(s.signal_count),alert_count:d(s.alert_count)}:void 0,nodes:Array.isArray(e.nodes)?e.nodes.map(rv).filter(a=>a!==null):[],edges:Array.isArray(e.edges)?e.edges.map(lv).filter(a=>a!==null):[],signals:Array.isArray(e.signals)?e.signals.map(cv).filter(a=>a!==null):[],focus:dv(e.focus),swarm_status:Ko(e.swarm_status),swarm_proof:Mc(e.swarm_proof),truth_notes:F(e.truth_notes)}}function le(t){Y.value=t,wo(t)&&pv()}async function Pc(){ga.value=!0,ha.value=null;try{const t=await Nu();Do.value=O_(t)}catch(t){ha.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{ga.value=!1}}function Bo(t){tn.value=t}async function Uo(){$a.value=!0,ya.value=null;try{const t=await zu();Kt.value=j_(t)}catch(t){ya.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{$a.value=!1}}async function pv(){Kt.value||$a.value||await Uo()}async function Be(){await Pc(),wo(Y.value)&&await Uo()}async function en(){var t;oo.value=!0,Aa.value=null;try{const e=await ju(),n=F_(e);ds.value=n;const s=tn.value;n.operations.length===0?tn.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(tn.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Aa.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{oo.value=!1}}function mv(){xn=null,Un.value=null,Ta.value=!1,Hn.value=null}async function _v(t){xn=t,Ta.value=!0,Hn.value=null;try{const e=await Ou(t);if(xn!==t)return;Un.value=B_(e)}catch(e){if(xn!==t)return;Un.value=null,Hn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{xn===t&&(Ta.value=!1)}}async function vv(){ao.value=!0,ka.value=null;try{const t=await Du();cs.value=V_(t)}catch(t){ka.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{ao.value=!1}}async function ne(t=yc(),e=bc()){xa.value=!0,Sa.value=null;try{const n=await qu(t,e);Oe.value=iv(n)}catch(n){Sa.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{xa.value=!1}}async function Me(t=yc(),e=bc()){io.value=!0,Ca.value=null;try{const n=await wu(t,e);qo.value=uv(n)}catch(n){Ca.value=n instanceof Error?n.message:"Failed to load orchestra map"}finally{io.value=!1}}async function fe(t,e,n){so.value=t,ba.value=null;try{await Fu(e,n),await Pc(),(Kt.value||wo(Y.value))&&await Uo(),await ne(),await Me(),await en()}catch(s){throw ba.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{so.value=null}}function fv(t){return fe(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function gv(t){return fe(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function $v(t){return fe(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function hv(t={}){return fe("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function yv(t){return fe(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function bv(t){return fe(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function kv(t,e){return fe(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function xv(t,e){return fe(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}qm(()=>{Be(),en(),(Y.value==="swarm"||Y.value==="warroom"||Y.value==="orchestra"||Oe.value!==null)&&ne(),(Y.value==="orchestra"||qo.value!==null)&&Me(),Y.value==="warroom"&&bt()});function ro(t){t==="command"&&(Ie(),Be(),en(),(Y.value==="swarm"||Y.value==="warroom"||Y.value==="orchestra")&&ne(),Y.value==="orchestra"&&Me(),Y.value==="warroom"&&bt()),t==="mission"&&(Ie(),fc(),fa()),t==="proof"&&$c(D.value.params.session_id,D.value.params.operation_id),t==="execution"&&(Ie(),Te()),t==="intervene"&&(Ie(),bt(),ze()),t==="memory"&&oe(),t==="planning"&&No(),t==="lab"&&re()}function Sv({metric:t}){return i`
    <article class="semantic-metric-row">
      <div class="semantic-metric-head">
        <strong>${t.label}</strong>
        <span class="semantic-code">${t.id}</span>
      </div>
      <p>${t.what_it_measures}</p>
      <div class="semantic-grid compact">
        <span>이유</span><span>${t.why_it_exists}</span>
        <span>근거 경로</span><span>${t.source_path}</span>
        <span>갱신 조건</span><span>${t.update_trigger}</span>
        <span>에이전트 영향</span><span>${t.agent_behavior_effect}</span>
        <span>생태계 영향</span><span>${t.ecosystem_effect}</span>
        <span>해석</span><span>${t.interpretation}</span>
        <span>나쁜 냄새</span><span>${t.bad_smell}</span>
        <span>다음 액션</span><span>${t.next_action}</span>
      </div>
    </article>
  `}function Cv({panel:t}){return i`
    <div class="semantic-body">
      <div class="semantic-grid">
        <span>목적</span><span>${t.purpose}</span>
        <span>무엇을 푸나</span><span>${t.problem_solved}</span>
        <span>언제 보나</span><span>${t.when_active}</span>
        <span>에이전트 역할</span><span>${t.agent_role}</span>
        <span>생태계 기능</span><span>${t.ecosystem_function}</span>
      </div>
      ${t.related_tools.length>0?i`<div class="semantic-tag-row">
            ${t.related_tools.map(e=>i`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
      ${t.metrics.length>0?i`<div class="semantic-metric-list">
            ${t.metrics.map(e=>i`<${Sv} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function w({panelId:t,compact:e=!1,label:n="왜 필요한가"}){const s=Am(t);return s?i`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${Cv} panel=${s} />
    </details>
  `:da.value?i`<span class="semantic-inline-state">의미 계층 불러오는 중…</span>`:null}function kt({surfaceId:t,compact:e=!1}){const n=Cm(t);return n?i`
    <section class="semantic-surface-card ${e?"compact":""}">
      <div class="semantic-surface-head">
        <strong>${n.label}</strong>
        <span class="semantic-code">${n.id}</span>
      </div>
      <p class="semantic-lead">${n.purpose}</p>
      <div class="semantic-grid">
        <span>무엇을 푸나</span><span>${n.problem_solved}</span>
        <span>언제 보나</span><span>${n.when_active}</span>
        <span>에이전트 역할</span><span>${n.agent_role}</span>
        <span>생태계 기능</span><span>${n.ecosystem_function}</span>
      </div>
      ${n.panels.length>0?i`<div class="semantic-tag-row">
            ${n.panels.map(s=>i`<span class="semantic-tag">${s.title}</span>`)}
          </div>`:null}
    </section>
  `:da.value?i`<div class="semantic-surface-card ${e?"compact":""}">의미 계층 불러오는 중…</div>`:ua.value?i`<div class="semantic-surface-card ${e?"compact":""}">${ua.value}</div>`:null}function R({title:t,class:e,semanticId:n,testId:s,children:a}){return i`
    <div class="card ${e??""}" data-testid=${s}>
      ${t?i`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?i`<${w} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}function li(t){const e=(t??"").trim().toLowerCase();return e==="bad"||e==="critical"||e==="offline"?"bad":e==="warn"||e==="paused"||e==="blocked"?"warn":"ok"}function Av(){var n;const t=(n=jo.value)==null?void 0:n.focus;if(!(t!=null&&t.suggested_tab))return;const e=t.suggested_params??{};if(t.suggested_tab==="intervene"){ot("intervene",e);return}ot("command",{...t.suggested_surface?{surface:t.suggested_surface}:{},...e})}function Qa(){var p,m,u,v,f,$;const t=jo.value;if(!t)return Zi.value?i`<section class="room-truth-strip room-truth-strip-loading">room truth 불러오는 중...</section>`:pa.value?i`<section class="room-truth-strip room-truth-strip-error">${pa.value}</section>`:null;const e=t.room.status,n=t.room.counts,s=(p=t.execution)==null?void 0:p.summary,a=(m=t.execution)==null?void 0:m.top_queue,o=t.command,l=t.operator,c=t.focus;return i`
    <section class="room-truth-strip">
      <article class="room-truth-card">
        <span class="room-truth-label">room truth</span>
        <strong>${(e==null?void 0:e.project)??"project"} · ${(e==null?void 0:e.room)??"default"}</strong>
        <p>${(n==null?void 0:n.agents)??0} agents · ${(n==null?void 0:n.tasks)??0} tasks · ${(n==null?void 0:n.keepers)??0} keepers</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${e!=null&&e.paused?"warn":"ok"}">${e!=null&&e.paused?"일시정지":"열림"}</span>
          <span class="command-chip">${(e==null?void 0:e.cluster)??"cluster:unknown"}</span>
          <span class="command-chip">${t.room.provenance??"truth"}</span>
        </div>
      </article>

      <article class="room-truth-card">
        <span class="room-truth-label">execution</span>
        <strong>세션 ${(s==null?void 0:s.active_sessions)??0} · 막힘 ${(s==null?void 0:s.blocked_sessions)??0}</strong>
        <p>${(a==null?void 0:a.summary)??"지금은 실행 대기열 최상단 항목이 없습니다."}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${li(((s==null?void 0:s.blocked_sessions)??0)>0?"warn":"ok")}">priority ${(s==null?void 0:s.priority_items)??0}</span>
          <span class="command-chip">${((u=t.execution)==null?void 0:u.provenance)??"derived"}</span>
        </div>
      </article>

      <article class="room-truth-card">
        <span class="room-truth-label">control</span>
        <strong>작전 ${(o==null?void 0:o.active_operations)??0} · 승인 ${(o==null?void 0:o.pending_approvals)??0}</strong>
        <p>alerts bad ${(o==null?void 0:o.bad_alerts)??0} / warn ${(o==null?void 0:o.warn_alerts)??0} · lanes ${(o==null?void 0:o.moving_lanes)??0}/${(o==null?void 0:o.active_lanes)??0}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${li(((o==null?void 0:o.bad_alerts)??0)>0?"bad":((o==null?void 0:o.warn_alerts)??0)>0||((o==null?void 0:o.pending_approvals)??0)>0?"warn":"ok")}">
            health ${(l==null?void 0:l.health)??"ok"}
          </span>
          <span class="command-chip">${(o==null?void 0:o.provenance)??"truth"}</span>
        </div>
      </article>

      <article class="room-truth-card room-truth-card-focus">
        <span class="room-truth-label">next focus</span>
        <strong>${(c==null?void 0:c.label)??"지금은 방 전체가 비교적 안정적입니다"}</strong>
        <p>${(c==null?void 0:c.reason)??((f=(v=l==null?void 0:l.attention_summary)==null?void 0:v.top_item)==null?void 0:f.summary)??(a==null?void 0:a.summary)??"다음 drill-down 대상이 아직 없습니다."}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${li((c==null?void 0:c.provenance)==="fallback"?"warn":"ok")}">${(c==null?void 0:c.source)??"steady"}</span>
          <span class="command-chip">${(c==null?void 0:c.provenance)??(($=l==null?void 0:l.recommendation_summary)==null?void 0:$.provenance)??"derived"}</span>
        </div>
        ${c!=null&&c.suggested_tab?i`
              <div class="room-truth-actions">
                <button class="control-btn ghost" onClick=${Av}>
                  ${c.suggested_tab==="intervene"?"개입면 열기":"지휘면 열기"}
                </button>
              </div>
            `:null}
      </article>
    </section>
  `}const Ia="masc_dashboard_workflow_context",Tv=900*1e3;function $t(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function Qt(t){const e=$t(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function zc(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function lo(t){return _(t)?t:null}function Iv(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function Rv(t){if(!t)return null;try{const e=JSON.parse(t);if(!_(e))return null;const n=$t(e.id),s=$t(e.source_surface),a=$t(e.source_label),o=$t(e.summary),l=$t(e.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!o||!l?null:{id:n,source_surface:s,source_label:a,action_type:$t(e.action_type),target_type:$t(e.target_type),target_id:$t(e.target_id),focus_kind:$t(e.focus_kind),operation_id:$t(e.operation_id),command_surface:$t(e.command_surface),summary:o,payload_preview:$t(e.payload_preview),suggested_payload:lo(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:l}}catch{return null}}function Ho(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=Tv}function Mv(){const t=zc(),e=Rv((t==null?void 0:t.getItem(Ia))??null);return e?Ho(e)?e:(t==null||t.removeItem(Ia),null):null}const Nc=g(Mv());function jc(t){const e=t&&Ho(t)?t:null;Nc.value=e;const n=zc();if(!n)return;if(!e){n.removeItem(Ia);return}const s=Iv(e);s&&n.setItem(Ia,s)}function Ev(t){if(!t)return null;const e=lo(t.suggested_payload);if(e)return e;if(_(t.preview)){const n=lo(t.preview.payload);if(n)return n}return null}function Lv(t){if(!t)return null;const e=Qt(t.message);if(e)return e;const n=Qt(t.task_title)??Qt(t.title),s=Qt(t.task_description)??Qt(t.description),a=Qt(t.reason),o=Qt(t.priority)??Qt(t.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function Wo(t,e,n,s,a,o,l,c){return[t,e,n??"action",s??"target",a??"room",o??"focus",l??"operation",c].join(":")}function _n(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=Ev(t),o=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,l=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,c=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,p=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:Wo("mission",n,(t==null?void 0:t.action_type)??null,o,l,c,null,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:o,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:p,payload_preview:Lv(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function Pv({targetType:t,targetId:e,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:o=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:Wo("execution",s,null,t,e,n,o,c),source_surface:"execution",source_label:s,action_type:null,target_type:t,target_id:e,focus_kind:n,operation_id:o,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function zv(t,e){return(e.source==="mission"||e.source==="execution")&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)&&(e.operation_id??null)===(t.operation_id??null)}function us(t){const{params:e}=t;if(e.source!=="mission"&&e.source!=="execution")return null;const n=Nc.value;if(n&&Ho(n)&&zv(n,e))return n;const s=new Date().toISOString(),a=e.source==="execution"?"execution":"mission";return{id:Wo(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,e.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,operation_id:e.operation_id??null,command_surface:e.surface??null,summary:a==="execution"?e.focus_kind?`${e.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function Oc(t){return{source:t.source_surface,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function Dc(t){if(t.command_surface)return t.command_surface;const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.focus_kind==="operation"||t.target_type==="operation"?"operations":t.target_type==="room"?"orchestra":"swarm"}function qc(t){return{source:t.source_surface,surface:Dc(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function Nv(t){return Oc(t)}function jv(t){return qc(t)}function Go(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function Za(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(t==null?void 0:t.trim())||"추천 액션"}}function Ov(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"orchestra":return"오케스트라";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}const Gt=g(null),se=g(null);function Lt(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function It(t){return t==="bad"||t==="offline"||t==="critical"||t==="risk"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"||t==="watch"?"warn":"ok"}function Yt(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function Dv(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"확인 필요":t<60?`${Math.round(t)}초`:t<3600?`${Math.round(t/60)}분`:t<86400?`${Math.round(t/3600)}시간`:`${Math.round(t/86400)}일`}function qt(t){switch((t??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"pending":return"대기 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":case"watch":return"주의";case"bad":case"critical":case"risk":return"위험";case"degraded":return"저하";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"loading":return"불러오는 중";case"error":return"오류";case"unavailable":return"사용 불가";case"stale":return"오래됨";case"refreshing":return"갱신 중";case"cached":return"캐시";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Ra(t){switch((t??"").trim().toLowerCase()){case"room":return"방";case"team_session":case"session":return"세션";case"operation":return"작전";case"keeper":return"키퍼";case"agent":return"에이전트";default:return(t==null?void 0:t.trim())||"대상"}}function Ir(t){switch((t??"").trim().toLowerCase()){case"metadata_gap":return"메타데이터 부족";case"mixed":return"신호 혼재";case"":return null;default:return(t==null?void 0:t.trim())||null}}function qv(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function wv(t){return Go(t?_n(t,null,"상황판 추천 액션"):null)}function ti(t,e=_n()){jc(e),ot(t,t==="intervene"?Nv(e):jv(e))}function wc(t){ti("intervene",_n(null,t,"상황판 incident"))}function Fc(t){ti("command",_n(null,t,"상황판 incident"))}function Jo(t,e,n="상황판 추천 액션"){ti("intervene",_n(t,e,n))}function Kc(t,e,n="상황판 추천 액션"){ti("command",_n(t,e,n))}function co(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),ot(t,n)}function Fv(t){return{kind:t.kind,severity:t.severity,summary:t.summary,target_type:t.target_type,target_id:t.target_id??null,actor:null,evidence:t.evidence_preview}}function Kv(t){var n,s;const e=ve.value.find(a=>a.name===t.name||a.agent_name===t.agent_name)??null;return{brief:t,keeper:e,currentWork:Lt(t.current_work,110)??Lt(e==null?void 0:e.skill_primary,110)??Lt(e==null?void 0:e.last_proactive_reason,110)??"명시된 키퍼 초점 없음",recentInput:Lt(e==null?void 0:e.recent_input_preview,120)??null,recentOutput:Lt(e==null?void 0:e.recent_output_preview,120)??Lt((n=e==null?void 0:e.diagnostic)==null?void 0:n.last_reply_preview,120)??Lt(e==null?void 0:e.last_proactive_preview,120)??null,recentEvent:Lt(e==null?void 0:e.last_proactive_reason,120)??Lt((s=e==null?void 0:e.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(e==null?void 0:e.recent_tool_names)??[]}}function Bv(){const t=Xa.value;if(!t)return new Map;const e=t.sessions.length>0?t.sessions:t.session_briefs;return new Map(e.map(n=>[n.session_id,n]))}function Uv(t){Gt.value=Gt.value===t?null:t,se.value=null}function Bc(t){se.value=se.value===t?null:t,Gt.value=null}function Hv(){Gt.value=null,se.value=null}function Wv({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,o=2*Math.PI*s,l=o*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),i`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${c}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${o}" 
          stroke-dashoffset="${l}" 
        />
      </svg>
      <span class="mitosis-text ${c}">${Math.round(t*100)}%</span>
    </div>
  `}function Gv(t){switch(t.trim().toLowerCase()){case"active":case"running":return"가동 중";case"working":return"작업 중";case"watching":return"관찰 중";case"quiet":return"조용함";case"idle":return"유휴";case"ok":case"healthy":return"정상";case"warn":case"warning":case"degraded":return"주의";case"bad":case"critical":case"error":case"failed":return"위험";case"blocked":return"막힘";case"paused":return"일시정지";case"pending":return"대기";case"offline":case"inactive":return"오프라인";case"connected":return"연결됨";case"disconnected":return"끊김";case"ready":return"준비됨";case"done":case"completed":return"완료";case"unknown":return"알 수 없음";default:return t}}function ge({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??Gv(t)}
    </span>
  `}function Uc(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}초 전`;const a=Math.floor(s/60);if(a<60)return`${a}분 전`;const o=Math.floor(a/60);return o<24?`${o}시간 전`:`${Math.floor(o/24)}일 전`}function X({timestamp:t}){const e=Uc(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}function Jv(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Rr(t,e="없음"){return!t||t.length===0?e:t.slice(0,4).join(", ")}function Hc({model:t,onClick:e,variant:n,testId:s}){var c,p,m,u;const a=!!t.recentEvent||!!t.recentInput||!!t.recentOutput||!!t.routeSummary||!!t.auditSource||!!t.auditAt||(((c=t.recentTools)==null?void 0:c.length)??0)>0||(((p=t.allowedTools)==null?void 0:p.length)??0)>0,o=n==="mission"?`mission-activity-card ${t.tone}`:"keeper-canonical-card",l=n==="mission"?"mission-card-select":`monitor-row ${t.tone}${t.stateClass?` state-${t.stateClass}`:""}`;return i`
    <article class=${o}>
      <button class=${l} data-testid=${s} onClick=${e}>
        <div class=${n==="mission"?"mission-activity-head":"monitor-row-header"}>
          <div class=${n==="mission"?"mission-activity-title":"monitor-row-title"}>
            <span class="agent-emoji">${t.emoji??""}</span>
            <div>
              <div class=${n==="mission"?"":"monitor-name-line"}>
                <strong class=${n==="mission"?"":"monitor-title"}>${t.name}</strong>
                ${t.koreanName?i`<span class=${n==="mission"?"":"monitor-sub"}>${t.koreanName}</span>`:null}
              </div>
              ${t.runtimeLabel?i`<div class=${n==="mission"?"":"monitor-sub"}>${t.runtimeLabel}</div>`:null}
              ${t.note?i`<div class=${n==="mission"?"":"monitor-note"}>${t.note}</div>`:null}
            </div>
          </div>
          ${n==="execution"?i`
                <${Wv} ratio=${t.contextRatio??0} size=${34} stroke=${4} />
                <${ge} status=${t.statusRaw??"unknown"} />
                ${t.stateLabel?i`<span class="monitor-pill ${t.tone}">${t.stateLabel}</span>`:null}
              `:i`<span class="command-chip ${t.tone}">${t.statusLabel}</span>`}
        </div>

        <div class=${n==="mission"?"mission-activity-meta":"monitor-meta"}>
          ${t.lastActivityAt?i`<span>최근 활동 <${X} timestamp=${t.lastActivityAt} /></span>`:i`<span>${t.lastActivityFallback??"최근 활동 없음"}</span>`}
          ${t.relatedSessionId?i`<span>세션 · ${t.relatedSessionId}</span>`:null}
          ${t.continuity?i`<span>${t.continuity}</span>`:null}
          ${t.lifecycle?i`<span>생애주기 ${t.lifecycle}</span>`:null}
          <span>컨텍스트 ${Jv(t.contextRatio)}</span>
        </div>

        <div class=${n==="mission"?"mission-activity-focus":"monitor-focus"}>
          ${n==="mission"?i`
                <span>무엇을</span>
                <strong>${t.focus}</strong>
              `:i`${t.focus}`}
        </div>

        ${t.summary?i`<div class=${n==="mission"?"mission-inline-note":"monitor-footnote"}>${t.summary}</div>`:null}
      </button>

      ${a?i`
            <details class="mission-card-disclosure compact">
              <summary>${t.disclosureLabel??"세부 정보"}</summary>
              <div class="mission-activity-foot">
                ${t.recentEvent?i`<span>최근 일 · ${t.recentEvent}</span>`:null}
                ${t.routeSummary?i`<span>route · ${t.routeSummary}</span>`:null}
                ${t.auditSource?i`<span>audit · ${t.auditSource}</span>`:null}
                ${t.auditAt?i`<span><${X} timestamp=${t.auditAt} /></span>`:null}
              </div>
              ${t.recentInput||t.recentOutput?i`
                    <div class="mission-io-stack">
                      <div class="mission-io-item">
                        <span>최근 입력</span>
                        <strong>${t.recentInput??"표시 가능한 최근 입력이 없습니다"}</strong>
                      </div>
                      <div class="mission-io-item">
                        <span>최근 응답</span>
                        <strong>${t.recentOutput??"표시 가능한 최근 응답이 없습니다"}</strong>
                      </div>
                    </div>
                  `:null}
              ${(((m=t.recentTools)==null?void 0:m.length)??0)>0||(((u=t.allowedTools)==null?void 0:u.length)??0)>0?i`
                    <div class="mission-activity-foot">
                      <span>최근 도구 · ${Rr(t.recentTools)}</span>
                      <span>허용 도구 · ${Rr(t.allowedTools)}</span>
                    </div>
                  `:null}
            </details>
          `:null}
    </article>
  `}function Wc(t,e){const n=t==null?void 0:t.trim(),s=e==null?void 0:e.trim();return s?n&&s===n?null:s:null}function Gc(t,e){const n=Wc(t,e);return n?`runtime · ${n}`:null}function Jc(t,e){const n=t==null?void 0:t.trim(),s=Wc(n,e);return n?s?`keeper key · ${n} · runtime agent · ${s}`:`keeper key · ${n}`:null}function ci(t){return(t==null?void 0:t.trim().toLowerCase())??""}function Yv(t){var e,n;return t?((e=t.agent)==null?void 0:e.exists)===!1||ci((n=t.diagnostic)==null?void 0:n.health_state)==="offline"||ci(t.status)==="offline"||ci(t.status)==="inactive"?"offline":"online":"unlinked"}function Xv(t){switch(t){case"offline":return"offline";case"none_recent":return"none_recent";case"not_applicable":return"not_applicable";case"unlinked":return"unlinked";default:return"not_collected"}}function Vv(t){const e=Yv(t);return e==="unlinked"?"unlinked":e==="offline"?"offline":"none_recent"}let Qv=0;const Ee=g([]);function j(t,e="success",n=4e3){const s=++Qv;Ee.value=[...Ee.value,{id:s,message:t,type:e}],setTimeout(()=>{Ee.value=Ee.value.filter(a=>a.id!==s)},n)}function Zv(t){Ee.value=Ee.value.filter(e=>e.id!==t)}function tf(){const t=Ee.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Zv(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const ef="masc_dashboard_agent_name",vn=g(null),Ma=g(!1),Wn=g(""),Ea=g([]),Gn=g([]),nn=g(""),En=g(!1);function ps(t){vn.value=t,Yo()}function Mr(){vn.value=null,Wn.value="",Ea.value=[],Gn.value=[],nn.value=""}function nf(){const t=vn.value;return t?Vt.value.find(e=>e.name===t)??null:null}function Yc(t){return t?ae.value.filter(e=>e.assignee===t):[]}function sf(t){return t?ve.value.find(e=>e.agent_name===t||e.name===t)??null:null}function af(t){if(!t)return null;const e=Xa.value;return e?e.agent_briefs.find(n=>n.agent_name===t)??null:null}function of(t){return t?Eo.value.find(e=>e.agent_name===t||e.name===t)??null:null}async function Yo(){const t=vn.value;if(t){Ma.value=!0,Wn.value="",Ea.value=[],Gn.value=[];try{const e=await bp(80);Ea.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Yc(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await kp(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const l=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));Gn.value=s}catch(e){Wn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Ma.value=!1}}}async function Er(){var s;const t=vn.value,e=nn.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(ef))==null?void 0:s.trim())||"dashboard";En.value=!0;try{await yp(n,`@${t} ${e}`),nn.value="",j(`Mention sent to ${t}`,"success"),Yo()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";j(o,"error")}finally{En.value=!1}}function rf({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${ge} status=${t.status} />
    </div>
  `}function lf({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Lr(t,e=160){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function cf(){const t=vn.value;if(!t)return null;const e=nf(),n=sf(t),s=of(t),a=af(t),o=Yc(t),l=Ea.value,c=(a==null?void 0:a.display_name)??(n==null?void 0:n.name)??t,p=c!==t?t:null,m=(e==null?void 0:e.status)??(a==null?void 0:a.status)??"unknown",u=!e&&(a==null?void 0:a.is_live)===!1,v=(e==null?void 0:e.last_seen)??(a==null?void 0:a.last_activity_at)??null,f=(e==null?void 0:e.emoji)??(n==null?void 0:n.emoji),$=(e==null?void 0:e.koreanName)??(n==null?void 0:n.koreanName),C=Lr(s==null?void 0:s.continuity_summary)??Lr(s==null?void 0:s.skill_route_summary)??null,b=Jc(n==null?void 0:n.name,n==null?void 0:n.agent_name);return i`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${k=>{k.target.classList.contains("agent-detail-overlay")&&Mr()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${f?i`<span style="font-size:2rem">${f}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${c}
                  ${$?i`<span style="font-size:0.75em;color:#888">(${$})</span>`:""}
                  ${p?i`<span class="mono" style="font-size:0.75em;color:#888">${p}</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  <${ge} status=${m} />
                  ${u?i`<span class="pill">archived session participant</span>`:null}
                  ${e!=null&&e.model?i`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                  ${!e&&(a!=null&&a.archived_reason)?i`<span style="font-size:0.75rem;color:#888">${a.archived_reason}</span>`:null}
                </div>
              </div>
            </div>
            <div class="agent-detail-sub">
              ${e!=null&&e.current_task||a!=null&&a.current_work?i`<span>Task: ${(e==null?void 0:e.current_task)??(a==null?void 0:a.current_work)}</span>`:null}
              ${v?i`<span>Last seen: <${X} timestamp=${v} /></span>`:null}
            </div>
            ${n||C||a!=null&&a.related_session_id?i`
                  <div class="agent-detail-sub">
                    ${n?i`<span>Linked keeper: ${n.name}${b?` · ${b}`:""}</span>`:null}
                    ${a!=null&&a.related_session_id?i`<span>Session: ${a.related_session_id}</span>`:null}
                    ${C?i`<span>${C}</span>`:null}
                  </div>
                `:null}
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Yo()}} disabled=${Ma.value}>
              ${Ma.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Mr}>Close</button>
          </div>
        </div>

        ${Wn.value?i`<div class="council-error">${Wn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${R} title="Assigned Tasks">
            ${o.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${o.map(k=>i`<${rf} key=${k.id} task=${k} />`)}</div>`}
          <//>

          <${R} title="Recent Activity">
            ${l.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${l.map((k,h)=>i`<div key=${h} class="agent-activity-line">${k}</div>`)}</div>`}
          <//>
        </div>
        <${R} title="Task History">
          ${Gn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${Gn.value.map(k=>i`<${lf} key=${k.taskId} row=${k} />`)}</div>`}
        <//>

        <${R} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${nn.value}
              onInput=${k=>{nn.value=k.target.value}}
              onKeyDown=${k=>{k.key==="Enter"&&Er()}}
              disabled=${En.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Er()}}
              disabled=${En.value||nn.value.trim()===""}
            >
              ${En.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function df(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function uf(t){switch(t.delivery){case"sending":return"sending";case"streaming":return t.streamState==="finalizing"?"finalizing":"streaming";case"timeout":return"timeout";case"error":return"error";case"history":return t.role;default:return"delivered"}}function di(t){return t.delivery==="error"||t.delivery==="timeout"?"error":t.role==="user"?"user":t.role==="assistant"?"assistant":"system"}function Xc(t){return t.role==="user"?"You":t.label.trim()?t.label.trim():t.role}function pf(t){return Xc(t).slice(0,2).toUpperCase()}function mf(t){var n;const e=(n=t==null?void 0:t.usage)==null?void 0:n.totalTokens;return typeof e=="number"&&Number.isFinite(e)?`${e} tok`:null}function _f(t){return t?[t.modelUsed??null,typeof t.latencyMs=="number"?`${t.latencyMs} ms`:null,mf(t)].filter(e=>!!e):[]}function Pr(t){return typeof t!="number"||!Number.isFinite(t)?null:t===0?"$0.00":t<.01?`$${t.toFixed(4)}`:`$${t.toFixed(2)}`}function vf(t){if(!t)return[];const e=["Goal","Progress","Next","Decisions","OpenQuestions","Constraints"];return t.split(`
`).map(n=>n.trim()).filter(Boolean).map(n=>{const s=e.find(a=>n.startsWith(`${a}:`));return s?{label:s,value:n.slice(s.length+1).trim()}:null}).filter(n=>!!(n&&n.value))}function ff(t){var e;return[t.modelUsed?{label:"Model",value:t.modelUsed}:null,typeof t.latencyMs=="number"?{label:"Latency",value:`${t.latencyMs} ms`}:null,typeof((e=t.usage)==null?void 0:e.totalTokens)=="number"?{label:"Tokens",value:`${t.usage.totalTokens}`}:null,Pr(t.costUsd)?{label:"Cost",value:Pr(t.costUsd)}:null,t.traceId?{label:"Trace",value:t.traceId}:null,typeof t.generation=="number"?{label:"Generation",value:`${t.generation}`}:null].filter(n=>!!n)}function gf({entry:t}){var m;const[e,n]=qn(!1),[s,a]=qn(!1),o=_f(t.details),l=!!t.details,c=t.details?ff(t.details):[],p=vf((m=t.details)==null?void 0:m.stateBlock);return i`
    <article class=${`chat-bubble ${di(t)}`}>
      <div class="chat-bubble-head">
        <div class="chat-bubble-identity">
          <div class=${`chat-avatar ${di(t)}`}>${pf(t)}</div>
          <div class="chat-bubble-identity-copy">
            <div class="chat-bubble-labels">
              <span class=${`chat-role-chip ${di(t)}`}>${t.label}</span>
              <span class="chat-delivery-chip">${uf(t)}</span>
              ${t.timestamp?i`<span class="chat-time-chip">${df(t.timestamp)}</span>`:null}
            </div>
            <div class="chat-identity-title">${Xc(t)}</div>
          </div>
        </div>
        ${l?i`
              <button
                type="button"
                class="chat-disclosure-btn"
                onClick=${()=>{n(!e)}}
              >
                ${e?"Hide details":"Show details"}
              </button>
            `:null}
      </div>

      ${o.length>0?i`<div class="chat-detail-chip-row">
            ${o.map(u=>i`<span class="chat-detail-chip">${u}</span>`)}
          </div>`:null}

      <div class="chat-bubble-body">${t.text||(t.delivery==="streaming"?"…":"(empty reply)")}</div>
      ${t.error?i`<div class="chat-bubble-error">${t.error}</div>`:null}

      ${e&&t.details?i`
            <div class="chat-detail-panel">
              ${c.length>0?i`
                    <div class="chat-overview-grid">
                      ${c.map(u=>i`
                        <div class="chat-overview-card">
                          <div class="chat-overview-label">${u.label}</div>
                          <div class="chat-overview-value">${u.value}</div>
                        </div>
                      `)}
                    </div>
                  `:null}
              ${t.details.skillPrimary?i`
                    <div class="chat-detail-callout">
                      <div class="chat-detail-callout-label">Skill Route</div>
                      <div class="chat-detail-callout-value">${t.details.skillPrimary}</div>
                      ${t.details.skillReason?i`<div class="chat-detail-callout-copy">${t.details.skillReason}</div>`:null}
                    </div>
                  `:null}
              ${p.length>0?i`
                    <div class="chat-detail-section">
                      <div class="chat-detail-section-title">State Snapshot</div>
                      <div class="chat-state-grid">
                        ${p.map(u=>i`
                          <div class="chat-state-card">
                            <div class="chat-state-label">${u.label}</div>
                            <div class="chat-state-value">${u.value}</div>
                          </div>
                        `)}
                      </div>
                    </div>
                  `:null}
              ${t.details.rawPayload?i`
                    <div class="chat-detail-section">
                      <button
                        type="button"
                        class="chat-raw-toggle"
                        onClick=${()=>{a(!s)}}
                      >
                        ${s?"Hide raw payload":"Show raw payload"}
                      </button>
                      ${s?i`<pre>${JSON.stringify(t.details.rawPayload,null,2)}</pre>`:null}
                    </div>
                  `:null}
            </div>
          `:null}
    </article>
  `}function $f({entries:t,emptyText:e}){const n=An(null),s=t.map(a=>`${a.id}:${a.text.length}:${a.delivery}`).join("|");return nt(()=>{const a=n.current;a&&(a.scrollTop=a.scrollHeight)},[s]),i`
    <div class="chat-transcript" ref=${n}>
      ${t.length===0?i`<div class="chat-empty-copy">${e}</div>`:t.map(a=>i`<${gf} key=${a.id} entry=${a} />`)}
    </div>
  `}function hf({draft:t,placeholder:e,disabled:n,streaming:s,onDraftChange:a,onSend:o,onAbort:l}){return i`
    <div class="chat-composer">
      <textarea
        class="control-textarea chat-composer-input"
        placeholder=${e}
        value=${t}
        onInput=${c=>{a(c.target.value)}}
        disabled=${n}
      ></textarea>
      <div class="chat-composer-actions">
        <button
          type="button"
          class="control-btn"
          onClick=${o}
          disabled=${n||s||t.trim()===""}
        >
          ${s?"Streaming…":"Send"}
        </button>
        ${s&&l?i`
              <button
                type="button"
                class="control-btn ghost"
                onClick=${l}
              >
                Stop
              </button>
            `:null}
      </div>
    </div>
  `}function yf(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function bf(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function kf(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function xf(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Vc(t){if(!t)return null;const e=Xt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function Sf({keeper:t,showRawStatus:e=!1}){if(nt(()=>{t!=null&&t.name&&Dl(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Xt.value[t.name],s=Vc(t),a=Hi.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${yf(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${bf((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${kf(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${xf(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Qc({keeperName:t,placeholder:e}){const[n,s]=qn("");nt(()=>{t&&Dl(t)},[t]);const a=ft.value[t]??[],o=ra.value[t]??!1,l=Dt.value[t],c=async()=>{const p=n.trim();if(!(!t||!p)){s("");try{await Hp(t,p)}catch(m){if(m instanceof Error&&m.name==="AbortError")return;const u=m instanceof Error?m.message:`Failed to message ${t}`;j(u,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <${$f}
        entries=${a}
        emptyText="No direct keeper conversation yet."
      />
      <${hf}
        draft=${n}
        placeholder=${e}
        disabled=${!t}
        streaming=${o}
        onDraftChange=${s}
        onSend=${()=>{c()}}
        onAbort=${()=>{Ol(t)}}
      />
      ${l?i`<div class="control-status-copy control-error-copy">${l}</div>`:null}
    </div>
  `}function Cf({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=Vc(e),a=Wi.value[e.name]??!1,o=Gi.value[e.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{Wp(e.name,t).catch(p=>{const m=p instanceof Error?p.message:`Failed to probe ${e.name}`;j(m,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{Gp(e.name,t).catch(p=>{const m=p instanceof Error?p.message:`Failed to recover ${e.name}`;j(m,"error")})}}
        disabled=${o||!c||!t.trim()}
      >
        ${o?"Recovering...":"Recover"}
      </button>
      <button
        class=${`control-btn ghost ${l==="manual_lodge_poke"?"is-active":""}`}
        onClick=${n}
      >
        Poke Lodge
      </button>
    </div>
  `}const Xo=g(null);function Zc(t){Xo.value=t,Up(t.name)}function zr(){Xo.value=null}function Af(t){return typeof t!="number"||Number.isNaN(t)?"확인 필요":t>=.85?"높음":t>=.7?"상승 중":"안정"}function Tf({keeper:t}){var u,v;const e=t.metrics_series??[];if(e.length<2){const f=(((u=t.context)==null?void 0:u.context_ratio)??t.context_ratio??0)*100,$=f>85?"#ef4444":f>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${f.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${f.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=e.length,l=e.map((f,$)=>{const C=a+$/(o-1)*(n-2*a),b=s-a-(f.context_ratio??0)*(s-2*a);return{x:C,y:b,p:f}}),c=l.map(({x:f,y:$})=>`${f.toFixed(1)},${$.toFixed(1)}`).join(" "),p=(((v=e[e.length-1])==null?void 0:v.context_ratio)??0)*100,m=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:f})=>f.is_handoff).map(({x:f})=>i`
          <line x1="${f.toFixed(1)}" y1="${a}" x2="${f.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${m}" stroke-width="1.5"/>
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}function If({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
    <div>
      <div style="display:flex; gap:12px; margin-bottom:10px;">
        <div style="flex:1;">
          <div style="font-size:11px; color:#888;">HP ${t.hp}/${t.max_hp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${e}%; height:100%; background:${e>50?"#4ade80":e>25?"#fbbf24":"#ef4444"}; border-radius:3px;" />
          </div>
        </div>
        <div style="flex:1;">
          <div style="font-size:11px; color:#888;">MP ${t.mp}/${t.max_mp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${n}%; height:100%; background:#818cf8; border-radius:3px;" />
          </div>
        </div>
      </div>
      <div style="display:grid; grid-template-columns: repeat(3,1fr); gap:6px;">
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(s=>i`
          <div style="text-align:center; padding:6px; background:rgba(255,255,255,0.03); border-radius:6px;">
            <div style="font-size:10px; color:#888; text-transform:uppercase;">${s.label}</div>
            <div style="font-size:16px; font-weight:bold; color:#e0e0e0;">${s.value}</div>
          </div>
        `)}
      </div>
      <div style="margin-top:8px; font-size:12px; color:#888;">
        Level ${t.level} · XP ${t.xp}
      </div>
    </div>
  `}function Rf({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px;">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Mf({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Nr({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom:12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}async function Ef(){try{const t=await Ga({actor:xl(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Nl(t.result);await ls(),e!=null&&e.skipped_reason?j(e.skipped_reason,"warning"):j(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";j(e,"error")}}function Lf({keeper:t}){return i`
    <div style="margin-top:24px; border-top:1px solid rgba(255,255,255,0.1); padding-top:24px;">
      <h3 style="margin:0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display:grid; grid-template-columns:1fr 1fr; gap:20px;">
        <div style="display:flex; flex-direction:column; gap:12px;">
          <${Sf} keeper=${t} />
          <${Cf}
            actor=${xl()}
            keeper=${t}
            onPokeLodge=${()=>{Ef()}}
          />
        </div>

        <div style="min-height:345px;">
          <${Qc}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function Pf(){var s,a,o,l,c;const t=Xo.value;if(!t)return null;const e=Jc(t.name,t.agent_name),n=(((s=t.traits)==null?void 0:s.length)??0)>0||(((a=t.interests)==null?void 0:a.length)??0)>0||!!t.skill_primary||!!t.last_heartbeat;return i`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${p=>{p.target.classList.contains("keeper-detail-overlay")&&zr()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?i`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
              ${e?i`<div style="font-size:12px; color:#94a3b8;">${e}</div>`:null}
              ${t.agent_name?i`<div style="font-size:12px; color:#888;">Runtime agent: ${t.agent_name}</div>`:null}
            </div>
            <${ge} status=${t.status} />
          </div>
          <button
            onClick=${()=>zr()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        <${Tf} keeper=${t} />

        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">
          ${n?i`
                <${R} title="Profile">
                  <${Nr} traits=${t.traits??[]} label="Traits" />
                  <${Nr} traits=${t.interests??[]} label="Interests" />
                  ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span></div>`:null}
                  ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">Last heartbeat: <${X} timestamp=${t.last_heartbeat} /></div>`:null}
                <//>
              `:null}

          ${t.trpg_stats?i`
                <${R} title="TRPG Stats">
                  <${If} stats=${t.trpg_stats} />
                <//>
              `:null}

          ${t.inventory&&t.inventory.length>0?i`
                <${R} title="Equipment (${t.inventory.length})">
                  <${Rf} items=${t.inventory} />
                <//>
              `:null}

          ${t.relationships&&Object.keys(t.relationships).length>0?i`
                <${R} title="Relationships (${Object.keys(t.relationships).length})">
                  <${Mf} rels=${t.relationships} />
                <//>
              `:null}

          <${R} title="Memory & Context">
            <div class="keeper-signal-list">
              <div class="keeper-signal-row">
                <span>Context pressure</span>
                <strong>${Af(((o=t.context)==null?void 0:o.context_ratio)??t.context_ratio??null)}</strong>
              </div>
              <div class="keeper-signal-row">
                <span>Current ratio</span>
                <strong>
                  ${typeof(((l=t.context)==null?void 0:l.context_ratio)??t.context_ratio)=="number"?`${Math.round((((c=t.context)==null?void 0:c.context_ratio)??t.context_ratio??0)*100)}%`:"-"}
                </strong>
              </div>
              ${t.memory_recent_note?i`<div class="keeper-memory-note">${t.memory_recent_note}</div>`:i`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>

        <${Lf} keeper=${t} />
      </div>
    </div>
  `}function zf({cluster:t,project:e,room:n,generatedAt:s}){return i`
    <div class="mission-context-bar">
      <div class="mission-context-item">
        <span>클러스터</span>
        <strong>${t??"확인 없음"}</strong>
      </div>
      <div class="mission-context-item">
        <span>프로젝트</span>
        <strong>${e??"확인 없음"}</strong>
      </div>
      <div class="mission-context-item">
        <span>방</span>
        <strong>${n??"기본 방"}</strong>
      </div>
      <div class="mission-context-item">
        <span>갱신 시각</span>
        <strong>${s?Yt(s):"기록 없음"}</strong>
      </div>
    </div>
  `}function Nf(){const t=dc.value,e=It((t==null?void 0:t.status)??(Ce.value?"bad":"warn")),n=!t||t.sections.length===0,s=(t==null?void 0:t.status)==="error"||(t==null?void 0:t.status)==="unavailable"&&!(t!=null&&t.cached);return i`
    <${R} title="판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>휴리스틱 대신 별도 판단 결과</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${e}">
          ${qt((t==null?void 0:t.status)??(Ce.value?"error":"loading"))}
        </span>
        ${t!=null&&t.model?i`<span class="command-chip">${t.model}</span>`:null}
        ${t!=null&&t.generated_at?i`<span class="command-chip">${Yt(t.generated_at)}</span>`:null}
        ${t!=null&&t.cached?i`<span class="command-chip">캐시</span>`:null}
        ${t!=null&&t.stale?i`<span class="command-chip warn">오래됨</span>`:null}
        ${t!=null&&t.refreshing?i`<span class="command-chip warn">갱신 중</span>`:null}
      </div>

      ${Ce.value?i`<div class="empty-state error">${Ce.value}</div>`:null}
      ${t!=null&&t.error?i`<div class="empty-state error">${t.error}</div>`:null}
      ${t!=null&&t.summary?i`<div class="mission-inline-note">${t.summary}</div>`:null}
      ${t!=null&&t.last_error&&!t.error?i`<div class="mission-inline-note">최근 갱신 실패: ${t.last_error}</div>`:null}

      ${t&&t.sections.length>0?i`
            <div class="mission-briefing-grid">
              ${t.sections.slice(0,3).map(a=>i`
                <article class="mission-briefing-section ${It(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${It(a.status)}">${qt(a.status)}</span>
                      ${Ir(a.signal_class)?i`<span class="command-chip ${a.signal_class==="mixed"?"warn":""}">${Ir(a.signal_class)}</span>`:null}
                      ${a.evidence_quality?i`<span class="command-chip">${a.evidence_quality}</span>`:null}
                    </div>
                  </div>
                  <p>${a.summary}</p>
                  ${a.evidence.length>0?i`
                        <details class="mission-card-disclosure compact">
                          <summary>근거 보기</summary>
                          <div class="mission-pill-row">
                            ${a.evidence.map(o=>i`<span class="mission-pill">${o}</span>`)}
                          </div>
                        </details>
                      `:null}
                </article>
              `)}
            </div>
          `:!Fe.value&&!Ce.value&&n?i`
                <div class="empty-state">
                  ${(t==null?void 0:t.status)==="pending"?"최신 스냅샷으로 브리핑을 생성 중입니다. 마지막 성공 결과가 생기면 자동으로 다시 읽습니다.":"판단 결과가 아직 없습니다."}
                </div>
              `:null}

      ${t&&t.metadata_gaps.length>0?i`
            <details class="mission-card-disclosure compact mission-briefing-gaps">
              <summary>관측 공백 (${t.metadata_gap_count??t.metadata_gaps.length})</summary>
              <div class="mission-list-stack">
                ${t.metadata_gaps.map(a=>i`
                  <article class="mission-briefing-gap ${a.severity==="watch"?"warn":""}">
                    <div class="mission-card-head">
                      <strong>${Ra(a.scope_type)}${a.scope_id?` · ${a.scope_id}`:""}</strong>
                      <span class="command-chip ${a.severity==="watch"?"warn":""}">${qt(a.severity)}</span>
                    </div>
                    <p>${a.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{fa(s)}} disabled=${Fe.value}>
          ${Fe.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{fa(!0)}} disabled=${Fe.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function jf({item:t,selected:e,sessionLookup:n}){const s=Fv(t),a=t.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),o=t.top_action??null;return i`
    <article class="mission-attention-card ${It((o==null?void 0:o.severity)??t.severity)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Uv(t.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.summary}</strong>
            <div class="mission-card-target">${Ra(t.target_type)}${t.target_id?` · ${t.target_id}`:""}</div>
          </div>
          <span class="command-chip ${It((o==null?void 0:o.severity)??t.severity)}">${o?qv(o):t.severity}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>영향 세션</span>
            <strong>${t.related_session_ids.length}</strong>
            <small>${t.related_session_ids.slice(0,2).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>영향 에이전트</span>
            <strong>${t.related_agent_names.length}</strong>
            <small>${t.related_agent_names.slice(0,3).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 신호</span>
            <strong>${t.last_seen_at?Yt(t.last_seen_at):"기록 없음"}</strong>
            <small>${Ra(t.target_type)}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${o?Za(o.action_type):"판단 필요"}</strong>
            <small>${o?wv(o):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${o?i`<div class="mission-inline-note">${o.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?i`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>i`
                  <button class="mission-link-row" onClick=${()=>Bc(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${qt(l.status)} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:i`<div class="empty-state">직접 연결된 세션이 아직 없습니다.</div>`}

        ${t.related_agent_names.length>0?i`
              <div class="mission-pill-row">
                ${t.related_agent_names.slice(0,8).map(l=>i`
                  <button class="mission-pill action" onClick=${()=>ps(l)}>${l}</button>
                `)}
              </div>
            `:null}

        ${t.evidence_preview.length>0?i`
              <details class="mission-card-disclosure compact">
                <summary>근거 미리보기</summary>
                <div class="mission-evidence-list">
                  ${t.evidence_preview.map(l=>i`<span>${l}</span>`)}
                </div>
              </details>
            `:null}
      </details>

      <div class="mission-card-actions">
        ${o?i`
              <button class="control-btn ghost" onClick=${()=>Jo(o,s,"상황판 주의 신호")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>Kc(o,s,"상황판 주의 신호")}>
                원인 보기
              </button>
            `:i`
              <button class="control-btn ghost" onClick=${()=>wc(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Fc(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function Of({brief:t,selected:e}){var l,c;const n=t.member_previews.slice(0,4),s=t.top_recommendation??null,a=t.top_attention??null,o=n.map(p=>p.display_name??p.agent_name);return i`
    <article class="mission-crew-card ${It(((l=t.top_attention)==null?void 0:l.severity)??t.health??t.status)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Bc(t.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.goal}</strong>
            <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          </div>
          <span class="command-chip ${It(((c=t.top_attention)==null?void 0:c.severity)??t.health??t.status)}">${qt(t.status)}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${t.member_names.length}</strong>
            <small>${o.slice(0,3).join(", ")||t.member_names.slice(0,3).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${Dv(t.elapsed_sec)}</strong>
            <small>${t.started_at?`${Yt(t.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 흐름</span>
            <strong>${t.last_event_at?Yt(t.last_event_at):"기록 없음"}</strong>
            <small>${t.communication_summary??"요약 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>충원 상태</span>
            <strong>${t.active_count??0}/${t.required_count||1}</strong>
            <small>활성 / 필요</small>
          </div>
        </div>
      </button>

      ${t.blocker_summary?i`<div class="mission-inline-note">막힘 · ${t.blocker_summary}</div>`:null}

      <div class="mission-crew-event">
        <span>최근 사건</span>
        <strong>${t.last_event_summary??"최근 세션 이벤트가 없습니다."}</strong>
        <small>${t.last_event_at?Yt(t.last_event_at):"시각 없음"}</small>
      </div>

      ${t.operation_badges.length>0?i`
            <div class="mission-pill-row">
              ${t.operation_badges.slice(0,3).map(p=>i`
                <span class="mission-pill">
                  ${p.operation_id} · ${qt(p.status)}${p.stage?` · ${p.stage}`:""}
                </span>
              `)}
            </div>
          `:null}

      ${n.length>0?i`
            <div class="mission-member-preview-grid">
              ${n.map(p=>i`
                <button class="mission-member-preview" onClick=${()=>ps(p.agent_name)}>
                  <strong>${p.display_name??p.agent_name}</strong>
                  <span>${p.current_work??"현재 작업 없음"}</span>
                  <small>
                    ${p.recent_output_preview??p.recent_input_preview??"최근 입출력 없음"}
                    ${p.is_live===!1?" · archived participant":""}
                  </small>
                </button>
              `)}
            </div>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>co("intervene",t.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>co("command",t.session_id)}>세션 원인 보기</button>
        ${s?i`<button class="control-btn ghost" onClick=${()=>Jo(s,a,"상황판 세션 요약")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function Df({detail:t,loading:e,error:n}){if(e&&!t)return i`
      <${R} title="세션 상세" class="mission-list-card">
        <div class="loading-indicator">세션 상세 불러오는 중...</div>
      <//>
    `;if(n&&!t)return i`
      <${R} title="세션 상세" class="mission-list-card">
        <div class="empty-state error">${n}</div>
      <//>
    `;if(!(t!=null&&t.session))return null;const s=t.session;return i`
    <${R} title="세션 상세" class="mission-list-card" semanticId="mission.session_detail">
      <div class="mission-section-head">
        <h3>${s.goal}</h3>
        <p>${s.session_id}${s.room?` · ${s.room}`:""}</p>
      </div>

      ${n?i`<div class="mission-inline-note">${n}</div>`:null}

      <div class="mission-detail-grid">
        <div class="mission-detail-column">
          <div class="mission-card-head">
            <strong>타임라인</strong>
            <span class="command-chip">${t.timeline.length}</span>
          </div>
          <div class="mission-timeline-list">
            ${t.timeline.length>0?t.timeline.map(a=>i`
                  <article class="mission-timeline-row">
                    <div class="mission-card-head">
                      <strong>${a.summary}</strong>
                      <span>${a.timestamp?Yt(a.timestamp):"시각 없음"}</span>
                    </div>
                    <small>${a.actor?`${a.actor} · `:""}${a.event_type??"이벤트"}</small>
                  </article>
                `):i`<div class="empty-state">표시할 세션 이벤트가 없습니다.</div>`}
          </div>
        </div>

        <div class="mission-detail-column">
          <div class="mission-card-head">
            <strong>참여자</strong>
            <span class="command-chip">${t.participants.length}</span>
          </div>
          <div class="mission-activity-list compact">
            ${t.participants.length>0?t.participants.map(a=>i`
                  <button class="mission-member-preview" onClick=${()=>ps(a.agent_name)}>
                    <strong>${a.display_name??a.agent_name}</strong>
                    <span>${a.current_work??"현재 작업 없음"}</span>
                    <small>
                      ${a.recent_output_preview??a.recent_input_preview??"최근 입출력 없음"}
                      ${a.is_live===!1?" · archived participant":""}
                      ${a.last_activity_at?` · ${Yt(a.last_activity_at)}`:""}
                    </small>
                  </button>
                `):i`<div class="empty-state">세션 참여자 미리보기가 없습니다.</div>`}
          </div>
        </div>
      </div>

      <div class="mission-detail-grid">
        <div class="mission-detail-column">
          <div class="mission-card-head">
            <strong>연결된 작전</strong>
            <span class="command-chip">${t.operations.length}</span>
          </div>
          <div class="mission-link-list">
            ${t.operations.length>0?t.operations.map(a=>i`
                  <button class="mission-link-row" onClick=${()=>co("command",s.session_id)}>
                    <strong>${a.operation_id}</strong>
                    <span>${qt(a.status)}${a.stage?` · ${a.stage}`:""}</span>
                    <small>${a.detachment_status??a.objective??"분견대 정보 없음"}</small>
                  </button>
                `):i`<div class="empty-state">연결된 작전이 없습니다.</div>`}
          </div>
        </div>

        <div class="mission-detail-column">
          <div class="mission-card-head">
            <strong>연속성 관찰</strong>
            <span class="command-chip">${t.keepers.length}</span>
          </div>
          <div class="mission-link-list">
            ${t.keepers.length>0?t.keepers.map(a=>i`
                  <div class="mission-link-row static">
                    <strong>${a.name}</strong>
                    <span>${qt(a.status)}${a.generation!=null?` · 세대 ${a.generation}`:""}</span>
                    <small>${a.current_work??"현재 작업 정보 없음"}</small>
                  </div>
                `):i`<div class="empty-state">직접 연결된 키퍼는 없습니다.</div>`}
          </div>
        </div>
      </div>
    <//>
  `}function qf({row:t}){var o,l,c,p,m,u,v,f,$,C,b,k;const e=[`세대 ${t.brief.generation??((o=t.keeper)==null?void 0:o.generation)??0}`,t.brief.context_ratio!=null?`컨텍스트 ${Math.round(t.brief.context_ratio*100)}%`:((l=t.keeper)==null?void 0:l.context_ratio)!=null?`컨텍스트 ${Math.round(t.keeper.context_ratio*100)}%`:null,t.brief.last_turn_ago_s!=null?`최근 턴 ${Math.round(t.brief.last_turn_ago_s)}초 전`:null].filter(h=>h!==null).join(" · "),n=t.recentTools.length>0?t.recentTools.join(", "):Xv(Vv(t.keeper)),s=Gc(t.brief.name,t.brief.agent_name??((c=t.keeper)==null?void 0:c.agent_name)),a={name:t.brief.name,koreanName:((p=t.keeper)==null?void 0:p.koreanName)??null,runtimeLabel:s,emoji:((m=t.keeper)==null?void 0:m.emoji)??null,tone:It(t.brief.status??((u=t.keeper)==null?void 0:u.status)),statusRaw:t.brief.status??((v=t.keeper)==null?void 0:v.status)??null,statusLabel:qt(t.brief.status??((f=t.keeper)==null?void 0:f.status)),focus:t.currentWork,lastActivityAt:(($=t.keeper)==null?void 0:$.last_heartbeat)??null,lastActivityFallback:"최근 활동 없음",continuity:e||"연속성 정보 없음",contextRatio:t.brief.context_ratio??((C=t.keeper)==null?void 0:C.context_ratio)??null,summary:(b=t.keeper)!=null&&b.skill_reason?`판단 요약 · ${Lt(t.keeper.skill_reason,120)}`:null,relatedSessionId:null,recentEvent:t.recentEvent,recentInput:t.recentInput,recentOutput:t.recentOutput,recentTools:t.recentTools,allowedTools:[],disclosureLabel:"연속성 상세"};return i`<${Hc}
    variant="mission"
    model=${{...a,recentTools:t.recentTools.length>0?t.recentTools:[n],recentEvent:t.recentEvent??`runtime agent · ${t.brief.agent_name??((k=t.keeper)==null?void 0:k.agent_name)??"기록 없음"}`}}
    onClick=${()=>{t.keeper&&Zc(t.keeper)}}
  />`}function wf({item:t}){const e=t.action??null,n=t.attention??null;return i`
    <article class="mission-action-card ${It(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${It(t.severity)}">
          ${t.signal_type==="action"&&e?Za(e.action_type):(n==null?void 0:n.kind)??"내부 신호"}
        </span>
        <span class="mission-card-target">${Ra(t.target_type)}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      ${e?i`<div class="mission-action-preview">${e.reason}</div>`:null}
      <div class="mission-card-actions">
        ${e?i`
              <button class="control-btn ghost" onClick=${()=>Jo(e,n,"상황판 내부 신호")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Kc(e,n,"상황판 내부 신호")}>이 이슈의 원인 보기</button>
            `:n?i`
                <button class="control-btn ghost" onClick=${()=>wc(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>Fc(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function jr(){var u;const t=Xa.value;if(to.value&&!t)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(va.value&&!t)return i`<div class="empty-state error">${va.value}</div>`;if(!t)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;Gt.value&&!t.attention_queue.some(v=>v.id===Gt.value)&&(Gt.value=null);const e=t.sessions;se.value&&!e.some(v=>v.session_id===se.value)&&(se.value=null);const n=t.attention_queue.find(v=>v.id===Gt.value)??null,s=(n==null?void 0:n.related_session_ids.find(v=>e.some(f=>f.session_id===v)))??null,a=se.value??s??((u=e[0])==null?void 0:u.session_id)??null,o=Bv(),l=e.find(v=>v.session_id===a)??null,c=t.keeper_briefs.slice(0,6).map(Kv),p=t.attention_queue.filter(v=>v.related_session_ids.length>0).slice(0,6),m=t.internal_signals.slice(0,3);return nt(()=>{h_(a)},[a]),i`
    <section class="dashboard-panel mission-view">
      <${kt} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 어떤 세션이 돌고 있고, 누가 참여하며, 어디가 막혔는지를 한 시점에서 읽는 기본 관찰면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${It(t.summary.room_health)}">${qt(t.summary.room_health)}</span>
          <span class="command-chip">${t.summary.project??"프로젝트 미지정"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?Yt(t.generated_at):"기록 없음"}</span>
        </div>
      </div>

      <${Qa} />

      <${zf}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <${Nf} />

      ${a?i`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${(l==null?void 0:l.goal)??a}${n?` · ${n.summary}`:""}</span>
              <button class="control-btn ghost" onClick=${Hv}>선택 해제</button>
            </div>
          `:null}

      <${R} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 작전을 먼저 봅니다.</p>
        </div>
        <div class="mission-list-stack">
          ${e.length>0?e.map(v=>i`<${Of} key=${v.session_id} brief=${v} selected=${a===v.session_id} />`):i`<div class="empty-state">지금 활성 세션이 없습니다.</div>`}
        </div>
      <//>

      <${Df}
        detail=${eo.value}
        loading=${Xs.value}
        error=${Vs.value}
      />

      <div class="mission-human-grid">
        <${R} title="주의 대기열" class="mission-list-card" semanticId="mission.attention_queue">
          <div class="mission-section-head">
            <h3>어느 세션을 먼저 봐야 하나</h3>
            <p>문제와 경고는 세션에 연결된 것만 먼저 보여주고, 원인 분석은 선택된 세션에서 이어서 봅니다.</p>
          </div>
          <div class="mission-lane-stack">
            ${p.length>0?p.map(v=>i`<${jf} key=${v.id} item=${v} selected=${Gt.value===v.id} sessionLookup=${o} />`):i`<div class="empty-state">지금 세션 단위 주의 대기열은 비어 있습니다.</div>`}
          </div>
        <//>

        <${R} title="내부 신호" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>시스템 진단</h3>
            <p>artifact scope drift 같은 내부 신호는 메인 판단을 방해하지 않도록 접어 둔 보조 면에만 둡니다.</p>
          </div>
          <details class="mission-card-disclosure">
            <summary>내부 신호 ${m.length}</summary>
            <div class="mission-list-stack">
              ${m.length>0?m.map(v=>i`<${wf} key=${v.id} item=${v} />`):i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
            </div>
          </details>
        <//>
      </div>

      <${R} title="키퍼 연속성" class="mission-list-card" semanticId="mission.keeper_activity">
        <div class="mission-section-head">
          <h3>키퍼 연속성 요약</h3>
          <p>카드 제목은 keeper 이름이고, runtime agent 이름은 상세에만 보조 라벨로 보여줍니다.</p>
        </div>
        <div class="mission-activity-list">
          ${c.length>0?c.map(v=>i`<${qf} key=${v.brief.name} row=${v} />`):i`<div class="empty-state">지금 보이는 키퍼가 없습니다.</div>`}
        </div>
        <div class="mission-card-actions">
          <button class="control-btn ghost" onClick=${()=>ot("execution")}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${()=>ot("command")}>지휘 진단면 보기</button>
        </div>
      <//>
    </section>
  `}const Ff="modulepreload",Kf=function(t){return"/dashboard/"+t},Or={},Bf=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(m){return Promise.all(m.map(u=>Promise.resolve(u).then(v=>({status:"fulfilled",value:v}),v=>({status:"rejected",reason:v}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),p=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(m=>{if(m=Kf(m),m in Or)return;Or[m]=!0;const u=m.endsWith(".css"),v=u?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${v}`))return;const f=document.createElement("link");if(f.rel=u?"stylesheet":Ff,u||(f.as="script"),f.crossOrigin="",f.href=m,p&&f.setAttribute("nonce",p),document.head.appendChild(f),u)return new Promise(($,C)=>{f.addEventListener("load",$),f.addEventListener("error",()=>C(new Error(`Unable to preload CSS for ${m}`)))})}))}function o(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&o(c.reason);return e().catch(o)})};function La(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function et(t){if(!t)return"정보 없음";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function Uf(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function td(t){if(!t)return"정보 없음";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"기한 지남":n<60?`${n}초 후`:n<3600?`${Math.round(n/60)}분 후`:n<86400?`${Math.round(n/3600)}시간 후`:`${Math.round(n/86400)}일 후`}function L(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let Dr=!1,Hf=0;function Wf(){return++Hf}let ui=null;async function Gf(){ui||(ui=Bf(()=>import("./mermaid.core-jGXAHDhK.js").then(e=>e.bE),[]).then(e=>e.default));const t=await ui;return Dr||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),Dr=!0),t}function ce(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function ms(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":`${Math.round(t*100)}%`}function Sn(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":t<60?`${Math.round(t)}초`:t<3600?`${Math.round(t/60)}분`:`${Math.round(t/3600)}시간`}function _s(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function be(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:_s(t/e*100)}function Jf(t,e){const n=_s(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function ed(t){if(!t)return"최근 체인 이력이 없습니다";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`토큰 ${t.tokens}`),t.message&&e.push(t.message),e.join(" · ")}const Yf=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],nd=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"orchestra",label:"오케스트라",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],Xf=nd.map(t=>t.id),Vf=["chain_start","node_start","node_complete","chain_complete","chain_error"],Qf={warroom:{title:"실시간 워룸",description:"실제 실행, 워커, 메시지, 트레이스를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 작전, 분견대, 의존 관계를 먼저 읽는 기본 진입 표면입니다."},orchestra:{title:"룸 오케스트라 맵",description:"룸, 세션, 레인, 워커, 키퍼를 한 장의 작전판으로 읽는 시각화 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"레인 이동, 워커 결속, 막힘을 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 작전별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"실제 관리 유닛인지, 실시간 에이전트 기반 자동 투영인지 구분해서 봅니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"작전, 주체, 유닛 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"결정 승인과 유닛 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function qr(t){return!!t&&Xf.includes(t)}function Zf(){const t=D.value.params;return t.source!=="mission"&&t.source!=="execution"?{}:{source:t.source,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function Vo(t){const e=Zf(),n=id(),s=Qo();if(t==="operations")return e;if(t==="chains"){const a=tn.value;return a?{...e,surface:t,operation:a}:{...e,surface:t}}return t==="swarm"||t==="warroom"||t==="orchestra"?{...e,surface:t,...n?{run_id:n}:{},...s?{operation_id:s}:{}}:{...e,surface:t}}function tg(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function eg(t){switch(t){case"company":return"중대";case"platoon":return"소대";case"squad":return"분대";case"agent":return"에이전트";default:return t}}function ct(t){return so.value===t}function vs(){return Do.value}function ng(t){var a,o,l,c,p,m,u;const e=Do.value,n=Oe.value,s=ds.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"실시간 실행, 워커, 메시지, 트레이스를 한 화면에서 보고 필요한 세부 표면으로 바로 이동합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 의존 관계를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(o=e==null?void 0:e.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((p=(c=e==null?void 0:e.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:p.reason)??"레인 이동과 막힘 근거를 보고 다음 확인 도구를 고릅니다."};case"orchestra":return{tool:"masc_operator_snapshot",reason:"룸, 세션, 레인, 워커, 키퍼를 한 장에서 훑은 뒤 내려볼 대상을 고릅니다."};case"chains":return{tool:(u=(m=s==null?void 0:s.operations[0])==null?void 0:m.preview_run)!=null&&u.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"이 구조가 실제 관리 단위인지 자동 투영인지 먼저 구분해야 지휘면을 오해하지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 유닛과 작전을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"트레이스 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 제어 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function sg(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function ag(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function sd(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function ad(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function id(){const e=ad().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Qo(){const e=ad().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function ig(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function og(t){return t.status==="claimed"||t.status==="in_progress"}function rg(t){const e=cs.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function pi(t){var e;return((e=cs.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function lg(t){const e=cs.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function de(t){try{await t()}catch{}}function Zo(t){return(t==null?void 0:t.trim().toLowerCase())??""}function Ue(t){const e=Zo(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function ke(t){const e=Zo(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function cg(){var n,s,a,o,l,c,p,m,u;const t=Oe.value;if(!t)return!1;const e=t.workers.some(v=>v.joined||v.live_presence||v.completed||v.current_task_matches_run||v.heartbeat_fresh||v.claim_marker_seen||v.done_marker_seen||v.final_marker_seen||!!v.current_task||!!v.bound_task_id||!!v.last_message);return!!((n=t.operation)!=null&&n.operation_id||(s=t.detachment)!=null&&s.detachment_id||(((a=t.summary)==null?void 0:a.joined_workers)??0)>0||(((o=t.summary)==null?void 0:o.live_workers)??0)>0||(((l=t.summary)==null?void 0:l.current_task_bound)??0)>0||(((c=t.summary)==null?void 0:c.fresh_heartbeats)??0)>0||(((p=t.summary)==null?void 0:p.claim_markers_seen)??0)>0||(((m=t.summary)==null?void 0:m.done_markers_seen)??0)>0||(((u=t.summary)==null?void 0:u.final_markers_seen)??0)>0||e||t.recent_messages.length>0||t.recent_trace_events.length>0)}function dg(t){const e=Zo(t.status);return e==="active"||e==="running"}function ug(){var o,l,c,p;const t=((o=Mt.value)==null?void 0:o.sessions)??[],e=Oe.value,n=((l=e==null?void 0:e.detachment)==null?void 0:l.session_id)??null;if(n){const m=t.find(u=>u.session_id===n);if(m)return m}const s=((c=e==null?void 0:e.operation)==null?void 0:c.operation_id)??Qo();if(s){const m=t.find(u=>u.command_plane_operation_id===s);if(m)return m}const a=((p=e==null?void 0:e.detachment)==null?void 0:p.detachment_id)??null;if(a){const m=t.find(u=>u.command_plane_detachment_id===a);if(m)return m}return t.find(dg)??t[0]??null}function mi(t){return t==="proven"?"ok":t==="partial"?"warn":"bad"}function He(t){return Array.isArray(t)?t:[]}function Pt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)?t:{}}function Ts(t){return typeof t=="string"&&t.trim()!==""?t:null}function pg(t){return typeof t=="number"&&Number.isFinite(t)?t:null}function mg(t){const e=t.split("/");return e.length<=3?t:`…/${e.slice(-3).join("/")}`}function _g(t){return t==="proven"?"충분":t==="partial"?"부분":"부족"}function vg(t){return t==="proven"?"협업 증거가 충분합니다":t==="partial"?"흔적은 있으나 협업 증거가 덜 모였습니다":"증거가 부족합니다"}function fg(t,e,n,s,a,o,l){const c=[`${e}명이 실제 흔적을 남겼고, 계획된 참여자는 ${n}명입니다.`,a>0?`서로를 참조한 상호작용 증거가 ${a}건 있습니다.`:"서로를 참조한 명시적 상호작용 증거가 아직 없습니다.",o>0?`도구·산출물·체크포인트 증거가 ${o}건 있습니다.`:"도구·산출물·체크포인트 증거가 거의 없습니다.",l>0?`CPv2 backing trace가 ${l}건 있어 실행 흔적은 남아 있습니다.`:"관리형 backing trace는 아직 없습니다."];return t==="partial"?[c[0]??"",s>0?`partial인 이유: 호출되었지만 응답하지 않은 참여자가 ${s}명 있습니다.`:a===0?"partial인 이유: 여러 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.":"partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.",l>0?"다음 보강 포인트: 응답 턴이나 도구 호출을 남기면 proof가 협업 수준으로 올라갑니다.":"다음 보강 포인트: 관리형 trace 또는 산출물 연결을 더 남기면 근거가 강해집니다."]:t==="proven"?[c[0]??"","결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.","다음 행동: raw evidence는 접어두고 결과 산출물과 다음 실행 결정만 확인하면 됩니다."]:[c[0]??"",s>0?`결론: 협업 시도는 있었지만 무응답 참여자가 ${s}명 있어 협업 증거로 인정하기 어렵습니다.`:"결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.",o>0?"다음 보강 포인트: 응답 턴과 도구 근거를 서로 연결해 남겨야 합니다.":"다음 보강 포인트: 참여자 간 턴, 도구 근거, 산출물 연결을 더 남겨야 합니다."]}function wr(t){return(t==null?void 0:t.mode)==="requested_not_found"?"bad":(t==null?void 0:t.mode)==="latest_auto_selected"?"warn":"ok"}function gg(t){return(t==null?void 0:t.mode)==="requested_not_found"?"선택 실패":(t==null?void 0:t.mode)==="latest_auto_selected"?"자동 선택":(t==null?void 0:t.mode)==="explicit"?"명시 선택":"선택 없음"}function $g(t){return t.activity_state==="acted"?(t.interaction_count??0)>0||(t.tool_evidence_count??0)>0?"ok":"warn":t.activity_state==="mentioned_only"?"warn":"bad"}function hg(t){return t.activity_state==="acted"?"실제 흔적":t.activity_state==="mentioned_only"?"호출만 됨":"계획만 됨"}function yg(t){if(t.activity_state==="acted")return`턴 ${t.turn_count??0} · spawn ${t.spawn_count??0} · 도구 근거 ${t.tool_evidence_count??0}`;if(t.activity_state==="mentioned_only"){const e=t.requested_by?`호출자 ${t.requested_by}`:"호출자 미상";return`호출 ${t.mention_count??0}회 · ${e}`}return"계획된 참여자이지만 아직 이벤트가 없습니다."}function Fr(t){return Array.isArray(t.tool_names)?t.tool_names:[]}function bg({selection:t}){return!t||t.mode==="explicit"?null:i`
    <div class="command-guide-card ${wr(t)}">
      <div class="command-guide-head">
        <strong>${gg(t)}</strong>
        <span class="command-chip ${wr(t)}">${t.mode??"none"}</span>
      </div>
      <p>${t.reason??"근거 컨텍스트 선택 정보가 없습니다."}</p>
      <div class="command-card-grid">
        <span>선택된 세션</span><span>${t.selected_session_id??"없음"}</span>
        <span>작성자</span><span>${t.selected_created_by??"없음"}</span>
        <span>선택된 목표</span><span>${t.selected_goal??"없음"}</span>
        <span>가용 세션 수</span><span>${t.available_session_count??0}</span>
      </div>
    </div>
  `}function kg({item:t}){return i`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${t.summary??t.event_type??"도구 근거"}</strong>
          <div class="command-meta-line">
            <span>${t.actor??"시스템"}</span>
            <span>${t.event_type??"event"}</span>
          </div>
        </div>
        <span class="command-chip">${et(t.timestamp??null)}</span>
      </div>
      ${Fr(t).length>0?i`<div class="semantic-tag-row">
            ${Fr(t).map(e=>i`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
    </article>
  `}function xg(t){const e=new Map;for(const n of t){const s=[n.timestamp??"",n.event_type??"",n.actor??"",n.summary??""].join("|"),a=n.source??"unknown",o=e.get(s);if(o){o.sources.includes(a)||o.sources.push(a),!o.operation_id&&n.operation_id&&(o.operation_id=n.operation_id);continue}e.set(s,{...n,sources:[a]})}return[...e.values()]}function Sg(t){return t.sources.length===2?"세션 + 지휘":t.sources.length===1?t.sources[0]==="unknown"?"출처 미상":t.sources[0]??"출처":t.sources.join(" + ")}function Cg(t){const e=[];for(const[n,s]of Object.entries(t))if(s!=null){if(typeof s=="string"){if(s.trim()==="")continue;e.push({label:n,value:s});continue}if(typeof s=="number"||typeof s=="boolean"){e.push({label:n,value:String(s)});continue}}return e}function Ag(t){const e=Pt(t),n=Pt(e.traces),s=Array.isArray(n.events)?n.events:[],a=Pt(e.detachments),o=Array.isArray(a.detachments)?a.detachments:[],l=Pt(o[0]),c=Pt(l.detachment),p=Pt(l.operation),m=Pt(e.summary),u=Pt(m.operations),v=Pt(u.summary);return[{label:"작전",value:Ts(e.operation_id)??"없음"},{label:"분견대",value:Ts(e.detachment_id)??"없음"},{label:"트레이스 이벤트",value:`${s.length}`},{label:"분견대 상태",value:Ts(c.status)??"없음"},{label:"작전 단계",value:Ts(p.stage)??"없음"},{label:"활성 작전",value:`${pg(v.active)??0}`}]}function Tg({item:t}){return i`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${t.summary??t.event_type??"이벤트"}</strong>
          <div class="command-meta-line">
            <span>${Sg(t)}</span>
            <span>${t.event_type??"이벤트"}</span>
            <span>${t.actor??"시스템"}</span>
          </div>
        </div>
        <span class="command-chip">${et(t.timestamp)}</span>
      </div>
      ${t.sources.length>1?i`<div class="semantic-tag-row">
            ${t.sources.map(e=>i`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
    </article>
  `}function Ig({item:t}){const e=t.recent_output_preview??null,n=t.recent_input_preview??null,s=t.recent_event_summary??null,a=t.recent_request_preview??null,o=t.last_active_at??t.recent_request_at??null;return i`
    <article class="mission-activity-row proof-actor-row">
      <div class="mission-activity-head">
        <div>
          <strong>${t.actor}</strong>
          <div class="mission-activity-meta">
            <span>${t.role??"참여자"}</span>
            <span>${o?et(o):"기록 없음"}</span>
          </div>
        </div>
        <span class="command-chip ${$g(t)}">
          ${hg(t)}
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>${yg(t)}</span>
      </div>
      ${t.activity_detail?i`<div class="proof-summary-block">
            <strong>현재 해석</strong>
            <span>${t.activity_detail}</span>
          </div>`:null}
      ${s?i`<div class="proof-summary-block">
            <strong>최근 흔적</strong>
            <span>${s}</span>
          </div>`:null}
      ${a&&t.activity_state!=="acted"?i`<div class="proof-summary-block">
            <strong>최근 요청</strong>
            <span>${a}</span>
          </div>`:null}
      ${n||e?i`<div class="proof-io-grid">
            <div class="mission-activity-preview">
              <strong>최근 입력</strong>
              <span>${n??"표시 가능한 입력 없음"}</span>
            </div>
            <div class="mission-activity-preview">
              <strong>최근 응답</strong>
              <span>${e??"표시 가능한 응답 없음"}</span>
            </div>
          </div>`:null}
      ${He(t.recent_tool_names).length>0?i`<div class="semantic-tag-row">
            ${He(t.recent_tool_names).map(l=>i`<span class="semantic-tag">${l}</span>`)}
          </div>`:null}
    </article>
  `}function Rg({item:t}){return i`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${t.kind}</strong>
          <div class="command-meta-line">
            <span>${mg(t.path)}</span>
          </div>
        </div>
        <span class="command-chip ${t.exists?"ok":"warn"}">${t.exists?"존재함":"없음"}</span>
      </div>
    </article>
  `}function Kr({title:t,rows:e}){return e.length===0?null:i`
    <div class="proof-kv-block">
      ${t?i`<strong>${t}</strong>`:null}
      <div class="proof-kv-grid">
        ${e.map(n=>i`
          <span>${n.label}</span>
          <strong>${n.value}</strong>
        `)}
      </div>
    </div>
  `}function Mg(){var G,V,it;const t=D.value.params,e=t.session_id??null,n=t.operation_id??null;nt(()=>{$c(e,n)},[e,n]);const s=gc.value;if(no.value&&!s)return i`<section class="dashboard-panel"><div class="loading-indicator">근거 화면 불러오는 중…</div></section>`;if(Ke.value&&!s)return i`<section class="dashboard-panel"><div class="error-card">${Ke.value}</div></section>`;const a=s==null?void 0:s.summary,o=(s==null?void 0:s.selection)??null,l=He(s==null?void 0:s.actor_contributions),c=He(s==null?void 0:s.artifacts),p=He(s==null?void 0:s.tool_evidence),m=(s==null?void 0:s.proof_verdict)??"insufficient",u=(s==null?void 0:s.cp_backing_evidence)??null,v=Array.isArray((G=u==null?void 0:u.traces)==null?void 0:G.events)?((it=(V=u.traces)==null?void 0:V.events)==null?void 0:it.length)??0:0,f=(a==null?void 0:a.actors_count)??l.length,$=(a==null?void 0:a.planned_actor_count)??l.length,C=(a==null?void 0:a.unanswered_actor_count)??l.filter(z=>z.activity_state!=="acted"&&(z.mention_count??0)>0).length,b=(a==null?void 0:a.mentioned_actor_count)??l.filter(z=>(z.mention_count??0)>0).length,k=(a==null?void 0:a.interaction_count)??0,h=(a==null?void 0:a.evidence_count)??0,S=xg(He(s==null?void 0:s.timeline)),E=Cg(Pt(s==null?void 0:s.goal_binding)),M=Ag(u),P=c.filter(z=>z.exists).length,W=c.length-P,I=fg(m,f,$,C,k,h,v);return i`
    <section class="dashboard-panel mission-view">
      <${kt} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>근거</h2>
          <p>이 세션이 실제로 여러 참여자의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${mi(m)}">${_g(m)}</span>
          ${s!=null&&s.session_id?i`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?i`<span class="command-chip">${et(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${Ke.value?i`<div class="error-card">${Ke.value}</div>`:null}

      <${bg} selection=${o} />

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${mi(m)}">
          <span>판정</span>
          <strong>${vg(m)}</strong>
          <small>${(a==null?void 0:a.detail)??"협업 증거를 verdict로 요약합니다."}</small>
        </div>
        <div class="summary-stat-card">
          <span>실제 흔적</span>
          <strong>${f}</strong>
          <small>이벤트를 남긴 actor 수</small>
        </div>
        <div class="summary-stat-card ${$>f?"warn":"ok"}">
          <span>계획된 참여자</span>
          <strong>${$}</strong>
          <small>${b>0?`${b}명 호출됨`:"호출 기록 없음"}</small>
        </div>
        <div class="summary-stat-card ${C>0?"warn":"ok"}">
          <span>무응답</span>
          <strong>${C}</strong>
          <small>${C>0?"호출됐지만 응답 근거 없음":"무응답 참여자 없음"}</small>
        </div>
        <div class="summary-stat-card ${k>0?"ok":"warn"}">
          <span>직접 상호작용</span>
          <strong>${k}</strong>
          <small>참여자 간 직접 연결 근거</small>
        </div>
        <div class="summary-stat-card ${h>0?"ok":"warn"}">
          <span>근거</span>
          <strong>${h}</strong>
          <small>도구 / 산출물 / 체크포인트</small>
        </div>
        <div class="summary-stat-card ${v>0?"ok":"warn"}">
          <span>CP 트레이스</span>
          <strong>${v}</strong>
          <small>관리형 backing 이벤트</small>
        </div>
        <div class="summary-stat-card ${W===0&&c.length>0?"ok":"warn"}">
          <span>산출물</span>
          <strong>${P}/${c.length}</strong>
          <small>${W>0?`${W}개 누락`:"전부 존재함"}</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${R} title="3줄 근거 요약" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, 왜 아직 부족한지, 다음에 무엇을 남겨야 하는지만 먼저 봅니다.</p>
          </div>
          <div class="proof-summary-stack">
            ${I.map((z,T)=>i`
              <article class="proof-summary-block ${T===1&&m!=="proven"?mi(m):""}">
                <strong>${T===0?"지금 결론":T===1?"왜 이렇게 판정됐나":"다음 보강 포인트"}</strong>
                <span>${z}</span>
              </article>
            `)}
          </div>
        <//>

        <${R} title="목표 연결" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 화면이 어떤 세션과 목표를 기준으로 그려졌는지 먼저 고정합니다.</p>
          </div>
          <${Kr} rows=${E} />
          <details class="mission-card-disclosure compact">
            <summary>원본 목표 연결 JSON</summary>
            <pre class="command-json-block">${La((s==null?void 0:s.goal_binding)??{})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${R} title="협업 타임라인" class="mission-list-card" semanticId="proof.timeline">
          <div class="mission-section-head">
            <h3>협업 타임라인</h3>
            <p>team-session과 command-plane에서 같은 사건이 보이면 한 줄로 묶어 읽습니다.</p>
          </div>
          <div class="mission-list-stack">
            ${S.length>0?S.slice(0,18).map(z=>i`<${Tg} key=${z.id} item=${z} />`):i`<div class="empty-state">표시할 타임라인 근거가 없습니다.</div>`}
          </div>
        <//>

        <${R} title="참여 흔적" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>실제 흔적, 호출만 된 참여자, 계획만 된 참여자를 구분해서 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${l.length>0?l.map(z=>i`<${Ig} key=${z.actor} item=${z} />`):i`<div class="empty-state">표시할 참여 흔적이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${R} title="도구 근거" class="mission-list-card" semanticId="proof.tool_evidence">
          <div class="mission-section-head">
            <h3>어떤 도구를 언제 썼는가</h3>
            <p>숫자만 보여주지 말고, 최근 도구 호출 근거를 직접 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${p.length>0?p.map((z,T)=>i`<${kg} key=${`${z.actor??"system"}-${T}`} item=${z} />`):i`<div class="empty-state">기록된 tool evidence가 없습니다.</div>`}
          </div>
        <//>

        <${R} title="실행 근거" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>작전, 분견대, 트레이스 수만 먼저 보고, 원본 CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${Kr} rows=${M} />
          <details class="mission-card-disclosure compact">
            <summary>원본 CPv2 backing JSON</summary>
            <pre class="command-json-block">${La(u??{})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${R} title="산출물" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>어떤 파일 산출물이 남았나</h3>
            <p>proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${c.length>0?c.map(z=>i`<${Rg} key=${z.path} item=${z} />`):i`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function Eg(){const t=us(D.value);return t?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${Za(t.action_type)}</span>
        <span class="command-chip">${Go(t)}</span>
        <span class="command-chip">${Ov(D.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?i`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function Lg(){const t=Y.value,e=Qf[t],n=ng(t);return i`
    <section class="command-entry-strip">
      <article class="command-entry-card">
        <span class="command-entry-label">현재 표면</span>
        <strong>${e.title}</strong>
        <p>${e.description}</p>
      </article>
      <article class="command-entry-card">
        <span class="command-entry-label">다음 추천</span>
        <strong>${n.tool}</strong>
        <p>${n.reason}</p>
      </article>
    </section>
  `}function Is({label:t,value:e,subtext:n,percent:s,color:a}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${Jf(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(_s(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function Rs({label:t,value:e,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${L(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${L(a)}" style=${`width: ${Math.max(8,Math.round(_s(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function Pg(){var V,it,z,T;const t=vs(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary,l=(V=t==null?void 0:t.swarm_status)==null?void 0:V.overview,c=t==null?void 0:t.swarm_proof,p=t==null?void 0:t.operations.microarch,m=(e==null?void 0:e.managed_unit_count)??0,u=(e==null?void 0:e.total_units)??0,v=(n==null?void 0:n.active)??0,f=(s==null?void 0:s.active)??0,$=(l==null?void 0:l.moving_lanes)??0,C=(l==null?void 0:l.active_lanes)??0,b=(c==null?void 0:c.workers.done)??0,k=(c==null?void 0:c.workers.expected)??0,h=(o==null?void 0:o.bad)??0,S=(o==null?void 0:o.warn)??0,E=(a==null?void 0:a.pending)??0,M=(a==null?void 0:a.total)??0,P=v+f,W=((it=p==null?void 0:p.cache)==null?void 0:it.l1_hit_rate)??((T=(z=p==null?void 0:p.signals)==null?void 0:z.cache_contention)==null?void 0:T.l1_hit_rate)??0,I=v>0||f>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",G=v>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${I}</h3>
        <p>${G}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${L(v>0?"ok":"warn")}">활성 작전 ${v}</span>
          <span class="command-chip ${L($>0?"ok":(C>0,"warn"))}">이동 레인 ${$}/${Math.max(C,$)}</span>
          <span class="command-chip ${L(h>0?"bad":S>0?"warn":"ok")}">치명 알림 ${h}</span>
          <span class="command-chip ${L(E>0?"warn":"ok")}">승인 대기 ${E}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Is}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(u,m)}`}
          subtext=${u>0?`${u-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${be(m,Math.max(u,m))}
          color="#67e8f9"
        />
        <${Is}
          label="실행 열도"
          value=${String(P)}
          subtext=${`${v}개 작전 + ${f}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${be(P,Math.max(m,P||1))}
          color="#4ade80"
        />
        <${Is}
          label="스웜 이동감"
          value=${`${$}/${Math.max(C,$)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${et(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${be($,Math.max(C,$||1))}
          color="#fbbf24"
        />
        <${Is}
          label="증거 수집률"
          value=${`${b}/${Math.max(k,b)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${be(b,Math.max(k,b||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${Rs}
        label="승인 대기열"
        value=${`${E}건 대기`}
        detail=${`현재 정책 창에서 ${M}개 결정을 추적 중입니다`}
        percent=${be(E,Math.max(M,E||1))}
        tone=${E>0?"warn":"ok"}
      />
      <${Rs}
        label="알림 압력"
        value=${`치명 ${h} / 주의 ${S}`}
        detail=${h>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${be(h*2+S,Math.max((h+S)*2,1))}
        tone=${h>0?"bad":S>0?"warn":"ok"}
      />
      <${Rs}
        label="디스패치 점유"
          value=${`${f}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${be(f,Math.max(m,f||1))}
        tone=${f>0?"ok":"warn"}
      />
      <${Rs}
        label="캐시 신뢰도"
        value=${W?ms(W):"정보 없음"}
        detail=${W?"microarch 캐시 텔레메트리에서 집계한 L1 적중률":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${_s((W??0)*100)}
        tone=${W>=.75?"ok":W>=.4?"warn":"bad"}
      />
    </div>
  `}function zg(){var f,$,C,b,k;const t=vs(),e=ds.value,n=us(D.value),s=sg(n),a=t==null?void 0:t.topology.summary,o=t==null?void 0:t.operations.summary,l=(f=t==null?void 0:t.swarm_status)==null?void 0:f.overview,c=t==null?void 0:t.operations.microarch,p=t==null?void 0:t.decisions.summary,m=t==null?void 0:t.alerts.summary,u=($=c==null?void 0:c.signals)==null?void 0:$.issue_pressure,v=c==null?void 0:c.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((C=t==null?void 0:t.detachments.summary)==null?void 0:C.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(p==null?void 0:p.pending)??0}</strong><small>${(p==null?void 0:p.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 주의</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((b=e==null?void 0:e.summary)==null?void 0:b.active_chains)??0}</strong><small>${((k=e==null?void 0:e.summary)==null?void 0:k.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${et(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(v==null?void 0:v.l1_hit_rate)!=null?`${ms(v.l1_hit_rate)} L1 적중`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"정보 없음"}</small></div>
    </div>
  `}function Ng(){var V,it,z,T,A,Q,at,J,Bt;const t=vs(),e=Kt.value,n=vt.value,s=sd(),a=s?Vt.value.find(B=>B.name===s)??null:null,o=s?ae.value.filter(B=>B.assignee===s&&og(B)):[],l=((V=t==null?void 0:t.operations.summary)==null?void 0:V.active)??0,c=((it=t==null?void 0:t.detachments.summary)==null?void 0:it.total)??0,p=((z=t==null?void 0:t.decisions.summary)==null?void 0:z.pending)??0,m=e==null?void 0:e.detachments.detachments.find(B=>{const Et=B.detachment.heartbeat_deadline,$e=Et?Date.parse(Et):Number.NaN;return B.detachment.status==="stalled"||!Number.isNaN($e)&&$e<=Date.now()}),u=e==null?void 0:e.alerts.alerts.find(B=>B.severity==="bad"),v=!!(n!=null&&n.room||n!=null&&n.project),f=(a==null?void 0:a.current_task)??null,$=ig(a==null?void 0:a.last_seen),C=$!=null?$<=120:null,b=[v?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:ae.value.length>0?"masc_claim":"masc_add_task"}:f?C===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${f} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${f}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((T=t.topology.summary)==null?void 0:T.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((A=t.topology.summary)==null?void 0:A.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Q=t.topology.summary)==null?void 0:Q.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},p>0?{title:"디스패치 준비도",tone:"warn",detail:`${p}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||u?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${u?` · alert ${u.title??u.alert_id}`:""}${!e&&!m&&!u?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],k=v?!s||!a?"masc_join":o.length===0?ae.value.length>0?"masc_claim":"masc_add_task":f?C===!1?"masc_heartbeat":!t||(((at=t.topology.summary)==null?void 0:at.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":p>0?"masc_policy_approve":l>0&&c===0||m||u?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",h=rg(k),E=lg(k==="masc_set_room"?["repo-root-room"]:k==="masc_plan_set_task"?["claimed-not-current"]:k==="masc_heartbeat"?["heartbeat-stale"]:k==="masc_dispatch_tick"?["no-detachments"]:k==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),M=pi("room_task_hygiene"),P=pi("cpv2_benchmark"),W=pi("supervisor_session"),I=((J=cs.value)==null?void 0:J.docs)??[],G=[M,P,W].filter(B=>B!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${w} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(h==null?void 0:h.title)??k}</strong>
            <span class="command-chip ok">${k}</span>
          </div>
          <p>${(h==null?void 0:h.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(Bt=h==null?void 0:h.success_signals)!=null&&Bt.length?i`<div class="command-tag-row">
                ${h.success_signals.map(B=>i`<span class="command-tag ok">${B}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${b.map(B=>i`
            <article class="command-readiness-row ${L(B.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${B.title}</strong>
                  <span class="command-chip ${L(B.tone)}">${B.tone}</span>
                </div>
                <p>${B.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${B.tool}</div>
            </article>
          `)}
        </div>

        ${E.length>0?i`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${E.length}</span>
                </div>
                <div class="command-guide-list">
                  ${E.map(B=>i`
                    <article class="command-guide-inline">
                      <strong>${B.title}</strong>
                      <div>${B.symptom}</div>
                      <div class="command-card-sub">${B.fix_tool} 로 해결: ${B.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `:null}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">운영 경로</div>
          <${w} panelId="command.summary" compact=${!0} />
        </div>
        ${ao.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:ka.value?i`<div class="empty-state error">${ka.value}</div>`:i`
                <div class="command-path-grid">
                  ${G.map(B=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${B.title}</strong>
                        <span class="command-chip">${B.id}</span>
                      </div>
                      <p>${B.summary}</p>
                      <div class="command-card-sub">${B.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${B.steps.slice(0,4).map(Et=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Et.tool}</span>
                            <span>${Et.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${I.length>0?i`<div class="command-doc-links">
                      ${I.map(B=>i`<span class="command-tag">${B.title}: ${B.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function jg(){return i`
    <${Pg} />
    <${zg} />
    <${Ng} />
  `}function Og(){return $a.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:ya.value?i`<div class="empty-state error">${ya.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}const xe=g(null),Ms=g("compact"),Zt=g({zoom:1,panX:0,panY:0}),_i=g(!1),Es=g(!1),Cn={width:1280,height:760},od=.42,rd=1.9;function Qs(t,e,n){return Math.max(e,Math.min(n,t))}function tr(t,e){const n=t==null?void 0:t.trim();return n?n.length<=e?n:`${n.slice(0,Math.max(1,e-1))}…`:null}function Dg(t){return t==="compact"?"집약":"균형"}function Br(t){switch((t??"").trim().toLowerCase()){case"room":return"룸";case"session":return"세션";case"operation":return"작전";case"detachment":return"분견대";case"lane":return"레인";case"worker":return"워커";case"keeper":return"키퍼";default:return(t==null?void 0:t.trim())||"노드"}}function Ls(t,e,n){if(t<=0)return[];if(t===1)return[Math.round((e+n)/2)];const s=(n-e)/(t-1);return Array.from({length:t},(a,o)=>Math.round(e+o*s))}function qg(t,e){const n=new Map;for(const s of t){const a=e(s),o=n.get(a)??[];o.push(s),n.set(a,o)}return n}function ld(t){return t==="compact"?{room:{x:660,y:108},sessions:{y:228,min:220,max:1110},operations:{y:338,min:260,max:1050},detachments:{y:430,min:310,max:1e3},lanes:{y:540,min:220,max:1110},worker:{perRow:5,xSpacing:60,ySpacing:52,laneOffsetY:76,freeBaseY:662},keeper:{startX:1180,colSpacing:92,rowSpacing:90,startY:176,columns:2},signalRadius:116}:{room:{x:700,y:112},sessions:{y:236,min:240,max:1140},operations:{y:356,min:300,max:1080},detachments:{y:454,min:340,max:1030},lanes:{y:584,min:230,max:1110},worker:{perRow:4,xSpacing:72,ySpacing:60,laneOffsetY:82,freeBaseY:720},keeper:{startX:1210,colSpacing:108,rowSpacing:102,startY:188,columns:2},signalRadius:132}}function cd(t,e){return t.kind==="room"?e==="compact"?{width:138,height:138,radius:68}:{width:156,height:156,radius:76}:t.kind==="worker"?e==="compact"?{width:70,height:36,radius:18}:{width:84,height:44,radius:22}:t.kind==="lane"?e==="compact"?{width:156,height:48,radius:15}:{width:176,height:56,radius:17}:t.kind==="keeper"?e==="compact"?{width:118,height:50,radius:22}:{width:132,height:60,radius:24}:t.kind==="session"?e==="compact"?{width:182,height:58,radius:17}:{width:202,height:68,radius:18}:e==="compact"?{width:176,height:58,radius:16}:{width:196,height:68,radius:18}}function wg(t,e){const n=t.kind==="worker"?e==="compact"?10:14:t.kind==="keeper"?e==="compact"?12:16:t.kind==="lane"?e==="compact"?16:22:e==="compact"?18:26;return tr(t.label,n)??t.label}function Fg(t,e){if(e==="compact"&&(t.kind==="worker"||t.kind==="keeper"||t.kind==="detachment"))return null;const n=t.kind==="session"?e==="compact"?20:28:e==="compact"?14:24;return tr(t.subtitle,n)}function Kg(t,e){return e==="compact"&&t.kind!=="session"&&t.kind!=="operation"?null:tr(t.status,e==="compact"?10:14)}function Bg(t,e){const n=ld(e),s=new Map,a=t.nodes,o=a.find(b=>b.kind==="room")??null,l=a.filter(b=>b.kind==="session"),c=a.filter(b=>b.kind==="operation"),p=a.filter(b=>b.kind==="detachment"),m=a.filter(b=>b.kind==="lane"),u=a.filter(b=>b.kind==="worker"),v=a.filter(b=>b.kind==="keeper");o&&s.set(o.id,{x:n.room.x,y:n.room.y}),Ls(l.length,n.sessions.min,n.sessions.max).forEach((b,k)=>{const h=l[k];h&&s.set(h.id,{x:b,y:n.sessions.y})}),Ls(c.length,n.operations.min,n.operations.max).forEach((b,k)=>{const h=c[k];h&&s.set(h.id,{x:b,y:n.operations.y})}),Ls(p.length,n.detachments.min,n.detachments.max).forEach((b,k)=>{const h=p[k];h&&s.set(h.id,{x:b,y:n.detachments.y})}),Ls(m.length,n.lanes.min,n.lanes.max).forEach((b,k)=>{const h=m[k];h&&s.set(h.id,{x:b,y:n.lanes.y})});const f=new Map(m.map(b=>{const k=s.get(b.id);return k?[b.id,k.x]:null}).filter(b=>b!==null)),$=qg(u,b=>b.lane_id?`lane:${b.lane_id}`:b.parent_id?b.parent_id:"free");let C=0;for(const[b,k]of $){let h=f.get(b.replace(/^lane:/,""));if(h==null){const E=s.get(b);h=E==null?void 0:E.x}h==null&&(h=260+C%4*180,C+=1);const S=Math.max(1,Math.ceil(k.length/n.worker.perRow));for(let E=0;E<S;E+=1){const M=k.slice(E*n.worker.perRow,(E+1)*n.worker.perRow),P=(M.length-1)*n.worker.xSpacing,W=h-P/2;M.forEach((I,G)=>{var V;s.set(I.id,{x:Math.round(W+G*n.worker.xSpacing),y:b==="free"?n.worker.freeBaseY+E*n.worker.ySpacing:(((V=s.get(b.replace(/^lane:/,"")))==null?void 0:V.y)??n.lanes.y)+n.worker.laneOffsetY+E*n.worker.ySpacing})})}}return v.forEach((b,k)=>{const h=k%n.keeper.columns,S=Math.floor(k/n.keeper.columns);s.set(b.id,{x:n.keeper.startX+h*n.keeper.colSpacing,y:n.keeper.startY+S*n.keeper.rowSpacing})}),s}function Ug(t,e,n){if(!e||t.signals.length===0)return[];const s=ld(n);return t.signals.slice(0,6).map((a,o)=>{const l=(-130+o*36)*(Math.PI/180);return{signalNode:a,x:Math.round(e.x+Math.cos(l)*s.signalRadius),y:Math.round(e.y+Math.sin(l)*s.signalRadius)}})}function Hg(t,e,n,s){let a=Number.POSITIVE_INFINITY,o=Number.NEGATIVE_INFINITY,l=Number.POSITIVE_INFINITY,c=Number.NEGATIVE_INFINITY;for(const p of t.nodes){const m=e.get(p.id);if(!m)continue;const u=cd(p,s);p.kind==="room"?(a=Math.min(a,m.x-u.radius),o=Math.max(o,m.x+u.radius),l=Math.min(l,m.y-u.radius),c=Math.max(c,m.y+u.radius)):(a=Math.min(a,m.x-u.width/2),o=Math.max(o,m.x+u.width/2),l=Math.min(l,m.y-u.height/2),c=Math.max(c,m.y+u.height/2))}for(const p of n)a=Math.min(a,p.x-20),o=Math.max(o,p.x+20),l=Math.min(l,p.y-20),c=Math.max(c,p.y+20);return!Number.isFinite(a)||!Number.isFinite(o)||!Number.isFinite(l)||!Number.isFinite(c)?{minX:0,minY:0,maxX:Cn.width,maxY:Cn.height,width:Cn.width,height:Cn.height}:{minX:a,minY:l,maxX:o,maxY:c,width:Math.max(1,o-a),height:Math.max(1,c-l)}}function Ur(t,e,n){const s=n==="compact"?48:72,a=Math.max(360,e.width-s*2),o=Math.max(280,e.height-s*2),l=Qs(Math.min(a/Math.max(t.width,1),o/Math.max(t.height,1)),od,rd),c=t.minX+t.width/2,p=t.minY+t.height/2;return{zoom:l,panX:e.width/2-c*l,panY:e.height/2-p*l}}function Wg(t,e){const n=(t.x+e.x)/2,s=e.y>=t.y?32:-32;return`M ${t.x} ${t.y} C ${n} ${t.y+s}, ${n} ${e.y-s}, ${e.x} ${e.y}`}function Hr(t,e,n){if(t==="command"){if(e){le(e),ot("command",{...Vo(e),...n});return}ot("command",n);return}if(t==="intervene"){ot("intervene",n);return}ot("command",n)}function Gg({signalNodes:t,roomPoint:e,onSelect:n}){return!e||t.length===0?null:i`
    ${t.map(({signalNode:s,x:a,y:o})=>i`
      <g
        key=${s.id}
        data-orchestra-signal="true"
        class=${`orchestra-signal-node ${L(s.tone)}`}
        onClick=${()=>n(s.id)}
      >
        <title>${s.label}${s.detail?` — ${s.detail}`:""}</title>
        <line x1=${e.x} y1=${e.y} x2=${a} y2=${o} class="orchestra-signal-link" />
        <circle cx=${a} cy=${o} r="16" class="orchestra-signal-dot" />
        <text x=${a} y=${o+4} text-anchor="middle" class="orchestra-signal-glyph">!</text>
      </g>
    `)}
  `}function Jg({edges:t,positions:e,selectedId:n}){return i`
    ${t.map(s=>{const a=e.get(s.source),o=e.get(s.target);if(!a||!o)return null;const l=n!=null&&(s.source===n||s.target===n);return i`
        <path
          key=${s.id}
          d=${Wg(a,o)}
          class=${`orchestra-edge ${L(s.tone)} ${s.animated?"animated":""} ${l?"active":""}`}
        />
      `})}
  `}function Yg({orchestra:t,positions:e,density:n,selectedId:s,onSelect:a}){var l;const o=((l=t.focus)==null?void 0:l.target_kind)==="node"?t.focus.target_id:null;return i`
    ${t.nodes.map(c=>{const p=e.get(c.id);if(!p)return null;const m=cd(c,n),u=c.id===s,v=c.id===o,f=c.visual_class??c.kind,$=wg(c,n),C=Fg(c,n),b=Kg(c,n);if(c.kind==="room")return i`
          <g
            key=${c.id}
            data-orchestra-node="true"
            class=${`orchestra-node room ${L(c.tone)} ${u?"selected":""} ${v?"focused":""}`}
            onClick=${()=>a(c.id)}
          >
            <title>${c.label}</title>
            <circle cx=${p.x} cy=${p.y} r=${m.radius} class="orchestra-room-ring outer" />
            <circle cx=${p.x} cy=${p.y} r=${m.radius-16} class="orchestra-room-ring inner" />
            <text x=${p.x} y=${p.y-10} text-anchor="middle" class="orchestra-room-glyph">${c.glyph??"◎"}</text>
            <text x=${p.x} y=${p.y+22} text-anchor="middle" class="orchestra-room-label">${$}</text>
          </g>
        `;const k=p.x-m.width/2,h=p.y-m.height/2;return i`
        <g
          key=${c.id}
          data-orchestra-node="true"
          class=${`orchestra-node ${f} ${L(c.tone)} ${u?"selected":""} ${v?"focused":""}`}
          onClick=${()=>a(c.id)}
        >
          <title>${c.label}${c.subtitle?` — ${c.subtitle}`:""}${c.status?` (${c.status})`:""}</title>
          <rect x=${k} y=${h} width=${m.width} height=${m.height} rx=${m.radius} class="orchestra-node-body" />
          <text x=${k+16} y=${h+24} class="orchestra-node-glyph">${c.glyph??"•"}</text>
          <text x=${k+38} y=${h+24} class="orchestra-node-label">${$}</text>
          ${C?i`<text x=${k+38} y=${h+42} class="orchestra-node-subtitle">${C}</text>`:null}
          ${b?i`<text x=${k+m.width-10} y=${h+18} text-anchor="end" class="orchestra-node-status">${b}</text>`:null}
        </g>
      `})}
  `}function dd(t){var s,a;const e=xe.value;if(e){const o=t.nodes.find(c=>c.id===e);if(o)return{type:"node",value:o};const l=t.signals.find(c=>c.id===e);if(l)return{type:"signal",value:l}}if(((s=t.focus)==null?void 0:s.target_kind)==="node"){const o=t.nodes.find(l=>{var c;return l.id===((c=t.focus)==null?void 0:c.target_id)});if(o)return{type:"node",value:o}}if(((a=t.focus)==null?void 0:a.target_kind)==="signal"){const o=t.signals.find(l=>{var c;return l.id===((c=t.focus)==null?void 0:c.target_id)});if(o)return{type:"signal",value:o}}const n=t.nodes[0];return n?{type:"node",value:n}:null}function Xg({orchestra:t}){const e=dd(t);if(!e)return i`<aside class="orchestra-drawer card"><div class="empty-state">선택 가능한 대상이 아직 없습니다.</div></aside>`;if(e.type==="signal"){const o=e.value;return i`
      <aside class="orchestra-drawer card ${L(o.tone)}">
        <div class="card-title-row">
          <div class="card-title">${o.label}</div>
          <span class="command-chip ${L(o.tone)}">${Br(o.kind)}</span>
        </div>
        <p>${o.detail??"세부 설명이 없습니다."}</p>
        ${o.suggested_surface?i`
              <div class="command-action-row">
                <button
                  class="control-btn"
                  onClick=${()=>Hr("command",o.suggested_surface,o.suggested_params??{})}
                >
                  추천 화면 열기
                </button>
              </div>
            `:null}
      </aside>
    `}const n=e.value,s=t.signals.filter(o=>o.source_id===n.id||o.target_id===n.id),a=t.edges.filter(o=>o.source===n.id||o.target===n.id);return i`
    <aside class="orchestra-drawer card ${L(n.tone)}">
      <div class="card-title-row">
        <div class="card-title">${n.label}</div>
        <span class="command-chip ${L(n.tone)}">${Br(n.kind)}</span>
      </div>
      ${n.subtitle?i`<p class="command-card-sub">${n.subtitle}</p>`:null}
      <div class="orchestra-fact-list">
        ${n.facts.map(o=>i`
          <div class="orchestra-fact-row">
            <span>${o.label}</span>
            <strong>${o.value}</strong>
          </div>
        `)}
      </div>
      ${s.length>0?i`
        <div class="command-tag-row">
          ${s.map(o=>i`<span class="command-chip ${L(o.tone)}">${o.label}</span>`)}
        </div>
      `:null}
      <div class="command-card-sub">연결 ${a.length}개 · 근거 ${n.provenance}</div>
      ${n.link_tab&&(n.link_surface||Object.keys(n.link_params??{}).length>0)?i`
            <div class="command-action-row">
              <button
                class="control-btn"
                onClick=${()=>Hr(n.link_tab??"command",n.link_surface,n.link_params??{})}
              >
                이 화면 열기
              </button>
            </div>
          `:null}
    </aside>
  `}function Vg(){var G,V,it,z;const t=qo.value,e=An(null),n=An(null),s=An(""),[a,o]=qn(Cn);if(nt(()=>{const T=e.current;if(!T)return;const A=()=>{const at=T.getBoundingClientRect();at.width<=0||at.height<=0||o({width:Math.max(640,Math.round(at.width)),height:Math.max(480,Math.round(at.height))})};if(A(),typeof ResizeObserver>"u")return window.addEventListener("resize",A),()=>window.removeEventListener("resize",A);const Q=new ResizeObserver(()=>A());return Q.observe(T),()=>Q.disconnect()},[]),io.value&&!t)return i`<section class="card command-section"><div class="empty-state">오케스트라 맵 불러오는 중…</div></section>`;if(Ca.value)return i`<section class="card command-section"><div class="empty-state error">${Ca.value}</div></section>`;if(!t)return i`<section class="card command-section"><div class="empty-state">오케스트라 맵 데이터가 아직 없습니다.</div></section>`;const l=Ms.value,c=Bg(t,l),p=t.nodes.find(T=>T.kind==="room")??null,m=p?c.get(p.id)??null:null,u=Ug(t,m,l),v=Hg(t,c,u,l),f=dd(t),$=(f==null?void 0:f.value.id)??null,C=`${l}:${a.width}x${a.height}:${t.nodes.length}:${t.edges.length}:${t.signals.length}`,b=(T,A)=>{Zt.value=T,Es.value=A},k=()=>{b(Ur(v,a,l),!1)},h=()=>{if(xe.value=null,l!=="compact"){Ms.value="compact",Es.value=!1;return}k()};nt(()=>{$&&!t.nodes.some(T=>T.id===$)&&!t.signals.some(T=>T.id===$)&&(xe.value=null)},[C,$,t]),nt(()=>{(!Es.value||s.current!==C)&&(b(Ur(v,a,l),!1),s.current=C)},[C]);const S=Zt.value,E=(T,A,Q)=>{const at=Zt.value.zoom,J=Qs(at*Q,od,rd);if(Math.abs(J-at)<.001)return;const Bt=(T-Zt.value.panX)/at,B=(A-Zt.value.panY)/at;b({zoom:J,panX:T-Bt*J,panY:A-B*J},!0)},M=T=>{T.preventDefault();const A=e.current;if(!A)return;const Q=A.getBoundingClientRect(),at=Qs(T.clientX-Q.left,0,Q.width),J=Qs(T.clientY-Q.top,0,Q.height);E(at,J,T.deltaY<0?1.1:.92)},P=T=>{var at;const A=T.target;if(!(A instanceof Element)||!A.closest('[data-orchestra-background="true"]'))return;const Q=T.currentTarget;Q&&(n.current={pointerId:T.pointerId,startX:T.clientX,startY:T.clientY,panX:Zt.value.panX,panY:Zt.value.panY},_i.value=!0,Es.value=!0,(at=Q.setPointerCapture)==null||at.call(Q,T.pointerId))},W=T=>{const A=n.current;!A||A.pointerId!==T.pointerId||b({zoom:Zt.value.zoom,panX:A.panX+(T.clientX-A.startX),panY:A.panY+(T.clientY-A.startY)},!0)},I=T=>{var Q;if(!n.current)return;const A=T==null?void 0:T.currentTarget;A&&T&&((Q=A.releasePointerCapture)==null||Q.call(A,T.pointerId)),n.current=null,_i.value=!1};return i`
    <section class="card command-section orchestra-surface">
      <div class="card-title-row">
        <div class="card-title">오케스트라 맵</div>
        <${w} panelId="command.orchestra" compact=${!0} />
      </div>
      <p class="command-card-sub">
        룸 전체를 한 장의 작전판으로 읽는 시각화입니다. 확대/이동으로 밀집 구간을 읽고, 노드를 눌러 상세 신호와 연결 대상을 확인합니다.
      </p>

      <div class="orchestra-toolbar">
        <div class="orchestra-toolbar-group">
          <button class="control-btn ghost" onClick=${k}>맞춤 보기</button>
          <button class="control-btn ghost" onClick=${h}>초기화</button>
        </div>
        <div class="orchestra-toolbar-group">
          <button
            class="control-btn ghost"
            onClick=${()=>E(a.width/2,a.height/2,1.12)}
          >
            확대
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>E(a.width/2,a.height/2,.9)}
          >
            축소
          </button>
          <span class="command-chip">${Math.round(S.zoom*100)}%</span>
        </div>
        <div class="orchestra-toolbar-group">
          <button
            class=${`control-btn ${l==="balanced"?"is-active":"ghost"}`}
            onClick=${()=>{Ms.value="balanced",xe.value=$}}
          >
            균형
          </button>
          <button
            class=${`control-btn ${l==="compact"?"is-active":"ghost"}`}
            onClick=${()=>{Ms.value="compact",xe.value=$}}
          >
            집약
          </button>
          <span class="command-chip">${Dg(l)}</span>
        </div>
      </div>

      <div class="orchestra-shell">
        <div
          ref=${e}
          class="orchestra-canvas-wrap"
          onWheel=${M}
          onPointerDown=${P}
          onPointerMove=${W}
          onPointerUp=${I}
          onPointerCancel=${I}
          onPointerLeave=${()=>I()}
        >
          <svg
            class=${`orchestra-canvas ${_i.value?"is-dragging":""}`}
            viewBox=${`0 0 ${a.width} ${a.height}`}
            preserveAspectRatio="xMidYMid meet"
          >
            <defs>
              <pattern id="orchestra-grid" width="32" height="32" patternUnits="userSpaceOnUse">
                <path d="M 32 0 L 0 0 0 32" fill="none" class="orchestra-grid-line"></path>
              </pattern>
            </defs>
            <rect
              data-orchestra-background="true"
              width=${a.width}
              height=${a.height}
              fill="url(#orchestra-grid)"
              class="orchestra-grid"
            ></rect>
            <g transform=${`translate(${S.panX} ${S.panY}) scale(${S.zoom})`}>
              <${Jg} edges=${t.edges} positions=${c} selectedId=${$} />
              <${Gg} signalNodes=${u} roomPoint=${m} onSelect=${T=>{xe.value=T}} />
              <${Yg}
                orchestra=${t}
                positions=${c}
                density=${l}
                selectedId=${$}
                onSelect=${T=>{xe.value=T}}
              />
            </g>
          </svg>
          <div class="orchestra-summary-strip">
            <span class="command-chip">세션 ${((G=t.summary)==null?void 0:G.session_count)??0}</span>
            <span class="command-chip">워커 ${((V=t.summary)==null?void 0:V.worker_count)??0}</span>
            <span class="command-chip">키퍼 ${((it=t.summary)==null?void 0:it.keeper_count)??0}</span>
            <span class="command-chip ${L(t.signals.some(T=>T.tone==="bad")?"bad":t.signals.length>0?"warn":"ok")}">
              신호 ${((z=t.summary)==null?void 0:z.signal_count)??t.signals.length}
            </span>
            <span class="command-chip">갱신 ${et(t.generated_at)}</span>
          </div>
        </div>

        <${Xg} orchestra=${t} />
      </div>
    </section>
  `}const ud="masc_dashboard_agent_name";function Qg(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(ud))==null?void 0:s.trim())||"dashboard"}const ei=g(Qg()),sn=g(""),Pa=g("운영 점검"),an=g(""),Jn=g(""),Yn=g("2"),cn=g(""),yt=g("note"),Xn=g(""),Vn=g(""),Qn=g(""),Zn=g("2"),ts=g(""),za=g("운영자 중지 요청"),uo=g(""),Zg=g(""),Ps=g(null);function t$(t){const e=t.trim()||"dashboard";ei.value=e,localStorage.setItem(ud,e)}function Na(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function er(t){switch((t??"").trim().toLowerCase()){case"judgment":return"상주 판단";case"fallback":return"보조 읽기 모델";default:return(t==null?void 0:t.trim())||"안내"}}function ja(t){switch((t??"").trim().toLowerCase()){case"judgment":return"ok";case"fallback":return"warn";default:return"warn"}}function nr(t){return t!=null&&t.enabled?t.refreshing?"갱신 중":t.judge_online?"온라인":t.last_error?"오류":"대기":"꺼짐"}function e$(t){return t!=null&&t.enabled?t.judge_online?"ok":t.refreshing?"warn":"bad":"warn"}function sr(t){return t!=null&&t.fresh_until?t.fresh_until:"갱신 기준 없음"}function Wr(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function dn(t){return typeof t=="string"?t.trim().toLowerCase():""}function n$(t){var s;const e=dn(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=dn((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function vi(t){const e=dn(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function Gr(t){return t.some(e=>dn(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function s$(t){return t.target_type==="team_session"}function a$(t){return t.target_type==="keeper"}function Pe(t){switch(t){case"broadcast":return"방송";case"room_pause":return"방 일시정지";case"room_resume":return"방 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"team_worker_spawn_batch":return"세션 작업자 교체";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"키퍼 메시지";case"keeper_msg":return"키퍼 메시지";case"swarm_run_continue":return"스웜 실행 계속";case"swarm_run_rerun":return"스웜 실행 재실행";case"swarm_run_abandon":return"스웜 실행 포기";default:return(t==null?void 0:t.trim())||"액션"}}function on(t){switch(t){case"room":return"방";case"team_session":return"세션";case"keeper":return"키퍼";case"swarm_run":return"스웜 실행";default:return(t==null?void 0:t.trim())||"대상"}}function We(t){switch(dn(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Oa(t){return t?"확인 후 실행":"즉시 실행"}function i$(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"worker_spawn_batch":return"작업자 교체";default:return t}}function mt(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function o$(t){return!t||typeof t!="object"||Array.isArray(t)?null:t}function r$(t){if(!t)return"";const e=t.spawn_batch;return Na(e!==void 0?e:t)}function pd(t){const e=o$(t.payload);if(t.target_type==="room"){if(t.action_type==="broadcast"){sn.value=mt(e,"message")??t.summary;return}if(t.action_type==="task_inject"){an.value=mt(e,"title")??"운영자 주입 작업",Jn.value=mt(e,"description")??t.summary,Yn.value=mt(e,"priority")??Yn.value;return}t.action_type==="room_pause"&&(Pa.value=mt(e,"reason")??t.summary);return}if(t.target_type==="team_session"){if(t.target_id&&(cn.value=t.target_id),t.action_type==="team_stop"){za.value=mt(e,"reason")??t.summary;return}yt.value=t.action_type==="team_worker_spawn_batch"?"worker_spawn_batch":t.action_type==="team_task_inject"?"task":t.action_type==="team_broadcast"?"broadcast":"note";const n=mt(e,"message");if(n&&(Xn.value=n),yt.value==="worker_spawn_batch"){ts.value=r$(e);return}yt.value==="task"&&(Vn.value=mt(e,"task_title")??mt(e,"title")??"운영자 주입 작업",Qn.value=mt(e,"task_description")??mt(e,"description")??t.summary,Zn.value=mt(e,"task_priority")??mt(e,"priority")??Zn.value);return}t.target_type==="keeper"&&(t.target_id&&(uo.value=t.target_id),Zg.value=mt(e,"message")??t.summary)}function l$(t){pd({action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.suggested_payload,summary:t.summary})}function c$(t){pd({action_type:t.action_type,target_type:t.target_type,target_id:t.target_id??null,payload:t.suggested_payload,summary:t.reason}),j("추천 액션 payload를 폼에 채웠습니다","success")}function d$(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function Ne(t){const e=ei.value.trim()||"dashboard";try{const n=await lc({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?j("확인 대기열에 올렸습니다","warning"):j(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return j(s,"error"),null}}async function Jr(){const t=sn.value.trim();if(!t)return;await Ne({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(sn.value="")}async function u$(){await Ne({action_type:"room_pause",target_type:"room",payload:{reason:Pa.value.trim()||"운영 점검"},successMessage:"방 일시정지를 요청했습니다"})}async function md(){await Ne({action_type:"room_resume",target_type:"room",payload:{},successMessage:"방 재개를 요청했습니다"})}async function p$(){const t=an.value.trim();if(!t)return;await Ne({action_type:"task_inject",target_type:"room",payload:{title:t,description:Jn.value.trim()||"개입 화면에서 주입",priority:Number.parseInt(Yn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(an.value="",Jn.value="")}async function m$(){var l;const t=Mt.value,e=cn.value||((l=t==null?void 0:t.sessions[0])==null?void 0:l.session_id)||"";if(!e){j("먼저 세션을 고르세요","warning");return}const n={};if(yt.value==="worker_spawn_batch"){const c=ts.value.trim();if(!c){j("spawn_batch JSON을 먼저 채우세요","warning");return}try{const m=JSON.parse(c);if(Array.isArray(m))n.spawn_batch=m;else if(m&&typeof m=="object"&&Array.isArray(m.spawn_batch))n.spawn_batch=m.spawn_batch;else{j("spawn_batch는 배열 또는 { spawn_batch: [...] } 형태여야 합니다","warning");return}}catch(m){const u=m instanceof Error?m.message:"spawn_batch JSON 파싱에 실패했습니다";j(u,"error");return}await Ne({action_type:"team_worker_spawn_batch",target_type:"team_session",target_id:e,payload:n,successMessage:"작업자 교체 요청을 적용했습니다"})&&(ts.value="");return}const s=Xn.value.trim();s&&(n.message=s);let a="team_note";yt.value==="broadcast"?a="team_broadcast":yt.value==="task"&&(a="team_task_inject"),yt.value==="task"&&(n.task_title=Vn.value.trim()||"운영자 주입 작업",n.task_description=Qn.value.trim()||"개입 화면에서 주입",n.task_priority=Number.parseInt(Zn.value,10)||2),await Ne({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Xn.value="",yt.value==="task"&&(Vn.value="",Qn.value=""))}async function _$(){var n;const t=Mt.value,e=cn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){j("먼저 세션을 고르세요","warning");return}await Ne({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:za.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Yr(t,e="confirm"){const n=ei.value.trim()||"dashboard";try{await cc(n,t,e),j(e==="deny"?"승인 대기를 거부했습니다":"확인 실행을 완료했습니다","success")}catch(s){const a=s instanceof Error?s.message:e==="deny"?"승인 대기 거부에 실패했습니다":"확인 실행에 실패했습니다";j(a,"error")}}function _d(t){switch(t){case"explicit":return"실제 관리 단위";case"hybrid":return"관리 단위 + 자동 보강";case"auto":return"자동 투영";default:return"출처 미상"}}function vd(t){switch(t){case"explicit":return"ok";case"hybrid":return"warn";case"auto":return"warn";default:return"warn"}}function v$(t){switch(t){case"explicit":return"지금 보이는 유닛은 실제로 정의된 지휘면 관리 단위입니다.";case"hybrid":return"일부는 실제 관리 단위이고, 비어 있는 부분은 실시간 에이전트 편성을 보고 자동 보강한 구조입니다.";case"auto":return"이 화면은 실시간 에이전트 편성을 지휘면 모양으로 자동 투영한 것입니다. 실제 명령 체계와 1:1로 같다고 보면 안 됩니다.";default:return"이 화면은 관리 토폴로지와 실효 토폴로지가 섞여 있을 수 있습니다."}}function f$(t){const e=t.unit.source??"unknown";return e==="explicit"?t.active_operation_count&&t.active_operation_count>0?"실제 관리 단위이며 연결된 작전이 있습니다.":"실제 관리 단위이지만 현재 연결된 작전은 없습니다.":e==="hybrid"?t.active_operation_count&&t.active_operation_count>0?"관리 단위를 기반으로 자동 보강된 구조이며 일부 작전이 연결돼 있습니다.":"관리 단위를 기반으로 자동 보강된 구조이며 현재 실행 연결은 약합니다.":t.active_operation_count&&t.active_operation_count>0?"자동 생성된 구조이지만 이 노드에 연결된 작전 흔적은 있습니다.":"자동 생성된 구조이며 현재 실행 연결은 없습니다."}function fd({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,o=t.unit.policy,l=t.unit.source??"unknown",c=a>0?`${a}개 작전 연결`:"실행 연결 없음";return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${eg(t.unit.kind)}</span>
            <span class="command-chip ${L(t.health)}">${t.health??"ok"}</span>
            <span class="command-chip ${vd(l)}">${_d(l)}</span>
            <span class="command-chip ${a>0?"ok":"warn"}">${c}</span>
            ${o!=null&&o.frozen?i`<span class="command-chip warn">동결됨</span>`:null}
            ${o!=null&&o.kill_switch?i`<span class="command-chip bad">킬 스위치</span>`:null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${t.unit.unit_id}</span>
            <span>리더 ${t.unit.leader_id??"미지정"} / ${t.leader_status??"확인 필요"}</span>
            <span>편성 ${n}/${s}</span>
            <span>작전 ${a}</span>
            <span>자율성 ${(o==null?void 0:o.autonomy_level)??"정보 없음"}</span>
          </div>
          <div class="command-card-sub">${f$(t)}</div>
          ${t.reasons&&t.reasons.length>0?i`<div class="command-tag-row">
                ${t.reasons.map(p=>i`<span class="command-tag warn">${p}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?i`<div class="command-tree-children">
            ${t.children.map(p=>i`<${fd} node=${p} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function g$({alert:t}){return i`
    <article class="command-alert ${L(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${L(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"범위"}:${t.scope_id??"정보 없음"}</span>
        <span>${et(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function ar({event:t}){return i`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${et(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${La(t.detail)}</pre>
    </article>
  `}function $$(){const t=Kt.value,e=t==null?void 0:t.topology,n=e==null?void 0:e.source,s=e==null?void 0:e.summary,a=(s==null?void 0:s.managed_unit_count)??0,o=(s==null?void 0:s.active_operation_count)??0;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${w} panelId="command.topology" compact=${!0} />
      </div>
      ${t?i`
            <div class="command-topology-explainer">
              <div class="command-tree-title-row">
                <span class="command-chip ${vd(n)}">${_d(n)}</span>
                <span class="command-chip">관리 유닛 ${a}</span>
                <span class="command-chip ${o>0?"ok":"warn"}">활성 작전 ${o}</span>
              </div>
              <p>${v$(n)}</p>
            </div>
          `:null}
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(l=>i`<${fd} node=${l} />`)}`:i`<div class="empty-state">지금은 실시간 에이전트나 관리 유닛 기준으로 그릴 지휘 계층이 없습니다.</div>`}
    </section>
  `}function h$(){const t=Kt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${w} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${g$} alert=${e} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 지휘면 경보는 없습니다.</div>`}
    </section>
  `}function y$(){const t=Kt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${w} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${ar} event=${e} />`)}
          </div>`:i`<div class="empty-state">최근 트레이스 이벤트가 없습니다.</div>`}
    </section>
  `}function b$(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t,null,2)}catch{return String(t)}}function k$(t,e){return(e==null?void 0:e.status)==="abandoned"||(t==null?void 0:t.recommended_kind)==="continue"?"warn":(t==null?void 0:t.recommended_kind)==="rerun"?"bad":"ok"}function x$(t){switch(t){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(t==null?void 0:t.trim())||"결정"}}function S$(t){return t?t.runtime_blocker?"막힘":t.provider_reachable?"준비됨":"확인 필요":"확인 필요"}function gd({swarm:t}){var v,f;const e=t.run_id,n=t.resolution_recommendation,s=t.run_resolution;if(!e||!n&&!s)return null;const a=sd()??"dashboard",o=((v=Mt.value)==null?void 0:v.pending_confirms.find($=>$.target_type==="swarm_run"&&$.target_id===e))??null,l=k$(n,s),c=((f=t.operation)==null?void 0:f.operation_id)??t.operation_id??void 0,p={run_id:e};c&&(p.operation_id=c),n!=null&&n.reason&&(p.reason=n.reason);const m=async $=>{await lc({actor:a,action_type:$,target_type:"swarm_run",target_id:e,payload:p})},u=async $=>{o&&await cc(a,o.confirm_token,$)};return i`
    <article class="command-guide-card ${L(l)}">
      <div class="command-guide-head">
        <strong>런 해석</strong>
        <span class="command-chip ${L(l)}">
          ${x$((s==null?void 0:s.status)??(n==null?void 0:n.recommended_kind)??null)}
        </span>
      </div>
      <p>
        ${(s==null?void 0:s.status)==="abandoned"?`이 run은 ${s.decided_by}가 ${et(s.decided_at)}에 soft abandon 처리했습니다. ${s.reason}`:(n==null?void 0:n.reason)??"이 run에 대한 별도 resolution recommendation은 아직 없습니다."}
      </p>
      <div class="command-card-grid">
        <span>런</span><span>${e}</span>
        <span>근거 경로</span><span>${(n==null?void 0:n.provenance)??"recorded"}</span>
        <span>결정 엔진</span><span>${(n==null?void 0:n.decision_engine)??"operator_record"}</span>
        <span>권위성</span><span>${n!=null&&n.authoritative?"예":"아니오"}</span>
      </div>
      ${n!=null&&n.evidence?i`
            <div class="command-tag-row">
              <span class="command-tag">joined ${n.evidence.joined_workers??0}</span>
              <span class="command-tag">trace ${n.evidence.trace_events??0}</span>
              <span class="command-tag">message ${n.evidence.message_events??0}</span>
              ${n.evidence.runtime_blocker?i`<span class="command-tag ${L("bad")}">${n.evidence.runtime_blocker}</span>`:null}
            </div>
          `:null}
      ${o?i`
            <div class="command-guide-card warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip warn">${o.confirm_token}</span>
              </div>
              ${o.preview?i`<pre class="command-trace-detail">${b$(o.preview)}</pre>`:null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${()=>{u("confirm")}} disabled=${Z.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${()=>{u("deny")}} disabled=${Z.value}>취소</button>
              </div>
            </div>
          `:n?i`
              <div class="command-action-row">
                ${n.continue_available?i`<button class="control-btn ghost" onClick=${()=>{m("swarm_run_continue")}} disabled=${Z.value}>계속</button>`:null}
                ${n.rerun_available?i`<button class="control-btn" onClick=${()=>{m("swarm_run_rerun")}} disabled=${Z.value}>재실행</button>`:null}
                ${n.abandon_available?i`<button class="control-btn ghost" onClick=${()=>{m("swarm_run_abandon")}} disabled=${Z.value}>포기</button>`:null}
              </div>
            `:null}
    </article>
  `}function $d(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function hd({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const o=a.motion_state;o in e?e[o]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return i`
    <div>
      <div class="swarm-health-bar">
        ${s.filter(a=>a.count>0).map(a=>i`
          <div class="swarm-health-seg ${a.key}" style="flex: ${a.count}"></div>
        `)}
      </div>
      <div class="swarm-health-labels">
        ${s.filter(a=>a.count>0).map(a=>i`
          <span class="swarm-health-label">
            <span class="swarm-health-swatch" style="background: ${a.color}"></span>
            ${a.count} ${a.key}
          </span>
        `)}
      </div>
    </div>
  `}function C$({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function A$({lane:t}){const e=t.counts??{},n=$d(t),s=e.workers??0,a=e.operations??0,o=e.detachments??0,l=a+o,c=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return i`
    <article class="swarm-lane-strip ${L(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${L(n)}">${t.phase}</span>
          <span class="command-chip ${L(n)}">${t.motion_state}</span>
          <span class="command-chip">${et(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${L(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${C$} total=${s} />
              </div>
            `:null}
        ${l>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">흐름</span>
                <div class="swarm-mini-bar">
                  <div class="swarm-mini-bar-fill" style="width: ${l>0?Math.round(a/l*100):0}%; background: var(--${n==="bad"?"bad":n==="warn"?"warn":"ok"})"></div>
                </div>
                <span class="swarm-worker-count">작전 ${a} · 실행체 ${o}</span>
              </div>
            `:null}
      </div>
      ${t.blockers.length>0?i`<div class="swarm-lane-blockers">막힘: ${t.blockers.join(" · ")}</div>`:null}
      ${t.hard_flags.length>0?i`
            <div class="swarm-lane-flags">
              ${t.hard_flags.map(p=>i`<span class="command-chip ${L(p.severity)}">${p.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function yd({lanes:t}){const e=t.slice(0,4);return e.length===0?null:i`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=$d(n),a=n.counts.workers??0,o=n.counts.operations??0,l=n.counts.detachments??0;return i`
          <article class="swarm-story-card ${L(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${L(s)}">${n.motion_state}</span>
              <span class="command-chip">${n.phase}</span>
            </div>
            <strong>${n.label}</strong>
            <p>${n.current_step}</p>
            <div class="swarm-story-strip">
              <span>워커 ${a}</span>
              <span>작전 ${o}</span>
              <span>실행체 ${l}</span>
            </div>
            <small>${n.movement_reason}</small>
          </article>
        `})}
    </div>
  `}function T$({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${L(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?i`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function I$({gap:t}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.summary}</strong>
          <div class="command-card-sub">${t.code} · lane ${t.lane_ids.join(", ")||"n/a"}</div>
        </div>
        <span class="command-chip ${L(t.severity)}">${t.count}</span>
      </div>
      ${t.why_it_matters?i`<p>${t.why_it_matters}</p>`:null}
      ${t.next_tool||t.next_step?i`
            <div class="command-card-grid">
              <span>다음 도구</span><span>${t.next_tool??"masc_observe_traces"}</span>
              <span>다음 확인</span><span>${t.next_step??"최근 trace를 확인합니다."}</span>
            </div>
          `:null}
    </article>
  `}function R$({swarm:t}){const e=t==null?void 0:t.narrative;return e?i`
    <div class="command-guide-card highlight">
      <div class="command-guide-head">
        <strong>읽는 순서</strong>
        <span class="command-chip">${e.state??"idle"}</span>
      </div>
      <div class="proof-summary-stack">
        <article class="proof-summary-block">
          <strong>무엇으로 시작됐나</strong>
          <span>${e.started??"시작 근거가 없습니다."}</span>
        </article>
        <article class="proof-summary-block">
          <strong>지금 무엇을 하고 있나</strong>
          <span>${e.active_work??"현재 작업 설명이 없습니다."}</span>
        </article>
        <article class="proof-summary-block">
          <strong>끝났는가</strong>
          <span>${e.completion??"종료 근거가 없습니다."}</span>
        </article>
      </div>
    </div>
  `:null}function M$({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${L(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${L(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?i`
            <p>${t.status_summary??t.missing_reason??"아직 스웜 증거가 수집되지 않았습니다."}</p>
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>상태 코드</span><span>${t.reason_code??"n/a"}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${et(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.expected_artifact_dir?i`<div class="command-card-foot">expected ${t.expected_artifact_dir}</div>`:null}
            ${t.artifact_ref?i`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?i`<p>${t.missing_reason}</p>`:null}
          `:i`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function E$(){const t=vs(),e=us(D.value),n=ag(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,o=(s==null?void 0:s.lanes.filter(v=>v.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],p=s==null?void 0:s.overview,m=s==null?void 0:s.recommended_next_action,u=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${w} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${yd} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(p==null?void 0:p.active_lanes)??0}</strong><small>${(p==null?void 0:p.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(p==null?void 0:p.stalled_lanes)??0}</strong><small>${(p==null?void 0:p.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${et(p==null?void 0:p.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${et(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${hd} lanes=${o} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(v=>i`<${A$} lane=${v} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <${R$} swarm=${s} />

                <div class="command-guide-card highlight ${n==="recommendation"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(m==null?void 0:m.lane_id)??"전체"}</span>
                  </div>
                  <p>${(m==null?void 0:m.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${M$} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${L(l.some(v=>v.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?i`<div class="command-card-stack">${l.slice(0,4).map(v=>i`<${I$} gap=${v} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?i`<div class="swarm-event-rail">${c.map(v=>i`<${T$} event=${v} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function L$({item:t}){return i`
    <article class="command-guide-card ${L(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${L(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function bd({blocker:t}){return i`
    <article class="command-alert ${L(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${L(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function P$({worker:t}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${L(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
          ${t.status}
        </span>
      </div>
      <div class="command-card-grid">
        <span>Joined</span><span>${t.joined?"yes":"no"}</span>
        <span>Live</span><span>${t.live_presence?"yes":"no"}</span>
        <span>Completed</span><span>${t.completed?"yes":"no"}</span>
        <span>Task</span><span>${t.current_task??t.bound_task_id??"none"}</span>
        <span>Task Title</span><span>${t.bound_task_title??"n/a"}</span>
        <span>Task Status</span><span>${t.bound_task_status??"n/a"}</span>
        <span>Heartbeat</span><span>${t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}s`:t.heartbeat_fresh?"completed-cleanly":"n/a"}</span>
        <span>Squad</span><span>${t.squad_member?"yes":"no"}</span>
        <span>Detachment</span><span>${t.detachment_member?"yes":"no"}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${t.lane}</span>
        <span class="command-tag ${t.current_task_matches_run?"ok":"warn"}">current_task</span>
        <span class="command-tag ${t.claim_marker_seen?"ok":"warn"}">claim</span>
        <span class="command-tag ${t.done_marker_seen?"ok":"warn"}">done</span>
        <span class="command-tag ${t.final_marker_seen?"ok":"warn"}">final</span>
      </div>
      ${t.last_message?i`<div class="command-card-foot">${et(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function z$(){var u,v,f,$,C,b,k,h,S,E,M,P,W,I,G,V,it,z,T,A,Q,at;const t=Oe.value,e=id(),n=Qo(),s=S$(t==null?void 0:t.provider),a=((u=t==null?void 0:t.provider)==null?void 0:u.configured_capacity)??0,o=((v=t==null?void 0:t.provider)==null?void 0:v.actual_slots)??((f=t==null?void 0:t.provider)==null?void 0:f.total_slots)??0,l=(($=t==null?void 0:t.provider)==null?void 0:$.expected_slots)??"n/a",c=((C=t==null?void 0:t.provider)==null?void 0:C.actual_ctx)??((b=t==null?void 0:t.provider)==null?void 0:b.ctx_per_slot)??0,p=((k=t==null?void 0:t.provider)==null?void 0:k.expected_ctx)??"n/a",m=((h=t==null?void 0:t.summary)==null?void 0:h.peak_hot_slots)??((S=t==null?void 0:t.provider)==null?void 0:S.peak_active_slots)??0;return i`
    <div class="command-section-stack">
      <${E$} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${w} panelId="command.swarm" compact=${!0} />
          </div>
          ${xa.value?i`<div class="empty-state">Loading swarm live state…</div>`:Sa.value?i`<div class="empty-state error">${Sa.value}</div>`:t?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((E=t.summary)==null?void 0:E.joined_workers)??0}/${((M=t.summary)==null?void 0:M.expected_workers)??0}</strong><small>${((P=t.summary)==null?void 0:P.live_workers)??0}개 가동 · ${((W=t.summary)==null?void 0:W.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임 계약</span><strong>${s}</strong><small>설정 ${a||"n/a"} · 실제 ${o}/${l} · ctx ${c}/${p}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(I=t.summary)!=null&&I.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>최대 hot ${m} · ${((G=t.provider)==null?void 0:G.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(V=t.summary)!=null&&V.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((it=t.operation)==null?void 0:it.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((z=t.squad)==null?void 0:z.label)??"없음"}</span>
                      <span>실행체</span><span>${((T=t.detachment)==null?void 0:T.detachment_id)??"없음"}</span>
                      <span>목표 해석</span><span>target profile 기준, 달성 사실과 분리</span>
                      <span>예상 워커</span><span>${((A=t.summary)==null?void 0:A.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((Q=t.summary)==null?void 0:Q.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((at=t.provider)==null?void 0:at.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?i`<div class="command-tag-row">
                          ${t.truth_notes.map(J=>i`<span class="command-tag">${J}</span>`)}
                        </div>`:null}
                    <${gd} swarm=${t} />
                  `:i`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${w} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?i`<div class="command-card-stack">
                ${t.checklist.map(J=>i`<${L$} item=${J} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${w} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?i`<div class="command-card-stack">
                ${t.workers.map(J=>i`<${P$} worker=${J} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${w} panelId="command.swarm" compact=${!0} />
          </div>
          ${t!=null&&t.provider?i`
                <div class="command-card-grid">
                  <span>프로바이더</span><span>${t.provider.provider_base_url??"정보 없음"}</span>
                  <span>프로바이더 응답</span><span>${t.provider.provider_reachable==null?"정보 없음":t.provider.provider_reachable?"가능":"불가"}</span>
                  <span>요청 모델</span><span>${t.provider.provider_model_id??"정보 없음"}</span>
                  <span>실제 모델</span><span>${t.provider.actual_model_id??"정보 없음"}</span>
                  <span>슬롯 URL</span><span>${t.provider.slot_url??"정보 없음"}</span>
                  <span>설정 용량</span><span>${t.provider.configured_capacity??"정보 없음"}</span>
                  <span>요구 슬롯</span><span>${t.provider.expected_slots??"정보 없음"}</span>
                  <span>실제 슬롯</span><span>${t.provider.actual_slots??t.provider.total_slots??0}</span>
                  <span>요구 컨텍스트</span><span>${t.provider.expected_ctx??"정보 없음"}</span>
                  <span>실제 컨텍스트</span><span>${t.provider.actual_ctx??t.provider.ctx_per_slot??0}</span>
                  <span>현재 hot</span><span>${t.provider.active_slots_now??0}</span>
                  <span>최대 hot</span><span>${t.provider.peak_active_slots??0}</span>
                  <span>샘플 수</span><span>${t.provider.sample_count??0}</span>
                  <span>마지막 샘플</span><span>${t.provider.last_sample_at?et(t.provider.last_sample_at):"정보 없음"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"없음"}</span>
                  <span>검사 시각</span><span>${t.provider.checked_at?et(t.provider.checked_at):"정보 없음"}</span>
                </div>
                <div class="command-card-sub">
                  target profile과 실제 런타임은 다를 수 있습니다. 설정 용량, 실제 슬롯, 최대 hot 슬롯을 분리해서 읽으세요.
                </div>
                ${t.provider.detail?i`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?i`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(J=>i`
                          <article class="command-trace-row">
                            <div class="command-trace-main">
                              <div class="command-trace-head">
                                <strong>hot ${J.active_slots}</strong>
                                <span class="command-chip">${et(J.timestamp)}</span>
                              </div>
                            <div class="command-card-sub">slot ids ${J.active_slot_ids.join(", ")||"없음"}</div>
                            </div>
                          </article>
                      `)}
                    </div>`:i`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:i`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${w} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?i`<div class="command-card-stack">
                ${t.blockers.map(J=>i`<${bd} blocker=${J} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${w} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?i`<div class="command-trace-stack">
                ${t.recent_messages.map(J=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${J.from}</strong>
                        <span class="command-chip">${et(J.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${J.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${J.content}</pre>
                  </article>
                `)}
              </div>`:i`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${w} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${t.recent_trace_events.map(J=>i`<${ar} event=${J} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function N$(t){return t==="swarm"?"스웜 실시간":"세션 요약"}function j$(t){switch(t){case"current":return"현재 과업 일치";case"drift":return"과업 드리프트";case"claim":return"착수 흔적 있음";case"no-claim":return"착수 흔적 없음";case"done":return"완료 흔적 있음";case"no-done":return"완료 흔적 없음";case"final":return"최종 보고 있음";case"no-final":return"최종 보고 없음";case"turn":return"턴 기록 있음";case"silent":return"턴 기록 없음";case"noted":return"노트 기록 있음";default:return t.startsWith("empty:")?`빈 노트 ${t.slice(6)}회`:t.startsWith("turns:")?`턴 ${t.slice(6)}회`:t}}function O$(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"할당 없음",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}초`:t.heartbeat_fresh?"정상":"정보 없음",detail:[t.bound_task_status??null,t.detachment_member?"분견대 소속":null,t.squad_member?"분대 소속":null].filter(Boolean).join(" · ")||"스웜 실시간 카드",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function D$(t,e){const n=t.actor??t.spawn_role??`워커-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"워커",a=t.lane_id??t.capsule_mode??t.control_domain??"세션",o=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"세션 레인",heartbeat:t.last_turn_ts_iso?et(t.last_turn_ts_iso):"정보 없음",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?ms(t.routing_confidence):null].filter(Boolean).join(" · ")||"세션 요약 카드",markers:o,note:t.routing_reason??null}}function Xr(t){return L(t.severity)}function q$({worker:t}){return i`
    <article class="command-card compact warroom-worker-card ${L(Ue(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${L(Ue(t.status))}">${ke(t.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>출처</span><span>${N$(t.source)}</span>
        <span>과업</span><span>${t.task}</span>
        <span>최근 신호</span><span>${t.heartbeat}</span>
        <span>근거</span><span>${t.detail}</span>
      </div>
      <div class="command-tag-row">
        ${t.markers.map(e=>i`<span class="command-tag">${j$(e)}</span>`)}
      </div>
      ${t.note?i`<div class="command-card-foot">${t.note}</div>`:null}
    </article>
  `}function te({label:t,surface:e,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){le(e),ot("command",{...Vo(e),...n});return}ot("intervene")}}
    >
      ${t}
    </button>
  `}function w$(){var T,A,Q,at,J,Bt,B,Et,$e,fn,gn,fs,gs,$s,hs,ys,bs,ks,ur,pr,mr;const t=vs(),e=Oe.value,n=Mt.value,s=wt.value,a=ug(),o=e!=null&&e.operation?((T=ds.value)==null?void 0:T.operations.find(tt=>{var xs;return tt.operation.operation_id===((xs=e.operation)==null?void 0:xs.operation_id)}))??null:null,l=cg(),c=(e==null?void 0:e.workers)??[],p=(s==null?void 0:s.worker_cards)??[],m=l&&c.length>0?c.map(O$):p.map(D$),u=l,v=((A=t==null?void 0:t.decisions.summary)==null?void 0:A.pending)??0,f=(n==null?void 0:n.pending_confirms)??[],$=l?(e==null?void 0:e.blockers)??[]:[],C=(s==null?void 0:s.recommended_actions)??[],b=(Q=s==null?void 0:s.active_recommended_actions)!=null&&Q.length?s.active_recommended_actions:C,k=s==null?void 0:s.active_summary,h=(s==null?void 0:s.active_guidance_layer)??"fallback",S=(s==null?void 0:s.resident_judge_runtime)??(n==null?void 0:n.resident_judge_runtime),E=(s==null?void 0:s.attention_items)??[],M=((at=e==null?void 0:e.recent_messages[0])==null?void 0:at.timestamp)??null,P=((J=e==null?void 0:e.recent_trace_events[0])==null?void 0:J.timestamp)??null,W=l?M??P??null:null,I=a==null?void 0:a.summary,G=(l?(Bt=e==null?void 0:e.summary)==null?void 0:Bt.expected_workers:void 0)??(typeof(I==null?void 0:I.planned_worker_count)=="number"?I.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,V=(l?(B=e==null?void 0:e.summary)==null?void 0:B.joined_workers:void 0)??(typeof(I==null?void 0:I.active_agent_count)=="number"?I.active_agent_count:void 0)??m.length,it=$.length>0||v>0||f.length>0?"warn":u||a?"ok":"warn",z=l?((Et=t==null?void 0:t.swarm_status)==null?void 0:Et.lanes.filter(tt=>tt.present))??[]:[];return nt(()=>{bt()},[]),nt(()=>{a!=null&&a.session_id&&ln(a.session_id)},[a==null?void 0:a.session_id,n,($e=e==null?void 0:e.detachment)==null?void 0:$e.session_id]),!u&&!a?xa.value||Kn.value?i`<div class="empty-state">실시간 워룸 불러오는 중…</div>`:i`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">실시간 워룸</div>
          <${w} panelId="command.warroom" compact=${!0} />
        </div>
        <div class="command-warroom-empty-copy">
          <strong>지금 보이는 실시간 실행이 없습니다</strong>
          <p>활성 작전이나 팀 세션이 시작되면 이 화면이 자동으로 붙잡습니다.</p>
        </div>
        <div class="command-action-row">
          <${te} label="작전 보기" surface="operations" />
          <${te} label="스웜 보기" surface="swarm" />
          <${te} label="개입 열기" />
          <${te} label="제어 보기" surface="control" />
        </div>
      </section>
    `:i`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${L(it)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">실시간 워룸</span>
            <strong>${l?((fn=e==null?void 0:e.operation)==null?void 0:fn.objective)??(a==null?void 0:a.session_id)??"가동 중인 실행":(a==null?void 0:a.session_id)??"가동 중인 실행"}</strong>
            <div class="command-card-sub">
              ${l?((gn=e==null?void 0:e.operation)==null?void 0:gn.operation_id)??"작전 정보 없음":"세션 기준값"}
              ${a!=null&&a.session_id?` · 세션 ${a.session_id}`:""}
              ${l&&((fs=e==null?void 0:e.detachment)!=null&&fs.detachment_id)?` · 분견대 ${e.detachment.detachment_id}`:""}
            </div>
            ${k!=null&&k.summary?i`<div class="command-warroom-guidance ${ja(h)}">
                  <strong>${er(h)}</strong>
                  <span>${k.summary}</span>
                </div>`:null}
          </div>
          <div class="command-action-row">
            <${te}
              label="스웜 상세"
              surface="swarm"
              params=${{...l&&((gs=e==null?void 0:e.operation)!=null&&gs.operation_id)?{operation_id:e.operation.operation_id}:{},...l&&(e!=null&&e.run_id)?{run_id:e.run_id}:{}}}
            />
            <${te} label="트레이스" surface="trace" />
            ${l&&o?i`<${te}
                  label="체인"
                  surface="chains"
                  params=${{operation:o.operation.operation_id}}
                />`:null}
            <${te} label="개입" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>워커</span>
            <strong>${V??0}/${G??0}</strong>
            <small>${l?(($s=e==null?void 0:e.summary)==null?void 0:$s.completed_workers)??0:0} 완료 · ${m.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>런타임</span>
            <strong>${l?(hs=e==null?void 0:e.provider)!=null&&hs.runtime_blocker?"막힘":(ys=e==null?void 0:e.provider)!=null&&ys.provider_reachable?"준비됨":a?ke(a.status):"확인 필요":a?ke(a.status):"확인 필요"}</strong>
            <small>${l?`설정 ${((bs=e==null?void 0:e.provider)==null?void 0:bs.configured_capacity)??"n/a"} · 실제 ${((ks=e==null?void 0:e.provider)==null?void 0:ks.actual_slots)??((ur=e==null?void 0:e.provider)==null?void 0:ur.total_slots)??0} · hot ${((pr=e==null?void 0:e.summary)==null?void 0:pr.peak_hot_slots)??((mr=e==null?void 0:e.provider)==null?void 0:mr.peak_active_slots)??0}`:`세션 워커 ${(s==null?void 0:s.worker_cards.length)??0}`}</small>
          </div>
          <div class="monitor-stat-card ${L($.length>0||v>0?"warn":"ok")}">
            <span>압력</span>
            <strong>${$.length+v+f.length}</strong>
            <small>막힘 ${$.length} · 승인 ${v} · 확인 ${f.length}</small>
          </div>
          <div class="monitor-stat-card ${L(ja(h))}">
            <span>상주 판정기</span>
            <strong>${nr(S)}</strong>
            <small>${sr(k)}${S!=null&&S.model_used?` · ${S.model_used}`:""}</small>
          </div>
          <div class="monitor-stat-card">
            <span>마지막 신호</span>
            <strong>${et(W)}</strong>
            <small>${M?"메시지":P?"트레이스":"대기 중"}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${w} panelId="command.warroom" compact=${!0} />
            </div>
            ${z.length>0?i`
                  <${yd} lanes=${z} />
                  <${hd} lanes=${z} />
                `:a?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${L(Ue(a.status))}">${ke(a.status)}</span>
                      </div>
                      <p>스웜 실시간 증거는 아직 약합니다. 이 카드는 세션 요약과 워커 기록을 기준으로 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${Sn(a.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${Sn(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 레인이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">워커 현황</div>
              <${w} panelId="command.warroom" compact=${!0} />
            </div>
            ${m.length>0?i`<div class="command-card-stack">
                  ${m.map(tt=>i`<${q$} worker=${tt} />`)}
                </div>`:i`<div class="empty-state">활성 워커 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">상황 피드</div>
              <${w} panelId="command.warroom" compact=${!0} />
            </div>
            ${e&&e.recent_messages.length>0&&l?i`<div class="command-trace-stack">
                  ${e.recent_messages.map(tt=>i`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${tt.from}</strong>
                          <span class="command-chip">${et(tt.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${tt.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${tt.content}</pre>
                    </article>
                  `)}
                </div>`:b.length>0||E.length>0?i`<div class="command-card-stack">
                    ${b.slice(0,4).map(tt=>i`
                      <article class="command-guide-card ${Xr(tt)}">
                        <div class="command-guide-head">
                          <strong>${tt.action_type}</strong>
                          <span class="command-chip ${Xr(tt)}">${tt.target_type}</span>
                        </div>
                        <p>${tt.reason}</p>
                      </article>
                    `)}
                    ${E.slice(0,3).map(tt=>i`
                      <article class="command-alert ${L(tt.severity)}">
                        <div class="command-card-head">
                          <strong>${tt.kind}</strong>
                          <span class="command-chip ${L(tt.severity)}">${tt.severity}</span>
                        </div>
                        <p>${tt.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?i`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((tt,xs)=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>세션 이벤트 ${xs+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${La(tt)}</pre>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">메시지나 주의 항목이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">트레이스 흐름</div>
              <${w} panelId="command.trace" compact=${!0} />
            </div>
            ${e&&e.recent_trace_events.length>0?i`<div class="command-trace-stack">
                  ${e.recent_trace_events.map(tt=>i`<${ar} event=${tt} />`)}
                </div>`:i`<div class="empty-state">실행 범위 트레이스 이벤트가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">압력</div>
              <${w} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&e?i`<${gd} swarm=${e} />`:null}
              ${$.length>0?$.map(tt=>i`<${bd} blocker=${tt} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${v>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>승인 대기</strong>
                        <span class="command-chip warn">${v}</span>
                      </div>
                      <p>엄격 액션이 묶여 있습니다. 실제 승인 처리는 제어 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${f.length>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>확인 대기</strong>
                        <span class="command-chip warn">${f.length}</span>
                      </div>
                      <p>운영자 미리보기가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${f.slice(0,3).map(tt=>i`<span class="command-tag">${tt.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
            </div>
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">현재 초점</div>
              <${w} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&(e!=null&&e.operation)?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${e.operation.objective}</strong>
                          <div class="command-card-sub">${e.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${L(Ue(e.operation.status))}">${ke(e.operation.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>유닛</span><span>${e.operation.assigned_unit_id}</span>
                        <span>트레이스</span><span>${e.operation.trace_id}</span>
                        <span>자율성</span><span>${e.operation.autonomy_level??"정보 없음"}</span>
                        <span>최근 갱신</span><span>${et(e.operation.updated_at)}</span>
                      </div>
                    </article>
                  `:null}
              ${l&&(e!=null&&e.detachment)?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${e.detachment.detachment_id}</strong>
                          <div class="command-card-sub">${e.detachment.assigned_unit_id}</div>
                        </div>
                        <span class="command-chip ${L(Ue(e.detachment.status))}">${ke(e.detachment.status??"active")}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>리더</span><span>${e.detachment.leader_id??"미지정"}</span>
                        <span>편성</span><span>${e.detachment.roster.length}</span>
                        <span>세션</span><span>${e.detachment.session_id??"연결 없음"}</span>
                        <span>하트비트</span><span>${td(e.detachment.heartbeat_deadline)}</span>
                      </div>
                    </article>
                  `:null}
              ${a?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${a.session_id}</strong>
                          <div class="command-card-sub">현재 세션 기준</div>
                        </div>
                        <span class="command-chip ${L(Ue(a.status))}">${ke(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${Sn(a.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${Sn(a.remaining_sec)}</span>
                        <span>완료 변화량</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function Vr(t){switch((t??"").trim().toLowerCase()){case"active":return"가동 중";case"paused":return"일시정지";case"failed":return"실패";case"completed":case"done":return"완료";case"disconnected":return"끊김";case"preview":return"미리보기";case"captured":return"기록됨";default:return(t==null?void 0:t.trim())||"확인 필요"}}function F$({source:t}){const e=An(null),[n,s]=qn(null);return nt(()=>{let a=!1;const o=e.current;return o?(o.innerHTML="",s(null),(async()=>{try{const c=await Gf(),{svg:p}=await c.render(`command-chain-${Wf()}`,t);if(a||!e.current)return;e.current.innerHTML=p}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid 렌더링에 실패했습니다")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function K$({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return i`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${ce(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?i`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?i`<span class="command-tag ${ce(s==null?void 0:s.status)}">${ms(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${ed(t.history)}</div>
    </button>
  `}function B$({item:t}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"알 수 없는 체인"}</strong>
        <span class="command-chip ${ce(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${et(t.timestamp)}</div>
      <div class="command-card-sub">${ed(t)}</div>
    </article>
  `}function U$({node:t}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${ce(t.status)}">${t.status??"확인 필요"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"노드"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?i`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function H$({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,o=e.chain,l=(o==null?void 0:o.run_id)??null;return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${L(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${Vr(e.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>트레이스</span><span class="mono">${e.trace_id}</span>
        <span>자율성</span><span>${e.autonomy_level??"정보 없음"}</span>
        <span>예산 등급</span><span>${e.budget_class??"standard"}</span>
        <span>출처</span><span>${e.source??"managed"}</span>
        <span>최근 갱신</span><span>${et(e.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${ce(o.status)}">${Vr(o.status)}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">실행 ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?i`<div class="command-card-foot">체크포인트 ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{le("swarm"),ot("command",{surface:"swarm",operation_id:e.operation_id,...l?{run_id:l}:{}})}}
        >
          스웜 실시간 보기
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{Bo(e.operation_id),le("chains"),ot("command",{surface:"chains",operation:e.operation_id})}}
              >
                체인 열기
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${ct(n)} onClick=${()=>de(()=>fv(e.operation_id))}>
                ${ct(n)?"일시정지 중…":"일시정지"}
              </button>
              <button class="control-btn ghost" disabled=${ct(a)} onClick=${()=>de(()=>$v(e.operation_id))}>
                ${ct(a)?"회수 중…":"회수"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${ct(s)} onClick=${()=>de(()=>gv(e.operation_id))}>
                ${ct(s)?"재개 중…":"재개"}
              </button>
            `:null}
      </div>
    </article>
  `}function W$({card:t}){var n;const e=t.detachment;return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${L(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>리더</span><span>${e.leader_id??"미지정"}</span>
        <span>편성</span><span>${e.roster.length}</span>
        <span>세션</span><span>${e.session_id??"연결 없음"}</span>
        <span>런타임</span><span>${e.runtime_kind??"managed"}</span>
        <span>런타임 참조</span><span>${e.runtime_ref??"정보 없음"}</span>
        <span>진행 흔적</span><span>${et(e.last_progress_at)}</span>
        <span>하트비트</span><span>${td(e.heartbeat_deadline)}</span>
        <span>최근 갱신</span><span>${et(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?i`<span class="command-tag ${Uf(e.heartbeat_deadline)}">
              기한 ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function G$(){const t=Kt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">작전</div>
          <${w} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${H$} card=${e} />`)}
            </div>`:i`<div class="empty-state">관리형 또는 투영된 작전이 없습니다.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">분견대</div>
          <${w} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${W$} card=${e} />`)}
            </div>`:i`<div class="empty-state">투영된 분견대가 없습니다.</div>`}
      </section>
    </div>
  `}function J$(){var c,p,m,u,v,f,$,C,b,k,h,S,E,M,P,W;const t=ds.value,e=(t==null?void 0:t.operations)??[],n=tn.value,s=e.find(I=>I.operation.operation_id===n)??e[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,o=((p=Un.value)==null?void 0:p.run)??(s==null?void 0:s.preview_run)??null,l=!((m=Un.value)!=null&&m.run)&&!!(s!=null&&s.preview_run);return nt(()=>{a?_v(a):mv()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${w} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${ce(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>native chain 연결</strong>
            <span class="command-chip ${ce(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"체인 요약은 MASC 프록시를 통해 집계됩니다."}</p>
          <div class="command-card-grid">
            <span>기준 URL</span><span>${(t==null?void 0:t.connection.base_url)??"정보 없음"}</span>
            <span>연결된 작전</span><span>${((u=t==null?void 0:t.summary)==null?void 0:u.linked_operations)??0}</span>
            <span>활성 체인</span><span>${((v=t==null?void 0:t.summary)==null?void 0:v.active_chains)??0}</span>
            <span>최근 실패</span><span>${((f=t==null?void 0:t.summary)==null?void 0:f.recent_failures)??0}</span>
            <span>마지막 이벤트</span><span>${et(($=t==null?void 0:t.summary)==null?void 0:$.last_history_event_at)}</span>
          </div>
        </article>

        ${Aa.value?i`<div class="empty-state error">${Aa.value}</div>`:null}

        ${oo.value&&!t?i`<div class="empty-state">체인 오버레이 불러오는 중…</div>`:e.length>0?i`
                <div class="command-chain-list">
                  ${e.map(I=>i`
                    <${K$}
                      overlay=${I}
                      selected=${(s==null?void 0:s.operation.operation_id)===I.operation.operation_id}
                      onSelect=${()=>Bo(I.operation.operation_id)}
                    />
                  `)}
                </div>
              `:i`<div class="empty-state">체인 기반 작전이 아직 없습니다.</div>`}

        <div class="command-chain-history">
          <div class="command-guide-head">
            <strong>최근 이력</strong>
            <span class="command-chip">${(t==null?void 0:t.recent_history.length)??0}</span>
          </div>
          ${t&&t.recent_history.length>0?i`
                <div class="command-card-stack">
                  ${t.recent_history.slice(0,6).map(I=>i`<${B$} item=${I} />`)}
                </div>
              `:i`<div class="empty-state">최근 체인 이력이 없습니다.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">체인 상세</div>
          <${w} panelId="command.chains" compact=${!0} />
        </div>
        ${s?i`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${ce((C=s.operation.chain)==null?void 0:C.status)}">
                    ${((b=s.operation.chain)==null?void 0:b.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>종류</span><span>${((k=s.operation.chain)==null?void 0:k.kind)??"chain_dsl"}</span>
                  <span>체인 ID</span><span>${((h=s.operation.chain)==null?void 0:h.chain_id)??"goal-driven"}</span>
                  <span>실행 ID</span><span>${a??"아직 구체화되지 않음"}</span>
                  <span>진행률</span><span>${ms((S=s.runtime)==null?void 0:S.progress)}</span>
                  <span>경과</span><span>${Sn((E=s.runtime)==null?void 0:E.elapsed_sec)}</span>
                  <span>최근 갱신</span><span>${et(((M=s.operation.chain)==null?void 0:M.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(P=s.operation.chain)!=null&&P.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid 그래프</strong>
                        <span class="command-chip">${((W=s.operation.chain)==null?void 0:W.chain_id)??"graph"}</span>
                      </div>
                      <${F$} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">기록된 Mermaid 그래프가 아직 없습니다.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>실행 상세</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"실패":l?"미리보기":"기록됨":"대기 중"}
                  </span>
                </div>
                ${Ta.value?i`<div class="empty-state">실행 상세 불러오는 중…</div>`:Hn.value?i`<div class="empty-state error">${Hn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>체인</span><span>${o.chain_id}</span>
                            <span>실행</span><span>${o.run_id??"미리보기만 있음"}</span>
                            <span>지속시간</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"정보 없음"}</span>
                            <span>노드</span><span>${o.nodes.length}</span>
                          </div>
                          ${l?i`<div class="command-card-foot">run-store에 기록되기 전, 설계된 체인으로 만든 미리보기입니다.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(I=>i`<${U$} node=${I} />`)}
                          </div>
                        `:i`<div class="empty-state">이 작전의 run-store 상세는 아직 없습니다.</div>`}
              </div>
            `:i`<div class="empty-state">그래프와 실행 상세를 보려면 체인 기반 작전을 고르세요.</div>`}
      </section>
    </div>
  `}function Y$(t){switch((t??"").trim().toLowerCase()){case"pending":return"대기 중";case"approved":return"승인됨";case"denied":return"거부됨";case"executed":return"실행됨";case"active":return"가동 중";default:return(t==null?void 0:t.trim())||"확인 필요"}}function X$({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return i`
    <article class="command-card ${L(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${L(t.status)}">${Y$(t.status??"pending")}</span>
      </div>
      <div class="command-card-grid">
        <span>결정 ID</span><span>${t.decision_id}</span>
        <span>요청자</span><span>${t.requested_by??"알 수 없음"}</span>
        <span>출처</span><span>${t.source??"managed"}</span>
        <span>트레이스</span><span class="mono">${t.trace_id}</span>
        <span>생성 시각</span><span>${et(t.created_at)}</span>
        <span>이유</span><span>${t.reason??"정보 없음"}</span>
      </div>
      ${t.status==="pending"&&!s?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${ct(e)} onClick=${()=>de(()=>yv(t.decision_id))}>
                ${ct(e)?"승인 중…":"승인"}
              </button>
              <button class="control-btn ghost" disabled=${ct(n)} onClick=${()=>de(()=>bv(t.decision_id))}>
                ${ct(n)?"거부 중…":"거부"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">레거시 operator 승인입니다. 실제 실행은 operator control에서 처리합니다.</div>`:null}
    </article>
  `}function V$({row:t}){var c,p,m;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((c=e.policy)!=null&&c.frozen),o=!!((p=e.policy)!=null&&p.kill_switch),l=Math.round((t.utilization??0)*100);return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${L(l>100?"bad":l>70?"warn":"ok")}">${l}%</span>
      </div>
      <div class="command-card-grid">
        <span>편성</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>정원</span><span>${t.headcount_cap??0}</span>
        <span>작전</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>자율성</span><span>${((m=e.policy)==null?void 0:m.autonomy_level)??"정보 없음"}</span>
        <span>동결</span><span>${a?"예":"아니오"}</span>
        <span>킬 스위치</span><span>${o?"켜짐":"꺼짐"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${ct(n)} onClick=${()=>de(()=>kv(e.unit_id,!a))}>
          ${ct(n)?"적용 중…":a?"동결 해제":"동결"}
        </button>
        <button class="control-btn ghost" disabled=${ct(s)} onClick=${()=>de(()=>xv(e.unit_id,!o))}>
          ${ct(s)?"적용 중…":o?"킬 스위치 해제":"킬 스위치 켜기"}
        </button>
      </div>
    </article>
  `}function Q$(){const t=Kt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${w} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${X$} decision=${e} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">유닛 제어</div>
          <${w} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${V$} row=${e} />`)}
            </div>`:i`<div class="empty-state">제어할 용량 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function Z$(){return i`
    <div class="command-surface-tabs grouped">
      ${Yf.map(t=>i`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${nd.filter(e=>e.group===t.id).map(e=>i`
                <button
                  class="command-surface-tab ${Y.value===e.id?"active":""}"
                  onClick=${()=>{le(e.id),ot("command",Vo(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function th(){if(Y.value==="warroom")return i`<${w$} />`;if(Y.value==="summary")return i`<${jg} />`;if(Y.value==="orchestra")return i`<${Vg} />`;if(Y.value==="swarm")return i`<${z$} />`;if(!Kt.value)return i`<${Og} />`;switch(Y.value){case"chains":return i`<${J$} />`;case"topology":return i`<${$$} />`;case"alerts":return i`<${h$} />`;case"trace":return i`<${y$} />`;case"control":return i`<${Q$} />`;case"operations":default:return i`<${G$} />`}}function eh(){return nt(()=>{Be(),en(),vv(),ne(),Me()},[]),nt(()=>{if(D.value.tab!=="command")return;const t=D.value.params.surface,e=D.value.params.operation,n=us(D.value);if(qr(t))le(t);else if(n){const s=Dc(n);qr(s)&&le(s)}else t||le("warroom");e&&Bo(e),(t==="swarm"||t==="warroom"||t==="orchestra"||Y.value==="warroom"||Y.value==="orchestra")&&ne(),(t==="orchestra"||Y.value==="orchestra")&&Me(),(t==="warroom"||Y.value==="warroom")&&bt()},[D.value.tab,D.value.params.surface,D.value.params.operation,D.value.params.operation_id,D.value.params.run_id,D.value.params.source,D.value.params.action_type,D.value.params.target_type,D.value.params.target_id,D.value.params.focus_kind]),nt(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,Be(),en(),(Y.value==="swarm"||Y.value==="warroom"||Y.value==="orchestra")&&ne(),Y.value==="orchestra"&&Me(),Y.value==="warroom"&&bt()},250))},n=new EventSource(tg()),s=Vf.map(a=>{const o=()=>e();return n.addEventListener(a,o),{type:a,handler:o}});return n.onerror=()=>{e()},()=>{s.forEach(({type:a,handler:o})=>{n.removeEventListener(a,o)}),n.close(),t&&window.clearTimeout(t)}},[]),nt(()=>{const t=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const e=Y.value;e!=="swarm"&&e!=="warroom"&&e!=="orchestra"||(Be(),ne(),e==="orchestra"&&Me(),e==="warroom"&&bt())},5e3);return()=>{window.clearInterval(t)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{de(()=>hv())}}
            disabled=${ct("dispatch:tick")}
          >
            ${ct("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Ie(),Be(),en(),ne(),Y.value==="warroom"&&bt()}}
            disabled=${ga.value}
          >
            ${ga.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${ha.value?i`<div class="empty-state error">${ha.value}</div>`:null}
      ${ba.value?i`<div class="empty-state error">${ba.value}</div>`:null}
      <${kt} surfaceId="command" />
      <${Qa} />
      <${Eg} />
      ${Y.value==="warroom"?null:i`<${Lg} />`}
      <${Z$} />
      <${th} />
    </section>
  `}function nh(){var k,h;const t=Mt.value,e=Oo.value,n=(t==null?void 0:t.room)??{},s=(t==null?void 0:t.pending_confirms)??[],a=t==null?void 0:t.pending_confirm_summary,o=a?a.confirm_required_actions:((t==null?void 0:t.available_actions)??[]).filter(S=>S.confirm_required),l=((k=a==null?void 0:a.actor_filter)==null?void 0:k.trim())||null,c=(a==null?void 0:a.hidden_count)??0,p=(a==null?void 0:a.hidden_actors)??[],m=(t==null?void 0:t.recent_messages)??[],u=(e==null?void 0:e.recommended_actions)??[],v=(h=e==null?void 0:e.active_recommended_actions)!=null&&h.length?e.active_recommended_actions:u,f=e==null?void 0:e.active_summary,$=(e==null?void 0:e.resident_judge_runtime)??(t==null?void 0:t.resident_judge_runtime),C=(e==null?void 0:e.active_guidance_layer)??"fallback",b=m.slice(0,5);return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Room 개입</div>
          <${w} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">전체 room에 영향 주는 액션입니다. 방송, 정지/재개, 작업 주입을 여기서 처리합니다.</p>

        <div class="ops-stat-grid">
          <div class="ops-stat">
            <span>Room</span>
            <strong>${n.current_room??n.room_id??"default"}</strong>
          </div>
          <div class="ops-stat">
            <span>프로젝트</span>
            <strong>${n.project??"확인 없음"}</strong>
          </div>
          <div class="ops-stat">
            <span>클러스터</span>
            <strong>${n.cluster??"확인 없음"}</strong>
          </div>
          <div class="ops-stat ${n.paused?"warn":"ok"}">
            <span>상태</span>
            <strong>${n.paused?"일시정지":"진행 중"}</strong>
          </div>
          <div class="ops-stat ${e$($)}">
            <span>Resident Judge</span>
            <strong>${nr($)}</strong>
          </div>
        </div>

        <label class="control-label" for="ops-broadcast">Room 방송</label>
        <div class="control-row">
          <input
            id="ops-broadcast"
            class="control-input"
            type="text"
            placeholder="@agent 또는 room 전체 공지"
            value=${sn.value}
            onInput=${S=>{sn.value=S.target.value}}
            onKeyDown=${S=>{S.key==="Enter"&&Jr()}}
            disabled=${Z.value}
          />
          <button class="control-btn" onClick=${()=>{Jr()}} disabled=${Z.value||sn.value.trim()===""}>
            보내기
          </button>
        </div>

        <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
        <div class="control-row ops-split-row">
          <input
            id="ops-pause-reason"
            class="control-input"
            type="text"
            value=${Pa.value}
            onInput=${S=>{Pa.value=S.target.value}}
            disabled=${Z.value}
          />
          <button class="control-btn ghost" onClick=${()=>{u$()}} disabled=${Z.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{md()}} disabled=${Z.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${an.value}
          onInput=${S=>{an.value=S.target.value}}
          disabled=${Z.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${Jn.value}
          onInput=${S=>{Jn.value=S.target.value}}
          disabled=${Z.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${Yn.value}
            onChange=${S=>{Yn.value=S.target.value}}
            disabled=${Z.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{p$()}} disabled=${Z.value||an.value.trim()===""}>
            주입
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">추천 개입</div>
          <${w} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
        <article class="ops-guidance-card ${ja(C)}">
          <div class="ops-guidance-head">
            <strong>${er(C)}</strong>
            <span>${($==null?void 0:$.keeper_name)??(e==null?void 0:e.judgment_owner)??"judge 없음"}</span>
          </div>
          <div class="ops-guidance-body">
            ${(f==null?void 0:f.summary)??"현재 active guidance 요약이 없습니다. fallback queue만 표시합니다."}
          </div>
          <div class="ops-guidance-meta">
            <span>authoritative ${e!=null&&e.authoritative_judgment_available?"yes":"no"}</span>
            <span>${sr(f)}</span>
            ${$!=null&&$.model_used?i`<span>${$.model_used}</span>`:null}
          </div>
        </article>
        ${Bn.value&&!e?i`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:v.length>0?i`
          <div class="ops-log-list">
            ${v.map(S=>i`
              <article key=${`${S.action_type}:${S.target_type}:${S.target_id??"room"}`} class="ops-log-entry ${S.severity}">
                <div class="ops-log-head">
                  <strong>${Pe(S.action_type)}</strong>
                  <span>${on(S.target_type)}${S.target_id?` · ${S.target_id}`:""}</span>
                  <span>${Oa(S.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${S.reason}</div>
                ${S.suggested_payload?i`
                  <div class="ops-confirmation-actions">
                    <button class="control-btn ghost" onClick=${()=>{c$(S)}} disabled=${Z.value}>
                      폼에 채우기
                    </button>
                  </div>
                `:null}
              </article>
            `)}
          </div>
        `:i`
          <div class="ops-empty">지금 떠 있는 추천 개입은 없습니다.</div>
        `}
      </section>

      <section class="card ops-panel ops-pending-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${w} panelId="intervene.pending_confirmations" compact=${!0} />
        </div>
        <p class="ops-context-note">
          ${l?`현재 actor ${l} 기준 queue를 읽습니다. 승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다.`:"승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다."}
        </p>
        ${o.length>0?i`
          <div class="ops-log-list">
            ${o.map(S=>i`
              <article key=${`${S.action_type}:${S.target_type}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${Pe(S.action_type)}</strong>
                  <span>${on(S.target_type)}</span>
                  <span>${Oa(S.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${S.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}
        ${s.length>0?i`
          <div class="ops-confirmation-list">
            ${s.map(S=>i`
              <article key=${S.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${Pe(S.action_type)}</strong>
                  <span>${on(S.target_type)}${S.target_id?` · ${S.target_id}`:""}</span>
                  <span>${S.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${S.preview?i`<pre class="ops-code-block compact">${Na(S.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{Yr(S.confirm_token)}} disabled=${Z.value}>
                    실행
                  </button>
                  <button class="control-btn ghost" onClick=${()=>{Yr(S.confirm_token,"deny")}} disabled=${Z.value}>
                    거부
                  </button>
                  <span class="ops-token">${S.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        `:i`
          <div class="ops-empty">
            ${c>0&&l?`현재 선택한 actor(${l}) 기준 승인 대기는 0건입니다. 다른 actor 대기 ${c}건${p.length>0?` · ${p.join(", ")}`:""}`:"지금 승인 대기는 없습니다. 위 목록의 preview-confirm 액션을 먼저 만들어야 여기에 쌓입니다."}
          </div>
        `}
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 Room 메시지</div>
          <${w} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${b.length>0?i`
          <div class="ops-feed-list">
            ${b.map(S=>i`
              <article key=${S.seq??S.id??S.timestamp} class="ops-feed-item">
                <div class="ops-feed-meta">
                  <strong>${S.from}</strong>
                  <span>${S.timestamp}</span>
                </div>
                <div class="ops-feed-content">${S.content}</div>
              </article>
            `)}
          </div>
        `:i`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
      </section>
    </div>
  `}function sh(){var m;const t=Mt.value,e=wt.value,n=(t==null?void 0:t.sessions)??[],s=((t==null?void 0:t.available_actions)??[]).filter(u=>u.target_type==="team_session"),a=n.find(u=>u.session_id===cn.value)??n[0]??null,o=e==null?void 0:e.active_summary,l=(e==null?void 0:e.active_guidance_layer)??"fallback",c=(e==null?void 0:e.resident_judge_runtime)??(t==null?void 0:t.resident_judge_runtime),p=(m=e==null?void 0:e.active_recommended_actions)!=null&&m.length?e.active_recommended_actions:(e==null?void 0:e.recommended_actions)??[];return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${w} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(u=>{var v;return i`
            <button
              key=${u.session_id}
              class="ops-entity-card ${(a==null?void 0:a.session_id)===u.session_id?"active":""}"
              onClick=${()=>{cn.value=u.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${u.session_id}</strong>
                <span class="status-badge ${u.status??"idle"}">${We(u.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(u.progress_pct??0)}%</span>
                <span>${u.done_delta_total??0}건 완료</span>
                <span>${(v=u.team_health)!=null&&v.status?We(String(u.team_health.status)):"상태 확인 필요"}</span>
              </div>
            </button>
          `})}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Session 요약</div>
          <${w} panelId="intervene.session_digest" compact=${!0} />
        </div>
        <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
        ${a&&e?i`
          <article class="ops-guidance-card ${ja(l)}">
            <div class="ops-guidance-head">
              <strong>${er(l)}</strong>
              <span>${nr(c)}</span>
            </div>
            <div class="ops-guidance-body">
              ${(o==null?void 0:o.summary)??"현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다."}
            </div>
            <div class="ops-guidance-meta">
              <span>authoritative ${e.authoritative_judgment_available?"yes":"no"}</span>
              <span>${sr(o)}</span>
              ${c!=null&&c.model_used?i`<span>${c.model_used}</span>`:null}
            </div>
          </article>
          ${p.length>0?i`
            <div class="ops-log-list">
              ${p.map(u=>i`
                <article key=${`${u.action_type}:${u.target_type}:${u.target_id??"session"}`} class="ops-log-entry ${u.severity}">
                  <div class="ops-log-head">
                    <strong>${Pe(u.action_type)}</strong>
                    <span>${on(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
                  </div>
                  <div class="ops-log-body">${u.reason}</div>
                </article>
              `)}
            </div>
          `:null}
          <div class="ops-log-list">
            ${e.attention_items.length>0?e.attention_items.map(u=>i`
              <article key=${`${u.kind}:${u.target_id??"session"}`} class="ops-log-entry ${u.severity}">
                <div class="ops-log-head">
                  <strong>${u.kind}</strong>
                  <span>${on(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${u.summary}</div>
              </article>
            `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${e.worker_cards.length>0?e.worker_cards.map(u=>i`
              <article key=${`${u.actor??u.spawn_role??"worker"}:${u.spawn_agent??u.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${u.actor??u.spawn_role??"worker"}</strong>
                  <span>${We(u.status)}</span>
                  <span>${u.spawn_agent??u.runtime_pool??"runtime 확인 필요"}</span>
                </div>
                <div class="ops-log-body">
                  ${u.worker_class??"worker"}${u.lane_id?` · ${u.lane_id}`:""}${u.routing_reason?` · ${u.routing_reason}`:""}
                </div>
              </article>
            `):null}
          </div>
        `:i`
          <div class="ops-empty">세션을 고르면 세부 요약을 불러옵니다.</div>
        `}
      </section>

      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Session 액션</div>
          <${w} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>
        ${s.length>0?i`
          <div class="ops-log-list">
            ${s.map(u=>i`
              <article key=${u.action_type} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${Pe(u.action_type)}</strong>
                  <span>${Oa(u.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${u.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}

        ${a?i`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${a.session_id}</div>
            <div class="ops-detail-meta">
              <span>상태: ${We(a.status)}</span>
              <span>경과: ${a.elapsed_sec??0}초</span>
              <span>남은 시간: ${a.remaining_sec??0}초</span>
            </div>
            ${a.linked_autoresearch?i`
              <div class="ops-detail-meta">
                <span>Autoresearch: ${String(a.linked_autoresearch.status??"unknown")}</span>
                <span>Loop: ${String(a.linked_autoresearch.loop_id??"n/a")}</span>
                <span>Cycle: ${String(a.linked_autoresearch.current_cycle??0)}</span>
                <span>Best: ${String(a.linked_autoresearch.best_score??"n/a")}</span>
              </div>
            `:null}
            ${a.recent_events&&a.recent_events.length>0?i`
              <pre class="ops-code-block compact">${Na(a.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${yt.value}
            onChange=${u=>{yt.value=u.target.value}}
            disabled=${Z.value||!a}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
            <option value="worker_spawn_batch">worker 교체</option>
          </select>
          <button class="control-btn" onClick=${()=>{m$()}} disabled=${Z.value||!a}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${i$(yt.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${Xn.value}
          onInput=${u=>{Xn.value=u.target.value}}
          disabled=${Z.value||!a}
        ></textarea>

        ${yt.value==="task"?i`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${Vn.value}
            onInput=${u=>{Vn.value=u.target.value}}
            disabled=${Z.value||!a}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${Qn.value}
            onInput=${u=>{Qn.value=u.target.value}}
            disabled=${Z.value||!a}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${Zn.value}
            onChange=${u=>{Zn.value=u.target.value}}
            disabled=${Z.value||!a}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
        `:yt.value==="worker_spawn_batch"?i`
          <textarea
            class="control-textarea"
            rows=${6}
            placeholder='spawn_batch JSON, 예: [{"spawn_agent":"llama","spawn_prompt":"...", "spawn_role":"replacement"}]'
            value=${ts.value}
            onInput=${u=>{ts.value=u.target.value}}
            disabled=${Z.value||!a}
          ></textarea>
        `:null}

        <div class="control-row ops-split-row">
          <input
            class="control-input"
            type="text"
            value=${za.value}
            onInput=${u=>{za.value=u.target.value}}
            disabled=${Z.value||!a}
          />
          <button class="control-btn ghost" onClick=${()=>{_$()}} disabled=${Z.value||!a}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function ah(){var o;const t=Mt.value,e=(t==null?void 0:t.keepers)??[],n=(t==null?void 0:t.persistent_agents)??[],s=(t==null?void 0:t.available_actions)??[],a=e.find(l=>l.name===uo.value)??e[0]??null;return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${w} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${e.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:e.map(l=>i`
            <button
              key=${l.name}
              class="ops-entity-card ${(a==null?void 0:a.name)===l.name?"active":""}"
              onClick=${()=>{uo.value=l.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${l.name}</strong>
                <span class="status-badge ${l.status??"idle"}">${We(l.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${l.model??"model 확인 필요"}</span>
                <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${Wr(l.last_turn_ago_s)}</span>
              </div>
            </button>
          `)}
        </div>
        <div class="ops-context-note" style="margin-top:12px;">Persistent agent는 resident keeper와 분리해서 참고용으로만 보여줍니다.</div>
        <div class="ops-entity-list">
          ${n.length===0?i`<div class="ops-empty">분리된 persistent agent는 없습니다.</div>`:n.map(l=>i`
                <article key=${l.name} class="ops-entity-card">
                  <div class="ops-entity-title-row">
                    <strong>${l.name}</strong>
                    <span class="status-badge ${l.status??"idle"}">${We(l.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>persistent</span>
                    <span>${l.model??"model 확인 필요"}</span>
                    <span>${Wr(l.last_turn_ago_s)}</span>
                  </div>
                </article>
              `)}
        </div>
      </section>

      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Keeper 액션</div>
          <${w} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 keeper에만 직접 메시지를 보내서 probe, 수정, 재지시를 합니다.</p>

        ${a?i`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${a.name}</div>
            <div class="ops-detail-meta">
              <span>자율성: ${a.autonomy_level??"확인 없음"}</span>
              <span>세대: ${a.generation??0}</span>
              <span>활성 목표: ${((o=a.active_goal_ids)==null?void 0:o.length)??0}</span>
            </div>
          </div>
          <${Qc}
            keeperName=${a.name}
            placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
          />
        `:i`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">가능한 액션 목록</div>
          <${w} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
        <div class="ops-log-list">
          ${s.length?s.map(l=>i`
                <article key=${`${l.action_type}:${l.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${Pe(l.action_type)}</strong>
                    <span>${on(l.target_type)}</span>
                    <span>${Oa(l.confirm_required)}</span>
                  </div>
                  <div class="ops-log-body">${l.description??"설명이 아직 없습니다."}</div>
                </article>
              `):i`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 개입 로그</div>
          <${w} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <div class="ops-log-list">
          ${ma.value.length===0?i`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:ma.value.map(l=>i`
            <article key=${l.id} class="ops-log-entry ${l.outcome}">
              <div class="ops-log-head">
                <strong>${Pe(l.action_type)}</strong>
                <span>${l.target_label}</span>
                <span>${l.at}</span>
              </div>
              <div class="ops-log-body">${l.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function ih(){var M,P,W;const t=Mt.value,e=D.value.tab==="intervene"?us(D.value):null,n=Oo.value,s=(t==null?void 0:t.room)??{},a=(t==null?void 0:t.sessions)??[],o=(t==null?void 0:t.keepers)??[],l=(t==null?void 0:t.pending_confirms)??[],c=t==null?void 0:t.pending_confirm_summary,p=(c==null?void 0:c.visible_count)??l.length,m=(c==null?void 0:c.total_count)??l.length,u=(c==null?void 0:c.hidden_count)??0,v=((M=c==null?void 0:c.actor_filter)==null?void 0:M.trim())||null,f=a.find(I=>I.session_id===cn.value)??a[0]??null,$=(n==null?void 0:n.attention_items)??[],C=$.filter(s$),b=$.filter(a$),k=a.filter(I=>n$(I)!=="ok"),h=o.filter(I=>vi(I)!=="ok"),S=d$(e,a,o);nt(()=>{ze()},[]),nt(()=>{if(D.value.tab!=="intervene"){Ps.value=null;return}if(!e){Ps.value=null;return}Ps.value!==e.id&&(Ps.value=e.id,l$(e))},[D.value.tab,D.value.params.source,D.value.params.action_type,D.value.params.target_type,D.value.params.target_id,D.value.params.focus_kind,e==null?void 0:e.id]),nt(()=>{const I=(f==null?void 0:f.session_id)??null;ln(I)},[f==null?void 0:f.session_id]);const E=[{key:"room",label:"방 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:u>0?`${p}/${m}`:p,detail:p>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":u>0&&v?`현재 개입 ID(${v}) 기준으로는 비어 있고, 다른 개입 ID 대기 ${u}건이 있습니다`:"지금 막혀 있는 확인 대기는 없습니다",tone:m>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:C.length>0?C.length:a.length,detail:C.length>0?((P=C[0])==null?void 0:P.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 팀 세션이 없습니다":"세션 쪽 긴급 주의 신호는 현재 없습니다",tone:C.length>0?Gr(C):a.length===0?"warn":k.some(I=>dn(I.status)==="paused")?"bad":k.length>0?"warn":"ok"},{key:"keeper",label:"키퍼 압력",value:b.length>0?b.length:h.length,detail:b.length>0?((W=b[0])==null?void 0:W.summary)??"직접 메시지나 상태 점검이 필요한 키퍼가 있습니다":h.length>0?"오래됐거나 오프라인이거나 텔레메트리가 비는 키퍼가 보입니다":"지금은 키퍼 쪽이 비교적 안정적입니다",tone:b.length>0?Gr(b):h.some(I=>vi(I)==="bad")?"bad":h.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${kt} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">개입</div>
            <${w} panelId="intervene.action_studio" compact=${!0} />
          </div>
          <h2 class="ops-heading">방, 세션, 키퍼를 바로 조정하는 화면</h2>
          <p class="ops-subheading">
            읽는 화면이 아니라 행동하는 화면입니다. 방, 세션, 키퍼를 나눠 보고 바로 개입합니다.
          </p>
        </div>
        <div class="ops-toolbar">
          <label class="control-label" for="ops-actor">개입 ID</label>
          <input
            id="ops-actor"
            class="control-input ops-actor-input"
            type="text"
            value=${ei.value}
            onInput=${I=>t$(I.target.value)}
          />
            <button
              class="control-btn ghost"
              onClick=${()=>{Ie(),bt(),ze(),ln((f==null?void 0:f.session_id)??null)}}
            disabled=${Kn.value||Z.value}
          >
            ${Kn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${pe.value?i`<section class="ops-banner error">${pe.value}</section>`:null}
      ${rn.value?i`<section class="ops-banner error">${rn.value}</section>`:null}
      <${Qa} />
      ${e?i`
        <section class="ops-banner ${S?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${Za(e.action_type)}</span>
            <span>${Go(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?i`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${S?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const I=[];if((p>0||u>0)&&I.push({label:u>0?`확인 대기 ${p}/${m}건 확인`:`확인 대기 ${p}건 처리`,desc:u>0&&v?`현재 개입 ID(${v}) 기준으로 보이는 대기열을 먼저 확인합니다`:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:p>0?"bad":"warn",onClick:()=>{const G=document.querySelector(".ops-pending-section");G==null||G.scrollIntoView({behavior:"smooth"})}}),s.paused&&I.push({label:"방 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void md()}),h.length>0){const G=h.filter(V=>vi(V)==="bad");I.push({label:G.length>0?`오프라인 키퍼 ${G.length}개`:`점검이 필요한 키퍼 ${h.length}개`,desc:G.length>0?"메시지를 보내거나 상태를 확인하세요":"오래됐거나 텔레메트리가 비어 있습니다",tone:G.length>0?"bad":"warn",onClick:()=>{const V=document.querySelector(".ops-keeper-section");V==null||V.scrollIntoView({behavior:"smooth"})}})}return I.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${I.slice(0,3).map(G=>i`
                <button class="ops-action-guide-item ${G.tone}" onClick=${G.onClick}>
                  <strong>${G.label}</strong>
                  <span>${G.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `})()}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${w} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 방인지, 세션인지, 키퍼인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${E.map(I=>i`
            <div key=${I.key} class="ops-priority-card ${I.tone}">
              <span class="ops-priority-label">${I.label}</span>
              <strong>${I.value}</strong>
              <div class="ops-priority-detail">${I.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${nh} />
        <${sh} />
        <${ah} />
      </div>
    </section>
  `}function oh({text:t}){if(!t)return null;const e=rh(t);return i`<div class="markdown-content">${e}</div>`}function rh(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),p=[];for(s++;s<e.length&&!e[s].startsWith(l);)p.push(e[s]),s++;s++,n.push(i`<pre><code class=${c?`language-${c}`:""}>${p.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<e.length&&!e[s].includes("</think>");)l.push(e[s]),s++;if(s<e.length){const m=e[s].replace("</think>","").trim();m&&l.push(m),s++}const p=l.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${fi(p)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<e.length&&e[s].startsWith("> ");)l.push(e[s].slice(2)),s++;n.push(i`<blockquote>${fi(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<e.length;){const l=e[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;o.push(l),s++}o.length>0&&n.push(i`<p>${fi(o.join(`
`))}</p>`)}return n}function fi(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&e.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const kd=[{id:"recent",label:"최신순"},{id:"hot",label:"인기순"},{id:"trending",label:"급상승"},{id:"updated",label:"최근 갱신"},{id:"discussed",label:"토론 많은 순"}],Zs=g(null),ta=g([]),un=g(!1),Le=g(null),Ln=g(""),Pn=g(!1),Ge=g(!0),ir=20,qe=g(ir);function lh(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const ch=g(lh());function dh(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"미리보기 없음"}function Qr(t){return t.updated_at!==t.created_at}function uh(t){if(t.post_kind)return t.post_kind==="automation";const e=(t.hearth??"").toLowerCase();return t.visibility!=="internal"||!t.expires_at||!e?!1:!!(e.startsWith("mdal")||e.includes("harness"))}function ph(t){return t==="lodge-system"||t==="team-session"}function es(t){return t.post_kind?t.post_kind:ph(t.author)?"system":uh(t)?"automation":"human"}function xd(t){const e=[],n=[];let s=0;return t.forEach(a=>{const o=es(a);if(!(o==="system"&&Ae.value)){if(o==="automation"&&Ge.value){s+=1;return}if(o==="human"){e.push(a);return}n.push(a)}}),{human:e,operations:n,hiddenAutomation:s}}function mh(t){if(!t.expires_at)return null;const e=Date.parse(t.expires_at);return Number.isFinite(e)?e<=Date.now()?i`<span class="board-meta-chip">만료됨</span>`:i`<span class="board-meta-chip">만료까지 <${X} timestamp=${t.expires_at} /></span>`:null}async function or(t){Le.value=t,Zs.value=null,ta.value=[],un.value=!0;try{const e=await Xu(t);if(Le.value!==t)return;Zs.value={id:e.id,author:e.author,title:e.title,body:e.body,content:e.content,meta:e.meta,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,post_kind:e.post_kind,flair:e.flair,hearth:e.hearth,visibility:e.visibility,expires_at:e.expires_at,hearth_count:e.hearth_count},ta.value=e.comments??[]}catch{Le.value===t&&(Zs.value=null,ta.value=[])}finally{Le.value===t&&(un.value=!1)}}async function Zr(t){const e=Ln.value.trim();if(e){Pn.value=!0;try{await Vu(t,ch.value,e),Ln.value="",j("댓글을 등록했습니다","success"),await or(t),oe()}catch{j("댓글 등록에 실패했습니다","error")}finally{Pn.value=!1}}}function _h(){const t=wn.value,e=Ge.value?"자동화 글 숨김":"자동화 글 표시 중";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${kd.map(n=>i`
          <button
            class="board-sort-btn ${t===n.id?"active":""}"
            onClick=${()=>{wn.value=n.id,qe.value=ir,oe()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Ge.value?"is-active":""}"
          onClick=${()=>{Ge.value=!Ge.value}}
        >
          ${e}
        </button>
        <button
          class="control-btn ghost ${Ae.value?"is-active":""}"
          onClick=${()=>{Ae.value=!Ae.value,oe()}}
        >
          ${Ae.value?"시스템 글 숨김":"시스템 글 표시 중"}
        </button>
        <button class="control-btn ghost" onClick=${oe} disabled=${Fn.value}>
          ${Fn.value?"새로고침 중...":"새로고침"}
        </button>
      </div>
    </div>
  `}function gi(){var s;const t=((s=kd.find(a=>a.id===wn.value))==null?void 0:s.label)??wn.value,e=xd(Ya.value),n=e.human.length+e.operations.length;return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">보이는 글</span>
        <strong>${n}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">정렬</span>
        <strong>${t}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">잡음 필터</span>
        <strong>${Ge.value?`자동화 ${e.hiddenAutomation}건 숨김`:"분리된 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">시스템 글 정책</span>
        <strong>${Ae.value?"시스템 글 숨김":"시스템 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">최근 갱신</span>
        <strong>${Qi.value?i`<${X} timestamp=${Qi.value} />`:"아직 불러오지 않음"}</strong>
      </div>
    </div>
  `}function tl({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Ll(t.id,n),oe()}catch{j("투표에 실패했습니다","error")}};return i`
    <div class="board-post" onClick=${()=>Wd(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-head">
            <div class="post-title-row">
              <div class="post-title">${t.title}</div>
              <div class="post-chip-row">
                ${Qr(t)?i`<span class="board-meta-chip">수정됨</span>`:null}
                ${es(t)!=="human"?i`<span class="board-meta-chip">${es(t)}</span>`:null}
                ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>작성자 ${t.author}</span>
            <span><${X} timestamp=${t.created_at} /></span>
            ${Qr(t)?i`<span>수정 <${X} timestamp=${t.updated_at} /></span>`:null}
            <span>댓글 ${t.comment_count}</span>
            <span>투표 ${t.votes??0}</span>
          </div>
        </div>
        <div class="post-snippet">${dh(t.body)}</div>
      </div>
    </div>
  `}function vh({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">아직 댓글이 없습니다</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${X} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function fh({postId:t}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="댓글 추가..."
        value=${Ln.value}
        onInput=${e=>{Ln.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Zr(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Pn.value}
      />
      <button
        onClick=${()=>Zr(t)}
        disabled=${Pn.value||Ln.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Pn.value?"...":"등록"}
      </button>
    </div>
  `}function gh({post:t}){Le.value!==t.id&&!un.value&&or(t.id);const e=async n=>{try{await Ll(t.id,n),oe()}catch{j("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>ot("memory")}>← 메모리로 돌아가기</button>
      <${R} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${oh} text=${t.body} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${X} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          ${t.hearth||t.visibility||t.expires_at?i`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                  ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
                  ${es(t)!=="human"?i`<span class="board-meta-chip">${es(t)}</span>`:null}
                  ${mh(t)}
                </div>
              `:null}
          ${t.meta?i`
                <details style="margin-top:12px;">
                  <summary>운영 메타</summary>
                  <div class="post-body" style="margin-top:8px;">
                    ${t.meta.source?i`<div><strong>출처</strong>: ${t.meta.source}</div>`:null}
                    ${t.meta.state_block?i`<pre style="white-space:pre-wrap; margin-top:8px;">${t.meta.state_block}</pre>`:null}
                  </div>
                </details>
              `:null}
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ 추천</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ 비추천</button>
          </div>
        </div>
      <//>

      <${R} title="댓글" semanticId="memory.feed">
        ${un.value?i`<div class="loading-indicator">댓글 불러오는 중...</div>`:i`<${vh} comments=${ta.value} />`}
        <${fh} postId=${t.id} />
      <//>
    </div>
  `}function $h(){const t=xd(Ya.value),e=[...t.human,...t.operations],n=D.value.params.post??null,s=n?e.find(a=>a.id===n)??(Le.value===n?Zs.value:null):null;return n&&!s&&Le.value!==n&&!un.value&&or(n),n?s?i`
          <${kt} surfaceId="memory" />
          <${gi} />
          <${gh} post=${s} />
        `:i`
          <div>
            <${kt} surfaceId="memory" />
            <${gi} />
            <button class="back-btn" onClick=${()=>ot("memory")}>← 메모리로 돌아가기</button>
            ${un.value?i`<div class="loading-indicator">글 불러오는 중...</div>`:i`<div class="empty-state">글을 찾지 못했습니다</div>`}
          </div>
        `:i`
    <div>
      <${kt} surfaceId="memory" />
      <${gi} />
      <${_h} />
      ${Fn.value?i`<div class="loading-indicator">메모리 피드 불러오는 중...</div>`:e.length===0?i`<div class="empty-state">지금은 남아 있는 메모리 글이 없습니다</div>`:i`
              <${R} title="사람이 쓴 글" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.human.slice(0,qe.value).map(a=>i`<${tl} key=${a.id} post=${a} />`)}
                </div>
                ${t.human.length>qe.value?i`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{qe.value=qe.value+ir}}
                    >
                      더 보기 (${t.human.length-qe.value}개 남음)
                    </button>
                  </div>
                `:null}
              <//>
              ${t.operations.length>0?i`
                    <${R} title="자동화 · 시스템" class="section" semanticId="memory.feed">
                      <div class="board-post-list">
                        ${t.operations.map(a=>i`<${tl} key=${a.id} post=${a} />`)}
                      </div>
                    <//>
                  `:null}
            `}
    </div>
  `}const Se=g(null),Ht=g(null),Wt=g(null);function ns(t){return t==="bad"||t==="critical"||t==="offline"?"bad":t==="warn"||t==="paused"||t==="blocked"||t==="interrupted"?"warn":"ok"}function ss(t){switch((t??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":return"주의";case"bad":case"critical":return"위험";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function hh(t){return t==="session"?"세션":"작전"}function yh(t){return t?ve.value.find(e=>e.name===t||e.agent_name===t)??null:null}function bh(t){switch(t){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function kh(t){switch(t){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function xh(t){switch(t){case"acted":return"행동";case"passed":return"통과";case"skipped":return"건너뜀";case"failed":return"실패";default:return t}}function Sh(t){switch(t){case"post":return"post";case"comment":return"comment";case"vote":return"vote";case"none":case null:case void 0:return"none";default:return t}}function el(t){if(!t)return;const e=Pv({targetType:t.target_type,targetId:t.target_id,focusKind:t.focus_kind,operationId:t.operation_id??null,commandSurface:t.command_surface??null,sourceLabel:"실행 진단",summary:t.label});jc(e),ot(t.surface,t.surface==="intervene"?Oc(e):qc(e))}function yn({label:t,value:e,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function rr({intervene:t,command:e}){return i`
    <div class="control-row">
      ${t?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),el(t)}}
            >
              ${t.label}
            </button>
          `:null}
      ${e?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),el(e)}}
            >
              ${e.label}
            </button>
          `:null}
    </div>
  `}function Ch({item:t,selected:e}){return i`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{Se.value=e?null:t.id,Ht.value=null,Wt.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.kind==="session"?t.target_id:t.linked_session_id??t.target_id}</div>
          <div class="mission-card-title">${t.summary}</div>
        </div>
        <span class="command-chip ${ns(t.severity)}">${ss(t.status??t.severity)}</span>
      </div>
      <div class="mission-card-meta">
        <span>${hh(t.kind)}</span>
        ${t.linked_operation_id?i`<span>연결 작전 · ${t.linked_operation_id}</span>`:null}
        ${t.last_seen_at?i`<span><${X} timestamp=${t.last_seen_at} /></span>`:null}
      </div>
      <${rr} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function Ah({brief:t,selected:e}){return i`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.session-card"
      onClick=${()=>{Ht.value=e?null:t.session_id,Wt.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          <div class="mission-card-title">${t.goal}</div>
        </div>
        <span class="command-chip ${ns(t.health??t.status)}">${ss(t.status)}</span>
      </div>
      <div class="mission-card-meta">
        <span>건강도 · ${ss(t.health??"ok")}</span>
        ${t.linked_operation_id?i`<span>연결 작전 · ${t.linked_operation_id}</span>`:null}
        ${t.last_activity_at?i`<span><${X} timestamp=${t.last_activity_at} /></span>`:null}
      </div>
      ${t.runtime_blocker?i`<div class="mission-card-detail">${t.runtime_blocker}</div>`:t.last_activity_summary?i`<div class="mission-card-detail">${t.last_activity_summary}</div>`:null}
      ${t.worker_gap_summary?i`<div class="monitor-footnote">${t.worker_gap_summary}</div>`:null}
      <${rr} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function Th({brief:t,selected:e}){return i`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.operation-card"
      onClick=${()=>{Wt.value=e?null:t.operation_id,Ht.value=t.linked_session_id??null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.operation_id}${t.assigned_unit_label?` · ${t.assigned_unit_label}`:""}</div>
          <div class="mission-card-title">${t.objective}</div>
        </div>
        <span class="command-chip ${ns(t.blocker_summary?"warn":t.status)}">${ss(t.status)}</span>
      </div>
      <div class="mission-card-meta">
        ${t.stage?i`<span>단계 · ${t.stage}</span>`:null}
        ${t.linked_session_id?i`<span>세션 · ${t.linked_session_id}</span>`:null}
        ${t.updated_at?i`<span><${X} timestamp=${t.updated_at} /></span>`:null}
      </div>
      ${t.blocker_summary?i`<div class="mission-card-detail">${t.blocker_summary}</div>`:null}
      ${t.next_tool?i`<div class="monitor-footnote">다음 도구 · ${t.next_tool}</div>`:null}
      <${rr} command=${t.command_handoff} />
    </button>
  `}function Ih({tick:t}){return t?i`
    <div class="monitor-nested-card">
      <div class="stats-grid">
        <${yn} label="checked" value=${t.checked??0} color="#22d3ee" />
        <${yn} label="acted" value=${t.acted??0} color="#4ade80" />
        <${yn} label="passed" value=${t.passed??0} color="#94a3b8" />
        <${yn} label="skipped" value=${t.skipped??0} color="#fbbf24" />
        <${yn} label="failed" value=${t.failed??0} color="#fb7185" />
      </div>
      <div class="monitor-meta">
        ${t.last_tick_at?i`<span>마지막 tick <${X} timestamp=${t.last_tick_at} /></span>`:i`<span>마지막 tick 없음</span>`}
        ${t.last_skip_reason?i`<span>대표 skip 이유 · ${t.last_skip_reason}</span>`:null}
      </div>
      ${t.activity_report?i`<div class="monitor-footnote">${t.activity_report}</div>`:null}
    </div>
  `:i`<div class="empty-state">최근 lodge tick 기록이 없습니다.</div>`}function Rh({row:t}){return i`
    <button
      class="monitor-row ${ns(t.outcome==="failed"?"bad":t.outcome==="skipped"?"warn":"ok")}"
      data-testid="execution.lodge-checkin-card"
      onClick=${()=>ps(t.agent_name)}
    >
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.agent_name}</span>
            ${t.worker_name?i`<span class="monitor-sub">worker · ${t.worker_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.reason??t.summary??"이유가 기록되지 않았습니다."}</div>
        </div>
        <span class="monitor-pill ${ns(t.outcome==="failed"?"bad":t.outcome==="skipped"?"warn":"ok")}">${xh(t.outcome)}</span>
      </div>
      <div class="monitor-meta">
        <span>trigger · ${t.trigger??"unknown"}</span>
        ${t.checked_at?i`<span><${X} timestamp=${t.checked_at} /></span>`:null}
        <span>action · ${Sh(t.action_kind)}</span>
      </div>
      ${t.summary&&t.summary!==t.reason?i`<div class="monitor-focus">${t.summary}</div>`:null}
      ${t.failure_reason||t.decision_reason?i`<div class="monitor-footnote">
            ${t.failure_reason?`실패 이유: ${t.failure_reason}`:`판단 이유: ${t.decision_reason}`}
          </div>`:null}
    </button>
  `}function nl({row:t,testId:e}){return i`
    <button class="monitor-row ${t.tone} state-${t.state}" data-testid=${e} onClick=${()=>ps(t.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.name}</span>
            ${t.korean_name?i`<span class="monitor-sub">${t.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${ge} status=${t.status??"unknown"} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${bh(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.last_signal_at?i`<span>신호 <${X} timestamp=${t.last_signal_at} /></span>`:i`<span>최근 신호 없음</span>`}
        <span>${(t.active_task_count??0)>0?`활성 작업 ${t.active_task_count}개`:"활성 작업 없음"}</span>
        ${t.related_session_id?i`<span>세션 · ${t.related_session_id}</span>`:null}
        ${t.related_operation_id?i`<span>작전 · ${t.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${t.recent_output_preview&&t.recent_output_preview!==t.focus?i`<div class="monitor-footnote">최근 상세: ${t.recent_output_preview}</div>`:null}
    </button>
  `}function Mh({row:t}){const e=()=>{const a=yh(t.name);a&&Zc(a)},n=Gc(t.name,t.agent_name),s={name:t.name,koreanName:t.korean_name??null,runtimeLabel:n,emoji:t.emoji??null,tone:t.tone,statusRaw:t.status??null,statusLabel:ss(t.status),stateClass:t.state,stateLabel:kh(t.state),contextRatio:t.context_ratio??null,note:t.note,focus:t.focus,lastActivityAt:t.last_signal_at??null,lastActivityFallback:"최근 활동 없음",relatedSessionId:t.related_session_id??null,continuity:t.continuity??null,lifecycle:t.lifecycle??null,summary:t.continuity_summary??t.recent_output_preview??null,recentInput:t.recent_input_preview??null,recentOutput:t.recent_output_preview??null,recentTools:t.recent_tool_names??[],allowedTools:t.allowed_tool_names??[],routeSummary:t.skill_route_summary??null,auditSource:t.tool_audit_source??null,auditAt:t.tool_audit_at??null,disclosureLabel:"연속성 상세"};return i`<${Hc}
    variant="execution"
    model=${s}
    onClick=${e}
    testId="execution.continuity-card"
  />`}function Eh(){const t=ql.value,e=wl.value,n=Fl.value,s=Kl.value,a=Bl.value,o=Ul.value,l=Eo.value,c=Hl.value;Se.value&&!t.some(h=>h.id===Se.value)&&(Se.value=null),Ht.value&&!e.some(h=>h.session_id===Ht.value)&&(Ht.value=null),Wt.value&&!n.some(h=>h.operation_id===Wt.value)&&(Wt.value=null);const p=Se.value?t.find(h=>h.id===Se.value)??null:null,m=Ht.value?Ht.value:p?p.kind==="session"?p.target_id:p.linked_session_id??null:null,u=Wt.value?Wt.value:p?p.kind==="operation"?p.target_id:p.linked_operation_id??null:null,v=m?e.filter(h=>h.session_id===m):u?e.filter(h=>h.linked_operation_id===u):e,f=u?n.filter(h=>h.operation_id===u):m?n.filter(h=>{var S;return h.linked_session_id===m||h.operation_id===((S=v[0])==null?void 0:S.linked_operation_id)}):n,$=m||u?s.filter(h=>(m?h.related_session_id===m:!1)||(u?h.related_operation_id===u:!1)):s,C=m?l.filter(h=>h.related_session_id===m||h.tone!=="ok"):l,b=m?o.filter(h=>v.some(S=>S.member_names.includes(h.agent_name))):o,k=m||u?c.filter(h=>(m?h.related_session_id===m:!1)||(u?h.related_operation_id===u:!1)||h.tone!=="ok"):c;return i`
    <div class="agents-monitor">
      <${kt} surfaceId="execution" />
      <${Qa} />
      <${R}
        title="실행 대기열"
        class="section"
        semanticId="execution.queue"
        testId="execution.queue"
      >
        <div class="monitor-section-head">
          <h2 class="monitor-headline">지금 막힌 실행과 다음 인계</h2>
          <p class="monitor-subheadline">세션과 작전을 한 대기열로 보고, 어디를 먼저 개입 화면과 원인 화면으로 넘길지 판단합니다.</p>
        </div>
        <div class="monitor-alert-list">
          ${t.length===0?i`<div class="empty-state">지금은 막힌 실행이 없습니다.</div>`:t.map(h=>i`<${Ch} key=${h.id} item=${h} selected=${Se.value===h.id} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${R}
          title="영향받는 세션"
          class="section"
          semanticId="execution.sessions"
          testId="execution.session-briefs"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">영향받는 세션</h2>
            <p class="monitor-subheadline">대기열에서 고른 실행이 어떤 세션 목표와 실행 막힘을 갖는지 요약합니다.</p>
          </div>
          <div class="monitor-list">
            ${v.length===0?i`<div class="empty-state">선택된 실행과 연결된 세션이 없습니다.</div>`:v.map(h=>i`<${Ah} key=${h.session_id} brief=${h} selected=${Ht.value===h.session_id} />`)}
          </div>
        <//>

        <${R}
          title="영향받는 작전"
          class="section"
          semanticId="execution.operations"
          testId="execution.operation-briefs"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">영향받는 작전</h2>
            <p class="monitor-subheadline">지휘 평면 작전의 막힘과 다음 도구만 얇게 보여주고, 자세한 근거는 원인 화면으로 넘깁니다.</p>
          </div>
          <div class="monitor-list">
            ${f.length===0?i`<div class="empty-state">선택된 실행과 연결된 작전이 없습니다.</div>`:f.map(h=>i`<${Th} key=${h.operation_id} brief=${h} selected=${Wt.value===h.operation_id} />`)}
          </div>
        <//>

        <${R}
          title="Lodge Check-ins"
          class="section"
          semanticId="execution.lodge"
          testId="execution.lodge-checkins"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Lodge Check-ins</h2>
            <p class="monitor-subheadline">최근 lodge tick에서 누가 무엇을 허용받았고, 실제로 어떻게 행동했는지 먼저 보여줍니다.</p>
          </div>
          <${Ih} tick=${a} />
          <div class="monitor-list">
            ${b.length===0?i`<div class="empty-state">최근 lodge check-in 기록이 없습니다.</div>`:b.map(h=>i`<${Rh} key=${`${h.agent_name}-${h.checked_at??h.outcome}`} row=${h} />`)}
          </div>
        <//>

        <${R}
          title="작업 인력"
          class="section"
          semanticId="execution.worker_support"
          testId="execution.worker-support"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">지원 작업자</h2>
            <p class="monitor-subheadline">선택된 세션이나 작전에 연결된 작업자만 보이고, 전체 작업자 벽은 첫 화면을 차지하지 않게 합니다.</p>
          </div>
          <div class="monitor-list">
            ${$.length===0?i`<div class="empty-state">연결된 작업자가 없습니다.</div>`:$.map(h=>i`<${nl} key=${h.name} row=${h} testId="execution.worker-card" />`)}
          </div>
        <//>

        <${R}
          title="연속성"
          class="section"
          semanticId="execution.continuity"
          testId="execution.continuity"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">키퍼 연속성 요약</h2>
            <p class="monitor-subheadline">카드 제목은 keeper 이름이고, keeper-*-agent 형태의 runtime agent는 보조 라벨로만 표시합니다.</p>
          </div>
          <div class="monitor-list">
            ${C.length===0?i`<div class="empty-state">지금은 연속성 경고가 없습니다.</div>`:C.map(h=>i`<${Mh} key=${h.name} row=${h} />`)}
          </div>
        <//>

        <${R}
          title="오프라인 인력"
          class="section"
          semanticId="execution.offline"
          testId="execution.offline-workers"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">오프라인 작업자</h2>
            <p class="monitor-subheadline">빠진 작업자는 하단 보조 면으로 분리해 활성 실행 판단을 방해하지 않게 유지합니다.</p>
          </div>
          <div class="monitor-list">
            ${k.length===0?i`<div class="empty-state">지금은 오프라인 작업자가 없습니다.</div>`:k.map(h=>i`<${nl} key=${h.name} row=${h} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const po=g(null),mo=g(null),zn=g(!1);async function sl(){if(!zn.value){zn.value=!0,mo.value=null;try{po.value=await Eu()}catch(t){mo.value=t instanceof Error?t.message:String(t)}finally{zn.value=!1}}}function Lh(t){switch(t){case"essential":return"badge-essential";case"standard":return"badge-standard";default:return"badge-full"}}function Ph({items:t,maxCount:e}){return t.length===0?i`<p class="muted">No tool calls recorded yet.</p>`:i`
    <div class="tool-bar-chart">
      ${t.map(n=>{const s=e>0?n.call_count/e*100:0;return i`
          <div class="tool-bar-row" key=${n.name}>
            <span class="tool-bar-name">${n.name}</span>
            <span class="tool-bar-tier ${Lh(n.tier)}">${n.tier}</span>
            <div class="tool-bar-track">
              <div class="tool-bar-fill" style=${{width:`${s}%`}} />
            </div>
            <span class="tool-bar-count">${n.call_count}</span>
          </div>
        `})}
    </div>
  `}function zh({dist:t}){const e=t.full,n=e>0?(t.essential/e*100).toFixed(1):"0",s=e>0?(t.standard/e*100).toFixed(1):"0",a=e-t.standard,o=e>0?(a/e*100).toFixed(1):"0";return i`
    <div class="tier-dist">
      <div class="tier-dist-row">
        <span class="tier-dist-label badge-essential">Essential</span>
        <span class="tier-dist-count">${t.essential}</span>
        <span class="tier-dist-pct">${n}%</span>
      </div>
      <div class="tier-dist-row">
        <span class="tier-dist-label badge-standard">Standard</span>
        <span class="tier-dist-count">${t.standard}</span>
        <span class="tier-dist-pct">${s}%</span>
      </div>
      <div class="tier-dist-row">
        <span class="tier-dist-label badge-full">Full-only</span>
        <span class="tier-dist-count">${a}</span>
        <span class="tier-dist-pct">${o}%</span>
      </div>
    </div>
  `}function Nh(){const t=po.value,e=zn.value,n=mo.value;return nt(()=>{!po.value&&!zn.value&&sl()},[]),i`
    <div class="tool-metrics">
      <div class="tool-metrics-header">
        <h3 class="tool-metrics-title">Tool Usage</h3>
        <button
          class="control-btn ghost"
          onClick=${()=>void sl()}
          disabled=${e}
        >
          ${e?"Loading...":t?"Refresh":"Load"}
        </button>
      </div>

      ${n?i`<div class="tool-metrics-error">${n}</div>`:null}

      ${t?i`
        <div class="tool-metrics-summary">
          <div class="tool-metrics-stat">
            <span class="stat-value">${t.total_calls}</span>
            <span class="stat-label">Total Calls</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${t.distinct_tools_called}</span>
            <span class="stat-label">Distinct Tools</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${t.never_called_count}</span>
            <span class="stat-label">Never Called</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${t.registered_count}</span>
            <span class="stat-label">Registered (v2)</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${t.dispatch_v2_enabled?"ON":"OFF"}</span>
            <span class="stat-label">Dispatch v2</span>
          </div>
        </div>

        <div class="tool-metrics-sections">
          <div class="tool-metrics-section">
            <h4>Tier Distribution</h4>
            <${zh} dist=${t.tier_distribution} />
          </div>
          <div class="tool-metrics-section">
            <h4>Top 20 Tools</h4>
            <${Ph}
              items=${t.top_20}
              maxCount=${t.top_20.length>0?t.top_20[0].call_count:0}
            />
          </div>
        </div>
      `:e?null:i`
        <p class="muted">Click Load to fetch tool usage statistics.</p>
      `}
    </div>
  `}const _o=g(null),vo=g(null),Nn=g(!1),bn=g(""),zs=g("all"),$i=g(!1),hi=g(!1),yi=g(!0),bi=g(!0);async function al(){if(!Nn.value){Nn.value=!0,vo.value=null;try{_o.value=await Lu()}catch(t){vo.value=t instanceof Error?t.message:String(t)}finally{Nn.value=!1}}}function jh(t,e){const n=e.trim().toLowerCase();return n?[t.name,t.description,t.category,t.required_permission??"",t.visibility,t.lifecycle,t.implementationStatus,t.tier,t.canonicalName??"",t.replacement??"",t.reason??"",...t.doc_refs,...t.prompt_hints].join(" ").toLowerCase().includes(n):!0}function Ns(t,e="default"){return i`
    <span
      style=${{fontSize:"11px",color:e==="ok"?"#7dd3fc":e==="warn"?"#fbbf24":"#cbd5e1",background:e==="ok"?"rgba(14, 165, 233, 0.18)":e==="warn"?"rgba(245, 158, 11, 0.18)":"rgba(148, 163, 184, 0.16)",borderRadius:"999px",padding:"2px 8px"}}
    >
      ${t}
    </span>
  `}function Oh({item:t}){return i`
    <article class="tool-inventory-row">
      <div class="tool-inventory-head">
        <div>
          <div class="tool-inventory-name">${t.name}</div>
          <div class="tool-inventory-desc">${t.description}</div>
        </div>
        <div class="tool-inventory-badges">
          ${Ns(t.tier,t.tier==="essential"?"ok":t.tier==="standard"?"warn":"default")}
          ${Ns(t.visibility)}
          ${Ns(t.lifecycle,t.lifecycle==="deprecated"?"warn":"default")}
          ${Ns(t.implementationStatus)}
        </div>
      </div>
      <div class="tool-inventory-meta">
        <span>Category: <strong>${t.category}</strong></span>
        <span>Mode: <strong>${t.enabled_in_current_mode?"enabled":"disabled"}</strong></span>
        <span>Direct call: <strong>${t.direct_call_allowed?"allowed":"blocked"}</strong></span>
        <span>Permission: <strong>${t.required_permission??"none"}</strong></span>
      </div>
      ${t.reason?i`<div class="tool-inventory-reason">${t.reason}</div>`:null}
      <div class="tool-inventory-links">
        ${t.canonicalName?i`<span>Canonical: <strong>${t.canonicalName}</strong></span>`:null}
        ${t.replacement?i`<span>Replacement: <strong>${t.replacement}</strong></span>`:null}
        ${t.doc_refs.length>0?i`<span>Docs: <strong>${t.doc_refs.join(", ")}</strong></span>`:null}
      </div>
    </article>
  `}function Dh(){const t=_o.value,e=Nn.value,n=vo.value,s=(t==null?void 0:t.tool_inventory.tools)??[],a=(t==null?void 0:t.tool_usage)??null;nt(()=>{!_o.value&&!Nn.value&&al()},[]),nt(()=>{var $;if(D.value.tab!=="tools")return;const f=($=D.value.params.q)==null?void 0:$.trim();f&&f!==bn.value&&(bn.value=f)},[D.value.tab,D.value.params.q]);const o=Array.from(new Set(s.map(f=>f.category))).sort((f,$)=>f.localeCompare($)),l=s.filter(f=>!(!jh(f,bn.value)||zs.value!=="all"&&f.category!==zs.value||$i.value&&!f.enabled_in_current_mode||hi.value&&!f.direct_call_allowed||!yi.value&&f.visibility==="hidden"||!bi.value&&f.lifecycle==="deprecated")),c=s.length,p=s.filter(f=>f.enabled_in_current_mode).length,m=s.filter(f=>f.visibility==="hidden").length,u=s.filter(f=>f.lifecycle==="deprecated").length,v=s.filter(f=>f.direct_call_allowed).length;return i`
    <div>
      <${R} title="System Tool Inventory" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">전체 도구 inventory를 기본으로 보여줍니다</h2>
          <p class="monitor-subheadline">Allowed tools는 runtime allowlist이고, 여기서는 시스템이 가진 전체 도구 surface를 hidden/deprecated 포함 기준으로 봅니다.</p>
        </div>

        <div class="tool-inventory-summary">
          <div class="tool-inventory-stat">
            <span class="stat-value">${c}</span>
            <span class="stat-label">Total tools</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${p}</span>
            <span class="stat-label">Mode enabled</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${m}</span>
            <span class="stat-label">Hidden</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${u}</span>
            <span class="stat-label">Deprecated</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${v}</span>
            <span class="stat-label">Direct call</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${l.length}</span>
            <span class="stat-label">Filtered</span>
          </div>
        </div>

        <div class="tool-inventory-filters">
          <input
            class="control-input"
            type="text"
            placeholder="Search tools, docs, permission, replacement…"
            value=${bn.value}
            onInput=${f=>{bn.value=f.target.value}}
          />
          <select
            class="control-select"
            value=${zs.value}
            onChange=${f=>{zs.value=f.target.value}}
          >
            <option value="all">All categories</option>
            ${o.map(f=>i`<option value=${f}>${f}</option>`)}
          </select>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${$i.value}
              onChange=${f=>{$i.value=f.target.checked}}
            />
            <span>Enabled only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${hi.value}
              onChange=${f=>{hi.value=f.target.checked}}
            />
            <span>Direct-call only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${yi.value}
              onChange=${f=>{yi.value=f.target.checked}}
            />
            <span>Show hidden</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${bi.value}
              onChange=${f=>{bi.value=f.target.checked}}
            />
            <span>Show deprecated</span>
          </label>
          <button class="control-btn ghost" onClick=${()=>{al()}} disabled=${e}>
            ${e?"Refreshing…":"Refresh inventory"}
          </button>
        </div>

        ${n?i`<div class="tool-metrics-error">${n}</div>`:null}

        <div class="tool-inventory-list">
          ${l.length>0?l.map(f=>i`<${Oh} key=${f.name} item=${f} />`):i`<div class="empty-state">No tools matched the current filters.</div>`}
        </div>
      <//>

      <${R} title="Tool Usage" class="section">
        ${a?i`
              <div class="tool-inventory-usage-hint">
                Registered ${a.registered_count} · Distinct called ${a.distinct_tools_called} · Never called ${a.never_called_count}
              </div>
            `:null}
        <${Nh} />
      <//>
    </div>
  `}const Da=g("all"),qa=g("all"),fo=g(new Set);function qh(t){const e=new Set(fo.value);e.has(t)?e.delete(t):e.add(t),fo.value=e}const Sd=Rt(()=>{let t=Xe.value;return Da.value!=="all"&&(t=t.filter(e=>e.horizon===Da.value)),qa.value!=="all"&&(t=t.filter(e=>e.status===qa.value)),t}),wh=Rt(()=>{const t={short:[],mid:[],long:[]};for(const e of Sd.value){const n=t[e.horizon];n&&n.push(e)}return t}),Fh=Rt(()=>{const t=Array.from(Gl.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function Kh(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function lr(t){switch(t){case"short":return"단기";case"mid":return"중기";case"long":return"장기";default:return t}}function ea(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Bh(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function il(t){return t.toFixed(4)}function ol(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function Uh(t){switch(t){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function Hh(t){switch(t){case"active":return"진행 중";case"completed":return"완료";case"paused":return"일시정지";default:return"전체"}}function rl(t,e){return(t.priority??4)-(e.priority??4)}function Wh(t,e){const n=t.updated_at??t.created_at??"";return(e.updated_at??e.created_at??"").localeCompare(n)}function Gh(t,e){return t.length<=e?t:t.slice(0,e)+"..."}function Jh({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ea(t.horizon)}">
            ${lr(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${Kh(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${X} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${ge} status=${t.status} />
        <div class="goal-updated">
          <${X} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function ki({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return i`
    <${R} title="${lr(t)} 목표 (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${Jh} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function Yh(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">범위</label>
        ${["all","short","mid","long"].map(t=>i`
          <button
            class="goal-filter-btn ${Da.value===t?"active":""}"
            onClick=${()=>{Da.value=t}}
          >
            ${t==="all"?"전체":lr(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">상태</label>
        ${["all","active","completed","paused"].map(t=>i`
          <button
            class="goal-filter-btn ${qa.value===t?"active":""}"
            onClick=${()=>{qa.value=t}}
          >
            ${Hh(t)}
          </button>
        `)}
      </div>
    </div>
  `}function Xh(){const t=Xe.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return i`
    <div class="goal-summary">
      <div class="goal-summary-item">
        <div class="goal-summary-value">${t.length}</div>
        <div class="goal-summary-label">전체</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#4ade80">${e}</div>
        <div class="goal-summary-label">진행 중</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#888">${n}</div>
        <div class="goal-summary-label">완료</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ea("short")}">${s.short}</div>
        <div class="goal-summary-label">단기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ea("mid")}">${s.mid}</div>
        <div class="goal-summary-label">중기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ea("long")}">${s.long}</div>
        <div class="goal-summary-label">장기</div>
      </div>
    </div>
  `}function Vh({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length}개 도구: ${t.latest_tool_names.join(", ")}`:"아직 근거 없음";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${ge} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${il(t.baseline_metric)}</span>
          <span>현재 ${il(t.current_metric)}</span>
          <span class=${ol(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${ol(t)}
          </span>
          <span>Elapsed ${Bh(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"명시된 목표가 없습니다"}</div>
        ${t.stop_reason||t.error_message?i`
              <div class="planning-loop-footnote">
                ${t.error_message??t.stop_reason}
              </div>
            `:null}
        <div class="planning-loop-footnote">
          ${t.strict_mode?"엄격 근거 모드":"레거시"} · ${t.worker_engine??"엔진 정보 없음"} · ${n}
        </div>
        ${e?i`
              <div class="planning-loop-footnote">
                최근 반복 #${e.iteration}: ${e.changes||e.next_suggestion||"서술 정보 없음"}
              </div>
            `:i`<div class="planning-loop-footnote">반복 이력이 아직 없습니다</div>`}
      </div>
    </div>
  `}function xi({task:t}){const e=t.priority??4,n=e<=1?"p1":e===2?"p2":e===3?"p3":"p4",s=fo.value.has(t.id),a=!!t.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${Uh(e)}</span>
        <div class="kanban-card-title">${t.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>qh(t.id)}
        >
          ${s?t.description:Gh(t.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${t.created_at?i`<${X} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Qh(){const{todo:t,inProgress:e,done:n}=Yl.value,s=[...t].sort(rl),a=[...e].sort(rl),o=[...n].sort(Wh);return i`
    <${R} title="태스크 백로그" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>할 일</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">대기 중인 태스크가 없습니다</div>`:s.map(l=>i`<${xi} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>진행 중</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">진행 중인 태스크가 없습니다</div>`:a.map(l=>i`<${xi} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>완료</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">완료된 태스크가 없습니다</div>`:o.slice(0,20).map(l=>i`<${xi} key=${l.id} task=${l} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...외 ${o.length-20}개 더 있음</div>`:null}
        </div>
      </div>
    <//>
  `}function Zh(){const{todo:t,inProgress:e,done:n}=Yl.value,s=t.length+e.length+n.length,a=[...t,...e].filter(u=>(u.priority??4)<=2).length,o=wh.value,l=Fh.value,c=Xe.value.length>0,p=l.length>0,m=Lo.value;return i`
    <div>
      <${kt} surfaceId="planning" />

      <!-- Step 1: Task-based stats grid -->
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">전체 태스크</div>
          <div class="stat-value">${s}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">할 일</div>
          <div class="stat-value" style="color:#e0e0e0">${t.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">진행 중</div>
          <div class="stat-value" style="color:#fbbf24">${e.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">완료</div>
          <div class="stat-value" style="color:#4ade80">${n.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">높은 우선순위</div>
          <div class="stat-value" style="color:${a>0?"#f87171":"#888"}">${a}</div>
        </div>
      </div>

      <!-- Compact refresh toolbar -->
      <div class="planning-toolbar">
        <button
          class="control-btn secondary"
          onClick=${()=>{No(),nc()}}
          disabled=${Tn.value||In.value}
        >
          ${Tn.value||In.value?"새로고침 중...":"계획 데이터 새로고침"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${Qh} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          목표 파이프라인
          <span class="monitor-pill">${Xe.value.length}</span>
        </summary>
        <div>
          ${c?i`
            <${Xh} />
            <${Yh} />
            ${Tn.value&&Xe.value.length===0?i`<div class="loading-indicator">목표 불러오는 중...</div>`:Sd.value.length===0?i`<div class="empty-state">현재 필터에 맞는 목표가 없습니다</div>`:i`
                    <${ki} horizon="short" items=${o.short??[]} />
                    <${ki} horizon="mid" items=${o.mid??[]} />
                    <${ki} horizon="long" items=${o.long??[]} />
                  `}
          `:i`
            <div class="empty-state">
              정의된 목표가 없습니다. <code>masc_goal_upsert</code>로 목표를 만들 수 있습니다.
            </div>
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible" open=${p}>
        <summary>
          MDAL 루프
          <span class="monitor-pill">${l.length}</span>
        </summary>
        <div>
          ${In.value&&l.length===0?i`<div class="loading-indicator">MDAL 루프 불러오는 중...</div>`:l.length===0&&(m==="error"||Ve.value)?i`<div class="empty-state">MDAL 스냅샷을 불러오지 못했습니다${Ve.value?`: ${Ve.value}`:""}. 백엔드 상태를 확인하세요.</div>`:l.length===0?i`<div class="empty-state">가동 중인 루프가 없습니다. <code>masc_mdal_start</code>로 시작할 수 있습니다.</div>`:i`
                  <div class="planning-loop-list">
                    ${l.map(u=>i`<${Vh} key=${u.loop_id} loop=${u} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const wa=g(!1),jn=g(!1),Je=g(!1),me=g(""),On=g(""),go=g("open"),Ot=g(null),as=g(null),Fa=g(null),Ka=g(null),$o=g(!1);function is(t){return`${t.kind}:${t.id}`}function cr(){var n;const t=as.value,e=((n=Ot.value)==null?void 0:n.items)??[];return t?e.find(s=>is(s)===t)??null:null}function ty(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");return(e==null?void 0:e.trim())||"dashboard"}function ey(t){const e=t.trim().toLowerCase();return e==="open"||e==="pending"}function Cd(t){return!!(t.judgment_summary&&t.judgment_summary.trim())}function Ad(t){switch(go.value){case"needs_quorum":return t.filter(e=>e.kind==="consensus"&&(e.votes??0)<(e.quorum??0));case"ready":return t.filter(e=>{var n;return(n=e.guardrail_state)==null?void 0:n.ready_to_execute});case"needs_approval":return t.filter(e=>{var n,s;return((n=e.guardrail_state)==null?void 0:n.requires_human_gate)||!!((s=e.guardrail_state)!=null&&s.pending_confirm)});case"judge_offline":return t.filter(e=>!Cd(e));case"open":default:return t.filter(e=>ey(e.status))}}function ny(t){if(t==null)return"없음";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function ni(t){const e=(t||"").toLowerCase();return e.includes("reject")||e.includes("deny")||e.includes("closed")||e.includes("cancel")?"negative":e.includes("approve")||e.includes("support")||e.includes("open")||e.includes("ready")?"positive":"neutral"}function sy(t){return typeof t!="number"||Number.isNaN(t)?"확인 필요":`${Math.round(t*100)}%`}function kn(t){return"resolved_tool"in t||"payload_preview"in t||"reason"in t}async function Td(t){if(Fa.value=null,Ka.value=null,!!t){$o.value=!0,me.value="";try{t.kind==="debate"?Fa.value=await Sp(t.id):Ka.value=await Cp(t.id)}catch(e){me.value=e instanceof Error?e.message:"거버넌스 상세를 불러오지 못했습니다"}finally{$o.value=!1}}}async function ay(t){as.value=is(t),await Td(t)}async function pn(){var t;wa.value=!0,me.value="";try{const e=await Su();Ot.value=e;const n=Ad(e.items??[]),s=as.value,a=n.find(o=>is(o)===s)??n[0]??((t=e.items)==null?void 0:t[0])??null;as.value=a?is(a):null,await Td(a)}catch(e){me.value=e instanceof Error?e.message:"거버넌스 상태를 불러오지 못했습니다"}finally{wa.value=!1}}Dm(pn);async function ll(){const t=On.value.trim();if(t){jn.value=!0;try{const e=await xp(t);On.value="",j(e!=null&&e.id?`토론을 시작했습니다: ${e.id}`:"토론을 시작했습니다","success"),await pn()}catch(e){const n=e instanceof Error?e.message:"토론 시작에 실패했습니다";me.value=n,j(n,"error")}finally{jn.value=!1}}}async function cl(t){var o,l;const e=cr(),n=(o=e==null?void 0:e.guardrail_state)==null?void 0:o.pending_confirm,s=n==null?void 0:n.confirm_token;if(!s)return;const a=((l=n==null?void 0:n.actor)==null?void 0:l.trim())||ty();Je.value=!0;try{await Al(a,s,t),j(t==="confirm"?"액션을 승인했습니다":"액션을 거부했습니다","success"),await pn()}catch(c){const p=c instanceof Error?c.message:"대기 중인 액션 처리에 실패했습니다";me.value=p,j(p,"error")}finally{Je.value=!1}}function iy(){var n,s,a,o,l,c;const t=(n=Ot.value)==null?void 0:n.summary,e=(s=Ot.value)==null?void 0:s.judge;return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">열린 토론</span>
        <strong>${(t==null?void 0:t.debates_open)??((o=(a=Ot.value)==null?void 0:a.debates)==null?void 0:o.length)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">합의 세션</span>
        <strong>${(t==null?void 0:t.sessions_active)??((c=(l=Ot.value)==null?void 0:l.sessions)==null?void 0:c.length)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">정족수 부족</span>
        <strong>${(t==null?void 0:t.sessions_without_quorum)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">실행 준비</span>
        <strong>${(t==null?void 0:t.ready_to_execute)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">판정기</span>
        <strong>${(e==null?void 0:e.judge_online)??(t==null?void 0:t.judge_online)?"온라인":"오프라인"}</strong>
      </div>
    </div>
  `}function oy(){return i`
    <${R} title="거버넌스 콘솔" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="토론 주제를 입력하세요..."
            value=${On.value}
            onInput=${t=>{On.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&ll()}}
            disabled=${jn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${ll}
            disabled=${jn.value||On.value.trim()===""}
          >
            ${jn.value?"시작 중...":"토론 시작"}
          </button>
          <button class="control-btn ghost" onClick=${pn} disabled=${wa.value}>
            ${wa.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
        <div class="governance-filter-row">
          ${[["open","열림"],["needs_quorum","정족수 부족"],["ready","준비됨"],["needs_approval","승인 필요"],["judge_offline","판정기 오프라인"]].map(([t,e])=>i`
            <button
              class="control-btn ${go.value===t?"is-active":"ghost"}"
              onClick=${async()=>{go.value=t,await pn()}}
            >
              ${e}
            </button>
          `)}
        </div>
        ${me.value?i`<div class="council-error">${me.value}</div>`:null}
      </div>
    <//>
  `}function ry(){var e;const t=Ad(((e=Ot.value)==null?void 0:e.items)??[]);return i`
    <${R} title="의사결정 수신함" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${t.length===0?i`
              <div class="empty-state">
                지금 필터에 맞는 토론이나 합의 세션이 없습니다.
              </div>
            `:t.map(n=>{var a,o;const s=as.value===is(n);return i`
                <button
                  class="council-row governance-decision-row ${s?"selected":""}"
                  onClick=${()=>ay(n)}
                >
                  <div class="council-row-main">
                    <div class="governance-row-head">
                      <span class="governance-kind">${n.kind}</span>
                      <span class="council-topic">${n.topic}</span>
                    </div>
                    <div class="council-sub">
                      <span>${n.truth_summary||"사실 요약이 아직 없습니다"}</span>
                      ${n.last_activity_at?i`<span><${X} timestamp=${n.last_activity_at} /></span>`:null}
                    </div>
                    <div class="governance-chip-row">
                      ${(a=n.guardrail_state)!=null&&a.requires_human_gate?i`<span class="governance-chip warn">승인 필요</span>`:null}
                      ${(o=n.guardrail_state)!=null&&o.ready_to_execute?i`<span class="governance-chip ok">준비됨</span>`:null}
                      ${n.kind==="consensus"&&(n.votes??0)<(n.quorum??0)?i`<span class="governance-chip warn">정족수 부족</span>`:null}
                      ${Cd(n)?null:i`<span class="governance-chip dim">판정기 오프라인</span>`}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${ni(n.status)}">${n.status}</span>
                    ${n.kind==="consensus"?i`<span class="governance-vote-meter">${n.votes??0}/${n.quorum??0}</span>`:i`<span class="governance-vote-meter">${n.evidence_refs.length} refs</span>`}
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function ly({argument:t}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${ni(t.position)}">${t.position}</span>
        <strong>${t.agent}</strong>
        ${t.created_at?i`<span><${X} timestamp=${t.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${t.content}</div>
      <div class="governance-chip-row">
        ${t.evidence.map(e=>i`<span class="governance-chip">${e}</span>`)}
        ${t.reply_to!=null?i`<span class="governance-chip">답글 #${t.reply_to}</span>`:null}
        ${t.mentions.map(e=>i`<span class="governance-chip">@${e}</span>`)}
        ${t.archetype?i`<span class="governance-chip dim">${t.archetype}</span>`:null}
      </div>
    </div>
  `}function cy({vote:t}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${ni(t.decision)}">${t.decision}</span>
        <strong>${t.agent}</strong>
        ${t.timestamp?i`<span><${X} timestamp=${t.timestamp} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${t.reason||"기록된 이유가 없습니다."}</div>
      <div class="governance-chip-row">
        ${t.weight!=null?i`<span class="governance-chip">가중치 ${t.weight}</span>`:null}
        ${t.archetype?i`<span class="governance-chip dim">${t.archetype}</span>`:null}
      </div>
    </div>
  `}function dy(){const t=cr(),e=Fa.value,n=Ka.value;return i`
    <${R}
      title=${t?`${t.kind==="debate"?"토론":"합의"} 상세`:"의사결정 상세"}
      class="section"
      semanticId="governance.detail"
    >
      ${$o.value?i`<div class="loading-indicator">거버넌스 상세 불러오는 중...</div>`:t?t.kind==="debate"&&e?i`
                <div class="governance-detail-head">
                  <div>
                    <h3>${e.debate.topic}</h3>
                    <div class="council-sub">
                      <span>${e.debate.id}</span>
                      <span>${e.debate.status}</span>
                      ${e.debate.created_at?i`<span><${X} timestamp=${e.debate.created_at} /></span>`:null}
                    </div>
                  </div>
                  <div class="governance-balance-grid">
                    <span class="governance-balance"><strong>${e.summary.support_count}</strong> support</span>
                    <span class="governance-balance"><strong>${e.summary.oppose_count}</strong> oppose</span>
                    <span class="governance-balance"><strong>${e.summary.neutral_count}</strong> neutral</span>
                    <span class="governance-balance"><strong>${e.summary.total_arguments}</strong> total</span>
                  </div>
                </div>
                ${e.summary.summary_text?i`<div class="governance-summary-callout">${e.summary.summary_text}</div>`:null}
                <div class="governance-ledger">
                  ${e.arguments.length===0?i`<div class="empty-state">기록된 토론이 아직 없습니다.</div>`:e.arguments.map(s=>i`<${ly} key=${s.index} argument=${s} />`)}
                </div>
              `:t.kind==="consensus"&&n?i`
                  <div class="governance-detail-head">
                    <div>
                      <h3>${n.session.topic}</h3>
                      <div class="council-sub">
                        <span>${n.session.id}</span>
                        <span>${n.session.state}</span>
                      <span>시작자 ${n.session.initiator}</span>
                        ${n.session.created_at?i`<span><${X} timestamp=${n.session.created_at} /></span>`:null}
                      </div>
                    </div>
                    <div class="governance-balance-grid">
                      <span class="governance-balance"><strong>${n.summary.approve_count}</strong> approve</span>
                      <span class="governance-balance"><strong>${n.summary.reject_count}</strong> reject</span>
                      <span class="governance-balance"><strong>${n.summary.abstain_count}</strong> abstain</span>
                      <span class="governance-balance"><strong>${n.session.quorum}</strong> quorum</span>
                    </div>
                  </div>
                  ${n.summary.result?i`<div class="governance-summary-callout">${n.summary.result}</div>`:null}
                  <div class="governance-ledger">
                    ${n.votes.length===0?i`<div class="empty-state">기록된 표결이 아직 없습니다.</div>`:n.votes.map(s=>i`<${cy} key=${s.agent+s.timestamp} vote=${s} />`)}
                  </div>
                `:i`<div class="empty-state">이 의사결정의 상세를 아직 읽을 수 없습니다.</div>`:i`<div class="empty-state">사실 계층과 판단을 보려면 의사결정 항목을 고르세요.</div>`}
    <//>
  `}function dl({title:t,route:e}){if(!e)return null;const n=kn(e)?e.resolved_tool:e.delegated_tool,s=kn(e)?e.target_type:null,a=kn(e)?e.target_id:null,o=kn(e)?e.reason:null,l=kn(e)?e.payload_preview:null;return i`
    <div class="governance-side-block">
      <h4>${t}</h4>
      <div class="council-sub">
        ${n?i`<span>도구 ${n}</span>`:null}
        ${"action_type"in e&&e.action_type?i`<span>액션 ${e.action_type}</span>`:null}
        ${"confirmation_state"in e&&e.confirmation_state?i`<span>${e.confirmation_state}</span>`:null}
        ${"created_at"in e&&e.created_at?i`<span><${X} timestamp=${e.created_at} /></span>`:null}
      </div>
      ${s?i`<div class="governance-side-line">대상 ${s}${a?`:${a}`:""}</div>`:null}
      ${o?i`<div class="governance-side-line">${o}</div>`:null}
      ${l?i`<pre class="council-detail governance-preview">${ny(l)}</pre>`:null}
    </div>
  `}function uy(){var c,p,m;const t=cr(),e=Fa.value,n=Ka.value,s=(e==null?void 0:e.context)??(n==null?void 0:n.context)??(t==null?void 0:t.context),a=(e==null?void 0:e.judgment)??(n==null?void 0:n.judgment),o=t==null?void 0:t.guardrail_state,l=(c=Ot.value)==null?void 0:c.judge;return i`
    <div class="governance-side-column">
      <${R} title="이유 / 가드레일" class="section" semanticId="governance.guardrail">
        ${t?i`
              <div class="governance-side-block">
                <h4>판정기</h4>
                <div class="council-sub">
                  <span>${l!=null&&l.judge_online?"온라인":"오프라인"}</span>
                  ${l!=null&&l.model_used?i`<span>${l.model_used}</span>`:null}
                  ${l!=null&&l.generated_at?i`<span><${X} timestamp=${l.generated_at} /></span>`:null}
                </div>
                ${t.judgment_summary?i`<div class="governance-summary-callout">${t.judgment_summary}</div>`:i`<div class="governance-side-line">현재 LLM 판단이 없어 사실 계층만 보여줍니다.</div>`}
                <div class="council-sub">
                  <span>신뢰도 ${sy(t.confidence)}</span>
                  ${a!=null&&a.keeper_name?i`<span>${a.keeper_name}</span>`:null}
                </div>
              </div>

              <${dl} title="추천 경로" route=${t.recommended_action} />
              <${dl} title="실행된 경로" route=${t.executed_route} />

              <div class="governance-side-block">
                <h4>가드레일 상태</h4>
                <div class="council-sub">
                  <span>${o!=null&&o.requires_human_gate?"사람 승인 필요":"사람 승인 없음"}</span>
                  ${o!=null&&o.ready_to_execute?i`<span>실행 준비됨</span>`:null}
                </div>
                ${o!=null&&o.pending_confirm?i`
                      <div class="governance-side-line">
                        대기 중 ${o.pending_confirm.action_type||"액션"}
                        ${o.pending_confirm.target_type?` · ${o.pending_confirm.target_type}`:""}
                      </div>
                      <div class="governance-action-row">
                        <button
                          class="control-btn secondary"
                          onClick=${()=>cl("confirm")}
                          disabled=${Je.value}
                        >
                          ${Je.value?"처리 중...":"승인"}
                        </button>
                        <button
                          class="control-btn ghost"
                          onClick=${()=>cl("deny")}
                          disabled=${Je.value}
                        >
                          ${Je.value?"처리 중...":"거부"}
                        </button>
                      </div>
                    `:i`<div class="governance-side-line">이 의사결정에 대기 중인 사람 승인은 없습니다.</div>`}
              </div>
            `:i`<div class="empty-state">판단과 경로를 보려면 의사결정을 고르세요.</div>`}
      <//>

      <${R} title="맥락" class="section" semanticId="governance.context">
        ${t?i`
              <div class="governance-side-block">
                <div class="governance-chip-row">
                  ${s!=null&&s.board_post_id?i`<span class="governance-chip">board ${s.board_post_id}</span>`:null}
                  ${s!=null&&s.task_id?i`<span class="governance-chip">task ${s.task_id}</span>`:null}
                  ${s!=null&&s.operation_id?i`<span class="governance-chip">작전 ${s.operation_id}</span>`:null}
                  ${s!=null&&s.team_session_id?i`<span class="governance-chip">session ${s.team_session_id}</span>`:null}
                </div>
                ${t.related_agents.length>0?i`
                      <div class="governance-side-line">관련 에이전트</div>
                      <div class="governance-chip-row">
                        ${t.related_agents.map(u=>i`<span class="governance-chip dim">${u}</span>`)}
                      </div>
                    `:i`<div class="governance-side-line">명시적으로 연결된 맥락 기록이 없습니다.</div>`}
                ${t.evidence_refs.length>0?i`
                      <div class="governance-side-line">근거 참조</div>
                      <div class="governance-chip-row">
                        ${t.evidence_refs.map(u=>i`<span class="governance-chip">${u}</span>`)}
                      </div>
                    `:null}
              </div>
          `:i`<div class="empty-state">선택된 맥락이 없습니다.</div>`}
      <//>

      <${R} title="최근 활동" class="section" semanticId="governance.activity">
        <div class="governance-activity-list">
          ${(((p=Ot.value)==null?void 0:p.activity)??[]).slice(0,8).map(u=>i`
            <div class="governance-activity-row">
              <div class="governance-ledger-head">
                <span class="governance-badge ${ni(u.kind)}">${u.kind}</span>
                ${u.actor?i`<strong>${u.actor}</strong>`:null}
                ${u.created_at?i`<span><${X} timestamp=${u.created_at} /></span>`:null}
              </div>
              <div class="governance-ledger-body">${u.summary||u.topic||"활동이 기록되었습니다."}</div>
            </div>
          `)}
          ${(((m=Ot.value)==null?void 0:m.activity)??[]).length===0?i`<div class="empty-state">기록된 거버넌스 활동이 없습니다.</div>`:null}
        </div>
      <//>
    </div>
  `}function py(){return nt(()=>{pn()},[]),i`
    <div>
      <${kt} surfaceId="governance" />
      <${iy} />
      <${oy} />
      <div class="governance-layout">
        <${ry} />
        <${dy} />
        <${uy} />
      </div>
    </div>
  `}const we=g(""),Si=g("ability_check"),Ci=g("10"),Ai=g("12"),js=g(""),Os=g("idle"),ee=g(""),Ds=g("keeper-late"),Ti=g("player"),Ii=g(""),St=g("idle"),Ri=g(null),qs=g(""),Mi=g(""),Ei=g("player"),Li=g(""),Pi=g(""),zi=g(""),Dn=g("20"),Ni=g("20"),ji=g(""),ws=g("idle"),ho=g(null),Id=g("overview"),Oi=g("all"),Di=g("all"),qi=g("all"),my=12e4,si=g(null),ul=g(Date.now());function _y(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function vy(t,e){return e>0?Math.round(t/e*100):0}const fy={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},gy={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Fs(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function $y(t){const e=t.trim().toLowerCase();return fy[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function hy(t){const e=t.trim().toLowerCase();return gy[e]??"상황에 따라 선택되는 전술 액션입니다."}function ht(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function zt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function os(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const yy=new Set(["str","dex","con","int","wis","cha"]);function by(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!_(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const l=a.trim();if(l){if(typeof o=="number"&&Number.isFinite(o)){s[l]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const c=Number.parseFloat(o.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function ky(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(Dn.value.trim(),10);Number.isFinite(s)&&s>n&&(Dn.value=String(n))}function yo(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function xy(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Sy(t){Id.value=t}function Rd(t){const e=si.value;return e==null||e<=t}function Cy(t){const e=si.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Ba(){si.value=null}function Md(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Ay(t,e){Md(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(si.value=Date.now()+my,j("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function na(t){return Rd(t)?(j("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function bo(t,e,n){return Md([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Ty({hp:t,max:e}){const n=vy(t,e),s=_y(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Iy({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Ry({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Ed({actor:t}){var p,m,u,v;const e=(p=t.archetype)==null?void 0:p.trim(),n=(m=t.persona)==null?void 0:m.trim(),s=(u=t.portrait)==null?void 0:u.trim(),a=(v=t.background)==null?void 0:v.trim(),o=t.traits??[],l=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([f,$])=>Number.isFinite($)).filter(([f])=>!yy.has(f.toLowerCase()));return i`
    <div class="trpg-actor">
      ${s?i`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${f=>{const $=f.target;$&&($.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${ge} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Ry} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Ty} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Iy} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${Fs(e)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([f,$])=>i`
                <span class="trpg-custom-stat-chip">${Fs(f)} ${$}</span>
              `)}
            </div>
          </div>
        `:null}
      ${o.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${o.map(f=>i`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Fs(f)}</span>
                  <span class="trpg-annot-desc">${$y(f)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${l.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${l.map(f=>i`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Fs(f)}</span>
                  <span class="trpg-annot-desc">${hy(f)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function My({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function Ld({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${xy(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${yo(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${X} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Ey({events:t}){const e="__none__",n=Oi.value,s=Di.value,a=qi.value,o=Array.from(new Set(t.map(yo).map(v=>v.trim()).filter(v=>v!==""))).sort((v,f)=>v.localeCompare(f)),l=Array.from(new Set(t.map(v=>(v.type??"").trim()).filter(v=>v!==""))).sort((v,f)=>v.localeCompare(f)),c=t.some(v=>(v.type??"").trim()===""),p=Array.from(new Set(t.map(v=>(v.phase??"").trim()).filter(v=>v!==""))).sort((v,f)=>v.localeCompare(f)),m=t.some(v=>(v.phase??"").trim()===""),u=t.filter(v=>{if(n!=="all"&&yo(v)!==n)return!1;const f=(v.type??"").trim(),$=(v.phase??"").trim();if(s===e){if(f!=="")return!1}else if(s!=="all"&&f!==s)return!1;if(a===e){if($!=="")return!1}else if(a!=="all"&&$!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${v=>{Oi.value=v.target.value}}>
          <option value="all">all</option>
          ${o.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${v=>{Di.value=v.target.value}}>
          <option value="all">all</option>
          ${c?i`<option value=${e}>(none)</option>`:null}
          ${l.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${v=>{qi.value=v.target.value}}>
          <option value="all">all</option>
          ${m?i`<option value=${e}>(none)</option>`:null}
          ${p.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Oi.value="all",Di.value="all",qi.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${u.length} / 전체 ${t.length}
      </span>
    </div>
    <${Ld} events=${u.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Ly({outcome:t}){if(!t)return null;const e=o=>{const l=o.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function Pd({state:t}){const e=t.history??[];return e.length===0?null:i`
    <div class="trpg-round-list">
      ${e.slice(-10).map(n=>i`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
  `}function Py({state:t,nowMs:e}){var m;const n=Jt.value||((m=t.session)==null?void 0:m.room)||"",s=Os.value,a=t.party??[];if(!a.find(u=>u.id===we.value)&&a.length>0){const u=a[0];u&&(we.value=u.id)}const l=async()=>{var v,f;if(!n){j("Room ID가 비어 있습니다.","error");return}if(!na(e))return;const u=((v=t.current_round)==null?void 0:v.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(bo("라운드 실행",n,u)){Os.value="running";try{const $=await pp(n);ho.value=$,Os.value="ok";const C=_($.summary)?$.summary:null,b=C?os(C,"advanced",!1):!1,k=C?ht(C,"progress_reason",""):"";j(b?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${k?`: ${k}`:""}`,b?"success":"warning"),re()}catch($){ho.value=null,Os.value="error";const C=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";j(C,"error")}finally{Ba()}}},c=async()=>{var v,f;if(!n||!na(e))return;const u=((v=t.current_round)==null?void 0:v.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(bo("턴 강제 진행",n,u))try{await vp(n),j("턴을 다음 단계로 이동했습니다.","success"),re()}catch{j("턴 이동에 실패했습니다.","error")}finally{Ba()}},p=async()=>{if(!n||!na(e))return;const u=we.value.trim();if(!u){j("먼저 Actor를 선택하세요.","warning");return}const v=Number.parseInt(Ci.value,10),f=Number.parseInt(Ai.value,10);if(Number.isNaN(v)||Number.isNaN(f)){j("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(js.value,10),C=js.value.trim()===""||Number.isNaN($)?void 0:$;try{await _p({roomId:n,actorId:u,action:Si.value.trim()||"ability_check",statValue:v,dc:f,rawD20:C}),j("주사위 판정을 기록했습니다.","success"),re()}catch{j("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${u=>{Jt.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${we.value}
            onChange=${u=>{we.value=u.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(u=>i`<option value=${u.id}>${u.name} (${u.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${Si.value}
              onInput=${u=>{Si.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Ci.value}
              onInput=${u=>{Ci.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ai.value}
              onInput=${u=>{Ai.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${js.value}
              onInput=${u=>{js.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&p()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${p}>Roll</button>
            <button
              class="trpg-run-btn recommend"
              onClick=${l}
              disabled=${s==="running"}
            >
              ${s==="running"?"실행 중...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${c}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${s!=="idle"?i`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function zy({state:t}){var a;const e=Jt.value||((a=t.session)==null?void 0:a.room)||"",n=ws.value,s=async()=>{if(!e){j("Room ID가 비어 있습니다.","warning");return}const o=qs.value.trim(),l=Mi.value.trim();if(!l&&!o){j("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Dn.value.trim(),10),p=Number.parseInt(Ni.value.trim(),10),m=Number.isFinite(p)?Math.max(1,p):20,u=Number.isFinite(c)?Math.max(0,Math.min(m,c)):m;let v={};try{v=by(ji.value)}catch(f){j(f instanceof Error?f.message:"능력치 JSON 오류","error");return}ws.value="spawning";try{const f=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await fp(e,{actor_id:o||void 0,name:l||void 0,role:Ei.value,idempotencyKey:f,portrait:Pi.value.trim()||void 0,background:zi.value.trim()||void 0,hp:u,max_hp:m,alive:u>0,stats:Object.keys(v).length>0?v:void 0}),C=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!C)throw new Error("생성 응답에 actor_id가 없습니다.");const b=Li.value.trim();b&&await gp(e,C,b),we.value=C,ee.value=C,o||(qs.value=""),ws.value="ok",j(`Actor 생성 완료: ${C}`,"success"),await re()}catch(f){ws.value="error",j(f instanceof Error?f.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Mi.value}
            onInput=${o=>{Mi.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ei.value}
            onChange=${o=>{Ei.value=o.target.value}}
          >
            <option value="player">player</option>
            <option value="npc">npc</option>
            <option value="dm">dm</option>
          </select>
        </div>
        <div class="trpg-control-field">
          <label>Keeper (optional)</label>
          <input
            id="trpg-spawn-keeper-input"
            name="trpg-spawn-keeper-input"
            type="text"
            value=${Li.value}
            onInput=${o=>{Li.value=o.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn recommend" onClick=${s} disabled=${n==="spawning"}>
              ${n==="spawning"?"Spawning...":"Spawn Actor"}
            </button>
          </div>
        </div>
      </div>

      <details class="trpg-control-details">
        <summary>상세 입력 (선택)</summary>
        <div class="trpg-control-grid">
          <div class="trpg-control-field">
            <label>Actor ID (optional)</label>
            <input
              id="trpg-spawn-actor-id-input"
              name="trpg-spawn-actor-id-input"
              type="text"
              value=${qs.value}
              onInput=${o=>{qs.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Pi.value}
              onInput=${o=>{Pi.value=o.target.value}}
              placeholder="https://.../portrait.png"
            />
          </div>
          <div class="trpg-control-field">
            <label>HP</label>
            <input
              id="trpg-spawn-hp-input"
              name="trpg-spawn-hp-input"
              type="number"
              min="0"
              value=${Dn.value}
              onInput=${o=>{Dn.value=o.target.value}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field">
            <label>Max HP</label>
            <input
              id="trpg-spawn-max-hp-input"
              name="trpg-spawn-max-hp-input"
              type="number"
              min="1"
              value=${Ni.value}
              onInput=${o=>{const l=o.target.value;Ni.value=l,ky(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${zi.value}
              onInput=${o=>{zi.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${ji.value}
              onInput=${o=>{ji.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Ny({state:t,nowMs:e}){var f;const n=Jt.value||((f=t.session)==null?void 0:f.room)||"",s=t.join_gate,a=Ri.value,o=_(a)?a:null,l=(t.party??[]).filter($=>$.role!=="dm"),c=ee.value.trim(),p=l.some($=>$.id===c),m=p?c:c?"__manual__":"",u=async()=>{const $=ee.value.trim(),C=Ds.value.trim();if(!n||!$){j("Room/Actor가 필요합니다.","warning");return}St.value="checking";try{const b=await $p(n,$,C||void 0);Ri.value=b,St.value="ok",j("참가 가능 여부를 갱신했습니다.","success")}catch(b){St.value="error";const k=b instanceof Error?b.message:"참가 가능 여부 확인에 실패했습니다.";j(k,"error")}},v=async()=>{var h,S;const $=ee.value.trim(),C=Ds.value.trim(),b=Ii.value.trim();if(!n||!$||!C){j("Room/Actor/Keeper가 필요합니다.","warning");return}if(!na(e))return;const k=((h=t.current_round)==null?void 0:h.phase)??((S=t.session)==null?void 0:S.status)??"unknown";if(bo("Mid-Join 승인 요청",n,k)){St.value="requesting";try{const E=await hp({room_id:n,actor_id:$,keeper_name:C,role:Ti.value,...b?{name:b}:{}});Ri.value=E;const M=_(E)?os(E,"granted",!1):!1,P=_(E)?ht(E,"reason_code",""):"";M?j("Mid-Join이 승인되었습니다.","success"):j(`Mid-Join이 거절되었습니다${P?`: ${P}`:""}`,"warning"),St.value=M?"ok":"error",re()}catch(E){St.value="error";const M=E instanceof Error?E.message:"Mid-Join 요청에 실패했습니다.";j(M,"error")}finally{Ba()}}};return i`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${s!=null&&s.phase_open?"OPEN":"CLOSED"}</strong>
        ${s!=null&&s.window?i`<span style="margin-left:8px;">(${s.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(s==null?void 0:s.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <select
            value=${m}
            onChange=${$=>{const C=$.target.value;if(C==="__manual__"){(p||!c)&&(ee.value="");return}ee.value=C}}
          >
            <option value="">Actor 선택</option>
            ${l.map($=>i`
              <option value=${$.id}>${$.name} (${$.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${m==="__manual__"?i`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${ee.value}
                onInput=${$=>{ee.value=$.target.value}}
                placeholder="player-xyz"
                style="margin-top:6px;"
              />
            `:null}
        </div>
        <div class="trpg-control-field">
          <label>Keeper</label>
          <input
            id="trpg-join-keeper-input"
            name="trpg-join-keeper-input"
            type="text"
            value=${Ds.value}
            onInput=${$=>{Ds.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ti.value}
            onChange=${$=>{Ti.value=$.target.value}}
          >
            <option value="player">player</option>
            <option value="npc">npc</option>
            <option value="dm">dm</option>
          </select>
        </div>
        <div class="trpg-control-field">
          <label>Name (optional)</label>
          <input
            id="trpg-join-name-input"
            name="trpg-join-name-input"
            type="text"
            value=${Ii.value}
            onInput=${$=>{Ii.value=$.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${u} disabled=${St.value==="checking"||St.value==="requesting"}>
              ${St.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${v} disabled=${St.value==="checking"||St.value==="requesting"}>
              ${St.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${os(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${zt(o,"effective_score",0)}/${zt(o,"required_points",0)}</span>
            ${ht(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${ht(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function zd({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Nd({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function jd(){const t=ho.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=_(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(_).slice(-8),o=t.canon_check,l=_(o)?o:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(P=>typeof P=="string").slice(0,3):[],p=l&&Array.isArray(l.violations)?l.violations.filter(P=>typeof P=="string").slice(0,3):[],m=n?os(n,"advanced",!1):!1,u=n?ht(n,"progress_reason",""):"",v=n?ht(n,"progress_detail",""):"",f=n?zt(n,"player_successes",0):0,$=n?zt(n,"player_required_successes",0):0,C=n?os(n,"dm_success",!1):!1,b=n?zt(n,"timeouts",0):0,k=n?zt(n,"unavailable",0):0,h=n?zt(n,"reprompts",0):0,S=n?zt(n,"npc_attacks",0):0,E=n?zt(n,"keeper_timeout_sec",0):0,M=n?zt(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${m?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${m?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${C?"DM ok":"DM stalled"} / players ${f}/${$}
          </span>
        </div>
        ${u?i`<div style="margin-top:4px; font-size:12px;">${u}</div>`:null}
        ${v?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${v}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${b}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${h}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${E||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${M}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(P=>{const W=ht(P,"status","unknown"),I=ht(P,"actor_id","-"),G=ht(P,"role","-"),V=ht(P,"reason",""),it=ht(P,"action_type",""),z=ht(P,"reply","");return i`
                <div class="trpg-round-item ${W.includes("fallback")||W.includes("timeout")?"failed":"active"}">
                  <span>${I} (${G})</span>
                  <span style="margin-left:auto; font-size:11px;">${W}</span>
                  ${it?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${it}</div>`:null}
                  ${V?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${V}</div>`:null}
                  ${z?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${z.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${ht(l,"status","unknown")}</strong>
            </div>
            ${p.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${p.map(P=>i`<div>violation: ${P}</div>`)}
                </div>`:null}
            ${c.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(P=>i`<div>warning: ${P}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function jy({state:t,nowMs:e}){var l,c,p;const n=Jt.value||((l=t.session)==null?void 0:l.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((p=t.session)==null?void 0:p.status)??"unknown",a=Rd(e),o=Cy(e);return i`
    <${R} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${o}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>Ay(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{Ba(),j("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Oy({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Sy(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Dy({state:t}){const e=t.party??[],n=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${R} title="관전 가이드" semanticId="lab.trpg">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${R} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${Ld} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${R} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${My} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${R} title="현재 라운드" semanticId="lab.trpg">
          <${Nd} state=${t} />
        <//>

        <${R} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${zd} state=${t} />
        <//>

        <${R} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>i`<${Ed} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?i`
            <${R} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Pd} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function qy({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${R} title=${`이벤트 타임라인 (${e.length})`}>
          <${Ey} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${R} title="최근 라운드 결과" semanticId="lab.trpg">
          <${jd} />
        <//>

        <${R} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${Nd} state=${t} />
        <//>
      </div>
    </div>
  `}function wy({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${jy} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${R} title="조작 패널" semanticId="lab.trpg">
            <${Py} state=${t} nowMs=${e} />
          <//>

          <${R} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${zy} state=${t} />
          <//>

          <${R} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${Ny} state=${t} nowMs=${e} />
          <//>

          <${R} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${jd} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${R} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${zd} state=${t} />
          <//>

          <${R} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${Ed} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?i`
              <${R} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Pd} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Fy(){var c,p,m,u,v;const t=Wl.value,e=Vi.value;if(nt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const f=window.setInterval(()=>{ul.value=Date.now()},1e3);return()=>{window.clearInterval(f)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>re()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,o=Id.value,l=ul.value;return i`
    <div>
      <${kt} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Jt.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((p=t.current_round)==null?void 0:p.phase)??((m=t.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>re()}>새로고침</button>
      </div>

      <${Ly} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((u=t.session)==null?void 0:u.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((v=t.current_round)==null?void 0:v.round_number)??0}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Party</div>
          <div class="stat-value">${n.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Events</div>
          <div class="stat-value">${s.length}</div>
        </div>
      </div>

      <${Oy} active=${o} />

      ${o==="overview"?i`<${Dy} state=${t} />`:o==="timeline"?i`<${qy} state=${t} />`:i`<${wy} state=${t} nowMs=${l} />`}
    </div>
  `}function Ky(){return i`
    <div>
      <${kt} surfaceId="lab" />
      <${R} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${R} title="TRPG" class="section" semanticId="lab.trpg">
        <${Fy} />
      <//>
    </div>
  `}const Ua=g(new Set(["broadcast","tasks","keepers","system"]));function By(t){const e=new Set(Ua.value);e.has(t)?e.delete(t):e.add(t),Ua.value=e}const dr=g(null);function Od(t){dr.value=t}function Uy(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const Hy=Rt(()=>{const t=Ua.value;return aa.value.filter(e=>t.has(Uy(e)))}),Wy=12e4,Gy=Rt(()=>{const t=Xl.value,e=Date.now();return Vt.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?o=e-new Date(l).getTime()>Wy?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),Jy=Rt(()=>{const t=Xl.value;return Vt.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function pl(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function Yy(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function Xy(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function Vy(){const t=Gy.value,e=dr.value;return t.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${t.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${Xy(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>Od(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const Qy=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function Zy(){const t=Ua.value;return i`
    <div class="activity-filter-bar">
      ${Qy.map(e=>i`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>By(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function tb(){const t=Hy.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${Zy} />
      <div class="activity-stream-list">
        ${t.length===0?i`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>i`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${pl(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${pl(e)}">${Yy(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${Uc(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function eb(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function nb(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function sb(){const t=Jy.value,e=dr.value;return i`
    <div class="focus-sidebar">
      <div class="focus-sidebar-head">
        <h3>Agents</h3>
        <span class="focus-count">${t.length} active</span>
      </div>
      <div class="focus-sidebar-list">
        ${t.length===0?i`<div class="focus-empty">No active agents</div>`:t.map(n=>i`
            <div
              key=${n.name}
              class="focus-agent-card ${e===n.name?"focus-agent-selected":""}"
              onClick=${()=>Od(e===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${eb(n.pressure)}">
                  ${nb(n.pressure)}
                  ${n.assignedCount>0?i` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?i`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?i`<span class="focus-activity-text">${n.lastActivityText}</span>`:i`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?i`<${X} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function ab(){const t=ue.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>라이브 모니터</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"연결됨":"오프라인"}
          </span>
          <span class="live-stat">에이전트 ${Vt.value.length}</span>
          <span class="live-stat">이벤트 ${Ha.value}</span>
        </div>
      </div>

      <${Vy} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${tb} />
        </div>
        <div class="live-panel-side">
          <${sb} />
        </div>
      </div>
    </div>
  `}const ml=[{id:"observe",label:"관찰",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"맥락",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"개입",description:"개입과 운영 기준 지휘를 실행하는 표면"},{id:"lab",label:"실험",description:"실험적 기능은 메인 operator console 밖으로 분리"}],ko=[{id:"mission",label:"상황판",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"proof",label:"근거",icon:"🔍",group:"observe",description:"협업, 대화, 도구, 근거 기록을 증명 중심으로 읽는 표면"},{id:"execution",label:"실행",icon:"🤖",group:"observe",description:"워커, 태스크, 키퍼 연속성을 분리해서 보는 실행 표면"},{id:"tools",label:"도구",icon:"🧰",group:"observe",description:"시스템 전체 도구 inventory와 사용 통계를 함께 읽는 표면"},{id:"live",label:"라이브",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"계획",icon:"🎯",group:"observe",description:"목표, 지표 루프, 백로그 압력을 읽는 계획 표면"},{id:"memory",label:"메모리",icon:"💬",group:"context",description:"게시글과 댓글로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"거버넌스",icon:"⚖️",group:"context",description:"토론과 표결을 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"개입",icon:"🎮",group:"act",description:"룸, 세션, 키퍼 액션을 실행하는 개입 화면"},{id:"command",label:"지휘",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"실험",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 표면을 메인 콘솔 밖에서 다룹니다"}];function ib(t){const e=t==null?void 0:t.trim();return e?e.length>10?e.slice(0,10):e:"커밋 정보 없음"}function Tt(t,e){return e==="live"?"가동 중":e==="quiet"?"조용함":e==="starting"?"기동 중":e==="idle"?t==="guardian"?"유휴":"대기 중":"비활성"}function Ct(t,e){return i`
    <div class="build-badge-row">
      <span>${t}</span>
      <strong>${e}</strong>
    </div>
  `}function Ks(t,e,n,s,a){return i`
    <div style="padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
      <div class="rail-card-head" style="margin:0;">
        <h3 style="font-size:12px;">${t}</h3>
        <span class="rail-section-chip ${n}">${e}</span>
      </div>
      ${s}
      ${a?i`<div class="rail-build-hint">${a}</div>`:null}
    </div>
  `}function ob({currentTab:t}){var p,m,u,v,f,$,C,b,k,h;const e=ue.value,n=(p=vt.value)==null?void 0:p.build,s=(m=vt.value)==null?void 0:m.lodge,a=(u=vt.value)==null?void 0:u.gardener,o=(v=vt.value)==null?void 0:v.guardian,l=(f=vt.value)==null?void 0:f.sentinel,c=[];if(s&&c.push(Ks("Lodge",s.enabled?Tt("lodge",s.quiet_active?"quiet":"live"):Tt("lodge","disabled"),s.enabled?s.quiet_active?"warn":"ok":"bad",[Ct("틱",s.total_ticks??0),Ct("체크인",s.total_checkins??0),Ct("최근 결과",(($=s.last_tick_result)==null?void 0:$.activity_report)??s.last_skip_reason??"없음")])),a&&c.push(Ks("Gardener",a.alive?Tt("gardener","live"):a.enabled?Tt("gardener","starting"):Tt("gardener","disabled"),a.alive?"ok":a.enabled?"warn":"bad",[Ct("최근 tick",a.last_tick_completed_at?i`<${X} timestamp=${a.last_tick_completed_at} />`:"기록 없음"),Ct("판단",`${a.last_intervention??"없음"} · ${a.last_decision_source??"없음"}`),Ct("백로그",`미할당 ${((C=a.health_summary)==null?void 0:C.todo_count)??0} · P1/2 ${((b=a.health_summary)==null?void 0:b.high_priority_todo)??0}`)],a.last_reason??a.last_error??void 0)),o){const S=o.masc_loops_running||o.lodge_loop_started||o.lodge_running;c.push(Ks("Guardian",S?Tt("guardian","live"):o.enabled?Tt("guardian","idle"):Tt("guardian","disabled"),S?"ok":o.enabled?"warn":"bad",[Ct("모드",o.mode??"알 수 없음"),Ct("루프",`zombie ${o.zombie_loop_running?"on":"off"} · gc ${o.gc_loop_running?"on":"off"}`),Ct("소유자",o.runtime_owner??"없음")],((k=o.last_lodge_result)==null?void 0:k.message)??o.last_gc_result??o.last_zombie_result??void 0))}return l&&c.push(Ks("Sentinel",l.started?Tt("sentinel","live"):l.enabled?Tt("sentinel","starting"):Tt("sentinel","disabled"),l.started?"ok":l.enabled?"warn":"bad",[Ct("에이전트",l.agent_name??"sentinel"),Ct("소비자",((h=l.consumers)==null?void 0:h.length)??0),Ct("가디언 소유자",l.guardian_runtime_owner??"없음")],l.llm_enabled===!0?"LLM 기반 housekeeping resident":void 0)),i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${w} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${e?"ok":"bad"}">${e?"연결됨":"오프라인"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>에이전트</span>
          <strong>${Vt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>키퍼</span>
          <strong>${ve.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>태스크</span>
          <strong>${ae.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>이벤트</span>
          <strong>${Ha.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{ls(),tc(),ro(t)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>ot("intervene")}>
          개입 열기
        </button>
      </div>
      ${n?i`<div class="rail-build-hint">서버 빌드 · v${n.release_version} · ${ib(n.commit)}</div>`:null}
      ${c.length>0?i`
            <div style="margin-top:12px; display:flex; flex-direction:column; gap:10px;">
              ${c}
            </div>
          `:null}
    </section>
  `}function rb(){const t=Mt.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${w} panelId="side_rail.quick_actions" compact=${!0} />
        <span class="rail-section-chip ${e>0?"warn":"ok"}">${e>0?"확인 필요":"정상"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>확인 대기</span>
          <strong>${e}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Session</span>
          <strong>${n}</strong>
        </div>
        <div class="rail-stat-card">
          <span>키퍼</span>
          <strong>${s}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{bt(),ze()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>ot("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}const Bs=g(!1);function lb(){const t=ue.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"연결됨":"재연결 중..."}</span>
      <span class="event-count">이벤트 ${Ha.value}</span>
    </div>
  `}function cb(t){const e=t==null?void 0:t.trim();return e?e.length>10?e.slice(0,10):e:"커밋 정보 없음"}function db(){const t=vt.value,e=t==null?void 0:t.build,n=e?`v${e.release_version} · ${cb(e.commit)}`:t!=null&&t.version?`v${t.version} · 커밋 정보 없음`:"버전 정보 없음";return i`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${Bs.value}
        onClick=${()=>{Bs.value=!Bs.value}}
      >
        서버 빌드 · ${n}
      </button>
      ${Bs.value?i`
            <div class="build-badge-panel">
              <div class="build-badge-row">
                <span>릴리즈</span>
                <strong>${(e==null?void 0:e.release_version)??(t==null?void 0:t.version)??"unknown"}</strong>
              </div>
              <div class="build-badge-row">
                <span>커밋</span>
                <strong>${(e==null?void 0:e.commit)??"커밋 정보 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>서버 시작</span>
                <strong>${e!=null&&e.started_at?i`<${X} timestamp=${e.started_at} />`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof(e==null?void 0:e.uptime_seconds)=="number"?`${e.uptime_seconds}s`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${t!=null&&t.generated_at?i`<${X} timestamp=${t.generated_at} />`:"알 수 없음"}</strong>
              </div>
            </div>
          `:null}
    </div>
  `}function ub(){const t=D.value.tab,e=ko.find(s=>s.id===t),n=ml.find(s=>s.id===(e==null?void 0:e.group));return i`
    <aside class="dashboard-rail">
      <${kt} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${w} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${ml.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${ko.filter(a=>a.group===s.id).map(a=>i`
                  <button
                    class="rail-tab-btn ${t===a.id?"active":""}"
                    onClick=${()=>ot(a.id)}
                  >
                    <span class="rail-tab-icon">${a.icon}</span>
                    <span class="rail-tab-copy">
                      <strong>${a.label}</strong>
                      <span>${a.description}</span>
                    </span>
                  </button>
                `)}
            </div>
          </div>
        `)}
        <div class="rail-view-note">
          <div class="rail-view-note-label">현재 화면</div>
          <strong>${(e==null?void 0:e.label)??t}</strong>
          <p>${(e==null?void 0:e.description)??"운영 화면"}</p>
        </div>
      </section>

      <${ob} currentTab=${t} />
      <${rb} />
    </aside>
  `}function pb(){switch(D.value.tab){case"mission":return i`<${jr} />`;case"proof":return i`<${Mg} />`;case"execution":return i`<${Eh} />`;case"tools":return i`<${Dh} />`;case"live":return i`<${ab} />`;case"memory":return i`<${$h} />`;case"governance":return i`<${py} />`;case"planning":return i`<${Zh} />`;case"intervene":return i`<${ih} />`;case"command":return i`<${eh} />`;case"lab":return i`<${Ky} />`;default:return i`<${jr} />`}}function mb(){return Xi.value&&!ue.value?i`<div class="loading-indicator">대시보드 불러오는 중...</div>`:i`<${pb} />`}function _b(){nt(()=>{Gd(),yl(),ec(),Ie(),Te(),tc(),fc();const n=Fm();return Km(),()=>{eu(),n(),Bm()}},[]),nt(()=>{const n=setInterval(()=>{ro(D.value.tab)},15e3);return()=>{clearInterval(n)}},[]),nt(()=>{ro(D.value.tab)},[D.value.tab]);const t=D.value.tab,e=ko.find(n=>n.id===t);return i`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC 대시보드
            <${db} />
          </h1>
          <p class="header-subtitle">${(e==null?void 0:e.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${lb} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${ub} />
        <main class="dashboard-main">
          <${mb} />
        </main>
      </div>

      <${Pf} />
      <${cf} />
      <${tf} />
    </div>
  `}const _l=document.getElementById("app");_l&&Kd(i`<${_b} />`,_l);export{Bf as _};
