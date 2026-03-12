var Wc=Object.defineProperty;var Gc=(e,t,n)=>t in e?Wc(e,t,{enumerable:!0,configurable:!0,writable:!0,value:n}):e[t]=n;var jt=(e,t,n)=>Gc(e,typeof t!="symbol"?t+"":t,n);import{e as Jc,_ as Vc,c as f,b as Ie,y as ne,d as Rr,A as Yc,G as Xc}from"./vendor-kuFK4-oj.js";(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const l of o.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=Jc.bind(Vc);const Qc=["mission","proof","execution","live","memory","governance","planning","intervene","command","lab"],Pr={tab:"mission",params:{},postId:null};function jo(e){return!!e&&Qc.includes(e)}function gi(e){try{return decodeURIComponent(e)}catch{return e}}function $i(e){const t={};return e&&new URLSearchParams(e).forEach((s,a)=>{t[a]=s}),t}function Zc(e){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Lr(e,t){if(e[0]==="chains"){const o={...t,surface:"chains"};return e[1]==="operation"&&e[2]&&(o.operation=gi(e[2])),{tab:"command",params:o,postId:null}}if(e[0]==="lab"){const o={...t};return e[1]&&(o.surface=gi(e[1])),{tab:"lab",params:o,postId:null}}const n=e[0],s=t.tab;return{tab:jo(n)?n:jo(s)?s:"mission",params:t,postId:null}}function Bs(e){const t=(e||"").replace(/^#/,"").trim();if(!t)return Pr;const n=gi(t);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=$i(a),l=Zc(s);return Lr(l,o)}function ed(e,t){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Pr,params:$i(t.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=$i(t.replace(/^\?/,""));return Lr(s,a)}function Mr(e){const t=e.tab==="lab"&&e.params.surface?`lab/${encodeURIComponent(e.params.surface)}`:e.tab,n=Object.entries(e.params).filter(([a])=>!(a==="tab"||e.tab==="lab"&&a==="surface"));if(n.length===0)return`#${t}`;const s=new URLSearchParams(n);return`#${t}?${s.toString()}`}const F=f(Bs(window.location.hash));window.addEventListener("hashchange",()=>{F.value=Bs(window.location.hash)});function se(e,t){const n={tab:e,params:t??{}};window.location.hash=Mr(n)}function td(e){window.location.hash=`#memory?post=${encodeURIComponent(e)}`}function nd(){if(window.location.hash&&window.location.hash!=="#"){F.value=Bs(window.location.hash);return}const e=ed(window.location.pathname,window.location.search);if(e){F.value=e;const t=Mr(e);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${t}`);return}window.location.hash="#mission",F.value=Bs(window.location.hash)}const Eo="masc_dashboard_sse_session_id",sd=1e3,ad=15e3,rt=f(!1),za=f(0),jr=f(null),Us=f([]);function id(){let e=sessionStorage.getItem(Eo);return e||(e=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Eo,e)),e}const od=200;function rd(e,t,n="system",s={}){const a={agent:e,text:t,timestamp:Date.now(),kind:n,...s};Us.value=[a,...Us.value].slice(0,od)}function hi(e,t=88){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-3)}...`:n:void 0}function No(e,t){const n=hi(t);return n?`${e}: ${n}`:`New ${e.toLowerCase()}`}function Ce(e,t,n,s,a={}){rd(e,t,n,{eventType:s,...a})}let Me=null,Gt=null,yi=0;function Er(){Gt&&(clearTimeout(Gt),Gt=null)}function ld(){if(Gt)return;yi++;const e=Math.min(yi,5),t=Math.min(ad,sd*Math.pow(2,e));Gt=setTimeout(()=>{Gt=null,Nr()},t)}function Nr(){Er(),Me&&(Me.close(),Me=null);const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");n&&t.set("agent",n),s&&t.set("token",s),t.set("session_id",id());const a=t.toString()?`/sse?${t.toString()}`:"/sse",o=new EventSource(a);Me=o,o.onopen=()=>{Me===o&&(yi=0,rt.value=!0)},o.onerror=()=>{Me===o&&(rt.value=!1,o.close(),Me=null,ld())},o.onmessage=l=>{try{const c=JSON.parse(l.data);za.value++,jr.value=c,cd(c)}catch{}}}function cd(e){const t=e.type,n=e.agent??e.author??e.from??e.from_agent??"";switch(t){case"agent_joined":Ce(n,"Joined","system","agent_joined");break;case"agent_left":Ce(n,"Left","system","agent_left");break;case"broadcast":Ce(n,`${(e.message??e.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Ce(n,`Task: ${e.task_id??""} -> ${e.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Ce(n,No("Post",e.content??e.message),"board","board_post",{author:e.author??n,preview:hi(e.content??e.message),postId:e.post_id});break;case"board_comment":case"masc/board_comment":Ce(n,No("Comment",e.content??e.message),"board","board_comment",{author:e.author??n,preview:hi(e.content??e.message),postId:e.post_id});break;case"keeper_heartbeat":Ce(e.name??n,`Heartbeat gen=${e.generation??"?"} ctx=${e.context_ratio!=null?Math.round(e.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Ce(e.name??n,`Handoff gen ${e.from_generation??"?"} -> ${e.to_generation??"?"} (${e.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Ce(e.name??n,`Compaction saved ${e.saved_tokens??"?"} tokens (${e.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Ce(e.name??n,`Guardrail: ${e.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Ce(n,t,"system","unknown")}}function dd(){Er(),Me&&(Me.close(),Me=null),rt.value=!1}function v(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function r(e){return typeof e=="string"&&e.trim()!==""?e.trim():void 0}function d(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function N(e){return typeof e=="boolean"?e:void 0}function H(e){return Array.isArray(e)?e.map(t=>typeof t=="string"?t.trim():"").filter(Boolean):[]}function pe(e,t=[]){if(Array.isArray(e))return e;if(!v(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function ae(e){if(typeof e=="string"&&e.trim()!=="")return e;if(!(typeof e!="number"||!Number.isFinite(e)||e<=0))return new Date(e*1e3).toISOString()}function wr(){return new URLSearchParams(window.location.search)}const ud="masc_dashboard_agent_name";function pd(){var e;try{return((e=localStorage.getItem(ud))==null?void 0:e.trim())||null}catch{return null}}function Dr(){const e=wr(),t={},n=e.get("token"),s=pd(),a=e.get("agent")??e.get("agent_name")??s;return n&&(t.Authorization=`Bearer ${n}`),a&&(t["X-MASC-Agent"]=a),t}function Or(){return{...Dr(),"Content-Type":"application/json"}}const md=15e3,Vi=3e4,vd=6e4,wo=new Set([408,425,429,500,502,503,504]);class Zn extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);jt(this,"method");jt(this,"path");jt(this,"status");jt(this,"statusText");jt(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function Yi(e,t,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(e,{...t,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const l=typeof t.method=="string"?t.method.toUpperCase():"GET";throw new Zn({method:l,path:e,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function _d(){var t,n;const e=wr();return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Q(e){const t=await Yi(e,{headers:Dr()},md);if(!t.ok)throw new Zn({method:"GET",path:e,status:t.status,statusText:t.statusText});return t.json()}function fd(e){return new Promise(t=>setTimeout(t,e))}function gd(e){const t=e.match(/\b(\d{3})\b/);if(!t)return null;const n=t[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function $d(e){if(e instanceof Zn)return e.timeout||typeof e.status=="number"&&wo.has(e.status);if(!(e instanceof Error))return!1;if(/timeout after \d+ms/i.test(e.message))return!0;const t=gd(e.message);return t!==null&&wo.has(t)}async function Ra(e,t,n=2){let s=0;for(;;)try{return await t()}catch(a){if(!$d(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${e} failed (attempt ${s+1}), retrying in ${o}ms`,a),await fd(o),s+=1}}async function Oe(e,t,n,s=Vi){const a=await Yi(e,{method:"POST",headers:{...Or(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new Zn({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.json()}async function hd(e,t,n,s=Vi){const a=await Yi(e,{method:"POST",headers:{...Or(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new Zn({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.text()}function yd(e){const t=e.split(`
`).find(s=>s.startsWith("data: ")),n=t?t.slice(6).trim():e.trim();return JSON.parse(n)}function bd(e){var t,n,s,a,o,l,c;if((t=e.error)!=null&&t.message)throw new Error(e.error.message);if((n=e.result)!=null&&n.isError){const p=((a=(s=e.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(p)}return((c=(l=(o=e.result)==null?void 0:o.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function ut(e,t){const n=await hd("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:e,arguments:t},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},vd),s=yd(n);return bd(s)}function kd(){return Q("/api/v1/dashboard/shell")}function xd(){return Q("/api/v1/dashboard/execution")}function Sd(e,t){const n=new URLSearchParams;return n.set("sort_by",e),t!=null&&t.excludeSystem&&n.set("exclude_system","true"),Q(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function Cd(){return Ra("fetchDashboardGovernance",async()=>{const e=await Q("/api/v1/dashboard/governance"),t=Array.isArray(e.items)?e.items.map(o=>Bd(o)).filter(o=>o!==null):[],n=Array.isArray(e.pending_actions)?e.pending_actions.map(o=>Kr(o)).filter(o=>o!==null):[],s=t.filter(o=>o.kind==="debate").map(o=>({id:o.id,topic:o.topic,status:o.status,argument_count:o.evidence_refs.length,created_at:o.last_activity_at??void 0})),a=t.filter(o=>o.kind==="consensus").map(o=>({id:o.id,topic:o.topic,initiator:o.related_agents[0]||"system",votes:o.votes??0,quorum:o.quorum??0,threshold:o.threshold,state:o.status,created_at:o.last_activity_at??void 0}));return{generated_at:le(e.generated_at)??void 0,summary:v(e.summary)?{debates:me(e.summary.debates)??void 0,voting_sessions:me(e.summary.voting_sessions)??void 0,debates_open:me(e.summary.debates_open)??void 0,sessions_active:me(e.summary.sessions_active)??void 0,sessions_without_quorum:me(e.summary.sessions_without_quorum)??void 0,ready_to_execute:me(e.summary.ready_to_execute)??void 0,oldest_open_debate_age_s:typeof e.summary.oldest_open_debate_age_s=="number"?e.summary.oldest_open_debate_age_s:null,last_activity_age_s:typeof e.summary.last_activity_age_s=="number"?e.summary.last_activity_age_s:null,judge_online:typeof e.summary.judge_online=="boolean"?e.summary.judge_online:void 0,judge_last_seen_at:le(e.summary.judge_last_seen_at)}:void 0,debates:s,sessions:a,items:t,activity:Array.isArray(e.activity)?e.activity.map(o=>Ud(o)).filter(o=>o!==null):[],judge:Hd(e.judge),pending_actions:n}})}function Ad(){return Q("/api/v1/dashboard/semantics")}function Id(){return Q("/api/v1/dashboard/mission")}function Td(e){const t=`?session_id=${encodeURIComponent(e)}`;return Q(`/api/v1/dashboard/session${t}`)}function zd(e=!1){return Q(`/api/v1/dashboard/mission/briefing${e?"?force=1":""}`)}function Rd(e,t){const n=new URLSearchParams;e&&n.set("session_id",e),t&&n.set("operation_id",t);const s=n.toString();return Q(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function Pd(){return Q("/api/v1/dashboard/planning")}function Ld(){return Q("/api/v1/tool-metrics")}function Md(){return Q("/api/v1/operator")}function qr(e={}){const t=new URLSearchParams;e.targetType&&t.set("target_type",e.targetType),e.targetId&&t.set("target_id",e.targetId),e.includeWorkers!=null&&t.set("include_workers",e.includeWorkers?"true":"false");const n=t.toString();return Q(`/api/v1/operator/digest${n?`?${n}`:""}`)}function jd(){return Q("/api/v1/command-plane")}function Ed(){return Q("/api/v1/command-plane/summary")}function Nd(){return Q("/api/v1/chains/summary")}function wd(e){return Q(`/api/v1/chains/runs/${encodeURIComponent(e)}`)}function Dd(){return Q("/api/v1/command-plane/help")}function Od(e,t){const n=new URLSearchParams;e&&n.set("run_id",e),t&&n.set("operation_id",t);const s=n.toString();return Q(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function qd(e,t){const n=new URLSearchParams;e&&n.set("run_id",e),t&&n.set("operation_id",t);const s=n.toString();return Q(`/api/v1/command-plane/orchestra${s?`?${s}`:""}`)}function Fd(e,t){return Oe(e,t)}function Kd(e){switch(e.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"swarm_run_continue":return 6e4;case"swarm_run_rerun":return 12e4;case"swarm_run_abandon":return 3e4;case"lodge_tick":return 45e3;default:return Vi}}function Pa(e){return Oe("/api/v1/operator/action",e,void 0,Kd(e))}function Fr(e,t,n="confirm"){return Oe("/api/v1/operator/confirm",{actor:e,confirm_token:t,decision:n})}function Rs(e){if(typeof e=="string"&&e.trim())return e;if(typeof e!="number"||Number.isNaN(e))return new Date().toISOString();const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}function le(e){if(typeof e=="string"){const t=e.trim();return t||null}if(typeof e=="number"&&Number.isFinite(e)){const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}return null}function q(e){if(typeof e!="string")return null;const t=e.trim();return t||null}function Kr(e){if(!v(e))return null;const t=k(e.confirm_token??e.token,"").trim();return t?{confirm_token:t,actor:q(e.actor)??void 0,action_type:q(e.action_type)??void 0,target_type:q(e.target_type)??void 0,target_id:q(e.target_id),delegated_tool:q(e.delegated_tool)??void 0,created_at:le(e.created_at)??void 0,preview:e.preview}:null}function Xi(e){return v(e)?{board_post_id:q(e.board_post_id),task_id:q(e.task_id),operation_id:q(e.operation_id),team_session_id:q(e.team_session_id)}:{}}function Br(e){if(!v(e))return null;const t=q(e.action_kind),n=q(e.resolved_tool),s=q(e.target_type),a=q(e.target_id),o=q(e.reason);return!t&&!n&&!s&&!o?null:{action_kind:t??void 0,resolved_tool:n,target_type:s,target_id:a,reason:o??void 0,payload_preview:e.payload_preview}}function Ur(e){if(!v(e))return null;const t=q(e.action_type),n=q(e.delegated_tool),s=q(e.confirmation_state),a=le(e.created_at);return!t&&!n&&!s&&!a?null:{action_type:t??void 0,delegated_tool:n,confirmation_state:s??void 0,created_at:a}}function Hr(e){if(!v(e))return null;const t=Kr(e.pending_confirm),n=q(e.pending_confirm_token)??(t==null?void 0:t.confirm_token)??null;return{requires_human_gate:typeof e.requires_human_gate=="boolean"?e.requires_human_gate:void 0,pending_confirm:t,pending_confirm_token:n,ready_to_execute:typeof e.ready_to_execute=="boolean"?e.ready_to_execute:void 0}}function Wr(e){if(!v(e))return null;const t=q(e.summary),n=q(e.target_id);return!t&&!n?null:{judgment_id:q(e.judgment_id)??void 0,target_kind:q(e.target_kind)??void 0,target_id:n??void 0,status:q(e.status)??void 0,summary:t??void 0,confidence:typeof e.confidence=="number"?e.confidence:null,generated_at:le(e.generated_at),expires_at:le(e.expires_at),model_used:q(e.model_used),keeper_name:q(e.keeper_name),evidence_refs:je(e.evidence_refs),recommended_action:Br(e.recommended_action),guardrail_state:Hr(e.guardrail_state),executed_route:Ur(e.executed_route)}}function Bd(e){if(!v(e))return null;const t=k(e.id,"").trim(),n=k(e.topic,"").trim();if(!t||!n)return null;const s=Xi(e.context);return{kind:k(e.kind,"debate"),id:t,topic:n,status:k(e.status??e.state,"open"),last_activity_at:le(e.last_activity_at),truth_summary:q(e.truth_summary)??void 0,judgment_summary:q(e.judgment_summary),confidence:typeof e.confidence=="number"?e.confidence:null,related_agents:je(e.related_agents),context:s,linked_board_post_id:q(e.linked_board_post_id)??s.board_post_id??null,linked_task_id:q(e.linked_task_id)??s.task_id??null,linked_operation_id:q(e.linked_operation_id)??s.operation_id??null,linked_session_id:q(e.linked_session_id)??s.team_session_id??null,recommended_action:Br(e.recommended_action),executed_route:Ur(e.executed_route),guardrail_state:Hr(e.guardrail_state),evidence_refs:je(e.evidence_refs),approve_count:me(e.approve_count),reject_count:me(e.reject_count),abstain_count:me(e.abstain_count),votes:me(e.votes),quorum:me(e.quorum),threshold:typeof e.threshold=="number"?e.threshold:void 0}}function Ud(e){if(!v(e))return null;const t=k(e.kind,"").trim();return t?{kind:t,item_kind:q(e.item_kind)??void 0,item_id:q(e.item_id)??void 0,topic:q(e.topic)??void 0,created_at:le(e.created_at),summary:q(e.summary)??void 0,actor:q(e.actor),index:me(e.index),decision:q(e.decision)}:null}function Hd(e){if(v(e))return{judge_online:typeof e.judge_online=="boolean"?e.judge_online:void 0,refreshing:typeof e.refreshing=="boolean"?e.refreshing:void 0,generated_at:le(e.generated_at),expires_at:le(e.expires_at),model_used:q(e.model_used),keeper_name:q(e.keeper_name),last_error:q(e.last_error)}}function Wd(e){var a;const t=e.trim(),s=((a=(t.startsWith("[flair:")?t.replace(/^\[flair:[^\]]+\]\s*/i,""):t).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Gd(e){if(!v(e))return null;const t=k(e.source,"").trim()||null,n=k(e.state_block,"").trim()||null;return!t&&!n?null:{source:t,state_block:n}}function Jd(e){if(!v(e))return null;const t=k(e.id,"").trim(),n=k(e.author,"").trim(),s=k(e.body,"").trim()||k(e.content,"").trim(),a=s;if(!t||!n)return null;const o=B(e.score,0),l=B(e.votes_up,0),c=B(e.votes_down,0),p=B(e.votes,o||l-c),m=B(e.comment_count,B(e.reply_count,0)),u=(()=>{const S=e.flair;if(typeof S=="string"&&S.trim())return S.trim();if(v(S)){const x=k(S.name,"").trim();if(x)return x}return k(e.flair_name,"").trim()||void 0})(),_=k(e.created_at_iso,"").trim()||Rs(e.created_at),g=k(e.updated_at_iso,"").trim()||(e.updated_at!==void 0?Rs(e.updated_at):_),b=k(e.title,"").trim()||Wd(s),$=Array.isArray(e.tags)?e.tags.filter(S=>typeof S=="string"&&S.trim()!==""):[];return{id:t,author:n,post_kind:(()=>{const S=k(e.post_kind,"").trim().toLowerCase();return S==="automation"||S==="system"||S==="human"?S:void 0})(),title:b,body:s,content:a,meta:Gd(e.meta),tags:$,votes:p,vote_balance:o,comment_count:m,created_at:_,updated_at:g,flair:u,hearth:k(e.hearth,"").trim()||null,visibility:k(e.visibility,"").trim()||void 0,expires_at:k(e.expires_at_iso,"").trim()||(e.expires_at!==void 0&&e.expires_at!==0?Rs(e.expires_at):"")||null,hearth_count:B(e.hearth_count,0)}}function Vd(e){if(!v(e))return null;const t=k(e.id,"").trim(),n=k(e.post_id,"").trim(),s=k(e.author,"").trim();return!t||!s?null:{id:t,post_id:n,author:s,content:k(e.content,""),created_at:Rs(e.created_at)}}async function Yd(e){return Ra("fetchBoardPost",async()=>{const t=await Q(`/api/v1/board/${e}?format=flat`),n=v(t.post)?t.post:t,s=Jd(n)??{id:e,author:"unknown",post_kind:"human",title:"Post",body:"",content:"",meta:null,tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(t.comments)?t.comments:[]).map(Vd).filter(l=>l!==null);return{...s,comments:o}})}function Gr(e,t){return Oe("/api/v1/tools/masc_board_vote",{post_id:e,direction:t,vote:t,voter:_d()})}function Xd(e,t,n){return Oe("/api/v1/tools/masc_board_comment",{post_id:e,author:t,content:n})}function Qd(e){const t=k(e,"").trim().toLowerCase();if(t==="win"||t==="won"||t==="victory")return"victory";if(t==="lose"||t==="lost"||t==="defeat")return"defeat";if(t==="draw"||t==="stalemate"||t==="tie")return"draw"}function ce(...e){for(const t of e){const n=k(t,"");if(n.trim())return n.trim()}return""}function Do(e){const t=Qd(ce(e.outcome,e.result,e.result_code));if(!t)return;const n=ce(e.reason,e.reason_code,e.description,e.detail),s=ce(e.summary,e.summary_ko,e.summary_en,e.note),a=ce(e.details,e.details_text,e.text,e.note),o=ce(e.winner,e.winner_name,e.actor_winner,e.winner_actor),l=ce(e.winner_actor_id,e.winner_actor,e.actor_winner_id),c=ce(e.raw_reason,e.raw_reason_code,e.error_message),p=(()=>{const _=e.evidence??e.evidence_ids??e.supporting_events??e.event_ids??[];return typeof _=="string"?[_]:Array.isArray(_)?_.map(g=>{if(typeof g=="string")return g.trim();if(v(g)){const h=k(g.summary,"").trim();if(h)return h;const b=k(g.text,"").trim();if(b)return b;const $=k(g.type,"").trim();return $||k(g.event_id,"").trim()}return""}).filter(g=>g.length>0):[]})(),m=(()=>{const _=B(e.turn,Number.NaN);if(Number.isFinite(_))return _;const g=B(e.turn_number,Number.NaN);if(Number.isFinite(g))return g;const h=B(e.current_turn,Number.NaN);if(Number.isFinite(h))return h;const b=B(e.round,Number.NaN);return Number.isFinite(b)?b:void 0})(),u=ce(e.phase,e.phase_name,e.current_phase,e.phase_id);return{result:t,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:l||void 0,evidence:p.length>0?p:void 0,raw_reason:c||void 0,turn:m,phase:u||void 0}}function Zd(e,t){const n=v(e.state)?e.state:{};if(k(n.status,"active").toLowerCase()!=="ended")return;const a=[...t].reverse().find(l=>v(l)?k(l.type,"")==="session.outcome":!1),o=v(n.session_outcome)?n.session_outcome:{};if(v(o)&&Object.keys(o).length>0){const l=Do(o);if(l)return l}if(v(a))return Do(v(a.payload)?a.payload:{})}function k(e,t=""){return typeof e=="string"?e:t}function B(e,t=0){return typeof e=="number"&&Number.isFinite(e)?e:t}function me(e){if(typeof e=="number"&&Number.isFinite(e))return Math.trunc(e);if(typeof e=="string"){const t=Number.parseInt(e.trim(),10);if(Number.isFinite(t))return t}}function Hs(e,t=!1){return typeof e=="boolean"?e:t}function je(e){return Array.isArray(e)?e.map(t=>{if(typeof t=="string")return t.trim();if(v(t)){const n=k(t.name,"").trim(),s=k(t.id,"").trim(),a=k(t.skill,"").trim();return n||s||a}return""}).filter(t=>t.length>0):[]}function eu(e){const t={};if(!v(e)&&!Array.isArray(e))return t;if(v(e))return Object.entries(e).forEach(([n,s])=>{const a=n.trim(),o=k(s,"").trim();!a||!o||(t[a]=o)}),t;for(const n of e){if(!v(n))continue;const s=ce(n.to,n.target,n.actor_id,n.name,n.id),a=ce(n.relationship,n.relation,n.type,n.kind);!s||!a||(t[s]=a)}return t}function tu(e,t,n){if(e==="dm"||e==="player"||e==="npc")return e;const s=t.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function ke(e,t,n,s=0){const a=e[t];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=e[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const nu=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function su(e){const t=v(e.stats)?e.stats:{},n={};return Object.entries(t).forEach(([s,a])=>{const o=s.trim();o&&(nu.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function au(e,t){if(e!=="dice.rolled")return;const n=B(t.raw_d20,0),s=B(t.total,0),a=B(t.bonus,0),o=k(t.action,"roll"),l=B(t.dc,0);return{notation:l>0?`${o} (DC ${l})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function iu(e){const t=JSON.stringify(e);return t?t.length>160?`${t.slice(0,157)}...`:t:""}function ou(e){const t=e.trim().toLowerCase();return t?t.startsWith("dice.")?"dice":t.startsWith("combat.")||t.includes(".attack")||t.includes(".damage")?"combat":t.includes("actor.")?"actor":t.includes("turn.")||t==="turn.started"||t==="phase.changed"?"turn":t.includes("join.")?"join":t.includes("memory")?"memory":t.includes("world.")?"world":t.includes("narration")?"story":"meta":"meta"}function ru(e,t,n,s){const a=n||t||k(s.actor_id,"")||k(s.actor_name,"");switch(e){case"turn.action.proposed":{const o=k(s.proposed_action,k(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=k(s.reply,k(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return k(s.reply,k(s.content,k(s.text,"Narration")));case"dice.rolled":{const o=k(s.action,"roll"),l=B(s.total,0),c=B(s.dc,0),p=k(s.label,""),m=a||"actor",u=c>0?` vs DC ${c}`:"",_=p?` (${p})`:"";return`${m} ${o}: ${l}${u}${_}`}case"turn.started":return`Turn ${B(s.turn,1)} started`;case"phase.changed":return`Phase: ${k(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${k(s.name,v(s.actor)?k(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${k(s.keeper_name,k(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${k(s.keeper_name,k(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${B(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${B(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||k(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||k(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${k(s.reason_code,"unknown")}`;case"memory.signal":{const o=v(s.entity_refs)?s.entity_refs:{},l=k(o.requested_tier,""),c=k(o.effective_tier,""),p=Hs(o.guardrail_applied,!1),m=k(s.summary_en,k(s.summary_ko,"Memory signal"));if(!l&&!c)return m;const u=l&&c?`${l}->${c}`:c||l;return`${m} [${u}${p?" (guardrail)":""}]`}case"world.event":{if(k(s.event_type,"")==="canon.check"){const l=k(s.status,"unknown"),c=k(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return k(s.description,k(s.summary,"World event"))}case"combat.attack":return k(s.summary,k(s.result,"Attack resolved"));case"combat.defense":return k(s.summary,k(s.result,"Defense resolved"));case"session.outcome":return k(s.summary,k(s.outcome,"Session ended"));default:{const o=iu(s);return o?`${e}: ${o}`:e}}}function lu(e,t){const n=v(e)?e:{},s=k(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=k(n.actor_name,"").trim()||t[a]||k(v(n.payload)?n.payload.actor_name:"",""),l=v(n.payload)?n.payload:{},c=k(n.ts,k(n.timestamp,new Date().toISOString())),p=k(n.phase,k(l.phase,"")),m=k(n.category,"");return{type:s,actor:o||a||k(l.actor_name,""),actor_id:a||k(l.actor_id,""),actor_name:o,seq:n.seq,room_id:k(n.room_id,""),phase:p||void 0,category:m||ou(s),visibility:k(n.visibility,k(l.visibility,"public")),event_id:k(n.event_id,""),content:ru(s,a,o,l),dice_roll:au(s,l),timestamp:c}}function cu(e,t,n){var Z,ie;const s=k(e.room_id,"")||n||"default",a=v(e.state)?e.state:{},o=v(a.party)?a.party:{},l=v(a.actor_control)?a.actor_control:{},c=v(a.join_gate)?a.join_gate:{},p=v(a.contribution_ledger)?a.contribution_ledger:{},m=Object.entries(o).map(([V,ee])=>{const A=v(ee)?ee:{},Te=ke(A,"max_hp",void 0,10),Je=ke(A,"hp",void 0,Te),_t=ke(A,"max_mp",void 0,0),ft=ke(A,"mp",void 0,0),K=ke(A,"level",void 0,1),ze=ke(A,"xp",void 0,0),gt=Hs(A.alive,Je>0),_n=l[V],fn=typeof _n=="string"?_n:void 0,ls=tu(A.role,V,fn),cs=me(A.generation),ds=ce(A.joined_at,A.joinedAt,A.started_at,A.startedAt),us=ce(A.claimed_at,A.claimedAt,A.assigned_at,A.assignedAt,A.assigned_time),ps=ce(A.last_seen,A.lastSeen,A.last_seen_at,A.lastSeenAt,A.last_active,A.lastActive),ms=ce(A.scene,A.current_scene,A.currentScene,A.world_scene,A.scene_name,A.sceneName),vs=ce(A.location,A.current_location,A.currentLocation,A.position,A.zone,A.area);return{id:V,name:k(A.name,V),role:ls,keeper:fn,archetype:k(A.archetype,""),persona:k(A.persona,""),portrait:k(A.portrait,"")||void 0,background:k(A.background,"")||void 0,traits:je(A.traits),skills:je(A.skills),stats_raw:su(A),status:gt?"active":"dead",generation:cs,joined_at:ds||void 0,claimed_at:us||void 0,last_seen:ps||void 0,scene:ms||void 0,location:vs||void 0,inventory:je(A.inventory),notes:je(A.notes),relationships:eu(A.relationships),stats:{hp:Je,max_hp:Te,mp:ft,max_mp:_t,level:K,xp:ze,strength:ke(A,"strength","str",10),dexterity:ke(A,"dexterity","dex",10),constitution:ke(A,"constitution","con",10),intelligence:ke(A,"intelligence","int",10),wisdom:ke(A,"wisdom","wis",10),charisma:ke(A,"charisma","cha",10)}}}),u=m.filter(V=>V.status!=="dead"),_=Zd(e,t),g={phase_open:Hs(c.phase_open,!0),min_points:B(c.min_points,3),window:k(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},h=Object.entries(p).map(([V,ee])=>{const A=v(ee)?ee:{};return{actor_id:V,score:B(A.score,0),last_reason:k(A.last_reason,"")||null,reasons:je(A.reasons)}}),b=m.reduce((V,ee)=>(V[ee.id]=ee.name,V),{}),$=t.map(V=>lu(V,b)),S=B(a.turn,1),C=k(a.phase,"round"),x=k(a.map,""),L=v(a.world)?a.world:{},T=x||k(L.ascii_map,k(L.map,"")),R=$.filter((V,ee)=>{const A=t[ee];if(!v(A))return!1;const Te=v(A.payload)?A.payload:{};return B(Te.turn,-1)===S}),M=(R.length>0?R:$).slice(-12),z=k(a.status,"active");return{session:{id:s,room:s,status:z==="ended"?"ended":z==="paused"?"paused":"active",round:S,actors:u,created_at:((Z=$[0])==null?void 0:Z.timestamp)??new Date().toISOString()},current_round:{round_number:S,phase:C,events:M,timestamp:((ie=$[$.length-1])==null?void 0:ie.timestamp)??new Date().toISOString()},map:T||void 0,join_gate:g,contribution_ledger:h,outcome:_,party:u,story_log:$,history:[]}}async function du(e){const t=`?room_id=${encodeURIComponent(e)}`,n=await Q(`/api/v1/trpg/events${t}`);return Array.isArray(n.events)?n.events:[]}async function uu(e){const t=`?room_id=${encodeURIComponent(e)}`,[n,s]=await Promise.all([Q(`/api/v1/trpg/state${t}`),du(e)]);return cu(n,s,e)}function pu(e){return Oe("/api/v1/trpg/rounds/run",{room_id:e})}function mu(e){const t="".trim().toLowerCase();if(t)switch(t){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return t}}function vu(e){const t={room_id:e.roomId,actor_id:e.actorId,action:e.action,stat_value:e.statValue,dc:e.dc};return e.rawD20!=null&&(t.raw_d20=e.rawD20),e.ruleModule&&(t.rule_module=e.ruleModule),Oe("/api/v1/trpg/dice/roll",t)}function _u(e,t){const n=mu();return Oe("/api/v1/trpg/turns/advance",{room_id:e,...n?{phase:n}:{}})}function fu(e,t){var a;const n=(a=t.idempotencyKey)==null?void 0:a.trim(),s={room_id:e};return t.actor_id&&t.actor_id.trim()&&(s.actor_id=t.actor_id.trim()),t.name&&t.name.trim()&&(s.name=t.name.trim()),t.role&&(s.role=t.role),t.archetype&&t.archetype.trim()&&(s.archetype=t.archetype.trim()),t.persona&&t.persona.trim()&&(s.persona=t.persona.trim()),t.portrait&&t.portrait.trim()&&(s.portrait=t.portrait.trim()),t.background&&t.background.trim()&&(s.background=t.background.trim()),t.hp!=null&&(s.hp=t.hp),t.max_hp!=null&&(s.max_hp=t.max_hp),t.alive!=null&&(s.alive=t.alive),Array.isArray(t.traits)&&t.traits.length>0&&(s.traits=t.traits),Array.isArray(t.skills)&&t.skills.length>0&&(s.skills=t.skills),Array.isArray(t.inventory)&&t.inventory.length>0&&(s.inventory=t.inventory),t.stats&&Object.keys(t.stats).length>0&&(s.stats=t.stats),n&&(s.idempotency_key=n),Oe("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function gu(e,t,n){return Oe("/api/v1/trpg/actors/claim",{room_id:e,actor_id:t,keeper:n})}async function $u(e,t,n){const s=await ut("trpg.join.eligibility",{room_id:e,actor_id:t,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function hu(e){const t=await ut("trpg.mid_join.request",e);return JSON.parse(t)}async function yu(e,t){await ut("masc_broadcast",{agent_name:e,message:t})}async function bu(e=40){return(await ut("masc_messages",{limit:e})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function ku(e,t=20){return ut("masc_task_history",{task_id:e,limit:t})}async function xu(e){const t=await ut("masc_debate_start",{topic:e});try{return JSON.parse(t)}catch{return null}}async function Su(e){return Ra("fetchDebateStatus",async()=>{const t=encodeURIComponent(e),n=await Q(`/api/v1/council/debates/${t}/summary`);if(!v(n))return null;const s=v(n.debate)?n.debate:n,a=k(s.id,"").trim(),o=k(s.topic,"").trim();return!a||!o?null:{debate:{id:a,topic:o,status:k(s.status,"open"),created_at:le(s.created_at_iso??s.created_at),closed_at:le(s.closed_at)},arguments:Array.isArray(n.arguments)?n.arguments.flatMap(l=>v(l)?[{index:B(l.index,0),agent:k(l.agent,"unknown"),position:k(l.position,"neutral"),content:k(l.content,""),evidence:je(l.evidence),reply_to:me(l.reply_to)??null,mentions:je(l.mentions),archetype:q(l.archetype),created_at:le(l.created_at)}]:[]):[],summary:{support_count:v(n.summary)?B(n.summary.support_count,0):B(n.support_count,0),oppose_count:v(n.summary)?B(n.summary.oppose_count,0):B(n.oppose_count,0),neutral_count:v(n.summary)?B(n.summary.neutral_count,0):B(n.neutral_count,0),total_arguments:v(n.summary)?B(n.summary.total_arguments,0):B(n.total_arguments,0),summary_text:v(n.summary)?k(n.summary.summary_text,""):k(n.summary_text,"")},context:Xi(n.context),judgment:Wr(n.judgment)}})}async function Cu(e){return Ra("fetchConsensusSessionSummary",async()=>{const t=encodeURIComponent(e),n=await Q(`/api/v1/council/sessions/${t}/summary`);if(!v(n)||!v(n.session))return null;const s=n.session,a=k(s.id,"").trim(),o=k(s.topic,"").trim();return!a||!o?null:{session:{id:a,topic:o,state:k(s.state,"open"),initiator:k(s.initiator,"system"),quorum:B(s.quorum,0),threshold:B(s.threshold,0),created_at:le(s.created_at),closed_at:le(s.closed_at)},votes:Array.isArray(n.votes)?n.votes.flatMap(l=>v(l)?[{agent:k(l.agent,"unknown"),decision:k(l.decision,"abstain"),reason:k(l.reason,""),timestamp:le(l.timestamp),weight:typeof l.weight=="number"?l.weight:void 0,archetype:q(l.archetype)}]:[]):[],summary:{approve_count:v(n.summary)?B(n.summary.approve_count,0):0,reject_count:v(n.summary)?B(n.summary.reject_count,0):0,abstain_count:v(n.summary)?B(n.summary.abstain_count,0):0,quorum_met:v(n.summary)?Hs(n.summary.quorum_met,!1):!1,result:v(n.summary)?q(n.summary.result):null},context:Xi(n.context),judgment:Wr(n.judgment)}})}function Au(e,t,n){return ut("masc_keeper_msg",{name:e,message:t})}const Iu=f(""),He=f({}),de=f({}),bi=f({}),ki=f({}),xi=f({}),Si=f({}),We=f({});function re(e,t,n){e.value={...e.value,[t]:n}}function Tu(e){var n;const t=(n=r(e))==null?void 0:n.toLowerCase();return t==="user"||t==="assistant"||t==="system"||t==="tool"?t:"other"}function zu(e){switch(e){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Ka(e,t){if(!Array.isArray(e))return[];const n=[];for(const s of e){if(!v(s))continue;const a=r(s.name);if(!a)continue;const o=r(s[t]);t==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function Ru(e){if(!v(e))return null;const t=r(e.name);return t?{name:t,trigger:r(e.trigger),outcome:r(e.outcome),summary:r(e.summary),reason:r(e.reason)}:null}function Pu(e){const t=e.toLowerCase();return t.includes("graphql")?"graphql_error":t.includes("timeout")||t.includes("model")||t.includes("llm")||t.includes("api key")||t.includes("api_key")||t.includes("provider")?"llm_error":"unknown"}function Lu(e,t){return e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":t==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":t==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":t==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Jr(e,t,n){return r(e)??Lu(t,n)}function Vr(e,t){return typeof e=="boolean"?e:t==="recover"}function Ws(e){if(!v(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);return!t||!n||!s?null:{health_state:t,quiet_reason:r(e.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:ae(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:Vr(e.recoverable,n),summary:Jr(e.summary,t,r(e.quiet_reason)??null),keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function Yr(e){return v(e)?{hour:d(e.hour),checked:d(e.checked)??0,acted:d(e.acted)??0,acted_names:H(e.acted_names),activity_report:r(e.activity_report),quiet_hours_overridden:N(e.quiet_hours_overridden),skipped_reason:r(e.skipped_reason),acted_rows:Ka(e.acted_rows,"summary").map(t=>({name:t.name,summary:t.summary})),passed_rows:Ka(e.passed_rows,"reason").map(t=>({name:t.name,reason:t.reason})),skipped_rows:Ka(e.skipped_rows,"reason").map(t=>({name:t.name,reason:t.reason})),checkins:Array.isArray(e.checkins)?e.checkins.map(Ru).filter(t=>t!==null):[]}:null}function Mu(e){return v(e)?{enabled:N(e.enabled)??!1,interval_s:d(e.interval_s)??0,quiet_start:d(e.quiet_start),quiet_end:d(e.quiet_end),quiet_active:N(e.quiet_active),use_planner:N(e.use_planner),delegate_llm:N(e.delegate_llm),agent_count:d(e.agent_count),agents:H(e.agents),last_tick_ago_s:d(e.last_tick_ago_s)??null,last_tick_ago:r(e.last_tick_ago),total_ticks:d(e.total_ticks),total_checkins:d(e.total_checkins),last_skip_reason:r(e.last_skip_reason)??null,last_tick_result:Yr(e.last_tick_result),active_self_heartbeats:H(e.active_self_heartbeats)}:null}function ju(e){return v(e)?{status:e.status,diagnostic:Ws(e.diagnostic)}:null}function Eu(e){return v(e)?{recovered:N(e.recovered)??!1,skipped_reason:r(e.skipped_reason)??null,before:Ws(e.before),after:Ws(e.after),down:e.down,up:e.up}:null}function Nu(e,t){var x,L;if(!(e!=null&&e.name))return null;const n=r((x=e.agent)==null?void 0:x.status)??r(e.status)??"unknown",s=r((L=e.agent)==null?void 0:L.error)??null,a=e.presence_keepalive??!0,o=e.keepalive_running??!1,l=e.turn_count??0,c=e.last_turn_ago_s??null,p=e.proactive_enabled??!1,m=e.proactive_cooldown_sec??0,u=e.last_proactive_ago_s??null,_=p&&u!=null?Math.max(0,m-u):null,g=l<=0||c==null?"never":c>900?"stale":"fresh",h=typeof e.last_heartbeat=="string"&&e.last_heartbeat.trim()?e.last_heartbeat:null,b=s??(a&&!o?"keeper keepalive is not running":null),$=n==="offline"||n==="inactive"?"offline":b?"degraded":g==="stale"?"stale":g==="never"?"idle":"healthy",S=b?Pu(b):t!=null&&t.quiet_active&&g!=="fresh"?"quiet_hours":a&&!o?"disabled":l<=0?"never_started":_!=null&&_>0?"min_gap":g==="fresh"||g==="stale"?"no_recent_activity":"unknown",C=$==="offline"||$==="degraded"||$==="stale"?"recover":S==="quiet_hours"?"manual_lodge_poke":S==="unknown"?"probe":"direct_message";return{health_state:$,quiet_reason:S,next_action_path:C,last_reply_status:g,last_reply_at:h,last_reply_preview:null,last_error:b,next_eligible_at_s:_!=null&&_>0?_:null,recoverable:Vr(void 0,C),summary:Jr(void 0,$,S),keepalive_running:o}}function wu(e,t){if(!v(e))return null;const n=Tu(e.role),s=r(e.content)??r(e.preview);if(!s)return null;const a=ae(e.ts_unix)??ae(e.timestamp);return{id:`${n}-${a??"entry"}-${t}`,role:n,label:zu(n),text:s,timestamp:a,delivery:"history"}}function Du(e,t,n){const s=v(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,l)=>wu(o,l)).filter(o=>o!==null):[];return{name:e,diagnostic:Ws(s==null?void 0:s.diagnostic),history:a,rawText:t,rawStatus:n,loadedAt:new Date().toISOString()}}function Oo(e,t){const n=de.value[e]??[];de.value={...de.value,[e]:[...n,t].slice(-50)}}function Ou(e,t){return e.role!==t.role||e.text!==t.text?!1:e.timestamp&&t.timestamp?e.timestamp===t.timestamp:!0}function qu(e,t){const s=(de.value[e]??[]).filter(a=>a.delivery!=="history"&&!t.some(o=>Ou(a,o)));de.value={...de.value,[e]:[...t,...s].slice(-50)}}function La(e,t){He.value={...He.value,[e]:t},qu(e,t.history)}function qo(e,t){const n=He.value[e];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};La(e,{...n,diagnostic:{...s,...t}})}async function Qi(){try{await es()}catch(e){console.warn("[keeper-runtime] dashboard refresh failed",e)}}function Fu(e){Iu.value=e.trim()}async function Xr(e,t=!1){const n=e.trim();if(!n)return null;if(!t&&He.value[n])return He.value[n];re(bi,n,!0),re(We,n,null);try{const s=await ut("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=Du(n,s,a);return La(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return re(We,n,a),null}finally{re(bi,n,!1)}}async function Ku(e,t){const n=e.trim(),s=t.trim();if(!n||!s)return;const a=`local-${Date.now()}`;Oo(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),re(ki,n,!0),re(We,n,null);try{const o=await Au(n,s);de.value={...de.value,[n]:(de.value[n]??[]).map(l=>l.id===a?{...l,delivery:"delivered"}:l)},Oo(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),qo(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await Qi()}catch(o){const l=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw de.value={...de.value,[n]:(de.value[n]??[]).map(c=>c.id===a?{...c,delivery:"error",error:l}:c)},qo(n,{last_reply_status:"error",last_error:l}),re(We,n,l),o}finally{re(ki,n,!1)}}async function Bu(e,t){const n=e.trim();if(!n)return null;re(xi,n,!0),re(We,n,null);try{const s=await Pa({actor:t,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=ju(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const l=He.value[n];La(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??de.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Qi(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw re(We,n,a),s}finally{re(xi,n,!1)}}async function Uu(e,t){const n=e.trim();if(!n)return null;re(Si,n,!0),re(We,n,null);try{const s=await Pa({actor:t,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Eu(s.result),o=(a==null?void 0:a.after)??null;if(o){const l=He.value[n];La(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??de.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Qi(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw re(We,n,a),s}finally{re(Si,n,!1)}}function $t(e){return(e??"").trim().toLowerCase()}function fe(e){const t=typeof e=="number"?e:Date.parse(e);return Number.isNaN(t)?0:t}function Ps(e,t=88){const n=e.replace(/\s+/g," ").trim();return n&&(n.length>t?`${n.slice(0,t-3)}...`:n)}function fs(e){return typeof e!="number"||!Number.isFinite(e)||e<0?null:new Date(Date.now()-e*1e3).toISOString()}function gn(e){return e.last_heartbeat??fs(e.last_turn_ago_s)??fs(e.last_proactive_ago_s)??fs(e.last_handoff_ago_s)??fs(e.last_compaction_ago_s)}function Hu(e){const t=e.title.trim();return t||Ps(e.content)}function Wu(e){const t=e.generation??"?",n=typeof e.context_ratio=="number"&&Number.isFinite(e.context_ratio)?`${Math.round(e.context_ratio*100)}%`:"?";return e.last_heartbeat?`Heartbeat gen=${t} ctx=${n}`:`Keeper snapshot gen=${t} ctx=${n}`}function Gu(e,t,n,s,a={}){var L;const o=$t(e),l=t.filter(T=>$t(T.assignee)===o&&(T.status==="claimed"||T.status==="in_progress")).length,c=n.filter(T=>$t(T.from)===o).sort((T,R)=>fe(R.timestamp)-fe(T.timestamp))[0],p=s.filter(T=>$t(T.agent)===o||$t(T.author)===o).sort((T,R)=>fe(R.timestamp)-fe(T.timestamp))[0],m=(a.boardPosts??[]).filter(T=>$t(T.author)===o).sort((T,R)=>fe(R.updated_at||R.created_at)-fe(T.updated_at||T.created_at))[0],u=(a.keepers??[]).filter(T=>$t(T.name)===o&&gn(T)!==null).sort((T,R)=>fe(gn(R)??0)-fe(gn(T)??0))[0],_=c?fe(c.timestamp):0,g=p?fe(p.timestamp):0,h=m?fe(m.updated_at||m.created_at):0,b=u?fe(gn(u)??0):0,$=a.lastSeen?fe(a.lastSeen):0,S=((L=a.currentTask)==null?void 0:L.trim())||(l>0?`${l} claimed tasks`:null);if(_===0&&g===0&&h===0&&b===0&&$===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:S};const x=[c?{timestamp:c.timestamp,ts:_,text:Ps(c.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:h,text:`Post: ${Ps(Hu(m))}`}:null,u?{timestamp:gn(u),ts:b,text:Wu(u)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:g,text:Ps(p.text)}:null].filter(T=>T!==null).sort((T,R)=>R.ts-T.ts)[0];return x&&x.ts>=$?{activeAssignedCount:l,lastActivityAt:x.timestamp,lastActivityText:x.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:S??"Presence heartbeat"}}const Ge=f([]),et=f([]),Ci=f([]),pt=f([]),te=f(null),Ju=f(null),Qr=f(null),Zr=f([]),el=f([]),tl=f([]),nl=f([]),sl=f([]),al=f([]),Ai=f(new Map),Ma=f([]),jn=f("recent"),St=f(!0),il=f(null),Ue=f(""),Jt=f([]),xn=f(!1),ol=f(new Map),Zi=f("unknown"),Vt=f(null),Ii=f(!1),En=f(!1),Ti=f(!1),Sn=f(!1),eo=f(null),Gs=f(!1),Js=f(null),rl=f(null),zi=f(null),Vu=f(null),Yu=f(null),Xu=f(null);Ie(()=>Ge.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle"));const ll=Ie(()=>{const e=et.value;return{todo:e.filter(t=>t.status==="todo"),inProgress:e.filter(t=>t.status==="in_progress"||t.status==="claimed"),done:e.filter(t=>t.status==="done")}}),cl=Ie(()=>{const e=new Map,t=et.value,n=Ci.value,s=Us.value,a=Ma.value,o=pt.value;for(const l of Ge.value)e.set(l.name.trim().toLowerCase(),Gu(l.name,t,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:o}));return e});function Qu(e){var o;const t=((o=e.status)==null?void 0:o.toLowerCase())??"";if(t==="offline"||t==="inactive")return"offline";const n=e.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}Ie(()=>{const e=new Map;for(const t of pt.value)e.set(t.name,Qu(t));return e});const Zu=12e4;function ep(e,t){const n=t.get(e.name);if(n!=null)return n;const s=e.last_heartbeat?Date.parse(e.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[e.last_turn_ago_s,e.last_proactive_ago_s,e.last_handoff_ago_s,e.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}Ie(()=>{const e=Date.now(),t=new Set,n=Ai.value;for(const s of pt.value){const a=ep(s,n);a!=null&&e-a>Zu&&t.add(s.name)}return t});function tp(e){return e==="dashboard_refresh"||e==="masc/dashboard_refresh"||e.startsWith("goal_")||e.startsWith("masc/goal_")||e.startsWith("mdal_")||e.startsWith("masc/mdal_")||e.startsWith("operator_")||e.startsWith("masc/operator_")||e.startsWith("command_plane_")||e.startsWith("masc/command_plane_")}function dl(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="active"||t==="busy"||t==="listening"||t==="idle"||t==="inactive"||t==="offline"?t:t==="in_progress"||t==="claimed"?"busy":"offline"}function np(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="todo"||t==="in_progress"||t==="claimed"||t==="done"||t==="cancelled"?t:t==="inprogress"?"in_progress":"todo"}function sp(e){if(!v(e))return null;const t=r(e.name);return t?{name:t,agent_type:r(e.agent_type),status:dl(e.status),current_task:r(e.current_task)??null,joined_at:r(e.joined_at),last_seen:r(e.last_seen),capabilities:H(e.capabilities),emoji:r(e.emoji),koreanName:r(e.koreanName)??r(e.korean_name),model:r(e.model),traits:H(e.traits),interests:H(e.interests),activityLevel:d(e.activityLevel)??d(e.activity_level),primaryValue:r(e.primaryValue)??r(e.primary_value)}:null}function ap(e){if(!v(e))return null;const t=r(e.id),n=r(e.title);return!t||!n?null:{id:t,title:n,status:np(e.status),priority:d(e.priority),assignee:r(e.assignee),description:r(e.description),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function ip(e){if(!v(e))return null;const t=r(e.from)??r(e.from_agent)??"system",n=r(e.content)??"",s=r(e.timestamp)??new Date().toISOString();return{id:r(e.id),seq:d(e.seq),from:t,content:n,timestamp:s,type:r(e.type)}}function to(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="ok"||t==="warn"||t==="bad"?t:"ok"}function op(e){return v(e)?{active_sessions:d(e.active_sessions),blocked_sessions:d(e.blocked_sessions),active_operations:d(e.active_operations),blocked_operations:d(e.blocked_operations),runtime_pressure:d(e.runtime_pressure),worker_alerts:d(e.worker_alerts),continuity_alerts:d(e.continuity_alerts),priority_items:d(e.priority_items),todo_tasks:d(e.todo_tasks),claimed_tasks:d(e.claimed_tasks),running_tasks:d(e.running_tasks),done_tasks:d(e.done_tasks),cancelled_tasks:d(e.cancelled_tasks),keepers:d(e.keepers)}:null}function tt(e){if(!v(e))return null;const t=r(e.surface),n=r(e.label),s=r(e.target_type),a=r(e.target_id),o=r(e.focus_kind);return!t||!n||!s||!a||!o?null:{surface:t==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:o,operation_id:r(e.operation_id)??null,command_surface:r(e.command_surface)??null}}function rp(e){if(!v(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.summary),a=r(e.target_type),o=r(e.target_id);return!t||!s||!a||!o||n!=="session"&&n!=="operation"?null:{id:t,kind:n,severity:to(e.severity),status:r(e.status),summary:s,target_type:a,target_id:o,linked_session_id:r(e.linked_session_id)??null,linked_operation_id:r(e.linked_operation_id)??null,last_seen_at:r(e.last_seen_at)??null,top_handoff:tt(e.top_handoff),intervene_handoff:tt(e.intervene_handoff),command_handoff:tt(e.command_handoff)}}function lp(e){if(!v(e))return null;const t=r(e.session_id),n=r(e.goal);return!t||!n?null:{session_id:t,goal:n,room:r(e.room)??null,status:r(e.status),health:r(e.health),member_names:H(e.member_names),linked_operation_id:r(e.linked_operation_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,runtime_blocker:r(e.runtime_blocker)??null,worker_gap_summary:r(e.worker_gap_summary)??null,last_activity_at:r(e.last_activity_at)??null,last_activity_summary:r(e.last_activity_summary)??null,communication_summary:r(e.communication_summary)??null,active_count:d(e.active_count),required_count:d(e.required_count),top_handoff:tt(e.top_handoff),intervene_handoff:tt(e.intervene_handoff),command_handoff:tt(e.command_handoff)}}function cp(e){if(!v(e))return null;const t=r(e.operation_id),n=r(e.objective);return!t||!n?null:{operation_id:t,objective:n,status:r(e.status),stage:r(e.stage)??null,assigned_unit_id:r(e.assigned_unit_id)??null,assigned_unit_label:r(e.assigned_unit_label)??null,linked_session_id:r(e.linked_session_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,blocker_summary:r(e.blocker_summary)??null,search_status:r(e.search_status)??null,next_tool:r(e.next_tool)??null,updated_at:r(e.updated_at)??null,top_handoff:tt(e.top_handoff),command_handoff:tt(e.command_handoff)}}function Fo(e){if(!v(e))return null;const t=r(e.name)??r(e.agent_name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline"?null:{name:t,agent_name:r(e.agent_name),status:r(e.status),tone:to(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,active_task_count:d(e.active_task_count),related_session_id:r(e.related_session_id)??null,related_operation_id:r(e.related_operation_id)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),model:r(e.model)??null,recent_output_preview:r(e.recent_output_preview)??null,recent_event:r(e.recent_event)??null}}function dp(e){if(!v(e))return null;const t=r(e.name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:t,agent_name:r(e.agent_name)??null,status:r(e.status),tone:to(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,last_autonomous_action_at:r(e.last_autonomous_action_at)??null,generation:d(e.generation),turn_count:d(e.turn_count),context_ratio:d(e.context_ratio)??null,continuity:r(e.continuity)??null,lifecycle:r(e.lifecycle)??null,related_session_id:r(e.related_session_id)??null,model:r(e.model)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),skill_reason:r(e.skill_reason)??null}}function Ko(e){if(typeof e.seq=="number"&&Number.isFinite(e.seq))return e.seq;const t=Date.parse(e.timestamp);return Number.isNaN(t)?0:t}function up(e,t){if(t.length===0)return e;const n=new Map;for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>Ko(s)-Ko(a)).slice(-500)}function pp(e){return Array.isArray(e)?e.map(t=>{if(!v(t))return null;const n=d(t.ts_unix);if(n==null)return null;const s=v(t.handoff)?t.handoff:null;return{ts:n,context_ratio:d(t.context_ratio)??0,context_tokens:d(t.context_tokens)??0,context_max:d(t.context_max)??0,latency_ms:d(t.latency_ms)??0,generation:d(t.generation)??0,channel:typeof t.channel=="string"?t.channel:"turn",is_handoff:s!=null&&t.handoff_performed===!0,is_compaction:t.compacted===!0,compaction_saved_tokens:d(t.compaction_saved_tokens)??0,compaction_trigger:typeof t.compaction_trigger=="string"?t.compaction_trigger:null,model_used:typeof t.model_used=="string"?t.model_used:"",cost_usd:d(t.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?d(s.new_generation)??null:null}}).filter(t=>t!==null):[]}function Bo(e){if(!v(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);if(!t||!n||!s)return null;const a=r(e.quiet_reason)??null,o=r(e.summary)??(t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:t,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:ae(e.last_reply_at)??r(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:typeof e.recoverable=="boolean"?e.recoverable:n==="recover",summary:o,keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function mp(e,t){return(Array.isArray(e)?e:v(e)&&Array.isArray(e.keepers)?e.keepers:[]).map(s=>{if(!v(s))return null;const a=v(s.agent)?s.agent:null,o=v(s.context)?s.context:null,l=v(s.metrics_window)?s.metrics_window:void 0,c=r(s.name);if(!c)return null;const p=d(s.context_ratio)??d(o==null?void 0:o.context_ratio),m=r(s.status)??r(a==null?void 0:a.status)??"offline",u=dl(m),_=r(s.model)??r(s.active_model)??r(s.primary_model),g=H(s.skill_secondary),h=o?{source:r(o.source),context_ratio:d(o.context_ratio),context_tokens:d(o.context_tokens),context_max:d(o.context_max),message_count:d(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,b=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:d(a.last_seen_ago_s),capabilities:H(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,$=pp(s.metrics_series),S={name:c,runtime_class:s.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:typeof s.desired=="boolean"?s.desired:void 0,resident_registered:typeof s.resident_registered=="boolean"?s.resident_registered:void 0,reconcile_status:r(s.reconcile_status)??null,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:_,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:u,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:d(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:d(s.proactive_idle_sec),proactive_cooldown_sec:d(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:d(s.generation),turn_count:d(s.turn_count)??d(s.total_turns),keeper_age_s:d(s.keeper_age_s),last_turn_ago_s:d(s.last_turn_ago_s),last_handoff_ago_s:d(s.last_handoff_ago_s),last_compaction_ago_s:d(s.last_compaction_ago_s),last_proactive_ago_s:d(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:p,context_tokens:d(s.context_tokens)??d(o==null?void 0:o.context_tokens),context_max:d(s.context_max)??d(o==null?void 0:o.context_max),context_source:r(s.context_source)??r(o==null?void 0:o.source),context:h,traits:H(s.traits),interests:H(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:d(s.activityLevel)??d(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:H(s.recent_tool_names)??[],conversation_tail_count:d(s.conversation_tail_count),k2k_count:d(s.k2k_count),handoff_count_total:d(s.handoff_count_total)??d(s.trace_history_count),compaction_count:d(s.compaction_count),last_compaction_saved_tokens:d(s.last_compaction_saved_tokens),diagnostic:Bo(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:g,skill_reason:r(s.skill_reason)??null,metrics_series:$.length>0?$:void 0,metrics_window:l,agent:b};return S.diagnostic=Bo(s.diagnostic)??Nu(S,(t==null?void 0:t.lodge)??null),S}).filter(s=>s!==null)}function vp(e){if(!v(e))return;const t=r(e.release_version),n=ae(e.started_at),s=d(e.uptime_seconds);if(!(!t||!n||s==null))return{release_version:t,commit:r(e.commit)??null,started_at:n,uptime_seconds:s}}function _p(e){if(v(e))return{enabled:e.enabled===!0,alive:e.alive===!0,status:r(e.status)??void 0,tick_in_progress:typeof e.tick_in_progress=="boolean"?e.tick_in_progress:void 0,tick_count:d(e.tick_count)??void 0,check_interval_sec:d(e.check_interval_sec)??void 0,last_tick_started_at:ae(e.last_tick_started_at)??r(e.last_tick_started_at)??null,last_tick_completed_at:ae(e.last_tick_completed_at)??r(e.last_tick_completed_at)??null,next_tick_due_at:ae(e.next_tick_due_at)??r(e.next_tick_due_at)??null,last_health_check_at:ae(e.last_health_check_at)??r(e.last_health_check_at)??null,last_intervention:r(e.last_intervention)??void 0,last_decision_source:r(e.last_decision_source)??void 0,last_action:r(e.last_action)??void 0,last_target:r(e.last_target)??null,last_reason:r(e.last_reason)??null,last_error:r(e.last_error)??null,circuit_open:typeof e.circuit_open=="boolean"?e.circuit_open:void 0,circuit_open_until:ae(e.circuit_open_until)??r(e.circuit_open_until)??null,can_spawn:typeof e.can_spawn=="boolean"?e.can_spawn:void 0,can_retire:typeof e.can_retire=="boolean"?e.can_retire:void 0,last_spawn_attempt_at:ae(e.last_spawn_attempt_at)??r(e.last_spawn_attempt_at)??null,last_retirement_attempt_at:ae(e.last_retirement_attempt_at)??r(e.last_retirement_attempt_at)??null,spawns_today:d(e.spawns_today)??void 0,retirements_today:d(e.retirements_today)??void 0,health_summary:v(e.health_summary)?{total_agents:d(e.health_summary.total_agents)??void 0,active_agents:d(e.health_summary.active_agents)??void 0,idle_agents:d(e.health_summary.idle_agents)??void 0,todo_count:d(e.health_summary.todo_count)??void 0,high_priority_todo:d(e.health_summary.high_priority_todo)??void 0,orphan_count:d(e.health_summary.orphan_count)??void 0,homeostatic_score:d(e.health_summary.homeostatic_score)??void 0,needs_workers:typeof e.health_summary.needs_workers=="boolean"?e.health_summary.needs_workers:void 0}:void 0}}function fp(e){if(v(e))return{enabled:e.enabled===!0,mode:r(e.mode)??void 0,masc_enabled:typeof e.masc_enabled=="boolean"?e.masc_enabled:void 0,masc_loops_running:typeof e.masc_loops_running=="boolean"?e.masc_loops_running:void 0,runtime_owner:r(e.runtime_owner)??null,zombie_loop_running:typeof e.zombie_loop_running=="boolean"?e.zombie_loop_running:void 0,gc_loop_running:typeof e.gc_loop_running=="boolean"?e.gc_loop_running:void 0,lodge_enabled:typeof e.lodge_enabled=="boolean"?e.lodge_enabled:void 0,lodge_loop_started:typeof e.lodge_loop_started=="boolean"?e.lodge_loop_started:void 0,lodge_running:typeof e.lodge_running=="boolean"?e.lodge_running:void 0,last_zombie_cleanup:ae(e.last_zombie_cleanup)??r(e.last_zombie_cleanup)??null,last_gc:ae(e.last_gc)??r(e.last_gc)??null,last_lodge:ae(e.last_lodge)??r(e.last_lodge)??null,last_zombie_result:r(e.last_zombie_result)??null,last_gc_result:r(e.last_gc_result)??null,last_lodge_result:v(e.last_lodge_result)?{ok:typeof e.last_lodge_result.ok=="boolean"?e.last_lodge_result.ok:void 0,message:r(e.last_lodge_result.message)??void 0}:null}}function gp(e){if(v(e))return{enabled:e.enabled===!0,started:e.started===!0,agent_name:r(e.agent_name)??null,llm_enabled:typeof e.llm_enabled=="boolean"?e.llm_enabled:void 0,uptime_s:d(e.uptime_s)??void 0,embedded_guardian_loops_running:typeof e.embedded_guardian_loops_running=="boolean"?e.embedded_guardian_loops_running:void 0,guardian_runtime_owner:r(e.guardian_runtime_owner)??null,consumers:H(e.consumers)}}function ul(e,t){return v(e)?{...e,generated_at:t??ae(e.generated_at)??void 0,build:vp(e.build),lodge:Mu(e.lodge)??void 0,gardener:_p(e.gardener)??void 0,guardian:fp(e.guardian)??void 0,sentinel:gp(e.sentinel)??void 0}:null}function pl(e,t){return t?e?{...e,...t,build:t.build??e.build,generated_at:t.generated_at??e.generated_at}:t:e}function $p(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="running"||t==="interrupted"||t==="completed"||t==="stopped"||t==="error"?t:t.startsWith("error")?"error":"running"}function hp(e){if(!v(e))return null;const t=d(e.iteration);if(t==null)return null;const n=d(e.metric_before)??0,s=d(e.metric_after)??n,a=v(e.evidence)?e.evidence:null;return{iteration:t,metric_before:n,metric_after:s,delta:d(e.delta)??s-n,changes:r(e.changes)??"",failed_attempts:r(e.failed_attempts)??"",next_suggestion:r(e.next_suggestion)??"",elapsed_ms:d(e.elapsed_ms)??0,cost_usd:d(e.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:d(a.tool_call_count)??0,tool_names:H(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function yp(e){var o,l;if(!v(e))return null;const t=r(e.loop_id);if(!t)return null;const n=d(e.baseline_metric)??0,s=Array.isArray(e.history)?e.history.map(hp).filter(c=>c!==null):[],a=d(e.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:t,profile:r(e.profile)??"unknown",status:$p(e.status),strict_mode:typeof e.strict_mode=="boolean"?e.strict_mode:void 0,error_message:r(e.error_message)??r(e.error_reason)??null,stop_reason:r(e.stop_reason)??r(e.reason)??null,current_iteration:d(e.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:d(e.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(e.target)??"",stagnation_streak:d(e.stagnation_streak)??0,stagnation_limit:d(e.stagnation_limit)??0,elapsed_seconds:d(e.elapsed_seconds)??0,updated_at:ae(e.updated_at)??null,stopped_at:ae(e.stopped_at)??null,execution_mode:e.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:e.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(e.worker_model)??null,evidence_policy:e.evidence_policy==="hard"||e.evidence_policy==="legacy"?e.evidence_policy:void 0,latest_tool_call_count:d(e.latest_tool_call_count)??0,latest_tool_names:H(e.latest_tool_names)??[],session_id:r(e.session_id)??null,evidence_status:e.evidence_status==="legacy_unverified"?"legacy_unverified":e.evidence_status==="verified"?"verified":null,durability:e.durability==="persistent_backend"||e.durability==="memory_only"?e.durability:void 0,persistence_backend:e.persistence_backend==="filesystem"||e.persistence_backend==="postgres"||e.persistence_backend==="memory"?e.persistence_backend:void 0,recoverable:typeof e.recoverable=="boolean"?e.recoverable:void 0,history:s}}async function es(){Ii.value=!0;try{await Promise.all([vl(),Ct()]),rl.value=new Date().toISOString()}catch(e){console.error("Dashboard refresh error:",e)}finally{Ii.value=!1}}async function ml(){Gs.value=!0,Js.value=null;try{const e=await Ad();eo.value=e,Xu.value=new Date().toISOString()}catch(e){Js.value=e instanceof Error?e.message:"Failed to load dashboard semantics"}finally{Gs.value=!1}}function bp(e){var t;return((t=eo.value)==null?void 0:t.surfaces.find(n=>n.id===e))??null}function kp(e){var n;const t=((n=eo.value)==null?void 0:n.surfaces)??[];for(const s of t){const a=s.panels.find(o=>o.id===e);if(a)return a}return null}function xp(e){var s,a;Jt.value=(Array.isArray(e.goals)?e.goals:[]).map(o=>{if(!v(o))return null;const l=r(o.id),c=r(o.title),p=r(o.horizon),m=r(o.status),u=r(o.created_at),_=r(o.updated_at);return!l||!c||!p||!m||!u||!_?null:{id:l,horizon:p,title:c,metric:r(o.metric)??null,target_value:r(o.target_value)??null,due_date:r(o.due_date)??null,priority:d(o.priority)??3,status:m,parent_goal_id:r(o.parent_goal_id)??null,last_review_note:r(o.last_review_note)??null,last_review_at:r(o.last_review_at)??null,created_at:u,updated_at:_}}).filter(o=>o!==null);const t=new Map,n=Array.isArray((s=e.mdal)==null?void 0:s.loops)?e.mdal.loops:[];for(const o of n){const l=yp(o);l&&t.set(l.loop_id,l)}ol.value=t,Vt.value=typeof((a=e.mdal)==null?void 0:a.error)=="string"?e.mdal.error:null,Zi.value=Vt.value?"error":t.size===0?"idle":"ready"}async function vl(){try{const e=await kd(),t=ul(e.status,e.generated_at);t&&(te.value=pl(te.value,t))}catch(e){console.error("Dashboard shell fetch error:",e)}}async function Ct(){var e;try{const t=await xd(),n=ul(t.status,t.generated_at),s=(e=te.value)==null?void 0:e.room;n&&(te.value=pl(te.value,n));const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Ge.value=(Array.isArray(t.agents)?t.agents:[]).map(sp).filter(l=>l!==null),et.value=(Array.isArray(t.tasks)?t.tasks:[]).map(ap).filter(l=>l!==null);const o=(Array.isArray(t.messages)?t.messages:[]).map(ip).filter(l=>l!==null);Ci.value=a?o:up(Ci.value,o),pt.value=mp(t.keepers,n??te.value),Qr.value=op(t.summary),Zr.value=(Array.isArray(t.execution_queue)?t.execution_queue:Array.isArray(t.priority_queue)?t.priority_queue:[]).map(rp).filter(l=>l!==null),el.value=(Array.isArray(t.session_briefs)?t.session_briefs:[]).map(lp).filter(l=>l!==null),tl.value=(Array.isArray(t.operation_briefs)?t.operation_briefs:[]).map(cp).filter(l=>l!==null),nl.value=(Array.isArray(t.worker_support_briefs)?t.worker_support_briefs:Array.isArray(t.worker_briefs)?t.worker_briefs:[]).map(Fo).filter(l=>l!==null),sl.value=(Array.isArray(t.continuity_briefs)?t.continuity_briefs:[]).map(dp).filter(l=>l!==null),al.value=(Array.isArray(t.offline_worker_briefs)?t.offline_worker_briefs:[]).map(Fo).filter(l=>l!==null),Ju.value=null,rl.value=new Date().toISOString()}catch(t){console.error("Dashboard execution fetch error:",t)}}async function nt(){En.value=!0;try{const e=await Sd(jn.value,{excludeSystem:St.value});Ma.value=e.posts??[],zi.value=new Date().toISOString()}catch(e){console.error("Board fetch error:",e)}finally{En.value=!1}}async function st(){var e;Ti.value=!0;try{const t=Ue.value||((e=te.value)==null?void 0:e.room)||"default";Ue.value||(Ue.value=t);const n=await uu(t);il.value=n}catch(t){console.error("TRPG fetch error:",t)}finally{Ti.value=!1}}async function no(){xn.value=!0,Sn.value=!0;try{const e=await Pd();xp(e),Vu.value=new Date().toISOString(),Yu.value=new Date().toISOString()}catch(e){console.error("Planning fetch error:",e),Zi.value="error",Vt.value=e instanceof Error?e.message:String(e)}finally{xn.value=!1,Sn.value=!1}}async function _l(){return no()}let Ls=null;function Sp(e){Ls=e}let Ms=null;function Cp(e){Ms=e}let js=null;function Ap(e){js=e}const At={};let Ba=null;function ht(e,t,n=500){At[e]&&clearTimeout(At[e]),At[e]=setTimeout(()=>{t(),delete At[e]},n)}function Ip(){const e=jr.subscribe(t=>{if(t){if(t.type==="keeper_heartbeat"&&t.name){const n=new Map(Ai.value);n.set(t.name,t.ts_unix?t.ts_unix*1e3:Date.now()),Ai.value=n;return}(t.type==="agent_joined"||t.type==="agent_left")&&ht("execution",Ct),tp(t.type)&&(Ba||(Ba=setTimeout(()=>{es(),Ms==null||Ms(),js==null||js(),Ba=null},500))),(t.type.startsWith("task_")||t.type.startsWith("masc/task_"))&&ht("execution",Ct),t.type==="broadcast"&&ht("execution",Ct),(t.type==="keeper_handoff"||t.type==="keeper_compaction"||t.type==="keeper_guardrail")&&ht("execution",Ct),(t.type==="board_post"||t.type==="masc/board_post"||t.type==="board_comment"||t.type==="masc/board_comment")&&ht("board",nt),t.type.startsWith("decision_")&&ht("council",()=>Ls==null?void 0:Ls()),(t.type==="mdal_started"||t.type==="mdal_iteration"||t.type==="mdal_completed"||t.type==="mdal_stopped")&&ht("mdal",_l,350)}});return()=>{e();for(const t of Object.keys(At))clearTimeout(At[t]),delete At[t]}}let Cn=null;function Tp(){Cn||(Cn=setInterval(()=>{rt.value,es()},1e4))}function zp(){Cn&&(clearInterval(Cn),Cn=null)}function Rp({metric:e}){return i`
    <article class="semantic-metric-row">
      <div class="semantic-metric-head">
        <strong>${e.label}</strong>
        <span class="semantic-code">${e.id}</span>
      </div>
      <p>${e.what_it_measures}</p>
      <div class="semantic-grid compact">
        <span>이유</span><span>${e.why_it_exists}</span>
        <span>근거 경로</span><span>${e.source_path}</span>
        <span>갱신 조건</span><span>${e.update_trigger}</span>
        <span>에이전트 영향</span><span>${e.agent_behavior_effect}</span>
        <span>생태계 영향</span><span>${e.ecosystem_effect}</span>
        <span>해석</span><span>${e.interpretation}</span>
        <span>나쁜 냄새</span><span>${e.bad_smell}</span>
        <span>다음 액션</span><span>${e.next_action}</span>
      </div>
    </article>
  `}function Pp({panel:e}){return i`
    <div class="semantic-body">
      <div class="semantic-grid">
        <span>목적</span><span>${e.purpose}</span>
        <span>무엇을 푸나</span><span>${e.problem_solved}</span>
        <span>언제 보나</span><span>${e.when_active}</span>
        <span>에이전트 역할</span><span>${e.agent_role}</span>
        <span>생태계 기능</span><span>${e.ecosystem_function}</span>
      </div>
      ${e.related_tools.length>0?i`<div class="semantic-tag-row">
            ${e.related_tools.map(t=>i`<span class="semantic-tag">${t}</span>`)}
          </div>`:null}
      ${e.metrics.length>0?i`<div class="semantic-metric-list">
            ${e.metrics.map(t=>i`<${Rp} key=${t.id} metric=${t} />`)}
          </div>`:null}
    </div>
  `}function O({panelId:e,compact:t=!1,label:n="왜 필요한가"}){const s=kp(e);return s?i`
    <details class="semantic-inline ${t?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${Pp} panel=${s} />
    </details>
  `:Gs.value?i`<span class="semantic-inline-state">의미 계층 불러오는 중…</span>`:null}function be({surfaceId:e,compact:t=!1}){const n=bp(e);return n?i`
    <section class="semantic-surface-card ${t?"compact":""}">
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
  `:Gs.value?i`<div class="semantic-surface-card ${t?"compact":""}">의미 계층 불러오는 중…</div>`:Js.value?i`<div class="semantic-surface-card ${t?"compact":""}">${Js.value}</div>`:null}function I({title:e,class:t,semanticId:n,testId:s,children:a}){return i`
    <div class="card ${t??""}" data-testid=${s}>
      ${e?i`
            <div class="card-title-row">
              <div class="card-title">${e}</div>
              ${n?i`<${O} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}const ts=f(null),Ri=f(!1),Vs=f(null),fl=f(null),qt=f(!1),xt=f(null),Pi=f(null),Es=f(!1),Ns=f(null);let Yt=null;function Uo(){Yt!==null&&(window.clearTimeout(Yt),Yt=null)}function Lp(e=1500){Yt===null&&(Yt=window.setTimeout(()=>{Yt=null,Ys(!1)},e))}function w(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function y(e){return typeof e=="string"&&e.trim()!==""?e:void 0}function D(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function Xt(e){return typeof e=="boolean"?e:void 0}function U(e,t=[]){if(Array.isArray(e))return e;if(!w(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function pn(e){if(!w(e))return null;const t=y(e.kind),n=y(e.summary),s=y(e.target_type);return!t||!n||!s?null:{kind:t,severity:y(e.severity)??"warn",summary:n,target_type:s,target_id:y(e.target_id)??null,actor:y(e.actor)??null,evidence:e.evidence}}function Lt(e){if(!w(e))return null;const t=y(e.action_type),n=y(e.target_type),s=y(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:y(e.target_id)??null,severity:y(e.severity)??"warn",reason:s,confirm_required:Xt(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function Mp(e){if(!w(e))return null;const t=y(e.session_id);return t?{session_id:t,goal:y(e.goal),status:y(e.status),health:y(e.health),scale_profile:y(e.scale_profile),control_profile:y(e.control_profile),planned_worker_count:D(e.planned_worker_count),active_agent_count:D(e.active_agent_count),last_turn_age_sec:D(e.last_turn_age_sec)??null,attention_count:D(e.attention_count),recommended_action_count:D(e.recommended_action_count),top_attention:pn(e.top_attention),top_recommendation:Lt(e.top_recommendation)}:null}function jp(e){if(!w(e))return null;const t=y(e.session_id);if(!t)return null;const n=w(e.status)?e.status:e,s=w(n.summary)?n.summary:void 0;return{session_id:t,status:y(e.status)??y(s==null?void 0:s.status)??(w(n.session)?y(n.session.status):void 0),progress_pct:D(e.progress_pct)??D(s==null?void 0:s.progress_pct),elapsed_sec:D(e.elapsed_sec)??D(s==null?void 0:s.elapsed_sec),remaining_sec:D(e.remaining_sec)??D(s==null?void 0:s.remaining_sec),done_delta_total:D(e.done_delta_total)??D(s==null?void 0:s.done_delta_total),summary:w(e.summary)?e.summary:s,team_health:w(e.team_health)?e.team_health:w(n.team_health)?n.team_health:void 0,communication_metrics:w(e.communication_metrics)?e.communication_metrics:w(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:w(e.orchestration_state)?e.orchestration_state:w(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:w(e.cascade_metrics)?e.cascade_metrics:w(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:w(e.report_paths)?Object.fromEntries(Object.entries(e.report_paths).map(([a,o])=>{const l=y(o);return l?[a,l]:null}).filter(a=>a!==null)):w(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const l=y(o);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:w(e.session)?e.session:w(n.session)?n.session:void 0,recent_events:U(e.recent_events,["events"]).filter(w)}}function Ep(e){if(!w(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name),status:y(e.status),autonomy_level:y(e.autonomy_level),context_ratio:D(e.context_ratio),generation:D(e.generation),active_goal_ids:U(e.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:y(e.last_autonomous_action_at)??null,last_turn_ago_s:D(e.last_turn_ago_s),model:y(e.model)}:null}function Np(e){if(!w(e))return null;const t=y(e.confirm_token)??y(e.token);return t?{confirm_token:t,actor:y(e.actor),action_type:y(e.action_type),target_type:y(e.target_type),target_id:y(e.target_id)??null,delegated_tool:y(e.delegated_tool),created_at:y(e.created_at),preview:e.preview}:null}function wp(e){if(!w(e))return null;const t=y(e.action_type),n=y(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:y(e.description),confirm_required:Xt(e.confirm_required)}}function Dp(e){const t=w(e)?e:{};return{room_health:y(t.room_health),cluster:y(t.cluster),project:y(t.project),current_room:y(t.current_room)??null,paused:Xt(t.paused),tempo_interval_s:D(t.tempo_interval_s),active_agents:D(t.active_agents),keeper_pressure:D(t.keeper_pressure),active_operations:D(t.active_operations),pending_approvals:D(t.pending_approvals),incident_count:D(t.incident_count),recommended_action_count:D(t.recommended_action_count),top_attention:pn(t.top_attention),top_action:Lt(t.top_action)}}function Op(e){const t=w(e)?e:{},n=w(t.swarm_overview)?t.swarm_overview:{};return{health:y(t.health),active_operations:D(t.active_operations),pending_approvals:D(t.pending_approvals),swarm_overview:{active_lanes:D(n.active_lanes),moving_lanes:D(n.moving_lanes),stalled_lanes:D(n.stalled_lanes),projected_lanes:D(n.projected_lanes),last_movement_at:y(n.last_movement_at)??null},top_attention:pn(t.top_attention),top_action:Lt(t.top_action),session_cards:U(t.session_cards).map(Mp).filter(s=>s!==null)}}function qp(e){const t=w(e)?e:{};return{sessions:U(t.sessions,["items"]).map(jp).filter(n=>n!==null),keepers:U(t.keepers,["items"]).map(Ep).filter(n=>n!==null),pending_confirms:U(t.pending_confirms).map(Np).filter(n=>n!==null),available_actions:U(t.available_actions).map(wp).filter(n=>n!==null)}}function Fp(e){if(!w(e))return null;const t=y(e.id),n=y(e.kind),s=y(e.summary),a=y(e.target_type);return!t||!n||!s||!a?null:{id:t,kind:n,severity:y(e.severity)??"warn",summary:s,target_type:a,target_id:y(e.target_id)??null,top_action:Lt(e.top_action),related_session_ids:U(e.related_session_ids).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),related_agent_names:U(e.related_agent_names).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),evidence_preview:U(e.evidence_preview).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),last_seen_at:y(e.last_seen_at)??null}}function gl(e){if(!w(e))return null;const t=y(e.session_id),n=y(e.goal);return!t||!n?null:{session_id:t,goal:n,room:y(e.room)??null,status:y(e.status),health:y(e.health),member_names:U(e.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:y(e.started_at)??null,elapsed_sec:D(e.elapsed_sec)??null,operation_id:y(e.operation_id)??null,blocker_summary:y(e.blocker_summary)??null,last_event_at:y(e.last_event_at)??null,last_event_summary:y(e.last_event_summary)??null,communication_summary:y(e.communication_summary)??null,active_count:D(e.active_count),required_count:D(e.required_count),related_attention_count:D(e.related_attention_count)??0,top_attention:pn(e.top_attention),top_recommendation:Lt(e.top_recommendation)}}function $l(e){if(!w(e))return null;const t=y(e.agent_name);return t?{agent_name:t,status:y(e.status),current_work:y(e.current_work)??null,recent_input_preview:y(e.recent_input_preview)??null,recent_output_preview:y(e.recent_output_preview)??null,recent_tool_names:U(e.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_activity_at:y(e.last_activity_at)??null}:null}function hl(e){if(!w(e))return null;const t=y(e.operation_id);return t?{operation_id:t,status:y(e.status),stage:y(e.stage)??null,detachment_status:y(e.detachment_status)??null,objective:y(e.objective)??null,updated_at:y(e.updated_at)??null}:null}function yl(e){if(!w(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name)??null,status:y(e.status),generation:D(e.generation),context_ratio:D(e.context_ratio)??null,last_turn_ago_s:D(e.last_turn_ago_s)??null,current_work:y(e.current_work)??null}:null}function bl(e){const t=gl(e);return t?{...t,member_previews:U(w(e)?e.member_previews:void 0).map($l).filter(n=>n!==null),operation_badges:U(w(e)?e.operation_badges:void 0).map(hl).filter(n=>n!==null),keeper_refs:U(w(e)?e.keeper_refs:void 0).map(yl).filter(n=>n!==null)}:null}function Kp(e){if(!w(e))return null;const t=y(e.agent_name);return t?{agent_name:t,status:y(e.status),where:y(e.where)??null,with_whom:U(e.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:y(e.current_work)??null,related_session_id:y(e.related_session_id)??null,related_attention_count:D(e.related_attention_count)??0,last_activity_at:y(e.last_activity_at)??null,recent_output_preview:y(e.recent_output_preview)??null,recent_input_preview:y(e.recent_input_preview)??null,recent_event:y(e.recent_event)??null,recent_tool_names:U(e.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),allowed_tool_names:U(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:U(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:D(e.latest_tool_call_count)??null,tool_audit_source:y(e.tool_audit_source)??null,tool_audit_at:y(e.tool_audit_at)??null}:null}function Bp(e){if(!w(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name)??null,status:y(e.status),generation:D(e.generation),context_ratio:D(e.context_ratio)??null,last_turn_ago_s:D(e.last_turn_ago_s)??null,current_work:y(e.current_work)??null,last_autonomous_action_at:y(e.last_autonomous_action_at)??null,allowed_tool_names:U(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:U(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:D(e.latest_tool_call_count)??null,tool_audit_source:y(e.tool_audit_source)??null,tool_audit_at:y(e.tool_audit_at)??null}:null}function Up(e){if(!w(e))return null;const t=y(e.id),n=y(e.signal_type),s=y(e.summary),a=y(e.target_type);return!t||!n||!s||!a?null:{id:t,signal_type:n==="action"?"action":"attention",severity:y(e.severity)??"warn",summary:s,target_type:a,target_id:y(e.target_id)??null,attention:pn(e.attention),action:Lt(e.action)}}function Hp(e){const t=w(e)?e:{},n=U(t.session_briefs).map(gl).filter(a=>a!==null),s=U(t.sessions).map(bl).filter(a=>a!==null);return{generated_at:y(t.generated_at),summary:Dp(t.summary),incidents:U(t.incidents).map(pn).filter(a=>a!==null),recommended_actions:U(t.recommended_actions).map(Lt).filter(a=>a!==null),command_focus:Op(t.command_focus),operator_targets:qp(t.operator_targets),attention_queue:U(t.attention_queue).map(Fp).filter(a=>a!==null),sessions:s.length>0?s:n.map(a=>({...a,member_previews:[],operation_badges:[],keeper_refs:[]})),session_briefs:n,agent_briefs:U(t.agent_briefs).map(Kp).filter(a=>a!==null),keeper_briefs:U(t.keeper_briefs).map(Bp).filter(a=>a!==null),internal_signals:U(t.internal_signals).map(Up).filter(a=>a!==null)}}function Wp(e){if(!w(e))return null;const t=y(e.id),n=y(e.summary);return!t||!n?null:{id:t,timestamp:y(e.timestamp)??null,event_type:y(e.event_type),actor:y(e.actor)??null,summary:n}}function Gp(e){const t=w(e)?e:{};return{generated_at:y(t.generated_at),session_id:y(t.session_id)??"",session:bl(t.session),timeline:U(t.timeline).map(Wp).filter(n=>n!==null),participants:U(t.participants).map($l).filter(n=>n!==null),operations:U(t.operations).map(hl).filter(n=>n!==null),keepers:U(t.keepers).map(yl).filter(n=>n!==null),error:y(t.error)??null}}function Jp(e){if(!w(e))return null;const t=y(e.id),n=y(e.label),s=y(e.summary);if(!t||!n||!s)return null;const a=y(e.status)??"unclear";return{id:t,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:y(e.signal_class)==="metadata_gap"||y(e.signal_class)==="mixed"||y(e.signal_class)==="operational_risk"?y(e.signal_class):void 0,evidence_quality:y(e.evidence_quality)==="strong"||y(e.evidence_quality)==="partial"||y(e.evidence_quality)==="missing"?y(e.evidence_quality):void 0,evidence:U(e.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function Vp(e){if(!w(e))return null;const t=y(e.kind),n=y(e.summary),s=y(e.scope_type),a=y(e.severity);return!t||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:t,summary:n,scope_type:s,scope_id:y(e.scope_id)??null,severity:a}}function Yp(e){const t=w(e)?e:{},n=w(t.basis)?t.basis:{},s=y(t.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:y(t.generated_at),cached:Xt(t.cached),stale:Xt(t.stale),refreshing:Xt(t.refreshing),status:a,summary:y(t.summary)??null,model:y(t.model)??null,ttl_sec:D(t.ttl_sec),criteria:U(t.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:y(n.current_room)??null,crew_count:D(n.crew_count),agent_count:D(n.agent_count),keeper_count:D(n.keeper_count)},metadata_gap_count:D(t.metadata_gap_count),metadata_gaps:U(t.metadata_gaps).map(Vp).filter(o=>o!==null),sections:U(t.sections).map(Jp).filter(o=>o!==null),error:y(t.error)??null,last_error:y(t.last_error)??null}}async function kl(){Ri.value=!0,Vs.value=null;try{const e=await Id();ts.value=Hp(e)}catch(e){Vs.value=e instanceof Error?e.message:"Failed to load mission snapshot"}finally{Ri.value=!1}}async function Xp(e){if(!e){Pi.value=null,Ns.value=null,Es.value=!1;return}Es.value=!0,Ns.value=null;try{const t=await Td(e);Pi.value=Gp(t)}catch(t){Ns.value=t instanceof Error?t.message:"Failed to load session detail"}finally{Es.value=!1}}async function Ys(e=!1){qt.value=!0,xt.value=null;try{const t=await zd(e),n=Yp(t);fl.value=n,n.refreshing||n.status==="pending"?Lp():Uo()}catch(t){xt.value=t instanceof Error?t.message:"Failed to load mission briefing",Uo()}finally{qt.value=!1}}const Xs="masc_dashboard_workflow_context",Qp=900*1e3;function ge(e){return typeof e=="string"&&e.trim()!==""?e.trim():null}function Ve(e){const t=ge(e);return t||(typeof e=="number"&&Number.isFinite(e)?String(e):null)}function xl(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function Li(e){return v(e)?e:null}function Zp(e){if(!e)return null;try{return JSON.stringify(e)}catch{return null}}function em(e){if(!e)return null;try{const t=JSON.parse(e);if(!v(t))return null;const n=ge(t.id),s=ge(t.source_surface),a=ge(t.source_label),o=ge(t.summary),l=ge(t.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!o||!l?null:{id:n,source_surface:s,source_label:a,action_type:ge(t.action_type),target_type:ge(t.target_type),target_id:ge(t.target_id),focus_kind:ge(t.focus_kind),operation_id:ge(t.operation_id),command_surface:ge(t.command_surface),summary:o,payload_preview:ge(t.payload_preview),suggested_payload:Li(t.suggested_payload),preview:t.preview??null,evidence:t.evidence??null,created_at:l}}catch{return null}}function so(e){const t=Date.parse(e.created_at);return Number.isNaN(t)?!1:Date.now()-t<=Qp}function tm(){const e=xl(),t=em((e==null?void 0:e.getItem(Xs))??null);return t?so(t)?t:(e==null||e.removeItem(Xs),null):null}const Sl=f(tm());function Cl(e){const t=e&&so(e)?e:null;Sl.value=t;const n=xl();if(!n)return;if(!t){n.removeItem(Xs);return}const s=Zp(t);s&&n.setItem(Xs,s)}function nm(e){if(!e)return null;const t=Li(e.suggested_payload);if(t)return t;if(v(e.preview)){const n=Li(e.preview.payload);if(n)return n}return null}function sm(e){if(!e)return null;const t=Ve(e.message);if(t)return t;const n=Ve(e.task_title)??Ve(e.title),s=Ve(e.task_description)??Ve(e.description),a=Ve(e.reason),o=Ve(e.priority)??Ve(e.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function ao(e,t,n,s,a,o,l,c){return[e,t,n??"action",s??"target",a??"room",o??"focus",l??"operation",c].join(":")}function mn(e,t,n="상황판 추천 액션"){const s=new Date().toISOString(),a=nm(e),o=(e==null?void 0:e.target_type)??(t==null?void 0:t.target_type)??null,l=(e==null?void 0:e.target_id)??(t==null?void 0:t.target_id)??null,c=(t==null?void 0:t.kind)??(e==null?void 0:e.action_type)??null,p=(e==null?void 0:e.reason)??(t==null?void 0:t.summary)??n;return{id:ao("mission",n,(e==null?void 0:e.action_type)??null,o,l,c,null,s),source_surface:"mission",source_label:n,action_type:(e==null?void 0:e.action_type)??null,target_type:o,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:p,payload_preview:sm(a),suggested_payload:a,preview:(e==null?void 0:e.preview)??null,evidence:(t==null?void 0:t.evidence)??null,created_at:s}}function am({targetType:e,targetId:t,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:o=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:ao("execution",s,null,e,t,n,o,c),source_surface:"execution",source_label:s,action_type:null,target_type:e,target_id:t,focus_kind:n,operation_id:o,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function im(e,t){return(t.source==="mission"||t.source==="execution")&&(t.action_type??null)===(e.action_type??null)&&(t.target_type??null)===(e.target_type??null)&&(t.target_id??null)===(e.target_id??null)&&(t.focus_kind??null)===(e.focus_kind??null)&&(t.operation_id??null)===(e.operation_id??null)}function ns(e){const{params:t}=e;if(t.source!=="mission"&&t.source!=="execution")return null;const n=Sl.value;if(n&&so(n)&&im(n,t))return n;const s=new Date().toISOString(),a=t.source==="execution"?"execution":"mission";return{id:ao(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",t.action_type??null,t.target_type??null,t.target_id??null,t.focus_kind??null,t.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:t.action_type??null,target_type:t.target_type??null,target_id:t.target_id??null,focus_kind:t.focus_kind??t.action_type??null,operation_id:t.operation_id??null,command_surface:t.surface??null,summary:a==="execution"?t.focus_kind?`${t.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":t.focus_kind?`${t.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function Al(e){return{source:e.source_surface,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function Il(e){if(e.command_surface)return e.command_surface;const t=[e.focus_kind,e.summary,e.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"summary":t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")||t.includes("swarm")?"swarm":e.focus_kind==="operation"||e.target_type==="operation"?"operations":e.target_type==="room"?"orchestra":"swarm"}function Tl(e){return{source:e.source_surface,surface:Il(e),...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function om(e){return Al(e)}function rm(e){return Tl(e)}function io(e){return e!=null&&e.target_type?e.target_id?`${e.target_type} · ${e.target_id}`:e.target_type:"대상 정보 없음"}function ja(e){switch(e){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(e==null?void 0:e.trim())||"추천 액션"}}function lm(e){switch(e){case"warroom":return"워룸";case"summary":return"요약";case"orchestra":return"오케스트라";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(e==null?void 0:e.trim())||"지휘"}}const Be=f(null),Ze=f(null);function Re(e,t=120){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-1)}…`:n:null}function ve(e){return e==="bad"||e==="offline"||e==="critical"||e==="risk"?"bad":e==="warn"||e==="pending"||e==="degraded"||e==="interrupted"||e==="watch"?"warn":"ok"}function Ne(e){if(!e)return"방금";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function cm(e){return typeof e!="number"||!Number.isFinite(e)||e<0?"확인 필요":e<60?`${Math.round(e)}초`:e<3600?`${Math.round(e/60)}분`:e<86400?`${Math.round(e/3600)}시간`:`${Math.round(e/86400)}일`}function we(e){switch((e??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"pending":return"대기 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":case"watch":return"주의";case"bad":case"critical":case"risk":return"위험";case"degraded":return"저하";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"loading":return"불러오는 중";case"error":return"오류";case"unavailable":return"사용 불가";case"stale":return"오래됨";case"refreshing":return"갱신 중";case"cached":return"캐시";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function Qs(e){switch((e??"").trim().toLowerCase()){case"room":return"방";case"team_session":case"session":return"세션";case"operation":return"작전";case"keeper":return"키퍼";case"agent":return"에이전트";default:return(e==null?void 0:e.trim())||"대상"}}function Ho(e){switch((e??"").trim().toLowerCase()){case"metadata_gap":return"메타데이터 부족";case"mixed":return"신호 혼재";case"":return null;default:return(e==null?void 0:e.trim())||null}}function dm(e){return e!=null&&e.confirm_required?"확인 후 실행":"즉시 실행"}function um(e){return io(e?mn(e,null,"상황판 추천 액션"):null)}function Ea(e,t=mn()){Cl(t),se(e,e==="intervene"?om(t):rm(t))}function zl(e){Ea("intervene",mn(null,e,"상황판 incident"))}function Rl(e){Ea("command",mn(null,e,"상황판 incident"))}function oo(e,t,n="상황판 추천 액션"){Ea("intervene",mn(e,t,n))}function Pl(e,t,n="상황판 추천 액션"){Ea("command",mn(e,t,n))}function Mi(e,t){const n={source:"mission",target_type:"team_session",target_id:t,focus_kind:"team_session"};e==="command"&&(n.surface="swarm"),se(e,n)}function pm(e){return{kind:e.kind,severity:e.severity,summary:e.summary,target_type:e.target_type,target_id:e.target_id??null,actor:null,evidence:e.evidence_preview}}function mm(e){var n,s;const t=pt.value.find(a=>a.name===e.name||a.agent_name===e.agent_name)??null;return{brief:e,keeper:t,currentWork:Re(e.current_work,110)??Re(t==null?void 0:t.skill_primary,110)??Re(t==null?void 0:t.last_proactive_reason,110)??"명시된 키퍼 초점 없음",recentInput:Re(t==null?void 0:t.recent_input_preview,120)??null,recentOutput:Re(t==null?void 0:t.recent_output_preview,120)??Re((n=t==null?void 0:t.diagnostic)==null?void 0:n.last_reply_preview,120)??Re(t==null?void 0:t.last_proactive_preview,120)??null,recentEvent:Re(t==null?void 0:t.last_proactive_reason,120)??Re((s=t==null?void 0:t.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(t==null?void 0:t.recent_tool_names)??[]}}function vm(){const e=ts.value;if(!e)return new Map;const t=e.sessions.length>0?e.sessions:e.session_briefs;return new Map(t.map(n=>[n.session_id,n]))}function _m(e){Be.value=Be.value===e?null:e,Ze.value=null}function Ll(e){Ze.value=Ze.value===e?null:e,Be.value=null}function fm(){Be.value=null,Ze.value=null}function gm(e){switch(e.trim().toLowerCase()){case"active":case"running":return"가동 중";case"working":return"작업 중";case"watching":return"관찰 중";case"quiet":return"조용함";case"idle":return"유휴";case"ok":case"healthy":return"정상";case"warn":case"warning":case"degraded":return"주의";case"bad":case"critical":case"error":case"failed":return"위험";case"blocked":return"막힘";case"paused":return"일시정지";case"pending":return"대기";case"offline":case"inactive":return"오프라인";case"connected":return"연결됨";case"disconnected":return"끊김";case"ready":return"준비됨";case"done":case"completed":return"완료";case"unknown":return"알 수 없음";default:return e}}function mt({status:e,label:t}){return i`
    <span class="status-badge ${e}">
      <span class="status-dot-inline ${e}"></span>
      ${t??gm(e)}
    </span>
  `}function Ml(e){const t=Date.now(),n=typeof e=="number"?e<1e12?e*1e3:e:new Date(e).getTime(),s=Math.floor((t-n)/1e3);if(s<60)return`${s}초 전`;const a=Math.floor(s/60);if(a<60)return`${a}분 전`;const o=Math.floor(a/60);return o<24?`${o}시간 전`:`${Math.floor(o/24)}일 전`}function J({timestamp:e}){const t=Ml(e),n=typeof e=="string"?e:new Date(e<1e12?e*1e3:e).toISOString();return i`<span class="time-ago" title=${n}>${t}</span>`}let $m=0;const It=f([]);function E(e,t="success",n=4e3){const s=++$m;It.value=[...It.value,{id:s,message:e,type:t}],setTimeout(()=>{It.value=It.value.filter(a=>a.id!==s)},n)}function hm(e){It.value=It.value.filter(t=>t.id!==e)}function ym(){const e=It.value;return e.length===0?null:i`
    <div class="toast-container">
      ${e.map(t=>i`
        <div key=${t.id} class="toast ${t.type}" onClick=${()=>hm(t.id)}>
          ${t.message}
        </div>
      `)}
    </div>
  `}const bm="masc_dashboard_agent_name",vn=f(null),Zs=f(!1),Nn=f(""),ea=f([]),wn=f([]),Qt=f(""),An=f(!1);function Na(e){vn.value=e,ro()}function Wo(){vn.value=null,Nn.value="",ea.value=[],wn.value=[],Qt.value=""}function km(){const e=vn.value;return e?Ge.value.find(t=>t.name===e)??null:null}function jl(e){return e?et.value.filter(t=>t.assignee===e):[]}function El(e){return e?pt.value.find(t=>t.agent_name===e||t.name===e)??null:null}function xm(e){if(!e)return null;const t=ts.value;return t?t.agent_briefs.find(n=>n.agent_name===e)??null:null}function Sm(e){if(!e)return[];const t=e.metrics_window;return(Array.isArray(t==null?void 0:t.top_tools)?t.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Cm(e){const t=El(e);return t?t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]:[]}async function ro(){const e=vn.value;if(e){Zs.value=!0,Nn.value="",ea.value=[],wn.value=[];try{const t=await bu(80);ea.value=t.filter(a=>a.includes(e)).slice(0,20);const n=jl(e).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await ku(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const l=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));wn.value=s}catch(t){Nn.value=t instanceof Error?t.message:"Failed to load agent detail"}finally{Zs.value=!1}}}async function Go(){var s;const e=vn.value,t=Qt.value.trim();if(!e||!t)return;const n=((s=localStorage.getItem(bm))==null?void 0:s.trim())||"dashboard";An.value=!0;try{await yu(n,`@${e} ${t}`),Qt.value="",E(`Mention sent to ${e}`,"success"),ro()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";E(o,"error")}finally{An.value=!1}}function Am({task:e}){return i`
    <div class="agent-detail-task">
      <span class="pill">${e.id}</span>
      <span class="agent-detail-task-title">${e.title}</span>
      <${mt} status=${e.status} />
    </div>
  `}function Im({row:e}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${e.taskId}</span>
      </div>
      <pre class="agent-history-pre">${e.text||"No task history yet"}</pre>
    </div>
  `}function Tm(){var C,x,L,T,R,M,z;const e=vn.value;if(!e)return null;const t=km(),n=El(e),s=xm(e),a=jl(e),o=ea.value,l=Cm(e),c=Sm(n),p=(s==null?void 0:s.allowed_tool_names)??[],m=(s==null?void 0:s.latest_tool_names)??[],u=s==null?void 0:s.latest_tool_call_count,_=s==null?void 0:s.tool_audit_source,g=s==null?void 0:s.tool_audit_at,h=(t==null?void 0:t.capabilities)??[],b=((C=te.value)==null?void 0:C.room)??"default",$=((x=te.value)==null?void 0:x.project)??"확인 없음",S=((L=te.value)==null?void 0:L.cluster)??"확인 없음";return i`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${j=>{j.target.classList.contains("agent-detail-overlay")&&Wo()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${t!=null&&t.emoji?i`<span style="font-size:2rem">${t.emoji}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${e}
                  ${t!=null&&t.koreanName?i`<span style="font-size:0.75em;color:#888">(${t.koreanName})</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  ${t?i`
                        <${mt} status=${t.status} />
                        ${t.model?i`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${t.model}</span>`:""}
                        ${t.primaryValue?i`<span style="font-size:0.75rem;color:#a78bfa">${t.primaryValue}</span>`:""}
                      `:i`<span>Agent snapshot not found in current state</span>`}
                </div>
              </div>
            </div>
            ${(t==null?void 0:t.activityLevel)!=null?i`
              <div style="display:flex;align-items:center;gap:8px;font-size:0.8rem">
                <span style="color:#888">Activity</span>
                <div style="flex:1;max-width:120px;height:6px;background:#1a1a2e;border-radius:3px;overflow:hidden">
                  <div style="width:${Math.min(t.activityLevel*10,100)}%;height:100%;background:${t.activityLevel>=8?"#22c55e":t.activityLevel>=5?"#f59e0b":"#666"};border-radius:3px"></div>
                </div>
                <span style="color:#888">${t.activityLevel}/10</span>
              </div>
            `:""}
            ${(((T=t==null?void 0:t.traits)==null?void 0:T.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(R=t==null?void 0:t.traits)==null?void 0:R.map(j=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${j}</span>`)}
              </div>
            `:""}
            ${(((M=t==null?void 0:t.interests)==null?void 0:M.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(z=t==null?void 0:t.interests)==null?void 0:z.map(j=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${j}</span>`)}
              </div>
            `:""}
            ${h.length>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${h.map(j=>i`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${j}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${t?i`
                    ${t.current_task?i`<span>Task: ${t.current_task}</span>`:null}
                    ${t.last_seen?i`<span>Last seen: <${J} timestamp=${t.last_seen} /></span>`:null}
                    <span>Room: ${b}</span>
                    <span>Project: ${$}</span>
                    <span>Cluster: ${S}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{ro()}} disabled=${Zs.value}>
              ${Zs.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Wo}>Close</button>
          </div>
        </div>

        ${Nn.value?i`<div class="council-error">${Nn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${I} title="Assigned Tasks">
            ${a.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${a.map(j=>i`<${Am} key=${j.id} task=${j} />`)}</div>`}
          <//>

          <${I} title="Recent Activity">
            ${o.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${o.map((j,Z)=>i`<div key=${Z} class="agent-activity-line">${j}</div>`)}</div>`}
          <//>
        </div>

        <${I} title="Capabilities & Tool Audit">
          <div style="display:flex; flex-direction:column; gap:12px;">
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Capabilities</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${h.length>0?h.map(j=>i`<span class="pill">${j}</span>`):i`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Allowed tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${p.length>0?p.map(j=>i`<span class="pill">${j}</span>`):i`<span class="empty-state" style="font-size:12px;">No allowlist reported</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Observed tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${m.length>0?m.map(j=>i`<span class="pill">${j}</span>`):i`<span class="empty-state" style="font-size:12px;">No observed tool-use evidence</span>`}
              </div>
            </div>
            <div class="agent-detail-sub">
              <span>Tool calls: ${typeof u=="number"?u:"—"}</span>
              <span>Evidence source: ${_??"unreported"}</span>
              <span>
                Observed at:
                ${g?i` <${J} timestamp=${g} />`:" unreported"}
              </span>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Linked keeper recent tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${l.length>0?l.map(j=>i`<span class="pill">${j}</span>`):i`<span class="empty-state" style="font-size:12px;">No keeper tool telemetry</span>`}
              </div>
            </div>
            ${c.length>0?i`
                  <div>
                    <div style="font-size:12px; color:#888; margin-bottom:6px;">Keeper window top tools</div>
                    <div style="display:flex; flex-wrap:wrap; gap:6px;">
                      ${c.map(j=>i`<span class="pill">${j}</span>`)}
                    </div>
                  </div>
                `:null}
            ${n?i`
                  <div style="font-size:12px; color:#888;">
                    Linked keeper: <span style="color:#4ade80;">${n.name}</span>
                    ${n.skill_primary?i` · route <span style="color:#22d3ee;">${n.skill_primary}</span>`:null}
                  </div>
                `:null}
          </div>
        <//>

        <${I} title="Task History">
          ${wn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${wn.value.map(j=>i`<${Im} key=${j.taskId} row=${j} />`)}</div>`}
        <//>

        <${I} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Qt.value}
              onInput=${j=>{Qt.value=j.target.value}}
              onKeyDown=${j=>{j.key==="Enter"&&Go()}}
              disabled=${An.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Go()}}
              disabled=${An.value||Qt.value.trim()===""}
            >
              ${An.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const _e=f(null),lo=f(null),De=f(null),Dn=f(!1),lt=f(null),On=f(!1),on=f(null),W=f(!1),ta=f([]);let zm=1;function Rm(e){return v(e)?{id:r(e.id),seq:d(e.seq),from:r(e.from)??r(e.from_agent)??"system",content:r(e.content)??"",timestamp:r(e.timestamp)??new Date().toISOString(),type:r(e.type)}:null}function Pm(e){return v(e)?{room_id:r(e.room_id),current_room:r(e.current_room)??r(e.room),project:r(e.project),cluster:r(e.cluster),paused:N(e.paused),pause_reason:r(e.pause_reason)??null,paused_by:r(e.paused_by)??null,paused_at:r(e.paused_at)??null}:{}}function Jo(e){if(!v(e))return;const t=Object.entries(e).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return t.length>0?Object.fromEntries(t):void 0}function Nl(e){if(!v(e))return null;const t=r(e.kind),n=r(e.summary),s=r(e.target_type);return!t||!n||!s?null:{kind:t,severity:r(e.severity)??"warn",summary:n,target_type:s,target_id:r(e.target_id)??null,actor:r(e.actor)??null,evidence:e.evidence}}function In(e){if(!v(e))return null;const t=r(e.action_type),n=r(e.target_type),s=r(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:r(e.target_id)??null,severity:r(e.severity)??"warn",reason:s,confirm_required:N(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function wl(e){return v(e)?{enabled:N(e.enabled),judge_online:N(e.judge_online),refreshing:N(e.refreshing),generated_at:r(e.generated_at)??null,expires_at:r(e.expires_at)??null,model_used:r(e.model_used)??null,keeper_name:r(e.keeper_name)??null,last_error:r(e.last_error)??null}:null}function Ua(e){return v(e)?{summary:r(e.summary)??null,confidence:d(e.confidence)??null,provenance:r(e.provenance)??null,authoritative:N(e.authoritative),surface:r(e.surface)??null,fresh_until:r(e.fresh_until)??null,keeper_name:r(e.keeper_name)??null,fallback_used:N(e.fallback_used),disagreement_with_truth:N(e.disagreement_with_truth)}:null}function Lm(e){return v(e)?{judgment_id:r(e.judgment_id)??void 0,surface:r(e.surface)??null,target_type:r(e.target_type)??null,target_id:r(e.target_id)??null,status:r(e.status)??null,summary:r(e.summary)??null,confidence:d(e.confidence)??null,generated_at:r(e.generated_at)??null,fresh_until:r(e.fresh_until)??null,keeper_name:r(e.keeper_name)??null,model_name:r(e.model_name)??null,runtime_name:r(e.runtime_name)??null,evidence_refs:H(e.evidence_refs),recommended_action:In(e.recommended_action),supersedes:H(e.supersedes),fallback_used:N(e.fallback_used),disagreement_with_truth:N(e.disagreement_with_truth),provenance:r(e.provenance)??null}:null}function Mm(e){return v(e)?{actor:r(e.actor)??null,spawn_agent:r(e.spawn_agent)??null,spawn_role:r(e.spawn_role)??null,spawn_model:r(e.spawn_model)??null,worker_class:r(e.worker_class)??null,parent_actor:r(e.parent_actor)??null,capsule_mode:r(e.capsule_mode)??null,runtime_pool:r(e.runtime_pool)??null,lane_id:r(e.lane_id)??null,controller_level:r(e.controller_level)??null,control_domain:r(e.control_domain)??null,supervisor_actor:r(e.supervisor_actor)??null,model_tier:r(e.model_tier)??null,task_profile:r(e.task_profile)??null,risk_level:r(e.risk_level)??null,routing_confidence:d(e.routing_confidence)??null,routing_reason:r(e.routing_reason)??null,status:r(e.status)??"unknown",turn_count:d(e.turn_count)??0,empty_note_turn_count:d(e.empty_note_turn_count)??0,has_turn:N(e.has_turn)??!1,last_turn_ts_iso:r(e.last_turn_ts_iso)??null}:null}function jm(e){if(!v(e))return null;const t=r(e.session_id);return t?{session_id:t,goal:r(e.goal),status:r(e.status),health:r(e.health),scale_profile:r(e.scale_profile),control_profile:r(e.control_profile),planned_worker_count:d(e.planned_worker_count),active_agent_count:d(e.active_agent_count),last_turn_age_sec:d(e.last_turn_age_sec)??null,attention_count:d(e.attention_count),recommended_action_count:d(e.recommended_action_count),top_attention:Nl(e.top_attention),top_recommendation:In(e.top_recommendation)}:null}function Dl(e){const t=v(e)?e:{};return{trace_id:r(t.trace_id),target_type:r(t.target_type)??"room",target_id:r(t.target_id)??null,health:r(t.health),judgment_owner:r(t.judgment_owner)??null,authoritative_judgment_available:N(t.authoritative_judgment_available),resident_judge_runtime:wl(t.resident_judge_runtime),judgment:Lm(t.judgment),active_guidance_layer:r(t.active_guidance_layer)??null,active_summary:Ua(t.active_summary),active_recommended_actions:pe(t.active_recommended_actions).map(In).filter(n=>n!==null),active_recommendation_source:r(t.active_recommendation_source)??null,active_recommendation_summary:Ua(t.active_recommendation_summary),fallback_recommended_actions:pe(t.fallback_recommended_actions).map(In).filter(n=>n!==null),recommendation_summary:Ua(t.recommendation_summary),swarm_status:v(t.swarm_status)?t.swarm_status:void 0,attention_items:pe(t.attention_items).map(Nl).filter(n=>n!==null),recommended_actions:pe(t.recommended_actions).map(In).filter(n=>n!==null),session_cards:pe(t.session_cards).map(jm).filter(n=>n!==null),worker_cards:pe(t.worker_cards).map(Mm).filter(n=>n!==null)}}function Em(e){if(!v(e))return null;const t=v(e.status)?e.status:void 0,n=v(e.summary)?e.summary:v(t==null?void 0:t.summary)?t.summary:void 0,s=v(e.session)?e.session:v(t==null?void 0:t.session)?t.session:void 0,a=r(e.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const o=Jo(e.report_paths)??Jo(t==null?void 0:t.report_paths),l=pe(e.recent_events,["events"]).filter(v);return{session_id:a,status:r(e.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:d(e.progress_pct)??d(n==null?void 0:n.progress_pct),elapsed_sec:d(e.elapsed_sec)??d(n==null?void 0:n.elapsed_sec),remaining_sec:d(e.remaining_sec)??d(n==null?void 0:n.remaining_sec),done_delta_total:d(e.done_delta_total)??d(n==null?void 0:n.done_delta_total),summary:n,team_health:v(e.team_health)?e.team_health:v(t==null?void 0:t.team_health)?t.team_health:void 0,communication_metrics:v(e.communication_metrics)?e.communication_metrics:v(t==null?void 0:t.communication_metrics)?t.communication_metrics:void 0,orchestration_state:v(e.orchestration_state)?e.orchestration_state:v(t==null?void 0:t.orchestration_state)?t.orchestration_state:void 0,cascade_metrics:v(e.cascade_metrics)?e.cascade_metrics:v(t==null?void 0:t.cascade_metrics)?t.cascade_metrics:void 0,report_paths:o,linked_autoresearch:v(e.linked_autoresearch)?e.linked_autoresearch:v(t==null?void 0:t.linked_autoresearch)?t.linked_autoresearch:void 0,session:s,recent_events:l}}function Vo(e){if(!v(e))return null;const t=r(e.name);if(!t)return null;const n=v(e.context)?e.context:void 0;return{name:t,runtime_class:e.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:N(e.desired),resident_registered:N(e.resident_registered),agent_name:r(e.agent_name),status:r(e.status),autonomy_level:r(e.autonomy_level),context_ratio:d(e.context_ratio)??d(n==null?void 0:n.context_ratio),generation:d(e.generation),active_goal_ids:H(e.active_goal_ids),last_autonomous_action_at:r(e.last_autonomous_action_at)??null,last_turn_ago_s:d(e.last_turn_ago_s),model:r(e.model)??r(e.active_model)??r(e.primary_model)}}function Nm(e){if(!v(e))return null;const t=r(e.confirm_token)??r(e.token);return t?{confirm_token:t,actor:r(e.actor),action_type:r(e.action_type),target_type:r(e.target_type),target_id:r(e.target_id)??null,delegated_tool:r(e.delegated_tool),created_at:r(e.created_at),preview:e.preview}:null}function Ol(e){if(!v(e))return null;const t=r(e.action_type),n=r(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:r(e.description),confirm_required:N(e.confirm_required)}}function wm(e){return v(e)?{actor_filter:r(e.actor_filter)??null,filter_active:N(e.filter_active)??!1,visible_count:d(e.visible_count)??0,total_count:d(e.total_count)??0,hidden_count:d(e.hidden_count)??0,hidden_actors:H(e.hidden_actors),confirm_required_actions:pe(e.confirm_required_actions).map(Ol).filter(t=>t!==null)}:null}function Dm(e){const t=v(e)?e:{};return{room:Pm(t.room),sessions:pe(t.sessions,["items","sessions"]).map(Em).filter(n=>n!==null),keepers:pe(t.keepers,["items","keepers"]).map(Vo).filter(n=>n!==null),resident_judge_runtime:wl(t.resident_judge_runtime),persistent_agents:pe(t.persistent_agents,["items","persistent_agents"]).map(Vo).filter(n=>n!==null),recent_messages:pe(t.recent_messages,["messages"]).map(Rm).filter(n=>n!==null),pending_confirms:pe(t.pending_confirms,["items","confirms"]).map(Nm).filter(n=>n!==null),pending_confirm_summary:wm(t.pending_confirm_summary)??void 0,available_actions:pe(t.available_actions,["actions"]).map(Ol).filter(n=>n!==null)}}function gs(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e)}catch{return String(e)}}function Yo(e){return e.target_id?`${e.target_type}:${e.target_id}`:e.target_type}function na(e){ta.value=[{...e,id:zm++,at:new Date().toISOString()},...ta.value].slice(0,20)}function ql(e){return e.confirm_required?gs(e.preview)||"Confirmation required":gs(e.result)||gs(e.executed_action)||gs(e.delegated_tool_result)||e.status}async function ye(){Dn.value=!0,lt.value=null;try{const e=await Md();_e.value=Dm(e)}catch(e){lt.value=e instanceof Error?e.message:"Failed to load operator snapshot"}finally{Dn.value=!1}}async function Pt(){On.value=!0,on.value=null;try{const e=await qr({targetType:"room"});lo.value=Dl(e)}catch(e){on.value=e instanceof Error?e.message:"Failed to load operator digest"}finally{On.value=!1}}async function rn(e){if(!e){De.value=null;return}On.value=!0,on.value=null;try{const t=await qr({targetType:"team_session",targetId:e,includeWorkers:!0});De.value=Dl(t)}catch(t){on.value=t instanceof Error?t.message:"Failed to load session digest"}finally{On.value=!1}}async function Fl(e){var t;W.value=!0,lt.value=null;try{const n=await Pa(e);return na({actor:e.actor,action_type:e.action_type,target_label:Yo(e),outcome:n.confirm_required?"preview":"executed",message:ql(n),delegated_tool:n.delegated_tool}),await ye(),await Pt(),(t=De.value)!=null&&t.target_id&&await rn(De.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw lt.value=s,na({actor:e.actor,action_type:e.action_type,target_label:Yo(e),outcome:"error",message:s}),n}finally{W.value=!1}}async function Kl(e,t,n="confirm"){var s;W.value=!0,lt.value=null;try{const a=await Fr(e,t,n);return na({actor:e,action_type:n,target_label:t,outcome:"confirmed",message:ql(a),delegated_tool:a.delegated_tool}),await ye(),await Pt(),(s=De.value)!=null&&s.target_id&&await rn(De.value.target_id),a}catch(a){const o=a instanceof Error?a.message:"Operator confirmation failed";throw lt.value=o,na({actor:e,action_type:"confirm",target_label:t,outcome:"error",message:o}),a}finally{W.value=!1}}Ap(()=>{var e;ye(),Pt(),(e=De.value)!=null&&e.target_id&&rn(De.value.target_id)});function Om(e){switch(e){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function qm(e){switch(e){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Fm(e){switch(e.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return e.role}}function Xo(e){return e.delivery==="error"||e.delivery==="timeout"?"bad":e.delivery==="sending"?"warn":e.role==="assistant"?"assistant":e.role==="user"?"user":"warn"}function Bl(e){if(!e)return null;const t=new Date(e);return Number.isNaN(t.getTime())?null:t.toLocaleTimeString()}function Km(e){return typeof e!="number"||!Number.isFinite(e)||e<=0?null:e<60?`${Math.round(e)}s`:`${Math.ceil(e/60)}m`}function Ul(e){if(!e)return null;const t=He.value[e.name];return(t==null?void 0:t.diagnostic)??e.diagnostic??null}function Bm({keeper:e,showRawStatus:t=!1}){if(ne(()=>{e!=null&&e.name&&Xr(e.name)},[e==null?void 0:e.name]),!e)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=He.value[e.name],s=Ul(e),a=bi.value[e.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Om(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${qm((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${Bl(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${Km(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${t?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Um({keeperName:e,placeholder:t}){const[n,s]=Rr("");ne(()=>{e&&Xr(e)},[e]);const a=de.value[e]??[],o=ki.value[e]??!1,l=We.value[e],c=async()=>{const p=n.trim();if(!(!e||!p)){s("");try{await Ku(e,p)}catch(m){const u=m instanceof Error?m.message:`Failed to message ${e}`;E(u,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(p=>i`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Xo(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${Xo(p)}`}>${Fm(p)}</span>
                  ${p.timestamp?i`<span class="keeper-conversation-time">${Bl(p.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${p.text}</div>
                ${p.error?i`<div class="keeper-conversation-error">${p.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${t}
          value=${n}
          onInput=${p=>{s(p.target.value)}}
          disabled=${o||!e}
        ></textarea>
        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${()=>{c()}}
            disabled=${o||n.trim()===""||!e}
          >
            ${o?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${l?i`<div class="control-status-copy control-error-copy">${l}</div>`:null}
      </div>
    </div>
  `}function Hm({actor:e,keeper:t,onPokeLodge:n}){if(!t)return null;const s=Ul(t),a=xi.value[t.name]??!1,o=Si.value[t.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{Bu(t.name,e).catch(p=>{const m=p instanceof Error?p.message:`Failed to probe ${t.name}`;E(m,"error")})}}
        disabled=${a||!e.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{Uu(t.name,e).catch(p=>{const m=p instanceof Error?p.message:`Failed to recover ${t.name}`;E(m,"error")})}}
        disabled=${o||!c||!e.trim()}
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
  `}const co=f(null);function Hl(e){co.value=e,Fu(e.name)}function Qo(){co.value=null}const wt=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Wm(e){if(!e)return 0;const t=wt.findIndex(n=>n.level===e);return t>=0?t:0}function Gm({keeper:e}){const t=Wm(e.autonomy_level),n=wt[t]??wt[0];if(!n)return null;const s=(t+1)/wt.length*100;return i`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${t+1} / ${wt.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${wt.map((a,o)=>i`
            <span style="width:8px; height:8px; border-radius:50%; background:${o<=t?a.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${e.autonomous_action_count??0}</strong>
      </div>
      ${e.last_autonomous_action_at?i`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${J} timestamp=${e.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${e.active_goal_ids&&e.active_goal_ids.length>0?i`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${e.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function ws(e){return e?e>=1e6?`${(e/1e6).toFixed(1)}M`:e>=1e3?`${(e/1e3).toFixed(1)}K`:String(e):"—"}function Jm(e){switch(e){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(e==null?void 0:e.trim())||"action"}}function Vm(e){return e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]}function Ym(e){const t=e.metrics_window;return(Array.isArray(t==null?void 0:t.top_tools)?t.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Xm(e){const t=ts.value;return t?t.keeper_briefs.find(n=>n.name===e.name||n.agent_name&&e.agent_name&&n.agent_name===e.agent_name)??null:null}function Qm({keeper:e}){const t=e.metrics_series??[],n=t[t.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:e.generation??"-",hint:"Succession count"},{label:"Turns",value:e.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:e.context_ratio!=null?`${Math.round(e.context_ratio*100)}%`:"-",hint:e.context_ratio!=null&&e.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:e.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${ws(e.context_tokens)}</div>
        <div class="kpi-label">Tokens</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${e.handoff_count_total??"—"}</div>
        <div class="kpi-label">Handoffs</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${e.compaction_count??"—"}</div>
        <div class="kpi-label">Compactions</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${s}</div>
        <div class="kpi-label">Cost (USD)</div>
      </div>
    </div>
  `}function Zm({keeper:e}){var u,_;const t=e.metrics_series??[];if(t.length<2){const g=(((u=e.context)==null?void 0:u.context_ratio)??0)*100,h=g>85?"#ef4444":g>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${g.toFixed(1)}%;background:${h}"></div>
        </div>
        <span class="chart-pct">${g.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=t.length,l=t.map((g,h)=>{const b=a+h/(o-1)*(n-2*a),$=s-a-(g.context_ratio??0)*(s-2*a);return{x:b,y:$,p:g}}),c=l.map(({x:g,y:h})=>`${g.toFixed(1)},${h.toFixed(1)}`).join(" "),p=(((_=t[t.length-1])==null?void 0:_.context_ratio)??0)*100,m=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:g})=>g.is_handoff).map(({x:g})=>i`
          <line x1="${g.toFixed(1)}" y1="${a}" x2="${g.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${m}" stroke-width="1.5"/>
        ${l.filter(({p:g})=>g.is_compaction).map(({x:g,y:h})=>i`
          <circle cx="${g.toFixed(1)}" cy="${h.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}const Ha=f("");function ev({keeper:e}){var a,o,l,c;const t=Ha.value.toLowerCase(),n=[{title:"Name",key:"name",value:e.name},{title:"Emoji",key:"emoji",value:e.emoji??"-"},{title:"Korean",key:"koreanName",value:e.koreanName??"-"},{title:"Model",key:"model",value:e.model??"-"},{title:"Status",key:"status",value:e.status},{title:"Primary",key:"primaryValue",value:e.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(e.activityLevel??"-")},{title:"Gen",key:"generation",value:String(e.generation??"-")},{title:"Turns",key:"turn_count",value:String(e.turn_count??"-")},{title:"Context",key:"context_ratio",value:e.context_ratio!=null?`${Math.round(e.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:e.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=e.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=e.interests)==null?void 0:o.join(", "))||"-"}],s=t?n.filter(p=>p.title.toLowerCase().includes(t)||p.key.includes(t)||p.value.toLowerCase().includes(t)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Ha.value}
        onInput=${p=>{Ha.value=p.target.value}}
      />
      ${s.map(p=>i`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${p.title}</span>
          <span class="keeper-field-key">${p.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${p.value}</span>
        </div>
      `)}
      ${e.trace_id?i`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${e.trace_id}</span></div>`:""}
      ${e.agent_name?i`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${e.agent_name}</span></div>`:""}
      ${e.primary_model?i`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${e.primary_model}</span></div>`:""}
      ${e.active_model?i`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${e.active_model}</span></div>`:""}
      ${e.next_model_hint?i`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${e.next_model_hint}</span></div>`:""}
      ${e.skill_primary?i`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${e.skill_primary}</span></div>`:""}
      ${e.skill_secondary?i`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${e.skill_secondary}</span></div>`:""}
      ${e.skill_reason?i`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${e.skill_reason}</span></div>`:""}
      ${e.context_source?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${e.context_source}</span></div>`:""}
      ${e.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${ws(e.context_tokens)}</span></div>`:""}
      ${e.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${ws(e.context_max)}</span></div>`:""}
      ${e.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${e.memory_recent_note}</span></div>`:""}
      ${e.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${e.k2k_count}</span></div>`:""}
      ${e.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${e.conversation_tail_count}</span></div>`:""}
      ${e.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${e.handoff_count_total}</span></div>`:""}
      ${e.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${e.compaction_count}</span></div>`:""}
      ${e.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${ws(e.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=e.context)==null?void 0:l.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${e.context.message_count}</span></div>`:""}
      ${((c=e.context)==null?void 0:c.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${e.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function tv({stats:e}){const t=e.max_hp>0?Math.round(e.hp/e.max_hp*100):0,n=e.max_mp>0?Math.round(e.mp/e.max_mp*100):0;return i`
    <div>
      <div style="display: flex; gap: 12px; margin-bottom: 10px;">
        <div style="flex:1;">
          <div style="font-size:11px; color:#888;">HP ${e.hp}/${e.max_hp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${t}%; height:100%; background:${t>50?"#4ade80":t>25?"#fbbf24":"#ef4444"}; border-radius:3px;" />
          </div>
        </div>
        <div style="flex:1;">
          <div style="font-size:11px; color:#888;">MP ${e.mp}/${e.max_mp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${n}%; height:100%; background:#818cf8; border-radius:3px;" />
          </div>
        </div>
      </div>
      <div style="display:grid; grid-template-columns: repeat(3,1fr); gap:6px;">
        ${[{label:"STR",value:e.strength},{label:"DEX",value:e.dexterity},{label:"CON",value:e.constitution},{label:"INT",value:e.intelligence},{label:"WIS",value:e.wisdom},{label:"CHA",value:e.charisma}].map(s=>i`
          <div style="text-align:center; padding:6px; background:rgba(255,255,255,0.03); border-radius:6px;">
            <div style="font-size:10px; color:#888; text-transform:uppercase;">${s.label}</div>
            <div style="font-size:16px; font-weight:bold; color:#e0e0e0;">${s.value}</div>
          </div>
        `)}
      </div>
      <div style="margin-top:8px; font-size:12px; color:#888;">
        Level ${e.level} — XP ${e.xp}
      </div>
    </div>
  `}function nv({items:e}){return e.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${e.map((t,n)=>i`
        <div class="keeper-equipment-row">
          <span>${t}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function sv({rels:e}){const t=Object.entries(e);return t.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${t.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Zo({traits:e,label:t}){return e.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${t}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${e.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Wa(e){return e==null||Number.isNaN(e)?"-":`${Math.round(e*100)}%`}function av({keeper:e}){const t=e.metrics_window,n=[{label:"Model fallback",value:Wa(typeof(t==null?void 0:t.model_fallback_rate)=="number"?t.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Wa(typeof(t==null?void 0:t.proactive_fallback_rate)=="number"?t.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Wa(typeof(t==null?void 0:t.memory_pass_rate)=="number"?t.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(t==null?void 0:t.handoff_count)=="number"?t.handoff_count:e.handoff_count_total??"-"},{label:"Compactions",value:typeof(t==null?void 0:t.compaction_events)=="number"?t.compaction_events:e.compaction_count??"-"},{label:"Saved tokens",value:typeof(t==null?void 0:t.compaction_saved_tokens)=="number"?t.compaction_saved_tokens:e.last_compaction_saved_tokens??"-"},{label:"K2K events",value:e.k2k_count??"-"},{label:"Conversation tail",value:e.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(t==null?void 0:t.tool_call_count)=="number"?t.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(t==null?void 0:t.proactive_preview_similarity_avg)=="number"?`${(t.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(t==null?void 0:t.memory_avg_score)=="number"?t.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(t==null?void 0:t.fallback_rate)=="number"?`${(t.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(s=>i`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function iv({keeper:e}){var $,S,C,x,L,T,R;const t=(($=_e.value)==null?void 0:$.room)??{},n=(((S=_e.value)==null?void 0:S.available_actions)??[]).filter(M=>M.target_type==="keeper"||M.target_type==="room").slice(0,8),s=Vm(e),a=Ym(e),o=Xm(e),l=(o==null?void 0:o.allowed_tool_names)??[],c=(o==null?void 0:o.latest_tool_names)??[],p=o==null?void 0:o.latest_tool_call_count,m=o==null?void 0:o.tool_audit_source,u=o==null?void 0:o.tool_audit_at,_=((C=e.agent)==null?void 0:C.capabilities)??[],g=t.current_room??t.room_id??((x=te.value)==null?void 0:x.room)??"default",h=t.project??((L=te.value)==null?void 0:L.project)??"확인 없음",b=t.cluster??((T=te.value)==null?void 0:T.cluster)??"확인 없음";return i`
    <div class="keeper-signal-list">
      <div class="keeper-signal-row">
        <span>Room</span>
        <strong>${g}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Project</span>
        <strong>${h}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Cluster</span>
        <strong>${b}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Current task</span>
        <strong>${((R=e.agent)==null?void 0:R.current_task)??"없음"}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Skill route</span>
        <strong>${e.skill_primary??"미확인"}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Allowed tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${l.length>0?l.map(M=>i`<span class="pill">${M}</span>`):i`<span style="font-size:12px; color:#888;">allowlist 미보고</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Observed tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${c.length>0?c.map(M=>i`<span class="pill">${M}</span>`):i`<span style="font-size:12px; color:#888;">observed tool-use evidence 없음</span>`}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Tool calls</span>
        <strong>${typeof p=="number"?p:"—"}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Evidence source</span>
        <strong>${m??"unreported"}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Observed at</span>
        <strong>${u?i`<${J} timestamp=${u} />`:"unreported"}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Keeper recent tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${s.length>0?s.map(M=>i`<span class="pill">${M}</span>`):i`<span style="font-size:12px; color:#888;">도구 텔레메트리 없음</span>`}
        </div>
      </div>
      ${a.length>0?i`
            <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
              <span style="font-size:12px; color:#888;">Window top tools</span>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${a.map(M=>i`<span class="pill">${M}</span>`)}
              </div>
            </div>
          `:null}
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${_.length>0?_.map(M=>i`<span class="pill">${M}</span>`):i`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(M=>i`<span class="pill">${Jm(M.action_type)}</span>`):i`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function Wl(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(t??n??"dashboard").trim()||"dashboard"}async function ov(){try{const e=await Pa({actor:Wl(),action_type:"lodge_tick",target_type:"room",payload:{}}),t=Yr(e.result);await es(),t!=null&&t.skipped_reason?E(t.skipped_reason,"warning"):E(t?`Poke finished: ${t.acted}/${t.checked} acted`:"Poke finished",t&&t.acted>0?"success":"warning")}catch(e){const t=e instanceof Error?e.message:"Failed to run Lodge poke";E(t,"error")}}function rv({keeper:e}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Bm} keeper=${e} />
          <${Hm}
            actor=${Wl()}
            keeper=${e}
            onPokeLodge=${()=>{ov()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Um}
            keeperName=${e.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function lv(){var t,n,s;const e=co.value;return e?i`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Qo()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${e.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${e.name}</h2>
              ${e.koreanName?i`<div style="font-size:13px; color:#888;">${e.koreanName}</div>`:null}
            </div>
            <${mt} status=${e.status} />
            ${e.model?i`<span class="pill">${e.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Qo()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Qm} keeper=${e} />

        ${""}
        <${Zm} keeper=${e} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${I} title="Field Dictionary">
            <${ev} keeper=${e} />
          <//>

          ${""}
          <${I} title="Profile">
            <${Zo} traits=${e.traits??[]} label="Traits" />
            <${Zo} traits=${e.interests??[]} label="Interests" />
            ${e.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${e.primaryValue}</span></div>`:null}
            ${e.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${e.skill_primary}</span>
                </div>`:null}
            ${e.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${e.skill_reason}</div>`:null}
            ${e.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${J} timestamp=${e.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${e.autonomy_level?i`
              <${I} title="Autonomy">
                <${Gm} keeper=${e} />
              <//>
            `:null}

          ${""}
          ${e.trpg_stats?i`
              <${I} title="TRPG Stats">
                <${tv} stats=${e.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${e.inventory&&e.inventory.length>0?i`
              <${I} title="Equipment (${e.inventory.length})">
                <${nv} items=${e.inventory} />
              <//>
            `:null}

          ${""}
          ${e.relationships&&Object.keys(e.relationships).length>0?i`
              <${I} title="Relationships (${Object.keys(e.relationships).length})">
                <${sv} rels=${e.relationships} />
              <//>
            `:null}

          <${I} title="Runtime Signals">
            <${av} keeper=${e} />
          <//>

          <${I} title="Neighborhood & Tool Audit">
            <${iv} keeper=${e} />
          <//>

          <${I} title="Memory & Context">
            <div class="keeper-signal-list">
              <div class="keeper-signal-row">
                <span>Context source</span>
                <strong>${e.context_source??((t=e.context)==null?void 0:t.source)??"-"}</strong>
              </div>
              <div class="keeper-signal-row">
                <span>Context tokens</span>
                <strong>
                  ${e.context_tokens??((n=e.context)==null?void 0:n.context_tokens)??"-"}
                  /
                  ${e.context_max??((s=e.context)==null?void 0:s.context_max)??"-"}
                </strong>
              </div>
              ${e.memory_recent_note?i`
                  <div class="keeper-memory-note">
                    ${e.memory_recent_note}
                  </div>
                `:i`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${rv} keeper=${e} />
      </div>
    </div>
  `:null}function cv({cluster:e,project:t,room:n,generatedAt:s}){return i`
    <div class="mission-context-bar">
      <div class="mission-context-item">
        <span>클러스터</span>
        <strong>${e??"확인 없음"}</strong>
      </div>
      <div class="mission-context-item">
        <span>프로젝트</span>
        <strong>${t??"확인 없음"}</strong>
      </div>
      <div class="mission-context-item">
        <span>방</span>
        <strong>${n??"기본 방"}</strong>
      </div>
      <div class="mission-context-item">
        <span>갱신 시각</span>
        <strong>${s?Ne(s):"기록 없음"}</strong>
      </div>
    </div>
  `}function Et({label:e,value:t,detail:n,tone:s}){return i`
    <article class="mission-stat-card ${ve(s)}">
      <span class="mission-stat-label">${e}</span>
      <strong class="mission-stat-value">${t}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function dv(){const e=fl.value,t=ve((e==null?void 0:e.status)??(xt.value?"bad":"warn")),n=!e||e.sections.length===0,s=(e==null?void 0:e.status)==="error"||(e==null?void 0:e.status)==="unavailable"&&!(e!=null&&e.cached);return i`
    <${I} title="판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>휴리스틱 대신 별도 판단 결과</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${t}">
          ${we((e==null?void 0:e.status)??(xt.value?"error":"loading"))}
        </span>
        ${e!=null&&e.model?i`<span class="command-chip">${e.model}</span>`:null}
        ${e!=null&&e.generated_at?i`<span class="command-chip">${Ne(e.generated_at)}</span>`:null}
        ${e!=null&&e.cached?i`<span class="command-chip">캐시</span>`:null}
        ${e!=null&&e.stale?i`<span class="command-chip warn">오래됨</span>`:null}
        ${e!=null&&e.refreshing?i`<span class="command-chip warn">갱신 중</span>`:null}
      </div>

      ${xt.value?i`<div class="empty-state error">${xt.value}</div>`:null}
      ${e!=null&&e.error?i`<div class="empty-state error">${e.error}</div>`:null}
      ${e!=null&&e.summary?i`<div class="mission-inline-note">${e.summary}</div>`:null}
      ${e!=null&&e.last_error&&!e.error?i`<div class="mission-inline-note">최근 갱신 실패: ${e.last_error}</div>`:null}

      ${e&&e.sections.length>0?i`
            <div class="mission-briefing-grid">
              ${e.sections.slice(0,3).map(a=>i`
                <article class="mission-briefing-section ${ve(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${ve(a.status)}">${we(a.status)}</span>
                      ${Ho(a.signal_class)?i`<span class="command-chip ${a.signal_class==="mixed"?"warn":""}">${Ho(a.signal_class)}</span>`:null}
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
          `:!qt.value&&!xt.value&&n?i`
                <div class="empty-state">
                  ${(e==null?void 0:e.status)==="pending"?"최신 스냅샷으로 브리핑을 생성 중입니다. 마지막 성공 결과가 생기면 자동으로 다시 읽습니다.":"판단 결과가 아직 없습니다."}
                </div>
              `:null}

      ${e&&e.metadata_gaps.length>0?i`
            <details class="mission-card-disclosure compact mission-briefing-gaps">
              <summary>관측 공백 (${e.metadata_gap_count??e.metadata_gaps.length})</summary>
              <div class="mission-list-stack">
                ${e.metadata_gaps.map(a=>i`
                  <article class="mission-briefing-gap ${a.severity==="watch"?"warn":""}">
                    <div class="mission-card-head">
                      <strong>${Qs(a.scope_type)}${a.scope_id?` · ${a.scope_id}`:""}</strong>
                      <span class="command-chip ${a.severity==="watch"?"warn":""}">${we(a.severity)}</span>
                    </div>
                    <p>${a.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{Ys(s)}} disabled=${qt.value}>
          ${qt.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{Ys(!0)}} disabled=${qt.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function uv({item:e,selected:t,sessionLookup:n}){const s=pm(e),a=e.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),o=e.top_action??null;return i`
    <article class="mission-attention-card ${ve((o==null?void 0:o.severity)??e.severity)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>_m(e.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${e.summary}</strong>
            <div class="mission-card-target">${Qs(e.target_type)}${e.target_id?` · ${e.target_id}`:""}</div>
          </div>
          <span class="command-chip ${ve((o==null?void 0:o.severity)??e.severity)}">${o?dm(o):e.severity}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>영향 세션</span>
            <strong>${e.related_session_ids.length}</strong>
            <small>${e.related_session_ids.slice(0,2).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>영향 에이전트</span>
            <strong>${e.related_agent_names.length}</strong>
            <small>${e.related_agent_names.slice(0,3).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 신호</span>
            <strong>${e.last_seen_at?Ne(e.last_seen_at):"기록 없음"}</strong>
            <small>${Qs(e.target_type)}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${o?ja(o.action_type):"판단 필요"}</strong>
            <small>${o?um(o):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${o?i`<div class="mission-inline-note">${o.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?i`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>i`
                  <button class="mission-link-row" onClick=${()=>Ll(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${we(l.status)} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:i`<div class="empty-state">직접 연결된 세션이 아직 없습니다.</div>`}

        ${e.related_agent_names.length>0?i`
              <div class="mission-pill-row">
                ${e.related_agent_names.slice(0,8).map(l=>i`
                  <button class="mission-pill action" onClick=${()=>Na(l)}>${l}</button>
                `)}
              </div>
            `:null}

        ${e.evidence_preview.length>0?i`
              <details class="mission-card-disclosure compact">
                <summary>근거 미리보기</summary>
                <div class="mission-evidence-list">
                  ${e.evidence_preview.map(l=>i`<span>${l}</span>`)}
                </div>
              </details>
            `:null}
      </details>

      <div class="mission-card-actions">
        ${o?i`
              <button class="control-btn ghost" onClick=${()=>oo(o,s,"상황판 주의 신호")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>Pl(o,s,"상황판 주의 신호")}>
                원인 보기
              </button>
            `:i`
              <button class="control-btn ghost" onClick=${()=>zl(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Rl(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function pv({brief:e,selected:t}){var o,l;const n=e.member_previews.slice(0,4),s=e.top_recommendation??null,a=e.top_attention??null;return i`
    <article class="mission-crew-card ${ve(((o=e.top_attention)==null?void 0:o.severity)??e.health??e.status)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Ll(e.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${e.goal}</strong>
            <div class="mission-card-target">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          </div>
          <span class="command-chip ${ve(((l=e.top_attention)==null?void 0:l.severity)??e.health??e.status)}">${we(e.status)}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${e.member_names.length}</strong>
            <small>${e.member_names.slice(0,3).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${cm(e.elapsed_sec)}</strong>
            <small>${e.started_at?`${Ne(e.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 흐름</span>
            <strong>${e.last_event_at?Ne(e.last_event_at):"기록 없음"}</strong>
            <small>${e.communication_summary??"요약 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>충원 상태</span>
            <strong>${e.active_count??0}/${e.required_count||1}</strong>
            <small>활성 / 필요</small>
          </div>
        </div>
      </button>

      ${e.blocker_summary?i`<div class="mission-inline-note">막힘 · ${e.blocker_summary}</div>`:null}

      <div class="mission-crew-event">
        <span>최근 사건</span>
        <strong>${e.last_event_summary??"최근 세션 이벤트가 없습니다."}</strong>
        <small>${e.last_event_at?Ne(e.last_event_at):"시각 없음"}</small>
      </div>

      ${e.operation_badges.length>0?i`
            <div class="mission-pill-row">
              ${e.operation_badges.slice(0,3).map(c=>i`
                <span class="mission-pill">
                  ${c.operation_id} · ${we(c.status)}${c.stage?` · ${c.stage}`:""}
                </span>
              `)}
            </div>
          `:null}

      ${n.length>0?i`
            <div class="mission-member-preview-grid">
              ${n.map(c=>i`
                <button class="mission-member-preview" onClick=${()=>Na(c.agent_name)}>
                  <strong>${c.agent_name}</strong>
                  <span>${c.current_work??"현재 작업 없음"}</span>
                  <small>${c.recent_output_preview??c.recent_input_preview??"최근 입출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Mi("intervene",e.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Mi("command",e.session_id)}>세션 원인 보기</button>
        ${s?i`<button class="control-btn ghost" onClick=${()=>oo(s,a,"상황판 세션 요약")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function mv({detail:e,loading:t,error:n}){if(t&&!e)return i`
      <${I} title="세션 상세" class="mission-list-card">
        <div class="loading-indicator">세션 상세 불러오는 중...</div>
      <//>
    `;if(n&&!e)return i`
      <${I} title="세션 상세" class="mission-list-card">
        <div class="empty-state error">${n}</div>
      <//>
    `;if(!(e!=null&&e.session))return null;const s=e.session;return i`
    <${I} title="세션 상세" class="mission-list-card" semanticId="mission.session_detail">
      <div class="mission-section-head">
        <h3>${s.goal}</h3>
        <p>${s.session_id}${s.room?` · ${s.room}`:""}</p>
      </div>

      ${n?i`<div class="mission-inline-note">${n}</div>`:null}

      <div class="mission-detail-grid">
        <div class="mission-detail-column">
          <div class="mission-card-head">
            <strong>타임라인</strong>
            <span class="command-chip">${e.timeline.length}</span>
          </div>
          <div class="mission-timeline-list">
            ${e.timeline.length>0?e.timeline.map(a=>i`
                  <article class="mission-timeline-row">
                    <div class="mission-card-head">
                      <strong>${a.summary}</strong>
                      <span>${a.timestamp?Ne(a.timestamp):"시각 없음"}</span>
                    </div>
                    <small>${a.actor?`${a.actor} · `:""}${a.event_type??"이벤트"}</small>
                  </article>
                `):i`<div class="empty-state">표시할 세션 이벤트가 없습니다.</div>`}
          </div>
        </div>

        <div class="mission-detail-column">
          <div class="mission-card-head">
            <strong>참여자</strong>
            <span class="command-chip">${e.participants.length}</span>
          </div>
          <div class="mission-activity-list compact">
            ${e.participants.length>0?e.participants.map(a=>i`
                  <button class="mission-member-preview" onClick=${()=>Na(a.agent_name)}>
                    <strong>${a.agent_name}</strong>
                    <span>${a.current_work??"현재 작업 없음"}</span>
                    <small>
                      ${a.recent_output_preview??a.recent_input_preview??"최근 입출력 없음"}
                      ${a.last_activity_at?` · ${Ne(a.last_activity_at)}`:""}
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
            <span class="command-chip">${e.operations.length}</span>
          </div>
          <div class="mission-link-list">
            ${e.operations.length>0?e.operations.map(a=>i`
                  <button class="mission-link-row" onClick=${()=>Mi("command",s.session_id)}>
                    <strong>${a.operation_id}</strong>
                    <span>${we(a.status)}${a.stage?` · ${a.stage}`:""}</span>
                    <small>${a.detachment_status??a.objective??"분견대 정보 없음"}</small>
                  </button>
                `):i`<div class="empty-state">연결된 작전이 없습니다.</div>`}
          </div>
        </div>

        <div class="mission-detail-column">
          <div class="mission-card-head">
            <strong>연속성 관찰</strong>
            <span class="command-chip">${e.keepers.length}</span>
          </div>
          <div class="mission-link-list">
            ${e.keepers.length>0?e.keepers.map(a=>i`
                  <div class="mission-link-row static">
                    <strong>${a.name}</strong>
                    <span>${we(a.status)}${a.generation!=null?` · 세대 ${a.generation}`:""}</span>
                    <small>${a.current_work??"현재 작업 정보 없음"}</small>
                  </div>
                `):i`<div class="empty-state">직접 연결된 키퍼는 없습니다.</div>`}
          </div>
        </div>
      </div>
    <//>
  `}function vv({row:e}){var n,s,a,o,l,c,p,m,u,_;const t=[`세대 ${e.brief.generation??((n=e.keeper)==null?void 0:n.generation)??0}`,e.brief.context_ratio!=null?`컨텍스트 ${Math.round(e.brief.context_ratio*100)}%`:((s=e.keeper)==null?void 0:s.context_ratio)!=null?`컨텍스트 ${Math.round(e.keeper.context_ratio*100)}%`:null,e.brief.last_turn_ago_s!=null?`최근 턴 ${Math.round(e.brief.last_turn_ago_s)}초 전`:null].filter(g=>g!==null).join(" · ");return i`
    <article class="mission-activity-card ${ve(e.brief.status??((a=e.keeper)==null?void 0:a.status))}">
      <button class="mission-card-select" onClick=${()=>{e.keeper&&Hl(e.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((o=e.keeper)==null?void 0:o.emoji)??""}</span>
            <div>
              <strong>${e.brief.name}</strong>
              ${(l=e.keeper)!=null&&l.koreanName?i`<span>${e.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${ve(e.brief.status??((c=e.keeper)==null?void 0:c.status))}">${we(e.brief.status??((p=e.keeper)==null?void 0:p.status))}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 하트비트 · ${(m=e.keeper)!=null&&m.last_heartbeat?Ne(e.keeper.last_heartbeat):"기록 없음"}</span>
          <span>${t||"연속성 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${e.currentWork}</strong>
          ${(u=e.keeper)!=null&&u.skill_reason?i`<small>판단 요약 · ${Re(e.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>연속성 상세</summary>
        <div class="mission-activity-foot">
          <span>에이전트 · ${e.brief.agent_name??((_=e.keeper)==null?void 0:_.agent_name)??"기록 없음"}</span>
          ${e.recentEvent?i`<span>최근 일 · ${e.recentEvent}</span>`:null}
        </div>
        <details class="mission-card-disclosure compact">
          <summary>입력 · 응답 · 도구</summary>
          <div class="mission-io-stack">
            <div class="mission-io-item">
              <span>최근 입력</span>
              <strong>${e.recentInput??"표시 가능한 최근 입력이 없습니다"}</strong>
            </div>
            <div class="mission-io-item">
              <span>최근 응답</span>
              <strong>${e.recentOutput??"표시 가능한 최근 응답이 없습니다"}</strong>
            </div>
          </div>
          <div class="mission-activity-foot">
            <span>최근 도구 · ${e.recentTools.length>0?e.recentTools.join(", "):"도구 사용 없음"}</span>
          </div>
        </details>
      </details>
    </article>
  `}function _v({item:e}){const t=e.action??null,n=e.attention??null;return i`
    <article class="mission-action-card ${ve(e.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${ve(e.severity)}">
          ${e.signal_type==="action"&&t?ja(t.action_type):(n==null?void 0:n.kind)??"내부 신호"}
        </span>
        <span class="mission-card-target">${Qs(e.target_type)}${e.target_id?` · ${e.target_id}`:""}</span>
      </div>
      <p>${e.summary}</p>
      ${t?i`<div class="mission-action-preview">${t.reason}</div>`:null}
      <div class="mission-card-actions">
        ${t?i`
              <button class="control-btn ghost" onClick=${()=>oo(t,n,"상황판 내부 신호")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Pl(t,n,"상황판 내부 신호")}>이 이슈의 원인 보기</button>
            `:n?i`
                <button class="control-btn ghost" onClick=${()=>zl(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>Rl(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function er(){var h,b,$,S;const e=ts.value;if(Ri.value&&!e)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(Vs.value&&!e)return i`<div class="empty-state error">${Vs.value}</div>`;if(!e)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;Be.value&&!e.attention_queue.some(C=>C.id===Be.value)&&(Be.value=null);const t=e.sessions;Ze.value&&!t.some(C=>C.session_id===Ze.value)&&(Ze.value=null);const n=e.attention_queue.find(C=>C.id===Be.value)??null,s=(n==null?void 0:n.related_session_ids.find(C=>t.some(x=>x.session_id===C)))??null,a=Ze.value??s??((h=t[0])==null?void 0:h.session_id)??null,o=vm(),l=t.find(C=>C.session_id===a)??null,c=e.keeper_briefs.slice(0,6).map(mm),p=e.attention_queue.filter(C=>C.related_session_ids.length>0).slice(0,6),m=e.internal_signals.slice(0,3),u=t.filter(C=>{var L;const x=((L=C.top_attention)==null?void 0:L.severity)??C.health??C.status;return ve(x)!=="ok"||!!C.blocker_summary}).length,_=new Set(t.flatMap(C=>C.member_names)).size,g=t.flatMap(C=>C.member_previews??[]).filter(C=>C.recent_output_preview).length+c.filter(C=>C.recentOutput).length;return ne(()=>{Xp(a)},[a]),i`
    <section class="dashboard-panel mission-view">
      <${be} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 어떤 세션이 돌고 있고, 누가 참여하며, 어디가 막혔는지를 한 시점에서 읽는 기본 관찰면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${ve(e.summary.room_health)}">${we(e.summary.room_health)}</span>
          <span class="command-chip">${e.summary.project??"프로젝트 미지정"}${e.summary.current_room?` · ${e.summary.current_room}`:""}</span>
          <span class="command-chip">${e.generated_at?Ne(e.generated_at):"기록 없음"}</span>
        </div>
      </div>

      <${cv}
        cluster=${e.summary.cluster}
        project=${e.summary.project}
        room=${e.summary.current_room}
        generatedAt=${e.generated_at}
      />

      <${dv} />

      <div class="mission-stat-grid">
        <${Et} label="활성 세션" value=${t.length} detail="지금 진행중인 협업 단위" tone=${((b=l==null?void 0:l.top_attention)==null?void 0:b.severity)??(l==null?void 0:l.health)??"ok"} />
        <${Et} label="막힌 세션" value=${u} detail="주의가 필요한 흐름" tone=${u>0?"warn":"ok"} />
        <${Et} label="참여자" value=${_} detail="현재 세션에 연결된 주체" tone=${_>0?"ok":"warn"} />
        <${Et} label="키퍼 관찰" value=${c.length} detail="연속성 확인 대상" tone=${(($=c[0])==null?void 0:$.brief.status)??"ok"} />
        <${Et} label="최근 응답" value=${g} detail="메인에서 바로 읽을 수 있는 응답 수" tone=${g>0?"ok":"warn"} />
        <${Et} label="내부 신호" value=${m.length} detail="시스템 진단은 보조 면에만 유지" tone=${((S=m[0])==null?void 0:S.severity)??"ok"} />
      </div>

      ${a?i`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${(l==null?void 0:l.goal)??a}${n?` · ${n.summary}`:""}</span>
              <button class="control-btn ghost" onClick=${fm}>선택 해제</button>
            </div>
          `:null}

      <${I} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 작전을 먼저 봅니다.</p>
        </div>
        <div class="mission-list-stack">
          ${t.length>0?t.map(C=>i`<${pv} key=${C.session_id} brief=${C} selected=${a===C.session_id} />`):i`<div class="empty-state">지금 활성 세션이 없습니다.</div>`}
        </div>
      <//>

      <${mv}
        detail=${Pi.value}
        loading=${Es.value}
        error=${Ns.value}
      />

      <div class="mission-human-grid">
        <${I} title="주의 대기열" class="mission-list-card" semanticId="mission.attention_queue">
          <div class="mission-section-head">
            <h3>어느 세션을 먼저 봐야 하나</h3>
            <p>문제와 경고는 세션에 연결된 것만 먼저 보여주고, 원인 분석은 선택된 세션에서 이어서 봅니다.</p>
          </div>
          <div class="mission-lane-stack">
            ${p.length>0?p.map(C=>i`<${uv} key=${C.id} item=${C} selected=${Be.value===C.id} sessionLookup=${o} />`):i`<div class="empty-state">지금 세션 단위 주의 대기열은 비어 있습니다.</div>`}
          </div>
        <//>

        <${I} title="내부 신호" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>시스템 진단</h3>
            <p>artifact scope drift 같은 내부 신호는 메인 판단을 방해하지 않도록 접어 둔 보조 면에만 둡니다.</p>
          </div>
          <details class="mission-card-disclosure">
            <summary>내부 신호 ${m.length}</summary>
            <div class="mission-list-stack">
              ${m.length>0?m.map(C=>i`<${_v} key=${C.id} item=${C} />`):i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
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
          ${c.length>0?c.map(C=>i`<${vv} key=${C.brief.name} row=${C} />`):i`<div class="empty-state">지금 보이는 키퍼가 없습니다.</div>`}
        </div>
        <div class="mission-card-actions">
          <button class="control-btn ghost" onClick=${()=>se("execution")}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${()=>se("command")}>지휘 진단면 보기</button>
        </div>
      <//>
    </section>
  `}const Gl=f(null),ji=f(!1),Ft=f(null);async function Jl(e,t){ji.value=!0,Ft.value=null;try{Gl.value=await Rd(e,t)}catch(n){Ft.value=n instanceof Error?n.message:String(n)}finally{ji.value=!1}}const fv="modulepreload",gv=function(e){return"/dashboard/"+e},tr={},$v=function(t,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(m){return Promise.all(m.map(u=>Promise.resolve(u).then(_=>({status:"fulfilled",value:_}),_=>({status:"rejected",reason:_}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),p=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(m=>{if(m=gv(m),m in tr)return;tr[m]=!0;const u=m.endsWith(".css"),_=u?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${_}`))return;const g=document.createElement("link");if(g.rel=u?"stylesheet":fv,u||(g.as="script"),g.crossOrigin="",g.href=m,p&&g.setAttribute("nonce",p),document.head.appendChild(g),u)return new Promise((h,b)=>{g.addEventListener("load",h),g.addEventListener("error",()=>b(new Error(`Unable to preload CSS for ${m}`)))})}))}function o(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&o(c.reason);return t().catch(o)})},uo=f(null),qe=f(null),sa=f(!1),aa=f(!1),ia=f(null),oa=f(null),Ei=f(null),ra=f(null),G=f("warroom"),ss=f(null),Ni=f(!1),la=f(null),Mt=f(null),ca=f(!1),da=f(null),po=f(null),wi=f(!1),ua=f(null),as=f(null),Di=f(!1),pa=f(null),qn=f(null),ma=f(!1),Fn=f(null),Zt=f(null);let bn=null;function mo(e){return e!=="summary"&&e!=="swarm"&&e!=="warroom"&&e!=="orchestra"}function Vl(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,o)=>{e.has(o)||e.set(o,a)}),e}function Yl(){const t=Vl().get("run_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function Xl(){const t=Vl().get("operation_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function hv(e){if(v(e))return{policy_class:r(e.policy_class),approval_class:r(e.approval_class),tool_allowlist:H(e.tool_allowlist),model_allowlist:H(e.model_allowlist),requires_human_for:H(e.requires_human_for),autonomy_level:r(e.autonomy_level),escalation_timeout_sec:d(e.escalation_timeout_sec),kill_switch:N(e.kill_switch),frozen:N(e.frozen)}}function yv(e){if(v(e))return{headcount_cap:d(e.headcount_cap),active_operation_cap:d(e.active_operation_cap),max_cost_usd:d(e.max_cost_usd),max_tokens:d(e.max_tokens)}}function vo(e){if(!v(e))return null;const t=r(e.unit_id),n=r(e.label),s=r(e.kind);return!t||!n||!s?null:{unit_id:t,label:n,kind:s,parent_unit_id:r(e.parent_unit_id)??null,leader_id:r(e.leader_id)??null,roster:H(e.roster),capability_profile:H(e.capability_profile),source:r(e.source),created_at:r(e.created_at),updated_at:r(e.updated_at),policy:hv(e.policy),budget:yv(e.budget)}}function Ql(e){if(!v(e))return null;const t=vo(e.unit);return t?{unit:t,leader_status:r(e.leader_status),roster_total:d(e.roster_total),roster_live:d(e.roster_live),active_operation_count:d(e.active_operation_count),health:r(e.health),reasons:H(e.reasons),children:Array.isArray(e.children)?e.children.map(Ql).filter(n=>n!==null):[]}:null}function bv(e){if(v(e))return{total_units:d(e.total_units),company_count:d(e.company_count),platoon_count:d(e.platoon_count),squad_count:d(e.squad_count),leaf_agent_unit_count:d(e.leaf_agent_unit_count),live_agent_count:d(e.live_agent_count),managed_unit_count:d(e.managed_unit_count),active_operation_count:d(e.active_operation_count)}}function Zl(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),source:r(t.source),summary:bv(t.summary),units:Array.isArray(t.units)?t.units.map(Ql).filter(n=>n!==null):[]}}function kv(e){if(!v(e))return null;const t=r(e.kind),n=r(e.status);return!t||!n?null:{kind:t,chain_id:r(e.chain_id)??null,goal:r(e.goal)??null,run_id:r(e.run_id)??null,status:n,viewer_path:r(e.viewer_path)??null,last_sync_at:r(e.last_sync_at)??null}}function wa(e){if(!v(e))return null;const t=r(e.operation_id),n=r(e.objective),s=r(e.assigned_unit_id),a=r(e.trace_id),o=r(e.status);return!t||!n||!s||!a||!o?null:{operation_id:t,objective:n,assigned_unit_id:s,autonomy_level:r(e.autonomy_level),policy_class:r(e.policy_class),budget_class:r(e.budget_class),detachment_session_id:r(e.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(e.checkpoint_ref)??null,active_goal_ids:H(e.active_goal_ids),note:r(e.note)??null,created_by:r(e.created_by),source:r(e.source),status:o,chain:kv(e.chain),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function xv(e){if(!v(e))return null;const t=wa(e.operation);return t?{operation:t,assigned_unit_label:r(e.assigned_unit_label)}:null}function $n(e){if(v(e))return{tone:r(e.tone),pending_ops:d(e.pending_ops),blocked_ops:d(e.blocked_ops),in_flight_ops:d(e.in_flight_ops),pipeline_stalls:d(e.pipeline_stalls),bus_traffic:d(e.bus_traffic),l1_hit_rate:d(e.l1_hit_rate),invalidation_count:d(e.invalidation_count),current_pending:d(e.current_pending),current_in_flight:d(e.current_in_flight),cdb_wakeups:d(e.cdb_wakeups),total_stolen:d(e.total_stolen),avg_best_score:d(e.avg_best_score),avg_candidate_count:d(e.avg_candidate_count),best_first_operations:d(e.best_first_operations),active_sessions:d(e.active_sessions),commit_rate:d(e.commit_rate),total_speculations:d(e.total_speculations)}}function Sv(e){if(!v(e))return;const t=v(e.pipeline)?e.pipeline:void 0,n=v(e.cache)?e.cache:void 0,s=v(e.ooo)?e.ooo:void 0,a=v(e.speculative)?e.speculative:void 0,o=v(e.search_fabric)?e.search_fabric:void 0,l=v(e.signals)?e.signals:void 0;return{pipeline:t?{total_ops:d(t.total_ops),completed_ops:d(t.completed_ops),stalled_cycles:d(t.stalled_cycles),hazards_detected:d(t.hazards_detected),forwarding_used:d(t.forwarding_used),pipeline_flushes:d(t.pipeline_flushes),ipc:d(t.ipc)}:void 0,cache:n?{total_reads:d(n.total_reads),total_writes:d(n.total_writes),l1_hit_rate:d(n.l1_hit_rate),invalidation_count:d(n.invalidation_count),writeback_count:d(n.writeback_count),bus_traffic:d(n.bus_traffic)}:void 0,ooo:s?{agent_count:d(s.agent_count),total_added:d(s.total_added),total_issued:d(s.total_issued),total_completed:d(s.total_completed),total_stolen:d(s.total_stolen),cdb_wakeups:d(s.cdb_wakeups),stall_cycles:d(s.stall_cycles),global_cdb_events:d(s.global_cdb_events),current_pending:d(s.current_pending),current_in_flight:d(s.current_in_flight)}:void 0,speculative:a?{total_speculations:d(a.total_speculations),total_commits:d(a.total_commits),total_aborts:d(a.total_aborts),commit_rate:d(a.commit_rate),total_fast_calls:d(a.total_fast_calls),total_cost_usd:d(a.total_cost_usd),active_sessions:d(a.active_sessions)}:void 0,search_fabric:o?{total_operations:d(o.total_operations),best_first_operations:d(o.best_first_operations),legacy_operations:d(o.legacy_operations),blocked_operations:d(o.blocked_operations),ready_operations:d(o.ready_operations),research_pipeline_operations:d(o.research_pipeline_operations),avg_candidate_count:d(o.avg_candidate_count),avg_best_score:d(o.avg_best_score),top_stage:r(o.top_stage)??null}:void 0,signals:l?{issue_pressure:$n(l.issue_pressure),cache_contention:$n(l.cache_contention),scheduler_efficiency:$n(l.scheduler_efficiency),routing_confidence:$n(l.routing_confidence),speculative_posture:$n(l.speculative_posture)}:void 0}}function ec(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),paused:d(n.paused),managed:d(n.managed),projected:d(n.projected)}:void 0,microarch:Sv(t.microarch),operations:Array.isArray(t.operations)?t.operations.map(xv).filter(s=>s!==null):[]}}function tc(e){if(!v(e))return null;const t=r(e.detachment_id),n=r(e.operation_id),s=r(e.assigned_unit_id);return!t||!n||!s?null:{detachment_id:t,operation_id:n,assigned_unit_id:s,leader_id:r(e.leader_id)??null,roster:H(e.roster),session_id:r(e.session_id)??null,checkpoint_ref:r(e.checkpoint_ref)??null,runtime_kind:r(e.runtime_kind)??null,runtime_ref:r(e.runtime_ref)??null,source:r(e.source),status:r(e.status),last_event_at:r(e.last_event_at)??null,last_progress_at:r(e.last_progress_at)??null,heartbeat_deadline:r(e.heartbeat_deadline)??null,created_at:r(e.created_at),updated_at:r(e.updated_at)}}function Cv(e){if(!v(e))return null;const t=tc(e.detachment);return t?{detachment:t,assigned_unit_label:r(e.assigned_unit_label),operation:wa(e.operation)}:null}function nc(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),projected:d(n.projected)}:void 0,detachments:Array.isArray(t.detachments)?t.detachments.map(Cv).filter(s=>s!==null):[]}}function Av(e){if(!v(e))return null;const t=r(e.decision_id),n=r(e.trace_id),s=r(e.requested_action),a=r(e.scope_type),o=r(e.scope_id);return!t||!n||!s||!a||!o?null:{decision_id:t,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:r(e.operation_id)??null,target_unit_id:r(e.target_unit_id)??null,requested_by:r(e.requested_by),status:r(e.status),reason:r(e.reason)??null,source:r(e.source),detail:e.detail,created_at:r(e.created_at),decided_at:r(e.decided_at)??null,expires_at:r(e.expires_at)??null}}function sc(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),pending:d(n.pending),approved:d(n.approved),denied:d(n.denied)}:void 0,decisions:Array.isArray(t.decisions)?t.decisions.map(Av).filter(s=>s!==null):[]}}function Iv(e){if(!v(e))return null;const t=vo(e.unit);return t?{unit:t,roster_total:d(e.roster_total),roster_live:d(e.roster_live),headcount_cap:d(e.headcount_cap),active_operations:d(e.active_operations),active_operation_cap:d(e.active_operation_cap),utilization:d(e.utilization)}:null}function Tv(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),capacity:Array.isArray(t.capacity)?t.capacity.map(Iv).filter(n=>n!==null):[]}}function zv(e){if(!v(e))return null;const t=r(e.alert_id);return t?{alert_id:t,severity:r(e.severity),kind:r(e.kind),scope_type:r(e.scope_type),scope_id:r(e.scope_id),title:r(e.title),detail:r(e.detail),timestamp:r(e.timestamp)}:null}function ac(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),bad:d(n.bad),warn:d(n.warn)}:void 0,alerts:Array.isArray(t.alerts)?t.alerts.map(zv).filter(s=>s!==null):[]}}function ic(e){if(!v(e))return null;const t=r(e.event_id),n=r(e.trace_id),s=r(e.event_type);return!t||!n||!s?null:{event_id:t,trace_id:n,event_type:s,operation_id:r(e.operation_id)??null,unit_id:r(e.unit_id)??null,actor:r(e.actor)??null,source:r(e.source),timestamp:r(e.timestamp),detail:e.detail}}function Rv(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),events:Array.isArray(t.events)?t.events.map(ic).filter(n=>n!==null):[]}}function Pv(e){if(!v(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s}}function Lv(e){if(!v(e))return null;const t=r(e.lane_id),n=r(e.label),s=r(e.kind),a=r(e.phase),o=r(e.motion_state),l=r(e.source_of_truth),c=r(e.movement_reason),p=r(e.current_step);if(!t||!n||!s||!a||!o||!l||!c||!p)return null;const m=v(e.counts)?e.counts:{};return{lane_id:t,label:n,kind:s,present:N(e.present)??!1,phase:a,motion_state:o,source_of_truth:l,last_movement_at:r(e.last_movement_at)??null,movement_reason:c,current_step:p,blockers:H(e.blockers),counts:{operations:d(m.operations),detachments:d(m.detachments),workers:d(m.workers),approvals:d(m.approvals),alerts:d(m.alerts)},hard_flags:Array.isArray(e.hard_flags)?e.hard_flags.map(Pv).filter(u=>u!==null):[]}}function Mv(e){if(!v(e))return null;const t=r(e.event_id),n=r(e.lane_id),s=r(e.kind),a=r(e.timestamp),o=r(e.title),l=r(e.detail),c=r(e.tone),p=r(e.source);return!t||!n||!s||!a||!o||!l||!c||!p?null:{event_id:t,lane_id:n,kind:s,timestamp:a,title:o,detail:l,tone:c,source:p}}function jv(e){if(!v(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s,lane_ids:H(e.lane_ids),count:d(e.count)??0}}function _o(e){if(!v(e))return;const t=v(e.overview)?e.overview:{},n=v(e.gaps)?e.gaps:{},s=v(e.recommended_next_action)?e.recommended_next_action:void 0;return{generated_at:r(e.generated_at),overview:{active_lanes:d(t.active_lanes),moving_lanes:d(t.moving_lanes),stalled_lanes:d(t.stalled_lanes),projected_lanes:d(t.projected_lanes),last_movement_at:r(t.last_movement_at)??null},lanes:Array.isArray(e.lanes)?e.lanes.map(Lv).filter(a=>a!==null):[],timeline:Array.isArray(e.timeline)?e.timeline.map(Mv).filter(a=>a!==null):[],gaps:{count:d(n.count),items:Array.isArray(n.items)?n.items.map(jv).filter(a=>a!==null):[]},recommended_next_action:s?{tool:r(s.tool)??"masc_operator_snapshot",label:r(s.label)??"Observe operator state",reason:r(s.reason)??"",lane_id:r(s.lane_id)??null}:void 0}}function oc(e){if(!v(e))return;const t=v(e.workers)?e.workers:{},n=N(e.pass);return{status:r(e.status)??"missing",source:r(e.source)??"none",run_id:r(e.run_id)??null,captured_at:r(e.captured_at)??null,...n!==void 0?{pass:n}:{},...d(e.peak_hot_slots)!=null?{peak_hot_slots:d(e.peak_hot_slots)}:{},...d(e.ctx_per_slot)!=null?{ctx_per_slot:d(e.ctx_per_slot)}:{},workers:{expected:d(t.expected),joined:d(t.joined),current_task_bound:d(t.current_task_bound),fresh_heartbeats:d(t.fresh_heartbeats),done:d(t.done),final:d(t.final)},artifact_ref:r(e.artifact_ref)??null,missing_reason:r(e.missing_reason)??null}}function Ev(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),topology:Zl(t.topology),operations:ec(t.operations),detachments:nc(t.detachments),alerts:ac(t.alerts),decisions:sc(t.decisions),capacity:Tv(t.capacity),traces:Rv(t.traces),swarm_status:_o(t.swarm_status)}}function Nv(e){const t=v(e)?e:{},n=Zl(t.topology),s=ec(t.operations),a=nc(t.detachments),o=ac(t.alerts),l=sc(t.decisions);return{version:r(t.version),generated_at:r(t.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:_o(t.swarm_status),swarm_proof:oc(t.swarm_proof)}}function wv(e){return v(e)?{chain_id:r(e.chain_id)??null,started_at:d(e.started_at)??null,progress:d(e.progress)??null,elapsed_sec:d(e.elapsed_sec)??null}:null}function rc(e){if(!v(e))return null;const t=r(e.event);return t?{event:t,chain_id:r(e.chain_id)??null,timestamp:r(e.timestamp)??null,duration_ms:d(e.duration_ms)??null,message:r(e.message)??null,tokens:d(e.tokens)??null}:null}function Dv(e){if(!v(e))return null;const t=wa(e.operation);return t?{operation:t,runtime:wv(e.runtime),history:rc(e.history),mermaid:r(e.mermaid)??null,preview_run:lc(e.preview_run)}:null}function Ov(e){const t=v(e)?e:{};return{status:r(t.status)??"disconnected",base_url:r(t.base_url)??null,message:r(t.message)??null}}function qv(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),connection:Ov(t.connection),summary:n?{linked_operations:d(n.linked_operations),active_chains:d(n.active_chains),running_operations:d(n.running_operations),recent_failures:d(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(t.operations)?t.operations.map(Dv).filter(s=>s!==null):[],recent_history:Array.isArray(t.recent_history)?t.recent_history.map(rc).filter(s=>s!==null):[]}}function Fv(e){if(!v(e))return null;const t=r(e.id);return t?{id:t,type:r(e.type),status:r(e.status),duration_ms:d(e.duration_ms)??null,error:r(e.error)??null}:null}function lc(e){if(!v(e))return null;const t=r(e.run_id),n=r(e.chain_id);return n?{run_id:t??null,chain_id:n,duration_ms:d(e.duration_ms),success:N(e.success),mermaid:r(e.mermaid),nodes:Array.isArray(e.nodes)?e.nodes.map(Fv).filter(s=>s!==null):[]}:null}function Kv(e){const t=v(e)?e:{};return{run:lc(t.run)}}function Bv(e){if(!v(e))return null;const t=r(e.title),n=r(e.path);return!t||!n?null:{title:t,path:n}}function Uv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary);return!t||!n||!s?null:{id:t,title:n,summary:s}}function Hv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.tool),a=r(e.summary);return!t||!n||!s||!a?null:{id:t,title:n,tool:s,summary:a,success_signals:H(e.success_signals),pitfalls:H(e.pitfalls)}}function Wv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary),a=r(e.when_to_use);return!t||!n||!s||!a?null:{id:t,title:n,summary:s,when_to_use:a,steps:Array.isArray(e.steps)?e.steps.map(Hv).filter(o=>o!==null):[]}}function Gv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.description);return!t||!n||!s?null:{id:t,title:n,description:s,tools:H(e.tools)}}function Jv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.symptom),a=r(e.why),o=r(e.fix_tool),l=r(e.fix_summary);return!t||!n||!s||!a||!o||!l?null:{id:t,title:n,symptom:s,why:a,fix_tool:o,fix_summary:l}}function Vv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.path_id),a=r(e.transport);return!t||!n||!s||!a?null:{id:t,title:n,path_id:s,transport:a,request:e.request,response:e.response,notes:H(e.notes)}}function Yv(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),docs:Array.isArray(t.docs)?t.docs.map(Bv).filter(n=>n!==null):[],concepts:Array.isArray(t.concepts)?t.concepts.map(Uv).filter(n=>n!==null):[],golden_paths:Array.isArray(t.golden_paths)?t.golden_paths.map(Wv).filter(n=>n!==null):[],tool_groups:Array.isArray(t.tool_groups)?t.tool_groups.map(Gv).filter(n=>n!==null):[],pitfalls:Array.isArray(t.pitfalls)?t.pitfalls.map(Jv).filter(n=>n!==null):[],examples:Array.isArray(t.examples)?t.examples.map(Vv).filter(n=>n!==null):[]}}function Xv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.status),a=r(e.detail),o=r(e.next_tool);return!t||!n||!s||!a||!o?null:{id:t,title:n,status:s,detail:a,next_tool:o}}function Qv(e){if(!v(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.title),a=r(e.detail),o=r(e.next_tool);return!t||!n||!s||!a||!o?null:{code:t,severity:n,title:s,detail:a,next_tool:o}}function Zv(e){if(!v(e))return null;const t=r(e.from),n=r(e.content),s=r(e.timestamp),a=d(e.seq);return!t||!n||!s||a==null?null:{seq:a,from:t,content:n,timestamp:s}}function e_(e){if(!v(e))return null;const t=r(e.name),n=r(e.role),s=r(e.lane),a=r(e.status),o=r(e.claim_marker),l=r(e.done_marker),c=r(e.final_marker);if(!t||!n||!s||!a||!o||!l||!c)return null;const p=(()=>{if(!v(e.last_message))return null;const m=d(e.last_message.seq),u=r(e.last_message.content),_=r(e.last_message.timestamp);return m==null||!u||!_?null:{seq:m,content:u,timestamp:_}})();return{name:t,role:n,lane:s,joined:N(e.joined)??!1,live_presence:N(e.live_presence)??!1,completed:N(e.completed)??!1,status:a,current_task:r(e.current_task)??null,bound_task_id:r(e.bound_task_id)??null,bound_task_title:r(e.bound_task_title)??null,bound_task_status:r(e.bound_task_status)??null,current_task_matches_run:N(e.current_task_matches_run)??!1,squad_member:N(e.squad_member)??!1,detachment_member:N(e.detachment_member)??!1,last_seen:r(e.last_seen)??null,heartbeat_age_sec:d(e.heartbeat_age_sec)??null,heartbeat_fresh:N(e.heartbeat_fresh)??!1,claim_marker_seen:N(e.claim_marker_seen)??!1,done_marker_seen:N(e.done_marker_seen)??!1,final_marker_seen:N(e.final_marker_seen)??!1,claim_marker:o,done_marker:l,final_marker:c,last_message:p}}function t_(e){if(!v(e))return;const t=Array.isArray(e.timeline)?e.timeline.map(n=>{if(!v(n))return null;const s=r(n.timestamp),a=d(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:r(e.slot_url)??null,provider_base_url:r(e.provider_base_url)??null,provider_reachable:N(e.provider_reachable)??null,provider_status_code:d(e.provider_status_code)??null,provider_model_id:r(e.provider_model_id)??null,actual_model_id:r(e.actual_model_id)??null,expected_slots:d(e.expected_slots),actual_slots:d(e.actual_slots),expected_ctx:d(e.expected_ctx),actual_ctx:d(e.actual_ctx),slot_reachable:N(e.slot_reachable)??null,slot_status_code:d(e.slot_status_code)??null,runtime_blocker:r(e.runtime_blocker)??null,detail:r(e.detail)??null,checked_at:r(e.checked_at)??null,total_slots:d(e.total_slots),ctx_per_slot:d(e.ctx_per_slot),active_slots_now:d(e.active_slots_now),peak_active_slots:d(e.peak_active_slots),sample_count:d(e.sample_count),last_sample_at:r(e.last_sample_at)??null,timeline:t}}function n_(e){if(!v(e))return null;const t=r(e.run_id),n=r(e.status),s=r(e.decided_by),a=r(e.decided_at),o=r(e.reason);if(!t||!n||!s||!a||!o)return null;const l=[];return Array.isArray(e.history)&&e.history.forEach(c=>{if(!v(c))return;const p=r(c.status),m=r(c.decided_by),u=r(c.decided_at),_=r(c.reason);!p||!m||!u||!_||l.push({status:p,decided_by:m,decided_at:u,reason:_,operation_id:r(c.operation_id)??null,detachment_id:r(c.detachment_id)??null,note:r(c.note)??null})}),{run_id:t,status:n,decided_by:s,decided_at:a,reason:o,operation_id:r(e.operation_id)??null,detachment_id:r(e.detachment_id)??null,note:r(e.note)??null,history:l}}function s_(e){if(!v(e))return null;const t=r(e.run_id),n=r(e.recommended_kind),s=r(e.reason);return!t||!n||!s?null:{run_id:t,recommended_kind:n,continue_available:N(e.continue_available)??!1,rerun_available:N(e.rerun_available)??!1,abandon_available:N(e.abandon_available)??!1,reason:s,evidence:v(e.evidence)?{operation_id:r(e.evidence.operation_id)??null,detachment_id:r(e.evidence.detachment_id)??null,joined_workers:d(e.evidence.joined_workers),current_task_bound:d(e.evidence.current_task_bound),fresh_heartbeats:d(e.evidence.fresh_heartbeats),trace_events:d(e.evidence.trace_events),message_events:d(e.evidence.message_events),runtime_blocker:r(e.evidence.runtime_blocker)??null}:void 0,provenance:r(e.provenance),decision_engine:r(e.decision_engine),authoritative:N(e.authoritative)}}function a_(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),run_id:r(t.run_id),room_id:r(t.room_id),operation_id:r(t.operation_id)??null,run_resolution:n_(t.run_resolution),resolution_recommendation:s_(t.resolution_recommendation),recommended_next_tool:r(t.recommended_next_tool),summary:n?{expected_workers:d(n.expected_workers),joined_workers:d(n.joined_workers),live_workers:d(n.live_workers),squad_roster_size:d(n.squad_roster_size),detachment_roster_size:d(n.detachment_roster_size),current_task_bound:d(n.current_task_bound),fresh_heartbeats:d(n.fresh_heartbeats),claim_markers_seen:d(n.claim_markers_seen),done_markers_seen:d(n.done_markers_seen),final_markers_seen:d(n.final_markers_seen),completed_workers:d(n.completed_workers),peak_hot_slots:d(n.peak_hot_slots),hot_window_ok:N(n.hot_window_ok),pass_hot_concurrency:N(n.pass_hot_concurrency),pass_end_to_end:N(n.pass_end_to_end),pending_decisions:d(n.pending_decisions),pass:N(n.pass)}:void 0,provider:t_(t.provider),operation:wa(t.operation),squad:vo(t.squad),detachment:tc(t.detachment),workers:Array.isArray(t.workers)?t.workers.map(e_).filter(s=>s!==null):[],checklist:Array.isArray(t.checklist)?t.checklist.map(Xv).filter(s=>s!==null):[],blockers:Array.isArray(t.blockers)?t.blockers.map(Qv).filter(s=>s!==null):[],recent_messages:Array.isArray(t.recent_messages)?t.recent_messages.map(Zv).filter(s=>s!==null):[],recent_trace_events:Array.isArray(t.recent_trace_events)?t.recent_trace_events.map(ic).filter(s=>s!==null):[],truth_notes:H(t.truth_notes)}}function i_(e){if(!v(e))return null;const t=r(e.label),n=r(e.value);return!t||!n?null:{label:t,value:n}}function o_(e){if(!v(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.label),a=r(e.tone),o=r(e.provenance);return!t||!n||!s||!a||!o?null:{id:t,kind:n,label:s,subtitle:r(e.subtitle)??null,status:r(e.status)??null,tone:a,pulse:r(e.pulse)??null,provenance:o,visual_class:r(e.visual_class)??void 0,glyph:r(e.glyph)??void 0,parent_id:r(e.parent_id)??null,lane_id:r(e.lane_id)??null,link_tab:r(e.link_tab)??null,link_surface:r(e.link_surface)??null,link_params:v(e.link_params)?Object.fromEntries(Object.entries(e.link_params).map(([l,c])=>{const p=r(c);return p?[l,p]:null}).filter(l=>l!==null)):{},facts:Array.isArray(e.facts)?e.facts.map(i_).filter(l=>l!==null):[]}}function r_(e){if(!v(e))return null;const t=r(e.id),n=r(e.source),s=r(e.target),a=r(e.kind),o=r(e.tone),l=r(e.provenance);return!t||!n||!s||!a||!o||!l?null:{id:t,source:n,target:s,kind:a,label:r(e.label)??null,tone:o,provenance:l,animated:N(e.animated)}}function l_(e){if(!v(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.label),a=r(e.tone),o=r(e.provenance);return!t||!n||!s||!a||!o?null:{id:t,kind:n,label:s,detail:r(e.detail)??null,tone:a,provenance:o,source_id:r(e.source_id)??null,target_id:r(e.target_id)??null,suggested_surface:r(e.suggested_surface)??null,suggested_params:v(e.suggested_params)?Object.fromEntries(Object.entries(e.suggested_params).map(([l,c])=>{const p=r(c);return p?[l,p]:null}).filter(l=>l!==null)):{}}}function c_(e){if(!v(e))return null;const t=r(e.target_kind),n=r(e.target_id),s=r(e.label),a=r(e.reason);return!t||!n||!s||!a?null:{target_kind:t,target_id:n,label:s,reason:a,suggested_surface:r(e.suggested_surface)??null,suggested_params:v(e.suggested_params)?Object.fromEntries(Object.entries(e.suggested_params).map(([o,l])=>{const c=r(l);return c?[o,c]:null}).filter(o=>o!==null)):{}}}function d_(e){const t=v(e)?e:{},n=v(t.room)?t.room:{},s=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),room:{room_id:r(n.room_id),project:r(n.project),cluster:r(n.cluster),paused:N(n.paused),pause_reason:r(n.pause_reason)??null,agent_count:d(n.agent_count),task_count:d(n.task_count),message_count:d(n.message_count)},summary:s?{session_count:d(s.session_count),operation_count:d(s.operation_count),detachment_count:d(s.detachment_count),lane_count:d(s.lane_count),worker_count:d(s.worker_count),keeper_count:d(s.keeper_count),signal_count:d(s.signal_count),alert_count:d(s.alert_count)}:void 0,nodes:Array.isArray(t.nodes)?t.nodes.map(o_).filter(a=>a!==null):[],edges:Array.isArray(t.edges)?t.edges.map(r_).filter(a=>a!==null):[],signals:Array.isArray(t.signals)?t.signals.map(l_).filter(a=>a!==null):[],focus:c_(t.focus),swarm_status:_o(t.swarm_status),swarm_proof:oc(t.swarm_proof),truth_notes:H(t.truth_notes)}}function at(e){G.value=e,mo(e)&&u_()}async function cc(){sa.value=!0,ia.value=null;try{const e=await Ed();uo.value=Nv(e)}catch(e){ia.value=e instanceof Error?e.message:"Failed to load command-plane summary"}finally{sa.value=!1}}function fo(e){Zt.value=e}async function go(){aa.value=!0,oa.value=null;try{const e=await jd();qe.value=Ev(e)}catch(e){oa.value=e instanceof Error?e.message:"Failed to load command-plane snapshot"}finally{aa.value=!1}}async function u_(){qe.value||aa.value||await go()}async function Kt(){await cc(),mo(G.value)&&await go()}async function en(){var e;Di.value=!0,pa.value=null;try{const t=await Nd(),n=qv(t);as.value=n;const s=Zt.value;n.operations.length===0?Zt.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Zt.value=((e=n.operations[0])==null?void 0:e.operation.operation_id)??null)}catch(t){pa.value=t instanceof Error?t.message:"Failed to load chain summary"}finally{Di.value=!1}}function p_(){bn=null,qn.value=null,ma.value=!1,Fn.value=null}async function m_(e){bn=e,ma.value=!0,Fn.value=null;try{const t=await wd(e);if(bn!==e)return;qn.value=Kv(t)}catch(t){if(bn!==e)return;qn.value=null,Fn.value=t instanceof Error?t.message:"Failed to load chain run"}finally{bn===e&&(ma.value=!1)}}async function v_(){Ni.value=!0,la.value=null;try{const e=await Dd();ss.value=Yv(e)}catch(e){la.value=e instanceof Error?e.message:"Failed to load command-plane help"}finally{Ni.value=!1}}async function Qe(e=Yl(),t=Xl()){ca.value=!0,da.value=null;try{const n=await Od(e,t);Mt.value=a_(n)}catch(n){da.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{ca.value=!1}}async function Tt(e=Yl(),t=Xl()){wi.value=!0,ua.value=null;try{const n=await qd(e,t);po.value=d_(n)}catch(n){ua.value=n instanceof Error?n.message:"Failed to load orchestra map"}finally{wi.value=!1}}async function vt(e,t,n){Ei.value=e,ra.value=null;try{await Fd(t,n),await cc(),(qe.value||mo(G.value))&&await go(),await Qe(),await Tt(),await en()}catch(s){throw ra.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{Ei.value=null}}function __(e){return vt(`pause:${e}`,"/api/v1/command-plane/operations/pause",{operation_id:e})}function f_(e){return vt(`resume:${e}`,"/api/v1/command-plane/operations/resume",{operation_id:e})}function g_(e){return vt(`recall:${e}`,"/api/v1/command-plane/dispatch/recall",{operation_id:e})}function $_(e={}){return vt("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...e.operationId?{operation_id:e.operationId}:{},...e.detachmentId?{detachment_id:e.detachmentId}:{}})}function h_(e){return vt(`approve:${e}`,"/api/v1/command-plane/policy/approve",{decision_id:e})}function y_(e){return vt(`deny:${e}`,"/api/v1/command-plane/policy/deny",{decision_id:e})}function b_(e,t){return vt(`freeze:${e}`,"/api/v1/command-plane/policy/freeze",{unit_id:e,enabled:t})}function k_(e,t){return vt(`kill:${e}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:e,enabled:t})}Cp(()=>{Kt(),en(),(G.value==="swarm"||G.value==="warroom"||G.value==="orchestra"||Mt.value!==null)&&Qe(),(G.value==="orchestra"||po.value!==null)&&Tt(),G.value==="warroom"&&ye()});function va(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function X(e){if(!e)return"정보 없음";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function x_(e){if(!e)return"warn";const t=Date.parse(e);return Number.isNaN(t)?"warn":t<=Date.now()?"bad":"ok"}function dc(e){if(!e)return"정보 없음";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.round((t-Date.now())/1e3);return n<=0?"기한 지남":n<60?`${n}초 후`:n<3600?`${Math.round(n/60)}분 후`:n<86400?`${Math.round(n/3600)}시간 후`:`${Math.round(n/86400)}일 후`}function P(e){return e==="bad"?"bad":e==="warn"||e==="pending"?"warn":"ok"}let nr=!1,S_=0;function C_(){return++S_}let Ga=null;async function A_(){Ga||(Ga=$v(()=>import("./mermaid.core-VO_lyTgA.js").then(t=>t.bE),[]).then(t=>t.default));const e=await Ga;return nr||(e.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),nr=!0),e}function it(e){if(!e)return"warn";const t=e.toLowerCase();return t.includes("failed")||t.includes("error")||t.includes("disconnected")||t.includes("stopped")?"bad":t.includes("running")||t.includes("active")||t.includes("degraded")||t.includes("pending")?"warn":"ok"}function is(e){return typeof e!="number"||!Number.isFinite(e)?"정보 없음":`${Math.round(e*100)}%`}function kn(e){return typeof e!="number"||!Number.isFinite(e)?"정보 없음":e<60?`${Math.round(e)}초`:e<3600?`${Math.round(e/60)}분`:`${Math.round(e/3600)}시간`}function os(e){return typeof e!="number"||!Number.isFinite(e)?0:Math.max(0,Math.min(100,e))}function yt(e,t){return typeof e!="number"||!Number.isFinite(e)||typeof t!="number"||!Number.isFinite(t)||t<=0?0:os(e/t*100)}function I_(e,t){const n=os(e);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${t};`}function uc(e){if(!e)return"최근 체인 이력이 없습니다";const t=[e.event];return typeof e.duration_ms=="number"&&t.push(`${e.duration_ms}ms`),typeof e.tokens=="number"&&t.push(`토큰 ${e.tokens}`),e.message&&t.push(e.message),t.join(" · ")}const T_=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],pc=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"orchestra",label:"오케스트라",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],z_=pc.map(e=>e.id),R_=["chain_start","node_start","node_complete","chain_complete","chain_error"],P_={warroom:{title:"실시간 워룸",description:"실제 실행, 워커, 메시지, 트레이스를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 작전, 분견대, 의존 관계를 먼저 읽는 기본 진입 표면입니다."},orchestra:{title:"룸 오케스트라 맵",description:"룸, 세션, 레인, 워커, 키퍼를 한 장의 작전판으로 읽는 시각화 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"레인 이동, 워커 결속, 막힘을 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 작전별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"실제 관리 유닛인지, 실시간 에이전트 기반 자동 투영인지 구분해서 봅니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"작전, 주체, 유닛 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"결정 승인과 유닛 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function sr(e){return!!e&&z_.includes(e)}function L_(){const e=F.value.params;return e.source!=="mission"&&e.source!=="execution"?{}:{source:e.source,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function $o(e){const t=L_(),n=_c(),s=ho();if(e==="operations")return t;if(e==="chains"){const a=Zt.value;return a?{...t,surface:e,operation:a}:{...t,surface:e}}return e==="swarm"||e==="warroom"||e==="orchestra"?{...t,surface:e,...n?{run_id:n}:{},...s?{operation_id:s}:{}}:{...t,surface:e}}function M_(){const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");return n&&t.set("agent",n),s&&t.set("token",s),t.toString()?`/api/v1/chains/events?${t.toString()}`:"/api/v1/chains/events"}function j_(e){switch(e){case"company":return"중대";case"platoon":return"소대";case"squad":return"분대";case"agent":return"에이전트";default:return e}}function oe(e){return Ei.value===e}function rs(){return uo.value}function E_(e){var a,o,l,c,p,m,u;const t=uo.value,n=Mt.value,s=as.value;switch(e){case"warroom":return{tool:"masc_observe_operations",reason:"실시간 실행, 워커, 메시지, 트레이스를 한 화면에서 보고 필요한 세부 표면으로 바로 이동합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=t==null?void 0:t.operations.summary)==null?void 0:a.active)??0}개와 의존 관계를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(o=t==null?void 0:t.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((p=(c=t==null?void 0:t.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:p.reason)??"레인 이동과 막힘 근거를 보고 다음 확인 도구를 고릅니다."};case"orchestra":return{tool:"masc_operator_snapshot",reason:"룸, 세션, 레인, 워커, 키퍼를 한 장에서 훑은 뒤 내려볼 대상을 고릅니다."};case"chains":return{tool:(u=(m=s==null?void 0:s.operations[0])==null?void 0:m.preview_run)!=null&&u.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"이 구조가 실제 관리 단위인지 자동 투영인지 먼저 구분해야 지휘면을 오해하지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 유닛과 작전을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"트레이스 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 제어 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function N_(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"microarch":t.includes("leader_offline")||t.includes("roster_offline")?"alerts":t.includes("stale_data")?"swarm":null:null}function w_(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")?"recommendation":t.includes("gap")?"gaps":null:null}function mc(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");if(!t)return null;const n=t.trim();return n===""?null:n}function vc(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,o)=>{e.has(o)||e.set(o,a)}),e}function _c(){const t=vc().get("run_id");if(!t)return null;const n=t.trim();return n===""?null:n}function ho(){const t=vc().get("operation_id");if(!t)return null;const n=t.trim();return n===""?null:n}function D_(e){if(!e)return null;const t=Date.parse(e);return Number.isNaN(t)?null:Math.max(0,Math.round((Date.now()-t)/1e3))}function O_(e){return e.status==="claimed"||e.status==="in_progress"}function q_(e){const t=ss.value;if(!t)return null;for(const n of t.golden_paths){const s=n.steps.find(a=>a.tool===e);if(s)return s}return null}function Ja(e){var t;return((t=ss.value)==null?void 0:t.golden_paths.find(n=>n.id===e))??null}function F_(e){const t=ss.value;if(!t)return[];const n=new Set(e);return t.pitfalls.filter(s=>n.has(s.id))}async function ot(e){try{await e()}catch{}}function yo(e){return(e==null?void 0:e.trim().toLowerCase())??""}function Bt(e){const t=yo(e);return t.includes("failed")||t.includes("error")||t.includes("stopped")||t==="paused"?"bad":t.includes("active")||t.includes("running")||t.includes("healthy")||t.includes("ok")?"ok":"warn"}function bt(e){const t=yo(e);return t?t==="active"||t==="running"?"진행 중":t==="paused"?"일시정지":t==="done"||t==="ended"||t==="completed"?"완료":t==="failed"||t==="error"||t==="stopped"?"문제":(e==null?void 0:e.trim())||"확인 필요":"확인 필요"}function K_(){var n,s,a,o,l,c,p,m,u;const e=Mt.value;if(!e)return!1;const t=e.workers.some(_=>_.joined||_.live_presence||_.completed||_.current_task_matches_run||_.heartbeat_fresh||_.claim_marker_seen||_.done_marker_seen||_.final_marker_seen||!!_.current_task||!!_.bound_task_id||!!_.last_message);return!!((n=e.operation)!=null&&n.operation_id||(s=e.detachment)!=null&&s.detachment_id||(((a=e.summary)==null?void 0:a.joined_workers)??0)>0||(((o=e.summary)==null?void 0:o.live_workers)??0)>0||(((l=e.summary)==null?void 0:l.current_task_bound)??0)>0||(((c=e.summary)==null?void 0:c.fresh_heartbeats)??0)>0||(((p=e.summary)==null?void 0:p.claim_markers_seen)??0)>0||(((m=e.summary)==null?void 0:m.done_markers_seen)??0)>0||(((u=e.summary)==null?void 0:u.final_markers_seen)??0)>0||t||e.recent_messages.length>0||e.recent_trace_events.length>0)}function B_(e){const t=yo(e.status);return t==="active"||t==="running"}function U_(){var o,l,c,p;const e=((o=_e.value)==null?void 0:o.sessions)??[],t=Mt.value,n=((l=t==null?void 0:t.detachment)==null?void 0:l.session_id)??null;if(n){const m=e.find(u=>u.session_id===n);if(m)return m}const s=((c=t==null?void 0:t.operation)==null?void 0:c.operation_id)??ho();if(s){const m=e.find(u=>u.command_plane_operation_id===s);if(m)return m}const a=((p=t==null?void 0:t.detachment)==null?void 0:p.detachment_id)??null;if(a){const m=e.find(u=>u.command_plane_detachment_id===a);if(m)return m}return e.find(B_)??e[0]??null}function Va(e){return e==="proven"?"ok":e==="partial"?"warn":"bad"}function Tn(e){return Array.isArray(e)?e:[]}function Pe(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)?e:{}}function $s(e){return typeof e=="string"&&e.trim()!==""?e:null}function H_(e){return typeof e=="number"&&Number.isFinite(e)?e:null}function W_(e){const t=e.split("/");return t.length<=3?e:`…/${t.slice(-3).join("/")}`}function G_(e){return e==="proven"?"충분":e==="partial"?"부분":"부족"}function J_(e){return e==="proven"?"협업 증거가 충분합니다":e==="partial"?"흔적은 있으나 협업 증거가 덜 모였습니다":"증거가 부족합니다"}function V_(e,t,n,s,a){const o=[`${t}명의 actor 흔적이 기록돼 있습니다.`,n>0?`서로를 참조한 상호작용 증거가 ${n}건 있습니다.`:"서로를 참조한 명시적 상호작용 증거가 아직 없습니다.",s>0?`도구·산출물·체크포인트 증거가 ${s}건 있습니다.`:"도구·산출물·체크포인트 증거가 거의 없습니다.",a>0?`CPv2 backing trace가 ${a}건 있어 실행 흔적은 남아 있습니다.`:"관리형 backing trace는 아직 없습니다."];return e==="partial"?[o[0]??"",n===0?"partial인 이유: 참여 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.":"partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.",a>0?"다음 보강 포인트: 대화/상호참조 event를 남기면 proof가 더 강해집니다.":"다음 보강 포인트: 관리형 trace 또는 산출물 연결을 더 남기면 근거가 강해집니다."]:e==="proven"?[o[0]??"","결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.","다음 행동: raw evidence는 접어두고 세션 결과와 산출물만 확인하면 됩니다."]:[o[0]??"","결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.","다음 보강 포인트: 참여자 간 턴, 도구 근거, 산출물 연결을 더 남겨야 합니다."]}function Y_(e){const t=new Map;for(const n of e){const s=[n.timestamp??"",n.event_type??"",n.actor??"",n.summary??""].join("|"),a=n.source??"unknown",o=t.get(s);if(o){o.sources.includes(a)||o.sources.push(a),!o.operation_id&&n.operation_id&&(o.operation_id=n.operation_id);continue}t.set(s,{...n,sources:[a]})}return[...t.values()]}function X_(e){return e.sources.length===2?"세션 + 지휘":e.sources.length===1?e.sources[0]==="unknown"?"출처 미상":e.sources[0]??"출처":e.sources.join(" + ")}function Q_(e){const t=[];for(const[n,s]of Object.entries(e))if(s!=null){if(typeof s=="string"){if(s.trim()==="")continue;t.push({label:n,value:s});continue}if(typeof s=="number"||typeof s=="boolean"){t.push({label:n,value:String(s)});continue}}return t}function Z_(e){const t=Pe(e),n=Pe(t.traces),s=Array.isArray(n.events)?n.events:[],a=Pe(t.detachments),o=Array.isArray(a.detachments)?a.detachments:[],l=Pe(o[0]),c=Pe(l.detachment),p=Pe(l.operation),m=Pe(t.summary),u=Pe(m.operations),_=Pe(u.summary);return[{label:"작전",value:$s(t.operation_id)??"없음"},{label:"분견대",value:$s(t.detachment_id)??"없음"},{label:"트레이스 이벤트",value:`${s.length}`},{label:"분견대 상태",value:$s(c.status)??"없음"},{label:"작전 단계",value:$s(p.stage)??"없음"},{label:"활성 작전",value:`${H_(_.active)??0}`}]}function ef({item:e}){return i`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${e.summary??e.event_type??"이벤트"}</strong>
          <div class="command-meta-line">
            <span>${X_(e)}</span>
            <span>${e.event_type??"이벤트"}</span>
            <span>${e.actor??"시스템"}</span>
          </div>
        </div>
        <span class="command-chip">${X(e.timestamp)}</span>
      </div>
      ${e.sources.length>1?i`<div class="semantic-tag-row">
            ${e.sources.map(t=>i`<span class="semantic-tag">${t}</span>`)}
          </div>`:null}
    </article>
  `}function tf({item:e}){const t=e.recent_output_preview??null,n=e.recent_input_preview??null,s=e.recent_event_summary??null,a=(e.interaction_count??0)>0?"ok":"warn";return i`
    <article class="mission-activity-row proof-actor-row">
      <div class="mission-activity-head">
        <div>
          <strong>${e.actor}</strong>
          <div class="mission-activity-meta">
            <span>${e.role??"참여자"}</span>
            <span>${e.last_active_at?X(e.last_active_at):"기록 없음"}</span>
          </div>
        </div>
        <span class="command-chip ${a}">
          ${(e.interaction_count??0)>0?`상호작용 ${e.interaction_count}`:"상호작용 없음"}
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>턴 ${e.turn_count??0}</span>
        <span>spawn ${e.spawn_count??0}</span>
        <span>도구 근거 ${e.tool_evidence_count??0}</span>
      </div>
      ${s?i`<div class="proof-summary-block">
            <strong>최근 흔적</strong>
            <span>${s}</span>
          </div>`:null}
      ${n||t?i`<div class="proof-io-grid">
            <div class="mission-activity-preview">
              <strong>최근 입력</strong>
              <span>${n??"표시 가능한 입력 없음"}</span>
            </div>
            <div class="mission-activity-preview">
              <strong>최근 응답</strong>
              <span>${t??"표시 가능한 응답 없음"}</span>
            </div>
          </div>`:null}
      ${Tn(e.recent_tool_names).length>0?i`<div class="semantic-tag-row">
            ${Tn(e.recent_tool_names).map(o=>i`<span class="semantic-tag">${o}</span>`)}
          </div>`:null}
    </article>
  `}function nf({item:e}){return i`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${e.kind}</strong>
          <div class="command-meta-line">
            <span>${W_(e.path)}</span>
          </div>
        </div>
        <span class="command-chip ${e.exists?"ok":"warn"}">${e.exists?"존재함":"없음"}</span>
      </div>
    </article>
  `}function ar({title:e,rows:t}){return t.length===0?null:i`
    <div class="proof-kv-block">
      ${e?i`<strong>${e}</strong>`:null}
      <div class="proof-kv-grid">
        ${t.map(n=>i`
          <span>${n.label}</span>
          <strong>${n.value}</strong>
        `)}
      </div>
    </div>
  `}function sf(){var L,T,R;const e=F.value.params,t=e.session_id??null,n=e.operation_id??null;ne(()=>{Jl(t,n)},[t,n]);const s=Gl.value;if(ji.value&&!s)return i`<section class="dashboard-panel"><div class="loading-indicator">근거 화면 불러오는 중…</div></section>`;if(Ft.value&&!s)return i`<section class="dashboard-panel"><div class="error-card">${Ft.value}</div></section>`;const a=s==null?void 0:s.summary,o=Tn(s==null?void 0:s.actor_contributions),l=Tn(s==null?void 0:s.artifacts),c=(s==null?void 0:s.proof_verdict)??"insufficient",p=(s==null?void 0:s.cp_backing_evidence)??null,m=Array.isArray((L=p==null?void 0:p.traces)==null?void 0:L.events)?((R=(T=p.traces)==null?void 0:T.events)==null?void 0:R.length)??0:0,u=(a==null?void 0:a.actors_count)??o.length,_=(a==null?void 0:a.interaction_count)??0,g=(a==null?void 0:a.evidence_count)??0,h=Y_(Tn(s==null?void 0:s.timeline)),b=Q_(Pe(s==null?void 0:s.goal_binding)),$=Z_(p),S=l.filter(M=>M.exists).length,C=l.length-S,x=V_(c,u,_,g,m);return i`
    <section class="dashboard-panel mission-view">
      <${be} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>근거</h2>
          <p>이 세션이 실제로 여러 참여자의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${Va(c)}">${G_(c)}</span>
          ${s!=null&&s.session_id?i`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?i`<span class="command-chip">${X(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${Ft.value?i`<div class="error-card">${Ft.value}</div>`:null}

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${Va(c)}">
          <span>판정</span>
          <strong>${J_(c)}</strong>
          <small>${(a==null?void 0:a.detail)??"협업 증거를 verdict로 요약합니다."}</small>
        </div>
        <div class="summary-stat-card">
          <span>참여자</span>
          <strong>${u}</strong>
          <small>기록된 참여자 수</small>
        </div>
        <div class="summary-stat-card ${_>0?"ok":"warn"}">
          <span>상호작용</span>
          <strong>${_}</strong>
          <small>참여자 간 직접 상호작용 근거</small>
        </div>
        <div class="summary-stat-card ${g>0?"ok":"warn"}">
          <span>근거</span>
          <strong>${g}</strong>
          <small>도구 / 산출물 / 체크포인트</small>
        </div>
        <div class="summary-stat-card ${m>0?"ok":"warn"}">
          <span>CP 트레이스</span>
          <strong>${m}</strong>
          <small>관리형 backing 이벤트</small>
        </div>
        <div class="summary-stat-card ${C===0&&l.length>0?"ok":"warn"}">
          <span>산출물</span>
          <strong>${S}/${l.length}</strong>
          <small>${C>0?`${C}개 누락`:"전부 존재함"}</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${I} title="3줄 근거 요약" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, partial 이유, 다음 보강 포인트만 먼저 봅니다.</p>
          </div>
          <div class="proof-summary-stack">
            ${x.map((M,z)=>i`
              <article class="proof-summary-block ${z===1&&c!=="proven"?Va(c):""}">
                <strong>${z===0?"지금 결론":z===1?"왜 이렇게 판정됐나":"다음 보강 포인트"}</strong>
                <span>${M}</span>
              </article>
            `)}
          </div>
        <//>

        <${I} title="목표 연결" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 근거가 어느 세션, 목표, 작전에 묶였는지 읽습니다.</p>
          </div>
          <${ar} rows=${b} />
          <details class="mission-card-disclosure compact">
            <summary>원본 목표 연결 JSON</summary>
            <pre class="command-json-block">${va((s==null?void 0:s.goal_binding)??{})}</pre>
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
            ${h.length>0?h.slice(0,18).map(M=>i`<${ef} key=${M.id} item=${M} />`):i`<div class="empty-state">표시할 타임라인 근거가 없습니다.</div>`}
          </div>
        <//>

        <${I} title="참여 흔적" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>턴 수보다 최근 흔적, 입출력, 도구, 상호작용 유무를 우선 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${o.length>0?o.map(M=>i`<${tf} key=${M.actor} item=${M} />`):i`<div class="empty-state">표시할 참여 흔적이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${I} title="실행 근거" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>작전, 분견대, 트레이스 수만 먼저 보고, 원본 CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${ar} rows=${$} />
          <details class="mission-card-disclosure compact">
            <summary>원본 CPv2 backing JSON</summary>
            <pre class="command-json-block">${va(p??{})}</pre>
          </details>
        <//>

        <${I} title="산출물" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>어떤 파일 산출물이 남았나</h3>
            <p>proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${l.length>0?l.map(M=>i`<${nf} key=${M.path} item=${M} />`):i`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function af(){const e=ns(F.value);return e?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${e.source_label}</strong>
        <span class="command-chip">${ja(e.action_type)}</span>
        <span class="command-chip">${io(e)}</span>
        <span class="command-chip">${lm(F.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${e.summary}</div>
      ${e.payload_preview?i`<div class="command-focus-preview">${e.payload_preview}</div>`:null}
    </section>
  `:null}function of(){const e=G.value,t=P_[e],n=E_(e);return i`
    <section class="command-entry-strip">
      <article class="command-entry-card">
        <span class="command-entry-label">현재 표면</span>
        <strong>${t.title}</strong>
        <p>${t.description}</p>
      </article>
      <article class="command-entry-card">
        <span class="command-entry-label">다음 추천</span>
        <strong>${n.tool}</strong>
        <p>${n.reason}</p>
      </article>
    </section>
  `}function hs({label:e,value:t,subtext:n,percent:s,color:a}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${I_(s,a)}>
        <div class="command-gauge-core">
          <strong>${t}</strong>
          <span>${Math.round(os(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${e}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function ys({label:e,value:t,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${P(a)}">
      <div class="command-signal-copy">
        <span>${e}</span>
        <strong>${t}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${P(a)}" style=${`width: ${Math.max(8,Math.round(os(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function rf(){var Z,ie,V,ee;const e=rs(),t=e==null?void 0:e.topology.summary,n=e==null?void 0:e.operations.summary,s=e==null?void 0:e.detachments.summary,a=e==null?void 0:e.decisions.summary,o=e==null?void 0:e.alerts.summary,l=(Z=e==null?void 0:e.swarm_status)==null?void 0:Z.overview,c=e==null?void 0:e.swarm_proof,p=e==null?void 0:e.operations.microarch,m=(t==null?void 0:t.managed_unit_count)??0,u=(t==null?void 0:t.total_units)??0,_=(n==null?void 0:n.active)??0,g=(s==null?void 0:s.active)??0,h=(l==null?void 0:l.moving_lanes)??0,b=(l==null?void 0:l.active_lanes)??0,$=(c==null?void 0:c.workers.done)??0,S=(c==null?void 0:c.workers.expected)??0,C=(o==null?void 0:o.bad)??0,x=(o==null?void 0:o.warn)??0,L=(a==null?void 0:a.pending)??0,T=(a==null?void 0:a.total)??0,R=_+g,M=((ie=p==null?void 0:p.cache)==null?void 0:ie.l1_hit_rate)??((ee=(V=p==null?void 0:p.signals)==null?void 0:V.cache_contention)==null?void 0:ee.l1_hit_rate)??0,z=_>0||g>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",j=_>0||h>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${z}</h3>
        <p>${j}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${P(_>0?"ok":"warn")}">활성 작전 ${_}</span>
          <span class="command-chip ${P(h>0?"ok":(b>0,"warn"))}">이동 레인 ${h}/${Math.max(b,h)}</span>
          <span class="command-chip ${P(C>0?"bad":x>0?"warn":"ok")}">치명 알림 ${C}</span>
          <span class="command-chip ${P(L>0?"warn":"ok")}">승인 대기 ${L}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${hs}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(u,m)}`}
          subtext=${u>0?`${u-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${yt(m,Math.max(u,m))}
          color="#67e8f9"
        />
        <${hs}
          label="실행 열도"
          value=${String(R)}
          subtext=${`${_}개 작전 + ${g}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${yt(R,Math.max(m,R||1))}
          color="#4ade80"
        />
        <${hs}
          label="스웜 이동감"
          value=${`${h}/${Math.max(b,h)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${X(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${yt(h,Math.max(b,h||1))}
          color="#fbbf24"
        />
        <${hs}
          label="증거 수집률"
          value=${`${$}/${Math.max(S,$)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${yt($,Math.max(S,$||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${ys}
        label="승인 대기열"
        value=${`${L}건 대기`}
        detail=${`현재 정책 창에서 ${T}개 결정을 추적 중입니다`}
        percent=${yt(L,Math.max(T,L||1))}
        tone=${L>0?"warn":"ok"}
      />
      <${ys}
        label="알림 압력"
        value=${`치명 ${C} / 주의 ${x}`}
        detail=${C>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${yt(C*2+x,Math.max((C+x)*2,1))}
        tone=${C>0?"bad":x>0?"warn":"ok"}
      />
      <${ys}
        label="디스패치 점유"
          value=${`${g}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${yt(g,Math.max(m,g||1))}
        tone=${g>0?"ok":"warn"}
      />
      <${ys}
        label="캐시 신뢰도"
        value=${M?is(M):"정보 없음"}
        detail=${M?"microarch 캐시 텔레메트리에서 집계한 L1 적중률":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${os((M??0)*100)}
        tone=${M>=.75?"ok":M>=.4?"warn":"bad"}
      />
    </div>
  `}function lf(){var g,h,b,$,S;const e=rs(),t=as.value,n=ns(F.value),s=N_(n),a=e==null?void 0:e.topology.summary,o=e==null?void 0:e.operations.summary,l=(g=e==null?void 0:e.swarm_status)==null?void 0:g.overview,c=e==null?void 0:e.operations.microarch,p=e==null?void 0:e.decisions.summary,m=e==null?void 0:e.alerts.summary,u=(h=c==null?void 0:c.signals)==null?void 0:h.issue_pressure,_=c==null?void 0:c.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((b=e==null?void 0:e.detachments.summary)==null?void 0:b.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(p==null?void 0:p.pending)??0}</strong><small>${(p==null?void 0:p.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 주의</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${(($=t==null?void 0:t.summary)==null?void 0:$.active_chains)??0}</strong><small>${((S=t==null?void 0:t.summary)==null?void 0:S.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${X(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(_==null?void 0:_.l1_hit_rate)!=null?`${is(_.l1_hit_rate)} L1 적중`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"정보 없음"}</small></div>
    </div>
  `}function cf(){var Z,ie,V,ee,A,Te,Je,_t,ft;const e=rs(),t=qe.value,n=te.value,s=mc(),a=s?Ge.value.find(K=>K.name===s)??null:null,o=s?et.value.filter(K=>K.assignee===s&&O_(K)):[],l=((Z=e==null?void 0:e.operations.summary)==null?void 0:Z.active)??0,c=((ie=e==null?void 0:e.detachments.summary)==null?void 0:ie.total)??0,p=((V=e==null?void 0:e.decisions.summary)==null?void 0:V.pending)??0,m=t==null?void 0:t.detachments.detachments.find(K=>{const ze=K.detachment.heartbeat_deadline,gt=ze?Date.parse(ze):Number.NaN;return K.detachment.status==="stalled"||!Number.isNaN(gt)&&gt<=Date.now()}),u=t==null?void 0:t.alerts.alerts.find(K=>K.severity==="bad"),_=!!(n!=null&&n.room||n!=null&&n.project),g=(a==null?void 0:a.current_task)??null,h=D_(a==null?void 0:a.last_seen),b=h!=null?h<=120:null,$=[_?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:et.value.length>0?"masc_claim":"masc_add_task"}:g?b===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${g} 이지만 heartbeat가 stale 합니다 (${h}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${g}${h!=null?` · 마지막 활동 ${h}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!e||(((ee=e.topology.summary)==null?void 0:ee.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((A=e.topology.summary)==null?void 0:A.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Te=e.topology.summary)==null?void 0:Te.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},p>0?{title:"디스패치 준비도",tone:"warn",detail:`${p}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||u?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${u?` · alert ${u.title??u.alert_id}`:""}${!t&&!m&&!u?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${t?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],S=_?!s||!a?"masc_join":o.length===0?et.value.length>0?"masc_claim":"masc_add_task":g?b===!1?"masc_heartbeat":!e||(((Je=e.topology.summary)==null?void 0:Je.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":p>0?"masc_policy_approve":l>0&&c===0||m||u?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",C=q_(S),L=F_(S==="masc_set_room"?["repo-root-room"]:S==="masc_plan_set_task"?["claimed-not-current"]:S==="masc_heartbeat"?["heartbeat-stale"]:S==="masc_dispatch_tick"?["no-detachments"]:S==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),T=Ja("room_task_hygiene"),R=Ja("cpv2_benchmark"),M=Ja("supervisor_session"),z=((_t=ss.value)==null?void 0:_t.docs)??[],j=[T,R,M].filter(K=>K!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${O} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(C==null?void 0:C.title)??S}</strong>
            <span class="command-chip ok">${S}</span>
          </div>
          <p>${(C==null?void 0:C.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(ft=C==null?void 0:C.success_signals)!=null&&ft.length?i`<div class="command-tag-row">
                ${C.success_signals.map(K=>i`<span class="command-tag ok">${K}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${$.map(K=>i`
            <article class="command-readiness-row ${P(K.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${K.title}</strong>
                  <span class="command-chip ${P(K.tone)}">${K.tone}</span>
                </div>
                <p>${K.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${K.tool}</div>
            </article>
          `)}
        </div>

        ${L.length>0?i`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${L.length}</span>
                </div>
                <div class="command-guide-list">
                  ${L.map(K=>i`
                    <article class="command-guide-inline">
                      <strong>${K.title}</strong>
                      <div>${K.symptom}</div>
                      <div class="command-card-sub">${K.fix_tool} 로 해결: ${K.fix_summary}</div>
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
        ${Ni.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:la.value?i`<div class="empty-state error">${la.value}</div>`:i`
                <div class="command-path-grid">
                  ${j.map(K=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${K.title}</strong>
                        <span class="command-chip">${K.id}</span>
                      </div>
                      <p>${K.summary}</p>
                      <div class="command-card-sub">${K.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${K.steps.slice(0,4).map(ze=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${ze.tool}</span>
                            <span>${ze.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${z.length>0?i`<div class="command-doc-links">
                      ${z.map(K=>i`<span class="command-tag">${K.title}: ${K.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function df(){return i`
    <${rf} />
    <${lf} />
    <${cf} />
  `}function uf(){return aa.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:oa.value?i`<div class="empty-state error">${oa.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}const Oi=f(null),ir=1280,or=760;function rr(e){switch((e??"").trim().toLowerCase()){case"room":return"룸";case"session":return"세션";case"operation":return"작전";case"detachment":return"분견대";case"lane":return"레인";case"worker":return"워커";case"keeper":return"키퍼";default:return(e==null?void 0:e.trim())||"노드"}}function hn(e,t,n){if(e<=0)return[];if(e===1)return[Math.round((t+n)/2)];const s=(n-t)/(e-1);return Array.from({length:e},(a,o)=>Math.round(t+o*s))}function pf(e,t){const n=new Map;for(const s of e){const a=t(s),o=n.get(a)??[];o.push(s),n.set(a,o)}return n}function mf(e){const t=new Map,n=e.nodes,s=n.find(b=>b.kind==="room")??null,a=n.filter(b=>b.kind==="session"),o=n.filter(b=>b.kind==="operation"),l=n.filter(b=>b.kind==="detachment"),c=n.filter(b=>b.kind==="lane"),p=n.filter(b=>b.kind==="worker"),m=n.filter(b=>b.kind==="keeper");s&&t.set(s.id,{x:640,y:96}),hn(a.length,170,1110).forEach((b,$)=>{const S=a[$];S&&t.set(S.id,{x:b,y:220})}),hn(o.length,240,1040).forEach((b,$)=>{const S=o[$];S&&t.set(S.id,{x:b,y:330})}),hn(l.length,300,980).forEach((b,$)=>{const S=l[$];S&&t.set(S.id,{x:b,y:420})}),hn(c.length,170,1110).forEach((b,$)=>{const S=c[$];S&&t.set(S.id,{x:b,y:530})});const u=new Map(c.map(b=>{const $=t.get(b.id);return $?[b.id,$.x]:null}).filter(b=>b!==null)),_=pf(p,b=>b.lane_id?`lane:${b.lane_id}`:b.parent_id?b.parent_id:"free");let g=0;for(const[b,$]of _){let S=u.get(b);if(S==null){const x=t.get(b);S=x==null?void 0:x.x}S==null&&(S=180+g%5*200,g+=1),hn($.length,S-90,S+90).forEach((x,L)=>{const T=$[L];if(!T)return;const R=L>5?Math.floor(L/6):0;t.set(T.id,{x,y:635+R*62})})}const h=m.length>3?[1120,1180]:[1140];return m.forEach((b,$)=>{const S=$%h.length,C=Math.floor($/h.length);t.set(b.id,{x:h[S]??1140,y:190+C*108})}),t}function vf(e,t){const n=(e.x+t.x)/2,s=t.y>=e.y?32:-32;return`M ${e.x} ${e.y} C ${n} ${e.y+s}, ${n} ${t.y-s}, ${t.x} ${t.y}`}function lr(e,t,n){if(e==="command"){if(t){at(t),se("command",{...$o(t),...n});return}se("command",n);return}if(e==="intervene"){se("intervene",n);return}se("command",n)}function _f(e){switch(e.kind){case"room":return{width:150,height:150,radius:74};case"worker":return{width:78,height:42,radius:22};case"lane":return{width:170,height:54,radius:16};case"keeper":return{width:120,height:56,radius:24};default:return{width:188,height:64,radius:18}}}function ff({orchestra:e,roomPoint:t,onSelect:n}){if(!t||e.signals.length===0)return null;const s=108;return i`
    ${e.signals.slice(0,6).map((a,o)=>{const l=(-120+o*38)*(Math.PI/180),c=Math.round(t.x+Math.cos(l)*s),p=Math.round(t.y+Math.sin(l)*s);return i`
        <g
          key=${a.id}
          class=${`orchestra-signal-node ${P(a.tone)}`}
          onClick=${()=>n(a.id)}
        >
          <line x1=${t.x} y1=${t.y} x2=${c} y2=${p} class="orchestra-signal-link" />
          <circle cx=${c} cy=${p} r="16" class="orchestra-signal-dot" />
          <text x=${c} y=${p+4} text-anchor="middle" class="orchestra-signal-glyph">!</text>
        </g>
      `})}
  `}function gf({edges:e,positions:t,selectedId:n}){return i`
    ${e.map(s=>{const a=t.get(s.source),o=t.get(s.target);if(!a||!o)return null;const l=n!=null&&(s.source===n||s.target===n);return i`
        <path
          key=${s.id}
          d=${vf(a,o)}
          class=${`orchestra-edge ${P(s.tone)} ${s.animated?"animated":""} ${l?"active":""}`}
        />
      `})}
  `}function $f({orchestra:e,positions:t,selectedId:n,onSelect:s}){var o;const a=((o=e.focus)==null?void 0:o.target_kind)==="node"?e.focus.target_id:null;return i`
    ${e.nodes.map(l=>{const c=t.get(l.id);if(!c)return null;const p=_f(l),m=l.id===n,u=l.id===a;if(l.kind==="room")return i`
          <g
            key=${l.id}
            class=${`orchestra-node room ${P(l.tone)} ${m?"selected":""} ${u?"focused":""}`}
            onClick=${()=>s(l.id)}
          >
            <circle cx=${c.x} cy=${c.y} r=${p.radius} class="orchestra-room-ring outer" />
            <circle cx=${c.x} cy=${c.y} r=${p.radius-16} class="orchestra-room-ring inner" />
            <text x=${c.x} y=${c.y-10} text-anchor="middle" class="orchestra-room-glyph">${l.glyph??"◎"}</text>
            <text x=${c.x} y=${c.y+22} text-anchor="middle" class="orchestra-room-label">${l.label}</text>
          </g>
        `;const _=c.x-p.width/2,g=c.y-p.height/2;return i`
        <g
          key=${l.id}
          class=${`orchestra-node ${l.kind} ${P(l.tone)} ${m?"selected":""} ${u?"focused":""}`}
          onClick=${()=>s(l.id)}
        >
          <rect x=${_} y=${g} width=${p.width} height=${p.height} rx=${p.radius} class="orchestra-node-body" />
          <text x=${_+16} y=${g+24} class="orchestra-node-glyph">${l.glyph??"•"}</text>
          <text x=${_+38} y=${g+24} class="orchestra-node-label">${l.label}</text>
          ${l.subtitle?i`<text x=${_+38} y=${g+42} class="orchestra-node-subtitle">${l.subtitle}</text>`:null}
          ${l.status?i`<text x=${_+p.width-10} y=${g+18} text-anchor="end" class="orchestra-node-status">${l.status}</text>`:null}
        </g>
      `})}
  `}function fc(e){var s,a;const t=Oi.value;if(t){const o=e.nodes.find(c=>c.id===t);if(o)return{type:"node",value:o};const l=e.signals.find(c=>c.id===t);if(l)return{type:"signal",value:l}}if(((s=e.focus)==null?void 0:s.target_kind)==="node"){const o=e.nodes.find(l=>{var c;return l.id===((c=e.focus)==null?void 0:c.target_id)});if(o)return{type:"node",value:o}}if(((a=e.focus)==null?void 0:a.target_kind)==="signal"){const o=e.signals.find(l=>{var c;return l.id===((c=e.focus)==null?void 0:c.target_id)});if(o)return{type:"signal",value:o}}const n=e.nodes[0];return n?{type:"node",value:n}:null}function hf({orchestra:e}){const t=fc(e);if(!t)return i`<aside class="orchestra-drawer card"><div class="empty-state">선택 가능한 대상이 아직 없습니다.</div></aside>`;if(t.type==="signal"){const o=t.value;return i`
      <aside class="orchestra-drawer card ${P(o.tone)}">
          <div class="card-title-row">
            <div class="card-title">${o.label}</div>
          <span class="command-chip ${P(o.tone)}">${rr(o.kind)}</span>
        </div>
        <p>${o.detail??"세부 설명이 없습니다."}</p>
        ${o.suggested_surface?i`
              <div class="command-action-row">
                <button
                  class="control-btn"
                  onClick=${()=>lr("command",o.suggested_surface,o.suggested_params??{})}
                >
                  추천 화면 열기
                </button>
              </div>
            `:null}
      </aside>
    `}const n=t.value,s=e.signals.filter(o=>o.source_id===n.id||o.target_id===n.id),a=e.edges.filter(o=>o.source===n.id||o.target===n.id);return i`
    <aside class="orchestra-drawer card ${P(n.tone)}">
      <div class="card-title-row">
        <div class="card-title">${n.label}</div>
        <span class="command-chip ${P(n.tone)}">${rr(n.kind)}</span>
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
          ${s.map(o=>i`<span class="command-chip ${P(o.tone)}">${o.label}</span>`)}
        </div>
      `:null}
      <div class="command-card-sub">연결 ${a.length}개 · 근거 ${n.provenance}</div>
      ${n.link_tab&&(n.link_surface||Object.keys(n.link_params??{}).length>0)?i`
            <div class="command-action-row">
              <button
                class="control-btn"
                onClick=${()=>lr(n.link_tab??"command",n.link_surface,n.link_params??{})}
              >
                이 화면 열기
              </button>
            </div>
          `:null}
    </aside>
  `}function yf(){var o,l,c,p;const e=po.value;if(wi.value&&!e)return i`<section class="card command-section"><div class="empty-state">오케스트라 맵 불러오는 중…</div></section>`;if(ua.value)return i`<section class="card command-section"><div class="empty-state error">${ua.value}</div></section>`;if(!e)return i`<section class="card command-section"><div class="empty-state">오케스트라 맵 데이터가 아직 없습니다.</div></section>`;const t=mf(e),n=fc(e),s=(n==null?void 0:n.value.id)??null,a=e.nodes.find(m=>m.kind==="room")?t.get(e.nodes.find(m=>m.kind==="room").id)??null:null;return i`
    <section class="card command-section orchestra-surface">
      <div class="card-title-row">
        <div class="card-title">오케스트라 맵</div>
        <${O} panelId="command.orchestra" compact=${!0} />
      </div>
      <p class="command-card-sub">룸 전체를 한 장의 작전판으로 읽는 시각화입니다. 노드를 누르면 관련 신호와 내려볼 대상을 바로 확인할 수 있습니다.</p>

      <div class="orchestra-shell">
        <div class="orchestra-canvas-wrap">
          <svg class="orchestra-canvas" viewBox=${`0 0 ${ir} ${or}`}>
            <defs>
              <pattern id="orchestra-grid" width="32" height="32" patternUnits="userSpaceOnUse">
                <path d="M 32 0 L 0 0 0 32" fill="none" class="orchestra-grid-line"></path>
              </pattern>
            </defs>
            <rect width=${ir} height=${or} fill="url(#orchestra-grid)" class="orchestra-grid"></rect>
            <${gf} edges=${e.edges} positions=${t} selectedId=${s} />
            <${ff} orchestra=${e} roomPoint=${a} onSelect=${m=>{Oi.value=m}} />
            <${$f}
              orchestra=${e}
              positions=${t}
              selectedId=${s}
              onSelect=${m=>{Oi.value=m}}
            />
          </svg>
          <div class="orchestra-summary-strip">
            <span class="command-chip">세션 ${((o=e.summary)==null?void 0:o.session_count)??0}</span>
            <span class="command-chip">워커 ${((l=e.summary)==null?void 0:l.worker_count)??0}</span>
            <span class="command-chip">키퍼 ${((c=e.summary)==null?void 0:c.keeper_count)??0}</span>
            <span class="command-chip ${P(e.signals.some(m=>m.tone==="bad")?"bad":e.signals.length>0?"warn":"ok")}">
              신호 ${((p=e.summary)==null?void 0:p.signal_count)??e.signals.length}
            </span>
            <span class="command-chip">갱신 ${X(e.generated_at)}</span>
          </div>
        </div>

        <${hf} orchestra=${e} />
      </div>
    </section>
  `}const gc="masc_dashboard_agent_name";function bf(){var t,n,s;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(gc))==null?void 0:s.trim())||"dashboard"}const Da=f(bf()),tn=f(""),_a=f("운영 점검"),nn=f(""),Kn=f(""),Bn=f("2"),ln=f(""),he=f("note"),Un=f(""),Hn=f(""),Wn=f(""),Gn=f("2"),Jn=f(""),fa=f("운영자 중지 요청"),ga=f(""),sn=f(""),bs=f(null);function kf(e){const t=e.trim()||"dashboard";Da.value=t,localStorage.setItem(gc,t)}function $a(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function bo(e){switch((e??"").trim().toLowerCase()){case"judgment":return"상주 판단";case"fallback":return"보조 읽기 모델";default:return(e==null?void 0:e.trim())||"안내"}}function ha(e){switch((e??"").trim().toLowerCase()){case"judgment":return"ok";case"fallback":return"warn";default:return"warn"}}function ko(e){return e!=null&&e.enabled?e.refreshing?"갱신 중":e.judge_online?"온라인":e.last_error?"오류":"대기":"꺼짐"}function xf(e){return e!=null&&e.enabled?e.judge_online?"ok":e.refreshing?"warn":"bad":"warn"}function xo(e){return e!=null&&e.fresh_until?e.fresh_until:"갱신 기준 없음"}function cr(e){return typeof e!="number"||!Number.isFinite(e)?"확인 없음":e<60?`${Math.round(e)}초 전`:e<3600?`${Math.round(e/60)}분 전`:`${Math.round(e/3600)}시간 전`}function cn(e){return typeof e=="string"?e.trim().toLowerCase():""}function Sf(e){var s;const t=cn(e.status);if(t==="paused")return"bad";if(t===""||t==="unknown")return"warn";const n=cn((s=e.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||t&&t!=="active"&&t!=="running"&&t!=="ended"?"warn":"ok"}function Ya(e){const t=cn(e.status);return t==="offline"||t==="inactive"||t==="error"?"bad":t===""||t==="unknown"||(e.context_ratio??0)>=.8||e.context_ratio==null||e.last_turn_ago_s==null||(e.last_turn_ago_s??0)>=3600?"warn":"ok"}function dr(e){return e.some(t=>cn(t.severity)==="bad")?"bad":e.length>0?"warn":"ok"}function Cf(e){return e.target_type==="team_session"}function Af(e){return e.target_type==="keeper"}function Rt(e){switch(e){case"broadcast":return"방송";case"room_pause":return"방 일시정지";case"room_resume":return"방 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"team_worker_spawn_batch":return"세션 작업자 교체";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"키퍼 메시지";case"keeper_msg":return"키퍼 메시지";case"swarm_run_continue":return"스웜 실행 계속";case"swarm_run_rerun":return"스웜 실행 재실행";case"swarm_run_abandon":return"스웜 실행 포기";default:return(e==null?void 0:e.trim())||"액션"}}function an(e){switch(e){case"room":return"방";case"team_session":return"세션";case"keeper":return"키퍼";case"swarm_run":return"스웜 실행";default:return(e==null?void 0:e.trim())||"대상"}}function Ut(e){switch(cn(e)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function ya(e){return e?"확인 후 실행":"즉시 실행"}function If(e){switch(e){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"worker_spawn_batch":return"작업자 교체";default:return e}}function ue(e,t){if(!e)return null;const n=e[t];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function Tf(e){return!e||typeof e!="object"||Array.isArray(e)?null:e}function zf(e){if(!e)return"";const t=e.spawn_batch;return $a(t!==void 0?t:e)}function $c(e){const t=Tf(e.payload);if(e.target_type==="room"){if(e.action_type==="broadcast"){tn.value=ue(t,"message")??e.summary;return}if(e.action_type==="task_inject"){nn.value=ue(t,"title")??"운영자 주입 작업",Kn.value=ue(t,"description")??e.summary,Bn.value=ue(t,"priority")??Bn.value;return}e.action_type==="room_pause"&&(_a.value=ue(t,"reason")??e.summary);return}if(e.target_type==="team_session"){if(e.target_id&&(ln.value=e.target_id),e.action_type==="team_stop"){fa.value=ue(t,"reason")??e.summary;return}he.value=e.action_type==="team_worker_spawn_batch"?"worker_spawn_batch":e.action_type==="team_task_inject"?"task":e.action_type==="team_broadcast"?"broadcast":"note";const n=ue(t,"message");if(n&&(Un.value=n),he.value==="worker_spawn_batch"){Jn.value=zf(t);return}he.value==="task"&&(Hn.value=ue(t,"task_title")??ue(t,"title")??"운영자 주입 작업",Wn.value=ue(t,"task_description")??ue(t,"description")??e.summary,Gn.value=ue(t,"task_priority")??ue(t,"priority")??Gn.value);return}e.target_type==="keeper"&&(e.target_id&&(ga.value=e.target_id),sn.value=ue(t,"message")??e.summary)}function Rf(e){$c({action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.suggested_payload,summary:e.summary})}function Pf(e){$c({action_type:e.action_type,target_type:e.target_type,target_id:e.target_id??null,payload:e.suggested_payload,summary:e.reason}),E("추천 액션 payload를 폼에 채웠습니다","success")}function Lf(e,t,n){return!e||!e.target_type||e.target_type==="room"?!0:e.target_type==="team_session"?!!e.target_id&&t.some(s=>s.session_id===e.target_id):e.target_type==="keeper"?!!e.target_id&&n.some(s=>s.name===e.target_id):!0}async function ct(e){const t=Da.value.trim()||"dashboard";try{const n=await Fl({actor:t,action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.payload});return n.confirm_required?E("확인 대기열에 올렸습니다","warning"):E(e.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return E(s,"error"),null}}async function ur(){const e=tn.value.trim();if(!e)return;await ct({action_type:"broadcast",target_type:"room",payload:{message:e},successMessage:"방송을 보냈습니다"})&&(tn.value="")}async function Mf(){await ct({action_type:"room_pause",target_type:"room",payload:{reason:_a.value.trim()||"운영 점검"},successMessage:"방 일시정지를 요청했습니다"})}async function hc(){await ct({action_type:"room_resume",target_type:"room",payload:{},successMessage:"방 재개를 요청했습니다"})}async function jf(){const e=nn.value.trim();if(!e)return;await ct({action_type:"task_inject",target_type:"room",payload:{title:e,description:Kn.value.trim()||"개입 화면에서 주입",priority:Number.parseInt(Bn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(nn.value="",Kn.value="")}async function Ef(){var l;const e=_e.value,t=ln.value||((l=e==null?void 0:e.sessions[0])==null?void 0:l.session_id)||"";if(!t){E("먼저 세션을 고르세요","warning");return}const n={};if(he.value==="worker_spawn_batch"){const c=Jn.value.trim();if(!c){E("spawn_batch JSON을 먼저 채우세요","warning");return}try{const m=JSON.parse(c);if(Array.isArray(m))n.spawn_batch=m;else if(m&&typeof m=="object"&&Array.isArray(m.spawn_batch))n.spawn_batch=m.spawn_batch;else{E("spawn_batch는 배열 또는 { spawn_batch: [...] } 형태여야 합니다","warning");return}}catch(m){const u=m instanceof Error?m.message:"spawn_batch JSON 파싱에 실패했습니다";E(u,"error");return}await ct({action_type:"team_worker_spawn_batch",target_type:"team_session",target_id:t,payload:n,successMessage:"작업자 교체 요청을 적용했습니다"})&&(Jn.value="");return}const s=Un.value.trim();s&&(n.message=s);let a="team_note";he.value==="broadcast"?a="team_broadcast":he.value==="task"&&(a="team_task_inject"),he.value==="task"&&(n.task_title=Hn.value.trim()||"운영자 주입 작업",n.task_description=Wn.value.trim()||"개입 화면에서 주입",n.task_priority=Number.parseInt(Gn.value,10)||2),await ct({action_type:a,target_type:"team_session",target_id:t,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Un.value="",he.value==="task"&&(Hn.value="",Wn.value=""))}async function Nf(){var n;const e=_e.value,t=ln.value||((n=e==null?void 0:e.sessions[0])==null?void 0:n.session_id)||"";if(!t){E("먼저 세션을 고르세요","warning");return}await ct({action_type:"team_stop",target_type:"team_session",target_id:t,payload:{reason:fa.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function wf(){var a;const e=_e.value,t=ga.value||((a=e==null?void 0:e.keepers[0])==null?void 0:a.name)||"",n=sn.value.trim();if(!t){E("먼저 키퍼를 고르세요","warning");return}if(!n)return;await ct({action_type:"keeper_message",target_type:"keeper",target_id:t,payload:{message:n},successMessage:`${t}에게 메시지를 보냈습니다`})&&(sn.value="")}async function pr(e,t="confirm"){const n=Da.value.trim()||"dashboard";try{await Kl(n,e,t),E(t==="deny"?"승인 대기를 거부했습니다":"확인 실행을 완료했습니다","success")}catch(s){const a=s instanceof Error?s.message:t==="deny"?"승인 대기 거부에 실패했습니다":"확인 실행에 실패했습니다";E(a,"error")}}function yc(e){switch(e){case"explicit":return"실제 관리 단위";case"hybrid":return"관리 단위 + 자동 보강";case"auto":return"자동 투영";default:return"출처 미상"}}function bc(e){switch(e){case"explicit":return"ok";case"hybrid":return"warn";case"auto":return"warn";default:return"warn"}}function Df(e){switch(e){case"explicit":return"지금 보이는 유닛은 실제로 정의된 지휘면 관리 단위입니다.";case"hybrid":return"일부는 실제 관리 단위이고, 비어 있는 부분은 실시간 에이전트 편성을 보고 자동 보강한 구조입니다.";case"auto":return"이 화면은 실시간 에이전트 편성을 지휘면 모양으로 자동 투영한 것입니다. 실제 명령 체계와 1:1로 같다고 보면 안 됩니다.";default:return"이 화면은 관리 토폴로지와 실효 토폴로지가 섞여 있을 수 있습니다."}}function Of(e){const t=e.unit.source??"unknown";return t==="explicit"?e.active_operation_count&&e.active_operation_count>0?"실제 관리 단위이며 연결된 작전이 있습니다.":"실제 관리 단위이지만 현재 연결된 작전은 없습니다.":t==="hybrid"?e.active_operation_count&&e.active_operation_count>0?"관리 단위를 기반으로 자동 보강된 구조이며 일부 작전이 연결돼 있습니다.":"관리 단위를 기반으로 자동 보강된 구조이며 현재 실행 연결은 약합니다.":e.active_operation_count&&e.active_operation_count>0?"자동 생성된 구조이지만 이 노드에 연결된 작전 흔적은 있습니다.":"자동 생성된 구조이며 현재 실행 연결은 없습니다."}function kc({node:e,depth:t=0}){const n=e.roster_live??0,s=e.roster_total??e.unit.roster.length,a=e.active_operation_count??0,o=e.unit.policy,l=e.unit.source??"unknown",c=a>0?`${a}개 작전 연결`:"실행 연결 없음";return i`
    <div class="command-tree-node depth-${Math.min(t,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${e.unit.label}</strong>
            <span class="command-chip">${j_(e.unit.kind)}</span>
            <span class="command-chip ${P(e.health)}">${e.health??"ok"}</span>
            <span class="command-chip ${bc(l)}">${yc(l)}</span>
            <span class="command-chip ${a>0?"ok":"warn"}">${c}</span>
            ${o!=null&&o.frozen?i`<span class="command-chip warn">동결됨</span>`:null}
            ${o!=null&&o.kill_switch?i`<span class="command-chip bad">킬 스위치</span>`:null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${e.unit.unit_id}</span>
            <span>리더 ${e.unit.leader_id??"미지정"} / ${e.leader_status??"확인 필요"}</span>
            <span>편성 ${n}/${s}</span>
            <span>작전 ${a}</span>
            <span>자율성 ${(o==null?void 0:o.autonomy_level)??"정보 없음"}</span>
          </div>
          <div class="command-card-sub">${Of(e)}</div>
          ${e.reasons&&e.reasons.length>0?i`<div class="command-tag-row">
                ${e.reasons.map(p=>i`<span class="command-tag warn">${p}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${e.children.length>0?i`<div class="command-tree-children">
            ${e.children.map(p=>i`<${kc} node=${p} depth=${t+1} />`)}
          </div>`:null}
    </div>
  `}function qf({alert:e}){return i`
    <article class="command-alert ${P(e.severity)}">
      <div class="command-card-head">
        <strong>${e.title??e.kind??e.alert_id}</strong>
        <span class="command-chip ${P(e.severity)}">${e.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${e.scope_type??"범위"}:${e.scope_id??"정보 없음"}</span>
        <span>${X(e.timestamp)}</span>
      </div>
      ${e.detail?i`<p>${e.detail}</p>`:null}
    </article>
  `}function So({event:e}){return i`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${e.event_type}</strong>
          <span class="command-chip">${e.source??"control_plane"}</span>
          <span class="command-chip">${X(e.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${e.operation_id??e.trace_id}
          ${e.unit_id?` · ${e.unit_id}`:""}
          ${e.actor?` · ${e.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${va(e.detail)}</pre>
    </article>
  `}function Ff(){const e=qe.value,t=e==null?void 0:e.topology,n=t==null?void 0:t.source,s=t==null?void 0:t.summary,a=(s==null?void 0:s.managed_unit_count)??0,o=(s==null?void 0:s.active_operation_count)??0;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${O} panelId="command.topology" compact=${!0} />
      </div>
      ${e?i`
            <div class="command-topology-explainer">
              <div class="command-tree-title-row">
                <span class="command-chip ${bc(n)}">${yc(n)}</span>
                <span class="command-chip">관리 유닛 ${a}</span>
                <span class="command-chip ${o>0?"ok":"warn"}">활성 작전 ${o}</span>
              </div>
              <p>${Df(n)}</p>
            </div>
          `:null}
      ${e&&e.topology.units.length>0?i`${e.topology.units.map(l=>i`<${kc} node=${l} />`)}`:i`<div class="empty-state">지금은 실시간 에이전트나 관리 유닛 기준으로 그릴 지휘 계층이 없습니다.</div>`}
    </section>
  `}function Kf(){const e=qe.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${O} panelId="command.alerts" compact=${!0} />
      </div>
      ${e&&e.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${e.alerts.alerts.map(t=>i`<${qf} alert=${t} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 지휘면 경보는 없습니다.</div>`}
    </section>
  `}function Bf(){const e=qe.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${O} panelId="command.trace" compact=${!0} />
      </div>
      ${e&&e.traces.events.length>0?i`<div class="command-trace-stack">
            ${e.traces.events.map(t=>i`<${So} event=${t} />`)}
          </div>`:i`<div class="empty-state">최근 트레이스 이벤트가 없습니다.</div>`}
    </section>
  `}function Uf(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Hf(e,t){return(t==null?void 0:t.status)==="abandoned"||(e==null?void 0:e.recommended_kind)==="continue"?"warn":(e==null?void 0:e.recommended_kind)==="rerun"?"bad":"ok"}function Wf(e){switch(e){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(e==null?void 0:e.trim())||"결정"}}function xc({swarm:e}){var _,g;const t=e.run_id,n=e.resolution_recommendation,s=e.run_resolution;if(!t||!n&&!s)return null;const a=mc()??"dashboard",o=((_=_e.value)==null?void 0:_.pending_confirms.find(h=>h.target_type==="swarm_run"&&h.target_id===t))??null,l=Hf(n,s),c=((g=e.operation)==null?void 0:g.operation_id)??e.operation_id??void 0,p={run_id:t};c&&(p.operation_id=c),n!=null&&n.reason&&(p.reason=n.reason);const m=async h=>{await Fl({actor:a,action_type:h,target_type:"swarm_run",target_id:t,payload:p})},u=async h=>{o&&await Kl(a,o.confirm_token,h)};return i`
    <article class="command-guide-card ${P(l)}">
      <div class="command-guide-head">
        <strong>Run Resolution</strong>
        <span class="command-chip ${P(l)}">
          ${Wf((s==null?void 0:s.status)??(n==null?void 0:n.recommended_kind)??null)}
        </span>
      </div>
      <p>
        ${(s==null?void 0:s.status)==="abandoned"?`이 run은 ${s.decided_by}가 ${X(s.decided_at)}에 soft abandon 처리했습니다. ${s.reason}`:(n==null?void 0:n.reason)??"이 run에 대한 별도 resolution recommendation은 아직 없습니다."}
      </p>
      <div class="command-card-grid">
        <span>Run</span><span>${t}</span>
        <span>Provenance</span><span>${(n==null?void 0:n.provenance)??"recorded"}</span>
        <span>Engine</span><span>${(n==null?void 0:n.decision_engine)??"operator_record"}</span>
        <span>Authoritative</span><span>${n!=null&&n.authoritative?"yes":"no"}</span>
      </div>
      ${n!=null&&n.evidence?i`
            <div class="command-tag-row">
              <span class="command-tag">joined ${n.evidence.joined_workers??0}</span>
              <span class="command-tag">trace ${n.evidence.trace_events??0}</span>
              <span class="command-tag">message ${n.evidence.message_events??0}</span>
              ${n.evidence.runtime_blocker?i`<span class="command-tag ${P("bad")}">${n.evidence.runtime_blocker}</span>`:null}
            </div>
          `:null}
      ${o?i`
            <div class="command-guide-card warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip warn">${o.confirm_token}</span>
              </div>
              ${o.preview?i`<pre class="command-trace-detail">${Uf(o.preview)}</pre>`:null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${()=>{u("confirm")}} disabled=${W.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${()=>{u("deny")}} disabled=${W.value}>취소</button>
              </div>
            </div>
          `:n?i`
              <div class="command-action-row">
                ${n.continue_available?i`<button class="control-btn ghost" onClick=${()=>{m("swarm_run_continue")}} disabled=${W.value}>Continue</button>`:null}
                ${n.rerun_available?i`<button class="control-btn" onClick=${()=>{m("swarm_run_rerun")}} disabled=${W.value}>Rerun</button>`:null}
                ${n.abandon_available?i`<button class="control-btn ghost" onClick=${()=>{m("swarm_run_abandon")}} disabled=${W.value}>Abandon</button>`:null}
              </div>
            `:null}
    </article>
  `}function Sc(e){return e.motion_state==="stalled"||e.hard_flags.some(t=>t.severity==="bad")?"bad":e.motion_state==="waiting"||e.hard_flags.some(t=>t.severity==="warn")?"warn":"ok"}function Cc({lanes:e}){const t={moving:0,waiting:0,stalled:0,terminal:0};for(const a of e){const o=a.motion_state;o in t?t[o]++:t.waiting++}if(e.length===0)return null;const s=[{key:"moving",count:t.moving,color:"var(--ok)"},{key:"waiting",count:t.waiting,color:"var(--warn)"},{key:"stalled",count:t.stalled,color:"var(--bad)"},{key:"terminal",count:t.terminal,color:"#556"}];return i`
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
  `}function Gf({total:e}){const n=Math.min(e,20),s=e>20?e-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${e})</span>
    </div>
  `}function Jf({lane:e}){const t=e.counts??{},n=Sc(e),s=t.workers??0,a=t.operations??0,o=t.detachments??0,l=a+o,c=e.motion_state==="moving"?84:e.motion_state==="waiting"?58:e.motion_state==="terminal"?100:26;return i`
    <article class="swarm-lane-strip ${P(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${e.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${e.kind} · ${e.source_of_truth}</span>
            <strong>${e.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${P(n)}">${e.phase}</span>
          <span class="command-chip ${P(n)}">${e.motion_state}</span>
          <span class="command-chip">${X(e.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${e.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${P(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${e.current_step}</span>
        </div>
        ${s>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${Gf} total=${s} />
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
      ${e.blockers.length>0?i`<div class="swarm-lane-blockers">막힘: ${e.blockers.join(" · ")}</div>`:null}
      ${e.hard_flags.length>0?i`
            <div class="swarm-lane-flags">
              ${e.hard_flags.map(p=>i`<span class="command-chip ${P(p.severity)}">${p.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Ac({lanes:e}){const t=e.slice(0,4);return t.length===0?null:i`
    <div class="swarm-storyboard">
      ${t.map(n=>{const s=Sc(n),a=n.counts.workers??0,o=n.counts.operations??0,l=n.counts.detachments??0;return i`
          <article class="swarm-story-card ${P(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${P(s)}">${n.motion_state}</span>
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
  `}function Vf({event:e}){const t=e.timestamp?new Date(e.timestamp):null,n=t&&!isNaN(t.getTime())?t:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${P(e.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${e.title}</strong>
        <span class="swarm-event-kind">${e.kind}</span>
        ${e.detail?i`<div class="command-card-sub">${e.detail}</div>`:null}
      </div>
    </div>
  `}function Yf({gap:e}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${P(e.severity)}">${e.code} (${e.count})</span>
      <span class="command-card-sub">${e.summary}</span>
    </div>
  `}function Xf({proof:e}){const t=(e==null?void 0:e.status)==="missing"?"warn":(e==null?void 0:e.pass)===!1?"bad":(e==null?void 0:e.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${P(t)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${P(t)}">${(e==null?void 0:e.status)??"missing"}</span>
        </div>
      ${e?i`
            <div class="command-card-grid">
              <span>소스</span><span>${e.source}</span>
              <span>런</span><span>${e.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${X(e.captured_at)}</span>
              <span>통과</span><span>${e.pass==null?"n/a":e.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${e.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${e.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${e.workers.expected??"n/a"} 예상 · ${e.workers.done??"n/a"} 완료 · ${e.workers.final??"n/a"} 최종</span>
            </div>
            ${e.artifact_ref?i`<div class="command-card-foot">${e.artifact_ref}</div>`:null}
            ${e.missing_reason?i`<p>${e.missing_reason}</p>`:null}
          `:i`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function Qf(){const e=rs(),t=ns(F.value),n=w_(t),s=e==null?void 0:e.swarm_status,a=e==null?void 0:e.swarm_proof,o=(s==null?void 0:s.lanes.filter(_=>_.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],p=s==null?void 0:s.overview,m=s==null?void 0:s.recommended_next_action,u=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${O} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${Ac} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(p==null?void 0:p.active_lanes)??0}</strong><small>${(p==null?void 0:p.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(p==null?void 0:p.stalled_lanes)??0}</strong><small>${(p==null?void 0:p.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${X(p==null?void 0:p.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${X(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${Cc} lanes=${o} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(_=>i`<${Jf} lane=${_} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${Xf} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${P(l.some(_=>_.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?i`<div class="swarm-event-rail">${l.slice(0,4).map(_=>i`<${Yf} gap=${_} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?i`<div class="swarm-event-rail">${c.map(_=>i`<${Vf} event=${_} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Zf({item:e}){return i`
    <article class="command-guide-card ${P(e.status)}">
      <div class="command-guide-head">
        <strong>${e.title}</strong>
        <span class="command-chip ${P(e.status)}">${e.status}</span>
      </div>
      <p>${e.detail}</p>
      <div class="command-card-foot">Next tool: ${e.next_tool}</div>
    </article>
  `}function Ic({blocker:e}){return i`
    <article class="command-alert ${P(e.severity)}">
      <div class="command-card-head">
        <strong>${e.title}</strong>
        <span class="command-chip ${P(e.severity)}">${e.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${e.code}</span>
        <span>next ${e.next_tool}</span>
      </div>
      <p>${e.detail}</p>
    </article>
  `}function eg({worker:e}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.name}</strong>
          <div class="command-card-sub">${e.role} · ${e.lane}</div>
        </div>
        <span class="command-chip ${P(e.joined?e.heartbeat_fresh?"ok":"warn":"bad")}">
          ${e.status}
        </span>
      </div>
      <div class="command-card-grid">
        <span>Joined</span><span>${e.joined?"yes":"no"}</span>
        <span>Live</span><span>${e.live_presence?"yes":"no"}</span>
        <span>Completed</span><span>${e.completed?"yes":"no"}</span>
        <span>Task</span><span>${e.current_task??e.bound_task_id??"none"}</span>
        <span>Task Title</span><span>${e.bound_task_title??"n/a"}</span>
        <span>Task Status</span><span>${e.bound_task_status??"n/a"}</span>
        <span>Heartbeat</span><span>${e.heartbeat_age_sec!=null?`${Math.round(e.heartbeat_age_sec)}s`:e.heartbeat_fresh?"completed-cleanly":"n/a"}</span>
        <span>Squad</span><span>${e.squad_member?"yes":"no"}</span>
        <span>Detachment</span><span>${e.detachment_member?"yes":"no"}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${e.lane}</span>
        <span class="command-tag ${e.current_task_matches_run?"ok":"warn"}">current_task</span>
        <span class="command-tag ${e.claim_marker_seen?"ok":"warn"}">claim</span>
        <span class="command-tag ${e.done_marker_seen?"ok":"warn"}">done</span>
        <span class="command-tag ${e.final_marker_seen?"ok":"warn"}">final</span>
      </div>
      ${e.last_message?i`<div class="command-card-foot">${X(e.last_message.timestamp)} · ${e.last_message.content}</div>`:null}
    </article>
  `}function tg(){var p,m,u,_,g,h,b,$,S,C,x,L,T,R,M,z,j,Z,ie,V,ee;const e=Mt.value,t=_c(),n=ho(),s=(p=e==null?void 0:e.provider)!=null&&p.runtime_blocker?"blocked":(m=e==null?void 0:e.provider)!=null&&m.provider_reachable?"ready":"check",a=((u=e==null?void 0:e.provider)==null?void 0:u.actual_slots)??((_=e==null?void 0:e.provider)==null?void 0:_.total_slots)??0,o=((g=e==null?void 0:e.provider)==null?void 0:g.expected_slots)??"n/a",l=((h=e==null?void 0:e.provider)==null?void 0:h.actual_ctx)??((b=e==null?void 0:e.provider)==null?void 0:b.ctx_per_slot)??0,c=(($=e==null?void 0:e.provider)==null?void 0:$.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${Qf} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${ca.value?i`<div class="empty-state">Loading swarm live state…</div>`:da.value?i`<div class="empty-state error">${da.value}</div>`:e?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${e.run_id??t??"swarm-live"}</strong><small>${e.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((S=e.summary)==null?void 0:S.joined_workers)??0}/${((C=e.summary)==null?void 0:C.expected_workers)??0}</strong><small>${((x=e.summary)==null?void 0:x.live_workers)??0}개 가동 · ${((L=e.summary)==null?void 0:L.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${o} · ctx ${l}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(T=e.summary)!=null&&T.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((R=e.provider)==null?void 0:R.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(M=e.summary)!=null&&M.pass_end_to_end?"통과":"확인 필요"}</strong><small>${e.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((z=e.operation)==null?void 0:z.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((j=e.squad)==null?void 0:j.label)??"없음"}</span>
                      <span>실행체</span><span>${((Z=e.detachment)==null?void 0:Z.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((ie=e.summary)==null?void 0:ie.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((V=e.summary)==null?void 0:V.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((ee=e.provider)==null?void 0:ee.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${e.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${e.truth_notes.length>0?i`<div class="command-tag-row">
                          ${e.truth_notes.map(A=>i`<span class="command-tag">${A}</span>`)}
                        </div>`:null}
                    <${xc} swarm=${e} />
                  `:i`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.checklist.length>0?i`<div class="command-card-stack">
                ${e.checklist.map(A=>i`<${Zf} item=${A} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.workers.length>0?i`<div class="command-card-stack">
                ${e.workers.map(A=>i`<${eg} worker=${A} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${e!=null&&e.provider?i`
                <div class="command-card-grid">
                  <span>Provider</span><span>${e.provider.provider_base_url??"n/a"}</span>
                  <span>Provider Reachable</span><span>${e.provider.provider_reachable==null?"n/a":e.provider.provider_reachable?"yes":"no"}</span>
                  <span>Requested Model</span><span>${e.provider.provider_model_id??"n/a"}</span>
                  <span>Actual Model</span><span>${e.provider.actual_model_id??"n/a"}</span>
                  <span>Slot URL</span><span>${e.provider.slot_url??"n/a"}</span>
                  <span>Expected Slots</span><span>${e.provider.expected_slots??"n/a"}</span>
                  <span>Actual Slots</span><span>${e.provider.actual_slots??e.provider.total_slots??0}</span>
                  <span>Expected Ctx</span><span>${e.provider.expected_ctx??"n/a"}</span>
                  <span>Actual Ctx</span><span>${e.provider.actual_ctx??e.provider.ctx_per_slot??0}</span>
                  <span>Active Now</span><span>${e.provider.active_slots_now??0}</span>
                  <span>Peak Active</span><span>${e.provider.peak_active_slots??0}</span>
                  <span>Sample Count</span><span>${e.provider.sample_count??0}</span>
                  <span>Last Sample</span><span>${e.provider.last_sample_at?X(e.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${e.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${e.provider.checked_at?X(e.provider.checked_at):"n/a"}</span>
                </div>
                ${e.provider.detail?i`<div class="command-card-sub">${e.provider.detail}</div>`:null}
                ${e.provider.timeline.length>0?i`<div class="command-trace-stack">
                      ${e.provider.timeline.slice(-12).map(A=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${A.active_slots} active</strong>
                              <span class="command-chip">${X(A.timestamp)}</span>
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
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.blockers.length>0?i`<div class="command-card-stack">
                ${e.blockers.map(A=>i`<${Ic} blocker=${A} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(e==null?void 0:e.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.recent_messages.length>0?i`<div class="command-trace-stack">
                ${e.recent_messages.map(A=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${A.from}</strong>
                        <span class="command-chip">${X(A.timestamp)}</span>
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
            <${O} panelId="command.trace" compact=${!0} />
          </div>
          ${e&&e.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${e.recent_trace_events.map(A=>i`<${So} event=${A} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function ng(e){return e==="swarm"?"스웜 실시간":"세션 요약"}function sg(e){switch(e){case"current":return"현재 과업 일치";case"drift":return"과업 드리프트";case"claim":return"착수 흔적 있음";case"no-claim":return"착수 흔적 없음";case"done":return"완료 흔적 있음";case"no-done":return"완료 흔적 없음";case"final":return"최종 보고 있음";case"no-final":return"최종 보고 없음";case"turn":return"턴 기록 있음";case"silent":return"턴 기록 없음";case"noted":return"노트 기록 있음";default:return e.startsWith("empty:")?`빈 노트 ${e.slice(6)}회`:e.startsWith("turns:")?`턴 ${e.slice(6)}회`:e}}function ag(e){var n;const t=[e.current_task_matches_run?"current":"drift",e.claim_marker_seen?"claim":"no-claim",e.done_marker_seen?"done":"no-done",e.final_marker_seen?"final":"no-final"];return{key:`swarm:${e.name}`,name:e.name,role:e.role,lane:e.lane,status:e.status,source:"swarm",task:e.current_task??e.bound_task_title??e.bound_task_id??"할당 없음",heartbeat:e.heartbeat_age_sec!=null?`${Math.round(e.heartbeat_age_sec)}초`:e.heartbeat_fresh?"정상":"정보 없음",detail:[e.bound_task_status??null,e.detachment_member?"분견대 소속":null,e.squad_member?"분대 소속":null].filter(Boolean).join(" · ")||"스웜 실시간 카드",markers:t,note:((n=e.last_message)==null?void 0:n.content)??null}}function ig(e,t){const n=e.actor??e.spawn_role??`워커-${t+1}`,s=e.spawn_role??e.worker_class??e.spawn_agent??"워커",a=e.lane_id??e.capsule_mode??e.control_domain??"세션",o=[e.has_turn?"turn":"silent",e.empty_note_turn_count>0?`empty:${e.empty_note_turn_count}`:"noted",e.turn_count>0?`turns:${e.turn_count}`:"turns:0"];return{key:`session:${n}:${t}`,name:n,role:s,lane:a,status:e.status,source:"session",task:e.task_profile??e.runtime_pool??"세션 레인",heartbeat:e.last_turn_ts_iso?X(e.last_turn_ts_iso):"정보 없음",detail:[e.spawn_agent??null,e.spawn_model??null,e.routing_confidence!=null?is(e.routing_confidence):null].filter(Boolean).join(" · ")||"세션 요약 카드",markers:o,note:e.routing_reason??null}}function mr(e){return P(e.severity)}function og({worker:e}){return i`
    <article class="command-card compact warroom-worker-card ${P(Bt(e.status))}">
      <div class="command-card-head">
        <div>
          <strong>${e.name}</strong>
          <div class="command-card-sub">${e.role} · ${e.lane}</div>
        </div>
        <span class="command-chip ${P(Bt(e.status))}">${bt(e.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>출처</span><span>${ng(e.source)}</span>
        <span>과업</span><span>${e.task}</span>
        <span>최근 신호</span><span>${e.heartbeat}</span>
        <span>근거</span><span>${e.detail}</span>
      </div>
      <div class="command-tag-row">
        ${e.markers.map(t=>i`<span class="command-tag">${sg(t)}</span>`)}
      </div>
      ${e.note?i`<div class="command-card-foot">${e.note}</div>`:null}
    </article>
  `}function Ye({label:e,surface:t,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(t){at(t),se("command",{...$o(t),...n});return}se("intervene")}}
    >
      ${e}
    </button>
  `}function rg(){var ee,A,Te,Je,_t,ft,K,ze,gt,_n,fn,ls,cs,ds,us,ps,ms,vs,Po,Lo,Mo;const e=rs(),t=Mt.value,n=_e.value,s=De.value,a=U_(),o=t!=null&&t.operation?((ee=as.value)==null?void 0:ee.operations.find(Y=>{var _s;return Y.operation.operation_id===((_s=t.operation)==null?void 0:_s.operation_id)}))??null:null,l=K_(),c=(t==null?void 0:t.workers)??[],p=(s==null?void 0:s.worker_cards)??[],m=l&&c.length>0?c.map(ag):p.map(ig),u=l,_=((A=e==null?void 0:e.decisions.summary)==null?void 0:A.pending)??0,g=(n==null?void 0:n.pending_confirms)??[],h=l?(t==null?void 0:t.blockers)??[]:[],b=(s==null?void 0:s.recommended_actions)??[],$=(Te=s==null?void 0:s.active_recommended_actions)!=null&&Te.length?s.active_recommended_actions:b,S=s==null?void 0:s.active_summary,C=(s==null?void 0:s.active_guidance_layer)??"fallback",x=(s==null?void 0:s.resident_judge_runtime)??(n==null?void 0:n.resident_judge_runtime),L=(s==null?void 0:s.attention_items)??[],T=((Je=t==null?void 0:t.recent_messages[0])==null?void 0:Je.timestamp)??null,R=((_t=t==null?void 0:t.recent_trace_events[0])==null?void 0:_t.timestamp)??null,M=l?T??R??null:null,z=a==null?void 0:a.summary,j=(l?(ft=t==null?void 0:t.summary)==null?void 0:ft.expected_workers:void 0)??(typeof(z==null?void 0:z.planned_worker_count)=="number"?z.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,Z=(l?(K=t==null?void 0:t.summary)==null?void 0:K.joined_workers:void 0)??(typeof(z==null?void 0:z.active_agent_count)=="number"?z.active_agent_count:void 0)??m.length,ie=h.length>0||_>0||g.length>0?"warn":u||a?"ok":"warn",V=l?((ze=e==null?void 0:e.swarm_status)==null?void 0:ze.lanes.filter(Y=>Y.present))??[]:[];return ne(()=>{ye()},[]),ne(()=>{a!=null&&a.session_id&&rn(a.session_id)},[a==null?void 0:a.session_id,n,(gt=t==null?void 0:t.detachment)==null?void 0:gt.session_id]),!u&&!a?ca.value||Dn.value?i`<div class="empty-state">실시간 워룸 불러오는 중…</div>`:i`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">실시간 워룸</div>
          <${O} panelId="command.warroom" compact=${!0} />
        </div>
        <div class="command-warroom-empty-copy">
          <strong>지금 보이는 실시간 실행이 없습니다</strong>
          <p>활성 작전이나 팀 세션이 시작되면 이 화면이 자동으로 붙잡습니다.</p>
        </div>
        <div class="command-action-row">
          <${Ye} label="작전 보기" surface="operations" />
          <${Ye} label="스웜 보기" surface="swarm" />
          <${Ye} label="개입 열기" />
          <${Ye} label="제어 보기" surface="control" />
        </div>
      </section>
    `:i`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${P(ie)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">실시간 워룸</span>
            <strong>${l?((_n=t==null?void 0:t.operation)==null?void 0:_n.objective)??(a==null?void 0:a.session_id)??"가동 중인 실행":(a==null?void 0:a.session_id)??"가동 중인 실행"}</strong>
            <div class="command-card-sub">
              ${l?((fn=t==null?void 0:t.operation)==null?void 0:fn.operation_id)??"작전 정보 없음":"세션 기준값"}
              ${a!=null&&a.session_id?` · 세션 ${a.session_id}`:""}
              ${l&&((ls=t==null?void 0:t.detachment)!=null&&ls.detachment_id)?` · 분견대 ${t.detachment.detachment_id}`:""}
            </div>
            ${S!=null&&S.summary?i`<div class="command-warroom-guidance ${ha(C)}">
                  <strong>${bo(C)}</strong>
                  <span>${S.summary}</span>
                </div>`:null}
          </div>
          <div class="command-action-row">
            <${Ye}
              label="스웜 상세"
              surface="swarm"
              params=${{...l&&((cs=t==null?void 0:t.operation)!=null&&cs.operation_id)?{operation_id:t.operation.operation_id}:{},...l&&(t!=null&&t.run_id)?{run_id:t.run_id}:{}}}
            />
            <${Ye} label="트레이스" surface="trace" />
            ${l&&o?i`<${Ye}
                  label="체인"
                  surface="chains"
                  params=${{operation:o.operation.operation_id}}
                />`:null}
            <${Ye} label="개입" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>워커</span>
            <strong>${Z??0}/${j??0}</strong>
            <small>${l?((ds=t==null?void 0:t.summary)==null?void 0:ds.completed_workers)??0:0} 완료 · ${m.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>런타임</span>
            <strong>${l?(us=t==null?void 0:t.provider)!=null&&us.runtime_blocker?"막힘":(ps=t==null?void 0:t.provider)!=null&&ps.provider_reachable?"준비됨":a?bt(a.status):"확인 필요":a?bt(a.status):"확인 필요"}</strong>
            <small>${l?`슬롯 ${((ms=t==null?void 0:t.provider)==null?void 0:ms.active_slots_now)??0}/${((vs=t==null?void 0:t.provider)==null?void 0:vs.actual_slots)??((Po=t==null?void 0:t.provider)==null?void 0:Po.total_slots)??0} · 컨텍스트 ${((Lo=t==null?void 0:t.provider)==null?void 0:Lo.actual_ctx)??((Mo=t==null?void 0:t.provider)==null?void 0:Mo.ctx_per_slot)??0}`:`세션 워커 ${(s==null?void 0:s.worker_cards.length)??0}`}</small>
          </div>
          <div class="monitor-stat-card ${P(h.length>0||_>0?"warn":"ok")}">
            <span>압력</span>
            <strong>${h.length+_+g.length}</strong>
            <small>막힘 ${h.length} · 승인 ${_} · 확인 ${g.length}</small>
          </div>
          <div class="monitor-stat-card ${P(ha(C))}">
            <span>상주 판정기</span>
            <strong>${ko(x)}</strong>
            <small>${xo(S)}${x!=null&&x.model_used?` · ${x.model_used}`:""}</small>
          </div>
          <div class="monitor-stat-card">
            <span>마지막 신호</span>
            <strong>${X(M)}</strong>
            <small>${T?"메시지":R?"트레이스":"대기 중"}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${V.length>0?i`
                  <${Ac} lanes=${V} />
                  <${Cc} lanes=${V} />
                `:a?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${P(Bt(a.status))}">${bt(a.status)}</span>
                      </div>
                      <p>스웜 실시간 증거는 아직 약합니다. 이 카드는 세션 요약과 워커 기록을 기준으로 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${kn(a.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${kn(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 레인이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">워커 현황</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${m.length>0?i`<div class="command-card-stack">
                  ${m.map(Y=>i`<${og} worker=${Y} />`)}
                </div>`:i`<div class="empty-state">활성 워커 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">상황 피드</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${t&&t.recent_messages.length>0&&l?i`<div class="command-trace-stack">
                  ${t.recent_messages.map(Y=>i`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${Y.from}</strong>
                          <span class="command-chip">${X(Y.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${Y.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${Y.content}</pre>
                    </article>
                  `)}
                </div>`:$.length>0||L.length>0?i`<div class="command-card-stack">
                    ${$.slice(0,4).map(Y=>i`
                      <article class="command-guide-card ${mr(Y)}">
                        <div class="command-guide-head">
                          <strong>${Y.action_type}</strong>
                          <span class="command-chip ${mr(Y)}">${Y.target_type}</span>
                        </div>
                        <p>${Y.reason}</p>
                      </article>
                    `)}
                    ${L.slice(0,3).map(Y=>i`
                      <article class="command-alert ${P(Y.severity)}">
                        <div class="command-card-head">
                          <strong>${Y.kind}</strong>
                          <span class="command-chip ${P(Y.severity)}">${Y.severity}</span>
                        </div>
                        <p>${Y.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?i`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((Y,_s)=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>세션 이벤트 ${_s+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${va(Y)}</pre>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">메시지나 주의 항목이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">트레이스 흐름</div>
              <${O} panelId="command.trace" compact=${!0} />
            </div>
            ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                  ${t.recent_trace_events.map(Y=>i`<${So} event=${Y} />`)}
                </div>`:i`<div class="empty-state">실행 범위 트레이스 이벤트가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">압력</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&t?i`<${xc} swarm=${t} />`:null}
              ${h.length>0?h.map(Y=>i`<${Ic} blocker=${Y} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${_>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>승인 대기</strong>
                        <span class="command-chip warn">${_}</span>
                      </div>
                      <p>엄격 액션이 묶여 있습니다. 실제 승인 처리는 제어 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${g.length>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>확인 대기</strong>
                        <span class="command-chip warn">${g.length}</span>
                      </div>
                      <p>운영자 미리보기가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${g.slice(0,3).map(Y=>i`<span class="command-tag">${Y.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
            </div>
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">현재 초점</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&(t!=null&&t.operation)?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${t.operation.objective}</strong>
                          <div class="command-card-sub">${t.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${P(Bt(t.operation.status))}">${bt(t.operation.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>유닛</span><span>${t.operation.assigned_unit_id}</span>
                        <span>트레이스</span><span>${t.operation.trace_id}</span>
                        <span>자율성</span><span>${t.operation.autonomy_level??"정보 없음"}</span>
                        <span>최근 갱신</span><span>${X(t.operation.updated_at)}</span>
                      </div>
                    </article>
                  `:null}
              ${l&&(t!=null&&t.detachment)?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${t.detachment.detachment_id}</strong>
                          <div class="command-card-sub">${t.detachment.assigned_unit_id}</div>
                        </div>
                        <span class="command-chip ${P(Bt(t.detachment.status))}">${bt(t.detachment.status??"active")}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>리더</span><span>${t.detachment.leader_id??"미지정"}</span>
                        <span>편성</span><span>${t.detachment.roster.length}</span>
                        <span>세션</span><span>${t.detachment.session_id??"연결 없음"}</span>
                        <span>하트비트</span><span>${dc(t.detachment.heartbeat_deadline)}</span>
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
                        <span class="command-chip ${P(Bt(a.status))}">${bt(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${kn(a.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${kn(a.remaining_sec)}</span>
                        <span>완료 변화량</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function vr(e){switch((e??"").trim().toLowerCase()){case"active":return"가동 중";case"paused":return"일시정지";case"failed":return"실패";case"completed":case"done":return"완료";case"disconnected":return"끊김";case"preview":return"미리보기";case"captured":return"기록됨";default:return(e==null?void 0:e.trim())||"확인 필요"}}function lg({source:e}){const t=Yc(null),[n,s]=Rr(null);return ne(()=>{let a=!1;const o=t.current;return o?(o.innerHTML="",s(null),(async()=>{try{const c=await A_(),{svg:p}=await c.render(`command-chain-${C_()}`,e);if(a||!t.current)return;t.current.innerHTML=p}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid 렌더링에 실패했습니다")}})(),()=>{a=!0,t.current&&(t.current.innerHTML="")}):void 0},[e]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${t}></div>
    </div>
  `}function cg({overlay:e,selected:t,onSelect:n}){const s=e.operation.chain,a=e.runtime;return i`
    <button class="command-chain-item ${t?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${e.operation.objective}</strong>
          <div class="command-card-sub">${e.operation.operation_id}</div>
        </div>
        <span class="command-chip ${it(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??e.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?i`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?i`<span class="command-tag ${it(s==null?void 0:s.status)}">${is(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${uc(e.history)}</div>
    </button>
  `}function dg({item:e}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${e.chain_id??"알 수 없는 체인"}</strong>
        <span class="command-chip ${it(e.event)}">${e.event}</span>
      </div>
      <div class="command-card-sub">${X(e.timestamp)}</div>
      <div class="command-card-sub">${uc(e)}</div>
    </article>
  `}function ug({node:e}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${e.id}</strong>
        <span class="command-chip ${it(e.status)}">${e.status??"확인 필요"}</span>
      </div>
      <div class="command-card-sub">
        ${e.type??"노드"}
        ${typeof e.duration_ms=="number"?` · ${e.duration_ms}ms`:""}
      </div>
      ${e.error?i`<div class="command-card-sub error-text">${e.error}</div>`:null}
    </article>
  `}function pg({card:e}){const t=e.operation,n=`pause:${t.operation_id}`,s=`resume:${t.operation_id}`,a=`recall:${t.operation_id}`,o=t.chain,l=(o==null?void 0:o.run_id)??null;return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${t.objective}</strong>
          <div class="command-card-sub">${t.operation_id}</div>
        </div>
        <span class="command-chip ${P(t.status==="active"?"ok":t.status==="paused"?"warn":t.status==="failed"?"bad":"ok")}">${vr(t.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${e.assigned_unit_label??t.assigned_unit_id}</span>
        <span>트레이스</span><span class="mono">${t.trace_id}</span>
        <span>자율성</span><span>${t.autonomy_level??"정보 없음"}</span>
        <span>예산 등급</span><span>${t.budget_class??"standard"}</span>
        <span>출처</span><span>${t.source??"managed"}</span>
        <span>최근 갱신</span><span>${X(t.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${it(o.status)}">${vr(o.status)}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">실행 ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${t.checkpoint_ref?i`<div class="command-card-foot">체크포인트 ${t.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{at("swarm"),se("command",{surface:"swarm",operation_id:t.operation_id,...l?{run_id:l}:{}})}}
        >
          스웜 실시간 보기
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{fo(t.operation_id),at("chains"),se("command",{surface:"chains",operation:t.operation_id})}}
              >
                체인 열기
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="active"?i`
              <button class="control-btn ghost" disabled=${oe(n)} onClick=${()=>ot(()=>__(t.operation_id))}>
                ${oe(n)?"일시정지 중…":"일시정지"}
              </button>
              <button class="control-btn ghost" disabled=${oe(a)} onClick=${()=>ot(()=>g_(t.operation_id))}>
                ${oe(a)?"회수 중…":"회수"}
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="paused"?i`
              <button class="control-btn ghost" disabled=${oe(s)} onClick=${()=>ot(()=>f_(t.operation_id))}>
                ${oe(s)?"재개 중…":"재개"}
              </button>
            `:null}
      </div>
    </article>
  `}function mg({card:e}){var n;const t=e.detachment;return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.detachment_id}</strong>
          <div class="command-card-sub">${((n=e.operation)==null?void 0:n.objective)??t.operation_id}</div>
        </div>
        <span class="command-chip ${P(t.status)}">${t.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${e.assigned_unit_label??t.assigned_unit_id}</span>
        <span>리더</span><span>${t.leader_id??"미지정"}</span>
        <span>편성</span><span>${t.roster.length}</span>
        <span>세션</span><span>${t.session_id??"연결 없음"}</span>
        <span>런타임</span><span>${t.runtime_kind??"managed"}</span>
        <span>런타임 참조</span><span>${t.runtime_ref??"정보 없음"}</span>
        <span>진행 흔적</span><span>${X(t.last_progress_at)}</span>
        <span>하트비트</span><span>${dc(t.heartbeat_deadline)}</span>
        <span>최근 갱신</span><span>${X(t.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${t.heartbeat_deadline?i`<span class="command-tag ${x_(t.heartbeat_deadline)}">
              기한 ${t.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function vg(){const e=qe.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">작전</div>
          <${O} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.operations.operations.length>0?i`<div class="command-card-stack">
              ${e.operations.operations.map(t=>i`<${pg} card=${t} />`)}
            </div>`:i`<div class="empty-state">관리형 또는 투영된 작전이 없습니다.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">분견대</div>
          <${O} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${e.detachments.detachments.map(t=>i`<${mg} card=${t} />`)}
            </div>`:i`<div class="empty-state">투영된 분견대가 없습니다.</div>`}
      </section>
    </div>
  `}function _g(){var c,p,m,u,_,g,h,b,$,S,C,x,L,T,R,M;const e=as.value,t=(e==null?void 0:e.operations)??[],n=Zt.value,s=t.find(z=>z.operation.operation_id===n)??t[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,o=((p=qn.value)==null?void 0:p.run)??(s==null?void 0:s.preview_run)??null,l=!((m=qn.value)!=null&&m.run)&&!!(s!=null&&s.preview_run);return ne(()=>{a?m_(a):p_()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${O} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${it(e==null?void 0:e.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp 연결</strong>
            <span class="command-chip ${it(e==null?void 0:e.connection.status)}">${(e==null?void 0:e.connection.status)??"disconnected"}</span>
          </div>
          <p>${(e==null?void 0:e.connection.message)??"체인 요약은 MASC 프록시를 통해 집계됩니다."}</p>
          <div class="command-card-grid">
            <span>기준 URL</span><span>${(e==null?void 0:e.connection.base_url)??"정보 없음"}</span>
            <span>연결된 작전</span><span>${((u=e==null?void 0:e.summary)==null?void 0:u.linked_operations)??0}</span>
            <span>활성 체인</span><span>${((_=e==null?void 0:e.summary)==null?void 0:_.active_chains)??0}</span>
            <span>최근 실패</span><span>${((g=e==null?void 0:e.summary)==null?void 0:g.recent_failures)??0}</span>
            <span>마지막 이벤트</span><span>${X((h=e==null?void 0:e.summary)==null?void 0:h.last_history_event_at)}</span>
          </div>
        </article>

        ${pa.value?i`<div class="empty-state error">${pa.value}</div>`:null}

        ${Di.value&&!e?i`<div class="empty-state">체인 오버레이 불러오는 중…</div>`:t.length>0?i`
                <div class="command-chain-list">
                  ${t.map(z=>i`
                    <${cg}
                      overlay=${z}
                      selected=${(s==null?void 0:s.operation.operation_id)===z.operation.operation_id}
                      onSelect=${()=>fo(z.operation.operation_id)}
                    />
                  `)}
                </div>
              `:i`<div class="empty-state">체인 기반 작전이 아직 없습니다.</div>`}

        <div class="command-chain-history">
          <div class="command-guide-head">
            <strong>최근 이력</strong>
            <span class="command-chip">${(e==null?void 0:e.recent_history.length)??0}</span>
          </div>
          ${e&&e.recent_history.length>0?i`
                <div class="command-card-stack">
                  ${e.recent_history.slice(0,6).map(z=>i`<${dg} item=${z} />`)}
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
                  <span class="command-chip ${it((b=s.operation.chain)==null?void 0:b.status)}">
                    ${(($=s.operation.chain)==null?void 0:$.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>종류</span><span>${((S=s.operation.chain)==null?void 0:S.kind)??"chain_dsl"}</span>
                  <span>체인 ID</span><span>${((C=s.operation.chain)==null?void 0:C.chain_id)??"goal-driven"}</span>
                  <span>실행 ID</span><span>${a??"아직 구체화되지 않음"}</span>
                  <span>진행률</span><span>${is((x=s.runtime)==null?void 0:x.progress)}</span>
                  <span>경과</span><span>${kn((L=s.runtime)==null?void 0:L.elapsed_sec)}</span>
                  <span>최근 갱신</span><span>${X(((T=s.operation.chain)==null?void 0:T.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(R=s.operation.chain)!=null&&R.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid 그래프</strong>
                        <span class="command-chip">${((M=s.operation.chain)==null?void 0:M.chain_id)??"graph"}</span>
                      </div>
                      <${lg} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">기록된 Mermaid 그래프가 아직 없습니다.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>실행 상세</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"실패":l?"미리보기":"기록됨":"대기 중"}
                  </span>
                </div>
                ${ma.value?i`<div class="empty-state">실행 상세 불러오는 중…</div>`:Fn.value?i`<div class="empty-state error">${Fn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>체인</span><span>${o.chain_id}</span>
                            <span>실행</span><span>${o.run_id??"미리보기만 있음"}</span>
                            <span>지속시간</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"정보 없음"}</span>
                            <span>노드</span><span>${o.nodes.length}</span>
                          </div>
                          ${l?i`<div class="command-card-foot">run-store에 기록되기 전, 설계된 체인으로 만든 미리보기입니다.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(z=>i`<${ug} node=${z} />`)}
                          </div>
                        `:i`<div class="empty-state">이 작전의 run-store 상세는 아직 없습니다.</div>`}
              </div>
            `:i`<div class="empty-state">그래프와 실행 상세를 보려면 체인 기반 작전을 고르세요.</div>`}
      </section>
    </div>
  `}function fg(e){switch((e??"").trim().toLowerCase()){case"pending":return"대기 중";case"approved":return"승인됨";case"denied":return"거부됨";case"executed":return"실행됨";case"active":return"가동 중";default:return(e==null?void 0:e.trim())||"확인 필요"}}function gg({decision:e}){const t=`approve:${e.decision_id}`,n=`deny:${e.decision_id}`,s=e.source==="projected_operator";return i`
    <article class="command-card ${P(e.status)}">
      <div class="command-card-head">
        <div>
          <strong>${e.requested_action}</strong>
          <div class="command-card-sub">${e.scope_type}:${e.scope_id}</div>
        </div>
        <span class="command-chip ${P(e.status)}">${fg(e.status??"pending")}</span>
      </div>
      <div class="command-card-grid">
        <span>결정 ID</span><span>${e.decision_id}</span>
        <span>요청자</span><span>${e.requested_by??"알 수 없음"}</span>
        <span>출처</span><span>${e.source??"managed"}</span>
        <span>트레이스</span><span class="mono">${e.trace_id}</span>
        <span>생성 시각</span><span>${X(e.created_at)}</span>
        <span>이유</span><span>${e.reason??"정보 없음"}</span>
      </div>
      ${e.status==="pending"&&!s?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${oe(t)} onClick=${()=>ot(()=>h_(e.decision_id))}>
                ${oe(t)?"승인 중…":"승인"}
              </button>
              <button class="control-btn ghost" disabled=${oe(n)} onClick=${()=>ot(()=>y_(e.decision_id))}>
                ${oe(n)?"거부 중…":"거부"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">레거시 operator 승인입니다. 실제 실행은 operator control에서 처리합니다.</div>`:null}
    </article>
  `}function $g({row:e}){var c,p,m;const t=e.unit,n=`freeze:${t.unit_id}`,s=`kill:${t.unit_id}`,a=!!((c=t.policy)!=null&&c.frozen),o=!!((p=t.policy)!=null&&p.kill_switch),l=Math.round((e.utilization??0)*100);return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.label}</strong>
          <div class="command-card-sub">${t.unit_id}</div>
        </div>
        <span class="command-chip ${P(l>100?"bad":l>70?"warn":"ok")}">${l}%</span>
      </div>
      <div class="command-card-grid">
        <span>편성</span><span>${e.roster_live??0}/${e.roster_total??0}</span>
        <span>정원</span><span>${e.headcount_cap??0}</span>
        <span>작전</span><span>${e.active_operations??0}/${e.active_operation_cap??0}</span>
        <span>자율성</span><span>${((m=t.policy)==null?void 0:m.autonomy_level)??"정보 없음"}</span>
        <span>동결</span><span>${a?"예":"아니오"}</span>
        <span>킬 스위치</span><span>${o?"켜짐":"꺼짐"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${oe(n)} onClick=${()=>ot(()=>b_(t.unit_id,!a))}>
          ${oe(n)?"적용 중…":a?"동결 해제":"동결"}
        </button>
        <button class="control-btn ghost" disabled=${oe(s)} onClick=${()=>ot(()=>k_(t.unit_id,!o))}>
          ${oe(s)?"적용 중…":o?"킬 스위치 해제":"킬 스위치 켜기"}
        </button>
      </div>
    </article>
  `}function hg(){const e=qe.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${O} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${e.decisions.decisions.map(t=>i`<${gg} decision=${t} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">유닛 제어</div>
          <${O} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${e.capacity.capacity.map(t=>i`<${$g} row=${t} />`)}
            </div>`:i`<div class="empty-state">제어할 용량 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function yg(){return i`
    <div class="command-surface-tabs grouped">
      ${T_.map(e=>i`
        <div class="command-tab-group" key=${e.id}>
          <span class="command-tab-group-label">${e.label}</span>
          <div class="command-tab-group-items">
            ${pc.filter(t=>t.group===e.id).map(t=>i`
                <button
                  class="command-surface-tab ${G.value===t.id?"active":""}"
                  onClick=${()=>{at(t.id),se("command",$o(t.id))}}
                >
                  ${t.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function bg(){if(G.value==="warroom")return i`<${rg} />`;if(G.value==="summary")return i`<${df} />`;if(G.value==="orchestra")return i`<${yf} />`;if(G.value==="swarm")return i`<${tg} />`;if(!qe.value)return i`<${uf} />`;switch(G.value){case"chains":return i`<${_g} />`;case"topology":return i`<${Ff} />`;case"alerts":return i`<${Kf} />`;case"trace":return i`<${Bf} />`;case"control":return i`<${hg} />`;case"operations":default:return i`<${vg} />`}}function kg(){return ne(()=>{Kt(),en(),v_(),Qe(),Tt()},[]),ne(()=>{if(F.value.tab!=="command")return;const e=F.value.params.surface,t=F.value.params.operation,n=ns(F.value);if(sr(e))at(e);else if(n){const s=Il(n);sr(s)&&at(s)}else e||at("warroom");t&&fo(t),(e==="swarm"||e==="warroom"||e==="orchestra"||G.value==="warroom"||G.value==="orchestra")&&Qe(),(e==="orchestra"||G.value==="orchestra")&&Tt(),(e==="warroom"||G.value==="warroom")&&ye()},[F.value.tab,F.value.params.surface,F.value.params.operation,F.value.params.operation_id,F.value.params.run_id,F.value.params.source,F.value.params.action_type,F.value.params.target_type,F.value.params.target_id,F.value.params.focus_kind]),ne(()=>{let e=null;const t=()=>{e||(e=window.setTimeout(()=>{e=null,Kt(),en(),(G.value==="swarm"||G.value==="warroom"||G.value==="orchestra")&&Qe(),G.value==="orchestra"&&Tt(),G.value==="warroom"&&ye()},250))},n=new EventSource(M_()),s=R_.map(a=>{const o=()=>t();return n.addEventListener(a,o),{type:a,handler:o}});return n.onerror=()=>{t()},()=>{s.forEach(({type:a,handler:o})=>{n.removeEventListener(a,o)}),n.close(),e&&window.clearTimeout(e)}},[]),ne(()=>{const e=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const t=G.value;t!=="swarm"&&t!=="warroom"&&t!=="orchestra"||(Kt(),Qe(),t==="orchestra"&&Tt(),t==="warroom"&&ye())},5e3);return()=>{window.clearInterval(e)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{ot(()=>$_())}}
            disabled=${oe("dispatch:tick")}
          >
            ${oe("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Kt(),en(),Qe(),G.value==="warroom"&&ye()}}
            disabled=${sa.value}
          >
            ${sa.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${ia.value?i`<div class="empty-state error">${ia.value}</div>`:null}
      ${ra.value?i`<div class="empty-state error">${ra.value}</div>`:null}
      <${be} surfaceId="command" />
      <${af} />
      ${G.value==="warroom"?null:i`<${of} />`}
      <${yg} />
      <${bg} />
    </section>
  `}function xg(){var S,C;const e=_e.value,t=lo.value,n=(e==null?void 0:e.room)??{},s=(e==null?void 0:e.pending_confirms)??[],a=e==null?void 0:e.pending_confirm_summary,o=a?a.confirm_required_actions:((e==null?void 0:e.available_actions)??[]).filter(x=>x.confirm_required),l=((S=a==null?void 0:a.actor_filter)==null?void 0:S.trim())||null,c=(a==null?void 0:a.hidden_count)??0,p=(a==null?void 0:a.hidden_actors)??[],m=(e==null?void 0:e.recent_messages)??[],u=(t==null?void 0:t.recommended_actions)??[],_=(C=t==null?void 0:t.active_recommended_actions)!=null&&C.length?t.active_recommended_actions:u,g=t==null?void 0:t.active_summary,h=(t==null?void 0:t.resident_judge_runtime)??(e==null?void 0:e.resident_judge_runtime),b=(t==null?void 0:t.active_guidance_layer)??"fallback",$=m.slice(0,5);return i`
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
          <div class="ops-stat ${xf(h)}">
            <span>Resident Judge</span>
            <strong>${ko(h)}</strong>
          </div>
        </div>

        <label class="control-label" for="ops-broadcast">Room 방송</label>
        <div class="control-row">
          <input
            id="ops-broadcast"
            class="control-input"
            type="text"
            placeholder="@agent 또는 room 전체 공지"
            value=${tn.value}
            onInput=${x=>{tn.value=x.target.value}}
            onKeyDown=${x=>{x.key==="Enter"&&ur()}}
            disabled=${W.value}
          />
          <button class="control-btn" onClick=${()=>{ur()}} disabled=${W.value||tn.value.trim()===""}>
            보내기
          </button>
        </div>

        <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
        <div class="control-row ops-split-row">
          <input
            id="ops-pause-reason"
            class="control-input"
            type="text"
            value=${_a.value}
            onInput=${x=>{_a.value=x.target.value}}
            disabled=${W.value}
          />
          <button class="control-btn ghost" onClick=${()=>{Mf()}} disabled=${W.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{hc()}} disabled=${W.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${nn.value}
          onInput=${x=>{nn.value=x.target.value}}
          disabled=${W.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${Kn.value}
          onInput=${x=>{Kn.value=x.target.value}}
          disabled=${W.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${Bn.value}
            onChange=${x=>{Bn.value=x.target.value}}
            disabled=${W.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{jf()}} disabled=${W.value||nn.value.trim()===""}>
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
        <article class="ops-guidance-card ${ha(b)}">
          <div class="ops-guidance-head">
            <strong>${bo(b)}</strong>
            <span>${(h==null?void 0:h.keeper_name)??(t==null?void 0:t.judgment_owner)??"judge 없음"}</span>
          </div>
          <div class="ops-guidance-body">
            ${(g==null?void 0:g.summary)??"현재 active guidance 요약이 없습니다. fallback queue만 표시합니다."}
          </div>
          <div class="ops-guidance-meta">
            <span>authoritative ${t!=null&&t.authoritative_judgment_available?"yes":"no"}</span>
            <span>${xo(g)}</span>
            ${h!=null&&h.model_used?i`<span>${h.model_used}</span>`:null}
          </div>
        </article>
        ${On.value&&!t?i`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:_.length>0?i`
          <div class="ops-log-list">
            ${_.map(x=>i`
              <article key=${`${x.action_type}:${x.target_type}:${x.target_id??"room"}`} class="ops-log-entry ${x.severity}">
                <div class="ops-log-head">
                  <strong>${Rt(x.action_type)}</strong>
                  <span>${an(x.target_type)}${x.target_id?` · ${x.target_id}`:""}</span>
                  <span>${ya(x.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${x.reason}</div>
                ${x.suggested_payload?i`
                  <div class="ops-confirmation-actions">
                    <button class="control-btn ghost" onClick=${()=>{Pf(x)}} disabled=${W.value}>
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
            ${o.map(x=>i`
              <article key=${`${x.action_type}:${x.target_type}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${Rt(x.action_type)}</strong>
                  <span>${an(x.target_type)}</span>
                  <span>${ya(x.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${x.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}
        ${s.length>0?i`
          <div class="ops-confirmation-list">
            ${s.map(x=>i`
              <article key=${x.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${Rt(x.action_type)}</strong>
                  <span>${an(x.target_type)}${x.target_id?` · ${x.target_id}`:""}</span>
                  <span>${x.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${x.preview?i`<pre class="ops-code-block compact">${$a(x.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{pr(x.confirm_token)}} disabled=${W.value}>
                    실행
                  </button>
                  <button class="control-btn ghost" onClick=${()=>{pr(x.confirm_token,"deny")}} disabled=${W.value}>
                    거부
                  </button>
                  <span class="ops-token">${x.confirm_token}</span>
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
          <${O} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${$.length>0?i`
          <div class="ops-feed-list">
            ${$.map(x=>i`
              <article key=${x.seq??x.id??x.timestamp} class="ops-feed-item">
                <div class="ops-feed-meta">
                  <strong>${x.from}</strong>
                  <span>${x.timestamp}</span>
                </div>
                <div class="ops-feed-content">${x.content}</div>
              </article>
            `)}
          </div>
        `:i`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
      </section>
    </div>
  `}function Sg(){var m;const e=_e.value,t=De.value,n=(e==null?void 0:e.sessions)??[],s=((e==null?void 0:e.available_actions)??[]).filter(u=>u.target_type==="team_session"),a=n.find(u=>u.session_id===ln.value)??n[0]??null,o=t==null?void 0:t.active_summary,l=(t==null?void 0:t.active_guidance_layer)??"fallback",c=(t==null?void 0:t.resident_judge_runtime)??(e==null?void 0:e.resident_judge_runtime),p=(m=t==null?void 0:t.active_recommended_actions)!=null&&m.length?t.active_recommended_actions:(t==null?void 0:t.recommended_actions)??[];return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${O} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(u=>{var _;return i`
            <button
              key=${u.session_id}
              class="ops-entity-card ${(a==null?void 0:a.session_id)===u.session_id?"active":""}"
              onClick=${()=>{ln.value=u.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${u.session_id}</strong>
                <span class="status-badge ${u.status??"idle"}">${Ut(u.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(u.progress_pct??0)}%</span>
                <span>${u.done_delta_total??0}건 완료</span>
                <span>${(_=u.team_health)!=null&&_.status?Ut(String(u.team_health.status)):"상태 확인 필요"}</span>
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
        ${a&&t?i`
          <article class="ops-guidance-card ${ha(l)}">
            <div class="ops-guidance-head">
              <strong>${bo(l)}</strong>
              <span>${ko(c)}</span>
            </div>
            <div class="ops-guidance-body">
              ${(o==null?void 0:o.summary)??"현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다."}
            </div>
            <div class="ops-guidance-meta">
              <span>authoritative ${t.authoritative_judgment_available?"yes":"no"}</span>
              <span>${xo(o)}</span>
              ${c!=null&&c.model_used?i`<span>${c.model_used}</span>`:null}
            </div>
          </article>
          ${p.length>0?i`
            <div class="ops-log-list">
              ${p.map(u=>i`
                <article key=${`${u.action_type}:${u.target_type}:${u.target_id??"session"}`} class="ops-log-entry ${u.severity}">
                  <div class="ops-log-head">
                    <strong>${Rt(u.action_type)}</strong>
                    <span>${an(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
                  </div>
                  <div class="ops-log-body">${u.reason}</div>
                </article>
              `)}
            </div>
          `:null}
          <div class="ops-log-list">
            ${t.attention_items.length>0?t.attention_items.map(u=>i`
              <article key=${`${u.kind}:${u.target_id??"session"}`} class="ops-log-entry ${u.severity}">
                <div class="ops-log-head">
                  <strong>${u.kind}</strong>
                  <span>${an(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${u.summary}</div>
              </article>
            `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${t.worker_cards.length>0?t.worker_cards.map(u=>i`
              <article key=${`${u.actor??u.spawn_role??"worker"}:${u.spawn_agent??u.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${u.actor??u.spawn_role??"worker"}</strong>
                  <span>${Ut(u.status)}</span>
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
          <${O} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>
        ${s.length>0?i`
          <div class="ops-log-list">
            ${s.map(u=>i`
              <article key=${u.action_type} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${Rt(u.action_type)}</strong>
                  <span>${ya(u.confirm_required)}</span>
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
              <span>상태: ${Ut(a.status)}</span>
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
              <pre class="ops-code-block compact">${$a(a.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${he.value}
            onChange=${u=>{he.value=u.target.value}}
            disabled=${W.value||!a}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
            <option value="worker_spawn_batch">worker 교체</option>
          </select>
          <button class="control-btn" onClick=${()=>{Ef()}} disabled=${W.value||!a}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${If(he.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${Un.value}
          onInput=${u=>{Un.value=u.target.value}}
          disabled=${W.value||!a}
        ></textarea>

        ${he.value==="task"?i`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${Hn.value}
            onInput=${u=>{Hn.value=u.target.value}}
            disabled=${W.value||!a}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${Wn.value}
            onInput=${u=>{Wn.value=u.target.value}}
            disabled=${W.value||!a}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${Gn.value}
            onChange=${u=>{Gn.value=u.target.value}}
            disabled=${W.value||!a}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
        `:he.value==="worker_spawn_batch"?i`
          <textarea
            class="control-textarea"
            rows=${6}
            placeholder='spawn_batch JSON, 예: [{"spawn_agent":"llama","spawn_prompt":"...", "spawn_role":"replacement"}]'
            value=${Jn.value}
            onInput=${u=>{Jn.value=u.target.value}}
            disabled=${W.value||!a}
          ></textarea>
        `:null}

        <div class="control-row ops-split-row">
          <input
            class="control-input"
            type="text"
            value=${fa.value}
            onInput=${u=>{fa.value=u.target.value}}
            disabled=${W.value||!a}
          />
          <button class="control-btn ghost" onClick=${()=>{Nf()}} disabled=${W.value||!a}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function Cg(){var o;const e=_e.value,t=(e==null?void 0:e.keepers)??[],n=(e==null?void 0:e.persistent_agents)??[],s=(e==null?void 0:e.available_actions)??[],a=t.find(l=>l.name===ga.value)??t[0]??null;return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${O} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${t.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:t.map(l=>i`
            <button
              key=${l.name}
              class="ops-entity-card ${(a==null?void 0:a.name)===l.name?"active":""}"
              onClick=${()=>{ga.value=l.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${l.name}</strong>
                <span class="status-badge ${l.status??"idle"}">${Ut(l.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${l.model??"model 확인 필요"}</span>
                <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${cr(l.last_turn_ago_s)}</span>
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
                    <span class="status-badge ${l.status??"idle"}">${Ut(l.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>persistent</span>
                    <span>${l.model??"model 확인 필요"}</span>
                    <span>${cr(l.last_turn_ago_s)}</span>
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
        `:i`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

        <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
        <textarea
          id="ops-keeper-message"
          class="control-textarea"
          rows=${6}
          placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
          value=${sn.value}
          onInput=${l=>{sn.value=l.target.value}}
          disabled=${W.value||!a}
        ></textarea>
        <div class="control-row">
          <button class="control-btn" onClick=${()=>{wf()}} disabled=${W.value||!a||sn.value.trim()===""}>
            keeper에 보내기
          </button>
        </div>
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
                    <strong>${Rt(l.action_type)}</strong>
                    <span>${an(l.target_type)}</span>
                    <span>${ya(l.confirm_required)}</span>
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
          ${ta.value.length===0?i`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:ta.value.map(l=>i`
            <article key=${l.id} class="ops-log-entry ${l.outcome}">
              <div class="ops-log-head">
                <strong>${Rt(l.action_type)}</strong>
                <span>${l.target_label}</span>
                <span>${l.at}</span>
              </div>
              <div class="ops-log-body">${l.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function Ag(){var T,R,M;const e=_e.value,t=F.value.tab==="intervene"?ns(F.value):null,n=lo.value,s=(e==null?void 0:e.room)??{},a=(e==null?void 0:e.sessions)??[],o=(e==null?void 0:e.keepers)??[],l=(e==null?void 0:e.pending_confirms)??[],c=e==null?void 0:e.pending_confirm_summary,p=(c==null?void 0:c.visible_count)??l.length,m=(c==null?void 0:c.total_count)??l.length,u=(c==null?void 0:c.hidden_count)??0,_=((T=c==null?void 0:c.actor_filter)==null?void 0:T.trim())||null,g=a.find(z=>z.session_id===ln.value)??a[0]??null,h=(n==null?void 0:n.attention_items)??[],b=h.filter(Cf),$=h.filter(Af),S=a.filter(z=>Sf(z)!=="ok"),C=o.filter(z=>Ya(z)!=="ok"),x=Lf(t,a,o);ne(()=>{Pt()},[]),ne(()=>{if(F.value.tab!=="intervene"){bs.value=null;return}if(!t){bs.value=null;return}bs.value!==t.id&&(bs.value=t.id,Rf(t))},[F.value.tab,F.value.params.source,F.value.params.action_type,F.value.params.target_type,F.value.params.target_id,F.value.params.focus_kind,t==null?void 0:t.id]),ne(()=>{const z=(g==null?void 0:g.session_id)??null;rn(z)},[g==null?void 0:g.session_id]);const L=[{key:"room",label:"방 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:u>0?`${p}/${m}`:p,detail:p>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":u>0&&_?`현재 개입 ID(${_}) 기준으로는 비어 있고, 다른 개입 ID 대기 ${u}건이 있습니다`:"지금 막혀 있는 확인 대기는 없습니다",tone:m>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:b.length>0?b.length:a.length,detail:b.length>0?((R=b[0])==null?void 0:R.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 팀 세션이 없습니다":"세션 쪽 긴급 주의 신호는 현재 없습니다",tone:b.length>0?dr(b):a.length===0?"warn":S.some(z=>cn(z.status)==="paused")?"bad":S.length>0?"warn":"ok"},{key:"keeper",label:"키퍼 압력",value:$.length>0?$.length:C.length,detail:$.length>0?((M=$[0])==null?void 0:M.summary)??"직접 메시지나 상태 점검이 필요한 키퍼가 있습니다":C.length>0?"오래됐거나 오프라인이거나 텔레메트리가 비는 키퍼가 보입니다":"지금은 키퍼 쪽이 비교적 안정적입니다",tone:$.length>0?dr($):C.some(z=>Ya(z)==="bad")?"bad":C.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${be} surfaceId="intervene" />
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
            value=${Da.value}
            onInput=${z=>kf(z.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{ye(),Pt(),rn((g==null?void 0:g.session_id)??null)}}
            disabled=${Dn.value||W.value}
          >
            ${Dn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${lt.value?i`<section class="ops-banner error">${lt.value}</section>`:null}
      ${on.value?i`<section class="ops-banner error">${on.value}</section>`:null}
      ${t?i`
        <section class="ops-banner ${x?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${t.source_label}</strong>
            <span>${ja(t.action_type)}</span>
            <span>${io(t)}</span>
          </div>
          <div class="ops-handoff-body">${t.summary}</div>
          ${t.payload_preview?i`<div class="ops-handoff-preview">${t.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${x?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const z=[];if((p>0||u>0)&&z.push({label:u>0?`확인 대기 ${p}/${m}건 확인`:`확인 대기 ${p}건 처리`,desc:u>0&&_?`현재 개입 ID(${_}) 기준으로 보이는 대기열을 먼저 확인합니다`:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:p>0?"bad":"warn",onClick:()=>{const j=document.querySelector(".ops-pending-section");j==null||j.scrollIntoView({behavior:"smooth"})}}),s.paused&&z.push({label:"방 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void hc()}),C.length>0){const j=C.filter(Z=>Ya(Z)==="bad");z.push({label:j.length>0?`오프라인 키퍼 ${j.length}개`:`점검이 필요한 키퍼 ${C.length}개`,desc:j.length>0?"메시지를 보내거나 상태를 확인하세요":"오래됐거나 텔레메트리가 비어 있습니다",tone:j.length>0?"bad":"warn",onClick:()=>{const Z=document.querySelector(".ops-keeper-section");Z==null||Z.scrollIntoView({behavior:"smooth"})}})}return z.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${z.slice(0,3).map(j=>i`
                <button class="ops-action-guide-item ${j.tone}" onClick=${j.onClick}>
                  <strong>${j.label}</strong>
                  <span>${j.desc}</span>
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
          ${L.map(z=>i`
            <div key=${z.key} class="ops-priority-card ${z.tone}">
              <span class="ops-priority-label">${z.label}</span>
              <strong>${z.value}</strong>
              <div class="ops-priority-detail">${z.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${xg} />
        <${Sg} />
        <${Cg} />
      </div>
    </section>
  `}function Ig({text:e}){if(!e)return null;const t=Tg(e);return i`<div class="markdown-content">${t}</div>`}function Tg(e){const t=e.split(`
`),n=[];let s=0;for(;s<t.length;){const a=t[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),p=[];for(s++;s<t.length&&!t[s].startsWith(l);)p.push(t[s]),s++;s++,n.push(i`<pre><code class=${c?`language-${c}`:""}>${p.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<t.length&&!t[s].includes("</think>");)l.push(t[s]),s++;if(s<t.length){const m=t[s].replace("</think>","").trim();m&&l.push(m),s++}const p=l.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Xa(p)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<t.length&&t[s].startsWith("> ");)l.push(t[s].slice(2)),s++;n.push(i`<blockquote>${Xa(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<t.length;){const l=t[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;o.push(l),s++}o.length>0&&n.push(i`<p>${Xa(o.join(`
`))}</p>`)}return n}function Xa(e){const t=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(e))!==null;){if(a.index>s&&t.push(e.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);t.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);t.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);t.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&t.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<e.length&&t.push(e.slice(s)),t.length>0?t:[e]}const Tc=[{id:"recent",label:"최신순"},{id:"hot",label:"인기순"},{id:"trending",label:"급상승"},{id:"updated",label:"최근 갱신"},{id:"discussed",label:"토론 많은 순"}],Ds=f(null),Os=f([]),dn=f(!1),zt=f(null),zn=f(""),Rn=f(!1),Ht=f(!0),Co=20,Dt=f(Co);function zg(){var t,n;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Rg=f(zg());function Pg(e){const t=e.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return t?t.length>180?`${t.slice(0,177)}...`:t:"미리보기 없음"}function _r(e){return e.updated_at!==e.created_at}function Lg(e){if(e.post_kind)return e.post_kind==="automation";const t=(e.hearth??"").toLowerCase();return e.visibility!=="internal"||!e.expires_at||!t?!1:!!(t.startsWith("mdal")||t.includes("harness"))}function Mg(e){return e==="lodge-system"||e==="team-session"}function Vn(e){return e.post_kind?e.post_kind:Mg(e.author)?"system":Lg(e)?"automation":"human"}function zc(e){const t=[],n=[];let s=0;return e.forEach(a=>{const o=Vn(a);if(!(o==="system"&&St.value)){if(o==="automation"&&Ht.value){s+=1;return}if(o==="human"){t.push(a);return}n.push(a)}}),{human:t,operations:n,hiddenAutomation:s}}function jg(e){if(!e.expires_at)return null;const t=Date.parse(e.expires_at);return Number.isFinite(t)?t<=Date.now()?i`<span class="board-meta-chip">만료됨</span>`:i`<span class="board-meta-chip">만료까지 <${J} timestamp=${e.expires_at} /></span>`:null}async function Ao(e){zt.value=e,Ds.value=null,Os.value=[],dn.value=!0;try{const t=await Yd(e);if(zt.value!==e)return;Ds.value={id:t.id,author:t.author,title:t.title,body:t.body,content:t.content,meta:t.meta,tags:t.tags,votes:t.votes,vote_balance:t.vote_balance,comment_count:t.comment_count,created_at:t.created_at,updated_at:t.updated_at,post_kind:t.post_kind,flair:t.flair,hearth:t.hearth,visibility:t.visibility,expires_at:t.expires_at,hearth_count:t.hearth_count},Os.value=t.comments??[]}catch{zt.value===e&&(Ds.value=null,Os.value=[])}finally{zt.value===e&&(dn.value=!1)}}async function fr(e){const t=zn.value.trim();if(t){Rn.value=!0;try{await Xd(e,Rg.value,t),zn.value="",E("댓글을 등록했습니다","success"),await Ao(e),nt()}catch{E("댓글 등록에 실패했습니다","error")}finally{Rn.value=!1}}}function Eg(){const e=jn.value,t=Ht.value?"자동화 글 숨김":"자동화 글 표시 중";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Tc.map(n=>i`
          <button
            class="board-sort-btn ${e===n.id?"active":""}"
            onClick=${()=>{jn.value=n.id,Dt.value=Co,nt()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Ht.value?"is-active":""}"
          onClick=${()=>{Ht.value=!Ht.value}}
        >
          ${t}
        </button>
        <button
          class="control-btn ghost ${St.value?"is-active":""}"
          onClick=${()=>{St.value=!St.value,nt()}}
        >
          ${St.value?"시스템 글 숨김":"시스템 글 표시 중"}
        </button>
        <button class="control-btn ghost" onClick=${nt} disabled=${En.value}>
          ${En.value?"새로고침 중...":"새로고침"}
        </button>
      </div>
    </div>
  `}function Qa(){var s;const e=((s=Tc.find(a=>a.id===jn.value))==null?void 0:s.label)??jn.value,t=zc(Ma.value),n=t.human.length+t.operations.length;return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">보이는 글</span>
        <strong>${n}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">정렬</span>
        <strong>${e}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">잡음 필터</span>
        <strong>${Ht.value?`자동화 ${t.hiddenAutomation}건 숨김`:"분리된 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">시스템 글 정책</span>
        <strong>${St.value?"시스템 글 숨김":"시스템 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">최근 갱신</span>
        <strong>${zi.value?i`<${J} timestamp=${zi.value} />`:"아직 불러오지 않음"}</strong>
      </div>
    </div>
  `}function gr({post:e}){const t=async(n,s)=>{s.stopPropagation();try{await Gr(e.id,n),nt()}catch{E("투표에 실패했습니다","error")}};return i`
    <div class="board-post" onClick=${()=>td(e.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>t("up",n)}>▲</button>
        <span class="vote-count">${e.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>t("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-head">
            <div class="post-title-row">
              <div class="post-title">${e.title}</div>
              <div class="post-chip-row">
                ${_r(e)?i`<span class="board-meta-chip">수정됨</span>`:null}
                ${Vn(e)!=="human"?i`<span class="board-meta-chip">${Vn(e)}</span>`:null}
                ${e.hearth?i`<span class="board-meta-chip">${e.hearth}</span>`:null}
                ${e.visibility?i`<span class="board-meta-chip">${e.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>작성자 ${e.author}</span>
            <span><${J} timestamp=${e.created_at} /></span>
            ${_r(e)?i`<span>수정 <${J} timestamp=${e.updated_at} /></span>`:null}
            <span>댓글 ${e.comment_count}</span>
            <span>투표 ${e.votes??0}</span>
          </div>
        </div>
        <div class="post-snippet">${Pg(e.body)}</div>
      </div>
    </div>
  `}function Ng({comments:e}){return e.length===0?i`<div class="empty-state" style="font-size:13px">아직 댓글이 없습니다</div>`:i`
    <div class="comment-thread">
      ${e.map(t=>i`
        <div key=${t.id} class="board-comment">
          <span class="comment-author">${t.author}</span>
          <span class="comment-time"><${J} timestamp=${t.created_at} /></span>
          <div class="comment-text">${t.content}</div>
        </div>
      `)}
    </div>
  `}function wg({postId:e}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="댓글 추가..."
        value=${zn.value}
        onInput=${t=>{zn.value=t.target.value}}
        onKeyDown=${t=>{t.key==="Enter"&&fr(e)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Rn.value}
      />
      <button
        onClick=${()=>fr(e)}
        disabled=${Rn.value||zn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Rn.value?"...":"등록"}
      </button>
    </div>
  `}function Dg({post:e}){zt.value!==e.id&&!dn.value&&Ao(e.id);const t=async n=>{try{await Gr(e.id,n),nt()}catch{E("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>se("memory")}>← 메모리로 돌아가기</button>
      <${I} title=${e.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${Ig} text=${e.body} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${e.author}</span>
            <${J} timestamp=${e.created_at} />
            <span>${e.votes??0} votes</span>
          </div>
          ${e.hearth||e.visibility||e.expires_at?i`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${e.hearth?i`<span class="board-meta-chip">${e.hearth}</span>`:null}
                  ${e.visibility?i`<span class="board-meta-chip">${e.visibility}</span>`:null}
                  ${Vn(e)!=="human"?i`<span class="board-meta-chip">${Vn(e)}</span>`:null}
                  ${jg(e)}
                </div>
              `:null}
          ${e.meta?i`
                <details style="margin-top:12px;">
                  <summary>운영 메타</summary>
                  <div class="post-body" style="margin-top:8px;">
                    ${e.meta.source?i`<div><strong>출처</strong>: ${e.meta.source}</div>`:null}
                    ${e.meta.state_block?i`<pre style="white-space:pre-wrap; margin-top:8px;">${e.meta.state_block}</pre>`:null}
                  </div>
                </details>
              `:null}
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>t("up")}>▲ 추천</button>
            <button class="vote-btn downvote" onClick=${()=>t("down")}>▼ 비추천</button>
          </div>
        </div>
      <//>

      <${I} title="댓글" semanticId="memory.feed">
        ${dn.value?i`<div class="loading-indicator">댓글 불러오는 중...</div>`:i`<${Ng} comments=${Os.value} />`}
        <${wg} postId=${e.id} />
      <//>
    </div>
  `}function Og(){const e=zc(Ma.value),t=[...e.human,...e.operations],n=F.value.params.post??null,s=n?t.find(a=>a.id===n)??(zt.value===n?Ds.value:null):null;return n&&!s&&zt.value!==n&&!dn.value&&Ao(n),n?s?i`
          <${be} surfaceId="memory" />
          <${Qa} />
          <${Dg} post=${s} />
        `:i`
          <div>
            <${be} surfaceId="memory" />
            <${Qa} />
            <button class="back-btn" onClick=${()=>se("memory")}>← 메모리로 돌아가기</button>
            ${dn.value?i`<div class="loading-indicator">글 불러오는 중...</div>`:i`<div class="empty-state">글을 찾지 못했습니다</div>`}
          </div>
        `:i`
    <div>
      <${be} surfaceId="memory" />
      <${Qa} />
      <${Eg} />
      ${En.value?i`<div class="loading-indicator">메모리 피드 불러오는 중...</div>`:t.length===0?i`<div class="empty-state">지금은 남아 있는 메모리 글이 없습니다</div>`:i`
              <${I} title="사람이 쓴 글" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${e.human.slice(0,Dt.value).map(a=>i`<${gr} key=${a.id} post=${a} />`)}
                </div>
                ${e.human.length>Dt.value?i`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{Dt.value=Dt.value+Co}}
                    >
                      더 보기 (${e.human.length-Dt.value}개 남음)
                    </button>
                  </div>
                `:null}
              <//>
              ${e.operations.length>0?i`
                    <${I} title="자동화 · 시스템" class="section" semanticId="memory.feed">
                      <div class="board-post-list">
                        ${e.operations.map(a=>i`<${gr} key=${a.id} post=${a} />`)}
                      </div>
                    <//>
                  `:null}
            `}
    </div>
  `}function qg({ratio:e,size:t=40,stroke:n=4}){if(e==null)return null;const s=(t-n)/2,a=t/2,o=2*Math.PI*s,l=o*((100-e*100)/100);let c="mitosis-safe";return e>=.8?c="mitosis-critical":e>=.5&&(c="mitosis-warn"),i`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(e*100)}%">
      <svg class="mitosis-ring" width="${t}" height="${t}" viewBox="0 0 ${t} ${t}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${c}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${o}" 
          stroke-dashoffset="${l}" 
        />
      </svg>
      <span class="mitosis-text ${c}">${Math.round(e*100)}%</span>
    </div>
  `}const kt=f(null),Fe=f(null),Ke=f(null);function Oa(e){return e==="bad"||e==="critical"||e==="offline"?"bad":e==="warn"||e==="paused"||e==="blocked"||e==="interrupted"?"warn":"ok"}function ba(e){switch((e??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":return"주의";case"bad":case"critical":return"위험";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function Fg(e){return e==="session"?"세션":"작전"}function Kg(e){return typeof e!="number"||Number.isNaN(e)?"—":`${Math.round(e*100)}%`}function Bg(e){return e?pt.value.find(t=>t.name===e||t.agent_name===e)??null:null}function Ug(e){switch(e){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function Hg(e){switch(e){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function $r(e){if(!e)return;const t=am({targetType:e.target_type,targetId:e.target_id,focusKind:e.focus_kind,operationId:e.operation_id??null,commandSurface:e.command_surface??null,sourceLabel:"실행 진단",summary:e.label});Cl(t),se(e.surface,e.surface==="intervene"?Al(t):Tl(t))}function Nt({label:e,value:t,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${e}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${t}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function Io({intervene:e,command:t}){return i`
    <div class="control-row">
      ${e?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),$r(e)}}
            >
              ${e.label}
            </button>
          `:null}
      ${t?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),$r(t)}}
            >
              ${t.label}
            </button>
          `:null}
    </div>
  `}function Wg({item:e,selected:t}){return i`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{kt.value=t?null:e.id,Fe.value=null,Ke.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.kind==="session"?e.target_id:e.linked_session_id??e.target_id}</div>
          <div class="mission-card-title">${e.summary}</div>
        </div>
        <span class="command-chip ${Oa(e.severity)}">${ba(e.status??e.severity)}</span>
      </div>
      <div class="mission-card-meta">
        <span>${Fg(e.kind)}</span>
        ${e.linked_operation_id?i`<span>연결 작전 · ${e.linked_operation_id}</span>`:null}
        ${e.last_seen_at?i`<span><${J} timestamp=${e.last_seen_at} /></span>`:null}
      </div>
      <${Io} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function Gg({brief:e,selected:t}){return i`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.session-card"
      onClick=${()=>{Fe.value=t?null:e.session_id,Ke.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          <div class="mission-card-title">${e.goal}</div>
        </div>
        <span class="command-chip ${Oa(e.health??e.status)}">${ba(e.status)}</span>
      </div>
      <div class="mission-card-meta">
        <span>건강도 · ${ba(e.health??"ok")}</span>
        ${e.linked_operation_id?i`<span>연결 작전 · ${e.linked_operation_id}</span>`:null}
        ${e.last_activity_at?i`<span><${J} timestamp=${e.last_activity_at} /></span>`:null}
      </div>
      ${e.runtime_blocker?i`<div class="mission-card-detail">${e.runtime_blocker}</div>`:e.last_activity_summary?i`<div class="mission-card-detail">${e.last_activity_summary}</div>`:null}
      ${e.worker_gap_summary?i`<div class="monitor-footnote">${e.worker_gap_summary}</div>`:null}
      <${Io} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function Jg({brief:e,selected:t}){return i`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.operation-card"
      onClick=${()=>{Ke.value=t?null:e.operation_id,Fe.value=e.linked_session_id??null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.operation_id}${e.assigned_unit_label?` · ${e.assigned_unit_label}`:""}</div>
          <div class="mission-card-title">${e.objective}</div>
        </div>
        <span class="command-chip ${Oa(e.blocker_summary?"warn":e.status)}">${ba(e.status)}</span>
      </div>
      <div class="mission-card-meta">
        ${e.stage?i`<span>단계 · ${e.stage}</span>`:null}
        ${e.linked_session_id?i`<span>세션 · ${e.linked_session_id}</span>`:null}
        ${e.updated_at?i`<span><${J} timestamp=${e.updated_at} /></span>`:null}
      </div>
      ${e.blocker_summary?i`<div class="mission-card-detail">${e.blocker_summary}</div>`:null}
      ${e.next_tool?i`<div class="monitor-footnote">다음 도구 · ${e.next_tool}</div>`:null}
      <${Io} command=${e.command_handoff} />
    </button>
  `}function hr({row:e,testId:t}){return i`
    <button class="monitor-row ${e.tone} state-${e.state}" data-testid=${t} onClick=${()=>Na(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.korean_name?i`<span class="monitor-sub">${e.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${e.note}</div>
        </div>
        <${mt} status=${e.status??"unknown"} />
        <span class="monitor-pill ${e.tone} state-${e.state}">${Ug(e.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_signal_at?i`<span>신호 <${J} timestamp=${e.last_signal_at} /></span>`:i`<span>최근 신호 없음</span>`}
        <span>${(e.active_task_count??0)>0?`활성 작업 ${e.active_task_count}개`:"활성 작업 없음"}</span>
        ${e.related_session_id?i`<span>세션 · ${e.related_session_id}</span>`:null}
        ${e.related_operation_id?i`<span>작전 · ${e.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.recent_output_preview&&e.recent_output_preview!==e.focus?i`<div class="monitor-footnote">최근 상세: ${e.recent_output_preview}</div>`:null}
    </button>
  `}function Vg({row:e}){const t=()=>{const n=Bg(e.name);n&&Hl(n)};return i`
    <button class="monitor-row ${e.tone} state-${e.state}" data-testid="execution.continuity-card" onClick=${t}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.korean_name?i`<span class="monitor-sub">${e.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${e.note}</div>
        </div>
        <${qg} ratio=${e.context_ratio??0} size=${34} stroke=${4} />
        <${mt} status=${e.status??"unknown"} />
        <span class="monitor-pill ${e.tone}">${Hg(e.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_signal_at?i`<span>최근 활동 <${J} timestamp=${e.last_signal_at} /></span>`:i`<span>최근 활동 없음</span>`}
        ${e.related_session_id?i`<span>세션 · ${e.related_session_id}</span>`:null}
        ${e.continuity?i`<span>${e.continuity}</span>`:null}
        ${e.lifecycle?i`<span>생애주기 ${e.lifecycle}</span>`:null}
        <span>컨텍스트 ${Kg(e.context_ratio)}</span>
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.skill_reason?i`<div class="monitor-footnote">연속성 이유: ${e.skill_reason}</div>`:null}
    </button>
  `}function Yg(){const e=Qr.value,t=Zr.value,n=el.value,s=tl.value,a=nl.value,o=sl.value,l=al.value;kt.value&&!t.some($=>$.id===kt.value)&&(kt.value=null),Fe.value&&!n.some($=>$.session_id===Fe.value)&&(Fe.value=null),Ke.value&&!s.some($=>$.operation_id===Ke.value)&&(Ke.value=null);const c=kt.value?t.find($=>$.id===kt.value)??null:null,p=Fe.value?Fe.value:c?c.kind==="session"?c.target_id:c.linked_session_id??null:null,m=Ke.value?Ke.value:c?c.kind==="operation"?c.target_id:c.linked_operation_id??null:null,u=p?n.filter($=>$.session_id===p):m?n.filter($=>$.linked_operation_id===m):n,_=m?s.filter($=>$.operation_id===m):p?s.filter($=>{var S;return $.linked_session_id===p||$.operation_id===((S=u[0])==null?void 0:S.linked_operation_id)}):s,g=p||m?a.filter($=>(p?$.related_session_id===p:!1)||(m?$.related_operation_id===m:!1)):a,h=p?o.filter($=>$.related_session_id===p||$.tone!=="ok"):o,b=p||m?l.filter($=>(p?$.related_session_id===p:!1)||(m?$.related_operation_id===m:!1)||$.tone!=="ok"):l;return i`
    <div class="agents-monitor">
      <${be} surfaceId="execution" />
      <div class="stats-grid">
        <${Nt} label="활성 세션" value=${(e==null?void 0:e.active_sessions)??n.length} color="#4ade80" caption="실행 관점 세션 수" />
        <${Nt} label="막힌 세션" value=${(e==null?void 0:e.blocked_sessions)??n.filter($=>Oa($.health??$.status)!=="ok").length} color="#fbbf24" caption="개입이 필요한 세션 수" />
        <${Nt} label="활성 작전" value=${(e==null?void 0:e.active_operations)??s.length} color="#22d3ee" caption="지휘 평면 작전 수" />
        <${Nt} label="막힌 작전" value=${(e==null?void 0:e.blocked_operations)??s.filter($=>$.blocker_summary).length} color="#fb7185" caption="원인 확인이 필요한 작전 수" />
        <${Nt} label="인력 경고" value=${(e==null?void 0:e.worker_alerts)??a.filter($=>$.tone!=="ok").length} color="#fb7185" caption="지원 인력 압박" />
        <${Nt} label="연속성 경고" value=${(e==null?void 0:e.continuity_alerts)??o.filter($=>$.tone!=="ok").length} color="#fb7185" caption="키퍼 연속성 압박" />
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
          ${t.length===0?i`<div class="empty-state">지금은 막힌 실행이 없습니다.</div>`:t.map($=>i`<${Wg} key=${$.id} item=${$} selected=${kt.value===$.id} />`)}
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
            ${u.length===0?i`<div class="empty-state">선택된 실행과 연결된 세션이 없습니다.</div>`:u.map($=>i`<${Gg} key=${$.session_id} brief=${$} selected=${Fe.value===$.session_id} />`)}
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
            ${_.length===0?i`<div class="empty-state">선택된 실행과 연결된 작전이 없습니다.</div>`:_.map($=>i`<${Jg} key=${$.operation_id} brief=${$} selected=${Ke.value===$.operation_id} />`)}
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
            ${g.length===0?i`<div class="empty-state">연결된 작업자가 없습니다.</div>`:g.map($=>i`<${hr} key=${$.name} row=${$} testId="execution.worker-card" />`)}
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
            ${h.length===0?i`<div class="empty-state">지금은 연속성 경고가 없습니다.</div>`:h.map($=>i`<${Vg} key=${$.name} row=${$} />`)}
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
            ${b.length===0?i`<div class="empty-state">지금은 오프라인 작업자가 없습니다.</div>`:b.map($=>i`<${hr} key=${$.name} row=${$} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const ka=f("all"),xa=f("all"),qi=f(new Set);function Xg(e){const t=new Set(qi.value);t.has(e)?t.delete(e):t.add(e),qi.value=t}const Rc=Ie(()=>{let e=Jt.value;return ka.value!=="all"&&(e=e.filter(t=>t.horizon===ka.value)),xa.value!=="all"&&(e=e.filter(t=>t.status===xa.value)),e}),Qg=Ie(()=>{const e={short:[],mid:[],long:[]};for(const t of Rc.value){const n=e[t.horizon];n&&n.push(t)}return e}),Zg=Ie(()=>{const e=Array.from(ol.value.values());return e.sort((t,n)=>t.status==="running"&&n.status!=="running"?-1:n.status==="running"&&t.status!=="running"?1:t.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&t.status!=="interrupted"?1:n.elapsed_seconds-t.elapsed_seconds),e});function e$(e){return"★".repeat(Math.min(e,5))+"☆".repeat(Math.max(0,5-e))}function To(e){switch(e){case"short":return"단기";case"mid":return"중기";case"long":return"장기";default:return e}}function qs(e){switch(e){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function t$(e){return e<60?`${Math.round(e)}s`:e<3600?`${Math.floor(e/60)}m ${Math.round(e%60)}s`:`${Math.floor(e/3600)}h ${Math.floor(e%3600/60)}m`}function yr(e){return e.toFixed(4)}function br(e){const t=e.current_metric-e.baseline_metric;return`${t>=0?"+":""}${t.toFixed(4)}`}function n$(e){switch(e){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function s$(e){switch(e){case"active":return"진행 중";case"completed":return"완료";case"paused":return"일시정지";default:return"전체"}}function kr(e,t){return(e.priority??4)-(t.priority??4)}function a$(e,t){const n=e.updated_at??e.created_at??"";return(t.updated_at??t.created_at??"").localeCompare(n)}function i$(e,t){return e.length<=t?e:e.slice(0,t)+"..."}function o$({goal:e}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${qs(e.horizon)}">
            ${To(e.horizon)}
          </span>
          <span class="goal-title">${e.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${e.priority}">${e$(e.priority)}</span>
          ${e.metric?i`<span class="goal-metric">${e.metric}${e.target_value?` → ${e.target_value}`:""}</span>`:null}
          ${e.due_date?i`<span class="goal-due">Due: <${J} timestamp=${e.due_date} /></span>`:null}
        </div>
        ${e.last_review_note?i`
          <div class="goal-review-note">${e.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${mt} status=${e.status} />
        <div class="goal-updated">
          <${J} timestamp=${e.updated_at} />
        </div>
      </div>
    </div>
  `}function Za({horizon:e,items:t}){if(t.length===0)return null;const n=[...t].sort((s,a)=>a.priority-s.priority);return i`
    <${I} title="${To(e)} 목표 (${t.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${o$} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function r$(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">범위</label>
        ${["all","short","mid","long"].map(e=>i`
          <button
            class="goal-filter-btn ${ka.value===e?"active":""}"
            onClick=${()=>{ka.value=e}}
          >
            ${e==="all"?"전체":To(e)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">상태</label>
        ${["all","active","completed","paused"].map(e=>i`
          <button
            class="goal-filter-btn ${xa.value===e?"active":""}"
            onClick=${()=>{xa.value=e}}
          >
            ${s$(e)}
          </button>
        `)}
      </div>
    </div>
  `}function l$(){const e=Jt.value,t=e.filter(a=>a.status==="active").length,n=e.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of e)a.horizon in s&&s[a.horizon]++;return i`
    <div class="goal-summary">
      <div class="goal-summary-item">
        <div class="goal-summary-value">${e.length}</div>
        <div class="goal-summary-label">전체</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#4ade80">${t}</div>
        <div class="goal-summary-label">진행 중</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#888">${n}</div>
        <div class="goal-summary-label">완료</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${qs("short")}">${s.short}</div>
        <div class="goal-summary-label">단기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${qs("mid")}">${s.mid}</div>
        <div class="goal-summary-label">중기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${qs("long")}">${s.long}</div>
        <div class="goal-summary-label">장기</div>
      </div>
    </div>
  `}function c$({loop:e}){const t=e.history[0],n=e.latest_tool_names&&e.latest_tool_names.length>0?`${e.latest_tool_call_count??e.latest_tool_names.length}개 도구: ${e.latest_tool_names.join(", ")}`:"아직 근거 없음";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${e.profile}</div>
            <div class="planning-loop-sub">${e.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${mt} status=${e.status} />
            <span class="pill">${e.current_iteration}${e.max_iterations>0?`/${e.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${yr(e.baseline_metric)}</span>
          <span>현재 ${yr(e.current_metric)}</span>
          <span class=${br(e).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${br(e)}
          </span>
          <span>Elapsed ${t$(e.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${e.target||"명시된 목표가 없습니다"}</div>
        ${e.stop_reason||e.error_message?i`
              <div class="planning-loop-footnote">
                ${e.error_message??e.stop_reason}
              </div>
            `:null}
        <div class="planning-loop-footnote">
          ${e.strict_mode?"엄격 근거 모드":"레거시"} · ${e.worker_engine??"엔진 정보 없음"} · ${n}
        </div>
        ${t?i`
              <div class="planning-loop-footnote">
                최근 반복 #${t.iteration}: ${t.changes||t.next_suggestion||"서술 정보 없음"}
              </div>
            `:i`<div class="planning-loop-footnote">반복 이력이 아직 없습니다</div>`}
      </div>
    </div>
  `}function ei({task:e}){const t=e.priority??4,n=t<=1?"p1":t===2?"p2":t===3?"p3":"p4",s=qi.value.has(e.id),a=!!e.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${n$(t)}</span>
        <div class="kanban-card-title">${e.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>Xg(e.id)}
        >
          ${s?e.description:i$(e.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${e.created_at?i`<${J} timestamp=${e.created_at} />`:i`<span>-</span>`}
        ${e.assignee?i`<span class="kanban-assignee">${e.assignee}</span>`:null}
      </div>
    </div>
  `}function d$(){const{todo:e,inProgress:t,done:n}=ll.value,s=[...e].sort(kr),a=[...t].sort(kr),o=[...n].sort(a$);return i`
    <${I} title="태스크 백로그" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>할 일</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">대기 중인 태스크가 없습니다</div>`:s.map(l=>i`<${ei} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>진행 중</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">진행 중인 태스크가 없습니다</div>`:a.map(l=>i`<${ei} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>완료</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">완료된 태스크가 없습니다</div>`:o.slice(0,20).map(l=>i`<${ei} key=${l.id} task=${l} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...외 ${o.length-20}개 더 있음</div>`:null}
        </div>
      </div>
    <//>
  `}function u$(){const{todo:e,inProgress:t,done:n}=ll.value,s=e.length+t.length+n.length,a=[...e,...t].filter(u=>(u.priority??4)<=2).length,o=Qg.value,l=Zg.value,c=Jt.value.length>0,p=l.length>0,m=Zi.value;return i`
    <div>
      <${be} surfaceId="planning" />

      <!-- Step 1: Task-based stats grid -->
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">전체 태스크</div>
          <div class="stat-value">${s}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">할 일</div>
          <div class="stat-value" style="color:#e0e0e0">${e.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">진행 중</div>
          <div class="stat-value" style="color:#fbbf24">${t.length}</div>
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
          onClick=${()=>{no(),_l()}}
          disabled=${xn.value||Sn.value}
        >
          ${xn.value||Sn.value?"새로고침 중...":"계획 데이터 새로고침"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${d$} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          목표 파이프라인
          <span class="monitor-pill">${Jt.value.length}</span>
        </summary>
        <div>
          ${c?i`
            <${l$} />
            <${r$} />
            ${xn.value&&Jt.value.length===0?i`<div class="loading-indicator">목표 불러오는 중...</div>`:Rc.value.length===0?i`<div class="empty-state">현재 필터에 맞는 목표가 없습니다</div>`:i`
                    <${Za} horizon="short" items=${o.short??[]} />
                    <${Za} horizon="mid" items=${o.mid??[]} />
                    <${Za} horizon="long" items=${o.long??[]} />
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
          ${Sn.value&&l.length===0?i`<div class="loading-indicator">MDAL 루프 불러오는 중...</div>`:l.length===0&&(m==="error"||Vt.value)?i`<div class="empty-state">MDAL 스냅샷을 불러오지 못했습니다${Vt.value?`: ${Vt.value}`:""}. 백엔드 상태를 확인하세요.</div>`:l.length===0?i`<div class="empty-state">가동 중인 루프가 없습니다. <code>masc_mdal_start</code>로 시작할 수 있습니다.</div>`:i`
                  <div class="planning-loop-list">
                    ${l.map(u=>i`<${c$} key=${u.loop_id} loop=${u} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const Sa=f(!1),Pn=f(!1),Wt=f(!1),dt=f(""),Ln=f(""),Fi=f("open"),Ee=f(null),Yn=f(null),Ca=f(null),Aa=f(null),Ki=f(!1);function Xn(e){return`${e.kind}:${e.id}`}function zo(){var n;const e=Yn.value,t=((n=Ee.value)==null?void 0:n.items)??[];return e?t.find(s=>Xn(s)===e)??null:null}function p$(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");return(t==null?void 0:t.trim())||"dashboard"}function m$(e){const t=e.trim().toLowerCase();return t==="open"||t==="pending"}function Pc(e){return!!(e.judgment_summary&&e.judgment_summary.trim())}function Lc(e){switch(Fi.value){case"needs_quorum":return e.filter(t=>t.kind==="consensus"&&(t.votes??0)<(t.quorum??0));case"ready":return e.filter(t=>{var n;return(n=t.guardrail_state)==null?void 0:n.ready_to_execute});case"needs_approval":return e.filter(t=>{var n,s;return((n=t.guardrail_state)==null?void 0:n.requires_human_gate)||!!((s=t.guardrail_state)!=null&&s.pending_confirm)});case"judge_offline":return e.filter(t=>!Pc(t));case"open":default:return e.filter(t=>m$(t.status))}}function v$(e){if(e==null)return"없음";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function qa(e){const t=(e||"").toLowerCase();return t.includes("reject")||t.includes("deny")||t.includes("closed")||t.includes("cancel")?"negative":t.includes("approve")||t.includes("support")||t.includes("open")||t.includes("ready")?"positive":"neutral"}function _$(e){return typeof e!="number"||Number.isNaN(e)?"확인 필요":`${Math.round(e*100)}%`}function yn(e){return"resolved_tool"in e||"payload_preview"in e||"reason"in e}async function Mc(e){if(Ca.value=null,Aa.value=null,!!e){Ki.value=!0,dt.value="";try{e.kind==="debate"?Ca.value=await Su(e.id):Aa.value=await Cu(e.id)}catch(t){dt.value=t instanceof Error?t.message:"거버넌스 상세를 불러오지 못했습니다"}finally{Ki.value=!1}}}async function f$(e){Yn.value=Xn(e),await Mc(e)}async function un(){var e;Sa.value=!0,dt.value="";try{const t=await Cd();Ee.value=t;const n=Lc(t.items??[]),s=Yn.value,a=n.find(o=>Xn(o)===s)??n[0]??((e=t.items)==null?void 0:e[0])??null;Yn.value=a?Xn(a):null,await Mc(a)}catch(t){dt.value=t instanceof Error?t.message:"거버넌스 상태를 불러오지 못했습니다"}finally{Sa.value=!1}}Sp(un);async function xr(){const e=Ln.value.trim();if(e){Pn.value=!0;try{const t=await xu(e);Ln.value="",E(t!=null&&t.id?`토론을 시작했습니다: ${t.id}`:"토론을 시작했습니다","success"),await un()}catch(t){const n=t instanceof Error?t.message:"토론 시작에 실패했습니다";dt.value=n,E(n,"error")}finally{Pn.value=!1}}}async function Sr(e){var o,l;const t=zo(),n=(o=t==null?void 0:t.guardrail_state)==null?void 0:o.pending_confirm,s=n==null?void 0:n.confirm_token;if(!s)return;const a=((l=n==null?void 0:n.actor)==null?void 0:l.trim())||p$();Wt.value=!0;try{await Fr(a,s,e),E(e==="confirm"?"액션을 승인했습니다":"액션을 거부했습니다","success"),await un()}catch(c){const p=c instanceof Error?c.message:"대기 중인 액션 처리에 실패했습니다";dt.value=p,E(p,"error")}finally{Wt.value=!1}}function g$(){var n,s,a,o,l,c;const e=(n=Ee.value)==null?void 0:n.summary,t=(s=Ee.value)==null?void 0:s.judge;return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">열린 토론</span>
        <strong>${(e==null?void 0:e.debates_open)??((o=(a=Ee.value)==null?void 0:a.debates)==null?void 0:o.length)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">합의 세션</span>
        <strong>${(e==null?void 0:e.sessions_active)??((c=(l=Ee.value)==null?void 0:l.sessions)==null?void 0:c.length)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">정족수 부족</span>
        <strong>${(e==null?void 0:e.sessions_without_quorum)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">실행 준비</span>
        <strong>${(e==null?void 0:e.ready_to_execute)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">판정기</span>
        <strong>${(t==null?void 0:t.judge_online)??(e==null?void 0:e.judge_online)?"온라인":"오프라인"}</strong>
      </div>
    </div>
  `}function $$(){return i`
    <${I} title="거버넌스 콘솔" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="토론 주제를 입력하세요..."
            value=${Ln.value}
            onInput=${e=>{Ln.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&xr()}}
            disabled=${Pn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${xr}
            disabled=${Pn.value||Ln.value.trim()===""}
          >
            ${Pn.value?"시작 중...":"토론 시작"}
          </button>
          <button class="control-btn ghost" onClick=${un} disabled=${Sa.value}>
            ${Sa.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
        <div class="governance-filter-row">
          ${[["open","열림"],["needs_quorum","정족수 부족"],["ready","준비됨"],["needs_approval","승인 필요"],["judge_offline","판정기 오프라인"]].map(([e,t])=>i`
            <button
              class="control-btn ${Fi.value===e?"is-active":"ghost"}"
              onClick=${async()=>{Fi.value=e,await un()}}
            >
              ${t}
            </button>
          `)}
        </div>
        ${dt.value?i`<div class="council-error">${dt.value}</div>`:null}
      </div>
    <//>
  `}function h$(){var t;const e=Lc(((t=Ee.value)==null?void 0:t.items)??[]);return i`
    <${I} title="의사결정 수신함" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${e.length===0?i`
              <div class="empty-state">
                지금 필터에 맞는 토론이나 합의 세션이 없습니다.
              </div>
            `:e.map(n=>{var a,o;const s=Yn.value===Xn(n);return i`
                <button
                  class="council-row governance-decision-row ${s?"selected":""}"
                  onClick=${()=>f$(n)}
                >
                  <div class="council-row-main">
                    <div class="governance-row-head">
                      <span class="governance-kind">${n.kind}</span>
                      <span class="council-topic">${n.topic}</span>
                    </div>
                    <div class="council-sub">
                      <span>${n.truth_summary||"사실 요약이 아직 없습니다"}</span>
                      ${n.last_activity_at?i`<span><${J} timestamp=${n.last_activity_at} /></span>`:null}
                    </div>
                    <div class="governance-chip-row">
                      ${(a=n.guardrail_state)!=null&&a.requires_human_gate?i`<span class="governance-chip warn">승인 필요</span>`:null}
                      ${(o=n.guardrail_state)!=null&&o.ready_to_execute?i`<span class="governance-chip ok">준비됨</span>`:null}
                      ${n.kind==="consensus"&&(n.votes??0)<(n.quorum??0)?i`<span class="governance-chip warn">정족수 부족</span>`:null}
                      ${Pc(n)?null:i`<span class="governance-chip dim">판정기 오프라인</span>`}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${qa(n.status)}">${n.status}</span>
                    ${n.kind==="consensus"?i`<span class="governance-vote-meter">${n.votes??0}/${n.quorum??0}</span>`:i`<span class="governance-vote-meter">${n.evidence_refs.length} refs</span>`}
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function y$({argument:e}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${qa(e.position)}">${e.position}</span>
        <strong>${e.agent}</strong>
        ${e.created_at?i`<span><${J} timestamp=${e.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.content}</div>
      <div class="governance-chip-row">
        ${e.evidence.map(t=>i`<span class="governance-chip">${t}</span>`)}
        ${e.reply_to!=null?i`<span class="governance-chip">답글 #${e.reply_to}</span>`:null}
        ${e.mentions.map(t=>i`<span class="governance-chip">@${t}</span>`)}
        ${e.archetype?i`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function b$({vote:e}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${qa(e.decision)}">${e.decision}</span>
        <strong>${e.agent}</strong>
        ${e.timestamp?i`<span><${J} timestamp=${e.timestamp} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.reason||"기록된 이유가 없습니다."}</div>
      <div class="governance-chip-row">
        ${e.weight!=null?i`<span class="governance-chip">가중치 ${e.weight}</span>`:null}
        ${e.archetype?i`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function k$(){const e=zo(),t=Ca.value,n=Aa.value;return i`
    <${I}
      title=${e?`${e.kind==="debate"?"토론":"합의"} 상세`:"의사결정 상세"}
      class="section"
      semanticId="governance.detail"
    >
      ${Ki.value?i`<div class="loading-indicator">거버넌스 상세 불러오는 중...</div>`:e?e.kind==="debate"&&t?i`
                <div class="governance-detail-head">
                  <div>
                    <h3>${t.debate.topic}</h3>
                    <div class="council-sub">
                      <span>${t.debate.id}</span>
                      <span>${t.debate.status}</span>
                      ${t.debate.created_at?i`<span><${J} timestamp=${t.debate.created_at} /></span>`:null}
                    </div>
                  </div>
                  <div class="governance-balance-grid">
                    <span class="governance-balance"><strong>${t.summary.support_count}</strong> support</span>
                    <span class="governance-balance"><strong>${t.summary.oppose_count}</strong> oppose</span>
                    <span class="governance-balance"><strong>${t.summary.neutral_count}</strong> neutral</span>
                    <span class="governance-balance"><strong>${t.summary.total_arguments}</strong> total</span>
                  </div>
                </div>
                ${t.summary.summary_text?i`<div class="governance-summary-callout">${t.summary.summary_text}</div>`:null}
                <div class="governance-ledger">
                  ${t.arguments.length===0?i`<div class="empty-state">기록된 토론이 아직 없습니다.</div>`:t.arguments.map(s=>i`<${y$} key=${s.index} argument=${s} />`)}
                </div>
              `:e.kind==="consensus"&&n?i`
                  <div class="governance-detail-head">
                    <div>
                      <h3>${n.session.topic}</h3>
                      <div class="council-sub">
                        <span>${n.session.id}</span>
                        <span>${n.session.state}</span>
                      <span>시작자 ${n.session.initiator}</span>
                        ${n.session.created_at?i`<span><${J} timestamp=${n.session.created_at} /></span>`:null}
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
                    ${n.votes.length===0?i`<div class="empty-state">기록된 표결이 아직 없습니다.</div>`:n.votes.map(s=>i`<${b$} key=${s.agent+s.timestamp} vote=${s} />`)}
                  </div>
                `:i`<div class="empty-state">이 의사결정의 상세를 아직 읽을 수 없습니다.</div>`:i`<div class="empty-state">사실 계층과 판단을 보려면 의사결정 항목을 고르세요.</div>`}
    <//>
  `}function Cr({title:e,route:t}){if(!t)return null;const n=yn(t)?t.resolved_tool:t.delegated_tool,s=yn(t)?t.target_type:null,a=yn(t)?t.target_id:null,o=yn(t)?t.reason:null,l=yn(t)?t.payload_preview:null;return i`
    <div class="governance-side-block">
      <h4>${e}</h4>
      <div class="council-sub">
        ${n?i`<span>도구 ${n}</span>`:null}
        ${"action_type"in t&&t.action_type?i`<span>액션 ${t.action_type}</span>`:null}
        ${"confirmation_state"in t&&t.confirmation_state?i`<span>${t.confirmation_state}</span>`:null}
        ${"created_at"in t&&t.created_at?i`<span><${J} timestamp=${t.created_at} /></span>`:null}
      </div>
      ${s?i`<div class="governance-side-line">대상 ${s}${a?`:${a}`:""}</div>`:null}
      ${o?i`<div class="governance-side-line">${o}</div>`:null}
      ${l?i`<pre class="council-detail governance-preview">${v$(l)}</pre>`:null}
    </div>
  `}function x$(){var c,p,m;const e=zo(),t=Ca.value,n=Aa.value,s=(t==null?void 0:t.context)??(n==null?void 0:n.context)??(e==null?void 0:e.context),a=(t==null?void 0:t.judgment)??(n==null?void 0:n.judgment),o=e==null?void 0:e.guardrail_state,l=(c=Ee.value)==null?void 0:c.judge;return i`
    <div class="governance-side-column">
      <${I} title="이유 / 가드레일" class="section" semanticId="governance.guardrail">
        ${e?i`
              <div class="governance-side-block">
                <h4>판정기</h4>
                <div class="council-sub">
                  <span>${l!=null&&l.judge_online?"온라인":"오프라인"}</span>
                  ${l!=null&&l.model_used?i`<span>${l.model_used}</span>`:null}
                  ${l!=null&&l.generated_at?i`<span><${J} timestamp=${l.generated_at} /></span>`:null}
                </div>
                ${e.judgment_summary?i`<div class="governance-summary-callout">${e.judgment_summary}</div>`:i`<div class="governance-side-line">현재 LLM 판단이 없어 사실 계층만 보여줍니다.</div>`}
                <div class="council-sub">
                  <span>신뢰도 ${_$(e.confidence)}</span>
                  ${a!=null&&a.keeper_name?i`<span>${a.keeper_name}</span>`:null}
                </div>
              </div>

              <${Cr} title="추천 경로" route=${e.recommended_action} />
              <${Cr} title="실행된 경로" route=${e.executed_route} />

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
                          onClick=${()=>Sr("confirm")}
                          disabled=${Wt.value}
                        >
                          ${Wt.value?"처리 중...":"승인"}
                        </button>
                        <button
                          class="control-btn ghost"
                          onClick=${()=>Sr("deny")}
                          disabled=${Wt.value}
                        >
                          ${Wt.value?"처리 중...":"거부"}
                        </button>
                      </div>
                    `:i`<div class="governance-side-line">이 의사결정에 대기 중인 사람 승인은 없습니다.</div>`}
              </div>
            `:i`<div class="empty-state">판단과 경로를 보려면 의사결정을 고르세요.</div>`}
      <//>

      <${I} title="맥락" class="section" semanticId="governance.context">
        ${e?i`
              <div class="governance-side-block">
                <div class="governance-chip-row">
                  ${s!=null&&s.board_post_id?i`<span class="governance-chip">board ${s.board_post_id}</span>`:null}
                  ${s!=null&&s.task_id?i`<span class="governance-chip">task ${s.task_id}</span>`:null}
                  ${s!=null&&s.operation_id?i`<span class="governance-chip">작전 ${s.operation_id}</span>`:null}
                  ${s!=null&&s.team_session_id?i`<span class="governance-chip">session ${s.team_session_id}</span>`:null}
                </div>
                ${e.related_agents.length>0?i`
                      <div class="governance-side-line">관련 에이전트</div>
                      <div class="governance-chip-row">
                        ${e.related_agents.map(u=>i`<span class="governance-chip dim">${u}</span>`)}
                      </div>
                    `:i`<div class="governance-side-line">명시적으로 연결된 맥락 기록이 없습니다.</div>`}
                ${e.evidence_refs.length>0?i`
                      <div class="governance-side-line">근거 참조</div>
                      <div class="governance-chip-row">
                        ${e.evidence_refs.map(u=>i`<span class="governance-chip">${u}</span>`)}
                      </div>
                    `:null}
              </div>
          `:i`<div class="empty-state">선택된 맥락이 없습니다.</div>`}
      <//>

      <${I} title="최근 활동" class="section" semanticId="governance.activity">
        <div class="governance-activity-list">
          ${(((p=Ee.value)==null?void 0:p.activity)??[]).slice(0,8).map(u=>i`
            <div class="governance-activity-row">
              <div class="governance-ledger-head">
                <span class="governance-badge ${qa(u.kind)}">${u.kind}</span>
                ${u.actor?i`<strong>${u.actor}</strong>`:null}
                ${u.created_at?i`<span><${J} timestamp=${u.created_at} /></span>`:null}
              </div>
              <div class="governance-ledger-body">${u.summary||u.topic||"활동이 기록되었습니다."}</div>
            </div>
          `)}
          ${(((m=Ee.value)==null?void 0:m.activity)??[]).length===0?i`<div class="empty-state">기록된 거버넌스 활동이 없습니다.</div>`:null}
        </div>
      <//>
    </div>
  `}function S$(){return ne(()=>{un()},[]),i`
    <div>
      <${be} surfaceId="governance" />
      <${g$} />
      <${$$} />
      <div class="governance-layout">
        <${h$} />
        <${k$} />
        <${x$} />
      </div>
    </div>
  `}const Ot=f(""),ti=f("ability_check"),ni=f("10"),si=f("12"),ks=f(""),xs=f("idle"),Xe=f(""),Ss=f("keeper-late"),ai=f("player"),ii=f(""),xe=f("idle"),oi=f(null),Cs=f(""),ri=f(""),li=f("player"),ci=f(""),di=f(""),ui=f(""),Mn=f("20"),pi=f("20"),mi=f(""),As=f("idle"),Bi=f(null),jc=f("overview"),vi=f("all"),_i=f("all"),fi=f("all"),C$=12e4,Fa=f(null),Ar=f(Date.now());function A$(e,t){const n=t>0?e/t*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function I$(e,t){return t>0?Math.round(e/t*100):0}const T$={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},z$={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Is(e){const t=e.trim();return t?t.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):e}function R$(e){const t=e.trim().toLowerCase();return T$[t]??"행동 선택 가중치에 영향을 주는 성향입니다."}function P$(e){const t=e.trim().toLowerCase();return z$[t]??"상황에 따라 선택되는 전술 액션입니다."}function $e(e,t,n=""){const s=e[t];return typeof s=="string"?s:n}function Le(e,t,n=0){const s=e[t];return typeof s=="number"&&Number.isFinite(s)?s:n}function Qn(e,t,n=!1){const s=e[t];return typeof s=="boolean"?s:n}const L$=new Set(["str","dex","con","int","wis","cha"]);function M$(e){const t=e.trim();if(!t)return{};let n;try{n=JSON.parse(t)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!v(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const l=a.trim();if(l){if(typeof o=="number"&&Number.isFinite(o)){s[l]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const c=Number.parseFloat(o.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function j$(e){const t=Number.parseInt(e.trim(),10);if(!Number.isFinite(t))return;const n=Math.max(1,t),s=Number.parseInt(Mn.value.trim(),10);Number.isFinite(s)&&s>n&&(Mn.value=String(n))}function Ui(e){const n=(e.actor_name??e.actor??e.actor_id??"system").trim();return n===""?"system":n}function E$(e){var n;return(((n=e.timestamp)==null?void 0:n.trim())??"")||"-"}function N$(e){jc.value=e}function Ec(e){const t=Fa.value;return t==null||t<=e}function w$(e){const t=Fa.value;return t==null||t<=e?0:Math.max(0,Math.ceil((t-e)/1e3))}function Ia(){Fa.value=null}function Nc(e){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(e)}function D$(e,t){Nc(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${e||"-"}`,`PHASE: ${t||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Fa.value=Date.now()+C$,E("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Fs(e){return Ec(e)?(E("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Hi(e,t,n){return Nc([`[위험 액션 확인] ${e}`,`ROOM: ${t||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function O$({hp:e,max:t}){const n=I$(e,t),s=A$(e,t);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function q$({stats:e}){const t=[{label:"STR",value:e.strength},{label:"DEX",value:e.dexterity},{label:"CON",value:e.constitution},{label:"INT",value:e.intelligence},{label:"WIS",value:e.wisdom},{label:"CHA",value:e.charisma}];return i`
    <div class="trpg-actor-stats">
      ${t.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function F$({keeper:e,role:t}){if(!e)return null;const n=t==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${e}
    </span>
  `}function wc({actor:e}){var p,m,u,_;const t=(p=e.archetype)==null?void 0:p.trim(),n=(m=e.persona)==null?void 0:m.trim(),s=(u=e.portrait)==null?void 0:u.trim(),a=(_=e.background)==null?void 0:_.trim(),o=e.traits??[],l=e.skills??[],c=Object.entries(e.stats_raw??{}).filter(([g,h])=>Number.isFinite(h)).filter(([g])=>!L$.has(g.toLowerCase()));return i`
    <div class="trpg-actor">
      ${s?i`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${e.name} portrait`}
              loading="lazy"
              onError=${g=>{const h=g.target;h&&(h.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${e.name}</span>
        <${mt} status=${e.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${e.role}">${e.role}</span>
        <${F$} keeper=${e.keeper} role=${e.role} />
      </div>
      ${e.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${e.stats.hp}/${e.stats.max_hp}
              ${e.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${e.stats.mp}/${e.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${e.stats.level}</span>
            </div>
            <${O$} hp=${e.stats.hp} max=${e.stats.max_hp} />
            <${q$} stats=${e.stats} />
          </div>
        `:null}
      ${t?i`<div class="trpg-actor-meta">Archetype: ${Is(t)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([g,h])=>i`
                <span class="trpg-custom-stat-chip">${Is(g)} ${h}</span>
              `)}
            </div>
          </div>
        `:null}
      ${o.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${o.map(g=>i`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Is(g)}</span>
                  <span class="trpg-annot-desc">${R$(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${l.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${l.map(g=>i`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Is(g)}</span>
                  <span class="trpg-annot-desc">${P$(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function K$({mapStr:e}){return i`<pre class="trpg-map">${e}</pre>`}function Dc({events:e,emptyLabel:t="아직 이벤트가 없습니다."}){return e.length===0?i`<div class="empty-state" style="font-size:13px">${t}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${e.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${E$(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Ui(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${J} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function B$({events:e}){const t="__none__",n=vi.value,s=_i.value,a=fi.value,o=Array.from(new Set(e.map(Ui).map(_=>_.trim()).filter(_=>_!==""))).sort((_,g)=>_.localeCompare(g)),l=Array.from(new Set(e.map(_=>(_.type??"").trim()).filter(_=>_!==""))).sort((_,g)=>_.localeCompare(g)),c=e.some(_=>(_.type??"").trim()===""),p=Array.from(new Set(e.map(_=>(_.phase??"").trim()).filter(_=>_!==""))).sort((_,g)=>_.localeCompare(g)),m=e.some(_=>(_.phase??"").trim()===""),u=e.filter(_=>{if(n!=="all"&&Ui(_)!==n)return!1;const g=(_.type??"").trim(),h=(_.phase??"").trim();if(s===t){if(g!=="")return!1}else if(s!=="all"&&g!==s)return!1;if(a===t){if(h!=="")return!1}else if(a!=="all"&&h!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${_=>{vi.value=_.target.value}}>
          <option value="all">all</option>
          ${o.map(_=>i`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${_=>{_i.value=_.target.value}}>
          <option value="all">all</option>
          ${c?i`<option value=${t}>(none)</option>`:null}
          ${l.map(_=>i`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${_=>{fi.value=_.target.value}}>
          <option value="all">all</option>
          ${m?i`<option value=${t}>(none)</option>`:null}
          ${p.map(_=>i`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{vi.value="all",_i.value="all",fi.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${u.length} / 전체 ${e.length}
      </span>
    </div>
    <${Dc} events=${u.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function U$({outcome:e}){if(!e)return null;const t=o=>{const l=o.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=e.result==="victory"?"승리":e.result==="defeat"?"패배":e.result==="draw"?"무승부":"종료",s=e.result==="victory"?"#34d399":e.result==="defeat"?"#f87171":"#9ca3af",a=[e.reason?`원인: ${t(e.reason)}`:null,e.phase?`페이즈: ${t(e.phase)}`:null,typeof e.turn=="number"?`턴: ${e.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${e.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${t(e.summary)}</div>`:null}
      ${a?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function Oc({state:e}){const t=e.history??[];return t.length===0?null:i`
    <div class="trpg-round-list">
      ${t.slice(-10).map(n=>i`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
  `}function H$({state:e,nowMs:t}){var m;const n=Ue.value||((m=e.session)==null?void 0:m.room)||"",s=xs.value,a=e.party??[];if(!a.find(u=>u.id===Ot.value)&&a.length>0){const u=a[0];u&&(Ot.value=u.id)}const l=async()=>{var _,g;if(!n){E("Room ID가 비어 있습니다.","error");return}if(!Fs(t))return;const u=((_=e.current_round)==null?void 0:_.phase)??((g=e.session)==null?void 0:g.status)??"unknown";if(Hi("라운드 실행",n,u)){xs.value="running";try{const h=await pu(n);Bi.value=h,xs.value="ok";const b=v(h.summary)?h.summary:null,$=b?Qn(b,"advanced",!1):!1,S=b?$e(b,"progress_reason",""):"";E($?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${S?`: ${S}`:""}`,$?"success":"warning"),st()}catch(h){Bi.value=null,xs.value="error";const b=h instanceof Error?h.message:"라운드 실행에 실패했습니다.";E(b,"error")}finally{Ia()}}},c=async()=>{var _,g;if(!n||!Fs(t))return;const u=((_=e.current_round)==null?void 0:_.phase)??((g=e.session)==null?void 0:g.status)??"unknown";if(Hi("턴 강제 진행",n,u))try{await _u(n),E("턴을 다음 단계로 이동했습니다.","success"),st()}catch{E("턴 이동에 실패했습니다.","error")}finally{Ia()}},p=async()=>{if(!n||!Fs(t))return;const u=Ot.value.trim();if(!u){E("먼저 Actor를 선택하세요.","warning");return}const _=Number.parseInt(ni.value,10),g=Number.parseInt(si.value,10);if(Number.isNaN(_)||Number.isNaN(g)){E("stat/dc는 숫자여야 합니다.","warning");return}const h=Number.parseInt(ks.value,10),b=ks.value.trim()===""||Number.isNaN(h)?void 0:h;try{await vu({roomId:n,actorId:u,action:ti.value.trim()||"ability_check",statValue:_,dc:g,rawD20:b}),E("주사위 판정을 기록했습니다.","success"),st()}catch{E("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${u=>{Ue.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Ot.value}
            onChange=${u=>{Ot.value=u.target.value}}
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
              value=${ti.value}
              onInput=${u=>{ti.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${ni.value}
              onInput=${u=>{ni.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${si.value}
              onInput=${u=>{si.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${ks.value}
              onInput=${u=>{ks.value=u.target.value}}
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
  `}function W$({state:e}){var a;const t=Ue.value||((a=e.session)==null?void 0:a.room)||"",n=As.value,s=async()=>{if(!t){E("Room ID가 비어 있습니다.","warning");return}const o=Cs.value.trim(),l=ri.value.trim();if(!l&&!o){E("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Mn.value.trim(),10),p=Number.parseInt(pi.value.trim(),10),m=Number.isFinite(p)?Math.max(1,p):20,u=Number.isFinite(c)?Math.max(0,Math.min(m,c)):m;let _={};try{_=M$(mi.value)}catch(g){E(g instanceof Error?g.message:"능력치 JSON 오류","error");return}As.value="spawning";try{const g=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,h=await fu(t,{actor_id:o||void 0,name:l||void 0,role:li.value,idempotencyKey:g,portrait:di.value.trim()||void 0,background:ui.value.trim()||void 0,hp:u,max_hp:m,alive:u>0,stats:Object.keys(_).length>0?_:void 0}),b=typeof h.actor_id=="string"?h.actor_id.trim():"";if(!b)throw new Error("생성 응답에 actor_id가 없습니다.");const $=ci.value.trim();$&&await gu(t,b,$),Ot.value=b,Xe.value=b,o||(Cs.value=""),As.value="ok",E(`Actor 생성 완료: ${b}`,"success"),await st()}catch(g){As.value="error",E(g instanceof Error?g.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${ri.value}
            onInput=${o=>{ri.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${li.value}
            onChange=${o=>{li.value=o.target.value}}
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
            value=${ci.value}
            onInput=${o=>{ci.value=o.target.value}}
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
              value=${Cs.value}
              onInput=${o=>{Cs.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${di.value}
              onInput=${o=>{di.value=o.target.value}}
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
              value=${Mn.value}
              onInput=${o=>{Mn.value=o.target.value}}
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
              value=${pi.value}
              onInput=${o=>{const l=o.target.value;pi.value=l,j$(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ui.value}
              onInput=${o=>{ui.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${mi.value}
              onInput=${o=>{mi.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function G$({state:e,nowMs:t}){var g;const n=Ue.value||((g=e.session)==null?void 0:g.room)||"",s=e.join_gate,a=oi.value,o=v(a)?a:null,l=(e.party??[]).filter(h=>h.role!=="dm"),c=Xe.value.trim(),p=l.some(h=>h.id===c),m=p?c:c?"__manual__":"",u=async()=>{const h=Xe.value.trim(),b=Ss.value.trim();if(!n||!h){E("Room/Actor가 필요합니다.","warning");return}xe.value="checking";try{const $=await $u(n,h,b||void 0);oi.value=$,xe.value="ok",E("참가 가능 여부를 갱신했습니다.","success")}catch($){xe.value="error";const S=$ instanceof Error?$.message:"참가 가능 여부 확인에 실패했습니다.";E(S,"error")}},_=async()=>{var C,x;const h=Xe.value.trim(),b=Ss.value.trim(),$=ii.value.trim();if(!n||!h||!b){E("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Fs(t))return;const S=((C=e.current_round)==null?void 0:C.phase)??((x=e.session)==null?void 0:x.status)??"unknown";if(Hi("Mid-Join 승인 요청",n,S)){xe.value="requesting";try{const L=await hu({room_id:n,actor_id:h,keeper_name:b,role:ai.value,...$?{name:$}:{}});oi.value=L;const T=v(L)?Qn(L,"granted",!1):!1,R=v(L)?$e(L,"reason_code",""):"";T?E("Mid-Join이 승인되었습니다.","success"):E(`Mid-Join이 거절되었습니다${R?`: ${R}`:""}`,"warning"),xe.value=T?"ok":"error",st()}catch(L){xe.value="error";const T=L instanceof Error?L.message:"Mid-Join 요청에 실패했습니다.";E(T,"error")}finally{Ia()}}};return i`
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
            onChange=${h=>{const b=h.target.value;if(b==="__manual__"){(p||!c)&&(Xe.value="");return}Xe.value=b}}
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
                value=${Xe.value}
                onInput=${h=>{Xe.value=h.target.value}}
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
            value=${Ss.value}
            onInput=${h=>{Ss.value=h.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${ai.value}
            onChange=${h=>{ai.value=h.target.value}}
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
            value=${ii.value}
            onInput=${h=>{ii.value=h.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${u} disabled=${xe.value==="checking"||xe.value==="requesting"}>
              ${xe.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${_} disabled=${xe.value==="checking"||xe.value==="requesting"}>
              ${xe.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Qn(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Le(o,"effective_score",0)}/${Le(o,"required_points",0)}</span>
            ${$e(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${$e(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function qc({state:e}){const t=[...e.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return t.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${t.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Fc({state:e}){var n;const t=e.current_round;return t?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${t.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${t.phase}</div>
      ${t.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=t.events[t.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Kc(){const e=Bi.value;if(!e)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const t=e.summary,n=v(t)?t:null,a=(Array.isArray(e.statuses)?e.statuses:[]).filter(v).slice(-8),o=e.canon_check,l=v(o)?o:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(R=>typeof R=="string").slice(0,3):[],p=l&&Array.isArray(l.violations)?l.violations.filter(R=>typeof R=="string").slice(0,3):[],m=n?Qn(n,"advanced",!1):!1,u=n?$e(n,"progress_reason",""):"",_=n?$e(n,"progress_detail",""):"",g=n?Le(n,"player_successes",0):0,h=n?Le(n,"player_required_successes",0):0,b=n?Qn(n,"dm_success",!1):!1,$=n?Le(n,"timeouts",0):0,S=n?Le(n,"unavailable",0):0,C=n?Le(n,"reprompts",0):0,x=n?Le(n,"npc_attacks",0):0,L=n?Le(n,"keeper_timeout_sec",0):0,T=n?Le(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${m?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${m?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${e.turn_before??0} → ${e.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${b?"DM ok":"DM stalled"} / players ${g}/${h}
          </span>
        </div>
        ${u?i`<div style="margin-top:4px; font-size:12px;">${u}</div>`:null}
        ${_?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${_}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${$}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${L||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${T}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(R=>{const M=$e(R,"status","unknown"),z=$e(R,"actor_id","-"),j=$e(R,"role","-"),Z=$e(R,"reason",""),ie=$e(R,"action_type",""),V=$e(R,"reply","");return i`
                <div class="trpg-round-item ${M.includes("fallback")||M.includes("timeout")?"failed":"active"}">
                  <span>${z} (${j})</span>
                  <span style="margin-left:auto; font-size:11px;">${M}</span>
                  ${ie?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${ie}</div>`:null}
                  ${Z?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${Z}</div>`:null}
                  ${V?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${V.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${$e(l,"status","unknown")}</strong>
            </div>
            ${p.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${p.map(R=>i`<div>violation: ${R}</div>`)}
                </div>`:null}
            ${c.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(R=>i`<div>warning: ${R}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function J$({state:e,nowMs:t}){var l,c,p;const n=Ue.value||((l=e.session)==null?void 0:l.room)||"",s=((c=e.current_round)==null?void 0:c.phase)??((p=e.session)==null?void 0:p.status)??"unknown",a=Ec(t),o=w$(t);return i`
    <${I} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${o}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>D$(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{Ia(),E("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function V$({active:e}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${e===n.id?"active":""}"
          role="tab"
          aria-selected=${e===n.id}
          onClick=${()=>N$(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Y$({state:e}){const t=e.party??[],n=e.story_log??[];return i`
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
          <${Dc} events=${n.slice(-20)} />
        <//>

        ${e.map?i`
            <${I} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${K$} mapStr=${e.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${I} title="현재 라운드" semanticId="lab.trpg">
          <${Fc} state=${e} />
        <//>

        <${I} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${qc} state=${e} />
        <//>

        <${I} title=${`파티 (${t.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${t.map(s=>i`<${wc} key=${s.id??s.name} actor=${s} />`)}
            ${t.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${e.history&&e.history.length>0?i`
            <${I} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
              <${Oc} state=${e} />
            <//>
          `:null}
      </div>
    </div>
  `}function X$({state:e}){const t=e.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${I} title=${`이벤트 타임라인 (${t.length})`}>
          <${B$} events=${t} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${I} title="최근 라운드 결과" semanticId="lab.trpg">
          <${Kc} />
        <//>

        <${I} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${Fc} state=${e} />
        <//>
      </div>
    </div>
  `}function Q$({state:e,nowMs:t}){const n=e.party??[];return i`
    <div>
      <${J$} state=${e} nowMs=${t} />
      <div class="trpg-layout">
        <div>
          <${I} title="조작 패널" semanticId="lab.trpg">
            <${H$} state=${e} nowMs=${t} />
          <//>

          <${I} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${W$} state=${e} />
          <//>

          <${I} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${G$} state=${e} nowMs=${t} />
          <//>

          <${I} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${Kc} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${I} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${qc} state=${e} />
          <//>

          <${I} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${wc} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${e.history&&e.history.length>0?i`
              <${I} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
                <${Oc} state=${e} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Z$(){var c,p,m,u,_;const e=il.value,t=Ti.value;if(ne(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const g=window.setInterval(()=>{Ar.value=Date.now()},1e3);return()=>{window.clearInterval(g)}},[]),t&&!e)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!e)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>st()}>Refresh</button>
      </div>
    `;const n=e.party??[],s=e.story_log??[],a=e.outcome,o=jc.value,l=Ar.value;return i`
    <div>
      <${be} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Ue.value||((c=e.session)==null?void 0:c.room)||"-"} · phase: ${((p=e.current_round)==null?void 0:p.phase)??((m=e.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>st()}>새로고침</button>
      </div>

      <${U$} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((u=e.session)==null?void 0:u.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((_=e.current_round)==null?void 0:_.round_number)??0}</div>
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

      <${V$} active=${o} />

      ${o==="overview"?i`<${Y$} state=${e} />`:o==="timeline"?i`<${X$} state=${e} />`:i`<${Q$} state=${e} nowMs=${l} />`}
    </div>
  `}const Bc=f(null),Wi=f(null),Ks=f(!1);async function eh(){if(!Ks.value){Ks.value=!0,Wi.value=null;try{Bc.value=await Ld()}catch(e){Wi.value=e instanceof Error?e.message:String(e)}finally{Ks.value=!1}}}function th(e){switch(e){case"essential":return"badge-essential";case"standard":return"badge-standard";default:return"badge-full"}}function nh({items:e,maxCount:t}){return e.length===0?i`<p class="muted">No tool calls recorded yet.</p>`:i`
    <div class="tool-bar-chart">
      ${e.map(n=>{const s=t>0?n.call_count/t*100:0;return i`
          <div class="tool-bar-row" key=${n.name}>
            <span class="tool-bar-name">${n.name}</span>
            <span class="tool-bar-tier ${th(n.tier)}">${n.tier}</span>
            <div class="tool-bar-track">
              <div class="tool-bar-fill" style=${{width:`${s}%`}} />
            </div>
            <span class="tool-bar-count">${n.call_count}</span>
          </div>
        `})}
    </div>
  `}function sh({dist:e}){const t=e.full,n=t>0?(e.essential/t*100).toFixed(1):"0",s=t>0?(e.standard/t*100).toFixed(1):"0",a=t-e.standard,o=t>0?(a/t*100).toFixed(1):"0";return i`
    <div class="tier-dist">
      <div class="tier-dist-row">
        <span class="tier-dist-label badge-essential">Essential</span>
        <span class="tier-dist-count">${e.essential}</span>
        <span class="tier-dist-pct">${n}%</span>
      </div>
      <div class="tier-dist-row">
        <span class="tier-dist-label badge-standard">Standard</span>
        <span class="tier-dist-count">${e.standard}</span>
        <span class="tier-dist-pct">${s}%</span>
      </div>
      <div class="tier-dist-row">
        <span class="tier-dist-label badge-full">Full-only</span>
        <span class="tier-dist-count">${a}</span>
        <span class="tier-dist-pct">${o}%</span>
      </div>
    </div>
  `}function ah(){const e=Bc.value,t=Ks.value,n=Wi.value;return i`
    <div class="tool-metrics">
      <div class="tool-metrics-header">
        <h3 class="tool-metrics-title">Tool Usage</h3>
        <button
          class="control-btn ghost"
          onClick=${()=>void eh()}
          disabled=${t}
        >
          ${t?"Loading...":e?"Refresh":"Load"}
        </button>
      </div>

      ${n?i`<div class="tool-metrics-error">${n}</div>`:null}

      ${e?i`
        <div class="tool-metrics-summary">
          <div class="tool-metrics-stat">
            <span class="stat-value">${e.total_calls}</span>
            <span class="stat-label">Total Calls</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${e.distinct_tools_called}</span>
            <span class="stat-label">Distinct Tools</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${e.never_called_count}</span>
            <span class="stat-label">Never Called</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${e.registered_count}</span>
            <span class="stat-label">Registered (v2)</span>
          </div>
          <div class="tool-metrics-stat">
            <span class="stat-value">${e.dispatch_v2_enabled?"ON":"OFF"}</span>
            <span class="stat-label">Dispatch v2</span>
          </div>
        </div>

        <div class="tool-metrics-sections">
          <div class="tool-metrics-section">
            <h4>Tier Distribution</h4>
            <${sh} dist=${e.tier_distribution} />
          </div>
          <div class="tool-metrics-section">
            <h4>Top 20 Tools</h4>
            <${nh}
              items=${e.top_20}
              maxCount=${e.top_20.length>0?e.top_20[0].call_count:0}
            />
          </div>
        </div>
      `:t?null:i`
        <p class="muted">Click Load to fetch tool usage statistics.</p>
      `}
    </div>
  `}function ih(){return i`
    <div>
      <${be} surfaceId="lab" />
      <${I} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${I} title="Tool Usage Metrics" class="section" semanticId="lab.tool_metrics">
        <${ah} />
      <//>

      <${I} title="TRPG" class="section" semanticId="lab.trpg">
        <${Z$} />
      <//>
    </div>
  `}const Ta=f(new Set(["broadcast","tasks","keepers","system"]));function oh(e){const t=new Set(Ta.value);t.has(e)?t.delete(e):t.add(e),Ta.value=t}const Ro=f(null);function Uc(e){Ro.value=e}function rh(e){return e.kind==="board"?"broadcast":e.kind==="tasks"?"tasks":e.kind==="keepers"?"keepers":"system"}const lh=Ie(()=>{const e=Ta.value;return Us.value.filter(t=>e.has(rh(t)))}),ch=12e4,dh=Ie(()=>{const e=cl.value,t=Date.now();return Ge.value.map(n=>{const s=n.name.trim().toLowerCase(),a=e.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?o=t-new Date(l).getTime()>ch?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),uh=Ie(()=>{const e=cl.value;return Ge.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle").map(t=>{const n=t.name.trim().toLowerCase(),s=e.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:t.name,emoji:t.emoji??"",koreanName:t.koreanName??null,currentTask:t.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((t,n)=>{const s={hot:0,normal:1,calm:2};return s[t.pressure]-s[n.pressure]})});function Ir(e){return e.kind==="board"?"live-event-broadcast":e.kind==="tasks"?"live-event-task":e.kind==="keepers"?"live-event-keeper":"live-event-system"}function ph(e){const t=e.eventType;return t==="broadcast"?"broadcast":t==="agent_joined"?"joined":t==="agent_left"?"left":t==="task_update"?"task":t==="board_post"?"post":t==="board_comment"?"comment":t==="keeper_heartbeat"?"heartbeat":t==="keeper_handoff"?"handoff":t==="keeper_compaction"?"compact":t==="keeper_guardrail"?"guardrail":e.kind==="board"?"board":e.kind==="tasks"?"task":e.kind==="keepers"?"keeper":"system"}function mh(e){switch(e){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function vh(){const e=dh.value,t=Ro.value;return e.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${e.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${mh(n.state)} ${t===n.name?"pulse-selected":""}"
          onClick=${()=>Uc(t===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const _h=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function fh(){const e=Ta.value;return i`
    <div class="activity-filter-bar">
      ${_h.map(t=>i`
        <button
          key=${t.kind}
          class="activity-filter-btn ${t.cssClass} ${e.has(t.kind)?"active":""}"
          onClick=${()=>oh(t.kind)}
        >
          ${t.label}
        </button>
      `)}
    </div>
  `}function gh(){const e=lh.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${e.length} events</span>
      </div>
      <${fh} />
      <div class="activity-stream-list">
        ${e.length===0?i`<div class="activity-empty">No events matching filters</div>`:e.map((t,n)=>i`
            <div
              key=${`${t.timestamp}-${n}`}
              class="activity-item ${Ir(t)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${Ir(t)}">${ph(t)}</span>
                <span class="activity-agent">${t.agent}</span>
                <span class="activity-time">${Ml(t.timestamp)}</span>
              </div>
              <div class="activity-item-text">${t.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function $h(e){switch(e){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function hh(e){switch(e){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function yh(){const e=uh.value,t=Ro.value;return i`
    <div class="focus-sidebar">
      <div class="focus-sidebar-head">
        <h3>Agents</h3>
        <span class="focus-count">${e.length} active</span>
      </div>
      <div class="focus-sidebar-list">
        ${e.length===0?i`<div class="focus-empty">No active agents</div>`:e.map(n=>i`
            <div
              key=${n.name}
              class="focus-agent-card ${t===n.name?"focus-agent-selected":""}"
              onClick=${()=>Uc(t===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${$h(n.pressure)}">
                  ${hh(n.pressure)}
                  ${n.assignedCount>0?i` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?i`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?i`<span class="focus-activity-text">${n.lastActivityText}</span>`:i`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?i`<${J} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function bh(){const e=rt.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>라이브 모니터</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${e?"connected":"disconnected"}"></span>
            ${e?"연결됨":"오프라인"}
          </span>
          <span class="live-stat">에이전트 ${Ge.value.length}</span>
          <span class="live-stat">이벤트 ${za.value}</span>
        </div>
      </div>

      <${vh} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${gh} />
        </div>
        <div class="live-panel-side">
          <${yh} />
        </div>
      </div>
    </div>
  `}const Tr=[{id:"observe",label:"관찰",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"맥락",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"개입",description:"개입과 운영 기준 지휘를 실행하는 표면"},{id:"lab",label:"실험",description:"실험적 기능은 메인 operator console 밖으로 분리"}],Gi=[{id:"mission",label:"상황판",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"proof",label:"근거",icon:"🔍",group:"observe",description:"협업, 대화, 도구, 근거 기록을 증명 중심으로 읽는 표면"},{id:"execution",label:"실행",icon:"🤖",group:"observe",description:"워커, 태스크, 키퍼 연속성을 분리해서 보는 실행 표면"},{id:"live",label:"라이브",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"계획",icon:"🎯",group:"observe",description:"목표, 지표 루프, 백로그 압력을 읽는 계획 표면"},{id:"memory",label:"메모리",icon:"💬",group:"context",description:"게시글과 댓글로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"거버넌스",icon:"⚖️",group:"context",description:"토론과 표결을 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"개입",icon:"🎮",group:"act",description:"룸, 세션, 키퍼 액션을 실행하는 개입 화면"},{id:"command",label:"지휘",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"실험",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 표면을 메인 콘솔 밖에서 다룹니다"}],Ts=f(!1);function kh(){const e=rt.value;return i`
    <div class="connection-status ${e?"connected":"disconnected"}">
      <span class="status-dot ${e?"connected":"disconnected"}"></span>
      <span class="status-text">${e?"연결됨":"재연결 중..."}</span>
      <span class="event-count">이벤트 ${za.value}</span>
    </div>
  `}function Hc(e){const t=e==null?void 0:e.trim();return t?t.length>10?t.slice(0,10):t:"커밋 정보 없음"}function Ae(e,t){return t==="live"?"가동 중":t==="quiet"?"조용함":t==="starting"?"기동 중":t==="idle"?e==="guardian"?"유휴":"대기 중":"비활성"}function xh(){const e=te.value,t=e==null?void 0:e.build,n=t?`v${t.release_version} · ${Hc(t.commit)}`:e!=null&&e.version?`v${e.version} · 커밋 정보 없음`:"버전 정보 없음";return i`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${Ts.value}
        onClick=${()=>{Ts.value=!Ts.value}}
      >
        서버 빌드 · ${n}
      </button>
      ${Ts.value?i`
            <div class="build-badge-panel">
              <div class="build-badge-row">
                <span>릴리즈</span>
                <strong>${(t==null?void 0:t.release_version)??(e==null?void 0:e.version)??"unknown"}</strong>
              </div>
              <div class="build-badge-row">
                <span>커밋</span>
                <strong>${(t==null?void 0:t.commit)??"커밋 정보 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>서버 시작</span>
                <strong>${t!=null&&t.started_at?i`<${J} timestamp=${t.started_at} />`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof(t==null?void 0:t.uptime_seconds)=="number"?`${t.uptime_seconds}s`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${e!=null&&e.generated_at?i`<${J} timestamp=${e.generated_at} />`:"알 수 없음"}</strong>
              </div>
            </div>
          `:null}
    </div>
  `}function Ji(e){e==="command"&&(Kt(),en(),(G.value==="swarm"||G.value==="warroom"||G.value==="orchestra")&&Qe(),G.value==="orchestra"&&Tt(),G.value==="warroom"&&ye()),e==="mission"&&(kl(),Ys()),e==="proof"&&Jl(F.value.params.session_id,F.value.params.operation_id),e==="execution"&&Ct(),e==="intervene"&&(ye(),Pt()),e==="memory"&&nt(),e==="planning"&&no(),e==="lab"&&st()}function Se(e,t){return i`
    <div class="build-badge-row">
      <span>${e}</span>
      <strong>${t}</strong>
    </div>
  `}function zs(e,t,n,s,a){return i`
    <div style="padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
      <div class="rail-card-head" style="margin:0;">
        <h3 style="font-size:12px;">${e}</h3>
        <span class="rail-section-chip ${n}">${t}</span>
      </div>
      ${s}
      ${a?i`<div class="rail-build-hint">${a}</div>`:null}
    </div>
  `}function Sh({currentTab:e}){var p,m,u,_,g,h,b,$,S,C;const t=rt.value,n=(p=te.value)==null?void 0:p.build,s=(m=te.value)==null?void 0:m.lodge,a=(u=te.value)==null?void 0:u.gardener,o=(_=te.value)==null?void 0:_.guardian,l=(g=te.value)==null?void 0:g.sentinel,c=[];if(s&&c.push(zs("Lodge",s.enabled?Ae("lodge",s.quiet_active?"quiet":"live"):Ae("lodge","disabled"),s.enabled?s.quiet_active?"warn":"ok":"bad",[Se("틱",s.total_ticks??0),Se("체크인",s.total_checkins??0),Se("최근 결과",((h=s.last_tick_result)==null?void 0:h.activity_report)??s.last_skip_reason??"없음")])),a&&c.push(zs("Gardener",a.alive?Ae("gardener","live"):a.enabled?Ae("gardener","starting"):Ae("gardener","disabled"),a.alive?"ok":a.enabled?"warn":"bad",[Se("최근 tick",a.last_tick_completed_at?i`<${J} timestamp=${a.last_tick_completed_at} />`:"기록 없음"),Se("판단",`${a.last_intervention??"없음"} · ${a.last_decision_source??"없음"}`),Se("백로그",`미할당 ${((b=a.health_summary)==null?void 0:b.todo_count)??0} · P1/2 ${(($=a.health_summary)==null?void 0:$.high_priority_todo)??0}`)],a.last_reason??a.last_error??void 0)),o){const x=o.masc_loops_running||o.lodge_loop_started||o.lodge_running;c.push(zs("Guardian",x?Ae("guardian","live"):o.enabled?Ae("guardian","idle"):Ae("guardian","disabled"),x?"ok":o.enabled?"warn":"bad",[Se("모드",o.mode??"알 수 없음"),Se("루프",`zombie ${o.zombie_loop_running?"on":"off"} · gc ${o.gc_loop_running?"on":"off"}`),Se("소유자",o.runtime_owner??"없음")],((S=o.last_lodge_result)==null?void 0:S.message)??o.last_gc_result??o.last_zombie_result??void 0))}return l&&c.push(zs("Sentinel",l.started?Ae("sentinel","live"):l.enabled?Ae("sentinel","starting"):Ae("sentinel","disabled"),l.started?"ok":l.enabled?"warn":"bad",[Se("에이전트",l.agent_name??"sentinel"),Se("소비자",((C=l.consumers)==null?void 0:C.length)??0),Se("가디언 소유자",l.guardian_runtime_owner??"없음")],l.llm_enabled===!0?"LLM 기반 housekeeping resident":void 0)),i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${O} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${t?"ok":"bad"}">${t?"연결됨":"오프라인"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>에이전트</span>
          <strong>${Ge.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>키퍼</span>
          <strong>${pt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>태스크</span>
          <strong>${et.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>이벤트</span>
          <strong>${za.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{es(),ml(),Ji(e)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>se("intervene")}>
          개입 열기
        </button>
      </div>
      ${n?i`<div class="rail-build-hint">서버 빌드 · v${n.release_version} · ${Hc(n.commit)}</div>`:null}
      ${c.length>0?i`
            <div style="margin-top:12px; display:flex; flex-direction:column; gap:10px;">
              ${c}
            </div>
          `:null}
    </section>
  `}function Ch(){const e=_e.value,t=(e==null?void 0:e.pending_confirms.length)??0,n=(e==null?void 0:e.sessions.length)??0,s=(e==null?void 0:e.keepers.length)??0;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${O} panelId="side_rail.quick_actions" compact=${!0} />
        <span class="rail-section-chip ${t>0?"warn":"ok"}">${t>0?"확인 필요":"정상"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>확인 대기</span>
          <strong>${t}</strong>
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
          onClick=${()=>{ye(),Pt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>se("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function Ah(){const e=F.value.tab,t=Gi.find(s=>s.id===e),n=Tr.find(s=>s.id===(t==null?void 0:t.group));return i`
    <aside class="dashboard-rail">
      <${be} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${O} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${Tr.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${Gi.filter(a=>a.group===s.id).map(a=>i`
                  <button
                    class="rail-tab-btn ${e===a.id?"active":""}"
                    onClick=${()=>se(a.id)}
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
          <strong>${(t==null?void 0:t.label)??e}</strong>
          <p>${(t==null?void 0:t.description)??"운영 화면"}</p>
        </div>
      </section>

      <${Sh} currentTab=${e} />
      <${Ch} />
    </aside>
  `}function Ih(){switch(F.value.tab){case"mission":return i`<${er} />`;case"proof":return i`<${sf} />`;case"execution":return i`<${Yg} />`;case"live":return i`<${bh} />`;case"memory":return i`<${Og} />`;case"governance":return i`<${S$} />`;case"planning":return i`<${u$} />`;case"intervene":return i`<${Ag} />`;case"command":return i`<${kg} />`;case"lab":return i`<${ih} />`;default:return i`<${er} />`}}function Th(){ne(()=>{nd(),Nr(),vl(),Ct(),ml(),kl();const n=Ip();return Tp(),()=>{dd(),n(),zp()}},[]),ne(()=>{const n=setInterval(()=>{Ji(F.value.tab)},15e3);return()=>{clearInterval(n)}},[]),ne(()=>{Ji(F.value.tab)},[F.value.tab]);const e=F.value.tab,t=Gi.find(n=>n.id===e);return i`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC 대시보드
            <${xh} />
          </h1>
          <p class="header-subtitle">${(t==null?void 0:t.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${kh} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${Ah} />
        <main class="dashboard-main">
          ${Ii.value&&!rt.value?i`<div class="loading-indicator">대시보드 불러오는 중...</div>`:i`<${Ih} />`}
        </main>
      </div>

      <${lv} />
      <${Tm} />
      <${ym} />
    </div>
  `}const zr=document.getElementById("app");zr&&Xc(i`<${Th} />`,zr);export{$v as _};
