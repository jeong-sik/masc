var zu=Object.defineProperty;var Eu=(t,e,n)=>e in t?zu(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var He=(t,e,n)=>Eu(t,typeof e!="symbol"?e+"":e,n);import{e as ju,_ as wu,c as g,b as Et,A as Dn,y as nt,d as $n,G as Nu}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const l of i.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var o=ju.bind(wu);const Du=["mission","proof","execution","tools","live","memory","governance","planning","intervene","command","lab"],pc={tab:"mission",params:{},postId:null};function dl(t){return!!t&&Du.includes(t)}function oi(t){try{return decodeURIComponent(t)}catch{return t}}function ii(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Ou(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function mc(t,e){if(t[0]==="chains"){const i={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(i.operation=oi(t[2])),{tab:"command",params:i,postId:null}}if(t[0]==="lab"){const i={...e};return t[1]&&(i.surface=oi(t[1])),{tab:"lab",params:i,postId:null}}const n=t[0],s=e.tab;return{tab:dl(n)?n:dl(s)?s:"mission",params:e,postId:null}}function va(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return pc;const n=oi(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=ii(a),l=Ou(s);return mc(l,i)}function qu(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...pc,params:ii(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=ii(e.replace(/^\?/,""));return mc(s,a)}function _c(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const D=g(va(window.location.hash));window.addEventListener("hashchange",()=>{D.value=va(window.location.hash)});function at(t,e){const n={tab:t,params:e??{}};window.location.hash=_c(n)}function Fu(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function Ku(){if(window.location.hash&&window.location.hash!=="#"){D.value=va(window.location.hash);return}const t=qu(window.location.pathname,window.location.search);if(t){D.value=t;const e=_c(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",D.value=va(window.location.hash)}const ul="masc_dashboard_sse_session_id",Bu=1e3,Uu=15e3,ge=g(!1),no=g(0),vc=g(null),fa=g([]);function Hu(){let t=sessionStorage.getItem(ul);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(ul,t)),t}const Wu=200;function Gu(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};fa.value=[a,...fa.value].slice(0,Wu)}function ri(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function pl(t,e){const n=ri(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function Mt(t,e,n,s,a={}){Gu(t,e,n,{eventType:s,...a})}let Ot=null,ln=null,li=0;function fc(){ln&&(clearTimeout(ln),ln=null)}function Ju(){if(ln)return;li++;const t=Math.min(li,5),e=Math.min(Uu,Bu*Math.pow(2,t));ln=setTimeout(()=>{ln=null,gc()},e)}function gc(){fc(),Ot&&(Ot.close(),Ot=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Hu());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);Ot=i,i.onopen=()=>{Ot===i&&(li=0,ge.value=!0)},i.onerror=()=>{Ot===i&&(ge.value=!1,i.close(),Ot=null,Ju())},i.onmessage=l=>{try{const c=JSON.parse(l.data);no.value++,vc.value=c,Vu(c)}catch{}}}function Vu(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":Mt(n,"Joined","system","agent_joined");break;case"agent_left":Mt(n,"Left","system","agent_left");break;case"broadcast":Mt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Mt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Mt(n,pl("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:ri(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":Mt(n,pl("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:ri(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":Mt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Mt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Mt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Mt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Mt(n,e,"system","unknown")}}function Yu(){fc(),Ot&&(Ot.close(),Ot=null),ge.value=!1}function m(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function r(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function u(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function E(t){return typeof t=="boolean"?t:void 0}function K(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function ct(t,e=[]){if(Array.isArray(t))return t;if(!m(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function it(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}const ga="[STATE]",ci="[/STATE]";function Xu(t){const e=t.indexOf(ga);if(e<0)return null;const n=e+ga.length,s=t.indexOf(ci,n);return s<0?null:t.slice(n,s).trim()||null}function Qu(t){let e=t;for(;;){const n=e.indexOf(ga);if(n<0)return e;const s=e.indexOf(ci,n+ga.length);if(s<0)return e.slice(0,n);e=`${e.slice(0,n)}${e.slice(s+ci.length)}`}}function Zu(t){return t.split(`
`).filter(e=>{const n=e.trim();return!n.startsWith("SKILL:")&&!n.startsWith("SKILL_REASON:")}).join(`
`)}function $c(t){const e=Zu(t);return Qu(e).replace(/\n{3,}/g,`

`).trim()}function hc(t){const e=(()=>{if(!m(t))return null;const i=t.raw_payload;return m(i)?i:t})();if(!e)return null;const n=r(e.reply)??"",s=n?Xu(n):null,a=m(e.usage)?{inputTokens:u(e.usage.input_tokens)??null,outputTokens:u(e.usage.output_tokens)??null,totalTokens:u(e.usage.total_tokens)??null}:null;return{traceId:r(e.trace_id)??null,generation:u(e.generation)??null,modelUsed:r(e.model_used)??null,latencyMs:u(e.latency_ms)??null,costUsd:u(e.cost_usd)??null,usage:a,skillPrimary:r(e.skill_primary)??null,skillReason:r(e.skill_reason)??null,stateBlock:s,rawPayload:e}}function yc(t){if(!m(t))return null;const e=r(t.action_type),n=r(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:r(t.description),confirm_required:E(t.confirm_required)}}function so(t){if(!m(t))return null;const e=r(t.confirm_token)??r(t.token);return e?{confirm_token:e,actor:r(t.actor),action_type:r(t.action_type),target_type:r(t.target_type),target_id:r(t.target_id)??null,delegated_tool:r(t.delegated_tool),created_at:r(t.created_at),preview:t.preview}:null}function Ki(t){return m(t)?{actor_filter:r(t.actor_filter)??null,filter_active:E(t.filter_active)??!1,visible_count:u(t.visible_count)??0,total_count:u(t.total_count)??0,hidden_count:u(t.hidden_count)??0,hidden_actors:K(t.hidden_actors),confirm_required_actions:ct(t.confirm_required_actions).map(yc).filter(e=>e!==null)}:null}function bc(t){if(!m(t))return null;const e=ct(t.items,["confirms"]).map(so).filter(s=>s!==null),n=Ki(t.summary);return!n&&e.length===0?null:{items:e,summary:n??{actor_filter:null,filter_active:!1,visible_count:e.length,total_count:e.length,hidden_count:0,hidden_actors:[],confirm_required_actions:[]}}}function hs(t){var a,i,l,c;const e=(t==null?void 0:t.pending_confirm_envelope)??null,n=(e==null?void 0:e.items)??(t==null?void 0:t.pending_confirms)??[],s=(e==null?void 0:e.summary)??(t==null?void 0:t.pending_confirm_summary)??{actor_filter:null,filter_active:!1,visible_count:n.length,total_count:n.length,hidden_count:0,hidden_actors:[],confirm_required_actions:((a=t==null?void 0:t.available_actions)==null?void 0:a.filter(d=>d.confirm_required))??[]};return{items:n,summary:s,actor_filter:((i=s.actor_filter)==null?void 0:i.trim())||null,visible_count:s.visible_count??n.length,total_count:s.total_count??n.length,hidden_count:s.hidden_count??0,hidden_actors:s.hidden_actors??[],confirm_required_actions:(l=s.confirm_required_actions)!=null&&l.length?s.confirm_required_actions:((c=t==null?void 0:t.available_actions)==null?void 0:c.filter(d=>d.confirm_required))??[]}}function Bi(){return new URLSearchParams(window.location.search)}const tp="masc_dashboard_agent_name";function kc(){var t;try{return((t=localStorage.getItem(tp))==null?void 0:t.trim())||null}catch{return null}}function ep(){var e,n;const t=Bi();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||kc()||"dashboard"}function xc(){const t=Bi(),e={},n=t.get("token"),s=kc(),a=t.get("agent")??t.get("agent_name")??s;return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Ui(){return{...xc(),"Content-Type":"application/json"}}const np=15e3,Hi=3e4,sp=6e4,ml=new Set([408,425,429,500,502,503,504]);class ys extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);He(this,"method");He(this,"path");He(this,"status");He(this,"statusText");He(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function Wi(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const l=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new ys({method:l,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function ap(){var e,n;const t=Bi();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function st(t){const e=await Wi(t,{headers:xc()},np);if(!e.ok)throw new ys({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function op(t){return new Promise(e=>setTimeout(e,t))}function ip(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function rp(t){if(t instanceof ys)return t.timeout||typeof t.status=="number"&&ml.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=ip(t.message);return e!==null&&ml.has(e)}async function ao(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!rp(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,a),await op(i),s+=1}}async function Gt(t,e,n,s=Hi){const a=await Wi(t,{method:"POST",headers:{...Ui(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new ys({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function lp(t,e,n,s=Hi){const a=await Wi(t,{method:"POST",headers:{...Ui(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new ys({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function cp(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function dp(t){var e,n,s,a,i,l,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((c=(l=(i=t.result)==null?void 0:i.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function jt(t,e){const n=await lp("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},sp),s=cp(n);return dp(s)}function oo(t){const e=t.trim();return e?JSON.parse(e):{}}async function up(t){return oo(await jt("masc_autoresearch_status",{loop_id:t}))}async function pp(t,e){return oo(await jt("masc_autoresearch_inject",{loop_id:t,hypothesis:e}))}async function mp(t){return oo(await jt("masc_autoresearch_cycle",{loop_id:t}))}async function _p(t,e){return oo(await jt("masc_autoresearch_stop",{loop_id:t,reason:e}))}async function vp(t,e,n){const s={message:e},a=await bs({actor:ep(),action_type:"keeper_message",target_type:"keeper",target_id:t,payload:s}),i=m(a.result)?a.result:null,l=i&&typeof i.reply=="string"?i.reply:"",c=i&&m(i.result)?i.result:i,d=hc(c);return{text:$c(l||"(empty reply)"),details:d}}async function fp(t,e,n){return vp(t,e)}function gp(t){const e=t.replace(/\r\n/g,`
`),n=[];let s=0;for(;;){const a=e.indexOf(`

`,s);if(a<0)return{frames:n,rest:e.slice(s)};n.push(e.slice(s,a)),s=a+2}}function _l(t){const e=t.split(`
`).filter(n=>n.startsWith("data:")).map(n=>n.slice(5).trimStart());if(e.length===0)return null;try{return JSON.parse(e.join(`
`))}catch{return null}}async function $p(t,e,n,{signal:s,onEvent:a}){var p;const i=await fetch("/api/v1/keepers/chat/stream",{method:"POST",headers:{...Ui(),Accept:"text/event-stream"},body:JSON.stringify({name:t,message:e}),signal:s});if(!i.ok){const _=await i.text();let v=_||`Streaming request failed (${i.status})`;try{const f=JSON.parse(_);v=((p=f.error)==null?void 0:p.message)??f.message??v}catch{}throw new Error(v)}if(!i.body)throw new Error("Streaming response body is unavailable");const l=i.body.getReader(),c=new TextDecoder;let d="";try{for(;;){const{done:v,value:f}=await l.read();d+=c.decode(f??new Uint8Array,{stream:!v});const{frames:h,rest:T}=gp(d);d=T;for(const k of h){const C=_l(k);C&&a(C)}if(v)break}const _=d.trim();if(_){const v=_l(_);v&&a(v)}}finally{l.releaseLock()}}function hp(){return st("/api/v1/dashboard/shell")}function yp(){return st("/api/v1/dashboard/room-truth")}function bp(){return st("/api/v1/dashboard/execution")}function kp(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),st(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function xp(){return ao("fetchDashboardGovernance",async()=>{const t=await st("/api/v1/dashboard/governance"),e=Array.isArray(t.items)?t.items.map(i=>Kp(i)).filter(i=>i!==null):[],n=Array.isArray(t.pending_actions)?t.pending_actions.map(i=>so(i)).filter(i=>i!==null):[],s=e.filter(i=>i.kind==="debate").map(i=>({id:i.id,topic:i.topic,status:i.status,argument_count:i.evidence_refs.length,created_at:i.last_activity_at??void 0})),a=e.filter(i=>i.kind==="consensus").map(i=>({id:i.id,topic:i.topic,initiator:i.related_agents[0]||"system",votes:i.votes??0,quorum:i.quorum??0,threshold:i.threshold,state:i.status,created_at:i.last_activity_at??void 0}));return{generated_at:_t(t.generated_at)??void 0,summary:m(t.summary)?{debates:gt(t.summary.debates)??void 0,voting_sessions:gt(t.summary.voting_sessions)??void 0,debates_open:gt(t.summary.debates_open)??void 0,sessions_active:gt(t.summary.sessions_active)??void 0,sessions_without_quorum:gt(t.summary.sessions_without_quorum)??void 0,ready_to_execute:gt(t.summary.ready_to_execute)??void 0,oldest_open_debate_age_s:typeof t.summary.oldest_open_debate_age_s=="number"?t.summary.oldest_open_debate_age_s:null,last_activity_age_s:typeof t.summary.last_activity_age_s=="number"?t.summary.last_activity_age_s:null,judge_online:typeof t.summary.judge_online=="boolean"?t.summary.judge_online:void 0,judge_last_seen_at:_t(t.summary.judge_last_seen_at)}:void 0,debates:s,sessions:a,items:e,activity:Array.isArray(t.activity)?t.activity.map(i=>Bp(i)).filter(i=>i!==null):[],judge:Up(t.judge),pending_actions:n,pending_confirm_summary:Ki(t.pending_confirm_summary),pending_confirm_envelope:bc(t.pending_confirm_envelope)}})}function Sp(){return st("/api/v1/dashboard/semantics")}function Cp(){return st("/api/v1/dashboard/mission")}function Ap(t){const e=`?session_id=${encodeURIComponent(t)}`;return st(`/api/v1/dashboard/session${e}`)}function Tp(t=!1){return st(`/api/v1/dashboard/mission/briefing${t?"?force=1":""}`)}function Ip(t,e){const n=new URLSearchParams;t&&n.set("session_id",t),e&&n.set("operation_id",e);const s=n.toString();return st(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function Rp(){return st("/api/v1/dashboard/planning")}function Lp(){return st("/api/v1/tool-metrics")}function Mp(){return st("/api/v1/dashboard/tools")}function Pp(){return st("/api/v1/operator")}function Sc(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return st(`/api/v1/operator/digest${n?`?${n}`:""}`)}function zp(){return st("/api/v1/command-plane")}function Ep(){return st("/api/v1/command-plane/summary")}function jp(){return st("/api/v1/chains/summary")}function wp(t){return st(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Np(){return st("/api/v1/command-plane/help")}function Dp(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return st(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function Op(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return st(`/api/v1/command-plane/orchestra${s?`?${s}`:""}`)}function qp(t,e){return Gt(t,e)}function Fp(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"swarm_run_continue":return 6e4;case"swarm_run_rerun":return 12e4;case"swarm_run_abandon":return 3e4;case"lodge_tick":return 45e3;default:return Hi}}function bs(t){return Gt("/api/v1/operator/action",t,void 0,Fp(t))}function Cc(t,e,n="confirm"){return Gt("/api/v1/operator/confirm",{actor:t,confirm_token:e,decision:n})}function na(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function _t(t){if(typeof t=="string"){const e=t.trim();return e||null}if(typeof t=="number"&&Number.isFinite(t)){const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}return null}function W(t){if(typeof t!="string")return null;const e=t.trim();return e||null}function Gi(t){return m(t)?{board_post_id:W(t.board_post_id),task_id:W(t.task_id),operation_id:W(t.operation_id),team_session_id:W(t.team_session_id)}:{}}function Ac(t){if(!m(t))return null;const e=W(t.action_kind),n=W(t.resolved_tool),s=W(t.target_type),a=W(t.target_id),i=W(t.reason);return!e&&!n&&!s&&!i?null:{action_kind:e??void 0,resolved_tool:n,target_type:s,target_id:a,reason:i??void 0,payload_preview:t.payload_preview}}function Tc(t){if(!m(t))return null;const e=W(t.action_type),n=W(t.delegated_tool),s=W(t.confirmation_state),a=_t(t.created_at);return!e&&!n&&!s&&!a?null:{action_type:e??void 0,delegated_tool:n,confirmation_state:s??void 0,created_at:a}}function Ic(t){if(!m(t))return null;const e=so(t.pending_confirm),n=W(t.pending_confirm_token)??(e==null?void 0:e.confirm_token)??null;return{requires_human_gate:typeof t.requires_human_gate=="boolean"?t.requires_human_gate:void 0,pending_confirm:e,pending_confirm_token:n,ready_to_execute:typeof t.ready_to_execute=="boolean"?t.ready_to_execute:void 0}}function Rc(t){if(!m(t))return null;const e=W(t.summary),n=W(t.target_id);return!e&&!n?null:{judgment_id:W(t.judgment_id)??void 0,target_kind:W(t.target_kind)??void 0,target_id:n??void 0,status:W(t.status)??void 0,summary:e??void 0,confidence:typeof t.confidence=="number"?t.confidence:null,generated_at:_t(t.generated_at),expires_at:_t(t.expires_at),model_used:W(t.model_used),keeper_name:W(t.keeper_name),evidence_refs:Kt(t.evidence_refs),recommended_action:Ac(t.recommended_action),guardrail_state:Ic(t.guardrail_state),executed_route:Tc(t.executed_route)}}function Kp(t){if(!m(t))return null;const e=A(t.id,"").trim(),n=A(t.topic,"").trim();if(!e||!n)return null;const s=Gi(t.context);return{kind:A(t.kind,"debate"),id:e,topic:n,status:A(t.status??t.state,"open"),last_activity_at:_t(t.last_activity_at),truth_summary:W(t.truth_summary)??void 0,judgment_summary:W(t.judgment_summary),confidence:typeof t.confidence=="number"?t.confidence:null,related_agents:Kt(t.related_agents),context:s,linked_board_post_id:W(t.linked_board_post_id)??s.board_post_id??null,linked_task_id:W(t.linked_task_id)??s.task_id??null,linked_operation_id:W(t.linked_operation_id)??s.operation_id??null,linked_session_id:W(t.linked_session_id)??s.team_session_id??null,recommended_action:Ac(t.recommended_action),executed_route:Tc(t.executed_route),guardrail_state:Ic(t.guardrail_state),evidence_refs:Kt(t.evidence_refs),approve_count:gt(t.approve_count),reject_count:gt(t.reject_count),abstain_count:gt(t.abstain_count),votes:gt(t.votes),quorum:gt(t.quorum),threshold:typeof t.threshold=="number"?t.threshold:void 0}}function Bp(t){if(!m(t))return null;const e=A(t.kind,"").trim();return e?{kind:e,item_kind:W(t.item_kind)??void 0,item_id:W(t.item_id)??void 0,topic:W(t.topic)??void 0,created_at:_t(t.created_at),summary:W(t.summary)??void 0,actor:W(t.actor),index:gt(t.index),decision:W(t.decision)}:null}function Up(t){if(m(t))return{judge_online:typeof t.judge_online=="boolean"?t.judge_online:void 0,refreshing:typeof t.refreshing=="boolean"?t.refreshing:void 0,generated_at:_t(t.generated_at),expires_at:_t(t.expires_at),model_used:W(t.model_used),keeper_name:W(t.keeper_name),last_error:W(t.last_error)}}function Hp(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Wp(t){if(!m(t))return null;const e=A(t.source,"").trim()||null,n=A(t.state_block,"").trim()||null;return!e&&!n?null:{source:e,state_block:n}}function Gp(t){if(!m(t))return null;const e=A(t.id,"").trim(),n=A(t.author,"").trim(),s=A(t.body,"").trim()||A(t.content,"").trim(),a=s;if(!e||!n)return null;const i=H(t.score,0),l=H(t.votes_up,0),c=H(t.votes_down,0),d=H(t.votes,i||l-c),p=H(t.comment_count,H(t.reply_count,0)),_=(()=>{const C=t.flair;if(typeof C=="string"&&C.trim())return C.trim();if(m(C)){const y=A(C.name,"").trim();if(y)return y}return A(t.flair_name,"").trim()||void 0})(),v=A(t.created_at_iso,"").trim()||na(t.created_at),f=A(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?na(t.updated_at):v),T=A(t.title,"").trim()||Hp(s),k=Array.isArray(t.tags)?t.tags.filter(C=>typeof C=="string"&&C.trim()!==""):[];return{id:e,author:n,post_kind:(()=>{const C=A(t.post_kind,"").trim().toLowerCase();return C==="automation"||C==="system"||C==="human"?C:void 0})(),title:T,body:s,content:a,meta:Wp(t.meta),tags:k,votes:d,vote_balance:i,comment_count:p,created_at:v,updated_at:f,flair:_,hearth:A(t.hearth,"").trim()||null,visibility:A(t.visibility,"").trim()||void 0,expires_at:A(t.expires_at_iso,"").trim()||(t.expires_at!==void 0&&t.expires_at!==0?na(t.expires_at):"")||null,hearth_count:H(t.hearth_count,0)}}function Jp(t){if(!m(t))return null;const e=A(t.id,"").trim(),n=A(t.post_id,"").trim(),s=A(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:A(t.content,""),created_at:na(t.created_at)}}async function Vp(t){return ao("fetchBoardPost",async()=>{const e=await st(`/api/v1/board/${t}?format=flat`),n=m(e.post)?e.post:e,s=Gp(n)??{id:t,author:"unknown",post_kind:"human",title:"Post",body:"",content:"",meta:null,tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},i=(Array.isArray(e.comments)?e.comments:[]).map(Jp).filter(l=>l!==null);return{...s,comments:i}})}function Lc(t,e){return Gt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:ap()})}function Yp(t,e,n){return Gt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Xp(t){const e=A(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function pt(...t){for(const e of t){const n=A(e,"");if(n.trim())return n.trim()}return""}function vl(t){const e=Xp(pt(t.outcome,t.result,t.result_code));if(!e)return;const n=pt(t.reason,t.reason_code,t.description,t.detail),s=pt(t.summary,t.summary_ko,t.summary_en,t.note),a=pt(t.details,t.details_text,t.text,t.note),i=pt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),l=pt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=pt(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const v=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof v=="string"?[v]:Array.isArray(v)?v.map(f=>{if(typeof f=="string")return f.trim();if(m(f)){const h=A(f.summary,"").trim();if(h)return h;const T=A(f.text,"").trim();if(T)return T;const k=A(f.type,"").trim();return k||A(f.event_id,"").trim()}return""}).filter(f=>f.length>0):[]})(),p=(()=>{const v=H(t.turn,Number.NaN);if(Number.isFinite(v))return v;const f=H(t.turn_number,Number.NaN);if(Number.isFinite(f))return f;const h=H(t.current_turn,Number.NaN);if(Number.isFinite(h))return h;const T=H(t.round,Number.NaN);return Number.isFinite(T)?T:void 0})(),_=pt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:l||void 0,evidence:d.length>0?d:void 0,raw_reason:c||void 0,turn:p,phase:_||void 0}}function Qp(t,e){const n=m(t.state)?t.state:{};if(A(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(l=>m(l)?A(l.type,"")==="session.outcome":!1),i=m(n.session_outcome)?n.session_outcome:{};if(m(i)&&Object.keys(i).length>0){const l=vl(i);if(l)return l}if(m(a))return vl(m(a.payload)?a.payload:{})}function A(t,e=""){return typeof t=="string"?t:e}function H(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function gt(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function $a(t,e=!1){return typeof t=="boolean"?t:e}function Kt(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(m(e)){const n=A(e.name,"").trim(),s=A(e.id,"").trim(),a=A(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function Zp(t){const e={};if(!m(t)&&!Array.isArray(t))return e;if(m(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=A(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!m(n))continue;const s=pt(n.to,n.target,n.actor_id,n.name,n.id),a=pt(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function tm(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function It(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const em=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function nm(t){const e=m(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const i=s.trim();i&&(em.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function sm(t,e){if(t!=="dice.rolled")return;const n=H(e.raw_d20,0),s=H(e.total,0),a=H(e.bonus,0),i=A(e.action,"roll"),l=H(e.dc,0);return{notation:l>0?`${i} (DC ${l})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function am(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function om(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function im(t,e,n,s){const a=n||e||A(s.actor_id,"")||A(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=A(s.proposed_action,A(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=A(s.reply,A(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return A(s.reply,A(s.content,A(s.text,"Narration")));case"dice.rolled":{const i=A(s.action,"roll"),l=H(s.total,0),c=H(s.dc,0),d=A(s.label,""),p=a||"actor",_=c>0?` vs DC ${c}`:"",v=d?` (${d})`:"";return`${p} ${i}: ${l}${_}${v}`}case"turn.started":return`Turn ${H(s.turn,1)} started`;case"phase.changed":return`Phase: ${A(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${A(s.name,m(s.actor)?A(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${A(s.keeper_name,A(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${A(s.keeper_name,A(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${H(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${H(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||A(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||A(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${A(s.reason_code,"unknown")}`;case"memory.signal":{const i=m(s.entity_refs)?s.entity_refs:{},l=A(i.requested_tier,""),c=A(i.effective_tier,""),d=$a(i.guardrail_applied,!1),p=A(s.summary_en,A(s.summary_ko,"Memory signal"));if(!l&&!c)return p;const _=l&&c?`${l}->${c}`:c||l;return`${p} [${_}${d?" (guardrail)":""}]`}case"world.event":{if(A(s.event_type,"")==="canon.check"){const l=A(s.status,"unknown"),c=A(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return A(s.description,A(s.summary,"World event"))}case"combat.attack":return A(s.summary,A(s.result,"Attack resolved"));case"combat.defense":return A(s.summary,A(s.result,"Defense resolved"));case"session.outcome":return A(s.summary,A(s.outcome,"Session ended"));default:{const i=am(s);return i?`${t}: ${i}`:t}}}function rm(t,e){const n=m(t)?t:{},s=A(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=A(n.actor_name,"").trim()||e[a]||A(m(n.payload)?n.payload.actor_name:"",""),l=m(n.payload)?n.payload:{},c=A(n.ts,A(n.timestamp,new Date().toISOString())),d=A(n.phase,A(l.phase,"")),p=A(n.category,"");return{type:s,actor:i||a||A(l.actor_name,""),actor_id:a||A(l.actor_id,""),actor_name:i,seq:n.seq,room_id:A(n.room_id,""),phase:d||void 0,category:p||om(s),visibility:A(n.visibility,A(l.visibility,"public")),event_id:A(n.event_id,""),content:im(s,a,i,l),dice_roll:sm(s,l),timestamp:c}}function lm(t,e,n){var Z,tt;const s=A(t.room_id,"")||n||"default",a=m(t.state)?t.state:{},i=m(a.party)?a.party:{},l=m(a.actor_control)?a.actor_control:{},c=m(a.join_gate)?a.join_gate:{},d=m(a.contribution_ledger)?a.contribution_ledger:{},p=Object.entries(i).map(([G,R])=>{const S=m(R)?R:{},P=It(S,"max_hp",void 0,10),J=It(S,"hp",void 0,P),yt=It(S,"max_mp",void 0,0),oe=It(S,"mp",void 0,0),U=It(S,"level",void 0,1),vt=It(S,"xp",void 0,0),xe=$a(S.alive,J>0),rt=l[G],In=typeof rt=="string"?rt:void 0,Ps=tm(S.role,G,In),zs=gt(S.generation),Es=pt(S.joined_at,S.joinedAt,S.started_at,S.startedAt),go=pt(S.claimed_at,S.claimedAt,S.assigned_at,S.assignedAt,S.assigned_time),$o=pt(S.last_seen,S.lastSeen,S.last_seen_at,S.lastSeenAt,S.last_active,S.lastActive),ho=pt(S.scene,S.current_scene,S.currentScene,S.world_scene,S.scene_name,S.sceneName),yo=pt(S.location,S.current_location,S.currentLocation,S.position,S.zone,S.area);return{id:G,name:A(S.name,G),role:Ps,keeper:In,archetype:A(S.archetype,""),persona:A(S.persona,""),portrait:A(S.portrait,"")||void 0,background:A(S.background,"")||void 0,traits:Kt(S.traits),skills:Kt(S.skills),stats_raw:nm(S),status:xe?"active":"dead",generation:zs,joined_at:Es||void 0,claimed_at:go||void 0,last_seen:$o||void 0,scene:ho||void 0,location:yo||void 0,inventory:Kt(S.inventory),notes:Kt(S.notes),relationships:Zp(S.relationships),stats:{hp:J,max_hp:P,mp:oe,max_mp:yt,level:U,xp:vt,strength:It(S,"strength","str",10),dexterity:It(S,"dexterity","dex",10),constitution:It(S,"constitution","con",10),intelligence:It(S,"intelligence","int",10),wisdom:It(S,"wisdom","wis",10),charisma:It(S,"charisma","cha",10)}}}),_=p.filter(G=>G.status!=="dead"),v=Qp(t,e),f={phase_open:$a(c.phase_open,!0),min_points:H(c.min_points,3),window:A(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},h=Object.entries(d).map(([G,R])=>{const S=m(R)?R:{};return{actor_id:G,score:H(S.score,0),last_reason:A(S.last_reason,"")||null,reasons:Kt(S.reasons)}}),T=p.reduce((G,R)=>(G[R.id]=R.name,G),{}),k=e.map(G=>rm(G,T)),C=H(a.turn,1),$=A(a.phase,"round"),y=A(a.map,""),x=m(a.world)?a.world:{},M=y||A(x.ascii_map,A(x.map,"")),I=k.filter((G,R)=>{const S=e[R];if(!m(S))return!1;const P=m(S.payload)?S.payload:{};return H(P.turn,-1)===C}),F=(I.length>0?I:k).slice(-12),B=A(a.status,"active");return{session:{id:s,room:s,status:B==="ended"?"ended":B==="paused"?"paused":"active",round:C,actors:_,created_at:((Z=k[0])==null?void 0:Z.timestamp)??new Date().toISOString()},current_round:{round_number:C,phase:$,events:F,timestamp:((tt=k[k.length-1])==null?void 0:tt.timestamp)??new Date().toISOString()},map:M||void 0,join_gate:f,contribution_ledger:h,outcome:v,party:_,story_log:k,history:[]}}async function cm(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await st(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function dm(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([st(`/api/v1/trpg/state${e}`),cm(t)]);return lm(n,s,t)}function um(t){return Gt("/api/v1/trpg/rounds/run",{room_id:t})}function pm(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function mm(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Gt("/api/v1/trpg/dice/roll",e)}function _m(t,e){const n=pm();return Gt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function vm(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Gt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function fm(t,e,n){return Gt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function gm(t,e,n){const s=await jt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function $m(t){const e=await jt("trpg.mid_join.request",t);return JSON.parse(e)}async function hm(t,e){await jt("masc_broadcast",{agent_name:t,message:e})}async function ym(t=40){return(await jt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function bm(t,e=20){return jt("masc_task_history",{task_id:t,limit:e})}async function km(t){const e=await jt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function xm(t){return ao("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await st(`/api/v1/council/debates/${e}/summary`);if(!m(n))return null;const s=m(n.debate)?n.debate:n,a=A(s.id,"").trim(),i=A(s.topic,"").trim();return!a||!i?null:{debate:{id:a,topic:i,status:A(s.status,"open"),created_at:_t(s.created_at_iso??s.created_at),closed_at:_t(s.closed_at)},arguments:Array.isArray(n.arguments)?n.arguments.flatMap(l=>m(l)?[{index:H(l.index,0),agent:A(l.agent,"unknown"),position:A(l.position,"neutral"),content:A(l.content,""),evidence:Kt(l.evidence),reply_to:gt(l.reply_to)??null,mentions:Kt(l.mentions),archetype:W(l.archetype),created_at:_t(l.created_at)}]:[]):[],summary:{support_count:m(n.summary)?H(n.summary.support_count,0):H(n.support_count,0),oppose_count:m(n.summary)?H(n.summary.oppose_count,0):H(n.oppose_count,0),neutral_count:m(n.summary)?H(n.summary.neutral_count,0):H(n.neutral_count,0),total_arguments:m(n.summary)?H(n.summary.total_arguments,0):H(n.total_arguments,0),summary_text:m(n.summary)?A(n.summary.summary_text,""):A(n.summary_text,"")},context:Gi(n.context),judgment:Rc(n.judgment)}})}async function Sm(t){return ao("fetchConsensusSessionSummary",async()=>{const e=encodeURIComponent(t),n=await st(`/api/v1/council/sessions/${e}/summary`);if(!m(n)||!m(n.session))return null;const s=n.session,a=A(s.id,"").trim(),i=A(s.topic,"").trim();return!a||!i?null:{session:{id:a,topic:i,state:A(s.state,"open"),initiator:A(s.initiator,"system"),quorum:H(s.quorum,0),threshold:H(s.threshold,0),created_at:_t(s.created_at),closed_at:_t(s.closed_at)},votes:Array.isArray(n.votes)?n.votes.flatMap(l=>m(l)?[{agent:A(l.agent,"unknown"),decision:A(l.decision,"abstain"),reason:A(l.reason,""),timestamp:_t(l.timestamp),weight:typeof l.weight=="number"?l.weight:void 0,archetype:W(l.archetype)}]:[]):[],summary:{approve_count:m(n.summary)?H(n.summary.approve_count,0):0,reject_count:m(n.summary)?H(n.summary.reject_count,0):0,abstain_count:m(n.summary)?H(n.summary.abstain_count,0):0,quorum_met:m(n.summary)?$a(n.summary.quorum_met,!1):!1,result:m(n.summary)?W(n.summary.result):null},context:Gi(n.context),judgment:Rc(n.judgment)}})}const Cm=g(""),se=g({}),$t=g({}),di=g({}),ha=g({}),ui=g({}),pi=g({}),Ut=g({}),Ji=new Map,Vi=new Map;function lt(t,e,n){t.value={...t.value,[e]:n}}function Am(t){var n;const e=(n=r(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Tm(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function bo(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!m(s))continue;const a=r(s.name);if(!a)continue;const i=r(s[e]);e==="summary"?n.push({name:a,summary:i}):n.push({name:a,reason:i})}return n}function Im(t){if(!m(t))return null;const e=r(t.name);return e?{name:e,trigger:r(t.trigger),outcome:r(t.outcome),summary:r(t.summary),reason:r(t.reason)}:null}function Rm(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Lm(t,e,n){return r(t)??Rm(e,n)}function Mm(t,e){return typeof t=="boolean"?t:e==="recover"}function ya(t){if(!m(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:r(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:it(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:u(t.next_eligible_at_s)??null,recoverable:Mm(t.recoverable,n),summary:Lm(t.summary,e,r(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0,continuity_state:r(t.continuity_state)??null,continuity_summary:r(t.continuity_summary)??null}}function Mc(t){return m(t)?{hour:u(t.hour),checked:u(t.checked)??0,acted:u(t.acted)??0,acted_names:K(t.acted_names),activity_report:r(t.activity_report),quiet_hours_overridden:E(t.quiet_hours_overridden),skipped_reason:r(t.skipped_reason),acted_rows:bo(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:bo(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:bo(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Im).filter(e=>e!==null):[]}:null}function Pm(t){return m(t)?{enabled:E(t.enabled)??!1,interval_s:u(t.interval_s)??0,quiet_start:u(t.quiet_start),quiet_end:u(t.quiet_end),quiet_active:E(t.quiet_active),use_planner:E(t.use_planner),delegate_llm:E(t.delegate_llm),agent_count:u(t.agent_count),agents:K(t.agents),last_tick_ago_s:u(t.last_tick_ago_s)??null,last_tick_ago:r(t.last_tick_ago),total_ticks:u(t.total_ticks),total_checkins:u(t.total_checkins),last_skip_reason:r(t.last_skip_reason)??null,last_tick_result:Mc(t.last_tick_result),active_self_heartbeats:K(t.active_self_heartbeats)}:null}function zm(t){return m(t)?{status:t.status,diagnostic:ya(t.diagnostic)}:null}function Em(t){return m(t)?{recovered:E(t.recovered)??!1,skipped_reason:r(t.skipped_reason)??null,before:ya(t.before),after:ya(t.after),down:t.down,up:t.up}:null}function jm(t,e){if(!m(t))return null;const n=Am(t.role),s=r(t.content)??r(t.preview);if(!s)return null;const a=$c(s);if(!a)return null;const i=it(t.ts_unix)??it(t.timestamp);return{id:`${n}-${i??"entry"}-${e}`,role:n,label:Tm(n),text:a,timestamp:i,delivery:"history",streamState:null,details:null}}function wm(t,e,n){const s=m(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((i,l)=>jm(i,l)).filter(i=>i!==null):[];return{name:t,diagnostic:ya(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function fl(t,e){const n=$t.value[t]??[];$t.value={...$t.value,[t]:[...n,e].slice(-50)}}function Yi(t,e,n){const s=$t.value[t]??[];$t.value={...$t.value,[t]:s.map(a=>a.id===e?n(a):a)}}function ko(t,e,n,s){Yi(t,e,a=>({...a,streamState:n,delivery:s}))}function Nm(t,e,n){Yi(t,e,s=>({...s,text:`${s.text}${n}`,streamState:"streaming",delivery:"streaming"}))}function Yt(t,e,n){Yi(t,e,s=>({...s,...n}))}function Dm(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Om(t,e){const s=($t.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(i=>Dm(a,i)));$t.value={...$t.value,[t]:[...e,...s].slice(-50)}}function io(t,e){se.value={...se.value,[t]:e},Om(t,e.history)}function js(t,e){const n=se.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};io(t,{...n,diagnostic:{...s,...e}})}function qm(t,e,n){Vi.set(t,e),Ji.set(t,n)}function Pc(t){Vi.delete(t),Ji.delete(t)}function Fm(t){return Vi.get(t)??null}function zc(t){const e=t.trim();if(!e)return;const n=Ji.get(e),s=Fm(e);n&&n.abort(),s&&Yt(e,s,{delivery:"timeout",streamState:null,error:"Stream cancelled",timestamp:new Date().toISOString()}),Pc(e),lt(ha,e,!1)}function Km(t,e,n){switch(n.type){case"RUN_STARTED":return ko(t,e,"opening","sending"),null;case"TEXT_MESSAGE_START":return ko(t,e,"streaming","streaming"),null;case"TEXT_MESSAGE_CONTENT":{const s=typeof n.delta=="string"?n.delta:"";return s&&Nm(t,e,s),null}case"TEXT_MESSAGE_END":return ko(t,e,"finalizing","streaming"),null;case"CUSTOM":if(n.name==="KEEPER_REPLY_DETAILS"){const s=hc(n.value);s&&Yt(t,e,{details:s})}return null;case"RUN_ERROR":return typeof n.value=="string"?n.value:(m(n.value)?r(n.value.message):null)??"Keeper stream failed";default:return null}}async function ba(){try{await ks()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Bm(t){Cm.value=t.trim()}async function Ec(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&se.value[n])return se.value[n];lt(di,n,!0),lt(Ut,n,null);try{const s=await jt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const i=wm(n,s,a);return io(n,i),i}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return lt(Ut,n,a),null}finally{lt(di,n,!1)}}async function Um(t,e){var c;const n=t.trim(),s=e.trim();if(!n||!s)return;zc(n);const a=`local-${Date.now()}`,i=`reply-${Date.now()}`;fl(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending",streamState:null,details:null}),fl(n,{id:i,role:"assistant",label:n,text:"",timestamp:null,delivery:"sending",streamState:"opening",details:null}),lt(ha,n,!0),lt(Ut,n,null);const l=new AbortController;qm(n,i,l);try{Yt(n,a,{delivery:"delivered"}),await $p(n,s,void 0,{signal:l.signal,onEvent:_=>{const v=Km(n,i,_);if(v)throw new Error(v)}});const d=($t.value[n]??[]).find(_=>_.id===i)??null,p=(d==null?void 0:d.text.trim())||"(empty reply)";Yt(n,i,{text:p,delivery:"delivered",streamState:null,timestamp:new Date().toISOString(),error:null}),js(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:p.slice(0,200),last_error:null})}catch(d){if(d instanceof Error&&d.name==="AbortError")throw Yt(n,i,{delivery:"timeout",streamState:null,error:"Stream cancelled",timestamp:new Date().toISOString()}),js(n,{last_reply_status:"error",last_error:"Stream cancelled"}),lt(Ut,n,"Stream cancelled"),d;if(!((c=($t.value[n]??[]).find(f=>f.id===i))!=null&&c.text.trim()))try{const f=await fp(n,s);Yt(n,i,{text:f.text.trim()||"(empty reply)",delivery:"delivered",streamState:null,details:f.details,error:null,timestamp:new Date().toISOString()}),Yt(n,a,{delivery:"delivered",error:null}),js(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(f.text.trim()||"(empty reply)").slice(0,200),last_error:null}),await ba();return}catch{}const v=d instanceof Error?d.message:`Failed to send direct message to ${n}`;throw Yt(n,i,{delivery:"error",streamState:null,error:v,timestamp:new Date().toISOString()}),Yt(n,a,{delivery:"error",error:v}),js(n,{last_reply_status:"error",last_error:v}),lt(Ut,n,v),d}finally{Pc(n),lt(ha,n,!1),await ba()}}async function Hm(t,e){const n=t.trim();if(!n)return null;lt(ui,n,!0),lt(Ut,n,null);try{const s=await bs({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=zm(s.result),i=(a==null?void 0:a.diagnostic)??null;if(i){const l=se.value[n];io(n,{name:n,diagnostic:i,history:(l==null?void 0:l.history)??$t.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ba(),i}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw lt(Ut,n,a),s}finally{lt(ui,n,!1)}}async function Wm(t,e){const n=t.trim();if(!n)return null;lt(pi,n,!0),lt(Ut,n,null);try{const s=await bs({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Em(s.result),i=(a==null?void 0:a.after)??null;if(i){const l=se.value[n];io(n,{name:n,diagnostic:i,history:(l==null?void 0:l.history)??$t.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ba(),i}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw lt(Ut,n,a),s}finally{lt(pi,n,!1)}}function Gm(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Jm(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}function Vm(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof a=="number"?Date.now()-a*1e3:null}function Ym(t){return Array.isArray(t)?t.map(e=>{if(!m(e))return null;const n=u(e.ts_unix),s=u(e.context_ratio);if(n==null||s==null)return null;const a=m(e.handoff)?e.handoff:null;return{ts:n,context_ratio:s,context_tokens:u(e.context_tokens)??0,context_max:u(e.context_max)??0,latency_ms:u(e.latency_ms)??0,generation:u(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:u(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:u(e.cost_usd)??Number.NaN,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?u(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function Xm(t){if(!m(t))return;const e={};for(const[n,s]of Object.entries(t)){if(n==="top_tools"){if(!Array.isArray(s))continue;const i=s.filter(l=>m(l)&&typeof l.tool=="string"&&l.tool.trim()!=="");i.length>0&&(e.top_tools=i);continue}const a=u(s);a!=null&&(e[n]=a)}return Object.keys(e).length>0?e:void 0}function Qm(t){if(!m(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);if(!e||!n||!s)return null;const a=r(t.quiet_reason)??null;return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:it(t.last_reply_at)??r(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:u(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:r(t.summary),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0,continuity_state:r(t.continuity_state)??null,continuity_summary:r(t.continuity_summary)??null}}function Zm(t){return(Array.isArray(t)?t:m(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!m(n))return null;const s=m(n.agent)?n.agent:null,a=m(n.context)?n.context:null,i=Xm(n.metrics_window),l=r(n.name);if(!l)return null;const c=u(n.context_ratio)??u(a==null?void 0:a.context_ratio),d=r(n.status)??r(s==null?void 0:s.status)??"offline",p=r(n.model)??r(n.active_model)??r(n.primary_model),_=K(n.skill_secondary),v=Ym(n.metrics_series),f=a?{source:r(a.source),context_ratio:u(a.context_ratio),context_tokens:u(a.context_tokens),context_max:u(a.context_max),message_count:u(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,h=s?{name:r(s.name),exists:typeof s.exists=="boolean"?s.exists:void 0,error:r(s.error),agent_type:r(s.agent_type),status:r(s.status),current_task:r(s.current_task)??null,joined_at:r(s.joined_at),last_seen:r(s.last_seen),last_seen_ago_s:u(s.last_seen_ago_s),capabilities:K(s.capabilities),is_zombie:typeof s.is_zombie=="boolean"?s.is_zombie:void 0}:void 0;return{name:l,runtime_class:n.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:typeof n.desired=="boolean"?n.desired:void 0,resident_registered:typeof n.resident_registered=="boolean"?n.resident_registered:void 0,reconcile_status:r(n.reconcile_status)??null,emoji:r(n.emoji),koreanName:r(n.koreanName)??r(n.korean_name),agent_name:r(n.agent_name),trace_id:r(n.trace_id),model:p,primary_model:r(n.primary_model),active_model:r(n.active_model),next_model_hint:r(n.next_model_hint)??null,status:Gm(d),presence_keepalive:typeof n.presence_keepalive=="boolean"?n.presence_keepalive:void 0,presence_keepalive_sec:u(n.presence_keepalive_sec),keepalive_running:typeof n.keepalive_running=="boolean"?n.keepalive_running:void 0,proactive_enabled:typeof n.proactive_enabled=="boolean"?n.proactive_enabled:void 0,proactive_idle_sec:u(n.proactive_idle_sec),proactive_cooldown_sec:u(n.proactive_cooldown_sec),last_heartbeat:r(n.last_heartbeat)??r(s==null?void 0:s.last_seen),generation:u(n.generation),turn_count:u(n.turn_count)??u(n.total_turns),keeper_age_s:u(n.keeper_age_s),last_turn_ago_s:u(n.last_turn_ago_s),last_handoff_ago_s:u(n.last_handoff_ago_s),last_compaction_ago_s:u(n.last_compaction_ago_s),last_proactive_ago_s:u(n.last_proactive_ago_s),last_proactive_preview:r(n.last_proactive_preview)??null,context_ratio:c,context_tokens:u(n.context_tokens)??u(a==null?void 0:a.context_tokens),context_max:u(n.context_max)??u(a==null?void 0:a.context_max),context_source:r(n.context_source)??r(a==null?void 0:a.source),context:f,traits:K(n.traits),interests:K(n.interests),primaryValue:r(n.primaryValue)??r(n.primary_value),activityLevel:u(n.activityLevel)??u(n.activity_level),memory_recent_note:r(n.memory_recent_note)??null,recent_input_preview:r(n.recent_input_preview)??null,recent_output_preview:r(n.recent_output_preview)??null,recent_tool_names:K(n.recent_tool_names)??[],allowed_tool_names:K(n.allowed_tool_names)??[],latest_tool_names:K(n.latest_tool_names)??[],latest_tool_call_count:u(n.latest_tool_call_count)??null,tool_audit_source:r(n.tool_audit_source)??null,tool_audit_at:it(n.tool_audit_at)??r(n.tool_audit_at)??null,conversation_tail_count:u(n.conversation_tail_count),k2k_count:u(n.k2k_count),handoff_count_total:u(n.handoff_count_total)??u(n.trace_history_count),compaction_count:u(n.compaction_count),last_compaction_saved_tokens:u(n.last_compaction_saved_tokens),diagnostic:Qm(n.diagnostic),skill_primary:r(n.skill_primary)??null,skill_secondary:_,skill_reason:r(n.skill_reason)??null,metrics_series:v.length>0?v:void 0,metrics_window:i,agent:h}}).filter(n=>n!==null)}function Ce(t){return(t??"").trim().toLowerCase()}function bt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function sa(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function ws(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Rn(t){return t.last_heartbeat??ws(t.last_turn_ago_s)??ws(t.last_proactive_ago_s)??ws(t.last_handoff_ago_s)??ws(t.last_compaction_ago_s)}function t_(t){const e=t.title.trim();return e||sa(t.content)}function e_(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function n_(t,e,n,s,a={}){var x;const i=Ce(t),l=e.filter(M=>Ce(M.assignee)===i&&(M.status==="claimed"||M.status==="in_progress")).length,c=n.filter(M=>Ce(M.from)===i).sort((M,I)=>bt(I.timestamp)-bt(M.timestamp))[0],d=s.filter(M=>Ce(M.agent)===i||Ce(M.author)===i).sort((M,I)=>bt(I.timestamp)-bt(M.timestamp))[0],p=(a.boardPosts??[]).filter(M=>Ce(M.author)===i).sort((M,I)=>bt(I.updated_at||I.created_at)-bt(M.updated_at||M.created_at))[0],_=(a.keepers??[]).filter(M=>Ce(M.name)===i&&Rn(M)!==null).sort((M,I)=>bt(Rn(I)??0)-bt(Rn(M)??0))[0],v=c?bt(c.timestamp):0,f=d?bt(d.timestamp):0,h=p?bt(p.updated_at||p.created_at):0,T=_?bt(Rn(_)??0):0,k=a.lastSeen?bt(a.lastSeen):0,C=((x=a.currentTask)==null?void 0:x.trim())||(l>0?`${l} claimed tasks`:null);if(v===0&&f===0&&h===0&&T===0&&k===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:C};const y=[c?{timestamp:c.timestamp,ts:v,text:sa(c.content)}:null,p?{timestamp:p.updated_at||p.created_at,ts:h,text:`Post: ${sa(t_(p))}`}:null,_?{timestamp:Rn(_),ts:T,text:e_(_)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:f,text:sa(d.text)}:null].filter(M=>M!==null).sort((M,I)=>I.ts-M.ts)[0];return y&&y.ts>=k?{activeAssignedCount:l,lastActivityAt:y.timestamp,lastActivityText:y.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:C??"Presence heartbeat"}}const Jt=g([]),ue=g([]),mi=g([]),ae=g([]),ut=g(null),s_=g(null),a_=g(null),jc=g([]),wc=g([]),Nc=g([]),Dc=g([]),Oc=g(null),qc=g([]),Xi=g([]),Fc=g([]),_i=g(new Map),ro=g([]),Xn=g("recent"),Me=g(!0),Kc=g(null),ne=g(""),cn=g([]),On=g(!1),Bc=g(new Map),Qi=g("unknown"),dn=g(null),vi=g(!1),Qn=g(!1),fi=g(!1),qn=g(!1),Zi=g(null),ka=g(!1),xa=g(null),Uc=g(null),gi=g(null),o_=g(null),i_=g(null),r_=g(null);Et(()=>Jt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const Hc=Et(()=>{const t=ue.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Wc=Et(()=>{const t=new Map,e=ue.value,n=mi.value,s=fa.value,a=ro.value,i=ae.value;for(const l of Jt.value)t.set(l.name.trim().toLowerCase(),n_(l.name,e,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:i}));return t});Et(()=>{var e;const t=new Map;for(const n of ae.value){const s=((e=n.status)==null?void 0:e.toLowerCase())??"";if(s==="offline"||s==="inactive"){t.set(n.name,"offline");continue}!n.metrics_series||n.metrics_series.length===0||t.set(n.name,Jm(n))}return t});const l_=12e4;Et(()=>{const t=Date.now(),e=new Set,n=_i.value;for(const s of ae.value){const a=Vm(s,n);a!=null&&t-a>l_&&e.add(s.name)}return e});function c_(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function d_(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function u_(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function p_(t){if(!m(t))return null;const e=r(t.name);return e?{name:e,agent_type:r(t.agent_type),status:d_(t.status),current_task:r(t.current_task)??null,joined_at:r(t.joined_at),last_seen:r(t.last_seen),capabilities:K(t.capabilities),emoji:r(t.emoji),koreanName:r(t.koreanName)??r(t.korean_name),model:r(t.model),traits:K(t.traits),interests:K(t.interests),activityLevel:u(t.activityLevel)??u(t.activity_level),primaryValue:r(t.primaryValue)??r(t.primary_value)}:null}function m_(t){if(!m(t))return null;const e=r(t.id),n=r(t.title);return!e||!n?null:{id:e,title:n,status:u_(t.status),priority:u(t.priority),assignee:r(t.assignee),description:r(t.description),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function __(t){if(!m(t))return null;const e=r(t.from)??r(t.from_agent)??"system",n=r(t.content)??"",s=r(t.timestamp)??new Date().toISOString();return{id:r(t.id),seq:u(t.seq),from:e,content:n,timestamp:s,type:r(t.type)}}function tr(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="ok"||e==="warn"||e==="bad"?e:"ok"}function v_(t){return m(t)?{active_sessions:u(t.active_sessions),blocked_sessions:u(t.blocked_sessions),active_operations:u(t.active_operations),blocked_operations:u(t.blocked_operations),runtime_pressure:u(t.runtime_pressure),worker_alerts:u(t.worker_alerts),continuity_alerts:u(t.continuity_alerts),priority_items:u(t.priority_items),todo_tasks:u(t.todo_tasks),claimed_tasks:u(t.claimed_tasks),running_tasks:u(t.running_tasks),done_tasks:u(t.done_tasks),cancelled_tasks:u(t.cancelled_tasks),keepers:u(t.keepers)}:null}function pe(t){if(!m(t))return null;const e=r(t.surface),n=r(t.label),s=r(t.target_type),a=r(t.target_id),i=r(t.focus_kind);return!e||!n||!s||!a||!i?null:{surface:e==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:i,operation_id:r(t.operation_id)??null,command_surface:r(t.command_surface)??null}}function f_(t){if(!m(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.summary),a=r(t.target_type),i=r(t.target_id);return!e||!s||!a||!i||n!=="session"&&n!=="operation"?null:{id:e,kind:n,severity:tr(t.severity),status:r(t.status),summary:s,target_type:a,target_id:i,linked_session_id:r(t.linked_session_id)??null,linked_operation_id:r(t.linked_operation_id)??null,last_seen_at:r(t.last_seen_at)??null,top_handoff:pe(t.top_handoff),intervene_handoff:pe(t.intervene_handoff),command_handoff:pe(t.command_handoff)}}function g_(t){if(!m(t))return null;const e=r(t.session_id),n=r(t.goal);return!e||!n?null:{session_id:e,goal:n,room:r(t.room)??null,status:r(t.status),health:r(t.health),member_names:K(t.member_names),linked_operation_id:r(t.linked_operation_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,runtime_blocker:r(t.runtime_blocker)??null,worker_gap_summary:r(t.worker_gap_summary)??null,last_activity_at:r(t.last_activity_at)??null,last_activity_summary:r(t.last_activity_summary)??null,communication_summary:r(t.communication_summary)??null,active_count:u(t.active_count),seen_count:u(t.seen_count),planned_count:u(t.planned_count),required_count:u(t.required_count),counts_basis:r(t.counts_basis)??null,top_handoff:pe(t.top_handoff),intervene_handoff:pe(t.intervene_handoff),command_handoff:pe(t.command_handoff)}}function $_(t){if(!m(t))return null;const e=r(t.operation_id),n=r(t.objective);return!e||!n?null:{operation_id:e,objective:n,status:r(t.status),stage:r(t.stage)??null,assigned_unit_id:r(t.assigned_unit_id)??null,assigned_unit_label:r(t.assigned_unit_label)??null,linked_session_id:r(t.linked_session_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,blocker_summary:r(t.blocker_summary)??null,search_status:r(t.search_status)??null,next_tool:r(t.next_tool)??null,updated_at:r(t.updated_at)??null,top_handoff:pe(t.top_handoff),command_handoff:pe(t.command_handoff)}}function gl(t){if(!m(t))return null;const e=r(t.name)??r(t.agent_name),n=r(t.note),s=r(t.focus),a=r(t.state);if(!e||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline")return null;const i=r(t.signal_truth),l=i==="live"||i==="stale"||i==="absent"?i:void 0,c=r(t.evidence_source),d=c==="message"||c==="presence"||c==="none"?c:void 0;return{name:e,agent_name:r(t.agent_name),status:r(t.status),tone:tr(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,last_signal_age_sec:u(t.last_signal_age_sec)??null,signal_truth:l,evidence_source:d,active_task_count:u(t.active_task_count),related_session_id:r(t.related_session_id)??null,related_operation_id:r(t.related_operation_id)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),model:r(t.model)??null,recent_output_preview:r(t.recent_output_preview)??null,recent_event:r(t.recent_event)??null}}function h_(t){return m(t)?{checked:u(t.checked),acted:u(t.acted),passed:u(t.passed),skipped:u(t.skipped),failed:u(t.failed),last_tick_at:r(t.last_tick_at)??null,last_skip_reason:r(t.last_skip_reason)??null,activity_report:r(t.activity_report)??null}:null}function y_(t){if(!m(t))return null;const e=r(t.agent_name),n=r(t.outcome);return!e||!n?null:{agent_name:e,trigger:r(t.trigger)??null,outcome:n,summary:r(t.summary)??null,reason:r(t.reason)??null,allowed_tool_names:K(t.allowed_tool_names)??[],used_tool_names:K(t.used_tool_names)??[],used_tool_call_count:u(t.used_tool_call_count)??null,action_kind:r(t.action_kind)??"none",tool_audit_source:r(t.tool_audit_source)??null,tool_audit_at:r(t.tool_audit_at)??null,checked_at:r(t.checked_at)??null,decision_reason:r(t.decision_reason)??null,worker_name:r(t.worker_name)??null,failure_reason:r(t.failure_reason)??null}}function b_(t){if(!m(t))return null;const e=r(t.name),n=r(t.note),s=r(t.focus),a=r(t.state);return!e||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:e,agent_name:r(t.agent_name)??null,status:r(t.status),tone:tr(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,last_autonomous_action_at:r(t.last_autonomous_action_at)??null,generation:u(t.generation),turn_count:u(t.turn_count),context_ratio:u(t.context_ratio)??null,continuity:r(t.continuity)??null,lifecycle:r(t.lifecycle)??null,related_session_id:r(t.related_session_id)??null,model:r(t.model)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),skill_reason:r(t.skill_reason)??null,recent_input_preview:r(t.recent_input_preview)??null,recent_output_preview:r(t.recent_output_preview)??null,recent_tool_names:K(t.recent_tool_names)??[],allowed_tool_names:K(t.allowed_tool_names)??[],latest_tool_names:K(t.latest_tool_names)??[],latest_tool_call_count:u(t.latest_tool_call_count)??null,tool_audit_source:r(t.tool_audit_source)??null,tool_audit_at:r(t.tool_audit_at)??null,last_proactive_preview:r(t.last_proactive_preview)??null,continuity_summary:r(t.continuity_summary)??null,skill_route_summary:r(t.skill_route_summary)??null}}function $l(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function k_(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>$l(s)-$l(a)).slice(-500)}function x_(t){if(!m(t))return;const e=r(t.release_version),n=it(t.started_at),s=u(t.uptime_seconds);if(!(!e||!n||s==null))return{release_version:e,commit:r(t.commit)??null,started_at:n,uptime_seconds:s}}function S_(t){if(m(t))return{enabled:t.enabled===!0,alive:t.alive===!0,status:r(t.status)??void 0,tick_in_progress:typeof t.tick_in_progress=="boolean"?t.tick_in_progress:void 0,tick_count:u(t.tick_count)??void 0,check_interval_sec:u(t.check_interval_sec)??void 0,last_tick_started_at:it(t.last_tick_started_at)??r(t.last_tick_started_at)??null,last_tick_completed_at:it(t.last_tick_completed_at)??r(t.last_tick_completed_at)??null,next_tick_due_at:it(t.next_tick_due_at)??r(t.next_tick_due_at)??null,last_health_check_at:it(t.last_health_check_at)??r(t.last_health_check_at)??null,last_intervention:r(t.last_intervention)??void 0,last_decision_source:r(t.last_decision_source)??void 0,last_action:r(t.last_action)??void 0,last_target:r(t.last_target)??null,last_reason:r(t.last_reason)??null,last_error:r(t.last_error)??null,circuit_open:typeof t.circuit_open=="boolean"?t.circuit_open:void 0,circuit_open_until:it(t.circuit_open_until)??r(t.circuit_open_until)??null,can_spawn:typeof t.can_spawn=="boolean"?t.can_spawn:void 0,can_retire:typeof t.can_retire=="boolean"?t.can_retire:void 0,last_spawn_attempt_at:it(t.last_spawn_attempt_at)??r(t.last_spawn_attempt_at)??null,last_retirement_attempt_at:it(t.last_retirement_attempt_at)??r(t.last_retirement_attempt_at)??null,spawns_today:u(t.spawns_today)??void 0,retirements_today:u(t.retirements_today)??void 0,health_summary:m(t.health_summary)?{total_agents:u(t.health_summary.total_agents)??void 0,active_agents:u(t.health_summary.active_agents)??void 0,idle_agents:u(t.health_summary.idle_agents)??void 0,todo_count:u(t.health_summary.todo_count)??void 0,high_priority_todo:u(t.health_summary.high_priority_todo)??void 0,orphan_count:u(t.health_summary.orphan_count)??void 0,homeostatic_score:u(t.health_summary.homeostatic_score)??void 0,needs_workers:typeof t.health_summary.needs_workers=="boolean"?t.health_summary.needs_workers:void 0}:void 0}}function C_(t){if(m(t))return{enabled:t.enabled===!0,mode:r(t.mode)??void 0,masc_enabled:typeof t.masc_enabled=="boolean"?t.masc_enabled:void 0,masc_loops_running:typeof t.masc_loops_running=="boolean"?t.masc_loops_running:void 0,runtime_owner:r(t.runtime_owner)??null,zombie_loop_running:typeof t.zombie_loop_running=="boolean"?t.zombie_loop_running:void 0,gc_loop_running:typeof t.gc_loop_running=="boolean"?t.gc_loop_running:void 0,lodge_enabled:typeof t.lodge_enabled=="boolean"?t.lodge_enabled:void 0,lodge_loop_started:typeof t.lodge_loop_started=="boolean"?t.lodge_loop_started:void 0,lodge_running:typeof t.lodge_running=="boolean"?t.lodge_running:void 0,last_zombie_cleanup:it(t.last_zombie_cleanup)??r(t.last_zombie_cleanup)??null,last_gc:it(t.last_gc)??r(t.last_gc)??null,last_lodge:it(t.last_lodge)??r(t.last_lodge)??null,last_zombie_result:r(t.last_zombie_result)??null,last_gc_result:r(t.last_gc_result)??null,last_lodge_result:m(t.last_lodge_result)?{ok:typeof t.last_lodge_result.ok=="boolean"?t.last_lodge_result.ok:void 0,message:r(t.last_lodge_result.message)??void 0}:null}}function A_(t){if(m(t))return{enabled:t.enabled===!0,started:t.started===!0,agent_name:r(t.agent_name)??null,llm_enabled:typeof t.llm_enabled=="boolean"?t.llm_enabled:void 0,uptime_s:u(t.uptime_s)??void 0,embedded_guardian_loops_running:typeof t.embedded_guardian_loops_running=="boolean"?t.embedded_guardian_loops_running:void 0,guardian_runtime_owner:r(t.guardian_runtime_owner)??null,consumers:K(t.consumers)}}function Gc(t,e){return m(t)?{...t,generated_at:e??it(t.generated_at)??void 0,build:x_(t.build),lodge:Pm(t.lodge)??void 0,gardener:S_(t.gardener)??void 0,guardian:C_(t.guardian)??void 0,sentinel:A_(t.sentinel)??void 0}:null}function Jc(t,e){return e?t?{...t,...e,build:e.build??t.build,generated_at:e.generated_at??t.generated_at}:e:t}function T_(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function I_(t){if(!m(t))return null;const e=u(t.iteration);if(e==null)return null;const n=u(t.metric_before)??0,s=u(t.metric_after)??n,a=m(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:u(t.delta)??s-n,changes:r(t.changes)??"",failed_attempts:r(t.failed_attempts)??"",next_suggestion:r(t.next_suggestion)??"",elapsed_ms:u(t.elapsed_ms)??0,cost_usd:u(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:u(a.tool_call_count)??0,tool_names:K(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function R_(t){var i,l;if(!m(t))return null;const e=r(t.loop_id);if(!e)return null;const n=u(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(I_).filter(c=>c!==null):[],a=u(t.current_metric)??((i=s[0])==null?void 0:i.metric_after)??n;return{loop_id:e,profile:r(t.profile)??"unknown",status:T_(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:r(t.error_message)??r(t.error_reason)??null,stop_reason:r(t.stop_reason)??r(t.reason)??null,current_iteration:u(t.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:u(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(t.target)??"",stagnation_streak:u(t.stagnation_streak)??0,stagnation_limit:u(t.stagnation_limit)??0,elapsed_seconds:u(t.elapsed_seconds)??0,updated_at:it(t.updated_at)??null,stopped_at:it(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:u(t.latest_tool_call_count)??0,latest_tool_names:K(t.latest_tool_names)??[],session_id:r(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function ks(){vi.value=!0;try{await Promise.all([Yc(),Pe()]),Uc.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{vi.value=!1}}async function Vc(){ka.value=!0,xa.value=null;try{const t=await Sp();Zi.value=t,r_.value=new Date().toISOString()}catch(t){xa.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{ka.value=!1}}function L_(t){var e;return((e=Zi.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function M_(t){var n;const e=((n=Zi.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(i=>i.id===t);if(a)return a}return null}function P_(t){var s,a;cn.value=(Array.isArray(t.goals)?t.goals:[]).map(i=>{if(!m(i))return null;const l=r(i.id),c=r(i.title),d=r(i.horizon),p=r(i.status),_=r(i.created_at),v=r(i.updated_at);return!l||!c||!d||!p||!_||!v?null:{id:l,horizon:d,title:c,metric:r(i.metric)??null,target_value:r(i.target_value)??null,due_date:r(i.due_date)??null,priority:u(i.priority)??3,status:p,parent_goal_id:r(i.parent_goal_id)??null,last_review_note:r(i.last_review_note)??null,last_review_at:r(i.last_review_at)??null,created_at:_,updated_at:v}}).filter(i=>i!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const i of n){const l=R_(i);l&&e.set(l.loop_id,l)}Bc.value=e,dn.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,Qi.value=dn.value?"error":e.size===0?"idle":"ready"}async function Yc(){try{const t=await hp(),e=Gc(t.status,t.generated_at);e&&(ut.value=Jc(ut.value,e))}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Pe(){var t;try{const e=await bp(),n=Gc(e.status,e.generated_at),s=(t=ut.value)==null?void 0:t.room;n&&(ut.value=Jc(ut.value,n));const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Jt.value=(Array.isArray(e.agents)?e.agents:[]).map(p_).filter(l=>l!==null),ue.value=(Array.isArray(e.tasks)?e.tasks:[]).map(m_).filter(l=>l!==null);const i=(Array.isArray(e.messages)?e.messages:[]).map(__).filter(l=>l!==null);mi.value=a?i:k_(mi.value,i),ae.value=Zm(e.keepers),a_.value=v_(e.summary),Oc.value=h_(e.lodge_tick),qc.value=(Array.isArray(e.lodge_checkins)?e.lodge_checkins:[]).map(y_).filter(l=>l!==null),jc.value=(Array.isArray(e.execution_queue)?e.execution_queue:Array.isArray(e.priority_queue)?e.priority_queue:[]).map(f_).filter(l=>l!==null),wc.value=(Array.isArray(e.session_briefs)?e.session_briefs:[]).map(g_).filter(l=>l!==null),Nc.value=(Array.isArray(e.operation_briefs)?e.operation_briefs:[]).map($_).filter(l=>l!==null),Dc.value=(Array.isArray(e.worker_support_briefs)?e.worker_support_briefs:Array.isArray(e.worker_briefs)?e.worker_briefs:[]).map(gl).filter(l=>l!==null),Xi.value=(Array.isArray(e.continuity_briefs)?e.continuity_briefs:[]).map(b_).filter(l=>l!==null),Fc.value=(Array.isArray(e.offline_worker_briefs)?e.offline_worker_briefs:[]).map(gl).filter(l=>l!==null),s_.value=null,Uc.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function me(){Qn.value=!0;try{const t=await kp(Xn.value,{excludeSystem:Me.value});ro.value=t.posts??[],gi.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Qn.value=!1}}async function _e(){var t;fi.value=!0;try{const e=ne.value||((t=ut.value)==null?void 0:t.room)||"default";ne.value||(ne.value=e);const n=await dm(e);Kc.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{fi.value=!1}}async function er(){On.value=!0,qn.value=!0;try{const t=await Rp();P_(t),o_.value=new Date().toISOString(),i_.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),Qi.value="error",dn.value=t instanceof Error?t.message:String(t)}finally{On.value=!1,qn.value=!1}}async function Xc(){return er()}const nr=g(null),$i=g(!1),Sa=g(null);function z_(t){return m(t)?{room:r(t.room)??r(t.current_room),room_base_path:r(t.room_base_path),cluster:r(t.cluster),project:r(t.project),paused:E(t.paused),version:r(t.version),generated_at:r(t.generated_at),tempo_interval_s:u(t.tempo_interval_s)}:null}function E_(t){return m(t)?{active_sessions:u(t.active_sessions),blocked_sessions:u(t.blocked_sessions),active_operations:u(t.active_operations),blocked_operations:u(t.blocked_operations),runtime_pressure:u(t.runtime_pressure),worker_alerts:u(t.worker_alerts),continuity_alerts:u(t.continuity_alerts),priority_items:u(t.priority_items),keepers:u(t.keepers)}:null}function j_(t){if(!m(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.severity),a=r(t.summary),i=r(t.target_type),l=r(t.target_id);return!e||!n||!s||!a||!i||!l?null:{id:e,kind:n,severity:s,summary:a,target_type:i,target_id:l,status:r(t.status),linked_session_id:r(t.linked_session_id)??null,linked_operation_id:r(t.linked_operation_id)??null,last_seen_at:r(t.last_seen_at)??null,top_handoff:m(t.top_handoff)?t.top_handoff:null,intervene_handoff:m(t.intervene_handoff)?t.intervene_handoff:null,command_handoff:m(t.command_handoff)?t.command_handoff:null}}function w_(t){if(!m(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function N_(t){if(!m(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:E(t.confirm_required),suggested_payload:m(t.suggested_payload)?t.suggested_payload:void 0,preview:t.preview}}function D_(t){return m(t)?{actor_filter:r(t.actor_filter)??null,filter_active:E(t.filter_active)??!1,visible_count:u(t.visible_count)??0,total_count:u(t.total_count)??0,hidden_count:u(t.hidden_count)??0,hidden_actors:K(t.hidden_actors),confirm_required_actions:ct(t.confirm_required_actions).flatMap(e=>{if(!m(e))return[];const n=r(e.action_type),s=r(e.target_type);return!n||!s?[]:[{action_type:n,target_type:s,description:r(e.description),confirm_required:E(e.confirm_required)}]})}:null}function O_(t){return m(t)?{count:u(t.count)??0,bad_count:u(t.bad_count)??0,warn_count:u(t.warn_count)??0,provenance:r(t.provenance)??null,top_item:w_(t.top_item)}:null}function q_(t){return m(t)?{count:u(t.count)??0,provenance:r(t.provenance)??null,top_action:N_(t.top_action)}:null}function F_(t){if(!m(t))return null;const e=r(t.label),n=r(t.reason),s=r(t.source),a=r(t.provenance);return!e||!n||!s||!a?null:{label:e,reason:n,source:s,provenance:a,target_kind:r(t.target_kind)??null,target_id:r(t.target_id)??null,suggested_tab:r(t.suggested_tab)??null,suggested_surface:r(t.suggested_surface)??null,suggested_params:m(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([i,l])=>{const c=r(l);return c?[i,c]:null}).filter(i=>i!==null)):{}}}function K_(t){const e=m(t)?t:{},n=m(e.room)?e.room:{},s=m(e.execution)?e.execution:{},a=m(e.command)?e.command:{},i=m(e.operator)?e.operator:{};return{generated_at:r(e.generated_at),room:{status:z_(n.status),counts:m(n.counts)?{agents:u(n.counts.agents),tasks:u(n.counts.tasks),keepers:u(n.counts.keepers)}:void 0,provenance:r(n.provenance)??null},execution:{summary:E_(s.summary),top_queue:j_(s.top_queue),provenance:r(s.provenance)??null},command:{active_operations:u(a.active_operations),active_detachments:u(a.active_detachments),pending_approvals:u(a.pending_approvals),bad_alerts:u(a.bad_alerts),warn_alerts:u(a.warn_alerts),moving_lanes:u(a.moving_lanes),active_lanes:u(a.active_lanes),provenance:r(a.provenance)??null},operator:{health:r(i.health)??null,attention_summary:O_(i.attention_summary),recommendation_summary:q_(i.recommendation_summary),pending_confirm_summary:D_(i.pending_confirm_summary),provenance:r(i.provenance)??null},focus:F_(e.focus)}}async function ze(){$i.value=!0,Sa.value=null;try{const t=await yp();nr.value=K_(t)}catch(t){Sa.value=t instanceof Error?t.message:"Failed to load room truth"}finally{$i.value=!1}}let aa=null;function B_(t){aa=t}let oa=null;function U_(t){oa=t}let ia=null;function H_(t){ia=t}const Ee={};let xo=null;function Ae(t,e,n=500){Ee[t]&&clearTimeout(Ee[t]),Ee[t]=setTimeout(()=>{e(),delete Ee[t]},n)}function W_(){const t=vc.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(_i.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),_i.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&Ae("execution",Pe),c_(e.type)&&(xo||(xo=setTimeout(()=>{ks(),oa==null||oa(),ia==null||ia(),xo=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&Ae("execution",Pe),e.type==="broadcast"&&Ae("execution",Pe),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&Ae("execution",Pe),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&Ae("board",me),e.type.startsWith("decision_")&&Ae("council",()=>aa==null?void 0:aa()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&Ae("mdal",Xc,350)}});return()=>{t();for(const e of Object.keys(Ee))clearTimeout(Ee[e]),delete Ee[e]}}let Fn=null;function G_(){Fn||(Fn=setInterval(()=>{ge.value,ks()},1e4))}function J_(){Fn&&(clearInterval(Fn),Fn=null)}const Tt=g(null),sr=g(null),Wt=g(null),Zn=g(!1),$e=g(null),ts=g(!1),hn=g(null),ot=g(!1),Ca=g([]);let V_=1;function Y_(t){return m(t)?{id:r(t.id),seq:u(t.seq),from:r(t.from)??r(t.from_agent)??"system",content:r(t.content)??"",timestamp:r(t.timestamp)??new Date().toISOString(),type:r(t.type)}:null}function X_(t){return m(t)?{room_id:r(t.room_id),current_room:r(t.current_room)??r(t.room),project:r(t.project),cluster:r(t.cluster),paused:E(t.paused),pause_reason:r(t.pause_reason)??null,paused_by:r(t.paused_by)??null,paused_at:r(t.paused_at)??null}:{}}function hl(t){if(!m(t))return;const e=Object.entries(t).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Qc(t){if(!m(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function Kn(t){if(!m(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:E(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Zc(t){return m(t)?{enabled:E(t.enabled),judge_online:E(t.judge_online),refreshing:E(t.refreshing),generated_at:r(t.generated_at)??null,expires_at:r(t.expires_at)??null,model_used:r(t.model_used)??null,keeper_name:r(t.keeper_name)??null,last_error:r(t.last_error)??null}:null}function So(t){return m(t)?{summary:r(t.summary)??null,confidence:u(t.confidence)??null,provenance:r(t.provenance)??null,authoritative:E(t.authoritative),surface:r(t.surface)??null,fresh_until:r(t.fresh_until)??null,keeper_name:r(t.keeper_name)??null,fallback_used:E(t.fallback_used),disagreement_with_truth:E(t.disagreement_with_truth)}:null}function Q_(t){return m(t)?{judgment_id:r(t.judgment_id)??void 0,surface:r(t.surface)??null,target_type:r(t.target_type)??null,target_id:r(t.target_id)??null,status:r(t.status)??null,summary:r(t.summary)??null,confidence:u(t.confidence)??null,generated_at:r(t.generated_at)??null,fresh_until:r(t.fresh_until)??null,keeper_name:r(t.keeper_name)??null,model_name:r(t.model_name)??null,runtime_name:r(t.runtime_name)??null,evidence_refs:K(t.evidence_refs),recommended_action:Kn(t.recommended_action),supersedes:K(t.supersedes),fallback_used:E(t.fallback_used),disagreement_with_truth:E(t.disagreement_with_truth),provenance:r(t.provenance)??null}:null}function Z_(t){return m(t)?{actor:r(t.actor)??null,spawn_agent:r(t.spawn_agent)??null,spawn_role:r(t.spawn_role)??null,spawn_model:r(t.spawn_model)??null,worker_class:r(t.worker_class)??null,parent_actor:r(t.parent_actor)??null,capsule_mode:r(t.capsule_mode)??null,runtime_pool:r(t.runtime_pool)??null,lane_id:r(t.lane_id)??null,controller_level:r(t.controller_level)??null,control_domain:r(t.control_domain)??null,supervisor_actor:r(t.supervisor_actor)??null,model_tier:r(t.model_tier)??null,task_profile:r(t.task_profile)??null,risk_level:r(t.risk_level)??null,routing_confidence:u(t.routing_confidence)??null,routing_reason:r(t.routing_reason)??null,status:r(t.status)??"unknown",turn_count:u(t.turn_count)??0,empty_note_turn_count:u(t.empty_note_turn_count)??0,has_turn:E(t.has_turn)??!1,last_turn_ts_iso:r(t.last_turn_ts_iso)??null}:null}function tv(t){if(!m(t))return null;const e=r(t.session_id);return e?{session_id:e,goal:r(t.goal),status:r(t.status),health:r(t.health),scale_profile:r(t.scale_profile),control_profile:r(t.control_profile),planned_worker_count:u(t.planned_worker_count),active_agent_count:u(t.active_agent_count),last_turn_age_sec:u(t.last_turn_age_sec)??null,attention_count:u(t.attention_count),recommended_action_count:u(t.recommended_action_count),top_attention:Qc(t.top_attention),top_recommendation:Kn(t.top_recommendation)}:null}function yl(t){if(!m(t))return null;const e=r(t.loop_id),n=r(t.status);return!e&&!n?null:{loop_id:e??null,session_id:r(t.session_id)??null,status:n??null,current_cycle:u(t.current_cycle)??void 0,best_score:u(t.best_score)??null,last_decision:r(t.last_decision)??null,target_file:r(t.target_file)??null,workdir:r(t.workdir)??null,source_workdir:r(t.source_workdir)??null,program_note:r(t.program_note)??null,operation_id:r(t.operation_id)??null,queued_hypothesis:r(t.queued_hypothesis)??null,warnings:ct(t.warnings).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),error:r(t.error)??null}}function td(t){const e=m(t)?t:{};return{trace_id:r(e.trace_id),target_type:r(e.target_type)??"room",target_id:r(e.target_id)??null,health:r(e.health),judgment_owner:r(e.judgment_owner)??null,authoritative_judgment_available:E(e.authoritative_judgment_available),resident_judge_runtime:Zc(e.resident_judge_runtime),judgment:Q_(e.judgment),active_guidance_layer:r(e.active_guidance_layer)??null,active_summary:So(e.active_summary),active_recommended_actions:ct(e.active_recommended_actions).map(Kn).filter(n=>n!==null),active_recommendation_source:r(e.active_recommendation_source)??null,active_recommendation_summary:So(e.active_recommendation_summary),fallback_recommended_actions:ct(e.fallback_recommended_actions).map(Kn).filter(n=>n!==null),recommendation_summary:So(e.recommendation_summary),swarm_status:m(e.swarm_status)?e.swarm_status:void 0,attention_items:ct(e.attention_items).map(Qc).filter(n=>n!==null),recommended_actions:ct(e.recommended_actions).map(Kn).filter(n=>n!==null),session_cards:ct(e.session_cards).map(tv).filter(n=>n!==null),worker_cards:ct(e.worker_cards).map(Z_).filter(n=>n!==null)}}function ev(t){if(!m(t))return null;const e=m(t.status)?t.status:void 0,n=m(t.summary)?t.summary:m(e==null?void 0:e.summary)?e.summary:void 0,s=m(t.session)?t.session:m(e==null?void 0:e.session)?e.session:void 0,a=r(t.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const i=hl(t.report_paths)??hl(e==null?void 0:e.report_paths),l=ct(t.recent_events,["events"]).filter(m);return{session_id:a,status:r(t.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:u(t.progress_pct)??u(n==null?void 0:n.progress_pct),elapsed_sec:u(t.elapsed_sec)??u(n==null?void 0:n.elapsed_sec),remaining_sec:u(t.remaining_sec)??u(n==null?void 0:n.remaining_sec),done_delta_total:u(t.done_delta_total)??u(n==null?void 0:n.done_delta_total),summary:n,team_health:m(t.team_health)?t.team_health:m(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:m(t.communication_metrics)?t.communication_metrics:m(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:m(t.orchestration_state)?t.orchestration_state:m(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:m(t.cascade_metrics)?t.cascade_metrics:m(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,linked_autoresearch:yl(t.linked_autoresearch)??yl(e==null?void 0:e.linked_autoresearch)??null,session:s,recent_events:l}}function bl(t){if(!m(t))return null;const e=r(t.name);if(!e)return null;const n=m(t.context)?t.context:void 0;return{name:e,runtime_class:t.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:E(t.desired),resident_registered:E(t.resident_registered),agent_name:r(t.agent_name),status:r(t.status),autonomy_level:r(t.autonomy_level),context_ratio:u(t.context_ratio)??u(n==null?void 0:n.context_ratio),generation:u(t.generation),active_goal_ids:K(t.active_goal_ids),last_autonomous_action_at:r(t.last_autonomous_action_at)??null,last_turn_ago_s:u(t.last_turn_ago_s),model:r(t.model)??r(t.active_model)??r(t.primary_model)}}function nv(t){const e=m(t)?t:{},n=bc(e.pending_confirm_envelope);return{room:X_(e.room),sessions:ct(e.sessions,["items","sessions"]).map(ev).filter(s=>s!==null),keepers:ct(e.keepers,["items","keepers"]).map(bl).filter(s=>s!==null),resident_judge_runtime:Zc(e.resident_judge_runtime),persistent_agents:ct(e.persistent_agents,["items","persistent_agents"]).map(bl).filter(s=>s!==null),recent_messages:ct(e.recent_messages,["messages"]).map(Y_).filter(s=>s!==null),pending_confirms:(n==null?void 0:n.items)??ct(e.pending_confirms,["items","confirms"]).map(so).filter(s=>s!==null),pending_confirm_envelope:n??void 0,pending_confirm_summary:(n==null?void 0:n.summary)??Ki(e.pending_confirm_summary)??void 0,available_actions:ct(e.available_actions,["actions"]).map(yc).filter(s=>s!==null)}}function Ns(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function kl(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function Aa(t){Ca.value=[{...t,id:V_++,at:new Date().toISOString()},...Ca.value].slice(0,20)}function ed(t){return t.confirm_required?Ns(t.preview)||"Confirmation required":Ns(t.result)||Ns(t.executed_action)||Ns(t.delegated_tool_result)||t.status}async function mt(){Zn.value=!0,$e.value=null;try{const t=await Pp();Tt.value=nv(t)}catch(t){$e.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Zn.value=!1}}async function Fe(){ts.value=!0,hn.value=null;try{const t=await Sc({targetType:"room"});sr.value=td(t)}catch(t){hn.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{ts.value=!1}}async function he(t){if(!t){Wt.value=null;return}ts.value=!0,hn.value=null;try{const e=await Sc({targetType:"team_session",targetId:t,includeWorkers:!0});Wt.value=td(e)}catch(e){hn.value=e instanceof Error?e.message:"Failed to load session digest"}finally{ts.value=!1}}async function nd(t){var e;ot.value=!0,$e.value=null;try{const n=await bs(t);return Aa({actor:t.actor,action_type:t.action_type,target_label:kl(t),outcome:n.confirm_required?"preview":"executed",message:ed(n),delegated_tool:n.delegated_tool}),await mt(),await Fe(),(e=Wt.value)!=null&&e.target_id&&await he(Wt.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw $e.value=s,Aa({actor:t.actor,action_type:t.action_type,target_label:kl(t),outcome:"error",message:s}),n}finally{ot.value=!1}}async function sd(t,e,n="confirm"){var s;ot.value=!0,$e.value=null;try{const a=await Cc(t,e,n);return Aa({actor:t,action_type:n,target_label:e,outcome:"confirmed",message:ed(a),delegated_tool:a.delegated_tool}),await mt(),await Fe(),(s=Wt.value)!=null&&s.target_id&&await he(Wt.value.target_id),a}catch(a){const i=a instanceof Error?a.message:"Operator confirmation failed";throw $e.value=i,Aa({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:i}),a}finally{ot.value=!1}}H_(()=>{var t;mt(),Fe(),(t=Wt.value)!=null&&t.target_id&&he(Wt.value.target_id)});const xs=g(null),hi=g(!1),Ta=g(null),ad=g(null),Qe=g(!1),Le=g(null),yi=g(null),ra=g(!1),la=g(null);let un=null;function xl(){un!==null&&(window.clearTimeout(un),un=null)}function sv(t=1500){un===null&&(un=window.setTimeout(()=>{un=null,Ia(!1)},t))}function N(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function b(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function w(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function pn(t){return typeof t=="boolean"?t:void 0}function V(t,e=[]){if(Array.isArray(t))return t;if(!N(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function Sn(t){if(!N(t))return null;const e=b(t.kind),n=b(t.summary),s=b(t.target_type);return!e||!n||!s?null:{kind:e,severity:b(t.severity)??"warn",summary:n,target_type:s,target_id:b(t.target_id)??null,actor:b(t.actor)??null,evidence:t.evidence}}function Be(t){if(!N(t))return null;const e=b(t.action_type),n=b(t.target_type),s=b(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:b(t.target_id)??null,severity:b(t.severity)??"warn",reason:s,confirm_required:pn(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function av(t){if(!N(t))return null;const e=b(t.session_id);return e?{session_id:e,goal:b(t.goal),status:b(t.status),health:b(t.health),scale_profile:b(t.scale_profile),control_profile:b(t.control_profile),planned_worker_count:w(t.planned_worker_count),active_agent_count:w(t.active_agent_count),last_turn_age_sec:w(t.last_turn_age_sec)??null,attention_count:w(t.attention_count),recommended_action_count:w(t.recommended_action_count),top_attention:Sn(t.top_attention),top_recommendation:Be(t.top_recommendation)}:null}function ov(t){if(!N(t))return null;const e=b(t.session_id);if(!e)return null;const n=N(t.status)?t.status:t,s=N(n.summary)?n.summary:void 0;return{session_id:e,status:b(t.status)??b(s==null?void 0:s.status)??(N(n.session)?b(n.session.status):void 0),progress_pct:w(t.progress_pct)??w(s==null?void 0:s.progress_pct),elapsed_sec:w(t.elapsed_sec)??w(s==null?void 0:s.elapsed_sec),remaining_sec:w(t.remaining_sec)??w(s==null?void 0:s.remaining_sec),done_delta_total:w(t.done_delta_total)??w(s==null?void 0:s.done_delta_total),summary:N(t.summary)?t.summary:s,team_health:N(t.team_health)?t.team_health:N(n.team_health)?n.team_health:void 0,communication_metrics:N(t.communication_metrics)?t.communication_metrics:N(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:N(t.orchestration_state)?t.orchestration_state:N(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:N(t.cascade_metrics)?t.cascade_metrics:N(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:N(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,i])=>{const l=b(i);return l?[a,l]:null}).filter(a=>a!==null)):N(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,i])=>{const l=b(i);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:N(t.session)?t.session:N(n.session)?n.session:void 0,recent_events:V(t.recent_events,["events"]).filter(N)}}function iv(t){if(!N(t))return null;const e=b(t.name);return e?{name:e,agent_name:b(t.agent_name),status:b(t.status),autonomy_level:b(t.autonomy_level),context_ratio:w(t.context_ratio),generation:w(t.generation),active_goal_ids:V(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:b(t.last_autonomous_action_at)??null,last_turn_ago_s:w(t.last_turn_ago_s),model:b(t.model)}:null}function rv(t){if(!N(t))return null;const e=b(t.confirm_token)??b(t.token);return e?{confirm_token:e,actor:b(t.actor),action_type:b(t.action_type),target_type:b(t.target_type),target_id:b(t.target_id)??null,delegated_tool:b(t.delegated_tool),created_at:b(t.created_at),preview:t.preview}:null}function lv(t){if(!N(t))return null;const e=b(t.action_type),n=b(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:b(t.description),confirm_required:pn(t.confirm_required)}}function cv(t){const e=N(t)?t:{};return{room_health:b(e.room_health),cluster:b(e.cluster),project:b(e.project),current_room:b(e.current_room)??b(e.room)??null,paused:pn(e.paused),tempo_interval_s:w(e.tempo_interval_s),active_agents:w(e.active_agents),keeper_pressure:w(e.keeper_pressure),active_operations:w(e.active_operations),pending_approvals:w(e.pending_approvals),incident_count:w(e.incident_count),recommended_action_count:w(e.recommended_action_count),top_attention:Sn(e.top_attention),top_action:Be(e.top_action)}}function dv(t){const e=N(t)?t:{},n=N(e.swarm_overview)?e.swarm_overview:{};return{health:b(e.health),active_operations:w(e.active_operations),pending_approvals:w(e.pending_approvals),swarm_overview:{active_lanes:w(n.active_lanes),moving_lanes:w(n.moving_lanes),stalled_lanes:w(n.stalled_lanes),projected_lanes:w(n.projected_lanes),last_movement_at:b(n.last_movement_at)??null},top_attention:Sn(e.top_attention),top_action:Be(e.top_action),session_cards:V(e.session_cards).map(av).filter(s=>s!==null)}}function uv(t){const e=N(t)?t:{};return{sessions:V(e.sessions,["items"]).map(ov).filter(n=>n!==null),keepers:V(e.keepers,["items"]).map(iv).filter(n=>n!==null),pending_confirms:V(e.pending_confirms).map(rv).filter(n=>n!==null),available_actions:V(e.available_actions).map(lv).filter(n=>n!==null)}}function pv(t){if(!N(t))return null;const e=b(t.id),n=b(t.kind),s=b(t.summary),a=b(t.target_type);return!e||!n||!s||!a?null:{id:e,kind:n,severity:b(t.severity)??"warn",summary:s,target_type:a,target_id:b(t.target_id)??null,top_action:Be(t.top_action),related_session_ids:V(t.related_session_ids).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),related_agent_names:V(t.related_agent_names).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),evidence_preview:V(t.evidence_preview).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),last_seen_at:b(t.last_seen_at)??null}}function od(t){if(!N(t))return null;const e=b(t.session_id),n=b(t.goal);return!e||!n?null:{session_id:e,goal:n,room:b(t.room)??null,status:b(t.status),health:b(t.health),member_names:V(t.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:b(t.started_at)??null,elapsed_sec:w(t.elapsed_sec)??null,operation_id:b(t.operation_id)??null,blocker_summary:b(t.blocker_summary)??null,last_event_at:b(t.last_event_at)??null,last_event_summary:b(t.last_event_summary)??null,communication_summary:b(t.communication_summary)??null,active_count:w(t.active_count),seen_count:w(t.seen_count),planned_count:w(t.planned_count),required_count:w(t.required_count),counts_basis:b(t.counts_basis)??null,related_attention_count:w(t.related_attention_count)??0,top_attention:Sn(t.top_attention),top_recommendation:Be(t.top_recommendation)}}function id(t){if(!N(t))return null;const e=b(t.agent_name);return e?{agent_name:e,display_name:b(t.display_name)??null,is_live:typeof t.is_live=="boolean"?t.is_live:void 0,current_work:b(t.current_work)??null,recent_input_preview:b(t.recent_input_preview)??null,recent_output_preview:b(t.recent_output_preview)??null,recent_tool_names:V(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_activity_at:b(t.last_activity_at)??null}:null}function rd(t){if(!N(t))return null;const e=b(t.operation_id);return e?{operation_id:e,status:b(t.status),stage:b(t.stage)??null,detachment_status:b(t.detachment_status)??null,objective:b(t.objective)??null,updated_at:b(t.updated_at)??null}:null}function ld(t){if(!N(t))return null;const e=b(t.name);return e?{name:e,agent_name:b(t.agent_name)??null,status:b(t.status),generation:w(t.generation),context_ratio:w(t.context_ratio)??null,last_turn_ago_s:w(t.last_turn_ago_s)??null,current_work:b(t.current_work)??null}:null}function cd(t){const e=od(t);return e?{...e,member_previews:V(N(t)?t.member_previews:void 0).map(id).filter(n=>n!==null),operation_badges:V(N(t)?t.operation_badges:void 0).map(rd).filter(n=>n!==null),keeper_refs:V(N(t)?t.keeper_refs:void 0).map(ld).filter(n=>n!==null)}:null}function mv(t){if(!N(t))return null;const e=b(t.agent_name);return e?{agent_name:e,display_name:b(t.display_name)??null,is_live:typeof t.is_live=="boolean"?t.is_live:void 0,archived_reason:b(t.archived_reason)??null,status:b(t.status),where:b(t.where)??null,with_whom:V(t.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:b(t.current_work)??null,related_session_id:b(t.related_session_id)??null,related_attention_count:w(t.related_attention_count)??0,last_activity_at:b(t.last_activity_at)??null,last_activity_age_sec:w(t.last_activity_age_sec)??null,signal_truth:b(t.signal_truth)==="live"||b(t.signal_truth)==="stale"||b(t.signal_truth)==="archived"||b(t.signal_truth)==="unknown"?b(t.signal_truth):void 0,evidence_source:b(t.evidence_source)==="message"||b(t.evidence_source)==="presence"||b(t.evidence_source)==="session"||b(t.evidence_source)==="none"?b(t.evidence_source):void 0,recent_output_preview:b(t.recent_output_preview)??null,recent_input_preview:b(t.recent_input_preview)??null,recent_tool_names:V(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean)}:null}function _v(t){if(!N(t))return null;const e=b(t.name);return e?{name:e,agent_name:b(t.agent_name)??null,status:b(t.status),generation:w(t.generation),context_ratio:w(t.context_ratio)??null,last_turn_ago_s:w(t.last_turn_ago_s)??null,current_work:b(t.current_work)??null,last_autonomous_action_at:b(t.last_autonomous_action_at)??null,allowed_tool_names:V(t.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:V(t.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:w(t.latest_tool_call_count)??null,tool_audit_source:b(t.tool_audit_source)??null,tool_audit_at:b(t.tool_audit_at)??null}:null}function vv(t){if(!N(t))return null;const e=b(t.id),n=b(t.signal_type),s=b(t.summary),a=b(t.target_type);return!e||!n||!s||!a?null:{id:e,signal_type:n==="action"?"action":"attention",severity:b(t.severity)??"warn",summary:s,target_type:a,target_id:b(t.target_id)??null,attention:Sn(t.attention),action:Be(t.action)}}function fv(t){const e=N(t)?t:{},n=V(e.session_briefs).map(od).filter(a=>a!==null),s=V(e.sessions).map(cd).filter(a=>a!==null);return{generated_at:b(e.generated_at),summary:cv(e.summary),incidents:V(e.incidents).map(Sn).filter(a=>a!==null),recommended_actions:V(e.recommended_actions).map(Be).filter(a=>a!==null),command_focus:dv(e.command_focus),operator_targets:uv(e.operator_targets),attention_queue:V(e.attention_queue).map(pv).filter(a=>a!==null),sessions:s.length>0?s:n.map(a=>({...a,member_previews:[],operation_badges:[],keeper_refs:[]})),session_briefs:n,agent_briefs:V(e.agent_briefs).map(mv).filter(a=>a!==null),keeper_briefs:V(e.keeper_briefs).map(_v).filter(a=>a!==null),internal_signals:V(e.internal_signals).map(vv).filter(a=>a!==null)}}function gv(t){if(!N(t))return null;const e=b(t.id),n=b(t.summary);return!e||!n?null:{id:e,timestamp:b(t.timestamp)??null,event_type:b(t.event_type),actor:b(t.actor)??null,summary:n}}function $v(t){const e=N(t)?t:{};return{generated_at:b(e.generated_at),session_id:b(e.session_id)??"",session:cd(e.session),timeline:V(e.timeline).map(gv).filter(n=>n!==null),participants:V(e.participants).map(id).filter(n=>n!==null),operations:V(e.operations).map(rd).filter(n=>n!==null),keepers:V(e.keepers).map(ld).filter(n=>n!==null),error:b(e.error)??null}}function hv(t){if(!N(t))return null;const e=b(t.id),n=b(t.label),s=b(t.summary);if(!e||!n||!s)return null;const a=b(t.status)??"unclear";return{id:e,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:b(t.signal_class)==="metadata_gap"||b(t.signal_class)==="mixed"||b(t.signal_class)==="operational_risk"?b(t.signal_class):void 0,evidence_quality:b(t.evidence_quality)==="strong"||b(t.evidence_quality)==="partial"||b(t.evidence_quality)==="missing"?b(t.evidence_quality):void 0,evidence:V(t.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function yv(t){if(!N(t))return null;const e=b(t.kind),n=b(t.summary),s=b(t.scope_type),a=b(t.severity);return!e||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:e,summary:n,scope_type:s,scope_id:b(t.scope_id)??null,severity:a}}function bv(t){const e=N(t)?t:{},n=N(e.basis)?e.basis:{},s=b(e.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:b(e.generated_at),cached:pn(e.cached),stale:pn(e.stale),refreshing:pn(e.refreshing),status:a,summary:b(e.summary)??null,model:b(e.model)??null,ttl_sec:w(e.ttl_sec),criteria:V(e.criteria).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),basis:{current_room:b(n.current_room)??null,crew_count:w(n.crew_count),agent_count:w(n.agent_count),keeper_count:w(n.keeper_count)},metadata_gap_count:w(e.metadata_gap_count),metadata_gaps:V(e.metadata_gaps).map(yv).filter(i=>i!==null),sections:V(e.sections).map(hv).filter(i=>i!==null),error:b(e.error)??null,last_error:b(e.last_error)??null}}async function dd(){hi.value=!0,Ta.value=null;try{const t=await Cp();xs.value=fv(t)}catch(t){Ta.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{hi.value=!1}}async function kv(t){if(!t){yi.value=null,la.value=null,ra.value=!1;return}ra.value=!0,la.value=null;try{const e=await Ap(t);yi.value=$v(e)}catch(e){la.value=e instanceof Error?e.message:"Failed to load session detail"}finally{ra.value=!1}}async function Ia(t=!1){Qe.value=!0,Le.value=null;try{const e=await Tp(t),n=bv(e);ad.value=n,n.refreshing||n.status==="pending"?sv():xl()}catch(e){Le.value=e instanceof Error?e.message:"Failed to load mission briefing",xl()}finally{Qe.value=!1}}const ud=g(null),bi=g(!1),Ze=g(null);async function pd(t,e){bi.value=!0,Ze.value=null;try{ud.value=await Ip(t,e)}catch(n){Ze.value=n instanceof Error?n.message:String(n)}finally{bi.value=!1}}const ar=g(null),Vt=g(null),Ra=g(!1),La=g(!1),Ma=g(null),Pa=g(null),ki=g(null),za=g(null),X=g("warroom"),Ss=g(null),xi=g(!1),Ea=g(null),Ue=g(null),ja=g(!1),wa=g(null),or=g(null),Si=g(!1),Na=g(null),Cs=g(null),Ci=g(!1),Da=g(null),es=g(null),Oa=g(!1),ns=g(null),mn=g(null);let jn=null;function ir(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"&&t!=="orchestra"}function md(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function _d(){const e=md().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function vd(){const e=md().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function xv(t){if(m(t))return{policy_class:r(t.policy_class),approval_class:r(t.approval_class),tool_allowlist:K(t.tool_allowlist),model_allowlist:K(t.model_allowlist),requires_human_for:K(t.requires_human_for),autonomy_level:r(t.autonomy_level),escalation_timeout_sec:u(t.escalation_timeout_sec),kill_switch:E(t.kill_switch),frozen:E(t.frozen)}}function Sv(t){if(m(t))return{headcount_cap:u(t.headcount_cap),active_operation_cap:u(t.active_operation_cap),max_cost_usd:u(t.max_cost_usd),max_tokens:u(t.max_tokens)}}function rr(t){if(!m(t))return null;const e=r(t.unit_id),n=r(t.label),s=r(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:r(t.parent_unit_id)??null,leader_id:r(t.leader_id)??null,roster:K(t.roster),capability_profile:K(t.capability_profile),source:r(t.source),created_at:r(t.created_at),updated_at:r(t.updated_at),policy:xv(t.policy),budget:Sv(t.budget)}}function fd(t){if(!m(t))return null;const e=rr(t.unit);return e?{unit:e,leader_status:r(t.leader_status),roster_total:u(t.roster_total),roster_live:u(t.roster_live),active_operation_count:u(t.active_operation_count),health:r(t.health),reasons:K(t.reasons),children:Array.isArray(t.children)?t.children.map(fd).filter(n=>n!==null):[]}:null}function Cv(t){if(m(t))return{total_units:u(t.total_units),company_count:u(t.company_count),platoon_count:u(t.platoon_count),squad_count:u(t.squad_count),leaf_agent_unit_count:u(t.leaf_agent_unit_count),live_agent_count:u(t.live_agent_count),managed_unit_count:u(t.managed_unit_count),active_operation_count:u(t.active_operation_count)}}function gd(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),source:r(e.source),summary:Cv(e.summary),units:Array.isArray(e.units)?e.units.map(fd).filter(n=>n!==null):[]}}function Av(t){if(!m(t))return null;const e=r(t.kind),n=r(t.status);return!e||!n?null:{kind:e,chain_id:r(t.chain_id)??null,goal:r(t.goal)??null,run_id:r(t.run_id)??null,status:n,viewer_path:r(t.viewer_path)??null,last_sync_at:r(t.last_sync_at)??null}}function lo(t){if(!m(t))return null;const e=r(t.operation_id),n=r(t.objective),s=r(t.assigned_unit_id),a=r(t.trace_id),i=r(t.status);return!e||!n||!s||!a||!i?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:r(t.autonomy_level),policy_class:r(t.policy_class),budget_class:r(t.budget_class),detachment_session_id:r(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(t.checkpoint_ref)??null,active_goal_ids:K(t.active_goal_ids),note:r(t.note)??null,created_by:r(t.created_by),source:r(t.source),status:i,chain:Av(t.chain),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function Tv(t){if(!m(t))return null;const e=lo(t.operation);return e?{operation:e,assigned_unit_label:r(t.assigned_unit_label)}:null}function Ln(t){if(m(t))return{tone:r(t.tone),pending_ops:u(t.pending_ops),blocked_ops:u(t.blocked_ops),in_flight_ops:u(t.in_flight_ops),pipeline_stalls:u(t.pipeline_stalls),bus_traffic:u(t.bus_traffic),l1_hit_rate:u(t.l1_hit_rate),invalidation_count:u(t.invalidation_count),current_pending:u(t.current_pending),current_in_flight:u(t.current_in_flight),cdb_wakeups:u(t.cdb_wakeups),total_stolen:u(t.total_stolen),avg_best_score:u(t.avg_best_score),avg_candidate_count:u(t.avg_candidate_count),best_first_operations:u(t.best_first_operations),active_sessions:u(t.active_sessions),commit_rate:u(t.commit_rate),total_speculations:u(t.total_speculations)}}function Iv(t){if(!m(t))return;const e=m(t.pipeline)?t.pipeline:void 0,n=m(t.cache)?t.cache:void 0,s=m(t.ooo)?t.ooo:void 0,a=m(t.speculative)?t.speculative:void 0,i=m(t.search_fabric)?t.search_fabric:void 0,l=m(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:u(e.total_ops),completed_ops:u(e.completed_ops),stalled_cycles:u(e.stalled_cycles),hazards_detected:u(e.hazards_detected),forwarding_used:u(e.forwarding_used),pipeline_flushes:u(e.pipeline_flushes),ipc:u(e.ipc)}:void 0,cache:n?{total_reads:u(n.total_reads),total_writes:u(n.total_writes),l1_hit_rate:u(n.l1_hit_rate),invalidation_count:u(n.invalidation_count),writeback_count:u(n.writeback_count),bus_traffic:u(n.bus_traffic)}:void 0,ooo:s?{agent_count:u(s.agent_count),total_added:u(s.total_added),total_issued:u(s.total_issued),total_completed:u(s.total_completed),total_stolen:u(s.total_stolen),cdb_wakeups:u(s.cdb_wakeups),stall_cycles:u(s.stall_cycles),global_cdb_events:u(s.global_cdb_events),current_pending:u(s.current_pending),current_in_flight:u(s.current_in_flight)}:void 0,speculative:a?{total_speculations:u(a.total_speculations),total_commits:u(a.total_commits),total_aborts:u(a.total_aborts),commit_rate:u(a.commit_rate),total_fast_calls:u(a.total_fast_calls),total_cost_usd:u(a.total_cost_usd),active_sessions:u(a.active_sessions)}:void 0,search_fabric:i?{total_operations:u(i.total_operations),best_first_operations:u(i.best_first_operations),legacy_operations:u(i.legacy_operations),blocked_operations:u(i.blocked_operations),ready_operations:u(i.ready_operations),research_pipeline_operations:u(i.research_pipeline_operations),avg_candidate_count:u(i.avg_candidate_count),avg_best_score:u(i.avg_best_score),top_stage:r(i.top_stage)??null}:void 0,signals:l?{issue_pressure:Ln(l.issue_pressure),cache_contention:Ln(l.cache_contention),scheduler_efficiency:Ln(l.scheduler_efficiency),routing_confidence:Ln(l.routing_confidence),speculative_posture:Ln(l.speculative_posture)}:void 0}}function $d(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),active:u(n.active),paused:u(n.paused),managed:u(n.managed),projected:u(n.projected)}:void 0,microarch:Iv(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(Tv).filter(s=>s!==null):[]}}function hd(t){if(!m(t))return null;const e=r(t.detachment_id),n=r(t.operation_id),s=r(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:r(t.leader_id)??null,roster:K(t.roster),session_id:r(t.session_id)??null,checkpoint_ref:r(t.checkpoint_ref)??null,runtime_kind:r(t.runtime_kind)??null,runtime_ref:r(t.runtime_ref)??null,source:r(t.source),status:r(t.status),last_event_at:r(t.last_event_at)??null,last_progress_at:r(t.last_progress_at)??null,heartbeat_deadline:r(t.heartbeat_deadline)??null,created_at:r(t.created_at),updated_at:r(t.updated_at)}}function Rv(t){if(!m(t))return null;const e=hd(t.detachment);return e?{detachment:e,assigned_unit_label:r(t.assigned_unit_label),operation:lo(t.operation)}:null}function yd(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),active:u(n.active),projected:u(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(Rv).filter(s=>s!==null):[]}}function Lv(t){if(!m(t))return null;const e=r(t.decision_id),n=r(t.trace_id),s=r(t.requested_action),a=r(t.scope_type),i=r(t.scope_id);return!e||!n||!s||!a||!i?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:i,operation_id:r(t.operation_id)??null,target_unit_id:r(t.target_unit_id)??null,requested_by:r(t.requested_by),status:r(t.status),reason:r(t.reason)??null,source:r(t.source),detail:t.detail,created_at:r(t.created_at),decided_at:r(t.decided_at)??null,expires_at:r(t.expires_at)??null}}function bd(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),pending:u(n.pending),approved:u(n.approved),denied:u(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(Lv).filter(s=>s!==null):[]}}function Mv(t){if(!m(t))return null;const e=rr(t.unit);return e?{unit:e,roster_total:u(t.roster_total),roster_live:u(t.roster_live),headcount_cap:u(t.headcount_cap),active_operations:u(t.active_operations),active_operation_cap:u(t.active_operation_cap),utilization:u(t.utilization)}:null}function Pv(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(Mv).filter(n=>n!==null):[]}}function zv(t){if(!m(t))return null;const e=r(t.alert_id);return e?{alert_id:e,severity:r(t.severity),kind:r(t.kind),scope_type:r(t.scope_type),scope_id:r(t.scope_id),title:r(t.title),detail:r(t.detail),timestamp:r(t.timestamp)}:null}function kd(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),bad:u(n.bad),warn:u(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(zv).filter(s=>s!==null):[]}}function xd(t){if(!m(t))return null;const e=r(t.event_id),n=r(t.trace_id),s=r(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:r(t.operation_id)??null,unit_id:r(t.unit_id)??null,actor:r(t.actor)??null,source:r(t.source),timestamp:r(t.timestamp),detail:t.detail}}function Ev(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),events:Array.isArray(e.events)?e.events.map(xd).filter(n=>n!==null):[]}}function jv(t){if(!m(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function wv(t){if(!m(t))return null;const e=r(t.lane_id),n=r(t.label),s=r(t.kind),a=r(t.phase),i=r(t.motion_state),l=r(t.source_of_truth),c=r(t.movement_reason),d=r(t.current_step);if(!e||!n||!s||!a||!i||!l||!c||!d)return null;const p=m(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:E(t.present)??!1,phase:a,motion_state:i,source_of_truth:l,last_movement_at:r(t.last_movement_at)??null,movement_reason:c,current_step:d,blockers:K(t.blockers),counts:{operations:u(p.operations),detachments:u(p.detachments),workers:u(p.workers),approvals:u(p.approvals),alerts:u(p.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(jv).filter(_=>_!==null):[]}}function Nv(t){if(!m(t))return null;const e=r(t.event_id),n=r(t.lane_id),s=r(t.kind),a=r(t.timestamp),i=r(t.title),l=r(t.detail),c=r(t.tone),d=r(t.source);return!e||!n||!s||!a||!i||!l||!c||!d?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:i,detail:l,tone:c,source:d}}function Dv(t){if(!m(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,why_it_matters:r(t.why_it_matters)??void 0,next_tool:r(t.next_tool)??void 0,next_step:r(t.next_step)??void 0,lane_ids:K(t.lane_ids),count:u(t.count)??0}}function lr(t){if(!m(t))return;const e=m(t.overview)?t.overview:{},n=m(t.gaps)?t.gaps:{},s=m(t.narrative)?t.narrative:{},a=m(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:r(t.generated_at),narrative:{state:r(s.state)??void 0,started:r(s.started)??void 0,active_work:r(s.active_work)??void 0,completion:r(s.completion)??void 0,lane_id:r(s.lane_id)??null},overview:{active_lanes:u(e.active_lanes),moving_lanes:u(e.moving_lanes),stalled_lanes:u(e.stalled_lanes),projected_lanes:u(e.projected_lanes),last_movement_at:r(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(wv).filter(i=>i!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(Nv).filter(i=>i!==null):[],gaps:{count:u(n.count),items:Array.isArray(n.items)?n.items.map(Dv).filter(i=>i!==null):[]},recommended_next_action:a?{tool:r(a.tool)??"masc_operator_snapshot",label:r(a.label)??"Observe operator state",reason:r(a.reason)??"",lane_id:r(a.lane_id)??null}:void 0}}function Sd(t){if(!m(t))return;const e=m(t.workers)?t.workers:{},n=E(t.pass);return{status:r(t.status)??"missing",source:r(t.source)??"none",reason_code:r(t.reason_code)??null,status_summary:r(t.status_summary)??null,run_id:r(t.run_id)??null,captured_at:r(t.captured_at)??null,...n!==void 0?{pass:n}:{},...u(t.peak_hot_slots)!=null?{peak_hot_slots:u(t.peak_hot_slots)}:{},...u(t.ctx_per_slot)!=null?{ctx_per_slot:u(t.ctx_per_slot)}:{},workers:{expected:u(e.expected),joined:u(e.joined),current_task_bound:u(e.current_task_bound),fresh_heartbeats:u(e.fresh_heartbeats),done:u(e.done),final:u(e.final)},expected_artifact_dir:r(t.expected_artifact_dir)??null,artifact_ref:r(t.artifact_ref)??null,missing_reason:r(t.missing_reason)??null}}function Ov(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),topology:gd(e.topology),operations:$d(e.operations),detachments:yd(e.detachments),alerts:kd(e.alerts),decisions:bd(e.decisions),capacity:Pv(e.capacity),traces:Ev(e.traces),swarm_status:lr(e.swarm_status)}}function qv(t){const e=m(t)?t:{},n=gd(e.topology),s=$d(e.operations),a=yd(e.detachments),i=kd(e.alerts),l=bd(e.decisions);return{version:r(e.version),generated_at:r(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:i.version,generated_at:i.generated_at,summary:i.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:lr(e.swarm_status),swarm_proof:Sd(e.swarm_proof)}}function Fv(t){return m(t)?{chain_id:r(t.chain_id)??null,started_at:u(t.started_at)??null,progress:u(t.progress)??null,elapsed_sec:u(t.elapsed_sec)??null}:null}function Cd(t){if(!m(t))return null;const e=r(t.event);return e?{event:e,chain_id:r(t.chain_id)??null,timestamp:r(t.timestamp)??null,duration_ms:u(t.duration_ms)??null,message:r(t.message)??null,tokens:u(t.tokens)??null}:null}function Kv(t){if(!m(t))return null;const e=lo(t.operation);return e?{operation:e,runtime:Fv(t.runtime),history:Cd(t.history),mermaid:r(t.mermaid)??null,preview_run:Ad(t.preview_run)}:null}function Bv(t){const e=m(t)?t:{};return{status:r(e.status)??"disconnected",base_url:r(e.base_url)??null,message:r(e.message)??null}}function Uv(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),connection:Bv(e.connection),summary:n?{linked_operations:u(n.linked_operations),active_chains:u(n.active_chains),running_operations:u(n.running_operations),recent_failures:u(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Kv).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(Cd).filter(s=>s!==null):[]}}function Hv(t){if(!m(t))return null;const e=r(t.id);return e?{id:e,type:r(t.type),status:r(t.status),duration_ms:u(t.duration_ms)??null,error:r(t.error)??null}:null}function Ad(t){if(!m(t))return null;const e=r(t.run_id),n=r(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:u(t.duration_ms),success:E(t.success),mermaid:r(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(Hv).filter(s=>s!==null):[]}:null}function Wv(t){const e=m(t)?t:{};return{run:Ad(e.run)}}function Gv(t){if(!m(t))return null;const e=r(t.title),n=r(t.path);return!e||!n?null:{title:e,path:n}}function Jv(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function Vv(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.tool),a=r(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:K(t.success_signals),pitfalls:K(t.pitfalls)}}function Yv(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary),a=r(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(Vv).filter(i=>i!==null):[]}}function Xv(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:K(t.tools)}}function Qv(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.symptom),a=r(t.why),i=r(t.fix_tool),l=r(t.fix_summary);return!e||!n||!s||!a||!i||!l?null:{id:e,title:n,symptom:s,why:a,fix_tool:i,fix_summary:l}}function Zv(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.path_id),a=r(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:K(t.notes)}}function tf(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Gv).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Jv).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Yv).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(Xv).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(Qv).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Zv).filter(n=>n!==null):[]}}function ef(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.status),a=r(t.detail),i=r(t.next_tool);return!e||!n||!s||!a||!i?null:{id:e,title:n,status:s,detail:a,next_tool:i}}function nf(t){if(!m(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.title),a=r(t.detail),i=r(t.next_tool);return!e||!n||!s||!a||!i?null:{code:e,severity:n,title:s,detail:a,next_tool:i}}function sf(t){if(!m(t))return null;const e=r(t.from),n=r(t.content),s=r(t.timestamp),a=u(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function af(t){if(!m(t))return null;const e=r(t.name),n=r(t.role),s=r(t.lane),a=r(t.status),i=r(t.claim_marker),l=r(t.done_marker),c=r(t.final_marker);if(!e||!n||!s||!a||!i||!l||!c)return null;const d=(()=>{if(!m(t.last_message))return null;const p=u(t.last_message.seq),_=r(t.last_message.content),v=r(t.last_message.timestamp);return p==null||!_||!v?null:{seq:p,content:_,timestamp:v}})();return{name:e,role:n,lane:s,joined:E(t.joined)??!1,live_presence:E(t.live_presence)??!1,completed:E(t.completed)??!1,status:a,current_task:r(t.current_task)??null,bound_task_id:r(t.bound_task_id)??null,bound_task_title:r(t.bound_task_title)??null,bound_task_status:r(t.bound_task_status)??null,current_task_matches_run:E(t.current_task_matches_run)??!1,squad_member:E(t.squad_member)??!1,detachment_member:E(t.detachment_member)??!1,last_seen:r(t.last_seen)??null,heartbeat_age_sec:u(t.heartbeat_age_sec)??null,heartbeat_fresh:E(t.heartbeat_fresh)??!1,claim_marker_seen:E(t.claim_marker_seen)??!1,done_marker_seen:E(t.done_marker_seen)??!1,final_marker_seen:E(t.final_marker_seen)??!1,claim_marker:i,done_marker:l,final_marker:c,last_message:d}}function of(t){if(!m(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!m(n))return null;const s=r(n.timestamp),a=u(n.active_slots);if(!s||a==null)return null;const i=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:i}}).filter(n=>n!==null):[];return{slot_url:r(t.slot_url)??null,provider_base_url:r(t.provider_base_url)??null,provider_reachable:E(t.provider_reachable)??null,provider_status_code:u(t.provider_status_code)??null,provider_model_id:r(t.provider_model_id)??null,actual_model_id:r(t.actual_model_id)??null,expected_slots:u(t.expected_slots),actual_slots:u(t.actual_slots),expected_ctx:u(t.expected_ctx),actual_ctx:u(t.actual_ctx),configured_capacity:u(t.configured_capacity),slot_reachable:E(t.slot_reachable)??null,slot_status_code:u(t.slot_status_code)??null,runtime_blocker:r(t.runtime_blocker)??null,detail:r(t.detail)??null,checked_at:r(t.checked_at)??null,total_slots:u(t.total_slots),ctx_per_slot:u(t.ctx_per_slot),active_slots_now:u(t.active_slots_now),peak_active_slots:u(t.peak_active_slots),sample_count:u(t.sample_count),last_sample_at:r(t.last_sample_at)??null,timeline:e}}function rf(t){if(!m(t))return null;const e=r(t.run_id),n=r(t.status),s=r(t.decided_by),a=r(t.decided_at),i=r(t.reason);if(!e||!n||!s||!a||!i)return null;const l=[];return Array.isArray(t.history)&&t.history.forEach(c=>{if(!m(c))return;const d=r(c.status),p=r(c.decided_by),_=r(c.decided_at),v=r(c.reason);!d||!p||!_||!v||l.push({status:d,decided_by:p,decided_at:_,reason:v,operation_id:r(c.operation_id)??null,detachment_id:r(c.detachment_id)??null,note:r(c.note)??null})}),{run_id:e,status:n,decided_by:s,decided_at:a,reason:i,operation_id:r(t.operation_id)??null,detachment_id:r(t.detachment_id)??null,note:r(t.note)??null,history:l}}function lf(t){if(!m(t))return null;const e=r(t.run_id),n=r(t.recommended_kind),s=r(t.reason);return!e||!n||!s?null:{run_id:e,recommended_kind:n,continue_available:E(t.continue_available)??!1,rerun_available:E(t.rerun_available)??!1,abandon_available:E(t.abandon_available)??!1,reason:s,evidence:m(t.evidence)?{operation_id:r(t.evidence.operation_id)??null,detachment_id:r(t.evidence.detachment_id)??null,joined_workers:u(t.evidence.joined_workers),current_task_bound:u(t.evidence.current_task_bound),fresh_heartbeats:u(t.evidence.fresh_heartbeats),trace_events:u(t.evidence.trace_events),message_events:u(t.evidence.message_events),runtime_blocker:r(t.evidence.runtime_blocker)??null}:void 0,provenance:r(t.provenance),decision_engine:r(t.decision_engine),authoritative:E(t.authoritative)}}function cf(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),run_id:r(e.run_id),room_id:r(e.room_id),operation_id:r(e.operation_id)??null,run_resolution:rf(e.run_resolution),resolution_recommendation:lf(e.resolution_recommendation),recommended_next_tool:r(e.recommended_next_tool),summary:n?{expected_workers:u(n.expected_workers),joined_workers:u(n.joined_workers),live_workers:u(n.live_workers),squad_roster_size:u(n.squad_roster_size),detachment_roster_size:u(n.detachment_roster_size),current_task_bound:u(n.current_task_bound),fresh_heartbeats:u(n.fresh_heartbeats),claim_markers_seen:u(n.claim_markers_seen),done_markers_seen:u(n.done_markers_seen),final_markers_seen:u(n.final_markers_seen),completed_workers:u(n.completed_workers),peak_hot_slots:u(n.peak_hot_slots),hot_window_ok:E(n.hot_window_ok),pass_hot_concurrency:E(n.pass_hot_concurrency),pass_end_to_end:E(n.pass_end_to_end),pending_decisions:u(n.pending_decisions),pass:E(n.pass)}:void 0,provider:of(e.provider),operation:lo(e.operation),squad:rr(e.squad),detachment:hd(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(af).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(ef).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(nf).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(sf).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(xd).filter(s=>s!==null):[],truth_notes:K(e.truth_notes)}}function df(t){if(!m(t))return null;const e=r(t.label),n=r(t.value);return!e||!n?null:{label:e,value:n}}function uf(t){if(!m(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.label),a=r(t.tone),i=r(t.provenance);return!e||!n||!s||!a||!i?null:{id:e,kind:n,label:s,subtitle:r(t.subtitle)??null,status:r(t.status)??null,tone:a,pulse:r(t.pulse)??null,provenance:i,visual_class:r(t.visual_class)??void 0,glyph:r(t.glyph)??void 0,parent_id:r(t.parent_id)??null,lane_id:r(t.lane_id)??null,link_tab:r(t.link_tab)??null,link_surface:r(t.link_surface)??null,link_params:m(t.link_params)?Object.fromEntries(Object.entries(t.link_params).map(([l,c])=>{const d=r(c);return d?[l,d]:null}).filter(l=>l!==null)):{},facts:Array.isArray(t.facts)?t.facts.map(df).filter(l=>l!==null):[]}}function pf(t){if(!m(t))return null;const e=r(t.id),n=r(t.source),s=r(t.target),a=r(t.kind),i=r(t.tone),l=r(t.provenance);return!e||!n||!s||!a||!i||!l?null:{id:e,source:n,target:s,kind:a,label:r(t.label)??null,tone:i,provenance:l,animated:E(t.animated)}}function mf(t){if(!m(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.label),a=r(t.tone),i=r(t.provenance);return!e||!n||!s||!a||!i?null:{id:e,kind:n,label:s,detail:r(t.detail)??null,tone:a,provenance:i,source_id:r(t.source_id)??null,target_id:r(t.target_id)??null,suggested_surface:r(t.suggested_surface)??null,suggested_params:m(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([l,c])=>{const d=r(c);return d?[l,d]:null}).filter(l=>l!==null)):{}}}function _f(t){if(!m(t))return null;const e=r(t.target_kind),n=r(t.target_id),s=r(t.label),a=r(t.reason);return!e||!n||!s||!a?null:{target_kind:e,target_id:n,label:s,reason:a,suggested_surface:r(t.suggested_surface)??null,suggested_params:m(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([i,l])=>{const c=r(l);return c?[i,c]:null}).filter(i=>i!==null)):{}}}function vf(t){const e=m(t)?t:{},n=m(e.room)?e.room:{},s=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),room:{room_id:r(n.room_id),project:r(n.project),cluster:r(n.cluster),paused:E(n.paused),pause_reason:r(n.pause_reason)??null,agent_count:u(n.agent_count),task_count:u(n.task_count),message_count:u(n.message_count)},summary:s?{session_count:u(s.session_count),operation_count:u(s.operation_count),detachment_count:u(s.detachment_count),lane_count:u(s.lane_count),worker_count:u(s.worker_count),keeper_count:u(s.keeper_count),signal_count:u(s.signal_count),alert_count:u(s.alert_count)}:void 0,nodes:Array.isArray(e.nodes)?e.nodes.map(uf).filter(a=>a!==null):[],edges:Array.isArray(e.edges)?e.edges.map(pf).filter(a=>a!==null):[],signals:Array.isArray(e.signals)?e.signals.map(mf).filter(a=>a!==null):[],focus:_f(e.focus),swarm_status:lr(e.swarm_status),swarm_proof:Sd(e.swarm_proof),truth_notes:K(e.truth_notes)}}function Bt(t){X.value=t,ir(t)&&ff()}async function Td(){Ra.value=!0,Ma.value=null;try{const t=await Ep();ar.value=qv(t)}catch(t){Ma.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{Ra.value=!1}}function cr(t){mn.value=t}async function dr(){La.value=!0,Pa.value=null;try{const t=await zp();Vt.value=Ov(t)}catch(t){Pa.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{La.value=!1}}async function ff(){Vt.value||La.value||await dr()}async function tn(){await Td(),ir(X.value)&&await dr()}async function Oe(){var t;Ci.value=!0,Da.value=null;try{const e=await jp(),n=Uv(e);Cs.value=n;const s=mn.value;n.operations.length===0?mn.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(mn.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Da.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{Ci.value=!1}}function gf(){jn=null,es.value=null,Oa.value=!1,ns.value=null}async function $f(t){jn=t,Oa.value=!0,ns.value=null;try{const e=await wp(t);if(jn!==t)return;es.value=Wv(e)}catch(e){if(jn!==t)return;es.value=null,ns.value=e instanceof Error?e.message:"Failed to load chain run"}finally{jn===t&&(Oa.value=!1)}}async function hf(){xi.value=!0,Ea.value=null;try{const t=await Np();Ss.value=tf(t)}catch(t){Ea.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{xi.value=!1}}async function te(t=_d(),e=vd()){ja.value=!0,wa.value=null;try{const n=await Dp(t,e);Ue.value=cf(n)}catch(n){wa.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{ja.value=!1}}async function je(t=_d(),e=vd()){Si.value=!0,Na.value=null;try{const n=await Op(t,e);or.value=vf(n)}catch(n){Na.value=n instanceof Error?n.message:"Failed to load orchestra map"}finally{Si.value=!1}}async function be(t,e,n){ki.value=t,za.value=null;try{await qp(e,n),await Td(),(Vt.value||ir(X.value))&&await dr(),await te(),await je(),await Oe()}catch(s){throw za.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{ki.value=null}}function yf(t){return be(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function bf(t){return be(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function kf(t){return be(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function xf(t={}){return be("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function Sf(t){return be(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function Cf(t){return be(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function Af(t,e){return be(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function Tf(t,e){return be(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}U_(()=>{tn(),Oe(),(X.value==="swarm"||X.value==="warroom"||X.value==="orchestra"||Ue.value!==null)&&te(),(X.value==="orchestra"||or.value!==null)&&je(),X.value==="warroom"&&mt()});function Ai(t){t==="command"&&(ze(),tn(),Oe(),(X.value==="swarm"||X.value==="warroom"||X.value==="orchestra")&&te(),X.value==="orchestra"&&je(),X.value==="warroom"&&mt()),t==="mission"&&(ze(),dd(),Ia()),t==="proof"&&pd(D.value.params.session_id,D.value.params.operation_id),t==="execution"&&(ze(),Pe()),t==="intervene"&&(ze(),mt(),Fe()),t==="memory"&&me(),t==="planning"&&er(),t==="lab"&&_e()}function If({metric:t}){return o`
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
  `}function Rf({panel:t}){return o`
    <div class="semantic-body">
      <div class="semantic-grid">
        <span>목적</span><span>${t.purpose}</span>
        <span>무엇을 푸나</span><span>${t.problem_solved}</span>
        <span>언제 보나</span><span>${t.when_active}</span>
        <span>에이전트 역할</span><span>${t.agent_role}</span>
        <span>생태계 기능</span><span>${t.ecosystem_function}</span>
      </div>
      ${t.related_tools.length>0?o`<div class="semantic-tag-row">
            ${t.related_tools.map(e=>o`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
      ${t.metrics.length>0?o`<div class="semantic-metric-list">
            ${t.metrics.map(e=>o`<${If} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function O({panelId:t,compact:e=!1,label:n="왜 필요한가"}){const s=M_(t);return s?o`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${Rf} panel=${s} />
    </details>
  `:ka.value?o`<span class="semantic-inline-state">의미 계층 불러오는 중…</span>`:null}function At({surfaceId:t,compact:e=!1}){const n=L_(t);return n?o`
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
      ${n.panels.length>0?o`<div class="semantic-tag-row">
            ${n.panels.map(s=>o`<span class="semantic-tag">${s.title}</span>`)}
          </div>`:null}
    </section>
  `:ka.value?o`<div class="semantic-surface-card ${e?"compact":""}">의미 계층 불러오는 중…</div>`:xa.value?o`<div class="semantic-surface-card ${e?"compact":""}">${xa.value}</div>`:null}function L({title:t,class:e,semanticId:n,testId:s,children:a}){return o`
    <div class="card ${e??""}" data-testid=${s}>
      ${t?o`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?o`<${O} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}const qa="masc_dashboard_workflow_context",Lf=900*1e3;function kt(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function ie(t){const e=kt(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function Id(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function Ti(t){return m(t)?t:null}function Mf(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function Pf(t){if(!t)return null;try{const e=JSON.parse(t);if(!m(e))return null;const n=kt(e.id),s=kt(e.source_surface),a=kt(e.source_label),i=kt(e.summary),l=kt(e.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!i||!l?null:{id:n,source_surface:s,source_label:a,action_type:kt(e.action_type),target_type:kt(e.target_type),target_id:kt(e.target_id),focus_kind:kt(e.focus_kind),operation_id:kt(e.operation_id),command_surface:kt(e.command_surface),summary:i,payload_preview:kt(e.payload_preview),suggested_payload:Ti(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:l}}catch{return null}}function ur(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=Lf}function zf(){const t=Id(),e=Pf((t==null?void 0:t.getItem(qa))??null);return e?ur(e)?e:(t==null||t.removeItem(qa),null):null}const Rd=g(zf());function Ld(t){const e=t&&ur(t)?t:null;Rd.value=e;const n=Id();if(!n)return;if(!e){n.removeItem(qa);return}const s=Mf(e);s&&n.setItem(qa,s)}function Ef(t){if(!t)return null;const e=Ti(t.suggested_payload);if(e)return e;if(m(t.preview)){const n=Ti(t.preview.payload);if(n)return n}return null}function jf(t){if(!t)return null;const e=ie(t.message);if(e)return e;const n=ie(t.task_title)??ie(t.title),s=ie(t.task_description)??ie(t.description),a=ie(t.reason),i=ie(t.priority)??ie(t.task_priority);return n&&s?`${n} · ${s}`:n&&i?`${n} · P${i}`:n||s||a||null}function pr(t,e,n,s,a,i,l,c){return[t,e,n??"action",s??"target",a??"room",i??"focus",l??"operation",c].join(":")}function Cn(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=Ef(t),i=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,l=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,c=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,d=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:pr("mission",n,(t==null?void 0:t.action_type)??null,i,l,c,null,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:i,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:d,payload_preview:jf(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function wf({targetType:t,targetId:e,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:i=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:pr("execution",s,null,t,e,n,i,c),source_surface:"execution",source_label:s,action_type:null,target_type:t,target_id:e,focus_kind:n,operation_id:i,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function Nf(t,e){return(e.source==="mission"||e.source==="execution")&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)&&(e.operation_id??null)===(t.operation_id??null)}function As(t){const{params:e}=t;if(e.source!=="mission"&&e.source!=="execution")return null;const n=Rd.value;if(n&&ur(n)&&Nf(n,e))return n;const s=new Date().toISOString(),a=e.source==="execution"?"execution":"mission";return{id:pr(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,e.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,operation_id:e.operation_id??null,command_surface:e.surface??null,summary:a==="execution"?e.focus_kind?`${e.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function Md(t){return{source:t.source_surface,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function Pd(t){if(t.command_surface)return t.command_surface;const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.focus_kind==="operation"||t.target_type==="operation"?"operations":t.target_type==="room"?"orchestra":"swarm"}function zd(t){return{source:t.source_surface,surface:Pd(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function Df(t){return Md(t)}function Of(t){return zd(t)}function mr(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function co(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(t==null?void 0:t.trim())||"추천 액션"}}function qf(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"orchestra":return"오케스트라";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}const ee=g(null),ce=g(null);function wt(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function ht(t){return t==="bad"||t==="offline"||t==="critical"||t==="risk"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"||t==="watch"?"warn":"ok"}function Ht(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function Ff(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"확인 필요":t<60?`${Math.round(t)}초`:t<3600?`${Math.round(t/60)}분`:t<86400?`${Math.round(t/3600)}시간`:`${Math.round(t/86400)}일`}function zt(t){switch((t??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"pending":return"대기 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":case"watch":return"주의";case"bad":case"critical":case"risk":return"위험";case"degraded":return"저하";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"loading":return"불러오는 중";case"error":return"오류";case"unavailable":return"사용 불가";case"stale":return"오래됨";case"refreshing":return"갱신 중";case"cached":return"캐시";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Fa(t){switch((t??"").trim().toLowerCase()){case"room":return"방";case"team_session":case"session":return"세션";case"operation":return"작전";case"keeper":return"키퍼";case"agent":return"에이전트";default:return(t==null?void 0:t.trim())||"대상"}}function Sl(t){switch((t??"").trim().toLowerCase()){case"metadata_gap":return"메타데이터 부족";case"mixed":return"신호 혼재";case"":return null;default:return(t==null?void 0:t.trim())||null}}function Kf(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function Bf(t){return mr(t?Cn(t,null,"상황판 추천 액션"):null)}function uo(t,e=Cn()){Ld(e),at(t,t==="intervene"?Df(e):Of(e))}function Ed(t){uo("intervene",Cn(null,t,"상황판 incident"))}function jd(t){uo("command",Cn(null,t,"상황판 incident"))}function _r(t,e,n="상황판 추천 액션"){uo("intervene",Cn(t,e,n))}function wd(t,e,n="상황판 추천 액션"){uo("command",Cn(t,e,n))}function Ii(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),at(t,n)}function Uf(t){return{kind:t.kind,severity:t.severity,summary:t.summary,target_type:t.target_type,target_id:t.target_id??null,actor:null,evidence:t.evidence_preview}}function Hf(t){var n,s;const e=ae.value.find(a=>a.name===t.name||a.agent_name===t.agent_name)??null;return{brief:t,keeper:e,currentWork:wt(t.current_work,110)??wt(e==null?void 0:e.skill_primary,110)??wt(e==null?void 0:e.last_proactive_reason,110)??"명시된 키퍼 초점 없음",recentInput:wt(e==null?void 0:e.recent_input_preview,120)??null,recentOutput:wt(e==null?void 0:e.recent_output_preview,120)??wt((n=e==null?void 0:e.diagnostic)==null?void 0:n.last_reply_preview,120)??wt(e==null?void 0:e.last_proactive_preview,120)??null,recentEvent:wt(e==null?void 0:e.last_proactive_reason,120)??wt((s=e==null?void 0:e.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(e==null?void 0:e.recent_tool_names)??[]}}function Wf(){const t=xs.value;if(!t)return new Map;const e=t.sessions.length>0?t.sessions:t.session_briefs;return new Map(e.map(n=>[n.session_id,n]))}function Gf(t){ee.value=ee.value===t?null:t,ce.value=null}function Nd(t){ce.value=ce.value===t?null:t,ee.value=null}function Jf(){ee.value=null,ce.value=null}function Co(t){return(t==null?void 0:t.trim().toLowerCase())??""}function Ts(t){var e,n;return t?((e=t.agent)==null?void 0:e.exists)===!1||Co((n=t.diagnostic)==null?void 0:n.health_state)==="offline"||Co(t.status)==="offline"||Co(t.status)==="inactive"?"offline":"online":"unlinked"}function wn(t){switch(t){case"offline":return"offline";case"none_recent":return"none_recent";case"not_applicable":return"not_applicable";case"unlinked":return"unlinked";default:return"not_collected"}}function Vf(t){const e=Ts(t);return e==="unlinked"?"unlinked":e==="offline"?"offline":"not_collected"}function Yf(t,e){const n=Ts(t);return n==="unlinked"?"unlinked":n==="offline"?"offline":e!=null&&e.trim()?"none_recent":"not_collected"}function Xf(t,e){const n=Ts(t);return n==="unlinked"?"unlinked":n==="offline"?"offline":e!=null&&e.trim()?"none_recent":"not_collected"}function Dd(t){const e=Ts(t);return e==="unlinked"?"unlinked":e==="offline"?"offline":"none_recent"}function Qf(t){const e=t==null?void 0:t.trim();at("tools",e?{q:e}:void 0)}function vr(t){return(t??"").trim().toLowerCase()}function Zf(t){switch(vr(t)){case"truth":case"recorded":return"ok";case"derived":case"fallback":case"narrative":case"judgment":return"warn";default:return""}}function tg(t){switch(vr(t)){case"truth":return"직접 수집한 source of truth";case"derived":return"truth를 바탕으로 계산한 read-model";case"fallback":return"직접 truth가 비어 있을 때 쓰는 대체 경로";case"recorded":return"이미 기록된 결정 또는 증거";case"narrative":return"LLM 해석 레이어";case"judgment":return"판단 레이어";default:return"근거 계층"}}function Ri(t){const e=(t.label??"").trim();return e||vr(t.kind)||"unknown"}function we({item:t}){const e=Ri(t),n=Zf(t.kind);return o`
    <span class="command-chip ${n}" title=${tg(t.kind)}>
      ${e}
    </span>
  `}function Je({items:t,className:e="mission-briefing-meta",testId:n}){const s=t.filter(a=>Ri(a).trim().length>0);return s.length===0?null:o`
    <div class=${e} data-testid=${n}>
      ${s.map((a,i)=>o`<${we} key=${`${Ri(a)}-${i}`} item=${a} />`)}
    </div>
  `}function eg(t){switch(t.trim().toLowerCase()){case"active":case"running":return"가동 중";case"working":return"작업 중";case"watching":return"관찰 중";case"quiet":return"조용함";case"idle":return"유휴";case"ok":case"healthy":return"정상";case"warn":case"warning":case"degraded":return"주의";case"bad":case"critical":case"error":case"failed":return"위험";case"blocked":return"막힘";case"paused":return"일시정지";case"pending":return"대기";case"offline":case"inactive":return"오프라인";case"connected":return"연결됨";case"disconnected":return"끊김";case"ready":return"준비됨";case"done":case"completed":return"완료";case"unknown":return"알 수 없음";default:return t}}function ke({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??eg(t)}
    </span>
  `}function Od(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}초 전`;const a=Math.floor(s/60);if(a<60)return`${a}분 전`;const i=Math.floor(a/60);return i<24?`${i}시간 전`:`${Math.floor(i/24)}일 전`}function Y({timestamp:t}){const e=Od(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}let ng=0;const Ne=g([]);function j(t,e="success",n=4e3){const s=++ng;Ne.value=[...Ne.value,{id:s,message:t,type:e}],setTimeout(()=>{Ne.value=Ne.value.filter(a=>a.id!==s)},n)}function sg(t){Ne.value=Ne.value.filter(e=>e.id!==t)}function ag(){const t=Ne.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>sg(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}function qd(t,e){const n=t==null?void 0:t.trim(),s=e==null?void 0:e.trim();return s?n&&s===n?null:s:null}function og(t,e){const n=qd(t,e);return n?`runtime · ${n}`:null}function ig(t,e){const n=t==null?void 0:t.trim(),s=qd(n,e);return n?s?`keeper key · ${n} · runtime agent · ${s}`:`keeper key · ${n}`:null}const rg="masc_dashboard_agent_name",An=g(null),Ka=g(!1),ss=g(""),Ba=g([]),as=g([]),_n=g(""),Bn=g(!1);function Is(t){An.value=t,fr()}function Cl(){An.value=null,ss.value="",Ba.value=[],as.value=[],_n.value=""}function lg(){const t=An.value;return t?Jt.value.find(e=>e.name===t)??null:null}function Fd(t){return t?ue.value.filter(e=>e.assignee===t):[]}function cg(t){return t?ae.value.find(e=>e.agent_name===t||e.name===t)??null:null}function dg(t){if(!t)return null;const e=xs.value;return e?e.agent_briefs.find(n=>n.agent_name===t)??null:null}function ug(t){return t?Xi.value.find(e=>e.agent_name===t||e.name===t)??null:null}async function fr(){const t=An.value;if(t){Ka.value=!0,ss.value="",Ba.value=[],as.value=[];try{const e=await ym(80);Ba.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Fd(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await bm(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const l=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));as.value=s}catch(e){ss.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Ka.value=!1}}}async function Al(){var s;const t=An.value,e=_n.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(rg))==null?void 0:s.trim())||"dashboard";Bn.value=!0;try{await hm(n,`@${t} ${e}`),_n.value="",j(`Mention sent to ${t}`,"success"),fr()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";j(i,"error")}finally{Bn.value=!1}}function pg({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${ke} status=${t.status} />
    </div>
  `}function mg({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Tl(t,e=160){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function _g(){const t=An.value;if(!t)return null;const e=lg(),n=cg(t),s=ug(t),a=dg(t),i=Fd(t),l=Ba.value,c=(a==null?void 0:a.display_name)??(n==null?void 0:n.name)??t,d=c!==t?t:null,p=(e==null?void 0:e.status)??(a==null?void 0:a.status)??"unknown",_=!e&&(a==null?void 0:a.is_live)===!1,v=(e==null?void 0:e.last_seen)??(a==null?void 0:a.last_activity_at)??null,f=(a==null?void 0:a.signal_truth)==="live"?"live":(a==null?void 0:a.signal_truth)==="stale"?"stale":(a==null?void 0:a.signal_truth)==="archived"?"archived":(a==null?void 0:a.signal_truth)==="unknown"?"unknown":null,h=(a==null?void 0:a.evidence_source)??null,T=(e==null?void 0:e.emoji)??(n==null?void 0:n.emoji),k=(e==null?void 0:e.koreanName)??(n==null?void 0:n.koreanName),C=Tl(s==null?void 0:s.continuity_summary)??Tl(s==null?void 0:s.skill_route_summary)??null,$=ig(n==null?void 0:n.name,n==null?void 0:n.agent_name);return o`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${y=>{y.target.classList.contains("agent-detail-overlay")&&Cl()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${T?o`<span style="font-size:2rem">${T}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${c}
                  ${k?o`<span style="font-size:0.75em;color:#888">(${k})</span>`:""}
                  ${d?o`<span class="mono" style="font-size:0.75em;color:#888">${d}</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  <${ke} status=${p} />
                  ${_?o`<span class="pill">archived session participant</span>`:null}
                  ${e!=null&&e.model?o`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                  ${!e&&(a!=null&&a.archived_reason)?o`<span style="font-size:0.75rem;color:#888">${a.archived_reason}</span>`:null}
                  ${f?o`<span class="pill">signal · ${f}</span>`:null}
                  ${h?o`<span class="pill">source · ${h}</span>`:null}
                </div>
              </div>
            </div>
            <div class="agent-detail-sub">
              ${e!=null&&e.current_task||a!=null&&a.current_work?o`<span>Task: ${(e==null?void 0:e.current_task)??(a==null?void 0:a.current_work)}</span>`:null}
              ${v?o`<span>Last seen: <${Y} timestamp=${v} /></span>`:null}
            </div>
            ${n||C||a!=null&&a.related_session_id?o`
                  <div class="agent-detail-sub">
                    ${n?o`<span>Linked keeper: ${n.name}${$?` · ${$}`:""}</span>`:null}
                    ${a!=null&&a.related_session_id?o`<span>Session: ${a.related_session_id}</span>`:null}
                    ${C?o`<span>${C}</span>`:null}
                  </div>
                `:null}
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{fr()}} disabled=${Ka.value}>
              ${Ka.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Cl}>Close</button>
          </div>
        </div>

        ${ss.value?o`<div class="council-error">${ss.value}</div>`:null}

        <div class="agent-detail-grid">
          <${L} title="Assigned Tasks">
            ${i.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${i.map(y=>o`<${pg} key=${y.id} task=${y} />`)}</div>`}
          <//>

          <${L} title="Recent Activity">
            ${l.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${l.map((y,x)=>o`<div key=${x} class="agent-activity-line">${y}</div>`)}</div>`}
          <//>
        </div>
        <${L} title="Task History">
          ${as.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${as.value.map(y=>o`<${mg} key=${y.taskId} row=${y} />`)}</div>`}
        <//>

        <${L} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${_n.value}
              onInput=${y=>{_n.value=y.target.value}}
              onKeyDown=${y=>{y.key==="Enter"&&Al()}}
              disabled=${Bn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Al()}}
              disabled=${Bn.value||_n.value.trim()===""}
            >
              ${Bn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function vg(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function fg(t){switch(t.delivery){case"sending":return"sending";case"streaming":return t.streamState==="finalizing"?"finalizing":"streaming";case"timeout":return"timeout";case"error":return"error";case"history":return t.role;default:return"delivered"}}function Ao(t){return t.delivery==="error"||t.delivery==="timeout"?"error":t.role==="user"?"user":t.role==="assistant"?"assistant":"system"}function Kd(t){return t.role==="user"?"You":t.label.trim()?t.label.trim():t.role}function gg(t){return Kd(t).slice(0,2).toUpperCase()}function $g(t){var n;const e=(n=t==null?void 0:t.usage)==null?void 0:n.totalTokens;return typeof e=="number"&&Number.isFinite(e)?`${e} tok`:null}function hg(t){return t?[t.modelUsed??null,typeof t.latencyMs=="number"?`${t.latencyMs} ms`:null,$g(t)].filter(e=>!!e):[]}function Il(t){return typeof t!="number"||!Number.isFinite(t)?null:t===0?"$0.00":t<.01?`$${t.toFixed(4)}`:`$${t.toFixed(2)}`}function yg(t){if(!t)return[];const e=["Goal","Progress","Next","Decisions","OpenQuestions","Constraints"];return t.split(`
`).map(n=>n.trim()).filter(Boolean).map(n=>{const s=e.find(a=>n.startsWith(`${a}:`));return s?{label:s,value:n.slice(s.length+1).trim()}:null}).filter(n=>!!(n&&n.value))}function bg(t){var e;return[t.modelUsed?{label:"Model",value:t.modelUsed}:null,typeof t.latencyMs=="number"?{label:"Latency",value:`${t.latencyMs} ms`}:null,typeof((e=t.usage)==null?void 0:e.totalTokens)=="number"?{label:"Tokens",value:`${t.usage.totalTokens}`}:null,Il(t.costUsd)?{label:"Cost",value:Il(t.costUsd)}:null,t.traceId?{label:"Trace",value:t.traceId}:null,typeof t.generation=="number"?{label:"Generation",value:`${t.generation}`}:null].filter(n=>!!n)}function kg({entry:t}){var p;const[e,n]=$n(!1),[s,a]=$n(!1),i=hg(t.details),l=!!t.details,c=t.details?bg(t.details):[],d=yg((p=t.details)==null?void 0:p.stateBlock);return o`
    <article class=${`chat-bubble ${Ao(t)}`}>
      <div class="chat-bubble-head">
        <div class="chat-bubble-identity">
          <div class=${`chat-avatar ${Ao(t)}`}>${gg(t)}</div>
          <div class="chat-bubble-identity-copy">
            <div class="chat-bubble-labels">
              <span class=${`chat-role-chip ${Ao(t)}`}>${t.label}</span>
              <span class="chat-delivery-chip">${fg(t)}</span>
              ${t.timestamp?o`<span class="chat-time-chip">${vg(t.timestamp)}</span>`:null}
            </div>
            <div class="chat-identity-title">${Kd(t)}</div>
          </div>
        </div>
        ${l?o`
              <button
                type="button"
                class="chat-disclosure-btn"
                onClick=${()=>{n(!e)}}
              >
                ${e?"Hide details":"Show details"}
              </button>
            `:null}
      </div>

      ${i.length>0?o`<div class="chat-detail-chip-row">
            ${i.map(_=>o`<span class="chat-detail-chip">${_}</span>`)}
          </div>`:null}

      <div class="chat-bubble-body">${t.text||(t.delivery==="streaming"?"…":"(empty reply)")}</div>
      ${t.error?o`<div class="chat-bubble-error">${t.error}</div>`:null}

      ${e&&t.details?o`
            <div class="chat-detail-panel">
              ${c.length>0?o`
                    <div class="chat-overview-grid">
                      ${c.map(_=>o`
                        <div class="chat-overview-card">
                          <div class="chat-overview-label">${_.label}</div>
                          <div class="chat-overview-value">${_.value}</div>
                        </div>
                      `)}
                    </div>
                  `:null}
              ${t.details.skillPrimary?o`
                    <div class="chat-detail-callout">
                      <div class="chat-detail-callout-label">Skill Route</div>
                      <div class="chat-detail-callout-value">${t.details.skillPrimary}</div>
                      ${t.details.skillReason?o`<div class="chat-detail-callout-copy">${t.details.skillReason}</div>`:null}
                    </div>
                  `:null}
              ${d.length>0?o`
                    <div class="chat-detail-section">
                      <div class="chat-detail-section-title">State Snapshot</div>
                      <div class="chat-state-grid">
                        ${d.map(_=>o`
                          <div class="chat-state-card">
                            <div class="chat-state-label">${_.label}</div>
                            <div class="chat-state-value">${_.value}</div>
                          </div>
                        `)}
                      </div>
                    </div>
                  `:null}
              ${t.details.rawPayload?o`
                    <div class="chat-detail-section">
                      <button
                        type="button"
                        class="chat-raw-toggle"
                        onClick=${()=>{a(!s)}}
                      >
                        ${s?"Hide raw payload":"Show raw payload"}
                      </button>
                      ${s?o`<pre>${JSON.stringify(t.details.rawPayload,null,2)}</pre>`:null}
                    </div>
                  `:null}
            </div>
          `:null}
    </article>
  `}function xg({entries:t,emptyText:e}){const n=Dn(null),s=t.map(a=>`${a.id}:${a.text.length}:${a.delivery}`).join("|");return nt(()=>{const a=n.current;a&&(a.scrollTop=a.scrollHeight)},[s]),o`
    <div class="chat-transcript" ref=${n}>
      ${t.length===0?o`<div class="chat-empty-copy">${e}</div>`:t.map(a=>o`<${kg} key=${a.id} entry=${a} />`)}
    </div>
  `}function Sg({draft:t,placeholder:e,disabled:n,streaming:s,onDraftChange:a,onSend:i,onAbort:l}){return o`
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
          onClick=${i}
          disabled=${n||s||t.trim()===""}
        >
          ${s?"Streaming…":"Send"}
        </button>
        ${s&&l?o`
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
  `}function Cg(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Ag(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Rl(t){switch(t){case"healthy":return"정상";case"recovering":return"복구 중";case"desired_offline":return"의도적 오프라인";case"offline":return"오프라인";default:return null}}function Tg(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Ig(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Bd(t){if(!t)return null;const e=se.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function Rg({keeper:t,showRawStatus:e=!1}){if(nt(()=>{t!=null&&t.name&&Ec(t.name)},[t==null?void 0:t.name]),!t)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=se.value[t.name],s=Bd(t),a=di.value[t.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        ${Rl(s==null?void 0:s.continuity_state)?o`<span class="pill">${Rl(s==null?void 0:s.continuity_state)}</span>`:null}
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Cg(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Ag((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.continuity_summary)??(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?o` · ${Tg(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?o` · next eligible ${Ig(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?o`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Ud({keeperName:t,placeholder:e}){const[n,s]=$n("");nt(()=>{t&&Ec(t)},[t]);const a=$t.value[t]??[],i=ha.value[t]??!1,l=Ut.value[t],c=async()=>{const d=n.trim();if(!(!t||!d)){s("");try{await Um(t,d)}catch(p){if(p instanceof Error&&p.name==="AbortError")return;const _=p instanceof Error?p.message:`Failed to message ${t}`;j(_,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <${xg}
        entries=${a}
        emptyText="No direct keeper conversation yet."
      />
      <${Sg}
        draft=${n}
        placeholder=${e}
        disabled=${!t}
        streaming=${i}
        onDraftChange=${s}
        onSend=${()=>{c()}}
        onAbort=${()=>{zc(t)}}
      />
      ${l?o`<div class="control-status-copy control-error-copy">${l}</div>`:null}
    </div>
  `}function Lg({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=Bd(e),a=ui.value[e.name]??!1,i=pi.value[e.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{Hm(e.name,t).catch(d=>{const p=d instanceof Error?d.message:`Failed to probe ${e.name}`;j(p,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{Wm(e.name,t).catch(d=>{const p=d instanceof Error?d.message:`Failed to recover ${e.name}`;j(p,"error")})}}
        disabled=${i||!c||!t.trim()}
      >
        ${i?"Recovering...":"Recover"}
      </button>
      <button
        class=${`control-btn ghost ${l==="manual_lodge_poke"?"is-active":""}`}
        onClick=${n}
      >
        Poke Lodge
      </button>
    </div>
  `}const gr=g(null);function Hd(t){gr.value=t,Bm(t.name)}function Ll(){gr.value=null}const Ve=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Mg(t){if(!t)return 0;const e=Ve.findIndex(n=>n.level===t);return e>=0?e:0}function Pg({keeper:t}){const e=Mg(t.autonomy_level),n=Ve[e]??Ve[0];if(!n)return null;const s=(e+1)/Ve.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${Ve.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Ve.map((a,i)=>o`
            <span style="width:8px; height:8px; border-radius:50%; background:${i<=e?a.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?o`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${Y} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function ca(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function zg(t){switch(t){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(t==null?void 0:t.trim())||"action"}}function Eg(t){return t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]}function jg(t){const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function wg(t){const e=xs.value;return e?e.keeper_briefs.find(n=>n.name===t.name||n.agent_name&&t.agent_name&&n.agent_name===t.agent_name)??null:null}function Ng({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=n&&Number.isFinite(n.cost_usd)?`$${n.cost_usd.toFixed(4)}`:null,a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${ca(t.context_tokens)}</div>
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
      ${s?o`
            <div class="kpi-tile">
              <div class="kpi-value">${s}</div>
              <div class="kpi-label">Cost (USD)</div>
            </div>
          `:null}
    </div>
  `}function Dg({keeper:t}){var _,v;const e=t.metrics_series??[];if(e.length<2){const f=(((_=t.context)==null?void 0:_.context_ratio)??0)*100,h=f>85?"#ef4444":f>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${f.toFixed(1)}%;background:${h}"></div>
        </div>
        <span class="chart-pct">${f.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,l=e.map((f,h)=>{const T=a+h/(i-1)*(n-2*a),k=s-a-(f.context_ratio??0)*(s-2*a);return{x:T,y:k,p:f}}),c=l.map(({x:f,y:h})=>`${f.toFixed(1)},${h.toFixed(1)}`).join(" "),d=(((v=e[e.length-1])==null?void 0:v.context_ratio)??0)*100,p=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:f})=>f.is_handoff).map(({x:f})=>o`
          <line x1="${f.toFixed(1)}" y1="${a}" x2="${f.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${p}" stroke-width="1.5"/>
        ${l.filter(({p:f})=>f.is_compaction).map(({x:f,y:h})=>o`
          <circle cx="${f.toFixed(1)}" cy="${h.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const To=g("");function Og({keeper:t}){var a,i,l,c;const e=To.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${To.value}
        onInput=${d=>{To.value=d.target.value}}
      />
      ${s.map(d=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${d.title}</span>
          <span class="keeper-field-key">${d.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${d.value}</span>
        </div>
      `)}
      ${t.trace_id?o`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${t.trace_id}</span></div>`:""}
      ${t.agent_name?o`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${t.agent_name}</span></div>`:""}
      ${t.primary_model?o`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.primary_model}</span></div>`:""}
      ${t.active_model?o`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.active_model}</span></div>`:""}
      ${t.next_model_hint?o`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.next_model_hint}</span></div>`:""}
      ${t.skill_primary?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_primary}</span></div>`:""}
      ${t.skill_secondary?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_secondary}</span></div>`:""}
      ${t.skill_reason?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_reason}</span></div>`:""}
      ${t.context_source?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${t.context_source}</span></div>`:""}
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${ca(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${ca(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${ca(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function qg({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(s=>o`
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
  `}function Fg({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Kg({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Ml({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Io(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Bg({keeper:t}){const e=t.metrics_window,s=[{label:"Model fallback",value:Io(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Io(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Io(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}].filter(a=>!(a.value==="-"||a.value==="—"||a.value===""));return s.length===0?null:o`
    <div class="keeper-signal-list">
      ${s.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function Ug({keeper:t}){var B,et,Z,tt,G,R,S;const e=((B=Tt.value)==null?void 0:B.room)??{},n=(((et=Tt.value)==null?void 0:et.available_actions)??[]).filter(P=>P.target_type==="keeper"||P.target_type==="room").slice(0,8),s=Eg(t),a=jg(t),i=wg(t),l=i!=null&&i.allowed_tool_names&&i.allowed_tool_names.length>0?i.allowed_tool_names:t.allowed_tool_names??[],c=i!=null&&i.latest_tool_names&&i.latest_tool_names.length>0?i.latest_tool_names:t.latest_tool_names??[],d=(i==null?void 0:i.latest_tool_call_count)??t.latest_tool_call_count,p=(i==null?void 0:i.tool_audit_source)??t.tool_audit_source,_=(i==null?void 0:i.tool_audit_at)??t.tool_audit_at,v=((Z=t.agent)==null?void 0:Z.capabilities)??[],f=e.current_room??e.room_id??((tt=ut.value)==null?void 0:tt.room)??"default",h=e.project??((G=ut.value)==null?void 0:G.project)??"확인 없음",T=e.cluster??((R=ut.value)==null?void 0:R.cluster)??"확인 없음",k=wn(Vf(t)),C=wn(Yf(t,p)),$=wn(Xf(t,p)),y=wn(Dd(t)),x=Ts(t),M=((S=t.agent)==null?void 0:S.current_task)??(x==="offline"?"offline":"not_collected"),I=t.skill_primary??(x==="offline"?"offline":"not_collected"),F=l[0]??c[0]??s[0]??null;return o`
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
        <strong>${T}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Current task</span>
        <strong>${M}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Skill route</span>
        <strong>${I}</strong>
      </div>
      <div style="display:flex; justify-content:flex-end; margin-top:4px;">
        <button class="control-btn ghost" onClick=${()=>{Qf(F)}}>
          Open tools panel
        </button>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Allowed tools</span>
        <span style="font-size:11px; color:#64748b;">Currently permitted tools for this keeper runtime.</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${l.length>0?l.map(P=>o`<span class="pill">${P}</span>`):o`<span style="font-size:12px; color:#888;">${k}</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Observed tools</span>
        <span style="font-size:11px; color:#64748b;">Recent execution evidence from heartbeat or runtime telemetry.</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${c.length>0?c.map(P=>o`<span class="pill">${P}</span>`):o`<span style="font-size:12px; color:#888;">${C}</span>`}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Tool calls</span>
        <strong>${typeof d=="number"?d:C==="none_recent"?0:$}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Evidence source</span>
        <strong>${p??$}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Observed at</span>
        <strong>${_?o`<${Y} timestamp=${_} />`:$}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Keeper recent tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${s.length>0?s.map(P=>o`<span class="pill">${P}</span>`):o`<span style="font-size:12px; color:#888;">${y}</span>`}
        </div>
      </div>
      ${a.length>0?o`
            <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
              <span style="font-size:12px; color:#888;">Window top tools</span>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${a.map(P=>o`<span class="pill">${P}</span>`)}
              </div>
            </div>
          `:null}
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${v.length>0?v.map(P=>o`<span class="pill">${P}</span>`):o`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(P=>o`<span class="pill">${zg(P.action_type)}</span>`):o`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function Wd(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Hg(){try{const t=await bs({actor:Wd(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Mc(t.result);await ks(),e!=null&&e.skipped_reason?j(e.skipped_reason,"warning"):j(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";j(e,"error")}}function Wg({keeper:t}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Rg} keeper=${t} />
          <${Lg}
            actor=${Wd()}
            keeper=${t}
            onPokeLodge=${()=>{Hg()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Ud}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function Gg(){var e,n,s;const t=gr.value;return t?o`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Ll()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?o`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
            </div>
            <${ke} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Ll()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Ng} keeper=${t} />

        ${""}
        <${Dg} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${L} title="Field Dictionary">
            <${Og} keeper=${t} />
          <//>

          ${""}
          <${L} title="Profile">
            <${Ml} traits=${t.traits??[]} label="Traits" />
            <${Ml} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${Y} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${L} title="Autonomy">
                <${Pg} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${L} title="TRPG Stats">
                <${qg} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${L} title="Equipment (${t.inventory.length})">
                <${Fg} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${L} title="Relationships (${Object.keys(t.relationships).length})">
                <${Kg} rels=${t.relationships} />
              <//>
            `:null}

          <${L} title="Runtime Signals">
            <${Bg} keeper=${t} />
          <//>

          <${L} title="Neighborhood & Tool Audit">
            <${Ug} keeper=${t} />
          <//>

          <${L} title="Memory & Context">
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
              ${t.memory_recent_note?o`
                  <div class="keeper-memory-note">
                    ${t.memory_recent_note}
                  </div>
                `:o`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${Wg} keeper=${t} />
      </div>
    </div>
  `:null}function Jg({cluster:t,project:e,room:n,generatedAt:s}){return o`
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
        <strong>${s?Ht(s):"기록 없음"}</strong>
      </div>
      ${t&&t!=="unknown"?o`
            <div class="mission-context-item">
              <span>배포 메타</span>
              <strong>${t}</strong>
            </div>
          `:null}
    </div>
  `}function We({label:t,value:e,detail:n,tone:s}){return o`
    <article class="mission-stat-card ${ht(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function Vg(){const t=ad.value,e=ht((t==null?void 0:t.status)??(Le.value?"bad":"warn")),n=!t||t.sections.length===0,s=(t==null?void 0:t.status)==="error"||(t==null?void 0:t.status)==="unavailable"&&!(t!=null&&t.cached);return o`
    <${L} title="판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>왜 그렇게 보이나</h3>
        <p>사회 truth를 읽은 뒤에만 별도 판단 결과를 참고하고, 근거는 접어서 둡니다.</p>
        <${Je}
          items=${[{kind:"narrative"},{kind:"fallback",label:"fallback on failure"}]}
        />
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${e}">
          ${zt((t==null?void 0:t.status)??(Le.value?"error":"loading"))}
        </span>
        ${t!=null&&t.model?o`<span class="command-chip">${t.model}</span>`:null}
        ${t!=null&&t.generated_at?o`<span class="command-chip">${Ht(t.generated_at)}</span>`:null}
        ${t!=null&&t.cached?o`<span class="command-chip">캐시</span>`:null}
        ${t!=null&&t.stale?o`<span class="command-chip warn">오래됨</span>`:null}
        ${t!=null&&t.refreshing?o`<span class="command-chip warn">갱신 중</span>`:null}
      </div>

      ${Le.value?o`<div class="empty-state error">${Le.value}</div>`:null}
      ${t!=null&&t.error?o`<div class="empty-state error">${t.error}</div>`:null}
      ${t!=null&&t.summary?o`<div class="mission-inline-note">${t.summary}</div>`:null}
      ${t!=null&&t.last_error&&!t.error?o`<div class="mission-inline-note">최근 갱신 실패: ${t.last_error}</div>`:null}

      ${t&&t.sections.length>0?o`
            <div class="mission-briefing-grid">
              ${t.sections.slice(0,3).map(a=>o`
                <article class="mission-briefing-section ${ht(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${ht(a.status)}">${zt(a.status)}</span>
                      ${Sl(a.signal_class)?o`<span class="command-chip ${a.signal_class==="mixed"?"warn":""}">${Sl(a.signal_class)}</span>`:null}
                      ${a.evidence_quality?o`<span class="command-chip">${a.evidence_quality}</span>`:null}
                    </div>
                  </div>
                  <p>${a.summary}</p>
                  ${a.evidence.length>0?o`
                        <details class="mission-card-disclosure compact">
                          <summary>근거 보기</summary>
                          <div class="mission-pill-row">
                            ${a.evidence.map(i=>o`<span class="mission-pill">${i}</span>`)}
                          </div>
                        </details>
                      `:null}
                </article>
              `)}
            </div>
          `:!Qe.value&&!Le.value&&n?o`
                <div class="empty-state">
                  ${(t==null?void 0:t.status)==="pending"?"최신 스냅샷으로 브리핑을 생성 중입니다. 마지막 성공 결과가 생기면 자동으로 다시 읽습니다.":"판단 결과가 아직 없습니다."}
                </div>
              `:null}

      ${t&&t.metadata_gaps.length>0?o`
            <details class="mission-card-disclosure compact mission-briefing-gaps">
              <summary>관측 공백 (${t.metadata_gap_count??t.metadata_gaps.length})</summary>
              <div class="mission-list-stack">
                ${t.metadata_gaps.map(a=>o`
                  <article class="mission-briefing-gap ${a.severity==="watch"?"warn":""}">
                    <div class="mission-card-head">
                      <strong>${Fa(a.scope_type)}${a.scope_id?` · ${a.scope_id}`:""}</strong>
                      <span class="command-chip ${a.severity==="watch"?"warn":""}">${zt(a.severity)}</span>
                    </div>
                    <p>${a.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{Ia(s)}} disabled=${Qe.value}>
          ${Qe.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{Ia(!0)}} disabled=${Qe.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function Yg({item:t,selected:e,sessionLookup:n}){const s=Uf(t),a=t.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),i=t.top_action??null;return o`
    <article class="mission-attention-card ${ht((i==null?void 0:i.severity)??t.severity)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Gf(t.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.summary}</strong>
            <div class="mission-card-target">${Fa(t.target_type)}${t.target_id?` · ${t.target_id}`:""}</div>
          </div>
          <span class="command-chip ${ht((i==null?void 0:i.severity)??t.severity)}">${i?Kf(i):t.severity}</span>
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
            <strong>${t.last_seen_at?Ht(t.last_seen_at):"기록 없음"}</strong>
            <small>${Fa(t.target_type)}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${i?co(i.action_type):"판단 필요"}</strong>
            <small>${i?Bf(i):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${i?o`<div class="mission-inline-note">${i.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?o`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>o`
                  <button class="mission-link-row" onClick=${()=>Nd(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${zt(l.status)} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:o`<div class="empty-state">직접 연결된 세션이 아직 없습니다.</div>`}

        ${t.related_agent_names.length>0?o`
              <div class="mission-pill-row">
                ${t.related_agent_names.slice(0,8).map(l=>o`
                  <button class="mission-pill action" onClick=${()=>Is(l)}>${l}</button>
                `)}
              </div>
            `:null}

        ${t.evidence_preview.length>0?o`
              <details class="mission-card-disclosure compact">
                <summary>근거 미리보기</summary>
                <div class="mission-evidence-list">
                  ${t.evidence_preview.map(l=>o`<span>${l}</span>`)}
                </div>
              </details>
            `:null}
      </details>

      <div class="mission-card-actions">
        ${i?o`
              <button class="control-btn ghost" onClick=${()=>_r(i,s,"상황판 주의 신호")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>wd(i,s,"상황판 주의 신호")}>
                원인 보기
              </button>
            `:o`
              <button class="control-btn ghost" onClick=${()=>Ed(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>jd(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function Xg({brief:t,selected:e}){var d,p;const n=t.member_previews.slice(0,4),s=t.top_recommendation??null,a=t.top_attention??null,i=t.active_count??0,l=t.seen_count??i,c=t.planned_count??t.member_names.length;return o`
    <article class="mission-crew-card ${ht(((d=t.top_attention)==null?void 0:d.severity)??t.health??t.status)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Nd(t.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.goal}</strong>
            <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          </div>
          <span class="command-chip ${ht(((p=t.top_attention)==null?void 0:p.severity)??t.health??t.status)}">${zt(t.status)}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${t.member_names.length}</strong>
            <small>${t.member_names.slice(0,3).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${Ff(t.elapsed_sec)}</strong>
            <small>${t.started_at?`${Ht(t.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 흐름</span>
            <strong>${t.last_event_at?Ht(t.last_event_at):"기록 없음"}</strong>
            <small>${t.communication_summary??"요약 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>충원 상태</span>
            <strong>${i}/${t.required_count||1}</strong>
            <small>live · seen ${l} · planned ${c}</small>
          </div>
        </div>
      </button>

      ${t.blocker_summary?o`<div class="mission-inline-note">막힘 · ${t.blocker_summary}</div>`:null}
      ${t.counts_basis?o`<div class="mission-inline-note">관측 기준 · ${t.counts_basis}</div>`:null}

      <div class="mission-crew-event">
        <span>최근 사건</span>
        <strong>${t.last_event_summary??"최근 세션 이벤트가 없습니다."}</strong>
        <small>${t.last_event_at?Ht(t.last_event_at):"시각 없음"}</small>
      </div>

      ${t.operation_badges.length>0?o`
            <div class="mission-pill-row">
              ${t.operation_badges.slice(0,3).map(_=>o`
                <span class="mission-pill">
                  ${_.operation_id} · ${zt(_.status)}${_.stage?` · ${_.stage}`:""}
                </span>
              `)}
            </div>
          `:null}

      ${n.length>0?o`
            <div class="mission-member-preview-grid">
              ${n.map(_=>o`
                <button class="mission-member-preview" onClick=${()=>Is(_.agent_name)}>
                  <strong>${_.agent_name}</strong>
                  <span>
                    ${_.current_work??"현재 작업 없음"}
                    ${_.is_live===!1?" · archived":_.is_live===!0?" · live":""}
                  </span>
                  <small>${_.recent_output_preview??_.recent_input_preview??"최근 입출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Ii("intervene",t.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Ii("command",t.session_id)}>세션 원인 보기</button>
        ${s?o`<button class="control-btn ghost" onClick=${()=>_r(s,a,"상황판 세션 요약")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function Qg({detail:t,loading:e,error:n}){if(e&&!t)return o`
      <${L} title="세션 상세" class="mission-list-card">
        <div class="loading-indicator">세션 상세 불러오는 중...</div>
      <//>
    `;if(n&&!t)return o`
      <${L} title="세션 상세" class="mission-list-card">
        <div class="empty-state error">${n}</div>
      <//>
    `;if(!(t!=null&&t.session))return null;const s=t.session;return o`
    <${L} title="세션 상세" class="mission-list-card" semanticId="mission.session_detail">
      <div class="mission-section-head">
        <h3>${s.goal}</h3>
        <p>${s.session_id}${s.room?` · ${s.room}`:""}</p>
      </div>

      ${n?o`<div class="mission-inline-note">${n}</div>`:null}

      <div class="mission-detail-grid">
        <div class="mission-detail-column">
          <div class="mission-card-head">
            <strong>타임라인</strong>
            <span class="command-chip">${t.timeline.length}</span>
          </div>
          <div class="mission-timeline-list">
            ${t.timeline.length>0?t.timeline.map(a=>o`
                  <article class="mission-timeline-row">
                    <div class="mission-card-head">
                      <strong>${a.summary}</strong>
                      <span>${a.timestamp?Ht(a.timestamp):"시각 없음"}</span>
                    </div>
                    <small>${a.actor?`${a.actor} · `:""}${a.event_type??"이벤트"}</small>
                  </article>
                `):o`<div class="empty-state">표시할 세션 이벤트가 없습니다.</div>`}
          </div>
        </div>

        <div class="mission-detail-column">
          <div class="mission-card-head">
            <strong>참여자</strong>
            <span class="command-chip">${t.participants.length}</span>
          </div>
          <div class="mission-activity-list compact">
            ${t.participants.length>0?t.participants.map(a=>o`
                  <button class="mission-member-preview" onClick=${()=>Is(a.agent_name)}>
                    <strong>${a.agent_name}</strong>
                    <span>${a.current_work??"현재 작업 없음"}</span>
                    <small>
                      ${a.recent_output_preview??a.recent_input_preview??"최근 입출력 없음"}
                      ${a.last_activity_at?` · ${Ht(a.last_activity_at)}`:""}
                    </small>
                  </button>
                `):o`<div class="empty-state">세션 참여자 미리보기가 없습니다.</div>`}
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
            ${t.operations.length>0?t.operations.map(a=>o`
                  <button class="mission-link-row" onClick=${()=>Ii("command",s.session_id)}>
                    <strong>${a.operation_id}</strong>
                    <span>${zt(a.status)}${a.stage?` · ${a.stage}`:""}</span>
                    <small>${a.detachment_status??a.objective??"분견대 정보 없음"}</small>
                  </button>
                `):o`<div class="empty-state">연결된 작전이 없습니다.</div>`}
          </div>
        </div>

        <div class="mission-detail-column">
          <div class="mission-card-head">
            <strong>연속성 관찰</strong>
            <span class="command-chip">${t.keepers.length}</span>
          </div>
          <div class="mission-link-list">
            ${t.keepers.length>0?t.keepers.map(a=>o`
                  <div class="mission-link-row static">
                    <strong>${a.name}</strong>
                    <span>${zt(a.status)}${a.generation!=null?` · 세대 ${a.generation}`:""}</span>
                    <small>${a.current_work??"현재 작업 정보 없음"}</small>
                  </div>
                `):o`<div class="empty-state">직접 연결된 키퍼는 없습니다.</div>`}
          </div>
        </div>
      </div>
    <//>
  `}function Zg({row:t}){var s,a,i,l,c,d,p,_,v,f;const e=[`세대 ${t.brief.generation??((s=t.keeper)==null?void 0:s.generation)??0}`,t.brief.context_ratio!=null?`컨텍스트 ${Math.round(t.brief.context_ratio*100)}%`:((a=t.keeper)==null?void 0:a.context_ratio)!=null?`컨텍스트 ${Math.round(t.keeper.context_ratio*100)}%`:null,t.brief.last_turn_ago_s!=null?`최근 턴 ${Math.round(t.brief.last_turn_ago_s)}초 전`:null].filter(h=>h!==null).join(" · "),n=t.recentTools.length>0?t.recentTools.join(", "):wn(Dd(t.keeper));return o`
    <article class="mission-activity-card ${ht(t.brief.status??((i=t.keeper)==null?void 0:i.status))}">
      <button class="mission-card-select" onClick=${()=>{t.keeper&&Hd(t.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((l=t.keeper)==null?void 0:l.emoji)??""}</span>
            <div>
              <strong>${t.brief.name}</strong>
              ${(c=t.keeper)!=null&&c.koreanName?o`<span>${t.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${ht(t.brief.status??((d=t.keeper)==null?void 0:d.status))}">${zt(t.brief.status??((p=t.keeper)==null?void 0:p.status))}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 하트비트 · ${(_=t.keeper)!=null&&_.last_heartbeat?Ht(t.keeper.last_heartbeat):"기록 없음"}</span>
          <span>${e||"연속성 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${t.currentWork}</strong>
          ${(v=t.keeper)!=null&&v.skill_reason?o`<small>판단 요약 · ${wt(t.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>연속성 상세</summary>
        <div class="mission-activity-foot">
          <span>에이전트 · ${t.brief.agent_name??((f=t.keeper)==null?void 0:f.agent_name)??"기록 없음"}</span>
          ${t.recentEvent?o`<span>최근 일 · ${t.recentEvent}</span>`:null}
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
  `}function t$({item:t}){const e=t.action??null,n=t.attention??null;return o`
    <article class="mission-action-card ${ht(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${ht(t.severity)}">
          ${t.signal_type==="action"&&e?co(e.action_type):(n==null?void 0:n.kind)??"내부 신호"}
        </span>
        <span class="mission-card-target">${Fa(t.target_type)}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      ${e?o`<div class="mission-action-preview">${e.reason}</div>`:null}
      <div class="mission-card-actions">
        ${e?o`
              <button class="control-btn ghost" onClick=${()=>_r(e,n,"상황판 내부 신호")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>wd(e,n,"상황판 내부 신호")}>이 이슈의 원인 보기</button>
            `:n?o`
                <button class="control-btn ghost" onClick=${()=>Ed(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>jd(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function Pl(){var C,$,y;const t=xs.value;if(hi.value&&!t)return o`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(Ta.value&&!t)return o`<div class="empty-state error">${Ta.value}</div>`;if(!t)return o`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;ee.value&&!t.attention_queue.some(x=>x.id===ee.value)&&(ee.value=null);const e=t.sessions;ce.value&&!e.some(x=>x.session_id===ce.value)&&(ce.value=null);const n=t.attention_queue.find(x=>x.id===ee.value)??null,s=(n==null?void 0:n.related_session_ids.find(x=>e.some(M=>M.session_id===x)))??null,a=ce.value??s??((C=e[0])==null?void 0:C.session_id)??null,i=Wf(),l=e.find(x=>x.session_id===a)??null,c=t.keeper_briefs.slice(0,6).map(Hf),d=t.attention_queue.filter(x=>x.related_session_ids.length>0).slice(0,6),p=t.internal_signals.slice(0,3),_=e.filter(x=>{var I;const M=((I=x.top_attention)==null?void 0:I.severity)??x.health??x.status;return ht(M)!=="ok"||!!x.blocker_summary}).length,v=e.filter(x=>x.last_event_summary||x.last_event_at).length,f=new Set(e.flatMap(x=>x.member_names)).size,h=e.flatMap(x=>x.member_previews??[]).filter(x=>x.recent_output_preview).length+c.filter(x=>x.recentOutput).length,T=((l==null?void 0:l.member_previews)??[]).filter(x=>x.recent_output_preview),k=c.filter(x=>x.recentOutput).slice(0,4);return nt(()=>{kv(a)},[a]),o`
    <section class="dashboard-panel mission-view">
      <${At} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 어떤 세션이 돌고 있고, 누가 참여하며, 어디가 막혔는지를 한 시점에서 읽는 기본 관찰면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${ht(t.summary.room_health)}">${zt(t.summary.room_health)}</span>
          <span class="command-chip">${t.summary.project??"프로젝트 미지정"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?Ht(t.generated_at):"기록 없음"}</span>
        </div>
      </div>

      <${Jg}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <div class="mission-stat-grid">
        <${We} label="활성 세션" value=${e.length} detail="지금 진행중인 협업 단위" tone=${(($=l==null?void 0:l.top_attention)==null?void 0:$.severity)??(l==null?void 0:l.health)??"ok"} />
        <${We} label="막힌 세션" value=${_} detail="주의가 필요한 흐름" tone=${_>0?"warn":"ok"} />
        <${We} label="최근 사건 세션" value=${v} detail="최근 사건이 관측된 세션" tone=${v>0?"ok":"warn"} />
        <${We} label="참여자" value=${f} detail="현재 세션에 연결된 주체" tone=${f>0?"ok":"warn"} />
        <${We} label="키퍼 관찰" value=${c.length} detail="연속성 확인 대상" tone=${((y=c[0])==null?void 0:y.brief.status)??"ok"} />
        <${We} label="최근 응답" value=${h} detail="메인에서 바로 읽을 수 있는 응답 수" tone=${h>0?"ok":"warn"} />
      </div>

      ${a?o`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${(l==null?void 0:l.goal)??a}${n?` · ${n.summary}`:""}</span>
              <button class="control-btn ghost" onClick=${Jf}>선택 해제</button>
            </div>
          `:null}

      <${L} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 작전을 먼저 읽고 사회의 현재 상태를 파악합니다.</p>
          <${Je} items=${[{kind:"truth"}]} />
        </div>
        <div class="mission-list-stack">
          ${e.length>0?e.map(x=>o`<${Xg} key=${x.session_id} brief=${x} selected=${a===x.session_id} />`):o`<div class="empty-state">지금 활성 세션이 없습니다.</div>`}
        </div>
      <//>

      <${Qg}
        detail=${yi.value}
        loading=${ra.value}
        error=${la.value}
      />

      <${L} title="키퍼 연속성" class="mission-list-card" semanticId="mission.keeper_activity">
        <div class="mission-section-head">
          <h3>세션 밖에서 움직이는 행위자</h3>
          <p>키퍼는 세션과 별개로 보고, 사회의 연속성과 장기 행위자 상태를 먼저 읽습니다.</p>
          <${Je} items=${[{kind:"truth"}]} />
        </div>
        <div class="mission-activity-list">
          ${c.length>0?c.map(x=>o`<${Zg} key=${x.brief.name} row=${x} />`):o`<div class="empty-state">지금 보이는 키퍼가 없습니다.</div>`}
        </div>
        <div class="mission-card-actions">
          <button class="control-btn ghost" onClick=${()=>at("execution")}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${()=>at("command")}>지휘 진단면 보기</button>
        </div>
      <//>

      <${L} title="최근 사회 활동" class="mission-list-card" semanticId="mission.session_activity">
        <div class="mission-section-head">
          <h3>누가 방금 무엇을 했나</h3>
          <p>선택된 세션과 연결된 행위자의 최근 출력만 모아 읽고, 해석은 뒤로 미룹니다.</p>
          <${Je} items=${[{kind:"truth"}]} />
        </div>
        <div class="mission-list-stack">
          ${T.length>0?T.slice(0,4).map(x=>o`
                <div class="mission-inline-note">
                  <strong>${x.agent_name??"unknown actor"}</strong>
                  ${x.role?o` · ${x.role}`:null}
                  ${x.status?o` · ${zt(x.status)}`:null}
                  <div>${x.recent_output_preview}</div>
                </div>
              `):o`<div class="empty-state">선택된 세션에서 바로 읽을 최근 출력이 없습니다.</div>`}
          ${k.length>0?k.map(x=>o`
                <div class="mission-inline-note">
                  <strong>${x.brief.name}</strong>
                  <div>${x.recentOutput}</div>
                </div>
              `):null}
        </div>
      <//>

      <${L} title="세션 우선순위" class="mission-list-card" semanticId="mission.attention_queue">
        <div class="mission-section-head">
          <h3>어느 세션을 먼저 봐야 하나</h3>
          <p>주의 신호는 truth를 훑은 다음에만 읽고, 세션 집중 순서를 정하는 용도로만 씁니다.</p>
          <${Je} items=${[{kind:"derived"}]} />
        </div>
        <div class="mission-lane-stack">
          ${d.length>0?d.map(x=>o`<${Yg} key=${x.id} item=${x} selected=${ee.value===x.id} sessionLookup=${i} />`):o`<div class="empty-state">지금 세션 단위 주의 대기열은 비어 있습니다.</div>`}
        </div>
      <//>

      <div class="mission-human-grid">
        <${Vg} />

        <${L} title="운영 보조 진단" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>시스템 진단</h3>
            <p>artifact scope drift 같은 내부 신호는 사회 흐름을 읽은 뒤에만 참고하도록 아래 보조 면으로 둡니다.</p>
            <${Je} items=${[{kind:"derived"}]} />
          </div>
          <details class="mission-card-disclosure">
            <summary>내부 신호 ${p.length}</summary>
            <div class="mission-list-stack">
              ${p.length>0?p.map(x=>o`<${t$} key=${x.id} item=${x} />`):o`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
            </div>
          </details>
        <//>
      </div>
    </section>
  `}const e$="modulepreload",n$=function(t){return"/dashboard/"+t},zl={},s$=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(p){return Promise.all(p.map(_=>Promise.resolve(_).then(v=>({status:"fulfilled",value:v}),v=>({status:"rejected",reason:v}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),d=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(p=>{if(p=n$(p),p in zl)return;zl[p]=!0;const _=p.endsWith(".css"),v=_?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${p}"]${v}`))return;const f=document.createElement("link");if(f.rel=_?"stylesheet":e$,_||(f.as="script"),f.crossOrigin="",f.href=p,d&&f.setAttribute("nonce",d),document.head.appendChild(f),_)return new Promise((h,T)=>{f.addEventListener("load",h),f.addEventListener("error",()=>T(new Error(`Unable to preload CSS for ${p}`)))})}))}function i(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&i(c.reason);return e().catch(i)})};function os(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Q(t){if(!t)return"정보 없음";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function a$(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Gd(t){if(!t)return"정보 없음";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"기한 지남":n<60?`${n}초 후`:n<3600?`${Math.round(n/60)}분 후`:n<86400?`${Math.round(n/3600)}시간 후`:`${Math.round(n/86400)}일 후`}function z(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let El=!1,o$=0;function i$(){return++o$}let Ro=null;async function r$(){Ro||(Ro=s$(()=>import("./mermaid.core-CMdn3k4B.js").then(e=>e.bE),[]).then(e=>e.default));const t=await Ro;return El||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),El=!0),t}function ve(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function Tn(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":`${Math.round(t*100)}%`}function en(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":t<60?`${Math.round(t)}초`:t<3600?`${Math.round(t/60)}분`:`${Math.round(t/3600)}시간`}function Rs(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function Te(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:Rs(t/e*100)}function l$(t,e){const n=Rs(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function po(t){if(!t)return"최근 체인 이력이 없습니다";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`토큰 ${t.tokens}`),t.message&&e.push(t.message),e.join(" · ")}const c$=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Jd=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"orchestra",label:"오케스트라",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],d$=Jd.map(t=>t.id),u$=["chain_start","node_start","node_complete","chain_complete","chain_error"],p$={warroom:{title:"실시간 워룸",description:"실제 실행, 워커, 메시지, 트레이스를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 작전, 분견대, 의존 관계를 먼저 읽는 기본 진입 표면입니다."},orchestra:{title:"룸 오케스트라 맵",description:"룸, 세션, 레인, 워커, 키퍼를 한 장의 작전판으로 읽는 시각화 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"레인 이동, 워커 결속, 막힘을 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 작전별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"실제 관리 유닛인지, 실시간 에이전트 기반 자동 투영인지 구분해서 봅니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"작전, 주체, 유닛 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"결정 승인과 유닛 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function jl(t){return!!t&&d$.includes(t)}function m$(){const t=D.value.params;return t.source!=="mission"&&t.source!=="execution"?{}:{source:t.source,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function Ls(t){const e=m$(),n=Xd(),s=$r();if(t==="operations")return e;if(t==="chains"){const a=mn.value;return a?{...e,surface:t,operation:a}:{...e,surface:t}}return t==="swarm"||t==="warroom"||t==="orchestra"?{...e,surface:t,...n?{run_id:n}:{},...s?{operation_id:s}:{}}:{...e,surface:t}}function _$(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function v$(t){switch(t){case"company":return"중대";case"platoon":return"소대";case"squad":return"분대";case"agent":return"에이전트";default:return t}}function dt(t){return ki.value===t}function Ms(){return ar.value}function f$(t){var a,i,l,c,d,p,_;const e=ar.value,n=Ue.value,s=Cs.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"실시간 실행, 워커, 메시지, 트레이스를 한 화면에서 보고 필요한 세부 표면으로 바로 이동합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 의존 관계를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(i=e==null?void 0:e.swarm_status)==null?void 0:i.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((d=(c=e==null?void 0:e.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:d.reason)??"레인 이동과 막힘 근거를 보고 다음 확인 도구를 고릅니다."};case"orchestra":return{tool:"masc_operator_snapshot",reason:"룸, 세션, 레인, 워커, 키퍼를 한 장에서 훑은 뒤 내려볼 대상을 고릅니다."};case"chains":return{tool:(_=(p=s==null?void 0:s.operations[0])==null?void 0:p.preview_run)!=null&&_.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"이 구조가 실제 관리 단위인지 자동 투영인지 먼저 구분해야 지휘면을 오해하지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 유닛과 작전을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"트레이스 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 제어 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function g$(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function $$(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function Vd(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Yd(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function Xd(){const e=Yd().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function $r(){const e=Yd().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function h$(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function y$(t){return t.status==="claimed"||t.status==="in_progress"}function b$(t){const e=Ss.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function Lo(t){var e;return((e=Ss.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function k$(t){const e=Ss.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function fe(t){try{await t()}catch{}}function hr(t){return(t==null?void 0:t.trim().toLowerCase())??""}function de(t){const e=hr(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function Ft(t){const e=hr(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function x$(){var n,s,a,i,l,c,d,p,_;const t=Ue.value;if(!t)return!1;const e=t.workers.some(v=>v.joined||v.live_presence||v.completed||v.current_task_matches_run||v.heartbeat_fresh||v.claim_marker_seen||v.done_marker_seen||v.final_marker_seen||!!v.current_task||!!v.bound_task_id||!!v.last_message);return!!((n=t.operation)!=null&&n.operation_id||(s=t.detachment)!=null&&s.detachment_id||(((a=t.summary)==null?void 0:a.joined_workers)??0)>0||(((i=t.summary)==null?void 0:i.live_workers)??0)>0||(((l=t.summary)==null?void 0:l.current_task_bound)??0)>0||(((c=t.summary)==null?void 0:c.fresh_heartbeats)??0)>0||(((d=t.summary)==null?void 0:d.claim_markers_seen)??0)>0||(((p=t.summary)==null?void 0:p.done_markers_seen)??0)>0||(((_=t.summary)==null?void 0:_.final_markers_seen)??0)>0||e||t.recent_messages.length>0||t.recent_trace_events.length>0)}function S$(t){const e=hr(t.status);return e==="active"||e==="running"}function C$(){var i,l,c,d;const t=((i=Tt.value)==null?void 0:i.sessions)??[],e=Ue.value,n=((l=e==null?void 0:e.detachment)==null?void 0:l.session_id)??null;if(n){const p=t.find(_=>_.session_id===n);if(p)return p}const s=((c=e==null?void 0:e.operation)==null?void 0:c.operation_id)??$r();if(s){const p=t.find(_=>_.command_plane_operation_id===s);if(p)return p}const a=((d=e==null?void 0:e.detachment)==null?void 0:d.detachment_id)??null;if(a){const p=t.find(_=>_.command_plane_detachment_id===a);if(p)return p}return t.find(S$)??t[0]??null}function Mn(t){return t==="proven"?"ok":t==="partial"?"warn":"bad"}function nn(t){return Array.isArray(t)?t:[]}function Nt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)?t:{}}function Ds(t){return typeof t=="string"&&t.trim()!==""?t:null}function A$(t){return typeof t=="number"&&Number.isFinite(t)?t:null}function T$(t){const e=t.split("/");return e.length<=3?t:`…/${e.slice(-3).join("/")}`}function I$(t){return t==="proven"?"충분":t==="partial"?"부분":"부족"}function R$(t){return t==="proven"?"협업 증거가 충분합니다":t==="partial"?"흔적은 있으나 협업 증거가 덜 모였습니다":"증거가 부족합니다"}function L$(t,e,n,s,a,i,l,c,d){const p=[`${s}명이 실제 흔적을 남겼고, 계획된 참여자는 ${a}명입니다.`,l>0?`서로를 참조한 상호작용 증거가 ${l}건 있습니다.`:"서로를 참조한 명시적 상호작용 증거가 아직 없습니다.",c>0?`도구·산출물·체크포인트 증거가 ${c}건 있습니다.`:"도구·산출물·체크포인트 증거가 거의 없습니다.",d>0?`CPv2 backing trace가 ${d}건 있어 실행 흔적은 남아 있습니다.`:"관리형 backing trace는 아직 없습니다."];return n==="proven"&&e==="insufficient"?[p[0]??"","왜 이렇게 판정됐나: 과거 proof는 proved였지만, 현재 보이는 live evidence는 부족해서 partial로 완화했습니다.","다음 보강 포인트: 최근 응답 턴이나 도구 호출을 다시 남겨 historical proof를 현재 상태와 연결해야 합니다."]:n==="proven"&&e==="partial"?[p[0]??"","왜 이렇게 판정됐나: historical proof는 강하지만, 현재 live evidence는 아직 partial 수준입니다.","다음 보강 포인트: 최근 상호작용과 실행 근거를 더 남기면 proven으로 회복할 수 있습니다."]:t==="partial"?[p[0]??"",i>0?`partial인 이유: 호출되었지만 응답하지 않은 참여자가 ${i}명 있습니다.`:l===0?"partial인 이유: 여러 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.":"partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.",d>0?"다음 보강 포인트: 응답 턴이나 도구 호출을 남기면 proof가 협업 수준으로 올라갑니다.":"다음 보강 포인트: 관리형 trace 또는 산출물 연결을 더 남기면 근거가 강해집니다."]:t==="proven"?[p[0]??"","결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.","다음 행동: raw evidence는 접어두고 결과 산출물과 다음 실행 결정만 확인하면 됩니다."]:[p[0]??"",i>0?`결론: 협업 시도는 있었지만 무응답 참여자가 ${i}명 있어 협업 증거로 인정하기 어렵습니다.`:"결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.",c>0?"다음 보강 포인트: 응답 턴과 도구 근거를 서로 연결해 남겨야 합니다.":"다음 보강 포인트: 참여자 간 턴, 도구 근거, 산출물 연결을 더 남겨야 합니다."]}function M$(t){return t==="historical_only"?"historical only":t==="live_and_historical"?"live + historical":"live"}function wl(t){return(t==null?void 0:t.mode)==="requested_not_found"?"bad":(t==null?void 0:t.mode)==="latest_auto_selected"?"warn":"ok"}function P$(t){return(t==null?void 0:t.mode)==="requested_not_found"?"선택 실패":(t==null?void 0:t.mode)==="latest_auto_selected"?"자동 선택":(t==null?void 0:t.mode)==="explicit"?"명시 선택":"선택 없음"}function z$(t){return t.activity_state==="acted"?(t.interaction_count??0)>0||(t.tool_evidence_count??0)>0?"ok":"warn":t.activity_state==="mentioned_only"?"warn":"bad"}function E$(t){return t.activity_state==="acted"?"실제 흔적":t.activity_state==="mentioned_only"?"호출만 됨":"계획만 됨"}function j$(t){if(t.activity_state==="acted")return`턴 ${t.turn_count??0} · spawn ${t.spawn_count??0} · 도구 근거 ${t.tool_evidence_count??0}`;if(t.activity_state==="mentioned_only"){const e=t.requested_by?`호출자 ${t.requested_by}`:"호출자 미상";return`호출 ${t.mention_count??0}회 · ${e}`}return"계획된 참여자이지만 아직 이벤트가 없습니다."}function Nl(t){return Array.isArray(t.tool_names)?t.tool_names:[]}function w$({selection:t,summary:e}){if(!t||t.mode==="explicit")return null;const n=t.mode==="latest_auto_selected"&&(e==null?void 0:e.historical_verdict)==="proven"&&(e==null?void 0:e.live_verdict)!=="proven";return o`
    <div class="command-guide-card ${wl(t)}">
      <div class="command-guide-head">
        <strong>${P$(t)}</strong>
        <span class="command-chip ${wl(t)}">${t.mode??"none"}</span>
      </div>
      <p>${t.reason??"근거 컨텍스트 선택 정보가 없습니다."}</p>
      ${n?o`<p>선택된 최신 세션은 historical proof가 더 강하고 current live evidence는 더 약합니다.</p>`:null}
      <div class="command-card-grid">
        <span>선택된 세션</span><span>${t.selected_session_id??"없음"}</span>
        <span>작성자</span><span>${t.selected_created_by??"없음"}</span>
        <span>선택된 목표</span><span>${t.selected_goal??"없음"}</span>
        <span>가용 세션 수</span><span>${t.available_session_count??0}</span>
      </div>
    </div>
  `}function N$({item:t}){return o`
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
      ${Nl(t).length>0?o`<div class="semantic-tag-row">
            ${Nl(t).map(e=>o`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
    </article>
  `}function D$(t){const e=new Map;for(const n of t){const s=[n.timestamp??"",n.event_type??"",n.actor??"",n.summary??""].join("|"),a=n.source??"unknown",i=e.get(s);if(i){i.sources.includes(a)||i.sources.push(a),!i.operation_id&&n.operation_id&&(i.operation_id=n.operation_id);continue}e.set(s,{...n,sources:[a]})}return[...e.values()]}function O$(t){return t.sources.length===2?"세션 + 지휘":t.sources.length===1?t.sources[0]==="unknown"?"출처 미상":t.sources[0]??"출처":t.sources.join(" + ")}function q$(t){const e=[];for(const[n,s]of Object.entries(t))if(s!=null){if(typeof s=="string"){if(s.trim()==="")continue;e.push({label:n,value:s});continue}if(typeof s=="number"||typeof s=="boolean"){e.push({label:n,value:String(s)});continue}}return e}function F$(t){const e=Nt(t),n=Nt(e.traces),s=Array.isArray(n.events)?n.events:[],a=Nt(e.detachments),i=Array.isArray(a.detachments)?a.detachments:[],l=Nt(i[0]),c=Nt(l.detachment),d=Nt(l.operation),p=Nt(e.summary),_=Nt(p.operations),v=Nt(_.summary);return[{label:"작전",value:Ds(e.operation_id)??"없음"},{label:"분견대",value:Ds(e.detachment_id)??"없음"},{label:"트레이스 이벤트",value:`${s.length}`},{label:"분견대 상태",value:Ds(c.status)??"없음"},{label:"작전 단계",value:Ds(d.stage)??"없음"},{label:"활성 작전",value:`${A$(v.active)??0}`}]}function K$({item:t}){return o`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${t.summary??t.event_type??"이벤트"}</strong>
          <div class="command-meta-line">
            <span>${O$(t)}</span>
            <span>${t.event_type??"이벤트"}</span>
            <span>${t.actor??"시스템"}</span>
          </div>
        </div>
        <span class="command-chip">${Q(t.timestamp)}</span>
      </div>
      ${t.sources.length>1?o`<div class="semantic-tag-row">
            ${t.sources.map(e=>o`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
    </article>
  `}function B$({item:t}){const e=t.recent_output_preview??null,n=t.recent_input_preview??null,s=t.recent_event_summary??null,a=t.recent_request_preview??null,i=t.last_active_at??t.recent_request_at??null;return o`
    <article class="mission-activity-row proof-actor-row">
      <div class="mission-activity-head">
        <div>
          <strong>${t.actor}</strong>
          <div class="mission-activity-meta">
            <span>${t.role??"참여자"}</span>
            <span>${i?Q(i):"기록 없음"}</span>
          </div>
        </div>
        <span class="command-chip ${z$(t)}">
          ${E$(t)}
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>${j$(t)}</span>
      </div>
      ${t.activity_detail?o`<div class="proof-summary-block">
            <strong>현재 해석</strong>
            <span>${t.activity_detail}</span>
          </div>`:null}
      ${s?o`<div class="proof-summary-block">
            <strong>최근 흔적</strong>
            <span>${s}</span>
          </div>`:null}
      ${a&&t.activity_state!=="acted"?o`<div class="proof-summary-block">
            <strong>최근 요청</strong>
            <span>${a}</span>
          </div>`:null}
      ${n||e?o`<div class="proof-io-grid">
            <div class="mission-activity-preview">
              <strong>최근 입력</strong>
              <span>${n??"표시 가능한 입력 없음"}</span>
            </div>
            <div class="mission-activity-preview">
              <strong>최근 응답</strong>
              <span>${e??"표시 가능한 응답 없음"}</span>
            </div>
          </div>`:null}
      ${nn(t.recent_tool_names).length>0?o`<div class="semantic-tag-row">
            ${nn(t.recent_tool_names).map(l=>o`<span class="semantic-tag">${l}</span>`)}
          </div>`:null}
    </article>
  `}function U$({item:t}){return o`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${t.kind}</strong>
          <div class="command-meta-line">
            <span>${T$(t.path)}</span>
          </div>
        </div>
        <span class="command-chip ${t.exists?"ok":"warn"}">${t.exists?"존재함":"없음"}</span>
      </div>
    </article>
  `}function Dl({title:t,rows:e}){return e.length===0?null:o`
    <div class="proof-kv-block">
      ${t?o`<strong>${t}</strong>`:null}
      <div class="proof-kv-grid">
        ${e.map(n=>o`
          <span>${n.label}</span>
          <strong>${n.value}</strong>
        `)}
      </div>
    </div>
  `}function H$(){var G,R,S;const t=D.value.params,e=t.session_id??null,n=t.operation_id??null;nt(()=>{pd(e,n)},[e,n]);const s=ud.value;if(bi.value&&!s)return o`<section class="dashboard-panel"><div class="loading-indicator">근거 화면 불러오는 중…</div></section>`;if(Ze.value&&!s)return o`<section class="dashboard-panel"><div class="error-card">${Ze.value}</div></section>`;const a=s==null?void 0:s.summary,i=(s==null?void 0:s.selection)??null,l=nn(s==null?void 0:s.actor_contributions),c=nn(s==null?void 0:s.artifacts),d=nn(s==null?void 0:s.tool_evidence),p=(s==null?void 0:s.proof_verdict)??"insufficient",_=(a==null?void 0:a.live_verdict)??p,v=(a==null?void 0:a.historical_verdict)??null,f=(a==null?void 0:a.verdict_basis)??"live",h=(s==null?void 0:s.cp_backing_evidence)??null,T=Array.isArray((G=h==null?void 0:h.traces)==null?void 0:G.events)?((S=(R=h.traces)==null?void 0:R.events)==null?void 0:S.length)??0:0,k=(a==null?void 0:a.actors_count)??l.length,C=(a==null?void 0:a.planned_actor_count)??l.length,$=(a==null?void 0:a.unanswered_actor_count)??l.filter(P=>P.activity_state!=="acted"&&(P.mention_count??0)>0).length,y=(a==null?void 0:a.mentioned_actor_count)??l.filter(P=>(P.mention_count??0)>0).length,x=(a==null?void 0:a.interaction_count)??0,M=(a==null?void 0:a.evidence_count)??0,I=D$(nn(s==null?void 0:s.timeline)),F=q$(Nt(s==null?void 0:s.goal_binding)),B=F$(h),et=c.filter(P=>P.exists).length,Z=c.length-et,tt=L$(p,_,v,k,C,$,x,M,T);return o`
    <section class="dashboard-panel mission-view">
      <${At} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>근거</h2>
          <p>이 세션이 실제로 여러 참여자의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${Mn(p)}">${I$(p)}</span>
          ${s!=null&&s.session_id?o`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?o`<span class="command-chip">${Q(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${Ze.value?o`<div class="error-card">${Ze.value}</div>`:null}

      <${w$} selection=${i} summary=${a??null} />

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${Mn(p)}">
          <span>판정</span>
          <strong>${R$(p)}</strong>
          <small>${(a==null?void 0:a.detail)??"협업 증거를 verdict로 요약합니다."}</small>
        </div>
        <div class="summary-stat-card ${Mn(_)}">
          <span>Live 판정</span>
          <strong>${_}</strong>
          <small>${M$(f)} 기준 최종 판정에 반영</small>
        </div>
        <div class="summary-stat-card ${Mn(v??"insufficient")}">
          <span>Historical proof</span>
          <strong>${v??"none"}</strong>
          <small>persisted proof 문서 기준</small>
        </div>
        <div class="summary-stat-card">
          <span>실제 흔적</span>
          <strong>${k}</strong>
          <small>이벤트를 남긴 actor 수</small>
        </div>
        <div class="summary-stat-card ${C>k?"warn":"ok"}">
          <span>계획된 참여자</span>
          <strong>${C}</strong>
          <small>${y>0?`${y}명 호출됨`:"호출 기록 없음"}</small>
        </div>
        <div class="summary-stat-card ${$>0?"warn":"ok"}">
          <span>무응답</span>
          <strong>${$}</strong>
          <small>${$>0?"호출됐지만 응답 근거 없음":"무응답 참여자 없음"}</small>
        </div>
        <div class="summary-stat-card ${x>0?"ok":"warn"}">
          <span>직접 상호작용</span>
          <strong>${x}</strong>
          <small>참여자 간 직접 연결 근거</small>
        </div>
        <div class="summary-stat-card ${M>0?"ok":"warn"}">
          <span>근거</span>
          <strong>${M}</strong>
          <small>도구 / 산출물 / 체크포인트</small>
        </div>
        <div class="summary-stat-card ${T>0?"ok":"warn"}">
          <span>CP 트레이스</span>
          <strong>${T}</strong>
          <small>관리형 backing 이벤트</small>
        </div>
        <div class="summary-stat-card ${Z===0&&c.length>0?"ok":"warn"}">
          <span>산출물</span>
          <strong>${et}/${c.length}</strong>
          <small>${Z>0?`${Z}개 누락`:"전부 존재함"}</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${L} title="3줄 근거 요약" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, 왜 아직 부족한지, 다음에 무엇을 남겨야 하는지만 먼저 봅니다.</p>
          </div>
          <div class="proof-summary-stack">
            ${tt.map((P,J)=>o`
              <article class="proof-summary-block ${J===1&&p!=="proven"?Mn(p):""}">
                <strong>${J===0?"지금 결론":J===1?"왜 이렇게 판정됐나":"다음 보강 포인트"}</strong>
                <span>${P}</span>
              </article>
            `)}
          </div>
        <//>

        <${L} title="목표 연결" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 화면이 어떤 세션과 목표를 기준으로 그려졌는지 먼저 고정합니다.</p>
          </div>
          <${Dl} rows=${F} />
          <details class="mission-card-disclosure compact">
            <summary>원본 목표 연결 JSON</summary>
            <pre class="command-json-block">${os((s==null?void 0:s.goal_binding)??{})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${L} title="협업 타임라인" class="mission-list-card" semanticId="proof.timeline">
          <div class="mission-section-head">
            <h3>협업 타임라인</h3>
            <p>team-session과 command-plane에서 같은 사건이 보이면 한 줄로 묶어 읽습니다.</p>
          </div>
          <div class="mission-list-stack">
            ${I.length>0?I.slice(0,18).map(P=>o`<${K$} key=${P.id} item=${P} />`):o`<div class="empty-state">표시할 타임라인 근거가 없습니다.</div>`}
          </div>
        <//>

        <${L} title="참여 흔적" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>실제 흔적, 호출만 된 참여자, 계획만 된 참여자를 구분해서 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${l.length>0?l.map(P=>o`<${B$} key=${P.actor} item=${P} />`):o`<div class="empty-state">표시할 참여 흔적이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${L} title="도구 근거" class="mission-list-card" semanticId="proof.tool_evidence">
          <div class="mission-section-head">
            <h3>어떤 도구를 언제 썼는가</h3>
            <p>숫자만 보여주지 말고, 최근 도구 호출 근거를 직접 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${d.length>0?d.map((P,J)=>o`<${N$} key=${`${P.actor??"system"}-${J}`} item=${P} />`):o`<div class="empty-state">기록된 tool evidence가 없습니다.</div>`}
          </div>
        <//>

        <${L} title="실행 근거" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>작전, 분견대, 트레이스 수만 먼저 보고, 원본 CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${Dl} rows=${B} />
          <details class="mission-card-disclosure compact">
            <summary>원본 CPv2 backing JSON</summary>
            <pre class="command-json-block">${os(h??{})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${L} title="산출물" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>어떤 파일 산출물이 남았나</h3>
            <p>proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${c.length>0?c.map(P=>o`<${U$} key=${P.path} item=${P} />`):o`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function Mo(t){const e=(t??"").trim().toLowerCase();return e==="bad"||e==="critical"||e==="offline"?"bad":e==="warn"||e==="paused"||e==="blocked"?"warn":"ok"}function W$(){var n;const t=(n=nr.value)==null?void 0:n.focus;if(!(t!=null&&t.suggested_tab))return;const e=t.suggested_params??{};if(t.suggested_tab==="intervene"){at("intervene",e);return}at("command",{...t.suggested_surface?{surface:t.suggested_surface}:{},...e})}function yr(){var d,p,_,v,f,h;const t=nr.value;if(!t)return $i.value?o`<section class="room-truth-strip room-truth-strip-loading">room truth 불러오는 중...</section>`:Sa.value?o`<section class="room-truth-strip room-truth-strip-error">${Sa.value}</section>`:null;const e=t.room.status,n=t.room.counts,s=(d=t.execution)==null?void 0:d.summary,a=(p=t.execution)==null?void 0:p.top_queue,i=t.command,l=t.operator,c=t.focus;return o`
    <section class="room-truth-strip">
      <article class="room-truth-card">
        <span class="room-truth-label">room truth</span>
        <strong>${(e==null?void 0:e.project)??"project"} · ${(e==null?void 0:e.room)??"default"}</strong>
        <p>${(n==null?void 0:n.agents)??0} agents · ${(n==null?void 0:n.tasks)??0} tasks · ${(n==null?void 0:n.keepers)??0} keepers</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${e!=null&&e.paused?"warn":"ok"}">${e!=null&&e.paused?"일시정지":"열림"}</span>
          <span class="command-chip">${(e==null?void 0:e.cluster)??"cluster:unknown"}</span>
          <${we} item=${{kind:t.room.provenance??"truth"}} />
        </div>
      </article>

      <article class="room-truth-card">
        <span class="room-truth-label">execution</span>
        <strong>세션 ${(s==null?void 0:s.active_sessions)??0} · 막힘 ${(s==null?void 0:s.blocked_sessions)??0}</strong>
        <p>${(a==null?void 0:a.summary)??"지금은 실행 대기열 최상단 항목이 없습니다."}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${Mo(((s==null?void 0:s.blocked_sessions)??0)>0?"warn":"ok")}">priority ${(s==null?void 0:s.priority_items)??0}</span>
          <${we} item=${{kind:((_=t.execution)==null?void 0:_.provenance)??"derived"}} />
        </div>
      </article>

      <article class="room-truth-card">
        <span class="room-truth-label">control</span>
        <strong>작전 ${(i==null?void 0:i.active_operations)??0} · 승인 ${(i==null?void 0:i.pending_approvals)??0}</strong>
        <p>alerts bad ${(i==null?void 0:i.bad_alerts)??0} / warn ${(i==null?void 0:i.warn_alerts)??0} · lanes ${(i==null?void 0:i.moving_lanes)??0}/${(i==null?void 0:i.active_lanes)??0}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${Mo(((i==null?void 0:i.bad_alerts)??0)>0?"bad":((i==null?void 0:i.warn_alerts)??0)>0||((i==null?void 0:i.pending_approvals)??0)>0?"warn":"ok")}">
            health ${(l==null?void 0:l.health)??"ok"}
          </span>
          <${we} item=${{kind:(i==null?void 0:i.provenance)??"truth"}} />
        </div>
      </article>

      <article class="room-truth-card room-truth-card-focus">
        <span class="room-truth-label">next focus</span>
        <strong>${(c==null?void 0:c.label)??"지금은 방 전체가 비교적 안정적입니다"}</strong>
        <p>${(c==null?void 0:c.reason)??((f=(v=l==null?void 0:l.attention_summary)==null?void 0:v.top_item)==null?void 0:f.summary)??(a==null?void 0:a.summary)??"다음 drill-down 대상이 아직 없습니다."}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${Mo((c==null?void 0:c.provenance)==="fallback"?"warn":"ok")}">${(c==null?void 0:c.source)??"steady"}</span>
          <${we} item=${{kind:(c==null?void 0:c.provenance)??((h=l==null?void 0:l.recommendation_summary)==null?void 0:h.provenance)??"derived"}} />
        </div>
        ${c!=null&&c.suggested_tab?o`
              <div class="room-truth-actions">
                <button class="control-btn ghost" onClick=${W$}>
                  ${c.suggested_tab==="intervene"?"개입면 열기":"지휘면 열기"}
                </button>
              </div>
            `:null}
      </article>
    </section>
  `}function G$(){const t=As(D.value);return t?o`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${co(t.action_type)}</span>
        <span class="command-chip">${mr(t)}</span>
        <span class="command-chip">${qf(D.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?o`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function J$(){const t=X.value,e=p$[t],n=f$(t);return o`
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
  `}function Os({label:t,value:e,subtext:n,percent:s,color:a}){return o`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${l$(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(Rs(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function qs({label:t,value:e,detail:n,percent:s,tone:a}){return o`
    <article class="command-signal-rail ${z(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${z(a)}" style=${`width: ${Math.max(8,Math.round(Rs(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function V$(){var Z,tt,G,R;const t=Ms(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,i=t==null?void 0:t.alerts.summary,l=(Z=t==null?void 0:t.swarm_status)==null?void 0:Z.overview,c=t==null?void 0:t.swarm_proof,d=t==null?void 0:t.operations.microarch,p=(e==null?void 0:e.managed_unit_count)??0,_=(e==null?void 0:e.total_units)??0,v=(n==null?void 0:n.active)??0,f=(s==null?void 0:s.active)??0,h=(l==null?void 0:l.moving_lanes)??0,T=(l==null?void 0:l.active_lanes)??0,k=(c==null?void 0:c.workers.done)??0,C=(c==null?void 0:c.workers.expected)??0,$=(i==null?void 0:i.bad)??0,y=(i==null?void 0:i.warn)??0,x=(a==null?void 0:a.pending)??0,M=(a==null?void 0:a.total)??0,I=v+f,F=((tt=d==null?void 0:d.cache)==null?void 0:tt.l1_hit_rate)??((R=(G=d==null?void 0:d.signals)==null?void 0:G.cache_contention)==null?void 0:R.l1_hit_rate)??0,B=v>0||f>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",et=v>0||h>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return o`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${B}</h3>
        <p>${et}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${z(v>0?"ok":"warn")}">활성 작전 ${v}</span>
          <span class="command-chip ${z(h>0?"ok":(T>0,"warn"))}">이동 레인 ${h}/${Math.max(T,h)}</span>
          <span class="command-chip ${z($>0?"bad":y>0?"warn":"ok")}">치명 알림 ${$}</span>
          <span class="command-chip ${z(x>0?"warn":"ok")}">승인 대기 ${x}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Os}
          label="관리 단위 범위"
          value=${`${p}/${Math.max(_,p)}`}
          subtext=${_>0?`${_-p}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${Te(p,Math.max(_,p))}
          color="#67e8f9"
        />
        <${Os}
          label="실행 열도"
          value=${String(I)}
          subtext=${`${v}개 작전 + ${f}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${Te(I,Math.max(p,I||1))}
          color="#4ade80"
        />
        <${Os}
          label="스웜 이동감"
          value=${`${h}/${Math.max(T,h)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${Q(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${Te(h,Math.max(T,h||1))}
          color="#fbbf24"
        />
        <${Os}
          label="증거 수집률"
          value=${`${k}/${Math.max(C,k)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${Te(k,Math.max(C,k||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${qs}
        label="승인 대기열"
        value=${`${x}건 대기`}
        detail=${`현재 정책 창에서 ${M}개 결정을 추적 중입니다`}
        percent=${Te(x,Math.max(M,x||1))}
        tone=${x>0?"warn":"ok"}
      />
      <${qs}
        label="알림 압력"
        value=${`치명 ${$} / 주의 ${y}`}
        detail=${$>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${Te($*2+y,Math.max(($+y)*2,1))}
        tone=${$>0?"bad":y>0?"warn":"ok"}
      />
      <${qs}
        label="디스패치 점유"
          value=${`${f}개 가동`}
        detail=${p>0?`${p}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${Te(f,Math.max(p,f||1))}
        tone=${f>0?"ok":"warn"}
      />
      <${qs}
        label="캐시 신뢰도"
        value=${F?Tn(F):"정보 없음"}
        detail=${F?"microarch 캐시 텔레메트리에서 집계한 L1 적중률":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Rs((F??0)*100)}
        tone=${F>=.75?"ok":F>=.4?"warn":"bad"}
      />
    </div>
  `}function Y$(){var f,h,T,k,C;const t=Ms(),e=Cs.value,n=As(D.value),s=g$(n),a=t==null?void 0:t.topology.summary,i=t==null?void 0:t.operations.summary,l=(f=t==null?void 0:t.swarm_status)==null?void 0:f.overview,c=t==null?void 0:t.operations.microarch,d=t==null?void 0:t.decisions.summary,p=t==null?void 0:t.alerts.summary,_=(h=c==null?void 0:c.signals)==null?void 0:h.issue_pressure,v=c==null?void 0:c.cache;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(i==null?void 0:i.active)??0}</strong><small>${((T=t==null?void 0:t.detachments.summary)==null?void 0:T.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(d==null?void 0:d.pending)??0}</strong><small>${(d==null?void 0:d.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(p==null?void 0:p.bad)??0}</strong><small>${(p==null?void 0:p.warn)??0}건 주의</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((k=e==null?void 0:e.summary)==null?void 0:k.active_chains)??0}</strong><small>${((C=e==null?void 0:e.summary)==null?void 0:C.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${Q(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(_==null?void 0:_.pending_ops)??0}</strong><small>${(v==null?void 0:v.l1_hit_rate)!=null?`${Tn(v.l1_hit_rate)} L1 적중`:"캐시 데이터 없음"} · ${(_==null?void 0:_.tone)??"정보 없음"}</small></div>
    </div>
  `}function X$(){var Z,tt,G,R,S,P,J,yt,oe;const t=Ms(),e=Vt.value,n=ut.value,s=Vd(),a=s?Jt.value.find(U=>U.name===s)??null:null,i=s?ue.value.filter(U=>U.assignee===s&&y$(U)):[],l=((Z=t==null?void 0:t.operations.summary)==null?void 0:Z.active)??0,c=((tt=t==null?void 0:t.detachments.summary)==null?void 0:tt.total)??0,d=((G=t==null?void 0:t.decisions.summary)==null?void 0:G.pending)??0,p=e==null?void 0:e.detachments.detachments.find(U=>{const vt=U.detachment.heartbeat_deadline,xe=vt?Date.parse(vt):Number.NaN;return U.detachment.status==="stalled"||!Number.isNaN(xe)&&xe<=Date.now()}),_=e==null?void 0:e.alerts.alerts.find(U=>U.severity==="bad"),v=!!(n!=null&&n.room||n!=null&&n.project),f=(a==null?void 0:a.current_task)??null,h=h$(a==null?void 0:a.last_seen),T=h!=null?h<=120:null,k=[v?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?i.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:ue.value.length>0?"masc_claim":"masc_add_task"}:f?T===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${f} 이지만 heartbeat가 stale 합니다 (${h}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${f}${h!=null?` · 마지막 활동 ${h}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((R=t.topology.summary)==null?void 0:R.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((S=t.topology.summary)==null?void 0:S.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((P=t.topology.summary)==null?void 0:P.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},d>0?{title:"디스패치 준비도",tone:"warn",detail:`${d}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:p||_?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${p?` · detachment ${p.detachment.detachment_id} 가 stalled 상태입니다`:""}${_?` · alert ${_.title??_.alert_id}`:""}${!e&&!p&&!_?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:d>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],C=v?!s||!a?"masc_join":i.length===0?ue.value.length>0?"masc_claim":"masc_add_task":f?T===!1?"masc_heartbeat":!t||(((J=t.topology.summary)==null?void 0:J.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":d>0?"masc_policy_approve":l>0&&c===0||p||_?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",$=b$(C),x=k$(C==="masc_set_room"?["repo-root-room"]:C==="masc_plan_set_task"?["claimed-not-current"]:C==="masc_heartbeat"?["heartbeat-stale"]:C==="masc_dispatch_tick"?["no-detachments"]:C==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),M=Lo("room_task_hygiene"),I=Lo("cpv2_benchmark"),F=Lo("supervisor_session"),B=((yt=Ss.value)==null?void 0:yt.docs)??[],et=[M,I,F].filter(U=>U!==null);return o`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${O} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${($==null?void 0:$.title)??C}</strong>
            <span class="command-chip ok">${C}</span>
          </div>
          <p>${($==null?void 0:$.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(oe=$==null?void 0:$.success_signals)!=null&&oe.length?o`<div class="command-tag-row">
                ${$.success_signals.map(U=>o`<span class="command-tag ok">${U}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${k.map(U=>o`
            <article class="command-readiness-row ${z(U.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${U.title}</strong>
                  <span class="command-chip ${z(U.tone)}">${U.tone}</span>
                </div>
                <p>${U.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${U.tool}</div>
            </article>
          `)}
        </div>

        ${x.length>0?o`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${x.length}</span>
                </div>
                <div class="command-guide-list">
                  ${x.map(U=>o`
                    <article class="command-guide-inline">
                      <strong>${U.title}</strong>
                      <div>${U.symptom}</div>
                      <div class="command-card-sub">${U.fix_tool} 로 해결: ${U.fix_summary}</div>
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
        ${xi.value?o`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:Ea.value?o`<div class="empty-state error">${Ea.value}</div>`:o`
                <div class="command-path-grid">
                  ${et.map(U=>o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${U.title}</strong>
                        <span class="command-chip">${U.id}</span>
                      </div>
                      <p>${U.summary}</p>
                      <div class="command-card-sub">${U.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${U.steps.slice(0,4).map(vt=>o`
                          <div class="command-step-row">
                            <span class="command-step-tool">${vt.tool}</span>
                            <span>${vt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${B.length>0?o`<div class="command-doc-links">
                      ${B.map(U=>o`<span class="command-tag">${U.title}: ${U.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Q$(){return o`
    <${V$} />
    <${Y$} />
    <${X$} />
  `}function Z$(){return La.value?o`<div class="empty-state">command-plane detail 불러오는 중…</div>`:Pa.value?o`<div class="empty-state error">${Pa.value}</div>`:o`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}const Ie=g(null),Fs=g("compact"),re=g({zoom:1,panX:0,panY:0}),Po=g(!1),Ks=g(!1),Nn={width:1280,height:760},Qd=.42,Zd=1.9;function da(t,e,n){return Math.max(e,Math.min(n,t))}function br(t,e){const n=t==null?void 0:t.trim();return n?n.length<=e?n:`${n.slice(0,Math.max(1,e-1))}…`:null}function th(t){return t==="compact"?"집약":"균형"}function Ol(t){switch((t??"").trim().toLowerCase()){case"room":return"룸";case"session":return"세션";case"operation":return"작전";case"detachment":return"분견대";case"lane":return"레인";case"worker":return"워커";case"keeper":return"키퍼";default:return(t==null?void 0:t.trim())||"노드"}}function Bs(t,e,n){if(t<=0)return[];if(t===1)return[Math.round((e+n)/2)];const s=(n-e)/(t-1);return Array.from({length:t},(a,i)=>Math.round(e+i*s))}function eh(t,e){const n=new Map;for(const s of t){const a=e(s),i=n.get(a)??[];i.push(s),n.set(a,i)}return n}function tu(t){return t==="compact"?{room:{x:660,y:108},sessions:{y:228,min:220,max:1110},operations:{y:338,min:260,max:1050},detachments:{y:430,min:310,max:1e3},lanes:{y:540,min:220,max:1110},worker:{perRow:5,xSpacing:60,ySpacing:52,laneOffsetY:76,freeBaseY:662},keeper:{startX:1180,colSpacing:92,rowSpacing:90,startY:176,columns:2},signalRadius:116}:{room:{x:700,y:112},sessions:{y:236,min:240,max:1140},operations:{y:356,min:300,max:1080},detachments:{y:454,min:340,max:1030},lanes:{y:584,min:230,max:1110},worker:{perRow:4,xSpacing:72,ySpacing:60,laneOffsetY:82,freeBaseY:720},keeper:{startX:1210,colSpacing:108,rowSpacing:102,startY:188,columns:2},signalRadius:132}}function eu(t,e){return t.kind==="room"?e==="compact"?{width:138,height:138,radius:68}:{width:156,height:156,radius:76}:t.kind==="worker"?e==="compact"?{width:70,height:36,radius:18}:{width:84,height:44,radius:22}:t.kind==="lane"?e==="compact"?{width:156,height:48,radius:15}:{width:176,height:56,radius:17}:t.kind==="keeper"?e==="compact"?{width:118,height:50,radius:22}:{width:132,height:60,radius:24}:t.kind==="session"?e==="compact"?{width:182,height:58,radius:17}:{width:202,height:68,radius:18}:e==="compact"?{width:176,height:58,radius:16}:{width:196,height:68,radius:18}}function nh(t,e){const n=t.kind==="worker"?e==="compact"?10:14:t.kind==="keeper"?e==="compact"?12:16:t.kind==="lane"?e==="compact"?16:22:e==="compact"?18:26;return br(t.label,n)??t.label}function sh(t,e){if(e==="compact"&&(t.kind==="worker"||t.kind==="keeper"||t.kind==="detachment"))return null;const n=t.kind==="session"?e==="compact"?20:28:e==="compact"?14:24;return br(t.subtitle,n)}function ah(t,e){return e==="compact"&&t.kind!=="session"&&t.kind!=="operation"?null:br(t.status,e==="compact"?10:14)}function oh(t,e){const n=tu(e),s=new Map,a=t.nodes,i=a.find(k=>k.kind==="room")??null,l=a.filter(k=>k.kind==="session"),c=a.filter(k=>k.kind==="operation"),d=a.filter(k=>k.kind==="detachment"),p=a.filter(k=>k.kind==="lane"),_=a.filter(k=>k.kind==="worker"),v=a.filter(k=>k.kind==="keeper");i&&s.set(i.id,{x:n.room.x,y:n.room.y}),Bs(l.length,n.sessions.min,n.sessions.max).forEach((k,C)=>{const $=l[C];$&&s.set($.id,{x:k,y:n.sessions.y})}),Bs(c.length,n.operations.min,n.operations.max).forEach((k,C)=>{const $=c[C];$&&s.set($.id,{x:k,y:n.operations.y})}),Bs(d.length,n.detachments.min,n.detachments.max).forEach((k,C)=>{const $=d[C];$&&s.set($.id,{x:k,y:n.detachments.y})}),Bs(p.length,n.lanes.min,n.lanes.max).forEach((k,C)=>{const $=p[C];$&&s.set($.id,{x:k,y:n.lanes.y})});const f=new Map(p.map(k=>{const C=s.get(k.id);return C?[k.id,C.x]:null}).filter(k=>k!==null)),h=eh(_,k=>k.lane_id?`lane:${k.lane_id}`:k.parent_id?k.parent_id:"free");let T=0;for(const[k,C]of h){let $=f.get(k.replace(/^lane:/,""));if($==null){const x=s.get(k);$=x==null?void 0:x.x}$==null&&($=260+T%4*180,T+=1);const y=Math.max(1,Math.ceil(C.length/n.worker.perRow));for(let x=0;x<y;x+=1){const M=C.slice(x*n.worker.perRow,(x+1)*n.worker.perRow),I=(M.length-1)*n.worker.xSpacing,F=$-I/2;M.forEach((B,et)=>{var Z;s.set(B.id,{x:Math.round(F+et*n.worker.xSpacing),y:k==="free"?n.worker.freeBaseY+x*n.worker.ySpacing:(((Z=s.get(k.replace(/^lane:/,"")))==null?void 0:Z.y)??n.lanes.y)+n.worker.laneOffsetY+x*n.worker.ySpacing})})}}return v.forEach((k,C)=>{const $=C%n.keeper.columns,y=Math.floor(C/n.keeper.columns);s.set(k.id,{x:n.keeper.startX+$*n.keeper.colSpacing,y:n.keeper.startY+y*n.keeper.rowSpacing})}),s}function ih(t,e,n){if(!e||t.signals.length===0)return[];const s=tu(n);return t.signals.slice(0,6).map((a,i)=>{const l=(-130+i*36)*(Math.PI/180);return{signalNode:a,x:Math.round(e.x+Math.cos(l)*s.signalRadius),y:Math.round(e.y+Math.sin(l)*s.signalRadius)}})}function rh(t,e,n,s){let a=Number.POSITIVE_INFINITY,i=Number.NEGATIVE_INFINITY,l=Number.POSITIVE_INFINITY,c=Number.NEGATIVE_INFINITY;for(const d of t.nodes){const p=e.get(d.id);if(!p)continue;const _=eu(d,s);d.kind==="room"?(a=Math.min(a,p.x-_.radius),i=Math.max(i,p.x+_.radius),l=Math.min(l,p.y-_.radius),c=Math.max(c,p.y+_.radius)):(a=Math.min(a,p.x-_.width/2),i=Math.max(i,p.x+_.width/2),l=Math.min(l,p.y-_.height/2),c=Math.max(c,p.y+_.height/2))}for(const d of n)a=Math.min(a,d.x-20),i=Math.max(i,d.x+20),l=Math.min(l,d.y-20),c=Math.max(c,d.y+20);return!Number.isFinite(a)||!Number.isFinite(i)||!Number.isFinite(l)||!Number.isFinite(c)?{minX:0,minY:0,maxX:Nn.width,maxY:Nn.height,width:Nn.width,height:Nn.height}:{minX:a,minY:l,maxX:i,maxY:c,width:Math.max(1,i-a),height:Math.max(1,c-l)}}function ql(t,e,n){const s=n==="compact"?48:72,a=Math.max(360,e.width-s*2),i=Math.max(280,e.height-s*2),l=da(Math.min(a/Math.max(t.width,1),i/Math.max(t.height,1)),Qd,Zd),c=t.minX+t.width/2,d=t.minY+t.height/2;return{zoom:l,panX:e.width/2-c*l,panY:e.height/2-d*l}}function lh(t,e){const n=(t.x+e.x)/2,s=e.y>=t.y?32:-32;return`M ${t.x} ${t.y} C ${n} ${t.y+s}, ${n} ${e.y-s}, ${e.x} ${e.y}`}function Fl(t,e,n){if(t==="command"){if(e){Bt(e),at("command",{...Ls(e),...n});return}at("command",n);return}if(t==="intervene"){at("intervene",n);return}at("command",n)}function ch({signalNodes:t,roomPoint:e,onSelect:n}){return!e||t.length===0?null:o`
    ${t.map(({signalNode:s,x:a,y:i})=>o`
      <g
        key=${s.id}
        data-orchestra-signal="true"
        class=${`orchestra-signal-node ${z(s.tone)}`}
        onClick=${()=>n(s.id)}
      >
        <title>${s.label}${s.detail?` — ${s.detail}`:""}</title>
        <line x1=${e.x} y1=${e.y} x2=${a} y2=${i} class="orchestra-signal-link" />
        <circle cx=${a} cy=${i} r="16" class="orchestra-signal-dot" />
        <text x=${a} y=${i+4} text-anchor="middle" class="orchestra-signal-glyph">!</text>
      </g>
    `)}
  `}function dh({edges:t,positions:e,selectedId:n}){return o`
    ${t.map(s=>{const a=e.get(s.source),i=e.get(s.target);if(!a||!i)return null;const l=n!=null&&(s.source===n||s.target===n);return o`
        <path
          key=${s.id}
          d=${lh(a,i)}
          class=${`orchestra-edge ${z(s.tone)} ${s.animated?"animated":""} ${l?"active":""}`}
        />
      `})}
  `}function uh({orchestra:t,positions:e,density:n,selectedId:s,onSelect:a}){var l;const i=((l=t.focus)==null?void 0:l.target_kind)==="node"?t.focus.target_id:null;return o`
    ${t.nodes.map(c=>{const d=e.get(c.id);if(!d)return null;const p=eu(c,n),_=c.id===s,v=c.id===i,f=c.visual_class??c.kind,h=nh(c,n),T=sh(c,n),k=ah(c,n);if(c.kind==="room")return o`
          <g
            key=${c.id}
            data-orchestra-node="true"
            class=${`orchestra-node room ${z(c.tone)} ${_?"selected":""} ${v?"focused":""}`}
            onClick=${()=>a(c.id)}
          >
            <title>${c.label}</title>
            <circle cx=${d.x} cy=${d.y} r=${p.radius} class="orchestra-room-ring outer" />
            <circle cx=${d.x} cy=${d.y} r=${p.radius-16} class="orchestra-room-ring inner" />
            <text x=${d.x} y=${d.y-10} text-anchor="middle" class="orchestra-room-glyph">${c.glyph??"◎"}</text>
            <text x=${d.x} y=${d.y+22} text-anchor="middle" class="orchestra-room-label">${h}</text>
          </g>
        `;const C=d.x-p.width/2,$=d.y-p.height/2;return o`
        <g
          key=${c.id}
          data-orchestra-node="true"
          class=${`orchestra-node ${f} ${z(c.tone)} ${_?"selected":""} ${v?"focused":""}`}
          onClick=${()=>a(c.id)}
        >
          <title>${c.label}${c.subtitle?` — ${c.subtitle}`:""}${c.status?` (${c.status})`:""}</title>
          <rect x=${C} y=${$} width=${p.width} height=${p.height} rx=${p.radius} class="orchestra-node-body" />
          <text x=${C+16} y=${$+24} class="orchestra-node-glyph">${c.glyph??"•"}</text>
          <text x=${C+38} y=${$+24} class="orchestra-node-label">${h}</text>
          ${T?o`<text x=${C+38} y=${$+42} class="orchestra-node-subtitle">${T}</text>`:null}
          ${k?o`<text x=${C+p.width-10} y=${$+18} text-anchor="end" class="orchestra-node-status">${k}</text>`:null}
        </g>
      `})}
  `}function nu(t){var s,a;const e=Ie.value;if(e){const i=t.nodes.find(c=>c.id===e);if(i)return{type:"node",value:i};const l=t.signals.find(c=>c.id===e);if(l)return{type:"signal",value:l}}if(((s=t.focus)==null?void 0:s.target_kind)==="node"){const i=t.nodes.find(l=>{var c;return l.id===((c=t.focus)==null?void 0:c.target_id)});if(i)return{type:"node",value:i}}if(((a=t.focus)==null?void 0:a.target_kind)==="signal"){const i=t.signals.find(l=>{var c;return l.id===((c=t.focus)==null?void 0:c.target_id)});if(i)return{type:"signal",value:i}}const n=t.nodes[0];return n?{type:"node",value:n}:null}function ph({orchestra:t}){const e=nu(t);if(!e)return o`<aside class="orchestra-drawer card"><div class="empty-state">선택 가능한 대상이 아직 없습니다.</div></aside>`;if(e.type==="signal"){const i=e.value;return o`
      <aside class="orchestra-drawer card ${z(i.tone)}">
        <div class="card-title-row">
          <div class="card-title">${i.label}</div>
          <span class="command-chip ${z(i.tone)}">${Ol(i.kind)}</span>
        </div>
        <p>${i.detail??"세부 설명이 없습니다."}</p>
        ${i.suggested_surface?o`
              <div class="command-action-row">
                <button
                  class="control-btn"
                  onClick=${()=>Fl("command",i.suggested_surface,i.suggested_params??{})}
                >
                  추천 화면 열기
                </button>
              </div>
            `:null}
      </aside>
    `}const n=e.value,s=t.signals.filter(i=>i.source_id===n.id||i.target_id===n.id),a=t.edges.filter(i=>i.source===n.id||i.target===n.id);return o`
    <aside class="orchestra-drawer card ${z(n.tone)}">
      <div class="card-title-row">
        <div class="card-title">${n.label}</div>
        <span class="command-chip ${z(n.tone)}">${Ol(n.kind)}</span>
      </div>
      ${n.subtitle?o`<p class="command-card-sub">${n.subtitle}</p>`:null}
      <div class="orchestra-fact-list">
        ${n.facts.map(i=>o`
          <div class="orchestra-fact-row">
            <span>${i.label}</span>
            <strong>${i.value}</strong>
          </div>
        `)}
      </div>
      ${s.length>0?o`
        <div class="command-tag-row">
          ${s.map(i=>o`<span class="command-chip ${z(i.tone)}">${i.label}</span>`)}
        </div>
      `:null}
      <div class="command-card-sub">연결 ${a.length}개 · 근거 ${n.provenance}</div>
      ${n.link_tab&&(n.link_surface||Object.keys(n.link_params??{}).length>0)?o`
            <div class="command-action-row">
              <button
                class="control-btn"
                onClick=${()=>Fl(n.link_tab??"command",n.link_surface,n.link_params??{})}
              >
                이 화면 열기
              </button>
            </div>
          `:null}
    </aside>
  `}function mh(){var et,Z,tt,G;const t=or.value,e=Dn(null),n=Dn(null),s=Dn(""),[a,i]=$n(Nn);if(nt(()=>{const R=e.current;if(!R)return;const S=()=>{const J=R.getBoundingClientRect();J.width<=0||J.height<=0||i({width:Math.max(640,Math.round(J.width)),height:Math.max(480,Math.round(J.height))})};if(S(),typeof ResizeObserver>"u")return window.addEventListener("resize",S),()=>window.removeEventListener("resize",S);const P=new ResizeObserver(()=>S());return P.observe(R),()=>P.disconnect()},[]),Si.value&&!t)return o`<section class="card command-section"><div class="empty-state">오케스트라 맵 불러오는 중…</div></section>`;if(Na.value)return o`<section class="card command-section"><div class="empty-state error">${Na.value}</div></section>`;if(!t)return o`<section class="card command-section"><div class="empty-state">오케스트라 맵 데이터가 아직 없습니다.</div></section>`;const l=Fs.value,c=oh(t,l),d=t.nodes.find(R=>R.kind==="room")??null,p=d?c.get(d.id)??null:null,_=ih(t,p,l),v=rh(t,c,_,l),f=nu(t),h=(f==null?void 0:f.value.id)??null,T=`${l}:${a.width}x${a.height}:${t.nodes.length}:${t.edges.length}:${t.signals.length}`,k=(R,S)=>{re.value=R,Ks.value=S},C=()=>{k(ql(v,a,l),!1)},$=()=>{if(Ie.value=null,l!=="compact"){Fs.value="compact",Ks.value=!1;return}C()};nt(()=>{h&&!t.nodes.some(R=>R.id===h)&&!t.signals.some(R=>R.id===h)&&(Ie.value=null)},[T,h,t]),nt(()=>{(!Ks.value||s.current!==T)&&(k(ql(v,a,l),!1),s.current=T)},[T]);const y=re.value,x=(R,S,P)=>{const J=re.value.zoom,yt=da(J*P,Qd,Zd);if(Math.abs(yt-J)<.001)return;const oe=(R-re.value.panX)/J,U=(S-re.value.panY)/J;k({zoom:yt,panX:R-oe*yt,panY:S-U*yt},!0)},M=R=>{R.preventDefault();const S=e.current;if(!S)return;const P=S.getBoundingClientRect(),J=da(R.clientX-P.left,0,P.width),yt=da(R.clientY-P.top,0,P.height);x(J,yt,R.deltaY<0?1.1:.92)},I=R=>{var J;const S=R.target;if(!(S instanceof Element)||!S.closest('[data-orchestra-background="true"]'))return;const P=R.currentTarget;P&&(n.current={pointerId:R.pointerId,startX:R.clientX,startY:R.clientY,panX:re.value.panX,panY:re.value.panY},Po.value=!0,Ks.value=!0,(J=P.setPointerCapture)==null||J.call(P,R.pointerId))},F=R=>{const S=n.current;!S||S.pointerId!==R.pointerId||k({zoom:re.value.zoom,panX:S.panX+(R.clientX-S.startX),panY:S.panY+(R.clientY-S.startY)},!0)},B=R=>{var P;if(!n.current)return;const S=R==null?void 0:R.currentTarget;S&&R&&((P=S.releasePointerCapture)==null||P.call(S,R.pointerId)),n.current=null,Po.value=!1};return o`
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
          <button class="control-btn ghost" onClick=${C}>맞춤 보기</button>
          <button class="control-btn ghost" onClick=${$}>초기화</button>
        </div>
        <div class="orchestra-toolbar-group">
          <button
            class="control-btn ghost"
            onClick=${()=>x(a.width/2,a.height/2,1.12)}
          >
            확대
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>x(a.width/2,a.height/2,.9)}
          >
            축소
          </button>
          <span class="command-chip">${Math.round(y.zoom*100)}%</span>
        </div>
        <div class="orchestra-toolbar-group">
          <button
            class=${`control-btn ${l==="balanced"?"is-active":"ghost"}`}
            onClick=${()=>{Fs.value="balanced",Ie.value=h}}
          >
            균형
          </button>
          <button
            class=${`control-btn ${l==="compact"?"is-active":"ghost"}`}
            onClick=${()=>{Fs.value="compact",Ie.value=h}}
          >
            집약
          </button>
          <span class="command-chip">${th(l)}</span>
        </div>
      </div>

      <div class="orchestra-shell">
        <div
          ref=${e}
          class="orchestra-canvas-wrap"
          onWheel=${M}
          onPointerDown=${I}
          onPointerMove=${F}
          onPointerUp=${B}
          onPointerCancel=${B}
          onPointerLeave=${()=>B()}
        >
          <svg
            class=${`orchestra-canvas ${Po.value?"is-dragging":""}`}
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
            <g transform=${`translate(${y.panX} ${y.panY}) scale(${y.zoom})`}>
              <${dh} edges=${t.edges} positions=${c} selectedId=${h} />
              <${ch} signalNodes=${_} roomPoint=${p} onSelect=${R=>{Ie.value=R}} />
              <${uh}
                orchestra=${t}
                positions=${c}
                density=${l}
                selectedId=${h}
                onSelect=${R=>{Ie.value=R}}
              />
            </g>
          </svg>
          <div class="orchestra-summary-strip">
            <span class="command-chip">세션 ${((et=t.summary)==null?void 0:et.session_count)??0}</span>
            <span class="command-chip">워커 ${((Z=t.summary)==null?void 0:Z.worker_count)??0}</span>
            <span class="command-chip">키퍼 ${((tt=t.summary)==null?void 0:tt.keeper_count)??0}</span>
            <span class="command-chip ${z(t.signals.some(R=>R.tone==="bad")?"bad":t.signals.length>0?"warn":"ok")}">
              신호 ${((G=t.summary)==null?void 0:G.signal_count)??t.signals.length}
            </span>
            <span class="command-chip">갱신 ${Q(t.generated_at)}</span>
          </div>
        </div>

        <${ph} orchestra=${t} />
      </div>
    </section>
  `}const su="masc_dashboard_agent_name";function _h(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(su))==null?void 0:s.trim())||"dashboard"}const mo=g(_h()),vn=g(""),Ua=g("운영 점검"),fn=g(""),is=g(""),rs=g("2"),yn=g(""),Ct=g("note"),ls=g(""),cs=g(""),ds=g(""),us=g("2"),ps=g(""),Ha=g("운영자 중지 요청"),Li=g(""),vh=g(""),Us=g(null);function fh(t){const e=t.trim()||"dashboard";mo.value=e,localStorage.setItem(su,e)}function Wa(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function kr(t){switch((t??"").trim().toLowerCase()){case"judgment":return"상주 판단";case"fallback":return"보조 읽기 모델";default:return(t==null?void 0:t.trim())||"안내"}}function Ga(t){switch((t??"").trim().toLowerCase()){case"judgment":return"ok";case"fallback":return"warn";default:return"warn"}}function _o(t){return t!=null&&t.enabled?t.refreshing?"갱신 중":t.judge_online?"온라인":t.last_error?"오류":"대기":"꺼짐"}function au(t){return t!=null&&t.enabled?t.judge_online?"ok":t.refreshing?"warn":"bad":"warn"}function xr(t){return t!=null&&t.fresh_until?t.fresh_until:"갱신 기준 없음"}function Kl(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function bn(t){return typeof t=="string"?t.trim().toLowerCase():""}function gh(t){var s;const e=bn(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=bn((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function zo(t){const e=bn(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function Bl(t){return t.some(e=>bn(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function $h(t){return t.target_type==="team_session"}function hh(t){return t.target_type==="keeper"}function qe(t){switch(t){case"broadcast":return"방송";case"room_pause":return"방 일시정지";case"room_resume":return"방 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"team_worker_spawn_batch":return"세션 작업자 교체";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"키퍼 메시지";case"keeper_msg":return"키퍼 메시지";case"swarm_run_continue":return"스웜 실행 계속";case"swarm_run_rerun":return"스웜 실행 재실행";case"swarm_run_abandon":return"스웜 실행 포기";default:return(t==null?void 0:t.trim())||"액션"}}function gn(t){switch(t){case"room":return"방";case"team_session":return"세션";case"keeper":return"키퍼";case"swarm_run":return"스웜 실행";default:return(t==null?void 0:t.trim())||"대상"}}function sn(t){switch(bn(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Ja(t){return t?"확인 후 실행":"즉시 실행"}function yh(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"worker_spawn_batch":return"작업자 교체";default:return t}}function ft(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function bh(t){return!t||typeof t!="object"||Array.isArray(t)?null:t}function kh(t){if(!t)return"";const e=t.spawn_batch;return Wa(e!==void 0?e:t)}function ou(t){const e=bh(t.payload);if(t.target_type==="room"){if(t.action_type==="broadcast"){vn.value=ft(e,"message")??t.summary;return}if(t.action_type==="task_inject"){fn.value=ft(e,"title")??"운영자 주입 작업",is.value=ft(e,"description")??t.summary,rs.value=ft(e,"priority")??rs.value;return}t.action_type==="room_pause"&&(Ua.value=ft(e,"reason")??t.summary);return}if(t.target_type==="team_session"){if(t.target_id&&(yn.value=t.target_id),t.action_type==="team_stop"){Ha.value=ft(e,"reason")??t.summary;return}Ct.value=t.action_type==="team_worker_spawn_batch"?"worker_spawn_batch":t.action_type==="team_task_inject"?"task":t.action_type==="team_broadcast"?"broadcast":"note";const n=ft(e,"message");if(n&&(ls.value=n),Ct.value==="worker_spawn_batch"){ps.value=kh(e);return}Ct.value==="task"&&(cs.value=ft(e,"task_title")??ft(e,"title")??"운영자 주입 작업",ds.value=ft(e,"task_description")??ft(e,"description")??t.summary,us.value=ft(e,"task_priority")??ft(e,"priority")??us.value);return}t.target_type==="keeper"&&(t.target_id&&(Li.value=t.target_id),vh.value=ft(e,"message")??t.summary)}function xh(t){ou({action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.suggested_payload,summary:t.summary})}function Sh(t){ou({action_type:t.action_type,target_type:t.target_type,target_id:t.target_id??null,payload:t.suggested_payload,summary:t.reason}),j("추천 액션 payload를 폼에 채웠습니다","success")}function Ch(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function Ke(t){const e=mo.value.trim()||"dashboard";try{const n=await nd({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?j("확인 대기열에 올렸습니다","warning"):j(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return j(s,"error"),null}}async function Ul(){const t=vn.value.trim();if(!t)return;await Ke({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(vn.value="")}async function Ah(){await Ke({action_type:"room_pause",target_type:"room",payload:{reason:Ua.value.trim()||"운영 점검"},successMessage:"방 일시정지를 요청했습니다"})}async function iu(){await Ke({action_type:"room_resume",target_type:"room",payload:{},successMessage:"방 재개를 요청했습니다"})}async function Th(){const t=fn.value.trim();if(!t)return;await Ke({action_type:"task_inject",target_type:"room",payload:{title:t,description:is.value.trim()||"개입 화면에서 주입",priority:Number.parseInt(rs.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(fn.value="",is.value="")}async function Ih(){var l;const t=Tt.value,e=yn.value||((l=t==null?void 0:t.sessions[0])==null?void 0:l.session_id)||"";if(!e){j("먼저 세션을 고르세요","warning");return}const n={};if(Ct.value==="worker_spawn_batch"){const c=ps.value.trim();if(!c){j("spawn_batch JSON을 먼저 채우세요","warning");return}try{const p=JSON.parse(c);if(Array.isArray(p))n.spawn_batch=p;else if(p&&typeof p=="object"&&Array.isArray(p.spawn_batch))n.spawn_batch=p.spawn_batch;else{j("spawn_batch는 배열 또는 { spawn_batch: [...] } 형태여야 합니다","warning");return}}catch(p){const _=p instanceof Error?p.message:"spawn_batch JSON 파싱에 실패했습니다";j(_,"error");return}await Ke({action_type:"team_worker_spawn_batch",target_type:"team_session",target_id:e,payload:n,successMessage:"작업자 교체 요청을 적용했습니다"})&&(ps.value="");return}const s=ls.value.trim();s&&(n.message=s);let a="team_note";Ct.value==="broadcast"?a="team_broadcast":Ct.value==="task"&&(a="team_task_inject"),Ct.value==="task"&&(n.task_title=cs.value.trim()||"운영자 주입 작업",n.task_description=ds.value.trim()||"개입 화면에서 주입",n.task_priority=Number.parseInt(us.value,10)||2),await Ke({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(ls.value="",Ct.value==="task"&&(cs.value="",ds.value=""))}async function Rh(){var n;const t=Tt.value,e=yn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){j("먼저 세션을 고르세요","warning");return}await Ke({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Ha.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Hl(t,e="confirm"){const n=mo.value.trim()||"dashboard";try{await sd(n,t,e),j(e==="deny"?"승인 대기를 거부했습니다":"확인 실행을 완료했습니다","success")}catch(s){const a=s instanceof Error?s.message:e==="deny"?"승인 대기 거부에 실패했습니다":"확인 실행에 실패했습니다";j(a,"error")}}function ru(t){switch(t){case"explicit":return"실제 관리 단위";case"hybrid":return"관리 단위 + 자동 보강";case"auto":return"자동 투영";default:return"출처 미상"}}function lu(t){switch(t){case"explicit":return"ok";case"hybrid":return"warn";case"auto":return"warn";default:return"warn"}}function Lh(t){switch(t){case"explicit":return"지금 보이는 유닛은 실제로 정의된 지휘면 관리 단위입니다.";case"hybrid":return"일부는 실제 관리 단위이고, 비어 있는 부분은 실시간 에이전트 편성을 보고 자동 보강한 구조입니다.";case"auto":return"이 화면은 실시간 에이전트 편성을 지휘면 모양으로 자동 투영한 것입니다. 실제 명령 체계와 1:1로 같다고 보면 안 됩니다.";default:return"이 화면은 관리 토폴로지와 실효 토폴로지가 섞여 있을 수 있습니다."}}function Mh(t){const e=t.unit.source??"unknown";return e==="explicit"?t.active_operation_count&&t.active_operation_count>0?"실제 관리 단위이며 연결된 작전이 있습니다.":"실제 관리 단위이지만 현재 연결된 작전은 없습니다.":e==="hybrid"?t.active_operation_count&&t.active_operation_count>0?"관리 단위를 기반으로 자동 보강된 구조이며 일부 작전이 연결돼 있습니다.":"관리 단위를 기반으로 자동 보강된 구조이며 현재 실행 연결은 약합니다.":t.active_operation_count&&t.active_operation_count>0?"자동 생성된 구조이지만 이 노드에 연결된 작전 흔적은 있습니다.":"자동 생성된 구조이며 현재 실행 연결은 없습니다."}function cu({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,i=t.unit.policy,l=t.unit.source??"unknown",c=a>0?`${a}개 작전 연결`:"실행 연결 없음";return o`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${v$(t.unit.kind)}</span>
            <span class="command-chip ${z(t.health)}">${t.health??"ok"}</span>
            <span class="command-chip ${lu(l)}">${ru(l)}</span>
            <span class="command-chip ${a>0?"ok":"warn"}">${c}</span>
            ${i!=null&&i.frozen?o`<span class="command-chip warn">동결됨</span>`:null}
            ${i!=null&&i.kill_switch?o`<span class="command-chip bad">킬 스위치</span>`:null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${t.unit.unit_id}</span>
            <span>리더 ${t.unit.leader_id??"미지정"} / ${t.leader_status??"확인 필요"}</span>
            <span>편성 ${n}/${s}</span>
            <span>작전 ${a}</span>
            <span>자율성 ${(i==null?void 0:i.autonomy_level)??"정보 없음"}</span>
          </div>
          <div class="command-card-sub">${Mh(t)}</div>
          ${t.reasons&&t.reasons.length>0?o`<div class="command-tag-row">
                ${t.reasons.map(d=>o`<span class="command-tag warn">${d}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?o`<div class="command-tree-children">
            ${t.children.map(d=>o`<${cu} node=${d} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function Ph({alert:t}){return o`
    <article class="command-alert ${z(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${z(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"범위"}:${t.scope_id??"정보 없음"}</span>
        <span>${Q(t.timestamp)}</span>
      </div>
      ${t.detail?o`<p>${t.detail}</p>`:null}
    </article>
  `}function Sr({event:t}){return o`
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
      <pre class="command-trace-detail">${os(t.detail)}</pre>
    </article>
  `}function zh(){const t=Vt.value,e=t==null?void 0:t.topology,n=e==null?void 0:e.source,s=e==null?void 0:e.summary,a=(s==null?void 0:s.managed_unit_count)??0,i=(s==null?void 0:s.active_operation_count)??0;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${O} panelId="command.topology" compact=${!0} />
      </div>
      ${t?o`
            <div class="command-topology-explainer">
              <div class="command-tree-title-row">
                <span class="command-chip ${lu(n)}">${ru(n)}</span>
                <span class="command-chip">관리 유닛 ${a}</span>
                <span class="command-chip ${i>0?"ok":"warn"}">활성 작전 ${i}</span>
              </div>
              <p>${Lh(n)}</p>
            </div>
          `:null}
      ${t&&t.topology.units.length>0?o`${t.topology.units.map(l=>o`<${cu} node=${l} />`)}`:o`<div class="empty-state">지금은 실시간 에이전트나 관리 유닛 기준으로 그릴 지휘 계층이 없습니다.</div>`}
    </section>
  `}function Eh(){const t=Vt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${O} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>o`<${Ph} alert=${e} />`)}
          </div>`:o`<div class="empty-state">지금 올라온 지휘면 경보는 없습니다.</div>`}
    </section>
  `}function jh(){const t=Vt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${O} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?o`<div class="command-trace-stack">
            ${t.traces.events.map(e=>o`<${Sr} event=${e} />`)}
          </div>`:o`<div class="empty-state">최근 트레이스 이벤트가 없습니다.</div>`}
    </section>
  `}function wh(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t,null,2)}catch{return String(t)}}function Nh(t,e){return(e==null?void 0:e.status)==="abandoned"||(t==null?void 0:t.recommended_kind)==="continue"?"warn":(t==null?void 0:t.recommended_kind)==="rerun"?"bad":"ok"}function Dh(t){switch(t){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(t==null?void 0:t.trim())||"결정"}}function du({swarm:t}){var v,f;const e=t.run_id,n=t.resolution_recommendation,s=t.run_resolution;if(!e||!n&&!s)return null;const a=Vd()??"dashboard",i=((v=Tt.value)==null?void 0:v.pending_confirms.find(h=>h.target_type==="swarm_run"&&h.target_id===e))??null,l=Nh(n,s),c=((f=t.operation)==null?void 0:f.operation_id)??t.operation_id??void 0,d={run_id:e};c&&(d.operation_id=c),n!=null&&n.reason&&(d.reason=n.reason);const p=async h=>{await nd({actor:a,action_type:h,target_type:"swarm_run",target_id:e,payload:d})},_=async h=>{i&&await sd(a,i.confirm_token,h)};return o`
    <article class="command-guide-card ${z(l)}">
      <div class="command-guide-head">
        <strong>Run Resolution</strong>
        <span class="command-chip ${z(l)}">
          ${Dh((s==null?void 0:s.status)??(n==null?void 0:n.recommended_kind)??null)}
        </span>
      </div>
      <p>
        ${(s==null?void 0:s.status)==="abandoned"?`이 run은 ${s.decided_by}가 ${Q(s.decided_at)}에 soft abandon 처리했습니다. ${s.reason}`:(n==null?void 0:n.reason)??"이 run에 대한 별도 resolution recommendation은 아직 없습니다."}
      </p>
      <div class="command-card-grid">
        <span>Run</span><span>${e}</span>
        <span>Provenance</span><span><${we} item=${{kind:(n==null?void 0:n.provenance)??"recorded"}} /></span>
        <span>Engine</span><span>${(n==null?void 0:n.decision_engine)??"operator_record"}</span>
        <span>Authoritative</span><span>${n!=null&&n.authoritative?"yes":"no"}</span>
      </div>
      ${n!=null&&n.evidence?o`
            <div class="command-tag-row">
              <span class="command-tag">joined ${n.evidence.joined_workers??0}</span>
              <span class="command-tag">trace ${n.evidence.trace_events??0}</span>
              <span class="command-tag">message ${n.evidence.message_events??0}</span>
              ${n.evidence.runtime_blocker?o`<span class="command-tag ${z("bad")}">${n.evidence.runtime_blocker}</span>`:null}
            </div>
          `:null}
      ${i?o`
            <div class="command-guide-card warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip warn">${i.confirm_token}</span>
              </div>
              ${i.preview?o`<pre class="command-trace-detail">${wh(i.preview)}</pre>`:null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${()=>{_("confirm")}} disabled=${ot.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${()=>{_("deny")}} disabled=${ot.value}>취소</button>
              </div>
            </div>
          `:n?o`
              <div class="command-action-row">
                ${n.continue_available?o`<button class="control-btn ghost" onClick=${()=>{p("swarm_run_continue")}} disabled=${ot.value}>Continue</button>`:null}
                ${n.rerun_available?o`<button class="control-btn" onClick=${()=>{p("swarm_run_rerun")}} disabled=${ot.value}>Rerun</button>`:null}
                ${n.abandon_available?o`<button class="control-btn ghost" onClick=${()=>{p("swarm_run_abandon")}} disabled=${ot.value}>Abandon</button>`:null}
              </div>
            `:null}
    </article>
  `}function uu(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function pu({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const i=a.motion_state;i in e?e[i]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return o`
    <div>
      <div class="swarm-health-bar">
        ${s.filter(a=>a.count>0).map(a=>o`
          <div class="swarm-health-seg ${a.key}" style="flex: ${a.count}"></div>
        `)}
      </div>
      <div class="swarm-health-labels">
        ${s.filter(a=>a.count>0).map(a=>o`
          <span class="swarm-health-label">
            <span class="swarm-health-swatch" style="background: ${a.color}"></span>
            ${a.count} ${a.key}
          </span>
        `)}
      </div>
    </div>
  `}function Oh({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return o`
    <div class="swarm-worker-grid">
      ${a.map(()=>o`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?o`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function qh({lane:t}){const e=t.counts??{},n=uu(t),s=e.workers??0,a=e.operations??0,i=e.detachments??0,l=a+i,c=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return o`
    <article class="swarm-lane-strip ${z(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${z(n)}">${t.phase}</span>
          <span class="command-chip ${z(n)}">${t.motion_state}</span>
          <span class="command-chip">${Q(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${z(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?o`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${Oh} total=${s} />
              </div>
            `:null}
        ${l>0?o`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">흐름</span>
                <div class="swarm-mini-bar">
                  <div class="swarm-mini-bar-fill" style="width: ${l>0?Math.round(a/l*100):0}%; background: var(--${n==="bad"?"bad":n==="warn"?"warn":"ok"})"></div>
                </div>
                <span class="swarm-worker-count">작전 ${a} · 실행체 ${i}</span>
              </div>
            `:null}
      </div>
      ${t.blockers.length>0?o`<div class="swarm-lane-blockers">막힘: ${t.blockers.join(" · ")}</div>`:null}
      ${t.hard_flags.length>0?o`
            <div class="swarm-lane-flags">
              ${t.hard_flags.map(d=>o`<span class="command-chip ${z(d.severity)}">${d.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function mu({lanes:t}){const e=t.slice(0,4);return e.length===0?null:o`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=uu(n),a=n.counts.workers??0,i=n.counts.operations??0,l=n.counts.detachments??0;return o`
          <article class="swarm-story-card ${z(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${z(s)}">${n.motion_state}</span>
              <span class="command-chip">${n.phase}</span>
            </div>
            <strong>${n.label}</strong>
            <p>${n.current_step}</p>
            <div class="swarm-story-strip">
              <span>워커 ${a}</span>
              <span>작전 ${i}</span>
              <span>실행체 ${l}</span>
            </div>
            <small>${n.movement_reason}</small>
          </article>
        `})}
    </div>
  `}function Fh({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return o`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${z(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?o`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function Kh({gap:t}){return o`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${z(t.severity)}">${t.code} (${t.count})</span>
      <span class="command-card-sub">${t.summary}</span>
    </div>
  `}function Bh({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return o`
    <div class="command-guide-card ${z(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${z(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?o`
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${Q(t.captured_at)}</span>
              <span>통과</span><span>${t.pass==null?"n/a":t.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${t.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${t.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${t.workers.expected??"n/a"} 예상 · ${t.workers.done??"n/a"} 완료 · ${t.workers.final??"n/a"} 최종</span>
            </div>
            ${t.artifact_ref?o`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?o`<p>${t.missing_reason}</p>`:null}
          `:o`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function Uh(){const t=Ms(),e=As(D.value),n=$$(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,i=(s==null?void 0:s.lanes.filter(v=>v.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],d=s==null?void 0:s.overview,p=s==null?void 0:s.recommended_next_action,_=i.length<=1;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${O} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?o`
            <${mu} lanes=${i} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(d==null?void 0:d.active_lanes)??0}</strong><small>${(d==null?void 0:d.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(d==null?void 0:d.stalled_lanes)??0}</strong><small>${(d==null?void 0:d.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${Q(d==null?void 0:d.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${Q(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(p==null?void 0:p.label)??"운영자 상태 확인"}</strong><small>${(p==null?void 0:p.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${i.length>0?o`<${pu} lanes=${i} />`:null}

            <div class="command-swarm-layout ${_?"compact":""}">
              <div class="command-card-stack">
                ${i.length>0?i.map(v=>o`<${qh} lane=${v} />`):o`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${Bh} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${z(l.some(v=>v.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?o`<div class="swarm-event-rail">${l.slice(0,4).map(v=>o`<${Kh} gap=${v} />`)}</div>`:o`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?o`<div class="swarm-event-rail">${c.map(v=>o`<${Fh} event=${v} />`)}</div>`:o`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:o`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Hh({item:t}){return o`
    <article class="command-guide-card ${z(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${z(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function _u({blocker:t}){return o`
    <article class="command-alert ${z(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${z(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function Wh({worker:t}){return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${z(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${t.last_message?o`<div class="command-card-foot">${Q(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function Gh(){var d,p,_,v,f,h,T,k,C,$,y,x,M,I,F,B,et,Z,tt,G,R;const t=Ue.value,e=Xd(),n=$r(),s=(d=t==null?void 0:t.provider)!=null&&d.runtime_blocker?"blocked":(p=t==null?void 0:t.provider)!=null&&p.provider_reachable?"ready":"check",a=((_=t==null?void 0:t.provider)==null?void 0:_.actual_slots)??((v=t==null?void 0:t.provider)==null?void 0:v.total_slots)??0,i=((f=t==null?void 0:t.provider)==null?void 0:f.expected_slots)??"n/a",l=((h=t==null?void 0:t.provider)==null?void 0:h.actual_ctx)??((T=t==null?void 0:t.provider)==null?void 0:T.ctx_per_slot)??0,c=((k=t==null?void 0:t.provider)==null?void 0:k.expected_ctx)??"n/a";return o`
    <div class="command-section-stack">
      <${Uh} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${ja.value?o`<div class="empty-state">Loading swarm live state…</div>`:wa.value?o`<div class="empty-state error">${wa.value}</div>`:t?o`
                    <div class="command-tag-row">
                      <span class="command-tag">experimental</span>
                      <${we} item=${{kind:"derived",label:"derived read-model"}} />
                      <span class="command-tag ${t.run_resolution||t.resolution_recommendation?"warn":"ok"}">
                        ${t.run_resolution||t.resolution_recommendation?"operator resolution aware":"no resolution advice"}
                      </span>
                    </div>
                    <div class="command-card-sub">
                      이 화면은 swarm-live의 사회 truth 자체가 아니라, 실험적 오케스트레이션을 읽기 위한 파생 관찰면입니다.
                    </div>
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((C=t.summary)==null?void 0:C.joined_workers)??0}/${(($=t.summary)==null?void 0:$.expected_workers)??0}</strong><small>${((y=t.summary)==null?void 0:y.live_workers)??0}개 가동 · ${((x=t.summary)==null?void 0:x.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${i} · ctx ${l}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(M=t.summary)!=null&&M.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((I=t.provider)==null?void 0:I.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(F=t.summary)!=null&&F.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((B=t.operation)==null?void 0:B.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((et=t.squad)==null?void 0:et.label)??"없음"}</span>
                      <span>실행체</span><span>${((Z=t.detachment)==null?void 0:Z.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((tt=t.summary)==null?void 0:tt.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((G=t.summary)==null?void 0:G.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((R=t.provider)==null?void 0:R.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?o`<div class="command-tag-row">
                          ${t.truth_notes.map(S=>o`<span class="command-tag">${S}</span>`)}
                        </div>`:null}
                    <${du} swarm=${t} />
                  `:o`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?o`<div class="command-card-stack">
                ${t.checklist.map(S=>o`<${Hh} item=${S} />`)}
              </div>`:o`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?o`<div class="command-card-stack">
                ${t.workers.map(S=>o`<${Wh} worker=${S} />`)}
              </div>`:o`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${t!=null&&t.provider?o`
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
                ${t.provider.detail?o`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?o`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(S=>o`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${S.active_slots} active</strong>
                              <span class="command-chip">${Q(S.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${S.active_slot_ids.join(", ")||"none"}</div>
                          </div>
                        </article>
                      `)}
                    </div>`:o`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:o`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?o`<div class="command-card-stack">
                ${t.blockers.map(S=>o`<${_u} blocker=${S} />`)}
              </div>`:o`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?o`<div class="command-trace-stack">
                ${t.recent_messages.map(S=>o`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${S.from}</strong>
                        <span class="command-chip">${Q(S.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${S.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${S.content}</pre>
                  </article>
                `)}
              </div>`:o`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${O} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?o`<div class="command-trace-stack">
                ${t.recent_trace_events.map(S=>o`<${Sr} event=${S} />`)}
              </div>`:o`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function Xt(t,e=260){return t.length<=e?t:`${t.slice(0,e-1)}…`}function an(t){if(!t)return 0;const e=Date.parse(t);return Number.isNaN(e)?0:e}function Jh(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function Vh(t){const e=typeof t.timestamp=="string"?t.timestamp:typeof t.created_at=="string"?t.created_at:typeof t.at=="string"?t.at:null,n=typeof t.title=="string"?t.title:typeof t.kind=="string"?t.kind:typeof t.event=="string"?t.event:"세션 이벤트",s=typeof t.detail=="string"?t.detail:typeof t.summary=="string"?t.summary:os(t);return{timestamp:e,title:n,detail:Xt(s,220)}}function Yh(t){return t==="swarm"?"스웜 실시간":"세션 요약"}function Xh(t){switch(t){case"current":return"현재 과업 일치";case"drift":return"과업 드리프트";case"claim":return"착수 흔적 있음";case"no-claim":return"착수 흔적 없음";case"done":return"완료 흔적 있음";case"no-done":return"완료 흔적 없음";case"final":return"최종 보고 있음";case"no-final":return"최종 보고 없음";case"turn":return"턴 기록 있음";case"silent":return"턴 기록 없음";case"noted":return"노트 기록 있음";default:return t.startsWith("empty:")?`빈 노트 ${t.slice(6)}회`:t.startsWith("turns:")?`턴 ${t.slice(6)}회`:t}}function Qh(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"할당 없음",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}초`:t.heartbeat_fresh?"정상":"정보 없음",detail:[t.bound_task_status??null,t.detachment_member?"분견대 소속":null,t.squad_member?"분대 소속":null].filter(Boolean).join(" · ")||"스웜 실시간 카드",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function Zh(t,e){const n=t.actor??t.spawn_role??`워커-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"워커",a=t.lane_id??t.capsule_mode??t.control_domain??"세션",i=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"세션 레인",heartbeat:t.last_turn_ts_iso?Q(t.last_turn_ts_iso):"정보 없음",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?Tn(t.routing_confidence):null].filter(Boolean).join(" · ")||"세션 요약 카드",markers:i,note:t.routing_reason??null}}function ty(t){var e;return{key:`agent:${t.name}`,name:t.name,role:t.agent_type??"agent",source:"agent",status:Ft(t.status),tone:z(de(t.status)),task:t.current_task??"대기 중",signal:Q(t.last_seen),detail:[t.model??null,((e=t.capabilities)==null?void 0:e.slice(0,2).join(", "))||null].filter(Boolean).join(" · ")||"글로벌 agent roster",chips:[t.context_ratio!=null?`ctx ${Math.round(t.context_ratio*100)}%`:"ctx n/a",t.status],note:t.personalityHint??null}}function ey(t){var n,s,a;const e=t.status==="offline"||t.status==="inactive"?"bad":t.status==="active"||t.status==="healthy"?"ok":"warn";return{key:`keeper:${t.name}`,name:t.name,role:t.runtime_class??"keeper",source:"keeper",status:Ft(t.status),tone:e,task:((n=t.active_goal_ids)==null?void 0:n[0])??t.last_proactive_reason??((s=t.agent)==null?void 0:s.current_task)??"standby",signal:t.last_heartbeat?Q(t.last_heartbeat):Jh(t.last_turn_ago_s),detail:[t.autonomy_level??null,t.active_model??t.primary_model??t.model??null,t.keepalive_running?"keepalive on":null].filter(Boolean).join(" · ")||"글로벌 keeper roster",chips:[t.context_ratio!=null?`ctx ${Math.round(t.context_ratio*100)}%`:"ctx n/a",t.latest_tool_call_count!=null?`tools ${t.latest_tool_call_count}`:"tools n/a"],note:((a=t.diagnostic)==null?void 0:a.summary)??t.last_proactive_preview??t.recent_output_preview??null}}function ny(t){return{key:`resident:${t.keeper_name??"judge"}`,name:t.keeper_name??"resident-judge",role:"resident judge",source:"resident",status:_o(t),tone:au(t),task:t.judge_online?"live guidance":"standby",signal:t.generated_at?Q(t.generated_at):"정보 없음",detail:[t.model_used??null,t.last_error?"error":null].filter(Boolean).join(" · ")||"resident runtime",chips:[t.enabled?"enabled":"disabled",t.judge_online?"online":"offline"],note:t.last_error??null}}function sy(t){return z(t.severity)}function ay({swarmMessages:t,traceEvents:e,chainOverlay:n,linkedAutoresearch:s,selectedSession:a,activeRecommendedActions:i,attentionItems:l}){const c=[];for(const d of t.slice(0,8))c.push({key:`message:${d.seq}`,title:d.from,detail:Xt(d.content,280),meta:`메시지 · seq ${d.seq}`,source:"swarm",tone:"ok",timestamp:d.timestamp,sortTs:an(d.timestamp)});for(const d of e.slice(0,8))c.push({key:`trace:${d.event_id}`,title:d.event_type,detail:Xt(os(d.detail),280),meta:[d.actor??null,d.source??null].filter(Boolean).join(" · ")||"trace",source:"trace",tone:d.event_type.includes("error")||d.event_type.includes("fail")?"bad":"warn",timestamp:d.timestamp,sortTs:an(d.timestamp)});if(n!=null&&n.history&&c.push({key:`chain:${n.operation.operation_id}:${n.history.event}`,title:`Chain · ${n.history.event}`,detail:Xt(po(n.history),260),meta:n.history.chain_id??n.operation.operation_id,source:"chain",tone:n.history.event.includes("error")||n.history.event.includes("fail")?"bad":"warn",timestamp:n.history.timestamp,sortTs:an(n.history.timestamp)}),s){const d=[s.last_decision??null,s.target_file?`target ${s.target_file}`:null,s.error??null].filter(Boolean);c.push({key:`autoresearch:${s.loop_id??(a==null?void 0:a.session_id)??"session"}`,title:`Autoresearch · ${s.status??"unknown"}`,detail:Xt(d.join(" · ")||"linked autoresearch context",260),meta:[s.loop_id?`loop ${s.loop_id}`:null,s.current_cycle!=null?`cycle ${s.current_cycle}`:null,s.best_score!=null?`best ${s.best_score}`:null].filter(Boolean).join(" · ")||"linked autoresearch",source:"autoresearch",tone:s.error?"bad":s.status==="running"?"warn":"ok",timestamp:null,sortTs:0})}for(const d of i.slice(0,4))c.push({key:`recommendation:${d.action_type}:${d.target_type}:${d.target_id??"session"}`,title:`${d.action_type} · ${d.target_type}`,detail:Xt(d.reason,240),meta:d.target_id??"operator recommendation",source:"recommendation",tone:sy(d),timestamp:null,sortTs:0});for(const d of l.slice(0,4))c.push({key:`attention:${d.kind}:${d.target_id??"session"}`,title:`${d.kind} · ${d.target_type}`,detail:Xt(d.summary,240),meta:d.target_id??"attention",source:"attention",tone:z(d.severity),timestamp:null,sortTs:0});for(const[d,p]of((a==null?void 0:a.recent_events)??[]).slice(0,4).entries()){const _=Vh(p);c.push({key:`session:${(a==null?void 0:a.session_id)??"unknown"}:${d}`,title:_.title,detail:_.detail,meta:(a==null?void 0:a.session_id)??"session",source:"session",tone:"warn",timestamp:_.timestamp,sortTs:an(_.timestamp)})}return c.sort((d,p)=>p.sortTs-d.sortTs||d.title.localeCompare(p.title)).slice(0,14)}function oy({worker:t}){return o`
    <article class="command-card compact warroom-worker-card ${z(de(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${z(de(t.status))}">${Ft(t.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>출처</span><span>${Yh(t.source)}</span>
        <span>과업</span><span>${t.task}</span>
        <span>최근 신호</span><span>${t.heartbeat}</span>
        <span>근거</span><span>${t.detail}</span>
      </div>
      <div class="command-tag-row">
        ${t.markers.map(e=>o`<span class="command-tag">${Xh(e)}</span>`)}
      </div>
      ${t.note?o`<div class="command-card-foot">${Xt(t.note,220)}</div>`:null}
    </article>
  `}function Wl({item:t}){return o`
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
        ${t.chips.map(e=>o`<span class="command-tag">${e}</span>`)}
      </div>
      ${t.note?o`<div class="command-card-foot">${Xt(t.note,200)}</div>`:null}
    </article>
  `}function iy({item:t}){return o`
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
  `}function qt({label:t,surface:e,params:n={}}){return o`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){Bt(e),at("command",{...Ls(e),...n});return}at("intervene")}}
    >
      ${t}
    </button>
  `}function ry({chainOverlay:t,linkedAutoresearch:e}){var n,s,a,i;return!t&&!e?o`<div class="command-guide-card"><p>이 세션에 붙은 chain/autoresearch 오버레이가 아직 없습니다.</p></div>`:o`
    <div class="warroom-orchestration-grid">
      ${t?o`
            <article class="command-card warroom-orchestration-card">
              <div class="command-card-head">
                <div>
                  <strong>Chain Orchestration</strong>
                  <div class="command-card-sub">${t.operation.operation_id}</div>
                </div>
                <span class="command-chip ${z(de(t.operation.status))}">${Ft(t.operation.status)}</span>
              </div>
              <div class="command-card-grid">
                <span>Chain</span><span>${((n=t.runtime)==null?void 0:n.chain_id)??((s=t.preview_run)==null?void 0:s.chain_id)??"n/a"}</span>
                <span>Progress</span><span>${Tn((a=t.runtime)==null?void 0:a.progress)}</span>
                <span>Elapsed</span><span>${en((i=t.runtime)==null?void 0:i.elapsed_sec)}</span>
                <span>최근 이벤트</span><span>${po(t.history)}</span>
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
      ${e?o`
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
                ${e.operation_id?o`<${qt}
                      label="작전 상세"
                      surface="operations"
                      params=${{operation_id:e.operation_id}}
                    />`:null}
              </div>
            </article>
          `:null}
    </div>
  `}function ly({wallboard:t=!1}){var Mr,Pr,zr,Er,jr,wr,Nr,Dr,Or,qr,Fr,Kr,Br,Ur,Hr,Wr,Gr,Jr,Vr,Yr,Xr,Qr,Zr,tl,el,nl,sl,al,ol,il,rl,ll;const e=Ms(),n=Ue.value,s=Tt.value,a=Wt.value,i=C$(),l=n!=null&&n.operation?((Mr=Cs.value)==null?void 0:Mr.operations.find(q=>{var Se;return q.operation.operation_id===((Se=n.operation)==null?void 0:Se.operation_id)}))??null:null,c=(i==null?void 0:i.linked_autoresearch)??null,d=x$(),p=(n==null?void 0:n.workers)??[],_=(a==null?void 0:a.worker_cards)??[],v=d&&p.length>0?p.map(Qh):_.map(Zh),f=Jt.value.filter(q=>q.status==="active"||q.status==="busy"||q.status==="listening"||q.status==="idle"),h=ae.value.filter(q=>q.status!=="offline"||q.keepalive_running||q.last_heartbeat).sort((q,Se)=>an(Se.last_heartbeat)-an(q.last_heartbeat)),T=d,k=((Pr=e==null?void 0:e.decisions.summary)==null?void 0:Pr.pending)??0,C=hs(s),$=C.items,y=C.total_count,x=C.visible_count,M=C.hidden_count,I=d?(n==null?void 0:n.blockers)??[]:[],F=(a==null?void 0:a.recommended_actions)??[],B=(zr=a==null?void 0:a.active_recommended_actions)!=null&&zr.length?a.active_recommended_actions:F,et=a==null?void 0:a.active_summary,Z=(a==null?void 0:a.active_guidance_layer)??"fallback",tt=(a==null?void 0:a.resident_judge_runtime)??(s==null?void 0:s.resident_judge_runtime),G=(a==null?void 0:a.attention_items)??[],R=((Er=n==null?void 0:n.recent_messages[0])==null?void 0:Er.timestamp)??null,S=((jr=n==null?void 0:n.recent_trace_events[0])==null?void 0:jr.timestamp)??null,P=d?R??S??null:null,J=i==null?void 0:i.summary,yt=(d?(wr=n==null?void 0:n.summary)==null?void 0:wr.expected_workers:void 0)??(typeof(J==null?void 0:J.planned_worker_count)=="number"?J.planned_worker_count:void 0)??(a==null?void 0:a.worker_cards.length)??0,oe=(d?(Nr=n==null?void 0:n.summary)==null?void 0:Nr.joined_workers:void 0)??(typeof(J==null?void 0:J.active_agent_count)=="number"?J.active_agent_count:void 0)??v.length,U=I.length>0||k>0||y>0?"warn":T||i?"ok":"warn",vt=d?((Dr=e==null?void 0:e.swarm_status)==null?void 0:Dr.lanes.filter(q=>q.present))??[]:[],xe=((qr=(Or=e==null?void 0:e.swarm_status)==null?void 0:Or.narrative)==null?void 0:qr.lane_id)??((Kr=(Fr=e==null?void 0:e.swarm_status)==null?void 0:Fr.recommended_next_action)==null?void 0:Kr.lane_id)??((Br=vt[0])==null?void 0:Br.lane_id)??null,rt=xe?vt.find(q=>q.lane_id===xe)??null:vt[0]??null,In=[...tt?[ny(tt)]:[],...f.slice(0,t?8:5).map(ty),...h.slice(0,t?8:5).map(ey)],Ps=In.filter(q=>q.source==="agent"),zs=In.filter(q=>q.source==="keeper"||q.source==="resident"),Es=ay({swarmMessages:(n==null?void 0:n.recent_messages)??[],traceEvents:(n==null?void 0:n.recent_trace_events)??[],chainOverlay:l,linkedAutoresearch:c,selectedSession:i,activeRecommendedActions:B,attentionItems:G}),go=((Ur=n==null?void 0:n.operation)==null?void 0:Ur.objective)??((Wr=(Hr=e==null?void 0:e.swarm_status)==null?void 0:Hr.narrative)==null?void 0:Wr.active_work)??(i==null?void 0:i.session_id)??"가동 중인 워룸",$o=[(et==null?void 0:et.summary)??null,((Jr=(Gr=e==null?void 0:e.swarm_status)==null?void 0:Gr.narrative)==null?void 0:Jr.state)??null,((Yr=(Vr=e==null?void 0:e.swarm_status)==null?void 0:Vr.narrative)==null?void 0:Yr.active_work)??null,rt?`${rt.label} · ${rt.current_step}`:null].filter(Boolean).join(" · ")||"실제 실행, 메시지, 트레이스, 상주 판단을 한 장에서 읽는 wallboard입니다.",[ho,yo]=$n(typeof document<"u"&&!!document.fullscreenElement);nt(()=>{mt()},[]),nt(()=>{i!=null&&i.session_id&&he(i.session_id)},[i==null?void 0:i.session_id,s,(Xr=n==null?void 0:n.detachment)==null?void 0:Xr.session_id]),nt(()=>{if(!t)return;const q=()=>{yo(!!document.fullscreenElement)};return document.addEventListener("fullscreenchange",q),q(),()=>{document.removeEventListener("fullscreenchange",q)}},[t]);const Mu=()=>{var q,Se,cl;if(!(typeof document>"u")){if(document.fullscreenElement){(q=document.exitFullscreen)==null||q.call(document);return}(cl=(Se=document.documentElement).requestFullscreen)==null||cl.call(Se)}},Pu=()=>{mt(),te(),Oe(),i!=null&&i.session_id&&he(i.session_id)};return!T&&!i?ja.value||Zn.value?o`<div class="empty-state">실시간 워룸 불러오는 중…</div>`:o`
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
          <${qt} label="작전 보기" surface="operations" />
          <${qt} label="스웜 보기" surface="swarm" />
          <${qt} label="체인 보기" surface="chains" />
          <${qt} label="개입 열기" />
        </div>
      </section>
    `:o`
    <div class="command-section-stack ${t?"wallboard":""}">
      <section class="command-warroom-strip ${z(U)} ${t?"wallboard":""}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">${t?"War Room Wallboard":"실시간 워룸"}</span>
            <strong>${go}</strong>
            <div class="command-card-sub">
              ${d?((Qr=n==null?void 0:n.operation)==null?void 0:Qr.operation_id)??"작전 정보 없음":"세션 기준값"}
              ${i!=null&&i.session_id?` · 세션 ${i.session_id}`:""}
              ${d&&((Zr=n==null?void 0:n.detachment)!=null&&Zr.detachment_id)?` · 분견대 ${n.detachment.detachment_id}`:""}
              ${rt?` · 대표 레인 ${rt.label}`:""}
            </div>
            <div class="command-warroom-summary">${$o}</div>
            ${et!=null&&et.summary?o`<div class="command-warroom-guidance ${Ga(Z)}">
                  <strong>${kr(Z)}</strong>
                  <span>${et.summary}</span>
                </div>`:null}
          </div>
          <div class="command-warroom-hero-actions">
            <button class="control-btn ghost" onClick=${Pu}>새로고침</button>
            ${t?o`
                  <button class="control-btn ghost" onClick=${Mu}>
                    ${ho?"전체 화면 해제":"전체 화면"}
                  </button>
                  <button
                    class="control-btn ghost"
                    onClick=${()=>{var q;document.fullscreenElement&&((q=document.exitFullscreen)==null||q.call(document)),Bt("warroom"),at("command",Ls("warroom"))}}
                  >
                    표준 보기
                  </button>
                `:null}
            <${qt}
              label="스웜 상세"
              surface="swarm"
              params=${{...d&&((tl=n==null?void 0:n.operation)!=null&&tl.operation_id)?{operation_id:n.operation.operation_id}:{},...d&&(n!=null&&n.run_id)?{run_id:n.run_id}:{}}}
            />
            ${l?o`<${qt}
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
            <small>${d?((el=n==null?void 0:n.summary)==null?void 0:el.completed_workers)??0:0} 완료 · ${v.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>런타임</span>
            <strong>${d?(nl=n==null?void 0:n.provider)!=null&&nl.runtime_blocker?"막힘":(sl=n==null?void 0:n.provider)!=null&&sl.provider_reachable?"준비됨":i?Ft(i.status):"확인 필요":i?Ft(i.status):"확인 필요"}</strong>
            <small>${d?`설정 ${((al=n==null?void 0:n.provider)==null?void 0:al.configured_capacity)??"n/a"} · 실제 ${((ol=n==null?void 0:n.provider)==null?void 0:ol.actual_slots)??((il=n==null?void 0:n.provider)==null?void 0:il.total_slots)??0} · hot ${((rl=n==null?void 0:n.summary)==null?void 0:rl.peak_hot_slots)??((ll=n==null?void 0:n.provider)==null?void 0:ll.peak_active_slots)??0}`:`세션 워커 ${(a==null?void 0:a.worker_cards.length)??0}`}</small>
          </div>
          <div class="monitor-stat-card ${z(I.length>0||k>0||y>0?"warn":"ok")}">
            <span>압력</span>
            <strong>${I.length+k+y}</strong>
            <small>막힘 ${I.length} · 승인 ${k} · 확인 ${x}${M>0?`/${y}`:""}</small>
          </div>
          <div class="monitor-stat-card ${z(Ga(Z))}">
            <span>상주 판정기</span>
            <strong>${_o(tt)}</strong>
            <small>${xr(et)}${tt!=null&&tt.model_used?` · ${tt.model_used}`:""}</small>
          </div>
          <div class="monitor-stat-card">
            <span>마지막 신호</span>
            <strong>${Q(P)}</strong>
            <small>${R?"메시지":S?"트레이스":"대기 중"}</small>
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
            ${vt.length>0?o`
                  <${mu} lanes=${vt} />
                  <${pu} lanes=${vt} />
                `:i?o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${i.session_id}</strong>
                        <span class="command-chip ${z(de(i.status))}">${Ft(i.status)}</span>
                      </div>
                      <p>스웜 실시간 증거는 아직 약합니다. 이 카드는 세션 요약과 워커 기록을 기준으로 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${i.progress_pct!=null?`${i.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${en(i.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${en(i.remaining_sec)}</span>
                      </div>
                    </article>
                  `:o`<div class="empty-state">보이는 레인이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">오케스트레이션</div>
              <${O} panelId="command.chains" compact=${!0} />
            </div>
            <${ry} chainOverlay=${l} linkedAutoresearch=${c} />
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">워커 현황</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${v.length>0?o`<div class="command-card-stack">
                  ${v.map(q=>o`<${oy} worker=${q} />`)}
                </div>`:o`<div class="empty-state">활성 워커 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">상황 피드</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${Es.length>0?o`<div class="command-trace-stack">
                  ${Es.map(q=>o`<${iy} item=${q} />`)}
                </div>`:o`<div class="empty-state">메시지, chain, autoresearch, attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">트레이스 흐름</div>
              <${O} panelId="command.trace" compact=${!0} />
            </div>
            ${n&&n.recent_trace_events.length>0?o`<div class="command-trace-stack">
                  ${n.recent_trace_events.map(q=>o`<${Sr} event=${q} />`)}
                </div>`:o`<div class="empty-state">실행 범위 트레이스 이벤트가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Agents</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${Ps.length>0?o`<div class="warroom-presence-grid">
                  ${Ps.map(q=>o`<${Wl} item=${q} />`)}
                </div>`:o`<div class="empty-state">가시적인 active agent가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Keepers</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${zs.length>0?o`<div class="warroom-presence-grid">
                  ${zs.map(q=>o`<${Wl} item=${q} />`)}
                </div>`:o`<div class="empty-state">가시적인 keeper/runtime 카드가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">압력</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${d&&n?o`<${du} swarm=${n} />`:null}
              ${I.length>0?I.map(q=>o`<${_u} blocker=${q} />`):o`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${k>0?o`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>승인 대기</strong>
                        <span class="command-chip warn">${k}</span>
                      </div>
                      <p>엄격 액션이 묶여 있습니다. 실제 승인 처리는 제어 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${y>0?o`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>확인 대기</strong>
                        <span class="command-chip warn">${M>0?`${x}/${y}`:y}</span>
                      </div>
                      <p>
                        운영자 미리보기가 사람 확인을 기다리고 있습니다.
                        ${M>0?` 현재 actor 기준으로는 ${x}건만 보입니다.`:""}
                      </p>
                      <div class="command-tag-row">
                        ${$.slice(0,3).map(q=>o`<span class="command-tag">${q.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
              ${rt?o`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${rt.label}</strong>
                          <div class="command-card-sub">${rt.kind} · ${rt.phase}</div>
                        </div>
                        <span class="command-chip ${z(de(rt.motion_state))}">${Ft(rt.motion_state)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>현재 단계</span><span>${rt.current_step}</span>
                        <span>이동 사유</span><span>${rt.movement_reason}</span>
                        <span>막힘 수</span><span>${rt.blockers.length}</span>
                        <span>최근 이동</span><span>${Q(rt.last_movement_at)}</span>
                      </div>
                    </article>
                  `:null}
              ${d&&(n!=null&&n.detachment)?o`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${n.detachment.detachment_id}</strong>
                          <div class="command-card-sub">${n.detachment.assigned_unit_id}</div>
                        </div>
                        <span class="command-chip ${z(de(n.detachment.status))}">${Ft(n.detachment.status??"active")}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>리더</span><span>${n.detachment.leader_id??"미지정"}</span>
                        <span>편성</span><span>${n.detachment.roster.length}</span>
                        <span>세션</span><span>${n.detachment.session_id??"연결 없음"}</span>
                        <span>하트비트</span><span>${Gd(n.detachment.heartbeat_deadline)}</span>
                      </div>
                    </article>
                  `:i?o`
                      <article class="command-card compact">
                        <div class="command-card-head">
                          <div>
                            <strong>${i.session_id}</strong>
                            <div class="command-card-sub">현재 세션 기준</div>
                          </div>
                          <span class="command-chip ${z(de(i.status))}">${Ft(i.status)}</span>
                        </div>
                        <div class="command-card-grid">
                          <span>진행률</span><span>${i.progress_pct!=null?`${i.progress_pct}%`:"정보 없음"}</span>
                          <span>경과</span><span>${en(i.elapsed_sec)}</span>
                          <span>남은 시간</span><span>${en(i.remaining_sec)}</span>
                          <span>완료 변화량</span><span>${i.done_delta_total??0}</span>
                        </div>
                      </article>
                    `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function Gl(t){switch((t??"").trim().toLowerCase()){case"active":return"가동 중";case"paused":return"일시정지";case"failed":return"실패";case"completed":case"done":return"완료";case"disconnected":return"끊김";case"preview":return"미리보기";case"captured":return"기록됨";default:return(t==null?void 0:t.trim())||"확인 필요"}}function cy({source:t}){const e=Dn(null),[n,s]=$n(null);return nt(()=>{let a=!1;const i=e.current;return i?(i.innerHTML="",s(null),(async()=>{try{const c=await r$(),{svg:d}=await c.render(`command-chain-${i$()}`,t);if(a||!e.current)return;e.current.innerHTML=d}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid 렌더링에 실패했습니다")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),o`
    <div class="command-chain-graph-shell">
      ${n?o`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function dy({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return o`
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
        ${s!=null&&s.chain_id?o`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?o`<span class="command-tag ${ve(s==null?void 0:s.status)}">${Tn(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${po(t.history)}</div>
    </button>
  `}function uy({item:t}){return o`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"알 수 없는 체인"}</strong>
        <span class="command-chip ${ve(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${Q(t.timestamp)}</div>
      <div class="command-card-sub">${po(t)}</div>
    </article>
  `}function py({node:t}){return o`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${ve(t.status)}">${t.status??"확인 필요"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"노드"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?o`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function my({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,i=e.chain,l=(i==null?void 0:i.run_id)??null;return o`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${z(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${Gl(e.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>트레이스</span><span class="mono">${e.trace_id}</span>
        <span>자율성</span><span>${e.autonomy_level??"정보 없음"}</span>
        <span>예산 등급</span><span>${e.budget_class??"standard"}</span>
        <span>출처</span><span>${e.source??"managed"}</span>
        <span>최근 갱신</span><span>${Q(e.updated_at)}</span>
      </div>
      ${i?o`
            <div class="command-tag-row">
              <span class="command-tag">${i.kind}</span>
              <span class="command-tag ${ve(i.status)}">${Gl(i.status)}</span>
              ${i.chain_id?o`<span class="command-tag">${i.chain_id}</span>`:null}
              ${i.run_id?o`<span class="command-tag">실행 ${i.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?o`<div class="command-card-foot">체크포인트 ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Bt("swarm"),at("command",{surface:"swarm",operation_id:e.operation_id,...l?{run_id:l}:{}})}}
        >
          스웜 실시간 보기
        </button>
        ${i?o`
              <button
                class="control-btn ghost"
                onClick=${()=>{cr(e.operation_id),Bt("chains"),at("command",{surface:"chains",operation:e.operation_id})}}
              >
                체인 열기
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?o`
              <button class="control-btn ghost" disabled=${dt(n)} onClick=${()=>fe(()=>yf(e.operation_id))}>
                ${dt(n)?"일시정지 중…":"일시정지"}
              </button>
              <button class="control-btn ghost" disabled=${dt(a)} onClick=${()=>fe(()=>kf(e.operation_id))}>
                ${dt(a)?"회수 중…":"회수"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?o`
              <button class="control-btn ghost" disabled=${dt(s)} onClick=${()=>fe(()=>bf(e.operation_id))}>
                ${dt(s)?"재개 중…":"재개"}
              </button>
            `:null}
      </div>
    </article>
  `}function _y({card:t}){var n;const e=t.detachment;return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${z(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>리더</span><span>${e.leader_id??"미지정"}</span>
        <span>편성</span><span>${e.roster.length}</span>
        <span>세션</span><span>${e.session_id??"연결 없음"}</span>
        <span>런타임</span><span>${e.runtime_kind??"managed"}</span>
        <span>런타임 참조</span><span>${e.runtime_ref??"정보 없음"}</span>
        <span>진행 흔적</span><span>${Q(e.last_progress_at)}</span>
        <span>하트비트</span><span>${Gd(e.heartbeat_deadline)}</span>
        <span>최근 갱신</span><span>${Q(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?o`<span class="command-tag ${a$(e.heartbeat_deadline)}">
              기한 ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function vy(){const t=Vt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">작전</div>
          <${O} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?o`<div class="command-card-stack">
              ${t.operations.operations.map(e=>o`<${my} card=${e} />`)}
            </div>`:o`<div class="empty-state">관리형 또는 투영된 작전이 없습니다.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">분견대</div>
          <${O} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>o`<${_y} card=${e} />`)}
            </div>`:o`<div class="empty-state">투영된 분견대가 없습니다.</div>`}
      </section>
    </div>
  `}function fy(){var c,d,p,_,v,f,h,T,k,C,$,y,x,M,I,F;const t=Cs.value,e=(t==null?void 0:t.operations)??[],n=mn.value,s=e.find(B=>B.operation.operation_id===n)??e[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,i=((d=es.value)==null?void 0:d.run)??(s==null?void 0:s.preview_run)??null,l=!((p=es.value)!=null&&p.run)&&!!(s!=null&&s.preview_run);return nt(()=>{a?$f(a):gf()},[a]),o`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${O} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${ve(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>native chain 연결</strong>
            <span class="command-chip ${ve(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"체인 요약은 MASC 프록시를 통해 집계됩니다."}</p>
          <div class="command-card-grid">
            <span>기준 URL</span><span>${(t==null?void 0:t.connection.base_url)??"정보 없음"}</span>
            <span>연결된 작전</span><span>${((_=t==null?void 0:t.summary)==null?void 0:_.linked_operations)??0}</span>
            <span>활성 체인</span><span>${((v=t==null?void 0:t.summary)==null?void 0:v.active_chains)??0}</span>
            <span>최근 실패</span><span>${((f=t==null?void 0:t.summary)==null?void 0:f.recent_failures)??0}</span>
            <span>마지막 이벤트</span><span>${Q((h=t==null?void 0:t.summary)==null?void 0:h.last_history_event_at)}</span>
          </div>
        </article>

        ${Da.value?o`<div class="empty-state error">${Da.value}</div>`:null}

        ${Ci.value&&!t?o`<div class="empty-state">체인 오버레이 불러오는 중…</div>`:e.length>0?o`
                <div class="command-chain-list">
                  ${e.map(B=>o`
                    <${dy}
                      overlay=${B}
                      selected=${(s==null?void 0:s.operation.operation_id)===B.operation.operation_id}
                      onSelect=${()=>cr(B.operation.operation_id)}
                    />
                  `)}
                </div>
              `:o`<div class="empty-state">체인 기반 작전이 아직 없습니다.</div>`}

        <div class="command-chain-history">
          <div class="command-guide-head">
            <strong>최근 이력</strong>
            <span class="command-chip">${(t==null?void 0:t.recent_history.length)??0}</span>
          </div>
          ${t&&t.recent_history.length>0?o`
                <div class="command-card-stack">
                  ${t.recent_history.slice(0,6).map(B=>o`<${uy} item=${B} />`)}
                </div>
              `:o`<div class="empty-state">최근 체인 이력이 없습니다.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">체인 상세</div>
          <${O} panelId="command.chains" compact=${!0} />
        </div>
        ${s?o`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${ve((T=s.operation.chain)==null?void 0:T.status)}">
                    ${((k=s.operation.chain)==null?void 0:k.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>종류</span><span>${((C=s.operation.chain)==null?void 0:C.kind)??"chain_dsl"}</span>
                  <span>체인 ID</span><span>${(($=s.operation.chain)==null?void 0:$.chain_id)??"goal-driven"}</span>
                  <span>실행 ID</span><span>${a??"아직 구체화되지 않음"}</span>
                  <span>진행률</span><span>${Tn((y=s.runtime)==null?void 0:y.progress)}</span>
                  <span>경과</span><span>${en((x=s.runtime)==null?void 0:x.elapsed_sec)}</span>
                  <span>최근 갱신</span><span>${Q(((M=s.operation.chain)==null?void 0:M.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(I=s.operation.chain)!=null&&I.goal?o`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?o`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid 그래프</strong>
                        <span class="command-chip">${((F=s.operation.chain)==null?void 0:F.chain_id)??"graph"}</span>
                      </div>
                      <${cy} source=${s.mermaid} />
                    </div>
                  `:o`<div class="empty-state">기록된 Mermaid 그래프가 아직 없습니다.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>실행 상세</strong>
                  <span class="command-chip ${(i==null?void 0:i.success)===!1?"bad":"ok"}">
                    ${i?i.success===!1?"실패":l?"미리보기":"기록됨":"대기 중"}
                  </span>
                </div>
                ${Oa.value?o`<div class="empty-state">실행 상세 불러오는 중…</div>`:ns.value?o`<div class="empty-state error">${ns.value}</div>`:i&&i.nodes.length>0?o`
                          <div class="command-card-grid">
                            <span>체인</span><span>${i.chain_id}</span>
                            <span>실행</span><span>${i.run_id??"미리보기만 있음"}</span>
                            <span>지속시간</span><span>${i.duration_ms!=null?`${i.duration_ms}ms`:"정보 없음"}</span>
                            <span>노드</span><span>${i.nodes.length}</span>
                          </div>
                          ${l?o`<div class="command-card-foot">run-store에 기록되기 전, 설계된 체인으로 만든 미리보기입니다.</div>`:null}
                          <div class="command-card-stack">
                            ${i.nodes.map(B=>o`<${py} node=${B} />`)}
                          </div>
                        `:o`<div class="empty-state">이 작전의 run-store 상세는 아직 없습니다.</div>`}
              </div>
            `:o`<div class="empty-state">그래프와 실행 상세를 보려면 체인 기반 작전을 고르세요.</div>`}
      </section>
    </div>
  `}function gy(t){switch((t??"").trim().toLowerCase()){case"pending":return"대기 중";case"approved":return"승인됨";case"denied":return"거부됨";case"executed":return"실행됨";case"active":return"가동 중";default:return(t==null?void 0:t.trim())||"확인 필요"}}function $y({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return o`
    <article class="command-card ${z(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${z(t.status)}">${gy(t.status??"pending")}</span>
      </div>
      <div class="command-card-grid">
        <span>결정 ID</span><span>${t.decision_id}</span>
        <span>요청자</span><span>${t.requested_by??"알 수 없음"}</span>
        <span>출처</span><span>${t.source??"managed"}</span>
        <span>트레이스</span><span class="mono">${t.trace_id}</span>
        <span>생성 시각</span><span>${Q(t.created_at)}</span>
        <span>이유</span><span>${t.reason??"정보 없음"}</span>
      </div>
      ${t.status==="pending"&&!s?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${dt(e)} onClick=${()=>fe(()=>Sf(t.decision_id))}>
                ${dt(e)?"승인 중…":"승인"}
              </button>
              <button class="control-btn ghost" disabled=${dt(n)} onClick=${()=>fe(()=>Cf(t.decision_id))}>
                ${dt(n)?"거부 중…":"거부"}
              </button>
            </div>
          `:null}
      ${s?o`<div class="command-card-foot">레거시 operator 승인입니다. 실제 실행은 operator control에서 처리합니다.</div>`:null}
    </article>
  `}function hy({row:t}){var c,d,p;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((c=e.policy)!=null&&c.frozen),i=!!((d=e.policy)!=null&&d.kill_switch),l=Math.round((t.utilization??0)*100);return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${z(l>100?"bad":l>70?"warn":"ok")}">${l}%</span>
      </div>
      <div class="command-card-grid">
        <span>편성</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>정원</span><span>${t.headcount_cap??0}</span>
        <span>작전</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>자율성</span><span>${((p=e.policy)==null?void 0:p.autonomy_level)??"정보 없음"}</span>
        <span>동결</span><span>${a?"예":"아니오"}</span>
        <span>킬 스위치</span><span>${i?"켜짐":"꺼짐"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${dt(n)} onClick=${()=>fe(()=>Af(e.unit_id,!a))}>
          ${dt(n)?"적용 중…":a?"동결 해제":"동결"}
        </button>
        <button class="control-btn ghost" disabled=${dt(s)} onClick=${()=>fe(()=>Tf(e.unit_id,!i))}>
          ${dt(s)?"적용 중…":i?"킬 스위치 해제":"킬 스위치 켜기"}
        </button>
      </div>
    </article>
  `}function yy(){const t=Vt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${O} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>o`<${$y} decision=${e} />`)}
            </div>`:o`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">유닛 제어</div>
          <${O} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>o`<${hy} row=${e} />`)}
            </div>`:o`<div class="empty-state">제어할 용량 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function by(){return o`
    <div class="command-surface-tabs grouped">
      ${c$.map(t=>o`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${Jd.filter(e=>e.group===t.id).map(e=>o`
                <button
                  class="command-surface-tab ${X.value===e.id?"active":""}"
                  onClick=${()=>{Bt(e.id),at("command",Ls(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function ky({wallboard:t=!1}){if(X.value==="warroom")return o`<${ly} wallboard=${t} />`;if(X.value==="summary")return o`<${Q$} />`;if(X.value==="orchestra")return o`<${mh} />`;if(X.value==="swarm")return o`<${Gh} />`;if(!Vt.value)return o`<${Z$} />`;switch(X.value){case"chains":return o`<${fy} />`;case"topology":return o`<${zh} />`;case"alerts":return o`<${Eh} />`;case"trace":return o`<${jh} />`;case"control":return o`<${yy} />`;case"operations":default:return o`<${vy} />`}}function xy(){const t=X.value==="warroom"&&D.value.params.presentation==="wallboard";return nt(()=>{tn(),Oe(),hf(),te(),je()},[]),nt(()=>{if(D.value.tab!=="command")return;const e=D.value.params.surface,n=D.value.params.operation,s=As(D.value);if(jl(e))Bt(e);else if(s){const a=Pd(s);jl(a)&&Bt(a)}else e||Bt("warroom");n&&cr(n),(e==="swarm"||e==="warroom"||e==="orchestra"||X.value==="warroom"||X.value==="orchestra")&&te(),(e==="orchestra"||X.value==="orchestra")&&je(),(e==="warroom"||X.value==="warroom")&&mt()},[D.value.tab,D.value.params.surface,D.value.params.operation,D.value.params.operation_id,D.value.params.run_id,D.value.params.source,D.value.params.action_type,D.value.params.target_type,D.value.params.target_id,D.value.params.focus_kind]),nt(()=>{let e=null;const n=()=>{e||(e=window.setTimeout(()=>{e=null,tn(),Oe(),(X.value==="swarm"||X.value==="warroom"||X.value==="orchestra")&&te(),X.value==="orchestra"&&je(),X.value==="warroom"&&mt()},250))},s=new EventSource(_$()),a=u$.map(i=>{const l=()=>n();return s.addEventListener(i,l),{type:i,handler:l}});return s.onerror=()=>{n()},()=>{a.forEach(({type:i,handler:l})=>{s.removeEventListener(i,l)}),s.close(),e&&window.clearTimeout(e)}},[]),nt(()=>{const e=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const n=X.value;n!=="swarm"&&n!=="warroom"&&n!=="orchestra"||(tn(),te(),n==="orchestra"&&je(),n==="warroom"&&mt())},5e3);return()=>{window.clearInterval(e)}},[]),o`
    <section class="dashboard-panel command-plane-view ${t?"wallboard":""}">
      ${t?null:o`
        <div class="panel-header">
          <div>
            <h2>지휘면</h2>
            <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
          </div>
          <div class="panel-actions">
            <button
              class="control-btn ghost"
              onClick=${()=>{fe(()=>xf())}}
              disabled=${dt("dispatch:tick")}
            >
              ${dt("dispatch:tick")?"정리 중...":"Tick 실행"}
            </button>
            <button
              class="control-btn ghost"
              onClick=${()=>{ze(),tn(),Oe(),te(),X.value==="warroom"&&mt()}}
              disabled=${Ra.value}
            >
              ${Ra.value?"새로고침 중...":"새로고침"}
            </button>
            <button
              class="control-btn ghost"
              onClick=${()=>{Bt("warroom"),at("command",{...Ls("warroom"),presentation:"wallboard"})}}
            >
              Wallboard
            </button>
          </div>
        </div>
      `}

      ${Ma.value?o`<div class="empty-state error">${Ma.value}</div>`:null}
      ${za.value?o`<div class="empty-state error">${za.value}</div>`:null}
      ${t?null:o`<${At} surfaceId="command" />`}
      ${t?null:o`<${yr} />`}
      ${t?null:o`<${G$} />`}
      ${t||X.value==="warroom"?null:o`<${J$} />`}
      ${t?null:o`<${by} />`}
      <${ky} wallboard=${t} />
    </section>
  `}function Sy(){var C;const t=Tt.value,e=sr.value,n=(t==null?void 0:t.room)??{},s=hs(t),a=s.items,i=s.confirm_required_actions,l=s.actor_filter,c=s.hidden_count,d=s.hidden_actors,p=(t==null?void 0:t.recent_messages)??[],_=(e==null?void 0:e.recommended_actions)??[],v=(C=e==null?void 0:e.active_recommended_actions)!=null&&C.length?e.active_recommended_actions:_,f=e==null?void 0:e.active_summary,h=(e==null?void 0:e.resident_judge_runtime)??(t==null?void 0:t.resident_judge_runtime),T=(e==null?void 0:e.active_guidance_layer)??"fallback",k=p.slice(0,5);return o`
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
          <div class="ops-stat ${au(h)}">
            <span>Resident Judge</span>
            <strong>${_o(h)}</strong>
          </div>
        </div>

        <label class="control-label" for="ops-broadcast">Room 방송</label>
        <div class="control-row">
          <input
            id="ops-broadcast"
            class="control-input"
            type="text"
            placeholder="@agent 또는 room 전체 공지"
            value=${vn.value}
            onInput=${$=>{vn.value=$.target.value}}
            onKeyDown=${$=>{$.key==="Enter"&&Ul()}}
            disabled=${ot.value}
          />
          <button class="control-btn" onClick=${()=>{Ul()}} disabled=${ot.value||vn.value.trim()===""}>
            보내기
          </button>
        </div>

        <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
        <div class="control-row ops-split-row">
          <input
            id="ops-pause-reason"
            class="control-input"
            type="text"
            value=${Ua.value}
            onInput=${$=>{Ua.value=$.target.value}}
            disabled=${ot.value}
          />
          <button class="control-btn ghost" onClick=${()=>{Ah()}} disabled=${ot.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{iu()}} disabled=${ot.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${fn.value}
          onInput=${$=>{fn.value=$.target.value}}
          disabled=${ot.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${is.value}
          onInput=${$=>{is.value=$.target.value}}
          disabled=${ot.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${rs.value}
            onChange=${$=>{rs.value=$.target.value}}
            disabled=${ot.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{Th()}} disabled=${ot.value||fn.value.trim()===""}>
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
        <article class="ops-guidance-card ${Ga(T)}">
          <div class="ops-guidance-head">
            <strong>${kr(T)}</strong>
            <span>${(h==null?void 0:h.keeper_name)??(e==null?void 0:e.judgment_owner)??"judge 없음"}</span>
          </div>
          <div class="ops-guidance-body">
            ${(f==null?void 0:f.summary)??"현재 active guidance 요약이 없습니다. fallback queue만 표시합니다."}
          </div>
          <div class="ops-guidance-meta">
            <span>authoritative ${e!=null&&e.authoritative_judgment_available?"yes":"no"}</span>
            <span>${xr(f)}</span>
            ${h!=null&&h.model_used?o`<span>${h.model_used}</span>`:null}
          </div>
        </article>
        ${ts.value&&!e?o`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:v.length>0?o`
          <div class="ops-log-list">
            ${v.map($=>o`
              <article key=${`${$.action_type}:${$.target_type}:${$.target_id??"room"}`} class="ops-log-entry ${$.severity}">
                <div class="ops-log-head">
                  <strong>${qe($.action_type)}</strong>
                  <span>${gn($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                  <span>${Ja($.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${$.reason}</div>
                ${$.suggested_payload?o`
                  <div class="ops-confirmation-actions">
                    <button class="control-btn ghost" onClick=${()=>{Sh($)}} disabled=${ot.value}>
                      폼에 채우기
                    </button>
                  </div>
                `:null}
              </article>
            `)}
          </div>
        `:o`
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
        ${i.length>0?o`
          <div class="ops-log-list">
            ${i.map($=>o`
              <article key=${`${$.action_type}:${$.target_type}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${qe($.action_type)}</strong>
                  <span>${gn($.target_type)}</span>
                  <span>${Ja($.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${$.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}
        ${a.length>0?o`
          <div class="ops-confirmation-list">
            ${a.map($=>o`
              <article key=${$.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${qe($.action_type)}</strong>
                  <span>${gn($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                  <span>${$.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${$.preview?o`<pre class="ops-code-block compact">${Wa($.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{Hl($.confirm_token)}} disabled=${ot.value}>
                    실행
                  </button>
                  <button class="control-btn ghost" onClick=${()=>{Hl($.confirm_token,"deny")}} disabled=${ot.value}>
                    거부
                  </button>
                  <span class="ops-token">${$.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        `:o`
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
        ${k.length>0?o`
          <div class="ops-feed-list">
            ${k.map($=>o`
              <article key=${$.seq??$.id??$.timestamp} class="ops-feed-item">
                <div class="ops-feed-meta">
                  <strong>${$.from}</strong>
                  <span>${$.timestamp}</span>
                </div>
                <div class="ops-feed-content">${$.content}</div>
              </article>
            `)}
          </div>
        `:o`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
      </section>
    </div>
  `}const Ge=g(""),Eo=g(!1),Hs=g(null);function Cy(){var $;const t=Tt.value,e=Wt.value,n=(t==null?void 0:t.sessions)??[],s=((t==null?void 0:t.available_actions)??[]).filter(y=>y.target_type==="team_session"),a=n.find(y=>y.session_id===yn.value)??n[0]??null,i=e==null?void 0:e.active_summary,l=(e==null?void 0:e.active_guidance_layer)??"fallback",c=(e==null?void 0:e.resident_judge_runtime)??(t==null?void 0:t.resident_judge_runtime),d=(a==null?void 0:a.linked_autoresearch)??null,p=ot.value||Eo.value,_=($=e==null?void 0:e.active_recommended_actions)!=null&&$.length?e.active_recommended_actions:(e==null?void 0:e.recommended_actions)??[],v=async()=>{await mt(),a!=null&&a.session_id&&await he(a.session_id)},f=async y=>{Eo.value=!0,Hs.value=null;try{await y(),await v()}catch(x){Hs.value=x instanceof Error?x.message:"Autoresearch action failed"}finally{Eo.value=!1}},h=async()=>{d!=null&&d.loop_id&&await f(()=>up(d.loop_id))},T=async()=>{if(!(d!=null&&d.loop_id)||!Ge.value.trim())return;const y=Ge.value.trim();await f(()=>pp(d.loop_id,y)),Ge.value=""},k=async()=>{d!=null&&d.loop_id&&await f(()=>mp(d.loop_id))},C=async()=>{d!=null&&d.loop_id&&await f(()=>_p(d.loop_id,"dashboard stop request"))};return o`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${O} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?o`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(y=>{var x;return o`
            <button
              key=${y.session_id}
              class="ops-entity-card ${(a==null?void 0:a.session_id)===y.session_id?"active":""}"
              onClick=${()=>{yn.value=y.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${y.session_id}</strong>
                <span class="status-badge ${y.status??"idle"}">${sn(y.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(y.progress_pct??0)}%</span>
                <span>${y.done_delta_total??0}건 완료</span>
                <span>${(x=y.team_health)!=null&&x.status?sn(String(y.team_health.status)):"상태 확인 필요"}</span>
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
        ${a&&e?o`
          <article class="ops-guidance-card ${Ga(l)}">
            <div class="ops-guidance-head">
              <strong>${kr(l)}</strong>
              <span>${_o(c)}</span>
            </div>
            <div class="ops-guidance-body">
              ${(i==null?void 0:i.summary)??"현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다."}
            </div>
            <div class="ops-guidance-meta">
              <span>authoritative ${e.authoritative_judgment_available?"yes":"no"}</span>
              <span>${xr(i)}</span>
              ${c!=null&&c.model_used?o`<span>${c.model_used}</span>`:null}
            </div>
          </article>
          ${_.length>0?o`
            <div class="ops-log-list">
              ${_.map(y=>o`
                <article key=${`${y.action_type}:${y.target_type}:${y.target_id??"session"}`} class="ops-log-entry ${y.severity}">
                  <div class="ops-log-head">
                    <strong>${qe(y.action_type)}</strong>
                    <span>${gn(y.target_type)}${y.target_id?` · ${y.target_id}`:""}</span>
                  </div>
                  <div class="ops-log-body">${y.reason}</div>
                </article>
              `)}
            </div>
          `:null}
          <div class="ops-log-list">
            ${e.attention_items.length>0?e.attention_items.map(y=>o`
              <article key=${`${y.kind}:${y.target_id??"session"}`} class="ops-log-entry ${y.severity}">
                <div class="ops-log-head">
                  <strong>${y.kind}</strong>
                  <span>${gn(y.target_type)}${y.target_id?` · ${y.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${y.summary}</div>
              </article>
            `):o`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${e.worker_cards.length>0?e.worker_cards.map(y=>o`
              <article key=${`${y.actor??y.spawn_role??"worker"}:${y.spawn_agent??y.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${y.actor??y.spawn_role??"worker"}</strong>
                  <span>${sn(y.status)}</span>
                  <span>${y.spawn_agent??y.runtime_pool??"runtime 확인 필요"}</span>
                </div>
                <div class="ops-log-body">
                  ${y.worker_class??"worker"}${y.lane_id?` · ${y.lane_id}`:""}${y.routing_reason?` · ${y.routing_reason}`:""}
                </div>
              </article>
            `):null}
          </div>
        `:o`
          <div class="ops-empty">세션을 고르면 세부 요약을 불러옵니다.</div>
        `}
      </section>

      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Session 액션</div>
          <${O} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>
        ${s.length>0?o`
          <div class="ops-log-list">
            ${s.map(y=>o`
              <article key=${y.action_type} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${qe(y.action_type)}</strong>
                  <span>${Ja(y.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${y.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}

        ${a?o`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${a.session_id}</div>
            <div class="ops-detail-meta">
              <span>상태: ${sn(a.status)}</span>
              <span>경과: ${a.elapsed_sec??0}초</span>
              <span>남은 시간: ${a.remaining_sec??0}초</span>
            </div>
            ${a.linked_autoresearch?o`
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
                ${a.linked_autoresearch.operation_id?o`<span>작전: ${a.linked_autoresearch.operation_id}</span>`:null}
              </div>
              ${a.linked_autoresearch.program_note?o`<div class="ops-context-note">Program note: ${a.linked_autoresearch.program_note}</div>`:null}
              ${a.linked_autoresearch.queued_hypothesis?o`<div class="ops-context-note">Queued hypothesis: ${a.linked_autoresearch.queued_hypothesis}</div>`:null}
              ${a.linked_autoresearch.warnings&&a.linked_autoresearch.warnings.length>0?o`<div class="ops-context-note">Warnings: ${a.linked_autoresearch.warnings.join(", ")}</div>`:null}
              ${a.linked_autoresearch.error?o`<div class="ops-empty">${a.linked_autoresearch.error}</div>`:null}
            `:null}
            ${a.recent_events&&a.recent_events.length>0?o`
              <pre class="ops-code-block compact">${Wa(a.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:o`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        ${d!=null&&d.loop_id?o`
          <label class="control-label" for="ops-autoresearch-hypothesis">Autoresearch 제어</label>
          <div class="control-row ops-split-row">
            <button class="control-btn ghost" onClick=${()=>{h()}} disabled=${p}>
              상태 새로고침
            </button>
            <button class="control-btn" onClick=${()=>{k()}} disabled=${p}>
              1 cycle 실행
            </button>
            <button class="control-btn ghost" onClick=${()=>{C()}} disabled=${p}>
              loop 중지
            </button>
          </div>
          <textarea
            id="ops-autoresearch-hypothesis"
            class="control-textarea"
            rows=${2}
            placeholder="다음 cycle에 넣을 hypothesis"
            value=${Ge.value}
            onInput=${y=>{Ge.value=y.target.value}}
            disabled=${p}
          ></textarea>
          <div class="control-row ops-split-row">
            <button class="control-btn" onClick=${()=>{T()}} disabled=${p||!Ge.value.trim()}>
              hypothesis 주입
            </button>
            <span class="ops-context-note">canonical control은 MCP tool이고, 이 화면은 그 상태를 읽고 이어서 제어합니다.</span>
          </div>
          ${Hs.value?o`<div class="ops-empty">${Hs.value}</div>`:null}
        `:null}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${Ct.value}
            onChange=${y=>{Ct.value=y.target.value}}
            disabled=${p||!a}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
            <option value="worker_spawn_batch">worker 교체</option>
          </select>
          <button class="control-btn" onClick=${()=>{Ih()}} disabled=${p||!a}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${yh(Ct.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${ls.value}
          onInput=${y=>{ls.value=y.target.value}}
          disabled=${p||!a}
        ></textarea>

        ${Ct.value==="task"?o`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${cs.value}
            onInput=${y=>{cs.value=y.target.value}}
            disabled=${p||!a}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${ds.value}
            onInput=${y=>{ds.value=y.target.value}}
            disabled=${p||!a}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${us.value}
            onChange=${y=>{us.value=y.target.value}}
            disabled=${p||!a}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
        `:Ct.value==="worker_spawn_batch"?o`
          <textarea
            class="control-textarea"
            rows=${6}
            placeholder='spawn_batch JSON, 예: [{"spawn_agent":"llama","spawn_prompt":"...", "spawn_role":"replacement"}]'
            value=${ps.value}
            onInput=${y=>{ps.value=y.target.value}}
            disabled=${p||!a}
          ></textarea>
        `:null}

        <div class="control-row ops-split-row">
          <input
            class="control-input"
            type="text"
            value=${Ha.value}
            onInput=${y=>{Ha.value=y.target.value}}
            disabled=${p||!a}
          />
          <button class="control-btn ghost" onClick=${()=>{Rh()}} disabled=${p||!a}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function Ay(){var i;const t=Tt.value,e=(t==null?void 0:t.keepers)??[],n=(t==null?void 0:t.persistent_agents)??[],s=(t==null?void 0:t.available_actions)??[],a=e.find(l=>l.name===Li.value)??e[0]??null;return o`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${O} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${e.length===0?o`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:e.map(l=>o`
            <button
              key=${l.name}
              class="ops-entity-card ${(a==null?void 0:a.name)===l.name?"active":""}"
              onClick=${()=>{Li.value=l.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${l.name}</strong>
                <span class="status-badge ${l.status??"idle"}">${sn(l.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${l.model??"model 확인 필요"}</span>
                <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${Kl(l.last_turn_ago_s)}</span>
              </div>
            </button>
          `)}
        </div>
        <div class="ops-context-note" style="margin-top:12px;">Persistent agent는 resident keeper와 분리해서 참고용으로만 보여줍니다.</div>
        <div class="ops-entity-list">
          ${n.length===0?o`<div class="ops-empty">분리된 persistent agent는 없습니다.</div>`:n.map(l=>o`
                <article key=${l.name} class="ops-entity-card">
                  <div class="ops-entity-title-row">
                    <strong>${l.name}</strong>
                    <span class="status-badge ${l.status??"idle"}">${sn(l.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>persistent</span>
                    <span>${l.model??"model 확인 필요"}</span>
                    <span>${Kl(l.last_turn_ago_s)}</span>
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

        ${a?o`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${a.name}</div>
            <div class="ops-detail-meta">
              <span>자율성: ${a.autonomy_level??"확인 없음"}</span>
              <span>세대: ${a.generation??0}</span>
              <span>활성 목표: ${((i=a.active_goal_ids)==null?void 0:i.length)??0}</span>
            </div>
          </div>
          <${Ud}
            keeperName=${a.name}
            placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
          />
        `:o`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">가능한 액션 목록</div>
          <${O} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
        <div class="ops-log-list">
          ${s.length?s.map(l=>o`
                <article key=${`${l.action_type}:${l.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${qe(l.action_type)}</strong>
                    <span>${gn(l.target_type)}</span>
                    <span>${Ja(l.confirm_required)}</span>
                  </div>
                  <div class="ops-log-body">${l.description??"설명이 아직 없습니다."}</div>
                </article>
              `):o`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 개입 로그</div>
          <${O} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <div class="ops-log-list">
          ${Ca.value.length===0?o`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:Ca.value.map(l=>o`
            <article key=${l.id} class="ops-log-entry ${l.outcome}">
              <div class="ops-log-head">
                <strong>${qe(l.action_type)}</strong>
                <span>${l.target_label}</span>
                <span>${l.at}</span>
              </div>
              <div class="ops-log-body">${l.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function Ty(){var x,M;const t=Tt.value,e=D.value.tab==="intervene"?As(D.value):null,n=sr.value,s=(t==null?void 0:t.room)??{},a=(t==null?void 0:t.sessions)??[],i=(t==null?void 0:t.keepers)??[],l=hs(t),c=l.visible_count,d=l.total_count,p=l.hidden_count,_=l.actor_filter,v=a.find(I=>I.session_id===yn.value)??a[0]??null,f=(n==null?void 0:n.attention_items)??[],h=f.filter($h),T=f.filter(hh),k=a.filter(I=>gh(I)!=="ok"),C=i.filter(I=>zo(I)!=="ok"),$=Ch(e,a,i);nt(()=>{Fe()},[]),nt(()=>{if(D.value.tab!=="intervene"){Us.value=null;return}if(!e){Us.value=null;return}Us.value!==e.id&&(Us.value=e.id,xh(e))},[D.value.tab,D.value.params.source,D.value.params.action_type,D.value.params.target_type,D.value.params.target_id,D.value.params.focus_kind,e==null?void 0:e.id]),nt(()=>{const I=(v==null?void 0:v.session_id)??null;he(I)},[v==null?void 0:v.session_id]);const y=[{key:"room",label:"방 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:p>0?`${c}/${d}`:c,detail:c>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":p>0&&_?`현재 개입 ID(${_}) 기준으로는 비어 있고, 다른 개입 ID 대기 ${p}건이 있습니다`:"지금 막혀 있는 확인 대기는 없습니다",tone:d>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:h.length>0?h.length:a.length,detail:h.length>0?((x=h[0])==null?void 0:x.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 팀 세션이 없습니다":"세션 쪽 긴급 주의 신호는 현재 없습니다",tone:h.length>0?Bl(h):a.length===0?"warn":k.some(I=>bn(I.status)==="paused")?"bad":k.length>0?"warn":"ok"},{key:"keeper",label:"키퍼 압력",value:T.length>0?T.length:C.length,detail:T.length>0?((M=T[0])==null?void 0:M.summary)??"직접 메시지나 상태 점검이 필요한 키퍼가 있습니다":C.length>0?"오래됐거나 오프라인이거나 텔레메트리가 비는 키퍼가 보입니다":"지금은 키퍼 쪽이 비교적 안정적입니다",tone:T.length>0?Bl(T):C.some(I=>zo(I)==="bad")?"bad":C.length>0?"warn":"ok"}];return o`
    <section class="ops-view">
      <${At} surfaceId="intervene" />
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
            value=${mo.value}
            onInput=${I=>fh(I.target.value)}
          />
            <button
              class="control-btn ghost"
              onClick=${()=>{ze(),mt(),Fe(),he((v==null?void 0:v.session_id)??null)}}
            disabled=${Zn.value||ot.value}
          >
            ${Zn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${$e.value?o`<section class="ops-banner error">${$e.value}</section>`:null}
      ${hn.value?o`<section class="ops-banner error">${hn.value}</section>`:null}
      <${yr} />
      ${e?o`
        <section class="ops-banner ${$?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${co(e.action_type)}</span>
            <span>${mr(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?o`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${$?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const I=[];if((c>0||p>0)&&I.push({label:p>0?`확인 대기 ${c}/${d}건 확인`:`확인 대기 ${c}건 처리`,desc:p>0&&_?`현재 개입 ID(${_}) 기준으로 보이는 대기열을 먼저 확인합니다`:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:c>0?"bad":"warn",onClick:()=>{const F=document.querySelector(".ops-pending-section");F==null||F.scrollIntoView({behavior:"smooth"})}}),s.paused&&I.push({label:"방 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void iu()}),C.length>0){const F=C.filter(B=>zo(B)==="bad");I.push({label:F.length>0?`오프라인 키퍼 ${F.length}개`:`점검이 필요한 키퍼 ${C.length}개`,desc:F.length>0?"메시지를 보내거나 상태를 확인하세요":"오래됐거나 텔레메트리가 비어 있습니다",tone:F.length>0?"bad":"warn",onClick:()=>{const B=document.querySelector(".ops-keeper-section");B==null||B.scrollIntoView({behavior:"smooth"})}})}return I.length===0?null:o`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${I.slice(0,3).map(F=>o`
                <button class="ops-action-guide-item ${F.tone}" onClick=${F.onClick}>
                  <strong>${F.label}</strong>
                  <span>${F.desc}</span>
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
          ${y.map(I=>o`
            <div key=${I.key} class="ops-priority-card ${I.tone}">
              <span class="ops-priority-label">${I.label}</span>
              <strong>${I.value}</strong>
              <div class="ops-priority-detail">${I.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${Sy} />
        <${Cy} />
        <${Ay} />
      </div>
    </section>
  `}function Iy({text:t}){if(!t)return null;const e=Ry(t);return o`<div class="markdown-content">${e}</div>`}function Ry(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(l);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${c?`language-${c}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<e.length&&!e[s].includes("</think>");)l.push(e[s]),s++;if(s<e.length){const p=e[s].replace("</think>","").trim();p&&l.push(p),s++}const d=l.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${jo(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<e.length&&e[s].startsWith("> ");)l.push(e[s].slice(2)),s++;n.push(o`<blockquote>${jo(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const l=e[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;i.push(l),s++}i.length>0&&n.push(o`<p>${jo(i.join(`
`))}</p>`)}return n}function jo(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const vu=[{id:"recent",label:"최신순"},{id:"hot",label:"인기순"},{id:"trending",label:"급상승"},{id:"updated",label:"최근 갱신"},{id:"discussed",label:"토론 많은 순"}],ua=g(null),pa=g([]),kn=g(!1),De=g(null),Un=g(""),Hn=g(!1),on=g(!0),Cr=20,Ye=g(Cr);function Ly(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const My=g(Ly());function Py(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"미리보기 없음"}function Jl(t){return t.updated_at!==t.created_at}function zy(t){if(t.post_kind)return t.post_kind==="automation";const e=(t.hearth??"").toLowerCase();return t.visibility!=="internal"||!t.expires_at||!e?!1:!!(e.startsWith("mdal")||e.includes("harness"))}function Ey(t){return t==="lodge-system"||t==="team-session"}function ms(t){return t.post_kind?t.post_kind:Ey(t.author)?"system":zy(t)?"automation":"human"}function fu(t){const e=[],n=[];let s=0;return t.forEach(a=>{const i=ms(a);if(!(i==="system"&&Me.value)){if(i==="automation"&&on.value){s+=1;return}if(i==="human"){e.push(a);return}n.push(a)}}),{human:e,operations:n,hiddenAutomation:s}}function jy(t){if(!t.expires_at)return null;const e=Date.parse(t.expires_at);return Number.isFinite(e)?e<=Date.now()?o`<span class="board-meta-chip">만료됨</span>`:o`<span class="board-meta-chip">만료까지 <${Y} timestamp=${t.expires_at} /></span>`:null}async function Ar(t){De.value=t,ua.value=null,pa.value=[],kn.value=!0;try{const e=await Vp(t);if(De.value!==t)return;ua.value={id:e.id,author:e.author,title:e.title,body:e.body,content:e.content,meta:e.meta,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,post_kind:e.post_kind,flair:e.flair,hearth:e.hearth,visibility:e.visibility,expires_at:e.expires_at,hearth_count:e.hearth_count},pa.value=e.comments??[]}catch{De.value===t&&(ua.value=null,pa.value=[])}finally{De.value===t&&(kn.value=!1)}}async function Vl(t){const e=Un.value.trim();if(e){Hn.value=!0;try{await Yp(t,My.value,e),Un.value="",j("댓글을 등록했습니다","success"),await Ar(t),me()}catch{j("댓글 등록에 실패했습니다","error")}finally{Hn.value=!1}}}function wy(){const t=Xn.value,e=on.value?"자동화 글 숨김":"자동화 글 표시 중";return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${vu.map(n=>o`
          <button
            class="board-sort-btn ${t===n.id?"active":""}"
            onClick=${()=>{Xn.value=n.id,Ye.value=Cr,me()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${on.value?"is-active":""}"
          onClick=${()=>{on.value=!on.value}}
        >
          ${e}
        </button>
        <button
          class="control-btn ghost ${Me.value?"is-active":""}"
          onClick=${()=>{Me.value=!Me.value,me()}}
        >
          ${Me.value?"시스템 글 숨김":"시스템 글 표시 중"}
        </button>
        <button class="control-btn ghost" onClick=${me} disabled=${Qn.value}>
          ${Qn.value?"새로고침 중...":"새로고침"}
        </button>
      </div>
    </div>
  `}function wo(){var s;const t=((s=vu.find(a=>a.id===Xn.value))==null?void 0:s.label)??Xn.value,e=fu(ro.value),n=e.human.length+e.operations.length;return o`
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
        <strong>${on.value?`자동화 ${e.hiddenAutomation}건 숨김`:"분리된 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">시스템 글 정책</span>
        <strong>${Me.value?"시스템 글 숨김":"시스템 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">최근 갱신</span>
        <strong>${gi.value?o`<${Y} timestamp=${gi.value} />`:"아직 불러오지 않음"}</strong>
      </div>
    </div>
  `}function Yl({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Lc(t.id,n),me()}catch{j("투표에 실패했습니다","error")}};return o`
    <div class="board-post" onClick=${()=>Fu(t.id)}>
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
                ${Jl(t)?o`<span class="board-meta-chip">수정됨</span>`:null}
                ${ms(t)!=="human"?o`<span class="board-meta-chip">${ms(t)}</span>`:null}
                ${t.hearth?o`<span class="board-meta-chip">${t.hearth}</span>`:null}
                ${t.visibility?o`<span class="board-meta-chip">${t.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>작성자 ${t.author}</span>
            <span><${Y} timestamp=${t.created_at} /></span>
            ${Jl(t)?o`<span>수정 <${Y} timestamp=${t.updated_at} /></span>`:null}
            <span>댓글 ${t.comment_count}</span>
            <span>투표 ${t.votes??0}</span>
          </div>
        </div>
        <div class="post-snippet">${Py(t.body)}</div>
      </div>
    </div>
  `}function Ny({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">아직 댓글이 없습니다</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${Y} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Dy({postId:t}){return o`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="댓글 추가..."
        value=${Un.value}
        onInput=${e=>{Un.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Vl(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Hn.value}
      />
      <button
        onClick=${()=>Vl(t)}
        disabled=${Hn.value||Un.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Hn.value?"...":"등록"}
      </button>
    </div>
  `}function Oy({post:t}){De.value!==t.id&&!kn.value&&Ar(t.id);const e=async n=>{try{await Lc(t.id,n),me()}catch{j("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>at("memory")}>← 메모리로 돌아가기</button>
      <${L} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${Iy} text=${t.body} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${Y} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          ${t.hearth||t.visibility||t.expires_at?o`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${t.hearth?o`<span class="board-meta-chip">${t.hearth}</span>`:null}
                  ${t.visibility?o`<span class="board-meta-chip">${t.visibility}</span>`:null}
                  ${ms(t)!=="human"?o`<span class="board-meta-chip">${ms(t)}</span>`:null}
                  ${jy(t)}
                </div>
              `:null}
          ${t.meta?o`
                <details style="margin-top:12px;">
                  <summary>운영 메타</summary>
                  <div class="post-body" style="margin-top:8px;">
                    ${t.meta.source?o`<div><strong>출처</strong>: ${t.meta.source}</div>`:null}
                    ${t.meta.state_block?o`<pre style="white-space:pre-wrap; margin-top:8px;">${t.meta.state_block}</pre>`:null}
                  </div>
                </details>
              `:null}
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ 추천</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ 비추천</button>
          </div>
        </div>
      <//>

      <${L} title="댓글" semanticId="memory.feed">
        ${kn.value?o`<div class="loading-indicator">댓글 불러오는 중...</div>`:o`<${Ny} comments=${pa.value} />`}
        <${Dy} postId=${t.id} />
      <//>
    </div>
  `}function qy(){const t=fu(ro.value),e=[...t.human,...t.operations],n=D.value.params.post??null,s=n?e.find(a=>a.id===n)??(De.value===n?ua.value:null):null;return n&&!s&&De.value!==n&&!kn.value&&Ar(n),n?s?o`
          <${At} surfaceId="memory" />
          <${wo} />
          <${Oy} post=${s} />
        `:o`
          <div>
            <${At} surfaceId="memory" />
            <${wo} />
            <button class="back-btn" onClick=${()=>at("memory")}>← 메모리로 돌아가기</button>
            ${kn.value?o`<div class="loading-indicator">글 불러오는 중...</div>`:o`<div class="empty-state">글을 찾지 못했습니다</div>`}
          </div>
        `:o`
    <div>
      <${At} surfaceId="memory" />
      <${wo} />
      <${wy} />
      ${Qn.value?o`<div class="loading-indicator">메모리 피드 불러오는 중...</div>`:e.length===0?o`<div class="empty-state">지금은 남아 있는 메모리 글이 없습니다</div>`:o`
              <${L} title="사람이 쓴 글" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.human.slice(0,Ye.value).map(a=>o`<${Yl} key=${a.id} post=${a} />`)}
                </div>
                ${t.human.length>Ye.value?o`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{Ye.value=Ye.value+Cr}}
                    >
                      더 보기 (${t.human.length-Ye.value}개 남음)
                    </button>
                  </div>
                `:null}
              <//>
              ${t.operations.length>0?o`
                    <${L} title="자동화 · 시스템" class="section" semanticId="memory.feed">
                      <div class="board-post-list">
                        ${t.operations.map(a=>o`<${Yl} key=${a.id} post=${a} />`)}
                      </div>
                    <//>
                  `:null}
            `}
    </div>
  `}function Fy({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,l=i*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${c}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${l}" 
        />
      </svg>
      <span class="mitosis-text ${c}">${Math.round(t*100)}%</span>
    </div>
  `}function Ky(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Xl(t,e="없음"){return!t||t.length===0?e:t.slice(0,4).join(", ")}function By({model:t,onClick:e,variant:n,testId:s}){var c,d,p,_;const a=!!t.recentEvent||!!t.recentInput||!!t.recentOutput||!!t.routeSummary||!!t.auditSource||!!t.auditAt||(((c=t.recentTools)==null?void 0:c.length)??0)>0||(((d=t.allowedTools)==null?void 0:d.length)??0)>0,i=n==="mission"?`mission-activity-card ${t.tone}`:"keeper-canonical-card",l=n==="mission"?"mission-card-select":`monitor-row ${t.tone}${t.stateClass?` state-${t.stateClass}`:""}`;return o`
    <article class=${i}>
      <button class=${l} data-testid=${s} onClick=${e}>
        <div class=${n==="mission"?"mission-activity-head":"monitor-row-header"}>
          <div class=${n==="mission"?"mission-activity-title":"monitor-row-title"}>
            <span class="agent-emoji">${t.emoji??""}</span>
            <div>
              <div class=${n==="mission"?"":"monitor-name-line"}>
                <strong class=${n==="mission"?"":"monitor-title"}>${t.name}</strong>
                ${t.koreanName?o`<span class=${n==="mission"?"":"monitor-sub"}>${t.koreanName}</span>`:null}
              </div>
              ${t.runtimeLabel?o`<div class=${n==="mission"?"":"monitor-sub"}>${t.runtimeLabel}</div>`:null}
              ${t.note?o`<div class=${n==="mission"?"":"monitor-note"}>${t.note}</div>`:null}
            </div>
          </div>
          ${n==="execution"?o`
                <${Fy} ratio=${t.contextRatio??0} size=${34} stroke=${4} />
                <${ke} status=${t.statusRaw??"unknown"} />
                ${t.stateLabel?o`<span class="monitor-pill ${t.tone}">${t.stateLabel}</span>`:null}
              `:o`<span class="command-chip ${t.tone}">${t.statusLabel}</span>`}
        </div>

        <div class=${n==="mission"?"mission-activity-meta":"monitor-meta"}>
          ${t.lastActivityAt?o`<span>최근 활동 <${Y} timestamp=${t.lastActivityAt} /></span>`:o`<span>${t.lastActivityFallback??"최근 활동 없음"}</span>`}
          ${t.relatedSessionId?o`<span>세션 · ${t.relatedSessionId}</span>`:null}
          ${t.continuity?o`<span>${t.continuity}</span>`:null}
          ${t.lifecycle?o`<span>생애주기 ${t.lifecycle}</span>`:null}
          <span>컨텍스트 ${Ky(t.contextRatio)}</span>
        </div>

        <div class=${n==="mission"?"mission-activity-focus":"monitor-focus"}>
          ${n==="mission"?o`
                <span>무엇을</span>
                <strong>${t.focus}</strong>
              `:o`${t.focus}`}
        </div>

        ${t.summary?o`<div class=${n==="mission"?"mission-inline-note":"monitor-footnote"}>${t.summary}</div>`:null}
      </button>

      ${a?o`
            <details class="mission-card-disclosure compact">
              <summary>${t.disclosureLabel??"세부 정보"}</summary>
              <div class="mission-activity-foot">
                ${t.recentEvent?o`<span>최근 일 · ${t.recentEvent}</span>`:null}
                ${t.routeSummary?o`<span>route · ${t.routeSummary}</span>`:null}
                ${t.auditSource?o`<span>audit · ${t.auditSource}</span>`:null}
                ${t.auditAt?o`<span><${Y} timestamp=${t.auditAt} /></span>`:null}
              </div>
              ${t.recentInput||t.recentOutput?o`
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
              ${(((p=t.recentTools)==null?void 0:p.length)??0)>0||(((_=t.allowedTools)==null?void 0:_.length)??0)>0?o`
                    <div class="mission-activity-foot">
                      <span>최근 도구 · ${Xl(t.recentTools)}</span>
                      <span>허용 도구 · ${Xl(t.allowedTools)}</span>
                    </div>
                  `:null}
            </details>
          `:null}
    </article>
  `}const Re=g(null),Qt=g(null),Zt=g(null);function _s(t){return t==="bad"||t==="critical"||t==="offline"?"bad":t==="warn"||t==="paused"||t==="blocked"||t==="interrupted"?"warn":"ok"}function vs(t){switch((t??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":return"주의";case"bad":case"critical":return"위험";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Uy(t){return t==="session"?"세션":"작전"}function Hy(t){return t?ae.value.find(e=>e.name===t||e.agent_name===t)??null:null}function Wy(t){switch(t){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function Gy(t){switch(t){case"live":return"최근 신호(≤5m)";case"stale":return"오래된 신호(>5m)";case"absent":return"signal 없음";default:return t??"signal 미상"}}function Jy(t){switch(t){case"message":return"최근 출력";case"presence":return"presence/하트비트";case"none":return"근거 없음";default:return t??"근거 미상"}}function Vy(t){switch(t){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function Yy(t){switch(t){case"acted":return"행동";case"passed":return"통과";case"skipped":return"건너뜀";case"failed":return"실패";default:return t}}function Xy(t){switch(t){case"post":return"post";case"comment":return"comment";case"vote":return"vote";case"none":case null:case void 0:return"none";default:return t}}function Ql(t){if(!t)return;const e=wf({targetType:t.target_type,targetId:t.target_id,focusKind:t.focus_kind,operationId:t.operation_id??null,commandSurface:t.command_surface??null,sourceLabel:"실행 진단",summary:t.label});Ld(e),at(t.surface,t.surface==="intervene"?Md(e):zd(e))}function Pn({label:t,value:e,color:n,caption:s}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?o`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function Tr({intervene:t,command:e}){return o`
    <div class="control-row">
      ${t?o`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),Ql(t)}}
            >
              ${t.label}
            </button>
          `:null}
      ${e?o`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),Ql(e)}}
            >
              ${e.label}
            </button>
          `:null}
    </div>
  `}function Qy({item:t,selected:e}){return o`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{Re.value=e?null:t.id,Qt.value=null,Zt.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.kind==="session"?t.target_id:t.linked_session_id??t.target_id}</div>
          <div class="mission-card-title">${t.summary}</div>
        </div>
        <span class="command-chip ${_s(t.severity)}">${vs(t.status??t.severity)}</span>
      </div>
      <div class="mission-card-meta">
        <span>${Uy(t.kind)}</span>
        ${t.linked_operation_id?o`<span>연결 작전 · ${t.linked_operation_id}</span>`:null}
        ${t.last_seen_at?o`<span><${Y} timestamp=${t.last_seen_at} /></span>`:null}
      </div>
      <${Tr} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function Zy({brief:t,selected:e}){const n=t.active_count??0,s=t.seen_count??n,a=t.planned_count??t.member_names.length;return o`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.session-card"
      onClick=${()=>{Qt.value=e?null:t.session_id,Zt.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          <div class="mission-card-title">${t.goal}</div>
        </div>
        <span class="command-chip ${_s(t.health??t.status)}">${vs(t.status)}</span>
      </div>
      <div class="mission-card-meta">
        <span>건강도 · ${vs(t.health??"ok")}</span>
        <span>live ${n} · seen ${s} · planned ${a}</span>
        ${t.linked_operation_id?o`<span>연결 작전 · ${t.linked_operation_id}</span>`:null}
        ${t.last_activity_at?o`<span><${Y} timestamp=${t.last_activity_at} /></span>`:null}
      </div>
      ${t.runtime_blocker?o`<div class="mission-card-detail">${t.runtime_blocker}</div>`:t.last_activity_summary?o`<div class="mission-card-detail">${t.last_activity_summary}</div>`:null}
      <div class="monitor-footnote">
        ${t.worker_gap_summary??`관측 기준 · ${t.counts_basis??"recent_turns"}`}
      </div>
      <${Tr} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function tb({brief:t,selected:e}){return o`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.operation-card"
      onClick=${()=>{Zt.value=e?null:t.operation_id,Qt.value=t.linked_session_id??null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.operation_id}${t.assigned_unit_label?` · ${t.assigned_unit_label}`:""}</div>
          <div class="mission-card-title">${t.objective}</div>
        </div>
        <span class="command-chip ${_s(t.blocker_summary?"warn":t.status)}">${vs(t.status)}</span>
      </div>
      <div class="mission-card-meta">
        ${t.stage?o`<span>단계 · ${t.stage}</span>`:null}
        ${t.linked_session_id?o`<span>세션 · ${t.linked_session_id}</span>`:null}
        ${t.updated_at?o`<span><${Y} timestamp=${t.updated_at} /></span>`:null}
      </div>
      ${t.blocker_summary?o`<div class="mission-card-detail">${t.blocker_summary}</div>`:null}
      ${t.next_tool?o`<div class="monitor-footnote">다음 도구 · ${t.next_tool}</div>`:null}
      <${Tr} command=${t.command_handoff} />
    </button>
  `}function eb({tick:t}){return t?o`
    <div class="monitor-nested-card">
      <div class="stats-grid">
        <${Pn} label="checked" value=${t.checked??0} color="#22d3ee" />
        <${Pn} label="acted" value=${t.acted??0} color="#4ade80" />
        <${Pn} label="passed" value=${t.passed??0} color="#94a3b8" />
        <${Pn} label="skipped" value=${t.skipped??0} color="#fbbf24" />
        <${Pn} label="failed" value=${t.failed??0} color="#fb7185" />
      </div>
      <div class="monitor-meta">
        ${t.last_tick_at?o`<span>마지막 tick <${Y} timestamp=${t.last_tick_at} /></span>`:o`<span>마지막 tick 없음</span>`}
        ${t.last_skip_reason?o`<span>대표 skip 이유 · ${t.last_skip_reason}</span>`:null}
      </div>
      ${t.activity_report?o`<div class="monitor-footnote">${t.activity_report}</div>`:null}
    </div>
  `:o`<div class="empty-state">최근 lodge tick 기록이 없습니다.</div>`}function nb({row:t}){return o`
    <button
      class="monitor-row ${_s(t.outcome==="failed"?"bad":t.outcome==="skipped"?"warn":"ok")}"
      data-testid="execution.lodge-checkin-card"
      onClick=${()=>Is(t.agent_name)}
    >
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.agent_name}</span>
            ${t.worker_name?o`<span class="monitor-sub">worker · ${t.worker_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.reason??t.summary??"이유가 기록되지 않았습니다."}</div>
        </div>
        <span class="monitor-pill ${_s(t.outcome==="failed"?"bad":t.outcome==="skipped"?"warn":"ok")}">${Yy(t.outcome)}</span>
      </div>
      <div class="monitor-meta">
        <span>trigger · ${t.trigger??"unknown"}</span>
        ${t.checked_at?o`<span><${Y} timestamp=${t.checked_at} /></span>`:null}
        <span>action · ${Xy(t.action_kind)}</span>
      </div>
      ${t.summary&&t.summary!==t.reason?o`<div class="monitor-focus">${t.summary}</div>`:null}
      ${t.failure_reason||t.decision_reason?o`<div class="monitor-footnote">
            ${t.failure_reason?`실패 이유: ${t.failure_reason}`:`판단 이유: ${t.decision_reason}`}
          </div>`:null}
    </button>
  `}function Zl({row:t,testId:e}){return o`
    <button class="monitor-row ${t.tone} state-${t.state}" data-testid=${e} onClick=${()=>Is(t.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.name}</span>
            ${t.korean_name?o`<span class="monitor-sub">${t.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${ke} status=${t.status??"unknown"} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${Wy(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.last_signal_at?o`<span>신호 <${Y} timestamp=${t.last_signal_at} /></span>`:o`<span>최근 신호 없음</span>`}
        <span>${Gy(t.signal_truth)} · ${Jy(t.evidence_source)}</span>
        ${typeof t.last_signal_age_sec=="number"?o`<span>${t.last_signal_age_sec}s ago</span>`:null}
        <span>${(t.active_task_count??0)>0?`활성 작업 ${t.active_task_count}개`:"활성 작업 없음"}</span>
        ${t.related_session_id?o`<span>세션 · ${t.related_session_id}</span>`:null}
        ${t.related_operation_id?o`<span>작전 · ${t.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${t.recent_output_preview&&t.recent_output_preview!==t.focus?o`<div class="monitor-footnote">최근 상세: ${t.recent_output_preview}</div>`:null}
    </button>
  `}function sb({row:t}){const e=()=>{const a=Hy(t.name);a&&Hd(a)},n=og(t.name,t.agent_name),s={name:t.name,koreanName:t.korean_name??null,runtimeLabel:n,emoji:t.emoji??null,tone:t.tone,statusRaw:t.status??null,statusLabel:vs(t.status),stateClass:t.state,stateLabel:Vy(t.state),contextRatio:t.context_ratio??null,note:t.note,focus:t.focus,lastActivityAt:t.last_signal_at??null,lastActivityFallback:"최근 활동 없음",relatedSessionId:t.related_session_id??null,continuity:t.continuity??null,lifecycle:t.lifecycle??null,summary:t.continuity_summary??t.recent_output_preview??null,recentInput:t.recent_input_preview??null,recentOutput:t.recent_output_preview??null,recentTools:t.recent_tool_names??[],allowedTools:t.allowed_tool_names??[],routeSummary:t.skill_route_summary??null,auditSource:t.tool_audit_source??null,auditAt:t.tool_audit_at??null,disclosureLabel:"연속성 상세"};return o`<${By}
    variant="execution"
    model=${s}
    onClick=${e}
    testId="execution.continuity-card"
  />`}function ab(){const t=jc.value,e=wc.value,n=Nc.value,s=Dc.value,a=Oc.value,i=qc.value,l=Xi.value,c=Fc.value;Re.value&&!t.some($=>$.id===Re.value)&&(Re.value=null),Qt.value&&!e.some($=>$.session_id===Qt.value)&&(Qt.value=null),Zt.value&&!n.some($=>$.operation_id===Zt.value)&&(Zt.value=null);const d=Re.value?t.find($=>$.id===Re.value)??null:null,p=Qt.value?Qt.value:d?d.kind==="session"?d.target_id:d.linked_session_id??null:null,_=Zt.value?Zt.value:d?d.kind==="operation"?d.target_id:d.linked_operation_id??null:null,v=p?e.filter($=>$.session_id===p):_?e.filter($=>$.linked_operation_id===_):e,f=_?n.filter($=>$.operation_id===_):p?n.filter($=>{var y;return $.linked_session_id===p||$.operation_id===((y=v[0])==null?void 0:y.linked_operation_id)}):n,h=p||_?s.filter($=>(p?$.related_session_id===p:!1)||(_?$.related_operation_id===_:!1)):s,T=p?l.filter($=>$.related_session_id===p||$.tone!=="ok"):l,k=p?i.filter($=>v.some(y=>y.member_names.includes($.agent_name))):i,C=p||_?c.filter($=>(p?$.related_session_id===p:!1)||(_?$.related_operation_id===_:!1)||$.tone!=="ok"):c;return o`
    <div class="agents-monitor">
      <${At} surfaceId="execution" />
      <${yr} />
      <${L}
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
          ${t.length===0?o`<div class="empty-state">지금은 막힌 실행이 없습니다.</div>`:t.map($=>o`<${Qy} key=${$.id} item=${$} selected=${Re.value===$.id} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${L}
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
            ${v.length===0?o`<div class="empty-state">선택된 실행과 연결된 세션이 없습니다.</div>`:v.map($=>o`<${Zy} key=${$.session_id} brief=${$} selected=${Qt.value===$.session_id} />`)}
          </div>
        <//>

        <${L}
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
            ${f.length===0?o`<div class="empty-state">선택된 실행과 연결된 작전이 없습니다.</div>`:f.map($=>o`<${tb} key=${$.operation_id} brief=${$} selected=${Zt.value===$.operation_id} />`)}
          </div>
        <//>

        <${L}
          title="Lodge Check-ins"
          class="section"
          semanticId="execution.lodge"
          testId="execution.lodge-checkins"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Lodge Check-ins</h2>
            <p class="monitor-subheadline">최근 lodge tick에서 누가 무엇을 허용받았고, 실제로 어떻게 행동했는지 먼저 보여줍니다.</p>
          </div>
          <${eb} tick=${a} />
          <div class="monitor-list">
            ${k.length===0?o`<div class="empty-state">최근 lodge check-in 기록이 없습니다.</div>`:k.map($=>o`<${nb} key=${`${$.agent_name}-${$.checked_at??$.outcome}`} row=${$} />`)}
          </div>
        <//>

        <${L}
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
            ${h.length===0?o`<div class="empty-state">연결된 작업자가 없습니다.</div>`:h.map($=>o`<${Zl} key=${$.name} row=${$} testId="execution.worker-card" />`)}
          </div>
        <//>

        <${L}
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
            ${T.length===0?o`<div class="empty-state">지금은 연속성 경고가 없습니다.</div>`:T.map($=>o`<${sb} key=${$.name} row=${$} />`)}
          </div>
        <//>

        <${L}
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
            ${C.length===0?o`<div class="empty-state">지금은 오프라인 작업자가 없습니다.</div>`:C.map($=>o`<${Zl} key=${$.name} row=${$} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const Mi=g(null),Pi=g(null),Wn=g(!1);async function tc(){if(!Wn.value){Wn.value=!0,Pi.value=null;try{Mi.value=await Lp()}catch(t){Pi.value=t instanceof Error?t.message:String(t)}finally{Wn.value=!1}}}function ob(t){switch(t){case"essential":return"badge-essential";case"standard":return"badge-standard";default:return"badge-full"}}function ib({items:t,maxCount:e}){return t.length===0?o`<p class="muted">No tool calls recorded yet.</p>`:o`
    <div class="tool-bar-chart">
      ${t.map(n=>{const s=e>0?n.call_count/e*100:0;return o`
          <div class="tool-bar-row" key=${n.name}>
            <span class="tool-bar-name">${n.name}</span>
            <span class="tool-bar-tier ${ob(n.tier)}">${n.tier}</span>
            <div class="tool-bar-track">
              <div class="tool-bar-fill" style=${{width:`${s}%`}} />
            </div>
            <span class="tool-bar-count">${n.call_count}</span>
          </div>
        `})}
    </div>
  `}function rb({dist:t}){const e=t.full,n=e>0?(t.essential/e*100).toFixed(1):"0",s=e>0?(t.standard/e*100).toFixed(1):"0",a=e-t.standard,i=e>0?(a/e*100).toFixed(1):"0";return o`
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
        <span class="tier-dist-pct">${i}%</span>
      </div>
    </div>
  `}function lb(){const t=Mi.value,e=Wn.value,n=Pi.value;return nt(()=>{!Mi.value&&!Wn.value&&tc()},[]),o`
    <div class="tool-metrics">
      <div class="tool-metrics-header">
        <h3 class="tool-metrics-title">Tool Usage</h3>
        <button
          class="control-btn ghost"
          onClick=${()=>void tc()}
          disabled=${e}
        >
          ${e?"Loading...":t?"Refresh":"Load"}
        </button>
      </div>

      ${n?o`<div class="tool-metrics-error">${n}</div>`:null}

      ${t?o`
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
            <${rb} dist=${t.tier_distribution} />
          </div>
          <div class="tool-metrics-section">
            <h4>Top 20 Tools</h4>
            <${ib}
              items=${t.top_20}
              maxCount=${t.top_20.length>0?t.top_20[0].call_count:0}
            />
          </div>
        </div>
      `:e?null:o`
        <p class="muted">Click Load to fetch tool usage statistics.</p>
      `}
    </div>
  `}const zi=g(null),Ei=g(null),Gn=g(!1),zn=g(""),Ws=g("all"),No=g(!1),Do=g(!1),Oo=g(!0),qo=g(!0);async function ec(){if(!Gn.value){Gn.value=!0,Ei.value=null;try{zi.value=await Mp()}catch(t){Ei.value=t instanceof Error?t.message:String(t)}finally{Gn.value=!1}}}function cb(t,e){const n=e.trim().toLowerCase();return n?[t.name,t.description,t.category,t.required_permission??"",t.visibility,t.lifecycle,t.implementationStatus,t.tier,t.canonicalName??"",t.replacement??"",t.reason??"",...t.doc_refs,...t.prompt_hints].join(" ").toLowerCase().includes(n):!0}function Gs(t,e="default"){return o`
    <span
      style=${{fontSize:"11px",color:e==="ok"?"#7dd3fc":e==="warn"?"#fbbf24":"#cbd5e1",background:e==="ok"?"rgba(14, 165, 233, 0.18)":e==="warn"?"rgba(245, 158, 11, 0.18)":"rgba(148, 163, 184, 0.16)",borderRadius:"999px",padding:"2px 8px"}}
    >
      ${t}
    </span>
  `}function db({item:t}){return o`
    <article class="tool-inventory-row">
      <div class="tool-inventory-head">
        <div>
          <div class="tool-inventory-name">${t.name}</div>
          <div class="tool-inventory-desc">${t.description}</div>
        </div>
        <div class="tool-inventory-badges">
          ${Gs(t.tier,t.tier==="essential"?"ok":t.tier==="standard"?"warn":"default")}
          ${Gs(t.visibility)}
          ${Gs(t.lifecycle,t.lifecycle==="deprecated"?"warn":"default")}
          ${Gs(t.implementationStatus)}
        </div>
      </div>
      <div class="tool-inventory-meta">
        <span>Category: <strong>${t.category}</strong></span>
        <span>Mode: <strong>${t.enabled_in_current_mode?"enabled":"disabled"}</strong></span>
        <span>Direct call: <strong>${t.direct_call_allowed?"allowed":"blocked"}</strong></span>
        <span>Permission: <strong>${t.required_permission??"none"}</strong></span>
      </div>
      ${t.reason?o`<div class="tool-inventory-reason">${t.reason}</div>`:null}
      <div class="tool-inventory-links">
        ${t.canonicalName?o`<span>Canonical: <strong>${t.canonicalName}</strong></span>`:null}
        ${t.replacement?o`<span>Replacement: <strong>${t.replacement}</strong></span>`:null}
        ${t.doc_refs.length>0?o`<span>Docs: <strong>${t.doc_refs.join(", ")}</strong></span>`:null}
      </div>
    </article>
  `}function ub(){const t=zi.value,e=Gn.value,n=Ei.value,s=(t==null?void 0:t.tool_inventory.tools)??[],a=(t==null?void 0:t.tool_usage)??null;nt(()=>{!zi.value&&!Gn.value&&ec()},[]),nt(()=>{var h;if(D.value.tab!=="tools")return;const f=(h=D.value.params.q)==null?void 0:h.trim();f&&f!==zn.value&&(zn.value=f)},[D.value.tab,D.value.params.q]);const i=Array.from(new Set(s.map(f=>f.category))).sort((f,h)=>f.localeCompare(h)),l=s.filter(f=>!(!cb(f,zn.value)||Ws.value!=="all"&&f.category!==Ws.value||No.value&&!f.enabled_in_current_mode||Do.value&&!f.direct_call_allowed||!Oo.value&&f.visibility==="hidden"||!qo.value&&f.lifecycle==="deprecated")),c=s.length,d=s.filter(f=>f.enabled_in_current_mode).length,p=s.filter(f=>f.visibility==="hidden").length,_=s.filter(f=>f.lifecycle==="deprecated").length,v=s.filter(f=>f.direct_call_allowed).length;return o`
    <div>
      <${L} title="System Tool Inventory" class="section">
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
            <span class="stat-value">${p}</span>
            <span class="stat-label">Hidden</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${_}</span>
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
            value=${zn.value}
            onInput=${f=>{zn.value=f.target.value}}
          />
          <select
            class="control-select"
            value=${Ws.value}
            onChange=${f=>{Ws.value=f.target.value}}
          >
            <option value="all">All categories</option>
            ${i.map(f=>o`<option value=${f}>${f}</option>`)}
          </select>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${No.value}
              onChange=${f=>{No.value=f.target.checked}}
            />
            <span>Enabled only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${Do.value}
              onChange=${f=>{Do.value=f.target.checked}}
            />
            <span>Direct-call only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${Oo.value}
              onChange=${f=>{Oo.value=f.target.checked}}
            />
            <span>Show hidden</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${qo.value}
              onChange=${f=>{qo.value=f.target.checked}}
            />
            <span>Show deprecated</span>
          </label>
          <button class="control-btn ghost" onClick=${()=>{ec()}} disabled=${e}>
            ${e?"Refreshing…":"Refresh inventory"}
          </button>
        </div>

        ${n?o`<div class="tool-metrics-error">${n}</div>`:null}

        <div class="tool-inventory-list">
          ${l.length>0?l.map(f=>o`<${db} key=${f.name} item=${f} />`):o`<div class="empty-state">No tools matched the current filters.</div>`}
        </div>
      <//>

      <${L} title="Tool Usage" class="section">
        ${a?o`
              <div class="tool-inventory-usage-hint">
                Registered ${a.registered_count} · Distinct called ${a.distinct_tools_called} · Never called ${a.never_called_count}
              </div>
            `:null}
        <${lb} />
      <//>
    </div>
  `}const Va=g("all"),Ya=g("all"),ji=g(new Set);function pb(t){const e=new Set(ji.value);e.has(t)?e.delete(t):e.add(t),ji.value=e}const gu=Et(()=>{let t=cn.value;return Va.value!=="all"&&(t=t.filter(e=>e.horizon===Va.value)),Ya.value!=="all"&&(t=t.filter(e=>e.status===Ya.value)),t}),mb=Et(()=>{const t={short:[],mid:[],long:[]};for(const e of gu.value){const n=t[e.horizon];n&&n.push(e)}return t}),_b=Et(()=>{const t=Array.from(Bc.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function vb(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function Ir(t){switch(t){case"short":return"단기";case"mid":return"중기";case"long":return"장기";default:return t}}function ma(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function fb(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function nc(t){return t.toFixed(4)}function sc(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function gb(t){switch(t){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function $b(t){switch(t){case"active":return"진행 중";case"completed":return"완료";case"paused":return"일시정지";default:return"전체"}}function ac(t,e){return(t.priority??4)-(e.priority??4)}function hb(t,e){const n=t.updated_at??t.created_at??"";return(e.updated_at??e.created_at??"").localeCompare(n)}function yb(t,e){return t.length<=e?t:t.slice(0,e)+"..."}function bb({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ma(t.horizon)}">
            ${Ir(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${vb(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${Y} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${ke} status=${t.status} />
        <div class="goal-updated">
          <${Y} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Fo({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${L} title="${Ir(t)} 목표 (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>o`<${bb} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function kb(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">범위</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Va.value===t?"active":""}"
            onClick=${()=>{Va.value=t}}
          >
            ${t==="all"?"전체":Ir(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">상태</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Ya.value===t?"active":""}"
            onClick=${()=>{Ya.value=t}}
          >
            ${$b(t)}
          </button>
        `)}
      </div>
    </div>
  `}function xb(){const t=cn.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${ma("short")}">${s.short}</div>
        <div class="goal-summary-label">단기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ma("mid")}">${s.mid}</div>
        <div class="goal-summary-label">중기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ma("long")}">${s.long}</div>
        <div class="goal-summary-label">장기</div>
      </div>
    </div>
  `}function Sb({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length}개 도구: ${t.latest_tool_names.join(", ")}`:"아직 근거 없음";return o`
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
          <span>Baseline ${nc(t.baseline_metric)}</span>
          <span>현재 ${nc(t.current_metric)}</span>
          <span class=${sc(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${sc(t)}
          </span>
          <span>Elapsed ${fb(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"명시된 목표가 없습니다"}</div>
        ${t.stop_reason||t.error_message?o`
              <div class="planning-loop-footnote">
                ${t.error_message??t.stop_reason}
              </div>
            `:null}
        <div class="planning-loop-footnote">
          ${t.strict_mode?"엄격 근거 모드":"레거시"} · ${t.worker_engine??"엔진 정보 없음"} · ${n}
        </div>
        ${e?o`
              <div class="planning-loop-footnote">
                최근 반복 #${e.iteration}: ${e.changes||e.next_suggestion||"서술 정보 없음"}
              </div>
            `:o`<div class="planning-loop-footnote">반복 이력이 아직 없습니다</div>`}
      </div>
    </div>
  `}function Ko({task:t}){const e=t.priority??4,n=e<=1?"p1":e===2?"p2":e===3?"p3":"p4",s=ji.value.has(t.id),a=!!t.description;return o`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${gb(e)}</span>
        <div class="kanban-card-title">${t.title}</div>
      </div>
      ${a?o`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>pb(t.id)}
        >
          ${s?t.description:yb(t.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${t.created_at?o`<${Y} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Cb(){const{todo:t,inProgress:e,done:n}=Hc.value,s=[...t].sort(ac),a=[...e].sort(ac),i=[...n].sort(hb);return o`
    <${L} title="태스크 백로그" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>할 일</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${s.length===0?o`<div class="empty-state" style="opacity: 0.5;">대기 중인 태스크가 없습니다</div>`:s.map(l=>o`<${Ko} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>진행 중</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${a.length===0?o`<div class="empty-state" style="opacity: 0.5;">진행 중인 태스크가 없습니다</div>`:a.map(l=>o`<${Ko} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>완료</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${i.length===0?o`<div class="empty-state" style="opacity: 0.5;">완료된 태스크가 없습니다</div>`:i.slice(0,20).map(l=>o`<${Ko} key=${l.id} task=${l} />`)}
          ${i.length>20?o`<div class="empty-state" style="opacity: 0.5;">...외 ${i.length-20}개 더 있음</div>`:null}
        </div>
      </div>
    <//>
  `}function Ab(){const{todo:t,inProgress:e,done:n}=Hc.value,s=t.length+e.length+n.length,a=[...t,...e].filter(_=>(_.priority??4)<=2).length,i=mb.value,l=_b.value,c=cn.value.length>0,d=l.length>0,p=Qi.value;return o`
    <div>
      <${At} surfaceId="planning" />

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
          onClick=${()=>{er(),Xc()}}
          disabled=${On.value||qn.value}
        >
          ${On.value||qn.value?"새로고침 중...":"계획 데이터 새로고침"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${Cb} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          목표 파이프라인
          <span class="monitor-pill">${cn.value.length}</span>
        </summary>
        <div>
          ${c?o`
            <${xb} />
            <${kb} />
            ${On.value&&cn.value.length===0?o`<div class="loading-indicator">목표 불러오는 중...</div>`:gu.value.length===0?o`<div class="empty-state">현재 필터에 맞는 목표가 없습니다</div>`:o`
                    <${Fo} horizon="short" items=${i.short??[]} />
                    <${Fo} horizon="mid" items=${i.mid??[]} />
                    <${Fo} horizon="long" items=${i.long??[]} />
                  `}
          `:o`
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
          ${qn.value&&l.length===0?o`<div class="loading-indicator">MDAL 루프 불러오는 중...</div>`:l.length===0&&(p==="error"||dn.value)?o`<div class="empty-state">MDAL 스냅샷을 불러오지 못했습니다${dn.value?`: ${dn.value}`:""}. 백엔드 상태를 확인하세요.</div>`:l.length===0?o`<div class="empty-state">가동 중인 루프가 없습니다. <code>masc_mdal_start</code>로 시작할 수 있습니다.</div>`:o`
                  <div class="planning-loop-list">
                    ${l.map(_=>o`<${Sb} key=${_.loop_id} loop=${_} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const Xa=g(!1),Jn=g(!1),rn=g(!1),ye=g(""),Vn=g(""),wi=g("open"),St=g(null),fs=g(null),Qa=g(null),Za=g(null),Ni=g(!1);function gs(t){return`${t.kind}:${t.id}`}function Rr(){var n;const t=fs.value,e=((n=St.value)==null?void 0:n.items)??[];return t?e.find(s=>gs(s)===t)??null:null}function Tb(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");return(e==null?void 0:e.trim())||"dashboard"}function Ib(t){const e=t.trim().toLowerCase();return e==="open"||e==="pending"}function $u(t){return!!(t.judgment_summary&&t.judgment_summary.trim())}function hu(t){switch(wi.value){case"needs_quorum":return t.filter(e=>e.kind==="consensus"&&(e.votes??0)<(e.quorum??0));case"ready":return t.filter(e=>{var n;return(n=e.guardrail_state)==null?void 0:n.ready_to_execute});case"needs_approval":return t.filter(e=>{var n,s;return((n=e.guardrail_state)==null?void 0:n.requires_human_gate)||!!((s=e.guardrail_state)!=null&&s.pending_confirm)});case"judge_offline":return t.filter(e=>!$u(e));case"open":default:return t.filter(e=>Ib(e.status))}}function Rb(t){if(t==null)return"없음";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function vo(t){const e=(t||"").toLowerCase();return e.includes("reject")||e.includes("deny")||e.includes("closed")||e.includes("cancel")?"negative":e.includes("approve")||e.includes("support")||e.includes("open")||e.includes("ready")?"positive":"neutral"}function Lb(t){return typeof t!="number"||Number.isNaN(t)?"확인 필요":`${Math.round(t*100)}%`}function En(t){return"resolved_tool"in t||"payload_preview"in t||"reason"in t}async function yu(t){if(Qa.value=null,Za.value=null,!!t){Ni.value=!0,ye.value="";try{t.kind==="debate"?Qa.value=await xm(t.id):Za.value=await Sm(t.id)}catch(e){ye.value=e instanceof Error?e.message:"거버넌스 상세를 불러오지 못했습니다"}finally{Ni.value=!1}}}async function Mb(t){fs.value=gs(t),await yu(t)}async function xn(){var t;Xa.value=!0,ye.value="";try{const e=await xp();St.value=e;const n=hu(e.items??[]),s=fs.value,a=n.find(i=>gs(i)===s)??n[0]??((t=e.items)==null?void 0:t[0])??null;fs.value=a?gs(a):null,await yu(a)}catch(e){ye.value=e instanceof Error?e.message:"거버넌스 상태를 불러오지 못했습니다"}finally{Xa.value=!1}}B_(xn);async function oc(){const t=Vn.value.trim();if(t){Jn.value=!0;try{const e=await km(t);Vn.value="",j(e!=null&&e.id?`토론을 시작했습니다: ${e.id}`:"토론을 시작했습니다","success"),await xn()}catch(e){const n=e instanceof Error?e.message:"토론 시작에 실패했습니다";ye.value=n,j(n,"error")}finally{Jn.value=!1}}}async function ic(t){var i,l;const e=Rr(),n=(i=e==null?void 0:e.guardrail_state)==null?void 0:i.pending_confirm,s=n==null?void 0:n.confirm_token;if(!s)return;const a=((l=n==null?void 0:n.actor)==null?void 0:l.trim())||Tb();rn.value=!0;try{await Cc(a,s,t),j(t==="confirm"?"액션을 승인했습니다":"액션을 거부했습니다","success"),await xn()}catch(c){const d=c instanceof Error?c.message:"대기 중인 액션 처리에 실패했습니다";ye.value=d,j(d,"error")}finally{rn.value=!1}}function Pb(){var s,a,i,l,c,d,p,_,v;const t=(s=St.value)==null?void 0:s.summary,e=(a=St.value)==null?void 0:a.judge,n=hs({pending_confirm_envelope:(i=St.value)==null?void 0:i.pending_confirm_envelope,pending_confirm_summary:(l=St.value)==null?void 0:l.pending_confirm_summary,pending_confirms:(c=St.value)==null?void 0:c.pending_actions});return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">열린 토론</span>
        <strong>${(t==null?void 0:t.debates_open)??((p=(d=St.value)==null?void 0:d.debates)==null?void 0:p.length)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">합의 세션</span>
        <strong>${(t==null?void 0:t.sessions_active)??((v=(_=St.value)==null?void 0:_.sessions)==null?void 0:v.length)??0}</strong>
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
        <span class="board-summary-label">승인 대기</span>
        <strong>${n.hidden_count>0?`${n.visible_count}/${n.total_count}`:n.total_count}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">판정기</span>
        <strong>${(e==null?void 0:e.judge_online)??(t==null?void 0:t.judge_online)?"온라인":"오프라인"}</strong>
      </div>
    </div>
  `}function zb(){return o`
    <${L} title="거버넌스 콘솔" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="토론 주제를 입력하세요..."
            value=${Vn.value}
            onInput=${t=>{Vn.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&oc()}}
            disabled=${Jn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${oc}
            disabled=${Jn.value||Vn.value.trim()===""}
          >
            ${Jn.value?"시작 중...":"토론 시작"}
          </button>
          <button class="control-btn ghost" onClick=${xn} disabled=${Xa.value}>
            ${Xa.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
        <div class="governance-filter-row">
          ${[["open","열림"],["needs_quorum","정족수 부족"],["ready","준비됨"],["needs_approval","승인 필요"],["judge_offline","판정기 오프라인"]].map(([t,e])=>o`
            <button
              class="control-btn ${wi.value===t?"is-active":"ghost"}"
              onClick=${async()=>{wi.value=t,await xn()}}
            >
              ${e}
            </button>
          `)}
        </div>
        ${ye.value?o`<div class="council-error">${ye.value}</div>`:null}
      </div>
    <//>
  `}function Eb(){var e;const t=hu(((e=St.value)==null?void 0:e.items)??[]);return o`
    <${L} title="의사결정 수신함" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${t.length===0?o`
              <div class="empty-state">
                지금 필터에 맞는 토론이나 합의 세션이 없습니다.
              </div>
            `:t.map(n=>{var a,i;const s=fs.value===gs(n);return o`
                <button
                  class="council-row governance-decision-row ${s?"selected":""}"
                  onClick=${()=>Mb(n)}
                >
                  <div class="council-row-main">
                    <div class="governance-row-head">
                      <span class="governance-kind">${n.kind}</span>
                      <span class="council-topic">${n.topic}</span>
                    </div>
                    <div class="council-sub">
                      <span>${n.truth_summary||"사실 요약이 아직 없습니다"}</span>
                      ${n.last_activity_at?o`<span><${Y} timestamp=${n.last_activity_at} /></span>`:null}
                    </div>
                    <div class="governance-chip-row">
                      ${(a=n.guardrail_state)!=null&&a.requires_human_gate?o`<span class="governance-chip warn">승인 필요</span>`:null}
                      ${(i=n.guardrail_state)!=null&&i.ready_to_execute?o`<span class="governance-chip ok">준비됨</span>`:null}
                      ${n.kind==="consensus"&&(n.votes??0)<(n.quorum??0)?o`<span class="governance-chip warn">정족수 부족</span>`:null}
                      ${$u(n)?null:o`<span class="governance-chip dim">판정기 오프라인</span>`}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${vo(n.status)}">${n.status}</span>
                    ${n.kind==="consensus"?o`<span class="governance-vote-meter">${n.votes??0}/${n.quorum??0}</span>`:o`<span class="governance-vote-meter">${n.evidence_refs.length} refs</span>`}
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function jb({argument:t}){return o`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${vo(t.position)}">${t.position}</span>
        <strong>${t.agent}</strong>
        ${t.created_at?o`<span><${Y} timestamp=${t.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${t.content}</div>
      <div class="governance-chip-row">
        ${t.evidence.map(e=>o`<span class="governance-chip">${e}</span>`)}
        ${t.reply_to!=null?o`<span class="governance-chip">답글 #${t.reply_to}</span>`:null}
        ${t.mentions.map(e=>o`<span class="governance-chip">@${e}</span>`)}
        ${t.archetype?o`<span class="governance-chip dim">${t.archetype}</span>`:null}
      </div>
    </div>
  `}function wb({vote:t}){return o`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${vo(t.decision)}">${t.decision}</span>
        <strong>${t.agent}</strong>
        ${t.timestamp?o`<span><${Y} timestamp=${t.timestamp} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${t.reason||"기록된 이유가 없습니다."}</div>
      <div class="governance-chip-row">
        ${t.weight!=null?o`<span class="governance-chip">가중치 ${t.weight}</span>`:null}
        ${t.archetype?o`<span class="governance-chip dim">${t.archetype}</span>`:null}
      </div>
    </div>
  `}function Nb(){const t=Rr(),e=Qa.value,n=Za.value;return o`
    <${L}
      title=${t?`${t.kind==="debate"?"토론":"합의"} 상세`:"의사결정 상세"}
      class="section"
      semanticId="governance.detail"
    >
      ${Ni.value?o`<div class="loading-indicator">거버넌스 상세 불러오는 중...</div>`:t?t.kind==="debate"&&e?o`
                <div class="governance-detail-head">
                  <div>
                    <h3>${e.debate.topic}</h3>
                    <div class="council-sub">
                      <span>${e.debate.id}</span>
                      <span>${e.debate.status}</span>
                      ${e.debate.created_at?o`<span><${Y} timestamp=${e.debate.created_at} /></span>`:null}
                    </div>
                  </div>
                  <div class="governance-balance-grid">
                    <span class="governance-balance"><strong>${e.summary.support_count}</strong> support</span>
                    <span class="governance-balance"><strong>${e.summary.oppose_count}</strong> oppose</span>
                    <span class="governance-balance"><strong>${e.summary.neutral_count}</strong> neutral</span>
                    <span class="governance-balance"><strong>${e.summary.total_arguments}</strong> total</span>
                  </div>
                </div>
                ${e.summary.summary_text?o`<div class="governance-summary-callout">${e.summary.summary_text}</div>`:null}
                <div class="governance-ledger">
                  ${e.arguments.length===0?o`<div class="empty-state">기록된 토론이 아직 없습니다.</div>`:e.arguments.map(s=>o`<${jb} key=${s.index} argument=${s} />`)}
                </div>
              `:t.kind==="consensus"&&n?o`
                  <div class="governance-detail-head">
                    <div>
                      <h3>${n.session.topic}</h3>
                      <div class="council-sub">
                        <span>${n.session.id}</span>
                        <span>${n.session.state}</span>
                      <span>시작자 ${n.session.initiator}</span>
                        ${n.session.created_at?o`<span><${Y} timestamp=${n.session.created_at} /></span>`:null}
                      </div>
                    </div>
                    <div class="governance-balance-grid">
                      <span class="governance-balance"><strong>${n.summary.approve_count}</strong> approve</span>
                      <span class="governance-balance"><strong>${n.summary.reject_count}</strong> reject</span>
                      <span class="governance-balance"><strong>${n.summary.abstain_count}</strong> abstain</span>
                      <span class="governance-balance"><strong>${n.session.quorum}</strong> quorum</span>
                    </div>
                  </div>
                  ${n.summary.result?o`<div class="governance-summary-callout">${n.summary.result}</div>`:null}
                  <div class="governance-ledger">
                    ${n.votes.length===0?o`<div class="empty-state">기록된 표결이 아직 없습니다.</div>`:n.votes.map(s=>o`<${wb} key=${s.agent+s.timestamp} vote=${s} />`)}
                  </div>
                `:o`<div class="empty-state">이 의사결정의 상세를 아직 읽을 수 없습니다.</div>`:o`<div class="empty-state">사실 계층과 판단을 보려면 의사결정 항목을 고르세요.</div>`}
    <//>
  `}function rc({title:t,route:e}){if(!e)return null;const n=En(e)?e.resolved_tool:e.delegated_tool,s=En(e)?e.target_type:null,a=En(e)?e.target_id:null,i=En(e)?e.reason:null,l=En(e)?e.payload_preview:null;return o`
    <div class="governance-side-block">
      <h4>${t}</h4>
      <div class="council-sub">
        ${n?o`<span>도구 ${n}</span>`:null}
        ${"action_type"in e&&e.action_type?o`<span>액션 ${e.action_type}</span>`:null}
        ${"confirmation_state"in e&&e.confirmation_state?o`<span>${e.confirmation_state}</span>`:null}
        ${"created_at"in e&&e.created_at?o`<span><${Y} timestamp=${e.created_at} /></span>`:null}
      </div>
      ${s?o`<div class="governance-side-line">대상 ${s}${a?`:${a}`:""}</div>`:null}
      ${i?o`<div class="governance-side-line">${i}</div>`:null}
      ${l?o`<pre class="council-detail governance-preview">${Rb(l)}</pre>`:null}
    </div>
  `}function Db(){var c,d,p;const t=Rr(),e=Qa.value,n=Za.value,s=(e==null?void 0:e.context)??(n==null?void 0:n.context)??(t==null?void 0:t.context),a=(e==null?void 0:e.judgment)??(n==null?void 0:n.judgment),i=t==null?void 0:t.guardrail_state,l=(c=St.value)==null?void 0:c.judge;return o`
    <div class="governance-side-column">
      <${L} title="이유 / 가드레일" class="section" semanticId="governance.guardrail">
        ${t?o`
              <div class="governance-side-block">
                <h4>판정기</h4>
                <div class="council-sub">
                  <span>${l!=null&&l.judge_online?"온라인":"오프라인"}</span>
                  ${l!=null&&l.model_used?o`<span>${l.model_used}</span>`:null}
                  ${l!=null&&l.generated_at?o`<span><${Y} timestamp=${l.generated_at} /></span>`:null}
                </div>
                ${t.judgment_summary?o`<div class="governance-summary-callout">${t.judgment_summary}</div>`:o`<div class="governance-side-line">현재 LLM 판단이 없어 사실 계층만 보여줍니다.</div>`}
                <div class="council-sub">
                  <span>신뢰도 ${Lb(t.confidence)}</span>
                  ${a!=null&&a.keeper_name?o`<span>${a.keeper_name}</span>`:null}
                </div>
              </div>

              <${rc} title="추천 경로" route=${t.recommended_action} />
              <${rc} title="실행된 경로" route=${t.executed_route} />

              <div class="governance-side-block">
                <h4>가드레일 상태</h4>
                <div class="council-sub">
                  <span>${i!=null&&i.requires_human_gate?"사람 승인 필요":"사람 승인 없음"}</span>
                  ${i!=null&&i.ready_to_execute?o`<span>실행 준비됨</span>`:null}
                </div>
                ${i!=null&&i.pending_confirm?o`
                      <div class="governance-side-line">
                        대기 중 ${i.pending_confirm.action_type||"액션"}
                        ${i.pending_confirm.target_type?` · ${i.pending_confirm.target_type}`:""}
                      </div>
                      <div class="governance-action-row">
                        <button
                          class="control-btn secondary"
                          onClick=${()=>ic("confirm")}
                          disabled=${rn.value}
                        >
                          ${rn.value?"처리 중...":"승인"}
                        </button>
                        <button
                          class="control-btn ghost"
                          onClick=${()=>ic("deny")}
                          disabled=${rn.value}
                        >
                          ${rn.value?"처리 중...":"거부"}
                        </button>
                      </div>
                    `:o`<div class="governance-side-line">이 의사결정에 대기 중인 사람 승인은 없습니다.</div>`}
              </div>
            `:o`<div class="empty-state">판단과 경로를 보려면 의사결정을 고르세요.</div>`}
      <//>

      <${L} title="맥락" class="section" semanticId="governance.context">
        ${t?o`
              <div class="governance-side-block">
                <div class="governance-chip-row">
                  ${s!=null&&s.board_post_id?o`<span class="governance-chip">board ${s.board_post_id}</span>`:null}
                  ${s!=null&&s.task_id?o`<span class="governance-chip">task ${s.task_id}</span>`:null}
                  ${s!=null&&s.operation_id?o`<span class="governance-chip">작전 ${s.operation_id}</span>`:null}
                  ${s!=null&&s.team_session_id?o`<span class="governance-chip">session ${s.team_session_id}</span>`:null}
                </div>
                ${t.related_agents.length>0?o`
                      <div class="governance-side-line">관련 에이전트</div>
                      <div class="governance-chip-row">
                        ${t.related_agents.map(_=>o`<span class="governance-chip dim">${_}</span>`)}
                      </div>
                    `:o`<div class="governance-side-line">명시적으로 연결된 맥락 기록이 없습니다.</div>`}
                ${t.evidence_refs.length>0?o`
                      <div class="governance-side-line">근거 참조</div>
                      <div class="governance-chip-row">
                        ${t.evidence_refs.map(_=>o`<span class="governance-chip">${_}</span>`)}
                      </div>
                    `:null}
              </div>
          `:o`<div class="empty-state">선택된 맥락이 없습니다.</div>`}
      <//>

      <${L} title="최근 활동" class="section" semanticId="governance.activity">
        <div class="governance-activity-list">
          ${(((d=St.value)==null?void 0:d.activity)??[]).slice(0,8).map(_=>o`
            <div class="governance-activity-row">
              <div class="governance-ledger-head">
                <span class="governance-badge ${vo(_.kind)}">${_.kind}</span>
                ${_.actor?o`<strong>${_.actor}</strong>`:null}
                ${_.created_at?o`<span><${Y} timestamp=${_.created_at} /></span>`:null}
              </div>
              <div class="governance-ledger-body">${_.summary||_.topic||"활동이 기록되었습니다."}</div>
            </div>
          `)}
          ${(((p=St.value)==null?void 0:p.activity)??[]).length===0?o`<div class="empty-state">기록된 거버넌스 활동이 없습니다.</div>`:null}
        </div>
      <//>
    </div>
  `}function Ob(){return nt(()=>{xn()},[]),o`
    <div>
      <${At} surfaceId="governance" />
      <${Pb} />
      <${zb} />
      <div class="governance-layout">
        <${Eb} />
        <${Nb} />
        <${Db} />
      </div>
    </div>
  `}const Xe=g(""),Bo=g("ability_check"),Uo=g("10"),Ho=g("12"),Js=g(""),Vs=g("idle"),le=g(""),Ys=g("keeper-late"),Wo=g("player"),Go=g(""),Rt=g("idle"),Jo=g(null),Xs=g(""),Vo=g(""),Yo=g("player"),Xo=g(""),Qo=g(""),Zo=g(""),Yn=g("20"),ti=g("20"),ei=g(""),Qs=g("idle"),Di=g(null),bu=g("overview"),ni=g("all"),si=g("all"),ai=g("all"),qb=12e4,fo=g(null),lc=g(Date.now());function Fb(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Kb(t,e){return e>0?Math.round(t/e*100):0}const Bb={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Ub={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Zs(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Hb(t){const e=t.trim().toLowerCase();return Bb[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Wb(t){const e=t.trim().toLowerCase();return Ub[e]??"상황에 따라 선택되는 전술 액션입니다."}function xt(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Dt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function $s(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const Gb=new Set(["str","dex","con","int","wis","cha"]);function Jb(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!m(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const l=a.trim();if(l){if(typeof i=="number"&&Number.isFinite(i)){s[l]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const c=Number.parseFloat(i.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function Vb(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(Yn.value.trim(),10);Number.isFinite(s)&&s>n&&(Yn.value=String(n))}function Oi(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Yb(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Xb(t){bu.value=t}function ku(t){const e=fo.value;return e==null||e<=t}function Qb(t){const e=fo.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function to(){fo.value=null}function xu(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Zb(t,e){xu(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(fo.value=Date.now()+qb,j("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function _a(t){return ku(t)?(j("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function qi(t,e,n){return xu([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function tk({hp:t,max:e}){const n=Kb(t,e),s=Fb(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function ek({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function nk({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Su({actor:t}){var d,p,_,v;const e=(d=t.archetype)==null?void 0:d.trim(),n=(p=t.persona)==null?void 0:p.trim(),s=(_=t.portrait)==null?void 0:_.trim(),a=(v=t.background)==null?void 0:v.trim(),i=t.traits??[],l=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([f,h])=>Number.isFinite(h)).filter(([f])=>!Gb.has(f.toLowerCase()));return o`
    <div class="trpg-actor">
      ${s?o`
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
        <${ke} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${nk} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${tk} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${ek} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${Zs(e)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([f,h])=>o`
                <span class="trpg-custom-stat-chip">${Zs(f)} ${h}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(f=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Zs(f)}</span>
                  <span class="trpg-annot-desc">${Hb(f)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${l.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${l.map(f=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Zs(f)}</span>
                  <span class="trpg-annot-desc">${Wb(f)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function sk({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Cu({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Yb(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Oi(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${Y} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function ak({events:t}){const e="__none__",n=ni.value,s=si.value,a=ai.value,i=Array.from(new Set(t.map(Oi).map(v=>v.trim()).filter(v=>v!==""))).sort((v,f)=>v.localeCompare(f)),l=Array.from(new Set(t.map(v=>(v.type??"").trim()).filter(v=>v!==""))).sort((v,f)=>v.localeCompare(f)),c=t.some(v=>(v.type??"").trim()===""),d=Array.from(new Set(t.map(v=>(v.phase??"").trim()).filter(v=>v!==""))).sort((v,f)=>v.localeCompare(f)),p=t.some(v=>(v.phase??"").trim()===""),_=t.filter(v=>{if(n!=="all"&&Oi(v)!==n)return!1;const f=(v.type??"").trim(),h=(v.phase??"").trim();if(s===e){if(f!=="")return!1}else if(s!=="all"&&f!==s)return!1;if(a===e){if(h!=="")return!1}else if(a!=="all"&&h!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${v=>{ni.value=v.target.value}}>
          <option value="all">all</option>
          ${i.map(v=>o`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${v=>{si.value=v.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${e}>(none)</option>`:null}
          ${l.map(v=>o`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${v=>{ai.value=v.target.value}}>
          <option value="all">all</option>
          ${p?o`<option value=${e}>(none)</option>`:null}
          ${d.map(v=>o`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{ni.value="all",si.value="all",ai.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${_.length} / 전체 ${t.length}
      </span>
    </div>
    <${Cu} events=${_.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function ok({outcome:t}){if(!t)return null;const e=i=>{const l=i.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function Au({state:t}){const e=t.history??[];return e.length===0?null:o`
    <div class="trpg-round-list">
      ${e.slice(-10).map(n=>o`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
  `}function ik({state:t,nowMs:e}){var p;const n=ne.value||((p=t.session)==null?void 0:p.room)||"",s=Vs.value,a=t.party??[];if(!a.find(_=>_.id===Xe.value)&&a.length>0){const _=a[0];_&&(Xe.value=_.id)}const l=async()=>{var v,f;if(!n){j("Room ID가 비어 있습니다.","error");return}if(!_a(e))return;const _=((v=t.current_round)==null?void 0:v.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(qi("라운드 실행",n,_)){Vs.value="running";try{const h=await um(n);Di.value=h,Vs.value="ok";const T=m(h.summary)?h.summary:null,k=T?$s(T,"advanced",!1):!1,C=T?xt(T,"progress_reason",""):"";j(k?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${C?`: ${C}`:""}`,k?"success":"warning"),_e()}catch(h){Di.value=null,Vs.value="error";const T=h instanceof Error?h.message:"라운드 실행에 실패했습니다.";j(T,"error")}finally{to()}}},c=async()=>{var v,f;if(!n||!_a(e))return;const _=((v=t.current_round)==null?void 0:v.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(qi("턴 강제 진행",n,_))try{await _m(n),j("턴을 다음 단계로 이동했습니다.","success"),_e()}catch{j("턴 이동에 실패했습니다.","error")}finally{to()}},d=async()=>{if(!n||!_a(e))return;const _=Xe.value.trim();if(!_){j("먼저 Actor를 선택하세요.","warning");return}const v=Number.parseInt(Uo.value,10),f=Number.parseInt(Ho.value,10);if(Number.isNaN(v)||Number.isNaN(f)){j("stat/dc는 숫자여야 합니다.","warning");return}const h=Number.parseInt(Js.value,10),T=Js.value.trim()===""||Number.isNaN(h)?void 0:h;try{await mm({roomId:n,actorId:_,action:Bo.value.trim()||"ability_check",statValue:v,dc:f,rawD20:T}),j("주사위 판정을 기록했습니다.","success"),_e()}catch{j("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${_=>{ne.value=_.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Xe.value}
            onChange=${_=>{Xe.value=_.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(_=>o`<option value=${_.id}>${_.name} (${_.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${Bo.value}
              onInput=${_=>{Bo.value=_.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Uo.value}
              onInput=${_=>{Uo.value=_.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ho.value}
              onInput=${_=>{Ho.value=_.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Js.value}
              onInput=${_=>{Js.value=_.target.value}}
              onKeyDown=${_=>{_.key==="Enter"&&d()}}
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

      ${s!=="idle"?o`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function rk({state:t}){var a;const e=ne.value||((a=t.session)==null?void 0:a.room)||"",n=Qs.value,s=async()=>{if(!e){j("Room ID가 비어 있습니다.","warning");return}const i=Xs.value.trim(),l=Vo.value.trim();if(!l&&!i){j("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Yn.value.trim(),10),d=Number.parseInt(ti.value.trim(),10),p=Number.isFinite(d)?Math.max(1,d):20,_=Number.isFinite(c)?Math.max(0,Math.min(p,c)):p;let v={};try{v=Jb(ei.value)}catch(f){j(f instanceof Error?f.message:"능력치 JSON 오류","error");return}Qs.value="spawning";try{const f=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,h=await vm(e,{actor_id:i||void 0,name:l||void 0,role:Yo.value,idempotencyKey:f,portrait:Qo.value.trim()||void 0,background:Zo.value.trim()||void 0,hp:_,max_hp:p,alive:_>0,stats:Object.keys(v).length>0?v:void 0}),T=typeof h.actor_id=="string"?h.actor_id.trim():"";if(!T)throw new Error("생성 응답에 actor_id가 없습니다.");const k=Xo.value.trim();k&&await fm(e,T,k),Xe.value=T,le.value=T,i||(Xs.value=""),Qs.value="ok",j(`Actor 생성 완료: ${T}`,"success"),await _e()}catch(f){Qs.value="error",j(f instanceof Error?f.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Vo.value}
            onInput=${i=>{Vo.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Yo.value}
            onChange=${i=>{Yo.value=i.target.value}}
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
            value=${Xo.value}
            onInput=${i=>{Xo.value=i.target.value}}
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
              value=${Xs.value}
              onInput=${i=>{Xs.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Qo.value}
              onInput=${i=>{Qo.value=i.target.value}}
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
              value=${Yn.value}
              onInput=${i=>{Yn.value=i.target.value}}
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
              value=${ti.value}
              onInput=${i=>{const l=i.target.value;ti.value=l,Vb(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Zo.value}
              onInput=${i=>{Zo.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${ei.value}
              onInput=${i=>{ei.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function lk({state:t,nowMs:e}){var f;const n=ne.value||((f=t.session)==null?void 0:f.room)||"",s=t.join_gate,a=Jo.value,i=m(a)?a:null,l=(t.party??[]).filter(h=>h.role!=="dm"),c=le.value.trim(),d=l.some(h=>h.id===c),p=d?c:c?"__manual__":"",_=async()=>{const h=le.value.trim(),T=Ys.value.trim();if(!n||!h){j("Room/Actor가 필요합니다.","warning");return}Rt.value="checking";try{const k=await gm(n,h,T||void 0);Jo.value=k,Rt.value="ok",j("참가 가능 여부를 갱신했습니다.","success")}catch(k){Rt.value="error";const C=k instanceof Error?k.message:"참가 가능 여부 확인에 실패했습니다.";j(C,"error")}},v=async()=>{var $,y;const h=le.value.trim(),T=Ys.value.trim(),k=Go.value.trim();if(!n||!h||!T){j("Room/Actor/Keeper가 필요합니다.","warning");return}if(!_a(e))return;const C=(($=t.current_round)==null?void 0:$.phase)??((y=t.session)==null?void 0:y.status)??"unknown";if(qi("Mid-Join 승인 요청",n,C)){Rt.value="requesting";try{const x=await $m({room_id:n,actor_id:h,keeper_name:T,role:Wo.value,...k?{name:k}:{}});Jo.value=x;const M=m(x)?$s(x,"granted",!1):!1,I=m(x)?xt(x,"reason_code",""):"";M?j("Mid-Join이 승인되었습니다.","success"):j(`Mid-Join이 거절되었습니다${I?`: ${I}`:""}`,"warning"),Rt.value=M?"ok":"error",_e()}catch(x){Rt.value="error";const M=x instanceof Error?x.message:"Mid-Join 요청에 실패했습니다.";j(M,"error")}finally{to()}}};return o`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${s!=null&&s.phase_open?"OPEN":"CLOSED"}</strong>
        ${s!=null&&s.window?o`<span style="margin-left:8px;">(${s.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(s==null?void 0:s.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <select
            value=${p}
            onChange=${h=>{const T=h.target.value;if(T==="__manual__"){(d||!c)&&(le.value="");return}le.value=T}}
          >
            <option value="">Actor 선택</option>
            ${l.map(h=>o`
              <option value=${h.id}>${h.name} (${h.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${p==="__manual__"?o`
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
            value=${Ys.value}
            onInput=${h=>{Ys.value=h.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Wo.value}
            onChange=${h=>{Wo.value=h.target.value}}
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
            value=${Go.value}
            onInput=${h=>{Go.value=h.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${_} disabled=${Rt.value==="checking"||Rt.value==="requesting"}>
              ${Rt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${v} disabled=${Rt.value==="checking"||Rt.value==="requesting"}>
              ${Rt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${$s(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Dt(i,"effective_score",0)}/${Dt(i,"required_points",0)}</span>
            ${xt(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${xt(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Tu({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Iu({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Ru(){const t=Di.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=m(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(m).slice(-8),i=t.canon_check,l=m(i)?i:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(I=>typeof I=="string").slice(0,3):[],d=l&&Array.isArray(l.violations)?l.violations.filter(I=>typeof I=="string").slice(0,3):[],p=n?$s(n,"advanced",!1):!1,_=n?xt(n,"progress_reason",""):"",v=n?xt(n,"progress_detail",""):"",f=n?Dt(n,"player_successes",0):0,h=n?Dt(n,"player_required_successes",0):0,T=n?$s(n,"dm_success",!1):!1,k=n?Dt(n,"timeouts",0):0,C=n?Dt(n,"unavailable",0):0,$=n?Dt(n,"reprompts",0):0,y=n?Dt(n,"npc_attacks",0):0,x=n?Dt(n,"keeper_timeout_sec",0):0,M=n?Dt(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${p?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${p?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${T?"DM ok":"DM stalled"} / players ${f}/${h}
          </span>
        </div>
        ${_?o`<div style="margin-top:4px; font-size:12px;">${_}</div>`:null}
        ${v?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${v}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${$}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${y}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${x||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${M}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(I=>{const F=xt(I,"status","unknown"),B=xt(I,"actor_id","-"),et=xt(I,"role","-"),Z=xt(I,"reason",""),tt=xt(I,"action_type",""),G=xt(I,"reply","");return o`
                <div class="trpg-round-item ${F.includes("fallback")||F.includes("timeout")?"failed":"active"}">
                  <span>${B} (${et})</span>
                  <span style="margin-left:auto; font-size:11px;">${F}</span>
                  ${tt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${tt}</div>`:null}
                  ${Z?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${Z}</div>`:null}
                  ${G?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${G.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${xt(l,"status","unknown")}</strong>
            </div>
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(I=>o`<div>violation: ${I}</div>`)}
                </div>`:null}
            ${c.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(I=>o`<div>warning: ${I}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function ck({state:t,nowMs:e}){var l,c,d;const n=ne.value||((l=t.session)==null?void 0:l.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=ku(e),i=Qb(e);return o`
    <${L} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>Zb(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{to(),j("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function dk({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Xb(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function uk({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${L} title="관전 가이드" semanticId="lab.trpg">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${L} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${Cu} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${L} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${sk} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${L} title="현재 라운드" semanticId="lab.trpg">
          <${Iu} state=${t} />
        <//>

        <${L} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${Tu} state=${t} />
        <//>

        <${L} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${Su} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${L} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Au} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function pk({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${L} title=${`이벤트 타임라인 (${e.length})`}>
          <${ak} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${L} title="최근 라운드 결과" semanticId="lab.trpg">
          <${Ru} />
        <//>

        <${L} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${Iu} state=${t} />
        <//>
      </div>
    </div>
  `}function mk({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${ck} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${L} title="조작 패널" semanticId="lab.trpg">
            <${ik} state=${t} nowMs=${e} />
          <//>

          <${L} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${rk} state=${t} />
          <//>

          <${L} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${lk} state=${t} nowMs=${e} />
          <//>

          <${L} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${Ru} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${L} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${Tu} state=${t} />
          <//>

          <${L} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${Su} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${L} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Au} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function _k(){var c,d,p,_,v;const t=Kc.value,e=fi.value;if(nt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const f=window.setInterval(()=>{lc.value=Date.now()},1e3);return()=>{window.clearInterval(f)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>_e()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=bu.value,l=lc.value;return o`
    <div>
      <${At} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${ne.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((p=t.session)==null?void 0:p.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>_e()}>새로고침</button>
      </div>

      <${ok} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((_=t.session)==null?void 0:_.status)??"active"}</div>
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

      <${dk} active=${i} />

      ${i==="overview"?o`<${uk} state=${t} />`:i==="timeline"?o`<${pk} state=${t} />`:o`<${mk} state=${t} nowMs=${l} />`}
    </div>
  `}function vk(){return o`
    <div>
      <${At} surfaceId="lab" />
      <${L} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${L} title="TRPG" class="section" semanticId="lab.trpg">
        <${_k} />
      <//>
    </div>
  `}const eo=g(new Set(["broadcast","tasks","keepers","system"]));function fk(t){const e=new Set(eo.value);e.has(t)?e.delete(t):e.add(t),eo.value=e}const Lr=g(null);function Lu(t){Lr.value=t}function gk(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const $k=Et(()=>{const t=eo.value;return fa.value.filter(e=>t.has(gk(e)))}),hk=12e4,yk=Et(()=>{const t=Wc.value,e=Date.now();return Jt.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let i="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?i=e-new Date(l).getTime()>hk?"stale":"working":i="working"}else(n.status==="offline"||n.status==="inactive")&&(i="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:i,currentTask:n.current_task,motion:a}})}),bk=Et(()=>{const t=Wc.value;return Jt.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let i="calm";return a>=3?i="hot":a>=1&&(i="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:i}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function cc(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function kk(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function xk(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function Sk(){const t=yk.value,e=Lr.value;return t.length===0?o`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:o`
    <div class="pulse-strip">
      ${t.map(n=>o`
        <button
          key=${n.name}
          class="pulse-bubble ${xk(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>Lu(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const Ck=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function Ak(){const t=eo.value;return o`
    <div class="activity-filter-bar">
      ${Ck.map(e=>o`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>fk(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Tk(){const t=$k.value;return o`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${Ak} />
      <div class="activity-stream-list">
        ${t.length===0?o`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>o`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${cc(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${cc(e)}">${kk(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${Od(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function Ik(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function Rk(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function Lk(){const t=bk.value,e=Lr.value;return o`
    <div class="focus-sidebar">
      <div class="focus-sidebar-head">
        <h3>Agents</h3>
        <span class="focus-count">${t.length} active</span>
      </div>
      <div class="focus-sidebar-list">
        ${t.length===0?o`<div class="focus-empty">No active agents</div>`:t.map(n=>o`
            <div
              key=${n.name}
              class="focus-agent-card ${e===n.name?"focus-agent-selected":""}"
              onClick=${()=>Lu(e===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?o`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${Ik(n.pressure)}">
                  ${Rk(n.pressure)}
                  ${n.assignedCount>0?o` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?o`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?o`<span class="focus-activity-text">${n.lastActivityText}</span>`:o`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?o`<${Y} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function Mk(){const t=ge.value;return o`
    <div class="live-monitor">
      <div class="live-header">
        <h2>라이브 모니터</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"연결됨":"오프라인"}
          </span>
          <span class="live-stat">에이전트 ${Jt.value.length}</span>
          <span class="live-stat">이벤트 ${no.value}</span>
        </div>
      </div>

      <${Sk} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${Tk} />
        </div>
        <div class="live-panel-side">
          <${Lk} />
        </div>
      </div>
    </div>
  `}const dc=[{id:"now",label:"지금",description:"지금 무슨 일이 벌어지는지 사회의 현재 상태를 먼저 읽는 표면"},{id:"why",label:"이유",description:"왜 그렇게 보이는지 근거, 메모리, 거버넌스로 뒤를 파는 표면"},{id:"act",label:"개입",description:"운영자 액션과 계획 조정을 통해 지금 상태를 바꾸는 표면"},{id:"lab",label:"실험",description:"실험적 오케스트레이션과 고급 지휘 표면을 분리해서 보는 영역"}],Fi=[{id:"mission",label:"상황판",icon:"🏠",group:"now",description:"room 중심으로 지금 상황과 사회의 흐름을 가장 먼저 읽는 기본 랜딩"},{id:"execution",label:"실행",icon:"🤖",group:"now",description:"agents, keepers, sessions를 중심으로 사회의 행위자를 읽는 표면"},{id:"live",label:"라이브",icon:"📡",group:"now",description:"실시간 에이전트 활동과 이벤트 흐름을 사회 관찰 관점으로 보는 표면"},{id:"proof",label:"근거",icon:"🔍",group:"why",description:"협업, 대화, 실행의 증거 경로를 확인하는 표면"},{id:"memory",label:"메모리",icon:"💬",group:"why",description:"게시글, 댓글, 비동기 기억으로 room의 누적 맥락을 읽는 표면"},{id:"governance",label:"거버넌스",icon:"⚖️",group:"why",description:"토론, 표결, 판단 구조를 규범과 결정의 관점에서 읽는 표면"},{id:"planning",label:"계획",icon:"🎯",group:"act",description:"목표, 백로그, 압력을 운영 관점으로 읽는 계획 표면"},{id:"tools",label:"도구",icon:"🧰",group:"act",description:"시스템 전체 도구 inventory와 사용 건강도를 확인하는 운영 표면"},{id:"intervene",label:"개입",icon:"🎮",group:"act",description:"룸, 세션, 키퍼에 직접 개입하는 운영 화면"},{id:"command",label:"지휘",icon:"🧭",group:"lab",description:"command-plane, swarm, resolution 같은 고급 지휘/실험 표면"},{id:"lab",label:"실험",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 표면을 메인 사회/운영 콘솔 밖에서 다룹니다"}];function Pk(t){const e=t==null?void 0:t.trim();return e?e.length>10?e.slice(0,10):e:"커밋 정보 없음"}function Pt(t,e){return e==="live"?"가동 중":e==="quiet"?"조용함":e==="starting"?"기동 중":e==="idle"?t==="guardian"?"유휴":"대기 중":"비활성"}function Lt(t,e){return o`
    <div class="build-badge-row">
      <span>${t}</span>
      <strong>${e}</strong>
    </div>
  `}function ta(t,e,n,s,a){return o`
    <div style="padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
      <div class="rail-card-head" style="margin:0;">
        <h3 style="font-size:12px;">${t}</h3>
        <span class="rail-section-chip ${n}">${e}</span>
      </div>
      ${s}
      ${a?o`<div class="rail-build-hint">${a}</div>`:null}
    </div>
  `}function zk({currentTab:t}){var d,p,_,v,f,h,T,k,C,$;const e=ge.value,n=(d=ut.value)==null?void 0:d.build,s=(p=ut.value)==null?void 0:p.lodge,a=(_=ut.value)==null?void 0:_.gardener,i=(v=ut.value)==null?void 0:v.guardian,l=(f=ut.value)==null?void 0:f.sentinel,c=[];if(s&&c.push(ta("Lodge",s.enabled?Pt("lodge",s.quiet_active?"quiet":"live"):Pt("lodge","disabled"),s.enabled?s.quiet_active?"warn":"ok":"bad",[Lt("틱",s.total_ticks??0),Lt("체크인",s.total_checkins??0),Lt("최근 결과",((h=s.last_tick_result)==null?void 0:h.activity_report)??s.last_skip_reason??"없음")])),a&&c.push(ta("Gardener",a.alive?Pt("gardener","live"):a.enabled?Pt("gardener","starting"):Pt("gardener","disabled"),a.alive?"ok":a.enabled?"warn":"bad",[Lt("최근 tick",a.last_tick_completed_at?o`<${Y} timestamp=${a.last_tick_completed_at} />`:"기록 없음"),Lt("판단",`${a.last_intervention??"없음"} · ${a.last_decision_source??"없음"}`),Lt("백로그",`미할당 ${((T=a.health_summary)==null?void 0:T.todo_count)??0} · P1/2 ${((k=a.health_summary)==null?void 0:k.high_priority_todo)??0}`)],a.last_reason??a.last_error??void 0)),i){const y=i.masc_loops_running||i.lodge_loop_started||i.lodge_running;c.push(ta("Guardian",y?Pt("guardian","live"):i.enabled?Pt("guardian","idle"):Pt("guardian","disabled"),y?"ok":i.enabled?"warn":"bad",[Lt("모드",i.mode??"알 수 없음"),Lt("루프",`zombie ${i.zombie_loop_running?"on":"off"} · gc ${i.gc_loop_running?"on":"off"}`),Lt("소유자",i.runtime_owner??"없음")],((C=i.last_lodge_result)==null?void 0:C.message)??i.last_gc_result??i.last_zombie_result??void 0))}return l&&c.push(ta("Sentinel",l.started?Pt("sentinel","live"):l.enabled?Pt("sentinel","starting"):Pt("sentinel","disabled"),l.started?"ok":l.enabled?"warn":"bad",[Lt("에이전트",l.agent_name??"sentinel"),Lt("소비자",(($=l.consumers)==null?void 0:$.length)??0),Lt("가디언 소유자",l.guardian_runtime_owner??"없음")],l.llm_enabled===!0?"LLM 기반 housekeeping resident":void 0)),o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${O} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${e?"ok":"bad"}">${e?"연결됨":"오프라인"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>에이전트</span>
          <strong>${Jt.value.length}</strong>
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
          <strong>${no.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{ks(),Vc(),Ai(t)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>at("intervene")}>
          개입 열기
        </button>
      </div>
      ${n?o`<div class="rail-build-hint">서버 빌드 · v${n.release_version} · ${Pk(n.commit)}</div>`:null}
      ${c.length>0?o`
            <div style="margin-top:12px; display:flex; flex-direction:column; gap:10px;">
              ${c}
            </div>
          `:null}
    </section>
  `}function Ek(){const t=Tt.value,e=hs(t).total_count,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return o`
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
          onClick=${()=>{mt(),Fe()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>at("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}const ea=g(!1);function jk(){const t=ge.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"연결됨":"재연결 중..."}</span>
      <span class="event-count">이벤트 ${no.value}</span>
    </div>
  `}function wk(t){const e=t==null?void 0:t.trim();return e?e.length>10?e.slice(0,10):e:"커밋 정보 없음"}function Nk(){const t=ut.value,e=t==null?void 0:t.build,n=e?`v${e.release_version} · ${wk(e.commit)}`:t!=null&&t.version?`v${t.version} · 커밋 정보 없음`:"버전 정보 없음";return o`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${ea.value}
        onClick=${()=>{ea.value=!ea.value}}
      >
        서버 빌드 · ${n}
      </button>
      ${ea.value?o`
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
                <strong>${e!=null&&e.started_at?o`<${Y} timestamp=${e.started_at} />`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof(e==null?void 0:e.uptime_seconds)=="number"?`${e.uptime_seconds}s`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${t!=null&&t.generated_at?o`<${Y} timestamp=${t.generated_at} />`:"알 수 없음"}</strong>
              </div>
            </div>
          `:null}
    </div>
  `}function Dk(){const t=D.value.tab,e=Fi.find(s=>s.id===t),n=dc.find(s=>s.id===(e==null?void 0:e.group));return o`
    <aside class="dashboard-rail">
      <${At} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${O} panelId="side_rail.navigate" compact=${!0} />
          ${n?o`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${dc.map(s=>o`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${Fi.filter(a=>a.group===s.id).map(a=>o`
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

      <${zk} currentTab=${t} />
      <${Ek} />
    </aside>
  `}function Ok(){switch(D.value.tab){case"mission":return o`<${Pl} />`;case"proof":return o`<${H$} />`;case"execution":return o`<${ab} />`;case"tools":return o`<${ub} />`;case"live":return o`<${Mk} />`;case"memory":return o`<${qy} />`;case"governance":return o`<${Ob} />`;case"planning":return o`<${Ab} />`;case"intervene":return o`<${Ty} />`;case"command":return o`<${xy} />`;case"lab":return o`<${vk} />`;default:return o`<${Pl} />`}}function qk(){return vi.value&&!ge.value?o`<div class="loading-indicator">대시보드 불러오는 중...</div>`:o`<${Ok} />`}function Fk(){nt(()=>{Ku(),gc(),Yc(),ze(),Pe(),Vc(),dd();const n=W_();return G_(),()=>{Yu(),n(),J_()}},[]),nt(()=>{const n=setInterval(()=>{Ai(D.value.tab)},15e3);return()=>{clearInterval(n)}},[]),nt(()=>{Ai(D.value.tab)},[D.value.tab]);const t=D.value.tab,e=Fi.find(n=>n.id===t);return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC 대시보드
            <${Nk} />
          </h1>
          <p class="header-subtitle">${(e==null?void 0:e.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${jk} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${Dk} />
        <main class="dashboard-main">
          <${qk} />
        </main>
      </div>

      <${Gg} />
      <${_g} />
      <${ag} />
    </div>
  `}const uc=document.getElementById("app");uc&&Nu(o`<${Fk} />`,uc);export{s$ as _};
