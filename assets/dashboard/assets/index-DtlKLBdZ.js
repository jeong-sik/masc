var fu=Object.defineProperty;var gu=(t,e,n)=>e in t?fu(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Ke=(t,e,n)=>gu(t,typeof e!="symbol"?e+"":e,n);import{e as $u,_ as hu,c as g,b as Mt,A as En,y as st,d as pn,G as yu}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const l of o.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=$u.bind(hu);const bu=["mission","proof","execution","tools","live","memory","governance","planning","intervene","command","lab"],Gl={tab:"mission",params:{},postId:null};function Wr(t){return!!t&&bu.includes(t)}function Wi(t){try{return decodeURIComponent(t)}catch{return t}}function Hi(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function ku(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Jl(t,e){if(t[0]==="chains"){const o={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(o.operation=Wi(t[2])),{tab:"command",params:o,postId:null}}if(t[0]==="lab"){const o={...e};return t[1]&&(o.surface=Wi(t[1])),{tab:"lab",params:o,postId:null}}const n=t[0],s=e.tab;return{tab:Wr(n)?n:Wr(s)?s:"mission",params:e,postId:null}}function sa(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Gl;const n=Wi(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=Hi(a),l=ku(s);return Jl(l,o)}function xu(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Gl,params:Hi(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Hi(e.replace(/^\?/,""));return Jl(s,a)}function Yl(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const w=g(sa(window.location.hash));window.addEventListener("hashchange",()=>{w.value=sa(window.location.hash)});function it(t,e){const n={tab:t,params:e??{}};window.location.hash=Yl(n)}function Su(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function Cu(){if(window.location.hash&&window.location.hash!=="#"){w.value=sa(window.location.hash);return}const t=xu(window.location.pathname,window.location.search);if(t){w.value=t;const e=Yl(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",w.value=sa(window.location.hash)}const Hr="masc_dashboard_sse_session_id",Au=1e3,Tu=15e3,ve=g(!1),Ua=g(0),Vl=g(null),aa=g([]);function Iu(){let t=sessionStorage.getItem(Hr);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Hr,t)),t}const Ru=200;function Mu(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};aa.value=[a,...aa.value].slice(0,Ru)}function Gi(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Gr(t,e){const n=Gi(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function Tt(t,e,n,s,a={}){Mu(t,e,n,{eventType:s,...a})}let jt=null,en=null,Ji=0;function Xl(){en&&(clearTimeout(en),en=null)}function Eu(){if(en)return;Ji++;const t=Math.min(Ji,5),e=Math.min(Tu,Au*Math.pow(2,t));en=setTimeout(()=>{en=null,Ql()},e)}function Ql(){Xl(),jt&&(jt.close(),jt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Iu());const a=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(a);jt=o,o.onopen=()=>{jt===o&&(Ji=0,ve.value=!0)},o.onerror=()=>{jt===o&&(ve.value=!1,o.close(),jt=null,Eu())},o.onmessage=l=>{try{const c=JSON.parse(l.data);Ua.value++,Vl.value=c,Lu(c)}catch{}}}function Lu(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":Tt(n,"Joined","system","agent_joined");break;case"agent_left":Tt(n,"Left","system","agent_left");break;case"broadcast":Tt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Tt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Tt(n,Gr("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Gi(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":Tt(n,Gr("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Gi(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":Tt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Tt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Tt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Tt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Tt(n,e,"system","unknown")}}function Pu(){Xl(),jt&&(jt.close(),jt=null),ve.value=!1}function _(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function r(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function u(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function z(t){return typeof t=="boolean"?t:void 0}function B(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function mt(t,e=[]){if(Array.isArray(t))return t;if(!_(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function lt(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}const ia="[STATE]",Yi="[/STATE]";function zu(t){const e=t.indexOf(ia);if(e<0)return null;const n=e+ia.length,s=t.indexOf(Yi,n);return s<0?null:t.slice(n,s).trim()||null}function Nu(t){let e=t;for(;;){const n=e.indexOf(ia);if(n<0)return e;const s=e.indexOf(Yi,n+ia.length);if(s<0)return e.slice(0,n);e=`${e.slice(0,n)}${e.slice(s+Yi.length)}`}}function ju(t){return t.split(`
`).filter(e=>{const n=e.trim();return!n.startsWith("SKILL:")&&!n.startsWith("SKILL_REASON:")}).join(`
`)}function Us(t){const e=ju(t);return Nu(e).replace(/\n{3,}/g,`

`).trim()}function Zl(t){const e=(()=>{if(!_(t))return null;const o=t.raw_payload;return _(o)?o:t})();if(!e)return null;const n=r(e.reply)??"",s=n?zu(n):null,a=_(e.usage)?{inputTokens:u(e.usage.input_tokens)??null,outputTokens:u(e.usage.output_tokens)??null,totalTokens:u(e.usage.total_tokens)??null}:null;return{traceId:r(e.trace_id)??null,generation:u(e.generation)??null,modelUsed:r(e.model_used)??null,latencyMs:u(e.latency_ms)??null,costUsd:u(e.cost_usd)??null,usage:a,skillPrimary:r(e.skill_primary)??null,skillReason:r(e.skill_reason)??null,stateBlock:s,rawPayload:e}}function Du(t){const e=t.trim();if(!e.startsWith("{"))return{text:Us(e),details:null};try{const n=JSON.parse(e),s=Zl(n),a=_(n)?r(n.reply)??e:e;return{text:Us(a),details:s}}catch{return{text:Us(e),details:null}}}function Io(){return new URLSearchParams(window.location.search)}const wu="masc_dashboard_agent_name";function tc(){var t;try{return((t=localStorage.getItem(wu))==null?void 0:t.trim())||null}catch{return null}}function ec(){var e,n;const t=Io();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||tc()||"dashboard"}function nc(){const t=Io(),e={},n=t.get("token"),s=tc(),a=t.get("agent")??t.get("agent_name")??s;return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Ro(){return{...nc(),"Content-Type":"application/json"}}const Ou=15e3,Mo=3e4,qu=6e4,Jr=new Set([408,425,429,500,502,503,504]);class ps extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);Ke(this,"method");Ke(this,"path");Ke(this,"status");Ke(this,"statusText");Ke(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function Eo(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const l=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new ps({method:l,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function Fu(){var e,n;const t=Io();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function at(t){const e=await Eo(t,{headers:nc()},Ou);if(!e.ok)throw new ps({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Bu(t){return new Promise(e=>setTimeout(e,t))}function Ku(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function Uu(t){if(t instanceof ps)return t.timeout||typeof t.status=="number"&&Jr.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Ku(t.message);return e!==null&&Jr.has(e)}async function Wa(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!Uu(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${o}ms`,a),await Bu(o),s+=1}}async function Wt(t,e,n,s=Mo){const a=await Eo(t,{method:"POST",headers:{...Ro(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new ps({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function Wu(t,e,n,s=Mo){const a=await Eo(t,{method:"POST",headers:{...Ro(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new ps({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function Hu(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Gu(t){var e,n,s,a,o,l,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((c=(l=(o=t.result)==null?void 0:o.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function $e(t,e){const n=await Wu("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},qu),s=Hu(n);return Gu(s)}async function Ju(t,e,n){return $e("masc_keeper_msg",{name:t,message:e})}async function Yu(t,e,n){const s=await Ju(t,e);return Du(s)}function Vu(t){const e=t.replace(/\r\n/g,`
`),n=[];let s=0;for(;;){const a=e.indexOf(`

`,s);if(a<0)return{frames:n,rest:e.slice(s)};n.push(e.slice(s,a)),s=a+2}}function Yr(t){const e=t.split(`
`).filter(n=>n.startsWith("data:")).map(n=>n.slice(5).trimStart());if(e.length===0)return null;try{return JSON.parse(e.join(`
`))}catch{return null}}async function Xu(t,e,n,{signal:s,onEvent:a}){var m;const o=await fetch("/api/v1/keepers/chat/stream",{method:"POST",headers:{...Ro(),Accept:"text/event-stream"},body:JSON.stringify({name:t,message:e}),signal:s});if(!o.ok){const p=await o.text();let v=p||`Streaming request failed (${o.status})`;try{const f=JSON.parse(p);v=((m=f.error)==null?void 0:m.message)??f.message??v}catch{}throw new Error(v)}if(!o.body)throw new Error("Streaming response body is unavailable");const l=o.body.getReader(),c=new TextDecoder;let d="";try{for(;;){const{done:v,value:f}=await l.read();d+=c.decode(f??new Uint8Array,{stream:!v});const{frames:$,rest:S}=Vu(d);d=S;for(const y of $){const k=Yr(y);k&&a(k)}if(v)break}const p=d.trim();if(p){const v=Yr(p);v&&a(v)}}finally{l.releaseLock()}}function Qu(){return at("/api/v1/dashboard/shell")}function Zu(){return at("/api/v1/dashboard/room-truth")}function tp(){return at("/api/v1/dashboard/execution")}function ep(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),at(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function np(){return Wa("fetchDashboardGovernance",async()=>{const t=await at("/api/v1/dashboard/governance"),e=Array.isArray(t.items)?t.items.map(o=>bp(o)).filter(o=>o!==null):[],n=Array.isArray(t.pending_actions)?t.pending_actions.map(o=>ic(o)).filter(o=>o!==null):[],s=e.filter(o=>o.kind==="debate").map(o=>({id:o.id,topic:o.topic,status:o.status,argument_count:o.evidence_refs.length,created_at:o.last_activity_at??void 0})),a=e.filter(o=>o.kind==="consensus").map(o=>({id:o.id,topic:o.topic,initiator:o.related_agents[0]||"system",votes:o.votes??0,quorum:o.quorum??0,threshold:o.threshold,state:o.status,created_at:o.last_activity_at??void 0}));return{generated_at:ut(t.generated_at)??void 0,summary:_(t.summary)?{debates:vt(t.summary.debates)??void 0,voting_sessions:vt(t.summary.voting_sessions)??void 0,debates_open:vt(t.summary.debates_open)??void 0,sessions_active:vt(t.summary.sessions_active)??void 0,sessions_without_quorum:vt(t.summary.sessions_without_quorum)??void 0,ready_to_execute:vt(t.summary.ready_to_execute)??void 0,oldest_open_debate_age_s:typeof t.summary.oldest_open_debate_age_s=="number"?t.summary.oldest_open_debate_age_s:null,last_activity_age_s:typeof t.summary.last_activity_age_s=="number"?t.summary.last_activity_age_s:null,judge_online:typeof t.summary.judge_online=="boolean"?t.summary.judge_online:void 0,judge_last_seen_at:ut(t.summary.judge_last_seen_at)}:void 0,debates:s,sessions:a,items:e,activity:Array.isArray(t.activity)?t.activity.map(o=>kp(o)).filter(o=>o!==null):[],judge:xp(t.judge),pending_actions:n}})}function sp(){return at("/api/v1/dashboard/semantics")}function ap(){return at("/api/v1/dashboard/mission")}function ip(t){const e=`?session_id=${encodeURIComponent(t)}`;return at(`/api/v1/dashboard/session${e}`)}function op(t=!1){return at(`/api/v1/dashboard/mission/briefing${t?"?force=1":""}`)}function rp(t,e){const n=new URLSearchParams;t&&n.set("session_id",t),e&&n.set("operation_id",e);const s=n.toString();return at(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function lp(){return at("/api/v1/dashboard/planning")}function cp(){return at("/api/v1/tool-metrics")}function dp(){return at("/api/v1/dashboard/tools")}function up(){return at("/api/v1/operator")}function sc(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return at(`/api/v1/operator/digest${n?`?${n}`:""}`)}function pp(){return at("/api/v1/command-plane")}function mp(){return at("/api/v1/command-plane/summary")}function _p(){return at("/api/v1/chains/summary")}function vp(t){return at(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function fp(){return at("/api/v1/command-plane/help")}function gp(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return at(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function $p(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return at(`/api/v1/command-plane/orchestra${s?`?${s}`:""}`)}function hp(t,e){return Wt(t,e)}function yp(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"swarm_run_continue":return 6e4;case"swarm_run_rerun":return 12e4;case"swarm_run_abandon":return 3e4;case"lodge_tick":return 45e3;default:return Mo}}function Ha(t){return Wt("/api/v1/operator/action",t,void 0,yp(t))}function ac(t,e,n="confirm"){return Wt("/api/v1/operator/confirm",{actor:t,confirm_token:e,decision:n})}function Ws(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function ut(t){if(typeof t=="string"){const e=t.trim();return e||null}if(typeof t=="number"&&Number.isFinite(t)){const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}return null}function K(t){if(typeof t!="string")return null;const e=t.trim();return e||null}function ic(t){if(!_(t))return null;const e=x(t.confirm_token??t.token,"").trim();return e?{confirm_token:e,actor:K(t.actor)??void 0,action_type:K(t.action_type)??void 0,target_type:K(t.target_type)??void 0,target_id:K(t.target_id),delegated_tool:K(t.delegated_tool)??void 0,created_at:ut(t.created_at)??void 0,preview:t.preview}:null}function Lo(t){return _(t)?{board_post_id:K(t.board_post_id),task_id:K(t.task_id),operation_id:K(t.operation_id),team_session_id:K(t.team_session_id)}:{}}function oc(t){if(!_(t))return null;const e=K(t.action_kind),n=K(t.resolved_tool),s=K(t.target_type),a=K(t.target_id),o=K(t.reason);return!e&&!n&&!s&&!o?null:{action_kind:e??void 0,resolved_tool:n,target_type:s,target_id:a,reason:o??void 0,payload_preview:t.payload_preview}}function rc(t){if(!_(t))return null;const e=K(t.action_type),n=K(t.delegated_tool),s=K(t.confirmation_state),a=ut(t.created_at);return!e&&!n&&!s&&!a?null:{action_type:e??void 0,delegated_tool:n,confirmation_state:s??void 0,created_at:a}}function lc(t){if(!_(t))return null;const e=ic(t.pending_confirm),n=K(t.pending_confirm_token)??(e==null?void 0:e.confirm_token)??null;return{requires_human_gate:typeof t.requires_human_gate=="boolean"?t.requires_human_gate:void 0,pending_confirm:e,pending_confirm_token:n,ready_to_execute:typeof t.ready_to_execute=="boolean"?t.ready_to_execute:void 0}}function cc(t){if(!_(t))return null;const e=K(t.summary),n=K(t.target_id);return!e&&!n?null:{judgment_id:K(t.judgment_id)??void 0,target_kind:K(t.target_kind)??void 0,target_id:n??void 0,status:K(t.status)??void 0,summary:e??void 0,confidence:typeof t.confidence=="number"?t.confidence:null,generated_at:ut(t.generated_at),expires_at:ut(t.expires_at),model_used:K(t.model_used),keeper_name:K(t.keeper_name),evidence_refs:Ot(t.evidence_refs),recommended_action:oc(t.recommended_action),guardrail_state:lc(t.guardrail_state),executed_route:rc(t.executed_route)}}function bp(t){if(!_(t))return null;const e=x(t.id,"").trim(),n=x(t.topic,"").trim();if(!e||!n)return null;const s=Lo(t.context);return{kind:x(t.kind,"debate"),id:e,topic:n,status:x(t.status??t.state,"open"),last_activity_at:ut(t.last_activity_at),truth_summary:K(t.truth_summary)??void 0,judgment_summary:K(t.judgment_summary),confidence:typeof t.confidence=="number"?t.confidence:null,related_agents:Ot(t.related_agents),context:s,linked_board_post_id:K(t.linked_board_post_id)??s.board_post_id??null,linked_task_id:K(t.linked_task_id)??s.task_id??null,linked_operation_id:K(t.linked_operation_id)??s.operation_id??null,linked_session_id:K(t.linked_session_id)??s.team_session_id??null,recommended_action:oc(t.recommended_action),executed_route:rc(t.executed_route),guardrail_state:lc(t.guardrail_state),evidence_refs:Ot(t.evidence_refs),approve_count:vt(t.approve_count),reject_count:vt(t.reject_count),abstain_count:vt(t.abstain_count),votes:vt(t.votes),quorum:vt(t.quorum),threshold:typeof t.threshold=="number"?t.threshold:void 0}}function kp(t){if(!_(t))return null;const e=x(t.kind,"").trim();return e?{kind:e,item_kind:K(t.item_kind)??void 0,item_id:K(t.item_id)??void 0,topic:K(t.topic)??void 0,created_at:ut(t.created_at),summary:K(t.summary)??void 0,actor:K(t.actor),index:vt(t.index),decision:K(t.decision)}:null}function xp(t){if(_(t))return{judge_online:typeof t.judge_online=="boolean"?t.judge_online:void 0,refreshing:typeof t.refreshing=="boolean"?t.refreshing:void 0,generated_at:ut(t.generated_at),expires_at:ut(t.expires_at),model_used:K(t.model_used),keeper_name:K(t.keeper_name),last_error:K(t.last_error)}}function Sp(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Cp(t){if(!_(t))return null;const e=x(t.source,"").trim()||null,n=x(t.state_block,"").trim()||null;return!e&&!n?null:{source:e,state_block:n}}function Ap(t){if(!_(t))return null;const e=x(t.id,"").trim(),n=x(t.author,"").trim(),s=x(t.body,"").trim()||x(t.content,"").trim(),a=s;if(!e||!n)return null;const o=H(t.score,0),l=H(t.votes_up,0),c=H(t.votes_down,0),d=H(t.votes,o||l-c),m=H(t.comment_count,H(t.reply_count,0)),p=(()=>{const k=t.flair;if(typeof k=="string"&&k.trim())return k.trim();if(_(k)){const C=x(k.name,"").trim();if(C)return C}return x(t.flair_name,"").trim()||void 0})(),v=x(t.created_at_iso,"").trim()||Ws(t.created_at),f=x(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Ws(t.updated_at):v),S=x(t.title,"").trim()||Sp(s),y=Array.isArray(t.tags)?t.tags.filter(k=>typeof k=="string"&&k.trim()!==""):[];return{id:e,author:n,post_kind:(()=>{const k=x(t.post_kind,"").trim().toLowerCase();return k==="automation"||k==="system"||k==="human"?k:void 0})(),title:S,body:s,content:a,meta:Cp(t.meta),tags:y,votes:d,vote_balance:o,comment_count:m,created_at:v,updated_at:f,flair:p,hearth:x(t.hearth,"").trim()||null,visibility:x(t.visibility,"").trim()||void 0,expires_at:x(t.expires_at_iso,"").trim()||(t.expires_at!==void 0&&t.expires_at!==0?Ws(t.expires_at):"")||null,hearth_count:H(t.hearth_count,0)}}function Tp(t){if(!_(t))return null;const e=x(t.id,"").trim(),n=x(t.post_id,"").trim(),s=x(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:x(t.content,""),created_at:Ws(t.created_at)}}async function Ip(t){return Wa("fetchBoardPost",async()=>{const e=await at(`/api/v1/board/${t}?format=flat`),n=_(e.post)?e.post:e,s=Ap(n)??{id:t,author:"unknown",post_kind:"human",title:"Post",body:"",content:"",meta:null,tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(e.comments)?e.comments:[]).map(Tp).filter(l=>l!==null);return{...s,comments:o}})}function dc(t,e){return Wt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Fu()})}function Rp(t,e,n){return Wt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Mp(t){const e=x(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function pt(...t){for(const e of t){const n=x(e,"");if(n.trim())return n.trim()}return""}function Vr(t){const e=Mp(pt(t.outcome,t.result,t.result_code));if(!e)return;const n=pt(t.reason,t.reason_code,t.description,t.detail),s=pt(t.summary,t.summary_ko,t.summary_en,t.note),a=pt(t.details,t.details_text,t.text,t.note),o=pt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),l=pt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=pt(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const v=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof v=="string"?[v]:Array.isArray(v)?v.map(f=>{if(typeof f=="string")return f.trim();if(_(f)){const $=x(f.summary,"").trim();if($)return $;const S=x(f.text,"").trim();if(S)return S;const y=x(f.type,"").trim();return y||x(f.event_id,"").trim()}return""}).filter(f=>f.length>0):[]})(),m=(()=>{const v=H(t.turn,Number.NaN);if(Number.isFinite(v))return v;const f=H(t.turn_number,Number.NaN);if(Number.isFinite(f))return f;const $=H(t.current_turn,Number.NaN);if(Number.isFinite($))return $;const S=H(t.round,Number.NaN);return Number.isFinite(S)?S:void 0})(),p=pt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:l||void 0,evidence:d.length>0?d:void 0,raw_reason:c||void 0,turn:m,phase:p||void 0}}function Ep(t,e){const n=_(t.state)?t.state:{};if(x(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(l=>_(l)?x(l.type,"")==="session.outcome":!1),o=_(n.session_outcome)?n.session_outcome:{};if(_(o)&&Object.keys(o).length>0){const l=Vr(o);if(l)return l}if(_(a))return Vr(_(a.payload)?a.payload:{})}function x(t,e=""){return typeof t=="string"?t:e}function H(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function vt(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function oa(t,e=!1){return typeof t=="boolean"?t:e}function Ot(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(_(e)){const n=x(e.name,"").trim(),s=x(e.id,"").trim(),a=x(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Lp(t){const e={};if(!_(t)&&!Array.isArray(t))return e;if(_(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),o=x(s,"").trim();!a||!o||(e[a]=o)}),e;for(const n of t){if(!_(n))continue;const s=pt(n.to,n.target,n.actor_id,n.name,n.id),a=pt(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Pp(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function St(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const zp=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Np(t){const e=_(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const o=s.trim();o&&(zp.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function jp(t,e){if(t!=="dice.rolled")return;const n=H(e.raw_d20,0),s=H(e.total,0),a=H(e.bonus,0),o=x(e.action,"roll"),l=H(e.dc,0);return{notation:l>0?`${o} (DC ${l})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function Dp(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function wp(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Op(t,e,n,s){const a=n||e||x(s.actor_id,"")||x(s.actor_name,"");switch(t){case"turn.action.proposed":{const o=x(s.proposed_action,x(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=x(s.reply,x(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return x(s.reply,x(s.content,x(s.text,"Narration")));case"dice.rolled":{const o=x(s.action,"roll"),l=H(s.total,0),c=H(s.dc,0),d=x(s.label,""),m=a||"actor",p=c>0?` vs DC ${c}`:"",v=d?` (${d})`:"";return`${m} ${o}: ${l}${p}${v}`}case"turn.started":return`Turn ${H(s.turn,1)} started`;case"phase.changed":return`Phase: ${x(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${x(s.name,_(s.actor)?x(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${x(s.keeper_name,x(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${x(s.keeper_name,x(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${H(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${H(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||x(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||x(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${x(s.reason_code,"unknown")}`;case"memory.signal":{const o=_(s.entity_refs)?s.entity_refs:{},l=x(o.requested_tier,""),c=x(o.effective_tier,""),d=oa(o.guardrail_applied,!1),m=x(s.summary_en,x(s.summary_ko,"Memory signal"));if(!l&&!c)return m;const p=l&&c?`${l}->${c}`:c||l;return`${m} [${p}${d?" (guardrail)":""}]`}case"world.event":{if(x(s.event_type,"")==="canon.check"){const l=x(s.status,"unknown"),c=x(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return x(s.description,x(s.summary,"World event"))}case"combat.attack":return x(s.summary,x(s.result,"Attack resolved"));case"combat.defense":return x(s.summary,x(s.result,"Defense resolved"));case"session.outcome":return x(s.summary,x(s.outcome,"Session ended"));default:{const o=Dp(s);return o?`${t}: ${o}`:t}}}function qp(t,e){const n=_(t)?t:{},s=x(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=x(n.actor_name,"").trim()||e[a]||x(_(n.payload)?n.payload.actor_name:"",""),l=_(n.payload)?n.payload:{},c=x(n.ts,x(n.timestamp,new Date().toISOString())),d=x(n.phase,x(l.phase,"")),m=x(n.category,"");return{type:s,actor:o||a||x(l.actor_name,""),actor_id:a||x(l.actor_id,""),actor_name:o,seq:n.seq,room_id:x(n.room_id,""),phase:d||void 0,category:m||wp(s),visibility:x(n.visibility,x(l.visibility,"public")),event_id:x(n.event_id,""),content:Op(s,a,o,l),dice_roll:jp(s,l),timestamp:c}}function Fp(t,e,n){var X,rt;const s=x(t.room_id,"")||n||"default",a=_(t.state)?t.state:{},o=_(a.party)?a.party:{},l=_(a.actor_control)?a.actor_control:{},c=_(a.join_gate)?a.join_gate:{},d=_(a.contribution_ledger)?a.contribution_ledger:{},m=Object.entries(o).map(([U,I])=>{const A=_(I)?I:{},N=St(A,"max_hp",void 0,10),J=St(A,"hp",void 0,N),Q=St(A,"max_mp",void 0,0),ot=St(A,"mp",void 0,0),W=St(A,"level",void 0,1),Lt=St(A,"xp",void 0,0),be=oa(A.alive,J>0),kn=l[U],bs=typeof kn=="string"?kn:void 0,ii=Pp(A.role,U,bs),oi=vt(A.generation),ri=pt(A.joined_at,A.joinedAt,A.started_at,A.startedAt),li=pt(A.claimed_at,A.claimedAt,A.assigned_at,A.assignedAt,A.assigned_time),ci=pt(A.last_seen,A.lastSeen,A.last_seen_at,A.lastSeenAt,A.last_active,A.lastActive),ks=pt(A.scene,A.current_scene,A.currentScene,A.world_scene,A.scene_name,A.sceneName),xs=pt(A.location,A.current_location,A.currentLocation,A.position,A.zone,A.area);return{id:U,name:x(A.name,U),role:ii,keeper:bs,archetype:x(A.archetype,""),persona:x(A.persona,""),portrait:x(A.portrait,"")||void 0,background:x(A.background,"")||void 0,traits:Ot(A.traits),skills:Ot(A.skills),stats_raw:Np(A),status:be?"active":"dead",generation:oi,joined_at:ri||void 0,claimed_at:li||void 0,last_seen:ci||void 0,scene:ks||void 0,location:xs||void 0,inventory:Ot(A.inventory),notes:Ot(A.notes),relationships:Lp(A.relationships),stats:{hp:J,max_hp:N,mp:ot,max_mp:Q,level:W,xp:Lt,strength:St(A,"strength","str",10),dexterity:St(A,"dexterity","dex",10),constitution:St(A,"constitution","con",10),intelligence:St(A,"intelligence","int",10),wisdom:St(A,"wisdom","wis",10),charisma:St(A,"charisma","cha",10)}}}),p=m.filter(U=>U.status!=="dead"),v=Ep(t,e),f={phase_open:oa(c.phase_open,!0),min_points:H(c.min_points,3),window:x(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},$=Object.entries(d).map(([U,I])=>{const A=_(I)?I:{};return{actor_id:U,score:H(A.score,0),last_reason:x(A.last_reason,"")||null,reasons:Ot(A.reasons)}}),S=m.reduce((U,I)=>(U[I.id]=I.name,U),{}),y=e.map(U=>qp(U,S)),k=H(a.turn,1),h=x(a.phase,"round"),C=x(a.map,""),M=_(a.world)?a.world:{},T=C||x(M.ascii_map,x(M.map,"")),P=y.filter((U,I)=>{const A=e[I];if(!_(A))return!1;const N=_(A.payload)?A.payload:{};return H(N.turn,-1)===k}),G=(P.length>0?P:y).slice(-12),L=x(a.status,"active");return{session:{id:s,room:s,status:L==="ended"?"ended":L==="paused"?"paused":"active",round:k,actors:p,created_at:((X=y[0])==null?void 0:X.timestamp)??new Date().toISOString()},current_round:{round_number:k,phase:h,events:G,timestamp:((rt=y[y.length-1])==null?void 0:rt.timestamp)??new Date().toISOString()},map:T||void 0,join_gate:f,contribution_ledger:$,outcome:v,party:p,story_log:y,history:[]}}async function Bp(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await at(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Kp(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([at(`/api/v1/trpg/state${e}`),Bp(t)]);return Fp(n,s,t)}function Up(t){return Wt("/api/v1/trpg/rounds/run",{room_id:t})}function Wp(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Hp(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Wt("/api/v1/trpg/dice/roll",e)}function Gp(t,e){const n=Wp();return Wt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Jp(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Wt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function Yp(t,e,n){return Wt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Vp(t,e,n){const s=await $e("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Xp(t){const e=await $e("trpg.mid_join.request",t);return JSON.parse(e)}async function Qp(t,e){await $e("masc_broadcast",{agent_name:t,message:e})}async function Zp(t=40){return(await $e("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function tm(t,e=20){return $e("masc_task_history",{task_id:t,limit:e})}async function em(t){const e=await $e("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function nm(t){return Wa("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await at(`/api/v1/council/debates/${e}/summary`);if(!_(n))return null;const s=_(n.debate)?n.debate:n,a=x(s.id,"").trim(),o=x(s.topic,"").trim();return!a||!o?null:{debate:{id:a,topic:o,status:x(s.status,"open"),created_at:ut(s.created_at_iso??s.created_at),closed_at:ut(s.closed_at)},arguments:Array.isArray(n.arguments)?n.arguments.flatMap(l=>_(l)?[{index:H(l.index,0),agent:x(l.agent,"unknown"),position:x(l.position,"neutral"),content:x(l.content,""),evidence:Ot(l.evidence),reply_to:vt(l.reply_to)??null,mentions:Ot(l.mentions),archetype:K(l.archetype),created_at:ut(l.created_at)}]:[]):[],summary:{support_count:_(n.summary)?H(n.summary.support_count,0):H(n.support_count,0),oppose_count:_(n.summary)?H(n.summary.oppose_count,0):H(n.oppose_count,0),neutral_count:_(n.summary)?H(n.summary.neutral_count,0):H(n.neutral_count,0),total_arguments:_(n.summary)?H(n.summary.total_arguments,0):H(n.total_arguments,0),summary_text:_(n.summary)?x(n.summary.summary_text,""):x(n.summary_text,"")},context:Lo(n.context),judgment:cc(n.judgment)}})}async function sm(t){return Wa("fetchConsensusSessionSummary",async()=>{const e=encodeURIComponent(t),n=await at(`/api/v1/council/sessions/${e}/summary`);if(!_(n)||!_(n.session))return null;const s=n.session,a=x(s.id,"").trim(),o=x(s.topic,"").trim();return!a||!o?null:{session:{id:a,topic:o,state:x(s.state,"open"),initiator:x(s.initiator,"system"),quorum:H(s.quorum,0),threshold:H(s.threshold,0),created_at:ut(s.created_at),closed_at:ut(s.closed_at)},votes:Array.isArray(n.votes)?n.votes.flatMap(l=>_(l)?[{agent:x(l.agent,"unknown"),decision:x(l.decision,"abstain"),reason:x(l.reason,""),timestamp:ut(l.timestamp),weight:typeof l.weight=="number"?l.weight:void 0,archetype:K(l.archetype)}]:[]):[],summary:{approve_count:_(n.summary)?H(n.summary.approve_count,0):0,reject_count:_(n.summary)?H(n.summary.reject_count,0):0,abstain_count:_(n.summary)?H(n.summary.abstain_count,0):0,quorum_met:_(n.summary)?oa(n.summary.quorum_met,!1):!1,result:_(n.summary)?K(n.summary.result):null},context:Lo(n.context),judgment:cc(n.judgment)}})}const am=g(""),ne=g({}),$t=g({}),Vi=g({}),ra=g({}),Xi=g({}),Qi=g({}),Bt=g({}),Po=new Map,zo=new Map;function ct(t,e,n){t.value={...t.value,[e]:n}}function im(t){var n;const e=(n=r(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function om(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function di(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!_(s))continue;const a=r(s.name);if(!a)continue;const o=r(s[e]);e==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function rm(t){if(!_(t))return null;const e=r(t.name);return e?{name:e,trigger:r(t.trigger),outcome:r(t.outcome),summary:r(t.summary),reason:r(t.reason)}:null}function lm(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function cm(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function uc(t,e,n){return r(t)??cm(e,n)}function pc(t,e){return typeof t=="boolean"?t:e==="recover"}function la(t){if(!_(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:r(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:lt(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:u(t.next_eligible_at_s)??null,recoverable:pc(t.recoverable,n),summary:uc(t.summary,e,r(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function mc(t){return _(t)?{hour:u(t.hour),checked:u(t.checked)??0,acted:u(t.acted)??0,acted_names:B(t.acted_names),activity_report:r(t.activity_report),quiet_hours_overridden:z(t.quiet_hours_overridden),skipped_reason:r(t.skipped_reason),acted_rows:di(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:di(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:di(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(rm).filter(e=>e!==null):[]}:null}function dm(t){return _(t)?{enabled:z(t.enabled)??!1,interval_s:u(t.interval_s)??0,quiet_start:u(t.quiet_start),quiet_end:u(t.quiet_end),quiet_active:z(t.quiet_active),use_planner:z(t.use_planner),delegate_llm:z(t.delegate_llm),agent_count:u(t.agent_count),agents:B(t.agents),last_tick_ago_s:u(t.last_tick_ago_s)??null,last_tick_ago:r(t.last_tick_ago),total_ticks:u(t.total_ticks),total_checkins:u(t.total_checkins),last_skip_reason:r(t.last_skip_reason)??null,last_tick_result:mc(t.last_tick_result),active_self_heartbeats:B(t.active_self_heartbeats)}:null}function um(t){return _(t)?{status:t.status,diagnostic:la(t.diagnostic)}:null}function pm(t){return _(t)?{recovered:z(t.recovered)??!1,skipped_reason:r(t.skipped_reason)??null,before:la(t.before),after:la(t.after),down:t.down,up:t.up}:null}function mm(t,e){var C,M;if(!(t!=null&&t.name))return null;const n=r((C=t.agent)==null?void 0:C.status)??r(t.status)??"unknown",s=r((M=t.agent)==null?void 0:M.error)??null,a=t.presence_keepalive??!0,o=t.keepalive_running??!1,l=t.turn_count??0,c=t.last_turn_ago_s??null,d=t.proactive_enabled??!1,m=t.proactive_cooldown_sec??0,p=t.last_proactive_ago_s??null,v=d&&p!=null?Math.max(0,m-p):null,f=l<=0||c==null?"never":c>900?"stale":"fresh",$=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,S=s??(a&&!o?"keeper keepalive is not running":null),y=n==="offline"||n==="inactive"?"offline":S?"degraded":f==="stale"?"stale":f==="never"?"idle":"healthy",k=S?lm(S):e!=null&&e.quiet_active&&f!=="fresh"?"quiet_hours":a&&!o?"disabled":l<=0?"never_started":v!=null&&v>0?"min_gap":f==="fresh"||f==="stale"?"no_recent_activity":"unknown",h=y==="offline"||y==="degraded"||y==="stale"?"recover":k==="quiet_hours"?"manual_lodge_poke":k==="unknown"?"probe":"direct_message";return{health_state:y,quiet_reason:k,next_action_path:h,last_reply_status:f,last_reply_at:$,last_reply_preview:null,last_error:S,next_eligible_at_s:v!=null&&v>0?v:null,recoverable:pc(void 0,h),summary:uc(void 0,y,k),keepalive_running:o}}function _m(t,e){if(!_(t))return null;const n=im(t.role),s=r(t.content)??r(t.preview);if(!s)return null;const a=Us(s);if(!a)return null;const o=lt(t.ts_unix)??lt(t.timestamp);return{id:`${n}-${o??"entry"}-${e}`,role:n,label:om(n),text:a,timestamp:o,delivery:"history",streamState:null,details:null}}function vm(t,e,n){const s=_(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,l)=>_m(o,l)).filter(o=>o!==null):[];return{name:t,diagnostic:la(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function Xr(t,e){const n=$t.value[t]??[];$t.value={...$t.value,[t]:[...n,e].slice(-50)}}function No(t,e,n){const s=$t.value[t]??[];$t.value={...$t.value,[t]:s.map(a=>a.id===e?n(a):a)}}function ui(t,e,n,s){No(t,e,a=>({...a,streamState:n,delivery:s}))}function fm(t,e,n){No(t,e,s=>({...s,text:`${s.text}${n}`,streamState:"streaming",delivery:"streaming"}))}function Jt(t,e,n){No(t,e,s=>({...s,...n}))}function gm(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function $m(t,e){const s=($t.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(o=>gm(a,o)));$t.value={...$t.value,[t]:[...e,...s].slice(-50)}}function Ga(t,e){ne.value={...ne.value,[t]:e},$m(t,e.history)}function Ss(t,e){const n=ne.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ga(t,{...n,diagnostic:{...s,...e}})}function hm(t,e,n){zo.set(t,e),Po.set(t,n)}function _c(t){zo.delete(t),Po.delete(t)}function ym(t){return zo.get(t)??null}function vc(t){const e=t.trim();if(!e)return;const n=Po.get(e),s=ym(e);n&&n.abort(),s&&Jt(e,s,{delivery:"timeout",streamState:null,error:"Stream cancelled",timestamp:new Date().toISOString()}),_c(e),ct(ra,e,!1)}function bm(t,e,n){switch(n.type){case"RUN_STARTED":return ui(t,e,"opening","sending"),null;case"TEXT_MESSAGE_START":return ui(t,e,"streaming","streaming"),null;case"TEXT_MESSAGE_CONTENT":{const s=typeof n.delta=="string"?n.delta:"";return s&&fm(t,e,s),null}case"TEXT_MESSAGE_END":return ui(t,e,"finalizing","streaming"),null;case"CUSTOM":if(n.name==="KEEPER_REPLY_DETAILS"){const s=Zl(n.value);s&&Jt(t,e,{details:s})}return null;case"RUN_ERROR":return typeof n.value=="string"?n.value:(_(n.value)?r(n.value.message):null)??"Keeper stream failed";default:return null}}async function ca(){try{await ms()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function km(t){am.value=t.trim()}async function fc(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&ne.value[n])return ne.value[n];ct(Vi,n,!0),ct(Bt,n,null);try{const s=await $e("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=vm(n,s,a);return Ga(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return ct(Bt,n,a),null}finally{ct(Vi,n,!1)}}async function xm(t,e){var c;const n=t.trim(),s=e.trim();if(!n||!s)return;vc(n);const a=`local-${Date.now()}`,o=`reply-${Date.now()}`;Xr(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending",streamState:null,details:null}),Xr(n,{id:o,role:"assistant",label:n,text:"",timestamp:null,delivery:"sending",streamState:"opening",details:null}),ct(ra,n,!0),ct(Bt,n,null);const l=new AbortController;hm(n,o,l);try{Jt(n,a,{delivery:"delivered"}),await Xu(n,s,void 0,{signal:l.signal,onEvent:p=>{const v=bm(n,o,p);if(v)throw new Error(v)}});const d=($t.value[n]??[]).find(p=>p.id===o)??null,m=(d==null?void 0:d.text.trim())||"(empty reply)";Jt(n,o,{text:m,delivery:"delivered",streamState:null,timestamp:new Date().toISOString(),error:null}),Ss(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:m.slice(0,200),last_error:null})}catch(d){if(d instanceof Error&&d.name==="AbortError")throw Jt(n,o,{delivery:"timeout",streamState:null,error:"Stream cancelled",timestamp:new Date().toISOString()}),Ss(n,{last_reply_status:"error",last_error:"Stream cancelled"}),ct(Bt,n,"Stream cancelled"),d;if(!((c=($t.value[n]??[]).find(f=>f.id===o))!=null&&c.text.trim()))try{const f=await Yu(n,s);Jt(n,o,{text:f.text.trim()||"(empty reply)",delivery:"delivered",streamState:null,details:f.details,error:null,timestamp:new Date().toISOString()}),Jt(n,a,{delivery:"delivered",error:null}),Ss(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(f.text.trim()||"(empty reply)").slice(0,200),last_error:null}),await ca();return}catch{}const v=d instanceof Error?d.message:`Failed to send direct message to ${n}`;throw Jt(n,o,{delivery:"error",streamState:null,error:v,timestamp:new Date().toISOString()}),Jt(n,a,{delivery:"error",error:v}),Ss(n,{last_reply_status:"error",last_error:v}),ct(Bt,n,v),d}finally{_c(n),ct(ra,n,!1),await ca()}}async function Sm(t,e){const n=t.trim();if(!n)return null;ct(Xi,n,!0),ct(Bt,n,null);try{const s=await Ha({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=um(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const l=ne.value[n];Ga(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??$t.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ca(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw ct(Bt,n,a),s}finally{ct(Xi,n,!1)}}async function Cm(t,e){const n=t.trim();if(!n)return null;ct(Qi,n,!0),ct(Bt,n,null);try{const s=await Ha({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=pm(s.result),o=(a==null?void 0:a.after)??null;if(o){const l=ne.value[n];Ga(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??$t.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ca(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw ct(Bt,n,a),s}finally{ct(Qi,n,!1)}}function xe(t){return(t??"").trim().toLowerCase()}function ht(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Hs(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Cs(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function xn(t){return t.last_heartbeat??Cs(t.last_turn_ago_s)??Cs(t.last_proactive_ago_s)??Cs(t.last_handoff_ago_s)??Cs(t.last_compaction_ago_s)}function Am(t){const e=t.title.trim();return e||Hs(t.content)}function Tm(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Im(t,e,n,s,a={}){var M;const o=xe(t),l=e.filter(T=>xe(T.assignee)===o&&(T.status==="claimed"||T.status==="in_progress")).length,c=n.filter(T=>xe(T.from)===o).sort((T,P)=>ht(P.timestamp)-ht(T.timestamp))[0],d=s.filter(T=>xe(T.agent)===o||xe(T.author)===o).sort((T,P)=>ht(P.timestamp)-ht(T.timestamp))[0],m=(a.boardPosts??[]).filter(T=>xe(T.author)===o).sort((T,P)=>ht(P.updated_at||P.created_at)-ht(T.updated_at||T.created_at))[0],p=(a.keepers??[]).filter(T=>xe(T.name)===o&&xn(T)!==null).sort((T,P)=>ht(xn(P)??0)-ht(xn(T)??0))[0],v=c?ht(c.timestamp):0,f=d?ht(d.timestamp):0,$=m?ht(m.updated_at||m.created_at):0,S=p?ht(xn(p)??0):0,y=a.lastSeen?ht(a.lastSeen):0,k=((M=a.currentTask)==null?void 0:M.trim())||(l>0?`${l} claimed tasks`:null);if(v===0&&f===0&&$===0&&S===0&&y===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:k};const C=[c?{timestamp:c.timestamp,ts:v,text:Hs(c.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:$,text:`Post: ${Hs(Am(m))}`}:null,p?{timestamp:xn(p),ts:S,text:Tm(p)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:f,text:Hs(d.text)}:null].filter(T=>T!==null).sort((T,P)=>P.ts-T.ts)[0];return C&&C.ts>=y?{activeAssignedCount:l,lastActivityAt:C.timestamp,lastActivityText:C.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:k??"Presence heartbeat"}}const Ht=g([]),ce=g([]),Zi=g([]),se=g([]),ft=g(null),Rm=g(null),gc=g([]),$c=g([]),hc=g([]),yc=g([]),bc=g(null),kc=g([]),jo=g([]),xc=g([]),to=g(new Map),Ja=g([]),Un=g("recent"),Re=g(!0),Sc=g(null),te=g(""),nn=g([]),Ln=g(!1),Cc=g(new Map),Do=g("unknown"),sn=g(null),eo=g(!1),Wn=g(!1),no=g(!1),Pn=g(!1),wo=g(null),da=g(!1),ua=g(null),Ac=g(null),so=g(null),Mm=g(null),Em=g(null),Lm=g(null);Mt(()=>Ht.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const Tc=Mt(()=>{const t=ce.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Ic=Mt(()=>{const t=new Map,e=ce.value,n=Zi.value,s=aa.value,a=Ja.value,o=se.value;for(const l of Ht.value)t.set(l.name.trim().toLowerCase(),Im(l.name,e,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:o}));return t});function Pm(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}Mt(()=>{const t=new Map;for(const e of se.value)t.set(e.name,Pm(e));return t});const zm=12e4;function Nm(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}Mt(()=>{const t=Date.now(),e=new Set,n=to.value;for(const s of se.value){const a=Nm(s,n);a!=null&&t-a>zm&&e.add(s.name)}return e});function jm(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function Rc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Dm(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function wm(t){if(!_(t))return null;const e=r(t.name);return e?{name:e,agent_type:r(t.agent_type),status:Rc(t.status),current_task:r(t.current_task)??null,joined_at:r(t.joined_at),last_seen:r(t.last_seen),capabilities:B(t.capabilities),emoji:r(t.emoji),koreanName:r(t.koreanName)??r(t.korean_name),model:r(t.model),traits:B(t.traits),interests:B(t.interests),activityLevel:u(t.activityLevel)??u(t.activity_level),primaryValue:r(t.primaryValue)??r(t.primary_value)}:null}function Om(t){if(!_(t))return null;const e=r(t.id),n=r(t.title);return!e||!n?null:{id:e,title:n,status:Dm(t.status),priority:u(t.priority),assignee:r(t.assignee),description:r(t.description),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function qm(t){if(!_(t))return null;const e=r(t.from)??r(t.from_agent)??"system",n=r(t.content)??"",s=r(t.timestamp)??new Date().toISOString();return{id:r(t.id),seq:u(t.seq),from:e,content:n,timestamp:s,type:r(t.type)}}function Oo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="ok"||e==="warn"||e==="bad"?e:"ok"}function de(t){if(!_(t))return null;const e=r(t.surface),n=r(t.label),s=r(t.target_type),a=r(t.target_id),o=r(t.focus_kind);return!e||!n||!s||!a||!o?null:{surface:e==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:o,operation_id:r(t.operation_id)??null,command_surface:r(t.command_surface)??null}}function Fm(t){if(!_(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.summary),a=r(t.target_type),o=r(t.target_id);return!e||!s||!a||!o||n!=="session"&&n!=="operation"?null:{id:e,kind:n,severity:Oo(t.severity),status:r(t.status),summary:s,target_type:a,target_id:o,linked_session_id:r(t.linked_session_id)??null,linked_operation_id:r(t.linked_operation_id)??null,last_seen_at:r(t.last_seen_at)??null,top_handoff:de(t.top_handoff),intervene_handoff:de(t.intervene_handoff),command_handoff:de(t.command_handoff)}}function Bm(t){if(!_(t))return null;const e=r(t.session_id),n=r(t.goal);return!e||!n?null:{session_id:e,goal:n,room:r(t.room)??null,status:r(t.status),health:r(t.health),member_names:B(t.member_names),linked_operation_id:r(t.linked_operation_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,runtime_blocker:r(t.runtime_blocker)??null,worker_gap_summary:r(t.worker_gap_summary)??null,last_activity_at:r(t.last_activity_at)??null,last_activity_summary:r(t.last_activity_summary)??null,communication_summary:r(t.communication_summary)??null,active_count:u(t.active_count),required_count:u(t.required_count),top_handoff:de(t.top_handoff),intervene_handoff:de(t.intervene_handoff),command_handoff:de(t.command_handoff)}}function Km(t){if(!_(t))return null;const e=r(t.operation_id),n=r(t.objective);return!e||!n?null:{operation_id:e,objective:n,status:r(t.status),stage:r(t.stage)??null,assigned_unit_id:r(t.assigned_unit_id)??null,assigned_unit_label:r(t.assigned_unit_label)??null,linked_session_id:r(t.linked_session_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,blocker_summary:r(t.blocker_summary)??null,search_status:r(t.search_status)??null,next_tool:r(t.next_tool)??null,updated_at:r(t.updated_at)??null,top_handoff:de(t.top_handoff),command_handoff:de(t.command_handoff)}}function Qr(t){if(!_(t))return null;const e=r(t.name)??r(t.agent_name),n=r(t.note),s=r(t.focus),a=r(t.state);return!e||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline"?null:{name:e,agent_name:r(t.agent_name),status:r(t.status),tone:Oo(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,active_task_count:u(t.active_task_count),related_session_id:r(t.related_session_id)??null,related_operation_id:r(t.related_operation_id)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),model:r(t.model)??null,recent_output_preview:r(t.recent_output_preview)??null,recent_event:r(t.recent_event)??null}}function Um(t){return _(t)?{checked:u(t.checked),acted:u(t.acted),passed:u(t.passed),skipped:u(t.skipped),failed:u(t.failed),last_tick_at:r(t.last_tick_at)??null,last_skip_reason:r(t.last_skip_reason)??null,activity_report:r(t.activity_report)??null}:null}function Wm(t){if(!_(t))return null;const e=r(t.agent_name),n=r(t.outcome);return!e||!n?null:{agent_name:e,trigger:r(t.trigger)??null,outcome:n,summary:r(t.summary)??null,reason:r(t.reason)??null,allowed_tool_names:B(t.allowed_tool_names)??[],used_tool_names:B(t.used_tool_names)??[],used_tool_call_count:u(t.used_tool_call_count)??null,action_kind:r(t.action_kind)??"none",tool_audit_source:r(t.tool_audit_source)??null,tool_audit_at:r(t.tool_audit_at)??null,checked_at:r(t.checked_at)??null,decision_reason:r(t.decision_reason)??null,worker_name:r(t.worker_name)??null,failure_reason:r(t.failure_reason)??null}}function Hm(t){if(!_(t))return null;const e=r(t.name),n=r(t.note),s=r(t.focus),a=r(t.state);return!e||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:e,agent_name:r(t.agent_name)??null,status:r(t.status),tone:Oo(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,last_autonomous_action_at:r(t.last_autonomous_action_at)??null,generation:u(t.generation),turn_count:u(t.turn_count),context_ratio:u(t.context_ratio)??null,continuity:r(t.continuity)??null,lifecycle:r(t.lifecycle)??null,related_session_id:r(t.related_session_id)??null,model:r(t.model)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),skill_reason:r(t.skill_reason)??null,recent_input_preview:r(t.recent_input_preview)??null,recent_output_preview:r(t.recent_output_preview)??null,recent_tool_names:B(t.recent_tool_names)??[],allowed_tool_names:B(t.allowed_tool_names)??[],latest_tool_names:B(t.latest_tool_names)??[],latest_tool_call_count:u(t.latest_tool_call_count)??null,tool_audit_source:r(t.tool_audit_source)??null,tool_audit_at:r(t.tool_audit_at)??null,last_proactive_preview:r(t.last_proactive_preview)??null,continuity_summary:r(t.continuity_summary)??null,skill_route_summary:r(t.skill_route_summary)??null}}function Zr(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function Gm(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>Zr(s)-Zr(a)).slice(-500)}function Jm(t){return Array.isArray(t)?t.map(e=>{if(!_(e))return null;const n=u(e.ts_unix);if(n==null)return null;const s=_(e.handoff)?e.handoff:null;return{ts:n,context_ratio:u(e.context_ratio)??0,context_tokens:u(e.context_tokens)??0,context_max:u(e.context_max)??0,latency_ms:u(e.latency_ms)??0,generation:u(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:u(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:u(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?u(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function tl(t){if(!_(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);if(!e||!n||!s)return null;const a=r(t.quiet_reason)??null,o=r(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:lt(t.last_reply_at)??r(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:u(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:o,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Ym(t,e){return(Array.isArray(t)?t:_(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!_(s))return null;const a=_(s.agent)?s.agent:null,o=_(s.context)?s.context:null,l=_(s.metrics_window)?s.metrics_window:void 0,c=r(s.name);if(!c)return null;const d=u(s.context_ratio)??u(o==null?void 0:o.context_ratio),m=r(s.status)??r(a==null?void 0:a.status)??"offline",p=Rc(m),v=r(s.model)??r(s.active_model)??r(s.primary_model),f=B(s.skill_secondary),$=o?{source:r(o.source),context_ratio:u(o.context_ratio),context_tokens:u(o.context_tokens),context_max:u(o.context_max),message_count:u(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,S=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:u(a.last_seen_ago_s),capabilities:B(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,y=Jm(s.metrics_series),k={name:c,runtime_class:s.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:typeof s.desired=="boolean"?s.desired:void 0,resident_registered:typeof s.resident_registered=="boolean"?s.resident_registered:void 0,reconcile_status:r(s.reconcile_status)??null,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:v,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:p,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:u(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:u(s.proactive_idle_sec),proactive_cooldown_sec:u(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:u(s.generation),turn_count:u(s.turn_count)??u(s.total_turns),keeper_age_s:u(s.keeper_age_s),last_turn_ago_s:u(s.last_turn_ago_s),last_handoff_ago_s:u(s.last_handoff_ago_s),last_compaction_ago_s:u(s.last_compaction_ago_s),last_proactive_ago_s:u(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:d,context_tokens:u(s.context_tokens)??u(o==null?void 0:o.context_tokens),context_max:u(s.context_max)??u(o==null?void 0:o.context_max),context_source:r(s.context_source)??r(o==null?void 0:o.source),context:$,traits:B(s.traits),interests:B(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:u(s.activityLevel)??u(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:B(s.recent_tool_names)??[],allowed_tool_names:B(s.allowed_tool_names)??[],latest_tool_names:B(s.latest_tool_names)??[],latest_tool_call_count:u(s.latest_tool_call_count)??null,tool_audit_source:r(s.tool_audit_source)??null,tool_audit_at:lt(s.tool_audit_at)??r(s.tool_audit_at)??null,conversation_tail_count:u(s.conversation_tail_count),k2k_count:u(s.k2k_count),handoff_count_total:u(s.handoff_count_total)??u(s.trace_history_count),compaction_count:u(s.compaction_count),last_compaction_saved_tokens:u(s.last_compaction_saved_tokens),diagnostic:tl(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:f,skill_reason:r(s.skill_reason)??null,metrics_series:y.length>0?y:void 0,metrics_window:l,agent:S};return k.diagnostic=tl(s.diagnostic)??mm(k,(e==null?void 0:e.lodge)??null),k}).filter(s=>s!==null)}function Vm(t){if(!_(t))return;const e=r(t.release_version),n=lt(t.started_at),s=u(t.uptime_seconds);if(!(!e||!n||s==null))return{release_version:e,commit:r(t.commit)??null,started_at:n,uptime_seconds:s}}function Xm(t){if(_(t))return{enabled:t.enabled===!0,alive:t.alive===!0,status:r(t.status)??void 0,tick_in_progress:typeof t.tick_in_progress=="boolean"?t.tick_in_progress:void 0,tick_count:u(t.tick_count)??void 0,check_interval_sec:u(t.check_interval_sec)??void 0,last_tick_started_at:lt(t.last_tick_started_at)??r(t.last_tick_started_at)??null,last_tick_completed_at:lt(t.last_tick_completed_at)??r(t.last_tick_completed_at)??null,next_tick_due_at:lt(t.next_tick_due_at)??r(t.next_tick_due_at)??null,last_health_check_at:lt(t.last_health_check_at)??r(t.last_health_check_at)??null,last_intervention:r(t.last_intervention)??void 0,last_decision_source:r(t.last_decision_source)??void 0,last_action:r(t.last_action)??void 0,last_target:r(t.last_target)??null,last_reason:r(t.last_reason)??null,last_error:r(t.last_error)??null,circuit_open:typeof t.circuit_open=="boolean"?t.circuit_open:void 0,circuit_open_until:lt(t.circuit_open_until)??r(t.circuit_open_until)??null,can_spawn:typeof t.can_spawn=="boolean"?t.can_spawn:void 0,can_retire:typeof t.can_retire=="boolean"?t.can_retire:void 0,last_spawn_attempt_at:lt(t.last_spawn_attempt_at)??r(t.last_spawn_attempt_at)??null,last_retirement_attempt_at:lt(t.last_retirement_attempt_at)??r(t.last_retirement_attempt_at)??null,spawns_today:u(t.spawns_today)??void 0,retirements_today:u(t.retirements_today)??void 0,health_summary:_(t.health_summary)?{total_agents:u(t.health_summary.total_agents)??void 0,active_agents:u(t.health_summary.active_agents)??void 0,idle_agents:u(t.health_summary.idle_agents)??void 0,todo_count:u(t.health_summary.todo_count)??void 0,high_priority_todo:u(t.health_summary.high_priority_todo)??void 0,orphan_count:u(t.health_summary.orphan_count)??void 0,homeostatic_score:u(t.health_summary.homeostatic_score)??void 0,needs_workers:typeof t.health_summary.needs_workers=="boolean"?t.health_summary.needs_workers:void 0}:void 0}}function Qm(t){if(_(t))return{enabled:t.enabled===!0,mode:r(t.mode)??void 0,masc_enabled:typeof t.masc_enabled=="boolean"?t.masc_enabled:void 0,masc_loops_running:typeof t.masc_loops_running=="boolean"?t.masc_loops_running:void 0,runtime_owner:r(t.runtime_owner)??null,zombie_loop_running:typeof t.zombie_loop_running=="boolean"?t.zombie_loop_running:void 0,gc_loop_running:typeof t.gc_loop_running=="boolean"?t.gc_loop_running:void 0,lodge_enabled:typeof t.lodge_enabled=="boolean"?t.lodge_enabled:void 0,lodge_loop_started:typeof t.lodge_loop_started=="boolean"?t.lodge_loop_started:void 0,lodge_running:typeof t.lodge_running=="boolean"?t.lodge_running:void 0,last_zombie_cleanup:lt(t.last_zombie_cleanup)??r(t.last_zombie_cleanup)??null,last_gc:lt(t.last_gc)??r(t.last_gc)??null,last_lodge:lt(t.last_lodge)??r(t.last_lodge)??null,last_zombie_result:r(t.last_zombie_result)??null,last_gc_result:r(t.last_gc_result)??null,last_lodge_result:_(t.last_lodge_result)?{ok:typeof t.last_lodge_result.ok=="boolean"?t.last_lodge_result.ok:void 0,message:r(t.last_lodge_result.message)??void 0}:null}}function Zm(t){if(_(t))return{enabled:t.enabled===!0,started:t.started===!0,agent_name:r(t.agent_name)??null,llm_enabled:typeof t.llm_enabled=="boolean"?t.llm_enabled:void 0,uptime_s:u(t.uptime_s)??void 0,embedded_guardian_loops_running:typeof t.embedded_guardian_loops_running=="boolean"?t.embedded_guardian_loops_running:void 0,guardian_runtime_owner:r(t.guardian_runtime_owner)??null,consumers:B(t.consumers)}}function Mc(t,e){return _(t)?{...t,generated_at:e??lt(t.generated_at)??void 0,build:Vm(t.build),lodge:dm(t.lodge)??void 0,gardener:Xm(t.gardener)??void 0,guardian:Qm(t.guardian)??void 0,sentinel:Zm(t.sentinel)??void 0}:null}function Ec(t,e){return e?t?{...t,...e,build:e.build??t.build,generated_at:e.generated_at??t.generated_at}:e:t}function t_(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function e_(t){if(!_(t))return null;const e=u(t.iteration);if(e==null)return null;const n=u(t.metric_before)??0,s=u(t.metric_after)??n,a=_(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:u(t.delta)??s-n,changes:r(t.changes)??"",failed_attempts:r(t.failed_attempts)??"",next_suggestion:r(t.next_suggestion)??"",elapsed_ms:u(t.elapsed_ms)??0,cost_usd:u(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:u(a.tool_call_count)??0,tool_names:B(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function n_(t){var o,l;if(!_(t))return null;const e=r(t.loop_id);if(!e)return null;const n=u(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(e_).filter(c=>c!==null):[],a=u(t.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:r(t.profile)??"unknown",status:t_(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:r(t.error_message)??r(t.error_reason)??null,stop_reason:r(t.stop_reason)??r(t.reason)??null,current_iteration:u(t.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:u(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(t.target)??"",stagnation_streak:u(t.stagnation_streak)??0,stagnation_limit:u(t.stagnation_limit)??0,elapsed_seconds:u(t.elapsed_seconds)??0,updated_at:lt(t.updated_at)??null,stopped_at:lt(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:u(t.latest_tool_call_count)??0,latest_tool_names:B(t.latest_tool_names)??[],session_id:r(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function ms(){eo.value=!0;try{await Promise.all([Pc(),Me()]),Ac.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{eo.value=!1}}async function Lc(){da.value=!0,ua.value=null;try{const t=await sp();wo.value=t,Lm.value=new Date().toISOString()}catch(t){ua.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{da.value=!1}}function s_(t){var e;return((e=wo.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function a_(t){var n;const e=((n=wo.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(o=>o.id===t);if(a)return a}return null}function i_(t){var s,a;nn.value=(Array.isArray(t.goals)?t.goals:[]).map(o=>{if(!_(o))return null;const l=r(o.id),c=r(o.title),d=r(o.horizon),m=r(o.status),p=r(o.created_at),v=r(o.updated_at);return!l||!c||!d||!m||!p||!v?null:{id:l,horizon:d,title:c,metric:r(o.metric)??null,target_value:r(o.target_value)??null,due_date:r(o.due_date)??null,priority:u(o.priority)??3,status:m,parent_goal_id:r(o.parent_goal_id)??null,last_review_note:r(o.last_review_note)??null,last_review_at:r(o.last_review_at)??null,created_at:p,updated_at:v}}).filter(o=>o!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const o of n){const l=n_(o);l&&e.set(l.loop_id,l)}Cc.value=e,sn.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,Do.value=sn.value?"error":e.size===0?"idle":"ready"}async function Pc(){try{const t=await Qu(),e=Mc(t.status,t.generated_at);e&&(ft.value=Ec(ft.value,e))}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Me(){var t;try{const e=await tp(),n=Mc(e.status,e.generated_at),s=(t=ft.value)==null?void 0:t.room;n&&(ft.value=Ec(ft.value,n));const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Ht.value=(Array.isArray(e.agents)?e.agents:[]).map(wm).filter(l=>l!==null),ce.value=(Array.isArray(e.tasks)?e.tasks:[]).map(Om).filter(l=>l!==null);const o=(Array.isArray(e.messages)?e.messages:[]).map(qm).filter(l=>l!==null);Zi.value=a?o:Gm(Zi.value,o),se.value=Ym(e.keepers,n??ft.value),bc.value=Um(e.lodge_tick),kc.value=(Array.isArray(e.lodge_checkins)?e.lodge_checkins:[]).map(Wm).filter(l=>l!==null),gc.value=(Array.isArray(e.execution_queue)?e.execution_queue:Array.isArray(e.priority_queue)?e.priority_queue:[]).map(Fm).filter(l=>l!==null),$c.value=(Array.isArray(e.session_briefs)?e.session_briefs:[]).map(Bm).filter(l=>l!==null),hc.value=(Array.isArray(e.operation_briefs)?e.operation_briefs:[]).map(Km).filter(l=>l!==null),yc.value=(Array.isArray(e.worker_support_briefs)?e.worker_support_briefs:Array.isArray(e.worker_briefs)?e.worker_briefs:[]).map(Qr).filter(l=>l!==null),jo.value=(Array.isArray(e.continuity_briefs)?e.continuity_briefs:[]).map(Hm).filter(l=>l!==null),xc.value=(Array.isArray(e.offline_worker_briefs)?e.offline_worker_briefs:[]).map(Qr).filter(l=>l!==null),Rm.value=null,Ac.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function ue(){Wn.value=!0;try{const t=await ep(Un.value,{excludeSystem:Re.value});Ja.value=t.posts??[],so.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Wn.value=!1}}async function pe(){var t;no.value=!0;try{const e=te.value||((t=ft.value)==null?void 0:t.room)||"default";te.value||(te.value=e);const n=await Kp(e);Sc.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{no.value=!1}}async function qo(){Ln.value=!0,Pn.value=!0;try{const t=await lp();i_(t),Mm.value=new Date().toISOString(),Em.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),Do.value="error",sn.value=t instanceof Error?t.message:String(t)}finally{Ln.value=!1,Pn.value=!1}}async function zc(){return qo()}const Fo=g(null),ao=g(!1),pa=g(null);function o_(t){return _(t)?{room:r(t.room)??r(t.current_room),room_base_path:r(t.room_base_path),cluster:r(t.cluster),project:r(t.project),paused:z(t.paused),version:r(t.version),generated_at:r(t.generated_at),tempo_interval_s:u(t.tempo_interval_s)}:null}function r_(t){return _(t)?{active_sessions:u(t.active_sessions),blocked_sessions:u(t.blocked_sessions),active_operations:u(t.active_operations),blocked_operations:u(t.blocked_operations),runtime_pressure:u(t.runtime_pressure),worker_alerts:u(t.worker_alerts),continuity_alerts:u(t.continuity_alerts),priority_items:u(t.priority_items),keepers:u(t.keepers)}:null}function l_(t){if(!_(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.severity),a=r(t.summary),o=r(t.target_type),l=r(t.target_id);return!e||!n||!s||!a||!o||!l?null:{id:e,kind:n,severity:s,summary:a,target_type:o,target_id:l,status:r(t.status),linked_session_id:r(t.linked_session_id)??null,linked_operation_id:r(t.linked_operation_id)??null,last_seen_at:r(t.last_seen_at)??null,top_handoff:_(t.top_handoff)?t.top_handoff:null,intervene_handoff:_(t.intervene_handoff)?t.intervene_handoff:null,command_handoff:_(t.command_handoff)?t.command_handoff:null}}function c_(t){if(!_(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function d_(t){if(!_(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:z(t.confirm_required),suggested_payload:_(t.suggested_payload)?t.suggested_payload:void 0,preview:t.preview}}function u_(t){return _(t)?{actor_filter:r(t.actor_filter)??null,filter_active:z(t.filter_active)??!1,visible_count:u(t.visible_count)??0,total_count:u(t.total_count)??0,hidden_count:u(t.hidden_count)??0,hidden_actors:B(t.hidden_actors),confirm_required_actions:mt(t.confirm_required_actions).flatMap(e=>{if(!_(e))return[];const n=r(e.action_type),s=r(e.target_type);return!n||!s?[]:[{action_type:n,target_type:s,description:r(e.description),confirm_required:z(e.confirm_required)}]})}:null}function p_(t){return _(t)?{count:u(t.count)??0,bad_count:u(t.bad_count)??0,warn_count:u(t.warn_count)??0,provenance:r(t.provenance)??null,top_item:c_(t.top_item)}:null}function m_(t){return _(t)?{count:u(t.count)??0,provenance:r(t.provenance)??null,top_action:d_(t.top_action)}:null}function __(t){if(!_(t))return null;const e=r(t.label),n=r(t.reason),s=r(t.source),a=r(t.provenance);return!e||!n||!s||!a?null:{label:e,reason:n,source:s,provenance:a,target_kind:r(t.target_kind)??null,target_id:r(t.target_id)??null,suggested_tab:r(t.suggested_tab)??null,suggested_surface:r(t.suggested_surface)??null,suggested_params:_(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([o,l])=>{const c=r(l);return c?[o,c]:null}).filter(o=>o!==null)):{}}}function v_(t){const e=_(t)?t:{},n=_(e.room)?e.room:{},s=_(e.execution)?e.execution:{},a=_(e.command)?e.command:{},o=_(e.operator)?e.operator:{};return{generated_at:r(e.generated_at),room:{status:o_(n.status),counts:_(n.counts)?{agents:u(n.counts.agents),tasks:u(n.counts.tasks),keepers:u(n.counts.keepers)}:void 0,provenance:r(n.provenance)??null},execution:{summary:r_(s.summary),top_queue:l_(s.top_queue),provenance:r(s.provenance)??null},command:{active_operations:u(a.active_operations),active_detachments:u(a.active_detachments),pending_approvals:u(a.pending_approvals),bad_alerts:u(a.bad_alerts),warn_alerts:u(a.warn_alerts),moving_lanes:u(a.moving_lanes),active_lanes:u(a.active_lanes),provenance:r(a.provenance)??null},operator:{health:r(o.health)??null,attention_summary:p_(o.attention_summary),recommendation_summary:m_(o.recommendation_summary),pending_confirm_summary:u_(o.pending_confirm_summary),provenance:r(o.provenance)??null},focus:__(e.focus)}}async function Ee(){ao.value=!0,pa.value=null;try{const t=await Zu();Fo.value=v_(t)}catch(t){pa.value=t instanceof Error?t.message:"Failed to load room truth"}finally{ao.value=!1}}let Gs=null;function f_(t){Gs=t}let Js=null;function g_(t){Js=t}let Ys=null;function $_(t){Ys=t}const Le={};let pi=null;function Se(t,e,n=500){Le[t]&&clearTimeout(Le[t]),Le[t]=setTimeout(()=>{e(),delete Le[t]},n)}function h_(){const t=Vl.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(to.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),to.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&Se("execution",Me),jm(e.type)&&(pi||(pi=setTimeout(()=>{ms(),Js==null||Js(),Ys==null||Ys(),pi=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&Se("execution",Me),e.type==="broadcast"&&Se("execution",Me),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&Se("execution",Me),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&Se("board",ue),e.type.startsWith("decision_")&&Se("council",()=>Gs==null?void 0:Gs()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&Se("mdal",zc,350)}});return()=>{t();for(const e of Object.keys(Le))clearTimeout(Le[e]),delete Le[e]}}let zn=null;function y_(){zn||(zn=setInterval(()=>{ve.value,ms()},1e4))}function b_(){zn&&(clearInterval(zn),zn=null)}const Et=g(null),Bo=g(null),Ut=g(null),Hn=g(!1),fe=g(null),Gn=g(!1),mn=g(null),nt=g(!1),ma=g([]);let k_=1;function x_(t){return _(t)?{id:r(t.id),seq:u(t.seq),from:r(t.from)??r(t.from_agent)??"system",content:r(t.content)??"",timestamp:r(t.timestamp)??new Date().toISOString(),type:r(t.type)}:null}function S_(t){return _(t)?{room_id:r(t.room_id),current_room:r(t.current_room)??r(t.room),project:r(t.project),cluster:r(t.cluster),paused:z(t.paused),pause_reason:r(t.pause_reason)??null,paused_by:r(t.paused_by)??null,paused_at:r(t.paused_at)??null}:{}}function el(t){if(!_(t))return;const e=Object.entries(t).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Nc(t){if(!_(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function Nn(t){if(!_(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:z(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function jc(t){return _(t)?{enabled:z(t.enabled),judge_online:z(t.judge_online),refreshing:z(t.refreshing),generated_at:r(t.generated_at)??null,expires_at:r(t.expires_at)??null,model_used:r(t.model_used)??null,keeper_name:r(t.keeper_name)??null,last_error:r(t.last_error)??null}:null}function mi(t){return _(t)?{summary:r(t.summary)??null,confidence:u(t.confidence)??null,provenance:r(t.provenance)??null,authoritative:z(t.authoritative),surface:r(t.surface)??null,fresh_until:r(t.fresh_until)??null,keeper_name:r(t.keeper_name)??null,fallback_used:z(t.fallback_used),disagreement_with_truth:z(t.disagreement_with_truth)}:null}function C_(t){return _(t)?{judgment_id:r(t.judgment_id)??void 0,surface:r(t.surface)??null,target_type:r(t.target_type)??null,target_id:r(t.target_id)??null,status:r(t.status)??null,summary:r(t.summary)??null,confidence:u(t.confidence)??null,generated_at:r(t.generated_at)??null,fresh_until:r(t.fresh_until)??null,keeper_name:r(t.keeper_name)??null,model_name:r(t.model_name)??null,runtime_name:r(t.runtime_name)??null,evidence_refs:B(t.evidence_refs),recommended_action:Nn(t.recommended_action),supersedes:B(t.supersedes),fallback_used:z(t.fallback_used),disagreement_with_truth:z(t.disagreement_with_truth),provenance:r(t.provenance)??null}:null}function A_(t){return _(t)?{actor:r(t.actor)??null,spawn_agent:r(t.spawn_agent)??null,spawn_role:r(t.spawn_role)??null,spawn_model:r(t.spawn_model)??null,worker_class:r(t.worker_class)??null,parent_actor:r(t.parent_actor)??null,capsule_mode:r(t.capsule_mode)??null,runtime_pool:r(t.runtime_pool)??null,lane_id:r(t.lane_id)??null,controller_level:r(t.controller_level)??null,control_domain:r(t.control_domain)??null,supervisor_actor:r(t.supervisor_actor)??null,model_tier:r(t.model_tier)??null,task_profile:r(t.task_profile)??null,risk_level:r(t.risk_level)??null,routing_confidence:u(t.routing_confidence)??null,routing_reason:r(t.routing_reason)??null,status:r(t.status)??"unknown",turn_count:u(t.turn_count)??0,empty_note_turn_count:u(t.empty_note_turn_count)??0,has_turn:z(t.has_turn)??!1,last_turn_ts_iso:r(t.last_turn_ts_iso)??null}:null}function T_(t){if(!_(t))return null;const e=r(t.session_id);return e?{session_id:e,goal:r(t.goal),status:r(t.status),health:r(t.health),scale_profile:r(t.scale_profile),control_profile:r(t.control_profile),planned_worker_count:u(t.planned_worker_count),active_agent_count:u(t.active_agent_count),last_turn_age_sec:u(t.last_turn_age_sec)??null,attention_count:u(t.attention_count),recommended_action_count:u(t.recommended_action_count),top_attention:Nc(t.top_attention),top_recommendation:Nn(t.top_recommendation)}:null}function nl(t){return _(t)?{loop_id:r(t.loop_id)??null,session_id:r(t.session_id)??null,status:r(t.status)??null,current_cycle:u(t.current_cycle)??void 0,best_score:u(t.best_score)??null,last_decision:r(t.last_decision)??null,target_file:r(t.target_file)??null,program_note:r(t.program_note)??null,operation_id:r(t.operation_id)??null,error:r(t.error)??null}:null}function Dc(t){const e=_(t)?t:{};return{trace_id:r(e.trace_id),target_type:r(e.target_type)??"room",target_id:r(e.target_id)??null,health:r(e.health),judgment_owner:r(e.judgment_owner)??null,authoritative_judgment_available:z(e.authoritative_judgment_available),resident_judge_runtime:jc(e.resident_judge_runtime),judgment:C_(e.judgment),active_guidance_layer:r(e.active_guidance_layer)??null,active_summary:mi(e.active_summary),active_recommended_actions:mt(e.active_recommended_actions).map(Nn).filter(n=>n!==null),active_recommendation_source:r(e.active_recommendation_source)??null,active_recommendation_summary:mi(e.active_recommendation_summary),fallback_recommended_actions:mt(e.fallback_recommended_actions).map(Nn).filter(n=>n!==null),recommendation_summary:mi(e.recommendation_summary),swarm_status:_(e.swarm_status)?e.swarm_status:void 0,attention_items:mt(e.attention_items).map(Nc).filter(n=>n!==null),recommended_actions:mt(e.recommended_actions).map(Nn).filter(n=>n!==null),session_cards:mt(e.session_cards).map(T_).filter(n=>n!==null),worker_cards:mt(e.worker_cards).map(A_).filter(n=>n!==null)}}function I_(t){if(!_(t))return null;const e=_(t.status)?t.status:void 0,n=_(t.summary)?t.summary:_(e==null?void 0:e.summary)?e.summary:void 0,s=_(t.session)?t.session:_(e==null?void 0:e.session)?e.session:void 0,a=r(t.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const o=el(t.report_paths)??el(e==null?void 0:e.report_paths),l=mt(t.recent_events,["events"]).filter(_);return{session_id:a,status:r(t.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:u(t.progress_pct)??u(n==null?void 0:n.progress_pct),elapsed_sec:u(t.elapsed_sec)??u(n==null?void 0:n.elapsed_sec),remaining_sec:u(t.remaining_sec)??u(n==null?void 0:n.remaining_sec),done_delta_total:u(t.done_delta_total)??u(n==null?void 0:n.done_delta_total),summary:n,team_health:_(t.team_health)?t.team_health:_(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:_(t.communication_metrics)?t.communication_metrics:_(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:_(t.orchestration_state)?t.orchestration_state:_(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:_(t.cascade_metrics)?t.cascade_metrics:_(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,linked_autoresearch:nl(t.linked_autoresearch)??nl(e==null?void 0:e.linked_autoresearch)??null,session:s,recent_events:l}}function sl(t){if(!_(t))return null;const e=r(t.name);if(!e)return null;const n=_(t.context)?t.context:void 0;return{name:e,runtime_class:t.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:z(t.desired),resident_registered:z(t.resident_registered),agent_name:r(t.agent_name),status:r(t.status),autonomy_level:r(t.autonomy_level),context_ratio:u(t.context_ratio)??u(n==null?void 0:n.context_ratio),generation:u(t.generation),active_goal_ids:B(t.active_goal_ids),last_autonomous_action_at:r(t.last_autonomous_action_at)??null,last_turn_ago_s:u(t.last_turn_ago_s),model:r(t.model)??r(t.active_model)??r(t.primary_model)}}function R_(t){if(!_(t))return null;const e=r(t.confirm_token)??r(t.token);return e?{confirm_token:e,actor:r(t.actor),action_type:r(t.action_type),target_type:r(t.target_type),target_id:r(t.target_id)??null,delegated_tool:r(t.delegated_tool),created_at:r(t.created_at),preview:t.preview}:null}function wc(t){if(!_(t))return null;const e=r(t.action_type),n=r(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:r(t.description),confirm_required:z(t.confirm_required)}}function M_(t){return _(t)?{actor_filter:r(t.actor_filter)??null,filter_active:z(t.filter_active)??!1,visible_count:u(t.visible_count)??0,total_count:u(t.total_count)??0,hidden_count:u(t.hidden_count)??0,hidden_actors:B(t.hidden_actors),confirm_required_actions:mt(t.confirm_required_actions).map(wc).filter(e=>e!==null)}:null}function E_(t){const e=_(t)?t:{};return{room:S_(e.room),sessions:mt(e.sessions,["items","sessions"]).map(I_).filter(n=>n!==null),keepers:mt(e.keepers,["items","keepers"]).map(sl).filter(n=>n!==null),resident_judge_runtime:jc(e.resident_judge_runtime),persistent_agents:mt(e.persistent_agents,["items","persistent_agents"]).map(sl).filter(n=>n!==null),recent_messages:mt(e.recent_messages,["messages"]).map(x_).filter(n=>n!==null),pending_confirms:mt(e.pending_confirms,["items","confirms"]).map(R_).filter(n=>n!==null),pending_confirm_summary:M_(e.pending_confirm_summary)??void 0,available_actions:mt(e.available_actions,["actions"]).map(wc).filter(n=>n!==null)}}function As(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function al(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function _a(t){ma.value=[{...t,id:k_++,at:new Date().toISOString()},...ma.value].slice(0,20)}function Oc(t){return t.confirm_required?As(t.preview)||"Confirmation required":As(t.result)||As(t.executed_action)||As(t.delegated_tool_result)||t.status}async function gt(){Hn.value=!0,fe.value=null;try{const t=await up();Et.value=E_(t)}catch(t){fe.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Hn.value=!1}}async function we(){Gn.value=!0,mn.value=null;try{const t=await sc({targetType:"room"});Bo.value=Dc(t)}catch(t){mn.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{Gn.value=!1}}async function Oe(t){if(!t){Ut.value=null;return}Gn.value=!0,mn.value=null;try{const e=await sc({targetType:"team_session",targetId:t,includeWorkers:!0});Ut.value=Dc(e)}catch(e){mn.value=e instanceof Error?e.message:"Failed to load session digest"}finally{Gn.value=!1}}async function qc(t){var e;nt.value=!0,fe.value=null;try{const n=await Ha(t);return _a({actor:t.actor,action_type:t.action_type,target_label:al(t),outcome:n.confirm_required?"preview":"executed",message:Oc(n),delegated_tool:n.delegated_tool}),await gt(),await we(),(e=Ut.value)!=null&&e.target_id&&await Oe(Ut.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw fe.value=s,_a({actor:t.actor,action_type:t.action_type,target_label:al(t),outcome:"error",message:s}),n}finally{nt.value=!1}}async function Fc(t,e,n="confirm"){var s;nt.value=!0,fe.value=null;try{const a=await ac(t,e,n);return _a({actor:t,action_type:n,target_label:e,outcome:"confirmed",message:Oc(a),delegated_tool:a.delegated_tool}),await gt(),await we(),(s=Ut.value)!=null&&s.target_id&&await Oe(Ut.value.target_id),a}catch(a){const o=a instanceof Error?a.message:"Operator confirmation failed";throw fe.value=o,_a({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:o}),a}finally{nt.value=!1}}$_(()=>{var t;gt(),we(),(t=Ut.value)!=null&&t.target_id&&Oe(Ut.value.target_id)});const Ya=g(null),io=g(!1),va=g(null),Bc=g(null),He=g(!1),Ie=g(null),oo=g(null),Vs=g(!1),Xs=g(null);let an=null;function il(){an!==null&&(window.clearTimeout(an),an=null)}function L_(t=1500){an===null&&(an=window.setTimeout(()=>{an=null,fa(!1)},t))}function D(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function q(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function on(t){return typeof t=="boolean"?t:void 0}function Y(t,e=[]){if(Array.isArray(t))return t;if(!D(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function $n(t){if(!D(t))return null;const e=b(t.kind),n=b(t.summary),s=b(t.target_type);return!e||!n||!s?null:{kind:e,severity:b(t.severity)??"warn",summary:n,target_type:s,target_id:b(t.target_id)??null,actor:b(t.actor)??null,evidence:t.evidence}}function Fe(t){if(!D(t))return null;const e=b(t.action_type),n=b(t.target_type),s=b(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:b(t.target_id)??null,severity:b(t.severity)??"warn",reason:s,confirm_required:on(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function P_(t){if(!D(t))return null;const e=b(t.session_id);return e?{session_id:e,goal:b(t.goal),status:b(t.status),health:b(t.health),scale_profile:b(t.scale_profile),control_profile:b(t.control_profile),planned_worker_count:q(t.planned_worker_count),active_agent_count:q(t.active_agent_count),last_turn_age_sec:q(t.last_turn_age_sec)??null,attention_count:q(t.attention_count),recommended_action_count:q(t.recommended_action_count),top_attention:$n(t.top_attention),top_recommendation:Fe(t.top_recommendation)}:null}function z_(t){if(!D(t))return null;const e=b(t.session_id);if(!e)return null;const n=D(t.status)?t.status:t,s=D(n.summary)?n.summary:void 0;return{session_id:e,status:b(t.status)??b(s==null?void 0:s.status)??(D(n.session)?b(n.session.status):void 0),progress_pct:q(t.progress_pct)??q(s==null?void 0:s.progress_pct),elapsed_sec:q(t.elapsed_sec)??q(s==null?void 0:s.elapsed_sec),remaining_sec:q(t.remaining_sec)??q(s==null?void 0:s.remaining_sec),done_delta_total:q(t.done_delta_total)??q(s==null?void 0:s.done_delta_total),summary:D(t.summary)?t.summary:s,team_health:D(t.team_health)?t.team_health:D(n.team_health)?n.team_health:void 0,communication_metrics:D(t.communication_metrics)?t.communication_metrics:D(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:D(t.orchestration_state)?t.orchestration_state:D(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:D(t.cascade_metrics)?t.cascade_metrics:D(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:D(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,o])=>{const l=b(o);return l?[a,l]:null}).filter(a=>a!==null)):D(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const l=b(o);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:D(t.session)?t.session:D(n.session)?n.session:void 0,recent_events:Y(t.recent_events,["events"]).filter(D)}}function N_(t){if(!D(t))return null;const e=b(t.name);return e?{name:e,agent_name:b(t.agent_name),status:b(t.status),autonomy_level:b(t.autonomy_level),context_ratio:q(t.context_ratio),generation:q(t.generation),active_goal_ids:Y(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:b(t.last_autonomous_action_at)??null,last_turn_ago_s:q(t.last_turn_ago_s),model:b(t.model)}:null}function j_(t){if(!D(t))return null;const e=b(t.confirm_token)??b(t.token);return e?{confirm_token:e,actor:b(t.actor),action_type:b(t.action_type),target_type:b(t.target_type),target_id:b(t.target_id)??null,delegated_tool:b(t.delegated_tool),created_at:b(t.created_at),preview:t.preview}:null}function D_(t){if(!D(t))return null;const e=b(t.action_type),n=b(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:b(t.description),confirm_required:on(t.confirm_required)}}function w_(t){const e=D(t)?t:{};return{room_health:b(e.room_health),cluster:b(e.cluster),project:b(e.project),current_room:b(e.current_room)??b(e.room)??null,paused:on(e.paused),tempo_interval_s:q(e.tempo_interval_s),active_agents:q(e.active_agents),keeper_pressure:q(e.keeper_pressure),active_operations:q(e.active_operations),pending_approvals:q(e.pending_approvals),incident_count:q(e.incident_count),recommended_action_count:q(e.recommended_action_count),top_attention:$n(e.top_attention),top_action:Fe(e.top_action)}}function O_(t){const e=D(t)?t:{},n=D(e.swarm_overview)?e.swarm_overview:{};return{health:b(e.health),active_operations:q(e.active_operations),pending_approvals:q(e.pending_approvals),swarm_overview:{active_lanes:q(n.active_lanes),moving_lanes:q(n.moving_lanes),stalled_lanes:q(n.stalled_lanes),projected_lanes:q(n.projected_lanes),last_movement_at:b(n.last_movement_at)??null},top_attention:$n(e.top_attention),top_action:Fe(e.top_action),session_cards:Y(e.session_cards).map(P_).filter(s=>s!==null)}}function q_(t){const e=D(t)?t:{};return{sessions:Y(e.sessions,["items"]).map(z_).filter(n=>n!==null),keepers:Y(e.keepers,["items"]).map(N_).filter(n=>n!==null),pending_confirms:Y(e.pending_confirms).map(j_).filter(n=>n!==null),available_actions:Y(e.available_actions).map(D_).filter(n=>n!==null)}}function F_(t){if(!D(t))return null;const e=b(t.id),n=b(t.kind),s=b(t.summary),a=b(t.target_type);return!e||!n||!s||!a?null:{id:e,kind:n,severity:b(t.severity)??"warn",summary:s,target_type:a,target_id:b(t.target_id)??null,top_action:Fe(t.top_action),related_session_ids:Y(t.related_session_ids).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),related_agent_names:Y(t.related_agent_names).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),evidence_preview:Y(t.evidence_preview).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),last_seen_at:b(t.last_seen_at)??null}}function Kc(t){if(!D(t))return null;const e=b(t.session_id),n=b(t.goal);return!e||!n?null:{session_id:e,goal:n,room:b(t.room)??null,status:b(t.status),health:b(t.health),member_names:Y(t.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:b(t.started_at)??null,elapsed_sec:q(t.elapsed_sec)??null,operation_id:b(t.operation_id)??null,blocker_summary:b(t.blocker_summary)??null,last_event_at:b(t.last_event_at)??null,last_event_summary:b(t.last_event_summary)??null,communication_summary:b(t.communication_summary)??null,active_count:q(t.active_count),required_count:q(t.required_count),related_attention_count:q(t.related_attention_count)??0,top_attention:$n(t.top_attention),top_recommendation:Fe(t.top_recommendation)}}function Uc(t){if(!D(t))return null;const e=b(t.agent_name);return e?{agent_name:e,display_name:b(t.display_name)??null,is_live:typeof t.is_live=="boolean"?t.is_live:void 0,current_work:b(t.current_work)??null,recent_input_preview:b(t.recent_input_preview)??null,recent_output_preview:b(t.recent_output_preview)??null,recent_tool_names:Y(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_activity_at:b(t.last_activity_at)??null}:null}function Wc(t){if(!D(t))return null;const e=b(t.operation_id);return e?{operation_id:e,status:b(t.status),stage:b(t.stage)??null,detachment_status:b(t.detachment_status)??null,objective:b(t.objective)??null,updated_at:b(t.updated_at)??null}:null}function Hc(t){if(!D(t))return null;const e=b(t.name);return e?{name:e,agent_name:b(t.agent_name)??null,status:b(t.status),generation:q(t.generation),context_ratio:q(t.context_ratio)??null,last_turn_ago_s:q(t.last_turn_ago_s)??null,current_work:b(t.current_work)??null}:null}function Gc(t){const e=Kc(t);return e?{...e,member_previews:Y(D(t)?t.member_previews:void 0).map(Uc).filter(n=>n!==null),operation_badges:Y(D(t)?t.operation_badges:void 0).map(Wc).filter(n=>n!==null),keeper_refs:Y(D(t)?t.keeper_refs:void 0).map(Hc).filter(n=>n!==null)}:null}function B_(t){if(!D(t))return null;const e=b(t.agent_name);return e?{agent_name:e,display_name:b(t.display_name)??null,is_live:typeof t.is_live=="boolean"?t.is_live:void 0,archived_reason:b(t.archived_reason)??null,status:b(t.status),where:b(t.where)??null,with_whom:Y(t.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:b(t.current_work)??null,related_session_id:b(t.related_session_id)??null,related_attention_count:q(t.related_attention_count)??0,last_activity_at:b(t.last_activity_at)??null,recent_output_preview:b(t.recent_output_preview)??null,recent_input_preview:b(t.recent_input_preview)??null,recent_tool_names:Y(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean)}:null}function K_(t){if(!D(t))return null;const e=b(t.name);return e?{name:e,agent_name:b(t.agent_name)??null,status:b(t.status),generation:q(t.generation),context_ratio:q(t.context_ratio)??null,last_turn_ago_s:q(t.last_turn_ago_s)??null,current_work:b(t.current_work)??null,last_autonomous_action_at:b(t.last_autonomous_action_at)??null,allowed_tool_names:Y(t.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:Y(t.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:q(t.latest_tool_call_count)??null,tool_audit_source:b(t.tool_audit_source)??null,tool_audit_at:b(t.tool_audit_at)??null}:null}function U_(t){if(!D(t))return null;const e=b(t.id),n=b(t.signal_type),s=b(t.summary),a=b(t.target_type);return!e||!n||!s||!a?null:{id:e,signal_type:n==="action"?"action":"attention",severity:b(t.severity)??"warn",summary:s,target_type:a,target_id:b(t.target_id)??null,attention:$n(t.attention),action:Fe(t.action)}}function W_(t){const e=D(t)?t:{},n=Y(e.session_briefs).map(Kc).filter(a=>a!==null),s=Y(e.sessions).map(Gc).filter(a=>a!==null);return{generated_at:b(e.generated_at),summary:w_(e.summary),incidents:Y(e.incidents).map($n).filter(a=>a!==null),recommended_actions:Y(e.recommended_actions).map(Fe).filter(a=>a!==null),command_focus:O_(e.command_focus),operator_targets:q_(e.operator_targets),attention_queue:Y(e.attention_queue).map(F_).filter(a=>a!==null),sessions:s.length>0?s:n.map(a=>({...a,member_previews:[],operation_badges:[],keeper_refs:[]})),session_briefs:n,agent_briefs:Y(e.agent_briefs).map(B_).filter(a=>a!==null),keeper_briefs:Y(e.keeper_briefs).map(K_).filter(a=>a!==null),internal_signals:Y(e.internal_signals).map(U_).filter(a=>a!==null)}}function H_(t){if(!D(t))return null;const e=b(t.id),n=b(t.summary);return!e||!n?null:{id:e,timestamp:b(t.timestamp)??null,event_type:b(t.event_type),actor:b(t.actor)??null,summary:n}}function G_(t){const e=D(t)?t:{};return{generated_at:b(e.generated_at),session_id:b(e.session_id)??"",session:Gc(e.session),timeline:Y(e.timeline).map(H_).filter(n=>n!==null),participants:Y(e.participants).map(Uc).filter(n=>n!==null),operations:Y(e.operations).map(Wc).filter(n=>n!==null),keepers:Y(e.keepers).map(Hc).filter(n=>n!==null),error:b(e.error)??null}}function J_(t){if(!D(t))return null;const e=b(t.id),n=b(t.label),s=b(t.summary);if(!e||!n||!s)return null;const a=b(t.status)??"unclear";return{id:e,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:b(t.signal_class)==="metadata_gap"||b(t.signal_class)==="mixed"||b(t.signal_class)==="operational_risk"?b(t.signal_class):void 0,evidence_quality:b(t.evidence_quality)==="strong"||b(t.evidence_quality)==="partial"||b(t.evidence_quality)==="missing"?b(t.evidence_quality):void 0,evidence:Y(t.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function Y_(t){if(!D(t))return null;const e=b(t.kind),n=b(t.summary),s=b(t.scope_type),a=b(t.severity);return!e||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:e,summary:n,scope_type:s,scope_id:b(t.scope_id)??null,severity:a}}function V_(t){const e=D(t)?t:{},n=D(e.basis)?e.basis:{},s=b(e.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:b(e.generated_at),cached:on(e.cached),stale:on(e.stale),refreshing:on(e.refreshing),status:a,summary:b(e.summary)??null,model:b(e.model)??null,ttl_sec:q(e.ttl_sec),criteria:Y(e.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:b(n.current_room)??null,crew_count:q(n.crew_count),agent_count:q(n.agent_count),keeper_count:q(n.keeper_count)},metadata_gap_count:q(e.metadata_gap_count),metadata_gaps:Y(e.metadata_gaps).map(Y_).filter(o=>o!==null),sections:Y(e.sections).map(J_).filter(o=>o!==null),error:b(e.error)??null,last_error:b(e.last_error)??null}}async function Jc(){io.value=!0,va.value=null;try{const t=await ap();Ya.value=W_(t)}catch(t){va.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{io.value=!1}}async function X_(t){if(!t){oo.value=null,Xs.value=null,Vs.value=!1;return}Vs.value=!0,Xs.value=null;try{const e=await ip(t);oo.value=G_(e)}catch(e){Xs.value=e instanceof Error?e.message:"Failed to load session detail"}finally{Vs.value=!1}}async function fa(t=!1){He.value=!0,Ie.value=null;try{const e=await op(t),n=V_(e);Bc.value=n,n.refreshing||n.status==="pending"?L_():il()}catch(e){Ie.value=e instanceof Error?e.message:"Failed to load mission briefing",il()}finally{He.value=!1}}const Yc=g(null),ro=g(!1),Ge=g(null);async function Vc(t,e){ro.value=!0,Ge.value=null;try{Yc.value=await rp(t,e)}catch(n){Ge.value=n instanceof Error?n.message:String(n)}finally{ro.value=!1}}const Ko=g(null),Gt=g(null),ga=g(!1),$a=g(!1),ha=g(null),ya=g(null),lo=g(null),ba=g(null),Z=g("warroom"),_s=g(null),co=g(!1),ka=g(null),Be=g(null),xa=g(!1),Sa=g(null),Uo=g(null),uo=g(!1),Ca=g(null),vs=g(null),po=g(!1),Aa=g(null),Jn=g(null),Ta=g(!1),Yn=g(null),rn=g(null);let Rn=null;function Wo(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"&&t!=="orchestra"}function Xc(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function Qc(){const e=Xc().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Zc(){const e=Xc().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Q_(t){if(_(t))return{policy_class:r(t.policy_class),approval_class:r(t.approval_class),tool_allowlist:B(t.tool_allowlist),model_allowlist:B(t.model_allowlist),requires_human_for:B(t.requires_human_for),autonomy_level:r(t.autonomy_level),escalation_timeout_sec:u(t.escalation_timeout_sec),kill_switch:z(t.kill_switch),frozen:z(t.frozen)}}function Z_(t){if(_(t))return{headcount_cap:u(t.headcount_cap),active_operation_cap:u(t.active_operation_cap),max_cost_usd:u(t.max_cost_usd),max_tokens:u(t.max_tokens)}}function Ho(t){if(!_(t))return null;const e=r(t.unit_id),n=r(t.label),s=r(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:r(t.parent_unit_id)??null,leader_id:r(t.leader_id)??null,roster:B(t.roster),capability_profile:B(t.capability_profile),source:r(t.source),created_at:r(t.created_at),updated_at:r(t.updated_at),policy:Q_(t.policy),budget:Z_(t.budget)}}function td(t){if(!_(t))return null;const e=Ho(t.unit);return e?{unit:e,leader_status:r(t.leader_status),roster_total:u(t.roster_total),roster_live:u(t.roster_live),active_operation_count:u(t.active_operation_count),health:r(t.health),reasons:B(t.reasons),children:Array.isArray(t.children)?t.children.map(td).filter(n=>n!==null):[]}:null}function tv(t){if(_(t))return{total_units:u(t.total_units),company_count:u(t.company_count),platoon_count:u(t.platoon_count),squad_count:u(t.squad_count),leaf_agent_unit_count:u(t.leaf_agent_unit_count),live_agent_count:u(t.live_agent_count),managed_unit_count:u(t.managed_unit_count),active_operation_count:u(t.active_operation_count)}}function ed(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),source:r(e.source),summary:tv(e.summary),units:Array.isArray(e.units)?e.units.map(td).filter(n=>n!==null):[]}}function ev(t){if(!_(t))return null;const e=r(t.kind),n=r(t.status);return!e||!n?null:{kind:e,chain_id:r(t.chain_id)??null,goal:r(t.goal)??null,run_id:r(t.run_id)??null,status:n,viewer_path:r(t.viewer_path)??null,last_sync_at:r(t.last_sync_at)??null}}function Va(t){if(!_(t))return null;const e=r(t.operation_id),n=r(t.objective),s=r(t.assigned_unit_id),a=r(t.trace_id),o=r(t.status);return!e||!n||!s||!a||!o?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:r(t.autonomy_level),policy_class:r(t.policy_class),budget_class:r(t.budget_class),detachment_session_id:r(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(t.checkpoint_ref)??null,active_goal_ids:B(t.active_goal_ids),note:r(t.note)??null,created_by:r(t.created_by),source:r(t.source),status:o,chain:ev(t.chain),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function nv(t){if(!_(t))return null;const e=Va(t.operation);return e?{operation:e,assigned_unit_label:r(t.assigned_unit_label)}:null}function Sn(t){if(_(t))return{tone:r(t.tone),pending_ops:u(t.pending_ops),blocked_ops:u(t.blocked_ops),in_flight_ops:u(t.in_flight_ops),pipeline_stalls:u(t.pipeline_stalls),bus_traffic:u(t.bus_traffic),l1_hit_rate:u(t.l1_hit_rate),invalidation_count:u(t.invalidation_count),current_pending:u(t.current_pending),current_in_flight:u(t.current_in_flight),cdb_wakeups:u(t.cdb_wakeups),total_stolen:u(t.total_stolen),avg_best_score:u(t.avg_best_score),avg_candidate_count:u(t.avg_candidate_count),best_first_operations:u(t.best_first_operations),active_sessions:u(t.active_sessions),commit_rate:u(t.commit_rate),total_speculations:u(t.total_speculations)}}function sv(t){if(!_(t))return;const e=_(t.pipeline)?t.pipeline:void 0,n=_(t.cache)?t.cache:void 0,s=_(t.ooo)?t.ooo:void 0,a=_(t.speculative)?t.speculative:void 0,o=_(t.search_fabric)?t.search_fabric:void 0,l=_(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:u(e.total_ops),completed_ops:u(e.completed_ops),stalled_cycles:u(e.stalled_cycles),hazards_detected:u(e.hazards_detected),forwarding_used:u(e.forwarding_used),pipeline_flushes:u(e.pipeline_flushes),ipc:u(e.ipc)}:void 0,cache:n?{total_reads:u(n.total_reads),total_writes:u(n.total_writes),l1_hit_rate:u(n.l1_hit_rate),invalidation_count:u(n.invalidation_count),writeback_count:u(n.writeback_count),bus_traffic:u(n.bus_traffic)}:void 0,ooo:s?{agent_count:u(s.agent_count),total_added:u(s.total_added),total_issued:u(s.total_issued),total_completed:u(s.total_completed),total_stolen:u(s.total_stolen),cdb_wakeups:u(s.cdb_wakeups),stall_cycles:u(s.stall_cycles),global_cdb_events:u(s.global_cdb_events),current_pending:u(s.current_pending),current_in_flight:u(s.current_in_flight)}:void 0,speculative:a?{total_speculations:u(a.total_speculations),total_commits:u(a.total_commits),total_aborts:u(a.total_aborts),commit_rate:u(a.commit_rate),total_fast_calls:u(a.total_fast_calls),total_cost_usd:u(a.total_cost_usd),active_sessions:u(a.active_sessions)}:void 0,search_fabric:o?{total_operations:u(o.total_operations),best_first_operations:u(o.best_first_operations),legacy_operations:u(o.legacy_operations),blocked_operations:u(o.blocked_operations),ready_operations:u(o.ready_operations),research_pipeline_operations:u(o.research_pipeline_operations),avg_candidate_count:u(o.avg_candidate_count),avg_best_score:u(o.avg_best_score),top_stage:r(o.top_stage)??null}:void 0,signals:l?{issue_pressure:Sn(l.issue_pressure),cache_contention:Sn(l.cache_contention),scheduler_efficiency:Sn(l.scheduler_efficiency),routing_confidence:Sn(l.routing_confidence),speculative_posture:Sn(l.speculative_posture)}:void 0}}function nd(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),active:u(n.active),paused:u(n.paused),managed:u(n.managed),projected:u(n.projected)}:void 0,microarch:sv(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(nv).filter(s=>s!==null):[]}}function sd(t){if(!_(t))return null;const e=r(t.detachment_id),n=r(t.operation_id),s=r(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:r(t.leader_id)??null,roster:B(t.roster),session_id:r(t.session_id)??null,checkpoint_ref:r(t.checkpoint_ref)??null,runtime_kind:r(t.runtime_kind)??null,runtime_ref:r(t.runtime_ref)??null,source:r(t.source),status:r(t.status),last_event_at:r(t.last_event_at)??null,last_progress_at:r(t.last_progress_at)??null,heartbeat_deadline:r(t.heartbeat_deadline)??null,created_at:r(t.created_at),updated_at:r(t.updated_at)}}function av(t){if(!_(t))return null;const e=sd(t.detachment);return e?{detachment:e,assigned_unit_label:r(t.assigned_unit_label),operation:Va(t.operation)}:null}function ad(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),active:u(n.active),projected:u(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(av).filter(s=>s!==null):[]}}function iv(t){if(!_(t))return null;const e=r(t.decision_id),n=r(t.trace_id),s=r(t.requested_action),a=r(t.scope_type),o=r(t.scope_id);return!e||!n||!s||!a||!o?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:r(t.operation_id)??null,target_unit_id:r(t.target_unit_id)??null,requested_by:r(t.requested_by),status:r(t.status),reason:r(t.reason)??null,source:r(t.source),detail:t.detail,created_at:r(t.created_at),decided_at:r(t.decided_at)??null,expires_at:r(t.expires_at)??null}}function id(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),pending:u(n.pending),approved:u(n.approved),denied:u(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(iv).filter(s=>s!==null):[]}}function ov(t){if(!_(t))return null;const e=Ho(t.unit);return e?{unit:e,roster_total:u(t.roster_total),roster_live:u(t.roster_live),headcount_cap:u(t.headcount_cap),active_operations:u(t.active_operations),active_operation_cap:u(t.active_operation_cap),utilization:u(t.utilization)}:null}function rv(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(ov).filter(n=>n!==null):[]}}function lv(t){if(!_(t))return null;const e=r(t.alert_id);return e?{alert_id:e,severity:r(t.severity),kind:r(t.kind),scope_type:r(t.scope_type),scope_id:r(t.scope_id),title:r(t.title),detail:r(t.detail),timestamp:r(t.timestamp)}:null}function od(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),bad:u(n.bad),warn:u(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(lv).filter(s=>s!==null):[]}}function rd(t){if(!_(t))return null;const e=r(t.event_id),n=r(t.trace_id),s=r(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:r(t.operation_id)??null,unit_id:r(t.unit_id)??null,actor:r(t.actor)??null,source:r(t.source),timestamp:r(t.timestamp),detail:t.detail}}function cv(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),events:Array.isArray(e.events)?e.events.map(rd).filter(n=>n!==null):[]}}function dv(t){if(!_(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function uv(t){if(!_(t))return null;const e=r(t.lane_id),n=r(t.label),s=r(t.kind),a=r(t.phase),o=r(t.motion_state),l=r(t.source_of_truth),c=r(t.movement_reason),d=r(t.current_step);if(!e||!n||!s||!a||!o||!l||!c||!d)return null;const m=_(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:z(t.present)??!1,phase:a,motion_state:o,source_of_truth:l,last_movement_at:r(t.last_movement_at)??null,movement_reason:c,current_step:d,blockers:B(t.blockers),counts:{operations:u(m.operations),detachments:u(m.detachments),workers:u(m.workers),approvals:u(m.approvals),alerts:u(m.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(dv).filter(p=>p!==null):[]}}function pv(t){if(!_(t))return null;const e=r(t.event_id),n=r(t.lane_id),s=r(t.kind),a=r(t.timestamp),o=r(t.title),l=r(t.detail),c=r(t.tone),d=r(t.source);return!e||!n||!s||!a||!o||!l||!c||!d?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:o,detail:l,tone:c,source:d}}function mv(t){if(!_(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,why_it_matters:r(t.why_it_matters)??void 0,next_tool:r(t.next_tool)??void 0,next_step:r(t.next_step)??void 0,lane_ids:B(t.lane_ids),count:u(t.count)??0}}function Go(t){if(!_(t))return;const e=_(t.overview)?t.overview:{},n=_(t.gaps)?t.gaps:{},s=_(t.narrative)?t.narrative:{},a=_(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:r(t.generated_at),narrative:{state:r(s.state)??void 0,started:r(s.started)??void 0,active_work:r(s.active_work)??void 0,completion:r(s.completion)??void 0,lane_id:r(s.lane_id)??null},overview:{active_lanes:u(e.active_lanes),moving_lanes:u(e.moving_lanes),stalled_lanes:u(e.stalled_lanes),projected_lanes:u(e.projected_lanes),last_movement_at:r(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(uv).filter(o=>o!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(pv).filter(o=>o!==null):[],gaps:{count:u(n.count),items:Array.isArray(n.items)?n.items.map(mv).filter(o=>o!==null):[]},recommended_next_action:a?{tool:r(a.tool)??"masc_operator_snapshot",label:r(a.label)??"Observe operator state",reason:r(a.reason)??"",lane_id:r(a.lane_id)??null}:void 0}}function ld(t){if(!_(t))return;const e=_(t.workers)?t.workers:{},n=z(t.pass);return{status:r(t.status)??"missing",source:r(t.source)??"none",reason_code:r(t.reason_code)??null,status_summary:r(t.status_summary)??null,run_id:r(t.run_id)??null,captured_at:r(t.captured_at)??null,...n!==void 0?{pass:n}:{},...u(t.peak_hot_slots)!=null?{peak_hot_slots:u(t.peak_hot_slots)}:{},...u(t.ctx_per_slot)!=null?{ctx_per_slot:u(t.ctx_per_slot)}:{},workers:{expected:u(e.expected),joined:u(e.joined),current_task_bound:u(e.current_task_bound),fresh_heartbeats:u(e.fresh_heartbeats),done:u(e.done),final:u(e.final)},expected_artifact_dir:r(t.expected_artifact_dir)??null,artifact_ref:r(t.artifact_ref)??null,missing_reason:r(t.missing_reason)??null}}function _v(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),topology:ed(e.topology),operations:nd(e.operations),detachments:ad(e.detachments),alerts:od(e.alerts),decisions:id(e.decisions),capacity:rv(e.capacity),traces:cv(e.traces),swarm_status:Go(e.swarm_status)}}function vv(t){const e=_(t)?t:{},n=ed(e.topology),s=nd(e.operations),a=ad(e.detachments),o=od(e.alerts),l=id(e.decisions);return{version:r(e.version),generated_at:r(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:Go(e.swarm_status),swarm_proof:ld(e.swarm_proof)}}function fv(t){return _(t)?{chain_id:r(t.chain_id)??null,started_at:u(t.started_at)??null,progress:u(t.progress)??null,elapsed_sec:u(t.elapsed_sec)??null}:null}function cd(t){if(!_(t))return null;const e=r(t.event);return e?{event:e,chain_id:r(t.chain_id)??null,timestamp:r(t.timestamp)??null,duration_ms:u(t.duration_ms)??null,message:r(t.message)??null,tokens:u(t.tokens)??null}:null}function gv(t){if(!_(t))return null;const e=Va(t.operation);return e?{operation:e,runtime:fv(t.runtime),history:cd(t.history),mermaid:r(t.mermaid)??null,preview_run:dd(t.preview_run)}:null}function $v(t){const e=_(t)?t:{};return{status:r(e.status)??"disconnected",base_url:r(e.base_url)??null,message:r(e.message)??null}}function hv(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),connection:$v(e.connection),summary:n?{linked_operations:u(n.linked_operations),active_chains:u(n.active_chains),running_operations:u(n.running_operations),recent_failures:u(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(gv).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(cd).filter(s=>s!==null):[]}}function yv(t){if(!_(t))return null;const e=r(t.id);return e?{id:e,type:r(t.type),status:r(t.status),duration_ms:u(t.duration_ms)??null,error:r(t.error)??null}:null}function dd(t){if(!_(t))return null;const e=r(t.run_id),n=r(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:u(t.duration_ms),success:z(t.success),mermaid:r(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(yv).filter(s=>s!==null):[]}:null}function bv(t){const e=_(t)?t:{};return{run:dd(e.run)}}function kv(t){if(!_(t))return null;const e=r(t.title),n=r(t.path);return!e||!n?null:{title:e,path:n}}function xv(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function Sv(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.tool),a=r(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:B(t.success_signals),pitfalls:B(t.pitfalls)}}function Cv(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary),a=r(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(Sv).filter(o=>o!==null):[]}}function Av(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:B(t.tools)}}function Tv(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.symptom),a=r(t.why),o=r(t.fix_tool),l=r(t.fix_summary);return!e||!n||!s||!a||!o||!l?null:{id:e,title:n,symptom:s,why:a,fix_tool:o,fix_summary:l}}function Iv(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.path_id),a=r(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:B(t.notes)}}function Rv(t){const e=_(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(kv).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(xv).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Cv).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Av).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Tv).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Iv).filter(n=>n!==null):[]}}function Mv(t){if(!_(t))return null;const e=r(t.id),n=r(t.title),s=r(t.status),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{id:e,title:n,status:s,detail:a,next_tool:o}}function Ev(t){if(!_(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.title),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{code:e,severity:n,title:s,detail:a,next_tool:o}}function Lv(t){if(!_(t))return null;const e=r(t.from),n=r(t.content),s=r(t.timestamp),a=u(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function Pv(t){if(!_(t))return null;const e=r(t.name),n=r(t.role),s=r(t.lane),a=r(t.status),o=r(t.claim_marker),l=r(t.done_marker),c=r(t.final_marker);if(!e||!n||!s||!a||!o||!l||!c)return null;const d=(()=>{if(!_(t.last_message))return null;const m=u(t.last_message.seq),p=r(t.last_message.content),v=r(t.last_message.timestamp);return m==null||!p||!v?null:{seq:m,content:p,timestamp:v}})();return{name:e,role:n,lane:s,joined:z(t.joined)??!1,live_presence:z(t.live_presence)??!1,completed:z(t.completed)??!1,status:a,current_task:r(t.current_task)??null,bound_task_id:r(t.bound_task_id)??null,bound_task_title:r(t.bound_task_title)??null,bound_task_status:r(t.bound_task_status)??null,current_task_matches_run:z(t.current_task_matches_run)??!1,squad_member:z(t.squad_member)??!1,detachment_member:z(t.detachment_member)??!1,last_seen:r(t.last_seen)??null,heartbeat_age_sec:u(t.heartbeat_age_sec)??null,heartbeat_fresh:z(t.heartbeat_fresh)??!1,claim_marker_seen:z(t.claim_marker_seen)??!1,done_marker_seen:z(t.done_marker_seen)??!1,final_marker_seen:z(t.final_marker_seen)??!1,claim_marker:o,done_marker:l,final_marker:c,last_message:d}}function zv(t){if(!_(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!_(n))return null;const s=r(n.timestamp),a=u(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:r(t.slot_url)??null,provider_base_url:r(t.provider_base_url)??null,provider_reachable:z(t.provider_reachable)??null,provider_status_code:u(t.provider_status_code)??null,provider_model_id:r(t.provider_model_id)??null,actual_model_id:r(t.actual_model_id)??null,expected_slots:u(t.expected_slots),actual_slots:u(t.actual_slots),expected_ctx:u(t.expected_ctx),actual_ctx:u(t.actual_ctx),configured_capacity:u(t.configured_capacity),slot_reachable:z(t.slot_reachable)??null,slot_status_code:u(t.slot_status_code)??null,runtime_blocker:r(t.runtime_blocker)??null,detail:r(t.detail)??null,checked_at:r(t.checked_at)??null,total_slots:u(t.total_slots),ctx_per_slot:u(t.ctx_per_slot),active_slots_now:u(t.active_slots_now),peak_active_slots:u(t.peak_active_slots),sample_count:u(t.sample_count),last_sample_at:r(t.last_sample_at)??null,timeline:e}}function Nv(t){if(!_(t))return null;const e=r(t.run_id),n=r(t.status),s=r(t.decided_by),a=r(t.decided_at),o=r(t.reason);if(!e||!n||!s||!a||!o)return null;const l=[];return Array.isArray(t.history)&&t.history.forEach(c=>{if(!_(c))return;const d=r(c.status),m=r(c.decided_by),p=r(c.decided_at),v=r(c.reason);!d||!m||!p||!v||l.push({status:d,decided_by:m,decided_at:p,reason:v,operation_id:r(c.operation_id)??null,detachment_id:r(c.detachment_id)??null,note:r(c.note)??null})}),{run_id:e,status:n,decided_by:s,decided_at:a,reason:o,operation_id:r(t.operation_id)??null,detachment_id:r(t.detachment_id)??null,note:r(t.note)??null,history:l}}function jv(t){if(!_(t))return null;const e=r(t.run_id),n=r(t.recommended_kind),s=r(t.reason);return!e||!n||!s?null:{run_id:e,recommended_kind:n,continue_available:z(t.continue_available)??!1,rerun_available:z(t.rerun_available)??!1,abandon_available:z(t.abandon_available)??!1,reason:s,evidence:_(t.evidence)?{operation_id:r(t.evidence.operation_id)??null,detachment_id:r(t.evidence.detachment_id)??null,joined_workers:u(t.evidence.joined_workers),current_task_bound:u(t.evidence.current_task_bound),fresh_heartbeats:u(t.evidence.fresh_heartbeats),trace_events:u(t.evidence.trace_events),message_events:u(t.evidence.message_events),runtime_blocker:r(t.evidence.runtime_blocker)??null}:void 0,provenance:r(t.provenance),decision_engine:r(t.decision_engine),authoritative:z(t.authoritative)}}function Dv(t){const e=_(t)?t:{},n=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),run_id:r(e.run_id),room_id:r(e.room_id),operation_id:r(e.operation_id)??null,run_resolution:Nv(e.run_resolution),resolution_recommendation:jv(e.resolution_recommendation),recommended_next_tool:r(e.recommended_next_tool),summary:n?{expected_workers:u(n.expected_workers),joined_workers:u(n.joined_workers),live_workers:u(n.live_workers),squad_roster_size:u(n.squad_roster_size),detachment_roster_size:u(n.detachment_roster_size),current_task_bound:u(n.current_task_bound),fresh_heartbeats:u(n.fresh_heartbeats),claim_markers_seen:u(n.claim_markers_seen),done_markers_seen:u(n.done_markers_seen),final_markers_seen:u(n.final_markers_seen),completed_workers:u(n.completed_workers),peak_hot_slots:u(n.peak_hot_slots),hot_window_ok:z(n.hot_window_ok),pass_hot_concurrency:z(n.pass_hot_concurrency),pass_end_to_end:z(n.pass_end_to_end),pending_decisions:u(n.pending_decisions),pass:z(n.pass)}:void 0,provider:zv(e.provider),operation:Va(e.operation),squad:Ho(e.squad),detachment:sd(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Pv).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Mv).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Ev).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Lv).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(rd).filter(s=>s!==null):[],truth_notes:B(e.truth_notes)}}function wv(t){if(!_(t))return null;const e=r(t.label),n=r(t.value);return!e||!n?null:{label:e,value:n}}function Ov(t){if(!_(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.label),a=r(t.tone),o=r(t.provenance);return!e||!n||!s||!a||!o?null:{id:e,kind:n,label:s,subtitle:r(t.subtitle)??null,status:r(t.status)??null,tone:a,pulse:r(t.pulse)??null,provenance:o,visual_class:r(t.visual_class)??void 0,glyph:r(t.glyph)??void 0,parent_id:r(t.parent_id)??null,lane_id:r(t.lane_id)??null,link_tab:r(t.link_tab)??null,link_surface:r(t.link_surface)??null,link_params:_(t.link_params)?Object.fromEntries(Object.entries(t.link_params).map(([l,c])=>{const d=r(c);return d?[l,d]:null}).filter(l=>l!==null)):{},facts:Array.isArray(t.facts)?t.facts.map(wv).filter(l=>l!==null):[]}}function qv(t){if(!_(t))return null;const e=r(t.id),n=r(t.source),s=r(t.target),a=r(t.kind),o=r(t.tone),l=r(t.provenance);return!e||!n||!s||!a||!o||!l?null:{id:e,source:n,target:s,kind:a,label:r(t.label)??null,tone:o,provenance:l,animated:z(t.animated)}}function Fv(t){if(!_(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.label),a=r(t.tone),o=r(t.provenance);return!e||!n||!s||!a||!o?null:{id:e,kind:n,label:s,detail:r(t.detail)??null,tone:a,provenance:o,source_id:r(t.source_id)??null,target_id:r(t.target_id)??null,suggested_surface:r(t.suggested_surface)??null,suggested_params:_(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([l,c])=>{const d=r(c);return d?[l,d]:null}).filter(l=>l!==null)):{}}}function Bv(t){if(!_(t))return null;const e=r(t.target_kind),n=r(t.target_id),s=r(t.label),a=r(t.reason);return!e||!n||!s||!a?null:{target_kind:e,target_id:n,label:s,reason:a,suggested_surface:r(t.suggested_surface)??null,suggested_params:_(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([o,l])=>{const c=r(l);return c?[o,c]:null}).filter(o=>o!==null)):{}}}function Kv(t){const e=_(t)?t:{},n=_(e.room)?e.room:{},s=_(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),room:{room_id:r(n.room_id),project:r(n.project),cluster:r(n.cluster),paused:z(n.paused),pause_reason:r(n.pause_reason)??null,agent_count:u(n.agent_count),task_count:u(n.task_count),message_count:u(n.message_count)},summary:s?{session_count:u(s.session_count),operation_count:u(s.operation_count),detachment_count:u(s.detachment_count),lane_count:u(s.lane_count),worker_count:u(s.worker_count),keeper_count:u(s.keeper_count),signal_count:u(s.signal_count),alert_count:u(s.alert_count)}:void 0,nodes:Array.isArray(e.nodes)?e.nodes.map(Ov).filter(a=>a!==null):[],edges:Array.isArray(e.edges)?e.edges.map(qv).filter(a=>a!==null):[],signals:Array.isArray(e.signals)?e.signals.map(Fv).filter(a=>a!==null):[],focus:Bv(e.focus),swarm_status:Go(e.swarm_status),swarm_proof:ld(e.swarm_proof),truth_notes:B(e.truth_notes)}}function qt(t){Z.value=t,Wo(t)&&Uv()}async function ud(){ga.value=!0,ha.value=null;try{const t=await mp();Ko.value=vv(t)}catch(t){ha.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{ga.value=!1}}function Jo(t){rn.value=t}async function Yo(){$a.value=!0,ya.value=null;try{const t=await pp();Gt.value=_v(t)}catch(t){ya.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{$a.value=!1}}async function Uv(){Gt.value||$a.value||await Yo()}async function Je(){await ud(),Wo(Z.value)&&await Yo()}async function je(){var t;po.value=!0,Aa.value=null;try{const e=await _p(),n=hv(e);vs.value=n;const s=rn.value;n.operations.length===0?rn.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(rn.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Aa.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{po.value=!1}}function Wv(){Rn=null,Jn.value=null,Ta.value=!1,Yn.value=null}async function Hv(t){Rn=t,Ta.value=!0,Yn.value=null;try{const e=await vp(t);if(Rn!==t)return;Jn.value=bv(e)}catch(e){if(Rn!==t)return;Jn.value=null,Yn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{Rn===t&&(Ta.value=!1)}}async function Gv(){co.value=!0,ka.value=null;try{const t=await fp();_s.value=Rv(t)}catch(t){ka.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{co.value=!1}}async function Qt(t=Qc(),e=Zc()){xa.value=!0,Sa.value=null;try{const n=await gp(t,e);Be.value=Dv(n)}catch(n){Sa.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{xa.value=!1}}async function Pe(t=Qc(),e=Zc()){uo.value=!0,Ca.value=null;try{const n=await $p(t,e);Uo.value=Kv(n)}catch(n){Ca.value=n instanceof Error?n.message:"Failed to load orchestra map"}finally{uo.value=!1}}async function he(t,e,n){lo.value=t,ba.value=null;try{await hp(e,n),await ud(),(Gt.value||Wo(Z.value))&&await Yo(),await Qt(),await Pe(),await je()}catch(s){throw ba.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{lo.value=null}}function Jv(t){return he(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Yv(t){return he(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function Vv(t){return he(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Xv(t={}){return he("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Qv(t){return he(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Zv(t){return he(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function tf(t,e){return he(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function ef(t,e){return he(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}g_(()=>{Je(),je(),(Z.value==="swarm"||Z.value==="warroom"||Z.value==="orchestra"||Be.value!==null)&&Qt(),(Z.value==="orchestra"||Uo.value!==null)&&Pe(),Z.value==="warroom"&&gt()});function mo(t){t==="command"&&(Ee(),Je(),je(),(Z.value==="swarm"||Z.value==="warroom"||Z.value==="orchestra")&&Qt(),Z.value==="orchestra"&&Pe(),Z.value==="warroom"&&gt()),t==="mission"&&(Ee(),Jc(),fa()),t==="proof"&&Vc(w.value.params.session_id,w.value.params.operation_id),t==="execution"&&(Ee(),Me()),t==="intervene"&&(Ee(),gt(),we()),t==="memory"&&ue(),t==="planning"&&qo(),t==="lab"&&pe()}function nf({metric:t}){return i`
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
  `}function sf({panel:t}){return i`
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
            ${t.metrics.map(e=>i`<${nf} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function O({panelId:t,compact:e=!1,label:n="왜 필요한가"}){const s=a_(t);return s?i`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${sf} panel=${s} />
    </details>
  `:da.value?i`<span class="semantic-inline-state">의미 계층 불러오는 중…</span>`:null}function xt({surfaceId:t,compact:e=!1}){const n=s_(t);return n?i`
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
              ${n?i`<${O} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}function _i(t){const e=(t??"").trim().toLowerCase();return e==="bad"||e==="critical"||e==="offline"?"bad":e==="warn"||e==="paused"||e==="blocked"?"warn":"ok"}function af(){var n;const t=(n=Fo.value)==null?void 0:n.focus;if(!(t!=null&&t.suggested_tab))return;const e=t.suggested_params??{};if(t.suggested_tab==="intervene"){it("intervene",e);return}it("command",{...t.suggested_surface?{surface:t.suggested_surface}:{},...e})}function Xa(){var d,m,p,v,f,$;const t=Fo.value;if(!t)return ao.value?i`<section class="room-truth-strip room-truth-strip-loading">room truth 불러오는 중...</section>`:pa.value?i`<section class="room-truth-strip room-truth-strip-error">${pa.value}</section>`:null;const e=t.room.status,n=t.room.counts,s=(d=t.execution)==null?void 0:d.summary,a=(m=t.execution)==null?void 0:m.top_queue,o=t.command,l=t.operator,c=t.focus;return i`
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
          <span class="command-chip ${_i(((s==null?void 0:s.blocked_sessions)??0)>0?"warn":"ok")}">priority ${(s==null?void 0:s.priority_items)??0}</span>
          <span class="command-chip">${((p=t.execution)==null?void 0:p.provenance)??"derived"}</span>
        </div>
      </article>

      <article class="room-truth-card">
        <span class="room-truth-label">control</span>
        <strong>작전 ${(o==null?void 0:o.active_operations)??0} · 승인 ${(o==null?void 0:o.pending_approvals)??0}</strong>
        <p>alerts bad ${(o==null?void 0:o.bad_alerts)??0} / warn ${(o==null?void 0:o.warn_alerts)??0} · lanes ${(o==null?void 0:o.moving_lanes)??0}/${(o==null?void 0:o.active_lanes)??0}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${_i(((o==null?void 0:o.bad_alerts)??0)>0?"bad":((o==null?void 0:o.warn_alerts)??0)>0||((o==null?void 0:o.pending_approvals)??0)>0?"warn":"ok")}">
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
          <span class="command-chip ${_i((c==null?void 0:c.provenance)==="fallback"?"warn":"ok")}">${(c==null?void 0:c.source)??"steady"}</span>
          <span class="command-chip">${(c==null?void 0:c.provenance)??(($=l==null?void 0:l.recommendation_summary)==null?void 0:$.provenance)??"derived"}</span>
        </div>
        ${c!=null&&c.suggested_tab?i`
              <div class="room-truth-actions">
                <button class="control-btn ghost" onClick=${af}>
                  ${c.suggested_tab==="intervene"?"개입면 열기":"지휘면 열기"}
                </button>
              </div>
            `:null}
      </article>
    </section>
  `}const Ia="masc_dashboard_workflow_context",of=900*1e3;function yt(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function ae(t){const e=yt(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function pd(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function _o(t){return _(t)?t:null}function rf(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function lf(t){if(!t)return null;try{const e=JSON.parse(t);if(!_(e))return null;const n=yt(e.id),s=yt(e.source_surface),a=yt(e.source_label),o=yt(e.summary),l=yt(e.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!o||!l?null:{id:n,source_surface:s,source_label:a,action_type:yt(e.action_type),target_type:yt(e.target_type),target_id:yt(e.target_id),focus_kind:yt(e.focus_kind),operation_id:yt(e.operation_id),command_surface:yt(e.command_surface),summary:o,payload_preview:yt(e.payload_preview),suggested_payload:_o(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:l}}catch{return null}}function Vo(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=of}function cf(){const t=pd(),e=lf((t==null?void 0:t.getItem(Ia))??null);return e?Vo(e)?e:(t==null||t.removeItem(Ia),null):null}const md=g(cf());function _d(t){const e=t&&Vo(t)?t:null;md.value=e;const n=pd();if(!n)return;if(!e){n.removeItem(Ia);return}const s=rf(e);s&&n.setItem(Ia,s)}function df(t){if(!t)return null;const e=_o(t.suggested_payload);if(e)return e;if(_(t.preview)){const n=_o(t.preview.payload);if(n)return n}return null}function uf(t){if(!t)return null;const e=ae(t.message);if(e)return e;const n=ae(t.task_title)??ae(t.title),s=ae(t.task_description)??ae(t.description),a=ae(t.reason),o=ae(t.priority)??ae(t.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function Xo(t,e,n,s,a,o,l,c){return[t,e,n??"action",s??"target",a??"room",o??"focus",l??"operation",c].join(":")}function hn(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=df(t),o=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,l=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,c=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,d=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:Xo("mission",n,(t==null?void 0:t.action_type)??null,o,l,c,null,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:o,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:d,payload_preview:uf(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function pf({targetType:t,targetId:e,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:o=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:Xo("execution",s,null,t,e,n,o,c),source_surface:"execution",source_label:s,action_type:null,target_type:t,target_id:e,focus_kind:n,operation_id:o,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function mf(t,e){return(e.source==="mission"||e.source==="execution")&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)&&(e.operation_id??null)===(t.operation_id??null)}function fs(t){const{params:e}=t;if(e.source!=="mission"&&e.source!=="execution")return null;const n=md.value;if(n&&Vo(n)&&mf(n,e))return n;const s=new Date().toISOString(),a=e.source==="execution"?"execution":"mission";return{id:Xo(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,e.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,operation_id:e.operation_id??null,command_surface:e.surface??null,summary:a==="execution"?e.focus_kind?`${e.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function vd(t){return{source:t.source_surface,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function fd(t){if(t.command_surface)return t.command_surface;const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.focus_kind==="operation"||t.target_type==="operation"?"operations":t.target_type==="room"?"orchestra":"swarm"}function gd(t){return{source:t.source_surface,surface:fd(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function _f(t){return vd(t)}function vf(t){return gd(t)}function Qo(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function Qa(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(t==null?void 0:t.trim())||"추천 액션"}}function ff(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"orchestra":return"오케스트라";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}const Zt=g(null),re=g(null);function Pt(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function Rt(t){return t==="bad"||t==="offline"||t==="critical"||t==="risk"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"||t==="watch"?"warn":"ok"}function ee(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function gf(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"확인 필요":t<60?`${Math.round(t)}초`:t<3600?`${Math.round(t/60)}분`:t<86400?`${Math.round(t/3600)}시간`:`${Math.round(t/86400)}일`}function Kt(t){switch((t??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"pending":return"대기 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":case"watch":return"주의";case"bad":case"critical":case"risk":return"위험";case"degraded":return"저하";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"loading":return"불러오는 중";case"error":return"오류";case"unavailable":return"사용 불가";case"stale":return"오래됨";case"refreshing":return"갱신 중";case"cached":return"캐시";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Ra(t){switch((t??"").trim().toLowerCase()){case"room":return"방";case"team_session":case"session":return"세션";case"operation":return"작전";case"keeper":return"키퍼";case"agent":return"에이전트";default:return(t==null?void 0:t.trim())||"대상"}}function ol(t){switch((t??"").trim().toLowerCase()){case"metadata_gap":return"메타데이터 부족";case"mixed":return"신호 혼재";case"":return null;default:return(t==null?void 0:t.trim())||null}}function $f(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function hf(t){return Qo(t?hn(t,null,"상황판 추천 액션"):null)}function Za(t,e=hn()){_d(e),it(t,t==="intervene"?_f(e):vf(e))}function $d(t){Za("intervene",hn(null,t,"상황판 incident"))}function hd(t){Za("command",hn(null,t,"상황판 incident"))}function Zo(t,e,n="상황판 추천 액션"){Za("intervene",hn(t,e,n))}function yd(t,e,n="상황판 추천 액션"){Za("command",hn(t,e,n))}function vo(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),it(t,n)}function yf(t){return{kind:t.kind,severity:t.severity,summary:t.summary,target_type:t.target_type,target_id:t.target_id??null,actor:null,evidence:t.evidence_preview}}function bf(t){var n,s;const e=se.value.find(a=>a.name===t.name||a.agent_name===t.agent_name)??null;return{brief:t,keeper:e,currentWork:Pt(t.current_work,110)??Pt(e==null?void 0:e.skill_primary,110)??Pt(e==null?void 0:e.last_proactive_reason,110)??"명시된 키퍼 초점 없음",recentInput:Pt(e==null?void 0:e.recent_input_preview,120)??null,recentOutput:Pt(e==null?void 0:e.recent_output_preview,120)??Pt((n=e==null?void 0:e.diagnostic)==null?void 0:n.last_reply_preview,120)??Pt(e==null?void 0:e.last_proactive_preview,120)??null,recentEvent:Pt(e==null?void 0:e.last_proactive_reason,120)??Pt((s=e==null?void 0:e.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(e==null?void 0:e.recent_tool_names)??[]}}function kf(){const t=Ya.value;if(!t)return new Map;const e=t.sessions.length>0?t.sessions:t.session_briefs;return new Map(e.map(n=>[n.session_id,n]))}function xf(t){Zt.value=Zt.value===t?null:t,re.value=null}function bd(t){re.value=re.value===t?null:t,Zt.value=null}function Sf(){Zt.value=null,re.value=null}function Cf({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,o=2*Math.PI*s,l=o*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),i`
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
  `}function Af(t){switch(t.trim().toLowerCase()){case"active":case"running":return"가동 중";case"working":return"작업 중";case"watching":return"관찰 중";case"quiet":return"조용함";case"idle":return"유휴";case"ok":case"healthy":return"정상";case"warn":case"warning":case"degraded":return"주의";case"bad":case"critical":case"error":case"failed":return"위험";case"blocked":return"막힘";case"paused":return"일시정지";case"pending":return"대기";case"offline":case"inactive":return"오프라인";case"connected":return"연결됨";case"disconnected":return"끊김";case"ready":return"준비됨";case"done":case"completed":return"완료";case"unknown":return"알 수 없음";default:return t}}function ye({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??Af(t)}
    </span>
  `}function kd(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}초 전`;const a=Math.floor(s/60);if(a<60)return`${a}분 전`;const o=Math.floor(a/60);return o<24?`${o}시간 전`:`${Math.floor(o/24)}일 전`}function et({timestamp:t}){const e=kd(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}function Tf(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function rl(t,e="없음"){return!t||t.length===0?e:t.slice(0,4).join(", ")}function xd({model:t,onClick:e,variant:n,testId:s}){var c,d,m,p;const a=!!t.recentEvent||!!t.recentInput||!!t.recentOutput||!!t.routeSummary||!!t.auditSource||!!t.auditAt||(((c=t.recentTools)==null?void 0:c.length)??0)>0||(((d=t.allowedTools)==null?void 0:d.length)??0)>0,o=n==="mission"?`mission-activity-card ${t.tone}`:"keeper-canonical-card",l=n==="mission"?"mission-card-select":`monitor-row ${t.tone}${t.stateClass?` state-${t.stateClass}`:""}`;return i`
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
                <${Cf} ratio=${t.contextRatio??0} size=${34} stroke=${4} />
                <${ye} status=${t.statusRaw??"unknown"} />
                ${t.stateLabel?i`<span class="monitor-pill ${t.tone}">${t.stateLabel}</span>`:null}
              `:i`<span class="command-chip ${t.tone}">${t.statusLabel}</span>`}
        </div>

        <div class=${n==="mission"?"mission-activity-meta":"monitor-meta"}>
          ${t.lastActivityAt?i`<span>최근 활동 <${et} timestamp=${t.lastActivityAt} /></span>`:i`<span>${t.lastActivityFallback??"최근 활동 없음"}</span>`}
          ${t.relatedSessionId?i`<span>세션 · ${t.relatedSessionId}</span>`:null}
          ${t.continuity?i`<span>${t.continuity}</span>`:null}
          ${t.lifecycle?i`<span>생애주기 ${t.lifecycle}</span>`:null}
          <span>컨텍스트 ${Tf(t.contextRatio)}</span>
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
                ${t.auditAt?i`<span><${et} timestamp=${t.auditAt} /></span>`:null}
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
                      <span>최근 도구 · ${rl(t.recentTools)}</span>
                      <span>허용 도구 · ${rl(t.allowedTools)}</span>
                    </div>
                  `:null}
            </details>
          `:null}
    </article>
  `}function Sd(t,e){const n=t==null?void 0:t.trim(),s=e==null?void 0:e.trim();return s?n&&s===n?null:s:null}function Cd(t,e){const n=Sd(t,e);return n?`runtime · ${n}`:null}function Ad(t,e){const n=t==null?void 0:t.trim(),s=Sd(n,e);return n?s?`keeper key · ${n} · runtime agent · ${s}`:`keeper key · ${n}`:null}function vi(t){return(t==null?void 0:t.trim().toLowerCase())??""}function If(t){var e,n;return t?((e=t.agent)==null?void 0:e.exists)===!1||vi((n=t.diagnostic)==null?void 0:n.health_state)==="offline"||vi(t.status)==="offline"||vi(t.status)==="inactive"?"offline":"online":"unlinked"}function Rf(t){switch(t){case"offline":return"offline";case"none_recent":return"none_recent";case"not_applicable":return"not_applicable";case"unlinked":return"unlinked";default:return"not_collected"}}function Mf(t){const e=If(t);return e==="unlinked"?"unlinked":e==="offline"?"offline":"none_recent"}let Ef=0;const ze=g([]);function j(t,e="success",n=4e3){const s=++Ef;ze.value=[...ze.value,{id:s,message:t,type:e}],setTimeout(()=>{ze.value=ze.value.filter(a=>a.id!==s)},n)}function Lf(t){ze.value=ze.value.filter(e=>e.id!==t)}function Pf(){const t=ze.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Lf(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const zf="masc_dashboard_agent_name",yn=g(null),Ma=g(!1),Vn=g(""),Ea=g([]),Xn=g([]),ln=g(""),jn=g(!1);function gs(t){yn.value=t,tr()}function ll(){yn.value=null,Vn.value="",Ea.value=[],Xn.value=[],ln.value=""}function Nf(){const t=yn.value;return t?Ht.value.find(e=>e.name===t)??null:null}function Td(t){return t?ce.value.filter(e=>e.assignee===t):[]}function jf(t){return t?se.value.find(e=>e.agent_name===t||e.name===t)??null:null}function Df(t){if(!t)return null;const e=Ya.value;return e?e.agent_briefs.find(n=>n.agent_name===t)??null:null}function wf(t){return t?jo.value.find(e=>e.agent_name===t||e.name===t)??null:null}async function tr(){const t=yn.value;if(t){Ma.value=!0,Vn.value="",Ea.value=[],Xn.value=[];try{const e=await Zp(80);Ea.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Td(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await tm(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const l=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));Xn.value=s}catch(e){Vn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Ma.value=!1}}}async function cl(){var s;const t=yn.value,e=ln.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(zf))==null?void 0:s.trim())||"dashboard";jn.value=!0;try{await Qp(n,`@${t} ${e}`),ln.value="",j(`Mention sent to ${t}`,"success"),tr()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";j(o,"error")}finally{jn.value=!1}}function Of({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${ye} status=${t.status} />
    </div>
  `}function qf({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function dl(t,e=160){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function Ff(){const t=yn.value;if(!t)return null;const e=Nf(),n=jf(t),s=wf(t),a=Df(t),o=Td(t),l=Ea.value,c=(a==null?void 0:a.display_name)??(n==null?void 0:n.name)??t,d=c!==t?t:null,m=(e==null?void 0:e.status)??(a==null?void 0:a.status)??"unknown",p=!e&&(a==null?void 0:a.is_live)===!1,v=(e==null?void 0:e.last_seen)??(a==null?void 0:a.last_activity_at)??null,f=(e==null?void 0:e.emoji)??(n==null?void 0:n.emoji),$=(e==null?void 0:e.koreanName)??(n==null?void 0:n.koreanName),S=dl(s==null?void 0:s.continuity_summary)??dl(s==null?void 0:s.skill_route_summary)??null,y=Ad(n==null?void 0:n.name,n==null?void 0:n.agent_name);return i`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${k=>{k.target.classList.contains("agent-detail-overlay")&&ll()}}
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
                  ${d?i`<span class="mono" style="font-size:0.75em;color:#888">${d}</span>`:""}
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
              ${v?i`<span>Last seen: <${et} timestamp=${v} /></span>`:null}
            </div>
            ${n||S||a!=null&&a.related_session_id?i`
                  <div class="agent-detail-sub">
                    ${n?i`<span>Linked keeper: ${n.name}${y?` · ${y}`:""}</span>`:null}
                    ${a!=null&&a.related_session_id?i`<span>Session: ${a.related_session_id}</span>`:null}
                    ${S?i`<span>${S}</span>`:null}
                  </div>
                `:null}
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{tr()}} disabled=${Ma.value}>
              ${Ma.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${ll}>Close</button>
          </div>
        </div>

        ${Vn.value?i`<div class="council-error">${Vn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${R} title="Assigned Tasks">
            ${o.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${o.map(k=>i`<${Of} key=${k.id} task=${k} />`)}</div>`}
          <//>

          <${R} title="Recent Activity">
            ${l.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${l.map((k,h)=>i`<div key=${h} class="agent-activity-line">${k}</div>`)}</div>`}
          <//>
        </div>
        <${R} title="Task History">
          ${Xn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${Xn.value.map(k=>i`<${qf} key=${k.taskId} row=${k} />`)}</div>`}
        <//>

        <${R} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${ln.value}
              onInput=${k=>{ln.value=k.target.value}}
              onKeyDown=${k=>{k.key==="Enter"&&cl()}}
              disabled=${jn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{cl()}}
              disabled=${jn.value||ln.value.trim()===""}
            >
              ${jn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Bf(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Kf(t){switch(t.delivery){case"sending":return"sending";case"streaming":return t.streamState==="finalizing"?"finalizing":"streaming";case"timeout":return"timeout";case"error":return"error";case"history":return t.role;default:return"delivered"}}function fi(t){return t.delivery==="error"||t.delivery==="timeout"?"error":t.role==="user"?"user":t.role==="assistant"?"assistant":"system"}function Id(t){return t.role==="user"?"You":t.label.trim()?t.label.trim():t.role}function Uf(t){return Id(t).slice(0,2).toUpperCase()}function Wf(t){var n;const e=(n=t==null?void 0:t.usage)==null?void 0:n.totalTokens;return typeof e=="number"&&Number.isFinite(e)?`${e} tok`:null}function Hf(t){return t?[t.modelUsed??null,typeof t.latencyMs=="number"?`${t.latencyMs} ms`:null,Wf(t)].filter(e=>!!e):[]}function ul(t){return typeof t!="number"||!Number.isFinite(t)?null:t===0?"$0.00":t<.01?`$${t.toFixed(4)}`:`$${t.toFixed(2)}`}function Gf(t){if(!t)return[];const e=["Goal","Progress","Next","Decisions","OpenQuestions","Constraints"];return t.split(`
`).map(n=>n.trim()).filter(Boolean).map(n=>{const s=e.find(a=>n.startsWith(`${a}:`));return s?{label:s,value:n.slice(s.length+1).trim()}:null}).filter(n=>!!(n&&n.value))}function Jf(t){var e;return[t.modelUsed?{label:"Model",value:t.modelUsed}:null,typeof t.latencyMs=="number"?{label:"Latency",value:`${t.latencyMs} ms`}:null,typeof((e=t.usage)==null?void 0:e.totalTokens)=="number"?{label:"Tokens",value:`${t.usage.totalTokens}`}:null,ul(t.costUsd)?{label:"Cost",value:ul(t.costUsd)}:null,t.traceId?{label:"Trace",value:t.traceId}:null,typeof t.generation=="number"?{label:"Generation",value:`${t.generation}`}:null].filter(n=>!!n)}function Yf({entry:t}){var m;const[e,n]=pn(!1),[s,a]=pn(!1),o=Hf(t.details),l=!!t.details,c=t.details?Jf(t.details):[],d=Gf((m=t.details)==null?void 0:m.stateBlock);return i`
    <article class=${`chat-bubble ${fi(t)}`}>
      <div class="chat-bubble-head">
        <div class="chat-bubble-identity">
          <div class=${`chat-avatar ${fi(t)}`}>${Uf(t)}</div>
          <div class="chat-bubble-identity-copy">
            <div class="chat-bubble-labels">
              <span class=${`chat-role-chip ${fi(t)}`}>${t.label}</span>
              <span class="chat-delivery-chip">${Kf(t)}</span>
              ${t.timestamp?i`<span class="chat-time-chip">${Bf(t.timestamp)}</span>`:null}
            </div>
            <div class="chat-identity-title">${Id(t)}</div>
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
              ${d.length>0?i`
                    <div class="chat-detail-section">
                      <div class="chat-detail-section-title">State Snapshot</div>
                      <div class="chat-state-grid">
                        ${d.map(p=>i`
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
  `}function Vf({entries:t,emptyText:e}){const n=En(null),s=t.map(a=>`${a.id}:${a.text.length}:${a.delivery}`).join("|");return st(()=>{const a=n.current;a&&(a.scrollTop=a.scrollHeight)},[s]),i`
    <div class="chat-transcript" ref=${n}>
      ${t.length===0?i`<div class="chat-empty-copy">${e}</div>`:t.map(a=>i`<${Yf} key=${a.id} entry=${a} />`)}
    </div>
  `}function Xf({draft:t,placeholder:e,disabled:n,streaming:s,onDraftChange:a,onSend:o,onAbort:l}){return i`
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
  `}function Qf(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Zf(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function tg(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function eg(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Rd(t){if(!t)return null;const e=ne.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function ng({keeper:t,showRawStatus:e=!1}){if(st(()=>{t!=null&&t.name&&fc(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=ne.value[t.name],s=Rd(t),a=Vi.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Qf(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Zf((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${tg(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${eg(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Md({keeperName:t,placeholder:e}){const[n,s]=pn("");st(()=>{t&&fc(t)},[t]);const a=$t.value[t]??[],o=ra.value[t]??!1,l=Bt.value[t],c=async()=>{const d=n.trim();if(!(!t||!d)){s("");try{await xm(t,d)}catch(m){if(m instanceof Error&&m.name==="AbortError")return;const p=m instanceof Error?m.message:`Failed to message ${t}`;j(p,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <${Vf}
        entries=${a}
        emptyText="No direct keeper conversation yet."
      />
      <${Xf}
        draft=${n}
        placeholder=${e}
        disabled=${!t}
        streaming=${o}
        onDraftChange=${s}
        onSend=${()=>{c()}}
        onAbort=${()=>{vc(t)}}
      />
      ${l?i`<div class="control-status-copy control-error-copy">${l}</div>`:null}
    </div>
  `}function sg({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=Rd(e),a=Xi.value[e.name]??!1,o=Qi.value[e.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{Sm(e.name,t).catch(d=>{const m=d instanceof Error?d.message:`Failed to probe ${e.name}`;j(m,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{Cm(e.name,t).catch(d=>{const m=d instanceof Error?d.message:`Failed to recover ${e.name}`;j(m,"error")})}}
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
  `}const er=g(null);function Ed(t){er.value=t,km(t.name)}function pl(){er.value=null}function ag(t){return typeof t!="number"||Number.isNaN(t)?"확인 필요":t>=.85?"높음":t>=.7?"상승 중":"안정"}function ig({keeper:t}){var p,v;const e=t.metrics_series??[];if(e.length<2){const f=(((p=t.context)==null?void 0:p.context_ratio)??t.context_ratio??0)*100,$=f>85?"#ef4444":f>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${f.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${f.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=e.length,l=e.map((f,$)=>{const S=a+$/(o-1)*(n-2*a),y=s-a-(f.context_ratio??0)*(s-2*a);return{x:S,y,p:f}}),c=l.map(({x:f,y:$})=>`${f.toFixed(1)},${$.toFixed(1)}`).join(" "),d=(((v=e[e.length-1])==null?void 0:v.context_ratio)??0)*100,m=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:f})=>f.is_handoff).map(({x:f})=>i`
          <line x1="${f.toFixed(1)}" y1="${a}" x2="${f.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${m}" stroke-width="1.5"/>
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}function og({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
  `}function rg({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px;">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function lg({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function ml({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom:12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}async function cg(){try{const t=await Ha({actor:ec(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=mc(t.result);await ms(),e!=null&&e.skipped_reason?j(e.skipped_reason,"warning"):j(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";j(e,"error")}}function dg({keeper:t}){return i`
    <div style="margin-top:24px; border-top:1px solid rgba(255,255,255,0.1); padding-top:24px;">
      <h3 style="margin:0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display:grid; grid-template-columns:1fr 1fr; gap:20px;">
        <div style="display:flex; flex-direction:column; gap:12px;">
          <${ng} keeper=${t} />
          <${sg}
            actor=${ec()}
            keeper=${t}
            onPokeLodge=${()=>{cg()}}
          />
        </div>

        <div style="min-height:345px;">
          <${Md}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function ug(){var s,a,o,l,c;const t=er.value;if(!t)return null;const e=Ad(t.name,t.agent_name),n=(((s=t.traits)==null?void 0:s.length)??0)>0||(((a=t.interests)==null?void 0:a.length)??0)>0||!!t.skill_primary||!!t.last_heartbeat;return i`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${d=>{d.target.classList.contains("keeper-detail-overlay")&&pl()}}
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
            <${ye} status=${t.status} />
          </div>
          <button
            onClick=${()=>pl()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        <${ig} keeper=${t} />

        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">
          ${n?i`
                <${R} title="Profile">
                  <${ml} traits=${t.traits??[]} label="Traits" />
                  <${ml} traits=${t.interests??[]} label="Interests" />
                  ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span></div>`:null}
                  ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">Last heartbeat: <${et} timestamp=${t.last_heartbeat} /></div>`:null}
                <//>
              `:null}

          ${t.trpg_stats?i`
                <${R} title="TRPG Stats">
                  <${og} stats=${t.trpg_stats} />
                <//>
              `:null}

          ${t.inventory&&t.inventory.length>0?i`
                <${R} title="Equipment (${t.inventory.length})">
                  <${rg} items=${t.inventory} />
                <//>
              `:null}

          ${t.relationships&&Object.keys(t.relationships).length>0?i`
                <${R} title="Relationships (${Object.keys(t.relationships).length})">
                  <${lg} rels=${t.relationships} />
                <//>
              `:null}

          <${R} title="Memory & Context">
            <div class="keeper-signal-list">
              <div class="keeper-signal-row">
                <span>Context pressure</span>
                <strong>${ag(((o=t.context)==null?void 0:o.context_ratio)??t.context_ratio??null)}</strong>
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

        <${dg} keeper=${t} />
      </div>
    </div>
  `}function pg({cluster:t,project:e,room:n,generatedAt:s}){return i`
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
        <strong>${s?ee(s):"기록 없음"}</strong>
      </div>
    </div>
  `}function mg(){const t=Bc.value,e=Rt((t==null?void 0:t.status)??(Ie.value?"bad":"warn")),n=!t||t.sections.length===0,s=(t==null?void 0:t.status)==="error"||(t==null?void 0:t.status)==="unavailable"&&!(t!=null&&t.cached);return i`
    <${R} title="판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>휴리스틱 대신 별도 판단 결과</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${e}">
          ${Kt((t==null?void 0:t.status)??(Ie.value?"error":"loading"))}
        </span>
        ${t!=null&&t.model?i`<span class="command-chip">${t.model}</span>`:null}
        ${t!=null&&t.generated_at?i`<span class="command-chip">${ee(t.generated_at)}</span>`:null}
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
                <article class="mission-briefing-section ${Rt(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${Rt(a.status)}">${Kt(a.status)}</span>
                      ${ol(a.signal_class)?i`<span class="command-chip ${a.signal_class==="mixed"?"warn":""}">${ol(a.signal_class)}</span>`:null}
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
          `:!He.value&&!Ie.value&&n?i`
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
                      <span class="command-chip ${a.severity==="watch"?"warn":""}">${Kt(a.severity)}</span>
                    </div>
                    <p>${a.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{fa(s)}} disabled=${He.value}>
          ${He.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{fa(!0)}} disabled=${He.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function _g({item:t,selected:e,sessionLookup:n}){const s=yf(t),a=t.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),o=t.top_action??null;return i`
    <article class="mission-attention-card ${Rt((o==null?void 0:o.severity)??t.severity)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>xf(t.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.summary}</strong>
            <div class="mission-card-target">${Ra(t.target_type)}${t.target_id?` · ${t.target_id}`:""}</div>
          </div>
          <span class="command-chip ${Rt((o==null?void 0:o.severity)??t.severity)}">${o?$f(o):t.severity}</span>
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
            <strong>${t.last_seen_at?ee(t.last_seen_at):"기록 없음"}</strong>
            <small>${Ra(t.target_type)}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${o?Qa(o.action_type):"판단 필요"}</strong>
            <small>${o?hf(o):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${o?i`<div class="mission-inline-note">${o.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?i`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>i`
                  <button class="mission-link-row" onClick=${()=>bd(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${Kt(l.status)} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:i`<div class="empty-state">직접 연결된 세션이 아직 없습니다.</div>`}

        ${t.related_agent_names.length>0?i`
              <div class="mission-pill-row">
                ${t.related_agent_names.slice(0,8).map(l=>i`
                  <button class="mission-pill action" onClick=${()=>gs(l)}>${l}</button>
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
              <button class="control-btn ghost" onClick=${()=>Zo(o,s,"상황판 주의 신호")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>yd(o,s,"상황판 주의 신호")}>
                원인 보기
              </button>
            `:i`
              <button class="control-btn ghost" onClick=${()=>$d(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>hd(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function vg({brief:t,selected:e}){var l,c;const n=t.member_previews.slice(0,4),s=t.top_recommendation??null,a=t.top_attention??null,o=n.map(d=>d.display_name??d.agent_name);return i`
    <article class="mission-crew-card ${Rt(((l=t.top_attention)==null?void 0:l.severity)??t.health??t.status)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>bd(t.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.goal}</strong>
            <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          </div>
          <span class="command-chip ${Rt(((c=t.top_attention)==null?void 0:c.severity)??t.health??t.status)}">${Kt(t.status)}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${t.member_names.length}</strong>
            <small>${o.slice(0,3).join(", ")||t.member_names.slice(0,3).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${gf(t.elapsed_sec)}</strong>
            <small>${t.started_at?`${ee(t.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 흐름</span>
            <strong>${t.last_event_at?ee(t.last_event_at):"기록 없음"}</strong>
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
        <small>${t.last_event_at?ee(t.last_event_at):"시각 없음"}</small>
      </div>

      ${t.operation_badges.length>0?i`
            <div class="mission-pill-row">
              ${t.operation_badges.slice(0,3).map(d=>i`
                <span class="mission-pill">
                  ${d.operation_id} · ${Kt(d.status)}${d.stage?` · ${d.stage}`:""}
                </span>
              `)}
            </div>
          `:null}

      ${n.length>0?i`
            <div class="mission-member-preview-grid">
              ${n.map(d=>i`
                <button class="mission-member-preview" onClick=${()=>gs(d.agent_name)}>
                  <strong>${d.display_name??d.agent_name}</strong>
                  <span>${d.current_work??"현재 작업 없음"}</span>
                  <small>
                    ${d.recent_output_preview??d.recent_input_preview??"최근 입출력 없음"}
                    ${d.is_live===!1?" · archived participant":""}
                  </small>
                </button>
              `)}
            </div>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>vo("intervene",t.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>vo("command",t.session_id)}>세션 원인 보기</button>
        ${s?i`<button class="control-btn ghost" onClick=${()=>Zo(s,a,"상황판 세션 요약")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function fg({detail:t,loading:e,error:n}){if(e&&!t)return i`
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
                      <span>${a.timestamp?ee(a.timestamp):"시각 없음"}</span>
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
                  <button class="mission-member-preview" onClick=${()=>gs(a.agent_name)}>
                    <strong>${a.display_name??a.agent_name}</strong>
                    <span>${a.current_work??"현재 작업 없음"}</span>
                    <small>
                      ${a.recent_output_preview??a.recent_input_preview??"최근 입출력 없음"}
                      ${a.is_live===!1?" · archived participant":""}
                      ${a.last_activity_at?` · ${ee(a.last_activity_at)}`:""}
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
                  <button class="mission-link-row" onClick=${()=>vo("command",s.session_id)}>
                    <strong>${a.operation_id}</strong>
                    <span>${Kt(a.status)}${a.stage?` · ${a.stage}`:""}</span>
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
                    <span>${Kt(a.status)}${a.generation!=null?` · 세대 ${a.generation}`:""}</span>
                    <small>${a.current_work??"현재 작업 정보 없음"}</small>
                  </div>
                `):i`<div class="empty-state">직접 연결된 키퍼는 없습니다.</div>`}
          </div>
        </div>
      </div>
    <//>
  `}function gg({row:t}){var o,l,c,d,m,p,v,f,$,S,y,k;const e=[`세대 ${t.brief.generation??((o=t.keeper)==null?void 0:o.generation)??0}`,t.brief.context_ratio!=null?`컨텍스트 ${Math.round(t.brief.context_ratio*100)}%`:((l=t.keeper)==null?void 0:l.context_ratio)!=null?`컨텍스트 ${Math.round(t.keeper.context_ratio*100)}%`:null,t.brief.last_turn_ago_s!=null?`최근 턴 ${Math.round(t.brief.last_turn_ago_s)}초 전`:null].filter(h=>h!==null).join(" · "),n=t.recentTools.length>0?t.recentTools.join(", "):Rf(Mf(t.keeper)),s=Cd(t.brief.name,t.brief.agent_name??((c=t.keeper)==null?void 0:c.agent_name)),a={name:t.brief.name,koreanName:((d=t.keeper)==null?void 0:d.koreanName)??null,runtimeLabel:s,emoji:((m=t.keeper)==null?void 0:m.emoji)??null,tone:Rt(t.brief.status??((p=t.keeper)==null?void 0:p.status)),statusRaw:t.brief.status??((v=t.keeper)==null?void 0:v.status)??null,statusLabel:Kt(t.brief.status??((f=t.keeper)==null?void 0:f.status)),focus:t.currentWork,lastActivityAt:(($=t.keeper)==null?void 0:$.last_heartbeat)??null,lastActivityFallback:"최근 활동 없음",continuity:e||"연속성 정보 없음",contextRatio:t.brief.context_ratio??((S=t.keeper)==null?void 0:S.context_ratio)??null,summary:(y=t.keeper)!=null&&y.skill_reason?`판단 요약 · ${Pt(t.keeper.skill_reason,120)}`:null,relatedSessionId:null,recentEvent:t.recentEvent,recentInput:t.recentInput,recentOutput:t.recentOutput,recentTools:t.recentTools,allowedTools:[],disclosureLabel:"연속성 상세"};return i`<${xd}
    variant="mission"
    model=${{...a,recentTools:t.recentTools.length>0?t.recentTools:[n],recentEvent:t.recentEvent??`runtime agent · ${t.brief.agent_name??((k=t.keeper)==null?void 0:k.agent_name)??"기록 없음"}`}}
    onClick=${()=>{t.keeper&&Ed(t.keeper)}}
  />`}function $g({item:t}){const e=t.action??null,n=t.attention??null;return i`
    <article class="mission-action-card ${Rt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${Rt(t.severity)}">
          ${t.signal_type==="action"&&e?Qa(e.action_type):(n==null?void 0:n.kind)??"내부 신호"}
        </span>
        <span class="mission-card-target">${Ra(t.target_type)}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      ${e?i`<div class="mission-action-preview">${e.reason}</div>`:null}
      <div class="mission-card-actions">
        ${e?i`
              <button class="control-btn ghost" onClick=${()=>Zo(e,n,"상황판 내부 신호")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>yd(e,n,"상황판 내부 신호")}>이 이슈의 원인 보기</button>
            `:n?i`
                <button class="control-btn ghost" onClick=${()=>$d(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>hd(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function _l(){var p;const t=Ya.value;if(io.value&&!t)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(va.value&&!t)return i`<div class="empty-state error">${va.value}</div>`;if(!t)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;Zt.value&&!t.attention_queue.some(v=>v.id===Zt.value)&&(Zt.value=null);const e=t.sessions;re.value&&!e.some(v=>v.session_id===re.value)&&(re.value=null);const n=t.attention_queue.find(v=>v.id===Zt.value)??null,s=(n==null?void 0:n.related_session_ids.find(v=>e.some(f=>f.session_id===v)))??null,a=re.value??s??((p=e[0])==null?void 0:p.session_id)??null,o=kf(),l=e.find(v=>v.session_id===a)??null,c=t.keeper_briefs.slice(0,6).map(bf),d=t.attention_queue.filter(v=>v.related_session_ids.length>0).slice(0,6),m=t.internal_signals.slice(0,3);return st(()=>{X_(a)},[a]),i`
    <section class="dashboard-panel mission-view">
      <${xt} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 어떤 세션이 돌고 있고, 누가 참여하며, 어디가 막혔는지를 한 시점에서 읽는 기본 관찰면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${Rt(t.summary.room_health)}">${Kt(t.summary.room_health)}</span>
          <span class="command-chip">${t.summary.project??"프로젝트 미지정"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?ee(t.generated_at):"기록 없음"}</span>
        </div>
      </div>

      <${Xa} />

      <${pg}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <${mg} />

      ${a?i`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${(l==null?void 0:l.goal)??a}${n?` · ${n.summary}`:""}</span>
              <button class="control-btn ghost" onClick=${Sf}>선택 해제</button>
            </div>
          `:null}

      <${R} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 작전을 먼저 봅니다.</p>
        </div>
        <div class="mission-list-stack">
          ${e.length>0?e.map(v=>i`<${vg} key=${v.session_id} brief=${v} selected=${a===v.session_id} />`):i`<div class="empty-state">지금 활성 세션이 없습니다.</div>`}
        </div>
      <//>

      <${fg}
        detail=${oo.value}
        loading=${Vs.value}
        error=${Xs.value}
      />

      <div class="mission-human-grid">
        <${R} title="주의 대기열" class="mission-list-card" semanticId="mission.attention_queue">
          <div class="mission-section-head">
            <h3>어느 세션을 먼저 봐야 하나</h3>
            <p>문제와 경고는 세션에 연결된 것만 먼저 보여주고, 원인 분석은 선택된 세션에서 이어서 봅니다.</p>
          </div>
          <div class="mission-lane-stack">
            ${d.length>0?d.map(v=>i`<${_g} key=${v.id} item=${v} selected=${Zt.value===v.id} sessionLookup=${o} />`):i`<div class="empty-state">지금 세션 단위 주의 대기열은 비어 있습니다.</div>`}
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
              ${m.length>0?m.map(v=>i`<${$g} key=${v.id} item=${v} />`):i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
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
          ${c.length>0?c.map(v=>i`<${gg} key=${v.brief.name} row=${v} />`):i`<div class="empty-state">지금 보이는 키퍼가 없습니다.</div>`}
        </div>
        <div class="mission-card-actions">
          <button class="control-btn ghost" onClick=${()=>it("execution")}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${()=>it("command")}>지휘 진단면 보기</button>
        </div>
      <//>
    </section>
  `}const hg="modulepreload",yg=function(t){return"/dashboard/"+t},vl={},bg=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(m){return Promise.all(m.map(p=>Promise.resolve(p).then(v=>({status:"fulfilled",value:v}),v=>({status:"rejected",reason:v}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),d=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(m=>{if(m=yg(m),m in vl)return;vl[m]=!0;const p=m.endsWith(".css"),v=p?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${v}`))return;const f=document.createElement("link");if(f.rel=p?"stylesheet":hg,p||(f.as="script"),f.crossOrigin="",f.href=m,d&&f.setAttribute("nonce",d),document.head.appendChild(f),p)return new Promise(($,S)=>{f.addEventListener("load",$),f.addEventListener("error",()=>S(new Error(`Unable to preload CSS for ${m}`)))})}))}function o(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&o(c.reason);return e().catch(o)})};function Qn(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function tt(t){if(!t)return"정보 없음";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function kg(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Ld(t){if(!t)return"정보 없음";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"기한 지남":n<60?`${n}초 후`:n<3600?`${Math.round(n/60)}분 후`:n<86400?`${Math.round(n/3600)}시간 후`:`${Math.round(n/86400)}일 후`}function E(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let fl=!1,xg=0;function Sg(){return++xg}let gi=null;async function Cg(){gi||(gi=bg(()=>import("./mermaid.core-DcU6QXGN.js").then(e=>e.bE),[]).then(e=>e.default));const t=await gi;return fl||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),fl=!0),t}function me(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function bn(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":`${Math.round(t*100)}%`}function Ye(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":t<60?`${Math.round(t)}초`:t<3600?`${Math.round(t/60)}분`:`${Math.round(t/3600)}시간`}function $s(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function Ce(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:$s(t/e*100)}function Ag(t,e){const n=$s(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function ti(t){if(!t)return"최근 체인 이력이 없습니다";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`토큰 ${t.tokens}`),t.message&&e.push(t.message),e.join(" · ")}const Tg=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Pd=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"orchestra",label:"오케스트라",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],Ig=Pd.map(t=>t.id),Rg=["chain_start","node_start","node_complete","chain_complete","chain_error"],Mg={warroom:{title:"실시간 워룸",description:"실제 실행, 워커, 메시지, 트레이스를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 작전, 분견대, 의존 관계를 먼저 읽는 기본 진입 표면입니다."},orchestra:{title:"룸 오케스트라 맵",description:"룸, 세션, 레인, 워커, 키퍼를 한 장의 작전판으로 읽는 시각화 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"레인 이동, 워커 결속, 막힘을 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 작전별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"실제 관리 유닛인지, 실시간 에이전트 기반 자동 투영인지 구분해서 봅니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"작전, 주체, 유닛 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"결정 승인과 유닛 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function gl(t){return!!t&&Ig.includes(t)}function Eg(){const t=w.value.params;return t.source!=="mission"&&t.source!=="execution"?{}:{source:t.source,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function hs(t){const e=Eg(),n=jd(),s=nr();if(t==="operations")return e;if(t==="chains"){const a=rn.value;return a?{...e,surface:t,operation:a}:{...e,surface:t}}return t==="swarm"||t==="warroom"||t==="orchestra"?{...e,surface:t,...n?{run_id:n}:{},...s?{operation_id:s}:{}}:{...e,surface:t}}function Lg(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function Pg(t){switch(t){case"company":return"중대";case"platoon":return"소대";case"squad":return"분대";case"agent":return"에이전트";default:return t}}function dt(t){return lo.value===t}function ys(){return Ko.value}function zg(t){var a,o,l,c,d,m,p;const e=Ko.value,n=Be.value,s=vs.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"실시간 실행, 워커, 메시지, 트레이스를 한 화면에서 보고 필요한 세부 표면으로 바로 이동합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 의존 관계를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(o=e==null?void 0:e.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((d=(c=e==null?void 0:e.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:d.reason)??"레인 이동과 막힘 근거를 보고 다음 확인 도구를 고릅니다."};case"orchestra":return{tool:"masc_operator_snapshot",reason:"룸, 세션, 레인, 워커, 키퍼를 한 장에서 훑은 뒤 내려볼 대상을 고릅니다."};case"chains":return{tool:(p=(m=s==null?void 0:s.operations[0])==null?void 0:m.preview_run)!=null&&p.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"이 구조가 실제 관리 단위인지 자동 투영인지 먼저 구분해야 지휘면을 오해하지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 유닛과 작전을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"트레이스 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 제어 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function Ng(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function jg(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function zd(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Nd(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function jd(){const e=Nd().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function nr(){const e=Nd().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Dg(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function wg(t){return t.status==="claimed"||t.status==="in_progress"}function Og(t){const e=_s.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function $i(t){var e;return((e=_s.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function qg(t){const e=_s.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function _e(t){try{await t()}catch{}}function sr(t){return(t==null?void 0:t.trim().toLowerCase())??""}function le(t){const e=sr(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function wt(t){const e=sr(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function Fg(){var n,s,a,o,l,c,d,m,p;const t=Be.value;if(!t)return!1;const e=t.workers.some(v=>v.joined||v.live_presence||v.completed||v.current_task_matches_run||v.heartbeat_fresh||v.claim_marker_seen||v.done_marker_seen||v.final_marker_seen||!!v.current_task||!!v.bound_task_id||!!v.last_message);return!!((n=t.operation)!=null&&n.operation_id||(s=t.detachment)!=null&&s.detachment_id||(((a=t.summary)==null?void 0:a.joined_workers)??0)>0||(((o=t.summary)==null?void 0:o.live_workers)??0)>0||(((l=t.summary)==null?void 0:l.current_task_bound)??0)>0||(((c=t.summary)==null?void 0:c.fresh_heartbeats)??0)>0||(((d=t.summary)==null?void 0:d.claim_markers_seen)??0)>0||(((m=t.summary)==null?void 0:m.done_markers_seen)??0)>0||(((p=t.summary)==null?void 0:p.final_markers_seen)??0)>0||e||t.recent_messages.length>0||t.recent_trace_events.length>0)}function Bg(t){const e=sr(t.status);return e==="active"||e==="running"}function Kg(){var o,l,c,d;const t=((o=Et.value)==null?void 0:o.sessions)??[],e=Be.value,n=((l=e==null?void 0:e.detachment)==null?void 0:l.session_id)??null;if(n){const m=t.find(p=>p.session_id===n);if(m)return m}const s=((c=e==null?void 0:e.operation)==null?void 0:c.operation_id)??nr();if(s){const m=t.find(p=>p.command_plane_operation_id===s);if(m)return m}const a=((d=e==null?void 0:e.detachment)==null?void 0:d.detachment_id)??null;if(a){const m=t.find(p=>p.command_plane_detachment_id===a);if(m)return m}return t.find(Bg)??t[0]??null}function Cn(t){return t==="proven"?"ok":t==="partial"?"warn":"bad"}function Ve(t){return Array.isArray(t)?t:[]}function zt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)?t:{}}function Ts(t){return typeof t=="string"&&t.trim()!==""?t:null}function Ug(t){return typeof t=="number"&&Number.isFinite(t)?t:null}function Wg(t){const e=t.split("/");return e.length<=3?t:`…/${e.slice(-3).join("/")}`}function Hg(t){return t==="proven"?"충분":t==="partial"?"부분":"부족"}function Gg(t){return t==="proven"?"협업 증거가 충분합니다":t==="partial"?"흔적은 있으나 협업 증거가 덜 모였습니다":"증거가 부족합니다"}function Jg(t,e,n,s,a,o,l,c,d){const m=[`${s}명이 실제 흔적을 남겼고, 계획된 참여자는 ${a}명입니다.`,l>0?`서로를 참조한 상호작용 증거가 ${l}건 있습니다.`:"서로를 참조한 명시적 상호작용 증거가 아직 없습니다.",c>0?`도구·산출물·체크포인트 증거가 ${c}건 있습니다.`:"도구·산출물·체크포인트 증거가 거의 없습니다.",d>0?`CPv2 backing trace가 ${d}건 있어 실행 흔적은 남아 있습니다.`:"관리형 backing trace는 아직 없습니다."];return n==="proven"&&e==="insufficient"?[m[0]??"","왜 이렇게 판정됐나: 과거 proof는 proved였지만, 현재 보이는 live evidence는 부족해서 partial로 완화했습니다.","다음 보강 포인트: 최근 응답 턴이나 도구 호출을 다시 남겨 historical proof를 현재 상태와 연결해야 합니다."]:n==="proven"&&e==="partial"?[m[0]??"","왜 이렇게 판정됐나: historical proof는 강하지만, 현재 live evidence는 아직 partial 수준입니다.","다음 보강 포인트: 최근 상호작용과 실행 근거를 더 남기면 proven으로 회복할 수 있습니다."]:t==="partial"?[m[0]??"",o>0?`partial인 이유: 호출되었지만 응답하지 않은 참여자가 ${o}명 있습니다.`:l===0?"partial인 이유: 여러 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.":"partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.",d>0?"다음 보강 포인트: 응답 턴이나 도구 호출을 남기면 proof가 협업 수준으로 올라갑니다.":"다음 보강 포인트: 관리형 trace 또는 산출물 연결을 더 남기면 근거가 강해집니다."]:t==="proven"?[m[0]??"","결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.","다음 행동: raw evidence는 접어두고 결과 산출물과 다음 실행 결정만 확인하면 됩니다."]:[m[0]??"",o>0?`결론: 협업 시도는 있었지만 무응답 참여자가 ${o}명 있어 협업 증거로 인정하기 어렵습니다.`:"결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.",c>0?"다음 보강 포인트: 응답 턴과 도구 근거를 서로 연결해 남겨야 합니다.":"다음 보강 포인트: 참여자 간 턴, 도구 근거, 산출물 연결을 더 남겨야 합니다."]}function Yg(t){return t==="historical_only"?"historical only":t==="live_and_historical"?"live + historical":"live"}function $l(t){return(t==null?void 0:t.mode)==="requested_not_found"?"bad":(t==null?void 0:t.mode)==="latest_auto_selected"?"warn":"ok"}function Vg(t){return(t==null?void 0:t.mode)==="requested_not_found"?"선택 실패":(t==null?void 0:t.mode)==="latest_auto_selected"?"자동 선택":(t==null?void 0:t.mode)==="explicit"?"명시 선택":"선택 없음"}function Xg(t){return t.activity_state==="acted"?(t.interaction_count??0)>0||(t.tool_evidence_count??0)>0?"ok":"warn":t.activity_state==="mentioned_only"?"warn":"bad"}function Qg(t){return t.activity_state==="acted"?"실제 흔적":t.activity_state==="mentioned_only"?"호출만 됨":"계획만 됨"}function Zg(t){if(t.activity_state==="acted")return`턴 ${t.turn_count??0} · spawn ${t.spawn_count??0} · 도구 근거 ${t.tool_evidence_count??0}`;if(t.activity_state==="mentioned_only"){const e=t.requested_by?`호출자 ${t.requested_by}`:"호출자 미상";return`호출 ${t.mention_count??0}회 · ${e}`}return"계획된 참여자이지만 아직 이벤트가 없습니다."}function hl(t){return Array.isArray(t.tool_names)?t.tool_names:[]}function t$({selection:t,summary:e}){if(!t||t.mode==="explicit")return null;const n=t.mode==="latest_auto_selected"&&(e==null?void 0:e.historical_verdict)==="proven"&&(e==null?void 0:e.live_verdict)!=="proven";return i`
    <div class="command-guide-card ${$l(t)}">
      <div class="command-guide-head">
        <strong>${Vg(t)}</strong>
        <span class="command-chip ${$l(t)}">${t.mode??"none"}</span>
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
  `}function e$({item:t}){return i`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${t.summary??t.event_type??"도구 근거"}</strong>
          <div class="command-meta-line">
            <span>${t.actor??"시스템"}</span>
            <span>${t.event_type??"event"}</span>
          </div>
        </div>
        <span class="command-chip">${tt(t.timestamp??null)}</span>
      </div>
      ${hl(t).length>0?i`<div class="semantic-tag-row">
            ${hl(t).map(e=>i`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
    </article>
  `}function n$(t){const e=new Map;for(const n of t){const s=[n.timestamp??"",n.event_type??"",n.actor??"",n.summary??""].join("|"),a=n.source??"unknown",o=e.get(s);if(o){o.sources.includes(a)||o.sources.push(a),!o.operation_id&&n.operation_id&&(o.operation_id=n.operation_id);continue}e.set(s,{...n,sources:[a]})}return[...e.values()]}function s$(t){return t.sources.length===2?"세션 + 지휘":t.sources.length===1?t.sources[0]==="unknown"?"출처 미상":t.sources[0]??"출처":t.sources.join(" + ")}function a$(t){const e=[];for(const[n,s]of Object.entries(t))if(s!=null){if(typeof s=="string"){if(s.trim()==="")continue;e.push({label:n,value:s});continue}if(typeof s=="number"||typeof s=="boolean"){e.push({label:n,value:String(s)});continue}}return e}function i$(t){const e=zt(t),n=zt(e.traces),s=Array.isArray(n.events)?n.events:[],a=zt(e.detachments),o=Array.isArray(a.detachments)?a.detachments:[],l=zt(o[0]),c=zt(l.detachment),d=zt(l.operation),m=zt(e.summary),p=zt(m.operations),v=zt(p.summary);return[{label:"작전",value:Ts(e.operation_id)??"없음"},{label:"분견대",value:Ts(e.detachment_id)??"없음"},{label:"트레이스 이벤트",value:`${s.length}`},{label:"분견대 상태",value:Ts(c.status)??"없음"},{label:"작전 단계",value:Ts(d.stage)??"없음"},{label:"활성 작전",value:`${Ug(v.active)??0}`}]}function o$({item:t}){return i`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${t.summary??t.event_type??"이벤트"}</strong>
          <div class="command-meta-line">
            <span>${s$(t)}</span>
            <span>${t.event_type??"이벤트"}</span>
            <span>${t.actor??"시스템"}</span>
          </div>
        </div>
        <span class="command-chip">${tt(t.timestamp)}</span>
      </div>
      ${t.sources.length>1?i`<div class="semantic-tag-row">
            ${t.sources.map(e=>i`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
    </article>
  `}function r$({item:t}){const e=t.recent_output_preview??null,n=t.recent_input_preview??null,s=t.recent_event_summary??null,a=t.recent_request_preview??null,o=t.last_active_at??t.recent_request_at??null;return i`
    <article class="mission-activity-row proof-actor-row">
      <div class="mission-activity-head">
        <div>
          <strong>${t.actor}</strong>
          <div class="mission-activity-meta">
            <span>${t.role??"참여자"}</span>
            <span>${o?tt(o):"기록 없음"}</span>
          </div>
        </div>
        <span class="command-chip ${Xg(t)}">
          ${Qg(t)}
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>${Zg(t)}</span>
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
      ${Ve(t.recent_tool_names).length>0?i`<div class="semantic-tag-row">
            ${Ve(t.recent_tool_names).map(l=>i`<span class="semantic-tag">${l}</span>`)}
          </div>`:null}
    </article>
  `}function l$({item:t}){return i`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${t.kind}</strong>
          <div class="command-meta-line">
            <span>${Wg(t.path)}</span>
          </div>
        </div>
        <span class="command-chip ${t.exists?"ok":"warn"}">${t.exists?"존재함":"없음"}</span>
      </div>
    </article>
  `}function yl({title:t,rows:e}){return e.length===0?null:i`
    <div class="proof-kv-block">
      ${t?i`<strong>${t}</strong>`:null}
      <div class="proof-kv-grid">
        ${e.map(n=>i`
          <span>${n.label}</span>
          <strong>${n.value}</strong>
        `)}
      </div>
    </div>
  `}function c$(){var U,I,A;const t=w.value.params,e=t.session_id??null,n=t.operation_id??null;st(()=>{Vc(e,n)},[e,n]);const s=Yc.value;if(ro.value&&!s)return i`<section class="dashboard-panel"><div class="loading-indicator">근거 화면 불러오는 중…</div></section>`;if(Ge.value&&!s)return i`<section class="dashboard-panel"><div class="error-card">${Ge.value}</div></section>`;const a=s==null?void 0:s.summary,o=(s==null?void 0:s.selection)??null,l=Ve(s==null?void 0:s.actor_contributions),c=Ve(s==null?void 0:s.artifacts),d=Ve(s==null?void 0:s.tool_evidence),m=(s==null?void 0:s.proof_verdict)??"insufficient",p=(a==null?void 0:a.live_verdict)??m,v=(a==null?void 0:a.historical_verdict)??null,f=(a==null?void 0:a.verdict_basis)??"live",$=(s==null?void 0:s.cp_backing_evidence)??null,S=Array.isArray((U=$==null?void 0:$.traces)==null?void 0:U.events)?((A=(I=$.traces)==null?void 0:I.events)==null?void 0:A.length)??0:0,y=(a==null?void 0:a.actors_count)??l.length,k=(a==null?void 0:a.planned_actor_count)??l.length,h=(a==null?void 0:a.unanswered_actor_count)??l.filter(N=>N.activity_state!=="acted"&&(N.mention_count??0)>0).length,C=(a==null?void 0:a.mentioned_actor_count)??l.filter(N=>(N.mention_count??0)>0).length,M=(a==null?void 0:a.interaction_count)??0,T=(a==null?void 0:a.evidence_count)??0,P=n$(Ve(s==null?void 0:s.timeline)),G=a$(zt(s==null?void 0:s.goal_binding)),L=i$($),V=c.filter(N=>N.exists).length,X=c.length-V,rt=Jg(m,p,v,y,k,h,M,T,S);return i`
    <section class="dashboard-panel mission-view">
      <${xt} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>근거</h2>
          <p>이 세션이 실제로 여러 참여자의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${Cn(m)}">${Hg(m)}</span>
          ${s!=null&&s.session_id?i`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?i`<span class="command-chip">${tt(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${Ge.value?i`<div class="error-card">${Ge.value}</div>`:null}

      <${t$} selection=${o} summary=${a??null} />

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${Cn(m)}">
          <span>판정</span>
          <strong>${Gg(m)}</strong>
          <small>${(a==null?void 0:a.detail)??"협업 증거를 verdict로 요약합니다."}</small>
        </div>
        <div class="summary-stat-card ${Cn(p)}">
          <span>Live 판정</span>
          <strong>${p}</strong>
          <small>${Yg(f)} 기준 최종 판정에 반영</small>
        </div>
        <div class="summary-stat-card ${Cn(v??"insufficient")}">
          <span>Historical proof</span>
          <strong>${v??"none"}</strong>
          <small>persisted proof 문서 기준</small>
        </div>
        <div class="summary-stat-card">
          <span>실제 흔적</span>
          <strong>${y}</strong>
          <small>이벤트를 남긴 actor 수</small>
        </div>
        <div class="summary-stat-card ${k>y?"warn":"ok"}">
          <span>계획된 참여자</span>
          <strong>${k}</strong>
          <small>${C>0?`${C}명 호출됨`:"호출 기록 없음"}</small>
        </div>
        <div class="summary-stat-card ${h>0?"warn":"ok"}">
          <span>무응답</span>
          <strong>${h}</strong>
          <small>${h>0?"호출됐지만 응답 근거 없음":"무응답 참여자 없음"}</small>
        </div>
        <div class="summary-stat-card ${M>0?"ok":"warn"}">
          <span>직접 상호작용</span>
          <strong>${M}</strong>
          <small>참여자 간 직접 연결 근거</small>
        </div>
        <div class="summary-stat-card ${T>0?"ok":"warn"}">
          <span>근거</span>
          <strong>${T}</strong>
          <small>도구 / 산출물 / 체크포인트</small>
        </div>
        <div class="summary-stat-card ${S>0?"ok":"warn"}">
          <span>CP 트레이스</span>
          <strong>${S}</strong>
          <small>관리형 backing 이벤트</small>
        </div>
        <div class="summary-stat-card ${X===0&&c.length>0?"ok":"warn"}">
          <span>산출물</span>
          <strong>${V}/${c.length}</strong>
          <small>${X>0?`${X}개 누락`:"전부 존재함"}</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${R} title="3줄 근거 요약" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, 왜 아직 부족한지, 다음에 무엇을 남겨야 하는지만 먼저 봅니다.</p>
          </div>
          <div class="proof-summary-stack">
            ${rt.map((N,J)=>i`
              <article class="proof-summary-block ${J===1&&m!=="proven"?Cn(m):""}">
                <strong>${J===0?"지금 결론":J===1?"왜 이렇게 판정됐나":"다음 보강 포인트"}</strong>
                <span>${N}</span>
              </article>
            `)}
          </div>
        <//>

        <${R} title="목표 연결" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 화면이 어떤 세션과 목표를 기준으로 그려졌는지 먼저 고정합니다.</p>
          </div>
          <${yl} rows=${G} />
          <details class="mission-card-disclosure compact">
            <summary>원본 목표 연결 JSON</summary>
            <pre class="command-json-block">${Qn((s==null?void 0:s.goal_binding)??{})}</pre>
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
            ${P.length>0?P.slice(0,18).map(N=>i`<${o$} key=${N.id} item=${N} />`):i`<div class="empty-state">표시할 타임라인 근거가 없습니다.</div>`}
          </div>
        <//>

        <${R} title="참여 흔적" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>실제 흔적, 호출만 된 참여자, 계획만 된 참여자를 구분해서 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${l.length>0?l.map(N=>i`<${r$} key=${N.actor} item=${N} />`):i`<div class="empty-state">표시할 참여 흔적이 없습니다.</div>`}
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
            ${d.length>0?d.map((N,J)=>i`<${e$} key=${`${N.actor??"system"}-${J}`} item=${N} />`):i`<div class="empty-state">기록된 tool evidence가 없습니다.</div>`}
          </div>
        <//>

        <${R} title="실행 근거" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>작전, 분견대, 트레이스 수만 먼저 보고, 원본 CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${yl} rows=${L} />
          <details class="mission-card-disclosure compact">
            <summary>원본 CPv2 backing JSON</summary>
            <pre class="command-json-block">${Qn($??{})}</pre>
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
            ${c.length>0?c.map(N=>i`<${l$} key=${N.path} item=${N} />`):i`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function d$(){const t=fs(w.value);return t?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${Qa(t.action_type)}</span>
        <span class="command-chip">${Qo(t)}</span>
        <span class="command-chip">${ff(w.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?i`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function u$(){const t=Z.value,e=Mg[t],n=zg(t);return i`
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
      <div class="command-gauge-ring" style=${Ag(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round($s(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function Rs({label:t,value:e,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${E(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${E(a)}" style=${`width: ${Math.max(8,Math.round($s(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function p$(){var X,rt,U,I;const t=ys(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary,l=(X=t==null?void 0:t.swarm_status)==null?void 0:X.overview,c=t==null?void 0:t.swarm_proof,d=t==null?void 0:t.operations.microarch,m=(e==null?void 0:e.managed_unit_count)??0,p=(e==null?void 0:e.total_units)??0,v=(n==null?void 0:n.active)??0,f=(s==null?void 0:s.active)??0,$=(l==null?void 0:l.moving_lanes)??0,S=(l==null?void 0:l.active_lanes)??0,y=(c==null?void 0:c.workers.done)??0,k=(c==null?void 0:c.workers.expected)??0,h=(o==null?void 0:o.bad)??0,C=(o==null?void 0:o.warn)??0,M=(a==null?void 0:a.pending)??0,T=(a==null?void 0:a.total)??0,P=v+f,G=((rt=d==null?void 0:d.cache)==null?void 0:rt.l1_hit_rate)??((I=(U=d==null?void 0:d.signals)==null?void 0:U.cache_contention)==null?void 0:I.l1_hit_rate)??0,L=v>0||f>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",V=v>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${L}</h3>
        <p>${V}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${E(v>0?"ok":"warn")}">활성 작전 ${v}</span>
          <span class="command-chip ${E($>0?"ok":(S>0,"warn"))}">이동 레인 ${$}/${Math.max(S,$)}</span>
          <span class="command-chip ${E(h>0?"bad":C>0?"warn":"ok")}">치명 알림 ${h}</span>
          <span class="command-chip ${E(M>0?"warn":"ok")}">승인 대기 ${M}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Is}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(p,m)}`}
          subtext=${p>0?`${p-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${Ce(m,Math.max(p,m))}
          color="#67e8f9"
        />
        <${Is}
          label="실행 열도"
          value=${String(P)}
          subtext=${`${v}개 작전 + ${f}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${Ce(P,Math.max(m,P||1))}
          color="#4ade80"
        />
        <${Is}
          label="스웜 이동감"
          value=${`${$}/${Math.max(S,$)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${tt(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${Ce($,Math.max(S,$||1))}
          color="#fbbf24"
        />
        <${Is}
          label="증거 수집률"
          value=${`${y}/${Math.max(k,y)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${Ce(y,Math.max(k,y||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${Rs}
        label="승인 대기열"
        value=${`${M}건 대기`}
        detail=${`현재 정책 창에서 ${T}개 결정을 추적 중입니다`}
        percent=${Ce(M,Math.max(T,M||1))}
        tone=${M>0?"warn":"ok"}
      />
      <${Rs}
        label="알림 압력"
        value=${`치명 ${h} / 주의 ${C}`}
        detail=${h>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${Ce(h*2+C,Math.max((h+C)*2,1))}
        tone=${h>0?"bad":C>0?"warn":"ok"}
      />
      <${Rs}
        label="디스패치 점유"
          value=${`${f}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${Ce(f,Math.max(m,f||1))}
        tone=${f>0?"ok":"warn"}
      />
      <${Rs}
        label="캐시 신뢰도"
        value=${G?bn(G):"정보 없음"}
        detail=${G?"microarch 캐시 텔레메트리에서 집계한 L1 적중률":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${$s((G??0)*100)}
        tone=${G>=.75?"ok":G>=.4?"warn":"bad"}
      />
    </div>
  `}function m$(){var f,$,S,y,k;const t=ys(),e=vs.value,n=fs(w.value),s=Ng(n),a=t==null?void 0:t.topology.summary,o=t==null?void 0:t.operations.summary,l=(f=t==null?void 0:t.swarm_status)==null?void 0:f.overview,c=t==null?void 0:t.operations.microarch,d=t==null?void 0:t.decisions.summary,m=t==null?void 0:t.alerts.summary,p=($=c==null?void 0:c.signals)==null?void 0:$.issue_pressure,v=c==null?void 0:c.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((S=t==null?void 0:t.detachments.summary)==null?void 0:S.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(d==null?void 0:d.pending)??0}</strong><small>${(d==null?void 0:d.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 주의</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((y=e==null?void 0:e.summary)==null?void 0:y.active_chains)??0}</strong><small>${((k=e==null?void 0:e.summary)==null?void 0:k.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${tt(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(p==null?void 0:p.pending_ops)??0}</strong><small>${(v==null?void 0:v.l1_hit_rate)!=null?`${bn(v.l1_hit_rate)} L1 적중`:"캐시 데이터 없음"} · ${(p==null?void 0:p.tone)??"정보 없음"}</small></div>
    </div>
  `}function _$(){var X,rt,U,I,A,N,J,Q,ot;const t=ys(),e=Gt.value,n=ft.value,s=zd(),a=s?Ht.value.find(W=>W.name===s)??null:null,o=s?ce.value.filter(W=>W.assignee===s&&wg(W)):[],l=((X=t==null?void 0:t.operations.summary)==null?void 0:X.active)??0,c=((rt=t==null?void 0:t.detachments.summary)==null?void 0:rt.total)??0,d=((U=t==null?void 0:t.decisions.summary)==null?void 0:U.pending)??0,m=e==null?void 0:e.detachments.detachments.find(W=>{const Lt=W.detachment.heartbeat_deadline,be=Lt?Date.parse(Lt):Number.NaN;return W.detachment.status==="stalled"||!Number.isNaN(be)&&be<=Date.now()}),p=e==null?void 0:e.alerts.alerts.find(W=>W.severity==="bad"),v=!!(n!=null&&n.room||n!=null&&n.project),f=(a==null?void 0:a.current_task)??null,$=Dg(a==null?void 0:a.last_seen),S=$!=null?$<=120:null,y=[v?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:ce.value.length>0?"masc_claim":"masc_add_task"}:f?S===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${f} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${f}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((I=t.topology.summary)==null?void 0:I.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((A=t.topology.summary)==null?void 0:A.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((N=t.topology.summary)==null?void 0:N.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},d>0?{title:"디스패치 준비도",tone:"warn",detail:`${d}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||p?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${p?` · alert ${p.title??p.alert_id}`:""}${!e&&!m&&!p?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:d>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],k=v?!s||!a?"masc_join":o.length===0?ce.value.length>0?"masc_claim":"masc_add_task":f?S===!1?"masc_heartbeat":!t||(((J=t.topology.summary)==null?void 0:J.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":d>0?"masc_policy_approve":l>0&&c===0||m||p?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",h=Og(k),M=qg(k==="masc_set_room"?["repo-root-room"]:k==="masc_plan_set_task"?["claimed-not-current"]:k==="masc_heartbeat"?["heartbeat-stale"]:k==="masc_dispatch_tick"?["no-detachments"]:k==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),T=$i("room_task_hygiene"),P=$i("cpv2_benchmark"),G=$i("supervisor_session"),L=((Q=_s.value)==null?void 0:Q.docs)??[],V=[T,P,G].filter(W=>W!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${O} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(h==null?void 0:h.title)??k}</strong>
            <span class="command-chip ok">${k}</span>
          </div>
          <p>${(h==null?void 0:h.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(ot=h==null?void 0:h.success_signals)!=null&&ot.length?i`<div class="command-tag-row">
                ${h.success_signals.map(W=>i`<span class="command-tag ok">${W}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${y.map(W=>i`
            <article class="command-readiness-row ${E(W.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${W.title}</strong>
                  <span class="command-chip ${E(W.tone)}">${W.tone}</span>
                </div>
                <p>${W.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${W.tool}</div>
            </article>
          `)}
        </div>

        ${M.length>0?i`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${M.length}</span>
                </div>
                <div class="command-guide-list">
                  ${M.map(W=>i`
                    <article class="command-guide-inline">
                      <strong>${W.title}</strong>
                      <div>${W.symptom}</div>
                      <div class="command-card-sub">${W.fix_tool} 로 해결: ${W.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `:null}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">운영 경로</div>
          <${O} panelId="command.summary" compact=${!0} />
        </div>
        ${co.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:ka.value?i`<div class="empty-state error">${ka.value}</div>`:i`
                <div class="command-path-grid">
                  ${V.map(W=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${W.title}</strong>
                        <span class="command-chip">${W.id}</span>
                      </div>
                      <p>${W.summary}</p>
                      <div class="command-card-sub">${W.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${W.steps.slice(0,4).map(Lt=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Lt.tool}</span>
                            <span>${Lt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${L.length>0?i`<div class="command-doc-links">
                      ${L.map(W=>i`<span class="command-tag">${W.title}: ${W.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function v$(){return i`
    <${p$} />
    <${m$} />
    <${_$} />
  `}function f$(){return $a.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:ya.value?i`<div class="empty-state error">${ya.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}const Ae=g(null),Ms=g("compact"),ie=g({zoom:1,panX:0,panY:0}),hi=g(!1),Es=g(!1),Mn={width:1280,height:760},Dd=.42,wd=1.9;function Qs(t,e,n){return Math.max(e,Math.min(n,t))}function ar(t,e){const n=t==null?void 0:t.trim();return n?n.length<=e?n:`${n.slice(0,Math.max(1,e-1))}…`:null}function g$(t){return t==="compact"?"집약":"균형"}function bl(t){switch((t??"").trim().toLowerCase()){case"room":return"룸";case"session":return"세션";case"operation":return"작전";case"detachment":return"분견대";case"lane":return"레인";case"worker":return"워커";case"keeper":return"키퍼";default:return(t==null?void 0:t.trim())||"노드"}}function Ls(t,e,n){if(t<=0)return[];if(t===1)return[Math.round((e+n)/2)];const s=(n-e)/(t-1);return Array.from({length:t},(a,o)=>Math.round(e+o*s))}function $$(t,e){const n=new Map;for(const s of t){const a=e(s),o=n.get(a)??[];o.push(s),n.set(a,o)}return n}function Od(t){return t==="compact"?{room:{x:660,y:108},sessions:{y:228,min:220,max:1110},operations:{y:338,min:260,max:1050},detachments:{y:430,min:310,max:1e3},lanes:{y:540,min:220,max:1110},worker:{perRow:5,xSpacing:60,ySpacing:52,laneOffsetY:76,freeBaseY:662},keeper:{startX:1180,colSpacing:92,rowSpacing:90,startY:176,columns:2},signalRadius:116}:{room:{x:700,y:112},sessions:{y:236,min:240,max:1140},operations:{y:356,min:300,max:1080},detachments:{y:454,min:340,max:1030},lanes:{y:584,min:230,max:1110},worker:{perRow:4,xSpacing:72,ySpacing:60,laneOffsetY:82,freeBaseY:720},keeper:{startX:1210,colSpacing:108,rowSpacing:102,startY:188,columns:2},signalRadius:132}}function qd(t,e){return t.kind==="room"?e==="compact"?{width:138,height:138,radius:68}:{width:156,height:156,radius:76}:t.kind==="worker"?e==="compact"?{width:70,height:36,radius:18}:{width:84,height:44,radius:22}:t.kind==="lane"?e==="compact"?{width:156,height:48,radius:15}:{width:176,height:56,radius:17}:t.kind==="keeper"?e==="compact"?{width:118,height:50,radius:22}:{width:132,height:60,radius:24}:t.kind==="session"?e==="compact"?{width:182,height:58,radius:17}:{width:202,height:68,radius:18}:e==="compact"?{width:176,height:58,radius:16}:{width:196,height:68,radius:18}}function h$(t,e){const n=t.kind==="worker"?e==="compact"?10:14:t.kind==="keeper"?e==="compact"?12:16:t.kind==="lane"?e==="compact"?16:22:e==="compact"?18:26;return ar(t.label,n)??t.label}function y$(t,e){if(e==="compact"&&(t.kind==="worker"||t.kind==="keeper"||t.kind==="detachment"))return null;const n=t.kind==="session"?e==="compact"?20:28:e==="compact"?14:24;return ar(t.subtitle,n)}function b$(t,e){return e==="compact"&&t.kind!=="session"&&t.kind!=="operation"?null:ar(t.status,e==="compact"?10:14)}function k$(t,e){const n=Od(e),s=new Map,a=t.nodes,o=a.find(y=>y.kind==="room")??null,l=a.filter(y=>y.kind==="session"),c=a.filter(y=>y.kind==="operation"),d=a.filter(y=>y.kind==="detachment"),m=a.filter(y=>y.kind==="lane"),p=a.filter(y=>y.kind==="worker"),v=a.filter(y=>y.kind==="keeper");o&&s.set(o.id,{x:n.room.x,y:n.room.y}),Ls(l.length,n.sessions.min,n.sessions.max).forEach((y,k)=>{const h=l[k];h&&s.set(h.id,{x:y,y:n.sessions.y})}),Ls(c.length,n.operations.min,n.operations.max).forEach((y,k)=>{const h=c[k];h&&s.set(h.id,{x:y,y:n.operations.y})}),Ls(d.length,n.detachments.min,n.detachments.max).forEach((y,k)=>{const h=d[k];h&&s.set(h.id,{x:y,y:n.detachments.y})}),Ls(m.length,n.lanes.min,n.lanes.max).forEach((y,k)=>{const h=m[k];h&&s.set(h.id,{x:y,y:n.lanes.y})});const f=new Map(m.map(y=>{const k=s.get(y.id);return k?[y.id,k.x]:null}).filter(y=>y!==null)),$=$$(p,y=>y.lane_id?`lane:${y.lane_id}`:y.parent_id?y.parent_id:"free");let S=0;for(const[y,k]of $){let h=f.get(y.replace(/^lane:/,""));if(h==null){const M=s.get(y);h=M==null?void 0:M.x}h==null&&(h=260+S%4*180,S+=1);const C=Math.max(1,Math.ceil(k.length/n.worker.perRow));for(let M=0;M<C;M+=1){const T=k.slice(M*n.worker.perRow,(M+1)*n.worker.perRow),P=(T.length-1)*n.worker.xSpacing,G=h-P/2;T.forEach((L,V)=>{var X;s.set(L.id,{x:Math.round(G+V*n.worker.xSpacing),y:y==="free"?n.worker.freeBaseY+M*n.worker.ySpacing:(((X=s.get(y.replace(/^lane:/,"")))==null?void 0:X.y)??n.lanes.y)+n.worker.laneOffsetY+M*n.worker.ySpacing})})}}return v.forEach((y,k)=>{const h=k%n.keeper.columns,C=Math.floor(k/n.keeper.columns);s.set(y.id,{x:n.keeper.startX+h*n.keeper.colSpacing,y:n.keeper.startY+C*n.keeper.rowSpacing})}),s}function x$(t,e,n){if(!e||t.signals.length===0)return[];const s=Od(n);return t.signals.slice(0,6).map((a,o)=>{const l=(-130+o*36)*(Math.PI/180);return{signalNode:a,x:Math.round(e.x+Math.cos(l)*s.signalRadius),y:Math.round(e.y+Math.sin(l)*s.signalRadius)}})}function S$(t,e,n,s){let a=Number.POSITIVE_INFINITY,o=Number.NEGATIVE_INFINITY,l=Number.POSITIVE_INFINITY,c=Number.NEGATIVE_INFINITY;for(const d of t.nodes){const m=e.get(d.id);if(!m)continue;const p=qd(d,s);d.kind==="room"?(a=Math.min(a,m.x-p.radius),o=Math.max(o,m.x+p.radius),l=Math.min(l,m.y-p.radius),c=Math.max(c,m.y+p.radius)):(a=Math.min(a,m.x-p.width/2),o=Math.max(o,m.x+p.width/2),l=Math.min(l,m.y-p.height/2),c=Math.max(c,m.y+p.height/2))}for(const d of n)a=Math.min(a,d.x-20),o=Math.max(o,d.x+20),l=Math.min(l,d.y-20),c=Math.max(c,d.y+20);return!Number.isFinite(a)||!Number.isFinite(o)||!Number.isFinite(l)||!Number.isFinite(c)?{minX:0,minY:0,maxX:Mn.width,maxY:Mn.height,width:Mn.width,height:Mn.height}:{minX:a,minY:l,maxX:o,maxY:c,width:Math.max(1,o-a),height:Math.max(1,c-l)}}function kl(t,e,n){const s=n==="compact"?48:72,a=Math.max(360,e.width-s*2),o=Math.max(280,e.height-s*2),l=Qs(Math.min(a/Math.max(t.width,1),o/Math.max(t.height,1)),Dd,wd),c=t.minX+t.width/2,d=t.minY+t.height/2;return{zoom:l,panX:e.width/2-c*l,panY:e.height/2-d*l}}function C$(t,e){const n=(t.x+e.x)/2,s=e.y>=t.y?32:-32;return`M ${t.x} ${t.y} C ${n} ${t.y+s}, ${n} ${e.y-s}, ${e.x} ${e.y}`}function xl(t,e,n){if(t==="command"){if(e){qt(e),it("command",{...hs(e),...n});return}it("command",n);return}if(t==="intervene"){it("intervene",n);return}it("command",n)}function A$({signalNodes:t,roomPoint:e,onSelect:n}){return!e||t.length===0?null:i`
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
  `}function T$({edges:t,positions:e,selectedId:n}){return i`
    ${t.map(s=>{const a=e.get(s.source),o=e.get(s.target);if(!a||!o)return null;const l=n!=null&&(s.source===n||s.target===n);return i`
        <path
          key=${s.id}
          d=${C$(a,o)}
          class=${`orchestra-edge ${E(s.tone)} ${s.animated?"animated":""} ${l?"active":""}`}
        />
      `})}
  `}function I$({orchestra:t,positions:e,density:n,selectedId:s,onSelect:a}){var l;const o=((l=t.focus)==null?void 0:l.target_kind)==="node"?t.focus.target_id:null;return i`
    ${t.nodes.map(c=>{const d=e.get(c.id);if(!d)return null;const m=qd(c,n),p=c.id===s,v=c.id===o,f=c.visual_class??c.kind,$=h$(c,n),S=y$(c,n),y=b$(c,n);if(c.kind==="room")return i`
          <g
            key=${c.id}
            data-orchestra-node="true"
            class=${`orchestra-node room ${E(c.tone)} ${p?"selected":""} ${v?"focused":""}`}
            onClick=${()=>a(c.id)}
          >
            <title>${c.label}</title>
            <circle cx=${d.x} cy=${d.y} r=${m.radius} class="orchestra-room-ring outer" />
            <circle cx=${d.x} cy=${d.y} r=${m.radius-16} class="orchestra-room-ring inner" />
            <text x=${d.x} y=${d.y-10} text-anchor="middle" class="orchestra-room-glyph">${c.glyph??"◎"}</text>
            <text x=${d.x} y=${d.y+22} text-anchor="middle" class="orchestra-room-label">${$}</text>
          </g>
        `;const k=d.x-m.width/2,h=d.y-m.height/2;return i`
        <g
          key=${c.id}
          data-orchestra-node="true"
          class=${`orchestra-node ${f} ${E(c.tone)} ${p?"selected":""} ${v?"focused":""}`}
          onClick=${()=>a(c.id)}
        >
          <title>${c.label}${c.subtitle?` — ${c.subtitle}`:""}${c.status?` (${c.status})`:""}</title>
          <rect x=${k} y=${h} width=${m.width} height=${m.height} rx=${m.radius} class="orchestra-node-body" />
          <text x=${k+16} y=${h+24} class="orchestra-node-glyph">${c.glyph??"•"}</text>
          <text x=${k+38} y=${h+24} class="orchestra-node-label">${$}</text>
          ${S?i`<text x=${k+38} y=${h+42} class="orchestra-node-subtitle">${S}</text>`:null}
          ${y?i`<text x=${k+m.width-10} y=${h+18} text-anchor="end" class="orchestra-node-status">${y}</text>`:null}
        </g>
      `})}
  `}function Fd(t){var s,a;const e=Ae.value;if(e){const o=t.nodes.find(c=>c.id===e);if(o)return{type:"node",value:o};const l=t.signals.find(c=>c.id===e);if(l)return{type:"signal",value:l}}if(((s=t.focus)==null?void 0:s.target_kind)==="node"){const o=t.nodes.find(l=>{var c;return l.id===((c=t.focus)==null?void 0:c.target_id)});if(o)return{type:"node",value:o}}if(((a=t.focus)==null?void 0:a.target_kind)==="signal"){const o=t.signals.find(l=>{var c;return l.id===((c=t.focus)==null?void 0:c.target_id)});if(o)return{type:"signal",value:o}}const n=t.nodes[0];return n?{type:"node",value:n}:null}function R$({orchestra:t}){const e=Fd(t);if(!e)return i`<aside class="orchestra-drawer card"><div class="empty-state">선택 가능한 대상이 아직 없습니다.</div></aside>`;if(e.type==="signal"){const o=e.value;return i`
      <aside class="orchestra-drawer card ${E(o.tone)}">
        <div class="card-title-row">
          <div class="card-title">${o.label}</div>
          <span class="command-chip ${E(o.tone)}">${bl(o.kind)}</span>
        </div>
        <p>${o.detail??"세부 설명이 없습니다."}</p>
        ${o.suggested_surface?i`
              <div class="command-action-row">
                <button
                  class="control-btn"
                  onClick=${()=>xl("command",o.suggested_surface,o.suggested_params??{})}
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
        <span class="command-chip ${E(n.tone)}">${bl(n.kind)}</span>
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
                onClick=${()=>xl(n.link_tab??"command",n.link_surface,n.link_params??{})}
              >
                이 화면 열기
              </button>
            </div>
          `:null}
    </aside>
  `}function M$(){var V,X,rt,U;const t=Uo.value,e=En(null),n=En(null),s=En(""),[a,o]=pn(Mn);if(st(()=>{const I=e.current;if(!I)return;const A=()=>{const J=I.getBoundingClientRect();J.width<=0||J.height<=0||o({width:Math.max(640,Math.round(J.width)),height:Math.max(480,Math.round(J.height))})};if(A(),typeof ResizeObserver>"u")return window.addEventListener("resize",A),()=>window.removeEventListener("resize",A);const N=new ResizeObserver(()=>A());return N.observe(I),()=>N.disconnect()},[]),uo.value&&!t)return i`<section class="card command-section"><div class="empty-state">오케스트라 맵 불러오는 중…</div></section>`;if(Ca.value)return i`<section class="card command-section"><div class="empty-state error">${Ca.value}</div></section>`;if(!t)return i`<section class="card command-section"><div class="empty-state">오케스트라 맵 데이터가 아직 없습니다.</div></section>`;const l=Ms.value,c=k$(t,l),d=t.nodes.find(I=>I.kind==="room")??null,m=d?c.get(d.id)??null:null,p=x$(t,m,l),v=S$(t,c,p,l),f=Fd(t),$=(f==null?void 0:f.value.id)??null,S=`${l}:${a.width}x${a.height}:${t.nodes.length}:${t.edges.length}:${t.signals.length}`,y=(I,A)=>{ie.value=I,Es.value=A},k=()=>{y(kl(v,a,l),!1)},h=()=>{if(Ae.value=null,l!=="compact"){Ms.value="compact",Es.value=!1;return}k()};st(()=>{$&&!t.nodes.some(I=>I.id===$)&&!t.signals.some(I=>I.id===$)&&(Ae.value=null)},[S,$,t]),st(()=>{(!Es.value||s.current!==S)&&(y(kl(v,a,l),!1),s.current=S)},[S]);const C=ie.value,M=(I,A,N)=>{const J=ie.value.zoom,Q=Qs(J*N,Dd,wd);if(Math.abs(Q-J)<.001)return;const ot=(I-ie.value.panX)/J,W=(A-ie.value.panY)/J;y({zoom:Q,panX:I-ot*Q,panY:A-W*Q},!0)},T=I=>{I.preventDefault();const A=e.current;if(!A)return;const N=A.getBoundingClientRect(),J=Qs(I.clientX-N.left,0,N.width),Q=Qs(I.clientY-N.top,0,N.height);M(J,Q,I.deltaY<0?1.1:.92)},P=I=>{var J;const A=I.target;if(!(A instanceof Element)||!A.closest('[data-orchestra-background="true"]'))return;const N=I.currentTarget;N&&(n.current={pointerId:I.pointerId,startX:I.clientX,startY:I.clientY,panX:ie.value.panX,panY:ie.value.panY},hi.value=!0,Es.value=!0,(J=N.setPointerCapture)==null||J.call(N,I.pointerId))},G=I=>{const A=n.current;!A||A.pointerId!==I.pointerId||y({zoom:ie.value.zoom,panX:A.panX+(I.clientX-A.startX),panY:A.panY+(I.clientY-A.startY)},!0)},L=I=>{var N;if(!n.current)return;const A=I==null?void 0:I.currentTarget;A&&I&&((N=A.releasePointerCapture)==null||N.call(A,I.pointerId)),n.current=null,hi.value=!1};return i`
    <section class="card command-section orchestra-surface">
      <div class="card-title-row">
        <div class="card-title">오케스트라 맵</div>
        <${O} panelId="command.orchestra" compact=${!0} />
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
            onClick=${()=>M(a.width/2,a.height/2,1.12)}
          >
            확대
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>M(a.width/2,a.height/2,.9)}
          >
            축소
          </button>
          <span class="command-chip">${Math.round(C.zoom*100)}%</span>
        </div>
        <div class="orchestra-toolbar-group">
          <button
            class=${`control-btn ${l==="balanced"?"is-active":"ghost"}`}
            onClick=${()=>{Ms.value="balanced",Ae.value=$}}
          >
            균형
          </button>
          <button
            class=${`control-btn ${l==="compact"?"is-active":"ghost"}`}
            onClick=${()=>{Ms.value="compact",Ae.value=$}}
          >
            집약
          </button>
          <span class="command-chip">${g$(l)}</span>
        </div>
      </div>

      <div class="orchestra-shell">
        <div
          ref=${e}
          class="orchestra-canvas-wrap"
          onWheel=${T}
          onPointerDown=${P}
          onPointerMove=${G}
          onPointerUp=${L}
          onPointerCancel=${L}
          onPointerLeave=${()=>L()}
        >
          <svg
            class=${`orchestra-canvas ${hi.value?"is-dragging":""}`}
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
            <g transform=${`translate(${C.panX} ${C.panY}) scale(${C.zoom})`}>
              <${T$} edges=${t.edges} positions=${c} selectedId=${$} />
              <${A$} signalNodes=${p} roomPoint=${m} onSelect=${I=>{Ae.value=I}} />
              <${I$}
                orchestra=${t}
                positions=${c}
                density=${l}
                selectedId=${$}
                onSelect=${I=>{Ae.value=I}}
              />
            </g>
          </svg>
          <div class="orchestra-summary-strip">
            <span class="command-chip">세션 ${((V=t.summary)==null?void 0:V.session_count)??0}</span>
            <span class="command-chip">워커 ${((X=t.summary)==null?void 0:X.worker_count)??0}</span>
            <span class="command-chip">키퍼 ${((rt=t.summary)==null?void 0:rt.keeper_count)??0}</span>
            <span class="command-chip ${E(t.signals.some(I=>I.tone==="bad")?"bad":t.signals.length>0?"warn":"ok")}">
              신호 ${((U=t.summary)==null?void 0:U.signal_count)??t.signals.length}
            </span>
            <span class="command-chip">갱신 ${tt(t.generated_at)}</span>
          </div>
        </div>

        <${R$} orchestra=${t} />
      </div>
    </section>
  `}const Bd="masc_dashboard_agent_name";function E$(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Bd))==null?void 0:s.trim())||"dashboard"}const ei=g(E$()),cn=g(""),La=g("운영 점검"),dn=g(""),Zn=g(""),ts=g("2"),_n=g(""),kt=g("note"),es=g(""),ns=g(""),ss=g(""),as=g("2"),is=g(""),Pa=g("운영자 중지 요청"),fo=g(""),L$=g(""),Ps=g(null);function P$(t){const e=t.trim()||"dashboard";ei.value=e,localStorage.setItem(Bd,e)}function za(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function ir(t){switch((t??"").trim().toLowerCase()){case"judgment":return"상주 판단";case"fallback":return"보조 읽기 모델";default:return(t==null?void 0:t.trim())||"안내"}}function Na(t){switch((t??"").trim().toLowerCase()){case"judgment":return"ok";case"fallback":return"warn";default:return"warn"}}function ni(t){return t!=null&&t.enabled?t.refreshing?"갱신 중":t.judge_online?"온라인":t.last_error?"오류":"대기":"꺼짐"}function Kd(t){return t!=null&&t.enabled?t.judge_online?"ok":t.refreshing?"warn":"bad":"warn"}function or(t){return t!=null&&t.fresh_until?t.fresh_until:"갱신 기준 없음"}function Sl(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function vn(t){return typeof t=="string"?t.trim().toLowerCase():""}function z$(t){var s;const e=vn(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=vn((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function yi(t){const e=vn(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function Cl(t){return t.some(e=>vn(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function N$(t){return t.target_type==="team_session"}function j$(t){return t.target_type==="keeper"}function De(t){switch(t){case"broadcast":return"방송";case"room_pause":return"방 일시정지";case"room_resume":return"방 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"team_worker_spawn_batch":return"세션 작업자 교체";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"키퍼 메시지";case"keeper_msg":return"키퍼 메시지";case"swarm_run_continue":return"스웜 실행 계속";case"swarm_run_rerun":return"스웜 실행 재실행";case"swarm_run_abandon":return"스웜 실행 포기";default:return(t==null?void 0:t.trim())||"액션"}}function un(t){switch(t){case"room":return"방";case"team_session":return"세션";case"keeper":return"키퍼";case"swarm_run":return"스웜 실행";default:return(t==null?void 0:t.trim())||"대상"}}function Xe(t){switch(vn(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function ja(t){return t?"확인 후 실행":"즉시 실행"}function D$(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"worker_spawn_batch":return"작업자 교체";default:return t}}function _t(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function w$(t){return!t||typeof t!="object"||Array.isArray(t)?null:t}function O$(t){if(!t)return"";const e=t.spawn_batch;return za(e!==void 0?e:t)}function Ud(t){const e=w$(t.payload);if(t.target_type==="room"){if(t.action_type==="broadcast"){cn.value=_t(e,"message")??t.summary;return}if(t.action_type==="task_inject"){dn.value=_t(e,"title")??"운영자 주입 작업",Zn.value=_t(e,"description")??t.summary,ts.value=_t(e,"priority")??ts.value;return}t.action_type==="room_pause"&&(La.value=_t(e,"reason")??t.summary);return}if(t.target_type==="team_session"){if(t.target_id&&(_n.value=t.target_id),t.action_type==="team_stop"){Pa.value=_t(e,"reason")??t.summary;return}kt.value=t.action_type==="team_worker_spawn_batch"?"worker_spawn_batch":t.action_type==="team_task_inject"?"task":t.action_type==="team_broadcast"?"broadcast":"note";const n=_t(e,"message");if(n&&(es.value=n),kt.value==="worker_spawn_batch"){is.value=O$(e);return}kt.value==="task"&&(ns.value=_t(e,"task_title")??_t(e,"title")??"운영자 주입 작업",ss.value=_t(e,"task_description")??_t(e,"description")??t.summary,as.value=_t(e,"task_priority")??_t(e,"priority")??as.value);return}t.target_type==="keeper"&&(t.target_id&&(fo.value=t.target_id),L$.value=_t(e,"message")??t.summary)}function q$(t){Ud({action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.suggested_payload,summary:t.summary})}function F$(t){Ud({action_type:t.action_type,target_type:t.target_type,target_id:t.target_id??null,payload:t.suggested_payload,summary:t.reason}),j("추천 액션 payload를 폼에 채웠습니다","success")}function B$(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function qe(t){const e=ei.value.trim()||"dashboard";try{const n=await qc({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?j("확인 대기열에 올렸습니다","warning"):j(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return j(s,"error"),null}}async function Al(){const t=cn.value.trim();if(!t)return;await qe({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(cn.value="")}async function K$(){await qe({action_type:"room_pause",target_type:"room",payload:{reason:La.value.trim()||"운영 점검"},successMessage:"방 일시정지를 요청했습니다"})}async function Wd(){await qe({action_type:"room_resume",target_type:"room",payload:{},successMessage:"방 재개를 요청했습니다"})}async function U$(){const t=dn.value.trim();if(!t)return;await qe({action_type:"task_inject",target_type:"room",payload:{title:t,description:Zn.value.trim()||"개입 화면에서 주입",priority:Number.parseInt(ts.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(dn.value="",Zn.value="")}async function W$(){var l;const t=Et.value,e=_n.value||((l=t==null?void 0:t.sessions[0])==null?void 0:l.session_id)||"";if(!e){j("먼저 세션을 고르세요","warning");return}const n={};if(kt.value==="worker_spawn_batch"){const c=is.value.trim();if(!c){j("spawn_batch JSON을 먼저 채우세요","warning");return}try{const m=JSON.parse(c);if(Array.isArray(m))n.spawn_batch=m;else if(m&&typeof m=="object"&&Array.isArray(m.spawn_batch))n.spawn_batch=m.spawn_batch;else{j("spawn_batch는 배열 또는 { spawn_batch: [...] } 형태여야 합니다","warning");return}}catch(m){const p=m instanceof Error?m.message:"spawn_batch JSON 파싱에 실패했습니다";j(p,"error");return}await qe({action_type:"team_worker_spawn_batch",target_type:"team_session",target_id:e,payload:n,successMessage:"작업자 교체 요청을 적용했습니다"})&&(is.value="");return}const s=es.value.trim();s&&(n.message=s);let a="team_note";kt.value==="broadcast"?a="team_broadcast":kt.value==="task"&&(a="team_task_inject"),kt.value==="task"&&(n.task_title=ns.value.trim()||"운영자 주입 작업",n.task_description=ss.value.trim()||"개입 화면에서 주입",n.task_priority=Number.parseInt(as.value,10)||2),await qe({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(es.value="",kt.value==="task"&&(ns.value="",ss.value=""))}async function H$(){var n;const t=Et.value,e=_n.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){j("먼저 세션을 고르세요","warning");return}await qe({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Pa.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Tl(t,e="confirm"){const n=ei.value.trim()||"dashboard";try{await Fc(n,t,e),j(e==="deny"?"승인 대기를 거부했습니다":"확인 실행을 완료했습니다","success")}catch(s){const a=s instanceof Error?s.message:e==="deny"?"승인 대기 거부에 실패했습니다":"확인 실행에 실패했습니다";j(a,"error")}}function Hd(t){switch(t){case"explicit":return"실제 관리 단위";case"hybrid":return"관리 단위 + 자동 보강";case"auto":return"자동 투영";default:return"출처 미상"}}function Gd(t){switch(t){case"explicit":return"ok";case"hybrid":return"warn";case"auto":return"warn";default:return"warn"}}function G$(t){switch(t){case"explicit":return"지금 보이는 유닛은 실제로 정의된 지휘면 관리 단위입니다.";case"hybrid":return"일부는 실제 관리 단위이고, 비어 있는 부분은 실시간 에이전트 편성을 보고 자동 보강한 구조입니다.";case"auto":return"이 화면은 실시간 에이전트 편성을 지휘면 모양으로 자동 투영한 것입니다. 실제 명령 체계와 1:1로 같다고 보면 안 됩니다.";default:return"이 화면은 관리 토폴로지와 실효 토폴로지가 섞여 있을 수 있습니다."}}function J$(t){const e=t.unit.source??"unknown";return e==="explicit"?t.active_operation_count&&t.active_operation_count>0?"실제 관리 단위이며 연결된 작전이 있습니다.":"실제 관리 단위이지만 현재 연결된 작전은 없습니다.":e==="hybrid"?t.active_operation_count&&t.active_operation_count>0?"관리 단위를 기반으로 자동 보강된 구조이며 일부 작전이 연결돼 있습니다.":"관리 단위를 기반으로 자동 보강된 구조이며 현재 실행 연결은 약합니다.":t.active_operation_count&&t.active_operation_count>0?"자동 생성된 구조이지만 이 노드에 연결된 작전 흔적은 있습니다.":"자동 생성된 구조이며 현재 실행 연결은 없습니다."}function Jd({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,o=t.unit.policy,l=t.unit.source??"unknown",c=a>0?`${a}개 작전 연결`:"실행 연결 없음";return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${Pg(t.unit.kind)}</span>
            <span class="command-chip ${E(t.health)}">${t.health??"ok"}</span>
            <span class="command-chip ${Gd(l)}">${Hd(l)}</span>
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
          <div class="command-card-sub">${J$(t)}</div>
          ${t.reasons&&t.reasons.length>0?i`<div class="command-tag-row">
                ${t.reasons.map(d=>i`<span class="command-tag warn">${d}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?i`<div class="command-tree-children">
            ${t.children.map(d=>i`<${Jd} node=${d} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Y$({alert:t}){return i`
    <article class="command-alert ${E(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${E(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"범위"}:${t.scope_id??"정보 없음"}</span>
        <span>${tt(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function rr({event:t}){return i`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${tt(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${Qn(t.detail)}</pre>
    </article>
  `}function V$(){const t=Gt.value,e=t==null?void 0:t.topology,n=e==null?void 0:e.source,s=e==null?void 0:e.summary,a=(s==null?void 0:s.managed_unit_count)??0,o=(s==null?void 0:s.active_operation_count)??0;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${O} panelId="command.topology" compact=${!0} />
      </div>
      ${t?i`
            <div class="command-topology-explainer">
              <div class="command-tree-title-row">
                <span class="command-chip ${Gd(n)}">${Hd(n)}</span>
                <span class="command-chip">관리 유닛 ${a}</span>
                <span class="command-chip ${o>0?"ok":"warn"}">활성 작전 ${o}</span>
              </div>
              <p>${G$(n)}</p>
            </div>
          `:null}
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(l=>i`<${Jd} node=${l} />`)}`:i`<div class="empty-state">지금은 실시간 에이전트나 관리 유닛 기준으로 그릴 지휘 계층이 없습니다.</div>`}
    </section>
  `}function X$(){const t=Gt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${O} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${Y$} alert=${e} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 지휘면 경보는 없습니다.</div>`}
    </section>
  `}function Q$(){const t=Gt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${O} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${rr} event=${e} />`)}
          </div>`:i`<div class="empty-state">최근 트레이스 이벤트가 없습니다.</div>`}
    </section>
  `}function Z$(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t,null,2)}catch{return String(t)}}function th(t,e){return(e==null?void 0:e.status)==="abandoned"||(t==null?void 0:t.recommended_kind)==="continue"?"warn":(t==null?void 0:t.recommended_kind)==="rerun"?"bad":"ok"}function eh(t){switch(t){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(t==null?void 0:t.trim())||"결정"}}function nh(t){return t?t.runtime_blocker?"막힘":t.provider_reachable?"준비됨":"확인 필요":"확인 필요"}function Yd({swarm:t}){var v,f;const e=t.run_id,n=t.resolution_recommendation,s=t.run_resolution;if(!e||!n&&!s)return null;const a=zd()??"dashboard",o=((v=Et.value)==null?void 0:v.pending_confirms.find($=>$.target_type==="swarm_run"&&$.target_id===e))??null,l=th(n,s),c=((f=t.operation)==null?void 0:f.operation_id)??t.operation_id??void 0,d={run_id:e};c&&(d.operation_id=c),n!=null&&n.reason&&(d.reason=n.reason);const m=async $=>{await qc({actor:a,action_type:$,target_type:"swarm_run",target_id:e,payload:d})},p=async $=>{o&&await Fc(a,o.confirm_token,$)};return i`
    <article class="command-guide-card ${E(l)}">
      <div class="command-guide-head">
        <strong>런 해석</strong>
        <span class="command-chip ${E(l)}">
          ${eh((s==null?void 0:s.status)??(n==null?void 0:n.recommended_kind)??null)}
        </span>
      </div>
      <p>
        ${(s==null?void 0:s.status)==="abandoned"?`이 run은 ${s.decided_by}가 ${tt(s.decided_at)}에 soft abandon 처리했습니다. ${s.reason}`:(n==null?void 0:n.reason)??"이 run에 대한 별도 resolution recommendation은 아직 없습니다."}
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
              ${n.evidence.runtime_blocker?i`<span class="command-tag ${E("bad")}">${n.evidence.runtime_blocker}</span>`:null}
            </div>
          `:null}
      ${o?i`
            <div class="command-guide-card warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip warn">${o.confirm_token}</span>
              </div>
              ${o.preview?i`<pre class="command-trace-detail">${Z$(o.preview)}</pre>`:null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${()=>{p("confirm")}} disabled=${nt.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${()=>{p("deny")}} disabled=${nt.value}>취소</button>
              </div>
            </div>
          `:n?i`
              <div class="command-action-row">
                ${n.continue_available?i`<button class="control-btn ghost" onClick=${()=>{m("swarm_run_continue")}} disabled=${nt.value}>계속</button>`:null}
                ${n.rerun_available?i`<button class="control-btn" onClick=${()=>{m("swarm_run_rerun")}} disabled=${nt.value}>재실행</button>`:null}
                ${n.abandon_available?i`<button class="control-btn ghost" onClick=${()=>{m("swarm_run_abandon")}} disabled=${nt.value}>포기</button>`:null}
              </div>
            `:null}
    </article>
  `}function Vd(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function Xd({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const o=a.motion_state;o in e?e[o]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return i`
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
  `}function sh({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function ah({lane:t}){const e=t.counts??{},n=Vd(t),s=e.workers??0,a=e.operations??0,o=e.detachments??0,l=a+o,c=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return i`
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
          <span class="command-chip">${tt(t.last_movement_at)}</span>
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
                <${sh} total=${s} />
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
              ${t.hard_flags.map(d=>i`<span class="command-chip ${E(d.severity)}">${d.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Qd({lanes:t}){const e=t.slice(0,4);return e.length===0?null:i`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=Vd(n),a=n.counts.workers??0,o=n.counts.operations??0,l=n.counts.detachments??0;return i`
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
  `}function ih({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${E(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?i`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function oh({gap:t}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.summary}</strong>
          <div class="command-card-sub">${t.code} · lane ${t.lane_ids.join(", ")||"n/a"}</div>
        </div>
        <span class="command-chip ${E(t.severity)}">${t.count}</span>
      </div>
      ${t.why_it_matters?i`<p>${t.why_it_matters}</p>`:null}
      ${t.next_tool||t.next_step?i`
            <div class="command-card-grid">
              <span>다음 도구</span><span>${t.next_tool??"masc_observe_traces"}</span>
              <span>다음 확인</span><span>${t.next_step??"최근 trace를 확인합니다."}</span>
            </div>
          `:null}
    </article>
  `}function rh({swarm:t}){const e=t==null?void 0:t.narrative;return e?i`
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
  `:null}function lh({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${E(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${E(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?i`
            <p>${t.status_summary??t.missing_reason??"아직 스웜 증거가 수집되지 않았습니다."}</p>
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>상태 코드</span><span>${t.reason_code??"n/a"}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${tt(t.captured_at)}</span>
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
  `}function ch(){const t=ys(),e=fs(w.value),n=jg(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,o=(s==null?void 0:s.lanes.filter(v=>v.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],d=s==null?void 0:s.overview,m=s==null?void 0:s.recommended_next_action,p=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${O} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${Qd} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(d==null?void 0:d.active_lanes)??0}</strong><small>${(d==null?void 0:d.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(d==null?void 0:d.stalled_lanes)??0}</strong><small>${(d==null?void 0:d.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${tt(d==null?void 0:d.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${tt(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${Xd} lanes=${o} />`:null}

            <div class="command-swarm-layout ${p?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(v=>i`<${ah} lane=${v} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <${rh} swarm=${s} />

                <div class="command-guide-card highlight ${n==="recommendation"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(m==null?void 0:m.lane_id)??"전체"}</span>
                  </div>
                  <p>${(m==null?void 0:m.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${lh} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${E(l.some(v=>v.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?i`<div class="command-card-stack">${l.slice(0,4).map(v=>i`<${oh} gap=${v} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?i`<div class="swarm-event-rail">${c.map(v=>i`<${ih} event=${v} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function dh({item:t}){return i`
    <article class="command-guide-card ${E(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${E(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Zd({blocker:t}){return i`
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
  `}function uh({worker:t}){return i`
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
      ${t.last_message?i`<div class="command-card-foot">${tt(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function ph(){var p,v,f,$,S,y,k,h,C,M,T,P,G,L,V,X,rt,U,I,A,N,J;const t=Be.value,e=jd(),n=nr(),s=nh(t==null?void 0:t.provider),a=((p=t==null?void 0:t.provider)==null?void 0:p.configured_capacity)??0,o=((v=t==null?void 0:t.provider)==null?void 0:v.actual_slots)??((f=t==null?void 0:t.provider)==null?void 0:f.total_slots)??0,l=(($=t==null?void 0:t.provider)==null?void 0:$.expected_slots)??"n/a",c=((S=t==null?void 0:t.provider)==null?void 0:S.actual_ctx)??((y=t==null?void 0:t.provider)==null?void 0:y.ctx_per_slot)??0,d=((k=t==null?void 0:t.provider)==null?void 0:k.expected_ctx)??"n/a",m=((h=t==null?void 0:t.summary)==null?void 0:h.peak_hot_slots)??((C=t==null?void 0:t.provider)==null?void 0:C.peak_active_slots)??0;return i`
    <div class="command-section-stack">
      <${ch} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${xa.value?i`<div class="empty-state">Loading swarm live state…</div>`:Sa.value?i`<div class="empty-state error">${Sa.value}</div>`:t?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((M=t.summary)==null?void 0:M.joined_workers)??0}/${((T=t.summary)==null?void 0:T.expected_workers)??0}</strong><small>${((P=t.summary)==null?void 0:P.live_workers)??0}개 가동 · ${((G=t.summary)==null?void 0:G.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임 계약</span><strong>${s}</strong><small>설정 ${a||"n/a"} · 실제 ${o}/${l} · ctx ${c}/${d}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(L=t.summary)!=null&&L.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>최대 hot ${m} · ${((V=t.provider)==null?void 0:V.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(X=t.summary)!=null&&X.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((rt=t.operation)==null?void 0:rt.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((U=t.squad)==null?void 0:U.label)??"없음"}</span>
                      <span>실행체</span><span>${((I=t.detachment)==null?void 0:I.detachment_id)??"없음"}</span>
                      <span>목표 해석</span><span>target profile 기준, 달성 사실과 분리</span>
                      <span>예상 워커</span><span>${((A=t.summary)==null?void 0:A.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((N=t.summary)==null?void 0:N.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((J=t.provider)==null?void 0:J.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?i`<div class="command-tag-row">
                          ${t.truth_notes.map(Q=>i`<span class="command-tag">${Q}</span>`)}
                        </div>`:null}
                    <${Yd} swarm=${t} />
                  `:i`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?i`<div class="command-card-stack">
                ${t.checklist.map(Q=>i`<${dh} item=${Q} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?i`<div class="command-card-stack">
                ${t.workers.map(Q=>i`<${uh} worker=${Q} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${O} panelId="command.swarm" compact=${!0} />
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
                  <span>마지막 샘플</span><span>${t.provider.last_sample_at?tt(t.provider.last_sample_at):"정보 없음"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"없음"}</span>
                  <span>검사 시각</span><span>${t.provider.checked_at?tt(t.provider.checked_at):"정보 없음"}</span>
                </div>
                <div class="command-card-sub">
                  target profile과 실제 런타임은 다를 수 있습니다. 설정 용량, 실제 슬롯, 최대 hot 슬롯을 분리해서 읽으세요.
                </div>
                ${t.provider.detail?i`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?i`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(Q=>i`
                          <article class="command-trace-row">
                            <div class="command-trace-main">
                              <div class="command-trace-head">
                                <strong>hot ${Q.active_slots}</strong>
                                <span class="command-chip">${tt(Q.timestamp)}</span>
                              </div>
                            <div class="command-card-sub">slot ids ${Q.active_slot_ids.join(", ")||"없음"}</div>
                            </div>
                          </article>
                      `)}
                    </div>`:i`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:i`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?i`<div class="command-card-stack">
                ${t.blockers.map(Q=>i`<${Zd} blocker=${Q} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?i`<div class="command-trace-stack">
                ${t.recent_messages.map(Q=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${Q.from}</strong>
                        <span class="command-chip">${tt(Q.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${Q.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${Q.content}</pre>
                  </article>
                `)}
              </div>`:i`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${O} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${t.recent_trace_events.map(Q=>i`<${rr} event=${Q} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function Yt(t,e=260){return t.length<=e?t:`${t.slice(0,e-1)}…`}function Qe(t){if(!t)return 0;const e=Date.parse(t);return Number.isNaN(e)?0:e}function mh(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function _h(t){const e=typeof t.timestamp=="string"?t.timestamp:typeof t.created_at=="string"?t.created_at:typeof t.at=="string"?t.at:null,n=typeof t.title=="string"?t.title:typeof t.kind=="string"?t.kind:typeof t.event=="string"?t.event:"세션 이벤트",s=typeof t.detail=="string"?t.detail:typeof t.summary=="string"?t.summary:Qn(t);return{timestamp:e,title:n,detail:Yt(s,220)}}function vh(t){return t==="swarm"?"스웜 실시간":"세션 요약"}function fh(t){switch(t){case"current":return"현재 과업 일치";case"drift":return"과업 드리프트";case"claim":return"착수 흔적 있음";case"no-claim":return"착수 흔적 없음";case"done":return"완료 흔적 있음";case"no-done":return"완료 흔적 없음";case"final":return"최종 보고 있음";case"no-final":return"최종 보고 없음";case"turn":return"턴 기록 있음";case"silent":return"턴 기록 없음";case"noted":return"노트 기록 있음";default:return t.startsWith("empty:")?`빈 노트 ${t.slice(6)}회`:t.startsWith("turns:")?`턴 ${t.slice(6)}회`:t}}function gh(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"할당 없음",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}초`:t.heartbeat_fresh?"정상":"정보 없음",detail:[t.bound_task_status??null,t.detachment_member?"분견대 소속":null,t.squad_member?"분대 소속":null].filter(Boolean).join(" · ")||"스웜 실시간 카드",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function $h(t,e){const n=t.actor??t.spawn_role??`워커-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"워커",a=t.lane_id??t.capsule_mode??t.control_domain??"세션",o=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"세션 레인",heartbeat:t.last_turn_ts_iso?tt(t.last_turn_ts_iso):"정보 없음",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?bn(t.routing_confidence):null].filter(Boolean).join(" · ")||"세션 요약 카드",markers:o,note:t.routing_reason??null}}function hh(t){var e;return{key:`agent:${t.name}`,name:t.name,role:t.agent_type??"agent",source:"agent",status:wt(t.status),tone:E(le(t.status)),task:t.current_task??"대기 중",signal:tt(t.last_seen),detail:[t.model??null,((e=t.capabilities)==null?void 0:e.slice(0,2).join(", "))||null].filter(Boolean).join(" · ")||"글로벌 agent roster",chips:[t.context_ratio!=null?`ctx ${Math.round(t.context_ratio*100)}%`:"ctx n/a",t.status],note:t.personalityHint??null}}function yh(t){var n,s,a;const e=t.status==="offline"||t.status==="inactive"?"bad":t.status==="active"||t.status==="healthy"?"ok":"warn";return{key:`keeper:${t.name}`,name:t.name,role:t.runtime_class??"keeper",source:"keeper",status:wt(t.status),tone:e,task:((n=t.active_goal_ids)==null?void 0:n[0])??t.last_proactive_reason??((s=t.agent)==null?void 0:s.current_task)??"standby",signal:t.last_heartbeat?tt(t.last_heartbeat):mh(t.last_turn_ago_s),detail:[t.autonomy_level??null,t.active_model??t.primary_model??t.model??null,t.keepalive_running?"keepalive on":null].filter(Boolean).join(" · ")||"글로벌 keeper roster",chips:[t.context_ratio!=null?`ctx ${Math.round(t.context_ratio*100)}%`:"ctx n/a",t.latest_tool_call_count!=null?`tools ${t.latest_tool_call_count}`:"tools n/a"],note:((a=t.diagnostic)==null?void 0:a.summary)??t.last_proactive_preview??t.recent_output_preview??null}}function bh(t){return{key:`resident:${t.keeper_name??"judge"}`,name:t.keeper_name??"resident-judge",role:"resident judge",source:"resident",status:ni(t),tone:Kd(t),task:t.judge_online?"live guidance":"standby",signal:t.generated_at?tt(t.generated_at):"정보 없음",detail:[t.model_used??null,t.last_error?"error":null].filter(Boolean).join(" · ")||"resident runtime",chips:[t.enabled?"enabled":"disabled",t.judge_online?"online":"offline"],note:t.last_error??null}}function kh(t){return E(t.severity)}function xh({swarmMessages:t,traceEvents:e,chainOverlay:n,linkedAutoresearch:s,selectedSession:a,activeRecommendedActions:o,attentionItems:l}){const c=[];for(const d of t.slice(0,8))c.push({key:`message:${d.seq}`,title:d.from,detail:Yt(d.content,280),meta:`메시지 · seq ${d.seq}`,source:"swarm",tone:"ok",timestamp:d.timestamp,sortTs:Qe(d.timestamp)});for(const d of e.slice(0,8))c.push({key:`trace:${d.event_id}`,title:d.event_type,detail:Yt(Qn(d.detail),280),meta:[d.actor??null,d.source??null].filter(Boolean).join(" · ")||"trace",source:"trace",tone:d.event_type.includes("error")||d.event_type.includes("fail")?"bad":"warn",timestamp:d.timestamp,sortTs:Qe(d.timestamp)});if(n!=null&&n.history&&c.push({key:`chain:${n.operation.operation_id}:${n.history.event}`,title:`Chain · ${n.history.event}`,detail:Yt(ti(n.history),260),meta:n.history.chain_id??n.operation.operation_id,source:"chain",tone:n.history.event.includes("error")||n.history.event.includes("fail")?"bad":"warn",timestamp:n.history.timestamp,sortTs:Qe(n.history.timestamp)}),s){const d=[s.last_decision??null,s.target_file?`target ${s.target_file}`:null,s.error??null].filter(Boolean);c.push({key:`autoresearch:${s.loop_id??(a==null?void 0:a.session_id)??"session"}`,title:`Autoresearch · ${s.status??"unknown"}`,detail:Yt(d.join(" · ")||"linked autoresearch context",260),meta:[s.loop_id?`loop ${s.loop_id}`:null,s.current_cycle!=null?`cycle ${s.current_cycle}`:null,s.best_score!=null?`best ${s.best_score}`:null].filter(Boolean).join(" · ")||"linked autoresearch",source:"autoresearch",tone:s.error?"bad":s.status==="running"?"warn":"ok",timestamp:null,sortTs:0})}for(const d of o.slice(0,4))c.push({key:`recommendation:${d.action_type}:${d.target_type}:${d.target_id??"session"}`,title:`${d.action_type} · ${d.target_type}`,detail:Yt(d.reason,240),meta:d.target_id??"operator recommendation",source:"recommendation",tone:kh(d),timestamp:null,sortTs:0});for(const d of l.slice(0,4))c.push({key:`attention:${d.kind}:${d.target_id??"session"}`,title:`${d.kind} · ${d.target_type}`,detail:Yt(d.summary,240),meta:d.target_id??"attention",source:"attention",tone:E(d.severity),timestamp:null,sortTs:0});for(const[d,m]of((a==null?void 0:a.recent_events)??[]).slice(0,4).entries()){const p=_h(m);c.push({key:`session:${(a==null?void 0:a.session_id)??"unknown"}:${d}`,title:p.title,detail:p.detail,meta:(a==null?void 0:a.session_id)??"session",source:"session",tone:"warn",timestamp:p.timestamp,sortTs:Qe(p.timestamp)})}return c.sort((d,m)=>m.sortTs-d.sortTs||d.title.localeCompare(m.title)).slice(0,14)}function Sh({worker:t}){return i`
    <article class="command-card compact warroom-worker-card ${E(le(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${E(le(t.status))}">${wt(t.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>출처</span><span>${vh(t.source)}</span>
        <span>과업</span><span>${t.task}</span>
        <span>최근 신호</span><span>${t.heartbeat}</span>
        <span>근거</span><span>${t.detail}</span>
      </div>
      <div class="command-tag-row">
        ${t.markers.map(e=>i`<span class="command-tag">${fh(e)}</span>`)}
      </div>
      ${t.note?i`<div class="command-card-foot">${Yt(t.note,220)}</div>`:null}
    </article>
  `}function Il({item:t}){return i`
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
  `}function Ch({item:t}){return i`
    <article class="command-trace-row warroom-feed-card ${t.tone}">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.title}</strong>
          <span class="command-chip ${t.tone}">${t.timestamp?tt(t.timestamp):t.source}</span>
        </div>
        <div class="command-card-sub">${t.meta}</div>
      </div>
      <div class="warroom-feed-detail">${t.detail}</div>
    </article>
  `}function Dt({label:t,surface:e,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){qt(e),it("command",{...hs(e),...n});return}it("intervene")}}
    >
      ${t}
    </button>
  `}function Ah({chainOverlay:t,linkedAutoresearch:e}){var n,s,a,o;return!t&&!e?i`<div class="command-guide-card"><p>이 세션에 붙은 chain/autoresearch 오버레이가 아직 없습니다.</p></div>`:i`
    <div class="warroom-orchestration-grid">
      ${t?i`
            <article class="command-card warroom-orchestration-card">
              <div class="command-card-head">
                <div>
                  <strong>Chain Orchestration</strong>
                  <div class="command-card-sub">${t.operation.operation_id}</div>
                </div>
                <span class="command-chip ${E(le(t.operation.status))}">${wt(t.operation.status)}</span>
              </div>
              <div class="command-card-grid">
                <span>Chain</span><span>${((n=t.runtime)==null?void 0:n.chain_id)??((s=t.preview_run)==null?void 0:s.chain_id)??"n/a"}</span>
                <span>Progress</span><span>${bn((a=t.runtime)==null?void 0:a.progress)}</span>
                <span>Elapsed</span><span>${Ye((o=t.runtime)==null?void 0:o.elapsed_sec)}</span>
                <span>최근 이벤트</span><span>${ti(t.history)}</span>
              </div>
              <div class="command-action-row">
                <${Dt}
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
                <${Dt} label="세션 개입" />
                ${e.operation_id?i`<${Dt}
                      label="작전 상세"
                      surface="operations"
                      params=${{operation_id:e.operation_id}}
                    />`:null}
              </div>
            </article>
          `:null}
    </div>
  `}function Th({wallboard:t=!1}){var ks,xs,_r,vr,fr,gr,$r,hr,yr,br,kr,xr,Sr,Cr,Ar,Tr,Ir,Rr,Mr,Er,Lr,Pr,zr,Nr,jr,Dr,wr,Or,qr,Fr,Br,Kr;const e=ys(),n=Be.value,s=Et.value,a=Ut.value,o=Kg(),l=n!=null&&n.operation?((ks=vs.value)==null?void 0:ks.operations.find(F=>{var ke;return F.operation.operation_id===((ke=n.operation)==null?void 0:ke.operation_id)}))??null:null,c=(o==null?void 0:o.linked_autoresearch)??null,d=Fg(),m=(n==null?void 0:n.workers)??[],p=(a==null?void 0:a.worker_cards)??[],v=d&&m.length>0?m.map(gh):p.map($h),f=Ht.value.filter(F=>F.status==="active"||F.status==="busy"||F.status==="listening"||F.status==="idle"),$=se.value.filter(F=>F.status!=="offline"||F.keepalive_running||F.last_heartbeat).sort((F,ke)=>Qe(ke.last_heartbeat)-Qe(F.last_heartbeat)),S=d,y=((xs=e==null?void 0:e.decisions.summary)==null?void 0:xs.pending)??0,k=(s==null?void 0:s.pending_confirms)??[],h=d?(n==null?void 0:n.blockers)??[]:[],C=(a==null?void 0:a.recommended_actions)??[],M=(_r=a==null?void 0:a.active_recommended_actions)!=null&&_r.length?a.active_recommended_actions:C,T=a==null?void 0:a.active_summary,P=(a==null?void 0:a.active_guidance_layer)??"fallback",G=(a==null?void 0:a.resident_judge_runtime)??(s==null?void 0:s.resident_judge_runtime),L=(a==null?void 0:a.attention_items)??[],V=((vr=n==null?void 0:n.recent_messages[0])==null?void 0:vr.timestamp)??null,X=((fr=n==null?void 0:n.recent_trace_events[0])==null?void 0:fr.timestamp)??null,rt=d?V??X??null:null,U=o==null?void 0:o.summary,I=(d?(gr=n==null?void 0:n.summary)==null?void 0:gr.expected_workers:void 0)??(typeof(U==null?void 0:U.planned_worker_count)=="number"?U.planned_worker_count:void 0)??(a==null?void 0:a.worker_cards.length)??0,A=(d?($r=n==null?void 0:n.summary)==null?void 0:$r.joined_workers:void 0)??(typeof(U==null?void 0:U.active_agent_count)=="number"?U.active_agent_count:void 0)??v.length,N=h.length>0||y>0||k.length>0?"warn":S||o?"ok":"warn",J=d?((hr=e==null?void 0:e.swarm_status)==null?void 0:hr.lanes.filter(F=>F.present))??[]:[],Q=((br=(yr=e==null?void 0:e.swarm_status)==null?void 0:yr.narrative)==null?void 0:br.lane_id)??((xr=(kr=e==null?void 0:e.swarm_status)==null?void 0:kr.recommended_next_action)==null?void 0:xr.lane_id)??((Sr=J[0])==null?void 0:Sr.lane_id)??null,ot=Q?J.find(F=>F.lane_id===Q)??null:J[0]??null,W=[...G?[bh(G)]:[],...f.slice(0,t?8:5).map(hh),...$.slice(0,t?8:5).map(yh)],Lt=W.filter(F=>F.source==="agent"),be=W.filter(F=>F.source==="keeper"||F.source==="resident"),kn=xh({swarmMessages:(n==null?void 0:n.recent_messages)??[],traceEvents:(n==null?void 0:n.recent_trace_events)??[],chainOverlay:l,linkedAutoresearch:c,selectedSession:o,activeRecommendedActions:M,attentionItems:L}),bs=((Cr=n==null?void 0:n.operation)==null?void 0:Cr.objective)??((Tr=(Ar=e==null?void 0:e.swarm_status)==null?void 0:Ar.narrative)==null?void 0:Tr.active_work)??(o==null?void 0:o.session_id)??"가동 중인 워룸",ii=[(T==null?void 0:T.summary)??null,((Rr=(Ir=e==null?void 0:e.swarm_status)==null?void 0:Ir.narrative)==null?void 0:Rr.state)??null,((Er=(Mr=e==null?void 0:e.swarm_status)==null?void 0:Mr.narrative)==null?void 0:Er.active_work)??null,ot?`${ot.label} · ${ot.current_step}`:null].filter(Boolean).join(" · ")||"실제 실행, 메시지, 트레이스, 상주 판단을 한 장에서 읽는 wallboard입니다.",[oi,ri]=pn(typeof document<"u"&&!!document.fullscreenElement);st(()=>{gt()},[]),st(()=>{o!=null&&o.session_id&&Oe(o.session_id)},[o==null?void 0:o.session_id,s,(Lr=n==null?void 0:n.detachment)==null?void 0:Lr.session_id]),st(()=>{if(!t)return;const F=()=>{ri(!!document.fullscreenElement)};return document.addEventListener("fullscreenchange",F),F(),()=>{document.removeEventListener("fullscreenchange",F)}},[t]);const li=()=>{var F,ke,Ur;if(!(typeof document>"u")){if(document.fullscreenElement){(F=document.exitFullscreen)==null||F.call(document);return}(Ur=(ke=document.documentElement).requestFullscreen)==null||Ur.call(ke)}},ci=()=>{gt(),Qt(),je(),o!=null&&o.session_id&&Oe(o.session_id)};return!S&&!o?xa.value||Hn.value?i`<div class="empty-state">실시간 워룸 불러오는 중…</div>`:i`
      <section class="card command-section command-warroom-empty ${t?"wallboard":""}">
        <div class="card-title-row">
          <div class="card-title">실시간 워룸</div>
          <${O} panelId="command.warroom" compact=${!0} />
        </div>
        <div class="command-warroom-empty-copy">
          <span class="command-hero-kicker">Narrative Playback</span>
          <strong>지금 붙잡을 live swarm 또는 team session이 없습니다</strong>
          <p>chain, autoresearch, worker wallboard는 활성 작전 또는 세션이 생기면 자동으로 붙습니다. 지금은 drill-down surface로 이동하는 편이 맞습니다.</p>
        </div>
        <div class="command-action-row">
          <${Dt} label="작전 보기" surface="operations" />
          <${Dt} label="스웜 보기" surface="swarm" />
          <${Dt} label="체인 보기" surface="chains" />
          <${Dt} label="개입 열기" />
        </div>
      </section>
    `:i`
    <div class="command-section-stack ${t?"wallboard":""}">
      <section class="command-warroom-strip ${E(N)} ${t?"wallboard":""}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">${t?"War Room Wallboard":"실시간 워룸"}</span>
            <strong>${bs}</strong>
            <div class="command-card-sub">
              ${d?((Pr=n==null?void 0:n.operation)==null?void 0:Pr.operation_id)??"작전 정보 없음":"세션 기준값"}
              ${o!=null&&o.session_id?` · 세션 ${o.session_id}`:""}
              ${d&&((zr=n==null?void 0:n.detachment)!=null&&zr.detachment_id)?` · 분견대 ${n.detachment.detachment_id}`:""}
              ${ot?` · 대표 레인 ${ot.label}`:""}
            </div>
            <div class="command-warroom-summary">${ii}</div>
            ${T!=null&&T.summary?i`<div class="command-warroom-guidance ${Na(P)}">
                  <strong>${ir(P)}</strong>
                  <span>${T.summary}</span>
                </div>`:null}
          </div>
          <div class="command-warroom-hero-actions">
            <button class="control-btn ghost" onClick=${ci}>새로고침</button>
            ${t?i`
                  <button class="control-btn ghost" onClick=${li}>
                    ${oi?"전체 화면 해제":"전체 화면"}
                  </button>
                  <button
                    class="control-btn ghost"
                    onClick=${()=>{var F;document.fullscreenElement&&((F=document.exitFullscreen)==null||F.call(document)),qt("warroom"),it("command",hs("warroom"))}}
                  >
                    표준 보기
                  </button>
                `:null}
            <${Dt}
              label="스웜 상세"
              surface="swarm"
              params=${{...d&&((Nr=n==null?void 0:n.operation)!=null&&Nr.operation_id)?{operation_id:n.operation.operation_id}:{},...d&&(n!=null&&n.run_id)?{run_id:n.run_id}:{}}}
            />
            ${l?i`<${Dt}
                  label="체인"
                  surface="chains"
                  params=${{operation:l.operation.operation_id}}
                />`:null}
            <${Dt} label="개입" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>워커</span>
            <strong>${A??0}/${I??0}</strong>
            <small>${d?((jr=n==null?void 0:n.summary)==null?void 0:jr.completed_workers)??0:0} 완료 · ${v.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>런타임</span>
            <strong>${d?(Dr=n==null?void 0:n.provider)!=null&&Dr.runtime_blocker?"막힘":(wr=n==null?void 0:n.provider)!=null&&wr.provider_reachable?"준비됨":o?wt(o.status):"확인 필요":o?wt(o.status):"확인 필요"}</strong>
            <small>${d?`설정 ${((Or=n==null?void 0:n.provider)==null?void 0:Or.configured_capacity)??"n/a"} · 실제 ${((qr=n==null?void 0:n.provider)==null?void 0:qr.actual_slots)??((Fr=n==null?void 0:n.provider)==null?void 0:Fr.total_slots)??0} · hot ${((Br=n==null?void 0:n.summary)==null?void 0:Br.peak_hot_slots)??((Kr=n==null?void 0:n.provider)==null?void 0:Kr.peak_active_slots)??0}`:`세션 워커 ${(a==null?void 0:a.worker_cards.length)??0}`}</small>
          </div>
          <div class="monitor-stat-card ${E(h.length>0||y>0?"warn":"ok")}">
            <span>압력</span>
            <strong>${h.length+y+k.length}</strong>
            <small>막힘 ${h.length} · 승인 ${y} · 확인 ${k.length}</small>
          </div>
          <div class="monitor-stat-card ${E(Na(P))}">
            <span>상주 판정기</span>
            <strong>${ni(G)}</strong>
            <small>${or(T)}${G!=null&&G.model_used?` · ${G.model_used}`:""}</small>
          </div>
          <div class="monitor-stat-card">
            <span>마지막 신호</span>
            <strong>${tt(rt)}</strong>
            <small>${V?"메시지":X?"트레이스":"대기 중"}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid ${t?"wallboard":""}">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${J.length>0?i`
                  <${Qd} lanes=${J} />
                  <${Xd} lanes=${J} />
                `:o?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${o.session_id}</strong>
                        <span class="command-chip ${E(le(o.status))}">${wt(o.status)}</span>
                      </div>
                      <p>스웜 실시간 증거는 아직 약합니다. 이 카드는 세션 요약과 워커 기록을 기준으로 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${o.progress_pct!=null?`${o.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${Ye(o.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${Ye(o.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 레인이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">오케스트레이션</div>
              <${O} panelId="command.chains" compact=${!0} />
            </div>
            <${Ah} chainOverlay=${l} linkedAutoresearch=${c} />
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">워커 현황</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${v.length>0?i`<div class="command-card-stack">
                  ${v.map(F=>i`<${Sh} worker=${F} />`)}
                </div>`:i`<div class="empty-state">활성 워커 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">상황 피드</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${kn.length>0?i`<div class="command-trace-stack">
                  ${kn.map(F=>i`<${Ch} item=${F} />`)}
                </div>`:i`<div class="empty-state">메시지, chain, autoresearch, attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">트레이스 흐름</div>
              <${O} panelId="command.trace" compact=${!0} />
            </div>
            ${n&&n.recent_trace_events.length>0?i`<div class="command-trace-stack">
                  ${n.recent_trace_events.map(F=>i`<${rr} event=${F} />`)}
                </div>`:i`<div class="empty-state">실행 범위 트레이스 이벤트가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Agents</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${Lt.length>0?i`<div class="warroom-presence-grid">
                  ${Lt.map(F=>i`<${Il} item=${F} />`)}
                </div>`:i`<div class="empty-state">가시적인 active agent가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Keepers</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${be.length>0?i`<div class="warroom-presence-grid">
                  ${be.map(F=>i`<${Il} item=${F} />`)}
                </div>`:i`<div class="empty-state">가시적인 keeper/runtime 카드가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">압력</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${d&&n?i`<${Yd} swarm=${n} />`:null}
              ${h.length>0?h.map(F=>i`<${Zd} blocker=${F} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${y>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>승인 대기</strong>
                        <span class="command-chip warn">${y}</span>
                      </div>
                      <p>엄격 액션이 묶여 있습니다. 실제 승인 처리는 제어 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${k.length>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>확인 대기</strong>
                        <span class="command-chip warn">${k.length}</span>
                      </div>
                      <p>운영자 미리보기가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${k.slice(0,3).map(F=>i`<span class="command-tag">${F.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
              ${ot?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${ot.label}</strong>
                          <div class="command-card-sub">${ot.kind} · ${ot.phase}</div>
                        </div>
                        <span class="command-chip ${E(le(ot.motion_state))}">${wt(ot.motion_state)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>현재 단계</span><span>${ot.current_step}</span>
                        <span>이동 사유</span><span>${ot.movement_reason}</span>
                        <span>막힘 수</span><span>${ot.blockers.length}</span>
                        <span>최근 이동</span><span>${tt(ot.last_movement_at)}</span>
                      </div>
                    </article>
                  `:null}
              ${d&&(n!=null&&n.detachment)?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${n.detachment.detachment_id}</strong>
                          <div class="command-card-sub">${n.detachment.assigned_unit_id}</div>
                        </div>
                        <span class="command-chip ${E(le(n.detachment.status))}">${wt(n.detachment.status??"active")}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>리더</span><span>${n.detachment.leader_id??"미지정"}</span>
                        <span>편성</span><span>${n.detachment.roster.length}</span>
                        <span>세션</span><span>${n.detachment.session_id??"연결 없음"}</span>
                        <span>하트비트</span><span>${Ld(n.detachment.heartbeat_deadline)}</span>
                      </div>
                    </article>
                  `:o?i`
                      <article class="command-card compact">
                        <div class="command-card-head">
                          <div>
                            <strong>${o.session_id}</strong>
                            <div class="command-card-sub">현재 세션 기준</div>
                          </div>
                          <span class="command-chip ${E(le(o.status))}">${wt(o.status)}</span>
                        </div>
                        <div class="command-card-grid">
                          <span>진행률</span><span>${o.progress_pct!=null?`${o.progress_pct}%`:"정보 없음"}</span>
                          <span>경과</span><span>${Ye(o.elapsed_sec)}</span>
                          <span>남은 시간</span><span>${Ye(o.remaining_sec)}</span>
                          <span>완료 변화량</span><span>${o.done_delta_total??0}</span>
                        </div>
                      </article>
                    `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function Rl(t){switch((t??"").trim().toLowerCase()){case"active":return"가동 중";case"paused":return"일시정지";case"failed":return"실패";case"completed":case"done":return"완료";case"disconnected":return"끊김";case"preview":return"미리보기";case"captured":return"기록됨";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Ih({source:t}){const e=En(null),[n,s]=pn(null);return st(()=>{let a=!1;const o=e.current;return o?(o.innerHTML="",s(null),(async()=>{try{const c=await Cg(),{svg:d}=await c.render(`command-chain-${Sg()}`,t);if(a||!e.current)return;e.current.innerHTML=d}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid 렌더링에 실패했습니다")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function Rh({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return i`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${me(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?i`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?i`<span class="command-tag ${me(s==null?void 0:s.status)}">${bn(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${ti(t.history)}</div>
    </button>
  `}function Mh({item:t}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"알 수 없는 체인"}</strong>
        <span class="command-chip ${me(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${tt(t.timestamp)}</div>
      <div class="command-card-sub">${ti(t)}</div>
    </article>
  `}function Eh({node:t}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${me(t.status)}">${t.status??"확인 필요"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"노드"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?i`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function Lh({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,o=e.chain,l=(o==null?void 0:o.run_id)??null;return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${E(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${Rl(e.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>트레이스</span><span class="mono">${e.trace_id}</span>
        <span>자율성</span><span>${e.autonomy_level??"정보 없음"}</span>
        <span>예산 등급</span><span>${e.budget_class??"standard"}</span>
        <span>출처</span><span>${e.source??"managed"}</span>
        <span>최근 갱신</span><span>${tt(e.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${me(o.status)}">${Rl(o.status)}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">실행 ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?i`<div class="command-card-foot">체크포인트 ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{qt("swarm"),it("command",{surface:"swarm",operation_id:e.operation_id,...l?{run_id:l}:{}})}}
        >
          스웜 실시간 보기
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{Jo(e.operation_id),qt("chains"),it("command",{surface:"chains",operation:e.operation_id})}}
              >
                체인 열기
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${dt(n)} onClick=${()=>_e(()=>Jv(e.operation_id))}>
                ${dt(n)?"일시정지 중…":"일시정지"}
              </button>
              <button class="control-btn ghost" disabled=${dt(a)} onClick=${()=>_e(()=>Vv(e.operation_id))}>
                ${dt(a)?"회수 중…":"회수"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${dt(s)} onClick=${()=>_e(()=>Yv(e.operation_id))}>
                ${dt(s)?"재개 중…":"재개"}
              </button>
            `:null}
      </div>
    </article>
  `}function Ph({card:t}){var n;const e=t.detachment;return i`
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
        <span>진행 흔적</span><span>${tt(e.last_progress_at)}</span>
        <span>하트비트</span><span>${Ld(e.heartbeat_deadline)}</span>
        <span>최근 갱신</span><span>${tt(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?i`<span class="command-tag ${kg(e.heartbeat_deadline)}">
              기한 ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function zh(){const t=Gt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">작전</div>
          <${O} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${Lh} card=${e} />`)}
            </div>`:i`<div class="empty-state">관리형 또는 투영된 작전이 없습니다.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">분견대</div>
          <${O} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${Ph} card=${e} />`)}
            </div>`:i`<div class="empty-state">투영된 분견대가 없습니다.</div>`}
      </section>
    </div>
  `}function Nh(){var c,d,m,p,v,f,$,S,y,k,h,C,M,T,P,G;const t=vs.value,e=(t==null?void 0:t.operations)??[],n=rn.value,s=e.find(L=>L.operation.operation_id===n)??e[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,o=((d=Jn.value)==null?void 0:d.run)??(s==null?void 0:s.preview_run)??null,l=!((m=Jn.value)!=null&&m.run)&&!!(s!=null&&s.preview_run);return st(()=>{a?Hv(a):Wv()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${O} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${me(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>native chain 연결</strong>
            <span class="command-chip ${me(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"체인 요약은 MASC 프록시를 통해 집계됩니다."}</p>
          <div class="command-card-grid">
            <span>기준 URL</span><span>${(t==null?void 0:t.connection.base_url)??"정보 없음"}</span>
            <span>연결된 작전</span><span>${((p=t==null?void 0:t.summary)==null?void 0:p.linked_operations)??0}</span>
            <span>활성 체인</span><span>${((v=t==null?void 0:t.summary)==null?void 0:v.active_chains)??0}</span>
            <span>최근 실패</span><span>${((f=t==null?void 0:t.summary)==null?void 0:f.recent_failures)??0}</span>
            <span>마지막 이벤트</span><span>${tt(($=t==null?void 0:t.summary)==null?void 0:$.last_history_event_at)}</span>
          </div>
        </article>

        ${Aa.value?i`<div class="empty-state error">${Aa.value}</div>`:null}

        ${po.value&&!t?i`<div class="empty-state">체인 오버레이 불러오는 중…</div>`:e.length>0?i`
                <div class="command-chain-list">
                  ${e.map(L=>i`
                    <${Rh}
                      overlay=${L}
                      selected=${(s==null?void 0:s.operation.operation_id)===L.operation.operation_id}
                      onSelect=${()=>Jo(L.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(L=>i`<${Mh} item=${L} />`)}
                </div>
              `:i`<div class="empty-state">최근 체인 이력이 없습니다.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">체인 상세</div>
          <${O} panelId="command.chains" compact=${!0} />
        </div>
        ${s?i`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${me((S=s.operation.chain)==null?void 0:S.status)}">
                    ${((y=s.operation.chain)==null?void 0:y.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>종류</span><span>${((k=s.operation.chain)==null?void 0:k.kind)??"chain_dsl"}</span>
                  <span>체인 ID</span><span>${((h=s.operation.chain)==null?void 0:h.chain_id)??"goal-driven"}</span>
                  <span>실행 ID</span><span>${a??"아직 구체화되지 않음"}</span>
                  <span>진행률</span><span>${bn((C=s.runtime)==null?void 0:C.progress)}</span>
                  <span>경과</span><span>${Ye((M=s.runtime)==null?void 0:M.elapsed_sec)}</span>
                  <span>최근 갱신</span><span>${tt(((T=s.operation.chain)==null?void 0:T.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(P=s.operation.chain)!=null&&P.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid 그래프</strong>
                        <span class="command-chip">${((G=s.operation.chain)==null?void 0:G.chain_id)??"graph"}</span>
                      </div>
                      <${Ih} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">기록된 Mermaid 그래프가 아직 없습니다.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>실행 상세</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"실패":l?"미리보기":"기록됨":"대기 중"}
                  </span>
                </div>
                ${Ta.value?i`<div class="empty-state">실행 상세 불러오는 중…</div>`:Yn.value?i`<div class="empty-state error">${Yn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>체인</span><span>${o.chain_id}</span>
                            <span>실행</span><span>${o.run_id??"미리보기만 있음"}</span>
                            <span>지속시간</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"정보 없음"}</span>
                            <span>노드</span><span>${o.nodes.length}</span>
                          </div>
                          ${l?i`<div class="command-card-foot">run-store에 기록되기 전, 설계된 체인으로 만든 미리보기입니다.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(L=>i`<${Eh} node=${L} />`)}
                          </div>
                        `:i`<div class="empty-state">이 작전의 run-store 상세는 아직 없습니다.</div>`}
              </div>
            `:i`<div class="empty-state">그래프와 실행 상세를 보려면 체인 기반 작전을 고르세요.</div>`}
      </section>
    </div>
  `}function jh(t){switch((t??"").trim().toLowerCase()){case"pending":return"대기 중";case"approved":return"승인됨";case"denied":return"거부됨";case"executed":return"실행됨";case"active":return"가동 중";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Dh({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return i`
    <article class="command-card ${E(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${E(t.status)}">${jh(t.status??"pending")}</span>
      </div>
      <div class="command-card-grid">
        <span>결정 ID</span><span>${t.decision_id}</span>
        <span>요청자</span><span>${t.requested_by??"알 수 없음"}</span>
        <span>출처</span><span>${t.source??"managed"}</span>
        <span>트레이스</span><span class="mono">${t.trace_id}</span>
        <span>생성 시각</span><span>${tt(t.created_at)}</span>
        <span>이유</span><span>${t.reason??"정보 없음"}</span>
      </div>
      ${t.status==="pending"&&!s?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${dt(e)} onClick=${()=>_e(()=>Qv(t.decision_id))}>
                ${dt(e)?"승인 중…":"승인"}
              </button>
              <button class="control-btn ghost" disabled=${dt(n)} onClick=${()=>_e(()=>Zv(t.decision_id))}>
                ${dt(n)?"거부 중…":"거부"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">레거시 operator 승인입니다. 실제 실행은 operator control에서 처리합니다.</div>`:null}
    </article>
  `}function wh({row:t}){var c,d,m;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((c=e.policy)!=null&&c.frozen),o=!!((d=e.policy)!=null&&d.kill_switch),l=Math.round((t.utilization??0)*100);return i`
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
        <button class="control-btn ghost" disabled=${dt(n)} onClick=${()=>_e(()=>tf(e.unit_id,!a))}>
          ${dt(n)?"적용 중…":a?"동결 해제":"동결"}
        </button>
        <button class="control-btn ghost" disabled=${dt(s)} onClick=${()=>_e(()=>ef(e.unit_id,!o))}>
          ${dt(s)?"적용 중…":o?"킬 스위치 해제":"킬 스위치 켜기"}
        </button>
      </div>
    </article>
  `}function Oh(){const t=Gt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${O} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${Dh} decision=${e} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">유닛 제어</div>
          <${O} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${wh} row=${e} />`)}
            </div>`:i`<div class="empty-state">제어할 용량 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function qh(){return i`
    <div class="command-surface-tabs grouped">
      ${Tg.map(t=>i`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${Pd.filter(e=>e.group===t.id).map(e=>i`
                <button
                  class="command-surface-tab ${Z.value===e.id?"active":""}"
                  onClick=${()=>{qt(e.id),it("command",hs(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function Fh({wallboard:t=!1}){if(Z.value==="warroom")return i`<${Th} wallboard=${t} />`;if(Z.value==="summary")return i`<${v$} />`;if(Z.value==="orchestra")return i`<${M$} />`;if(Z.value==="swarm")return i`<${ph} />`;if(!Gt.value)return i`<${f$} />`;switch(Z.value){case"chains":return i`<${Nh} />`;case"topology":return i`<${V$} />`;case"alerts":return i`<${X$} />`;case"trace":return i`<${Q$} />`;case"control":return i`<${Oh} />`;case"operations":default:return i`<${zh} />`}}function Bh(){const t=Z.value==="warroom"&&w.value.params.presentation==="wallboard";return st(()=>{Je(),je(),Gv(),Qt(),Pe()},[]),st(()=>{if(w.value.tab!=="command")return;const e=w.value.params.surface,n=w.value.params.operation,s=fs(w.value);if(gl(e))qt(e);else if(s){const a=fd(s);gl(a)&&qt(a)}else e||qt("warroom");n&&Jo(n),(e==="swarm"||e==="warroom"||e==="orchestra"||Z.value==="warroom"||Z.value==="orchestra")&&Qt(),(e==="orchestra"||Z.value==="orchestra")&&Pe(),(e==="warroom"||Z.value==="warroom")&&gt()},[w.value.tab,w.value.params.surface,w.value.params.operation,w.value.params.operation_id,w.value.params.run_id,w.value.params.source,w.value.params.action_type,w.value.params.target_type,w.value.params.target_id,w.value.params.focus_kind]),st(()=>{let e=null;const n=()=>{e||(e=window.setTimeout(()=>{e=null,Je(),je(),(Z.value==="swarm"||Z.value==="warroom"||Z.value==="orchestra")&&Qt(),Z.value==="orchestra"&&Pe(),Z.value==="warroom"&&gt()},250))},s=new EventSource(Lg()),a=Rg.map(o=>{const l=()=>n();return s.addEventListener(o,l),{type:o,handler:l}});return s.onerror=()=>{n()},()=>{a.forEach(({type:o,handler:l})=>{s.removeEventListener(o,l)}),s.close(),e&&window.clearTimeout(e)}},[]),st(()=>{const e=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const n=Z.value;n!=="swarm"&&n!=="warroom"&&n!=="orchestra"||(Je(),Qt(),n==="orchestra"&&Pe(),n==="warroom"&&gt())},5e3);return()=>{window.clearInterval(e)}},[]),i`
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
              onClick=${()=>{_e(()=>Xv())}}
              disabled=${dt("dispatch:tick")}
            >
              ${dt("dispatch:tick")?"정리 중...":"Tick 실행"}
            </button>
            <button
              class="control-btn ghost"
              onClick=${()=>{Ee(),Je(),je(),Qt(),Z.value==="warroom"&&gt()}}
              disabled=${ga.value}
            >
              ${ga.value?"새로고침 중...":"새로고침"}
            </button>
            <button
              class="control-btn ghost"
              onClick=${()=>{qt("warroom"),it("command",{...hs("warroom"),presentation:"wallboard"})}}
            >
              Wallboard
            </button>
          </div>
        </div>
      `}

      ${ha.value?i`<div class="empty-state error">${ha.value}</div>`:null}
      ${ba.value?i`<div class="empty-state error">${ba.value}</div>`:null}
      ${t?null:i`<${xt} surfaceId="command" />`}
      ${t?null:i`<${Xa} />`}
      ${t?null:i`<${d$} />`}
      ${t||Z.value==="warroom"?null:i`<${u$} />`}
      ${t?null:i`<${qh} />`}
      <${Fh} wallboard=${t} />
    </section>
  `}function Kh(){var k,h;const t=Et.value,e=Bo.value,n=(t==null?void 0:t.room)??{},s=(t==null?void 0:t.pending_confirms)??[],a=t==null?void 0:t.pending_confirm_summary,o=a?a.confirm_required_actions:((t==null?void 0:t.available_actions)??[]).filter(C=>C.confirm_required),l=((k=a==null?void 0:a.actor_filter)==null?void 0:k.trim())||null,c=(a==null?void 0:a.hidden_count)??0,d=(a==null?void 0:a.hidden_actors)??[],m=(t==null?void 0:t.recent_messages)??[],p=(e==null?void 0:e.recommended_actions)??[],v=(h=e==null?void 0:e.active_recommended_actions)!=null&&h.length?e.active_recommended_actions:p,f=e==null?void 0:e.active_summary,$=(e==null?void 0:e.resident_judge_runtime)??(t==null?void 0:t.resident_judge_runtime),S=(e==null?void 0:e.active_guidance_layer)??"fallback",y=m.slice(0,5);return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Room 개입</div>
          <${O} panelId="intervene.action_studio" compact=${!0} />
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
          <div class="ops-stat ${Kd($)}">
            <span>Resident Judge</span>
            <strong>${ni($)}</strong>
          </div>
        </div>

        <label class="control-label" for="ops-broadcast">Room 방송</label>
        <div class="control-row">
          <input
            id="ops-broadcast"
            class="control-input"
            type="text"
            placeholder="@agent 또는 room 전체 공지"
            value=${cn.value}
            onInput=${C=>{cn.value=C.target.value}}
            onKeyDown=${C=>{C.key==="Enter"&&Al()}}
            disabled=${nt.value}
          />
          <button class="control-btn" onClick=${()=>{Al()}} disabled=${nt.value||cn.value.trim()===""}>
            보내기
          </button>
        </div>

        <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
        <div class="control-row ops-split-row">
          <input
            id="ops-pause-reason"
            class="control-input"
            type="text"
            value=${La.value}
            onInput=${C=>{La.value=C.target.value}}
            disabled=${nt.value}
          />
          <button class="control-btn ghost" onClick=${()=>{K$()}} disabled=${nt.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{Wd()}} disabled=${nt.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${dn.value}
          onInput=${C=>{dn.value=C.target.value}}
          disabled=${nt.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${Zn.value}
          onInput=${C=>{Zn.value=C.target.value}}
          disabled=${nt.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${ts.value}
            onChange=${C=>{ts.value=C.target.value}}
            disabled=${nt.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{U$()}} disabled=${nt.value||dn.value.trim()===""}>
            주입
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">추천 개입</div>
          <${O} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
        <article class="ops-guidance-card ${Na(S)}">
          <div class="ops-guidance-head">
            <strong>${ir(S)}</strong>
            <span>${($==null?void 0:$.keeper_name)??(e==null?void 0:e.judgment_owner)??"judge 없음"}</span>
          </div>
          <div class="ops-guidance-body">
            ${(f==null?void 0:f.summary)??"현재 active guidance 요약이 없습니다. fallback queue만 표시합니다."}
          </div>
          <div class="ops-guidance-meta">
            <span>authoritative ${e!=null&&e.authoritative_judgment_available?"yes":"no"}</span>
            <span>${or(f)}</span>
            ${$!=null&&$.model_used?i`<span>${$.model_used}</span>`:null}
          </div>
        </article>
        ${Gn.value&&!e?i`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:v.length>0?i`
          <div class="ops-log-list">
            ${v.map(C=>i`
              <article key=${`${C.action_type}:${C.target_type}:${C.target_id??"room"}`} class="ops-log-entry ${C.severity}">
                <div class="ops-log-head">
                  <strong>${De(C.action_type)}</strong>
                  <span>${un(C.target_type)}${C.target_id?` · ${C.target_id}`:""}</span>
                  <span>${ja(C.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${C.reason}</div>
                ${C.suggested_payload?i`
                  <div class="ops-confirmation-actions">
                    <button class="control-btn ghost" onClick=${()=>{F$(C)}} disabled=${nt.value}>
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
          <${O} panelId="intervene.pending_confirmations" compact=${!0} />
        </div>
        <p class="ops-context-note">
          ${l?`현재 actor ${l} 기준 queue를 읽습니다. 승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다.`:"승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다."}
        </p>
        ${o.length>0?i`
          <div class="ops-log-list">
            ${o.map(C=>i`
              <article key=${`${C.action_type}:${C.target_type}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${De(C.action_type)}</strong>
                  <span>${un(C.target_type)}</span>
                  <span>${ja(C.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${C.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}
        ${s.length>0?i`
          <div class="ops-confirmation-list">
            ${s.map(C=>i`
              <article key=${C.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${De(C.action_type)}</strong>
                  <span>${un(C.target_type)}${C.target_id?` · ${C.target_id}`:""}</span>
                  <span>${C.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${C.preview?i`<pre class="ops-code-block compact">${za(C.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{Tl(C.confirm_token)}} disabled=${nt.value}>
                    실행
                  </button>
                  <button class="control-btn ghost" onClick=${()=>{Tl(C.confirm_token,"deny")}} disabled=${nt.value}>
                    거부
                  </button>
                  <span class="ops-token">${C.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        `:i`
          <div class="ops-empty">
            ${c>0&&l?`현재 선택한 actor(${l}) 기준 승인 대기는 0건입니다. 다른 actor 대기 ${c}건${d.length>0?` · ${d.join(", ")}`:""}`:"지금 승인 대기는 없습니다. 위 목록의 preview-confirm 액션을 먼저 만들어야 여기에 쌓입니다."}
          </div>
        `}
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 Room 메시지</div>
          <${O} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${y.length>0?i`
          <div class="ops-feed-list">
            ${y.map(C=>i`
              <article key=${C.seq??C.id??C.timestamp} class="ops-feed-item">
                <div class="ops-feed-meta">
                  <strong>${C.from}</strong>
                  <span>${C.timestamp}</span>
                </div>
                <div class="ops-feed-content">${C.content}</div>
              </article>
            `)}
          </div>
        `:i`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
      </section>
    </div>
  `}function Uh(){var m;const t=Et.value,e=Ut.value,n=(t==null?void 0:t.sessions)??[],s=((t==null?void 0:t.available_actions)??[]).filter(p=>p.target_type==="team_session"),a=n.find(p=>p.session_id===_n.value)??n[0]??null,o=e==null?void 0:e.active_summary,l=(e==null?void 0:e.active_guidance_layer)??"fallback",c=(e==null?void 0:e.resident_judge_runtime)??(t==null?void 0:t.resident_judge_runtime),d=(m=e==null?void 0:e.active_recommended_actions)!=null&&m.length?e.active_recommended_actions:(e==null?void 0:e.recommended_actions)??[];return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${O} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(p=>{var v;return i`
            <button
              key=${p.session_id}
              class="ops-entity-card ${(a==null?void 0:a.session_id)===p.session_id?"active":""}"
              onClick=${()=>{_n.value=p.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${p.session_id}</strong>
                <span class="status-badge ${p.status??"idle"}">${Xe(p.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(p.progress_pct??0)}%</span>
                <span>${p.done_delta_total??0}건 완료</span>
                <span>${(v=p.team_health)!=null&&v.status?Xe(String(p.team_health.status)):"상태 확인 필요"}</span>
              </div>
            </button>
          `})}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Session 요약</div>
          <${O} panelId="intervene.session_digest" compact=${!0} />
        </div>
        <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
        ${a&&e?i`
          <article class="ops-guidance-card ${Na(l)}">
            <div class="ops-guidance-head">
              <strong>${ir(l)}</strong>
              <span>${ni(c)}</span>
            </div>
            <div class="ops-guidance-body">
              ${(o==null?void 0:o.summary)??"현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다."}
            </div>
            <div class="ops-guidance-meta">
              <span>authoritative ${e.authoritative_judgment_available?"yes":"no"}</span>
              <span>${or(o)}</span>
              ${c!=null&&c.model_used?i`<span>${c.model_used}</span>`:null}
            </div>
          </article>
          ${d.length>0?i`
            <div class="ops-log-list">
              ${d.map(p=>i`
                <article key=${`${p.action_type}:${p.target_type}:${p.target_id??"session"}`} class="ops-log-entry ${p.severity}">
                  <div class="ops-log-head">
                    <strong>${De(p.action_type)}</strong>
                    <span>${un(p.target_type)}${p.target_id?` · ${p.target_id}`:""}</span>
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
                  <span>${un(p.target_type)}${p.target_id?` · ${p.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${p.summary}</div>
              </article>
            `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${e.worker_cards.length>0?e.worker_cards.map(p=>i`
              <article key=${`${p.actor??p.spawn_role??"worker"}:${p.spawn_agent??p.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${p.actor??p.spawn_role??"worker"}</strong>
                  <span>${Xe(p.status)}</span>
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
          <${O} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>
        ${s.length>0?i`
          <div class="ops-log-list">
            ${s.map(p=>i`
              <article key=${p.action_type} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${De(p.action_type)}</strong>
                  <span>${ja(p.confirm_required)}</span>
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
              <span>상태: ${Xe(a.status)}</span>
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
              <pre class="ops-code-block compact">${za(a.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${kt.value}
            onChange=${p=>{kt.value=p.target.value}}
            disabled=${nt.value||!a}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
            <option value="worker_spawn_batch">worker 교체</option>
          </select>
          <button class="control-btn" onClick=${()=>{W$()}} disabled=${nt.value||!a}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${D$(kt.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${es.value}
          onInput=${p=>{es.value=p.target.value}}
          disabled=${nt.value||!a}
        ></textarea>

        ${kt.value==="task"?i`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${ns.value}
            onInput=${p=>{ns.value=p.target.value}}
            disabled=${nt.value||!a}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${ss.value}
            onInput=${p=>{ss.value=p.target.value}}
            disabled=${nt.value||!a}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${as.value}
            onChange=${p=>{as.value=p.target.value}}
            disabled=${nt.value||!a}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
        `:kt.value==="worker_spawn_batch"?i`
          <textarea
            class="control-textarea"
            rows=${6}
            placeholder='spawn_batch JSON, 예: [{"spawn_agent":"llama","spawn_prompt":"...", "spawn_role":"replacement"}]'
            value=${is.value}
            onInput=${p=>{is.value=p.target.value}}
            disabled=${nt.value||!a}
          ></textarea>
        `:null}

        <div class="control-row ops-split-row">
          <input
            class="control-input"
            type="text"
            value=${Pa.value}
            onInput=${p=>{Pa.value=p.target.value}}
            disabled=${nt.value||!a}
          />
          <button class="control-btn ghost" onClick=${()=>{H$()}} disabled=${nt.value||!a}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function Wh(){var o;const t=Et.value,e=(t==null?void 0:t.keepers)??[],n=(t==null?void 0:t.persistent_agents)??[],s=(t==null?void 0:t.available_actions)??[],a=e.find(l=>l.name===fo.value)??e[0]??null;return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${O} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${e.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:e.map(l=>i`
            <button
              key=${l.name}
              class="ops-entity-card ${(a==null?void 0:a.name)===l.name?"active":""}"
              onClick=${()=>{fo.value=l.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${l.name}</strong>
                <span class="status-badge ${l.status??"idle"}">${Xe(l.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${l.model??"model 확인 필요"}</span>
                <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${Sl(l.last_turn_ago_s)}</span>
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
                    <span class="status-badge ${l.status??"idle"}">${Xe(l.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>persistent</span>
                    <span>${l.model??"model 확인 필요"}</span>
                    <span>${Sl(l.last_turn_ago_s)}</span>
                  </div>
                </article>
              `)}
        </div>
      </section>

      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Keeper 액션</div>
          <${O} panelId="intervene.action_studio" compact=${!0} />
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
          <${Md}
            keeperName=${a.name}
            placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
          />
        `:i`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">가능한 액션 목록</div>
          <${O} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
        <div class="ops-log-list">
          ${s.length?s.map(l=>i`
                <article key=${`${l.action_type}:${l.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${De(l.action_type)}</strong>
                    <span>${un(l.target_type)}</span>
                    <span>${ja(l.confirm_required)}</span>
                  </div>
                  <div class="ops-log-body">${l.description??"설명이 아직 없습니다."}</div>
                </article>
              `):i`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 개입 로그</div>
          <${O} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <div class="ops-log-list">
          ${ma.value.length===0?i`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:ma.value.map(l=>i`
            <article key=${l.id} class="ops-log-entry ${l.outcome}">
              <div class="ops-log-head">
                <strong>${De(l.action_type)}</strong>
                <span>${l.target_label}</span>
                <span>${l.at}</span>
              </div>
              <div class="ops-log-body">${l.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function Hh(){var T,P,G;const t=Et.value,e=w.value.tab==="intervene"?fs(w.value):null,n=Bo.value,s=(t==null?void 0:t.room)??{},a=(t==null?void 0:t.sessions)??[],o=(t==null?void 0:t.keepers)??[],l=(t==null?void 0:t.pending_confirms)??[],c=t==null?void 0:t.pending_confirm_summary,d=(c==null?void 0:c.visible_count)??l.length,m=(c==null?void 0:c.total_count)??l.length,p=(c==null?void 0:c.hidden_count)??0,v=((T=c==null?void 0:c.actor_filter)==null?void 0:T.trim())||null,f=a.find(L=>L.session_id===_n.value)??a[0]??null,$=(n==null?void 0:n.attention_items)??[],S=$.filter(N$),y=$.filter(j$),k=a.filter(L=>z$(L)!=="ok"),h=o.filter(L=>yi(L)!=="ok"),C=B$(e,a,o);st(()=>{we()},[]),st(()=>{if(w.value.tab!=="intervene"){Ps.value=null;return}if(!e){Ps.value=null;return}Ps.value!==e.id&&(Ps.value=e.id,q$(e))},[w.value.tab,w.value.params.source,w.value.params.action_type,w.value.params.target_type,w.value.params.target_id,w.value.params.focus_kind,e==null?void 0:e.id]),st(()=>{const L=(f==null?void 0:f.session_id)??null;Oe(L)},[f==null?void 0:f.session_id]);const M=[{key:"room",label:"방 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:p>0?`${d}/${m}`:d,detail:d>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":p>0&&v?`현재 개입 ID(${v}) 기준으로는 비어 있고, 다른 개입 ID 대기 ${p}건이 있습니다`:"지금 막혀 있는 확인 대기는 없습니다",tone:m>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:S.length>0?S.length:a.length,detail:S.length>0?((P=S[0])==null?void 0:P.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 팀 세션이 없습니다":"세션 쪽 긴급 주의 신호는 현재 없습니다",tone:S.length>0?Cl(S):a.length===0?"warn":k.some(L=>vn(L.status)==="paused")?"bad":k.length>0?"warn":"ok"},{key:"keeper",label:"키퍼 압력",value:y.length>0?y.length:h.length,detail:y.length>0?((G=y[0])==null?void 0:G.summary)??"직접 메시지나 상태 점검이 필요한 키퍼가 있습니다":h.length>0?"오래됐거나 오프라인이거나 텔레메트리가 비는 키퍼가 보입니다":"지금은 키퍼 쪽이 비교적 안정적입니다",tone:y.length>0?Cl(y):h.some(L=>yi(L)==="bad")?"bad":h.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${xt} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">개입</div>
            <${O} panelId="intervene.action_studio" compact=${!0} />
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
            onInput=${L=>P$(L.target.value)}
          />
            <button
              class="control-btn ghost"
              onClick=${()=>{Ee(),gt(),we(),Oe((f==null?void 0:f.session_id)??null)}}
            disabled=${Hn.value||nt.value}
          >
            ${Hn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${fe.value?i`<section class="ops-banner error">${fe.value}</section>`:null}
      ${mn.value?i`<section class="ops-banner error">${mn.value}</section>`:null}
      <${Xa} />
      ${e?i`
        <section class="ops-banner ${C?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${Qa(e.action_type)}</span>
            <span>${Qo(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?i`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${C?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const L=[];if((d>0||p>0)&&L.push({label:p>0?`확인 대기 ${d}/${m}건 확인`:`확인 대기 ${d}건 처리`,desc:p>0&&v?`현재 개입 ID(${v}) 기준으로 보이는 대기열을 먼저 확인합니다`:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:d>0?"bad":"warn",onClick:()=>{const V=document.querySelector(".ops-pending-section");V==null||V.scrollIntoView({behavior:"smooth"})}}),s.paused&&L.push({label:"방 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void Wd()}),h.length>0){const V=h.filter(X=>yi(X)==="bad");L.push({label:V.length>0?`오프라인 키퍼 ${V.length}개`:`점검이 필요한 키퍼 ${h.length}개`,desc:V.length>0?"메시지를 보내거나 상태를 확인하세요":"오래됐거나 텔레메트리가 비어 있습니다",tone:V.length>0?"bad":"warn",onClick:()=>{const X=document.querySelector(".ops-keeper-section");X==null||X.scrollIntoView({behavior:"smooth"})}})}return L.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${L.slice(0,3).map(V=>i`
                <button class="ops-action-guide-item ${V.tone}" onClick=${V.onClick}>
                  <strong>${V.label}</strong>
                  <span>${V.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `})()}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${O} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 방인지, 세션인지, 키퍼인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${M.map(L=>i`
            <div key=${L.key} class="ops-priority-card ${L.tone}">
              <span class="ops-priority-label">${L.label}</span>
              <strong>${L.value}</strong>
              <div class="ops-priority-detail">${L.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${Kh} />
        <${Uh} />
        <${Wh} />
      </div>
    </section>
  `}function Gh({text:t}){if(!t)return null;const e=Jh(t);return i`<div class="markdown-content">${e}</div>`}function Jh(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(l);)d.push(e[s]),s++;s++,n.push(i`<pre><code class=${c?`language-${c}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<e.length&&!e[s].includes("</think>");)l.push(e[s]),s++;if(s<e.length){const m=e[s].replace("</think>","").trim();m&&l.push(m),s++}const d=l.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${bi(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<e.length&&e[s].startsWith("> ");)l.push(e[s].slice(2)),s++;n.push(i`<blockquote>${bi(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<e.length;){const l=e[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;o.push(l),s++}o.length>0&&n.push(i`<p>${bi(o.join(`
`))}</p>`)}return n}function bi(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&e.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const tu=[{id:"recent",label:"최신순"},{id:"hot",label:"인기순"},{id:"trending",label:"급상승"},{id:"updated",label:"최근 갱신"},{id:"discussed",label:"토론 많은 순"}],Zs=g(null),ta=g([]),fn=g(!1),Ne=g(null),Dn=g(""),wn=g(!1),Ze=g(!0),lr=20,Ue=g(lr);function Yh(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Vh=g(Yh());function Xh(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"미리보기 없음"}function Ml(t){return t.updated_at!==t.created_at}function Qh(t){if(t.post_kind)return t.post_kind==="automation";const e=(t.hearth??"").toLowerCase();return t.visibility!=="internal"||!t.expires_at||!e?!1:!!(e.startsWith("mdal")||e.includes("harness"))}function Zh(t){return t==="lodge-system"||t==="team-session"}function os(t){return t.post_kind?t.post_kind:Zh(t.author)?"system":Qh(t)?"automation":"human"}function eu(t){const e=[],n=[];let s=0;return t.forEach(a=>{const o=os(a);if(!(o==="system"&&Re.value)){if(o==="automation"&&Ze.value){s+=1;return}if(o==="human"){e.push(a);return}n.push(a)}}),{human:e,operations:n,hiddenAutomation:s}}function ty(t){if(!t.expires_at)return null;const e=Date.parse(t.expires_at);return Number.isFinite(e)?e<=Date.now()?i`<span class="board-meta-chip">만료됨</span>`:i`<span class="board-meta-chip">만료까지 <${et} timestamp=${t.expires_at} /></span>`:null}async function cr(t){Ne.value=t,Zs.value=null,ta.value=[],fn.value=!0;try{const e=await Ip(t);if(Ne.value!==t)return;Zs.value={id:e.id,author:e.author,title:e.title,body:e.body,content:e.content,meta:e.meta,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,post_kind:e.post_kind,flair:e.flair,hearth:e.hearth,visibility:e.visibility,expires_at:e.expires_at,hearth_count:e.hearth_count},ta.value=e.comments??[]}catch{Ne.value===t&&(Zs.value=null,ta.value=[])}finally{Ne.value===t&&(fn.value=!1)}}async function El(t){const e=Dn.value.trim();if(e){wn.value=!0;try{await Rp(t,Vh.value,e),Dn.value="",j("댓글을 등록했습니다","success"),await cr(t),ue()}catch{j("댓글 등록에 실패했습니다","error")}finally{wn.value=!1}}}function ey(){const t=Un.value,e=Ze.value?"자동화 글 숨김":"자동화 글 표시 중";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${tu.map(n=>i`
          <button
            class="board-sort-btn ${t===n.id?"active":""}"
            onClick=${()=>{Un.value=n.id,Ue.value=lr,ue()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Ze.value?"is-active":""}"
          onClick=${()=>{Ze.value=!Ze.value}}
        >
          ${e}
        </button>
        <button
          class="control-btn ghost ${Re.value?"is-active":""}"
          onClick=${()=>{Re.value=!Re.value,ue()}}
        >
          ${Re.value?"시스템 글 숨김":"시스템 글 표시 중"}
        </button>
        <button class="control-btn ghost" onClick=${ue} disabled=${Wn.value}>
          ${Wn.value?"새로고침 중...":"새로고침"}
        </button>
      </div>
    </div>
  `}function ki(){var s;const t=((s=tu.find(a=>a.id===Un.value))==null?void 0:s.label)??Un.value,e=eu(Ja.value),n=e.human.length+e.operations.length;return i`
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
        <strong>${Ze.value?`자동화 ${e.hiddenAutomation}건 숨김`:"분리된 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">시스템 글 정책</span>
        <strong>${Re.value?"시스템 글 숨김":"시스템 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">최근 갱신</span>
        <strong>${so.value?i`<${et} timestamp=${so.value} />`:"아직 불러오지 않음"}</strong>
      </div>
    </div>
  `}function Ll({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await dc(t.id,n),ue()}catch{j("투표에 실패했습니다","error")}};return i`
    <div class="board-post" onClick=${()=>Su(t.id)}>
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
                ${Ml(t)?i`<span class="board-meta-chip">수정됨</span>`:null}
                ${os(t)!=="human"?i`<span class="board-meta-chip">${os(t)}</span>`:null}
                ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>작성자 ${t.author}</span>
            <span><${et} timestamp=${t.created_at} /></span>
            ${Ml(t)?i`<span>수정 <${et} timestamp=${t.updated_at} /></span>`:null}
            <span>댓글 ${t.comment_count}</span>
            <span>투표 ${t.votes??0}</span>
          </div>
        </div>
        <div class="post-snippet">${Xh(t.body)}</div>
      </div>
    </div>
  `}function ny({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">아직 댓글이 없습니다</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${et} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function sy({postId:t}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="댓글 추가..."
        value=${Dn.value}
        onInput=${e=>{Dn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&El(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${wn.value}
      />
      <button
        onClick=${()=>El(t)}
        disabled=${wn.value||Dn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${wn.value?"...":"등록"}
      </button>
    </div>
  `}function ay({post:t}){Ne.value!==t.id&&!fn.value&&cr(t.id);const e=async n=>{try{await dc(t.id,n),ue()}catch{j("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>it("memory")}>← 메모리로 돌아가기</button>
      <${R} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${Gh} text=${t.body} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${et} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          ${t.hearth||t.visibility||t.expires_at?i`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                  ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
                  ${os(t)!=="human"?i`<span class="board-meta-chip">${os(t)}</span>`:null}
                  ${ty(t)}
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
        ${fn.value?i`<div class="loading-indicator">댓글 불러오는 중...</div>`:i`<${ny} comments=${ta.value} />`}
        <${sy} postId=${t.id} />
      <//>
    </div>
  `}function iy(){const t=eu(Ja.value),e=[...t.human,...t.operations],n=w.value.params.post??null,s=n?e.find(a=>a.id===n)??(Ne.value===n?Zs.value:null):null;return n&&!s&&Ne.value!==n&&!fn.value&&cr(n),n?s?i`
          <${xt} surfaceId="memory" />
          <${ki} />
          <${ay} post=${s} />
        `:i`
          <div>
            <${xt} surfaceId="memory" />
            <${ki} />
            <button class="back-btn" onClick=${()=>it("memory")}>← 메모리로 돌아가기</button>
            ${fn.value?i`<div class="loading-indicator">글 불러오는 중...</div>`:i`<div class="empty-state">글을 찾지 못했습니다</div>`}
          </div>
        `:i`
    <div>
      <${xt} surfaceId="memory" />
      <${ki} />
      <${ey} />
      ${Wn.value?i`<div class="loading-indicator">메모리 피드 불러오는 중...</div>`:e.length===0?i`<div class="empty-state">지금은 남아 있는 메모리 글이 없습니다</div>`:i`
              <${R} title="사람이 쓴 글" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.human.slice(0,Ue.value).map(a=>i`<${Ll} key=${a.id} post=${a} />`)}
                </div>
                ${t.human.length>Ue.value?i`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{Ue.value=Ue.value+lr}}
                    >
                      더 보기 (${t.human.length-Ue.value}개 남음)
                    </button>
                  </div>
                `:null}
              <//>
              ${t.operations.length>0?i`
                    <${R} title="자동화 · 시스템" class="section" semanticId="memory.feed">
                      <div class="board-post-list">
                        ${t.operations.map(a=>i`<${Ll} key=${a.id} post=${a} />`)}
                      </div>
                    <//>
                  `:null}
            `}
    </div>
  `}const Te=g(null),Vt=g(null),Xt=g(null);function rs(t){return t==="bad"||t==="critical"||t==="offline"?"bad":t==="warn"||t==="paused"||t==="blocked"||t==="interrupted"?"warn":"ok"}function ls(t){switch((t??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":return"주의";case"bad":case"critical":return"위험";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function oy(t){return t==="session"?"세션":"작전"}function ry(t){return t?se.value.find(e=>e.name===t||e.agent_name===t)??null:null}function ly(t){switch(t){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function cy(t){switch(t){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function dy(t){switch(t){case"acted":return"행동";case"passed":return"통과";case"skipped":return"건너뜀";case"failed":return"실패";default:return t}}function uy(t){switch(t){case"post":return"post";case"comment":return"comment";case"vote":return"vote";case"none":case null:case void 0:return"none";default:return t}}function Pl(t){if(!t)return;const e=pf({targetType:t.target_type,targetId:t.target_id,focusKind:t.focus_kind,operationId:t.operation_id??null,commandSurface:t.command_surface??null,sourceLabel:"실행 진단",summary:t.label});_d(e),it(t.surface,t.surface==="intervene"?vd(e):gd(e))}function An({label:t,value:e,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function dr({intervene:t,command:e}){return i`
    <div class="control-row">
      ${t?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),Pl(t)}}
            >
              ${t.label}
            </button>
          `:null}
      ${e?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),Pl(e)}}
            >
              ${e.label}
            </button>
          `:null}
    </div>
  `}function py({item:t,selected:e}){return i`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{Te.value=e?null:t.id,Vt.value=null,Xt.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.kind==="session"?t.target_id:t.linked_session_id??t.target_id}</div>
          <div class="mission-card-title">${t.summary}</div>
        </div>
        <span class="command-chip ${rs(t.severity)}">${ls(t.status??t.severity)}</span>
      </div>
      <div class="mission-card-meta">
        <span>${oy(t.kind)}</span>
        ${t.linked_operation_id?i`<span>연결 작전 · ${t.linked_operation_id}</span>`:null}
        ${t.last_seen_at?i`<span><${et} timestamp=${t.last_seen_at} /></span>`:null}
      </div>
      <${dr} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function my({brief:t,selected:e}){return i`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.session-card"
      onClick=${()=>{Vt.value=e?null:t.session_id,Xt.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          <div class="mission-card-title">${t.goal}</div>
        </div>
        <span class="command-chip ${rs(t.health??t.status)}">${ls(t.status)}</span>
      </div>
      <div class="mission-card-meta">
        <span>건강도 · ${ls(t.health??"ok")}</span>
        ${t.linked_operation_id?i`<span>연결 작전 · ${t.linked_operation_id}</span>`:null}
        ${t.last_activity_at?i`<span><${et} timestamp=${t.last_activity_at} /></span>`:null}
      </div>
      ${t.runtime_blocker?i`<div class="mission-card-detail">${t.runtime_blocker}</div>`:t.last_activity_summary?i`<div class="mission-card-detail">${t.last_activity_summary}</div>`:null}
      ${t.worker_gap_summary?i`<div class="monitor-footnote">${t.worker_gap_summary}</div>`:null}
      <${dr} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function _y({brief:t,selected:e}){return i`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.operation-card"
      onClick=${()=>{Xt.value=e?null:t.operation_id,Vt.value=t.linked_session_id??null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.operation_id}${t.assigned_unit_label?` · ${t.assigned_unit_label}`:""}</div>
          <div class="mission-card-title">${t.objective}</div>
        </div>
        <span class="command-chip ${rs(t.blocker_summary?"warn":t.status)}">${ls(t.status)}</span>
      </div>
      <div class="mission-card-meta">
        ${t.stage?i`<span>단계 · ${t.stage}</span>`:null}
        ${t.linked_session_id?i`<span>세션 · ${t.linked_session_id}</span>`:null}
        ${t.updated_at?i`<span><${et} timestamp=${t.updated_at} /></span>`:null}
      </div>
      ${t.blocker_summary?i`<div class="mission-card-detail">${t.blocker_summary}</div>`:null}
      ${t.next_tool?i`<div class="monitor-footnote">다음 도구 · ${t.next_tool}</div>`:null}
      <${dr} command=${t.command_handoff} />
    </button>
  `}function vy({tick:t}){return t?i`
    <div class="monitor-nested-card">
      <div class="stats-grid">
        <${An} label="checked" value=${t.checked??0} color="#22d3ee" />
        <${An} label="acted" value=${t.acted??0} color="#4ade80" />
        <${An} label="passed" value=${t.passed??0} color="#94a3b8" />
        <${An} label="skipped" value=${t.skipped??0} color="#fbbf24" />
        <${An} label="failed" value=${t.failed??0} color="#fb7185" />
      </div>
      <div class="monitor-meta">
        ${t.last_tick_at?i`<span>마지막 tick <${et} timestamp=${t.last_tick_at} /></span>`:i`<span>마지막 tick 없음</span>`}
        ${t.last_skip_reason?i`<span>대표 skip 이유 · ${t.last_skip_reason}</span>`:null}
      </div>
      ${t.activity_report?i`<div class="monitor-footnote">${t.activity_report}</div>`:null}
    </div>
  `:i`<div class="empty-state">최근 lodge tick 기록이 없습니다.</div>`}function fy({row:t}){return i`
    <button
      class="monitor-row ${rs(t.outcome==="failed"?"bad":t.outcome==="skipped"?"warn":"ok")}"
      data-testid="execution.lodge-checkin-card"
      onClick=${()=>gs(t.agent_name)}
    >
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.agent_name}</span>
            ${t.worker_name?i`<span class="monitor-sub">worker · ${t.worker_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.reason??t.summary??"이유가 기록되지 않았습니다."}</div>
        </div>
        <span class="monitor-pill ${rs(t.outcome==="failed"?"bad":t.outcome==="skipped"?"warn":"ok")}">${dy(t.outcome)}</span>
      </div>
      <div class="monitor-meta">
        <span>trigger · ${t.trigger??"unknown"}</span>
        ${t.checked_at?i`<span><${et} timestamp=${t.checked_at} /></span>`:null}
        <span>action · ${uy(t.action_kind)}</span>
      </div>
      ${t.summary&&t.summary!==t.reason?i`<div class="monitor-focus">${t.summary}</div>`:null}
      ${t.failure_reason||t.decision_reason?i`<div class="monitor-footnote">
            ${t.failure_reason?`실패 이유: ${t.failure_reason}`:`판단 이유: ${t.decision_reason}`}
          </div>`:null}
    </button>
  `}function zl({row:t,testId:e}){return i`
    <button class="monitor-row ${t.tone} state-${t.state}" data-testid=${e} onClick=${()=>gs(t.name)}>
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
        <span class="monitor-pill ${t.tone} state-${t.state}">${ly(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.last_signal_at?i`<span>신호 <${et} timestamp=${t.last_signal_at} /></span>`:i`<span>최근 신호 없음</span>`}
        <span>${(t.active_task_count??0)>0?`활성 작업 ${t.active_task_count}개`:"활성 작업 없음"}</span>
        ${t.related_session_id?i`<span>세션 · ${t.related_session_id}</span>`:null}
        ${t.related_operation_id?i`<span>작전 · ${t.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${t.recent_output_preview&&t.recent_output_preview!==t.focus?i`<div class="monitor-footnote">최근 상세: ${t.recent_output_preview}</div>`:null}
    </button>
  `}function gy({row:t}){const e=()=>{const a=ry(t.name);a&&Ed(a)},n=Cd(t.name,t.agent_name),s={name:t.name,koreanName:t.korean_name??null,runtimeLabel:n,emoji:t.emoji??null,tone:t.tone,statusRaw:t.status??null,statusLabel:ls(t.status),stateClass:t.state,stateLabel:cy(t.state),contextRatio:t.context_ratio??null,note:t.note,focus:t.focus,lastActivityAt:t.last_signal_at??null,lastActivityFallback:"최근 활동 없음",relatedSessionId:t.related_session_id??null,continuity:t.continuity??null,lifecycle:t.lifecycle??null,summary:t.continuity_summary??t.recent_output_preview??null,recentInput:t.recent_input_preview??null,recentOutput:t.recent_output_preview??null,recentTools:t.recent_tool_names??[],allowedTools:t.allowed_tool_names??[],routeSummary:t.skill_route_summary??null,auditSource:t.tool_audit_source??null,auditAt:t.tool_audit_at??null,disclosureLabel:"연속성 상세"};return i`<${xd}
    variant="execution"
    model=${s}
    onClick=${e}
    testId="execution.continuity-card"
  />`}function $y(){const t=gc.value,e=$c.value,n=hc.value,s=yc.value,a=bc.value,o=kc.value,l=jo.value,c=xc.value;Te.value&&!t.some(h=>h.id===Te.value)&&(Te.value=null),Vt.value&&!e.some(h=>h.session_id===Vt.value)&&(Vt.value=null),Xt.value&&!n.some(h=>h.operation_id===Xt.value)&&(Xt.value=null);const d=Te.value?t.find(h=>h.id===Te.value)??null:null,m=Vt.value?Vt.value:d?d.kind==="session"?d.target_id:d.linked_session_id??null:null,p=Xt.value?Xt.value:d?d.kind==="operation"?d.target_id:d.linked_operation_id??null:null,v=m?e.filter(h=>h.session_id===m):p?e.filter(h=>h.linked_operation_id===p):e,f=p?n.filter(h=>h.operation_id===p):m?n.filter(h=>{var C;return h.linked_session_id===m||h.operation_id===((C=v[0])==null?void 0:C.linked_operation_id)}):n,$=m||p?s.filter(h=>(m?h.related_session_id===m:!1)||(p?h.related_operation_id===p:!1)):s,S=m?l.filter(h=>h.related_session_id===m||h.tone!=="ok"):l,y=m?o.filter(h=>v.some(C=>C.member_names.includes(h.agent_name))):o,k=m||p?c.filter(h=>(m?h.related_session_id===m:!1)||(p?h.related_operation_id===p:!1)||h.tone!=="ok"):c;return i`
    <div class="agents-monitor">
      <${xt} surfaceId="execution" />
      <${Xa} />
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
          ${t.length===0?i`<div class="empty-state">지금은 막힌 실행이 없습니다.</div>`:t.map(h=>i`<${py} key=${h.id} item=${h} selected=${Te.value===h.id} />`)}
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
            ${v.length===0?i`<div class="empty-state">선택된 실행과 연결된 세션이 없습니다.</div>`:v.map(h=>i`<${my} key=${h.session_id} brief=${h} selected=${Vt.value===h.session_id} />`)}
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
            ${f.length===0?i`<div class="empty-state">선택된 실행과 연결된 작전이 없습니다.</div>`:f.map(h=>i`<${_y} key=${h.operation_id} brief=${h} selected=${Xt.value===h.operation_id} />`)}
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
          <${vy} tick=${a} />
          <div class="monitor-list">
            ${y.length===0?i`<div class="empty-state">최근 lodge check-in 기록이 없습니다.</div>`:y.map(h=>i`<${fy} key=${`${h.agent_name}-${h.checked_at??h.outcome}`} row=${h} />`)}
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
            ${$.length===0?i`<div class="empty-state">연결된 작업자가 없습니다.</div>`:$.map(h=>i`<${zl} key=${h.name} row=${h} testId="execution.worker-card" />`)}
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
            ${S.length===0?i`<div class="empty-state">지금은 연속성 경고가 없습니다.</div>`:S.map(h=>i`<${gy} key=${h.name} row=${h} />`)}
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
            ${k.length===0?i`<div class="empty-state">지금은 오프라인 작업자가 없습니다.</div>`:k.map(h=>i`<${zl} key=${h.name} row=${h} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const go=g(null),$o=g(null),On=g(!1);async function Nl(){if(!On.value){On.value=!0,$o.value=null;try{go.value=await cp()}catch(t){$o.value=t instanceof Error?t.message:String(t)}finally{On.value=!1}}}function hy(t){switch(t){case"essential":return"badge-essential";case"standard":return"badge-standard";default:return"badge-full"}}function yy({items:t,maxCount:e}){return t.length===0?i`<p class="muted">No tool calls recorded yet.</p>`:i`
    <div class="tool-bar-chart">
      ${t.map(n=>{const s=e>0?n.call_count/e*100:0;return i`
          <div class="tool-bar-row" key=${n.name}>
            <span class="tool-bar-name">${n.name}</span>
            <span class="tool-bar-tier ${hy(n.tier)}">${n.tier}</span>
            <div class="tool-bar-track">
              <div class="tool-bar-fill" style=${{width:`${s}%`}} />
            </div>
            <span class="tool-bar-count">${n.call_count}</span>
          </div>
        `})}
    </div>
  `}function by({dist:t}){const e=t.full,n=e>0?(t.essential/e*100).toFixed(1):"0",s=e>0?(t.standard/e*100).toFixed(1):"0",a=e-t.standard,o=e>0?(a/e*100).toFixed(1):"0";return i`
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
  `}function ky(){const t=go.value,e=On.value,n=$o.value;return st(()=>{!go.value&&!On.value&&Nl()},[]),i`
    <div class="tool-metrics">
      <div class="tool-metrics-header">
        <h3 class="tool-metrics-title">Tool Usage</h3>
        <button
          class="control-btn ghost"
          onClick=${()=>void Nl()}
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
            <${by} dist=${t.tier_distribution} />
          </div>
          <div class="tool-metrics-section">
            <h4>Top 20 Tools</h4>
            <${yy}
              items=${t.top_20}
              maxCount=${t.top_20.length>0?t.top_20[0].call_count:0}
            />
          </div>
        </div>
      `:e?null:i`
        <p class="muted">Click Load to fetch tool usage statistics.</p>
      `}
    </div>
  `}const ho=g(null),yo=g(null),qn=g(!1),Tn=g(""),zs=g("all"),xi=g(!1),Si=g(!1),Ci=g(!0),Ai=g(!0);async function jl(){if(!qn.value){qn.value=!0,yo.value=null;try{ho.value=await dp()}catch(t){yo.value=t instanceof Error?t.message:String(t)}finally{qn.value=!1}}}function xy(t,e){const n=e.trim().toLowerCase();return n?[t.name,t.description,t.category,t.required_permission??"",t.visibility,t.lifecycle,t.implementationStatus,t.tier,t.canonicalName??"",t.replacement??"",t.reason??"",...t.doc_refs,...t.prompt_hints].join(" ").toLowerCase().includes(n):!0}function Ns(t,e="default"){return i`
    <span
      style=${{fontSize:"11px",color:e==="ok"?"#7dd3fc":e==="warn"?"#fbbf24":"#cbd5e1",background:e==="ok"?"rgba(14, 165, 233, 0.18)":e==="warn"?"rgba(245, 158, 11, 0.18)":"rgba(148, 163, 184, 0.16)",borderRadius:"999px",padding:"2px 8px"}}
    >
      ${t}
    </span>
  `}function Sy({item:t}){return i`
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
  `}function Cy(){const t=ho.value,e=qn.value,n=yo.value,s=(t==null?void 0:t.tool_inventory.tools)??[],a=(t==null?void 0:t.tool_usage)??null;st(()=>{!ho.value&&!qn.value&&jl()},[]),st(()=>{var $;if(w.value.tab!=="tools")return;const f=($=w.value.params.q)==null?void 0:$.trim();f&&f!==Tn.value&&(Tn.value=f)},[w.value.tab,w.value.params.q]);const o=Array.from(new Set(s.map(f=>f.category))).sort((f,$)=>f.localeCompare($)),l=s.filter(f=>!(!xy(f,Tn.value)||zs.value!=="all"&&f.category!==zs.value||xi.value&&!f.enabled_in_current_mode||Si.value&&!f.direct_call_allowed||!Ci.value&&f.visibility==="hidden"||!Ai.value&&f.lifecycle==="deprecated")),c=s.length,d=s.filter(f=>f.enabled_in_current_mode).length,m=s.filter(f=>f.visibility==="hidden").length,p=s.filter(f=>f.lifecycle==="deprecated").length,v=s.filter(f=>f.direct_call_allowed).length;return i`
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
            <span class="stat-value">${d}</span>
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
            value=${Tn.value}
            onInput=${f=>{Tn.value=f.target.value}}
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
              checked=${xi.value}
              onChange=${f=>{xi.value=f.target.checked}}
            />
            <span>Enabled only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${Si.value}
              onChange=${f=>{Si.value=f.target.checked}}
            />
            <span>Direct-call only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${Ci.value}
              onChange=${f=>{Ci.value=f.target.checked}}
            />
            <span>Show hidden</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${Ai.value}
              onChange=${f=>{Ai.value=f.target.checked}}
            />
            <span>Show deprecated</span>
          </label>
          <button class="control-btn ghost" onClick=${()=>{jl()}} disabled=${e}>
            ${e?"Refreshing…":"Refresh inventory"}
          </button>
        </div>

        ${n?i`<div class="tool-metrics-error">${n}</div>`:null}

        <div class="tool-inventory-list">
          ${l.length>0?l.map(f=>i`<${Sy} key=${f.name} item=${f} />`):i`<div class="empty-state">No tools matched the current filters.</div>`}
        </div>
      <//>

      <${R} title="Tool Usage" class="section">
        ${a?i`
              <div class="tool-inventory-usage-hint">
                Registered ${a.registered_count} · Distinct called ${a.distinct_tools_called} · Never called ${a.never_called_count}
              </div>
            `:null}
        <${ky} />
      <//>
    </div>
  `}const Da=g("all"),wa=g("all"),bo=g(new Set);function Ay(t){const e=new Set(bo.value);e.has(t)?e.delete(t):e.add(t),bo.value=e}const nu=Mt(()=>{let t=nn.value;return Da.value!=="all"&&(t=t.filter(e=>e.horizon===Da.value)),wa.value!=="all"&&(t=t.filter(e=>e.status===wa.value)),t}),Ty=Mt(()=>{const t={short:[],mid:[],long:[]};for(const e of nu.value){const n=t[e.horizon];n&&n.push(e)}return t}),Iy=Mt(()=>{const t=Array.from(Cc.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function Ry(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function ur(t){switch(t){case"short":return"단기";case"mid":return"중기";case"long":return"장기";default:return t}}function ea(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function My(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Dl(t){return t.toFixed(4)}function wl(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function Ey(t){switch(t){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function Ly(t){switch(t){case"active":return"진행 중";case"completed":return"완료";case"paused":return"일시정지";default:return"전체"}}function Ol(t,e){return(t.priority??4)-(e.priority??4)}function Py(t,e){const n=t.updated_at??t.created_at??"";return(e.updated_at??e.created_at??"").localeCompare(n)}function zy(t,e){return t.length<=e?t:t.slice(0,e)+"..."}function Ny({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ea(t.horizon)}">
            ${ur(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${Ry(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${et} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${ye} status=${t.status} />
        <div class="goal-updated">
          <${et} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Ti({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return i`
    <${R} title="${ur(t)} 목표 (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${Ny} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function jy(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">범위</label>
        ${["all","short","mid","long"].map(t=>i`
          <button
            class="goal-filter-btn ${Da.value===t?"active":""}"
            onClick=${()=>{Da.value=t}}
          >
            ${t==="all"?"전체":ur(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">상태</label>
        ${["all","active","completed","paused"].map(t=>i`
          <button
            class="goal-filter-btn ${wa.value===t?"active":""}"
            onClick=${()=>{wa.value=t}}
          >
            ${Ly(t)}
          </button>
        `)}
      </div>
    </div>
  `}function Dy(){const t=nn.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return i`
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
  `}function wy({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length}개 도구: ${t.latest_tool_names.join(", ")}`:"아직 근거 없음";return i`
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
          <span>Baseline ${Dl(t.baseline_metric)}</span>
          <span>현재 ${Dl(t.current_metric)}</span>
          <span class=${wl(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${wl(t)}
          </span>
          <span>Elapsed ${My(t.elapsed_seconds)}</span>
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
  `}function Ii({task:t}){const e=t.priority??4,n=e<=1?"p1":e===2?"p2":e===3?"p3":"p4",s=bo.value.has(t.id),a=!!t.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${Ey(e)}</span>
        <div class="kanban-card-title">${t.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>Ay(t.id)}
        >
          ${s?t.description:zy(t.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${t.created_at?i`<${et} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Oy(){const{todo:t,inProgress:e,done:n}=Tc.value,s=[...t].sort(Ol),a=[...e].sort(Ol),o=[...n].sort(Py);return i`
    <${R} title="태스크 백로그" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>할 일</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">대기 중인 태스크가 없습니다</div>`:s.map(l=>i`<${Ii} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>진행 중</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">진행 중인 태스크가 없습니다</div>`:a.map(l=>i`<${Ii} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>완료</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">완료된 태스크가 없습니다</div>`:o.slice(0,20).map(l=>i`<${Ii} key=${l.id} task=${l} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...외 ${o.length-20}개 더 있음</div>`:null}
        </div>
      </div>
    <//>
  `}function qy(){const{todo:t,inProgress:e,done:n}=Tc.value,s=t.length+e.length+n.length,a=[...t,...e].filter(p=>(p.priority??4)<=2).length,o=Ty.value,l=Iy.value,c=nn.value.length>0,d=l.length>0,m=Do.value;return i`
    <div>
      <${xt} surfaceId="planning" />

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
          onClick=${()=>{qo(),zc()}}
          disabled=${Ln.value||Pn.value}
        >
          ${Ln.value||Pn.value?"새로고침 중...":"계획 데이터 새로고침"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${Oy} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          목표 파이프라인
          <span class="monitor-pill">${nn.value.length}</span>
        </summary>
        <div>
          ${c?i`
            <${Dy} />
            <${jy} />
            ${Ln.value&&nn.value.length===0?i`<div class="loading-indicator">목표 불러오는 중...</div>`:nu.value.length===0?i`<div class="empty-state">현재 필터에 맞는 목표가 없습니다</div>`:i`
                    <${Ti} horizon="short" items=${o.short??[]} />
                    <${Ti} horizon="mid" items=${o.mid??[]} />
                    <${Ti} horizon="long" items=${o.long??[]} />
                  `}
          `:i`
            <div class="empty-state">
              정의된 목표가 없습니다. <code>masc_goal_upsert</code>로 목표를 만들 수 있습니다.
            </div>
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible" open=${d}>
        <summary>
          MDAL 루프
          <span class="monitor-pill">${l.length}</span>
        </summary>
        <div>
          ${Pn.value&&l.length===0?i`<div class="loading-indicator">MDAL 루프 불러오는 중...</div>`:l.length===0&&(m==="error"||sn.value)?i`<div class="empty-state">MDAL 스냅샷을 불러오지 못했습니다${sn.value?`: ${sn.value}`:""}. 백엔드 상태를 확인하세요.</div>`:l.length===0?i`<div class="empty-state">가동 중인 루프가 없습니다. <code>masc_mdal_start</code>로 시작할 수 있습니다.</div>`:i`
                  <div class="planning-loop-list">
                    ${l.map(p=>i`<${wy} key=${p.loop_id} loop=${p} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const Oa=g(!1),Fn=g(!1),tn=g(!1),ge=g(""),Bn=g(""),ko=g("open"),Ft=g(null),cs=g(null),qa=g(null),Fa=g(null),xo=g(!1);function ds(t){return`${t.kind}:${t.id}`}function pr(){var n;const t=cs.value,e=((n=Ft.value)==null?void 0:n.items)??[];return t?e.find(s=>ds(s)===t)??null:null}function Fy(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");return(e==null?void 0:e.trim())||"dashboard"}function By(t){const e=t.trim().toLowerCase();return e==="open"||e==="pending"}function su(t){return!!(t.judgment_summary&&t.judgment_summary.trim())}function au(t){switch(ko.value){case"needs_quorum":return t.filter(e=>e.kind==="consensus"&&(e.votes??0)<(e.quorum??0));case"ready":return t.filter(e=>{var n;return(n=e.guardrail_state)==null?void 0:n.ready_to_execute});case"needs_approval":return t.filter(e=>{var n,s;return((n=e.guardrail_state)==null?void 0:n.requires_human_gate)||!!((s=e.guardrail_state)!=null&&s.pending_confirm)});case"judge_offline":return t.filter(e=>!su(e));case"open":default:return t.filter(e=>By(e.status))}}function Ky(t){if(t==null)return"없음";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function si(t){const e=(t||"").toLowerCase();return e.includes("reject")||e.includes("deny")||e.includes("closed")||e.includes("cancel")?"negative":e.includes("approve")||e.includes("support")||e.includes("open")||e.includes("ready")?"positive":"neutral"}function Uy(t){return typeof t!="number"||Number.isNaN(t)?"확인 필요":`${Math.round(t*100)}%`}function In(t){return"resolved_tool"in t||"payload_preview"in t||"reason"in t}async function iu(t){if(qa.value=null,Fa.value=null,!!t){xo.value=!0,ge.value="";try{t.kind==="debate"?qa.value=await nm(t.id):Fa.value=await sm(t.id)}catch(e){ge.value=e instanceof Error?e.message:"거버넌스 상세를 불러오지 못했습니다"}finally{xo.value=!1}}}async function Wy(t){cs.value=ds(t),await iu(t)}async function gn(){var t;Oa.value=!0,ge.value="";try{const e=await np();Ft.value=e;const n=au(e.items??[]),s=cs.value,a=n.find(o=>ds(o)===s)??n[0]??((t=e.items)==null?void 0:t[0])??null;cs.value=a?ds(a):null,await iu(a)}catch(e){ge.value=e instanceof Error?e.message:"거버넌스 상태를 불러오지 못했습니다"}finally{Oa.value=!1}}f_(gn);async function ql(){const t=Bn.value.trim();if(t){Fn.value=!0;try{const e=await em(t);Bn.value="",j(e!=null&&e.id?`토론을 시작했습니다: ${e.id}`:"토론을 시작했습니다","success"),await gn()}catch(e){const n=e instanceof Error?e.message:"토론 시작에 실패했습니다";ge.value=n,j(n,"error")}finally{Fn.value=!1}}}async function Fl(t){var o,l;const e=pr(),n=(o=e==null?void 0:e.guardrail_state)==null?void 0:o.pending_confirm,s=n==null?void 0:n.confirm_token;if(!s)return;const a=((l=n==null?void 0:n.actor)==null?void 0:l.trim())||Fy();tn.value=!0;try{await ac(a,s,t),j(t==="confirm"?"액션을 승인했습니다":"액션을 거부했습니다","success"),await gn()}catch(c){const d=c instanceof Error?c.message:"대기 중인 액션 처리에 실패했습니다";ge.value=d,j(d,"error")}finally{tn.value=!1}}function Hy(){var n,s,a,o,l,c;const t=(n=Ft.value)==null?void 0:n.summary,e=(s=Ft.value)==null?void 0:s.judge;return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">열린 토론</span>
        <strong>${(t==null?void 0:t.debates_open)??((o=(a=Ft.value)==null?void 0:a.debates)==null?void 0:o.length)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">합의 세션</span>
        <strong>${(t==null?void 0:t.sessions_active)??((c=(l=Ft.value)==null?void 0:l.sessions)==null?void 0:c.length)??0}</strong>
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
  `}function Gy(){return i`
    <${R} title="거버넌스 콘솔" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="토론 주제를 입력하세요..."
            value=${Bn.value}
            onInput=${t=>{Bn.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&ql()}}
            disabled=${Fn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${ql}
            disabled=${Fn.value||Bn.value.trim()===""}
          >
            ${Fn.value?"시작 중...":"토론 시작"}
          </button>
          <button class="control-btn ghost" onClick=${gn} disabled=${Oa.value}>
            ${Oa.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
        <div class="governance-filter-row">
          ${[["open","열림"],["needs_quorum","정족수 부족"],["ready","준비됨"],["needs_approval","승인 필요"],["judge_offline","판정기 오프라인"]].map(([t,e])=>i`
            <button
              class="control-btn ${ko.value===t?"is-active":"ghost"}"
              onClick=${async()=>{ko.value=t,await gn()}}
            >
              ${e}
            </button>
          `)}
        </div>
        ${ge.value?i`<div class="council-error">${ge.value}</div>`:null}
      </div>
    <//>
  `}function Jy(){var e;const t=au(((e=Ft.value)==null?void 0:e.items)??[]);return i`
    <${R} title="의사결정 수신함" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${t.length===0?i`
              <div class="empty-state">
                지금 필터에 맞는 토론이나 합의 세션이 없습니다.
              </div>
            `:t.map(n=>{var a,o;const s=cs.value===ds(n);return i`
                <button
                  class="council-row governance-decision-row ${s?"selected":""}"
                  onClick=${()=>Wy(n)}
                >
                  <div class="council-row-main">
                    <div class="governance-row-head">
                      <span class="governance-kind">${n.kind}</span>
                      <span class="council-topic">${n.topic}</span>
                    </div>
                    <div class="council-sub">
                      <span>${n.truth_summary||"사실 요약이 아직 없습니다"}</span>
                      ${n.last_activity_at?i`<span><${et} timestamp=${n.last_activity_at} /></span>`:null}
                    </div>
                    <div class="governance-chip-row">
                      ${(a=n.guardrail_state)!=null&&a.requires_human_gate?i`<span class="governance-chip warn">승인 필요</span>`:null}
                      ${(o=n.guardrail_state)!=null&&o.ready_to_execute?i`<span class="governance-chip ok">준비됨</span>`:null}
                      ${n.kind==="consensus"&&(n.votes??0)<(n.quorum??0)?i`<span class="governance-chip warn">정족수 부족</span>`:null}
                      ${su(n)?null:i`<span class="governance-chip dim">판정기 오프라인</span>`}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${si(n.status)}">${n.status}</span>
                    ${n.kind==="consensus"?i`<span class="governance-vote-meter">${n.votes??0}/${n.quorum??0}</span>`:i`<span class="governance-vote-meter">${n.evidence_refs.length} refs</span>`}
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function Yy({argument:t}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${si(t.position)}">${t.position}</span>
        <strong>${t.agent}</strong>
        ${t.created_at?i`<span><${et} timestamp=${t.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${t.content}</div>
      <div class="governance-chip-row">
        ${t.evidence.map(e=>i`<span class="governance-chip">${e}</span>`)}
        ${t.reply_to!=null?i`<span class="governance-chip">답글 #${t.reply_to}</span>`:null}
        ${t.mentions.map(e=>i`<span class="governance-chip">@${e}</span>`)}
        ${t.archetype?i`<span class="governance-chip dim">${t.archetype}</span>`:null}
      </div>
    </div>
  `}function Vy({vote:t}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${si(t.decision)}">${t.decision}</span>
        <strong>${t.agent}</strong>
        ${t.timestamp?i`<span><${et} timestamp=${t.timestamp} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${t.reason||"기록된 이유가 없습니다."}</div>
      <div class="governance-chip-row">
        ${t.weight!=null?i`<span class="governance-chip">가중치 ${t.weight}</span>`:null}
        ${t.archetype?i`<span class="governance-chip dim">${t.archetype}</span>`:null}
      </div>
    </div>
  `}function Xy(){const t=pr(),e=qa.value,n=Fa.value;return i`
    <${R}
      title=${t?`${t.kind==="debate"?"토론":"합의"} 상세`:"의사결정 상세"}
      class="section"
      semanticId="governance.detail"
    >
      ${xo.value?i`<div class="loading-indicator">거버넌스 상세 불러오는 중...</div>`:t?t.kind==="debate"&&e?i`
                <div class="governance-detail-head">
                  <div>
                    <h3>${e.debate.topic}</h3>
                    <div class="council-sub">
                      <span>${e.debate.id}</span>
                      <span>${e.debate.status}</span>
                      ${e.debate.created_at?i`<span><${et} timestamp=${e.debate.created_at} /></span>`:null}
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
                  ${e.arguments.length===0?i`<div class="empty-state">기록된 토론이 아직 없습니다.</div>`:e.arguments.map(s=>i`<${Yy} key=${s.index} argument=${s} />`)}
                </div>
              `:t.kind==="consensus"&&n?i`
                  <div class="governance-detail-head">
                    <div>
                      <h3>${n.session.topic}</h3>
                      <div class="council-sub">
                        <span>${n.session.id}</span>
                        <span>${n.session.state}</span>
                      <span>시작자 ${n.session.initiator}</span>
                        ${n.session.created_at?i`<span><${et} timestamp=${n.session.created_at} /></span>`:null}
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
                    ${n.votes.length===0?i`<div class="empty-state">기록된 표결이 아직 없습니다.</div>`:n.votes.map(s=>i`<${Vy} key=${s.agent+s.timestamp} vote=${s} />`)}
                  </div>
                `:i`<div class="empty-state">이 의사결정의 상세를 아직 읽을 수 없습니다.</div>`:i`<div class="empty-state">사실 계층과 판단을 보려면 의사결정 항목을 고르세요.</div>`}
    <//>
  `}function Bl({title:t,route:e}){if(!e)return null;const n=In(e)?e.resolved_tool:e.delegated_tool,s=In(e)?e.target_type:null,a=In(e)?e.target_id:null,o=In(e)?e.reason:null,l=In(e)?e.payload_preview:null;return i`
    <div class="governance-side-block">
      <h4>${t}</h4>
      <div class="council-sub">
        ${n?i`<span>도구 ${n}</span>`:null}
        ${"action_type"in e&&e.action_type?i`<span>액션 ${e.action_type}</span>`:null}
        ${"confirmation_state"in e&&e.confirmation_state?i`<span>${e.confirmation_state}</span>`:null}
        ${"created_at"in e&&e.created_at?i`<span><${et} timestamp=${e.created_at} /></span>`:null}
      </div>
      ${s?i`<div class="governance-side-line">대상 ${s}${a?`:${a}`:""}</div>`:null}
      ${o?i`<div class="governance-side-line">${o}</div>`:null}
      ${l?i`<pre class="council-detail governance-preview">${Ky(l)}</pre>`:null}
    </div>
  `}function Qy(){var c,d,m;const t=pr(),e=qa.value,n=Fa.value,s=(e==null?void 0:e.context)??(n==null?void 0:n.context)??(t==null?void 0:t.context),a=(e==null?void 0:e.judgment)??(n==null?void 0:n.judgment),o=t==null?void 0:t.guardrail_state,l=(c=Ft.value)==null?void 0:c.judge;return i`
    <div class="governance-side-column">
      <${R} title="이유 / 가드레일" class="section" semanticId="governance.guardrail">
        ${t?i`
              <div class="governance-side-block">
                <h4>판정기</h4>
                <div class="council-sub">
                  <span>${l!=null&&l.judge_online?"온라인":"오프라인"}</span>
                  ${l!=null&&l.model_used?i`<span>${l.model_used}</span>`:null}
                  ${l!=null&&l.generated_at?i`<span><${et} timestamp=${l.generated_at} /></span>`:null}
                </div>
                ${t.judgment_summary?i`<div class="governance-summary-callout">${t.judgment_summary}</div>`:i`<div class="governance-side-line">현재 LLM 판단이 없어 사실 계층만 보여줍니다.</div>`}
                <div class="council-sub">
                  <span>신뢰도 ${Uy(t.confidence)}</span>
                  ${a!=null&&a.keeper_name?i`<span>${a.keeper_name}</span>`:null}
                </div>
              </div>

              <${Bl} title="추천 경로" route=${t.recommended_action} />
              <${Bl} title="실행된 경로" route=${t.executed_route} />

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
                          onClick=${()=>Fl("confirm")}
                          disabled=${tn.value}
                        >
                          ${tn.value?"처리 중...":"승인"}
                        </button>
                        <button
                          class="control-btn ghost"
                          onClick=${()=>Fl("deny")}
                          disabled=${tn.value}
                        >
                          ${tn.value?"처리 중...":"거부"}
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
                        ${t.related_agents.map(p=>i`<span class="governance-chip dim">${p}</span>`)}
                      </div>
                    `:i`<div class="governance-side-line">명시적으로 연결된 맥락 기록이 없습니다.</div>`}
                ${t.evidence_refs.length>0?i`
                      <div class="governance-side-line">근거 참조</div>
                      <div class="governance-chip-row">
                        ${t.evidence_refs.map(p=>i`<span class="governance-chip">${p}</span>`)}
                      </div>
                    `:null}
              </div>
          `:i`<div class="empty-state">선택된 맥락이 없습니다.</div>`}
      <//>

      <${R} title="최근 활동" class="section" semanticId="governance.activity">
        <div class="governance-activity-list">
          ${(((d=Ft.value)==null?void 0:d.activity)??[]).slice(0,8).map(p=>i`
            <div class="governance-activity-row">
              <div class="governance-ledger-head">
                <span class="governance-badge ${si(p.kind)}">${p.kind}</span>
                ${p.actor?i`<strong>${p.actor}</strong>`:null}
                ${p.created_at?i`<span><${et} timestamp=${p.created_at} /></span>`:null}
              </div>
              <div class="governance-ledger-body">${p.summary||p.topic||"활동이 기록되었습니다."}</div>
            </div>
          `)}
          ${(((m=Ft.value)==null?void 0:m.activity)??[]).length===0?i`<div class="empty-state">기록된 거버넌스 활동이 없습니다.</div>`:null}
        </div>
      <//>
    </div>
  `}function Zy(){return st(()=>{gn()},[]),i`
    <div>
      <${xt} surfaceId="governance" />
      <${Hy} />
      <${Gy} />
      <div class="governance-layout">
        <${Jy} />
        <${Xy} />
        <${Qy} />
      </div>
    </div>
  `}const We=g(""),Ri=g("ability_check"),Mi=g("10"),Ei=g("12"),js=g(""),Ds=g("idle"),oe=g(""),ws=g("keeper-late"),Li=g("player"),Pi=g(""),Ct=g("idle"),zi=g(null),Os=g(""),Ni=g(""),ji=g("player"),Di=g(""),wi=g(""),Oi=g(""),Kn=g("20"),qi=g("20"),Fi=g(""),qs=g("idle"),So=g(null),ou=g("overview"),Bi=g("all"),Ki=g("all"),Ui=g("all"),tb=12e4,ai=g(null),Kl=g(Date.now());function eb(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function nb(t,e){return e>0?Math.round(t/e*100):0}const sb={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},ab={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Fs(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function ib(t){const e=t.trim().toLowerCase();return sb[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function ob(t){const e=t.trim().toLowerCase();return ab[e]??"상황에 따라 선택되는 전술 액션입니다."}function bt(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Nt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function us(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const rb=new Set(["str","dex","con","int","wis","cha"]);function lb(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!_(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const l=a.trim();if(l){if(typeof o=="number"&&Number.isFinite(o)){s[l]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const c=Number.parseFloat(o.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function cb(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(Kn.value.trim(),10);Number.isFinite(s)&&s>n&&(Kn.value=String(n))}function Co(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function db(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function ub(t){ou.value=t}function ru(t){const e=ai.value;return e==null||e<=t}function pb(t){const e=ai.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Ba(){ai.value=null}function lu(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function mb(t,e){lu(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(ai.value=Date.now()+tb,j("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function na(t){return ru(t)?(j("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Ao(t,e,n){return lu([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function _b({hp:t,max:e}){const n=nb(t,e),s=eb(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function vb({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function fb({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function cu({actor:t}){var d,m,p,v;const e=(d=t.archetype)==null?void 0:d.trim(),n=(m=t.persona)==null?void 0:m.trim(),s=(p=t.portrait)==null?void 0:p.trim(),a=(v=t.background)==null?void 0:v.trim(),o=t.traits??[],l=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([f,$])=>Number.isFinite($)).filter(([f])=>!rb.has(f.toLowerCase()));return i`
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
        <${ye} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${fb} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${_b} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${vb} stats=${t.stats} />
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
                  <span class="trpg-annot-desc">${ib(f)}</span>
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
                  <span class="trpg-annot-desc">${ob(f)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function gb({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function du({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${db(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Co(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${et} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function $b({events:t}){const e="__none__",n=Bi.value,s=Ki.value,a=Ui.value,o=Array.from(new Set(t.map(Co).map(v=>v.trim()).filter(v=>v!==""))).sort((v,f)=>v.localeCompare(f)),l=Array.from(new Set(t.map(v=>(v.type??"").trim()).filter(v=>v!==""))).sort((v,f)=>v.localeCompare(f)),c=t.some(v=>(v.type??"").trim()===""),d=Array.from(new Set(t.map(v=>(v.phase??"").trim()).filter(v=>v!==""))).sort((v,f)=>v.localeCompare(f)),m=t.some(v=>(v.phase??"").trim()===""),p=t.filter(v=>{if(n!=="all"&&Co(v)!==n)return!1;const f=(v.type??"").trim(),$=(v.phase??"").trim();if(s===e){if(f!=="")return!1}else if(s!=="all"&&f!==s)return!1;if(a===e){if($!=="")return!1}else if(a!=="all"&&$!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${v=>{Bi.value=v.target.value}}>
          <option value="all">all</option>
          ${o.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${v=>{Ki.value=v.target.value}}>
          <option value="all">all</option>
          ${c?i`<option value=${e}>(none)</option>`:null}
          ${l.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${v=>{Ui.value=v.target.value}}>
          <option value="all">all</option>
          ${m?i`<option value=${e}>(none)</option>`:null}
          ${d.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Bi.value="all",Ki.value="all",Ui.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${p.length} / 전체 ${t.length}
      </span>
    </div>
    <${du} events=${p.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function hb({outcome:t}){if(!t)return null;const e=o=>{const l=o.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function uu({state:t}){const e=t.history??[];return e.length===0?null:i`
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
  `}function yb({state:t,nowMs:e}){var m;const n=te.value||((m=t.session)==null?void 0:m.room)||"",s=Ds.value,a=t.party??[];if(!a.find(p=>p.id===We.value)&&a.length>0){const p=a[0];p&&(We.value=p.id)}const l=async()=>{var v,f;if(!n){j("Room ID가 비어 있습니다.","error");return}if(!na(e))return;const p=((v=t.current_round)==null?void 0:v.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(Ao("라운드 실행",n,p)){Ds.value="running";try{const $=await Up(n);So.value=$,Ds.value="ok";const S=_($.summary)?$.summary:null,y=S?us(S,"advanced",!1):!1,k=S?bt(S,"progress_reason",""):"";j(y?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${k?`: ${k}`:""}`,y?"success":"warning"),pe()}catch($){So.value=null,Ds.value="error";const S=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";j(S,"error")}finally{Ba()}}},c=async()=>{var v,f;if(!n||!na(e))return;const p=((v=t.current_round)==null?void 0:v.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(Ao("턴 강제 진행",n,p))try{await Gp(n),j("턴을 다음 단계로 이동했습니다.","success"),pe()}catch{j("턴 이동에 실패했습니다.","error")}finally{Ba()}},d=async()=>{if(!n||!na(e))return;const p=We.value.trim();if(!p){j("먼저 Actor를 선택하세요.","warning");return}const v=Number.parseInt(Mi.value,10),f=Number.parseInt(Ei.value,10);if(Number.isNaN(v)||Number.isNaN(f)){j("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(js.value,10),S=js.value.trim()===""||Number.isNaN($)?void 0:$;try{await Hp({roomId:n,actorId:p,action:Ri.value.trim()||"ability_check",statValue:v,dc:f,rawD20:S}),j("주사위 판정을 기록했습니다.","success"),pe()}catch{j("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${p=>{te.value=p.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${We.value}
            onChange=${p=>{We.value=p.target.value}}
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
              value=${Ri.value}
              onInput=${p=>{Ri.value=p.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Mi.value}
              onInput=${p=>{Mi.value=p.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ei.value}
              onInput=${p=>{Ei.value=p.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${js.value}
              onInput=${p=>{js.value=p.target.value}}
              onKeyDown=${p=>{p.key==="Enter"&&d()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${d}>Roll</button>
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
  `}function bb({state:t}){var a;const e=te.value||((a=t.session)==null?void 0:a.room)||"",n=qs.value,s=async()=>{if(!e){j("Room ID가 비어 있습니다.","warning");return}const o=Os.value.trim(),l=Ni.value.trim();if(!l&&!o){j("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Kn.value.trim(),10),d=Number.parseInt(qi.value.trim(),10),m=Number.isFinite(d)?Math.max(1,d):20,p=Number.isFinite(c)?Math.max(0,Math.min(m,c)):m;let v={};try{v=lb(Fi.value)}catch(f){j(f instanceof Error?f.message:"능력치 JSON 오류","error");return}qs.value="spawning";try{const f=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await Jp(e,{actor_id:o||void 0,name:l||void 0,role:ji.value,idempotencyKey:f,portrait:wi.value.trim()||void 0,background:Oi.value.trim()||void 0,hp:p,max_hp:m,alive:p>0,stats:Object.keys(v).length>0?v:void 0}),S=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!S)throw new Error("생성 응답에 actor_id가 없습니다.");const y=Di.value.trim();y&&await Yp(e,S,y),We.value=S,oe.value=S,o||(Os.value=""),qs.value="ok",j(`Actor 생성 완료: ${S}`,"success"),await pe()}catch(f){qs.value="error",j(f instanceof Error?f.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Ni.value}
            onInput=${o=>{Ni.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${ji.value}
            onChange=${o=>{ji.value=o.target.value}}
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
            value=${Di.value}
            onInput=${o=>{Di.value=o.target.value}}
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
              value=${Os.value}
              onInput=${o=>{Os.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${wi.value}
              onInput=${o=>{wi.value=o.target.value}}
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
              value=${Kn.value}
              onInput=${o=>{Kn.value=o.target.value}}
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
              value=${qi.value}
              onInput=${o=>{const l=o.target.value;qi.value=l,cb(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Oi.value}
              onInput=${o=>{Oi.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Fi.value}
              onInput=${o=>{Fi.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function kb({state:t,nowMs:e}){var f;const n=te.value||((f=t.session)==null?void 0:f.room)||"",s=t.join_gate,a=zi.value,o=_(a)?a:null,l=(t.party??[]).filter($=>$.role!=="dm"),c=oe.value.trim(),d=l.some($=>$.id===c),m=d?c:c?"__manual__":"",p=async()=>{const $=oe.value.trim(),S=ws.value.trim();if(!n||!$){j("Room/Actor가 필요합니다.","warning");return}Ct.value="checking";try{const y=await Vp(n,$,S||void 0);zi.value=y,Ct.value="ok",j("참가 가능 여부를 갱신했습니다.","success")}catch(y){Ct.value="error";const k=y instanceof Error?y.message:"참가 가능 여부 확인에 실패했습니다.";j(k,"error")}},v=async()=>{var h,C;const $=oe.value.trim(),S=ws.value.trim(),y=Pi.value.trim();if(!n||!$||!S){j("Room/Actor/Keeper가 필요합니다.","warning");return}if(!na(e))return;const k=((h=t.current_round)==null?void 0:h.phase)??((C=t.session)==null?void 0:C.status)??"unknown";if(Ao("Mid-Join 승인 요청",n,k)){Ct.value="requesting";try{const M=await Xp({room_id:n,actor_id:$,keeper_name:S,role:Li.value,...y?{name:y}:{}});zi.value=M;const T=_(M)?us(M,"granted",!1):!1,P=_(M)?bt(M,"reason_code",""):"";T?j("Mid-Join이 승인되었습니다.","success"):j(`Mid-Join이 거절되었습니다${P?`: ${P}`:""}`,"warning"),Ct.value=T?"ok":"error",pe()}catch(M){Ct.value="error";const T=M instanceof Error?M.message:"Mid-Join 요청에 실패했습니다.";j(T,"error")}finally{Ba()}}};return i`
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
            onChange=${$=>{const S=$.target.value;if(S==="__manual__"){(d||!c)&&(oe.value="");return}oe.value=S}}
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
                value=${oe.value}
                onInput=${$=>{oe.value=$.target.value}}
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
            value=${ws.value}
            onInput=${$=>{ws.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Li.value}
            onChange=${$=>{Li.value=$.target.value}}
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
            value=${Pi.value}
            onInput=${$=>{Pi.value=$.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${p} disabled=${Ct.value==="checking"||Ct.value==="requesting"}>
              ${Ct.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${v} disabled=${Ct.value==="checking"||Ct.value==="requesting"}>
              ${Ct.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${us(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Nt(o,"effective_score",0)}/${Nt(o,"required_points",0)}</span>
            ${bt(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${bt(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function pu({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function mu({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function _u(){const t=So.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=_(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(_).slice(-8),o=t.canon_check,l=_(o)?o:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(P=>typeof P=="string").slice(0,3):[],d=l&&Array.isArray(l.violations)?l.violations.filter(P=>typeof P=="string").slice(0,3):[],m=n?us(n,"advanced",!1):!1,p=n?bt(n,"progress_reason",""):"",v=n?bt(n,"progress_detail",""):"",f=n?Nt(n,"player_successes",0):0,$=n?Nt(n,"player_required_successes",0):0,S=n?us(n,"dm_success",!1):!1,y=n?Nt(n,"timeouts",0):0,k=n?Nt(n,"unavailable",0):0,h=n?Nt(n,"reprompts",0):0,C=n?Nt(n,"npc_attacks",0):0,M=n?Nt(n,"keeper_timeout_sec",0):0,T=n?Nt(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${m?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${m?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${S?"DM ok":"DM stalled"} / players ${f}/${$}
          </span>
        </div>
        ${p?i`<div style="margin-top:4px; font-size:12px;">${p}</div>`:null}
        ${v?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${v}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${y}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${h}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${M||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${T}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(P=>{const G=bt(P,"status","unknown"),L=bt(P,"actor_id","-"),V=bt(P,"role","-"),X=bt(P,"reason",""),rt=bt(P,"action_type",""),U=bt(P,"reply","");return i`
                <div class="trpg-round-item ${G.includes("fallback")||G.includes("timeout")?"failed":"active"}">
                  <span>${L} (${V})</span>
                  <span style="margin-left:auto; font-size:11px;">${G}</span>
                  ${rt?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${rt}</div>`:null}
                  ${X?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${X}</div>`:null}
                  ${U?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${U.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${bt(l,"status","unknown")}</strong>
            </div>
            ${d.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(P=>i`<div>violation: ${P}</div>`)}
                </div>`:null}
            ${c.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(P=>i`<div>warning: ${P}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function xb({state:t,nowMs:e}){var l,c,d;const n=te.value||((l=t.session)==null?void 0:l.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=ru(e),o=pb(e);return i`
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
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>mb(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{Ba(),j("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Sb({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>ub(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Cb({state:t}){const e=t.party??[],n=t.story_log??[];return i`
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
          <${du} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${R} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${gb} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${R} title="현재 라운드" semanticId="lab.trpg">
          <${mu} state=${t} />
        <//>

        <${R} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${pu} state=${t} />
        <//>

        <${R} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>i`<${cu} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?i`
            <${R} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${uu} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Ab({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${R} title=${`이벤트 타임라인 (${e.length})`}>
          <${$b} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${R} title="최근 라운드 결과" semanticId="lab.trpg">
          <${_u} />
        <//>

        <${R} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${mu} state=${t} />
        <//>
      </div>
    </div>
  `}function Tb({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${xb} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${R} title="조작 패널" semanticId="lab.trpg">
            <${yb} state=${t} nowMs=${e} />
          <//>

          <${R} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${bb} state=${t} />
          <//>

          <${R} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${kb} state=${t} nowMs=${e} />
          <//>

          <${R} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${_u} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${R} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${pu} state=${t} />
          <//>

          <${R} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${cu} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?i`
              <${R} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${uu} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Ib(){var c,d,m,p,v;const t=Sc.value,e=no.value;if(st(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const f=window.setInterval(()=>{Kl.value=Date.now()},1e3);return()=>{window.clearInterval(f)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>pe()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,o=ou.value,l=Kl.value;return i`
    <div>
      <${xt} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${te.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((m=t.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>pe()}>새로고침</button>
      </div>

      <${hb} outcome=${a} />

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

      <${Sb} active=${o} />

      ${o==="overview"?i`<${Cb} state=${t} />`:o==="timeline"?i`<${Ab} state=${t} />`:i`<${Tb} state=${t} nowMs=${l} />`}
    </div>
  `}function Rb(){return i`
    <div>
      <${xt} surfaceId="lab" />
      <${R} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${R} title="TRPG" class="section" semanticId="lab.trpg">
        <${Ib} />
      <//>
    </div>
  `}const Ka=g(new Set(["broadcast","tasks","keepers","system"]));function Mb(t){const e=new Set(Ka.value);e.has(t)?e.delete(t):e.add(t),Ka.value=e}const mr=g(null);function vu(t){mr.value=t}function Eb(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const Lb=Mt(()=>{const t=Ka.value;return aa.value.filter(e=>t.has(Eb(e)))}),Pb=12e4,zb=Mt(()=>{const t=Ic.value,e=Date.now();return Ht.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?o=e-new Date(l).getTime()>Pb?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),Nb=Mt(()=>{const t=Ic.value;return Ht.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function Ul(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function jb(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function Db(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function wb(){const t=zb.value,e=mr.value;return t.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${t.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${Db(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>vu(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const Ob=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function qb(){const t=Ka.value;return i`
    <div class="activity-filter-bar">
      ${Ob.map(e=>i`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>Mb(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Fb(){const t=Lb.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${qb} />
      <div class="activity-stream-list">
        ${t.length===0?i`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>i`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${Ul(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${Ul(e)}">${jb(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${kd(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function Bb(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function Kb(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function Ub(){const t=Nb.value,e=mr.value;return i`
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
              onClick=${()=>vu(e===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${Bb(n.pressure)}">
                  ${Kb(n.pressure)}
                  ${n.assignedCount>0?i` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?i`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?i`<span class="focus-activity-text">${n.lastActivityText}</span>`:i`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?i`<${et} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function Wb(){const t=ve.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>라이브 모니터</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"연결됨":"오프라인"}
          </span>
          <span class="live-stat">에이전트 ${Ht.value.length}</span>
          <span class="live-stat">이벤트 ${Ua.value}</span>
        </div>
      </div>

      <${wb} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${Fb} />
        </div>
        <div class="live-panel-side">
          <${Ub} />
        </div>
      </div>
    </div>
  `}const Wl=[{id:"observe",label:"관찰",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"맥락",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"개입",description:"개입과 운영 기준 지휘를 실행하는 표면"},{id:"lab",label:"실험",description:"실험적 기능은 메인 operator console 밖으로 분리"}],To=[{id:"mission",label:"상황판",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"proof",label:"근거",icon:"🔍",group:"observe",description:"협업, 대화, 도구, 근거 기록을 증명 중심으로 읽는 표면"},{id:"execution",label:"실행",icon:"🤖",group:"observe",description:"워커, 태스크, 키퍼 연속성을 분리해서 보는 실행 표면"},{id:"tools",label:"도구",icon:"🧰",group:"observe",description:"시스템 전체 도구 inventory와 사용 통계를 함께 읽는 표면"},{id:"live",label:"라이브",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"계획",icon:"🎯",group:"observe",description:"목표, 지표 루프, 백로그 압력을 읽는 계획 표면"},{id:"memory",label:"메모리",icon:"💬",group:"context",description:"게시글과 댓글로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"거버넌스",icon:"⚖️",group:"context",description:"토론과 표결을 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"개입",icon:"🎮",group:"act",description:"룸, 세션, 키퍼 액션을 실행하는 개입 화면"},{id:"command",label:"지휘",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"실험",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 표면을 메인 콘솔 밖에서 다룹니다"}];function Hb(t){const e=t==null?void 0:t.trim();return e?e.length>10?e.slice(0,10):e:"커밋 정보 없음"}function It(t,e){return e==="live"?"가동 중":e==="quiet"?"조용함":e==="starting"?"기동 중":e==="idle"?t==="guardian"?"유휴":"대기 중":"비활성"}function At(t,e){return i`
    <div class="build-badge-row">
      <span>${t}</span>
      <strong>${e}</strong>
    </div>
  `}function Bs(t,e,n,s,a){return i`
    <div style="padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
      <div class="rail-card-head" style="margin:0;">
        <h3 style="font-size:12px;">${t}</h3>
        <span class="rail-section-chip ${n}">${e}</span>
      </div>
      ${s}
      ${a?i`<div class="rail-build-hint">${a}</div>`:null}
    </div>
  `}function Gb({currentTab:t}){var d,m,p,v,f,$,S,y,k,h;const e=ve.value,n=(d=ft.value)==null?void 0:d.build,s=(m=ft.value)==null?void 0:m.lodge,a=(p=ft.value)==null?void 0:p.gardener,o=(v=ft.value)==null?void 0:v.guardian,l=(f=ft.value)==null?void 0:f.sentinel,c=[];if(s&&c.push(Bs("Lodge",s.enabled?It("lodge",s.quiet_active?"quiet":"live"):It("lodge","disabled"),s.enabled?s.quiet_active?"warn":"ok":"bad",[At("틱",s.total_ticks??0),At("체크인",s.total_checkins??0),At("최근 결과",(($=s.last_tick_result)==null?void 0:$.activity_report)??s.last_skip_reason??"없음")])),a&&c.push(Bs("Gardener",a.alive?It("gardener","live"):a.enabled?It("gardener","starting"):It("gardener","disabled"),a.alive?"ok":a.enabled?"warn":"bad",[At("최근 tick",a.last_tick_completed_at?i`<${et} timestamp=${a.last_tick_completed_at} />`:"기록 없음"),At("판단",`${a.last_intervention??"없음"} · ${a.last_decision_source??"없음"}`),At("백로그",`미할당 ${((S=a.health_summary)==null?void 0:S.todo_count)??0} · P1/2 ${((y=a.health_summary)==null?void 0:y.high_priority_todo)??0}`)],a.last_reason??a.last_error??void 0)),o){const C=o.masc_loops_running||o.lodge_loop_started||o.lodge_running;c.push(Bs("Guardian",C?It("guardian","live"):o.enabled?It("guardian","idle"):It("guardian","disabled"),C?"ok":o.enabled?"warn":"bad",[At("모드",o.mode??"알 수 없음"),At("루프",`zombie ${o.zombie_loop_running?"on":"off"} · gc ${o.gc_loop_running?"on":"off"}`),At("소유자",o.runtime_owner??"없음")],((k=o.last_lodge_result)==null?void 0:k.message)??o.last_gc_result??o.last_zombie_result??void 0))}return l&&c.push(Bs("Sentinel",l.started?It("sentinel","live"):l.enabled?It("sentinel","starting"):It("sentinel","disabled"),l.started?"ok":l.enabled?"warn":"bad",[At("에이전트",l.agent_name??"sentinel"),At("소비자",((h=l.consumers)==null?void 0:h.length)??0),At("가디언 소유자",l.guardian_runtime_owner??"없음")],l.llm_enabled===!0?"LLM 기반 housekeeping resident":void 0)),i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${O} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${e?"ok":"bad"}">${e?"연결됨":"오프라인"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>에이전트</span>
          <strong>${Ht.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>키퍼</span>
          <strong>${se.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>태스크</span>
          <strong>${ce.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>이벤트</span>
          <strong>${Ua.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{ms(),Lc(),mo(t)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>it("intervene")}>
          개입 열기
        </button>
      </div>
      ${n?i`<div class="rail-build-hint">서버 빌드 · v${n.release_version} · ${Hb(n.commit)}</div>`:null}
      ${c.length>0?i`
            <div style="margin-top:12px; display:flex; flex-direction:column; gap:10px;">
              ${c}
            </div>
          `:null}
    </section>
  `}function Jb(){const t=Et.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${O} panelId="side_rail.quick_actions" compact=${!0} />
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
          onClick=${()=>{gt(),we()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>it("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}const Ks=g(!1);function Yb(){const t=ve.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"연결됨":"재연결 중..."}</span>
      <span class="event-count">이벤트 ${Ua.value}</span>
    </div>
  `}function Vb(t){const e=t==null?void 0:t.trim();return e?e.length>10?e.slice(0,10):e:"커밋 정보 없음"}function Xb(){const t=ft.value,e=t==null?void 0:t.build,n=e?`v${e.release_version} · ${Vb(e.commit)}`:t!=null&&t.version?`v${t.version} · 커밋 정보 없음`:"버전 정보 없음";return i`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${Ks.value}
        onClick=${()=>{Ks.value=!Ks.value}}
      >
        서버 빌드 · ${n}
      </button>
      ${Ks.value?i`
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
                <strong>${e!=null&&e.started_at?i`<${et} timestamp=${e.started_at} />`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof(e==null?void 0:e.uptime_seconds)=="number"?`${e.uptime_seconds}s`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${t!=null&&t.generated_at?i`<${et} timestamp=${t.generated_at} />`:"알 수 없음"}</strong>
              </div>
            </div>
          `:null}
    </div>
  `}function Qb(){const t=w.value.tab,e=To.find(s=>s.id===t),n=Wl.find(s=>s.id===(e==null?void 0:e.group));return i`
    <aside class="dashboard-rail">
      <${xt} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${O} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${Wl.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${To.filter(a=>a.group===s.id).map(a=>i`
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

      <${Gb} currentTab=${t} />
      <${Jb} />
    </aside>
  `}function Zb(){switch(w.value.tab){case"mission":return i`<${_l} />`;case"proof":return i`<${c$} />`;case"execution":return i`<${$y} />`;case"tools":return i`<${Cy} />`;case"live":return i`<${Wb} />`;case"memory":return i`<${iy} />`;case"governance":return i`<${Zy} />`;case"planning":return i`<${qy} />`;case"intervene":return i`<${Hh} />`;case"command":return i`<${Bh} />`;case"lab":return i`<${Rb} />`;default:return i`<${_l} />`}}function tk(){return eo.value&&!ve.value?i`<div class="loading-indicator">대시보드 불러오는 중...</div>`:i`<${Zb} />`}function ek(){st(()=>{Cu(),Ql(),Pc(),Ee(),Me(),Lc(),Jc();const n=h_();return y_(),()=>{Pu(),n(),b_()}},[]),st(()=>{const n=setInterval(()=>{mo(w.value.tab)},15e3);return()=>{clearInterval(n)}},[]),st(()=>{mo(w.value.tab)},[w.value.tab]);const t=w.value.tab,e=To.find(n=>n.id===t);return i`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC 대시보드
            <${Xb} />
          </h1>
          <p class="header-subtitle">${(e==null?void 0:e.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${Yb} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${Qb} />
        <main class="dashboard-main">
          <${tk} />
        </main>
      </div>

      <${ug} />
      <${Ff} />
      <${Pf} />
    </div>
  `}const Hl=document.getElementById("app");Hl&&yu(i`<${ek} />`,Hl);export{bg as _};
