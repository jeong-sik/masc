var xu=Object.defineProperty;var Su=(t,e,n)=>e in t?xu(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Ue=(t,e,n)=>Su(t,typeof e!="symbol"?e+"":e,n);import{e as Cu,_ as Au,c as g,b as Pt,A as Pn,y as nt,d as vn,G as Tu}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const l of o.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=Cu.bind(Au);const Iu=["mission","proof","execution","tools","live","memory","governance","planning","intervene","command","lab"],nc={tab:"mission",params:{},postId:null};function el(t){return!!t&&Iu.includes(t)}function Yi(t){try{return decodeURIComponent(t)}catch{return t}}function Xi(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Ru(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function sc(t,e){if(t[0]==="chains"){const o={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(o.operation=Yi(t[2])),{tab:"command",params:o,postId:null}}if(t[0]==="lab"){const o={...e};return t[1]&&(o.surface=Yi(t[1])),{tab:"lab",params:o,postId:null}}const n=t[0],s=e.tab;return{tab:el(n)?n:el(s)?s:"mission",params:e,postId:null}}function ua(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return nc;const n=Yi(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=Xi(a),l=Ru(s);return sc(l,o)}function Mu(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...nc,params:Xi(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Xi(e.replace(/^\?/,""));return sc(s,a)}function ac(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const O=g(ua(window.location.hash));window.addEventListener("hashchange",()=>{O.value=ua(window.location.hash)});function it(t,e){const n={tab:t,params:e??{}};window.location.hash=ac(n)}function Lu(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function zu(){if(window.location.hash&&window.location.hash!=="#"){O.value=ua(window.location.hash);return}const t=Mu(window.location.pathname,window.location.search);if(t){O.value=t;const e=ac(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",O.value=ua(window.location.hash)}const nl="masc_dashboard_sse_session_id",Eu=1e3,Pu=15e3,ge=g(!1),Ya=g(0),ic=g(null),pa=g([]);function Nu(){let t=sessionStorage.getItem(nl);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(nl,t)),t}const ju=200;function wu(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};pa.value=[a,...pa.value].slice(0,ju)}function Qi(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function sl(t,e){const n=Qi(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function Lt(t,e,n,s,a={}){wu(t,e,n,{eventType:s,...a})}let Dt=null,an=null,Zi=0;function oc(){an&&(clearTimeout(an),an=null)}function Ou(){if(an)return;Zi++;const t=Math.min(Zi,5),e=Math.min(Pu,Eu*Math.pow(2,t));an=setTimeout(()=>{an=null,rc()},e)}function rc(){oc(),Dt&&(Dt.close(),Dt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Nu());const a=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(a);Dt=o,o.onopen=()=>{Dt===o&&(Zi=0,ge.value=!0)},o.onerror=()=>{Dt===o&&(ge.value=!1,o.close(),Dt=null,Ou())},o.onmessage=l=>{try{const c=JSON.parse(l.data);Ya.value++,ic.value=c,Du(c)}catch{}}}function Du(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":Lt(n,"Joined","system","agent_joined");break;case"agent_left":Lt(n,"Left","system","agent_left");break;case"broadcast":Lt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Lt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Lt(n,sl("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Qi(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":Lt(n,sl("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Qi(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":Lt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Lt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Lt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Lt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Lt(n,e,"system","unknown")}}function qu(){oc(),Dt&&(Dt.close(),Dt=null),ge.value=!1}function _(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function r(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function d(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function N(t){return typeof t=="boolean"?t:void 0}function B(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function dt(t,e=[]){if(Array.isArray(t))return t;if(!_(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function ot(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}const ma="[STATE]",to="[/STATE]";function Fu(t){const e=t.indexOf(ma);if(e<0)return null;const n=e+ma.length,s=t.indexOf(to,n);return s<0?null:t.slice(n,s).trim()||null}function Ku(t){let e=t;for(;;){const n=e.indexOf(ma);if(n<0)return e;const s=e.indexOf(to,n+ma.length);if(s<0)return e.slice(0,n);e=`${e.slice(0,n)}${e.slice(s+to.length)}`}}function Bu(t){return t.split(`
`).filter(e=>{const n=e.trim();return!n.startsWith("SKILL:")&&!n.startsWith("SKILL_REASON:")}).join(`
`)}function Xs(t){const e=Bu(t);return Ku(e).replace(/\n{3,}/g,`

`).trim()}function lc(t){const e=(()=>{if(!_(t))return null;const o=t.raw_payload;return _(o)?o:t})();if(!e)return null;const n=r(e.reply)??"",s=n?Fu(n):null,a=_(e.usage)?{inputTokens:d(e.usage.input_tokens)??null,outputTokens:d(e.usage.output_tokens)??null,totalTokens:d(e.usage.total_tokens)??null}:null;return{traceId:r(e.trace_id)??null,generation:d(e.generation)??null,modelUsed:r(e.model_used)??null,latencyMs:d(e.latency_ms)??null,costUsd:d(e.cost_usd)??null,usage:a,skillPrimary:r(e.skill_primary)??null,skillReason:r(e.skill_reason)??null,stateBlock:s,rawPayload:e}}function Uu(t){const e=t.trim();if(!e.startsWith("{"))return{text:Xs(e),details:null};try{const n=JSON.parse(e),s=lc(n),a=_(n)?r(n.reply)??e:e;return{text:Xs(a),details:s}}catch{return{text:Xs(e),details:null}}}function cc(){return new URLSearchParams(window.location.search)}const Hu="masc_dashboard_agent_name";function Wu(){var t;try{return((t=localStorage.getItem(Hu))==null?void 0:t.trim())||null}catch{return null}}function dc(){const t=cc(),e={},n=t.get("token"),s=Wu(),a=t.get("agent")??t.get("agent_name")??s;return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function No(){return{...dc(),"Content-Type":"application/json"}}const Gu=15e3,jo=3e4,Ju=6e4,al=new Set([408,425,429,500,502,503,504]);class gs extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);Ue(this,"method");Ue(this,"path");Ue(this,"status");Ue(this,"statusText");Ue(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function wo(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const l=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new gs({method:l,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function Vu(){var e,n;const t=cc();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function st(t){const e=await wo(t,{headers:dc()},Gu);if(!e.ok)throw new gs({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Yu(t){return new Promise(e=>setTimeout(e,t))}function Xu(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function Qu(t){if(t instanceof gs)return t.timeout||typeof t.status=="number"&&al.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Xu(t.message);return e!==null&&al.has(e)}async function uc(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!Qu(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${o}ms`,a),await Yu(o),s+=1}}async function Wt(t,e,n,s=jo){const a=await wo(t,{method:"POST",headers:{...No(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new gs({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function Zu(t,e,n,s=jo){const a=await wo(t,{method:"POST",headers:{...No(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new gs({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function tp(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function ep(t){var e,n,s,a,o,l,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const u=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(u)}return((c=(l=(o=t.result)==null?void 0:o.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function Nt(t,e){const n=await Zu("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Ju),s=tp(n);return ep(s)}async function np(t,e,n){return Nt("masc_keeper_msg",{name:t,message:e})}async function sp(t,e,n){const s=await np(t,e);return Uu(s)}function ap(t){const e=t.replace(/\r\n/g,`
`),n=[];let s=0;for(;;){const a=e.indexOf(`

`,s);if(a<0)return{frames:n,rest:e.slice(s)};n.push(e.slice(s,a)),s=a+2}}function il(t){const e=t.split(`
`).filter(n=>n.startsWith("data:")).map(n=>n.slice(5).trimStart());if(e.length===0)return null;try{return JSON.parse(e.join(`
`))}catch{return null}}async function ip(t,e,n,{signal:s,onEvent:a}){var m;const o=await fetch("/api/v1/keepers/chat/stream",{method:"POST",headers:{...No(),Accept:"text/event-stream"},body:JSON.stringify({name:t,message:e}),signal:s});if(!o.ok){const p=await o.text();let v=p||`Streaming request failed (${o.status})`;try{const f=JSON.parse(p);v=((m=f.error)==null?void 0:m.message)??f.message??v}catch{}throw new Error(v)}if(!o.body)throw new Error("Streaming response body is unavailable");const l=o.body.getReader(),c=new TextDecoder;let u="";try{for(;;){const{done:v,value:f}=await l.read();u+=c.decode(f??new Uint8Array,{stream:!v});const{frames:h,rest:A}=ap(u);u=A;for(const b of h){const k=il(b);k&&a(k)}if(v)break}const p=u.trim();if(p){const v=il(p);v&&a(v)}}finally{l.releaseLock()}}function op(){return st("/api/v1/dashboard/shell")}function rp(){return st("/api/v1/dashboard/room-truth")}function lp(){return st("/api/v1/dashboard/execution")}function cp(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),st(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function dp(){return uc("fetchDashboardGovernance",async()=>{const t=await st("/api/v1/dashboard/governance"),e=Array.isArray(t.items)?t.items.map(s=>zp(s)).filter(s=>s!==null):[],n=Array.isArray(t.pending_actions)?t.pending_actions.map(s=>mc(s)).filter(s=>s!==null):[];return{generated_at:mt(t.generated_at)??void 0,summary:_(t.summary)?{cases_open:ct(t.summary.cases_open)??void 0,pending_ruling:ct(t.summary.pending_ruling)??void 0,ready_auto_execute:ct(t.summary.ready_auto_execute)??void 0,needs_human_gate:ct(t.summary.needs_human_gate)??void 0,executed:ct(t.summary.executed)??void 0,blocked:ct(t.summary.blocked)??void 0,debates:ct(t.summary.debates)??void 0,voting_sessions:ct(t.summary.voting_sessions)??void 0,debates_open:ct(t.summary.debates_open)??void 0,sessions_active:ct(t.summary.sessions_active)??void 0,sessions_without_quorum:ct(t.summary.sessions_without_quorum)??void 0,ready_to_execute:ct(t.summary.ready_to_execute)??void 0,oldest_open_debate_age_s:typeof t.summary.oldest_open_debate_age_s=="number"?t.summary.oldest_open_debate_age_s:null,last_activity_age_s:typeof t.summary.last_activity_age_s=="number"?t.summary.last_activity_age_s:null,judge_online:typeof t.summary.judge_online=="boolean"?t.summary.judge_online:void 0,judge_last_seen_at:mt(t.summary.judge_last_seen_at)}:void 0,items:e,activity:Array.isArray(t.activity)?t.activity.map(s=>Pp(s)).filter(s=>s!==null):[],judge:Np(t.judge),pending_actions:n}})}function up(){return st("/api/v1/dashboard/semantics")}function pp(){return st("/api/v1/dashboard/mission")}function mp(t){const e=`?session_id=${encodeURIComponent(t)}`;return st(`/api/v1/dashboard/session${e}`)}function _p(t=!1){return st(`/api/v1/dashboard/mission/briefing${t?"?force=1":""}`)}function vp(t,e){const n=new URLSearchParams;t&&n.set("session_id",t),e&&n.set("operation_id",e);const s=n.toString();return st(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function fp(){return st("/api/v1/dashboard/planning")}function gp(){return st("/api/v1/tool-metrics")}function $p(){return st("/api/v1/dashboard/tools")}function hp(){return st("/api/v1/operator")}function pc(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return st(`/api/v1/operator/digest${n?`?${n}`:""}`)}function yp(){return st("/api/v1/command-plane")}function bp(){return st("/api/v1/command-plane/summary")}function kp(){return st("/api/v1/chains/summary")}function xp(t){return st(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Sp(){return st("/api/v1/command-plane/help")}function Cp(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return st(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function Ap(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return st(`/api/v1/command-plane/orchestra${s?`?${s}`:""}`)}function Tp(t,e){return Wt(t,e)}function Ip(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"swarm_run_continue":return 6e4;case"swarm_run_rerun":return 12e4;case"swarm_run_abandon":return 3e4;case"lodge_tick":return 45e3;default:return jo}}function Xa(t){return Wt("/api/v1/operator/action",t,void 0,Ip(t))}function Rp(t,e,n="confirm"){return Wt("/api/v1/operator/confirm",{actor:t,confirm_token:e,decision:n})}function Qs(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function mt(t){if(typeof t=="string"){const e=t.trim();return e||null}if(typeof t=="number"&&Number.isFinite(t)){const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}return null}function P(t){if(typeof t!="string")return null;const e=t.trim();return e||null}function mc(t){if(!_(t))return null;const e=C(t.confirm_token??t.token,"").trim();return e?{confirm_token:e,actor:P(t.actor)??void 0,action_type:P(t.action_type)??void 0,target_type:P(t.target_type)??void 0,target_id:P(t.target_id),delegated_tool:P(t.delegated_tool)??void 0,created_at:mt(t.created_at)??void 0,preview:t.preview}:null}function Mp(t){return _(t)?{board_post_id:P(t.board_post_id),task_id:P(t.task_id),operation_id:P(t.operation_id),team_session_id:P(t.team_session_id)}:{}}function Oo(t){if(!_(t))return null;const e=P(t.action_kind),n=P(t.resolved_tool),s=P(t.target_type),a=P(t.target_id),o=P(t.reason);return!e&&!n&&!s&&!o?null:{action_kind:e??void 0,resolved_tool:n,target_type:s,target_id:a,reason:o??void 0,payload_preview:t.payload_preview}}function _c(t){if(!_(t))return null;const e=P(t.action_type),n=P(t.delegated_tool),s=P(t.confirmation_state),a=mt(t.created_at);return!e&&!n&&!s&&!a?null:{action_type:e??void 0,delegated_tool:n,confirmation_state:s??void 0,created_at:a}}function vc(t){if(!_(t))return null;const e=mc(t.pending_confirm),n=P(t.pending_confirm_token)??(e==null?void 0:e.confirm_token)??null;return{requires_human_gate:typeof t.requires_human_gate=="boolean"?t.requires_human_gate:void 0,pending_confirm:e,pending_confirm_token:n,ready_to_execute:typeof t.ready_to_execute=="boolean"?t.ready_to_execute:void 0}}function Lp(t){if(!_(t))return null;const e=P(t.summary),n=P(t.target_id);return!e&&!n?null:{judgment_id:P(t.judgment_id)??void 0,target_kind:P(t.target_kind)??void 0,target_id:n??void 0,status:P(t.status)??void 0,summary:e??void 0,confidence:typeof t.confidence=="number"?t.confidence:null,generated_at:mt(t.generated_at),expires_at:mt(t.expires_at),model_used:P(t.model_used),keeper_name:P(t.keeper_name),evidence_refs:Mt(t.evidence_refs),recommended_action:Oo(t.recommended_action),guardrail_state:vc(t.guardrail_state),executed_route:_c(t.executed_route)}}function zp(t){if(!_(t))return null;const e=C(t.id,"").trim(),n=C(t.topic??t.title,"").trim();if(!e||!n)return null;const s=Mp(t.context);return{kind:C(t.kind,"case"),id:e,topic:n,status:C(t.status??t.state,"open"),origin:P(t.origin),subject_type:P(t.subject_type),risk_class:P(t.risk_class),provenance:P(t.provenance),auto_execution_state:P(t.auto_execution_state),petition_count:ct(t.petition_count),brief_count:ct(t.brief_count),last_activity_at:mt(t.last_activity_at),truth_summary:P(t.truth_summary)??void 0,judgment_summary:P(t.judgment_summary),confidence:typeof t.confidence=="number"?t.confidence:null,related_agents:Mt(t.related_agents),context:s,linked_board_post_id:P(t.linked_board_post_id)??s.board_post_id??null,linked_task_id:P(t.linked_task_id)??s.task_id??null,linked_operation_id:P(t.linked_operation_id)??s.operation_id??null,linked_session_id:P(t.linked_session_id)??s.team_session_id??null,recommended_action:Oo(t.recommended_action),executed_route:_c(t.executed_route),guardrail_state:vc(t.guardrail_state),evidence_refs:Mt(t.evidence_refs)}}function Ep(t){if(!_(t))return null;const e=C(t.id,"").trim(),n=C(t.author,"").trim(),s=C(t.summary,"").trim();return!e||!n||!s?null:{id:e,author:n,stance:C(t.stance,"support"),summary:s,evidence_refs:Mt(t.evidence_refs),created_at:mt(t.created_at)}}function fc(t){if(!_(t))return null;const e=C(t.id,"").trim(),n=C(t.case_id,"").trim();return!e||!n?null:{id:e,case_id:n,status:C(t.status,"blocked"),risk_class:P(t.risk_class),action_request:Oo(t.action_request),created_at:mt(t.created_at),updated_at:mt(t.updated_at),execution_ref:P(t.execution_ref),result_summary:P(t.result_summary),actor:P(t.actor)}}function Do(t){if(!_(t)||!_(t.case))return null;const e=t.case,n=C(e.id,"").trim(),s=C(e.title,"").trim();return!n||!s?null:{case:{id:n,petition_ids:Mt(e.petition_ids),title:s,origin:P(e.origin),subject_type:P(e.subject_type),risk_class:P(e.risk_class),status:C(e.status,"pending_ruling"),created_at:mt(e.created_at),updated_at:mt(e.updated_at),source_refs:Mt(e.source_refs),briefs:Array.isArray(e.briefs)?e.briefs.map(a=>Ep(a)).filter(a=>a!==null):[]},petitions:Array.isArray(t.petitions)?t.petitions.flatMap(a=>{if(!_(a))return[];const o=C(a.id,"").trim(),l=C(a.case_id,"").trim(),c=C(a.title,"").trim();return!o||!l||!c?[]:[{id:o,case_id:l,title:c,origin:P(a.origin),subject_type:P(a.subject_type),risk_class:P(a.risk_class),source_refs:Mt(a.source_refs),created_by:P(a.created_by),created_at:mt(a.created_at)}]}):[],ruling:Lp(t.ruling),execution_order:fc(t.execution_order)}}function Pp(t){if(!_(t))return null;const e=C(t.kind,"").trim();return e?{kind:e,item_kind:P(t.item_kind)??void 0,item_id:P(t.item_id)??void 0,topic:P(t.topic)??void 0,created_at:mt(t.created_at),summary:P(t.summary)??void 0,actor:P(t.actor),index:ct(t.index),decision:P(t.decision)}:null}function Np(t){if(_(t))return{judge_online:typeof t.judge_online=="boolean"?t.judge_online:void 0,refreshing:typeof t.refreshing=="boolean"?t.refreshing:void 0,generated_at:mt(t.generated_at),expires_at:mt(t.expires_at),model_used:P(t.model_used),keeper_name:P(t.keeper_name),last_error:P(t.last_error)}}function jp(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function wp(t){if(!_(t))return null;const e=C(t.source,"").trim()||null,n=C(t.state_block,"").trim()||null;return!e&&!n?null:{source:e,state_block:n}}function Op(t){if(!_(t))return null;const e=C(t.id,"").trim(),n=C(t.author,"").trim(),s=C(t.body,"").trim()||C(t.content,"").trim(),a=s;if(!e||!n)return null;const o=at(t.score,0),l=at(t.votes_up,0),c=at(t.votes_down,0),u=at(t.votes,o||l-c),m=at(t.comment_count,at(t.reply_count,0)),p=(()=>{const k=t.flair;if(typeof k=="string"&&k.trim())return k.trim();if(_(k)){const z=C(k.name,"").trim();if(z)return z}return C(t.flair_name,"").trim()||void 0})(),v=C(t.created_at_iso,"").trim()||Qs(t.created_at),f=C(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Qs(t.updated_at):v),A=C(t.title,"").trim()||jp(s),b=Array.isArray(t.tags)?t.tags.filter(k=>typeof k=="string"&&k.trim()!==""):[];return{id:e,author:n,post_kind:(()=>{const k=C(t.post_kind,"").trim().toLowerCase();return k==="automation"||k==="system"||k==="human"?k:void 0})(),title:A,body:s,content:a,meta:wp(t.meta),tags:b,votes:u,vote_balance:o,comment_count:m,created_at:v,updated_at:f,flair:p,hearth:C(t.hearth,"").trim()||null,visibility:C(t.visibility,"").trim()||void 0,expires_at:C(t.expires_at_iso,"").trim()||(t.expires_at!==void 0&&t.expires_at!==0?Qs(t.expires_at):"")||null,hearth_count:at(t.hearth_count,0)}}function Dp(t){if(!_(t))return null;const e=C(t.id,"").trim(),n=C(t.post_id,"").trim(),s=C(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:C(t.content,""),created_at:Qs(t.created_at)}}async function qp(t){return uc("fetchBoardPost",async()=>{const e=await st(`/api/v1/board/${t}?format=flat`),n=_(e.post)?e.post:e,s=Op(n)??{id:t,author:"unknown",post_kind:"human",title:"Post",body:"",content:"",meta:null,tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(e.comments)?e.comments:[]).map(Dp).filter(l=>l!==null);return{...s,comments:o}})}function gc(t,e){return Wt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Vu()})}function Fp(t,e,n){return Wt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Kp(t){const e=C(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function _t(...t){for(const e of t){const n=C(e,"");if(n.trim())return n.trim()}return""}function ol(t){const e=Kp(_t(t.outcome,t.result,t.result_code));if(!e)return;const n=_t(t.reason,t.reason_code,t.description,t.detail),s=_t(t.summary,t.summary_ko,t.summary_en,t.note),a=_t(t.details,t.details_text,t.text,t.note),o=_t(t.winner,t.winner_name,t.actor_winner,t.winner_actor),l=_t(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=_t(t.raw_reason,t.raw_reason_code,t.error_message),u=(()=>{const v=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof v=="string"?[v]:Array.isArray(v)?v.map(f=>{if(typeof f=="string")return f.trim();if(_(f)){const h=C(f.summary,"").trim();if(h)return h;const A=C(f.text,"").trim();if(A)return A;const b=C(f.type,"").trim();return b||C(f.event_id,"").trim()}return""}).filter(f=>f.length>0):[]})(),m=(()=>{const v=at(t.turn,Number.NaN);if(Number.isFinite(v))return v;const f=at(t.turn_number,Number.NaN);if(Number.isFinite(f))return f;const h=at(t.current_turn,Number.NaN);if(Number.isFinite(h))return h;const A=at(t.round,Number.NaN);return Number.isFinite(A)?A:void 0})(),p=_t(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:l||void 0,evidence:u.length>0?u:void 0,raw_reason:c||void 0,turn:m,phase:p||void 0}}function Bp(t,e){const n=_(t.state)?t.state:{};if(C(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(l=>_(l)?C(l.type,"")==="session.outcome":!1),o=_(n.session_outcome)?n.session_outcome:{};if(_(o)&&Object.keys(o).length>0){const l=ol(o);if(l)return l}if(_(a))return ol(_(a.payload)?a.payload:{})}function C(t,e=""){return typeof t=="string"?t:e}function at(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function ct(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function eo(t,e=!1){return typeof t=="boolean"?t:e}function Mt(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(_(e)){const n=C(e.name,"").trim(),s=C(e.id,"").trim(),a=C(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Up(t){const e={};if(!_(t)&&!Array.isArray(t))return e;if(_(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),o=C(s,"").trim();!a||!o||(e[a]=o)}),e;for(const n of t){if(!_(n))continue;const s=_t(n.to,n.target,n.actor_id,n.name,n.id),a=_t(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Hp(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function Tt(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const Wp=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Gp(t){const e=_(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const o=s.trim();o&&(Wp.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function Jp(t,e){if(t!=="dice.rolled")return;const n=at(e.raw_d20,0),s=at(e.total,0),a=at(e.bonus,0),o=C(e.action,"roll"),l=at(e.dc,0);return{notation:l>0?`${o} (DC ${l})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function Vp(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Yp(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Xp(t,e,n,s){const a=n||e||C(s.actor_id,"")||C(s.actor_name,"");switch(t){case"turn.action.proposed":{const o=C(s.proposed_action,C(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=C(s.reply,C(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return C(s.reply,C(s.content,C(s.text,"Narration")));case"dice.rolled":{const o=C(s.action,"roll"),l=at(s.total,0),c=at(s.dc,0),u=C(s.label,""),m=a||"actor",p=c>0?` vs DC ${c}`:"",v=u?` (${u})`:"";return`${m} ${o}: ${l}${p}${v}`}case"turn.started":return`Turn ${at(s.turn,1)} started`;case"phase.changed":return`Phase: ${C(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${C(s.name,_(s.actor)?C(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${C(s.keeper_name,C(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${C(s.keeper_name,C(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${at(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${at(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||C(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||C(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${C(s.reason_code,"unknown")}`;case"memory.signal":{const o=_(s.entity_refs)?s.entity_refs:{},l=C(o.requested_tier,""),c=C(o.effective_tier,""),u=eo(o.guardrail_applied,!1),m=C(s.summary_en,C(s.summary_ko,"Memory signal"));if(!l&&!c)return m;const p=l&&c?`${l}->${c}`:c||l;return`${m} [${p}${u?" (guardrail)":""}]`}case"world.event":{if(C(s.event_type,"")==="canon.check"){const l=C(s.status,"unknown"),c=C(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return C(s.description,C(s.summary,"World event"))}case"combat.attack":return C(s.summary,C(s.result,"Attack resolved"));case"combat.defense":return C(s.summary,C(s.result,"Defense resolved"));case"session.outcome":return C(s.summary,C(s.outcome,"Session ended"));default:{const o=Vp(s);return o?`${t}: ${o}`:t}}}function Qp(t,e){const n=_(t)?t:{},s=C(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=C(n.actor_name,"").trim()||e[a]||C(_(n.payload)?n.payload.actor_name:"",""),l=_(n.payload)?n.payload:{},c=C(n.ts,C(n.timestamp,new Date().toISOString())),u=C(n.phase,C(l.phase,"")),m=C(n.category,"");return{type:s,actor:o||a||C(l.actor_name,""),actor_id:a||C(l.actor_id,""),actor_name:o,seq:n.seq,room_id:C(n.room_id,""),phase:u||void 0,category:m||Yp(s),visibility:C(n.visibility,C(l.visibility,"public")),event_id:C(n.event_id,""),content:Xp(s,a,o,l),dice_roll:Jp(s,l),timestamp:c}}function Zp(t,e,n){var Q,tt;const s=C(t.room_id,"")||n||"default",a=_(t.state)?t.state:{},o=_(a.party)?a.party:{},l=_(a.actor_control)?a.actor_control:{},c=_(a.join_gate)?a.join_gate:{},u=_(a.contribution_ledger)?a.contribution_ledger:{},m=Object.entries(o).map(([W,I])=>{const x=_(I)?I:{},L=Tt(x,"max_hp",void 0,10),G=Tt(x,"hp",void 0,L),yt=Tt(x,"max_mp",void 0,0),ie=Tt(x,"mp",void 0,0),H=Tt(x,"level",void 0,1),vt=Tt(x,"xp",void 0,0),be=eo(x.alive,G>0),rt=l[W],Cn=typeof rt=="string"?rt:void 0,Is=Hp(x.role,W,Cn),Rs=ct(x.generation),Ms=_t(x.joined_at,x.joinedAt,x.started_at,x.startedAt),ci=_t(x.claimed_at,x.claimedAt,x.assigned_at,x.assignedAt,x.assigned_time),di=_t(x.last_seen,x.lastSeen,x.last_seen_at,x.lastSeenAt,x.last_active,x.lastActive),ui=_t(x.scene,x.current_scene,x.currentScene,x.world_scene,x.scene_name,x.sceneName),pi=_t(x.location,x.current_location,x.currentLocation,x.position,x.zone,x.area);return{id:W,name:C(x.name,W),role:Is,keeper:Cn,archetype:C(x.archetype,""),persona:C(x.persona,""),portrait:C(x.portrait,"")||void 0,background:C(x.background,"")||void 0,traits:Mt(x.traits),skills:Mt(x.skills),stats_raw:Gp(x),status:be?"active":"dead",generation:Rs,joined_at:Ms||void 0,claimed_at:ci||void 0,last_seen:di||void 0,scene:ui||void 0,location:pi||void 0,inventory:Mt(x.inventory),notes:Mt(x.notes),relationships:Up(x.relationships),stats:{hp:G,max_hp:L,mp:ie,max_mp:yt,level:H,xp:vt,strength:Tt(x,"strength","str",10),dexterity:Tt(x,"dexterity","dex",10),constitution:Tt(x,"constitution","con",10),intelligence:Tt(x,"intelligence","int",10),wisdom:Tt(x,"wisdom","wis",10),charisma:Tt(x,"charisma","cha",10)}}}),p=m.filter(W=>W.status!=="dead"),v=Bp(t,e),f={phase_open:eo(c.phase_open,!0),min_points:at(c.min_points,3),window:C(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},h=Object.entries(u).map(([W,I])=>{const x=_(I)?I:{};return{actor_id:W,score:at(x.score,0),last_reason:C(x.last_reason,"")||null,reasons:Mt(x.reasons)}}),A=m.reduce((W,I)=>(W[I.id]=I.name,W),{}),b=e.map(W=>Qp(W,A)),k=at(a.turn,1),$=C(a.phase,"round"),z=C(a.map,""),S=_(a.world)?a.world:{},M=z||C(S.ascii_map,C(S.map,"")),T=b.filter((W,I)=>{const x=e[I];if(!_(x))return!1;const L=_(x.payload)?x.payload:{};return at(L.turn,-1)===k}),K=(T.length>0?T:b).slice(-12),U=C(a.status,"active");return{session:{id:s,room:s,status:U==="ended"?"ended":U==="paused"?"paused":"active",round:k,actors:p,created_at:((Q=b[0])==null?void 0:Q.timestamp)??new Date().toISOString()},current_round:{round_number:k,phase:$,events:K,timestamp:((tt=b[b.length-1])==null?void 0:tt.timestamp)??new Date().toISOString()},map:M||void 0,join_gate:f,contribution_ledger:h,outcome:v,party:p,story_log:b,history:[]}}async function tm(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await st(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function em(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([st(`/api/v1/trpg/state${e}`),tm(t)]);return Zp(n,s,t)}function nm(t){return Wt("/api/v1/trpg/rounds/run",{room_id:t})}function sm(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function am(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Wt("/api/v1/trpg/dice/roll",e)}function im(t,e){const n=sm();return Wt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function om(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Wt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function rm(t,e,n){return Wt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function lm(t,e,n){const s=await Nt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function cm(t){const e=await Nt("trpg.mid_join.request",t);return JSON.parse(e)}async function dm(t,e){await Nt("masc_broadcast",{agent_name:t,message:e})}async function um(t=40){return(await Nt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function pm(t,e=20){return Nt("masc_task_history",{task_id:t,limit:e})}async function mm(t){const e=await Nt("masc_petition_submit",{title:t,origin:"human",subject_type:"task",risk_class:"low",requested_action:{action_type:"add_task",payload:{title:t}}});try{const n=JSON.parse(e),s=_(n.case)?n.case:null,a=_(n.petition)?n.petition:null,o=_(n.ruling)?n.ruling:null;return!s||!a?null:Do({case:s,petitions:[a],ruling:o,execution_order:null})}catch{return null}}async function _m(t,e,n){const s=await Nt("masc_case_brief_submit",{case_id:t,stance:e,summary:n});try{const a=JSON.parse(s),o=Do(a);if(o)return o}catch{}return $c(t)}async function $c(t){const e=await Nt("masc_case_status",{case_id:t});try{return Do(JSON.parse(e))}catch{return null}}async function vm(t,e){const n=await Nt("masc_execution_orders",{case_id:t,decision:e});try{return fc(JSON.parse(n))}catch{return null}}const fm=g(""),ne=g({}),$t=g({}),no=g({}),_a=g({}),so=g({}),ao=g({}),Bt=g({}),qo=new Map,Fo=new Map;function lt(t,e,n){t.value={...t.value,[e]:n}}function gm(t){var n;const e=(n=r(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function $m(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function mi(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!_(s))continue;const a=r(s.name);if(!a)continue;const o=r(s[e]);e==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function hm(t){if(!_(t))return null;const e=r(t.name);return e?{name:e,trigger:r(t.trigger),outcome:r(t.outcome),summary:r(t.summary),reason:r(t.reason)}:null}function ym(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function bm(t,e,n){return r(t)??ym(e,n)}function km(t,e){return typeof t=="boolean"?t:e==="recover"}function va(t){if(!_(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:r(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:ot(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:d(t.next_eligible_at_s)??null,recoverable:km(t.recoverable,n),summary:bm(t.summary,e,r(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0,continuity_state:r(t.continuity_state)??null,continuity_summary:r(t.continuity_summary)??null}}function hc(t){return _(t)?{hour:d(t.hour),checked:d(t.checked)??0,acted:d(t.acted)??0,acted_names:B(t.acted_names),activity_report:r(t.activity_report),quiet_hours_overridden:N(t.quiet_hours_overridden),skipped_reason:r(t.skipped_reason),acted_rows:mi(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:mi(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:mi(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(hm).filter(e=>e!==null):[]}:null}function xm(t){return _(t)?{enabled:N(t.enabled)??!1,interval_s:d(t.interval_s)??0,quiet_start:d(t.quiet_start),quiet_end:d(t.quiet_end),quiet_active:N(t.quiet_active),use_planner:N(t.use_planner),delegate_llm:N(t.delegate_llm),agent_count:d(t.agent_count),agents:B(t.agents),last_tick_ago_s:d(t.last_tick_ago_s)??null,last_tick_ago:r(t.last_tick_ago),total_ticks:d(t.total_ticks),total_checkins:d(t.total_checkins),last_skip_reason:r(t.last_skip_reason)??null,last_tick_result:hc(t.last_tick_result),active_self_heartbeats:B(t.active_self_heartbeats)}:null}function Sm(t){return _(t)?{status:t.status,diagnostic:va(t.diagnostic)}:null}function Cm(t){return _(t)?{recovered:N(t.recovered)??!1,skipped_reason:r(t.skipped_reason)??null,before:va(t.before),after:va(t.after),down:t.down,up:t.up}:null}function Am(t,e){if(!_(t))return null;const n=gm(t.role),s=r(t.content)??r(t.preview);if(!s)return null;const a=Xs(s);if(!a)return null;const o=ot(t.ts_unix)??ot(t.timestamp);return{id:`${n}-${o??"entry"}-${e}`,role:n,label:$m(n),text:a,timestamp:o,delivery:"history",streamState:null,details:null}}function Tm(t,e,n){const s=_(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,l)=>Am(o,l)).filter(o=>o!==null):[];return{name:t,diagnostic:va(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function rl(t,e){const n=$t.value[t]??[];$t.value={...$t.value,[t]:[...n,e].slice(-50)}}function Ko(t,e,n){const s=$t.value[t]??[];$t.value={...$t.value,[t]:s.map(a=>a.id===e?n(a):a)}}function _i(t,e,n,s){Ko(t,e,a=>({...a,streamState:n,delivery:s}))}function Im(t,e,n){Ko(t,e,s=>({...s,text:`${s.text}${n}`,streamState:"streaming",delivery:"streaming"}))}function Vt(t,e,n){Ko(t,e,s=>({...s,...n}))}function Rm(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Mm(t,e){const s=($t.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(o=>Rm(a,o)));$t.value={...$t.value,[t]:[...e,...s].slice(-50)}}function Qa(t,e){ne.value={...ne.value,[t]:e},Mm(t,e.history)}function Ls(t,e){const n=ne.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Qa(t,{...n,diagnostic:{...s,...e}})}function Lm(t,e,n){Fo.set(t,e),qo.set(t,n)}function yc(t){Fo.delete(t),qo.delete(t)}function zm(t){return Fo.get(t)??null}function bc(t){const e=t.trim();if(!e)return;const n=qo.get(e),s=zm(e);n&&n.abort(),s&&Vt(e,s,{delivery:"timeout",streamState:null,error:"Stream cancelled",timestamp:new Date().toISOString()}),yc(e),lt(_a,e,!1)}function Em(t,e,n){switch(n.type){case"RUN_STARTED":return _i(t,e,"opening","sending"),null;case"TEXT_MESSAGE_START":return _i(t,e,"streaming","streaming"),null;case"TEXT_MESSAGE_CONTENT":{const s=typeof n.delta=="string"?n.delta:"";return s&&Im(t,e,s),null}case"TEXT_MESSAGE_END":return _i(t,e,"finalizing","streaming"),null;case"CUSTOM":if(n.name==="KEEPER_REPLY_DETAILS"){const s=lc(n.value);s&&Vt(t,e,{details:s})}return null;case"RUN_ERROR":return typeof n.value=="string"?n.value:(_(n.value)?r(n.value.message):null)??"Keeper stream failed";default:return null}}async function fa(){try{await $s()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Pm(t){fm.value=t.trim()}async function kc(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&ne.value[n])return ne.value[n];lt(no,n,!0),lt(Bt,n,null);try{const s=await Nt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=Tm(n,s,a);return Qa(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return lt(Bt,n,a),null}finally{lt(no,n,!1)}}async function Nm(t,e){var c;const n=t.trim(),s=e.trim();if(!n||!s)return;bc(n);const a=`local-${Date.now()}`,o=`reply-${Date.now()}`;rl(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending",streamState:null,details:null}),rl(n,{id:o,role:"assistant",label:n,text:"",timestamp:null,delivery:"sending",streamState:"opening",details:null}),lt(_a,n,!0),lt(Bt,n,null);const l=new AbortController;Lm(n,o,l);try{Vt(n,a,{delivery:"delivered"}),await ip(n,s,void 0,{signal:l.signal,onEvent:p=>{const v=Em(n,o,p);if(v)throw new Error(v)}});const u=($t.value[n]??[]).find(p=>p.id===o)??null,m=(u==null?void 0:u.text.trim())||"(empty reply)";Vt(n,o,{text:m,delivery:"delivered",streamState:null,timestamp:new Date().toISOString(),error:null}),Ls(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:m.slice(0,200),last_error:null})}catch(u){if(u instanceof Error&&u.name==="AbortError")throw Vt(n,o,{delivery:"timeout",streamState:null,error:"Stream cancelled",timestamp:new Date().toISOString()}),Ls(n,{last_reply_status:"error",last_error:"Stream cancelled"}),lt(Bt,n,"Stream cancelled"),u;if(!((c=($t.value[n]??[]).find(f=>f.id===o))!=null&&c.text.trim()))try{const f=await sp(n,s);Vt(n,o,{text:f.text.trim()||"(empty reply)",delivery:"delivered",streamState:null,details:f.details,error:null,timestamp:new Date().toISOString()}),Vt(n,a,{delivery:"delivered",error:null}),Ls(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(f.text.trim()||"(empty reply)").slice(0,200),last_error:null}),await fa();return}catch{}const v=u instanceof Error?u.message:`Failed to send direct message to ${n}`;throw Vt(n,o,{delivery:"error",streamState:null,error:v,timestamp:new Date().toISOString()}),Vt(n,a,{delivery:"error",error:v}),Ls(n,{last_reply_status:"error",last_error:v}),lt(Bt,n,v),u}finally{yc(n),lt(_a,n,!1),await fa()}}async function jm(t,e){const n=t.trim();if(!n)return null;lt(so,n,!0),lt(Bt,n,null);try{const s=await Xa({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=Sm(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const l=ne.value[n];Qa(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??$t.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await fa(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw lt(Bt,n,a),s}finally{lt(so,n,!1)}}async function wm(t,e){const n=t.trim();if(!n)return null;lt(ao,n,!0),lt(Bt,n,null);try{const s=await Xa({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Cm(s.result),o=(a==null?void 0:a.after)??null;if(o){const l=ne.value[n];Qa(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??$t.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await fa(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw lt(Bt,n,a),s}finally{lt(ao,n,!1)}}function Om(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Dm(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}function qm(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}function Fm(t){return Array.isArray(t)?t.map(e=>{if(!_(e))return null;const n=d(e.ts_unix),s=d(e.context_ratio);if(n==null||s==null)return null;const a=_(e.handoff)?e.handoff:null;return{ts:n,context_ratio:s,context_tokens:d(e.context_tokens)??0,context_max:d(e.context_max)??0,latency_ms:d(e.latency_ms)??0,generation:d(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:d(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:d(e.cost_usd)??Number.NaN,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?d(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function Km(t){if(!_(t))return;const e={};for(const[n,s]of Object.entries(t)){if(n==="top_tools"){if(!Array.isArray(s))continue;const o=s.filter(l=>_(l)&&typeof l.tool=="string"&&l.tool.trim()!=="");o.length>0&&(e.top_tools=o);continue}const a=d(s);a!=null&&(e[n]=a)}return Object.keys(e).length>0?e:void 0}function Bm(t){if(!_(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);if(!e||!n||!s)return null;const a=r(t.quiet_reason)??null;return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:ot(t.last_reply_at)??r(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:d(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:r(t.summary),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0,continuity_state:r(t.continuity_state)??null,continuity_summary:r(t.continuity_summary)??null}}function Um(t){return(Array.isArray(t)?t:_(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!_(n))return null;const s=_(n.agent)?n.agent:null,a=_(n.context)?n.context:null,o=Km(n.metrics_window),l=r(n.name);if(!l)return null;const c=d(n.context_ratio)??d(a==null?void 0:a.context_ratio),u=r(n.status)??r(s==null?void 0:s.status)??"offline",m=r(n.model)??r(n.active_model)??r(n.primary_model),p=B(n.skill_secondary),v=Fm(n.metrics_series),f=a?{source:r(a.source),context_ratio:d(a.context_ratio),context_tokens:d(a.context_tokens),context_max:d(a.context_max),message_count:d(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,h=s?{name:r(s.name),exists:typeof s.exists=="boolean"?s.exists:void 0,error:r(s.error),agent_type:r(s.agent_type),status:r(s.status),current_task:r(s.current_task)??null,joined_at:r(s.joined_at),last_seen:r(s.last_seen),last_seen_ago_s:d(s.last_seen_ago_s),capabilities:B(s.capabilities),is_zombie:typeof s.is_zombie=="boolean"?s.is_zombie:void 0}:void 0;return{name:l,runtime_class:n.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:typeof n.desired=="boolean"?n.desired:void 0,resident_registered:typeof n.resident_registered=="boolean"?n.resident_registered:void 0,reconcile_status:r(n.reconcile_status)??null,emoji:r(n.emoji),koreanName:r(n.koreanName)??r(n.korean_name),agent_name:r(n.agent_name),trace_id:r(n.trace_id),model:m,primary_model:r(n.primary_model),active_model:r(n.active_model),next_model_hint:r(n.next_model_hint)??null,status:Om(u),presence_keepalive:typeof n.presence_keepalive=="boolean"?n.presence_keepalive:void 0,presence_keepalive_sec:d(n.presence_keepalive_sec),keepalive_running:typeof n.keepalive_running=="boolean"?n.keepalive_running:void 0,proactive_enabled:typeof n.proactive_enabled=="boolean"?n.proactive_enabled:void 0,proactive_idle_sec:d(n.proactive_idle_sec),proactive_cooldown_sec:d(n.proactive_cooldown_sec),last_heartbeat:r(n.last_heartbeat)??r(s==null?void 0:s.last_seen),generation:d(n.generation),turn_count:d(n.turn_count)??d(n.total_turns),keeper_age_s:d(n.keeper_age_s),last_turn_ago_s:d(n.last_turn_ago_s),last_handoff_ago_s:d(n.last_handoff_ago_s),last_compaction_ago_s:d(n.last_compaction_ago_s),last_proactive_ago_s:d(n.last_proactive_ago_s),last_proactive_preview:r(n.last_proactive_preview)??null,context_ratio:c,context_tokens:d(n.context_tokens)??d(a==null?void 0:a.context_tokens),context_max:d(n.context_max)??d(a==null?void 0:a.context_max),context_source:r(n.context_source)??r(a==null?void 0:a.source),context:f,traits:B(n.traits),interests:B(n.interests),primaryValue:r(n.primaryValue)??r(n.primary_value),activityLevel:d(n.activityLevel)??d(n.activity_level),memory_recent_note:r(n.memory_recent_note)??null,recent_input_preview:r(n.recent_input_preview)??null,recent_output_preview:r(n.recent_output_preview)??null,recent_tool_names:B(n.recent_tool_names)??[],allowed_tool_names:B(n.allowed_tool_names)??[],latest_tool_names:B(n.latest_tool_names)??[],latest_tool_call_count:d(n.latest_tool_call_count)??null,tool_audit_source:r(n.tool_audit_source)??null,tool_audit_at:ot(n.tool_audit_at)??r(n.tool_audit_at)??null,conversation_tail_count:d(n.conversation_tail_count),k2k_count:d(n.k2k_count),handoff_count_total:d(n.handoff_count_total)??d(n.trace_history_count),compaction_count:d(n.compaction_count),last_compaction_saved_tokens:d(n.last_compaction_saved_tokens),diagnostic:Bm(n.diagnostic),skill_primary:r(n.skill_primary)??null,skill_secondary:p,skill_reason:r(n.skill_reason)??null,metrics_series:v.length>0?v:void 0,metrics_window:o,agent:h}}).filter(n=>n!==null)}function xe(t){return(t??"").trim().toLowerCase()}function bt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Zs(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function zs(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function An(t){return t.last_heartbeat??zs(t.last_turn_ago_s)??zs(t.last_proactive_ago_s)??zs(t.last_handoff_ago_s)??zs(t.last_compaction_ago_s)}function Hm(t){const e=t.title.trim();return e||Zs(t.content)}function Wm(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Gm(t,e,n,s,a={}){var S;const o=xe(t),l=e.filter(M=>xe(M.assignee)===o&&(M.status==="claimed"||M.status==="in_progress")).length,c=n.filter(M=>xe(M.from)===o).sort((M,T)=>bt(T.timestamp)-bt(M.timestamp))[0],u=s.filter(M=>xe(M.agent)===o||xe(M.author)===o).sort((M,T)=>bt(T.timestamp)-bt(M.timestamp))[0],m=(a.boardPosts??[]).filter(M=>xe(M.author)===o).sort((M,T)=>bt(T.updated_at||T.created_at)-bt(M.updated_at||M.created_at))[0],p=(a.keepers??[]).filter(M=>xe(M.name)===o&&An(M)!==null).sort((M,T)=>bt(An(T)??0)-bt(An(M)??0))[0],v=c?bt(c.timestamp):0,f=u?bt(u.timestamp):0,h=m?bt(m.updated_at||m.created_at):0,A=p?bt(An(p)??0):0,b=a.lastSeen?bt(a.lastSeen):0,k=((S=a.currentTask)==null?void 0:S.trim())||(l>0?`${l} claimed tasks`:null);if(v===0&&f===0&&h===0&&A===0&&b===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:k};const z=[c?{timestamp:c.timestamp,ts:v,text:Zs(c.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:h,text:`Post: ${Zs(Hm(m))}`}:null,p?{timestamp:An(p),ts:A,text:Wm(p)}:null,u?{timestamp:new Date(u.timestamp).toISOString(),ts:f,text:Zs(u.text)}:null].filter(M=>M!==null).sort((M,T)=>T.ts-M.ts)[0];return z&&z.ts>=b?{activeAssignedCount:l,lastActivityAt:z.timestamp,lastActivityText:z.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:k??"Presence heartbeat"}}const Gt=g([]),ue=g([]),io=g([]),ae=g([]),pt=g(null),Jm=g(null),Vm=g(null),xc=g([]),Sc=g([]),Cc=g([]),Ac=g([]),Tc=g(null),Ic=g([]),Bo=g([]),Rc=g([]),oo=g(new Map),Za=g([]),Jn=g("recent"),Re=g(!0),Mc=g(null),ee=g(""),on=g([]),Nn=g(!1),Lc=g(new Map),Uo=g("unknown"),rn=g(null),ro=g(!1),Vn=g(!1),lo=g(!1),jn=g(!1),Ho=g(null),ga=g(!1),$a=g(null),zc=g(null),co=g(null),Ym=g(null),Xm=g(null),Qm=g(null);Pt(()=>Gt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const Ec=Pt(()=>{const t=ue.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Pc=Pt(()=>{const t=new Map,e=ue.value,n=io.value,s=pa.value,a=Za.value,o=ae.value;for(const l of Gt.value)t.set(l.name.trim().toLowerCase(),Gm(l.name,e,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:o}));return t});Pt(()=>{var e;const t=new Map;for(const n of ae.value){const s=((e=n.status)==null?void 0:e.toLowerCase())??"";if(s==="offline"||s==="inactive"){t.set(n.name,"offline");continue}!n.metrics_series||n.metrics_series.length===0||t.set(n.name,Dm(n))}return t});const Zm=12e4;Pt(()=>{const t=Date.now(),e=new Set,n=oo.value;for(const s of ae.value){const a=qm(s,n);a!=null&&t-a>Zm&&e.add(s.name)}return e});function t_(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function e_(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function n_(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function s_(t){if(!_(t))return null;const e=r(t.name);return e?{name:e,agent_type:r(t.agent_type),status:e_(t.status),current_task:r(t.current_task)??null,joined_at:r(t.joined_at),last_seen:r(t.last_seen),capabilities:B(t.capabilities),emoji:r(t.emoji),koreanName:r(t.koreanName)??r(t.korean_name),model:r(t.model),traits:B(t.traits),interests:B(t.interests),activityLevel:d(t.activityLevel)??d(t.activity_level),primaryValue:r(t.primaryValue)??r(t.primary_value)}:null}function a_(t){if(!_(t))return null;const e=r(t.id),n=r(t.title);return!e||!n?null:{id:e,title:n,status:n_(t.status),priority:d(t.priority),assignee:r(t.assignee),description:r(t.description),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function i_(t){if(!_(t))return null;const e=r(t.from)??r(t.from_agent)??"system",n=r(t.content)??"",s=r(t.timestamp)??new Date().toISOString();return{id:r(t.id),seq:d(t.seq),from:e,content:n,timestamp:s,type:r(t.type)}}function Wo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="ok"||e==="warn"||e==="bad"?e:"ok"}function o_(t){return _(t)?{active_sessions:d(t.active_sessions),blocked_sessions:d(t.blocked_sessions),active_operations:d(t.active_operations),blocked_operations:d(t.blocked_operations),runtime_pressure:d(t.runtime_pressure),worker_alerts:d(t.worker_alerts),continuity_alerts:d(t.continuity_alerts),priority_items:d(t.priority_items),todo_tasks:d(t.todo_tasks),claimed_tasks:d(t.claimed_tasks),running_tasks:d(t.running_tasks),done_tasks:d(t.done_tasks),cancelled_tasks:d(t.cancelled_tasks),keepers:d(t.keepers)}:null}function pe(t){if(!_(t))return null;const e=r(t.surface),n=r(t.label),s=r(t.target_type),a=r(t.target_id),o=r(t.focus_kind);return!e||!n||!s||!a||!o?null:{surface:e==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:o,operation_id:r(t.operation_id)??null,command_surface:r(t.command_surface)??null}}function r_(t){if(!_(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.summary),a=r(t.target_type),o=r(t.target_id);return!e||!s||!a||!o||n!=="session"&&n!=="operation"?null:{id:e,kind:n,severity:Wo(t.severity),status:r(t.status),summary:s,target_type:a,target_id:o,linked_session_id:r(t.linked_session_id)??null,linked_operation_id:r(t.linked_operation_id)??null,last_seen_at:r(t.last_seen_at)??null,top_handoff:pe(t.top_handoff),intervene_handoff:pe(t.intervene_handoff),command_handoff:pe(t.command_handoff)}}function l_(t){if(!_(t))return null;const e=r(t.session_id),n=r(t.goal);return!e||!n?null:{session_id:e,goal:n,room:r(t.room)??null,status:r(t.status),health:r(t.health),member_names:B(t.member_names),linked_operation_id:r(t.linked_operation_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,runtime_blocker:r(t.runtime_blocker)??null,worker_gap_summary:r(t.worker_gap_summary)??null,last_activity_at:r(t.last_activity_at)??null,last_activity_summary:r(t.last_activity_summary)??null,communication_summary:r(t.communication_summary)??null,active_count:d(t.active_count),required_count:d(t.required_count),top_handoff:pe(t.top_handoff),intervene_handoff:pe(t.intervene_handoff),command_handoff:pe(t.command_handoff)}}function c_(t){if(!_(t))return null;const e=r(t.operation_id),n=r(t.objective);return!e||!n?null:{operation_id:e,objective:n,status:r(t.status),stage:r(t.stage)??null,assigned_unit_id:r(t.assigned_unit_id)??null,assigned_unit_label:r(t.assigned_unit_label)??null,linked_session_id:r(t.linked_session_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,blocker_summary:r(t.blocker_summary)??null,search_status:r(t.search_status)??null,next_tool:r(t.next_tool)??null,updated_at:r(t.updated_at)??null,top_handoff:pe(t.top_handoff),command_handoff:pe(t.command_handoff)}}function ll(t){if(!_(t))return null;const e=r(t.name)??r(t.agent_name),n=r(t.note),s=r(t.focus),a=r(t.state);return!e||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline"?null:{name:e,agent_name:r(t.agent_name),status:r(t.status),tone:Wo(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,active_task_count:d(t.active_task_count),related_session_id:r(t.related_session_id)??null,related_operation_id:r(t.related_operation_id)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),model:r(t.model)??null,recent_output_preview:r(t.recent_output_preview)??null,recent_event:r(t.recent_event)??null}}function d_(t){return _(t)?{checked:d(t.checked),acted:d(t.acted),passed:d(t.passed),skipped:d(t.skipped),failed:d(t.failed),last_tick_at:r(t.last_tick_at)??null,last_skip_reason:r(t.last_skip_reason)??null,activity_report:r(t.activity_report)??null}:null}function u_(t){if(!_(t))return null;const e=r(t.agent_name),n=r(t.outcome);return!e||!n?null:{agent_name:e,trigger:r(t.trigger)??null,outcome:n,summary:r(t.summary)??null,reason:r(t.reason)??null,allowed_tool_names:B(t.allowed_tool_names)??[],used_tool_names:B(t.used_tool_names)??[],used_tool_call_count:d(t.used_tool_call_count)??null,action_kind:r(t.action_kind)??"none",tool_audit_source:r(t.tool_audit_source)??null,tool_audit_at:r(t.tool_audit_at)??null,checked_at:r(t.checked_at)??null,decision_reason:r(t.decision_reason)??null,worker_name:r(t.worker_name)??null,failure_reason:r(t.failure_reason)??null}}function p_(t){if(!_(t))return null;const e=r(t.name),n=r(t.note),s=r(t.focus),a=r(t.state);return!e||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:e,agent_name:r(t.agent_name)??null,status:r(t.status),tone:Wo(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,last_autonomous_action_at:r(t.last_autonomous_action_at)??null,generation:d(t.generation),turn_count:d(t.turn_count),context_ratio:d(t.context_ratio)??null,continuity:r(t.continuity)??null,lifecycle:r(t.lifecycle)??null,related_session_id:r(t.related_session_id)??null,model:r(t.model)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),skill_reason:r(t.skill_reason)??null,recent_input_preview:r(t.recent_input_preview)??null,recent_output_preview:r(t.recent_output_preview)??null,recent_tool_names:B(t.recent_tool_names)??[],allowed_tool_names:B(t.allowed_tool_names)??[],latest_tool_names:B(t.latest_tool_names)??[],latest_tool_call_count:d(t.latest_tool_call_count)??null,tool_audit_source:r(t.tool_audit_source)??null,tool_audit_at:r(t.tool_audit_at)??null,last_proactive_preview:r(t.last_proactive_preview)??null,continuity_summary:r(t.continuity_summary)??null,skill_route_summary:r(t.skill_route_summary)??null}}function cl(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function m_(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>cl(s)-cl(a)).slice(-500)}function __(t){if(!_(t))return;const e=r(t.release_version),n=ot(t.started_at),s=d(t.uptime_seconds);if(!(!e||!n||s==null))return{release_version:e,commit:r(t.commit)??null,started_at:n,uptime_seconds:s}}function v_(t){if(_(t))return{enabled:t.enabled===!0,alive:t.alive===!0,status:r(t.status)??void 0,tick_in_progress:typeof t.tick_in_progress=="boolean"?t.tick_in_progress:void 0,tick_count:d(t.tick_count)??void 0,check_interval_sec:d(t.check_interval_sec)??void 0,last_tick_started_at:ot(t.last_tick_started_at)??r(t.last_tick_started_at)??null,last_tick_completed_at:ot(t.last_tick_completed_at)??r(t.last_tick_completed_at)??null,next_tick_due_at:ot(t.next_tick_due_at)??r(t.next_tick_due_at)??null,last_health_check_at:ot(t.last_health_check_at)??r(t.last_health_check_at)??null,last_intervention:r(t.last_intervention)??void 0,last_decision_source:r(t.last_decision_source)??void 0,last_action:r(t.last_action)??void 0,last_target:r(t.last_target)??null,last_reason:r(t.last_reason)??null,last_error:r(t.last_error)??null,circuit_open:typeof t.circuit_open=="boolean"?t.circuit_open:void 0,circuit_open_until:ot(t.circuit_open_until)??r(t.circuit_open_until)??null,can_spawn:typeof t.can_spawn=="boolean"?t.can_spawn:void 0,can_retire:typeof t.can_retire=="boolean"?t.can_retire:void 0,last_spawn_attempt_at:ot(t.last_spawn_attempt_at)??r(t.last_spawn_attempt_at)??null,last_retirement_attempt_at:ot(t.last_retirement_attempt_at)??r(t.last_retirement_attempt_at)??null,spawns_today:d(t.spawns_today)??void 0,retirements_today:d(t.retirements_today)??void 0,health_summary:_(t.health_summary)?{total_agents:d(t.health_summary.total_agents)??void 0,active_agents:d(t.health_summary.active_agents)??void 0,idle_agents:d(t.health_summary.idle_agents)??void 0,todo_count:d(t.health_summary.todo_count)??void 0,high_priority_todo:d(t.health_summary.high_priority_todo)??void 0,orphan_count:d(t.health_summary.orphan_count)??void 0,homeostatic_score:d(t.health_summary.homeostatic_score)??void 0,needs_workers:typeof t.health_summary.needs_workers=="boolean"?t.health_summary.needs_workers:void 0}:void 0}}function f_(t){if(_(t))return{enabled:t.enabled===!0,mode:r(t.mode)??void 0,masc_enabled:typeof t.masc_enabled=="boolean"?t.masc_enabled:void 0,masc_loops_running:typeof t.masc_loops_running=="boolean"?t.masc_loops_running:void 0,runtime_owner:r(t.runtime_owner)??null,zombie_loop_running:typeof t.zombie_loop_running=="boolean"?t.zombie_loop_running:void 0,gc_loop_running:typeof t.gc_loop_running=="boolean"?t.gc_loop_running:void 0,lodge_enabled:typeof t.lodge_enabled=="boolean"?t.lodge_enabled:void 0,lodge_loop_started:typeof t.lodge_loop_started=="boolean"?t.lodge_loop_started:void 0,lodge_running:typeof t.lodge_running=="boolean"?t.lodge_running:void 0,last_zombie_cleanup:ot(t.last_zombie_cleanup)??r(t.last_zombie_cleanup)??null,last_gc:ot(t.last_gc)??r(t.last_gc)??null,last_lodge:ot(t.last_lodge)??r(t.last_lodge)??null,last_zombie_result:r(t.last_zombie_result)??null,last_gc_result:r(t.last_gc_result)??null,last_lodge_result:_(t.last_lodge_result)?{ok:typeof t.last_lodge_result.ok=="boolean"?t.last_lodge_result.ok:void 0,message:r(t.last_lodge_result.message)??void 0}:null}}function g_(t){if(_(t))return{enabled:t.enabled===!0,started:t.started===!0,agent_name:r(t.agent_name)??null,llm_enabled:typeof t.llm_enabled=="boolean"?t.llm_enabled:void 0,uptime_s:d(t.uptime_s)??void 0,embedded_guardian_loops_running:typeof t.embedded_guardian_loops_running=="boolean"?t.embedded_guardian_loops_running:void 0,guardian_runtime_owner:r(t.guardian_runtime_owner)??null,consumers:B(t.consumers)}}function Nc(t,e){return _(t)?{...t,generated_at:e??ot(t.generated_at)??void 0,build:__(t.build),lodge:xm(t.lodge)??void 0,gardener:v_(t.gardener)??void 0,guardian:f_(t.guardian)??void 0,sentinel:g_(t.sentinel)??void 0}:null}function jc(t,e){return e?t?{...t,...e,build:e.build??t.build,generated_at:e.generated_at??t.generated_at}:e:t}function $_(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function h_(t){if(!_(t))return null;const e=d(t.iteration);if(e==null)return null;const n=d(t.metric_before)??0,s=d(t.metric_after)??n,a=_(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:d(t.delta)??s-n,changes:r(t.changes)??"",failed_attempts:r(t.failed_attempts)??"",next_suggestion:r(t.next_suggestion)??"",elapsed_ms:d(t.elapsed_ms)??0,cost_usd:d(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:d(a.tool_call_count)??0,tool_names:B(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function y_(t){var o,l;if(!_(t))return null;const e=r(t.loop_id);if(!e)return null;const n=d(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(h_).filter(c=>c!==null):[],a=d(t.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:r(t.profile)??"unknown",status:$_(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:r(t.error_message)??r(t.error_reason)??null,stop_reason:r(t.stop_reason)??r(t.reason)??null,current_iteration:d(t.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:d(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(t.target)??"",stagnation_streak:d(t.stagnation_streak)??0,stagnation_limit:d(t.stagnation_limit)??0,elapsed_seconds:d(t.elapsed_seconds)??0,updated_at:ot(t.updated_at)??null,stopped_at:ot(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:d(t.latest_tool_call_count)??0,latest_tool_names:B(t.latest_tool_names)??[],session_id:r(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function $s(){ro.value=!0;try{await Promise.all([Oc(),Me()]),zc.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{ro.value=!1}}async function wc(){ga.value=!0,$a.value=null;try{const t=await up();Ho.value=t,Qm.value=new Date().toISOString()}catch(t){$a.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{ga.value=!1}}function b_(t){var e;return((e=Ho.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function k_(t){var n;const e=((n=Ho.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(o=>o.id===t);if(a)return a}return null}function x_(t){var s,a;on.value=(Array.isArray(t.goals)?t.goals:[]).map(o=>{if(!_(o))return null;const l=r(o.id),c=r(o.title),u=r(o.horizon),m=r(o.status),p=r(o.created_at),v=r(o.updated_at);return!l||!c||!u||!m||!p||!v?null:{id:l,horizon:u,title:c,metric:r(o.metric)??null,target_value:r(o.target_value)??null,due_date:r(o.due_date)??null,priority:d(o.priority)??3,status:m,parent_goal_id:r(o.parent_goal_id)??null,last_review_note:r(o.last_review_note)??null,last_review_at:r(o.last_review_at)??null,created_at:p,updated_at:v}}).filter(o=>o!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const o of n){const l=y_(o);l&&e.set(l.loop_id,l)}Lc.value=e,rn.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,Uo.value=rn.value?"error":e.size===0?"idle":"ready"}async function Oc(){try{const t=await op(),e=Nc(t.status,t.generated_at);e&&(pt.value=jc(pt.value,e))}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Me(){var t;try{const e=await lp(),n=Nc(e.status,e.generated_at),s=(t=pt.value)==null?void 0:t.room;n&&(pt.value=jc(pt.value,n));const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Gt.value=(Array.isArray(e.agents)?e.agents:[]).map(s_).filter(l=>l!==null),ue.value=(Array.isArray(e.tasks)?e.tasks:[]).map(a_).filter(l=>l!==null);const o=(Array.isArray(e.messages)?e.messages:[]).map(i_).filter(l=>l!==null);io.value=a?o:m_(io.value,o),ae.value=Um(e.keepers),Vm.value=o_(e.summary),Tc.value=d_(e.lodge_tick),Ic.value=(Array.isArray(e.lodge_checkins)?e.lodge_checkins:[]).map(u_).filter(l=>l!==null),xc.value=(Array.isArray(e.execution_queue)?e.execution_queue:Array.isArray(e.priority_queue)?e.priority_queue:[]).map(r_).filter(l=>l!==null),Sc.value=(Array.isArray(e.session_briefs)?e.session_briefs:[]).map(l_).filter(l=>l!==null),Cc.value=(Array.isArray(e.operation_briefs)?e.operation_briefs:[]).map(c_).filter(l=>l!==null),Ac.value=(Array.isArray(e.worker_support_briefs)?e.worker_support_briefs:Array.isArray(e.worker_briefs)?e.worker_briefs:[]).map(ll).filter(l=>l!==null),Bo.value=(Array.isArray(e.continuity_briefs)?e.continuity_briefs:[]).map(p_).filter(l=>l!==null),Rc.value=(Array.isArray(e.offline_worker_briefs)?e.offline_worker_briefs:[]).map(ll).filter(l=>l!==null),Jm.value=null,zc.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function me(){Vn.value=!0;try{const t=await cp(Jn.value,{excludeSystem:Re.value});Za.value=t.posts??[],co.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Vn.value=!1}}async function _e(){var t;lo.value=!0;try{const e=ee.value||((t=pt.value)==null?void 0:t.room)||"default";ee.value||(ee.value=e);const n=await em(e);Mc.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{lo.value=!1}}async function Go(){Nn.value=!0,jn.value=!0;try{const t=await fp();x_(t),Ym.value=new Date().toISOString(),Xm.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),Uo.value="error",rn.value=t instanceof Error?t.message:String(t)}finally{Nn.value=!1,jn.value=!1}}async function Dc(){return Go()}const Jo=g(null),uo=g(!1),ha=g(null);function S_(t){return _(t)?{room:r(t.room)??r(t.current_room),room_base_path:r(t.room_base_path),cluster:r(t.cluster),project:r(t.project),paused:N(t.paused),version:r(t.version),generated_at:r(t.generated_at),tempo_interval_s:d(t.tempo_interval_s)}:null}function C_(t){return _(t)?{active_sessions:d(t.active_sessions),blocked_sessions:d(t.blocked_sessions),active_operations:d(t.active_operations),blocked_operations:d(t.blocked_operations),runtime_pressure:d(t.runtime_pressure),worker_alerts:d(t.worker_alerts),continuity_alerts:d(t.continuity_alerts),priority_items:d(t.priority_items),keepers:d(t.keepers)}:null}function A_(t){if(!_(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.severity),a=r(t.summary),o=r(t.target_type),l=r(t.target_id);return!e||!n||!s||!a||!o||!l?null:{id:e,kind:n,severity:s,summary:a,target_type:o,target_id:l,status:r(t.status),linked_session_id:r(t.linked_session_id)??null,linked_operation_id:r(t.linked_operation_id)??null,last_seen_at:r(t.last_seen_at)??null,top_handoff:_(t.top_handoff)?t.top_handoff:null,intervene_handoff:_(t.intervene_handoff)?t.intervene_handoff:null,command_handoff:_(t.command_handoff)?t.command_handoff:null}}function T_(t){if(!_(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function I_(t){if(!_(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:N(t.confirm_required),suggested_payload:_(t.suggested_payload)?t.suggested_payload:void 0,preview:t.preview}}function R_(t){return _(t)?{actor_filter:r(t.actor_filter)??null,filter_active:N(t.filter_active)??!1,visible_count:d(t.visible_count)??0,total_count:d(t.total_count)??0,hidden_count:d(t.hidden_count)??0,hidden_actors:B(t.hidden_actors),confirm_required_actions:dt(t.confirm_required_actions).flatMap(e=>{if(!_(e))return[];const n=r(e.action_type),s=r(e.target_type);return!n||!s?[]:[{action_type:n,target_type:s,description:r(e.description),confirm_required:N(e.confirm_required)}]})}:null}function M_(t){return _(t)?{count:d(t.count)??0,bad_count:d(t.bad_count)??0,warn_count:d(t.warn_count)??0,provenance:r(t.provenance)??null,top_item:T_(t.top_item)}:null}function L_(t){return _(t)?{count:d(t.count)??0,provenance:r(t.provenance)??null,top_action:I_(t.top_action)}:null}function z_(t){if(!_(t))return null;const e=r(t.label),n=r(t.reason),s=r(t.source),a=r(t.provenance);return!e||!n||!s||!a?null:{label:e,reason:n,source:s,provenance:a,target_kind:r(t.target_kind)??null,target_id:r(t.target_id)??null,suggested_tab:r(t.suggested_tab)??null,suggested_surface:r(t.suggested_surface)??null,suggested_params:_(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([o,l])=>{const c=r(l);return c?[o,c]:null}).filter(o=>o!==null)):{}}}function E_(t){const e=_(t)?t:{},n=_(e.room)?e.room:{},s=_(e.execution)?e.execution:{},a=_(e.command)?e.command:{},o=_(e.operator)?e.operator:{};return{generated_at:r(e.generated_at),room:{status:S_(n.status),counts:_(n.counts)?{agents:d(n.counts.agents),tasks:d(n.counts.tasks),keepers:d(n.counts.keepers)}:void 0,provenance:r(n.provenance)??null},execution:{summary:C_(s.summary),top_queue:A_(s.top_queue),provenance:r(s.provenance)??null},command:{active_operations:d(a.active_operations),active_detachments:d(a.active_detachments),pending_approvals:d(a.pending_approvals),bad_alerts:d(a.bad_alerts),warn_alerts:d(a.warn_alerts),moving_lanes:d(a.moving_lanes),active_lanes:d(a.active_lanes),provenance:r(a.provenance)??null},operator:{health:r(o.health)??null,attention_summary:M_(o.attention_summary),recommendation_summary:L_(o.recommendation_summary),pending_confirm_summary:R_(o.pending_confirm_summary),provenance:r(o.provenance)??null},focus:z_(e.focus)}}async function Le(){uo.value=!0,ha.value=null;try{const t=await rp();Jo.value=E_(t)}catch(t){ha.value=t instanceof Error?t.message:"Failed to load room truth"}finally{uo.value=!1}}let ta=null;function P_(t){ta=t}let ea=null;function N_(t){ea=t}let na=null;function j_(t){na=t}const ze={};let vi=null;function Se(t,e,n=500){ze[t]&&clearTimeout(ze[t]),ze[t]=setTimeout(()=>{e(),delete ze[t]},n)}function w_(){const t=ic.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(oo.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),oo.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&Se("execution",Me),t_(e.type)&&(vi||(vi=setTimeout(()=>{$s(),ea==null||ea(),na==null||na(),vi=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&Se("execution",Me),e.type==="broadcast"&&Se("execution",Me),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&Se("execution",Me),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&Se("board",me),e.type.startsWith("decision_")&&Se("council",()=>ta==null?void 0:ta()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&Se("mdal",Dc,350)}});return()=>{t();for(const e of Object.keys(ze))clearTimeout(ze[e]),delete ze[e]}}let wn=null;function O_(){wn||(wn=setInterval(()=>{ge.value,$s()},1e4))}function D_(){wn&&(clearInterval(wn),wn=null)}function qc(t){if(!_(t))return null;const e=r(t.action_type),n=r(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:r(t.description),confirm_required:N(t.confirm_required)}}function Fc(t){if(!_(t))return null;const e=r(t.confirm_token)??r(t.token);return e?{confirm_token:e,actor:r(t.actor),action_type:r(t.action_type),target_type:r(t.target_type),target_id:r(t.target_id)??null,delegated_tool:r(t.delegated_tool),created_at:r(t.created_at),preview:t.preview}:null}function Kc(t){return _(t)?{actor_filter:r(t.actor_filter)??null,filter_active:N(t.filter_active)??!1,visible_count:d(t.visible_count)??0,total_count:d(t.total_count)??0,hidden_count:d(t.hidden_count)??0,hidden_actors:B(t.hidden_actors),confirm_required_actions:dt(t.confirm_required_actions).map(qc).filter(e=>e!==null)}:null}function q_(t){if(!_(t))return null;const e=dt(t.items,["confirms"]).map(Fc).filter(s=>s!==null),n=Kc(t.summary);return!n&&e.length===0?null:{items:e,summary:n??{actor_filter:null,filter_active:!1,visible_count:e.length,total_count:e.length,hidden_count:0,hidden_actors:[],confirm_required_actions:[]}}}function ti(t){var a,o,l,c;const e=(t==null?void 0:t.pending_confirm_envelope)??null,n=(e==null?void 0:e.items)??(t==null?void 0:t.pending_confirms)??[],s=(e==null?void 0:e.summary)??(t==null?void 0:t.pending_confirm_summary)??{actor_filter:null,filter_active:!1,visible_count:n.length,total_count:n.length,hidden_count:0,hidden_actors:[],confirm_required_actions:((a=t==null?void 0:t.available_actions)==null?void 0:a.filter(u=>u.confirm_required))??[]};return{items:n,summary:s,actor_filter:((o=s.actor_filter)==null?void 0:o.trim())||null,visible_count:s.visible_count??n.length,total_count:s.total_count??n.length,hidden_count:s.hidden_count??0,hidden_actors:s.hidden_actors??[],confirm_required_actions:(l=s.confirm_required_actions)!=null&&l.length?s.confirm_required_actions:((c=t==null?void 0:t.available_actions)==null?void 0:c.filter(u=>u.confirm_required))??[]}}const At=g(null),Vo=g(null),Ht=g(null),Yn=g(!1),$e=g(null),Xn=g(!1),fn=g(null),Z=g(!1),ya=g([]);let F_=1;function K_(t){return _(t)?{id:r(t.id),seq:d(t.seq),from:r(t.from)??r(t.from_agent)??"system",content:r(t.content)??"",timestamp:r(t.timestamp)??new Date().toISOString(),type:r(t.type)}:null}function B_(t){return _(t)?{room_id:r(t.room_id),current_room:r(t.current_room)??r(t.room),project:r(t.project),cluster:r(t.cluster),paused:N(t.paused),pause_reason:r(t.pause_reason)??null,paused_by:r(t.paused_by)??null,paused_at:r(t.paused_at)??null}:{}}function dl(t){if(!_(t))return;const e=Object.entries(t).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Bc(t){if(!_(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function On(t){if(!_(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:N(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Uc(t){return _(t)?{enabled:N(t.enabled),judge_online:N(t.judge_online),refreshing:N(t.refreshing),generated_at:r(t.generated_at)??null,expires_at:r(t.expires_at)??null,model_used:r(t.model_used)??null,keeper_name:r(t.keeper_name)??null,last_error:r(t.last_error)??null}:null}function fi(t){return _(t)?{summary:r(t.summary)??null,confidence:d(t.confidence)??null,provenance:r(t.provenance)??null,authoritative:N(t.authoritative),surface:r(t.surface)??null,fresh_until:r(t.fresh_until)??null,keeper_name:r(t.keeper_name)??null,fallback_used:N(t.fallback_used),disagreement_with_truth:N(t.disagreement_with_truth)}:null}function U_(t){return _(t)?{judgment_id:r(t.judgment_id)??void 0,surface:r(t.surface)??null,target_type:r(t.target_type)??null,target_id:r(t.target_id)??null,status:r(t.status)??null,summary:r(t.summary)??null,confidence:d(t.confidence)??null,generated_at:r(t.generated_at)??null,fresh_until:r(t.fresh_until)??null,keeper_name:r(t.keeper_name)??null,model_name:r(t.model_name)??null,runtime_name:r(t.runtime_name)??null,evidence_refs:B(t.evidence_refs),recommended_action:On(t.recommended_action),supersedes:B(t.supersedes),fallback_used:N(t.fallback_used),disagreement_with_truth:N(t.disagreement_with_truth),provenance:r(t.provenance)??null}:null}function H_(t){return _(t)?{actor:r(t.actor)??null,spawn_agent:r(t.spawn_agent)??null,spawn_role:r(t.spawn_role)??null,spawn_model:r(t.spawn_model)??null,worker_class:r(t.worker_class)??null,parent_actor:r(t.parent_actor)??null,capsule_mode:r(t.capsule_mode)??null,runtime_pool:r(t.runtime_pool)??null,lane_id:r(t.lane_id)??null,controller_level:r(t.controller_level)??null,control_domain:r(t.control_domain)??null,supervisor_actor:r(t.supervisor_actor)??null,model_tier:r(t.model_tier)??null,task_profile:r(t.task_profile)??null,risk_level:r(t.risk_level)??null,routing_confidence:d(t.routing_confidence)??null,routing_reason:r(t.routing_reason)??null,status:r(t.status)??"unknown",turn_count:d(t.turn_count)??0,empty_note_turn_count:d(t.empty_note_turn_count)??0,has_turn:N(t.has_turn)??!1,last_turn_ts_iso:r(t.last_turn_ts_iso)??null}:null}function W_(t){if(!_(t))return null;const e=r(t.session_id);return e?{session_id:e,goal:r(t.goal),status:r(t.status),health:r(t.health),scale_profile:r(t.scale_profile),control_profile:r(t.control_profile),planned_worker_count:d(t.planned_worker_count),active_agent_count:d(t.active_agent_count),last_turn_age_sec:d(t.last_turn_age_sec)??null,attention_count:d(t.attention_count),recommended_action_count:d(t.recommended_action_count),top_attention:Bc(t.top_attention),top_recommendation:On(t.top_recommendation)}:null}function ul(t){return _(t)?{loop_id:r(t.loop_id)??null,session_id:r(t.session_id)??null,status:r(t.status)??null,current_cycle:d(t.current_cycle)??void 0,best_score:d(t.best_score)??null,last_decision:r(t.last_decision)??null,target_file:r(t.target_file)??null,program_note:r(t.program_note)??null,operation_id:r(t.operation_id)??null,error:r(t.error)??null}:null}function Hc(t){const e=_(t)?t:{};return{trace_id:r(e.trace_id),target_type:r(e.target_type)??"room",target_id:r(e.target_id)??null,health:r(e.health),judgment_owner:r(e.judgment_owner)??null,authoritative_judgment_available:N(e.authoritative_judgment_available),resident_judge_runtime:Uc(e.resident_judge_runtime),judgment:U_(e.judgment),active_guidance_layer:r(e.active_guidance_layer)??null,active_summary:fi(e.active_summary),active_recommended_actions:dt(e.active_recommended_actions).map(On).filter(n=>n!==null),active_recommendation_source:r(e.active_recommendation_source)??null,active_recommendation_summary:fi(e.active_recommendation_summary),fallback_recommended_actions:dt(e.fallback_recommended_actions).map(On).filter(n=>n!==null),recommendation_summary:fi(e.recommendation_summary),swarm_status:_(e.swarm_status)?e.swarm_status:void 0,attention_items:dt(e.attention_items).map(Bc).filter(n=>n!==null),recommended_actions:dt(e.recommended_actions).map(On).filter(n=>n!==null),session_cards:dt(e.session_cards).map(W_).filter(n=>n!==null),worker_cards:dt(e.worker_cards).map(H_).filter(n=>n!==null)}}function G_(t){if(!_(t))return null;const e=_(t.status)?t.status:void 0,n=_(t.summary)?t.summary:_(e==null?void 0:e.summary)?e.summary:void 0,s=_(t.session)?t.session:_(e==null?void 0:e.session)?e.session:void 0,a=r(t.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const o=dl(t.report_paths)??dl(e==null?void 0:e.report_paths),l=dt(t.recent_events,["events"]).filter(_);return{session_id:a,status:r(t.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:d(t.progress_pct)??d(n==null?void 0:n.progress_pct),elapsed_sec:d(t.elapsed_sec)??d(n==null?void 0:n.elapsed_sec),remaining_sec:d(t.remaining_sec)??d(n==null?void 0:n.remaining_sec),done_delta_total:d(t.done_delta_total)??d(n==null?void 0:n.done_delta_total),summary:n,team_health:_(t.team_health)?t.team_health:_(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:_(t.communication_metrics)?t.communication_metrics:_(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:_(t.orchestration_state)?t.orchestration_state:_(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:_(t.cascade_metrics)?t.cascade_metrics:_(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,linked_autoresearch:ul(t.linked_autoresearch)??ul(e==null?void 0:e.linked_autoresearch)??null,session:s,recent_events:l}}function pl(t){if(!_(t))return null;const e=r(t.name);if(!e)return null;const n=_(t.context)?t.context:void 0;return{name:e,runtime_class:t.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:N(t.desired),resident_registered:N(t.resident_registered),agent_name:r(t.agent_name),status:r(t.status),autonomy_level:r(t.autonomy_level),context_ratio:d(t.context_ratio)??d(n==null?void 0:n.context_ratio),generation:d(t.generation),active_goal_ids:B(t.active_goal_ids),last_autonomous_action_at:r(t.last_autonomous_action_at)??null,last_turn_ago_s:d(t.last_turn_ago_s),model:r(t.model)??r(t.active_model)??r(t.primary_model)}}function J_(t){const e=_(t)?t:{},n=q_(e.pending_confirm_envelope);return{room:B_(e.room),sessions:dt(e.sessions,["items","sessions"]).map(G_).filter(s=>s!==null),keepers:dt(e.keepers,["items","keepers"]).map(pl).filter(s=>s!==null),resident_judge_runtime:Uc(e.resident_judge_runtime),persistent_agents:dt(e.persistent_agents,["items","persistent_agents"]).map(pl).filter(s=>s!==null),recent_messages:dt(e.recent_messages,["messages"]).map(K_).filter(s=>s!==null),pending_confirms:(n==null?void 0:n.items)??dt(e.pending_confirms,["items","confirms"]).map(Fc).filter(s=>s!==null),pending_confirm_envelope:n??void 0,pending_confirm_summary:(n==null?void 0:n.summary)??Kc(e.pending_confirm_summary)??void 0,available_actions:dt(e.available_actions,["actions"]).map(qc).filter(s=>s!==null)}}function Es(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function ml(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function ba(t){ya.value=[{...t,id:F_++,at:new Date().toISOString()},...ya.value].slice(0,20)}function Wc(t){return t.confirm_required?Es(t.preview)||"Confirmation required":Es(t.result)||Es(t.executed_action)||Es(t.delegated_tool_result)||t.status}async function gt(){Yn.value=!0,$e.value=null;try{const t=await hp();At.value=J_(t)}catch(t){$e.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Yn.value=!1}}async function Oe(){Xn.value=!0,fn.value=null;try{const t=await pc({targetType:"room"});Vo.value=Hc(t)}catch(t){fn.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{Xn.value=!1}}async function De(t){if(!t){Ht.value=null;return}Xn.value=!0,fn.value=null;try{const e=await pc({targetType:"team_session",targetId:t,includeWorkers:!0});Ht.value=Hc(e)}catch(e){fn.value=e instanceof Error?e.message:"Failed to load session digest"}finally{Xn.value=!1}}async function Gc(t){var e;Z.value=!0,$e.value=null;try{const n=await Xa(t);return ba({actor:t.actor,action_type:t.action_type,target_label:ml(t),outcome:n.confirm_required?"preview":"executed",message:Wc(n),delegated_tool:n.delegated_tool}),await gt(),await Oe(),(e=Ht.value)!=null&&e.target_id&&await De(Ht.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw $e.value=s,ba({actor:t.actor,action_type:t.action_type,target_label:ml(t),outcome:"error",message:s}),n}finally{Z.value=!1}}async function Jc(t,e,n="confirm"){var s;Z.value=!0,$e.value=null;try{const a=await Rp(t,e,n);return ba({actor:t,action_type:n,target_label:e,outcome:"confirmed",message:Wc(a),delegated_tool:a.delegated_tool}),await gt(),await Oe(),(s=Ht.value)!=null&&s.target_id&&await De(Ht.value.target_id),a}catch(a){const o=a instanceof Error?a.message:"Operator confirmation failed";throw $e.value=o,ba({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:o}),a}finally{Z.value=!1}}j_(()=>{var t;gt(),Oe(),(t=Ht.value)!=null&&t.target_id&&De(Ht.value.target_id)});const hs=g(null),po=g(!1),ka=g(null),Vc=g(null),Ve=g(!1),Ie=g(null),mo=g(null),sa=g(!1),aa=g(null);let ln=null;function _l(){ln!==null&&(window.clearTimeout(ln),ln=null)}function V_(t=1500){ln===null&&(ln=window.setTimeout(()=>{ln=null,xa(!1)},t))}function w(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function y(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function q(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function cn(t){return typeof t=="boolean"?t:void 0}function J(t,e=[]){if(Array.isArray(t))return t;if(!w(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function bn(t){if(!w(t))return null;const e=y(t.kind),n=y(t.summary),s=y(t.target_type);return!e||!n||!s?null:{kind:e,severity:y(t.severity)??"warn",summary:n,target_type:s,target_id:y(t.target_id)??null,actor:y(t.actor)??null,evidence:t.evidence}}function Ke(t){if(!w(t))return null;const e=y(t.action_type),n=y(t.target_type),s=y(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:y(t.target_id)??null,severity:y(t.severity)??"warn",reason:s,confirm_required:cn(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Y_(t){if(!w(t))return null;const e=y(t.session_id);return e?{session_id:e,goal:y(t.goal),status:y(t.status),health:y(t.health),scale_profile:y(t.scale_profile),control_profile:y(t.control_profile),planned_worker_count:q(t.planned_worker_count),active_agent_count:q(t.active_agent_count),last_turn_age_sec:q(t.last_turn_age_sec)??null,attention_count:q(t.attention_count),recommended_action_count:q(t.recommended_action_count),top_attention:bn(t.top_attention),top_recommendation:Ke(t.top_recommendation)}:null}function X_(t){if(!w(t))return null;const e=y(t.session_id);if(!e)return null;const n=w(t.status)?t.status:t,s=w(n.summary)?n.summary:void 0;return{session_id:e,status:y(t.status)??y(s==null?void 0:s.status)??(w(n.session)?y(n.session.status):void 0),progress_pct:q(t.progress_pct)??q(s==null?void 0:s.progress_pct),elapsed_sec:q(t.elapsed_sec)??q(s==null?void 0:s.elapsed_sec),remaining_sec:q(t.remaining_sec)??q(s==null?void 0:s.remaining_sec),done_delta_total:q(t.done_delta_total)??q(s==null?void 0:s.done_delta_total),summary:w(t.summary)?t.summary:s,team_health:w(t.team_health)?t.team_health:w(n.team_health)?n.team_health:void 0,communication_metrics:w(t.communication_metrics)?t.communication_metrics:w(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:w(t.orchestration_state)?t.orchestration_state:w(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:w(t.cascade_metrics)?t.cascade_metrics:w(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:w(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,o])=>{const l=y(o);return l?[a,l]:null}).filter(a=>a!==null)):w(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const l=y(o);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:w(t.session)?t.session:w(n.session)?n.session:void 0,recent_events:J(t.recent_events,["events"]).filter(w)}}function Q_(t){if(!w(t))return null;const e=y(t.name);return e?{name:e,agent_name:y(t.agent_name),status:y(t.status),autonomy_level:y(t.autonomy_level),context_ratio:q(t.context_ratio),generation:q(t.generation),active_goal_ids:J(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:y(t.last_autonomous_action_at)??null,last_turn_ago_s:q(t.last_turn_ago_s),model:y(t.model)}:null}function Z_(t){if(!w(t))return null;const e=y(t.confirm_token)??y(t.token);return e?{confirm_token:e,actor:y(t.actor),action_type:y(t.action_type),target_type:y(t.target_type),target_id:y(t.target_id)??null,delegated_tool:y(t.delegated_tool),created_at:y(t.created_at),preview:t.preview}:null}function tv(t){if(!w(t))return null;const e=y(t.action_type),n=y(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:y(t.description),confirm_required:cn(t.confirm_required)}}function ev(t){const e=w(t)?t:{};return{room_health:y(e.room_health),cluster:y(e.cluster),project:y(e.project),current_room:y(e.current_room)??y(e.room)??null,paused:cn(e.paused),tempo_interval_s:q(e.tempo_interval_s),active_agents:q(e.active_agents),keeper_pressure:q(e.keeper_pressure),active_operations:q(e.active_operations),pending_approvals:q(e.pending_approvals),incident_count:q(e.incident_count),recommended_action_count:q(e.recommended_action_count),top_attention:bn(e.top_attention),top_action:Ke(e.top_action)}}function nv(t){const e=w(t)?t:{},n=w(e.swarm_overview)?e.swarm_overview:{};return{health:y(e.health),active_operations:q(e.active_operations),pending_approvals:q(e.pending_approvals),swarm_overview:{active_lanes:q(n.active_lanes),moving_lanes:q(n.moving_lanes),stalled_lanes:q(n.stalled_lanes),projected_lanes:q(n.projected_lanes),last_movement_at:y(n.last_movement_at)??null},top_attention:bn(e.top_attention),top_action:Ke(e.top_action),session_cards:J(e.session_cards).map(Y_).filter(s=>s!==null)}}function sv(t){const e=w(t)?t:{};return{sessions:J(e.sessions,["items"]).map(X_).filter(n=>n!==null),keepers:J(e.keepers,["items"]).map(Q_).filter(n=>n!==null),pending_confirms:J(e.pending_confirms).map(Z_).filter(n=>n!==null),available_actions:J(e.available_actions).map(tv).filter(n=>n!==null)}}function av(t){if(!w(t))return null;const e=y(t.id),n=y(t.kind),s=y(t.summary),a=y(t.target_type);return!e||!n||!s||!a?null:{id:e,kind:n,severity:y(t.severity)??"warn",summary:s,target_type:a,target_id:y(t.target_id)??null,top_action:Ke(t.top_action),related_session_ids:J(t.related_session_ids).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),related_agent_names:J(t.related_agent_names).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),evidence_preview:J(t.evidence_preview).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),last_seen_at:y(t.last_seen_at)??null}}function Yc(t){if(!w(t))return null;const e=y(t.session_id),n=y(t.goal);return!e||!n?null:{session_id:e,goal:n,room:y(t.room)??null,status:y(t.status),health:y(t.health),member_names:J(t.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:y(t.started_at)??null,elapsed_sec:q(t.elapsed_sec)??null,operation_id:y(t.operation_id)??null,blocker_summary:y(t.blocker_summary)??null,last_event_at:y(t.last_event_at)??null,last_event_summary:y(t.last_event_summary)??null,communication_summary:y(t.communication_summary)??null,active_count:q(t.active_count),required_count:q(t.required_count),related_attention_count:q(t.related_attention_count)??0,top_attention:bn(t.top_attention),top_recommendation:Ke(t.top_recommendation)}}function Xc(t){if(!w(t))return null;const e=y(t.agent_name);return e?{agent_name:e,display_name:y(t.display_name)??null,is_live:typeof t.is_live=="boolean"?t.is_live:void 0,current_work:y(t.current_work)??null,recent_input_preview:y(t.recent_input_preview)??null,recent_output_preview:y(t.recent_output_preview)??null,recent_tool_names:J(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_activity_at:y(t.last_activity_at)??null}:null}function Qc(t){if(!w(t))return null;const e=y(t.operation_id);return e?{operation_id:e,status:y(t.status),stage:y(t.stage)??null,detachment_status:y(t.detachment_status)??null,objective:y(t.objective)??null,updated_at:y(t.updated_at)??null}:null}function Zc(t){if(!w(t))return null;const e=y(t.name);return e?{name:e,agent_name:y(t.agent_name)??null,status:y(t.status),generation:q(t.generation),context_ratio:q(t.context_ratio)??null,last_turn_ago_s:q(t.last_turn_ago_s)??null,current_work:y(t.current_work)??null}:null}function td(t){const e=Yc(t);return e?{...e,member_previews:J(w(t)?t.member_previews:void 0).map(Xc).filter(n=>n!==null),operation_badges:J(w(t)?t.operation_badges:void 0).map(Qc).filter(n=>n!==null),keeper_refs:J(w(t)?t.keeper_refs:void 0).map(Zc).filter(n=>n!==null)}:null}function iv(t){if(!w(t))return null;const e=y(t.agent_name);return e?{agent_name:e,display_name:y(t.display_name)??null,is_live:typeof t.is_live=="boolean"?t.is_live:void 0,archived_reason:y(t.archived_reason)??null,status:y(t.status),where:y(t.where)??null,with_whom:J(t.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:y(t.current_work)??null,related_session_id:y(t.related_session_id)??null,related_attention_count:q(t.related_attention_count)??0,last_activity_at:y(t.last_activity_at)??null,recent_output_preview:y(t.recent_output_preview)??null,recent_input_preview:y(t.recent_input_preview)??null,recent_tool_names:J(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean)}:null}function ov(t){if(!w(t))return null;const e=y(t.name);return e?{name:e,agent_name:y(t.agent_name)??null,status:y(t.status),generation:q(t.generation),context_ratio:q(t.context_ratio)??null,last_turn_ago_s:q(t.last_turn_ago_s)??null,current_work:y(t.current_work)??null,last_autonomous_action_at:y(t.last_autonomous_action_at)??null,allowed_tool_names:J(t.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:J(t.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:q(t.latest_tool_call_count)??null,tool_audit_source:y(t.tool_audit_source)??null,tool_audit_at:y(t.tool_audit_at)??null}:null}function rv(t){if(!w(t))return null;const e=y(t.id),n=y(t.signal_type),s=y(t.summary),a=y(t.target_type);return!e||!n||!s||!a?null:{id:e,signal_type:n==="action"?"action":"attention",severity:y(t.severity)??"warn",summary:s,target_type:a,target_id:y(t.target_id)??null,attention:bn(t.attention),action:Ke(t.action)}}function lv(t){const e=w(t)?t:{},n=J(e.session_briefs).map(Yc).filter(a=>a!==null),s=J(e.sessions).map(td).filter(a=>a!==null);return{generated_at:y(e.generated_at),summary:ev(e.summary),incidents:J(e.incidents).map(bn).filter(a=>a!==null),recommended_actions:J(e.recommended_actions).map(Ke).filter(a=>a!==null),command_focus:nv(e.command_focus),operator_targets:sv(e.operator_targets),attention_queue:J(e.attention_queue).map(av).filter(a=>a!==null),sessions:s.length>0?s:n.map(a=>({...a,member_previews:[],operation_badges:[],keeper_refs:[]})),session_briefs:n,agent_briefs:J(e.agent_briefs).map(iv).filter(a=>a!==null),keeper_briefs:J(e.keeper_briefs).map(ov).filter(a=>a!==null),internal_signals:J(e.internal_signals).map(rv).filter(a=>a!==null)}}function cv(t){if(!w(t))return null;const e=y(t.id),n=y(t.summary);return!e||!n?null:{id:e,timestamp:y(t.timestamp)??null,event_type:y(t.event_type),actor:y(t.actor)??null,summary:n}}function dv(t){const e=w(t)?t:{};return{generated_at:y(e.generated_at),session_id:y(e.session_id)??"",session:td(e.session),timeline:J(e.timeline).map(cv).filter(n=>n!==null),participants:J(e.participants).map(Xc).filter(n=>n!==null),operations:J(e.operations).map(Qc).filter(n=>n!==null),keepers:J(e.keepers).map(Zc).filter(n=>n!==null),error:y(e.error)??null}}function uv(t){if(!w(t))return null;const e=y(t.id),n=y(t.label),s=y(t.summary);if(!e||!n||!s)return null;const a=y(t.status)??"unclear";return{id:e,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:y(t.signal_class)==="metadata_gap"||y(t.signal_class)==="mixed"||y(t.signal_class)==="operational_risk"?y(t.signal_class):void 0,evidence_quality:y(t.evidence_quality)==="strong"||y(t.evidence_quality)==="partial"||y(t.evidence_quality)==="missing"?y(t.evidence_quality):void 0,evidence:J(t.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function pv(t){if(!w(t))return null;const e=y(t.kind),n=y(t.summary),s=y(t.scope_type),a=y(t.severity);return!e||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:e,summary:n,scope_type:s,scope_id:y(t.scope_id)??null,severity:a}}function mv(t){const e=w(t)?t:{},n=w(e.basis)?e.basis:{},s=y(e.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:y(e.generated_at),cached:cn(e.cached),stale:cn(e.stale),refreshing:cn(e.refreshing),status:a,summary:y(e.summary)??null,model:y(e.model)??null,ttl_sec:q(e.ttl_sec),criteria:J(e.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:y(n.current_room)??null,crew_count:q(n.crew_count),agent_count:q(n.agent_count),keeper_count:q(n.keeper_count)},metadata_gap_count:q(e.metadata_gap_count),metadata_gaps:J(e.metadata_gaps).map(pv).filter(o=>o!==null),sections:J(e.sections).map(uv).filter(o=>o!==null),error:y(e.error)??null,last_error:y(e.last_error)??null}}async function ed(){po.value=!0,ka.value=null;try{const t=await pp();hs.value=lv(t)}catch(t){ka.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{po.value=!1}}async function _v(t){if(!t){mo.value=null,aa.value=null,sa.value=!1;return}sa.value=!0,aa.value=null;try{const e=await mp(t);mo.value=dv(e)}catch(e){aa.value=e instanceof Error?e.message:"Failed to load session detail"}finally{sa.value=!1}}async function xa(t=!1){Ve.value=!0,Ie.value=null;try{const e=await _p(t),n=mv(e);Vc.value=n,n.refreshing||n.status==="pending"?V_():_l()}catch(e){Ie.value=e instanceof Error?e.message:"Failed to load mission briefing",_l()}finally{Ve.value=!1}}const nd=g(null),_o=g(!1),Ye=g(null);async function sd(t,e){_o.value=!0,Ye.value=null;try{nd.value=await vp(t,e)}catch(n){Ye.value=n instanceof Error?n.message:String(n)}finally{_o.value=!1}}const Yo=g(null),Jt=g(null),Sa=g(!1),Ca=g(!1),Aa=g(null),Ta=g(null),vo=g(null),Ia=g(null),V=g("warroom"),ys=g(null),fo=g(!1),Ra=g(null),Be=g(null),Ma=g(!1),La=g(null),Xo=g(null),go=g(!1),za=g(null),bs=g(null),$o=g(!1),Ea=g(null),Qn=g(null),Pa=g(!1),Zn=g(null),dn=g(null);let Ln=null;function Qo(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"&&t!=="orchestra"}function ad(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function id(){const e=ad().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function od(){const e=ad().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function vv(t){if(_(t))return{policy_class:r(t.policy_class),approval_class:r(t.approval_class),tool_allowlist:B(t.tool_allowlist),model_allowlist:B(t.model_allowlist),requires_human_for:B(t.requires_human_for),autonomy_level:r(t.autonomy_level),escalation_timeout_sec:d(t.escalation_timeout_sec),kill_switch:N(t.kill_switch),frozen:N(t.frozen)}}function fv(t){if(_(t))return{headcount_cap:d(t.headcount_cap),active_operation_cap:d(t.active_operation_cap),max_cost_usd:d(t.max_cost_usd),max_tokens:d(t.max_tokens)}}function Zo(t){if(!_(t))return null;const e=r(t.unit_id),n=r(t.label),s=r(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:r(t.parent_unit_id)??null,leader_id:r(t.leader_id)??null,roster:B(t.roster),capability_profile:B(t.capability_profile),source:r(t.source),created_at:r(t.created_at),updated_at:r(t.updated_at),policy:vv(t.policy),budget:fv(t.budget)}}function rd(t){if(!_(t))return null;const e=Zo(t.unit);return e?{unit:e,leader_status:r(t.leader_status),roster_total:d(t.roster_total),roster_live:d(t.roster_live),active_operation_count:d(t.active_operation_count),health:r(t.health),reasons:B(t.reasons),children:Array.isArray(t.children)?t.children.map(rd).filter(n=>n!==null):[]}:null}function gv(t){if(_(t))return{total_units:d(t.total_units),company_count:d(t.company_count),platoon_count:d(t.platoon_count),squad_count:d(t.squad_count),leaf_agent_unit_count:d(t.leaf_agent_unit_count),live_agent_count:d(t.live_agent_count),managed_unit_count:d(t.managed_unit_count),active_operation_count:d(t.active_operation_count)}}function ld(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),source:r(e.source),summary:gv(e.summary),units:Array.isArray(e.units)?e.units.map(rd).filter(n=>n!==null):[]}}function $v(t){if(!_(t))return null;const e=r(t.kind),n=r(t.status);return!e||!n?null:{kind:e,chain_id:r(t.chain_id)??null,goal:r(t.goal)??null,run_id:r(t.run_id)??null,status:n,viewer_path:r(t.viewer_path)??null,last_sync_at:r(t.last_sync_at)??null}}function ei(t){if(!_(t))return null;const e=r(t.operation_id),n=r(t.objective),s=r(t.assigned_unit_id),a=r(t.trace_id),o=r(t.status);return!e||!n||!s||!a||!o?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:r(t.autonomy_level),policy_class:r(t.policy_class),budget_class:r(t.budget_class),detachment_session_id:r(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(t.checkpoint_ref)??null,active_goal_ids:B(t.active_goal_ids),note:r(t.note)??null,created_by:r(t.created_by),source:r(t.source),status:o,chain:$v(t.chain),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function hv(t){if(!_(t))return null;const e=ei(t.operation);return e?{operation:e,assigned_unit_label:r(t.assigned_unit_label)}:null}function Tn(t){if(_(t))return{tone:r(t.tone),pending_ops:d(t.pending_ops),blocked_ops:d(t.blocked_ops),in_flight_ops:d(t.in_flight_ops),pipeline_stalls:d(t.pipeline_stalls),bus_traffic:d(t.bus_traffic),l1_hit_rate:d(t.l1_hit_rate),invalidation_count:d(t.invalidation_count),current_pending:d(t.current_pending),current_in_flight:d(t.current_in_flight),cdb_wakeups:d(t.cdb_wakeups),total_stolen:d(t.total_stolen),avg_best_score:d(t.avg_best_score),avg_candidate_count:d(t.avg_candidate_count),best_first_operations:d(t.best_first_operations),active_sessions:d(t.active_sessions),commit_rate:d(t.commit_rate),total_speculations:d(t.total_speculations)}}function yv(t){if(!_(t))return;const e=_(t.pipeline)?t.pipeline:void 0,n=_(t.cache)?t.cache:void 0,s=_(t.ooo)?t.ooo:void 0,a=_(t.speculative)?t.speculative:void 0,o=_(t.search_fabric)?t.search_fabric:void 0,l=_(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:d(e.total_ops),completed_ops:d(e.completed_ops),stalled_cycles:d(e.stalled_cycles),hazards_detected:d(e.hazards_detected),forwarding_used:d(e.forwarding_used),pipeline_flushes:d(e.pipeline_flushes),ipc:d(e.ipc)}:void 0,cache:n?{total_reads:d(n.total_reads),total_writes:d(n.total_writes),l1_hit_rate:d(n.l1_hit_rate),invalidation_count:d(n.invalidation_count),writeback_count:d(n.writeback_count),bus_traffic:d(n.bus_traffic)}:void 0,ooo:s?{agent_count:d(s.agent_count),total_added:d(s.total_added),total_issued:d(s.total_issued),total_completed:d(s.total_completed),total_stolen:d(s.total_stolen),cdb_wakeups:d(s.cdb_wakeups),stall_cycles:d(s.stall_cycles),global_cdb_events:d(s.global_cdb_events),current_pending:d(s.current_pending),current_in_flight:d(s.current_in_flight)}:void 0,speculative:a?{total_speculations:d(a.total_speculations),total_commits:d(a.total_commits),total_aborts:d(a.total_aborts),commit_rate:d(a.commit_rate),total_fast_calls:d(a.total_fast_calls),total_cost_usd:d(a.total_cost_usd),active_sessions:d(a.active_sessions)}:void 0,search_fabric:o?{total_operations:d(o.total_operations),best_first_operations:d(o.best_first_operations),legacy_operations:d(o.legacy_operations),blocked_operations:d(o.blocked_operations),ready_operations:d(o.ready_operations),research_pipeline_operations:d(o.research_pipeline_operations),avg_candidate_count:d(o.avg_candidate_count),avg_best_score:d(o.avg_best_score),top_stage:r(o.top_stage)??null}:void 0,signals:l?{issue_pressure:Tn(l.issue_pressure),cache_contention:Tn(l.cache_contention),scheduler_efficiency:Tn(l.scheduler_efficiency),routing_confidence:Tn(l.routing_confidence),speculative_posture:Tn(l.speculative_posture)}:void 0}}function cd(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),active:d(n.active),paused:d(n.paused),managed:d(n.managed),projected:d(n.projected)}:void 0,microarch:yv(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(hv).filter(s=>s!==null):[]}}function dd(t){if(!_(t))return null;const e=r(t.detachment_id),n=r(t.operation_id),s=r(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:r(t.leader_id)??null,roster:B(t.roster),session_id:r(t.session_id)??null,checkpoint_ref:r(t.checkpoint_ref)??null,runtime_kind:r(t.runtime_kind)??null,runtime_ref:r(t.runtime_ref)??null,source:r(t.source),status:r(t.status),last_event_at:r(t.last_event_at)??null,last_progress_at:r(t.last_progress_at)??null,heartbeat_deadline:r(t.heartbeat_deadline)??null,created_at:r(t.created_at),updated_at:r(t.updated_at)}}function bv(t){if(!_(t))return null;const e=dd(t.detachment);return e?{detachment:e,assigned_unit_label:r(t.assigned_unit_label),operation:ei(t.operation)}:null}function ud(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),active:d(n.active),projected:d(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(bv).filter(s=>s!==null):[]}}function kv(t){if(!_(t))return null;const e=r(t.decision_id),n=r(t.trace_id),s=r(t.requested_action),a=r(t.scope_type),o=r(t.scope_id);return!e||!n||!s||!a||!o?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:r(t.operation_id)??null,target_unit_id:r(t.target_unit_id)??null,requested_by:r(t.requested_by),status:r(t.status),reason:r(t.reason)??null,source:r(t.source),detail:t.detail,created_at:r(t.created_at),decided_at:r(t.decided_at)??null,expires_at:r(t.expires_at)??null}}function pd(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),pending:d(n.pending),approved:d(n.approved),denied:d(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(kv).filter(s=>s!==null):[]}}function xv(t){if(!_(t))return null;const e=Zo(t.unit);return e?{unit:e,roster_total:d(t.roster_total),roster_live:d(t.roster_live),headcount_cap:d(t.headcount_cap),active_operations:d(t.active_operations),active_operation_cap:d(t.active_operation_cap),utilization:d(t.utilization)}:null}function Sv(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(xv).filter(n=>n!==null):[]}}function Cv(t){if(!_(t))return null;const e=r(t.alert_id);return e?{alert_id:e,severity:r(t.severity),kind:r(t.kind),scope_type:r(t.scope_type),scope_id:r(t.scope_id),title:r(t.title),detail:r(t.detail),timestamp:r(t.timestamp)}:null}function md(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),bad:d(n.bad),warn:d(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(Cv).filter(s=>s!==null):[]}}function _d(t){if(!_(t))return null;const e=r(t.event_id),n=r(t.trace_id),s=r(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:r(t.operation_id)??null,unit_id:r(t.unit_id)??null,actor:r(t.actor)??null,source:r(t.source),timestamp:r(t.timestamp),detail:t.detail}}function Av(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),events:Array.isArray(e.events)?e.events.map(_d).filter(n=>n!==null):[]}}function Tv(t){if(!_(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function Iv(t){if(!_(t))return null;const e=r(t.lane_id),n=r(t.label),s=r(t.kind),a=r(t.phase),o=r(t.motion_state),l=r(t.source_of_truth),c=r(t.movement_reason),u=r(t.current_step);if(!e||!n||!s||!a||!o||!l||!c||!u)return null;const m=_(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:N(t.present)??!1,phase:a,motion_state:o,source_of_truth:l,last_movement_at:r(t.last_movement_at)??null,movement_reason:c,current_step:u,blockers:B(t.blockers),counts:{operations:d(m.operations),detachments:d(m.detachments),workers:d(m.workers),approvals:d(m.approvals),alerts:d(m.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(Tv).filter(p=>p!==null):[]}}function Rv(t){if(!_(t))return null;const e=r(t.event_id),n=r(t.lane_id),s=r(t.kind),a=r(t.timestamp),o=r(t.title),l=r(t.detail),c=r(t.tone),u=r(t.source);return!e||!n||!s||!a||!o||!l||!c||!u?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:o,detail:l,tone:c,source:u}}function Mv(t){if(!_(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,why_it_matters:r(t.why_it_matters)??void 0,next_tool:r(t.next_tool)??void 0,next_step:r(t.next_step)??void 0,lane_ids:B(t.lane_ids),count:d(t.count)??0}}function tr(t){if(!_(t))return;const e=_(t.overview)?t.overview:{},n=_(t.gaps)?t.gaps:{},s=_(t.narrative)?t.narrative:{},a=_(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:r(t.generated_at),narrative:{state:r(s.state)??void 0,started:r(s.started)??void 0,active_work:r(s.active_work)??void 0,completion:r(s.completion)??void 0,lane_id:r(s.lane_id)??null},overview:{active_lanes:d(e.active_lanes),moving_lanes:d(e.moving_lanes),stalled_lanes:d(e.stalled_lanes),projected_lanes:d(e.projected_lanes),last_movement_at:r(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(Iv).filter(o=>o!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(Rv).filter(o=>o!==null):[],gaps:{count:d(n.count),items:Array.isArray(n.items)?n.items.map(Mv).filter(o=>o!==null):[]},recommended_next_action:a?{tool:r(a.tool)??"masc_operator_snapshot",label:r(a.label)??"Observe operator state",reason:r(a.reason)??"",lane_id:r(a.lane_id)??null}:void 0}}function vd(t){if(!_(t))return;const e=_(t.workers)?t.workers:{},n=N(t.pass);return{status:r(t.status)??"missing",source:r(t.source)??"none",reason_code:r(t.reason_code)??null,status_summary:r(t.status_summary)??null,run_id:r(t.run_id)??null,captured_at:r(t.captured_at)??null,...n!==void 0?{pass:n}:{},...d(t.peak_hot_slots)!=null?{peak_hot_slots:d(t.peak_hot_slots)}:{},...d(t.ctx_per_slot)!=null?{ctx_per_slot:d(t.ctx_per_slot)}:{},workers:{expected:d(e.expected),joined:d(e.joined),current_task_bound:d(e.current_task_bound),fresh_heartbeats:d(e.fresh_heartbeats),done:d(e.done),final:d(e.final)},expected_artifact_dir:r(t.expected_artifact_dir)??null,artifact_ref:r(t.artifact_ref)??null,missing_reason:r(t.missing_reason)??null}}function Lv(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),topology:ld(e.topology),operations:cd(e.operations),detachments:ud(e.detachments),alerts:md(e.alerts),decisions:pd(e.decisions),capacity:Sv(e.capacity),traces:Av(e.traces),swarm_status:tr(e.swarm_status)}}function zv(t){const e=_(t)?t:{},n=ld(e.topology),s=cd(e.operations),a=ud(e.detachments),o=md(e.alerts),l=pd(e.decisions);return{version:r(e.version),generated_at:r(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:tr(e.swarm_status),swarm_proof:vd(e.swarm_proof)}}function Ev(t){return _(t)?{chain_id:r(t.chain_id)??null,started_at:d(t.started_at)??null,progress:d(t.progress)??null,elapsed_sec:d(t.elapsed_sec)??null}:null}function fd(t){if(!_(t))return null;const e=r(t.event);return e?{event:e,chain_id:r(t.chain_id)??null,timestamp:r(t.timestamp)??null,duration_ms:d(t.duration_ms)??null,message:r(t.message)??null,tokens:d(t.tokens)??null}:null}function Pv(t){if(!_(t))return null;const e=ei(t.operation);return e?{operation:e,runtime:Ev(t.runtime),history:fd(t.history),mermaid:r(t.mermaid)??null,preview_run:gd(t.preview_run)}:null}function Nv(t){const e=_(t)?t:{};return{status:r(e.status)??"disconnected",base_url:r(e.base_url)??null,message:r(e.message)??null}}function jv(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),connection:Nv(e.connection),summary:n?{linked_operations:d(n.linked_operations),active_chains:d(n.active_chains),running_operations:d(n.running_operations),recent_failures:d(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Pv).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(fd).filter(s=>s!==null):[]}}function wv(t){if(!_(t))return null;const e=r(t.id);return e?{id:e,type:r(t.type),status:r(t.status),duration_ms:d(t.duration_ms)??null,error:r(t.error)??null}:null}function gd(t){if(!_(t))return null;const e=r(t.run_id),n=r(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:d(t.duration_ms),success:N(t.success),mermaid:r(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(wv).filter(s=>s!==null):[]}:null}function Ov(t){const e=_(t)?t:{};return{run:gd(e.run)}}function Dv(t){if(!_(t))return null;const e=r(t.title),n=r(t.path);return!e||!n?null:{title:e,path:n}}function qv(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function Fv(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.tool),a=r(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:B(t.success_signals),pitfalls:B(t.pitfalls)}}function Kv(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary),a=r(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(Fv).filter(o=>o!==null):[]}}function Bv(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:B(t.tools)}}function Uv(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.symptom),a=r(t.why),o=r(t.fix_tool),l=r(t.fix_summary);return!e||!n||!s||!a||!o||!l?null:{id:e,title:n,symptom:s,why:a,fix_tool:o,fix_summary:l}}function Hv(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.path_id),a=r(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:B(t.notes)}}function Wv(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Dv).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(qv).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Kv).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Bv).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Uv).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Hv).filter(n=>n!==null):[]}}function Gv(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.status),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{id:e,title:n,status:s,detail:a,next_tool:o}}function Jv(t){if(!_(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.title),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{code:e,severity:n,title:s,detail:a,next_tool:o}}function Vv(t){if(!_(t))return null;const e=r(t.from),n=r(t.content),s=r(t.timestamp),a=d(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function Yv(t){if(!_(t))return null;const e=r(t.name),n=r(t.role),s=r(t.lane),a=r(t.status),o=r(t.claim_marker),l=r(t.done_marker),c=r(t.final_marker);if(!e||!n||!s||!a||!o||!l||!c)return null;const u=(()=>{if(!_(t.last_message))return null;const m=d(t.last_message.seq),p=r(t.last_message.content),v=r(t.last_message.timestamp);return m==null||!p||!v?null:{seq:m,content:p,timestamp:v}})();return{name:e,role:n,lane:s,joined:N(t.joined)??!1,live_presence:N(t.live_presence)??!1,completed:N(t.completed)??!1,status:a,current_task:r(t.current_task)??null,bound_task_id:r(t.bound_task_id)??null,bound_task_title:r(t.bound_task_title)??null,bound_task_status:r(t.bound_task_status)??null,current_task_matches_run:N(t.current_task_matches_run)??!1,squad_member:N(t.squad_member)??!1,detachment_member:N(t.detachment_member)??!1,last_seen:r(t.last_seen)??null,heartbeat_age_sec:d(t.heartbeat_age_sec)??null,heartbeat_fresh:N(t.heartbeat_fresh)??!1,claim_marker_seen:N(t.claim_marker_seen)??!1,done_marker_seen:N(t.done_marker_seen)??!1,final_marker_seen:N(t.final_marker_seen)??!1,claim_marker:o,done_marker:l,final_marker:c,last_message:u}}function Xv(t){if(!_(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!_(n))return null;const s=r(n.timestamp),a=d(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:r(t.slot_url)??null,provider_base_url:r(t.provider_base_url)??null,provider_reachable:N(t.provider_reachable)??null,provider_status_code:d(t.provider_status_code)??null,provider_model_id:r(t.provider_model_id)??null,actual_model_id:r(t.actual_model_id)??null,expected_slots:d(t.expected_slots),actual_slots:d(t.actual_slots),expected_ctx:d(t.expected_ctx),actual_ctx:d(t.actual_ctx),configured_capacity:d(t.configured_capacity),slot_reachable:N(t.slot_reachable)??null,slot_status_code:d(t.slot_status_code)??null,runtime_blocker:r(t.runtime_blocker)??null,detail:r(t.detail)??null,checked_at:r(t.checked_at)??null,total_slots:d(t.total_slots),ctx_per_slot:d(t.ctx_per_slot),active_slots_now:d(t.active_slots_now),peak_active_slots:d(t.peak_active_slots),sample_count:d(t.sample_count),last_sample_at:r(t.last_sample_at)??null,timeline:e}}function Qv(t){if(!_(t))return null;const e=r(t.run_id),n=r(t.status),s=r(t.decided_by),a=r(t.decided_at),o=r(t.reason);if(!e||!n||!s||!a||!o)return null;const l=[];return Array.isArray(t.history)&&t.history.forEach(c=>{if(!_(c))return;const u=r(c.status),m=r(c.decided_by),p=r(c.decided_at),v=r(c.reason);!u||!m||!p||!v||l.push({status:u,decided_by:m,decided_at:p,reason:v,operation_id:r(c.operation_id)??null,detachment_id:r(c.detachment_id)??null,note:r(c.note)??null})}),{run_id:e,status:n,decided_by:s,decided_at:a,reason:o,operation_id:r(t.operation_id)??null,detachment_id:r(t.detachment_id)??null,note:r(t.note)??null,history:l}}function Zv(t){if(!_(t))return null;const e=r(t.run_id),n=r(t.recommended_kind),s=r(t.reason);return!e||!n||!s?null:{run_id:e,recommended_kind:n,continue_available:N(t.continue_available)??!1,rerun_available:N(t.rerun_available)??!1,abandon_available:N(t.abandon_available)??!1,reason:s,evidence:_(t.evidence)?{operation_id:r(t.evidence.operation_id)??null,detachment_id:r(t.evidence.detachment_id)??null,joined_workers:d(t.evidence.joined_workers),current_task_bound:d(t.evidence.current_task_bound),fresh_heartbeats:d(t.evidence.fresh_heartbeats),trace_events:d(t.evidence.trace_events),message_events:d(t.evidence.message_events),runtime_blocker:r(t.evidence.runtime_blocker)??null}:void 0,provenance:r(t.provenance),decision_engine:r(t.decision_engine),authoritative:N(t.authoritative)}}function tf(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),run_id:r(e.run_id),room_id:r(e.room_id),operation_id:r(e.operation_id)??null,run_resolution:Qv(e.run_resolution),resolution_recommendation:Zv(e.resolution_recommendation),recommended_next_tool:r(e.recommended_next_tool),summary:n?{expected_workers:d(n.expected_workers),joined_workers:d(n.joined_workers),live_workers:d(n.live_workers),squad_roster_size:d(n.squad_roster_size),detachment_roster_size:d(n.detachment_roster_size),current_task_bound:d(n.current_task_bound),fresh_heartbeats:d(n.fresh_heartbeats),claim_markers_seen:d(n.claim_markers_seen),done_markers_seen:d(n.done_markers_seen),final_markers_seen:d(n.final_markers_seen),completed_workers:d(n.completed_workers),peak_hot_slots:d(n.peak_hot_slots),hot_window_ok:N(n.hot_window_ok),pass_hot_concurrency:N(n.pass_hot_concurrency),pass_end_to_end:N(n.pass_end_to_end),pending_decisions:d(n.pending_decisions),pass:N(n.pass)}:void 0,provider:Xv(e.provider),operation:ei(e.operation),squad:Zo(e.squad),detachment:dd(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Yv).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Gv).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Jv).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Vv).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(_d).filter(s=>s!==null):[],truth_notes:B(e.truth_notes)}}function ef(t){if(!_(t))return null;const e=r(t.label),n=r(t.value);return!e||!n?null:{label:e,value:n}}function nf(t){if(!_(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.label),a=r(t.tone),o=r(t.provenance);return!e||!n||!s||!a||!o?null:{id:e,kind:n,label:s,subtitle:r(t.subtitle)??null,status:r(t.status)??null,tone:a,pulse:r(t.pulse)??null,provenance:o,visual_class:r(t.visual_class)??void 0,glyph:r(t.glyph)??void 0,parent_id:r(t.parent_id)??null,lane_id:r(t.lane_id)??null,link_tab:r(t.link_tab)??null,link_surface:r(t.link_surface)??null,link_params:_(t.link_params)?Object.fromEntries(Object.entries(t.link_params).map(([l,c])=>{const u=r(c);return u?[l,u]:null}).filter(l=>l!==null)):{},facts:Array.isArray(t.facts)?t.facts.map(ef).filter(l=>l!==null):[]}}function sf(t){if(!_(t))return null;const e=r(t.id),n=r(t.source),s=r(t.target),a=r(t.kind),o=r(t.tone),l=r(t.provenance);return!e||!n||!s||!a||!o||!l?null:{id:e,source:n,target:s,kind:a,label:r(t.label)??null,tone:o,provenance:l,animated:N(t.animated)}}function af(t){if(!_(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.label),a=r(t.tone),o=r(t.provenance);return!e||!n||!s||!a||!o?null:{id:e,kind:n,label:s,detail:r(t.detail)??null,tone:a,provenance:o,source_id:r(t.source_id)??null,target_id:r(t.target_id)??null,suggested_surface:r(t.suggested_surface)??null,suggested_params:_(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([l,c])=>{const u=r(c);return u?[l,u]:null}).filter(l=>l!==null)):{}}}function of(t){if(!_(t))return null;const e=r(t.target_kind),n=r(t.target_id),s=r(t.label),a=r(t.reason);return!e||!n||!s||!a?null:{target_kind:e,target_id:n,label:s,reason:a,suggested_surface:r(t.suggested_surface)??null,suggested_params:_(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([o,l])=>{const c=r(l);return c?[o,c]:null}).filter(o=>o!==null)):{}}}function rf(t){const e=_(t)?t:{},n=_(e.room)?e.room:{},s=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),room:{room_id:r(n.room_id),project:r(n.project),cluster:r(n.cluster),paused:N(n.paused),pause_reason:r(n.pause_reason)??null,agent_count:d(n.agent_count),task_count:d(n.task_count),message_count:d(n.message_count)},summary:s?{session_count:d(s.session_count),operation_count:d(s.operation_count),detachment_count:d(s.detachment_count),lane_count:d(s.lane_count),worker_count:d(s.worker_count),keeper_count:d(s.keeper_count),signal_count:d(s.signal_count),alert_count:d(s.alert_count)}:void 0,nodes:Array.isArray(e.nodes)?e.nodes.map(nf).filter(a=>a!==null):[],edges:Array.isArray(e.edges)?e.edges.map(sf).filter(a=>a!==null):[],signals:Array.isArray(e.signals)?e.signals.map(af).filter(a=>a!==null):[],focus:of(e.focus),swarm_status:tr(e.swarm_status),swarm_proof:vd(e.swarm_proof),truth_notes:B(e.truth_notes)}}function Kt(t){V.value=t,Qo(t)&&lf()}async function $d(){Sa.value=!0,Aa.value=null;try{const t=await bp();Yo.value=zv(t)}catch(t){Aa.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{Sa.value=!1}}function er(t){dn.value=t}async function nr(){Ca.value=!0,Ta.value=null;try{const t=await yp();Jt.value=Lv(t)}catch(t){Ta.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{Ca.value=!1}}async function lf(){Jt.value||Ca.value||await nr()}async function Xe(){await $d(),Qo(V.value)&&await nr()}async function je(){var t;$o.value=!0,Ea.value=null;try{const e=await kp(),n=jv(e);bs.value=n;const s=dn.value;n.operations.length===0?dn.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(dn.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Ea.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{$o.value=!1}}function cf(){Ln=null,Qn.value=null,Pa.value=!1,Zn.value=null}async function df(t){Ln=t,Pa.value=!0,Zn.value=null;try{const e=await xp(t);if(Ln!==t)return;Qn.value=Ov(e)}catch(e){if(Ln!==t)return;Qn.value=null,Zn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{Ln===t&&(Pa.value=!1)}}async function uf(){fo.value=!0,Ra.value=null;try{const t=await Sp();ys.value=Wv(t)}catch(t){Ra.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{fo.value=!1}}async function Zt(t=id(),e=od()){Ma.value=!0,La.value=null;try{const n=await Cp(t,e);Be.value=tf(n)}catch(n){La.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{Ma.value=!1}}async function Ee(t=id(),e=od()){go.value=!0,za.value=null;try{const n=await Ap(t,e);Xo.value=rf(n)}catch(n){za.value=n instanceof Error?n.message:"Failed to load orchestra map"}finally{go.value=!1}}async function he(t,e,n){vo.value=t,Ia.value=null;try{await Tp(e,n),await $d(),(Jt.value||Qo(V.value))&&await nr(),await Zt(),await Ee(),await je()}catch(s){throw Ia.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{vo.value=null}}function pf(t){return he(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function mf(t){return he(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function _f(t){return he(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function vf(t={}){return he("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function ff(t){return he(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function gf(t){return he(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function $f(t,e){return he(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function hf(t,e){return he(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}N_(()=>{Xe(),je(),(V.value==="swarm"||V.value==="warroom"||V.value==="orchestra"||Be.value!==null)&&Zt(),(V.value==="orchestra"||Xo.value!==null)&&Ee(),V.value==="warroom"&&gt()});function ho(t){t==="command"&&(Le(),Xe(),je(),(V.value==="swarm"||V.value==="warroom"||V.value==="orchestra")&&Zt(),V.value==="orchestra"&&Ee(),V.value==="warroom"&&gt()),t==="mission"&&(Le(),ed(),xa()),t==="proof"&&sd(O.value.params.session_id,O.value.params.operation_id),t==="execution"&&(Le(),Me()),t==="intervene"&&(Le(),gt(),Oe()),t==="memory"&&me(),t==="planning"&&Go(),t==="lab"&&_e()}function yf({metric:t}){return i`
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
  `}function bf({panel:t}){return i`
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
            ${t.metrics.map(e=>i`<${yf} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function D({panelId:t,compact:e=!1,label:n="왜 필요한가"}){const s=k_(t);return s?i`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${bf} panel=${s} />
    </details>
  `:ga.value?i`<span class="semantic-inline-state">의미 계층 불러오는 중…</span>`:null}function Ct({surfaceId:t,compact:e=!1}){const n=b_(t);return n?i`
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
  `:ga.value?i`<div class="semantic-surface-card ${e?"compact":""}">의미 계층 불러오는 중…</div>`:$a.value?i`<div class="semantic-surface-card ${e?"compact":""}">${$a.value}</div>`:null}function R({title:t,class:e,semanticId:n,testId:s,children:a}){return i`
    <div class="card ${e??""}" data-testid=${s}>
      ${t?i`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?i`<${D} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}const Na="masc_dashboard_workflow_context",kf=900*1e3;function kt(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function oe(t){const e=kt(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function hd(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function yo(t){return _(t)?t:null}function xf(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function Sf(t){if(!t)return null;try{const e=JSON.parse(t);if(!_(e))return null;const n=kt(e.id),s=kt(e.source_surface),a=kt(e.source_label),o=kt(e.summary),l=kt(e.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!o||!l?null:{id:n,source_surface:s,source_label:a,action_type:kt(e.action_type),target_type:kt(e.target_type),target_id:kt(e.target_id),focus_kind:kt(e.focus_kind),operation_id:kt(e.operation_id),command_surface:kt(e.command_surface),summary:o,payload_preview:kt(e.payload_preview),suggested_payload:yo(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:l}}catch{return null}}function sr(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=kf}function Cf(){const t=hd(),e=Sf((t==null?void 0:t.getItem(Na))??null);return e?sr(e)?e:(t==null||t.removeItem(Na),null):null}const yd=g(Cf());function bd(t){const e=t&&sr(t)?t:null;yd.value=e;const n=hd();if(!n)return;if(!e){n.removeItem(Na);return}const s=xf(e);s&&n.setItem(Na,s)}function Af(t){if(!t)return null;const e=yo(t.suggested_payload);if(e)return e;if(_(t.preview)){const n=yo(t.preview.payload);if(n)return n}return null}function Tf(t){if(!t)return null;const e=oe(t.message);if(e)return e;const n=oe(t.task_title)??oe(t.title),s=oe(t.task_description)??oe(t.description),a=oe(t.reason),o=oe(t.priority)??oe(t.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function ar(t,e,n,s,a,o,l,c){return[t,e,n??"action",s??"target",a??"room",o??"focus",l??"operation",c].join(":")}function kn(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=Af(t),o=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,l=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,c=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,u=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:ar("mission",n,(t==null?void 0:t.action_type)??null,o,l,c,null,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:o,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:u,payload_preview:Tf(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function If({targetType:t,targetId:e,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:o=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:ar("execution",s,null,t,e,n,o,c),source_surface:"execution",source_label:s,action_type:null,target_type:t,target_id:e,focus_kind:n,operation_id:o,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function Rf(t,e){return(e.source==="mission"||e.source==="execution")&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)&&(e.operation_id??null)===(t.operation_id??null)}function ks(t){const{params:e}=t;if(e.source!=="mission"&&e.source!=="execution")return null;const n=yd.value;if(n&&sr(n)&&Rf(n,e))return n;const s=new Date().toISOString(),a=e.source==="execution"?"execution":"mission";return{id:ar(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,e.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,operation_id:e.operation_id??null,command_surface:e.surface??null,summary:a==="execution"?e.focus_kind?`${e.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function kd(t){return{source:t.source_surface,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function xd(t){if(t.command_surface)return t.command_surface;const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.focus_kind==="operation"||t.target_type==="operation"?"operations":t.target_type==="room"?"orchestra":"swarm"}function Sd(t){return{source:t.source_surface,surface:xd(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function Mf(t){return kd(t)}function Lf(t){return Sd(t)}function ir(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function ni(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(t==null?void 0:t.trim())||"추천 액션"}}function zf(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"orchestra":return"오케스트라";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}const te=g(null),ce=g(null);function jt(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function ht(t){return t==="bad"||t==="offline"||t==="critical"||t==="risk"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"||t==="watch"?"warn":"ok"}function Ut(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function Ef(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"확인 필요":t<60?`${Math.round(t)}초`:t<3600?`${Math.round(t/60)}분`:t<86400?`${Math.round(t/3600)}시간`:`${Math.round(t/86400)}일`}function Et(t){switch((t??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"pending":return"대기 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":case"watch":return"주의";case"bad":case"critical":case"risk":return"위험";case"degraded":return"저하";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"loading":return"불러오는 중";case"error":return"오류";case"unavailable":return"사용 불가";case"stale":return"오래됨";case"refreshing":return"갱신 중";case"cached":return"캐시";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function ja(t){switch((t??"").trim().toLowerCase()){case"room":return"방";case"team_session":case"session":return"세션";case"operation":return"작전";case"keeper":return"키퍼";case"agent":return"에이전트";default:return(t==null?void 0:t.trim())||"대상"}}function vl(t){switch((t??"").trim().toLowerCase()){case"metadata_gap":return"메타데이터 부족";case"mixed":return"신호 혼재";case"":return null;default:return(t==null?void 0:t.trim())||null}}function Pf(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function Nf(t){return ir(t?kn(t,null,"상황판 추천 액션"):null)}function si(t,e=kn()){bd(e),it(t,t==="intervene"?Mf(e):Lf(e))}function Cd(t){si("intervene",kn(null,t,"상황판 incident"))}function Ad(t){si("command",kn(null,t,"상황판 incident"))}function or(t,e,n="상황판 추천 액션"){si("intervene",kn(t,e,n))}function Td(t,e,n="상황판 추천 액션"){si("command",kn(t,e,n))}function bo(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),it(t,n)}function jf(t){return{kind:t.kind,severity:t.severity,summary:t.summary,target_type:t.target_type,target_id:t.target_id??null,actor:null,evidence:t.evidence_preview}}function wf(t){var n,s;const e=ae.value.find(a=>a.name===t.name||a.agent_name===t.agent_name)??null;return{brief:t,keeper:e,currentWork:jt(t.current_work,110)??jt(e==null?void 0:e.skill_primary,110)??jt(e==null?void 0:e.last_proactive_reason,110)??"명시된 키퍼 초점 없음",recentInput:jt(e==null?void 0:e.recent_input_preview,120)??null,recentOutput:jt(e==null?void 0:e.recent_output_preview,120)??jt((n=e==null?void 0:e.diagnostic)==null?void 0:n.last_reply_preview,120)??jt(e==null?void 0:e.last_proactive_preview,120)??null,recentEvent:jt(e==null?void 0:e.last_proactive_reason,120)??jt((s=e==null?void 0:e.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(e==null?void 0:e.recent_tool_names)??[]}}function Of(){const t=hs.value;if(!t)return new Map;const e=t.sessions.length>0?t.sessions:t.session_briefs;return new Map(e.map(n=>[n.session_id,n]))}function Df(t){te.value=te.value===t?null:t,ce.value=null}function Id(t){ce.value=ce.value===t?null:t,te.value=null}function qf(){te.value=null,ce.value=null}function gi(t){return(t==null?void 0:t.trim().toLowerCase())??""}function xs(t){var e,n;return t?((e=t.agent)==null?void 0:e.exists)===!1||gi((n=t.diagnostic)==null?void 0:n.health_state)==="offline"||gi(t.status)==="offline"||gi(t.status)==="inactive"?"offline":"online":"unlinked"}function zn(t){switch(t){case"offline":return"offline";case"none_recent":return"none_recent";case"not_applicable":return"not_applicable";case"unlinked":return"unlinked";default:return"not_collected"}}function Ff(t){const e=xs(t);return e==="unlinked"?"unlinked":e==="offline"?"offline":"not_collected"}function Kf(t,e){const n=xs(t);return n==="unlinked"?"unlinked":n==="offline"?"offline":e!=null&&e.trim()?"none_recent":"not_collected"}function Bf(t,e){const n=xs(t);return n==="unlinked"?"unlinked":n==="offline"?"offline":e!=null&&e.trim()?"none_recent":"not_collected"}function Rd(t){const e=xs(t);return e==="unlinked"?"unlinked":e==="offline"?"offline":"none_recent"}function Uf(t){const e=t==null?void 0:t.trim();it("tools",e?{q:e}:void 0)}function Hf(t){switch(t.trim().toLowerCase()){case"active":case"running":return"가동 중";case"working":return"작업 중";case"watching":return"관찰 중";case"quiet":return"조용함";case"idle":return"유휴";case"ok":case"healthy":return"정상";case"warn":case"warning":case"degraded":return"주의";case"bad":case"critical":case"error":case"failed":return"위험";case"blocked":return"막힘";case"paused":return"일시정지";case"pending":return"대기";case"offline":case"inactive":return"오프라인";case"connected":return"연결됨";case"disconnected":return"끊김";case"ready":return"준비됨";case"done":case"completed":return"완료";case"unknown":return"알 수 없음";default:return t}}function ye({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??Hf(t)}
    </span>
  `}function Md(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}초 전`;const a=Math.floor(s/60);if(a<60)return`${a}분 전`;const o=Math.floor(a/60);return o<24?`${o}시간 전`:`${Math.floor(o/24)}일 전`}function X({timestamp:t}){const e=Md(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}let Wf=0;const Pe=g([]);function j(t,e="success",n=4e3){const s=++Wf;Pe.value=[...Pe.value,{id:s,message:t,type:e}],setTimeout(()=>{Pe.value=Pe.value.filter(a=>a.id!==s)},n)}function Gf(t){Pe.value=Pe.value.filter(e=>e.id!==t)}function Jf(){const t=Pe.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Gf(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}function Ld(t,e){const n=t==null?void 0:t.trim(),s=e==null?void 0:e.trim();return s?n&&s===n?null:s:null}function Vf(t,e){const n=Ld(t,e);return n?`runtime · ${n}`:null}function Yf(t,e){const n=t==null?void 0:t.trim(),s=Ld(n,e);return n?s?`keeper key · ${n} · runtime agent · ${s}`:`keeper key · ${n}`:null}const Xf="masc_dashboard_agent_name",xn=g(null),wa=g(!1),ts=g(""),Oa=g([]),es=g([]),un=g(""),Dn=g(!1);function Ss(t){xn.value=t,rr()}function fl(){xn.value=null,ts.value="",Oa.value=[],es.value=[],un.value=""}function Qf(){const t=xn.value;return t?Gt.value.find(e=>e.name===t)??null:null}function zd(t){return t?ue.value.filter(e=>e.assignee===t):[]}function Zf(t){return t?ae.value.find(e=>e.agent_name===t||e.name===t)??null:null}function tg(t){if(!t)return null;const e=hs.value;return e?e.agent_briefs.find(n=>n.agent_name===t)??null:null}function eg(t){return t?Bo.value.find(e=>e.agent_name===t||e.name===t)??null:null}async function rr(){const t=xn.value;if(t){wa.value=!0,ts.value="",Oa.value=[],es.value=[];try{const e=await um(80);Oa.value=e.filter(a=>a.includes(t)).slice(0,20);const n=zd(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await pm(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const l=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));es.value=s}catch(e){ts.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{wa.value=!1}}}async function gl(){var s;const t=xn.value,e=un.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Xf))==null?void 0:s.trim())||"dashboard";Dn.value=!0;try{await dm(n,`@${t} ${e}`),un.value="",j(`Mention sent to ${t}`,"success"),rr()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";j(o,"error")}finally{Dn.value=!1}}function ng({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${ye} status=${t.status} />
    </div>
  `}function sg({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function $l(t,e=160){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function ag(){const t=xn.value;if(!t)return null;const e=Qf(),n=Zf(t),s=eg(t),a=tg(t),o=zd(t),l=Oa.value,c=(a==null?void 0:a.display_name)??(n==null?void 0:n.name)??t,u=c!==t?t:null,m=(e==null?void 0:e.status)??(a==null?void 0:a.status)??"unknown",p=!e&&(a==null?void 0:a.is_live)===!1,v=(e==null?void 0:e.last_seen)??(a==null?void 0:a.last_activity_at)??null,f=(e==null?void 0:e.emoji)??(n==null?void 0:n.emoji),h=(e==null?void 0:e.koreanName)??(n==null?void 0:n.koreanName),A=$l(s==null?void 0:s.continuity_summary)??$l(s==null?void 0:s.skill_route_summary)??null,b=Yf(n==null?void 0:n.name,n==null?void 0:n.agent_name);return i`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${k=>{k.target.classList.contains("agent-detail-overlay")&&fl()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${f?i`<span style="font-size:2rem">${f}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${c}
                  ${h?i`<span style="font-size:0.75em;color:#888">(${h})</span>`:""}
                  ${u?i`<span class="mono" style="font-size:0.75em;color:#888">${u}</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  <${ye} status=${m} />
                  ${p?i`<span class="pill">archived session participant</span>`:null}
                  ${e!=null&&e.model?i`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                  ${!e&&(a!=null&&a.archived_reason)?i`<span style="font-size:0.75rem;color:#888">${a.archived_reason}</span>`:null}
                </div>
              </div>
            </div>
            <div class="agent-detail-sub">
              ${e!=null&&e.current_task||a!=null&&a.current_work?i`<span>Task: ${(e==null?void 0:e.current_task)??(a==null?void 0:a.current_work)}</span>`:null}
              ${v?i`<span>Last seen: <${X} timestamp=${v} /></span>`:null}
            </div>
            ${n||A||a!=null&&a.related_session_id?i`
                  <div class="agent-detail-sub">
                    ${n?i`<span>Linked keeper: ${n.name}${b?` · ${b}`:""}</span>`:null}
                    ${a!=null&&a.related_session_id?i`<span>Session: ${a.related_session_id}</span>`:null}
                    ${A?i`<span>${A}</span>`:null}
                  </div>
                `:null}
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{rr()}} disabled=${wa.value}>
              ${wa.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${fl}>Close</button>
          </div>
        </div>

        ${ts.value?i`<div class="council-error">${ts.value}</div>`:null}

        <div class="agent-detail-grid">
          <${R} title="Assigned Tasks">
            ${o.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${o.map(k=>i`<${ng} key=${k.id} task=${k} />`)}</div>`}
          <//>

          <${R} title="Recent Activity">
            ${l.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${l.map((k,$)=>i`<div key=${$} class="agent-activity-line">${k}</div>`)}</div>`}
          <//>
        </div>
        <${R} title="Task History">
          ${es.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${es.value.map(k=>i`<${sg} key=${k.taskId} row=${k} />`)}</div>`}
        <//>

        <${R} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${un.value}
              onInput=${k=>{un.value=k.target.value}}
              onKeyDown=${k=>{k.key==="Enter"&&gl()}}
              disabled=${Dn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{gl()}}
              disabled=${Dn.value||un.value.trim()===""}
            >
              ${Dn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function ig(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function og(t){switch(t.delivery){case"sending":return"sending";case"streaming":return t.streamState==="finalizing"?"finalizing":"streaming";case"timeout":return"timeout";case"error":return"error";case"history":return t.role;default:return"delivered"}}function $i(t){return t.delivery==="error"||t.delivery==="timeout"?"error":t.role==="user"?"user":t.role==="assistant"?"assistant":"system"}function Ed(t){return t.role==="user"?"You":t.label.trim()?t.label.trim():t.role}function rg(t){return Ed(t).slice(0,2).toUpperCase()}function lg(t){var n;const e=(n=t==null?void 0:t.usage)==null?void 0:n.totalTokens;return typeof e=="number"&&Number.isFinite(e)?`${e} tok`:null}function cg(t){return t?[t.modelUsed??null,typeof t.latencyMs=="number"?`${t.latencyMs} ms`:null,lg(t)].filter(e=>!!e):[]}function hl(t){return typeof t!="number"||!Number.isFinite(t)?null:t===0?"$0.00":t<.01?`$${t.toFixed(4)}`:`$${t.toFixed(2)}`}function dg(t){if(!t)return[];const e=["Goal","Progress","Next","Decisions","OpenQuestions","Constraints"];return t.split(`
`).map(n=>n.trim()).filter(Boolean).map(n=>{const s=e.find(a=>n.startsWith(`${a}:`));return s?{label:s,value:n.slice(s.length+1).trim()}:null}).filter(n=>!!(n&&n.value))}function ug(t){var e;return[t.modelUsed?{label:"Model",value:t.modelUsed}:null,typeof t.latencyMs=="number"?{label:"Latency",value:`${t.latencyMs} ms`}:null,typeof((e=t.usage)==null?void 0:e.totalTokens)=="number"?{label:"Tokens",value:`${t.usage.totalTokens}`}:null,hl(t.costUsd)?{label:"Cost",value:hl(t.costUsd)}:null,t.traceId?{label:"Trace",value:t.traceId}:null,typeof t.generation=="number"?{label:"Generation",value:`${t.generation}`}:null].filter(n=>!!n)}function pg({entry:t}){var m;const[e,n]=vn(!1),[s,a]=vn(!1),o=cg(t.details),l=!!t.details,c=t.details?ug(t.details):[],u=dg((m=t.details)==null?void 0:m.stateBlock);return i`
    <article class=${`chat-bubble ${$i(t)}`}>
      <div class="chat-bubble-head">
        <div class="chat-bubble-identity">
          <div class=${`chat-avatar ${$i(t)}`}>${rg(t)}</div>
          <div class="chat-bubble-identity-copy">
            <div class="chat-bubble-labels">
              <span class=${`chat-role-chip ${$i(t)}`}>${t.label}</span>
              <span class="chat-delivery-chip">${og(t)}</span>
              ${t.timestamp?i`<span class="chat-time-chip">${ig(t.timestamp)}</span>`:null}
            </div>
            <div class="chat-identity-title">${Ed(t)}</div>
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
            ${o.map(p=>i`<span class="chat-detail-chip">${p}</span>`)}
          </div>`:null}

      <div class="chat-bubble-body">${t.text||(t.delivery==="streaming"?"…":"(empty reply)")}</div>
      ${t.error?i`<div class="chat-bubble-error">${t.error}</div>`:null}

      ${e&&t.details?i`
            <div class="chat-detail-panel">
              ${c.length>0?i`
                    <div class="chat-overview-grid">
                      ${c.map(p=>i`
                        <div class="chat-overview-card">
                          <div class="chat-overview-label">${p.label}</div>
                          <div class="chat-overview-value">${p.value}</div>
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
              ${u.length>0?i`
                    <div class="chat-detail-section">
                      <div class="chat-detail-section-title">State Snapshot</div>
                      <div class="chat-state-grid">
                        ${u.map(p=>i`
                          <div class="chat-state-card">
                            <div class="chat-state-label">${p.label}</div>
                            <div class="chat-state-value">${p.value}</div>
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
  `}function mg({entries:t,emptyText:e}){const n=Pn(null),s=t.map(a=>`${a.id}:${a.text.length}:${a.delivery}`).join("|");return nt(()=>{const a=n.current;a&&(a.scrollTop=a.scrollHeight)},[s]),i`
    <div class="chat-transcript" ref=${n}>
      ${t.length===0?i`<div class="chat-empty-copy">${e}</div>`:t.map(a=>i`<${pg} key=${a.id} entry=${a} />`)}
    </div>
  `}function _g({draft:t,placeholder:e,disabled:n,streaming:s,onDraftChange:a,onSend:o,onAbort:l}){return i`
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
  `}function vg(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function fg(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function yl(t){switch(t){case"healthy":return"정상";case"recovering":return"복구 중";case"desired_offline":return"의도적 오프라인";case"offline":return"오프라인";default:return null}}function gg(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function $g(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Pd(t){if(!t)return null;const e=ne.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function hg({keeper:t,showRawStatus:e=!1}){if(nt(()=>{t!=null&&t.name&&kc(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=ne.value[t.name],s=Pd(t),a=no.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        ${yl(s==null?void 0:s.continuity_state)?i`<span class="pill">${yl(s==null?void 0:s.continuity_state)}</span>`:null}
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${vg(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${fg((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.continuity_summary)??(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${gg(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${$g(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Nd({keeperName:t,placeholder:e}){const[n,s]=vn("");nt(()=>{t&&kc(t)},[t]);const a=$t.value[t]??[],o=_a.value[t]??!1,l=Bt.value[t],c=async()=>{const u=n.trim();if(!(!t||!u)){s("");try{await Nm(t,u)}catch(m){if(m instanceof Error&&m.name==="AbortError")return;const p=m instanceof Error?m.message:`Failed to message ${t}`;j(p,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <${mg}
        entries=${a}
        emptyText="No direct keeper conversation yet."
      />
      <${_g}
        draft=${n}
        placeholder=${e}
        disabled=${!t}
        streaming=${o}
        onDraftChange=${s}
        onSend=${()=>{c()}}
        onAbort=${()=>{bc(t)}}
      />
      ${l?i`<div class="control-status-copy control-error-copy">${l}</div>`:null}
    </div>
  `}function yg({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=Pd(e),a=so.value[e.name]??!1,o=ao.value[e.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{jm(e.name,t).catch(u=>{const m=u instanceof Error?u.message:`Failed to probe ${e.name}`;j(m,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{wm(e.name,t).catch(u=>{const m=u instanceof Error?u.message:`Failed to recover ${e.name}`;j(m,"error")})}}
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
  `}const lr=g(null);function jd(t){lr.value=t,Pm(t.name)}function bl(){lr.value=null}const We=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function bg(t){if(!t)return 0;const e=We.findIndex(n=>n.level===t);return e>=0?e:0}function kg({keeper:t}){const e=bg(t.autonomy_level),n=We[e]??We[0];if(!n)return null;const s=(e+1)/We.length*100;return i`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${We.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${We.map((a,o)=>i`
            <span style="width:8px; height:8px; border-radius:50%; background:${o<=e?a.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?i`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${X} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?i`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function ia(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function xg(t){switch(t){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(t==null?void 0:t.trim())||"action"}}function Sg(t){return t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]}function Cg(t){const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Ag(t){const e=hs.value;return e?e.keeper_briefs.find(n=>n.name===t.name||n.agent_name&&t.agent_name&&n.agent_name===t.agent_name)??null:null}function Tg({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=n&&Number.isFinite(n.cost_usd)?`$${n.cost_usd.toFixed(4)}`:null,a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${ia(t.context_tokens)}</div>
        <div class="kpi-label">Tokens</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${t.handoff_count_total??"—"}</div>
        <div class="kpi-label">Handoffs</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${t.compaction_count??"—"}</div>
        <div class="kpi-label">Compactions</div>
      </div>
      ${s?i`
            <div class="kpi-tile">
              <div class="kpi-value">${s}</div>
              <div class="kpi-label">Cost (USD)</div>
            </div>
          `:null}
    </div>
  `}function Ig({keeper:t}){var p,v;const e=t.metrics_series??[];if(e.length<2){const f=(((p=t.context)==null?void 0:p.context_ratio)??0)*100,h=f>85?"#ef4444":f>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${f.toFixed(1)}%;background:${h}"></div>
        </div>
        <span class="chart-pct">${f.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=e.length,l=e.map((f,h)=>{const A=a+h/(o-1)*(n-2*a),b=s-a-(f.context_ratio??0)*(s-2*a);return{x:A,y:b,p:f}}),c=l.map(({x:f,y:h})=>`${f.toFixed(1)},${h.toFixed(1)}`).join(" "),u=(((v=e[e.length-1])==null?void 0:v.context_ratio)??0)*100,m=u>85?"#ef4444":u>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:f})=>f.is_handoff).map(({x:f})=>i`
          <line x1="${f.toFixed(1)}" y1="${a}" x2="${f.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${m}" stroke-width="1.5"/>
        ${l.filter(({p:f})=>f.is_compaction).map(({x:f,y:h})=>i`
          <circle cx="${f.toFixed(1)}" cy="${h.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${u.toFixed(1)}%</span>
    </div>`}const hi=g("");function Rg({keeper:t}){var a,o,l,c;const e=hi.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],s=e?n.filter(u=>u.title.toLowerCase().includes(e)||u.key.includes(e)||u.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${hi.value}
        onInput=${u=>{hi.value=u.target.value}}
      />
      ${s.map(u=>i`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${u.title}</span>
          <span class="keeper-field-key">${u.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${u.value}</span>
        </div>
      `)}
      ${t.trace_id?i`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${t.trace_id}</span></div>`:""}
      ${t.agent_name?i`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${t.agent_name}</span></div>`:""}
      ${t.primary_model?i`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.primary_model}</span></div>`:""}
      ${t.active_model?i`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.active_model}</span></div>`:""}
      ${t.next_model_hint?i`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.next_model_hint}</span></div>`:""}
      ${t.skill_primary?i`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_primary}</span></div>`:""}
      ${t.skill_secondary?i`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_secondary}</span></div>`:""}
      ${t.skill_reason?i`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_reason}</span></div>`:""}
      ${t.context_source?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${t.context_source}</span></div>`:""}
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${ia(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${ia(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${ia(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Mg({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
    <div>
      <div style="display: flex; gap: 12px; margin-bottom: 10px;">
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
        Level ${t.level} — XP ${t.xp}
      </div>
    </div>
  `}function Lg({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function zg({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function kl({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function yi(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Eg({keeper:t}){const e=t.metrics_window,s=[{label:"Model fallback",value:yi(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:yi(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:yi(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}].filter(a=>!(a.value==="-"||a.value==="—"||a.value===""));return s.length===0?null:i`
    <div class="keeper-signal-list">
      ${s.map(a=>i`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function Pg({keeper:t}){var U,et,Q,tt,W,I,x;const e=((U=At.value)==null?void 0:U.room)??{},n=(((et=At.value)==null?void 0:et.available_actions)??[]).filter(L=>L.target_type==="keeper"||L.target_type==="room").slice(0,8),s=Sg(t),a=Cg(t),o=Ag(t),l=o!=null&&o.allowed_tool_names&&o.allowed_tool_names.length>0?o.allowed_tool_names:t.allowed_tool_names??[],c=o!=null&&o.latest_tool_names&&o.latest_tool_names.length>0?o.latest_tool_names:t.latest_tool_names??[],u=(o==null?void 0:o.latest_tool_call_count)??t.latest_tool_call_count,m=(o==null?void 0:o.tool_audit_source)??t.tool_audit_source,p=(o==null?void 0:o.tool_audit_at)??t.tool_audit_at,v=((Q=t.agent)==null?void 0:Q.capabilities)??[],f=e.current_room??e.room_id??((tt=pt.value)==null?void 0:tt.room)??"default",h=e.project??((W=pt.value)==null?void 0:W.project)??"확인 없음",A=e.cluster??((I=pt.value)==null?void 0:I.cluster)??"확인 없음",b=zn(Ff(t)),k=zn(Kf(t,m)),$=zn(Bf(t,m)),z=zn(Rd(t)),S=xs(t),M=((x=t.agent)==null?void 0:x.current_task)??(S==="offline"?"offline":"not_collected"),T=t.skill_primary??(S==="offline"?"offline":"not_collected"),K=l[0]??c[0]??s[0]??null;return i`
    <div class="keeper-signal-list">
      <div class="keeper-signal-row">
        <span>Room</span>
        <strong>${f}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Project</span>
        <strong>${h}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Cluster</span>
        <strong>${A}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Current task</span>
        <strong>${M}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Skill route</span>
        <strong>${T}</strong>
      </div>
      <div style="display:flex; justify-content:flex-end; margin-top:4px;">
        <button class="control-btn ghost" onClick=${()=>{Uf(K)}}>
          Open tools panel
        </button>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Allowed tools</span>
        <span style="font-size:11px; color:#64748b;">Currently permitted tools for this keeper runtime.</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${l.length>0?l.map(L=>i`<span class="pill">${L}</span>`):i`<span style="font-size:12px; color:#888;">${b}</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Observed tools</span>
        <span style="font-size:11px; color:#64748b;">Recent execution evidence from heartbeat or runtime telemetry.</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${c.length>0?c.map(L=>i`<span class="pill">${L}</span>`):i`<span style="font-size:12px; color:#888;">${k}</span>`}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Tool calls</span>
        <strong>${typeof u=="number"?u:k==="none_recent"?0:$}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Evidence source</span>
        <strong>${m??$}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Observed at</span>
        <strong>${p?i`<${X} timestamp=${p} />`:$}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Keeper recent tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${s.length>0?s.map(L=>i`<span class="pill">${L}</span>`):i`<span style="font-size:12px; color:#888;">${z}</span>`}
        </div>
      </div>
      ${a.length>0?i`
            <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
              <span style="font-size:12px; color:#888;">Window top tools</span>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${a.map(L=>i`<span class="pill">${L}</span>`)}
              </div>
            </div>
          `:null}
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${v.length>0?v.map(L=>i`<span class="pill">${L}</span>`):i`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(L=>i`<span class="pill">${xg(L.action_type)}</span>`):i`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function wd(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Ng(){try{const t=await Xa({actor:wd(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=hc(t.result);await $s(),e!=null&&e.skipped_reason?j(e.skipped_reason,"warning"):j(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";j(e,"error")}}function jg({keeper:t}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${hg} keeper=${t} />
          <${yg}
            actor=${wd()}
            keeper=${t}
            onPokeLodge=${()=>{Ng()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Nd}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function wg(){var e,n,s;const t=lr.value;return t?i`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&bl()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?i`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
            </div>
            <${ye} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>bl()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Tg} keeper=${t} />

        ${""}
        <${Ig} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${R} title="Field Dictionary">
            <${Rg} keeper=${t} />
          <//>

          ${""}
          <${R} title="Profile">
            <${kl} traits=${t.traits??[]} label="Traits" />
            <${kl} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${X} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?i`
              <${R} title="Autonomy">
                <${kg} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?i`
              <${R} title="TRPG Stats">
                <${Mg} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${R} title="Equipment (${t.inventory.length})">
                <${Lg} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${R} title="Relationships (${Object.keys(t.relationships).length})">
                <${zg} rels=${t.relationships} />
              <//>
            `:null}

          <${R} title="Runtime Signals">
            <${Eg} keeper=${t} />
          <//>

          <${R} title="Neighborhood & Tool Audit">
            <${Pg} keeper=${t} />
          <//>

          <${R} title="Memory & Context">
            <div class="keeper-signal-list">
              <div class="keeper-signal-row">
                <span>Context source</span>
                <strong>${t.context_source??((e=t.context)==null?void 0:e.source)??"-"}</strong>
              </div>
              <div class="keeper-signal-row">
                <span>Context tokens</span>
                <strong>
                  ${t.context_tokens??((n=t.context)==null?void 0:n.context_tokens)??"-"}
                  /
                  ${t.context_max??((s=t.context)==null?void 0:s.context_max)??"-"}
                </strong>
              </div>
              ${t.memory_recent_note?i`
                  <div class="keeper-memory-note">
                    ${t.memory_recent_note}
                  </div>
                `:i`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${jg} keeper=${t} />
      </div>
    </div>
  `:null}function Og({cluster:t,project:e,room:n,generatedAt:s}){return i`
    <div class="mission-context-bar">
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
        <strong>${s?Ut(s):"기록 없음"}</strong>
      </div>
      ${t&&t!=="unknown"?i`
            <div class="mission-context-item">
              <span>배포 메타</span>
              <strong>${t}</strong>
            </div>
          `:null}
    </div>
  `}function He({label:t,value:e,detail:n,tone:s}){return i`
    <article class="mission-stat-card ${ht(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function Dg(){const t=Vc.value,e=ht((t==null?void 0:t.status)??(Ie.value?"bad":"warn")),n=!t||t.sections.length===0,s=(t==null?void 0:t.status)==="error"||(t==null?void 0:t.status)==="unavailable"&&!(t!=null&&t.cached);return i`
    <${R} title="판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>왜 그렇게 보이나</h3>
        <p>사회 truth를 읽은 뒤에만 별도 판단 결과를 참고하고, 근거는 접어서 둡니다.</p>
        <div class="mission-briefing-meta">
          <span class="command-chip">narrative</span>
          <span class="command-chip warn">fallback on failure</span>
        </div>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${e}">
          ${Et((t==null?void 0:t.status)??(Ie.value?"error":"loading"))}
        </span>
        ${t!=null&&t.model?i`<span class="command-chip">${t.model}</span>`:null}
        ${t!=null&&t.generated_at?i`<span class="command-chip">${Ut(t.generated_at)}</span>`:null}
        ${t!=null&&t.cached?i`<span class="command-chip">캐시</span>`:null}
        ${t!=null&&t.stale?i`<span class="command-chip warn">오래됨</span>`:null}
        ${t!=null&&t.refreshing?i`<span class="command-chip warn">갱신 중</span>`:null}
      </div>

      ${Ie.value?i`<div class="empty-state error">${Ie.value}</div>`:null}
      ${t!=null&&t.error?i`<div class="empty-state error">${t.error}</div>`:null}
      ${t!=null&&t.summary?i`<div class="mission-inline-note">${t.summary}</div>`:null}
      ${t!=null&&t.last_error&&!t.error?i`<div class="mission-inline-note">최근 갱신 실패: ${t.last_error}</div>`:null}

      ${t&&t.sections.length>0?i`
            <div class="mission-briefing-grid">
              ${t.sections.slice(0,3).map(a=>i`
                <article class="mission-briefing-section ${ht(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${ht(a.status)}">${Et(a.status)}</span>
                      ${vl(a.signal_class)?i`<span class="command-chip ${a.signal_class==="mixed"?"warn":""}">${vl(a.signal_class)}</span>`:null}
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
          `:!Ve.value&&!Ie.value&&n?i`
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
                      <strong>${ja(a.scope_type)}${a.scope_id?` · ${a.scope_id}`:""}</strong>
                      <span class="command-chip ${a.severity==="watch"?"warn":""}">${Et(a.severity)}</span>
                    </div>
                    <p>${a.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{xa(s)}} disabled=${Ve.value}>
          ${Ve.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{xa(!0)}} disabled=${Ve.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function qg({item:t,selected:e,sessionLookup:n}){const s=jf(t),a=t.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),o=t.top_action??null;return i`
    <article class="mission-attention-card ${ht((o==null?void 0:o.severity)??t.severity)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Df(t.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.summary}</strong>
            <div class="mission-card-target">${ja(t.target_type)}${t.target_id?` · ${t.target_id}`:""}</div>
          </div>
          <span class="command-chip ${ht((o==null?void 0:o.severity)??t.severity)}">${o?Pf(o):t.severity}</span>
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
            <strong>${t.last_seen_at?Ut(t.last_seen_at):"기록 없음"}</strong>
            <small>${ja(t.target_type)}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${o?ni(o.action_type):"판단 필요"}</strong>
            <small>${o?Nf(o):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${o?i`<div class="mission-inline-note">${o.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?i`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>i`
                  <button class="mission-link-row" onClick=${()=>Id(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${Et(l.status)} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:i`<div class="empty-state">직접 연결된 세션이 아직 없습니다.</div>`}

        ${t.related_agent_names.length>0?i`
              <div class="mission-pill-row">
                ${t.related_agent_names.slice(0,8).map(l=>i`
                  <button class="mission-pill action" onClick=${()=>Ss(l)}>${l}</button>
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
              <button class="control-btn ghost" onClick=${()=>or(o,s,"상황판 주의 신호")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>Td(o,s,"상황판 주의 신호")}>
                원인 보기
              </button>
            `:i`
              <button class="control-btn ghost" onClick=${()=>Cd(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Ad(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function Fg({brief:t,selected:e}){var o,l;const n=t.member_previews.slice(0,4),s=t.top_recommendation??null,a=t.top_attention??null;return i`
    <article class="mission-crew-card ${ht(((o=t.top_attention)==null?void 0:o.severity)??t.health??t.status)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Id(t.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.goal}</strong>
            <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          </div>
          <span class="command-chip ${ht(((l=t.top_attention)==null?void 0:l.severity)??t.health??t.status)}">${Et(t.status)}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${t.member_names.length}</strong>
            <small>${t.member_names.slice(0,3).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${Ef(t.elapsed_sec)}</strong>
            <small>${t.started_at?`${Ut(t.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 흐름</span>
            <strong>${t.last_event_at?Ut(t.last_event_at):"기록 없음"}</strong>
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
        <small>${t.last_event_at?Ut(t.last_event_at):"시각 없음"}</small>
      </div>

      ${t.operation_badges.length>0?i`
            <div class="mission-pill-row">
              ${t.operation_badges.slice(0,3).map(c=>i`
                <span class="mission-pill">
                  ${c.operation_id} · ${Et(c.status)}${c.stage?` · ${c.stage}`:""}
                </span>
              `)}
            </div>
          `:null}

      ${n.length>0?i`
            <div class="mission-member-preview-grid">
              ${n.map(c=>i`
                <button class="mission-member-preview" onClick=${()=>Ss(c.agent_name)}>
                  <strong>${c.agent_name}</strong>
                  <span>${c.current_work??"현재 작업 없음"}</span>
                  <small>${c.recent_output_preview??c.recent_input_preview??"최근 입출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>bo("intervene",t.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>bo("command",t.session_id)}>세션 원인 보기</button>
        ${s?i`<button class="control-btn ghost" onClick=${()=>or(s,a,"상황판 세션 요약")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function Kg({detail:t,loading:e,error:n}){if(e&&!t)return i`
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
                      <span>${a.timestamp?Ut(a.timestamp):"시각 없음"}</span>
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
                  <button class="mission-member-preview" onClick=${()=>Ss(a.agent_name)}>
                    <strong>${a.agent_name}</strong>
                    <span>${a.current_work??"현재 작업 없음"}</span>
                    <small>
                      ${a.recent_output_preview??a.recent_input_preview??"최근 입출력 없음"}
                      ${a.last_activity_at?` · ${Ut(a.last_activity_at)}`:""}
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
                  <button class="mission-link-row" onClick=${()=>bo("command",s.session_id)}>
                    <strong>${a.operation_id}</strong>
                    <span>${Et(a.status)}${a.stage?` · ${a.stage}`:""}</span>
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
                    <span>${Et(a.status)}${a.generation!=null?` · 세대 ${a.generation}`:""}</span>
                    <small>${a.current_work??"현재 작업 정보 없음"}</small>
                  </div>
                `):i`<div class="empty-state">직접 연결된 키퍼는 없습니다.</div>`}
          </div>
        </div>
      </div>
    <//>
  `}function Bg({row:t}){var s,a,o,l,c,u,m,p,v,f;const e=[`세대 ${t.brief.generation??((s=t.keeper)==null?void 0:s.generation)??0}`,t.brief.context_ratio!=null?`컨텍스트 ${Math.round(t.brief.context_ratio*100)}%`:((a=t.keeper)==null?void 0:a.context_ratio)!=null?`컨텍스트 ${Math.round(t.keeper.context_ratio*100)}%`:null,t.brief.last_turn_ago_s!=null?`최근 턴 ${Math.round(t.brief.last_turn_ago_s)}초 전`:null].filter(h=>h!==null).join(" · "),n=t.recentTools.length>0?t.recentTools.join(", "):zn(Rd(t.keeper));return i`
    <article class="mission-activity-card ${ht(t.brief.status??((o=t.keeper)==null?void 0:o.status))}">
      <button class="mission-card-select" onClick=${()=>{t.keeper&&jd(t.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((l=t.keeper)==null?void 0:l.emoji)??""}</span>
            <div>
              <strong>${t.brief.name}</strong>
              ${(c=t.keeper)!=null&&c.koreanName?i`<span>${t.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${ht(t.brief.status??((u=t.keeper)==null?void 0:u.status))}">${Et(t.brief.status??((m=t.keeper)==null?void 0:m.status))}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 하트비트 · ${(p=t.keeper)!=null&&p.last_heartbeat?Ut(t.keeper.last_heartbeat):"기록 없음"}</span>
          <span>${e||"연속성 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${t.currentWork}</strong>
          ${(v=t.keeper)!=null&&v.skill_reason?i`<small>판단 요약 · ${jt(t.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>연속성 상세</summary>
        <div class="mission-activity-foot">
          <span>에이전트 · ${t.brief.agent_name??((f=t.keeper)==null?void 0:f.agent_name)??"기록 없음"}</span>
          ${t.recentEvent?i`<span>최근 일 · ${t.recentEvent}</span>`:null}
        </div>
        <details class="mission-card-disclosure compact">
          <summary>입력 · 응답 · 도구</summary>
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
          <div class="mission-activity-foot">
            <span>최근 도구 · ${n}</span>
          </div>
        </details>
      </details>
    </article>
  `}function Ug({item:t}){const e=t.action??null,n=t.attention??null;return i`
    <article class="mission-action-card ${ht(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${ht(t.severity)}">
          ${t.signal_type==="action"&&e?ni(e.action_type):(n==null?void 0:n.kind)??"내부 신호"}
        </span>
        <span class="mission-card-target">${ja(t.target_type)}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      ${e?i`<div class="mission-action-preview">${e.reason}</div>`:null}
      <div class="mission-card-actions">
        ${e?i`
              <button class="control-btn ghost" onClick=${()=>or(e,n,"상황판 내부 신호")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Td(e,n,"상황판 내부 신호")}>이 이슈의 원인 보기</button>
            `:n?i`
                <button class="control-btn ghost" onClick=${()=>Cd(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>Ad(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function xl(){var k,$,z;const t=hs.value;if(po.value&&!t)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(ka.value&&!t)return i`<div class="empty-state error">${ka.value}</div>`;if(!t)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;te.value&&!t.attention_queue.some(S=>S.id===te.value)&&(te.value=null);const e=t.sessions;ce.value&&!e.some(S=>S.session_id===ce.value)&&(ce.value=null);const n=t.attention_queue.find(S=>S.id===te.value)??null,s=(n==null?void 0:n.related_session_ids.find(S=>e.some(M=>M.session_id===S)))??null,a=ce.value??s??((k=e[0])==null?void 0:k.session_id)??null,o=Of(),l=e.find(S=>S.session_id===a)??null,c=t.keeper_briefs.slice(0,6).map(wf),u=t.attention_queue.filter(S=>S.related_session_ids.length>0).slice(0,6),m=t.internal_signals.slice(0,3),p=e.filter(S=>{var T;const M=((T=S.top_attention)==null?void 0:T.severity)??S.health??S.status;return ht(M)!=="ok"||!!S.blocker_summary}).length,v=e.filter(S=>S.last_event_summary||S.last_event_at).length,f=new Set(e.flatMap(S=>S.member_names)).size,h=e.flatMap(S=>S.member_previews??[]).filter(S=>S.recent_output_preview).length+c.filter(S=>S.recentOutput).length,A=((l==null?void 0:l.member_previews)??[]).filter(S=>S.recent_output_preview),b=c.filter(S=>S.recentOutput).slice(0,4);return nt(()=>{_v(a)},[a]),i`
    <section class="dashboard-panel mission-view">
      <${Ct} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 어떤 세션이 돌고 있고, 누가 참여하며, 어디가 막혔는지를 한 시점에서 읽는 기본 관찰면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${ht(t.summary.room_health)}">${Et(t.summary.room_health)}</span>
          <span class="command-chip">${t.summary.project??"프로젝트 미지정"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?Ut(t.generated_at):"기록 없음"}</span>
        </div>
      </div>

      <${Og}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <div class="mission-stat-grid">
        <${He} label="활성 세션" value=${e.length} detail="지금 진행중인 협업 단위" tone=${(($=l==null?void 0:l.top_attention)==null?void 0:$.severity)??(l==null?void 0:l.health)??"ok"} />
        <${He} label="막힌 세션" value=${p} detail="주의가 필요한 흐름" tone=${p>0?"warn":"ok"} />
        <${He} label="최근 사건 세션" value=${v} detail="최근 사건이 관측된 세션" tone=${v>0?"ok":"warn"} />
        <${He} label="참여자" value=${f} detail="현재 세션에 연결된 주체" tone=${f>0?"ok":"warn"} />
        <${He} label="키퍼 관찰" value=${c.length} detail="연속성 확인 대상" tone=${((z=c[0])==null?void 0:z.brief.status)??"ok"} />
        <${He} label="최근 응답" value=${h} detail="메인에서 바로 읽을 수 있는 응답 수" tone=${h>0?"ok":"warn"} />
      </div>

      ${a?i`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${(l==null?void 0:l.goal)??a}${n?` · ${n.summary}`:""}</span>
              <button class="control-btn ghost" onClick=${qf}>선택 해제</button>
            </div>
          `:null}

      <${R} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 작전을 먼저 읽고 사회의 현재 상태를 파악합니다.</p>
          <div class="mission-briefing-meta">
            <span class="command-chip ok">truth</span>
          </div>
        </div>
        <div class="mission-list-stack">
          ${e.length>0?e.map(S=>i`<${Fg} key=${S.session_id} brief=${S} selected=${a===S.session_id} />`):i`<div class="empty-state">지금 활성 세션이 없습니다.</div>`}
        </div>
      <//>

      <${Kg}
        detail=${mo.value}
        loading=${sa.value}
        error=${aa.value}
      />

      <${R} title="키퍼 연속성" class="mission-list-card" semanticId="mission.keeper_activity">
        <div class="mission-section-head">
          <h3>세션 밖에서 움직이는 행위자</h3>
          <p>키퍼는 세션과 별개로 보고, 사회의 연속성과 장기 행위자 상태를 먼저 읽습니다.</p>
          <div class="mission-briefing-meta">
            <span class="command-chip ok">truth</span>
          </div>
        </div>
        <div class="mission-activity-list">
          ${c.length>0?c.map(S=>i`<${Bg} key=${S.brief.name} row=${S} />`):i`<div class="empty-state">지금 보이는 키퍼가 없습니다.</div>`}
        </div>
        <div class="mission-card-actions">
          <button class="control-btn ghost" onClick=${()=>it("execution")}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${()=>it("command")}>지휘 진단면 보기</button>
        </div>
      <//>

      <${R} title="최근 사회 활동" class="mission-list-card" semanticId="mission.session_activity">
        <div class="mission-section-head">
          <h3>누가 방금 무엇을 했나</h3>
          <p>선택된 세션과 연결된 행위자의 최근 출력만 모아 읽고, 해석은 뒤로 미룹니다.</p>
          <div class="mission-briefing-meta">
            <span class="command-chip ok">truth</span>
          </div>
        </div>
        <div class="mission-list-stack">
          ${A.length>0?A.slice(0,4).map(S=>i`
                <div class="mission-inline-note">
                  <strong>${S.agent_name??"unknown actor"}</strong>
                  ${S.role?i` · ${S.role}`:null}
                  ${S.status?i` · ${Et(S.status)}`:null}
                  <div>${S.recent_output_preview}</div>
                </div>
              `):i`<div class="empty-state">선택된 세션에서 바로 읽을 최근 출력이 없습니다.</div>`}
          ${b.length>0?b.map(S=>i`
                <div class="mission-inline-note">
                  <strong>${S.brief.name}</strong>
                  <div>${S.recentOutput}</div>
                </div>
              `):null}
        </div>
      <//>

      <${R} title="세션 우선순위" class="mission-list-card" semanticId="mission.attention_queue">
        <div class="mission-section-head">
          <h3>어느 세션을 먼저 봐야 하나</h3>
          <p>주의 신호는 truth를 훑은 다음에만 읽고, 세션 집중 순서를 정하는 용도로만 씁니다.</p>
          <div class="mission-briefing-meta">
            <span class="command-chip warn">derived</span>
          </div>
        </div>
        <div class="mission-lane-stack">
          ${u.length>0?u.map(S=>i`<${qg} key=${S.id} item=${S} selected=${te.value===S.id} sessionLookup=${o} />`):i`<div class="empty-state">지금 세션 단위 주의 대기열은 비어 있습니다.</div>`}
        </div>
      <//>

      <div class="mission-human-grid">
        <${Dg} />

        <${R} title="운영 보조 진단" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>시스템 진단</h3>
            <p>artifact scope drift 같은 내부 신호는 사회 흐름을 읽은 뒤에만 참고하도록 아래 보조 면으로 둡니다.</p>
            <div class="mission-briefing-meta">
              <span class="command-chip warn">derived</span>
            </div>
          </div>
          <details class="mission-card-disclosure">
            <summary>내부 신호 ${m.length}</summary>
            <div class="mission-list-stack">
              ${m.length>0?m.map(S=>i`<${Ug} key=${S.id} item=${S} />`):i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
            </div>
          </details>
        <//>
      </div>
    </section>
  `}const Hg="modulepreload",Wg=function(t){return"/dashboard/"+t},Sl={},Gg=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(m){return Promise.all(m.map(p=>Promise.resolve(p).then(v=>({status:"fulfilled",value:v}),v=>({status:"rejected",reason:v}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),u=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(m=>{if(m=Wg(m),m in Sl)return;Sl[m]=!0;const p=m.endsWith(".css"),v=p?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${v}`))return;const f=document.createElement("link");if(f.rel=p?"stylesheet":Hg,p||(f.as="script"),f.crossOrigin="",f.href=m,u&&f.setAttribute("nonce",u),document.head.appendChild(f),p)return new Promise((h,A)=>{f.addEventListener("load",h),f.addEventListener("error",()=>A(new Error(`Unable to preload CSS for ${m}`)))})}))}function o(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&o(c.reason);return e().catch(o)})};function ns(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Y(t){if(!t)return"정보 없음";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function Jg(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Od(t){if(!t)return"정보 없음";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"기한 지남":n<60?`${n}초 후`:n<3600?`${Math.round(n/60)}분 후`:n<86400?`${Math.round(n/3600)}시간 후`:`${Math.round(n/86400)}일 후`}function E(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let Cl=!1,Vg=0;function Yg(){return++Vg}let bi=null;async function Xg(){bi||(bi=Gg(()=>import("./mermaid.core-BIQMy4Cq.js").then(e=>e.bE),[]).then(e=>e.default));const t=await bi;return Cl||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),Cl=!0),t}function ve(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Sn(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":`${Math.round(t*100)}%`}function Qe(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":t<60?`${Math.round(t)}초`:t<3600?`${Math.round(t/60)}분`:`${Math.round(t/3600)}시간`}function Cs(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function Ce(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:Cs(t/e*100)}function Qg(t,e){const n=Cs(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function ai(t){if(!t)return"최근 체인 이력이 없습니다";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`토큰 ${t.tokens}`),t.message&&e.push(t.message),e.join(" · ")}const Zg=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Dd=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"orchestra",label:"오케스트라",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],t$=Dd.map(t=>t.id),e$=["chain_start","node_start","node_complete","chain_complete","chain_error"],n$={warroom:{title:"실시간 워룸",description:"실제 실행, 워커, 메시지, 트레이스를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 작전, 분견대, 의존 관계를 먼저 읽는 기본 진입 표면입니다."},orchestra:{title:"룸 오케스트라 맵",description:"룸, 세션, 레인, 워커, 키퍼를 한 장의 작전판으로 읽는 시각화 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"레인 이동, 워커 결속, 막힘을 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 작전별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"실제 관리 유닛인지, 실시간 에이전트 기반 자동 투영인지 구분해서 봅니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"작전, 주체, 유닛 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"결정 승인과 유닛 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function Al(t){return!!t&&t$.includes(t)}function s$(){const t=O.value.params;return t.source!=="mission"&&t.source!=="execution"?{}:{source:t.source,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function As(t){const e=s$(),n=Kd(),s=cr();if(t==="operations")return e;if(t==="chains"){const a=dn.value;return a?{...e,surface:t,operation:a}:{...e,surface:t}}return t==="swarm"||t==="warroom"||t==="orchestra"?{...e,surface:t,...n?{run_id:n}:{},...s?{operation_id:s}:{}}:{...e,surface:t}}function a$(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function i$(t){switch(t){case"company":return"중대";case"platoon":return"소대";case"squad":return"분대";case"agent":return"에이전트";default:return t}}function ut(t){return vo.value===t}function Ts(){return Yo.value}function o$(t){var a,o,l,c,u,m,p;const e=Yo.value,n=Be.value,s=bs.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"실시간 실행, 워커, 메시지, 트레이스를 한 화면에서 보고 필요한 세부 표면으로 바로 이동합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 의존 관계를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(o=e==null?void 0:e.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((u=(c=e==null?void 0:e.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:u.reason)??"레인 이동과 막힘 근거를 보고 다음 확인 도구를 고릅니다."};case"orchestra":return{tool:"masc_operator_snapshot",reason:"룸, 세션, 레인, 워커, 키퍼를 한 장에서 훑은 뒤 내려볼 대상을 고릅니다."};case"chains":return{tool:(p=(m=s==null?void 0:s.operations[0])==null?void 0:m.preview_run)!=null&&p.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"이 구조가 실제 관리 단위인지 자동 투영인지 먼저 구분해야 지휘면을 오해하지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 유닛과 작전을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"트레이스 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 제어 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function r$(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function l$(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function qd(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Fd(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function Kd(){const e=Fd().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function cr(){const e=Fd().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function c$(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function d$(t){return t.status==="claimed"||t.status==="in_progress"}function u$(t){const e=ys.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function ki(t){var e;return((e=ys.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function p$(t){const e=ys.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function fe(t){try{await t()}catch{}}function dr(t){return(t==null?void 0:t.trim().toLowerCase())??""}function de(t){const e=dr(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function Ft(t){const e=dr(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function m$(){var n,s,a,o,l,c,u,m,p;const t=Be.value;if(!t)return!1;const e=t.workers.some(v=>v.joined||v.live_presence||v.completed||v.current_task_matches_run||v.heartbeat_fresh||v.claim_marker_seen||v.done_marker_seen||v.final_marker_seen||!!v.current_task||!!v.bound_task_id||!!v.last_message);return!!((n=t.operation)!=null&&n.operation_id||(s=t.detachment)!=null&&s.detachment_id||(((a=t.summary)==null?void 0:a.joined_workers)??0)>0||(((o=t.summary)==null?void 0:o.live_workers)??0)>0||(((l=t.summary)==null?void 0:l.current_task_bound)??0)>0||(((c=t.summary)==null?void 0:c.fresh_heartbeats)??0)>0||(((u=t.summary)==null?void 0:u.claim_markers_seen)??0)>0||(((m=t.summary)==null?void 0:m.done_markers_seen)??0)>0||(((p=t.summary)==null?void 0:p.final_markers_seen)??0)>0||e||t.recent_messages.length>0||t.recent_trace_events.length>0)}function _$(t){const e=dr(t.status);return e==="active"||e==="running"}function v$(){var o,l,c,u;const t=((o=At.value)==null?void 0:o.sessions)??[],e=Be.value,n=((l=e==null?void 0:e.detachment)==null?void 0:l.session_id)??null;if(n){const m=t.find(p=>p.session_id===n);if(m)return m}const s=((c=e==null?void 0:e.operation)==null?void 0:c.operation_id)??cr();if(s){const m=t.find(p=>p.command_plane_operation_id===s);if(m)return m}const a=((u=e==null?void 0:e.detachment)==null?void 0:u.detachment_id)??null;if(a){const m=t.find(p=>p.command_plane_detachment_id===a);if(m)return m}return t.find(_$)??t[0]??null}function In(t){return t==="proven"?"ok":t==="partial"?"warn":"bad"}function Ze(t){return Array.isArray(t)?t:[]}function wt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)?t:{}}function Ps(t){return typeof t=="string"&&t.trim()!==""?t:null}function f$(t){return typeof t=="number"&&Number.isFinite(t)?t:null}function g$(t){const e=t.split("/");return e.length<=3?t:`…/${e.slice(-3).join("/")}`}function $$(t){return t==="proven"?"충분":t==="partial"?"부분":"부족"}function h$(t){return t==="proven"?"협업 증거가 충분합니다":t==="partial"?"흔적은 있으나 협업 증거가 덜 모였습니다":"증거가 부족합니다"}function y$(t,e,n,s,a,o,l,c,u){const m=[`${s}명이 실제 흔적을 남겼고, 계획된 참여자는 ${a}명입니다.`,l>0?`서로를 참조한 상호작용 증거가 ${l}건 있습니다.`:"서로를 참조한 명시적 상호작용 증거가 아직 없습니다.",c>0?`도구·산출물·체크포인트 증거가 ${c}건 있습니다.`:"도구·산출물·체크포인트 증거가 거의 없습니다.",u>0?`CPv2 backing trace가 ${u}건 있어 실행 흔적은 남아 있습니다.`:"관리형 backing trace는 아직 없습니다."];return n==="proven"&&e==="insufficient"?[m[0]??"","왜 이렇게 판정됐나: 과거 proof는 proved였지만, 현재 보이는 live evidence는 부족해서 partial로 완화했습니다.","다음 보강 포인트: 최근 응답 턴이나 도구 호출을 다시 남겨 historical proof를 현재 상태와 연결해야 합니다."]:n==="proven"&&e==="partial"?[m[0]??"","왜 이렇게 판정됐나: historical proof는 강하지만, 현재 live evidence는 아직 partial 수준입니다.","다음 보강 포인트: 최근 상호작용과 실행 근거를 더 남기면 proven으로 회복할 수 있습니다."]:t==="partial"?[m[0]??"",o>0?`partial인 이유: 호출되었지만 응답하지 않은 참여자가 ${o}명 있습니다.`:l===0?"partial인 이유: 여러 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.":"partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.",u>0?"다음 보강 포인트: 응답 턴이나 도구 호출을 남기면 proof가 협업 수준으로 올라갑니다.":"다음 보강 포인트: 관리형 trace 또는 산출물 연결을 더 남기면 근거가 강해집니다."]:t==="proven"?[m[0]??"","결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.","다음 행동: raw evidence는 접어두고 결과 산출물과 다음 실행 결정만 확인하면 됩니다."]:[m[0]??"",o>0?`결론: 협업 시도는 있었지만 무응답 참여자가 ${o}명 있어 협업 증거로 인정하기 어렵습니다.`:"결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.",c>0?"다음 보강 포인트: 응답 턴과 도구 근거를 서로 연결해 남겨야 합니다.":"다음 보강 포인트: 참여자 간 턴, 도구 근거, 산출물 연결을 더 남겨야 합니다."]}function b$(t){return t==="historical_only"?"historical only":t==="live_and_historical"?"live + historical":"live"}function Tl(t){return(t==null?void 0:t.mode)==="requested_not_found"?"bad":(t==null?void 0:t.mode)==="latest_auto_selected"?"warn":"ok"}function k$(t){return(t==null?void 0:t.mode)==="requested_not_found"?"선택 실패":(t==null?void 0:t.mode)==="latest_auto_selected"?"자동 선택":(t==null?void 0:t.mode)==="explicit"?"명시 선택":"선택 없음"}function x$(t){return t.activity_state==="acted"?(t.interaction_count??0)>0||(t.tool_evidence_count??0)>0?"ok":"warn":t.activity_state==="mentioned_only"?"warn":"bad"}function S$(t){return t.activity_state==="acted"?"실제 흔적":t.activity_state==="mentioned_only"?"호출만 됨":"계획만 됨"}function C$(t){if(t.activity_state==="acted")return`턴 ${t.turn_count??0} · spawn ${t.spawn_count??0} · 도구 근거 ${t.tool_evidence_count??0}`;if(t.activity_state==="mentioned_only"){const e=t.requested_by?`호출자 ${t.requested_by}`:"호출자 미상";return`호출 ${t.mention_count??0}회 · ${e}`}return"계획된 참여자이지만 아직 이벤트가 없습니다."}function Il(t){return Array.isArray(t.tool_names)?t.tool_names:[]}function A$({selection:t,summary:e}){if(!t||t.mode==="explicit")return null;const n=t.mode==="latest_auto_selected"&&(e==null?void 0:e.historical_verdict)==="proven"&&(e==null?void 0:e.live_verdict)!=="proven";return i`
    <div class="command-guide-card ${Tl(t)}">
      <div class="command-guide-head">
        <strong>${k$(t)}</strong>
        <span class="command-chip ${Tl(t)}">${t.mode??"none"}</span>
      </div>
      <p>${t.reason??"근거 컨텍스트 선택 정보가 없습니다."}</p>
      ${n?i`<p>선택된 최신 세션은 historical proof가 더 강하고 current live evidence는 더 약합니다.</p>`:null}
      <div class="command-card-grid">
        <span>선택된 세션</span><span>${t.selected_session_id??"없음"}</span>
        <span>작성자</span><span>${t.selected_created_by??"없음"}</span>
        <span>선택된 목표</span><span>${t.selected_goal??"없음"}</span>
        <span>가용 세션 수</span><span>${t.available_session_count??0}</span>
      </div>
    </div>
  `}function T$({item:t}){return i`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${t.summary??t.event_type??"도구 근거"}</strong>
          <div class="command-meta-line">
            <span>${t.actor??"시스템"}</span>
            <span>${t.event_type??"event"}</span>
          </div>
        </div>
        <span class="command-chip">${Y(t.timestamp??null)}</span>
      </div>
      ${Il(t).length>0?i`<div class="semantic-tag-row">
            ${Il(t).map(e=>i`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
    </article>
  `}function I$(t){const e=new Map;for(const n of t){const s=[n.timestamp??"",n.event_type??"",n.actor??"",n.summary??""].join("|"),a=n.source??"unknown",o=e.get(s);if(o){o.sources.includes(a)||o.sources.push(a),!o.operation_id&&n.operation_id&&(o.operation_id=n.operation_id);continue}e.set(s,{...n,sources:[a]})}return[...e.values()]}function R$(t){return t.sources.length===2?"세션 + 지휘":t.sources.length===1?t.sources[0]==="unknown"?"출처 미상":t.sources[0]??"출처":t.sources.join(" + ")}function M$(t){const e=[];for(const[n,s]of Object.entries(t))if(s!=null){if(typeof s=="string"){if(s.trim()==="")continue;e.push({label:n,value:s});continue}if(typeof s=="number"||typeof s=="boolean"){e.push({label:n,value:String(s)});continue}}return e}function L$(t){const e=wt(t),n=wt(e.traces),s=Array.isArray(n.events)?n.events:[],a=wt(e.detachments),o=Array.isArray(a.detachments)?a.detachments:[],l=wt(o[0]),c=wt(l.detachment),u=wt(l.operation),m=wt(e.summary),p=wt(m.operations),v=wt(p.summary);return[{label:"작전",value:Ps(e.operation_id)??"없음"},{label:"분견대",value:Ps(e.detachment_id)??"없음"},{label:"트레이스 이벤트",value:`${s.length}`},{label:"분견대 상태",value:Ps(c.status)??"없음"},{label:"작전 단계",value:Ps(u.stage)??"없음"},{label:"활성 작전",value:`${f$(v.active)??0}`}]}function z$({item:t}){return i`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${t.summary??t.event_type??"이벤트"}</strong>
          <div class="command-meta-line">
            <span>${R$(t)}</span>
            <span>${t.event_type??"이벤트"}</span>
            <span>${t.actor??"시스템"}</span>
          </div>
        </div>
        <span class="command-chip">${Y(t.timestamp)}</span>
      </div>
      ${t.sources.length>1?i`<div class="semantic-tag-row">
            ${t.sources.map(e=>i`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
    </article>
  `}function E$({item:t}){const e=t.recent_output_preview??null,n=t.recent_input_preview??null,s=t.recent_event_summary??null,a=t.recent_request_preview??null,o=t.last_active_at??t.recent_request_at??null;return i`
    <article class="mission-activity-row proof-actor-row">
      <div class="mission-activity-head">
        <div>
          <strong>${t.actor}</strong>
          <div class="mission-activity-meta">
            <span>${t.role??"참여자"}</span>
            <span>${o?Y(o):"기록 없음"}</span>
          </div>
        </div>
        <span class="command-chip ${x$(t)}">
          ${S$(t)}
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>${C$(t)}</span>
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
      ${Ze(t.recent_tool_names).length>0?i`<div class="semantic-tag-row">
            ${Ze(t.recent_tool_names).map(l=>i`<span class="semantic-tag">${l}</span>`)}
          </div>`:null}
    </article>
  `}function P$({item:t}){return i`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${t.kind}</strong>
          <div class="command-meta-line">
            <span>${g$(t.path)}</span>
          </div>
        </div>
        <span class="command-chip ${t.exists?"ok":"warn"}">${t.exists?"존재함":"없음"}</span>
      </div>
    </article>
  `}function Rl({title:t,rows:e}){return e.length===0?null:i`
    <div class="proof-kv-block">
      ${t?i`<strong>${t}</strong>`:null}
      <div class="proof-kv-grid">
        ${e.map(n=>i`
          <span>${n.label}</span>
          <strong>${n.value}</strong>
        `)}
      </div>
    </div>
  `}function N$(){var W,I,x;const t=O.value.params,e=t.session_id??null,n=t.operation_id??null;nt(()=>{sd(e,n)},[e,n]);const s=nd.value;if(_o.value&&!s)return i`<section class="dashboard-panel"><div class="loading-indicator">근거 화면 불러오는 중…</div></section>`;if(Ye.value&&!s)return i`<section class="dashboard-panel"><div class="error-card">${Ye.value}</div></section>`;const a=s==null?void 0:s.summary,o=(s==null?void 0:s.selection)??null,l=Ze(s==null?void 0:s.actor_contributions),c=Ze(s==null?void 0:s.artifacts),u=Ze(s==null?void 0:s.tool_evidence),m=(s==null?void 0:s.proof_verdict)??"insufficient",p=(a==null?void 0:a.live_verdict)??m,v=(a==null?void 0:a.historical_verdict)??null,f=(a==null?void 0:a.verdict_basis)??"live",h=(s==null?void 0:s.cp_backing_evidence)??null,A=Array.isArray((W=h==null?void 0:h.traces)==null?void 0:W.events)?((x=(I=h.traces)==null?void 0:I.events)==null?void 0:x.length)??0:0,b=(a==null?void 0:a.actors_count)??l.length,k=(a==null?void 0:a.planned_actor_count)??l.length,$=(a==null?void 0:a.unanswered_actor_count)??l.filter(L=>L.activity_state!=="acted"&&(L.mention_count??0)>0).length,z=(a==null?void 0:a.mentioned_actor_count)??l.filter(L=>(L.mention_count??0)>0).length,S=(a==null?void 0:a.interaction_count)??0,M=(a==null?void 0:a.evidence_count)??0,T=I$(Ze(s==null?void 0:s.timeline)),K=M$(wt(s==null?void 0:s.goal_binding)),U=L$(h),et=c.filter(L=>L.exists).length,Q=c.length-et,tt=y$(m,p,v,b,k,$,S,M,A);return i`
    <section class="dashboard-panel mission-view">
      <${Ct} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>근거</h2>
          <p>이 세션이 실제로 여러 참여자의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${In(m)}">${$$(m)}</span>
          ${s!=null&&s.session_id?i`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?i`<span class="command-chip">${Y(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${Ye.value?i`<div class="error-card">${Ye.value}</div>`:null}

      <${A$} selection=${o} summary=${a??null} />

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${In(m)}">
          <span>판정</span>
          <strong>${h$(m)}</strong>
          <small>${(a==null?void 0:a.detail)??"협업 증거를 verdict로 요약합니다."}</small>
        </div>
        <div class="summary-stat-card ${In(p)}">
          <span>Live 판정</span>
          <strong>${p}</strong>
          <small>${b$(f)} 기준 최종 판정에 반영</small>
        </div>
        <div class="summary-stat-card ${In(v??"insufficient")}">
          <span>Historical proof</span>
          <strong>${v??"none"}</strong>
          <small>persisted proof 문서 기준</small>
        </div>
        <div class="summary-stat-card">
          <span>실제 흔적</span>
          <strong>${b}</strong>
          <small>이벤트를 남긴 actor 수</small>
        </div>
        <div class="summary-stat-card ${k>b?"warn":"ok"}">
          <span>계획된 참여자</span>
          <strong>${k}</strong>
          <small>${z>0?`${z}명 호출됨`:"호출 기록 없음"}</small>
        </div>
        <div class="summary-stat-card ${$>0?"warn":"ok"}">
          <span>무응답</span>
          <strong>${$}</strong>
          <small>${$>0?"호출됐지만 응답 근거 없음":"무응답 참여자 없음"}</small>
        </div>
        <div class="summary-stat-card ${S>0?"ok":"warn"}">
          <span>직접 상호작용</span>
          <strong>${S}</strong>
          <small>참여자 간 직접 연결 근거</small>
        </div>
        <div class="summary-stat-card ${M>0?"ok":"warn"}">
          <span>근거</span>
          <strong>${M}</strong>
          <small>도구 / 산출물 / 체크포인트</small>
        </div>
        <div class="summary-stat-card ${A>0?"ok":"warn"}">
          <span>CP 트레이스</span>
          <strong>${A}</strong>
          <small>관리형 backing 이벤트</small>
        </div>
        <div class="summary-stat-card ${Q===0&&c.length>0?"ok":"warn"}">
          <span>산출물</span>
          <strong>${et}/${c.length}</strong>
          <small>${Q>0?`${Q}개 누락`:"전부 존재함"}</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${R} title="3줄 근거 요약" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, 왜 아직 부족한지, 다음에 무엇을 남겨야 하는지만 먼저 봅니다.</p>
          </div>
          <div class="proof-summary-stack">
            ${tt.map((L,G)=>i`
              <article class="proof-summary-block ${G===1&&m!=="proven"?In(m):""}">
                <strong>${G===0?"지금 결론":G===1?"왜 이렇게 판정됐나":"다음 보강 포인트"}</strong>
                <span>${L}</span>
              </article>
            `)}
          </div>
        <//>

        <${R} title="목표 연결" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 화면이 어떤 세션과 목표를 기준으로 그려졌는지 먼저 고정합니다.</p>
          </div>
          <${Rl} rows=${K} />
          <details class="mission-card-disclosure compact">
            <summary>원본 목표 연결 JSON</summary>
            <pre class="command-json-block">${ns((s==null?void 0:s.goal_binding)??{})}</pre>
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
            ${T.length>0?T.slice(0,18).map(L=>i`<${z$} key=${L.id} item=${L} />`):i`<div class="empty-state">표시할 타임라인 근거가 없습니다.</div>`}
          </div>
        <//>

        <${R} title="참여 흔적" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>실제 흔적, 호출만 된 참여자, 계획만 된 참여자를 구분해서 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${l.length>0?l.map(L=>i`<${E$} key=${L.actor} item=${L} />`):i`<div class="empty-state">표시할 참여 흔적이 없습니다.</div>`}
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
            ${u.length>0?u.map((L,G)=>i`<${T$} key=${`${L.actor??"system"}-${G}`} item=${L} />`):i`<div class="empty-state">기록된 tool evidence가 없습니다.</div>`}
          </div>
        <//>

        <${R} title="실행 근거" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>작전, 분견대, 트레이스 수만 먼저 보고, 원본 CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${Rl} rows=${U} />
          <details class="mission-card-disclosure compact">
            <summary>원본 CPv2 backing JSON</summary>
            <pre class="command-json-block">${ns(h??{})}</pre>
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
            ${c.length>0?c.map(L=>i`<${P$} key=${L.path} item=${L} />`):i`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function xi(t){const e=(t??"").trim().toLowerCase();return e==="bad"||e==="critical"||e==="offline"?"bad":e==="warn"||e==="paused"||e==="blocked"?"warn":"ok"}function j$(){var n;const t=(n=Jo.value)==null?void 0:n.focus;if(!(t!=null&&t.suggested_tab))return;const e=t.suggested_params??{};if(t.suggested_tab==="intervene"){it("intervene",e);return}it("command",{...t.suggested_surface?{surface:t.suggested_surface}:{},...e})}function ur(){var u,m,p,v,f,h;const t=Jo.value;if(!t)return uo.value?i`<section class="room-truth-strip room-truth-strip-loading">room truth 불러오는 중...</section>`:ha.value?i`<section class="room-truth-strip room-truth-strip-error">${ha.value}</section>`:null;const e=t.room.status,n=t.room.counts,s=(u=t.execution)==null?void 0:u.summary,a=(m=t.execution)==null?void 0:m.top_queue,o=t.command,l=t.operator,c=t.focus;return i`
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
          <span class="command-chip ${xi(((s==null?void 0:s.blocked_sessions)??0)>0?"warn":"ok")}">priority ${(s==null?void 0:s.priority_items)??0}</span>
          <span class="command-chip">${((p=t.execution)==null?void 0:p.provenance)??"derived"}</span>
        </div>
      </article>

      <article class="room-truth-card">
        <span class="room-truth-label">control</span>
        <strong>작전 ${(o==null?void 0:o.active_operations)??0} · 승인 ${(o==null?void 0:o.pending_approvals)??0}</strong>
        <p>alerts bad ${(o==null?void 0:o.bad_alerts)??0} / warn ${(o==null?void 0:o.warn_alerts)??0} · lanes ${(o==null?void 0:o.moving_lanes)??0}/${(o==null?void 0:o.active_lanes)??0}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${xi(((o==null?void 0:o.bad_alerts)??0)>0?"bad":((o==null?void 0:o.warn_alerts)??0)>0||((o==null?void 0:o.pending_approvals)??0)>0?"warn":"ok")}">
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
          <span class="command-chip ${xi((c==null?void 0:c.provenance)==="fallback"?"warn":"ok")}">${(c==null?void 0:c.source)??"steady"}</span>
          <span class="command-chip">${(c==null?void 0:c.provenance)??((h=l==null?void 0:l.recommendation_summary)==null?void 0:h.provenance)??"derived"}</span>
        </div>
        ${c!=null&&c.suggested_tab?i`
              <div class="room-truth-actions">
                <button class="control-btn ghost" onClick=${j$}>
                  ${c.suggested_tab==="intervene"?"개입면 열기":"지휘면 열기"}
                </button>
              </div>
            `:null}
      </article>
    </section>
  `}function w$(){const t=ks(O.value);return t?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${ni(t.action_type)}</span>
        <span class="command-chip">${ir(t)}</span>
        <span class="command-chip">${zf(O.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?i`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function O$(){const t=V.value,e=n$[t],n=o$(t);return i`
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
  `}function Ns({label:t,value:e,subtext:n,percent:s,color:a}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${Qg(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(Cs(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function js({label:t,value:e,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${E(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${E(a)}" style=${`width: ${Math.max(8,Math.round(Cs(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function D$(){var Q,tt,W,I;const t=Ts(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary,l=(Q=t==null?void 0:t.swarm_status)==null?void 0:Q.overview,c=t==null?void 0:t.swarm_proof,u=t==null?void 0:t.operations.microarch,m=(e==null?void 0:e.managed_unit_count)??0,p=(e==null?void 0:e.total_units)??0,v=(n==null?void 0:n.active)??0,f=(s==null?void 0:s.active)??0,h=(l==null?void 0:l.moving_lanes)??0,A=(l==null?void 0:l.active_lanes)??0,b=(c==null?void 0:c.workers.done)??0,k=(c==null?void 0:c.workers.expected)??0,$=(o==null?void 0:o.bad)??0,z=(o==null?void 0:o.warn)??0,S=(a==null?void 0:a.pending)??0,M=(a==null?void 0:a.total)??0,T=v+f,K=((tt=u==null?void 0:u.cache)==null?void 0:tt.l1_hit_rate)??((I=(W=u==null?void 0:u.signals)==null?void 0:W.cache_contention)==null?void 0:I.l1_hit_rate)??0,U=v>0||f>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",et=v>0||h>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${U}</h3>
        <p>${et}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${E(v>0?"ok":"warn")}">활성 작전 ${v}</span>
          <span class="command-chip ${E(h>0?"ok":(A>0,"warn"))}">이동 레인 ${h}/${Math.max(A,h)}</span>
          <span class="command-chip ${E($>0?"bad":z>0?"warn":"ok")}">치명 알림 ${$}</span>
          <span class="command-chip ${E(S>0?"warn":"ok")}">승인 대기 ${S}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Ns}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(p,m)}`}
          subtext=${p>0?`${p-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${Ce(m,Math.max(p,m))}
          color="#67e8f9"
        />
        <${Ns}
          label="실행 열도"
          value=${String(T)}
          subtext=${`${v}개 작전 + ${f}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${Ce(T,Math.max(m,T||1))}
          color="#4ade80"
        />
        <${Ns}
          label="스웜 이동감"
          value=${`${h}/${Math.max(A,h)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${Y(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${Ce(h,Math.max(A,h||1))}
          color="#fbbf24"
        />
        <${Ns}
          label="증거 수집률"
          value=${`${b}/${Math.max(k,b)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${Ce(b,Math.max(k,b||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${js}
        label="승인 대기열"
        value=${`${S}건 대기`}
        detail=${`현재 정책 창에서 ${M}개 결정을 추적 중입니다`}
        percent=${Ce(S,Math.max(M,S||1))}
        tone=${S>0?"warn":"ok"}
      />
      <${js}
        label="알림 압력"
        value=${`치명 ${$} / 주의 ${z}`}
        detail=${$>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${Ce($*2+z,Math.max(($+z)*2,1))}
        tone=${$>0?"bad":z>0?"warn":"ok"}
      />
      <${js}
        label="디스패치 점유"
          value=${`${f}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${Ce(f,Math.max(m,f||1))}
        tone=${f>0?"ok":"warn"}
      />
      <${js}
        label="캐시 신뢰도"
        value=${K?Sn(K):"정보 없음"}
        detail=${K?"microarch 캐시 텔레메트리에서 집계한 L1 적중률":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Cs((K??0)*100)}
        tone=${K>=.75?"ok":K>=.4?"warn":"bad"}
      />
    </div>
  `}function q$(){var f,h,A,b,k;const t=Ts(),e=bs.value,n=ks(O.value),s=r$(n),a=t==null?void 0:t.topology.summary,o=t==null?void 0:t.operations.summary,l=(f=t==null?void 0:t.swarm_status)==null?void 0:f.overview,c=t==null?void 0:t.operations.microarch,u=t==null?void 0:t.decisions.summary,m=t==null?void 0:t.alerts.summary,p=(h=c==null?void 0:c.signals)==null?void 0:h.issue_pressure,v=c==null?void 0:c.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((A=t==null?void 0:t.detachments.summary)==null?void 0:A.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(u==null?void 0:u.pending)??0}</strong><small>${(u==null?void 0:u.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 주의</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((b=e==null?void 0:e.summary)==null?void 0:b.active_chains)??0}</strong><small>${((k=e==null?void 0:e.summary)==null?void 0:k.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${Y(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(p==null?void 0:p.pending_ops)??0}</strong><small>${(v==null?void 0:v.l1_hit_rate)!=null?`${Sn(v.l1_hit_rate)} L1 적중`:"캐시 데이터 없음"} · ${(p==null?void 0:p.tone)??"정보 없음"}</small></div>
    </div>
  `}function F$(){var Q,tt,W,I,x,L,G,yt,ie;const t=Ts(),e=Jt.value,n=pt.value,s=qd(),a=s?Gt.value.find(H=>H.name===s)??null:null,o=s?ue.value.filter(H=>H.assignee===s&&d$(H)):[],l=((Q=t==null?void 0:t.operations.summary)==null?void 0:Q.active)??0,c=((tt=t==null?void 0:t.detachments.summary)==null?void 0:tt.total)??0,u=((W=t==null?void 0:t.decisions.summary)==null?void 0:W.pending)??0,m=e==null?void 0:e.detachments.detachments.find(H=>{const vt=H.detachment.heartbeat_deadline,be=vt?Date.parse(vt):Number.NaN;return H.detachment.status==="stalled"||!Number.isNaN(be)&&be<=Date.now()}),p=e==null?void 0:e.alerts.alerts.find(H=>H.severity==="bad"),v=!!(n!=null&&n.room||n!=null&&n.project),f=(a==null?void 0:a.current_task)??null,h=c$(a==null?void 0:a.last_seen),A=h!=null?h<=120:null,b=[v?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:ue.value.length>0?"masc_claim":"masc_add_task"}:f?A===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${f} 이지만 heartbeat가 stale 합니다 (${h}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${f}${h!=null?` · 마지막 활동 ${h}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((I=t.topology.summary)==null?void 0:I.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((x=t.topology.summary)==null?void 0:x.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((L=t.topology.summary)==null?void 0:L.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},u>0?{title:"디스패치 준비도",tone:"warn",detail:`${u}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||p?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${p?` · alert ${p.title??p.alert_id}`:""}${!e&&!m&&!p?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:u>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],k=v?!s||!a?"masc_join":o.length===0?ue.value.length>0?"masc_claim":"masc_add_task":f?A===!1?"masc_heartbeat":!t||(((G=t.topology.summary)==null?void 0:G.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":u>0?"masc_policy_approve":l>0&&c===0||m||p?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",$=u$(k),S=p$(k==="masc_set_room"?["repo-root-room"]:k==="masc_plan_set_task"?["claimed-not-current"]:k==="masc_heartbeat"?["heartbeat-stale"]:k==="masc_dispatch_tick"?["no-detachments"]:k==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),M=ki("room_task_hygiene"),T=ki("cpv2_benchmark"),K=ki("supervisor_session"),U=((yt=ys.value)==null?void 0:yt.docs)??[],et=[M,T,K].filter(H=>H!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${D} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${($==null?void 0:$.title)??k}</strong>
            <span class="command-chip ok">${k}</span>
          </div>
          <p>${($==null?void 0:$.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(ie=$==null?void 0:$.success_signals)!=null&&ie.length?i`<div class="command-tag-row">
                ${$.success_signals.map(H=>i`<span class="command-tag ok">${H}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${b.map(H=>i`
            <article class="command-readiness-row ${E(H.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${H.title}</strong>
                  <span class="command-chip ${E(H.tone)}">${H.tone}</span>
                </div>
                <p>${H.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${H.tool}</div>
            </article>
          `)}
        </div>

        ${S.length>0?i`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${S.length}</span>
                </div>
                <div class="command-guide-list">
                  ${S.map(H=>i`
                    <article class="command-guide-inline">
                      <strong>${H.title}</strong>
                      <div>${H.symptom}</div>
                      <div class="command-card-sub">${H.fix_tool} 로 해결: ${H.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `:null}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">운영 경로</div>
          <${D} panelId="command.summary" compact=${!0} />
        </div>
        ${fo.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:Ra.value?i`<div class="empty-state error">${Ra.value}</div>`:i`
                <div class="command-path-grid">
                  ${et.map(H=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${H.title}</strong>
                        <span class="command-chip">${H.id}</span>
                      </div>
                      <p>${H.summary}</p>
                      <div class="command-card-sub">${H.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${H.steps.slice(0,4).map(vt=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${vt.tool}</span>
                            <span>${vt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${U.length>0?i`<div class="command-doc-links">
                      ${U.map(H=>i`<span class="command-tag">${H.title}: ${H.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function K$(){return i`
    <${D$} />
    <${q$} />
    <${F$} />
  `}function B$(){return Ca.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:Ta.value?i`<div class="empty-state error">${Ta.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}const Ae=g(null),ws=g("compact"),re=g({zoom:1,panX:0,panY:0}),Si=g(!1),Os=g(!1),En={width:1280,height:760},Bd=.42,Ud=1.9;function oa(t,e,n){return Math.max(e,Math.min(n,t))}function pr(t,e){const n=t==null?void 0:t.trim();return n?n.length<=e?n:`${n.slice(0,Math.max(1,e-1))}…`:null}function U$(t){return t==="compact"?"집약":"균형"}function Ml(t){switch((t??"").trim().toLowerCase()){case"room":return"룸";case"session":return"세션";case"operation":return"작전";case"detachment":return"분견대";case"lane":return"레인";case"worker":return"워커";case"keeper":return"키퍼";default:return(t==null?void 0:t.trim())||"노드"}}function Ds(t,e,n){if(t<=0)return[];if(t===1)return[Math.round((e+n)/2)];const s=(n-e)/(t-1);return Array.from({length:t},(a,o)=>Math.round(e+o*s))}function H$(t,e){const n=new Map;for(const s of t){const a=e(s),o=n.get(a)??[];o.push(s),n.set(a,o)}return n}function Hd(t){return t==="compact"?{room:{x:660,y:108},sessions:{y:228,min:220,max:1110},operations:{y:338,min:260,max:1050},detachments:{y:430,min:310,max:1e3},lanes:{y:540,min:220,max:1110},worker:{perRow:5,xSpacing:60,ySpacing:52,laneOffsetY:76,freeBaseY:662},keeper:{startX:1180,colSpacing:92,rowSpacing:90,startY:176,columns:2},signalRadius:116}:{room:{x:700,y:112},sessions:{y:236,min:240,max:1140},operations:{y:356,min:300,max:1080},detachments:{y:454,min:340,max:1030},lanes:{y:584,min:230,max:1110},worker:{perRow:4,xSpacing:72,ySpacing:60,laneOffsetY:82,freeBaseY:720},keeper:{startX:1210,colSpacing:108,rowSpacing:102,startY:188,columns:2},signalRadius:132}}function Wd(t,e){return t.kind==="room"?e==="compact"?{width:138,height:138,radius:68}:{width:156,height:156,radius:76}:t.kind==="worker"?e==="compact"?{width:70,height:36,radius:18}:{width:84,height:44,radius:22}:t.kind==="lane"?e==="compact"?{width:156,height:48,radius:15}:{width:176,height:56,radius:17}:t.kind==="keeper"?e==="compact"?{width:118,height:50,radius:22}:{width:132,height:60,radius:24}:t.kind==="session"?e==="compact"?{width:182,height:58,radius:17}:{width:202,height:68,radius:18}:e==="compact"?{width:176,height:58,radius:16}:{width:196,height:68,radius:18}}function W$(t,e){const n=t.kind==="worker"?e==="compact"?10:14:t.kind==="keeper"?e==="compact"?12:16:t.kind==="lane"?e==="compact"?16:22:e==="compact"?18:26;return pr(t.label,n)??t.label}function G$(t,e){if(e==="compact"&&(t.kind==="worker"||t.kind==="keeper"||t.kind==="detachment"))return null;const n=t.kind==="session"?e==="compact"?20:28:e==="compact"?14:24;return pr(t.subtitle,n)}function J$(t,e){return e==="compact"&&t.kind!=="session"&&t.kind!=="operation"?null:pr(t.status,e==="compact"?10:14)}function V$(t,e){const n=Hd(e),s=new Map,a=t.nodes,o=a.find(b=>b.kind==="room")??null,l=a.filter(b=>b.kind==="session"),c=a.filter(b=>b.kind==="operation"),u=a.filter(b=>b.kind==="detachment"),m=a.filter(b=>b.kind==="lane"),p=a.filter(b=>b.kind==="worker"),v=a.filter(b=>b.kind==="keeper");o&&s.set(o.id,{x:n.room.x,y:n.room.y}),Ds(l.length,n.sessions.min,n.sessions.max).forEach((b,k)=>{const $=l[k];$&&s.set($.id,{x:b,y:n.sessions.y})}),Ds(c.length,n.operations.min,n.operations.max).forEach((b,k)=>{const $=c[k];$&&s.set($.id,{x:b,y:n.operations.y})}),Ds(u.length,n.detachments.min,n.detachments.max).forEach((b,k)=>{const $=u[k];$&&s.set($.id,{x:b,y:n.detachments.y})}),Ds(m.length,n.lanes.min,n.lanes.max).forEach((b,k)=>{const $=m[k];$&&s.set($.id,{x:b,y:n.lanes.y})});const f=new Map(m.map(b=>{const k=s.get(b.id);return k?[b.id,k.x]:null}).filter(b=>b!==null)),h=H$(p,b=>b.lane_id?`lane:${b.lane_id}`:b.parent_id?b.parent_id:"free");let A=0;for(const[b,k]of h){let $=f.get(b.replace(/^lane:/,""));if($==null){const S=s.get(b);$=S==null?void 0:S.x}$==null&&($=260+A%4*180,A+=1);const z=Math.max(1,Math.ceil(k.length/n.worker.perRow));for(let S=0;S<z;S+=1){const M=k.slice(S*n.worker.perRow,(S+1)*n.worker.perRow),T=(M.length-1)*n.worker.xSpacing,K=$-T/2;M.forEach((U,et)=>{var Q;s.set(U.id,{x:Math.round(K+et*n.worker.xSpacing),y:b==="free"?n.worker.freeBaseY+S*n.worker.ySpacing:(((Q=s.get(b.replace(/^lane:/,"")))==null?void 0:Q.y)??n.lanes.y)+n.worker.laneOffsetY+S*n.worker.ySpacing})})}}return v.forEach((b,k)=>{const $=k%n.keeper.columns,z=Math.floor(k/n.keeper.columns);s.set(b.id,{x:n.keeper.startX+$*n.keeper.colSpacing,y:n.keeper.startY+z*n.keeper.rowSpacing})}),s}function Y$(t,e,n){if(!e||t.signals.length===0)return[];const s=Hd(n);return t.signals.slice(0,6).map((a,o)=>{const l=(-130+o*36)*(Math.PI/180);return{signalNode:a,x:Math.round(e.x+Math.cos(l)*s.signalRadius),y:Math.round(e.y+Math.sin(l)*s.signalRadius)}})}function X$(t,e,n,s){let a=Number.POSITIVE_INFINITY,o=Number.NEGATIVE_INFINITY,l=Number.POSITIVE_INFINITY,c=Number.NEGATIVE_INFINITY;for(const u of t.nodes){const m=e.get(u.id);if(!m)continue;const p=Wd(u,s);u.kind==="room"?(a=Math.min(a,m.x-p.radius),o=Math.max(o,m.x+p.radius),l=Math.min(l,m.y-p.radius),c=Math.max(c,m.y+p.radius)):(a=Math.min(a,m.x-p.width/2),o=Math.max(o,m.x+p.width/2),l=Math.min(l,m.y-p.height/2),c=Math.max(c,m.y+p.height/2))}for(const u of n)a=Math.min(a,u.x-20),o=Math.max(o,u.x+20),l=Math.min(l,u.y-20),c=Math.max(c,u.y+20);return!Number.isFinite(a)||!Number.isFinite(o)||!Number.isFinite(l)||!Number.isFinite(c)?{minX:0,minY:0,maxX:En.width,maxY:En.height,width:En.width,height:En.height}:{minX:a,minY:l,maxX:o,maxY:c,width:Math.max(1,o-a),height:Math.max(1,c-l)}}function Ll(t,e,n){const s=n==="compact"?48:72,a=Math.max(360,e.width-s*2),o=Math.max(280,e.height-s*2),l=oa(Math.min(a/Math.max(t.width,1),o/Math.max(t.height,1)),Bd,Ud),c=t.minX+t.width/2,u=t.minY+t.height/2;return{zoom:l,panX:e.width/2-c*l,panY:e.height/2-u*l}}function Q$(t,e){const n=(t.x+e.x)/2,s=e.y>=t.y?32:-32;return`M ${t.x} ${t.y} C ${n} ${t.y+s}, ${n} ${e.y-s}, ${e.x} ${e.y}`}function zl(t,e,n){if(t==="command"){if(e){Kt(e),it("command",{...As(e),...n});return}it("command",n);return}if(t==="intervene"){it("intervene",n);return}it("command",n)}function Z$({signalNodes:t,roomPoint:e,onSelect:n}){return!e||t.length===0?null:i`
    ${t.map(({signalNode:s,x:a,y:o})=>i`
      <g
        key=${s.id}
        data-orchestra-signal="true"
        class=${`orchestra-signal-node ${E(s.tone)}`}
        onClick=${()=>n(s.id)}
      >
        <title>${s.label}${s.detail?` — ${s.detail}`:""}</title>
        <line x1=${e.x} y1=${e.y} x2=${a} y2=${o} class="orchestra-signal-link" />
        <circle cx=${a} cy=${o} r="16" class="orchestra-signal-dot" />
        <text x=${a} y=${o+4} text-anchor="middle" class="orchestra-signal-glyph">!</text>
      </g>
    `)}
  `}function th({edges:t,positions:e,selectedId:n}){return i`
    ${t.map(s=>{const a=e.get(s.source),o=e.get(s.target);if(!a||!o)return null;const l=n!=null&&(s.source===n||s.target===n);return i`
        <path
          key=${s.id}
          d=${Q$(a,o)}
          class=${`orchestra-edge ${E(s.tone)} ${s.animated?"animated":""} ${l?"active":""}`}
        />
      `})}
  `}function eh({orchestra:t,positions:e,density:n,selectedId:s,onSelect:a}){var l;const o=((l=t.focus)==null?void 0:l.target_kind)==="node"?t.focus.target_id:null;return i`
    ${t.nodes.map(c=>{const u=e.get(c.id);if(!u)return null;const m=Wd(c,n),p=c.id===s,v=c.id===o,f=c.visual_class??c.kind,h=W$(c,n),A=G$(c,n),b=J$(c,n);if(c.kind==="room")return i`
          <g
            key=${c.id}
            data-orchestra-node="true"
            class=${`orchestra-node room ${E(c.tone)} ${p?"selected":""} ${v?"focused":""}`}
            onClick=${()=>a(c.id)}
          >
            <title>${c.label}</title>
            <circle cx=${u.x} cy=${u.y} r=${m.radius} class="orchestra-room-ring outer" />
            <circle cx=${u.x} cy=${u.y} r=${m.radius-16} class="orchestra-room-ring inner" />
            <text x=${u.x} y=${u.y-10} text-anchor="middle" class="orchestra-room-glyph">${c.glyph??"◎"}</text>
            <text x=${u.x} y=${u.y+22} text-anchor="middle" class="orchestra-room-label">${h}</text>
          </g>
        `;const k=u.x-m.width/2,$=u.y-m.height/2;return i`
        <g
          key=${c.id}
          data-orchestra-node="true"
          class=${`orchestra-node ${f} ${E(c.tone)} ${p?"selected":""} ${v?"focused":""}`}
          onClick=${()=>a(c.id)}
        >
          <title>${c.label}${c.subtitle?` — ${c.subtitle}`:""}${c.status?` (${c.status})`:""}</title>
          <rect x=${k} y=${$} width=${m.width} height=${m.height} rx=${m.radius} class="orchestra-node-body" />
          <text x=${k+16} y=${$+24} class="orchestra-node-glyph">${c.glyph??"•"}</text>
          <text x=${k+38} y=${$+24} class="orchestra-node-label">${h}</text>
          ${A?i`<text x=${k+38} y=${$+42} class="orchestra-node-subtitle">${A}</text>`:null}
          ${b?i`<text x=${k+m.width-10} y=${$+18} text-anchor="end" class="orchestra-node-status">${b}</text>`:null}
        </g>
      `})}
  `}function Gd(t){var s,a;const e=Ae.value;if(e){const o=t.nodes.find(c=>c.id===e);if(o)return{type:"node",value:o};const l=t.signals.find(c=>c.id===e);if(l)return{type:"signal",value:l}}if(((s=t.focus)==null?void 0:s.target_kind)==="node"){const o=t.nodes.find(l=>{var c;return l.id===((c=t.focus)==null?void 0:c.target_id)});if(o)return{type:"node",value:o}}if(((a=t.focus)==null?void 0:a.target_kind)==="signal"){const o=t.signals.find(l=>{var c;return l.id===((c=t.focus)==null?void 0:c.target_id)});if(o)return{type:"signal",value:o}}const n=t.nodes[0];return n?{type:"node",value:n}:null}function nh({orchestra:t}){const e=Gd(t);if(!e)return i`<aside class="orchestra-drawer card"><div class="empty-state">선택 가능한 대상이 아직 없습니다.</div></aside>`;if(e.type==="signal"){const o=e.value;return i`
      <aside class="orchestra-drawer card ${E(o.tone)}">
        <div class="card-title-row">
          <div class="card-title">${o.label}</div>
          <span class="command-chip ${E(o.tone)}">${Ml(o.kind)}</span>
        </div>
        <p>${o.detail??"세부 설명이 없습니다."}</p>
        ${o.suggested_surface?i`
              <div class="command-action-row">
                <button
                  class="control-btn"
                  onClick=${()=>zl("command",o.suggested_surface,o.suggested_params??{})}
                >
                  추천 화면 열기
                </button>
              </div>
            `:null}
      </aside>
    `}const n=e.value,s=t.signals.filter(o=>o.source_id===n.id||o.target_id===n.id),a=t.edges.filter(o=>o.source===n.id||o.target===n.id);return i`
    <aside class="orchestra-drawer card ${E(n.tone)}">
      <div class="card-title-row">
        <div class="card-title">${n.label}</div>
        <span class="command-chip ${E(n.tone)}">${Ml(n.kind)}</span>
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
          ${s.map(o=>i`<span class="command-chip ${E(o.tone)}">${o.label}</span>`)}
        </div>
      `:null}
      <div class="command-card-sub">연결 ${a.length}개 · 근거 ${n.provenance}</div>
      ${n.link_tab&&(n.link_surface||Object.keys(n.link_params??{}).length>0)?i`
            <div class="command-action-row">
              <button
                class="control-btn"
                onClick=${()=>zl(n.link_tab??"command",n.link_surface,n.link_params??{})}
              >
                이 화면 열기
              </button>
            </div>
          `:null}
    </aside>
  `}function sh(){var et,Q,tt,W;const t=Xo.value,e=Pn(null),n=Pn(null),s=Pn(""),[a,o]=vn(En);if(nt(()=>{const I=e.current;if(!I)return;const x=()=>{const G=I.getBoundingClientRect();G.width<=0||G.height<=0||o({width:Math.max(640,Math.round(G.width)),height:Math.max(480,Math.round(G.height))})};if(x(),typeof ResizeObserver>"u")return window.addEventListener("resize",x),()=>window.removeEventListener("resize",x);const L=new ResizeObserver(()=>x());return L.observe(I),()=>L.disconnect()},[]),go.value&&!t)return i`<section class="card command-section"><div class="empty-state">오케스트라 맵 불러오는 중…</div></section>`;if(za.value)return i`<section class="card command-section"><div class="empty-state error">${za.value}</div></section>`;if(!t)return i`<section class="card command-section"><div class="empty-state">오케스트라 맵 데이터가 아직 없습니다.</div></section>`;const l=ws.value,c=V$(t,l),u=t.nodes.find(I=>I.kind==="room")??null,m=u?c.get(u.id)??null:null,p=Y$(t,m,l),v=X$(t,c,p,l),f=Gd(t),h=(f==null?void 0:f.value.id)??null,A=`${l}:${a.width}x${a.height}:${t.nodes.length}:${t.edges.length}:${t.signals.length}`,b=(I,x)=>{re.value=I,Os.value=x},k=()=>{b(Ll(v,a,l),!1)},$=()=>{if(Ae.value=null,l!=="compact"){ws.value="compact",Os.value=!1;return}k()};nt(()=>{h&&!t.nodes.some(I=>I.id===h)&&!t.signals.some(I=>I.id===h)&&(Ae.value=null)},[A,h,t]),nt(()=>{(!Os.value||s.current!==A)&&(b(Ll(v,a,l),!1),s.current=A)},[A]);const z=re.value,S=(I,x,L)=>{const G=re.value.zoom,yt=oa(G*L,Bd,Ud);if(Math.abs(yt-G)<.001)return;const ie=(I-re.value.panX)/G,H=(x-re.value.panY)/G;b({zoom:yt,panX:I-ie*yt,panY:x-H*yt},!0)},M=I=>{I.preventDefault();const x=e.current;if(!x)return;const L=x.getBoundingClientRect(),G=oa(I.clientX-L.left,0,L.width),yt=oa(I.clientY-L.top,0,L.height);S(G,yt,I.deltaY<0?1.1:.92)},T=I=>{var G;const x=I.target;if(!(x instanceof Element)||!x.closest('[data-orchestra-background="true"]'))return;const L=I.currentTarget;L&&(n.current={pointerId:I.pointerId,startX:I.clientX,startY:I.clientY,panX:re.value.panX,panY:re.value.panY},Si.value=!0,Os.value=!0,(G=L.setPointerCapture)==null||G.call(L,I.pointerId))},K=I=>{const x=n.current;!x||x.pointerId!==I.pointerId||b({zoom:re.value.zoom,panX:x.panX+(I.clientX-x.startX),panY:x.panY+(I.clientY-x.startY)},!0)},U=I=>{var L;if(!n.current)return;const x=I==null?void 0:I.currentTarget;x&&I&&((L=x.releasePointerCapture)==null||L.call(x,I.pointerId)),n.current=null,Si.value=!1};return i`
    <section class="card command-section orchestra-surface">
      <div class="card-title-row">
        <div class="card-title">오케스트라 맵</div>
        <${D} panelId="command.orchestra" compact=${!0} />
      </div>
      <p class="command-card-sub">
        룸 전체를 한 장의 작전판으로 읽는 시각화입니다. 확대/이동으로 밀집 구간을 읽고, 노드를 눌러 상세 신호와 연결 대상을 확인합니다.
      </p>

      <div class="orchestra-toolbar">
        <div class="orchestra-toolbar-group">
          <button class="control-btn ghost" onClick=${k}>맞춤 보기</button>
          <button class="control-btn ghost" onClick=${$}>초기화</button>
        </div>
        <div class="orchestra-toolbar-group">
          <button
            class="control-btn ghost"
            onClick=${()=>S(a.width/2,a.height/2,1.12)}
          >
            확대
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>S(a.width/2,a.height/2,.9)}
          >
            축소
          </button>
          <span class="command-chip">${Math.round(z.zoom*100)}%</span>
        </div>
        <div class="orchestra-toolbar-group">
          <button
            class=${`control-btn ${l==="balanced"?"is-active":"ghost"}`}
            onClick=${()=>{ws.value="balanced",Ae.value=h}}
          >
            균형
          </button>
          <button
            class=${`control-btn ${l==="compact"?"is-active":"ghost"}`}
            onClick=${()=>{ws.value="compact",Ae.value=h}}
          >
            집약
          </button>
          <span class="command-chip">${U$(l)}</span>
        </div>
      </div>

      <div class="orchestra-shell">
        <div
          ref=${e}
          class="orchestra-canvas-wrap"
          onWheel=${M}
          onPointerDown=${T}
          onPointerMove=${K}
          onPointerUp=${U}
          onPointerCancel=${U}
          onPointerLeave=${()=>U()}
        >
          <svg
            class=${`orchestra-canvas ${Si.value?"is-dragging":""}`}
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
            <g transform=${`translate(${z.panX} ${z.panY}) scale(${z.zoom})`}>
              <${th} edges=${t.edges} positions=${c} selectedId=${h} />
              <${Z$} signalNodes=${p} roomPoint=${m} onSelect=${I=>{Ae.value=I}} />
              <${eh}
                orchestra=${t}
                positions=${c}
                density=${l}
                selectedId=${h}
                onSelect=${I=>{Ae.value=I}}
              />
            </g>
          </svg>
          <div class="orchestra-summary-strip">
            <span class="command-chip">세션 ${((et=t.summary)==null?void 0:et.session_count)??0}</span>
            <span class="command-chip">워커 ${((Q=t.summary)==null?void 0:Q.worker_count)??0}</span>
            <span class="command-chip">키퍼 ${((tt=t.summary)==null?void 0:tt.keeper_count)??0}</span>
            <span class="command-chip ${E(t.signals.some(I=>I.tone==="bad")?"bad":t.signals.length>0?"warn":"ok")}">
              신호 ${((W=t.summary)==null?void 0:W.signal_count)??t.signals.length}
            </span>
            <span class="command-chip">갱신 ${Y(t.generated_at)}</span>
          </div>
        </div>

        <${nh} orchestra=${t} />
      </div>
    </section>
  `}const Jd="masc_dashboard_agent_name";function ah(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Jd))==null?void 0:s.trim())||"dashboard"}const ii=g(ah()),pn=g(""),Da=g("운영 점검"),mn=g(""),ss=g(""),as=g("2"),gn=g(""),St=g("note"),is=g(""),os=g(""),rs=g(""),ls=g("2"),cs=g(""),qa=g("운영자 중지 요청"),ko=g(""),ih=g(""),qs=g(null);function oh(t){const e=t.trim()||"dashboard";ii.value=e,localStorage.setItem(Jd,e)}function Fa(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function mr(t){switch((t??"").trim().toLowerCase()){case"judgment":return"상주 판단";case"fallback":return"보조 읽기 모델";default:return(t==null?void 0:t.trim())||"안내"}}function Ka(t){switch((t??"").trim().toLowerCase()){case"judgment":return"ok";case"fallback":return"warn";default:return"warn"}}function oi(t){return t!=null&&t.enabled?t.refreshing?"갱신 중":t.judge_online?"온라인":t.last_error?"오류":"대기":"꺼짐"}function Vd(t){return t!=null&&t.enabled?t.judge_online?"ok":t.refreshing?"warn":"bad":"warn"}function _r(t){return t!=null&&t.fresh_until?t.fresh_until:"갱신 기준 없음"}function El(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function $n(t){return typeof t=="string"?t.trim().toLowerCase():""}function rh(t){var s;const e=$n(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=$n((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function Ci(t){const e=$n(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function Pl(t){return t.some(e=>$n(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function lh(t){return t.target_type==="team_session"}function ch(t){return t.target_type==="keeper"}function we(t){switch(t){case"broadcast":return"방송";case"room_pause":return"방 일시정지";case"room_resume":return"방 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"team_worker_spawn_batch":return"세션 작업자 교체";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"키퍼 메시지";case"keeper_msg":return"키퍼 메시지";case"swarm_run_continue":return"스웜 실행 계속";case"swarm_run_rerun":return"스웜 실행 재실행";case"swarm_run_abandon":return"스웜 실행 포기";default:return(t==null?void 0:t.trim())||"액션"}}function _n(t){switch(t){case"room":return"방";case"team_session":return"세션";case"keeper":return"키퍼";case"swarm_run":return"스웜 실행";default:return(t==null?void 0:t.trim())||"대상"}}function tn(t){switch($n(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Ba(t){return t?"확인 후 실행":"즉시 실행"}function dh(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"worker_spawn_batch":return"작업자 교체";default:return t}}function ft(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function uh(t){return!t||typeof t!="object"||Array.isArray(t)?null:t}function ph(t){if(!t)return"";const e=t.spawn_batch;return Fa(e!==void 0?e:t)}function Yd(t){const e=uh(t.payload);if(t.target_type==="room"){if(t.action_type==="broadcast"){pn.value=ft(e,"message")??t.summary;return}if(t.action_type==="task_inject"){mn.value=ft(e,"title")??"운영자 주입 작업",ss.value=ft(e,"description")??t.summary,as.value=ft(e,"priority")??as.value;return}t.action_type==="room_pause"&&(Da.value=ft(e,"reason")??t.summary);return}if(t.target_type==="team_session"){if(t.target_id&&(gn.value=t.target_id),t.action_type==="team_stop"){qa.value=ft(e,"reason")??t.summary;return}St.value=t.action_type==="team_worker_spawn_batch"?"worker_spawn_batch":t.action_type==="team_task_inject"?"task":t.action_type==="team_broadcast"?"broadcast":"note";const n=ft(e,"message");if(n&&(is.value=n),St.value==="worker_spawn_batch"){cs.value=ph(e);return}St.value==="task"&&(os.value=ft(e,"task_title")??ft(e,"title")??"운영자 주입 작업",rs.value=ft(e,"task_description")??ft(e,"description")??t.summary,ls.value=ft(e,"task_priority")??ft(e,"priority")??ls.value);return}t.target_type==="keeper"&&(t.target_id&&(ko.value=t.target_id),ih.value=ft(e,"message")??t.summary)}function mh(t){Yd({action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.suggested_payload,summary:t.summary})}function _h(t){Yd({action_type:t.action_type,target_type:t.target_type,target_id:t.target_id??null,payload:t.suggested_payload,summary:t.reason}),j("추천 액션 payload를 폼에 채웠습니다","success")}function vh(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function qe(t){const e=ii.value.trim()||"dashboard";try{const n=await Gc({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?j("확인 대기열에 올렸습니다","warning"):j(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return j(s,"error"),null}}async function Nl(){const t=pn.value.trim();if(!t)return;await qe({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(pn.value="")}async function fh(){await qe({action_type:"room_pause",target_type:"room",payload:{reason:Da.value.trim()||"운영 점검"},successMessage:"방 일시정지를 요청했습니다"})}async function Xd(){await qe({action_type:"room_resume",target_type:"room",payload:{},successMessage:"방 재개를 요청했습니다"})}async function gh(){const t=mn.value.trim();if(!t)return;await qe({action_type:"task_inject",target_type:"room",payload:{title:t,description:ss.value.trim()||"개입 화면에서 주입",priority:Number.parseInt(as.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(mn.value="",ss.value="")}async function $h(){var l;const t=At.value,e=gn.value||((l=t==null?void 0:t.sessions[0])==null?void 0:l.session_id)||"";if(!e){j("먼저 세션을 고르세요","warning");return}const n={};if(St.value==="worker_spawn_batch"){const c=cs.value.trim();if(!c){j("spawn_batch JSON을 먼저 채우세요","warning");return}try{const m=JSON.parse(c);if(Array.isArray(m))n.spawn_batch=m;else if(m&&typeof m=="object"&&Array.isArray(m.spawn_batch))n.spawn_batch=m.spawn_batch;else{j("spawn_batch는 배열 또는 { spawn_batch: [...] } 형태여야 합니다","warning");return}}catch(m){const p=m instanceof Error?m.message:"spawn_batch JSON 파싱에 실패했습니다";j(p,"error");return}await qe({action_type:"team_worker_spawn_batch",target_type:"team_session",target_id:e,payload:n,successMessage:"작업자 교체 요청을 적용했습니다"})&&(cs.value="");return}const s=is.value.trim();s&&(n.message=s);let a="team_note";St.value==="broadcast"?a="team_broadcast":St.value==="task"&&(a="team_task_inject"),St.value==="task"&&(n.task_title=os.value.trim()||"운영자 주입 작업",n.task_description=rs.value.trim()||"개입 화면에서 주입",n.task_priority=Number.parseInt(ls.value,10)||2),await qe({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(is.value="",St.value==="task"&&(os.value="",rs.value=""))}async function hh(){var n;const t=At.value,e=gn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){j("먼저 세션을 고르세요","warning");return}await qe({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:qa.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function jl(t,e="confirm"){const n=ii.value.trim()||"dashboard";try{await Jc(n,t,e),j(e==="deny"?"승인 대기를 거부했습니다":"확인 실행을 완료했습니다","success")}catch(s){const a=s instanceof Error?s.message:e==="deny"?"승인 대기 거부에 실패했습니다":"확인 실행에 실패했습니다";j(a,"error")}}function Qd(t){switch(t){case"explicit":return"실제 관리 단위";case"hybrid":return"관리 단위 + 자동 보강";case"auto":return"자동 투영";default:return"출처 미상"}}function Zd(t){switch(t){case"explicit":return"ok";case"hybrid":return"warn";case"auto":return"warn";default:return"warn"}}function yh(t){switch(t){case"explicit":return"지금 보이는 유닛은 실제로 정의된 지휘면 관리 단위입니다.";case"hybrid":return"일부는 실제 관리 단위이고, 비어 있는 부분은 실시간 에이전트 편성을 보고 자동 보강한 구조입니다.";case"auto":return"이 화면은 실시간 에이전트 편성을 지휘면 모양으로 자동 투영한 것입니다. 실제 명령 체계와 1:1로 같다고 보면 안 됩니다.";default:return"이 화면은 관리 토폴로지와 실효 토폴로지가 섞여 있을 수 있습니다."}}function bh(t){const e=t.unit.source??"unknown";return e==="explicit"?t.active_operation_count&&t.active_operation_count>0?"실제 관리 단위이며 연결된 작전이 있습니다.":"실제 관리 단위이지만 현재 연결된 작전은 없습니다.":e==="hybrid"?t.active_operation_count&&t.active_operation_count>0?"관리 단위를 기반으로 자동 보강된 구조이며 일부 작전이 연결돼 있습니다.":"관리 단위를 기반으로 자동 보강된 구조이며 현재 실행 연결은 약합니다.":t.active_operation_count&&t.active_operation_count>0?"자동 생성된 구조이지만 이 노드에 연결된 작전 흔적은 있습니다.":"자동 생성된 구조이며 현재 실행 연결은 없습니다."}function tu({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,o=t.unit.policy,l=t.unit.source??"unknown",c=a>0?`${a}개 작전 연결`:"실행 연결 없음";return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${i$(t.unit.kind)}</span>
            <span class="command-chip ${E(t.health)}">${t.health??"ok"}</span>
            <span class="command-chip ${Zd(l)}">${Qd(l)}</span>
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
          <div class="command-card-sub">${bh(t)}</div>
          ${t.reasons&&t.reasons.length>0?i`<div class="command-tag-row">
                ${t.reasons.map(u=>i`<span class="command-tag warn">${u}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?i`<div class="command-tree-children">
            ${t.children.map(u=>i`<${tu} node=${u} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function kh({alert:t}){return i`
    <article class="command-alert ${E(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${E(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"범위"}:${t.scope_id??"정보 없음"}</span>
        <span>${Y(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function vr({event:t}){return i`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${Y(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${ns(t.detail)}</pre>
    </article>
  `}function xh(){const t=Jt.value,e=t==null?void 0:t.topology,n=e==null?void 0:e.source,s=e==null?void 0:e.summary,a=(s==null?void 0:s.managed_unit_count)??0,o=(s==null?void 0:s.active_operation_count)??0;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${D} panelId="command.topology" compact=${!0} />
      </div>
      ${t?i`
            <div class="command-topology-explainer">
              <div class="command-tree-title-row">
                <span class="command-chip ${Zd(n)}">${Qd(n)}</span>
                <span class="command-chip">관리 유닛 ${a}</span>
                <span class="command-chip ${o>0?"ok":"warn"}">활성 작전 ${o}</span>
              </div>
              <p>${yh(n)}</p>
            </div>
          `:null}
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(l=>i`<${tu} node=${l} />`)}`:i`<div class="empty-state">지금은 실시간 에이전트나 관리 유닛 기준으로 그릴 지휘 계층이 없습니다.</div>`}
    </section>
  `}function Sh(){const t=Jt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${D} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${kh} alert=${e} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 지휘면 경보는 없습니다.</div>`}
    </section>
  `}function Ch(){const t=Jt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${D} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${vr} event=${e} />`)}
          </div>`:i`<div class="empty-state">최근 트레이스 이벤트가 없습니다.</div>`}
    </section>
  `}function Ah(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Th(t,e){return(e==null?void 0:e.status)==="abandoned"||(t==null?void 0:t.recommended_kind)==="continue"?"warn":(t==null?void 0:t.recommended_kind)==="rerun"?"bad":"ok"}function Ih(t){switch(t){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(t==null?void 0:t.trim())||"결정"}}function eu({swarm:t}){var v,f;const e=t.run_id,n=t.resolution_recommendation,s=t.run_resolution;if(!e||!n&&!s)return null;const a=qd()??"dashboard",o=((v=At.value)==null?void 0:v.pending_confirms.find(h=>h.target_type==="swarm_run"&&h.target_id===e))??null,l=Th(n,s),c=((f=t.operation)==null?void 0:f.operation_id)??t.operation_id??void 0,u={run_id:e};c&&(u.operation_id=c),n!=null&&n.reason&&(u.reason=n.reason);const m=async h=>{await Gc({actor:a,action_type:h,target_type:"swarm_run",target_id:e,payload:u})},p=async h=>{o&&await Jc(a,o.confirm_token,h)};return i`
    <article class="command-guide-card ${E(l)}">
      <div class="command-guide-head">
        <strong>Run Resolution</strong>
        <span class="command-chip ${E(l)}">
          ${Ih((s==null?void 0:s.status)??(n==null?void 0:n.recommended_kind)??null)}
        </span>
      </div>
      <p>
        ${(s==null?void 0:s.status)==="abandoned"?`이 run은 ${s.decided_by}가 ${Y(s.decided_at)}에 soft abandon 처리했습니다. ${s.reason}`:(n==null?void 0:n.reason)??"이 run에 대한 별도 resolution recommendation은 아직 없습니다."}
      </p>
      <div class="command-card-grid">
        <span>Run</span><span>${e}</span>
        <span>Provenance</span><span>${(n==null?void 0:n.provenance)??"recorded"}</span>
        <span>Engine</span><span>${(n==null?void 0:n.decision_engine)??"operator_record"}</span>
        <span>Authoritative</span><span>${n!=null&&n.authoritative?"yes":"no"}</span>
      </div>
      ${n!=null&&n.evidence?i`
            <div class="command-tag-row">
              <span class="command-tag">joined ${n.evidence.joined_workers??0}</span>
              <span class="command-tag">trace ${n.evidence.trace_events??0}</span>
              <span class="command-tag">message ${n.evidence.message_events??0}</span>
              ${n.evidence.runtime_blocker?i`<span class="command-tag ${E("bad")}">${n.evidence.runtime_blocker}</span>`:null}
            </div>
          `:null}
      ${o?i`
            <div class="command-guide-card warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip warn">${o.confirm_token}</span>
              </div>
              ${o.preview?i`<pre class="command-trace-detail">${Ah(o.preview)}</pre>`:null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${()=>{p("confirm")}} disabled=${Z.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${()=>{p("deny")}} disabled=${Z.value}>취소</button>
              </div>
            </div>
          `:n?i`
              <div class="command-action-row">
                ${n.continue_available?i`<button class="control-btn ghost" onClick=${()=>{m("swarm_run_continue")}} disabled=${Z.value}>Continue</button>`:null}
                ${n.rerun_available?i`<button class="control-btn" onClick=${()=>{m("swarm_run_rerun")}} disabled=${Z.value}>Rerun</button>`:null}
                ${n.abandon_available?i`<button class="control-btn ghost" onClick=${()=>{m("swarm_run_abandon")}} disabled=${Z.value}>Abandon</button>`:null}
              </div>
            `:null}
    </article>
  `}function nu(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function su({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const o=a.motion_state;o in e?e[o]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return i`
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
  `}function Rh({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function Mh({lane:t}){const e=t.counts??{},n=nu(t),s=e.workers??0,a=e.operations??0,o=e.detachments??0,l=a+o,c=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return i`
    <article class="swarm-lane-strip ${E(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${E(n)}">${t.phase}</span>
          <span class="command-chip ${E(n)}">${t.motion_state}</span>
          <span class="command-chip">${Y(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${E(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${Rh} total=${s} />
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
              ${t.hard_flags.map(u=>i`<span class="command-chip ${E(u.severity)}">${u.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function au({lanes:t}){const e=t.slice(0,4);return e.length===0?null:i`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=nu(n),a=n.counts.workers??0,o=n.counts.operations??0,l=n.counts.detachments??0;return i`
          <article class="swarm-story-card ${E(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${E(s)}">${n.motion_state}</span>
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
  `}function Lh({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${E(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?i`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function zh({gap:t}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${E(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function Eh({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${E(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${E(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?i`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${Y(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?i`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?i`<p>${t.missing_reason}</p>`:null}
          `:i`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function Ph(){const t=Ts(),e=ks(O.value),n=l$(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,o=(s==null?void 0:s.lanes.filter(v=>v.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],u=s==null?void 0:s.overview,m=s==null?void 0:s.recommended_next_action,p=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${D} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${au} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(u==null?void 0:u.active_lanes)??0}</strong><small>${(u==null?void 0:u.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(u==null?void 0:u.stalled_lanes)??0}</strong><small>${(u==null?void 0:u.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${Y(u==null?void 0:u.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${Y(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${su} lanes=${o} />`:null}

            <div class="command-swarm-layout ${p?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(v=>i`<${Mh} lane=${v} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight ${n==="recommendation"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(m==null?void 0:m.lane_id)??"전체"}</span>
                  </div>
                  <p>${(m==null?void 0:m.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${Eh} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${E(l.some(v=>v.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?i`<div class="swarm-event-rail">${l.slice(0,4).map(v=>i`<${zh} gap=${v} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?i`<div class="swarm-event-rail">${c.map(v=>i`<${Lh} event=${v} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Nh({item:t}){return i`
    <article class="command-guide-card ${E(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${E(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function iu({blocker:t}){return i`
    <article class="command-alert ${E(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${E(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function jh({worker:t}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${E(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${t.last_message?i`<div class="command-card-foot">${Y(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function wh(){var u,m,p,v,f,h,A,b,k,$,z,S,M,T,K,U,et,Q,tt,W,I;const t=Be.value,e=Kd(),n=cr(),s=(u=t==null?void 0:t.provider)!=null&&u.runtime_blocker?"blocked":(m=t==null?void 0:t.provider)!=null&&m.provider_reachable?"ready":"check",a=((p=t==null?void 0:t.provider)==null?void 0:p.actual_slots)??((v=t==null?void 0:t.provider)==null?void 0:v.total_slots)??0,o=((f=t==null?void 0:t.provider)==null?void 0:f.expected_slots)??"n/a",l=((h=t==null?void 0:t.provider)==null?void 0:h.actual_ctx)??((A=t==null?void 0:t.provider)==null?void 0:A.ctx_per_slot)??0,c=((b=t==null?void 0:t.provider)==null?void 0:b.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${Ph} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${Ma.value?i`<div class="empty-state">Loading swarm live state…</div>`:La.value?i`<div class="empty-state error">${La.value}</div>`:t?i`
                    <div class="command-tag-row">
                      <span class="command-tag">experimental</span>
                      <span class="command-tag">derived read-model</span>
                      <span class="command-tag ${t.run_resolution||t.resolution_recommendation?"warn":"ok"}">
                        ${t.run_resolution||t.resolution_recommendation?"operator resolution aware":"no resolution advice"}
                      </span>
                    </div>
                    <div class="command-card-sub">
                      이 화면은 swarm-live의 사회 truth 자체가 아니라, 실험적 오케스트레이션을 읽기 위한 파생 관찰면입니다.
                    </div>
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((k=t.summary)==null?void 0:k.joined_workers)??0}/${(($=t.summary)==null?void 0:$.expected_workers)??0}</strong><small>${((z=t.summary)==null?void 0:z.live_workers)??0}개 가동 · ${((S=t.summary)==null?void 0:S.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${o} · ctx ${l}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(M=t.summary)!=null&&M.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((T=t.provider)==null?void 0:T.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(K=t.summary)!=null&&K.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((U=t.operation)==null?void 0:U.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((et=t.squad)==null?void 0:et.label)??"없음"}</span>
                      <span>실행체</span><span>${((Q=t.detachment)==null?void 0:Q.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((tt=t.summary)==null?void 0:tt.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((W=t.summary)==null?void 0:W.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((I=t.provider)==null?void 0:I.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?i`<div class="command-tag-row">
                          ${t.truth_notes.map(x=>i`<span class="command-tag">${x}</span>`)}
                        </div>`:null}
                    <${eu} swarm=${t} />
                  `:i`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?i`<div class="command-card-stack">
                ${t.checklist.map(x=>i`<${Nh} item=${x} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?i`<div class="command-card-stack">
                ${t.workers.map(x=>i`<${jh} worker=${x} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t!=null&&t.provider?i`
                <div class="command-card-grid">
                  <span>Provider</span><span>${t.provider.provider_base_url??"n/a"}</span>
                  <span>Provider Reachable</span><span>${t.provider.provider_reachable==null?"n/a":t.provider.provider_reachable?"yes":"no"}</span>
                  <span>Requested Model</span><span>${t.provider.provider_model_id??"n/a"}</span>
                  <span>Actual Model</span><span>${t.provider.actual_model_id??"n/a"}</span>
                  <span>Slot URL</span><span>${t.provider.slot_url??"n/a"}</span>
                  <span>Expected Slots</span><span>${t.provider.expected_slots??"n/a"}</span>
                  <span>Actual Slots</span><span>${t.provider.actual_slots??t.provider.total_slots??0}</span>
                  <span>Expected Ctx</span><span>${t.provider.expected_ctx??"n/a"}</span>
                  <span>Actual Ctx</span><span>${t.provider.actual_ctx??t.provider.ctx_per_slot??0}</span>
                  <span>Active Now</span><span>${t.provider.active_slots_now??0}</span>
                  <span>Peak Active</span><span>${t.provider.peak_active_slots??0}</span>
                  <span>Sample Count</span><span>${t.provider.sample_count??0}</span>
                  <span>Last Sample</span><span>${t.provider.last_sample_at?Y(t.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${t.provider.checked_at?Y(t.provider.checked_at):"n/a"}</span>
                </div>
                ${t.provider.detail?i`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?i`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(x=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${x.active_slots} active</strong>
                              <span class="command-chip">${Y(x.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${x.active_slot_ids.join(", ")||"none"}</div>
                          </div>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:i`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?i`<div class="command-card-stack">
                ${t.blockers.map(x=>i`<${iu} blocker=${x} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?i`<div class="command-trace-stack">
                ${t.recent_messages.map(x=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${x.from}</strong>
                        <span class="command-chip">${Y(x.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${x.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${x.content}</pre>
                  </article>
                `)}
              </div>`:i`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${D} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${t.recent_trace_events.map(x=>i`<${vr} event=${x} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function Yt(t,e=260){return t.length<=e?t:`${t.slice(0,e-1)}…`}function en(t){if(!t)return 0;const e=Date.parse(t);return Number.isNaN(e)?0:e}function Oh(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function Dh(t){const e=typeof t.timestamp=="string"?t.timestamp:typeof t.created_at=="string"?t.created_at:typeof t.at=="string"?t.at:null,n=typeof t.title=="string"?t.title:typeof t.kind=="string"?t.kind:typeof t.event=="string"?t.event:"세션 이벤트",s=typeof t.detail=="string"?t.detail:typeof t.summary=="string"?t.summary:ns(t);return{timestamp:e,title:n,detail:Yt(s,220)}}function qh(t){return t==="swarm"?"스웜 실시간":"세션 요약"}function Fh(t){switch(t){case"current":return"현재 과업 일치";case"drift":return"과업 드리프트";case"claim":return"착수 흔적 있음";case"no-claim":return"착수 흔적 없음";case"done":return"완료 흔적 있음";case"no-done":return"완료 흔적 없음";case"final":return"최종 보고 있음";case"no-final":return"최종 보고 없음";case"turn":return"턴 기록 있음";case"silent":return"턴 기록 없음";case"noted":return"노트 기록 있음";default:return t.startsWith("empty:")?`빈 노트 ${t.slice(6)}회`:t.startsWith("turns:")?`턴 ${t.slice(6)}회`:t}}function Kh(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"할당 없음",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}초`:t.heartbeat_fresh?"정상":"정보 없음",detail:[t.bound_task_status??null,t.detachment_member?"분견대 소속":null,t.squad_member?"분대 소속":null].filter(Boolean).join(" · ")||"스웜 실시간 카드",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function Bh(t,e){const n=t.actor??t.spawn_role??`워커-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"워커",a=t.lane_id??t.capsule_mode??t.control_domain??"세션",o=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"세션 레인",heartbeat:t.last_turn_ts_iso?Y(t.last_turn_ts_iso):"정보 없음",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?Sn(t.routing_confidence):null].filter(Boolean).join(" · ")||"세션 요약 카드",markers:o,note:t.routing_reason??null}}function Uh(t){var e;return{key:`agent:${t.name}`,name:t.name,role:t.agent_type??"agent",source:"agent",status:Ft(t.status),tone:E(de(t.status)),task:t.current_task??"대기 중",signal:Y(t.last_seen),detail:[t.model??null,((e=t.capabilities)==null?void 0:e.slice(0,2).join(", "))||null].filter(Boolean).join(" · ")||"글로벌 agent roster",chips:[t.context_ratio!=null?`ctx ${Math.round(t.context_ratio*100)}%`:"ctx n/a",t.status],note:t.personalityHint??null}}function Hh(t){var n,s,a;const e=t.status==="offline"||t.status==="inactive"?"bad":t.status==="active"||t.status==="healthy"?"ok":"warn";return{key:`keeper:${t.name}`,name:t.name,role:t.runtime_class??"keeper",source:"keeper",status:Ft(t.status),tone:e,task:((n=t.active_goal_ids)==null?void 0:n[0])??t.last_proactive_reason??((s=t.agent)==null?void 0:s.current_task)??"standby",signal:t.last_heartbeat?Y(t.last_heartbeat):Oh(t.last_turn_ago_s),detail:[t.autonomy_level??null,t.active_model??t.primary_model??t.model??null,t.keepalive_running?"keepalive on":null].filter(Boolean).join(" · ")||"글로벌 keeper roster",chips:[t.context_ratio!=null?`ctx ${Math.round(t.context_ratio*100)}%`:"ctx n/a",t.latest_tool_call_count!=null?`tools ${t.latest_tool_call_count}`:"tools n/a"],note:((a=t.diagnostic)==null?void 0:a.summary)??t.last_proactive_preview??t.recent_output_preview??null}}function Wh(t){return{key:`resident:${t.keeper_name??"judge"}`,name:t.keeper_name??"resident-judge",role:"resident judge",source:"resident",status:oi(t),tone:Vd(t),task:t.judge_online?"live guidance":"standby",signal:t.generated_at?Y(t.generated_at):"정보 없음",detail:[t.model_used??null,t.last_error?"error":null].filter(Boolean).join(" · ")||"resident runtime",chips:[t.enabled?"enabled":"disabled",t.judge_online?"online":"offline"],note:t.last_error??null}}function Gh(t){return E(t.severity)}function Jh({swarmMessages:t,traceEvents:e,chainOverlay:n,linkedAutoresearch:s,selectedSession:a,activeRecommendedActions:o,attentionItems:l}){const c=[];for(const u of t.slice(0,8))c.push({key:`message:${u.seq}`,title:u.from,detail:Yt(u.content,280),meta:`메시지 · seq ${u.seq}`,source:"swarm",tone:"ok",timestamp:u.timestamp,sortTs:en(u.timestamp)});for(const u of e.slice(0,8))c.push({key:`trace:${u.event_id}`,title:u.event_type,detail:Yt(ns(u.detail),280),meta:[u.actor??null,u.source??null].filter(Boolean).join(" · ")||"trace",source:"trace",tone:u.event_type.includes("error")||u.event_type.includes("fail")?"bad":"warn",timestamp:u.timestamp,sortTs:en(u.timestamp)});if(n!=null&&n.history&&c.push({key:`chain:${n.operation.operation_id}:${n.history.event}`,title:`Chain · ${n.history.event}`,detail:Yt(ai(n.history),260),meta:n.history.chain_id??n.operation.operation_id,source:"chain",tone:n.history.event.includes("error")||n.history.event.includes("fail")?"bad":"warn",timestamp:n.history.timestamp,sortTs:en(n.history.timestamp)}),s){const u=[s.last_decision??null,s.target_file?`target ${s.target_file}`:null,s.error??null].filter(Boolean);c.push({key:`autoresearch:${s.loop_id??(a==null?void 0:a.session_id)??"session"}`,title:`Autoresearch · ${s.status??"unknown"}`,detail:Yt(u.join(" · ")||"linked autoresearch context",260),meta:[s.loop_id?`loop ${s.loop_id}`:null,s.current_cycle!=null?`cycle ${s.current_cycle}`:null,s.best_score!=null?`best ${s.best_score}`:null].filter(Boolean).join(" · ")||"linked autoresearch",source:"autoresearch",tone:s.error?"bad":s.status==="running"?"warn":"ok",timestamp:null,sortTs:0})}for(const u of o.slice(0,4))c.push({key:`recommendation:${u.action_type}:${u.target_type}:${u.target_id??"session"}`,title:`${u.action_type} · ${u.target_type}`,detail:Yt(u.reason,240),meta:u.target_id??"operator recommendation",source:"recommendation",tone:Gh(u),timestamp:null,sortTs:0});for(const u of l.slice(0,4))c.push({key:`attention:${u.kind}:${u.target_id??"session"}`,title:`${u.kind} · ${u.target_type}`,detail:Yt(u.summary,240),meta:u.target_id??"attention",source:"attention",tone:E(u.severity),timestamp:null,sortTs:0});for(const[u,m]of((a==null?void 0:a.recent_events)??[]).slice(0,4).entries()){const p=Dh(m);c.push({key:`session:${(a==null?void 0:a.session_id)??"unknown"}:${u}`,title:p.title,detail:p.detail,meta:(a==null?void 0:a.session_id)??"session",source:"session",tone:"warn",timestamp:p.timestamp,sortTs:en(p.timestamp)})}return c.sort((u,m)=>m.sortTs-u.sortTs||u.title.localeCompare(m.title)).slice(0,14)}function Vh({worker:t}){return i`
    <article class="command-card compact warroom-worker-card ${E(de(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${E(de(t.status))}">${Ft(t.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>출처</span><span>${qh(t.source)}</span>
        <span>과업</span><span>${t.task}</span>
        <span>최근 신호</span><span>${t.heartbeat}</span>
        <span>근거</span><span>${t.detail}</span>
      </div>
      <div class="command-tag-row">
        ${t.markers.map(e=>i`<span class="command-tag">${Fh(e)}</span>`)}
      </div>
      ${t.note?i`<div class="command-card-foot">${Yt(t.note,220)}</div>`:null}
    </article>
  `}function wl({item:t}){return i`
    <article class="command-card compact warroom-presence-card ${t.tone}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.source}</div>
        </div>
        <span class="command-chip ${t.tone}">${t.status}</span>
      </div>
      <div class="command-card-grid">
        <span>현재 과업</span><span>${t.task}</span>
        <span>최근 신호</span><span>${t.signal}</span>
        <span>근거</span><span>${t.detail}</span>
      </div>
      <div class="command-tag-row">
        ${t.chips.map(e=>i`<span class="command-tag">${e}</span>`)}
      </div>
      ${t.note?i`<div class="command-card-foot">${Yt(t.note,200)}</div>`:null}
    </article>
  `}function Yh({item:t}){return i`
    <article class="command-trace-row warroom-feed-card ${t.tone}">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.title}</strong>
          <span class="command-chip ${t.tone}">${t.timestamp?Y(t.timestamp):t.source}</span>
        </div>
        <div class="command-card-sub">${t.meta}</div>
      </div>
      <div class="warroom-feed-detail">${t.detail}</div>
    </article>
  `}function qt({label:t,surface:e,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){Kt(e),it("command",{...As(e),...n});return}it("intervene")}}
    >
      ${t}
    </button>
  `}function Xh({chainOverlay:t,linkedAutoresearch:e}){var n,s,a,o;return!t&&!e?i`<div class="command-guide-card"><p>이 세션에 붙은 chain/autoresearch 오버레이가 아직 없습니다.</p></div>`:i`
    <div class="warroom-orchestration-grid">
      ${t?i`
            <article class="command-card warroom-orchestration-card">
              <div class="command-card-head">
                <div>
                  <strong>Chain Orchestration</strong>
                  <div class="command-card-sub">${t.operation.operation_id}</div>
                </div>
                <span class="command-chip ${E(de(t.operation.status))}">${Ft(t.operation.status)}</span>
              </div>
              <div class="command-card-grid">
                <span>Chain</span><span>${((n=t.runtime)==null?void 0:n.chain_id)??((s=t.preview_run)==null?void 0:s.chain_id)??"n/a"}</span>
                <span>Progress</span><span>${Sn((a=t.runtime)==null?void 0:a.progress)}</span>
                <span>Elapsed</span><span>${Qe((o=t.runtime)==null?void 0:o.elapsed_sec)}</span>
                <span>최근 이벤트</span><span>${ai(t.history)}</span>
              </div>
              <div class="command-action-row">
                <${qt}
                  label="체인 상세"
                  surface="chains"
                  params=${{operation:t.operation.operation_id}}
                />
              </div>
            </article>
          `:null}
      ${e?i`
            <article class="command-card warroom-orchestration-card">
              <div class="command-card-head">
                <div>
                  <strong>Autoresearch Loop</strong>
                  <div class="command-card-sub">${e.loop_id??e.session_id??"linked session"}</div>
                </div>
                <span class="command-chip ${e.error?"bad":e.status==="running"?"warn":"ok"}">${e.status??"unknown"}</span>
              </div>
              <div class="command-card-grid">
                <span>Cycle</span><span>${e.current_cycle??0}</span>
                <span>Best score</span><span>${e.best_score??"n/a"}</span>
                <span>Target</span><span>${e.target_file??"n/a"}</span>
                <span>Last decision</span><span>${e.last_decision??e.error??"기록 없음"}</span>
              </div>
              <div class="command-action-row">
                <${qt} label="세션 개입" />
                ${e.operation_id?i`<${qt}
                      label="작전 상세"
                      surface="operations"
                      params=${{operation_id:e.operation_id}}
                    />`:null}
              </div>
            </article>
          `:null}
    </div>
  `}function Qh({wallboard:t=!1}){var kr,xr,Sr,Cr,Ar,Tr,Ir,Rr,Mr,Lr,zr,Er,Pr,Nr,jr,wr,Or,Dr,qr,Fr,Kr,Br,Ur,Hr,Wr,Gr,Jr,Vr,Yr,Xr,Qr,Zr;const e=Ts(),n=Be.value,s=At.value,a=Ht.value,o=v$(),l=n!=null&&n.operation?((kr=bs.value)==null?void 0:kr.operations.find(F=>{var ke;return F.operation.operation_id===((ke=n.operation)==null?void 0:ke.operation_id)}))??null:null,c=(o==null?void 0:o.linked_autoresearch)??null,u=m$(),m=(n==null?void 0:n.workers)??[],p=(a==null?void 0:a.worker_cards)??[],v=u&&m.length>0?m.map(Kh):p.map(Bh),f=Gt.value.filter(F=>F.status==="active"||F.status==="busy"||F.status==="listening"||F.status==="idle"),h=ae.value.filter(F=>F.status!=="offline"||F.keepalive_running||F.last_heartbeat).sort((F,ke)=>en(ke.last_heartbeat)-en(F.last_heartbeat)),A=u,b=((xr=e==null?void 0:e.decisions.summary)==null?void 0:xr.pending)??0,k=ti(s),$=k.items,z=k.total_count,S=k.visible_count,M=k.hidden_count,T=u?(n==null?void 0:n.blockers)??[]:[],K=(a==null?void 0:a.recommended_actions)??[],U=(Sr=a==null?void 0:a.active_recommended_actions)!=null&&Sr.length?a.active_recommended_actions:K,et=a==null?void 0:a.active_summary,Q=(a==null?void 0:a.active_guidance_layer)??"fallback",tt=(a==null?void 0:a.resident_judge_runtime)??(s==null?void 0:s.resident_judge_runtime),W=(a==null?void 0:a.attention_items)??[],I=((Cr=n==null?void 0:n.recent_messages[0])==null?void 0:Cr.timestamp)??null,x=((Ar=n==null?void 0:n.recent_trace_events[0])==null?void 0:Ar.timestamp)??null,L=u?I??x??null:null,G=o==null?void 0:o.summary,yt=(u?(Tr=n==null?void 0:n.summary)==null?void 0:Tr.expected_workers:void 0)??(typeof(G==null?void 0:G.planned_worker_count)=="number"?G.planned_worker_count:void 0)??(a==null?void 0:a.worker_cards.length)??0,ie=(u?(Ir=n==null?void 0:n.summary)==null?void 0:Ir.joined_workers:void 0)??(typeof(G==null?void 0:G.active_agent_count)=="number"?G.active_agent_count:void 0)??v.length,H=T.length>0||b>0||z>0?"warn":A||o?"ok":"warn",vt=u?((Rr=e==null?void 0:e.swarm_status)==null?void 0:Rr.lanes.filter(F=>F.present))??[]:[],be=((Lr=(Mr=e==null?void 0:e.swarm_status)==null?void 0:Mr.narrative)==null?void 0:Lr.lane_id)??((Er=(zr=e==null?void 0:e.swarm_status)==null?void 0:zr.recommended_next_action)==null?void 0:Er.lane_id)??((Pr=vt[0])==null?void 0:Pr.lane_id)??null,rt=be?vt.find(F=>F.lane_id===be)??null:vt[0]??null,Cn=[...tt?[Wh(tt)]:[],...f.slice(0,t?8:5).map(Uh),...h.slice(0,t?8:5).map(Hh)],Is=Cn.filter(F=>F.source==="agent"),Rs=Cn.filter(F=>F.source==="keeper"||F.source==="resident"),Ms=Jh({swarmMessages:(n==null?void 0:n.recent_messages)??[],traceEvents:(n==null?void 0:n.recent_trace_events)??[],chainOverlay:l,linkedAutoresearch:c,selectedSession:o,activeRecommendedActions:U,attentionItems:W}),ci=((Nr=n==null?void 0:n.operation)==null?void 0:Nr.objective)??((wr=(jr=e==null?void 0:e.swarm_status)==null?void 0:jr.narrative)==null?void 0:wr.active_work)??(o==null?void 0:o.session_id)??"가동 중인 워룸",di=[(et==null?void 0:et.summary)??null,((Dr=(Or=e==null?void 0:e.swarm_status)==null?void 0:Or.narrative)==null?void 0:Dr.state)??null,((Fr=(qr=e==null?void 0:e.swarm_status)==null?void 0:qr.narrative)==null?void 0:Fr.active_work)??null,rt?`${rt.label} · ${rt.current_step}`:null].filter(Boolean).join(" · ")||"실제 실행, 메시지, 트레이스, 상주 판단을 한 장에서 읽는 wallboard입니다.",[ui,pi]=vn(typeof document<"u"&&!!document.fullscreenElement);nt(()=>{gt()},[]),nt(()=>{o!=null&&o.session_id&&De(o.session_id)},[o==null?void 0:o.session_id,s,(Kr=n==null?void 0:n.detachment)==null?void 0:Kr.session_id]),nt(()=>{if(!t)return;const F=()=>{pi(!!document.fullscreenElement)};return document.addEventListener("fullscreenchange",F),F(),()=>{document.removeEventListener("fullscreenchange",F)}},[t]);const bu=()=>{var F,ke,tl;if(!(typeof document>"u")){if(document.fullscreenElement){(F=document.exitFullscreen)==null||F.call(document);return}(tl=(ke=document.documentElement).requestFullscreen)==null||tl.call(ke)}},ku=()=>{gt(),Zt(),je(),o!=null&&o.session_id&&De(o.session_id)};return!A&&!o?Ma.value||Yn.value?i`<div class="empty-state">실시간 워룸 불러오는 중…</div>`:i`
      <section class="card command-section command-warroom-empty ${t?"wallboard":""}">
        <div class="card-title-row">
          <div class="card-title">실시간 워룸</div>
          <${D} panelId="command.warroom" compact=${!0} />
        </div>
        <div class="command-warroom-empty-copy">
          <span class="command-hero-kicker">Narrative Playback</span>
          <strong>지금 붙잡을 live swarm 또는 team session이 없습니다</strong>
          <p>chain, autoresearch, worker wallboard는 활성 작전 또는 세션이 생기면 자동으로 붙습니다. 지금은 drill-down surface로 이동하는 편이 맞습니다.</p>
        </div>
        <div class="command-action-row">
          <${qt} label="작전 보기" surface="operations" />
          <${qt} label="스웜 보기" surface="swarm" />
          <${qt} label="체인 보기" surface="chains" />
          <${qt} label="개입 열기" />
        </div>
      </section>
    `:i`
    <div class="command-section-stack ${t?"wallboard":""}">
      <section class="command-warroom-strip ${E(H)} ${t?"wallboard":""}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">${t?"War Room Wallboard":"실시간 워룸"}</span>
            <strong>${ci}</strong>
            <div class="command-card-sub">
              ${u?((Br=n==null?void 0:n.operation)==null?void 0:Br.operation_id)??"작전 정보 없음":"세션 기준값"}
              ${o!=null&&o.session_id?` · 세션 ${o.session_id}`:""}
              ${u&&((Ur=n==null?void 0:n.detachment)!=null&&Ur.detachment_id)?` · 분견대 ${n.detachment.detachment_id}`:""}
              ${rt?` · 대표 레인 ${rt.label}`:""}
            </div>
            <div class="command-warroom-summary">${di}</div>
            ${et!=null&&et.summary?i`<div class="command-warroom-guidance ${Ka(Q)}">
                  <strong>${mr(Q)}</strong>
                  <span>${et.summary}</span>
                </div>`:null}
          </div>
          <div class="command-warroom-hero-actions">
            <button class="control-btn ghost" onClick=${ku}>새로고침</button>
            ${t?i`
                  <button class="control-btn ghost" onClick=${bu}>
                    ${ui?"전체 화면 해제":"전체 화면"}
                  </button>
                  <button
                    class="control-btn ghost"
                    onClick=${()=>{var F;document.fullscreenElement&&((F=document.exitFullscreen)==null||F.call(document)),Kt("warroom"),it("command",As("warroom"))}}
                  >
                    표준 보기
                  </button>
                `:null}
            <${qt}
              label="스웜 상세"
              surface="swarm"
              params=${{...u&&((Hr=n==null?void 0:n.operation)!=null&&Hr.operation_id)?{operation_id:n.operation.operation_id}:{},...u&&(n!=null&&n.run_id)?{run_id:n.run_id}:{}}}
            />
            ${l?i`<${qt}
                  label="체인"
                  surface="chains"
                  params=${{operation:l.operation.operation_id}}
                />`:null}
            <${qt} label="개입" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>워커</span>
            <strong>${ie??0}/${yt??0}</strong>
            <small>${u?((Wr=n==null?void 0:n.summary)==null?void 0:Wr.completed_workers)??0:0} 완료 · ${v.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>런타임</span>
            <strong>${u?(Gr=n==null?void 0:n.provider)!=null&&Gr.runtime_blocker?"막힘":(Jr=n==null?void 0:n.provider)!=null&&Jr.provider_reachable?"준비됨":o?Ft(o.status):"확인 필요":o?Ft(o.status):"확인 필요"}</strong>
            <small>${u?`설정 ${((Vr=n==null?void 0:n.provider)==null?void 0:Vr.configured_capacity)??"n/a"} · 실제 ${((Yr=n==null?void 0:n.provider)==null?void 0:Yr.actual_slots)??((Xr=n==null?void 0:n.provider)==null?void 0:Xr.total_slots)??0} · hot ${((Qr=n==null?void 0:n.summary)==null?void 0:Qr.peak_hot_slots)??((Zr=n==null?void 0:n.provider)==null?void 0:Zr.peak_active_slots)??0}`:`세션 워커 ${(a==null?void 0:a.worker_cards.length)??0}`}</small>
          </div>
          <div class="monitor-stat-card ${E(T.length>0||b>0||z>0?"warn":"ok")}">
            <span>압력</span>
            <strong>${T.length+b+z}</strong>
            <small>막힘 ${T.length} · 승인 ${b} · 확인 ${S}${M>0?`/${z}`:""}</small>
          </div>
          <div class="monitor-stat-card ${E(Ka(Q))}">
            <span>상주 판정기</span>
            <strong>${oi(tt)}</strong>
            <small>${_r(et)}${tt!=null&&tt.model_used?` · ${tt.model_used}`:""}</small>
          </div>
          <div class="monitor-stat-card">
            <span>마지막 신호</span>
            <strong>${Y(L)}</strong>
            <small>${I?"메시지":x?"트레이스":"대기 중"}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid ${t?"wallboard":""}">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            ${vt.length>0?i`
                  <${au} lanes=${vt} />
                  <${su} lanes=${vt} />
                `:o?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${o.session_id}</strong>
                        <span class="command-chip ${E(de(o.status))}">${Ft(o.status)}</span>
                      </div>
                      <p>스웜 실시간 증거는 아직 약합니다. 이 카드는 세션 요약과 워커 기록을 기준으로 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${o.progress_pct!=null?`${o.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${Qe(o.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${Qe(o.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 레인이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">오케스트레이션</div>
              <${D} panelId="command.chains" compact=${!0} />
            </div>
            <${Xh} chainOverlay=${l} linkedAutoresearch=${c} />
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">워커 현황</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            ${v.length>0?i`<div class="command-card-stack">
                  ${v.map(F=>i`<${Vh} worker=${F} />`)}
                </div>`:i`<div class="empty-state">활성 워커 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">상황 피드</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            ${Ms.length>0?i`<div class="command-trace-stack">
                  ${Ms.map(F=>i`<${Yh} item=${F} />`)}
                </div>`:i`<div class="empty-state">메시지, chain, autoresearch, attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">트레이스 흐름</div>
              <${D} panelId="command.trace" compact=${!0} />
            </div>
            ${n&&n.recent_trace_events.length>0?i`<div class="command-trace-stack">
                  ${n.recent_trace_events.map(F=>i`<${vr} event=${F} />`)}
                </div>`:i`<div class="empty-state">실행 범위 트레이스 이벤트가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Agents</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            ${Is.length>0?i`<div class="warroom-presence-grid">
                  ${Is.map(F=>i`<${wl} item=${F} />`)}
                </div>`:i`<div class="empty-state">가시적인 active agent가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Keepers</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            ${Rs.length>0?i`<div class="warroom-presence-grid">
                  ${Rs.map(F=>i`<${wl} item=${F} />`)}
                </div>`:i`<div class="empty-state">가시적인 keeper/runtime 카드가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">압력</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${u&&n?i`<${eu} swarm=${n} />`:null}
              ${T.length>0?T.map(F=>i`<${iu} blocker=${F} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${b>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>승인 대기</strong>
                        <span class="command-chip warn">${b}</span>
                      </div>
                      <p>엄격 액션이 묶여 있습니다. 실제 승인 처리는 제어 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${z>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>확인 대기</strong>
                        <span class="command-chip warn">${M>0?`${S}/${z}`:z}</span>
                      </div>
                      <p>
                        운영자 미리보기가 사람 확인을 기다리고 있습니다.
                        ${M>0?` 현재 actor 기준으로는 ${S}건만 보입니다.`:""}
                      </p>
                      <div class="command-tag-row">
                        ${$.slice(0,3).map(F=>i`<span class="command-tag">${F.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
              ${rt?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${rt.label}</strong>
                          <div class="command-card-sub">${rt.kind} · ${rt.phase}</div>
                        </div>
                        <span class="command-chip ${E(de(rt.motion_state))}">${Ft(rt.motion_state)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>현재 단계</span><span>${rt.current_step}</span>
                        <span>이동 사유</span><span>${rt.movement_reason}</span>
                        <span>막힘 수</span><span>${rt.blockers.length}</span>
                        <span>최근 이동</span><span>${Y(rt.last_movement_at)}</span>
                      </div>
                    </article>
                  `:null}
              ${u&&(n!=null&&n.detachment)?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${n.detachment.detachment_id}</strong>
                          <div class="command-card-sub">${n.detachment.assigned_unit_id}</div>
                        </div>
                        <span class="command-chip ${E(de(n.detachment.status))}">${Ft(n.detachment.status??"active")}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>리더</span><span>${n.detachment.leader_id??"미지정"}</span>
                        <span>편성</span><span>${n.detachment.roster.length}</span>
                        <span>세션</span><span>${n.detachment.session_id??"연결 없음"}</span>
                        <span>하트비트</span><span>${Od(n.detachment.heartbeat_deadline)}</span>
                      </div>
                    </article>
                  `:o?i`
                      <article class="command-card compact">
                        <div class="command-card-head">
                          <div>
                            <strong>${o.session_id}</strong>
                            <div class="command-card-sub">현재 세션 기준</div>
                          </div>
                          <span class="command-chip ${E(de(o.status))}">${Ft(o.status)}</span>
                        </div>
                        <div class="command-card-grid">
                          <span>진행률</span><span>${o.progress_pct!=null?`${o.progress_pct}%`:"정보 없음"}</span>
                          <span>경과</span><span>${Qe(o.elapsed_sec)}</span>
                          <span>남은 시간</span><span>${Qe(o.remaining_sec)}</span>
                          <span>완료 변화량</span><span>${o.done_delta_total??0}</span>
                        </div>
                      </article>
                    `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function Ol(t){switch((t??"").trim().toLowerCase()){case"active":return"가동 중";case"paused":return"일시정지";case"failed":return"실패";case"completed":case"done":return"완료";case"disconnected":return"끊김";case"preview":return"미리보기";case"captured":return"기록됨";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Zh({source:t}){const e=Pn(null),[n,s]=vn(null);return nt(()=>{let a=!1;const o=e.current;return o?(o.innerHTML="",s(null),(async()=>{try{const c=await Xg(),{svg:u}=await c.render(`command-chain-${Yg()}`,t);if(a||!e.current)return;e.current.innerHTML=u}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid 렌더링에 실패했습니다")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function ty({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return i`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${ve(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?i`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?i`<span class="command-tag ${ve(s==null?void 0:s.status)}">${Sn(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${ai(t.history)}</div>
    </button>
  `}function ey({item:t}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"알 수 없는 체인"}</strong>
        <span class="command-chip ${ve(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${Y(t.timestamp)}</div>
      <div class="command-card-sub">${ai(t)}</div>
    </article>
  `}function ny({node:t}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${ve(t.status)}">${t.status??"확인 필요"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"노드"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?i`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function sy({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,o=e.chain,l=(o==null?void 0:o.run_id)??null;return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${E(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${Ol(e.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>트레이스</span><span class="mono">${e.trace_id}</span>
        <span>자율성</span><span>${e.autonomy_level??"정보 없음"}</span>
        <span>예산 등급</span><span>${e.budget_class??"standard"}</span>
        <span>출처</span><span>${e.source??"managed"}</span>
        <span>최근 갱신</span><span>${Y(e.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${ve(o.status)}">${Ol(o.status)}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">실행 ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?i`<div class="command-card-foot">체크포인트 ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Kt("swarm"),it("command",{surface:"swarm",operation_id:e.operation_id,...l?{run_id:l}:{}})}}
        >
          스웜 실시간 보기
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{er(e.operation_id),Kt("chains"),it("command",{surface:"chains",operation:e.operation_id})}}
              >
                체인 열기
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${ut(n)} onClick=${()=>fe(()=>pf(e.operation_id))}>
                ${ut(n)?"일시정지 중…":"일시정지"}
              </button>
              <button class="control-btn ghost" disabled=${ut(a)} onClick=${()=>fe(()=>_f(e.operation_id))}>
                ${ut(a)?"회수 중…":"회수"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${ut(s)} onClick=${()=>fe(()=>mf(e.operation_id))}>
                ${ut(s)?"재개 중…":"재개"}
              </button>
            `:null}
      </div>
    </article>
  `}function ay({card:t}){var n;const e=t.detachment;return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${E(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>리더</span><span>${e.leader_id??"미지정"}</span>
        <span>편성</span><span>${e.roster.length}</span>
        <span>세션</span><span>${e.session_id??"연결 없음"}</span>
        <span>런타임</span><span>${e.runtime_kind??"managed"}</span>
        <span>런타임 참조</span><span>${e.runtime_ref??"정보 없음"}</span>
        <span>진행 흔적</span><span>${Y(e.last_progress_at)}</span>
        <span>하트비트</span><span>${Od(e.heartbeat_deadline)}</span>
        <span>최근 갱신</span><span>${Y(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?i`<span class="command-tag ${Jg(e.heartbeat_deadline)}">
              기한 ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function iy(){const t=Jt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">작전</div>
          <${D} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${sy} card=${e} />`)}
            </div>`:i`<div class="empty-state">관리형 또는 투영된 작전이 없습니다.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">분견대</div>
          <${D} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${ay} card=${e} />`)}
            </div>`:i`<div class="empty-state">투영된 분견대가 없습니다.</div>`}
      </section>
    </div>
  `}function oy(){var c,u,m,p,v,f,h,A,b,k,$,z,S,M,T,K;const t=bs.value,e=(t==null?void 0:t.operations)??[],n=dn.value,s=e.find(U=>U.operation.operation_id===n)??e[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,o=((u=Qn.value)==null?void 0:u.run)??(s==null?void 0:s.preview_run)??null,l=!((m=Qn.value)!=null&&m.run)&&!!(s!=null&&s.preview_run);return nt(()=>{a?df(a):cf()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${D} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${ve(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>native chain 연결</strong>
            <span class="command-chip ${ve(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"체인 요약은 MASC 프록시를 통해 집계됩니다."}</p>
          <div class="command-card-grid">
            <span>기준 URL</span><span>${(t==null?void 0:t.connection.base_url)??"정보 없음"}</span>
            <span>연결된 작전</span><span>${((p=t==null?void 0:t.summary)==null?void 0:p.linked_operations)??0}</span>
            <span>활성 체인</span><span>${((v=t==null?void 0:t.summary)==null?void 0:v.active_chains)??0}</span>
            <span>최근 실패</span><span>${((f=t==null?void 0:t.summary)==null?void 0:f.recent_failures)??0}</span>
            <span>마지막 이벤트</span><span>${Y((h=t==null?void 0:t.summary)==null?void 0:h.last_history_event_at)}</span>
          </div>
        </article>

        ${Ea.value?i`<div class="empty-state error">${Ea.value}</div>`:null}

        ${$o.value&&!t?i`<div class="empty-state">체인 오버레이 불러오는 중…</div>`:e.length>0?i`
                <div class="command-chain-list">
                  ${e.map(U=>i`
                    <${ty}
                      overlay=${U}
                      selected=${(s==null?void 0:s.operation.operation_id)===U.operation.operation_id}
                      onSelect=${()=>er(U.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(U=>i`<${ey} item=${U} />`)}
                </div>
              `:i`<div class="empty-state">최근 체인 이력이 없습니다.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">체인 상세</div>
          <${D} panelId="command.chains" compact=${!0} />
        </div>
        ${s?i`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${ve((A=s.operation.chain)==null?void 0:A.status)}">
                    ${((b=s.operation.chain)==null?void 0:b.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>종류</span><span>${((k=s.operation.chain)==null?void 0:k.kind)??"chain_dsl"}</span>
                  <span>체인 ID</span><span>${(($=s.operation.chain)==null?void 0:$.chain_id)??"goal-driven"}</span>
                  <span>실행 ID</span><span>${a??"아직 구체화되지 않음"}</span>
                  <span>진행률</span><span>${Sn((z=s.runtime)==null?void 0:z.progress)}</span>
                  <span>경과</span><span>${Qe((S=s.runtime)==null?void 0:S.elapsed_sec)}</span>
                  <span>최근 갱신</span><span>${Y(((M=s.operation.chain)==null?void 0:M.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(T=s.operation.chain)!=null&&T.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid 그래프</strong>
                        <span class="command-chip">${((K=s.operation.chain)==null?void 0:K.chain_id)??"graph"}</span>
                      </div>
                      <${Zh} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">기록된 Mermaid 그래프가 아직 없습니다.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>실행 상세</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"실패":l?"미리보기":"기록됨":"대기 중"}
                  </span>
                </div>
                ${Pa.value?i`<div class="empty-state">실행 상세 불러오는 중…</div>`:Zn.value?i`<div class="empty-state error">${Zn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>체인</span><span>${o.chain_id}</span>
                            <span>실행</span><span>${o.run_id??"미리보기만 있음"}</span>
                            <span>지속시간</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"정보 없음"}</span>
                            <span>노드</span><span>${o.nodes.length}</span>
                          </div>
                          ${l?i`<div class="command-card-foot">run-store에 기록되기 전, 설계된 체인으로 만든 미리보기입니다.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(U=>i`<${ny} node=${U} />`)}
                          </div>
                        `:i`<div class="empty-state">이 작전의 run-store 상세는 아직 없습니다.</div>`}
              </div>
            `:i`<div class="empty-state">그래프와 실행 상세를 보려면 체인 기반 작전을 고르세요.</div>`}
      </section>
    </div>
  `}function ry(t){switch((t??"").trim().toLowerCase()){case"pending":return"대기 중";case"approved":return"승인됨";case"denied":return"거부됨";case"executed":return"실행됨";case"active":return"가동 중";default:return(t==null?void 0:t.trim())||"확인 필요"}}function ly({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return i`
    <article class="command-card ${E(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${E(t.status)}">${ry(t.status??"pending")}</span>
      </div>
      <div class="command-card-grid">
        <span>결정 ID</span><span>${t.decision_id}</span>
        <span>요청자</span><span>${t.requested_by??"알 수 없음"}</span>
        <span>출처</span><span>${t.source??"managed"}</span>
        <span>트레이스</span><span class="mono">${t.trace_id}</span>
        <span>생성 시각</span><span>${Y(t.created_at)}</span>
        <span>이유</span><span>${t.reason??"정보 없음"}</span>
      </div>
      ${t.status==="pending"&&!s?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${ut(e)} onClick=${()=>fe(()=>ff(t.decision_id))}>
                ${ut(e)?"승인 중…":"승인"}
              </button>
              <button class="control-btn ghost" disabled=${ut(n)} onClick=${()=>fe(()=>gf(t.decision_id))}>
                ${ut(n)?"거부 중…":"거부"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">레거시 operator 승인입니다. 실제 실행은 operator control에서 처리합니다.</div>`:null}
    </article>
  `}function cy({row:t}){var c,u,m;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((c=e.policy)!=null&&c.frozen),o=!!((u=e.policy)!=null&&u.kill_switch),l=Math.round((t.utilization??0)*100);return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${E(l>100?"bad":l>70?"warn":"ok")}">${l}%</span>
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
        <button class="control-btn ghost" disabled=${ut(n)} onClick=${()=>fe(()=>$f(e.unit_id,!a))}>
          ${ut(n)?"적용 중…":a?"동결 해제":"동결"}
        </button>
        <button class="control-btn ghost" disabled=${ut(s)} onClick=${()=>fe(()=>hf(e.unit_id,!o))}>
          ${ut(s)?"적용 중…":o?"킬 스위치 해제":"킬 스위치 켜기"}
        </button>
      </div>
    </article>
  `}function dy(){const t=Jt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${D} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${ly} decision=${e} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">유닛 제어</div>
          <${D} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${cy} row=${e} />`)}
            </div>`:i`<div class="empty-state">제어할 용량 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function uy(){return i`
    <div class="command-surface-tabs grouped">
      ${Zg.map(t=>i`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${Dd.filter(e=>e.group===t.id).map(e=>i`
                <button
                  class="command-surface-tab ${V.value===e.id?"active":""}"
                  onClick=${()=>{Kt(e.id),it("command",As(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function py({wallboard:t=!1}){if(V.value==="warroom")return i`<${Qh} wallboard=${t} />`;if(V.value==="summary")return i`<${K$} />`;if(V.value==="orchestra")return i`<${sh} />`;if(V.value==="swarm")return i`<${wh} />`;if(!Jt.value)return i`<${B$} />`;switch(V.value){case"chains":return i`<${oy} />`;case"topology":return i`<${xh} />`;case"alerts":return i`<${Sh} />`;case"trace":return i`<${Ch} />`;case"control":return i`<${dy} />`;case"operations":default:return i`<${iy} />`}}function my(){const t=V.value==="warroom"&&O.value.params.presentation==="wallboard";return nt(()=>{Xe(),je(),uf(),Zt(),Ee()},[]),nt(()=>{if(O.value.tab!=="command")return;const e=O.value.params.surface,n=O.value.params.operation,s=ks(O.value);if(Al(e))Kt(e);else if(s){const a=xd(s);Al(a)&&Kt(a)}else e||Kt("warroom");n&&er(n),(e==="swarm"||e==="warroom"||e==="orchestra"||V.value==="warroom"||V.value==="orchestra")&&Zt(),(e==="orchestra"||V.value==="orchestra")&&Ee(),(e==="warroom"||V.value==="warroom")&&gt()},[O.value.tab,O.value.params.surface,O.value.params.operation,O.value.params.operation_id,O.value.params.run_id,O.value.params.source,O.value.params.action_type,O.value.params.target_type,O.value.params.target_id,O.value.params.focus_kind]),nt(()=>{let e=null;const n=()=>{e||(e=window.setTimeout(()=>{e=null,Xe(),je(),(V.value==="swarm"||V.value==="warroom"||V.value==="orchestra")&&Zt(),V.value==="orchestra"&&Ee(),V.value==="warroom"&&gt()},250))},s=new EventSource(a$()),a=e$.map(o=>{const l=()=>n();return s.addEventListener(o,l),{type:o,handler:l}});return s.onerror=()=>{n()},()=>{a.forEach(({type:o,handler:l})=>{s.removeEventListener(o,l)}),s.close(),e&&window.clearTimeout(e)}},[]),nt(()=>{const e=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const n=V.value;n!=="swarm"&&n!=="warroom"&&n!=="orchestra"||(Xe(),Zt(),n==="orchestra"&&Ee(),n==="warroom"&&gt())},5e3);return()=>{window.clearInterval(e)}},[]),i`
    <section class="dashboard-panel command-plane-view ${t?"wallboard":""}">
      ${t?null:i`
        <div class="panel-header">
          <div>
            <h2>지휘면</h2>
            <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
          </div>
          <div class="panel-actions">
            <button
              class="control-btn ghost"
              onClick=${()=>{fe(()=>vf())}}
              disabled=${ut("dispatch:tick")}
            >
              ${ut("dispatch:tick")?"정리 중...":"Tick 실행"}
            </button>
            <button
              class="control-btn ghost"
              onClick=${()=>{Le(),Xe(),je(),Zt(),V.value==="warroom"&&gt()}}
              disabled=${Sa.value}
            >
              ${Sa.value?"새로고침 중...":"새로고침"}
            </button>
            <button
              class="control-btn ghost"
              onClick=${()=>{Kt("warroom"),it("command",{...As("warroom"),presentation:"wallboard"})}}
            >
              Wallboard
            </button>
          </div>
        </div>
      `}

      ${Aa.value?i`<div class="empty-state error">${Aa.value}</div>`:null}
      ${Ia.value?i`<div class="empty-state error">${Ia.value}</div>`:null}
      ${t?null:i`<${Ct} surfaceId="command" />`}
      ${t?null:i`<${ur} />`}
      ${t?null:i`<${w$} />`}
      ${t||V.value==="warroom"?null:i`<${O$} />`}
      ${t?null:i`<${uy} />`}
      <${py} wallboard=${t} />
    </section>
  `}function _y(){var k;const t=At.value,e=Vo.value,n=(t==null?void 0:t.room)??{},s=ti(t),a=s.items,o=s.confirm_required_actions,l=s.actor_filter,c=s.hidden_count,u=s.hidden_actors,m=(t==null?void 0:t.recent_messages)??[],p=(e==null?void 0:e.recommended_actions)??[],v=(k=e==null?void 0:e.active_recommended_actions)!=null&&k.length?e.active_recommended_actions:p,f=e==null?void 0:e.active_summary,h=(e==null?void 0:e.resident_judge_runtime)??(t==null?void 0:t.resident_judge_runtime),A=(e==null?void 0:e.active_guidance_layer)??"fallback",b=m.slice(0,5);return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Room 개입</div>
          <${D} panelId="intervene.action_studio" compact=${!0} />
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
          <div class="ops-stat ${Vd(h)}">
            <span>Resident Judge</span>
            <strong>${oi(h)}</strong>
          </div>
        </div>

        <label class="control-label" for="ops-broadcast">Room 방송</label>
        <div class="control-row">
          <input
            id="ops-broadcast"
            class="control-input"
            type="text"
            placeholder="@agent 또는 room 전체 공지"
            value=${pn.value}
            onInput=${$=>{pn.value=$.target.value}}
            onKeyDown=${$=>{$.key==="Enter"&&Nl()}}
            disabled=${Z.value}
          />
          <button class="control-btn" onClick=${()=>{Nl()}} disabled=${Z.value||pn.value.trim()===""}>
            보내기
          </button>
        </div>

        <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
        <div class="control-row ops-split-row">
          <input
            id="ops-pause-reason"
            class="control-input"
            type="text"
            value=${Da.value}
            onInput=${$=>{Da.value=$.target.value}}
            disabled=${Z.value}
          />
          <button class="control-btn ghost" onClick=${()=>{fh()}} disabled=${Z.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{Xd()}} disabled=${Z.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${mn.value}
          onInput=${$=>{mn.value=$.target.value}}
          disabled=${Z.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${ss.value}
          onInput=${$=>{ss.value=$.target.value}}
          disabled=${Z.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${as.value}
            onChange=${$=>{as.value=$.target.value}}
            disabled=${Z.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{gh()}} disabled=${Z.value||mn.value.trim()===""}>
            주입
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">추천 개입</div>
          <${D} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
        <article class="ops-guidance-card ${Ka(A)}">
          <div class="ops-guidance-head">
            <strong>${mr(A)}</strong>
            <span>${(h==null?void 0:h.keeper_name)??(e==null?void 0:e.judgment_owner)??"judge 없음"}</span>
          </div>
          <div class="ops-guidance-body">
            ${(f==null?void 0:f.summary)??"현재 active guidance 요약이 없습니다. fallback queue만 표시합니다."}
          </div>
          <div class="ops-guidance-meta">
            <span>authoritative ${e!=null&&e.authoritative_judgment_available?"yes":"no"}</span>
            <span>${_r(f)}</span>
            ${h!=null&&h.model_used?i`<span>${h.model_used}</span>`:null}
          </div>
        </article>
        ${Xn.value&&!e?i`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:v.length>0?i`
          <div class="ops-log-list">
            ${v.map($=>i`
              <article key=${`${$.action_type}:${$.target_type}:${$.target_id??"room"}`} class="ops-log-entry ${$.severity}">
                <div class="ops-log-head">
                  <strong>${we($.action_type)}</strong>
                  <span>${_n($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                  <span>${Ba($.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${$.reason}</div>
                ${$.suggested_payload?i`
                  <div class="ops-confirmation-actions">
                    <button class="control-btn ghost" onClick=${()=>{_h($)}} disabled=${Z.value}>
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
          <${D} panelId="intervene.pending_confirmations" compact=${!0} />
        </div>
        <p class="ops-context-note">
          ${l?`현재 actor ${l} 기준 queue를 읽습니다. 승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다.`:"승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다."}
        </p>
        ${o.length>0?i`
          <div class="ops-log-list">
            ${o.map($=>i`
              <article key=${`${$.action_type}:${$.target_type}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${we($.action_type)}</strong>
                  <span>${_n($.target_type)}</span>
                  <span>${Ba($.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${$.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}
        ${a.length>0?i`
          <div class="ops-confirmation-list">
            ${a.map($=>i`
              <article key=${$.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${we($.action_type)}</strong>
                  <span>${_n($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                  <span>${$.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${$.preview?i`<pre class="ops-code-block compact">${Fa($.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{jl($.confirm_token)}} disabled=${Z.value}>
                    실행
                  </button>
                  <button class="control-btn ghost" onClick=${()=>{jl($.confirm_token,"deny")}} disabled=${Z.value}>
                    거부
                  </button>
                  <span class="ops-token">${$.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        `:i`
          <div class="ops-empty">
            ${c>0&&l?`현재 선택한 actor(${l}) 기준 승인 대기는 0건입니다. 다른 actor 대기 ${c}건${u.length>0?` · ${u.join(", ")}`:""}`:"지금 승인 대기는 없습니다. 위 목록의 preview-confirm 액션을 먼저 만들어야 여기에 쌓입니다."}
          </div>
        `}
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 Room 메시지</div>
          <${D} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${b.length>0?i`
          <div class="ops-feed-list">
            ${b.map($=>i`
              <article key=${$.seq??$.id??$.timestamp} class="ops-feed-item">
                <div class="ops-feed-meta">
                  <strong>${$.from}</strong>
                  <span>${$.timestamp}</span>
                </div>
                <div class="ops-feed-content">${$.content}</div>
              </article>
            `)}
          </div>
        `:i`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
      </section>
    </div>
  `}function vy(){var m;const t=At.value,e=Ht.value,n=(t==null?void 0:t.sessions)??[],s=((t==null?void 0:t.available_actions)??[]).filter(p=>p.target_type==="team_session"),a=n.find(p=>p.session_id===gn.value)??n[0]??null,o=e==null?void 0:e.active_summary,l=(e==null?void 0:e.active_guidance_layer)??"fallback",c=(e==null?void 0:e.resident_judge_runtime)??(t==null?void 0:t.resident_judge_runtime),u=(m=e==null?void 0:e.active_recommended_actions)!=null&&m.length?e.active_recommended_actions:(e==null?void 0:e.recommended_actions)??[];return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${D} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(p=>{var v;return i`
            <button
              key=${p.session_id}
              class="ops-entity-card ${(a==null?void 0:a.session_id)===p.session_id?"active":""}"
              onClick=${()=>{gn.value=p.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${p.session_id}</strong>
                <span class="status-badge ${p.status??"idle"}">${tn(p.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(p.progress_pct??0)}%</span>
                <span>${p.done_delta_total??0}건 완료</span>
                <span>${(v=p.team_health)!=null&&v.status?tn(String(p.team_health.status)):"상태 확인 필요"}</span>
              </div>
            </button>
          `})}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Session 요약</div>
          <${D} panelId="intervene.session_digest" compact=${!0} />
        </div>
        <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
        ${a&&e?i`
          <article class="ops-guidance-card ${Ka(l)}">
            <div class="ops-guidance-head">
              <strong>${mr(l)}</strong>
              <span>${oi(c)}</span>
            </div>
            <div class="ops-guidance-body">
              ${(o==null?void 0:o.summary)??"현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다."}
            </div>
            <div class="ops-guidance-meta">
              <span>authoritative ${e.authoritative_judgment_available?"yes":"no"}</span>
              <span>${_r(o)}</span>
              ${c!=null&&c.model_used?i`<span>${c.model_used}</span>`:null}
            </div>
          </article>
          ${u.length>0?i`
            <div class="ops-log-list">
              ${u.map(p=>i`
                <article key=${`${p.action_type}:${p.target_type}:${p.target_id??"session"}`} class="ops-log-entry ${p.severity}">
                  <div class="ops-log-head">
                    <strong>${we(p.action_type)}</strong>
                    <span>${_n(p.target_type)}${p.target_id?` · ${p.target_id}`:""}</span>
                  </div>
                  <div class="ops-log-body">${p.reason}</div>
                </article>
              `)}
            </div>
          `:null}
          <div class="ops-log-list">
            ${e.attention_items.length>0?e.attention_items.map(p=>i`
              <article key=${`${p.kind}:${p.target_id??"session"}`} class="ops-log-entry ${p.severity}">
                <div class="ops-log-head">
                  <strong>${p.kind}</strong>
                  <span>${_n(p.target_type)}${p.target_id?` · ${p.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${p.summary}</div>
              </article>
            `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${e.worker_cards.length>0?e.worker_cards.map(p=>i`
              <article key=${`${p.actor??p.spawn_role??"worker"}:${p.spawn_agent??p.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${p.actor??p.spawn_role??"worker"}</strong>
                  <span>${tn(p.status)}</span>
                  <span>${p.spawn_agent??p.runtime_pool??"runtime 확인 필요"}</span>
                </div>
                <div class="ops-log-body">
                  ${p.worker_class??"worker"}${p.lane_id?` · ${p.lane_id}`:""}${p.routing_reason?` · ${p.routing_reason}`:""}
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
          <${D} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>
        ${s.length>0?i`
          <div class="ops-log-list">
            ${s.map(p=>i`
              <article key=${p.action_type} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${we(p.action_type)}</strong>
                  <span>${Ba(p.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${p.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}

        ${a?i`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${a.session_id}</div>
            <div class="ops-detail-meta">
              <span>상태: ${tn(a.status)}</span>
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
              <pre class="ops-code-block compact">${Fa(a.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${St.value}
            onChange=${p=>{St.value=p.target.value}}
            disabled=${Z.value||!a}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
            <option value="worker_spawn_batch">worker 교체</option>
          </select>
          <button class="control-btn" onClick=${()=>{$h()}} disabled=${Z.value||!a}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${dh(St.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${is.value}
          onInput=${p=>{is.value=p.target.value}}
          disabled=${Z.value||!a}
        ></textarea>

        ${St.value==="task"?i`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${os.value}
            onInput=${p=>{os.value=p.target.value}}
            disabled=${Z.value||!a}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${rs.value}
            onInput=${p=>{rs.value=p.target.value}}
            disabled=${Z.value||!a}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${ls.value}
            onChange=${p=>{ls.value=p.target.value}}
            disabled=${Z.value||!a}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
        `:St.value==="worker_spawn_batch"?i`
          <textarea
            class="control-textarea"
            rows=${6}
            placeholder='spawn_batch JSON, 예: [{"spawn_agent":"llama","spawn_prompt":"...", "spawn_role":"replacement"}]'
            value=${cs.value}
            onInput=${p=>{cs.value=p.target.value}}
            disabled=${Z.value||!a}
          ></textarea>
        `:null}

        <div class="control-row ops-split-row">
          <input
            class="control-input"
            type="text"
            value=${qa.value}
            onInput=${p=>{qa.value=p.target.value}}
            disabled=${Z.value||!a}
          />
          <button class="control-btn ghost" onClick=${()=>{hh()}} disabled=${Z.value||!a}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function fy(){var o;const t=At.value,e=(t==null?void 0:t.keepers)??[],n=(t==null?void 0:t.persistent_agents)??[],s=(t==null?void 0:t.available_actions)??[],a=e.find(l=>l.name===ko.value)??e[0]??null;return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${D} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${e.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:e.map(l=>i`
            <button
              key=${l.name}
              class="ops-entity-card ${(a==null?void 0:a.name)===l.name?"active":""}"
              onClick=${()=>{ko.value=l.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${l.name}</strong>
                <span class="status-badge ${l.status??"idle"}">${tn(l.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${l.model??"model 확인 필요"}</span>
                <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${El(l.last_turn_ago_s)}</span>
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
                    <span class="status-badge ${l.status??"idle"}">${tn(l.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>persistent</span>
                    <span>${l.model??"model 확인 필요"}</span>
                    <span>${El(l.last_turn_ago_s)}</span>
                  </div>
                </article>
              `)}
        </div>
      </section>

      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Keeper 액션</div>
          <${D} panelId="intervene.action_studio" compact=${!0} />
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
          <${Nd}
            keeperName=${a.name}
            placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
          />
        `:i`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">가능한 액션 목록</div>
          <${D} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
        <div class="ops-log-list">
          ${s.length?s.map(l=>i`
                <article key=${`${l.action_type}:${l.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${we(l.action_type)}</strong>
                    <span>${_n(l.target_type)}</span>
                    <span>${Ba(l.confirm_required)}</span>
                  </div>
                  <div class="ops-log-body">${l.description??"설명이 아직 없습니다."}</div>
                </article>
              `):i`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 개입 로그</div>
          <${D} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <div class="ops-log-list">
          ${ya.value.length===0?i`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:ya.value.map(l=>i`
            <article key=${l.id} class="ops-log-entry ${l.outcome}">
              <div class="ops-log-head">
                <strong>${we(l.action_type)}</strong>
                <span>${l.target_label}</span>
                <span>${l.at}</span>
              </div>
              <div class="ops-log-body">${l.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function gy(){var S,M;const t=At.value,e=O.value.tab==="intervene"?ks(O.value):null,n=Vo.value,s=(t==null?void 0:t.room)??{},a=(t==null?void 0:t.sessions)??[],o=(t==null?void 0:t.keepers)??[],l=ti(t),c=l.visible_count,u=l.total_count,m=l.hidden_count,p=l.actor_filter,v=a.find(T=>T.session_id===gn.value)??a[0]??null,f=(n==null?void 0:n.attention_items)??[],h=f.filter(lh),A=f.filter(ch),b=a.filter(T=>rh(T)!=="ok"),k=o.filter(T=>Ci(T)!=="ok"),$=vh(e,a,o);nt(()=>{Oe()},[]),nt(()=>{if(O.value.tab!=="intervene"){qs.value=null;return}if(!e){qs.value=null;return}qs.value!==e.id&&(qs.value=e.id,mh(e))},[O.value.tab,O.value.params.source,O.value.params.action_type,O.value.params.target_type,O.value.params.target_id,O.value.params.focus_kind,e==null?void 0:e.id]),nt(()=>{const T=(v==null?void 0:v.session_id)??null;De(T)},[v==null?void 0:v.session_id]);const z=[{key:"room",label:"방 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:m>0?`${c}/${u}`:c,detail:c>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":m>0&&p?`현재 개입 ID(${p}) 기준으로는 비어 있고, 다른 개입 ID 대기 ${m}건이 있습니다`:"지금 막혀 있는 확인 대기는 없습니다",tone:u>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:h.length>0?h.length:a.length,detail:h.length>0?((S=h[0])==null?void 0:S.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 팀 세션이 없습니다":"세션 쪽 긴급 주의 신호는 현재 없습니다",tone:h.length>0?Pl(h):a.length===0?"warn":b.some(T=>$n(T.status)==="paused")?"bad":b.length>0?"warn":"ok"},{key:"keeper",label:"키퍼 압력",value:A.length>0?A.length:k.length,detail:A.length>0?((M=A[0])==null?void 0:M.summary)??"직접 메시지나 상태 점검이 필요한 키퍼가 있습니다":k.length>0?"오래됐거나 오프라인이거나 텔레메트리가 비는 키퍼가 보입니다":"지금은 키퍼 쪽이 비교적 안정적입니다",tone:A.length>0?Pl(A):k.some(T=>Ci(T)==="bad")?"bad":k.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${Ct} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">개입</div>
            <${D} panelId="intervene.action_studio" compact=${!0} />
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
            value=${ii.value}
            onInput=${T=>oh(T.target.value)}
          />
            <button
              class="control-btn ghost"
              onClick=${()=>{Le(),gt(),Oe(),De((v==null?void 0:v.session_id)??null)}}
            disabled=${Yn.value||Z.value}
          >
            ${Yn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${$e.value?i`<section class="ops-banner error">${$e.value}</section>`:null}
      ${fn.value?i`<section class="ops-banner error">${fn.value}</section>`:null}
      <${ur} />
      ${e?i`
        <section class="ops-banner ${$?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${ni(e.action_type)}</span>
            <span>${ir(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?i`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${$?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const T=[];if((c>0||m>0)&&T.push({label:m>0?`확인 대기 ${c}/${u}건 확인`:`확인 대기 ${c}건 처리`,desc:m>0&&p?`현재 개입 ID(${p}) 기준으로 보이는 대기열을 먼저 확인합니다`:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:c>0?"bad":"warn",onClick:()=>{const K=document.querySelector(".ops-pending-section");K==null||K.scrollIntoView({behavior:"smooth"})}}),s.paused&&T.push({label:"방 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void Xd()}),k.length>0){const K=k.filter(U=>Ci(U)==="bad");T.push({label:K.length>0?`오프라인 키퍼 ${K.length}개`:`점검이 필요한 키퍼 ${k.length}개`,desc:K.length>0?"메시지를 보내거나 상태를 확인하세요":"오래됐거나 텔레메트리가 비어 있습니다",tone:K.length>0?"bad":"warn",onClick:()=>{const U=document.querySelector(".ops-keeper-section");U==null||U.scrollIntoView({behavior:"smooth"})}})}return T.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${T.slice(0,3).map(K=>i`
                <button class="ops-action-guide-item ${K.tone}" onClick=${K.onClick}>
                  <strong>${K.label}</strong>
                  <span>${K.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `})()}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${D} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 방인지, 세션인지, 키퍼인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${z.map(T=>i`
            <div key=${T.key} class="ops-priority-card ${T.tone}">
              <span class="ops-priority-label">${T.label}</span>
              <strong>${T.value}</strong>
              <div class="ops-priority-detail">${T.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${_y} />
        <${vy} />
        <${fy} />
      </div>
    </section>
  `}function $y({text:t}){if(!t)return null;const e=hy(t);return i`<div class="markdown-content">${e}</div>`}function hy(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),u=[];for(s++;s<e.length&&!e[s].startsWith(l);)u.push(e[s]),s++;s++,n.push(i`<pre><code class=${c?`language-${c}`:""}>${u.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<e.length&&!e[s].includes("</think>");)l.push(e[s]),s++;if(s<e.length){const m=e[s].replace("</think>","").trim();m&&l.push(m),s++}const u=l.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Ai(u)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<e.length&&e[s].startsWith("> ");)l.push(e[s].slice(2)),s++;n.push(i`<blockquote>${Ai(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<e.length;){const l=e[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;o.push(l),s++}o.length>0&&n.push(i`<p>${Ai(o.join(`
`))}</p>`)}return n}function Ai(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&e.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const ou=[{id:"recent",label:"최신순"},{id:"hot",label:"인기순"},{id:"trending",label:"급상승"},{id:"updated",label:"최근 갱신"},{id:"discussed",label:"토론 많은 순"}],ra=g(null),la=g([]),hn=g(!1),Ne=g(null),qn=g(""),Fn=g(!1),nn=g(!0),fr=20,Ge=g(fr);function yy(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const by=g(yy());function ky(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"미리보기 없음"}function Dl(t){return t.updated_at!==t.created_at}function xy(t){if(t.post_kind)return t.post_kind==="automation";const e=(t.hearth??"").toLowerCase();return t.visibility!=="internal"||!t.expires_at||!e?!1:!!(e.startsWith("mdal")||e.includes("harness"))}function Sy(t){return t==="lodge-system"||t==="team-session"}function ds(t){return t.post_kind?t.post_kind:Sy(t.author)?"system":xy(t)?"automation":"human"}function ru(t){const e=[],n=[];let s=0;return t.forEach(a=>{const o=ds(a);if(!(o==="system"&&Re.value)){if(o==="automation"&&nn.value){s+=1;return}if(o==="human"){e.push(a);return}n.push(a)}}),{human:e,operations:n,hiddenAutomation:s}}function Cy(t){if(!t.expires_at)return null;const e=Date.parse(t.expires_at);return Number.isFinite(e)?e<=Date.now()?i`<span class="board-meta-chip">만료됨</span>`:i`<span class="board-meta-chip">만료까지 <${X} timestamp=${t.expires_at} /></span>`:null}async function gr(t){Ne.value=t,ra.value=null,la.value=[],hn.value=!0;try{const e=await qp(t);if(Ne.value!==t)return;ra.value={id:e.id,author:e.author,title:e.title,body:e.body,content:e.content,meta:e.meta,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,post_kind:e.post_kind,flair:e.flair,hearth:e.hearth,visibility:e.visibility,expires_at:e.expires_at,hearth_count:e.hearth_count},la.value=e.comments??[]}catch{Ne.value===t&&(ra.value=null,la.value=[])}finally{Ne.value===t&&(hn.value=!1)}}async function ql(t){const e=qn.value.trim();if(e){Fn.value=!0;try{await Fp(t,by.value,e),qn.value="",j("댓글을 등록했습니다","success"),await gr(t),me()}catch{j("댓글 등록에 실패했습니다","error")}finally{Fn.value=!1}}}function Ay(){const t=Jn.value,e=nn.value?"자동화 글 숨김":"자동화 글 표시 중";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${ou.map(n=>i`
          <button
            class="board-sort-btn ${t===n.id?"active":""}"
            onClick=${()=>{Jn.value=n.id,Ge.value=fr,me()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${nn.value?"is-active":""}"
          onClick=${()=>{nn.value=!nn.value}}
        >
          ${e}
        </button>
        <button
          class="control-btn ghost ${Re.value?"is-active":""}"
          onClick=${()=>{Re.value=!Re.value,me()}}
        >
          ${Re.value?"시스템 글 숨김":"시스템 글 표시 중"}
        </button>
        <button class="control-btn ghost" onClick=${me} disabled=${Vn.value}>
          ${Vn.value?"새로고침 중...":"새로고침"}
        </button>
      </div>
    </div>
  `}function Ti(){var s;const t=((s=ou.find(a=>a.id===Jn.value))==null?void 0:s.label)??Jn.value,e=ru(Za.value),n=e.human.length+e.operations.length;return i`
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
        <strong>${nn.value?`자동화 ${e.hiddenAutomation}건 숨김`:"분리된 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">시스템 글 정책</span>
        <strong>${Re.value?"시스템 글 숨김":"시스템 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">최근 갱신</span>
        <strong>${co.value?i`<${X} timestamp=${co.value} />`:"아직 불러오지 않음"}</strong>
      </div>
    </div>
  `}function Fl({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await gc(t.id,n),me()}catch{j("투표에 실패했습니다","error")}};return i`
    <div class="board-post" onClick=${()=>Lu(t.id)}>
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
                ${Dl(t)?i`<span class="board-meta-chip">수정됨</span>`:null}
                ${ds(t)!=="human"?i`<span class="board-meta-chip">${ds(t)}</span>`:null}
                ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>작성자 ${t.author}</span>
            <span><${X} timestamp=${t.created_at} /></span>
            ${Dl(t)?i`<span>수정 <${X} timestamp=${t.updated_at} /></span>`:null}
            <span>댓글 ${t.comment_count}</span>
            <span>투표 ${t.votes??0}</span>
          </div>
        </div>
        <div class="post-snippet">${ky(t.body)}</div>
      </div>
    </div>
  `}function Ty({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">아직 댓글이 없습니다</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${X} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Iy({postId:t}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="댓글 추가..."
        value=${qn.value}
        onInput=${e=>{qn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&ql(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Fn.value}
      />
      <button
        onClick=${()=>ql(t)}
        disabled=${Fn.value||qn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Fn.value?"...":"등록"}
      </button>
    </div>
  `}function Ry({post:t}){Ne.value!==t.id&&!hn.value&&gr(t.id);const e=async n=>{try{await gc(t.id,n),me()}catch{j("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>it("memory")}>← 메모리로 돌아가기</button>
      <${R} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${$y} text=${t.body} />
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
                  ${ds(t)!=="human"?i`<span class="board-meta-chip">${ds(t)}</span>`:null}
                  ${Cy(t)}
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
        ${hn.value?i`<div class="loading-indicator">댓글 불러오는 중...</div>`:i`<${Ty} comments=${la.value} />`}
        <${Iy} postId=${t.id} />
      <//>
    </div>
  `}function My(){const t=ru(Za.value),e=[...t.human,...t.operations],n=O.value.params.post??null,s=n?e.find(a=>a.id===n)??(Ne.value===n?ra.value:null):null;return n&&!s&&Ne.value!==n&&!hn.value&&gr(n),n?s?i`
          <${Ct} surfaceId="memory" />
          <${Ti} />
          <${Ry} post=${s} />
        `:i`
          <div>
            <${Ct} surfaceId="memory" />
            <${Ti} />
            <button class="back-btn" onClick=${()=>it("memory")}>← 메모리로 돌아가기</button>
            ${hn.value?i`<div class="loading-indicator">글 불러오는 중...</div>`:i`<div class="empty-state">글을 찾지 못했습니다</div>`}
          </div>
        `:i`
    <div>
      <${Ct} surfaceId="memory" />
      <${Ti} />
      <${Ay} />
      ${Vn.value?i`<div class="loading-indicator">메모리 피드 불러오는 중...</div>`:e.length===0?i`<div class="empty-state">지금은 남아 있는 메모리 글이 없습니다</div>`:i`
              <${R} title="사람이 쓴 글" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.human.slice(0,Ge.value).map(a=>i`<${Fl} key=${a.id} post=${a} />`)}
                </div>
                ${t.human.length>Ge.value?i`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{Ge.value=Ge.value+fr}}
                    >
                      더 보기 (${t.human.length-Ge.value}개 남음)
                    </button>
                  </div>
                `:null}
              <//>
              ${t.operations.length>0?i`
                    <${R} title="자동화 · 시스템" class="section" semanticId="memory.feed">
                      <div class="board-post-list">
                        ${t.operations.map(a=>i`<${Fl} key=${a.id} post=${a} />`)}
                      </div>
                    <//>
                  `:null}
            `}
    </div>
  `}function Ly({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,o=2*Math.PI*s,l=o*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),i`
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
  `}function zy(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Kl(t,e="없음"){return!t||t.length===0?e:t.slice(0,4).join(", ")}function Ey({model:t,onClick:e,variant:n,testId:s}){var c,u,m,p;const a=!!t.recentEvent||!!t.recentInput||!!t.recentOutput||!!t.routeSummary||!!t.auditSource||!!t.auditAt||(((c=t.recentTools)==null?void 0:c.length)??0)>0||(((u=t.allowedTools)==null?void 0:u.length)??0)>0,o=n==="mission"?`mission-activity-card ${t.tone}`:"keeper-canonical-card",l=n==="mission"?"mission-card-select":`monitor-row ${t.tone}${t.stateClass?` state-${t.stateClass}`:""}`;return i`
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
                <${Ly} ratio=${t.contextRatio??0} size=${34} stroke=${4} />
                <${ye} status=${t.statusRaw??"unknown"} />
                ${t.stateLabel?i`<span class="monitor-pill ${t.tone}">${t.stateLabel}</span>`:null}
              `:i`<span class="command-chip ${t.tone}">${t.statusLabel}</span>`}
        </div>

        <div class=${n==="mission"?"mission-activity-meta":"monitor-meta"}>
          ${t.lastActivityAt?i`<span>최근 활동 <${X} timestamp=${t.lastActivityAt} /></span>`:i`<span>${t.lastActivityFallback??"최근 활동 없음"}</span>`}
          ${t.relatedSessionId?i`<span>세션 · ${t.relatedSessionId}</span>`:null}
          ${t.continuity?i`<span>${t.continuity}</span>`:null}
          ${t.lifecycle?i`<span>생애주기 ${t.lifecycle}</span>`:null}
          <span>컨텍스트 ${zy(t.contextRatio)}</span>
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
              ${(((m=t.recentTools)==null?void 0:m.length)??0)>0||(((p=t.allowedTools)==null?void 0:p.length)??0)>0?i`
                    <div class="mission-activity-foot">
                      <span>최근 도구 · ${Kl(t.recentTools)}</span>
                      <span>허용 도구 · ${Kl(t.allowedTools)}</span>
                    </div>
                  `:null}
            </details>
          `:null}
    </article>
  `}const Te=g(null),Xt=g(null),Qt=g(null);function us(t){return t==="bad"||t==="critical"||t==="offline"?"bad":t==="warn"||t==="paused"||t==="blocked"||t==="interrupted"?"warn":"ok"}function ps(t){switch((t??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":return"주의";case"bad":case"critical":return"위험";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Py(t){return t==="session"?"세션":"작전"}function Ny(t){return t?ae.value.find(e=>e.name===t||e.agent_name===t)??null:null}function jy(t){switch(t){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function wy(t){switch(t){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function Oy(t){switch(t){case"acted":return"행동";case"passed":return"통과";case"skipped":return"건너뜀";case"failed":return"실패";default:return t}}function Dy(t){switch(t){case"post":return"post";case"comment":return"comment";case"vote":return"vote";case"none":case null:case void 0:return"none";default:return t}}function Bl(t){if(!t)return;const e=If({targetType:t.target_type,targetId:t.target_id,focusKind:t.focus_kind,operationId:t.operation_id??null,commandSurface:t.command_surface??null,sourceLabel:"실행 진단",summary:t.label});bd(e),it(t.surface,t.surface==="intervene"?kd(e):Sd(e))}function Rn({label:t,value:e,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function $r({intervene:t,command:e}){return i`
    <div class="control-row">
      ${t?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),Bl(t)}}
            >
              ${t.label}
            </button>
          `:null}
      ${e?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),Bl(e)}}
            >
              ${e.label}
            </button>
          `:null}
    </div>
  `}function qy({item:t,selected:e}){return i`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{Te.value=e?null:t.id,Xt.value=null,Qt.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.kind==="session"?t.target_id:t.linked_session_id??t.target_id}</div>
          <div class="mission-card-title">${t.summary}</div>
        </div>
        <span class="command-chip ${us(t.severity)}">${ps(t.status??t.severity)}</span>
      </div>
      <div class="mission-card-meta">
        <span>${Py(t.kind)}</span>
        ${t.linked_operation_id?i`<span>연결 작전 · ${t.linked_operation_id}</span>`:null}
        ${t.last_seen_at?i`<span><${X} timestamp=${t.last_seen_at} /></span>`:null}
      </div>
      <${$r} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function Fy({brief:t,selected:e}){return i`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.session-card"
      onClick=${()=>{Xt.value=e?null:t.session_id,Qt.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          <div class="mission-card-title">${t.goal}</div>
        </div>
        <span class="command-chip ${us(t.health??t.status)}">${ps(t.status)}</span>
      </div>
      <div class="mission-card-meta">
        <span>건강도 · ${ps(t.health??"ok")}</span>
        ${t.linked_operation_id?i`<span>연결 작전 · ${t.linked_operation_id}</span>`:null}
        ${t.last_activity_at?i`<span><${X} timestamp=${t.last_activity_at} /></span>`:null}
      </div>
      ${t.runtime_blocker?i`<div class="mission-card-detail">${t.runtime_blocker}</div>`:t.last_activity_summary?i`<div class="mission-card-detail">${t.last_activity_summary}</div>`:null}
      ${t.worker_gap_summary?i`<div class="monitor-footnote">${t.worker_gap_summary}</div>`:null}
      <${$r} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function Ky({brief:t,selected:e}){return i`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.operation-card"
      onClick=${()=>{Qt.value=e?null:t.operation_id,Xt.value=t.linked_session_id??null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.operation_id}${t.assigned_unit_label?` · ${t.assigned_unit_label}`:""}</div>
          <div class="mission-card-title">${t.objective}</div>
        </div>
        <span class="command-chip ${us(t.blocker_summary?"warn":t.status)}">${ps(t.status)}</span>
      </div>
      <div class="mission-card-meta">
        ${t.stage?i`<span>단계 · ${t.stage}</span>`:null}
        ${t.linked_session_id?i`<span>세션 · ${t.linked_session_id}</span>`:null}
        ${t.updated_at?i`<span><${X} timestamp=${t.updated_at} /></span>`:null}
      </div>
      ${t.blocker_summary?i`<div class="mission-card-detail">${t.blocker_summary}</div>`:null}
      ${t.next_tool?i`<div class="monitor-footnote">다음 도구 · ${t.next_tool}</div>`:null}
      <${$r} command=${t.command_handoff} />
    </button>
  `}function By({tick:t}){return t?i`
    <div class="monitor-nested-card">
      <div class="stats-grid">
        <${Rn} label="checked" value=${t.checked??0} color="#22d3ee" />
        <${Rn} label="acted" value=${t.acted??0} color="#4ade80" />
        <${Rn} label="passed" value=${t.passed??0} color="#94a3b8" />
        <${Rn} label="skipped" value=${t.skipped??0} color="#fbbf24" />
        <${Rn} label="failed" value=${t.failed??0} color="#fb7185" />
      </div>
      <div class="monitor-meta">
        ${t.last_tick_at?i`<span>마지막 tick <${X} timestamp=${t.last_tick_at} /></span>`:i`<span>마지막 tick 없음</span>`}
        ${t.last_skip_reason?i`<span>대표 skip 이유 · ${t.last_skip_reason}</span>`:null}
      </div>
      ${t.activity_report?i`<div class="monitor-footnote">${t.activity_report}</div>`:null}
    </div>
  `:i`<div class="empty-state">최근 lodge tick 기록이 없습니다.</div>`}function Uy({row:t}){return i`
    <button
      class="monitor-row ${us(t.outcome==="failed"?"bad":t.outcome==="skipped"?"warn":"ok")}"
      data-testid="execution.lodge-checkin-card"
      onClick=${()=>Ss(t.agent_name)}
    >
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.agent_name}</span>
            ${t.worker_name?i`<span class="monitor-sub">worker · ${t.worker_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.reason??t.summary??"이유가 기록되지 않았습니다."}</div>
        </div>
        <span class="monitor-pill ${us(t.outcome==="failed"?"bad":t.outcome==="skipped"?"warn":"ok")}">${Oy(t.outcome)}</span>
      </div>
      <div class="monitor-meta">
        <span>trigger · ${t.trigger??"unknown"}</span>
        ${t.checked_at?i`<span><${X} timestamp=${t.checked_at} /></span>`:null}
        <span>action · ${Dy(t.action_kind)}</span>
      </div>
      ${t.summary&&t.summary!==t.reason?i`<div class="monitor-focus">${t.summary}</div>`:null}
      ${t.failure_reason||t.decision_reason?i`<div class="monitor-footnote">
            ${t.failure_reason?`실패 이유: ${t.failure_reason}`:`판단 이유: ${t.decision_reason}`}
          </div>`:null}
    </button>
  `}function Ul({row:t,testId:e}){return i`
    <button class="monitor-row ${t.tone} state-${t.state}" data-testid=${e} onClick=${()=>Ss(t.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.name}</span>
            ${t.korean_name?i`<span class="monitor-sub">${t.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${ye} status=${t.status??"unknown"} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${jy(t.state)}</span>
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
  `}function Hy({row:t}){const e=()=>{const a=Ny(t.name);a&&jd(a)},n=Vf(t.name,t.agent_name),s={name:t.name,koreanName:t.korean_name??null,runtimeLabel:n,emoji:t.emoji??null,tone:t.tone,statusRaw:t.status??null,statusLabel:ps(t.status),stateClass:t.state,stateLabel:wy(t.state),contextRatio:t.context_ratio??null,note:t.note,focus:t.focus,lastActivityAt:t.last_signal_at??null,lastActivityFallback:"최근 활동 없음",relatedSessionId:t.related_session_id??null,continuity:t.continuity??null,lifecycle:t.lifecycle??null,summary:t.continuity_summary??t.recent_output_preview??null,recentInput:t.recent_input_preview??null,recentOutput:t.recent_output_preview??null,recentTools:t.recent_tool_names??[],allowedTools:t.allowed_tool_names??[],routeSummary:t.skill_route_summary??null,auditSource:t.tool_audit_source??null,auditAt:t.tool_audit_at??null,disclosureLabel:"연속성 상세"};return i`<${Ey}
    variant="execution"
    model=${s}
    onClick=${e}
    testId="execution.continuity-card"
  />`}function Wy(){const t=xc.value,e=Sc.value,n=Cc.value,s=Ac.value,a=Tc.value,o=Ic.value,l=Bo.value,c=Rc.value;Te.value&&!t.some($=>$.id===Te.value)&&(Te.value=null),Xt.value&&!e.some($=>$.session_id===Xt.value)&&(Xt.value=null),Qt.value&&!n.some($=>$.operation_id===Qt.value)&&(Qt.value=null);const u=Te.value?t.find($=>$.id===Te.value)??null:null,m=Xt.value?Xt.value:u?u.kind==="session"?u.target_id:u.linked_session_id??null:null,p=Qt.value?Qt.value:u?u.kind==="operation"?u.target_id:u.linked_operation_id??null:null,v=m?e.filter($=>$.session_id===m):p?e.filter($=>$.linked_operation_id===p):e,f=p?n.filter($=>$.operation_id===p):m?n.filter($=>{var z;return $.linked_session_id===m||$.operation_id===((z=v[0])==null?void 0:z.linked_operation_id)}):n,h=m||p?s.filter($=>(m?$.related_session_id===m:!1)||(p?$.related_operation_id===p:!1)):s,A=m?l.filter($=>$.related_session_id===m||$.tone!=="ok"):l,b=m?o.filter($=>v.some(z=>z.member_names.includes($.agent_name))):o,k=m||p?c.filter($=>(m?$.related_session_id===m:!1)||(p?$.related_operation_id===p:!1)||$.tone!=="ok"):c;return i`
    <div class="agents-monitor">
      <${Ct} surfaceId="execution" />
      <${ur} />
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
          ${t.length===0?i`<div class="empty-state">지금은 막힌 실행이 없습니다.</div>`:t.map($=>i`<${qy} key=${$.id} item=${$} selected=${Te.value===$.id} />`)}
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
            ${v.length===0?i`<div class="empty-state">선택된 실행과 연결된 세션이 없습니다.</div>`:v.map($=>i`<${Fy} key=${$.session_id} brief=${$} selected=${Xt.value===$.session_id} />`)}
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
            ${f.length===0?i`<div class="empty-state">선택된 실행과 연결된 작전이 없습니다.</div>`:f.map($=>i`<${Ky} key=${$.operation_id} brief=${$} selected=${Qt.value===$.operation_id} />`)}
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
          <${By} tick=${a} />
          <div class="monitor-list">
            ${b.length===0?i`<div class="empty-state">최근 lodge check-in 기록이 없습니다.</div>`:b.map($=>i`<${Uy} key=${`${$.agent_name}-${$.checked_at??$.outcome}`} row=${$} />`)}
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
            ${h.length===0?i`<div class="empty-state">연결된 작업자가 없습니다.</div>`:h.map($=>i`<${Ul} key=${$.name} row=${$} testId="execution.worker-card" />`)}
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
            ${A.length===0?i`<div class="empty-state">지금은 연속성 경고가 없습니다.</div>`:A.map($=>i`<${Hy} key=${$.name} row=${$} />`)}
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
            ${k.length===0?i`<div class="empty-state">지금은 오프라인 작업자가 없습니다.</div>`:k.map($=>i`<${Ul} key=${$.name} row=${$} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const xo=g(null),So=g(null),Kn=g(!1);async function Hl(){if(!Kn.value){Kn.value=!0,So.value=null;try{xo.value=await gp()}catch(t){So.value=t instanceof Error?t.message:String(t)}finally{Kn.value=!1}}}function Gy(t){switch(t){case"essential":return"badge-essential";case"standard":return"badge-standard";default:return"badge-full"}}function Jy({items:t,maxCount:e}){return t.length===0?i`<p class="muted">No tool calls recorded yet.</p>`:i`
    <div class="tool-bar-chart">
      ${t.map(n=>{const s=e>0?n.call_count/e*100:0;return i`
          <div class="tool-bar-row" key=${n.name}>
            <span class="tool-bar-name">${n.name}</span>
            <span class="tool-bar-tier ${Gy(n.tier)}">${n.tier}</span>
            <div class="tool-bar-track">
              <div class="tool-bar-fill" style=${{width:`${s}%`}} />
            </div>
            <span class="tool-bar-count">${n.call_count}</span>
          </div>
        `})}
    </div>
  `}function Vy({dist:t}){const e=t.full,n=e>0?(t.essential/e*100).toFixed(1):"0",s=e>0?(t.standard/e*100).toFixed(1):"0",a=e-t.standard,o=e>0?(a/e*100).toFixed(1):"0";return i`
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
  `}function Yy(){const t=xo.value,e=Kn.value,n=So.value;return nt(()=>{!xo.value&&!Kn.value&&Hl()},[]),i`
    <div class="tool-metrics">
      <div class="tool-metrics-header">
        <h3 class="tool-metrics-title">Tool Usage</h3>
        <button
          class="control-btn ghost"
          onClick=${()=>void Hl()}
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
            <${Vy} dist=${t.tier_distribution} />
          </div>
          <div class="tool-metrics-section">
            <h4>Top 20 Tools</h4>
            <${Jy}
              items=${t.top_20}
              maxCount=${t.top_20.length>0?t.top_20[0].call_count:0}
            />
          </div>
        </div>
      `:e?null:i`
        <p class="muted">Click Load to fetch tool usage statistics.</p>
      `}
    </div>
  `}const Co=g(null),Ao=g(null),Bn=g(!1),Mn=g(""),Fs=g("all"),Ii=g(!1),Ri=g(!1),Mi=g(!0),Li=g(!0);async function Wl(){if(!Bn.value){Bn.value=!0,Ao.value=null;try{Co.value=await $p()}catch(t){Ao.value=t instanceof Error?t.message:String(t)}finally{Bn.value=!1}}}function Xy(t,e){const n=e.trim().toLowerCase();return n?[t.name,t.description,t.category,t.required_permission??"",t.visibility,t.lifecycle,t.implementationStatus,t.tier,t.canonicalName??"",t.replacement??"",t.reason??"",...t.doc_refs,...t.prompt_hints].join(" ").toLowerCase().includes(n):!0}function Ks(t,e="default"){return i`
    <span
      style=${{fontSize:"11px",color:e==="ok"?"#7dd3fc":e==="warn"?"#fbbf24":"#cbd5e1",background:e==="ok"?"rgba(14, 165, 233, 0.18)":e==="warn"?"rgba(245, 158, 11, 0.18)":"rgba(148, 163, 184, 0.16)",borderRadius:"999px",padding:"2px 8px"}}
    >
      ${t}
    </span>
  `}function Qy({item:t}){return i`
    <article class="tool-inventory-row">
      <div class="tool-inventory-head">
        <div>
          <div class="tool-inventory-name">${t.name}</div>
          <div class="tool-inventory-desc">${t.description}</div>
        </div>
        <div class="tool-inventory-badges">
          ${Ks(t.tier,t.tier==="essential"?"ok":t.tier==="standard"?"warn":"default")}
          ${Ks(t.visibility)}
          ${Ks(t.lifecycle,t.lifecycle==="deprecated"?"warn":"default")}
          ${Ks(t.implementationStatus)}
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
  `}function Zy(){const t=Co.value,e=Bn.value,n=Ao.value,s=(t==null?void 0:t.tool_inventory.tools)??[],a=(t==null?void 0:t.tool_usage)??null;nt(()=>{!Co.value&&!Bn.value&&Wl()},[]),nt(()=>{var h;if(O.value.tab!=="tools")return;const f=(h=O.value.params.q)==null?void 0:h.trim();f&&f!==Mn.value&&(Mn.value=f)},[O.value.tab,O.value.params.q]);const o=Array.from(new Set(s.map(f=>f.category))).sort((f,h)=>f.localeCompare(h)),l=s.filter(f=>!(!Xy(f,Mn.value)||Fs.value!=="all"&&f.category!==Fs.value||Ii.value&&!f.enabled_in_current_mode||Ri.value&&!f.direct_call_allowed||!Mi.value&&f.visibility==="hidden"||!Li.value&&f.lifecycle==="deprecated")),c=s.length,u=s.filter(f=>f.enabled_in_current_mode).length,m=s.filter(f=>f.visibility==="hidden").length,p=s.filter(f=>f.lifecycle==="deprecated").length,v=s.filter(f=>f.direct_call_allowed).length;return i`
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
            <span class="stat-value">${u}</span>
            <span class="stat-label">Mode enabled</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${m}</span>
            <span class="stat-label">Hidden</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${p}</span>
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
            value=${Mn.value}
            onInput=${f=>{Mn.value=f.target.value}}
          />
          <select
            class="control-select"
            value=${Fs.value}
            onChange=${f=>{Fs.value=f.target.value}}
          >
            <option value="all">All categories</option>
            ${o.map(f=>i`<option value=${f}>${f}</option>`)}
          </select>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${Ii.value}
              onChange=${f=>{Ii.value=f.target.checked}}
            />
            <span>Enabled only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${Ri.value}
              onChange=${f=>{Ri.value=f.target.checked}}
            />
            <span>Direct-call only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${Mi.value}
              onChange=${f=>{Mi.value=f.target.checked}}
            />
            <span>Show hidden</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${Li.value}
              onChange=${f=>{Li.value=f.target.checked}}
            />
            <span>Show deprecated</span>
          </label>
          <button class="control-btn ghost" onClick=${()=>{Wl()}} disabled=${e}>
            ${e?"Refreshing…":"Refresh inventory"}
          </button>
        </div>

        ${n?i`<div class="tool-metrics-error">${n}</div>`:null}

        <div class="tool-inventory-list">
          ${l.length>0?l.map(f=>i`<${Qy} key=${f.name} item=${f} />`):i`<div class="empty-state">No tools matched the current filters.</div>`}
        </div>
      <//>

      <${R} title="Tool Usage" class="section">
        ${a?i`
              <div class="tool-inventory-usage-hint">
                Registered ${a.registered_count} · Distinct called ${a.distinct_tools_called} · Never called ${a.never_called_count}
              </div>
            `:null}
        <${Yy} />
      <//>
    </div>
  `}const Ua=g("all"),Ha=g("all"),To=g(new Set);function tb(t){const e=new Set(To.value);e.has(t)?e.delete(t):e.add(t),To.value=e}const lu=Pt(()=>{let t=on.value;return Ua.value!=="all"&&(t=t.filter(e=>e.horizon===Ua.value)),Ha.value!=="all"&&(t=t.filter(e=>e.status===Ha.value)),t}),eb=Pt(()=>{const t={short:[],mid:[],long:[]};for(const e of lu.value){const n=t[e.horizon];n&&n.push(e)}return t}),nb=Pt(()=>{const t=Array.from(Lc.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function sb(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function hr(t){switch(t){case"short":return"단기";case"mid":return"중기";case"long":return"장기";default:return t}}function ca(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function ab(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Gl(t){return t.toFixed(4)}function Jl(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function ib(t){switch(t){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function ob(t){switch(t){case"active":return"진행 중";case"completed":return"완료";case"paused":return"일시정지";default:return"전체"}}function Vl(t,e){return(t.priority??4)-(e.priority??4)}function rb(t,e){const n=t.updated_at??t.created_at??"";return(e.updated_at??e.created_at??"").localeCompare(n)}function lb(t,e){return t.length<=e?t:t.slice(0,e)+"..."}function cb({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ca(t.horizon)}">
            ${hr(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${sb(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${X} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${ye} status=${t.status} />
        <div class="goal-updated">
          <${X} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function zi({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return i`
    <${R} title="${hr(t)} 목표 (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${cb} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function db(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">범위</label>
        ${["all","short","mid","long"].map(t=>i`
          <button
            class="goal-filter-btn ${Ua.value===t?"active":""}"
            onClick=${()=>{Ua.value=t}}
          >
            ${t==="all"?"전체":hr(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">상태</label>
        ${["all","active","completed","paused"].map(t=>i`
          <button
            class="goal-filter-btn ${Ha.value===t?"active":""}"
            onClick=${()=>{Ha.value=t}}
          >
            ${ob(t)}
          </button>
        `)}
      </div>
    </div>
  `}function ub(){const t=on.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return i`
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
        <div class="goal-summary-value" style="color:${ca("short")}">${s.short}</div>
        <div class="goal-summary-label">단기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ca("mid")}">${s.mid}</div>
        <div class="goal-summary-label">중기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ca("long")}">${s.long}</div>
        <div class="goal-summary-label">장기</div>
      </div>
    </div>
  `}function pb({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length}개 도구: ${t.latest_tool_names.join(", ")}`:"아직 근거 없음";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${ye} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Gl(t.baseline_metric)}</span>
          <span>현재 ${Gl(t.current_metric)}</span>
          <span class=${Jl(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Jl(t)}
          </span>
          <span>Elapsed ${ab(t.elapsed_seconds)}</span>
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
  `}function Ei({task:t}){const e=t.priority??4,n=e<=1?"p1":e===2?"p2":e===3?"p3":"p4",s=To.value.has(t.id),a=!!t.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${ib(e)}</span>
        <div class="kanban-card-title">${t.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>tb(t.id)}
        >
          ${s?t.description:lb(t.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${t.created_at?i`<${X} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function mb(){const{todo:t,inProgress:e,done:n}=Ec.value,s=[...t].sort(Vl),a=[...e].sort(Vl),o=[...n].sort(rb);return i`
    <${R} title="태스크 백로그" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>할 일</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">대기 중인 태스크가 없습니다</div>`:s.map(l=>i`<${Ei} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>진행 중</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">진행 중인 태스크가 없습니다</div>`:a.map(l=>i`<${Ei} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>완료</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">완료된 태스크가 없습니다</div>`:o.slice(0,20).map(l=>i`<${Ei} key=${l.id} task=${l} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...외 ${o.length-20}개 더 있음</div>`:null}
        </div>
      </div>
    <//>
  `}function _b(){const{todo:t,inProgress:e,done:n}=Ec.value,s=t.length+e.length+n.length,a=[...t,...e].filter(p=>(p.priority??4)<=2).length,o=eb.value,l=nb.value,c=on.value.length>0,u=l.length>0,m=Uo.value;return i`
    <div>
      <${Ct} surfaceId="planning" />

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
          onClick=${()=>{Go(),Dc()}}
          disabled=${Nn.value||jn.value}
        >
          ${Nn.value||jn.value?"새로고침 중...":"계획 데이터 새로고침"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${mb} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          목표 파이프라인
          <span class="monitor-pill">${on.value.length}</span>
        </summary>
        <div>
          ${c?i`
            <${ub} />
            <${db} />
            ${Nn.value&&on.value.length===0?i`<div class="loading-indicator">목표 불러오는 중...</div>`:lu.value.length===0?i`<div class="empty-state">현재 필터에 맞는 목표가 없습니다</div>`:i`
                    <${zi} horizon="short" items=${o.short??[]} />
                    <${zi} horizon="mid" items=${o.mid??[]} />
                    <${zi} horizon="long" items=${o.long??[]} />
                  `}
          `:i`
            <div class="empty-state">
              정의된 목표가 없습니다. <code>masc_goal_upsert</code>로 목표를 만들 수 있습니다.
            </div>
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible" open=${u}>
        <summary>
          MDAL 루프
          <span class="monitor-pill">${l.length}</span>
        </summary>
        <div>
          ${jn.value&&l.length===0?i`<div class="loading-indicator">MDAL 루프 불러오는 중...</div>`:l.length===0&&(m==="error"||rn.value)?i`<div class="empty-state">MDAL 스냅샷을 불러오지 못했습니다${rn.value?`: ${rn.value}`:""}. 백엔드 상태를 확인하세요.</div>`:l.length===0?i`<div class="empty-state">가동 중인 루프가 없습니다. <code>masc_mdal_start</code>로 시작할 수 있습니다.</div>`:i`
                  <div class="planning-loop-list">
                    ${l.map(p=>i`<${pb} key=${p.loop_id} loop=${p} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const Wa=g(!1),Un=g(!1),sn=g(!1),Ga=g(!1),se=g(""),Hn=g(""),Wn=g(""),Io=g("support"),Ro=g("open"),yn=g(null),ms=g(null),_s=g(null),Mo=g(!1);function vs(t){return`${t.kind}:${t.id}`}function ri(){var n;const t=ms.value,e=((n=yn.value)==null?void 0:n.items)??[];return t?e.find(s=>vs(s)===t)??null:null}function vb(t){const e=t.trim().toLowerCase();return e!=="executed"&&e!=="blocked"&&e!=="closed"}function cu(t){switch(Ro.value){case"pending_ruling":return t.filter(e=>e.status==="pending_ruling");case"needs_human_gate":return t.filter(e=>e.status==="needs_human_gate");case"executed":return t.filter(e=>e.status==="executed");case"blocked":return t.filter(e=>e.status==="blocked"||e.status==="closed");case"open":default:return t.filter(e=>vb(e.status))}}function fb(t){if(t==null)return"없음";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function yr(t){const e=(t||"").toLowerCase();return e.includes("block")||e.includes("deny")||e.includes("closed")?"negative":e.includes("support")||e.includes("approve")||e.includes("ready")||e.includes("executed")||e.includes("done")?"positive":"neutral"}function gb(t){return typeof t!="number"||Number.isNaN(t)?"판정 대기":`${Math.round(t*100)}%`}async function du(t){if(_s.value=null,!!t){Mo.value=!0,se.value="";try{_s.value=await $c(t.id)}catch(e){se.value=e instanceof Error?e.message:"거버넌스 상세를 불러오지 못했습니다"}finally{Mo.value=!1}}}async function $b(t){ms.value=vs(t),await du(t)}async function Fe(){Wa.value=!0,se.value="";try{const t=await dp();yn.value=t;const e=cu(t.items??[]),n=ms.value,s=e.find(a=>vs(a)===n)??e[0]??null;ms.value=s?vs(s):null,await du(s)}catch(t){se.value=t instanceof Error?t.message:"거버넌스 상태를 불러오지 못했습니다"}finally{Wa.value=!1}}P_(Fe);async function Yl(){const t=Hn.value.trim();if(t){Un.value=!0;try{const e=await mm(t);Hn.value="",j(e!=null&&e.case.id?`청원을 접수했습니다: ${e.case.id}`:"청원을 접수했습니다","success"),await Fe()}catch(e){const n=e instanceof Error?e.message:"청원 접수에 실패했습니다";se.value=n,j(n,"error")}finally{Un.value=!1}}}async function hb(){const t=ri(),e=Wn.value.trim();if(!(!t||!e)){Ga.value=!0;try{const n=await _m(t.id,Io.value,e);Wn.value="",_s.value=n,j("심의 의견을 기록했습니다","success"),await Fe()}catch(n){const s=n instanceof Error?n.message:"심의 기록에 실패했습니다";se.value=s,j(s,"error")}finally{Ga.value=!1}}}async function Xl(t){const e=ri();if(e){sn.value=!0;try{await vm(e.id,t),j(t==="confirm"?"집행을 승인했습니다":"집행을 거부했습니다","success"),await Fe()}catch(n){const s=n instanceof Error?n.message:"집행 결정을 처리하지 못했습니다";se.value=s,j(s,"error")}finally{sn.value=!1}}}function yb(){var e,n,s;const t=(e=yn.value)==null?void 0:e.summary;return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">열린 케이스</span>
        <strong>${(t==null?void 0:t.cases_open)??((s=(n=yn.value)==null?void 0:n.items)==null?void 0:s.length)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">판정 대기</span>
        <strong>${(t==null?void 0:t.pending_ruling)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">자동집행 준비</span>
        <strong>${(t==null?void 0:t.ready_auto_execute)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">사람 승인 대기</span>
        <strong>${(t==null?void 0:t.needs_human_gate)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">집행 완료</span>
        <strong>${(t==null?void 0:t.executed)??0}</strong>
      </div>
    </div>
  `}function bb(){return i`
    <${R} title="청원 콘솔" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="청원 제목을 입력하세요..."
            value=${Hn.value}
            onInput=${t=>{Hn.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&Yl()}}
            disabled=${Un.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Yl}
            disabled=${Un.value||Hn.value.trim()===""}
          >
            ${Un.value?"접수 중...":"청원 접수"}
          </button>
          <button class="control-btn ghost" onClick=${Fe} disabled=${Wa.value}>
            ${Wa.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
        <div class="governance-filter-row">
          ${[["open","진행 중"],["pending_ruling","판정 대기"],["needs_human_gate","승인 대기"],["executed","집행 완료"],["blocked","보류/종결"]].map(([t,e])=>i`
            <button
              class="control-btn ${Ro.value===t?"is-active":"ghost"}"
              onClick=${async()=>{Ro.value=t,await Fe()}}
            >
              ${e}
            </button>
          `)}
        </div>
        ${se.value?i`<div class="council-error">${se.value}</div>`:null}
      </div>
    <//>
  `}function kb(){var e;const t=cu(((e=yn.value)==null?void 0:e.items)??[]);return i`
    <${R} title="사건 수신함" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${t.length===0?i`<div class="empty-state">지금 필터에 맞는 사건이 없습니다.</div>`:t.map(n=>{const s=ms.value===vs(n);return i`
                <button
                  class="council-row governance-decision-row ${s?"selected":""}"
                  onClick=${()=>$b(n)}
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
                      ${n.origin?i`<span class="governance-chip dim">${n.origin}</span>`:null}
                      ${n.risk_class?i`<span class="governance-chip">${n.risk_class}</span>`:null}
                      ${n.provenance?i`<span class="governance-chip">${n.provenance}</span>`:null}
                      ${n.status==="needs_human_gate"?i`<span class="governance-chip warn">사람 승인 필요</span>`:null}
                      ${n.status==="executed"?i`<span class="governance-chip ok">집행 완료</span>`:null}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${yr(n.status)}">${n.status}</span>
                    <span class="governance-vote-meter">${n.brief_count??0} briefs</span>
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function xb({petition:t}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge neutral">petition</span>
        <strong>${t.created_by||t.origin||"system"}</strong>
        ${t.created_at?i`<span><${X} timestamp=${t.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${t.title}</div>
      <div class="governance-chip-row">
        ${t.source_refs.map(e=>i`<span class="governance-chip">${e}</span>`)}
      </div>
    </div>
  `}function Sb({brief:t}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${yr(t.stance)}">${t.stance}</span>
        <strong>${t.author}</strong>
        ${t.created_at?i`<span><${X} timestamp=${t.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${t.summary}</div>
      <div class="governance-chip-row">
        ${t.evidence_refs.map(e=>i`<span class="governance-chip">${e}</span>`)}
      </div>
    </div>
  `}function Cb(){var a;const t=ri(),e=_s.value,n=(e==null?void 0:e.petitions)??[],s=(e==null?void 0:e.case.briefs)??[];return i`
    <${R}
      title=${t?"사건 상세":"거버넌스 상세"}
      class="section"
      semanticId="governance.detail"
    >
      ${Mo.value?i`<div class="loading-indicator">거버넌스 상세 불러오는 중...</div>`:!t||!e?i`<div class="empty-state">사건을 고르면 청원, 심의, 판정, 집행 기록을 볼 수 있습니다.</div>`:i`
              <div class="governance-detail-head">
                <div>
                  <h3>${e.case.title}</h3>
                  <div class="council-sub">
                    <span>${e.case.id}</span>
                    <span>${e.case.status}</span>
                    ${e.case.updated_at?i`<span><${X} timestamp=${e.case.updated_at} /></span>`:null}
                  </div>
                </div>
                <div class="governance-balance-grid">
                  <span class="governance-balance"><strong>${n.length}</strong> petitions</span>
                  <span class="governance-balance"><strong>${s.length}</strong> briefs</span>
                  <span class="governance-balance"><strong>${t.confidence!=null?Math.round(t.confidence*100):0}</strong>% ruling</span>
                  <span class="governance-balance"><strong>${((a=e.execution_order)==null?void 0:a.status)||"none"}</strong></span>
                </div>
              </div>
              <div class="governance-ledger">
                ${n.length===0?i`<div class="empty-state">기록된 청원이 없습니다.</div>`:n.map(o=>i`<${xb} key=${o.id} petition=${o} />`)}
              </div>
              <div class="governance-ledger">
                ${s.length===0?i`<div class="empty-state">심의 brief가 아직 없습니다.</div>`:s.map(o=>i`<${Sb} key=${o.id} brief=${o} />`)}
              </div>
            `}
    <//>
  `}function Ab({order:t}){if(!(t!=null&&t.action_request))return null;const e=t.action_request;return i`
    <div class="governance-side-block">
      <h4>집행 명령</h4>
      <div class="council-sub">
        <span>${e.resolved_tool||e.action_kind||e.target_type||"action"}</span>
        <span>${t.status}</span>
      </div>
      ${e.target_type?i`<div class="governance-side-line">대상 ${e.target_type}${e.target_id?`:${e.target_id}`:""}</div>`:null}
      ${e.reason?i`<div class="governance-side-line">${e.reason}</div>`:null}
      ${e.payload_preview?i`<pre class="council-detail governance-preview">${fb(e.payload_preview)}</pre>`:null}
      ${t.execution_ref?i`<div class="governance-side-line">결과 참조 ${t.execution_ref}</div>`:null}
      ${t.result_summary?i`<div class="governance-side-line">${t.result_summary}</div>`:null}
    </div>
  `}function Tb(){const t=ri(),e=_s.value,n=e==null?void 0:e.ruling,s=e==null?void 0:e.execution_order;return i`
    <div class="governance-side-column">
      <${R} title="판정 / 집행" class="section" semanticId="governance.guardrail">
        ${!t||!e?i`<div class="empty-state">사건을 고르면 판정과 집행 경로가 보입니다.</div>`:i`
              <div class="governance-side-block">
                <h4>판정</h4>
                <div class="council-sub">
                  <span>${(n==null?void 0:n.status)||"pending"}</span>
                  <span>${gb(n==null?void 0:n.confidence)}</span>
                  ${n!=null&&n.generated_at?i`<span><${X} timestamp=${n.generated_at} /></span>`:null}
                </div>
                ${n!=null&&n.summary?i`<div class="governance-summary-callout">${n.summary}</div>`:i`<div class="governance-side-line">아직 ruling이 생성되지 않았습니다.</div>`}
                <div class="governance-chip-row">
                  ${t.provenance?i`<span class="governance-chip">${t.provenance}</span>`:null}
                  ${t.risk_class?i`<span class="governance-chip">${t.risk_class}</span>`:null}
                  ${t.subject_type?i`<span class="governance-chip dim">${t.subject_type}</span>`:null}
                </div>
              </div>
              <${Ab} order=${s} />
              ${(s==null?void 0:s.status)==="needs_human_gate"?i`
                    <div class="governance-side-block">
                      <h4>사람 승인</h4>
                      <div class="governance-side-line">이 집행은 고위험으로 분류되어 수동 결재가 필요합니다.</div>
                      <div class="governance-action-row">
                        <button class="control-btn secondary" onClick=${()=>Xl("confirm")} disabled=${sn.value}>
                          ${sn.value?"처리 중...":"승인"}
                        </button>
                        <button class="control-btn ghost" onClick=${()=>Xl("deny")} disabled=${sn.value}>
                          ${sn.value?"처리 중...":"거부"}
                        </button>
                      </div>
                    </div>
                  `:null}
            `}
    <//>
      <${R} title="심의 입력" class="section" semanticId="governance.context">
        ${t?i`
              <div class="governance-side-block">
                <div class="governance-filter-row">
                  ${["support","oppose","neutral"].map(a=>i`
                    <button
                      class="control-btn ${Io.value===a?"is-active":"ghost"}"
                      onClick=${()=>{Io.value=a}}
                    >
                      ${a}
                    </button>
                  `)}
                </div>
                <textarea
                  class="control-input"
                  rows=${5}
                  placeholder="이 사건에 대한 brief를 입력하세요..."
                  value=${Wn.value}
                  onInput=${a=>{Wn.value=a.target.value}}
                ></textarea>
                <div class="governance-action-row">
                  <button
                    class="control-btn secondary"
                    onClick=${hb}
                    disabled=${Ga.value||Wn.value.trim()===""}
                  >
                    ${Ga.value?"기록 중...":"brief 추가"}
                  </button>
                </div>
              </div>
            `:i`<div class="empty-state">사건을 선택한 뒤 brief를 추가하세요.</div>`}
      <//>
    </div>
  `}function Ib(){var e;const t=(((e=yn.value)==null?void 0:e.activity)??[]).slice(0,8);return i`
    <${R} title="최근 활동" class="section" semanticId="governance.activity">
      <div class="governance-activity-list">
        ${t.length===0?i`<div class="empty-state">기록된 활동이 아직 없습니다.</div>`:t.map(n=>i`
              <div class="governance-activity-row">
                <div class="governance-ledger-head">
                  <span class="governance-badge ${yr(n.kind)}">${n.kind}</span>
                  ${n.created_at?i`<span><${X} timestamp=${n.created_at} /></span>`:null}
                </div>
                <div class="governance-ledger-body">${n.summary||n.topic||"활동이 기록되었습니다."}</div>
              </div>
            `)}
      </div>
    <//>
  `}function Rb(){return nt(()=>{Fe()},[]),i`
    <div class="section-grid">
      <${Ct} surfaceId="governance" />
      <${yb} />
      <${bb} />
      <div class="governance-layout">
        <${kb} />
        <${Cb} />
        <${Tb} />
      </div>
      <${Ib} />
    </div>
  `}const Je=g(""),Pi=g("ability_check"),Ni=g("10"),ji=g("12"),Bs=g(""),Us=g("idle"),le=g(""),Hs=g("keeper-late"),wi=g("player"),Oi=g(""),It=g("idle"),Di=g(null),Ws=g(""),qi=g(""),Fi=g("player"),Ki=g(""),Bi=g(""),Ui=g(""),Gn=g("20"),Hi=g("20"),Wi=g(""),Gs=g("idle"),Lo=g(null),uu=g("overview"),Gi=g("all"),Ji=g("all"),Vi=g("all"),Mb=12e4,li=g(null),Ql=g(Date.now());function Lb(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function zb(t,e){return e>0?Math.round(t/e*100):0}const Eb={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Pb={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Js(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Nb(t){const e=t.trim().toLowerCase();return Eb[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function jb(t){const e=t.trim().toLowerCase();return Pb[e]??"상황에 따라 선택되는 전술 액션입니다."}function xt(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Ot(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function fs(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const wb=new Set(["str","dex","con","int","wis","cha"]);function Ob(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!_(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const l=a.trim();if(l){if(typeof o=="number"&&Number.isFinite(o)){s[l]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const c=Number.parseFloat(o.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function Db(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(Gn.value.trim(),10);Number.isFinite(s)&&s>n&&(Gn.value=String(n))}function zo(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function qb(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Fb(t){uu.value=t}function pu(t){const e=li.value;return e==null||e<=t}function Kb(t){const e=li.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Ja(){li.value=null}function mu(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Bb(t,e){mu(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(li.value=Date.now()+Mb,j("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function da(t){return pu(t)?(j("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Eo(t,e,n){return mu([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Ub({hp:t,max:e}){const n=zb(t,e),s=Lb(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Hb({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Wb({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function _u({actor:t}){var u,m,p,v;const e=(u=t.archetype)==null?void 0:u.trim(),n=(m=t.persona)==null?void 0:m.trim(),s=(p=t.portrait)==null?void 0:p.trim(),a=(v=t.background)==null?void 0:v.trim(),o=t.traits??[],l=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([f,h])=>Number.isFinite(h)).filter(([f])=>!wb.has(f.toLowerCase()));return i`
    <div class="trpg-actor">
      ${s?i`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${f=>{const h=f.target;h&&(h.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${ye} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Wb} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Ub} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Hb} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${Js(e)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([f,h])=>i`
                <span class="trpg-custom-stat-chip">${Js(f)} ${h}</span>
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
                  <span class="trpg-annot-name">${Js(f)}</span>
                  <span class="trpg-annot-desc">${Nb(f)}</span>
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
                  <span class="trpg-annot-name">${Js(f)}</span>
                  <span class="trpg-annot-desc">${jb(f)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Gb({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function vu({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${qb(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${zo(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${X} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Jb({events:t}){const e="__none__",n=Gi.value,s=Ji.value,a=Vi.value,o=Array.from(new Set(t.map(zo).map(v=>v.trim()).filter(v=>v!==""))).sort((v,f)=>v.localeCompare(f)),l=Array.from(new Set(t.map(v=>(v.type??"").trim()).filter(v=>v!==""))).sort((v,f)=>v.localeCompare(f)),c=t.some(v=>(v.type??"").trim()===""),u=Array.from(new Set(t.map(v=>(v.phase??"").trim()).filter(v=>v!==""))).sort((v,f)=>v.localeCompare(f)),m=t.some(v=>(v.phase??"").trim()===""),p=t.filter(v=>{if(n!=="all"&&zo(v)!==n)return!1;const f=(v.type??"").trim(),h=(v.phase??"").trim();if(s===e){if(f!=="")return!1}else if(s!=="all"&&f!==s)return!1;if(a===e){if(h!=="")return!1}else if(a!=="all"&&h!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${v=>{Gi.value=v.target.value}}>
          <option value="all">all</option>
          ${o.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${v=>{Ji.value=v.target.value}}>
          <option value="all">all</option>
          ${c?i`<option value=${e}>(none)</option>`:null}
          ${l.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${v=>{Vi.value=v.target.value}}>
          <option value="all">all</option>
          ${m?i`<option value=${e}>(none)</option>`:null}
          ${u.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Gi.value="all",Ji.value="all",Vi.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${p.length} / 전체 ${t.length}
      </span>
    </div>
    <${vu} events=${p.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Vb({outcome:t}){if(!t)return null;const e=o=>{const l=o.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function fu({state:t}){const e=t.history??[];return e.length===0?null:i`
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
  `}function Yb({state:t,nowMs:e}){var m;const n=ee.value||((m=t.session)==null?void 0:m.room)||"",s=Us.value,a=t.party??[];if(!a.find(p=>p.id===Je.value)&&a.length>0){const p=a[0];p&&(Je.value=p.id)}const l=async()=>{var v,f;if(!n){j("Room ID가 비어 있습니다.","error");return}if(!da(e))return;const p=((v=t.current_round)==null?void 0:v.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(Eo("라운드 실행",n,p)){Us.value="running";try{const h=await nm(n);Lo.value=h,Us.value="ok";const A=_(h.summary)?h.summary:null,b=A?fs(A,"advanced",!1):!1,k=A?xt(A,"progress_reason",""):"";j(b?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${k?`: ${k}`:""}`,b?"success":"warning"),_e()}catch(h){Lo.value=null,Us.value="error";const A=h instanceof Error?h.message:"라운드 실행에 실패했습니다.";j(A,"error")}finally{Ja()}}},c=async()=>{var v,f;if(!n||!da(e))return;const p=((v=t.current_round)==null?void 0:v.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(Eo("턴 강제 진행",n,p))try{await im(n),j("턴을 다음 단계로 이동했습니다.","success"),_e()}catch{j("턴 이동에 실패했습니다.","error")}finally{Ja()}},u=async()=>{if(!n||!da(e))return;const p=Je.value.trim();if(!p){j("먼저 Actor를 선택하세요.","warning");return}const v=Number.parseInt(Ni.value,10),f=Number.parseInt(ji.value,10);if(Number.isNaN(v)||Number.isNaN(f)){j("stat/dc는 숫자여야 합니다.","warning");return}const h=Number.parseInt(Bs.value,10),A=Bs.value.trim()===""||Number.isNaN(h)?void 0:h;try{await am({roomId:n,actorId:p,action:Pi.value.trim()||"ability_check",statValue:v,dc:f,rawD20:A}),j("주사위 판정을 기록했습니다.","success"),_e()}catch{j("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${p=>{ee.value=p.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Je.value}
            onChange=${p=>{Je.value=p.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(p=>i`<option value=${p.id}>${p.name} (${p.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${Pi.value}
              onInput=${p=>{Pi.value=p.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Ni.value}
              onInput=${p=>{Ni.value=p.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${ji.value}
              onInput=${p=>{ji.value=p.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Bs.value}
              onInput=${p=>{Bs.value=p.target.value}}
              onKeyDown=${p=>{p.key==="Enter"&&u()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${u}>Roll</button>
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
  `}function Xb({state:t}){var a;const e=ee.value||((a=t.session)==null?void 0:a.room)||"",n=Gs.value,s=async()=>{if(!e){j("Room ID가 비어 있습니다.","warning");return}const o=Ws.value.trim(),l=qi.value.trim();if(!l&&!o){j("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Gn.value.trim(),10),u=Number.parseInt(Hi.value.trim(),10),m=Number.isFinite(u)?Math.max(1,u):20,p=Number.isFinite(c)?Math.max(0,Math.min(m,c)):m;let v={};try{v=Ob(Wi.value)}catch(f){j(f instanceof Error?f.message:"능력치 JSON 오류","error");return}Gs.value="spawning";try{const f=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,h=await om(e,{actor_id:o||void 0,name:l||void 0,role:Fi.value,idempotencyKey:f,portrait:Bi.value.trim()||void 0,background:Ui.value.trim()||void 0,hp:p,max_hp:m,alive:p>0,stats:Object.keys(v).length>0?v:void 0}),A=typeof h.actor_id=="string"?h.actor_id.trim():"";if(!A)throw new Error("생성 응답에 actor_id가 없습니다.");const b=Ki.value.trim();b&&await rm(e,A,b),Je.value=A,le.value=A,o||(Ws.value=""),Gs.value="ok",j(`Actor 생성 완료: ${A}`,"success"),await _e()}catch(f){Gs.value="error",j(f instanceof Error?f.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${qi.value}
            onInput=${o=>{qi.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Fi.value}
            onChange=${o=>{Fi.value=o.target.value}}
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
            value=${Ki.value}
            onInput=${o=>{Ki.value=o.target.value}}
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
              value=${Ws.value}
              onInput=${o=>{Ws.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Bi.value}
              onInput=${o=>{Bi.value=o.target.value}}
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
              value=${Gn.value}
              onInput=${o=>{Gn.value=o.target.value}}
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
              value=${Hi.value}
              onInput=${o=>{const l=o.target.value;Hi.value=l,Db(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Ui.value}
              onInput=${o=>{Ui.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Wi.value}
              onInput=${o=>{Wi.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Qb({state:t,nowMs:e}){var f;const n=ee.value||((f=t.session)==null?void 0:f.room)||"",s=t.join_gate,a=Di.value,o=_(a)?a:null,l=(t.party??[]).filter(h=>h.role!=="dm"),c=le.value.trim(),u=l.some(h=>h.id===c),m=u?c:c?"__manual__":"",p=async()=>{const h=le.value.trim(),A=Hs.value.trim();if(!n||!h){j("Room/Actor가 필요합니다.","warning");return}It.value="checking";try{const b=await lm(n,h,A||void 0);Di.value=b,It.value="ok",j("참가 가능 여부를 갱신했습니다.","success")}catch(b){It.value="error";const k=b instanceof Error?b.message:"참가 가능 여부 확인에 실패했습니다.";j(k,"error")}},v=async()=>{var $,z;const h=le.value.trim(),A=Hs.value.trim(),b=Oi.value.trim();if(!n||!h||!A){j("Room/Actor/Keeper가 필요합니다.","warning");return}if(!da(e))return;const k=(($=t.current_round)==null?void 0:$.phase)??((z=t.session)==null?void 0:z.status)??"unknown";if(Eo("Mid-Join 승인 요청",n,k)){It.value="requesting";try{const S=await cm({room_id:n,actor_id:h,keeper_name:A,role:wi.value,...b?{name:b}:{}});Di.value=S;const M=_(S)?fs(S,"granted",!1):!1,T=_(S)?xt(S,"reason_code",""):"";M?j("Mid-Join이 승인되었습니다.","success"):j(`Mid-Join이 거절되었습니다${T?`: ${T}`:""}`,"warning"),It.value=M?"ok":"error",_e()}catch(S){It.value="error";const M=S instanceof Error?S.message:"Mid-Join 요청에 실패했습니다.";j(M,"error")}finally{Ja()}}};return i`
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
            onChange=${h=>{const A=h.target.value;if(A==="__manual__"){(u||!c)&&(le.value="");return}le.value=A}}
          >
            <option value="">Actor 선택</option>
            ${l.map(h=>i`
              <option value=${h.id}>${h.name} (${h.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${m==="__manual__"?i`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${le.value}
                onInput=${h=>{le.value=h.target.value}}
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
            value=${Hs.value}
            onInput=${h=>{Hs.value=h.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${wi.value}
            onChange=${h=>{wi.value=h.target.value}}
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
            value=${Oi.value}
            onInput=${h=>{Oi.value=h.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${p} disabled=${It.value==="checking"||It.value==="requesting"}>
              ${It.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${v} disabled=${It.value==="checking"||It.value==="requesting"}>
              ${It.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${fs(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Ot(o,"effective_score",0)}/${Ot(o,"required_points",0)}</span>
            ${xt(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${xt(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function gu({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function $u({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function hu(){const t=Lo.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=_(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(_).slice(-8),o=t.canon_check,l=_(o)?o:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(T=>typeof T=="string").slice(0,3):[],u=l&&Array.isArray(l.violations)?l.violations.filter(T=>typeof T=="string").slice(0,3):[],m=n?fs(n,"advanced",!1):!1,p=n?xt(n,"progress_reason",""):"",v=n?xt(n,"progress_detail",""):"",f=n?Ot(n,"player_successes",0):0,h=n?Ot(n,"player_required_successes",0):0,A=n?fs(n,"dm_success",!1):!1,b=n?Ot(n,"timeouts",0):0,k=n?Ot(n,"unavailable",0):0,$=n?Ot(n,"reprompts",0):0,z=n?Ot(n,"npc_attacks",0):0,S=n?Ot(n,"keeper_timeout_sec",0):0,M=n?Ot(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${m?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${m?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${A?"DM ok":"DM stalled"} / players ${f}/${h}
          </span>
        </div>
        ${p?i`<div style="margin-top:4px; font-size:12px;">${p}</div>`:null}
        ${v?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${v}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${b}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${$}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${z}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${S||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${M}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(T=>{const K=xt(T,"status","unknown"),U=xt(T,"actor_id","-"),et=xt(T,"role","-"),Q=xt(T,"reason",""),tt=xt(T,"action_type",""),W=xt(T,"reply","");return i`
                <div class="trpg-round-item ${K.includes("fallback")||K.includes("timeout")?"failed":"active"}">
                  <span>${U} (${et})</span>
                  <span style="margin-left:auto; font-size:11px;">${K}</span>
                  ${tt?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${tt}</div>`:null}
                  ${Q?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${Q}</div>`:null}
                  ${W?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${W.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${xt(l,"status","unknown")}</strong>
            </div>
            ${u.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${u.map(T=>i`<div>violation: ${T}</div>`)}
                </div>`:null}
            ${c.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(T=>i`<div>warning: ${T}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Zb({state:t,nowMs:e}){var l,c,u;const n=ee.value||((l=t.session)==null?void 0:l.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((u=t.session)==null?void 0:u.status)??"unknown",a=pu(e),o=Kb(e);return i`
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
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>Bb(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{Ja(),j("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function tk({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Fb(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function ek({state:t}){const e=t.party??[],n=t.story_log??[];return i`
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
          <${vu} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${R} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${Gb} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${R} title="현재 라운드" semanticId="lab.trpg">
          <${$u} state=${t} />
        <//>

        <${R} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${gu} state=${t} />
        <//>

        <${R} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>i`<${_u} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?i`
            <${R} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${fu} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function nk({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${R} title=${`이벤트 타임라인 (${e.length})`}>
          <${Jb} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${R} title="최근 라운드 결과" semanticId="lab.trpg">
          <${hu} />
        <//>

        <${R} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${$u} state=${t} />
        <//>
      </div>
    </div>
  `}function sk({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${Zb} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${R} title="조작 패널" semanticId="lab.trpg">
            <${Yb} state=${t} nowMs=${e} />
          <//>

          <${R} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${Xb} state=${t} />
          <//>

          <${R} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${Qb} state=${t} nowMs=${e} />
          <//>

          <${R} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${hu} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${R} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${gu} state=${t} />
          <//>

          <${R} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${_u} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?i`
              <${R} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${fu} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function ak(){var c,u,m,p,v;const t=Mc.value,e=lo.value;if(nt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const f=window.setInterval(()=>{Ql.value=Date.now()},1e3);return()=>{window.clearInterval(f)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>_e()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,o=uu.value,l=Ql.value;return i`
    <div>
      <${Ct} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${ee.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((u=t.current_round)==null?void 0:u.phase)??((m=t.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>_e()}>새로고침</button>
      </div>

      <${Vb} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((p=t.session)==null?void 0:p.status)??"active"}</div>
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

      <${tk} active=${o} />

      ${o==="overview"?i`<${ek} state=${t} />`:o==="timeline"?i`<${nk} state=${t} />`:i`<${sk} state=${t} nowMs=${l} />`}
    </div>
  `}function ik(){return i`
    <div>
      <${Ct} surfaceId="lab" />
      <${R} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${R} title="TRPG" class="section" semanticId="lab.trpg">
        <${ak} />
      <//>
    </div>
  `}const Va=g(new Set(["broadcast","tasks","keepers","system"]));function ok(t){const e=new Set(Va.value);e.has(t)?e.delete(t):e.add(t),Va.value=e}const br=g(null);function yu(t){br.value=t}function rk(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const lk=Pt(()=>{const t=Va.value;return pa.value.filter(e=>t.has(rk(e)))}),ck=12e4,dk=Pt(()=>{const t=Pc.value,e=Date.now();return Gt.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?o=e-new Date(l).getTime()>ck?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),uk=Pt(()=>{const t=Pc.value;return Gt.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function Zl(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function pk(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function mk(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function _k(){const t=dk.value,e=br.value;return t.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${t.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${mk(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>yu(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const vk=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function fk(){const t=Va.value;return i`
    <div class="activity-filter-bar">
      ${vk.map(e=>i`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>ok(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function gk(){const t=lk.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${fk} />
      <div class="activity-stream-list">
        ${t.length===0?i`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>i`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${Zl(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${Zl(e)}">${pk(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${Md(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function $k(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function hk(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function yk(){const t=uk.value,e=br.value;return i`
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
              onClick=${()=>yu(e===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${$k(n.pressure)}">
                  ${hk(n.pressure)}
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
  `}function bk(){const t=ge.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>라이브 모니터</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"연결됨":"오프라인"}
          </span>
          <span class="live-stat">에이전트 ${Gt.value.length}</span>
          <span class="live-stat">이벤트 ${Ya.value}</span>
        </div>
      </div>

      <${_k} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${gk} />
        </div>
        <div class="live-panel-side">
          <${yk} />
        </div>
      </div>
    </div>
  `}const tc=[{id:"now",label:"지금",description:"지금 무슨 일이 벌어지는지 사회의 현재 상태를 먼저 읽는 표면"},{id:"why",label:"이유",description:"왜 그렇게 보이는지 근거, 메모리, 거버넌스로 뒤를 파는 표면"},{id:"act",label:"개입",description:"운영자 액션과 계획 조정을 통해 지금 상태를 바꾸는 표면"},{id:"lab",label:"실험",description:"실험적 오케스트레이션과 고급 지휘 표면을 분리해서 보는 영역"}],Po=[{id:"mission",label:"상황판",icon:"🏠",group:"now",description:"room 중심으로 지금 상황과 사회의 흐름을 가장 먼저 읽는 기본 랜딩"},{id:"execution",label:"실행",icon:"🤖",group:"now",description:"agents, keepers, sessions를 중심으로 사회의 행위자를 읽는 표면"},{id:"live",label:"라이브",icon:"📡",group:"now",description:"실시간 에이전트 활동과 이벤트 흐름을 사회 관찰 관점으로 보는 표면"},{id:"proof",label:"근거",icon:"🔍",group:"why",description:"협업, 대화, 실행의 증거 경로를 확인하는 표면"},{id:"memory",label:"메모리",icon:"💬",group:"why",description:"게시글, 댓글, 비동기 기억으로 room의 누적 맥락을 읽는 표면"},{id:"governance",label:"거버넌스",icon:"⚖️",group:"why",description:"토론, 표결, 판단 구조를 규범과 결정의 관점에서 읽는 표면"},{id:"planning",label:"계획",icon:"🎯",group:"act",description:"목표, 백로그, 압력을 운영 관점으로 읽는 계획 표면"},{id:"tools",label:"도구",icon:"🧰",group:"act",description:"시스템 전체 도구 inventory와 사용 건강도를 확인하는 운영 표면"},{id:"intervene",label:"개입",icon:"🎮",group:"act",description:"룸, 세션, 키퍼에 직접 개입하는 운영 화면"},{id:"command",label:"지휘",icon:"🧭",group:"lab",description:"command-plane, swarm, resolution 같은 고급 지휘/실험 표면"},{id:"lab",label:"실험",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 표면을 메인 사회/운영 콘솔 밖에서 다룹니다"}];function kk(t){const e=t==null?void 0:t.trim();return e?e.length>10?e.slice(0,10):e:"커밋 정보 없음"}function zt(t,e){return e==="live"?"가동 중":e==="quiet"?"조용함":e==="starting"?"기동 중":e==="idle"?t==="guardian"?"유휴":"대기 중":"비활성"}function Rt(t,e){return i`
    <div class="build-badge-row">
      <span>${t}</span>
      <strong>${e}</strong>
    </div>
  `}function Vs(t,e,n,s,a){return i`
    <div style="padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
      <div class="rail-card-head" style="margin:0;">
        <h3 style="font-size:12px;">${t}</h3>
        <span class="rail-section-chip ${n}">${e}</span>
      </div>
      ${s}
      ${a?i`<div class="rail-build-hint">${a}</div>`:null}
    </div>
  `}function xk({currentTab:t}){var u,m,p,v,f,h,A,b,k,$;const e=ge.value,n=(u=pt.value)==null?void 0:u.build,s=(m=pt.value)==null?void 0:m.lodge,a=(p=pt.value)==null?void 0:p.gardener,o=(v=pt.value)==null?void 0:v.guardian,l=(f=pt.value)==null?void 0:f.sentinel,c=[];if(s&&c.push(Vs("Lodge",s.enabled?zt("lodge",s.quiet_active?"quiet":"live"):zt("lodge","disabled"),s.enabled?s.quiet_active?"warn":"ok":"bad",[Rt("틱",s.total_ticks??0),Rt("체크인",s.total_checkins??0),Rt("최근 결과",((h=s.last_tick_result)==null?void 0:h.activity_report)??s.last_skip_reason??"없음")])),a&&c.push(Vs("Gardener",a.alive?zt("gardener","live"):a.enabled?zt("gardener","starting"):zt("gardener","disabled"),a.alive?"ok":a.enabled?"warn":"bad",[Rt("최근 tick",a.last_tick_completed_at?i`<${X} timestamp=${a.last_tick_completed_at} />`:"기록 없음"),Rt("판단",`${a.last_intervention??"없음"} · ${a.last_decision_source??"없음"}`),Rt("백로그",`미할당 ${((A=a.health_summary)==null?void 0:A.todo_count)??0} · P1/2 ${((b=a.health_summary)==null?void 0:b.high_priority_todo)??0}`)],a.last_reason??a.last_error??void 0)),o){const z=o.masc_loops_running||o.lodge_loop_started||o.lodge_running;c.push(Vs("Guardian",z?zt("guardian","live"):o.enabled?zt("guardian","idle"):zt("guardian","disabled"),z?"ok":o.enabled?"warn":"bad",[Rt("모드",o.mode??"알 수 없음"),Rt("루프",`zombie ${o.zombie_loop_running?"on":"off"} · gc ${o.gc_loop_running?"on":"off"}`),Rt("소유자",o.runtime_owner??"없음")],((k=o.last_lodge_result)==null?void 0:k.message)??o.last_gc_result??o.last_zombie_result??void 0))}return l&&c.push(Vs("Sentinel",l.started?zt("sentinel","live"):l.enabled?zt("sentinel","starting"):zt("sentinel","disabled"),l.started?"ok":l.enabled?"warn":"bad",[Rt("에이전트",l.agent_name??"sentinel"),Rt("소비자",(($=l.consumers)==null?void 0:$.length)??0),Rt("가디언 소유자",l.guardian_runtime_owner??"없음")],l.llm_enabled===!0?"LLM 기반 housekeeping resident":void 0)),i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${D} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${e?"ok":"bad"}">${e?"연결됨":"오프라인"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>에이전트</span>
          <strong>${Gt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>키퍼</span>
          <strong>${ae.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>태스크</span>
          <strong>${ue.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>이벤트</span>
          <strong>${Ya.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{$s(),wc(),ho(t)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>it("intervene")}>
          개입 열기
        </button>
      </div>
      ${n?i`<div class="rail-build-hint">서버 빌드 · v${n.release_version} · ${kk(n.commit)}</div>`:null}
      ${c.length>0?i`
            <div style="margin-top:12px; display:flex; flex-direction:column; gap:10px;">
              ${c}
            </div>
          `:null}
    </section>
  `}function Sk(){const t=At.value,e=ti(t).total_count,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${D} panelId="side_rail.quick_actions" compact=${!0} />
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
          onClick=${()=>{gt(),Oe()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>it("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}const Ys=g(!1);function Ck(){const t=ge.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"연결됨":"재연결 중..."}</span>
      <span class="event-count">이벤트 ${Ya.value}</span>
    </div>
  `}function Ak(t){const e=t==null?void 0:t.trim();return e?e.length>10?e.slice(0,10):e:"커밋 정보 없음"}function Tk(){const t=pt.value,e=t==null?void 0:t.build,n=e?`v${e.release_version} · ${Ak(e.commit)}`:t!=null&&t.version?`v${t.version} · 커밋 정보 없음`:"버전 정보 없음";return i`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${Ys.value}
        onClick=${()=>{Ys.value=!Ys.value}}
      >
        서버 빌드 · ${n}
      </button>
      ${Ys.value?i`
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
  `}function Ik(){const t=O.value.tab,e=Po.find(s=>s.id===t),n=tc.find(s=>s.id===(e==null?void 0:e.group));return i`
    <aside class="dashboard-rail">
      <${Ct} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${D} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${tc.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${Po.filter(a=>a.group===s.id).map(a=>i`
                  <button
                    class="rail-tab-btn ${t===a.id?"active":""}"
                    onClick=${()=>it(a.id)}
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

      <${xk} currentTab=${t} />
      <${Sk} />
    </aside>
  `}function Rk(){switch(O.value.tab){case"mission":return i`<${xl} />`;case"proof":return i`<${N$} />`;case"execution":return i`<${Wy} />`;case"tools":return i`<${Zy} />`;case"live":return i`<${bk} />`;case"memory":return i`<${My} />`;case"governance":return i`<${Rb} />`;case"planning":return i`<${_b} />`;case"intervene":return i`<${gy} />`;case"command":return i`<${my} />`;case"lab":return i`<${ik} />`;default:return i`<${xl} />`}}function Mk(){return ro.value&&!ge.value?i`<div class="loading-indicator">대시보드 불러오는 중...</div>`:i`<${Rk} />`}function Lk(){nt(()=>{zu(),rc(),Oc(),Le(),Me(),wc(),ed();const n=w_();return O_(),()=>{qu(),n(),D_()}},[]),nt(()=>{const n=setInterval(()=>{ho(O.value.tab)},15e3);return()=>{clearInterval(n)}},[]),nt(()=>{ho(O.value.tab)},[O.value.tab]);const t=O.value.tab,e=Po.find(n=>n.id===t);return i`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC 대시보드
            <${Tk} />
          </h1>
          <p class="header-subtitle">${(e==null?void 0:e.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${Ck} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${Ik} />
        <main class="dashboard-main">
          <${Mk} />
        </main>
      </div>

      <${wg} />
      <${ag} />
      <${Jf} />
    </div>
  `}const ec=document.getElementById("app");ec&&Tu(i`<${Lk} />`,ec);export{Gg as _};
