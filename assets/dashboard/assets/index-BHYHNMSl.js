var yu=Object.defineProperty;var bu=(t,e,n)=>e in t?yu(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var Ke=(t,e,n)=>bu(t,typeof e!="symbol"?e+"":e,n);import{e as ku,_ as xu,c as g,b as Et,A as Ln,y as nt,d as mn,G as Su}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const l of i.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var o=ku.bind(xu);const Cu=["mission","proof","execution","tools","live","memory","governance","planning","intervene","command","lab"],Xl={tab:"mission",params:{},postId:null};function Yr(t){return!!t&&Cu.includes(t)}function Vo(t){try{return decodeURIComponent(t)}catch{return t}}function Xo(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Au(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Ql(t,e){if(t[0]==="chains"){const i={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(i.operation=Vo(t[2])),{tab:"command",params:i,postId:null}}if(t[0]==="lab"){const i={...e};return t[1]&&(i.surface=Vo(t[1])),{tab:"lab",params:i,postId:null}}const n=t[0],s=e.tab;return{tab:Yr(n)?n:Yr(s)?s:"mission",params:e,postId:null}}function oa(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Xl;const n=Vo(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=Xo(a),l=Au(s);return Ql(l,i)}function Tu(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Xl,params:Xo(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Xo(e.replace(/^\?/,""));return Ql(s,a)}function Zl(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const D=g(oa(window.location.hash));window.addEventListener("hashchange",()=>{D.value=oa(window.location.hash)});function ot(t,e){const n={tab:t,params:e??{}};window.location.hash=Zl(n)}function Iu(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function Ru(){if(window.location.hash&&window.location.hash!=="#"){D.value=oa(window.location.hash);return}const t=Tu(window.location.pathname,window.location.search);if(t){D.value=t;const e=Zl(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",D.value=oa(window.location.hash)}const Vr="masc_dashboard_sse_session_id",Mu=1e3,Eu=15e3,fe=g(!1),Ha=g(0),tc=g(null),ia=g([]);function Lu(){let t=sessionStorage.getItem(Vr);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Vr,t)),t}const Pu=200;function zu(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};ia.value=[a,...ia.value].slice(0,Pu)}function Qo(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Xr(t,e){const n=Qo(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function It(t,e,n,s,a={}){zu(t,e,n,{eventType:s,...a})}let wt=null,nn=null,Zo=0;function ec(){nn&&(clearTimeout(nn),nn=null)}function ju(){if(nn)return;Zo++;const t=Math.min(Zo,5),e=Math.min(Eu,Mu*Math.pow(2,t));nn=setTimeout(()=>{nn=null,nc()},e)}function nc(){ec(),wt&&(wt.close(),wt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Lu());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);wt=i,i.onopen=()=>{wt===i&&(Zo=0,fe.value=!0)},i.onerror=()=>{wt===i&&(fe.value=!1,i.close(),wt=null,ju())},i.onmessage=l=>{try{const c=JSON.parse(l.data);Ha.value++,tc.value=c,Nu(c)}catch{}}}function Nu(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":It(n,"Joined","system","agent_joined");break;case"agent_left":It(n,"Left","system","agent_left");break;case"broadcast":It(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":It(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":It(n,Xr("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Qo(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":It(n,Xr("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Qo(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":It(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":It(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":It(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":It(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:It(n,e,"system","unknown")}}function wu(){ec(),wt&&(wt.close(),wt=null),fe.value=!1}function m(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function r(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function u(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function z(t){return typeof t=="boolean"?t:void 0}function B(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function dt(t,e=[]){if(Array.isArray(t))return t;if(!m(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function lt(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}const ra="[STATE]",ti="[/STATE]";function Du(t){const e=t.indexOf(ra);if(e<0)return null;const n=e+ra.length,s=t.indexOf(ti,n);return s<0?null:t.slice(n,s).trim()||null}function Ou(t){let e=t;for(;;){const n=e.indexOf(ra);if(n<0)return e;const s=e.indexOf(ti,n+ra.length);if(s<0)return e.slice(0,n);e=`${e.slice(0,n)}${e.slice(s+ti.length)}`}}function qu(t){return t.split(`
`).filter(e=>{const n=e.trim();return!n.startsWith("SKILL:")&&!n.startsWith("SKILL_REASON:")}).join(`
`)}function Hs(t){const e=qu(t);return Ou(e).replace(/\n{3,}/g,`

`).trim()}function sc(t){const e=(()=>{if(!m(t))return null;const i=t.raw_payload;return m(i)?i:t})();if(!e)return null;const n=r(e.reply)??"",s=n?Du(n):null,a=m(e.usage)?{inputTokens:u(e.usage.input_tokens)??null,outputTokens:u(e.usage.output_tokens)??null,totalTokens:u(e.usage.total_tokens)??null}:null;return{traceId:r(e.trace_id)??null,generation:u(e.generation)??null,modelUsed:r(e.model_used)??null,latencyMs:u(e.latency_ms)??null,costUsd:u(e.cost_usd)??null,usage:a,skillPrimary:r(e.skill_primary)??null,skillReason:r(e.skill_reason)??null,stateBlock:s,rawPayload:e}}function Fu(t){const e=t.trim();if(!e.startsWith("{"))return{text:Hs(e),details:null};try{const n=JSON.parse(e),s=sc(n),a=m(n)?r(n.reply)??e:e;return{text:Hs(a),details:s}}catch{return{text:Hs(e),details:null}}}function Li(){return new URLSearchParams(window.location.search)}const Bu="masc_dashboard_agent_name";function ac(){var t;try{return((t=localStorage.getItem(Bu))==null?void 0:t.trim())||null}catch{return null}}function oc(){var e,n;const t=Li();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||ac()||"dashboard"}function ic(){const t=Li(),e={},n=t.get("token"),s=ac(),a=t.get("agent")??t.get("agent_name")??s;return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Pi(){return{...ic(),"Content-Type":"application/json"}}const Ku=15e3,zi=3e4,Uu=6e4,Qr=new Set([408,425,429,500,502,503,504]);class ms extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);Ke(this,"method");Ke(this,"path");Ke(this,"status");Ke(this,"statusText");Ke(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function ji(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const l=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new ms({method:l,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function Wu(){var e,n;const t=Li();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function st(t){const e=await ji(t,{headers:ic()},Ku);if(!e.ok)throw new ms({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Hu(t){return new Promise(e=>setTimeout(e,t))}function Gu(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function Ju(t){if(t instanceof ms)return t.timeout||typeof t.status=="number"&&Qr.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Gu(t.message);return e!==null&&Qr.has(e)}async function Ga(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!Ju(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,a),await Hu(i),s+=1}}async function Ht(t,e,n,s=zi){const a=await ji(t,{method:"POST",headers:{...Pi(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new ms({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function Yu(t,e,n,s=zi){const a=await ji(t,{method:"POST",headers:{...Pi(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new ms({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function Vu(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Xu(t){var e,n,s,a,i,l,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(d)}return((c=(l=(i=t.result)==null?void 0:i.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function Tt(t,e){const n=await Yu("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Uu),s=Vu(n);return Xu(s)}function Ja(t){const e=t.trim();return e?JSON.parse(e):{}}async function Qu(t){return Ja(await Tt("masc_autoresearch_status",{loop_id:t}))}async function Zu(t,e){return Ja(await Tt("masc_autoresearch_inject",{loop_id:t,hypothesis:e}))}async function tp(t){return Ja(await Tt("masc_autoresearch_cycle",{loop_id:t}))}async function ep(t,e){return Ja(await Tt("masc_autoresearch_stop",{loop_id:t,reason:e}))}async function np(t,e,n){return Tt("masc_keeper_msg",{name:t,message:e})}async function sp(t,e,n){const s=await np(t,e);return Fu(s)}function ap(t){const e=t.replace(/\r\n/g,`
`),n=[];let s=0;for(;;){const a=e.indexOf(`

`,s);if(a<0)return{frames:n,rest:e.slice(s)};n.push(e.slice(s,a)),s=a+2}}function Zr(t){const e=t.split(`
`).filter(n=>n.startsWith("data:")).map(n=>n.slice(5).trimStart());if(e.length===0)return null;try{return JSON.parse(e.join(`
`))}catch{return null}}async function op(t,e,n,{signal:s,onEvent:a}){var p;const i=await fetch("/api/v1/keepers/chat/stream",{method:"POST",headers:{...Pi(),Accept:"text/event-stream"},body:JSON.stringify({name:t,message:e}),signal:s});if(!i.ok){const v=await i.text();let _=v||`Streaming request failed (${i.status})`;try{const f=JSON.parse(v);_=((p=f.error)==null?void 0:p.message)??f.message??_}catch{}throw new Error(_)}if(!i.body)throw new Error("Streaming response body is unavailable");const l=i.body.getReader(),c=new TextDecoder;let d="";try{for(;;){const{done:_,value:f}=await l.read();d+=c.decode(f??new Uint8Array,{stream:!_});const{frames:h,rest:C}=ap(d);d=C;for(const b of h){const x=Zr(b);x&&a(x)}if(_)break}const v=d.trim();if(v){const _=Zr(v);_&&a(_)}}finally{l.releaseLock()}}function ip(){return st("/api/v1/dashboard/shell")}function rp(){return st("/api/v1/dashboard/room-truth")}function lp(){return st("/api/v1/dashboard/execution")}function cp(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),st(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function dp(){return Ga("fetchDashboardGovernance",async()=>{const t=await st("/api/v1/dashboard/governance"),e=Array.isArray(t.items)?t.items.map(i=>Rp(i)).filter(i=>i!==null):[],n=Array.isArray(t.pending_actions)?t.pending_actions.map(i=>cc(i)).filter(i=>i!==null):[],s=e.filter(i=>i.kind==="debate").map(i=>({id:i.id,topic:i.topic,status:i.status,argument_count:i.evidence_refs.length,created_at:i.last_activity_at??void 0})),a=e.filter(i=>i.kind==="consensus").map(i=>({id:i.id,topic:i.topic,initiator:i.related_agents[0]||"system",votes:i.votes??0,quorum:i.quorum??0,threshold:i.threshold,state:i.status,created_at:i.last_activity_at??void 0}));return{generated_at:pt(t.generated_at)??void 0,summary:m(t.summary)?{debates:ft(t.summary.debates)??void 0,voting_sessions:ft(t.summary.voting_sessions)??void 0,debates_open:ft(t.summary.debates_open)??void 0,sessions_active:ft(t.summary.sessions_active)??void 0,sessions_without_quorum:ft(t.summary.sessions_without_quorum)??void 0,ready_to_execute:ft(t.summary.ready_to_execute)??void 0,oldest_open_debate_age_s:typeof t.summary.oldest_open_debate_age_s=="number"?t.summary.oldest_open_debate_age_s:null,last_activity_age_s:typeof t.summary.last_activity_age_s=="number"?t.summary.last_activity_age_s:null,judge_online:typeof t.summary.judge_online=="boolean"?t.summary.judge_online:void 0,judge_last_seen_at:pt(t.summary.judge_last_seen_at)}:void 0,debates:s,sessions:a,items:e,activity:Array.isArray(t.activity)?t.activity.map(i=>Mp(i)).filter(i=>i!==null):[],judge:Ep(t.judge),pending_actions:n}})}function up(){return st("/api/v1/dashboard/semantics")}function pp(){return st("/api/v1/dashboard/mission")}function mp(t){const e=`?session_id=${encodeURIComponent(t)}`;return st(`/api/v1/dashboard/session${e}`)}function _p(t=!1){return st(`/api/v1/dashboard/mission/briefing${t?"?force=1":""}`)}function vp(t,e){const n=new URLSearchParams;t&&n.set("session_id",t),e&&n.set("operation_id",e);const s=n.toString();return st(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function fp(){return st("/api/v1/dashboard/planning")}function gp(){return st("/api/v1/tool-metrics")}function $p(){return st("/api/v1/dashboard/tools")}function hp(){return st("/api/v1/operator")}function rc(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return st(`/api/v1/operator/digest${n?`?${n}`:""}`)}function yp(){return st("/api/v1/command-plane")}function bp(){return st("/api/v1/command-plane/summary")}function kp(){return st("/api/v1/chains/summary")}function xp(t){return st(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Sp(){return st("/api/v1/command-plane/help")}function Cp(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return st(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function Ap(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return st(`/api/v1/command-plane/orchestra${s?`?${s}`:""}`)}function Tp(t,e){return Ht(t,e)}function Ip(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"swarm_run_continue":return 6e4;case"swarm_run_rerun":return 12e4;case"swarm_run_abandon":return 3e4;case"lodge_tick":return 45e3;default:return zi}}function Ya(t){return Ht("/api/v1/operator/action",t,void 0,Ip(t))}function lc(t,e,n="confirm"){return Ht("/api/v1/operator/confirm",{actor:t,confirm_token:e,decision:n})}function Gs(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function pt(t){if(typeof t=="string"){const e=t.trim();return e||null}if(typeof t=="number"&&Number.isFinite(t)){const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}return null}function K(t){if(typeof t!="string")return null;const e=t.trim();return e||null}function cc(t){if(!m(t))return null;const e=S(t.confirm_token??t.token,"").trim();return e?{confirm_token:e,actor:K(t.actor)??void 0,action_type:K(t.action_type)??void 0,target_type:K(t.target_type)??void 0,target_id:K(t.target_id),delegated_tool:K(t.delegated_tool)??void 0,created_at:pt(t.created_at)??void 0,preview:t.preview}:null}function Ni(t){return m(t)?{board_post_id:K(t.board_post_id),task_id:K(t.task_id),operation_id:K(t.operation_id),team_session_id:K(t.team_session_id)}:{}}function dc(t){if(!m(t))return null;const e=K(t.action_kind),n=K(t.resolved_tool),s=K(t.target_type),a=K(t.target_id),i=K(t.reason);return!e&&!n&&!s&&!i?null:{action_kind:e??void 0,resolved_tool:n,target_type:s,target_id:a,reason:i??void 0,payload_preview:t.payload_preview}}function uc(t){if(!m(t))return null;const e=K(t.action_type),n=K(t.delegated_tool),s=K(t.confirmation_state),a=pt(t.created_at);return!e&&!n&&!s&&!a?null:{action_type:e??void 0,delegated_tool:n,confirmation_state:s??void 0,created_at:a}}function pc(t){if(!m(t))return null;const e=cc(t.pending_confirm),n=K(t.pending_confirm_token)??(e==null?void 0:e.confirm_token)??null;return{requires_human_gate:typeof t.requires_human_gate=="boolean"?t.requires_human_gate:void 0,pending_confirm:e,pending_confirm_token:n,ready_to_execute:typeof t.ready_to_execute=="boolean"?t.ready_to_execute:void 0}}function mc(t){if(!m(t))return null;const e=K(t.summary),n=K(t.target_id);return!e&&!n?null:{judgment_id:K(t.judgment_id)??void 0,target_kind:K(t.target_kind)??void 0,target_id:n??void 0,status:K(t.status)??void 0,summary:e??void 0,confidence:typeof t.confidence=="number"?t.confidence:null,generated_at:pt(t.generated_at),expires_at:pt(t.expires_at),model_used:K(t.model_used),keeper_name:K(t.keeper_name),evidence_refs:qt(t.evidence_refs),recommended_action:dc(t.recommended_action),guardrail_state:pc(t.guardrail_state),executed_route:uc(t.executed_route)}}function Rp(t){if(!m(t))return null;const e=S(t.id,"").trim(),n=S(t.topic,"").trim();if(!e||!n)return null;const s=Ni(t.context);return{kind:S(t.kind,"debate"),id:e,topic:n,status:S(t.status??t.state,"open"),last_activity_at:pt(t.last_activity_at),truth_summary:K(t.truth_summary)??void 0,judgment_summary:K(t.judgment_summary),confidence:typeof t.confidence=="number"?t.confidence:null,related_agents:qt(t.related_agents),context:s,linked_board_post_id:K(t.linked_board_post_id)??s.board_post_id??null,linked_task_id:K(t.linked_task_id)??s.task_id??null,linked_operation_id:K(t.linked_operation_id)??s.operation_id??null,linked_session_id:K(t.linked_session_id)??s.team_session_id??null,recommended_action:dc(t.recommended_action),executed_route:uc(t.executed_route),guardrail_state:pc(t.guardrail_state),evidence_refs:qt(t.evidence_refs),approve_count:ft(t.approve_count),reject_count:ft(t.reject_count),abstain_count:ft(t.abstain_count),votes:ft(t.votes),quorum:ft(t.quorum),threshold:typeof t.threshold=="number"?t.threshold:void 0}}function Mp(t){if(!m(t))return null;const e=S(t.kind,"").trim();return e?{kind:e,item_kind:K(t.item_kind)??void 0,item_id:K(t.item_id)??void 0,topic:K(t.topic)??void 0,created_at:pt(t.created_at),summary:K(t.summary)??void 0,actor:K(t.actor),index:ft(t.index),decision:K(t.decision)}:null}function Ep(t){if(m(t))return{judge_online:typeof t.judge_online=="boolean"?t.judge_online:void 0,refreshing:typeof t.refreshing=="boolean"?t.refreshing:void 0,generated_at:pt(t.generated_at),expires_at:pt(t.expires_at),model_used:K(t.model_used),keeper_name:K(t.keeper_name),last_error:K(t.last_error)}}function Lp(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Pp(t){if(!m(t))return null;const e=S(t.source,"").trim()||null,n=S(t.state_block,"").trim()||null;return!e&&!n?null:{source:e,state_block:n}}function zp(t){if(!m(t))return null;const e=S(t.id,"").trim(),n=S(t.author,"").trim(),s=S(t.body,"").trim()||S(t.content,"").trim(),a=s;if(!e||!n)return null;const i=H(t.score,0),l=H(t.votes_up,0),c=H(t.votes_down,0),d=H(t.votes,i||l-c),p=H(t.comment_count,H(t.reply_count,0)),v=(()=>{const x=t.flair;if(typeof x=="string"&&x.trim())return x.trim();if(m(x)){const $=S(x.name,"").trim();if($)return $}return S(t.flair_name,"").trim()||void 0})(),_=S(t.created_at_iso,"").trim()||Gs(t.created_at),f=S(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Gs(t.updated_at):_),C=S(t.title,"").trim()||Lp(s),b=Array.isArray(t.tags)?t.tags.filter(x=>typeof x=="string"&&x.trim()!==""):[];return{id:e,author:n,post_kind:(()=>{const x=S(t.post_kind,"").trim().toLowerCase();return x==="automation"||x==="system"||x==="human"?x:void 0})(),title:C,body:s,content:a,meta:Pp(t.meta),tags:b,votes:d,vote_balance:i,comment_count:p,created_at:_,updated_at:f,flair:v,hearth:S(t.hearth,"").trim()||null,visibility:S(t.visibility,"").trim()||void 0,expires_at:S(t.expires_at_iso,"").trim()||(t.expires_at!==void 0&&t.expires_at!==0?Gs(t.expires_at):"")||null,hearth_count:H(t.hearth_count,0)}}function jp(t){if(!m(t))return null;const e=S(t.id,"").trim(),n=S(t.post_id,"").trim(),s=S(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:S(t.content,""),created_at:Gs(t.created_at)}}async function Np(t){return Ga("fetchBoardPost",async()=>{const e=await st(`/api/v1/board/${t}?format=flat`),n=m(e.post)?e.post:e,s=zp(n)??{id:t,author:"unknown",post_kind:"human",title:"Post",body:"",content:"",meta:null,tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},i=(Array.isArray(e.comments)?e.comments:[]).map(jp).filter(l=>l!==null);return{...s,comments:i}})}function _c(t,e){return Ht("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Wu()})}function wp(t,e,n){return Ht("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Dp(t){const e=S(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function mt(...t){for(const e of t){const n=S(e,"");if(n.trim())return n.trim()}return""}function tl(t){const e=Dp(mt(t.outcome,t.result,t.result_code));if(!e)return;const n=mt(t.reason,t.reason_code,t.description,t.detail),s=mt(t.summary,t.summary_ko,t.summary_en,t.note),a=mt(t.details,t.details_text,t.text,t.note),i=mt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),l=mt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=mt(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const _=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof _=="string"?[_]:Array.isArray(_)?_.map(f=>{if(typeof f=="string")return f.trim();if(m(f)){const h=S(f.summary,"").trim();if(h)return h;const C=S(f.text,"").trim();if(C)return C;const b=S(f.type,"").trim();return b||S(f.event_id,"").trim()}return""}).filter(f=>f.length>0):[]})(),p=(()=>{const _=H(t.turn,Number.NaN);if(Number.isFinite(_))return _;const f=H(t.turn_number,Number.NaN);if(Number.isFinite(f))return f;const h=H(t.current_turn,Number.NaN);if(Number.isFinite(h))return h;const C=H(t.round,Number.NaN);return Number.isFinite(C)?C:void 0})(),v=mt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:l||void 0,evidence:d.length>0?d:void 0,raw_reason:c||void 0,turn:p,phase:v||void 0}}function Op(t,e){const n=m(t.state)?t.state:{};if(S(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(l=>m(l)?S(l.type,"")==="session.outcome":!1),i=m(n.session_outcome)?n.session_outcome:{};if(m(i)&&Object.keys(i).length>0){const l=tl(i);if(l)return l}if(m(a))return tl(m(a.payload)?a.payload:{})}function S(t,e=""){return typeof t=="string"?t:e}function H(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function ft(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function la(t,e=!1){return typeof t=="boolean"?t:e}function qt(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(m(e)){const n=S(e.name,"").trim(),s=S(e.id,"").trim(),a=S(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function qp(t){const e={};if(!m(t)&&!Array.isArray(t))return e;if(m(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=S(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!m(n))continue;const s=mt(n.to,n.target,n.actor_id,n.name,n.id),a=mt(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Fp(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function St(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const Bp=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Kp(t){const e=m(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const i=s.trim();i&&(Bp.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function Up(t,e){if(t!=="dice.rolled")return;const n=H(e.raw_d20,0),s=H(e.total,0),a=H(e.bonus,0),i=S(e.action,"roll"),l=H(e.dc,0);return{notation:l>0?`${i} (DC ${l})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Wp(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Hp(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Gp(t,e,n,s){const a=n||e||S(s.actor_id,"")||S(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=S(s.proposed_action,S(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=S(s.reply,S(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return S(s.reply,S(s.content,S(s.text,"Narration")));case"dice.rolled":{const i=S(s.action,"roll"),l=H(s.total,0),c=H(s.dc,0),d=S(s.label,""),p=a||"actor",v=c>0?` vs DC ${c}`:"",_=d?` (${d})`:"";return`${p} ${i}: ${l}${v}${_}`}case"turn.started":return`Turn ${H(s.turn,1)} started`;case"phase.changed":return`Phase: ${S(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${S(s.name,m(s.actor)?S(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${S(s.keeper_name,S(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${S(s.keeper_name,S(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${H(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${H(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||S(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||S(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${S(s.reason_code,"unknown")}`;case"memory.signal":{const i=m(s.entity_refs)?s.entity_refs:{},l=S(i.requested_tier,""),c=S(i.effective_tier,""),d=la(i.guardrail_applied,!1),p=S(s.summary_en,S(s.summary_ko,"Memory signal"));if(!l&&!c)return p;const v=l&&c?`${l}->${c}`:c||l;return`${p} [${v}${d?" (guardrail)":""}]`}case"world.event":{if(S(s.event_type,"")==="canon.check"){const l=S(s.status,"unknown"),c=S(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return S(s.description,S(s.summary,"World event"))}case"combat.attack":return S(s.summary,S(s.result,"Attack resolved"));case"combat.defense":return S(s.summary,S(s.result,"Defense resolved"));case"session.outcome":return S(s.summary,S(s.outcome,"Session ended"));default:{const i=Wp(s);return i?`${t}: ${i}`:t}}}function Jp(t,e){const n=m(t)?t:{},s=S(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=S(n.actor_name,"").trim()||e[a]||S(m(n.payload)?n.payload.actor_name:"",""),l=m(n.payload)?n.payload:{},c=S(n.ts,S(n.timestamp,new Date().toISOString())),d=S(n.phase,S(l.phase,"")),p=S(n.category,"");return{type:s,actor:i||a||S(l.actor_name,""),actor_id:a||S(l.actor_id,""),actor_name:i,seq:n.seq,room_id:S(n.room_id,""),phase:d||void 0,category:p||Hp(s),visibility:S(n.visibility,S(l.visibility,"public")),event_id:S(n.event_id,""),content:Gp(s,a,i,l),dice_roll:Up(s,l),timestamp:c}}function Yp(t,e,n){var X,rt;const s=S(t.room_id,"")||n||"default",a=m(t.state)?t.state:{},i=m(a.party)?a.party:{},l=m(a.actor_control)?a.actor_control:{},c=m(a.join_gate)?a.join_gate:{},d=m(a.contribution_ledger)?a.contribution_ledger:{},p=Object.entries(i).map(([U,I])=>{const A=m(I)?I:{},j=St(A,"max_hp",void 0,10),J=St(A,"hp",void 0,j),Q=St(A,"max_mp",void 0,0),it=St(A,"mp",void 0,0),W=St(A,"level",void 0,1),Pt=St(A,"xp",void 0,0),ke=la(A.alive,J>0),xn=l[U],ks=typeof xn=="string"?xn:void 0,lo=Fp(A.role,U,ks),co=ft(A.generation),uo=mt(A.joined_at,A.joinedAt,A.started_at,A.startedAt),po=mt(A.claimed_at,A.claimedAt,A.assigned_at,A.assignedAt,A.assigned_time),mo=mt(A.last_seen,A.lastSeen,A.last_seen_at,A.lastSeenAt,A.last_active,A.lastActive),xs=mt(A.scene,A.current_scene,A.currentScene,A.world_scene,A.scene_name,A.sceneName),Ss=mt(A.location,A.current_location,A.currentLocation,A.position,A.zone,A.area);return{id:U,name:S(A.name,U),role:lo,keeper:ks,archetype:S(A.archetype,""),persona:S(A.persona,""),portrait:S(A.portrait,"")||void 0,background:S(A.background,"")||void 0,traits:qt(A.traits),skills:qt(A.skills),stats_raw:Kp(A),status:ke?"active":"dead",generation:co,joined_at:uo||void 0,claimed_at:po||void 0,last_seen:mo||void 0,scene:xs||void 0,location:Ss||void 0,inventory:qt(A.inventory),notes:qt(A.notes),relationships:qp(A.relationships),stats:{hp:J,max_hp:j,mp:it,max_mp:Q,level:W,xp:Pt,strength:St(A,"strength","str",10),dexterity:St(A,"dexterity","dex",10),constitution:St(A,"constitution","con",10),intelligence:St(A,"intelligence","int",10),wisdom:St(A,"wisdom","wis",10),charisma:St(A,"charisma","cha",10)}}}),v=p.filter(U=>U.status!=="dead"),_=Op(t,e),f={phase_open:la(c.phase_open,!0),min_points:H(c.min_points,3),window:S(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},h=Object.entries(d).map(([U,I])=>{const A=m(I)?I:{};return{actor_id:U,score:H(A.score,0),last_reason:S(A.last_reason,"")||null,reasons:qt(A.reasons)}}),C=p.reduce((U,I)=>(U[I.id]=I.name,U),{}),b=e.map(U=>Jp(U,C)),x=H(a.turn,1),y=S(a.phase,"round"),$=S(a.map,""),R=m(a.world)?a.world:{},T=$||S(R.ascii_map,S(R.map,"")),P=b.filter((U,I)=>{const A=e[I];if(!m(A))return!1;const j=m(A.payload)?A.payload:{};return H(j.turn,-1)===x}),G=(P.length>0?P:b).slice(-12),L=S(a.status,"active");return{session:{id:s,room:s,status:L==="ended"?"ended":L==="paused"?"paused":"active",round:x,actors:v,created_at:((X=b[0])==null?void 0:X.timestamp)??new Date().toISOString()},current_round:{round_number:x,phase:y,events:G,timestamp:((rt=b[b.length-1])==null?void 0:rt.timestamp)??new Date().toISOString()},map:T||void 0,join_gate:f,contribution_ledger:h,outcome:_,party:v,story_log:b,history:[]}}async function Vp(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await st(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Xp(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([st(`/api/v1/trpg/state${e}`),Vp(t)]);return Yp(n,s,t)}function Qp(t){return Ht("/api/v1/trpg/rounds/run",{room_id:t})}function Zp(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function tm(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Ht("/api/v1/trpg/dice/roll",e)}function em(t,e){const n=Zp();return Ht("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function nm(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Ht("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function sm(t,e,n){return Ht("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function am(t,e,n){const s=await Tt("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function om(t){const e=await Tt("trpg.mid_join.request",t);return JSON.parse(e)}async function im(t,e){await Tt("masc_broadcast",{agent_name:t,message:e})}async function rm(t=40){return(await Tt("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function lm(t,e=20){return Tt("masc_task_history",{task_id:t,limit:e})}async function cm(t){const e=await Tt("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function dm(t){return Ga("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await st(`/api/v1/council/debates/${e}/summary`);if(!m(n))return null;const s=m(n.debate)?n.debate:n,a=S(s.id,"").trim(),i=S(s.topic,"").trim();return!a||!i?null:{debate:{id:a,topic:i,status:S(s.status,"open"),created_at:pt(s.created_at_iso??s.created_at),closed_at:pt(s.closed_at)},arguments:Array.isArray(n.arguments)?n.arguments.flatMap(l=>m(l)?[{index:H(l.index,0),agent:S(l.agent,"unknown"),position:S(l.position,"neutral"),content:S(l.content,""),evidence:qt(l.evidence),reply_to:ft(l.reply_to)??null,mentions:qt(l.mentions),archetype:K(l.archetype),created_at:pt(l.created_at)}]:[]):[],summary:{support_count:m(n.summary)?H(n.summary.support_count,0):H(n.support_count,0),oppose_count:m(n.summary)?H(n.summary.oppose_count,0):H(n.oppose_count,0),neutral_count:m(n.summary)?H(n.summary.neutral_count,0):H(n.neutral_count,0),total_arguments:m(n.summary)?H(n.summary.total_arguments,0):H(n.total_arguments,0),summary_text:m(n.summary)?S(n.summary.summary_text,""):S(n.summary_text,"")},context:Ni(n.context),judgment:mc(n.judgment)}})}async function um(t){return Ga("fetchConsensusSessionSummary",async()=>{const e=encodeURIComponent(t),n=await st(`/api/v1/council/sessions/${e}/summary`);if(!m(n)||!m(n.session))return null;const s=n.session,a=S(s.id,"").trim(),i=S(s.topic,"").trim();return!a||!i?null:{session:{id:a,topic:i,state:S(s.state,"open"),initiator:S(s.initiator,"system"),quorum:H(s.quorum,0),threshold:H(s.threshold,0),created_at:pt(s.created_at),closed_at:pt(s.closed_at)},votes:Array.isArray(n.votes)?n.votes.flatMap(l=>m(l)?[{agent:S(l.agent,"unknown"),decision:S(l.decision,"abstain"),reason:S(l.reason,""),timestamp:pt(l.timestamp),weight:typeof l.weight=="number"?l.weight:void 0,archetype:K(l.archetype)}]:[]):[],summary:{approve_count:m(n.summary)?H(n.summary.approve_count,0):0,reject_count:m(n.summary)?H(n.summary.reject_count,0):0,abstain_count:m(n.summary)?H(n.summary.abstain_count,0):0,quorum_met:m(n.summary)?la(n.summary.quorum_met,!1):!1,result:m(n.summary)?K(n.summary.result):null},context:Ni(n.context),judgment:mc(n.judgment)}})}const pm=g(""),se=g({}),$t=g({}),ei=g({}),ca=g({}),ni=g({}),si=g({}),Kt=g({}),wi=new Map,Di=new Map;function ct(t,e,n){t.value={...t.value,[e]:n}}function mm(t){var n;const e=(n=r(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function _m(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function _o(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!m(s))continue;const a=r(s.name);if(!a)continue;const i=r(s[e]);e==="summary"?n.push({name:a,summary:i}):n.push({name:a,reason:i})}return n}function vm(t){if(!m(t))return null;const e=r(t.name);return e?{name:e,trigger:r(t.trigger),outcome:r(t.outcome),summary:r(t.summary),reason:r(t.reason)}:null}function fm(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function gm(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function vc(t,e,n){return r(t)??gm(e,n)}function fc(t,e){return typeof t=="boolean"?t:e==="recover"}function da(t){if(!m(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:r(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:lt(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:u(t.next_eligible_at_s)??null,recoverable:fc(t.recoverable,n),summary:vc(t.summary,e,r(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function gc(t){return m(t)?{hour:u(t.hour),checked:u(t.checked)??0,acted:u(t.acted)??0,acted_names:B(t.acted_names),activity_report:r(t.activity_report),quiet_hours_overridden:z(t.quiet_hours_overridden),skipped_reason:r(t.skipped_reason),acted_rows:_o(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:_o(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:_o(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(vm).filter(e=>e!==null):[]}:null}function $m(t){return m(t)?{enabled:z(t.enabled)??!1,interval_s:u(t.interval_s)??0,quiet_start:u(t.quiet_start),quiet_end:u(t.quiet_end),quiet_active:z(t.quiet_active),use_planner:z(t.use_planner),delegate_llm:z(t.delegate_llm),agent_count:u(t.agent_count),agents:B(t.agents),last_tick_ago_s:u(t.last_tick_ago_s)??null,last_tick_ago:r(t.last_tick_ago),total_ticks:u(t.total_ticks),total_checkins:u(t.total_checkins),last_skip_reason:r(t.last_skip_reason)??null,last_tick_result:gc(t.last_tick_result),active_self_heartbeats:B(t.active_self_heartbeats)}:null}function hm(t){return m(t)?{status:t.status,diagnostic:da(t.diagnostic)}:null}function ym(t){return m(t)?{recovered:z(t.recovered)??!1,skipped_reason:r(t.skipped_reason)??null,before:da(t.before),after:da(t.after),down:t.down,up:t.up}:null}function bm(t,e){var $,R;if(!(t!=null&&t.name))return null;const n=r(($=t.agent)==null?void 0:$.status)??r(t.status)??"unknown",s=r((R=t.agent)==null?void 0:R.error)??null,a=t.presence_keepalive??!0,i=t.keepalive_running??!1,l=t.turn_count??0,c=t.last_turn_ago_s??null,d=t.proactive_enabled??!1,p=t.proactive_cooldown_sec??0,v=t.last_proactive_ago_s??null,_=d&&v!=null?Math.max(0,p-v):null,f=l<=0||c==null?"never":c>900?"stale":"fresh",h=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,C=s??(a&&!i?"keeper keepalive is not running":null),b=n==="offline"||n==="inactive"?"offline":C?"degraded":f==="stale"?"stale":f==="never"?"idle":"healthy",x=C?fm(C):e!=null&&e.quiet_active&&f!=="fresh"?"quiet_hours":a&&!i?"disabled":l<=0?"never_started":_!=null&&_>0?"min_gap":f==="fresh"||f==="stale"?"no_recent_activity":"unknown",y=b==="offline"||b==="degraded"||b==="stale"?"recover":x==="quiet_hours"?"manual_lodge_poke":x==="unknown"?"probe":"direct_message";return{health_state:b,quiet_reason:x,next_action_path:y,last_reply_status:f,last_reply_at:h,last_reply_preview:null,last_error:C,next_eligible_at_s:_!=null&&_>0?_:null,recoverable:fc(void 0,y),summary:vc(void 0,b,x),keepalive_running:i}}function km(t,e){if(!m(t))return null;const n=mm(t.role),s=r(t.content)??r(t.preview);if(!s)return null;const a=Hs(s);if(!a)return null;const i=lt(t.ts_unix)??lt(t.timestamp);return{id:`${n}-${i??"entry"}-${e}`,role:n,label:_m(n),text:a,timestamp:i,delivery:"history",streamState:null,details:null}}function xm(t,e,n){const s=m(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((i,l)=>km(i,l)).filter(i=>i!==null):[];return{name:t,diagnostic:da(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function el(t,e){const n=$t.value[t]??[];$t.value={...$t.value,[t]:[...n,e].slice(-50)}}function Oi(t,e,n){const s=$t.value[t]??[];$t.value={...$t.value,[t]:s.map(a=>a.id===e?n(a):a)}}function vo(t,e,n,s){Oi(t,e,a=>({...a,streamState:n,delivery:s}))}function Sm(t,e,n){Oi(t,e,s=>({...s,text:`${s.text}${n}`,streamState:"streaming",delivery:"streaming"}))}function Yt(t,e,n){Oi(t,e,s=>({...s,...n}))}function Cm(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Am(t,e){const s=($t.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(i=>Cm(a,i)));$t.value={...$t.value,[t]:[...e,...s].slice(-50)}}function Va(t,e){se.value={...se.value,[t]:e},Am(t,e.history)}function Cs(t,e){const n=se.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Va(t,{...n,diagnostic:{...s,...e}})}function Tm(t,e,n){Di.set(t,e),wi.set(t,n)}function $c(t){Di.delete(t),wi.delete(t)}function Im(t){return Di.get(t)??null}function hc(t){const e=t.trim();if(!e)return;const n=wi.get(e),s=Im(e);n&&n.abort(),s&&Yt(e,s,{delivery:"timeout",streamState:null,error:"Stream cancelled",timestamp:new Date().toISOString()}),$c(e),ct(ca,e,!1)}function Rm(t,e,n){switch(n.type){case"RUN_STARTED":return vo(t,e,"opening","sending"),null;case"TEXT_MESSAGE_START":return vo(t,e,"streaming","streaming"),null;case"TEXT_MESSAGE_CONTENT":{const s=typeof n.delta=="string"?n.delta:"";return s&&Sm(t,e,s),null}case"TEXT_MESSAGE_END":return vo(t,e,"finalizing","streaming"),null;case"CUSTOM":if(n.name==="KEEPER_REPLY_DETAILS"){const s=sc(n.value);s&&Yt(t,e,{details:s})}return null;case"RUN_ERROR":return typeof n.value=="string"?n.value:(m(n.value)?r(n.value.message):null)??"Keeper stream failed";default:return null}}async function ua(){try{await _s()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Mm(t){pm.value=t.trim()}async function yc(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&se.value[n])return se.value[n];ct(ei,n,!0),ct(Kt,n,null);try{const s=await Tt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const i=xm(n,s,a);return Va(n,i),i}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return ct(Kt,n,a),null}finally{ct(ei,n,!1)}}async function Em(t,e){var c;const n=t.trim(),s=e.trim();if(!n||!s)return;hc(n);const a=`local-${Date.now()}`,i=`reply-${Date.now()}`;el(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending",streamState:null,details:null}),el(n,{id:i,role:"assistant",label:n,text:"",timestamp:null,delivery:"sending",streamState:"opening",details:null}),ct(ca,n,!0),ct(Kt,n,null);const l=new AbortController;Tm(n,i,l);try{Yt(n,a,{delivery:"delivered"}),await op(n,s,void 0,{signal:l.signal,onEvent:v=>{const _=Rm(n,i,v);if(_)throw new Error(_)}});const d=($t.value[n]??[]).find(v=>v.id===i)??null,p=(d==null?void 0:d.text.trim())||"(empty reply)";Yt(n,i,{text:p,delivery:"delivered",streamState:null,timestamp:new Date().toISOString(),error:null}),Cs(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:p.slice(0,200),last_error:null})}catch(d){if(d instanceof Error&&d.name==="AbortError")throw Yt(n,i,{delivery:"timeout",streamState:null,error:"Stream cancelled",timestamp:new Date().toISOString()}),Cs(n,{last_reply_status:"error",last_error:"Stream cancelled"}),ct(Kt,n,"Stream cancelled"),d;if(!((c=($t.value[n]??[]).find(f=>f.id===i))!=null&&c.text.trim()))try{const f=await sp(n,s);Yt(n,i,{text:f.text.trim()||"(empty reply)",delivery:"delivered",streamState:null,details:f.details,error:null,timestamp:new Date().toISOString()}),Yt(n,a,{delivery:"delivered",error:null}),Cs(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(f.text.trim()||"(empty reply)").slice(0,200),last_error:null}),await ua();return}catch{}const _=d instanceof Error?d.message:`Failed to send direct message to ${n}`;throw Yt(n,i,{delivery:"error",streamState:null,error:_,timestamp:new Date().toISOString()}),Yt(n,a,{delivery:"error",error:_}),Cs(n,{last_reply_status:"error",last_error:_}),ct(Kt,n,_),d}finally{$c(n),ct(ca,n,!1),await ua()}}async function Lm(t,e){const n=t.trim();if(!n)return null;ct(ni,n,!0),ct(Kt,n,null);try{const s=await Ya({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=hm(s.result),i=(a==null?void 0:a.diagnostic)??null;if(i){const l=se.value[n];Va(n,{name:n,diagnostic:i,history:(l==null?void 0:l.history)??$t.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ua(),i}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw ct(Kt,n,a),s}finally{ct(ni,n,!1)}}async function Pm(t,e){const n=t.trim();if(!n)return null;ct(si,n,!0),ct(Kt,n,null);try{const s=await Ya({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=ym(s.result),i=(a==null?void 0:a.after)??null;if(i){const l=se.value[n];Va(n,{name:n,diagnostic:i,history:(l==null?void 0:l.history)??$t.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ua(),i}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw ct(Kt,n,a),s}finally{ct(si,n,!1)}}function Se(t){return(t??"").trim().toLowerCase()}function ht(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Js(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function As(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Sn(t){return t.last_heartbeat??As(t.last_turn_ago_s)??As(t.last_proactive_ago_s)??As(t.last_handoff_ago_s)??As(t.last_compaction_ago_s)}function zm(t){const e=t.title.trim();return e||Js(t.content)}function jm(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function Nm(t,e,n,s,a={}){var R;const i=Se(t),l=e.filter(T=>Se(T.assignee)===i&&(T.status==="claimed"||T.status==="in_progress")).length,c=n.filter(T=>Se(T.from)===i).sort((T,P)=>ht(P.timestamp)-ht(T.timestamp))[0],d=s.filter(T=>Se(T.agent)===i||Se(T.author)===i).sort((T,P)=>ht(P.timestamp)-ht(T.timestamp))[0],p=(a.boardPosts??[]).filter(T=>Se(T.author)===i).sort((T,P)=>ht(P.updated_at||P.created_at)-ht(T.updated_at||T.created_at))[0],v=(a.keepers??[]).filter(T=>Se(T.name)===i&&Sn(T)!==null).sort((T,P)=>ht(Sn(P)??0)-ht(Sn(T)??0))[0],_=c?ht(c.timestamp):0,f=d?ht(d.timestamp):0,h=p?ht(p.updated_at||p.created_at):0,C=v?ht(Sn(v)??0):0,b=a.lastSeen?ht(a.lastSeen):0,x=((R=a.currentTask)==null?void 0:R.trim())||(l>0?`${l} claimed tasks`:null);if(_===0&&f===0&&h===0&&C===0&&b===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:x};const $=[c?{timestamp:c.timestamp,ts:_,text:Js(c.content)}:null,p?{timestamp:p.updated_at||p.created_at,ts:h,text:`Post: ${Js(zm(p))}`}:null,v?{timestamp:Sn(v),ts:C,text:jm(v)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:f,text:Js(d.text)}:null].filter(T=>T!==null).sort((T,P)=>P.ts-T.ts)[0];return $&&$.ts>=b?{activeAssignedCount:l,lastActivityAt:$.timestamp,lastActivityText:$.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:x??"Presence heartbeat"}}const Gt=g([]),de=g([]),ai=g([]),ae=g([]),gt=g(null),wm=g(null),bc=g([]),kc=g([]),xc=g([]),Sc=g([]),Cc=g(null),Ac=g([]),qi=g([]),Tc=g([]),oi=g(new Map),Xa=g([]),Wn=g("recent"),Me=g(!0),Ic=g(null),ee=g(""),sn=g([]),Pn=g(!1),Rc=g(new Map),Fi=g("unknown"),an=g(null),ii=g(!1),Hn=g(!1),ri=g(!1),zn=g(!1),Bi=g(null),pa=g(!1),ma=g(null),Mc=g(null),li=g(null),Dm=g(null),Om=g(null),qm=g(null);Et(()=>Gt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const Ec=Et(()=>{const t=de.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Lc=Et(()=>{const t=new Map,e=de.value,n=ai.value,s=ia.value,a=Xa.value,i=ae.value;for(const l of Gt.value)t.set(l.name.trim().toLowerCase(),Nm(l.name,e,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:i}));return t});function Fm(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}Et(()=>{const t=new Map;for(const e of ae.value)t.set(e.name,Fm(e));return t});const Bm=12e4;function Km(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof a=="number"?Date.now()-a*1e3:null}Et(()=>{const t=Date.now(),e=new Set,n=oi.value;for(const s of ae.value){const a=Km(s,n);a!=null&&t-a>Bm&&e.add(s.name)}return e});function Um(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function Pc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Wm(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Hm(t){if(!m(t))return null;const e=r(t.name);return e?{name:e,agent_type:r(t.agent_type),status:Pc(t.status),current_task:r(t.current_task)??null,joined_at:r(t.joined_at),last_seen:r(t.last_seen),capabilities:B(t.capabilities),emoji:r(t.emoji),koreanName:r(t.koreanName)??r(t.korean_name),model:r(t.model),traits:B(t.traits),interests:B(t.interests),activityLevel:u(t.activityLevel)??u(t.activity_level),primaryValue:r(t.primaryValue)??r(t.primary_value)}:null}function Gm(t){if(!m(t))return null;const e=r(t.id),n=r(t.title);return!e||!n?null:{id:e,title:n,status:Wm(t.status),priority:u(t.priority),assignee:r(t.assignee),description:r(t.description),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function Jm(t){if(!m(t))return null;const e=r(t.from)??r(t.from_agent)??"system",n=r(t.content)??"",s=r(t.timestamp)??new Date().toISOString();return{id:r(t.id),seq:u(t.seq),from:e,content:n,timestamp:s,type:r(t.type)}}function Ki(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="ok"||e==="warn"||e==="bad"?e:"ok"}function ue(t){if(!m(t))return null;const e=r(t.surface),n=r(t.label),s=r(t.target_type),a=r(t.target_id),i=r(t.focus_kind);return!e||!n||!s||!a||!i?null:{surface:e==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:i,operation_id:r(t.operation_id)??null,command_surface:r(t.command_surface)??null}}function Ym(t){if(!m(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.summary),a=r(t.target_type),i=r(t.target_id);return!e||!s||!a||!i||n!=="session"&&n!=="operation"?null:{id:e,kind:n,severity:Ki(t.severity),status:r(t.status),summary:s,target_type:a,target_id:i,linked_session_id:r(t.linked_session_id)??null,linked_operation_id:r(t.linked_operation_id)??null,last_seen_at:r(t.last_seen_at)??null,top_handoff:ue(t.top_handoff),intervene_handoff:ue(t.intervene_handoff),command_handoff:ue(t.command_handoff)}}function Vm(t){if(!m(t))return null;const e=r(t.session_id),n=r(t.goal);return!e||!n?null:{session_id:e,goal:n,room:r(t.room)??null,status:r(t.status),health:r(t.health),member_names:B(t.member_names),linked_operation_id:r(t.linked_operation_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,runtime_blocker:r(t.runtime_blocker)??null,worker_gap_summary:r(t.worker_gap_summary)??null,last_activity_at:r(t.last_activity_at)??null,last_activity_summary:r(t.last_activity_summary)??null,communication_summary:r(t.communication_summary)??null,active_count:u(t.active_count),required_count:u(t.required_count),top_handoff:ue(t.top_handoff),intervene_handoff:ue(t.intervene_handoff),command_handoff:ue(t.command_handoff)}}function Xm(t){if(!m(t))return null;const e=r(t.operation_id),n=r(t.objective);return!e||!n?null:{operation_id:e,objective:n,status:r(t.status),stage:r(t.stage)??null,assigned_unit_id:r(t.assigned_unit_id)??null,assigned_unit_label:r(t.assigned_unit_label)??null,linked_session_id:r(t.linked_session_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,blocker_summary:r(t.blocker_summary)??null,search_status:r(t.search_status)??null,next_tool:r(t.next_tool)??null,updated_at:r(t.updated_at)??null,top_handoff:ue(t.top_handoff),command_handoff:ue(t.command_handoff)}}function nl(t){if(!m(t))return null;const e=r(t.name)??r(t.agent_name),n=r(t.note),s=r(t.focus),a=r(t.state);return!e||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline"?null:{name:e,agent_name:r(t.agent_name),status:r(t.status),tone:Ki(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,active_task_count:u(t.active_task_count),related_session_id:r(t.related_session_id)??null,related_operation_id:r(t.related_operation_id)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),model:r(t.model)??null,recent_output_preview:r(t.recent_output_preview)??null,recent_event:r(t.recent_event)??null}}function Qm(t){return m(t)?{checked:u(t.checked),acted:u(t.acted),passed:u(t.passed),skipped:u(t.skipped),failed:u(t.failed),last_tick_at:r(t.last_tick_at)??null,last_skip_reason:r(t.last_skip_reason)??null,activity_report:r(t.activity_report)??null}:null}function Zm(t){if(!m(t))return null;const e=r(t.agent_name),n=r(t.outcome);return!e||!n?null:{agent_name:e,trigger:r(t.trigger)??null,outcome:n,summary:r(t.summary)??null,reason:r(t.reason)??null,allowed_tool_names:B(t.allowed_tool_names)??[],used_tool_names:B(t.used_tool_names)??[],used_tool_call_count:u(t.used_tool_call_count)??null,action_kind:r(t.action_kind)??"none",tool_audit_source:r(t.tool_audit_source)??null,tool_audit_at:r(t.tool_audit_at)??null,checked_at:r(t.checked_at)??null,decision_reason:r(t.decision_reason)??null,worker_name:r(t.worker_name)??null,failure_reason:r(t.failure_reason)??null}}function t_(t){if(!m(t))return null;const e=r(t.name),n=r(t.note),s=r(t.focus),a=r(t.state);return!e||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:e,agent_name:r(t.agent_name)??null,status:r(t.status),tone:Ki(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,last_autonomous_action_at:r(t.last_autonomous_action_at)??null,generation:u(t.generation),turn_count:u(t.turn_count),context_ratio:u(t.context_ratio)??null,continuity:r(t.continuity)??null,lifecycle:r(t.lifecycle)??null,related_session_id:r(t.related_session_id)??null,model:r(t.model)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),skill_reason:r(t.skill_reason)??null,recent_input_preview:r(t.recent_input_preview)??null,recent_output_preview:r(t.recent_output_preview)??null,recent_tool_names:B(t.recent_tool_names)??[],allowed_tool_names:B(t.allowed_tool_names)??[],latest_tool_names:B(t.latest_tool_names)??[],latest_tool_call_count:u(t.latest_tool_call_count)??null,tool_audit_source:r(t.tool_audit_source)??null,tool_audit_at:r(t.tool_audit_at)??null,last_proactive_preview:r(t.last_proactive_preview)??null,continuity_summary:r(t.continuity_summary)??null,skill_route_summary:r(t.skill_route_summary)??null}}function sl(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function e_(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>sl(s)-sl(a)).slice(-500)}function n_(t){return Array.isArray(t)?t.map(e=>{if(!m(e))return null;const n=u(e.ts_unix);if(n==null)return null;const s=m(e.handoff)?e.handoff:null;return{ts:n,context_ratio:u(e.context_ratio)??0,context_tokens:u(e.context_tokens)??0,context_max:u(e.context_max)??0,latency_ms:u(e.latency_ms)??0,generation:u(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:u(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:u(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?u(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function al(t){if(!m(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);if(!e||!n||!s)return null;const a=r(t.quiet_reason)??null,i=r(t.summary)??(e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:lt(t.last_reply_at)??r(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:u(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:i,keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function s_(t,e){return(Array.isArray(t)?t:m(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(s=>{if(!m(s))return null;const a=m(s.agent)?s.agent:null,i=m(s.context)?s.context:null,l=m(s.metrics_window)?s.metrics_window:void 0,c=r(s.name);if(!c)return null;const d=u(s.context_ratio)??u(i==null?void 0:i.context_ratio),p=r(s.status)??r(a==null?void 0:a.status)??"offline",v=Pc(p),_=r(s.model)??r(s.active_model)??r(s.primary_model),f=B(s.skill_secondary),h=i?{source:r(i.source),context_ratio:u(i.context_ratio),context_tokens:u(i.context_tokens),context_max:u(i.context_max),message_count:u(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,C=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:u(a.last_seen_ago_s),capabilities:B(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,b=n_(s.metrics_series),x={name:c,runtime_class:s.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:typeof s.desired=="boolean"?s.desired:void 0,resident_registered:typeof s.resident_registered=="boolean"?s.resident_registered:void 0,reconcile_status:r(s.reconcile_status)??null,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:_,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:v,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:u(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:u(s.proactive_idle_sec),proactive_cooldown_sec:u(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:u(s.generation),turn_count:u(s.turn_count)??u(s.total_turns),keeper_age_s:u(s.keeper_age_s),last_turn_ago_s:u(s.last_turn_ago_s),last_handoff_ago_s:u(s.last_handoff_ago_s),last_compaction_ago_s:u(s.last_compaction_ago_s),last_proactive_ago_s:u(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:d,context_tokens:u(s.context_tokens)??u(i==null?void 0:i.context_tokens),context_max:u(s.context_max)??u(i==null?void 0:i.context_max),context_source:r(s.context_source)??r(i==null?void 0:i.source),context:h,traits:B(s.traits),interests:B(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:u(s.activityLevel)??u(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:B(s.recent_tool_names)??[],allowed_tool_names:B(s.allowed_tool_names)??[],latest_tool_names:B(s.latest_tool_names)??[],latest_tool_call_count:u(s.latest_tool_call_count)??null,tool_audit_source:r(s.tool_audit_source)??null,tool_audit_at:lt(s.tool_audit_at)??r(s.tool_audit_at)??null,conversation_tail_count:u(s.conversation_tail_count),k2k_count:u(s.k2k_count),handoff_count_total:u(s.handoff_count_total)??u(s.trace_history_count),compaction_count:u(s.compaction_count),last_compaction_saved_tokens:u(s.last_compaction_saved_tokens),diagnostic:al(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:f,skill_reason:r(s.skill_reason)??null,metrics_series:b.length>0?b:void 0,metrics_window:l,agent:C};return x.diagnostic=al(s.diagnostic)??bm(x,(e==null?void 0:e.lodge)??null),x}).filter(s=>s!==null)}function a_(t){if(!m(t))return;const e=r(t.release_version),n=lt(t.started_at),s=u(t.uptime_seconds);if(!(!e||!n||s==null))return{release_version:e,commit:r(t.commit)??null,started_at:n,uptime_seconds:s}}function o_(t){if(m(t))return{enabled:t.enabled===!0,alive:t.alive===!0,status:r(t.status)??void 0,tick_in_progress:typeof t.tick_in_progress=="boolean"?t.tick_in_progress:void 0,tick_count:u(t.tick_count)??void 0,check_interval_sec:u(t.check_interval_sec)??void 0,last_tick_started_at:lt(t.last_tick_started_at)??r(t.last_tick_started_at)??null,last_tick_completed_at:lt(t.last_tick_completed_at)??r(t.last_tick_completed_at)??null,next_tick_due_at:lt(t.next_tick_due_at)??r(t.next_tick_due_at)??null,last_health_check_at:lt(t.last_health_check_at)??r(t.last_health_check_at)??null,last_intervention:r(t.last_intervention)??void 0,last_decision_source:r(t.last_decision_source)??void 0,last_action:r(t.last_action)??void 0,last_target:r(t.last_target)??null,last_reason:r(t.last_reason)??null,last_error:r(t.last_error)??null,circuit_open:typeof t.circuit_open=="boolean"?t.circuit_open:void 0,circuit_open_until:lt(t.circuit_open_until)??r(t.circuit_open_until)??null,can_spawn:typeof t.can_spawn=="boolean"?t.can_spawn:void 0,can_retire:typeof t.can_retire=="boolean"?t.can_retire:void 0,last_spawn_attempt_at:lt(t.last_spawn_attempt_at)??r(t.last_spawn_attempt_at)??null,last_retirement_attempt_at:lt(t.last_retirement_attempt_at)??r(t.last_retirement_attempt_at)??null,spawns_today:u(t.spawns_today)??void 0,retirements_today:u(t.retirements_today)??void 0,health_summary:m(t.health_summary)?{total_agents:u(t.health_summary.total_agents)??void 0,active_agents:u(t.health_summary.active_agents)??void 0,idle_agents:u(t.health_summary.idle_agents)??void 0,todo_count:u(t.health_summary.todo_count)??void 0,high_priority_todo:u(t.health_summary.high_priority_todo)??void 0,orphan_count:u(t.health_summary.orphan_count)??void 0,homeostatic_score:u(t.health_summary.homeostatic_score)??void 0,needs_workers:typeof t.health_summary.needs_workers=="boolean"?t.health_summary.needs_workers:void 0}:void 0}}function i_(t){if(m(t))return{enabled:t.enabled===!0,mode:r(t.mode)??void 0,masc_enabled:typeof t.masc_enabled=="boolean"?t.masc_enabled:void 0,masc_loops_running:typeof t.masc_loops_running=="boolean"?t.masc_loops_running:void 0,runtime_owner:r(t.runtime_owner)??null,zombie_loop_running:typeof t.zombie_loop_running=="boolean"?t.zombie_loop_running:void 0,gc_loop_running:typeof t.gc_loop_running=="boolean"?t.gc_loop_running:void 0,lodge_enabled:typeof t.lodge_enabled=="boolean"?t.lodge_enabled:void 0,lodge_loop_started:typeof t.lodge_loop_started=="boolean"?t.lodge_loop_started:void 0,lodge_running:typeof t.lodge_running=="boolean"?t.lodge_running:void 0,last_zombie_cleanup:lt(t.last_zombie_cleanup)??r(t.last_zombie_cleanup)??null,last_gc:lt(t.last_gc)??r(t.last_gc)??null,last_lodge:lt(t.last_lodge)??r(t.last_lodge)??null,last_zombie_result:r(t.last_zombie_result)??null,last_gc_result:r(t.last_gc_result)??null,last_lodge_result:m(t.last_lodge_result)?{ok:typeof t.last_lodge_result.ok=="boolean"?t.last_lodge_result.ok:void 0,message:r(t.last_lodge_result.message)??void 0}:null}}function r_(t){if(m(t))return{enabled:t.enabled===!0,started:t.started===!0,agent_name:r(t.agent_name)??null,llm_enabled:typeof t.llm_enabled=="boolean"?t.llm_enabled:void 0,uptime_s:u(t.uptime_s)??void 0,embedded_guardian_loops_running:typeof t.embedded_guardian_loops_running=="boolean"?t.embedded_guardian_loops_running:void 0,guardian_runtime_owner:r(t.guardian_runtime_owner)??null,consumers:B(t.consumers)}}function zc(t,e){return m(t)?{...t,generated_at:e??lt(t.generated_at)??void 0,build:a_(t.build),lodge:$m(t.lodge)??void 0,gardener:o_(t.gardener)??void 0,guardian:i_(t.guardian)??void 0,sentinel:r_(t.sentinel)??void 0}:null}function jc(t,e){return e?t?{...t,...e,build:e.build??t.build,generated_at:e.generated_at??t.generated_at}:e:t}function l_(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function c_(t){if(!m(t))return null;const e=u(t.iteration);if(e==null)return null;const n=u(t.metric_before)??0,s=u(t.metric_after)??n,a=m(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:u(t.delta)??s-n,changes:r(t.changes)??"",failed_attempts:r(t.failed_attempts)??"",next_suggestion:r(t.next_suggestion)??"",elapsed_ms:u(t.elapsed_ms)??0,cost_usd:u(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:u(a.tool_call_count)??0,tool_names:B(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function d_(t){var i,l;if(!m(t))return null;const e=r(t.loop_id);if(!e)return null;const n=u(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(c_).filter(c=>c!==null):[],a=u(t.current_metric)??((i=s[0])==null?void 0:i.metric_after)??n;return{loop_id:e,profile:r(t.profile)??"unknown",status:l_(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:r(t.error_message)??r(t.error_reason)??null,stop_reason:r(t.stop_reason)??r(t.reason)??null,current_iteration:u(t.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:u(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(t.target)??"",stagnation_streak:u(t.stagnation_streak)??0,stagnation_limit:u(t.stagnation_limit)??0,elapsed_seconds:u(t.elapsed_seconds)??0,updated_at:lt(t.updated_at)??null,stopped_at:lt(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:u(t.latest_tool_call_count)??0,latest_tool_names:B(t.latest_tool_names)??[],session_id:r(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function _s(){ii.value=!0;try{await Promise.all([wc(),Ee()]),Mc.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{ii.value=!1}}async function Nc(){pa.value=!0,ma.value=null;try{const t=await up();Bi.value=t,qm.value=new Date().toISOString()}catch(t){ma.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{pa.value=!1}}function u_(t){var e;return((e=Bi.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function p_(t){var n;const e=((n=Bi.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(i=>i.id===t);if(a)return a}return null}function m_(t){var s,a;sn.value=(Array.isArray(t.goals)?t.goals:[]).map(i=>{if(!m(i))return null;const l=r(i.id),c=r(i.title),d=r(i.horizon),p=r(i.status),v=r(i.created_at),_=r(i.updated_at);return!l||!c||!d||!p||!v||!_?null:{id:l,horizon:d,title:c,metric:r(i.metric)??null,target_value:r(i.target_value)??null,due_date:r(i.due_date)??null,priority:u(i.priority)??3,status:p,parent_goal_id:r(i.parent_goal_id)??null,last_review_note:r(i.last_review_note)??null,last_review_at:r(i.last_review_at)??null,created_at:v,updated_at:_}}).filter(i=>i!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const i of n){const l=d_(i);l&&e.set(l.loop_id,l)}Rc.value=e,an.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,Fi.value=an.value?"error":e.size===0?"idle":"ready"}async function wc(){try{const t=await ip(),e=zc(t.status,t.generated_at);e&&(gt.value=jc(gt.value,e))}catch(t){console.error("Dashboard shell fetch error:",t)}}async function Ee(){var t;try{const e=await lp(),n=zc(e.status,e.generated_at),s=(t=gt.value)==null?void 0:t.room;n&&(gt.value=jc(gt.value,n));const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Gt.value=(Array.isArray(e.agents)?e.agents:[]).map(Hm).filter(l=>l!==null),de.value=(Array.isArray(e.tasks)?e.tasks:[]).map(Gm).filter(l=>l!==null);const i=(Array.isArray(e.messages)?e.messages:[]).map(Jm).filter(l=>l!==null);ai.value=a?i:e_(ai.value,i),ae.value=s_(e.keepers,n??gt.value),Cc.value=Qm(e.lodge_tick),Ac.value=(Array.isArray(e.lodge_checkins)?e.lodge_checkins:[]).map(Zm).filter(l=>l!==null),bc.value=(Array.isArray(e.execution_queue)?e.execution_queue:Array.isArray(e.priority_queue)?e.priority_queue:[]).map(Ym).filter(l=>l!==null),kc.value=(Array.isArray(e.session_briefs)?e.session_briefs:[]).map(Vm).filter(l=>l!==null),xc.value=(Array.isArray(e.operation_briefs)?e.operation_briefs:[]).map(Xm).filter(l=>l!==null),Sc.value=(Array.isArray(e.worker_support_briefs)?e.worker_support_briefs:Array.isArray(e.worker_briefs)?e.worker_briefs:[]).map(nl).filter(l=>l!==null),qi.value=(Array.isArray(e.continuity_briefs)?e.continuity_briefs:[]).map(t_).filter(l=>l!==null),Tc.value=(Array.isArray(e.offline_worker_briefs)?e.offline_worker_briefs:[]).map(nl).filter(l=>l!==null),wm.value=null,Mc.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function pe(){Hn.value=!0;try{const t=await cp(Wn.value,{excludeSystem:Me.value});Xa.value=t.posts??[],li.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Hn.value=!1}}async function me(){var t;ri.value=!0;try{const e=ee.value||((t=gt.value)==null?void 0:t.room)||"default";ee.value||(ee.value=e);const n=await Xp(e);Ic.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{ri.value=!1}}async function Ui(){Pn.value=!0,zn.value=!0;try{const t=await fp();m_(t),Dm.value=new Date().toISOString(),Om.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),Fi.value="error",an.value=t instanceof Error?t.message:String(t)}finally{Pn.value=!1,zn.value=!1}}async function Dc(){return Ui()}const Wi=g(null),ci=g(!1),_a=g(null);function __(t){return m(t)?{room:r(t.room)??r(t.current_room),room_base_path:r(t.room_base_path),cluster:r(t.cluster),project:r(t.project),paused:z(t.paused),version:r(t.version),generated_at:r(t.generated_at),tempo_interval_s:u(t.tempo_interval_s)}:null}function v_(t){return m(t)?{active_sessions:u(t.active_sessions),blocked_sessions:u(t.blocked_sessions),active_operations:u(t.active_operations),blocked_operations:u(t.blocked_operations),runtime_pressure:u(t.runtime_pressure),worker_alerts:u(t.worker_alerts),continuity_alerts:u(t.continuity_alerts),priority_items:u(t.priority_items),keepers:u(t.keepers)}:null}function f_(t){if(!m(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.severity),a=r(t.summary),i=r(t.target_type),l=r(t.target_id);return!e||!n||!s||!a||!i||!l?null:{id:e,kind:n,severity:s,summary:a,target_type:i,target_id:l,status:r(t.status),linked_session_id:r(t.linked_session_id)??null,linked_operation_id:r(t.linked_operation_id)??null,last_seen_at:r(t.last_seen_at)??null,top_handoff:m(t.top_handoff)?t.top_handoff:null,intervene_handoff:m(t.intervene_handoff)?t.intervene_handoff:null,command_handoff:m(t.command_handoff)?t.command_handoff:null}}function g_(t){if(!m(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function $_(t){if(!m(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:z(t.confirm_required),suggested_payload:m(t.suggested_payload)?t.suggested_payload:void 0,preview:t.preview}}function h_(t){return m(t)?{actor_filter:r(t.actor_filter)??null,filter_active:z(t.filter_active)??!1,visible_count:u(t.visible_count)??0,total_count:u(t.total_count)??0,hidden_count:u(t.hidden_count)??0,hidden_actors:B(t.hidden_actors),confirm_required_actions:dt(t.confirm_required_actions).flatMap(e=>{if(!m(e))return[];const n=r(e.action_type),s=r(e.target_type);return!n||!s?[]:[{action_type:n,target_type:s,description:r(e.description),confirm_required:z(e.confirm_required)}]})}:null}function y_(t){return m(t)?{count:u(t.count)??0,bad_count:u(t.bad_count)??0,warn_count:u(t.warn_count)??0,provenance:r(t.provenance)??null,top_item:g_(t.top_item)}:null}function b_(t){return m(t)?{count:u(t.count)??0,provenance:r(t.provenance)??null,top_action:$_(t.top_action)}:null}function k_(t){if(!m(t))return null;const e=r(t.label),n=r(t.reason),s=r(t.source),a=r(t.provenance);return!e||!n||!s||!a?null:{label:e,reason:n,source:s,provenance:a,target_kind:r(t.target_kind)??null,target_id:r(t.target_id)??null,suggested_tab:r(t.suggested_tab)??null,suggested_surface:r(t.suggested_surface)??null,suggested_params:m(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([i,l])=>{const c=r(l);return c?[i,c]:null}).filter(i=>i!==null)):{}}}function x_(t){const e=m(t)?t:{},n=m(e.room)?e.room:{},s=m(e.execution)?e.execution:{},a=m(e.command)?e.command:{},i=m(e.operator)?e.operator:{};return{generated_at:r(e.generated_at),room:{status:__(n.status),counts:m(n.counts)?{agents:u(n.counts.agents),tasks:u(n.counts.tasks),keepers:u(n.counts.keepers)}:void 0,provenance:r(n.provenance)??null},execution:{summary:v_(s.summary),top_queue:f_(s.top_queue),provenance:r(s.provenance)??null},command:{active_operations:u(a.active_operations),active_detachments:u(a.active_detachments),pending_approvals:u(a.pending_approvals),bad_alerts:u(a.bad_alerts),warn_alerts:u(a.warn_alerts),moving_lanes:u(a.moving_lanes),active_lanes:u(a.active_lanes),provenance:r(a.provenance)??null},operator:{health:r(i.health)??null,attention_summary:y_(i.attention_summary),recommendation_summary:b_(i.recommendation_summary),pending_confirm_summary:h_(i.pending_confirm_summary),provenance:r(i.provenance)??null},focus:k_(e.focus)}}async function Le(){ci.value=!0,_a.value=null;try{const t=await rp();Wi.value=x_(t)}catch(t){_a.value=t instanceof Error?t.message:"Failed to load room truth"}finally{ci.value=!1}}let Ys=null;function S_(t){Ys=t}let Vs=null;function C_(t){Vs=t}let Xs=null;function A_(t){Xs=t}const Pe={};let fo=null;function Ce(t,e,n=500){Pe[t]&&clearTimeout(Pe[t]),Pe[t]=setTimeout(()=>{e(),delete Pe[t]},n)}function T_(){const t=tc.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(oi.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),oi.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&Ce("execution",Ee),Um(e.type)&&(fo||(fo=setTimeout(()=>{_s(),Vs==null||Vs(),Xs==null||Xs(),fo=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&Ce("execution",Ee),e.type==="broadcast"&&Ce("execution",Ee),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&Ce("execution",Ee),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&Ce("board",pe),e.type.startsWith("decision_")&&Ce("council",()=>Ys==null?void 0:Ys()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&Ce("mdal",Dc,350)}});return()=>{t();for(const e of Object.keys(Pe))clearTimeout(Pe[e]),delete Pe[e]}}let jn=null;function I_(){jn||(jn=setInterval(()=>{fe.value,_s()},1e4))}function R_(){jn&&(clearInterval(jn),jn=null)}const Lt=g(null),Hi=g(null),Wt=g(null),Gn=g(!1),ge=g(null),Jn=g(!1),_n=g(null),at=g(!1),va=g([]);let M_=1;function E_(t){return m(t)?{id:r(t.id),seq:u(t.seq),from:r(t.from)??r(t.from_agent)??"system",content:r(t.content)??"",timestamp:r(t.timestamp)??new Date().toISOString(),type:r(t.type)}:null}function L_(t){return m(t)?{room_id:r(t.room_id),current_room:r(t.current_room)??r(t.room),project:r(t.project),cluster:r(t.cluster),paused:z(t.paused),pause_reason:r(t.pause_reason)??null,paused_by:r(t.paused_by)??null,paused_at:r(t.paused_at)??null}:{}}function ol(t){if(!m(t))return;const e=Object.entries(t).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Oc(t){if(!m(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function Nn(t){if(!m(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:z(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function qc(t){return m(t)?{enabled:z(t.enabled),judge_online:z(t.judge_online),refreshing:z(t.refreshing),generated_at:r(t.generated_at)??null,expires_at:r(t.expires_at)??null,model_used:r(t.model_used)??null,keeper_name:r(t.keeper_name)??null,last_error:r(t.last_error)??null}:null}function go(t){return m(t)?{summary:r(t.summary)??null,confidence:u(t.confidence)??null,provenance:r(t.provenance)??null,authoritative:z(t.authoritative),surface:r(t.surface)??null,fresh_until:r(t.fresh_until)??null,keeper_name:r(t.keeper_name)??null,fallback_used:z(t.fallback_used),disagreement_with_truth:z(t.disagreement_with_truth)}:null}function P_(t){return m(t)?{judgment_id:r(t.judgment_id)??void 0,surface:r(t.surface)??null,target_type:r(t.target_type)??null,target_id:r(t.target_id)??null,status:r(t.status)??null,summary:r(t.summary)??null,confidence:u(t.confidence)??null,generated_at:r(t.generated_at)??null,fresh_until:r(t.fresh_until)??null,keeper_name:r(t.keeper_name)??null,model_name:r(t.model_name)??null,runtime_name:r(t.runtime_name)??null,evidence_refs:B(t.evidence_refs),recommended_action:Nn(t.recommended_action),supersedes:B(t.supersedes),fallback_used:z(t.fallback_used),disagreement_with_truth:z(t.disagreement_with_truth),provenance:r(t.provenance)??null}:null}function z_(t){return m(t)?{actor:r(t.actor)??null,spawn_agent:r(t.spawn_agent)??null,spawn_role:r(t.spawn_role)??null,spawn_model:r(t.spawn_model)??null,worker_class:r(t.worker_class)??null,parent_actor:r(t.parent_actor)??null,capsule_mode:r(t.capsule_mode)??null,runtime_pool:r(t.runtime_pool)??null,lane_id:r(t.lane_id)??null,controller_level:r(t.controller_level)??null,control_domain:r(t.control_domain)??null,supervisor_actor:r(t.supervisor_actor)??null,model_tier:r(t.model_tier)??null,task_profile:r(t.task_profile)??null,risk_level:r(t.risk_level)??null,routing_confidence:u(t.routing_confidence)??null,routing_reason:r(t.routing_reason)??null,status:r(t.status)??"unknown",turn_count:u(t.turn_count)??0,empty_note_turn_count:u(t.empty_note_turn_count)??0,has_turn:z(t.has_turn)??!1,last_turn_ts_iso:r(t.last_turn_ts_iso)??null}:null}function j_(t){if(!m(t))return null;const e=r(t.session_id);return e?{session_id:e,goal:r(t.goal),status:r(t.status),health:r(t.health),scale_profile:r(t.scale_profile),control_profile:r(t.control_profile),planned_worker_count:u(t.planned_worker_count),active_agent_count:u(t.active_agent_count),last_turn_age_sec:u(t.last_turn_age_sec)??null,attention_count:u(t.attention_count),recommended_action_count:u(t.recommended_action_count),top_attention:Oc(t.top_attention),top_recommendation:Nn(t.top_recommendation)}:null}function il(t){if(!m(t))return null;const e=r(t.loop_id),n=r(t.status);return!e&&!n?null:{loop_id:e??null,session_id:r(t.session_id)??null,status:n??null,current_cycle:u(t.current_cycle)??void 0,best_score:u(t.best_score)??null,last_decision:r(t.last_decision)??null,target_file:r(t.target_file)??null,workdir:r(t.workdir)??null,source_workdir:r(t.source_workdir)??null,program_note:r(t.program_note)??null,operation_id:r(t.operation_id)??null,queued_hypothesis:r(t.queued_hypothesis)??null,warnings:dt(t.warnings).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),error:r(t.error)??null}}function Fc(t){const e=m(t)?t:{};return{trace_id:r(e.trace_id),target_type:r(e.target_type)??"room",target_id:r(e.target_id)??null,health:r(e.health),judgment_owner:r(e.judgment_owner)??null,authoritative_judgment_available:z(e.authoritative_judgment_available),resident_judge_runtime:qc(e.resident_judge_runtime),judgment:P_(e.judgment),active_guidance_layer:r(e.active_guidance_layer)??null,active_summary:go(e.active_summary),active_recommended_actions:dt(e.active_recommended_actions).map(Nn).filter(n=>n!==null),active_recommendation_source:r(e.active_recommendation_source)??null,active_recommendation_summary:go(e.active_recommendation_summary),fallback_recommended_actions:dt(e.fallback_recommended_actions).map(Nn).filter(n=>n!==null),recommendation_summary:go(e.recommendation_summary),swarm_status:m(e.swarm_status)?e.swarm_status:void 0,attention_items:dt(e.attention_items).map(Oc).filter(n=>n!==null),recommended_actions:dt(e.recommended_actions).map(Nn).filter(n=>n!==null),session_cards:dt(e.session_cards).map(j_).filter(n=>n!==null),worker_cards:dt(e.worker_cards).map(z_).filter(n=>n!==null)}}function N_(t){if(!m(t))return null;const e=m(t.status)?t.status:void 0,n=m(t.summary)?t.summary:m(e==null?void 0:e.summary)?e.summary:void 0,s=m(t.session)?t.session:m(e==null?void 0:e.session)?e.session:void 0,a=r(t.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const i=ol(t.report_paths)??ol(e==null?void 0:e.report_paths),l=dt(t.recent_events,["events"]).filter(m);return{session_id:a,status:r(t.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:u(t.progress_pct)??u(n==null?void 0:n.progress_pct),elapsed_sec:u(t.elapsed_sec)??u(n==null?void 0:n.elapsed_sec),remaining_sec:u(t.remaining_sec)??u(n==null?void 0:n.remaining_sec),done_delta_total:u(t.done_delta_total)??u(n==null?void 0:n.done_delta_total),summary:n,team_health:m(t.team_health)?t.team_health:m(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:m(t.communication_metrics)?t.communication_metrics:m(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:m(t.orchestration_state)?t.orchestration_state:m(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:m(t.cascade_metrics)?t.cascade_metrics:m(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,linked_autoresearch:il(t.linked_autoresearch)??il(e==null?void 0:e.linked_autoresearch)??null,session:s,recent_events:l}}function rl(t){if(!m(t))return null;const e=r(t.name);if(!e)return null;const n=m(t.context)?t.context:void 0;return{name:e,runtime_class:t.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:z(t.desired),resident_registered:z(t.resident_registered),agent_name:r(t.agent_name),status:r(t.status),autonomy_level:r(t.autonomy_level),context_ratio:u(t.context_ratio)??u(n==null?void 0:n.context_ratio),generation:u(t.generation),active_goal_ids:B(t.active_goal_ids),last_autonomous_action_at:r(t.last_autonomous_action_at)??null,last_turn_ago_s:u(t.last_turn_ago_s),model:r(t.model)??r(t.active_model)??r(t.primary_model)}}function w_(t){if(!m(t))return null;const e=r(t.confirm_token)??r(t.token);return e?{confirm_token:e,actor:r(t.actor),action_type:r(t.action_type),target_type:r(t.target_type),target_id:r(t.target_id)??null,delegated_tool:r(t.delegated_tool),created_at:r(t.created_at),preview:t.preview}:null}function Bc(t){if(!m(t))return null;const e=r(t.action_type),n=r(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:r(t.description),confirm_required:z(t.confirm_required)}}function D_(t){return m(t)?{actor_filter:r(t.actor_filter)??null,filter_active:z(t.filter_active)??!1,visible_count:u(t.visible_count)??0,total_count:u(t.total_count)??0,hidden_count:u(t.hidden_count)??0,hidden_actors:B(t.hidden_actors),confirm_required_actions:dt(t.confirm_required_actions).map(Bc).filter(e=>e!==null)}:null}function O_(t){const e=m(t)?t:{};return{room:L_(e.room),sessions:dt(e.sessions,["items","sessions"]).map(N_).filter(n=>n!==null),keepers:dt(e.keepers,["items","keepers"]).map(rl).filter(n=>n!==null),resident_judge_runtime:qc(e.resident_judge_runtime),persistent_agents:dt(e.persistent_agents,["items","persistent_agents"]).map(rl).filter(n=>n!==null),recent_messages:dt(e.recent_messages,["messages"]).map(E_).filter(n=>n!==null),pending_confirms:dt(e.pending_confirms,["items","confirms"]).map(w_).filter(n=>n!==null),pending_confirm_summary:D_(e.pending_confirm_summary)??void 0,available_actions:dt(e.available_actions,["actions"]).map(Bc).filter(n=>n!==null)}}function Ts(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function ll(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function fa(t){va.value=[{...t,id:M_++,at:new Date().toISOString()},...va.value].slice(0,20)}function Kc(t){return t.confirm_required?Ts(t.preview)||"Confirmation required":Ts(t.result)||Ts(t.executed_action)||Ts(t.delegated_tool_result)||t.status}async function _t(){Gn.value=!0,ge.value=null;try{const t=await hp();Lt.value=O_(t)}catch(t){ge.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Gn.value=!1}}async function Oe(){Jn.value=!0,_n.value=null;try{const t=await rc({targetType:"room"});Hi.value=Fc(t)}catch(t){_n.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{Jn.value=!1}}async function $e(t){if(!t){Wt.value=null;return}Jn.value=!0,_n.value=null;try{const e=await rc({targetType:"team_session",targetId:t,includeWorkers:!0});Wt.value=Fc(e)}catch(e){_n.value=e instanceof Error?e.message:"Failed to load session digest"}finally{Jn.value=!1}}async function Uc(t){var e;at.value=!0,ge.value=null;try{const n=await Ya(t);return fa({actor:t.actor,action_type:t.action_type,target_label:ll(t),outcome:n.confirm_required?"preview":"executed",message:Kc(n),delegated_tool:n.delegated_tool}),await _t(),await Oe(),(e=Wt.value)!=null&&e.target_id&&await $e(Wt.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw ge.value=s,fa({actor:t.actor,action_type:t.action_type,target_label:ll(t),outcome:"error",message:s}),n}finally{at.value=!1}}async function Wc(t,e,n="confirm"){var s;at.value=!0,ge.value=null;try{const a=await lc(t,e,n);return fa({actor:t,action_type:n,target_label:e,outcome:"confirmed",message:Kc(a),delegated_tool:a.delegated_tool}),await _t(),await Oe(),(s=Wt.value)!=null&&s.target_id&&await $e(Wt.value.target_id),a}catch(a){const i=a instanceof Error?a.message:"Operator confirmation failed";throw ge.value=i,fa({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:i}),a}finally{at.value=!1}}A_(()=>{var t;_t(),Oe(),(t=Wt.value)!=null&&t.target_id&&$e(Wt.value.target_id)});const Qa=g(null),di=g(!1),ga=g(null),Hc=g(null),Ge=g(!1),Re=g(null),ui=g(null),Qs=g(!1),Zs=g(null);let on=null;function cl(){on!==null&&(window.clearTimeout(on),on=null)}function q_(t=1500){on===null&&(on=window.setTimeout(()=>{on=null,$a(!1)},t))}function w(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function k(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function q(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function rn(t){return typeof t=="boolean"?t:void 0}function Y(t,e=[]){if(Array.isArray(t))return t;if(!w(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function hn(t){if(!w(t))return null;const e=k(t.kind),n=k(t.summary),s=k(t.target_type);return!e||!n||!s?null:{kind:e,severity:k(t.severity)??"warn",summary:n,target_type:s,target_id:k(t.target_id)??null,actor:k(t.actor)??null,evidence:t.evidence}}function Fe(t){if(!w(t))return null;const e=k(t.action_type),n=k(t.target_type),s=k(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:k(t.target_id)??null,severity:k(t.severity)??"warn",reason:s,confirm_required:rn(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function F_(t){if(!w(t))return null;const e=k(t.session_id);return e?{session_id:e,goal:k(t.goal),status:k(t.status),health:k(t.health),scale_profile:k(t.scale_profile),control_profile:k(t.control_profile),planned_worker_count:q(t.planned_worker_count),active_agent_count:q(t.active_agent_count),last_turn_age_sec:q(t.last_turn_age_sec)??null,attention_count:q(t.attention_count),recommended_action_count:q(t.recommended_action_count),top_attention:hn(t.top_attention),top_recommendation:Fe(t.top_recommendation)}:null}function B_(t){if(!w(t))return null;const e=k(t.session_id);if(!e)return null;const n=w(t.status)?t.status:t,s=w(n.summary)?n.summary:void 0;return{session_id:e,status:k(t.status)??k(s==null?void 0:s.status)??(w(n.session)?k(n.session.status):void 0),progress_pct:q(t.progress_pct)??q(s==null?void 0:s.progress_pct),elapsed_sec:q(t.elapsed_sec)??q(s==null?void 0:s.elapsed_sec),remaining_sec:q(t.remaining_sec)??q(s==null?void 0:s.remaining_sec),done_delta_total:q(t.done_delta_total)??q(s==null?void 0:s.done_delta_total),summary:w(t.summary)?t.summary:s,team_health:w(t.team_health)?t.team_health:w(n.team_health)?n.team_health:void 0,communication_metrics:w(t.communication_metrics)?t.communication_metrics:w(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:w(t.orchestration_state)?t.orchestration_state:w(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:w(t.cascade_metrics)?t.cascade_metrics:w(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:w(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,i])=>{const l=k(i);return l?[a,l]:null}).filter(a=>a!==null)):w(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,i])=>{const l=k(i);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:w(t.session)?t.session:w(n.session)?n.session:void 0,recent_events:Y(t.recent_events,["events"]).filter(w)}}function K_(t){if(!w(t))return null;const e=k(t.name);return e?{name:e,agent_name:k(t.agent_name),status:k(t.status),autonomy_level:k(t.autonomy_level),context_ratio:q(t.context_ratio),generation:q(t.generation),active_goal_ids:Y(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:k(t.last_autonomous_action_at)??null,last_turn_ago_s:q(t.last_turn_ago_s),model:k(t.model)}:null}function U_(t){if(!w(t))return null;const e=k(t.confirm_token)??k(t.token);return e?{confirm_token:e,actor:k(t.actor),action_type:k(t.action_type),target_type:k(t.target_type),target_id:k(t.target_id)??null,delegated_tool:k(t.delegated_tool),created_at:k(t.created_at),preview:t.preview}:null}function W_(t){if(!w(t))return null;const e=k(t.action_type),n=k(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:k(t.description),confirm_required:rn(t.confirm_required)}}function H_(t){const e=w(t)?t:{};return{room_health:k(e.room_health),cluster:k(e.cluster),project:k(e.project),current_room:k(e.current_room)??k(e.room)??null,paused:rn(e.paused),tempo_interval_s:q(e.tempo_interval_s),active_agents:q(e.active_agents),keeper_pressure:q(e.keeper_pressure),active_operations:q(e.active_operations),pending_approvals:q(e.pending_approvals),incident_count:q(e.incident_count),recommended_action_count:q(e.recommended_action_count),top_attention:hn(e.top_attention),top_action:Fe(e.top_action)}}function G_(t){const e=w(t)?t:{},n=w(e.swarm_overview)?e.swarm_overview:{};return{health:k(e.health),active_operations:q(e.active_operations),pending_approvals:q(e.pending_approvals),swarm_overview:{active_lanes:q(n.active_lanes),moving_lanes:q(n.moving_lanes),stalled_lanes:q(n.stalled_lanes),projected_lanes:q(n.projected_lanes),last_movement_at:k(n.last_movement_at)??null},top_attention:hn(e.top_attention),top_action:Fe(e.top_action),session_cards:Y(e.session_cards).map(F_).filter(s=>s!==null)}}function J_(t){const e=w(t)?t:{};return{sessions:Y(e.sessions,["items"]).map(B_).filter(n=>n!==null),keepers:Y(e.keepers,["items"]).map(K_).filter(n=>n!==null),pending_confirms:Y(e.pending_confirms).map(U_).filter(n=>n!==null),available_actions:Y(e.available_actions).map(W_).filter(n=>n!==null)}}function Y_(t){if(!w(t))return null;const e=k(t.id),n=k(t.kind),s=k(t.summary),a=k(t.target_type);return!e||!n||!s||!a?null:{id:e,kind:n,severity:k(t.severity)??"warn",summary:s,target_type:a,target_id:k(t.target_id)??null,top_action:Fe(t.top_action),related_session_ids:Y(t.related_session_ids).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),related_agent_names:Y(t.related_agent_names).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),evidence_preview:Y(t.evidence_preview).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),last_seen_at:k(t.last_seen_at)??null}}function Gc(t){if(!w(t))return null;const e=k(t.session_id),n=k(t.goal);return!e||!n?null:{session_id:e,goal:n,room:k(t.room)??null,status:k(t.status),health:k(t.health),member_names:Y(t.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:k(t.started_at)??null,elapsed_sec:q(t.elapsed_sec)??null,operation_id:k(t.operation_id)??null,blocker_summary:k(t.blocker_summary)??null,last_event_at:k(t.last_event_at)??null,last_event_summary:k(t.last_event_summary)??null,communication_summary:k(t.communication_summary)??null,active_count:q(t.active_count),required_count:q(t.required_count),related_attention_count:q(t.related_attention_count)??0,top_attention:hn(t.top_attention),top_recommendation:Fe(t.top_recommendation)}}function Jc(t){if(!w(t))return null;const e=k(t.agent_name);return e?{agent_name:e,display_name:k(t.display_name)??null,is_live:typeof t.is_live=="boolean"?t.is_live:void 0,current_work:k(t.current_work)??null,recent_input_preview:k(t.recent_input_preview)??null,recent_output_preview:k(t.recent_output_preview)??null,recent_tool_names:Y(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_activity_at:k(t.last_activity_at)??null}:null}function Yc(t){if(!w(t))return null;const e=k(t.operation_id);return e?{operation_id:e,status:k(t.status),stage:k(t.stage)??null,detachment_status:k(t.detachment_status)??null,objective:k(t.objective)??null,updated_at:k(t.updated_at)??null}:null}function Vc(t){if(!w(t))return null;const e=k(t.name);return e?{name:e,agent_name:k(t.agent_name)??null,status:k(t.status),generation:q(t.generation),context_ratio:q(t.context_ratio)??null,last_turn_ago_s:q(t.last_turn_ago_s)??null,current_work:k(t.current_work)??null}:null}function Xc(t){const e=Gc(t);return e?{...e,member_previews:Y(w(t)?t.member_previews:void 0).map(Jc).filter(n=>n!==null),operation_badges:Y(w(t)?t.operation_badges:void 0).map(Yc).filter(n=>n!==null),keeper_refs:Y(w(t)?t.keeper_refs:void 0).map(Vc).filter(n=>n!==null)}:null}function V_(t){if(!w(t))return null;const e=k(t.agent_name);return e?{agent_name:e,display_name:k(t.display_name)??null,is_live:typeof t.is_live=="boolean"?t.is_live:void 0,archived_reason:k(t.archived_reason)??null,status:k(t.status),where:k(t.where)??null,with_whom:Y(t.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:k(t.current_work)??null,related_session_id:k(t.related_session_id)??null,related_attention_count:q(t.related_attention_count)??0,last_activity_at:k(t.last_activity_at)??null,recent_output_preview:k(t.recent_output_preview)??null,recent_input_preview:k(t.recent_input_preview)??null,recent_tool_names:Y(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean)}:null}function X_(t){if(!w(t))return null;const e=k(t.name);return e?{name:e,agent_name:k(t.agent_name)??null,status:k(t.status),generation:q(t.generation),context_ratio:q(t.context_ratio)??null,last_turn_ago_s:q(t.last_turn_ago_s)??null,current_work:k(t.current_work)??null,last_autonomous_action_at:k(t.last_autonomous_action_at)??null,allowed_tool_names:Y(t.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:Y(t.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:q(t.latest_tool_call_count)??null,tool_audit_source:k(t.tool_audit_source)??null,tool_audit_at:k(t.tool_audit_at)??null}:null}function Q_(t){if(!w(t))return null;const e=k(t.id),n=k(t.signal_type),s=k(t.summary),a=k(t.target_type);return!e||!n||!s||!a?null:{id:e,signal_type:n==="action"?"action":"attention",severity:k(t.severity)??"warn",summary:s,target_type:a,target_id:k(t.target_id)??null,attention:hn(t.attention),action:Fe(t.action)}}function Z_(t){const e=w(t)?t:{},n=Y(e.session_briefs).map(Gc).filter(a=>a!==null),s=Y(e.sessions).map(Xc).filter(a=>a!==null);return{generated_at:k(e.generated_at),summary:H_(e.summary),incidents:Y(e.incidents).map(hn).filter(a=>a!==null),recommended_actions:Y(e.recommended_actions).map(Fe).filter(a=>a!==null),command_focus:G_(e.command_focus),operator_targets:J_(e.operator_targets),attention_queue:Y(e.attention_queue).map(Y_).filter(a=>a!==null),sessions:s.length>0?s:n.map(a=>({...a,member_previews:[],operation_badges:[],keeper_refs:[]})),session_briefs:n,agent_briefs:Y(e.agent_briefs).map(V_).filter(a=>a!==null),keeper_briefs:Y(e.keeper_briefs).map(X_).filter(a=>a!==null),internal_signals:Y(e.internal_signals).map(Q_).filter(a=>a!==null)}}function tv(t){if(!w(t))return null;const e=k(t.id),n=k(t.summary);return!e||!n?null:{id:e,timestamp:k(t.timestamp)??null,event_type:k(t.event_type),actor:k(t.actor)??null,summary:n}}function ev(t){const e=w(t)?t:{};return{generated_at:k(e.generated_at),session_id:k(e.session_id)??"",session:Xc(e.session),timeline:Y(e.timeline).map(tv).filter(n=>n!==null),participants:Y(e.participants).map(Jc).filter(n=>n!==null),operations:Y(e.operations).map(Yc).filter(n=>n!==null),keepers:Y(e.keepers).map(Vc).filter(n=>n!==null),error:k(e.error)??null}}function nv(t){if(!w(t))return null;const e=k(t.id),n=k(t.label),s=k(t.summary);if(!e||!n||!s)return null;const a=k(t.status)??"unclear";return{id:e,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:k(t.signal_class)==="metadata_gap"||k(t.signal_class)==="mixed"||k(t.signal_class)==="operational_risk"?k(t.signal_class):void 0,evidence_quality:k(t.evidence_quality)==="strong"||k(t.evidence_quality)==="partial"||k(t.evidence_quality)==="missing"?k(t.evidence_quality):void 0,evidence:Y(t.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function sv(t){if(!w(t))return null;const e=k(t.kind),n=k(t.summary),s=k(t.scope_type),a=k(t.severity);return!e||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:e,summary:n,scope_type:s,scope_id:k(t.scope_id)??null,severity:a}}function av(t){const e=w(t)?t:{},n=w(e.basis)?e.basis:{},s=k(e.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:k(e.generated_at),cached:rn(e.cached),stale:rn(e.stale),refreshing:rn(e.refreshing),status:a,summary:k(e.summary)??null,model:k(e.model)??null,ttl_sec:q(e.ttl_sec),criteria:Y(e.criteria).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),basis:{current_room:k(n.current_room)??null,crew_count:q(n.crew_count),agent_count:q(n.agent_count),keeper_count:q(n.keeper_count)},metadata_gap_count:q(e.metadata_gap_count),metadata_gaps:Y(e.metadata_gaps).map(sv).filter(i=>i!==null),sections:Y(e.sections).map(nv).filter(i=>i!==null),error:k(e.error)??null,last_error:k(e.last_error)??null}}async function Qc(){di.value=!0,ga.value=null;try{const t=await pp();Qa.value=Z_(t)}catch(t){ga.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{di.value=!1}}async function ov(t){if(!t){ui.value=null,Zs.value=null,Qs.value=!1;return}Qs.value=!0,Zs.value=null;try{const e=await mp(t);ui.value=ev(e)}catch(e){Zs.value=e instanceof Error?e.message:"Failed to load session detail"}finally{Qs.value=!1}}async function $a(t=!1){Ge.value=!0,Re.value=null;try{const e=await _p(t),n=av(e);Hc.value=n,n.refreshing||n.status==="pending"?q_():cl()}catch(e){Re.value=e instanceof Error?e.message:"Failed to load mission briefing",cl()}finally{Ge.value=!1}}const Zc=g(null),pi=g(!1),Je=g(null);async function td(t,e){pi.value=!0,Je.value=null;try{Zc.value=await vp(t,e)}catch(n){Je.value=n instanceof Error?n.message:String(n)}finally{pi.value=!1}}const Gi=g(null),Jt=g(null),ha=g(!1),ya=g(!1),ba=g(null),ka=g(null),mi=g(null),xa=g(null),Z=g("warroom"),vs=g(null),_i=g(!1),Sa=g(null),Be=g(null),Ca=g(!1),Aa=g(null),Ji=g(null),vi=g(!1),Ta=g(null),fs=g(null),fi=g(!1),Ia=g(null),Yn=g(null),Ra=g(!1),Vn=g(null),ln=g(null);let Mn=null;function Yi(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"&&t!=="orchestra"}function ed(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function nd(){const e=ed().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function sd(){const e=ed().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function iv(t){if(m(t))return{policy_class:r(t.policy_class),approval_class:r(t.approval_class),tool_allowlist:B(t.tool_allowlist),model_allowlist:B(t.model_allowlist),requires_human_for:B(t.requires_human_for),autonomy_level:r(t.autonomy_level),escalation_timeout_sec:u(t.escalation_timeout_sec),kill_switch:z(t.kill_switch),frozen:z(t.frozen)}}function rv(t){if(m(t))return{headcount_cap:u(t.headcount_cap),active_operation_cap:u(t.active_operation_cap),max_cost_usd:u(t.max_cost_usd),max_tokens:u(t.max_tokens)}}function Vi(t){if(!m(t))return null;const e=r(t.unit_id),n=r(t.label),s=r(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:r(t.parent_unit_id)??null,leader_id:r(t.leader_id)??null,roster:B(t.roster),capability_profile:B(t.capability_profile),source:r(t.source),created_at:r(t.created_at),updated_at:r(t.updated_at),policy:iv(t.policy),budget:rv(t.budget)}}function ad(t){if(!m(t))return null;const e=Vi(t.unit);return e?{unit:e,leader_status:r(t.leader_status),roster_total:u(t.roster_total),roster_live:u(t.roster_live),active_operation_count:u(t.active_operation_count),health:r(t.health),reasons:B(t.reasons),children:Array.isArray(t.children)?t.children.map(ad).filter(n=>n!==null):[]}:null}function lv(t){if(m(t))return{total_units:u(t.total_units),company_count:u(t.company_count),platoon_count:u(t.platoon_count),squad_count:u(t.squad_count),leaf_agent_unit_count:u(t.leaf_agent_unit_count),live_agent_count:u(t.live_agent_count),managed_unit_count:u(t.managed_unit_count),active_operation_count:u(t.active_operation_count)}}function od(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),source:r(e.source),summary:lv(e.summary),units:Array.isArray(e.units)?e.units.map(ad).filter(n=>n!==null):[]}}function cv(t){if(!m(t))return null;const e=r(t.kind),n=r(t.status);return!e||!n?null:{kind:e,chain_id:r(t.chain_id)??null,goal:r(t.goal)??null,run_id:r(t.run_id)??null,status:n,viewer_path:r(t.viewer_path)??null,last_sync_at:r(t.last_sync_at)??null}}function Za(t){if(!m(t))return null;const e=r(t.operation_id),n=r(t.objective),s=r(t.assigned_unit_id),a=r(t.trace_id),i=r(t.status);return!e||!n||!s||!a||!i?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:r(t.autonomy_level),policy_class:r(t.policy_class),budget_class:r(t.budget_class),detachment_session_id:r(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(t.checkpoint_ref)??null,active_goal_ids:B(t.active_goal_ids),note:r(t.note)??null,created_by:r(t.created_by),source:r(t.source),status:i,chain:cv(t.chain),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function dv(t){if(!m(t))return null;const e=Za(t.operation);return e?{operation:e,assigned_unit_label:r(t.assigned_unit_label)}:null}function Cn(t){if(m(t))return{tone:r(t.tone),pending_ops:u(t.pending_ops),blocked_ops:u(t.blocked_ops),in_flight_ops:u(t.in_flight_ops),pipeline_stalls:u(t.pipeline_stalls),bus_traffic:u(t.bus_traffic),l1_hit_rate:u(t.l1_hit_rate),invalidation_count:u(t.invalidation_count),current_pending:u(t.current_pending),current_in_flight:u(t.current_in_flight),cdb_wakeups:u(t.cdb_wakeups),total_stolen:u(t.total_stolen),avg_best_score:u(t.avg_best_score),avg_candidate_count:u(t.avg_candidate_count),best_first_operations:u(t.best_first_operations),active_sessions:u(t.active_sessions),commit_rate:u(t.commit_rate),total_speculations:u(t.total_speculations)}}function uv(t){if(!m(t))return;const e=m(t.pipeline)?t.pipeline:void 0,n=m(t.cache)?t.cache:void 0,s=m(t.ooo)?t.ooo:void 0,a=m(t.speculative)?t.speculative:void 0,i=m(t.search_fabric)?t.search_fabric:void 0,l=m(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:u(e.total_ops),completed_ops:u(e.completed_ops),stalled_cycles:u(e.stalled_cycles),hazards_detected:u(e.hazards_detected),forwarding_used:u(e.forwarding_used),pipeline_flushes:u(e.pipeline_flushes),ipc:u(e.ipc)}:void 0,cache:n?{total_reads:u(n.total_reads),total_writes:u(n.total_writes),l1_hit_rate:u(n.l1_hit_rate),invalidation_count:u(n.invalidation_count),writeback_count:u(n.writeback_count),bus_traffic:u(n.bus_traffic)}:void 0,ooo:s?{agent_count:u(s.agent_count),total_added:u(s.total_added),total_issued:u(s.total_issued),total_completed:u(s.total_completed),total_stolen:u(s.total_stolen),cdb_wakeups:u(s.cdb_wakeups),stall_cycles:u(s.stall_cycles),global_cdb_events:u(s.global_cdb_events),current_pending:u(s.current_pending),current_in_flight:u(s.current_in_flight)}:void 0,speculative:a?{total_speculations:u(a.total_speculations),total_commits:u(a.total_commits),total_aborts:u(a.total_aborts),commit_rate:u(a.commit_rate),total_fast_calls:u(a.total_fast_calls),total_cost_usd:u(a.total_cost_usd),active_sessions:u(a.active_sessions)}:void 0,search_fabric:i?{total_operations:u(i.total_operations),best_first_operations:u(i.best_first_operations),legacy_operations:u(i.legacy_operations),blocked_operations:u(i.blocked_operations),ready_operations:u(i.ready_operations),research_pipeline_operations:u(i.research_pipeline_operations),avg_candidate_count:u(i.avg_candidate_count),avg_best_score:u(i.avg_best_score),top_stage:r(i.top_stage)??null}:void 0,signals:l?{issue_pressure:Cn(l.issue_pressure),cache_contention:Cn(l.cache_contention),scheduler_efficiency:Cn(l.scheduler_efficiency),routing_confidence:Cn(l.routing_confidence),speculative_posture:Cn(l.speculative_posture)}:void 0}}function id(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),active:u(n.active),paused:u(n.paused),managed:u(n.managed),projected:u(n.projected)}:void 0,microarch:uv(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(dv).filter(s=>s!==null):[]}}function rd(t){if(!m(t))return null;const e=r(t.detachment_id),n=r(t.operation_id),s=r(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:r(t.leader_id)??null,roster:B(t.roster),session_id:r(t.session_id)??null,checkpoint_ref:r(t.checkpoint_ref)??null,runtime_kind:r(t.runtime_kind)??null,runtime_ref:r(t.runtime_ref)??null,source:r(t.source),status:r(t.status),last_event_at:r(t.last_event_at)??null,last_progress_at:r(t.last_progress_at)??null,heartbeat_deadline:r(t.heartbeat_deadline)??null,created_at:r(t.created_at),updated_at:r(t.updated_at)}}function pv(t){if(!m(t))return null;const e=rd(t.detachment);return e?{detachment:e,assigned_unit_label:r(t.assigned_unit_label),operation:Za(t.operation)}:null}function ld(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),active:u(n.active),projected:u(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(pv).filter(s=>s!==null):[]}}function mv(t){if(!m(t))return null;const e=r(t.decision_id),n=r(t.trace_id),s=r(t.requested_action),a=r(t.scope_type),i=r(t.scope_id);return!e||!n||!s||!a||!i?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:i,operation_id:r(t.operation_id)??null,target_unit_id:r(t.target_unit_id)??null,requested_by:r(t.requested_by),status:r(t.status),reason:r(t.reason)??null,source:r(t.source),detail:t.detail,created_at:r(t.created_at),decided_at:r(t.decided_at)??null,expires_at:r(t.expires_at)??null}}function cd(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),pending:u(n.pending),approved:u(n.approved),denied:u(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(mv).filter(s=>s!==null):[]}}function _v(t){if(!m(t))return null;const e=Vi(t.unit);return e?{unit:e,roster_total:u(t.roster_total),roster_live:u(t.roster_live),headcount_cap:u(t.headcount_cap),active_operations:u(t.active_operations),active_operation_cap:u(t.active_operation_cap),utilization:u(t.utilization)}:null}function vv(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(_v).filter(n=>n!==null):[]}}function fv(t){if(!m(t))return null;const e=r(t.alert_id);return e?{alert_id:e,severity:r(t.severity),kind:r(t.kind),scope_type:r(t.scope_type),scope_id:r(t.scope_id),title:r(t.title),detail:r(t.detail),timestamp:r(t.timestamp)}:null}function dd(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:u(n.total),bad:u(n.bad),warn:u(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map(fv).filter(s=>s!==null):[]}}function ud(t){if(!m(t))return null;const e=r(t.event_id),n=r(t.trace_id),s=r(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:r(t.operation_id)??null,unit_id:r(t.unit_id)??null,actor:r(t.actor)??null,source:r(t.source),timestamp:r(t.timestamp),detail:t.detail}}function gv(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),events:Array.isArray(e.events)?e.events.map(ud).filter(n=>n!==null):[]}}function $v(t){if(!m(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function hv(t){if(!m(t))return null;const e=r(t.lane_id),n=r(t.label),s=r(t.kind),a=r(t.phase),i=r(t.motion_state),l=r(t.source_of_truth),c=r(t.movement_reason),d=r(t.current_step);if(!e||!n||!s||!a||!i||!l||!c||!d)return null;const p=m(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:z(t.present)??!1,phase:a,motion_state:i,source_of_truth:l,last_movement_at:r(t.last_movement_at)??null,movement_reason:c,current_step:d,blockers:B(t.blockers),counts:{operations:u(p.operations),detachments:u(p.detachments),workers:u(p.workers),approvals:u(p.approvals),alerts:u(p.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map($v).filter(v=>v!==null):[]}}function yv(t){if(!m(t))return null;const e=r(t.event_id),n=r(t.lane_id),s=r(t.kind),a=r(t.timestamp),i=r(t.title),l=r(t.detail),c=r(t.tone),d=r(t.source);return!e||!n||!s||!a||!i||!l||!c||!d?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:i,detail:l,tone:c,source:d}}function bv(t){if(!m(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,why_it_matters:r(t.why_it_matters)??void 0,next_tool:r(t.next_tool)??void 0,next_step:r(t.next_step)??void 0,lane_ids:B(t.lane_ids),count:u(t.count)??0}}function Xi(t){if(!m(t))return;const e=m(t.overview)?t.overview:{},n=m(t.gaps)?t.gaps:{},s=m(t.narrative)?t.narrative:{},a=m(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:r(t.generated_at),narrative:{state:r(s.state)??void 0,started:r(s.started)??void 0,active_work:r(s.active_work)??void 0,completion:r(s.completion)??void 0,lane_id:r(s.lane_id)??null},overview:{active_lanes:u(e.active_lanes),moving_lanes:u(e.moving_lanes),stalled_lanes:u(e.stalled_lanes),projected_lanes:u(e.projected_lanes),last_movement_at:r(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(hv).filter(i=>i!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(yv).filter(i=>i!==null):[],gaps:{count:u(n.count),items:Array.isArray(n.items)?n.items.map(bv).filter(i=>i!==null):[]},recommended_next_action:a?{tool:r(a.tool)??"masc_operator_snapshot",label:r(a.label)??"Observe operator state",reason:r(a.reason)??"",lane_id:r(a.lane_id)??null}:void 0}}function pd(t){if(!m(t))return;const e=m(t.workers)?t.workers:{},n=z(t.pass);return{status:r(t.status)??"missing",source:r(t.source)??"none",reason_code:r(t.reason_code)??null,status_summary:r(t.status_summary)??null,run_id:r(t.run_id)??null,captured_at:r(t.captured_at)??null,...n!==void 0?{pass:n}:{},...u(t.peak_hot_slots)!=null?{peak_hot_slots:u(t.peak_hot_slots)}:{},...u(t.ctx_per_slot)!=null?{ctx_per_slot:u(t.ctx_per_slot)}:{},workers:{expected:u(e.expected),joined:u(e.joined),current_task_bound:u(e.current_task_bound),fresh_heartbeats:u(e.fresh_heartbeats),done:u(e.done),final:u(e.final)},expected_artifact_dir:r(t.expected_artifact_dir)??null,artifact_ref:r(t.artifact_ref)??null,missing_reason:r(t.missing_reason)??null}}function kv(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),topology:od(e.topology),operations:id(e.operations),detachments:ld(e.detachments),alerts:dd(e.alerts),decisions:cd(e.decisions),capacity:vv(e.capacity),traces:gv(e.traces),swarm_status:Xi(e.swarm_status)}}function xv(t){const e=m(t)?t:{},n=od(e.topology),s=id(e.operations),a=ld(e.detachments),i=dd(e.alerts),l=cd(e.decisions);return{version:r(e.version),generated_at:r(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:i.version,generated_at:i.generated_at,summary:i.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:Xi(e.swarm_status),swarm_proof:pd(e.swarm_proof)}}function Sv(t){return m(t)?{chain_id:r(t.chain_id)??null,started_at:u(t.started_at)??null,progress:u(t.progress)??null,elapsed_sec:u(t.elapsed_sec)??null}:null}function md(t){if(!m(t))return null;const e=r(t.event);return e?{event:e,chain_id:r(t.chain_id)??null,timestamp:r(t.timestamp)??null,duration_ms:u(t.duration_ms)??null,message:r(t.message)??null,tokens:u(t.tokens)??null}:null}function Cv(t){if(!m(t))return null;const e=Za(t.operation);return e?{operation:e,runtime:Sv(t.runtime),history:md(t.history),mermaid:r(t.mermaid)??null,preview_run:_d(t.preview_run)}:null}function Av(t){const e=m(t)?t:{};return{status:r(e.status)??"disconnected",base_url:r(e.base_url)??null,message:r(e.message)??null}}function Tv(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),connection:Av(e.connection),summary:n?{linked_operations:u(n.linked_operations),active_chains:u(n.active_chains),running_operations:u(n.running_operations),recent_failures:u(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(Cv).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(md).filter(s=>s!==null):[]}}function Iv(t){if(!m(t))return null;const e=r(t.id);return e?{id:e,type:r(t.type),status:r(t.status),duration_ms:u(t.duration_ms)??null,error:r(t.error)??null}:null}function _d(t){if(!m(t))return null;const e=r(t.run_id),n=r(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:u(t.duration_ms),success:z(t.success),mermaid:r(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(Iv).filter(s=>s!==null):[]}:null}function Rv(t){const e=m(t)?t:{};return{run:_d(e.run)}}function Mv(t){if(!m(t))return null;const e=r(t.title),n=r(t.path);return!e||!n?null:{title:e,path:n}}function Ev(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function Lv(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.tool),a=r(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:B(t.success_signals),pitfalls:B(t.pitfalls)}}function Pv(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary),a=r(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(Lv).filter(i=>i!==null):[]}}function zv(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:B(t.tools)}}function jv(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.symptom),a=r(t.why),i=r(t.fix_tool),l=r(t.fix_summary);return!e||!n||!s||!a||!i||!l?null:{id:e,title:n,symptom:s,why:a,fix_tool:i,fix_summary:l}}function Nv(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.path_id),a=r(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:B(t.notes)}}function wv(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(Mv).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(Ev).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(Pv).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(zv).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(jv).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(Nv).filter(n=>n!==null):[]}}function Dv(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.status),a=r(t.detail),i=r(t.next_tool);return!e||!n||!s||!a||!i?null:{id:e,title:n,status:s,detail:a,next_tool:i}}function Ov(t){if(!m(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.title),a=r(t.detail),i=r(t.next_tool);return!e||!n||!s||!a||!i?null:{code:e,severity:n,title:s,detail:a,next_tool:i}}function qv(t){if(!m(t))return null;const e=r(t.from),n=r(t.content),s=r(t.timestamp),a=u(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function Fv(t){if(!m(t))return null;const e=r(t.name),n=r(t.role),s=r(t.lane),a=r(t.status),i=r(t.claim_marker),l=r(t.done_marker),c=r(t.final_marker);if(!e||!n||!s||!a||!i||!l||!c)return null;const d=(()=>{if(!m(t.last_message))return null;const p=u(t.last_message.seq),v=r(t.last_message.content),_=r(t.last_message.timestamp);return p==null||!v||!_?null:{seq:p,content:v,timestamp:_}})();return{name:e,role:n,lane:s,joined:z(t.joined)??!1,live_presence:z(t.live_presence)??!1,completed:z(t.completed)??!1,status:a,current_task:r(t.current_task)??null,bound_task_id:r(t.bound_task_id)??null,bound_task_title:r(t.bound_task_title)??null,bound_task_status:r(t.bound_task_status)??null,current_task_matches_run:z(t.current_task_matches_run)??!1,squad_member:z(t.squad_member)??!1,detachment_member:z(t.detachment_member)??!1,last_seen:r(t.last_seen)??null,heartbeat_age_sec:u(t.heartbeat_age_sec)??null,heartbeat_fresh:z(t.heartbeat_fresh)??!1,claim_marker_seen:z(t.claim_marker_seen)??!1,done_marker_seen:z(t.done_marker_seen)??!1,final_marker_seen:z(t.final_marker_seen)??!1,claim_marker:i,done_marker:l,final_marker:c,last_message:d}}function Bv(t){if(!m(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!m(n))return null;const s=r(n.timestamp),a=u(n.active_slots);if(!s||a==null)return null;const i=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:i}}).filter(n=>n!==null):[];return{slot_url:r(t.slot_url)??null,provider_base_url:r(t.provider_base_url)??null,provider_reachable:z(t.provider_reachable)??null,provider_status_code:u(t.provider_status_code)??null,provider_model_id:r(t.provider_model_id)??null,actual_model_id:r(t.actual_model_id)??null,expected_slots:u(t.expected_slots),actual_slots:u(t.actual_slots),expected_ctx:u(t.expected_ctx),actual_ctx:u(t.actual_ctx),configured_capacity:u(t.configured_capacity),slot_reachable:z(t.slot_reachable)??null,slot_status_code:u(t.slot_status_code)??null,runtime_blocker:r(t.runtime_blocker)??null,detail:r(t.detail)??null,checked_at:r(t.checked_at)??null,total_slots:u(t.total_slots),ctx_per_slot:u(t.ctx_per_slot),active_slots_now:u(t.active_slots_now),peak_active_slots:u(t.peak_active_slots),sample_count:u(t.sample_count),last_sample_at:r(t.last_sample_at)??null,timeline:e}}function Kv(t){if(!m(t))return null;const e=r(t.run_id),n=r(t.status),s=r(t.decided_by),a=r(t.decided_at),i=r(t.reason);if(!e||!n||!s||!a||!i)return null;const l=[];return Array.isArray(t.history)&&t.history.forEach(c=>{if(!m(c))return;const d=r(c.status),p=r(c.decided_by),v=r(c.decided_at),_=r(c.reason);!d||!p||!v||!_||l.push({status:d,decided_by:p,decided_at:v,reason:_,operation_id:r(c.operation_id)??null,detachment_id:r(c.detachment_id)??null,note:r(c.note)??null})}),{run_id:e,status:n,decided_by:s,decided_at:a,reason:i,operation_id:r(t.operation_id)??null,detachment_id:r(t.detachment_id)??null,note:r(t.note)??null,history:l}}function Uv(t){if(!m(t))return null;const e=r(t.run_id),n=r(t.recommended_kind),s=r(t.reason);return!e||!n||!s?null:{run_id:e,recommended_kind:n,continue_available:z(t.continue_available)??!1,rerun_available:z(t.rerun_available)??!1,abandon_available:z(t.abandon_available)??!1,reason:s,evidence:m(t.evidence)?{operation_id:r(t.evidence.operation_id)??null,detachment_id:r(t.evidence.detachment_id)??null,joined_workers:u(t.evidence.joined_workers),current_task_bound:u(t.evidence.current_task_bound),fresh_heartbeats:u(t.evidence.fresh_heartbeats),trace_events:u(t.evidence.trace_events),message_events:u(t.evidence.message_events),runtime_blocker:r(t.evidence.runtime_blocker)??null}:void 0,provenance:r(t.provenance),decision_engine:r(t.decision_engine),authoritative:z(t.authoritative)}}function Wv(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),run_id:r(e.run_id),room_id:r(e.room_id),operation_id:r(e.operation_id)??null,run_resolution:Kv(e.run_resolution),resolution_recommendation:Uv(e.resolution_recommendation),recommended_next_tool:r(e.recommended_next_tool),summary:n?{expected_workers:u(n.expected_workers),joined_workers:u(n.joined_workers),live_workers:u(n.live_workers),squad_roster_size:u(n.squad_roster_size),detachment_roster_size:u(n.detachment_roster_size),current_task_bound:u(n.current_task_bound),fresh_heartbeats:u(n.fresh_heartbeats),claim_markers_seen:u(n.claim_markers_seen),done_markers_seen:u(n.done_markers_seen),final_markers_seen:u(n.final_markers_seen),completed_workers:u(n.completed_workers),peak_hot_slots:u(n.peak_hot_slots),hot_window_ok:z(n.hot_window_ok),pass_hot_concurrency:z(n.pass_hot_concurrency),pass_end_to_end:z(n.pass_end_to_end),pending_decisions:u(n.pending_decisions),pass:z(n.pass)}:void 0,provider:Bv(e.provider),operation:Za(e.operation),squad:Vi(e.squad),detachment:rd(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(Fv).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(Dv).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(Ov).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(qv).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(ud).filter(s=>s!==null):[],truth_notes:B(e.truth_notes)}}function Hv(t){if(!m(t))return null;const e=r(t.label),n=r(t.value);return!e||!n?null:{label:e,value:n}}function Gv(t){if(!m(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.label),a=r(t.tone),i=r(t.provenance);return!e||!n||!s||!a||!i?null:{id:e,kind:n,label:s,subtitle:r(t.subtitle)??null,status:r(t.status)??null,tone:a,pulse:r(t.pulse)??null,provenance:i,visual_class:r(t.visual_class)??void 0,glyph:r(t.glyph)??void 0,parent_id:r(t.parent_id)??null,lane_id:r(t.lane_id)??null,link_tab:r(t.link_tab)??null,link_surface:r(t.link_surface)??null,link_params:m(t.link_params)?Object.fromEntries(Object.entries(t.link_params).map(([l,c])=>{const d=r(c);return d?[l,d]:null}).filter(l=>l!==null)):{},facts:Array.isArray(t.facts)?t.facts.map(Hv).filter(l=>l!==null):[]}}function Jv(t){if(!m(t))return null;const e=r(t.id),n=r(t.source),s=r(t.target),a=r(t.kind),i=r(t.tone),l=r(t.provenance);return!e||!n||!s||!a||!i||!l?null:{id:e,source:n,target:s,kind:a,label:r(t.label)??null,tone:i,provenance:l,animated:z(t.animated)}}function Yv(t){if(!m(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.label),a=r(t.tone),i=r(t.provenance);return!e||!n||!s||!a||!i?null:{id:e,kind:n,label:s,detail:r(t.detail)??null,tone:a,provenance:i,source_id:r(t.source_id)??null,target_id:r(t.target_id)??null,suggested_surface:r(t.suggested_surface)??null,suggested_params:m(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([l,c])=>{const d=r(c);return d?[l,d]:null}).filter(l=>l!==null)):{}}}function Vv(t){if(!m(t))return null;const e=r(t.target_kind),n=r(t.target_id),s=r(t.label),a=r(t.reason);return!e||!n||!s||!a?null:{target_kind:e,target_id:n,label:s,reason:a,suggested_surface:r(t.suggested_surface)??null,suggested_params:m(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([i,l])=>{const c=r(l);return c?[i,c]:null}).filter(i=>i!==null)):{}}}function Xv(t){const e=m(t)?t:{},n=m(e.room)?e.room:{},s=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),room:{room_id:r(n.room_id),project:r(n.project),cluster:r(n.cluster),paused:z(n.paused),pause_reason:r(n.pause_reason)??null,agent_count:u(n.agent_count),task_count:u(n.task_count),message_count:u(n.message_count)},summary:s?{session_count:u(s.session_count),operation_count:u(s.operation_count),detachment_count:u(s.detachment_count),lane_count:u(s.lane_count),worker_count:u(s.worker_count),keeper_count:u(s.keeper_count),signal_count:u(s.signal_count),alert_count:u(s.alert_count)}:void 0,nodes:Array.isArray(e.nodes)?e.nodes.map(Gv).filter(a=>a!==null):[],edges:Array.isArray(e.edges)?e.edges.map(Jv).filter(a=>a!==null):[],signals:Array.isArray(e.signals)?e.signals.map(Yv).filter(a=>a!==null):[],focus:Vv(e.focus),swarm_status:Xi(e.swarm_status),swarm_proof:pd(e.swarm_proof),truth_notes:B(e.truth_notes)}}function Ft(t){Z.value=t,Yi(t)&&Qv()}async function vd(){ha.value=!0,ba.value=null;try{const t=await bp();Gi.value=xv(t)}catch(t){ba.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{ha.value=!1}}function Qi(t){ln.value=t}async function Zi(){ya.value=!0,ka.value=null;try{const t=await yp();Jt.value=kv(t)}catch(t){ka.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{ya.value=!1}}async function Qv(){Jt.value||ya.value||await Zi()}async function Ye(){await vd(),Yi(Z.value)&&await Zi()}async function we(){var t;fi.value=!0,Ia.value=null;try{const e=await kp(),n=Tv(e);fs.value=n;const s=ln.value;n.operations.length===0?ln.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(ln.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Ia.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{fi.value=!1}}function Zv(){Mn=null,Yn.value=null,Ra.value=!1,Vn.value=null}async function tf(t){Mn=t,Ra.value=!0,Vn.value=null;try{const e=await xp(t);if(Mn!==t)return;Yn.value=Rv(e)}catch(e){if(Mn!==t)return;Yn.value=null,Vn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{Mn===t&&(Ra.value=!1)}}async function ef(){_i.value=!0,Sa.value=null;try{const t=await Sp();vs.value=wv(t)}catch(t){Sa.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{_i.value=!1}}async function Zt(t=nd(),e=sd()){Ca.value=!0,Aa.value=null;try{const n=await Cp(t,e);Be.value=Wv(n)}catch(n){Aa.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{Ca.value=!1}}async function ze(t=nd(),e=sd()){vi.value=!0,Ta.value=null;try{const n=await Ap(t,e);Ji.value=Xv(n)}catch(n){Ta.value=n instanceof Error?n.message:"Failed to load orchestra map"}finally{vi.value=!1}}async function ye(t,e,n){mi.value=t,xa.value=null;try{await Tp(e,n),await vd(),(Jt.value||Yi(Z.value))&&await Zi(),await Zt(),await ze(),await we()}catch(s){throw xa.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{mi.value=null}}function nf(t){return ye(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function sf(t){return ye(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function af(t){return ye(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function of(t={}){return ye("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function rf(t){return ye(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function lf(t){return ye(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function cf(t,e){return ye(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function df(t,e){return ye(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}C_(()=>{Ye(),we(),(Z.value==="swarm"||Z.value==="warroom"||Z.value==="orchestra"||Be.value!==null)&&Zt(),(Z.value==="orchestra"||Ji.value!==null)&&ze(),Z.value==="warroom"&&_t()});function gi(t){t==="command"&&(Le(),Ye(),we(),(Z.value==="swarm"||Z.value==="warroom"||Z.value==="orchestra")&&Zt(),Z.value==="orchestra"&&ze(),Z.value==="warroom"&&_t()),t==="mission"&&(Le(),Qc(),$a()),t==="proof"&&td(D.value.params.session_id,D.value.params.operation_id),t==="execution"&&(Le(),Ee()),t==="intervene"&&(Le(),_t(),Oe()),t==="memory"&&pe(),t==="planning"&&Ui(),t==="lab"&&me()}function uf({metric:t}){return o`
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
  `}function pf({panel:t}){return o`
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
            ${t.metrics.map(e=>o`<${uf} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function O({panelId:t,compact:e=!1,label:n="왜 필요한가"}){const s=p_(t);return s?o`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${pf} panel=${s} />
    </details>
  `:pa.value?o`<span class="semantic-inline-state">의미 계층 불러오는 중…</span>`:null}function xt({surfaceId:t,compact:e=!1}){const n=u_(t);return n?o`
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
  `:pa.value?o`<div class="semantic-surface-card ${e?"compact":""}">의미 계층 불러오는 중…</div>`:ma.value?o`<div class="semantic-surface-card ${e?"compact":""}">${ma.value}</div>`:null}function M({title:t,class:e,semanticId:n,testId:s,children:a}){return o`
    <div class="card ${e??""}" data-testid=${s}>
      ${t?o`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?o`<${O} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}function $o(t){const e=(t??"").trim().toLowerCase();return e==="bad"||e==="critical"||e==="offline"?"bad":e==="warn"||e==="paused"||e==="blocked"?"warn":"ok"}function mf(){var n;const t=(n=Wi.value)==null?void 0:n.focus;if(!(t!=null&&t.suggested_tab))return;const e=t.suggested_params??{};if(t.suggested_tab==="intervene"){ot("intervene",e);return}ot("command",{...t.suggested_surface?{surface:t.suggested_surface}:{},...e})}function to(){var d,p,v,_,f,h;const t=Wi.value;if(!t)return ci.value?o`<section class="room-truth-strip room-truth-strip-loading">room truth 불러오는 중...</section>`:_a.value?o`<section class="room-truth-strip room-truth-strip-error">${_a.value}</section>`:null;const e=t.room.status,n=t.room.counts,s=(d=t.execution)==null?void 0:d.summary,a=(p=t.execution)==null?void 0:p.top_queue,i=t.command,l=t.operator,c=t.focus;return o`
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
          <span class="command-chip ${$o(((s==null?void 0:s.blocked_sessions)??0)>0?"warn":"ok")}">priority ${(s==null?void 0:s.priority_items)??0}</span>
          <span class="command-chip">${((v=t.execution)==null?void 0:v.provenance)??"derived"}</span>
        </div>
      </article>

      <article class="room-truth-card">
        <span class="room-truth-label">control</span>
        <strong>작전 ${(i==null?void 0:i.active_operations)??0} · 승인 ${(i==null?void 0:i.pending_approvals)??0}</strong>
        <p>alerts bad ${(i==null?void 0:i.bad_alerts)??0} / warn ${(i==null?void 0:i.warn_alerts)??0} · lanes ${(i==null?void 0:i.moving_lanes)??0}/${(i==null?void 0:i.active_lanes)??0}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${$o(((i==null?void 0:i.bad_alerts)??0)>0?"bad":((i==null?void 0:i.warn_alerts)??0)>0||((i==null?void 0:i.pending_approvals)??0)>0?"warn":"ok")}">
            health ${(l==null?void 0:l.health)??"ok"}
          </span>
          <span class="command-chip">${(i==null?void 0:i.provenance)??"truth"}</span>
        </div>
      </article>

      <article class="room-truth-card room-truth-card-focus">
        <span class="room-truth-label">next focus</span>
        <strong>${(c==null?void 0:c.label)??"지금은 방 전체가 비교적 안정적입니다"}</strong>
        <p>${(c==null?void 0:c.reason)??((f=(_=l==null?void 0:l.attention_summary)==null?void 0:_.top_item)==null?void 0:f.summary)??(a==null?void 0:a.summary)??"다음 drill-down 대상이 아직 없습니다."}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${$o((c==null?void 0:c.provenance)==="fallback"?"warn":"ok")}">${(c==null?void 0:c.source)??"steady"}</span>
          <span class="command-chip">${(c==null?void 0:c.provenance)??((h=l==null?void 0:l.recommendation_summary)==null?void 0:h.provenance)??"derived"}</span>
        </div>
        ${c!=null&&c.suggested_tab?o`
              <div class="room-truth-actions">
                <button class="control-btn ghost" onClick=${mf}>
                  ${c.suggested_tab==="intervene"?"개입면 열기":"지휘면 열기"}
                </button>
              </div>
            `:null}
      </article>
    </section>
  `}const Ma="masc_dashboard_workflow_context",_f=900*1e3;function yt(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function oe(t){const e=yt(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function fd(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function $i(t){return m(t)?t:null}function vf(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function ff(t){if(!t)return null;try{const e=JSON.parse(t);if(!m(e))return null;const n=yt(e.id),s=yt(e.source_surface),a=yt(e.source_label),i=yt(e.summary),l=yt(e.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!i||!l?null:{id:n,source_surface:s,source_label:a,action_type:yt(e.action_type),target_type:yt(e.target_type),target_id:yt(e.target_id),focus_kind:yt(e.focus_kind),operation_id:yt(e.operation_id),command_surface:yt(e.command_surface),summary:i,payload_preview:yt(e.payload_preview),suggested_payload:$i(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:l}}catch{return null}}function tr(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=_f}function gf(){const t=fd(),e=ff((t==null?void 0:t.getItem(Ma))??null);return e?tr(e)?e:(t==null||t.removeItem(Ma),null):null}const gd=g(gf());function $d(t){const e=t&&tr(t)?t:null;gd.value=e;const n=fd();if(!n)return;if(!e){n.removeItem(Ma);return}const s=vf(e);s&&n.setItem(Ma,s)}function $f(t){if(!t)return null;const e=$i(t.suggested_payload);if(e)return e;if(m(t.preview)){const n=$i(t.preview.payload);if(n)return n}return null}function hf(t){if(!t)return null;const e=oe(t.message);if(e)return e;const n=oe(t.task_title)??oe(t.title),s=oe(t.task_description)??oe(t.description),a=oe(t.reason),i=oe(t.priority)??oe(t.task_priority);return n&&s?`${n} · ${s}`:n&&i?`${n} · P${i}`:n||s||a||null}function er(t,e,n,s,a,i,l,c){return[t,e,n??"action",s??"target",a??"room",i??"focus",l??"operation",c].join(":")}function yn(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=$f(t),i=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,l=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,c=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,d=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:er("mission",n,(t==null?void 0:t.action_type)??null,i,l,c,null,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:i,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:d,payload_preview:hf(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function yf({targetType:t,targetId:e,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:i=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:er("execution",s,null,t,e,n,i,c),source_surface:"execution",source_label:s,action_type:null,target_type:t,target_id:e,focus_kind:n,operation_id:i,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function bf(t,e){return(e.source==="mission"||e.source==="execution")&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)&&(e.operation_id??null)===(t.operation_id??null)}function gs(t){const{params:e}=t;if(e.source!=="mission"&&e.source!=="execution")return null;const n=gd.value;if(n&&tr(n)&&bf(n,e))return n;const s=new Date().toISOString(),a=e.source==="execution"?"execution":"mission";return{id:er(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,e.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,operation_id:e.operation_id??null,command_surface:e.surface??null,summary:a==="execution"?e.focus_kind?`${e.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function hd(t){return{source:t.source_surface,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function yd(t){if(t.command_surface)return t.command_surface;const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.focus_kind==="operation"||t.target_type==="operation"?"operations":t.target_type==="room"?"orchestra":"swarm"}function bd(t){return{source:t.source_surface,surface:yd(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function kf(t){return hd(t)}function xf(t){return bd(t)}function nr(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function eo(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(t==null?void 0:t.trim())||"추천 액션"}}function Sf(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"orchestra":return"오케스트라";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}const te=g(null),le=g(null);function zt(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function Mt(t){return t==="bad"||t==="offline"||t==="critical"||t==="risk"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"||t==="watch"?"warn":"ok"}function ne(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function Cf(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"확인 필요":t<60?`${Math.round(t)}초`:t<3600?`${Math.round(t/60)}분`:t<86400?`${Math.round(t/3600)}시간`:`${Math.round(t/86400)}일`}function Ut(t){switch((t??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"pending":return"대기 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":case"watch":return"주의";case"bad":case"critical":case"risk":return"위험";case"degraded":return"저하";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"loading":return"불러오는 중";case"error":return"오류";case"unavailable":return"사용 불가";case"stale":return"오래됨";case"refreshing":return"갱신 중";case"cached":return"캐시";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Ea(t){switch((t??"").trim().toLowerCase()){case"room":return"방";case"team_session":case"session":return"세션";case"operation":return"작전";case"keeper":return"키퍼";case"agent":return"에이전트";default:return(t==null?void 0:t.trim())||"대상"}}function dl(t){switch((t??"").trim().toLowerCase()){case"metadata_gap":return"메타데이터 부족";case"mixed":return"신호 혼재";case"":return null;default:return(t==null?void 0:t.trim())||null}}function Af(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function Tf(t){return nr(t?yn(t,null,"상황판 추천 액션"):null)}function no(t,e=yn()){$d(e),ot(t,t==="intervene"?kf(e):xf(e))}function kd(t){no("intervene",yn(null,t,"상황판 incident"))}function xd(t){no("command",yn(null,t,"상황판 incident"))}function sr(t,e,n="상황판 추천 액션"){no("intervene",yn(t,e,n))}function Sd(t,e,n="상황판 추천 액션"){no("command",yn(t,e,n))}function hi(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),ot(t,n)}function If(t){return{kind:t.kind,severity:t.severity,summary:t.summary,target_type:t.target_type,target_id:t.target_id??null,actor:null,evidence:t.evidence_preview}}function Rf(t){var n,s;const e=ae.value.find(a=>a.name===t.name||a.agent_name===t.agent_name)??null;return{brief:t,keeper:e,currentWork:zt(t.current_work,110)??zt(e==null?void 0:e.skill_primary,110)??zt(e==null?void 0:e.last_proactive_reason,110)??"명시된 키퍼 초점 없음",recentInput:zt(e==null?void 0:e.recent_input_preview,120)??null,recentOutput:zt(e==null?void 0:e.recent_output_preview,120)??zt((n=e==null?void 0:e.diagnostic)==null?void 0:n.last_reply_preview,120)??zt(e==null?void 0:e.last_proactive_preview,120)??null,recentEvent:zt(e==null?void 0:e.last_proactive_reason,120)??zt((s=e==null?void 0:e.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(e==null?void 0:e.recent_tool_names)??[]}}function Mf(){const t=Qa.value;if(!t)return new Map;const e=t.sessions.length>0?t.sessions:t.session_briefs;return new Map(e.map(n=>[n.session_id,n]))}function Ef(t){te.value=te.value===t?null:t,le.value=null}function Cd(t){le.value=le.value===t?null:t,te.value=null}function Lf(){te.value=null,le.value=null}function Pf({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,l=i*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),o`
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
  `}function zf(t){switch(t.trim().toLowerCase()){case"active":case"running":return"가동 중";case"working":return"작업 중";case"watching":return"관찰 중";case"quiet":return"조용함";case"idle":return"유휴";case"ok":case"healthy":return"정상";case"warn":case"warning":case"degraded":return"주의";case"bad":case"critical":case"error":case"failed":return"위험";case"blocked":return"막힘";case"paused":return"일시정지";case"pending":return"대기";case"offline":case"inactive":return"오프라인";case"connected":return"연결됨";case"disconnected":return"끊김";case"ready":return"준비됨";case"done":case"completed":return"완료";case"unknown":return"알 수 없음";default:return t}}function be({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??zf(t)}
    </span>
  `}function Ad(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}초 전`;const a=Math.floor(s/60);if(a<60)return`${a}분 전`;const i=Math.floor(a/60);return i<24?`${i}시간 전`:`${Math.floor(i/24)}일 전`}function et({timestamp:t}){const e=Ad(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function jf(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function ul(t,e="없음"){return!t||t.length===0?e:t.slice(0,4).join(", ")}function Td({model:t,onClick:e,variant:n,testId:s}){var c,d,p,v;const a=!!t.recentEvent||!!t.recentInput||!!t.recentOutput||!!t.routeSummary||!!t.auditSource||!!t.auditAt||(((c=t.recentTools)==null?void 0:c.length)??0)>0||(((d=t.allowedTools)==null?void 0:d.length)??0)>0,i=n==="mission"?`mission-activity-card ${t.tone}`:"keeper-canonical-card",l=n==="mission"?"mission-card-select":`monitor-row ${t.tone}${t.stateClass?` state-${t.stateClass}`:""}`;return o`
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
                <${Pf} ratio=${t.contextRatio??0} size=${34} stroke=${4} />
                <${be} status=${t.statusRaw??"unknown"} />
                ${t.stateLabel?o`<span class="monitor-pill ${t.tone}">${t.stateLabel}</span>`:null}
              `:o`<span class="command-chip ${t.tone}">${t.statusLabel}</span>`}
        </div>

        <div class=${n==="mission"?"mission-activity-meta":"monitor-meta"}>
          ${t.lastActivityAt?o`<span>최근 활동 <${et} timestamp=${t.lastActivityAt} /></span>`:o`<span>${t.lastActivityFallback??"최근 활동 없음"}</span>`}
          ${t.relatedSessionId?o`<span>세션 · ${t.relatedSessionId}</span>`:null}
          ${t.continuity?o`<span>${t.continuity}</span>`:null}
          ${t.lifecycle?o`<span>생애주기 ${t.lifecycle}</span>`:null}
          <span>컨텍스트 ${jf(t.contextRatio)}</span>
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
                ${t.auditAt?o`<span><${et} timestamp=${t.auditAt} /></span>`:null}
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
              ${(((p=t.recentTools)==null?void 0:p.length)??0)>0||(((v=t.allowedTools)==null?void 0:v.length)??0)>0?o`
                    <div class="mission-activity-foot">
                      <span>최근 도구 · ${ul(t.recentTools)}</span>
                      <span>허용 도구 · ${ul(t.allowedTools)}</span>
                    </div>
                  `:null}
            </details>
          `:null}
    </article>
  `}function Id(t,e){const n=t==null?void 0:t.trim(),s=e==null?void 0:e.trim();return s?n&&s===n?null:s:null}function Rd(t,e){const n=Id(t,e);return n?`runtime · ${n}`:null}function Md(t,e){const n=t==null?void 0:t.trim(),s=Id(n,e);return n?s?`keeper key · ${n} · runtime agent · ${s}`:`keeper key · ${n}`:null}function ho(t){return(t==null?void 0:t.trim().toLowerCase())??""}function Nf(t){var e,n;return t?((e=t.agent)==null?void 0:e.exists)===!1||ho((n=t.diagnostic)==null?void 0:n.health_state)==="offline"||ho(t.status)==="offline"||ho(t.status)==="inactive"?"offline":"online":"unlinked"}function wf(t){switch(t){case"offline":return"offline";case"none_recent":return"none_recent";case"not_applicable":return"not_applicable";case"unlinked":return"unlinked";default:return"not_collected"}}function Df(t){const e=Nf(t);return e==="unlinked"?"unlinked":e==="offline"?"offline":"none_recent"}let Of=0;const je=g([]);function N(t,e="success",n=4e3){const s=++Of;je.value=[...je.value,{id:s,message:t,type:e}],setTimeout(()=>{je.value=je.value.filter(a=>a.id!==s)},n)}function qf(t){je.value=je.value.filter(e=>e.id!==t)}function Ff(){const t=je.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>qf(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Bf="masc_dashboard_agent_name",bn=g(null),La=g(!1),Xn=g(""),Pa=g([]),Qn=g([]),cn=g(""),wn=g(!1);function $s(t){bn.value=t,ar()}function pl(){bn.value=null,Xn.value="",Pa.value=[],Qn.value=[],cn.value=""}function Kf(){const t=bn.value;return t?Gt.value.find(e=>e.name===t)??null:null}function Ed(t){return t?de.value.filter(e=>e.assignee===t):[]}function Uf(t){return t?ae.value.find(e=>e.agent_name===t||e.name===t)??null:null}function Wf(t){if(!t)return null;const e=Qa.value;return e?e.agent_briefs.find(n=>n.agent_name===t)??null:null}function Hf(t){return t?qi.value.find(e=>e.agent_name===t||e.name===t)??null:null}async function ar(){const t=bn.value;if(t){La.value=!0,Xn.value="",Pa.value=[],Qn.value=[];try{const e=await rm(80);Pa.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Ed(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await lm(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const l=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));Qn.value=s}catch(e){Xn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{La.value=!1}}}async function ml(){var s;const t=bn.value,e=cn.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Bf))==null?void 0:s.trim())||"dashboard";wn.value=!0;try{await im(n,`@${t} ${e}`),cn.value="",N(`Mention sent to ${t}`,"success"),ar()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";N(i,"error")}finally{wn.value=!1}}function Gf({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${be} status=${t.status} />
    </div>
  `}function Jf({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function _l(t,e=160){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function Yf(){const t=bn.value;if(!t)return null;const e=Kf(),n=Uf(t),s=Hf(t),a=Wf(t),i=Ed(t),l=Pa.value,c=(a==null?void 0:a.display_name)??(n==null?void 0:n.name)??t,d=c!==t?t:null,p=(e==null?void 0:e.status)??(a==null?void 0:a.status)??"unknown",v=!e&&(a==null?void 0:a.is_live)===!1,_=(e==null?void 0:e.last_seen)??(a==null?void 0:a.last_activity_at)??null,f=(e==null?void 0:e.emoji)??(n==null?void 0:n.emoji),h=(e==null?void 0:e.koreanName)??(n==null?void 0:n.koreanName),C=_l(s==null?void 0:s.continuity_summary)??_l(s==null?void 0:s.skill_route_summary)??null,b=Md(n==null?void 0:n.name,n==null?void 0:n.agent_name);return o`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${x=>{x.target.classList.contains("agent-detail-overlay")&&pl()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${f?o`<span style="font-size:2rem">${f}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${c}
                  ${h?o`<span style="font-size:0.75em;color:#888">(${h})</span>`:""}
                  ${d?o`<span class="mono" style="font-size:0.75em;color:#888">${d}</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  <${be} status=${p} />
                  ${v?o`<span class="pill">archived session participant</span>`:null}
                  ${e!=null&&e.model?o`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                  ${!e&&(a!=null&&a.archived_reason)?o`<span style="font-size:0.75rem;color:#888">${a.archived_reason}</span>`:null}
                </div>
              </div>
            </div>
            <div class="agent-detail-sub">
              ${e!=null&&e.current_task||a!=null&&a.current_work?o`<span>Task: ${(e==null?void 0:e.current_task)??(a==null?void 0:a.current_work)}</span>`:null}
              ${_?o`<span>Last seen: <${et} timestamp=${_} /></span>`:null}
            </div>
            ${n||C||a!=null&&a.related_session_id?o`
                  <div class="agent-detail-sub">
                    ${n?o`<span>Linked keeper: ${n.name}${b?` · ${b}`:""}</span>`:null}
                    ${a!=null&&a.related_session_id?o`<span>Session: ${a.related_session_id}</span>`:null}
                    ${C?o`<span>${C}</span>`:null}
                  </div>
                `:null}
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{ar()}} disabled=${La.value}>
              ${La.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${pl}>Close</button>
          </div>
        </div>

        ${Xn.value?o`<div class="council-error">${Xn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${M} title="Assigned Tasks">
            ${i.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${i.map(x=>o`<${Gf} key=${x.id} task=${x} />`)}</div>`}
          <//>

          <${M} title="Recent Activity">
            ${l.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${l.map((x,y)=>o`<div key=${y} class="agent-activity-line">${x}</div>`)}</div>`}
          <//>
        </div>
        <${M} title="Task History">
          ${Qn.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Qn.value.map(x=>o`<${Jf} key=${x.taskId} row=${x} />`)}</div>`}
        <//>

        <${M} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${cn.value}
              onInput=${x=>{cn.value=x.target.value}}
              onKeyDown=${x=>{x.key==="Enter"&&ml()}}
              disabled=${wn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{ml()}}
              disabled=${wn.value||cn.value.trim()===""}
            >
              ${wn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Vf(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Xf(t){switch(t.delivery){case"sending":return"sending";case"streaming":return t.streamState==="finalizing"?"finalizing":"streaming";case"timeout":return"timeout";case"error":return"error";case"history":return t.role;default:return"delivered"}}function yo(t){return t.delivery==="error"||t.delivery==="timeout"?"error":t.role==="user"?"user":t.role==="assistant"?"assistant":"system"}function Ld(t){return t.role==="user"?"You":t.label.trim()?t.label.trim():t.role}function Qf(t){return Ld(t).slice(0,2).toUpperCase()}function Zf(t){var n;const e=(n=t==null?void 0:t.usage)==null?void 0:n.totalTokens;return typeof e=="number"&&Number.isFinite(e)?`${e} tok`:null}function tg(t){return t?[t.modelUsed??null,typeof t.latencyMs=="number"?`${t.latencyMs} ms`:null,Zf(t)].filter(e=>!!e):[]}function vl(t){return typeof t!="number"||!Number.isFinite(t)?null:t===0?"$0.00":t<.01?`$${t.toFixed(4)}`:`$${t.toFixed(2)}`}function eg(t){if(!t)return[];const e=["Goal","Progress","Next","Decisions","OpenQuestions","Constraints"];return t.split(`
`).map(n=>n.trim()).filter(Boolean).map(n=>{const s=e.find(a=>n.startsWith(`${a}:`));return s?{label:s,value:n.slice(s.length+1).trim()}:null}).filter(n=>!!(n&&n.value))}function ng(t){var e;return[t.modelUsed?{label:"Model",value:t.modelUsed}:null,typeof t.latencyMs=="number"?{label:"Latency",value:`${t.latencyMs} ms`}:null,typeof((e=t.usage)==null?void 0:e.totalTokens)=="number"?{label:"Tokens",value:`${t.usage.totalTokens}`}:null,vl(t.costUsd)?{label:"Cost",value:vl(t.costUsd)}:null,t.traceId?{label:"Trace",value:t.traceId}:null,typeof t.generation=="number"?{label:"Generation",value:`${t.generation}`}:null].filter(n=>!!n)}function sg({entry:t}){var p;const[e,n]=mn(!1),[s,a]=mn(!1),i=tg(t.details),l=!!t.details,c=t.details?ng(t.details):[],d=eg((p=t.details)==null?void 0:p.stateBlock);return o`
    <article class=${`chat-bubble ${yo(t)}`}>
      <div class="chat-bubble-head">
        <div class="chat-bubble-identity">
          <div class=${`chat-avatar ${yo(t)}`}>${Qf(t)}</div>
          <div class="chat-bubble-identity-copy">
            <div class="chat-bubble-labels">
              <span class=${`chat-role-chip ${yo(t)}`}>${t.label}</span>
              <span class="chat-delivery-chip">${Xf(t)}</span>
              ${t.timestamp?o`<span class="chat-time-chip">${Vf(t.timestamp)}</span>`:null}
            </div>
            <div class="chat-identity-title">${Ld(t)}</div>
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
            ${i.map(v=>o`<span class="chat-detail-chip">${v}</span>`)}
          </div>`:null}

      <div class="chat-bubble-body">${t.text||(t.delivery==="streaming"?"…":"(empty reply)")}</div>
      ${t.error?o`<div class="chat-bubble-error">${t.error}</div>`:null}

      ${e&&t.details?o`
            <div class="chat-detail-panel">
              ${c.length>0?o`
                    <div class="chat-overview-grid">
                      ${c.map(v=>o`
                        <div class="chat-overview-card">
                          <div class="chat-overview-label">${v.label}</div>
                          <div class="chat-overview-value">${v.value}</div>
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
                        ${d.map(v=>o`
                          <div class="chat-state-card">
                            <div class="chat-state-label">${v.label}</div>
                            <div class="chat-state-value">${v.value}</div>
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
  `}function ag({entries:t,emptyText:e}){const n=Ln(null),s=t.map(a=>`${a.id}:${a.text.length}:${a.delivery}`).join("|");return nt(()=>{const a=n.current;a&&(a.scrollTop=a.scrollHeight)},[s]),o`
    <div class="chat-transcript" ref=${n}>
      ${t.length===0?o`<div class="chat-empty-copy">${e}</div>`:t.map(a=>o`<${sg} key=${a.id} entry=${a} />`)}
    </div>
  `}function og({draft:t,placeholder:e,disabled:n,streaming:s,onDraftChange:a,onSend:i,onAbort:l}){return o`
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
  `}function ig(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function rg(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function lg(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function cg(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Pd(t){if(!t)return null;const e=se.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function dg({keeper:t,showRawStatus:e=!1}){if(nt(()=>{t!=null&&t.name&&yc(t.name)},[t==null?void 0:t.name]),!t)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=se.value[t.name],s=Pd(t),a=ei.value[t.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${ig(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${rg((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?o` · ${lg(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?o` · next eligible ${cg(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?o`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function zd({keeperName:t,placeholder:e}){const[n,s]=mn("");nt(()=>{t&&yc(t)},[t]);const a=$t.value[t]??[],i=ca.value[t]??!1,l=Kt.value[t],c=async()=>{const d=n.trim();if(!(!t||!d)){s("");try{await Em(t,d)}catch(p){if(p instanceof Error&&p.name==="AbortError")return;const v=p instanceof Error?p.message:`Failed to message ${t}`;N(v,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <${ag}
        entries=${a}
        emptyText="No direct keeper conversation yet."
      />
      <${og}
        draft=${n}
        placeholder=${e}
        disabled=${!t}
        streaming=${i}
        onDraftChange=${s}
        onSend=${()=>{c()}}
        onAbort=${()=>{hc(t)}}
      />
      ${l?o`<div class="control-status-copy control-error-copy">${l}</div>`:null}
    </div>
  `}function ug({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=Pd(e),a=ni.value[e.name]??!1,i=si.value[e.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{Lm(e.name,t).catch(d=>{const p=d instanceof Error?d.message:`Failed to probe ${e.name}`;N(p,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{Pm(e.name,t).catch(d=>{const p=d instanceof Error?d.message:`Failed to recover ${e.name}`;N(p,"error")})}}
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
  `}const or=g(null);function jd(t){or.value=t,Mm(t.name)}function fl(){or.value=null}function pg(t){return typeof t!="number"||Number.isNaN(t)?"확인 필요":t>=.85?"높음":t>=.7?"상승 중":"안정"}function mg({keeper:t}){var v,_;const e=t.metrics_series??[];if(e.length<2){const f=(((v=t.context)==null?void 0:v.context_ratio)??t.context_ratio??0)*100,h=f>85?"#ef4444":f>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${f.toFixed(1)}%;background:${h}"></div>
        </div>
        <span class="chart-pct">${f.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,l=e.map((f,h)=>{const C=a+h/(i-1)*(n-2*a),b=s-a-(f.context_ratio??0)*(s-2*a);return{x:C,y:b,p:f}}),c=l.map(({x:f,y:h})=>`${f.toFixed(1)},${h.toFixed(1)}`).join(" "),d=(((_=e[e.length-1])==null?void 0:_.context_ratio)??0)*100,p=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:f})=>f.is_handoff).map(({x:f})=>o`
          <line x1="${f.toFixed(1)}" y1="${a}" x2="${f.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${p}" stroke-width="1.5"/>
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}function _g({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(s=>o`
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
  `}function vg({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px;">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function fg({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function gl({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom:12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}async function gg(){try{const t=await Ya({actor:oc(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=gc(t.result);await _s(),e!=null&&e.skipped_reason?N(e.skipped_reason,"warning"):N(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";N(e,"error")}}function $g({keeper:t}){return o`
    <div style="margin-top:24px; border-top:1px solid rgba(255,255,255,0.1); padding-top:24px;">
      <h3 style="margin:0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display:grid; grid-template-columns:1fr 1fr; gap:20px;">
        <div style="display:flex; flex-direction:column; gap:12px;">
          <${dg} keeper=${t} />
          <${ug}
            actor=${oc()}
            keeper=${t}
            onPokeLodge=${()=>{gg()}}
          />
        </div>

        <div style="min-height:345px;">
          <${zd}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function hg(){var s,a,i,l,c;const t=or.value;if(!t)return null;const e=Md(t.name,t.agent_name),n=(((s=t.traits)==null?void 0:s.length)??0)>0||(((a=t.interests)==null?void 0:a.length)??0)>0||!!t.skill_primary||!!t.last_heartbeat;return o`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${d=>{d.target.classList.contains("keeper-detail-overlay")&&fl()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?o`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
              ${e?o`<div style="font-size:12px; color:#94a3b8;">${e}</div>`:null}
              ${t.agent_name?o`<div style="font-size:12px; color:#888;">Runtime agent: ${t.agent_name}</div>`:null}
            </div>
            <${be} status=${t.status} />
          </div>
          <button
            onClick=${()=>fl()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        <${mg} keeper=${t} />

        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">
          ${n?o`
                <${M} title="Profile">
                  <${gl} traits=${t.traits??[]} label="Traits" />
                  <${gl} traits=${t.interests??[]} label="Interests" />
                  ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span></div>`:null}
                  ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">Last heartbeat: <${et} timestamp=${t.last_heartbeat} /></div>`:null}
                <//>
              `:null}

          ${t.trpg_stats?o`
                <${M} title="TRPG Stats">
                  <${_g} stats=${t.trpg_stats} />
                <//>
              `:null}

          ${t.inventory&&t.inventory.length>0?o`
                <${M} title="Equipment (${t.inventory.length})">
                  <${vg} items=${t.inventory} />
                <//>
              `:null}

          ${t.relationships&&Object.keys(t.relationships).length>0?o`
                <${M} title="Relationships (${Object.keys(t.relationships).length})">
                  <${fg} rels=${t.relationships} />
                <//>
              `:null}

          <${M} title="Memory & Context">
            <div class="keeper-signal-list">
              <div class="keeper-signal-row">
                <span>Context pressure</span>
                <strong>${pg(((i=t.context)==null?void 0:i.context_ratio)??t.context_ratio??null)}</strong>
              </div>
              <div class="keeper-signal-row">
                <span>Current ratio</span>
                <strong>
                  ${typeof(((l=t.context)==null?void 0:l.context_ratio)??t.context_ratio)=="number"?`${Math.round((((c=t.context)==null?void 0:c.context_ratio)??t.context_ratio??0)*100)}%`:"-"}
                </strong>
              </div>
              ${t.memory_recent_note?o`<div class="keeper-memory-note">${t.memory_recent_note}</div>`:o`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>

        <${$g} keeper=${t} />
      </div>
    </div>
  `}function yg({cluster:t,project:e,room:n,generatedAt:s}){return o`
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
        <strong>${s?ne(s):"기록 없음"}</strong>
      </div>
    </div>
  `}function bg(){const t=Hc.value,e=Mt((t==null?void 0:t.status)??(Re.value?"bad":"warn")),n=!t||t.sections.length===0,s=(t==null?void 0:t.status)==="error"||(t==null?void 0:t.status)==="unavailable"&&!(t!=null&&t.cached);return o`
    <${M} title="판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>휴리스틱 대신 별도 판단 결과</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${e}">
          ${Ut((t==null?void 0:t.status)??(Re.value?"error":"loading"))}
        </span>
        ${t!=null&&t.model?o`<span class="command-chip">${t.model}</span>`:null}
        ${t!=null&&t.generated_at?o`<span class="command-chip">${ne(t.generated_at)}</span>`:null}
        ${t!=null&&t.cached?o`<span class="command-chip">캐시</span>`:null}
        ${t!=null&&t.stale?o`<span class="command-chip warn">오래됨</span>`:null}
        ${t!=null&&t.refreshing?o`<span class="command-chip warn">갱신 중</span>`:null}
      </div>

      ${Re.value?o`<div class="empty-state error">${Re.value}</div>`:null}
      ${t!=null&&t.error?o`<div class="empty-state error">${t.error}</div>`:null}
      ${t!=null&&t.summary?o`<div class="mission-inline-note">${t.summary}</div>`:null}
      ${t!=null&&t.last_error&&!t.error?o`<div class="mission-inline-note">최근 갱신 실패: ${t.last_error}</div>`:null}

      ${t&&t.sections.length>0?o`
            <div class="mission-briefing-grid">
              ${t.sections.slice(0,3).map(a=>o`
                <article class="mission-briefing-section ${Mt(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${Mt(a.status)}">${Ut(a.status)}</span>
                      ${dl(a.signal_class)?o`<span class="command-chip ${a.signal_class==="mixed"?"warn":""}">${dl(a.signal_class)}</span>`:null}
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
          `:!Ge.value&&!Re.value&&n?o`
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
                      <strong>${Ea(a.scope_type)}${a.scope_id?` · ${a.scope_id}`:""}</strong>
                      <span class="command-chip ${a.severity==="watch"?"warn":""}">${Ut(a.severity)}</span>
                    </div>
                    <p>${a.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{$a(s)}} disabled=${Ge.value}>
          ${Ge.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{$a(!0)}} disabled=${Ge.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function kg({item:t,selected:e,sessionLookup:n}){const s=If(t),a=t.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),i=t.top_action??null;return o`
    <article class="mission-attention-card ${Mt((i==null?void 0:i.severity)??t.severity)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Ef(t.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.summary}</strong>
            <div class="mission-card-target">${Ea(t.target_type)}${t.target_id?` · ${t.target_id}`:""}</div>
          </div>
          <span class="command-chip ${Mt((i==null?void 0:i.severity)??t.severity)}">${i?Af(i):t.severity}</span>
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
            <strong>${t.last_seen_at?ne(t.last_seen_at):"기록 없음"}</strong>
            <small>${Ea(t.target_type)}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${i?eo(i.action_type):"판단 필요"}</strong>
            <small>${i?Tf(i):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${i?o`<div class="mission-inline-note">${i.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?o`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>o`
                  <button class="mission-link-row" onClick=${()=>Cd(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${Ut(l.status)} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:o`<div class="empty-state">직접 연결된 세션이 아직 없습니다.</div>`}

        ${t.related_agent_names.length>0?o`
              <div class="mission-pill-row">
                ${t.related_agent_names.slice(0,8).map(l=>o`
                  <button class="mission-pill action" onClick=${()=>$s(l)}>${l}</button>
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
              <button class="control-btn ghost" onClick=${()=>sr(i,s,"상황판 주의 신호")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>Sd(i,s,"상황판 주의 신호")}>
                원인 보기
              </button>
            `:o`
              <button class="control-btn ghost" onClick=${()=>kd(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>xd(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function xg({brief:t,selected:e}){var l,c;const n=t.member_previews.slice(0,4),s=t.top_recommendation??null,a=t.top_attention??null,i=n.map(d=>d.display_name??d.agent_name);return o`
    <article class="mission-crew-card ${Mt(((l=t.top_attention)==null?void 0:l.severity)??t.health??t.status)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Cd(t.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.goal}</strong>
            <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          </div>
          <span class="command-chip ${Mt(((c=t.top_attention)==null?void 0:c.severity)??t.health??t.status)}">${Ut(t.status)}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${t.member_names.length}</strong>
            <small>${i.slice(0,3).join(", ")||t.member_names.slice(0,3).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${Cf(t.elapsed_sec)}</strong>
            <small>${t.started_at?`${ne(t.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 흐름</span>
            <strong>${t.last_event_at?ne(t.last_event_at):"기록 없음"}</strong>
            <small>${t.communication_summary??"요약 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>충원 상태</span>
            <strong>${t.active_count??0}/${t.required_count||1}</strong>
            <small>활성 / 필요</small>
          </div>
        </div>
      </button>

      ${t.blocker_summary?o`<div class="mission-inline-note">막힘 · ${t.blocker_summary}</div>`:null}

      <div class="mission-crew-event">
        <span>최근 사건</span>
        <strong>${t.last_event_summary??"최근 세션 이벤트가 없습니다."}</strong>
        <small>${t.last_event_at?ne(t.last_event_at):"시각 없음"}</small>
      </div>

      ${t.operation_badges.length>0?o`
            <div class="mission-pill-row">
              ${t.operation_badges.slice(0,3).map(d=>o`
                <span class="mission-pill">
                  ${d.operation_id} · ${Ut(d.status)}${d.stage?` · ${d.stage}`:""}
                </span>
              `)}
            </div>
          `:null}

      ${n.length>0?o`
            <div class="mission-member-preview-grid">
              ${n.map(d=>o`
                <button class="mission-member-preview" onClick=${()=>$s(d.agent_name)}>
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
        <button class="control-btn ghost" onClick=${()=>hi("intervene",t.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>hi("command",t.session_id)}>세션 원인 보기</button>
        ${s?o`<button class="control-btn ghost" onClick=${()=>sr(s,a,"상황판 세션 요약")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function Sg({detail:t,loading:e,error:n}){if(e&&!t)return o`
      <${M} title="세션 상세" class="mission-list-card">
        <div class="loading-indicator">세션 상세 불러오는 중...</div>
      <//>
    `;if(n&&!t)return o`
      <${M} title="세션 상세" class="mission-list-card">
        <div class="empty-state error">${n}</div>
      <//>
    `;if(!(t!=null&&t.session))return null;const s=t.session;return o`
    <${M} title="세션 상세" class="mission-list-card" semanticId="mission.session_detail">
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
                      <span>${a.timestamp?ne(a.timestamp):"시각 없음"}</span>
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
                  <button class="mission-member-preview" onClick=${()=>$s(a.agent_name)}>
                    <strong>${a.display_name??a.agent_name}</strong>
                    <span>${a.current_work??"현재 작업 없음"}</span>
                    <small>
                      ${a.recent_output_preview??a.recent_input_preview??"최근 입출력 없음"}
                      ${a.is_live===!1?" · archived participant":""}
                      ${a.last_activity_at?` · ${ne(a.last_activity_at)}`:""}
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
                  <button class="mission-link-row" onClick=${()=>hi("command",s.session_id)}>
                    <strong>${a.operation_id}</strong>
                    <span>${Ut(a.status)}${a.stage?` · ${a.stage}`:""}</span>
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
                    <span>${Ut(a.status)}${a.generation!=null?` · 세대 ${a.generation}`:""}</span>
                    <small>${a.current_work??"현재 작업 정보 없음"}</small>
                  </div>
                `):o`<div class="empty-state">직접 연결된 키퍼는 없습니다.</div>`}
          </div>
        </div>
      </div>
    <//>
  `}function Cg({row:t}){var i,l,c,d,p,v,_,f,h,C,b,x;const e=[`세대 ${t.brief.generation??((i=t.keeper)==null?void 0:i.generation)??0}`,t.brief.context_ratio!=null?`컨텍스트 ${Math.round(t.brief.context_ratio*100)}%`:((l=t.keeper)==null?void 0:l.context_ratio)!=null?`컨텍스트 ${Math.round(t.keeper.context_ratio*100)}%`:null,t.brief.last_turn_ago_s!=null?`최근 턴 ${Math.round(t.brief.last_turn_ago_s)}초 전`:null].filter(y=>y!==null).join(" · "),n=t.recentTools.length>0?t.recentTools.join(", "):wf(Df(t.keeper)),s=Rd(t.brief.name,t.brief.agent_name??((c=t.keeper)==null?void 0:c.agent_name)),a={name:t.brief.name,koreanName:((d=t.keeper)==null?void 0:d.koreanName)??null,runtimeLabel:s,emoji:((p=t.keeper)==null?void 0:p.emoji)??null,tone:Mt(t.brief.status??((v=t.keeper)==null?void 0:v.status)),statusRaw:t.brief.status??((_=t.keeper)==null?void 0:_.status)??null,statusLabel:Ut(t.brief.status??((f=t.keeper)==null?void 0:f.status)),focus:t.currentWork,lastActivityAt:((h=t.keeper)==null?void 0:h.last_heartbeat)??null,lastActivityFallback:"최근 활동 없음",continuity:e||"연속성 정보 없음",contextRatio:t.brief.context_ratio??((C=t.keeper)==null?void 0:C.context_ratio)??null,summary:(b=t.keeper)!=null&&b.skill_reason?`판단 요약 · ${zt(t.keeper.skill_reason,120)}`:null,relatedSessionId:null,recentEvent:t.recentEvent,recentInput:t.recentInput,recentOutput:t.recentOutput,recentTools:t.recentTools,allowedTools:[],disclosureLabel:"연속성 상세"};return o`<${Td}
    variant="mission"
    model=${{...a,recentTools:t.recentTools.length>0?t.recentTools:[n],recentEvent:t.recentEvent??`runtime agent · ${t.brief.agent_name??((x=t.keeper)==null?void 0:x.agent_name)??"기록 없음"}`}}
    onClick=${()=>{t.keeper&&jd(t.keeper)}}
  />`}function Ag({item:t}){const e=t.action??null,n=t.attention??null;return o`
    <article class="mission-action-card ${Mt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${Mt(t.severity)}">
          ${t.signal_type==="action"&&e?eo(e.action_type):(n==null?void 0:n.kind)??"내부 신호"}
        </span>
        <span class="mission-card-target">${Ea(t.target_type)}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      ${e?o`<div class="mission-action-preview">${e.reason}</div>`:null}
      <div class="mission-card-actions">
        ${e?o`
              <button class="control-btn ghost" onClick=${()=>sr(e,n,"상황판 내부 신호")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Sd(e,n,"상황판 내부 신호")}>이 이슈의 원인 보기</button>
            `:n?o`
                <button class="control-btn ghost" onClick=${()=>kd(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>xd(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function $l(){var v;const t=Qa.value;if(di.value&&!t)return o`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(ga.value&&!t)return o`<div class="empty-state error">${ga.value}</div>`;if(!t)return o`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;te.value&&!t.attention_queue.some(_=>_.id===te.value)&&(te.value=null);const e=t.sessions;le.value&&!e.some(_=>_.session_id===le.value)&&(le.value=null);const n=t.attention_queue.find(_=>_.id===te.value)??null,s=(n==null?void 0:n.related_session_ids.find(_=>e.some(f=>f.session_id===_)))??null,a=le.value??s??((v=e[0])==null?void 0:v.session_id)??null,i=Mf(),l=e.find(_=>_.session_id===a)??null,c=t.keeper_briefs.slice(0,6).map(Rf),d=t.attention_queue.filter(_=>_.related_session_ids.length>0).slice(0,6),p=t.internal_signals.slice(0,3);return nt(()=>{ov(a)},[a]),o`
    <section class="dashboard-panel mission-view">
      <${xt} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 어떤 세션이 돌고 있고, 누가 참여하며, 어디가 막혔는지를 한 시점에서 읽는 기본 관찰면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${Mt(t.summary.room_health)}">${Ut(t.summary.room_health)}</span>
          <span class="command-chip">${t.summary.project??"프로젝트 미지정"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?ne(t.generated_at):"기록 없음"}</span>
        </div>
      </div>

      <${to} />

      <${yg}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <${bg} />

      ${a?o`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${(l==null?void 0:l.goal)??a}${n?` · ${n.summary}`:""}</span>
              <button class="control-btn ghost" onClick=${Lf}>선택 해제</button>
            </div>
          `:null}

      <${M} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 작전을 먼저 봅니다.</p>
        </div>
        <div class="mission-list-stack">
          ${e.length>0?e.map(_=>o`<${xg} key=${_.session_id} brief=${_} selected=${a===_.session_id} />`):o`<div class="empty-state">지금 활성 세션이 없습니다.</div>`}
        </div>
      <//>

      <${Sg}
        detail=${ui.value}
        loading=${Qs.value}
        error=${Zs.value}
      />

      <div class="mission-human-grid">
        <${M} title="주의 대기열" class="mission-list-card" semanticId="mission.attention_queue">
          <div class="mission-section-head">
            <h3>어느 세션을 먼저 봐야 하나</h3>
            <p>문제와 경고는 세션에 연결된 것만 먼저 보여주고, 원인 분석은 선택된 세션에서 이어서 봅니다.</p>
          </div>
          <div class="mission-lane-stack">
            ${d.length>0?d.map(_=>o`<${kg} key=${_.id} item=${_} selected=${te.value===_.id} sessionLookup=${i} />`):o`<div class="empty-state">지금 세션 단위 주의 대기열은 비어 있습니다.</div>`}
          </div>
        <//>

        <${M} title="내부 신호" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>시스템 진단</h3>
            <p>artifact scope drift 같은 내부 신호는 메인 판단을 방해하지 않도록 접어 둔 보조 면에만 둡니다.</p>
          </div>
          <details class="mission-card-disclosure">
            <summary>내부 신호 ${p.length}</summary>
            <div class="mission-list-stack">
              ${p.length>0?p.map(_=>o`<${Ag} key=${_.id} item=${_} />`):o`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
            </div>
          </details>
        <//>
      </div>

      <${M} title="키퍼 연속성" class="mission-list-card" semanticId="mission.keeper_activity">
        <div class="mission-section-head">
          <h3>키퍼 연속성 요약</h3>
          <p>카드 제목은 keeper 이름이고, runtime agent 이름은 상세에만 보조 라벨로 보여줍니다.</p>
        </div>
        <div class="mission-activity-list">
          ${c.length>0?c.map(_=>o`<${Cg} key=${_.brief.name} row=${_} />`):o`<div class="empty-state">지금 보이는 키퍼가 없습니다.</div>`}
        </div>
        <div class="mission-card-actions">
          <button class="control-btn ghost" onClick=${()=>ot("execution")}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${()=>ot("command")}>지휘 진단면 보기</button>
        </div>
      <//>
    </section>
  `}const Tg="modulepreload",Ig=function(t){return"/dashboard/"+t},hl={},Rg=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(p){return Promise.all(p.map(v=>Promise.resolve(v).then(_=>({status:"fulfilled",value:_}),_=>({status:"rejected",reason:_}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),d=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(p=>{if(p=Ig(p),p in hl)return;hl[p]=!0;const v=p.endsWith(".css"),_=v?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${p}"]${_}`))return;const f=document.createElement("link");if(f.rel=v?"stylesheet":Tg,v||(f.as="script"),f.crossOrigin="",f.href=p,d&&f.setAttribute("nonce",d),document.head.appendChild(f),v)return new Promise((h,C)=>{f.addEventListener("load",h),f.addEventListener("error",()=>C(new Error(`Unable to preload CSS for ${p}`)))})}))}function i(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&i(c.reason);return e().catch(i)})};function Zn(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function tt(t){if(!t)return"정보 없음";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function Mg(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Nd(t){if(!t)return"정보 없음";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"기한 지남":n<60?`${n}초 후`:n<3600?`${Math.round(n/60)}분 후`:n<86400?`${Math.round(n/3600)}시간 후`:`${Math.round(n/86400)}일 후`}function E(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let yl=!1,Eg=0;function Lg(){return++Eg}let bo=null;async function Pg(){bo||(bo=Rg(()=>import("./mermaid.core-_WNGbsRE.js").then(e=>e.bE),[]).then(e=>e.default));const t=await bo;return yl||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),yl=!0),t}function _e(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function kn(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":`${Math.round(t*100)}%`}function Ve(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":t<60?`${Math.round(t)}초`:t<3600?`${Math.round(t/60)}분`:`${Math.round(t/3600)}시간`}function hs(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function Ae(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:hs(t/e*100)}function zg(t,e){const n=hs(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function so(t){if(!t)return"최근 체인 이력이 없습니다";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`토큰 ${t.tokens}`),t.message&&e.push(t.message),e.join(" · ")}const jg=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],wd=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"orchestra",label:"오케스트라",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],Ng=wd.map(t=>t.id),wg=["chain_start","node_start","node_complete","chain_complete","chain_error"],Dg={warroom:{title:"실시간 워룸",description:"실제 실행, 워커, 메시지, 트레이스를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 작전, 분견대, 의존 관계를 먼저 읽는 기본 진입 표면입니다."},orchestra:{title:"룸 오케스트라 맵",description:"룸, 세션, 레인, 워커, 키퍼를 한 장의 작전판으로 읽는 시각화 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"레인 이동, 워커 결속, 막힘을 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 작전별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"실제 관리 유닛인지, 실시간 에이전트 기반 자동 투영인지 구분해서 봅니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"작전, 주체, 유닛 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"결정 승인과 유닛 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function bl(t){return!!t&&Ng.includes(t)}function Og(){const t=D.value.params;return t.source!=="mission"&&t.source!=="execution"?{}:{source:t.source,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function ys(t){const e=Og(),n=qd(),s=ir();if(t==="operations")return e;if(t==="chains"){const a=ln.value;return a?{...e,surface:t,operation:a}:{...e,surface:t}}return t==="swarm"||t==="warroom"||t==="orchestra"?{...e,surface:t,...n?{run_id:n}:{},...s?{operation_id:s}:{}}:{...e,surface:t}}function qg(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function Fg(t){switch(t){case"company":return"중대";case"platoon":return"소대";case"squad":return"분대";case"agent":return"에이전트";default:return t}}function ut(t){return mi.value===t}function bs(){return Gi.value}function Bg(t){var a,i,l,c,d,p,v;const e=Gi.value,n=Be.value,s=fs.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"실시간 실행, 워커, 메시지, 트레이스를 한 화면에서 보고 필요한 세부 표면으로 바로 이동합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 의존 관계를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(i=e==null?void 0:e.swarm_status)==null?void 0:i.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((d=(c=e==null?void 0:e.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:d.reason)??"레인 이동과 막힘 근거를 보고 다음 확인 도구를 고릅니다."};case"orchestra":return{tool:"masc_operator_snapshot",reason:"룸, 세션, 레인, 워커, 키퍼를 한 장에서 훑은 뒤 내려볼 대상을 고릅니다."};case"chains":return{tool:(v=(p=s==null?void 0:s.operations[0])==null?void 0:p.preview_run)!=null&&v.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"이 구조가 실제 관리 단위인지 자동 투영인지 먼저 구분해야 지휘면을 오해하지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 유닛과 작전을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"트레이스 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 제어 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function Kg(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function Ug(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function Dd(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Od(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function qd(){const e=Od().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function ir(){const e=Od().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Wg(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function Hg(t){return t.status==="claimed"||t.status==="in_progress"}function Gg(t){const e=vs.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function ko(t){var e;return((e=vs.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function Jg(t){const e=vs.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function ve(t){try{await t()}catch{}}function rr(t){return(t==null?void 0:t.trim().toLowerCase())??""}function ce(t){const e=rr(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function Ot(t){const e=rr(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function Yg(){var n,s,a,i,l,c,d,p,v;const t=Be.value;if(!t)return!1;const e=t.workers.some(_=>_.joined||_.live_presence||_.completed||_.current_task_matches_run||_.heartbeat_fresh||_.claim_marker_seen||_.done_marker_seen||_.final_marker_seen||!!_.current_task||!!_.bound_task_id||!!_.last_message);return!!((n=t.operation)!=null&&n.operation_id||(s=t.detachment)!=null&&s.detachment_id||(((a=t.summary)==null?void 0:a.joined_workers)??0)>0||(((i=t.summary)==null?void 0:i.live_workers)??0)>0||(((l=t.summary)==null?void 0:l.current_task_bound)??0)>0||(((c=t.summary)==null?void 0:c.fresh_heartbeats)??0)>0||(((d=t.summary)==null?void 0:d.claim_markers_seen)??0)>0||(((p=t.summary)==null?void 0:p.done_markers_seen)??0)>0||(((v=t.summary)==null?void 0:v.final_markers_seen)??0)>0||e||t.recent_messages.length>0||t.recent_trace_events.length>0)}function Vg(t){const e=rr(t.status);return e==="active"||e==="running"}function Xg(){var i,l,c,d;const t=((i=Lt.value)==null?void 0:i.sessions)??[],e=Be.value,n=((l=e==null?void 0:e.detachment)==null?void 0:l.session_id)??null;if(n){const p=t.find(v=>v.session_id===n);if(p)return p}const s=((c=e==null?void 0:e.operation)==null?void 0:c.operation_id)??ir();if(s){const p=t.find(v=>v.command_plane_operation_id===s);if(p)return p}const a=((d=e==null?void 0:e.detachment)==null?void 0:d.detachment_id)??null;if(a){const p=t.find(v=>v.command_plane_detachment_id===a);if(p)return p}return t.find(Vg)??t[0]??null}function An(t){return t==="proven"?"ok":t==="partial"?"warn":"bad"}function Xe(t){return Array.isArray(t)?t:[]}function jt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)?t:{}}function Is(t){return typeof t=="string"&&t.trim()!==""?t:null}function Qg(t){return typeof t=="number"&&Number.isFinite(t)?t:null}function Zg(t){const e=t.split("/");return e.length<=3?t:`…/${e.slice(-3).join("/")}`}function t$(t){return t==="proven"?"충분":t==="partial"?"부분":"부족"}function e$(t){return t==="proven"?"협업 증거가 충분합니다":t==="partial"?"흔적은 있으나 협업 증거가 덜 모였습니다":"증거가 부족합니다"}function n$(t,e,n,s,a,i,l,c,d){const p=[`${s}명이 실제 흔적을 남겼고, 계획된 참여자는 ${a}명입니다.`,l>0?`서로를 참조한 상호작용 증거가 ${l}건 있습니다.`:"서로를 참조한 명시적 상호작용 증거가 아직 없습니다.",c>0?`도구·산출물·체크포인트 증거가 ${c}건 있습니다.`:"도구·산출물·체크포인트 증거가 거의 없습니다.",d>0?`CPv2 backing trace가 ${d}건 있어 실행 흔적은 남아 있습니다.`:"관리형 backing trace는 아직 없습니다."];return n==="proven"&&e==="insufficient"?[p[0]??"","왜 이렇게 판정됐나: 과거 proof는 proved였지만, 현재 보이는 live evidence는 부족해서 partial로 완화했습니다.","다음 보강 포인트: 최근 응답 턴이나 도구 호출을 다시 남겨 historical proof를 현재 상태와 연결해야 합니다."]:n==="proven"&&e==="partial"?[p[0]??"","왜 이렇게 판정됐나: historical proof는 강하지만, 현재 live evidence는 아직 partial 수준입니다.","다음 보강 포인트: 최근 상호작용과 실행 근거를 더 남기면 proven으로 회복할 수 있습니다."]:t==="partial"?[p[0]??"",i>0?`partial인 이유: 호출되었지만 응답하지 않은 참여자가 ${i}명 있습니다.`:l===0?"partial인 이유: 여러 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.":"partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.",d>0?"다음 보강 포인트: 응답 턴이나 도구 호출을 남기면 proof가 협업 수준으로 올라갑니다.":"다음 보강 포인트: 관리형 trace 또는 산출물 연결을 더 남기면 근거가 강해집니다."]:t==="proven"?[p[0]??"","결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.","다음 행동: raw evidence는 접어두고 결과 산출물과 다음 실행 결정만 확인하면 됩니다."]:[p[0]??"",i>0?`결론: 협업 시도는 있었지만 무응답 참여자가 ${i}명 있어 협업 증거로 인정하기 어렵습니다.`:"결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.",c>0?"다음 보강 포인트: 응답 턴과 도구 근거를 서로 연결해 남겨야 합니다.":"다음 보강 포인트: 참여자 간 턴, 도구 근거, 산출물 연결을 더 남겨야 합니다."]}function s$(t){return t==="historical_only"?"historical only":t==="live_and_historical"?"live + historical":"live"}function kl(t){return(t==null?void 0:t.mode)==="requested_not_found"?"bad":(t==null?void 0:t.mode)==="latest_auto_selected"?"warn":"ok"}function a$(t){return(t==null?void 0:t.mode)==="requested_not_found"?"선택 실패":(t==null?void 0:t.mode)==="latest_auto_selected"?"자동 선택":(t==null?void 0:t.mode)==="explicit"?"명시 선택":"선택 없음"}function o$(t){return t.activity_state==="acted"?(t.interaction_count??0)>0||(t.tool_evidence_count??0)>0?"ok":"warn":t.activity_state==="mentioned_only"?"warn":"bad"}function i$(t){return t.activity_state==="acted"?"실제 흔적":t.activity_state==="mentioned_only"?"호출만 됨":"계획만 됨"}function r$(t){if(t.activity_state==="acted")return`턴 ${t.turn_count??0} · spawn ${t.spawn_count??0} · 도구 근거 ${t.tool_evidence_count??0}`;if(t.activity_state==="mentioned_only"){const e=t.requested_by?`호출자 ${t.requested_by}`:"호출자 미상";return`호출 ${t.mention_count??0}회 · ${e}`}return"계획된 참여자이지만 아직 이벤트가 없습니다."}function xl(t){return Array.isArray(t.tool_names)?t.tool_names:[]}function l$({selection:t,summary:e}){if(!t||t.mode==="explicit")return null;const n=t.mode==="latest_auto_selected"&&(e==null?void 0:e.historical_verdict)==="proven"&&(e==null?void 0:e.live_verdict)!=="proven";return o`
    <div class="command-guide-card ${kl(t)}">
      <div class="command-guide-head">
        <strong>${a$(t)}</strong>
        <span class="command-chip ${kl(t)}">${t.mode??"none"}</span>
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
  `}function c$({item:t}){return o`
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
      ${xl(t).length>0?o`<div class="semantic-tag-row">
            ${xl(t).map(e=>o`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
    </article>
  `}function d$(t){const e=new Map;for(const n of t){const s=[n.timestamp??"",n.event_type??"",n.actor??"",n.summary??""].join("|"),a=n.source??"unknown",i=e.get(s);if(i){i.sources.includes(a)||i.sources.push(a),!i.operation_id&&n.operation_id&&(i.operation_id=n.operation_id);continue}e.set(s,{...n,sources:[a]})}return[...e.values()]}function u$(t){return t.sources.length===2?"세션 + 지휘":t.sources.length===1?t.sources[0]==="unknown"?"출처 미상":t.sources[0]??"출처":t.sources.join(" + ")}function p$(t){const e=[];for(const[n,s]of Object.entries(t))if(s!=null){if(typeof s=="string"){if(s.trim()==="")continue;e.push({label:n,value:s});continue}if(typeof s=="number"||typeof s=="boolean"){e.push({label:n,value:String(s)});continue}}return e}function m$(t){const e=jt(t),n=jt(e.traces),s=Array.isArray(n.events)?n.events:[],a=jt(e.detachments),i=Array.isArray(a.detachments)?a.detachments:[],l=jt(i[0]),c=jt(l.detachment),d=jt(l.operation),p=jt(e.summary),v=jt(p.operations),_=jt(v.summary);return[{label:"작전",value:Is(e.operation_id)??"없음"},{label:"분견대",value:Is(e.detachment_id)??"없음"},{label:"트레이스 이벤트",value:`${s.length}`},{label:"분견대 상태",value:Is(c.status)??"없음"},{label:"작전 단계",value:Is(d.stage)??"없음"},{label:"활성 작전",value:`${Qg(_.active)??0}`}]}function _$({item:t}){return o`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${t.summary??t.event_type??"이벤트"}</strong>
          <div class="command-meta-line">
            <span>${u$(t)}</span>
            <span>${t.event_type??"이벤트"}</span>
            <span>${t.actor??"시스템"}</span>
          </div>
        </div>
        <span class="command-chip">${tt(t.timestamp)}</span>
      </div>
      ${t.sources.length>1?o`<div class="semantic-tag-row">
            ${t.sources.map(e=>o`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
    </article>
  `}function v$({item:t}){const e=t.recent_output_preview??null,n=t.recent_input_preview??null,s=t.recent_event_summary??null,a=t.recent_request_preview??null,i=t.last_active_at??t.recent_request_at??null;return o`
    <article class="mission-activity-row proof-actor-row">
      <div class="mission-activity-head">
        <div>
          <strong>${t.actor}</strong>
          <div class="mission-activity-meta">
            <span>${t.role??"참여자"}</span>
            <span>${i?tt(i):"기록 없음"}</span>
          </div>
        </div>
        <span class="command-chip ${o$(t)}">
          ${i$(t)}
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>${r$(t)}</span>
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
      ${Xe(t.recent_tool_names).length>0?o`<div class="semantic-tag-row">
            ${Xe(t.recent_tool_names).map(l=>o`<span class="semantic-tag">${l}</span>`)}
          </div>`:null}
    </article>
  `}function f$({item:t}){return o`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${t.kind}</strong>
          <div class="command-meta-line">
            <span>${Zg(t.path)}</span>
          </div>
        </div>
        <span class="command-chip ${t.exists?"ok":"warn"}">${t.exists?"존재함":"없음"}</span>
      </div>
    </article>
  `}function Sl({title:t,rows:e}){return e.length===0?null:o`
    <div class="proof-kv-block">
      ${t?o`<strong>${t}</strong>`:null}
      <div class="proof-kv-grid">
        ${e.map(n=>o`
          <span>${n.label}</span>
          <strong>${n.value}</strong>
        `)}
      </div>
    </div>
  `}function g$(){var U,I,A;const t=D.value.params,e=t.session_id??null,n=t.operation_id??null;nt(()=>{td(e,n)},[e,n]);const s=Zc.value;if(pi.value&&!s)return o`<section class="dashboard-panel"><div class="loading-indicator">근거 화면 불러오는 중…</div></section>`;if(Je.value&&!s)return o`<section class="dashboard-panel"><div class="error-card">${Je.value}</div></section>`;const a=s==null?void 0:s.summary,i=(s==null?void 0:s.selection)??null,l=Xe(s==null?void 0:s.actor_contributions),c=Xe(s==null?void 0:s.artifacts),d=Xe(s==null?void 0:s.tool_evidence),p=(s==null?void 0:s.proof_verdict)??"insufficient",v=(a==null?void 0:a.live_verdict)??p,_=(a==null?void 0:a.historical_verdict)??null,f=(a==null?void 0:a.verdict_basis)??"live",h=(s==null?void 0:s.cp_backing_evidence)??null,C=Array.isArray((U=h==null?void 0:h.traces)==null?void 0:U.events)?((A=(I=h.traces)==null?void 0:I.events)==null?void 0:A.length)??0:0,b=(a==null?void 0:a.actors_count)??l.length,x=(a==null?void 0:a.planned_actor_count)??l.length,y=(a==null?void 0:a.unanswered_actor_count)??l.filter(j=>j.activity_state!=="acted"&&(j.mention_count??0)>0).length,$=(a==null?void 0:a.mentioned_actor_count)??l.filter(j=>(j.mention_count??0)>0).length,R=(a==null?void 0:a.interaction_count)??0,T=(a==null?void 0:a.evidence_count)??0,P=d$(Xe(s==null?void 0:s.timeline)),G=p$(jt(s==null?void 0:s.goal_binding)),L=m$(h),V=c.filter(j=>j.exists).length,X=c.length-V,rt=n$(p,v,_,b,x,y,R,T,C);return o`
    <section class="dashboard-panel mission-view">
      <${xt} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>근거</h2>
          <p>이 세션이 실제로 여러 참여자의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${An(p)}">${t$(p)}</span>
          ${s!=null&&s.session_id?o`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?o`<span class="command-chip">${tt(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${Je.value?o`<div class="error-card">${Je.value}</div>`:null}

      <${l$} selection=${i} summary=${a??null} />

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${An(p)}">
          <span>판정</span>
          <strong>${e$(p)}</strong>
          <small>${(a==null?void 0:a.detail)??"협업 증거를 verdict로 요약합니다."}</small>
        </div>
        <div class="summary-stat-card ${An(v)}">
          <span>Live 판정</span>
          <strong>${v}</strong>
          <small>${s$(f)} 기준 최종 판정에 반영</small>
        </div>
        <div class="summary-stat-card ${An(_??"insufficient")}">
          <span>Historical proof</span>
          <strong>${_??"none"}</strong>
          <small>persisted proof 문서 기준</small>
        </div>
        <div class="summary-stat-card">
          <span>실제 흔적</span>
          <strong>${b}</strong>
          <small>이벤트를 남긴 actor 수</small>
        </div>
        <div class="summary-stat-card ${x>b?"warn":"ok"}">
          <span>계획된 참여자</span>
          <strong>${x}</strong>
          <small>${$>0?`${$}명 호출됨`:"호출 기록 없음"}</small>
        </div>
        <div class="summary-stat-card ${y>0?"warn":"ok"}">
          <span>무응답</span>
          <strong>${y}</strong>
          <small>${y>0?"호출됐지만 응답 근거 없음":"무응답 참여자 없음"}</small>
        </div>
        <div class="summary-stat-card ${R>0?"ok":"warn"}">
          <span>직접 상호작용</span>
          <strong>${R}</strong>
          <small>참여자 간 직접 연결 근거</small>
        </div>
        <div class="summary-stat-card ${T>0?"ok":"warn"}">
          <span>근거</span>
          <strong>${T}</strong>
          <small>도구 / 산출물 / 체크포인트</small>
        </div>
        <div class="summary-stat-card ${C>0?"ok":"warn"}">
          <span>CP 트레이스</span>
          <strong>${C}</strong>
          <small>관리형 backing 이벤트</small>
        </div>
        <div class="summary-stat-card ${X===0&&c.length>0?"ok":"warn"}">
          <span>산출물</span>
          <strong>${V}/${c.length}</strong>
          <small>${X>0?`${X}개 누락`:"전부 존재함"}</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${M} title="3줄 근거 요약" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, 왜 아직 부족한지, 다음에 무엇을 남겨야 하는지만 먼저 봅니다.</p>
          </div>
          <div class="proof-summary-stack">
            ${rt.map((j,J)=>o`
              <article class="proof-summary-block ${J===1&&p!=="proven"?An(p):""}">
                <strong>${J===0?"지금 결론":J===1?"왜 이렇게 판정됐나":"다음 보강 포인트"}</strong>
                <span>${j}</span>
              </article>
            `)}
          </div>
        <//>

        <${M} title="목표 연결" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 화면이 어떤 세션과 목표를 기준으로 그려졌는지 먼저 고정합니다.</p>
          </div>
          <${Sl} rows=${G} />
          <details class="mission-card-disclosure compact">
            <summary>원본 목표 연결 JSON</summary>
            <pre class="command-json-block">${Zn((s==null?void 0:s.goal_binding)??{})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${M} title="협업 타임라인" class="mission-list-card" semanticId="proof.timeline">
          <div class="mission-section-head">
            <h3>협업 타임라인</h3>
            <p>team-session과 command-plane에서 같은 사건이 보이면 한 줄로 묶어 읽습니다.</p>
          </div>
          <div class="mission-list-stack">
            ${P.length>0?P.slice(0,18).map(j=>o`<${_$} key=${j.id} item=${j} />`):o`<div class="empty-state">표시할 타임라인 근거가 없습니다.</div>`}
          </div>
        <//>

        <${M} title="참여 흔적" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>실제 흔적, 호출만 된 참여자, 계획만 된 참여자를 구분해서 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${l.length>0?l.map(j=>o`<${v$} key=${j.actor} item=${j} />`):o`<div class="empty-state">표시할 참여 흔적이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${M} title="도구 근거" class="mission-list-card" semanticId="proof.tool_evidence">
          <div class="mission-section-head">
            <h3>어떤 도구를 언제 썼는가</h3>
            <p>숫자만 보여주지 말고, 최근 도구 호출 근거를 직접 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${d.length>0?d.map((j,J)=>o`<${c$} key=${`${j.actor??"system"}-${J}`} item=${j} />`):o`<div class="empty-state">기록된 tool evidence가 없습니다.</div>`}
          </div>
        <//>

        <${M} title="실행 근거" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>작전, 분견대, 트레이스 수만 먼저 보고, 원본 CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${Sl} rows=${L} />
          <details class="mission-card-disclosure compact">
            <summary>원본 CPv2 backing JSON</summary>
            <pre class="command-json-block">${Zn(h??{})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${M} title="산출물" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>어떤 파일 산출물이 남았나</h3>
            <p>proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${c.length>0?c.map(j=>o`<${f$} key=${j.path} item=${j} />`):o`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function $$(){const t=gs(D.value);return t?o`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${eo(t.action_type)}</span>
        <span class="command-chip">${nr(t)}</span>
        <span class="command-chip">${Sf(D.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?o`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function h$(){const t=Z.value,e=Dg[t],n=Bg(t);return o`
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
  `}function Rs({label:t,value:e,subtext:n,percent:s,color:a}){return o`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${zg(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(hs(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function Ms({label:t,value:e,detail:n,percent:s,tone:a}){return o`
    <article class="command-signal-rail ${E(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${E(a)}" style=${`width: ${Math.max(8,Math.round(hs(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function y$(){var X,rt,U,I;const t=bs(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,i=t==null?void 0:t.alerts.summary,l=(X=t==null?void 0:t.swarm_status)==null?void 0:X.overview,c=t==null?void 0:t.swarm_proof,d=t==null?void 0:t.operations.microarch,p=(e==null?void 0:e.managed_unit_count)??0,v=(e==null?void 0:e.total_units)??0,_=(n==null?void 0:n.active)??0,f=(s==null?void 0:s.active)??0,h=(l==null?void 0:l.moving_lanes)??0,C=(l==null?void 0:l.active_lanes)??0,b=(c==null?void 0:c.workers.done)??0,x=(c==null?void 0:c.workers.expected)??0,y=(i==null?void 0:i.bad)??0,$=(i==null?void 0:i.warn)??0,R=(a==null?void 0:a.pending)??0,T=(a==null?void 0:a.total)??0,P=_+f,G=((rt=d==null?void 0:d.cache)==null?void 0:rt.l1_hit_rate)??((I=(U=d==null?void 0:d.signals)==null?void 0:U.cache_contention)==null?void 0:I.l1_hit_rate)??0,L=_>0||f>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",V=_>0||h>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return o`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${L}</h3>
        <p>${V}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${E(_>0?"ok":"warn")}">활성 작전 ${_}</span>
          <span class="command-chip ${E(h>0?"ok":(C>0,"warn"))}">이동 레인 ${h}/${Math.max(C,h)}</span>
          <span class="command-chip ${E(y>0?"bad":$>0?"warn":"ok")}">치명 알림 ${y}</span>
          <span class="command-chip ${E(R>0?"warn":"ok")}">승인 대기 ${R}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Rs}
          label="관리 단위 범위"
          value=${`${p}/${Math.max(v,p)}`}
          subtext=${v>0?`${v-p}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${Ae(p,Math.max(v,p))}
          color="#67e8f9"
        />
        <${Rs}
          label="실행 열도"
          value=${String(P)}
          subtext=${`${_}개 작전 + ${f}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${Ae(P,Math.max(p,P||1))}
          color="#4ade80"
        />
        <${Rs}
          label="스웜 이동감"
          value=${`${h}/${Math.max(C,h)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${tt(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${Ae(h,Math.max(C,h||1))}
          color="#fbbf24"
        />
        <${Rs}
          label="증거 수집률"
          value=${`${b}/${Math.max(x,b)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${Ae(b,Math.max(x,b||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${Ms}
        label="승인 대기열"
        value=${`${R}건 대기`}
        detail=${`현재 정책 창에서 ${T}개 결정을 추적 중입니다`}
        percent=${Ae(R,Math.max(T,R||1))}
        tone=${R>0?"warn":"ok"}
      />
      <${Ms}
        label="알림 압력"
        value=${`치명 ${y} / 주의 ${$}`}
        detail=${y>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${Ae(y*2+$,Math.max((y+$)*2,1))}
        tone=${y>0?"bad":$>0?"warn":"ok"}
      />
      <${Ms}
        label="디스패치 점유"
          value=${`${f}개 가동`}
        detail=${p>0?`${p}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${Ae(f,Math.max(p,f||1))}
        tone=${f>0?"ok":"warn"}
      />
      <${Ms}
        label="캐시 신뢰도"
        value=${G?kn(G):"정보 없음"}
        detail=${G?"microarch 캐시 텔레메트리에서 집계한 L1 적중률":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${hs((G??0)*100)}
        tone=${G>=.75?"ok":G>=.4?"warn":"bad"}
      />
    </div>
  `}function b$(){var f,h,C,b,x;const t=bs(),e=fs.value,n=gs(D.value),s=Kg(n),a=t==null?void 0:t.topology.summary,i=t==null?void 0:t.operations.summary,l=(f=t==null?void 0:t.swarm_status)==null?void 0:f.overview,c=t==null?void 0:t.operations.microarch,d=t==null?void 0:t.decisions.summary,p=t==null?void 0:t.alerts.summary,v=(h=c==null?void 0:c.signals)==null?void 0:h.issue_pressure,_=c==null?void 0:c.cache;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(i==null?void 0:i.active)??0}</strong><small>${((C=t==null?void 0:t.detachments.summary)==null?void 0:C.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(d==null?void 0:d.pending)??0}</strong><small>${(d==null?void 0:d.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(p==null?void 0:p.bad)??0}</strong><small>${(p==null?void 0:p.warn)??0}건 주의</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((b=e==null?void 0:e.summary)==null?void 0:b.active_chains)??0}</strong><small>${((x=e==null?void 0:e.summary)==null?void 0:x.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${tt(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(v==null?void 0:v.pending_ops)??0}</strong><small>${(_==null?void 0:_.l1_hit_rate)!=null?`${kn(_.l1_hit_rate)} L1 적중`:"캐시 데이터 없음"} · ${(v==null?void 0:v.tone)??"정보 없음"}</small></div>
    </div>
  `}function k$(){var X,rt,U,I,A,j,J,Q,it;const t=bs(),e=Jt.value,n=gt.value,s=Dd(),a=s?Gt.value.find(W=>W.name===s)??null:null,i=s?de.value.filter(W=>W.assignee===s&&Hg(W)):[],l=((X=t==null?void 0:t.operations.summary)==null?void 0:X.active)??0,c=((rt=t==null?void 0:t.detachments.summary)==null?void 0:rt.total)??0,d=((U=t==null?void 0:t.decisions.summary)==null?void 0:U.pending)??0,p=e==null?void 0:e.detachments.detachments.find(W=>{const Pt=W.detachment.heartbeat_deadline,ke=Pt?Date.parse(Pt):Number.NaN;return W.detachment.status==="stalled"||!Number.isNaN(ke)&&ke<=Date.now()}),v=e==null?void 0:e.alerts.alerts.find(W=>W.severity==="bad"),_=!!(n!=null&&n.room||n!=null&&n.project),f=(a==null?void 0:a.current_task)??null,h=Wg(a==null?void 0:a.last_seen),C=h!=null?h<=120:null,b=[_?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?i.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:de.value.length>0?"masc_claim":"masc_add_task"}:f?C===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${f} 이지만 heartbeat가 stale 합니다 (${h}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${f}${h!=null?` · 마지막 활동 ${h}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((I=t.topology.summary)==null?void 0:I.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((A=t.topology.summary)==null?void 0:A.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((j=t.topology.summary)==null?void 0:j.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},d>0?{title:"디스패치 준비도",tone:"warn",detail:`${d}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:p||v?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${p?` · detachment ${p.detachment.detachment_id} 가 stalled 상태입니다`:""}${v?` · alert ${v.title??v.alert_id}`:""}${!e&&!p&&!v?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:d>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],x=_?!s||!a?"masc_join":i.length===0?de.value.length>0?"masc_claim":"masc_add_task":f?C===!1?"masc_heartbeat":!t||(((J=t.topology.summary)==null?void 0:J.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":d>0?"masc_policy_approve":l>0&&c===0||p||v?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",y=Gg(x),R=Jg(x==="masc_set_room"?["repo-root-room"]:x==="masc_plan_set_task"?["claimed-not-current"]:x==="masc_heartbeat"?["heartbeat-stale"]:x==="masc_dispatch_tick"?["no-detachments"]:x==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),T=ko("room_task_hygiene"),P=ko("cpv2_benchmark"),G=ko("supervisor_session"),L=((Q=vs.value)==null?void 0:Q.docs)??[],V=[T,P,G].filter(W=>W!==null);return o`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${O} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(y==null?void 0:y.title)??x}</strong>
            <span class="command-chip ok">${x}</span>
          </div>
          <p>${(y==null?void 0:y.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(it=y==null?void 0:y.success_signals)!=null&&it.length?o`<div class="command-tag-row">
                ${y.success_signals.map(W=>o`<span class="command-tag ok">${W}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${b.map(W=>o`
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

        ${R.length>0?o`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${R.length}</span>
                </div>
                <div class="command-guide-list">
                  ${R.map(W=>o`
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
        ${_i.value?o`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:Sa.value?o`<div class="empty-state error">${Sa.value}</div>`:o`
                <div class="command-path-grid">
                  ${V.map(W=>o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${W.title}</strong>
                        <span class="command-chip">${W.id}</span>
                      </div>
                      <p>${W.summary}</p>
                      <div class="command-card-sub">${W.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${W.steps.slice(0,4).map(Pt=>o`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Pt.tool}</span>
                            <span>${Pt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${L.length>0?o`<div class="command-doc-links">
                      ${L.map(W=>o`<span class="command-tag">${W.title}: ${W.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function x$(){return o`
    <${y$} />
    <${b$} />
    <${k$} />
  `}function S$(){return ya.value?o`<div class="empty-state">command-plane detail 불러오는 중…</div>`:ka.value?o`<div class="empty-state error">${ka.value}</div>`:o`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}const Te=g(null),Es=g("compact"),ie=g({zoom:1,panX:0,panY:0}),xo=g(!1),Ls=g(!1),En={width:1280,height:760},Fd=.42,Bd=1.9;function ta(t,e,n){return Math.max(e,Math.min(n,t))}function lr(t,e){const n=t==null?void 0:t.trim();return n?n.length<=e?n:`${n.slice(0,Math.max(1,e-1))}…`:null}function C$(t){return t==="compact"?"집약":"균형"}function Cl(t){switch((t??"").trim().toLowerCase()){case"room":return"룸";case"session":return"세션";case"operation":return"작전";case"detachment":return"분견대";case"lane":return"레인";case"worker":return"워커";case"keeper":return"키퍼";default:return(t==null?void 0:t.trim())||"노드"}}function Ps(t,e,n){if(t<=0)return[];if(t===1)return[Math.round((e+n)/2)];const s=(n-e)/(t-1);return Array.from({length:t},(a,i)=>Math.round(e+i*s))}function A$(t,e){const n=new Map;for(const s of t){const a=e(s),i=n.get(a)??[];i.push(s),n.set(a,i)}return n}function Kd(t){return t==="compact"?{room:{x:660,y:108},sessions:{y:228,min:220,max:1110},operations:{y:338,min:260,max:1050},detachments:{y:430,min:310,max:1e3},lanes:{y:540,min:220,max:1110},worker:{perRow:5,xSpacing:60,ySpacing:52,laneOffsetY:76,freeBaseY:662},keeper:{startX:1180,colSpacing:92,rowSpacing:90,startY:176,columns:2},signalRadius:116}:{room:{x:700,y:112},sessions:{y:236,min:240,max:1140},operations:{y:356,min:300,max:1080},detachments:{y:454,min:340,max:1030},lanes:{y:584,min:230,max:1110},worker:{perRow:4,xSpacing:72,ySpacing:60,laneOffsetY:82,freeBaseY:720},keeper:{startX:1210,colSpacing:108,rowSpacing:102,startY:188,columns:2},signalRadius:132}}function Ud(t,e){return t.kind==="room"?e==="compact"?{width:138,height:138,radius:68}:{width:156,height:156,radius:76}:t.kind==="worker"?e==="compact"?{width:70,height:36,radius:18}:{width:84,height:44,radius:22}:t.kind==="lane"?e==="compact"?{width:156,height:48,radius:15}:{width:176,height:56,radius:17}:t.kind==="keeper"?e==="compact"?{width:118,height:50,radius:22}:{width:132,height:60,radius:24}:t.kind==="session"?e==="compact"?{width:182,height:58,radius:17}:{width:202,height:68,radius:18}:e==="compact"?{width:176,height:58,radius:16}:{width:196,height:68,radius:18}}function T$(t,e){const n=t.kind==="worker"?e==="compact"?10:14:t.kind==="keeper"?e==="compact"?12:16:t.kind==="lane"?e==="compact"?16:22:e==="compact"?18:26;return lr(t.label,n)??t.label}function I$(t,e){if(e==="compact"&&(t.kind==="worker"||t.kind==="keeper"||t.kind==="detachment"))return null;const n=t.kind==="session"?e==="compact"?20:28:e==="compact"?14:24;return lr(t.subtitle,n)}function R$(t,e){return e==="compact"&&t.kind!=="session"&&t.kind!=="operation"?null:lr(t.status,e==="compact"?10:14)}function M$(t,e){const n=Kd(e),s=new Map,a=t.nodes,i=a.find(b=>b.kind==="room")??null,l=a.filter(b=>b.kind==="session"),c=a.filter(b=>b.kind==="operation"),d=a.filter(b=>b.kind==="detachment"),p=a.filter(b=>b.kind==="lane"),v=a.filter(b=>b.kind==="worker"),_=a.filter(b=>b.kind==="keeper");i&&s.set(i.id,{x:n.room.x,y:n.room.y}),Ps(l.length,n.sessions.min,n.sessions.max).forEach((b,x)=>{const y=l[x];y&&s.set(y.id,{x:b,y:n.sessions.y})}),Ps(c.length,n.operations.min,n.operations.max).forEach((b,x)=>{const y=c[x];y&&s.set(y.id,{x:b,y:n.operations.y})}),Ps(d.length,n.detachments.min,n.detachments.max).forEach((b,x)=>{const y=d[x];y&&s.set(y.id,{x:b,y:n.detachments.y})}),Ps(p.length,n.lanes.min,n.lanes.max).forEach((b,x)=>{const y=p[x];y&&s.set(y.id,{x:b,y:n.lanes.y})});const f=new Map(p.map(b=>{const x=s.get(b.id);return x?[b.id,x.x]:null}).filter(b=>b!==null)),h=A$(v,b=>b.lane_id?`lane:${b.lane_id}`:b.parent_id?b.parent_id:"free");let C=0;for(const[b,x]of h){let y=f.get(b.replace(/^lane:/,""));if(y==null){const R=s.get(b);y=R==null?void 0:R.x}y==null&&(y=260+C%4*180,C+=1);const $=Math.max(1,Math.ceil(x.length/n.worker.perRow));for(let R=0;R<$;R+=1){const T=x.slice(R*n.worker.perRow,(R+1)*n.worker.perRow),P=(T.length-1)*n.worker.xSpacing,G=y-P/2;T.forEach((L,V)=>{var X;s.set(L.id,{x:Math.round(G+V*n.worker.xSpacing),y:b==="free"?n.worker.freeBaseY+R*n.worker.ySpacing:(((X=s.get(b.replace(/^lane:/,"")))==null?void 0:X.y)??n.lanes.y)+n.worker.laneOffsetY+R*n.worker.ySpacing})})}}return _.forEach((b,x)=>{const y=x%n.keeper.columns,$=Math.floor(x/n.keeper.columns);s.set(b.id,{x:n.keeper.startX+y*n.keeper.colSpacing,y:n.keeper.startY+$*n.keeper.rowSpacing})}),s}function E$(t,e,n){if(!e||t.signals.length===0)return[];const s=Kd(n);return t.signals.slice(0,6).map((a,i)=>{const l=(-130+i*36)*(Math.PI/180);return{signalNode:a,x:Math.round(e.x+Math.cos(l)*s.signalRadius),y:Math.round(e.y+Math.sin(l)*s.signalRadius)}})}function L$(t,e,n,s){let a=Number.POSITIVE_INFINITY,i=Number.NEGATIVE_INFINITY,l=Number.POSITIVE_INFINITY,c=Number.NEGATIVE_INFINITY;for(const d of t.nodes){const p=e.get(d.id);if(!p)continue;const v=Ud(d,s);d.kind==="room"?(a=Math.min(a,p.x-v.radius),i=Math.max(i,p.x+v.radius),l=Math.min(l,p.y-v.radius),c=Math.max(c,p.y+v.radius)):(a=Math.min(a,p.x-v.width/2),i=Math.max(i,p.x+v.width/2),l=Math.min(l,p.y-v.height/2),c=Math.max(c,p.y+v.height/2))}for(const d of n)a=Math.min(a,d.x-20),i=Math.max(i,d.x+20),l=Math.min(l,d.y-20),c=Math.max(c,d.y+20);return!Number.isFinite(a)||!Number.isFinite(i)||!Number.isFinite(l)||!Number.isFinite(c)?{minX:0,minY:0,maxX:En.width,maxY:En.height,width:En.width,height:En.height}:{minX:a,minY:l,maxX:i,maxY:c,width:Math.max(1,i-a),height:Math.max(1,c-l)}}function Al(t,e,n){const s=n==="compact"?48:72,a=Math.max(360,e.width-s*2),i=Math.max(280,e.height-s*2),l=ta(Math.min(a/Math.max(t.width,1),i/Math.max(t.height,1)),Fd,Bd),c=t.minX+t.width/2,d=t.minY+t.height/2;return{zoom:l,panX:e.width/2-c*l,panY:e.height/2-d*l}}function P$(t,e){const n=(t.x+e.x)/2,s=e.y>=t.y?32:-32;return`M ${t.x} ${t.y} C ${n} ${t.y+s}, ${n} ${e.y-s}, ${e.x} ${e.y}`}function Tl(t,e,n){if(t==="command"){if(e){Ft(e),ot("command",{...ys(e),...n});return}ot("command",n);return}if(t==="intervene"){ot("intervene",n);return}ot("command",n)}function z$({signalNodes:t,roomPoint:e,onSelect:n}){return!e||t.length===0?null:o`
    ${t.map(({signalNode:s,x:a,y:i})=>o`
      <g
        key=${s.id}
        data-orchestra-signal="true"
        class=${`orchestra-signal-node ${E(s.tone)}`}
        onClick=${()=>n(s.id)}
      >
        <title>${s.label}${s.detail?` — ${s.detail}`:""}</title>
        <line x1=${e.x} y1=${e.y} x2=${a} y2=${i} class="orchestra-signal-link" />
        <circle cx=${a} cy=${i} r="16" class="orchestra-signal-dot" />
        <text x=${a} y=${i+4} text-anchor="middle" class="orchestra-signal-glyph">!</text>
      </g>
    `)}
  `}function j$({edges:t,positions:e,selectedId:n}){return o`
    ${t.map(s=>{const a=e.get(s.source),i=e.get(s.target);if(!a||!i)return null;const l=n!=null&&(s.source===n||s.target===n);return o`
        <path
          key=${s.id}
          d=${P$(a,i)}
          class=${`orchestra-edge ${E(s.tone)} ${s.animated?"animated":""} ${l?"active":""}`}
        />
      `})}
  `}function N$({orchestra:t,positions:e,density:n,selectedId:s,onSelect:a}){var l;const i=((l=t.focus)==null?void 0:l.target_kind)==="node"?t.focus.target_id:null;return o`
    ${t.nodes.map(c=>{const d=e.get(c.id);if(!d)return null;const p=Ud(c,n),v=c.id===s,_=c.id===i,f=c.visual_class??c.kind,h=T$(c,n),C=I$(c,n),b=R$(c,n);if(c.kind==="room")return o`
          <g
            key=${c.id}
            data-orchestra-node="true"
            class=${`orchestra-node room ${E(c.tone)} ${v?"selected":""} ${_?"focused":""}`}
            onClick=${()=>a(c.id)}
          >
            <title>${c.label}</title>
            <circle cx=${d.x} cy=${d.y} r=${p.radius} class="orchestra-room-ring outer" />
            <circle cx=${d.x} cy=${d.y} r=${p.radius-16} class="orchestra-room-ring inner" />
            <text x=${d.x} y=${d.y-10} text-anchor="middle" class="orchestra-room-glyph">${c.glyph??"◎"}</text>
            <text x=${d.x} y=${d.y+22} text-anchor="middle" class="orchestra-room-label">${h}</text>
          </g>
        `;const x=d.x-p.width/2,y=d.y-p.height/2;return o`
        <g
          key=${c.id}
          data-orchestra-node="true"
          class=${`orchestra-node ${f} ${E(c.tone)} ${v?"selected":""} ${_?"focused":""}`}
          onClick=${()=>a(c.id)}
        >
          <title>${c.label}${c.subtitle?` — ${c.subtitle}`:""}${c.status?` (${c.status})`:""}</title>
          <rect x=${x} y=${y} width=${p.width} height=${p.height} rx=${p.radius} class="orchestra-node-body" />
          <text x=${x+16} y=${y+24} class="orchestra-node-glyph">${c.glyph??"•"}</text>
          <text x=${x+38} y=${y+24} class="orchestra-node-label">${h}</text>
          ${C?o`<text x=${x+38} y=${y+42} class="orchestra-node-subtitle">${C}</text>`:null}
          ${b?o`<text x=${x+p.width-10} y=${y+18} text-anchor="end" class="orchestra-node-status">${b}</text>`:null}
        </g>
      `})}
  `}function Wd(t){var s,a;const e=Te.value;if(e){const i=t.nodes.find(c=>c.id===e);if(i)return{type:"node",value:i};const l=t.signals.find(c=>c.id===e);if(l)return{type:"signal",value:l}}if(((s=t.focus)==null?void 0:s.target_kind)==="node"){const i=t.nodes.find(l=>{var c;return l.id===((c=t.focus)==null?void 0:c.target_id)});if(i)return{type:"node",value:i}}if(((a=t.focus)==null?void 0:a.target_kind)==="signal"){const i=t.signals.find(l=>{var c;return l.id===((c=t.focus)==null?void 0:c.target_id)});if(i)return{type:"signal",value:i}}const n=t.nodes[0];return n?{type:"node",value:n}:null}function w$({orchestra:t}){const e=Wd(t);if(!e)return o`<aside class="orchestra-drawer card"><div class="empty-state">선택 가능한 대상이 아직 없습니다.</div></aside>`;if(e.type==="signal"){const i=e.value;return o`
      <aside class="orchestra-drawer card ${E(i.tone)}">
        <div class="card-title-row">
          <div class="card-title">${i.label}</div>
          <span class="command-chip ${E(i.tone)}">${Cl(i.kind)}</span>
        </div>
        <p>${i.detail??"세부 설명이 없습니다."}</p>
        ${i.suggested_surface?o`
              <div class="command-action-row">
                <button
                  class="control-btn"
                  onClick=${()=>Tl("command",i.suggested_surface,i.suggested_params??{})}
                >
                  추천 화면 열기
                </button>
              </div>
            `:null}
      </aside>
    `}const n=e.value,s=t.signals.filter(i=>i.source_id===n.id||i.target_id===n.id),a=t.edges.filter(i=>i.source===n.id||i.target===n.id);return o`
    <aside class="orchestra-drawer card ${E(n.tone)}">
      <div class="card-title-row">
        <div class="card-title">${n.label}</div>
        <span class="command-chip ${E(n.tone)}">${Cl(n.kind)}</span>
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
          ${s.map(i=>o`<span class="command-chip ${E(i.tone)}">${i.label}</span>`)}
        </div>
      `:null}
      <div class="command-card-sub">연결 ${a.length}개 · 근거 ${n.provenance}</div>
      ${n.link_tab&&(n.link_surface||Object.keys(n.link_params??{}).length>0)?o`
            <div class="command-action-row">
              <button
                class="control-btn"
                onClick=${()=>Tl(n.link_tab??"command",n.link_surface,n.link_params??{})}
              >
                이 화면 열기
              </button>
            </div>
          `:null}
    </aside>
  `}function D$(){var V,X,rt,U;const t=Ji.value,e=Ln(null),n=Ln(null),s=Ln(""),[a,i]=mn(En);if(nt(()=>{const I=e.current;if(!I)return;const A=()=>{const J=I.getBoundingClientRect();J.width<=0||J.height<=0||i({width:Math.max(640,Math.round(J.width)),height:Math.max(480,Math.round(J.height))})};if(A(),typeof ResizeObserver>"u")return window.addEventListener("resize",A),()=>window.removeEventListener("resize",A);const j=new ResizeObserver(()=>A());return j.observe(I),()=>j.disconnect()},[]),vi.value&&!t)return o`<section class="card command-section"><div class="empty-state">오케스트라 맵 불러오는 중…</div></section>`;if(Ta.value)return o`<section class="card command-section"><div class="empty-state error">${Ta.value}</div></section>`;if(!t)return o`<section class="card command-section"><div class="empty-state">오케스트라 맵 데이터가 아직 없습니다.</div></section>`;const l=Es.value,c=M$(t,l),d=t.nodes.find(I=>I.kind==="room")??null,p=d?c.get(d.id)??null:null,v=E$(t,p,l),_=L$(t,c,v,l),f=Wd(t),h=(f==null?void 0:f.value.id)??null,C=`${l}:${a.width}x${a.height}:${t.nodes.length}:${t.edges.length}:${t.signals.length}`,b=(I,A)=>{ie.value=I,Ls.value=A},x=()=>{b(Al(_,a,l),!1)},y=()=>{if(Te.value=null,l!=="compact"){Es.value="compact",Ls.value=!1;return}x()};nt(()=>{h&&!t.nodes.some(I=>I.id===h)&&!t.signals.some(I=>I.id===h)&&(Te.value=null)},[C,h,t]),nt(()=>{(!Ls.value||s.current!==C)&&(b(Al(_,a,l),!1),s.current=C)},[C]);const $=ie.value,R=(I,A,j)=>{const J=ie.value.zoom,Q=ta(J*j,Fd,Bd);if(Math.abs(Q-J)<.001)return;const it=(I-ie.value.panX)/J,W=(A-ie.value.panY)/J;b({zoom:Q,panX:I-it*Q,panY:A-W*Q},!0)},T=I=>{I.preventDefault();const A=e.current;if(!A)return;const j=A.getBoundingClientRect(),J=ta(I.clientX-j.left,0,j.width),Q=ta(I.clientY-j.top,0,j.height);R(J,Q,I.deltaY<0?1.1:.92)},P=I=>{var J;const A=I.target;if(!(A instanceof Element)||!A.closest('[data-orchestra-background="true"]'))return;const j=I.currentTarget;j&&(n.current={pointerId:I.pointerId,startX:I.clientX,startY:I.clientY,panX:ie.value.panX,panY:ie.value.panY},xo.value=!0,Ls.value=!0,(J=j.setPointerCapture)==null||J.call(j,I.pointerId))},G=I=>{const A=n.current;!A||A.pointerId!==I.pointerId||b({zoom:ie.value.zoom,panX:A.panX+(I.clientX-A.startX),panY:A.panY+(I.clientY-A.startY)},!0)},L=I=>{var j;if(!n.current)return;const A=I==null?void 0:I.currentTarget;A&&I&&((j=A.releasePointerCapture)==null||j.call(A,I.pointerId)),n.current=null,xo.value=!1};return o`
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
          <button class="control-btn ghost" onClick=${x}>맞춤 보기</button>
          <button class="control-btn ghost" onClick=${y}>초기화</button>
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
          <span class="command-chip">${Math.round($.zoom*100)}%</span>
        </div>
        <div class="orchestra-toolbar-group">
          <button
            class=${`control-btn ${l==="balanced"?"is-active":"ghost"}`}
            onClick=${()=>{Es.value="balanced",Te.value=h}}
          >
            균형
          </button>
          <button
            class=${`control-btn ${l==="compact"?"is-active":"ghost"}`}
            onClick=${()=>{Es.value="compact",Te.value=h}}
          >
            집약
          </button>
          <span class="command-chip">${C$(l)}</span>
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
            class=${`orchestra-canvas ${xo.value?"is-dragging":""}`}
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
            <g transform=${`translate(${$.panX} ${$.panY}) scale(${$.zoom})`}>
              <${j$} edges=${t.edges} positions=${c} selectedId=${h} />
              <${z$} signalNodes=${v} roomPoint=${p} onSelect=${I=>{Te.value=I}} />
              <${N$}
                orchestra=${t}
                positions=${c}
                density=${l}
                selectedId=${h}
                onSelect=${I=>{Te.value=I}}
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

        <${w$} orchestra=${t} />
      </div>
    </section>
  `}const Hd="masc_dashboard_agent_name";function O$(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Hd))==null?void 0:s.trim())||"dashboard"}const ao=g(O$()),dn=g(""),za=g("운영 점검"),un=g(""),ts=g(""),es=g("2"),vn=g(""),kt=g("note"),ns=g(""),ss=g(""),as=g(""),os=g("2"),is=g(""),ja=g("운영자 중지 요청"),yi=g(""),q$=g(""),zs=g(null);function F$(t){const e=t.trim()||"dashboard";ao.value=e,localStorage.setItem(Hd,e)}function Na(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function cr(t){switch((t??"").trim().toLowerCase()){case"judgment":return"상주 판단";case"fallback":return"보조 읽기 모델";default:return(t==null?void 0:t.trim())||"안내"}}function wa(t){switch((t??"").trim().toLowerCase()){case"judgment":return"ok";case"fallback":return"warn";default:return"warn"}}function oo(t){return t!=null&&t.enabled?t.refreshing?"갱신 중":t.judge_online?"온라인":t.last_error?"오류":"대기":"꺼짐"}function Gd(t){return t!=null&&t.enabled?t.judge_online?"ok":t.refreshing?"warn":"bad":"warn"}function dr(t){return t!=null&&t.fresh_until?t.fresh_until:"갱신 기준 없음"}function Il(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function fn(t){return typeof t=="string"?t.trim().toLowerCase():""}function B$(t){var s;const e=fn(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=fn((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function So(t){const e=fn(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function Rl(t){return t.some(e=>fn(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function K$(t){return t.target_type==="team_session"}function U$(t){return t.target_type==="keeper"}function De(t){switch(t){case"broadcast":return"방송";case"room_pause":return"방 일시정지";case"room_resume":return"방 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"team_worker_spawn_batch":return"세션 작업자 교체";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"키퍼 메시지";case"keeper_msg":return"키퍼 메시지";case"swarm_run_continue":return"스웜 실행 계속";case"swarm_run_rerun":return"스웜 실행 재실행";case"swarm_run_abandon":return"스웜 실행 포기";default:return(t==null?void 0:t.trim())||"액션"}}function pn(t){switch(t){case"room":return"방";case"team_session":return"세션";case"keeper":return"키퍼";case"swarm_run":return"스웜 실행";default:return(t==null?void 0:t.trim())||"대상"}}function Qe(t){switch(fn(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Da(t){return t?"확인 후 실행":"즉시 실행"}function W$(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"worker_spawn_batch":return"작업자 교체";default:return t}}function vt(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function H$(t){return!t||typeof t!="object"||Array.isArray(t)?null:t}function G$(t){if(!t)return"";const e=t.spawn_batch;return Na(e!==void 0?e:t)}function Jd(t){const e=H$(t.payload);if(t.target_type==="room"){if(t.action_type==="broadcast"){dn.value=vt(e,"message")??t.summary;return}if(t.action_type==="task_inject"){un.value=vt(e,"title")??"운영자 주입 작업",ts.value=vt(e,"description")??t.summary,es.value=vt(e,"priority")??es.value;return}t.action_type==="room_pause"&&(za.value=vt(e,"reason")??t.summary);return}if(t.target_type==="team_session"){if(t.target_id&&(vn.value=t.target_id),t.action_type==="team_stop"){ja.value=vt(e,"reason")??t.summary;return}kt.value=t.action_type==="team_worker_spawn_batch"?"worker_spawn_batch":t.action_type==="team_task_inject"?"task":t.action_type==="team_broadcast"?"broadcast":"note";const n=vt(e,"message");if(n&&(ns.value=n),kt.value==="worker_spawn_batch"){is.value=G$(e);return}kt.value==="task"&&(ss.value=vt(e,"task_title")??vt(e,"title")??"운영자 주입 작업",as.value=vt(e,"task_description")??vt(e,"description")??t.summary,os.value=vt(e,"task_priority")??vt(e,"priority")??os.value);return}t.target_type==="keeper"&&(t.target_id&&(yi.value=t.target_id),q$.value=vt(e,"message")??t.summary)}function J$(t){Jd({action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.suggested_payload,summary:t.summary})}function Y$(t){Jd({action_type:t.action_type,target_type:t.target_type,target_id:t.target_id??null,payload:t.suggested_payload,summary:t.reason}),N("추천 액션 payload를 폼에 채웠습니다","success")}function V$(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function qe(t){const e=ao.value.trim()||"dashboard";try{const n=await Uc({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?N("확인 대기열에 올렸습니다","warning"):N(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return N(s,"error"),null}}async function Ml(){const t=dn.value.trim();if(!t)return;await qe({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(dn.value="")}async function X$(){await qe({action_type:"room_pause",target_type:"room",payload:{reason:za.value.trim()||"운영 점검"},successMessage:"방 일시정지를 요청했습니다"})}async function Yd(){await qe({action_type:"room_resume",target_type:"room",payload:{},successMessage:"방 재개를 요청했습니다"})}async function Q$(){const t=un.value.trim();if(!t)return;await qe({action_type:"task_inject",target_type:"room",payload:{title:t,description:ts.value.trim()||"개입 화면에서 주입",priority:Number.parseInt(es.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(un.value="",ts.value="")}async function Z$(){var l;const t=Lt.value,e=vn.value||((l=t==null?void 0:t.sessions[0])==null?void 0:l.session_id)||"";if(!e){N("먼저 세션을 고르세요","warning");return}const n={};if(kt.value==="worker_spawn_batch"){const c=is.value.trim();if(!c){N("spawn_batch JSON을 먼저 채우세요","warning");return}try{const p=JSON.parse(c);if(Array.isArray(p))n.spawn_batch=p;else if(p&&typeof p=="object"&&Array.isArray(p.spawn_batch))n.spawn_batch=p.spawn_batch;else{N("spawn_batch는 배열 또는 { spawn_batch: [...] } 형태여야 합니다","warning");return}}catch(p){const v=p instanceof Error?p.message:"spawn_batch JSON 파싱에 실패했습니다";N(v,"error");return}await qe({action_type:"team_worker_spawn_batch",target_type:"team_session",target_id:e,payload:n,successMessage:"작업자 교체 요청을 적용했습니다"})&&(is.value="");return}const s=ns.value.trim();s&&(n.message=s);let a="team_note";kt.value==="broadcast"?a="team_broadcast":kt.value==="task"&&(a="team_task_inject"),kt.value==="task"&&(n.task_title=ss.value.trim()||"운영자 주입 작업",n.task_description=as.value.trim()||"개입 화면에서 주입",n.task_priority=Number.parseInt(os.value,10)||2),await qe({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(ns.value="",kt.value==="task"&&(ss.value="",as.value=""))}async function th(){var n;const t=Lt.value,e=vn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){N("먼저 세션을 고르세요","warning");return}await qe({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:ja.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function El(t,e="confirm"){const n=ao.value.trim()||"dashboard";try{await Wc(n,t,e),N(e==="deny"?"승인 대기를 거부했습니다":"확인 실행을 완료했습니다","success")}catch(s){const a=s instanceof Error?s.message:e==="deny"?"승인 대기 거부에 실패했습니다":"확인 실행에 실패했습니다";N(a,"error")}}function Vd(t){switch(t){case"explicit":return"실제 관리 단위";case"hybrid":return"관리 단위 + 자동 보강";case"auto":return"자동 투영";default:return"출처 미상"}}function Xd(t){switch(t){case"explicit":return"ok";case"hybrid":return"warn";case"auto":return"warn";default:return"warn"}}function eh(t){switch(t){case"explicit":return"지금 보이는 유닛은 실제로 정의된 지휘면 관리 단위입니다.";case"hybrid":return"일부는 실제 관리 단위이고, 비어 있는 부분은 실시간 에이전트 편성을 보고 자동 보강한 구조입니다.";case"auto":return"이 화면은 실시간 에이전트 편성을 지휘면 모양으로 자동 투영한 것입니다. 실제 명령 체계와 1:1로 같다고 보면 안 됩니다.";default:return"이 화면은 관리 토폴로지와 실효 토폴로지가 섞여 있을 수 있습니다."}}function nh(t){const e=t.unit.source??"unknown";return e==="explicit"?t.active_operation_count&&t.active_operation_count>0?"실제 관리 단위이며 연결된 작전이 있습니다.":"실제 관리 단위이지만 현재 연결된 작전은 없습니다.":e==="hybrid"?t.active_operation_count&&t.active_operation_count>0?"관리 단위를 기반으로 자동 보강된 구조이며 일부 작전이 연결돼 있습니다.":"관리 단위를 기반으로 자동 보강된 구조이며 현재 실행 연결은 약합니다.":t.active_operation_count&&t.active_operation_count>0?"자동 생성된 구조이지만 이 노드에 연결된 작전 흔적은 있습니다.":"자동 생성된 구조이며 현재 실행 연결은 없습니다."}function Qd({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,i=t.unit.policy,l=t.unit.source??"unknown",c=a>0?`${a}개 작전 연결`:"실행 연결 없음";return o`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${Fg(t.unit.kind)}</span>
            <span class="command-chip ${E(t.health)}">${t.health??"ok"}</span>
            <span class="command-chip ${Xd(l)}">${Vd(l)}</span>
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
          <div class="command-card-sub">${nh(t)}</div>
          ${t.reasons&&t.reasons.length>0?o`<div class="command-tag-row">
                ${t.reasons.map(d=>o`<span class="command-tag warn">${d}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?o`<div class="command-tree-children">
            ${t.children.map(d=>o`<${Qd} node=${d} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function sh({alert:t}){return o`
    <article class="command-alert ${E(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${E(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"범위"}:${t.scope_id??"정보 없음"}</span>
        <span>${tt(t.timestamp)}</span>
      </div>
      ${t.detail?o`<p>${t.detail}</p>`:null}
    </article>
  `}function ur({event:t}){return o`
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
      <pre class="command-trace-detail">${Zn(t.detail)}</pre>
    </article>
  `}function ah(){const t=Jt.value,e=t==null?void 0:t.topology,n=e==null?void 0:e.source,s=e==null?void 0:e.summary,a=(s==null?void 0:s.managed_unit_count)??0,i=(s==null?void 0:s.active_operation_count)??0;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${O} panelId="command.topology" compact=${!0} />
      </div>
      ${t?o`
            <div class="command-topology-explainer">
              <div class="command-tree-title-row">
                <span class="command-chip ${Xd(n)}">${Vd(n)}</span>
                <span class="command-chip">관리 유닛 ${a}</span>
                <span class="command-chip ${i>0?"ok":"warn"}">활성 작전 ${i}</span>
              </div>
              <p>${eh(n)}</p>
            </div>
          `:null}
      ${t&&t.topology.units.length>0?o`${t.topology.units.map(l=>o`<${Qd} node=${l} />`)}`:o`<div class="empty-state">지금은 실시간 에이전트나 관리 유닛 기준으로 그릴 지휘 계층이 없습니다.</div>`}
    </section>
  `}function oh(){const t=Jt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${O} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>o`<${sh} alert=${e} />`)}
          </div>`:o`<div class="empty-state">지금 올라온 지휘면 경보는 없습니다.</div>`}
    </section>
  `}function ih(){const t=Jt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${O} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?o`<div class="command-trace-stack">
            ${t.traces.events.map(e=>o`<${ur} event=${e} />`)}
          </div>`:o`<div class="empty-state">최근 트레이스 이벤트가 없습니다.</div>`}
    </section>
  `}function rh(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t,null,2)}catch{return String(t)}}function lh(t,e){return(e==null?void 0:e.status)==="abandoned"||(t==null?void 0:t.recommended_kind)==="continue"?"warn":(t==null?void 0:t.recommended_kind)==="rerun"?"bad":"ok"}function ch(t){switch(t){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(t==null?void 0:t.trim())||"결정"}}function dh(t){return t?t.runtime_blocker?"막힘":t.provider_reachable?"준비됨":"확인 필요":"확인 필요"}function Zd({swarm:t}){var _,f;const e=t.run_id,n=t.resolution_recommendation,s=t.run_resolution;if(!e||!n&&!s)return null;const a=Dd()??"dashboard",i=((_=Lt.value)==null?void 0:_.pending_confirms.find(h=>h.target_type==="swarm_run"&&h.target_id===e))??null,l=lh(n,s),c=((f=t.operation)==null?void 0:f.operation_id)??t.operation_id??void 0,d={run_id:e};c&&(d.operation_id=c),n!=null&&n.reason&&(d.reason=n.reason);const p=async h=>{await Uc({actor:a,action_type:h,target_type:"swarm_run",target_id:e,payload:d})},v=async h=>{i&&await Wc(a,i.confirm_token,h)};return o`
    <article class="command-guide-card ${E(l)}">
      <div class="command-guide-head">
        <strong>런 해석</strong>
        <span class="command-chip ${E(l)}">
          ${ch((s==null?void 0:s.status)??(n==null?void 0:n.recommended_kind)??null)}
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
      ${n!=null&&n.evidence?o`
            <div class="command-tag-row">
              <span class="command-tag">joined ${n.evidence.joined_workers??0}</span>
              <span class="command-tag">trace ${n.evidence.trace_events??0}</span>
              <span class="command-tag">message ${n.evidence.message_events??0}</span>
              ${n.evidence.runtime_blocker?o`<span class="command-tag ${E("bad")}">${n.evidence.runtime_blocker}</span>`:null}
            </div>
          `:null}
      ${i?o`
            <div class="command-guide-card warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip warn">${i.confirm_token}</span>
              </div>
              ${i.preview?o`<pre class="command-trace-detail">${rh(i.preview)}</pre>`:null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${()=>{v("confirm")}} disabled=${at.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${()=>{v("deny")}} disabled=${at.value}>취소</button>
              </div>
            </div>
          `:n?o`
              <div class="command-action-row">
                ${n.continue_available?o`<button class="control-btn ghost" onClick=${()=>{p("swarm_run_continue")}} disabled=${at.value}>계속</button>`:null}
                ${n.rerun_available?o`<button class="control-btn" onClick=${()=>{p("swarm_run_rerun")}} disabled=${at.value}>재실행</button>`:null}
                ${n.abandon_available?o`<button class="control-btn ghost" onClick=${()=>{p("swarm_run_abandon")}} disabled=${at.value}>포기</button>`:null}
              </div>
            `:null}
    </article>
  `}function tu(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function eu({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const i=a.motion_state;i in e?e[i]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return o`
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
  `}function uh({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return o`
    <div class="swarm-worker-grid">
      ${a.map(()=>o`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?o`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function ph({lane:t}){const e=t.counts??{},n=tu(t),s=e.workers??0,a=e.operations??0,i=e.detachments??0,l=a+i,c=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return o`
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
        ${s>0?o`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${uh} total=${s} />
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
              ${t.hard_flags.map(d=>o`<span class="command-chip ${E(d.severity)}">${d.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function nu({lanes:t}){const e=t.slice(0,4);return e.length===0?null:o`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=tu(n),a=n.counts.workers??0,i=n.counts.operations??0,l=n.counts.detachments??0;return o`
          <article class="swarm-story-card ${E(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${E(s)}">${n.motion_state}</span>
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
  `}function mh({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return o`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${E(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?o`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function _h({gap:t}){return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.summary}</strong>
          <div class="command-card-sub">${t.code} · lane ${t.lane_ids.join(", ")||"n/a"}</div>
        </div>
        <span class="command-chip ${E(t.severity)}">${t.count}</span>
      </div>
      ${t.why_it_matters?o`<p>${t.why_it_matters}</p>`:null}
      ${t.next_tool||t.next_step?o`
            <div class="command-card-grid">
              <span>다음 도구</span><span>${t.next_tool??"masc_observe_traces"}</span>
              <span>다음 확인</span><span>${t.next_step??"최근 trace를 확인합니다."}</span>
            </div>
          `:null}
    </article>
  `}function vh({swarm:t}){const e=t==null?void 0:t.narrative;return e?o`
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
  `:null}function fh({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return o`
    <div class="command-guide-card ${E(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${E(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?o`
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
            ${t.expected_artifact_dir?o`<div class="command-card-foot">expected ${t.expected_artifact_dir}</div>`:null}
            ${t.artifact_ref?o`<div class="command-card-foot">${t.artifact_ref}</div>`:null}
            ${t.missing_reason?o`<p>${t.missing_reason}</p>`:null}
          `:o`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function gh(){const t=bs(),e=gs(D.value),n=Ug(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,i=(s==null?void 0:s.lanes.filter(_=>_.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],d=s==null?void 0:s.overview,p=s==null?void 0:s.recommended_next_action,v=i.length<=1;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${O} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?o`
            <${nu} lanes=${i} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(d==null?void 0:d.active_lanes)??0}</strong><small>${(d==null?void 0:d.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(d==null?void 0:d.stalled_lanes)??0}</strong><small>${(d==null?void 0:d.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${tt(d==null?void 0:d.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${tt(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(p==null?void 0:p.label)??"운영자 상태 확인"}</strong><small>${(p==null?void 0:p.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${i.length>0?o`<${eu} lanes=${i} />`:null}

            <div class="command-swarm-layout ${v?"compact":""}">
              <div class="command-card-stack">
                ${i.length>0?i.map(_=>o`<${ph} lane=${_} />`):o`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <${vh} swarm=${s} />

                <div class="command-guide-card highlight ${n==="recommendation"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>${(p==null?void 0:p.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(p==null?void 0:p.lane_id)??"전체"}</span>
                  </div>
                  <p>${(p==null?void 0:p.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(p==null?void 0:p.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${fh} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${E(l.some(_=>_.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?o`<div class="command-card-stack">${l.slice(0,4).map(_=>o`<${_h} gap=${_} />`)}</div>`:o`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?o`<div class="swarm-event-rail">${c.map(_=>o`<${mh} event=${_} />`)}</div>`:o`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:o`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function $h({item:t}){return o`
    <article class="command-guide-card ${E(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${E(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function su({blocker:t}){return o`
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
  `}function hh({worker:t}){return o`
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
      ${t.last_message?o`<div class="command-card-foot">${tt(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function yh(){var v,_,f,h,C,b,x,y,$,R,T,P,G,L,V,X,rt,U,I,A,j,J;const t=Be.value,e=qd(),n=ir(),s=dh(t==null?void 0:t.provider),a=((v=t==null?void 0:t.provider)==null?void 0:v.configured_capacity)??0,i=((_=t==null?void 0:t.provider)==null?void 0:_.actual_slots)??((f=t==null?void 0:t.provider)==null?void 0:f.total_slots)??0,l=((h=t==null?void 0:t.provider)==null?void 0:h.expected_slots)??"n/a",c=((C=t==null?void 0:t.provider)==null?void 0:C.actual_ctx)??((b=t==null?void 0:t.provider)==null?void 0:b.ctx_per_slot)??0,d=((x=t==null?void 0:t.provider)==null?void 0:x.expected_ctx)??"n/a",p=((y=t==null?void 0:t.summary)==null?void 0:y.peak_hot_slots)??(($=t==null?void 0:t.provider)==null?void 0:$.peak_active_slots)??0;return o`
    <div class="command-section-stack">
      <${gh} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${Ca.value?o`<div class="empty-state">Loading swarm live state…</div>`:Aa.value?o`<div class="empty-state error">${Aa.value}</div>`:t?o`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((R=t.summary)==null?void 0:R.joined_workers)??0}/${((T=t.summary)==null?void 0:T.expected_workers)??0}</strong><small>${((P=t.summary)==null?void 0:P.live_workers)??0}개 가동 · ${((G=t.summary)==null?void 0:G.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임 계약</span><strong>${s}</strong><small>설정 ${a||"n/a"} · 실제 ${i}/${l} · ctx ${c}/${d}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(L=t.summary)!=null&&L.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>최대 hot ${p} · ${((V=t.provider)==null?void 0:V.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(X=t.summary)!=null&&X.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((rt=t.operation)==null?void 0:rt.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((U=t.squad)==null?void 0:U.label)??"없음"}</span>
                      <span>실행체</span><span>${((I=t.detachment)==null?void 0:I.detachment_id)??"없음"}</span>
                      <span>목표 해석</span><span>target profile 기준, 달성 사실과 분리</span>
                      <span>예상 워커</span><span>${((A=t.summary)==null?void 0:A.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((j=t.summary)==null?void 0:j.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((J=t.provider)==null?void 0:J.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?o`<div class="command-tag-row">
                          ${t.truth_notes.map(Q=>o`<span class="command-tag">${Q}</span>`)}
                        </div>`:null}
                    <${Zd} swarm=${t} />
                  `:o`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?o`<div class="command-card-stack">
                ${t.checklist.map(Q=>o`<${$h} item=${Q} />`)}
              </div>`:o`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?o`<div class="command-card-stack">
                ${t.workers.map(Q=>o`<${hh} worker=${Q} />`)}
              </div>`:o`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${t!=null&&t.provider?o`
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
                ${t.provider.detail?o`<div class="command-card-sub">${t.provider.detail}</div>`:null}
                ${t.provider.timeline.length>0?o`<div class="command-trace-stack">
                      ${t.provider.timeline.slice(-12).map(Q=>o`
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
                    </div>`:o`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:o`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?o`<div class="command-card-stack">
                ${t.blockers.map(Q=>o`<${su} blocker=${Q} />`)}
              </div>`:o`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?o`<div class="command-trace-stack">
                ${t.recent_messages.map(Q=>o`
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
              </div>`:o`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${O} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?o`<div class="command-trace-stack">
                ${t.recent_trace_events.map(Q=>o`<${ur} event=${Q} />`)}
              </div>`:o`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function Vt(t,e=260){return t.length<=e?t:`${t.slice(0,e-1)}…`}function Ze(t){if(!t)return 0;const e=Date.parse(t);return Number.isNaN(e)?0:e}function bh(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function kh(t){const e=typeof t.timestamp=="string"?t.timestamp:typeof t.created_at=="string"?t.created_at:typeof t.at=="string"?t.at:null,n=typeof t.title=="string"?t.title:typeof t.kind=="string"?t.kind:typeof t.event=="string"?t.event:"세션 이벤트",s=typeof t.detail=="string"?t.detail:typeof t.summary=="string"?t.summary:Zn(t);return{timestamp:e,title:n,detail:Vt(s,220)}}function xh(t){return t==="swarm"?"스웜 실시간":"세션 요약"}function Sh(t){switch(t){case"current":return"현재 과업 일치";case"drift":return"과업 드리프트";case"claim":return"착수 흔적 있음";case"no-claim":return"착수 흔적 없음";case"done":return"완료 흔적 있음";case"no-done":return"완료 흔적 없음";case"final":return"최종 보고 있음";case"no-final":return"최종 보고 없음";case"turn":return"턴 기록 있음";case"silent":return"턴 기록 없음";case"noted":return"노트 기록 있음";default:return t.startsWith("empty:")?`빈 노트 ${t.slice(6)}회`:t.startsWith("turns:")?`턴 ${t.slice(6)}회`:t}}function Ch(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"할당 없음",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}초`:t.heartbeat_fresh?"정상":"정보 없음",detail:[t.bound_task_status??null,t.detachment_member?"분견대 소속":null,t.squad_member?"분대 소속":null].filter(Boolean).join(" · ")||"스웜 실시간 카드",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function Ah(t,e){const n=t.actor??t.spawn_role??`워커-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"워커",a=t.lane_id??t.capsule_mode??t.control_domain??"세션",i=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"세션 레인",heartbeat:t.last_turn_ts_iso?tt(t.last_turn_ts_iso):"정보 없음",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?kn(t.routing_confidence):null].filter(Boolean).join(" · ")||"세션 요약 카드",markers:i,note:t.routing_reason??null}}function Th(t){var e;return{key:`agent:${t.name}`,name:t.name,role:t.agent_type??"agent",source:"agent",status:Ot(t.status),tone:E(ce(t.status)),task:t.current_task??"대기 중",signal:tt(t.last_seen),detail:[t.model??null,((e=t.capabilities)==null?void 0:e.slice(0,2).join(", "))||null].filter(Boolean).join(" · ")||"글로벌 agent roster",chips:[t.context_ratio!=null?`ctx ${Math.round(t.context_ratio*100)}%`:"ctx n/a",t.status],note:t.personalityHint??null}}function Ih(t){var n,s,a;const e=t.status==="offline"||t.status==="inactive"?"bad":t.status==="active"||t.status==="healthy"?"ok":"warn";return{key:`keeper:${t.name}`,name:t.name,role:t.runtime_class??"keeper",source:"keeper",status:Ot(t.status),tone:e,task:((n=t.active_goal_ids)==null?void 0:n[0])??t.last_proactive_reason??((s=t.agent)==null?void 0:s.current_task)??"standby",signal:t.last_heartbeat?tt(t.last_heartbeat):bh(t.last_turn_ago_s),detail:[t.autonomy_level??null,t.active_model??t.primary_model??t.model??null,t.keepalive_running?"keepalive on":null].filter(Boolean).join(" · ")||"글로벌 keeper roster",chips:[t.context_ratio!=null?`ctx ${Math.round(t.context_ratio*100)}%`:"ctx n/a",t.latest_tool_call_count!=null?`tools ${t.latest_tool_call_count}`:"tools n/a"],note:((a=t.diagnostic)==null?void 0:a.summary)??t.last_proactive_preview??t.recent_output_preview??null}}function Rh(t){return{key:`resident:${t.keeper_name??"judge"}`,name:t.keeper_name??"resident-judge",role:"resident judge",source:"resident",status:oo(t),tone:Gd(t),task:t.judge_online?"live guidance":"standby",signal:t.generated_at?tt(t.generated_at):"정보 없음",detail:[t.model_used??null,t.last_error?"error":null].filter(Boolean).join(" · ")||"resident runtime",chips:[t.enabled?"enabled":"disabled",t.judge_online?"online":"offline"],note:t.last_error??null}}function Mh(t){return E(t.severity)}function Eh({swarmMessages:t,traceEvents:e,chainOverlay:n,linkedAutoresearch:s,selectedSession:a,activeRecommendedActions:i,attentionItems:l}){const c=[];for(const d of t.slice(0,8))c.push({key:`message:${d.seq}`,title:d.from,detail:Vt(d.content,280),meta:`메시지 · seq ${d.seq}`,source:"swarm",tone:"ok",timestamp:d.timestamp,sortTs:Ze(d.timestamp)});for(const d of e.slice(0,8))c.push({key:`trace:${d.event_id}`,title:d.event_type,detail:Vt(Zn(d.detail),280),meta:[d.actor??null,d.source??null].filter(Boolean).join(" · ")||"trace",source:"trace",tone:d.event_type.includes("error")||d.event_type.includes("fail")?"bad":"warn",timestamp:d.timestamp,sortTs:Ze(d.timestamp)});if(n!=null&&n.history&&c.push({key:`chain:${n.operation.operation_id}:${n.history.event}`,title:`Chain · ${n.history.event}`,detail:Vt(so(n.history),260),meta:n.history.chain_id??n.operation.operation_id,source:"chain",tone:n.history.event.includes("error")||n.history.event.includes("fail")?"bad":"warn",timestamp:n.history.timestamp,sortTs:Ze(n.history.timestamp)}),s){const d=[s.last_decision??null,s.target_file?`target ${s.target_file}`:null,s.error??null].filter(Boolean);c.push({key:`autoresearch:${s.loop_id??(a==null?void 0:a.session_id)??"session"}`,title:`Autoresearch · ${s.status??"unknown"}`,detail:Vt(d.join(" · ")||"linked autoresearch context",260),meta:[s.loop_id?`loop ${s.loop_id}`:null,s.current_cycle!=null?`cycle ${s.current_cycle}`:null,s.best_score!=null?`best ${s.best_score}`:null].filter(Boolean).join(" · ")||"linked autoresearch",source:"autoresearch",tone:s.error?"bad":s.status==="running"?"warn":"ok",timestamp:null,sortTs:0})}for(const d of i.slice(0,4))c.push({key:`recommendation:${d.action_type}:${d.target_type}:${d.target_id??"session"}`,title:`${d.action_type} · ${d.target_type}`,detail:Vt(d.reason,240),meta:d.target_id??"operator recommendation",source:"recommendation",tone:Mh(d),timestamp:null,sortTs:0});for(const d of l.slice(0,4))c.push({key:`attention:${d.kind}:${d.target_id??"session"}`,title:`${d.kind} · ${d.target_type}`,detail:Vt(d.summary,240),meta:d.target_id??"attention",source:"attention",tone:E(d.severity),timestamp:null,sortTs:0});for(const[d,p]of((a==null?void 0:a.recent_events)??[]).slice(0,4).entries()){const v=kh(p);c.push({key:`session:${(a==null?void 0:a.session_id)??"unknown"}:${d}`,title:v.title,detail:v.detail,meta:(a==null?void 0:a.session_id)??"session",source:"session",tone:"warn",timestamp:v.timestamp,sortTs:Ze(v.timestamp)})}return c.sort((d,p)=>p.sortTs-d.sortTs||d.title.localeCompare(p.title)).slice(0,14)}function Lh({worker:t}){return o`
    <article class="command-card compact warroom-worker-card ${E(ce(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${E(ce(t.status))}">${Ot(t.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>출처</span><span>${xh(t.source)}</span>
        <span>과업</span><span>${t.task}</span>
        <span>최근 신호</span><span>${t.heartbeat}</span>
        <span>근거</span><span>${t.detail}</span>
      </div>
      <div class="command-tag-row">
        ${t.markers.map(e=>o`<span class="command-tag">${Sh(e)}</span>`)}
      </div>
      ${t.note?o`<div class="command-card-foot">${Vt(t.note,220)}</div>`:null}
    </article>
  `}function Ll({item:t}){return o`
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
      ${t.note?o`<div class="command-card-foot">${Vt(t.note,200)}</div>`:null}
    </article>
  `}function Ph({item:t}){return o`
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
  `}function Dt({label:t,surface:e,params:n={}}){return o`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){Ft(e),ot("command",{...ys(e),...n});return}ot("intervene")}}
    >
      ${t}
    </button>
  `}function zh({chainOverlay:t,linkedAutoresearch:e}){var n,s,a,i;return!t&&!e?o`<div class="command-guide-card"><p>이 세션에 붙은 chain/autoresearch 오버레이가 아직 없습니다.</p></div>`:o`
    <div class="warroom-orchestration-grid">
      ${t?o`
            <article class="command-card warroom-orchestration-card">
              <div class="command-card-head">
                <div>
                  <strong>Chain Orchestration</strong>
                  <div class="command-card-sub">${t.operation.operation_id}</div>
                </div>
                <span class="command-chip ${E(ce(t.operation.status))}">${Ot(t.operation.status)}</span>
              </div>
              <div class="command-card-grid">
                <span>Chain</span><span>${((n=t.runtime)==null?void 0:n.chain_id)??((s=t.preview_run)==null?void 0:s.chain_id)??"n/a"}</span>
                <span>Progress</span><span>${kn((a=t.runtime)==null?void 0:a.progress)}</span>
                <span>Elapsed</span><span>${Ve((i=t.runtime)==null?void 0:i.elapsed_sec)}</span>
                <span>최근 이벤트</span><span>${so(t.history)}</span>
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
                <${Dt} label="세션 개입" />
                ${e.operation_id?o`<${Dt}
                      label="작전 상세"
                      surface="operations"
                      params=${{operation_id:e.operation_id}}
                    />`:null}
              </div>
            </article>
          `:null}
    </div>
  `}function jh({wallboard:t=!1}){var xs,Ss,$r,hr,yr,br,kr,xr,Sr,Cr,Ar,Tr,Ir,Rr,Mr,Er,Lr,Pr,zr,jr,Nr,wr,Dr,Or,qr,Fr,Br,Kr,Ur,Wr,Hr,Gr;const e=bs(),n=Be.value,s=Lt.value,a=Wt.value,i=Xg(),l=n!=null&&n.operation?((xs=fs.value)==null?void 0:xs.operations.find(F=>{var xe;return F.operation.operation_id===((xe=n.operation)==null?void 0:xe.operation_id)}))??null:null,c=(i==null?void 0:i.linked_autoresearch)??null,d=Yg(),p=(n==null?void 0:n.workers)??[],v=(a==null?void 0:a.worker_cards)??[],_=d&&p.length>0?p.map(Ch):v.map(Ah),f=Gt.value.filter(F=>F.status==="active"||F.status==="busy"||F.status==="listening"||F.status==="idle"),h=ae.value.filter(F=>F.status!=="offline"||F.keepalive_running||F.last_heartbeat).sort((F,xe)=>Ze(xe.last_heartbeat)-Ze(F.last_heartbeat)),C=d,b=((Ss=e==null?void 0:e.decisions.summary)==null?void 0:Ss.pending)??0,x=(s==null?void 0:s.pending_confirms)??[],y=d?(n==null?void 0:n.blockers)??[]:[],$=(a==null?void 0:a.recommended_actions)??[],R=($r=a==null?void 0:a.active_recommended_actions)!=null&&$r.length?a.active_recommended_actions:$,T=a==null?void 0:a.active_summary,P=(a==null?void 0:a.active_guidance_layer)??"fallback",G=(a==null?void 0:a.resident_judge_runtime)??(s==null?void 0:s.resident_judge_runtime),L=(a==null?void 0:a.attention_items)??[],V=((hr=n==null?void 0:n.recent_messages[0])==null?void 0:hr.timestamp)??null,X=((yr=n==null?void 0:n.recent_trace_events[0])==null?void 0:yr.timestamp)??null,rt=d?V??X??null:null,U=i==null?void 0:i.summary,I=(d?(br=n==null?void 0:n.summary)==null?void 0:br.expected_workers:void 0)??(typeof(U==null?void 0:U.planned_worker_count)=="number"?U.planned_worker_count:void 0)??(a==null?void 0:a.worker_cards.length)??0,A=(d?(kr=n==null?void 0:n.summary)==null?void 0:kr.joined_workers:void 0)??(typeof(U==null?void 0:U.active_agent_count)=="number"?U.active_agent_count:void 0)??_.length,j=y.length>0||b>0||x.length>0?"warn":C||i?"ok":"warn",J=d?((xr=e==null?void 0:e.swarm_status)==null?void 0:xr.lanes.filter(F=>F.present))??[]:[],Q=((Cr=(Sr=e==null?void 0:e.swarm_status)==null?void 0:Sr.narrative)==null?void 0:Cr.lane_id)??((Tr=(Ar=e==null?void 0:e.swarm_status)==null?void 0:Ar.recommended_next_action)==null?void 0:Tr.lane_id)??((Ir=J[0])==null?void 0:Ir.lane_id)??null,it=Q?J.find(F=>F.lane_id===Q)??null:J[0]??null,W=[...G?[Rh(G)]:[],...f.slice(0,t?8:5).map(Th),...h.slice(0,t?8:5).map(Ih)],Pt=W.filter(F=>F.source==="agent"),ke=W.filter(F=>F.source==="keeper"||F.source==="resident"),xn=Eh({swarmMessages:(n==null?void 0:n.recent_messages)??[],traceEvents:(n==null?void 0:n.recent_trace_events)??[],chainOverlay:l,linkedAutoresearch:c,selectedSession:i,activeRecommendedActions:R,attentionItems:L}),ks=((Rr=n==null?void 0:n.operation)==null?void 0:Rr.objective)??((Er=(Mr=e==null?void 0:e.swarm_status)==null?void 0:Mr.narrative)==null?void 0:Er.active_work)??(i==null?void 0:i.session_id)??"가동 중인 워룸",lo=[(T==null?void 0:T.summary)??null,((Pr=(Lr=e==null?void 0:e.swarm_status)==null?void 0:Lr.narrative)==null?void 0:Pr.state)??null,((jr=(zr=e==null?void 0:e.swarm_status)==null?void 0:zr.narrative)==null?void 0:jr.active_work)??null,it?`${it.label} · ${it.current_step}`:null].filter(Boolean).join(" · ")||"실제 실행, 메시지, 트레이스, 상주 판단을 한 장에서 읽는 wallboard입니다.",[co,uo]=mn(typeof document<"u"&&!!document.fullscreenElement);nt(()=>{_t()},[]),nt(()=>{i!=null&&i.session_id&&$e(i.session_id)},[i==null?void 0:i.session_id,s,(Nr=n==null?void 0:n.detachment)==null?void 0:Nr.session_id]),nt(()=>{if(!t)return;const F=()=>{uo(!!document.fullscreenElement)};return document.addEventListener("fullscreenchange",F),F(),()=>{document.removeEventListener("fullscreenchange",F)}},[t]);const po=()=>{var F,xe,Jr;if(!(typeof document>"u")){if(document.fullscreenElement){(F=document.exitFullscreen)==null||F.call(document);return}(Jr=(xe=document.documentElement).requestFullscreen)==null||Jr.call(xe)}},mo=()=>{_t(),Zt(),we(),i!=null&&i.session_id&&$e(i.session_id)};return!C&&!i?Ca.value||Gn.value?o`<div class="empty-state">실시간 워룸 불러오는 중…</div>`:o`
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
    `:o`
    <div class="command-section-stack ${t?"wallboard":""}">
      <section class="command-warroom-strip ${E(j)} ${t?"wallboard":""}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">${t?"War Room Wallboard":"실시간 워룸"}</span>
            <strong>${ks}</strong>
            <div class="command-card-sub">
              ${d?((wr=n==null?void 0:n.operation)==null?void 0:wr.operation_id)??"작전 정보 없음":"세션 기준값"}
              ${i!=null&&i.session_id?` · 세션 ${i.session_id}`:""}
              ${d&&((Dr=n==null?void 0:n.detachment)!=null&&Dr.detachment_id)?` · 분견대 ${n.detachment.detachment_id}`:""}
              ${it?` · 대표 레인 ${it.label}`:""}
            </div>
            <div class="command-warroom-summary">${lo}</div>
            ${T!=null&&T.summary?o`<div class="command-warroom-guidance ${wa(P)}">
                  <strong>${cr(P)}</strong>
                  <span>${T.summary}</span>
                </div>`:null}
          </div>
          <div class="command-warroom-hero-actions">
            <button class="control-btn ghost" onClick=${mo}>새로고침</button>
            ${t?o`
                  <button class="control-btn ghost" onClick=${po}>
                    ${co?"전체 화면 해제":"전체 화면"}
                  </button>
                  <button
                    class="control-btn ghost"
                    onClick=${()=>{var F;document.fullscreenElement&&((F=document.exitFullscreen)==null||F.call(document)),Ft("warroom"),ot("command",ys("warroom"))}}
                  >
                    표준 보기
                  </button>
                `:null}
            <${Dt}
              label="스웜 상세"
              surface="swarm"
              params=${{...d&&((Or=n==null?void 0:n.operation)!=null&&Or.operation_id)?{operation_id:n.operation.operation_id}:{},...d&&(n!=null&&n.run_id)?{run_id:n.run_id}:{}}}
            />
            ${l?o`<${Dt}
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
            <small>${d?((qr=n==null?void 0:n.summary)==null?void 0:qr.completed_workers)??0:0} 완료 · ${_.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>런타임</span>
            <strong>${d?(Fr=n==null?void 0:n.provider)!=null&&Fr.runtime_blocker?"막힘":(Br=n==null?void 0:n.provider)!=null&&Br.provider_reachable?"준비됨":i?Ot(i.status):"확인 필요":i?Ot(i.status):"확인 필요"}</strong>
            <small>${d?`설정 ${((Kr=n==null?void 0:n.provider)==null?void 0:Kr.configured_capacity)??"n/a"} · 실제 ${((Ur=n==null?void 0:n.provider)==null?void 0:Ur.actual_slots)??((Wr=n==null?void 0:n.provider)==null?void 0:Wr.total_slots)??0} · hot ${((Hr=n==null?void 0:n.summary)==null?void 0:Hr.peak_hot_slots)??((Gr=n==null?void 0:n.provider)==null?void 0:Gr.peak_active_slots)??0}`:`세션 워커 ${(a==null?void 0:a.worker_cards.length)??0}`}</small>
          </div>
          <div class="monitor-stat-card ${E(y.length>0||b>0?"warn":"ok")}">
            <span>압력</span>
            <strong>${y.length+b+x.length}</strong>
            <small>막힘 ${y.length} · 승인 ${b} · 확인 ${x.length}</small>
          </div>
          <div class="monitor-stat-card ${E(wa(P))}">
            <span>상주 판정기</span>
            <strong>${oo(G)}</strong>
            <small>${dr(T)}${G!=null&&G.model_used?` · ${G.model_used}`:""}</small>
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
            ${J.length>0?o`
                  <${nu} lanes=${J} />
                  <${eu} lanes=${J} />
                `:i?o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${i.session_id}</strong>
                        <span class="command-chip ${E(ce(i.status))}">${Ot(i.status)}</span>
                      </div>
                      <p>스웜 실시간 증거는 아직 약합니다. 이 카드는 세션 요약과 워커 기록을 기준으로 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${i.progress_pct!=null?`${i.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${Ve(i.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${Ve(i.remaining_sec)}</span>
                      </div>
                    </article>
                  `:o`<div class="empty-state">보이는 레인이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">오케스트레이션</div>
              <${O} panelId="command.chains" compact=${!0} />
            </div>
            <${zh} chainOverlay=${l} linkedAutoresearch=${c} />
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">워커 현황</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${_.length>0?o`<div class="command-card-stack">
                  ${_.map(F=>o`<${Lh} worker=${F} />`)}
                </div>`:o`<div class="empty-state">활성 워커 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">상황 피드</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${xn.length>0?o`<div class="command-trace-stack">
                  ${xn.map(F=>o`<${Ph} item=${F} />`)}
                </div>`:o`<div class="empty-state">메시지, chain, autoresearch, attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">트레이스 흐름</div>
              <${O} panelId="command.trace" compact=${!0} />
            </div>
            ${n&&n.recent_trace_events.length>0?o`<div class="command-trace-stack">
                  ${n.recent_trace_events.map(F=>o`<${ur} event=${F} />`)}
                </div>`:o`<div class="empty-state">실행 범위 트레이스 이벤트가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Agents</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${Pt.length>0?o`<div class="warroom-presence-grid">
                  ${Pt.map(F=>o`<${Ll} item=${F} />`)}
                </div>`:o`<div class="empty-state">가시적인 active agent가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Keepers</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${ke.length>0?o`<div class="warroom-presence-grid">
                  ${ke.map(F=>o`<${Ll} item=${F} />`)}
                </div>`:o`<div class="empty-state">가시적인 keeper/runtime 카드가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">압력</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${d&&n?o`<${Zd} swarm=${n} />`:null}
              ${y.length>0?y.map(F=>o`<${su} blocker=${F} />`):o`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${b>0?o`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>승인 대기</strong>
                        <span class="command-chip warn">${b}</span>
                      </div>
                      <p>엄격 액션이 묶여 있습니다. 실제 승인 처리는 제어 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${x.length>0?o`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>확인 대기</strong>
                        <span class="command-chip warn">${x.length}</span>
                      </div>
                      <p>운영자 미리보기가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${x.slice(0,3).map(F=>o`<span class="command-tag">${F.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
              ${it?o`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${it.label}</strong>
                          <div class="command-card-sub">${it.kind} · ${it.phase}</div>
                        </div>
                        <span class="command-chip ${E(ce(it.motion_state))}">${Ot(it.motion_state)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>현재 단계</span><span>${it.current_step}</span>
                        <span>이동 사유</span><span>${it.movement_reason}</span>
                        <span>막힘 수</span><span>${it.blockers.length}</span>
                        <span>최근 이동</span><span>${tt(it.last_movement_at)}</span>
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
                        <span class="command-chip ${E(ce(n.detachment.status))}">${Ot(n.detachment.status??"active")}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>리더</span><span>${n.detachment.leader_id??"미지정"}</span>
                        <span>편성</span><span>${n.detachment.roster.length}</span>
                        <span>세션</span><span>${n.detachment.session_id??"연결 없음"}</span>
                        <span>하트비트</span><span>${Nd(n.detachment.heartbeat_deadline)}</span>
                      </div>
                    </article>
                  `:i?o`
                      <article class="command-card compact">
                        <div class="command-card-head">
                          <div>
                            <strong>${i.session_id}</strong>
                            <div class="command-card-sub">현재 세션 기준</div>
                          </div>
                          <span class="command-chip ${E(ce(i.status))}">${Ot(i.status)}</span>
                        </div>
                        <div class="command-card-grid">
                          <span>진행률</span><span>${i.progress_pct!=null?`${i.progress_pct}%`:"정보 없음"}</span>
                          <span>경과</span><span>${Ve(i.elapsed_sec)}</span>
                          <span>남은 시간</span><span>${Ve(i.remaining_sec)}</span>
                          <span>완료 변화량</span><span>${i.done_delta_total??0}</span>
                        </div>
                      </article>
                    `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function Pl(t){switch((t??"").trim().toLowerCase()){case"active":return"가동 중";case"paused":return"일시정지";case"failed":return"실패";case"completed":case"done":return"완료";case"disconnected":return"끊김";case"preview":return"미리보기";case"captured":return"기록됨";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Nh({source:t}){const e=Ln(null),[n,s]=mn(null);return nt(()=>{let a=!1;const i=e.current;return i?(i.innerHTML="",s(null),(async()=>{try{const c=await Pg(),{svg:d}=await c.render(`command-chain-${Lg()}`,t);if(a||!e.current)return;e.current.innerHTML=d}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid 렌더링에 실패했습니다")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),o`
    <div class="command-chain-graph-shell">
      ${n?o`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function wh({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return o`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${_e(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?o`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?o`<span class="command-tag ${_e(s==null?void 0:s.status)}">${kn(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${so(t.history)}</div>
    </button>
  `}function Dh({item:t}){return o`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"알 수 없는 체인"}</strong>
        <span class="command-chip ${_e(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${tt(t.timestamp)}</div>
      <div class="command-card-sub">${so(t)}</div>
    </article>
  `}function Oh({node:t}){return o`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${_e(t.status)}">${t.status??"확인 필요"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"노드"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?o`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function qh({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,i=e.chain,l=(i==null?void 0:i.run_id)??null;return o`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${E(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${Pl(e.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>트레이스</span><span class="mono">${e.trace_id}</span>
        <span>자율성</span><span>${e.autonomy_level??"정보 없음"}</span>
        <span>예산 등급</span><span>${e.budget_class??"standard"}</span>
        <span>출처</span><span>${e.source??"managed"}</span>
        <span>최근 갱신</span><span>${tt(e.updated_at)}</span>
      </div>
      ${i?o`
            <div class="command-tag-row">
              <span class="command-tag">${i.kind}</span>
              <span class="command-tag ${_e(i.status)}">${Pl(i.status)}</span>
              ${i.chain_id?o`<span class="command-tag">${i.chain_id}</span>`:null}
              ${i.run_id?o`<span class="command-tag">실행 ${i.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?o`<div class="command-card-foot">체크포인트 ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Ft("swarm"),ot("command",{surface:"swarm",operation_id:e.operation_id,...l?{run_id:l}:{}})}}
        >
          스웜 실시간 보기
        </button>
        ${i?o`
              <button
                class="control-btn ghost"
                onClick=${()=>{Qi(e.operation_id),Ft("chains"),ot("command",{surface:"chains",operation:e.operation_id})}}
              >
                체인 열기
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?o`
              <button class="control-btn ghost" disabled=${ut(n)} onClick=${()=>ve(()=>nf(e.operation_id))}>
                ${ut(n)?"일시정지 중…":"일시정지"}
              </button>
              <button class="control-btn ghost" disabled=${ut(a)} onClick=${()=>ve(()=>af(e.operation_id))}>
                ${ut(a)?"회수 중…":"회수"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?o`
              <button class="control-btn ghost" disabled=${ut(s)} onClick=${()=>ve(()=>sf(e.operation_id))}>
                ${ut(s)?"재개 중…":"재개"}
              </button>
            `:null}
      </div>
    </article>
  `}function Fh({card:t}){var n;const e=t.detachment;return o`
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
        <span>하트비트</span><span>${Nd(e.heartbeat_deadline)}</span>
        <span>최근 갱신</span><span>${tt(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?o`<span class="command-tag ${Mg(e.heartbeat_deadline)}">
              기한 ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Bh(){const t=Jt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">작전</div>
          <${O} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?o`<div class="command-card-stack">
              ${t.operations.operations.map(e=>o`<${qh} card=${e} />`)}
            </div>`:o`<div class="empty-state">관리형 또는 투영된 작전이 없습니다.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">분견대</div>
          <${O} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>o`<${Fh} card=${e} />`)}
            </div>`:o`<div class="empty-state">투영된 분견대가 없습니다.</div>`}
      </section>
    </div>
  `}function Kh(){var c,d,p,v,_,f,h,C,b,x,y,$,R,T,P,G;const t=fs.value,e=(t==null?void 0:t.operations)??[],n=ln.value,s=e.find(L=>L.operation.operation_id===n)??e[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,i=((d=Yn.value)==null?void 0:d.run)??(s==null?void 0:s.preview_run)??null,l=!((p=Yn.value)!=null&&p.run)&&!!(s!=null&&s.preview_run);return nt(()=>{a?tf(a):Zv()},[a]),o`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${O} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${_e(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>native chain 연결</strong>
            <span class="command-chip ${_e(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"체인 요약은 MASC 프록시를 통해 집계됩니다."}</p>
          <div class="command-card-grid">
            <span>기준 URL</span><span>${(t==null?void 0:t.connection.base_url)??"정보 없음"}</span>
            <span>연결된 작전</span><span>${((v=t==null?void 0:t.summary)==null?void 0:v.linked_operations)??0}</span>
            <span>활성 체인</span><span>${((_=t==null?void 0:t.summary)==null?void 0:_.active_chains)??0}</span>
            <span>최근 실패</span><span>${((f=t==null?void 0:t.summary)==null?void 0:f.recent_failures)??0}</span>
            <span>마지막 이벤트</span><span>${tt((h=t==null?void 0:t.summary)==null?void 0:h.last_history_event_at)}</span>
          </div>
        </article>

        ${Ia.value?o`<div class="empty-state error">${Ia.value}</div>`:null}

        ${fi.value&&!t?o`<div class="empty-state">체인 오버레이 불러오는 중…</div>`:e.length>0?o`
                <div class="command-chain-list">
                  ${e.map(L=>o`
                    <${wh}
                      overlay=${L}
                      selected=${(s==null?void 0:s.operation.operation_id)===L.operation.operation_id}
                      onSelect=${()=>Qi(L.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(L=>o`<${Dh} item=${L} />`)}
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
                  <span class="command-chip ${_e((C=s.operation.chain)==null?void 0:C.status)}">
                    ${((b=s.operation.chain)==null?void 0:b.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>종류</span><span>${((x=s.operation.chain)==null?void 0:x.kind)??"chain_dsl"}</span>
                  <span>체인 ID</span><span>${((y=s.operation.chain)==null?void 0:y.chain_id)??"goal-driven"}</span>
                  <span>실행 ID</span><span>${a??"아직 구체화되지 않음"}</span>
                  <span>진행률</span><span>${kn(($=s.runtime)==null?void 0:$.progress)}</span>
                  <span>경과</span><span>${Ve((R=s.runtime)==null?void 0:R.elapsed_sec)}</span>
                  <span>최근 갱신</span><span>${tt(((T=s.operation.chain)==null?void 0:T.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(P=s.operation.chain)!=null&&P.goal?o`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?o`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid 그래프</strong>
                        <span class="command-chip">${((G=s.operation.chain)==null?void 0:G.chain_id)??"graph"}</span>
                      </div>
                      <${Nh} source=${s.mermaid} />
                    </div>
                  `:o`<div class="empty-state">기록된 Mermaid 그래프가 아직 없습니다.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>실행 상세</strong>
                  <span class="command-chip ${(i==null?void 0:i.success)===!1?"bad":"ok"}">
                    ${i?i.success===!1?"실패":l?"미리보기":"기록됨":"대기 중"}
                  </span>
                </div>
                ${Ra.value?o`<div class="empty-state">실행 상세 불러오는 중…</div>`:Vn.value?o`<div class="empty-state error">${Vn.value}</div>`:i&&i.nodes.length>0?o`
                          <div class="command-card-grid">
                            <span>체인</span><span>${i.chain_id}</span>
                            <span>실행</span><span>${i.run_id??"미리보기만 있음"}</span>
                            <span>지속시간</span><span>${i.duration_ms!=null?`${i.duration_ms}ms`:"정보 없음"}</span>
                            <span>노드</span><span>${i.nodes.length}</span>
                          </div>
                          ${l?o`<div class="command-card-foot">run-store에 기록되기 전, 설계된 체인으로 만든 미리보기입니다.</div>`:null}
                          <div class="command-card-stack">
                            ${i.nodes.map(L=>o`<${Oh} node=${L} />`)}
                          </div>
                        `:o`<div class="empty-state">이 작전의 run-store 상세는 아직 없습니다.</div>`}
              </div>
            `:o`<div class="empty-state">그래프와 실행 상세를 보려면 체인 기반 작전을 고르세요.</div>`}
      </section>
    </div>
  `}function Uh(t){switch((t??"").trim().toLowerCase()){case"pending":return"대기 중";case"approved":return"승인됨";case"denied":return"거부됨";case"executed":return"실행됨";case"active":return"가동 중";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Wh({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return o`
    <article class="command-card ${E(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${E(t.status)}">${Uh(t.status??"pending")}</span>
      </div>
      <div class="command-card-grid">
        <span>결정 ID</span><span>${t.decision_id}</span>
        <span>요청자</span><span>${t.requested_by??"알 수 없음"}</span>
        <span>출처</span><span>${t.source??"managed"}</span>
        <span>트레이스</span><span class="mono">${t.trace_id}</span>
        <span>생성 시각</span><span>${tt(t.created_at)}</span>
        <span>이유</span><span>${t.reason??"정보 없음"}</span>
      </div>
      ${t.status==="pending"&&!s?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${ut(e)} onClick=${()=>ve(()=>rf(t.decision_id))}>
                ${ut(e)?"승인 중…":"승인"}
              </button>
              <button class="control-btn ghost" disabled=${ut(n)} onClick=${()=>ve(()=>lf(t.decision_id))}>
                ${ut(n)?"거부 중…":"거부"}
              </button>
            </div>
          `:null}
      ${s?o`<div class="command-card-foot">레거시 operator 승인입니다. 실제 실행은 operator control에서 처리합니다.</div>`:null}
    </article>
  `}function Hh({row:t}){var c,d,p;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((c=e.policy)!=null&&c.frozen),i=!!((d=e.policy)!=null&&d.kill_switch),l=Math.round((t.utilization??0)*100);return o`
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
        <span>자율성</span><span>${((p=e.policy)==null?void 0:p.autonomy_level)??"정보 없음"}</span>
        <span>동결</span><span>${a?"예":"아니오"}</span>
        <span>킬 스위치</span><span>${i?"켜짐":"꺼짐"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${ut(n)} onClick=${()=>ve(()=>cf(e.unit_id,!a))}>
          ${ut(n)?"적용 중…":a?"동결 해제":"동결"}
        </button>
        <button class="control-btn ghost" disabled=${ut(s)} onClick=${()=>ve(()=>df(e.unit_id,!i))}>
          ${ut(s)?"적용 중…":i?"킬 스위치 해제":"킬 스위치 켜기"}
        </button>
      </div>
    </article>
  `}function Gh(){const t=Jt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${O} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>o`<${Wh} decision=${e} />`)}
            </div>`:o`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">유닛 제어</div>
          <${O} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>o`<${Hh} row=${e} />`)}
            </div>`:o`<div class="empty-state">제어할 용량 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function Jh(){return o`
    <div class="command-surface-tabs grouped">
      ${jg.map(t=>o`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${wd.filter(e=>e.group===t.id).map(e=>o`
                <button
                  class="command-surface-tab ${Z.value===e.id?"active":""}"
                  onClick=${()=>{Ft(e.id),ot("command",ys(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function Yh({wallboard:t=!1}){if(Z.value==="warroom")return o`<${jh} wallboard=${t} />`;if(Z.value==="summary")return o`<${x$} />`;if(Z.value==="orchestra")return o`<${D$} />`;if(Z.value==="swarm")return o`<${yh} />`;if(!Jt.value)return o`<${S$} />`;switch(Z.value){case"chains":return o`<${Kh} />`;case"topology":return o`<${ah} />`;case"alerts":return o`<${oh} />`;case"trace":return o`<${ih} />`;case"control":return o`<${Gh} />`;case"operations":default:return o`<${Bh} />`}}function Vh(){const t=Z.value==="warroom"&&D.value.params.presentation==="wallboard";return nt(()=>{Ye(),we(),ef(),Zt(),ze()},[]),nt(()=>{if(D.value.tab!=="command")return;const e=D.value.params.surface,n=D.value.params.operation,s=gs(D.value);if(bl(e))Ft(e);else if(s){const a=yd(s);bl(a)&&Ft(a)}else e||Ft("warroom");n&&Qi(n),(e==="swarm"||e==="warroom"||e==="orchestra"||Z.value==="warroom"||Z.value==="orchestra")&&Zt(),(e==="orchestra"||Z.value==="orchestra")&&ze(),(e==="warroom"||Z.value==="warroom")&&_t()},[D.value.tab,D.value.params.surface,D.value.params.operation,D.value.params.operation_id,D.value.params.run_id,D.value.params.source,D.value.params.action_type,D.value.params.target_type,D.value.params.target_id,D.value.params.focus_kind]),nt(()=>{let e=null;const n=()=>{e||(e=window.setTimeout(()=>{e=null,Ye(),we(),(Z.value==="swarm"||Z.value==="warroom"||Z.value==="orchestra")&&Zt(),Z.value==="orchestra"&&ze(),Z.value==="warroom"&&_t()},250))},s=new EventSource(qg()),a=wg.map(i=>{const l=()=>n();return s.addEventListener(i,l),{type:i,handler:l}});return s.onerror=()=>{n()},()=>{a.forEach(({type:i,handler:l})=>{s.removeEventListener(i,l)}),s.close(),e&&window.clearTimeout(e)}},[]),nt(()=>{const e=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const n=Z.value;n!=="swarm"&&n!=="warroom"&&n!=="orchestra"||(Ye(),Zt(),n==="orchestra"&&ze(),n==="warroom"&&_t())},5e3);return()=>{window.clearInterval(e)}},[]),o`
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
              onClick=${()=>{ve(()=>of())}}
              disabled=${ut("dispatch:tick")}
            >
              ${ut("dispatch:tick")?"정리 중...":"Tick 실행"}
            </button>
            <button
              class="control-btn ghost"
              onClick=${()=>{Le(),Ye(),we(),Zt(),Z.value==="warroom"&&_t()}}
              disabled=${ha.value}
            >
              ${ha.value?"새로고침 중...":"새로고침"}
            </button>
            <button
              class="control-btn ghost"
              onClick=${()=>{Ft("warroom"),ot("command",{...ys("warroom"),presentation:"wallboard"})}}
            >
              Wallboard
            </button>
          </div>
        </div>
      `}

      ${ba.value?o`<div class="empty-state error">${ba.value}</div>`:null}
      ${xa.value?o`<div class="empty-state error">${xa.value}</div>`:null}
      ${t?null:o`<${xt} surfaceId="command" />`}
      ${t?null:o`<${to} />`}
      ${t?null:o`<${$$} />`}
      ${t||Z.value==="warroom"?null:o`<${h$} />`}
      ${t?null:o`<${Jh} />`}
      <${Yh} wallboard=${t} />
    </section>
  `}function Xh(){var x,y;const t=Lt.value,e=Hi.value,n=(t==null?void 0:t.room)??{},s=(t==null?void 0:t.pending_confirms)??[],a=t==null?void 0:t.pending_confirm_summary,i=a?a.confirm_required_actions:((t==null?void 0:t.available_actions)??[]).filter($=>$.confirm_required),l=((x=a==null?void 0:a.actor_filter)==null?void 0:x.trim())||null,c=(a==null?void 0:a.hidden_count)??0,d=(a==null?void 0:a.hidden_actors)??[],p=(t==null?void 0:t.recent_messages)??[],v=(e==null?void 0:e.recommended_actions)??[],_=(y=e==null?void 0:e.active_recommended_actions)!=null&&y.length?e.active_recommended_actions:v,f=e==null?void 0:e.active_summary,h=(e==null?void 0:e.resident_judge_runtime)??(t==null?void 0:t.resident_judge_runtime),C=(e==null?void 0:e.active_guidance_layer)??"fallback",b=p.slice(0,5);return o`
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
          <div class="ops-stat ${Gd(h)}">
            <span>Resident Judge</span>
            <strong>${oo(h)}</strong>
          </div>
        </div>

        <label class="control-label" for="ops-broadcast">Room 방송</label>
        <div class="control-row">
          <input
            id="ops-broadcast"
            class="control-input"
            type="text"
            placeholder="@agent 또는 room 전체 공지"
            value=${dn.value}
            onInput=${$=>{dn.value=$.target.value}}
            onKeyDown=${$=>{$.key==="Enter"&&Ml()}}
            disabled=${at.value}
          />
          <button class="control-btn" onClick=${()=>{Ml()}} disabled=${at.value||dn.value.trim()===""}>
            보내기
          </button>
        </div>

        <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
        <div class="control-row ops-split-row">
          <input
            id="ops-pause-reason"
            class="control-input"
            type="text"
            value=${za.value}
            onInput=${$=>{za.value=$.target.value}}
            disabled=${at.value}
          />
          <button class="control-btn ghost" onClick=${()=>{X$()}} disabled=${at.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{Yd()}} disabled=${at.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${un.value}
          onInput=${$=>{un.value=$.target.value}}
          disabled=${at.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${ts.value}
          onInput=${$=>{ts.value=$.target.value}}
          disabled=${at.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${es.value}
            onChange=${$=>{es.value=$.target.value}}
            disabled=${at.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{Q$()}} disabled=${at.value||un.value.trim()===""}>
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
        <article class="ops-guidance-card ${wa(C)}">
          <div class="ops-guidance-head">
            <strong>${cr(C)}</strong>
            <span>${(h==null?void 0:h.keeper_name)??(e==null?void 0:e.judgment_owner)??"judge 없음"}</span>
          </div>
          <div class="ops-guidance-body">
            ${(f==null?void 0:f.summary)??"현재 active guidance 요약이 없습니다. fallback queue만 표시합니다."}
          </div>
          <div class="ops-guidance-meta">
            <span>authoritative ${e!=null&&e.authoritative_judgment_available?"yes":"no"}</span>
            <span>${dr(f)}</span>
            ${h!=null&&h.model_used?o`<span>${h.model_used}</span>`:null}
          </div>
        </article>
        ${Jn.value&&!e?o`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:_.length>0?o`
          <div class="ops-log-list">
            ${_.map($=>o`
              <article key=${`${$.action_type}:${$.target_type}:${$.target_id??"room"}`} class="ops-log-entry ${$.severity}">
                <div class="ops-log-head">
                  <strong>${De($.action_type)}</strong>
                  <span>${pn($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                  <span>${Da($.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${$.reason}</div>
                ${$.suggested_payload?o`
                  <div class="ops-confirmation-actions">
                    <button class="control-btn ghost" onClick=${()=>{Y$($)}} disabled=${at.value}>
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
                  <strong>${De($.action_type)}</strong>
                  <span>${pn($.target_type)}</span>
                  <span>${Da($.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${$.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}
        ${s.length>0?o`
          <div class="ops-confirmation-list">
            ${s.map($=>o`
              <article key=${$.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${De($.action_type)}</strong>
                  <span>${pn($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                  <span>${$.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${$.preview?o`<pre class="ops-code-block compact">${Na($.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{El($.confirm_token)}} disabled=${at.value}>
                    실행
                  </button>
                  <button class="control-btn ghost" onClick=${()=>{El($.confirm_token,"deny")}} disabled=${at.value}>
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
        ${b.length>0?o`
          <div class="ops-feed-list">
            ${b.map($=>o`
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
  `}const Ue=g(""),Co=g(!1),js=g(null);function Qh(){var y;const t=Lt.value,e=Wt.value,n=(t==null?void 0:t.sessions)??[],s=((t==null?void 0:t.available_actions)??[]).filter($=>$.target_type==="team_session"),a=n.find($=>$.session_id===vn.value)??n[0]??null,i=e==null?void 0:e.active_summary,l=(e==null?void 0:e.active_guidance_layer)??"fallback",c=(e==null?void 0:e.resident_judge_runtime)??(t==null?void 0:t.resident_judge_runtime),d=(a==null?void 0:a.linked_autoresearch)??null,p=at.value||Co.value,v=(y=e==null?void 0:e.active_recommended_actions)!=null&&y.length?e.active_recommended_actions:(e==null?void 0:e.recommended_actions)??[],_=async()=>{await _t(),a!=null&&a.session_id&&await $e(a.session_id)},f=async $=>{Co.value=!0,js.value=null;try{await $(),await _()}catch(R){js.value=R instanceof Error?R.message:"Autoresearch action failed"}finally{Co.value=!1}},h=async()=>{d!=null&&d.loop_id&&await f(()=>Qu(d.loop_id))},C=async()=>{if(!(d!=null&&d.loop_id)||!Ue.value.trim())return;const $=Ue.value.trim();await f(()=>Zu(d.loop_id,$)),Ue.value=""},b=async()=>{d!=null&&d.loop_id&&await f(()=>tp(d.loop_id))},x=async()=>{d!=null&&d.loop_id&&await f(()=>ep(d.loop_id,"dashboard stop request"))};return o`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${O} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?o`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map($=>{var R;return o`
            <button
              key=${$.session_id}
              class="ops-entity-card ${(a==null?void 0:a.session_id)===$.session_id?"active":""}"
              onClick=${()=>{vn.value=$.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${$.session_id}</strong>
                <span class="status-badge ${$.status??"idle"}">${Qe($.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round($.progress_pct??0)}%</span>
                <span>${$.done_delta_total??0}건 완료</span>
                <span>${(R=$.team_health)!=null&&R.status?Qe(String($.team_health.status)):"상태 확인 필요"}</span>
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
          <article class="ops-guidance-card ${wa(l)}">
            <div class="ops-guidance-head">
              <strong>${cr(l)}</strong>
              <span>${oo(c)}</span>
            </div>
            <div class="ops-guidance-body">
              ${(i==null?void 0:i.summary)??"현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다."}
            </div>
            <div class="ops-guidance-meta">
              <span>authoritative ${e.authoritative_judgment_available?"yes":"no"}</span>
              <span>${dr(i)}</span>
              ${c!=null&&c.model_used?o`<span>${c.model_used}</span>`:null}
            </div>
          </article>
          ${v.length>0?o`
            <div class="ops-log-list">
              ${v.map($=>o`
                <article key=${`${$.action_type}:${$.target_type}:${$.target_id??"session"}`} class="ops-log-entry ${$.severity}">
                  <div class="ops-log-head">
                    <strong>${De($.action_type)}</strong>
                    <span>${pn($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                  </div>
                  <div class="ops-log-body">${$.reason}</div>
                </article>
              `)}
            </div>
          `:null}
          <div class="ops-log-list">
            ${e.attention_items.length>0?e.attention_items.map($=>o`
              <article key=${`${$.kind}:${$.target_id??"session"}`} class="ops-log-entry ${$.severity}">
                <div class="ops-log-head">
                  <strong>${$.kind}</strong>
                  <span>${pn($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${$.summary}</div>
              </article>
            `):o`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${e.worker_cards.length>0?e.worker_cards.map($=>o`
              <article key=${`${$.actor??$.spawn_role??"worker"}:${$.spawn_agent??$.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${$.actor??$.spawn_role??"worker"}</strong>
                  <span>${Qe($.status)}</span>
                  <span>${$.spawn_agent??$.runtime_pool??"runtime 확인 필요"}</span>
                </div>
                <div class="ops-log-body">
                  ${$.worker_class??"worker"}${$.lane_id?` · ${$.lane_id}`:""}${$.routing_reason?` · ${$.routing_reason}`:""}
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
            ${s.map($=>o`
              <article key=${$.action_type} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${De($.action_type)}</strong>
                  <span>${Da($.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${$.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}

        ${a?o`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${a.session_id}</div>
            <div class="ops-detail-meta">
              <span>상태: ${Qe(a.status)}</span>
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
              <pre class="ops-code-block compact">${Na(a.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:o`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        ${d!=null&&d.loop_id?o`
          <label class="control-label" for="ops-autoresearch-hypothesis">Autoresearch 제어</label>
          <div class="control-row ops-split-row">
            <button class="control-btn ghost" onClick=${()=>{h()}} disabled=${p}>
              상태 새로고침
            </button>
            <button class="control-btn" onClick=${()=>{b()}} disabled=${p}>
              1 cycle 실행
            </button>
            <button class="control-btn ghost" onClick=${()=>{x()}} disabled=${p}>
              loop 중지
            </button>
          </div>
          <textarea
            id="ops-autoresearch-hypothesis"
            class="control-textarea"
            rows=${2}
            placeholder="다음 cycle에 넣을 hypothesis"
            value=${Ue.value}
            onInput=${$=>{Ue.value=$.target.value}}
            disabled=${p}
          ></textarea>
          <div class="control-row ops-split-row">
            <button class="control-btn" onClick=${()=>{C()}} disabled=${p||!Ue.value.trim()}>
              hypothesis 주입
            </button>
            <span class="ops-context-note">canonical control은 MCP tool이고, 이 화면은 그 상태를 읽고 이어서 제어합니다.</span>
          </div>
          ${js.value?o`<div class="ops-empty">${js.value}</div>`:null}
        `:null}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${kt.value}
            onChange=${$=>{kt.value=$.target.value}}
            disabled=${p||!a}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
            <option value="worker_spawn_batch">worker 교체</option>
          </select>
          <button class="control-btn" onClick=${()=>{Z$()}} disabled=${p||!a}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${W$(kt.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${ns.value}
          onInput=${$=>{ns.value=$.target.value}}
          disabled=${p||!a}
        ></textarea>

        ${kt.value==="task"?o`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${ss.value}
            onInput=${$=>{ss.value=$.target.value}}
            disabled=${p||!a}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${as.value}
            onInput=${$=>{as.value=$.target.value}}
            disabled=${p||!a}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${os.value}
            onChange=${$=>{os.value=$.target.value}}
            disabled=${p||!a}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
        `:kt.value==="worker_spawn_batch"?o`
          <textarea
            class="control-textarea"
            rows=${6}
            placeholder='spawn_batch JSON, 예: [{"spawn_agent":"llama","spawn_prompt":"...", "spawn_role":"replacement"}]'
            value=${is.value}
            onInput=${$=>{is.value=$.target.value}}
            disabled=${p||!a}
          ></textarea>
        `:null}

        <div class="control-row ops-split-row">
          <input
            class="control-input"
            type="text"
            value=${ja.value}
            onInput=${$=>{ja.value=$.target.value}}
            disabled=${p||!a}
          />
          <button class="control-btn ghost" onClick=${()=>{th()}} disabled=${p||!a}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function Zh(){var i;const t=Lt.value,e=(t==null?void 0:t.keepers)??[],n=(t==null?void 0:t.persistent_agents)??[],s=(t==null?void 0:t.available_actions)??[],a=e.find(l=>l.name===yi.value)??e[0]??null;return o`
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
              onClick=${()=>{yi.value=l.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${l.name}</strong>
                <span class="status-badge ${l.status??"idle"}">${Qe(l.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${l.model??"model 확인 필요"}</span>
                <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${Il(l.last_turn_ago_s)}</span>
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
                    <span class="status-badge ${l.status??"idle"}">${Qe(l.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>persistent</span>
                    <span>${l.model??"model 확인 필요"}</span>
                    <span>${Il(l.last_turn_ago_s)}</span>
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
          <${zd}
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
                    <strong>${De(l.action_type)}</strong>
                    <span>${pn(l.target_type)}</span>
                    <span>${Da(l.confirm_required)}</span>
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
          ${va.value.length===0?o`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:va.value.map(l=>o`
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
  `}function ty(){var T,P,G;const t=Lt.value,e=D.value.tab==="intervene"?gs(D.value):null,n=Hi.value,s=(t==null?void 0:t.room)??{},a=(t==null?void 0:t.sessions)??[],i=(t==null?void 0:t.keepers)??[],l=(t==null?void 0:t.pending_confirms)??[],c=t==null?void 0:t.pending_confirm_summary,d=(c==null?void 0:c.visible_count)??l.length,p=(c==null?void 0:c.total_count)??l.length,v=(c==null?void 0:c.hidden_count)??0,_=((T=c==null?void 0:c.actor_filter)==null?void 0:T.trim())||null,f=a.find(L=>L.session_id===vn.value)??a[0]??null,h=(n==null?void 0:n.attention_items)??[],C=h.filter(K$),b=h.filter(U$),x=a.filter(L=>B$(L)!=="ok"),y=i.filter(L=>So(L)!=="ok"),$=V$(e,a,i);nt(()=>{Oe()},[]),nt(()=>{if(D.value.tab!=="intervene"){zs.value=null;return}if(!e){zs.value=null;return}zs.value!==e.id&&(zs.value=e.id,J$(e))},[D.value.tab,D.value.params.source,D.value.params.action_type,D.value.params.target_type,D.value.params.target_id,D.value.params.focus_kind,e==null?void 0:e.id]),nt(()=>{const L=(f==null?void 0:f.session_id)??null;$e(L)},[f==null?void 0:f.session_id]);const R=[{key:"room",label:"방 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:v>0?`${d}/${p}`:d,detail:d>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":v>0&&_?`현재 개입 ID(${_}) 기준으로는 비어 있고, 다른 개입 ID 대기 ${v}건이 있습니다`:"지금 막혀 있는 확인 대기는 없습니다",tone:p>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:C.length>0?C.length:a.length,detail:C.length>0?((P=C[0])==null?void 0:P.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 팀 세션이 없습니다":"세션 쪽 긴급 주의 신호는 현재 없습니다",tone:C.length>0?Rl(C):a.length===0?"warn":x.some(L=>fn(L.status)==="paused")?"bad":x.length>0?"warn":"ok"},{key:"keeper",label:"키퍼 압력",value:b.length>0?b.length:y.length,detail:b.length>0?((G=b[0])==null?void 0:G.summary)??"직접 메시지나 상태 점검이 필요한 키퍼가 있습니다":y.length>0?"오래됐거나 오프라인이거나 텔레메트리가 비는 키퍼가 보입니다":"지금은 키퍼 쪽이 비교적 안정적입니다",tone:b.length>0?Rl(b):y.some(L=>So(L)==="bad")?"bad":y.length>0?"warn":"ok"}];return o`
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
            value=${ao.value}
            onInput=${L=>F$(L.target.value)}
          />
            <button
              class="control-btn ghost"
              onClick=${()=>{Le(),_t(),Oe(),$e((f==null?void 0:f.session_id)??null)}}
            disabled=${Gn.value||at.value}
          >
            ${Gn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${ge.value?o`<section class="ops-banner error">${ge.value}</section>`:null}
      ${_n.value?o`<section class="ops-banner error">${_n.value}</section>`:null}
      <${to} />
      ${e?o`
        <section class="ops-banner ${$?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${eo(e.action_type)}</span>
            <span>${nr(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?o`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${$?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const L=[];if((d>0||v>0)&&L.push({label:v>0?`확인 대기 ${d}/${p}건 확인`:`확인 대기 ${d}건 처리`,desc:v>0&&_?`현재 개입 ID(${_}) 기준으로 보이는 대기열을 먼저 확인합니다`:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:d>0?"bad":"warn",onClick:()=>{const V=document.querySelector(".ops-pending-section");V==null||V.scrollIntoView({behavior:"smooth"})}}),s.paused&&L.push({label:"방 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void Yd()}),y.length>0){const V=y.filter(X=>So(X)==="bad");L.push({label:V.length>0?`오프라인 키퍼 ${V.length}개`:`점검이 필요한 키퍼 ${y.length}개`,desc:V.length>0?"메시지를 보내거나 상태를 확인하세요":"오래됐거나 텔레메트리가 비어 있습니다",tone:V.length>0?"bad":"warn",onClick:()=>{const X=document.querySelector(".ops-keeper-section");X==null||X.scrollIntoView({behavior:"smooth"})}})}return L.length===0?null:o`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${L.slice(0,3).map(V=>o`
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
          ${R.map(L=>o`
            <div key=${L.key} class="ops-priority-card ${L.tone}">
              <span class="ops-priority-label">${L.label}</span>
              <strong>${L.value}</strong>
              <div class="ops-priority-detail">${L.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${Xh} />
        <${Qh} />
        <${Zh} />
      </div>
    </section>
  `}function ey({text:t}){if(!t)return null;const e=ny(t);return o`<div class="markdown-content">${e}</div>`}function ny(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),d=[];for(s++;s<e.length&&!e[s].startsWith(l);)d.push(e[s]),s++;s++,n.push(o`<pre><code class=${c?`language-${c}`:""}>${d.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<e.length&&!e[s].includes("</think>");)l.push(e[s]),s++;if(s<e.length){const p=e[s].replace("</think>","").trim();p&&l.push(p),s++}const d=l.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Ao(d)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<e.length&&e[s].startsWith("> ");)l.push(e[s].slice(2)),s++;n.push(o`<blockquote>${Ao(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const l=e[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;i.push(l),s++}i.length>0&&n.push(o`<p>${Ao(i.join(`
`))}</p>`)}return n}function Ao(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const au=[{id:"recent",label:"최신순"},{id:"hot",label:"인기순"},{id:"trending",label:"급상승"},{id:"updated",label:"최근 갱신"},{id:"discussed",label:"토론 많은 순"}],ea=g(null),na=g([]),gn=g(!1),Ne=g(null),Dn=g(""),On=g(!1),tn=g(!0),pr=20,We=g(pr);function sy(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const ay=g(sy());function oy(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"미리보기 없음"}function zl(t){return t.updated_at!==t.created_at}function iy(t){if(t.post_kind)return t.post_kind==="automation";const e=(t.hearth??"").toLowerCase();return t.visibility!=="internal"||!t.expires_at||!e?!1:!!(e.startsWith("mdal")||e.includes("harness"))}function ry(t){return t==="lodge-system"||t==="team-session"}function rs(t){return t.post_kind?t.post_kind:ry(t.author)?"system":iy(t)?"automation":"human"}function ou(t){const e=[],n=[];let s=0;return t.forEach(a=>{const i=rs(a);if(!(i==="system"&&Me.value)){if(i==="automation"&&tn.value){s+=1;return}if(i==="human"){e.push(a);return}n.push(a)}}),{human:e,operations:n,hiddenAutomation:s}}function ly(t){if(!t.expires_at)return null;const e=Date.parse(t.expires_at);return Number.isFinite(e)?e<=Date.now()?o`<span class="board-meta-chip">만료됨</span>`:o`<span class="board-meta-chip">만료까지 <${et} timestamp=${t.expires_at} /></span>`:null}async function mr(t){Ne.value=t,ea.value=null,na.value=[],gn.value=!0;try{const e=await Np(t);if(Ne.value!==t)return;ea.value={id:e.id,author:e.author,title:e.title,body:e.body,content:e.content,meta:e.meta,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,post_kind:e.post_kind,flair:e.flair,hearth:e.hearth,visibility:e.visibility,expires_at:e.expires_at,hearth_count:e.hearth_count},na.value=e.comments??[]}catch{Ne.value===t&&(ea.value=null,na.value=[])}finally{Ne.value===t&&(gn.value=!1)}}async function jl(t){const e=Dn.value.trim();if(e){On.value=!0;try{await wp(t,ay.value,e),Dn.value="",N("댓글을 등록했습니다","success"),await mr(t),pe()}catch{N("댓글 등록에 실패했습니다","error")}finally{On.value=!1}}}function cy(){const t=Wn.value,e=tn.value?"자동화 글 숨김":"자동화 글 표시 중";return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${au.map(n=>o`
          <button
            class="board-sort-btn ${t===n.id?"active":""}"
            onClick=${()=>{Wn.value=n.id,We.value=pr,pe()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${tn.value?"is-active":""}"
          onClick=${()=>{tn.value=!tn.value}}
        >
          ${e}
        </button>
        <button
          class="control-btn ghost ${Me.value?"is-active":""}"
          onClick=${()=>{Me.value=!Me.value,pe()}}
        >
          ${Me.value?"시스템 글 숨김":"시스템 글 표시 중"}
        </button>
        <button class="control-btn ghost" onClick=${pe} disabled=${Hn.value}>
          ${Hn.value?"새로고침 중...":"새로고침"}
        </button>
      </div>
    </div>
  `}function To(){var s;const t=((s=au.find(a=>a.id===Wn.value))==null?void 0:s.label)??Wn.value,e=ou(Xa.value),n=e.human.length+e.operations.length;return o`
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
        <strong>${tn.value?`자동화 ${e.hiddenAutomation}건 숨김`:"분리된 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">시스템 글 정책</span>
        <strong>${Me.value?"시스템 글 숨김":"시스템 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">최근 갱신</span>
        <strong>${li.value?o`<${et} timestamp=${li.value} />`:"아직 불러오지 않음"}</strong>
      </div>
    </div>
  `}function Nl({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await _c(t.id,n),pe()}catch{N("투표에 실패했습니다","error")}};return o`
    <div class="board-post" onClick=${()=>Iu(t.id)}>
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
                ${zl(t)?o`<span class="board-meta-chip">수정됨</span>`:null}
                ${rs(t)!=="human"?o`<span class="board-meta-chip">${rs(t)}</span>`:null}
                ${t.hearth?o`<span class="board-meta-chip">${t.hearth}</span>`:null}
                ${t.visibility?o`<span class="board-meta-chip">${t.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>작성자 ${t.author}</span>
            <span><${et} timestamp=${t.created_at} /></span>
            ${zl(t)?o`<span>수정 <${et} timestamp=${t.updated_at} /></span>`:null}
            <span>댓글 ${t.comment_count}</span>
            <span>투표 ${t.votes??0}</span>
          </div>
        </div>
        <div class="post-snippet">${oy(t.body)}</div>
      </div>
    </div>
  `}function dy({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">아직 댓글이 없습니다</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${et} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function uy({postId:t}){return o`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="댓글 추가..."
        value=${Dn.value}
        onInput=${e=>{Dn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&jl(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${On.value}
      />
      <button
        onClick=${()=>jl(t)}
        disabled=${On.value||Dn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${On.value?"...":"등록"}
      </button>
    </div>
  `}function py({post:t}){Ne.value!==t.id&&!gn.value&&mr(t.id);const e=async n=>{try{await _c(t.id,n),pe()}catch{N("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>ot("memory")}>← 메모리로 돌아가기</button>
      <${M} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${ey} text=${t.body} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${et} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          ${t.hearth||t.visibility||t.expires_at?o`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${t.hearth?o`<span class="board-meta-chip">${t.hearth}</span>`:null}
                  ${t.visibility?o`<span class="board-meta-chip">${t.visibility}</span>`:null}
                  ${rs(t)!=="human"?o`<span class="board-meta-chip">${rs(t)}</span>`:null}
                  ${ly(t)}
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

      <${M} title="댓글" semanticId="memory.feed">
        ${gn.value?o`<div class="loading-indicator">댓글 불러오는 중...</div>`:o`<${dy} comments=${na.value} />`}
        <${uy} postId=${t.id} />
      <//>
    </div>
  `}function my(){const t=ou(Xa.value),e=[...t.human,...t.operations],n=D.value.params.post??null,s=n?e.find(a=>a.id===n)??(Ne.value===n?ea.value:null):null;return n&&!s&&Ne.value!==n&&!gn.value&&mr(n),n?s?o`
          <${xt} surfaceId="memory" />
          <${To} />
          <${py} post=${s} />
        `:o`
          <div>
            <${xt} surfaceId="memory" />
            <${To} />
            <button class="back-btn" onClick=${()=>ot("memory")}>← 메모리로 돌아가기</button>
            ${gn.value?o`<div class="loading-indicator">글 불러오는 중...</div>`:o`<div class="empty-state">글을 찾지 못했습니다</div>`}
          </div>
        `:o`
    <div>
      <${xt} surfaceId="memory" />
      <${To} />
      <${cy} />
      ${Hn.value?o`<div class="loading-indicator">메모리 피드 불러오는 중...</div>`:e.length===0?o`<div class="empty-state">지금은 남아 있는 메모리 글이 없습니다</div>`:o`
              <${M} title="사람이 쓴 글" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.human.slice(0,We.value).map(a=>o`<${Nl} key=${a.id} post=${a} />`)}
                </div>
                ${t.human.length>We.value?o`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{We.value=We.value+pr}}
                    >
                      더 보기 (${t.human.length-We.value}개 남음)
                    </button>
                  </div>
                `:null}
              <//>
              ${t.operations.length>0?o`
                    <${M} title="자동화 · 시스템" class="section" semanticId="memory.feed">
                      <div class="board-post-list">
                        ${t.operations.map(a=>o`<${Nl} key=${a.id} post=${a} />`)}
                      </div>
                    <//>
                  `:null}
            `}
    </div>
  `}const Ie=g(null),Xt=g(null),Qt=g(null);function ls(t){return t==="bad"||t==="critical"||t==="offline"?"bad":t==="warn"||t==="paused"||t==="blocked"||t==="interrupted"?"warn":"ok"}function cs(t){switch((t??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":return"주의";case"bad":case"critical":return"위험";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function _y(t){return t==="session"?"세션":"작전"}function vy(t){return t?ae.value.find(e=>e.name===t||e.agent_name===t)??null:null}function fy(t){switch(t){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function gy(t){switch(t){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function $y(t){switch(t){case"acted":return"행동";case"passed":return"통과";case"skipped":return"건너뜀";case"failed":return"실패";default:return t}}function hy(t){switch(t){case"post":return"post";case"comment":return"comment";case"vote":return"vote";case"none":case null:case void 0:return"none";default:return t}}function wl(t){if(!t)return;const e=yf({targetType:t.target_type,targetId:t.target_id,focusKind:t.focus_kind,operationId:t.operation_id??null,commandSurface:t.command_surface??null,sourceLabel:"실행 진단",summary:t.label});$d(e),ot(t.surface,t.surface==="intervene"?hd(e):bd(e))}function Tn({label:t,value:e,color:n,caption:s}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?o`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function _r({intervene:t,command:e}){return o`
    <div class="control-row">
      ${t?o`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),wl(t)}}
            >
              ${t.label}
            </button>
          `:null}
      ${e?o`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),wl(e)}}
            >
              ${e.label}
            </button>
          `:null}
    </div>
  `}function yy({item:t,selected:e}){return o`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{Ie.value=e?null:t.id,Xt.value=null,Qt.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.kind==="session"?t.target_id:t.linked_session_id??t.target_id}</div>
          <div class="mission-card-title">${t.summary}</div>
        </div>
        <span class="command-chip ${ls(t.severity)}">${cs(t.status??t.severity)}</span>
      </div>
      <div class="mission-card-meta">
        <span>${_y(t.kind)}</span>
        ${t.linked_operation_id?o`<span>연결 작전 · ${t.linked_operation_id}</span>`:null}
        ${t.last_seen_at?o`<span><${et} timestamp=${t.last_seen_at} /></span>`:null}
      </div>
      <${_r} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function by({brief:t,selected:e}){return o`
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
        <span class="command-chip ${ls(t.health??t.status)}">${cs(t.status)}</span>
      </div>
      <div class="mission-card-meta">
        <span>건강도 · ${cs(t.health??"ok")}</span>
        ${t.linked_operation_id?o`<span>연결 작전 · ${t.linked_operation_id}</span>`:null}
        ${t.last_activity_at?o`<span><${et} timestamp=${t.last_activity_at} /></span>`:null}
      </div>
      ${t.runtime_blocker?o`<div class="mission-card-detail">${t.runtime_blocker}</div>`:t.last_activity_summary?o`<div class="mission-card-detail">${t.last_activity_summary}</div>`:null}
      ${t.worker_gap_summary?o`<div class="monitor-footnote">${t.worker_gap_summary}</div>`:null}
      <${_r} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function ky({brief:t,selected:e}){return o`
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
        <span class="command-chip ${ls(t.blocker_summary?"warn":t.status)}">${cs(t.status)}</span>
      </div>
      <div class="mission-card-meta">
        ${t.stage?o`<span>단계 · ${t.stage}</span>`:null}
        ${t.linked_session_id?o`<span>세션 · ${t.linked_session_id}</span>`:null}
        ${t.updated_at?o`<span><${et} timestamp=${t.updated_at} /></span>`:null}
      </div>
      ${t.blocker_summary?o`<div class="mission-card-detail">${t.blocker_summary}</div>`:null}
      ${t.next_tool?o`<div class="monitor-footnote">다음 도구 · ${t.next_tool}</div>`:null}
      <${_r} command=${t.command_handoff} />
    </button>
  `}function xy({tick:t}){return t?o`
    <div class="monitor-nested-card">
      <div class="stats-grid">
        <${Tn} label="checked" value=${t.checked??0} color="#22d3ee" />
        <${Tn} label="acted" value=${t.acted??0} color="#4ade80" />
        <${Tn} label="passed" value=${t.passed??0} color="#94a3b8" />
        <${Tn} label="skipped" value=${t.skipped??0} color="#fbbf24" />
        <${Tn} label="failed" value=${t.failed??0} color="#fb7185" />
      </div>
      <div class="monitor-meta">
        ${t.last_tick_at?o`<span>마지막 tick <${et} timestamp=${t.last_tick_at} /></span>`:o`<span>마지막 tick 없음</span>`}
        ${t.last_skip_reason?o`<span>대표 skip 이유 · ${t.last_skip_reason}</span>`:null}
      </div>
      ${t.activity_report?o`<div class="monitor-footnote">${t.activity_report}</div>`:null}
    </div>
  `:o`<div class="empty-state">최근 lodge tick 기록이 없습니다.</div>`}function Sy({row:t}){return o`
    <button
      class="monitor-row ${ls(t.outcome==="failed"?"bad":t.outcome==="skipped"?"warn":"ok")}"
      data-testid="execution.lodge-checkin-card"
      onClick=${()=>$s(t.agent_name)}
    >
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.agent_name}</span>
            ${t.worker_name?o`<span class="monitor-sub">worker · ${t.worker_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.reason??t.summary??"이유가 기록되지 않았습니다."}</div>
        </div>
        <span class="monitor-pill ${ls(t.outcome==="failed"?"bad":t.outcome==="skipped"?"warn":"ok")}">${$y(t.outcome)}</span>
      </div>
      <div class="monitor-meta">
        <span>trigger · ${t.trigger??"unknown"}</span>
        ${t.checked_at?o`<span><${et} timestamp=${t.checked_at} /></span>`:null}
        <span>action · ${hy(t.action_kind)}</span>
      </div>
      ${t.summary&&t.summary!==t.reason?o`<div class="monitor-focus">${t.summary}</div>`:null}
      ${t.failure_reason||t.decision_reason?o`<div class="monitor-footnote">
            ${t.failure_reason?`실패 이유: ${t.failure_reason}`:`판단 이유: ${t.decision_reason}`}
          </div>`:null}
    </button>
  `}function Dl({row:t,testId:e}){return o`
    <button class="monitor-row ${t.tone} state-${t.state}" data-testid=${e} onClick=${()=>$s(t.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.name}</span>
            ${t.korean_name?o`<span class="monitor-sub">${t.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${be} status=${t.status??"unknown"} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${fy(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.last_signal_at?o`<span>신호 <${et} timestamp=${t.last_signal_at} /></span>`:o`<span>최근 신호 없음</span>`}
        <span>${(t.active_task_count??0)>0?`활성 작업 ${t.active_task_count}개`:"활성 작업 없음"}</span>
        ${t.related_session_id?o`<span>세션 · ${t.related_session_id}</span>`:null}
        ${t.related_operation_id?o`<span>작전 · ${t.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${t.recent_output_preview&&t.recent_output_preview!==t.focus?o`<div class="monitor-footnote">최근 상세: ${t.recent_output_preview}</div>`:null}
    </button>
  `}function Cy({row:t}){const e=()=>{const a=vy(t.name);a&&jd(a)},n=Rd(t.name,t.agent_name),s={name:t.name,koreanName:t.korean_name??null,runtimeLabel:n,emoji:t.emoji??null,tone:t.tone,statusRaw:t.status??null,statusLabel:cs(t.status),stateClass:t.state,stateLabel:gy(t.state),contextRatio:t.context_ratio??null,note:t.note,focus:t.focus,lastActivityAt:t.last_signal_at??null,lastActivityFallback:"최근 활동 없음",relatedSessionId:t.related_session_id??null,continuity:t.continuity??null,lifecycle:t.lifecycle??null,summary:t.continuity_summary??t.recent_output_preview??null,recentInput:t.recent_input_preview??null,recentOutput:t.recent_output_preview??null,recentTools:t.recent_tool_names??[],allowedTools:t.allowed_tool_names??[],routeSummary:t.skill_route_summary??null,auditSource:t.tool_audit_source??null,auditAt:t.tool_audit_at??null,disclosureLabel:"연속성 상세"};return o`<${Td}
    variant="execution"
    model=${s}
    onClick=${e}
    testId="execution.continuity-card"
  />`}function Ay(){const t=bc.value,e=kc.value,n=xc.value,s=Sc.value,a=Cc.value,i=Ac.value,l=qi.value,c=Tc.value;Ie.value&&!t.some(y=>y.id===Ie.value)&&(Ie.value=null),Xt.value&&!e.some(y=>y.session_id===Xt.value)&&(Xt.value=null),Qt.value&&!n.some(y=>y.operation_id===Qt.value)&&(Qt.value=null);const d=Ie.value?t.find(y=>y.id===Ie.value)??null:null,p=Xt.value?Xt.value:d?d.kind==="session"?d.target_id:d.linked_session_id??null:null,v=Qt.value?Qt.value:d?d.kind==="operation"?d.target_id:d.linked_operation_id??null:null,_=p?e.filter(y=>y.session_id===p):v?e.filter(y=>y.linked_operation_id===v):e,f=v?n.filter(y=>y.operation_id===v):p?n.filter(y=>{var $;return y.linked_session_id===p||y.operation_id===(($=_[0])==null?void 0:$.linked_operation_id)}):n,h=p||v?s.filter(y=>(p?y.related_session_id===p:!1)||(v?y.related_operation_id===v:!1)):s,C=p?l.filter(y=>y.related_session_id===p||y.tone!=="ok"):l,b=p?i.filter(y=>_.some($=>$.member_names.includes(y.agent_name))):i,x=p||v?c.filter(y=>(p?y.related_session_id===p:!1)||(v?y.related_operation_id===v:!1)||y.tone!=="ok"):c;return o`
    <div class="agents-monitor">
      <${xt} surfaceId="execution" />
      <${to} />
      <${M}
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
          ${t.length===0?o`<div class="empty-state">지금은 막힌 실행이 없습니다.</div>`:t.map(y=>o`<${yy} key=${y.id} item=${y} selected=${Ie.value===y.id} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${M}
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
            ${_.length===0?o`<div class="empty-state">선택된 실행과 연결된 세션이 없습니다.</div>`:_.map(y=>o`<${by} key=${y.session_id} brief=${y} selected=${Xt.value===y.session_id} />`)}
          </div>
        <//>

        <${M}
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
            ${f.length===0?o`<div class="empty-state">선택된 실행과 연결된 작전이 없습니다.</div>`:f.map(y=>o`<${ky} key=${y.operation_id} brief=${y} selected=${Qt.value===y.operation_id} />`)}
          </div>
        <//>

        <${M}
          title="Lodge Check-ins"
          class="section"
          semanticId="execution.lodge"
          testId="execution.lodge-checkins"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Lodge Check-ins</h2>
            <p class="monitor-subheadline">최근 lodge tick에서 누가 무엇을 허용받았고, 실제로 어떻게 행동했는지 먼저 보여줍니다.</p>
          </div>
          <${xy} tick=${a} />
          <div class="monitor-list">
            ${b.length===0?o`<div class="empty-state">최근 lodge check-in 기록이 없습니다.</div>`:b.map(y=>o`<${Sy} key=${`${y.agent_name}-${y.checked_at??y.outcome}`} row=${y} />`)}
          </div>
        <//>

        <${M}
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
            ${h.length===0?o`<div class="empty-state">연결된 작업자가 없습니다.</div>`:h.map(y=>o`<${Dl} key=${y.name} row=${y} testId="execution.worker-card" />`)}
          </div>
        <//>

        <${M}
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
            ${C.length===0?o`<div class="empty-state">지금은 연속성 경고가 없습니다.</div>`:C.map(y=>o`<${Cy} key=${y.name} row=${y} />`)}
          </div>
        <//>

        <${M}
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
            ${x.length===0?o`<div class="empty-state">지금은 오프라인 작업자가 없습니다.</div>`:x.map(y=>o`<${Dl} key=${y.name} row=${y} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const bi=g(null),ki=g(null),qn=g(!1);async function Ol(){if(!qn.value){qn.value=!0,ki.value=null;try{bi.value=await gp()}catch(t){ki.value=t instanceof Error?t.message:String(t)}finally{qn.value=!1}}}function Ty(t){switch(t){case"essential":return"badge-essential";case"standard":return"badge-standard";default:return"badge-full"}}function Iy({items:t,maxCount:e}){return t.length===0?o`<p class="muted">No tool calls recorded yet.</p>`:o`
    <div class="tool-bar-chart">
      ${t.map(n=>{const s=e>0?n.call_count/e*100:0;return o`
          <div class="tool-bar-row" key=${n.name}>
            <span class="tool-bar-name">${n.name}</span>
            <span class="tool-bar-tier ${Ty(n.tier)}">${n.tier}</span>
            <div class="tool-bar-track">
              <div class="tool-bar-fill" style=${{width:`${s}%`}} />
            </div>
            <span class="tool-bar-count">${n.call_count}</span>
          </div>
        `})}
    </div>
  `}function Ry({dist:t}){const e=t.full,n=e>0?(t.essential/e*100).toFixed(1):"0",s=e>0?(t.standard/e*100).toFixed(1):"0",a=e-t.standard,i=e>0?(a/e*100).toFixed(1):"0";return o`
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
  `}function My(){const t=bi.value,e=qn.value,n=ki.value;return nt(()=>{!bi.value&&!qn.value&&Ol()},[]),o`
    <div class="tool-metrics">
      <div class="tool-metrics-header">
        <h3 class="tool-metrics-title">Tool Usage</h3>
        <button
          class="control-btn ghost"
          onClick=${()=>void Ol()}
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
            <${Ry} dist=${t.tier_distribution} />
          </div>
          <div class="tool-metrics-section">
            <h4>Top 20 Tools</h4>
            <${Iy}
              items=${t.top_20}
              maxCount=${t.top_20.length>0?t.top_20[0].call_count:0}
            />
          </div>
        </div>
      `:e?null:o`
        <p class="muted">Click Load to fetch tool usage statistics.</p>
      `}
    </div>
  `}const xi=g(null),Si=g(null),Fn=g(!1),In=g(""),Ns=g("all"),Io=g(!1),Ro=g(!1),Mo=g(!0),Eo=g(!0);async function ql(){if(!Fn.value){Fn.value=!0,Si.value=null;try{xi.value=await $p()}catch(t){Si.value=t instanceof Error?t.message:String(t)}finally{Fn.value=!1}}}function Ey(t,e){const n=e.trim().toLowerCase();return n?[t.name,t.description,t.category,t.required_permission??"",t.visibility,t.lifecycle,t.implementationStatus,t.tier,t.canonicalName??"",t.replacement??"",t.reason??"",...t.doc_refs,...t.prompt_hints].join(" ").toLowerCase().includes(n):!0}function ws(t,e="default"){return o`
    <span
      style=${{fontSize:"11px",color:e==="ok"?"#7dd3fc":e==="warn"?"#fbbf24":"#cbd5e1",background:e==="ok"?"rgba(14, 165, 233, 0.18)":e==="warn"?"rgba(245, 158, 11, 0.18)":"rgba(148, 163, 184, 0.16)",borderRadius:"999px",padding:"2px 8px"}}
    >
      ${t}
    </span>
  `}function Ly({item:t}){return o`
    <article class="tool-inventory-row">
      <div class="tool-inventory-head">
        <div>
          <div class="tool-inventory-name">${t.name}</div>
          <div class="tool-inventory-desc">${t.description}</div>
        </div>
        <div class="tool-inventory-badges">
          ${ws(t.tier,t.tier==="essential"?"ok":t.tier==="standard"?"warn":"default")}
          ${ws(t.visibility)}
          ${ws(t.lifecycle,t.lifecycle==="deprecated"?"warn":"default")}
          ${ws(t.implementationStatus)}
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
  `}function Py(){const t=xi.value,e=Fn.value,n=Si.value,s=(t==null?void 0:t.tool_inventory.tools)??[],a=(t==null?void 0:t.tool_usage)??null;nt(()=>{!xi.value&&!Fn.value&&ql()},[]),nt(()=>{var h;if(D.value.tab!=="tools")return;const f=(h=D.value.params.q)==null?void 0:h.trim();f&&f!==In.value&&(In.value=f)},[D.value.tab,D.value.params.q]);const i=Array.from(new Set(s.map(f=>f.category))).sort((f,h)=>f.localeCompare(h)),l=s.filter(f=>!(!Ey(f,In.value)||Ns.value!=="all"&&f.category!==Ns.value||Io.value&&!f.enabled_in_current_mode||Ro.value&&!f.direct_call_allowed||!Mo.value&&f.visibility==="hidden"||!Eo.value&&f.lifecycle==="deprecated")),c=s.length,d=s.filter(f=>f.enabled_in_current_mode).length,p=s.filter(f=>f.visibility==="hidden").length,v=s.filter(f=>f.lifecycle==="deprecated").length,_=s.filter(f=>f.direct_call_allowed).length;return o`
    <div>
      <${M} title="System Tool Inventory" class="section">
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
            <span class="stat-value">${v}</span>
            <span class="stat-label">Deprecated</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${_}</span>
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
            value=${In.value}
            onInput=${f=>{In.value=f.target.value}}
          />
          <select
            class="control-select"
            value=${Ns.value}
            onChange=${f=>{Ns.value=f.target.value}}
          >
            <option value="all">All categories</option>
            ${i.map(f=>o`<option value=${f}>${f}</option>`)}
          </select>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${Io.value}
              onChange=${f=>{Io.value=f.target.checked}}
            />
            <span>Enabled only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${Ro.value}
              onChange=${f=>{Ro.value=f.target.checked}}
            />
            <span>Direct-call only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${Mo.value}
              onChange=${f=>{Mo.value=f.target.checked}}
            />
            <span>Show hidden</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${Eo.value}
              onChange=${f=>{Eo.value=f.target.checked}}
            />
            <span>Show deprecated</span>
          </label>
          <button class="control-btn ghost" onClick=${()=>{ql()}} disabled=${e}>
            ${e?"Refreshing…":"Refresh inventory"}
          </button>
        </div>

        ${n?o`<div class="tool-metrics-error">${n}</div>`:null}

        <div class="tool-inventory-list">
          ${l.length>0?l.map(f=>o`<${Ly} key=${f.name} item=${f} />`):o`<div class="empty-state">No tools matched the current filters.</div>`}
        </div>
      <//>

      <${M} title="Tool Usage" class="section">
        ${a?o`
              <div class="tool-inventory-usage-hint">
                Registered ${a.registered_count} · Distinct called ${a.distinct_tools_called} · Never called ${a.never_called_count}
              </div>
            `:null}
        <${My} />
      <//>
    </div>
  `}const Oa=g("all"),qa=g("all"),Ci=g(new Set);function zy(t){const e=new Set(Ci.value);e.has(t)?e.delete(t):e.add(t),Ci.value=e}const iu=Et(()=>{let t=sn.value;return Oa.value!=="all"&&(t=t.filter(e=>e.horizon===Oa.value)),qa.value!=="all"&&(t=t.filter(e=>e.status===qa.value)),t}),jy=Et(()=>{const t={short:[],mid:[],long:[]};for(const e of iu.value){const n=t[e.horizon];n&&n.push(e)}return t}),Ny=Et(()=>{const t=Array.from(Rc.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function wy(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function vr(t){switch(t){case"short":return"단기";case"mid":return"중기";case"long":return"장기";default:return t}}function sa(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Dy(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Fl(t){return t.toFixed(4)}function Bl(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function Oy(t){switch(t){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function qy(t){switch(t){case"active":return"진행 중";case"completed":return"완료";case"paused":return"일시정지";default:return"전체"}}function Kl(t,e){return(t.priority??4)-(e.priority??4)}function Fy(t,e){const n=t.updated_at??t.created_at??"";return(e.updated_at??e.created_at??"").localeCompare(n)}function By(t,e){return t.length<=e?t:t.slice(0,e)+"..."}function Ky({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${sa(t.horizon)}">
            ${vr(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${wy(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${et} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${be} status=${t.status} />
        <div class="goal-updated">
          <${et} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Lo({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${M} title="${vr(t)} 목표 (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>o`<${Ky} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function Uy(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">범위</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Oa.value===t?"active":""}"
            onClick=${()=>{Oa.value=t}}
          >
            ${t==="all"?"전체":vr(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">상태</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${qa.value===t?"active":""}"
            onClick=${()=>{qa.value=t}}
          >
            ${qy(t)}
          </button>
        `)}
      </div>
    </div>
  `}function Wy(){const t=sn.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${sa("short")}">${s.short}</div>
        <div class="goal-summary-label">단기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${sa("mid")}">${s.mid}</div>
        <div class="goal-summary-label">중기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${sa("long")}">${s.long}</div>
        <div class="goal-summary-label">장기</div>
      </div>
    </div>
  `}function Hy({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length}개 도구: ${t.latest_tool_names.join(", ")}`:"아직 근거 없음";return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${be} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Fl(t.baseline_metric)}</span>
          <span>현재 ${Fl(t.current_metric)}</span>
          <span class=${Bl(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Bl(t)}
          </span>
          <span>Elapsed ${Dy(t.elapsed_seconds)}</span>
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
  `}function Po({task:t}){const e=t.priority??4,n=e<=1?"p1":e===2?"p2":e===3?"p3":"p4",s=Ci.value.has(t.id),a=!!t.description;return o`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${Oy(e)}</span>
        <div class="kanban-card-title">${t.title}</div>
      </div>
      ${a?o`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>zy(t.id)}
        >
          ${s?t.description:By(t.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${t.created_at?o`<${et} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Gy(){const{todo:t,inProgress:e,done:n}=Ec.value,s=[...t].sort(Kl),a=[...e].sort(Kl),i=[...n].sort(Fy);return o`
    <${M} title="태스크 백로그" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>할 일</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${s.length===0?o`<div class="empty-state" style="opacity: 0.5;">대기 중인 태스크가 없습니다</div>`:s.map(l=>o`<${Po} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>진행 중</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${a.length===0?o`<div class="empty-state" style="opacity: 0.5;">진행 중인 태스크가 없습니다</div>`:a.map(l=>o`<${Po} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>완료</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${i.length===0?o`<div class="empty-state" style="opacity: 0.5;">완료된 태스크가 없습니다</div>`:i.slice(0,20).map(l=>o`<${Po} key=${l.id} task=${l} />`)}
          ${i.length>20?o`<div class="empty-state" style="opacity: 0.5;">...외 ${i.length-20}개 더 있음</div>`:null}
        </div>
      </div>
    <//>
  `}function Jy(){const{todo:t,inProgress:e,done:n}=Ec.value,s=t.length+e.length+n.length,a=[...t,...e].filter(v=>(v.priority??4)<=2).length,i=jy.value,l=Ny.value,c=sn.value.length>0,d=l.length>0,p=Fi.value;return o`
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
          onClick=${()=>{Ui(),Dc()}}
          disabled=${Pn.value||zn.value}
        >
          ${Pn.value||zn.value?"새로고침 중...":"계획 데이터 새로고침"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${Gy} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          목표 파이프라인
          <span class="monitor-pill">${sn.value.length}</span>
        </summary>
        <div>
          ${c?o`
            <${Wy} />
            <${Uy} />
            ${Pn.value&&sn.value.length===0?o`<div class="loading-indicator">목표 불러오는 중...</div>`:iu.value.length===0?o`<div class="empty-state">현재 필터에 맞는 목표가 없습니다</div>`:o`
                    <${Lo} horizon="short" items=${i.short??[]} />
                    <${Lo} horizon="mid" items=${i.mid??[]} />
                    <${Lo} horizon="long" items=${i.long??[]} />
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
          ${zn.value&&l.length===0?o`<div class="loading-indicator">MDAL 루프 불러오는 중...</div>`:l.length===0&&(p==="error"||an.value)?o`<div class="empty-state">MDAL 스냅샷을 불러오지 못했습니다${an.value?`: ${an.value}`:""}. 백엔드 상태를 확인하세요.</div>`:l.length===0?o`<div class="empty-state">가동 중인 루프가 없습니다. <code>masc_mdal_start</code>로 시작할 수 있습니다.</div>`:o`
                  <div class="planning-loop-list">
                    ${l.map(v=>o`<${Hy} key=${v.loop_id} loop=${v} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const Fa=g(!1),Bn=g(!1),en=g(!1),he=g(""),Kn=g(""),Ai=g("open"),Bt=g(null),ds=g(null),Ba=g(null),Ka=g(null),Ti=g(!1);function us(t){return`${t.kind}:${t.id}`}function fr(){var n;const t=ds.value,e=((n=Bt.value)==null?void 0:n.items)??[];return t?e.find(s=>us(s)===t)??null:null}function Yy(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");return(e==null?void 0:e.trim())||"dashboard"}function Vy(t){const e=t.trim().toLowerCase();return e==="open"||e==="pending"}function ru(t){return!!(t.judgment_summary&&t.judgment_summary.trim())}function lu(t){switch(Ai.value){case"needs_quorum":return t.filter(e=>e.kind==="consensus"&&(e.votes??0)<(e.quorum??0));case"ready":return t.filter(e=>{var n;return(n=e.guardrail_state)==null?void 0:n.ready_to_execute});case"needs_approval":return t.filter(e=>{var n,s;return((n=e.guardrail_state)==null?void 0:n.requires_human_gate)||!!((s=e.guardrail_state)!=null&&s.pending_confirm)});case"judge_offline":return t.filter(e=>!ru(e));case"open":default:return t.filter(e=>Vy(e.status))}}function Xy(t){if(t==null)return"없음";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function io(t){const e=(t||"").toLowerCase();return e.includes("reject")||e.includes("deny")||e.includes("closed")||e.includes("cancel")?"negative":e.includes("approve")||e.includes("support")||e.includes("open")||e.includes("ready")?"positive":"neutral"}function Qy(t){return typeof t!="number"||Number.isNaN(t)?"확인 필요":`${Math.round(t*100)}%`}function Rn(t){return"resolved_tool"in t||"payload_preview"in t||"reason"in t}async function cu(t){if(Ba.value=null,Ka.value=null,!!t){Ti.value=!0,he.value="";try{t.kind==="debate"?Ba.value=await dm(t.id):Ka.value=await um(t.id)}catch(e){he.value=e instanceof Error?e.message:"거버넌스 상세를 불러오지 못했습니다"}finally{Ti.value=!1}}}async function Zy(t){ds.value=us(t),await cu(t)}async function $n(){var t;Fa.value=!0,he.value="";try{const e=await dp();Bt.value=e;const n=lu(e.items??[]),s=ds.value,a=n.find(i=>us(i)===s)??n[0]??((t=e.items)==null?void 0:t[0])??null;ds.value=a?us(a):null,await cu(a)}catch(e){he.value=e instanceof Error?e.message:"거버넌스 상태를 불러오지 못했습니다"}finally{Fa.value=!1}}S_($n);async function Ul(){const t=Kn.value.trim();if(t){Bn.value=!0;try{const e=await cm(t);Kn.value="",N(e!=null&&e.id?`토론을 시작했습니다: ${e.id}`:"토론을 시작했습니다","success"),await $n()}catch(e){const n=e instanceof Error?e.message:"토론 시작에 실패했습니다";he.value=n,N(n,"error")}finally{Bn.value=!1}}}async function Wl(t){var i,l;const e=fr(),n=(i=e==null?void 0:e.guardrail_state)==null?void 0:i.pending_confirm,s=n==null?void 0:n.confirm_token;if(!s)return;const a=((l=n==null?void 0:n.actor)==null?void 0:l.trim())||Yy();en.value=!0;try{await lc(a,s,t),N(t==="confirm"?"액션을 승인했습니다":"액션을 거부했습니다","success"),await $n()}catch(c){const d=c instanceof Error?c.message:"대기 중인 액션 처리에 실패했습니다";he.value=d,N(d,"error")}finally{en.value=!1}}function tb(){var n,s,a,i,l,c;const t=(n=Bt.value)==null?void 0:n.summary,e=(s=Bt.value)==null?void 0:s.judge;return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">열린 토론</span>
        <strong>${(t==null?void 0:t.debates_open)??((i=(a=Bt.value)==null?void 0:a.debates)==null?void 0:i.length)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">합의 세션</span>
        <strong>${(t==null?void 0:t.sessions_active)??((c=(l=Bt.value)==null?void 0:l.sessions)==null?void 0:c.length)??0}</strong>
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
  `}function eb(){return o`
    <${M} title="거버넌스 콘솔" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="토론 주제를 입력하세요..."
            value=${Kn.value}
            onInput=${t=>{Kn.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&Ul()}}
            disabled=${Bn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Ul}
            disabled=${Bn.value||Kn.value.trim()===""}
          >
            ${Bn.value?"시작 중...":"토론 시작"}
          </button>
          <button class="control-btn ghost" onClick=${$n} disabled=${Fa.value}>
            ${Fa.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
        <div class="governance-filter-row">
          ${[["open","열림"],["needs_quorum","정족수 부족"],["ready","준비됨"],["needs_approval","승인 필요"],["judge_offline","판정기 오프라인"]].map(([t,e])=>o`
            <button
              class="control-btn ${Ai.value===t?"is-active":"ghost"}"
              onClick=${async()=>{Ai.value=t,await $n()}}
            >
              ${e}
            </button>
          `)}
        </div>
        ${he.value?o`<div class="council-error">${he.value}</div>`:null}
      </div>
    <//>
  `}function nb(){var e;const t=lu(((e=Bt.value)==null?void 0:e.items)??[]);return o`
    <${M} title="의사결정 수신함" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${t.length===0?o`
              <div class="empty-state">
                지금 필터에 맞는 토론이나 합의 세션이 없습니다.
              </div>
            `:t.map(n=>{var a,i;const s=ds.value===us(n);return o`
                <button
                  class="council-row governance-decision-row ${s?"selected":""}"
                  onClick=${()=>Zy(n)}
                >
                  <div class="council-row-main">
                    <div class="governance-row-head">
                      <span class="governance-kind">${n.kind}</span>
                      <span class="council-topic">${n.topic}</span>
                    </div>
                    <div class="council-sub">
                      <span>${n.truth_summary||"사실 요약이 아직 없습니다"}</span>
                      ${n.last_activity_at?o`<span><${et} timestamp=${n.last_activity_at} /></span>`:null}
                    </div>
                    <div class="governance-chip-row">
                      ${(a=n.guardrail_state)!=null&&a.requires_human_gate?o`<span class="governance-chip warn">승인 필요</span>`:null}
                      ${(i=n.guardrail_state)!=null&&i.ready_to_execute?o`<span class="governance-chip ok">준비됨</span>`:null}
                      ${n.kind==="consensus"&&(n.votes??0)<(n.quorum??0)?o`<span class="governance-chip warn">정족수 부족</span>`:null}
                      ${ru(n)?null:o`<span class="governance-chip dim">판정기 오프라인</span>`}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${io(n.status)}">${n.status}</span>
                    ${n.kind==="consensus"?o`<span class="governance-vote-meter">${n.votes??0}/${n.quorum??0}</span>`:o`<span class="governance-vote-meter">${n.evidence_refs.length} refs</span>`}
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function sb({argument:t}){return o`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${io(t.position)}">${t.position}</span>
        <strong>${t.agent}</strong>
        ${t.created_at?o`<span><${et} timestamp=${t.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${t.content}</div>
      <div class="governance-chip-row">
        ${t.evidence.map(e=>o`<span class="governance-chip">${e}</span>`)}
        ${t.reply_to!=null?o`<span class="governance-chip">답글 #${t.reply_to}</span>`:null}
        ${t.mentions.map(e=>o`<span class="governance-chip">@${e}</span>`)}
        ${t.archetype?o`<span class="governance-chip dim">${t.archetype}</span>`:null}
      </div>
    </div>
  `}function ab({vote:t}){return o`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${io(t.decision)}">${t.decision}</span>
        <strong>${t.agent}</strong>
        ${t.timestamp?o`<span><${et} timestamp=${t.timestamp} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${t.reason||"기록된 이유가 없습니다."}</div>
      <div class="governance-chip-row">
        ${t.weight!=null?o`<span class="governance-chip">가중치 ${t.weight}</span>`:null}
        ${t.archetype?o`<span class="governance-chip dim">${t.archetype}</span>`:null}
      </div>
    </div>
  `}function ob(){const t=fr(),e=Ba.value,n=Ka.value;return o`
    <${M}
      title=${t?`${t.kind==="debate"?"토론":"합의"} 상세`:"의사결정 상세"}
      class="section"
      semanticId="governance.detail"
    >
      ${Ti.value?o`<div class="loading-indicator">거버넌스 상세 불러오는 중...</div>`:t?t.kind==="debate"&&e?o`
                <div class="governance-detail-head">
                  <div>
                    <h3>${e.debate.topic}</h3>
                    <div class="council-sub">
                      <span>${e.debate.id}</span>
                      <span>${e.debate.status}</span>
                      ${e.debate.created_at?o`<span><${et} timestamp=${e.debate.created_at} /></span>`:null}
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
                  ${e.arguments.length===0?o`<div class="empty-state">기록된 토론이 아직 없습니다.</div>`:e.arguments.map(s=>o`<${sb} key=${s.index} argument=${s} />`)}
                </div>
              `:t.kind==="consensus"&&n?o`
                  <div class="governance-detail-head">
                    <div>
                      <h3>${n.session.topic}</h3>
                      <div class="council-sub">
                        <span>${n.session.id}</span>
                        <span>${n.session.state}</span>
                      <span>시작자 ${n.session.initiator}</span>
                        ${n.session.created_at?o`<span><${et} timestamp=${n.session.created_at} /></span>`:null}
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
                    ${n.votes.length===0?o`<div class="empty-state">기록된 표결이 아직 없습니다.</div>`:n.votes.map(s=>o`<${ab} key=${s.agent+s.timestamp} vote=${s} />`)}
                  </div>
                `:o`<div class="empty-state">이 의사결정의 상세를 아직 읽을 수 없습니다.</div>`:o`<div class="empty-state">사실 계층과 판단을 보려면 의사결정 항목을 고르세요.</div>`}
    <//>
  `}function Hl({title:t,route:e}){if(!e)return null;const n=Rn(e)?e.resolved_tool:e.delegated_tool,s=Rn(e)?e.target_type:null,a=Rn(e)?e.target_id:null,i=Rn(e)?e.reason:null,l=Rn(e)?e.payload_preview:null;return o`
    <div class="governance-side-block">
      <h4>${t}</h4>
      <div class="council-sub">
        ${n?o`<span>도구 ${n}</span>`:null}
        ${"action_type"in e&&e.action_type?o`<span>액션 ${e.action_type}</span>`:null}
        ${"confirmation_state"in e&&e.confirmation_state?o`<span>${e.confirmation_state}</span>`:null}
        ${"created_at"in e&&e.created_at?o`<span><${et} timestamp=${e.created_at} /></span>`:null}
      </div>
      ${s?o`<div class="governance-side-line">대상 ${s}${a?`:${a}`:""}</div>`:null}
      ${i?o`<div class="governance-side-line">${i}</div>`:null}
      ${l?o`<pre class="council-detail governance-preview">${Xy(l)}</pre>`:null}
    </div>
  `}function ib(){var c,d,p;const t=fr(),e=Ba.value,n=Ka.value,s=(e==null?void 0:e.context)??(n==null?void 0:n.context)??(t==null?void 0:t.context),a=(e==null?void 0:e.judgment)??(n==null?void 0:n.judgment),i=t==null?void 0:t.guardrail_state,l=(c=Bt.value)==null?void 0:c.judge;return o`
    <div class="governance-side-column">
      <${M} title="이유 / 가드레일" class="section" semanticId="governance.guardrail">
        ${t?o`
              <div class="governance-side-block">
                <h4>판정기</h4>
                <div class="council-sub">
                  <span>${l!=null&&l.judge_online?"온라인":"오프라인"}</span>
                  ${l!=null&&l.model_used?o`<span>${l.model_used}</span>`:null}
                  ${l!=null&&l.generated_at?o`<span><${et} timestamp=${l.generated_at} /></span>`:null}
                </div>
                ${t.judgment_summary?o`<div class="governance-summary-callout">${t.judgment_summary}</div>`:o`<div class="governance-side-line">현재 LLM 판단이 없어 사실 계층만 보여줍니다.</div>`}
                <div class="council-sub">
                  <span>신뢰도 ${Qy(t.confidence)}</span>
                  ${a!=null&&a.keeper_name?o`<span>${a.keeper_name}</span>`:null}
                </div>
              </div>

              <${Hl} title="추천 경로" route=${t.recommended_action} />
              <${Hl} title="실행된 경로" route=${t.executed_route} />

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
                          onClick=${()=>Wl("confirm")}
                          disabled=${en.value}
                        >
                          ${en.value?"처리 중...":"승인"}
                        </button>
                        <button
                          class="control-btn ghost"
                          onClick=${()=>Wl("deny")}
                          disabled=${en.value}
                        >
                          ${en.value?"처리 중...":"거부"}
                        </button>
                      </div>
                    `:o`<div class="governance-side-line">이 의사결정에 대기 중인 사람 승인은 없습니다.</div>`}
              </div>
            `:o`<div class="empty-state">판단과 경로를 보려면 의사결정을 고르세요.</div>`}
      <//>

      <${M} title="맥락" class="section" semanticId="governance.context">
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
                        ${t.related_agents.map(v=>o`<span class="governance-chip dim">${v}</span>`)}
                      </div>
                    `:o`<div class="governance-side-line">명시적으로 연결된 맥락 기록이 없습니다.</div>`}
                ${t.evidence_refs.length>0?o`
                      <div class="governance-side-line">근거 참조</div>
                      <div class="governance-chip-row">
                        ${t.evidence_refs.map(v=>o`<span class="governance-chip">${v}</span>`)}
                      </div>
                    `:null}
              </div>
          `:o`<div class="empty-state">선택된 맥락이 없습니다.</div>`}
      <//>

      <${M} title="최근 활동" class="section" semanticId="governance.activity">
        <div class="governance-activity-list">
          ${(((d=Bt.value)==null?void 0:d.activity)??[]).slice(0,8).map(v=>o`
            <div class="governance-activity-row">
              <div class="governance-ledger-head">
                <span class="governance-badge ${io(v.kind)}">${v.kind}</span>
                ${v.actor?o`<strong>${v.actor}</strong>`:null}
                ${v.created_at?o`<span><${et} timestamp=${v.created_at} /></span>`:null}
              </div>
              <div class="governance-ledger-body">${v.summary||v.topic||"활동이 기록되었습니다."}</div>
            </div>
          `)}
          ${(((p=Bt.value)==null?void 0:p.activity)??[]).length===0?o`<div class="empty-state">기록된 거버넌스 활동이 없습니다.</div>`:null}
        </div>
      <//>
    </div>
  `}function rb(){return nt(()=>{$n()},[]),o`
    <div>
      <${xt} surfaceId="governance" />
      <${tb} />
      <${eb} />
      <div class="governance-layout">
        <${nb} />
        <${ob} />
        <${ib} />
      </div>
    </div>
  `}const He=g(""),zo=g("ability_check"),jo=g("10"),No=g("12"),Ds=g(""),Os=g("idle"),re=g(""),qs=g("keeper-late"),wo=g("player"),Do=g(""),Ct=g("idle"),Oo=g(null),Fs=g(""),qo=g(""),Fo=g("player"),Bo=g(""),Ko=g(""),Uo=g(""),Un=g("20"),Wo=g("20"),Ho=g(""),Bs=g("idle"),Ii=g(null),du=g("overview"),Go=g("all"),Jo=g("all"),Yo=g("all"),lb=12e4,ro=g(null),Gl=g(Date.now());function cb(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function db(t,e){return e>0?Math.round(t/e*100):0}const ub={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},pb={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Ks(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function mb(t){const e=t.trim().toLowerCase();return ub[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function _b(t){const e=t.trim().toLowerCase();return pb[e]??"상황에 따라 선택되는 전술 액션입니다."}function bt(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Nt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function ps(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const vb=new Set(["str","dex","con","int","wis","cha"]);function fb(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!m(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const l=a.trim();if(l){if(typeof i=="number"&&Number.isFinite(i)){s[l]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const c=Number.parseFloat(i.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function gb(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(Un.value.trim(),10);Number.isFinite(s)&&s>n&&(Un.value=String(n))}function Ri(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function $b(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function hb(t){du.value=t}function uu(t){const e=ro.value;return e==null||e<=t}function yb(t){const e=ro.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Ua(){ro.value=null}function pu(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function bb(t,e){pu(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(ro.value=Date.now()+lb,N("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function aa(t){return uu(t)?(N("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Mi(t,e,n){return pu([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function kb({hp:t,max:e}){const n=db(t,e),s=cb(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function xb({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Sb({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function mu({actor:t}){var d,p,v,_;const e=(d=t.archetype)==null?void 0:d.trim(),n=(p=t.persona)==null?void 0:p.trim(),s=(v=t.portrait)==null?void 0:v.trim(),a=(_=t.background)==null?void 0:_.trim(),i=t.traits??[],l=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([f,h])=>Number.isFinite(h)).filter(([f])=>!vb.has(f.toLowerCase()));return o`
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
        <${be} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Sb} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${kb} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${xb} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${Ks(e)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([f,h])=>o`
                <span class="trpg-custom-stat-chip">${Ks(f)} ${h}</span>
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
                  <span class="trpg-annot-name">${Ks(f)}</span>
                  <span class="trpg-annot-desc">${mb(f)}</span>
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
                  <span class="trpg-annot-name">${Ks(f)}</span>
                  <span class="trpg-annot-desc">${_b(f)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Cb({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function _u({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${$b(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Ri(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${et} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Ab({events:t}){const e="__none__",n=Go.value,s=Jo.value,a=Yo.value,i=Array.from(new Set(t.map(Ri).map(_=>_.trim()).filter(_=>_!==""))).sort((_,f)=>_.localeCompare(f)),l=Array.from(new Set(t.map(_=>(_.type??"").trim()).filter(_=>_!==""))).sort((_,f)=>_.localeCompare(f)),c=t.some(_=>(_.type??"").trim()===""),d=Array.from(new Set(t.map(_=>(_.phase??"").trim()).filter(_=>_!==""))).sort((_,f)=>_.localeCompare(f)),p=t.some(_=>(_.phase??"").trim()===""),v=t.filter(_=>{if(n!=="all"&&Ri(_)!==n)return!1;const f=(_.type??"").trim(),h=(_.phase??"").trim();if(s===e){if(f!=="")return!1}else if(s!=="all"&&f!==s)return!1;if(a===e){if(h!=="")return!1}else if(a!=="all"&&h!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${_=>{Go.value=_.target.value}}>
          <option value="all">all</option>
          ${i.map(_=>o`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${_=>{Jo.value=_.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${e}>(none)</option>`:null}
          ${l.map(_=>o`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${_=>{Yo.value=_.target.value}}>
          <option value="all">all</option>
          ${p?o`<option value=${e}>(none)</option>`:null}
          ${d.map(_=>o`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Go.value="all",Jo.value="all",Yo.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${v.length} / 전체 ${t.length}
      </span>
    </div>
    <${_u} events=${v.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Tb({outcome:t}){if(!t)return null;const e=i=>{const l=i.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function vu({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function Ib({state:t,nowMs:e}){var p;const n=ee.value||((p=t.session)==null?void 0:p.room)||"",s=Os.value,a=t.party??[];if(!a.find(v=>v.id===He.value)&&a.length>0){const v=a[0];v&&(He.value=v.id)}const l=async()=>{var _,f;if(!n){N("Room ID가 비어 있습니다.","error");return}if(!aa(e))return;const v=((_=t.current_round)==null?void 0:_.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(Mi("라운드 실행",n,v)){Os.value="running";try{const h=await Qp(n);Ii.value=h,Os.value="ok";const C=m(h.summary)?h.summary:null,b=C?ps(C,"advanced",!1):!1,x=C?bt(C,"progress_reason",""):"";N(b?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${x?`: ${x}`:""}`,b?"success":"warning"),me()}catch(h){Ii.value=null,Os.value="error";const C=h instanceof Error?h.message:"라운드 실행에 실패했습니다.";N(C,"error")}finally{Ua()}}},c=async()=>{var _,f;if(!n||!aa(e))return;const v=((_=t.current_round)==null?void 0:_.phase)??((f=t.session)==null?void 0:f.status)??"unknown";if(Mi("턴 강제 진행",n,v))try{await em(n),N("턴을 다음 단계로 이동했습니다.","success"),me()}catch{N("턴 이동에 실패했습니다.","error")}finally{Ua()}},d=async()=>{if(!n||!aa(e))return;const v=He.value.trim();if(!v){N("먼저 Actor를 선택하세요.","warning");return}const _=Number.parseInt(jo.value,10),f=Number.parseInt(No.value,10);if(Number.isNaN(_)||Number.isNaN(f)){N("stat/dc는 숫자여야 합니다.","warning");return}const h=Number.parseInt(Ds.value,10),C=Ds.value.trim()===""||Number.isNaN(h)?void 0:h;try{await tm({roomId:n,actorId:v,action:zo.value.trim()||"ability_check",statValue:_,dc:f,rawD20:C}),N("주사위 판정을 기록했습니다.","success"),me()}catch{N("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${v=>{ee.value=v.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${He.value}
            onChange=${v=>{He.value=v.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(v=>o`<option value=${v.id}>${v.name} (${v.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${zo.value}
              onInput=${v=>{zo.value=v.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${jo.value}
              onInput=${v=>{jo.value=v.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${No.value}
              onInput=${v=>{No.value=v.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Ds.value}
              onInput=${v=>{Ds.value=v.target.value}}
              onKeyDown=${v=>{v.key==="Enter"&&d()}}
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
  `}function Rb({state:t}){var a;const e=ee.value||((a=t.session)==null?void 0:a.room)||"",n=Bs.value,s=async()=>{if(!e){N("Room ID가 비어 있습니다.","warning");return}const i=Fs.value.trim(),l=qo.value.trim();if(!l&&!i){N("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Un.value.trim(),10),d=Number.parseInt(Wo.value.trim(),10),p=Number.isFinite(d)?Math.max(1,d):20,v=Number.isFinite(c)?Math.max(0,Math.min(p,c)):p;let _={};try{_=fb(Ho.value)}catch(f){N(f instanceof Error?f.message:"능력치 JSON 오류","error");return}Bs.value="spawning";try{const f=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,h=await nm(e,{actor_id:i||void 0,name:l||void 0,role:Fo.value,idempotencyKey:f,portrait:Ko.value.trim()||void 0,background:Uo.value.trim()||void 0,hp:v,max_hp:p,alive:v>0,stats:Object.keys(_).length>0?_:void 0}),C=typeof h.actor_id=="string"?h.actor_id.trim():"";if(!C)throw new Error("생성 응답에 actor_id가 없습니다.");const b=Bo.value.trim();b&&await sm(e,C,b),He.value=C,re.value=C,i||(Fs.value=""),Bs.value="ok",N(`Actor 생성 완료: ${C}`,"success"),await me()}catch(f){Bs.value="error",N(f instanceof Error?f.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${qo.value}
            onInput=${i=>{qo.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Fo.value}
            onChange=${i=>{Fo.value=i.target.value}}
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
            value=${Bo.value}
            onInput=${i=>{Bo.value=i.target.value}}
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
              value=${Fs.value}
              onInput=${i=>{Fs.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Ko.value}
              onInput=${i=>{Ko.value=i.target.value}}
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
              value=${Un.value}
              onInput=${i=>{Un.value=i.target.value}}
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
              value=${Wo.value}
              onInput=${i=>{const l=i.target.value;Wo.value=l,gb(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Uo.value}
              onInput=${i=>{Uo.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Ho.value}
              onInput=${i=>{Ho.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Mb({state:t,nowMs:e}){var f;const n=ee.value||((f=t.session)==null?void 0:f.room)||"",s=t.join_gate,a=Oo.value,i=m(a)?a:null,l=(t.party??[]).filter(h=>h.role!=="dm"),c=re.value.trim(),d=l.some(h=>h.id===c),p=d?c:c?"__manual__":"",v=async()=>{const h=re.value.trim(),C=qs.value.trim();if(!n||!h){N("Room/Actor가 필요합니다.","warning");return}Ct.value="checking";try{const b=await am(n,h,C||void 0);Oo.value=b,Ct.value="ok",N("참가 가능 여부를 갱신했습니다.","success")}catch(b){Ct.value="error";const x=b instanceof Error?b.message:"참가 가능 여부 확인에 실패했습니다.";N(x,"error")}},_=async()=>{var y,$;const h=re.value.trim(),C=qs.value.trim(),b=Do.value.trim();if(!n||!h||!C){N("Room/Actor/Keeper가 필요합니다.","warning");return}if(!aa(e))return;const x=((y=t.current_round)==null?void 0:y.phase)??(($=t.session)==null?void 0:$.status)??"unknown";if(Mi("Mid-Join 승인 요청",n,x)){Ct.value="requesting";try{const R=await om({room_id:n,actor_id:h,keeper_name:C,role:wo.value,...b?{name:b}:{}});Oo.value=R;const T=m(R)?ps(R,"granted",!1):!1,P=m(R)?bt(R,"reason_code",""):"";T?N("Mid-Join이 승인되었습니다.","success"):N(`Mid-Join이 거절되었습니다${P?`: ${P}`:""}`,"warning"),Ct.value=T?"ok":"error",me()}catch(R){Ct.value="error";const T=R instanceof Error?R.message:"Mid-Join 요청에 실패했습니다.";N(T,"error")}finally{Ua()}}};return o`
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
            onChange=${h=>{const C=h.target.value;if(C==="__manual__"){(d||!c)&&(re.value="");return}re.value=C}}
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
                value=${re.value}
                onInput=${h=>{re.value=h.target.value}}
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
            value=${qs.value}
            onInput=${h=>{qs.value=h.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${wo.value}
            onChange=${h=>{wo.value=h.target.value}}
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
            value=${Do.value}
            onInput=${h=>{Do.value=h.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${v} disabled=${Ct.value==="checking"||Ct.value==="requesting"}>
              ${Ct.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${_} disabled=${Ct.value==="checking"||Ct.value==="requesting"}>
              ${Ct.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${ps(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Nt(i,"effective_score",0)}/${Nt(i,"required_points",0)}</span>
            ${bt(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${bt(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function fu({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function gu({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function $u(){const t=Ii.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=m(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(m).slice(-8),i=t.canon_check,l=m(i)?i:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(P=>typeof P=="string").slice(0,3):[],d=l&&Array.isArray(l.violations)?l.violations.filter(P=>typeof P=="string").slice(0,3):[],p=n?ps(n,"advanced",!1):!1,v=n?bt(n,"progress_reason",""):"",_=n?bt(n,"progress_detail",""):"",f=n?Nt(n,"player_successes",0):0,h=n?Nt(n,"player_required_successes",0):0,C=n?ps(n,"dm_success",!1):!1,b=n?Nt(n,"timeouts",0):0,x=n?Nt(n,"unavailable",0):0,y=n?Nt(n,"reprompts",0):0,$=n?Nt(n,"npc_attacks",0):0,R=n?Nt(n,"keeper_timeout_sec",0):0,T=n?Nt(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${p?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${p?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${C?"DM ok":"DM stalled"} / players ${f}/${h}
          </span>
        </div>
        ${v?o`<div style="margin-top:4px; font-size:12px;">${v}</div>`:null}
        ${_?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${_}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${b}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${y}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${$}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${R||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${T}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(P=>{const G=bt(P,"status","unknown"),L=bt(P,"actor_id","-"),V=bt(P,"role","-"),X=bt(P,"reason",""),rt=bt(P,"action_type",""),U=bt(P,"reply","");return o`
                <div class="trpg-round-item ${G.includes("fallback")||G.includes("timeout")?"failed":"active"}">
                  <span>${L} (${V})</span>
                  <span style="margin-left:auto; font-size:11px;">${G}</span>
                  ${rt?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${rt}</div>`:null}
                  ${X?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${X}</div>`:null}
                  ${U?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${U.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${bt(l,"status","unknown")}</strong>
            </div>
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(P=>o`<div>violation: ${P}</div>`)}
                </div>`:null}
            ${c.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(P=>o`<div>warning: ${P}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Eb({state:t,nowMs:e}){var l,c,d;const n=ee.value||((l=t.session)==null?void 0:l.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((d=t.session)==null?void 0:d.status)??"unknown",a=uu(e),i=yb(e);return o`
    <${M} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>bb(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Ua(),N("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Lb({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>hb(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Pb({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${M} title="관전 가이드" semanticId="lab.trpg">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${M} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${_u} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${M} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${Cb} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${M} title="현재 라운드" semanticId="lab.trpg">
          <${gu} state=${t} />
        <//>

        <${M} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${fu} state=${t} />
        <//>

        <${M} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${mu} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${M} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${vu} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function zb({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${M} title=${`이벤트 타임라인 (${e.length})`}>
          <${Ab} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${M} title="최근 라운드 결과" semanticId="lab.trpg">
          <${$u} />
        <//>

        <${M} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${gu} state=${t} />
        <//>
      </div>
    </div>
  `}function jb({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${Eb} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${M} title="조작 패널" semanticId="lab.trpg">
            <${Ib} state=${t} nowMs=${e} />
          <//>

          <${M} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${Rb} state=${t} />
          <//>

          <${M} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${Mb} state=${t} nowMs=${e} />
          <//>

          <${M} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${$u} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${M} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${fu} state=${t} />
          <//>

          <${M} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${mu} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${M} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${vu} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Nb(){var c,d,p,v,_;const t=Ic.value,e=ri.value;if(nt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const f=window.setInterval(()=>{Gl.value=Date.now()},1e3);return()=>{window.clearInterval(f)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>me()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=du.value,l=Gl.value;return o`
    <div>
      <${xt} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${ee.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((p=t.session)==null?void 0:p.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>me()}>새로고침</button>
      </div>

      <${Tb} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((v=t.session)==null?void 0:v.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((_=t.current_round)==null?void 0:_.round_number)??0}</div>
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

      <${Lb} active=${i} />

      ${i==="overview"?o`<${Pb} state=${t} />`:i==="timeline"?o`<${zb} state=${t} />`:o`<${jb} state=${t} nowMs=${l} />`}
    </div>
  `}function wb(){return o`
    <div>
      <${xt} surfaceId="lab" />
      <${M} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${M} title="TRPG" class="section" semanticId="lab.trpg">
        <${Nb} />
      <//>
    </div>
  `}const Wa=g(new Set(["broadcast","tasks","keepers","system"]));function Db(t){const e=new Set(Wa.value);e.has(t)?e.delete(t):e.add(t),Wa.value=e}const gr=g(null);function hu(t){gr.value=t}function Ob(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const qb=Et(()=>{const t=Wa.value;return ia.value.filter(e=>t.has(Ob(e)))}),Fb=12e4,Bb=Et(()=>{const t=Lc.value,e=Date.now();return Gt.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let i="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?i=e-new Date(l).getTime()>Fb?"stale":"working":i="working"}else(n.status==="offline"||n.status==="inactive")&&(i="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:i,currentTask:n.current_task,motion:a}})}),Kb=Et(()=>{const t=Lc.value;return Gt.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let i="calm";return a>=3?i="hot":a>=1&&(i="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:i}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function Jl(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function Ub(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function Wb(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function Hb(){const t=Bb.value,e=gr.value;return t.length===0?o`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:o`
    <div class="pulse-strip">
      ${t.map(n=>o`
        <button
          key=${n.name}
          class="pulse-bubble ${Wb(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>hu(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const Gb=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function Jb(){const t=Wa.value;return o`
    <div class="activity-filter-bar">
      ${Gb.map(e=>o`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>Db(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Yb(){const t=qb.value;return o`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${Jb} />
      <div class="activity-stream-list">
        ${t.length===0?o`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>o`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${Jl(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${Jl(e)}">${Ub(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${Ad(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function Vb(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function Xb(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function Qb(){const t=Kb.value,e=gr.value;return o`
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
              onClick=${()=>hu(e===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?o`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${Vb(n.pressure)}">
                  ${Xb(n.pressure)}
                  ${n.assignedCount>0?o` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?o`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?o`<span class="focus-activity-text">${n.lastActivityText}</span>`:o`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?o`<${et} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function Zb(){const t=fe.value;return o`
    <div class="live-monitor">
      <div class="live-header">
        <h2>라이브 모니터</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"연결됨":"오프라인"}
          </span>
          <span class="live-stat">에이전트 ${Gt.value.length}</span>
          <span class="live-stat">이벤트 ${Ha.value}</span>
        </div>
      </div>

      <${Hb} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${Yb} />
        </div>
        <div class="live-panel-side">
          <${Qb} />
        </div>
      </div>
    </div>
  `}const Yl=[{id:"observe",label:"관찰",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"맥락",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"개입",description:"개입과 운영 기준 지휘를 실행하는 표면"},{id:"lab",label:"실험",description:"실험적 기능은 메인 operator console 밖으로 분리"}],Ei=[{id:"mission",label:"상황판",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"proof",label:"근거",icon:"🔍",group:"observe",description:"협업, 대화, 도구, 근거 기록을 증명 중심으로 읽는 표면"},{id:"execution",label:"실행",icon:"🤖",group:"observe",description:"워커, 태스크, 키퍼 연속성을 분리해서 보는 실행 표면"},{id:"tools",label:"도구",icon:"🧰",group:"observe",description:"시스템 전체 도구 inventory와 사용 통계를 함께 읽는 표면"},{id:"live",label:"라이브",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"계획",icon:"🎯",group:"observe",description:"목표, 지표 루프, 백로그 압력을 읽는 계획 표면"},{id:"memory",label:"메모리",icon:"💬",group:"context",description:"게시글과 댓글로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"거버넌스",icon:"⚖️",group:"context",description:"토론과 표결을 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"개입",icon:"🎮",group:"act",description:"룸, 세션, 키퍼 액션을 실행하는 개입 화면"},{id:"command",label:"지휘",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"실험",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 표면을 메인 콘솔 밖에서 다룹니다"}];function tk(t){const e=t==null?void 0:t.trim();return e?e.length>10?e.slice(0,10):e:"커밋 정보 없음"}function Rt(t,e){return e==="live"?"가동 중":e==="quiet"?"조용함":e==="starting"?"기동 중":e==="idle"?t==="guardian"?"유휴":"대기 중":"비활성"}function At(t,e){return o`
    <div class="build-badge-row">
      <span>${t}</span>
      <strong>${e}</strong>
    </div>
  `}function Us(t,e,n,s,a){return o`
    <div style="padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
      <div class="rail-card-head" style="margin:0;">
        <h3 style="font-size:12px;">${t}</h3>
        <span class="rail-section-chip ${n}">${e}</span>
      </div>
      ${s}
      ${a?o`<div class="rail-build-hint">${a}</div>`:null}
    </div>
  `}function ek({currentTab:t}){var d,p,v,_,f,h,C,b,x,y;const e=fe.value,n=(d=gt.value)==null?void 0:d.build,s=(p=gt.value)==null?void 0:p.lodge,a=(v=gt.value)==null?void 0:v.gardener,i=(_=gt.value)==null?void 0:_.guardian,l=(f=gt.value)==null?void 0:f.sentinel,c=[];if(s&&c.push(Us("Lodge",s.enabled?Rt("lodge",s.quiet_active?"quiet":"live"):Rt("lodge","disabled"),s.enabled?s.quiet_active?"warn":"ok":"bad",[At("틱",s.total_ticks??0),At("체크인",s.total_checkins??0),At("최근 결과",((h=s.last_tick_result)==null?void 0:h.activity_report)??s.last_skip_reason??"없음")])),a&&c.push(Us("Gardener",a.alive?Rt("gardener","live"):a.enabled?Rt("gardener","starting"):Rt("gardener","disabled"),a.alive?"ok":a.enabled?"warn":"bad",[At("최근 tick",a.last_tick_completed_at?o`<${et} timestamp=${a.last_tick_completed_at} />`:"기록 없음"),At("판단",`${a.last_intervention??"없음"} · ${a.last_decision_source??"없음"}`),At("백로그",`미할당 ${((C=a.health_summary)==null?void 0:C.todo_count)??0} · P1/2 ${((b=a.health_summary)==null?void 0:b.high_priority_todo)??0}`)],a.last_reason??a.last_error??void 0)),i){const $=i.masc_loops_running||i.lodge_loop_started||i.lodge_running;c.push(Us("Guardian",$?Rt("guardian","live"):i.enabled?Rt("guardian","idle"):Rt("guardian","disabled"),$?"ok":i.enabled?"warn":"bad",[At("모드",i.mode??"알 수 없음"),At("루프",`zombie ${i.zombie_loop_running?"on":"off"} · gc ${i.gc_loop_running?"on":"off"}`),At("소유자",i.runtime_owner??"없음")],((x=i.last_lodge_result)==null?void 0:x.message)??i.last_gc_result??i.last_zombie_result??void 0))}return l&&c.push(Us("Sentinel",l.started?Rt("sentinel","live"):l.enabled?Rt("sentinel","starting"):Rt("sentinel","disabled"),l.started?"ok":l.enabled?"warn":"bad",[At("에이전트",l.agent_name??"sentinel"),At("소비자",((y=l.consumers)==null?void 0:y.length)??0),At("가디언 소유자",l.guardian_runtime_owner??"없음")],l.llm_enabled===!0?"LLM 기반 housekeeping resident":void 0)),o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${O} panelId="side_rail.snapshot" compact=${!0} />
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
          <strong>${de.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>이벤트</span>
          <strong>${Ha.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{_s(),Nc(),gi(t)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>ot("intervene")}>
          개입 열기
        </button>
      </div>
      ${n?o`<div class="rail-build-hint">서버 빌드 · v${n.release_version} · ${tk(n.commit)}</div>`:null}
      ${c.length>0?o`
            <div style="margin-top:12px; display:flex; flex-direction:column; gap:10px;">
              ${c}
            </div>
          `:null}
    </section>
  `}function nk(){const t=Lt.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return o`
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
          onClick=${()=>{_t(),Oe()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>ot("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}const Ws=g(!1);function sk(){const t=fe.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"연결됨":"재연결 중..."}</span>
      <span class="event-count">이벤트 ${Ha.value}</span>
    </div>
  `}function ak(t){const e=t==null?void 0:t.trim();return e?e.length>10?e.slice(0,10):e:"커밋 정보 없음"}function ok(){const t=gt.value,e=t==null?void 0:t.build,n=e?`v${e.release_version} · ${ak(e.commit)}`:t!=null&&t.version?`v${t.version} · 커밋 정보 없음`:"버전 정보 없음";return o`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${Ws.value}
        onClick=${()=>{Ws.value=!Ws.value}}
      >
        서버 빌드 · ${n}
      </button>
      ${Ws.value?o`
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
                <strong>${e!=null&&e.started_at?o`<${et} timestamp=${e.started_at} />`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof(e==null?void 0:e.uptime_seconds)=="number"?`${e.uptime_seconds}s`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${t!=null&&t.generated_at?o`<${et} timestamp=${t.generated_at} />`:"알 수 없음"}</strong>
              </div>
            </div>
          `:null}
    </div>
  `}function ik(){const t=D.value.tab,e=Ei.find(s=>s.id===t),n=Yl.find(s=>s.id===(e==null?void 0:e.group));return o`
    <aside class="dashboard-rail">
      <${xt} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${O} panelId="side_rail.navigate" compact=${!0} />
          ${n?o`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${Yl.map(s=>o`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${Ei.filter(a=>a.group===s.id).map(a=>o`
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

      <${ek} currentTab=${t} />
      <${nk} />
    </aside>
  `}function rk(){switch(D.value.tab){case"mission":return o`<${$l} />`;case"proof":return o`<${g$} />`;case"execution":return o`<${Ay} />`;case"tools":return o`<${Py} />`;case"live":return o`<${Zb} />`;case"memory":return o`<${my} />`;case"governance":return o`<${rb} />`;case"planning":return o`<${Jy} />`;case"intervene":return o`<${ty} />`;case"command":return o`<${Vh} />`;case"lab":return o`<${wb} />`;default:return o`<${$l} />`}}function lk(){return ii.value&&!fe.value?o`<div class="loading-indicator">대시보드 불러오는 중...</div>`:o`<${rk} />`}function ck(){nt(()=>{Ru(),nc(),wc(),Le(),Ee(),Nc(),Qc();const n=T_();return I_(),()=>{wu(),n(),R_()}},[]),nt(()=>{const n=setInterval(()=>{gi(D.value.tab)},15e3);return()=>{clearInterval(n)}},[]),nt(()=>{gi(D.value.tab)},[D.value.tab]);const t=D.value.tab,e=Ei.find(n=>n.id===t);return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC 대시보드
            <${ok} />
          </h1>
          <p class="header-subtitle">${(e==null?void 0:e.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${sk} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${ik} />
        <main class="dashboard-main">
          <${lk} />
        </main>
      </div>

      <${hg} />
      <${Yf} />
      <${Ff} />
    </div>
  `}const Vl=document.getElementById("app");Vl&&Su(o`<${ck} />`,Vl);export{Rg as _};
