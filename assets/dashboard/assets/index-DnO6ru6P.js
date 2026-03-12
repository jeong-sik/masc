var Md=Object.defineProperty;var Ld=(t,e,n)=>e in t?Md(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var we=(t,e,n)=>Ld(t,typeof e!="symbol"?e+"":e,n);import{e as Pd,_ as Nd,c as g,b as Mt,y as ot,d as xi,A as Hs,G as jd}from"./vendor-kuFK4-oj.js";(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const l of i.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var o=Pd.bind(Nd);const Ed=["mission","proof","execution","tools","live","memory","governance","planning","intervene","command","lab"],ml={tab:"mission",params:{},postId:null};function mr(t){return!!t&&Ed.includes(t)}function Ko(t){try{return decodeURIComponent(t)}catch{return t}}function Bo(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Od(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function _l(t,e){if(t[0]==="chains"){const i={...e,surface:"chains"};return t[1]==="operation"&&t[2]&&(i.operation=Ko(t[2])),{tab:"command",params:i,postId:null}}if(t[0]==="lab"){const i={...e};return t[1]&&(i.surface=Ko(t[1])),{tab:"lab",params:i,postId:null}}const n=t[0],s=e.tab;return{tab:mr(n)?n:mr(s)?s:"mission",params:e,postId:null}}function oa(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return ml;const n=Ko(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=Bo(a),l=Od(s);return _l(l,i)}function Dd(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...ml,params:Bo(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Bo(e.replace(/^\?/,""));return _l(s,a)}function vl(t){const e=t.tab==="lab"&&t.params.surface?`lab/${encodeURIComponent(t.params.surface)}`:t.tab,n=Object.entries(t.params).filter(([a])=>!(a==="tab"||t.tab==="lab"&&a==="surface"));if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const F=g(oa(window.location.hash));window.addEventListener("hashchange",()=>{F.value=oa(window.location.hash)});function it(t,e){const n={tab:t,params:e??{}};window.location.hash=vl(n)}function wd(t){window.location.hash=`#memory?post=${encodeURIComponent(t)}`}function qd(){if(window.location.hash&&window.location.hash!=="#"){F.value=oa(window.location.hash);return}const t=Dd(window.location.pathname,window.location.search);if(t){F.value=t;const e=vl(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#mission",F.value=oa(window.location.hash)}const _r="masc_dashboard_sse_session_id",Fd=1e3,Kd=15e3,pe=g(!1),Ga=g(0),fl=g(null),ia=g([]);function Bd(){let t=sessionStorage.getItem(_r);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(_r,t)),t}const Ud=200;function Hd(t,e,n="system",s={}){const a={agent:t,text:e,timestamp:Date.now(),kind:n,...s};ia.value=[a,...ia.value].slice(0,Ud)}function Uo(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function vr(t,e){const n=Uo(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function It(t,e,n,s,a={}){Hd(t,e,n,{eventType:s,...a})}let Et=null,Qe=null,Ho=0;function gl(){Qe&&(clearTimeout(Qe),Qe=null)}function Wd(){if(Qe)return;Ho++;const t=Math.min(Ho,5),e=Math.min(Kd,Fd*Math.pow(2,t));Qe=setTimeout(()=>{Qe=null,$l()},e)}function $l(){gl(),Et&&(Et.close(),Et=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",Bd());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);Et=i,i.onopen=()=>{Et===i&&(Ho=0,pe.value=!0)},i.onerror=()=>{Et===i&&(pe.value=!1,i.close(),Et=null,Wd())},i.onmessage=l=>{try{const c=JSON.parse(l.data);Ga.value++,fl.value=c,Gd(c)}catch{}}}function Gd(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":It(n,"Joined","system","agent_joined");break;case"agent_left":It(n,"Left","system","agent_left");break;case"broadcast":It(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":It(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":It(n,vr("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Uo(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":It(n,vr("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Uo(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":It(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":It(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":It(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":It(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:It(n,e,"system","unknown")}}function Jd(){gl(),Et&&(Et.close(),Et=null),pe.value=!1}function m(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function r(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function d(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function E(t){return typeof t=="boolean"?t:void 0}function B(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function mt(t,e=[]){if(Array.isArray(t))return t;if(!m(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function rt(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function hl(){return new URLSearchParams(window.location.search)}const Yd="masc_dashboard_agent_name";function Vd(){var t;try{return((t=localStorage.getItem(Yd))==null?void 0:t.trim())||null}catch{return null}}function yl(){const t=hl(),e={},n=t.get("token"),s=Vd(),a=t.get("agent")??t.get("agent_name")??s;return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function bl(){return{...yl(),"Content-Type":"application/json"}}const Xd=15e3,Si=3e4,Qd=6e4,fr=new Set([408,425,429,500,502,503,504]);class rs extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);we(this,"method");we(this,"path");we(this,"status");we(this,"statusText");we(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function Ci(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const l=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new rs({method:l,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function Zd(){var e,n;const t=hl();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function at(t){const e=await Ci(t,{headers:yl()},Xd);if(!e.ok)throw new rs({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function tu(t){return new Promise(e=>setTimeout(e,t))}function eu(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function nu(t){if(t instanceof rs)return t.timeout||typeof t.status=="number"&&fr.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=eu(t.message);return e!==null&&fr.has(e)}async function Ja(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!nu(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,a),await tu(i),s+=1}}async function Kt(t,e,n,s=Si){const a=await Ci(t,{method:"POST",headers:{...bl(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new rs({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function su(t,e,n,s=Si){const a=await Ci(t,{method:"POST",headers:{...bl(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new rs({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function au(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function ou(t){var e,n,s,a,i,l,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const p=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(p)}return((c=(l=(i=t.result)==null?void 0:i.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function fe(t,e){const n=await su("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Qd),s=au(n);return ou(s)}function iu(){return at("/api/v1/dashboard/shell")}function ru(){return at("/api/v1/dashboard/room-truth")}function lu(){return at("/api/v1/dashboard/execution")}function cu(t,e){const n=new URLSearchParams;return n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),at(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function du(){return Ja("fetchDashboardGovernance",async()=>{const t=await at("/api/v1/dashboard/governance"),e=Array.isArray(t.items)?t.items.map(i=>zu(i)).filter(i=>i!==null):[],n=Array.isArray(t.pending_actions)?t.pending_actions.map(i=>Sl(i)).filter(i=>i!==null):[],s=e.filter(i=>i.kind==="debate").map(i=>({id:i.id,topic:i.topic,status:i.status,argument_count:i.evidence_refs.length,created_at:i.last_activity_at??void 0})),a=e.filter(i=>i.kind==="consensus").map(i=>({id:i.id,topic:i.topic,initiator:i.related_agents[0]||"system",votes:i.votes??0,quorum:i.quorum??0,threshold:i.threshold,state:i.status,created_at:i.last_activity_at??void 0}));return{generated_at:ut(t.generated_at)??void 0,summary:m(t.summary)?{debates:ft(t.summary.debates)??void 0,voting_sessions:ft(t.summary.voting_sessions)??void 0,debates_open:ft(t.summary.debates_open)??void 0,sessions_active:ft(t.summary.sessions_active)??void 0,sessions_without_quorum:ft(t.summary.sessions_without_quorum)??void 0,ready_to_execute:ft(t.summary.ready_to_execute)??void 0,oldest_open_debate_age_s:typeof t.summary.oldest_open_debate_age_s=="number"?t.summary.oldest_open_debate_age_s:null,last_activity_age_s:typeof t.summary.last_activity_age_s=="number"?t.summary.last_activity_age_s:null,judge_online:typeof t.summary.judge_online=="boolean"?t.summary.judge_online:void 0,judge_last_seen_at:ut(t.summary.judge_last_seen_at)}:void 0,debates:s,sessions:a,items:e,activity:Array.isArray(t.activity)?t.activity.map(i=>Ru(i)).filter(i=>i!==null):[],judge:Mu(t.judge),pending_actions:n}})}function uu(){return at("/api/v1/dashboard/semantics")}function pu(){return at("/api/v1/dashboard/mission")}function mu(t){const e=`?session_id=${encodeURIComponent(t)}`;return at(`/api/v1/dashboard/session${e}`)}function _u(t=!1){return at(`/api/v1/dashboard/mission/briefing${t?"?force=1":""}`)}function vu(t,e){const n=new URLSearchParams;t&&n.set("session_id",t),e&&n.set("operation_id",e);const s=n.toString();return at(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function fu(){return at("/api/v1/dashboard/planning")}function gu(){return at("/api/v1/tool-metrics")}function $u(){return at("/api/v1/dashboard/tools")}function hu(){return at("/api/v1/operator")}function kl(t={}){const e=new URLSearchParams;t.targetType&&e.set("target_type",t.targetType),t.targetId&&e.set("target_id",t.targetId),t.includeWorkers!=null&&e.set("include_workers",t.includeWorkers?"true":"false");const n=e.toString();return at(`/api/v1/operator/digest${n?`?${n}`:""}`)}function yu(){return at("/api/v1/command-plane")}function bu(){return at("/api/v1/command-plane/summary")}function ku(){return at("/api/v1/chains/summary")}function xu(t){return at(`/api/v1/chains/runs/${encodeURIComponent(t)}`)}function Su(){return at("/api/v1/command-plane/help")}function Cu(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return at(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function Au(t,e){const n=new URLSearchParams;t&&n.set("run_id",t),e&&n.set("operation_id",e);const s=n.toString();return at(`/api/v1/command-plane/orchestra${s?`?${s}`:""}`)}function Tu(t,e){return Kt(t,e)}function Iu(t){switch(t.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"swarm_run_continue":return 6e4;case"swarm_run_rerun":return 12e4;case"swarm_run_abandon":return 3e4;case"lodge_tick":return 45e3;default:return Si}}function Ya(t){return Kt("/api/v1/operator/action",t,void 0,Iu(t))}function xl(t,e,n="confirm"){return Kt("/api/v1/operator/confirm",{actor:t,confirm_token:e,decision:n})}function Ws(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function ut(t){if(typeof t=="string"){const e=t.trim();return e||null}if(typeof t=="number"&&Number.isFinite(t)){const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}return null}function U(t){if(typeof t!="string")return null;const e=t.trim();return e||null}function Sl(t){if(!m(t))return null;const e=x(t.confirm_token??t.token,"").trim();return e?{confirm_token:e,actor:U(t.actor)??void 0,action_type:U(t.action_type)??void 0,target_type:U(t.target_type)??void 0,target_id:U(t.target_id),delegated_tool:U(t.delegated_tool)??void 0,created_at:ut(t.created_at)??void 0,preview:t.preview}:null}function Ai(t){return m(t)?{board_post_id:U(t.board_post_id),task_id:U(t.task_id),operation_id:U(t.operation_id),team_session_id:U(t.team_session_id)}:{}}function Cl(t){if(!m(t))return null;const e=U(t.action_kind),n=U(t.resolved_tool),s=U(t.target_type),a=U(t.target_id),i=U(t.reason);return!e&&!n&&!s&&!i?null:{action_kind:e??void 0,resolved_tool:n,target_type:s,target_id:a,reason:i??void 0,payload_preview:t.payload_preview}}function Al(t){if(!m(t))return null;const e=U(t.action_type),n=U(t.delegated_tool),s=U(t.confirmation_state),a=ut(t.created_at);return!e&&!n&&!s&&!a?null:{action_type:e??void 0,delegated_tool:n,confirmation_state:s??void 0,created_at:a}}function Tl(t){if(!m(t))return null;const e=Sl(t.pending_confirm),n=U(t.pending_confirm_token)??(e==null?void 0:e.confirm_token)??null;return{requires_human_gate:typeof t.requires_human_gate=="boolean"?t.requires_human_gate:void 0,pending_confirm:e,pending_confirm_token:n,ready_to_execute:typeof t.ready_to_execute=="boolean"?t.ready_to_execute:void 0}}function Il(t){if(!m(t))return null;const e=U(t.summary),n=U(t.target_id);return!e&&!n?null:{judgment_id:U(t.judgment_id)??void 0,target_kind:U(t.target_kind)??void 0,target_id:n??void 0,status:U(t.status)??void 0,summary:e??void 0,confidence:typeof t.confidence=="number"?t.confidence:null,generated_at:ut(t.generated_at),expires_at:ut(t.expires_at),model_used:U(t.model_used),keeper_name:U(t.keeper_name),evidence_refs:Ot(t.evidence_refs),recommended_action:Cl(t.recommended_action),guardrail_state:Tl(t.guardrail_state),executed_route:Al(t.executed_route)}}function zu(t){if(!m(t))return null;const e=x(t.id,"").trim(),n=x(t.topic,"").trim();if(!e||!n)return null;const s=Ai(t.context);return{kind:x(t.kind,"debate"),id:e,topic:n,status:x(t.status??t.state,"open"),last_activity_at:ut(t.last_activity_at),truth_summary:U(t.truth_summary)??void 0,judgment_summary:U(t.judgment_summary),confidence:typeof t.confidence=="number"?t.confidence:null,related_agents:Ot(t.related_agents),context:s,linked_board_post_id:U(t.linked_board_post_id)??s.board_post_id??null,linked_task_id:U(t.linked_task_id)??s.task_id??null,linked_operation_id:U(t.linked_operation_id)??s.operation_id??null,linked_session_id:U(t.linked_session_id)??s.team_session_id??null,recommended_action:Cl(t.recommended_action),executed_route:Al(t.executed_route),guardrail_state:Tl(t.guardrail_state),evidence_refs:Ot(t.evidence_refs),approve_count:ft(t.approve_count),reject_count:ft(t.reject_count),abstain_count:ft(t.abstain_count),votes:ft(t.votes),quorum:ft(t.quorum),threshold:typeof t.threshold=="number"?t.threshold:void 0}}function Ru(t){if(!m(t))return null;const e=x(t.kind,"").trim();return e?{kind:e,item_kind:U(t.item_kind)??void 0,item_id:U(t.item_id)??void 0,topic:U(t.topic)??void 0,created_at:ut(t.created_at),summary:U(t.summary)??void 0,actor:U(t.actor),index:ft(t.index),decision:U(t.decision)}:null}function Mu(t){if(m(t))return{judge_online:typeof t.judge_online=="boolean"?t.judge_online:void 0,refreshing:typeof t.refreshing=="boolean"?t.refreshing:void 0,generated_at:ut(t.generated_at),expires_at:ut(t.expires_at),model_used:U(t.model_used),keeper_name:U(t.keeper_name),last_error:U(t.last_error)}}function Lu(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Pu(t){if(!m(t))return null;const e=x(t.source,"").trim()||null,n=x(t.state_block,"").trim()||null;return!e&&!n?null:{source:e,state_block:n}}function Nu(t){if(!m(t))return null;const e=x(t.id,"").trim(),n=x(t.author,"").trim(),s=x(t.body,"").trim()||x(t.content,"").trim(),a=s;if(!e||!n)return null;const i=G(t.score,0),l=G(t.votes_up,0),c=G(t.votes_down,0),p=G(t.votes,i||l-c),_=G(t.comment_count,G(t.reply_count,0)),u=(()=>{const S=t.flair;if(typeof S=="string"&&S.trim())return S.trim();if(m(S)){const $=x(S.name,"").trim();if($)return $}return x(t.flair_name,"").trim()||void 0})(),f=x(t.created_at_iso,"").trim()||Ws(t.created_at),v=x(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Ws(t.updated_at):f),A=x(t.title,"").trim()||Lu(s),k=Array.isArray(t.tags)?t.tags.filter(S=>typeof S=="string"&&S.trim()!==""):[];return{id:e,author:n,post_kind:(()=>{const S=x(t.post_kind,"").trim().toLowerCase();return S==="automation"||S==="system"||S==="human"?S:void 0})(),title:A,body:s,content:a,meta:Pu(t.meta),tags:k,votes:p,vote_balance:i,comment_count:_,created_at:f,updated_at:v,flair:u,hearth:x(t.hearth,"").trim()||null,visibility:x(t.visibility,"").trim()||void 0,expires_at:x(t.expires_at_iso,"").trim()||(t.expires_at!==void 0&&t.expires_at!==0?Ws(t.expires_at):"")||null,hearth_count:G(t.hearth_count,0)}}function ju(t){if(!m(t))return null;const e=x(t.id,"").trim(),n=x(t.post_id,"").trim(),s=x(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:x(t.content,""),created_at:Ws(t.created_at)}}async function Eu(t){return Ja("fetchBoardPost",async()=>{const e=await at(`/api/v1/board/${t}?format=flat`),n=m(e.post)?e.post:e,s=Nu(n)??{id:t,author:"unknown",post_kind:"human",title:"Post",body:"",content:"",meta:null,tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},i=(Array.isArray(e.comments)?e.comments:[]).map(ju).filter(l=>l!==null);return{...s,comments:i}})}function zl(t,e){return Kt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Zd()})}function Ou(t,e,n){return Kt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Du(t){const e=x(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function pt(...t){for(const e of t){const n=x(e,"");if(n.trim())return n.trim()}return""}function gr(t){const e=Du(pt(t.outcome,t.result,t.result_code));if(!e)return;const n=pt(t.reason,t.reason_code,t.description,t.detail),s=pt(t.summary,t.summary_ko,t.summary_en,t.note),a=pt(t.details,t.details_text,t.text,t.note),i=pt(t.winner,t.winner_name,t.actor_winner,t.winner_actor),l=pt(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=pt(t.raw_reason,t.raw_reason_code,t.error_message),p=(()=>{const f=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof f=="string"?[f]:Array.isArray(f)?f.map(v=>{if(typeof v=="string")return v.trim();if(m(v)){const h=x(v.summary,"").trim();if(h)return h;const A=x(v.text,"").trim();if(A)return A;const k=x(v.type,"").trim();return k||x(v.event_id,"").trim()}return""}).filter(v=>v.length>0):[]})(),_=(()=>{const f=G(t.turn,Number.NaN);if(Number.isFinite(f))return f;const v=G(t.turn_number,Number.NaN);if(Number.isFinite(v))return v;const h=G(t.current_turn,Number.NaN);if(Number.isFinite(h))return h;const A=G(t.round,Number.NaN);return Number.isFinite(A)?A:void 0})(),u=pt(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:l||void 0,evidence:p.length>0?p:void 0,raw_reason:c||void 0,turn:_,phase:u||void 0}}function wu(t,e){const n=m(t.state)?t.state:{};if(x(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(l=>m(l)?x(l.type,"")==="session.outcome":!1),i=m(n.session_outcome)?n.session_outcome:{};if(m(i)&&Object.keys(i).length>0){const l=gr(i);if(l)return l}if(m(a))return gr(m(a.payload)?a.payload:{})}function x(t,e=""){return typeof t=="string"?t:e}function G(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function ft(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function ra(t,e=!1){return typeof t=="boolean"?t:e}function Ot(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(m(e)){const n=x(e.name,"").trim(),s=x(e.id,"").trim(),a=x(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function qu(t){const e={};if(!m(t)&&!Array.isArray(t))return e;if(m(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=x(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!m(n))continue;const s=pt(n.to,n.target,n.actor_id,n.name,n.id),a=pt(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function Fu(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function Ct(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const Ku=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Bu(t){const e=m(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const i=s.trim();i&&(Ku.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function Uu(t,e){if(t!=="dice.rolled")return;const n=G(e.raw_d20,0),s=G(e.total,0),a=G(e.bonus,0),i=x(e.action,"roll"),l=G(e.dc,0);return{notation:l>0?`${i} (DC ${l})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Hu(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Wu(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Gu(t,e,n,s){const a=n||e||x(s.actor_id,"")||x(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=x(s.proposed_action,x(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=x(s.reply,x(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return x(s.reply,x(s.content,x(s.text,"Narration")));case"dice.rolled":{const i=x(s.action,"roll"),l=G(s.total,0),c=G(s.dc,0),p=x(s.label,""),_=a||"actor",u=c>0?` vs DC ${c}`:"",f=p?` (${p})`:"";return`${_} ${i}: ${l}${u}${f}`}case"turn.started":return`Turn ${G(s.turn,1)} started`;case"phase.changed":return`Phase: ${x(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${x(s.name,m(s.actor)?x(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${x(s.keeper_name,x(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${x(s.keeper_name,x(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${G(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${G(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||x(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||x(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${x(s.reason_code,"unknown")}`;case"memory.signal":{const i=m(s.entity_refs)?s.entity_refs:{},l=x(i.requested_tier,""),c=x(i.effective_tier,""),p=ra(i.guardrail_applied,!1),_=x(s.summary_en,x(s.summary_ko,"Memory signal"));if(!l&&!c)return _;const u=l&&c?`${l}->${c}`:c||l;return`${_} [${u}${p?" (guardrail)":""}]`}case"world.event":{if(x(s.event_type,"")==="canon.check"){const l=x(s.status,"unknown"),c=x(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return x(s.description,x(s.summary,"World event"))}case"combat.attack":return x(s.summary,x(s.result,"Attack resolved"));case"combat.defense":return x(s.summary,x(s.result,"Defense resolved"));case"session.outcome":return x(s.summary,x(s.outcome,"Session ended"));default:{const i=Hu(s);return i?`${t}: ${i}`:t}}}function Ju(t,e){const n=m(t)?t:{},s=x(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=x(n.actor_name,"").trim()||e[a]||x(m(n.payload)?n.payload.actor_name:"",""),l=m(n.payload)?n.payload:{},c=x(n.ts,x(n.timestamp,new Date().toISOString())),p=x(n.phase,x(l.phase,"")),_=x(n.category,"");return{type:s,actor:i||a||x(l.actor_name,""),actor_id:a||x(l.actor_id,""),actor_name:i,seq:n.seq,room_id:x(n.room_id,""),phase:p||void 0,category:_||Wu(s),visibility:x(n.visibility,x(l.visibility,"public")),event_id:x(n.event_id,""),content:Gu(s,a,i,l),dice_roll:Uu(s,l),timestamp:c}}function Yu(t,e,n){var Y,st;const s=x(t.room_id,"")||n||"default",a=m(t.state)?t.state:{},i=m(a.party)?a.party:{},l=m(a.actor_control)?a.actor_control:{},c=m(a.join_gate)?a.join_gate:{},p=m(a.contribution_ledger)?a.contribution_ledger:{},_=Object.entries(i).map(([P,T])=>{const C=m(T)?T:{},D=Ct(C,"max_hp",void 0,10),j=Ct(C,"hp",void 0,D),Q=Ct(C,"max_mp",void 0,0),Ut=Ct(C,"mp",void 0,0),H=Ct(C,"level",void 0,1),Lt=Ct(C,"xp",void 0,0),ye=ra(C.alive,j>0),bn=l[P],kn=typeof bn=="string"?bn:void 0,$s=Fu(C.role,P,kn),hs=ft(C.generation),ys=pt(C.joined_at,C.joinedAt,C.started_at,C.startedAt),bs=pt(C.claimed_at,C.claimedAt,C.assigned_at,C.assignedAt,C.assigned_time),ks=pt(C.last_seen,C.lastSeen,C.last_seen_at,C.lastSeenAt,C.last_active,C.lastActive),xs=pt(C.scene,C.current_scene,C.currentScene,C.world_scene,C.scene_name,C.sceneName),Ss=pt(C.location,C.current_location,C.currentLocation,C.position,C.zone,C.area);return{id:P,name:x(C.name,P),role:$s,keeper:kn,archetype:x(C.archetype,""),persona:x(C.persona,""),portrait:x(C.portrait,"")||void 0,background:x(C.background,"")||void 0,traits:Ot(C.traits),skills:Ot(C.skills),stats_raw:Bu(C),status:ye?"active":"dead",generation:hs,joined_at:ys||void 0,claimed_at:bs||void 0,last_seen:ks||void 0,scene:xs||void 0,location:Ss||void 0,inventory:Ot(C.inventory),notes:Ot(C.notes),relationships:qu(C.relationships),stats:{hp:j,max_hp:D,mp:Ut,max_mp:Q,level:H,xp:Lt,strength:Ct(C,"strength","str",10),dexterity:Ct(C,"dexterity","dex",10),constitution:Ct(C,"constitution","con",10),intelligence:Ct(C,"intelligence","int",10),wisdom:Ct(C,"wisdom","wis",10),charisma:Ct(C,"charisma","cha",10)}}}),u=_.filter(P=>P.status!=="dead"),f=wu(t,e),v={phase_open:ra(c.phase_open,!0),min_points:G(c.min_points,3),window:x(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},h=Object.entries(p).map(([P,T])=>{const C=m(T)?T:{};return{actor_id:P,score:G(C.score,0),last_reason:x(C.last_reason,"")||null,reasons:Ot(C.reasons)}}),A=_.reduce((P,T)=>(P[T.id]=T.name,P),{}),k=e.map(P=>Ju(P,A)),S=G(a.turn,1),b=x(a.phase,"round"),$=x(a.map,""),R=m(a.world)?a.world:{},M=$||x(R.ascii_map,x(R.map,"")),L=k.filter((P,T)=>{const C=e[T];if(!m(C))return!1;const D=m(C.payload)?C.payload:{};return G(D.turn,-1)===S}),J=(L.length>0?L:k).slice(-12),z=x(a.status,"active");return{session:{id:s,room:s,status:z==="ended"?"ended":z==="paused"?"paused":"active",round:S,actors:u,created_at:((Y=k[0])==null?void 0:Y.timestamp)??new Date().toISOString()},current_round:{round_number:S,phase:b,events:J,timestamp:((st=k[k.length-1])==null?void 0:st.timestamp)??new Date().toISOString()},map:M||void 0,join_gate:v,contribution_ledger:h,outcome:f,party:u,story_log:k,history:[]}}async function Vu(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await at(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Xu(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([at(`/api/v1/trpg/state${e}`),Vu(t)]);return Yu(n,s,t)}function Qu(t){return Kt("/api/v1/trpg/rounds/run",{room_id:t})}function Zu(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function tp(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Kt("/api/v1/trpg/dice/roll",e)}function ep(t,e){const n=Zu();return Kt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function np(t,e){var a;const n=(a=e.idempotencyKey)==null?void 0:a.trim(),s={room_id:t};return e.actor_id&&e.actor_id.trim()&&(s.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(s.name=e.name.trim()),e.role&&(s.role=e.role),e.archetype&&e.archetype.trim()&&(s.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(s.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(s.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(s.background=e.background.trim()),e.hp!=null&&(s.hp=e.hp),e.max_hp!=null&&(s.max_hp=e.max_hp),e.alive!=null&&(s.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(s.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(s.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(s.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(s.stats=e.stats),n&&(s.idempotency_key=n),Kt("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function sp(t,e,n){return Kt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function ap(t,e,n){const s=await fe("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function op(t){const e=await fe("trpg.mid_join.request",t);return JSON.parse(e)}async function ip(t,e){await fe("masc_broadcast",{agent_name:t,message:e})}async function rp(t=40){return(await fe("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function lp(t,e=20){return fe("masc_task_history",{task_id:t,limit:e})}async function cp(t){const e=await fe("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function dp(t){return Ja("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await at(`/api/v1/council/debates/${e}/summary`);if(!m(n))return null;const s=m(n.debate)?n.debate:n,a=x(s.id,"").trim(),i=x(s.topic,"").trim();return!a||!i?null:{debate:{id:a,topic:i,status:x(s.status,"open"),created_at:ut(s.created_at_iso??s.created_at),closed_at:ut(s.closed_at)},arguments:Array.isArray(n.arguments)?n.arguments.flatMap(l=>m(l)?[{index:G(l.index,0),agent:x(l.agent,"unknown"),position:x(l.position,"neutral"),content:x(l.content,""),evidence:Ot(l.evidence),reply_to:ft(l.reply_to)??null,mentions:Ot(l.mentions),archetype:U(l.archetype),created_at:ut(l.created_at)}]:[]):[],summary:{support_count:m(n.summary)?G(n.summary.support_count,0):G(n.support_count,0),oppose_count:m(n.summary)?G(n.summary.oppose_count,0):G(n.oppose_count,0),neutral_count:m(n.summary)?G(n.summary.neutral_count,0):G(n.neutral_count,0),total_arguments:m(n.summary)?G(n.summary.total_arguments,0):G(n.total_arguments,0),summary_text:m(n.summary)?x(n.summary.summary_text,""):x(n.summary_text,"")},context:Ai(n.context),judgment:Il(n.judgment)}})}async function up(t){return Ja("fetchConsensusSessionSummary",async()=>{const e=encodeURIComponent(t),n=await at(`/api/v1/council/sessions/${e}/summary`);if(!m(n)||!m(n.session))return null;const s=n.session,a=x(s.id,"").trim(),i=x(s.topic,"").trim();return!a||!i?null:{session:{id:a,topic:i,state:x(s.state,"open"),initiator:x(s.initiator,"system"),quorum:G(s.quorum,0),threshold:G(s.threshold,0),created_at:ut(s.created_at),closed_at:ut(s.closed_at)},votes:Array.isArray(n.votes)?n.votes.flatMap(l=>m(l)?[{agent:x(l.agent,"unknown"),decision:x(l.decision,"abstain"),reason:x(l.reason,""),timestamp:ut(l.timestamp),weight:typeof l.weight=="number"?l.weight:void 0,archetype:U(l.archetype)}]:[]):[],summary:{approve_count:m(n.summary)?G(n.summary.approve_count,0):0,reject_count:m(n.summary)?G(n.summary.reject_count,0):0,abstain_count:m(n.summary)?G(n.summary.abstain_count,0):0,quorum_met:m(n.summary)?ra(n.summary.quorum_met,!1):!1,result:m(n.summary)?U(n.summary.result):null},context:Ai(n.context),judgment:Il(n.judgment)}})}function pp(t,e,n){return fe("masc_keeper_msg",{name:t,message:e})}const mp=g(""),Vt=g({}),_t=g({}),Wo=g({}),Go=g({}),Jo=g({}),Yo=g({}),Xt=g({});function dt(t,e,n){t.value={...t.value,[e]:n}}function _p(t){var n;const e=(n=r(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function vp(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function oo(t,e){if(!Array.isArray(t))return[];const n=[];for(const s of t){if(!m(s))continue;const a=r(s.name);if(!a)continue;const i=r(s[e]);e==="summary"?n.push({name:a,summary:i}):n.push({name:a,reason:i})}return n}function fp(t){if(!m(t))return null;const e=r(t.name);return e?{name:e,trigger:r(t.trigger),outcome:r(t.outcome),summary:r(t.summary),reason:r(t.reason)}:null}function gp(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function $p(t,e,n){return r(t)??gp(e,n)}function hp(t,e){return typeof t=="boolean"?t:e==="recover"}function la(t){if(!m(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);return!e||!n||!s?null:{health_state:e,quiet_reason:r(t.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:rt(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:d(t.next_eligible_at_s)??null,recoverable:hp(t.recoverable,n),summary:$p(t.summary,e,r(t.quiet_reason)??null),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0,continuity_state:r(t.continuity_state)??null,continuity_summary:r(t.continuity_summary)??null}}function Rl(t){return m(t)?{hour:d(t.hour),checked:d(t.checked)??0,acted:d(t.acted)??0,acted_names:B(t.acted_names),activity_report:r(t.activity_report),quiet_hours_overridden:E(t.quiet_hours_overridden),skipped_reason:r(t.skipped_reason),acted_rows:oo(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:oo(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:oo(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(fp).filter(e=>e!==null):[]}:null}function yp(t){return m(t)?{enabled:E(t.enabled)??!1,interval_s:d(t.interval_s)??0,quiet_start:d(t.quiet_start),quiet_end:d(t.quiet_end),quiet_active:E(t.quiet_active),use_planner:E(t.use_planner),delegate_llm:E(t.delegate_llm),agent_count:d(t.agent_count),agents:B(t.agents),last_tick_ago_s:d(t.last_tick_ago_s)??null,last_tick_ago:r(t.last_tick_ago),total_ticks:d(t.total_ticks),total_checkins:d(t.total_checkins),last_skip_reason:r(t.last_skip_reason)??null,last_tick_result:Rl(t.last_tick_result),active_self_heartbeats:B(t.active_self_heartbeats)}:null}function bp(t){return m(t)?{status:t.status,diagnostic:la(t.diagnostic)}:null}function kp(t){return m(t)?{recovered:E(t.recovered)??!1,skipped_reason:r(t.skipped_reason)??null,before:la(t.before),after:la(t.after),down:t.down,up:t.up}:null}function xp(t,e){if(!m(t))return null;const n=_p(t.role),s=r(t.content)??r(t.preview);if(!s)return null;const a=rt(t.ts_unix)??rt(t.timestamp);return{id:`${n}-${a??"entry"}-${e}`,role:n,label:vp(n),text:s,timestamp:a,delivery:"history"}}function Sp(t,e,n){const s=m(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((i,l)=>xp(i,l)).filter(i=>i!==null):[];return{name:t,diagnostic:la(s==null?void 0:s.diagnostic),history:a,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function $r(t,e){const n=_t.value[t]??[];_t.value={..._t.value,[t]:[...n,e].slice(-50)}}function Cp(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Ap(t,e){const s=(_t.value[t]??[]).filter(a=>a.delivery!=="history"&&!e.some(i=>Cp(a,i)));_t.value={..._t.value,[t]:[...e,...s].slice(-50)}}function Va(t,e){Vt.value={...Vt.value,[t]:e},Ap(t,e.history)}function hr(t,e){const n=Vt.value[t];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Va(t,{...n,diagnostic:{...s,...e}})}async function Ti(){try{await ls()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Tp(t){mp.value=t.trim()}async function Ml(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Vt.value[n])return Vt.value[n];dt(Wo,n,!0),dt(Xt,n,null);try{const s=await fe("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const i=Sp(n,s,a);return Va(n,i),i}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return dt(Xt,n,a),null}finally{dt(Wo,n,!1)}}async function Ip(t,e){const n=t.trim(),s=e.trim();if(!n||!s)return;const a=`local-${Date.now()}`;$r(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),dt(Go,n,!0),dt(Xt,n,null);try{const i=await pp(n,s);_t.value={..._t.value,[n]:(_t.value[n]??[]).map(l=>l.id===a?{...l,delivery:"delivered"}:l)},$r(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),hr(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await Ti()}catch(i){const l=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw _t.value={..._t.value,[n]:(_t.value[n]??[]).map(c=>c.id===a?{...c,delivery:"error",error:l}:c)},hr(n,{last_reply_status:"error",last_error:l}),dt(Xt,n,l),i}finally{dt(Go,n,!1)}}async function zp(t,e){const n=t.trim();if(!n)return null;dt(Jo,n,!0),dt(Xt,n,null);try{const s=await Ya({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=bp(s.result),i=(a==null?void 0:a.diagnostic)??null;if(i){const l=Vt.value[n];Va(n,{name:n,diagnostic:i,history:(l==null?void 0:l.history)??_t.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Ti(),i}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw dt(Xt,n,a),s}finally{dt(Jo,n,!1)}}async function Rp(t,e){const n=t.trim();if(!n)return null;dt(Yo,n,!0),dt(Xt,n,null);try{const s=await Ya({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=kp(s.result),i=(a==null?void 0:a.after)??null;if(i){const l=Vt.value[n];Va(n,{name:n,diagnostic:i,history:(l==null?void 0:l.history)??_t.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Ti(),i}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw dt(Xt,n,a),s}finally{dt(Yo,n,!1)}}function Mp(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Lp(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}function Pp(t,e){const n=e.get(t.name);if(n!=null)return n;const s=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof a=="number"?Date.now()-a*1e3:null}function Np(t){return Array.isArray(t)?t.map(e=>{if(!m(e))return null;const n=d(e.ts_unix),s=d(e.context_ratio);if(n==null||s==null)return null;const a=m(e.handoff)?e.handoff:null;return{ts:n,context_ratio:s,context_tokens:d(e.context_tokens)??0,context_max:d(e.context_max)??0,latency_ms:d(e.latency_ms)??0,generation:d(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:d(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:d(e.cost_usd)??Number.NaN,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?d(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function jp(t){if(!m(t))return;const e={};for(const[n,s]of Object.entries(t)){if(n==="top_tools"){if(!Array.isArray(s))continue;const i=s.filter(l=>m(l)&&typeof l.tool=="string"&&l.tool.trim()!=="");i.length>0&&(e.top_tools=i);continue}const a=d(s);a!=null&&(e[n]=a)}return Object.keys(e).length>0?e:void 0}function Ep(t){if(!m(t))return null;const e=r(t.health_state),n=r(t.next_action_path),s=r(t.last_reply_status);if(!e||!n||!s)return null;const a=r(t.quiet_reason)??null;return{health_state:e,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:rt(t.last_reply_at)??r(t.last_reply_at)??null,last_reply_preview:r(t.last_reply_preview)??null,last_error:r(t.last_error)??null,next_eligible_at_s:d(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:n==="recover",summary:r(t.summary),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function Op(t){return(Array.isArray(t)?t:m(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!m(n))return null;const s=m(n.agent)?n.agent:null,a=m(n.context)?n.context:null,i=jp(n.metrics_window),l=r(n.name);if(!l)return null;const c=d(n.context_ratio)??d(a==null?void 0:a.context_ratio),p=r(n.status)??r(s==null?void 0:s.status)??"offline",_=r(n.model)??r(n.active_model)??r(n.primary_model),u=B(n.skill_secondary),f=Np(n.metrics_series),v=a?{source:r(a.source),context_ratio:d(a.context_ratio),context_tokens:d(a.context_tokens),context_max:d(a.context_max),message_count:d(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,h=s?{name:r(s.name),exists:typeof s.exists=="boolean"?s.exists:void 0,error:r(s.error),agent_type:r(s.agent_type),status:r(s.status),current_task:r(s.current_task)??null,joined_at:r(s.joined_at),last_seen:r(s.last_seen),last_seen_ago_s:d(s.last_seen_ago_s),capabilities:B(s.capabilities),is_zombie:typeof s.is_zombie=="boolean"?s.is_zombie:void 0}:void 0;return{name:l,runtime_class:n.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:typeof n.desired=="boolean"?n.desired:void 0,resident_registered:typeof n.resident_registered=="boolean"?n.resident_registered:void 0,reconcile_status:r(n.reconcile_status)??null,emoji:r(n.emoji),koreanName:r(n.koreanName)??r(n.korean_name),agent_name:r(n.agent_name),trace_id:r(n.trace_id),model:_,primary_model:r(n.primary_model),active_model:r(n.active_model),next_model_hint:r(n.next_model_hint)??null,status:Mp(p),presence_keepalive:typeof n.presence_keepalive=="boolean"?n.presence_keepalive:void 0,presence_keepalive_sec:d(n.presence_keepalive_sec),keepalive_running:typeof n.keepalive_running=="boolean"?n.keepalive_running:void 0,proactive_enabled:typeof n.proactive_enabled=="boolean"?n.proactive_enabled:void 0,proactive_idle_sec:d(n.proactive_idle_sec),proactive_cooldown_sec:d(n.proactive_cooldown_sec),last_heartbeat:r(n.last_heartbeat)??r(s==null?void 0:s.last_seen),generation:d(n.generation),turn_count:d(n.turn_count)??d(n.total_turns),keeper_age_s:d(n.keeper_age_s),last_turn_ago_s:d(n.last_turn_ago_s),last_handoff_ago_s:d(n.last_handoff_ago_s),last_compaction_ago_s:d(n.last_compaction_ago_s),last_proactive_ago_s:d(n.last_proactive_ago_s),last_proactive_preview:r(n.last_proactive_preview)??null,context_ratio:c,context_tokens:d(n.context_tokens)??d(a==null?void 0:a.context_tokens),context_max:d(n.context_max)??d(a==null?void 0:a.context_max),context_source:r(n.context_source)??r(a==null?void 0:a.source),context:v,traits:B(n.traits),interests:B(n.interests),primaryValue:r(n.primaryValue)??r(n.primary_value),activityLevel:d(n.activityLevel)??d(n.activity_level),memory_recent_note:r(n.memory_recent_note)??null,recent_input_preview:r(n.recent_input_preview)??null,recent_output_preview:r(n.recent_output_preview)??null,recent_tool_names:B(n.recent_tool_names)??[],allowed_tool_names:B(n.allowed_tool_names)??[],latest_tool_names:B(n.latest_tool_names)??[],latest_tool_call_count:d(n.latest_tool_call_count)??null,tool_audit_source:r(n.tool_audit_source)??null,tool_audit_at:rt(n.tool_audit_at)??r(n.tool_audit_at)??null,conversation_tail_count:d(n.conversation_tail_count),k2k_count:d(n.k2k_count),handoff_count_total:d(n.handoff_count_total)??d(n.trace_history_count),compaction_count:d(n.compaction_count),last_compaction_saved_tokens:d(n.last_compaction_saved_tokens),diagnostic:Ep(n.diagnostic),skill_primary:r(n.skill_primary)??null,skill_secondary:u,skill_reason:r(n.skill_reason)??null,metrics_series:f.length>0?f:void 0,metrics_window:i,agent:h}}).filter(n=>n!==null)}function be(t){return(t??"").trim().toLowerCase()}function ht(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Gs(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function As(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function xn(t){return t.last_heartbeat??As(t.last_turn_ago_s)??As(t.last_proactive_ago_s)??As(t.last_handoff_ago_s)??As(t.last_compaction_ago_s)}function Dp(t){const e=t.title.trim();return e||Gs(t.content)}function wp(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function qp(t,e,n,s,a={}){var R;const i=be(t),l=e.filter(M=>be(M.assignee)===i&&(M.status==="claimed"||M.status==="in_progress")).length,c=n.filter(M=>be(M.from)===i).sort((M,L)=>ht(L.timestamp)-ht(M.timestamp))[0],p=s.filter(M=>be(M.agent)===i||be(M.author)===i).sort((M,L)=>ht(L.timestamp)-ht(M.timestamp))[0],_=(a.boardPosts??[]).filter(M=>be(M.author)===i).sort((M,L)=>ht(L.updated_at||L.created_at)-ht(M.updated_at||M.created_at))[0],u=(a.keepers??[]).filter(M=>be(M.name)===i&&xn(M)!==null).sort((M,L)=>ht(xn(L)??0)-ht(xn(M)??0))[0],f=c?ht(c.timestamp):0,v=p?ht(p.timestamp):0,h=_?ht(_.updated_at||_.created_at):0,A=u?ht(xn(u)??0):0,k=a.lastSeen?ht(a.lastSeen):0,S=((R=a.currentTask)==null?void 0:R.trim())||(l>0?`${l} claimed tasks`:null);if(f===0&&v===0&&h===0&&A===0&&k===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:S};const $=[c?{timestamp:c.timestamp,ts:f,text:Gs(c.content)}:null,_?{timestamp:_.updated_at||_.created_at,ts:h,text:`Post: ${Gs(Dp(_))}`}:null,u?{timestamp:xn(u),ts:A,text:wp(u)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:v,text:Gs(p.text)}:null].filter(M=>M!==null).sort((M,L)=>L.ts-M.ts)[0];return $&&$.ts>=k?{activeAssignedCount:l,lastActivityAt:$.timestamp,lastActivityText:$.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:S??"Presence heartbeat"}}const Qt=g([]),oe=g([]),Vo=g([]),ge=g([]),lt=g(null),Fp=g(null),Ll=g(null),Pl=g([]),Nl=g([]),jl=g([]),El=g([]),Ol=g(null),Ii=g([]),zi=g([]),Dl=g([]),Xo=g(new Map),Xa=g([]),Kn=g("recent"),Ie=g(!0),wl=g(null),Yt=g(""),Ze=g([]),Rn=g(!1),ql=g(new Map),Ri=g("unknown"),tn=g(null),Qo=g(!1),Bn=g(!1),Zo=g(!1),Mn=g(!1),Mi=g(null),ca=g(!1),da=g(null),Fl=g(null),ti=g(null),Kp=g(null),Bp=g(null),Up=g(null);Mt(()=>Qt.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle"));const Kl=Mt(()=>{const t=oe.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}}),Bl=Mt(()=>{const t=new Map,e=oe.value,n=Vo.value,s=ia.value,a=Xa.value,i=ge.value;for(const l of Qt.value)t.set(l.name.trim().toLowerCase(),qp(l.name,e,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:i}));return t});Mt(()=>{var e;const t=new Map;for(const n of ge.value){const s=((e=n.status)==null?void 0:e.toLowerCase())??"";if(s==="offline"||s==="inactive"){t.set(n.name,"offline");continue}!n.metrics_series||n.metrics_series.length===0||t.set(n.name,Lp(n))}return t});const Hp=12e4;Mt(()=>{const t=Date.now(),e=new Set,n=Xo.value;for(const s of ge.value){const a=Pp(s,n);a!=null&&t-a>Hp&&e.add(s.name)}return e});function Wp(t){return t==="dashboard_refresh"||t==="masc/dashboard_refresh"||t.startsWith("goal_")||t.startsWith("masc/goal_")||t.startsWith("mdal_")||t.startsWith("masc/mdal_")||t.startsWith("operator_")||t.startsWith("masc/operator_")||t.startsWith("command_plane_")||t.startsWith("masc/command_plane_")}function Gp(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="busy"||e==="listening"||e==="idle"||e==="inactive"||e==="offline"?e:e==="in_progress"||e==="claimed"?"busy":"offline"}function Jp(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Yp(t){if(!m(t))return null;const e=r(t.name);return e?{name:e,agent_type:r(t.agent_type),status:Gp(t.status),current_task:r(t.current_task)??null,joined_at:r(t.joined_at),last_seen:r(t.last_seen),capabilities:B(t.capabilities),emoji:r(t.emoji),koreanName:r(t.koreanName)??r(t.korean_name),model:r(t.model),traits:B(t.traits),interests:B(t.interests),activityLevel:d(t.activityLevel)??d(t.activity_level),primaryValue:r(t.primaryValue)??r(t.primary_value)}:null}function Vp(t){if(!m(t))return null;const e=r(t.id),n=r(t.title);return!e||!n?null:{id:e,title:n,status:Jp(t.status),priority:d(t.priority),assignee:r(t.assignee),description:r(t.description),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function Xp(t){if(!m(t))return null;const e=r(t.from)??r(t.from_agent)??"system",n=r(t.content)??"",s=r(t.timestamp)??new Date().toISOString();return{id:r(t.id),seq:d(t.seq),from:e,content:n,timestamp:s,type:r(t.type)}}function Li(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="ok"||e==="warn"||e==="bad"?e:"ok"}function Qp(t){return m(t)?{active_sessions:d(t.active_sessions),blocked_sessions:d(t.blocked_sessions),active_operations:d(t.active_operations),blocked_operations:d(t.blocked_operations),runtime_pressure:d(t.runtime_pressure),worker_alerts:d(t.worker_alerts),continuity_alerts:d(t.continuity_alerts),priority_items:d(t.priority_items),todo_tasks:d(t.todo_tasks),claimed_tasks:d(t.claimed_tasks),running_tasks:d(t.running_tasks),done_tasks:d(t.done_tasks),cancelled_tasks:d(t.cancelled_tasks),keepers:d(t.keepers)}:null}function ie(t){if(!m(t))return null;const e=r(t.surface),n=r(t.label),s=r(t.target_type),a=r(t.target_id),i=r(t.focus_kind);return!e||!n||!s||!a||!i?null:{surface:e==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:i,operation_id:r(t.operation_id)??null,command_surface:r(t.command_surface)??null}}function Zp(t){if(!m(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.summary),a=r(t.target_type),i=r(t.target_id);return!e||!s||!a||!i||n!=="session"&&n!=="operation"?null:{id:e,kind:n,severity:Li(t.severity),status:r(t.status),summary:s,target_type:a,target_id:i,linked_session_id:r(t.linked_session_id)??null,linked_operation_id:r(t.linked_operation_id)??null,last_seen_at:r(t.last_seen_at)??null,top_handoff:ie(t.top_handoff),intervene_handoff:ie(t.intervene_handoff),command_handoff:ie(t.command_handoff)}}function tm(t){if(!m(t))return null;const e=r(t.session_id),n=r(t.goal);return!e||!n?null:{session_id:e,goal:n,room:r(t.room)??null,status:r(t.status),health:r(t.health),member_names:B(t.member_names),linked_operation_id:r(t.linked_operation_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,runtime_blocker:r(t.runtime_blocker)??null,worker_gap_summary:r(t.worker_gap_summary)??null,last_activity_at:r(t.last_activity_at)??null,last_activity_summary:r(t.last_activity_summary)??null,communication_summary:r(t.communication_summary)??null,active_count:d(t.active_count),required_count:d(t.required_count),top_handoff:ie(t.top_handoff),intervene_handoff:ie(t.intervene_handoff),command_handoff:ie(t.command_handoff)}}function em(t){if(!m(t))return null;const e=r(t.operation_id),n=r(t.objective);return!e||!n?null:{operation_id:e,objective:n,status:r(t.status),stage:r(t.stage)??null,assigned_unit_id:r(t.assigned_unit_id)??null,assigned_unit_label:r(t.assigned_unit_label)??null,linked_session_id:r(t.linked_session_id)??null,linked_detachment_id:r(t.linked_detachment_id)??null,blocker_summary:r(t.blocker_summary)??null,search_status:r(t.search_status)??null,next_tool:r(t.next_tool)??null,updated_at:r(t.updated_at)??null,top_handoff:ie(t.top_handoff),command_handoff:ie(t.command_handoff)}}function yr(t){if(!m(t))return null;const e=r(t.name)??r(t.agent_name),n=r(t.note),s=r(t.focus),a=r(t.state);return!e||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline"?null:{name:e,agent_name:r(t.agent_name),status:r(t.status),tone:Li(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,active_task_count:d(t.active_task_count),related_session_id:r(t.related_session_id)??null,related_operation_id:r(t.related_operation_id)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),model:r(t.model)??null,recent_output_preview:r(t.recent_output_preview)??null,recent_event:r(t.recent_event)??null}}function nm(t){return m(t)?{checked:d(t.checked),acted:d(t.acted),passed:d(t.passed),skipped:d(t.skipped),failed:d(t.failed),last_tick_at:r(t.last_tick_at)??null,last_skip_reason:r(t.last_skip_reason)??null,activity_report:r(t.activity_report)??null}:null}function sm(t){if(!m(t))return null;const e=r(t.agent_name),n=r(t.outcome);return!e||!n?null:{agent_name:e,trigger:r(t.trigger)??null,outcome:n,summary:r(t.summary)??null,reason:r(t.reason)??null,allowed_tool_names:B(t.allowed_tool_names)??[],used_tool_names:B(t.used_tool_names)??[],used_tool_call_count:d(t.used_tool_call_count)??null,action_kind:r(t.action_kind)??"none",tool_audit_source:r(t.tool_audit_source)??null,tool_audit_at:r(t.tool_audit_at)??null,checked_at:r(t.checked_at)??null,decision_reason:r(t.decision_reason)??null,worker_name:r(t.worker_name)??null,failure_reason:r(t.failure_reason)??null}}function am(t){if(!m(t))return null;const e=r(t.name),n=r(t.note),s=r(t.focus),a=r(t.state);return!e||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:e,agent_name:r(t.agent_name)??null,status:r(t.status),tone:Li(t.tone),state:a,note:n,focus:s,last_signal_at:r(t.last_signal_at)??null,last_autonomous_action_at:r(t.last_autonomous_action_at)??null,generation:d(t.generation),turn_count:d(t.turn_count),context_ratio:d(t.context_ratio)??null,continuity:r(t.continuity)??null,lifecycle:r(t.lifecycle)??null,related_session_id:r(t.related_session_id)??null,model:r(t.model)??null,emoji:r(t.emoji),korean_name:r(t.korean_name),skill_reason:r(t.skill_reason)??null,recent_input_preview:r(t.recent_input_preview)??null,recent_output_preview:r(t.recent_output_preview)??null,recent_tool_names:B(t.recent_tool_names)??[],allowed_tool_names:B(t.allowed_tool_names)??[],latest_tool_names:B(t.latest_tool_names)??[],latest_tool_call_count:d(t.latest_tool_call_count)??null,tool_audit_source:r(t.tool_audit_source)??null,tool_audit_at:r(t.tool_audit_at)??null,last_proactive_preview:r(t.last_proactive_preview)??null,continuity_summary:r(t.continuity_summary)??null,skill_route_summary:r(t.skill_route_summary)??null}}function br(t){if(typeof t.seq=="number"&&Number.isFinite(t.seq))return t.seq;const e=Date.parse(t.timestamp);return Number.isNaN(e)?0:e}function om(t,e){if(e.length===0)return t;const n=new Map;for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>br(s)-br(a)).slice(-500)}function im(t){if(!m(t))return;const e=r(t.release_version),n=rt(t.started_at),s=d(t.uptime_seconds);if(!(!e||!n||s==null))return{release_version:e,commit:r(t.commit)??null,started_at:n,uptime_seconds:s}}function rm(t){if(m(t))return{enabled:t.enabled===!0,alive:t.alive===!0,status:r(t.status)??void 0,tick_in_progress:typeof t.tick_in_progress=="boolean"?t.tick_in_progress:void 0,tick_count:d(t.tick_count)??void 0,check_interval_sec:d(t.check_interval_sec)??void 0,last_tick_started_at:rt(t.last_tick_started_at)??r(t.last_tick_started_at)??null,last_tick_completed_at:rt(t.last_tick_completed_at)??r(t.last_tick_completed_at)??null,next_tick_due_at:rt(t.next_tick_due_at)??r(t.next_tick_due_at)??null,last_health_check_at:rt(t.last_health_check_at)??r(t.last_health_check_at)??null,last_intervention:r(t.last_intervention)??void 0,last_decision_source:r(t.last_decision_source)??void 0,last_action:r(t.last_action)??void 0,last_target:r(t.last_target)??null,last_reason:r(t.last_reason)??null,last_error:r(t.last_error)??null,circuit_open:typeof t.circuit_open=="boolean"?t.circuit_open:void 0,circuit_open_until:rt(t.circuit_open_until)??r(t.circuit_open_until)??null,can_spawn:typeof t.can_spawn=="boolean"?t.can_spawn:void 0,can_retire:typeof t.can_retire=="boolean"?t.can_retire:void 0,last_spawn_attempt_at:rt(t.last_spawn_attempt_at)??r(t.last_spawn_attempt_at)??null,last_retirement_attempt_at:rt(t.last_retirement_attempt_at)??r(t.last_retirement_attempt_at)??null,spawns_today:d(t.spawns_today)??void 0,retirements_today:d(t.retirements_today)??void 0,health_summary:m(t.health_summary)?{total_agents:d(t.health_summary.total_agents)??void 0,active_agents:d(t.health_summary.active_agents)??void 0,idle_agents:d(t.health_summary.idle_agents)??void 0,todo_count:d(t.health_summary.todo_count)??void 0,high_priority_todo:d(t.health_summary.high_priority_todo)??void 0,orphan_count:d(t.health_summary.orphan_count)??void 0,homeostatic_score:d(t.health_summary.homeostatic_score)??void 0,needs_workers:typeof t.health_summary.needs_workers=="boolean"?t.health_summary.needs_workers:void 0}:void 0}}function lm(t){if(m(t))return{enabled:t.enabled===!0,mode:r(t.mode)??void 0,masc_enabled:typeof t.masc_enabled=="boolean"?t.masc_enabled:void 0,masc_loops_running:typeof t.masc_loops_running=="boolean"?t.masc_loops_running:void 0,runtime_owner:r(t.runtime_owner)??null,zombie_loop_running:typeof t.zombie_loop_running=="boolean"?t.zombie_loop_running:void 0,gc_loop_running:typeof t.gc_loop_running=="boolean"?t.gc_loop_running:void 0,lodge_enabled:typeof t.lodge_enabled=="boolean"?t.lodge_enabled:void 0,lodge_loop_started:typeof t.lodge_loop_started=="boolean"?t.lodge_loop_started:void 0,lodge_running:typeof t.lodge_running=="boolean"?t.lodge_running:void 0,last_zombie_cleanup:rt(t.last_zombie_cleanup)??r(t.last_zombie_cleanup)??null,last_gc:rt(t.last_gc)??r(t.last_gc)??null,last_lodge:rt(t.last_lodge)??r(t.last_lodge)??null,last_zombie_result:r(t.last_zombie_result)??null,last_gc_result:r(t.last_gc_result)??null,last_lodge_result:m(t.last_lodge_result)?{ok:typeof t.last_lodge_result.ok=="boolean"?t.last_lodge_result.ok:void 0,message:r(t.last_lodge_result.message)??void 0}:null}}function cm(t){if(m(t))return{enabled:t.enabled===!0,started:t.started===!0,agent_name:r(t.agent_name)??null,llm_enabled:typeof t.llm_enabled=="boolean"?t.llm_enabled:void 0,uptime_s:d(t.uptime_s)??void 0,embedded_guardian_loops_running:typeof t.embedded_guardian_loops_running=="boolean"?t.embedded_guardian_loops_running:void 0,guardian_runtime_owner:r(t.guardian_runtime_owner)??null,consumers:B(t.consumers)}}function Ul(t,e){return m(t)?{...t,generated_at:e??rt(t.generated_at)??void 0,build:im(t.build),lodge:yp(t.lodge)??void 0,gardener:rm(t.gardener)??void 0,guardian:lm(t.guardian)??void 0,sentinel:cm(t.sentinel)??void 0}:null}function Hl(t,e){return e?t?{...t,...e,build:e.build??t.build,generated_at:e.generated_at??t.generated_at}:e:t}function dm(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="running"||e==="interrupted"||e==="completed"||e==="stopped"||e==="error"?e:e.startsWith("error")?"error":"running"}function um(t){if(!m(t))return null;const e=d(t.iteration);if(e==null)return null;const n=d(t.metric_before)??0,s=d(t.metric_after)??n,a=m(t.evidence)?t.evidence:null;return{iteration:e,metric_before:n,metric_after:s,delta:d(t.delta)??s-n,changes:r(t.changes)??"",failed_attempts:r(t.failed_attempts)??"",next_suggestion:r(t.next_suggestion)??"",elapsed_ms:d(t.elapsed_ms)??0,cost_usd:d(t.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:d(a.tool_call_count)??0,tool_names:B(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function pm(t){var i,l;if(!m(t))return null;const e=r(t.loop_id);if(!e)return null;const n=d(t.baseline_metric)??0,s=Array.isArray(t.history)?t.history.map(um).filter(c=>c!==null):[],a=d(t.current_metric)??((i=s[0])==null?void 0:i.metric_after)??n;return{loop_id:e,profile:r(t.profile)??"unknown",status:dm(t.status),strict_mode:typeof t.strict_mode=="boolean"?t.strict_mode:void 0,error_message:r(t.error_message)??r(t.error_reason)??null,stop_reason:r(t.stop_reason)??r(t.reason)??null,current_iteration:d(t.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:d(t.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(t.target)??"",stagnation_streak:d(t.stagnation_streak)??0,stagnation_limit:d(t.stagnation_limit)??0,elapsed_seconds:d(t.elapsed_seconds)??0,updated_at:rt(t.updated_at)??null,stopped_at:rt(t.stopped_at)??null,execution_mode:t.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:t.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(t.worker_model)??null,evidence_policy:t.evidence_policy==="hard"||t.evidence_policy==="legacy"?t.evidence_policy:void 0,latest_tool_call_count:d(t.latest_tool_call_count)??0,latest_tool_names:B(t.latest_tool_names)??[],session_id:r(t.session_id)??null,evidence_status:t.evidence_status==="legacy_unverified"?"legacy_unverified":t.evidence_status==="verified"?"verified":null,durability:t.durability==="persistent_backend"||t.durability==="memory_only"?t.durability:void 0,persistence_backend:t.persistence_backend==="filesystem"||t.persistence_backend==="postgres"||t.persistence_backend==="memory"?t.persistence_backend:void 0,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,history:s}}async function ls(){Qo.value=!0;try{await Promise.all([Gl(),ze()]),Fl.value=new Date().toISOString()}catch(t){console.error("Dashboard refresh error:",t)}finally{Qo.value=!1}}async function Wl(){ca.value=!0,da.value=null;try{const t=await uu();Mi.value=t,Up.value=new Date().toISOString()}catch(t){da.value=t instanceof Error?t.message:"Failed to load dashboard semantics"}finally{ca.value=!1}}function mm(t){var e;return((e=Mi.value)==null?void 0:e.surfaces.find(n=>n.id===t))??null}function _m(t){var n;const e=((n=Mi.value)==null?void 0:n.surfaces)??[];for(const s of e){const a=s.panels.find(i=>i.id===t);if(a)return a}return null}function vm(t){var s,a;Ze.value=(Array.isArray(t.goals)?t.goals:[]).map(i=>{if(!m(i))return null;const l=r(i.id),c=r(i.title),p=r(i.horizon),_=r(i.status),u=r(i.created_at),f=r(i.updated_at);return!l||!c||!p||!_||!u||!f?null:{id:l,horizon:p,title:c,metric:r(i.metric)??null,target_value:r(i.target_value)??null,due_date:r(i.due_date)??null,priority:d(i.priority)??3,status:_,parent_goal_id:r(i.parent_goal_id)??null,last_review_note:r(i.last_review_note)??null,last_review_at:r(i.last_review_at)??null,created_at:u,updated_at:f}}).filter(i=>i!==null);const e=new Map,n=Array.isArray((s=t.mdal)==null?void 0:s.loops)?t.mdal.loops:[];for(const i of n){const l=pm(i);l&&e.set(l.loop_id,l)}ql.value=e,tn.value=typeof((a=t.mdal)==null?void 0:a.error)=="string"?t.mdal.error:null,Ri.value=tn.value?"error":e.size===0?"idle":"ready"}async function Gl(){try{const t=await iu(),e=Ul(t.status,t.generated_at);e&&(lt.value=Hl(lt.value,e))}catch(t){console.error("Dashboard shell fetch error:",t)}}async function ze(){var t;try{const e=await lu(),n=Ul(e.status,e.generated_at),s=(t=lt.value)==null?void 0:t.room;n&&(lt.value=Hl(lt.value,n));const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Qt.value=(Array.isArray(e.agents)?e.agents:[]).map(Yp).filter(l=>l!==null),oe.value=(Array.isArray(e.tasks)?e.tasks:[]).map(Vp).filter(l=>l!==null);const i=(Array.isArray(e.messages)?e.messages:[]).map(Xp).filter(l=>l!==null);Vo.value=a?i:om(Vo.value,i),ge.value=Op(e.keepers),Ll.value=Qp(e.summary),Ol.value=nm(e.lodge_tick),Ii.value=(Array.isArray(e.lodge_checkins)?e.lodge_checkins:[]).map(sm).filter(l=>l!==null),Pl.value=(Array.isArray(e.execution_queue)?e.execution_queue:Array.isArray(e.priority_queue)?e.priority_queue:[]).map(Zp).filter(l=>l!==null),Nl.value=(Array.isArray(e.session_briefs)?e.session_briefs:[]).map(tm).filter(l=>l!==null),jl.value=(Array.isArray(e.operation_briefs)?e.operation_briefs:[]).map(em).filter(l=>l!==null),El.value=(Array.isArray(e.worker_support_briefs)?e.worker_support_briefs:Array.isArray(e.worker_briefs)?e.worker_briefs:[]).map(yr).filter(l=>l!==null),zi.value=(Array.isArray(e.continuity_briefs)?e.continuity_briefs:[]).map(am).filter(l=>l!==null),Dl.value=(Array.isArray(e.offline_worker_briefs)?e.offline_worker_briefs:[]).map(yr).filter(l=>l!==null),Fp.value=null,Fl.value=new Date().toISOString()}catch(e){console.error("Dashboard execution fetch error:",e)}}async function re(){Bn.value=!0;try{const t=await cu(Kn.value,{excludeSystem:Ie.value});Xa.value=t.posts??[],ti.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{Bn.value=!1}}async function le(){var t;Zo.value=!0;try{const e=Yt.value||((t=lt.value)==null?void 0:t.room)||"default";Yt.value||(Yt.value=e);const n=await Xu(e);wl.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Zo.value=!1}}async function Pi(){Rn.value=!0,Mn.value=!0;try{const t=await fu();vm(t),Kp.value=new Date().toISOString(),Bp.value=new Date().toISOString()}catch(t){console.error("Planning fetch error:",t),Ri.value="error",tn.value=t instanceof Error?t.message:String(t)}finally{Rn.value=!1,Mn.value=!1}}async function Jl(){return Pi()}const Ni=g(null),ei=g(!1),ua=g(null);function fm(t){return m(t)?{room:r(t.room)??r(t.current_room),room_base_path:r(t.room_base_path),cluster:r(t.cluster),project:r(t.project),paused:E(t.paused),version:r(t.version),generated_at:r(t.generated_at),tempo_interval_s:d(t.tempo_interval_s)}:null}function gm(t){return m(t)?{active_sessions:d(t.active_sessions),blocked_sessions:d(t.blocked_sessions),active_operations:d(t.active_operations),blocked_operations:d(t.blocked_operations),runtime_pressure:d(t.runtime_pressure),worker_alerts:d(t.worker_alerts),continuity_alerts:d(t.continuity_alerts),priority_items:d(t.priority_items),keepers:d(t.keepers)}:null}function $m(t){if(!m(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.severity),a=r(t.summary),i=r(t.target_type),l=r(t.target_id);return!e||!n||!s||!a||!i||!l?null:{id:e,kind:n,severity:s,summary:a,target_type:i,target_id:l,status:r(t.status),linked_session_id:r(t.linked_session_id)??null,linked_operation_id:r(t.linked_operation_id)??null,last_seen_at:r(t.last_seen_at)??null,top_handoff:m(t.top_handoff)?t.top_handoff:null,intervene_handoff:m(t.intervene_handoff)?t.intervene_handoff:null,command_handoff:m(t.command_handoff)?t.command_handoff:null}}function hm(t){if(!m(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function ym(t){if(!m(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:E(t.confirm_required),suggested_payload:m(t.suggested_payload)?t.suggested_payload:void 0,preview:t.preview}}function bm(t){return m(t)?{actor_filter:r(t.actor_filter)??null,filter_active:E(t.filter_active)??!1,visible_count:d(t.visible_count)??0,total_count:d(t.total_count)??0,hidden_count:d(t.hidden_count)??0,hidden_actors:B(t.hidden_actors),confirm_required_actions:mt(t.confirm_required_actions).flatMap(e=>{if(!m(e))return[];const n=r(e.action_type),s=r(e.target_type);return!n||!s?[]:[{action_type:n,target_type:s,description:r(e.description),confirm_required:E(e.confirm_required)}]})}:null}function km(t){return m(t)?{count:d(t.count)??0,bad_count:d(t.bad_count)??0,warn_count:d(t.warn_count)??0,provenance:r(t.provenance)??null,top_item:hm(t.top_item)}:null}function xm(t){return m(t)?{count:d(t.count)??0,provenance:r(t.provenance)??null,top_action:ym(t.top_action)}:null}function Sm(t){if(!m(t))return null;const e=r(t.label),n=r(t.reason),s=r(t.source),a=r(t.provenance);return!e||!n||!s||!a?null:{label:e,reason:n,source:s,provenance:a,target_kind:r(t.target_kind)??null,target_id:r(t.target_id)??null,suggested_tab:r(t.suggested_tab)??null,suggested_surface:r(t.suggested_surface)??null,suggested_params:m(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([i,l])=>{const c=r(l);return c?[i,c]:null}).filter(i=>i!==null)):{}}}function Cm(t){const e=m(t)?t:{},n=m(e.room)?e.room:{},s=m(e.execution)?e.execution:{},a=m(e.command)?e.command:{},i=m(e.operator)?e.operator:{};return{generated_at:r(e.generated_at),room:{status:fm(n.status),counts:m(n.counts)?{agents:d(n.counts.agents),tasks:d(n.counts.tasks),keepers:d(n.counts.keepers)}:void 0,provenance:r(n.provenance)??null},execution:{summary:gm(s.summary),top_queue:$m(s.top_queue),provenance:r(s.provenance)??null},command:{active_operations:d(a.active_operations),active_detachments:d(a.active_detachments),pending_approvals:d(a.pending_approvals),bad_alerts:d(a.bad_alerts),warn_alerts:d(a.warn_alerts),moving_lanes:d(a.moving_lanes),active_lanes:d(a.active_lanes),provenance:r(a.provenance)??null},operator:{health:r(i.health)??null,attention_summary:km(i.attention_summary),recommendation_summary:xm(i.recommendation_summary),pending_confirm_summary:bm(i.pending_confirm_summary),provenance:r(i.provenance)??null},focus:Sm(e.focus)}}async function Re(){ei.value=!0,ua.value=null;try{const t=await ru();Ni.value=Cm(t)}catch(t){ua.value=t instanceof Error?t.message:"Failed to load room truth"}finally{ei.value=!1}}let Js=null;function Am(t){Js=t}let Ys=null;function Tm(t){Ys=t}let Vs=null;function Im(t){Vs=t}const Me={};let io=null;function ke(t,e,n=500){Me[t]&&clearTimeout(Me[t]),Me[t]=setTimeout(()=>{e(),delete Me[t]},n)}function zm(){const t=fl.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Xo.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Xo.value=n;return}(e.type==="agent_joined"||e.type==="agent_left")&&ke("execution",ze),Wp(e.type)&&(io||(io=setTimeout(()=>{ls(),Ys==null||Ys(),Vs==null||Vs(),io=null},500))),(e.type.startsWith("task_")||e.type.startsWith("masc/task_"))&&ke("execution",ze),e.type==="broadcast"&&ke("execution",ze),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&ke("execution",ze),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&ke("board",re),e.type.startsWith("decision_")&&ke("council",()=>Js==null?void 0:Js()),(e.type==="mdal_started"||e.type==="mdal_iteration"||e.type==="mdal_completed"||e.type==="mdal_stopped")&&ke("mdal",Jl,350)}});return()=>{t();for(const e of Object.keys(Me))clearTimeout(Me[e]),delete Me[e]}}let Ln=null;function Rm(){Ln||(Ln=setInterval(()=>{pe.value,ls()},1e4))}function Mm(){Ln&&(clearInterval(Ln),Ln=null)}const $t=g(null),ji=g(null),Ft=g(null),Un=g(!1),me=g(null),Hn=g(!1),un=g(null),Z=g(!1),pa=g([]);let Lm=1;function Pm(t){return m(t)?{id:r(t.id),seq:d(t.seq),from:r(t.from)??r(t.from_agent)??"system",content:r(t.content)??"",timestamp:r(t.timestamp)??new Date().toISOString(),type:r(t.type)}:null}function Nm(t){return m(t)?{room_id:r(t.room_id),current_room:r(t.current_room)??r(t.room),project:r(t.project),cluster:r(t.cluster),paused:E(t.paused),pause_reason:r(t.pause_reason)??null,paused_by:r(t.paused_by)??null,paused_at:r(t.paused_at)??null}:{}}function kr(t){if(!m(t))return;const e=Object.entries(t).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Yl(t){if(!m(t))return null;const e=r(t.kind),n=r(t.summary),s=r(t.target_type);return!e||!n||!s?null:{kind:e,severity:r(t.severity)??"warn",summary:n,target_type:s,target_id:r(t.target_id)??null,actor:r(t.actor)??null,evidence:t.evidence}}function Pn(t){if(!m(t))return null;const e=r(t.action_type),n=r(t.target_type),s=r(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:r(t.target_id)??null,severity:r(t.severity)??"warn",reason:s,confirm_required:E(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Vl(t){return m(t)?{enabled:E(t.enabled),judge_online:E(t.judge_online),refreshing:E(t.refreshing),generated_at:r(t.generated_at)??null,expires_at:r(t.expires_at)??null,model_used:r(t.model_used)??null,keeper_name:r(t.keeper_name)??null,last_error:r(t.last_error)??null}:null}function ro(t){return m(t)?{summary:r(t.summary)??null,confidence:d(t.confidence)??null,provenance:r(t.provenance)??null,authoritative:E(t.authoritative),surface:r(t.surface)??null,fresh_until:r(t.fresh_until)??null,keeper_name:r(t.keeper_name)??null,fallback_used:E(t.fallback_used),disagreement_with_truth:E(t.disagreement_with_truth)}:null}function jm(t){return m(t)?{judgment_id:r(t.judgment_id)??void 0,surface:r(t.surface)??null,target_type:r(t.target_type)??null,target_id:r(t.target_id)??null,status:r(t.status)??null,summary:r(t.summary)??null,confidence:d(t.confidence)??null,generated_at:r(t.generated_at)??null,fresh_until:r(t.fresh_until)??null,keeper_name:r(t.keeper_name)??null,model_name:r(t.model_name)??null,runtime_name:r(t.runtime_name)??null,evidence_refs:B(t.evidence_refs),recommended_action:Pn(t.recommended_action),supersedes:B(t.supersedes),fallback_used:E(t.fallback_used),disagreement_with_truth:E(t.disagreement_with_truth),provenance:r(t.provenance)??null}:null}function Em(t){return m(t)?{actor:r(t.actor)??null,spawn_agent:r(t.spawn_agent)??null,spawn_role:r(t.spawn_role)??null,spawn_model:r(t.spawn_model)??null,worker_class:r(t.worker_class)??null,parent_actor:r(t.parent_actor)??null,capsule_mode:r(t.capsule_mode)??null,runtime_pool:r(t.runtime_pool)??null,lane_id:r(t.lane_id)??null,controller_level:r(t.controller_level)??null,control_domain:r(t.control_domain)??null,supervisor_actor:r(t.supervisor_actor)??null,model_tier:r(t.model_tier)??null,task_profile:r(t.task_profile)??null,risk_level:r(t.risk_level)??null,routing_confidence:d(t.routing_confidence)??null,routing_reason:r(t.routing_reason)??null,status:r(t.status)??"unknown",turn_count:d(t.turn_count)??0,empty_note_turn_count:d(t.empty_note_turn_count)??0,has_turn:E(t.has_turn)??!1,last_turn_ts_iso:r(t.last_turn_ts_iso)??null}:null}function Om(t){if(!m(t))return null;const e=r(t.session_id);return e?{session_id:e,goal:r(t.goal),status:r(t.status),health:r(t.health),scale_profile:r(t.scale_profile),control_profile:r(t.control_profile),planned_worker_count:d(t.planned_worker_count),active_agent_count:d(t.active_agent_count),last_turn_age_sec:d(t.last_turn_age_sec)??null,attention_count:d(t.attention_count),recommended_action_count:d(t.recommended_action_count),top_attention:Yl(t.top_attention),top_recommendation:Pn(t.top_recommendation)}:null}function Xl(t){const e=m(t)?t:{};return{trace_id:r(e.trace_id),target_type:r(e.target_type)??"room",target_id:r(e.target_id)??null,health:r(e.health),judgment_owner:r(e.judgment_owner)??null,authoritative_judgment_available:E(e.authoritative_judgment_available),resident_judge_runtime:Vl(e.resident_judge_runtime),judgment:jm(e.judgment),active_guidance_layer:r(e.active_guidance_layer)??null,active_summary:ro(e.active_summary),active_recommended_actions:mt(e.active_recommended_actions).map(Pn).filter(n=>n!==null),active_recommendation_source:r(e.active_recommendation_source)??null,active_recommendation_summary:ro(e.active_recommendation_summary),fallback_recommended_actions:mt(e.fallback_recommended_actions).map(Pn).filter(n=>n!==null),recommendation_summary:ro(e.recommendation_summary),swarm_status:m(e.swarm_status)?e.swarm_status:void 0,attention_items:mt(e.attention_items).map(Yl).filter(n=>n!==null),recommended_actions:mt(e.recommended_actions).map(Pn).filter(n=>n!==null),session_cards:mt(e.session_cards).map(Om).filter(n=>n!==null),worker_cards:mt(e.worker_cards).map(Em).filter(n=>n!==null)}}function Dm(t){if(!m(t))return null;const e=m(t.status)?t.status:void 0,n=m(t.summary)?t.summary:m(e==null?void 0:e.summary)?e.summary:void 0,s=m(t.session)?t.session:m(e==null?void 0:e.session)?e.session:void 0,a=r(t.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const i=kr(t.report_paths)??kr(e==null?void 0:e.report_paths),l=mt(t.recent_events,["events"]).filter(m);return{session_id:a,status:r(t.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:d(t.progress_pct)??d(n==null?void 0:n.progress_pct),elapsed_sec:d(t.elapsed_sec)??d(n==null?void 0:n.elapsed_sec),remaining_sec:d(t.remaining_sec)??d(n==null?void 0:n.remaining_sec),done_delta_total:d(t.done_delta_total)??d(n==null?void 0:n.done_delta_total),summary:n,team_health:m(t.team_health)?t.team_health:m(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:m(t.communication_metrics)?t.communication_metrics:m(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:m(t.orchestration_state)?t.orchestration_state:m(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:m(t.cascade_metrics)?t.cascade_metrics:m(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,linked_autoresearch:m(t.linked_autoresearch)?t.linked_autoresearch:m(e==null?void 0:e.linked_autoresearch)?e.linked_autoresearch:void 0,session:s,recent_events:l}}function xr(t){if(!m(t))return null;const e=r(t.name);if(!e)return null;const n=m(t.context)?t.context:void 0;return{name:e,runtime_class:t.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:E(t.desired),resident_registered:E(t.resident_registered),agent_name:r(t.agent_name),status:r(t.status),autonomy_level:r(t.autonomy_level),context_ratio:d(t.context_ratio)??d(n==null?void 0:n.context_ratio),generation:d(t.generation),active_goal_ids:B(t.active_goal_ids),last_autonomous_action_at:r(t.last_autonomous_action_at)??null,last_turn_ago_s:d(t.last_turn_ago_s),model:r(t.model)??r(t.active_model)??r(t.primary_model)}}function wm(t){if(!m(t))return null;const e=r(t.confirm_token)??r(t.token);return e?{confirm_token:e,actor:r(t.actor),action_type:r(t.action_type),target_type:r(t.target_type),target_id:r(t.target_id)??null,delegated_tool:r(t.delegated_tool),created_at:r(t.created_at),preview:t.preview}:null}function Ql(t){if(!m(t))return null;const e=r(t.action_type),n=r(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:r(t.description),confirm_required:E(t.confirm_required)}}function qm(t){return m(t)?{actor_filter:r(t.actor_filter)??null,filter_active:E(t.filter_active)??!1,visible_count:d(t.visible_count)??0,total_count:d(t.total_count)??0,hidden_count:d(t.hidden_count)??0,hidden_actors:B(t.hidden_actors),confirm_required_actions:mt(t.confirm_required_actions).map(Ql).filter(e=>e!==null)}:null}function Fm(t){const e=m(t)?t:{};return{room:Nm(e.room),sessions:mt(e.sessions,["items","sessions"]).map(Dm).filter(n=>n!==null),keepers:mt(e.keepers,["items","keepers"]).map(xr).filter(n=>n!==null),resident_judge_runtime:Vl(e.resident_judge_runtime),persistent_agents:mt(e.persistent_agents,["items","persistent_agents"]).map(xr).filter(n=>n!==null),recent_messages:mt(e.recent_messages,["messages"]).map(Pm).filter(n=>n!==null),pending_confirms:mt(e.pending_confirms,["items","confirms"]).map(wm).filter(n=>n!==null),pending_confirm_summary:qm(e.pending_confirm_summary)??void 0,available_actions:mt(e.available_actions,["actions"]).map(Ql).filter(n=>n!==null)}}function Ts(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function Sr(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function ma(t){pa.value=[{...t,id:Lm++,at:new Date().toISOString()},...pa.value].slice(0,20)}function Zl(t){return t.confirm_required?Ts(t.preview)||"Confirmation required":Ts(t.result)||Ts(t.executed_action)||Ts(t.delegated_tool_result)||t.status}async function xt(){Un.value=!0,me.value=null;try{const t=await hu();$t.value=Fm(t)}catch(t){me.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{Un.value=!1}}async function Ee(){Hn.value=!0,un.value=null;try{const t=await kl({targetType:"room"});ji.value=Xl(t)}catch(t){un.value=t instanceof Error?t.message:"Failed to load operator digest"}finally{Hn.value=!1}}async function pn(t){if(!t){Ft.value=null;return}Hn.value=!0,un.value=null;try{const e=await kl({targetType:"team_session",targetId:t,includeWorkers:!0});Ft.value=Xl(e)}catch(e){un.value=e instanceof Error?e.message:"Failed to load session digest"}finally{Hn.value=!1}}async function tc(t){var e;Z.value=!0,me.value=null;try{const n=await Ya(t);return ma({actor:t.actor,action_type:t.action_type,target_label:Sr(t),outcome:n.confirm_required?"preview":"executed",message:Zl(n),delegated_tool:n.delegated_tool}),await xt(),await Ee(),(e=Ft.value)!=null&&e.target_id&&await pn(Ft.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw me.value=s,ma({actor:t.actor,action_type:t.action_type,target_label:Sr(t),outcome:"error",message:s}),n}finally{Z.value=!1}}async function ec(t,e,n="confirm"){var s;Z.value=!0,me.value=null;try{const a=await xl(t,e,n);return ma({actor:t,action_type:n,target_label:e,outcome:"confirmed",message:Zl(a),delegated_tool:a.delegated_tool}),await xt(),await Ee(),(s=Ft.value)!=null&&s.target_id&&await pn(Ft.value.target_id),a}catch(a){const i=a instanceof Error?a.message:"Operator confirmation failed";throw me.value=i,ma({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:i}),a}finally{Z.value=!1}}Im(()=>{var t;xt(),Ee(),(t=Ft.value)!=null&&t.target_id&&pn(Ft.value.target_id)});const cs=g(null),ni=g(!1),_a=g(null),nc=g(null),Ue=g(!1),Te=g(null),si=g(null),Xs=g(!1),Qs=g(null);let en=null;function Cr(){en!==null&&(window.clearTimeout(en),en=null)}function Km(t=1500){en===null&&(en=window.setTimeout(()=>{en=null,va(!1)},t))}function w(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function y(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function q(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function nn(t){return typeof t=="boolean"?t:void 0}function V(t,e=[]){if(Array.isArray(t))return t;if(!w(t))return[];for(const n of e){const s=t[n];if(Array.isArray(s))return s}return[]}function $n(t){if(!w(t))return null;const e=y(t.kind),n=y(t.summary),s=y(t.target_type);return!e||!n||!s?null:{kind:e,severity:y(t.severity)??"warn",summary:n,target_type:s,target_id:y(t.target_id)??null,actor:y(t.actor)??null,evidence:t.evidence}}function Oe(t){if(!w(t))return null;const e=y(t.action_type),n=y(t.target_type),s=y(t.reason);return!e||!n||!s?null:{action_type:e,target_type:n,target_id:y(t.target_id)??null,severity:y(t.severity)??"warn",reason:s,confirm_required:nn(t.confirm_required),suggested_payload:t.suggested_payload,preview:t.preview}}function Bm(t){if(!w(t))return null;const e=y(t.session_id);return e?{session_id:e,goal:y(t.goal),status:y(t.status),health:y(t.health),scale_profile:y(t.scale_profile),control_profile:y(t.control_profile),planned_worker_count:q(t.planned_worker_count),active_agent_count:q(t.active_agent_count),last_turn_age_sec:q(t.last_turn_age_sec)??null,attention_count:q(t.attention_count),recommended_action_count:q(t.recommended_action_count),top_attention:$n(t.top_attention),top_recommendation:Oe(t.top_recommendation)}:null}function Um(t){if(!w(t))return null;const e=y(t.session_id);if(!e)return null;const n=w(t.status)?t.status:t,s=w(n.summary)?n.summary:void 0;return{session_id:e,status:y(t.status)??y(s==null?void 0:s.status)??(w(n.session)?y(n.session.status):void 0),progress_pct:q(t.progress_pct)??q(s==null?void 0:s.progress_pct),elapsed_sec:q(t.elapsed_sec)??q(s==null?void 0:s.elapsed_sec),remaining_sec:q(t.remaining_sec)??q(s==null?void 0:s.remaining_sec),done_delta_total:q(t.done_delta_total)??q(s==null?void 0:s.done_delta_total),summary:w(t.summary)?t.summary:s,team_health:w(t.team_health)?t.team_health:w(n.team_health)?n.team_health:void 0,communication_metrics:w(t.communication_metrics)?t.communication_metrics:w(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:w(t.orchestration_state)?t.orchestration_state:w(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:w(t.cascade_metrics)?t.cascade_metrics:w(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:w(t.report_paths)?Object.fromEntries(Object.entries(t.report_paths).map(([a,i])=>{const l=y(i);return l?[a,l]:null}).filter(a=>a!==null)):w(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,i])=>{const l=y(i);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:w(t.session)?t.session:w(n.session)?n.session:void 0,recent_events:V(t.recent_events,["events"]).filter(w)}}function Hm(t){if(!w(t))return null;const e=y(t.name);return e?{name:e,agent_name:y(t.agent_name),status:y(t.status),autonomy_level:y(t.autonomy_level),context_ratio:q(t.context_ratio),generation:q(t.generation),active_goal_ids:V(t.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:y(t.last_autonomous_action_at)??null,last_turn_ago_s:q(t.last_turn_ago_s),model:y(t.model)}:null}function Wm(t){if(!w(t))return null;const e=y(t.confirm_token)??y(t.token);return e?{confirm_token:e,actor:y(t.actor),action_type:y(t.action_type),target_type:y(t.target_type),target_id:y(t.target_id)??null,delegated_tool:y(t.delegated_tool),created_at:y(t.created_at),preview:t.preview}:null}function Gm(t){if(!w(t))return null;const e=y(t.action_type),n=y(t.target_type);return!e||!n?null:{action_type:e,target_type:n,description:y(t.description),confirm_required:nn(t.confirm_required)}}function Jm(t){const e=w(t)?t:{};return{room_health:y(e.room_health),cluster:y(e.cluster),project:y(e.project),current_room:y(e.current_room)??null,paused:nn(e.paused),tempo_interval_s:q(e.tempo_interval_s),active_agents:q(e.active_agents),keeper_pressure:q(e.keeper_pressure),active_operations:q(e.active_operations),pending_approvals:q(e.pending_approvals),incident_count:q(e.incident_count),recommended_action_count:q(e.recommended_action_count),top_attention:$n(e.top_attention),top_action:Oe(e.top_action)}}function Ym(t){const e=w(t)?t:{},n=w(e.swarm_overview)?e.swarm_overview:{};return{health:y(e.health),active_operations:q(e.active_operations),pending_approvals:q(e.pending_approvals),swarm_overview:{active_lanes:q(n.active_lanes),moving_lanes:q(n.moving_lanes),stalled_lanes:q(n.stalled_lanes),projected_lanes:q(n.projected_lanes),last_movement_at:y(n.last_movement_at)??null},top_attention:$n(e.top_attention),top_action:Oe(e.top_action),session_cards:V(e.session_cards).map(Bm).filter(s=>s!==null)}}function Vm(t){const e=w(t)?t:{};return{sessions:V(e.sessions,["items"]).map(Um).filter(n=>n!==null),keepers:V(e.keepers,["items"]).map(Hm).filter(n=>n!==null),pending_confirms:V(e.pending_confirms).map(Wm).filter(n=>n!==null),available_actions:V(e.available_actions).map(Gm).filter(n=>n!==null)}}function Xm(t){if(!w(t))return null;const e=y(t.id),n=y(t.kind),s=y(t.summary),a=y(t.target_type);return!e||!n||!s||!a?null:{id:e,kind:n,severity:y(t.severity)??"warn",summary:s,target_type:a,target_id:y(t.target_id)??null,top_action:Oe(t.top_action),related_session_ids:V(t.related_session_ids).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),related_agent_names:V(t.related_agent_names).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),evidence_preview:V(t.evidence_preview).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),last_seen_at:y(t.last_seen_at)??null}}function sc(t){if(!w(t))return null;const e=y(t.session_id),n=y(t.goal);return!e||!n?null:{session_id:e,goal:n,room:y(t.room)??null,status:y(t.status),health:y(t.health),member_names:V(t.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:y(t.started_at)??null,elapsed_sec:q(t.elapsed_sec)??null,operation_id:y(t.operation_id)??null,blocker_summary:y(t.blocker_summary)??null,last_event_at:y(t.last_event_at)??null,last_event_summary:y(t.last_event_summary)??null,communication_summary:y(t.communication_summary)??null,active_count:q(t.active_count),required_count:q(t.required_count),related_attention_count:q(t.related_attention_count)??0,top_attention:$n(t.top_attention),top_recommendation:Oe(t.top_recommendation)}}function ac(t){if(!w(t))return null;const e=y(t.agent_name);return e?{agent_name:e,status:y(t.status),current_work:y(t.current_work)??null,recent_input_preview:y(t.recent_input_preview)??null,recent_output_preview:y(t.recent_output_preview)??null,recent_tool_names:V(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_activity_at:y(t.last_activity_at)??null}:null}function oc(t){if(!w(t))return null;const e=y(t.operation_id);return e?{operation_id:e,status:y(t.status),stage:y(t.stage)??null,detachment_status:y(t.detachment_status)??null,objective:y(t.objective)??null,updated_at:y(t.updated_at)??null}:null}function ic(t){if(!w(t))return null;const e=y(t.name);return e?{name:e,agent_name:y(t.agent_name)??null,status:y(t.status),generation:q(t.generation),context_ratio:q(t.context_ratio)??null,last_turn_ago_s:q(t.last_turn_ago_s)??null,current_work:y(t.current_work)??null}:null}function rc(t){const e=sc(t);return e?{...e,member_previews:V(w(t)?t.member_previews:void 0).map(ac).filter(n=>n!==null),operation_badges:V(w(t)?t.operation_badges:void 0).map(oc).filter(n=>n!==null),keeper_refs:V(w(t)?t.keeper_refs:void 0).map(ic).filter(n=>n!==null)}:null}function Qm(t){if(!w(t))return null;const e=y(t.agent_name);return e?{agent_name:e,status:y(t.status),where:y(t.where)??null,with_whom:V(t.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:y(t.current_work)??null,related_session_id:y(t.related_session_id)??null,related_attention_count:q(t.related_attention_count)??0,last_activity_at:y(t.last_activity_at)??null,recent_output_preview:y(t.recent_output_preview)??null,recent_input_preview:y(t.recent_input_preview)??null,recent_event:y(t.recent_event)??null,recent_tool_names:V(t.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),allowed_tool_names:V(t.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:V(t.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:q(t.latest_tool_call_count)??null,tool_audit_source:y(t.tool_audit_source)??null,tool_audit_at:y(t.tool_audit_at)??null}:null}function Zm(t){if(!w(t))return null;const e=y(t.name);return e?{name:e,agent_name:y(t.agent_name)??null,status:y(t.status),generation:q(t.generation),context_ratio:q(t.context_ratio)??null,last_turn_ago_s:q(t.last_turn_ago_s)??null,current_work:y(t.current_work)??null,last_autonomous_action_at:y(t.last_autonomous_action_at)??null,allowed_tool_names:V(t.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:V(t.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:q(t.latest_tool_call_count)??null,tool_audit_source:y(t.tool_audit_source)??null,tool_audit_at:y(t.tool_audit_at)??null}:null}function t_(t){if(!w(t))return null;const e=y(t.id),n=y(t.signal_type),s=y(t.summary),a=y(t.target_type);return!e||!n||!s||!a?null:{id:e,signal_type:n==="action"?"action":"attention",severity:y(t.severity)??"warn",summary:s,target_type:a,target_id:y(t.target_id)??null,attention:$n(t.attention),action:Oe(t.action)}}function e_(t){const e=w(t)?t:{},n=V(e.session_briefs).map(sc).filter(a=>a!==null),s=V(e.sessions).map(rc).filter(a=>a!==null);return{generated_at:y(e.generated_at),summary:Jm(e.summary),incidents:V(e.incidents).map($n).filter(a=>a!==null),recommended_actions:V(e.recommended_actions).map(Oe).filter(a=>a!==null),command_focus:Ym(e.command_focus),operator_targets:Vm(e.operator_targets),attention_queue:V(e.attention_queue).map(Xm).filter(a=>a!==null),sessions:s.length>0?s:n.map(a=>({...a,member_previews:[],operation_badges:[],keeper_refs:[]})),session_briefs:n,agent_briefs:V(e.agent_briefs).map(Qm).filter(a=>a!==null),keeper_briefs:V(e.keeper_briefs).map(Zm).filter(a=>a!==null),internal_signals:V(e.internal_signals).map(t_).filter(a=>a!==null)}}function n_(t){if(!w(t))return null;const e=y(t.id),n=y(t.summary);return!e||!n?null:{id:e,timestamp:y(t.timestamp)??null,event_type:y(t.event_type),actor:y(t.actor)??null,summary:n}}function s_(t){const e=w(t)?t:{};return{generated_at:y(e.generated_at),session_id:y(e.session_id)??"",session:rc(e.session),timeline:V(e.timeline).map(n_).filter(n=>n!==null),participants:V(e.participants).map(ac).filter(n=>n!==null),operations:V(e.operations).map(oc).filter(n=>n!==null),keepers:V(e.keepers).map(ic).filter(n=>n!==null),error:y(e.error)??null}}function a_(t){if(!w(t))return null;const e=y(t.id),n=y(t.label),s=y(t.summary);if(!e||!n||!s)return null;const a=y(t.status)??"unclear";return{id:e,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:y(t.signal_class)==="metadata_gap"||y(t.signal_class)==="mixed"||y(t.signal_class)==="operational_risk"?y(t.signal_class):void 0,evidence_quality:y(t.evidence_quality)==="strong"||y(t.evidence_quality)==="partial"||y(t.evidence_quality)==="missing"?y(t.evidence_quality):void 0,evidence:V(t.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function o_(t){if(!w(t))return null;const e=y(t.kind),n=y(t.summary),s=y(t.scope_type),a=y(t.severity);return!e||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:e,summary:n,scope_type:s,scope_id:y(t.scope_id)??null,severity:a}}function i_(t){const e=w(t)?t:{},n=w(e.basis)?e.basis:{},s=y(e.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:y(e.generated_at),cached:nn(e.cached),stale:nn(e.stale),refreshing:nn(e.refreshing),status:a,summary:y(e.summary)??null,model:y(e.model)??null,ttl_sec:q(e.ttl_sec),criteria:V(e.criteria).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),basis:{current_room:y(n.current_room)??null,crew_count:q(n.crew_count),agent_count:q(n.agent_count),keeper_count:q(n.keeper_count)},metadata_gap_count:q(e.metadata_gap_count),metadata_gaps:V(e.metadata_gaps).map(o_).filter(i=>i!==null),sections:V(e.sections).map(a_).filter(i=>i!==null),error:y(e.error)??null,last_error:y(e.last_error)??null}}async function lc(){ni.value=!0,_a.value=null;try{const t=await pu();cs.value=e_(t)}catch(t){_a.value=t instanceof Error?t.message:"Failed to load mission snapshot"}finally{ni.value=!1}}async function r_(t){if(!t){si.value=null,Qs.value=null,Xs.value=!1;return}Xs.value=!0,Qs.value=null;try{const e=await mu(t);si.value=s_(e)}catch(e){Qs.value=e instanceof Error?e.message:"Failed to load session detail"}finally{Xs.value=!1}}async function va(t=!1){Ue.value=!0,Te.value=null;try{const e=await _u(t),n=i_(e);nc.value=n,n.refreshing||n.status==="pending"?Km():Cr()}catch(e){Te.value=e instanceof Error?e.message:"Failed to load mission briefing",Cr()}finally{Ue.value=!1}}const cc=g(null),ai=g(!1),He=g(null);async function dc(t,e){ai.value=!0,He.value=null;try{cc.value=await vu(t,e)}catch(n){He.value=n instanceof Error?n.message:String(n)}finally{ai.value=!1}}const Ei=g(null),Bt=g(null),fa=g(!1),ga=g(!1),$a=g(null),ha=g(null),oi=g(null),ya=g(null),tt=g("warroom"),ds=g(null),ii=g(!1),ba=g(null),De=g(null),ka=g(!1),xa=g(null),Oi=g(null),ri=g(!1),Sa=g(null),us=g(null),li=g(!1),Ca=g(null),Wn=g(null),Aa=g(!1),Gn=g(null),sn=g(null);let Tn=null;function Di(t){return t!=="summary"&&t!=="swarm"&&t!=="warroom"&&t!=="orchestra"}function uc(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function pc(){const e=uc().get("run_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function mc(){const e=uc().get("operation_id")??void 0;return e&&e.trim()!==""?e.trim():void 0}function l_(t){if(m(t))return{policy_class:r(t.policy_class),approval_class:r(t.approval_class),tool_allowlist:B(t.tool_allowlist),model_allowlist:B(t.model_allowlist),requires_human_for:B(t.requires_human_for),autonomy_level:r(t.autonomy_level),escalation_timeout_sec:d(t.escalation_timeout_sec),kill_switch:E(t.kill_switch),frozen:E(t.frozen)}}function c_(t){if(m(t))return{headcount_cap:d(t.headcount_cap),active_operation_cap:d(t.active_operation_cap),max_cost_usd:d(t.max_cost_usd),max_tokens:d(t.max_tokens)}}function wi(t){if(!m(t))return null;const e=r(t.unit_id),n=r(t.label),s=r(t.kind);return!e||!n||!s?null:{unit_id:e,label:n,kind:s,parent_unit_id:r(t.parent_unit_id)??null,leader_id:r(t.leader_id)??null,roster:B(t.roster),capability_profile:B(t.capability_profile),source:r(t.source),created_at:r(t.created_at),updated_at:r(t.updated_at),policy:l_(t.policy),budget:c_(t.budget)}}function _c(t){if(!m(t))return null;const e=wi(t.unit);return e?{unit:e,leader_status:r(t.leader_status),roster_total:d(t.roster_total),roster_live:d(t.roster_live),active_operation_count:d(t.active_operation_count),health:r(t.health),reasons:B(t.reasons),children:Array.isArray(t.children)?t.children.map(_c).filter(n=>n!==null):[]}:null}function d_(t){if(m(t))return{total_units:d(t.total_units),company_count:d(t.company_count),platoon_count:d(t.platoon_count),squad_count:d(t.squad_count),leaf_agent_unit_count:d(t.leaf_agent_unit_count),live_agent_count:d(t.live_agent_count),managed_unit_count:d(t.managed_unit_count),active_operation_count:d(t.active_operation_count)}}function vc(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),source:r(e.source),summary:d_(e.summary),units:Array.isArray(e.units)?e.units.map(_c).filter(n=>n!==null):[]}}function u_(t){if(!m(t))return null;const e=r(t.kind),n=r(t.status);return!e||!n?null:{kind:e,chain_id:r(t.chain_id)??null,goal:r(t.goal)??null,run_id:r(t.run_id)??null,status:n,viewer_path:r(t.viewer_path)??null,last_sync_at:r(t.last_sync_at)??null}}function Qa(t){if(!m(t))return null;const e=r(t.operation_id),n=r(t.objective),s=r(t.assigned_unit_id),a=r(t.trace_id),i=r(t.status);return!e||!n||!s||!a||!i?null:{operation_id:e,objective:n,assigned_unit_id:s,autonomy_level:r(t.autonomy_level),policy_class:r(t.policy_class),budget_class:r(t.budget_class),detachment_session_id:r(t.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(t.checkpoint_ref)??null,active_goal_ids:B(t.active_goal_ids),note:r(t.note)??null,created_by:r(t.created_by),source:r(t.source),status:i,chain:u_(t.chain),created_at:r(t.created_at),updated_at:r(t.updated_at)}}function p_(t){if(!m(t))return null;const e=Qa(t.operation);return e?{operation:e,assigned_unit_label:r(t.assigned_unit_label)}:null}function Sn(t){if(m(t))return{tone:r(t.tone),pending_ops:d(t.pending_ops),blocked_ops:d(t.blocked_ops),in_flight_ops:d(t.in_flight_ops),pipeline_stalls:d(t.pipeline_stalls),bus_traffic:d(t.bus_traffic),l1_hit_rate:d(t.l1_hit_rate),invalidation_count:d(t.invalidation_count),current_pending:d(t.current_pending),current_in_flight:d(t.current_in_flight),cdb_wakeups:d(t.cdb_wakeups),total_stolen:d(t.total_stolen),avg_best_score:d(t.avg_best_score),avg_candidate_count:d(t.avg_candidate_count),best_first_operations:d(t.best_first_operations),active_sessions:d(t.active_sessions),commit_rate:d(t.commit_rate),total_speculations:d(t.total_speculations)}}function m_(t){if(!m(t))return;const e=m(t.pipeline)?t.pipeline:void 0,n=m(t.cache)?t.cache:void 0,s=m(t.ooo)?t.ooo:void 0,a=m(t.speculative)?t.speculative:void 0,i=m(t.search_fabric)?t.search_fabric:void 0,l=m(t.signals)?t.signals:void 0;return{pipeline:e?{total_ops:d(e.total_ops),completed_ops:d(e.completed_ops),stalled_cycles:d(e.stalled_cycles),hazards_detected:d(e.hazards_detected),forwarding_used:d(e.forwarding_used),pipeline_flushes:d(e.pipeline_flushes),ipc:d(e.ipc)}:void 0,cache:n?{total_reads:d(n.total_reads),total_writes:d(n.total_writes),l1_hit_rate:d(n.l1_hit_rate),invalidation_count:d(n.invalidation_count),writeback_count:d(n.writeback_count),bus_traffic:d(n.bus_traffic)}:void 0,ooo:s?{agent_count:d(s.agent_count),total_added:d(s.total_added),total_issued:d(s.total_issued),total_completed:d(s.total_completed),total_stolen:d(s.total_stolen),cdb_wakeups:d(s.cdb_wakeups),stall_cycles:d(s.stall_cycles),global_cdb_events:d(s.global_cdb_events),current_pending:d(s.current_pending),current_in_flight:d(s.current_in_flight)}:void 0,speculative:a?{total_speculations:d(a.total_speculations),total_commits:d(a.total_commits),total_aborts:d(a.total_aborts),commit_rate:d(a.commit_rate),total_fast_calls:d(a.total_fast_calls),total_cost_usd:d(a.total_cost_usd),active_sessions:d(a.active_sessions)}:void 0,search_fabric:i?{total_operations:d(i.total_operations),best_first_operations:d(i.best_first_operations),legacy_operations:d(i.legacy_operations),blocked_operations:d(i.blocked_operations),ready_operations:d(i.ready_operations),research_pipeline_operations:d(i.research_pipeline_operations),avg_candidate_count:d(i.avg_candidate_count),avg_best_score:d(i.avg_best_score),top_stage:r(i.top_stage)??null}:void 0,signals:l?{issue_pressure:Sn(l.issue_pressure),cache_contention:Sn(l.cache_contention),scheduler_efficiency:Sn(l.scheduler_efficiency),routing_confidence:Sn(l.routing_confidence),speculative_posture:Sn(l.speculative_posture)}:void 0}}function fc(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),active:d(n.active),paused:d(n.paused),managed:d(n.managed),projected:d(n.projected)}:void 0,microarch:m_(e.microarch),operations:Array.isArray(e.operations)?e.operations.map(p_).filter(s=>s!==null):[]}}function gc(t){if(!m(t))return null;const e=r(t.detachment_id),n=r(t.operation_id),s=r(t.assigned_unit_id);return!e||!n||!s?null:{detachment_id:e,operation_id:n,assigned_unit_id:s,leader_id:r(t.leader_id)??null,roster:B(t.roster),session_id:r(t.session_id)??null,checkpoint_ref:r(t.checkpoint_ref)??null,runtime_kind:r(t.runtime_kind)??null,runtime_ref:r(t.runtime_ref)??null,source:r(t.source),status:r(t.status),last_event_at:r(t.last_event_at)??null,last_progress_at:r(t.last_progress_at)??null,heartbeat_deadline:r(t.heartbeat_deadline)??null,created_at:r(t.created_at),updated_at:r(t.updated_at)}}function __(t){if(!m(t))return null;const e=gc(t.detachment);return e?{detachment:e,assigned_unit_label:r(t.assigned_unit_label),operation:Qa(t.operation)}:null}function $c(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),active:d(n.active),projected:d(n.projected)}:void 0,detachments:Array.isArray(e.detachments)?e.detachments.map(__).filter(s=>s!==null):[]}}function v_(t){if(!m(t))return null;const e=r(t.decision_id),n=r(t.trace_id),s=r(t.requested_action),a=r(t.scope_type),i=r(t.scope_id);return!e||!n||!s||!a||!i?null:{decision_id:e,trace_id:n,requested_action:s,scope_type:a,scope_id:i,operation_id:r(t.operation_id)??null,target_unit_id:r(t.target_unit_id)??null,requested_by:r(t.requested_by),status:r(t.status),reason:r(t.reason)??null,source:r(t.source),detail:t.detail,created_at:r(t.created_at),decided_at:r(t.decided_at)??null,expires_at:r(t.expires_at)??null}}function hc(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),pending:d(n.pending),approved:d(n.approved),denied:d(n.denied)}:void 0,decisions:Array.isArray(e.decisions)?e.decisions.map(v_).filter(s=>s!==null):[]}}function f_(t){if(!m(t))return null;const e=wi(t.unit);return e?{unit:e,roster_total:d(t.roster_total),roster_live:d(t.roster_live),headcount_cap:d(t.headcount_cap),active_operations:d(t.active_operations),active_operation_cap:d(t.active_operation_cap),utilization:d(t.utilization)}:null}function g_(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),capacity:Array.isArray(e.capacity)?e.capacity.map(f_).filter(n=>n!==null):[]}}function $_(t){if(!m(t))return null;const e=r(t.alert_id);return e?{alert_id:e,severity:r(t.severity),kind:r(t.kind),scope_type:r(t.scope_type),scope_id:r(t.scope_id),title:r(t.title),detail:r(t.detail),timestamp:r(t.timestamp)}:null}function yc(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),summary:n?{total:d(n.total),bad:d(n.bad),warn:d(n.warn)}:void 0,alerts:Array.isArray(e.alerts)?e.alerts.map($_).filter(s=>s!==null):[]}}function bc(t){if(!m(t))return null;const e=r(t.event_id),n=r(t.trace_id),s=r(t.event_type);return!e||!n||!s?null:{event_id:e,trace_id:n,event_type:s,operation_id:r(t.operation_id)??null,unit_id:r(t.unit_id)??null,actor:r(t.actor)??null,source:r(t.source),timestamp:r(t.timestamp),detail:t.detail}}function h_(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),events:Array.isArray(e.events)?e.events.map(bc).filter(n=>n!==null):[]}}function y_(t){if(!m(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s}}function b_(t){if(!m(t))return null;const e=r(t.lane_id),n=r(t.label),s=r(t.kind),a=r(t.phase),i=r(t.motion_state),l=r(t.source_of_truth),c=r(t.movement_reason),p=r(t.current_step);if(!e||!n||!s||!a||!i||!l||!c||!p)return null;const _=m(t.counts)?t.counts:{};return{lane_id:e,label:n,kind:s,present:E(t.present)??!1,phase:a,motion_state:i,source_of_truth:l,last_movement_at:r(t.last_movement_at)??null,movement_reason:c,current_step:p,blockers:B(t.blockers),counts:{operations:d(_.operations),detachments:d(_.detachments),workers:d(_.workers),approvals:d(_.approvals),alerts:d(_.alerts)},hard_flags:Array.isArray(t.hard_flags)?t.hard_flags.map(y_).filter(u=>u!==null):[]}}function k_(t){if(!m(t))return null;const e=r(t.event_id),n=r(t.lane_id),s=r(t.kind),a=r(t.timestamp),i=r(t.title),l=r(t.detail),c=r(t.tone),p=r(t.source);return!e||!n||!s||!a||!i||!l||!c||!p?null:{event_id:e,lane_id:n,kind:s,timestamp:a,title:i,detail:l,tone:c,source:p}}function x_(t){if(!m(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.summary);return!e||!n||!s?null:{code:e,severity:n,summary:s,why_it_matters:r(t.why_it_matters)??void 0,next_tool:r(t.next_tool)??void 0,next_step:r(t.next_step)??void 0,lane_ids:B(t.lane_ids),count:d(t.count)??0}}function qi(t){if(!m(t))return;const e=m(t.overview)?t.overview:{},n=m(t.gaps)?t.gaps:{},s=m(t.narrative)?t.narrative:{},a=m(t.recommended_next_action)?t.recommended_next_action:void 0;return{generated_at:r(t.generated_at),narrative:{state:r(s.state)??void 0,started:r(s.started)??void 0,active_work:r(s.active_work)??void 0,completion:r(s.completion)??void 0,lane_id:r(s.lane_id)??null},overview:{active_lanes:d(e.active_lanes),moving_lanes:d(e.moving_lanes),stalled_lanes:d(e.stalled_lanes),projected_lanes:d(e.projected_lanes),last_movement_at:r(e.last_movement_at)??null},lanes:Array.isArray(t.lanes)?t.lanes.map(b_).filter(i=>i!==null):[],timeline:Array.isArray(t.timeline)?t.timeline.map(k_).filter(i=>i!==null):[],gaps:{count:d(n.count),items:Array.isArray(n.items)?n.items.map(x_).filter(i=>i!==null):[]},recommended_next_action:a?{tool:r(a.tool)??"masc_operator_snapshot",label:r(a.label)??"Observe operator state",reason:r(a.reason)??"",lane_id:r(a.lane_id)??null}:void 0}}function kc(t){if(!m(t))return;const e=m(t.workers)?t.workers:{},n=E(t.pass);return{status:r(t.status)??"missing",source:r(t.source)??"none",reason_code:r(t.reason_code)??null,status_summary:r(t.status_summary)??null,run_id:r(t.run_id)??null,captured_at:r(t.captured_at)??null,...n!==void 0?{pass:n}:{},...d(t.peak_hot_slots)!=null?{peak_hot_slots:d(t.peak_hot_slots)}:{},...d(t.ctx_per_slot)!=null?{ctx_per_slot:d(t.ctx_per_slot)}:{},workers:{expected:d(e.expected),joined:d(e.joined),current_task_bound:d(e.current_task_bound),fresh_heartbeats:d(e.fresh_heartbeats),done:d(e.done),final:d(e.final)},expected_artifact_dir:r(t.expected_artifact_dir)??null,artifact_ref:r(t.artifact_ref)??null,missing_reason:r(t.missing_reason)??null}}function S_(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),topology:vc(e.topology),operations:fc(e.operations),detachments:$c(e.detachments),alerts:yc(e.alerts),decisions:hc(e.decisions),capacity:g_(e.capacity),traces:h_(e.traces),swarm_status:qi(e.swarm_status)}}function C_(t){const e=m(t)?t:{},n=vc(e.topology),s=fc(e.operations),a=$c(e.detachments),i=yc(e.alerts),l=hc(e.decisions);return{version:r(e.version),generated_at:r(e.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:i.version,generated_at:i.generated_at,summary:i.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:qi(e.swarm_status),swarm_proof:kc(e.swarm_proof)}}function A_(t){return m(t)?{chain_id:r(t.chain_id)??null,started_at:d(t.started_at)??null,progress:d(t.progress)??null,elapsed_sec:d(t.elapsed_sec)??null}:null}function xc(t){if(!m(t))return null;const e=r(t.event);return e?{event:e,chain_id:r(t.chain_id)??null,timestamp:r(t.timestamp)??null,duration_ms:d(t.duration_ms)??null,message:r(t.message)??null,tokens:d(t.tokens)??null}:null}function T_(t){if(!m(t))return null;const e=Qa(t.operation);return e?{operation:e,runtime:A_(t.runtime),history:xc(t.history),mermaid:r(t.mermaid)??null,preview_run:Sc(t.preview_run)}:null}function I_(t){const e=m(t)?t:{};return{status:r(e.status)??"disconnected",base_url:r(e.base_url)??null,message:r(e.message)??null}}function z_(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),connection:I_(e.connection),summary:n?{linked_operations:d(n.linked_operations),active_chains:d(n.active_chains),running_operations:d(n.running_operations),recent_failures:d(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(e.operations)?e.operations.map(T_).filter(s=>s!==null):[],recent_history:Array.isArray(e.recent_history)?e.recent_history.map(xc).filter(s=>s!==null):[]}}function R_(t){if(!m(t))return null;const e=r(t.id);return e?{id:e,type:r(t.type),status:r(t.status),duration_ms:d(t.duration_ms)??null,error:r(t.error)??null}:null}function Sc(t){if(!m(t))return null;const e=r(t.run_id),n=r(t.chain_id);return n?{run_id:e??null,chain_id:n,duration_ms:d(t.duration_ms),success:E(t.success),mermaid:r(t.mermaid),nodes:Array.isArray(t.nodes)?t.nodes.map(R_).filter(s=>s!==null):[]}:null}function M_(t){const e=m(t)?t:{};return{run:Sc(e.run)}}function L_(t){if(!m(t))return null;const e=r(t.title),n=r(t.path);return!e||!n?null:{title:e,path:n}}function P_(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary);return!e||!n||!s?null:{id:e,title:n,summary:s}}function N_(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.tool),a=r(t.summary);return!e||!n||!s||!a?null:{id:e,title:n,tool:s,summary:a,success_signals:B(t.success_signals),pitfalls:B(t.pitfalls)}}function j_(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.summary),a=r(t.when_to_use);return!e||!n||!s||!a?null:{id:e,title:n,summary:s,when_to_use:a,steps:Array.isArray(t.steps)?t.steps.map(N_).filter(i=>i!==null):[]}}function E_(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.description);return!e||!n||!s?null:{id:e,title:n,description:s,tools:B(t.tools)}}function O_(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.symptom),a=r(t.why),i=r(t.fix_tool),l=r(t.fix_summary);return!e||!n||!s||!a||!i||!l?null:{id:e,title:n,symptom:s,why:a,fix_tool:i,fix_summary:l}}function D_(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.path_id),a=r(t.transport);return!e||!n||!s||!a?null:{id:e,title:n,path_id:s,transport:a,request:t.request,response:t.response,notes:B(t.notes)}}function w_(t){const e=m(t)?t:{};return{version:r(e.version),generated_at:r(e.generated_at),docs:Array.isArray(e.docs)?e.docs.map(L_).filter(n=>n!==null):[],concepts:Array.isArray(e.concepts)?e.concepts.map(P_).filter(n=>n!==null):[],golden_paths:Array.isArray(e.golden_paths)?e.golden_paths.map(j_).filter(n=>n!==null):[],tool_groups:Array.isArray(e.tool_groups)?e.tool_groups.map(E_).filter(n=>n!==null):[],pitfalls:Array.isArray(e.pitfalls)?e.pitfalls.map(O_).filter(n=>n!==null):[],examples:Array.isArray(e.examples)?e.examples.map(D_).filter(n=>n!==null):[]}}function q_(t){if(!m(t))return null;const e=r(t.id),n=r(t.title),s=r(t.status),a=r(t.detail),i=r(t.next_tool);return!e||!n||!s||!a||!i?null:{id:e,title:n,status:s,detail:a,next_tool:i}}function F_(t){if(!m(t))return null;const e=r(t.code),n=r(t.severity),s=r(t.title),a=r(t.detail),i=r(t.next_tool);return!e||!n||!s||!a||!i?null:{code:e,severity:n,title:s,detail:a,next_tool:i}}function K_(t){if(!m(t))return null;const e=r(t.from),n=r(t.content),s=r(t.timestamp),a=d(t.seq);return!e||!n||!s||a==null?null:{seq:a,from:e,content:n,timestamp:s}}function B_(t){if(!m(t))return null;const e=r(t.name),n=r(t.role),s=r(t.lane),a=r(t.status),i=r(t.claim_marker),l=r(t.done_marker),c=r(t.final_marker);if(!e||!n||!s||!a||!i||!l||!c)return null;const p=(()=>{if(!m(t.last_message))return null;const _=d(t.last_message.seq),u=r(t.last_message.content),f=r(t.last_message.timestamp);return _==null||!u||!f?null:{seq:_,content:u,timestamp:f}})();return{name:e,role:n,lane:s,joined:E(t.joined)??!1,live_presence:E(t.live_presence)??!1,completed:E(t.completed)??!1,status:a,current_task:r(t.current_task)??null,bound_task_id:r(t.bound_task_id)??null,bound_task_title:r(t.bound_task_title)??null,bound_task_status:r(t.bound_task_status)??null,current_task_matches_run:E(t.current_task_matches_run)??!1,squad_member:E(t.squad_member)??!1,detachment_member:E(t.detachment_member)??!1,last_seen:r(t.last_seen)??null,heartbeat_age_sec:d(t.heartbeat_age_sec)??null,heartbeat_fresh:E(t.heartbeat_fresh)??!1,claim_marker_seen:E(t.claim_marker_seen)??!1,done_marker_seen:E(t.done_marker_seen)??!1,final_marker_seen:E(t.final_marker_seen)??!1,claim_marker:i,done_marker:l,final_marker:c,last_message:p}}function U_(t){if(!m(t))return;const e=Array.isArray(t.timeline)?t.timeline.map(n=>{if(!m(n))return null;const s=r(n.timestamp),a=d(n.active_slots);if(!s||a==null)return null;const i=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:i}}).filter(n=>n!==null):[];return{slot_url:r(t.slot_url)??null,provider_base_url:r(t.provider_base_url)??null,provider_reachable:E(t.provider_reachable)??null,provider_status_code:d(t.provider_status_code)??null,provider_model_id:r(t.provider_model_id)??null,actual_model_id:r(t.actual_model_id)??null,expected_slots:d(t.expected_slots),actual_slots:d(t.actual_slots),expected_ctx:d(t.expected_ctx),actual_ctx:d(t.actual_ctx),configured_capacity:d(t.configured_capacity),slot_reachable:E(t.slot_reachable)??null,slot_status_code:d(t.slot_status_code)??null,runtime_blocker:r(t.runtime_blocker)??null,detail:r(t.detail)??null,checked_at:r(t.checked_at)??null,total_slots:d(t.total_slots),ctx_per_slot:d(t.ctx_per_slot),active_slots_now:d(t.active_slots_now),peak_active_slots:d(t.peak_active_slots),sample_count:d(t.sample_count),last_sample_at:r(t.last_sample_at)??null,timeline:e}}function H_(t){if(!m(t))return null;const e=r(t.run_id),n=r(t.status),s=r(t.decided_by),a=r(t.decided_at),i=r(t.reason);if(!e||!n||!s||!a||!i)return null;const l=[];return Array.isArray(t.history)&&t.history.forEach(c=>{if(!m(c))return;const p=r(c.status),_=r(c.decided_by),u=r(c.decided_at),f=r(c.reason);!p||!_||!u||!f||l.push({status:p,decided_by:_,decided_at:u,reason:f,operation_id:r(c.operation_id)??null,detachment_id:r(c.detachment_id)??null,note:r(c.note)??null})}),{run_id:e,status:n,decided_by:s,decided_at:a,reason:i,operation_id:r(t.operation_id)??null,detachment_id:r(t.detachment_id)??null,note:r(t.note)??null,history:l}}function W_(t){if(!m(t))return null;const e=r(t.run_id),n=r(t.recommended_kind),s=r(t.reason);return!e||!n||!s?null:{run_id:e,recommended_kind:n,continue_available:E(t.continue_available)??!1,rerun_available:E(t.rerun_available)??!1,abandon_available:E(t.abandon_available)??!1,reason:s,evidence:m(t.evidence)?{operation_id:r(t.evidence.operation_id)??null,detachment_id:r(t.evidence.detachment_id)??null,joined_workers:d(t.evidence.joined_workers),current_task_bound:d(t.evidence.current_task_bound),fresh_heartbeats:d(t.evidence.fresh_heartbeats),trace_events:d(t.evidence.trace_events),message_events:d(t.evidence.message_events),runtime_blocker:r(t.evidence.runtime_blocker)??null}:void 0,provenance:r(t.provenance),decision_engine:r(t.decision_engine),authoritative:E(t.authoritative)}}function G_(t){const e=m(t)?t:{},n=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),run_id:r(e.run_id),room_id:r(e.room_id),operation_id:r(e.operation_id)??null,run_resolution:H_(e.run_resolution),resolution_recommendation:W_(e.resolution_recommendation),recommended_next_tool:r(e.recommended_next_tool),summary:n?{expected_workers:d(n.expected_workers),joined_workers:d(n.joined_workers),live_workers:d(n.live_workers),squad_roster_size:d(n.squad_roster_size),detachment_roster_size:d(n.detachment_roster_size),current_task_bound:d(n.current_task_bound),fresh_heartbeats:d(n.fresh_heartbeats),claim_markers_seen:d(n.claim_markers_seen),done_markers_seen:d(n.done_markers_seen),final_markers_seen:d(n.final_markers_seen),completed_workers:d(n.completed_workers),peak_hot_slots:d(n.peak_hot_slots),hot_window_ok:E(n.hot_window_ok),pass_hot_concurrency:E(n.pass_hot_concurrency),pass_end_to_end:E(n.pass_end_to_end),pending_decisions:d(n.pending_decisions),pass:E(n.pass)}:void 0,provider:U_(e.provider),operation:Qa(e.operation),squad:wi(e.squad),detachment:gc(e.detachment),workers:Array.isArray(e.workers)?e.workers.map(B_).filter(s=>s!==null):[],checklist:Array.isArray(e.checklist)?e.checklist.map(q_).filter(s=>s!==null):[],blockers:Array.isArray(e.blockers)?e.blockers.map(F_).filter(s=>s!==null):[],recent_messages:Array.isArray(e.recent_messages)?e.recent_messages.map(K_).filter(s=>s!==null):[],recent_trace_events:Array.isArray(e.recent_trace_events)?e.recent_trace_events.map(bc).filter(s=>s!==null):[],truth_notes:B(e.truth_notes)}}function J_(t){if(!m(t))return null;const e=r(t.label),n=r(t.value);return!e||!n?null:{label:e,value:n}}function Y_(t){if(!m(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.label),a=r(t.tone),i=r(t.provenance);return!e||!n||!s||!a||!i?null:{id:e,kind:n,label:s,subtitle:r(t.subtitle)??null,status:r(t.status)??null,tone:a,pulse:r(t.pulse)??null,provenance:i,visual_class:r(t.visual_class)??void 0,glyph:r(t.glyph)??void 0,parent_id:r(t.parent_id)??null,lane_id:r(t.lane_id)??null,link_tab:r(t.link_tab)??null,link_surface:r(t.link_surface)??null,link_params:m(t.link_params)?Object.fromEntries(Object.entries(t.link_params).map(([l,c])=>{const p=r(c);return p?[l,p]:null}).filter(l=>l!==null)):{},facts:Array.isArray(t.facts)?t.facts.map(J_).filter(l=>l!==null):[]}}function V_(t){if(!m(t))return null;const e=r(t.id),n=r(t.source),s=r(t.target),a=r(t.kind),i=r(t.tone),l=r(t.provenance);return!e||!n||!s||!a||!i||!l?null:{id:e,source:n,target:s,kind:a,label:r(t.label)??null,tone:i,provenance:l,animated:E(t.animated)}}function X_(t){if(!m(t))return null;const e=r(t.id),n=r(t.kind),s=r(t.label),a=r(t.tone),i=r(t.provenance);return!e||!n||!s||!a||!i?null:{id:e,kind:n,label:s,detail:r(t.detail)??null,tone:a,provenance:i,source_id:r(t.source_id)??null,target_id:r(t.target_id)??null,suggested_surface:r(t.suggested_surface)??null,suggested_params:m(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([l,c])=>{const p=r(c);return p?[l,p]:null}).filter(l=>l!==null)):{}}}function Q_(t){if(!m(t))return null;const e=r(t.target_kind),n=r(t.target_id),s=r(t.label),a=r(t.reason);return!e||!n||!s||!a?null:{target_kind:e,target_id:n,label:s,reason:a,suggested_surface:r(t.suggested_surface)??null,suggested_params:m(t.suggested_params)?Object.fromEntries(Object.entries(t.suggested_params).map(([i,l])=>{const c=r(l);return c?[i,c]:null}).filter(i=>i!==null)):{}}}function Z_(t){const e=m(t)?t:{},n=m(e.room)?e.room:{},s=m(e.summary)?e.summary:void 0;return{version:r(e.version),generated_at:r(e.generated_at),room:{room_id:r(n.room_id),project:r(n.project),cluster:r(n.cluster),paused:E(n.paused),pause_reason:r(n.pause_reason)??null,agent_count:d(n.agent_count),task_count:d(n.task_count),message_count:d(n.message_count)},summary:s?{session_count:d(s.session_count),operation_count:d(s.operation_count),detachment_count:d(s.detachment_count),lane_count:d(s.lane_count),worker_count:d(s.worker_count),keeper_count:d(s.keeper_count),signal_count:d(s.signal_count),alert_count:d(s.alert_count)}:void 0,nodes:Array.isArray(e.nodes)?e.nodes.map(Y_).filter(a=>a!==null):[],edges:Array.isArray(e.edges)?e.edges.map(V_).filter(a=>a!==null):[],signals:Array.isArray(e.signals)?e.signals.map(X_).filter(a=>a!==null):[],focus:Q_(e.focus),swarm_status:qi(e.swarm_status),swarm_proof:kc(e.swarm_proof),truth_notes:B(e.truth_notes)}}function ce(t){tt.value=t,Di(t)&&tv()}async function Cc(){fa.value=!0,$a.value=null;try{const t=await bu();Ei.value=C_(t)}catch(t){$a.value=t instanceof Error?t.message:"Failed to load command-plane summary"}finally{fa.value=!1}}function Fi(t){sn.value=t}async function Ki(){ga.value=!0,ha.value=null;try{const t=await yu();Bt.value=S_(t)}catch(t){ha.value=t instanceof Error?t.message:"Failed to load command-plane snapshot"}finally{ga.value=!1}}async function tv(){Bt.value||ga.value||await Ki()}async function We(){await Cc(),Di(tt.value)&&await Ki()}async function an(){var t;li.value=!0,Ca.value=null;try{const e=await ku(),n=z_(e);us.value=n;const s=sn.value;n.operations.length===0?sn.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(sn.value=((t=n.operations[0])==null?void 0:t.operation.operation_id)??null)}catch(e){Ca.value=e instanceof Error?e.message:"Failed to load chain summary"}finally{li.value=!1}}function ev(){Tn=null,Wn.value=null,Aa.value=!1,Gn.value=null}async function nv(t){Tn=t,Aa.value=!0,Gn.value=null;try{const e=await xu(t);if(Tn!==t)return;Wn.value=M_(e)}catch(e){if(Tn!==t)return;Wn.value=null,Gn.value=e instanceof Error?e.message:"Failed to load chain run"}finally{Tn===t&&(Aa.value=!1)}}async function sv(){ii.value=!0,ba.value=null;try{const t=await Su();ds.value=w_(t)}catch(t){ba.value=t instanceof Error?t.message:"Failed to load command-plane help"}finally{ii.value=!1}}async function se(t=pc(),e=mc()){ka.value=!0,xa.value=null;try{const n=await Cu(t,e);De.value=G_(n)}catch(n){xa.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{ka.value=!1}}async function Le(t=pc(),e=mc()){ri.value=!0,Sa.value=null;try{const n=await Au(t,e);Oi.value=Z_(n)}catch(n){Sa.value=n instanceof Error?n.message:"Failed to load orchestra map"}finally{ri.value=!1}}async function $e(t,e,n){oi.value=t,ya.value=null;try{await Tu(e,n),await Cc(),(Bt.value||Di(tt.value))&&await Ki(),await se(),await Le(),await an()}catch(s){throw ya.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{oi.value=null}}function av(t){return $e(`pause:${t}`,"/api/v1/command-plane/operations/pause",{operation_id:t})}function ov(t){return $e(`resume:${t}`,"/api/v1/command-plane/operations/resume",{operation_id:t})}function iv(t){return $e(`recall:${t}`,"/api/v1/command-plane/dispatch/recall",{operation_id:t})}function rv(t={}){return $e("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...t.operationId?{operation_id:t.operationId}:{},...t.detachmentId?{detachment_id:t.detachmentId}:{}})}function lv(t){return $e(`approve:${t}`,"/api/v1/command-plane/policy/approve",{decision_id:t})}function cv(t){return $e(`deny:${t}`,"/api/v1/command-plane/policy/deny",{decision_id:t})}function dv(t,e){return $e(`freeze:${t}`,"/api/v1/command-plane/policy/freeze",{unit_id:t,enabled:e})}function uv(t,e){return $e(`kill:${t}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:t,enabled:e})}Tm(()=>{We(),an(),(tt.value==="swarm"||tt.value==="warroom"||tt.value==="orchestra"||De.value!==null)&&se(),(tt.value==="orchestra"||Oi.value!==null)&&Le(),tt.value==="warroom"&&xt()});function ci(t){t==="command"&&(Re(),We(),an(),(tt.value==="swarm"||tt.value==="warroom"||tt.value==="orchestra")&&se(),tt.value==="orchestra"&&Le(),tt.value==="warroom"&&xt()),t==="mission"&&(Re(),lc(),va()),t==="proof"&&dc(F.value.params.session_id,F.value.params.operation_id),t==="execution"&&(Re(),ze()),t==="intervene"&&(Re(),xt(),Ee()),t==="memory"&&re(),t==="planning"&&Pi(),t==="lab"&&le()}function pv({metric:t}){return o`
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
  `}function mv({panel:t}){return o`
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
            ${t.metrics.map(e=>o`<${pv} key=${e.id} metric=${e} />`)}
          </div>`:null}
    </div>
  `}function K({panelId:t,compact:e=!1,label:n="왜 필요한가"}){const s=_m(t);return s?o`
    <details class="semantic-inline ${e?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${mv} panel=${s} />
    </details>
  `:ca.value?o`<span class="semantic-inline-state">의미 계층 불러오는 중…</span>`:null}function St({surfaceId:t,compact:e=!1}){const n=mm(t);return n?o`
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
  `:ca.value?o`<div class="semantic-surface-card ${e?"compact":""}">의미 계층 불러오는 중…</div>`:da.value?o`<div class="semantic-surface-card ${e?"compact":""}">${da.value}</div>`:null}function I({title:t,class:e,semanticId:n,testId:s,children:a}){return o`
    <div class="card ${e??""}" data-testid=${s}>
      ${t?o`
            <div class="card-title-row">
              <div class="card-title">${t}</div>
              ${n?o`<${K} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}function lo(t){const e=(t??"").trim().toLowerCase();return e==="bad"||e==="critical"||e==="offline"?"bad":e==="warn"||e==="paused"||e==="blocked"?"warn":"ok"}function _v(){var n;const t=(n=Ni.value)==null?void 0:n.focus;if(!(t!=null&&t.suggested_tab))return;const e=t.suggested_params??{};if(t.suggested_tab==="intervene"){it("intervene",e);return}it("command",{...t.suggested_surface?{surface:t.suggested_surface}:{},...e})}function Za(){var p,_,u,f,v,h;const t=Ni.value;if(!t)return ei.value?o`<section class="room-truth-strip room-truth-strip-loading">room truth 불러오는 중...</section>`:ua.value?o`<section class="room-truth-strip room-truth-strip-error">${ua.value}</section>`:null;const e=t.room.status,n=t.room.counts,s=(p=t.execution)==null?void 0:p.summary,a=(_=t.execution)==null?void 0:_.top_queue,i=t.command,l=t.operator,c=t.focus;return o`
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
          <span class="command-chip ${lo(((s==null?void 0:s.blocked_sessions)??0)>0?"warn":"ok")}">priority ${(s==null?void 0:s.priority_items)??0}</span>
          <span class="command-chip">${((u=t.execution)==null?void 0:u.provenance)??"derived"}</span>
        </div>
      </article>

      <article class="room-truth-card">
        <span class="room-truth-label">control</span>
        <strong>작전 ${(i==null?void 0:i.active_operations)??0} · 승인 ${(i==null?void 0:i.pending_approvals)??0}</strong>
        <p>alerts bad ${(i==null?void 0:i.bad_alerts)??0} / warn ${(i==null?void 0:i.warn_alerts)??0} · lanes ${(i==null?void 0:i.moving_lanes)??0}/${(i==null?void 0:i.active_lanes)??0}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${lo(((i==null?void 0:i.bad_alerts)??0)>0?"bad":((i==null?void 0:i.warn_alerts)??0)>0||((i==null?void 0:i.pending_approvals)??0)>0?"warn":"ok")}">
            health ${(l==null?void 0:l.health)??"ok"}
          </span>
          <span class="command-chip">${(i==null?void 0:i.provenance)??"truth"}</span>
        </div>
      </article>

      <article class="room-truth-card room-truth-card-focus">
        <span class="room-truth-label">next focus</span>
        <strong>${(c==null?void 0:c.label)??"지금은 방 전체가 비교적 안정적입니다"}</strong>
        <p>${(c==null?void 0:c.reason)??((v=(f=l==null?void 0:l.attention_summary)==null?void 0:f.top_item)==null?void 0:v.summary)??(a==null?void 0:a.summary)??"다음 drill-down 대상이 아직 없습니다."}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${lo((c==null?void 0:c.provenance)==="fallback"?"warn":"ok")}">${(c==null?void 0:c.source)??"steady"}</span>
          <span class="command-chip">${(c==null?void 0:c.provenance)??((h=l==null?void 0:l.recommendation_summary)==null?void 0:h.provenance)??"derived"}</span>
        </div>
        ${c!=null&&c.suggested_tab?o`
              <div class="room-truth-actions">
                <button class="control-btn ghost" onClick=${_v}>
                  ${c.suggested_tab==="intervene"?"개입면 열기":"지휘면 열기"}
                </button>
              </div>
            `:null}
      </article>
    </section>
  `}const Ta="masc_dashboard_workflow_context",vv=900*1e3;function yt(t){return typeof t=="string"&&t.trim()!==""?t.trim():null}function Zt(t){const e=yt(t);return e||(typeof t=="number"&&Number.isFinite(t)?String(t):null)}function Ac(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function di(t){return m(t)?t:null}function fv(t){if(!t)return null;try{return JSON.stringify(t)}catch{return null}}function gv(t){if(!t)return null;try{const e=JSON.parse(t);if(!m(e))return null;const n=yt(e.id),s=yt(e.source_surface),a=yt(e.source_label),i=yt(e.summary),l=yt(e.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!i||!l?null:{id:n,source_surface:s,source_label:a,action_type:yt(e.action_type),target_type:yt(e.target_type),target_id:yt(e.target_id),focus_kind:yt(e.focus_kind),operation_id:yt(e.operation_id),command_surface:yt(e.command_surface),summary:i,payload_preview:yt(e.payload_preview),suggested_payload:di(e.suggested_payload),preview:e.preview??null,evidence:e.evidence??null,created_at:l}}catch{return null}}function Bi(t){const e=Date.parse(t.created_at);return Number.isNaN(e)?!1:Date.now()-e<=vv}function $v(){const t=Ac(),e=gv((t==null?void 0:t.getItem(Ta))??null);return e?Bi(e)?e:(t==null||t.removeItem(Ta),null):null}const Tc=g($v());function Ic(t){const e=t&&Bi(t)?t:null;Tc.value=e;const n=Ac();if(!n)return;if(!e){n.removeItem(Ta);return}const s=fv(e);s&&n.setItem(Ta,s)}function hv(t){if(!t)return null;const e=di(t.suggested_payload);if(e)return e;if(m(t.preview)){const n=di(t.preview.payload);if(n)return n}return null}function yv(t){if(!t)return null;const e=Zt(t.message);if(e)return e;const n=Zt(t.task_title)??Zt(t.title),s=Zt(t.task_description)??Zt(t.description),a=Zt(t.reason),i=Zt(t.priority)??Zt(t.task_priority);return n&&s?`${n} · ${s}`:n&&i?`${n} · P${i}`:n||s||a||null}function Ui(t,e,n,s,a,i,l,c){return[t,e,n??"action",s??"target",a??"room",i??"focus",l??"operation",c].join(":")}function hn(t,e,n="상황판 추천 액션"){const s=new Date().toISOString(),a=hv(t),i=(t==null?void 0:t.target_type)??(e==null?void 0:e.target_type)??null,l=(t==null?void 0:t.target_id)??(e==null?void 0:e.target_id)??null,c=(e==null?void 0:e.kind)??(t==null?void 0:t.action_type)??null,p=(t==null?void 0:t.reason)??(e==null?void 0:e.summary)??n;return{id:Ui("mission",n,(t==null?void 0:t.action_type)??null,i,l,c,null,s),source_surface:"mission",source_label:n,action_type:(t==null?void 0:t.action_type)??null,target_type:i,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:p,payload_preview:yv(a),suggested_payload:a,preview:(t==null?void 0:t.preview)??null,evidence:(e==null?void 0:e.evidence)??null,created_at:s}}function bv({targetType:t,targetId:e,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:i=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:Ui("execution",s,null,t,e,n,i,c),source_surface:"execution",source_label:s,action_type:null,target_type:t,target_id:e,focus_kind:n,operation_id:i,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function kv(t,e){return(e.source==="mission"||e.source==="execution")&&(e.action_type??null)===(t.action_type??null)&&(e.target_type??null)===(t.target_type??null)&&(e.target_id??null)===(t.target_id??null)&&(e.focus_kind??null)===(t.focus_kind??null)&&(e.operation_id??null)===(t.operation_id??null)}function ps(t){const{params:e}=t;if(e.source!=="mission"&&e.source!=="execution")return null;const n=Tc.value;if(n&&Bi(n)&&kv(n,e))return n;const s=new Date().toISOString(),a=e.source==="execution"?"execution":"mission";return{id:Ui(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",e.action_type??null,e.target_type??null,e.target_id??null,e.focus_kind??null,e.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:e.action_type??null,target_type:e.target_type??null,target_id:e.target_id??null,focus_kind:e.focus_kind??e.action_type??null,operation_id:e.operation_id??null,command_surface:e.surface??null,summary:a==="execution"?e.focus_kind?`${e.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":e.focus_kind?`${e.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function zc(t){return{source:t.source_surface,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function Rc(t){if(t.command_surface)return t.command_surface;const e=[t.focus_kind,t.summary,t.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"summary":e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")||e.includes("swarm")?"swarm":t.focus_kind==="operation"||t.target_type==="operation"?"operations":t.target_type==="room"?"orchestra":"swarm"}function Mc(t){return{source:t.source_surface,surface:Rc(t),...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function xv(t){return zc(t)}function Sv(t){return Mc(t)}function Hi(t){return t!=null&&t.target_type?t.target_id?`${t.target_type} · ${t.target_id}`:t.target_type:"대상 정보 없음"}function to(t){switch(t){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(t==null?void 0:t.trim())||"추천 액션"}}function Cv(t){switch(t){case"warroom":return"워룸";case"summary":return"요약";case"orchestra":return"오케스트라";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(t==null?void 0:t.trim())||"지휘"}}const Gt=g(null),ae=g(null);function Pt(t,e=120){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-1)}…`:n:null}function gt(t){return t==="bad"||t==="offline"||t==="critical"||t==="risk"?"bad":t==="warn"||t==="pending"||t==="degraded"||t==="interrupted"||t==="watch"?"warn":"ok"}function wt(t){if(!t)return"방금";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function Av(t){return typeof t!="number"||!Number.isFinite(t)||t<0?"확인 필요":t<60?`${Math.round(t)}초`:t<3600?`${Math.round(t/60)}분`:t<86400?`${Math.round(t/3600)}시간`:`${Math.round(t/86400)}일`}function qt(t){switch((t??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"pending":return"대기 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":case"watch":return"주의";case"bad":case"critical":case"risk":return"위험";case"degraded":return"저하";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"loading":return"불러오는 중";case"error":return"오류";case"unavailable":return"사용 불가";case"stale":return"오래됨";case"refreshing":return"갱신 중";case"cached":return"캐시";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Ia(t){switch((t??"").trim().toLowerCase()){case"room":return"방";case"team_session":case"session":return"세션";case"operation":return"작전";case"keeper":return"키퍼";case"agent":return"에이전트";default:return(t==null?void 0:t.trim())||"대상"}}function Ar(t){switch((t??"").trim().toLowerCase()){case"metadata_gap":return"메타데이터 부족";case"mixed":return"신호 혼재";case"":return null;default:return(t==null?void 0:t.trim())||null}}function Tv(t){return t!=null&&t.confirm_required?"확인 후 실행":"즉시 실행"}function Iv(t){return Hi(t?hn(t,null,"상황판 추천 액션"):null)}function eo(t,e=hn()){Ic(e),it(t,t==="intervene"?xv(e):Sv(e))}function Lc(t){eo("intervene",hn(null,t,"상황판 incident"))}function Pc(t){eo("command",hn(null,t,"상황판 incident"))}function Wi(t,e,n="상황판 추천 액션"){eo("intervene",hn(t,e,n))}function Nc(t,e,n="상황판 추천 액션"){eo("command",hn(t,e,n))}function ui(t,e){const n={source:"mission",target_type:"team_session",target_id:e,focus_kind:"team_session"};t==="command"&&(n.surface="swarm"),it(t,n)}function zv(t){return{kind:t.kind,severity:t.severity,summary:t.summary,target_type:t.target_type,target_id:t.target_id??null,actor:null,evidence:t.evidence_preview}}function Rv(t){var n,s;const e=ge.value.find(a=>a.name===t.name||a.agent_name===t.agent_name)??null;return{brief:t,keeper:e,currentWork:Pt(t.current_work,110)??Pt(e==null?void 0:e.skill_primary,110)??Pt(e==null?void 0:e.last_proactive_reason,110)??"명시된 키퍼 초점 없음",recentInput:Pt(e==null?void 0:e.recent_input_preview,120)??null,recentOutput:Pt(e==null?void 0:e.recent_output_preview,120)??Pt((n=e==null?void 0:e.diagnostic)==null?void 0:n.last_reply_preview,120)??Pt(e==null?void 0:e.last_proactive_preview,120)??null,recentEvent:Pt(e==null?void 0:e.last_proactive_reason,120)??Pt((s=e==null?void 0:e.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(e==null?void 0:e.recent_tool_names)??[]}}function Mv(){const t=cs.value;if(!t)return new Map;const e=t.sessions.length>0?t.sessions:t.session_briefs;return new Map(e.map(n=>[n.session_id,n]))}function Lv(t){Gt.value=Gt.value===t?null:t,ae.value=null}function jc(t){ae.value=ae.value===t?null:t,Gt.value=null}function Pv(){Gt.value=null,ae.value=null}function co(t){return(t==null?void 0:t.trim().toLowerCase())??""}function ms(t){var e,n;return t?((e=t.agent)==null?void 0:e.exists)===!1||co((n=t.diagnostic)==null?void 0:n.health_state)==="offline"||co(t.status)==="offline"||co(t.status)==="inactive"?"offline":"online":"unlinked"}function Jt(t){switch(t){case"offline":return"offline";case"none_recent":return"none_recent";case"not_applicable":return"not_applicable";case"unlinked":return"unlinked";default:return"not_collected"}}function Ec(t){const e=ms(t);return e==="unlinked"?"unlinked":e==="offline"?"offline":"not_collected"}function Oc(t,e){const n=ms(t);return n==="unlinked"?"unlinked":n==="offline"?"offline":e!=null&&e.trim()?"none_recent":"not_collected"}function Dc(t,e){const n=ms(t);return n==="unlinked"?"unlinked":n==="offline"?"offline":e!=null&&e.trim()?"none_recent":"not_collected"}function Gi(t){const e=ms(t);return e==="unlinked"?"unlinked":e==="offline"?"offline":"none_recent"}function wc(t){const e=t==null?void 0:t.trim();it("tools",e?{q:e}:void 0)}function Nv(t){switch(t.trim().toLowerCase()){case"active":case"running":return"가동 중";case"working":return"작업 중";case"watching":return"관찰 중";case"quiet":return"조용함";case"idle":return"유휴";case"ok":case"healthy":return"정상";case"warn":case"warning":case"degraded":return"주의";case"bad":case"critical":case"error":case"failed":return"위험";case"blocked":return"막힘";case"paused":return"일시정지";case"pending":return"대기";case"offline":case"inactive":return"오프라인";case"connected":return"연결됨";case"disconnected":return"끊김";case"ready":return"준비됨";case"done":case"completed":return"완료";case"unknown":return"알 수 없음";default:return t}}function he({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??Nv(t)}
    </span>
  `}function qc(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}초 전`;const a=Math.floor(s/60);if(a<60)return`${a}분 전`;const i=Math.floor(a/60);return i<24?`${i}시간 전`:`${Math.floor(i/24)}일 전`}function X({timestamp:t}){const e=qc(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}let jv=0;const Pe=g([]);function O(t,e="success",n=4e3){const s=++jv;Pe.value=[...Pe.value,{id:s,message:t,type:e}],setTimeout(()=>{Pe.value=Pe.value.filter(a=>a.id!==s)},n)}function Ev(t){Pe.value=Pe.value.filter(e=>e.id!==t)}function Ov(){const t=Pe.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Ev(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Dv="masc_dashboard_agent_name",yn=g(null),za=g(!1),Jn=g(""),Ra=g([]),Yn=g([]),on=g(""),Nn=g(!1);function _s(t){yn.value=t,Ji()}function Tr(){yn.value=null,Jn.value="",Ra.value=[],Yn.value=[],on.value=""}function wv(){const t=yn.value;return t?Qt.value.find(e=>e.name===t)??null:null}function Fc(t){return t?oe.value.filter(e=>e.assignee===t):[]}function Kc(t){return t?ge.value.find(e=>e.agent_name===t||e.name===t)??null:null}function qv(t){if(!t)return null;const e=cs.value;return e?e.agent_briefs.find(n=>n.agent_name===t)??null:null}function Fv(t){if(!t)return[];const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Kv(t){const e=Kc(t);return e?e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]:[]}function Ir(...t){for(const e of t)if(e&&e.length>0)return e;return[]}function Bv(t){return t?zi.value.find(e=>e.agent_name===t||e.name===t)??null:null}function Uv(t){return t?Ii.value.find(e=>e.agent_name===t||e.worker_name===t)??null:null}async function Ji(){const t=yn.value;if(t){za.value=!0,Jn.value="",Ra.value=[],Yn.value=[];try{const e=await rp(80);Ra.value=e.filter(a=>a.includes(t)).slice(0,20);const n=Fc(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await lp(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const l=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));Yn.value=s}catch(e){Jn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{za.value=!1}}}async function zr(){var s;const t=yn.value,e=on.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(Dv))==null?void 0:s.trim())||"dashboard";Nn.value=!0;try{await ip(n,`@${t} ${e}`),on.value="",O(`Mention sent to ${t}`,"success"),Ji()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";O(i,"error")}finally{Nn.value=!1}}function Hv({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${he} status=${t.status} />
    </div>
  `}function Wv({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Gv(){var W,Y,st,P,T,C,D;const t=yn.value;if(!t)return null;const e=wv(),n=Kc(t),s=Bv(t),a=Uv(t),i=qv(t),l=Fc(t),c=Ra.value,p=Kv(t),_=Fv(n),u=Ir(s==null?void 0:s.allowed_tool_names,i==null?void 0:i.allowed_tool_names,a==null?void 0:a.allowed_tool_names,n==null?void 0:n.allowed_tool_names),f=Ir(s==null?void 0:s.latest_tool_names,i==null?void 0:i.latest_tool_names,a==null?void 0:a.used_tool_names,n==null?void 0:n.latest_tool_names),v=(s==null?void 0:s.latest_tool_call_count)??(i==null?void 0:i.latest_tool_call_count)??(a==null?void 0:a.used_tool_call_count)??(n==null?void 0:n.latest_tool_call_count),h=(s==null?void 0:s.tool_audit_source)??(i==null?void 0:i.tool_audit_source)??(a==null?void 0:a.tool_audit_source)??(n==null?void 0:n.tool_audit_source),A=(s==null?void 0:s.tool_audit_at)??(i==null?void 0:i.tool_audit_at)??(a==null?void 0:a.tool_audit_at)??(n==null?void 0:n.tool_audit_at),k=(e==null?void 0:e.capabilities)??[],S=((W=lt.value)==null?void 0:W.room)??"default",b=((Y=lt.value)==null?void 0:Y.project)??"확인 없음",$=((st=lt.value)==null?void 0:st.cluster)??"확인 없음",R=Jt(Ec(n)),M=Jt(Oc(n,h)),L=Jt(Dc(n,h)),J=Jt(Gi(n)),z=u[0]??f[0]??p[0]??null;return o`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${j=>{j.target.classList.contains("agent-detail-overlay")&&Tr()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${e!=null&&e.emoji?o`<span style="font-size:2rem">${e.emoji}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${t}
                  ${e!=null&&e.koreanName?o`<span style="font-size:0.75em;color:#888">(${e.koreanName})</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  ${e?o`
                        <${he} status=${e.status} />
                        ${e.model?o`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                        ${e.primaryValue?o`<span style="font-size:0.75rem;color:#a78bfa">${e.primaryValue}</span>`:""}
                      `:o`<span>Agent snapshot not found in current state</span>`}
                </div>
              </div>
            </div>
            ${(e==null?void 0:e.activityLevel)!=null?o`
              <div style="display:flex;align-items:center;gap:8px;font-size:0.8rem">
                <span style="color:#888">Activity</span>
                <div style="flex:1;max-width:120px;height:6px;background:#1a1a2e;border-radius:3px;overflow:hidden">
                  <div style="width:${Math.min(e.activityLevel*10,100)}%;height:100%;background:${e.activityLevel>=8?"#22c55e":e.activityLevel>=5?"#f59e0b":"#666"};border-radius:3px"></div>
                </div>
                <span style="color:#888">${e.activityLevel}/10</span>
              </div>
            `:""}
            ${(((P=e==null?void 0:e.traits)==null?void 0:P.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(T=e==null?void 0:e.traits)==null?void 0:T.map(j=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${j}</span>`)}
              </div>
            `:""}
            ${(((C=e==null?void 0:e.interests)==null?void 0:C.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(D=e==null?void 0:e.interests)==null?void 0:D.map(j=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${j}</span>`)}
              </div>
            `:""}
            ${k.length>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${k.map(j=>o`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${j}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${X} timestamp=${e.last_seen} /></span>`:null}
                    <span>Room: ${S}</span>
                    <span>Project: ${b}</span>
                    <span>Cluster: ${$}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Ji()}} disabled=${za.value}>
              ${za.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Tr}>Close</button>
          </div>
        </div>

        ${Jn.value?o`<div class="council-error">${Jn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${I} title="Assigned Tasks">
            ${l.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${l.map(j=>o`<${Hv} key=${j.id} task=${j} />`)}</div>`}
          <//>

          <${I} title="Recent Activity">
            ${c.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${c.map((j,Q)=>o`<div key=${Q} class="agent-activity-line">${j}</div>`)}</div>`}
          <//>
        </div>

        <${I} title="Capabilities & Tool Audit">
          <div style="display:flex; flex-direction:column; gap:12px;">
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Capabilities</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${k.length>0?k.map(j=>o`<span class="pill">${j}</span>`):o`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
              </div>
            </div>
            <div style="display:flex; justify-content:flex-end;">
              <button class="control-btn ghost" onClick=${()=>{wc(z)}}>
                Open tools panel
              </button>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Allowed tools</div>
              <div style="font-size:11px; color:#64748b; margin-bottom:6px;">Currently permitted tools for this runtime, not the full system inventory.</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${u.length>0?u.map(j=>o`<span class="pill">${j}</span>`):o`<span class="empty-state" style="font-size:12px;">${R}</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Observed tools</div>
              <div style="font-size:11px; color:#64748b; margin-bottom:6px;">Recent execution evidence, not policy allowlist.</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${f.length>0?f.map(j=>o`<span class="pill">${j}</span>`):o`<span class="empty-state" style="font-size:12px;">${M}</span>`}
              </div>
            </div>
            <div class="agent-detail-sub">
              <span>Tool calls: ${typeof v=="number"?v:M==="none_recent"?0:L}</span>
              <span>Evidence source: ${h??L}</span>
              <span>
                Observed at:
                ${A?o` <${X} timestamp=${A} />`:` ${L}`}
              </span>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Linked keeper recent tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${p.length>0?p.map(j=>o`<span class="pill">${j}</span>`):o`<span class="empty-state" style="font-size:12px;">${J}</span>`}
              </div>
            </div>
            ${_.length>0?o`
                  <div>
                    <div style="font-size:12px; color:#888; margin-bottom:6px;">Keeper window top tools</div>
                    <div style="display:flex; flex-wrap:wrap; gap:6px;">
                      ${_.map(j=>o`<span class="pill">${j}</span>`)}
                    </div>
                  </div>
                `:null}
            ${n?o`
                  <div style="font-size:12px; color:#888;">
                    Linked keeper: <span style="color:#4ade80;">${n.name}</span>
                    ${n.skill_primary?o` · route <span style="color:#22d3ee;">${n.skill_primary}</span>`:null}
                  </div>
                `:null}
            ${s!=null&&s.continuity_summary||s!=null&&s.skill_route_summary?o`
                  <div class="agent-detail-sub">
                    ${s!=null&&s.continuity_summary?o`<span>${s.continuity_summary}</span>`:null}
                    ${s!=null&&s.skill_route_summary?o`<span>Route: ${s.skill_route_summary}</span>`:null}
                  </div>
                `:null}
          </div>
        <//>

        ${a?o`
              <${I} title="Latest Lodge Check-in">
                <div class="agent-detail-sub">
                  <span>Outcome: ${a.outcome}</span>
                  <span>Trigger: ${a.trigger??"unknown"}</span>
                  <span>Action: ${a.action_kind??"none"}</span>
                  ${a.checked_at?o`<span>Checked: <${X} timestamp=${a.checked_at} /></span>`:null}
                </div>
                ${a.reason?o`<div class="monitor-footnote">${a.reason}</div>`:null}
                ${a.summary&&a.summary!==a.reason?o`<div class="monitor-footnote">${a.summary}</div>`:null}
                ${a.failure_reason?o`<div class="monitor-footnote">Failure: ${a.failure_reason}</div>`:a.decision_reason?o`<div class="monitor-footnote">Decision: ${a.decision_reason}</div>`:null}
              <//>
            `:null}

        <${I} title="Task History">
          ${Yn.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Yn.value.map(j=>o`<${Wv} key=${j.taskId} row=${j} />`)}</div>`}
        <//>

        <${I} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${on.value}
              onInput=${j=>{on.value=j.target.value}}
              onKeyDown=${j=>{j.key==="Enter"&&zr()}}
              disabled=${Nn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{zr()}}
              disabled=${Nn.value||on.value.trim()===""}
            >
              ${Nn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Jv(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Yv(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Vv(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Rr(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function Bc(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function Xv(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function Mr(t){switch(t){case"desired_offline":return"desired offline";case"recovering":return"recovering";case"healthy":return"healthy";case"offline":return"offline";default:return null}}function Uc(t){if(!t)return null;const e=Vt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function Qv({keeper:t,showRawStatus:e=!1}){if(ot(()=>{t!=null&&t.name&&Ml(t.name)},[t==null?void 0:t.name]),!t)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Vt.value[t.name],s=Uc(t),a=Wo.value[t.name];return s?o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        ${Mr(s==null?void 0:s.continuity_state)?o`<span class="pill">${Mr(s==null?void 0:s.continuity_state)}</span>`:null}
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Jv(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Yv((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.continuity_summary)??(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${s.last_reply_status}
        ${s.last_reply_at?o` · ${Bc(s.last_reply_at)}`:null}
        ${s.next_eligible_at_s?o` · next eligible ${Xv(s.next_eligible_at_s)}`:null}
      </div>
      ${s.last_error?o`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `:o`
      <div class="control-result-box">
        <div class="control-status-copy">
          실시간 진단 데이터가 아직 없습니다.
        </div>
        ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
      </div>
    `}function Zv({keeperName:t,placeholder:e}){const[n,s]=xi("");ot(()=>{t&&Ml(t)},[t]);const a=_t.value[t]??[],i=Go.value[t]??!1,l=Xt.value[t],c=async()=>{const p=n.trim();if(!(!t||!p)){s("");try{await Ip(t,p)}catch(_){const u=_ instanceof Error?_.message:`Failed to message ${t}`;O(u,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(p=>o`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Rr(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${Rr(p)}`}>${Vv(p)}</span>
                  ${p.timestamp?o`<span class="keeper-conversation-time">${Bc(p.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${p.text}</div>
                ${p.error?o`<div class="keeper-conversation-error">${p.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${p=>{s(p.target.value)}}
          disabled=${i||!t}
        ></textarea>
        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${()=>{c()}}
            disabled=${i||n.trim()===""||!t}
          >
            ${i?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${l?o`<div class="control-status-copy control-error-copy">${l}</div>`:null}
      </div>
    </div>
  `}function tf({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const s=Uc(e),a=Jo.value[e.name]??!1,i=Yo.value[e.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{zp(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to probe ${e.name}`;O(_,"error")})}}
        disabled=${a||!t.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{Rp(e.name,t).catch(p=>{const _=p instanceof Error?p.message:`Failed to recover ${e.name}`;O(_,"error")})}}
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
  `}const Yi=g(null);function Hc(t){Yi.value=t,Tp(t.name)}function Lr(){Yi.value=null}const Fe=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function ef(t){if(!t)return 0;const e=Fe.findIndex(n=>n.level===t);return e>=0?e:0}function nf({keeper:t}){const e=ef(t.autonomy_level),n=Fe[e]??Fe[0];if(!n)return null;const s=(e+1)/Fe.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${Fe.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Fe.map((a,i)=>o`
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
            <strong><${X} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Zs(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function sf(t){switch(t){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(t==null?void 0:t.trim())||"action"}}function af(t){return t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]}function of(t){const e=t.metrics_window;return(Array.isArray(e==null?void 0:e.top_tools)?e.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function rf(t){const e=cs.value;return e?e.keeper_briefs.find(n=>n.name===t.name||n.agent_name&&t.agent_name&&n.agent_name===t.agent_name)??null:null}function lf({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=n&&Number.isFinite(n.cost_usd)?`$${n.cost_usd.toFixed(4)}`:null,a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Zs(t.context_tokens)}</div>
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
  `}function cf({keeper:t}){var u,f;const e=t.metrics_series??[];if(e.length<2){const v=(((u=t.context)==null?void 0:u.context_ratio)??0)*100,h=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${h}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,l=e.map((v,h)=>{const A=a+h/(i-1)*(n-2*a),k=s-a-(v.context_ratio??0)*(s-2*a);return{x:A,y:k,p:v}}),c=l.map(({x:v,y:h})=>`${v.toFixed(1)},${h.toFixed(1)}`).join(" "),p=(((f=e[e.length-1])==null?void 0:f.context_ratio)??0)*100,_=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:v})=>v.is_handoff).map(({x:v})=>o`
          <line x1="${v.toFixed(1)}" y1="${a}" x2="${v.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${_}" stroke-width="1.5"/>
        ${l.filter(({p:v})=>v.is_compaction).map(({x:v,y:h})=>o`
          <circle cx="${v.toFixed(1)}" cy="${h.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}const uo=g("");function df({keeper:t}){var a,i,l,c;const e=uo.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(p=>p.title.toLowerCase().includes(e)||p.key.includes(e)||p.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${uo.value}
        onInput=${p=>{uo.value=p.target.value}}
      />
      ${s.map(p=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${p.title}</span>
          <span class="keeper-field-key">${p.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${p.value}</span>
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Zs(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Zs(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Zs(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=t.context)==null?void 0:l.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function uf({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function pf({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function mf({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Pr({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function po(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function _f({keeper:t}){const e=t.metrics_window,s=[{label:"Model fallback",value:po(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:po(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:po(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}].filter(a=>!(a.value==="-"||a.value==="—"||a.value===""));return s.length===0?null:o`
    <div class="keeper-signal-list">
      ${s.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function vf({keeper:t}){var z,W,Y,st,P,T,C;const e=((z=$t.value)==null?void 0:z.room)??{},n=(((W=$t.value)==null?void 0:W.available_actions)??[]).filter(D=>D.target_type==="keeper"||D.target_type==="room").slice(0,8),s=af(t),a=of(t),i=rf(t),l=i!=null&&i.allowed_tool_names&&i.allowed_tool_names.length>0?i.allowed_tool_names:t.allowed_tool_names??[],c=i!=null&&i.latest_tool_names&&i.latest_tool_names.length>0?i.latest_tool_names:t.latest_tool_names??[],p=(i==null?void 0:i.latest_tool_call_count)??t.latest_tool_call_count,_=(i==null?void 0:i.tool_audit_source)??t.tool_audit_source,u=(i==null?void 0:i.tool_audit_at)??t.tool_audit_at,f=((Y=t.agent)==null?void 0:Y.capabilities)??[],v=e.current_room??e.room_id??((st=lt.value)==null?void 0:st.room)??"default",h=e.project??((P=lt.value)==null?void 0:P.project)??"확인 없음",A=e.cluster??((T=lt.value)==null?void 0:T.cluster)??"확인 없음",k=Jt(Ec(t)),S=Jt(Oc(t,_)),b=Jt(Dc(t,_)),$=Jt(Gi(t)),R=ms(t),M=((C=t.agent)==null?void 0:C.current_task)??(R==="offline"?"offline":"not_collected"),L=t.skill_primary??(R==="offline"?"offline":"not_collected"),J=l[0]??c[0]??s[0]??null;return o`
    <div class="keeper-signal-list">
      <div class="keeper-signal-row">
        <span>Room</span>
        <strong>${v}</strong>
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
        <strong>${L}</strong>
      </div>
      <div style="display:flex; justify-content:flex-end; margin-top:4px;">
        <button class="control-btn ghost" onClick=${()=>{wc(J)}}>
          Open tools panel
        </button>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Allowed tools</span>
        <span style="font-size:11px; color:#64748b;">Currently permitted tools for this keeper runtime.</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${l.length>0?l.map(D=>o`<span class="pill">${D}</span>`):o`<span style="font-size:12px; color:#888;">${k}</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Observed tools</span>
        <span style="font-size:11px; color:#64748b;">Recent execution evidence from heartbeat or runtime telemetry.</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${c.length>0?c.map(D=>o`<span class="pill">${D}</span>`):o`<span style="font-size:12px; color:#888;">${S}</span>`}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Tool calls</span>
        <strong>${typeof p=="number"?p:S==="none_recent"?0:b}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Evidence source</span>
        <strong>${_??b}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Observed at</span>
        <strong>${u?o`<${X} timestamp=${u} />`:b}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Keeper recent tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${s.length>0?s.map(D=>o`<span class="pill">${D}</span>`):o`<span style="font-size:12px; color:#888;">${$}</span>`}
        </div>
      </div>
      ${a.length>0?o`
            <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
              <span style="font-size:12px; color:#888;">Window top tools</span>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${a.map(D=>o`<span class="pill">${D}</span>`)}
              </div>
            </div>
          `:null}
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${f.length>0?f.map(D=>o`<span class="pill">${D}</span>`):o`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(D=>o`<span class="pill">${sf(D.action_type)}</span>`):o`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function Wc(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function ff(){try{const t=await Ya({actor:Wc(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=Rl(t.result);await ls(),e!=null&&e.skipped_reason?O(e.skipped_reason,"warning"):O(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";O(e,"error")}}function gf({keeper:t}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Qv} keeper=${t} />
          <${tf}
            actor=${Wc()}
            keeper=${t}
            onPokeLodge=${()=>{ff()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Zv}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function $f(){var e,n,s;const t=Yi.value;return t?o`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Lr()}}
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
            <${he} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Lr()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${lf} keeper=${t} />

        ${""}
        <${cf} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${I} title="Field Dictionary">
            <${df} keeper=${t} />
          <//>

          ${""}
          <${I} title="Profile">
            <${Pr} traits=${t.traits??[]} label="Traits" />
            <${Pr} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${X} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${I} title="Autonomy">
                <${nf} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${I} title="TRPG Stats">
                <${uf} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${I} title="Equipment (${t.inventory.length})">
                <${pf} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${I} title="Relationships (${Object.keys(t.relationships).length})">
                <${mf} rels=${t.relationships} />
              <//>
            `:null}

          <${I} title="Runtime Signals">
            <${_f} keeper=${t} />
          <//>

          <${I} title="Neighborhood & Tool Audit">
            <${vf} keeper=${t} />
          <//>

          <${I} title="Memory & Context">
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
        <${gf} keeper=${t} />
      </div>
    </div>
  `:null}function hf({cluster:t,project:e,room:n,generatedAt:s}){return o`
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
        <strong>${s?wt(s):"기록 없음"}</strong>
      </div>
    </div>
  `}function qe({label:t,value:e,detail:n,tone:s}){return o`
    <article class="mission-stat-card ${gt(s)}">
      <span class="mission-stat-label">${t}</span>
      <strong class="mission-stat-value">${e}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function yf(){const t=nc.value,e=gt((t==null?void 0:t.status)??(Te.value?"bad":"warn")),n=!t||t.sections.length===0,s=(t==null?void 0:t.status)==="error"||(t==null?void 0:t.status)==="unavailable"&&!(t!=null&&t.cached);return o`
    <${I} title="판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>휴리스틱 대신 별도 판단 결과</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${e}">
          ${qt((t==null?void 0:t.status)??(Te.value?"error":"loading"))}
        </span>
        ${t!=null&&t.model?o`<span class="command-chip">${t.model}</span>`:null}
        ${t!=null&&t.generated_at?o`<span class="command-chip">${wt(t.generated_at)}</span>`:null}
        ${t!=null&&t.cached?o`<span class="command-chip">캐시</span>`:null}
        ${t!=null&&t.stale?o`<span class="command-chip warn">오래됨</span>`:null}
        ${t!=null&&t.refreshing?o`<span class="command-chip warn">갱신 중</span>`:null}
      </div>

      ${Te.value?o`<div class="empty-state error">${Te.value}</div>`:null}
      ${t!=null&&t.error?o`<div class="empty-state error">${t.error}</div>`:null}
      ${t!=null&&t.summary?o`<div class="mission-inline-note">${t.summary}</div>`:null}
      ${t!=null&&t.last_error&&!t.error?o`<div class="mission-inline-note">최근 갱신 실패: ${t.last_error}</div>`:null}

      ${t&&t.sections.length>0?o`
            <div class="mission-briefing-grid">
              ${t.sections.slice(0,3).map(a=>o`
                <article class="mission-briefing-section ${gt(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${gt(a.status)}">${qt(a.status)}</span>
                      ${Ar(a.signal_class)?o`<span class="command-chip ${a.signal_class==="mixed"?"warn":""}">${Ar(a.signal_class)}</span>`:null}
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
          `:!Ue.value&&!Te.value&&n?o`
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
                      <strong>${Ia(a.scope_type)}${a.scope_id?` · ${a.scope_id}`:""}</strong>
                      <span class="command-chip ${a.severity==="watch"?"warn":""}">${qt(a.severity)}</span>
                    </div>
                    <p>${a.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{va(s)}} disabled=${Ue.value}>
          ${Ue.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{va(!0)}} disabled=${Ue.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function bf({item:t,selected:e,sessionLookup:n}){const s=zv(t),a=t.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),i=t.top_action??null;return o`
    <article class="mission-attention-card ${gt((i==null?void 0:i.severity)??t.severity)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Lv(t.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.summary}</strong>
            <div class="mission-card-target">${Ia(t.target_type)}${t.target_id?` · ${t.target_id}`:""}</div>
          </div>
          <span class="command-chip ${gt((i==null?void 0:i.severity)??t.severity)}">${i?Tv(i):t.severity}</span>
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
            <strong>${t.last_seen_at?wt(t.last_seen_at):"기록 없음"}</strong>
            <small>${Ia(t.target_type)}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${i?to(i.action_type):"판단 필요"}</strong>
            <small>${i?Iv(i):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${i?o`<div class="mission-inline-note">${i.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?o`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>o`
                  <button class="mission-link-row" onClick=${()=>jc(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${qt(l.status)} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:o`<div class="empty-state">직접 연결된 세션이 아직 없습니다.</div>`}

        ${t.related_agent_names.length>0?o`
              <div class="mission-pill-row">
                ${t.related_agent_names.slice(0,8).map(l=>o`
                  <button class="mission-pill action" onClick=${()=>_s(l)}>${l}</button>
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
              <button class="control-btn ghost" onClick=${()=>Wi(i,s,"상황판 주의 신호")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>Nc(i,s,"상황판 주의 신호")}>
                원인 보기
              </button>
            `:o`
              <button class="control-btn ghost" onClick=${()=>Lc(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Pc(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function kf({brief:t,selected:e}){var i,l;const n=t.member_previews.slice(0,4),s=t.top_recommendation??null,a=t.top_attention??null;return o`
    <article class="mission-crew-card ${gt(((i=t.top_attention)==null?void 0:i.severity)??t.health??t.status)} ${e?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>jc(t.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${t.goal}</strong>
            <div class="mission-card-target">${t.session_id}${t.room?` · ${t.room}`:""}</div>
          </div>
          <span class="command-chip ${gt(((l=t.top_attention)==null?void 0:l.severity)??t.health??t.status)}">${qt(t.status)}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${t.member_names.length}</strong>
            <small>${t.member_names.slice(0,3).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${Av(t.elapsed_sec)}</strong>
            <small>${t.started_at?`${wt(t.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 흐름</span>
            <strong>${t.last_event_at?wt(t.last_event_at):"기록 없음"}</strong>
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
        <small>${t.last_event_at?wt(t.last_event_at):"시각 없음"}</small>
      </div>

      ${t.operation_badges.length>0?o`
            <div class="mission-pill-row">
              ${t.operation_badges.slice(0,3).map(c=>o`
                <span class="mission-pill">
                  ${c.operation_id} · ${qt(c.status)}${c.stage?` · ${c.stage}`:""}
                </span>
              `)}
            </div>
          `:null}

      ${n.length>0?o`
            <div class="mission-member-preview-grid">
              ${n.map(c=>o`
                <button class="mission-member-preview" onClick=${()=>_s(c.agent_name)}>
                  <strong>${c.agent_name}</strong>
                  <span>${c.current_work??"현재 작업 없음"}</span>
                  <small>${c.recent_output_preview??c.recent_input_preview??"최근 입출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>ui("intervene",t.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>ui("command",t.session_id)}>세션 원인 보기</button>
        ${s?o`<button class="control-btn ghost" onClick=${()=>Wi(s,a,"상황판 세션 요약")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function xf({detail:t,loading:e,error:n}){if(e&&!t)return o`
      <${I} title="세션 상세" class="mission-list-card">
        <div class="loading-indicator">세션 상세 불러오는 중...</div>
      <//>
    `;if(n&&!t)return o`
      <${I} title="세션 상세" class="mission-list-card">
        <div class="empty-state error">${n}</div>
      <//>
    `;if(!(t!=null&&t.session))return null;const s=t.session;return o`
    <${I} title="세션 상세" class="mission-list-card" semanticId="mission.session_detail">
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
                      <span>${a.timestamp?wt(a.timestamp):"시각 없음"}</span>
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
                  <button class="mission-member-preview" onClick=${()=>_s(a.agent_name)}>
                    <strong>${a.agent_name}</strong>
                    <span>${a.current_work??"현재 작업 없음"}</span>
                    <small>
                      ${a.recent_output_preview??a.recent_input_preview??"최근 입출력 없음"}
                      ${a.last_activity_at?` · ${wt(a.last_activity_at)}`:""}
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
                  <button class="mission-link-row" onClick=${()=>ui("command",s.session_id)}>
                    <strong>${a.operation_id}</strong>
                    <span>${qt(a.status)}${a.stage?` · ${a.stage}`:""}</span>
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
                    <span>${qt(a.status)}${a.generation!=null?` · 세대 ${a.generation}`:""}</span>
                    <small>${a.current_work??"현재 작업 정보 없음"}</small>
                  </div>
                `):o`<div class="empty-state">직접 연결된 키퍼는 없습니다.</div>`}
          </div>
        </div>
      </div>
    <//>
  `}function Sf({row:t}){var s,a,i,l,c,p,_,u,f,v;const e=[`세대 ${t.brief.generation??((s=t.keeper)==null?void 0:s.generation)??0}`,t.brief.context_ratio!=null?`컨텍스트 ${Math.round(t.brief.context_ratio*100)}%`:((a=t.keeper)==null?void 0:a.context_ratio)!=null?`컨텍스트 ${Math.round(t.keeper.context_ratio*100)}%`:null,t.brief.last_turn_ago_s!=null?`최근 턴 ${Math.round(t.brief.last_turn_ago_s)}초 전`:null].filter(h=>h!==null).join(" · "),n=t.recentTools.length>0?t.recentTools.join(", "):Jt(Gi(t.keeper));return o`
    <article class="mission-activity-card ${gt(t.brief.status??((i=t.keeper)==null?void 0:i.status))}">
      <button class="mission-card-select" onClick=${()=>{t.keeper&&Hc(t.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((l=t.keeper)==null?void 0:l.emoji)??""}</span>
            <div>
              <strong>${t.brief.name}</strong>
              ${(c=t.keeper)!=null&&c.koreanName?o`<span>${t.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${gt(t.brief.status??((p=t.keeper)==null?void 0:p.status))}">${qt(t.brief.status??((_=t.keeper)==null?void 0:_.status))}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 하트비트 · ${(u=t.keeper)!=null&&u.last_heartbeat?wt(t.keeper.last_heartbeat):"기록 없음"}</span>
          <span>${e||"연속성 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${t.currentWork}</strong>
          ${(f=t.keeper)!=null&&f.skill_reason?o`<small>판단 요약 · ${Pt(t.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>연속성 상세</summary>
        <div class="mission-activity-foot">
          <span>에이전트 · ${t.brief.agent_name??((v=t.keeper)==null?void 0:v.agent_name)??"기록 없음"}</span>
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
  `}function Cf({item:t}){const e=t.action??null,n=t.attention??null;return o`
    <article class="mission-action-card ${gt(t.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${gt(t.severity)}">
          ${t.signal_type==="action"&&e?to(e.action_type):(n==null?void 0:n.kind)??"내부 신호"}
        </span>
        <span class="mission-card-target">${Ia(t.target_type)}${t.target_id?` · ${t.target_id}`:""}</span>
      </div>
      <p>${t.summary}</p>
      ${e?o`<div class="mission-action-preview">${e.reason}</div>`:null}
      <div class="mission-card-actions">
        ${e?o`
              <button class="control-btn ghost" onClick=${()=>Wi(e,n,"상황판 내부 신호")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Nc(e,n,"상황판 내부 신호")}>이 이슈의 원인 보기</button>
            `:n?o`
                <button class="control-btn ghost" onClick=${()=>Lc(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>Pc(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function Nr(){var h,A,k,S;const t=cs.value;if(ni.value&&!t)return o`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(_a.value&&!t)return o`<div class="empty-state error">${_a.value}</div>`;if(!t)return o`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;Gt.value&&!t.attention_queue.some(b=>b.id===Gt.value)&&(Gt.value=null);const e=t.sessions;ae.value&&!e.some(b=>b.session_id===ae.value)&&(ae.value=null);const n=t.attention_queue.find(b=>b.id===Gt.value)??null,s=(n==null?void 0:n.related_session_ids.find(b=>e.some($=>$.session_id===b)))??null,a=ae.value??s??((h=e[0])==null?void 0:h.session_id)??null,i=Mv(),l=e.find(b=>b.session_id===a)??null,c=t.keeper_briefs.slice(0,6).map(Rv),p=t.attention_queue.filter(b=>b.related_session_ids.length>0).slice(0,6),_=t.internal_signals.slice(0,3),u=e.filter(b=>{var R;const $=((R=b.top_attention)==null?void 0:R.severity)??b.health??b.status;return gt($)!=="ok"||!!b.blocker_summary}).length,f=new Set(e.flatMap(b=>b.member_names)).size,v=e.flatMap(b=>b.member_previews??[]).filter(b=>b.recent_output_preview).length+c.filter(b=>b.recentOutput).length;return ot(()=>{r_(a)},[a]),o`
    <section class="dashboard-panel mission-view">
      <${St} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 어떤 세션이 돌고 있고, 누가 참여하며, 어디가 막혔는지를 한 시점에서 읽는 기본 관찰면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${gt(t.summary.room_health)}">${qt(t.summary.room_health)}</span>
          <span class="command-chip">${t.summary.project??"프로젝트 미지정"}${t.summary.current_room?` · ${t.summary.current_room}`:""}</span>
          <span class="command-chip">${t.generated_at?wt(t.generated_at):"기록 없음"}</span>
        </div>
      </div>

      <${Za} />

      <${hf}
        cluster=${t.summary.cluster}
        project=${t.summary.project}
        room=${t.summary.current_room}
        generatedAt=${t.generated_at}
      />

      <${yf} />

      <div class="mission-stat-grid">
        <${qe} label="활성 세션" value=${e.length} detail="지금 진행중인 협업 단위" tone=${((A=l==null?void 0:l.top_attention)==null?void 0:A.severity)??(l==null?void 0:l.health)??"ok"} />
        <${qe} label="막힌 세션" value=${u} detail="주의가 필요한 흐름" tone=${u>0?"warn":"ok"} />
        <${qe} label="참여자" value=${f} detail="현재 세션에 연결된 주체" tone=${f>0?"ok":"warn"} />
        <${qe} label="키퍼 관찰" value=${c.length} detail="연속성 확인 대상" tone=${((k=c[0])==null?void 0:k.brief.status)??"ok"} />
        <${qe} label="최근 응답" value=${v} detail="메인에서 바로 읽을 수 있는 응답 수" tone=${v>0?"ok":"warn"} />
        <${qe} label="내부 신호" value=${_.length} detail="시스템 진단은 보조 면에만 유지" tone=${((S=_[0])==null?void 0:S.severity)??"ok"} />
      </div>

      ${a?o`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${(l==null?void 0:l.goal)??a}${n?` · ${n.summary}`:""}</span>
              <button class="control-btn ghost" onClick=${Pv}>선택 해제</button>
            </div>
          `:null}

      <${I} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 작전을 먼저 봅니다.</p>
        </div>
        <div class="mission-list-stack">
          ${e.length>0?e.map(b=>o`<${kf} key=${b.session_id} brief=${b} selected=${a===b.session_id} />`):o`<div class="empty-state">지금 활성 세션이 없습니다.</div>`}
        </div>
      <//>

      <${xf}
        detail=${si.value}
        loading=${Xs.value}
        error=${Qs.value}
      />

      <div class="mission-human-grid">
        <${I} title="주의 대기열" class="mission-list-card" semanticId="mission.attention_queue">
          <div class="mission-section-head">
            <h3>어느 세션을 먼저 봐야 하나</h3>
            <p>문제와 경고는 세션에 연결된 것만 먼저 보여주고, 원인 분석은 선택된 세션에서 이어서 봅니다.</p>
          </div>
          <div class="mission-lane-stack">
            ${p.length>0?p.map(b=>o`<${bf} key=${b.id} item=${b} selected=${Gt.value===b.id} sessionLookup=${i} />`):o`<div class="empty-state">지금 세션 단위 주의 대기열은 비어 있습니다.</div>`}
          </div>
        <//>

        <${I} title="내부 신호" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>시스템 진단</h3>
            <p>artifact scope drift 같은 내부 신호는 메인 판단을 방해하지 않도록 접어 둔 보조 면에만 둡니다.</p>
          </div>
          <details class="mission-card-disclosure">
            <summary>내부 신호 ${_.length}</summary>
            <div class="mission-list-stack">
              ${_.length>0?_.map(b=>o`<${Cf} key=${b.id} item=${b} />`):o`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
            </div>
          </details>
        <//>
      </div>

      <${I} title="키퍼 연속성" class="mission-list-card" semanticId="mission.keeper_activity">
        <div class="mission-section-head">
          <h3>연속성 보조 면</h3>
          <p>키퍼는 세션과 별개로 보고, 연속성 판단에 필요한 정보만 먼저 보여줍니다.</p>
        </div>
        <div class="mission-activity-list">
          ${c.length>0?c.map(b=>o`<${Sf} key=${b.brief.name} row=${b} />`):o`<div class="empty-state">지금 보이는 키퍼가 없습니다.</div>`}
        </div>
        <div class="mission-card-actions">
          <button class="control-btn ghost" onClick=${()=>it("execution")}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${()=>it("command")}>지휘 진단면 보기</button>
        </div>
      <//>
    </section>
  `}const Af="modulepreload",Tf=function(t){return"/dashboard/"+t},jr={},If=function(e,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(_){return Promise.all(_.map(u=>Promise.resolve(u).then(f=>({status:"fulfilled",value:f}),f=>({status:"rejected",reason:f}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),p=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(_=>{if(_=Tf(_),_ in jr)return;jr[_]=!0;const u=_.endsWith(".css"),f=u?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${_}"]${f}`))return;const v=document.createElement("link");if(v.rel=u?"stylesheet":Af,u||(v.as="script"),v.crossOrigin="",v.href=_,p&&v.setAttribute("nonce",p),document.head.appendChild(v),u)return new Promise((h,A)=>{v.addEventListener("load",h),v.addEventListener("error",()=>A(new Error(`Unable to preload CSS for ${_}`)))})}))}function i(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&i(c.reason);return e().catch(i)})};function Ma(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function nt(t){if(!t)return"정보 없음";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.max(0,Math.round((Date.now()-e)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function zf(t){if(!t)return"warn";const e=Date.parse(t);return Number.isNaN(e)?"warn":e<=Date.now()?"bad":"ok"}function Gc(t){if(!t)return"정보 없음";const e=Date.parse(t);if(Number.isNaN(e))return t;const n=Math.round((e-Date.now())/1e3);return n<=0?"기한 지남":n<60?`${n}초 후`:n<3600?`${Math.round(n/60)}분 후`:n<86400?`${Math.round(n/3600)}시간 후`:`${Math.round(n/86400)}일 후`}function N(t){return t==="bad"?"bad":t==="warn"||t==="pending"?"warn":"ok"}let Er=!1,Rf=0;function Mf(){return++Rf}let mo=null;async function Lf(){mo||(mo=If(()=>import("./mermaid.core-BaqhT-ae.js").then(e=>e.bE),[]).then(e=>e.default));const t=await mo;return Er||(t.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),Er=!0),t}function de(t){if(!t)return"warn";const e=t.toLowerCase();return e.includes("failed")||e.includes("error")||e.includes("disconnected")||e.includes("stopped")?"bad":e.includes("running")||e.includes("active")||e.includes("degraded")||e.includes("pending")?"warn":"ok"}function vs(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":`${Math.round(t*100)}%`}function In(t){return typeof t!="number"||!Number.isFinite(t)?"정보 없음":t<60?`${Math.round(t)}초`:t<3600?`${Math.round(t/60)}분`:`${Math.round(t/3600)}시간`}function fs(t){return typeof t!="number"||!Number.isFinite(t)?0:Math.max(0,Math.min(100,t))}function xe(t,e){return typeof t!="number"||!Number.isFinite(t)||typeof e!="number"||!Number.isFinite(e)||e<=0?0:fs(t/e*100)}function Pf(t,e){const n=fs(t);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${e};`}function Jc(t){if(!t)return"최근 체인 이력이 없습니다";const e=[t.event];return typeof t.duration_ms=="number"&&e.push(`${t.duration_ms}ms`),typeof t.tokens=="number"&&e.push(`토큰 ${t.tokens}`),t.message&&e.push(t.message),e.join(" · ")}const Nf=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Yc=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"orchestra",label:"오케스트라",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],jf=Yc.map(t=>t.id),Ef=["chain_start","node_start","node_complete","chain_complete","chain_error"],Of={warroom:{title:"실시간 워룸",description:"실제 실행, 워커, 메시지, 트레이스를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 작전, 분견대, 의존 관계를 먼저 읽는 기본 진입 표면입니다."},orchestra:{title:"룸 오케스트라 맵",description:"룸, 세션, 레인, 워커, 키퍼를 한 장의 작전판으로 읽는 시각화 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"레인 이동, 워커 결속, 막힘을 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 작전별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"실제 관리 유닛인지, 실시간 에이전트 기반 자동 투영인지 구분해서 봅니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"작전, 주체, 유닛 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"결정 승인과 유닛 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function Or(t){return!!t&&jf.includes(t)}function Df(){const t=F.value.params;return t.source!=="mission"&&t.source!=="execution"?{}:{source:t.source,...t.action_type?{action_type:t.action_type}:{},...t.target_type?{target_type:t.target_type}:{},...t.target_id?{target_id:t.target_id}:{},...t.focus_kind?{focus_kind:t.focus_kind}:{},...t.operation_id?{operation_id:t.operation_id}:{}}}function Vi(t){const e=Df(),n=Qc(),s=Xi();if(t==="operations")return e;if(t==="chains"){const a=sn.value;return a?{...e,surface:t,operation:a}:{...e,surface:t}}return t==="swarm"||t==="warroom"||t==="orchestra"?{...e,surface:t,...n?{run_id:n}:{},...s?{operation_id:s}:{}}:{...e,surface:t}}function wf(){const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");return n&&e.set("agent",n),s&&e.set("token",s),e.toString()?`/api/v1/chains/events?${e.toString()}`:"/api/v1/chains/events"}function qf(t){switch(t){case"company":return"중대";case"platoon":return"소대";case"squad":return"분대";case"agent":return"에이전트";default:return t}}function ct(t){return oi.value===t}function gs(){return Ei.value}function Ff(t){var a,i,l,c,p,_,u;const e=Ei.value,n=De.value,s=us.value;switch(t){case"warroom":return{tool:"masc_observe_operations",reason:"실시간 실행, 워커, 메시지, 트레이스를 한 화면에서 보고 필요한 세부 표면으로 바로 이동합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=e==null?void 0:e.operations.summary)==null?void 0:a.active)??0}개와 의존 관계를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(i=e==null?void 0:e.swarm_status)==null?void 0:i.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((p=(c=e==null?void 0:e.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:p.reason)??"레인 이동과 막힘 근거를 보고 다음 확인 도구를 고릅니다."};case"orchestra":return{tool:"masc_operator_snapshot",reason:"룸, 세션, 레인, 워커, 키퍼를 한 장에서 훑은 뒤 내려볼 대상을 고릅니다."};case"chains":return{tool:(u=(_=s==null?void 0:s.operations[0])==null?void 0:_.preview_run)!=null&&u.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"이 구조가 실제 관리 단위인지 자동 투영인지 먼저 구분해야 지휘면을 오해하지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 유닛과 작전을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"트레이스 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 제어 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function Kf(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("artifact_scope")||e.includes("routing_confidence")||e.includes("cache_contention")?"microarch":e.includes("leader_offline")||e.includes("roster_offline")?"alerts":e.includes("stale_data")?"swarm":null:null}function Bf(t){var n;const e=((n=t==null?void 0:t.focus_kind)==null?void 0:n.toLowerCase())??"";return e?e.includes("stale_data")||e.includes("leader_offline")||e.includes("roster_offline")||e.includes("managed")?"recommendation":e.includes("gap")?"gaps":null:null}function Vc(){if(typeof window>"u")return null;const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");if(!e)return null;const n=e.trim();return n===""?null:n}function Xc(){if(typeof window>"u")return new URLSearchParams;const t=new URLSearchParams(window.location.search),e=window.location.hash.replace(/^#/,""),n=e.indexOf("?");return n>=0&&new URLSearchParams(e.slice(n+1)).forEach((a,i)=>{t.has(i)||t.set(i,a)}),t}function Qc(){const e=Xc().get("run_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Xi(){const e=Xc().get("operation_id");if(!e)return null;const n=e.trim();return n===""?null:n}function Uf(t){if(!t)return null;const e=Date.parse(t);return Number.isNaN(e)?null:Math.max(0,Math.round((Date.now()-e)/1e3))}function Hf(t){return t.status==="claimed"||t.status==="in_progress"}function Wf(t){const e=ds.value;if(!e)return null;for(const n of e.golden_paths){const s=n.steps.find(a=>a.tool===t);if(s)return s}return null}function _o(t){var e;return((e=ds.value)==null?void 0:e.golden_paths.find(n=>n.id===t))??null}function Gf(t){const e=ds.value;if(!e)return[];const n=new Set(t);return e.pitfalls.filter(s=>n.has(s.id))}async function ue(t){try{await t()}catch{}}function Qi(t){return(t==null?void 0:t.trim().toLowerCase())??""}function Ge(t){const e=Qi(t);return e.includes("failed")||e.includes("error")||e.includes("stopped")||e==="paused"?"bad":e.includes("active")||e.includes("running")||e.includes("healthy")||e.includes("ok")?"ok":"warn"}function Se(t){const e=Qi(t);return e?e==="active"||e==="running"?"진행 중":e==="paused"?"일시정지":e==="done"||e==="ended"||e==="completed"?"완료":e==="failed"||e==="error"||e==="stopped"?"문제":(t==null?void 0:t.trim())||"확인 필요":"확인 필요"}function Jf(){var n,s,a,i,l,c,p,_,u;const t=De.value;if(!t)return!1;const e=t.workers.some(f=>f.joined||f.live_presence||f.completed||f.current_task_matches_run||f.heartbeat_fresh||f.claim_marker_seen||f.done_marker_seen||f.final_marker_seen||!!f.current_task||!!f.bound_task_id||!!f.last_message);return!!((n=t.operation)!=null&&n.operation_id||(s=t.detachment)!=null&&s.detachment_id||(((a=t.summary)==null?void 0:a.joined_workers)??0)>0||(((i=t.summary)==null?void 0:i.live_workers)??0)>0||(((l=t.summary)==null?void 0:l.current_task_bound)??0)>0||(((c=t.summary)==null?void 0:c.fresh_heartbeats)??0)>0||(((p=t.summary)==null?void 0:p.claim_markers_seen)??0)>0||(((_=t.summary)==null?void 0:_.done_markers_seen)??0)>0||(((u=t.summary)==null?void 0:u.final_markers_seen)??0)>0||e||t.recent_messages.length>0||t.recent_trace_events.length>0)}function Yf(t){const e=Qi(t.status);return e==="active"||e==="running"}function Vf(){var i,l,c,p;const t=((i=$t.value)==null?void 0:i.sessions)??[],e=De.value,n=((l=e==null?void 0:e.detachment)==null?void 0:l.session_id)??null;if(n){const _=t.find(u=>u.session_id===n);if(_)return _}const s=((c=e==null?void 0:e.operation)==null?void 0:c.operation_id)??Xi();if(s){const _=t.find(u=>u.command_plane_operation_id===s);if(_)return _}const a=((p=e==null?void 0:e.detachment)==null?void 0:p.detachment_id)??null;if(a){const _=t.find(u=>u.command_plane_detachment_id===a);if(_)return _}return t.find(Yf)??t[0]??null}function vo(t){return t==="proven"?"ok":t==="partial"?"warn":"bad"}function Je(t){return Array.isArray(t)?t:[]}function Nt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)?t:{}}function Is(t){return typeof t=="string"&&t.trim()!==""?t:null}function Xf(t){return typeof t=="number"&&Number.isFinite(t)?t:null}function Qf(t){const e=t.split("/");return e.length<=3?t:`…/${e.slice(-3).join("/")}`}function Zf(t){return t==="proven"?"충분":t==="partial"?"부분":"부족"}function tg(t){return t==="proven"?"협업 증거가 충분합니다":t==="partial"?"흔적은 있으나 협업 증거가 덜 모였습니다":"증거가 부족합니다"}function eg(t,e,n,s,a,i,l){const c=[`${e}명이 실제 흔적을 남겼고, 계획된 참여자는 ${n}명입니다.`,a>0?`서로를 참조한 상호작용 증거가 ${a}건 있습니다.`:"서로를 참조한 명시적 상호작용 증거가 아직 없습니다.",i>0?`도구·산출물·체크포인트 증거가 ${i}건 있습니다.`:"도구·산출물·체크포인트 증거가 거의 없습니다.",l>0?`CPv2 backing trace가 ${l}건 있어 실행 흔적은 남아 있습니다.`:"관리형 backing trace는 아직 없습니다."];return t==="partial"?[c[0]??"",s>0?`partial인 이유: 호출되었지만 응답하지 않은 참여자가 ${s}명 있습니다.`:a===0?"partial인 이유: 여러 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.":"partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.",l>0?"다음 보강 포인트: 응답 턴이나 도구 호출을 남기면 proof가 협업 수준으로 올라갑니다.":"다음 보강 포인트: 관리형 trace 또는 산출물 연결을 더 남기면 근거가 강해집니다."]:t==="proven"?[c[0]??"","결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.","다음 행동: raw evidence는 접어두고 결과 산출물과 다음 실행 결정만 확인하면 됩니다."]:[c[0]??"",s>0?`결론: 협업 시도는 있었지만 무응답 참여자가 ${s}명 있어 협업 증거로 인정하기 어렵습니다.`:"결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.",i>0?"다음 보강 포인트: 응답 턴과 도구 근거를 서로 연결해 남겨야 합니다.":"다음 보강 포인트: 참여자 간 턴, 도구 근거, 산출물 연결을 더 남겨야 합니다."]}function Dr(t){return(t==null?void 0:t.mode)==="requested_not_found"?"bad":(t==null?void 0:t.mode)==="latest_auto_selected"?"warn":"ok"}function ng(t){return(t==null?void 0:t.mode)==="requested_not_found"?"선택 실패":(t==null?void 0:t.mode)==="latest_auto_selected"?"자동 선택":(t==null?void 0:t.mode)==="explicit"?"명시 선택":"선택 없음"}function sg(t){return t.activity_state==="acted"?(t.interaction_count??0)>0||(t.tool_evidence_count??0)>0?"ok":"warn":t.activity_state==="mentioned_only"?"warn":"bad"}function ag(t){return t.activity_state==="acted"?"실제 흔적":t.activity_state==="mentioned_only"?"호출만 됨":"계획만 됨"}function og(t){if(t.activity_state==="acted")return`턴 ${t.turn_count??0} · spawn ${t.spawn_count??0} · 도구 근거 ${t.tool_evidence_count??0}`;if(t.activity_state==="mentioned_only"){const e=t.requested_by?`호출자 ${t.requested_by}`:"호출자 미상";return`호출 ${t.mention_count??0}회 · ${e}`}return"계획된 참여자이지만 아직 이벤트가 없습니다."}function wr(t){return Array.isArray(t.tool_names)?t.tool_names:[]}function ig({selection:t}){return!t||t.mode==="explicit"?null:o`
    <div class="command-guide-card ${Dr(t)}">
      <div class="command-guide-head">
        <strong>${ng(t)}</strong>
        <span class="command-chip ${Dr(t)}">${t.mode??"none"}</span>
      </div>
      <p>${t.reason??"근거 컨텍스트 선택 정보가 없습니다."}</p>
      <div class="command-card-grid">
        <span>선택된 세션</span><span>${t.selected_session_id??"없음"}</span>
        <span>작성자</span><span>${t.selected_created_by??"없음"}</span>
        <span>선택된 목표</span><span>${t.selected_goal??"없음"}</span>
        <span>가용 세션 수</span><span>${t.available_session_count??0}</span>
      </div>
    </div>
  `}function rg({item:t}){return o`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${t.summary??t.event_type??"도구 근거"}</strong>
          <div class="command-meta-line">
            <span>${t.actor??"시스템"}</span>
            <span>${t.event_type??"event"}</span>
          </div>
        </div>
        <span class="command-chip">${nt(t.timestamp??null)}</span>
      </div>
      ${wr(t).length>0?o`<div class="semantic-tag-row">
            ${wr(t).map(e=>o`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
    </article>
  `}function lg(t){const e=new Map;for(const n of t){const s=[n.timestamp??"",n.event_type??"",n.actor??"",n.summary??""].join("|"),a=n.source??"unknown",i=e.get(s);if(i){i.sources.includes(a)||i.sources.push(a),!i.operation_id&&n.operation_id&&(i.operation_id=n.operation_id);continue}e.set(s,{...n,sources:[a]})}return[...e.values()]}function cg(t){return t.sources.length===2?"세션 + 지휘":t.sources.length===1?t.sources[0]==="unknown"?"출처 미상":t.sources[0]??"출처":t.sources.join(" + ")}function dg(t){const e=[];for(const[n,s]of Object.entries(t))if(s!=null){if(typeof s=="string"){if(s.trim()==="")continue;e.push({label:n,value:s});continue}if(typeof s=="number"||typeof s=="boolean"){e.push({label:n,value:String(s)});continue}}return e}function ug(t){const e=Nt(t),n=Nt(e.traces),s=Array.isArray(n.events)?n.events:[],a=Nt(e.detachments),i=Array.isArray(a.detachments)?a.detachments:[],l=Nt(i[0]),c=Nt(l.detachment),p=Nt(l.operation),_=Nt(e.summary),u=Nt(_.operations),f=Nt(u.summary);return[{label:"작전",value:Is(e.operation_id)??"없음"},{label:"분견대",value:Is(e.detachment_id)??"없음"},{label:"트레이스 이벤트",value:`${s.length}`},{label:"분견대 상태",value:Is(c.status)??"없음"},{label:"작전 단계",value:Is(p.stage)??"없음"},{label:"활성 작전",value:`${Xf(f.active)??0}`}]}function pg({item:t}){return o`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${t.summary??t.event_type??"이벤트"}</strong>
          <div class="command-meta-line">
            <span>${cg(t)}</span>
            <span>${t.event_type??"이벤트"}</span>
            <span>${t.actor??"시스템"}</span>
          </div>
        </div>
        <span class="command-chip">${nt(t.timestamp)}</span>
      </div>
      ${t.sources.length>1?o`<div class="semantic-tag-row">
            ${t.sources.map(e=>o`<span class="semantic-tag">${e}</span>`)}
          </div>`:null}
    </article>
  `}function mg({item:t}){const e=t.recent_output_preview??null,n=t.recent_input_preview??null,s=t.recent_event_summary??null,a=t.recent_request_preview??null,i=t.last_active_at??t.recent_request_at??null;return o`
    <article class="mission-activity-row proof-actor-row">
      <div class="mission-activity-head">
        <div>
          <strong>${t.actor}</strong>
          <div class="mission-activity-meta">
            <span>${t.role??"참여자"}</span>
            <span>${i?nt(i):"기록 없음"}</span>
          </div>
        </div>
        <span class="command-chip ${sg(t)}">
          ${ag(t)}
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>${og(t)}</span>
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
      ${Je(t.recent_tool_names).length>0?o`<div class="semantic-tag-row">
            ${Je(t.recent_tool_names).map(l=>o`<span class="semantic-tag">${l}</span>`)}
          </div>`:null}
    </article>
  `}function _g({item:t}){return o`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${t.kind}</strong>
          <div class="command-meta-line">
            <span>${Qf(t.path)}</span>
          </div>
        </div>
        <span class="command-chip ${t.exists?"ok":"warn"}">${t.exists?"존재함":"없음"}</span>
      </div>
    </article>
  `}function qr({title:t,rows:e}){return e.length===0?null:o`
    <div class="proof-kv-block">
      ${t?o`<strong>${t}</strong>`:null}
      <div class="proof-kv-grid">
        ${e.map(n=>o`
          <span>${n.label}</span>
          <strong>${n.value}</strong>
        `)}
      </div>
    </div>
  `}function vg(){var W,Y,st;const t=F.value.params,e=t.session_id??null,n=t.operation_id??null;ot(()=>{dc(e,n)},[e,n]);const s=cc.value;if(ai.value&&!s)return o`<section class="dashboard-panel"><div class="loading-indicator">근거 화면 불러오는 중…</div></section>`;if(He.value&&!s)return o`<section class="dashboard-panel"><div class="error-card">${He.value}</div></section>`;const a=s==null?void 0:s.summary,i=(s==null?void 0:s.selection)??null,l=Je(s==null?void 0:s.actor_contributions),c=Je(s==null?void 0:s.artifacts),p=Je(s==null?void 0:s.tool_evidence),_=(s==null?void 0:s.proof_verdict)??"insufficient",u=(s==null?void 0:s.cp_backing_evidence)??null,f=Array.isArray((W=u==null?void 0:u.traces)==null?void 0:W.events)?((st=(Y=u.traces)==null?void 0:Y.events)==null?void 0:st.length)??0:0,v=(a==null?void 0:a.actors_count)??l.length,h=(a==null?void 0:a.planned_actor_count)??l.length,A=(a==null?void 0:a.unanswered_actor_count)??l.filter(P=>P.activity_state!=="acted"&&(P.mention_count??0)>0).length,k=(a==null?void 0:a.mentioned_actor_count)??l.filter(P=>(P.mention_count??0)>0).length,S=(a==null?void 0:a.interaction_count)??0,b=(a==null?void 0:a.evidence_count)??0,$=lg(Je(s==null?void 0:s.timeline)),R=dg(Nt(s==null?void 0:s.goal_binding)),M=ug(u),L=c.filter(P=>P.exists).length,J=c.length-L,z=eg(_,v,h,A,S,b,f);return o`
    <section class="dashboard-panel mission-view">
      <${St} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>근거</h2>
          <p>이 세션이 실제로 여러 참여자의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${vo(_)}">${Zf(_)}</span>
          ${s!=null&&s.session_id?o`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?o`<span class="command-chip">${nt(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${He.value?o`<div class="error-card">${He.value}</div>`:null}

      <${ig} selection=${i} />

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${vo(_)}">
          <span>판정</span>
          <strong>${tg(_)}</strong>
          <small>${(a==null?void 0:a.detail)??"협업 증거를 verdict로 요약합니다."}</small>
        </div>
        <div class="summary-stat-card">
          <span>실제 흔적</span>
          <strong>${v}</strong>
          <small>이벤트를 남긴 actor 수</small>
        </div>
        <div class="summary-stat-card ${h>v?"warn":"ok"}">
          <span>계획된 참여자</span>
          <strong>${h}</strong>
          <small>${k>0?`${k}명 호출됨`:"호출 기록 없음"}</small>
        </div>
        <div class="summary-stat-card ${A>0?"warn":"ok"}">
          <span>무응답</span>
          <strong>${A}</strong>
          <small>${A>0?"호출됐지만 응답 근거 없음":"무응답 참여자 없음"}</small>
        </div>
        <div class="summary-stat-card ${S>0?"ok":"warn"}">
          <span>직접 상호작용</span>
          <strong>${S}</strong>
          <small>참여자 간 직접 연결 근거</small>
        </div>
        <div class="summary-stat-card ${b>0?"ok":"warn"}">
          <span>근거</span>
          <strong>${b}</strong>
          <small>도구 / 산출물 / 체크포인트</small>
        </div>
        <div class="summary-stat-card ${f>0?"ok":"warn"}">
          <span>CP 트레이스</span>
          <strong>${f}</strong>
          <small>관리형 backing 이벤트</small>
        </div>
        <div class="summary-stat-card ${J===0&&c.length>0?"ok":"warn"}">
          <span>산출물</span>
          <strong>${L}/${c.length}</strong>
          <small>${J>0?`${J}개 누락`:"전부 존재함"}</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${I} title="3줄 근거 요약" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, 왜 아직 부족한지, 다음에 무엇을 남겨야 하는지만 먼저 봅니다.</p>
          </div>
          <div class="proof-summary-stack">
            ${z.map((P,T)=>o`
              <article class="proof-summary-block ${T===1&&_!=="proven"?vo(_):""}">
                <strong>${T===0?"지금 결론":T===1?"왜 이렇게 판정됐나":"다음 보강 포인트"}</strong>
                <span>${P}</span>
              </article>
            `)}
          </div>
        <//>

        <${I} title="목표 연결" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 화면이 어떤 세션과 목표를 기준으로 그려졌는지 먼저 고정합니다.</p>
          </div>
          <${qr} rows=${R} />
          <details class="mission-card-disclosure compact">
            <summary>원본 목표 연결 JSON</summary>
            <pre class="command-json-block">${Ma((s==null?void 0:s.goal_binding)??{})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${I} title="협업 타임라인" class="mission-list-card" semanticId="proof.timeline">
          <div class="mission-section-head">
            <h3>협업 타임라인</h3>
            <p>team-session과 command-plane에서 같은 사건이 보이면 한 줄로 묶어 읽습니다.</p>
          </div>
          <div class="mission-list-stack">
            ${$.length>0?$.slice(0,18).map(P=>o`<${pg} key=${P.id} item=${P} />`):o`<div class="empty-state">표시할 타임라인 근거가 없습니다.</div>`}
          </div>
        <//>

        <${I} title="참여 흔적" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>실제 흔적, 호출만 된 참여자, 계획만 된 참여자를 구분해서 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${l.length>0?l.map(P=>o`<${mg} key=${P.actor} item=${P} />`):o`<div class="empty-state">표시할 참여 흔적이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${I} title="도구 근거" class="mission-list-card" semanticId="proof.tool_evidence">
          <div class="mission-section-head">
            <h3>어떤 도구를 언제 썼는가</h3>
            <p>숫자만 보여주지 말고, 최근 도구 호출 근거를 직접 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${p.length>0?p.map((P,T)=>o`<${rg} key=${`${P.actor??"system"}-${T}`} item=${P} />`):o`<div class="empty-state">기록된 tool evidence가 없습니다.</div>`}
          </div>
        <//>

        <${I} title="실행 근거" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>작전, 분견대, 트레이스 수만 먼저 보고, 원본 CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${qr} rows=${M} />
          <details class="mission-card-disclosure compact">
            <summary>원본 CPv2 backing JSON</summary>
            <pre class="command-json-block">${Ma(u??{})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${I} title="산출물" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>어떤 파일 산출물이 남았나</h3>
            <p>proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${c.length>0?c.map(P=>o`<${_g} key=${P.path} item=${P} />`):o`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function fg(){const t=ps(F.value);return t?o`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${t.source_label}</strong>
        <span class="command-chip">${to(t.action_type)}</span>
        <span class="command-chip">${Hi(t)}</span>
        <span class="command-chip">${Cv(F.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${t.summary}</div>
      ${t.payload_preview?o`<div class="command-focus-preview">${t.payload_preview}</div>`:null}
    </section>
  `:null}function gg(){const t=tt.value,e=Of[t],n=Ff(t);return o`
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
  `}function zs({label:t,value:e,subtext:n,percent:s,color:a}){return o`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${Pf(s,a)}>
        <div class="command-gauge-core">
          <strong>${e}</strong>
          <span>${Math.round(fs(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${t}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function Rs({label:t,value:e,detail:n,percent:s,tone:a}){return o`
    <article class="command-signal-rail ${N(a)}">
      <div class="command-signal-copy">
        <span>${t}</span>
        <strong>${e}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${N(a)}" style=${`width: ${Math.max(8,Math.round(fs(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function $g(){var Y,st,P,T;const t=gs(),e=t==null?void 0:t.topology.summary,n=t==null?void 0:t.operations.summary,s=t==null?void 0:t.detachments.summary,a=t==null?void 0:t.decisions.summary,i=t==null?void 0:t.alerts.summary,l=(Y=t==null?void 0:t.swarm_status)==null?void 0:Y.overview,c=t==null?void 0:t.swarm_proof,p=t==null?void 0:t.operations.microarch,_=(e==null?void 0:e.managed_unit_count)??0,u=(e==null?void 0:e.total_units)??0,f=(n==null?void 0:n.active)??0,v=(s==null?void 0:s.active)??0,h=(l==null?void 0:l.moving_lanes)??0,A=(l==null?void 0:l.active_lanes)??0,k=(c==null?void 0:c.workers.done)??0,S=(c==null?void 0:c.workers.expected)??0,b=(i==null?void 0:i.bad)??0,$=(i==null?void 0:i.warn)??0,R=(a==null?void 0:a.pending)??0,M=(a==null?void 0:a.total)??0,L=f+v,J=((st=p==null?void 0:p.cache)==null?void 0:st.l1_hit_rate)??((T=(P=p==null?void 0:p.signals)==null?void 0:P.cache_contention)==null?void 0:T.l1_hit_rate)??0,z=f>0||v>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",W=f>0||h>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return o`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${z}</h3>
        <p>${W}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${N(f>0?"ok":"warn")}">활성 작전 ${f}</span>
          <span class="command-chip ${N(h>0?"ok":(A>0,"warn"))}">이동 레인 ${h}/${Math.max(A,h)}</span>
          <span class="command-chip ${N(b>0?"bad":$>0?"warn":"ok")}">치명 알림 ${b}</span>
          <span class="command-chip ${N(R>0?"warn":"ok")}">승인 대기 ${R}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${zs}
          label="관리 단위 범위"
          value=${`${_}/${Math.max(u,_)}`}
          subtext=${u>0?`${u-_}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${xe(_,Math.max(u,_))}
          color="#67e8f9"
        />
        <${zs}
          label="실행 열도"
          value=${String(L)}
          subtext=${`${f}개 작전 + ${v}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${xe(L,Math.max(_,L||1))}
          color="#4ade80"
        />
        <${zs}
          label="스웜 이동감"
          value=${`${h}/${Math.max(A,h)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${nt(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${xe(h,Math.max(A,h||1))}
          color="#fbbf24"
        />
        <${zs}
          label="증거 수집률"
          value=${`${k}/${Math.max(S,k)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${xe(k,Math.max(S,k||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${Rs}
        label="승인 대기열"
        value=${`${R}건 대기`}
        detail=${`현재 정책 창에서 ${M}개 결정을 추적 중입니다`}
        percent=${xe(R,Math.max(M,R||1))}
        tone=${R>0?"warn":"ok"}
      />
      <${Rs}
        label="알림 압력"
        value=${`치명 ${b} / 주의 ${$}`}
        detail=${b>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${xe(b*2+$,Math.max((b+$)*2,1))}
        tone=${b>0?"bad":$>0?"warn":"ok"}
      />
      <${Rs}
        label="디스패치 점유"
          value=${`${v}개 가동`}
        detail=${_>0?`${_}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${xe(v,Math.max(_,v||1))}
        tone=${v>0?"ok":"warn"}
      />
      <${Rs}
        label="캐시 신뢰도"
        value=${J?vs(J):"정보 없음"}
        detail=${J?"microarch 캐시 텔레메트리에서 집계한 L1 적중률":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${fs((J??0)*100)}
        tone=${J>=.75?"ok":J>=.4?"warn":"bad"}
      />
    </div>
  `}function hg(){var v,h,A,k,S;const t=gs(),e=us.value,n=ps(F.value),s=Kf(n),a=t==null?void 0:t.topology.summary,i=t==null?void 0:t.operations.summary,l=(v=t==null?void 0:t.swarm_status)==null?void 0:v.overview,c=t==null?void 0:t.operations.microarch,p=t==null?void 0:t.decisions.summary,_=t==null?void 0:t.alerts.summary,u=(h=c==null?void 0:c.signals)==null?void 0:h.issue_pressure,f=c==null?void 0:c.cache;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(i==null?void 0:i.active)??0}</strong><small>${((A=t==null?void 0:t.detachments.summary)==null?void 0:A.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(p==null?void 0:p.pending)??0}</strong><small>${(p==null?void 0:p.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(_==null?void 0:_.bad)??0}</strong><small>${(_==null?void 0:_.warn)??0}건 주의</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((k=e==null?void 0:e.summary)==null?void 0:k.active_chains)??0}</strong><small>${((S=e==null?void 0:e.summary)==null?void 0:S.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${nt(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(f==null?void 0:f.l1_hit_rate)!=null?`${vs(f.l1_hit_rate)} L1 적중`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"정보 없음"}</small></div>
    </div>
  `}function yg(){var Y,st,P,T,C,D,j,Q,Ut;const t=gs(),e=Bt.value,n=lt.value,s=Vc(),a=s?Qt.value.find(H=>H.name===s)??null:null,i=s?oe.value.filter(H=>H.assignee===s&&Hf(H)):[],l=((Y=t==null?void 0:t.operations.summary)==null?void 0:Y.active)??0,c=((st=t==null?void 0:t.detachments.summary)==null?void 0:st.total)??0,p=((P=t==null?void 0:t.decisions.summary)==null?void 0:P.pending)??0,_=e==null?void 0:e.detachments.detachments.find(H=>{const Lt=H.detachment.heartbeat_deadline,ye=Lt?Date.parse(Lt):Number.NaN;return H.detachment.status==="stalled"||!Number.isNaN(ye)&&ye<=Date.now()}),u=e==null?void 0:e.alerts.alerts.find(H=>H.severity==="bad"),f=!!(n!=null&&n.room||n!=null&&n.project),v=(a==null?void 0:a.current_task)??null,h=Uf(a==null?void 0:a.last_seen),A=h!=null?h<=120:null,k=[f?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?i.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:oe.value.length>0?"masc_claim":"masc_add_task"}:v?A===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${v} 이지만 heartbeat가 stale 합니다 (${h}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${v}${h!=null?` · 마지막 활동 ${h}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!t||(((T=t.topology.summary)==null?void 0:T.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((C=t.topology.summary)==null?void 0:C.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((D=t.topology.summary)==null?void 0:D.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},p>0?{title:"디스패치 준비도",tone:"warn",detail:`${p}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:_||u?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${_?` · detachment ${_.detachment.detachment_id} 가 stalled 상태입니다`:""}${u?` · alert ${u.title??u.alert_id}`:""}${!e&&!_&&!u?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${e?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],S=f?!s||!a?"masc_join":i.length===0?oe.value.length>0?"masc_claim":"masc_add_task":v?A===!1?"masc_heartbeat":!t||(((j=t.topology.summary)==null?void 0:j.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":p>0?"masc_policy_approve":l>0&&c===0||_||u?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",b=Wf(S),R=Gf(S==="masc_set_room"?["repo-root-room"]:S==="masc_plan_set_task"?["claimed-not-current"]:S==="masc_heartbeat"?["heartbeat-stale"]:S==="masc_dispatch_tick"?["no-detachments"]:S==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),M=_o("room_task_hygiene"),L=_o("cpv2_benchmark"),J=_o("supervisor_session"),z=((Q=ds.value)==null?void 0:Q.docs)??[],W=[M,L,J].filter(H=>H!==null);return o`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${K} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(b==null?void 0:b.title)??S}</strong>
            <span class="command-chip ok">${S}</span>
          </div>
          <p>${(b==null?void 0:b.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(Ut=b==null?void 0:b.success_signals)!=null&&Ut.length?o`<div class="command-tag-row">
                ${b.success_signals.map(H=>o`<span class="command-tag ok">${H}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${k.map(H=>o`
            <article class="command-readiness-row ${N(H.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${H.title}</strong>
                  <span class="command-chip ${N(H.tone)}">${H.tone}</span>
                </div>
                <p>${H.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${H.tool}</div>
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
                  ${R.map(H=>o`
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
          <${K} panelId="command.summary" compact=${!0} />
        </div>
        ${ii.value?o`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:ba.value?o`<div class="empty-state error">${ba.value}</div>`:o`
                <div class="command-path-grid">
                  ${W.map(H=>o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${H.title}</strong>
                        <span class="command-chip">${H.id}</span>
                      </div>
                      <p>${H.summary}</p>
                      <div class="command-card-sub">${H.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${H.steps.slice(0,4).map(Lt=>o`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Lt.tool}</span>
                            <span>${Lt.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${z.length>0?o`<div class="command-doc-links">
                      ${z.map(H=>o`<span class="command-tag">${H.title}: ${H.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function bg(){return o`
    <${$g} />
    <${hg} />
    <${yg} />
  `}function kg(){return ga.value?o`<div class="empty-state">command-plane detail 불러오는 중…</div>`:ha.value?o`<div class="empty-state error">${ha.value}</div>`:o`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}const Ce=g(null),Ms=g("compact"),te=g({zoom:1,panX:0,panY:0}),fo=g(!1),Ls=g(!1),zn={width:1280,height:760},Zc=.42,td=1.9;function ta(t,e,n){return Math.max(e,Math.min(n,t))}function Zi(t,e){const n=t==null?void 0:t.trim();return n?n.length<=e?n:`${n.slice(0,Math.max(1,e-1))}…`:null}function xg(t){return t==="compact"?"집약":"균형"}function Fr(t){switch((t??"").trim().toLowerCase()){case"room":return"룸";case"session":return"세션";case"operation":return"작전";case"detachment":return"분견대";case"lane":return"레인";case"worker":return"워커";case"keeper":return"키퍼";default:return(t==null?void 0:t.trim())||"노드"}}function Ps(t,e,n){if(t<=0)return[];if(t===1)return[Math.round((e+n)/2)];const s=(n-e)/(t-1);return Array.from({length:t},(a,i)=>Math.round(e+i*s))}function Sg(t,e){const n=new Map;for(const s of t){const a=e(s),i=n.get(a)??[];i.push(s),n.set(a,i)}return n}function ed(t){return t==="compact"?{room:{x:660,y:108},sessions:{y:228,min:220,max:1110},operations:{y:338,min:260,max:1050},detachments:{y:430,min:310,max:1e3},lanes:{y:540,min:220,max:1110},worker:{perRow:5,xSpacing:60,ySpacing:52,laneOffsetY:76,freeBaseY:662},keeper:{startX:1180,colSpacing:92,rowSpacing:90,startY:176,columns:2},signalRadius:116}:{room:{x:700,y:112},sessions:{y:236,min:240,max:1140},operations:{y:356,min:300,max:1080},detachments:{y:454,min:340,max:1030},lanes:{y:584,min:230,max:1110},worker:{perRow:4,xSpacing:72,ySpacing:60,laneOffsetY:82,freeBaseY:720},keeper:{startX:1210,colSpacing:108,rowSpacing:102,startY:188,columns:2},signalRadius:132}}function nd(t,e){return t.kind==="room"?e==="compact"?{width:138,height:138,radius:68}:{width:156,height:156,radius:76}:t.kind==="worker"?e==="compact"?{width:70,height:36,radius:18}:{width:84,height:44,radius:22}:t.kind==="lane"?e==="compact"?{width:156,height:48,radius:15}:{width:176,height:56,radius:17}:t.kind==="keeper"?e==="compact"?{width:118,height:50,radius:22}:{width:132,height:60,radius:24}:t.kind==="session"?e==="compact"?{width:182,height:58,radius:17}:{width:202,height:68,radius:18}:e==="compact"?{width:176,height:58,radius:16}:{width:196,height:68,radius:18}}function Cg(t,e){const n=t.kind==="worker"?e==="compact"?10:14:t.kind==="keeper"?e==="compact"?12:16:t.kind==="lane"?e==="compact"?16:22:e==="compact"?18:26;return Zi(t.label,n)??t.label}function Ag(t,e){if(e==="compact"&&(t.kind==="worker"||t.kind==="keeper"||t.kind==="detachment"))return null;const n=t.kind==="session"?e==="compact"?20:28:e==="compact"?14:24;return Zi(t.subtitle,n)}function Tg(t,e){return e==="compact"&&t.kind!=="session"&&t.kind!=="operation"?null:Zi(t.status,e==="compact"?10:14)}function Ig(t,e){const n=ed(e),s=new Map,a=t.nodes,i=a.find(k=>k.kind==="room")??null,l=a.filter(k=>k.kind==="session"),c=a.filter(k=>k.kind==="operation"),p=a.filter(k=>k.kind==="detachment"),_=a.filter(k=>k.kind==="lane"),u=a.filter(k=>k.kind==="worker"),f=a.filter(k=>k.kind==="keeper");i&&s.set(i.id,{x:n.room.x,y:n.room.y}),Ps(l.length,n.sessions.min,n.sessions.max).forEach((k,S)=>{const b=l[S];b&&s.set(b.id,{x:k,y:n.sessions.y})}),Ps(c.length,n.operations.min,n.operations.max).forEach((k,S)=>{const b=c[S];b&&s.set(b.id,{x:k,y:n.operations.y})}),Ps(p.length,n.detachments.min,n.detachments.max).forEach((k,S)=>{const b=p[S];b&&s.set(b.id,{x:k,y:n.detachments.y})}),Ps(_.length,n.lanes.min,n.lanes.max).forEach((k,S)=>{const b=_[S];b&&s.set(b.id,{x:k,y:n.lanes.y})});const v=new Map(_.map(k=>{const S=s.get(k.id);return S?[k.id,S.x]:null}).filter(k=>k!==null)),h=Sg(u,k=>k.lane_id?`lane:${k.lane_id}`:k.parent_id?k.parent_id:"free");let A=0;for(const[k,S]of h){let b=v.get(k.replace(/^lane:/,""));if(b==null){const R=s.get(k);b=R==null?void 0:R.x}b==null&&(b=260+A%4*180,A+=1);const $=Math.max(1,Math.ceil(S.length/n.worker.perRow));for(let R=0;R<$;R+=1){const M=S.slice(R*n.worker.perRow,(R+1)*n.worker.perRow),L=(M.length-1)*n.worker.xSpacing,J=b-L/2;M.forEach((z,W)=>{var Y;s.set(z.id,{x:Math.round(J+W*n.worker.xSpacing),y:k==="free"?n.worker.freeBaseY+R*n.worker.ySpacing:(((Y=s.get(k.replace(/^lane:/,"")))==null?void 0:Y.y)??n.lanes.y)+n.worker.laneOffsetY+R*n.worker.ySpacing})})}}return f.forEach((k,S)=>{const b=S%n.keeper.columns,$=Math.floor(S/n.keeper.columns);s.set(k.id,{x:n.keeper.startX+b*n.keeper.colSpacing,y:n.keeper.startY+$*n.keeper.rowSpacing})}),s}function zg(t,e,n){if(!e||t.signals.length===0)return[];const s=ed(n);return t.signals.slice(0,6).map((a,i)=>{const l=(-130+i*36)*(Math.PI/180);return{signalNode:a,x:Math.round(e.x+Math.cos(l)*s.signalRadius),y:Math.round(e.y+Math.sin(l)*s.signalRadius)}})}function Rg(t,e,n,s){let a=Number.POSITIVE_INFINITY,i=Number.NEGATIVE_INFINITY,l=Number.POSITIVE_INFINITY,c=Number.NEGATIVE_INFINITY;for(const p of t.nodes){const _=e.get(p.id);if(!_)continue;const u=nd(p,s);p.kind==="room"?(a=Math.min(a,_.x-u.radius),i=Math.max(i,_.x+u.radius),l=Math.min(l,_.y-u.radius),c=Math.max(c,_.y+u.radius)):(a=Math.min(a,_.x-u.width/2),i=Math.max(i,_.x+u.width/2),l=Math.min(l,_.y-u.height/2),c=Math.max(c,_.y+u.height/2))}for(const p of n)a=Math.min(a,p.x-20),i=Math.max(i,p.x+20),l=Math.min(l,p.y-20),c=Math.max(c,p.y+20);return!Number.isFinite(a)||!Number.isFinite(i)||!Number.isFinite(l)||!Number.isFinite(c)?{minX:0,minY:0,maxX:zn.width,maxY:zn.height,width:zn.width,height:zn.height}:{minX:a,minY:l,maxX:i,maxY:c,width:Math.max(1,i-a),height:Math.max(1,c-l)}}function Kr(t,e,n){const s=n==="compact"?48:72,a=Math.max(360,e.width-s*2),i=Math.max(280,e.height-s*2),l=ta(Math.min(a/Math.max(t.width,1),i/Math.max(t.height,1)),Zc,td),c=t.minX+t.width/2,p=t.minY+t.height/2;return{zoom:l,panX:e.width/2-c*l,panY:e.height/2-p*l}}function Mg(t,e){const n=(t.x+e.x)/2,s=e.y>=t.y?32:-32;return`M ${t.x} ${t.y} C ${n} ${t.y+s}, ${n} ${e.y-s}, ${e.x} ${e.y}`}function Br(t,e,n){if(t==="command"){if(e){ce(e),it("command",{...Vi(e),...n});return}it("command",n);return}if(t==="intervene"){it("intervene",n);return}it("command",n)}function Lg({signalNodes:t,roomPoint:e,onSelect:n}){return!e||t.length===0?null:o`
    ${t.map(({signalNode:s,x:a,y:i})=>o`
      <g
        key=${s.id}
        data-orchestra-signal="true"
        class=${`orchestra-signal-node ${N(s.tone)}`}
        onClick=${()=>n(s.id)}
      >
        <title>${s.label}${s.detail?` — ${s.detail}`:""}</title>
        <line x1=${e.x} y1=${e.y} x2=${a} y2=${i} class="orchestra-signal-link" />
        <circle cx=${a} cy=${i} r="16" class="orchestra-signal-dot" />
        <text x=${a} y=${i+4} text-anchor="middle" class="orchestra-signal-glyph">!</text>
      </g>
    `)}
  `}function Pg({edges:t,positions:e,selectedId:n}){return o`
    ${t.map(s=>{const a=e.get(s.source),i=e.get(s.target);if(!a||!i)return null;const l=n!=null&&(s.source===n||s.target===n);return o`
        <path
          key=${s.id}
          d=${Mg(a,i)}
          class=${`orchestra-edge ${N(s.tone)} ${s.animated?"animated":""} ${l?"active":""}`}
        />
      `})}
  `}function Ng({orchestra:t,positions:e,density:n,selectedId:s,onSelect:a}){var l;const i=((l=t.focus)==null?void 0:l.target_kind)==="node"?t.focus.target_id:null;return o`
    ${t.nodes.map(c=>{const p=e.get(c.id);if(!p)return null;const _=nd(c,n),u=c.id===s,f=c.id===i,v=c.visual_class??c.kind,h=Cg(c,n),A=Ag(c,n),k=Tg(c,n);if(c.kind==="room")return o`
          <g
            key=${c.id}
            data-orchestra-node="true"
            class=${`orchestra-node room ${N(c.tone)} ${u?"selected":""} ${f?"focused":""}`}
            onClick=${()=>a(c.id)}
          >
            <title>${c.label}</title>
            <circle cx=${p.x} cy=${p.y} r=${_.radius} class="orchestra-room-ring outer" />
            <circle cx=${p.x} cy=${p.y} r=${_.radius-16} class="orchestra-room-ring inner" />
            <text x=${p.x} y=${p.y-10} text-anchor="middle" class="orchestra-room-glyph">${c.glyph??"◎"}</text>
            <text x=${p.x} y=${p.y+22} text-anchor="middle" class="orchestra-room-label">${h}</text>
          </g>
        `;const S=p.x-_.width/2,b=p.y-_.height/2;return o`
        <g
          key=${c.id}
          data-orchestra-node="true"
          class=${`orchestra-node ${v} ${N(c.tone)} ${u?"selected":""} ${f?"focused":""}`}
          onClick=${()=>a(c.id)}
        >
          <title>${c.label}${c.subtitle?` — ${c.subtitle}`:""}${c.status?` (${c.status})`:""}</title>
          <rect x=${S} y=${b} width=${_.width} height=${_.height} rx=${_.radius} class="orchestra-node-body" />
          <text x=${S+16} y=${b+24} class="orchestra-node-glyph">${c.glyph??"•"}</text>
          <text x=${S+38} y=${b+24} class="orchestra-node-label">${h}</text>
          ${A?o`<text x=${S+38} y=${b+42} class="orchestra-node-subtitle">${A}</text>`:null}
          ${k?o`<text x=${S+_.width-10} y=${b+18} text-anchor="end" class="orchestra-node-status">${k}</text>`:null}
        </g>
      `})}
  `}function sd(t){var s,a;const e=Ce.value;if(e){const i=t.nodes.find(c=>c.id===e);if(i)return{type:"node",value:i};const l=t.signals.find(c=>c.id===e);if(l)return{type:"signal",value:l}}if(((s=t.focus)==null?void 0:s.target_kind)==="node"){const i=t.nodes.find(l=>{var c;return l.id===((c=t.focus)==null?void 0:c.target_id)});if(i)return{type:"node",value:i}}if(((a=t.focus)==null?void 0:a.target_kind)==="signal"){const i=t.signals.find(l=>{var c;return l.id===((c=t.focus)==null?void 0:c.target_id)});if(i)return{type:"signal",value:i}}const n=t.nodes[0];return n?{type:"node",value:n}:null}function jg({orchestra:t}){const e=sd(t);if(!e)return o`<aside class="orchestra-drawer card"><div class="empty-state">선택 가능한 대상이 아직 없습니다.</div></aside>`;if(e.type==="signal"){const i=e.value;return o`
      <aside class="orchestra-drawer card ${N(i.tone)}">
        <div class="card-title-row">
          <div class="card-title">${i.label}</div>
          <span class="command-chip ${N(i.tone)}">${Fr(i.kind)}</span>
        </div>
        <p>${i.detail??"세부 설명이 없습니다."}</p>
        ${i.suggested_surface?o`
              <div class="command-action-row">
                <button
                  class="control-btn"
                  onClick=${()=>Br("command",i.suggested_surface,i.suggested_params??{})}
                >
                  추천 화면 열기
                </button>
              </div>
            `:null}
      </aside>
    `}const n=e.value,s=t.signals.filter(i=>i.source_id===n.id||i.target_id===n.id),a=t.edges.filter(i=>i.source===n.id||i.target===n.id);return o`
    <aside class="orchestra-drawer card ${N(n.tone)}">
      <div class="card-title-row">
        <div class="card-title">${n.label}</div>
        <span class="command-chip ${N(n.tone)}">${Fr(n.kind)}</span>
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
          ${s.map(i=>o`<span class="command-chip ${N(i.tone)}">${i.label}</span>`)}
        </div>
      `:null}
      <div class="command-card-sub">연결 ${a.length}개 · 근거 ${n.provenance}</div>
      ${n.link_tab&&(n.link_surface||Object.keys(n.link_params??{}).length>0)?o`
            <div class="command-action-row">
              <button
                class="control-btn"
                onClick=${()=>Br(n.link_tab??"command",n.link_surface,n.link_params??{})}
              >
                이 화면 열기
              </button>
            </div>
          `:null}
    </aside>
  `}function Eg(){var W,Y,st,P;const t=Oi.value,e=Hs(null),n=Hs(null),s=Hs(""),[a,i]=xi(zn);if(ot(()=>{const T=e.current;if(!T)return;const C=()=>{const j=T.getBoundingClientRect();j.width<=0||j.height<=0||i({width:Math.max(640,Math.round(j.width)),height:Math.max(480,Math.round(j.height))})};if(C(),typeof ResizeObserver>"u")return window.addEventListener("resize",C),()=>window.removeEventListener("resize",C);const D=new ResizeObserver(()=>C());return D.observe(T),()=>D.disconnect()},[]),ri.value&&!t)return o`<section class="card command-section"><div class="empty-state">오케스트라 맵 불러오는 중…</div></section>`;if(Sa.value)return o`<section class="card command-section"><div class="empty-state error">${Sa.value}</div></section>`;if(!t)return o`<section class="card command-section"><div class="empty-state">오케스트라 맵 데이터가 아직 없습니다.</div></section>`;const l=Ms.value,c=Ig(t,l),p=t.nodes.find(T=>T.kind==="room")??null,_=p?c.get(p.id)??null:null,u=zg(t,_,l),f=Rg(t,c,u,l),v=sd(t),h=(v==null?void 0:v.value.id)??null,A=`${l}:${a.width}x${a.height}:${t.nodes.length}:${t.edges.length}:${t.signals.length}`,k=(T,C)=>{te.value=T,Ls.value=C},S=()=>{k(Kr(f,a,l),!1)},b=()=>{if(Ce.value=null,l!=="compact"){Ms.value="compact",Ls.value=!1;return}S()};ot(()=>{h&&!t.nodes.some(T=>T.id===h)&&!t.signals.some(T=>T.id===h)&&(Ce.value=null)},[A,h,t]),ot(()=>{(!Ls.value||s.current!==A)&&(k(Kr(f,a,l),!1),s.current=A)},[A]);const $=te.value,R=(T,C,D)=>{const j=te.value.zoom,Q=ta(j*D,Zc,td);if(Math.abs(Q-j)<.001)return;const Ut=(T-te.value.panX)/j,H=(C-te.value.panY)/j;k({zoom:Q,panX:T-Ut*Q,panY:C-H*Q},!0)},M=T=>{T.preventDefault();const C=e.current;if(!C)return;const D=C.getBoundingClientRect(),j=ta(T.clientX-D.left,0,D.width),Q=ta(T.clientY-D.top,0,D.height);R(j,Q,T.deltaY<0?1.1:.92)},L=T=>{var j;const C=T.target;if(!(C instanceof Element)||!C.closest('[data-orchestra-background="true"]'))return;const D=T.currentTarget;D&&(n.current={pointerId:T.pointerId,startX:T.clientX,startY:T.clientY,panX:te.value.panX,panY:te.value.panY},fo.value=!0,Ls.value=!0,(j=D.setPointerCapture)==null||j.call(D,T.pointerId))},J=T=>{const C=n.current;!C||C.pointerId!==T.pointerId||k({zoom:te.value.zoom,panX:C.panX+(T.clientX-C.startX),panY:C.panY+(T.clientY-C.startY)},!0)},z=T=>{var D;if(!n.current)return;const C=T==null?void 0:T.currentTarget;C&&T&&((D=C.releasePointerCapture)==null||D.call(C,T.pointerId)),n.current=null,fo.value=!1};return o`
    <section class="card command-section orchestra-surface">
      <div class="card-title-row">
        <div class="card-title">오케스트라 맵</div>
        <${K} panelId="command.orchestra" compact=${!0} />
      </div>
      <p class="command-card-sub">
        룸 전체를 한 장의 작전판으로 읽는 시각화입니다. 확대/이동으로 밀집 구간을 읽고, 노드를 눌러 상세 신호와 연결 대상을 확인합니다.
      </p>

      <div class="orchestra-toolbar">
        <div class="orchestra-toolbar-group">
          <button class="control-btn ghost" onClick=${S}>맞춤 보기</button>
          <button class="control-btn ghost" onClick=${b}>초기화</button>
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
            onClick=${()=>{Ms.value="balanced",Ce.value=h}}
          >
            균형
          </button>
          <button
            class=${`control-btn ${l==="compact"?"is-active":"ghost"}`}
            onClick=${()=>{Ms.value="compact",Ce.value=h}}
          >
            집약
          </button>
          <span class="command-chip">${xg(l)}</span>
        </div>
      </div>

      <div class="orchestra-shell">
        <div
          ref=${e}
          class="orchestra-canvas-wrap"
          onWheel=${M}
          onPointerDown=${L}
          onPointerMove=${J}
          onPointerUp=${z}
          onPointerCancel=${z}
          onPointerLeave=${()=>z()}
        >
          <svg
            class=${`orchestra-canvas ${fo.value?"is-dragging":""}`}
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
              <${Pg} edges=${t.edges} positions=${c} selectedId=${h} />
              <${Lg} signalNodes=${u} roomPoint=${_} onSelect=${T=>{Ce.value=T}} />
              <${Ng}
                orchestra=${t}
                positions=${c}
                density=${l}
                selectedId=${h}
                onSelect=${T=>{Ce.value=T}}
              />
            </g>
          </svg>
          <div class="orchestra-summary-strip">
            <span class="command-chip">세션 ${((W=t.summary)==null?void 0:W.session_count)??0}</span>
            <span class="command-chip">워커 ${((Y=t.summary)==null?void 0:Y.worker_count)??0}</span>
            <span class="command-chip">키퍼 ${((st=t.summary)==null?void 0:st.keeper_count)??0}</span>
            <span class="command-chip ${N(t.signals.some(T=>T.tone==="bad")?"bad":t.signals.length>0?"warn":"ok")}">
              신호 ${((P=t.summary)==null?void 0:P.signal_count)??t.signals.length}
            </span>
            <span class="command-chip">갱신 ${nt(t.generated_at)}</span>
          </div>
        </div>

        <${jg} orchestra=${t} />
      </div>
    </section>
  `}const ad="masc_dashboard_agent_name";function Og(){var e,n,s;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(ad))==null?void 0:s.trim())||"dashboard"}const no=g(Og()),rn=g(""),La=g("운영 점검"),ln=g(""),Vn=g(""),Xn=g("2"),mn=g(""),kt=g("note"),Qn=g(""),Zn=g(""),ts=g(""),es=g("2"),ns=g(""),Pa=g("운영자 중지 요청"),Na=g(""),cn=g(""),Ns=g(null);function Dg(t){const e=t.trim()||"dashboard";no.value=e,localStorage.setItem(ad,e)}function ja(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function tr(t){switch((t??"").trim().toLowerCase()){case"judgment":return"상주 판단";case"fallback":return"보조 읽기 모델";default:return(t==null?void 0:t.trim())||"안내"}}function Ea(t){switch((t??"").trim().toLowerCase()){case"judgment":return"ok";case"fallback":return"warn";default:return"warn"}}function er(t){return t!=null&&t.enabled?t.refreshing?"갱신 중":t.judge_online?"온라인":t.last_error?"오류":"대기":"꺼짐"}function wg(t){return t!=null&&t.enabled?t.judge_online?"ok":t.refreshing?"warn":"bad":"warn"}function nr(t){return t!=null&&t.fresh_until?t.fresh_until:"갱신 기준 없음"}function Ur(t){return typeof t!="number"||!Number.isFinite(t)?"확인 없음":t<60?`${Math.round(t)}초 전`:t<3600?`${Math.round(t/60)}분 전`:`${Math.round(t/3600)}시간 전`}function _n(t){return typeof t=="string"?t.trim().toLowerCase():""}function qg(t){var s;const e=_n(t.status);if(e==="paused")return"bad";if(e===""||e==="unknown")return"warn";const n=_n((s=t.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function go(t){const e=_n(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":e===""||e==="unknown"||(t.context_ratio??0)>=.8||t.context_ratio==null||t.last_turn_ago_s==null||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}function Hr(t){return t.some(e=>_n(e.severity)==="bad")?"bad":t.length>0?"warn":"ok"}function Fg(t){return t.target_type==="team_session"}function Kg(t){return t.target_type==="keeper"}function je(t){switch(t){case"broadcast":return"방송";case"room_pause":return"방 일시정지";case"room_resume":return"방 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"team_worker_spawn_batch":return"세션 작업자 교체";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"키퍼 메시지";case"keeper_msg":return"키퍼 메시지";case"swarm_run_continue":return"스웜 실행 계속";case"swarm_run_rerun":return"스웜 실행 재실행";case"swarm_run_abandon":return"스웜 실행 포기";default:return(t==null?void 0:t.trim())||"액션"}}function dn(t){switch(t){case"room":return"방";case"team_session":return"세션";case"keeper":return"키퍼";case"swarm_run":return"스웜 실행";default:return(t==null?void 0:t.trim())||"대상"}}function Ye(t){switch(_n(t)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function Oa(t){return t?"확인 후 실행":"즉시 실행"}function Bg(t){switch(t){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"worker_spawn_batch":return"작업자 교체";default:return t}}function vt(t,e){if(!t)return null;const n=t[e];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function Ug(t){return!t||typeof t!="object"||Array.isArray(t)?null:t}function Hg(t){if(!t)return"";const e=t.spawn_batch;return ja(e!==void 0?e:t)}function od(t){const e=Ug(t.payload);if(t.target_type==="room"){if(t.action_type==="broadcast"){rn.value=vt(e,"message")??t.summary;return}if(t.action_type==="task_inject"){ln.value=vt(e,"title")??"운영자 주입 작업",Vn.value=vt(e,"description")??t.summary,Xn.value=vt(e,"priority")??Xn.value;return}t.action_type==="room_pause"&&(La.value=vt(e,"reason")??t.summary);return}if(t.target_type==="team_session"){if(t.target_id&&(mn.value=t.target_id),t.action_type==="team_stop"){Pa.value=vt(e,"reason")??t.summary;return}kt.value=t.action_type==="team_worker_spawn_batch"?"worker_spawn_batch":t.action_type==="team_task_inject"?"task":t.action_type==="team_broadcast"?"broadcast":"note";const n=vt(e,"message");if(n&&(Qn.value=n),kt.value==="worker_spawn_batch"){ns.value=Hg(e);return}kt.value==="task"&&(Zn.value=vt(e,"task_title")??vt(e,"title")??"운영자 주입 작업",ts.value=vt(e,"task_description")??vt(e,"description")??t.summary,es.value=vt(e,"task_priority")??vt(e,"priority")??es.value);return}t.target_type==="keeper"&&(t.target_id&&(Na.value=t.target_id),cn.value=vt(e,"message")??t.summary)}function Wg(t){od({action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.suggested_payload,summary:t.summary})}function Gg(t){od({action_type:t.action_type,target_type:t.target_type,target_id:t.target_id??null,payload:t.suggested_payload,summary:t.reason}),O("추천 액션 payload를 폼에 채웠습니다","success")}function Jg(t,e,n){return!t||!t.target_type||t.target_type==="room"?!0:t.target_type==="team_session"?!!t.target_id&&e.some(s=>s.session_id===t.target_id):t.target_type==="keeper"?!!t.target_id&&n.some(s=>s.name===t.target_id):!0}async function _e(t){const e=no.value.trim()||"dashboard";try{const n=await tc({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?O("확인 대기열에 올렸습니다","warning"):O(t.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return O(s,"error"),null}}async function Wr(){const t=rn.value.trim();if(!t)return;await _e({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"방송을 보냈습니다"})&&(rn.value="")}async function Yg(){await _e({action_type:"room_pause",target_type:"room",payload:{reason:La.value.trim()||"운영 점검"},successMessage:"방 일시정지를 요청했습니다"})}async function id(){await _e({action_type:"room_resume",target_type:"room",payload:{},successMessage:"방 재개를 요청했습니다"})}async function Vg(){const t=ln.value.trim();if(!t)return;await _e({action_type:"task_inject",target_type:"room",payload:{title:t,description:Vn.value.trim()||"개입 화면에서 주입",priority:Number.parseInt(Xn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(ln.value="",Vn.value="")}async function Xg(){var l;const t=$t.value,e=mn.value||((l=t==null?void 0:t.sessions[0])==null?void 0:l.session_id)||"";if(!e){O("먼저 세션을 고르세요","warning");return}const n={};if(kt.value==="worker_spawn_batch"){const c=ns.value.trim();if(!c){O("spawn_batch JSON을 먼저 채우세요","warning");return}try{const _=JSON.parse(c);if(Array.isArray(_))n.spawn_batch=_;else if(_&&typeof _=="object"&&Array.isArray(_.spawn_batch))n.spawn_batch=_.spawn_batch;else{O("spawn_batch는 배열 또는 { spawn_batch: [...] } 형태여야 합니다","warning");return}}catch(_){const u=_ instanceof Error?_.message:"spawn_batch JSON 파싱에 실패했습니다";O(u,"error");return}await _e({action_type:"team_worker_spawn_batch",target_type:"team_session",target_id:e,payload:n,successMessage:"작업자 교체 요청을 적용했습니다"})&&(ns.value="");return}const s=Qn.value.trim();s&&(n.message=s);let a="team_note";kt.value==="broadcast"?a="team_broadcast":kt.value==="task"&&(a="team_task_inject"),kt.value==="task"&&(n.task_title=Zn.value.trim()||"운영자 주입 작업",n.task_description=ts.value.trim()||"개입 화면에서 주입",n.task_priority=Number.parseInt(es.value,10)||2),await _e({action_type:a,target_type:"team_session",target_id:e,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Qn.value="",kt.value==="task"&&(Zn.value="",ts.value=""))}async function Qg(){var n;const t=$t.value,e=mn.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){O("먼저 세션을 고르세요","warning");return}await _e({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Pa.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Zg(){var a;const t=$t.value,e=Na.value||((a=t==null?void 0:t.keepers[0])==null?void 0:a.name)||"",n=cn.value.trim();if(!e){O("먼저 키퍼를 고르세요","warning");return}if(!n)return;await _e({action_type:"keeper_message",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`${e}에게 메시지를 보냈습니다`})&&(cn.value="")}async function Gr(t,e="confirm"){const n=no.value.trim()||"dashboard";try{await ec(n,t,e),O(e==="deny"?"승인 대기를 거부했습니다":"확인 실행을 완료했습니다","success")}catch(s){const a=s instanceof Error?s.message:e==="deny"?"승인 대기 거부에 실패했습니다":"확인 실행에 실패했습니다";O(a,"error")}}function rd(t){switch(t){case"explicit":return"실제 관리 단위";case"hybrid":return"관리 단위 + 자동 보강";case"auto":return"자동 투영";default:return"출처 미상"}}function ld(t){switch(t){case"explicit":return"ok";case"hybrid":return"warn";case"auto":return"warn";default:return"warn"}}function t$(t){switch(t){case"explicit":return"지금 보이는 유닛은 실제로 정의된 지휘면 관리 단위입니다.";case"hybrid":return"일부는 실제 관리 단위이고, 비어 있는 부분은 실시간 에이전트 편성을 보고 자동 보강한 구조입니다.";case"auto":return"이 화면은 실시간 에이전트 편성을 지휘면 모양으로 자동 투영한 것입니다. 실제 명령 체계와 1:1로 같다고 보면 안 됩니다.";default:return"이 화면은 관리 토폴로지와 실효 토폴로지가 섞여 있을 수 있습니다."}}function e$(t){const e=t.unit.source??"unknown";return e==="explicit"?t.active_operation_count&&t.active_operation_count>0?"실제 관리 단위이며 연결된 작전이 있습니다.":"실제 관리 단위이지만 현재 연결된 작전은 없습니다.":e==="hybrid"?t.active_operation_count&&t.active_operation_count>0?"관리 단위를 기반으로 자동 보강된 구조이며 일부 작전이 연결돼 있습니다.":"관리 단위를 기반으로 자동 보강된 구조이며 현재 실행 연결은 약합니다.":t.active_operation_count&&t.active_operation_count>0?"자동 생성된 구조이지만 이 노드에 연결된 작전 흔적은 있습니다.":"자동 생성된 구조이며 현재 실행 연결은 없습니다."}function cd({node:t,depth:e=0}){const n=t.roster_live??0,s=t.roster_total??t.unit.roster.length,a=t.active_operation_count??0,i=t.unit.policy,l=t.unit.source??"unknown",c=a>0?`${a}개 작전 연결`:"실행 연결 없음";return o`
    <div class="command-tree-node depth-${Math.min(e,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${t.unit.label}</strong>
            <span class="command-chip">${qf(t.unit.kind)}</span>
            <span class="command-chip ${N(t.health)}">${t.health??"ok"}</span>
            <span class="command-chip ${ld(l)}">${rd(l)}</span>
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
          <div class="command-card-sub">${e$(t)}</div>
          ${t.reasons&&t.reasons.length>0?o`<div class="command-tag-row">
                ${t.reasons.map(p=>o`<span class="command-tag warn">${p}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${t.children.length>0?o`<div class="command-tree-children">
            ${t.children.map(p=>o`<${cd} node=${p} depth=${e+1} />`)}
          </div>`:null}
    </div>
  `}function n$({alert:t}){return o`
    <article class="command-alert ${N(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title??t.kind??t.alert_id}</strong>
        <span class="command-chip ${N(t.severity)}">${t.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.scope_type??"범위"}:${t.scope_id??"정보 없음"}</span>
        <span>${nt(t.timestamp)}</span>
      </div>
      ${t.detail?o`<p>${t.detail}</p>`:null}
    </article>
  `}function sr({event:t}){return o`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${t.event_type}</strong>
          <span class="command-chip">${t.source??"control_plane"}</span>
          <span class="command-chip">${nt(t.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${t.operation_id??t.trace_id}
          ${t.unit_id?` · ${t.unit_id}`:""}
          ${t.actor?` · ${t.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${Ma(t.detail)}</pre>
    </article>
  `}function s$(){const t=Bt.value,e=t==null?void 0:t.topology,n=e==null?void 0:e.source,s=e==null?void 0:e.summary,a=(s==null?void 0:s.managed_unit_count)??0,i=(s==null?void 0:s.active_operation_count)??0;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${K} panelId="command.topology" compact=${!0} />
      </div>
      ${t?o`
            <div class="command-topology-explainer">
              <div class="command-tree-title-row">
                <span class="command-chip ${ld(n)}">${rd(n)}</span>
                <span class="command-chip">관리 유닛 ${a}</span>
                <span class="command-chip ${i>0?"ok":"warn"}">활성 작전 ${i}</span>
              </div>
              <p>${t$(n)}</p>
            </div>
          `:null}
      ${t&&t.topology.units.length>0?o`${t.topology.units.map(l=>o`<${cd} node=${l} />`)}`:o`<div class="empty-state">지금은 실시간 에이전트나 관리 유닛 기준으로 그릴 지휘 계층이 없습니다.</div>`}
    </section>
  `}function a$(){const t=Bt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${K} panelId="command.alerts" compact=${!0} />
      </div>
      ${t&&t.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${t.alerts.alerts.map(e=>o`<${n$} alert=${e} />`)}
          </div>`:o`<div class="empty-state">지금 올라온 지휘면 경보는 없습니다.</div>`}
    </section>
  `}function o$(){const t=Bt.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${K} panelId="command.trace" compact=${!0} />
      </div>
      ${t&&t.traces.events.length>0?o`<div class="command-trace-stack">
            ${t.traces.events.map(e=>o`<${sr} event=${e} />`)}
          </div>`:o`<div class="empty-state">최근 트레이스 이벤트가 없습니다.</div>`}
    </section>
  `}function i$(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t,null,2)}catch{return String(t)}}function r$(t,e){return(e==null?void 0:e.status)==="abandoned"||(t==null?void 0:t.recommended_kind)==="continue"?"warn":(t==null?void 0:t.recommended_kind)==="rerun"?"bad":"ok"}function l$(t){switch(t){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(t==null?void 0:t.trim())||"결정"}}function c$(t){return t?t.runtime_blocker?"막힘":t.provider_reachable?"준비됨":"확인 필요":"확인 필요"}function dd({swarm:t}){var f,v;const e=t.run_id,n=t.resolution_recommendation,s=t.run_resolution;if(!e||!n&&!s)return null;const a=Vc()??"dashboard",i=((f=$t.value)==null?void 0:f.pending_confirms.find(h=>h.target_type==="swarm_run"&&h.target_id===e))??null,l=r$(n,s),c=((v=t.operation)==null?void 0:v.operation_id)??t.operation_id??void 0,p={run_id:e};c&&(p.operation_id=c),n!=null&&n.reason&&(p.reason=n.reason);const _=async h=>{await tc({actor:a,action_type:h,target_type:"swarm_run",target_id:e,payload:p})},u=async h=>{i&&await ec(a,i.confirm_token,h)};return o`
    <article class="command-guide-card ${N(l)}">
      <div class="command-guide-head">
        <strong>런 해석</strong>
        <span class="command-chip ${N(l)}">
          ${l$((s==null?void 0:s.status)??(n==null?void 0:n.recommended_kind)??null)}
        </span>
      </div>
      <p>
        ${(s==null?void 0:s.status)==="abandoned"?`이 run은 ${s.decided_by}가 ${nt(s.decided_at)}에 soft abandon 처리했습니다. ${s.reason}`:(n==null?void 0:n.reason)??"이 run에 대한 별도 resolution recommendation은 아직 없습니다."}
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
              ${n.evidence.runtime_blocker?o`<span class="command-tag ${N("bad")}">${n.evidence.runtime_blocker}</span>`:null}
            </div>
          `:null}
      ${i?o`
            <div class="command-guide-card warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip warn">${i.confirm_token}</span>
              </div>
              ${i.preview?o`<pre class="command-trace-detail">${i$(i.preview)}</pre>`:null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${()=>{u("confirm")}} disabled=${Z.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${()=>{u("deny")}} disabled=${Z.value}>취소</button>
              </div>
            </div>
          `:n?o`
              <div class="command-action-row">
                ${n.continue_available?o`<button class="control-btn ghost" onClick=${()=>{_("swarm_run_continue")}} disabled=${Z.value}>계속</button>`:null}
                ${n.rerun_available?o`<button class="control-btn" onClick=${()=>{_("swarm_run_rerun")}} disabled=${Z.value}>재실행</button>`:null}
                ${n.abandon_available?o`<button class="control-btn ghost" onClick=${()=>{_("swarm_run_abandon")}} disabled=${Z.value}>포기</button>`:null}
              </div>
            `:null}
    </article>
  `}function ud(t){return t.motion_state==="stalled"||t.hard_flags.some(e=>e.severity==="bad")?"bad":t.motion_state==="waiting"||t.hard_flags.some(e=>e.severity==="warn")?"warn":"ok"}function pd({lanes:t}){const e={moving:0,waiting:0,stalled:0,terminal:0};for(const a of t){const i=a.motion_state;i in e?e[i]++:e.waiting++}if(t.length===0)return null;const s=[{key:"moving",count:e.moving,color:"var(--ok)"},{key:"waiting",count:e.waiting,color:"var(--warn)"},{key:"stalled",count:e.stalled,color:"var(--bad)"},{key:"terminal",count:e.terminal,color:"#556"}];return o`
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
  `}function d$({total:t}){const n=Math.min(t,20),s=t>20?t-20:0,a=Array.from({length:n});return o`
    <div class="swarm-worker-grid">
      ${a.map(()=>o`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?o`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${t})</span>
    </div>
  `}function u$({lane:t}){const e=t.counts??{},n=ud(t),s=e.workers??0,a=e.operations??0,i=e.detachments??0,l=a+i,c=t.motion_state==="moving"?84:t.motion_state==="waiting"?58:t.motion_state==="terminal"?100:26;return o`
    <article class="swarm-lane-strip ${N(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${t.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${t.kind} · ${t.source_of_truth}</span>
            <strong>${t.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${N(n)}">${t.phase}</span>
          <span class="command-chip ${N(n)}">${t.motion_state}</span>
          <span class="command-chip">${nt(t.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${t.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${N(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${t.current_step}</span>
        </div>
        ${s>0?o`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${d$} total=${s} />
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
              ${t.hard_flags.map(p=>o`<span class="command-chip ${N(p.severity)}">${p.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function md({lanes:t}){const e=t.slice(0,4);return e.length===0?null:o`
    <div class="swarm-storyboard">
      ${e.map(n=>{const s=ud(n),a=n.counts.workers??0,i=n.counts.operations??0,l=n.counts.detachments??0;return o`
          <article class="swarm-story-card ${N(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${N(s)}">${n.motion_state}</span>
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
  `}function p$({event:t}){const e=t.timestamp?new Date(t.timestamp):null,n=e&&!isNaN(e.getTime())?e:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return o`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${N(t.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${t.title}</strong>
        <span class="swarm-event-kind">${t.kind}</span>
        ${t.detail?o`<div class="command-card-sub">${t.detail}</div>`:null}
      </div>
    </div>
  `}function m$({gap:t}){return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.summary}</strong>
          <div class="command-card-sub">${t.code} · lane ${t.lane_ids.join(", ")||"n/a"}</div>
        </div>
        <span class="command-chip ${N(t.severity)}">${t.count}</span>
      </div>
      ${t.why_it_matters?o`<p>${t.why_it_matters}</p>`:null}
      ${t.next_tool||t.next_step?o`
            <div class="command-card-grid">
              <span>다음 도구</span><span>${t.next_tool??"masc_observe_traces"}</span>
              <span>다음 확인</span><span>${t.next_step??"최근 trace를 확인합니다."}</span>
            </div>
          `:null}
    </article>
  `}function _$({swarm:t}){const e=t==null?void 0:t.narrative;return e?o`
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
  `:null}function v$({proof:t}){const e=(t==null?void 0:t.status)==="missing"?"warn":(t==null?void 0:t.pass)===!1?"bad":(t==null?void 0:t.pass)===!0?"ok":"warn";return o`
    <div class="command-guide-card ${N(e)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${N(e)}">${(t==null?void 0:t.status)??"missing"}</span>
        </div>
      ${t?o`
            <p>${t.status_summary??t.missing_reason??"아직 스웜 증거가 수집되지 않았습니다."}</p>
            <div class="command-card-grid">
              <span>소스</span><span>${t.source}</span>
              <span>상태 코드</span><span>${t.reason_code??"n/a"}</span>
              <span>런</span><span>${t.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${nt(t.captured_at)}</span>
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
  `}function f$(){const t=gs(),e=ps(F.value),n=Bf(e),s=t==null?void 0:t.swarm_status,a=t==null?void 0:t.swarm_proof,i=(s==null?void 0:s.lanes.filter(f=>f.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],p=s==null?void 0:s.overview,_=s==null?void 0:s.recommended_next_action,u=i.length<=1;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${K} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?o`
            <${md} lanes=${i} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(p==null?void 0:p.active_lanes)??0}</strong><small>${(p==null?void 0:p.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(p==null?void 0:p.stalled_lanes)??0}</strong><small>${(p==null?void 0:p.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${nt(p==null?void 0:p.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${nt(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(_==null?void 0:_.label)??"운영자 상태 확인"}</strong><small>${(_==null?void 0:_.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${i.length>0?o`<${pd} lanes=${i} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${i.length>0?i.map(f=>o`<${u$} lane=${f} />`):o`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <${_$} swarm=${s} />

                <div class="command-guide-card highlight ${n==="recommendation"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>${(_==null?void 0:_.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(_==null?void 0:_.lane_id)??"전체"}</span>
                  </div>
                  <p>${(_==null?void 0:_.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(_==null?void 0:_.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${v$} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${N(l.some(f=>f.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?o`<div class="command-card-stack">${l.slice(0,4).map(f=>o`<${m$} gap=${f} />`)}</div>`:o`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?o`<div class="swarm-event-rail">${c.map(f=>o`<${p$} event=${f} />`)}</div>`:o`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:o`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function g$({item:t}){return o`
    <article class="command-guide-card ${N(t.status)}">
      <div class="command-guide-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${N(t.status)}">${t.status}</span>
      </div>
      <p>${t.detail}</p>
      <div class="command-card-foot">Next tool: ${t.next_tool}</div>
    </article>
  `}function _d({blocker:t}){return o`
    <article class="command-alert ${N(t.severity)}">
      <div class="command-card-head">
        <strong>${t.title}</strong>
        <span class="command-chip ${N(t.severity)}">${t.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${t.code}</span>
        <span>next ${t.next_tool}</span>
      </div>
      <p>${t.detail}</p>
    </article>
  `}function $$({worker:t}){return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${N(t.joined?t.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${t.last_message?o`<div class="command-card-foot">${nt(t.last_message.timestamp)} · ${t.last_message.content}</div>`:null}
    </article>
  `}function h$(){var u,f,v,h,A,k,S,b,$,R,M,L,J,z,W,Y,st,P,T,C,D,j;const t=De.value,e=Qc(),n=Xi(),s=c$(t==null?void 0:t.provider),a=((u=t==null?void 0:t.provider)==null?void 0:u.configured_capacity)??0,i=((f=t==null?void 0:t.provider)==null?void 0:f.actual_slots)??((v=t==null?void 0:t.provider)==null?void 0:v.total_slots)??0,l=((h=t==null?void 0:t.provider)==null?void 0:h.expected_slots)??"n/a",c=((A=t==null?void 0:t.provider)==null?void 0:A.actual_ctx)??((k=t==null?void 0:t.provider)==null?void 0:k.ctx_per_slot)??0,p=((S=t==null?void 0:t.provider)==null?void 0:S.expected_ctx)??"n/a",_=((b=t==null?void 0:t.summary)==null?void 0:b.peak_hot_slots)??(($=t==null?void 0:t.provider)==null?void 0:$.peak_active_slots)??0;return o`
    <div class="command-section-stack">
      <${f$} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${K} panelId="command.swarm" compact=${!0} />
          </div>
          ${ka.value?o`<div class="empty-state">Loading swarm live state…</div>`:xa.value?o`<div class="empty-state error">${xa.value}</div>`:t?o`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${t.run_id??e??"swarm-live"}</strong><small>${t.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((R=t.summary)==null?void 0:R.joined_workers)??0}/${((M=t.summary)==null?void 0:M.expected_workers)??0}</strong><small>${((L=t.summary)==null?void 0:L.live_workers)??0}개 가동 · ${((J=t.summary)==null?void 0:J.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임 계약</span><strong>${s}</strong><small>설정 ${a||"n/a"} · 실제 ${i}/${l} · ctx ${c}/${p}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(z=t.summary)!=null&&z.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>최대 hot ${_} · ${((W=t.provider)==null?void 0:W.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(Y=t.summary)!=null&&Y.pass_end_to_end?"통과":"확인 필요"}</strong><small>${t.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((st=t.operation)==null?void 0:st.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((P=t.squad)==null?void 0:P.label)??"없음"}</span>
                      <span>실행체</span><span>${((T=t.detachment)==null?void 0:T.detachment_id)??"없음"}</span>
                      <span>목표 해석</span><span>target profile 기준, 달성 사실과 분리</span>
                      <span>예상 워커</span><span>${((C=t.summary)==null?void 0:C.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((D=t.summary)==null?void 0:D.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((j=t.provider)==null?void 0:j.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${t.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${t.truth_notes.length>0?o`<div class="command-tag-row">
                          ${t.truth_notes.map(Q=>o`<span class="command-tag">${Q}</span>`)}
                        </div>`:null}
                    <${dd} swarm=${t} />
                  `:o`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${K} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.checklist.length>0?o`<div class="command-card-stack">
                ${t.checklist.map(Q=>o`<${g$} item=${Q} />`)}
              </div>`:o`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${K} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.workers.length>0?o`<div class="command-card-stack">
                ${t.workers.map(Q=>o`<${$$} worker=${Q} />`)}
              </div>`:o`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${K} panelId="command.swarm" compact=${!0} />
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
                  <span>마지막 샘플</span><span>${t.provider.last_sample_at?nt(t.provider.last_sample_at):"정보 없음"}</span>
                  <span>런타임 막힘</span><span>${t.provider.runtime_blocker??"없음"}</span>
                  <span>검사 시각</span><span>${t.provider.checked_at?nt(t.provider.checked_at):"정보 없음"}</span>
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
                                <span class="command-chip">${nt(Q.timestamp)}</span>
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
            <${K} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.blockers.length>0?o`<div class="command-card-stack">
                ${t.blockers.map(Q=>o`<${_d} blocker=${Q} />`)}
              </div>`:o`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(t==null?void 0:t.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${K} panelId="command.swarm" compact=${!0} />
          </div>
          ${t&&t.recent_messages.length>0?o`<div class="command-trace-stack">
                ${t.recent_messages.map(Q=>o`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${Q.from}</strong>
                        <span class="command-chip">${nt(Q.timestamp)}</span>
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
            <${K} panelId="command.trace" compact=${!0} />
          </div>
          ${t&&t.recent_trace_events.length>0?o`<div class="command-trace-stack">
                ${t.recent_trace_events.map(Q=>o`<${sr} event=${Q} />`)}
              </div>`:o`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function y$(t){return t==="swarm"?"스웜 실시간":"세션 요약"}function b$(t){switch(t){case"current":return"현재 과업 일치";case"drift":return"과업 드리프트";case"claim":return"착수 흔적 있음";case"no-claim":return"착수 흔적 없음";case"done":return"완료 흔적 있음";case"no-done":return"완료 흔적 없음";case"final":return"최종 보고 있음";case"no-final":return"최종 보고 없음";case"turn":return"턴 기록 있음";case"silent":return"턴 기록 없음";case"noted":return"노트 기록 있음";default:return t.startsWith("empty:")?`빈 노트 ${t.slice(6)}회`:t.startsWith("turns:")?`턴 ${t.slice(6)}회`:t}}function k$(t){var n;const e=[t.current_task_matches_run?"current":"drift",t.claim_marker_seen?"claim":"no-claim",t.done_marker_seen?"done":"no-done",t.final_marker_seen?"final":"no-final"];return{key:`swarm:${t.name}`,name:t.name,role:t.role,lane:t.lane,status:t.status,source:"swarm",task:t.current_task??t.bound_task_title??t.bound_task_id??"할당 없음",heartbeat:t.heartbeat_age_sec!=null?`${Math.round(t.heartbeat_age_sec)}초`:t.heartbeat_fresh?"정상":"정보 없음",detail:[t.bound_task_status??null,t.detachment_member?"분견대 소속":null,t.squad_member?"분대 소속":null].filter(Boolean).join(" · ")||"스웜 실시간 카드",markers:e,note:((n=t.last_message)==null?void 0:n.content)??null}}function x$(t,e){const n=t.actor??t.spawn_role??`워커-${e+1}`,s=t.spawn_role??t.worker_class??t.spawn_agent??"워커",a=t.lane_id??t.capsule_mode??t.control_domain??"세션",i=[t.has_turn?"turn":"silent",t.empty_note_turn_count>0?`empty:${t.empty_note_turn_count}`:"noted",t.turn_count>0?`turns:${t.turn_count}`:"turns:0"];return{key:`session:${n}:${e}`,name:n,role:s,lane:a,status:t.status,source:"session",task:t.task_profile??t.runtime_pool??"세션 레인",heartbeat:t.last_turn_ts_iso?nt(t.last_turn_ts_iso):"정보 없음",detail:[t.spawn_agent??null,t.spawn_model??null,t.routing_confidence!=null?vs(t.routing_confidence):null].filter(Boolean).join(" · ")||"세션 요약 카드",markers:i,note:t.routing_reason??null}}function Jr(t){return N(t.severity)}function S$({worker:t}){return o`
    <article class="command-card compact warroom-worker-card ${N(Ge(t.status))}">
      <div class="command-card-head">
        <div>
          <strong>${t.name}</strong>
          <div class="command-card-sub">${t.role} · ${t.lane}</div>
        </div>
        <span class="command-chip ${N(Ge(t.status))}">${Se(t.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>출처</span><span>${y$(t.source)}</span>
        <span>과업</span><span>${t.task}</span>
        <span>최근 신호</span><span>${t.heartbeat}</span>
        <span>근거</span><span>${t.detail}</span>
      </div>
      <div class="command-tag-row">
        ${t.markers.map(e=>o`<span class="command-tag">${b$(e)}</span>`)}
      </div>
      ${t.note?o`<div class="command-card-foot">${t.note}</div>`:null}
    </article>
  `}function ee({label:t,surface:e,params:n={}}){return o`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(e){ce(e),it("command",{...Vi(e),...n});return}it("intervene")}}
    >
      ${t}
    </button>
  `}function C$(){var T,C,D,j,Q,Ut,H,Lt,ye,bn,kn,$s,hs,ys,bs,ks,xs,Ss,dr,ur,pr;const t=gs(),e=De.value,n=$t.value,s=Ft.value,a=Vf(),i=e!=null&&e.operation?((T=us.value)==null?void 0:T.operations.find(et=>{var Cs;return et.operation.operation_id===((Cs=e.operation)==null?void 0:Cs.operation_id)}))??null:null,l=Jf(),c=(e==null?void 0:e.workers)??[],p=(s==null?void 0:s.worker_cards)??[],_=l&&c.length>0?c.map(k$):p.map(x$),u=l,f=((C=t==null?void 0:t.decisions.summary)==null?void 0:C.pending)??0,v=(n==null?void 0:n.pending_confirms)??[],h=l?(e==null?void 0:e.blockers)??[]:[],A=(s==null?void 0:s.recommended_actions)??[],k=(D=s==null?void 0:s.active_recommended_actions)!=null&&D.length?s.active_recommended_actions:A,S=s==null?void 0:s.active_summary,b=(s==null?void 0:s.active_guidance_layer)??"fallback",$=(s==null?void 0:s.resident_judge_runtime)??(n==null?void 0:n.resident_judge_runtime),R=(s==null?void 0:s.attention_items)??[],M=((j=e==null?void 0:e.recent_messages[0])==null?void 0:j.timestamp)??null,L=((Q=e==null?void 0:e.recent_trace_events[0])==null?void 0:Q.timestamp)??null,J=l?M??L??null:null,z=a==null?void 0:a.summary,W=(l?(Ut=e==null?void 0:e.summary)==null?void 0:Ut.expected_workers:void 0)??(typeof(z==null?void 0:z.planned_worker_count)=="number"?z.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,Y=(l?(H=e==null?void 0:e.summary)==null?void 0:H.joined_workers:void 0)??(typeof(z==null?void 0:z.active_agent_count)=="number"?z.active_agent_count:void 0)??_.length,st=h.length>0||f>0||v.length>0?"warn":u||a?"ok":"warn",P=l?((Lt=t==null?void 0:t.swarm_status)==null?void 0:Lt.lanes.filter(et=>et.present))??[]:[];return ot(()=>{xt()},[]),ot(()=>{a!=null&&a.session_id&&pn(a.session_id)},[a==null?void 0:a.session_id,n,(ye=e==null?void 0:e.detachment)==null?void 0:ye.session_id]),!u&&!a?ka.value||Un.value?o`<div class="empty-state">실시간 워룸 불러오는 중…</div>`:o`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">실시간 워룸</div>
          <${K} panelId="command.warroom" compact=${!0} />
        </div>
        <div class="command-warroom-empty-copy">
          <strong>지금 보이는 실시간 실행이 없습니다</strong>
          <p>활성 작전이나 팀 세션이 시작되면 이 화면이 자동으로 붙잡습니다.</p>
        </div>
        <div class="command-action-row">
          <${ee} label="작전 보기" surface="operations" />
          <${ee} label="스웜 보기" surface="swarm" />
          <${ee} label="개입 열기" />
          <${ee} label="제어 보기" surface="control" />
        </div>
      </section>
    `:o`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${N(st)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">실시간 워룸</span>
            <strong>${l?((bn=e==null?void 0:e.operation)==null?void 0:bn.objective)??(a==null?void 0:a.session_id)??"가동 중인 실행":(a==null?void 0:a.session_id)??"가동 중인 실행"}</strong>
            <div class="command-card-sub">
              ${l?((kn=e==null?void 0:e.operation)==null?void 0:kn.operation_id)??"작전 정보 없음":"세션 기준값"}
              ${a!=null&&a.session_id?` · 세션 ${a.session_id}`:""}
              ${l&&(($s=e==null?void 0:e.detachment)!=null&&$s.detachment_id)?` · 분견대 ${e.detachment.detachment_id}`:""}
            </div>
            ${S!=null&&S.summary?o`<div class="command-warroom-guidance ${Ea(b)}">
                  <strong>${tr(b)}</strong>
                  <span>${S.summary}</span>
                </div>`:null}
          </div>
          <div class="command-action-row">
            <${ee}
              label="스웜 상세"
              surface="swarm"
              params=${{...l&&((hs=e==null?void 0:e.operation)!=null&&hs.operation_id)?{operation_id:e.operation.operation_id}:{},...l&&(e!=null&&e.run_id)?{run_id:e.run_id}:{}}}
            />
            <${ee} label="트레이스" surface="trace" />
            ${l&&i?o`<${ee}
                  label="체인"
                  surface="chains"
                  params=${{operation:i.operation.operation_id}}
                />`:null}
            <${ee} label="개입" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>워커</span>
            <strong>${Y??0}/${W??0}</strong>
            <small>${l?((ys=e==null?void 0:e.summary)==null?void 0:ys.completed_workers)??0:0} 완료 · ${_.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>런타임</span>
            <strong>${l?(bs=e==null?void 0:e.provider)!=null&&bs.runtime_blocker?"막힘":(ks=e==null?void 0:e.provider)!=null&&ks.provider_reachable?"준비됨":a?Se(a.status):"확인 필요":a?Se(a.status):"확인 필요"}</strong>
            <small>${l?`설정 ${((xs=e==null?void 0:e.provider)==null?void 0:xs.configured_capacity)??"n/a"} · 실제 ${((Ss=e==null?void 0:e.provider)==null?void 0:Ss.actual_slots)??((dr=e==null?void 0:e.provider)==null?void 0:dr.total_slots)??0} · hot ${((ur=e==null?void 0:e.summary)==null?void 0:ur.peak_hot_slots)??((pr=e==null?void 0:e.provider)==null?void 0:pr.peak_active_slots)??0}`:`세션 워커 ${(s==null?void 0:s.worker_cards.length)??0}`}</small>
          </div>
          <div class="monitor-stat-card ${N(h.length>0||f>0?"warn":"ok")}">
            <span>압력</span>
            <strong>${h.length+f+v.length}</strong>
            <small>막힘 ${h.length} · 승인 ${f} · 확인 ${v.length}</small>
          </div>
          <div class="monitor-stat-card ${N(Ea(b))}">
            <span>상주 판정기</span>
            <strong>${er($)}</strong>
            <small>${nr(S)}${$!=null&&$.model_used?` · ${$.model_used}`:""}</small>
          </div>
          <div class="monitor-stat-card">
            <span>마지막 신호</span>
            <strong>${nt(J)}</strong>
            <small>${M?"메시지":L?"트레이스":"대기 중"}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${K} panelId="command.warroom" compact=${!0} />
            </div>
            ${P.length>0?o`
                  <${md} lanes=${P} />
                  <${pd} lanes=${P} />
                `:a?o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${N(Ge(a.status))}">${Se(a.status)}</span>
                      </div>
                      <p>스웜 실시간 증거는 아직 약합니다. 이 카드는 세션 요약과 워커 기록을 기준으로 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${In(a.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${In(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:o`<div class="empty-state">보이는 레인이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">워커 현황</div>
              <${K} panelId="command.warroom" compact=${!0} />
            </div>
            ${_.length>0?o`<div class="command-card-stack">
                  ${_.map(et=>o`<${S$} worker=${et} />`)}
                </div>`:o`<div class="empty-state">활성 워커 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">상황 피드</div>
              <${K} panelId="command.warroom" compact=${!0} />
            </div>
            ${e&&e.recent_messages.length>0&&l?o`<div class="command-trace-stack">
                  ${e.recent_messages.map(et=>o`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${et.from}</strong>
                          <span class="command-chip">${nt(et.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${et.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${et.content}</pre>
                    </article>
                  `)}
                </div>`:k.length>0||R.length>0?o`<div class="command-card-stack">
                    ${k.slice(0,4).map(et=>o`
                      <article class="command-guide-card ${Jr(et)}">
                        <div class="command-guide-head">
                          <strong>${et.action_type}</strong>
                          <span class="command-chip ${Jr(et)}">${et.target_type}</span>
                        </div>
                        <p>${et.reason}</p>
                      </article>
                    `)}
                    ${R.slice(0,3).map(et=>o`
                      <article class="command-alert ${N(et.severity)}">
                        <div class="command-card-head">
                          <strong>${et.kind}</strong>
                          <span class="command-chip ${N(et.severity)}">${et.severity}</span>
                        </div>
                        <p>${et.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?o`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((et,Cs)=>o`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>세션 이벤트 ${Cs+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${Ma(et)}</pre>
                        </article>
                      `)}
                    </div>`:o`<div class="empty-state">메시지나 주의 항목이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">트레이스 흐름</div>
              <${K} panelId="command.trace" compact=${!0} />
            </div>
            ${e&&e.recent_trace_events.length>0?o`<div class="command-trace-stack">
                  ${e.recent_trace_events.map(et=>o`<${sr} event=${et} />`)}
                </div>`:o`<div class="empty-state">실행 범위 트레이스 이벤트가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">압력</div>
              <${K} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&e?o`<${dd} swarm=${e} />`:null}
              ${h.length>0?h.map(et=>o`<${_d} blocker=${et} />`):o`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${f>0?o`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>승인 대기</strong>
                        <span class="command-chip warn">${f}</span>
                      </div>
                      <p>엄격 액션이 묶여 있습니다. 실제 승인 처리는 제어 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${v.length>0?o`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>확인 대기</strong>
                        <span class="command-chip warn">${v.length}</span>
                      </div>
                      <p>운영자 미리보기가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${v.slice(0,3).map(et=>o`<span class="command-tag">${et.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
            </div>
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">현재 초점</div>
              <${K} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&(e!=null&&e.operation)?o`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${e.operation.objective}</strong>
                          <div class="command-card-sub">${e.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${N(Ge(e.operation.status))}">${Se(e.operation.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>유닛</span><span>${e.operation.assigned_unit_id}</span>
                        <span>트레이스</span><span>${e.operation.trace_id}</span>
                        <span>자율성</span><span>${e.operation.autonomy_level??"정보 없음"}</span>
                        <span>최근 갱신</span><span>${nt(e.operation.updated_at)}</span>
                      </div>
                    </article>
                  `:null}
              ${l&&(e!=null&&e.detachment)?o`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${e.detachment.detachment_id}</strong>
                          <div class="command-card-sub">${e.detachment.assigned_unit_id}</div>
                        </div>
                        <span class="command-chip ${N(Ge(e.detachment.status))}">${Se(e.detachment.status??"active")}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>리더</span><span>${e.detachment.leader_id??"미지정"}</span>
                        <span>편성</span><span>${e.detachment.roster.length}</span>
                        <span>세션</span><span>${e.detachment.session_id??"연결 없음"}</span>
                        <span>하트비트</span><span>${Gc(e.detachment.heartbeat_deadline)}</span>
                      </div>
                    </article>
                  `:null}
              ${a?o`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${a.session_id}</strong>
                          <div class="command-card-sub">현재 세션 기준</div>
                        </div>
                        <span class="command-chip ${N(Ge(a.status))}">${Se(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${In(a.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${In(a.remaining_sec)}</span>
                        <span>완료 변화량</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function Yr(t){switch((t??"").trim().toLowerCase()){case"active":return"가동 중";case"paused":return"일시정지";case"failed":return"실패";case"completed":case"done":return"완료";case"disconnected":return"끊김";case"preview":return"미리보기";case"captured":return"기록됨";default:return(t==null?void 0:t.trim())||"확인 필요"}}function A$({source:t}){const e=Hs(null),[n,s]=xi(null);return ot(()=>{let a=!1;const i=e.current;return i?(i.innerHTML="",s(null),(async()=>{try{const c=await Lf(),{svg:p}=await c.render(`command-chain-${Mf()}`,t);if(a||!e.current)return;e.current.innerHTML=p}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid 렌더링에 실패했습니다")}})(),()=>{a=!0,e.current&&(e.current.innerHTML="")}):void 0},[t]),o`
    <div class="command-chain-graph-shell">
      ${n?o`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${e}></div>
    </div>
  `}function T$({overlay:t,selected:e,onSelect:n}){const s=t.operation.chain,a=t.runtime;return o`
    <button class="command-chain-item ${e?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${t.operation.objective}</strong>
          <div class="command-card-sub">${t.operation.operation_id}</div>
        </div>
        <span class="command-chip ${de(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??t.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?o`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?o`<span class="command-tag ${de(s==null?void 0:s.status)}">${vs(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${Jc(t.history)}</div>
    </button>
  `}function I$({item:t}){return o`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${t.chain_id??"알 수 없는 체인"}</strong>
        <span class="command-chip ${de(t.event)}">${t.event}</span>
      </div>
      <div class="command-card-sub">${nt(t.timestamp)}</div>
      <div class="command-card-sub">${Jc(t)}</div>
    </article>
  `}function z$({node:t}){return o`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${t.id}</strong>
        <span class="command-chip ${de(t.status)}">${t.status??"확인 필요"}</span>
      </div>
      <div class="command-card-sub">
        ${t.type??"노드"}
        ${typeof t.duration_ms=="number"?` · ${t.duration_ms}ms`:""}
      </div>
      ${t.error?o`<div class="command-card-sub error-text">${t.error}</div>`:null}
    </article>
  `}function R$({card:t}){const e=t.operation,n=`pause:${e.operation_id}`,s=`resume:${e.operation_id}`,a=`recall:${e.operation_id}`,i=e.chain,l=(i==null?void 0:i.run_id)??null;return o`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.objective}</strong>
          <div class="command-card-sub">${e.operation_id}</div>
        </div>
        <span class="command-chip ${N(e.status==="active"?"ok":e.status==="paused"?"warn":e.status==="failed"?"bad":"ok")}">${Yr(e.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>트레이스</span><span class="mono">${e.trace_id}</span>
        <span>자율성</span><span>${e.autonomy_level??"정보 없음"}</span>
        <span>예산 등급</span><span>${e.budget_class??"standard"}</span>
        <span>출처</span><span>${e.source??"managed"}</span>
        <span>최근 갱신</span><span>${nt(e.updated_at)}</span>
      </div>
      ${i?o`
            <div class="command-tag-row">
              <span class="command-tag">${i.kind}</span>
              <span class="command-tag ${de(i.status)}">${Yr(i.status)}</span>
              ${i.chain_id?o`<span class="command-tag">${i.chain_id}</span>`:null}
              ${i.run_id?o`<span class="command-tag">실행 ${i.run_id}</span>`:null}
            </div>
          `:null}
      ${e.checkpoint_ref?o`<div class="command-card-foot">체크포인트 ${e.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{ce("swarm"),it("command",{surface:"swarm",operation_id:e.operation_id,...l?{run_id:l}:{}})}}
        >
          스웜 실시간 보기
        </button>
        ${i?o`
              <button
                class="control-btn ghost"
                onClick=${()=>{Fi(e.operation_id),ce("chains"),it("command",{surface:"chains",operation:e.operation_id})}}
              >
                체인 열기
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="active"?o`
              <button class="control-btn ghost" disabled=${ct(n)} onClick=${()=>ue(()=>av(e.operation_id))}>
                ${ct(n)?"일시정지 중…":"일시정지"}
              </button>
              <button class="control-btn ghost" disabled=${ct(a)} onClick=${()=>ue(()=>iv(e.operation_id))}>
                ${ct(a)?"회수 중…":"회수"}
              </button>
            `:null}
        ${e.source==="managed"&&e.status==="paused"?o`
              <button class="control-btn ghost" disabled=${ct(s)} onClick=${()=>ue(()=>ov(e.operation_id))}>
                ${ct(s)?"재개 중…":"재개"}
              </button>
            `:null}
      </div>
    </article>
  `}function M$({card:t}){var n;const e=t.detachment;return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.detachment_id}</strong>
          <div class="command-card-sub">${((n=t.operation)==null?void 0:n.objective)??e.operation_id}</div>
        </div>
        <span class="command-chip ${N(e.status)}">${e.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${t.assigned_unit_label??e.assigned_unit_id}</span>
        <span>리더</span><span>${e.leader_id??"미지정"}</span>
        <span>편성</span><span>${e.roster.length}</span>
        <span>세션</span><span>${e.session_id??"연결 없음"}</span>
        <span>런타임</span><span>${e.runtime_kind??"managed"}</span>
        <span>런타임 참조</span><span>${e.runtime_ref??"정보 없음"}</span>
        <span>진행 흔적</span><span>${nt(e.last_progress_at)}</span>
        <span>하트비트</span><span>${Gc(e.heartbeat_deadline)}</span>
        <span>최근 갱신</span><span>${nt(e.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${e.heartbeat_deadline?o`<span class="command-tag ${zf(e.heartbeat_deadline)}">
              기한 ${e.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function L$(){const t=Bt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">작전</div>
          <${K} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.operations.operations.length>0?o`<div class="command-card-stack">
              ${t.operations.operations.map(e=>o`<${R$} card=${e} />`)}
            </div>`:o`<div class="empty-state">관리형 또는 투영된 작전이 없습니다.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">분견대</div>
          <${K} panelId="command.operations" compact=${!0} />
        </div>
        ${t&&t.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${t.detachments.detachments.map(e=>o`<${M$} card=${e} />`)}
            </div>`:o`<div class="empty-state">투영된 분견대가 없습니다.</div>`}
      </section>
    </div>
  `}function P$(){var c,p,_,u,f,v,h,A,k,S,b,$,R,M,L,J;const t=us.value,e=(t==null?void 0:t.operations)??[],n=sn.value,s=e.find(z=>z.operation.operation_id===n)??e[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,i=((p=Wn.value)==null?void 0:p.run)??(s==null?void 0:s.preview_run)??null,l=!((_=Wn.value)!=null&&_.run)&&!!(s!=null&&s.preview_run);return ot(()=>{a?nv(a):ev()},[a]),o`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${K} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${de(t==null?void 0:t.connection.status)}">
          <div class="command-guide-head">
            <strong>native chain 연결</strong>
            <span class="command-chip ${de(t==null?void 0:t.connection.status)}">${(t==null?void 0:t.connection.status)??"disconnected"}</span>
          </div>
          <p>${(t==null?void 0:t.connection.message)??"체인 요약은 MASC 프록시를 통해 집계됩니다."}</p>
          <div class="command-card-grid">
            <span>기준 URL</span><span>${(t==null?void 0:t.connection.base_url)??"정보 없음"}</span>
            <span>연결된 작전</span><span>${((u=t==null?void 0:t.summary)==null?void 0:u.linked_operations)??0}</span>
            <span>활성 체인</span><span>${((f=t==null?void 0:t.summary)==null?void 0:f.active_chains)??0}</span>
            <span>최근 실패</span><span>${((v=t==null?void 0:t.summary)==null?void 0:v.recent_failures)??0}</span>
            <span>마지막 이벤트</span><span>${nt((h=t==null?void 0:t.summary)==null?void 0:h.last_history_event_at)}</span>
          </div>
        </article>

        ${Ca.value?o`<div class="empty-state error">${Ca.value}</div>`:null}

        ${li.value&&!t?o`<div class="empty-state">체인 오버레이 불러오는 중…</div>`:e.length>0?o`
                <div class="command-chain-list">
                  ${e.map(z=>o`
                    <${T$}
                      overlay=${z}
                      selected=${(s==null?void 0:s.operation.operation_id)===z.operation.operation_id}
                      onSelect=${()=>Fi(z.operation.operation_id)}
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
                  ${t.recent_history.slice(0,6).map(z=>o`<${I$} item=${z} />`)}
                </div>
              `:o`<div class="empty-state">최근 체인 이력이 없습니다.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">체인 상세</div>
          <${K} panelId="command.chains" compact=${!0} />
        </div>
        ${s?o`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${de((A=s.operation.chain)==null?void 0:A.status)}">
                    ${((k=s.operation.chain)==null?void 0:k.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>종류</span><span>${((S=s.operation.chain)==null?void 0:S.kind)??"chain_dsl"}</span>
                  <span>체인 ID</span><span>${((b=s.operation.chain)==null?void 0:b.chain_id)??"goal-driven"}</span>
                  <span>실행 ID</span><span>${a??"아직 구체화되지 않음"}</span>
                  <span>진행률</span><span>${vs(($=s.runtime)==null?void 0:$.progress)}</span>
                  <span>경과</span><span>${In((R=s.runtime)==null?void 0:R.elapsed_sec)}</span>
                  <span>최근 갱신</span><span>${nt(((M=s.operation.chain)==null?void 0:M.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(L=s.operation.chain)!=null&&L.goal?o`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?o`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid 그래프</strong>
                        <span class="command-chip">${((J=s.operation.chain)==null?void 0:J.chain_id)??"graph"}</span>
                      </div>
                      <${A$} source=${s.mermaid} />
                    </div>
                  `:o`<div class="empty-state">기록된 Mermaid 그래프가 아직 없습니다.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>실행 상세</strong>
                  <span class="command-chip ${(i==null?void 0:i.success)===!1?"bad":"ok"}">
                    ${i?i.success===!1?"실패":l?"미리보기":"기록됨":"대기 중"}
                  </span>
                </div>
                ${Aa.value?o`<div class="empty-state">실행 상세 불러오는 중…</div>`:Gn.value?o`<div class="empty-state error">${Gn.value}</div>`:i&&i.nodes.length>0?o`
                          <div class="command-card-grid">
                            <span>체인</span><span>${i.chain_id}</span>
                            <span>실행</span><span>${i.run_id??"미리보기만 있음"}</span>
                            <span>지속시간</span><span>${i.duration_ms!=null?`${i.duration_ms}ms`:"정보 없음"}</span>
                            <span>노드</span><span>${i.nodes.length}</span>
                          </div>
                          ${l?o`<div class="command-card-foot">run-store에 기록되기 전, 설계된 체인으로 만든 미리보기입니다.</div>`:null}
                          <div class="command-card-stack">
                            ${i.nodes.map(z=>o`<${z$} node=${z} />`)}
                          </div>
                        `:o`<div class="empty-state">이 작전의 run-store 상세는 아직 없습니다.</div>`}
              </div>
            `:o`<div class="empty-state">그래프와 실행 상세를 보려면 체인 기반 작전을 고르세요.</div>`}
      </section>
    </div>
  `}function N$(t){switch((t??"").trim().toLowerCase()){case"pending":return"대기 중";case"approved":return"승인됨";case"denied":return"거부됨";case"executed":return"실행됨";case"active":return"가동 중";default:return(t==null?void 0:t.trim())||"확인 필요"}}function j$({decision:t}){const e=`approve:${t.decision_id}`,n=`deny:${t.decision_id}`,s=t.source==="projected_operator";return o`
    <article class="command-card ${N(t.status)}">
      <div class="command-card-head">
        <div>
          <strong>${t.requested_action}</strong>
          <div class="command-card-sub">${t.scope_type}:${t.scope_id}</div>
        </div>
        <span class="command-chip ${N(t.status)}">${N$(t.status??"pending")}</span>
      </div>
      <div class="command-card-grid">
        <span>결정 ID</span><span>${t.decision_id}</span>
        <span>요청자</span><span>${t.requested_by??"알 수 없음"}</span>
        <span>출처</span><span>${t.source??"managed"}</span>
        <span>트레이스</span><span class="mono">${t.trace_id}</span>
        <span>생성 시각</span><span>${nt(t.created_at)}</span>
        <span>이유</span><span>${t.reason??"정보 없음"}</span>
      </div>
      ${t.status==="pending"&&!s?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${ct(e)} onClick=${()=>ue(()=>lv(t.decision_id))}>
                ${ct(e)?"승인 중…":"승인"}
              </button>
              <button class="control-btn ghost" disabled=${ct(n)} onClick=${()=>ue(()=>cv(t.decision_id))}>
                ${ct(n)?"거부 중…":"거부"}
              </button>
            </div>
          `:null}
      ${s?o`<div class="command-card-foot">레거시 operator 승인입니다. 실제 실행은 operator control에서 처리합니다.</div>`:null}
    </article>
  `}function E$({row:t}){var c,p,_;const e=t.unit,n=`freeze:${e.unit_id}`,s=`kill:${e.unit_id}`,a=!!((c=e.policy)!=null&&c.frozen),i=!!((p=e.policy)!=null&&p.kill_switch),l=Math.round((t.utilization??0)*100);return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.label}</strong>
          <div class="command-card-sub">${e.unit_id}</div>
        </div>
        <span class="command-chip ${N(l>100?"bad":l>70?"warn":"ok")}">${l}%</span>
      </div>
      <div class="command-card-grid">
        <span>편성</span><span>${t.roster_live??0}/${t.roster_total??0}</span>
        <span>정원</span><span>${t.headcount_cap??0}</span>
        <span>작전</span><span>${t.active_operations??0}/${t.active_operation_cap??0}</span>
        <span>자율성</span><span>${((_=e.policy)==null?void 0:_.autonomy_level)??"정보 없음"}</span>
        <span>동결</span><span>${a?"예":"아니오"}</span>
        <span>킬 스위치</span><span>${i?"켜짐":"꺼짐"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${ct(n)} onClick=${()=>ue(()=>dv(e.unit_id,!a))}>
          ${ct(n)?"적용 중…":a?"동결 해제":"동결"}
        </button>
        <button class="control-btn ghost" disabled=${ct(s)} onClick=${()=>ue(()=>uv(e.unit_id,!i))}>
          ${ct(s)?"적용 중…":i?"킬 스위치 해제":"킬 스위치 켜기"}
        </button>
      </div>
    </article>
  `}function O$(){const t=Bt.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${K} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${t.decisions.decisions.map(e=>o`<${j$} decision=${e} />`)}
            </div>`:o`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">유닛 제어</div>
          <${K} panelId="command.control" compact=${!0} />
        </div>
        ${t&&t.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${t.capacity.capacity.map(e=>o`<${E$} row=${e} />`)}
            </div>`:o`<div class="empty-state">제어할 용량 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function D$(){return o`
    <div class="command-surface-tabs grouped">
      ${Nf.map(t=>o`
        <div class="command-tab-group" key=${t.id}>
          <span class="command-tab-group-label">${t.label}</span>
          <div class="command-tab-group-items">
            ${Yc.filter(e=>e.group===t.id).map(e=>o`
                <button
                  class="command-surface-tab ${tt.value===e.id?"active":""}"
                  onClick=${()=>{ce(e.id),it("command",Vi(e.id))}}
                >
                  ${e.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function w$(){if(tt.value==="warroom")return o`<${C$} />`;if(tt.value==="summary")return o`<${bg} />`;if(tt.value==="orchestra")return o`<${Eg} />`;if(tt.value==="swarm")return o`<${h$} />`;if(!Bt.value)return o`<${kg} />`;switch(tt.value){case"chains":return o`<${P$} />`;case"topology":return o`<${s$} />`;case"alerts":return o`<${a$} />`;case"trace":return o`<${o$} />`;case"control":return o`<${O$} />`;case"operations":default:return o`<${L$} />`}}function q$(){return ot(()=>{We(),an(),sv(),se(),Le()},[]),ot(()=>{if(F.value.tab!=="command")return;const t=F.value.params.surface,e=F.value.params.operation,n=ps(F.value);if(Or(t))ce(t);else if(n){const s=Rc(n);Or(s)&&ce(s)}else t||ce("warroom");e&&Fi(e),(t==="swarm"||t==="warroom"||t==="orchestra"||tt.value==="warroom"||tt.value==="orchestra")&&se(),(t==="orchestra"||tt.value==="orchestra")&&Le(),(t==="warroom"||tt.value==="warroom")&&xt()},[F.value.tab,F.value.params.surface,F.value.params.operation,F.value.params.operation_id,F.value.params.run_id,F.value.params.source,F.value.params.action_type,F.value.params.target_type,F.value.params.target_id,F.value.params.focus_kind]),ot(()=>{let t=null;const e=()=>{t||(t=window.setTimeout(()=>{t=null,We(),an(),(tt.value==="swarm"||tt.value==="warroom"||tt.value==="orchestra")&&se(),tt.value==="orchestra"&&Le(),tt.value==="warroom"&&xt()},250))},n=new EventSource(wf()),s=Ef.map(a=>{const i=()=>e();return n.addEventListener(a,i),{type:a,handler:i}});return n.onerror=()=>{e()},()=>{s.forEach(({type:a,handler:i})=>{n.removeEventListener(a,i)}),n.close(),t&&window.clearTimeout(t)}},[]),ot(()=>{const t=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const e=tt.value;e!=="swarm"&&e!=="warroom"&&e!=="orchestra"||(We(),se(),e==="orchestra"&&Le(),e==="warroom"&&xt())},5e3);return()=>{window.clearInterval(t)}},[]),o`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{ue(()=>rv())}}
            disabled=${ct("dispatch:tick")}
          >
            ${ct("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Re(),We(),an(),se(),tt.value==="warroom"&&xt()}}
            disabled=${fa.value}
          >
            ${fa.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${$a.value?o`<div class="empty-state error">${$a.value}</div>`:null}
      ${ya.value?o`<div class="empty-state error">${ya.value}</div>`:null}
      <${St} surfaceId="command" />
      <${Za} />
      <${fg} />
      ${tt.value==="warroom"?null:o`<${gg} />`}
      <${D$} />
      <${w$} />
    </section>
  `}function F$(){var S,b;const t=$t.value,e=ji.value,n=(t==null?void 0:t.room)??{},s=(t==null?void 0:t.pending_confirms)??[],a=t==null?void 0:t.pending_confirm_summary,i=a?a.confirm_required_actions:((t==null?void 0:t.available_actions)??[]).filter($=>$.confirm_required),l=((S=a==null?void 0:a.actor_filter)==null?void 0:S.trim())||null,c=(a==null?void 0:a.hidden_count)??0,p=(a==null?void 0:a.hidden_actors)??[],_=(t==null?void 0:t.recent_messages)??[],u=(e==null?void 0:e.recommended_actions)??[],f=(b=e==null?void 0:e.active_recommended_actions)!=null&&b.length?e.active_recommended_actions:u,v=e==null?void 0:e.active_summary,h=(e==null?void 0:e.resident_judge_runtime)??(t==null?void 0:t.resident_judge_runtime),A=(e==null?void 0:e.active_guidance_layer)??"fallback",k=_.slice(0,5);return o`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Room 개입</div>
          <${K} panelId="intervene.action_studio" compact=${!0} />
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
          <div class="ops-stat ${wg(h)}">
            <span>Resident Judge</span>
            <strong>${er(h)}</strong>
          </div>
        </div>

        <label class="control-label" for="ops-broadcast">Room 방송</label>
        <div class="control-row">
          <input
            id="ops-broadcast"
            class="control-input"
            type="text"
            placeholder="@agent 또는 room 전체 공지"
            value=${rn.value}
            onInput=${$=>{rn.value=$.target.value}}
            onKeyDown=${$=>{$.key==="Enter"&&Wr()}}
            disabled=${Z.value}
          />
          <button class="control-btn" onClick=${()=>{Wr()}} disabled=${Z.value||rn.value.trim()===""}>
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
            onInput=${$=>{La.value=$.target.value}}
            disabled=${Z.value}
          />
          <button class="control-btn ghost" onClick=${()=>{Yg()}} disabled=${Z.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{id()}} disabled=${Z.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${ln.value}
          onInput=${$=>{ln.value=$.target.value}}
          disabled=${Z.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${Vn.value}
          onInput=${$=>{Vn.value=$.target.value}}
          disabled=${Z.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${Xn.value}
            onChange=${$=>{Xn.value=$.target.value}}
            disabled=${Z.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{Vg()}} disabled=${Z.value||ln.value.trim()===""}>
            주입
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">추천 개입</div>
          <${K} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
        <article class="ops-guidance-card ${Ea(A)}">
          <div class="ops-guidance-head">
            <strong>${tr(A)}</strong>
            <span>${(h==null?void 0:h.keeper_name)??(e==null?void 0:e.judgment_owner)??"judge 없음"}</span>
          </div>
          <div class="ops-guidance-body">
            ${(v==null?void 0:v.summary)??"현재 active guidance 요약이 없습니다. fallback queue만 표시합니다."}
          </div>
          <div class="ops-guidance-meta">
            <span>authoritative ${e!=null&&e.authoritative_judgment_available?"yes":"no"}</span>
            <span>${nr(v)}</span>
            ${h!=null&&h.model_used?o`<span>${h.model_used}</span>`:null}
          </div>
        </article>
        ${Hn.value&&!e?o`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:f.length>0?o`
          <div class="ops-log-list">
            ${f.map($=>o`
              <article key=${`${$.action_type}:${$.target_type}:${$.target_id??"room"}`} class="ops-log-entry ${$.severity}">
                <div class="ops-log-head">
                  <strong>${je($.action_type)}</strong>
                  <span>${dn($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                  <span>${Oa($.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${$.reason}</div>
                ${$.suggested_payload?o`
                  <div class="ops-confirmation-actions">
                    <button class="control-btn ghost" onClick=${()=>{Gg($)}} disabled=${Z.value}>
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
          <${K} panelId="intervene.pending_confirmations" compact=${!0} />
        </div>
        <p class="ops-context-note">
          ${l?`현재 actor ${l} 기준 queue를 읽습니다. 승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다.`:"승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다."}
        </p>
        ${i.length>0?o`
          <div class="ops-log-list">
            ${i.map($=>o`
              <article key=${`${$.action_type}:${$.target_type}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${je($.action_type)}</strong>
                  <span>${dn($.target_type)}</span>
                  <span>${Oa($.confirm_required)}</span>
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
                  <strong>${je($.action_type)}</strong>
                  <span>${dn($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                  <span>${$.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${$.preview?o`<pre class="ops-code-block compact">${ja($.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{Gr($.confirm_token)}} disabled=${Z.value}>
                    실행
                  </button>
                  <button class="control-btn ghost" onClick=${()=>{Gr($.confirm_token,"deny")}} disabled=${Z.value}>
                    거부
                  </button>
                  <span class="ops-token">${$.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        `:o`
          <div class="ops-empty">
            ${c>0&&l?`현재 선택한 actor(${l}) 기준 승인 대기는 0건입니다. 다른 actor 대기 ${c}건${p.length>0?` · ${p.join(", ")}`:""}`:"지금 승인 대기는 없습니다. 위 목록의 preview-confirm 액션을 먼저 만들어야 여기에 쌓입니다."}
          </div>
        `}
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 Room 메시지</div>
          <${K} panelId="intervene.recommended_actions" compact=${!0} />
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
  `}function K$(){var _;const t=$t.value,e=Ft.value,n=(t==null?void 0:t.sessions)??[],s=((t==null?void 0:t.available_actions)??[]).filter(u=>u.target_type==="team_session"),a=n.find(u=>u.session_id===mn.value)??n[0]??null,i=e==null?void 0:e.active_summary,l=(e==null?void 0:e.active_guidance_layer)??"fallback",c=(e==null?void 0:e.resident_judge_runtime)??(t==null?void 0:t.resident_judge_runtime),p=(_=e==null?void 0:e.active_recommended_actions)!=null&&_.length?e.active_recommended_actions:(e==null?void 0:e.recommended_actions)??[];return o`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${K} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?o`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(u=>{var f;return o`
            <button
              key=${u.session_id}
              class="ops-entity-card ${(a==null?void 0:a.session_id)===u.session_id?"active":""}"
              onClick=${()=>{mn.value=u.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${u.session_id}</strong>
                <span class="status-badge ${u.status??"idle"}">${Ye(u.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(u.progress_pct??0)}%</span>
                <span>${u.done_delta_total??0}건 완료</span>
                <span>${(f=u.team_health)!=null&&f.status?Ye(String(u.team_health.status)):"상태 확인 필요"}</span>
              </div>
            </button>
          `})}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Session 요약</div>
          <${K} panelId="intervene.session_digest" compact=${!0} />
        </div>
        <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
        ${a&&e?o`
          <article class="ops-guidance-card ${Ea(l)}">
            <div class="ops-guidance-head">
              <strong>${tr(l)}</strong>
              <span>${er(c)}</span>
            </div>
            <div class="ops-guidance-body">
              ${(i==null?void 0:i.summary)??"현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다."}
            </div>
            <div class="ops-guidance-meta">
              <span>authoritative ${e.authoritative_judgment_available?"yes":"no"}</span>
              <span>${nr(i)}</span>
              ${c!=null&&c.model_used?o`<span>${c.model_used}</span>`:null}
            </div>
          </article>
          ${p.length>0?o`
            <div class="ops-log-list">
              ${p.map(u=>o`
                <article key=${`${u.action_type}:${u.target_type}:${u.target_id??"session"}`} class="ops-log-entry ${u.severity}">
                  <div class="ops-log-head">
                    <strong>${je(u.action_type)}</strong>
                    <span>${dn(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
                  </div>
                  <div class="ops-log-body">${u.reason}</div>
                </article>
              `)}
            </div>
          `:null}
          <div class="ops-log-list">
            ${e.attention_items.length>0?e.attention_items.map(u=>o`
              <article key=${`${u.kind}:${u.target_id??"session"}`} class="ops-log-entry ${u.severity}">
                <div class="ops-log-head">
                  <strong>${u.kind}</strong>
                  <span>${dn(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${u.summary}</div>
              </article>
            `):o`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${e.worker_cards.length>0?e.worker_cards.map(u=>o`
              <article key=${`${u.actor??u.spawn_role??"worker"}:${u.spawn_agent??u.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${u.actor??u.spawn_role??"worker"}</strong>
                  <span>${Ye(u.status)}</span>
                  <span>${u.spawn_agent??u.runtime_pool??"runtime 확인 필요"}</span>
                </div>
                <div class="ops-log-body">
                  ${u.worker_class??"worker"}${u.lane_id?` · ${u.lane_id}`:""}${u.routing_reason?` · ${u.routing_reason}`:""}
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
          <${K} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>
        ${s.length>0?o`
          <div class="ops-log-list">
            ${s.map(u=>o`
              <article key=${u.action_type} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${je(u.action_type)}</strong>
                  <span>${Oa(u.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${u.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}

        ${a?o`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${a.session_id}</div>
            <div class="ops-detail-meta">
              <span>상태: ${Ye(a.status)}</span>
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
            `:null}
            ${a.recent_events&&a.recent_events.length>0?o`
              <pre class="ops-code-block compact">${ja(a.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:o`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${kt.value}
            onChange=${u=>{kt.value=u.target.value}}
            disabled=${Z.value||!a}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
            <option value="worker_spawn_batch">worker 교체</option>
          </select>
          <button class="control-btn" onClick=${()=>{Xg()}} disabled=${Z.value||!a}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${Bg(kt.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${Qn.value}
          onInput=${u=>{Qn.value=u.target.value}}
          disabled=${Z.value||!a}
        ></textarea>

        ${kt.value==="task"?o`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${Zn.value}
            onInput=${u=>{Zn.value=u.target.value}}
            disabled=${Z.value||!a}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${ts.value}
            onInput=${u=>{ts.value=u.target.value}}
            disabled=${Z.value||!a}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${es.value}
            onChange=${u=>{es.value=u.target.value}}
            disabled=${Z.value||!a}
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
            value=${ns.value}
            onInput=${u=>{ns.value=u.target.value}}
            disabled=${Z.value||!a}
          ></textarea>
        `:null}

        <div class="control-row ops-split-row">
          <input
            class="control-input"
            type="text"
            value=${Pa.value}
            onInput=${u=>{Pa.value=u.target.value}}
            disabled=${Z.value||!a}
          />
          <button class="control-btn ghost" onClick=${()=>{Qg()}} disabled=${Z.value||!a}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function B$(){var i;const t=$t.value,e=(t==null?void 0:t.keepers)??[],n=(t==null?void 0:t.persistent_agents)??[],s=(t==null?void 0:t.available_actions)??[],a=e.find(l=>l.name===Na.value)??e[0]??null;return o`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${K} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${e.length===0?o`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:e.map(l=>o`
            <button
              key=${l.name}
              class="ops-entity-card ${(a==null?void 0:a.name)===l.name?"active":""}"
              onClick=${()=>{Na.value=l.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${l.name}</strong>
                <span class="status-badge ${l.status??"idle"}">${Ye(l.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${l.model??"model 확인 필요"}</span>
                <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${Ur(l.last_turn_ago_s)}</span>
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
                    <span class="status-badge ${l.status??"idle"}">${Ye(l.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>persistent</span>
                    <span>${l.model??"model 확인 필요"}</span>
                    <span>${Ur(l.last_turn_ago_s)}</span>
                  </div>
                </article>
              `)}
        </div>
      </section>

      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Keeper 액션</div>
          <${K} panelId="intervene.action_studio" compact=${!0} />
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
        `:o`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

        <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
        <textarea
          id="ops-keeper-message"
          class="control-textarea"
          rows=${6}
          placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
          value=${cn.value}
          onInput=${l=>{cn.value=l.target.value}}
          disabled=${Z.value||!a}
        ></textarea>
        <div class="control-row">
          <button class="control-btn" onClick=${()=>{Zg()}} disabled=${Z.value||!a||cn.value.trim()===""}>
            keeper에 보내기
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">가능한 액션 목록</div>
          <${K} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
        <div class="ops-log-list">
          ${s.length?s.map(l=>o`
                <article key=${`${l.action_type}:${l.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${je(l.action_type)}</strong>
                    <span>${dn(l.target_type)}</span>
                    <span>${Oa(l.confirm_required)}</span>
                  </div>
                  <div class="ops-log-body">${l.description??"설명이 아직 없습니다."}</div>
                </article>
              `):o`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 개입 로그</div>
          <${K} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <div class="ops-log-list">
          ${pa.value.length===0?o`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:pa.value.map(l=>o`
            <article key=${l.id} class="ops-log-entry ${l.outcome}">
              <div class="ops-log-head">
                <strong>${je(l.action_type)}</strong>
                <span>${l.target_label}</span>
                <span>${l.at}</span>
              </div>
              <div class="ops-log-body">${l.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function U$(){var M,L,J;const t=$t.value,e=F.value.tab==="intervene"?ps(F.value):null,n=ji.value,s=(t==null?void 0:t.room)??{},a=(t==null?void 0:t.sessions)??[],i=(t==null?void 0:t.keepers)??[],l=(t==null?void 0:t.pending_confirms)??[],c=t==null?void 0:t.pending_confirm_summary,p=(c==null?void 0:c.visible_count)??l.length,_=(c==null?void 0:c.total_count)??l.length,u=(c==null?void 0:c.hidden_count)??0,f=((M=c==null?void 0:c.actor_filter)==null?void 0:M.trim())||null,v=a.find(z=>z.session_id===mn.value)??a[0]??null,h=(n==null?void 0:n.attention_items)??[],A=h.filter(Fg),k=h.filter(Kg),S=a.filter(z=>qg(z)!=="ok"),b=i.filter(z=>go(z)!=="ok"),$=Jg(e,a,i);ot(()=>{Ee()},[]),ot(()=>{if(F.value.tab!=="intervene"){Ns.value=null;return}if(!e){Ns.value=null;return}Ns.value!==e.id&&(Ns.value=e.id,Wg(e))},[F.value.tab,F.value.params.source,F.value.params.action_type,F.value.params.target_type,F.value.params.target_id,F.value.params.focus_kind,e==null?void 0:e.id]),ot(()=>{const z=(v==null?void 0:v.session_id)??null;pn(z)},[v==null?void 0:v.session_id]);const R=[{key:"room",label:"방 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:u>0?`${p}/${_}`:p,detail:p>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":u>0&&f?`현재 개입 ID(${f}) 기준으로는 비어 있고, 다른 개입 ID 대기 ${u}건이 있습니다`:"지금 막혀 있는 확인 대기는 없습니다",tone:_>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:A.length>0?A.length:a.length,detail:A.length>0?((L=A[0])==null?void 0:L.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 팀 세션이 없습니다":"세션 쪽 긴급 주의 신호는 현재 없습니다",tone:A.length>0?Hr(A):a.length===0?"warn":S.some(z=>_n(z.status)==="paused")?"bad":S.length>0?"warn":"ok"},{key:"keeper",label:"키퍼 압력",value:k.length>0?k.length:b.length,detail:k.length>0?((J=k[0])==null?void 0:J.summary)??"직접 메시지나 상태 점검이 필요한 키퍼가 있습니다":b.length>0?"오래됐거나 오프라인이거나 텔레메트리가 비는 키퍼가 보입니다":"지금은 키퍼 쪽이 비교적 안정적입니다",tone:k.length>0?Hr(k):b.some(z=>go(z)==="bad")?"bad":b.length>0?"warn":"ok"}];return o`
    <section class="ops-view">
      <${St} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">개입</div>
            <${K} panelId="intervene.action_studio" compact=${!0} />
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
            value=${no.value}
            onInput=${z=>Dg(z.target.value)}
          />
            <button
              class="control-btn ghost"
              onClick=${()=>{Re(),xt(),Ee(),pn((v==null?void 0:v.session_id)??null)}}
            disabled=${Un.value||Z.value}
          >
            ${Un.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${me.value?o`<section class="ops-banner error">${me.value}</section>`:null}
      ${un.value?o`<section class="ops-banner error">${un.value}</section>`:null}
      <${Za} />
      ${e?o`
        <section class="ops-banner ${$?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${e.source_label}</strong>
            <span>${to(e.action_type)}</span>
            <span>${Hi(e)}</span>
          </div>
          <div class="ops-handoff-body">${e.summary}</div>
          ${e.payload_preview?o`<div class="ops-handoff-preview">${e.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${$?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const z=[];if((p>0||u>0)&&z.push({label:u>0?`확인 대기 ${p}/${_}건 확인`:`확인 대기 ${p}건 처리`,desc:u>0&&f?`현재 개입 ID(${f}) 기준으로 보이는 대기열을 먼저 확인합니다`:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:p>0?"bad":"warn",onClick:()=>{const W=document.querySelector(".ops-pending-section");W==null||W.scrollIntoView({behavior:"smooth"})}}),s.paused&&z.push({label:"방 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void id()}),b.length>0){const W=b.filter(Y=>go(Y)==="bad");z.push({label:W.length>0?`오프라인 키퍼 ${W.length}개`:`점검이 필요한 키퍼 ${b.length}개`,desc:W.length>0?"메시지를 보내거나 상태를 확인하세요":"오래됐거나 텔레메트리가 비어 있습니다",tone:W.length>0?"bad":"warn",onClick:()=>{const Y=document.querySelector(".ops-keeper-section");Y==null||Y.scrollIntoView({behavior:"smooth"})}})}return z.length===0?null:o`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${z.slice(0,3).map(W=>o`
                <button class="ops-action-guide-item ${W.tone}" onClick=${W.onClick}>
                  <strong>${W.label}</strong>
                  <span>${W.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `})()}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${K} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 방인지, 세션인지, 키퍼인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${R.map(z=>o`
            <div key=${z.key} class="ops-priority-card ${z.tone}">
              <span class="ops-priority-label">${z.label}</span>
              <strong>${z.value}</strong>
              <div class="ops-priority-detail">${z.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${F$} />
        <${K$} />
        <${B$} />
      </div>
    </section>
  `}function H$({text:t}){if(!t)return null;const e=W$(t);return o`<div class="markdown-content">${e}</div>`}function W$(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),p=[];for(s++;s<e.length&&!e[s].startsWith(l);)p.push(e[s]),s++;s++,n.push(o`<pre><code class=${c?`language-${c}`:""}>${p.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<e.length&&!e[s].includes("</think>");)l.push(e[s]),s++;if(s<e.length){const _=e[s].replace("</think>","").trim();_&&l.push(_),s++}const p=l.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${$o(p)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<e.length&&e[s].startsWith("> ");)l.push(e[s].slice(2)),s++;n.push(o`<blockquote>${$o(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const l=e[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;i.push(l),s++}i.length>0&&n.push(o`<p>${$o(i.join(`
`))}</p>`)}return n}function $o(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const vd=[{id:"recent",label:"최신순"},{id:"hot",label:"인기순"},{id:"trending",label:"급상승"},{id:"updated",label:"최근 갱신"},{id:"discussed",label:"토론 많은 순"}],ea=g(null),na=g([]),vn=g(!1),Ne=g(null),jn=g(""),En=g(!1),Ve=g(!0),ar=20,Ke=g(ar);function G$(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const J$=g(G$());function Y$(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"미리보기 없음"}function Vr(t){return t.updated_at!==t.created_at}function V$(t){if(t.post_kind)return t.post_kind==="automation";const e=(t.hearth??"").toLowerCase();return t.visibility!=="internal"||!t.expires_at||!e?!1:!!(e.startsWith("mdal")||e.includes("harness"))}function X$(t){return t==="lodge-system"||t==="team-session"}function ss(t){return t.post_kind?t.post_kind:X$(t.author)?"system":V$(t)?"automation":"human"}function fd(t){const e=[],n=[];let s=0;return t.forEach(a=>{const i=ss(a);if(!(i==="system"&&Ie.value)){if(i==="automation"&&Ve.value){s+=1;return}if(i==="human"){e.push(a);return}n.push(a)}}),{human:e,operations:n,hiddenAutomation:s}}function Q$(t){if(!t.expires_at)return null;const e=Date.parse(t.expires_at);return Number.isFinite(e)?e<=Date.now()?o`<span class="board-meta-chip">만료됨</span>`:o`<span class="board-meta-chip">만료까지 <${X} timestamp=${t.expires_at} /></span>`:null}async function or(t){Ne.value=t,ea.value=null,na.value=[],vn.value=!0;try{const e=await Eu(t);if(Ne.value!==t)return;ea.value={id:e.id,author:e.author,title:e.title,body:e.body,content:e.content,meta:e.meta,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,post_kind:e.post_kind,flair:e.flair,hearth:e.hearth,visibility:e.visibility,expires_at:e.expires_at,hearth_count:e.hearth_count},na.value=e.comments??[]}catch{Ne.value===t&&(ea.value=null,na.value=[])}finally{Ne.value===t&&(vn.value=!1)}}async function Xr(t){const e=jn.value.trim();if(e){En.value=!0;try{await Ou(t,J$.value,e),jn.value="",O("댓글을 등록했습니다","success"),await or(t),re()}catch{O("댓글 등록에 실패했습니다","error")}finally{En.value=!1}}}function Z$(){const t=Kn.value,e=Ve.value?"자동화 글 숨김":"자동화 글 표시 중";return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${vd.map(n=>o`
          <button
            class="board-sort-btn ${t===n.id?"active":""}"
            onClick=${()=>{Kn.value=n.id,Ke.value=ar,re()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Ve.value?"is-active":""}"
          onClick=${()=>{Ve.value=!Ve.value}}
        >
          ${e}
        </button>
        <button
          class="control-btn ghost ${Ie.value?"is-active":""}"
          onClick=${()=>{Ie.value=!Ie.value,re()}}
        >
          ${Ie.value?"시스템 글 숨김":"시스템 글 표시 중"}
        </button>
        <button class="control-btn ghost" onClick=${re} disabled=${Bn.value}>
          ${Bn.value?"새로고침 중...":"새로고침"}
        </button>
      </div>
    </div>
  `}function ho(){var s;const t=((s=vd.find(a=>a.id===Kn.value))==null?void 0:s.label)??Kn.value,e=fd(Xa.value),n=e.human.length+e.operations.length;return o`
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
        <strong>${Ve.value?`자동화 ${e.hiddenAutomation}건 숨김`:"분리된 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">시스템 글 정책</span>
        <strong>${Ie.value?"시스템 글 숨김":"시스템 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">최근 갱신</span>
        <strong>${ti.value?o`<${X} timestamp=${ti.value} />`:"아직 불러오지 않음"}</strong>
      </div>
    </div>
  `}function Qr({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await zl(t.id,n),re()}catch{O("투표에 실패했습니다","error")}};return o`
    <div class="board-post" onClick=${()=>wd(t.id)}>
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
                ${Vr(t)?o`<span class="board-meta-chip">수정됨</span>`:null}
                ${ss(t)!=="human"?o`<span class="board-meta-chip">${ss(t)}</span>`:null}
                ${t.hearth?o`<span class="board-meta-chip">${t.hearth}</span>`:null}
                ${t.visibility?o`<span class="board-meta-chip">${t.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>작성자 ${t.author}</span>
            <span><${X} timestamp=${t.created_at} /></span>
            ${Vr(t)?o`<span>수정 <${X} timestamp=${t.updated_at} /></span>`:null}
            <span>댓글 ${t.comment_count}</span>
            <span>투표 ${t.votes??0}</span>
          </div>
        </div>
        <div class="post-snippet">${Y$(t.body)}</div>
      </div>
    </div>
  `}function th({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">아직 댓글이 없습니다</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${X} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function eh({postId:t}){return o`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="댓글 추가..."
        value=${jn.value}
        onInput=${e=>{jn.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Xr(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${En.value}
      />
      <button
        onClick=${()=>Xr(t)}
        disabled=${En.value||jn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${En.value?"...":"등록"}
      </button>
    </div>
  `}function nh({post:t}){Ne.value!==t.id&&!vn.value&&or(t.id);const e=async n=>{try{await zl(t.id,n),re()}catch{O("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>it("memory")}>← 메모리로 돌아가기</button>
      <${I} title=${t.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${H$} text=${t.body} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${t.author}</span>
            <${X} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
          </div>
          ${t.hearth||t.visibility||t.expires_at?o`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${t.hearth?o`<span class="board-meta-chip">${t.hearth}</span>`:null}
                  ${t.visibility?o`<span class="board-meta-chip">${t.visibility}</span>`:null}
                  ${ss(t)!=="human"?o`<span class="board-meta-chip">${ss(t)}</span>`:null}
                  ${Q$(t)}
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

      <${I} title="댓글" semanticId="memory.feed">
        ${vn.value?o`<div class="loading-indicator">댓글 불러오는 중...</div>`:o`<${th} comments=${na.value} />`}
        <${eh} postId=${t.id} />
      <//>
    </div>
  `}function sh(){const t=fd(Xa.value),e=[...t.human,...t.operations],n=F.value.params.post??null,s=n?e.find(a=>a.id===n)??(Ne.value===n?ea.value:null):null;return n&&!s&&Ne.value!==n&&!vn.value&&or(n),n?s?o`
          <${St} surfaceId="memory" />
          <${ho} />
          <${nh} post=${s} />
        `:o`
          <div>
            <${St} surfaceId="memory" />
            <${ho} />
            <button class="back-btn" onClick=${()=>it("memory")}>← 메모리로 돌아가기</button>
            ${vn.value?o`<div class="loading-indicator">글 불러오는 중...</div>`:o`<div class="empty-state">글을 찾지 못했습니다</div>`}
          </div>
        `:o`
    <div>
      <${St} surfaceId="memory" />
      <${ho} />
      <${Z$} />
      ${Bn.value?o`<div class="loading-indicator">메모리 피드 불러오는 중...</div>`:e.length===0?o`<div class="empty-state">지금은 남아 있는 메모리 글이 없습니다</div>`:o`
              <${I} title="사람이 쓴 글" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${t.human.slice(0,Ke.value).map(a=>o`<${Qr} key=${a.id} post=${a} />`)}
                </div>
                ${t.human.length>Ke.value?o`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{Ke.value=Ke.value+ar}}
                    >
                      더 보기 (${t.human.length-Ke.value}개 남음)
                    </button>
                  </div>
                `:null}
              <//>
              ${t.operations.length>0?o`
                    <${I} title="자동화 · 시스템" class="section" semanticId="memory.feed">
                      <div class="board-post-list">
                        ${t.operations.map(a=>o`<${Qr} key=${a.id} post=${a} />`)}
                      </div>
                    <//>
                  `:null}
            `}
    </div>
  `}function ah({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,l=i*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),o`
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
  `}const Ae=g(null),Ht=g(null),Wt=g(null);function fn(t){return t==="bad"||t==="critical"||t==="offline"?"bad":t==="warn"||t==="paused"||t==="blocked"||t==="interrupted"?"warn":"ok"}function Da(t){switch((t??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":return"주의";case"bad":case"critical":return"위험";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"unknown":case"":return"확인 필요";default:return(t==null?void 0:t.trim())||"확인 필요"}}function oh(t){return t==="session"?"세션":"작전"}function ih(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function rh(t){return t?ge.value.find(e=>e.name===t||e.agent_name===t)??null:null}function lh(t){switch(t){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function ch(t){switch(t){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function dh(t){switch(t){case"acted":return"행동";case"passed":return"통과";case"skipped":return"건너뜀";case"failed":return"실패";default:return t}}function uh(t){switch(t){case"post":return"post";case"comment":return"comment";case"vote":return"vote";case"none":case null:case void 0:return"none";default:return t}}function wa(t,e="없음"){const n=t??[];return n.length===0?e:n.length<=3?n.join(", "):`${n.slice(0,3).join(", ")} +${n.length-3}`}function Zr(t){if(!t)return;const e=bv({targetType:t.target_type,targetId:t.target_id,focusKind:t.focus_kind,operationId:t.operation_id??null,commandSurface:t.command_surface??null,sourceLabel:"실행 진단",summary:t.label});Ic(e),it(t.surface,t.surface==="intervene"?zc(e):Mc(e))}function Rt({label:t,value:e,color:n,caption:s}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${s?o`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function ir({intervene:t,command:e}){return o`
    <div class="control-row">
      ${t?o`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),Zr(t)}}
            >
              ${t.label}
            </button>
          `:null}
      ${e?o`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),Zr(e)}}
            >
              ${e.label}
            </button>
          `:null}
    </div>
  `}function ph({item:t,selected:e}){return o`
    <button
      class="mission-card-select ${e?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{Ae.value=e?null:t.id,Ht.value=null,Wt.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${t.kind==="session"?t.target_id:t.linked_session_id??t.target_id}</div>
          <div class="mission-card-title">${t.summary}</div>
        </div>
        <span class="command-chip ${fn(t.severity)}">${Da(t.status??t.severity)}</span>
      </div>
      <div class="mission-card-meta">
        <span>${oh(t.kind)}</span>
        ${t.linked_operation_id?o`<span>연결 작전 · ${t.linked_operation_id}</span>`:null}
        ${t.last_seen_at?o`<span><${X} timestamp=${t.last_seen_at} /></span>`:null}
      </div>
      <${ir} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function mh({brief:t,selected:e}){return o`
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
        <span class="command-chip ${fn(t.health??t.status)}">${Da(t.status)}</span>
      </div>
      <div class="mission-card-meta">
        <span>건강도 · ${Da(t.health??"ok")}</span>
        ${t.linked_operation_id?o`<span>연결 작전 · ${t.linked_operation_id}</span>`:null}
        ${t.last_activity_at?o`<span><${X} timestamp=${t.last_activity_at} /></span>`:null}
      </div>
      ${t.runtime_blocker?o`<div class="mission-card-detail">${t.runtime_blocker}</div>`:t.last_activity_summary?o`<div class="mission-card-detail">${t.last_activity_summary}</div>`:null}
      ${t.worker_gap_summary?o`<div class="monitor-footnote">${t.worker_gap_summary}</div>`:null}
      <${ir} intervene=${t.intervene_handoff} command=${t.command_handoff} />
    </button>
  `}function _h({brief:t,selected:e}){return o`
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
        <span class="command-chip ${fn(t.blocker_summary?"warn":t.status)}">${Da(t.status)}</span>
      </div>
      <div class="mission-card-meta">
        ${t.stage?o`<span>단계 · ${t.stage}</span>`:null}
        ${t.linked_session_id?o`<span>세션 · ${t.linked_session_id}</span>`:null}
        ${t.updated_at?o`<span><${X} timestamp=${t.updated_at} /></span>`:null}
      </div>
      ${t.blocker_summary?o`<div class="mission-card-detail">${t.blocker_summary}</div>`:null}
      ${t.next_tool?o`<div class="monitor-footnote">다음 도구 · ${t.next_tool}</div>`:null}
      <${ir} command=${t.command_handoff} />
    </button>
  `}function vh({tick:t}){return t?o`
    <div class="monitor-nested-card">
      <div class="stats-grid">
        <${Rt} label="checked" value=${t.checked??0} color="#22d3ee" />
        <${Rt} label="acted" value=${t.acted??0} color="#4ade80" />
        <${Rt} label="passed" value=${t.passed??0} color="#94a3b8" />
        <${Rt} label="skipped" value=${t.skipped??0} color="#fbbf24" />
        <${Rt} label="failed" value=${t.failed??0} color="#fb7185" />
      </div>
      <div class="monitor-meta">
        ${t.last_tick_at?o`<span>마지막 tick <${X} timestamp=${t.last_tick_at} /></span>`:o`<span>마지막 tick 없음</span>`}
        ${t.last_skip_reason?o`<span>대표 skip 이유 · ${t.last_skip_reason}</span>`:null}
      </div>
      ${t.activity_report?o`<div class="monitor-footnote">${t.activity_report}</div>`:null}
    </div>
  `:o`<div class="empty-state">최근 lodge tick 기록이 없습니다.</div>`}function fh({row:t}){return o`
    <button
      class="monitor-row ${fn(t.outcome==="failed"?"bad":t.outcome==="skipped"?"warn":"ok")}"
      data-testid="execution.lodge-checkin-card"
      onClick=${()=>_s(t.agent_name)}
    >
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.agent_name}</span>
            ${t.worker_name?o`<span class="monitor-sub">worker · ${t.worker_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.reason??t.summary??"이유가 기록되지 않았습니다."}</div>
        </div>
        <span class="monitor-pill ${fn(t.outcome==="failed"?"bad":t.outcome==="skipped"?"warn":"ok")}">${dh(t.outcome)}</span>
      </div>
      <div class="monitor-meta">
        <span>trigger · ${t.trigger??"unknown"}</span>
        ${t.checked_at?o`<span><${X} timestamp=${t.checked_at} /></span>`:null}
        <span>action · ${uh(t.action_kind)}</span>
        <span>allow ${t.allowed_tool_names.length}</span>
        <span>used ${t.used_tool_names.length}</span>
      </div>
      ${t.summary&&t.summary!==t.reason?o`<div class="monitor-focus">${t.summary}</div>`:null}
      <div class="monitor-footnote">
        허용 도구: ${wa(t.allowed_tool_names)} · 사용 도구: ${wa(t.used_tool_names)}
      </div>
      ${t.failure_reason||t.decision_reason?o`<div class="monitor-footnote">
            ${t.failure_reason?`실패 이유: ${t.failure_reason}`:`판단 이유: ${t.decision_reason}`}
          </div>`:null}
    </button>
  `}function tl({row:t,testId:e}){return o`
    <button class="monitor-row ${t.tone} state-${t.state}" data-testid=${e} onClick=${()=>_s(t.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.name}</span>
            ${t.korean_name?o`<span class="monitor-sub">${t.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${he} status=${t.status??"unknown"} />
        <span class="monitor-pill ${t.tone} state-${t.state}">${lh(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.last_signal_at?o`<span>신호 <${X} timestamp=${t.last_signal_at} /></span>`:o`<span>최근 신호 없음</span>`}
        <span>${(t.active_task_count??0)>0?`활성 작업 ${t.active_task_count}개`:"활성 작업 없음"}</span>
        ${t.related_session_id?o`<span>세션 · ${t.related_session_id}</span>`:null}
        ${t.related_operation_id?o`<span>작전 · ${t.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${t.recent_output_preview&&t.recent_output_preview!==t.focus?o`<div class="monitor-footnote">최근 상세: ${t.recent_output_preview}</div>`:null}
    </button>
  `}function gh({row:t}){var n,s;const e=()=>{const a=rh(t.name);a&&Hc(a)};return o`
    <button class="monitor-row ${t.tone} state-${t.state}" data-testid="execution.continuity-card" onClick=${e}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.name}</span>
            ${t.korean_name?o`<span class="monitor-sub">${t.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${ah} ratio=${t.context_ratio??0} size=${34} stroke=${4} />
        <${he} status=${t.status??"unknown"} />
        <span class="monitor-pill ${t.tone}">${ch(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.last_signal_at?o`<span>최근 활동 <${X} timestamp=${t.last_signal_at} /></span>`:o`<span>최근 활동 없음</span>`}
        ${t.related_session_id?o`<span>세션 · ${t.related_session_id}</span>`:null}
        ${t.continuity?o`<span>${t.continuity}</span>`:null}
        ${t.lifecycle?o`<span>생애주기 ${t.lifecycle}</span>`:null}
        <span>컨텍스트 ${ih(t.context_ratio)}</span>
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${t.recent_output_preview||t.continuity_summary?o`<div class="monitor-footnote">${t.recent_output_preview??t.continuity_summary}</div>`:null}
      ${t.skill_route_summary||t.tool_audit_source?o`<div class="monitor-footnote">
            ${t.skill_route_summary?`route · ${t.skill_route_summary}`:""}
            ${t.tool_audit_source?`${t.skill_route_summary?" · ":""}audit · ${t.tool_audit_source}`:""}
            ${t.tool_audit_at?o` · <${X} timestamp=${t.tool_audit_at} />`:null}
          </div>`:null}
      ${(((n=t.recent_tool_names)==null?void 0:n.length)??0)>0||(((s=t.allowed_tool_names)==null?void 0:s.length)??0)>0?o`<div class="monitor-footnote">
            recent tools: ${wa(t.recent_tool_names)} · allowed: ${wa(t.allowed_tool_names)}
          </div>`:null}
    </button>
  `}function $h(){const t=Ll.value,e=Pl.value,n=Nl.value,s=jl.value,a=El.value,i=Ol.value,l=Ii.value,c=zi.value,p=Dl.value;Ae.value&&!e.some($=>$.id===Ae.value)&&(Ae.value=null),Ht.value&&!n.some($=>$.session_id===Ht.value)&&(Ht.value=null),Wt.value&&!s.some($=>$.operation_id===Wt.value)&&(Wt.value=null);const _=Ae.value?e.find($=>$.id===Ae.value)??null:null,u=Ht.value?Ht.value:_?_.kind==="session"?_.target_id:_.linked_session_id??null:null,f=Wt.value?Wt.value:_?_.kind==="operation"?_.target_id:_.linked_operation_id??null:null,v=u?n.filter($=>$.session_id===u):f?n.filter($=>$.linked_operation_id===f):n,h=f?s.filter($=>$.operation_id===f):u?s.filter($=>{var R;return $.linked_session_id===u||$.operation_id===((R=v[0])==null?void 0:R.linked_operation_id)}):s,A=u||f?a.filter($=>(u?$.related_session_id===u:!1)||(f?$.related_operation_id===f:!1)):a,k=u?c.filter($=>$.related_session_id===u||$.tone!=="ok"):c,S=u?l.filter($=>v.some(R=>R.member_names.includes($.agent_name))):l,b=u||f?p.filter($=>(u?$.related_session_id===u:!1)||(f?$.related_operation_id===f:!1)||$.tone!=="ok"):p;return o`
    <div class="agents-monitor">
      <${St} surfaceId="execution" />
      <${Za} />
      <div class="stats-grid">
        <${Rt} label="활성 세션" value=${(t==null?void 0:t.active_sessions)??n.length} color="#4ade80" caption="실행 관점 세션 수" />
        <${Rt} label="막힌 세션" value=${(t==null?void 0:t.blocked_sessions)??n.filter($=>fn($.health??$.status)!=="ok").length} color="#fbbf24" caption="개입이 필요한 세션 수" />
        <${Rt} label="활성 작전" value=${(t==null?void 0:t.active_operations)??s.length} color="#22d3ee" caption="지휘 평면 작전 수" />
        <${Rt} label="막힌 작전" value=${(t==null?void 0:t.blocked_operations)??s.filter($=>$.blocker_summary).length} color="#fb7185" caption="원인 확인이 필요한 작전 수" />
        <${Rt} label="인력 경고" value=${(t==null?void 0:t.worker_alerts)??a.filter($=>$.tone!=="ok").length} color="#fb7185" caption="지원 인력 압박" />
        <${Rt} label="연속성 경고" value=${(t==null?void 0:t.continuity_alerts)??c.filter($=>$.tone!=="ok").length} color="#fb7185" caption="키퍼 연속성 압박" />
      </div>

      <${I}
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
          ${e.length===0?o`<div class="empty-state">지금은 막힌 실행이 없습니다.</div>`:e.map($=>o`<${ph} key=${$.id} item=${$} selected=${Ae.value===$.id} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${I}
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
            ${v.length===0?o`<div class="empty-state">선택된 실행과 연결된 세션이 없습니다.</div>`:v.map($=>o`<${mh} key=${$.session_id} brief=${$} selected=${Ht.value===$.session_id} />`)}
          </div>
        <//>

        <${I}
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
            ${h.length===0?o`<div class="empty-state">선택된 실행과 연결된 작전이 없습니다.</div>`:h.map($=>o`<${_h} key=${$.operation_id} brief=${$} selected=${Wt.value===$.operation_id} />`)}
          </div>
        <//>

        <${I}
          title="Lodge Check-ins"
          class="section"
          semanticId="execution.lodge"
          testId="execution.lodge-checkins"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Lodge Check-ins</h2>
            <p class="monitor-subheadline">최근 lodge tick에서 누가 무엇을 허용받았고, 실제로 어떻게 행동했는지 먼저 보여줍니다.</p>
          </div>
          <${vh} tick=${i} />
          <div class="monitor-list">
            ${S.length===0?o`<div class="empty-state">최근 lodge check-in 기록이 없습니다.</div>`:S.map($=>o`<${fh} key=${`${$.agent_name}-${$.checked_at??$.outcome}`} row=${$} />`)}
          </div>
        <//>

        <${I}
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
            ${A.length===0?o`<div class="empty-state">연결된 작업자가 없습니다.</div>`:A.map($=>o`<${tl} key=${$.name} row=${$} testId="execution.worker-card" />`)}
          </div>
        <//>

        <${I}
          title="연속성"
          class="section"
          semanticId="execution.continuity"
          testId="execution.continuity"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">연속성 보조 면</h2>
            <p class="monitor-subheadline">키퍼 연속성은 보조 면으로만 두고, 상태가 좋지 않은 키퍼 위주로 보여줍니다.</p>
          </div>
          <div class="monitor-list">
            ${k.length===0?o`<div class="empty-state">지금은 연속성 경고가 없습니다.</div>`:k.map($=>o`<${gh} key=${$.name} row=${$} />`)}
          </div>
        <//>

        <${I}
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
            ${b.length===0?o`<div class="empty-state">지금은 오프라인 작업자가 없습니다.</div>`:b.map($=>o`<${tl} key=${$.name} row=${$} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const pi=g(null),mi=g(null),On=g(!1);async function el(){if(!On.value){On.value=!0,mi.value=null;try{pi.value=await gu()}catch(t){mi.value=t instanceof Error?t.message:String(t)}finally{On.value=!1}}}function hh(t){switch(t){case"essential":return"badge-essential";case"standard":return"badge-standard";default:return"badge-full"}}function yh({items:t,maxCount:e}){return t.length===0?o`<p class="muted">No tool calls recorded yet.</p>`:o`
    <div class="tool-bar-chart">
      ${t.map(n=>{const s=e>0?n.call_count/e*100:0;return o`
          <div class="tool-bar-row" key=${n.name}>
            <span class="tool-bar-name">${n.name}</span>
            <span class="tool-bar-tier ${hh(n.tier)}">${n.tier}</span>
            <div class="tool-bar-track">
              <div class="tool-bar-fill" style=${{width:`${s}%`}} />
            </div>
            <span class="tool-bar-count">${n.call_count}</span>
          </div>
        `})}
    </div>
  `}function bh({dist:t}){const e=t.full,n=e>0?(t.essential/e*100).toFixed(1):"0",s=e>0?(t.standard/e*100).toFixed(1):"0",a=e-t.standard,i=e>0?(a/e*100).toFixed(1):"0";return o`
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
  `}function kh(){const t=pi.value,e=On.value,n=mi.value;return ot(()=>{!pi.value&&!On.value&&el()},[]),o`
    <div class="tool-metrics">
      <div class="tool-metrics-header">
        <h3 class="tool-metrics-title">Tool Usage</h3>
        <button
          class="control-btn ghost"
          onClick=${()=>void el()}
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
            <${bh} dist=${t.tier_distribution} />
          </div>
          <div class="tool-metrics-section">
            <h4>Top 20 Tools</h4>
            <${yh}
              items=${t.top_20}
              maxCount=${t.top_20.length>0?t.top_20[0].call_count:0}
            />
          </div>
        </div>
      `:e?null:o`
        <p class="muted">Click Load to fetch tool usage statistics.</p>
      `}
    </div>
  `}const _i=g(null),vi=g(null),Dn=g(!1),Cn=g(""),js=g("all"),yo=g(!1),bo=g(!1),ko=g(!0),xo=g(!0);async function nl(){if(!Dn.value){Dn.value=!0,vi.value=null;try{_i.value=await $u()}catch(t){vi.value=t instanceof Error?t.message:String(t)}finally{Dn.value=!1}}}function xh(t,e){const n=e.trim().toLowerCase();return n?[t.name,t.description,t.category,t.required_permission??"",t.visibility,t.lifecycle,t.implementationStatus,t.tier,t.canonicalName??"",t.replacement??"",t.reason??"",...t.doc_refs,...t.prompt_hints].join(" ").toLowerCase().includes(n):!0}function Es(t,e="default"){return o`
    <span
      style=${{fontSize:"11px",color:e==="ok"?"#7dd3fc":e==="warn"?"#fbbf24":"#cbd5e1",background:e==="ok"?"rgba(14, 165, 233, 0.18)":e==="warn"?"rgba(245, 158, 11, 0.18)":"rgba(148, 163, 184, 0.16)",borderRadius:"999px",padding:"2px 8px"}}
    >
      ${t}
    </span>
  `}function Sh({item:t}){return o`
    <article class="tool-inventory-row">
      <div class="tool-inventory-head">
        <div>
          <div class="tool-inventory-name">${t.name}</div>
          <div class="tool-inventory-desc">${t.description}</div>
        </div>
        <div class="tool-inventory-badges">
          ${Es(t.tier,t.tier==="essential"?"ok":t.tier==="standard"?"warn":"default")}
          ${Es(t.visibility)}
          ${Es(t.lifecycle,t.lifecycle==="deprecated"?"warn":"default")}
          ${Es(t.implementationStatus)}
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
  `}function Ch(){const t=_i.value,e=Dn.value,n=vi.value,s=(t==null?void 0:t.tool_inventory.tools)??[],a=(t==null?void 0:t.tool_usage)??null;ot(()=>{!_i.value&&!Dn.value&&nl()},[]),ot(()=>{var h;if(F.value.tab!=="tools")return;const v=(h=F.value.params.q)==null?void 0:h.trim();v&&v!==Cn.value&&(Cn.value=v)},[F.value.tab,F.value.params.q]);const i=Array.from(new Set(s.map(v=>v.category))).sort((v,h)=>v.localeCompare(h)),l=s.filter(v=>!(!xh(v,Cn.value)||js.value!=="all"&&v.category!==js.value||yo.value&&!v.enabled_in_current_mode||bo.value&&!v.direct_call_allowed||!ko.value&&v.visibility==="hidden"||!xo.value&&v.lifecycle==="deprecated")),c=s.length,p=s.filter(v=>v.enabled_in_current_mode).length,_=s.filter(v=>v.visibility==="hidden").length,u=s.filter(v=>v.lifecycle==="deprecated").length,f=s.filter(v=>v.direct_call_allowed).length;return o`
    <div>
      <${I} title="System Tool Inventory" class="section">
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
            <span class="stat-value">${_}</span>
            <span class="stat-label">Hidden</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${u}</span>
            <span class="stat-label">Deprecated</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${f}</span>
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
            value=${Cn.value}
            onInput=${v=>{Cn.value=v.target.value}}
          />
          <select
            class="control-select"
            value=${js.value}
            onChange=${v=>{js.value=v.target.value}}
          >
            <option value="all">All categories</option>
            ${i.map(v=>o`<option value=${v}>${v}</option>`)}
          </select>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${yo.value}
              onChange=${v=>{yo.value=v.target.checked}}
            />
            <span>Enabled only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${bo.value}
              onChange=${v=>{bo.value=v.target.checked}}
            />
            <span>Direct-call only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${ko.value}
              onChange=${v=>{ko.value=v.target.checked}}
            />
            <span>Show hidden</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${xo.value}
              onChange=${v=>{xo.value=v.target.checked}}
            />
            <span>Show deprecated</span>
          </label>
          <button class="control-btn ghost" onClick=${()=>{nl()}} disabled=${e}>
            ${e?"Refreshing…":"Refresh inventory"}
          </button>
        </div>

        ${n?o`<div class="tool-metrics-error">${n}</div>`:null}

        <div class="tool-inventory-list">
          ${l.length>0?l.map(v=>o`<${Sh} key=${v.name} item=${v} />`):o`<div class="empty-state">No tools matched the current filters.</div>`}
        </div>
      <//>

      <${I} title="Tool Usage" class="section">
        ${a?o`
              <div class="tool-inventory-usage-hint">
                Registered ${a.registered_count} · Distinct called ${a.distinct_tools_called} · Never called ${a.never_called_count}
              </div>
            `:null}
        <${kh} />
      <//>
    </div>
  `}const qa=g("all"),Fa=g("all"),fi=g(new Set);function Ah(t){const e=new Set(fi.value);e.has(t)?e.delete(t):e.add(t),fi.value=e}const gd=Mt(()=>{let t=Ze.value;return qa.value!=="all"&&(t=t.filter(e=>e.horizon===qa.value)),Fa.value!=="all"&&(t=t.filter(e=>e.status===Fa.value)),t}),Th=Mt(()=>{const t={short:[],mid:[],long:[]};for(const e of gd.value){const n=t[e.horizon];n&&n.push(e)}return t}),Ih=Mt(()=>{const t=Array.from(ql.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:e.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&e.status!=="interrupted"?1:n.elapsed_seconds-e.elapsed_seconds),t});function zh(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function rr(t){switch(t){case"short":return"단기";case"mid":return"중기";case"long":return"장기";default:return t}}function sa(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Rh(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function sl(t){return t.toFixed(4)}function al(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function Mh(t){switch(t){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function Lh(t){switch(t){case"active":return"진행 중";case"completed":return"완료";case"paused":return"일시정지";default:return"전체"}}function ol(t,e){return(t.priority??4)-(e.priority??4)}function Ph(t,e){const n=t.updated_at??t.created_at??"";return(e.updated_at??e.created_at??"").localeCompare(n)}function Nh(t,e){return t.length<=e?t:t.slice(0,e)+"..."}function jh({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${sa(t.horizon)}">
            ${rr(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${zh(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${X} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${he} status=${t.status} />
        <div class="goal-updated">
          <${X} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function So({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${I} title="${rr(t)} 목표 (${e.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>o`<${jh} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function Eh(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">범위</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${qa.value===t?"active":""}"
            onClick=${()=>{qa.value=t}}
          >
            ${t==="all"?"전체":rr(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">상태</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Fa.value===t?"active":""}"
            onClick=${()=>{Fa.value=t}}
          >
            ${Lh(t)}
          </button>
        `)}
      </div>
    </div>
  `}function Oh(){const t=Ze.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
  `}function Dh({loop:t}){const e=t.history[0],n=t.latest_tool_names&&t.latest_tool_names.length>0?`${t.latest_tool_call_count??t.latest_tool_names.length}개 도구: ${t.latest_tool_names.join(", ")}`:"아직 근거 없음";return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${he} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${sl(t.baseline_metric)}</span>
          <span>현재 ${sl(t.current_metric)}</span>
          <span class=${al(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${al(t)}
          </span>
          <span>Elapsed ${Rh(t.elapsed_seconds)}</span>
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
  `}function Co({task:t}){const e=t.priority??4,n=e<=1?"p1":e===2?"p2":e===3?"p3":"p4",s=fi.value.has(t.id),a=!!t.description;return o`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${Mh(e)}</span>
        <div class="kanban-card-title">${t.title}</div>
      </div>
      ${a?o`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>Ah(t.id)}
        >
          ${s?t.description:Nh(t.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${t.created_at?o`<${X} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function wh(){const{todo:t,inProgress:e,done:n}=Kl.value,s=[...t].sort(ol),a=[...e].sort(ol),i=[...n].sort(Ph);return o`
    <${I} title="태스크 백로그" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>할 일</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${s.length===0?o`<div class="empty-state" style="opacity: 0.5;">대기 중인 태스크가 없습니다</div>`:s.map(l=>o`<${Co} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>진행 중</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${a.length===0?o`<div class="empty-state" style="opacity: 0.5;">진행 중인 태스크가 없습니다</div>`:a.map(l=>o`<${Co} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>완료</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${i.length===0?o`<div class="empty-state" style="opacity: 0.5;">완료된 태스크가 없습니다</div>`:i.slice(0,20).map(l=>o`<${Co} key=${l.id} task=${l} />`)}
          ${i.length>20?o`<div class="empty-state" style="opacity: 0.5;">...외 ${i.length-20}개 더 있음</div>`:null}
        </div>
      </div>
    <//>
  `}function qh(){const{todo:t,inProgress:e,done:n}=Kl.value,s=t.length+e.length+n.length,a=[...t,...e].filter(u=>(u.priority??4)<=2).length,i=Th.value,l=Ih.value,c=Ze.value.length>0,p=l.length>0,_=Ri.value;return o`
    <div>
      <${St} surfaceId="planning" />

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
          onClick=${()=>{Pi(),Jl()}}
          disabled=${Rn.value||Mn.value}
        >
          ${Rn.value||Mn.value?"새로고침 중...":"계획 데이터 새로고침"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${wh} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          목표 파이프라인
          <span class="monitor-pill">${Ze.value.length}</span>
        </summary>
        <div>
          ${c?o`
            <${Oh} />
            <${Eh} />
            ${Rn.value&&Ze.value.length===0?o`<div class="loading-indicator">목표 불러오는 중...</div>`:gd.value.length===0?o`<div class="empty-state">현재 필터에 맞는 목표가 없습니다</div>`:o`
                    <${So} horizon="short" items=${i.short??[]} />
                    <${So} horizon="mid" items=${i.mid??[]} />
                    <${So} horizon="long" items=${i.long??[]} />
                  `}
          `:o`
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
          ${Mn.value&&l.length===0?o`<div class="loading-indicator">MDAL 루프 불러오는 중...</div>`:l.length===0&&(_==="error"||tn.value)?o`<div class="empty-state">MDAL 스냅샷을 불러오지 못했습니다${tn.value?`: ${tn.value}`:""}. 백엔드 상태를 확인하세요.</div>`:l.length===0?o`<div class="empty-state">가동 중인 루프가 없습니다. <code>masc_mdal_start</code>로 시작할 수 있습니다.</div>`:o`
                  <div class="planning-loop-list">
                    ${l.map(u=>o`<${Dh} key=${u.loop_id} loop=${u} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const Ka=g(!1),wn=g(!1),Xe=g(!1),ve=g(""),qn=g(""),gi=g("open"),Dt=g(null),as=g(null),Ba=g(null),Ua=g(null),$i=g(!1);function os(t){return`${t.kind}:${t.id}`}function lr(){var n;const t=as.value,e=((n=Dt.value)==null?void 0:n.items)??[];return t?e.find(s=>os(s)===t)??null:null}function Fh(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name");return(e==null?void 0:e.trim())||"dashboard"}function Kh(t){const e=t.trim().toLowerCase();return e==="open"||e==="pending"}function $d(t){return!!(t.judgment_summary&&t.judgment_summary.trim())}function hd(t){switch(gi.value){case"needs_quorum":return t.filter(e=>e.kind==="consensus"&&(e.votes??0)<(e.quorum??0));case"ready":return t.filter(e=>{var n;return(n=e.guardrail_state)==null?void 0:n.ready_to_execute});case"needs_approval":return t.filter(e=>{var n,s;return((n=e.guardrail_state)==null?void 0:n.requires_human_gate)||!!((s=e.guardrail_state)!=null&&s.pending_confirm)});case"judge_offline":return t.filter(e=>!$d(e));case"open":default:return t.filter(e=>Kh(e.status))}}function Bh(t){if(t==null)return"없음";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function so(t){const e=(t||"").toLowerCase();return e.includes("reject")||e.includes("deny")||e.includes("closed")||e.includes("cancel")?"negative":e.includes("approve")||e.includes("support")||e.includes("open")||e.includes("ready")?"positive":"neutral"}function Uh(t){return typeof t!="number"||Number.isNaN(t)?"확인 필요":`${Math.round(t*100)}%`}function An(t){return"resolved_tool"in t||"payload_preview"in t||"reason"in t}async function yd(t){if(Ba.value=null,Ua.value=null,!!t){$i.value=!0,ve.value="";try{t.kind==="debate"?Ba.value=await dp(t.id):Ua.value=await up(t.id)}catch(e){ve.value=e instanceof Error?e.message:"거버넌스 상세를 불러오지 못했습니다"}finally{$i.value=!1}}}async function Hh(t){as.value=os(t),await yd(t)}async function gn(){var t;Ka.value=!0,ve.value="";try{const e=await du();Dt.value=e;const n=hd(e.items??[]),s=as.value,a=n.find(i=>os(i)===s)??n[0]??((t=e.items)==null?void 0:t[0])??null;as.value=a?os(a):null,await yd(a)}catch(e){ve.value=e instanceof Error?e.message:"거버넌스 상태를 불러오지 못했습니다"}finally{Ka.value=!1}}Am(gn);async function il(){const t=qn.value.trim();if(t){wn.value=!0;try{const e=await cp(t);qn.value="",O(e!=null&&e.id?`토론을 시작했습니다: ${e.id}`:"토론을 시작했습니다","success"),await gn()}catch(e){const n=e instanceof Error?e.message:"토론 시작에 실패했습니다";ve.value=n,O(n,"error")}finally{wn.value=!1}}}async function rl(t){var i,l;const e=lr(),n=(i=e==null?void 0:e.guardrail_state)==null?void 0:i.pending_confirm,s=n==null?void 0:n.confirm_token;if(!s)return;const a=((l=n==null?void 0:n.actor)==null?void 0:l.trim())||Fh();Xe.value=!0;try{await xl(a,s,t),O(t==="confirm"?"액션을 승인했습니다":"액션을 거부했습니다","success"),await gn()}catch(c){const p=c instanceof Error?c.message:"대기 중인 액션 처리에 실패했습니다";ve.value=p,O(p,"error")}finally{Xe.value=!1}}function Wh(){var n,s,a,i,l,c;const t=(n=Dt.value)==null?void 0:n.summary,e=(s=Dt.value)==null?void 0:s.judge;return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">열린 토론</span>
        <strong>${(t==null?void 0:t.debates_open)??((i=(a=Dt.value)==null?void 0:a.debates)==null?void 0:i.length)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">합의 세션</span>
        <strong>${(t==null?void 0:t.sessions_active)??((c=(l=Dt.value)==null?void 0:l.sessions)==null?void 0:c.length)??0}</strong>
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
  `}function Gh(){return o`
    <${I} title="거버넌스 콘솔" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="토론 주제를 입력하세요..."
            value=${qn.value}
            onInput=${t=>{qn.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&il()}}
            disabled=${wn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${il}
            disabled=${wn.value||qn.value.trim()===""}
          >
            ${wn.value?"시작 중...":"토론 시작"}
          </button>
          <button class="control-btn ghost" onClick=${gn} disabled=${Ka.value}>
            ${Ka.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
        <div class="governance-filter-row">
          ${[["open","열림"],["needs_quorum","정족수 부족"],["ready","준비됨"],["needs_approval","승인 필요"],["judge_offline","판정기 오프라인"]].map(([t,e])=>o`
            <button
              class="control-btn ${gi.value===t?"is-active":"ghost"}"
              onClick=${async()=>{gi.value=t,await gn()}}
            >
              ${e}
            </button>
          `)}
        </div>
        ${ve.value?o`<div class="council-error">${ve.value}</div>`:null}
      </div>
    <//>
  `}function Jh(){var e;const t=hd(((e=Dt.value)==null?void 0:e.items)??[]);return o`
    <${I} title="의사결정 수신함" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${t.length===0?o`
              <div class="empty-state">
                지금 필터에 맞는 토론이나 합의 세션이 없습니다.
              </div>
            `:t.map(n=>{var a,i;const s=as.value===os(n);return o`
                <button
                  class="council-row governance-decision-row ${s?"selected":""}"
                  onClick=${()=>Hh(n)}
                >
                  <div class="council-row-main">
                    <div class="governance-row-head">
                      <span class="governance-kind">${n.kind}</span>
                      <span class="council-topic">${n.topic}</span>
                    </div>
                    <div class="council-sub">
                      <span>${n.truth_summary||"사실 요약이 아직 없습니다"}</span>
                      ${n.last_activity_at?o`<span><${X} timestamp=${n.last_activity_at} /></span>`:null}
                    </div>
                    <div class="governance-chip-row">
                      ${(a=n.guardrail_state)!=null&&a.requires_human_gate?o`<span class="governance-chip warn">승인 필요</span>`:null}
                      ${(i=n.guardrail_state)!=null&&i.ready_to_execute?o`<span class="governance-chip ok">준비됨</span>`:null}
                      ${n.kind==="consensus"&&(n.votes??0)<(n.quorum??0)?o`<span class="governance-chip warn">정족수 부족</span>`:null}
                      ${$d(n)?null:o`<span class="governance-chip dim">판정기 오프라인</span>`}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${so(n.status)}">${n.status}</span>
                    ${n.kind==="consensus"?o`<span class="governance-vote-meter">${n.votes??0}/${n.quorum??0}</span>`:o`<span class="governance-vote-meter">${n.evidence_refs.length} refs</span>`}
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function Yh({argument:t}){return o`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${so(t.position)}">${t.position}</span>
        <strong>${t.agent}</strong>
        ${t.created_at?o`<span><${X} timestamp=${t.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${t.content}</div>
      <div class="governance-chip-row">
        ${t.evidence.map(e=>o`<span class="governance-chip">${e}</span>`)}
        ${t.reply_to!=null?o`<span class="governance-chip">답글 #${t.reply_to}</span>`:null}
        ${t.mentions.map(e=>o`<span class="governance-chip">@${e}</span>`)}
        ${t.archetype?o`<span class="governance-chip dim">${t.archetype}</span>`:null}
      </div>
    </div>
  `}function Vh({vote:t}){return o`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${so(t.decision)}">${t.decision}</span>
        <strong>${t.agent}</strong>
        ${t.timestamp?o`<span><${X} timestamp=${t.timestamp} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${t.reason||"기록된 이유가 없습니다."}</div>
      <div class="governance-chip-row">
        ${t.weight!=null?o`<span class="governance-chip">가중치 ${t.weight}</span>`:null}
        ${t.archetype?o`<span class="governance-chip dim">${t.archetype}</span>`:null}
      </div>
    </div>
  `}function Xh(){const t=lr(),e=Ba.value,n=Ua.value;return o`
    <${I}
      title=${t?`${t.kind==="debate"?"토론":"합의"} 상세`:"의사결정 상세"}
      class="section"
      semanticId="governance.detail"
    >
      ${$i.value?o`<div class="loading-indicator">거버넌스 상세 불러오는 중...</div>`:t?t.kind==="debate"&&e?o`
                <div class="governance-detail-head">
                  <div>
                    <h3>${e.debate.topic}</h3>
                    <div class="council-sub">
                      <span>${e.debate.id}</span>
                      <span>${e.debate.status}</span>
                      ${e.debate.created_at?o`<span><${X} timestamp=${e.debate.created_at} /></span>`:null}
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
                  ${e.arguments.length===0?o`<div class="empty-state">기록된 토론이 아직 없습니다.</div>`:e.arguments.map(s=>o`<${Yh} key=${s.index} argument=${s} />`)}
                </div>
              `:t.kind==="consensus"&&n?o`
                  <div class="governance-detail-head">
                    <div>
                      <h3>${n.session.topic}</h3>
                      <div class="council-sub">
                        <span>${n.session.id}</span>
                        <span>${n.session.state}</span>
                      <span>시작자 ${n.session.initiator}</span>
                        ${n.session.created_at?o`<span><${X} timestamp=${n.session.created_at} /></span>`:null}
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
                    ${n.votes.length===0?o`<div class="empty-state">기록된 표결이 아직 없습니다.</div>`:n.votes.map(s=>o`<${Vh} key=${s.agent+s.timestamp} vote=${s} />`)}
                  </div>
                `:o`<div class="empty-state">이 의사결정의 상세를 아직 읽을 수 없습니다.</div>`:o`<div class="empty-state">사실 계층과 판단을 보려면 의사결정 항목을 고르세요.</div>`}
    <//>
  `}function ll({title:t,route:e}){if(!e)return null;const n=An(e)?e.resolved_tool:e.delegated_tool,s=An(e)?e.target_type:null,a=An(e)?e.target_id:null,i=An(e)?e.reason:null,l=An(e)?e.payload_preview:null;return o`
    <div class="governance-side-block">
      <h4>${t}</h4>
      <div class="council-sub">
        ${n?o`<span>도구 ${n}</span>`:null}
        ${"action_type"in e&&e.action_type?o`<span>액션 ${e.action_type}</span>`:null}
        ${"confirmation_state"in e&&e.confirmation_state?o`<span>${e.confirmation_state}</span>`:null}
        ${"created_at"in e&&e.created_at?o`<span><${X} timestamp=${e.created_at} /></span>`:null}
      </div>
      ${s?o`<div class="governance-side-line">대상 ${s}${a?`:${a}`:""}</div>`:null}
      ${i?o`<div class="governance-side-line">${i}</div>`:null}
      ${l?o`<pre class="council-detail governance-preview">${Bh(l)}</pre>`:null}
    </div>
  `}function Qh(){var c,p,_;const t=lr(),e=Ba.value,n=Ua.value,s=(e==null?void 0:e.context)??(n==null?void 0:n.context)??(t==null?void 0:t.context),a=(e==null?void 0:e.judgment)??(n==null?void 0:n.judgment),i=t==null?void 0:t.guardrail_state,l=(c=Dt.value)==null?void 0:c.judge;return o`
    <div class="governance-side-column">
      <${I} title="이유 / 가드레일" class="section" semanticId="governance.guardrail">
        ${t?o`
              <div class="governance-side-block">
                <h4>판정기</h4>
                <div class="council-sub">
                  <span>${l!=null&&l.judge_online?"온라인":"오프라인"}</span>
                  ${l!=null&&l.model_used?o`<span>${l.model_used}</span>`:null}
                  ${l!=null&&l.generated_at?o`<span><${X} timestamp=${l.generated_at} /></span>`:null}
                </div>
                ${t.judgment_summary?o`<div class="governance-summary-callout">${t.judgment_summary}</div>`:o`<div class="governance-side-line">현재 LLM 판단이 없어 사실 계층만 보여줍니다.</div>`}
                <div class="council-sub">
                  <span>신뢰도 ${Uh(t.confidence)}</span>
                  ${a!=null&&a.keeper_name?o`<span>${a.keeper_name}</span>`:null}
                </div>
              </div>

              <${ll} title="추천 경로" route=${t.recommended_action} />
              <${ll} title="실행된 경로" route=${t.executed_route} />

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
                          onClick=${()=>rl("confirm")}
                          disabled=${Xe.value}
                        >
                          ${Xe.value?"처리 중...":"승인"}
                        </button>
                        <button
                          class="control-btn ghost"
                          onClick=${()=>rl("deny")}
                          disabled=${Xe.value}
                        >
                          ${Xe.value?"처리 중...":"거부"}
                        </button>
                      </div>
                    `:o`<div class="governance-side-line">이 의사결정에 대기 중인 사람 승인은 없습니다.</div>`}
              </div>
            `:o`<div class="empty-state">판단과 경로를 보려면 의사결정을 고르세요.</div>`}
      <//>

      <${I} title="맥락" class="section" semanticId="governance.context">
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
                        ${t.related_agents.map(u=>o`<span class="governance-chip dim">${u}</span>`)}
                      </div>
                    `:o`<div class="governance-side-line">명시적으로 연결된 맥락 기록이 없습니다.</div>`}
                ${t.evidence_refs.length>0?o`
                      <div class="governance-side-line">근거 참조</div>
                      <div class="governance-chip-row">
                        ${t.evidence_refs.map(u=>o`<span class="governance-chip">${u}</span>`)}
                      </div>
                    `:null}
              </div>
          `:o`<div class="empty-state">선택된 맥락이 없습니다.</div>`}
      <//>

      <${I} title="최근 활동" class="section" semanticId="governance.activity">
        <div class="governance-activity-list">
          ${(((p=Dt.value)==null?void 0:p.activity)??[]).slice(0,8).map(u=>o`
            <div class="governance-activity-row">
              <div class="governance-ledger-head">
                <span class="governance-badge ${so(u.kind)}">${u.kind}</span>
                ${u.actor?o`<strong>${u.actor}</strong>`:null}
                ${u.created_at?o`<span><${X} timestamp=${u.created_at} /></span>`:null}
              </div>
              <div class="governance-ledger-body">${u.summary||u.topic||"활동이 기록되었습니다."}</div>
            </div>
          `)}
          ${(((_=Dt.value)==null?void 0:_.activity)??[]).length===0?o`<div class="empty-state">기록된 거버넌스 활동이 없습니다.</div>`:null}
        </div>
      <//>
    </div>
  `}function Zh(){return ot(()=>{gn()},[]),o`
    <div>
      <${St} surfaceId="governance" />
      <${Wh} />
      <${Gh} />
      <div class="governance-layout">
        <${Jh} />
        <${Xh} />
        <${Qh} />
      </div>
    </div>
  `}const Be=g(""),Ao=g("ability_check"),To=g("10"),Io=g("12"),Os=g(""),Ds=g("idle"),ne=g(""),ws=g("keeper-late"),zo=g("player"),Ro=g(""),At=g("idle"),Mo=g(null),qs=g(""),Lo=g(""),Po=g("player"),No=g(""),jo=g(""),Eo=g(""),Fn=g("20"),Oo=g("20"),Do=g(""),Fs=g("idle"),hi=g(null),bd=g("overview"),wo=g("all"),qo=g("all"),Fo=g("all"),ty=12e4,ao=g(null),cl=g(Date.now());function ey(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function ny(t,e){return e>0?Math.round(t/e*100):0}const sy={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},ay={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Ks(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function oy(t){const e=t.trim().toLowerCase();return sy[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function iy(t){const e=t.trim().toLowerCase();return ay[e]??"상황에 따라 선택되는 전술 액션입니다."}function bt(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function jt(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function is(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const ry=new Set(["str","dex","con","int","wis","cha"]);function ly(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!m(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const l=a.trim();if(l){if(typeof i=="number"&&Number.isFinite(i)){s[l]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const c=Number.parseFloat(i.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function cy(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),s=Number.parseInt(Fn.value.trim(),10);Number.isFinite(s)&&s>n&&(Fn.value=String(n))}function yi(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function dy(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function uy(t){bd.value=t}function kd(t){const e=ao.value;return e==null||e<=t}function py(t){const e=ao.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Ha(){ao.value=null}function xd(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function my(t,e){xd(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(ao.value=Date.now()+ty,O("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function aa(t){return kd(t)?(O("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function bi(t,e,n){return xd([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function _y({hp:t,max:e}){const n=ny(t,e),s=ey(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function vy({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function fy({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Sd({actor:t}){var p,_,u,f;const e=(p=t.archetype)==null?void 0:p.trim(),n=(_=t.persona)==null?void 0:_.trim(),s=(u=t.portrait)==null?void 0:u.trim(),a=(f=t.background)==null?void 0:f.trim(),i=t.traits??[],l=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([v,h])=>Number.isFinite(h)).filter(([v])=>!ry.has(v.toLowerCase()));return o`
    <div class="trpg-actor">
      ${s?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${v=>{const h=v.target;h&&(h.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${he} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${fy} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${_y} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${vy} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${Ks(e)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([v,h])=>o`
                <span class="trpg-custom-stat-chip">${Ks(v)} ${h}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(v=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Ks(v)}</span>
                  <span class="trpg-annot-desc">${oy(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${l.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${l.map(v=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Ks(v)}</span>
                  <span class="trpg-annot-desc">${iy(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function gy({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Cd({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${dy(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${yi(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${X} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function $y({events:t}){const e="__none__",n=wo.value,s=qo.value,a=Fo.value,i=Array.from(new Set(t.map(yi).map(f=>f.trim()).filter(f=>f!==""))).sort((f,v)=>f.localeCompare(v)),l=Array.from(new Set(t.map(f=>(f.type??"").trim()).filter(f=>f!==""))).sort((f,v)=>f.localeCompare(v)),c=t.some(f=>(f.type??"").trim()===""),p=Array.from(new Set(t.map(f=>(f.phase??"").trim()).filter(f=>f!==""))).sort((f,v)=>f.localeCompare(v)),_=t.some(f=>(f.phase??"").trim()===""),u=t.filter(f=>{if(n!=="all"&&yi(f)!==n)return!1;const v=(f.type??"").trim(),h=(f.phase??"").trim();if(s===e){if(v!=="")return!1}else if(s!=="all"&&v!==s)return!1;if(a===e){if(h!=="")return!1}else if(a!=="all"&&h!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${f=>{wo.value=f.target.value}}>
          <option value="all">all</option>
          ${i.map(f=>o`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${f=>{qo.value=f.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${e}>(none)</option>`:null}
          ${l.map(f=>o`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${f=>{Fo.value=f.target.value}}>
          <option value="all">all</option>
          ${_?o`<option value=${e}>(none)</option>`:null}
          ${p.map(f=>o`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{wo.value="all",qo.value="all",Fo.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${u.length} / 전체 ${t.length}
      </span>
    </div>
    <${Cd} events=${u.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function hy({outcome:t}){if(!t)return null;const e=i=>{const l=i.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function Ad({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function yy({state:t,nowMs:e}){var _;const n=Yt.value||((_=t.session)==null?void 0:_.room)||"",s=Ds.value,a=t.party??[];if(!a.find(u=>u.id===Be.value)&&a.length>0){const u=a[0];u&&(Be.value=u.id)}const l=async()=>{var f,v;if(!n){O("Room ID가 비어 있습니다.","error");return}if(!aa(e))return;const u=((f=t.current_round)==null?void 0:f.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(bi("라운드 실행",n,u)){Ds.value="running";try{const h=await Qu(n);hi.value=h,Ds.value="ok";const A=m(h.summary)?h.summary:null,k=A?is(A,"advanced",!1):!1,S=A?bt(A,"progress_reason",""):"";O(k?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${S?`: ${S}`:""}`,k?"success":"warning"),le()}catch(h){hi.value=null,Ds.value="error";const A=h instanceof Error?h.message:"라운드 실행에 실패했습니다.";O(A,"error")}finally{Ha()}}},c=async()=>{var f,v;if(!n||!aa(e))return;const u=((f=t.current_round)==null?void 0:f.phase)??((v=t.session)==null?void 0:v.status)??"unknown";if(bi("턴 강제 진행",n,u))try{await ep(n),O("턴을 다음 단계로 이동했습니다.","success"),le()}catch{O("턴 이동에 실패했습니다.","error")}finally{Ha()}},p=async()=>{if(!n||!aa(e))return;const u=Be.value.trim();if(!u){O("먼저 Actor를 선택하세요.","warning");return}const f=Number.parseInt(To.value,10),v=Number.parseInt(Io.value,10);if(Number.isNaN(f)||Number.isNaN(v)){O("stat/dc는 숫자여야 합니다.","warning");return}const h=Number.parseInt(Os.value,10),A=Os.value.trim()===""||Number.isNaN(h)?void 0:h;try{await tp({roomId:n,actorId:u,action:Ao.value.trim()||"ability_check",statValue:f,dc:v,rawD20:A}),O("주사위 판정을 기록했습니다.","success"),le()}catch{O("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${u=>{Yt.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Be.value}
            onChange=${u=>{Be.value=u.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(u=>o`<option value=${u.id}>${u.name} (${u.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${Ao.value}
              onInput=${u=>{Ao.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${To.value}
              onInput=${u=>{To.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Io.value}
              onInput=${u=>{Io.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Os.value}
              onInput=${u=>{Os.value=u.target.value}}
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

      ${s!=="idle"?o`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function by({state:t}){var a;const e=Yt.value||((a=t.session)==null?void 0:a.room)||"",n=Fs.value,s=async()=>{if(!e){O("Room ID가 비어 있습니다.","warning");return}const i=qs.value.trim(),l=Lo.value.trim();if(!l&&!i){O("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Fn.value.trim(),10),p=Number.parseInt(Oo.value.trim(),10),_=Number.isFinite(p)?Math.max(1,p):20,u=Number.isFinite(c)?Math.max(0,Math.min(_,c)):_;let f={};try{f=ly(Do.value)}catch(v){O(v instanceof Error?v.message:"능력치 JSON 오류","error");return}Fs.value="spawning";try{const v=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,h=await np(e,{actor_id:i||void 0,name:l||void 0,role:Po.value,idempotencyKey:v,portrait:jo.value.trim()||void 0,background:Eo.value.trim()||void 0,hp:u,max_hp:_,alive:u>0,stats:Object.keys(f).length>0?f:void 0}),A=typeof h.actor_id=="string"?h.actor_id.trim():"";if(!A)throw new Error("생성 응답에 actor_id가 없습니다.");const k=No.value.trim();k&&await sp(e,A,k),Be.value=A,ne.value=A,i||(qs.value=""),Fs.value="ok",O(`Actor 생성 완료: ${A}`,"success"),await le()}catch(v){Fs.value="error",O(v instanceof Error?v.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Lo.value}
            onInput=${i=>{Lo.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Po.value}
            onChange=${i=>{Po.value=i.target.value}}
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
            value=${No.value}
            onInput=${i=>{No.value=i.target.value}}
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
              onInput=${i=>{qs.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${jo.value}
              onInput=${i=>{jo.value=i.target.value}}
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
              value=${Fn.value}
              onInput=${i=>{Fn.value=i.target.value}}
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
              value=${Oo.value}
              onInput=${i=>{const l=i.target.value;Oo.value=l,cy(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Eo.value}
              onInput=${i=>{Eo.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Do.value}
              onInput=${i=>{Do.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function ky({state:t,nowMs:e}){var v;const n=Yt.value||((v=t.session)==null?void 0:v.room)||"",s=t.join_gate,a=Mo.value,i=m(a)?a:null,l=(t.party??[]).filter(h=>h.role!=="dm"),c=ne.value.trim(),p=l.some(h=>h.id===c),_=p?c:c?"__manual__":"",u=async()=>{const h=ne.value.trim(),A=ws.value.trim();if(!n||!h){O("Room/Actor가 필요합니다.","warning");return}At.value="checking";try{const k=await ap(n,h,A||void 0);Mo.value=k,At.value="ok",O("참가 가능 여부를 갱신했습니다.","success")}catch(k){At.value="error";const S=k instanceof Error?k.message:"참가 가능 여부 확인에 실패했습니다.";O(S,"error")}},f=async()=>{var b,$;const h=ne.value.trim(),A=ws.value.trim(),k=Ro.value.trim();if(!n||!h||!A){O("Room/Actor/Keeper가 필요합니다.","warning");return}if(!aa(e))return;const S=((b=t.current_round)==null?void 0:b.phase)??(($=t.session)==null?void 0:$.status)??"unknown";if(bi("Mid-Join 승인 요청",n,S)){At.value="requesting";try{const R=await op({room_id:n,actor_id:h,keeper_name:A,role:zo.value,...k?{name:k}:{}});Mo.value=R;const M=m(R)?is(R,"granted",!1):!1,L=m(R)?bt(R,"reason_code",""):"";M?O("Mid-Join이 승인되었습니다.","success"):O(`Mid-Join이 거절되었습니다${L?`: ${L}`:""}`,"warning"),At.value=M?"ok":"error",le()}catch(R){At.value="error";const M=R instanceof Error?R.message:"Mid-Join 요청에 실패했습니다.";O(M,"error")}finally{Ha()}}};return o`
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
            value=${_}
            onChange=${h=>{const A=h.target.value;if(A==="__manual__"){(p||!c)&&(ne.value="");return}ne.value=A}}
          >
            <option value="">Actor 선택</option>
            ${l.map(h=>o`
              <option value=${h.id}>${h.name} (${h.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${_==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${ne.value}
                onInput=${h=>{ne.value=h.target.value}}
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
            onInput=${h=>{ws.value=h.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${zo.value}
            onChange=${h=>{zo.value=h.target.value}}
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
            value=${Ro.value}
            onInput=${h=>{Ro.value=h.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${u} disabled=${At.value==="checking"||At.value==="requesting"}>
              ${At.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${f} disabled=${At.value==="checking"||At.value==="requesting"}>
              ${At.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${is(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${jt(i,"effective_score",0)}/${jt(i,"required_points",0)}</span>
            ${bt(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${bt(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Td({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Id({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function zd(){const t=hi.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=m(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(m).slice(-8),i=t.canon_check,l=m(i)?i:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(L=>typeof L=="string").slice(0,3):[],p=l&&Array.isArray(l.violations)?l.violations.filter(L=>typeof L=="string").slice(0,3):[],_=n?is(n,"advanced",!1):!1,u=n?bt(n,"progress_reason",""):"",f=n?bt(n,"progress_detail",""):"",v=n?jt(n,"player_successes",0):0,h=n?jt(n,"player_required_successes",0):0,A=n?is(n,"dm_success",!1):!1,k=n?jt(n,"timeouts",0):0,S=n?jt(n,"unavailable",0):0,b=n?jt(n,"reprompts",0):0,$=n?jt(n,"npc_attacks",0):0,R=n?jt(n,"keeper_timeout_sec",0):0,M=n?jt(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${_?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${_?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${A?"DM ok":"DM stalled"} / players ${v}/${h}
          </span>
        </div>
        ${u?o`<div style="margin-top:4px; font-size:12px;">${u}</div>`:null}
        ${f?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${f}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${b}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${$}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${R||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${M}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(L=>{const J=bt(L,"status","unknown"),z=bt(L,"actor_id","-"),W=bt(L,"role","-"),Y=bt(L,"reason",""),st=bt(L,"action_type",""),P=bt(L,"reply","");return o`
                <div class="trpg-round-item ${J.includes("fallback")||J.includes("timeout")?"failed":"active"}">
                  <span>${z} (${W})</span>
                  <span style="margin-left:auto; font-size:11px;">${J}</span>
                  ${st?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${st}</div>`:null}
                  ${Y?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${Y}</div>`:null}
                  ${P?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${P.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${bt(l,"status","unknown")}</strong>
            </div>
            ${p.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${p.map(L=>o`<div>violation: ${L}</div>`)}
                </div>`:null}
            ${c.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(L=>o`<div>warning: ${L}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function xy({state:t,nowMs:e}){var l,c,p;const n=Yt.value||((l=t.session)==null?void 0:l.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((p=t.session)==null?void 0:p.status)??"unknown",a=kd(e),i=py(e);return o`
    <${I} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>my(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Ha(),O("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Sy({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>uy(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Cy({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${I} title="관전 가이드" semanticId="lab.trpg">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${I} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${Cd} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${I} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${gy} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${I} title="현재 라운드" semanticId="lab.trpg">
          <${Id} state=${t} />
        <//>

        <${I} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${Td} state=${t} />
        <//>

        <${I} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${Sd} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${I} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Ad} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Ay({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${I} title=${`이벤트 타임라인 (${e.length})`}>
          <${$y} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${I} title="최근 라운드 결과" semanticId="lab.trpg">
          <${zd} />
        <//>

        <${I} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${Id} state=${t} />
        <//>
      </div>
    </div>
  `}function Ty({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${xy} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${I} title="조작 패널" semanticId="lab.trpg">
            <${yy} state=${t} nowMs=${e} />
          <//>

          <${I} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${by} state=${t} />
          <//>

          <${I} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${ky} state=${t} nowMs=${e} />
          <//>

          <${I} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${zd} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${I} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${Td} state=${t} />
          <//>

          <${I} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${Sd} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${I} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Ad} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Iy(){var c,p,_,u,f;const t=wl.value,e=Zo.value;if(ot(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const v=window.setInterval(()=>{cl.value=Date.now()},1e3);return()=>{window.clearInterval(v)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>le()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=bd.value,l=cl.value;return o`
    <div>
      <${St} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Yt.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((p=t.current_round)==null?void 0:p.phase)??((_=t.session)==null?void 0:_.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>le()}>새로고침</button>
      </div>

      <${hy} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((u=t.session)==null?void 0:u.status)??"active"}</div>
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

      <${Sy} active=${i} />

      ${i==="overview"?o`<${Cy} state=${t} />`:i==="timeline"?o`<${Ay} state=${t} />`:o`<${Ty} state=${t} nowMs=${l} />`}
    </div>
  `}function zy(){return o`
    <div>
      <${St} surfaceId="lab" />
      <${I} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${I} title="TRPG" class="section" semanticId="lab.trpg">
        <${Iy} />
      <//>
    </div>
  `}const Wa=g(new Set(["broadcast","tasks","keepers","system"]));function Ry(t){const e=new Set(Wa.value);e.has(t)?e.delete(t):e.add(t),Wa.value=e}const cr=g(null);function Rd(t){cr.value=t}function My(t){return t.kind==="board"?"broadcast":t.kind==="tasks"?"tasks":t.kind==="keepers"?"keepers":"system"}const Ly=Mt(()=>{const t=Wa.value;return ia.value.filter(e=>t.has(My(e)))}),Py=12e4,Ny=Mt(()=>{const t=Bl.value,e=Date.now();return Qt.value.map(n=>{const s=n.name.trim().toLowerCase(),a=t.get(s)??null;let i="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?i=e-new Date(l).getTime()>Py?"stale":"working":i="working"}else(n.status==="offline"||n.status==="inactive")&&(i="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:i,currentTask:n.current_task,motion:a}})}),jy=Mt(()=>{const t=Bl.value;return Qt.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle").map(e=>{const n=e.name.trim().toLowerCase(),s=t.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let i="calm";return a>=3?i="hot":a>=1&&(i="normal"),{name:e.name,emoji:e.emoji??"",koreanName:e.koreanName??null,currentTask:e.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:i}}).sort((e,n)=>{const s={hot:0,normal:1,calm:2};return s[e.pressure]-s[n.pressure]})});function dl(t){return t.kind==="board"?"live-event-broadcast":t.kind==="tasks"?"live-event-task":t.kind==="keepers"?"live-event-keeper":"live-event-system"}function Ey(t){const e=t.eventType;return e==="broadcast"?"broadcast":e==="agent_joined"?"joined":e==="agent_left"?"left":e==="task_update"?"task":e==="board_post"?"post":e==="board_comment"?"comment":e==="keeper_heartbeat"?"heartbeat":e==="keeper_handoff"?"handoff":e==="keeper_compaction"?"compact":e==="keeper_guardrail"?"guardrail":t.kind==="board"?"board":t.kind==="tasks"?"task":t.kind==="keepers"?"keeper":"system"}function Oy(t){switch(t){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function Dy(){const t=Ny.value,e=cr.value;return t.length===0?o`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:o`
    <div class="pulse-strip">
      ${t.map(n=>o`
        <button
          key=${n.name}
          class="pulse-bubble ${Oy(n.state)} ${e===n.name?"pulse-selected":""}"
          onClick=${()=>Rd(e===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const wy=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function qy(){const t=Wa.value;return o`
    <div class="activity-filter-bar">
      ${wy.map(e=>o`
        <button
          key=${e.kind}
          class="activity-filter-btn ${e.cssClass} ${t.has(e.kind)?"active":""}"
          onClick=${()=>Ry(e.kind)}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Fy(){const t=Ly.value;return o`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${t.length} events</span>
      </div>
      <${qy} />
      <div class="activity-stream-list">
        ${t.length===0?o`<div class="activity-empty">No events matching filters</div>`:t.map((e,n)=>o`
            <div
              key=${`${e.timestamp}-${n}`}
              class="activity-item ${dl(e)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${dl(e)}">${Ey(e)}</span>
                <span class="activity-agent">${e.agent}</span>
                <span class="activity-time">${qc(e.timestamp)}</span>
              </div>
              <div class="activity-item-text">${e.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function Ky(t){switch(t){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function By(t){switch(t){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function Uy(){const t=jy.value,e=cr.value;return o`
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
              onClick=${()=>Rd(e===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?o`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${Ky(n.pressure)}">
                  ${By(n.pressure)}
                  ${n.assignedCount>0?o` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?o`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?o`<span class="focus-activity-text">${n.lastActivityText}</span>`:o`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?o`<${X} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function Hy(){const t=pe.value;return o`
    <div class="live-monitor">
      <div class="live-header">
        <h2>라이브 모니터</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${t?"connected":"disconnected"}"></span>
            ${t?"연결됨":"오프라인"}
          </span>
          <span class="live-stat">에이전트 ${Qt.value.length}</span>
          <span class="live-stat">이벤트 ${Ga.value}</span>
        </div>
      </div>

      <${Dy} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${Fy} />
        </div>
        <div class="live-panel-side">
          <${Uy} />
        </div>
      </div>
    </div>
  `}const ul=[{id:"observe",label:"관찰",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"맥락",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"개입",description:"개입과 운영 기준 지휘를 실행하는 표면"},{id:"lab",label:"실험",description:"실험적 기능은 메인 operator console 밖으로 분리"}],ki=[{id:"mission",label:"상황판",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"proof",label:"근거",icon:"🔍",group:"observe",description:"협업, 대화, 도구, 근거 기록을 증명 중심으로 읽는 표면"},{id:"execution",label:"실행",icon:"🤖",group:"observe",description:"워커, 태스크, 키퍼 연속성을 분리해서 보는 실행 표면"},{id:"tools",label:"도구",icon:"🧰",group:"observe",description:"시스템 전체 도구 inventory와 사용 통계를 함께 읽는 표면"},{id:"live",label:"라이브",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"계획",icon:"🎯",group:"observe",description:"목표, 지표 루프, 백로그 압력을 읽는 계획 표면"},{id:"memory",label:"메모리",icon:"💬",group:"context",description:"게시글과 댓글로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"거버넌스",icon:"⚖️",group:"context",description:"토론과 표결을 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"개입",icon:"🎮",group:"act",description:"룸, 세션, 키퍼 액션을 실행하는 개입 화면"},{id:"command",label:"지휘",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"실험",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 표면을 메인 콘솔 밖에서 다룹니다"}];function Wy(t){const e=t==null?void 0:t.trim();return e?e.length>10?e.slice(0,10):e:"커밋 정보 없음"}function zt(t,e){return e==="live"?"가동 중":e==="quiet"?"조용함":e==="starting"?"기동 중":e==="idle"?t==="guardian"?"유휴":"대기 중":"비활성"}function Tt(t,e){return o`
    <div class="build-badge-row">
      <span>${t}</span>
      <strong>${e}</strong>
    </div>
  `}function Bs(t,e,n,s,a){return o`
    <div style="padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
      <div class="rail-card-head" style="margin:0;">
        <h3 style="font-size:12px;">${t}</h3>
        <span class="rail-section-chip ${n}">${e}</span>
      </div>
      ${s}
      ${a?o`<div class="rail-build-hint">${a}</div>`:null}
    </div>
  `}function Gy({currentTab:t}){var p,_,u,f,v,h,A,k,S,b;const e=pe.value,n=(p=lt.value)==null?void 0:p.build,s=(_=lt.value)==null?void 0:_.lodge,a=(u=lt.value)==null?void 0:u.gardener,i=(f=lt.value)==null?void 0:f.guardian,l=(v=lt.value)==null?void 0:v.sentinel,c=[];if(s&&c.push(Bs("Lodge",s.enabled?zt("lodge",s.quiet_active?"quiet":"live"):zt("lodge","disabled"),s.enabled?s.quiet_active?"warn":"ok":"bad",[Tt("틱",s.total_ticks??0),Tt("체크인",s.total_checkins??0),Tt("최근 결과",((h=s.last_tick_result)==null?void 0:h.activity_report)??s.last_skip_reason??"없음")])),a&&c.push(Bs("Gardener",a.alive?zt("gardener","live"):a.enabled?zt("gardener","starting"):zt("gardener","disabled"),a.alive?"ok":a.enabled?"warn":"bad",[Tt("최근 tick",a.last_tick_completed_at?o`<${X} timestamp=${a.last_tick_completed_at} />`:"기록 없음"),Tt("판단",`${a.last_intervention??"없음"} · ${a.last_decision_source??"없음"}`),Tt("백로그",`미할당 ${((A=a.health_summary)==null?void 0:A.todo_count)??0} · P1/2 ${((k=a.health_summary)==null?void 0:k.high_priority_todo)??0}`)],a.last_reason??a.last_error??void 0)),i){const $=i.masc_loops_running||i.lodge_loop_started||i.lodge_running;c.push(Bs("Guardian",$?zt("guardian","live"):i.enabled?zt("guardian","idle"):zt("guardian","disabled"),$?"ok":i.enabled?"warn":"bad",[Tt("모드",i.mode??"알 수 없음"),Tt("루프",`zombie ${i.zombie_loop_running?"on":"off"} · gc ${i.gc_loop_running?"on":"off"}`),Tt("소유자",i.runtime_owner??"없음")],((S=i.last_lodge_result)==null?void 0:S.message)??i.last_gc_result??i.last_zombie_result??void 0))}return l&&c.push(Bs("Sentinel",l.started?zt("sentinel","live"):l.enabled?zt("sentinel","starting"):zt("sentinel","disabled"),l.started?"ok":l.enabled?"warn":"bad",[Tt("에이전트",l.agent_name??"sentinel"),Tt("소비자",((b=l.consumers)==null?void 0:b.length)??0),Tt("가디언 소유자",l.guardian_runtime_owner??"없음")],l.llm_enabled===!0?"LLM 기반 housekeeping resident":void 0)),o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${K} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${e?"ok":"bad"}">${e?"연결됨":"오프라인"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>에이전트</span>
          <strong>${Qt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>키퍼</span>
          <strong>${ge.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>태스크</span>
          <strong>${oe.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>이벤트</span>
          <strong>${Ga.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{ls(),Wl(),ci(t)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>it("intervene")}>
          개입 열기
        </button>
      </div>
      ${n?o`<div class="rail-build-hint">서버 빌드 · v${n.release_version} · ${Wy(n.commit)}</div>`:null}
      ${c.length>0?o`
            <div style="margin-top:12px; display:flex; flex-direction:column; gap:10px;">
              ${c}
            </div>
          `:null}
    </section>
  `}function Jy(){const t=$t.value,e=(t==null?void 0:t.pending_confirms.length)??0,n=(t==null?void 0:t.sessions.length)??0,s=(t==null?void 0:t.keepers.length)??0;return o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${K} panelId="side_rail.quick_actions" compact=${!0} />
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
          onClick=${()=>{xt(),Ee()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>it("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}const Us=g(!1);function Yy(){const t=pe.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"연결됨":"재연결 중..."}</span>
      <span class="event-count">이벤트 ${Ga.value}</span>
    </div>
  `}function Vy(t){const e=t==null?void 0:t.trim();return e?e.length>10?e.slice(0,10):e:"커밋 정보 없음"}function Xy(){const t=lt.value,e=t==null?void 0:t.build,n=e?`v${e.release_version} · ${Vy(e.commit)}`:t!=null&&t.version?`v${t.version} · 커밋 정보 없음`:"버전 정보 없음";return o`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${Us.value}
        onClick=${()=>{Us.value=!Us.value}}
      >
        서버 빌드 · ${n}
      </button>
      ${Us.value?o`
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
                <strong>${e!=null&&e.started_at?o`<${X} timestamp=${e.started_at} />`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof(e==null?void 0:e.uptime_seconds)=="number"?`${e.uptime_seconds}s`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${t!=null&&t.generated_at?o`<${X} timestamp=${t.generated_at} />`:"알 수 없음"}</strong>
              </div>
            </div>
          `:null}
    </div>
  `}function Qy(){const t=F.value.tab,e=ki.find(s=>s.id===t),n=ul.find(s=>s.id===(e==null?void 0:e.group));return o`
    <aside class="dashboard-rail">
      <${St} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${K} panelId="side_rail.navigate" compact=${!0} />
          ${n?o`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${ul.map(s=>o`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${ki.filter(a=>a.group===s.id).map(a=>o`
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

      <${Gy} currentTab=${t} />
      <${Jy} />
    </aside>
  `}function Zy(){switch(F.value.tab){case"mission":return o`<${Nr} />`;case"proof":return o`<${vg} />`;case"execution":return o`<${$h} />`;case"tools":return o`<${Ch} />`;case"live":return o`<${Hy} />`;case"memory":return o`<${sh} />`;case"governance":return o`<${Zh} />`;case"planning":return o`<${qh} />`;case"intervene":return o`<${U$} />`;case"command":return o`<${q$} />`;case"lab":return o`<${zy} />`;default:return o`<${Nr} />`}}function tb(){return Qo.value&&!pe.value?o`<div class="loading-indicator">대시보드 불러오는 중...</div>`:o`<${Zy} />`}function eb(){ot(()=>{qd(),$l(),Gl(),Re(),ze(),Wl(),lc();const n=zm();return Rm(),()=>{Jd(),n(),Mm()}},[]),ot(()=>{const n=setInterval(()=>{ci(F.value.tab)},15e3);return()=>{clearInterval(n)}},[]),ot(()=>{ci(F.value.tab)},[F.value.tab]);const t=F.value.tab,e=ki.find(n=>n.id===t);return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC 대시보드
            <${Xy} />
          </h1>
          <p class="header-subtitle">${(e==null?void 0:e.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${Yy} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${Qy} />
        <main class="dashboard-main">
          <${tb} />
        </main>
      </div>

      <${$f} />
      <${Gv} />
      <${Ov} />
    </div>
  `}const pl=document.getElementById("app");pl&&jd(o`<${eb} />`,pl);export{If as _};
