var Wu=Object.defineProperty;var Gu=(t,e,n)=>e in t?Wu(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Je=(t,e,n)=>Gu(t,typeof e!="symbol"?e+"":e,n);import{e as Ju,_ as Vu,c as $,b as wt,A as ee,y as tt,d as Ke,q as _l,G as Yu}from"./vendor-as4krEX7.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const l of o.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=Ju.bind(Vu);const Xu=["mission","proof","execution","tools","live","memory","governance","planning","intervene","command","lab","social"],kc={tab:"mission",params:{},postId:null};function vl(t){return!!t&&Xu.includes(t)}function oo(t){try{return decodeURIComponent(t)}catch{return t}}function ro(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Qu(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function xc(t,e){if(t[0]==="chains"){const o={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(o.operation=oo(t[2])),{tab:"command",params:o,postId:null}}if(t[0]==="lab"){const o={...e};return t[1]&&(o.surface=oo(t[1])),{tab:"lab",params:o,postId:null}}const n=t[0],s=e.tab;return{tab:vl(n)?n:vl(s)?s:"mission",params:e,postId:null}}function ha(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return kc;const n=oo(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=ro(a),l=Qu(s);return xc(l,o)}function Zu(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...kc,params:ro(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=ro(e.replace(/^\?/,""));return xc(s,a)}function Sc(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const K=$(ha(window.location.hash));window.addEventListener("hashchange",()=>{K.value=ha(window.location.hash)});function at(t,e){const n={tab:t,params:e??{}};window.location.hash=Sc(n)}function tp(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function ep(){if(window.location.hash&&window.location.hash!=="#"){K.value=ha(window.location.hash);return}const t=Zu(window.location.pathname,window.location.search);if(t){K.value=t;const e=Sc(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",K.value=ha(window.location.hash)}const fl="masc_dashboard_sse_session_id",np=1e3,sp=15e3,$e=$(!1),ai=$(0),Cc=$(null),ya=$([]);function ap(){let t=sessionStorage.getItem(fl);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(fl,t)),t}const ip=200;function op(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};ya.value=[a,...ya.value].slice(0,ip)}function lo(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function gl(t,e){const n=lo(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function Et(t,e,n,s,a={}){op(t,e,n,{eventType:s,...a})}let Dt=null,un=null,co=0;function Ac(){un&&(clearTimeout(un),un=null)}function rp(){if(un)return;co++;const t=Math.min(co,5),e=Math.min(sp,np*Math.pow(2,t));un=setTimeout(()=>{un=null,Tc()},e)}function Tc(){Ac(),Dt&&(Dt.close(),Dt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",ap());const a=e.toString()?`/sse?${e.toString()}`:"/sse",o=new EventSource(a);Dt=o,o.onopen=()=>{Dt===o&&(co=0,$e.value=!0)},o.onerror=()=>{Dt===o&&($e.value=!1,o.close(),Dt=null,rp())},o.onmessage=l=>{try{const c=JSON.parse(l.data);ai.value++,Cc.value=c,lp(c)}catch{}}}function lp(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":Et(n,"Joined","system","agent_joined");break;case"agent_left":Et(n,"Left","system","agent_left");break;case"broadcast":Et(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Et(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Et(n,gl("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:lo(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":Et(n,gl("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:lo(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":Et(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Et(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Et(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Et(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Et(n,e,"system","unknown")}}function cp(){Ac(),Dt&&(Dt.close(),Dt=null),$e.value=!1}function v(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function r(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function u(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function j(t){return typeof t=="boolean"?t:void 0}function H(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function ct(t,e=[]){if(Array.isArray(t))return t;if(!v(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function ot(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}const ba="[STATE]",uo="[/STATE]";function dp(t){const e=t.indexOf(ba);if(e<0)return null;const n=e+ba.length,s=t.indexOf(uo,n);return s<0?null:t.slice(n,s).trim()||null}function up(t){let e=t;for(;;){const n=e.indexOf(ba);if(n<0)return e;const s=e.indexOf(uo,n+ba.length);if(s<0)return e.slice(0,n);e=`${e.slice(0,n)}${e.slice(s+uo.length)}`}}function pp(t){return t.split(`
`).filter(e=>{const n=e.trim();return!n.startsWith("SKILL:")&&!n.startsWith("SKILL_REASON:")}).join(`
`)}function Ic(t){const e=pp(t);return up(e).replace(/\n{3,}/g,`

`).trim()}function Rc(t){const e=(()=>{if(!v(t))return null;const o=t.raw_payload;return v(o)?o:t})();if(!e)return null;const n=r(e.reply)??"",s=n?dp(n):null,a=v(e.usage)?{inputTokens:u(e.usage.input_tokens)??null,outputTokens:u(e.usage.output_tokens)??null,totalTokens:u(e.usage.total_tokens)??null}:null;return{traceId:r(e.trace_id)??null,generation:u(e.generation)??null,modelUsed:r(e.model_used)??null,latencyMs:u(e.latency_ms)??null,costUsd:u(e.cost_usd)??null,usage:a,skillPrimary:r(e.skill_primary)??null,skillReason:r(e.skill_reason)??null,stateBlock:s,rawPayload:e}}function Go(){return new URLSearchParams(window.location.search)}const mp="masc_dashboard_agent_name";function Mc(){var t;try{return((t=localStorage.getItem(mp))==null?void 0:t.trim())||null}catch{return null}}function _p(){var e,n;const t=Go();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||Mc()||"dashboard"}function Lc(){const t=Go(),e={},n=t.get("token"),s=Mc(),a=t.get("agent")??t.get("agent_name")??s;return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Jo(){return{...Lc(),"Content-Type":"application/json"}}const vp=15e3,Vo=3e4,fp=6e4,gp=3e4,$l=new Set([408,425,429,500,502,503,504]);class xs extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);Je(this,"method");Je(this,"path");Je(this,"status");Je(this,"statusText");Je(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function ii(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const l=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new xs({method:l,path:t,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function $p(){var e,n;const t=Go();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function nt(t,e={}){const n=await ii(t,{headers:Lc()},e.timeoutMs??vp);if(!n.ok)throw new xs({method:"GET",path:t,status:n.status,statusText:n.statusText});return n.json()}function hp(t){return new Promise(e=>setTimeout(e,t))}function yp(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function bp(t){if(t instanceof xs)return t.timeout||typeof t.status=="number"&&$l.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=yp(t.message);return e!==null&&$l.has(e)}async function Ec(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!bp(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${o}ms`,a),await hp(o),s+=1}}async function Wt(t,e,n,s=Vo){const a=await ii(t,{method:"POST",headers:{...Jo(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new xs({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function kp(t,e,n,s=Vo){const a=await ii(t,{method:"POST",headers:{...Jo(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new xs({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function xp(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Sp(t){var e,n,s,a,o,l,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((c=(l=(o=t.result)==null?void 0:o.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function ht(t,e){const n=await kp("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},fp),s=xp(n);return Sp(s)}function oi(t){const e=t.trim();return e?JSON.parse(e):{}}async function Cp(t){return oi(await ht("masc_autoresearch_status",{loop_id:t}))}async function Ap(t,e){return oi(await ht("masc_autoresearch_inject",{loop_id:t,hypothesis:e}))}async function Tp(t){return oi(await ht("masc_autoresearch_cycle",{loop_id:t}))}async function Ip(t,e){return oi(await ht("masc_autoresearch_stop",{loop_id:t,reason:e}))}async function Rp(t,e,n){const s={message:e},a=await Ss({actor:_p(),action_type:"keeper_message",target_type:"keeper",target_id:t,payload:s}),o=v(a.result)?a.result:null,l=o&&typeof o.reply=="string"?o.reply:"",c=o&&v(o.result)?o.result:o,d=Rc(c);return{text:Ic(l||"(empty reply)"),details:d}}async function Mp(t,e,n){return Rp(t,e)}function Lp(t){const e=t.replace(/\r\n/g,`
`),n=[];let s=0;for(;;){const a=e.indexOf(`

`,s);if(a<0)return{frames:n,rest:e.slice(s)};n.push(e.slice(s,a)),s=a+2}}function hl(t){const e=t.split(`
`).filter(n=>n.startsWith("data:")).map(n=>n.slice(5).trimStart());if(e.length===0)return null;try{return JSON.parse(e.join(`
`))}catch{return null}}async function Ep(t,e,n,{signal:s,onEvent:a}){var p;const o=await fetch("/api/v1/keepers/chat/stream",{method:"POST",headers:{...Jo(),Accept:"text/event-stream"},body:JSON.stringify({name:t,message:e}),signal:s});if(!o.ok){const m=await o.text();let f=m||`Streaming request failed (${o.status})`;try{const h=JSON.parse(m);f=((p=h.error)==null?void 0:p.message)??h.message??f}catch{}throw new Error(f)}if(!o.body)throw new Error("Streaming response body is unavailable");const l=o.body.getReader(),c=new TextDecoder;let d="";try{for(;;){const{done:f,value:h}=await l.read();d+=c.decode(h??new Uint8Array,{stream:!f});const{frames:y,rest:C}=Lp(d);d=C;for(const _ of y){const k=hl(_);k&&a(k)}if(f)break}const m=d.trim();if(m){const f=hl(m);f&&a(f)}}finally{l.releaseLock()}}function Pp(){return nt("/api/v1/dashboard/shell")}function zp(){return nt("/api/v1/dashboard/room-truth",{timeoutMs:gp})}function wp(){return nt("/api/v1/dashboard/execution")}function Np(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),nt(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function jp(){return Ec("fetchDashboardGovernance",async()=>{const t=await nt("/api/v1/dashboard/governance"),e=Array.isArray(t.items)?t.items.map(s=>im(s)).filter(s=>s!==null):[],n=Array.isArray(t.pending_actions)?t.pending_actions.map(s=>zc(s)).filter(s=>s!==null):[];return{generated_at:pt(t.generated_at)??void 0,summary:v(t.summary)?{cases_open:Pt(t.summary.cases_open)??void 0,pending_ruling:Pt(t.summary.pending_ruling)??void 0,ready_auto_execute:Pt(t.summary.ready_auto_execute)??void 0,needs_human_gate:Pt(t.summary.needs_human_gate)??void 0,executed:Pt(t.summary.executed)??void 0,blocked:Pt(t.summary.blocked)??void 0,ready_to_execute:Pt(t.summary.ready_to_execute)??void 0,oldest_open_case_age_s:typeof t.summary.oldest_open_case_age_s=="number"?t.summary.oldest_open_case_age_s:null,last_activity_age_s:typeof t.summary.last_activity_age_s=="number"?t.summary.last_activity_age_s:null,judge_online:typeof t.summary.judge_online=="boolean"?t.summary.judge_online:void 0,judge_last_seen_at:pt(t.summary.judge_last_seen_at)}:void 0,items:e,activity:Array.isArray(t.activity)?t.activity.map(s=>rm(s)).filter(s=>s!==null):[],judge:lm(t.judge),pending_actions:n}})}function Op(){return nt("/api/v1/dashboard/semantics")}function Dp(){return nt("/api/v1/dashboard/mission")}function qp(t){const e=`?session_id=${encodeURIComponent(t)}`;return nt(`/api/v1/dashboard/session${e}`)}function Fp(t=!1){return nt(`/api/v1/dashboard/mission/briefing${t?"?force=1":""}`)}function Kp(t,e){const n=new URLSearchParams;t&&n.set("session_id",t),e&&n.set("operation_id",e);const s=n.toString();return nt(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function Bp(){return nt("/api/v1/dashboard/planning")}function Up(){return nt("/api/v1/tool-metrics")}function Hp(){return nt("/api/v1/dashboard/tools")}function Wp(){return nt("/api/v1/operator")}function Pc(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return nt(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Gp(){return nt("/api/v1/command-plane")}function Jp(){return nt("/api/v1/command-plane/summary")}function Vp(){return nt("/api/v1/chains/summary")}function Yp(t){return nt(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Xp(){return nt("/api/v1/command-plane/help")}function Qp(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return nt(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function Zp(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return nt(`/api/v1/command-plane/orchestra${s?`?${s}`:""}`)}function tm(t,e){return Wt(t,e)}function em(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"swarm_run_continue":return 6e4;case"swarm_run_rerun":return 12e4;case"swarm_run_abandon":return 3e4;case"social_sweep":case"lodge_tick":return 45e3;default:return Vo}}function Ss(t){return Wt("/api/v1/operator/action",t,void 0,em(t))}function nm(t,e,n="confirm"){return Wt("/api/v1/operator/confirm",{actor:t,confirm_token:e,decision:n})}function ia(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function pt(t){if(typeof t=="string"){const e=t.trim();return e||null}if(typeof t=="number"&&Number.isFinite(t)){const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}return null}function N(t){if(typeof t!="string")return null;const e=t.trim();return e||null}function zc(t){if(!v(t))return null;const e=T(t.confirm_token??t.token,"").trim();return e?{confirm_token:e,actor:N(t.actor)??void 0,action_type:N(t.action_type)??void 0,target_type:N(t.target_type)??void 0,target_id:N(t.target_id),delegated_tool:N(t.delegated_tool)??void 0,created_at:pt(t.created_at)??void 0,preview:t.preview}:null}function sm(t){return v(t)?{board_post_id:N(t.board_post_id),task_id:N(t.task_id),operation_id:N(t.operation_id),team_session_id:N(t.team_session_id)}:{}}function Yo(t){if(!v(t))return null;const e=N(t.action_kind),n=N(t.resolved_tool),s=N(t.target_type),a=N(t.target_id),o=N(t.reason);return!e&&!n&&!s&&!o?null:{action_kind:e??void 0,resolved_tool:n,target_type:s,target_id:a,reason:o??void 0,payload_preview:t.payload_preview}}function wc(t){if(!v(t))return null;const e=N(t.action_type),n=N(t.delegated_tool),s=N(t.confirmation_state),a=pt(t.created_at);return!e&&!n&&!s&&!a?null:{action_type:e??void 0,delegated_tool:n,confirmation_state:s??void 0,created_at:a}}function Nc(t){if(!v(t))return null;const e=zc(t.pending_confirm),n=N(t.pending_confirm_token)??(e==null?void 0:e.confirm_token)??null;return{requires_human_gate:typeof t.requires_human_gate=="boolean"?t.requires_human_gate:void 0,pending_confirm:e,pending_confirm_token:n,ready_to_execute:typeof t.ready_to_execute=="boolean"?t.ready_to_execute:void 0}}function am(t){if(!v(t))return null;const e=N(t.summary),n=N(t.target_id);return!e&&!n?null:{judgment_id:N(t.judgment_id)??void 0,target_kind:N(t.target_kind)??void 0,target_id:n??void 0,status:N(t.status)??void 0,summary:e??void 0,confidence:typeof t.confidence=="number"?t.confidence:null,generated_at:pt(t.generated_at),expires_at:pt(t.expires_at),model_used:N(t.model_used),keeper_name:N(t.keeper_name),evidence_refs:Lt(t.evidence_refs),recommended_action:Yo(t.recommended_action),guardrail_state:Nc(t.guardrail_state),executed_route:wc(t.executed_route)}}function im(t){if(!v(t))return null;const e=T(t.id,"").trim(),n=T(t.topic??t.title,"").trim();if(!e||!n)return null;const s=sm(t.context);return{kind:T(t.kind,"case"),id:e,topic:n,status:T(t.status??t.state,"open"),origin:N(t.origin),subject_type:N(t.subject_type),risk_class:N(t.risk_class),provenance:N(t.provenance),auto_execution_state:N(t.auto_execution_state),petition_count:Pt(t.petition_count),brief_count:Pt(t.brief_count),last_activity_at:pt(t.last_activity_at),truth_summary:N(t.truth_summary)??void 0,judgment_summary:N(t.judgment_summary),confidence:typeof t.confidence=="number"?t.confidence:null,related_agents:Lt(t.related_agents),context:s,linked_board_post_id:N(t.linked_board_post_id)??s.board_post_id??null,linked_task_id:N(t.linked_task_id)??s.task_id??null,linked_operation_id:N(t.linked_operation_id)??s.operation_id??null,linked_session_id:N(t.linked_session_id)??s.team_session_id??null,recommended_action:Yo(t.recommended_action),executed_route:wc(t.executed_route),guardrail_state:Nc(t.guardrail_state),evidence_refs:Lt(t.evidence_refs)}}function om(t){if(!v(t))return null;const e=T(t.id,"").trim(),n=T(t.author,"").trim(),s=T(t.summary,"").trim();return!e||!n||!s?null:{id:e,author:n,stance:T(t.stance,"support"),summary:s,evidence_refs:Lt(t.evidence_refs),created_at:pt(t.created_at)}}function jc(t){if(!v(t))return null;const e=T(t.id,"").trim(),n=T(t.case_id,"").trim();return!e||!n?null:{id:e,case_id:n,status:T(t.status,"blocked"),risk_class:N(t.risk_class),action_request:Yo(t.action_request),created_at:pt(t.created_at),updated_at:pt(t.updated_at),execution_ref:N(t.execution_ref),result_summary:N(t.result_summary),actor:N(t.actor)}}function Xo(t){if(!v(t)||!v(t.case))return null;const e=t.case,n=T(e.id,"").trim(),s=T(e.title,"").trim();return!n||!s?null:{case:{id:n,petition_ids:Lt(e.petition_ids),title:s,origin:N(e.origin),subject_type:N(e.subject_type),risk_class:N(e.risk_class),status:T(e.status,"pending_ruling"),created_at:pt(e.created_at),updated_at:pt(e.updated_at),source_refs:Lt(e.source_refs),briefs:Array.isArray(e.briefs)?e.briefs.map(a=>om(a)).filter(a=>a!==null):[]},petitions:Array.isArray(t.petitions)?t.petitions.flatMap(a=>{if(!v(a))return[];const o=T(a.id,"").trim(),l=T(a.case_id,"").trim(),c=T(a.title,"").trim();return!o||!l||!c?[]:[{id:o,case_id:l,title:c,origin:N(a.origin),subject_type:N(a.subject_type),risk_class:N(a.risk_class),source_refs:Lt(a.source_refs),created_by:N(a.created_by),created_at:pt(a.created_at)}]}):[],ruling:am(t.ruling),execution_order:jc(t.execution_order)}}function rm(t){if(!v(t))return null;const e=T(t.kind,"").trim();return e?{kind:e,item_kind:N(t.item_kind)??void 0,item_id:N(t.item_id)??void 0,topic:N(t.topic)??void 0,created_at:pt(t.created_at),summary:N(t.summary)??void 0,actor:N(t.actor),index:Pt(t.index),decision:N(t.decision)}:null}function lm(t){if(v(t))return{judge_online:typeof t.judge_online=="boolean"?t.judge_online:void 0,refreshing:typeof t.refreshing=="boolean"?t.refreshing:void 0,generated_at:pt(t.generated_at),expires_at:pt(t.expires_at),model_used:N(t.model_used),keeper_name:N(t.keeper_name),last_error:N(t.last_error)}}function cm(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function dm(t){if(!v(t))return null;const e=T(t.source,"").trim()||null,n=T(t.state_block,"").trim()||null;return!e&&!n?null:{source:e,state_block:n}}function um(t){if(!v(t))return null;const e=T(t.id,"").trim(),n=T(t.author,"").trim(),s=T(t.body,"").trim()||T(t.content,"").trim(),a=s;if(!e||!n)return null;const o=st(t.score,0),l=st(t.votes_up,0),c=st(t.votes_down,0),d=st(t.votes,o||l-c),p=st(t.comment_count,st(t.reply_count,0)),m=(()=>{const k=t.flair;if(typeof k=="string"&&k.trim())return k.trim();if(v(k)){const b=T(k.name,"").trim();if(b)return b}return T(t.flair_name,"").trim()||void 0})(),f=T(t.created_at_iso,"").trim()||ia(t.created_at),h=T(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?ia(t.updated_at):f),C=T(t.title,"").trim()||cm(s),_=Array.isArray(t.tags)?t.tags.filter(k=>typeof k=="string"&&k.trim()!==""):[];return{id:e,author:n,post_kind:(()=>{const k=T(t.post_kind,"").trim().toLowerCase();return k==="automation"||k==="system"||k==="human"?k:void 0})(),title:C,body:s,content:a,meta:dm(t.meta),tags:_,votes:d,vote_balance:o,comment_count:p,created_at:f,updated_at:h,flair:m,hearth:T(t.hearth,"").trim()||null,visibility:T(t.visibility,"").trim()||void 0,expires_at:T(t.expires_at_iso,"").trim()||(t.expires_at!==void 0&&t.expires_at!==0?ia(t.expires_at):"")||null,hearth_count:st(t.hearth_count,0)}}function pm(t){if(!v(t))return null;const e=T(t.id,"").trim(),n=T(t.post_id,"").trim(),s=T(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:T(t.content,""),created_at:ia(t.created_at)}}async function mm(t){return Ec("fetchBoardPost",async()=>{const e=await nt(`/api/v1/board/${t}?format=flat`),n=v(e.post)?e.post:e,s=um(n)??{id:t,author:"unknown",post_kind:"human",title:"Post",body:"",content:"",meta:null,tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(e.comments)?e.comments:[]).map(pm).filter(l=>l!==null);return{...s,comments:o}})}function Oc(t,e){return Wt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:$p()})}function _m(t,e,n){return Wt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function vm(t){const e=T(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function mt(...t){for(const e of t){const n=T(e,"");if(n.trim())return n.trim()}return""}function yl(t){const e=vm(mt(t.outcome,t.result,t.result_code));if(!e)return;const n=mt(t.reason,t.reason_code,t.description,t.detail),s=mt(t.summary,t.summary_ko,t.summary_en,t.note),a=mt(t.details,t.details_text,t.text,t.note),o=mt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),l=mt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=mt(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const f=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof f=="string"?[f]:Array.isArray(f)?f.map(h=>{if(typeof h=="string")return h.trim();if(v(h)){const y=T(h.summary,"").trim();if(y)return y;const C=T(h.text,"").trim();if(C)return C;const _=T(h.type,"").trim();return _||T(h.event_id,"").trim()}return""}).filter(h=>h.length>0):[]})(),p=(()=>{const f=st(t.turn,Number.NaN);if(Number.isFinite(f))return f;const h=st(t.turn_number,Number.NaN);if(Number.isFinite(h))return h;const y=st(t.current_turn,Number.NaN);if(Number.isFinite(y))return y;const C=st(t.round,Number.NaN);return Number.isFinite(C)?C:void 0})(),m=mt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:l||void 0,evidence:d.length>0?d:void 0,raw_reason:c||void 0,turn:p,phase:m||void 0}}function fm(t,e){const n=v(t.state)?t.state:{};if(T(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(l=>v(l)?T(l.type,"")==="session.outcome":!1),o=v(n.session_outcome)?n.session_outcome:{};if(v(o)&&Object.keys(o).length>0){const l=yl(o);if(l)return l}if(v(a))return yl(v(a.payload)?a.payload:{})}function T(t,e=""){return typeof t=="string"?t:e}function st(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Pt(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function po(t,e=!1){return typeof t=="boolean"?t:e}function Lt(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(v(e)){const n=T(e.name,"").trim(),s=T(e.id,"").trim(),a=T(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function gm(t){const e={};if(!v(t)&&!Array.isArray(t))return e;if(v(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),o=T(s,"").trim();!a||!o||(e[a]=o)}),e;for(const n of t){if(!v(n))continue;const s=mt(n.to,n.target,n.actor_id,n.name,n.id),a=mt(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function $m(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function Rt(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=t[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const hm=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function ym(t){const e=v(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const o=s.trim();o&&(hm.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function bm(t,e){if(t!=="dice.rolled")return;const n=st(e.raw_d20,0),s=st(e.total,0),a=st(e.bonus,0),o=T(e.action,"roll"),l=st(e.dc,0);return{notation:l>0?`${o} (DC ${l})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function km(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function xm(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Sm(t,e,n,s){const a=n||e||T(s.actor_id,"")||T(s.actor_name,"");switch(t){case"turn.action.proposed":{const o=T(s.proposed_action,T(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=T(s.reply,T(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return T(s.reply,T(s.content,T(s.text,"Narration")));case"dice.rolled":{const o=T(s.action,"roll"),l=st(s.total,0),c=st(s.dc,0),d=T(s.label,""),p=a||"actor",m=c>0?` vs DC ${c}`:"",f=d?` (${d})`:"";return`${p} ${o}: ${l}${m}${f}`}case"turn.started":return`Turn ${st(s.turn,1)} started`;case"phase.changed":return`Phase: ${T(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${T(s.name,v(s.actor)?T(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${T(s.keeper_name,T(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${T(s.keeper_name,T(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${st(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${st(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||T(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||T(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${T(s.reason_code,"unknown")}`;case"memory.signal":{const o=v(s.entity_refs)?s.entity_refs:{},l=T(o.requested_tier,""),c=T(o.effective_tier,""),d=po(o.guardrail_applied,!1),p=T(s.summary_en,T(s.summary_ko,"Memory signal"));if(!l&&!c)return p;const m=l&&c?`${l}->${c}`:c||l;return`${p} [${m}${d?" (guardrail)":""}]`}case"world.event":{if(T(s.event_type,"")==="canon.check"){const l=T(s.status,"unknown"),c=T(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return T(s.description,T(s.summary,"World event"))}case"combat.attack":return T(s.summary,T(s.result,"Attack resolved"));case"combat.defense":return T(s.summary,T(s.result,"Defense resolved"));case"session.outcome":return T(s.summary,T(s.outcome,"Session ended"));default:{const o=km(s);return o?`${t}: ${o}`:t}}}function Cm(t,e){const n=v(t)?t:{},s=T(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=T(n.actor_name,"").trim()||e[a]||T(v(n.payload)?n.payload.actor_name:"",""),l=v(n.payload)?n.payload:{},c=T(n.ts,T(n.timestamp,new Date().toISOString())),d=T(n.phase,T(l.phase,"")),p=T(n.category,"");return{type:s,actor:o||a||T(l.actor_name,""),actor_id:a||T(l.actor_id,""),actor_name:o,seq:n.seq,room_id:T(n.room_id,""),phase:d||void 0,category:p||xm(s),visibility:T(n.visibility,T(l.visibility,"public")),event_id:T(n.event_id,""),content:Sm(s,a,o,l),dice_roll:bm(s,l),timestamp:c}}function Am(t,e,n){var J,et;const s=T(t.room_id,"")||n||"default",a=v(t.state)?t.state:{},o=v(a.party)?a.party:{},l=v(a.actor_control)?a.actor_control:{},c=v(a.join_gate)?a.join_gate:{},d=v(a.contribution_ledger)?a.contribution_ledger:{},p=Object.entries(o).map(([G,P])=>{const A=v(P)?P:{},z=Rt(A,"max_hp",void 0,10),V=Rt(A,"hp",void 0,z),yt=Rt(A,"max_mp",void 0,0),oe=Rt(A,"mp",void 0,0),W=Rt(A,"level",void 0,1),ft=Rt(A,"xp",void 0,0),xe=po(A.alive,V>0),rt=l[G],Mn=typeof rt=="string"?rt:void 0,ws=$m(A.role,G,Mn),Ns=Pt(A.generation),js=mt(A.joined_at,A.joinedAt,A.started_at,A.startedAt),$i=mt(A.claimed_at,A.claimedAt,A.assigned_at,A.assignedAt,A.assigned_time),hi=mt(A.last_seen,A.lastSeen,A.last_seen_at,A.lastSeenAt,A.last_active,A.lastActive),yi=mt(A.scene,A.current_scene,A.currentScene,A.world_scene,A.scene_name,A.sceneName),bi=mt(A.location,A.current_location,A.currentLocation,A.position,A.zone,A.area);return{id:G,name:T(A.name,G),role:ws,keeper:Mn,archetype:T(A.archetype,""),persona:T(A.persona,""),portrait:T(A.portrait,"")||void 0,background:T(A.background,"")||void 0,traits:Lt(A.traits),skills:Lt(A.skills),stats_raw:ym(A),status:xe?"active":"dead",generation:Ns,joined_at:js||void 0,claimed_at:$i||void 0,last_seen:hi||void 0,scene:yi||void 0,location:bi||void 0,inventory:Lt(A.inventory),notes:Lt(A.notes),relationships:gm(A.relationships),stats:{hp:V,max_hp:z,mp:oe,max_mp:yt,level:W,xp:ft,strength:Rt(A,"strength","str",10),dexterity:Rt(A,"dexterity","dex",10),constitution:Rt(A,"constitution","con",10),intelligence:Rt(A,"intelligence","int",10),wisdom:Rt(A,"wisdom","wis",10),charisma:Rt(A,"charisma","cha",10)}}}),m=p.filter(G=>G.status!=="dead"),f=fm(t,e),h={phase_open:po(c.phase_open,!0),min_points:st(c.min_points,3),window:T(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},y=Object.entries(d).map(([G,P])=>{const A=v(P)?P:{};return{actor_id:G,score:st(A.score,0),last_reason:T(A.last_reason,"")||null,reasons:Lt(A.reasons)}}),C=p.reduce((G,P)=>(G[P.id]=P.name,G),{}),_=e.map(G=>Cm(G,C)),k=st(a.turn,1),g=T(a.phase,"round"),b=T(a.map,""),R=v(a.world)?a.world:{},L=b||T(R.ascii_map,T(R.map,"")),S=_.filter((G,P)=>{const A=e[P];if(!v(A))return!1;const z=v(A.payload)?A.payload:{};return st(z.turn,-1)===k}),M=(S.length>0?S:_).slice(-12),I=T(a.status,"active");return{session:{id:s,room:s,status:I==="ended"?"ended":I==="paused"?"paused":"active",round:k,actors:m,created_at:((J=_[0])==null?void 0:J.timestamp)??new Date().toISOString()},current_round:{round_number:k,phase:g,events:M,timestamp:((et=_[_.length-1])==null?void 0:et.timestamp)??new Date().toISOString()},map:L||void 0,join_gate:h,contribution_ledger:y,outcome:f,party:m,story_log:_,history:[]}}async function Tm(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await nt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Im(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([nt(`/api/v1/trpg/state${e}`),Tm(t)]);return Am(n,s,t)}function Rm(t){return Wt("/api/v1/trpg/rounds/run",{room_id:t})}function Mm(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Lm(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Wt("/api/v1/trpg/dice/roll",e)}function Em(t,e){const n=Mm();return Wt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Pm(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Wt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function zm(t,e,n){return Wt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function wm(t,e,n){const s=await ht("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Nm(t){const e=await ht("trpg.mid_join.request",t);return JSON.parse(e)}async function jm(t,e){await ht("masc_broadcast",{agent_name:t,message:e})}async function Om(t=40){return(await ht("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Dm(t,e=20){return ht("masc_task_history",{task_id:t,limit:e})}async function qm(t){const e=await ht("masc_petition_submit",{title:t,origin:"human",subject_type:"task",risk_class:"low",requested_action:{action_type:"add_task",payload:{title:t}}});try{const n=JSON.parse(e),s=v(n.case)?n.case:null,a=v(n.petition)?n.petition:null,o=v(n.ruling)?n.ruling:null;return!s||!a?null:Xo({case:s,petitions:[a],ruling:o,execution_order:null})}catch{return null}}async function Fm(t,e,n){const s=await ht("masc_case_brief_submit",{case_id:t,stance:e,summary:n});try{const a=JSON.parse(s),o=Xo(a);if(o)return o}catch{}return Dc(t)}async function Dc(t){const e=await ht("masc_case_status",{case_id:t});try{return Xo(JSON.parse(e))}catch{return null}}async function Km(t,e){const n=await ht("masc_execution_orders",{case_id:t,decision:e});try{return jc(JSON.parse(n))}catch{return null}}async function Bm(){try{const t=await ii("/api/v1/social-graph",{},1e4);return t.ok?await t.json():null}catch{return null}}const Um=$(""),se=$({}),$t=$({}),mo=$({}),ka=$({}),_o=$({}),vo=$({}),Bt=$({}),Qo=new Map,Zo=new Map;function lt(t,e,n){t.value={...t.value,[e]:n}}function Hm(t){var n;const e=(n=r(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Wm(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function ki(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!v(s))continue;const a=r(s.name);if(!a)continue;const o=r(s[e]);e==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function Gm(t){if(!v(t))return null;const e=r(t.name);return e?{name:e,trigger:r(t.trigger),outcome:r(t.outcome),summary:r(t.summary),reason:r(t.reason)}:null}function Jm(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Social quiet hours are active. Direct messages still work, but scheduled public-square reactions may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Vm(t,e,n){return r(t)??Jm(e,n)}function Ym(t,e){return typeof t=="boolean"?t:e==="recover"}function xa(t){if(!v(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:r(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:ot(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:u(t.next_eligible_at_s)??null,recoverable:Ym(t.recoverable,n),summary:Vm(t.summary,e,r(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0,continuity_state:r(t.continuity_state)??null,continuity_summary:r(t.continuity_summary)??null}}function qc(t){if(!v(t))return null;const e=r(t.last_system_skip_reason)??r(t.skipped_reason);return{hour:u(t.hour),checked:u(t.checked)??0,acted:u(t.acted)??0,acted_names:H(t.acted_names),activity_report:r(t.activity_report),quiet_hours_overridden:j(t.quiet_hours_overridden),skipped_reason:e,last_pass_reason:r(t.last_pass_reason)??null,last_system_skip_reason:e,acted_rows:ki(t.acted_rows,"summary").map(n=>({name:n.name,summary:n.summary})),passed_rows:ki(t.passed_rows,"reason").map(n=>({name:n.name,reason:n.reason})),skipped_rows:ki(t.skipped_rows,"reason").map(n=>({name:n.name,reason:n.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Gm).filter(n=>n!==null):[]}}function Xm(t){if(!v(t))return null;const e=r(t.last_system_skip_reason)??r(t.last_skip_reason)??null;return{enabled:j(t.enabled)??!1,interval_s:u(t.interval_s)??0,quiet_start:u(t.quiet_start),quiet_end:u(t.quiet_end),quiet_active:j(t.quiet_active),use_planner:j(t.use_planner),delegate_llm:j(t.delegate_llm),agent_count:u(t.agent_count),agents:H(t.agents),last_tick_ago_s:u(t.last_tick_ago_s)??null,last_tick_ago:r(t.last_tick_ago),total_ticks:u(t.total_ticks),total_checkins:u(t.total_checkins),last_skip_reason:e,last_pass_reason:r(t.last_pass_reason)??null,last_system_skip_reason:e,last_tick_result:qc(t.last_tick_result),active_self_heartbeats:H(t.active_self_heartbeats)}}function Qm(t){return v(t)?{status:t.status,diagnostic:xa(t.diagnostic)}:null}function Zm(t){return v(t)?{recovered:j(t.recovered)??!1,skipped_reason:r(t.skipped_reason)??null,before:xa(t.before),after:xa(t.after),down:t.down,up:t.up}:null}function t_(t,e){if(!v(t))return null;const n=Hm(t.role),s=r(t.content)??r(t.preview);if(!s)return null;const a=Ic(s);if(!a)return null;const o=ot(t.ts_unix)??ot(t.timestamp);return{id:`${n}-${o??"entry"}-${e}`,role:n,label:Wm(n),text:a,timestamp:o,delivery:"history",streamState:null,details:null}}function e_(t,e,n){const s=v(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,l)=>t_(o,l)).filter(o=>o!==null):[];return{name:t,diagnostic:xa(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function bl(t,e){const n=$t.value[t]??[];$t.value={...$t.value,[t]:[...n,e].slice(-50)}}function tr(t,e,n){const s=$t.value[t]??[];$t.value={...$t.value,[t]:s.map(a=>a.id===e?n(a):a)}}function xi(t,e,n,s){tr(t,e,a=>({...a,streamState:n,delivery:s}))}function n_(t,e,n){tr(t,e,s=>({...s,text:`${s.text}${n}`,streamState:"streaming",delivery:"streaming"}))}function Vt(t,e,n){tr(t,e,s=>({...s,...n}))}function s_(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function a_(t,e){const s=($t.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(o=>s_(a,o)));$t.value={...$t.value,[t]:[...e,...s].slice(-50)}}function ri(t,e){se.value={...se.value,[t]:e},a_(t,e.history)}function Os(t,e){const n=se.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};ri(t,{...n,diagnostic:{...s,...e}})}function i_(t,e,n){Zo.set(t,e),Qo.set(t,n)}function Fc(t){Zo.delete(t),Qo.delete(t)}function o_(t){return Zo.get(t)??null}function Kc(t){const e=t.trim();if(!e)return;const n=Qo.get(e),s=o_(e);n&&n.abort(),s&&Vt(e,s,{delivery:"timeout",streamState:null,error:"Stream cancelled",timestamp:new Date().toISOString()}),Fc(e),lt(ka,e,!1)}function r_(t,e,n){switch(n.type){case"RUN_STARTED":return xi(t,e,"opening","sending"),null;case"TEXT_MESSAGE_START":return xi(t,e,"streaming","streaming"),null;case"TEXT_MESSAGE_CONTENT":{const s=typeof n.delta=="string"?n.delta:"";return s&&n_(t,e,s),null}case"TEXT_MESSAGE_END":return xi(t,e,"finalizing","streaming"),null;case"CUSTOM":if(n.name==="KEEPER_REPLY_DETAILS"){const s=Rc(n.value);s&&Vt(t,e,{details:s})}return null;case"RUN_ERROR":return typeof n.value=="string"?n.value:(v(n.value)?r(n.value.message):null)??"Keeper stream failed";default:return null}}async function Sa(){try{await Cs()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function l_(t){Um.value=t.trim()}async function Bc(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&se.value[n])return se.value[n];lt(mo,n,!0),lt(Bt,n,null);try{const s=await ht("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=e_(n,s,a);return ri(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return lt(Bt,n,a),null}finally{lt(mo,n,!1)}}async function c_(t,e){var c;const n=t.trim(),s=e.trim();if(!n||!s)return;Kc(n);const a=`local-${Date.now()}`,o=`reply-${Date.now()}`;bl(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending",streamState:null,details:null}),bl(n,{id:o,role:"assistant",label:n,text:"",timestamp:null,delivery:"sending",streamState:"opening",details:null}),lt(ka,n,!0),lt(Bt,n,null);const l=new AbortController;i_(n,o,l);try{Vt(n,a,{delivery:"delivered"}),await Ep(n,s,void 0,{signal:l.signal,onEvent:m=>{const f=r_(n,o,m);if(f)throw new Error(f)}});const d=($t.value[n]??[]).find(m=>m.id===o)??null,p=(d==null?void 0:d.text.trim())||"(empty reply)";Vt(n,o,{text:p,delivery:"delivered",streamState:null,timestamp:new Date().toISOString(),error:null}),Os(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:p.slice(0,200),last_error:null})}catch(d){if(d instanceof Error&&d.name==="AbortError")throw Vt(n,o,{delivery:"timeout",streamState:null,error:"Stream cancelled",timestamp:new Date().toISOString()}),Os(n,{last_reply_status:"error",last_error:"Stream cancelled"}),lt(Bt,n,"Stream cancelled"),d;if(!((c=($t.value[n]??[]).find(h=>h.id===o))!=null&&c.text.trim()))try{const h=await Mp(n,s);Vt(n,o,{text:h.text.trim()||"(empty reply)",delivery:"delivered",streamState:null,details:h.details,error:null,timestamp:new Date().toISOString()}),Vt(n,a,{delivery:"delivered",error:null}),Os(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(h.text.trim()||"(empty reply)").slice(0,200),last_error:null}),await Sa();return}catch{}const f=d instanceof Error?d.message:`Failed to send direct message to ${n}`;throw Vt(n,o,{delivery:"error",streamState:null,error:f,timestamp:new Date().toISOString()}),Vt(n,a,{delivery:"error",error:f}),Os(n,{last_reply_status:"error",last_error:f}),lt(Bt,n,f),d}finally{Fc(n),lt(ka,n,!1),await Sa()}}async function d_(t,e){const n=t.trim();if(!n)return null;lt(_o,n,!0),lt(Bt,n,null);try{const s=await Ss({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=Qm(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const l=se.value[n];ri(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??$t.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Sa(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw lt(Bt,n,a),s}finally{lt(_o,n,!1)}}async function u_(t,e){const n=t.trim();if(!n)return null;lt(vo,n,!0),lt(Bt,n,null);try{const s=await Ss({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Zm(s.result),o=(a==null?void 0:a.after)??null;if(o){const l=se.value[n];ri(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??$t.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Sa(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw lt(Bt,n,a),s}finally{lt(vo,n,!1)}}function p_(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function m_(t){var o;const e=((o=t.status)==null?void 0:o.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}function __(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}function v_(t){return Array.isArray(t)?t.map(e=>{if(!v(e))return null;const n=u(e.ts_unix),s=u(e.context_ratio);if(n==null||s==null)return null;const a=v(e.handoff)?e.handoff:null;return{ts:n,context_ratio:s,context_tokens:u(e.context_tokens)??0,context_max:u(e.context_max)??0,latency_ms:u(e.latency_ms)??0,generation:u(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:u(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:u(e.cost_usd)??Number.NaN,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?u(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function f_(t){if(!v(t))return;const e={};for(const[n,s]of Object.entries(t)){if(n==="top_tools"){if(!Array.isArray(s))continue;const o=s.filter(l=>v(l)&&typeof l.tool=="string"&&l.tool.trim()!=="");o.length>0&&(e.top_tools=o);continue}const a=u(s);a!=null&&(e[n]=a)}return Object.keys(e).length>0?e:void 0}function g_(t){if(!v(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);if(!e||!n||!s)return null;const a=r(t.quiet_reason)??null;return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:ot(t.last_reply_at)??r(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:u(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:r(t.summary),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0,continuity_state:r(t.continuity_state)??null,continuity_summary:r(t.continuity_summary)??null}}function $_(t){return(Array.isArray(t)?t:v(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!v(n))return null;const s=v(n.agent)?n.agent:null,a=v(n.context)?n.context:null,o=f_(n.metrics_window),l=r(n.name);if(!l)return null;const c=u(n.context_ratio)??u(a==null?void 0:a.context_ratio),d=r(n.status)??r(s==null?void 0:s.status)??"offline",p=r(n.model)??r(n.active_model)??r(n.primary_model),m=H(n.skill_secondary),f=v_(n.metrics_series),h=a?{source:r(a.source),context_ratio:u(a.context_ratio),context_tokens:u(a.context_tokens),context_max:u(a.context_max),message_count:u(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,y=s?{name:r(s.name),exists:typeof s.exists=="boolean"?s.exists:void 0,error:r(s.error),agent_type:r(s.agent_type),status:r(s.status),current_task:r(s.current_task)??null,joined_at:r(s.joined_at),last_seen:r(s.last_seen),last_seen_ago_s:u(s.last_seen_ago_s),capabilities:H(s.capabilities),is_zombie:typeof s.is_zombie=="boolean"?s.is_zombie:void 0}:void 0;return{name:l,runtime_class:n.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:typeof n.desired=="boolean"?n.desired:void 0,resident_registered:typeof n.resident_registered=="boolean"?n.resident_registered:void 0,reconcile_status:r(n.reconcile_status)??null,emoji:r(n.emoji),koreanName:r(n.koreanName)??r(n.korean_name),agent_name:r(n.agent_name),trace_id:r(n.trace_id),model:p,primary_model:r(n.primary_model),active_model:r(n.active_model),next_model_hint:r(n.next_model_hint)??null,status:p_(d),presence_keepalive:typeof n.presence_keepalive=="boolean"?n.presence_keepalive:void 0,presence_keepalive_sec:u(n.presence_keepalive_sec),keepalive_running:typeof n.keepalive_running=="boolean"?n.keepalive_running:void 0,proactive_enabled:typeof n.proactive_enabled=="boolean"?n.proactive_enabled:void 0,proactive_idle_sec:u(n.proactive_idle_sec),proactive_cooldown_sec:u(n.proactive_cooldown_sec),last_heartbeat:r(n.last_heartbeat)??r(s==null?void 0:s.last_seen),generation:u(n.generation),turn_count:u(n.turn_count)??u(n.total_turns),keeper_age_s:u(n.keeper_age_s),last_turn_ago_s:u(n.last_turn_ago_s),last_handoff_ago_s:u(n.last_handoff_ago_s),last_compaction_ago_s:u(n.last_compaction_ago_s),last_proactive_ago_s:u(n.last_proactive_ago_s),last_proactive_preview:r(n.last_proactive_preview)??null,context_ratio:c,context_tokens:u(n.context_tokens)??u(a==null?void 0:a.context_tokens),context_max:u(n.context_max)??u(a==null?void 0:a.context_max),context_source:r(n.context_source)??r(a==null?void 0:a.source),context:h,traits:H(n.traits),interests:H(n.interests),primaryValue:r(n.primaryValue)??r(n.primary_value),activityLevel:u(n.activityLevel)??u(n.activity_level),memory_recent_note:r(n.memory_recent_note)??null,recent_input_preview:r(n.recent_input_preview)??null,recent_output_preview:r(n.recent_output_preview)??null,recent_tool_names:H(n.recent_tool_names)??[],allowed_tool_names:H(n.allowed_tool_names)??[],latest_tool_names:H(n.latest_tool_names)??[],latest_tool_call_count:u(n.latest_tool_call_count)??null,tool_audit_source:r(n.tool_audit_source)??null,tool_audit_at:ot(n.tool_audit_at)??r(n.tool_audit_at)??null,conversation_tail_count:u(n.conversation_tail_count),k2k_count:u(n.k2k_count),handoff_count_total:u(n.handoff_count_total)??u(n.trace_history_count),compaction_count:u(n.compaction_count),last_compaction_saved_tokens:u(n.last_compaction_saved_tokens),diagnostic:g_(n.diagnostic),skill_primary:r(n.skill_primary)??null,skill_secondary:m,skill_reason:r(n.skill_reason)??null,metrics_series:f.length>0?f:void 0,metrics_window:o,agent:y}}).filter(n=>n!==null)}function Ce(t){return(t??"").trim().toLowerCase()}function bt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function oa(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Ds(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Ln(t){return t.last_heartbeat??Ds(t.last_turn_ago_s)??Ds(t.last_proactive_ago_s)??Ds(t.last_handoff_ago_s)??Ds(t.last_compaction_ago_s)}function h_(t){const e=t.title.trim();return e||oa(t.content)}function y_(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function b_(t,e,n,s,a={}){var R;const o=Ce(t),l=e.filter(L=>Ce(L.assignee)===o&&(L.status==="claimed"||L.status==="in_progress")).length,c=n.filter(L=>Ce(L.from)===o).sort((L,S)=>bt(S.timestamp)-bt(L.timestamp))[0],d=s.filter(L=>Ce(L.agent)===o||Ce(L.author)===o).sort((L,S)=>bt(S.timestamp)-bt(L.timestamp))[0],p=(a.boardPosts??[]).filter(L=>Ce(L.author)===o).sort((L,S)=>bt(S.updated_at||S.created_at)-bt(L.updated_at||L.created_at))[0],m=(a.keepers??[]).filter(L=>Ce(L.name)===o&&Ln(L)!==null).sort((L,S)=>bt(Ln(S)??0)-bt(Ln(L)??0))[0],f=c?bt(c.timestamp):0,h=d?bt(d.timestamp):0,y=p?bt(p.updated_at||p.created_at):0,C=m?bt(Ln(m)??0):0,_=a.lastSeen?bt(a.lastSeen):0,k=((R=a.currentTask)==null?void 0:R.trim())||(l>0?`${l} claimed tasks`:null);if(f===0&&h===0&&y===0&&C===0&&_===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:k};const b=[c?{timestamp:c.timestamp,ts:f,text:oa(c.content)}:null,p?{timestamp:p.updated_at||p.created_at,ts:y,text:`Post: ${oa(h_(p))}`}:null,m?{timestamp:Ln(m),ts:C,text:y_(m)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:h,text:oa(d.text)}:null].filter(L=>L!==null).sort((L,S)=>S.ts-L.ts)[0];return b&&b.ts>=_?{activeAssignedCount:l,lastActivityAt:b.timestamp,lastActivityText:b.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:k??"Presence heartbeat"}}const Gt=$([]),pe=$([]),fo=$([]),ie=$([]),dt=$(null),k_=$(null),x_=$(null),Uc=$([]),Hc=$([]),Wc=$([]),Gc=$([]),Jc=$(null),Vc=$([]),er=$([]),Yc=$([]),go=$(new Map),li=$([]),ts=$("recent"),Ee=$(!0),Xc=$(null),ne=$(""),pn=$([]),Fn=$(!1),Qc=$(new Map),nr=$("unknown"),mn=$(null),$o=$(!1),es=$(!1),ho=$(!1),Kn=$(!1),sr=$(null),Ca=$(!1),Aa=$(null),Zc=$(null),yo=$(null),S_=$(null),C_=$(null),A_=$(null);wt(()=>Gt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const td=wt(()=>{const t=pe.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),ed=wt(()=>{const t=new Map,e=pe.value,n=fo.value,s=ya.value,a=li.value,o=ie.value;for(const l of Gt.value)t.set(l.name.trim().toLowerCase(),b_(l.name,e,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:o}));return t});wt(()=>{var e;const t=new Map;for(const n of ie.value){const s=((e=n.status)==null?void 0:e.toLowerCase())??"";if(s==="offline"||s==="inactive"){t.set(n.name,"offline");continue}!n.metrics_series||n.metrics_series.length===0||t.set(n.name,m_(n))}return t});const T_=12e4;wt(()=>{const t=Date.now(),e=new Set,n=go.value;for(const s of ie.value){const a=__(s,n);a!=null&&t-a>T_&&e.add(s.name)}return e});function I_(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function R_(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function M_(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function L_(t){if(!v(t))return null;const e=r(t.name);return e?{name:e,agent_type:r(t.agent_type),status:R_(t.status),current_task:r(t.current_task)??null,joined_at:r(t.joined_at),last_seen:r(t.last_seen),capabilities:H(t.capabilities),emoji:r(t.emoji),koreanName:r(t.koreanName)??r(t.korean_name),model:r(t.model),traits:H(t.traits),interests:H(t.interests),activityLevel:u(t.activityLevel)??u(t.activity_level),primaryValue:r(t.primaryValue)??r(t.primary_value)}:null}function E_(t){if(!v(t))return null;const e=r(t.id),n=r(t.title);return!e||!n?null:{id:e,title:n,status:M_(t.status),priority:u(t.priority),assignee:r(t.assignee),description:r(t.description),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function P_(t){if(!v(t))return null;const e=r(t.from)??r(t.from_agent)??"system",n=r(t.content)??"",s=r(t.timestamp)??new Date().toISOString();return{id:r(t.id),seq:u(t.seq),from:e,content:n,timestamp:s,type:r(t.type)}}function ar(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="ok"||e==="warn"||e==="bad"?e:"ok"}function z_(t){return v(t)?{active_sessions:u(t.active_sessions),blocked_sessions:u(t.blocked_sessions),active_operations:u(t.active_operations),blocked_operations:u(t.blocked_operations),runtime_pressure:u(t.runtime_pressure),worker_alerts:u(t.worker_alerts),continuity_alerts:u(t.continuity_alerts),priority_items:u(t.priority_items),todo_tasks:u(t.todo_tasks),claimed_tasks:u(t.claimed_tasks),running_tasks:u(t.running_tasks),done_tasks:u(t.done_tasks),cancelled_tasks:u(t.cancelled_tasks),keepers:u(t.keepers)}:null}function me(t){if(!v(t))return null;const e=r(t.surface),n=r(t.label),s=r(t.target_type),a=r(t.target_id),o=r(t.focus_kind);return!e||!n||!s||!a||!o?null:{surface:e==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:o,operation_id:r(t.operation_id)??null,command_surface:r(t.command_surface)??null}}function w_(t){if(!v(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.summary),a=r(t.target_type),o=r(t.target_id);return!e||!s||!a||!o||n!=="session"&&n!=="operation"?null:{id:e,kind:n,severity:ar(t.severity),status:r(t.status),summary:s,target_type:a,target_id:o,linked_session_id:r(t.linked_session_id)??null,linked_operation_id:r(t.linked_operation_id)??null,last_seen_at:r(t.last_seen_at)??null,top_handoff:me(t.top_handoff),intervene_handoff:me(t.intervene_handoff),command_handoff:me(t.command_handoff)}}function N_(t){if(!v(t))return null;const e=r(t.session_id),n=r(t.goal);return!e||!n?null:{session_id:e,goal:n,room:r(t.room)??null,status:r(t.status),health:r(t.health),member_names:H(t.member_names),linked_operation_id:r(t.linked_operation_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,runtime_blocker:r(t.runtime_blocker)??null,worker_gap_summary:r(t.worker_gap_summary)??null,last_activity_at:r(t.last_activity_at)??null,last_activity_summary:r(t.last_activity_summary)??null,communication_summary:r(t.communication_summary)??null,active_count:u(t.active_count),seen_count:u(t.seen_count),planned_count:u(t.planned_count),required_count:u(t.required_count),counts_basis:r(t.counts_basis)??null,top_handoff:me(t.top_handoff),intervene_handoff:me(t.intervene_handoff),command_handoff:me(t.command_handoff)}}function j_(t){if(!v(t))return null;const e=r(t.operation_id),n=r(t.objective);return!e||!n?null:{operation_id:e,objective:n,status:r(t.status),stage:r(t.stage)??null,assigned_unit_id:r(t.assigned_unit_id)??null,assigned_unit_label:r(t.assigned_unit_label)??null,linked_session_id:r(t.linked_session_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,blocker_summary:r(t.blocker_summary)??null,search_status:r(t.search_status)??null,next_tool:r(t.next_tool)??null,updated_at:r(t.updated_at)??null,top_handoff:me(t.top_handoff),command_handoff:me(t.command_handoff)}}function kl(t){if(!v(t))return null;const e=r(t.name)??r(t.agent_name),n=r(t.note),s=r(t.focus),a=r(t.state);if(!e||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline")return null;const o=r(t.signal_truth),l=o==="live"||o==="stale"||o==="absent"?o:void 0,c=r(t.evidence_source),d=c==="message"||c==="presence"||c==="none"?c:void 0;return{name:e,agent_name:r(t.agent_name),status:r(t.status),tone:ar(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,last_signal_age_sec:u(t.last_signal_age_sec)??null,signal_truth:l,evidence_source:d,active_task_count:u(t.active_task_count),related_session_id:r(t.related_session_id)??null,related_operation_id:r(t.related_operation_id)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),model:r(t.model)??null,recent_output_preview:r(t.recent_output_preview)??null,recent_event:r(t.recent_event)??null}}function O_(t){if(!v(t))return null;const e=r(t.last_system_skip_reason)??r(t.last_skip_reason)??null;return{checked:u(t.checked),acted:u(t.acted),passed:u(t.passed),skipped:u(t.skipped),failed:u(t.failed),last_tick_at:r(t.last_tick_at)??null,last_skip_reason:e,last_pass_reason:r(t.last_pass_reason)??null,last_system_skip_reason:e,strategy:r(t.strategy)??null,queue_depth:u(t.queue_depth)??null,activity_report:r(t.activity_report)??null}}function D_(t){if(!v(t))return null;const e=r(t.agent_name),n=r(t.outcome);return!e||!n?null:{agent_name:e,trigger:r(t.trigger)??null,outcome:n,summary:r(t.summary)??null,reason:r(t.reason)??null,allowed_tool_names:H(t.allowed_tool_names)??[],used_tool_names:H(t.used_tool_names)??[],used_tool_call_count:u(t.used_tool_call_count)??null,action_kind:r(t.action_kind)??"none",tool_audit_source:r(t.tool_audit_source)??null,tool_audit_at:r(t.tool_audit_at)??null,checked_at:r(t.checked_at)??null,decision_reason:r(t.decision_reason)??null,worker_name:r(t.worker_name)??null,failure_reason:r(t.failure_reason)??null}}function q_(t){if(!v(t))return null;const e=r(t.name),n=r(t.note),s=r(t.focus),a=r(t.state);return!e||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:e,agent_name:r(t.agent_name)??null,status:r(t.status),tone:ar(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,last_autonomous_action_at:r(t.last_autonomous_action_at)??null,generation:u(t.generation),turn_count:u(t.turn_count),context_ratio:u(t.context_ratio)??null,continuity:r(t.continuity)??null,lifecycle:r(t.lifecycle)??null,related_session_id:r(t.related_session_id)??null,model:r(t.model)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),skill_reason:r(t.skill_reason)??null,recent_input_preview:r(t.recent_input_preview)??null,recent_output_preview:r(t.recent_output_preview)??null,recent_tool_names:H(t.recent_tool_names)??[],allowed_tool_names:H(t.allowed_tool_names)??[],latest_tool_names:H(t.latest_tool_names)??[],latest_tool_call_count:u(t.latest_tool_call_count)??null,tool_audit_source:r(t.tool_audit_source)??null,tool_audit_at:r(t.tool_audit_at)??null,last_proactive_preview:r(t.last_proactive_preview)??null,continuity_summary:r(t.continuity_summary)??null,skill_route_summary:r(t.skill_route_summary)??null}}function xl(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function F_(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>xl(s)-xl(a)).slice(-500)}function K_(t){if(!v(t))return;const e=r(t.release_version),n=ot(t.started_at),s=u(t.uptime_seconds);if(!(!e||!n||s==null))return{release_version:e,commit:r(t.commit)??null,started_at:n,uptime_seconds:s}}function B_(t){if(v(t))return{enabled:t.enabled===!0,alive:t.alive===!0,status:r(t.status)??void 0,tick_in_progress:typeof t.tick_in_progress=="boolean"?t.tick_in_progress:void 0,tick_count:u(t.tick_count)??void 0,check_interval_sec:u(t.check_interval_sec)??void 0,last_tick_started_at:ot(t.last_tick_started_at)??r(t.last_tick_started_at)??null,last_tick_completed_at:ot(t.last_tick_completed_at)??r(t.last_tick_completed_at)??null,next_tick_due_at:ot(t.next_tick_due_at)??r(t.next_tick_due_at)??null,last_health_check_at:ot(t.last_health_check_at)??r(t.last_health_check_at)??null,last_intervention:r(t.last_intervention)??void 0,last_decision_source:r(t.last_decision_source)??void 0,last_action:r(t.last_action)??void 0,last_target:r(t.last_target)??null,last_reason:r(t.last_reason)??null,last_error:r(t.last_error)??null,circuit_open:typeof t.circuit_open=="boolean"?t.circuit_open:void 0,circuit_open_until:ot(t.circuit_open_until)??r(t.circuit_open_until)??null,can_spawn:typeof t.can_spawn=="boolean"?t.can_spawn:void 0,can_retire:typeof t.can_retire=="boolean"?t.can_retire:void 0,last_spawn_attempt_at:ot(t.last_spawn_attempt_at)??r(t.last_spawn_attempt_at)??null,last_retirement_attempt_at:ot(t.last_retirement_attempt_at)??r(t.last_retirement_attempt_at)??null,spawns_today:u(t.spawns_today)??void 0,retirements_today:u(t.retirements_today)??void 0,health_summary:v(t.health_summary)?{total_agents:u(t.health_summary.total_agents)??void 0,active_agents:u(t.health_summary.active_agents)??void 0,idle_agents:u(t.health_summary.idle_agents)??void 0,todo_count:u(t.health_summary.todo_count)??void 0,high_priority_todo:u(t.health_summary.high_priority_todo)??void 0,orphan_count:u(t.health_summary.orphan_count)??void 0,homeostatic_score:u(t.health_summary.homeostatic_score)??void 0,needs_workers:typeof t.health_summary.needs_workers=="boolean"?t.health_summary.needs_workers:void 0}:void 0}}function U_(t){if(v(t))return{enabled:t.enabled===!0,mode:r(t.mode)??void 0,masc_enabled:typeof t.masc_enabled=="boolean"?t.masc_enabled:void 0,masc_loops_running:typeof t.masc_loops_running=="boolean"?t.masc_loops_running:void 0,runtime_owner:r(t.runtime_owner)??null,zombie_loop_running:typeof t.zombie_loop_running=="boolean"?t.zombie_loop_running:void 0,gc_loop_running:typeof t.gc_loop_running=="boolean"?t.gc_loop_running:void 0,lodge_enabled:typeof t.lodge_enabled=="boolean"?t.lodge_enabled:void 0,lodge_loop_started:typeof t.lodge_loop_started=="boolean"?t.lodge_loop_started:void 0,lodge_running:typeof t.lodge_running=="boolean"?t.lodge_running:void 0,last_zombie_cleanup:ot(t.last_zombie_cleanup)??r(t.last_zombie_cleanup)??null,last_gc:ot(t.last_gc)??r(t.last_gc)??null,last_lodge:ot(t.last_lodge)??r(t.last_lodge)??null,last_zombie_result:r(t.last_zombie_result)??null,last_gc_result:r(t.last_gc_result)??null,last_lodge_result:v(t.last_lodge_result)?{ok:typeof t.last_lodge_result.ok=="boolean"?t.last_lodge_result.ok:void 0,message:r(t.last_lodge_result.message)??void 0}:null}}function H_(t){if(v(t))return{enabled:t.enabled===!0,started:t.started===!0,agent_name:r(t.agent_name)??null,llm_enabled:typeof t.llm_enabled=="boolean"?t.llm_enabled:void 0,uptime_s:u(t.uptime_s)??void 0,embedded_guardian_loops_running:typeof t.embedded_guardian_loops_running=="boolean"?t.embedded_guardian_loops_running:void 0,guardian_runtime_owner:r(t.guardian_runtime_owner)??null,consumers:H(t.consumers)}}function W_(t){if(!v(t))return;const e=v(t.last_result)?t.last_result:null;return{enabled:t.enabled===!0,strategy:r(t.strategy)??void 0,queue_depth:u(t.queue_depth)??void 0,processed_events:u(t.processed_events)??void 0,active_keepers:u(t.active_keepers)??void 0,last_event_at:ot(t.last_event_at)??r(t.last_event_at)??null,last_social_action_at:ot(t.last_social_action_at)??r(t.last_social_action_at)??null,last_pass_reason:r(t.last_pass_reason)??null,last_system_skip_reason:r(t.last_system_skip_reason)??null,total_checks:u(t.total_checks)??void 0,total_acted:u(t.total_acted)??void 0,total_passed:u(t.total_passed)??void 0,total_skipped:u(t.total_skipped)??void 0,total_failed:u(t.total_failed)??void 0,last_result:e?{checked:u(e.checked)??void 0,acted:u(e.acted)??void 0,passed:u(e.passed)??void 0,skipped:u(e.skipped)??void 0,failed:u(e.failed)??void 0,last_tick_at:ot(e.last_tick_at)??r(e.last_tick_at)??null,last_pass_reason:r(e.last_pass_reason)??null,last_system_skip_reason:r(e.last_system_skip_reason)??null,activity_report:r(e.activity_report)??null,checkins:Array.isArray(e.checkins)?e.checkins.map(n=>({name:r(n.agent_name)??"",trigger:r(n.trigger)??void 0,outcome:r(n.outcome)??void 0,summary:r(n.summary)??void 0,reason:r(n.reason)??void 0})).filter(n=>n.name!==""):[]}:null}}function nd(t,e){return v(t)?{...t,generated_at:e??ot(t.generated_at)??void 0,build:K_(t.build),lodge:Xm(t.lodge)??void 0,social_runtime:W_(t.social_runtime),gardener:B_(t.gardener)??void 0,guardian:U_(t.guardian)??void 0,sentinel:H_(t.sentinel)??void 0}:null}function sd(t,e){return e?t?{...t,...e,build:e.build??t.build,generated_at:e.generated_at??t.generated_at}:e:t}function G_(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function J_(t){if(!v(t))return null;const e=u(t.iteration);if(e==null)return null;const n=u(t.metric_before)??0,s=u(t.metric_after)??n,a=v(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:u(t.delta)??s-n,changes:r(t.changes)??"",failed_attempts:r(t.failed_attempts)??"",next_suggestion:r(t.next_suggestion)??"",elapsed_ms:u(t.elapsed_ms)??0,cost_usd:u(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:u(a.tool_call_count)??0,tool_names:H(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function V_(t){var o,l;if(!v(t))return null;const e=r(t.loop_id);if(!e)return null;const n=u(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(J_).filter(c=>c!==null):[],a=u(t.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:e,profile:r(t.profile)??"unknown",status:G_(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:r(t.error_message)??r(t.error_reason)??null,stop_reason:r(t.stop_reason)??r(t.reason)??null,current_iteration:u(t.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:u(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(t.target)??"",stagnation_streak:u(t.stagnation_streak)??0,stagnation_limit:u(t.stagnation_limit)??0,elapsed_seconds:u(t.elapsed_seconds)??0,updated_at:ot(t.updated_at)??null,stopped_at:ot(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:u(t.latest_tool_call_count)??0,latest_tool_names:H(t.latest_tool_names)??[],session_id:r(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function Cs(){$o.value=!0;try{await Promise.all([id(),Pe()]),Zc.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{$o.value=!1}}async function ad(){Ca.value=!0,Aa.value=null;try{const t=await Op();sr.value=t,A_.value=new Date().toISOString()}catch(t){Aa.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{Ca.value=!1}}function Y_(t){var e;return((e=sr.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function X_(t){var n;const e=((n=sr.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(o=>o.id===t);if(a)return a}return null}function Q_(t){var s,a;pn.value=(Array.isArray(t.goals)?t.goals:[]).map(o=>{if(!v(o))return null;const l=r(o.id),c=r(o.title),d=r(o.horizon),p=r(o.status),m=r(o.created_at),f=r(o.updated_at);return!l||!c||!d||!p||!m||!f?null:{id:l,horizon:d,title:c,metric:r(o.metric)??null,target_value:r(o.target_value)??null,due_date:r(o.due_date)??null,priority:u(o.priority)??3,status:p,parent_goal_id:r(o.parent_goal_id)??null,last_review_note:r(o.last_review_note)??null,last_review_at:r(o.last_review_at)??null,created_at:m,updated_at:f}}).filter(o=>o!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const o of n){const l=V_(o);l&&e.set(l.loop_id,l)}Qc.value=e,mn.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,nr.value=mn.value?"error":e.size===0?"idle":"ready"}async function id(){try{const t=await Pp(),e=nd(t.status,t.generated_at);e&&(dt.value=sd(dt.value,e))}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Pe(){var t;try{const e=await wp(),n=nd(e.status,e.generated_at),s=(t=dt.value)==null?void 0:t.room;n&&(dt.value=sd(dt.value,n));const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Gt.value=(Array.isArray(e.agents)?e.agents:[]).map(L_).filter(d=>d!==null),pe.value=(Array.isArray(e.tasks)?e.tasks:[]).map(E_).filter(d=>d!==null);const o=(Array.isArray(e.messages)?e.messages:[]).map(P_).filter(d=>d!==null);fo.value=a?o:F_(fo.value,o),ie.value=$_(e.keepers),x_.value=z_(e.summary);const l=Array.isArray(e.social_checkins)?e.social_checkins:[],c=Array.isArray(e.lodge_checkins)?e.lodge_checkins:[];Jc.value=O_(e.social_tick??e.lodge_tick),Vc.value=(l.length>0?l:c).map(D_).filter(d=>d!==null),Uc.value=(Array.isArray(e.execution_queue)?e.execution_queue:Array.isArray(e.priority_queue)?e.priority_queue:[]).map(w_).filter(d=>d!==null),Hc.value=(Array.isArray(e.session_briefs)?e.session_briefs:[]).map(N_).filter(d=>d!==null),Wc.value=(Array.isArray(e.operation_briefs)?e.operation_briefs:[]).map(j_).filter(d=>d!==null),Gc.value=(Array.isArray(e.worker_support_briefs)?e.worker_support_briefs:Array.isArray(e.worker_briefs)?e.worker_briefs:[]).map(kl).filter(d=>d!==null),er.value=(Array.isArray(e.continuity_briefs)?e.continuity_briefs:[]).map(q_).filter(d=>d!==null),Yc.value=(Array.isArray(e.offline_worker_briefs)?e.offline_worker_briefs:[]).map(kl).filter(d=>d!==null),k_.value=null,Zc.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function _e(){es.value=!0;try{const t=await Np(ts.value,{excludeSystem:Ee.value});li.value=t.posts??[],yo.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{es.value=!1}}async function ve(){var t;ho.value=!0;try{const e=ne.value||((t=dt.value)==null?void 0:t.room)||"default";ne.value||(ne.value=e);const n=await Im(e);Xc.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{ho.value=!1}}async function ir(){Fn.value=!0,Kn.value=!0;try{const t=await Bp();Q_(t),S_.value=new Date().toISOString(),C_.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),nr.value="error",mn.value=t instanceof Error?t.message:String(t)}finally{Fn.value=!1,Kn.value=!1}}async function od(){return ir()}const or=$(null),bo=$(!1),Ta=$(null);let En=null;function Z_(t){return v(t)?{room:r(t.room)??r(t.current_room),room_base_path:r(t.room_base_path),cluster:r(t.cluster),project:r(t.project),paused:j(t.paused),version:r(t.version),generated_at:r(t.generated_at),tempo_interval_s:u(t.tempo_interval_s)}:null}function tv(t){return v(t)?{active_sessions:u(t.active_sessions),blocked_sessions:u(t.blocked_sessions),active_operations:u(t.active_operations),blocked_operations:u(t.blocked_operations),runtime_pressure:u(t.runtime_pressure),worker_alerts:u(t.worker_alerts),continuity_alerts:u(t.continuity_alerts),priority_items:u(t.priority_items),keepers:u(t.keepers)}:null}function ev(t){if(!v(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.severity),a=r(t.summary),o=r(t.target_type),l=r(t.target_id);return!e||!n||!s||!a||!o||!l?null:{id:e,kind:n,severity:s,summary:a,target_type:o,target_id:l,status:r(t.status),linked_session_id:r(t.linked_session_id)??null,linked_operation_id:r(t.linked_operation_id)??null,last_seen_at:r(t.last_seen_at)??null,top_handoff:v(t.top_handoff)?t.top_handoff:null,intervene_handoff:v(t.intervene_handoff)?t.intervene_handoff:null,command_handoff:v(t.command_handoff)?t.command_handoff:null}}function nv(t){if(!v(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function sv(t){if(!v(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:j(t.confirm_required),suggested_payload:v(t.suggested_payload)?t.suggested_payload:void 0,preview:t.preview}}function av(t){return v(t)?{actor_filter:r(t.actor_filter)??null,filter_active:j(t.filter_active)??!1,visible_count:u(t.visible_count)??0,total_count:u(t.total_count)??0,hidden_count:u(t.hidden_count)??0,hidden_actors:H(t.hidden_actors),confirm_required_actions:ct(t.confirm_required_actions).flatMap(e=>{if(!v(e))return[];const n=r(e.action_type),s=r(e.target_type);return!n||!s?[]:[{action_type:n,target_type:s,description:r(e.description),confirm_required:j(e.confirm_required)}]})}:null}function iv(t){return v(t)?{count:u(t.count)??0,bad_count:u(t.bad_count)??0,warn_count:u(t.warn_count)??0,provenance:r(t.provenance)??null,top_item:nv(t.top_item)}:null}function ov(t){return v(t)?{count:u(t.count)??0,provenance:r(t.provenance)??null,top_action:sv(t.top_action)}:null}function rv(t){if(!v(t))return null;const e=r(t.label),n=r(t.reason),s=r(t.source),a=r(t.provenance);return!e||!n||!s||!a?null:{label:e,reason:n,source:s,provenance:a,target_kind:r(t.target_kind)??null,target_id:r(t.target_id)??null,suggested_tab:r(t.suggested_tab)??null,suggested_surface:r(t.suggested_surface)??null,suggested_params:v(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([o,l])=>{const c=r(l);return c?[o,c]:null}).filter(o=>o!==null)):{}}}function lv(t){const e=v(t)?t:{},n=v(e.room)?e.room:{},s=v(e.execution)?e.execution:{},a=v(e.command)?e.command:{},o=v(e.operator)?e.operator:{};return{generated_at:r(e.generated_at),room:{status:Z_(n.status),counts:v(n.counts)?{agents:u(n.counts.agents),tasks:u(n.counts.tasks),keepers:u(n.counts.keepers)}:void 0,provenance:r(n.provenance)??null},execution:{summary:tv(s.summary),top_queue:ev(s.top_queue),provenance:r(s.provenance)??null},command:{active_operations:u(a.active_operations),active_detachments:u(a.active_detachments),pending_approvals:u(a.pending_approvals),bad_alerts:u(a.bad_alerts),warn_alerts:u(a.warn_alerts),moving_lanes:u(a.moving_lanes),active_lanes:u(a.active_lanes),provenance:r(a.provenance)??null},operator:{health:r(o.health)??null,attention_summary:iv(o.attention_summary),recommendation_summary:ov(o.recommendation_summary),pending_confirm_summary:av(o.pending_confirm_summary),provenance:r(o.provenance)??null},focus:rv(e.focus)}}async function ze(){return En||(bo.value=!0,Ta.value=null,En=(async()=>{try{const t=await zp();or.value=lv(t)}catch(t){Ta.value=t instanceof Error?t.message:"Failed to load room truth"}finally{bo.value=!1,En=null}})(),En)}let ra=null;function cv(t){ra=t}let la=null;function dv(t){la=t}let ca=null;function uv(t){ca=t}const we={};let Si=null;function Ae(t,e,n=500){we[t]&&clearTimeout(we[t]),we[t]=setTimeout(()=>{e(),delete we[t]},n)}function pv(){const t=Cc.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(go.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),go.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&Ae("execution",Pe),I_(e.type)&&(Si||(Si=setTimeout(()=>{Cs(),la==null||la(),ca==null||ca(),Si=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&Ae("execution",Pe),e.type==="broadcast"&&Ae("execution",Pe),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&Ae("execution",Pe),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&Ae("board",_e),e.type.startsWith("decision_")&&Ae("governance",()=>ra==null?void 0:ra()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&Ae("mdal",od,350)}});return()=>{t();for(const e of Object.keys(we))clearTimeout(we[e]),delete we[e]}}let Bn=null;function mv(){Bn||(Bn=setInterval(()=>{$e.value,Cs()},1e4))}function _v(){Bn&&(clearInterval(Bn),Bn=null)}function rd(t){if(!v(t))return null;const e=r(t.action_type),n=r(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:r(t.description),confirm_required:j(t.confirm_required)}}function ld(t){if(!v(t))return null;const e=r(t.confirm_token)??r(t.token);return e?{confirm_token:e,actor:r(t.actor),action_type:r(t.action_type),target_type:r(t.target_type),target_id:r(t.target_id)??null,delegated_tool:r(t.delegated_tool),created_at:r(t.created_at),preview:t.preview}:null}function cd(t){return v(t)?{actor_filter:r(t.actor_filter)??null,filter_active:j(t.filter_active)??!1,visible_count:u(t.visible_count)??0,total_count:u(t.total_count)??0,hidden_count:u(t.hidden_count)??0,hidden_actors:H(t.hidden_actors),confirm_required_actions:ct(t.confirm_required_actions).map(rd).filter(e=>e!==null)}:null}function vv(t){if(!v(t))return null;const e=ct(t.items,["confirms"]).map(ld).filter(s=>s!==null),n=cd(t.summary);return!n&&e.length===0?null:{items:e,summary:n??{actor_filter:null,filter_active:!1,visible_count:e.length,total_count:e.length,hidden_count:0,hidden_actors:[],confirm_required_actions:[]}}}function ci(t){var a,o,l,c;const e=(t==null?void 0:t.pending_confirm_envelope)??null,n=(e==null?void 0:e.items)??(t==null?void 0:t.pending_confirms)??[],s=(e==null?void 0:e.summary)??(t==null?void 0:t.pending_confirm_summary)??{actor_filter:null,filter_active:!1,visible_count:n.length,total_count:n.length,hidden_count:0,hidden_actors:[],confirm_required_actions:((a=t==null?void 0:t.available_actions)==null?void 0:a.filter(d=>d.confirm_required))??[]};return{items:n,summary:s,actor_filter:((o=s.actor_filter)==null?void 0:o.trim())||null,visible_count:s.visible_count??n.length,total_count:s.total_count??n.length,hidden_count:s.hidden_count??0,hidden_actors:s.hidden_actors??[],confirm_required_actions:(l=s.confirm_required_actions)!=null&&l.length?s.confirm_required_actions:((c=t==null?void 0:t.available_actions)==null?void 0:c.filter(d=>d.confirm_required))??[]}}const It=$(null),rr=$(null),Ht=$(null),ns=$(!1),he=$(null),ss=$(!1),bn=$(null),it=$(!1),Ia=$([]);let fv=1;function gv(t){return v(t)?{id:r(t.id),seq:u(t.seq),from:r(t.from)??r(t.from_agent)??"system",content:r(t.content)??"",timestamp:r(t.timestamp)??new Date().toISOString(),type:r(t.type)}:null}function $v(t){return v(t)?{room_id:r(t.room_id),current_room:r(t.current_room)??r(t.room),project:r(t.project),cluster:r(t.cluster),paused:j(t.paused),pause_reason:r(t.pause_reason)??null,paused_by:r(t.paused_by)??null,paused_at:r(t.paused_at)??null}:{}}function Sl(t){if(!v(t))return;const e=Object.entries(t).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function dd(t){if(!v(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function Un(t){if(!v(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:j(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function ud(t){return v(t)?{enabled:j(t.enabled),judge_online:j(t.judge_online),refreshing:j(t.refreshing),generated_at:r(t.generated_at)??null,expires_at:r(t.expires_at)??null,model_used:r(t.model_used)??null,keeper_name:r(t.keeper_name)??null,last_error:r(t.last_error)??null}:null}function Ci(t){return v(t)?{summary:r(t.summary)??null,confidence:u(t.confidence)??null,provenance:r(t.provenance)??null,authoritative:j(t.authoritative),surface:r(t.surface)??null,fresh_until:r(t.fresh_until)??null,keeper_name:r(t.keeper_name)??null,fallback_used:j(t.fallback_used),disagreement_with_truth:j(t.disagreement_with_truth)}:null}function hv(t){return v(t)?{judgment_id:r(t.judgment_id)??void 0,surface:r(t.surface)??null,target_type:r(t.target_type)??null,target_id:r(t.target_id)??null,status:r(t.status)??null,summary:r(t.summary)??null,confidence:u(t.confidence)??null,generated_at:r(t.generated_at)??null,fresh_until:r(t.fresh_until)??null,keeper_name:r(t.keeper_name)??null,model_name:r(t.model_name)??null,runtime_name:r(t.runtime_name)??null,evidence_refs:H(t.evidence_refs),recommended_action:Un(t.recommended_action),supersedes:H(t.supersedes),fallback_used:j(t.fallback_used),disagreement_with_truth:j(t.disagreement_with_truth),provenance:r(t.provenance)??null}:null}function yv(t){return v(t)?{actor:r(t.actor)??null,spawn_agent:r(t.spawn_agent)??null,spawn_role:r(t.spawn_role)??null,spawn_model:r(t.spawn_model)??null,worker_class:r(t.worker_class)??null,parent_actor:r(t.parent_actor)??null,capsule_mode:r(t.capsule_mode)??null,runtime_pool:r(t.runtime_pool)??null,lane_id:r(t.lane_id)??null,controller_level:r(t.controller_level)??null,control_domain:r(t.control_domain)??null,supervisor_actor:r(t.supervisor_actor)??null,model_tier:r(t.model_tier)??null,task_profile:r(t.task_profile)??null,risk_level:r(t.risk_level)??null,routing_confidence:u(t.routing_confidence)??null,routing_reason:r(t.routing_reason)??null,status:r(t.status)??"unknown",turn_count:u(t.turn_count)??0,empty_note_turn_count:u(t.empty_note_turn_count)??0,has_turn:j(t.has_turn)??!1,last_turn_ts_iso:r(t.last_turn_ts_iso)??null}:null}function bv(t){if(!v(t))return null;const e=r(t.session_id);return e?{session_id:e,goal:r(t.goal),status:r(t.status),health:r(t.health),scale_profile:r(t.scale_profile),control_profile:r(t.control_profile),planned_worker_count:u(t.planned_worker_count),active_agent_count:u(t.active_agent_count),last_turn_age_sec:u(t.last_turn_age_sec)??null,attention_count:u(t.attention_count),recommended_action_count:u(t.recommended_action_count),top_attention:dd(t.top_attention),top_recommendation:Un(t.top_recommendation)}:null}function Cl(t){if(!v(t))return null;const e=r(t.loop_id),n=r(t.status);return!e&&!n?null:{loop_id:e??null,session_id:r(t.session_id)??null,status:n??null,current_cycle:u(t.current_cycle)??void 0,best_score:u(t.best_score)??null,last_decision:r(t.last_decision)??null,target_file:r(t.target_file)??null,workdir:r(t.workdir)??null,source_workdir:r(t.source_workdir)??null,program_note:r(t.program_note)??null,operation_id:r(t.operation_id)??null,queued_hypothesis:r(t.queued_hypothesis)??null,warnings:ct(t.warnings).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),error:r(t.error)??null}}function pd(t){const e=v(t)?t:{};return{trace_id:r(e.trace_id),target_type:r(e.target_type)??"room",target_id:r(e.target_id)??null,health:r(e.health),judgment_owner:r(e.judgment_owner)??null,authoritative_judgment_available:j(e.authoritative_judgment_available),resident_judge_runtime:ud(e.resident_judge_runtime),judgment:hv(e.judgment),active_guidance_layer:r(e.active_guidance_layer)??null,active_summary:Ci(e.active_summary),active_recommended_actions:ct(e.active_recommended_actions).map(Un).filter(n=>n!==null),active_recommendation_source:r(e.active_recommendation_source)??null,active_recommendation_summary:Ci(e.active_recommendation_summary),fallback_recommended_actions:ct(e.fallback_recommended_actions).map(Un).filter(n=>n!==null),recommendation_summary:Ci(e.recommendation_summary),swarm_status:v(e.swarm_status)?e.swarm_status:void 0,attention_items:ct(e.attention_items).map(dd).filter(n=>n!==null),recommended_actions:ct(e.recommended_actions).map(Un).filter(n=>n!==null),session_cards:ct(e.session_cards).map(bv).filter(n=>n!==null),worker_cards:ct(e.worker_cards).map(yv).filter(n=>n!==null)}}function kv(t){if(!v(t))return null;const e=v(t.status)?t.status:void 0,n=v(t.summary)?t.summary:v(e==null?void 0:e.summary)?e.summary:void 0,s=v(t.session)?t.session:v(e==null?void 0:e.session)?e.session:void 0,a=r(t.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const o=Sl(t.report_paths)??Sl(e==null?void 0:e.report_paths),l=ct(t.recent_events,["events"]).filter(v);return{session_id:a,status:r(t.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:u(t.progress_pct)??u(n==null?void 0:n.progress_pct),elapsed_sec:u(t.elapsed_sec)??u(n==null?void 0:n.elapsed_sec),remaining_sec:u(t.remaining_sec)??u(n==null?void 0:n.remaining_sec),done_delta_total:u(t.done_delta_total)??u(n==null?void 0:n.done_delta_total),summary:n,team_health:v(t.team_health)?t.team_health:v(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:v(t.communication_metrics)?t.communication_metrics:v(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:v(t.orchestration_state)?t.orchestration_state:v(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:v(t.cascade_metrics)?t.cascade_metrics:v(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:o,linked_autoresearch:Cl(t.linked_autoresearch)??Cl(e==null?void 0:e.linked_autoresearch)??null,session:s,recent_events:l}}function Al(t){if(!v(t))return null;const e=r(t.name);if(!e)return null;const n=v(t.context)?t.context:void 0;return{name:e,runtime_class:t.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:j(t.desired),resident_registered:j(t.resident_registered),agent_name:r(t.agent_name),status:r(t.status),autonomy_level:r(t.autonomy_level),context_ratio:u(t.context_ratio)??u(n==null?void 0:n.context_ratio),generation:u(t.generation),active_goal_ids:H(t.active_goal_ids),last_autonomous_action_at:r(t.last_autonomous_action_at)??null,last_turn_ago_s:u(t.last_turn_ago_s),model:r(t.model)??r(t.active_model)??r(t.primary_model)}}function xv(t){const e=v(t)?t:{},n=vv(e.pending_confirm_envelope);return{room:$v(e.room),sessions:ct(e.sessions,["items","sessions"]).map(kv).filter(s=>s!==null),keepers:ct(e.keepers,["items","keepers"]).map(Al).filter(s=>s!==null),resident_judge_runtime:ud(e.resident_judge_runtime),persistent_agents:ct(e.persistent_agents,["items","persistent_agents"]).map(Al).filter(s=>s!==null),recent_messages:ct(e.recent_messages,["messages"]).map(gv).filter(s=>s!==null),pending_confirms:(n==null?void 0:n.items)??ct(e.pending_confirms,["items","confirms"]).map(ld).filter(s=>s!==null),pending_confirm_envelope:n??void 0,pending_confirm_summary:(n==null?void 0:n.summary)??cd(e.pending_confirm_summary)??void 0,available_actions:ct(e.available_actions,["actions"]).map(rd).filter(s=>s!==null)}}function qs(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Tl(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Ra(t){Ia.value=[{...t,id:fv++,at:new Date().toISOString()},...Ia.value].slice(0,20)}function md(t){return t.confirm_required?qs(t.preview)||"Confirmation required":qs(t.result)||qs(t.executed_action)||qs(t.delegated_tool_result)||t.status}async function _t(){ns.value=!0,he.value=null;try{const t=await Wp();It.value=xv(t)}catch(t){he.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{ns.value=!1}}async function Be(){ss.value=!0,bn.value=null;try{const t=await Pc({targetType:"room"});rr.value=pd(t)}catch(t){bn.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{ss.value=!1}}async function ye(t){if(!t){Ht.value=null;return}ss.value=!0,bn.value=null;try{const e=await Pc({targetType:"team_session",targetId:t,includeWorkers:!0});Ht.value=pd(e)}catch(e){bn.value=e instanceof Error?e.message:"Failed to load session digest"}finally{ss.value=!1}}async function _d(t){var e;it.value=!0,he.value=null;try{const n=await Ss(t);return Ra({actor:t.actor,action_type:t.action_type,target_label:Tl(t),outcome:n.confirm_required?"preview":"executed",message:md(n),delegated_tool:n.delegated_tool}),await _t(),await Be(),(e=Ht.value)!=null&&e.target_id&&await ye(Ht.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw he.value=s,Ra({actor:t.actor,action_type:t.action_type,target_label:Tl(t),outcome:"error",message:s}),n}finally{it.value=!1}}async function vd(t,e,n="confirm"){var s;it.value=!0,he.value=null;try{const a=await nm(t,e,n);return Ra({actor:t,action_type:n,target_label:e,outcome:"confirmed",message:md(a),delegated_tool:a.delegated_tool}),await _t(),await Be(),(s=Ht.value)!=null&&s.target_id&&await ye(Ht.value.target_id),a}catch(a){const o=a instanceof Error?a.message:"Operator confirmation failed";throw he.value=o,Ra({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:o}),a}finally{it.value=!1}}uv(()=>{var t;_t(),Be(),(t=Ht.value)!=null&&t.target_id&&ye(Ht.value.target_id)});const As=$(null),ko=$(!1),Ma=$(null),fd=$(null),en=$(!1),Le=$(null),xo=$(null),da=$(!1),ua=$(null);let _n=null;function Il(){_n!==null&&(window.clearTimeout(_n),_n=null)}function Sv(t=1500){_n===null&&(_n=window.setTimeout(()=>{_n=null,La(!1)},t))}function F(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function x(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function q(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function vn(t){return typeof t=="boolean"?t:void 0}function Y(t,e=[]){if(Array.isArray(t))return t;if(!F(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function An(t){if(!F(t))return null;const e=x(t.kind),n=x(t.summary),s=x(t.target_type);return!e||!n||!s?null:{kind:e,severity:x(t.severity)??"warn",summary:n,target_type:s,target_id:x(t.target_id)??null,actor:x(t.actor)??null,evidence:t.evidence}}function We(t){if(!F(t))return null;const e=x(t.action_type),n=x(t.target_type),s=x(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:x(t.target_id)??null,severity:x(t.severity)??"warn",reason:s,confirm_required:vn(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Cv(t){if(!F(t))return null;const e=x(t.session_id);return e?{session_id:e,goal:x(t.goal),status:x(t.status),health:x(t.health),scale_profile:x(t.scale_profile),control_profile:x(t.control_profile),planned_worker_count:q(t.planned_worker_count),active_agent_count:q(t.active_agent_count),last_turn_age_sec:q(t.last_turn_age_sec)??null,attention_count:q(t.attention_count),recommended_action_count:q(t.recommended_action_count),top_attention:An(t.top_attention),top_recommendation:We(t.top_recommendation)}:null}function Av(t){if(!F(t))return null;const e=x(t.session_id);if(!e)return null;const n=F(t.status)?t.status:t,s=F(n.summary)?n.summary:void 0;return{session_id:e,status:x(t.status)??x(s==null?void 0:s.status)??(F(n.session)?x(n.session.status):void 0),progress_pct:q(t.progress_pct)??q(s==null?void 0:s.progress_pct),elapsed_sec:q(t.elapsed_sec)??q(s==null?void 0:s.elapsed_sec),remaining_sec:q(t.remaining_sec)??q(s==null?void 0:s.remaining_sec),done_delta_total:q(t.done_delta_total)??q(s==null?void 0:s.done_delta_total),summary:F(t.summary)?t.summary:s,team_health:F(t.team_health)?t.team_health:F(n.team_health)?n.team_health:void 0,communication_metrics:F(t.communication_metrics)?t.communication_metrics:F(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:F(t.orchestration_state)?t.orchestration_state:F(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:F(t.cascade_metrics)?t.cascade_metrics:F(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:F(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,o])=>{const l=x(o);return l?[a,l]:null}).filter(a=>a!==null)):F(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const l=x(o);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:F(t.session)?t.session:F(n.session)?n.session:void 0,recent_events:Y(t.recent_events,["events"]).filter(F)}}function Tv(t){if(!F(t))return null;const e=x(t.name);return e?{name:e,agent_name:x(t.agent_name),status:x(t.status),autonomy_level:x(t.autonomy_level),context_ratio:q(t.context_ratio),generation:q(t.generation),active_goal_ids:Y(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:x(t.last_autonomous_action_at)??null,last_turn_ago_s:q(t.last_turn_ago_s),model:x(t.model)}:null}function Iv(t){if(!F(t))return null;const e=x(t.confirm_token)??x(t.token);return e?{confirm_token:e,actor:x(t.actor),action_type:x(t.action_type),target_type:x(t.target_type),target_id:x(t.target_id)??null,delegated_tool:x(t.delegated_tool),created_at:x(t.created_at),preview:t.preview}:null}function Rv(t){if(!F(t))return null;const e=x(t.action_type),n=x(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:x(t.description),confirm_required:vn(t.confirm_required)}}function Mv(t){const e=F(t)?t:{};return{room_health:x(e.room_health),cluster:x(e.cluster),project:x(e.project),current_room:x(e.current_room)??x(e.room)??null,paused:vn(e.paused),tempo_interval_s:q(e.tempo_interval_s),active_agents:q(e.active_agents),keeper_pressure:q(e.keeper_pressure),active_operations:q(e.active_operations),pending_approvals:q(e.pending_approvals),incident_count:q(e.incident_count),recommended_action_count:q(e.recommended_action_count),top_attention:An(e.top_attention),top_action:We(e.top_action)}}function Lv(t){const e=F(t)?t:{},n=F(e.swarm_overview)?e.swarm_overview:{};return{health:x(e.health),active_operations:q(e.active_operations),pending_approvals:q(e.pending_approvals),swarm_overview:{active_lanes:q(n.active_lanes),moving_lanes:q(n.moving_lanes),stalled_lanes:q(n.stalled_lanes),projected_lanes:q(n.projected_lanes),last_movement_at:x(n.last_movement_at)??null},top_attention:An(e.top_attention),top_action:We(e.top_action),session_cards:Y(e.session_cards).map(Cv).filter(s=>s!==null)}}function Ev(t){const e=F(t)?t:{};return{sessions:Y(e.sessions,["items"]).map(Av).filter(n=>n!==null),keepers:Y(e.keepers,["items"]).map(Tv).filter(n=>n!==null),pending_confirms:Y(e.pending_confirms).map(Iv).filter(n=>n!==null),available_actions:Y(e.available_actions).map(Rv).filter(n=>n!==null)}}function Pv(t){if(!F(t))return null;const e=x(t.id),n=x(t.kind),s=x(t.summary),a=x(t.target_type);return!e||!n||!s||!a?null:{id:e,kind:n,severity:x(t.severity)??"warn",summary:s,target_type:a,target_id:x(t.target_id)??null,top_action:We(t.top_action),related_session_ids:Y(t.related_session_ids).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),related_agent_names:Y(t.related_agent_names).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),evidence_preview:Y(t.evidence_preview).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),last_seen_at:x(t.last_seen_at)??null}}function gd(t){if(!F(t))return null;const e=x(t.session_id),n=x(t.goal);return!e||!n?null:{session_id:e,goal:n,room:x(t.room)??null,status:x(t.status),health:x(t.health),member_names:Y(t.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:x(t.started_at)??null,elapsed_sec:q(t.elapsed_sec)??null,operation_id:x(t.operation_id)??null,blocker_summary:x(t.blocker_summary)??null,last_event_at:x(t.last_event_at)??null,last_event_summary:x(t.last_event_summary)??null,communication_summary:x(t.communication_summary)??null,active_count:q(t.active_count),seen_count:q(t.seen_count),planned_count:q(t.planned_count),required_count:q(t.required_count),counts_basis:x(t.counts_basis)??null,related_attention_count:q(t.related_attention_count)??0,top_attention:An(t.top_attention),top_recommendation:We(t.top_recommendation)}}function $d(t){if(!F(t))return null;const e=x(t.agent_name);return e?{agent_name:e,display_name:x(t.display_name)??null,is_live:typeof t.is_live=="boolean"?t.is_live:void 0,current_work:x(t.current_work)??null,recent_input_preview:x(t.recent_input_preview)??null,recent_output_preview:x(t.recent_output_preview)??null,recent_tool_names:Y(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_activity_at:x(t.last_activity_at)??null}:null}function hd(t){if(!F(t))return null;const e=x(t.operation_id);return e?{operation_id:e,status:x(t.status),stage:x(t.stage)??null,detachment_status:x(t.detachment_status)??null,objective:x(t.objective)??null,updated_at:x(t.updated_at)??null}:null}function yd(t){if(!F(t))return null;const e=x(t.name);return e?{name:e,agent_name:x(t.agent_name)??null,status:x(t.status),generation:q(t.generation),context_ratio:q(t.context_ratio)??null,last_turn_ago_s:q(t.last_turn_ago_s)??null,current_work:x(t.current_work)??null}:null}function bd(t){const e=gd(t);return e?{...e,member_previews:Y(F(t)?t.member_previews:void 0).map($d).filter(n=>n!==null),operation_badges:Y(F(t)?t.operation_badges:void 0).map(hd).filter(n=>n!==null),keeper_refs:Y(F(t)?t.keeper_refs:void 0).map(yd).filter(n=>n!==null)}:null}function zv(t){if(!F(t))return null;const e=x(t.agent_name);return e?{agent_name:e,display_name:x(t.display_name)??null,is_live:typeof t.is_live=="boolean"?t.is_live:void 0,archived_reason:x(t.archived_reason)??null,status:x(t.status),where:x(t.where)??null,with_whom:Y(t.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:x(t.current_work)??null,related_session_id:x(t.related_session_id)??null,related_attention_count:q(t.related_attention_count)??0,last_activity_at:x(t.last_activity_at)??null,last_activity_age_sec:q(t.last_activity_age_sec)??null,signal_truth:x(t.signal_truth)==="live"||x(t.signal_truth)==="stale"||x(t.signal_truth)==="archived"||x(t.signal_truth)==="unknown"?x(t.signal_truth):void 0,evidence_source:x(t.evidence_source)==="message"||x(t.evidence_source)==="presence"||x(t.evidence_source)==="session"||x(t.evidence_source)==="none"?x(t.evidence_source):void 0,recent_output_preview:x(t.recent_output_preview)??null,recent_input_preview:x(t.recent_input_preview)??null,recent_tool_names:Y(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean)}:null}function wv(t){if(!F(t))return null;const e=x(t.name);return e?{name:e,agent_name:x(t.agent_name)??null,status:x(t.status),generation:q(t.generation),context_ratio:q(t.context_ratio)??null,last_turn_ago_s:q(t.last_turn_ago_s)??null,current_work:x(t.current_work)??null,last_autonomous_action_at:x(t.last_autonomous_action_at)??null,allowed_tool_names:Y(t.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:Y(t.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:q(t.latest_tool_call_count)??null,tool_audit_source:x(t.tool_audit_source)??null,tool_audit_at:x(t.tool_audit_at)??null}:null}function Nv(t){if(!F(t))return null;const e=x(t.id),n=x(t.signal_type),s=x(t.summary),a=x(t.target_type);return!e||!n||!s||!a?null:{id:e,signal_type:n==="action"?"action":"attention",severity:x(t.severity)??"warn",summary:s,target_type:a,target_id:x(t.target_id)??null,attention:An(t.attention),action:We(t.action)}}function jv(t){const e=F(t)?t:{},n=Y(e.session_briefs).map(gd).filter(a=>a!==null),s=Y(e.sessions).map(bd).filter(a=>a!==null);return{generated_at:x(e.generated_at),summary:Mv(e.summary),incidents:Y(e.incidents).map(An).filter(a=>a!==null),recommended_actions:Y(e.recommended_actions).map(We).filter(a=>a!==null),command_focus:Lv(e.command_focus),operator_targets:Ev(e.operator_targets),attention_queue:Y(e.attention_queue).map(Pv).filter(a=>a!==null),sessions:s.length>0?s:n.map(a=>({...a,member_previews:[],operation_badges:[],keeper_refs:[]})),session_briefs:n,agent_briefs:Y(e.agent_briefs).map(zv).filter(a=>a!==null),keeper_briefs:Y(e.keeper_briefs).map(wv).filter(a=>a!==null),internal_signals:Y(e.internal_signals).map(Nv).filter(a=>a!==null)}}function Ov(t){if(!F(t))return null;const e=x(t.id),n=x(t.summary);return!e||!n?null:{id:e,timestamp:x(t.timestamp)??null,event_type:x(t.event_type),actor:x(t.actor)??null,summary:n}}function Dv(t){const e=F(t)?t:{};return{generated_at:x(e.generated_at),session_id:x(e.session_id)??"",session:bd(e.session),timeline:Y(e.timeline).map(Ov).filter(n=>n!==null),participants:Y(e.participants).map($d).filter(n=>n!==null),operations:Y(e.operations).map(hd).filter(n=>n!==null),keepers:Y(e.keepers).map(yd).filter(n=>n!==null),error:x(e.error)??null}}function qv(t){if(!F(t))return null;const e=x(t.id),n=x(t.label),s=x(t.summary);if(!e||!n||!s)return null;const a=x(t.status)??"unclear";return{id:e,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:x(t.signal_class)==="metadata_gap"||x(t.signal_class)==="mixed"||x(t.signal_class)==="operational_risk"?x(t.signal_class):void 0,evidence_quality:x(t.evidence_quality)==="strong"||x(t.evidence_quality)==="partial"||x(t.evidence_quality)==="missing"?x(t.evidence_quality):void 0,evidence:Y(t.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function Fv(t){if(!F(t))return null;const e=x(t.kind),n=x(t.summary),s=x(t.scope_type),a=x(t.severity);return!e||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:e,summary:n,scope_type:s,scope_id:x(t.scope_id)??null,severity:a}}function Kv(t){const e=F(t)?t:{},n=F(e.basis)?e.basis:{},s=x(e.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:x(e.generated_at),cached:vn(e.cached),stale:vn(e.stale),refreshing:vn(e.refreshing),status:a,summary:x(e.summary)??null,model:x(e.model)??null,ttl_sec:q(e.ttl_sec),criteria:Y(e.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:x(n.current_room)??null,crew_count:q(n.crew_count),agent_count:q(n.agent_count),keeper_count:q(n.keeper_count)},metadata_gap_count:q(e.metadata_gap_count),metadata_gaps:Y(e.metadata_gaps).map(Fv).filter(o=>o!==null),sections:Y(e.sections).map(qv).filter(o=>o!==null),error:x(e.error)??null,last_error:x(e.last_error)??null}}async function kd(){ko.value=!0,Ma.value=null;try{const t=await Dp();As.value=jv(t)}catch(t){Ma.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{ko.value=!1}}async function Bv(t){if(!t){xo.value=null,ua.value=null,da.value=!1;return}da.value=!0,ua.value=null;try{const e=await qp(t);xo.value=Dv(e)}catch(e){ua.value=e instanceof Error?e.message:"Failed to load session detail"}finally{da.value=!1}}async function La(t=!1){en.value=!0,Le.value=null;try{const e=await Fp(t),n=Kv(e);fd.value=n,n.refreshing||n.status==="pending"?Sv():Il()}catch(e){Le.value=e instanceof Error?e.message:"Failed to load mission briefing",Il()}finally{en.value=!1}}const xd=$(null),So=$(!1),nn=$(null);async function Sd(t,e){So.value=!0,nn.value=null;try{xd.value=await Kp(t,e)}catch(n){nn.value=n instanceof Error?n.message:String(n)}finally{So.value=!1}}const lr=$(null),Jt=$(null),Ea=$(!1),Pa=$(!1),za=$(null),wa=$(null),Co=$(null),Na=$(null),X=$("warroom"),Ts=$(null),Ao=$(!1),ja=$(null),Ge=$(null),Oa=$(!1),Da=$(null),cr=$(null),To=$(!1),qa=$(null),Is=$(null),Io=$(!1),Fa=$(null),as=$(null),Ka=$(!1),is=$(null),fn=$(null);let On=null;function dr(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"&&t!=="orchestra"}function Cd(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function Ad(){const e=Cd().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Td(){const e=Cd().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function Uv(t){if(v(t))return{policy_class:r(t.policy_class),approval_class:r(t.approval_class),tool_allowlist:H(t.tool_allowlist),model_allowlist:H(t.model_allowlist),requires_human_for:H(t.requires_human_for),autonomy_level:r(t.autonomy_level),escalation_timeout_sec:u(t.escalation_timeout_sec),kill_switch:j(t.kill_switch),frozen:j(t.frozen)}}function Hv(t){if(v(t))return{headcount_cap:u(t.headcount_cap),active_operation_cap:u(t.active_operation_cap),max_cost_usd:u(t.max_cost_usd),max_tokens:u(t.max_tokens)}}function ur(t){if(!v(t))return null;const e=r(t.unit_id),n=r(t.label),s=r(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:r(t.parent_unit_id)??null,leader_id:r(t.leader_id)??null,roster:H(t.roster),capability_profile:H(t.capability_profile),source:r(t.source),created_at:r(t.created_at),updated_at:r(t.updated_at),policy:Uv(t.policy),budget:Hv(t.budget)}}function Id(t){if(!v(t))return null;const e=ur(t.unit);return e?{unit:e,leader_status:r(t.leader_status),roster_total:u(t.roster_total),roster_live:u(t.roster_live),active_operation_count:u(t.active_operation_count),health:r(t.health),reasons:H(t.reasons),children:Array.isArray(t.children)?t.children.map(Id).filter(n=>n!==null):[]}:null}function Wv(t){if(v(t))return{total_units:u(t.total_units),company_count:u(t.company_count),platoon_count:u(t.platoon_count),squad_count:u(t.squad_count),leaf_agent_unit_count:u(t.leaf_agent_unit_count),live_agent_count:u(t.live_agent_count),managed_unit_count:u(t.managed_unit_count),active_operation_count:u(t.active_operation_count)}}function Rd(t){const e=v(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),source:r(e.source),summary:Wv(e.summary),units:Array.isArray(e.units)?e.units.map(Id).filter(n=>n!==null):[]}}function Gv(t){if(!v(t))return null;const e=r(t.kind),n=r(t.status);return!e||!n?null:{kind:e,chain_id:r(t.chain_id)??null,goal:r(t.goal)??null,run_id:r(t.run_id)??null,status:n,viewer_path:r(t.viewer_path)??null,last_sync_at:r(t.last_sync_at)??null}}function di(t){if(!v(t))return null;const e=r(t.operation_id),n=r(t.objective),s=r(t.assigned_unit_id),a=r(t.trace_id),o=r(t.status);return!e||!n||!s||!a||!o?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:r(t.autonomy_level),policy_class:r(t.policy_class),budget_class:r(t.budget_class),detachment_session_id:r(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(t.checkpoint_ref)??null,active_goal_ids:H(t.active_goal_ids),note:r(t.note)??null,created_by:r(t.created_by),source:r(t.source),status:o,chain:Gv(t.chain),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function Jv(t){if(!v(t))return null;const e=di(t.operation);return e?{operation:e,assigned_unit_label:r(t.assigned_unit_label)}:null}function Pn(t){if(v(t))return{tone:r(t.tone),pending_ops:u(t.pending_ops),blocked_ops:u(t.blocked_ops),in_flight_ops:u(t.in_flight_ops),pipeline_stalls:u(t.pipeline_stalls),bus_traffic:u(t.bus_traffic),l1_hit_rate:u(t.l1_hit_rate),invalidation_count:u(t.invalidation_count),current_pending:u(t.current_pending),current_in_flight:u(t.current_in_flight),cdb_wakeups:u(t.cdb_wakeups),total_stolen:u(t.total_stolen),avg_best_score:u(t.avg_best_score),avg_candidate_count:u(t.avg_candidate_count),best_first_operations:u(t.best_first_operations),active_sessions:u(t.active_sessions),commit_rate:u(t.commit_rate),total_speculations:u(t.total_speculations)}}function Vv(t){if(!v(t))return;const e=v(t.pipeline)?t.pipeline:void 0,n=v(t.cache)?t.cache:void 0,s=v(t.ooo)?t.ooo:void 0,a=v(t.speculative)?t.speculative:void 0,o=v(t.search_fabric)?t.search_fabric:void 0,l=v(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:u(e.total_ops),completed_ops:u(e.completed_ops),stalled_cycles:u(e.stalled_cycles),hazards_detected:u(e.hazards_detected),forwarding_used:u(e.forwarding_used),pipeline_flushes:u(e.pipeline_flushes),ipc:u(e.ipc)}:void 0,cache:n?{total_reads:u(n.total_reads),total_writes:u(n.total_writes),l1_hit_rate:u(n.l1_hit_rate),invalidation_count:u(n.invalidation_count),writeback_count:u(n.writeback_count),bus_traffic:u(n.bus_traffic)}:void 0,ooo:s?{agent_count:u(s.agent_count),total_added:u(s.total_added),total_issued:u(s.total_issued),total_completed:u(s.total_completed),total_stolen:u(s.total_stolen),cdb_wakeups:u(s.cdb_wakeups),stall_cycles:u(s.stall_cycles),global_cdb_events:u(s.global_cdb_events),current_pending:u(s.current_pending),current_in_flight:u(s.current_in_flight)}:void 0,speculative:a?{total_speculations:u(a.total_speculations),total_commits:u(a.total_commits),total_aborts:u(a.total_aborts),commit_rate:u(a.commit_rate),total_fast_calls:u(a.total_fast_calls),total_cost_usd:u(a.total_cost_usd),active_sessions:u(a.active_sessions)}:void 0,search_fabric:o?{total_operations:u(o.total_operations),best_first_operations:u(o.best_first_operations),legacy_operations:u(o.legacy_operations),blocked_operations:u(o.blocked_operations),ready_operations:u(o.ready_operations),research_pipeline_operations:u(o.research_pipeline_operations),avg_candidate_count:u(o.avg_candidate_count),avg_best_score:u(o.avg_best_score),top_stage:r(o.top_stage)??null}:void 0,signals:l?{issue_pressure:Pn(l.issue_pressure),cache_contention:Pn(l.cache_contention),scheduler_efficiency:Pn(l.scheduler_efficiency),routing_confidence:Pn(l.routing_confidence),speculative_posture:Pn(l.speculative_posture)}:void 0}}function Md(t){const e=v(t)?t:{},n=v(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),active:u(n.active),paused:u(n.paused),managed:u(n.managed),projected:u(n.projected)}:void 0,microarch:Vv(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(Jv).filter(s=>s!==null):[]}}function Ld(t){if(!v(t))return null;const e=r(t.detachment_id),n=r(t.operation_id),s=r(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:r(t.leader_id)??null,roster:H(t.roster),session_id:r(t.session_id)??null,checkpoint_ref:r(t.checkpoint_ref)??null,runtime_kind:r(t.runtime_kind)??null,runtime_ref:r(t.runtime_ref)??null,source:r(t.source),status:r(t.status),last_event_at:r(t.last_event_at)??null,last_progress_at:r(t.last_progress_at)??null,heartbeat_deadline:r(t.heartbeat_deadline)??null,created_at:r(t.created_at),updated_at:r(t.updated_at)}}function Yv(t){if(!v(t))return null;const e=Ld(t.detachment);return e?{detachment:e,assigned_unit_label:r(t.assigned_unit_label),operation:di(t.operation)}:null}function Ed(t){const e=v(t)?t:{},n=v(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),active:u(n.active),projected:u(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(Yv).filter(s=>s!==null):[]}}function Xv(t){if(!v(t))return null;const e=r(t.decision_id),n=r(t.trace_id),s=r(t.requested_action),a=r(t.scope_type),o=r(t.scope_id);return!e||!n||!s||!a||!o?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:r(t.operation_id)??null,target_unit_id:r(t.target_unit_id)??null,requested_by:r(t.requested_by),status:r(t.status),reason:r(t.reason)??null,source:r(t.source),detail:t.detail,created_at:r(t.created_at),decided_at:r(t.decided_at)??null,expires_at:r(t.expires_at)??null}}function Pd(t){const e=v(t)?t:{},n=v(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),pending:u(n.pending),approved:u(n.approved),denied:u(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(Xv).filter(s=>s!==null):[]}}function Qv(t){if(!v(t))return null;const e=ur(t.unit);return e?{unit:e,roster_total:u(t.roster_total),roster_live:u(t.roster_live),headcount_cap:u(t.headcount_cap),active_operations:u(t.active_operations),active_operation_cap:u(t.active_operation_cap),utilization:u(t.utilization)}:null}function Zv(t){const e=v(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(Qv).filter(n=>n!==null):[]}}function tf(t){if(!v(t))return null;const e=r(t.alert_id);return e?{alert_id:e,severity:r(t.severity),kind:r(t.kind),scope_type:r(t.scope_type),scope_id:r(t.scope_id),title:r(t.title),detail:r(t.detail),timestamp:r(t.timestamp)}:null}function zd(t){const e=v(t)?t:{},n=v(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),bad:u(n.bad),warn:u(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(tf).filter(s=>s!==null):[]}}function wd(t){if(!v(t))return null;const e=r(t.event_id),n=r(t.trace_id),s=r(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:r(t.operation_id)??null,unit_id:r(t.unit_id)??null,actor:r(t.actor)??null,source:r(t.source),timestamp:r(t.timestamp),detail:t.detail}}function ef(t){const e=v(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),events:Array.isArray(e.events)?e.events.map(wd).filter(n=>n!==null):[]}}function nf(t){if(!v(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function sf(t){if(!v(t))return null;const e=r(t.lane_id),n=r(t.label),s=r(t.kind),a=r(t.phase),o=r(t.motion_state),l=r(t.source_of_truth),c=r(t.movement_reason),d=r(t.current_step);if(!e||!n||!s||!a||!o||!l||!c||!d)return null;const p=v(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:j(t.present)??!1,phase:a,motion_state:o,source_of_truth:l,last_movement_at:r(t.last_movement_at)??null,movement_reason:c,current_step:d,blockers:H(t.blockers),counts:{operations:u(p.operations),detachments:u(p.detachments),workers:u(p.workers),approvals:u(p.approvals),alerts:u(p.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(nf).filter(m=>m!==null):[]}}function af(t){if(!v(t))return null;const e=r(t.event_id),n=r(t.lane_id),s=r(t.kind),a=r(t.timestamp),o=r(t.title),l=r(t.detail),c=r(t.tone),d=r(t.source);return!e||!n||!s||!a||!o||!l||!c||!d?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:o,detail:l,tone:c,source:d}}function of(t){if(!v(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,why_it_matters:r(t.why_it_matters)??void 0,next_tool:r(t.next_tool)??void 0,next_step:r(t.next_step)??void 0,lane_ids:H(t.lane_ids),count:u(t.count)??0}}function pr(t){if(!v(t))return;const e=v(t.overview)?t.overview:{},n=v(t.gaps)?t.gaps:{},s=v(t.narrative)?t.narrative:{},a=v(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:r(t.generated_at),narrative:{state:r(s.state)??void 0,started:r(s.started)??void 0,active_work:r(s.active_work)??void 0,completion:r(s.completion)??void 0,lane_id:r(s.lane_id)??null},overview:{active_lanes:u(e.active_lanes),moving_lanes:u(e.moving_lanes),stalled_lanes:u(e.stalled_lanes),projected_lanes:u(e.projected_lanes),last_movement_at:r(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(sf).filter(o=>o!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(af).filter(o=>o!==null):[],gaps:{count:u(n.count),items:Array.isArray(n.items)?n.items.map(of).filter(o=>o!==null):[]},recommended_next_action:a?{tool:r(a.tool)??"masc_operator_snapshot",label:r(a.label)??"Observe operator state",reason:r(a.reason)??"",lane_id:r(a.lane_id)??null}:void 0}}function Nd(t){if(!v(t))return;const e=v(t.workers)?t.workers:{},n=j(t.pass);return{status:r(t.status)??"missing",source:r(t.source)??"none",reason_code:r(t.reason_code)??null,status_summary:r(t.status_summary)??null,run_id:r(t.run_id)??null,captured_at:r(t.captured_at)??null,...n!==void 0?{pass:n}:{},...u(t.peak_hot_slots)!=null?{peak_hot_slots:u(t.peak_hot_slots)}:{},...u(t.ctx_per_slot)!=null?{ctx_per_slot:u(t.ctx_per_slot)}:{},workers:{expected:u(e.expected),joined:u(e.joined),current_task_bound:u(e.current_task_bound),fresh_heartbeats:u(e.fresh_heartbeats),done:u(e.done),final:u(e.final)},expected_artifact_dir:r(t.expected_artifact_dir)??null,artifact_ref:r(t.artifact_ref)??null,missing_reason:r(t.missing_reason)??null}}function rf(t){const e=v(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),topology:Rd(e.topology),operations:Md(e.operations),detachments:Ed(e.detachments),alerts:zd(e.alerts),decisions:Pd(e.decisions),capacity:Zv(e.capacity),traces:ef(e.traces),swarm_status:pr(e.swarm_status)}}function lf(t){const e=v(t)?t:{},n=Rd(e.topology),s=Md(e.operations),a=Ed(e.detachments),o=zd(e.alerts),l=Pd(e.decisions);return{version:r(e.version),generated_at:r(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:pr(e.swarm_status),swarm_proof:Nd(e.swarm_proof)}}function cf(t){return v(t)?{chain_id:r(t.chain_id)??null,started_at:u(t.started_at)??null,progress:u(t.progress)??null,elapsed_sec:u(t.elapsed_sec)??null}:null}function jd(t){if(!v(t))return null;const e=r(t.event);return e?{event:e,chain_id:r(t.chain_id)??null,timestamp:r(t.timestamp)??null,duration_ms:u(t.duration_ms)??null,message:r(t.message)??null,tokens:u(t.tokens)??null}:null}function df(t){if(!v(t))return null;const e=di(t.operation);return e?{operation:e,runtime:cf(t.runtime),history:jd(t.history),mermaid:r(t.mermaid)??null,preview_run:Od(t.preview_run)}:null}function uf(t){const e=v(t)?t:{};return{status:r(e.status)??"disconnected",base_url:r(e.base_url)??null,message:r(e.message)??null}}function pf(t){const e=v(t)?t:{},n=v(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),connection:uf(e.connection),summary:n?{linked_operations:u(n.linked_operations),active_chains:u(n.active_chains),running_operations:u(n.running_operations),recent_failures:u(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(df).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(jd).filter(s=>s!==null):[]}}function mf(t){if(!v(t))return null;const e=r(t.id);return e?{id:e,type:r(t.type),status:r(t.status),duration_ms:u(t.duration_ms)??null,error:r(t.error)??null}:null}function Od(t){if(!v(t))return null;const e=r(t.run_id),n=r(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:u(t.duration_ms),success:j(t.success),mermaid:r(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(mf).filter(s=>s!==null):[]}:null}function _f(t){const e=v(t)?t:{};return{run:Od(e.run)}}function vf(t){if(!v(t))return null;const e=r(t.title),n=r(t.path);return!e||!n?null:{title:e,path:n}}function ff(t){if(!v(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function gf(t){if(!v(t))return null;const e=r(t.id),n=r(t.title),s=r(t.tool),a=r(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:H(t.success_signals),pitfalls:H(t.pitfalls)}}function $f(t){if(!v(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary),a=r(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(gf).filter(o=>o!==null):[]}}function hf(t){if(!v(t))return null;const e=r(t.id),n=r(t.title),s=r(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:H(t.tools)}}function yf(t){if(!v(t))return null;const e=r(t.id),n=r(t.title),s=r(t.symptom),a=r(t.why),o=r(t.fix_tool),l=r(t.fix_summary);return!e||!n||!s||!a||!o||!l?null:{id:e,title:n,symptom:s,why:a,fix_tool:o,fix_summary:l}}function bf(t){if(!v(t))return null;const e=r(t.id),n=r(t.title),s=r(t.path_id),a=r(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:H(t.notes)}}function kf(t){const e=v(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(vf).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(ff).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map($f).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(hf).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(yf).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(bf).filter(n=>n!==null):[]}}function xf(t){if(!v(t))return null;const e=r(t.id),n=r(t.title),s=r(t.status),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{id:e,title:n,status:s,detail:a,next_tool:o}}function Sf(t){if(!v(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.title),a=r(t.detail),o=r(t.next_tool);return!e||!n||!s||!a||!o?null:{code:e,severity:n,title:s,detail:a,next_tool:o}}function Cf(t){if(!v(t))return null;const e=r(t.from),n=r(t.content),s=r(t.timestamp),a=u(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function Af(t){if(!v(t))return null;const e=r(t.name),n=r(t.role),s=r(t.lane),a=r(t.status),o=r(t.claim_marker),l=r(t.done_marker),c=r(t.final_marker);if(!e||!n||!s||!a||!o||!l||!c)return null;const d=(()=>{if(!v(t.last_message))return null;const p=u(t.last_message.seq),m=r(t.last_message.content),f=r(t.last_message.timestamp);return p==null||!m||!f?null:{seq:p,content:m,timestamp:f}})();return{name:e,role:n,lane:s,joined:j(t.joined)??!1,live_presence:j(t.live_presence)??!1,completed:j(t.completed)??!1,status:a,current_task:r(t.current_task)??null,bound_task_id:r(t.bound_task_id)??null,bound_task_title:r(t.bound_task_title)??null,bound_task_status:r(t.bound_task_status)??null,current_task_matches_run:j(t.current_task_matches_run)??!1,squad_member:j(t.squad_member)??!1,detachment_member:j(t.detachment_member)??!1,last_seen:r(t.last_seen)??null,heartbeat_age_sec:u(t.heartbeat_age_sec)??null,heartbeat_fresh:j(t.heartbeat_fresh)??!1,claim_marker_seen:j(t.claim_marker_seen)??!1,done_marker_seen:j(t.done_marker_seen)??!1,final_marker_seen:j(t.final_marker_seen)??!1,claim_marker:o,done_marker:l,final_marker:c,last_message:d}}function Tf(t){if(!v(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!v(n))return null;const s=r(n.timestamp),a=u(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:r(t.slot_url)??null,provider_base_url:r(t.provider_base_url)??null,provider_reachable:j(t.provider_reachable)??null,provider_status_code:u(t.provider_status_code)??null,provider_model_id:r(t.provider_model_id)??null,actual_model_id:r(t.actual_model_id)??null,expected_slots:u(t.expected_slots),actual_slots:u(t.actual_slots),expected_ctx:u(t.expected_ctx),actual_ctx:u(t.actual_ctx),configured_capacity:u(t.configured_capacity),slot_reachable:j(t.slot_reachable)??null,slot_status_code:u(t.slot_status_code)??null,runtime_blocker:r(t.runtime_blocker)??null,detail:r(t.detail)??null,checked_at:r(t.checked_at)??null,total_slots:u(t.total_slots),ctx_per_slot:u(t.ctx_per_slot),active_slots_now:u(t.active_slots_now),peak_active_slots:u(t.peak_active_slots),sample_count:u(t.sample_count),last_sample_at:r(t.last_sample_at)??null,timeline:e}}function If(t){if(!v(t))return null;const e=r(t.run_id),n=r(t.status),s=r(t.decided_by),a=r(t.decided_at),o=r(t.reason);if(!e||!n||!s||!a||!o)return null;const l=[];return Array.isArray(t.history)&&t.history.forEach(c=>{if(!v(c))return;const d=r(c.status),p=r(c.decided_by),m=r(c.decided_at),f=r(c.reason);!d||!p||!m||!f||l.push({status:d,decided_by:p,decided_at:m,reason:f,operation_id:r(c.operation_id)??null,detachment_id:r(c.detachment_id)??null,note:r(c.note)??null})}),{run_id:e,status:n,decided_by:s,decided_at:a,reason:o,operation_id:r(t.operation_id)??null,detachment_id:r(t.detachment_id)??null,note:r(t.note)??null,history:l}}function Rf(t){if(!v(t))return null;const e=r(t.run_id),n=r(t.recommended_kind),s=r(t.reason);return!e||!n||!s?null:{run_id:e,recommended_kind:n,continue_available:j(t.continue_available)??!1,rerun_available:j(t.rerun_available)??!1,abandon_available:j(t.abandon_available)??!1,reason:s,evidence:v(t.evidence)?{operation_id:r(t.evidence.operation_id)??null,detachment_id:r(t.evidence.detachment_id)??null,joined_workers:u(t.evidence.joined_workers),current_task_bound:u(t.evidence.current_task_bound),fresh_heartbeats:u(t.evidence.fresh_heartbeats),trace_events:u(t.evidence.trace_events),message_events:u(t.evidence.message_events),runtime_blocker:r(t.evidence.runtime_blocker)??null}:void 0,provenance:r(t.provenance),decision_engine:r(t.decision_engine),authoritative:j(t.authoritative)}}function Mf(t){const e=v(t)?t:{},n=v(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),run_id:r(e.run_id),room_id:r(e.room_id),operation_id:r(e.operation_id)??null,run_resolution:If(e.run_resolution),resolution_recommendation:Rf(e.resolution_recommendation),recommended_next_tool:r(e.recommended_next_tool),summary:n?{expected_workers:u(n.expected_workers),joined_workers:u(n.joined_workers),live_workers:u(n.live_workers),squad_roster_size:u(n.squad_roster_size),detachment_roster_size:u(n.detachment_roster_size),current_task_bound:u(n.current_task_bound),fresh_heartbeats:u(n.fresh_heartbeats),claim_markers_seen:u(n.claim_markers_seen),done_markers_seen:u(n.done_markers_seen),final_markers_seen:u(n.final_markers_seen),completed_workers:u(n.completed_workers),peak_hot_slots:u(n.peak_hot_slots),hot_window_ok:j(n.hot_window_ok),pass_hot_concurrency:j(n.pass_hot_concurrency),pass_end_to_end:j(n.pass_end_to_end),pending_decisions:u(n.pending_decisions),pass:j(n.pass)}:void 0,provider:Tf(e.provider),operation:di(e.operation),squad:ur(e.squad),detachment:Ld(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Af).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(xf).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Sf).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(Cf).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(wd).filter(s=>s!==null):[],truth_notes:H(e.truth_notes)}}function Lf(t){if(!v(t))return null;const e=r(t.label),n=r(t.value);return!e||!n?null:{label:e,value:n}}function Ef(t){if(!v(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.label),a=r(t.tone),o=r(t.provenance);return!e||!n||!s||!a||!o?null:{id:e,kind:n,label:s,subtitle:r(t.subtitle)??null,status:r(t.status)??null,tone:a,pulse:r(t.pulse)??null,provenance:o,visual_class:r(t.visual_class)??void 0,glyph:r(t.glyph)??void 0,parent_id:r(t.parent_id)??null,lane_id:r(t.lane_id)??null,link_tab:r(t.link_tab)??null,link_surface:r(t.link_surface)??null,link_params:v(t.link_params)?Object.fromEntries(Object.entries(t.link_params).map(([l,c])=>{const d=r(c);return d?[l,d]:null}).filter(l=>l!==null)):{},facts:Array.isArray(t.facts)?t.facts.map(Lf).filter(l=>l!==null):[]}}function Pf(t){if(!v(t))return null;const e=r(t.id),n=r(t.source),s=r(t.target),a=r(t.kind),o=r(t.tone),l=r(t.provenance);return!e||!n||!s||!a||!o||!l?null:{id:e,source:n,target:s,kind:a,label:r(t.label)??null,tone:o,provenance:l,animated:j(t.animated)}}function zf(t){if(!v(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.label),a=r(t.tone),o=r(t.provenance);return!e||!n||!s||!a||!o?null:{id:e,kind:n,label:s,detail:r(t.detail)??null,tone:a,provenance:o,source_id:r(t.source_id)??null,target_id:r(t.target_id)??null,suggested_surface:r(t.suggested_surface)??null,suggested_params:v(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([l,c])=>{const d=r(c);return d?[l,d]:null}).filter(l=>l!==null)):{}}}function wf(t){if(!v(t))return null;const e=r(t.target_kind),n=r(t.target_id),s=r(t.label),a=r(t.reason);return!e||!n||!s||!a?null:{target_kind:e,target_id:n,label:s,reason:a,suggested_surface:r(t.suggested_surface)??null,suggested_params:v(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([o,l])=>{const c=r(l);return c?[o,c]:null}).filter(o=>o!==null)):{}}}function Nf(t){const e=v(t)?t:{},n=v(e.room)?e.room:{},s=v(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),room:{room_id:r(n.room_id),project:r(n.project),cluster:r(n.cluster),paused:j(n.paused),pause_reason:r(n.pause_reason)??null,agent_count:u(n.agent_count),task_count:u(n.task_count),message_count:u(n.message_count)},summary:s?{session_count:u(s.session_count),operation_count:u(s.operation_count),detachment_count:u(s.detachment_count),lane_count:u(s.lane_count),worker_count:u(s.worker_count),keeper_count:u(s.keeper_count),signal_count:u(s.signal_count),alert_count:u(s.alert_count)}:void 0,nodes:Array.isArray(e.nodes)?e.nodes.map(Ef).filter(a=>a!==null):[],edges:Array.isArray(e.edges)?e.edges.map(Pf).filter(a=>a!==null):[],signals:Array.isArray(e.signals)?e.signals.map(zf).filter(a=>a!==null):[],focus:wf(e.focus),swarm_status:pr(e.swarm_status),swarm_proof:Nd(e.swarm_proof),truth_notes:H(e.truth_notes)}}function Kt(t){X.value=t,dr(t)&&jf()}async function Dd(){Ea.value=!0,za.value=null;try{const t=await Jp();lr.value=lf(t)}catch(t){za.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{Ea.value=!1}}function mr(t){fn.value=t}async function _r(){Pa.value=!0,wa.value=null;try{const t=await Gp();Jt.value=rf(t)}catch(t){wa.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{Pa.value=!1}}async function jf(){Jt.value||Pa.value||await _r()}async function sn(){await Dd(),dr(X.value)&&await _r()}async function qe(){var t;Io.value=!0,Fa.value=null;try{const e=await Vp(),n=pf(e);Is.value=n;const s=fn.value;n.operations.length===0?fn.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(fn.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Fa.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Io.value=!1}}function Of(){On=null,as.value=null,Ka.value=!1,is.value=null}async function Df(t){On=t,Ka.value=!0,is.value=null;try{const e=await Yp(t);if(On!==t)return;as.value=_f(e)}catch(e){if(On!==t)return;as.value=null,is.value=e instanceof Error?e.message:"Failed to load chain run"}finally{On===t&&(Ka.value=!1)}}async function qf(){Ao.value=!0,ja.value=null;try{const t=await Xp();Ts.value=kf(t)}catch(t){ja.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{Ao.value=!1}}async function Zt(t=Ad(),e=Td()){Oa.value=!0,Da.value=null;try{const n=await Qp(t,e);Ge.value=Mf(n)}catch(n){Da.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{Oa.value=!1}}async function Ne(t=Ad(),e=Td()){To.value=!0,qa.value=null;try{const n=await Zp(t,e);cr.value=Nf(n)}catch(n){qa.value=n instanceof Error?n.message:"Failed to load orchestra map"}finally{To.value=!1}}async function be(t,e,n){Co.value=t,Na.value=null;try{await tm(e,n),await Dd(),(Jt.value||dr(X.value))&&await _r(),await Zt(),await Ne(),await qe()}catch(s){throw Na.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{Co.value=null}}function Ff(t){return be(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function Kf(t){return be(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function Bf(t){return be(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function Uf(t={}){return be("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Hf(t){return be(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Wf(t){return be(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Gf(t,e){return be(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Jf(t,e){return be(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}dv(()=>{sn(),qe(),(X.value==="swarm"||X.value==="warroom"||X.value==="orchestra"||Ge.value!==null)&&Zt(),(X.value==="orchestra"||cr.value!==null)&&Ne(),X.value==="warroom"&&_t()});function Ro(t){t==="command"&&(ze(),sn(),qe(),(X.value==="swarm"||X.value==="warroom"||X.value==="orchestra")&&Zt(),X.value==="orchestra"&&Ne(),X.value==="warroom"&&_t()),t==="mission"&&(ze(),kd(),La()),t==="proof"&&Sd(K.value.params.session_id,K.value.params.operation_id),t==="execution"&&(ze(),Pe()),t==="intervene"&&(ze(),_t(),Be()),t==="memory"&&_e(),t==="planning"&&ir(),t==="lab"&&ve()}function Vf({metric:t}){return i`
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
  `}function Yf({panel:t}){return i`
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
            ${t.metrics.map(e=>i`<${Vf} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function B({panelId:t,compact:e=!1,label:n="왜 필요한가"}){const s=X_(t);return s?i`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${Yf} panel=${s} />
    </details>
  `:Ca.value?i`<span class="semantic-inline-state">의미 계층 불러오는 중…</span>`:null}function vt({surfaceId:t,compact:e=!1}){const n=Y_(t);return n?i`
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
  `:Ca.value?i`<div class="semantic-surface-card ${e?"compact":""}">의미 계층 불러오는 중…</div>`:Aa.value?i`<div class="semantic-surface-card ${e?"compact":""}">${Aa.value}</div>`:null}function E({title:t,class:e,semanticId:n,testId:s,children:a}){return i`
    <div class="card ${e??""}" data-testid=${s}>
      ${t?i`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?i`<${B} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}const Ba="masc_dashboard_workflow_context",Xf=900*1e3;function St(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function re(t){const e=St(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function qd(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function Mo(t){return v(t)?t:null}function Qf(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function Zf(t){if(!t)return null;try{const e=JSON.parse(t);if(!v(e))return null;const n=St(e.id),s=St(e.source_surface),a=St(e.source_label),o=St(e.summary),l=St(e.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!o||!l?null:{id:n,source_surface:s,source_label:a,action_type:St(e.action_type),target_type:St(e.target_type),target_id:St(e.target_id),focus_kind:St(e.focus_kind),operation_id:St(e.operation_id),command_surface:St(e.command_surface),summary:o,payload_preview:St(e.payload_preview),suggested_payload:Mo(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:l}}catch{return null}}function vr(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=Xf}function tg(){const t=qd(),e=Zf((t==null?void 0:t.getItem(Ba))??null);return e?vr(e)?e:(t==null||t.removeItem(Ba),null):null}const Fd=$(tg());function Kd(t){const e=t&&vr(t)?t:null;Fd.value=e;const n=qd();if(!n)return;if(!e){n.removeItem(Ba);return}const s=Qf(e);s&&n.setItem(Ba,s)}function eg(t){if(!t)return null;const e=Mo(t.suggested_payload);if(e)return e;if(v(t.preview)){const n=Mo(t.preview.payload);if(n)return n}return null}function ng(t){if(!t)return null;const e=re(t.message);if(e)return e;const n=re(t.task_title)??re(t.title),s=re(t.task_description)??re(t.description),a=re(t.reason),o=re(t.priority)??re(t.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function fr(t,e,n,s,a,o,l,c){return[t,e,n??"action",s??"target",a??"room",o??"focus",l??"operation",c].join(":")}function Tn(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=eg(t),o=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,l=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,c=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,d=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:fr("mission",n,(t==null?void 0:t.action_type)??null,o,l,c,null,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:o,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:d,payload_preview:ng(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function sg({targetType:t,targetId:e,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:o=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:fr("execution",s,null,t,e,n,o,c),source_surface:"execution",source_label:s,action_type:null,target_type:t,target_id:e,focus_kind:n,operation_id:o,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function ag(t,e){return(e.source==="mission"||e.source==="execution")&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)&&(e.operation_id??null)===(t.operation_id??null)}function Rs(t){const{params:e}=t;if(e.source!=="mission"&&e.source!=="execution")return null;const n=Fd.value;if(n&&vr(n)&&ag(n,e))return n;const s=new Date().toISOString(),a=e.source==="execution"?"execution":"mission";return{id:fr(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,e.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,operation_id:e.operation_id??null,command_surface:e.surface??null,summary:a==="execution"?e.focus_kind?`${e.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function Bd(t){return{source:t.source_surface,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function Ud(t){if(t.command_surface)return t.command_surface;const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.focus_kind==="operation"||t.target_type==="operation"?"operations":t.target_type==="room"?"orchestra":"swarm"}function Hd(t){return{source:t.source_surface,surface:Ud(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function ig(t){return Bd(t)}function og(t){return Hd(t)}function gr(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function ui(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(t==null?void 0:t.trim())||"추천 액션"}}function rg(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"orchestra":return"오케스트라";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}const te=$(null),de=$(null);function Nt(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function Tt(t){return t==="bad"||t==="offline"||t==="critical"||t==="risk"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"||t==="watch"?"warn":"ok"}function Ut(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function lg(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"확인 필요":t<60?`${Math.round(t)}초`:t<3600?`${Math.round(t/60)}분`:t<86400?`${Math.round(t/3600)}시간`:`${Math.round(t/86400)}일`}function zt(t){switch((t??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"pending":return"대기 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":case"watch":return"주의";case"bad":case"critical":case"risk":return"위험";case"degraded":return"저하";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"loading":return"불러오는 중";case"error":return"오류";case"unavailable":return"사용 불가";case"stale":return"오래됨";case"refreshing":return"갱신 중";case"cached":return"캐시";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Ua(t){switch((t??"").trim().toLowerCase()){case"room":return"방";case"team_session":case"session":return"세션";case"operation":return"작전";case"keeper":return"키퍼";case"agent":return"에이전트";default:return(t==null?void 0:t.trim())||"대상"}}function Rl(t){switch((t??"").trim().toLowerCase()){case"metadata_gap":return"메타데이터 부족";case"mixed":return"신호 혼재";case"":return null;default:return(t==null?void 0:t.trim())||null}}function cg(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function dg(t){return gr(t?Tn(t,null,"상황판 추천 액션"):null)}function pi(t,e=Tn()){Kd(e),at(t,t==="intervene"?ig(e):og(e))}function Wd(t){pi("intervene",Tn(null,t,"상황판 incident"))}function Gd(t){pi("command",Tn(null,t,"상황판 incident"))}function $r(t,e,n="상황판 추천 액션"){pi("intervene",Tn(t,e,n))}function Jd(t,e,n="상황판 추천 액션"){pi("command",Tn(t,e,n))}function Lo(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),at(t,n)}function ug(t){return{kind:t.kind,severity:t.severity,summary:t.summary,target_type:t.target_type,target_id:t.target_id??null,actor:null,evidence:t.evidence_preview}}function pg(t){var n,s;const e=ie.value.find(a=>a.name===t.name||a.agent_name===t.agent_name)??null;return{brief:t,keeper:e,currentWork:Nt(t.current_work,110)??Nt(e==null?void 0:e.skill_primary,110)??Nt(e==null?void 0:e.last_proactive_reason,110)??"명시된 키퍼 초점 없음",recentInput:Nt(e==null?void 0:e.recent_input_preview,120)??null,recentOutput:Nt(e==null?void 0:e.recent_output_preview,120)??Nt((n=e==null?void 0:e.diagnostic)==null?void 0:n.last_reply_preview,120)??Nt(e==null?void 0:e.last_proactive_preview,120)??null,recentEvent:Nt(e==null?void 0:e.last_proactive_reason,120)??Nt((s=e==null?void 0:e.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(e==null?void 0:e.recent_tool_names)??[]}}function mg(){const t=As.value;if(!t)return new Map;const e=t.sessions.length>0?t.sessions:t.session_briefs;return new Map(e.map(n=>[n.session_id,n]))}function _g(t){te.value=te.value===t?null:t,de.value=null}function Vd(t){de.value=de.value===t?null:t,te.value=null}function vg(){te.value=null,de.value=null}function Ai(t){return(t==null?void 0:t.trim().toLowerCase())??""}function Ms(t){var e,n;return t?((e=t.agent)==null?void 0:e.exists)===!1||Ai((n=t.diagnostic)==null?void 0:n.health_state)==="offline"||Ai(t.status)==="offline"||Ai(t.status)==="inactive"?"offline":"online":"unlinked"}function Dn(t){switch(t){case"offline":return"offline";case"none_recent":return"none_recent";case"not_applicable":return"not_applicable";case"unlinked":return"unlinked";default:return"not_collected"}}function fg(t){const e=Ms(t);return e==="unlinked"?"unlinked":e==="offline"?"offline":"not_collected"}function gg(t,e){const n=Ms(t);return n==="unlinked"?"unlinked":n==="offline"?"offline":e!=null&&e.trim()?"none_recent":"not_collected"}function $g(t,e){const n=Ms(t);return n==="unlinked"?"unlinked":n==="offline"?"offline":e!=null&&e.trim()?"none_recent":"not_collected"}function Yd(t){const e=Ms(t);return e==="unlinked"?"unlinked":e==="offline"?"offline":"none_recent"}function hg(t){const e=t==null?void 0:t.trim();at("tools",e?{q:e}:void 0)}function hr(t){return(t??"").trim().toLowerCase()}function yg(t){switch(hr(t)){case"truth":return"ok";case"recorded":return"";case"derived":case"fallback":case"narrative":case"judgment":return"warn";default:return""}}function bg(t){switch(hr(t)){case"truth":return"직접 수집한 source of truth";case"derived":return"truth를 바탕으로 계산한 read-model";case"fallback":return"직접 truth가 비어 있을 때 쓰는 대체 경로";case"recorded":return"이미 기록된 결정 또는 증거";case"narrative":return"LLM 해석 레이어";case"judgment":return"판단 레이어";default:return"근거 계층"}}function Eo(t){const e=(t.label??"").trim();return e||hr(t.kind)||"unknown"}function je({item:t}){const e=Eo(t),n=yg(t.kind);return i`
    <span class="command-chip ${n}" title=${bg(t.kind)}>
      ${e}
    </span>
  `}function Xe({items:t,className:e="mission-briefing-meta",testId:n}){const s=t.filter(a=>Eo(a).trim().length>0);return s.length===0?null:i`
    <div class=${e} data-testid=${n}>
      ${s.map((a,o)=>i`<${je} key=${`${Eo(a)}-${o}`} item=${a} />`)}
    </div>
  `}function kg(t){switch(t.trim().toLowerCase()){case"active":case"running":return"가동 중";case"working":return"작업 중";case"watching":return"관찰 중";case"quiet":return"조용함";case"idle":return"유휴";case"ok":case"healthy":return"정상";case"warn":case"warning":case"degraded":return"주의";case"bad":case"critical":case"error":case"failed":return"위험";case"blocked":return"막힘";case"paused":return"일시정지";case"pending":return"대기";case"offline":case"inactive":return"오프라인";case"connected":return"연결됨";case"disconnected":return"끊김";case"ready":return"준비됨";case"done":case"completed":return"완료";case"unknown":return"알 수 없음";default:return t}}function ke({status:t,label:e}){return i`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??kg(t)}
    </span>
  `}function Xd(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}초 전`;const a=Math.floor(s/60);if(a<60)return`${a}분 전`;const o=Math.floor(a/60);return o<24?`${o}시간 전`:`${Math.floor(o/24)}일 전`}function Z({timestamp:t}){const e=Xd(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return i`<span class="time-ago" title=${n}>${e}</span>`}let xg=0;const Oe=$([]);function O(t,e="success",n=4e3){const s=++xg;Oe.value=[...Oe.value,{id:s,message:t,type:e}],setTimeout(()=>{Oe.value=Oe.value.filter(a=>a.id!==s)},n)}function Sg(t){Oe.value=Oe.value.filter(e=>e.id!==t)}function Cg(){const t=Oe.value;return t.length===0?null:i`
    <div class="toast-container">
      ${t.map(e=>i`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Sg(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}function Qd(t,e){const n=t==null?void 0:t.trim(),s=e==null?void 0:e.trim();return s?n&&s===n?null:s:null}function Ag(t,e){const n=Qd(t,e);return n?`runtime · ${n}`:null}function Tg(t,e){const n=t==null?void 0:t.trim(),s=Qd(n,e);return n?s?`keeper key · ${n} · runtime agent · ${s}`:`keeper key · ${n}`:null}const Ig="masc_dashboard_agent_name",In=$(null),Ha=$(!1),os=$(""),Wa=$([]),rs=$([]),gn=$(""),Hn=$(!1);function Ls(t){In.value=t,yr()}function Ml(){In.value=null,os.value="",Wa.value=[],rs.value=[],gn.value=""}function Rg(){const t=In.value;return t?Gt.value.find(e=>e.name===t)??null:null}function Zd(t){return t?pe.value.filter(e=>e.assignee===t):[]}function Mg(t){return t?ie.value.find(e=>e.agent_name===t||e.name===t)??null:null}function Lg(t){if(!t)return null;const e=As.value;return e?e.agent_briefs.find(n=>n.agent_name===t)??null:null}function Eg(t){return t?er.value.find(e=>e.agent_name===t||e.name===t)??null:null}async function yr(){const t=In.value;if(t){Ha.value=!0,os.value="",Wa.value=[],rs.value=[];try{const e=await Om(80);Wa.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Zd(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await Dm(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const l=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));rs.value=s}catch(e){os.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Ha.value=!1}}}async function Ll(){var s;const t=In.value,e=gn.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Ig))==null?void 0:s.trim())||"dashboard";Hn.value=!0;try{await jm(n,`@${t} ${e}`),gn.value="",O(`Mention sent to ${t}`,"success"),yr()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";O(o,"error")}finally{Hn.value=!1}}function Pg({task:t}){return i`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${ke} status=${t.status} />
    </div>
  `}function zg({row:t}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function El(t,e=160){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function wg(){const t=In.value;if(!t)return null;const e=Rg(),n=Mg(t),s=Eg(t),a=Lg(t),o=Zd(t),l=Wa.value,c=(a==null?void 0:a.display_name)??(n==null?void 0:n.name)??t,d=c!==t?t:null,p=(e==null?void 0:e.status)??(a==null?void 0:a.status)??"unknown",m=!e&&(a==null?void 0:a.is_live)===!1,f=(e==null?void 0:e.last_seen)??(a==null?void 0:a.last_activity_at)??null,h=(a==null?void 0:a.signal_truth)==="live"?"live":(a==null?void 0:a.signal_truth)==="stale"?"stale":(a==null?void 0:a.signal_truth)==="archived"?"archived":(a==null?void 0:a.signal_truth)==="unknown"?"unknown":null,y=(a==null?void 0:a.evidence_source)??null,C=(e==null?void 0:e.emoji)??(n==null?void 0:n.emoji),_=(e==null?void 0:e.koreanName)??(n==null?void 0:n.koreanName),k=El(s==null?void 0:s.continuity_summary)??El(s==null?void 0:s.skill_route_summary)??null,g=Tg(n==null?void 0:n.name,n==null?void 0:n.agent_name);return i`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${b=>{b.target.classList.contains("agent-detail-overlay")&&Ml()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${C?i`<span style="font-size:2rem">${C}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${c}
                  ${_?i`<span style="font-size:0.75em;color:#888">(${_})</span>`:""}
                  ${d?i`<span class="mono" style="font-size:0.75em;color:#888">${d}</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  <${ke} status=${p} />
                  ${m?i`<span class="pill">archived session participant</span>`:null}
                  ${e!=null&&e.model?i`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                  ${!e&&(a!=null&&a.archived_reason)?i`<span style="font-size:0.75rem;color:#888">${a.archived_reason}</span>`:null}
                  ${h?i`<span class="pill">signal · ${h}</span>`:null}
                  ${y?i`<span class="pill">source · ${y}</span>`:null}
                </div>
              </div>
            </div>
            <div class="agent-detail-sub">
              ${e!=null&&e.current_task||a!=null&&a.current_work?i`<span>Task: ${(e==null?void 0:e.current_task)??(a==null?void 0:a.current_work)}</span>`:null}
              ${f?i`<span>Last seen: <${Z} timestamp=${f} /></span>`:null}
            </div>
            ${n||k||a!=null&&a.related_session_id?i`
                  <div class="agent-detail-sub">
                    ${n?i`<span>Linked keeper: ${n.name}${g?` · ${g}`:""}</span>`:null}
                    ${a!=null&&a.related_session_id?i`<span>Session: ${a.related_session_id}</span>`:null}
                    ${k?i`<span>${k}</span>`:null}
                  </div>
                `:null}
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{yr()}} disabled=${Ha.value}>
              ${Ha.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Ml}>Close</button>
          </div>
        </div>

        ${os.value?i`<div class="council-error">${os.value}</div>`:null}

        <div class="agent-detail-grid">
          <${E} title="Assigned Tasks">
            ${o.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${o.map(b=>i`<${Pg} key=${b.id} task=${b} />`)}</div>`}
          <//>

          <${E} title="Recent Activity">
            ${l.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${l.map((b,R)=>i`<div key=${R} class="agent-activity-line">${b}</div>`)}</div>`}
          <//>
        </div>
        <${E} title="Task History">
          ${rs.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${rs.value.map(b=>i`<${zg} key=${b.taskId} row=${b} />`)}</div>`}
        <//>

        <${E} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${gn.value}
              onInput=${b=>{gn.value=b.target.value}}
              onKeyDown=${b=>{b.key==="Enter"&&Ll()}}
              disabled=${Hn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Ll()}}
              disabled=${Hn.value||gn.value.trim()===""}
            >
              ${Hn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Ng(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function jg(t){switch(t.delivery){case"sending":return"sending";case"streaming":return t.streamState==="finalizing"?"finalizing":"streaming";case"timeout":return"timeout";case"error":return"error";case"history":return t.role;default:return"delivered"}}function Ti(t){return t.delivery==="error"||t.delivery==="timeout"?"error":t.role==="user"?"user":t.role==="assistant"?"assistant":"system"}function tu(t){return t.role==="user"?"You":t.label.trim()?t.label.trim():t.role}function Og(t){return tu(t).slice(0,2).toUpperCase()}function Dg(t){var n;const e=(n=t==null?void 0:t.usage)==null?void 0:n.totalTokens;return typeof e=="number"&&Number.isFinite(e)?`${e} tok`:null}function qg(t){return t?[t.modelUsed??null,typeof t.latencyMs=="number"?`${t.latencyMs} ms`:null,Dg(t)].filter(e=>!!e):[]}function Pl(t){return typeof t!="number"||!Number.isFinite(t)?null:t===0?"$0.00":t<.01?`$${t.toFixed(4)}`:`$${t.toFixed(2)}`}function Fg(t){if(!t)return[];const e=["Goal","Progress","Next","Decisions","OpenQuestions","Constraints"];return t.split(`
`).map(n=>n.trim()).filter(Boolean).map(n=>{const s=e.find(a=>n.startsWith(`${a}:`));return s?{label:s,value:n.slice(s.length+1).trim()}:null}).filter(n=>!!(n&&n.value))}function Kg(t){var e;return[t.modelUsed?{label:"Model",value:t.modelUsed}:null,typeof t.latencyMs=="number"?{label:"Latency",value:`${t.latencyMs} ms`}:null,typeof((e=t.usage)==null?void 0:e.totalTokens)=="number"?{label:"Tokens",value:`${t.usage.totalTokens}`}:null,Pl(t.costUsd)?{label:"Cost",value:Pl(t.costUsd)}:null,t.traceId?{label:"Trace",value:t.traceId}:null,typeof t.generation=="number"?{label:"Generation",value:`${t.generation}`}:null].filter(n=>!!n)}function Bg({entry:t}){var p;const[e,n]=Ke(!1),[s,a]=Ke(!1),o=qg(t.details),l=!!t.details,c=t.details?Kg(t.details):[],d=Fg((p=t.details)==null?void 0:p.stateBlock);return i`
    <article class=${`chat-bubble ${Ti(t)}`}>
      <div class="chat-bubble-head">
        <div class="chat-bubble-identity">
          <div class=${`chat-avatar ${Ti(t)}`}>${Og(t)}</div>
          <div class="chat-bubble-identity-copy">
            <div class="chat-bubble-labels">
              <span class=${`chat-role-chip ${Ti(t)}`}>${t.label}</span>
              <span class="chat-delivery-chip">${jg(t)}</span>
              ${t.timestamp?i`<span class="chat-time-chip">${Ng(t.timestamp)}</span>`:null}
            </div>
            <div class="chat-identity-title">${tu(t)}</div>
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
            ${o.map(m=>i`<span class="chat-detail-chip">${m}</span>`)}
          </div>`:null}

      <div class="chat-bubble-body">${t.text||(t.delivery==="streaming"?"…":"(empty reply)")}</div>
      ${t.error?i`<div class="chat-bubble-error">${t.error}</div>`:null}

      ${e&&t.details?i`
            <div class="chat-detail-panel">
              ${c.length>0?i`
                    <div class="chat-overview-grid">
                      ${c.map(m=>i`
                        <div class="chat-overview-card">
                          <div class="chat-overview-label">${m.label}</div>
                          <div class="chat-overview-value">${m.value}</div>
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
                        ${d.map(m=>i`
                          <div class="chat-state-card">
                            <div class="chat-state-label">${m.label}</div>
                            <div class="chat-state-value">${m.value}</div>
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
  `}function Ug({entries:t,emptyText:e}){const n=ee(null),s=t.map(a=>`${a.id}:${a.text.length}:${a.delivery}`).join("|");return tt(()=>{const a=n.current;a&&(a.scrollTop=a.scrollHeight)},[s]),i`
    <div class="chat-transcript" ref=${n}>
      ${t.length===0?i`<div class="chat-empty-copy">${e}</div>`:t.map(a=>i`<${Bg} key=${a.id} entry=${a} />`)}
    </div>
  `}function Hg({draft:t,placeholder:e,disabled:n,streaming:s,onDraftChange:a,onSend:o,onAbort:l}){return i`
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
  `}function Wg(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Gg(t){switch(t){case"manual_lodge_poke":return"Run Social Sweep";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function zl(t){switch(t){case"healthy":return"정상";case"recovering":return"복구 중";case"desired_offline":return"의도적 오프라인";case"offline":return"오프라인";default:return null}}function Jg(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Vg(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function eu(t){if(!t)return null;const e=se.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function Yg({keeper:t,showRawStatus:e=!1}){if(tt(()=>{t!=null&&t.name&&Bc(t.name)},[t==null?void 0:t.name]),!t)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=se.value[t.name],s=eu(t),a=mo.value[t.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        ${zl(s==null?void 0:s.continuity_state)?i`<span class="pill">${zl(s==null?void 0:s.continuity_state)}</span>`:null}
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Wg(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Gg((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.continuity_summary)??(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${Jg(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${Vg(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function nu({keeperName:t,placeholder:e}){const[n,s]=Ke("");tt(()=>{t&&Bc(t)},[t]);const a=$t.value[t]??[],o=ka.value[t]??!1,l=Bt.value[t],c=async()=>{const d=n.trim();if(!(!t||!d)){s("");try{await c_(t,d)}catch(p){if(p instanceof Error&&p.name==="AbortError")return;const m=p instanceof Error?p.message:`Failed to message ${t}`;O(m,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <${Ug}
        entries=${a}
        emptyText="No direct keeper conversation yet."
      />
      <${Hg}
        draft=${n}
        placeholder=${e}
        disabled=${!t}
        streaming=${o}
        onDraftChange=${s}
        onSend=${()=>{c()}}
        onAbort=${()=>{Kc(t)}}
      />
      ${l?i`<div class="control-status-copy control-error-copy">${l}</div>`:null}
    </div>
  `}function Xg({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=eu(e),a=_o.value[e.name]??!1,o=vo.value[e.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{d_(e.name,t).catch(d=>{const p=d instanceof Error?d.message:`Failed to probe ${e.name}`;O(p,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{u_(e.name,t).catch(d=>{const p=d instanceof Error?d.message:`Failed to recover ${e.name}`;O(p,"error")})}}
        disabled=${o||!c||!t.trim()}
      >
        ${o?"Recovering...":"Recover"}
      </button>
      <button
        class=${`control-btn ghost ${l==="manual_lodge_poke"?"is-active":""}`}
        onClick=${n}
      >
        Run Social Sweep
      </button>
    </div>
  `}const br=$(null);function su(t){br.value=t,l_(t.name)}function wl(){br.value=null}const Qe=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Qg(t){if(!t)return 0;const e=Qe.findIndex(n=>n.level===t);return e>=0?e:0}function Zg({keeper:t}){const e=Qg(t.autonomy_level),n=Qe[e]??Qe[0];if(!n)return null;const s=(e+1)/Qe.length*100;return i`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${Qe.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Qe.map((a,o)=>i`
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
            <strong><${Z} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?i`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function pa(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function t$(t){switch(t){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"social_sweep":case"lodge_tick":return"social";default:return(t==null?void 0:t.trim())||"action"}}function e$(t){return t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]}function n$(t){const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function s$(t){const e=As.value;return e?e.keeper_briefs.find(n=>n.name===t.name||n.agent_name&&t.agent_name&&n.agent_name===t.agent_name)??null:null}function a$({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=n&&Number.isFinite(n.cost_usd)?`$${n.cost_usd.toFixed(4)}`:null,a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${pa(t.context_tokens)}</div>
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
  `}function i$({keeper:t}){var m,f;const e=t.metrics_series??[];if(e.length<2){const h=(((m=t.context)==null?void 0:m.context_ratio)??0)*100,y=h>85?"#ef4444":h>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${h.toFixed(1)}%;background:${y}"></div>
        </div>
        <span class="chart-pct">${h.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=e.length,l=e.map((h,y)=>{const C=a+y/(o-1)*(n-2*a),_=s-a-(h.context_ratio??0)*(s-2*a);return{x:C,y:_,p:h}}),c=l.map(({x:h,y})=>`${h.toFixed(1)},${y.toFixed(1)}`).join(" "),d=(((f=e[e.length-1])==null?void 0:f.context_ratio)??0)*100,p=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:h})=>h.is_handoff).map(({x:h})=>i`
          <line x1="${h.toFixed(1)}" y1="${a}" x2="${h.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${p}" stroke-width="1.5"/>
        ${l.filter(({p:h})=>h.is_compaction).map(({x:h,y})=>i`
          <circle cx="${h.toFixed(1)}" cy="${y.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const Ii=$("");function o$({keeper:t}){var a,o,l,c;const e=Ii.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=t.interests)==null?void 0:o.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Ii.value}
        onInput=${d=>{Ii.value=d.target.value}}
      />
      ${s.map(d=>i`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${d.title}</span>
          <span class="keeper-field-key">${d.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${d.value}</span>
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
      ${t.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${pa(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${pa(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${pa(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function r$({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return i`
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
  `}function l$({items:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>i`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function c$({rels:t}){const e=Object.entries(t);return e.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Nl({traits:t,label:e}){return t.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Ri(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function d$({keeper:t}){const e=t.metrics_window,s=[{label:"Model fallback",value:Ri(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Ri(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Ri(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}].filter(a=>!(a.value==="-"||a.value==="—"||a.value===""));return s.length===0?null:i`
    <div class="keeper-signal-list">
      ${s.map(a=>i`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function u$({keeper:t}){var I,D,J,et,G,P,A;const e=((I=It.value)==null?void 0:I.room)??{},n=(((D=It.value)==null?void 0:D.available_actions)??[]).filter(z=>z.target_type==="keeper"||z.target_type==="room").slice(0,8),s=e$(t),a=n$(t),o=s$(t),l=o!=null&&o.allowed_tool_names&&o.allowed_tool_names.length>0?o.allowed_tool_names:t.allowed_tool_names??[],c=o!=null&&o.latest_tool_names&&o.latest_tool_names.length>0?o.latest_tool_names:t.latest_tool_names??[],d=(o==null?void 0:o.latest_tool_call_count)??t.latest_tool_call_count,p=(o==null?void 0:o.tool_audit_source)??t.tool_audit_source,m=(o==null?void 0:o.tool_audit_at)??t.tool_audit_at,f=((J=t.agent)==null?void 0:J.capabilities)??[],h=e.current_room??e.room_id??((et=dt.value)==null?void 0:et.room)??"default",y=e.project??((G=dt.value)==null?void 0:G.project)??"확인 없음",C=e.cluster??((P=dt.value)==null?void 0:P.cluster)??"확인 없음",_=Dn(fg(t)),k=Dn(gg(t,p)),g=Dn($g(t,p)),b=Dn(Yd(t)),R=Ms(t),L=((A=t.agent)==null?void 0:A.current_task)??(R==="offline"?"offline":"not_collected"),S=t.skill_primary??(R==="offline"?"offline":"not_collected"),M=l[0]??c[0]??s[0]??null;return i`
    <div class="keeper-signal-list">
      <div class="keeper-signal-row">
        <span>Room</span>
        <strong>${h}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Project</span>
        <strong>${y}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Cluster</span>
        <strong>${C}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Current task</span>
        <strong>${L}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Skill route</span>
        <strong>${S}</strong>
      </div>
      <div style="display:flex; justify-content:flex-end; margin-top:4px;">
        <button class="control-btn ghost" onClick=${()=>{hg(M)}}>
          Open tools panel
        </button>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Allowed tools</span>
        <span style="font-size:11px; color:#64748b;">Currently permitted tools for this keeper runtime.</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${l.length>0?l.map(z=>i`<span class="pill">${z}</span>`):i`<span style="font-size:12px; color:#888;">${_}</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Observed tools</span>
        <span style="font-size:11px; color:#64748b;">Recent execution evidence from heartbeat or runtime telemetry.</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${c.length>0?c.map(z=>i`<span class="pill">${z}</span>`):i`<span style="font-size:12px; color:#888;">${k}</span>`}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Tool calls</span>
        <strong>${typeof d=="number"?d:k==="none_recent"?0:g}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Evidence source</span>
        <strong>${p??g}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Observed at</span>
        <strong>${m?i`<${Z} timestamp=${m} />`:g}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Keeper recent tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${s.length>0?s.map(z=>i`<span class="pill">${z}</span>`):i`<span style="font-size:12px; color:#888;">${b}</span>`}
        </div>
      </div>
      ${a.length>0?i`
            <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
              <span style="font-size:12px; color:#888;">Window top tools</span>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${a.map(z=>i`<span class="pill">${z}</span>`)}
              </div>
            </div>
          `:null}
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${f.length>0?f.map(z=>i`<span class="pill">${z}</span>`):i`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(z=>i`<span class="pill">${t$(z.action_type)}</span>`):i`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function au(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function p$(){try{const t=await Ss({actor:au(),action_type:"social_sweep",target_type:"room",payload:{}}),e=qc(t.result);await Cs();const n=(e==null?void 0:e.last_system_skip_reason)??(e==null?void 0:e.skipped_reason);n?O(n,"warning"):O(e?`Social sweep finished: ${e.acted}/${e.checked} acted`:"Social sweep finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run social sweep";O(e,"error")}}function m$({keeper:t}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Yg} keeper=${t} />
          <${Xg}
            actor=${au()}
            keeper=${t}
            onPokeLodge=${()=>{p$()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${nu}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function _$(){var e,n,s;const t=br.value;return t?i`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&wl()}}
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
            <${ke} status=${t.status} />
            ${t.model?i`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>wl()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${a$} keeper=${t} />

        ${""}
        <${i$} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${E} title="Field Dictionary">
            <${o$} keeper=${t} />
          <//>

          ${""}
          <${E} title="Profile">
            <${Nl} traits=${t.traits??[]} label="Traits" />
            <${Nl} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${Z} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?i`
              <${E} title="Autonomy">
                <${Zg} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?i`
              <${E} title="TRPG Stats">
                <${r$} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?i`
              <${E} title="Equipment (${t.inventory.length})">
                <${l$} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?i`
              <${E} title="Relationships (${Object.keys(t.relationships).length})">
                <${c$} rels=${t.relationships} />
              <//>
            `:null}

          <${E} title="Runtime Signals">
            <${d$} keeper=${t} />
          <//>

          <${E} title="Neighborhood & Tool Audit">
            <${u$} keeper=${t} />
          <//>

          <${E} title="Memory & Context">
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
        <${m$} keeper=${t} />
      </div>
    </div>
  `:null}function v$({cluster:t,project:e,room:n,generatedAt:s}){return i`
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
  `}function Te({label:t,value:e,detail:n,tone:s}){return i`
    <article class="mission-stat-card ${Tt(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function f$(){const t=fd.value,e=Tt((t==null?void 0:t.status)??(Le.value?"bad":"warn")),n=!t||t.sections.length===0,s=(t==null?void 0:t.status)==="error"||(t==null?void 0:t.status)==="unavailable"&&!(t!=null&&t.cached);return i`
    <${E} title="판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>왜 그렇게 보이나</h3>
        <p>사회 truth를 읽은 뒤에만 별도 판단 결과를 참고하고, 근거는 접어서 둡니다.</p>
        <${Xe}
          items=${[{kind:"narrative"},{kind:"fallback",label:"fallback on failure"}]}
        />
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${e}">
          ${zt((t==null?void 0:t.status)??(Le.value?"error":"loading"))}
        </span>
        ${t!=null&&t.model?i`<span class="command-chip">${t.model}</span>`:null}
        ${t!=null&&t.generated_at?i`<span class="command-chip">${Ut(t.generated_at)}</span>`:null}
        ${t!=null&&t.cached?i`<span class="command-chip">캐시</span>`:null}
        ${t!=null&&t.stale?i`<span class="command-chip warn">오래됨</span>`:null}
        ${t!=null&&t.refreshing?i`<span class="command-chip warn">갱신 중</span>`:null}
      </div>

      ${Le.value?i`<div class="empty-state error">${Le.value}</div>`:null}
      ${t!=null&&t.error?i`<div class="empty-state error">${t.error}</div>`:null}
      ${t!=null&&t.summary?i`<div class="mission-inline-note">${t.summary}</div>`:null}
      ${t!=null&&t.last_error&&!t.error?i`<div class="mission-inline-note">최근 갱신 실패: ${t.last_error}</div>`:null}

      ${t&&t.sections.length>0?i`
            <div class="mission-briefing-grid">
              ${t.sections.slice(0,3).map(a=>i`
                <article class="mission-briefing-section ${Tt(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${Tt(a.status)}">${zt(a.status)}</span>
                      ${Rl(a.signal_class)?i`<span class="command-chip ${a.signal_class==="mixed"?"warn":""}">${Rl(a.signal_class)}</span>`:null}
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
          `:!en.value&&!Le.value&&n?i`
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
                      <strong>${Ua(a.scope_type)}${a.scope_id?` · ${a.scope_id}`:""}</strong>
                      <span class="command-chip ${a.severity==="watch"?"warn":""}">${zt(a.severity)}</span>
                    </div>
                    <p>${a.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{La(s)}} disabled=${en.value}>
          ${en.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{La(!0)}} disabled=${en.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function g$({item:t,selected:e,sessionLookup:n}){const s=ug(t),a=t.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),o=t.top_action??null;return i`
    <article class="mission-attention-card ${Tt((o==null?void 0:o.severity)??t.severity)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>_g(t.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.summary}</strong>
            <div class="mission-card-target">${Ua(t.target_type)}${t.target_id?` · ${t.target_id}`:""}</div>
          </div>
          <span class="command-chip ${Tt((o==null?void 0:o.severity)??t.severity)}">${o?cg(o):t.severity}</span>
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
            <small>${Ua(t.target_type)}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${o?ui(o.action_type):"판단 필요"}</strong>
            <small>${o?dg(o):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${o?i`<div class="mission-inline-note">${o.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?i`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>i`
                  <button class="mission-link-row" onClick=${()=>Vd(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${zt(l.status)} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:i`<div class="empty-state">직접 연결된 세션이 아직 없습니다.</div>`}

        ${t.related_agent_names.length>0?i`
              <div class="mission-pill-row">
                ${t.related_agent_names.slice(0,8).map(l=>i`
                  <button class="mission-pill action" onClick=${()=>Ls(l)}>${l}</button>
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
              <button class="control-btn ghost" onClick=${()=>$r(o,s,"상황판 주의 신호")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>Jd(o,s,"상황판 주의 신호")}>
                원인 보기
              </button>
            `:i`
              <button class="control-btn ghost" onClick=${()=>Wd(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Gd(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function $$({brief:t,selected:e}){var d,p;const n=t.member_previews.slice(0,4),s=t.top_recommendation??null,a=t.top_attention??null,o=t.active_count??0,l=t.seen_count??o,c=t.planned_count??t.member_names.length;return i`
    <article class="mission-crew-card ${Tt(((d=t.top_attention)==null?void 0:d.severity)??t.health??t.status)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Vd(t.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.goal}</strong>
            <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          </div>
          <span class="command-chip ${Tt(((p=t.top_attention)==null?void 0:p.severity)??t.health??t.status)}">${zt(t.status)}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${t.member_names.length}</strong>
            <small>${t.member_names.slice(0,3).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${lg(t.elapsed_sec)}</strong>
            <small>${t.started_at?`${Ut(t.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 흐름</span>
            <strong>${t.last_event_at?Ut(t.last_event_at):"기록 없음"}</strong>
            <small>${t.communication_summary??"요약 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>충원 상태</span>
            <strong>${o}/${t.required_count||1}</strong>
            <small>live · seen ${l} · planned ${c}</small>
          </div>
        </div>
      </button>

      ${t.blocker_summary?i`<div class="mission-inline-note">막힘 · ${t.blocker_summary}</div>`:null}
      ${t.counts_basis?i`<div class="mission-inline-note">관측 기준 · ${t.counts_basis}</div>`:null}

      <div class="mission-crew-event">
        <span>최근 사건</span>
        <strong>${t.last_event_summary??"최근 세션 이벤트가 없습니다."}</strong>
        <small>${t.last_event_at?Ut(t.last_event_at):"시각 없음"}</small>
      </div>

      ${t.operation_badges.length>0?i`
            <div class="mission-pill-row">
              ${t.operation_badges.slice(0,3).map(m=>i`
                <span class="mission-pill">
                  ${m.operation_id} · ${zt(m.status)}${m.stage?` · ${m.stage}`:""}
                </span>
              `)}
            </div>
          `:null}

      ${n.length>0?i`
            <div class="mission-member-preview-grid">
              ${n.map(m=>i`
                <button class="mission-member-preview" onClick=${()=>Ls(m.agent_name)}>
                  <strong>${m.agent_name}</strong>
                  <span>
                    ${m.current_work??"현재 작업 없음"}
                    ${m.is_live===!1?" · archived":m.is_live===!0?" · live":""}
                  </span>
                  <small>${m.recent_output_preview??m.recent_input_preview??"최근 입출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Lo("intervene",t.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Lo("command",t.session_id)}>세션 원인 보기</button>
        ${s?i`<button class="control-btn ghost" onClick=${()=>$r(s,a,"상황판 세션 요약")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function h$({detail:t,loading:e,error:n}){if(e&&!t)return i`
      <${E} title="세션 상세" class="mission-list-card">
        <div class="loading-indicator">세션 상세 불러오는 중...</div>
      <//>
    `;if(n&&!t)return i`
      <${E} title="세션 상세" class="mission-list-card">
        <div class="empty-state error">${n}</div>
      <//>
    `;if(!(t!=null&&t.session))return null;const s=t.session;return i`
    <${E} title="세션 상세" class="mission-list-card" semanticId="mission.session_detail">
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
                  <button class="mission-member-preview" onClick=${()=>Ls(a.agent_name)}>
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
                  <button class="mission-link-row" onClick=${()=>Lo("command",s.session_id)}>
                    <strong>${a.operation_id}</strong>
                    <span>${zt(a.status)}${a.stage?` · ${a.stage}`:""}</span>
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
                    <span>${zt(a.status)}${a.generation!=null?` · 세대 ${a.generation}`:""}</span>
                    <small>${a.current_work??"현재 작업 정보 없음"}</small>
                  </div>
                `):i`<div class="empty-state">직접 연결된 키퍼는 없습니다.</div>`}
          </div>
        </div>
      </div>
    <//>
  `}function y$({row:t}){var s,a,o,l,c,d,p,m,f,h;const e=[`세대 ${t.brief.generation??((s=t.keeper)==null?void 0:s.generation)??0}`,t.brief.context_ratio!=null?`컨텍스트 ${Math.round(t.brief.context_ratio*100)}%`:((a=t.keeper)==null?void 0:a.context_ratio)!=null?`컨텍스트 ${Math.round(t.keeper.context_ratio*100)}%`:null,t.brief.last_turn_ago_s!=null?`최근 턴 ${Math.round(t.brief.last_turn_ago_s)}초 전`:null].filter(y=>y!==null).join(" · "),n=t.recentTools.length>0?t.recentTools.join(", "):Dn(Yd(t.keeper));return i`
    <article class="mission-activity-card ${Tt(t.brief.status??((o=t.keeper)==null?void 0:o.status))}">
      <button class="mission-card-select" onClick=${()=>{t.keeper&&su(t.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((l=t.keeper)==null?void 0:l.emoji)??""}</span>
            <div>
              <strong>${t.brief.name}</strong>
              ${(c=t.keeper)!=null&&c.koreanName?i`<span>${t.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${Tt(t.brief.status??((d=t.keeper)==null?void 0:d.status))}">${zt(t.brief.status??((p=t.keeper)==null?void 0:p.status))}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 하트비트 · ${(m=t.keeper)!=null&&m.last_heartbeat?Ut(t.keeper.last_heartbeat):"기록 없음"}</span>
          <span>${e||"연속성 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${t.currentWork}</strong>
          ${(f=t.keeper)!=null&&f.skill_reason?i`<small>판단 요약 · ${Nt(t.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>연속성 상세</summary>
        <div class="mission-activity-foot">
          <span>에이전트 · ${t.brief.agent_name??((h=t.keeper)==null?void 0:h.agent_name)??"기록 없음"}</span>
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
  `}function b$({item:t}){const e=t.action??null,n=t.attention??null;return i`
    <article class="mission-action-card ${Tt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${Tt(t.severity)}">
          ${t.signal_type==="action"&&e?ui(e.action_type):(n==null?void 0:n.kind)??"내부 신호"}
        </span>
        <span class="mission-card-target">${Ua(t.target_type)}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      ${e?i`<div class="mission-action-preview">${e.reason}</div>`:null}
      <div class="mission-card-actions">
        ${e?i`
              <button class="control-btn ghost" onClick=${()=>$r(e,n,"상황판 내부 신호")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Jd(e,n,"상황판 내부 신호")}>이 이슈의 원인 보기</button>
            `:n?i`
                <button class="control-btn ghost" onClick=${()=>Wd(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>Gd(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function jl(){var S,M;const t=As.value;if(ko.value&&!t)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(Ma.value&&!t)return i`<div class="empty-state error">${Ma.value}</div>`;if(!t)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;te.value&&!t.attention_queue.some(I=>I.id===te.value)&&(te.value=null);const e=t.sessions;de.value&&!e.some(I=>I.session_id===de.value)&&(de.value=null);const n=t.attention_queue.find(I=>I.id===te.value)??null,s=(n==null?void 0:n.related_session_ids.find(I=>e.some(D=>D.session_id===I)))??null,a=de.value??s??((S=e[0])==null?void 0:S.session_id)??null,o=mg(),l=e.find(I=>I.session_id===a)??null,c=t.keeper_briefs.slice(0,6).map(pg),d=t.attention_queue.filter(I=>I.related_session_ids.length>0).slice(0,6),p=t.internal_signals.slice(0,3),m=e.filter(I=>I.top_attention!=null||I.related_attention_count>0).length,f=e.filter(I=>!!I.blocker_summary).length,h=e.filter(I=>!!I.last_event_summary||!!I.last_event_at).length,y=new Set,C=new Set;for(const I of e)for(const D of I.member_previews??[])y.add(D.agent_name),D.recent_output_preview&&C.add(D.agent_name);const _=y.size,k=C.size,g=c.filter(I=>{const D=(I.brief.status??"").trim().toLowerCase();return D!==""&&D!=="ok"}).length,b=e.filter(I=>{const D=I.member_previews??[];return D.length===0||D.every(J=>!J.recent_output_preview)}).length,R=((l==null?void 0:l.member_previews)??[]).filter(I=>I.recent_output_preview),L=c.filter(I=>I.recentOutput).slice(0,4);return tt(()=>{Bv(a)},[a]),i`
    <section class="dashboard-panel mission-view">
      <${vt} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 어떤 세션이 돌고 있고, 누가 참여하며, 어디가 막혔는지를 한 시점에서 읽는 기본 관찰면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${Tt(t.summary.room_health)}">${zt(t.summary.room_health)}</span>
          <span class="command-chip">${t.summary.project??"프로젝트 미지정"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?Ut(t.generated_at):"기록 없음"}</span>
        </div>
      </div>

      <${v$}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <div class="mission-stat-grid">
        <${Te}
          label="활성 세션"
          value=${e.length}
          detail="session card에 표시된 협업 단위"
          tone=${((M=l==null?void 0:l.top_attention)==null?void 0:M.severity)??(l==null?void 0:l.health)??"ok"}
        />
        <${Te}
          label="attention 세션"
          value=${m}
          detail="top_attention 또는 related_attention_count"
          tone=${m>0?"warn":"ok"}
        />
        <${Te}
          label="blocker 세션"
          value=${f}
          detail="blocker_summary가 있는 세션"
          tone=${f>0?"warn":"ok"}
        />
        <${Te}
          label="사건 기록 세션"
          value=${h}
          detail="last_event_at 또는 last_event_summary"
          tone=${h>0?"ok":"warn"}
        />
        <${Te}
          label="출력 preview 참여자"
          value=${k}
          detail=${_>0?`participant preview ${_}명 중`:"participant preview 없음"}
          tone=${k>0?"ok":"warn"}
        />
        <${Te}
          label="비-ok 키퍼"
          value=${g}
          detail=${c.length>0?`keeper brief ${c.length}명 중`:"keeper brief 없음"}
          tone=${g>0?"warn":"ok"}
        />
        <${Te}
          label="출력 preview 없는 세션"
          value=${b}
          detail="recent_output_preview가 없는 세션"
          tone=${b>0?"warn":"ok"}
        />
      </div>

      ${a?i`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${(l==null?void 0:l.goal)??a}${n?` · ${n.summary}`:""}</span>
              <button class="control-btn ghost" onClick=${vg}>선택 해제</button>
            </div>
          `:null}

      <${E} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 작전을 먼저 읽고 사회의 현재 상태를 파악합니다.</p>
          <${Xe} items=${[{kind:"truth"}]} />
        </div>
        <div class="mission-list-stack">
          ${e.length>0?e.map(I=>i`<${$$} key=${I.session_id} brief=${I} selected=${a===I.session_id} />`):i`<div class="empty-state">지금 활성 세션이 없습니다.</div>`}
        </div>
      <//>

      <${h$}
        detail=${xo.value}
        loading=${da.value}
        error=${ua.value}
      />

      <${E} title="키퍼 연속성" class="mission-list-card" semanticId="mission.keeper_activity">
        <div class="mission-section-head">
          <h3>세션 밖에서 움직이는 행위자</h3>
          <p>키퍼는 세션과 별개로 보고, 사회의 연속성과 장기 행위자 상태를 먼저 읽습니다.</p>
          <${Xe} items=${[{kind:"truth"}]} />
        </div>
        <div class="mission-activity-list">
          ${c.length>0?c.map(I=>i`<${y$} key=${I.brief.name} row=${I} />`):i`<div class="empty-state">지금 보이는 키퍼가 없습니다.</div>`}
        </div>
        <div class="mission-card-actions">
          <button class="control-btn ghost" onClick=${()=>at("execution")}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${()=>at("command")}>지휘 진단면 보기</button>
        </div>
      <//>

      <${E} title="최근 사회 활동" class="mission-list-card" semanticId="mission.session_activity">
        <div class="mission-section-head">
          <h3>누가 방금 무엇을 했나</h3>
          <p>선택된 세션과 연결된 행위자의 최근 출력만 모아 읽고, 해석은 뒤로 미룹니다.</p>
          <${Xe} items=${[{kind:"truth"}]} />
        </div>
        <div class="mission-list-stack">
          ${R.length>0?R.slice(0,4).map(I=>i`
                <div class="mission-inline-note">
                  <strong>${I.agent_name??"unknown actor"}</strong>
                  ${I.role?i` · ${I.role}`:null}
                  ${I.status?i` · ${zt(I.status)}`:null}
                  <div>${I.recent_output_preview}</div>
                </div>
              `):i`<div class="empty-state">선택된 세션에서 바로 읽을 최근 출력이 없습니다.</div>`}
          ${L.length>0?L.map(I=>i`
                <div class="mission-inline-note">
                  <strong>${I.brief.name}</strong>
                  <div>${I.recentOutput}</div>
                </div>
              `):null}
        </div>
      <//>

      <${E} title="세션 우선순위" class="mission-list-card" semanticId="mission.attention_queue">
        <div class="mission-section-head">
          <h3>어느 세션을 먼저 봐야 하나</h3>
          <p>주의 신호는 truth를 훑은 다음에만 읽고, 세션 집중 순서를 정하는 용도로만 씁니다.</p>
          <${Xe} items=${[{kind:"derived"}]} />
        </div>
        <div class="mission-lane-stack">
          ${d.length>0?d.map(I=>i`<${g$} key=${I.id} item=${I} selected=${te.value===I.id} sessionLookup=${o} />`):i`<div class="empty-state">지금 세션 단위 주의 대기열은 비어 있습니다.</div>`}
        </div>
      <//>

      <div class="mission-human-grid">
        <${f$} />

        <${E} title="운영 보조 진단" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>시스템 진단</h3>
            <p>artifact scope drift 같은 내부 신호는 사회 흐름을 읽은 뒤에만 참고하도록 아래 보조 면으로 둡니다.</p>
            <${Xe} items=${[{kind:"derived"}]} />
          </div>
          <details class="mission-card-disclosure">
            <summary>내부 신호 ${p.length}</summary>
            <div class="mission-list-stack">
              ${p.length>0?p.map(I=>i`<${b$} key=${I.id} item=${I} />`):i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
            </div>
          </details>
        <//>
      </div>
    </section>
  `}const k$="modulepreload",x$=function(t){return"/dashboard/"+t},Ol={},S$=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(p){return Promise.all(p.map(m=>Promise.resolve(m).then(f=>({status:"fulfilled",value:f}),f=>({status:"rejected",reason:f}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),d=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(p=>{if(p=x$(p),p in Ol)return;Ol[p]=!0;const m=p.endsWith(".css"),f=m?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${p}"]${f}`))return;const h=document.createElement("link");if(h.rel=m?"stylesheet":k$,m||(h.as="script"),h.crossOrigin="",h.href=p,d&&h.setAttribute("nonce",d),document.head.appendChild(h),m)return new Promise((y,C)=>{h.addEventListener("load",y),h.addEventListener("error",()=>C(new Error(`Unable to preload CSS for ${p}`)))})}))}function o(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&o(c.reason);return e().catch(o)})};function ls(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Q(t){if(!t)return"정보 없음";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function C$(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function iu(t){if(!t)return"정보 없음";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"기한 지남":n<60?`${n}초 후`:n<3600?`${Math.round(n/60)}분 후`:n<86400?`${Math.round(n/3600)}시간 후`:`${Math.round(n/86400)}일 후`}function w(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let Dl=!1,A$=0;function T$(){return++A$}let Mi=null;async function I$(){Mi||(Mi=S$(()=>import("./mermaid.core-C94DVEG1.js").then(e=>e.bE),[]).then(e=>e.default));const t=await Mi;return Dl||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),Dl=!0),t}function fe(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Rn(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":`${Math.round(t*100)}%`}function an(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":t<60?`${Math.round(t)}초`:t<3600?`${Math.round(t/60)}분`:`${Math.round(t/3600)}시간`}function Es(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function Ie(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:Es(t/e*100)}function R$(t,e){const n=Es(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function mi(t){if(!t)return"최근 체인 이력이 없습니다";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`토큰 ${t.tokens}`),t.message&&e.push(t.message),e.join(" · ")}const M$=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],ou=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"orchestra",label:"오케스트라",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],L$=ou.map(t=>t.id),E$=["chain_start","node_start","node_complete","chain_complete","chain_error"],P$={warroom:{title:"실시간 워룸",description:"실제 실행, 워커, 메시지, 트레이스를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 작전, 분견대, 의존 관계를 먼저 읽는 기본 진입 표면입니다."},orchestra:{title:"룸 오케스트라 맵",description:"룸, 세션, 레인, 워커, 키퍼를 한 장의 작전판으로 읽는 시각화 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"레인 이동, 워커 결속, 막힘을 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 작전별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"실제 관리 유닛인지, 실시간 에이전트 기반 자동 투영인지 구분해서 봅니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"작전, 주체, 유닛 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"결정 승인과 유닛 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function ql(t){return!!t&&L$.includes(t)}function z$(){const t=K.value.params;return t.source!=="mission"&&t.source!=="execution"?{}:{source:t.source,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function Ps(t){const e=z$(),n=cu(),s=kr();if(t==="operations")return e;if(t==="chains"){const a=fn.value;return a?{...e,surface:t,operation:a}:{...e,surface:t}}return t==="swarm"||t==="warroom"||t==="orchestra"?{...e,surface:t,...n?{run_id:n}:{},...s?{operation_id:s}:{}}:{...e,surface:t}}function w$(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function N$(t){switch(t){case"company":return"중대";case"platoon":return"소대";case"squad":return"분대";case"agent":return"에이전트";default:return t}}function ut(t){return Co.value===t}function zs(){return lr.value}function j$(t){var a,o,l,c,d,p,m;const e=lr.value,n=Ge.value,s=Is.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"실시간 실행, 워커, 메시지, 트레이스를 한 화면에서 보고 필요한 세부 표면으로 바로 이동합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 의존 관계를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(o=e==null?void 0:e.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((d=(c=e==null?void 0:e.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:d.reason)??"레인 이동과 막힘 근거를 보고 다음 확인 도구를 고릅니다."};case"orchestra":return{tool:"masc_operator_snapshot",reason:"룸, 세션, 레인, 워커, 키퍼를 한 장에서 훑은 뒤 내려볼 대상을 고릅니다."};case"chains":return{tool:(m=(p=s==null?void 0:s.operations[0])==null?void 0:p.preview_run)!=null&&m.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"이 구조가 실제 관리 단위인지 자동 투영인지 먼저 구분해야 지휘면을 오해하지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 유닛과 작전을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"트레이스 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 제어 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function O$(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function D$(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function ru(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function lu(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,o)=>{t.has(o)||t.set(o,a)}),t}function cu(){const e=lu().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function kr(){const e=lu().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function q$(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function F$(t){return t.status==="claimed"||t.status==="in_progress"}function K$(t){const e=Ts.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function Li(t){var e;return((e=Ts.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function B$(t){const e=Ts.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function ge(t){try{await t()}catch{}}function xr(t){return(t==null?void 0:t.trim().toLowerCase())??""}function ue(t){const e=xr(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function Ft(t){const e=xr(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function U$(){var n,s,a,o,l,c,d,p,m;const t=Ge.value;if(!t)return!1;const e=t.workers.some(f=>f.joined||f.live_presence||f.completed||f.current_task_matches_run||f.heartbeat_fresh||f.claim_marker_seen||f.done_marker_seen||f.final_marker_seen||!!f.current_task||!!f.bound_task_id||!!f.last_message);return!!((n=t.operation)!=null&&n.operation_id||(s=t.detachment)!=null&&s.detachment_id||(((a=t.summary)==null?void 0:a.joined_workers)??0)>0||(((o=t.summary)==null?void 0:o.live_workers)??0)>0||(((l=t.summary)==null?void 0:l.current_task_bound)??0)>0||(((c=t.summary)==null?void 0:c.fresh_heartbeats)??0)>0||(((d=t.summary)==null?void 0:d.claim_markers_seen)??0)>0||(((p=t.summary)==null?void 0:p.done_markers_seen)??0)>0||(((m=t.summary)==null?void 0:m.final_markers_seen)??0)>0||e||t.recent_messages.length>0||t.recent_trace_events.length>0)}function H$(t){const e=xr(t.status);return e==="active"||e==="running"}function W$(){var o,l,c,d;const t=((o=It.value)==null?void 0:o.sessions)??[],e=Ge.value,n=((l=e==null?void 0:e.detachment)==null?void 0:l.session_id)??null;if(n){const p=t.find(m=>m.session_id===n);if(p)return p}const s=((c=e==null?void 0:e.operation)==null?void 0:c.operation_id)??kr();if(s){const p=t.find(m=>m.command_plane_operation_id===s);if(p)return p}const a=((d=e==null?void 0:e.detachment)==null?void 0:d.detachment_id)??null;if(a){const p=t.find(m=>m.command_plane_detachment_id===a);if(p)return p}return t.find(H$)??t[0]??null}function zn(t){return t==="proven"?"ok":t==="partial"?"warn":"bad"}function on(t){return Array.isArray(t)?t:[]}function jt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)?t:{}}function Fs(t){return typeof t=="string"&&t.trim()!==""?t:null}function G$(t){return typeof t=="number"&&Number.isFinite(t)?t:null}function J$(t){const e=t.split("/");return e.length<=3?t:`…/${e.slice(-3).join("/")}`}function V$(t){return t==="proven"?"충분":t==="partial"?"부분":"부족"}function Y$(t){return t==="proven"?"협업 증거가 충분합니다":t==="partial"?"흔적은 있으나 협업 증거가 덜 모였습니다":"증거가 부족합니다"}function X$(t,e,n,s,a,o,l,c,d){const p=[`${s}명이 실제 흔적을 남겼고, 계획된 참여자는 ${a}명입니다.`,l>0?`서로를 참조한 상호작용 증거가 ${l}건 있습니다.`:"서로를 참조한 명시적 상호작용 증거가 아직 없습니다.",c>0?`도구·산출물·체크포인트 증거가 ${c}건 있습니다.`:"도구·산출물·체크포인트 증거가 거의 없습니다.",d>0?`CPv2 backing trace가 ${d}건 있어 실행 흔적은 남아 있습니다.`:"관리형 backing trace는 아직 없습니다."];return n==="proven"&&e==="insufficient"?[p[0]??"","왜 이렇게 판정됐나: 과거 proof는 proved였지만, 현재 보이는 live evidence는 부족해서 partial로 완화했습니다.","다음 보강 포인트: 최근 응답 턴이나 도구 호출을 다시 남겨 historical proof를 현재 상태와 연결해야 합니다."]:n==="proven"&&e==="partial"?[p[0]??"","왜 이렇게 판정됐나: historical proof는 강하지만, 현재 live evidence는 아직 partial 수준입니다.","다음 보강 포인트: 최근 상호작용과 실행 근거를 더 남기면 proven으로 회복할 수 있습니다."]:t==="partial"?[p[0]??"",o>0?`partial인 이유: 호출되었지만 응답하지 않은 참여자가 ${o}명 있습니다.`:l===0?"partial인 이유: 여러 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.":"partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.",d>0?"다음 보강 포인트: 응답 턴이나 도구 호출을 남기면 proof가 협업 수준으로 올라갑니다.":"다음 보강 포인트: 관리형 trace 또는 산출물 연결을 더 남기면 근거가 강해집니다."]:t==="proven"?[p[0]??"","결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.","다음 행동: raw evidence는 접어두고 결과 산출물과 다음 실행 결정만 확인하면 됩니다."]:[p[0]??"",o>0?`결론: 협업 시도는 있었지만 무응답 참여자가 ${o}명 있어 협업 증거로 인정하기 어렵습니다.`:"결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.",c>0?"다음 보강 포인트: 응답 턴과 도구 근거를 서로 연결해 남겨야 합니다.":"다음 보강 포인트: 참여자 간 턴, 도구 근거, 산출물 연결을 더 남겨야 합니다."]}function Q$(t){return t==="historical_only"?"historical only":t==="live_and_historical"?"live + historical":"live"}function Fl(t){return(t==null?void 0:t.mode)==="requested_not_found"?"bad":(t==null?void 0:t.mode)==="latest_auto_selected"?"warn":"ok"}function Z$(t){return(t==null?void 0:t.mode)==="requested_not_found"?"선택 실패":(t==null?void 0:t.mode)==="latest_auto_selected"?"자동 선택":(t==null?void 0:t.mode)==="explicit"?"명시 선택":"선택 없음"}function th(t){return t.activity_state==="acted"?(t.interaction_count??0)>0||(t.tool_evidence_count??0)>0?"ok":"warn":t.activity_state==="mentioned_only"?"warn":"bad"}function eh(t){return t.activity_state==="acted"?"실제 흔적":t.activity_state==="mentioned_only"?"호출만 됨":"계획만 됨"}function nh(t){if(t.activity_state==="acted")return`턴 ${t.turn_count??0} · spawn ${t.spawn_count??0} · 도구 근거 ${t.tool_evidence_count??0}`;if(t.activity_state==="mentioned_only"){const e=t.requested_by?`호출자 ${t.requested_by}`:"호출자 미상";return`호출 ${t.mention_count??0}회 · ${e}`}return"계획된 참여자이지만 아직 이벤트가 없습니다."}function Kl(t){return Array.isArray(t.tool_names)?t.tool_names:[]}function sh({selection:t,summary:e}){if(!t||t.mode==="explicit")return null;const n=t.mode==="latest_auto_selected"&&(e==null?void 0:e.historical_verdict)==="proven"&&(e==null?void 0:e.live_verdict)!=="proven";return i`
    <div class="command-guide-card ${Fl(t)}">
      <div class="command-guide-head">
        <strong>${Z$(t)}</strong>
        <span class="command-chip ${Fl(t)}">${t.mode??"none"}</span>
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
  `}function ah({item:t}){return i`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${t.summary??t.event_type??"도구 근거"}</strong>
          <div class="command-meta-line">
            <span>${t.actor??"시스템"}</span>
            <span>${t.event_type??"event"}</span>
          </div>
        </div>
        <span class="command-chip">${Q(t.timestamp??null)}</span>
      </div>
      ${Kl(t).length>0?i`<div class="semantic-tag-row">
            ${Kl(t).map(e=>i`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
    </article>
  `}function ih(t){const e=new Map;for(const n of t){const s=[n.timestamp??"",n.event_type??"",n.actor??"",n.summary??""].join("|"),a=n.source??"unknown",o=e.get(s);if(o){o.sources.includes(a)||o.sources.push(a),!o.operation_id&&n.operation_id&&(o.operation_id=n.operation_id);continue}e.set(s,{...n,sources:[a]})}return[...e.values()]}function oh(t){return t.sources.length===2?"세션 + 지휘":t.sources.length===1?t.sources[0]==="unknown"?"출처 미상":t.sources[0]??"출처":t.sources.join(" + ")}function rh(t){const e=[];for(const[n,s]of Object.entries(t))if(s!=null){if(typeof s=="string"){if(s.trim()==="")continue;e.push({label:n,value:s});continue}if(typeof s=="number"||typeof s=="boolean"){e.push({label:n,value:String(s)});continue}}return e}function lh(t){const e=jt(t),n=jt(e.traces),s=Array.isArray(n.events)?n.events:[],a=jt(e.detachments),o=Array.isArray(a.detachments)?a.detachments:[],l=jt(o[0]),c=jt(l.detachment),d=jt(l.operation),p=jt(e.summary),m=jt(p.operations),f=jt(m.summary);return[{label:"작전",value:Fs(e.operation_id)??"없음"},{label:"분견대",value:Fs(e.detachment_id)??"없음"},{label:"트레이스 이벤트",value:`${s.length}`},{label:"분견대 상태",value:Fs(c.status)??"없음"},{label:"작전 단계",value:Fs(d.stage)??"없음"},{label:"활성 작전",value:`${G$(f.active)??0}`}]}function ch({item:t}){return i`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${t.summary??t.event_type??"이벤트"}</strong>
          <div class="command-meta-line">
            <span>${oh(t)}</span>
            <span>${t.event_type??"이벤트"}</span>
            <span>${t.actor??"시스템"}</span>
          </div>
        </div>
        <span class="command-chip">${Q(t.timestamp)}</span>
      </div>
      ${t.sources.length>1?i`<div class="semantic-tag-row">
            ${t.sources.map(e=>i`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
    </article>
  `}function dh({item:t}){const e=t.recent_output_preview??null,n=t.recent_input_preview??null,s=t.recent_event_summary??null,a=t.recent_request_preview??null,o=t.last_active_at??t.recent_request_at??null;return i`
    <article class="mission-activity-row proof-actor-row">
      <div class="mission-activity-head">
        <div>
          <strong>${t.actor}</strong>
          <div class="mission-activity-meta">
            <span>${t.role??"참여자"}</span>
            <span>${o?Q(o):"기록 없음"}</span>
          </div>
        </div>
        <span class="command-chip ${th(t)}">
          ${eh(t)}
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>${nh(t)}</span>
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
      ${on(t.recent_tool_names).length>0?i`<div class="semantic-tag-row">
            ${on(t.recent_tool_names).map(l=>i`<span class="semantic-tag">${l}</span>`)}
          </div>`:null}
    </article>
  `}function uh({item:t}){return i`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${t.kind}</strong>
          <div class="command-meta-line">
            <span>${J$(t.path)}</span>
          </div>
        </div>
        <span class="command-chip ${t.exists?"ok":"warn"}">${t.exists?"존재함":"없음"}</span>
      </div>
    </article>
  `}function Bl({title:t,rows:e}){return e.length===0?null:i`
    <div class="proof-kv-block">
      ${t?i`<strong>${t}</strong>`:null}
      <div class="proof-kv-grid">
        ${e.map(n=>i`
          <span>${n.label}</span>
          <strong>${n.value}</strong>
        `)}
      </div>
    </div>
  `}function ph(){var G,P,A;const t=K.value.params,e=t.session_id??null,n=t.operation_id??null;tt(()=>{Sd(e,n)},[e,n]);const s=xd.value;if(So.value&&!s)return i`<section class="dashboard-panel"><div class="loading-indicator">근거 화면 불러오는 중…</div></section>`;if(nn.value&&!s)return i`<section class="dashboard-panel"><div class="error-card">${nn.value}</div></section>`;const a=s==null?void 0:s.summary,o=(s==null?void 0:s.selection)??null,l=on(s==null?void 0:s.actor_contributions),c=on(s==null?void 0:s.artifacts),d=on(s==null?void 0:s.tool_evidence),p=(s==null?void 0:s.proof_verdict)??"insufficient",m=(a==null?void 0:a.live_verdict)??p,f=(a==null?void 0:a.historical_verdict)??null,h=(a==null?void 0:a.verdict_basis)??"live",y=(s==null?void 0:s.cp_backing_evidence)??null,C=Array.isArray((G=y==null?void 0:y.traces)==null?void 0:G.events)?((A=(P=y.traces)==null?void 0:P.events)==null?void 0:A.length)??0:0,_=(a==null?void 0:a.actors_count)??l.length,k=(a==null?void 0:a.planned_actor_count)??l.length,g=(a==null?void 0:a.unanswered_actor_count)??l.filter(z=>z.activity_state!=="acted"&&(z.mention_count??0)>0).length,b=(a==null?void 0:a.mentioned_actor_count)??l.filter(z=>(z.mention_count??0)>0).length,R=(a==null?void 0:a.interaction_count)??0,L=(a==null?void 0:a.evidence_count)??0,S=ih(on(s==null?void 0:s.timeline)),M=rh(jt(s==null?void 0:s.goal_binding)),I=lh(y),D=c.filter(z=>z.exists).length,J=c.length-D,et=X$(p,m,f,_,k,g,R,L,C);return i`
    <section class="dashboard-panel mission-view">
      <${vt} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>근거</h2>
          <p>이 세션이 실제로 여러 참여자의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${zn(p)}">${V$(p)}</span>
          ${s!=null&&s.session_id?i`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?i`<span class="command-chip">${Q(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${nn.value?i`<div class="error-card">${nn.value}</div>`:null}

      <${sh} selection=${o} summary=${a??null} />

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${zn(p)}">
          <span>판정</span>
          <strong>${Y$(p)}</strong>
          <small>${(a==null?void 0:a.detail)??"협업 증거를 verdict로 요약합니다."}</small>
        </div>
        <div class="summary-stat-card ${zn(m)}">
          <span>Live 판정</span>
          <strong>${m}</strong>
          <small>${Q$(h)} 기준 최종 판정에 반영</small>
        </div>
        <div class="summary-stat-card ${zn(f??"insufficient")}">
          <span>Historical proof</span>
          <strong>${f??"none"}</strong>
          <small>persisted proof 문서 기준</small>
        </div>
        <div class="summary-stat-card">
          <span>실제 흔적</span>
          <strong>${_}</strong>
          <small>이벤트를 남긴 actor 수</small>
        </div>
        <div class="summary-stat-card ${k>_?"warn":"ok"}">
          <span>계획된 참여자</span>
          <strong>${k}</strong>
          <small>${b>0?`${b}명 호출됨`:"호출 기록 없음"}</small>
        </div>
        <div class="summary-stat-card ${g>0?"warn":"ok"}">
          <span>무응답</span>
          <strong>${g}</strong>
          <small>${g>0?"호출됐지만 응답 근거 없음":"무응답 참여자 없음"}</small>
        </div>
        <div class="summary-stat-card ${R>0?"ok":"warn"}">
          <span>직접 상호작용</span>
          <strong>${R}</strong>
          <small>참여자 간 직접 연결 근거</small>
        </div>
        <div class="summary-stat-card ${L>0?"ok":"warn"}">
          <span>근거</span>
          <strong>${L}</strong>
          <small>도구 / 산출물 / 체크포인트</small>
        </div>
        <div class="summary-stat-card ${C>0?"ok":"warn"}">
          <span>CP 트레이스</span>
          <strong>${C}</strong>
          <small>관리형 backing 이벤트</small>
        </div>
        <div class="summary-stat-card ${J===0&&c.length>0?"ok":"warn"}">
          <span>산출물</span>
          <strong>${D}/${c.length}</strong>
          <small>${J>0?`${J}개 누락`:"전부 존재함"}</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${E} title="3줄 근거 요약" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, 왜 아직 부족한지, 다음에 무엇을 남겨야 하는지만 먼저 봅니다.</p>
          </div>
          <div class="proof-summary-stack">
            ${et.map((z,V)=>i`
              <article class="proof-summary-block ${V===1&&p!=="proven"?zn(p):""}">
                <strong>${V===0?"지금 결론":V===1?"왜 이렇게 판정됐나":"다음 보강 포인트"}</strong>
                <span>${z}</span>
              </article>
            `)}
          </div>
        <//>

        <${E} title="목표 연결" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 화면이 어떤 세션과 목표를 기준으로 그려졌는지 먼저 고정합니다.</p>
          </div>
          <${Bl} rows=${M} />
          <details class="mission-card-disclosure compact">
            <summary>원본 목표 연결 JSON</summary>
            <pre class="command-json-block">${ls((s==null?void 0:s.goal_binding)??{})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${E} title="협업 타임라인" class="mission-list-card" semanticId="proof.timeline">
          <div class="mission-section-head">
            <h3>협업 타임라인</h3>
            <p>team-session과 command-plane에서 같은 사건이 보이면 한 줄로 묶어 읽습니다.</p>
          </div>
          <div class="mission-list-stack">
            ${S.length>0?S.slice(0,18).map(z=>i`<${ch} key=${z.id} item=${z} />`):i`<div class="empty-state">표시할 타임라인 근거가 없습니다.</div>`}
          </div>
        <//>

        <${E} title="참여 흔적" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>실제 흔적, 호출만 된 참여자, 계획만 된 참여자를 구분해서 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${l.length>0?l.map(z=>i`<${dh} key=${z.actor} item=${z} />`):i`<div class="empty-state">표시할 참여 흔적이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${E} title="도구 근거" class="mission-list-card" semanticId="proof.tool_evidence">
          <div class="mission-section-head">
            <h3>어떤 도구를 언제 썼는가</h3>
            <p>숫자만 보여주지 말고, 최근 도구 호출 근거를 직접 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${d.length>0?d.map((z,V)=>i`<${ah} key=${`${z.actor??"system"}-${V}`} item=${z} />`):i`<div class="empty-state">기록된 tool evidence가 없습니다.</div>`}
          </div>
        <//>

        <${E} title="실행 근거" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>작전, 분견대, 트레이스 수만 먼저 보고, 원본 CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${Bl} rows=${I} />
          <details class="mission-card-disclosure compact">
            <summary>원본 CPv2 backing JSON</summary>
            <pre class="command-json-block">${ls(y??{})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${E} title="산출물" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>어떤 파일 산출물이 남았나</h3>
            <p>proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${c.length>0?c.map(z=>i`<${uh} key=${z.path} item=${z} />`):i`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function Ei(t){const e=(t??"").trim().toLowerCase();return e==="bad"||e==="critical"||e==="offline"?"bad":e==="warn"||e==="paused"||e==="blocked"?"warn":"ok"}function mh(){var n;const t=(n=or.value)==null?void 0:n.focus;if(!(t!=null&&t.suggested_tab))return;const e=t.suggested_params??{};if(t.suggested_tab==="intervene"){at("intervene",e);return}at("command",{...t.suggested_surface?{surface:t.suggested_surface}:{},...e})}function Sr(){var d,p,m,f,h,y;const t=or.value;if(!t)return bo.value?i`<section class="room-truth-strip room-truth-strip-loading">room truth 불러오는 중...</section>`:Ta.value?i`<section class="room-truth-strip room-truth-strip-error">${Ta.value}</section>`:null;const e=t.room.status,n=t.room.counts,s=(d=t.execution)==null?void 0:d.summary,a=(p=t.execution)==null?void 0:p.top_queue,o=t.command,l=t.operator,c=t.focus;return i`
    <section class="room-truth-strip">
      <article class="room-truth-card">
        <span class="room-truth-label">room truth</span>
        <strong>${(e==null?void 0:e.project)??"project"} · ${(e==null?void 0:e.room)??"default"}</strong>
        <p>${(n==null?void 0:n.agents)??0} agents · ${(n==null?void 0:n.tasks)??0} tasks · ${(n==null?void 0:n.keepers)??0} keepers</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${e!=null&&e.paused?"warn":"ok"}">${e!=null&&e.paused?"일시정지":"열림"}</span>
          <span class="command-chip">${(e==null?void 0:e.cluster)??"cluster:unknown"}</span>
          <${je} item=${{kind:t.room.provenance??"truth"}} />
        </div>
      </article>

      <article class="room-truth-card">
        <span class="room-truth-label">execution</span>
        <strong>세션 ${(s==null?void 0:s.active_sessions)??0} · 막힘 ${(s==null?void 0:s.blocked_sessions)??0}</strong>
        <p>${(a==null?void 0:a.summary)??"지금은 실행 대기열 최상단 항목이 없습니다."}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${Ei(((s==null?void 0:s.blocked_sessions)??0)>0?"warn":"ok")}">priority ${(s==null?void 0:s.priority_items)??0}</span>
          <${je} item=${{kind:((m=t.execution)==null?void 0:m.provenance)??"derived"}} />
        </div>
      </article>

      <article class="room-truth-card">
        <span class="room-truth-label">control</span>
        <strong>작전 ${(o==null?void 0:o.active_operations)??0} · 승인 ${(o==null?void 0:o.pending_approvals)??0}</strong>
        <p>alerts bad ${(o==null?void 0:o.bad_alerts)??0} / warn ${(o==null?void 0:o.warn_alerts)??0} · lanes ${(o==null?void 0:o.moving_lanes)??0}/${(o==null?void 0:o.active_lanes)??0}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${Ei(((o==null?void 0:o.bad_alerts)??0)>0?"bad":((o==null?void 0:o.warn_alerts)??0)>0||((o==null?void 0:o.pending_approvals)??0)>0?"warn":"ok")}">
            health ${(l==null?void 0:l.health)??"ok"}
          </span>
          <${je} item=${{kind:(o==null?void 0:o.provenance)??"truth"}} />
        </div>
      </article>

      <article class="room-truth-card room-truth-card-focus">
        <span class="room-truth-label">next focus</span>
        <strong>${(c==null?void 0:c.label)??"지금은 방 전체가 비교적 안정적입니다"}</strong>
        <p>${(c==null?void 0:c.reason)??((h=(f=l==null?void 0:l.attention_summary)==null?void 0:f.top_item)==null?void 0:h.summary)??(a==null?void 0:a.summary)??"다음 drill-down 대상이 아직 없습니다."}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${Ei((c==null?void 0:c.provenance)==="fallback"?"warn":"ok")}">${(c==null?void 0:c.source)??"steady"}</span>
          <${je} item=${{kind:(c==null?void 0:c.provenance)??((y=l==null?void 0:l.recommendation_summary)==null?void 0:y.provenance)??"derived"}} />
        </div>
        ${c!=null&&c.suggested_tab?i`
              <div class="room-truth-actions">
                <button class="control-btn ghost" onClick=${mh}>
                  ${c.suggested_tab==="intervene"?"개입면 열기":"지휘면 열기"}
                </button>
              </div>
            `:null}
      </article>
    </section>
  `}function _h(){const t=Rs(K.value);return t?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${ui(t.action_type)}</span>
        <span class="command-chip">${gr(t)}</span>
        <span class="command-chip">${rg(K.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?i`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function vh(){const t=X.value,e=P$[t],n=j$(t);return i`
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
  `}function Ks({label:t,value:e,subtext:n,percent:s,color:a}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${R$(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(Es(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function Bs({label:t,value:e,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${w(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${w(a)}" style=${`width: ${Math.max(8,Math.round(Es(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function fh(){var J,et,G,P;const t=zs(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,o=t==null?void 0:t.alerts.summary,l=(J=t==null?void 0:t.swarm_status)==null?void 0:J.overview,c=t==null?void 0:t.swarm_proof,d=t==null?void 0:t.operations.microarch,p=(e==null?void 0:e.managed_unit_count)??0,m=(e==null?void 0:e.total_units)??0,f=(n==null?void 0:n.active)??0,h=(s==null?void 0:s.active)??0,y=(l==null?void 0:l.moving_lanes)??0,C=(l==null?void 0:l.active_lanes)??0,_=(c==null?void 0:c.workers.done)??0,k=(c==null?void 0:c.workers.expected)??0,g=(o==null?void 0:o.bad)??0,b=(o==null?void 0:o.warn)??0,R=(a==null?void 0:a.pending)??0,L=(a==null?void 0:a.total)??0,S=f+h,M=((et=d==null?void 0:d.cache)==null?void 0:et.l1_hit_rate)??((P=(G=d==null?void 0:d.signals)==null?void 0:G.cache_contention)==null?void 0:P.l1_hit_rate)??0,I=f>0||h>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",D=f>0||y>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${I}</h3>
        <p>${D}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${w(f>0?"ok":"warn")}">활성 작전 ${f}</span>
          <span class="command-chip ${w(y>0?"ok":(C>0,"warn"))}">이동 레인 ${y}/${Math.max(C,y)}</span>
          <span class="command-chip ${w(g>0?"bad":b>0?"warn":"ok")}">치명 알림 ${g}</span>
          <span class="command-chip ${w(R>0?"warn":"ok")}">승인 대기 ${R}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Ks}
          label="관리 단위 범위"
          value=${`${p}/${Math.max(m,p)}`}
          subtext=${m>0?`${m-p}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${Ie(p,Math.max(m,p))}
          color="#67e8f9"
        />
        <${Ks}
          label="실행 열도"
          value=${String(S)}
          subtext=${`${f}개 작전 + ${h}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${Ie(S,Math.max(p,S||1))}
          color="#4ade80"
        />
        <${Ks}
          label="스웜 이동감"
          value=${`${y}/${Math.max(C,y)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${Q(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${Ie(y,Math.max(C,y||1))}
          color="#fbbf24"
        />
        <${Ks}
          label="증거 수집률"
          value=${`${_}/${Math.max(k,_)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${Ie(_,Math.max(k,_||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${Bs}
        label="승인 대기열"
        value=${`${R}건 대기`}
        detail=${`현재 정책 창에서 ${L}개 결정을 추적 중입니다`}
        percent=${Ie(R,Math.max(L,R||1))}
        tone=${R>0?"warn":"ok"}
      />
      <${Bs}
        label="알림 압력"
        value=${`치명 ${g} / 주의 ${b}`}
        detail=${g>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${Ie(g*2+b,Math.max((g+b)*2,1))}
        tone=${g>0?"bad":b>0?"warn":"ok"}
      />
      <${Bs}
        label="디스패치 점유"
          value=${`${h}개 가동`}
        detail=${p>0?`${p}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${Ie(h,Math.max(p,h||1))}
        tone=${h>0?"ok":"warn"}
      />
      <${Bs}
        label="캐시 신뢰도"
        value=${M?Rn(M):"정보 없음"}
        detail=${M?"microarch 캐시 텔레메트리에서 집계한 L1 적중률":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Es((M??0)*100)}
        tone=${M>=.75?"ok":M>=.4?"warn":"bad"}
      />
    </div>
  `}function gh(){var h,y,C,_,k;const t=zs(),e=Is.value,n=Rs(K.value),s=O$(n),a=t==null?void 0:t.topology.summary,o=t==null?void 0:t.operations.summary,l=(h=t==null?void 0:t.swarm_status)==null?void 0:h.overview,c=t==null?void 0:t.operations.microarch,d=t==null?void 0:t.decisions.summary,p=t==null?void 0:t.alerts.summary,m=(y=c==null?void 0:c.signals)==null?void 0:y.issue_pressure,f=c==null?void 0:c.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((C=t==null?void 0:t.detachments.summary)==null?void 0:C.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(d==null?void 0:d.pending)??0}</strong><small>${(d==null?void 0:d.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(p==null?void 0:p.bad)??0}</strong><small>${(p==null?void 0:p.warn)??0}건 주의</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((_=e==null?void 0:e.summary)==null?void 0:_.active_chains)??0}</strong><small>${((k=e==null?void 0:e.summary)==null?void 0:k.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${Q(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(m==null?void 0:m.pending_ops)??0}</strong><small>${(f==null?void 0:f.l1_hit_rate)!=null?`${Rn(f.l1_hit_rate)} L1 적중`:"캐시 데이터 없음"} · ${(m==null?void 0:m.tone)??"정보 없음"}</small></div>
    </div>
  `}function $h(){var J,et,G,P,A,z,V,yt,oe;const t=zs(),e=Jt.value,n=dt.value,s=ru(),a=s?Gt.value.find(W=>W.name===s)??null:null,o=s?pe.value.filter(W=>W.assignee===s&&F$(W)):[],l=((J=t==null?void 0:t.operations.summary)==null?void 0:J.active)??0,c=((et=t==null?void 0:t.detachments.summary)==null?void 0:et.total)??0,d=((G=t==null?void 0:t.decisions.summary)==null?void 0:G.pending)??0,p=e==null?void 0:e.detachments.detachments.find(W=>{const ft=W.detachment.heartbeat_deadline,xe=ft?Date.parse(ft):Number.NaN;return W.detachment.status==="stalled"||!Number.isNaN(xe)&&xe<=Date.now()}),m=e==null?void 0:e.alerts.alerts.find(W=>W.severity==="bad"),f=!!(n!=null&&n.room||n!=null&&n.project),h=(a==null?void 0:a.current_task)??null,y=q$(a==null?void 0:a.last_seen),C=y!=null?y<=120:null,_=[f?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:pe.value.length>0?"masc_claim":"masc_add_task"}:h?C===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${h} 이지만 heartbeat가 stale 합니다 (${y}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${h}${y!=null?` · 마지막 활동 ${y}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((P=t.topology.summary)==null?void 0:P.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((A=t.topology.summary)==null?void 0:A.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((z=t.topology.summary)==null?void 0:z.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},d>0?{title:"디스패치 준비도",tone:"warn",detail:`${d}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:p||m?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${p?` · detachment ${p.detachment.detachment_id} 가 stalled 상태입니다`:""}${m?` · alert ${m.title??m.alert_id}`:""}${!e&&!p&&!m?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:d>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],k=f?!s||!a?"masc_join":o.length===0?pe.value.length>0?"masc_claim":"masc_add_task":h?C===!1?"masc_heartbeat":!t||(((V=t.topology.summary)==null?void 0:V.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":d>0?"masc_policy_approve":l>0&&c===0||p||m?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",g=K$(k),R=B$(k==="masc_set_room"?["repo-root-room"]:k==="masc_plan_set_task"?["claimed-not-current"]:k==="masc_heartbeat"?["heartbeat-stale"]:k==="masc_dispatch_tick"?["no-detachments"]:k==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),L=Li("room_task_hygiene"),S=Li("cpv2_benchmark"),M=Li("supervisor_session"),I=((yt=Ts.value)==null?void 0:yt.docs)??[],D=[L,S,M].filter(W=>W!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${B} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(g==null?void 0:g.title)??k}</strong>
            <span class="command-chip ok">${k}</span>
          </div>
          <p>${(g==null?void 0:g.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(oe=g==null?void 0:g.success_signals)!=null&&oe.length?i`<div class="command-tag-row">
                ${g.success_signals.map(W=>i`<span class="command-tag ok">${W}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${_.map(W=>i`
            <article class="command-readiness-row ${w(W.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${W.title}</strong>
                  <span class="command-chip ${w(W.tone)}">${W.tone}</span>
                </div>
                <p>${W.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${W.tool}</div>
            </article>
          `)}
        </div>

        ${R.length>0?i`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${R.length}</span>
                </div>
                <div class="command-guide-list">
                  ${R.map(W=>i`
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
          <${B} panelId="command.summary" compact=${!0} />
        </div>
        ${Ao.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:ja.value?i`<div class="empty-state error">${ja.value}</div>`:i`
                <div class="command-path-grid">
                  ${D.map(W=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${W.title}</strong>
                        <span class="command-chip">${W.id}</span>
                      </div>
                      <p>${W.summary}</p>
                      <div class="command-card-sub">${W.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${W.steps.slice(0,4).map(ft=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${ft.tool}</span>
                            <span>${ft.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${I.length>0?i`<div class="command-doc-links">
                      ${I.map(W=>i`<span class="command-tag">${W.title}: ${W.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function hh(){return i`
    <${fh} />
    <${gh} />
    <${$h} />
  `}function yh(){return Pa.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:wa.value?i`<div class="empty-state error">${wa.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}const Re=$(null),Us=$("compact"),le=$({zoom:1,panX:0,panY:0}),Pi=$(!1),Hs=$(!1),qn={width:1280,height:760},du=.42,uu=1.9;function ma(t,e,n){return Math.max(e,Math.min(n,t))}function Cr(t,e){const n=t==null?void 0:t.trim();return n?n.length<=e?n:`${n.slice(0,Math.max(1,e-1))}…`:null}function bh(t){return t==="compact"?"집약":"균형"}function Ul(t){switch((t??"").trim().toLowerCase()){case"room":return"룸";case"session":return"세션";case"operation":return"작전";case"detachment":return"분견대";case"lane":return"레인";case"worker":return"워커";case"keeper":return"키퍼";default:return(t==null?void 0:t.trim())||"노드"}}function Ws(t,e,n){if(t<=0)return[];if(t===1)return[Math.round((e+n)/2)];const s=(n-e)/(t-1);return Array.from({length:t},(a,o)=>Math.round(e+o*s))}function kh(t,e){const n=new Map;for(const s of t){const a=e(s),o=n.get(a)??[];o.push(s),n.set(a,o)}return n}function pu(t){return t==="compact"?{room:{x:660,y:108},sessions:{y:228,min:220,max:1110},operations:{y:338,min:260,max:1050},detachments:{y:430,min:310,max:1e3},lanes:{y:540,min:220,max:1110},worker:{perRow:5,xSpacing:60,ySpacing:52,laneOffsetY:76,freeBaseY:662},keeper:{startX:1180,colSpacing:92,rowSpacing:90,startY:176,columns:2},signalRadius:116}:{room:{x:700,y:112},sessions:{y:236,min:240,max:1140},operations:{y:356,min:300,max:1080},detachments:{y:454,min:340,max:1030},lanes:{y:584,min:230,max:1110},worker:{perRow:4,xSpacing:72,ySpacing:60,laneOffsetY:82,freeBaseY:720},keeper:{startX:1210,colSpacing:108,rowSpacing:102,startY:188,columns:2},signalRadius:132}}function mu(t,e){return t.kind==="room"?e==="compact"?{width:138,height:138,radius:68}:{width:156,height:156,radius:76}:t.kind==="worker"?e==="compact"?{width:70,height:36,radius:18}:{width:84,height:44,radius:22}:t.kind==="lane"?e==="compact"?{width:156,height:48,radius:15}:{width:176,height:56,radius:17}:t.kind==="keeper"?e==="compact"?{width:118,height:50,radius:22}:{width:132,height:60,radius:24}:t.kind==="session"?e==="compact"?{width:182,height:58,radius:17}:{width:202,height:68,radius:18}:e==="compact"?{width:176,height:58,radius:16}:{width:196,height:68,radius:18}}function xh(t,e){const n=t.kind==="worker"?e==="compact"?10:14:t.kind==="keeper"?e==="compact"?12:16:t.kind==="lane"?e==="compact"?16:22:e==="compact"?18:26;return Cr(t.label,n)??t.label}function Sh(t,e){if(e==="compact"&&(t.kind==="worker"||t.kind==="keeper"||t.kind==="detachment"))return null;const n=t.kind==="session"?e==="compact"?20:28:e==="compact"?14:24;return Cr(t.subtitle,n)}function Ch(t,e){return e==="compact"&&t.kind!=="session"&&t.kind!=="operation"?null:Cr(t.status,e==="compact"?10:14)}function Ah(t,e){const n=pu(e),s=new Map,a=t.nodes,o=a.find(_=>_.kind==="room")??null,l=a.filter(_=>_.kind==="session"),c=a.filter(_=>_.kind==="operation"),d=a.filter(_=>_.kind==="detachment"),p=a.filter(_=>_.kind==="lane"),m=a.filter(_=>_.kind==="worker"),f=a.filter(_=>_.kind==="keeper");o&&s.set(o.id,{x:n.room.x,y:n.room.y}),Ws(l.length,n.sessions.min,n.sessions.max).forEach((_,k)=>{const g=l[k];g&&s.set(g.id,{x:_,y:n.sessions.y})}),Ws(c.length,n.operations.min,n.operations.max).forEach((_,k)=>{const g=c[k];g&&s.set(g.id,{x:_,y:n.operations.y})}),Ws(d.length,n.detachments.min,n.detachments.max).forEach((_,k)=>{const g=d[k];g&&s.set(g.id,{x:_,y:n.detachments.y})}),Ws(p.length,n.lanes.min,n.lanes.max).forEach((_,k)=>{const g=p[k];g&&s.set(g.id,{x:_,y:n.lanes.y})});const h=new Map(p.map(_=>{const k=s.get(_.id);return k?[_.id,k.x]:null}).filter(_=>_!==null)),y=kh(m,_=>_.lane_id?`lane:${_.lane_id}`:_.parent_id?_.parent_id:"free");let C=0;for(const[_,k]of y){let g=h.get(_.replace(/^lane:/,""));if(g==null){const R=s.get(_);g=R==null?void 0:R.x}g==null&&(g=260+C%4*180,C+=1);const b=Math.max(1,Math.ceil(k.length/n.worker.perRow));for(let R=0;R<b;R+=1){const L=k.slice(R*n.worker.perRow,(R+1)*n.worker.perRow),S=(L.length-1)*n.worker.xSpacing,M=g-S/2;L.forEach((I,D)=>{var J;s.set(I.id,{x:Math.round(M+D*n.worker.xSpacing),y:_==="free"?n.worker.freeBaseY+R*n.worker.ySpacing:(((J=s.get(_.replace(/^lane:/,"")))==null?void 0:J.y)??n.lanes.y)+n.worker.laneOffsetY+R*n.worker.ySpacing})})}}return f.forEach((_,k)=>{const g=k%n.keeper.columns,b=Math.floor(k/n.keeper.columns);s.set(_.id,{x:n.keeper.startX+g*n.keeper.colSpacing,y:n.keeper.startY+b*n.keeper.rowSpacing})}),s}function Th(t,e,n){if(!e||t.signals.length===0)return[];const s=pu(n);return t.signals.slice(0,6).map((a,o)=>{const l=(-130+o*36)*(Math.PI/180);return{signalNode:a,x:Math.round(e.x+Math.cos(l)*s.signalRadius),y:Math.round(e.y+Math.sin(l)*s.signalRadius)}})}function Ih(t,e,n,s){let a=Number.POSITIVE_INFINITY,o=Number.NEGATIVE_INFINITY,l=Number.POSITIVE_INFINITY,c=Number.NEGATIVE_INFINITY;for(const d of t.nodes){const p=e.get(d.id);if(!p)continue;const m=mu(d,s);d.kind==="room"?(a=Math.min(a,p.x-m.radius),o=Math.max(o,p.x+m.radius),l=Math.min(l,p.y-m.radius),c=Math.max(c,p.y+m.radius)):(a=Math.min(a,p.x-m.width/2),o=Math.max(o,p.x+m.width/2),l=Math.min(l,p.y-m.height/2),c=Math.max(c,p.y+m.height/2))}for(const d of n)a=Math.min(a,d.x-20),o=Math.max(o,d.x+20),l=Math.min(l,d.y-20),c=Math.max(c,d.y+20);return!Number.isFinite(a)||!Number.isFinite(o)||!Number.isFinite(l)||!Number.isFinite(c)?{minX:0,minY:0,maxX:qn.width,maxY:qn.height,width:qn.width,height:qn.height}:{minX:a,minY:l,maxX:o,maxY:c,width:Math.max(1,o-a),height:Math.max(1,c-l)}}function Hl(t,e,n){const s=n==="compact"?48:72,a=Math.max(360,e.width-s*2),o=Math.max(280,e.height-s*2),l=ma(Math.min(a/Math.max(t.width,1),o/Math.max(t.height,1)),du,uu),c=t.minX+t.width/2,d=t.minY+t.height/2;return{zoom:l,panX:e.width/2-c*l,panY:e.height/2-d*l}}function Rh(t,e){const n=(t.x+e.x)/2,s=e.y>=t.y?32:-32;return`M ${t.x} ${t.y} C ${n} ${t.y+s}, ${n} ${e.y-s}, ${e.x} ${e.y}`}function Wl(t,e,n){if(t==="command"){if(e){Kt(e),at("command",{...Ps(e),...n});return}at("command",n);return}if(t==="intervene"){at("intervene",n);return}at("command",n)}function Mh({signalNodes:t,roomPoint:e,onSelect:n}){return!e||t.length===0?null:i`
    ${t.map(({signalNode:s,x:a,y:o})=>i`
      <g
        key=${s.id}
        data-orchestra-signal="true"
        class=${`orchestra-signal-node ${w(s.tone)}`}
        onClick=${()=>n(s.id)}
      >
        <title>${s.label}${s.detail?` — ${s.detail}`:""}</title>
        <line x1=${e.x} y1=${e.y} x2=${a} y2=${o} class="orchestra-signal-link" />
        <circle cx=${a} cy=${o} r="16" class="orchestra-signal-dot" />
        <text x=${a} y=${o+4} text-anchor="middle" class="orchestra-signal-glyph">!</text>
      </g>
    `)}
  `}function Lh({edges:t,positions:e,selectedId:n}){return i`
    ${t.map(s=>{const a=e.get(s.source),o=e.get(s.target);if(!a||!o)return null;const l=n!=null&&(s.source===n||s.target===n);return i`
        <path
          key=${s.id}
          d=${Rh(a,o)}
          class=${`orchestra-edge ${w(s.tone)} ${s.animated?"animated":""} ${l?"active":""}`}
        />
      `})}
  `}function Eh({orchestra:t,positions:e,density:n,selectedId:s,onSelect:a}){var l;const o=((l=t.focus)==null?void 0:l.target_kind)==="node"?t.focus.target_id:null;return i`
    ${t.nodes.map(c=>{const d=e.get(c.id);if(!d)return null;const p=mu(c,n),m=c.id===s,f=c.id===o,h=c.visual_class??c.kind,y=xh(c,n),C=Sh(c,n),_=Ch(c,n);if(c.kind==="room")return i`
          <g
            key=${c.id}
            data-orchestra-node="true"
            class=${`orchestra-node room ${w(c.tone)} ${m?"selected":""} ${f?"focused":""}`}
            onClick=${()=>a(c.id)}
          >
            <title>${c.label}</title>
            <circle cx=${d.x} cy=${d.y} r=${p.radius} class="orchestra-room-ring outer" />
            <circle cx=${d.x} cy=${d.y} r=${p.radius-16} class="orchestra-room-ring inner" />
            <text x=${d.x} y=${d.y-10} text-anchor="middle" class="orchestra-room-glyph">${c.glyph??"◎"}</text>
            <text x=${d.x} y=${d.y+22} text-anchor="middle" class="orchestra-room-label">${y}</text>
          </g>
        `;const k=d.x-p.width/2,g=d.y-p.height/2;return i`
        <g
          key=${c.id}
          data-orchestra-node="true"
          class=${`orchestra-node ${h} ${w(c.tone)} ${m?"selected":""} ${f?"focused":""}`}
          onClick=${()=>a(c.id)}
        >
          <title>${c.label}${c.subtitle?` — ${c.subtitle}`:""}${c.status?` (${c.status})`:""}</title>
          <rect x=${k} y=${g} width=${p.width} height=${p.height} rx=${p.radius} class="orchestra-node-body" />
          <text x=${k+16} y=${g+24} class="orchestra-node-glyph">${c.glyph??"•"}</text>
          <text x=${k+38} y=${g+24} class="orchestra-node-label">${y}</text>
          ${C?i`<text x=${k+38} y=${g+42} class="orchestra-node-subtitle">${C}</text>`:null}
          ${_?i`<text x=${k+p.width-10} y=${g+18} text-anchor="end" class="orchestra-node-status">${_}</text>`:null}
        </g>
      `})}
  `}function _u(t){var s,a;const e=Re.value;if(e){const o=t.nodes.find(c=>c.id===e);if(o)return{type:"node",value:o};const l=t.signals.find(c=>c.id===e);if(l)return{type:"signal",value:l}}if(((s=t.focus)==null?void 0:s.target_kind)==="node"){const o=t.nodes.find(l=>{var c;return l.id===((c=t.focus)==null?void 0:c.target_id)});if(o)return{type:"node",value:o}}if(((a=t.focus)==null?void 0:a.target_kind)==="signal"){const o=t.signals.find(l=>{var c;return l.id===((c=t.focus)==null?void 0:c.target_id)});if(o)return{type:"signal",value:o}}const n=t.nodes[0];return n?{type:"node",value:n}:null}function Ph({orchestra:t}){const e=_u(t);if(!e)return i`<aside class="orchestra-drawer card"><div class="empty-state">선택 가능한 대상이 아직 없습니다.</div></aside>`;if(e.type==="signal"){const o=e.value;return i`
      <aside class="orchestra-drawer card ${w(o.tone)}">
        <div class="card-title-row">
          <div class="card-title">${o.label}</div>
          <span class="command-chip ${w(o.tone)}">${Ul(o.kind)}</span>
        </div>
        <p>${o.detail??"세부 설명이 없습니다."}</p>
        ${o.suggested_surface?i`
              <div class="command-action-row">
                <button
                  class="control-btn"
                  onClick=${()=>Wl("command",o.suggested_surface,o.suggested_params??{})}
                >
                  추천 화면 열기
                </button>
              </div>
            `:null}
      </aside>
    `}const n=e.value,s=t.signals.filter(o=>o.source_id===n.id||o.target_id===n.id),a=t.edges.filter(o=>o.source===n.id||o.target===n.id);return i`
    <aside class="orchestra-drawer card ${w(n.tone)}">
      <div class="card-title-row">
        <div class="card-title">${n.label}</div>
        <span class="command-chip ${w(n.tone)}">${Ul(n.kind)}</span>
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
          ${s.map(o=>i`<span class="command-chip ${w(o.tone)}">${o.label}</span>`)}
        </div>
      `:null}
      <div class="command-card-sub">연결 ${a.length}개 · 근거 ${n.provenance}</div>
      ${n.link_tab&&(n.link_surface||Object.keys(n.link_params??{}).length>0)?i`
            <div class="command-action-row">
              <button
                class="control-btn"
                onClick=${()=>Wl(n.link_tab??"command",n.link_surface,n.link_params??{})}
              >
                이 화면 열기
              </button>
            </div>
          `:null}
    </aside>
  `}function zh(){var D,J,et,G;const t=cr.value,e=ee(null),n=ee(null),s=ee(""),[a,o]=Ke(qn);if(tt(()=>{const P=e.current;if(!P)return;const A=()=>{const V=P.getBoundingClientRect();V.width<=0||V.height<=0||o({width:Math.max(640,Math.round(V.width)),height:Math.max(480,Math.round(V.height))})};if(A(),typeof ResizeObserver>"u")return window.addEventListener("resize",A),()=>window.removeEventListener("resize",A);const z=new ResizeObserver(()=>A());return z.observe(P),()=>z.disconnect()},[]),To.value&&!t)return i`<section class="card command-section"><div class="empty-state">오케스트라 맵 불러오는 중…</div></section>`;if(qa.value)return i`<section class="card command-section"><div class="empty-state error">${qa.value}</div></section>`;if(!t)return i`<section class="card command-section"><div class="empty-state">오케스트라 맵 데이터가 아직 없습니다.</div></section>`;const l=Us.value,c=Ah(t,l),d=t.nodes.find(P=>P.kind==="room")??null,p=d?c.get(d.id)??null:null,m=Th(t,p,l),f=Ih(t,c,m,l),h=_u(t),y=(h==null?void 0:h.value.id)??null,C=`${l}:${a.width}x${a.height}:${t.nodes.length}:${t.edges.length}:${t.signals.length}`,_=(P,A)=>{le.value=P,Hs.value=A},k=()=>{_(Hl(f,a,l),!1)},g=()=>{if(Re.value=null,l!=="compact"){Us.value="compact",Hs.value=!1;return}k()};tt(()=>{y&&!t.nodes.some(P=>P.id===y)&&!t.signals.some(P=>P.id===y)&&(Re.value=null)},[C,y,t]),tt(()=>{(!Hs.value||s.current!==C)&&(_(Hl(f,a,l),!1),s.current=C)},[C]);const b=le.value,R=(P,A,z)=>{const V=le.value.zoom,yt=ma(V*z,du,uu);if(Math.abs(yt-V)<.001)return;const oe=(P-le.value.panX)/V,W=(A-le.value.panY)/V;_({zoom:yt,panX:P-oe*yt,panY:A-W*yt},!0)},L=P=>{P.preventDefault();const A=e.current;if(!A)return;const z=A.getBoundingClientRect(),V=ma(P.clientX-z.left,0,z.width),yt=ma(P.clientY-z.top,0,z.height);R(V,yt,P.deltaY<0?1.1:.92)},S=P=>{var V;const A=P.target;if(!(A instanceof Element)||!A.closest('[data-orchestra-background="true"]'))return;const z=P.currentTarget;z&&(n.current={pointerId:P.pointerId,startX:P.clientX,startY:P.clientY,panX:le.value.panX,panY:le.value.panY},Pi.value=!0,Hs.value=!0,(V=z.setPointerCapture)==null||V.call(z,P.pointerId))},M=P=>{const A=n.current;!A||A.pointerId!==P.pointerId||_({zoom:le.value.zoom,panX:A.panX+(P.clientX-A.startX),panY:A.panY+(P.clientY-A.startY)},!0)},I=P=>{var z;if(!n.current)return;const A=P==null?void 0:P.currentTarget;A&&P&&((z=A.releasePointerCapture)==null||z.call(A,P.pointerId)),n.current=null,Pi.value=!1};return i`
    <section class="card command-section orchestra-surface">
      <div class="card-title-row">
        <div class="card-title">오케스트라 맵</div>
        <${B} panelId="command.orchestra" compact=${!0} />
      </div>
      <p class="command-card-sub">
        룸 전체를 한 장의 작전판으로 읽는 시각화입니다. 확대/이동으로 밀집 구간을 읽고, 노드를 눌러 상세 신호와 연결 대상을 확인합니다.
      </p>

      <div class="orchestra-toolbar">
        <div class="orchestra-toolbar-group">
          <button class="control-btn ghost" onClick=${k}>맞춤 보기</button>
          <button class="control-btn ghost" onClick=${g}>초기화</button>
        </div>
        <div class="orchestra-toolbar-group">
          <button
            class="control-btn ghost"
            onClick=${()=>R(a.width/2,a.height/2,1.12)}
          >
            확대
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>R(a.width/2,a.height/2,.9)}
          >
            축소
          </button>
          <span class="command-chip">${Math.round(b.zoom*100)}%</span>
        </div>
        <div class="orchestra-toolbar-group">
          <button
            class=${`control-btn ${l==="balanced"?"is-active":"ghost"}`}
            onClick=${()=>{Us.value="balanced",Re.value=y}}
          >
            균형
          </button>
          <button
            class=${`control-btn ${l==="compact"?"is-active":"ghost"}`}
            onClick=${()=>{Us.value="compact",Re.value=y}}
          >
            집약
          </button>
          <span class="command-chip">${bh(l)}</span>
        </div>
      </div>

      <div class="orchestra-shell">
        <div
          ref=${e}
          class="orchestra-canvas-wrap"
          onWheel=${L}
          onPointerDown=${S}
          onPointerMove=${M}
          onPointerUp=${I}
          onPointerCancel=${I}
          onPointerLeave=${()=>I()}
        >
          <svg
            class=${`orchestra-canvas ${Pi.value?"is-dragging":""}`}
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
            <g transform=${`translate(${b.panX} ${b.panY}) scale(${b.zoom})`}>
              <${Lh} edges=${t.edges} positions=${c} selectedId=${y} />
              <${Mh} signalNodes=${m} roomPoint=${p} onSelect=${P=>{Re.value=P}} />
              <${Eh}
                orchestra=${t}
                positions=${c}
                density=${l}
                selectedId=${y}
                onSelect=${P=>{Re.value=P}}
              />
            </g>
          </svg>
          <div class="orchestra-summary-strip">
            <span class="command-chip">세션 ${((D=t.summary)==null?void 0:D.session_count)??0}</span>
            <span class="command-chip">워커 ${((J=t.summary)==null?void 0:J.worker_count)??0}</span>
            <span class="command-chip">키퍼 ${((et=t.summary)==null?void 0:et.keeper_count)??0}</span>
            <span class="command-chip ${w(t.signals.some(P=>P.tone==="bad")?"bad":t.signals.length>0?"warn":"ok")}">
              신호 ${((G=t.summary)==null?void 0:G.signal_count)??t.signals.length}
            </span>
            <span class="command-chip">갱신 ${Q(t.generated_at)}</span>
          </div>
        </div>

        <${Ph} orchestra=${t} />
      </div>
    </section>
  `}const vu="masc_dashboard_agent_name";function wh(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(vu))==null?void 0:s.trim())||"dashboard"}const _i=$(wh()),$n=$(""),Ga=$("운영 점검"),hn=$(""),cs=$(""),ds=$("2"),kn=$(""),At=$("note"),us=$(""),ps=$(""),ms=$(""),_s=$("2"),vs=$(""),Ja=$("운영자 중지 요청"),Po=$(""),Nh=$(""),Gs=$(null);function jh(t){const e=t.trim()||"dashboard";_i.value=e,localStorage.setItem(vu,e)}function Va(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Ar(t){switch((t??"").trim().toLowerCase()){case"judgment":return"상주 판단";case"fallback":return"보조 읽기 모델";default:return(t==null?void 0:t.trim())||"안내"}}function Ya(t){switch((t??"").trim().toLowerCase()){case"judgment":return"ok";case"fallback":return"warn";default:return"warn"}}function vi(t){return t!=null&&t.enabled?t.refreshing?"갱신 중":t.judge_online?"온라인":t.last_error?"오류":"대기":"꺼짐"}function fu(t){return t!=null&&t.enabled?t.judge_online?"ok":t.refreshing?"warn":"bad":"warn"}function Tr(t){return t!=null&&t.fresh_until?t.fresh_until:"갱신 기준 없음"}function Gl(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function xn(t){return typeof t=="string"?t.trim().toLowerCase():""}function Oh(t){var s;const e=xn(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=xn((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function zi(t){const e=xn(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function Jl(t){return t.some(e=>xn(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function Dh(t){return t.target_type==="team_session"}function qh(t){return t.target_type==="keeper"}function Fe(t){switch(t){case"broadcast":return"방송";case"room_pause":return"방 일시정지";case"room_resume":return"방 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"team_worker_spawn_batch":return"세션 작업자 교체";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"키퍼 메시지";case"keeper_msg":return"키퍼 메시지";case"swarm_run_continue":return"스웜 실행 계속";case"swarm_run_rerun":return"스웜 실행 재실행";case"swarm_run_abandon":return"스웜 실행 포기";default:return(t==null?void 0:t.trim())||"액션"}}function yn(t){switch(t){case"room":return"방";case"team_session":return"세션";case"keeper":return"키퍼";case"swarm_run":return"스웜 실행";default:return(t==null?void 0:t.trim())||"대상"}}function rn(t){switch(xn(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Xa(t){return t?"확인 후 실행":"즉시 실행"}function Fh(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"worker_spawn_batch":return"작업자 교체";default:return t}}function gt(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function Kh(t){return!t||typeof t!="object"||Array.isArray(t)?null:t}function Bh(t){if(!t)return"";const e=t.spawn_batch;return Va(e!==void 0?e:t)}function gu(t){const e=Kh(t.payload);if(t.target_type==="room"){if(t.action_type==="broadcast"){$n.value=gt(e,"message")??t.summary;return}if(t.action_type==="task_inject"){hn.value=gt(e,"title")??"운영자 주입 작업",cs.value=gt(e,"description")??t.summary,ds.value=gt(e,"priority")??ds.value;return}t.action_type==="room_pause"&&(Ga.value=gt(e,"reason")??t.summary);return}if(t.target_type==="team_session"){if(t.target_id&&(kn.value=t.target_id),t.action_type==="team_stop"){Ja.value=gt(e,"reason")??t.summary;return}At.value=t.action_type==="team_worker_spawn_batch"?"worker_spawn_batch":t.action_type==="team_task_inject"?"task":t.action_type==="team_broadcast"?"broadcast":"note";const n=gt(e,"message");if(n&&(us.value=n),At.value==="worker_spawn_batch"){vs.value=Bh(e);return}At.value==="task"&&(ps.value=gt(e,"task_title")??gt(e,"title")??"운영자 주입 작업",ms.value=gt(e,"task_description")??gt(e,"description")??t.summary,_s.value=gt(e,"task_priority")??gt(e,"priority")??_s.value);return}t.target_type==="keeper"&&(t.target_id&&(Po.value=t.target_id),Nh.value=gt(e,"message")??t.summary)}function Uh(t){gu({action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.suggested_payload,summary:t.summary})}function Hh(t){gu({action_type:t.action_type,target_type:t.target_type,target_id:t.target_id??null,payload:t.suggested_payload,summary:t.reason}),O("추천 액션 payload를 폼에 채웠습니다","success")}function Wh(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function Ue(t){const e=_i.value.trim()||"dashboard";try{const n=await _d({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?O("확인 대기열에 올렸습니다","warning"):O(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return O(s,"error"),null}}async function Vl(){const t=$n.value.trim();if(!t)return;await Ue({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&($n.value="")}async function Gh(){await Ue({action_type:"room_pause",target_type:"room",payload:{reason:Ga.value.trim()||"운영 점검"},successMessage:"방 일시정지를 요청했습니다"})}async function $u(){await Ue({action_type:"room_resume",target_type:"room",payload:{},successMessage:"방 재개를 요청했습니다"})}async function Jh(){const t=hn.value.trim();if(!t)return;await Ue({action_type:"task_inject",target_type:"room",payload:{title:t,description:cs.value.trim()||"개입 화면에서 주입",priority:Number.parseInt(ds.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(hn.value="",cs.value="")}async function Vh(){var l;const t=It.value,e=kn.value||((l=t==null?void 0:t.sessions[0])==null?void 0:l.session_id)||"";if(!e){O("먼저 세션을 고르세요","warning");return}const n={};if(At.value==="worker_spawn_batch"){const c=vs.value.trim();if(!c){O("spawn_batch JSON을 먼저 채우세요","warning");return}try{const p=JSON.parse(c);if(Array.isArray(p))n.spawn_batch=p;else if(p&&typeof p=="object"&&Array.isArray(p.spawn_batch))n.spawn_batch=p.spawn_batch;else{O("spawn_batch는 배열 또는 { spawn_batch: [...] } 형태여야 합니다","warning");return}}catch(p){const m=p instanceof Error?p.message:"spawn_batch JSON 파싱에 실패했습니다";O(m,"error");return}await Ue({action_type:"team_worker_spawn_batch",target_type:"team_session",target_id:e,payload:n,successMessage:"작업자 교체 요청을 적용했습니다"})&&(vs.value="");return}const s=us.value.trim();s&&(n.message=s);let a="team_note";At.value==="broadcast"?a="team_broadcast":At.value==="task"&&(a="team_task_inject"),At.value==="task"&&(n.task_title=ps.value.trim()||"운영자 주입 작업",n.task_description=ms.value.trim()||"개입 화면에서 주입",n.task_priority=Number.parseInt(_s.value,10)||2),await Ue({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(us.value="",At.value==="task"&&(ps.value="",ms.value=""))}async function Yh(){var n;const t=It.value,e=kn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){O("먼저 세션을 고르세요","warning");return}await Ue({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Ja.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Yl(t,e="confirm"){const n=_i.value.trim()||"dashboard";try{await vd(n,t,e),O(e==="deny"?"승인 대기를 거부했습니다":"확인 실행을 완료했습니다","success")}catch(s){const a=s instanceof Error?s.message:e==="deny"?"승인 대기 거부에 실패했습니다":"확인 실행에 실패했습니다";O(a,"error")}}function hu(t){switch(t){case"explicit":return"실제 관리 단위";case"hybrid":return"관리 단위 + 자동 보강";case"auto":return"자동 투영";default:return"출처 미상"}}function yu(t){switch(t){case"explicit":return"ok";case"hybrid":return"warn";case"auto":return"warn";default:return"warn"}}function Xh(t){switch(t){case"explicit":return"지금 보이는 유닛은 실제로 정의된 지휘면 관리 단위입니다.";case"hybrid":return"일부는 실제 관리 단위이고, 비어 있는 부분은 실시간 에이전트 편성을 보고 자동 보강한 구조입니다.";case"auto":return"이 화면은 실시간 에이전트 편성을 지휘면 모양으로 자동 투영한 것입니다. 실제 명령 체계와 1:1로 같다고 보면 안 됩니다.";default:return"이 화면은 관리 토폴로지와 실효 토폴로지가 섞여 있을 수 있습니다."}}function Qh(t){const e=t.unit.source??"unknown";return e==="explicit"?t.active_operation_count&&t.active_operation_count>0?"실제 관리 단위이며 연결된 작전이 있습니다.":"실제 관리 단위이지만 현재 연결된 작전은 없습니다.":e==="hybrid"?t.active_operation_count&&t.active_operation_count>0?"관리 단위를 기반으로 자동 보강된 구조이며 일부 작전이 연결돼 있습니다.":"관리 단위를 기반으로 자동 보강된 구조이며 현재 실행 연결은 약합니다.":t.active_operation_count&&t.active_operation_count>0?"자동 생성된 구조이지만 이 노드에 연결된 작전 흔적은 있습니다.":"자동 생성된 구조이며 현재 실행 연결은 없습니다."}function bu({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,o=t.unit.policy,l=t.unit.source??"unknown",c=a>0?`${a}개 작전 연결`:"실행 연결 없음";return i`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${N$(t.unit.kind)}</span>
            <span class="command-chip ${w(t.health)}">${t.health??"ok"}</span>
            <span class="command-chip ${yu(l)}">${hu(l)}</span>
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
          <div class="command-card-sub">${Qh(t)}</div>
          ${t.reasons&&t.reasons.length>0?i`<div class="command-tag-row">
                ${t.reasons.map(d=>i`<span class="command-tag warn">${d}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?i`<div class="command-tree-children">
            ${t.children.map(d=>i`<${bu} node=${d} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Zh({alert:t}){return i`
    <article class="command-alert ${w(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${w(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"범위"}:${t.scope_id??"정보 없음"}</span>
        <span>${Q(t.timestamp)}</span>
      </div>
      ${t.detail?i`<p>${t.detail}</p>`:null}
    </article>
  `}function Ir({event:t}){return i`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${Q(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${ls(t.detail)}</pre>
    </article>
  `}function ty(){const t=Jt.value,e=t==null?void 0:t.topology,n=e==null?void 0:e.source,s=e==null?void 0:e.summary,a=(s==null?void 0:s.managed_unit_count)??0,o=(s==null?void 0:s.active_operation_count)??0;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${B} panelId="command.topology" compact=${!0} />
      </div>
      ${t?i`
            <div class="command-topology-explainer">
              <div class="command-tree-title-row">
                <span class="command-chip ${yu(n)}">${hu(n)}</span>
                <span class="command-chip">관리 유닛 ${a}</span>
                <span class="command-chip ${o>0?"ok":"warn"}">활성 작전 ${o}</span>
              </div>
              <p>${Xh(n)}</p>
            </div>
          `:null}
      ${t&&t.topology.units.length>0?i`${t.topology.units.map(l=>i`<${bu} node=${l} />`)}`:i`<div class="empty-state">지금은 실시간 에이전트나 관리 유닛 기준으로 그릴 지휘 계층이 없습니다.</div>`}
    </section>
  `}function ey(){const t=Jt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${B} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>i`<${Zh} alert=${e} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 지휘면 경보는 없습니다.</div>`}
    </section>
  `}function ny(){const t=Jt.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${B} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?i`<div class="command-trace-stack">
            ${t.traces.events.map(e=>i`<${Ir} event=${e} />`)}
          </div>`:i`<div class="empty-state">최근 트레이스 이벤트가 없습니다.</div>`}
    </section>
  `}function sy(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t,null,2)}catch{return String(t)}}function ay(t,e){return(e==null?void 0:e.status)==="abandoned"||(t==null?void 0:t.recommended_kind)==="continue"?"warn":(t==null?void 0:t.recommended_kind)==="rerun"?"bad":"ok"}function iy(t){switch(t){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(t==null?void 0:t.trim())||"결정"}}function ku({swarm:t}){var f,h;const e=t.run_id,n=t.resolution_recommendation,s=t.run_resolution;if(!e||!n&&!s)return null;const a=ru()??"dashboard",o=((f=It.value)==null?void 0:f.pending_confirms.find(y=>y.target_type==="swarm_run"&&y.target_id===e))??null,l=ay(n,s),c=((h=t.operation)==null?void 0:h.operation_id)??t.operation_id??void 0,d={run_id:e};c&&(d.operation_id=c),n!=null&&n.reason&&(d.reason=n.reason);const p=async y=>{await _d({actor:a,action_type:y,target_type:"swarm_run",target_id:e,payload:d})},m=async y=>{o&&await vd(a,o.confirm_token,y)};return i`
    <article class="command-guide-card ${w(l)}">
      <div class="command-guide-head">
        <strong>Run Resolution</strong>
        <span class="command-chip ${w(l)}">
          ${iy((s==null?void 0:s.status)??(n==null?void 0:n.recommended_kind)??null)}
        </span>
      </div>
      <p>
        ${(s==null?void 0:s.status)==="abandoned"?`이 run은 ${s.decided_by}가 ${Q(s.decided_at)}에 soft abandon 처리했습니다. ${s.reason}`:(n==null?void 0:n.reason)??"이 run에 대한 별도 resolution recommendation은 아직 없습니다."}
      </p>
      <div class="command-card-grid">
        <span>Run</span><span>${e}</span>
        <span>Provenance</span><span><${je} item=${{kind:(n==null?void 0:n.provenance)??"recorded"}} /></span>
        <span>Engine</span><span>${(n==null?void 0:n.decision_engine)??"operator_record"}</span>
        <span>Authoritative</span><span>${n!=null&&n.authoritative?"yes":"no"}</span>
      </div>
      ${n!=null&&n.evidence?i`
            <div class="command-tag-row">
              <span class="command-tag">joined ${n.evidence.joined_workers??0}</span>
              <span class="command-tag">trace ${n.evidence.trace_events??0}</span>
              <span class="command-tag">message ${n.evidence.message_events??0}</span>
              ${n.evidence.runtime_blocker?i`<span class="command-tag ${w("bad")}">${n.evidence.runtime_blocker}</span>`:null}
            </div>
          `:null}
      ${o?i`
            <div class="command-guide-card warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip warn">${o.confirm_token}</span>
              </div>
              ${o.preview?i`<pre class="command-trace-detail">${sy(o.preview)}</pre>`:null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${()=>{m("confirm")}} disabled=${it.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${()=>{m("deny")}} disabled=${it.value}>취소</button>
              </div>
            </div>
          `:n?i`
              <div class="command-action-row">
                ${n.continue_available?i`<button class="control-btn ghost" onClick=${()=>{p("swarm_run_continue")}} disabled=${it.value}>Continue</button>`:null}
                ${n.rerun_available?i`<button class="control-btn" onClick=${()=>{p("swarm_run_rerun")}} disabled=${it.value}>Rerun</button>`:null}
                ${n.abandon_available?i`<button class="control-btn ghost" onClick=${()=>{p("swarm_run_abandon")}} disabled=${it.value}>Abandon</button>`:null}
              </div>
            `:null}
    </article>
  `}function xu(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function Su({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const o=a.motion_state;o in e?e[o]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return i`
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
  `}function oy({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function ry({lane:t}){const e=t.counts??{},n=xu(t),s=e.workers??0,a=e.operations??0,o=e.detachments??0,l=a+o,c=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return i`
    <article class="swarm-lane-strip ${w(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${w(n)}">${t.phase}</span>
          <span class="command-chip ${w(n)}">${t.motion_state}</span>
          <span class="command-chip">${Q(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${w(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${oy} total=${s} />
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
              ${t.hard_flags.map(d=>i`<span class="command-chip ${w(d.severity)}">${d.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Cu({lanes:t}){const e=t.slice(0,4);return e.length===0?null:i`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=xu(n),a=n.counts.workers??0,o=n.counts.operations??0,l=n.counts.detachments??0;return i`
          <article class="swarm-story-card ${w(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${w(s)}">${n.motion_state}</span>
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
  `}function ly({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${w(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?i`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function cy({gap:t}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${w(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function dy({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${w(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${w(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?i`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${Q(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?i`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?i`<p>${t.missing_reason}</p>`:null}
          `:i`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function uy(){const t=zs(),e=Rs(K.value),n=D$(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,o=(s==null?void 0:s.lanes.filter(f=>f.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],d=s==null?void 0:s.overview,p=s==null?void 0:s.recommended_next_action,m=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${B} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${Cu} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(d==null?void 0:d.active_lanes)??0}</strong><small>${(d==null?void 0:d.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(d==null?void 0:d.stalled_lanes)??0}</strong><small>${(d==null?void 0:d.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${Q(d==null?void 0:d.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${Q(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(p==null?void 0:p.label)??"운영자 상태 확인"}</strong><small>${(p==null?void 0:p.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${Su} lanes=${o} />`:null}

            <div class="command-swarm-layout ${m?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(f=>i`<${ry} lane=${f} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight ${n==="recommendation"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>${(p==null?void 0:p.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(p==null?void 0:p.lane_id)??"전체"}</span>
                  </div>
                  <p>${(p==null?void 0:p.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(p==null?void 0:p.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${dy} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${w(l.some(f=>f.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?i`<div class="swarm-event-rail">${l.slice(0,4).map(f=>i`<${cy} gap=${f} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?i`<div class="swarm-event-rail">${c.map(f=>i`<${ly} event=${f} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function py({item:t}){return i`
    <article class="command-guide-card ${w(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${w(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function Au({blocker:t}){return i`
    <article class="command-alert ${w(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${w(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function my({worker:t}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${w(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${t.last_message?i`<div class="command-card-foot">${Q(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function _y(){var d,p,m,f,h,y,C,_,k,g,b,R,L,S,M,I,D,J,et,G,P;const t=Ge.value,e=cu(),n=kr(),s=(d=t==null?void 0:t.provider)!=null&&d.runtime_blocker?"blocked":(p=t==null?void 0:t.provider)!=null&&p.provider_reachable?"ready":"check",a=((m=t==null?void 0:t.provider)==null?void 0:m.actual_slots)??((f=t==null?void 0:t.provider)==null?void 0:f.total_slots)??0,o=((h=t==null?void 0:t.provider)==null?void 0:h.expected_slots)??"n/a",l=((y=t==null?void 0:t.provider)==null?void 0:y.actual_ctx)??((C=t==null?void 0:t.provider)==null?void 0:C.ctx_per_slot)??0,c=((_=t==null?void 0:t.provider)==null?void 0:_.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${uy} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${B} panelId="command.swarm" compact=${!0} />
          </div>
          ${Oa.value?i`<div class="empty-state">Loading swarm live state…</div>`:Da.value?i`<div class="empty-state error">${Da.value}</div>`:t?i`
                    <div class="command-tag-row">
                      <span class="command-tag">experimental</span>
                      <${je} item=${{kind:"derived",label:"derived read-model"}} />
                      <span class="command-tag ${t.run_resolution||t.resolution_recommendation?"warn":"ok"}">
                        ${t.run_resolution||t.resolution_recommendation?"operator resolution aware":"no resolution advice"}
                      </span>
                    </div>
                    <div class="command-card-sub">
                      이 화면은 swarm-live의 사회 truth 자체가 아니라, 실험적 오케스트레이션을 읽기 위한 파생 관찰면입니다.
                    </div>
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((k=t.summary)==null?void 0:k.joined_workers)??0}/${((g=t.summary)==null?void 0:g.expected_workers)??0}</strong><small>${((b=t.summary)==null?void 0:b.live_workers)??0}개 가동 · ${((R=t.summary)==null?void 0:R.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${o} · ctx ${l}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(L=t.summary)!=null&&L.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((S=t.provider)==null?void 0:S.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(M=t.summary)!=null&&M.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((I=t.operation)==null?void 0:I.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((D=t.squad)==null?void 0:D.label)??"없음"}</span>
                      <span>실행체</span><span>${((J=t.detachment)==null?void 0:J.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((et=t.summary)==null?void 0:et.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((G=t.summary)==null?void 0:G.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((P=t.provider)==null?void 0:P.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?i`<div class="command-tag-row">
                          ${t.truth_notes.map(A=>i`<span class="command-tag">${A}</span>`)}
                        </div>`:null}
                    <${ku} swarm=${t} />
                  `:i`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${B} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?i`<div class="command-card-stack">
                ${t.checklist.map(A=>i`<${py} item=${A} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${B} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?i`<div class="command-card-stack">
                ${t.workers.map(A=>i`<${my} worker=${A} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${B} panelId="command.swarm" compact=${!0} />
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
                  <span>Last Sample</span><span>${t.provider.last_sample_at?Q(t.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${t.provider.checked_at?Q(t.provider.checked_at):"n/a"}</span>
                </div>
                ${t.provider.detail?i`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?i`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(A=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${A.active_slots} active</strong>
                              <span class="command-chip">${Q(A.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${A.active_slot_ids.join(", ")||"none"}</div>
                          </div>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:i`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${B} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?i`<div class="command-card-stack">
                ${t.blockers.map(A=>i`<${Au} blocker=${A} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${B} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?i`<div class="command-trace-stack">
                ${t.recent_messages.map(A=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${A.from}</strong>
                        <span class="command-chip">${Q(A.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${A.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${A.content}</pre>
                  </article>
                `)}
              </div>`:i`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${B} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${t.recent_trace_events.map(A=>i`<${Ir} event=${A} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function Yt(t,e=260){return t.length<=e?t:`${t.slice(0,e-1)}…`}function ln(t){if(!t)return 0;const e=Date.parse(t);return Number.isNaN(e)?0:e}function vy(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function fy(t){const e=typeof t.timestamp=="string"?t.timestamp:typeof t.created_at=="string"?t.created_at:typeof t.at=="string"?t.at:null,n=typeof t.title=="string"?t.title:typeof t.kind=="string"?t.kind:typeof t.event=="string"?t.event:"세션 이벤트",s=typeof t.detail=="string"?t.detail:typeof t.summary=="string"?t.summary:ls(t);return{timestamp:e,title:n,detail:Yt(s,220)}}function gy(t){return t==="swarm"?"스웜 실시간":"세션 요약"}function $y(t){switch(t){case"current":return"현재 과업 일치";case"drift":return"과업 드리프트";case"claim":return"착수 흔적 있음";case"no-claim":return"착수 흔적 없음";case"done":return"완료 흔적 있음";case"no-done":return"완료 흔적 없음";case"final":return"최종 보고 있음";case"no-final":return"최종 보고 없음";case"turn":return"턴 기록 있음";case"silent":return"턴 기록 없음";case"noted":return"노트 기록 있음";default:return t.startsWith("empty:")?`빈 노트 ${t.slice(6)}회`:t.startsWith("turns:")?`턴 ${t.slice(6)}회`:t}}function hy(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"할당 없음",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}초`:t.heartbeat_fresh?"정상":"정보 없음",detail:[t.bound_task_status??null,t.detachment_member?"분견대 소속":null,t.squad_member?"분대 소속":null].filter(Boolean).join(" · ")||"스웜 실시간 카드",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function yy(t,e){const n=t.actor??t.spawn_role??`워커-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"워커",a=t.lane_id??t.capsule_mode??t.control_domain??"세션",o=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"세션 레인",heartbeat:t.last_turn_ts_iso?Q(t.last_turn_ts_iso):"정보 없음",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?Rn(t.routing_confidence):null].filter(Boolean).join(" · ")||"세션 요약 카드",markers:o,note:t.routing_reason??null}}function by(t){var e;return{key:`agent:${t.name}`,name:t.name,role:t.agent_type??"agent",source:"agent",status:Ft(t.status),tone:w(ue(t.status)),task:t.current_task??"대기 중",signal:Q(t.last_seen),detail:[t.model??null,((e=t.capabilities)==null?void 0:e.slice(0,2).join(", "))||null].filter(Boolean).join(" · ")||"글로벌 agent roster",chips:[t.context_ratio!=null?`ctx ${Math.round(t.context_ratio*100)}%`:"ctx n/a",t.status],note:t.personalityHint??null}}function ky(t){var n,s,a;const e=t.status==="offline"||t.status==="inactive"?"bad":t.status==="active"||t.status==="healthy"?"ok":"warn";return{key:`keeper:${t.name}`,name:t.name,role:t.runtime_class??"keeper",source:"keeper",status:Ft(t.status),tone:e,task:((n=t.active_goal_ids)==null?void 0:n[0])??t.last_proactive_reason??((s=t.agent)==null?void 0:s.current_task)??"standby",signal:t.last_heartbeat?Q(t.last_heartbeat):vy(t.last_turn_ago_s),detail:[t.autonomy_level??null,t.active_model??t.primary_model??t.model??null,t.keepalive_running?"keepalive on":null].filter(Boolean).join(" · ")||"글로벌 keeper roster",chips:[t.context_ratio!=null?`ctx ${Math.round(t.context_ratio*100)}%`:"ctx n/a",t.latest_tool_call_count!=null?`tools ${t.latest_tool_call_count}`:"tools n/a"],note:((a=t.diagnostic)==null?void 0:a.summary)??t.last_proactive_preview??t.recent_output_preview??null}}function xy(t){return{key:`resident:${t.keeper_name??"judge"}`,name:t.keeper_name??"resident-judge",role:"resident judge",source:"resident",status:vi(t),tone:fu(t),task:t.judge_online?"live guidance":"standby",signal:t.generated_at?Q(t.generated_at):"정보 없음",detail:[t.model_used??null,t.last_error?"error":null].filter(Boolean).join(" · ")||"resident runtime",chips:[t.enabled?"enabled":"disabled",t.judge_online?"online":"offline"],note:t.last_error??null}}function Sy(t){return w(t.severity)}function Cy({swarmMessages:t,traceEvents:e,chainOverlay:n,linkedAutoresearch:s,selectedSession:a,activeRecommendedActions:o,attentionItems:l}){const c=[];for(const d of t.slice(0,8))c.push({key:`message:${d.seq}`,title:d.from,detail:Yt(d.content,280),meta:`메시지 · seq ${d.seq}`,source:"swarm",tone:"ok",timestamp:d.timestamp,sortTs:ln(d.timestamp)});for(const d of e.slice(0,8))c.push({key:`trace:${d.event_id}`,title:d.event_type,detail:Yt(ls(d.detail),280),meta:[d.actor??null,d.source??null].filter(Boolean).join(" · ")||"trace",source:"trace",tone:d.event_type.includes("error")||d.event_type.includes("fail")?"bad":"warn",timestamp:d.timestamp,sortTs:ln(d.timestamp)});if(n!=null&&n.history&&c.push({key:`chain:${n.operation.operation_id}:${n.history.event}`,title:`Chain · ${n.history.event}`,detail:Yt(mi(n.history),260),meta:n.history.chain_id??n.operation.operation_id,source:"chain",tone:n.history.event.includes("error")||n.history.event.includes("fail")?"bad":"warn",timestamp:n.history.timestamp,sortTs:ln(n.history.timestamp)}),s){const d=[s.last_decision??null,s.target_file?`target ${s.target_file}`:null,s.error??null].filter(Boolean);c.push({key:`autoresearch:${s.loop_id??(a==null?void 0:a.session_id)??"session"}`,title:`Autoresearch · ${s.status??"unknown"}`,detail:Yt(d.join(" · ")||"linked autoresearch context",260),meta:[s.loop_id?`loop ${s.loop_id}`:null,s.current_cycle!=null?`cycle ${s.current_cycle}`:null,s.best_score!=null?`best ${s.best_score}`:null].filter(Boolean).join(" · ")||"linked autoresearch",source:"autoresearch",tone:s.error?"bad":s.status==="running"?"warn":"ok",timestamp:null,sortTs:0})}for(const d of o.slice(0,4))c.push({key:`recommendation:${d.action_type}:${d.target_type}:${d.target_id??"session"}`,title:`${d.action_type} · ${d.target_type}`,detail:Yt(d.reason,240),meta:d.target_id??"operator recommendation",source:"recommendation",tone:Sy(d),timestamp:null,sortTs:0});for(const d of l.slice(0,4))c.push({key:`attention:${d.kind}:${d.target_id??"session"}`,title:`${d.kind} · ${d.target_type}`,detail:Yt(d.summary,240),meta:d.target_id??"attention",source:"attention",tone:w(d.severity),timestamp:null,sortTs:0});for(const[d,p]of((a==null?void 0:a.recent_events)??[]).slice(0,4).entries()){const m=fy(p);c.push({key:`session:${(a==null?void 0:a.session_id)??"unknown"}:${d}`,title:m.title,detail:m.detail,meta:(a==null?void 0:a.session_id)??"session",source:"session",tone:"warn",timestamp:m.timestamp,sortTs:ln(m.timestamp)})}return c.sort((d,p)=>p.sortTs-d.sortTs||d.title.localeCompare(p.title)).slice(0,14)}function Ay({worker:t}){return i`
    <article class="command-card compact warroom-worker-card ${w(ue(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${w(ue(t.status))}">${Ft(t.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>출처</span><span>${gy(t.source)}</span>
        <span>과업</span><span>${t.task}</span>
        <span>최근 신호</span><span>${t.heartbeat}</span>
        <span>근거</span><span>${t.detail}</span>
      </div>
      <div class="command-tag-row">
        ${t.markers.map(e=>i`<span class="command-tag">${$y(e)}</span>`)}
      </div>
      ${t.note?i`<div class="command-card-foot">${Yt(t.note,220)}</div>`:null}
    </article>
  `}function Xl({item:t}){return i`
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
  `}function Ty({item:t}){return i`
    <article class="command-trace-row warroom-feed-card ${t.tone}">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.title}</strong>
          <span class="command-chip ${t.tone}">${t.timestamp?Q(t.timestamp):t.source}</span>
        </div>
        <div class="command-card-sub">${t.meta}</div>
      </div>
      <div class="warroom-feed-detail">${t.detail}</div>
    </article>
  `}function qt({label:t,surface:e,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){Kt(e),at("command",{...Ps(e),...n});return}at("intervene")}}
    >
      ${t}
    </button>
  `}function Iy({chainOverlay:t,linkedAutoresearch:e}){var n,s,a,o;return!t&&!e?i`<div class="command-guide-card"><p>이 세션에 붙은 chain/autoresearch 오버레이가 아직 없습니다.</p></div>`:i`
    <div class="warroom-orchestration-grid">
      ${t?i`
            <article class="command-card warroom-orchestration-card">
              <div class="command-card-head">
                <div>
                  <strong>Chain Orchestration</strong>
                  <div class="command-card-sub">${t.operation.operation_id}</div>
                </div>
                <span class="command-chip ${w(ue(t.operation.status))}">${Ft(t.operation.status)}</span>
              </div>
              <div class="command-card-grid">
                <span>Chain</span><span>${((n=t.runtime)==null?void 0:n.chain_id)??((s=t.preview_run)==null?void 0:s.chain_id)??"n/a"}</span>
                <span>Progress</span><span>${Rn((a=t.runtime)==null?void 0:a.progress)}</span>
                <span>Elapsed</span><span>${an((o=t.runtime)==null?void 0:o.elapsed_sec)}</span>
                <span>최근 이벤트</span><span>${mi(t.history)}</span>
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
  `}function Ry({wallboard:t=!1}){var wr,Nr,jr,Or,Dr,qr,Fr,Kr,Br,Ur,Hr,Wr,Gr,Jr,Vr,Yr,Xr,Qr,Zr,tl,el,nl,sl,al,il,ol,rl,ll,cl,dl,ul,pl;const e=zs(),n=Ge.value,s=It.value,a=Ht.value,o=W$(),l=n!=null&&n.operation?((wr=Is.value)==null?void 0:wr.operations.find(U=>{var Se;return U.operation.operation_id===((Se=n.operation)==null?void 0:Se.operation_id)}))??null:null,c=(o==null?void 0:o.linked_autoresearch)??null,d=U$(),p=(n==null?void 0:n.workers)??[],m=(a==null?void 0:a.worker_cards)??[],f=d&&p.length>0?p.map(hy):m.map(yy),h=Gt.value.filter(U=>U.status==="active"||U.status==="busy"||U.status==="listening"||U.status==="idle"),y=ie.value.filter(U=>U.status!=="offline"||U.keepalive_running||U.last_heartbeat).sort((U,Se)=>ln(Se.last_heartbeat)-ln(U.last_heartbeat)),C=d,_=((Nr=e==null?void 0:e.decisions.summary)==null?void 0:Nr.pending)??0,k=ci(s),g=k.items,b=k.total_count,R=k.visible_count,L=k.hidden_count,S=d?(n==null?void 0:n.blockers)??[]:[],M=(a==null?void 0:a.recommended_actions)??[],I=(jr=a==null?void 0:a.active_recommended_actions)!=null&&jr.length?a.active_recommended_actions:M,D=a==null?void 0:a.active_summary,J=(a==null?void 0:a.active_guidance_layer)??"fallback",et=(a==null?void 0:a.resident_judge_runtime)??(s==null?void 0:s.resident_judge_runtime),G=(a==null?void 0:a.attention_items)??[],P=((Or=n==null?void 0:n.recent_messages[0])==null?void 0:Or.timestamp)??null,A=((Dr=n==null?void 0:n.recent_trace_events[0])==null?void 0:Dr.timestamp)??null,z=d?P??A??null:null,V=o==null?void 0:o.summary,yt=(d?(qr=n==null?void 0:n.summary)==null?void 0:qr.expected_workers:void 0)??(typeof(V==null?void 0:V.planned_worker_count)=="number"?V.planned_worker_count:void 0)??(a==null?void 0:a.worker_cards.length)??0,oe=(d?(Fr=n==null?void 0:n.summary)==null?void 0:Fr.joined_workers:void 0)??(typeof(V==null?void 0:V.active_agent_count)=="number"?V.active_agent_count:void 0)??f.length,W=S.length>0||_>0||b>0?"warn":C||o?"ok":"warn",ft=d?((Kr=e==null?void 0:e.swarm_status)==null?void 0:Kr.lanes.filter(U=>U.present))??[]:[],xe=((Ur=(Br=e==null?void 0:e.swarm_status)==null?void 0:Br.narrative)==null?void 0:Ur.lane_id)??((Wr=(Hr=e==null?void 0:e.swarm_status)==null?void 0:Hr.recommended_next_action)==null?void 0:Wr.lane_id)??((Gr=ft[0])==null?void 0:Gr.lane_id)??null,rt=xe?ft.find(U=>U.lane_id===xe)??null:ft[0]??null,Mn=[...et?[xy(et)]:[],...h.slice(0,t?8:5).map(by),...y.slice(0,t?8:5).map(ky)],ws=Mn.filter(U=>U.source==="agent"),Ns=Mn.filter(U=>U.source==="keeper"||U.source==="resident"),js=Cy({swarmMessages:(n==null?void 0:n.recent_messages)??[],traceEvents:(n==null?void 0:n.recent_trace_events)??[],chainOverlay:l,linkedAutoresearch:c,selectedSession:o,activeRecommendedActions:I,attentionItems:G}),$i=((Jr=n==null?void 0:n.operation)==null?void 0:Jr.objective)??((Yr=(Vr=e==null?void 0:e.swarm_status)==null?void 0:Vr.narrative)==null?void 0:Yr.active_work)??(o==null?void 0:o.session_id)??"가동 중인 워룸",hi=[(D==null?void 0:D.summary)??null,((Qr=(Xr=e==null?void 0:e.swarm_status)==null?void 0:Xr.narrative)==null?void 0:Qr.state)??null,((tl=(Zr=e==null?void 0:e.swarm_status)==null?void 0:Zr.narrative)==null?void 0:tl.active_work)??null,rt?`${rt.label} · ${rt.current_step}`:null].filter(Boolean).join(" · ")||"실제 실행, 메시지, 트레이스, 상주 판단을 한 장에서 읽는 wallboard입니다.",[yi,bi]=Ke(typeof document<"u"&&!!document.fullscreenElement);tt(()=>{_t()},[]),tt(()=>{o!=null&&o.session_id&&ye(o.session_id)},[o==null?void 0:o.session_id,s,(el=n==null?void 0:n.detachment)==null?void 0:el.session_id]),tt(()=>{if(!t)return;const U=()=>{bi(!!document.fullscreenElement)};return document.addEventListener("fullscreenchange",U),U(),()=>{document.removeEventListener("fullscreenchange",U)}},[t]);const Uu=()=>{var U,Se,ml;if(!(typeof document>"u")){if(document.fullscreenElement){(U=document.exitFullscreen)==null||U.call(document);return}(ml=(Se=document.documentElement).requestFullscreen)==null||ml.call(Se)}},Hu=()=>{_t(),Zt(),qe(),o!=null&&o.session_id&&ye(o.session_id)};return!C&&!o?Oa.value||ns.value?i`<div class="empty-state">실시간 워룸 불러오는 중…</div>`:i`
      <section class="card command-section command-warroom-empty ${t?"wallboard":""}">
        <div class="card-title-row">
          <div class="card-title">실시간 워룸</div>
          <${B} panelId="command.warroom" compact=${!0} />
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
      <section class="command-warroom-strip ${w(W)} ${t?"wallboard":""}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">${t?"War Room Wallboard":"실시간 워룸"}</span>
            <strong>${$i}</strong>
            <div class="command-card-sub">
              ${d?((nl=n==null?void 0:n.operation)==null?void 0:nl.operation_id)??"작전 정보 없음":"세션 기준값"}
              ${o!=null&&o.session_id?` · 세션 ${o.session_id}`:""}
              ${d&&((sl=n==null?void 0:n.detachment)!=null&&sl.detachment_id)?` · 분견대 ${n.detachment.detachment_id}`:""}
              ${rt?` · 대표 레인 ${rt.label}`:""}
            </div>
            <div class="command-warroom-summary">${hi}</div>
            ${D!=null&&D.summary?i`<div class="command-warroom-guidance ${Ya(J)}">
                  <strong>${Ar(J)}</strong>
                  <span>${D.summary}</span>
                </div>`:null}
          </div>
          <div class="command-warroom-hero-actions">
            <button class="control-btn ghost" onClick=${Hu}>새로고침</button>
            ${t?i`
                  <button class="control-btn ghost" onClick=${Uu}>
                    ${yi?"전체 화면 해제":"전체 화면"}
                  </button>
                  <button
                    class="control-btn ghost"
                    onClick=${()=>{var U;document.fullscreenElement&&((U=document.exitFullscreen)==null||U.call(document)),Kt("warroom"),at("command",Ps("warroom"))}}
                  >
                    표준 보기
                  </button>
                `:null}
            <${qt}
              label="스웜 상세"
              surface="swarm"
              params=${{...d&&((al=n==null?void 0:n.operation)!=null&&al.operation_id)?{operation_id:n.operation.operation_id}:{},...d&&(n!=null&&n.run_id)?{run_id:n.run_id}:{}}}
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
            <strong>${oe??0}/${yt??0}</strong>
            <small>${d?((il=n==null?void 0:n.summary)==null?void 0:il.completed_workers)??0:0} 완료 · ${f.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>런타임</span>
            <strong>${d?(ol=n==null?void 0:n.provider)!=null&&ol.runtime_blocker?"막힘":(rl=n==null?void 0:n.provider)!=null&&rl.provider_reachable?"준비됨":o?Ft(o.status):"확인 필요":o?Ft(o.status):"확인 필요"}</strong>
            <small>${d?`설정 ${((ll=n==null?void 0:n.provider)==null?void 0:ll.configured_capacity)??"n/a"} · 실제 ${((cl=n==null?void 0:n.provider)==null?void 0:cl.actual_slots)??((dl=n==null?void 0:n.provider)==null?void 0:dl.total_slots)??0} · hot ${((ul=n==null?void 0:n.summary)==null?void 0:ul.peak_hot_slots)??((pl=n==null?void 0:n.provider)==null?void 0:pl.peak_active_slots)??0}`:`세션 워커 ${(a==null?void 0:a.worker_cards.length)??0}`}</small>
          </div>
          <div class="monitor-stat-card ${w(S.length>0||_>0||b>0?"warn":"ok")}">
            <span>압력</span>
            <strong>${S.length+_+b}</strong>
            <small>막힘 ${S.length} · 승인 ${_} · 확인 ${R}${L>0?`/${b}`:""}</small>
          </div>
          <div class="monitor-stat-card ${w(Ya(J))}">
            <span>상주 판정기</span>
            <strong>${vi(et)}</strong>
            <small>${Tr(D)}${et!=null&&et.model_used?` · ${et.model_used}`:""}</small>
          </div>
          <div class="monitor-stat-card">
            <span>마지막 신호</span>
            <strong>${Q(z)}</strong>
            <small>${P?"메시지":A?"트레이스":"대기 중"}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid ${t?"wallboard":""}">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${B} panelId="command.warroom" compact=${!0} />
            </div>
            ${ft.length>0?i`
                  <${Cu} lanes=${ft} />
                  <${Su} lanes=${ft} />
                `:o?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${o.session_id}</strong>
                        <span class="command-chip ${w(ue(o.status))}">${Ft(o.status)}</span>
                      </div>
                      <p>스웜 실시간 증거는 아직 약합니다. 이 카드는 세션 요약과 워커 기록을 기준으로 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${o.progress_pct!=null?`${o.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${an(o.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${an(o.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 레인이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">오케스트레이션</div>
              <${B} panelId="command.chains" compact=${!0} />
            </div>
            <${Iy} chainOverlay=${l} linkedAutoresearch=${c} />
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">워커 현황</div>
              <${B} panelId="command.warroom" compact=${!0} />
            </div>
            ${f.length>0?i`<div class="command-card-stack">
                  ${f.map(U=>i`<${Ay} worker=${U} />`)}
                </div>`:i`<div class="empty-state">활성 워커 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">상황 피드</div>
              <${B} panelId="command.warroom" compact=${!0} />
            </div>
            ${js.length>0?i`<div class="command-trace-stack">
                  ${js.map(U=>i`<${Ty} item=${U} />`)}
                </div>`:i`<div class="empty-state">메시지, chain, autoresearch, attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">트레이스 흐름</div>
              <${B} panelId="command.trace" compact=${!0} />
            </div>
            ${n&&n.recent_trace_events.length>0?i`<div class="command-trace-stack">
                  ${n.recent_trace_events.map(U=>i`<${Ir} event=${U} />`)}
                </div>`:i`<div class="empty-state">실행 범위 트레이스 이벤트가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Agents</div>
              <${B} panelId="command.warroom" compact=${!0} />
            </div>
            ${ws.length>0?i`<div class="warroom-presence-grid">
                  ${ws.map(U=>i`<${Xl} item=${U} />`)}
                </div>`:i`<div class="empty-state">가시적인 active agent가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Keepers</div>
              <${B} panelId="command.warroom" compact=${!0} />
            </div>
            ${Ns.length>0?i`<div class="warroom-presence-grid">
                  ${Ns.map(U=>i`<${Xl} item=${U} />`)}
                </div>`:i`<div class="empty-state">가시적인 keeper/runtime 카드가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">압력</div>
              <${B} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${d&&n?i`<${ku} swarm=${n} />`:null}
              ${S.length>0?S.map(U=>i`<${Au} blocker=${U} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${_>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>승인 대기</strong>
                        <span class="command-chip warn">${_}</span>
                      </div>
                      <p>엄격 액션이 묶여 있습니다. 실제 승인 처리는 제어 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${b>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>확인 대기</strong>
                        <span class="command-chip warn">${L>0?`${R}/${b}`:b}</span>
                      </div>
                      <p>
                        운영자 미리보기가 사람 확인을 기다리고 있습니다.
                        ${L>0?` 현재 actor 기준으로는 ${R}건만 보입니다.`:""}
                      </p>
                      <div class="command-tag-row">
                        ${g.slice(0,3).map(U=>i`<span class="command-tag">${U.confirm_token}</span>`)}
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
                        <span class="command-chip ${w(ue(rt.motion_state))}">${Ft(rt.motion_state)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>현재 단계</span><span>${rt.current_step}</span>
                        <span>이동 사유</span><span>${rt.movement_reason}</span>
                        <span>막힘 수</span><span>${rt.blockers.length}</span>
                        <span>최근 이동</span><span>${Q(rt.last_movement_at)}</span>
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
                        <span class="command-chip ${w(ue(n.detachment.status))}">${Ft(n.detachment.status??"active")}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>리더</span><span>${n.detachment.leader_id??"미지정"}</span>
                        <span>편성</span><span>${n.detachment.roster.length}</span>
                        <span>세션</span><span>${n.detachment.session_id??"연결 없음"}</span>
                        <span>하트비트</span><span>${iu(n.detachment.heartbeat_deadline)}</span>
                      </div>
                    </article>
                  `:o?i`
                      <article class="command-card compact">
                        <div class="command-card-head">
                          <div>
                            <strong>${o.session_id}</strong>
                            <div class="command-card-sub">현재 세션 기준</div>
                          </div>
                          <span class="command-chip ${w(ue(o.status))}">${Ft(o.status)}</span>
                        </div>
                        <div class="command-card-grid">
                          <span>진행률</span><span>${o.progress_pct!=null?`${o.progress_pct}%`:"정보 없음"}</span>
                          <span>경과</span><span>${an(o.elapsed_sec)}</span>
                          <span>남은 시간</span><span>${an(o.remaining_sec)}</span>
                          <span>완료 변화량</span><span>${o.done_delta_total??0}</span>
                        </div>
                      </article>
                    `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function Ql(t){switch((t??"").trim().toLowerCase()){case"active":return"가동 중";case"paused":return"일시정지";case"failed":return"실패";case"completed":case"done":return"완료";case"disconnected":return"끊김";case"preview":return"미리보기";case"captured":return"기록됨";default:return(t==null?void 0:t.trim())||"확인 필요"}}function My({source:t}){const e=ee(null),[n,s]=Ke(null);return tt(()=>{let a=!1;const o=e.current;return o?(o.innerHTML="",s(null),(async()=>{try{const c=await I$(),{svg:d}=await c.render(`command-chain-${T$()}`,t);if(a||!e.current)return;e.current.innerHTML=d}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid 렌더링에 실패했습니다")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function Ly({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return i`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${fe(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?i`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?i`<span class="command-tag ${fe(s==null?void 0:s.status)}">${Rn(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${mi(t.history)}</div>
    </button>
  `}function Ey({item:t}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"알 수 없는 체인"}</strong>
        <span class="command-chip ${fe(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${Q(t.timestamp)}</div>
      <div class="command-card-sub">${mi(t)}</div>
    </article>
  `}function Py({node:t}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${fe(t.status)}">${t.status??"확인 필요"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"노드"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?i`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function zy({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,o=e.chain,l=(o==null?void 0:o.run_id)??null;return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${w(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${Ql(e.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>트레이스</span><span class="mono">${e.trace_id}</span>
        <span>자율성</span><span>${e.autonomy_level??"정보 없음"}</span>
        <span>예산 등급</span><span>${e.budget_class??"standard"}</span>
        <span>출처</span><span>${e.source??"managed"}</span>
        <span>최근 갱신</span><span>${Q(e.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${fe(o.status)}">${Ql(o.status)}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">실행 ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?i`<div class="command-card-foot">체크포인트 ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Kt("swarm"),at("command",{surface:"swarm",operation_id:e.operation_id,...l?{run_id:l}:{}})}}
        >
          스웜 실시간 보기
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{mr(e.operation_id),Kt("chains"),at("command",{surface:"chains",operation:e.operation_id})}}
              >
                체인 열기
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?i`
              <button class="control-btn ghost" disabled=${ut(n)} onClick=${()=>ge(()=>Ff(e.operation_id))}>
                ${ut(n)?"일시정지 중…":"일시정지"}
              </button>
              <button class="control-btn ghost" disabled=${ut(a)} onClick=${()=>ge(()=>Bf(e.operation_id))}>
                ${ut(a)?"회수 중…":"회수"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?i`
              <button class="control-btn ghost" disabled=${ut(s)} onClick=${()=>ge(()=>Kf(e.operation_id))}>
                ${ut(s)?"재개 중…":"재개"}
              </button>
            `:null}
      </div>
    </article>
  `}function wy({card:t}){var n;const e=t.detachment;return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${w(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>리더</span><span>${e.leader_id??"미지정"}</span>
        <span>편성</span><span>${e.roster.length}</span>
        <span>세션</span><span>${e.session_id??"연결 없음"}</span>
        <span>런타임</span><span>${e.runtime_kind??"managed"}</span>
        <span>런타임 참조</span><span>${e.runtime_ref??"정보 없음"}</span>
        <span>진행 흔적</span><span>${Q(e.last_progress_at)}</span>
        <span>하트비트</span><span>${iu(e.heartbeat_deadline)}</span>
        <span>최근 갱신</span><span>${Q(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?i`<span class="command-tag ${C$(e.heartbeat_deadline)}">
              기한 ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Ny(){const t=Jt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">작전</div>
          <${B} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?i`<div class="command-card-stack">
              ${t.operations.operations.map(e=>i`<${zy} card=${e} />`)}
            </div>`:i`<div class="empty-state">관리형 또는 투영된 작전이 없습니다.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">분견대</div>
          <${B} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>i`<${wy} card=${e} />`)}
            </div>`:i`<div class="empty-state">투영된 분견대가 없습니다.</div>`}
      </section>
    </div>
  `}function jy(){var c,d,p,m,f,h,y,C,_,k,g,b,R,L,S,M;const t=Is.value,e=(t==null?void 0:t.operations)??[],n=fn.value,s=e.find(I=>I.operation.operation_id===n)??e[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,o=((d=as.value)==null?void 0:d.run)??(s==null?void 0:s.preview_run)??null,l=!((p=as.value)!=null&&p.run)&&!!(s!=null&&s.preview_run);return tt(()=>{a?Df(a):Of()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${B} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${fe(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>native chain 연결</strong>
            <span class="command-chip ${fe(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"체인 요약은 MASC 프록시를 통해 집계됩니다."}</p>
          <div class="command-card-grid">
            <span>기준 URL</span><span>${(t==null?void 0:t.connection.base_url)??"정보 없음"}</span>
            <span>연결된 작전</span><span>${((m=t==null?void 0:t.summary)==null?void 0:m.linked_operations)??0}</span>
            <span>활성 체인</span><span>${((f=t==null?void 0:t.summary)==null?void 0:f.active_chains)??0}</span>
            <span>최근 실패</span><span>${((h=t==null?void 0:t.summary)==null?void 0:h.recent_failures)??0}</span>
            <span>마지막 이벤트</span><span>${Q((y=t==null?void 0:t.summary)==null?void 0:y.last_history_event_at)}</span>
          </div>
        </article>

        ${Fa.value?i`<div class="empty-state error">${Fa.value}</div>`:null}

        ${Io.value&&!t?i`<div class="empty-state">체인 오버레이 불러오는 중…</div>`:e.length>0?i`
                <div class="command-chain-list">
                  ${e.map(I=>i`
                    <${Ly}
                      overlay=${I}
                      selected=${(s==null?void 0:s.operation.operation_id)===I.operation.operation_id}
                      onSelect=${()=>mr(I.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(I=>i`<${Ey} item=${I} />`)}
                </div>
              `:i`<div class="empty-state">최근 체인 이력이 없습니다.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">체인 상세</div>
          <${B} panelId="command.chains" compact=${!0} />
        </div>
        ${s?i`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${fe((C=s.operation.chain)==null?void 0:C.status)}">
                    ${((_=s.operation.chain)==null?void 0:_.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>종류</span><span>${((k=s.operation.chain)==null?void 0:k.kind)??"chain_dsl"}</span>
                  <span>체인 ID</span><span>${((g=s.operation.chain)==null?void 0:g.chain_id)??"goal-driven"}</span>
                  <span>실행 ID</span><span>${a??"아직 구체화되지 않음"}</span>
                  <span>진행률</span><span>${Rn((b=s.runtime)==null?void 0:b.progress)}</span>
                  <span>경과</span><span>${an((R=s.runtime)==null?void 0:R.elapsed_sec)}</span>
                  <span>최근 갱신</span><span>${Q(((L=s.operation.chain)==null?void 0:L.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(S=s.operation.chain)!=null&&S.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid 그래프</strong>
                        <span class="command-chip">${((M=s.operation.chain)==null?void 0:M.chain_id)??"graph"}</span>
                      </div>
                      <${My} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">기록된 Mermaid 그래프가 아직 없습니다.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>실행 상세</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"실패":l?"미리보기":"기록됨":"대기 중"}
                  </span>
                </div>
                ${Ka.value?i`<div class="empty-state">실행 상세 불러오는 중…</div>`:is.value?i`<div class="empty-state error">${is.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>체인</span><span>${o.chain_id}</span>
                            <span>실행</span><span>${o.run_id??"미리보기만 있음"}</span>
                            <span>지속시간</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"정보 없음"}</span>
                            <span>노드</span><span>${o.nodes.length}</span>
                          </div>
                          ${l?i`<div class="command-card-foot">run-store에 기록되기 전, 설계된 체인으로 만든 미리보기입니다.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(I=>i`<${Py} node=${I} />`)}
                          </div>
                        `:i`<div class="empty-state">이 작전의 run-store 상세는 아직 없습니다.</div>`}
              </div>
            `:i`<div class="empty-state">그래프와 실행 상세를 보려면 체인 기반 작전을 고르세요.</div>`}
      </section>
    </div>
  `}function Oy(t){switch((t??"").trim().toLowerCase()){case"pending":return"대기 중";case"approved":return"승인됨";case"denied":return"거부됨";case"executed":return"실행됨";case"active":return"가동 중";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Dy({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return i`
    <article class="command-card ${w(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${w(t.status)}">${Oy(t.status??"pending")}</span>
      </div>
      <div class="command-card-grid">
        <span>결정 ID</span><span>${t.decision_id}</span>
        <span>요청자</span><span>${t.requested_by??"알 수 없음"}</span>
        <span>출처</span><span>${t.source??"managed"}</span>
        <span>트레이스</span><span class="mono">${t.trace_id}</span>
        <span>생성 시각</span><span>${Q(t.created_at)}</span>
        <span>이유</span><span>${t.reason??"정보 없음"}</span>
      </div>
      ${t.status==="pending"&&!s?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${ut(e)} onClick=${()=>ge(()=>Hf(t.decision_id))}>
                ${ut(e)?"승인 중…":"승인"}
              </button>
              <button class="control-btn ghost" disabled=${ut(n)} onClick=${()=>ge(()=>Wf(t.decision_id))}>
                ${ut(n)?"거부 중…":"거부"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">레거시 operator 승인입니다. 실제 실행은 operator control에서 처리합니다.</div>`:null}
    </article>
  `}function qy({row:t}){var c,d,p;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((c=e.policy)!=null&&c.frozen),o=!!((d=e.policy)!=null&&d.kill_switch),l=Math.round((t.utilization??0)*100);return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${w(l>100?"bad":l>70?"warn":"ok")}">${l}%</span>
      </div>
      <div class="command-card-grid">
        <span>편성</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>정원</span><span>${t.headcount_cap??0}</span>
        <span>작전</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>자율성</span><span>${((p=e.policy)==null?void 0:p.autonomy_level)??"정보 없음"}</span>
        <span>동결</span><span>${a?"예":"아니오"}</span>
        <span>킬 스위치</span><span>${o?"켜짐":"꺼짐"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${ut(n)} onClick=${()=>ge(()=>Gf(e.unit_id,!a))}>
          ${ut(n)?"적용 중…":a?"동결 해제":"동결"}
        </button>
        <button class="control-btn ghost" disabled=${ut(s)} onClick=${()=>ge(()=>Jf(e.unit_id,!o))}>
          ${ut(s)?"적용 중…":o?"킬 스위치 해제":"킬 스위치 켜기"}
        </button>
      </div>
    </article>
  `}function Fy(){const t=Jt.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${B} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>i`<${Dy} decision=${e} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">유닛 제어</div>
          <${B} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>i`<${qy} row=${e} />`)}
            </div>`:i`<div class="empty-state">제어할 용량 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function Ky(){return i`
    <div class="command-surface-tabs grouped">
      ${M$.map(t=>i`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${ou.filter(e=>e.group===t.id).map(e=>i`
                <button
                  class="command-surface-tab ${X.value===e.id?"active":""}"
                  onClick=${()=>{Kt(e.id),at("command",Ps(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function By({wallboard:t=!1}){if(X.value==="warroom")return i`<${Ry} wallboard=${t} />`;if(X.value==="summary")return i`<${hh} />`;if(X.value==="orchestra")return i`<${zh} />`;if(X.value==="swarm")return i`<${_y} />`;if(!Jt.value)return i`<${yh} />`;switch(X.value){case"chains":return i`<${jy} />`;case"topology":return i`<${ty} />`;case"alerts":return i`<${ey} />`;case"trace":return i`<${ny} />`;case"control":return i`<${Fy} />`;case"operations":default:return i`<${Ny} />`}}function Uy(){const t=X.value==="warroom"&&K.value.params.presentation==="wallboard";return tt(()=>{sn(),qe(),qf(),Zt(),Ne()},[]),tt(()=>{if(K.value.tab!=="command")return;const e=K.value.params.surface,n=K.value.params.operation,s=Rs(K.value);if(ql(e))Kt(e);else if(s){const a=Ud(s);ql(a)&&Kt(a)}else e||Kt("warroom");n&&mr(n),(e==="swarm"||e==="warroom"||e==="orchestra"||X.value==="warroom"||X.value==="orchestra")&&Zt(),(e==="orchestra"||X.value==="orchestra")&&Ne(),(e==="warroom"||X.value==="warroom")&&_t()},[K.value.tab,K.value.params.surface,K.value.params.operation,K.value.params.operation_id,K.value.params.run_id,K.value.params.source,K.value.params.action_type,K.value.params.target_type,K.value.params.target_id,K.value.params.focus_kind]),tt(()=>{let e=null;const n=()=>{e||(e=window.setTimeout(()=>{e=null,sn(),qe(),(X.value==="swarm"||X.value==="warroom"||X.value==="orchestra")&&Zt(),X.value==="orchestra"&&Ne(),X.value==="warroom"&&_t()},250))},s=new EventSource(w$()),a=E$.map(o=>{const l=()=>n();return s.addEventListener(o,l),{type:o,handler:l}});return s.onerror=()=>{n()},()=>{a.forEach(({type:o,handler:l})=>{s.removeEventListener(o,l)}),s.close(),e&&window.clearTimeout(e)}},[]),tt(()=>{const e=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const n=X.value;n!=="swarm"&&n!=="warroom"&&n!=="orchestra"||(sn(),Zt(),n==="orchestra"&&Ne(),n==="warroom"&&_t())},5e3);return()=>{window.clearInterval(e)}},[]),i`
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
              onClick=${()=>{ge(()=>Uf())}}
              disabled=${ut("dispatch:tick")}
            >
              ${ut("dispatch:tick")?"정리 중...":"Tick 실행"}
            </button>
            <button
              class="control-btn ghost"
              onClick=${()=>{ze(),sn(),qe(),Zt(),X.value==="warroom"&&_t()}}
              disabled=${Ea.value}
            >
              ${Ea.value?"새로고침 중...":"새로고침"}
            </button>
            <button
              class="control-btn ghost"
              onClick=${()=>{Kt("warroom"),at("command",{...Ps("warroom"),presentation:"wallboard"})}}
            >
              Wallboard
            </button>
          </div>
        </div>
      `}

      ${za.value?i`<div class="empty-state error">${za.value}</div>`:null}
      ${Na.value?i`<div class="empty-state error">${Na.value}</div>`:null}
      ${t?null:i`<${vt} surfaceId="command" />`}
      ${t?null:i`<${Sr} />`}
      ${t?null:i`<${_h} />`}
      ${t||X.value==="warroom"?null:i`<${vh} />`}
      ${t?null:i`<${Ky} />`}
      <${By} wallboard=${t} />
    </section>
  `}function Hy(){var k;const t=It.value,e=rr.value,n=(t==null?void 0:t.room)??{},s=ci(t),a=s.items,o=s.confirm_required_actions,l=s.actor_filter,c=s.hidden_count,d=s.hidden_actors,p=(t==null?void 0:t.recent_messages)??[],m=(e==null?void 0:e.recommended_actions)??[],f=(k=e==null?void 0:e.active_recommended_actions)!=null&&k.length?e.active_recommended_actions:m,h=e==null?void 0:e.active_summary,y=(e==null?void 0:e.resident_judge_runtime)??(t==null?void 0:t.resident_judge_runtime),C=(e==null?void 0:e.active_guidance_layer)??"fallback",_=p.slice(0,5);return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Room 개입</div>
          <${B} panelId="intervene.action_studio" compact=${!0} />
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
          <div class="ops-stat ${fu(y)}">
            <span>Resident Judge</span>
            <strong>${vi(y)}</strong>
          </div>
        </div>

        <label class="control-label" for="ops-broadcast">Room 방송</label>
        <div class="control-row">
          <input
            id="ops-broadcast"
            class="control-input"
            type="text"
            placeholder="@agent 또는 room 전체 공지"
            value=${$n.value}
            onInput=${g=>{$n.value=g.target.value}}
            onKeyDown=${g=>{g.key==="Enter"&&Vl()}}
            disabled=${it.value}
          />
          <button class="control-btn" onClick=${()=>{Vl()}} disabled=${it.value||$n.value.trim()===""}>
            보내기
          </button>
        </div>

        <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
        <div class="control-row ops-split-row">
          <input
            id="ops-pause-reason"
            class="control-input"
            type="text"
            value=${Ga.value}
            onInput=${g=>{Ga.value=g.target.value}}
            disabled=${it.value}
          />
          <button class="control-btn ghost" onClick=${()=>{Gh()}} disabled=${it.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{$u()}} disabled=${it.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${hn.value}
          onInput=${g=>{hn.value=g.target.value}}
          disabled=${it.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${cs.value}
          onInput=${g=>{cs.value=g.target.value}}
          disabled=${it.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${ds.value}
            onChange=${g=>{ds.value=g.target.value}}
            disabled=${it.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{Jh()}} disabled=${it.value||hn.value.trim()===""}>
            주입
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">추천 개입</div>
          <${B} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
        <article class="ops-guidance-card ${Ya(C)}">
          <div class="ops-guidance-head">
            <strong>${Ar(C)}</strong>
            <span>${(y==null?void 0:y.keeper_name)??(e==null?void 0:e.judgment_owner)??"judge 없음"}</span>
          </div>
          <div class="ops-guidance-body">
            ${(h==null?void 0:h.summary)??"현재 active guidance 요약이 없습니다. fallback queue만 표시합니다."}
          </div>
          <div class="ops-guidance-meta">
            <span>authoritative ${e!=null&&e.authoritative_judgment_available?"yes":"no"}</span>
            <span>${Tr(h)}</span>
            ${y!=null&&y.model_used?i`<span>${y.model_used}</span>`:null}
          </div>
        </article>
        ${ss.value&&!e?i`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:f.length>0?i`
          <div class="ops-log-list">
            ${f.map(g=>i`
              <article key=${`${g.action_type}:${g.target_type}:${g.target_id??"room"}`} class="ops-log-entry ${g.severity}">
                <div class="ops-log-head">
                  <strong>${Fe(g.action_type)}</strong>
                  <span>${yn(g.target_type)}${g.target_id?` · ${g.target_id}`:""}</span>
                  <span>${Xa(g.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${g.reason}</div>
                ${g.suggested_payload?i`
                  <div class="ops-confirmation-actions">
                    <button class="control-btn ghost" onClick=${()=>{Hh(g)}} disabled=${it.value}>
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
          <${B} panelId="intervene.pending_confirmations" compact=${!0} />
        </div>
        <p class="ops-context-note">
          ${l?`현재 actor ${l} 기준 queue를 읽습니다. 승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다.`:"승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다."}
        </p>
        ${o.length>0?i`
          <div class="ops-log-list">
            ${o.map(g=>i`
              <article key=${`${g.action_type}:${g.target_type}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${Fe(g.action_type)}</strong>
                  <span>${yn(g.target_type)}</span>
                  <span>${Xa(g.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${g.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}
        ${a.length>0?i`
          <div class="ops-confirmation-list">
            ${a.map(g=>i`
              <article key=${g.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${Fe(g.action_type)}</strong>
                  <span>${yn(g.target_type)}${g.target_id?` · ${g.target_id}`:""}</span>
                  <span>${g.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${g.preview?i`<pre class="ops-code-block compact">${Va(g.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{Yl(g.confirm_token)}} disabled=${it.value}>
                    실행
                  </button>
                  <button class="control-btn ghost" onClick=${()=>{Yl(g.confirm_token,"deny")}} disabled=${it.value}>
                    거부
                  </button>
                  <span class="ops-token">${g.confirm_token}</span>
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
          <${B} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${_.length>0?i`
          <div class="ops-feed-list">
            ${_.map(g=>i`
              <article key=${g.seq??g.id??g.timestamp} class="ops-feed-item">
                <div class="ops-feed-meta">
                  <strong>${g.from}</strong>
                  <span>${g.timestamp}</span>
                </div>
                <div class="ops-feed-content">${g.content}</div>
              </article>
            `)}
          </div>
        `:i`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
      </section>
    </div>
  `}const Ve=$(""),wi=$(!1),Js=$(null);function Wy(){var g;const t=It.value,e=Ht.value,n=(t==null?void 0:t.sessions)??[],s=((t==null?void 0:t.available_actions)??[]).filter(b=>b.target_type==="team_session"),a=n.find(b=>b.session_id===kn.value)??n[0]??null,o=e==null?void 0:e.active_summary,l=(e==null?void 0:e.active_guidance_layer)??"fallback",c=(e==null?void 0:e.resident_judge_runtime)??(t==null?void 0:t.resident_judge_runtime),d=(a==null?void 0:a.linked_autoresearch)??null,p=it.value||wi.value,m=(g=e==null?void 0:e.active_recommended_actions)!=null&&g.length?e.active_recommended_actions:(e==null?void 0:e.recommended_actions)??[],f=async()=>{await _t(),a!=null&&a.session_id&&await ye(a.session_id)},h=async b=>{wi.value=!0,Js.value=null;try{await b(),await f()}catch(R){Js.value=R instanceof Error?R.message:"Autoresearch action failed"}finally{wi.value=!1}},y=async()=>{d!=null&&d.loop_id&&await h(()=>Cp(d.loop_id))},C=async()=>{if(!(d!=null&&d.loop_id)||!Ve.value.trim())return;const b=Ve.value.trim();await h(()=>Ap(d.loop_id,b)),Ve.value=""},_=async()=>{d!=null&&d.loop_id&&await h(()=>Tp(d.loop_id))},k=async()=>{d!=null&&d.loop_id&&await h(()=>Ip(d.loop_id,"dashboard stop request"))};return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${B} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(b=>{var R;return i`
            <button
              key=${b.session_id}
              class="ops-entity-card ${(a==null?void 0:a.session_id)===b.session_id?"active":""}"
              onClick=${()=>{kn.value=b.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${b.session_id}</strong>
                <span class="status-badge ${b.status??"idle"}">${rn(b.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(b.progress_pct??0)}%</span>
                <span>${b.done_delta_total??0}건 완료</span>
                <span>${(R=b.team_health)!=null&&R.status?rn(String(b.team_health.status)):"상태 확인 필요"}</span>
              </div>
            </button>
          `})}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Session 요약</div>
          <${B} panelId="intervene.session_digest" compact=${!0} />
        </div>
        <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
        ${a&&e?i`
          <article class="ops-guidance-card ${Ya(l)}">
            <div class="ops-guidance-head">
              <strong>${Ar(l)}</strong>
              <span>${vi(c)}</span>
            </div>
            <div class="ops-guidance-body">
              ${(o==null?void 0:o.summary)??"현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다."}
            </div>
            <div class="ops-guidance-meta">
              <span>authoritative ${e.authoritative_judgment_available?"yes":"no"}</span>
              <span>${Tr(o)}</span>
              ${c!=null&&c.model_used?i`<span>${c.model_used}</span>`:null}
            </div>
          </article>
          ${m.length>0?i`
            <div class="ops-log-list">
              ${m.map(b=>i`
                <article key=${`${b.action_type}:${b.target_type}:${b.target_id??"session"}`} class="ops-log-entry ${b.severity}">
                  <div class="ops-log-head">
                    <strong>${Fe(b.action_type)}</strong>
                    <span>${yn(b.target_type)}${b.target_id?` · ${b.target_id}`:""}</span>
                  </div>
                  <div class="ops-log-body">${b.reason}</div>
                </article>
              `)}
            </div>
          `:null}
          <div class="ops-log-list">
            ${e.attention_items.length>0?e.attention_items.map(b=>i`
              <article key=${`${b.kind}:${b.target_id??"session"}`} class="ops-log-entry ${b.severity}">
                <div class="ops-log-head">
                  <strong>${b.kind}</strong>
                  <span>${yn(b.target_type)}${b.target_id?` · ${b.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${b.summary}</div>
              </article>
            `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${e.worker_cards.length>0?e.worker_cards.map(b=>i`
              <article key=${`${b.actor??b.spawn_role??"worker"}:${b.spawn_agent??b.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${b.actor??b.spawn_role??"worker"}</strong>
                  <span>${rn(b.status)}</span>
                  <span>${b.spawn_agent??b.runtime_pool??"runtime 확인 필요"}</span>
                </div>
                <div class="ops-log-body">
                  ${b.worker_class??"worker"}${b.lane_id?` · ${b.lane_id}`:""}${b.routing_reason?` · ${b.routing_reason}`:""}
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
          <${B} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>
        ${s.length>0?i`
          <div class="ops-log-list">
            ${s.map(b=>i`
              <article key=${b.action_type} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${Fe(b.action_type)}</strong>
                  <span>${Xa(b.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${b.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}

        ${a?i`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${a.session_id}</div>
            <div class="ops-detail-meta">
              <span>상태: ${rn(a.status)}</span>
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
              <div class="ops-detail-meta">
                <span>파일: ${a.linked_autoresearch.target_file??"n/a"}</span>
                <span>최근 결정: ${a.linked_autoresearch.last_decision??"n/a"}</span>
                <span>세션 연결: ${a.linked_autoresearch.session_id??a.session_id}</span>
                ${a.linked_autoresearch.operation_id?i`<span>작전: ${a.linked_autoresearch.operation_id}</span>`:null}
              </div>
              ${a.linked_autoresearch.program_note?i`<div class="ops-context-note">Program note: ${a.linked_autoresearch.program_note}</div>`:null}
              ${a.linked_autoresearch.queued_hypothesis?i`<div class="ops-context-note">Queued hypothesis: ${a.linked_autoresearch.queued_hypothesis}</div>`:null}
              ${a.linked_autoresearch.warnings&&a.linked_autoresearch.warnings.length>0?i`<div class="ops-context-note">Warnings: ${a.linked_autoresearch.warnings.join(", ")}</div>`:null}
              ${a.linked_autoresearch.error?i`<div class="ops-empty">${a.linked_autoresearch.error}</div>`:null}
            `:null}
            ${a.recent_events&&a.recent_events.length>0?i`
              <pre class="ops-code-block compact">${Va(a.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        ${d!=null&&d.loop_id?i`
          <label class="control-label" for="ops-autoresearch-hypothesis">Autoresearch 제어</label>
          <div class="control-row ops-split-row">
            <button class="control-btn ghost" onClick=${()=>{y()}} disabled=${p}>
              상태 새로고침
            </button>
            <button class="control-btn" onClick=${()=>{_()}} disabled=${p}>
              1 cycle 실행
            </button>
            <button class="control-btn ghost" onClick=${()=>{k()}} disabled=${p}>
              loop 중지
            </button>
          </div>
          <textarea
            id="ops-autoresearch-hypothesis"
            class="control-textarea"
            rows=${2}
            placeholder="다음 cycle에 넣을 hypothesis"
            value=${Ve.value}
            onInput=${b=>{Ve.value=b.target.value}}
            disabled=${p}
          ></textarea>
          <div class="control-row ops-split-row">
            <button class="control-btn" onClick=${()=>{C()}} disabled=${p||!Ve.value.trim()}>
              hypothesis 주입
            </button>
            <span class="ops-context-note">canonical control은 MCP tool이고, 이 화면은 그 상태를 읽고 이어서 제어합니다.</span>
          </div>
          ${Js.value?i`<div class="ops-empty">${Js.value}</div>`:null}
        `:null}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${At.value}
            onChange=${b=>{At.value=b.target.value}}
            disabled=${p||!a}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
            <option value="worker_spawn_batch">worker 교체</option>
          </select>
          <button class="control-btn" onClick=${()=>{Vh()}} disabled=${p||!a}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${Fh(At.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${us.value}
          onInput=${b=>{us.value=b.target.value}}
          disabled=${p||!a}
        ></textarea>

        ${At.value==="task"?i`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${ps.value}
            onInput=${b=>{ps.value=b.target.value}}
            disabled=${p||!a}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${ms.value}
            onInput=${b=>{ms.value=b.target.value}}
            disabled=${p||!a}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${_s.value}
            onChange=${b=>{_s.value=b.target.value}}
            disabled=${p||!a}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
        `:At.value==="worker_spawn_batch"?i`
          <textarea
            class="control-textarea"
            rows=${6}
            placeholder='spawn_batch JSON, 예: [{"spawn_agent":"llama","spawn_prompt":"...", "spawn_role":"replacement"}]'
            value=${vs.value}
            onInput=${b=>{vs.value=b.target.value}}
            disabled=${p||!a}
          ></textarea>
        `:null}

        <div class="control-row ops-split-row">
          <input
            class="control-input"
            type="text"
            value=${Ja.value}
            onInput=${b=>{Ja.value=b.target.value}}
            disabled=${p||!a}
          />
          <button class="control-btn ghost" onClick=${()=>{Yh()}} disabled=${p||!a}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function Gy(){var o;const t=It.value,e=(t==null?void 0:t.keepers)??[],n=(t==null?void 0:t.persistent_agents)??[],s=(t==null?void 0:t.available_actions)??[],a=e.find(l=>l.name===Po.value)??e[0]??null;return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${B} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${e.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:e.map(l=>i`
            <button
              key=${l.name}
              class="ops-entity-card ${(a==null?void 0:a.name)===l.name?"active":""}"
              onClick=${()=>{Po.value=l.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${l.name}</strong>
                <span class="status-badge ${l.status??"idle"}">${rn(l.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${l.model??"model 확인 필요"}</span>
                <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${Gl(l.last_turn_ago_s)}</span>
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
                    <span class="status-badge ${l.status??"idle"}">${rn(l.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>persistent</span>
                    <span>${l.model??"model 확인 필요"}</span>
                    <span>${Gl(l.last_turn_ago_s)}</span>
                  </div>
                </article>
              `)}
        </div>
      </section>

      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Keeper 액션</div>
          <${B} panelId="intervene.action_studio" compact=${!0} />
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
          <${nu}
            keeperName=${a.name}
            placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
          />
        `:i`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">가능한 액션 목록</div>
          <${B} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
        <div class="ops-log-list">
          ${s.length?s.map(l=>i`
                <article key=${`${l.action_type}:${l.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${Fe(l.action_type)}</strong>
                    <span>${yn(l.target_type)}</span>
                    <span>${Xa(l.confirm_required)}</span>
                  </div>
                  <div class="ops-log-body">${l.description??"설명이 아직 없습니다."}</div>
                </article>
              `):i`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 개입 로그</div>
          <${B} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <div class="ops-log-list">
          ${Ia.value.length===0?i`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:Ia.value.map(l=>i`
            <article key=${l.id} class="ops-log-entry ${l.outcome}">
              <div class="ops-log-head">
                <strong>${Fe(l.action_type)}</strong>
                <span>${l.target_label}</span>
                <span>${l.at}</span>
              </div>
              <div class="ops-log-body">${l.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function Jy(){var R,L;const t=It.value,e=K.value.tab==="intervene"?Rs(K.value):null,n=rr.value,s=(t==null?void 0:t.room)??{},a=(t==null?void 0:t.sessions)??[],o=(t==null?void 0:t.keepers)??[],l=ci(t),c=l.visible_count,d=l.total_count,p=l.hidden_count,m=l.actor_filter,f=a.find(S=>S.session_id===kn.value)??a[0]??null,h=(n==null?void 0:n.attention_items)??[],y=h.filter(Dh),C=h.filter(qh),_=a.filter(S=>Oh(S)!=="ok"),k=o.filter(S=>zi(S)!=="ok"),g=Wh(e,a,o);tt(()=>{Be()},[]),tt(()=>{if(K.value.tab!=="intervene"){Gs.value=null;return}if(!e){Gs.value=null;return}Gs.value!==e.id&&(Gs.value=e.id,Uh(e))},[K.value.tab,K.value.params.source,K.value.params.action_type,K.value.params.target_type,K.value.params.target_id,K.value.params.focus_kind,e==null?void 0:e.id]),tt(()=>{const S=(f==null?void 0:f.session_id)??null;ye(S)},[f==null?void 0:f.session_id]);const b=[{key:"room",label:"방 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:p>0?`${c}/${d}`:c,detail:c>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":p>0&&m?`현재 개입 ID(${m}) 기준으로는 비어 있고, 다른 개입 ID 대기 ${p}건이 있습니다`:"지금 막혀 있는 확인 대기는 없습니다",tone:d>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:y.length>0?y.length:a.length,detail:y.length>0?((R=y[0])==null?void 0:R.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 팀 세션이 없습니다":"세션 쪽 긴급 주의 신호는 현재 없습니다",tone:y.length>0?Jl(y):a.length===0?"warn":_.some(S=>xn(S.status)==="paused")?"bad":_.length>0?"warn":"ok"},{key:"keeper",label:"키퍼 압력",value:C.length>0?C.length:k.length,detail:C.length>0?((L=C[0])==null?void 0:L.summary)??"직접 메시지나 상태 점검이 필요한 키퍼가 있습니다":k.length>0?"오래됐거나 오프라인이거나 텔레메트리가 비는 키퍼가 보입니다":"지금은 키퍼 쪽이 비교적 안정적입니다",tone:C.length>0?Jl(C):k.some(S=>zi(S)==="bad")?"bad":k.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${vt} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">개입</div>
            <${B} panelId="intervene.action_studio" compact=${!0} />
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
            value=${_i.value}
            onInput=${S=>jh(S.target.value)}
          />
            <button
              class="control-btn ghost"
              onClick=${()=>{ze(),_t(),Be(),ye((f==null?void 0:f.session_id)??null)}}
            disabled=${ns.value||it.value}
          >
            ${ns.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${he.value?i`<section class="ops-banner error">${he.value}</section>`:null}
      ${bn.value?i`<section class="ops-banner error">${bn.value}</section>`:null}
      <${Sr} />
      ${e?i`
        <section class="ops-banner ${g?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${ui(e.action_type)}</span>
            <span>${gr(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?i`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${g?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const S=[];if((c>0||p>0)&&S.push({label:p>0?`확인 대기 ${c}/${d}건 확인`:`확인 대기 ${c}건 처리`,desc:p>0&&m?`현재 개입 ID(${m}) 기준으로 보이는 대기열을 먼저 확인합니다`:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:c>0?"bad":"warn",onClick:()=>{const M=document.querySelector(".ops-pending-section");M==null||M.scrollIntoView({behavior:"smooth"})}}),s.paused&&S.push({label:"방 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void $u()}),k.length>0){const M=k.filter(I=>zi(I)==="bad");S.push({label:M.length>0?`오프라인 키퍼 ${M.length}개`:`점검이 필요한 키퍼 ${k.length}개`,desc:M.length>0?"메시지를 보내거나 상태를 확인하세요":"오래됐거나 텔레메트리가 비어 있습니다",tone:M.length>0?"bad":"warn",onClick:()=>{const I=document.querySelector(".ops-keeper-section");I==null||I.scrollIntoView({behavior:"smooth"})}})}return S.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${S.slice(0,3).map(M=>i`
                <button class="ops-action-guide-item ${M.tone}" onClick=${M.onClick}>
                  <strong>${M.label}</strong>
                  <span>${M.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `})()}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${B} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 방인지, 세션인지, 키퍼인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${b.map(S=>i`
            <div key=${S.key} class="ops-priority-card ${S.tone}">
              <span class="ops-priority-label">${S.label}</span>
              <strong>${S.value}</strong>
              <div class="ops-priority-detail">${S.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${Hy} />
        <${Wy} />
        <${Gy} />
      </div>
    </section>
  `}function Vy({text:t}){if(!t)return null;const e=Yy(t);return i`<div class="markdown-content">${e}</div>`}function Yy(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(l);)d.push(e[s]),s++;s++,n.push(i`<pre><code class=${c?`language-${c}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<e.length&&!e[s].includes("</think>");)l.push(e[s]),s++;if(s<e.length){const p=e[s].replace("</think>","").trim();p&&l.push(p),s++}const d=l.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Ni(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<e.length&&e[s].startsWith("> ");)l.push(e[s].slice(2)),s++;n.push(i`<blockquote>${Ni(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<e.length;){const l=e[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;o.push(l),s++}o.length>0&&n.push(i`<p>${Ni(o.join(`
`))}</p>`)}return n}function Ni(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);e.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);e.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);e.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&e.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Tu=[{id:"recent",label:"최신순"},{id:"hot",label:"인기순"},{id:"trending",label:"급상승"},{id:"updated",label:"최근 갱신"},{id:"discussed",label:"토론 많은 순"}],_a=$(null),va=$([]),Sn=$(!1),De=$(null),Wn=$(""),Gn=$(!1),cn=$(!0),Rr=20,Ze=$(Rr);function Xy(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Qy=$(Xy());function Zy(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"미리보기 없음"}function Zl(t){return t.updated_at!==t.created_at}function tb(t){if(t.post_kind)return t.post_kind==="automation";const e=(t.hearth??"").toLowerCase();return t.visibility!=="internal"||!t.expires_at||!e?!1:!!(e.startsWith("mdal")||e.includes("harness"))}function eb(t){return t==="lodge-system"||t==="team-session"}function fs(t){return t.post_kind?t.post_kind:eb(t.author)?"system":tb(t)?"automation":"human"}function Iu(t){const e=[],n=[];let s=0;return t.forEach(a=>{const o=fs(a);if(!(o==="system"&&Ee.value)){if(o==="automation"&&cn.value){s+=1;return}if(o==="human"){e.push(a);return}n.push(a)}}),{human:e,operations:n,hiddenAutomation:s}}function nb(t){if(!t.expires_at)return null;const e=Date.parse(t.expires_at);return Number.isFinite(e)?e<=Date.now()?i`<span class="board-meta-chip">만료됨</span>`:i`<span class="board-meta-chip">만료까지 <${Z} timestamp=${t.expires_at} /></span>`:null}async function Mr(t){De.value=t,_a.value=null,va.value=[],Sn.value=!0;try{const e=await mm(t);if(De.value!==t)return;_a.value={id:e.id,author:e.author,title:e.title,body:e.body,content:e.content,meta:e.meta,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,post_kind:e.post_kind,flair:e.flair,hearth:e.hearth,visibility:e.visibility,expires_at:e.expires_at,hearth_count:e.hearth_count},va.value=e.comments??[]}catch{De.value===t&&(_a.value=null,va.value=[])}finally{De.value===t&&(Sn.value=!1)}}async function tc(t){const e=Wn.value.trim();if(e){Gn.value=!0;try{await _m(t,Qy.value,e),Wn.value="",O("댓글을 등록했습니다","success"),await Mr(t),_e()}catch{O("댓글 등록에 실패했습니다","error")}finally{Gn.value=!1}}}function sb(){const t=ts.value,e=cn.value?"자동화 글 숨김":"자동화 글 표시 중";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Tu.map(n=>i`
          <button
            class="board-sort-btn ${t===n.id?"active":""}"
            onClick=${()=>{ts.value=n.id,Ze.value=Rr,_e()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${cn.value?"is-active":""}"
          onClick=${()=>{cn.value=!cn.value}}
        >
          ${e}
        </button>
        <button
          class="control-btn ghost ${Ee.value?"is-active":""}"
          onClick=${()=>{Ee.value=!Ee.value,_e()}}
        >
          ${Ee.value?"시스템 글 숨김":"시스템 글 표시 중"}
        </button>
        <button class="control-btn ghost" onClick=${_e} disabled=${es.value}>
          ${es.value?"새로고침 중...":"새로고침"}
        </button>
      </div>
    </div>
  `}function ji(){var s;const t=((s=Tu.find(a=>a.id===ts.value))==null?void 0:s.label)??ts.value,e=Iu(li.value),n=e.human.length+e.operations.length;return i`
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
        <strong>${cn.value?`자동화 ${e.hiddenAutomation}건 숨김`:"분리된 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">시스템 글 정책</span>
        <strong>${Ee.value?"시스템 글 숨김":"시스템 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">최근 갱신</span>
        <strong>${yo.value?i`<${Z} timestamp=${yo.value} />`:"아직 불러오지 않음"}</strong>
      </div>
    </div>
  `}function ec({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Oc(t.id,n),_e()}catch{O("투표에 실패했습니다","error")}};return i`
    <div class="board-post" onClick=${()=>tp(t.id)}>
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
                ${Zl(t)?i`<span class="board-meta-chip">수정됨</span>`:null}
                ${fs(t)!=="human"?i`<span class="board-meta-chip">${fs(t)}</span>`:null}
                ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>작성자 ${t.author}</span>
            <span><${Z} timestamp=${t.created_at} /></span>
            ${Zl(t)?i`<span>수정 <${Z} timestamp=${t.updated_at} /></span>`:null}
            <span>댓글 ${t.comment_count}</span>
            <span>투표 ${t.votes??0}</span>
          </div>
        </div>
        <div class="post-snippet">${Zy(t.body)}</div>
      </div>
    </div>
  `}function ab({comments:t}){return t.length===0?i`<div class="empty-state" style="font-size:13px">아직 댓글이 없습니다</div>`:i`
    <div class="comment-thread">
      ${t.map(e=>i`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${Z} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function ib({postId:t}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="댓글 추가..."
        value=${Wn.value}
        onInput=${e=>{Wn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&tc(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Gn.value}
      />
      <button
        onClick=${()=>tc(t)}
        disabled=${Gn.value||Wn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Gn.value?"...":"등록"}
      </button>
    </div>
  `}function ob({post:t}){De.value!==t.id&&!Sn.value&&Mr(t.id);const e=async n=>{try{await Oc(t.id,n),_e()}catch{O("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>at("memory")}>← 메모리로 돌아가기</button>
      <${E} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${Vy} text=${t.body} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${Z} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          ${t.hearth||t.visibility||t.expires_at?i`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${t.hearth?i`<span class="board-meta-chip">${t.hearth}</span>`:null}
                  ${t.visibility?i`<span class="board-meta-chip">${t.visibility}</span>`:null}
                  ${fs(t)!=="human"?i`<span class="board-meta-chip">${fs(t)}</span>`:null}
                  ${nb(t)}
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

      <${E} title="댓글" semanticId="memory.feed">
        ${Sn.value?i`<div class="loading-indicator">댓글 불러오는 중...</div>`:i`<${ab} comments=${va.value} />`}
        <${ib} postId=${t.id} />
      <//>
    </div>
  `}function rb(){const t=Iu(li.value),e=[...t.human,...t.operations],n=K.value.params.post??null,s=n?e.find(a=>a.id===n)??(De.value===n?_a.value:null):null;return n&&!s&&De.value!==n&&!Sn.value&&Mr(n),n?s?i`
          <${vt} surfaceId="memory" />
          <${ji} />
          <${ob} post=${s} />
        `:i`
          <div>
            <${vt} surfaceId="memory" />
            <${ji} />
            <button class="back-btn" onClick=${()=>at("memory")}>← 메모리로 돌아가기</button>
            ${Sn.value?i`<div class="loading-indicator">글 불러오는 중...</div>`:i`<div class="empty-state">글을 찾지 못했습니다</div>`}
          </div>
        `:i`
    <div>
      <${vt} surfaceId="memory" />
      <${ji} />
      <${sb} />
      ${es.value?i`<div class="loading-indicator">메모리 피드 불러오는 중...</div>`:e.length===0?i`<div class="empty-state">지금은 남아 있는 메모리 글이 없습니다</div>`:i`
              <${E} title="사람이 쓴 글" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.human.slice(0,Ze.value).map(a=>i`<${ec} key=${a.id} post=${a} />`)}
                </div>
                ${t.human.length>Ze.value?i`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{Ze.value=Ze.value+Rr}}
                    >
                      더 보기 (${t.human.length-Ze.value}개 남음)
                    </button>
                  </div>
                `:null}
              <//>
              ${t.operations.length>0?i`
                    <${E} title="자동화 · 시스템" class="section" semanticId="memory.feed">
                      <div class="board-post-list">
                        ${t.operations.map(a=>i`<${ec} key=${a.id} post=${a} />`)}
                      </div>
                    <//>
                  `:null}
            `}
    </div>
  `}function lb({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,o=2*Math.PI*s,l=o*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),i`
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
  `}function cb(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function nc(t,e="없음"){return!t||t.length===0?e:t.slice(0,4).join(", ")}function db({model:t,onClick:e,variant:n,testId:s}){var c,d,p,m;const a=!!t.recentEvent||!!t.recentInput||!!t.recentOutput||!!t.routeSummary||!!t.auditSource||!!t.auditAt||(((c=t.recentTools)==null?void 0:c.length)??0)>0||(((d=t.allowedTools)==null?void 0:d.length)??0)>0,o=n==="mission"?`mission-activity-card ${t.tone}`:"keeper-canonical-card",l=n==="mission"?"mission-card-select":`monitor-row ${t.tone}${t.stateClass?` state-${t.stateClass}`:""}`;return i`
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
                <${lb} ratio=${t.contextRatio??0} size=${34} stroke=${4} />
                <${ke} status=${t.statusRaw??"unknown"} />
                ${t.stateLabel?i`<span class="monitor-pill ${t.tone}">${t.stateLabel}</span>`:null}
              `:i`<span class="command-chip ${t.tone}">${t.statusLabel}</span>`}
        </div>

        <div class=${n==="mission"?"mission-activity-meta":"monitor-meta"}>
          ${t.lastActivityAt?i`<span>최근 활동 <${Z} timestamp=${t.lastActivityAt} /></span>`:i`<span>${t.lastActivityFallback??"최근 활동 없음"}</span>`}
          ${t.relatedSessionId?i`<span>세션 · ${t.relatedSessionId}</span>`:null}
          ${t.continuity?i`<span>${t.continuity}</span>`:null}
          ${t.lifecycle?i`<span>생애주기 ${t.lifecycle}</span>`:null}
          <span>컨텍스트 ${cb(t.contextRatio)}</span>
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
                ${t.auditAt?i`<span><${Z} timestamp=${t.auditAt} /></span>`:null}
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
              ${(((p=t.recentTools)==null?void 0:p.length)??0)>0||(((m=t.allowedTools)==null?void 0:m.length)??0)>0?i`
                    <div class="mission-activity-foot">
                      <span>최근 도구 · ${nc(t.recentTools)}</span>
                      <span>허용 도구 · ${nc(t.allowedTools)}</span>
                    </div>
                  `:null}
            </details>
          `:null}
    </article>
  `}const Me=$(null),Xt=$(null),Qt=$(null);function gs(t){return t==="bad"||t==="critical"||t==="offline"?"bad":t==="warn"||t==="paused"||t==="blocked"||t==="interrupted"?"warn":"ok"}function $s(t){switch((t??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":return"주의";case"bad":case"critical":return"위험";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function ub(t){return t==="session"?"세션":"작전"}function pb(t){return t?ie.value.find(e=>e.name===t||e.agent_name===t)??null:null}function mb(t){switch(t){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function _b(t){switch(t){case"live":return"최근 신호(≤5m)";case"stale":return"오래된 신호(>5m)";case"absent":return"signal 없음";default:return t??"signal 미상"}}function vb(t){switch(t){case"message":return"최근 출력";case"presence":return"presence/하트비트";case"none":return"근거 없음";default:return t??"근거 미상"}}function fb(t){switch(t){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function gb(t){switch(t){case"acted":return"행동";case"passed":return"판단 패스";case"skipped":return"시스템 스킵";case"failed":return"실패";default:return t}}function $b(t){switch(t){case"post":return"post";case"comment":return"comment";case"vote":return"vote";case"none":case null:case void 0:return"없음";default:return t}}function sc(t){if(!t)return;const e=sg({targetType:t.target_type,targetId:t.target_id,focusKind:t.focus_kind,operationId:t.operation_id??null,commandSurface:t.command_surface??null,sourceLabel:"실행 진단",summary:t.label});Kd(e),at(t.surface,t.surface==="intervene"?Bd(e):Hd(e))}function wn({label:t,value:e,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function Lr({intervene:t,command:e}){return i`
    <div class="control-row">
      ${t?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),sc(t)}}
            >
              ${t.label}
            </button>
          `:null}
      ${e?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),sc(e)}}
            >
              ${e.label}
            </button>
          `:null}
    </div>
  `}function hb({item:t,selected:e}){return i`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{Me.value=e?null:t.id,Xt.value=null,Qt.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.kind==="session"?t.target_id:t.linked_session_id??t.target_id}</div>
          <div class="mission-card-title">${t.summary}</div>
        </div>
        <span class="command-chip ${gs(t.severity)}">${$s(t.status??t.severity)}</span>
      </div>
      <div class="mission-card-meta">
        <span>${ub(t.kind)}</span>
        ${t.linked_operation_id?i`<span>연결 작전 · ${t.linked_operation_id}</span>`:null}
        ${t.last_seen_at?i`<span><${Z} timestamp=${t.last_seen_at} /></span>`:null}
      </div>
      <${Lr} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function yb({brief:t,selected:e}){const n=t.active_count??0,s=t.seen_count??n,a=t.planned_count??t.member_names.length;return i`
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
        <span class="command-chip ${gs(t.health??t.status)}">${$s(t.status)}</span>
      </div>
      <div class="mission-card-meta">
        <span>건강도 · ${$s(t.health??"ok")}</span>
        <span>live ${n} · seen ${s} · planned ${a}</span>
        ${t.linked_operation_id?i`<span>연결 작전 · ${t.linked_operation_id}</span>`:null}
        ${t.last_activity_at?i`<span><${Z} timestamp=${t.last_activity_at} /></span>`:null}
      </div>
      ${t.runtime_blocker?i`<div class="mission-card-detail">${t.runtime_blocker}</div>`:t.last_activity_summary?i`<div class="mission-card-detail">${t.last_activity_summary}</div>`:null}
      <div class="monitor-footnote">
        ${t.worker_gap_summary??`관측 기준 · ${t.counts_basis??"recent_turns"}`}
      </div>
      <${Lr} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function bb({brief:t,selected:e}){return i`
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
        <span class="command-chip ${gs(t.blocker_summary?"warn":t.status)}">${$s(t.status)}</span>
      </div>
      <div class="mission-card-meta">
        ${t.stage?i`<span>단계 · ${t.stage}</span>`:null}
        ${t.linked_session_id?i`<span>세션 · ${t.linked_session_id}</span>`:null}
        ${t.updated_at?i`<span><${Z} timestamp=${t.updated_at} /></span>`:null}
      </div>
      ${t.blocker_summary?i`<div class="mission-card-detail">${t.blocker_summary}</div>`:null}
      ${t.next_tool?i`<div class="monitor-footnote">다음 도구 · ${t.next_tool}</div>`:null}
      <${Lr} command=${t.command_handoff} />
    </button>
  `}function kb({tick:t}){return t?i`
    <div class="monitor-nested-card">
      <div class="stats-grid">
        <${wn} label="검토" value=${t.checked??0} color="#22d3ee" />
        <${wn} label="행동" value=${t.acted??0} color="#4ade80" />
        <${wn} label="판단 패스" value=${t.passed??0} color="#94a3b8" />
        <${wn} label="시스템 스킵" value=${t.skipped??0} color="#fbbf24" />
        <${wn} label="실패" value=${t.failed??0} color="#fb7185" />
      </div>
      <div class="monitor-meta">
        ${t.last_tick_at?i`<span>마지막 tick <${Z} timestamp=${t.last_tick_at} /></span>`:i`<span>마지막 tick 없음</span>`}
        ${t.strategy?i`<span>전략 · ${t.strategy}</span>`:null}
        ${t.queue_depth!=null?i`<span>큐 · ${t.queue_depth}</span>`:null}
        ${t.last_pass_reason?i`<span>대표 패스 이유 · ${t.last_pass_reason}</span>`:null}
        ${t.last_system_skip_reason?i`<span>대표 시스템 스킵 이유 · ${t.last_system_skip_reason}</span>`:t.last_skip_reason?i`<span>대표 시스템 스킵 이유 · ${t.last_skip_reason}</span>`:null}
      </div>
      ${t.activity_report?i`<div class="monitor-footnote">${t.activity_report}</div>`:null}
    </div>
  `:i`<div class="empty-state">최근 social activity 기록이 없습니다.</div>`}function xb({row:t}){return i`
    <button
      class="monitor-row ${gs(t.outcome==="failed"?"bad":t.outcome==="skipped"?"warn":"ok")}"
      data-testid="execution.lodge-checkin-card"
      onClick=${()=>Ls(t.agent_name)}
    >
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.agent_name}</span>
            ${t.worker_name?i`<span class="monitor-sub">worker · ${t.worker_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.reason??t.summary??"이유가 기록되지 않았습니다."}</div>
        </div>
        <span class="monitor-pill ${gs(t.outcome==="failed"?"bad":t.outcome==="skipped"?"warn":"ok")}">${gb(t.outcome)}</span>
      </div>
        <div class="monitor-meta">
        <span>trigger · ${t.trigger??"unknown"}</span>
        ${t.checked_at?i`<span><${Z} timestamp=${t.checked_at} /></span>`:null}
        <span>action · ${$b(t.action_kind)}</span>
      </div>
      ${t.summary&&t.summary!==t.reason?i`<div class="monitor-focus">${t.summary}</div>`:null}
      ${t.failure_reason||t.decision_reason?i`<div class="monitor-footnote">
            ${t.failure_reason?`실패 이유: ${t.failure_reason}`:`판단 이유: ${t.decision_reason}`}
          </div>`:null}
    </button>
  `}function ac({row:t,testId:e}){return i`
    <button class="monitor-row ${t.tone} state-${t.state}" data-testid=${e} onClick=${()=>Ls(t.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.name}</span>
            ${t.korean_name?i`<span class="monitor-sub">${t.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${ke} status=${t.status??"unknown"} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${mb(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.last_signal_at?i`<span>신호 <${Z} timestamp=${t.last_signal_at} /></span>`:i`<span>최근 신호 없음</span>`}
        <span>${_b(t.signal_truth)} · ${vb(t.evidence_source)}</span>
        ${typeof t.last_signal_age_sec=="number"?i`<span>${t.last_signal_age_sec}s ago</span>`:null}
        <span>${(t.active_task_count??0)>0?`활성 작업 ${t.active_task_count}개`:"활성 작업 없음"}</span>
        ${t.related_session_id?i`<span>세션 · ${t.related_session_id}</span>`:null}
        ${t.related_operation_id?i`<span>작전 · ${t.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${t.recent_output_preview&&t.recent_output_preview!==t.focus?i`<div class="monitor-footnote">최근 상세: ${t.recent_output_preview}</div>`:null}
    </button>
  `}function Sb({row:t}){const e=()=>{const a=pb(t.name);a&&su(a)},n=Ag(t.name,t.agent_name),s={name:t.name,koreanName:t.korean_name??null,runtimeLabel:n,emoji:t.emoji??null,tone:t.tone,statusRaw:t.status??null,statusLabel:$s(t.status),stateClass:t.state,stateLabel:fb(t.state),contextRatio:t.context_ratio??null,note:t.note,focus:t.focus,lastActivityAt:t.last_signal_at??null,lastActivityFallback:"최근 활동 없음",relatedSessionId:t.related_session_id??null,continuity:t.continuity??null,lifecycle:t.lifecycle??null,summary:t.continuity_summary??t.recent_output_preview??null,recentInput:t.recent_input_preview??null,recentOutput:t.recent_output_preview??null,recentTools:t.recent_tool_names??[],allowedTools:t.allowed_tool_names??[],routeSummary:t.skill_route_summary??null,auditSource:t.tool_audit_source??null,auditAt:t.tool_audit_at??null,disclosureLabel:"연속성 상세"};return i`<${db}
    variant="execution"
    model=${s}
    onClick=${e}
    testId="execution.continuity-card"
  />`}function Cb(){const t=Uc.value,e=Hc.value,n=Wc.value,s=Gc.value,a=Jc.value,o=Vc.value,l=er.value,c=Yc.value;Me.value&&!t.some(g=>g.id===Me.value)&&(Me.value=null),Xt.value&&!e.some(g=>g.session_id===Xt.value)&&(Xt.value=null),Qt.value&&!n.some(g=>g.operation_id===Qt.value)&&(Qt.value=null);const d=Me.value?t.find(g=>g.id===Me.value)??null:null,p=Xt.value?Xt.value:d?d.kind==="session"?d.target_id:d.linked_session_id??null:null,m=Qt.value?Qt.value:d?d.kind==="operation"?d.target_id:d.linked_operation_id??null:null,f=p?e.filter(g=>g.session_id===p):m?e.filter(g=>g.linked_operation_id===m):e,h=m?n.filter(g=>g.operation_id===m):p?n.filter(g=>{var b;return g.linked_session_id===p||g.operation_id===((b=f[0])==null?void 0:b.linked_operation_id)}):n,y=p||m?s.filter(g=>(p?g.related_session_id===p:!1)||(m?g.related_operation_id===m:!1)):s,C=p?l.filter(g=>g.related_session_id===p||g.tone!=="ok"):l,_=p?o.filter(g=>f.some(b=>b.member_names.includes(g.agent_name))):o,k=p||m?c.filter(g=>(p?g.related_session_id===p:!1)||(m?g.related_operation_id===m:!1)||g.tone!=="ok"):c;return i`
    <div class="agents-monitor">
      <${vt} surfaceId="execution" />
      <${Sr} />
      <${E}
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
          ${t.length===0?i`<div class="empty-state">지금은 막힌 실행이 없습니다.</div>`:t.map(g=>i`<${hb} key=${g.id} item=${g} selected=${Me.value===g.id} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${E}
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
            ${f.length===0?i`<div class="empty-state">선택된 실행과 연결된 세션이 없습니다.</div>`:f.map(g=>i`<${yb} key=${g.session_id} brief=${g} selected=${Xt.value===g.session_id} />`)}
          </div>
        <//>

        <${E}
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
            ${h.length===0?i`<div class="empty-state">선택된 실행과 연결된 작전이 없습니다.</div>`:h.map(g=>i`<${bb} key=${g.operation_id} brief=${g} selected=${Qt.value===g.operation_id} />`)}
          </div>
        <//>

        <${E}
          title="Social Activity"
          class="section"
          semanticId="execution.lodge"
          testId="execution.lodge-checkins"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Social Activity</h2>
            <p class="monitor-subheadline">최근 public-square 이벤트에서 어떤 keeper가 행동했고, 어떤 keeper가 판단상 패스했으며, 어떤 경우가 시스템에 의해 스킵됐는지 먼저 보여줍니다.</p>
          </div>
          <${kb} tick=${a} />
          <div class="monitor-list">
            ${_.length===0?i`<div class="empty-state">최근 social activity 기록이 없습니다.</div>`:_.map(g=>i`<${xb} key=${`${g.agent_name}-${g.checked_at??g.outcome}`} row=${g} />`)}
          </div>
        <//>

        <${E}
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
            ${y.length===0?i`<div class="empty-state">연결된 작업자가 없습니다.</div>`:y.map(g=>i`<${ac} key=${g.name} row=${g} testId="execution.worker-card" />`)}
          </div>
        <//>

        <${E}
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
            ${C.length===0?i`<div class="empty-state">지금은 연속성 경고가 없습니다.</div>`:C.map(g=>i`<${Sb} key=${g.name} row=${g} />`)}
          </div>
        <//>

        <${E}
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
            ${k.length===0?i`<div class="empty-state">지금은 오프라인 작업자가 없습니다.</div>`:k.map(g=>i`<${ac} key=${g.name} row=${g} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Ab=40;function Tb({items:t,itemHeight:e,overscan:n=5,renderItem:s,getKey:a,className:o=""}){const l=ee(null),[c,d]=Ke({start:0,end:30}),p=t.length>Ab;if(tt(()=>{if(!p)return;const y=l.current;if(!y)return;let C=!1;const _=()=>{const{scrollTop:R,clientHeight:L}=y,S=Math.max(0,Math.floor(R/e)-n),M=Math.min(t.length,Math.ceil((R+L)/e)+n);d(I=>I.start===S&&I.end===M?I:{start:S,end:M})};let k=!1;const g=()=>{k||C||(k=!0,requestAnimationFrame(()=>{C||_(),k=!1}))},b=new ResizeObserver(()=>{C||_()});return _(),y.addEventListener("scroll",g,{passive:!0}),b.observe(y),()=>{C=!0,y.removeEventListener("scroll",g),b.disconnect()}},[p,t.length,e,n]),!p)return i`
      <div class=${o}>
        ${t.map((y,C)=>s(y,C))}
      </div>
    `;const m=t.length*e,f=c.start*e,h=t.slice(c.start,c.end);return i`
    <div ref=${l} class=${o}>
      <div class="virtual-list-spacer" style=${{height:`${m}px`,position:"relative"}}>
        <div
          class="virtual-list-viewport"
          style=${{position:"absolute",top:0,left:0,right:0,willChange:"transform",transform:`translateY(${f}px)`}}
        >
          ${h.map((y,C)=>{const _=c.start+C;return i`<div key=${a(y)}>${s(y,_)}</div>`})}
        </div>
      </div>
    </div>
  `}const zo=$(null),wo=$(null),Jn=$(!1);async function ic(){if(!Jn.value){Jn.value=!0,wo.value=null;try{zo.value=await Up()}catch(t){wo.value=t instanceof Error?t.message:String(t)}finally{Jn.value=!1}}}function Ib(t){switch(t){case"essential":return"badge-essential";case"standard":return"badge-standard";default:return"badge-full"}}function Rb({items:t,maxCount:e}){return t.length===0?i`<p class="muted">No tool calls recorded yet.</p>`:i`
    <div class="tool-bar-chart">
      ${t.map(n=>{const s=e>0?n.call_count/e*100:0;return i`
          <div class="tool-bar-row" key=${n.name}>
            <span class="tool-bar-name">${n.name}</span>
            <span class="tool-bar-tier ${Ib(n.tier)}">${n.tier}</span>
            <div class="tool-bar-track">
              <div class="tool-bar-fill" style=${{width:`${s}%`}} />
            </div>
            <span class="tool-bar-count">${n.call_count}</span>
          </div>
        `})}
    </div>
  `}function Mb({dist:t}){const e=t.full,n=e>0?(t.essential/e*100).toFixed(1):"0",s=e>0?(t.standard/e*100).toFixed(1):"0",a=e-t.standard,o=e>0?(a/e*100).toFixed(1):"0";return i`
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
  `}function Lb(){const t=zo.value,e=Jn.value,n=wo.value;return tt(()=>{!zo.value&&!Jn.value&&ic()},[]),i`
    <div class="tool-metrics">
      <div class="tool-metrics-header">
        <h3 class="tool-metrics-title">Tool Usage</h3>
        <button
          class="control-btn ghost"
          onClick=${()=>void ic()}
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
            <${Mb} dist=${t.tier_distribution} />
          </div>
          <div class="tool-metrics-section">
            <h4>Top 20 Tools</h4>
            <${Rb}
              items=${t.top_20}
              maxCount=${t.top_20.length>0?t.top_20[0].call_count:0}
            />
          </div>
        </div>
      `:e?null:i`
        <p class="muted">Click Load to fetch tool usage statistics.</p>
      `}
    </div>
  `}const No=$(null),jo=$(null),Vn=$(!1),Nn=$(""),Vs=$("all"),Oi=$(!1),Di=$(!1),qi=$(!0),Fi=$(!0),Ys=$("all"),Ru={public_mcp:["public_mcp"],agent:["spawned_agent_mcp"],keeper:["keeper_standard","keeper_privileged"],internal:["local_worker","mdal_auditable","privileged_executor"]},oc={all:"All",public_mcp:"MCP Public",agent:"Agent",keeper:"Keeper",internal:"Internal"};async function rc(){if(!Vn.value){Vn.value=!0,jo.value=null;try{No.value=await Hp()}catch(t){jo.value=t instanceof Error?t.message:String(t)}finally{Vn.value=!1}}}function Eb(t,e){const n=e.trim().toLowerCase();return n?[t.name,t.description,t.category,t.required_permission??"",t.visibility,t.lifecycle,t.implementationStatus,t.tier,t.canonicalName??"",t.replacement??"",t.reason??"",...t.doc_refs,...t.prompt_hints,...t.surfaces??[]].join(" ").toLowerCase().includes(n):!0}function jn(t,e="default"){return i`
    <span
      style=${{fontSize:"11px",color:e==="ok"?"#7dd3fc":e==="warn"?"#fbbf24":e==="surface"?"#c4b5fd":"#cbd5e1",background:e==="ok"?"rgba(14, 165, 233, 0.18)":e==="warn"?"rgba(245, 158, 11, 0.18)":e==="surface"?"rgba(139, 92, 246, 0.18)":"rgba(148, 163, 184, 0.16)",borderRadius:"999px",padding:"2px 8px"}}
    >
      ${t}
    </span>
  `}function Pb(t,e){if(e==="all")return t.length;const n=Ru[e];return t.filter(s=>(s.surfaces??[]).some(a=>n.includes(a))).length}function zb({item:t}){return i`
    <article class="tool-inventory-row">
      <div class="tool-inventory-head">
        <div>
          <div class="tool-inventory-name">${t.name}</div>
          <div class="tool-inventory-desc">${t.description}</div>
        </div>
        <div class="tool-inventory-badges">
          ${(t.surfaces??[]).map(e=>jn(e,"surface"))}
          ${jn(t.tier,t.tier==="essential"?"ok":t.tier==="standard"?"warn":"default")}
          ${jn(t.visibility)}
          ${jn(t.lifecycle,t.lifecycle==="deprecated"?"warn":"default")}
          ${jn(t.implementationStatus)}
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
  `}const lc=$(!1);function wb(){const t=No.value,e=Vn.value,n=jo.value,s=(t==null?void 0:t.tool_inventory.tools)??[],a=(t==null?void 0:t.tool_usage)??null,o=ee(null);tt(()=>{!No.value&&!Vn.value&&rc()},[]),tt(()=>{var k;if(K.value.tab!=="tools")return;const _=(k=K.value.params.q)==null?void 0:k.trim();_&&_!==Nn.value&&(Nn.value=_)},[K.value.tab,K.value.params.q]);const l=_l(()=>{const _=o.current;_&&(lc.value=_.scrollTop>500)},[]);tt(()=>{const _=o.current;if(_)return _.addEventListener("scroll",l,{passive:!0}),()=>_.removeEventListener("scroll",l)},[l]);const c=_l(()=>{const _=o.current;_&&_.scrollTo({top:0,behavior:"smooth"})},[]),d=Array.from(new Set(s.map(_=>_.category))).sort((_,k)=>_.localeCompare(k)),p=s.filter(_=>{if(!Eb(_,Nn.value)||Vs.value!=="all"&&_.category!==Vs.value||Oi.value&&!_.enabled_in_current_mode||Di.value&&!_.direct_call_allowed||!qi.value&&_.visibility==="hidden"||!Fi.value&&_.lifecycle==="deprecated")return!1;if(Ys.value!=="all"){const k=Ru[Ys.value];if(!(_.surfaces??[]).some(g=>k.includes(g)))return!1}return!0}),m=s.length,f=s.filter(_=>_.enabled_in_current_mode).length,h=s.filter(_=>_.visibility==="hidden").length,y=s.filter(_=>_.lifecycle==="deprecated").length,C=s.filter(_=>_.direct_call_allowed).length;return i`
    <div>
      <${E} title="System Tool Inventory" class="section">
        <div class="tool-inventory-sticky-header">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">System Tool Inventory</h2>
            <p class="monitor-subheadline">Allowed tools는 runtime allowlist이고, 여기서는 시스템이 가진 전체 도구 surface를 hidden/deprecated 포함 기준으로 봅니다.</p>
          </div>

          <div class="tool-inventory-summary">
            <div class="tool-inventory-stat">
              <span class="stat-value">${m}</span>
              <span class="stat-label">Total tools</span>
            </div>
            <div class="tool-inventory-stat">
              <span class="stat-value">${f}</span>
              <span class="stat-label">Mode enabled</span>
            </div>
            <div class="tool-inventory-stat">
              <span class="stat-value">${h}</span>
              <span class="stat-label">Hidden</span>
            </div>
            <div class="tool-inventory-stat">
              <span class="stat-value">${y}</span>
              <span class="stat-label">Deprecated</span>
            </div>
            <div class="tool-inventory-stat">
              <span class="stat-value">${C}</span>
              <span class="stat-label">Direct call</span>
            </div>
            <div class="tool-inventory-stat">
              <span class="stat-value">${p.length}</span>
              <span class="stat-label">Filtered</span>
            </div>
          </div>

          <div class="tool-surface-tabs">
            ${Object.keys(oc).map(_=>i`
              <button
                class=${`control-btn${Ys.value===_?" is-active":""}`}
                onClick=${()=>{Ys.value=_}}
              >
                ${oc[_]}
                <span class="tool-surface-count">${Pb(s,_)}</span>
              </button>
            `)}
          </div>

          <div class="tool-inventory-filters">
            <input
              class="control-input"
              type="text"
              placeholder="Search tools, docs, permission, replacement..."
              value=${Nn.value}
              onInput=${_=>{Nn.value=_.target.value}}
            />
            <select
              class="control-select"
              value=${Vs.value}
              onChange=${_=>{Vs.value=_.target.value}}
            >
              <option value="all">All categories</option>
              ${d.map(_=>i`<option value=${_}>${_}</option>`)}
            </select>
            <label class="tool-inventory-toggle">
              <input
                type="checkbox"
                checked=${Oi.value}
                onChange=${_=>{Oi.value=_.target.checked}}
              />
              <span>Enabled only</span>
            </label>
            <label class="tool-inventory-toggle">
              <input
                type="checkbox"
                checked=${Di.value}
                onChange=${_=>{Di.value=_.target.checked}}
              />
              <span>Direct-call only</span>
            </label>
            <label class="tool-inventory-toggle">
              <input
                type="checkbox"
                checked=${qi.value}
                onChange=${_=>{qi.value=_.target.checked}}
              />
              <span>Show hidden</span>
            </label>
            <label class="tool-inventory-toggle">
              <input
                type="checkbox"
                checked=${Fi.value}
                onChange=${_=>{Fi.value=_.target.checked}}
              />
              <span>Show deprecated</span>
            </label>
            <button class="control-btn ghost" onClick=${()=>{rc()}} disabled=${e}>
              ${e?"Refreshing...":"Refresh inventory"}
            </button>
          </div>
        </div>

        ${n?i`<div class="tool-metrics-error">${n}</div>`:null}

        <div ref=${o} class="tool-inventory-virtual-container">
          ${p.length>0?i`<${Tb}
                items=${p}
                itemHeight=${130}
                renderItem=${_=>i`<${zb} item=${_} />`}
                getKey=${_=>_.name}
                className="tool-inventory-list"
              />`:i`<div class="empty-state">No tools matched the current filters.</div>`}
        </div>

        <button
          class=${`tool-back-to-top${lc.value?" visible":""}`}
          onClick=${c}
          title="Back to top"
        >
          <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
            <path d="M10 15V5M10 5L5 10M10 5L15 10" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
          </svg>
        </button>
      <//>

      <${E} title="Tool Usage" class="section">
        ${a?i`
              <div class="tool-inventory-usage-hint">
                Registered ${a.registered_count} · Distinct called ${a.distinct_tools_called} · Never called ${a.never_called_count}
              </div>
            `:null}
        <${Lb} />
      <//>
    </div>
  `}const Qa=$("all"),Za=$("all"),Oo=$(new Set);function Nb(t){const e=new Set(Oo.value);e.has(t)?e.delete(t):e.add(t),Oo.value=e}const Mu=wt(()=>{let t=pn.value;return Qa.value!=="all"&&(t=t.filter(e=>e.horizon===Qa.value)),Za.value!=="all"&&(t=t.filter(e=>e.status===Za.value)),t}),jb=wt(()=>{const t={short:[],mid:[],long:[]};for(const e of Mu.value){const n=t[e.horizon];n&&n.push(e)}return t}),Ob=wt(()=>{const t=Array.from(Qc.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function Db(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Er(t){switch(t){case"short":return"단기";case"mid":return"중기";case"long":return"장기";default:return t}}function fa(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function qb(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function cc(t){return t.toFixed(4)}function dc(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function Fb(t){switch(t){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function Kb(t){switch(t){case"active":return"진행 중";case"completed":return"완료";case"paused":return"일시정지";default:return"전체"}}function uc(t,e){return(t.priority??4)-(e.priority??4)}function Bb(t,e){const n=t.updated_at??t.created_at??"";return(e.updated_at??e.created_at??"").localeCompare(n)}function Ub(t,e){return t.length<=e?t:t.slice(0,e)+"..."}function Hb({goal:t}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${fa(t.horizon)}">
            ${Er(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${Db(t.priority)}</span>
          ${t.metric?i`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?i`<span class="goal-due">Due: <${Z} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?i`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${ke} status=${t.status} />
        <div class="goal-updated">
          <${Z} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Ki({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return i`
    <${E} title="${Er(t)} 목표 (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${Hb} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function Wb(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">범위</label>
        ${["all","short","mid","long"].map(t=>i`
          <button
            class="goal-filter-btn ${Qa.value===t?"active":""}"
            onClick=${()=>{Qa.value=t}}
          >
            ${t==="all"?"전체":Er(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">상태</label>
        ${["all","active","completed","paused"].map(t=>i`
          <button
            class="goal-filter-btn ${Za.value===t?"active":""}"
            onClick=${()=>{Za.value=t}}
          >
            ${Kb(t)}
          </button>
        `)}
      </div>
    </div>
  `}function Gb(){const t=pn.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return i`
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
        <div class="goal-summary-value" style="color:${fa("short")}">${s.short}</div>
        <div class="goal-summary-label">단기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${fa("mid")}">${s.mid}</div>
        <div class="goal-summary-label">중기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${fa("long")}">${s.long}</div>
        <div class="goal-summary-label">장기</div>
      </div>
    </div>
  `}function Jb({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length}개 도구: ${t.latest_tool_names.join(", ")}`:"아직 근거 없음";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${ke} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${cc(t.baseline_metric)}</span>
          <span>현재 ${cc(t.current_metric)}</span>
          <span class=${dc(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${dc(t)}
          </span>
          <span>Elapsed ${qb(t.elapsed_seconds)}</span>
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
  `}function Bi({task:t}){const e=t.priority??4,n=e<=1?"p1":e===2?"p2":e===3?"p3":"p4",s=Oo.value.has(t.id),a=!!t.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${Fb(e)}</span>
        <div class="kanban-card-title">${t.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>Nb(t.id)}
        >
          ${s?t.description:Ub(t.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${t.created_at?i`<${Z} timestamp=${t.created_at} />`:i`<span>-</span>`}
        ${t.assignee?i`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Vb(){const{todo:t,inProgress:e,done:n}=td.value,s=[...t].sort(uc),a=[...e].sort(uc),o=[...n].sort(Bb);return i`
    <${E} title="태스크 백로그" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>할 일</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">대기 중인 태스크가 없습니다</div>`:s.map(l=>i`<${Bi} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>진행 중</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">진행 중인 태스크가 없습니다</div>`:a.map(l=>i`<${Bi} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>완료</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">완료된 태스크가 없습니다</div>`:o.slice(0,20).map(l=>i`<${Bi} key=${l.id} task=${l} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...외 ${o.length-20}개 더 있음</div>`:null}
        </div>
      </div>
    <//>
  `}function Yb(){const{todo:t,inProgress:e,done:n}=td.value,s=t.length+e.length+n.length,a=[...t,...e].filter(m=>(m.priority??4)<=2).length,o=jb.value,l=Ob.value,c=pn.value.length>0,d=l.length>0,p=nr.value;return i`
    <div>
      <${vt} surfaceId="planning" />

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
          onClick=${()=>{ir(),od()}}
          disabled=${Fn.value||Kn.value}
        >
          ${Fn.value||Kn.value?"새로고침 중...":"계획 데이터 새로고침"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${Vb} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          목표 파이프라인
          <span class="monitor-pill">${pn.value.length}</span>
        </summary>
        <div>
          ${c?i`
            <${Gb} />
            <${Wb} />
            ${Fn.value&&pn.value.length===0?i`<div class="loading-indicator">목표 불러오는 중...</div>`:Mu.value.length===0?i`<div class="empty-state">현재 필터에 맞는 목표가 없습니다</div>`:i`
                    <${Ki} horizon="short" items=${o.short??[]} />
                    <${Ki} horizon="mid" items=${o.mid??[]} />
                    <${Ki} horizon="long" items=${o.long??[]} />
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
          ${Kn.value&&l.length===0?i`<div class="loading-indicator">MDAL 루프 불러오는 중...</div>`:l.length===0&&(p==="error"||mn.value)?i`<div class="empty-state">MDAL 스냅샷을 불러오지 못했습니다${mn.value?`: ${mn.value}`:""}. 백엔드 상태를 확인하세요.</div>`:l.length===0?i`<div class="empty-state">가동 중인 루프가 없습니다. <code>masc_mdal_start</code>로 시작할 수 있습니다.</div>`:i`
                  <div class="planning-loop-list">
                    ${l.map(m=>i`<${Jb} key=${m.loop_id} loop=${m} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const ti=$(!1),Yn=$(!1),dn=$(!1),ei=$(!1),ae=$(""),Xn=$(""),Qn=$(""),Do=$("support"),qo=$("open"),Cn=$(null),hs=$(null),ys=$(null),Fo=$(!1);function bs(t){return`${t.kind}:${t.id}`}function fi(){var n;const t=hs.value,e=((n=Cn.value)==null?void 0:n.items)??[];return t?e.find(s=>bs(s)===t)??null:null}function Xb(t){const e=t.trim().toLowerCase();return e!=="executed"&&e!=="blocked"&&e!=="closed"}function Lu(t){switch(qo.value){case"pending_ruling":return t.filter(e=>e.status==="pending_ruling");case"needs_human_gate":return t.filter(e=>e.status==="needs_human_gate");case"executed":return t.filter(e=>e.status==="executed");case"blocked":return t.filter(e=>e.status==="blocked"||e.status==="closed");case"open":default:return t.filter(e=>Xb(e.status))}}function Qb(t){if(t==null)return"없음";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Pr(t){const e=(t||"").toLowerCase();return e.includes("block")||e.includes("deny")||e.includes("closed")?"negative":e.includes("support")||e.includes("approve")||e.includes("ready")||e.includes("executed")||e.includes("done")?"positive":"neutral"}function Zb(t){return typeof t!="number"||Number.isNaN(t)?"판정 대기":`${Math.round(t*100)}%`}async function Eu(t){if(ys.value=null,!!t){Fo.value=!0,ae.value="";try{ys.value=await Dc(t.id)}catch(e){ae.value=e instanceof Error?e.message:"거버넌스 상세를 불러오지 못했습니다"}finally{Fo.value=!1}}}async function tk(t){hs.value=bs(t),await Eu(t)}async function He(){ti.value=!0,ae.value="";try{const t=await jp();Cn.value=t;const e=Lu(t.items??[]),n=hs.value,s=e.find(a=>bs(a)===n)??e[0]??null;hs.value=s?bs(s):null,await Eu(s)}catch(t){ae.value=t instanceof Error?t.message:"거버넌스 상태를 불러오지 못했습니다"}finally{ti.value=!1}}cv(He);async function pc(){const t=Xn.value.trim();if(t){Yn.value=!0;try{const e=await qm(t);Xn.value="",O(e!=null&&e.case.id?`청원을 접수했습니다: ${e.case.id}`:"청원을 접수했습니다","success"),await He()}catch(e){const n=e instanceof Error?e.message:"청원 접수에 실패했습니다";ae.value=n,O(n,"error")}finally{Yn.value=!1}}}async function ek(){const t=fi(),e=Qn.value.trim();if(!(!t||!e)){ei.value=!0;try{const n=await Fm(t.id,Do.value,e);Qn.value="",ys.value=n,O("심의 의견을 기록했습니다","success"),await He()}catch(n){const s=n instanceof Error?n.message:"심의 기록에 실패했습니다";ae.value=s,O(s,"error")}finally{ei.value=!1}}}async function mc(t){const e=fi();if(e){dn.value=!0;try{await Km(e.id,t),O(t==="confirm"?"집행을 승인했습니다":"집행을 거부했습니다","success"),await He()}catch(n){const s=n instanceof Error?n.message:"집행 결정을 처리하지 못했습니다";ae.value=s,O(s,"error")}finally{dn.value=!1}}}function nk(){var e,n,s;const t=(e=Cn.value)==null?void 0:e.summary;return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">열린 케이스</span>
        <strong>${(t==null?void 0:t.cases_open)??((s=(n=Cn.value)==null?void 0:n.items)==null?void 0:s.length)??0}</strong>
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
  `}function sk(){return i`
    <${E} title="청원 콘솔" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="청원 제목을 입력하세요..."
            value=${Xn.value}
            onInput=${t=>{Xn.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&pc()}}
            disabled=${Yn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${pc}
            disabled=${Yn.value||Xn.value.trim()===""}
          >
            ${Yn.value?"접수 중...":"청원 접수"}
          </button>
          <button class="control-btn ghost" onClick=${He} disabled=${ti.value}>
            ${ti.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
        <div class="governance-filter-row">
          ${[["open","진행 중"],["pending_ruling","판정 대기"],["needs_human_gate","승인 대기"],["executed","집행 완료"],["blocked","보류/종결"]].map(([t,e])=>i`
            <button
              class="control-btn ${qo.value===t?"is-active":"ghost"}"
              onClick=${async()=>{qo.value=t,await He()}}
            >
              ${e}
            </button>
          `)}
        </div>
        ${ae.value?i`<div class="council-error">${ae.value}</div>`:null}
      </div>
    <//>
  `}function ak(){var e;const t=Lu(((e=Cn.value)==null?void 0:e.items)??[]);return i`
    <${E} title="사건 수신함" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${t.length===0?i`<div class="empty-state">지금 필터에 맞는 사건이 없습니다.</div>`:t.map(n=>{const s=hs.value===bs(n);return i`
                <button
                  class="council-row governance-decision-row ${s?"selected":""}"
                  onClick=${()=>tk(n)}
                >
                  <div class="council-row-main">
                    <div class="governance-row-head">
                      <span class="governance-kind">${n.kind}</span>
                      <span class="council-topic">${n.topic}</span>
                    </div>
                    <div class="council-sub">
                      <span>${n.truth_summary||"사실 요약이 아직 없습니다"}</span>
                      ${n.last_activity_at?i`<span><${Z} timestamp=${n.last_activity_at} /></span>`:null}
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
                    <span class="council-state ${Pr(n.status)}">${n.status}</span>
                    <span class="governance-vote-meter">${n.brief_count??0} briefs</span>
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function ik({petition:t}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge neutral">petition</span>
        <strong>${t.created_by||t.origin||"system"}</strong>
        ${t.created_at?i`<span><${Z} timestamp=${t.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${t.title}</div>
      <div class="governance-chip-row">
        ${t.source_refs.map(e=>i`<span class="governance-chip">${e}</span>`)}
      </div>
    </div>
  `}function ok({brief:t}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${Pr(t.stance)}">${t.stance}</span>
        <strong>${t.author}</strong>
        ${t.created_at?i`<span><${Z} timestamp=${t.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${t.summary}</div>
      <div class="governance-chip-row">
        ${t.evidence_refs.map(e=>i`<span class="governance-chip">${e}</span>`)}
      </div>
    </div>
  `}function rk(){var a;const t=fi(),e=ys.value,n=(e==null?void 0:e.petitions)??[],s=(e==null?void 0:e.case.briefs)??[];return i`
    <${E}
      title=${t?"사건 상세":"거버넌스 상세"}
      class="section"
      semanticId="governance.detail"
    >
      ${Fo.value?i`<div class="loading-indicator">거버넌스 상세 불러오는 중...</div>`:!t||!e?i`<div class="empty-state">사건을 고르면 청원, 심의, 판정, 집행 기록을 볼 수 있습니다.</div>`:i`
              <div class="governance-detail-head">
                <div>
                  <h3>${e.case.title}</h3>
                  <div class="council-sub">
                    <span>${e.case.id}</span>
                    <span>${e.case.status}</span>
                    ${e.case.updated_at?i`<span><${Z} timestamp=${e.case.updated_at} /></span>`:null}
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
                ${n.length===0?i`<div class="empty-state">기록된 청원이 없습니다.</div>`:n.map(o=>i`<${ik} key=${o.id} petition=${o} />`)}
              </div>
              <div class="governance-ledger">
                ${s.length===0?i`<div class="empty-state">심의 brief가 아직 없습니다.</div>`:s.map(o=>i`<${ok} key=${o.id} brief=${o} />`)}
              </div>
            `}
    <//>
  `}function lk({order:t}){if(!(t!=null&&t.action_request))return null;const e=t.action_request;return i`
    <div class="governance-side-block">
      <h4>집행 명령</h4>
      <div class="council-sub">
        <span>${e.resolved_tool||e.action_kind||e.target_type||"action"}</span>
        <span>${t.status}</span>
      </div>
      ${e.target_type?i`<div class="governance-side-line">대상 ${e.target_type}${e.target_id?`:${e.target_id}`:""}</div>`:null}
      ${e.reason?i`<div class="governance-side-line">${e.reason}</div>`:null}
      ${e.payload_preview?i`<pre class="council-detail governance-preview">${Qb(e.payload_preview)}</pre>`:null}
      ${t.execution_ref?i`<div class="governance-side-line">결과 참조 ${t.execution_ref}</div>`:null}
      ${t.result_summary?i`<div class="governance-side-line">${t.result_summary}</div>`:null}
    </div>
  `}function ck(){const t=fi(),e=ys.value,n=e==null?void 0:e.ruling,s=e==null?void 0:e.execution_order;return i`
    <div class="governance-side-column">
      <${E} title="판정 / 집행" class="section" semanticId="governance.guardrail">
        ${!t||!e?i`<div class="empty-state">사건을 고르면 판정과 집행 경로가 보입니다.</div>`:i`
              <div class="governance-side-block">
                <h4>판정</h4>
                <div class="council-sub">
                  <span>${(n==null?void 0:n.status)||"pending"}</span>
                  <span>${Zb(n==null?void 0:n.confidence)}</span>
                  ${n!=null&&n.generated_at?i`<span><${Z} timestamp=${n.generated_at} /></span>`:null}
                </div>
                ${n!=null&&n.summary?i`<div class="governance-summary-callout">${n.summary}</div>`:i`<div class="governance-side-line">아직 ruling이 생성되지 않았습니다.</div>`}
                <div class="governance-chip-row">
                  ${t.provenance?i`<span class="governance-chip">${t.provenance}</span>`:null}
                  ${t.risk_class?i`<span class="governance-chip">${t.risk_class}</span>`:null}
                  ${t.subject_type?i`<span class="governance-chip dim">${t.subject_type}</span>`:null}
                </div>
              </div>
              <${lk} order=${s} />
              ${(s==null?void 0:s.status)==="needs_human_gate"?i`
                    <div class="governance-side-block">
                      <h4>사람 승인</h4>
                      <div class="governance-side-line">이 집행은 고위험으로 분류되어 수동 결재가 필요합니다.</div>
                      <div class="governance-action-row">
                        <button class="control-btn secondary" onClick=${()=>mc("confirm")} disabled=${dn.value}>
                          ${dn.value?"처리 중...":"승인"}
                        </button>
                        <button class="control-btn ghost" onClick=${()=>mc("deny")} disabled=${dn.value}>
                          ${dn.value?"처리 중...":"거부"}
                        </button>
                      </div>
                    </div>
                  `:null}
            `}
    <//>
      <${E} title="심의 입력" class="section" semanticId="governance.context">
        ${t?i`
              <div class="governance-side-block">
                <div class="governance-filter-row">
                  ${["support","oppose","neutral"].map(a=>i`
                    <button
                      class="control-btn ${Do.value===a?"is-active":"ghost"}"
                      onClick=${()=>{Do.value=a}}
                    >
                      ${a}
                    </button>
                  `)}
                </div>
                <textarea
                  class="control-input"
                  rows=${5}
                  placeholder="이 사건에 대한 brief를 입력하세요..."
                  value=${Qn.value}
                  onInput=${a=>{Qn.value=a.target.value}}
                ></textarea>
                <div class="governance-action-row">
                  <button
                    class="control-btn secondary"
                    onClick=${ek}
                    disabled=${ei.value||Qn.value.trim()===""}
                  >
                    ${ei.value?"기록 중...":"brief 추가"}
                  </button>
                </div>
              </div>
            `:i`<div class="empty-state">사건을 선택한 뒤 brief를 추가하세요.</div>`}
      <//>
    </div>
  `}function dk(){var e;const t=(((e=Cn.value)==null?void 0:e.activity)??[]).slice(0,8);return i`
    <${E} title="최근 활동" class="section" semanticId="governance.activity">
      <div class="governance-activity-list">
        ${t.length===0?i`<div class="empty-state">기록된 활동이 아직 없습니다.</div>`:t.map(n=>i`
              <div class="governance-activity-row">
                <div class="governance-ledger-head">
                  <span class="governance-badge ${Pr(n.kind)}">${n.kind}</span>
                  ${n.created_at?i`<span><${Z} timestamp=${n.created_at} /></span>`:null}
                </div>
                <div class="governance-ledger-body">${n.summary||n.topic||"활동이 기록되었습니다."}</div>
              </div>
            `)}
      </div>
    <//>
  `}function uk(){return tt(()=>{He()},[]),i`
    <div class="section-grid">
      <${vt} surfaceId="governance" />
      <${nk} />
      <${sk} />
      <div class="governance-layout">
        <${ak} />
        <${rk} />
        <${ck} />
      </div>
      <${dk} />
    </div>
  `}function pk(t,e,n,s,a=120){if(t.length===0)return{positions:new Map};const o=n*s,l=Math.sqrt(o/Math.max(t.length,1)),c=t.map((h,y)=>{const C=2*Math.PI*y/t.length,_=Math.min(n,s)*.35;return{id:h.id,x:n/2+_*Math.cos(C),y:s/2+_*Math.sin(C),vx:0,vy:0,weight:h.weight}}),d=new Map;for(const h of c)d.set(h.id,h);const p=e.filter(h=>d.has(h.source)&&d.has(h.target)&&h.source!==h.target);let m=n/4;for(let h=0;h<a;h++){for(const _ of c)_.vx=0,_.vy=0;for(let _=0;_<c.length;_++)for(let k=_+1;k<c.length;k++){const g=c[_],b=c[k],R=g.x-b.x,L=g.y-b.y,S=Math.max(Math.sqrt(R*R+L*L),.01),M=l*l/S,I=R/S*M,D=L/S*M;g.vx+=I,g.vy+=D,b.vx-=I,b.vy-=D}for(const _ of p){const k=d.get(_.source),g=d.get(_.target),b=g.x-k.x,R=g.y-k.y,L=Math.max(Math.sqrt(b*b+R*R),.01),S=L*L/l,M=1+Math.log1p(_.weight)*.3,I=b/L*S*M,D=R/L*S*M;k.vx+=I,k.vy+=D,g.vx-=I,g.vy-=D}const y=n/2,C=s/2;for(const _ of c){const k=y-_.x,g=C-_.y;_.vx+=k*.01,_.vy+=g*.01}for(const _ of c){const k=Math.sqrt(_.vx*_.vx+_.vy*_.vy);if(k>0){const b=Math.min(k,m);_.x+=_.vx/k*b,_.y+=_.vy/k*b}const g=30;_.x=Math.max(g,Math.min(n-g,_.x)),_.y=Math.max(g,Math.min(s-g,_.y))}m*=.95}const f=new Map;for(const h of c)f.set(h.id,{x:h.x,y:h.y});return{positions:f}}const Ye=$(null);function mk(t,e){if(e==="offline"||e==="retired")return"#64748b";switch(t){case"agent":return"#22d3ee";case"task":return"#fbbf24";case"decision":return"#a78bfa";case"operation":return"#4ade80";case"debate":return"#fb923c";case"post":return"#f472b6";default:return"#94a3b8"}}function _c(t,e){if(!e)return"rgba(100, 116, 139, 0.2)";switch(t){case"mention":return"rgba(34, 211, 238, 0.4)";case"assigned":return"rgba(74, 222, 128, 0.4)";case"voted":return"rgba(167, 139, 250, 0.4)";case"commented":return"rgba(244, 114, 182, 0.4)";case"collaborated":return"rgba(251, 191, 36, 0.4)";default:return"rgba(148, 163, 184, 0.3)"}}function vc(t){return Math.max(6,Math.min(24,6+Math.log1p(t)*3))}function _k({data:t}){const e=ee(null),n=ee(null);tt(()=>{const a=e.current,o=n.current;if(!a||!o||!t.nodes.length)return;const l=o.getBoundingClientRect(),c=Math.max(l.width,400),d=480,p=window.devicePixelRatio||1;a.width=c*p,a.height=d*p,a.style.width=`${c}px`,a.style.height=`${d}px`;const m=a.getContext("2d");if(!m)return;m.setTransform(p,0,0,p,0,0);const h=pk(t.nodes.map(_=>({id:_.id,weight:_.weight})),t.edges.map(_=>({source:_.source,target:_.target,weight:_.weight})),c,d,150).positions,y=Ye.value;m.fillStyle="#0f1117",m.fillRect(0,0,c,d);for(const _ of t.edges){const k=h.get(_.source),g=h.get(_.target);if(!k||!g)continue;const b=y===_.source||y===_.target,R=b?Math.max(1,Math.min(4,1+_.weight*.5)):Math.max(.5,Math.min(2,.5+_.weight*.3));m.beginPath(),m.moveTo(k.x,k.y),m.lineTo(g.x,g.y),m.strokeStyle=b?_c(_.kind,_.active).replace(/[\d.]+\)$/,"0.7)"):_c(_.kind,_.active),m.lineWidth=R,m.stroke()}for(const _ of t.nodes){const k=h.get(_.id);if(!k)continue;const g=vc(_.weight),b=y===_.id,R=mk(_.kind,_.status);b&&(m.beginPath(),m.arc(k.x,k.y,g+6,0,Math.PI*2),m.fillStyle=R.replace(")",", 0.2)").replace("rgb","rgba"),m.fill()),m.beginPath(),m.arc(k.x,k.y,g,0,Math.PI*2),m.fillStyle=R,m.fill(),m.strokeStyle=b?"#fff":"rgba(255,255,255,0.15)",m.lineWidth=b?2:1,m.stroke(),(g>=10||b)&&(m.fillStyle="#e2e8f0",m.font=`${b?11:9}px system-ui, sans-serif`,m.textAlign="center",m.fillText(_.label,k.x,k.y+g+12))}function C(_){const k=e.current;if(!k)return;const g=k.getBoundingClientRect(),b=_.clientX-g.left,R=_.clientY-g.top;let L=null;for(const S of t.nodes){const M=h.get(S.id);if(!M)continue;const I=vc(S.weight),D=b-M.x,J=R-M.y;if(D*D+J*J<=(I+4)*(I+4)){L=S.id;break}}Ye.value!==L&&(Ye.value=L)}return a.addEventListener("mousemove",C),()=>a.removeEventListener("mousemove",C)},[t,Ye.value]);const s=Ye.value?t.nodes.find(a=>a.id===Ye.value):null;return i`
    <div ref=${n} class="social-graph-container">
      <canvas ref=${e} class="social-graph-canvas" />
      ${s?i`
        <div class="social-graph-tooltip">
          <strong>${s.label}</strong>
          <span class="social-graph-tooltip-kind">${s.kind}</span>
          <span>weight ${s.weight}</span>
          <span>status ${s.status}</span>
        </div>
      `:null}
    </div>
  `}const Pu=$(null),Ko=$(null),ga=$(!1);async function fc(){if(!ga.value){ga.value=!0,Ko.value=null;try{Pu.value=await Bm()}catch(t){Ko.value=t instanceof Error?t.message:String(t)}finally{ga.value=!1}}}function vk(t){switch(t){case"agent":return"에이전트";case"task":return"작업";case"decision":return"결정";case"operation":return"작전";case"debate":return"토론";case"post":return"게시글";default:return t}}function gc(t){switch(t){case"agent_joined":return"입장";case"agent_left":return"퇴장";case"broadcast":return"방송";case"task_update":return"작업 변경";case"board_post":return"게시";case"board_comment":return"댓글";case"board_vote":return"투표";case"keeper_heartbeat":return"하트비트";case"keeper_handoff":return"세대 교체";case"mention":return"멘션";default:return t}}function fk(t){const e=t.actor;if(e!=null&&e.id)return e.id;const n=t.payload;return n.agent??n.author??n.from??""}function gk(t){var s;const e=t.payload,n=e.message??e.content??"";return n?n.length>80?n.slice(0,77)+"...":n:(s=t.subject)!=null&&s.id?`-> ${t.subject.id}`:t.kind}function $k({data:t}){const e=t.stats;return i`
    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-label">노드</div>
        <div class="stat-value">${e.node_count}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">엣지</div>
        <div class="stat-value">${e.edge_count}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">에이전트</div>
        <div class="stat-value">${e.agent_count}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">활성</div>
        <div class="stat-value" style="color:#4ade80">${e.active_agents}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">작업</div>
        <div class="stat-value">${e.task_count}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">이벤트</div>
        <div class="stat-value">${e.event_count}</div>
      </div>
    </div>
  `}function hk({events:t}){return t.length===0?i`<div class="empty-state">최근 활동 이벤트가 없습니다.</div>`:i`
    <div class="monitor-list">
      ${t.map(e=>{const n=fk(e);return i`
          <div class="monitor-row ok" key=${e.seq}>
            <div class="monitor-row-header">
              <div class="monitor-row-title">
                <div class="monitor-name-line">
                  <span class="monitor-title">${n||"(unknown)"}</span>
                  <span class="monitor-sub">${gc(e.kind)}</span>
                </div>
                <div class="monitor-note">${gk(e)}</div>
              </div>
              <span class="monitor-pill ok">${gc(e.kind)}</span>
            </div>
            <div class="monitor-meta">
              <span>${e.room_id}</span>
              ${e.ts_iso?i`<span><${Z} timestamp=${e.ts_iso} /></span>`:null}
              ${e.tags.length>0?i`<span>${e.tags.join(", ")}</span>`:null}
            </div>
          </div>
        `})}
    </div>
  `}function yk({nodes:t}){var s;const e=t.filter(a=>a.kind==="agent").sort((a,o)=>o.weight-a.weight).slice(0,15);if(e.length===0)return i`<div class="empty-state">에이전트 노드가 없습니다.</div>`;const n=((s=e[0])==null?void 0:s.weight)??1;return i`
    <div class="social-leaderboard">
      ${e.map((a,o)=>{const l=n>0?a.weight/n*100:0;return i`
          <div class="social-leaderboard-row" key=${a.id}>
            <span class="social-leaderboard-rank">${o+1}</span>
            <div class="social-leaderboard-info">
              <span class="social-leaderboard-name">${a.label}</span>
              <div class="social-leaderboard-bar-wrap">
                <div class="social-leaderboard-bar" style="width:${l}%"></div>
              </div>
            </div>
            <span class="social-leaderboard-weight">${a.weight}</span>
            <span class="social-leaderboard-status ${a.status==="offline"||a.status==="retired"?"inactive":"active"}">${a.status}</span>
          </div>
        `})}
    </div>
  `}function bk({nodes:t}){const e=new Map;for(const s of t)e.set(s.kind,(e.get(s.kind)??0)+1);const n=[...e.entries()].sort((s,a)=>a[1]-s[1]);return i`
    <div class="social-kind-breakdown">
      ${n.map(([s,a])=>i`
        <div class="social-kind-chip" key=${s}>
          <span class="social-kind-label">${vk(s)}</span>
          <span class="social-kind-count">${a}</span>
        </div>
      `)}
    </div>
  `}function kk(){tt(()=>{fc()},[]);const t=Pu.value,e=Ko.value;return ga.value&&!t?i`<div class="loading-indicator">소셜 그래프 불러오는 중...</div>`:e&&!t?i`
      <div class="agents-monitor">
        <${vt} surfaceId="social" />
        <${E} title="오류" class="section" testId="social.error">
          <div class="empty-state">소셜 그래프를 불러올 수 없습니다: ${e}</div>
          <button class="control-btn ghost" onClick=${fc}>다시 시도</button>
        <//>
      </div>
    `:t?i`
    <div class="agents-monitor">
      <${vt} surfaceId="social" />

      <${E} title="소셜 그래프" class="section" semanticId="social.graph" testId="social.graph">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">에이전트 관계 그래프</h2>
          <p class="monitor-subheadline">에이전트, 작업, 결정 간의 상호작용을 시각화합니다. 노드 크기는 활동 빈도를 반영합니다.</p>
        </div>
        <${$k} data=${t} />
        <${_k} data=${t} />
        <div class="monitor-meta" style="margin-top:8px">
          <span>생성 시각: ${t.generated_at}</span>
          <span>이벤트 윈도우: ${t.window.limit}</span>
          ${t.window.room_id?i`<span>room: ${t.window.room_id}</span>`:null}
        </div>
      <//>

      <div class="agents-workbench">
        <${E} title="에이전트 활동 순위" class="section" semanticId="social.leaderboard" testId="social.leaderboard">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">에이전트 활동 순위</h2>
            <p class="monitor-subheadline">그래프 이벤트 빈도(weight)를 기준으로 정렬한 에이전트 순위입니다.</p>
          </div>
          <${yk} nodes=${t.nodes} />
        <//>

        <${E} title="노드 종류 분포" class="section" semanticId="social.kinds" testId="social.kinds">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">노드 종류</h2>
            <p class="monitor-subheadline">그래프에 포함된 노드를 종류별로 분류합니다.</p>
          </div>
          <${bk} nodes=${t.nodes} />
        <//>

        <${E} title="최근 활동" class="section" semanticId="social.timeline" testId="social.timeline">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">타임라인</h2>
            <p class="monitor-subheadline">가장 최근의 소셜 이벤트를 시간순으로 보여줍니다.</p>
          </div>
          <${hk} events=${[...t.timeline].reverse().slice(0,30)} />
        <//>
      </div>
    </div>
  `:i`<div class="empty-state">데이터가 없습니다.</div>`}const tn=$(""),Ui=$("ability_check"),Hi=$("10"),Wi=$("12"),Xs=$(""),Qs=$("idle"),ce=$(""),Zs=$("keeper-late"),Gi=$("player"),Ji=$(""),Mt=$("idle"),Vi=$(null),ta=$(""),Yi=$(""),Xi=$("player"),Qi=$(""),Zi=$(""),to=$(""),Zn=$("20"),eo=$("20"),no=$(""),ea=$("idle"),Bo=$(null),zu=$("overview"),so=$("all"),ao=$("all"),io=$("all"),xk=12e4,gi=$(null),$c=$(Date.now());function Sk(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Ck(t,e){return e>0?Math.round(t/e*100):0}const Ak={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Tk={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function na(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Ik(t){const e=t.trim().toLowerCase();return Ak[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Rk(t){const e=t.trim().toLowerCase();return Tk[e]??"상황에 따라 선택되는 전술 액션입니다."}function Ct(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Ot(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function ks(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const Mk=new Set(["str","dex","con","int","wis","cha"]);function Lk(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!v(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const l=a.trim();if(l){if(typeof o=="number"&&Number.isFinite(o)){s[l]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const c=Number.parseFloat(o.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function Ek(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(Zn.value.trim(),10);Number.isFinite(s)&&s>n&&(Zn.value=String(n))}function Uo(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Pk(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function zk(t){zu.value=t}function wu(t){const e=gi.value;return e==null||e<=t}function wk(t){const e=gi.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function ni(){gi.value=null}function Nu(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Nk(t,e){Nu(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(gi.value=Date.now()+xk,O("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function $a(t){return wu(t)?(O("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Ho(t,e,n){return Nu([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function jk({hp:t,max:e}){const n=Ck(t,e),s=Sk(t,e);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Ok({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return i`
    <div class="trpg-actor-stats">
      ${e.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Dk({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function ju({actor:t}){var d,p,m,f;const e=(d=t.archetype)==null?void 0:d.trim(),n=(p=t.persona)==null?void 0:p.trim(),s=(m=t.portrait)==null?void 0:m.trim(),a=(f=t.background)==null?void 0:f.trim(),o=t.traits??[],l=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([h,y])=>Number.isFinite(y)).filter(([h])=>!Mk.has(h.toLowerCase()));return i`
    <div class="trpg-actor">
      ${s?i`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${h=>{const y=h.target;y&&(y.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${ke} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Dk} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${jk} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Ok} stats=${t.stats} />
          </div>
        `:null}
      ${e?i`<div class="trpg-actor-meta">Archetype: ${na(e)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([h,y])=>i`
                <span class="trpg-custom-stat-chip">${na(h)} ${y}</span>
              `)}
            </div>
          </div>
        `:null}
      ${o.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${o.map(h=>i`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${na(h)}</span>
                  <span class="trpg-annot-desc">${Ik(h)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${l.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${l.map(h=>i`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${na(h)}</span>
                  <span class="trpg-annot-desc">${Rk(h)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function qk({mapStr:t}){return i`<pre class="trpg-map">${t}</pre>`}function Ou({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?i`<div class="empty-state" style="font-size:13px">${e}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Pk(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Uo(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${Z} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Fk({events:t}){const e="__none__",n=so.value,s=ao.value,a=io.value,o=Array.from(new Set(t.map(Uo).map(f=>f.trim()).filter(f=>f!==""))).sort((f,h)=>f.localeCompare(h)),l=Array.from(new Set(t.map(f=>(f.type??"").trim()).filter(f=>f!==""))).sort((f,h)=>f.localeCompare(h)),c=t.some(f=>(f.type??"").trim()===""),d=Array.from(new Set(t.map(f=>(f.phase??"").trim()).filter(f=>f!==""))).sort((f,h)=>f.localeCompare(h)),p=t.some(f=>(f.phase??"").trim()===""),m=t.filter(f=>{if(n!=="all"&&Uo(f)!==n)return!1;const h=(f.type??"").trim(),y=(f.phase??"").trim();if(s===e){if(h!=="")return!1}else if(s!=="all"&&h!==s)return!1;if(a===e){if(y!=="")return!1}else if(a!=="all"&&y!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${f=>{so.value=f.target.value}}>
          <option value="all">all</option>
          ${o.map(f=>i`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${f=>{ao.value=f.target.value}}>
          <option value="all">all</option>
          ${c?i`<option value=${e}>(none)</option>`:null}
          ${l.map(f=>i`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${f=>{io.value=f.target.value}}>
          <option value="all">all</option>
          ${p?i`<option value=${e}>(none)</option>`:null}
          ${d.map(f=>i`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{so.value="all",ao.value="all",io.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${m.length} / 전체 ${t.length}
      </span>
    </div>
    <${Ou} events=${m.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Kk({outcome:t}){if(!t)return null;const e=o=>{const l=o.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function Du({state:t}){const e=t.history??[];return e.length===0?null:i`
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
  `}function Bk({state:t,nowMs:e}){var p;const n=ne.value||((p=t.session)==null?void 0:p.room)||"",s=Qs.value,a=t.party??[];if(!a.find(m=>m.id===tn.value)&&a.length>0){const m=a[0];m&&(tn.value=m.id)}const l=async()=>{var f,h;if(!n){O("Room ID가 비어 있습니다.","error");return}if(!$a(e))return;const m=((f=t.current_round)==null?void 0:f.phase)??((h=t.session)==null?void 0:h.status)??"unknown";if(Ho("라운드 실행",n,m)){Qs.value="running";try{const y=await Rm(n);Bo.value=y,Qs.value="ok";const C=v(y.summary)?y.summary:null,_=C?ks(C,"advanced",!1):!1,k=C?Ct(C,"progress_reason",""):"";O(_?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${k?`: ${k}`:""}`,_?"success":"warning"),ve()}catch(y){Bo.value=null,Qs.value="error";const C=y instanceof Error?y.message:"라운드 실행에 실패했습니다.";O(C,"error")}finally{ni()}}},c=async()=>{var f,h;if(!n||!$a(e))return;const m=((f=t.current_round)==null?void 0:f.phase)??((h=t.session)==null?void 0:h.status)??"unknown";if(Ho("턴 강제 진행",n,m))try{await Em(n),O("턴을 다음 단계로 이동했습니다.","success"),ve()}catch{O("턴 이동에 실패했습니다.","error")}finally{ni()}},d=async()=>{if(!n||!$a(e))return;const m=tn.value.trim();if(!m){O("먼저 Actor를 선택하세요.","warning");return}const f=Number.parseInt(Hi.value,10),h=Number.parseInt(Wi.value,10);if(Number.isNaN(f)||Number.isNaN(h)){O("stat/dc는 숫자여야 합니다.","warning");return}const y=Number.parseInt(Xs.value,10),C=Xs.value.trim()===""||Number.isNaN(y)?void 0:y;try{await Lm({roomId:n,actorId:m,action:Ui.value.trim()||"ability_check",statValue:f,dc:h,rawD20:C}),O("주사위 판정을 기록했습니다.","success"),ve()}catch{O("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${m=>{ne.value=m.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${tn.value}
            onChange=${m=>{tn.value=m.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(m=>i`<option value=${m.id}>${m.name} (${m.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${Ui.value}
              onInput=${m=>{Ui.value=m.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Hi.value}
              onInput=${m=>{Hi.value=m.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Wi.value}
              onInput=${m=>{Wi.value=m.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Xs.value}
              onInput=${m=>{Xs.value=m.target.value}}
              onKeyDown=${m=>{m.key==="Enter"&&d()}}
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
  `}function Uk({state:t}){var a;const e=ne.value||((a=t.session)==null?void 0:a.room)||"",n=ea.value,s=async()=>{if(!e){O("Room ID가 비어 있습니다.","warning");return}const o=ta.value.trim(),l=Yi.value.trim();if(!l&&!o){O("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Zn.value.trim(),10),d=Number.parseInt(eo.value.trim(),10),p=Number.isFinite(d)?Math.max(1,d):20,m=Number.isFinite(c)?Math.max(0,Math.min(p,c)):p;let f={};try{f=Lk(no.value)}catch(h){O(h instanceof Error?h.message:"능력치 JSON 오류","error");return}ea.value="spawning";try{const h=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,y=await Pm(e,{actor_id:o||void 0,name:l||void 0,role:Xi.value,idempotencyKey:h,portrait:Zi.value.trim()||void 0,background:to.value.trim()||void 0,hp:m,max_hp:p,alive:m>0,stats:Object.keys(f).length>0?f:void 0}),C=typeof y.actor_id=="string"?y.actor_id.trim():"";if(!C)throw new Error("생성 응답에 actor_id가 없습니다.");const _=Qi.value.trim();_&&await zm(e,C,_),tn.value=C,ce.value=C,o||(ta.value=""),ea.value="ok",O(`Actor 생성 완료: ${C}`,"success"),await ve()}catch(h){ea.value="error",O(h instanceof Error?h.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Yi.value}
            onInput=${o=>{Yi.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Xi.value}
            onChange=${o=>{Xi.value=o.target.value}}
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
            value=${Qi.value}
            onInput=${o=>{Qi.value=o.target.value}}
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
              value=${ta.value}
              onInput=${o=>{ta.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Zi.value}
              onInput=${o=>{Zi.value=o.target.value}}
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
              value=${Zn.value}
              onInput=${o=>{Zn.value=o.target.value}}
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
              value=${eo.value}
              onInput=${o=>{const l=o.target.value;eo.value=l,Ek(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${to.value}
              onInput=${o=>{to.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${no.value}
              onInput=${o=>{no.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Hk({state:t,nowMs:e}){var h;const n=ne.value||((h=t.session)==null?void 0:h.room)||"",s=t.join_gate,a=Vi.value,o=v(a)?a:null,l=(t.party??[]).filter(y=>y.role!=="dm"),c=ce.value.trim(),d=l.some(y=>y.id===c),p=d?c:c?"__manual__":"",m=async()=>{const y=ce.value.trim(),C=Zs.value.trim();if(!n||!y){O("Room/Actor가 필요합니다.","warning");return}Mt.value="checking";try{const _=await wm(n,y,C||void 0);Vi.value=_,Mt.value="ok",O("참가 가능 여부를 갱신했습니다.","success")}catch(_){Mt.value="error";const k=_ instanceof Error?_.message:"참가 가능 여부 확인에 실패했습니다.";O(k,"error")}},f=async()=>{var g,b;const y=ce.value.trim(),C=Zs.value.trim(),_=Ji.value.trim();if(!n||!y||!C){O("Room/Actor/Keeper가 필요합니다.","warning");return}if(!$a(e))return;const k=((g=t.current_round)==null?void 0:g.phase)??((b=t.session)==null?void 0:b.status)??"unknown";if(Ho("Mid-Join 승인 요청",n,k)){Mt.value="requesting";try{const R=await Nm({room_id:n,actor_id:y,keeper_name:C,role:Gi.value,..._?{name:_}:{}});Vi.value=R;const L=v(R)?ks(R,"granted",!1):!1,S=v(R)?Ct(R,"reason_code",""):"";L?O("Mid-Join이 승인되었습니다.","success"):O(`Mid-Join이 거절되었습니다${S?`: ${S}`:""}`,"warning"),Mt.value=L?"ok":"error",ve()}catch(R){Mt.value="error";const L=R instanceof Error?R.message:"Mid-Join 요청에 실패했습니다.";O(L,"error")}finally{ni()}}};return i`
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
            value=${p}
            onChange=${y=>{const C=y.target.value;if(C==="__manual__"){(d||!c)&&(ce.value="");return}ce.value=C}}
          >
            <option value="">Actor 선택</option>
            ${l.map(y=>i`
              <option value=${y.id}>${y.name} (${y.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${p==="__manual__"?i`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${ce.value}
                onInput=${y=>{ce.value=y.target.value}}
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
            value=${Zs.value}
            onInput=${y=>{Zs.value=y.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Gi.value}
            onChange=${y=>{Gi.value=y.target.value}}
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
            value=${Ji.value}
            onInput=${y=>{Ji.value=y.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${m} disabled=${Mt.value==="checking"||Mt.value==="requesting"}>
              ${Mt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${f} disabled=${Mt.value==="checking"||Mt.value==="requesting"}>
              ${Mt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${ks(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Ot(o,"effective_score",0)}/${Ot(o,"required_points",0)}</span>
            ${Ct(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${Ct(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function qu({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${e.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Fu({state:t}){var n;const e=t.current_round;return e?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Ku(){const t=Bo.value;if(!t)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=v(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(v).slice(-8),o=t.canon_check,l=v(o)?o:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(S=>typeof S=="string").slice(0,3):[],d=l&&Array.isArray(l.violations)?l.violations.filter(S=>typeof S=="string").slice(0,3):[],p=n?ks(n,"advanced",!1):!1,m=n?Ct(n,"progress_reason",""):"",f=n?Ct(n,"progress_detail",""):"",h=n?Ot(n,"player_successes",0):0,y=n?Ot(n,"player_required_successes",0):0,C=n?ks(n,"dm_success",!1):!1,_=n?Ot(n,"timeouts",0):0,k=n?Ot(n,"unavailable",0):0,g=n?Ot(n,"reprompts",0):0,b=n?Ot(n,"npc_attacks",0):0,R=n?Ot(n,"keeper_timeout_sec",0):0,L=n?Ot(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${p?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${p?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${C?"DM ok":"DM stalled"} / players ${h}/${y}
          </span>
        </div>
        ${m?i`<div style="margin-top:4px; font-size:12px;">${m}</div>`:null}
        ${f?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${f}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${_}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${g}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${b}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${R||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${L}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(S=>{const M=Ct(S,"status","unknown"),I=Ct(S,"actor_id","-"),D=Ct(S,"role","-"),J=Ct(S,"reason",""),et=Ct(S,"action_type",""),G=Ct(S,"reply","");return i`
                <div class="trpg-round-item ${M.includes("fallback")||M.includes("timeout")?"failed":"active"}">
                  <span>${I} (${D})</span>
                  <span style="margin-left:auto; font-size:11px;">${M}</span>
                  ${et?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${et}</div>`:null}
                  ${J?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${J}</div>`:null}
                  ${G?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${G.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${Ct(l,"status","unknown")}</strong>
            </div>
            ${d.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(S=>i`<div>violation: ${S}</div>`)}
                </div>`:null}
            ${c.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(S=>i`<div>warning: ${S}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Wk({state:t,nowMs:e}){var l,c,d;const n=ne.value||((l=t.session)==null?void 0:l.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=wu(e),o=wk(e);return i`
    <${E} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${o}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>Nk(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{ni(),O("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Gk({active:t}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>zk(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Jk({state:t}){const e=t.party??[],n=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${E} title="관전 가이드" semanticId="lab.trpg">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${E} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${Ou} events=${n.slice(-20)} />
        <//>

        ${t.map?i`
            <${E} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${qk} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${E} title="현재 라운드" semanticId="lab.trpg">
          <${Fu} state=${t} />
        <//>

        <${E} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${qu} state=${t} />
        <//>

        <${E} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>i`<${ju} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?i`
            <${E} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Du} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Vk({state:t}){const e=t.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${E} title=${`이벤트 타임라인 (${e.length})`}>
          <${Fk} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${E} title="최근 라운드 결과" semanticId="lab.trpg">
          <${Ku} />
        <//>

        <${E} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${Fu} state=${t} />
        <//>
      </div>
    </div>
  `}function Yk({state:t,nowMs:e}){const n=t.party??[];return i`
    <div>
      <${Wk} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${E} title="조작 패널" semanticId="lab.trpg">
            <${Bk} state=${t} nowMs=${e} />
          <//>

          <${E} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${Uk} state=${t} />
          <//>

          <${E} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${Hk} state=${t} nowMs=${e} />
          <//>

          <${E} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${Ku} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${E} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${qu} state=${t} />
          <//>

          <${E} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${ju} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?i`
              <${E} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Du} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Xk(){var c,d,p,m,f;const t=Xc.value,e=ho.value;if(tt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const h=window.setInterval(()=>{$c.value=Date.now()},1e3);return()=>{window.clearInterval(h)}},[]),e&&!t)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>ve()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,o=zu.value,l=$c.value;return i`
    <div>
      <${vt} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${ne.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((p=t.session)==null?void 0:p.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>ve()}>새로고침</button>
      </div>

      <${Kk} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((m=t.session)==null?void 0:m.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((f=t.current_round)==null?void 0:f.round_number)??0}</div>
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

      <${Gk} active=${o} />

      ${o==="overview"?i`<${Jk} state=${t} />`:o==="timeline"?i`<${Vk} state=${t} />`:i`<${Yk} state=${t} nowMs=${l} />`}
    </div>
  `}function Qk(){return i`
    <div>
      <${vt} surfaceId="lab" />
      <${E} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${E} title="TRPG" class="section" semanticId="lab.trpg">
        <${Xk} />
      <//>
    </div>
  `}const si=$(new Set(["broadcast","tasks","keepers","system"]));function Zk(t){const e=new Set(si.value);e.has(t)?e.delete(t):e.add(t),si.value=e}const zr=$(null);function Bu(t){zr.value=t}function t0(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const e0=wt(()=>{const t=si.value;return ya.value.filter(e=>t.has(t0(e)))}),n0=12e4,s0=wt(()=>{const t=ed.value,e=Date.now();return Gt.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?o=e-new Date(l).getTime()>n0?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),a0=wt(()=>{const t=ed.value;return Gt.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function hc(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function i0(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function o0(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function r0(){const t=s0.value,e=zr.value;return t.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${t.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${o0(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>Bu(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const l0=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function c0(){const t=si.value;return i`
    <div class="activity-filter-bar">
      ${l0.map(e=>i`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>Zk(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function d0(){const t=e0.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${c0} />
      <div class="activity-stream-list">
        ${t.length===0?i`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>i`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${hc(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${hc(e)}">${i0(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${Xd(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function u0(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function p0(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function m0(){const t=a0.value,e=zr.value;return i`
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
              onClick=${()=>Bu(e===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${u0(n.pressure)}">
                  ${p0(n.pressure)}
                  ${n.assignedCount>0?i` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?i`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?i`<span class="focus-activity-text">${n.lastActivityText}</span>`:i`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?i`<${Z} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function _0(){const t=$e.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>라이브 모니터</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"연결됨":"오프라인"}
          </span>
          <span class="live-stat">에이전트 ${Gt.value.length}</span>
          <span class="live-stat">이벤트 ${ai.value}</span>
        </div>
      </div>

      <${r0} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${d0} />
        </div>
        <div class="live-panel-side">
          <${m0} />
        </div>
      </div>
    </div>
  `}const yc=[{id:"now",label:"지금",description:"지금 무슨 일이 벌어지는지 사회의 현재 상태를 먼저 읽는 표면"},{id:"why",label:"이유",description:"왜 그렇게 보이는지 근거, 메모리, 거버넌스로 뒤를 파는 표면"},{id:"act",label:"개입",description:"운영자 액션과 계획 조정을 통해 지금 상태를 바꾸는 표면"},{id:"lab",label:"실험",description:"실험적 오케스트레이션과 고급 지휘 표면을 분리해서 보는 영역"}],Wo=[{id:"mission",label:"상황판",icon:"🏠",group:"now",description:"room 중심으로 지금 상황과 사회의 흐름을 가장 먼저 읽는 기본 랜딩"},{id:"execution",label:"실행",icon:"🤖",group:"now",description:"agents, keepers, sessions를 중심으로 사회의 행위자를 읽는 표면"},{id:"live",label:"라이브",icon:"📡",group:"now",description:"실시간 에이전트 활동과 이벤트 흐름을 사회 관찰 관점으로 보는 표면"},{id:"proof",label:"근거",icon:"🔍",group:"why",description:"협업, 대화, 실행의 증거 경로를 확인하는 표면"},{id:"memory",label:"메모리",icon:"💬",group:"why",description:"게시글, 댓글, 비동기 기억으로 room의 누적 맥락을 읽는 표면"},{id:"governance",label:"거버넌스",icon:"⚖️",group:"why",description:"토론, 표결, 판단 구조를 규범과 결정의 관점에서 읽는 표면"},{id:"social",label:"소셜",icon:"🔗",group:"why",description:"에이전트 관계 그래프와 활동 흐름을 보는 사회 분석 표면"},{id:"planning",label:"계획",icon:"🎯",group:"act",description:"목표, 백로그, 압력을 운영 관점으로 읽는 계획 표면"},{id:"tools",label:"도구",icon:"🧰",group:"act",description:"시스템 전체 도구 inventory와 사용 건강도를 확인하는 운영 표면"},{id:"intervene",label:"개입",icon:"🎮",group:"act",description:"룸, 세션, 키퍼에 직접 개입하는 운영 화면"},{id:"command",label:"지휘",icon:"🧭",group:"lab",description:"command-plane, swarm, resolution 같은 고급 지휘/실험 표면"},{id:"lab",label:"실험",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 표면을 메인 사회/운영 콘솔 밖에서 다룹니다"}];function v0(t){const e=t==null?void 0:t.trim();return e?e.length>10?e.slice(0,10):e:"커밋 정보 없음"}function kt(t,e){return e==="live"?"가동 중":e==="quiet"?"조용함":e==="starting"?"기동 중":e==="idle"?t==="guardian"?"유휴":"대기 중":"비활성"}function xt(t,e){return i`
    <div class="build-badge-row">
      <span>${t}</span>
      <strong>${e}</strong>
    </div>
  `}function sa(t,e,n,s,a){return i`
    <div style="padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
      <div class="rail-card-head" style="margin:0;">
        <h3 style="font-size:12px;">${t}</h3>
        <span class="rail-section-chip ${n}">${e}</span>
      </div>
      ${s}
      ${a?i`<div class="rail-build-hint">${a}</div>`:null}
    </div>
  `}function f0({currentTab:t}){var p,m,f,h,y,C,_,k,g,b,R,L;const e=$e.value,n=(p=dt.value)==null?void 0:p.build,s=(m=dt.value)==null?void 0:m.social_runtime,a=(f=dt.value)==null?void 0:f.lodge,o=(h=dt.value)==null?void 0:h.gardener,l=(y=dt.value)==null?void 0:y.guardian,c=(C=dt.value)==null?void 0:C.sentinel,d=[];if(s||a){const S=s,M=a;d.push(sa("Social Runtime",S?S.enabled?kt("social","live"):kt("social","disabled"):M!=null&&M.enabled?kt("lodge",M.quiet_active?"quiet":"live"):kt("social","disabled"),S?S.enabled?"ok":"bad":M!=null&&M.enabled?M.quiet_active?"warn":"ok":"bad",[xt("전략",(S==null?void 0:S.strategy)??"legacy_fallback"),xt("대상 keeper",(S==null?void 0:S.active_keepers)??(M==null?void 0:M.agent_count)??0),xt("큐",(S==null?void 0:S.queue_depth)??0),xt("최근 결과",((_=S==null?void 0:S.last_result)==null?void 0:_.activity_report)??(S!=null&&S.last_pass_reason?`판단 패스: ${S.last_pass_reason}`:null)??(S!=null&&S.last_system_skip_reason?`시스템 스킵: ${S.last_system_skip_reason}`:null)??((k=M==null?void 0:M.last_tick_result)==null?void 0:k.activity_report)??(M!=null&&M.last_pass_reason?`판단 패스: ${M.last_pass_reason}`:null)??(M!=null&&M.last_system_skip_reason?`시스템 스킵: ${M.last_system_skip_reason}`:null)??(M==null?void 0:M.last_skip_reason)??"없음")]))}if(o&&d.push(sa("Gardener",o.alive?kt("gardener","live"):o.enabled?kt("gardener","starting"):kt("gardener","disabled"),o.alive?"ok":o.enabled?"warn":"bad",[xt("최근 tick",o.last_tick_completed_at?i`<${Z} timestamp=${o.last_tick_completed_at} />`:"기록 없음"),xt("판단",`${o.last_intervention??"없음"} · ${o.last_decision_source??"없음"}`),xt("백로그",`미할당 ${((g=o.health_summary)==null?void 0:g.todo_count)??0} · P1/2 ${((b=o.health_summary)==null?void 0:b.high_priority_todo)??0}`)],o.last_reason??o.last_error??void 0)),l){const S=l.masc_loops_running||l.lodge_loop_started||l.lodge_running;d.push(sa("Guardian",S?kt("guardian","live"):l.enabled?kt("guardian","idle"):kt("guardian","disabled"),S?"ok":l.enabled?"warn":"bad",[xt("모드",l.mode??"알 수 없음"),xt("루프",`zombie ${l.zombie_loop_running?"on":"off"} · gc ${l.gc_loop_running?"on":"off"}`),xt("소유자",l.runtime_owner??"없음")],((R=l.last_lodge_result)==null?void 0:R.message)??l.last_gc_result??l.last_zombie_result??void 0))}return c&&d.push(sa("Sentinel",c.started?kt("sentinel","live"):c.enabled?kt("sentinel","starting"):kt("sentinel","disabled"),c.started?"ok":c.enabled?"warn":"bad",[xt("에이전트",c.agent_name??"sentinel"),xt("소비자",((L=c.consumers)==null?void 0:L.length)??0),xt("가디언 소유자",c.guardian_runtime_owner??"없음")],c.llm_enabled===!0?"LLM 기반 housekeeping resident":void 0)),i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${B} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${e?"ok":"bad"}">${e?"연결됨":"오프라인"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>에이전트</span>
          <strong>${Gt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>키퍼</span>
          <strong>${ie.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>태스크</span>
          <strong>${pe.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>이벤트</span>
          <strong>${ai.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Cs(),ad(),Ro(t)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>at("intervene")}>
          개입 열기
        </button>
      </div>
      ${n?i`<div class="rail-build-hint">서버 빌드 · v${n.release_version} · ${v0(n.commit)}</div>`:null}
      ${d.length>0?i`
            <div style="margin-top:12px; display:flex; flex-direction:column; gap:10px;">
              ${d}
            </div>
          `:null}
    </section>
  `}function g0(){const t=It.value,e=ci(t).total_count,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${B} panelId="side_rail.quick_actions" compact=${!0} />
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
          onClick=${()=>{_t(),Be()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>at("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}const aa=$(!1);function $0(){const t=$e.value;return i`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"연결됨":"재연결 중..."}</span>
      <span class="event-count">이벤트 ${ai.value}</span>
    </div>
  `}function h0(t){const e=t==null?void 0:t.trim();return e?e.length>10?e.slice(0,10):e:"커밋 정보 없음"}function y0(){const t=dt.value,e=t==null?void 0:t.build,n=e?`v${e.release_version} · ${h0(e.commit)}`:t!=null&&t.version?`v${t.version} · 커밋 정보 없음`:"버전 정보 없음";return i`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${aa.value}
        onClick=${()=>{aa.value=!aa.value}}
      >
        서버 빌드 · ${n}
      </button>
      ${aa.value?i`
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
                <strong>${e!=null&&e.started_at?i`<${Z} timestamp=${e.started_at} />`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof(e==null?void 0:e.uptime_seconds)=="number"?`${e.uptime_seconds}s`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${t!=null&&t.generated_at?i`<${Z} timestamp=${t.generated_at} />`:"알 수 없음"}</strong>
              </div>
            </div>
          `:null}
    </div>
  `}function b0(){const t=K.value.tab,e=Wo.find(s=>s.id===t),n=yc.find(s=>s.id===(e==null?void 0:e.group));return i`
    <aside class="dashboard-rail">
      <${vt} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${B} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${yc.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${Wo.filter(a=>a.group===s.id).map(a=>i`
                  <button
                    class="rail-tab-btn ${t===a.id?"active":""}"
                    onClick=${()=>at(a.id)}
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

      <${f0} currentTab=${t} />
      <${g0} />
    </aside>
  `}function k0(){switch(K.value.tab){case"mission":return i`<${jl} />`;case"proof":return i`<${ph} />`;case"execution":return i`<${Cb} />`;case"tools":return i`<${wb} />`;case"live":return i`<${_0} />`;case"memory":return i`<${rb} />`;case"governance":return i`<${uk} />`;case"social":return i`<${kk} />`;case"planning":return i`<${Yb} />`;case"intervene":return i`<${Jy} />`;case"command":return i`<${Uy} />`;case"lab":return i`<${Qk} />`;default:return i`<${jl} />`}}function x0(){return $o.value&&!$e.value?i`<div class="loading-indicator">대시보드 불러오는 중...</div>`:i`<${k0} />`}function S0(){tt(()=>{ep(),Tc(),id(),ze(),Pe(),ad(),kd();const n=pv();return mv(),()=>{cp(),n(),_v()}},[]),tt(()=>{const n=setInterval(()=>{Ro(K.value.tab)},15e3);return()=>{clearInterval(n)}},[]),tt(()=>{Ro(K.value.tab)},[K.value.tab]);const t=K.value.tab,e=Wo.find(n=>n.id===t);return i`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC 대시보드
            <${y0} />
          </h1>
          <p class="header-subtitle">${(e==null?void 0:e.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${$0} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${b0} />
        <main class="dashboard-main">
          <${x0} />
        </main>
      </div>

      <${_$} />
      <${wg} />
      <${Cg} />
    </div>
  `}const bc=document.getElementById("app");bc&&Yu(i`<${S0} />`,bc);export{S$ as _};
