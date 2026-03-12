var _d=Object.defineProperty;var fd=(e,t,n)=>t in e?_d(e,t,{enumerable:!0,configurable:!0,writable:!0,value:n}):e[t]=n;var Nt=(e,t,n)=>fd(e,typeof t!="symbol"?t+"":t,n);import{e as gd,_ as $d,c as g,b as ze,y as se,d as Yr,A as hd,G as yd}from"./vendor-kuFK4-oj.js";(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const l of i.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var o=gd.bind($d);const bd=["mission","proof","execution","tools","live","memory","governance","planning","intervene","command","lab"],Xr={tab:"mission",params:{},postId:null};function Xi(e){return!!e&&bd.includes(e)}function Lo(e){try{return decodeURIComponent(e)}catch{return e}}function zo(e){const t={};return e&&new URLSearchParams(e).forEach((s,a)=>{t[a]=s}),t}function kd(e){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Zr(e,t){if(e[0]==="chains"){const i={...t,surface:"chains"};return e[1]==="operation"&&e[2]&&(i.operation=Lo(e[2])),{tab:"command",params:i,postId:null}}if(e[0]==="lab"){const i={...t};return e[1]&&(i.surface=Lo(e[1])),{tab:"lab",params:i,postId:null}}const n=e[0],s=t.tab;return{tab:Xi(n)?n:Xi(s)?s:"mission",params:t,postId:null}}function Ys(e){const t=(e||"").replace(/^#/,"").trim();if(!t)return Xr;const n=Lo(t);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=zo(a),l=kd(s);return Zr(l,i)}function xd(e,t){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Xr,params:zo(t.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=zo(t.replace(/^\?/,""));return Zr(s,a)}function el(e){const t=e.tab==="lab"&&e.params.surface?`lab/${encodeURIComponent(e.params.surface)}`:e.tab,n=Object.entries(e.params).filter(([a])=>!(a==="tab"||e.tab==="lab"&&a==="surface"));if(n.length===0)return`#${t}`;const s=new URLSearchParams(n);return`#${t}?${s.toString()}`}const D=g(Ys(window.location.hash));window.addEventListener("hashchange",()=>{D.value=Ys(window.location.hash)});function ie(e,t){const n={tab:e,params:t??{}};window.location.hash=el(n)}function Sd(e){window.location.hash=`#memory?post=${encodeURIComponent(e)}`}function Cd(){if(window.location.hash&&window.location.hash!=="#"){D.value=Ys(window.location.hash);return}const e=xd(window.location.pathname,window.location.search);if(e){D.value=e;const t=el(e);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${t}`);return}window.location.hash="#mission",D.value=Ys(window.location.hash)}const Zi="masc_dashboard_sse_session_id",Ad=1e3,Td=15e3,dt=g(!1),wa=g(0),tl=g(null),Xs=g([]);function Id(){let e=sessionStorage.getItem(Zi);return e||(e=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Zi,e)),e}const Rd=200;function Ld(e,t,n="system",s={}){const a={agent:e,text:t,timestamp:Date.now(),kind:n,...s};Xs.value=[a,...Xs.value].slice(0,Rd)}function Po(e,t=88){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-3)}...`:n:void 0}function er(e,t){const n=Po(t);return n?`${e}: ${n}`:`New ${e.toLowerCase()}`}function Te(e,t,n,s,a={}){Ld(e,t,n,{eventType:s,...a})}let Ne=null,Jt=null,Mo=0;function nl(){Jt&&(clearTimeout(Jt),Jt=null)}function zd(){if(Jt)return;Mo++;const e=Math.min(Mo,5),t=Math.min(Td,Ad*Math.pow(2,e));Jt=setTimeout(()=>{Jt=null,sl()},t)}function sl(){nl(),Ne&&(Ne.close(),Ne=null);const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");n&&t.set("agent",n),s&&t.set("token",s),t.set("session_id",Id());const a=t.toString()?`/sse?${t.toString()}`:"/sse",i=new EventSource(a);Ne=i,i.onopen=()=>{Ne===i&&(Mo=0,dt.value=!0)},i.onerror=()=>{Ne===i&&(dt.value=!1,i.close(),Ne=null,zd())},i.onmessage=l=>{try{const c=JSON.parse(l.data);wa.value++,tl.value=c,Pd(c)}catch{}}}function Pd(e){const t=e.type,n=e.agent??e.author??e.from??e.from_agent??"";switch(t){case"agent_joined":Te(n,"Joined","system","agent_joined");break;case"agent_left":Te(n,"Left","system","agent_left");break;case"broadcast":Te(n,`${(e.message??e.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Te(n,`Task: ${e.task_id??""} -> ${e.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Te(n,er("Post",e.content??e.message),"board","board_post",{author:e.author??n,preview:Po(e.content??e.message),postId:e.post_id});break;case"board_comment":case"masc/board_comment":Te(n,er("Comment",e.content??e.message),"board","board_comment",{author:e.author??n,preview:Po(e.content??e.message),postId:e.post_id});break;case"keeper_heartbeat":Te(e.name??n,`Heartbeat gen=${e.generation??"?"} ctx=${e.context_ratio!=null?Math.round(e.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Te(e.name??n,`Handoff gen ${e.from_generation??"?"} -> ${e.to_generation??"?"} (${e.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Te(e.name??n,`Compaction saved ${e.saved_tokens??"?"} tokens (${e.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Te(e.name??n,`Guardrail: ${e.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Te(n,t,"system","unknown")}}function Md(){nl(),Ne&&(Ne.close(),Ne=null),dt.value=!1}function v(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function r(e){return typeof e=="string"&&e.trim()!==""?e.trim():void 0}function d(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function j(e){return typeof e=="boolean"?e:void 0}function F(e){return Array.isArray(e)?e.map(t=>typeof t=="string"?t.trim():"").filter(Boolean):[]}function ve(e,t=[]){if(Array.isArray(e))return e;if(!v(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function re(e){if(typeof e=="string"&&e.trim()!=="")return e;if(!(typeof e!="number"||!Number.isFinite(e)||e<=0))return new Date(e*1e3).toISOString()}function al(){return new URLSearchParams(window.location.search)}const jd="masc_dashboard_agent_name";function Ed(){var e;try{return((e=localStorage.getItem(jd))==null?void 0:e.trim())||null}catch{return null}}function ol(){const e=al(),t={},n=e.get("token"),s=Ed(),a=e.get("agent")??e.get("agent_name")??s;return n&&(t.Authorization=`Bearer ${n}`),a&&(t["X-MASC-Agent"]=a),t}function il(){return{...ol(),"Content-Type":"application/json"}}const Nd=15e3,ui=3e4,Dd=6e4,tr=new Set([408,425,429,500,502,503,504]);class as extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);Nt(this,"method");Nt(this,"path");Nt(this,"status");Nt(this,"statusText");Nt(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function pi(e,t,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(e,{...t,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const l=typeof t.method=="string"?t.method.toUpperCase():"GET";throw new as({method:l,path:e,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function wd(){var t,n;const e=al();return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function ne(e){const t=await pi(e,{headers:ol()},Nd);if(!t.ok)throw new as({method:"GET",path:e,status:t.status,statusText:t.statusText});return t.json()}function Od(e){return new Promise(t=>setTimeout(t,e))}function qd(e){const t=e.match(/\b(\d{3})\b/);if(!t)return null;const n=t[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function Fd(e){if(e instanceof as)return e.timeout||typeof e.status=="number"&&tr.has(e.status);if(!(e instanceof Error))return!1;if(/timeout after \d+ms/i.test(e.message))return!0;const t=qd(e.message);return t!==null&&tr.has(t)}async function Oa(e,t,n=2){let s=0;for(;;)try{return await t()}catch(a){if(!Fd(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${e} failed (attempt ${s+1}), retrying in ${i}ms`,a),await Od(i),s+=1}}async function Fe(e,t,n,s=ui){const a=await pi(e,{method:"POST",headers:{...il(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new as({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.json()}async function Kd(e,t,n,s=ui){const a=await pi(e,{method:"POST",headers:{...il(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new as({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.text()}function Ud(e){const t=e.split(`
`).find(s=>s.startsWith("data: ")),n=t?t.slice(6).trim():e.trim();return JSON.parse(n)}function Hd(e){var t,n,s,a,i,l,c;if((t=e.error)!=null&&t.message)throw new Error(e.error.message);if((n=e.result)!=null&&n.isError){const p=((a=(s=e.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(p)}return((c=(l=(i=e.result)==null?void 0:i.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function vt(e,t){const n=await Kd("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:e,arguments:t},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Dd),s=Ud(n);return Hd(s)}function Bd(){return ne("/api/v1/dashboard/shell")}function Wd(){return ne("/api/v1/dashboard/execution")}function Gd(e,t){const n=new URLSearchParams;return n.set("sort_by",e),t!=null&&t.excludeSystem&&n.set("exclude_system","true"),ne(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function Jd(){return Oa("fetchDashboardGovernance",async()=>{const e=await ne("/api/v1/dashboard/governance"),t=Array.isArray(e.items)?e.items.map(i=>mu(i)).filter(i=>i!==null):[],n=Array.isArray(e.pending_actions)?e.pending_actions.map(i=>cl(i)).filter(i=>i!==null):[],s=t.filter(i=>i.kind==="debate").map(i=>({id:i.id,topic:i.topic,status:i.status,argument_count:i.evidence_refs.length,created_at:i.last_activity_at??void 0})),a=t.filter(i=>i.kind==="consensus").map(i=>({id:i.id,topic:i.topic,initiator:i.related_agents[0]||"system",votes:i.votes??0,quorum:i.quorum??0,threshold:i.threshold,state:i.status,created_at:i.last_activity_at??void 0}));return{generated_at:de(e.generated_at)??void 0,summary:v(e.summary)?{debates:_e(e.summary.debates)??void 0,voting_sessions:_e(e.summary.voting_sessions)??void 0,debates_open:_e(e.summary.debates_open)??void 0,sessions_active:_e(e.summary.sessions_active)??void 0,sessions_without_quorum:_e(e.summary.sessions_without_quorum)??void 0,ready_to_execute:_e(e.summary.ready_to_execute)??void 0,oldest_open_debate_age_s:typeof e.summary.oldest_open_debate_age_s=="number"?e.summary.oldest_open_debate_age_s:null,last_activity_age_s:typeof e.summary.last_activity_age_s=="number"?e.summary.last_activity_age_s:null,judge_online:typeof e.summary.judge_online=="boolean"?e.summary.judge_online:void 0,judge_last_seen_at:de(e.summary.judge_last_seen_at)}:void 0,debates:s,sessions:a,items:t,activity:Array.isArray(e.activity)?e.activity.map(i=>vu(i)).filter(i=>i!==null):[],judge:_u(e.judge),pending_actions:n}})}function Vd(){return ne("/api/v1/dashboard/semantics")}function Qd(){return ne("/api/v1/dashboard/mission")}function Yd(e){const t=`?session_id=${encodeURIComponent(e)}`;return ne(`/api/v1/dashboard/session${t}`)}function Xd(e=!1){return ne(`/api/v1/dashboard/mission/briefing${e?"?force=1":""}`)}function Zd(e,t){const n=new URLSearchParams;e&&n.set("session_id",e),t&&n.set("operation_id",t);const s=n.toString();return ne(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function eu(){return ne("/api/v1/dashboard/planning")}function tu(){return ne("/api/v1/tool-metrics")}function nu(){return ne("/api/v1/dashboard/tools")}function su(){return ne("/api/v1/operator")}function rl(e={}){const t=new URLSearchParams;e.targetType&&t.set("target_type",e.targetType),e.targetId&&t.set("target_id",e.targetId),e.includeWorkers!=null&&t.set("include_workers",e.includeWorkers?"true":"false");const n=t.toString();return ne(`/api/v1/operator/digest${n?`?${n}`:""}`)}function au(){return ne("/api/v1/command-plane")}function ou(){return ne("/api/v1/command-plane/summary")}function iu(){return ne("/api/v1/chains/summary")}function ru(e){return ne(`/api/v1/chains/runs/${encodeURIComponent(e)}`)}function lu(){return ne("/api/v1/command-plane/help")}function cu(e,t){const n=new URLSearchParams;e&&n.set("run_id",e),t&&n.set("operation_id",t);const s=n.toString();return ne(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function du(e,t){const n=new URLSearchParams;e&&n.set("run_id",e),t&&n.set("operation_id",t);const s=n.toString();return ne(`/api/v1/command-plane/orchestra${s?`?${s}`:""}`)}function uu(e,t){return Fe(e,t)}function pu(e){switch(e.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"swarm_run_continue":return 6e4;case"swarm_run_rerun":return 12e4;case"swarm_run_abandon":return 3e4;case"lodge_tick":return 45e3;default:return ui}}function qa(e){return Fe("/api/v1/operator/action",e,void 0,pu(e))}function ll(e,t,n="confirm"){return Fe("/api/v1/operator/confirm",{actor:e,confirm_token:t,decision:n})}function Os(e){if(typeof e=="string"&&e.trim())return e;if(typeof e!="number"||Number.isNaN(e))return new Date().toISOString();const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}function de(e){if(typeof e=="string"){const t=e.trim();return t||null}if(typeof e=="number"&&Number.isFinite(e)){const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}return null}function O(e){if(typeof e!="string")return null;const t=e.trim();return t||null}function cl(e){if(!v(e))return null;const t=k(e.confirm_token??e.token,"").trim();return t?{confirm_token:t,actor:O(e.actor)??void 0,action_type:O(e.action_type)??void 0,target_type:O(e.target_type)??void 0,target_id:O(e.target_id),delegated_tool:O(e.delegated_tool)??void 0,created_at:de(e.created_at)??void 0,preview:e.preview}:null}function mi(e){return v(e)?{board_post_id:O(e.board_post_id),task_id:O(e.task_id),operation_id:O(e.operation_id),team_session_id:O(e.team_session_id)}:{}}function dl(e){if(!v(e))return null;const t=O(e.action_kind),n=O(e.resolved_tool),s=O(e.target_type),a=O(e.target_id),i=O(e.reason);return!t&&!n&&!s&&!i?null:{action_kind:t??void 0,resolved_tool:n,target_type:s,target_id:a,reason:i??void 0,payload_preview:e.payload_preview}}function ul(e){if(!v(e))return null;const t=O(e.action_type),n=O(e.delegated_tool),s=O(e.confirmation_state),a=de(e.created_at);return!t&&!n&&!s&&!a?null:{action_type:t??void 0,delegated_tool:n,confirmation_state:s??void 0,created_at:a}}function pl(e){if(!v(e))return null;const t=cl(e.pending_confirm),n=O(e.pending_confirm_token)??(t==null?void 0:t.confirm_token)??null;return{requires_human_gate:typeof e.requires_human_gate=="boolean"?e.requires_human_gate:void 0,pending_confirm:t,pending_confirm_token:n,ready_to_execute:typeof e.ready_to_execute=="boolean"?e.ready_to_execute:void 0}}function ml(e){if(!v(e))return null;const t=O(e.summary),n=O(e.target_id);return!t&&!n?null:{judgment_id:O(e.judgment_id)??void 0,target_kind:O(e.target_kind)??void 0,target_id:n??void 0,status:O(e.status)??void 0,summary:t??void 0,confidence:typeof e.confidence=="number"?e.confidence:null,generated_at:de(e.generated_at),expires_at:de(e.expires_at),model_used:O(e.model_used),keeper_name:O(e.keeper_name),evidence_refs:De(e.evidence_refs),recommended_action:dl(e.recommended_action),guardrail_state:pl(e.guardrail_state),executed_route:ul(e.executed_route)}}function mu(e){if(!v(e))return null;const t=k(e.id,"").trim(),n=k(e.topic,"").trim();if(!t||!n)return null;const s=mi(e.context);return{kind:k(e.kind,"debate"),id:t,topic:n,status:k(e.status??e.state,"open"),last_activity_at:de(e.last_activity_at),truth_summary:O(e.truth_summary)??void 0,judgment_summary:O(e.judgment_summary),confidence:typeof e.confidence=="number"?e.confidence:null,related_agents:De(e.related_agents),context:s,linked_board_post_id:O(e.linked_board_post_id)??s.board_post_id??null,linked_task_id:O(e.linked_task_id)??s.task_id??null,linked_operation_id:O(e.linked_operation_id)??s.operation_id??null,linked_session_id:O(e.linked_session_id)??s.team_session_id??null,recommended_action:dl(e.recommended_action),executed_route:ul(e.executed_route),guardrail_state:pl(e.guardrail_state),evidence_refs:De(e.evidence_refs),approve_count:_e(e.approve_count),reject_count:_e(e.reject_count),abstain_count:_e(e.abstain_count),votes:_e(e.votes),quorum:_e(e.quorum),threshold:typeof e.threshold=="number"?e.threshold:void 0}}function vu(e){if(!v(e))return null;const t=k(e.kind,"").trim();return t?{kind:t,item_kind:O(e.item_kind)??void 0,item_id:O(e.item_id)??void 0,topic:O(e.topic)??void 0,created_at:de(e.created_at),summary:O(e.summary)??void 0,actor:O(e.actor),index:_e(e.index),decision:O(e.decision)}:null}function _u(e){if(v(e))return{judge_online:typeof e.judge_online=="boolean"?e.judge_online:void 0,refreshing:typeof e.refreshing=="boolean"?e.refreshing:void 0,generated_at:de(e.generated_at),expires_at:de(e.expires_at),model_used:O(e.model_used),keeper_name:O(e.keeper_name),last_error:O(e.last_error)}}function fu(e){var a;const t=e.trim(),s=((a=(t.startsWith("[flair:")?t.replace(/^\[flair:[^\]]+\]\s*/i,""):t).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function gu(e){if(!v(e))return null;const t=k(e.source,"").trim()||null,n=k(e.state_block,"").trim()||null;return!t&&!n?null:{source:t,state_block:n}}function $u(e){if(!v(e))return null;const t=k(e.id,"").trim(),n=k(e.author,"").trim(),s=k(e.body,"").trim()||k(e.content,"").trim(),a=s;if(!t||!n)return null;const i=H(e.score,0),l=H(e.votes_up,0),c=H(e.votes_down,0),p=H(e.votes,i||l-c),m=H(e.comment_count,H(e.reply_count,0)),u=(()=>{const S=e.flair;if(typeof S=="string"&&S.trim())return S.trim();if(v(S)){const $=k(S.name,"").trim();if($)return $}return k(e.flair_name,"").trim()||void 0})(),f=k(e.created_at_iso,"").trim()||Os(e.created_at),_=k(e.updated_at_iso,"").trim()||(e.updated_at!==void 0?Os(e.updated_at):f),b=k(e.title,"").trim()||fu(s),C=Array.isArray(e.tags)?e.tags.filter(S=>typeof S=="string"&&S.trim()!==""):[];return{id:t,author:n,post_kind:(()=>{const S=k(e.post_kind,"").trim().toLowerCase();return S==="automation"||S==="system"||S==="human"?S:void 0})(),title:b,body:s,content:a,meta:gu(e.meta),tags:C,votes:p,vote_balance:i,comment_count:m,created_at:f,updated_at:_,flair:u,hearth:k(e.hearth,"").trim()||null,visibility:k(e.visibility,"").trim()||void 0,expires_at:k(e.expires_at_iso,"").trim()||(e.expires_at!==void 0&&e.expires_at!==0?Os(e.expires_at):"")||null,hearth_count:H(e.hearth_count,0)}}function hu(e){if(!v(e))return null;const t=k(e.id,"").trim(),n=k(e.post_id,"").trim(),s=k(e.author,"").trim();return!t||!s?null:{id:t,post_id:n,author:s,content:k(e.content,""),created_at:Os(e.created_at)}}async function yu(e){return Oa("fetchBoardPost",async()=>{const t=await ne(`/api/v1/board/${e}?format=flat`),n=v(t.post)?t.post:t,s=$u(n)??{id:e,author:"unknown",post_kind:"human",title:"Post",body:"",content:"",meta:null,tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},i=(Array.isArray(t.comments)?t.comments:[]).map(hu).filter(l=>l!==null);return{...s,comments:i}})}function vl(e,t){return Fe("/api/v1/tools/masc_board_vote",{post_id:e,direction:t,vote:t,voter:wd()})}function bu(e,t,n){return Fe("/api/v1/tools/masc_board_comment",{post_id:e,author:t,content:n})}function ku(e){const t=k(e,"").trim().toLowerCase();if(t==="win"||t==="won"||t==="victory")return"victory";if(t==="lose"||t==="lost"||t==="defeat")return"defeat";if(t==="draw"||t==="stalemate"||t==="tie")return"draw"}function ue(...e){for(const t of e){const n=k(t,"");if(n.trim())return n.trim()}return""}function nr(e){const t=ku(ue(e.outcome,e.result,e.result_code));if(!t)return;const n=ue(e.reason,e.reason_code,e.description,e.detail),s=ue(e.summary,e.summary_ko,e.summary_en,e.note),a=ue(e.details,e.details_text,e.text,e.note),i=ue(e.winner,e.winner_name,e.actor_winner,e.winner_actor),l=ue(e.winner_actor_id,e.winner_actor,e.actor_winner_id),c=ue(e.raw_reason,e.raw_reason_code,e.error_message),p=(()=>{const f=e.evidence??e.evidence_ids??e.supporting_events??e.event_ids??[];return typeof f=="string"?[f]:Array.isArray(f)?f.map(_=>{if(typeof _=="string")return _.trim();if(v(_)){const h=k(_.summary,"").trim();if(h)return h;const b=k(_.text,"").trim();if(b)return b;const C=k(_.type,"").trim();return C||k(_.event_id,"").trim()}return""}).filter(_=>_.length>0):[]})(),m=(()=>{const f=H(e.turn,Number.NaN);if(Number.isFinite(f))return f;const _=H(e.turn_number,Number.NaN);if(Number.isFinite(_))return _;const h=H(e.current_turn,Number.NaN);if(Number.isFinite(h))return h;const b=H(e.round,Number.NaN);return Number.isFinite(b)?b:void 0})(),u=ue(e.phase,e.phase_name,e.current_phase,e.phase_id);return{result:t,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:l||void 0,evidence:p.length>0?p:void 0,raw_reason:c||void 0,turn:m,phase:u||void 0}}function xu(e,t){const n=v(e.state)?e.state:{};if(k(n.status,"active").toLowerCase()!=="ended")return;const a=[...t].reverse().find(l=>v(l)?k(l.type,"")==="session.outcome":!1),i=v(n.session_outcome)?n.session_outcome:{};if(v(i)&&Object.keys(i).length>0){const l=nr(i);if(l)return l}if(v(a))return nr(v(a.payload)?a.payload:{})}function k(e,t=""){return typeof e=="string"?e:t}function H(e,t=0){return typeof e=="number"&&Number.isFinite(e)?e:t}function _e(e){if(typeof e=="number"&&Number.isFinite(e))return Math.trunc(e);if(typeof e=="string"){const t=Number.parseInt(e.trim(),10);if(Number.isFinite(t))return t}}function Zs(e,t=!1){return typeof e=="boolean"?e:t}function De(e){return Array.isArray(e)?e.map(t=>{if(typeof t=="string")return t.trim();if(v(t)){const n=k(t.name,"").trim(),s=k(t.id,"").trim(),a=k(t.skill,"").trim();return n||s||a}return""}).filter(t=>t.length>0):[]}function Su(e){const t={};if(!v(e)&&!Array.isArray(e))return t;if(v(e))return Object.entries(e).forEach(([n,s])=>{const a=n.trim(),i=k(s,"").trim();!a||!i||(t[a]=i)}),t;for(const n of e){if(!v(n))continue;const s=ue(n.to,n.target,n.actor_id,n.name,n.id),a=ue(n.relationship,n.relation,n.type,n.kind);!s||!a||(t[s]=a)}return t}function Cu(e,t,n){if(e==="dm"||e==="player"||e==="npc")return e;const s=t.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function Se(e,t,n,s=0){const a=e[t];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=e[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const Au=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Tu(e){const t=v(e.stats)?e.stats:{},n={};return Object.entries(t).forEach(([s,a])=>{const i=s.trim();i&&(Au.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function Iu(e,t){if(e!=="dice.rolled")return;const n=H(t.raw_d20,0),s=H(t.total,0),a=H(t.bonus,0),i=k(t.action,"roll"),l=H(t.dc,0);return{notation:l>0?`${i} (DC ${l})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Ru(e){const t=JSON.stringify(e);return t?t.length>160?`${t.slice(0,157)}...`:t:""}function Lu(e){const t=e.trim().toLowerCase();return t?t.startsWith("dice.")?"dice":t.startsWith("combat.")||t.includes(".attack")||t.includes(".damage")?"combat":t.includes("actor.")?"actor":t.includes("turn.")||t==="turn.started"||t==="phase.changed"?"turn":t.includes("join.")?"join":t.includes("memory")?"memory":t.includes("world.")?"world":t.includes("narration")?"story":"meta":"meta"}function zu(e,t,n,s){const a=n||t||k(s.actor_id,"")||k(s.actor_name,"");switch(e){case"turn.action.proposed":{const i=k(s.proposed_action,k(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=k(s.reply,k(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return k(s.reply,k(s.content,k(s.text,"Narration")));case"dice.rolled":{const i=k(s.action,"roll"),l=H(s.total,0),c=H(s.dc,0),p=k(s.label,""),m=a||"actor",u=c>0?` vs DC ${c}`:"",f=p?` (${p})`:"";return`${m} ${i}: ${l}${u}${f}`}case"turn.started":return`Turn ${H(s.turn,1)} started`;case"phase.changed":return`Phase: ${k(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${k(s.name,v(s.actor)?k(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${k(s.keeper_name,k(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${k(s.keeper_name,k(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${H(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${H(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||k(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||k(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${k(s.reason_code,"unknown")}`;case"memory.signal":{const i=v(s.entity_refs)?s.entity_refs:{},l=k(i.requested_tier,""),c=k(i.effective_tier,""),p=Zs(i.guardrail_applied,!1),m=k(s.summary_en,k(s.summary_ko,"Memory signal"));if(!l&&!c)return m;const u=l&&c?`${l}->${c}`:c||l;return`${m} [${u}${p?" (guardrail)":""}]`}case"world.event":{if(k(s.event_type,"")==="canon.check"){const l=k(s.status,"unknown"),c=k(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return k(s.description,k(s.summary,"World event"))}case"combat.attack":return k(s.summary,k(s.result,"Attack resolved"));case"combat.defense":return k(s.summary,k(s.result,"Defense resolved"));case"session.outcome":return k(s.summary,k(s.outcome,"Session ended"));default:{const i=Ru(s);return i?`${e}: ${i}`:e}}}function Pu(e,t){const n=v(e)?e:{},s=k(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=k(n.actor_name,"").trim()||t[a]||k(v(n.payload)?n.payload.actor_name:"",""),l=v(n.payload)?n.payload:{},c=k(n.ts,k(n.timestamp,new Date().toISOString())),p=k(n.phase,k(l.phase,"")),m=k(n.category,"");return{type:s,actor:i||a||k(l.actor_name,""),actor_id:a||k(l.actor_id,""),actor_name:i,seq:n.seq,room_id:k(n.room_id,""),phase:p||void 0,category:m||Lu(s),visibility:k(n.visibility,k(l.visibility,"public")),event_id:k(n.event_id,""),content:zu(s,a,i,l),dice_roll:Iu(s,l),timestamp:c}}function Mu(e,t,n){var Z,ae;const s=k(e.room_id,"")||n||"default",a=v(e.state)?e.state:{},i=v(a.party)?a.party:{},l=v(a.actor_control)?a.actor_control:{},c=v(a.join_gate)?a.join_gate:{},p=v(a.contribution_ledger)?a.contribution_ledger:{},m=Object.entries(i).map(([W,ee])=>{const A=v(ee)?ee:{},te=Se(A,"max_hp",void 0,10),U=Se(A,"hp",void 0,te),Ue=Se(A,"max_mp",void 0,0),$t=Se(A,"mp",void 0,0),K=Se(A,"level",void 0,1),Pe=Se(A,"xp",void 0,0),ht=Zs(A.alive,U>0),gn=l[W],$n=typeof gn=="string"?gn:void 0,_s=Cu(A.role,W,$n),fs=_e(A.generation),gs=ue(A.joined_at,A.joinedAt,A.started_at,A.startedAt),$s=ue(A.claimed_at,A.claimedAt,A.assigned_at,A.assignedAt,A.assigned_time),hs=ue(A.last_seen,A.lastSeen,A.last_seen_at,A.lastSeenAt,A.last_active,A.lastActive),ys=ue(A.scene,A.current_scene,A.currentScene,A.world_scene,A.scene_name,A.sceneName),bs=ue(A.location,A.current_location,A.currentLocation,A.position,A.zone,A.area);return{id:W,name:k(A.name,W),role:_s,keeper:$n,archetype:k(A.archetype,""),persona:k(A.persona,""),portrait:k(A.portrait,"")||void 0,background:k(A.background,"")||void 0,traits:De(A.traits),skills:De(A.skills),stats_raw:Tu(A),status:ht?"active":"dead",generation:fs,joined_at:gs||void 0,claimed_at:$s||void 0,last_seen:hs||void 0,scene:ys||void 0,location:bs||void 0,inventory:De(A.inventory),notes:De(A.notes),relationships:Su(A.relationships),stats:{hp:U,max_hp:te,mp:$t,max_mp:Ue,level:K,xp:Pe,strength:Se(A,"strength","str",10),dexterity:Se(A,"dexterity","dex",10),constitution:Se(A,"constitution","con",10),intelligence:Se(A,"intelligence","int",10),wisdom:Se(A,"wisdom","wis",10),charisma:Se(A,"charisma","cha",10)}}}),u=m.filter(W=>W.status!=="dead"),f=xu(e,t),_={phase_open:Zs(c.phase_open,!0),min_points:H(c.min_points,3),window:k(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},h=Object.entries(p).map(([W,ee])=>{const A=v(ee)?ee:{};return{actor_id:W,score:H(A.score,0),last_reason:k(A.last_reason,"")||null,reasons:De(A.reasons)}}),b=m.reduce((W,ee)=>(W[ee.id]=ee.name,W),{}),C=t.map(W=>Pu(W,b)),S=H(a.turn,1),T=k(a.phase,"round"),$=k(a.map,""),x=v(a.world)?a.world:{},R=$||k(x.ascii_map,k(x.map,"")),z=C.filter((W,ee)=>{const A=t[ee];if(!v(A))return!1;const te=v(A.payload)?A.payload:{};return H(te.turn,-1)===S}),q=(z.length>0?z:C).slice(-12),L=k(a.status,"active");return{session:{id:s,room:s,status:L==="ended"?"ended":L==="paused"?"paused":"active",round:S,actors:u,created_at:((Z=C[0])==null?void 0:Z.timestamp)??new Date().toISOString()},current_round:{round_number:S,phase:T,events:q,timestamp:((ae=C[C.length-1])==null?void 0:ae.timestamp)??new Date().toISOString()},map:R||void 0,join_gate:_,contribution_ledger:h,outcome:f,party:u,story_log:C,history:[]}}async function ju(e){const t=`?room_id=${encodeURIComponent(e)}`,n=await ne(`/api/v1/trpg/events${t}`);return Array.isArray(n.events)?n.events:[]}async function Eu(e){const t=`?room_id=${encodeURIComponent(e)}`,[n,s]=await Promise.all([ne(`/api/v1/trpg/state${t}`),ju(e)]);return Mu(n,s,e)}function Nu(e){return Fe("/api/v1/trpg/rounds/run",{room_id:e})}function Du(e){const t="".trim().toLowerCase();if(t)switch(t){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return t}}function wu(e){const t={room_id:e.roomId,actor_id:e.actorId,action:e.action,stat_value:e.statValue,dc:e.dc};return e.rawD20!=null&&(t.raw_d20=e.rawD20),e.ruleModule&&(t.rule_module=e.ruleModule),Fe("/api/v1/trpg/dice/roll",t)}function Ou(e,t){const n=Du();return Fe("/api/v1/trpg/turns/advance",{room_id:e,...n?{phase:n}:{}})}function qu(e,t){var a;const n=(a=t.idempotencyKey)==null?void 0:a.trim(),s={room_id:e};return t.actor_id&&t.actor_id.trim()&&(s.actor_id=t.actor_id.trim()),t.name&&t.name.trim()&&(s.name=t.name.trim()),t.role&&(s.role=t.role),t.archetype&&t.archetype.trim()&&(s.archetype=t.archetype.trim()),t.persona&&t.persona.trim()&&(s.persona=t.persona.trim()),t.portrait&&t.portrait.trim()&&(s.portrait=t.portrait.trim()),t.background&&t.background.trim()&&(s.background=t.background.trim()),t.hp!=null&&(s.hp=t.hp),t.max_hp!=null&&(s.max_hp=t.max_hp),t.alive!=null&&(s.alive=t.alive),Array.isArray(t.traits)&&t.traits.length>0&&(s.traits=t.traits),Array.isArray(t.skills)&&t.skills.length>0&&(s.skills=t.skills),Array.isArray(t.inventory)&&t.inventory.length>0&&(s.inventory=t.inventory),t.stats&&Object.keys(t.stats).length>0&&(s.stats=t.stats),n&&(s.idempotency_key=n),Fe("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function Fu(e,t,n){return Fe("/api/v1/trpg/actors/claim",{room_id:e,actor_id:t,keeper:n})}async function Ku(e,t,n){const s=await vt("trpg.join.eligibility",{room_id:e,actor_id:t,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Uu(e){const t=await vt("trpg.mid_join.request",e);return JSON.parse(t)}async function Hu(e,t){await vt("masc_broadcast",{agent_name:e,message:t})}async function Bu(e=40){return(await vt("masc_messages",{limit:e})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Wu(e,t=20){return vt("masc_task_history",{task_id:e,limit:t})}async function Gu(e){const t=await vt("masc_debate_start",{topic:e});try{return JSON.parse(t)}catch{return null}}async function Ju(e){return Oa("fetchDebateStatus",async()=>{const t=encodeURIComponent(e),n=await ne(`/api/v1/council/debates/${t}/summary`);if(!v(n))return null;const s=v(n.debate)?n.debate:n,a=k(s.id,"").trim(),i=k(s.topic,"").trim();return!a||!i?null:{debate:{id:a,topic:i,status:k(s.status,"open"),created_at:de(s.created_at_iso??s.created_at),closed_at:de(s.closed_at)},arguments:Array.isArray(n.arguments)?n.arguments.flatMap(l=>v(l)?[{index:H(l.index,0),agent:k(l.agent,"unknown"),position:k(l.position,"neutral"),content:k(l.content,""),evidence:De(l.evidence),reply_to:_e(l.reply_to)??null,mentions:De(l.mentions),archetype:O(l.archetype),created_at:de(l.created_at)}]:[]):[],summary:{support_count:v(n.summary)?H(n.summary.support_count,0):H(n.support_count,0),oppose_count:v(n.summary)?H(n.summary.oppose_count,0):H(n.oppose_count,0),neutral_count:v(n.summary)?H(n.summary.neutral_count,0):H(n.neutral_count,0),total_arguments:v(n.summary)?H(n.summary.total_arguments,0):H(n.total_arguments,0),summary_text:v(n.summary)?k(n.summary.summary_text,""):k(n.summary_text,"")},context:mi(n.context),judgment:ml(n.judgment)}})}async function Vu(e){return Oa("fetchConsensusSessionSummary",async()=>{const t=encodeURIComponent(e),n=await ne(`/api/v1/council/sessions/${t}/summary`);if(!v(n)||!v(n.session))return null;const s=n.session,a=k(s.id,"").trim(),i=k(s.topic,"").trim();return!a||!i?null:{session:{id:a,topic:i,state:k(s.state,"open"),initiator:k(s.initiator,"system"),quorum:H(s.quorum,0),threshold:H(s.threshold,0),created_at:de(s.created_at),closed_at:de(s.closed_at)},votes:Array.isArray(n.votes)?n.votes.flatMap(l=>v(l)?[{agent:k(l.agent,"unknown"),decision:k(l.decision,"abstain"),reason:k(l.reason,""),timestamp:de(l.timestamp),weight:typeof l.weight=="number"?l.weight:void 0,archetype:O(l.archetype)}]:[]):[],summary:{approve_count:v(n.summary)?H(n.summary.approve_count,0):0,reject_count:v(n.summary)?H(n.summary.reject_count,0):0,abstain_count:v(n.summary)?H(n.summary.abstain_count,0):0,quorum_met:v(n.summary)?Zs(n.summary.quorum_met,!1):!1,result:v(n.summary)?O(n.summary.result):null},context:mi(n.context),judgment:ml(n.judgment)}})}function Qu(e,t,n){return vt("masc_keeper_msg",{name:e,message:t})}const Yu=g(""),Ve=g({}),pe=g({}),jo=g({}),Eo=g({}),No=g({}),Do=g({}),Qe=g({});function ce(e,t,n){e.value={...e.value,[t]:n}}function Xu(e){var n;const t=(n=r(e))==null?void 0:n.toLowerCase();return t==="user"||t==="assistant"||t==="system"||t==="tool"?t:"other"}function Zu(e){switch(e){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Va(e,t){if(!Array.isArray(e))return[];const n=[];for(const s of e){if(!v(s))continue;const a=r(s.name);if(!a)continue;const i=r(s[t]);t==="summary"?n.push({name:a,summary:i}):n.push({name:a,reason:i})}return n}function ep(e){if(!v(e))return null;const t=r(e.name);return t?{name:t,trigger:r(e.trigger),outcome:r(e.outcome),summary:r(e.summary),reason:r(e.reason)}:null}function tp(e){const t=e.toLowerCase();return t.includes("graphql")?"graphql_error":t.includes("timeout")||t.includes("model")||t.includes("llm")||t.includes("api key")||t.includes("api_key")||t.includes("provider")?"llm_error":"unknown"}function np(e,t){return e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":t==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":t==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":t==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function _l(e,t,n){return r(e)??np(t,n)}function fl(e,t){return typeof e=="boolean"?e:t==="recover"}function ea(e){if(!v(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);return!t||!n||!s?null:{health_state:t,quiet_reason:r(e.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:re(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:fl(e.recoverable,n),summary:_l(e.summary,t,r(e.quiet_reason)??null),keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function gl(e){return v(e)?{hour:d(e.hour),checked:d(e.checked)??0,acted:d(e.acted)??0,acted_names:F(e.acted_names),activity_report:r(e.activity_report),quiet_hours_overridden:j(e.quiet_hours_overridden),skipped_reason:r(e.skipped_reason),acted_rows:Va(e.acted_rows,"summary").map(t=>({name:t.name,summary:t.summary})),passed_rows:Va(e.passed_rows,"reason").map(t=>({name:t.name,reason:t.reason})),skipped_rows:Va(e.skipped_rows,"reason").map(t=>({name:t.name,reason:t.reason})),checkins:Array.isArray(e.checkins)?e.checkins.map(ep).filter(t=>t!==null):[]}:null}function sp(e){return v(e)?{enabled:j(e.enabled)??!1,interval_s:d(e.interval_s)??0,quiet_start:d(e.quiet_start),quiet_end:d(e.quiet_end),quiet_active:j(e.quiet_active),use_planner:j(e.use_planner),delegate_llm:j(e.delegate_llm),agent_count:d(e.agent_count),agents:F(e.agents),last_tick_ago_s:d(e.last_tick_ago_s)??null,last_tick_ago:r(e.last_tick_ago),total_ticks:d(e.total_ticks),total_checkins:d(e.total_checkins),last_skip_reason:r(e.last_skip_reason)??null,last_tick_result:gl(e.last_tick_result),active_self_heartbeats:F(e.active_self_heartbeats)}:null}function ap(e){return v(e)?{status:e.status,diagnostic:ea(e.diagnostic)}:null}function op(e){return v(e)?{recovered:j(e.recovered)??!1,skipped_reason:r(e.skipped_reason)??null,before:ea(e.before),after:ea(e.after),down:e.down,up:e.up}:null}function ip(e,t){var $,x;if(!(e!=null&&e.name))return null;const n=r(($=e.agent)==null?void 0:$.status)??r(e.status)??"unknown",s=r((x=e.agent)==null?void 0:x.error)??null,a=e.presence_keepalive??!0,i=e.keepalive_running??!1,l=e.turn_count??0,c=e.last_turn_ago_s??null,p=e.proactive_enabled??!1,m=e.proactive_cooldown_sec??0,u=e.last_proactive_ago_s??null,f=p&&u!=null?Math.max(0,m-u):null,_=l<=0||c==null?"never":c>900?"stale":"fresh",h=typeof e.last_heartbeat=="string"&&e.last_heartbeat.trim()?e.last_heartbeat:null,b=s??(a&&!i?"keeper keepalive is not running":null),C=n==="offline"||n==="inactive"?"offline":b?"degraded":_==="stale"?"stale":_==="never"?"idle":"healthy",S=b?tp(b):t!=null&&t.quiet_active&&_!=="fresh"?"quiet_hours":a&&!i?"disabled":l<=0?"never_started":f!=null&&f>0?"min_gap":_==="fresh"||_==="stale"?"no_recent_activity":"unknown",T=C==="offline"||C==="degraded"||C==="stale"?"recover":S==="quiet_hours"?"manual_lodge_poke":S==="unknown"?"probe":"direct_message";return{health_state:C,quiet_reason:S,next_action_path:T,last_reply_status:_,last_reply_at:h,last_reply_preview:null,last_error:b,next_eligible_at_s:f!=null&&f>0?f:null,recoverable:fl(void 0,T),summary:_l(void 0,C,S),keepalive_running:i}}function rp(e,t){if(!v(e))return null;const n=Xu(e.role),s=r(e.content)??r(e.preview);if(!s)return null;const a=re(e.ts_unix)??re(e.timestamp);return{id:`${n}-${a??"entry"}-${t}`,role:n,label:Zu(n),text:s,timestamp:a,delivery:"history"}}function lp(e,t,n){const s=v(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((i,l)=>rp(i,l)).filter(i=>i!==null):[];return{name:e,diagnostic:ea(s==null?void 0:s.diagnostic),history:a,rawText:t,rawStatus:n,loadedAt:new Date().toISOString()}}function sr(e,t){const n=pe.value[e]??[];pe.value={...pe.value,[e]:[...n,t].slice(-50)}}function cp(e,t){return e.role!==t.role||e.text!==t.text?!1:e.timestamp&&t.timestamp?e.timestamp===t.timestamp:!0}function dp(e,t){const s=(pe.value[e]??[]).filter(a=>a.delivery!=="history"&&!t.some(i=>cp(a,i)));pe.value={...pe.value,[e]:[...t,...s].slice(-50)}}function Fa(e,t){Ve.value={...Ve.value,[e]:t},dp(e,t.history)}function ar(e,t){const n=Ve.value[e];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Fa(e,{...n,diagnostic:{...s,...t}})}async function vi(){try{await os()}catch(e){console.warn("[keeper-runtime] dashboard refresh failed",e)}}function up(e){Yu.value=e.trim()}async function $l(e,t=!1){const n=e.trim();if(!n)return null;if(!t&&Ve.value[n])return Ve.value[n];ce(jo,n,!0),ce(Qe,n,null);try{const s=await vt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const i=lp(n,s,a);return Fa(n,i),i}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return ce(Qe,n,a),null}finally{ce(jo,n,!1)}}async function pp(e,t){const n=e.trim(),s=t.trim();if(!n||!s)return;const a=`local-${Date.now()}`;sr(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),ce(Eo,n,!0),ce(Qe,n,null);try{const i=await Qu(n,s);pe.value={...pe.value,[n]:(pe.value[n]??[]).map(l=>l.id===a?{...l,delivery:"delivered"}:l)},sr(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),ar(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await vi()}catch(i){const l=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw pe.value={...pe.value,[n]:(pe.value[n]??[]).map(c=>c.id===a?{...c,delivery:"error",error:l}:c)},ar(n,{last_reply_status:"error",last_error:l}),ce(Qe,n,l),i}finally{ce(Eo,n,!1)}}async function mp(e,t){const n=e.trim();if(!n)return null;ce(No,n,!0),ce(Qe,n,null);try{const s=await qa({actor:t,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=ap(s.result),i=(a==null?void 0:a.diagnostic)??null;if(i){const l=Ve.value[n];Fa(n,{name:n,diagnostic:i,history:(l==null?void 0:l.history)??pe.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await vi(),i}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw ce(Qe,n,a),s}finally{ce(No,n,!1)}}async function vp(e,t){const n=e.trim();if(!n)return null;ce(Do,n,!0),ce(Qe,n,null);try{const s=await qa({actor:t,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=op(s.result),i=(a==null?void 0:a.after)??null;if(i){const l=Ve.value[n];Fa(n,{name:n,diagnostic:i,history:(l==null?void 0:l.history)??pe.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await vi(),i}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw ce(Qe,n,a),s}finally{ce(Do,n,!1)}}function yt(e){return(e??"").trim().toLowerCase()}function $e(e){const t=typeof e=="number"?e:Date.parse(e);return Number.isNaN(t)?0:t}function qs(e,t=88){const n=e.replace(/\s+/g," ").trim();return n&&(n.length>t?`${n.slice(0,t-3)}...`:n)}function xs(e){return typeof e!="number"||!Number.isFinite(e)||e<0?null:new Date(Date.now()-e*1e3).toISOString()}function hn(e){return e.last_heartbeat??xs(e.last_turn_ago_s)??xs(e.last_proactive_ago_s)??xs(e.last_handoff_ago_s)??xs(e.last_compaction_ago_s)}function _p(e){const t=e.title.trim();return t||qs(e.content)}function fp(e){const t=e.generation??"?",n=typeof e.context_ratio=="number"&&Number.isFinite(e.context_ratio)?`${Math.round(e.context_ratio*100)}%`:"?";return e.last_heartbeat?`Heartbeat gen=${t} ctx=${n}`:`Keeper snapshot gen=${t} ctx=${n}`}function gp(e,t,n,s,a={}){var x;const i=yt(e),l=t.filter(R=>yt(R.assignee)===i&&(R.status==="claimed"||R.status==="in_progress")).length,c=n.filter(R=>yt(R.from)===i).sort((R,z)=>$e(z.timestamp)-$e(R.timestamp))[0],p=s.filter(R=>yt(R.agent)===i||yt(R.author)===i).sort((R,z)=>$e(z.timestamp)-$e(R.timestamp))[0],m=(a.boardPosts??[]).filter(R=>yt(R.author)===i).sort((R,z)=>$e(z.updated_at||z.created_at)-$e(R.updated_at||R.created_at))[0],u=(a.keepers??[]).filter(R=>yt(R.name)===i&&hn(R)!==null).sort((R,z)=>$e(hn(z)??0)-$e(hn(R)??0))[0],f=c?$e(c.timestamp):0,_=p?$e(p.timestamp):0,h=m?$e(m.updated_at||m.created_at):0,b=u?$e(hn(u)??0):0,C=a.lastSeen?$e(a.lastSeen):0,S=((x=a.currentTask)==null?void 0:x.trim())||(l>0?`${l} claimed tasks`:null);if(f===0&&_===0&&h===0&&b===0&&C===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:S};const $=[c?{timestamp:c.timestamp,ts:f,text:qs(c.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:h,text:`Post: ${qs(_p(m))}`}:null,u?{timestamp:hn(u),ts:b,text:fp(u)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:_,text:qs(p.text)}:null].filter(R=>R!==null).sort((R,z)=>z.ts-R.ts)[0];return $&&$.ts>=C?{activeAssignedCount:l,lastActivityAt:$.timestamp,lastActivityText:$.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:S??"Presence heartbeat"}}const Ye=g([]),st=g([]),wo=g([]),_t=g([]),oe=g(null),$p=g(null),hl=g(null),yl=g([]),bl=g([]),kl=g([]),xl=g([]),Sl=g(null),_i=g([]),fi=g([]),Cl=g([]),Oo=g(new Map),Ka=g([]),On=g("recent"),At=g(!0),Al=g(null),Je=g(""),Vt=g([]),An=g(!1),Tl=g(new Map),gi=g("unknown"),Qt=g(null),qo=g(!1),qn=g(!1),Fo=g(!1),Tn=g(!1),$i=g(null),ta=g(!1),na=g(null),Il=g(null),Ko=g(null),hp=g(null),yp=g(null),bp=g(null);ze(()=>Ye.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle"));const Rl=ze(()=>{const e=st.value;return{todo:e.filter(t=>t.status==="todo"),inProgress:e.filter(t=>t.status==="in_progress"||t.status==="claimed"),done:e.filter(t=>t.status==="done")}}),Ll=ze(()=>{const e=new Map,t=st.value,n=wo.value,s=Xs.value,a=Ka.value,i=_t.value;for(const l of Ye.value)e.set(l.name.trim().toLowerCase(),gp(l.name,t,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:i}));return e});function kp(e){var i;const t=((i=e.status)==null?void 0:i.toLowerCase())??"";if(t==="offline"||t==="inactive")return"offline";const n=e.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}ze(()=>{const e=new Map;for(const t of _t.value)e.set(t.name,kp(t));return e});const xp=12e4;function Sp(e,t){const n=t.get(e.name);if(n!=null)return n;const s=e.last_heartbeat?Date.parse(e.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[e.last_turn_ago_s,e.last_proactive_ago_s,e.last_handoff_ago_s,e.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof a=="number"?Date.now()-a*1e3:null}ze(()=>{const e=Date.now(),t=new Set,n=Oo.value;for(const s of _t.value){const a=Sp(s,n);a!=null&&e-a>xp&&t.add(s.name)}return t});function Cp(e){return e==="dashboard_refresh"||e==="masc/dashboard_refresh"||e.startsWith("goal_")||e.startsWith("masc/goal_")||e.startsWith("mdal_")||e.startsWith("masc/mdal_")||e.startsWith("operator_")||e.startsWith("masc/operator_")||e.startsWith("command_plane_")||e.startsWith("masc/command_plane_")}function zl(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="active"||t==="busy"||t==="listening"||t==="idle"||t==="inactive"||t==="offline"?t:t==="in_progress"||t==="claimed"?"busy":"offline"}function Ap(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="todo"||t==="in_progress"||t==="claimed"||t==="done"||t==="cancelled"?t:t==="inprogress"?"in_progress":"todo"}function Tp(e){if(!v(e))return null;const t=r(e.name);return t?{name:t,agent_type:r(e.agent_type),status:zl(e.status),current_task:r(e.current_task)??null,joined_at:r(e.joined_at),last_seen:r(e.last_seen),capabilities:F(e.capabilities),emoji:r(e.emoji),koreanName:r(e.koreanName)??r(e.korean_name),model:r(e.model),traits:F(e.traits),interests:F(e.interests),activityLevel:d(e.activityLevel)??d(e.activity_level),primaryValue:r(e.primaryValue)??r(e.primary_value)}:null}function Ip(e){if(!v(e))return null;const t=r(e.id),n=r(e.title);return!t||!n?null:{id:t,title:n,status:Ap(e.status),priority:d(e.priority),assignee:r(e.assignee),description:r(e.description),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function Rp(e){if(!v(e))return null;const t=r(e.from)??r(e.from_agent)??"system",n=r(e.content)??"",s=r(e.timestamp)??new Date().toISOString();return{id:r(e.id),seq:d(e.seq),from:t,content:n,timestamp:s,type:r(e.type)}}function hi(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="ok"||t==="warn"||t==="bad"?t:"ok"}function Lp(e){return v(e)?{active_sessions:d(e.active_sessions),blocked_sessions:d(e.blocked_sessions),active_operations:d(e.active_operations),blocked_operations:d(e.blocked_operations),runtime_pressure:d(e.runtime_pressure),worker_alerts:d(e.worker_alerts),continuity_alerts:d(e.continuity_alerts),priority_items:d(e.priority_items),todo_tasks:d(e.todo_tasks),claimed_tasks:d(e.claimed_tasks),running_tasks:d(e.running_tasks),done_tasks:d(e.done_tasks),cancelled_tasks:d(e.cancelled_tasks),keepers:d(e.keepers)}:null}function at(e){if(!v(e))return null;const t=r(e.surface),n=r(e.label),s=r(e.target_type),a=r(e.target_id),i=r(e.focus_kind);return!t||!n||!s||!a||!i?null:{surface:t==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:i,operation_id:r(e.operation_id)??null,command_surface:r(e.command_surface)??null}}function zp(e){if(!v(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.summary),a=r(e.target_type),i=r(e.target_id);return!t||!s||!a||!i||n!=="session"&&n!=="operation"?null:{id:t,kind:n,severity:hi(e.severity),status:r(e.status),summary:s,target_type:a,target_id:i,linked_session_id:r(e.linked_session_id)??null,linked_operation_id:r(e.linked_operation_id)??null,last_seen_at:r(e.last_seen_at)??null,top_handoff:at(e.top_handoff),intervene_handoff:at(e.intervene_handoff),command_handoff:at(e.command_handoff)}}function Pp(e){if(!v(e))return null;const t=r(e.session_id),n=r(e.goal);return!t||!n?null:{session_id:t,goal:n,room:r(e.room)??null,status:r(e.status),health:r(e.health),member_names:F(e.member_names),linked_operation_id:r(e.linked_operation_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,runtime_blocker:r(e.runtime_blocker)??null,worker_gap_summary:r(e.worker_gap_summary)??null,last_activity_at:r(e.last_activity_at)??null,last_activity_summary:r(e.last_activity_summary)??null,communication_summary:r(e.communication_summary)??null,active_count:d(e.active_count),required_count:d(e.required_count),top_handoff:at(e.top_handoff),intervene_handoff:at(e.intervene_handoff),command_handoff:at(e.command_handoff)}}function Mp(e){if(!v(e))return null;const t=r(e.operation_id),n=r(e.objective);return!t||!n?null:{operation_id:t,objective:n,status:r(e.status),stage:r(e.stage)??null,assigned_unit_id:r(e.assigned_unit_id)??null,assigned_unit_label:r(e.assigned_unit_label)??null,linked_session_id:r(e.linked_session_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,blocker_summary:r(e.blocker_summary)??null,search_status:r(e.search_status)??null,next_tool:r(e.next_tool)??null,updated_at:r(e.updated_at)??null,top_handoff:at(e.top_handoff),command_handoff:at(e.command_handoff)}}function or(e){if(!v(e))return null;const t=r(e.name)??r(e.agent_name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline"?null:{name:t,agent_name:r(e.agent_name),status:r(e.status),tone:hi(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,active_task_count:d(e.active_task_count),related_session_id:r(e.related_session_id)??null,related_operation_id:r(e.related_operation_id)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),model:r(e.model)??null,recent_output_preview:r(e.recent_output_preview)??null,recent_event:r(e.recent_event)??null}}function jp(e){return v(e)?{checked:d(e.checked),acted:d(e.acted),passed:d(e.passed),skipped:d(e.skipped),failed:d(e.failed),last_tick_at:r(e.last_tick_at)??null,last_skip_reason:r(e.last_skip_reason)??null,activity_report:r(e.activity_report)??null}:null}function Ep(e){if(!v(e))return null;const t=r(e.agent_name),n=r(e.outcome);return!t||!n?null:{agent_name:t,trigger:r(e.trigger)??null,outcome:n,summary:r(e.summary)??null,reason:r(e.reason)??null,allowed_tool_names:F(e.allowed_tool_names)??[],used_tool_names:F(e.used_tool_names)??[],used_tool_call_count:d(e.used_tool_call_count)??null,action_kind:r(e.action_kind)??"none",tool_audit_source:r(e.tool_audit_source)??null,tool_audit_at:r(e.tool_audit_at)??null,checked_at:r(e.checked_at)??null,decision_reason:r(e.decision_reason)??null,worker_name:r(e.worker_name)??null,failure_reason:r(e.failure_reason)??null}}function Np(e){if(!v(e))return null;const t=r(e.name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:t,agent_name:r(e.agent_name)??null,status:r(e.status),tone:hi(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,last_autonomous_action_at:r(e.last_autonomous_action_at)??null,generation:d(e.generation),turn_count:d(e.turn_count),context_ratio:d(e.context_ratio)??null,continuity:r(e.continuity)??null,lifecycle:r(e.lifecycle)??null,related_session_id:r(e.related_session_id)??null,model:r(e.model)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),skill_reason:r(e.skill_reason)??null,recent_input_preview:r(e.recent_input_preview)??null,recent_output_preview:r(e.recent_output_preview)??null,recent_tool_names:F(e.recent_tool_names)??[],allowed_tool_names:F(e.allowed_tool_names)??[],latest_tool_names:F(e.latest_tool_names)??[],latest_tool_call_count:d(e.latest_tool_call_count)??null,tool_audit_source:r(e.tool_audit_source)??null,tool_audit_at:r(e.tool_audit_at)??null,last_proactive_preview:r(e.last_proactive_preview)??null,continuity_summary:r(e.continuity_summary)??null,skill_route_summary:r(e.skill_route_summary)??null}}function ir(e){if(typeof e.seq=="number"&&Number.isFinite(e.seq))return e.seq;const t=Date.parse(e.timestamp);return Number.isNaN(t)?0:t}function Dp(e,t){if(t.length===0)return e;const n=new Map;for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>ir(s)-ir(a)).slice(-500)}function wp(e){return Array.isArray(e)?e.map(t=>{if(!v(t))return null;const n=d(t.ts_unix);if(n==null)return null;const s=v(t.handoff)?t.handoff:null;return{ts:n,context_ratio:d(t.context_ratio)??0,context_tokens:d(t.context_tokens)??0,context_max:d(t.context_max)??0,latency_ms:d(t.latency_ms)??0,generation:d(t.generation)??0,channel:typeof t.channel=="string"?t.channel:"turn",is_handoff:s!=null&&t.handoff_performed===!0,is_compaction:t.compacted===!0,compaction_saved_tokens:d(t.compaction_saved_tokens)??0,compaction_trigger:typeof t.compaction_trigger=="string"?t.compaction_trigger:null,model_used:typeof t.model_used=="string"?t.model_used:"",cost_usd:d(t.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?d(s.new_generation)??null:null}}).filter(t=>t!==null):[]}function rr(e){if(!v(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);if(!t||!n||!s)return null;const a=r(e.quiet_reason)??null,i=r(e.summary)??(t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:t,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:re(e.last_reply_at)??r(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:typeof e.recoverable=="boolean"?e.recoverable:n==="recover",summary:i,keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function Op(e,t){return(Array.isArray(e)?e:v(e)&&Array.isArray(e.keepers)?e.keepers:[]).map(s=>{if(!v(s))return null;const a=v(s.agent)?s.agent:null,i=v(s.context)?s.context:null,l=v(s.metrics_window)?s.metrics_window:void 0,c=r(s.name);if(!c)return null;const p=d(s.context_ratio)??d(i==null?void 0:i.context_ratio),m=r(s.status)??r(a==null?void 0:a.status)??"offline",u=zl(m),f=r(s.model)??r(s.active_model)??r(s.primary_model),_=F(s.skill_secondary),h=i?{source:r(i.source),context_ratio:d(i.context_ratio),context_tokens:d(i.context_tokens),context_max:d(i.context_max),message_count:d(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,b=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:d(a.last_seen_ago_s),capabilities:F(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,C=wp(s.metrics_series),S={name:c,runtime_class:s.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:typeof s.desired=="boolean"?s.desired:void 0,resident_registered:typeof s.resident_registered=="boolean"?s.resident_registered:void 0,reconcile_status:r(s.reconcile_status)??null,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:f,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:u,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:d(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:d(s.proactive_idle_sec),proactive_cooldown_sec:d(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:d(s.generation),turn_count:d(s.turn_count)??d(s.total_turns),keeper_age_s:d(s.keeper_age_s),last_turn_ago_s:d(s.last_turn_ago_s),last_handoff_ago_s:d(s.last_handoff_ago_s),last_compaction_ago_s:d(s.last_compaction_ago_s),last_proactive_ago_s:d(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:p,context_tokens:d(s.context_tokens)??d(i==null?void 0:i.context_tokens),context_max:d(s.context_max)??d(i==null?void 0:i.context_max),context_source:r(s.context_source)??r(i==null?void 0:i.source),context:h,traits:F(s.traits),interests:F(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:d(s.activityLevel)??d(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:F(s.recent_tool_names)??[],allowed_tool_names:F(s.allowed_tool_names)??[],latest_tool_names:F(s.latest_tool_names)??[],latest_tool_call_count:d(s.latest_tool_call_count)??null,tool_audit_source:r(s.tool_audit_source)??null,tool_audit_at:re(s.tool_audit_at)??r(s.tool_audit_at)??null,conversation_tail_count:d(s.conversation_tail_count),k2k_count:d(s.k2k_count),handoff_count_total:d(s.handoff_count_total)??d(s.trace_history_count),compaction_count:d(s.compaction_count),last_compaction_saved_tokens:d(s.last_compaction_saved_tokens),diagnostic:rr(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:_,skill_reason:r(s.skill_reason)??null,metrics_series:C.length>0?C:void 0,metrics_window:l,agent:b};return S.diagnostic=rr(s.diagnostic)??ip(S,(t==null?void 0:t.lodge)??null),S}).filter(s=>s!==null)}function qp(e){if(!v(e))return;const t=r(e.release_version),n=re(e.started_at),s=d(e.uptime_seconds);if(!(!t||!n||s==null))return{release_version:t,commit:r(e.commit)??null,started_at:n,uptime_seconds:s}}function Fp(e){if(v(e))return{enabled:e.enabled===!0,alive:e.alive===!0,status:r(e.status)??void 0,tick_in_progress:typeof e.tick_in_progress=="boolean"?e.tick_in_progress:void 0,tick_count:d(e.tick_count)??void 0,check_interval_sec:d(e.check_interval_sec)??void 0,last_tick_started_at:re(e.last_tick_started_at)??r(e.last_tick_started_at)??null,last_tick_completed_at:re(e.last_tick_completed_at)??r(e.last_tick_completed_at)??null,next_tick_due_at:re(e.next_tick_due_at)??r(e.next_tick_due_at)??null,last_health_check_at:re(e.last_health_check_at)??r(e.last_health_check_at)??null,last_intervention:r(e.last_intervention)??void 0,last_decision_source:r(e.last_decision_source)??void 0,last_action:r(e.last_action)??void 0,last_target:r(e.last_target)??null,last_reason:r(e.last_reason)??null,last_error:r(e.last_error)??null,circuit_open:typeof e.circuit_open=="boolean"?e.circuit_open:void 0,circuit_open_until:re(e.circuit_open_until)??r(e.circuit_open_until)??null,can_spawn:typeof e.can_spawn=="boolean"?e.can_spawn:void 0,can_retire:typeof e.can_retire=="boolean"?e.can_retire:void 0,last_spawn_attempt_at:re(e.last_spawn_attempt_at)??r(e.last_spawn_attempt_at)??null,last_retirement_attempt_at:re(e.last_retirement_attempt_at)??r(e.last_retirement_attempt_at)??null,spawns_today:d(e.spawns_today)??void 0,retirements_today:d(e.retirements_today)??void 0,health_summary:v(e.health_summary)?{total_agents:d(e.health_summary.total_agents)??void 0,active_agents:d(e.health_summary.active_agents)??void 0,idle_agents:d(e.health_summary.idle_agents)??void 0,todo_count:d(e.health_summary.todo_count)??void 0,high_priority_todo:d(e.health_summary.high_priority_todo)??void 0,orphan_count:d(e.health_summary.orphan_count)??void 0,homeostatic_score:d(e.health_summary.homeostatic_score)??void 0,needs_workers:typeof e.health_summary.needs_workers=="boolean"?e.health_summary.needs_workers:void 0}:void 0}}function Kp(e){if(v(e))return{enabled:e.enabled===!0,mode:r(e.mode)??void 0,masc_enabled:typeof e.masc_enabled=="boolean"?e.masc_enabled:void 0,masc_loops_running:typeof e.masc_loops_running=="boolean"?e.masc_loops_running:void 0,runtime_owner:r(e.runtime_owner)??null,zombie_loop_running:typeof e.zombie_loop_running=="boolean"?e.zombie_loop_running:void 0,gc_loop_running:typeof e.gc_loop_running=="boolean"?e.gc_loop_running:void 0,lodge_enabled:typeof e.lodge_enabled=="boolean"?e.lodge_enabled:void 0,lodge_loop_started:typeof e.lodge_loop_started=="boolean"?e.lodge_loop_started:void 0,lodge_running:typeof e.lodge_running=="boolean"?e.lodge_running:void 0,last_zombie_cleanup:re(e.last_zombie_cleanup)??r(e.last_zombie_cleanup)??null,last_gc:re(e.last_gc)??r(e.last_gc)??null,last_lodge:re(e.last_lodge)??r(e.last_lodge)??null,last_zombie_result:r(e.last_zombie_result)??null,last_gc_result:r(e.last_gc_result)??null,last_lodge_result:v(e.last_lodge_result)?{ok:typeof e.last_lodge_result.ok=="boolean"?e.last_lodge_result.ok:void 0,message:r(e.last_lodge_result.message)??void 0}:null}}function Up(e){if(v(e))return{enabled:e.enabled===!0,started:e.started===!0,agent_name:r(e.agent_name)??null,llm_enabled:typeof e.llm_enabled=="boolean"?e.llm_enabled:void 0,uptime_s:d(e.uptime_s)??void 0,embedded_guardian_loops_running:typeof e.embedded_guardian_loops_running=="boolean"?e.embedded_guardian_loops_running:void 0,guardian_runtime_owner:r(e.guardian_runtime_owner)??null,consumers:F(e.consumers)}}function Pl(e,t){return v(e)?{...e,generated_at:t??re(e.generated_at)??void 0,build:qp(e.build),lodge:sp(e.lodge)??void 0,gardener:Fp(e.gardener)??void 0,guardian:Kp(e.guardian)??void 0,sentinel:Up(e.sentinel)??void 0}:null}function Ml(e,t){return t?e?{...e,...t,build:t.build??e.build,generated_at:t.generated_at??e.generated_at}:t:e}function Hp(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="running"||t==="interrupted"||t==="completed"||t==="stopped"||t==="error"?t:t.startsWith("error")?"error":"running"}function Bp(e){if(!v(e))return null;const t=d(e.iteration);if(t==null)return null;const n=d(e.metric_before)??0,s=d(e.metric_after)??n,a=v(e.evidence)?e.evidence:null;return{iteration:t,metric_before:n,metric_after:s,delta:d(e.delta)??s-n,changes:r(e.changes)??"",failed_attempts:r(e.failed_attempts)??"",next_suggestion:r(e.next_suggestion)??"",elapsed_ms:d(e.elapsed_ms)??0,cost_usd:d(e.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:d(a.tool_call_count)??0,tool_names:F(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function Wp(e){var i,l;if(!v(e))return null;const t=r(e.loop_id);if(!t)return null;const n=d(e.baseline_metric)??0,s=Array.isArray(e.history)?e.history.map(Bp).filter(c=>c!==null):[],a=d(e.current_metric)??((i=s[0])==null?void 0:i.metric_after)??n;return{loop_id:t,profile:r(e.profile)??"unknown",status:Hp(e.status),strict_mode:typeof e.strict_mode=="boolean"?e.strict_mode:void 0,error_message:r(e.error_message)??r(e.error_reason)??null,stop_reason:r(e.stop_reason)??r(e.reason)??null,current_iteration:d(e.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:d(e.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(e.target)??"",stagnation_streak:d(e.stagnation_streak)??0,stagnation_limit:d(e.stagnation_limit)??0,elapsed_seconds:d(e.elapsed_seconds)??0,updated_at:re(e.updated_at)??null,stopped_at:re(e.stopped_at)??null,execution_mode:e.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:e.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(e.worker_model)??null,evidence_policy:e.evidence_policy==="hard"||e.evidence_policy==="legacy"?e.evidence_policy:void 0,latest_tool_call_count:d(e.latest_tool_call_count)??0,latest_tool_names:F(e.latest_tool_names)??[],session_id:r(e.session_id)??null,evidence_status:e.evidence_status==="legacy_unverified"?"legacy_unverified":e.evidence_status==="verified"?"verified":null,durability:e.durability==="persistent_backend"||e.durability==="memory_only"?e.durability:void 0,persistence_backend:e.persistence_backend==="filesystem"||e.persistence_backend==="postgres"||e.persistence_backend==="memory"?e.persistence_backend:void 0,recoverable:typeof e.recoverable=="boolean"?e.recoverable:void 0,history:s}}async function os(){qo.value=!0;try{await Promise.all([El(),Tt()]),Il.value=new Date().toISOString()}catch(e){console.error("Dashboard refresh error:",e)}finally{qo.value=!1}}async function jl(){ta.value=!0,na.value=null;try{const e=await Vd();$i.value=e,bp.value=new Date().toISOString()}catch(e){na.value=e instanceof Error?e.message:"Failed to load dashboard semantics"}finally{ta.value=!1}}function Gp(e){var t;return((t=$i.value)==null?void 0:t.surfaces.find(n=>n.id===e))??null}function Jp(e){var n;const t=((n=$i.value)==null?void 0:n.surfaces)??[];for(const s of t){const a=s.panels.find(i=>i.id===e);if(a)return a}return null}function Vp(e){var s,a;Vt.value=(Array.isArray(e.goals)?e.goals:[]).map(i=>{if(!v(i))return null;const l=r(i.id),c=r(i.title),p=r(i.horizon),m=r(i.status),u=r(i.created_at),f=r(i.updated_at);return!l||!c||!p||!m||!u||!f?null:{id:l,horizon:p,title:c,metric:r(i.metric)??null,target_value:r(i.target_value)??null,due_date:r(i.due_date)??null,priority:d(i.priority)??3,status:m,parent_goal_id:r(i.parent_goal_id)??null,last_review_note:r(i.last_review_note)??null,last_review_at:r(i.last_review_at)??null,created_at:u,updated_at:f}}).filter(i=>i!==null);const t=new Map,n=Array.isArray((s=e.mdal)==null?void 0:s.loops)?e.mdal.loops:[];for(const i of n){const l=Wp(i);l&&t.set(l.loop_id,l)}Tl.value=t,Qt.value=typeof((a=e.mdal)==null?void 0:a.error)=="string"?e.mdal.error:null,gi.value=Qt.value?"error":t.size===0?"idle":"ready"}async function El(){try{const e=await Bd(),t=Pl(e.status,e.generated_at);t&&(oe.value=Ml(oe.value,t))}catch(e){console.error("Dashboard shell fetch error:",e)}}async function Tt(){var e;try{const t=await Wd(),n=Pl(t.status,t.generated_at),s=(e=oe.value)==null?void 0:e.room;n&&(oe.value=Ml(oe.value,n));const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Ye.value=(Array.isArray(t.agents)?t.agents:[]).map(Tp).filter(l=>l!==null),st.value=(Array.isArray(t.tasks)?t.tasks:[]).map(Ip).filter(l=>l!==null);const i=(Array.isArray(t.messages)?t.messages:[]).map(Rp).filter(l=>l!==null);wo.value=a?i:Dp(wo.value,i),_t.value=Op(t.keepers,n??oe.value),hl.value=Lp(t.summary),Sl.value=jp(t.lodge_tick),_i.value=(Array.isArray(t.lodge_checkins)?t.lodge_checkins:[]).map(Ep).filter(l=>l!==null),yl.value=(Array.isArray(t.execution_queue)?t.execution_queue:Array.isArray(t.priority_queue)?t.priority_queue:[]).map(zp).filter(l=>l!==null),bl.value=(Array.isArray(t.session_briefs)?t.session_briefs:[]).map(Pp).filter(l=>l!==null),kl.value=(Array.isArray(t.operation_briefs)?t.operation_briefs:[]).map(Mp).filter(l=>l!==null),xl.value=(Array.isArray(t.worker_support_briefs)?t.worker_support_briefs:Array.isArray(t.worker_briefs)?t.worker_briefs:[]).map(or).filter(l=>l!==null),fi.value=(Array.isArray(t.continuity_briefs)?t.continuity_briefs:[]).map(Np).filter(l=>l!==null),Cl.value=(Array.isArray(t.offline_worker_briefs)?t.offline_worker_briefs:[]).map(or).filter(l=>l!==null),$p.value=null,Il.value=new Date().toISOString()}catch(t){console.error("Dashboard execution fetch error:",t)}}async function ot(){qn.value=!0;try{const e=await Gd(On.value,{excludeSystem:At.value});Ka.value=e.posts??[],Ko.value=new Date().toISOString()}catch(e){console.error("Board fetch error:",e)}finally{qn.value=!1}}async function it(){var e;Fo.value=!0;try{const t=Je.value||((e=oe.value)==null?void 0:e.room)||"default";Je.value||(Je.value=t);const n=await Eu(t);Al.value=n}catch(t){console.error("TRPG fetch error:",t)}finally{Fo.value=!1}}async function yi(){An.value=!0,Tn.value=!0;try{const e=await eu();Vp(e),hp.value=new Date().toISOString(),yp.value=new Date().toISOString()}catch(e){console.error("Planning fetch error:",e),gi.value="error",Qt.value=e instanceof Error?e.message:String(e)}finally{An.value=!1,Tn.value=!1}}async function Nl(){return yi()}let Fs=null;function Qp(e){Fs=e}let Ks=null;function Yp(e){Ks=e}let Us=null;function Xp(e){Us=e}const It={};let Qa=null;function bt(e,t,n=500){It[e]&&clearTimeout(It[e]),It[e]=setTimeout(()=>{t(),delete It[e]},n)}function Zp(){const e=tl.subscribe(t=>{if(t){if(t.type==="keeper_heartbeat"&&t.name){const n=new Map(Oo.value);n.set(t.name,t.ts_unix?t.ts_unix*1e3:Date.now()),Oo.value=n;return}(t.type==="agent_joined"||t.type==="agent_left")&&bt("execution",Tt),Cp(t.type)&&(Qa||(Qa=setTimeout(()=>{os(),Ks==null||Ks(),Us==null||Us(),Qa=null},500))),(t.type.startsWith("task_")||t.type.startsWith("masc/task_"))&&bt("execution",Tt),t.type==="broadcast"&&bt("execution",Tt),(t.type==="keeper_handoff"||t.type==="keeper_compaction"||t.type==="keeper_guardrail")&&bt("execution",Tt),(t.type==="board_post"||t.type==="masc/board_post"||t.type==="board_comment"||t.type==="masc/board_comment")&&bt("board",ot),t.type.startsWith("decision_")&&bt("council",()=>Fs==null?void 0:Fs()),(t.type==="mdal_started"||t.type==="mdal_iteration"||t.type==="mdal_completed"||t.type==="mdal_stopped")&&bt("mdal",Nl,350)}});return()=>{e();for(const t of Object.keys(It))clearTimeout(It[t]),delete It[t]}}let In=null;function em(){In||(In=setInterval(()=>{dt.value,os()},1e4))}function tm(){In&&(clearInterval(In),In=null)}const ge=g(null),bi=g(null),qe=g(null),Fn=g(!1),ut=g(null),Kn=g(!1),rn=g(null),J=g(!1),sa=g([]);let nm=1;function sm(e){return v(e)?{id:r(e.id),seq:d(e.seq),from:r(e.from)??r(e.from_agent)??"system",content:r(e.content)??"",timestamp:r(e.timestamp)??new Date().toISOString(),type:r(e.type)}:null}function am(e){return v(e)?{room_id:r(e.room_id),current_room:r(e.current_room)??r(e.room),project:r(e.project),cluster:r(e.cluster),paused:j(e.paused),pause_reason:r(e.pause_reason)??null,paused_by:r(e.paused_by)??null,paused_at:r(e.paused_at)??null}:{}}function lr(e){if(!v(e))return;const t=Object.entries(e).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return t.length>0?Object.fromEntries(t):void 0}function Dl(e){if(!v(e))return null;const t=r(e.kind),n=r(e.summary),s=r(e.target_type);return!t||!n||!s?null:{kind:t,severity:r(e.severity)??"warn",summary:n,target_type:s,target_id:r(e.target_id)??null,actor:r(e.actor)??null,evidence:e.evidence}}function Rn(e){if(!v(e))return null;const t=r(e.action_type),n=r(e.target_type),s=r(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:r(e.target_id)??null,severity:r(e.severity)??"warn",reason:s,confirm_required:j(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function wl(e){return v(e)?{enabled:j(e.enabled),judge_online:j(e.judge_online),refreshing:j(e.refreshing),generated_at:r(e.generated_at)??null,expires_at:r(e.expires_at)??null,model_used:r(e.model_used)??null,keeper_name:r(e.keeper_name)??null,last_error:r(e.last_error)??null}:null}function Ya(e){return v(e)?{summary:r(e.summary)??null,confidence:d(e.confidence)??null,provenance:r(e.provenance)??null,authoritative:j(e.authoritative),surface:r(e.surface)??null,fresh_until:r(e.fresh_until)??null,keeper_name:r(e.keeper_name)??null,fallback_used:j(e.fallback_used),disagreement_with_truth:j(e.disagreement_with_truth)}:null}function om(e){return v(e)?{judgment_id:r(e.judgment_id)??void 0,surface:r(e.surface)??null,target_type:r(e.target_type)??null,target_id:r(e.target_id)??null,status:r(e.status)??null,summary:r(e.summary)??null,confidence:d(e.confidence)??null,generated_at:r(e.generated_at)??null,fresh_until:r(e.fresh_until)??null,keeper_name:r(e.keeper_name)??null,model_name:r(e.model_name)??null,runtime_name:r(e.runtime_name)??null,evidence_refs:F(e.evidence_refs),recommended_action:Rn(e.recommended_action),supersedes:F(e.supersedes),fallback_used:j(e.fallback_used),disagreement_with_truth:j(e.disagreement_with_truth),provenance:r(e.provenance)??null}:null}function im(e){return v(e)?{actor:r(e.actor)??null,spawn_agent:r(e.spawn_agent)??null,spawn_role:r(e.spawn_role)??null,spawn_model:r(e.spawn_model)??null,worker_class:r(e.worker_class)??null,parent_actor:r(e.parent_actor)??null,capsule_mode:r(e.capsule_mode)??null,runtime_pool:r(e.runtime_pool)??null,lane_id:r(e.lane_id)??null,controller_level:r(e.controller_level)??null,control_domain:r(e.control_domain)??null,supervisor_actor:r(e.supervisor_actor)??null,model_tier:r(e.model_tier)??null,task_profile:r(e.task_profile)??null,risk_level:r(e.risk_level)??null,routing_confidence:d(e.routing_confidence)??null,routing_reason:r(e.routing_reason)??null,status:r(e.status)??"unknown",turn_count:d(e.turn_count)??0,empty_note_turn_count:d(e.empty_note_turn_count)??0,has_turn:j(e.has_turn)??!1,last_turn_ts_iso:r(e.last_turn_ts_iso)??null}:null}function rm(e){if(!v(e))return null;const t=r(e.session_id);return t?{session_id:t,goal:r(e.goal),status:r(e.status),health:r(e.health),scale_profile:r(e.scale_profile),control_profile:r(e.control_profile),planned_worker_count:d(e.planned_worker_count),active_agent_count:d(e.active_agent_count),last_turn_age_sec:d(e.last_turn_age_sec)??null,attention_count:d(e.attention_count),recommended_action_count:d(e.recommended_action_count),top_attention:Dl(e.top_attention),top_recommendation:Rn(e.top_recommendation)}:null}function Ol(e){const t=v(e)?e:{};return{trace_id:r(t.trace_id),target_type:r(t.target_type)??"room",target_id:r(t.target_id)??null,health:r(t.health),judgment_owner:r(t.judgment_owner)??null,authoritative_judgment_available:j(t.authoritative_judgment_available),resident_judge_runtime:wl(t.resident_judge_runtime),judgment:om(t.judgment),active_guidance_layer:r(t.active_guidance_layer)??null,active_summary:Ya(t.active_summary),active_recommended_actions:ve(t.active_recommended_actions).map(Rn).filter(n=>n!==null),active_recommendation_source:r(t.active_recommendation_source)??null,active_recommendation_summary:Ya(t.active_recommendation_summary),fallback_recommended_actions:ve(t.fallback_recommended_actions).map(Rn).filter(n=>n!==null),recommendation_summary:Ya(t.recommendation_summary),swarm_status:v(t.swarm_status)?t.swarm_status:void 0,attention_items:ve(t.attention_items).map(Dl).filter(n=>n!==null),recommended_actions:ve(t.recommended_actions).map(Rn).filter(n=>n!==null),session_cards:ve(t.session_cards).map(rm).filter(n=>n!==null),worker_cards:ve(t.worker_cards).map(im).filter(n=>n!==null)}}function lm(e){if(!v(e))return null;const t=v(e.status)?e.status:void 0,n=v(e.summary)?e.summary:v(t==null?void 0:t.summary)?t.summary:void 0,s=v(e.session)?e.session:v(t==null?void 0:t.session)?t.session:void 0,a=r(e.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const i=lr(e.report_paths)??lr(t==null?void 0:t.report_paths),l=ve(e.recent_events,["events"]).filter(v);return{session_id:a,status:r(e.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:d(e.progress_pct)??d(n==null?void 0:n.progress_pct),elapsed_sec:d(e.elapsed_sec)??d(n==null?void 0:n.elapsed_sec),remaining_sec:d(e.remaining_sec)??d(n==null?void 0:n.remaining_sec),done_delta_total:d(e.done_delta_total)??d(n==null?void 0:n.done_delta_total),summary:n,team_health:v(e.team_health)?e.team_health:v(t==null?void 0:t.team_health)?t.team_health:void 0,communication_metrics:v(e.communication_metrics)?e.communication_metrics:v(t==null?void 0:t.communication_metrics)?t.communication_metrics:void 0,orchestration_state:v(e.orchestration_state)?e.orchestration_state:v(t==null?void 0:t.orchestration_state)?t.orchestration_state:void 0,cascade_metrics:v(e.cascade_metrics)?e.cascade_metrics:v(t==null?void 0:t.cascade_metrics)?t.cascade_metrics:void 0,report_paths:i,linked_autoresearch:v(e.linked_autoresearch)?e.linked_autoresearch:v(t==null?void 0:t.linked_autoresearch)?t.linked_autoresearch:void 0,session:s,recent_events:l}}function cr(e){if(!v(e))return null;const t=r(e.name);if(!t)return null;const n=v(e.context)?e.context:void 0;return{name:t,runtime_class:e.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:j(e.desired),resident_registered:j(e.resident_registered),agent_name:r(e.agent_name),status:r(e.status),autonomy_level:r(e.autonomy_level),context_ratio:d(e.context_ratio)??d(n==null?void 0:n.context_ratio),generation:d(e.generation),active_goal_ids:F(e.active_goal_ids),last_autonomous_action_at:r(e.last_autonomous_action_at)??null,last_turn_ago_s:d(e.last_turn_ago_s),model:r(e.model)??r(e.active_model)??r(e.primary_model)}}function cm(e){if(!v(e))return null;const t=r(e.confirm_token)??r(e.token);return t?{confirm_token:t,actor:r(e.actor),action_type:r(e.action_type),target_type:r(e.target_type),target_id:r(e.target_id)??null,delegated_tool:r(e.delegated_tool),created_at:r(e.created_at),preview:e.preview}:null}function ql(e){if(!v(e))return null;const t=r(e.action_type),n=r(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:r(e.description),confirm_required:j(e.confirm_required)}}function dm(e){return v(e)?{actor_filter:r(e.actor_filter)??null,filter_active:j(e.filter_active)??!1,visible_count:d(e.visible_count)??0,total_count:d(e.total_count)??0,hidden_count:d(e.hidden_count)??0,hidden_actors:F(e.hidden_actors),confirm_required_actions:ve(e.confirm_required_actions).map(ql).filter(t=>t!==null)}:null}function um(e){const t=v(e)?e:{};return{room:am(t.room),sessions:ve(t.sessions,["items","sessions"]).map(lm).filter(n=>n!==null),keepers:ve(t.keepers,["items","keepers"]).map(cr).filter(n=>n!==null),resident_judge_runtime:wl(t.resident_judge_runtime),persistent_agents:ve(t.persistent_agents,["items","persistent_agents"]).map(cr).filter(n=>n!==null),recent_messages:ve(t.recent_messages,["messages"]).map(sm).filter(n=>n!==null),pending_confirms:ve(t.pending_confirms,["items","confirms"]).map(cm).filter(n=>n!==null),pending_confirm_summary:dm(t.pending_confirm_summary)??void 0,available_actions:ve(t.available_actions,["actions"]).map(ql).filter(n=>n!==null)}}function Ss(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e)}catch{return String(e)}}function dr(e){return e.target_id?`${e.target_type}:${e.target_id}`:e.target_type}function aa(e){sa.value=[{...e,id:nm++,at:new Date().toISOString()},...sa.value].slice(0,20)}function Fl(e){return e.confirm_required?Ss(e.preview)||"Confirmation required":Ss(e.result)||Ss(e.executed_action)||Ss(e.delegated_tool_result)||e.status}async function ke(){Fn.value=!0,ut.value=null;try{const e=await su();ge.value=um(e)}catch(e){ut.value=e instanceof Error?e.message:"Failed to load operator snapshot"}finally{Fn.value=!1}}async function Mt(){Kn.value=!0,rn.value=null;try{const e=await rl({targetType:"room"});bi.value=Ol(e)}catch(e){rn.value=e instanceof Error?e.message:"Failed to load operator digest"}finally{Kn.value=!1}}async function ln(e){if(!e){qe.value=null;return}Kn.value=!0,rn.value=null;try{const t=await rl({targetType:"team_session",targetId:e,includeWorkers:!0});qe.value=Ol(t)}catch(t){rn.value=t instanceof Error?t.message:"Failed to load session digest"}finally{Kn.value=!1}}async function Kl(e){var t;J.value=!0,ut.value=null;try{const n=await qa(e);return aa({actor:e.actor,action_type:e.action_type,target_label:dr(e),outcome:n.confirm_required?"preview":"executed",message:Fl(n),delegated_tool:n.delegated_tool}),await ke(),await Mt(),(t=qe.value)!=null&&t.target_id&&await ln(qe.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw ut.value=s,aa({actor:e.actor,action_type:e.action_type,target_label:dr(e),outcome:"error",message:s}),n}finally{J.value=!1}}async function Ul(e,t,n="confirm"){var s;J.value=!0,ut.value=null;try{const a=await ll(e,t,n);return aa({actor:e,action_type:n,target_label:t,outcome:"confirmed",message:Fl(a),delegated_tool:a.delegated_tool}),await ke(),await Mt(),(s=qe.value)!=null&&s.target_id&&await ln(qe.value.target_id),a}catch(a){const i=a instanceof Error?a.message:"Operator confirmation failed";throw ut.value=i,aa({actor:e,action_type:"confirm",target_label:t,outcome:"error",message:i}),a}finally{J.value=!1}}Xp(()=>{var e;ke(),Mt(),(e=qe.value)!=null&&e.target_id&&ln(qe.value.target_id)});const is=g(null),Uo=g(!1),oa=g(null),Hl=g(null),Ft=g(!1),Ct=g(null),Ho=g(null),Hs=g(!1),Bs=g(null);let Yt=null;function ur(){Yt!==null&&(window.clearTimeout(Yt),Yt=null)}function pm(e=1500){Yt===null&&(Yt=window.setTimeout(()=>{Yt=null,ia(!1)},e))}function E(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function y(e){return typeof e=="string"&&e.trim()!==""?e:void 0}function N(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function Xt(e){return typeof e=="boolean"?e:void 0}function B(e,t=[]){if(Array.isArray(e))return e;if(!E(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function vn(e){if(!E(e))return null;const t=y(e.kind),n=y(e.summary),s=y(e.target_type);return!t||!n||!s?null:{kind:t,severity:y(e.severity)??"warn",summary:n,target_type:s,target_id:y(e.target_id)??null,actor:y(e.actor)??null,evidence:e.evidence}}function jt(e){if(!E(e))return null;const t=y(e.action_type),n=y(e.target_type),s=y(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:y(e.target_id)??null,severity:y(e.severity)??"warn",reason:s,confirm_required:Xt(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function mm(e){if(!E(e))return null;const t=y(e.session_id);return t?{session_id:t,goal:y(e.goal),status:y(e.status),health:y(e.health),scale_profile:y(e.scale_profile),control_profile:y(e.control_profile),planned_worker_count:N(e.planned_worker_count),active_agent_count:N(e.active_agent_count),last_turn_age_sec:N(e.last_turn_age_sec)??null,attention_count:N(e.attention_count),recommended_action_count:N(e.recommended_action_count),top_attention:vn(e.top_attention),top_recommendation:jt(e.top_recommendation)}:null}function vm(e){if(!E(e))return null;const t=y(e.session_id);if(!t)return null;const n=E(e.status)?e.status:e,s=E(n.summary)?n.summary:void 0;return{session_id:t,status:y(e.status)??y(s==null?void 0:s.status)??(E(n.session)?y(n.session.status):void 0),progress_pct:N(e.progress_pct)??N(s==null?void 0:s.progress_pct),elapsed_sec:N(e.elapsed_sec)??N(s==null?void 0:s.elapsed_sec),remaining_sec:N(e.remaining_sec)??N(s==null?void 0:s.remaining_sec),done_delta_total:N(e.done_delta_total)??N(s==null?void 0:s.done_delta_total),summary:E(e.summary)?e.summary:s,team_health:E(e.team_health)?e.team_health:E(n.team_health)?n.team_health:void 0,communication_metrics:E(e.communication_metrics)?e.communication_metrics:E(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:E(e.orchestration_state)?e.orchestration_state:E(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:E(e.cascade_metrics)?e.cascade_metrics:E(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:E(e.report_paths)?Object.fromEntries(Object.entries(e.report_paths).map(([a,i])=>{const l=y(i);return l?[a,l]:null}).filter(a=>a!==null)):E(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,i])=>{const l=y(i);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:E(e.session)?e.session:E(n.session)?n.session:void 0,recent_events:B(e.recent_events,["events"]).filter(E)}}function _m(e){if(!E(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name),status:y(e.status),autonomy_level:y(e.autonomy_level),context_ratio:N(e.context_ratio),generation:N(e.generation),active_goal_ids:B(e.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:y(e.last_autonomous_action_at)??null,last_turn_ago_s:N(e.last_turn_ago_s),model:y(e.model)}:null}function fm(e){if(!E(e))return null;const t=y(e.confirm_token)??y(e.token);return t?{confirm_token:t,actor:y(e.actor),action_type:y(e.action_type),target_type:y(e.target_type),target_id:y(e.target_id)??null,delegated_tool:y(e.delegated_tool),created_at:y(e.created_at),preview:e.preview}:null}function gm(e){if(!E(e))return null;const t=y(e.action_type),n=y(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:y(e.description),confirm_required:Xt(e.confirm_required)}}function $m(e){const t=E(e)?e:{};return{room_health:y(t.room_health),cluster:y(t.cluster),project:y(t.project),current_room:y(t.current_room)??null,paused:Xt(t.paused),tempo_interval_s:N(t.tempo_interval_s),active_agents:N(t.active_agents),keeper_pressure:N(t.keeper_pressure),active_operations:N(t.active_operations),pending_approvals:N(t.pending_approvals),incident_count:N(t.incident_count),recommended_action_count:N(t.recommended_action_count),top_attention:vn(t.top_attention),top_action:jt(t.top_action)}}function hm(e){const t=E(e)?e:{},n=E(t.swarm_overview)?t.swarm_overview:{};return{health:y(t.health),active_operations:N(t.active_operations),pending_approvals:N(t.pending_approvals),swarm_overview:{active_lanes:N(n.active_lanes),moving_lanes:N(n.moving_lanes),stalled_lanes:N(n.stalled_lanes),projected_lanes:N(n.projected_lanes),last_movement_at:y(n.last_movement_at)??null},top_attention:vn(t.top_attention),top_action:jt(t.top_action),session_cards:B(t.session_cards).map(mm).filter(s=>s!==null)}}function ym(e){const t=E(e)?e:{};return{sessions:B(t.sessions,["items"]).map(vm).filter(n=>n!==null),keepers:B(t.keepers,["items"]).map(_m).filter(n=>n!==null),pending_confirms:B(t.pending_confirms).map(fm).filter(n=>n!==null),available_actions:B(t.available_actions).map(gm).filter(n=>n!==null)}}function bm(e){if(!E(e))return null;const t=y(e.id),n=y(e.kind),s=y(e.summary),a=y(e.target_type);return!t||!n||!s||!a?null:{id:t,kind:n,severity:y(e.severity)??"warn",summary:s,target_type:a,target_id:y(e.target_id)??null,top_action:jt(e.top_action),related_session_ids:B(e.related_session_ids).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),related_agent_names:B(e.related_agent_names).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),evidence_preview:B(e.evidence_preview).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),last_seen_at:y(e.last_seen_at)??null}}function Bl(e){if(!E(e))return null;const t=y(e.session_id),n=y(e.goal);return!t||!n?null:{session_id:t,goal:n,room:y(e.room)??null,status:y(e.status),health:y(e.health),member_names:B(e.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:y(e.started_at)??null,elapsed_sec:N(e.elapsed_sec)??null,operation_id:y(e.operation_id)??null,blocker_summary:y(e.blocker_summary)??null,last_event_at:y(e.last_event_at)??null,last_event_summary:y(e.last_event_summary)??null,communication_summary:y(e.communication_summary)??null,active_count:N(e.active_count),required_count:N(e.required_count),related_attention_count:N(e.related_attention_count)??0,top_attention:vn(e.top_attention),top_recommendation:jt(e.top_recommendation)}}function Wl(e){if(!E(e))return null;const t=y(e.agent_name);return t?{agent_name:t,status:y(e.status),current_work:y(e.current_work)??null,recent_input_preview:y(e.recent_input_preview)??null,recent_output_preview:y(e.recent_output_preview)??null,recent_tool_names:B(e.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_activity_at:y(e.last_activity_at)??null}:null}function Gl(e){if(!E(e))return null;const t=y(e.operation_id);return t?{operation_id:t,status:y(e.status),stage:y(e.stage)??null,detachment_status:y(e.detachment_status)??null,objective:y(e.objective)??null,updated_at:y(e.updated_at)??null}:null}function Jl(e){if(!E(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name)??null,status:y(e.status),generation:N(e.generation),context_ratio:N(e.context_ratio)??null,last_turn_ago_s:N(e.last_turn_ago_s)??null,current_work:y(e.current_work)??null}:null}function Vl(e){const t=Bl(e);return t?{...t,member_previews:B(E(e)?e.member_previews:void 0).map(Wl).filter(n=>n!==null),operation_badges:B(E(e)?e.operation_badges:void 0).map(Gl).filter(n=>n!==null),keeper_refs:B(E(e)?e.keeper_refs:void 0).map(Jl).filter(n=>n!==null)}:null}function km(e){if(!E(e))return null;const t=y(e.agent_name);return t?{agent_name:t,status:y(e.status),where:y(e.where)??null,with_whom:B(e.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:y(e.current_work)??null,related_session_id:y(e.related_session_id)??null,related_attention_count:N(e.related_attention_count)??0,last_activity_at:y(e.last_activity_at)??null,recent_output_preview:y(e.recent_output_preview)??null,recent_input_preview:y(e.recent_input_preview)??null,recent_event:y(e.recent_event)??null,recent_tool_names:B(e.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),allowed_tool_names:B(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:B(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:N(e.latest_tool_call_count)??null,tool_audit_source:y(e.tool_audit_source)??null,tool_audit_at:y(e.tool_audit_at)??null}:null}function xm(e){if(!E(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name)??null,status:y(e.status),generation:N(e.generation),context_ratio:N(e.context_ratio)??null,last_turn_ago_s:N(e.last_turn_ago_s)??null,current_work:y(e.current_work)??null,last_autonomous_action_at:y(e.last_autonomous_action_at)??null,allowed_tool_names:B(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:B(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:N(e.latest_tool_call_count)??null,tool_audit_source:y(e.tool_audit_source)??null,tool_audit_at:y(e.tool_audit_at)??null}:null}function Sm(e){if(!E(e))return null;const t=y(e.id),n=y(e.signal_type),s=y(e.summary),a=y(e.target_type);return!t||!n||!s||!a?null:{id:t,signal_type:n==="action"?"action":"attention",severity:y(e.severity)??"warn",summary:s,target_type:a,target_id:y(e.target_id)??null,attention:vn(e.attention),action:jt(e.action)}}function Cm(e){const t=E(e)?e:{},n=B(t.session_briefs).map(Bl).filter(a=>a!==null),s=B(t.sessions).map(Vl).filter(a=>a!==null);return{generated_at:y(t.generated_at),summary:$m(t.summary),incidents:B(t.incidents).map(vn).filter(a=>a!==null),recommended_actions:B(t.recommended_actions).map(jt).filter(a=>a!==null),command_focus:hm(t.command_focus),operator_targets:ym(t.operator_targets),attention_queue:B(t.attention_queue).map(bm).filter(a=>a!==null),sessions:s.length>0?s:n.map(a=>({...a,member_previews:[],operation_badges:[],keeper_refs:[]})),session_briefs:n,agent_briefs:B(t.agent_briefs).map(km).filter(a=>a!==null),keeper_briefs:B(t.keeper_briefs).map(xm).filter(a=>a!==null),internal_signals:B(t.internal_signals).map(Sm).filter(a=>a!==null)}}function Am(e){if(!E(e))return null;const t=y(e.id),n=y(e.summary);return!t||!n?null:{id:t,timestamp:y(e.timestamp)??null,event_type:y(e.event_type),actor:y(e.actor)??null,summary:n}}function Tm(e){const t=E(e)?e:{};return{generated_at:y(t.generated_at),session_id:y(t.session_id)??"",session:Vl(t.session),timeline:B(t.timeline).map(Am).filter(n=>n!==null),participants:B(t.participants).map(Wl).filter(n=>n!==null),operations:B(t.operations).map(Gl).filter(n=>n!==null),keepers:B(t.keepers).map(Jl).filter(n=>n!==null),error:y(t.error)??null}}function Im(e){if(!E(e))return null;const t=y(e.id),n=y(e.label),s=y(e.summary);if(!t||!n||!s)return null;const a=y(e.status)??"unclear";return{id:t,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:y(e.signal_class)==="metadata_gap"||y(e.signal_class)==="mixed"||y(e.signal_class)==="operational_risk"?y(e.signal_class):void 0,evidence_quality:y(e.evidence_quality)==="strong"||y(e.evidence_quality)==="partial"||y(e.evidence_quality)==="missing"?y(e.evidence_quality):void 0,evidence:B(e.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function Rm(e){if(!E(e))return null;const t=y(e.kind),n=y(e.summary),s=y(e.scope_type),a=y(e.severity);return!t||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:t,summary:n,scope_type:s,scope_id:y(e.scope_id)??null,severity:a}}function Lm(e){const t=E(e)?e:{},n=E(t.basis)?t.basis:{},s=y(t.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:y(t.generated_at),cached:Xt(t.cached),stale:Xt(t.stale),refreshing:Xt(t.refreshing),status:a,summary:y(t.summary)??null,model:y(t.model)??null,ttl_sec:N(t.ttl_sec),criteria:B(t.criteria).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),basis:{current_room:y(n.current_room)??null,crew_count:N(n.crew_count),agent_count:N(n.agent_count),keeper_count:N(n.keeper_count)},metadata_gap_count:N(t.metadata_gap_count),metadata_gaps:B(t.metadata_gaps).map(Rm).filter(i=>i!==null),sections:B(t.sections).map(Im).filter(i=>i!==null),error:y(t.error)??null,last_error:y(t.last_error)??null}}async function Ql(){Uo.value=!0,oa.value=null;try{const e=await Qd();is.value=Cm(e)}catch(e){oa.value=e instanceof Error?e.message:"Failed to load mission snapshot"}finally{Uo.value=!1}}async function zm(e){if(!e){Ho.value=null,Bs.value=null,Hs.value=!1;return}Hs.value=!0,Bs.value=null;try{const t=await Yd(e);Ho.value=Tm(t)}catch(t){Bs.value=t instanceof Error?t.message:"Failed to load session detail"}finally{Hs.value=!1}}async function ia(e=!1){Ft.value=!0,Ct.value=null;try{const t=await Xd(e),n=Lm(t);Hl.value=n,n.refreshing||n.status==="pending"?pm():ur()}catch(t){Ct.value=t instanceof Error?t.message:"Failed to load mission briefing",ur()}finally{Ft.value=!1}}const Yl=g(null),Bo=g(!1),Kt=g(null);async function Xl(e,t){Bo.value=!0,Kt.value=null;try{Yl.value=await Zd(e,t)}catch(n){Kt.value=n instanceof Error?n.message:String(n)}finally{Bo.value=!1}}const ki=g(null),Ke=g(null),ra=g(!1),la=g(!1),ca=g(null),da=g(null),Wo=g(null),ua=g(null),V=g("warroom"),rs=g(null),Go=g(!1),pa=g(null),Et=g(null),ma=g(!1),va=g(null),xi=g(null),Jo=g(!1),_a=g(null),ls=g(null),Vo=g(!1),fa=g(null),Un=g(null),ga=g(!1),Hn=g(null),Zt=g(null);let Sn=null;function Si(e){return e!=="summary"&&e!=="swarm"&&e!=="warroom"&&e!=="orchestra"}function Zl(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,i)=>{e.has(i)||e.set(i,a)}),e}function ec(){const t=Zl().get("run_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function tc(){const t=Zl().get("operation_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function Pm(e){if(v(e))return{policy_class:r(e.policy_class),approval_class:r(e.approval_class),tool_allowlist:F(e.tool_allowlist),model_allowlist:F(e.model_allowlist),requires_human_for:F(e.requires_human_for),autonomy_level:r(e.autonomy_level),escalation_timeout_sec:d(e.escalation_timeout_sec),kill_switch:j(e.kill_switch),frozen:j(e.frozen)}}function Mm(e){if(v(e))return{headcount_cap:d(e.headcount_cap),active_operation_cap:d(e.active_operation_cap),max_cost_usd:d(e.max_cost_usd),max_tokens:d(e.max_tokens)}}function Ci(e){if(!v(e))return null;const t=r(e.unit_id),n=r(e.label),s=r(e.kind);return!t||!n||!s?null:{unit_id:t,label:n,kind:s,parent_unit_id:r(e.parent_unit_id)??null,leader_id:r(e.leader_id)??null,roster:F(e.roster),capability_profile:F(e.capability_profile),source:r(e.source),created_at:r(e.created_at),updated_at:r(e.updated_at),policy:Pm(e.policy),budget:Mm(e.budget)}}function nc(e){if(!v(e))return null;const t=Ci(e.unit);return t?{unit:t,leader_status:r(e.leader_status),roster_total:d(e.roster_total),roster_live:d(e.roster_live),active_operation_count:d(e.active_operation_count),health:r(e.health),reasons:F(e.reasons),children:Array.isArray(e.children)?e.children.map(nc).filter(n=>n!==null):[]}:null}function jm(e){if(v(e))return{total_units:d(e.total_units),company_count:d(e.company_count),platoon_count:d(e.platoon_count),squad_count:d(e.squad_count),leaf_agent_unit_count:d(e.leaf_agent_unit_count),live_agent_count:d(e.live_agent_count),managed_unit_count:d(e.managed_unit_count),active_operation_count:d(e.active_operation_count)}}function sc(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),source:r(t.source),summary:jm(t.summary),units:Array.isArray(t.units)?t.units.map(nc).filter(n=>n!==null):[]}}function Em(e){if(!v(e))return null;const t=r(e.kind),n=r(e.status);return!t||!n?null:{kind:t,chain_id:r(e.chain_id)??null,goal:r(e.goal)??null,run_id:r(e.run_id)??null,status:n,viewer_path:r(e.viewer_path)??null,last_sync_at:r(e.last_sync_at)??null}}function Ua(e){if(!v(e))return null;const t=r(e.operation_id),n=r(e.objective),s=r(e.assigned_unit_id),a=r(e.trace_id),i=r(e.status);return!t||!n||!s||!a||!i?null:{operation_id:t,objective:n,assigned_unit_id:s,autonomy_level:r(e.autonomy_level),policy_class:r(e.policy_class),budget_class:r(e.budget_class),detachment_session_id:r(e.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(e.checkpoint_ref)??null,active_goal_ids:F(e.active_goal_ids),note:r(e.note)??null,created_by:r(e.created_by),source:r(e.source),status:i,chain:Em(e.chain),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function Nm(e){if(!v(e))return null;const t=Ua(e.operation);return t?{operation:t,assigned_unit_label:r(e.assigned_unit_label)}:null}function yn(e){if(v(e))return{tone:r(e.tone),pending_ops:d(e.pending_ops),blocked_ops:d(e.blocked_ops),in_flight_ops:d(e.in_flight_ops),pipeline_stalls:d(e.pipeline_stalls),bus_traffic:d(e.bus_traffic),l1_hit_rate:d(e.l1_hit_rate),invalidation_count:d(e.invalidation_count),current_pending:d(e.current_pending),current_in_flight:d(e.current_in_flight),cdb_wakeups:d(e.cdb_wakeups),total_stolen:d(e.total_stolen),avg_best_score:d(e.avg_best_score),avg_candidate_count:d(e.avg_candidate_count),best_first_operations:d(e.best_first_operations),active_sessions:d(e.active_sessions),commit_rate:d(e.commit_rate),total_speculations:d(e.total_speculations)}}function Dm(e){if(!v(e))return;const t=v(e.pipeline)?e.pipeline:void 0,n=v(e.cache)?e.cache:void 0,s=v(e.ooo)?e.ooo:void 0,a=v(e.speculative)?e.speculative:void 0,i=v(e.search_fabric)?e.search_fabric:void 0,l=v(e.signals)?e.signals:void 0;return{pipeline:t?{total_ops:d(t.total_ops),completed_ops:d(t.completed_ops),stalled_cycles:d(t.stalled_cycles),hazards_detected:d(t.hazards_detected),forwarding_used:d(t.forwarding_used),pipeline_flushes:d(t.pipeline_flushes),ipc:d(t.ipc)}:void 0,cache:n?{total_reads:d(n.total_reads),total_writes:d(n.total_writes),l1_hit_rate:d(n.l1_hit_rate),invalidation_count:d(n.invalidation_count),writeback_count:d(n.writeback_count),bus_traffic:d(n.bus_traffic)}:void 0,ooo:s?{agent_count:d(s.agent_count),total_added:d(s.total_added),total_issued:d(s.total_issued),total_completed:d(s.total_completed),total_stolen:d(s.total_stolen),cdb_wakeups:d(s.cdb_wakeups),stall_cycles:d(s.stall_cycles),global_cdb_events:d(s.global_cdb_events),current_pending:d(s.current_pending),current_in_flight:d(s.current_in_flight)}:void 0,speculative:a?{total_speculations:d(a.total_speculations),total_commits:d(a.total_commits),total_aborts:d(a.total_aborts),commit_rate:d(a.commit_rate),total_fast_calls:d(a.total_fast_calls),total_cost_usd:d(a.total_cost_usd),active_sessions:d(a.active_sessions)}:void 0,search_fabric:i?{total_operations:d(i.total_operations),best_first_operations:d(i.best_first_operations),legacy_operations:d(i.legacy_operations),blocked_operations:d(i.blocked_operations),ready_operations:d(i.ready_operations),research_pipeline_operations:d(i.research_pipeline_operations),avg_candidate_count:d(i.avg_candidate_count),avg_best_score:d(i.avg_best_score),top_stage:r(i.top_stage)??null}:void 0,signals:l?{issue_pressure:yn(l.issue_pressure),cache_contention:yn(l.cache_contention),scheduler_efficiency:yn(l.scheduler_efficiency),routing_confidence:yn(l.routing_confidence),speculative_posture:yn(l.speculative_posture)}:void 0}}function ac(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),paused:d(n.paused),managed:d(n.managed),projected:d(n.projected)}:void 0,microarch:Dm(t.microarch),operations:Array.isArray(t.operations)?t.operations.map(Nm).filter(s=>s!==null):[]}}function oc(e){if(!v(e))return null;const t=r(e.detachment_id),n=r(e.operation_id),s=r(e.assigned_unit_id);return!t||!n||!s?null:{detachment_id:t,operation_id:n,assigned_unit_id:s,leader_id:r(e.leader_id)??null,roster:F(e.roster),session_id:r(e.session_id)??null,checkpoint_ref:r(e.checkpoint_ref)??null,runtime_kind:r(e.runtime_kind)??null,runtime_ref:r(e.runtime_ref)??null,source:r(e.source),status:r(e.status),last_event_at:r(e.last_event_at)??null,last_progress_at:r(e.last_progress_at)??null,heartbeat_deadline:r(e.heartbeat_deadline)??null,created_at:r(e.created_at),updated_at:r(e.updated_at)}}function wm(e){if(!v(e))return null;const t=oc(e.detachment);return t?{detachment:t,assigned_unit_label:r(e.assigned_unit_label),operation:Ua(e.operation)}:null}function ic(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),projected:d(n.projected)}:void 0,detachments:Array.isArray(t.detachments)?t.detachments.map(wm).filter(s=>s!==null):[]}}function Om(e){if(!v(e))return null;const t=r(e.decision_id),n=r(e.trace_id),s=r(e.requested_action),a=r(e.scope_type),i=r(e.scope_id);return!t||!n||!s||!a||!i?null:{decision_id:t,trace_id:n,requested_action:s,scope_type:a,scope_id:i,operation_id:r(e.operation_id)??null,target_unit_id:r(e.target_unit_id)??null,requested_by:r(e.requested_by),status:r(e.status),reason:r(e.reason)??null,source:r(e.source),detail:e.detail,created_at:r(e.created_at),decided_at:r(e.decided_at)??null,expires_at:r(e.expires_at)??null}}function rc(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),pending:d(n.pending),approved:d(n.approved),denied:d(n.denied)}:void 0,decisions:Array.isArray(t.decisions)?t.decisions.map(Om).filter(s=>s!==null):[]}}function qm(e){if(!v(e))return null;const t=Ci(e.unit);return t?{unit:t,roster_total:d(e.roster_total),roster_live:d(e.roster_live),headcount_cap:d(e.headcount_cap),active_operations:d(e.active_operations),active_operation_cap:d(e.active_operation_cap),utilization:d(e.utilization)}:null}function Fm(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),capacity:Array.isArray(t.capacity)?t.capacity.map(qm).filter(n=>n!==null):[]}}function Km(e){if(!v(e))return null;const t=r(e.alert_id);return t?{alert_id:t,severity:r(e.severity),kind:r(e.kind),scope_type:r(e.scope_type),scope_id:r(e.scope_id),title:r(e.title),detail:r(e.detail),timestamp:r(e.timestamp)}:null}function lc(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),bad:d(n.bad),warn:d(n.warn)}:void 0,alerts:Array.isArray(t.alerts)?t.alerts.map(Km).filter(s=>s!==null):[]}}function cc(e){if(!v(e))return null;const t=r(e.event_id),n=r(e.trace_id),s=r(e.event_type);return!t||!n||!s?null:{event_id:t,trace_id:n,event_type:s,operation_id:r(e.operation_id)??null,unit_id:r(e.unit_id)??null,actor:r(e.actor)??null,source:r(e.source),timestamp:r(e.timestamp),detail:e.detail}}function Um(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),events:Array.isArray(t.events)?t.events.map(cc).filter(n=>n!==null):[]}}function Hm(e){if(!v(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s}}function Bm(e){if(!v(e))return null;const t=r(e.lane_id),n=r(e.label),s=r(e.kind),a=r(e.phase),i=r(e.motion_state),l=r(e.source_of_truth),c=r(e.movement_reason),p=r(e.current_step);if(!t||!n||!s||!a||!i||!l||!c||!p)return null;const m=v(e.counts)?e.counts:{};return{lane_id:t,label:n,kind:s,present:j(e.present)??!1,phase:a,motion_state:i,source_of_truth:l,last_movement_at:r(e.last_movement_at)??null,movement_reason:c,current_step:p,blockers:F(e.blockers),counts:{operations:d(m.operations),detachments:d(m.detachments),workers:d(m.workers),approvals:d(m.approvals),alerts:d(m.alerts)},hard_flags:Array.isArray(e.hard_flags)?e.hard_flags.map(Hm).filter(u=>u!==null):[]}}function Wm(e){if(!v(e))return null;const t=r(e.event_id),n=r(e.lane_id),s=r(e.kind),a=r(e.timestamp),i=r(e.title),l=r(e.detail),c=r(e.tone),p=r(e.source);return!t||!n||!s||!a||!i||!l||!c||!p?null:{event_id:t,lane_id:n,kind:s,timestamp:a,title:i,detail:l,tone:c,source:p}}function Gm(e){if(!v(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s,lane_ids:F(e.lane_ids),count:d(e.count)??0}}function Ai(e){if(!v(e))return;const t=v(e.overview)?e.overview:{},n=v(e.gaps)?e.gaps:{},s=v(e.recommended_next_action)?e.recommended_next_action:void 0;return{generated_at:r(e.generated_at),overview:{active_lanes:d(t.active_lanes),moving_lanes:d(t.moving_lanes),stalled_lanes:d(t.stalled_lanes),projected_lanes:d(t.projected_lanes),last_movement_at:r(t.last_movement_at)??null},lanes:Array.isArray(e.lanes)?e.lanes.map(Bm).filter(a=>a!==null):[],timeline:Array.isArray(e.timeline)?e.timeline.map(Wm).filter(a=>a!==null):[],gaps:{count:d(n.count),items:Array.isArray(n.items)?n.items.map(Gm).filter(a=>a!==null):[]},recommended_next_action:s?{tool:r(s.tool)??"masc_operator_snapshot",label:r(s.label)??"Observe operator state",reason:r(s.reason)??"",lane_id:r(s.lane_id)??null}:void 0}}function dc(e){if(!v(e))return;const t=v(e.workers)?e.workers:{},n=j(e.pass);return{status:r(e.status)??"missing",source:r(e.source)??"none",run_id:r(e.run_id)??null,captured_at:r(e.captured_at)??null,...n!==void 0?{pass:n}:{},...d(e.peak_hot_slots)!=null?{peak_hot_slots:d(e.peak_hot_slots)}:{},...d(e.ctx_per_slot)!=null?{ctx_per_slot:d(e.ctx_per_slot)}:{},workers:{expected:d(t.expected),joined:d(t.joined),current_task_bound:d(t.current_task_bound),fresh_heartbeats:d(t.fresh_heartbeats),done:d(t.done),final:d(t.final)},artifact_ref:r(e.artifact_ref)??null,missing_reason:r(e.missing_reason)??null}}function Jm(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),topology:sc(t.topology),operations:ac(t.operations),detachments:ic(t.detachments),alerts:lc(t.alerts),decisions:rc(t.decisions),capacity:Fm(t.capacity),traces:Um(t.traces),swarm_status:Ai(t.swarm_status)}}function Vm(e){const t=v(e)?e:{},n=sc(t.topology),s=ac(t.operations),a=ic(t.detachments),i=lc(t.alerts),l=rc(t.decisions);return{version:r(t.version),generated_at:r(t.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:i.version,generated_at:i.generated_at,summary:i.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:Ai(t.swarm_status),swarm_proof:dc(t.swarm_proof)}}function Qm(e){return v(e)?{chain_id:r(e.chain_id)??null,started_at:d(e.started_at)??null,progress:d(e.progress)??null,elapsed_sec:d(e.elapsed_sec)??null}:null}function uc(e){if(!v(e))return null;const t=r(e.event);return t?{event:t,chain_id:r(e.chain_id)??null,timestamp:r(e.timestamp)??null,duration_ms:d(e.duration_ms)??null,message:r(e.message)??null,tokens:d(e.tokens)??null}:null}function Ym(e){if(!v(e))return null;const t=Ua(e.operation);return t?{operation:t,runtime:Qm(e.runtime),history:uc(e.history),mermaid:r(e.mermaid)??null,preview_run:pc(e.preview_run)}:null}function Xm(e){const t=v(e)?e:{};return{status:r(t.status)??"disconnected",base_url:r(t.base_url)??null,message:r(t.message)??null}}function Zm(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),connection:Xm(t.connection),summary:n?{linked_operations:d(n.linked_operations),active_chains:d(n.active_chains),running_operations:d(n.running_operations),recent_failures:d(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(t.operations)?t.operations.map(Ym).filter(s=>s!==null):[],recent_history:Array.isArray(t.recent_history)?t.recent_history.map(uc).filter(s=>s!==null):[]}}function ev(e){if(!v(e))return null;const t=r(e.id);return t?{id:t,type:r(e.type),status:r(e.status),duration_ms:d(e.duration_ms)??null,error:r(e.error)??null}:null}function pc(e){if(!v(e))return null;const t=r(e.run_id),n=r(e.chain_id);return n?{run_id:t??null,chain_id:n,duration_ms:d(e.duration_ms),success:j(e.success),mermaid:r(e.mermaid),nodes:Array.isArray(e.nodes)?e.nodes.map(ev).filter(s=>s!==null):[]}:null}function tv(e){const t=v(e)?e:{};return{run:pc(t.run)}}function nv(e){if(!v(e))return null;const t=r(e.title),n=r(e.path);return!t||!n?null:{title:t,path:n}}function sv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary);return!t||!n||!s?null:{id:t,title:n,summary:s}}function av(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.tool),a=r(e.summary);return!t||!n||!s||!a?null:{id:t,title:n,tool:s,summary:a,success_signals:F(e.success_signals),pitfalls:F(e.pitfalls)}}function ov(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary),a=r(e.when_to_use);return!t||!n||!s||!a?null:{id:t,title:n,summary:s,when_to_use:a,steps:Array.isArray(e.steps)?e.steps.map(av).filter(i=>i!==null):[]}}function iv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.description);return!t||!n||!s?null:{id:t,title:n,description:s,tools:F(e.tools)}}function rv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.symptom),a=r(e.why),i=r(e.fix_tool),l=r(e.fix_summary);return!t||!n||!s||!a||!i||!l?null:{id:t,title:n,symptom:s,why:a,fix_tool:i,fix_summary:l}}function lv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.path_id),a=r(e.transport);return!t||!n||!s||!a?null:{id:t,title:n,path_id:s,transport:a,request:e.request,response:e.response,notes:F(e.notes)}}function cv(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),docs:Array.isArray(t.docs)?t.docs.map(nv).filter(n=>n!==null):[],concepts:Array.isArray(t.concepts)?t.concepts.map(sv).filter(n=>n!==null):[],golden_paths:Array.isArray(t.golden_paths)?t.golden_paths.map(ov).filter(n=>n!==null):[],tool_groups:Array.isArray(t.tool_groups)?t.tool_groups.map(iv).filter(n=>n!==null):[],pitfalls:Array.isArray(t.pitfalls)?t.pitfalls.map(rv).filter(n=>n!==null):[],examples:Array.isArray(t.examples)?t.examples.map(lv).filter(n=>n!==null):[]}}function dv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.status),a=r(e.detail),i=r(e.next_tool);return!t||!n||!s||!a||!i?null:{id:t,title:n,status:s,detail:a,next_tool:i}}function uv(e){if(!v(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.title),a=r(e.detail),i=r(e.next_tool);return!t||!n||!s||!a||!i?null:{code:t,severity:n,title:s,detail:a,next_tool:i}}function pv(e){if(!v(e))return null;const t=r(e.from),n=r(e.content),s=r(e.timestamp),a=d(e.seq);return!t||!n||!s||a==null?null:{seq:a,from:t,content:n,timestamp:s}}function mv(e){if(!v(e))return null;const t=r(e.name),n=r(e.role),s=r(e.lane),a=r(e.status),i=r(e.claim_marker),l=r(e.done_marker),c=r(e.final_marker);if(!t||!n||!s||!a||!i||!l||!c)return null;const p=(()=>{if(!v(e.last_message))return null;const m=d(e.last_message.seq),u=r(e.last_message.content),f=r(e.last_message.timestamp);return m==null||!u||!f?null:{seq:m,content:u,timestamp:f}})();return{name:t,role:n,lane:s,joined:j(e.joined)??!1,live_presence:j(e.live_presence)??!1,completed:j(e.completed)??!1,status:a,current_task:r(e.current_task)??null,bound_task_id:r(e.bound_task_id)??null,bound_task_title:r(e.bound_task_title)??null,bound_task_status:r(e.bound_task_status)??null,current_task_matches_run:j(e.current_task_matches_run)??!1,squad_member:j(e.squad_member)??!1,detachment_member:j(e.detachment_member)??!1,last_seen:r(e.last_seen)??null,heartbeat_age_sec:d(e.heartbeat_age_sec)??null,heartbeat_fresh:j(e.heartbeat_fresh)??!1,claim_marker_seen:j(e.claim_marker_seen)??!1,done_marker_seen:j(e.done_marker_seen)??!1,final_marker_seen:j(e.final_marker_seen)??!1,claim_marker:i,done_marker:l,final_marker:c,last_message:p}}function vv(e){if(!v(e))return;const t=Array.isArray(e.timeline)?e.timeline.map(n=>{if(!v(n))return null;const s=r(n.timestamp),a=d(n.active_slots);if(!s||a==null)return null;const i=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:i}}).filter(n=>n!==null):[];return{slot_url:r(e.slot_url)??null,provider_base_url:r(e.provider_base_url)??null,provider_reachable:j(e.provider_reachable)??null,provider_status_code:d(e.provider_status_code)??null,provider_model_id:r(e.provider_model_id)??null,actual_model_id:r(e.actual_model_id)??null,expected_slots:d(e.expected_slots),actual_slots:d(e.actual_slots),expected_ctx:d(e.expected_ctx),actual_ctx:d(e.actual_ctx),slot_reachable:j(e.slot_reachable)??null,slot_status_code:d(e.slot_status_code)??null,runtime_blocker:r(e.runtime_blocker)??null,detail:r(e.detail)??null,checked_at:r(e.checked_at)??null,total_slots:d(e.total_slots),ctx_per_slot:d(e.ctx_per_slot),active_slots_now:d(e.active_slots_now),peak_active_slots:d(e.peak_active_slots),sample_count:d(e.sample_count),last_sample_at:r(e.last_sample_at)??null,timeline:t}}function _v(e){if(!v(e))return null;const t=r(e.run_id),n=r(e.status),s=r(e.decided_by),a=r(e.decided_at),i=r(e.reason);if(!t||!n||!s||!a||!i)return null;const l=[];return Array.isArray(e.history)&&e.history.forEach(c=>{if(!v(c))return;const p=r(c.status),m=r(c.decided_by),u=r(c.decided_at),f=r(c.reason);!p||!m||!u||!f||l.push({status:p,decided_by:m,decided_at:u,reason:f,operation_id:r(c.operation_id)??null,detachment_id:r(c.detachment_id)??null,note:r(c.note)??null})}),{run_id:t,status:n,decided_by:s,decided_at:a,reason:i,operation_id:r(e.operation_id)??null,detachment_id:r(e.detachment_id)??null,note:r(e.note)??null,history:l}}function fv(e){if(!v(e))return null;const t=r(e.run_id),n=r(e.recommended_kind),s=r(e.reason);return!t||!n||!s?null:{run_id:t,recommended_kind:n,continue_available:j(e.continue_available)??!1,rerun_available:j(e.rerun_available)??!1,abandon_available:j(e.abandon_available)??!1,reason:s,evidence:v(e.evidence)?{operation_id:r(e.evidence.operation_id)??null,detachment_id:r(e.evidence.detachment_id)??null,joined_workers:d(e.evidence.joined_workers),current_task_bound:d(e.evidence.current_task_bound),fresh_heartbeats:d(e.evidence.fresh_heartbeats),trace_events:d(e.evidence.trace_events),message_events:d(e.evidence.message_events),runtime_blocker:r(e.evidence.runtime_blocker)??null}:void 0,provenance:r(e.provenance),decision_engine:r(e.decision_engine),authoritative:j(e.authoritative)}}function gv(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),run_id:r(t.run_id),room_id:r(t.room_id),operation_id:r(t.operation_id)??null,run_resolution:_v(t.run_resolution),resolution_recommendation:fv(t.resolution_recommendation),recommended_next_tool:r(t.recommended_next_tool),summary:n?{expected_workers:d(n.expected_workers),joined_workers:d(n.joined_workers),live_workers:d(n.live_workers),squad_roster_size:d(n.squad_roster_size),detachment_roster_size:d(n.detachment_roster_size),current_task_bound:d(n.current_task_bound),fresh_heartbeats:d(n.fresh_heartbeats),claim_markers_seen:d(n.claim_markers_seen),done_markers_seen:d(n.done_markers_seen),final_markers_seen:d(n.final_markers_seen),completed_workers:d(n.completed_workers),peak_hot_slots:d(n.peak_hot_slots),hot_window_ok:j(n.hot_window_ok),pass_hot_concurrency:j(n.pass_hot_concurrency),pass_end_to_end:j(n.pass_end_to_end),pending_decisions:d(n.pending_decisions),pass:j(n.pass)}:void 0,provider:vv(t.provider),operation:Ua(t.operation),squad:Ci(t.squad),detachment:oc(t.detachment),workers:Array.isArray(t.workers)?t.workers.map(mv).filter(s=>s!==null):[],checklist:Array.isArray(t.checklist)?t.checklist.map(dv).filter(s=>s!==null):[],blockers:Array.isArray(t.blockers)?t.blockers.map(uv).filter(s=>s!==null):[],recent_messages:Array.isArray(t.recent_messages)?t.recent_messages.map(pv).filter(s=>s!==null):[],recent_trace_events:Array.isArray(t.recent_trace_events)?t.recent_trace_events.map(cc).filter(s=>s!==null):[],truth_notes:F(t.truth_notes)}}function $v(e){if(!v(e))return null;const t=r(e.label),n=r(e.value);return!t||!n?null:{label:t,value:n}}function hv(e){if(!v(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.label),a=r(e.tone),i=r(e.provenance);return!t||!n||!s||!a||!i?null:{id:t,kind:n,label:s,subtitle:r(e.subtitle)??null,status:r(e.status)??null,tone:a,pulse:r(e.pulse)??null,provenance:i,visual_class:r(e.visual_class)??void 0,glyph:r(e.glyph)??void 0,parent_id:r(e.parent_id)??null,lane_id:r(e.lane_id)??null,link_tab:r(e.link_tab)??null,link_surface:r(e.link_surface)??null,link_params:v(e.link_params)?Object.fromEntries(Object.entries(e.link_params).map(([l,c])=>{const p=r(c);return p?[l,p]:null}).filter(l=>l!==null)):{},facts:Array.isArray(e.facts)?e.facts.map($v).filter(l=>l!==null):[]}}function yv(e){if(!v(e))return null;const t=r(e.id),n=r(e.source),s=r(e.target),a=r(e.kind),i=r(e.tone),l=r(e.provenance);return!t||!n||!s||!a||!i||!l?null:{id:t,source:n,target:s,kind:a,label:r(e.label)??null,tone:i,provenance:l,animated:j(e.animated)}}function bv(e){if(!v(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.label),a=r(e.tone),i=r(e.provenance);return!t||!n||!s||!a||!i?null:{id:t,kind:n,label:s,detail:r(e.detail)??null,tone:a,provenance:i,source_id:r(e.source_id)??null,target_id:r(e.target_id)??null,suggested_surface:r(e.suggested_surface)??null,suggested_params:v(e.suggested_params)?Object.fromEntries(Object.entries(e.suggested_params).map(([l,c])=>{const p=r(c);return p?[l,p]:null}).filter(l=>l!==null)):{}}}function kv(e){if(!v(e))return null;const t=r(e.target_kind),n=r(e.target_id),s=r(e.label),a=r(e.reason);return!t||!n||!s||!a?null:{target_kind:t,target_id:n,label:s,reason:a,suggested_surface:r(e.suggested_surface)??null,suggested_params:v(e.suggested_params)?Object.fromEntries(Object.entries(e.suggested_params).map(([i,l])=>{const c=r(l);return c?[i,c]:null}).filter(i=>i!==null)):{}}}function xv(e){const t=v(e)?e:{},n=v(t.room)?t.room:{},s=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),room:{room_id:r(n.room_id),project:r(n.project),cluster:r(n.cluster),paused:j(n.paused),pause_reason:r(n.pause_reason)??null,agent_count:d(n.agent_count),task_count:d(n.task_count),message_count:d(n.message_count)},summary:s?{session_count:d(s.session_count),operation_count:d(s.operation_count),detachment_count:d(s.detachment_count),lane_count:d(s.lane_count),worker_count:d(s.worker_count),keeper_count:d(s.keeper_count),signal_count:d(s.signal_count),alert_count:d(s.alert_count)}:void 0,nodes:Array.isArray(t.nodes)?t.nodes.map(hv).filter(a=>a!==null):[],edges:Array.isArray(t.edges)?t.edges.map(yv).filter(a=>a!==null):[],signals:Array.isArray(t.signals)?t.signals.map(bv).filter(a=>a!==null):[],focus:kv(t.focus),swarm_status:Ai(t.swarm_status),swarm_proof:dc(t.swarm_proof),truth_notes:F(t.truth_notes)}}function rt(e){V.value=e,Si(e)&&Sv()}async function mc(){ra.value=!0,ca.value=null;try{const e=await ou();ki.value=Vm(e)}catch(e){ca.value=e instanceof Error?e.message:"Failed to load command-plane summary"}finally{ra.value=!1}}function Ti(e){Zt.value=e}async function Ii(){la.value=!0,da.value=null;try{const e=await au();Ke.value=Jm(e)}catch(e){da.value=e instanceof Error?e.message:"Failed to load command-plane snapshot"}finally{la.value=!1}}async function Sv(){Ke.value||la.value||await Ii()}async function Ut(){await mc(),Si(V.value)&&await Ii()}async function en(){var e;Vo.value=!0,fa.value=null;try{const t=await iu(),n=Zm(t);ls.value=n;const s=Zt.value;n.operations.length===0?Zt.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Zt.value=((e=n.operations[0])==null?void 0:e.operation.operation_id)??null)}catch(t){fa.value=t instanceof Error?t.message:"Failed to load chain summary"}finally{Vo.value=!1}}function Cv(){Sn=null,Un.value=null,ga.value=!1,Hn.value=null}async function Av(e){Sn=e,ga.value=!0,Hn.value=null;try{const t=await ru(e);if(Sn!==e)return;Un.value=tv(t)}catch(t){if(Sn!==e)return;Un.value=null,Hn.value=t instanceof Error?t.message:"Failed to load chain run"}finally{Sn===e&&(ga.value=!1)}}async function Tv(){Go.value=!0,pa.value=null;try{const e=await lu();rs.value=cv(e)}catch(e){pa.value=e instanceof Error?e.message:"Failed to load command-plane help"}finally{Go.value=!1}}async function tt(e=ec(),t=tc()){ma.value=!0,va.value=null;try{const n=await cu(e,t);Et.value=gv(n)}catch(n){va.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{ma.value=!1}}async function Rt(e=ec(),t=tc()){Jo.value=!0,_a.value=null;try{const n=await du(e,t);xi.value=xv(n)}catch(n){_a.value=n instanceof Error?n.message:"Failed to load orchestra map"}finally{Jo.value=!1}}async function ft(e,t,n){Wo.value=e,ua.value=null;try{await uu(t,n),await mc(),(Ke.value||Si(V.value))&&await Ii(),await tt(),await Rt(),await en()}catch(s){throw ua.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{Wo.value=null}}function Iv(e){return ft(`pause:${e}`,"/api/v1/command-plane/operations/pause",{operation_id:e})}function Rv(e){return ft(`resume:${e}`,"/api/v1/command-plane/operations/resume",{operation_id:e})}function Lv(e){return ft(`recall:${e}`,"/api/v1/command-plane/dispatch/recall",{operation_id:e})}function zv(e={}){return ft("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...e.operationId?{operation_id:e.operationId}:{},...e.detachmentId?{detachment_id:e.detachmentId}:{}})}function Pv(e){return ft(`approve:${e}`,"/api/v1/command-plane/policy/approve",{decision_id:e})}function Mv(e){return ft(`deny:${e}`,"/api/v1/command-plane/policy/deny",{decision_id:e})}function jv(e,t){return ft(`freeze:${e}`,"/api/v1/command-plane/policy/freeze",{unit_id:e,enabled:t})}function Ev(e,t){return ft(`kill:${e}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:e,enabled:t})}Yp(()=>{Ut(),en(),(V.value==="swarm"||V.value==="warroom"||V.value==="orchestra"||Et.value!==null)&&tt(),(V.value==="orchestra"||xi.value!==null)&&Rt(),V.value==="warroom"&&ke()});function Qo(e){e==="command"&&(Ut(),en(),(V.value==="swarm"||V.value==="warroom"||V.value==="orchestra")&&tt(),V.value==="orchestra"&&Rt(),V.value==="warroom"&&ke()),e==="mission"&&(Ql(),ia()),e==="proof"&&Xl(D.value.params.session_id,D.value.params.operation_id),e==="execution"&&Tt(),e==="intervene"&&(ke(),Mt()),e==="memory"&&ot(),e==="planning"&&yi(),e==="lab"&&it()}function Nv({metric:e}){return o`
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
  `}function Dv({panel:e}){return o`
    <div class="semantic-body">
      <div class="semantic-grid">
        <span>목적</span><span>${e.purpose}</span>
        <span>무엇을 푸나</span><span>${e.problem_solved}</span>
        <span>언제 보나</span><span>${e.when_active}</span>
        <span>에이전트 역할</span><span>${e.agent_role}</span>
        <span>생태계 기능</span><span>${e.ecosystem_function}</span>
      </div>
      ${e.related_tools.length>0?o`<div class="semantic-tag-row">
            ${e.related_tools.map(t=>o`<span class="semantic-tag">${t}</span>`)}
          </div>`:null}
      ${e.metrics.length>0?o`<div class="semantic-metric-list">
            ${e.metrics.map(t=>o`<${Nv} key=${t.id} metric=${t} />`)}
          </div>`:null}
    </div>
  `}function w({panelId:e,compact:t=!1,label:n="왜 필요한가"}){const s=Jp(e);return s?o`
    <details class="semantic-inline ${t?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${Dv} panel=${s} />
    </details>
  `:ta.value?o`<span class="semantic-inline-state">의미 계층 불러오는 중…</span>`:null}function xe({surfaceId:e,compact:t=!1}){const n=Gp(e);return n?o`
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
      ${n.panels.length>0?o`<div class="semantic-tag-row">
            ${n.panels.map(s=>o`<span class="semantic-tag">${s.title}</span>`)}
          </div>`:null}
    </section>
  `:ta.value?o`<div class="semantic-surface-card ${t?"compact":""}">의미 계층 불러오는 중…</div>`:na.value?o`<div class="semantic-surface-card ${t?"compact":""}">${na.value}</div>`:null}function I({title:e,class:t,semanticId:n,testId:s,children:a}){return o`
    <div class="card ${t??""}" data-testid=${s}>
      ${e?o`
            <div class="card-title-row">
              <div class="card-title">${e}</div>
              ${n?o`<${w} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}const $a="masc_dashboard_workflow_context",wv=900*1e3;function he(e){return typeof e=="string"&&e.trim()!==""?e.trim():null}function Xe(e){const t=he(e);return t||(typeof e=="number"&&Number.isFinite(e)?String(e):null)}function vc(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function Yo(e){return v(e)?e:null}function Ov(e){if(!e)return null;try{return JSON.stringify(e)}catch{return null}}function qv(e){if(!e)return null;try{const t=JSON.parse(e);if(!v(t))return null;const n=he(t.id),s=he(t.source_surface),a=he(t.source_label),i=he(t.summary),l=he(t.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!i||!l?null:{id:n,source_surface:s,source_label:a,action_type:he(t.action_type),target_type:he(t.target_type),target_id:he(t.target_id),focus_kind:he(t.focus_kind),operation_id:he(t.operation_id),command_surface:he(t.command_surface),summary:i,payload_preview:he(t.payload_preview),suggested_payload:Yo(t.suggested_payload),preview:t.preview??null,evidence:t.evidence??null,created_at:l}}catch{return null}}function Ri(e){const t=Date.parse(e.created_at);return Number.isNaN(t)?!1:Date.now()-t<=wv}function Fv(){const e=vc(),t=qv((e==null?void 0:e.getItem($a))??null);return t?Ri(t)?t:(e==null||e.removeItem($a),null):null}const _c=g(Fv());function fc(e){const t=e&&Ri(e)?e:null;_c.value=t;const n=vc();if(!n)return;if(!t){n.removeItem($a);return}const s=Ov(t);s&&n.setItem($a,s)}function Kv(e){if(!e)return null;const t=Yo(e.suggested_payload);if(t)return t;if(v(e.preview)){const n=Yo(e.preview.payload);if(n)return n}return null}function Uv(e){if(!e)return null;const t=Xe(e.message);if(t)return t;const n=Xe(e.task_title)??Xe(e.title),s=Xe(e.task_description)??Xe(e.description),a=Xe(e.reason),i=Xe(e.priority)??Xe(e.task_priority);return n&&s?`${n} · ${s}`:n&&i?`${n} · P${i}`:n||s||a||null}function Li(e,t,n,s,a,i,l,c){return[e,t,n??"action",s??"target",a??"room",i??"focus",l??"operation",c].join(":")}function _n(e,t,n="상황판 추천 액션"){const s=new Date().toISOString(),a=Kv(e),i=(e==null?void 0:e.target_type)??(t==null?void 0:t.target_type)??null,l=(e==null?void 0:e.target_id)??(t==null?void 0:t.target_id)??null,c=(t==null?void 0:t.kind)??(e==null?void 0:e.action_type)??null,p=(e==null?void 0:e.reason)??(t==null?void 0:t.summary)??n;return{id:Li("mission",n,(e==null?void 0:e.action_type)??null,i,l,c,null,s),source_surface:"mission",source_label:n,action_type:(e==null?void 0:e.action_type)??null,target_type:i,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:p,payload_preview:Uv(a),suggested_payload:a,preview:(e==null?void 0:e.preview)??null,evidence:(t==null?void 0:t.evidence)??null,created_at:s}}function Hv({targetType:e,targetId:t,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:i=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:Li("execution",s,null,e,t,n,i,c),source_surface:"execution",source_label:s,action_type:null,target_type:e,target_id:t,focus_kind:n,operation_id:i,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function Bv(e,t){return(t.source==="mission"||t.source==="execution")&&(t.action_type??null)===(e.action_type??null)&&(t.target_type??null)===(e.target_type??null)&&(t.target_id??null)===(e.target_id??null)&&(t.focus_kind??null)===(e.focus_kind??null)&&(t.operation_id??null)===(e.operation_id??null)}function cs(e){const{params:t}=e;if(t.source!=="mission"&&t.source!=="execution")return null;const n=_c.value;if(n&&Ri(n)&&Bv(n,t))return n;const s=new Date().toISOString(),a=t.source==="execution"?"execution":"mission";return{id:Li(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",t.action_type??null,t.target_type??null,t.target_id??null,t.focus_kind??null,t.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:t.action_type??null,target_type:t.target_type??null,target_id:t.target_id??null,focus_kind:t.focus_kind??t.action_type??null,operation_id:t.operation_id??null,command_surface:t.surface??null,summary:a==="execution"?t.focus_kind?`${t.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":t.focus_kind?`${t.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function gc(e){return{source:e.source_surface,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function $c(e){if(e.command_surface)return e.command_surface;const t=[e.focus_kind,e.summary,e.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"summary":t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")||t.includes("swarm")?"swarm":e.focus_kind==="operation"||e.target_type==="operation"?"operations":e.target_type==="room"?"orchestra":"swarm"}function hc(e){return{source:e.source_surface,surface:$c(e),...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function Wv(e){return gc(e)}function Gv(e){return hc(e)}function zi(e){return e!=null&&e.target_type?e.target_id?`${e.target_type} · ${e.target_id}`:e.target_type:"대상 정보 없음"}function Ha(e){switch(e){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(e==null?void 0:e.trim())||"추천 액션"}}function Jv(e){switch(e){case"warroom":return"워룸";case"summary":return"요약";case"orchestra":return"오케스트라";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(e==null?void 0:e.trim())||"지휘"}}const We=g(null),nt=g(null);function Me(e,t=120){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-1)}…`:n:null}function fe(e){return e==="bad"||e==="offline"||e==="critical"||e==="risk"?"bad":e==="warn"||e==="pending"||e==="degraded"||e==="interrupted"||e==="watch"?"warn":"ok"}function Oe(e){if(!e)return"방금";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function Vv(e){return typeof e!="number"||!Number.isFinite(e)||e<0?"확인 필요":e<60?`${Math.round(e)}초`:e<3600?`${Math.round(e/60)}분`:e<86400?`${Math.round(e/3600)}시간`:`${Math.round(e/86400)}일`}function Le(e){switch((e??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"pending":return"대기 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":case"watch":return"주의";case"bad":case"critical":case"risk":return"위험";case"degraded":return"저하";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"loading":return"불러오는 중";case"error":return"오류";case"unavailable":return"사용 불가";case"stale":return"오래됨";case"refreshing":return"갱신 중";case"cached":return"캐시";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function ha(e){switch((e??"").trim().toLowerCase()){case"room":return"방";case"team_session":case"session":return"세션";case"operation":return"작전";case"keeper":return"키퍼";case"agent":return"에이전트";default:return(e==null?void 0:e.trim())||"대상"}}function pr(e){switch((e??"").trim().toLowerCase()){case"metadata_gap":return"메타데이터 부족";case"mixed":return"신호 혼재";case"":return null;default:return(e==null?void 0:e.trim())||null}}function Qv(e){return e!=null&&e.confirm_required?"확인 후 실행":"즉시 실행"}function Yv(e){return zi(e?_n(e,null,"상황판 추천 액션"):null)}function Ba(e,t=_n()){fc(t),ie(e,e==="intervene"?Wv(t):Gv(t))}function yc(e){Ba("intervene",_n(null,e,"상황판 incident"))}function bc(e){Ba("command",_n(null,e,"상황판 incident"))}function Pi(e,t,n="상황판 추천 액션"){Ba("intervene",_n(e,t,n))}function kc(e,t,n="상황판 추천 액션"){Ba("command",_n(e,t,n))}function Xo(e,t){const n={source:"mission",target_type:"team_session",target_id:t,focus_kind:"team_session"};e==="command"&&(n.surface="swarm"),ie(e,n)}function Xv(e){return{kind:e.kind,severity:e.severity,summary:e.summary,target_type:e.target_type,target_id:e.target_id??null,actor:null,evidence:e.evidence_preview}}function Zv(e){var n,s;const t=_t.value.find(a=>a.name===e.name||a.agent_name===e.agent_name)??null;return{brief:e,keeper:t,currentWork:Me(e.current_work,110)??Me(t==null?void 0:t.skill_primary,110)??Me(t==null?void 0:t.last_proactive_reason,110)??"명시된 키퍼 초점 없음",recentInput:Me(t==null?void 0:t.recent_input_preview,120)??null,recentOutput:Me(t==null?void 0:t.recent_output_preview,120)??Me((n=t==null?void 0:t.diagnostic)==null?void 0:n.last_reply_preview,120)??Me(t==null?void 0:t.last_proactive_preview,120)??null,recentEvent:Me(t==null?void 0:t.last_proactive_reason,120)??Me((s=t==null?void 0:t.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(t==null?void 0:t.recent_tool_names)??[]}}function e_(){const e=is.value;if(!e)return new Map;const t=e.sessions.length>0?e.sessions:e.session_briefs;return new Map(t.map(n=>[n.session_id,n]))}function t_(e){We.value=We.value===e?null:e,nt.value=null}function xc(e){nt.value=nt.value===e?null:e,We.value=null}function n_(){We.value=null,nt.value=null}function Xa(e){return(e==null?void 0:e.trim().toLowerCase())??""}function ds(e){var t,n;return e?((t=e.agent)==null?void 0:t.exists)===!1||Xa((n=e.diagnostic)==null?void 0:n.health_state)==="offline"||Xa(e.status)==="offline"||Xa(e.status)==="inactive"?"offline":"online":"unlinked"}function Ge(e){switch(e){case"offline":return"offline";case"none_recent":return"none_recent";case"not_applicable":return"not_applicable";case"unlinked":return"unlinked";default:return"not_collected"}}function Sc(e){const t=ds(e);return t==="unlinked"?"unlinked":t==="offline"?"offline":"not_collected"}function Cc(e,t){const n=ds(e);return n==="unlinked"?"unlinked":n==="offline"?"offline":t!=null&&t.trim()?"none_recent":"not_collected"}function Ac(e,t){const n=ds(e);return n==="unlinked"?"unlinked":n==="offline"?"offline":t!=null&&t.trim()?"none_recent":"not_collected"}function Mi(e){const t=ds(e);return t==="unlinked"?"unlinked":t==="offline"?"offline":"none_recent"}function Tc(e){const t=e==null?void 0:e.trim();ie("tools",t?{q:t}:void 0)}function s_(e){switch(e.trim().toLowerCase()){case"active":case"running":return"가동 중";case"working":return"작업 중";case"watching":return"관찰 중";case"quiet":return"조용함";case"idle":return"유휴";case"ok":case"healthy":return"정상";case"warn":case"warning":case"degraded":return"주의";case"bad":case"critical":case"error":case"failed":return"위험";case"blocked":return"막힘";case"paused":return"일시정지";case"pending":return"대기";case"offline":case"inactive":return"오프라인";case"connected":return"연결됨";case"disconnected":return"끊김";case"ready":return"준비됨";case"done":case"completed":return"완료";case"unknown":return"알 수 없음";default:return e}}function gt({status:e,label:t}){return o`
    <span class="status-badge ${e}">
      <span class="status-dot-inline ${e}"></span>
      ${t??s_(e)}
    </span>
  `}function Ic(e){const t=Date.now(),n=typeof e=="number"?e<1e12?e*1e3:e:new Date(e).getTime(),s=Math.floor((t-n)/1e3);if(s<60)return`${s}초 전`;const a=Math.floor(s/60);if(a<60)return`${a}분 전`;const i=Math.floor(a/60);return i<24?`${i}시간 전`:`${Math.floor(i/24)}일 전`}function G({timestamp:e}){const t=Ic(e),n=typeof e=="string"?e:new Date(e<1e12?e*1e3:e).toISOString();return o`<span class="time-ago" title=${n}>${t}</span>`}let a_=0;const Lt=g([]);function M(e,t="success",n=4e3){const s=++a_;Lt.value=[...Lt.value,{id:s,message:e,type:t}],setTimeout(()=>{Lt.value=Lt.value.filter(a=>a.id!==s)},n)}function o_(e){Lt.value=Lt.value.filter(t=>t.id!==e)}function i_(){const e=Lt.value;return e.length===0?null:o`
    <div class="toast-container">
      ${e.map(t=>o`
        <div key=${t.id} class="toast ${t.type}" onClick=${()=>o_(t.id)}>
          ${t.message}
        </div>
      `)}
    </div>
  `}const r_="masc_dashboard_agent_name",fn=g(null),ya=g(!1),Bn=g(""),ba=g([]),Wn=g([]),tn=g(""),Ln=g(!1);function us(e){fn.value=e,ji()}function mr(){fn.value=null,Bn.value="",ba.value=[],Wn.value=[],tn.value=""}function l_(){const e=fn.value;return e?Ye.value.find(t=>t.name===e)??null:null}function Rc(e){return e?st.value.filter(t=>t.assignee===e):[]}function Lc(e){return e?_t.value.find(t=>t.agent_name===e||t.name===e)??null:null}function c_(e){if(!e)return null;const t=is.value;return t?t.agent_briefs.find(n=>n.agent_name===e)??null:null}function d_(e){if(!e)return[];const t=e.metrics_window;return(Array.isArray(t==null?void 0:t.top_tools)?t.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function u_(e){const t=Lc(e);return t?t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]:[]}function vr(...e){for(const t of e)if(t&&t.length>0)return t;return[]}function p_(e){return e?fi.value.find(t=>t.agent_name===e||t.name===e)??null:null}function m_(e){return e?_i.value.find(t=>t.agent_name===e||t.worker_name===e)??null:null}async function ji(){const e=fn.value;if(e){ya.value=!0,Bn.value="",ba.value=[],Wn.value=[];try{const t=await Bu(80);ba.value=t.filter(a=>a.includes(e)).slice(0,20);const n=Rc(e).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await Wu(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const l=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));Wn.value=s}catch(t){Bn.value=t instanceof Error?t.message:"Failed to load agent detail"}finally{ya.value=!1}}}async function _r(){var s;const e=fn.value,t=tn.value.trim();if(!e||!t)return;const n=((s=localStorage.getItem(r_))==null?void 0:s.trim())||"dashboard";Ln.value=!0;try{await Hu(n,`@${e} ${t}`),tn.value="",M(`Mention sent to ${e}`,"success"),ji()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";M(i,"error")}finally{Ln.value=!1}}function v_({task:e}){return o`
    <div class="agent-detail-task">
      <span class="pill">${e.id}</span>
      <span class="agent-detail-task-title">${e.title}</span>
      <${gt} status=${e.status} />
    </div>
  `}function __({row:e}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${e.taskId}</span>
      </div>
      <pre class="agent-history-pre">${e.text||"No task history yet"}</pre>
    </div>
  `}function f_(){var Q,Z,ae,W,ee,A,te;const e=fn.value;if(!e)return null;const t=l_(),n=Lc(e),s=p_(e),a=m_(e),i=c_(e),l=Rc(e),c=ba.value,p=u_(e),m=d_(n),u=vr(s==null?void 0:s.allowed_tool_names,i==null?void 0:i.allowed_tool_names,a==null?void 0:a.allowed_tool_names,n==null?void 0:n.allowed_tool_names),f=vr(s==null?void 0:s.latest_tool_names,i==null?void 0:i.latest_tool_names,a==null?void 0:a.used_tool_names,n==null?void 0:n.latest_tool_names),_=(s==null?void 0:s.latest_tool_call_count)??(i==null?void 0:i.latest_tool_call_count)??(a==null?void 0:a.used_tool_call_count)??(n==null?void 0:n.latest_tool_call_count),h=(s==null?void 0:s.tool_audit_source)??(i==null?void 0:i.tool_audit_source)??(a==null?void 0:a.tool_audit_source)??(n==null?void 0:n.tool_audit_source),b=(s==null?void 0:s.tool_audit_at)??(i==null?void 0:i.tool_audit_at)??(a==null?void 0:a.tool_audit_at)??(n==null?void 0:n.tool_audit_at),C=(t==null?void 0:t.capabilities)??[],S=((Q=oe.value)==null?void 0:Q.room)??"default",T=((Z=oe.value)==null?void 0:Z.project)??"확인 없음",$=((ae=oe.value)==null?void 0:ae.cluster)??"확인 없음",x=Ge(Sc(n)),R=Ge(Cc(n,h)),z=Ge(Ac(n,h)),q=Ge(Mi(n)),L=u[0]??f[0]??p[0]??null;return o`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${U=>{U.target.classList.contains("agent-detail-overlay")&&mr()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${t!=null&&t.emoji?o`<span style="font-size:2rem">${t.emoji}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${e}
                  ${t!=null&&t.koreanName?o`<span style="font-size:0.75em;color:#888">(${t.koreanName})</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  ${t?o`
                        <${gt} status=${t.status} />
                        ${t.model?o`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${t.model}</span>`:""}
                        ${t.primaryValue?o`<span style="font-size:0.75rem;color:#a78bfa">${t.primaryValue}</span>`:""}
                      `:o`<span>Agent snapshot not found in current state</span>`}
                </div>
              </div>
            </div>
            ${(t==null?void 0:t.activityLevel)!=null?o`
              <div style="display:flex;align-items:center;gap:8px;font-size:0.8rem">
                <span style="color:#888">Activity</span>
                <div style="flex:1;max-width:120px;height:6px;background:#1a1a2e;border-radius:3px;overflow:hidden">
                  <div style="width:${Math.min(t.activityLevel*10,100)}%;height:100%;background:${t.activityLevel>=8?"#22c55e":t.activityLevel>=5?"#f59e0b":"#666"};border-radius:3px"></div>
                </div>
                <span style="color:#888">${t.activityLevel}/10</span>
              </div>
            `:""}
            ${(((W=t==null?void 0:t.traits)==null?void 0:W.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(ee=t==null?void 0:t.traits)==null?void 0:ee.map(U=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${U}</span>`)}
              </div>
            `:""}
            ${(((A=t==null?void 0:t.interests)==null?void 0:A.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(te=t==null?void 0:t.interests)==null?void 0:te.map(U=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${U}</span>`)}
              </div>
            `:""}
            ${C.length>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${C.map(U=>o`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${U}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${t?o`
                    ${t.current_task?o`<span>Task: ${t.current_task}</span>`:null}
                    ${t.last_seen?o`<span>Last seen: <${G} timestamp=${t.last_seen} /></span>`:null}
                    <span>Room: ${S}</span>
                    <span>Project: ${T}</span>
                    <span>Cluster: ${$}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{ji()}} disabled=${ya.value}>
              ${ya.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${mr}>Close</button>
          </div>
        </div>

        ${Bn.value?o`<div class="council-error">${Bn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${I} title="Assigned Tasks">
            ${l.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${l.map(U=>o`<${v_} key=${U.id} task=${U} />`)}</div>`}
          <//>

          <${I} title="Recent Activity">
            ${c.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${c.map((U,Ue)=>o`<div key=${Ue} class="agent-activity-line">${U}</div>`)}</div>`}
          <//>
        </div>

        <${I} title="Capabilities & Tool Audit">
          <div style="display:flex; flex-direction:column; gap:12px;">
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Capabilities</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${C.length>0?C.map(U=>o`<span class="pill">${U}</span>`):o`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
              </div>
            </div>
            <div style="display:flex; justify-content:flex-end;">
              <button class="control-btn ghost" onClick=${()=>{Tc(L)}}>
                Open tools panel
              </button>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Allowed tools</div>
              <div style="font-size:11px; color:#64748b; margin-bottom:6px;">Currently permitted tools for this runtime, not the full system inventory.</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${u.length>0?u.map(U=>o`<span class="pill">${U}</span>`):o`<span class="empty-state" style="font-size:12px;">${x}</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Observed tools</div>
              <div style="font-size:11px; color:#64748b; margin-bottom:6px;">Recent execution evidence, not policy allowlist.</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${f.length>0?f.map(U=>o`<span class="pill">${U}</span>`):o`<span class="empty-state" style="font-size:12px;">${R}</span>`}
              </div>
            </div>
            <div class="agent-detail-sub">
              <span>Tool calls: ${typeof _=="number"?_:R==="none_recent"?0:z}</span>
              <span>Evidence source: ${h??z}</span>
              <span>
                Observed at:
                ${b?o` <${G} timestamp=${b} />`:` ${z}`}
              </span>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Linked keeper recent tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${p.length>0?p.map(U=>o`<span class="pill">${U}</span>`):o`<span class="empty-state" style="font-size:12px;">${q}</span>`}
              </div>
            </div>
            ${m.length>0?o`
                  <div>
                    <div style="font-size:12px; color:#888; margin-bottom:6px;">Keeper window top tools</div>
                    <div style="display:flex; flex-wrap:wrap; gap:6px;">
                      ${m.map(U=>o`<span class="pill">${U}</span>`)}
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
                  ${a.checked_at?o`<span>Checked: <${G} timestamp=${a.checked_at} /></span>`:null}
                </div>
                ${a.reason?o`<div class="monitor-footnote">${a.reason}</div>`:null}
                ${a.summary&&a.summary!==a.reason?o`<div class="monitor-footnote">${a.summary}</div>`:null}
                ${a.failure_reason?o`<div class="monitor-footnote">Failure: ${a.failure_reason}</div>`:a.decision_reason?o`<div class="monitor-footnote">Decision: ${a.decision_reason}</div>`:null}
              <//>
            `:null}

        <${I} title="Task History">
          ${Wn.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Wn.value.map(U=>o`<${__} key=${U.taskId} row=${U} />`)}</div>`}
        <//>

        <${I} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${tn.value}
              onInput=${U=>{tn.value=U.target.value}}
              onKeyDown=${U=>{U.key==="Enter"&&_r()}}
              disabled=${Ln.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{_r()}}
              disabled=${Ln.value||tn.value.trim()===""}
            >
              ${Ln.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function g_(e){switch(e){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function $_(e){switch(e){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function h_(e){switch(e.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return e.role}}function fr(e){return e.delivery==="error"||e.delivery==="timeout"?"bad":e.delivery==="sending"?"warn":e.role==="assistant"?"assistant":e.role==="user"?"user":"warn"}function zc(e){if(!e)return null;const t=new Date(e);return Number.isNaN(t.getTime())?null:t.toLocaleTimeString()}function y_(e){return typeof e!="number"||!Number.isFinite(e)||e<=0?null:e<60?`${Math.round(e)}s`:`${Math.ceil(e/60)}m`}function Pc(e){if(!e)return null;const t=Ve.value[e.name];return(t==null?void 0:t.diagnostic)??e.diagnostic??null}function b_({keeper:e,showRawStatus:t=!1}){if(se(()=>{e!=null&&e.name&&$l(e.name)},[e==null?void 0:e.name]),!e)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Ve.value[e.name],s=Pc(e),a=jo.value[e.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${g_(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${$_((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?o` · ${zc(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?o` · next eligible ${y_(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?o`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${t?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function k_({keeperName:e,placeholder:t}){const[n,s]=Yr("");se(()=>{e&&$l(e)},[e]);const a=pe.value[e]??[],i=Eo.value[e]??!1,l=Qe.value[e],c=async()=>{const p=n.trim();if(!(!e||!p)){s("");try{await pp(e,p)}catch(m){const u=m instanceof Error?m.message:`Failed to message ${e}`;M(u,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(p=>o`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${fr(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${fr(p)}`}>${h_(p)}</span>
                  ${p.timestamp?o`<span class="keeper-conversation-time">${zc(p.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${p.text}</div>
                ${p.error?o`<div class="keeper-conversation-error">${p.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${t}
          value=${n}
          onInput=${p=>{s(p.target.value)}}
          disabled=${i||!e}
        ></textarea>
        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${()=>{c()}}
            disabled=${i||n.trim()===""||!e}
          >
            ${i?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${l?o`<div class="control-status-copy control-error-copy">${l}</div>`:null}
      </div>
    </div>
  `}function x_({actor:e,keeper:t,onPokeLodge:n}){if(!t)return null;const s=Pc(t),a=No.value[t.name]??!1,i=Do.value[t.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{mp(t.name,e).catch(p=>{const m=p instanceof Error?p.message:`Failed to probe ${t.name}`;M(m,"error")})}}
        disabled=${a||!e.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{vp(t.name,e).catch(p=>{const m=p instanceof Error?p.message:`Failed to recover ${t.name}`;M(m,"error")})}}
        disabled=${i||!c||!e.trim()}
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
  `}const Ei=g(null);function Mc(e){Ei.value=e,up(e.name)}function gr(){Ei.value=null}const wt=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function S_(e){if(!e)return 0;const t=wt.findIndex(n=>n.level===e);return t>=0?t:0}function C_({keeper:e}){const t=S_(e.autonomy_level),n=wt[t]??wt[0];if(!n)return null;const s=(t+1)/wt.length*100;return o`
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
          ${wt.map((a,i)=>o`
            <span style="width:8px; height:8px; border-radius:50%; background:${i<=t?a.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${e.autonomous_action_count??0}</strong>
      </div>
      ${e.last_autonomous_action_at?o`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${G} timestamp=${e.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${e.active_goal_ids&&e.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${e.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Ws(e){return e?e>=1e6?`${(e/1e6).toFixed(1)}M`:e>=1e3?`${(e/1e3).toFixed(1)}K`:String(e):"—"}function A_(e){switch(e){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(e==null?void 0:e.trim())||"action"}}function T_(e){return e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]}function I_(e){const t=e.metrics_window;return(Array.isArray(t==null?void 0:t.top_tools)?t.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function R_(e){const t=is.value;return t?t.keeper_briefs.find(n=>n.name===e.name||n.agent_name&&e.agent_name&&n.agent_name===e.agent_name)??null:null}function L_({keeper:e}){const t=e.metrics_series??[],n=t[t.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:e.generation??"-",hint:"Succession count"},{label:"Turns",value:e.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:e.context_ratio!=null?`${Math.round(e.context_ratio*100)}%`:"-",hint:e.context_ratio!=null&&e.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:e.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Ws(e.context_tokens)}</div>
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
  `}function z_({keeper:e}){var u,f;const t=e.metrics_series??[];if(t.length<2){const _=(((u=e.context)==null?void 0:u.context_ratio)??0)*100,h=_>85?"#ef4444":_>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${_.toFixed(1)}%;background:${h}"></div>
        </div>
        <span class="chart-pct">${_.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=t.length,l=t.map((_,h)=>{const b=a+h/(i-1)*(n-2*a),C=s-a-(_.context_ratio??0)*(s-2*a);return{x:b,y:C,p:_}}),c=l.map(({x:_,y:h})=>`${_.toFixed(1)},${h.toFixed(1)}`).join(" "),p=(((f=t[t.length-1])==null?void 0:f.context_ratio)??0)*100,m=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:_})=>_.is_handoff).map(({x:_})=>o`
          <line x1="${_.toFixed(1)}" y1="${a}" x2="${_.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${m}" stroke-width="1.5"/>
        ${l.filter(({p:_})=>_.is_compaction).map(({x:_,y:h})=>o`
          <circle cx="${_.toFixed(1)}" cy="${h.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}const Za=g("");function P_({keeper:e}){var a,i,l,c;const t=Za.value.toLowerCase(),n=[{title:"Name",key:"name",value:e.name},{title:"Emoji",key:"emoji",value:e.emoji??"-"},{title:"Korean",key:"koreanName",value:e.koreanName??"-"},{title:"Model",key:"model",value:e.model??"-"},{title:"Status",key:"status",value:e.status},{title:"Primary",key:"primaryValue",value:e.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(e.activityLevel??"-")},{title:"Gen",key:"generation",value:String(e.generation??"-")},{title:"Turns",key:"turn_count",value:String(e.turn_count??"-")},{title:"Context",key:"context_ratio",value:e.context_ratio!=null?`${Math.round(e.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:e.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=e.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=e.interests)==null?void 0:i.join(", "))||"-"}],s=t?n.filter(p=>p.title.toLowerCase().includes(t)||p.key.includes(t)||p.value.toLowerCase().includes(t)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Za.value}
        onInput=${p=>{Za.value=p.target.value}}
      />
      ${s.map(p=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${p.title}</span>
          <span class="keeper-field-key">${p.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${p.value}</span>
        </div>
      `)}
      ${e.trace_id?o`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${e.trace_id}</span></div>`:""}
      ${e.agent_name?o`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${e.agent_name}</span></div>`:""}
      ${e.primary_model?o`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${e.primary_model}</span></div>`:""}
      ${e.active_model?o`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${e.active_model}</span></div>`:""}
      ${e.next_model_hint?o`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${e.next_model_hint}</span></div>`:""}
      ${e.skill_primary?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${e.skill_primary}</span></div>`:""}
      ${e.skill_secondary?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${e.skill_secondary}</span></div>`:""}
      ${e.skill_reason?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${e.skill_reason}</span></div>`:""}
      ${e.context_source?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${e.context_source}</span></div>`:""}
      ${e.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Ws(e.context_tokens)}</span></div>`:""}
      ${e.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Ws(e.context_max)}</span></div>`:""}
      ${e.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${e.memory_recent_note}</span></div>`:""}
      ${e.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${e.k2k_count}</span></div>`:""}
      ${e.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${e.conversation_tail_count}</span></div>`:""}
      ${e.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${e.handoff_count_total}</span></div>`:""}
      ${e.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${e.compaction_count}</span></div>`:""}
      ${e.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Ws(e.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=e.context)==null?void 0:l.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${e.context.message_count}</span></div>`:""}
      ${((c=e.context)==null?void 0:c.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${e.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function M_({stats:e}){const t=e.max_hp>0?Math.round(e.hp/e.max_hp*100):0,n=e.max_mp>0?Math.round(e.mp/e.max_mp*100):0;return o`
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
        ${[{label:"STR",value:e.strength},{label:"DEX",value:e.dexterity},{label:"CON",value:e.constitution},{label:"INT",value:e.intelligence},{label:"WIS",value:e.wisdom},{label:"CHA",value:e.charisma}].map(s=>o`
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
  `}function j_({items:e}){return e.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${e.map((t,n)=>o`
        <div class="keeper-equipment-row">
          <span>${t}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function E_({rels:e}){const t=Object.entries(e);return t.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${t.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function $r({traits:e,label:t}){return e.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${t}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${e.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function eo(e){return e==null||Number.isNaN(e)?"-":`${Math.round(e*100)}%`}function N_({keeper:e}){const t=e.metrics_window,n=[{label:"Model fallback",value:eo(typeof(t==null?void 0:t.model_fallback_rate)=="number"?t.model_fallback_rate:void 0)},{label:"Proactive fallback",value:eo(typeof(t==null?void 0:t.proactive_fallback_rate)=="number"?t.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:eo(typeof(t==null?void 0:t.memory_pass_rate)=="number"?t.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(t==null?void 0:t.handoff_count)=="number"?t.handoff_count:e.handoff_count_total??"-"},{label:"Compactions",value:typeof(t==null?void 0:t.compaction_events)=="number"?t.compaction_events:e.compaction_count??"-"},{label:"Saved tokens",value:typeof(t==null?void 0:t.compaction_saved_tokens)=="number"?t.compaction_saved_tokens:e.last_compaction_saved_tokens??"-"},{label:"K2K events",value:e.k2k_count??"-"},{label:"Conversation tail",value:e.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(t==null?void 0:t.tool_call_count)=="number"?t.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(t==null?void 0:t.proactive_preview_similarity_avg)=="number"?`${(t.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(t==null?void 0:t.memory_avg_score)=="number"?t.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(t==null?void 0:t.fallback_rate)=="number"?`${(t.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function D_({keeper:e}){var L,Q,Z,ae,W,ee,A;const t=((L=ge.value)==null?void 0:L.room)??{},n=(((Q=ge.value)==null?void 0:Q.available_actions)??[]).filter(te=>te.target_type==="keeper"||te.target_type==="room").slice(0,8),s=T_(e),a=I_(e),i=R_(e),l=i!=null&&i.allowed_tool_names&&i.allowed_tool_names.length>0?i.allowed_tool_names:e.allowed_tool_names??[],c=i!=null&&i.latest_tool_names&&i.latest_tool_names.length>0?i.latest_tool_names:e.latest_tool_names??[],p=(i==null?void 0:i.latest_tool_call_count)??e.latest_tool_call_count,m=(i==null?void 0:i.tool_audit_source)??e.tool_audit_source,u=(i==null?void 0:i.tool_audit_at)??e.tool_audit_at,f=((Z=e.agent)==null?void 0:Z.capabilities)??[],_=t.current_room??t.room_id??((ae=oe.value)==null?void 0:ae.room)??"default",h=t.project??((W=oe.value)==null?void 0:W.project)??"확인 없음",b=t.cluster??((ee=oe.value)==null?void 0:ee.cluster)??"확인 없음",C=Ge(Sc(e)),S=Ge(Cc(e,m)),T=Ge(Ac(e,m)),$=Ge(Mi(e)),x=ds(e),R=((A=e.agent)==null?void 0:A.current_task)??(x==="offline"?"offline":"not_collected"),z=e.skill_primary??(x==="offline"?"offline":"not_collected"),q=l[0]??c[0]??s[0]??null;return o`
    <div class="keeper-signal-list">
      <div class="keeper-signal-row">
        <span>Room</span>
        <strong>${_}</strong>
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
        <strong>${R}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Skill route</span>
        <strong>${z}</strong>
      </div>
      <div style="display:flex; justify-content:flex-end; margin-top:4px;">
        <button class="control-btn ghost" onClick=${()=>{Tc(q)}}>
          Open tools panel
        </button>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Allowed tools</span>
        <span style="font-size:11px; color:#64748b;">Currently permitted tools for this keeper runtime.</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${l.length>0?l.map(te=>o`<span class="pill">${te}</span>`):o`<span style="font-size:12px; color:#888;">${C}</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Observed tools</span>
        <span style="font-size:11px; color:#64748b;">Recent execution evidence from heartbeat or runtime telemetry.</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${c.length>0?c.map(te=>o`<span class="pill">${te}</span>`):o`<span style="font-size:12px; color:#888;">${S}</span>`}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Tool calls</span>
        <strong>${typeof p=="number"?p:S==="none_recent"?0:T}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Evidence source</span>
        <strong>${m??T}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Observed at</span>
        <strong>${u?o`<${G} timestamp=${u} />`:T}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Keeper recent tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${s.length>0?s.map(te=>o`<span class="pill">${te}</span>`):o`<span style="font-size:12px; color:#888;">${$}</span>`}
        </div>
      </div>
      ${a.length>0?o`
            <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
              <span style="font-size:12px; color:#888;">Window top tools</span>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${a.map(te=>o`<span class="pill">${te}</span>`)}
              </div>
            </div>
          `:null}
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${f.length>0?f.map(te=>o`<span class="pill">${te}</span>`):o`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(te=>o`<span class="pill">${A_(te.action_type)}</span>`):o`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function jc(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(t??n??"dashboard").trim()||"dashboard"}async function w_(){try{const e=await qa({actor:jc(),action_type:"lodge_tick",target_type:"room",payload:{}}),t=gl(e.result);await os(),t!=null&&t.skipped_reason?M(t.skipped_reason,"warning"):M(t?`Poke finished: ${t.acted}/${t.checked} acted`:"Poke finished",t&&t.acted>0?"success":"warning")}catch(e){const t=e instanceof Error?e.message:"Failed to run Lodge poke";M(t,"error")}}function O_({keeper:e}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${b_} keeper=${e} />
          <${x_}
            actor=${jc()}
            keeper=${e}
            onPokeLodge=${()=>{w_()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${k_}
            keeperName=${e.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function q_(){var t,n,s;const e=Ei.value;return e?o`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&gr()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${e.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${e.name}</h2>
              ${e.koreanName?o`<div style="font-size:13px; color:#888;">${e.koreanName}</div>`:null}
            </div>
            <${gt} status=${e.status} />
            ${e.model?o`<span class="pill">${e.model}</span>`:null}
          </div>
          <button
            onClick=${()=>gr()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${L_} keeper=${e} />

        ${""}
        <${z_} keeper=${e} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${I} title="Field Dictionary">
            <${P_} keeper=${e} />
          <//>

          ${""}
          <${I} title="Profile">
            <${$r} traits=${e.traits??[]} label="Traits" />
            <${$r} traits=${e.interests??[]} label="Interests" />
            ${e.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${e.primaryValue}</span></div>`:null}
            ${e.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${e.skill_primary}</span>
                </div>`:null}
            ${e.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${e.skill_reason}</div>`:null}
            ${e.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${G} timestamp=${e.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${e.autonomy_level?o`
              <${I} title="Autonomy">
                <${C_} keeper=${e} />
              <//>
            `:null}

          ${""}
          ${e.trpg_stats?o`
              <${I} title="TRPG Stats">
                <${M_} stats=${e.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${e.inventory&&e.inventory.length>0?o`
              <${I} title="Equipment (${e.inventory.length})">
                <${j_} items=${e.inventory} />
              <//>
            `:null}

          ${""}
          ${e.relationships&&Object.keys(e.relationships).length>0?o`
              <${I} title="Relationships (${Object.keys(e.relationships).length})">
                <${E_} rels=${e.relationships} />
              <//>
            `:null}

          <${I} title="Runtime Signals">
            <${N_} keeper=${e} />
          <//>

          <${I} title="Neighborhood & Tool Audit">
            <${D_} keeper=${e} />
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
              ${e.memory_recent_note?o`
                  <div class="keeper-memory-note">
                    ${e.memory_recent_note}
                  </div>
                `:o`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${O_} keeper=${e} />
      </div>
    </div>
  `:null}function F_({cluster:e,project:t,room:n,generatedAt:s}){return o`
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
        <strong>${s?Oe(s):"기록 없음"}</strong>
      </div>
    </div>
  `}function Dt({label:e,value:t,detail:n,tone:s}){return o`
    <article class="mission-stat-card ${fe(s)}">
      <span class="mission-stat-label">${e}</span>
      <strong class="mission-stat-value">${t}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function K_(){const e=Hl.value,t=fe((e==null?void 0:e.status)??(Ct.value?"bad":"warn")),n=!e||e.sections.length===0,s=(e==null?void 0:e.status)==="error"||(e==null?void 0:e.status)==="unavailable"&&!(e!=null&&e.cached);return o`
    <${I} title="판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>왜 그렇게 보이나</h3>
        <p>사회 truth를 읽은 뒤에만 별도 판단 결과를 참고하고, 근거는 접어서 둡니다.</p>
        <div class="mission-briefing-meta">
          <span class="command-chip">narrative</span>
          <span class="command-chip warn">fallback on failure</span>
        </div>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${t}">
          ${Le((e==null?void 0:e.status)??(Ct.value?"error":"loading"))}
        </span>
        ${e!=null&&e.model?o`<span class="command-chip">${e.model}</span>`:null}
        ${e!=null&&e.generated_at?o`<span class="command-chip">${Oe(e.generated_at)}</span>`:null}
        ${e!=null&&e.cached?o`<span class="command-chip">캐시</span>`:null}
        ${e!=null&&e.stale?o`<span class="command-chip warn">오래됨</span>`:null}
        ${e!=null&&e.refreshing?o`<span class="command-chip warn">갱신 중</span>`:null}
      </div>

      ${Ct.value?o`<div class="empty-state error">${Ct.value}</div>`:null}
      ${e!=null&&e.error?o`<div class="empty-state error">${e.error}</div>`:null}
      ${e!=null&&e.summary?o`<div class="mission-inline-note">${e.summary}</div>`:null}
      ${e!=null&&e.last_error&&!e.error?o`<div class="mission-inline-note">최근 갱신 실패: ${e.last_error}</div>`:null}

      ${e&&e.sections.length>0?o`
            <div class="mission-briefing-grid">
              ${e.sections.slice(0,3).map(a=>o`
                <article class="mission-briefing-section ${fe(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${fe(a.status)}">${Le(a.status)}</span>
                      ${pr(a.signal_class)?o`<span class="command-chip ${a.signal_class==="mixed"?"warn":""}">${pr(a.signal_class)}</span>`:null}
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
          `:!Ft.value&&!Ct.value&&n?o`
                <div class="empty-state">
                  ${(e==null?void 0:e.status)==="pending"?"최신 스냅샷으로 브리핑을 생성 중입니다. 마지막 성공 결과가 생기면 자동으로 다시 읽습니다.":"판단 결과가 아직 없습니다."}
                </div>
              `:null}

      ${e&&e.metadata_gaps.length>0?o`
            <details class="mission-card-disclosure compact mission-briefing-gaps">
              <summary>관측 공백 (${e.metadata_gap_count??e.metadata_gaps.length})</summary>
              <div class="mission-list-stack">
                ${e.metadata_gaps.map(a=>o`
                  <article class="mission-briefing-gap ${a.severity==="watch"?"warn":""}">
                    <div class="mission-card-head">
                      <strong>${ha(a.scope_type)}${a.scope_id?` · ${a.scope_id}`:""}</strong>
                      <span class="command-chip ${a.severity==="watch"?"warn":""}">${Le(a.severity)}</span>
                    </div>
                    <p>${a.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{ia(s)}} disabled=${Ft.value}>
          ${Ft.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{ia(!0)}} disabled=${Ft.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function U_({item:e,selected:t,sessionLookup:n}){const s=Xv(e),a=e.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),i=e.top_action??null;return o`
    <article class="mission-attention-card ${fe((i==null?void 0:i.severity)??e.severity)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>t_(e.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${e.summary}</strong>
            <div class="mission-card-target">${ha(e.target_type)}${e.target_id?` · ${e.target_id}`:""}</div>
          </div>
          <span class="command-chip ${fe((i==null?void 0:i.severity)??e.severity)}">${i?Qv(i):e.severity}</span>
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
            <strong>${e.last_seen_at?Oe(e.last_seen_at):"기록 없음"}</strong>
            <small>${ha(e.target_type)}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${i?Ha(i.action_type):"판단 필요"}</strong>
            <small>${i?Yv(i):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${i?o`<div class="mission-inline-note">${i.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?o`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>o`
                  <button class="mission-link-row" onClick=${()=>xc(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${Le(l.status)} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:o`<div class="empty-state">직접 연결된 세션이 아직 없습니다.</div>`}

        ${e.related_agent_names.length>0?o`
              <div class="mission-pill-row">
                ${e.related_agent_names.slice(0,8).map(l=>o`
                  <button class="mission-pill action" onClick=${()=>us(l)}>${l}</button>
                `)}
              </div>
            `:null}

        ${e.evidence_preview.length>0?o`
              <details class="mission-card-disclosure compact">
                <summary>근거 미리보기</summary>
                <div class="mission-evidence-list">
                  ${e.evidence_preview.map(l=>o`<span>${l}</span>`)}
                </div>
              </details>
            `:null}
      </details>

      <div class="mission-card-actions">
        ${i?o`
              <button class="control-btn ghost" onClick=${()=>Pi(i,s,"상황판 주의 신호")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>kc(i,s,"상황판 주의 신호")}>
                원인 보기
              </button>
            `:o`
              <button class="control-btn ghost" onClick=${()=>yc(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>bc(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function H_({brief:e,selected:t}){var i,l;const n=e.member_previews.slice(0,4),s=e.top_recommendation??null,a=e.top_attention??null;return o`
    <article class="mission-crew-card ${fe(((i=e.top_attention)==null?void 0:i.severity)??e.health??e.status)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>xc(e.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${e.goal}</strong>
            <div class="mission-card-target">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          </div>
          <span class="command-chip ${fe(((l=e.top_attention)==null?void 0:l.severity)??e.health??e.status)}">${Le(e.status)}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${e.member_names.length}</strong>
            <small>${e.member_names.slice(0,3).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${Vv(e.elapsed_sec)}</strong>
            <small>${e.started_at?`${Oe(e.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 흐름</span>
            <strong>${e.last_event_at?Oe(e.last_event_at):"기록 없음"}</strong>
            <small>${e.communication_summary??"요약 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>충원 상태</span>
            <strong>${e.active_count??0}/${e.required_count||1}</strong>
            <small>활성 / 필요</small>
          </div>
        </div>
      </button>

      ${e.blocker_summary?o`<div class="mission-inline-note">막힘 · ${e.blocker_summary}</div>`:null}

      <div class="mission-crew-event">
        <span>최근 사건</span>
        <strong>${e.last_event_summary??"최근 세션 이벤트가 없습니다."}</strong>
        <small>${e.last_event_at?Oe(e.last_event_at):"시각 없음"}</small>
      </div>

      ${e.operation_badges.length>0?o`
            <div class="mission-pill-row">
              ${e.operation_badges.slice(0,3).map(c=>o`
                <span class="mission-pill">
                  ${c.operation_id} · ${Le(c.status)}${c.stage?` · ${c.stage}`:""}
                </span>
              `)}
            </div>
          `:null}

      ${n.length>0?o`
            <div class="mission-member-preview-grid">
              ${n.map(c=>o`
                <button class="mission-member-preview" onClick=${()=>us(c.agent_name)}>
                  <strong>${c.agent_name}</strong>
                  <span>${c.current_work??"현재 작업 없음"}</span>
                  <small>${c.recent_output_preview??c.recent_input_preview??"최근 입출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Xo("intervene",e.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Xo("command",e.session_id)}>세션 원인 보기</button>
        ${s?o`<button class="control-btn ghost" onClick=${()=>Pi(s,a,"상황판 세션 요약")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function B_({detail:e,loading:t,error:n}){if(t&&!e)return o`
      <${I} title="세션 상세" class="mission-list-card">
        <div class="loading-indicator">세션 상세 불러오는 중...</div>
      <//>
    `;if(n&&!e)return o`
      <${I} title="세션 상세" class="mission-list-card">
        <div class="empty-state error">${n}</div>
      <//>
    `;if(!(e!=null&&e.session))return null;const s=e.session;return o`
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
            <span class="command-chip">${e.timeline.length}</span>
          </div>
          <div class="mission-timeline-list">
            ${e.timeline.length>0?e.timeline.map(a=>o`
                  <article class="mission-timeline-row">
                    <div class="mission-card-head">
                      <strong>${a.summary}</strong>
                      <span>${a.timestamp?Oe(a.timestamp):"시각 없음"}</span>
                    </div>
                    <small>${a.actor?`${a.actor} · `:""}${a.event_type??"이벤트"}</small>
                  </article>
                `):o`<div class="empty-state">표시할 세션 이벤트가 없습니다.</div>`}
          </div>
        </div>

        <div class="mission-detail-column">
          <div class="mission-card-head">
            <strong>참여자</strong>
            <span class="command-chip">${e.participants.length}</span>
          </div>
          <div class="mission-activity-list compact">
            ${e.participants.length>0?e.participants.map(a=>o`
                  <button class="mission-member-preview" onClick=${()=>us(a.agent_name)}>
                    <strong>${a.agent_name}</strong>
                    <span>${a.current_work??"현재 작업 없음"}</span>
                    <small>
                      ${a.recent_output_preview??a.recent_input_preview??"최근 입출력 없음"}
                      ${a.last_activity_at?` · ${Oe(a.last_activity_at)}`:""}
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
            <span class="command-chip">${e.operations.length}</span>
          </div>
          <div class="mission-link-list">
            ${e.operations.length>0?e.operations.map(a=>o`
                  <button class="mission-link-row" onClick=${()=>Xo("command",s.session_id)}>
                    <strong>${a.operation_id}</strong>
                    <span>${Le(a.status)}${a.stage?` · ${a.stage}`:""}</span>
                    <small>${a.detachment_status??a.objective??"분견대 정보 없음"}</small>
                  </button>
                `):o`<div class="empty-state">연결된 작전이 없습니다.</div>`}
          </div>
        </div>

        <div class="mission-detail-column">
          <div class="mission-card-head">
            <strong>연속성 관찰</strong>
            <span class="command-chip">${e.keepers.length}</span>
          </div>
          <div class="mission-link-list">
            ${e.keepers.length>0?e.keepers.map(a=>o`
                  <div class="mission-link-row static">
                    <strong>${a.name}</strong>
                    <span>${Le(a.status)}${a.generation!=null?` · 세대 ${a.generation}`:""}</span>
                    <small>${a.current_work??"현재 작업 정보 없음"}</small>
                  </div>
                `):o`<div class="empty-state">직접 연결된 키퍼는 없습니다.</div>`}
          </div>
        </div>
      </div>
    <//>
  `}function W_({row:e}){var s,a,i,l,c,p,m,u,f,_;const t=[`세대 ${e.brief.generation??((s=e.keeper)==null?void 0:s.generation)??0}`,e.brief.context_ratio!=null?`컨텍스트 ${Math.round(e.brief.context_ratio*100)}%`:((a=e.keeper)==null?void 0:a.context_ratio)!=null?`컨텍스트 ${Math.round(e.keeper.context_ratio*100)}%`:null,e.brief.last_turn_ago_s!=null?`최근 턴 ${Math.round(e.brief.last_turn_ago_s)}초 전`:null].filter(h=>h!==null).join(" · "),n=e.recentTools.length>0?e.recentTools.join(", "):Ge(Mi(e.keeper));return o`
    <article class="mission-activity-card ${fe(e.brief.status??((i=e.keeper)==null?void 0:i.status))}">
      <button class="mission-card-select" onClick=${()=>{e.keeper&&Mc(e.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((l=e.keeper)==null?void 0:l.emoji)??""}</span>
            <div>
              <strong>${e.brief.name}</strong>
              ${(c=e.keeper)!=null&&c.koreanName?o`<span>${e.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${fe(e.brief.status??((p=e.keeper)==null?void 0:p.status))}">${Le(e.brief.status??((m=e.keeper)==null?void 0:m.status))}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 하트비트 · ${(u=e.keeper)!=null&&u.last_heartbeat?Oe(e.keeper.last_heartbeat):"기록 없음"}</span>
          <span>${t||"연속성 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${e.currentWork}</strong>
          ${(f=e.keeper)!=null&&f.skill_reason?o`<small>판단 요약 · ${Me(e.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>연속성 상세</summary>
        <div class="mission-activity-foot">
          <span>에이전트 · ${e.brief.agent_name??((_=e.keeper)==null?void 0:_.agent_name)??"기록 없음"}</span>
          ${e.recentEvent?o`<span>최근 일 · ${e.recentEvent}</span>`:null}
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
            <span>최근 도구 · ${n}</span>
          </div>
        </details>
      </details>
    </article>
  `}function G_({item:e}){const t=e.action??null,n=e.attention??null;return o`
    <article class="mission-action-card ${fe(e.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${fe(e.severity)}">
          ${e.signal_type==="action"&&t?Ha(t.action_type):(n==null?void 0:n.kind)??"내부 신호"}
        </span>
        <span class="mission-card-target">${ha(e.target_type)}${e.target_id?` · ${e.target_id}`:""}</span>
      </div>
      <p>${e.summary}</p>
      ${t?o`<div class="mission-action-preview">${t.reason}</div>`:null}
      <div class="mission-card-actions">
        ${t?o`
              <button class="control-btn ghost" onClick=${()=>Pi(t,n,"상황판 내부 신호")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>kc(t,n,"상황판 내부 신호")}>이 이슈의 원인 보기</button>
            `:n?o`
                <button class="control-btn ghost" onClick=${()=>yc(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>bc(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function hr(){var S,T,$;const e=is.value;if(Uo.value&&!e)return o`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(oa.value&&!e)return o`<div class="empty-state error">${oa.value}</div>`;if(!e)return o`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;We.value&&!e.attention_queue.some(x=>x.id===We.value)&&(We.value=null);const t=e.sessions;nt.value&&!t.some(x=>x.session_id===nt.value)&&(nt.value=null);const n=e.attention_queue.find(x=>x.id===We.value)??null,s=(n==null?void 0:n.related_session_ids.find(x=>t.some(R=>R.session_id===x)))??null,a=nt.value??s??((S=t[0])==null?void 0:S.session_id)??null,i=e_(),l=t.find(x=>x.session_id===a)??null,c=e.keeper_briefs.slice(0,6).map(Zv),p=e.attention_queue.filter(x=>x.related_session_ids.length>0).slice(0,6),m=e.internal_signals.slice(0,3),u=t.filter(x=>{var z;const R=((z=x.top_attention)==null?void 0:z.severity)??x.health??x.status;return fe(R)!=="ok"||!!x.blocker_summary}).length,f=t.filter(x=>x.last_event_summary||x.last_event_at).length,_=new Set(t.flatMap(x=>x.member_names)).size,h=t.flatMap(x=>x.member_previews??[]).filter(x=>x.recent_output_preview).length+c.filter(x=>x.recentOutput).length,b=((l==null?void 0:l.member_previews)??[]).filter(x=>x.recent_output_preview),C=c.filter(x=>x.recentOutput).slice(0,4);return se(()=>{zm(a)},[a]),o`
    <section class="dashboard-panel mission-view">
      <${xe} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 어떤 세션이 돌고 있고, 누가 참여하며, 어디가 막혔는지를 한 시점에서 읽는 기본 관찰면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${fe(e.summary.room_health)}">${Le(e.summary.room_health)}</span>
          <span class="command-chip">${e.summary.project??"프로젝트 미지정"}${e.summary.current_room?` · ${e.summary.current_room}`:""}</span>
          <span class="command-chip">${e.generated_at?Oe(e.generated_at):"기록 없음"}</span>
        </div>
      </div>

      <${F_}
        cluster=${e.summary.cluster}
        project=${e.summary.project}
        room=${e.summary.current_room}
        generatedAt=${e.generated_at}
      />

      <div class="mission-stat-grid">
        <${Dt} label="활성 세션" value=${t.length} detail="지금 진행중인 협업 단위" tone=${((T=l==null?void 0:l.top_attention)==null?void 0:T.severity)??(l==null?void 0:l.health)??"ok"} />
        <${Dt} label="막힌 세션" value=${u} detail="주의가 필요한 흐름" tone=${u>0?"warn":"ok"} />
        <${Dt} label="최근 사건 세션" value=${f} detail="최근 사건이 관측된 세션" tone=${f>0?"ok":"warn"} />
        <${Dt} label="참여자" value=${_} detail="현재 세션에 연결된 주체" tone=${_>0?"ok":"warn"} />
        <${Dt} label="키퍼 관찰" value=${c.length} detail="연속성 확인 대상" tone=${(($=c[0])==null?void 0:$.brief.status)??"ok"} />
        <${Dt} label="최근 응답" value=${h} detail="메인에서 바로 읽을 수 있는 응답 수" tone=${h>0?"ok":"warn"} />
      </div>

      ${a?o`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${(l==null?void 0:l.goal)??a}${n?` · ${n.summary}`:""}</span>
              <button class="control-btn ghost" onClick=${n_}>선택 해제</button>
            </div>
          `:null}

      <${I} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 작전을 먼저 읽고 사회의 현재 상태를 파악합니다.</p>
          <div class="mission-briefing-meta">
            <span class="command-chip ok">truth</span>
          </div>
        </div>
        <div class="mission-list-stack">
          ${t.length>0?t.map(x=>o`<${H_} key=${x.session_id} brief=${x} selected=${a===x.session_id} />`):o`<div class="empty-state">지금 활성 세션이 없습니다.</div>`}
        </div>
      <//>

      <${B_}
        detail=${Ho.value}
        loading=${Hs.value}
        error=${Bs.value}
      />

      <${I} title="키퍼 연속성" class="mission-list-card" semanticId="mission.keeper_activity">
        <div class="mission-section-head">
          <h3>세션 밖에서 움직이는 행위자</h3>
          <p>키퍼는 세션과 별개로 보고, 사회의 연속성과 장기 행위자 상태를 먼저 읽습니다.</p>
          <div class="mission-briefing-meta">
            <span class="command-chip ok">truth</span>
          </div>
        </div>
        <div class="mission-activity-list">
          ${c.length>0?c.map(x=>o`<${W_} key=${x.brief.name} row=${x} />`):o`<div class="empty-state">지금 보이는 키퍼가 없습니다.</div>`}
        </div>
        <div class="mission-card-actions">
          <button class="control-btn ghost" onClick=${()=>ie("execution")}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${()=>ie("command")}>지휘 진단면 보기</button>
        </div>
      <//>

      <${I} title="최근 사회 활동" class="mission-list-card" semanticId="mission.session_activity">
        <div class="mission-section-head">
          <h3>누가 방금 무엇을 했나</h3>
          <p>선택된 세션과 연결된 행위자의 최근 출력만 모아 읽고, 해석은 뒤로 미룹니다.</p>
          <div class="mission-briefing-meta">
            <span class="command-chip ok">truth</span>
          </div>
        </div>
        <div class="mission-list-stack">
          ${b.length>0?b.slice(0,4).map(x=>o`
                <div class="mission-inline-note">
                  <strong>${x.agent_name??"unknown actor"}</strong>
                  ${x.role?o` · ${x.role}`:null}
                  ${x.status?o` · ${Le(x.status)}`:null}
                  <div>${x.recent_output_preview}</div>
                </div>
              `):o`<div class="empty-state">선택된 세션에서 바로 읽을 최근 출력이 없습니다.</div>`}
          ${C.length>0?C.map(x=>o`
                <div class="mission-inline-note">
                  <strong>${x.brief.name}</strong>
                  <div>${x.recentOutput}</div>
                </div>
              `):null}
        </div>
      <//>

      <${I} title="세션 우선순위" class="mission-list-card" semanticId="mission.attention_queue">
        <div class="mission-section-head">
          <h3>어느 세션을 먼저 봐야 하나</h3>
          <p>주의 신호는 truth를 훑은 다음에만 읽고, 세션 집중 순서를 정하는 용도로만 씁니다.</p>
          <div class="mission-briefing-meta">
            <span class="command-chip warn">derived</span>
          </div>
        </div>
        <div class="mission-lane-stack">
          ${p.length>0?p.map(x=>o`<${U_} key=${x.id} item=${x} selected=${We.value===x.id} sessionLookup=${i} />`):o`<div class="empty-state">지금 세션 단위 주의 대기열은 비어 있습니다.</div>`}
        </div>
      <//>

      <div class="mission-human-grid">
        <${K_} />

        <${I} title="운영 보조 진단" class="mission-list-card" semanticId="mission.internal_signals">
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
              ${m.length>0?m.map(x=>o`<${G_} key=${x.id} item=${x} />`):o`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
            </div>
          </details>
        <//>
      </div>
    </section>
  `}const J_="modulepreload",V_=function(e){return"/dashboard/"+e},yr={},Q_=function(t,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(m){return Promise.all(m.map(u=>Promise.resolve(u).then(f=>({status:"fulfilled",value:f}),f=>({status:"rejected",reason:f}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),p=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(m=>{if(m=V_(m),m in yr)return;yr[m]=!0;const u=m.endsWith(".css"),f=u?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${f}`))return;const _=document.createElement("link");if(_.rel=u?"stylesheet":J_,u||(_.as="script"),_.crossOrigin="",_.href=m,p&&_.setAttribute("nonce",p),document.head.appendChild(_),u)return new Promise((h,b)=>{_.addEventListener("load",h),_.addEventListener("error",()=>b(new Error(`Unable to preload CSS for ${m}`)))})}))}function i(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&i(c.reason);return t().catch(i)})};function ka(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function X(e){if(!e)return"정보 없음";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function Y_(e){if(!e)return"warn";const t=Date.parse(e);return Number.isNaN(t)?"warn":t<=Date.now()?"bad":"ok"}function Ec(e){if(!e)return"정보 없음";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.round((t-Date.now())/1e3);return n<=0?"기한 지남":n<60?`${n}초 후`:n<3600?`${Math.round(n/60)}분 후`:n<86400?`${Math.round(n/3600)}시간 후`:`${Math.round(n/86400)}일 후`}function P(e){return e==="bad"?"bad":e==="warn"||e==="pending"?"warn":"ok"}let br=!1,X_=0;function Z_(){return++X_}let to=null;async function ef(){to||(to=Q_(()=>import("./mermaid.core-ehBncJNQ.js").then(t=>t.bE),[]).then(t=>t.default));const e=await to;return br||(e.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),br=!0),e}function lt(e){if(!e)return"warn";const t=e.toLowerCase();return t.includes("failed")||t.includes("error")||t.includes("disconnected")||t.includes("stopped")?"bad":t.includes("running")||t.includes("active")||t.includes("degraded")||t.includes("pending")?"warn":"ok"}function ps(e){return typeof e!="number"||!Number.isFinite(e)?"정보 없음":`${Math.round(e*100)}%`}function Cn(e){return typeof e!="number"||!Number.isFinite(e)?"정보 없음":e<60?`${Math.round(e)}초`:e<3600?`${Math.round(e/60)}분`:`${Math.round(e/3600)}시간`}function ms(e){return typeof e!="number"||!Number.isFinite(e)?0:Math.max(0,Math.min(100,e))}function kt(e,t){return typeof e!="number"||!Number.isFinite(e)||typeof t!="number"||!Number.isFinite(t)||t<=0?0:ms(e/t*100)}function tf(e,t){const n=ms(e);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${t};`}function Nc(e){if(!e)return"최근 체인 이력이 없습니다";const t=[e.event];return typeof e.duration_ms=="number"&&t.push(`${e.duration_ms}ms`),typeof e.tokens=="number"&&t.push(`토큰 ${e.tokens}`),e.message&&t.push(e.message),t.join(" · ")}const nf=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Dc=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"orchestra",label:"오케스트라",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],sf=Dc.map(e=>e.id),af=["chain_start","node_start","node_complete","chain_complete","chain_error"],of={warroom:{title:"실시간 워룸",description:"실제 실행, 워커, 메시지, 트레이스를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 작전, 분견대, 의존 관계를 먼저 읽는 기본 진입 표면입니다."},orchestra:{title:"룸 오케스트라 맵",description:"룸, 세션, 레인, 워커, 키퍼를 한 장의 작전판으로 읽는 시각화 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"레인 이동, 워커 결속, 막힘을 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 작전별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"실제 관리 유닛인지, 실시간 에이전트 기반 자동 투영인지 구분해서 봅니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"작전, 주체, 유닛 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"결정 승인과 유닛 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function kr(e){return!!e&&sf.includes(e)}function rf(){const e=D.value.params;return e.source!=="mission"&&e.source!=="execution"?{}:{source:e.source,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function Ni(e){const t=rf(),n=qc(),s=Di();if(e==="operations")return t;if(e==="chains"){const a=Zt.value;return a?{...t,surface:e,operation:a}:{...t,surface:e}}return e==="swarm"||e==="warroom"||e==="orchestra"?{...t,surface:e,...n?{run_id:n}:{},...s?{operation_id:s}:{}}:{...t,surface:e}}function lf(){const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");return n&&t.set("agent",n),s&&t.set("token",s),t.toString()?`/api/v1/chains/events?${t.toString()}`:"/api/v1/chains/events"}function cf(e){switch(e){case"company":return"중대";case"platoon":return"소대";case"squad":return"분대";case"agent":return"에이전트";default:return e}}function le(e){return Wo.value===e}function vs(){return ki.value}function df(e){var a,i,l,c,p,m,u;const t=ki.value,n=Et.value,s=ls.value;switch(e){case"warroom":return{tool:"masc_observe_operations",reason:"실시간 실행, 워커, 메시지, 트레이스를 한 화면에서 보고 필요한 세부 표면으로 바로 이동합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=t==null?void 0:t.operations.summary)==null?void 0:a.active)??0}개와 의존 관계를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(i=t==null?void 0:t.swarm_status)==null?void 0:i.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((p=(c=t==null?void 0:t.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:p.reason)??"레인 이동과 막힘 근거를 보고 다음 확인 도구를 고릅니다."};case"orchestra":return{tool:"masc_operator_snapshot",reason:"룸, 세션, 레인, 워커, 키퍼를 한 장에서 훑은 뒤 내려볼 대상을 고릅니다."};case"chains":return{tool:(u=(m=s==null?void 0:s.operations[0])==null?void 0:m.preview_run)!=null&&u.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"이 구조가 실제 관리 단위인지 자동 투영인지 먼저 구분해야 지휘면을 오해하지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 유닛과 작전을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"트레이스 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 제어 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function uf(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"microarch":t.includes("leader_offline")||t.includes("roster_offline")?"alerts":t.includes("stale_data")?"swarm":null:null}function pf(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")?"recommendation":t.includes("gap")?"gaps":null:null}function wc(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");if(!t)return null;const n=t.trim();return n===""?null:n}function Oc(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,i)=>{e.has(i)||e.set(i,a)}),e}function qc(){const t=Oc().get("run_id");if(!t)return null;const n=t.trim();return n===""?null:n}function Di(){const t=Oc().get("operation_id");if(!t)return null;const n=t.trim();return n===""?null:n}function mf(e){if(!e)return null;const t=Date.parse(e);return Number.isNaN(t)?null:Math.max(0,Math.round((Date.now()-t)/1e3))}function vf(e){return e.status==="claimed"||e.status==="in_progress"}function _f(e){const t=rs.value;if(!t)return null;for(const n of t.golden_paths){const s=n.steps.find(a=>a.tool===e);if(s)return s}return null}function no(e){var t;return((t=rs.value)==null?void 0:t.golden_paths.find(n=>n.id===e))??null}function ff(e){const t=rs.value;if(!t)return[];const n=new Set(e);return t.pitfalls.filter(s=>n.has(s.id))}async function ct(e){try{await e()}catch{}}function wi(e){return(e==null?void 0:e.trim().toLowerCase())??""}function Ht(e){const t=wi(e);return t.includes("failed")||t.includes("error")||t.includes("stopped")||t==="paused"?"bad":t.includes("active")||t.includes("running")||t.includes("healthy")||t.includes("ok")?"ok":"warn"}function xt(e){const t=wi(e);return t?t==="active"||t==="running"?"진행 중":t==="paused"?"일시정지":t==="done"||t==="ended"||t==="completed"?"완료":t==="failed"||t==="error"||t==="stopped"?"문제":(e==null?void 0:e.trim())||"확인 필요":"확인 필요"}function gf(){var n,s,a,i,l,c,p,m,u;const e=Et.value;if(!e)return!1;const t=e.workers.some(f=>f.joined||f.live_presence||f.completed||f.current_task_matches_run||f.heartbeat_fresh||f.claim_marker_seen||f.done_marker_seen||f.final_marker_seen||!!f.current_task||!!f.bound_task_id||!!f.last_message);return!!((n=e.operation)!=null&&n.operation_id||(s=e.detachment)!=null&&s.detachment_id||(((a=e.summary)==null?void 0:a.joined_workers)??0)>0||(((i=e.summary)==null?void 0:i.live_workers)??0)>0||(((l=e.summary)==null?void 0:l.current_task_bound)??0)>0||(((c=e.summary)==null?void 0:c.fresh_heartbeats)??0)>0||(((p=e.summary)==null?void 0:p.claim_markers_seen)??0)>0||(((m=e.summary)==null?void 0:m.done_markers_seen)??0)>0||(((u=e.summary)==null?void 0:u.final_markers_seen)??0)>0||t||e.recent_messages.length>0||e.recent_trace_events.length>0)}function $f(e){const t=wi(e.status);return t==="active"||t==="running"}function hf(){var i,l,c,p;const e=((i=ge.value)==null?void 0:i.sessions)??[],t=Et.value,n=((l=t==null?void 0:t.detachment)==null?void 0:l.session_id)??null;if(n){const m=e.find(u=>u.session_id===n);if(m)return m}const s=((c=t==null?void 0:t.operation)==null?void 0:c.operation_id)??Di();if(s){const m=e.find(u=>u.command_plane_operation_id===s);if(m)return m}const a=((p=t==null?void 0:t.detachment)==null?void 0:p.detachment_id)??null;if(a){const m=e.find(u=>u.command_plane_detachment_id===a);if(m)return m}return e.find($f)??e[0]??null}function so(e){return e==="proven"?"ok":e==="partial"?"warn":"bad"}function zn(e){return Array.isArray(e)?e:[]}function je(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)?e:{}}function Cs(e){return typeof e=="string"&&e.trim()!==""?e:null}function yf(e){return typeof e=="number"&&Number.isFinite(e)?e:null}function bf(e){const t=e.split("/");return t.length<=3?e:`…/${t.slice(-3).join("/")}`}function kf(e){return e==="proven"?"충분":e==="partial"?"부분":"부족"}function xf(e){return e==="proven"?"협업 증거가 충분합니다":e==="partial"?"흔적은 있으나 협업 증거가 덜 모였습니다":"증거가 부족합니다"}function Sf(e,t,n,s,a){const i=[`${t}명의 actor 흔적이 기록돼 있습니다.`,n>0?`서로를 참조한 상호작용 증거가 ${n}건 있습니다.`:"서로를 참조한 명시적 상호작용 증거가 아직 없습니다.",s>0?`도구·산출물·체크포인트 증거가 ${s}건 있습니다.`:"도구·산출물·체크포인트 증거가 거의 없습니다.",a>0?`CPv2 backing trace가 ${a}건 있어 실행 흔적은 남아 있습니다.`:"관리형 backing trace는 아직 없습니다."];return e==="partial"?[i[0]??"",n===0?"partial인 이유: 참여 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.":"partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.",a>0?"다음 보강 포인트: 대화/상호참조 event를 남기면 proof가 더 강해집니다.":"다음 보강 포인트: 관리형 trace 또는 산출물 연결을 더 남기면 근거가 강해집니다."]:e==="proven"?[i[0]??"","결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.","다음 행동: raw evidence는 접어두고 세션 결과와 산출물만 확인하면 됩니다."]:[i[0]??"","결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.","다음 보강 포인트: 참여자 간 턴, 도구 근거, 산출물 연결을 더 남겨야 합니다."]}function Cf(e){const t=new Map;for(const n of e){const s=[n.timestamp??"",n.event_type??"",n.actor??"",n.summary??""].join("|"),a=n.source??"unknown",i=t.get(s);if(i){i.sources.includes(a)||i.sources.push(a),!i.operation_id&&n.operation_id&&(i.operation_id=n.operation_id);continue}t.set(s,{...n,sources:[a]})}return[...t.values()]}function Af(e){return e.sources.length===2?"세션 + 지휘":e.sources.length===1?e.sources[0]==="unknown"?"출처 미상":e.sources[0]??"출처":e.sources.join(" + ")}function Tf(e){const t=[];for(const[n,s]of Object.entries(e))if(s!=null){if(typeof s=="string"){if(s.trim()==="")continue;t.push({label:n,value:s});continue}if(typeof s=="number"||typeof s=="boolean"){t.push({label:n,value:String(s)});continue}}return t}function If(e){const t=je(e),n=je(t.traces),s=Array.isArray(n.events)?n.events:[],a=je(t.detachments),i=Array.isArray(a.detachments)?a.detachments:[],l=je(i[0]),c=je(l.detachment),p=je(l.operation),m=je(t.summary),u=je(m.operations),f=je(u.summary);return[{label:"작전",value:Cs(t.operation_id)??"없음"},{label:"분견대",value:Cs(t.detachment_id)??"없음"},{label:"트레이스 이벤트",value:`${s.length}`},{label:"분견대 상태",value:Cs(c.status)??"없음"},{label:"작전 단계",value:Cs(p.stage)??"없음"},{label:"활성 작전",value:`${yf(f.active)??0}`}]}function Rf({item:e}){return o`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${e.summary??e.event_type??"이벤트"}</strong>
          <div class="command-meta-line">
            <span>${Af(e)}</span>
            <span>${e.event_type??"이벤트"}</span>
            <span>${e.actor??"시스템"}</span>
          </div>
        </div>
        <span class="command-chip">${X(e.timestamp)}</span>
      </div>
      ${e.sources.length>1?o`<div class="semantic-tag-row">
            ${e.sources.map(t=>o`<span class="semantic-tag">${t}</span>`)}
          </div>`:null}
    </article>
  `}function Lf({item:e}){const t=e.recent_output_preview??null,n=e.recent_input_preview??null,s=e.recent_event_summary??null,a=(e.interaction_count??0)>0?"ok":"warn";return o`
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
      ${s?o`<div class="proof-summary-block">
            <strong>최근 흔적</strong>
            <span>${s}</span>
          </div>`:null}
      ${n||t?o`<div class="proof-io-grid">
            <div class="mission-activity-preview">
              <strong>최근 입력</strong>
              <span>${n??"표시 가능한 입력 없음"}</span>
            </div>
            <div class="mission-activity-preview">
              <strong>최근 응답</strong>
              <span>${t??"표시 가능한 응답 없음"}</span>
            </div>
          </div>`:null}
      ${zn(e.recent_tool_names).length>0?o`<div class="semantic-tag-row">
            ${zn(e.recent_tool_names).map(i=>o`<span class="semantic-tag">${i}</span>`)}
          </div>`:null}
    </article>
  `}function zf({item:e}){return o`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${e.kind}</strong>
          <div class="command-meta-line">
            <span>${bf(e.path)}</span>
          </div>
        </div>
        <span class="command-chip ${e.exists?"ok":"warn"}">${e.exists?"존재함":"없음"}</span>
      </div>
    </article>
  `}function xr({title:e,rows:t}){return t.length===0?null:o`
    <div class="proof-kv-block">
      ${e?o`<strong>${e}</strong>`:null}
      <div class="proof-kv-grid">
        ${t.map(n=>o`
          <span>${n.label}</span>
          <strong>${n.value}</strong>
        `)}
      </div>
    </div>
  `}function Pf(){var x,R,z;const e=D.value.params,t=e.session_id??null,n=e.operation_id??null;se(()=>{Xl(t,n)},[t,n]);const s=Yl.value;if(Bo.value&&!s)return o`<section class="dashboard-panel"><div class="loading-indicator">근거 화면 불러오는 중…</div></section>`;if(Kt.value&&!s)return o`<section class="dashboard-panel"><div class="error-card">${Kt.value}</div></section>`;const a=s==null?void 0:s.summary,i=zn(s==null?void 0:s.actor_contributions),l=zn(s==null?void 0:s.artifacts),c=(s==null?void 0:s.proof_verdict)??"insufficient",p=(s==null?void 0:s.cp_backing_evidence)??null,m=Array.isArray((x=p==null?void 0:p.traces)==null?void 0:x.events)?((z=(R=p.traces)==null?void 0:R.events)==null?void 0:z.length)??0:0,u=(a==null?void 0:a.actors_count)??i.length,f=(a==null?void 0:a.interaction_count)??0,_=(a==null?void 0:a.evidence_count)??0,h=Cf(zn(s==null?void 0:s.timeline)),b=Tf(je(s==null?void 0:s.goal_binding)),C=If(p),S=l.filter(q=>q.exists).length,T=l.length-S,$=Sf(c,u,f,_,m);return o`
    <section class="dashboard-panel mission-view">
      <${xe} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>근거</h2>
          <p>이 세션이 실제로 여러 참여자의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${so(c)}">${kf(c)}</span>
          ${s!=null&&s.session_id?o`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?o`<span class="command-chip">${X(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${Kt.value?o`<div class="error-card">${Kt.value}</div>`:null}

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${so(c)}">
          <span>판정</span>
          <strong>${xf(c)}</strong>
          <small>${(a==null?void 0:a.detail)??"협업 증거를 verdict로 요약합니다."}</small>
        </div>
        <div class="summary-stat-card">
          <span>참여자</span>
          <strong>${u}</strong>
          <small>기록된 참여자 수</small>
        </div>
        <div class="summary-stat-card ${f>0?"ok":"warn"}">
          <span>상호작용</span>
          <strong>${f}</strong>
          <small>참여자 간 직접 상호작용 근거</small>
        </div>
        <div class="summary-stat-card ${_>0?"ok":"warn"}">
          <span>근거</span>
          <strong>${_}</strong>
          <small>도구 / 산출물 / 체크포인트</small>
        </div>
        <div class="summary-stat-card ${m>0?"ok":"warn"}">
          <span>CP 트레이스</span>
          <strong>${m}</strong>
          <small>관리형 backing 이벤트</small>
        </div>
        <div class="summary-stat-card ${T===0&&l.length>0?"ok":"warn"}">
          <span>산출물</span>
          <strong>${S}/${l.length}</strong>
          <small>${T>0?`${T}개 누락`:"전부 존재함"}</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${I} title="3줄 근거 요약" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, partial 이유, 다음 보강 포인트만 먼저 봅니다.</p>
          </div>
          <div class="proof-summary-stack">
            ${$.map((q,L)=>o`
              <article class="proof-summary-block ${L===1&&c!=="proven"?so(c):""}">
                <strong>${L===0?"지금 결론":L===1?"왜 이렇게 판정됐나":"다음 보강 포인트"}</strong>
                <span>${q}</span>
              </article>
            `)}
          </div>
        <//>

        <${I} title="목표 연결" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 근거가 어느 세션, 목표, 작전에 묶였는지 읽습니다.</p>
          </div>
          <${xr} rows=${b} />
          <details class="mission-card-disclosure compact">
            <summary>원본 목표 연결 JSON</summary>
            <pre class="command-json-block">${ka((s==null?void 0:s.goal_binding)??{})}</pre>
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
            ${h.length>0?h.slice(0,18).map(q=>o`<${Rf} key=${q.id} item=${q} />`):o`<div class="empty-state">표시할 타임라인 근거가 없습니다.</div>`}
          </div>
        <//>

        <${I} title="참여 흔적" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>턴 수보다 최근 흔적, 입출력, 도구, 상호작용 유무를 우선 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${i.length>0?i.map(q=>o`<${Lf} key=${q.actor} item=${q} />`):o`<div class="empty-state">표시할 참여 흔적이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${I} title="실행 근거" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>작전, 분견대, 트레이스 수만 먼저 보고, 원본 CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${xr} rows=${C} />
          <details class="mission-card-disclosure compact">
            <summary>원본 CPv2 backing JSON</summary>
            <pre class="command-json-block">${ka(p??{})}</pre>
          </details>
        <//>

        <${I} title="산출물" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>어떤 파일 산출물이 남았나</h3>
            <p>proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${l.length>0?l.map(q=>o`<${zf} key=${q.path} item=${q} />`):o`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function Mf(){const e=cs(D.value);return e?o`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${e.source_label}</strong>
        <span class="command-chip">${Ha(e.action_type)}</span>
        <span class="command-chip">${zi(e)}</span>
        <span class="command-chip">${Jv(D.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${e.summary}</div>
      ${e.payload_preview?o`<div class="command-focus-preview">${e.payload_preview}</div>`:null}
    </section>
  `:null}function jf(){const e=V.value,t=of[e],n=df(e);return o`
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
  `}function As({label:e,value:t,subtext:n,percent:s,color:a}){return o`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${tf(s,a)}>
        <div class="command-gauge-core">
          <strong>${t}</strong>
          <span>${Math.round(ms(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${e}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function Ts({label:e,value:t,detail:n,percent:s,tone:a}){return o`
    <article class="command-signal-rail ${P(a)}">
      <div class="command-signal-copy">
        <span>${e}</span>
        <strong>${t}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${P(a)}" style=${`width: ${Math.max(8,Math.round(ms(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function Ef(){var Z,ae,W,ee;const e=vs(),t=e==null?void 0:e.topology.summary,n=e==null?void 0:e.operations.summary,s=e==null?void 0:e.detachments.summary,a=e==null?void 0:e.decisions.summary,i=e==null?void 0:e.alerts.summary,l=(Z=e==null?void 0:e.swarm_status)==null?void 0:Z.overview,c=e==null?void 0:e.swarm_proof,p=e==null?void 0:e.operations.microarch,m=(t==null?void 0:t.managed_unit_count)??0,u=(t==null?void 0:t.total_units)??0,f=(n==null?void 0:n.active)??0,_=(s==null?void 0:s.active)??0,h=(l==null?void 0:l.moving_lanes)??0,b=(l==null?void 0:l.active_lanes)??0,C=(c==null?void 0:c.workers.done)??0,S=(c==null?void 0:c.workers.expected)??0,T=(i==null?void 0:i.bad)??0,$=(i==null?void 0:i.warn)??0,x=(a==null?void 0:a.pending)??0,R=(a==null?void 0:a.total)??0,z=f+_,q=((ae=p==null?void 0:p.cache)==null?void 0:ae.l1_hit_rate)??((ee=(W=p==null?void 0:p.signals)==null?void 0:W.cache_contention)==null?void 0:ee.l1_hit_rate)??0,L=f>0||_>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",Q=f>0||h>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return o`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${L}</h3>
        <p>${Q}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${P(f>0?"ok":"warn")}">활성 작전 ${f}</span>
          <span class="command-chip ${P(h>0?"ok":(b>0,"warn"))}">이동 레인 ${h}/${Math.max(b,h)}</span>
          <span class="command-chip ${P(T>0?"bad":$>0?"warn":"ok")}">치명 알림 ${T}</span>
          <span class="command-chip ${P(x>0?"warn":"ok")}">승인 대기 ${x}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${As}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(u,m)}`}
          subtext=${u>0?`${u-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${kt(m,Math.max(u,m))}
          color="#67e8f9"
        />
        <${As}
          label="실행 열도"
          value=${String(z)}
          subtext=${`${f}개 작전 + ${_}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${kt(z,Math.max(m,z||1))}
          color="#4ade80"
        />
        <${As}
          label="스웜 이동감"
          value=${`${h}/${Math.max(b,h)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${X(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${kt(h,Math.max(b,h||1))}
          color="#fbbf24"
        />
        <${As}
          label="증거 수집률"
          value=${`${C}/${Math.max(S,C)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${kt(C,Math.max(S,C||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${Ts}
        label="승인 대기열"
        value=${`${x}건 대기`}
        detail=${`현재 정책 창에서 ${R}개 결정을 추적 중입니다`}
        percent=${kt(x,Math.max(R,x||1))}
        tone=${x>0?"warn":"ok"}
      />
      <${Ts}
        label="알림 압력"
        value=${`치명 ${T} / 주의 ${$}`}
        detail=${T>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${kt(T*2+$,Math.max((T+$)*2,1))}
        tone=${T>0?"bad":$>0?"warn":"ok"}
      />
      <${Ts}
        label="디스패치 점유"
          value=${`${_}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${kt(_,Math.max(m,_||1))}
        tone=${_>0?"ok":"warn"}
      />
      <${Ts}
        label="캐시 신뢰도"
        value=${q?ps(q):"정보 없음"}
        detail=${q?"microarch 캐시 텔레메트리에서 집계한 L1 적중률":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${ms((q??0)*100)}
        tone=${q>=.75?"ok":q>=.4?"warn":"bad"}
      />
    </div>
  `}function Nf(){var _,h,b,C,S;const e=vs(),t=ls.value,n=cs(D.value),s=uf(n),a=e==null?void 0:e.topology.summary,i=e==null?void 0:e.operations.summary,l=(_=e==null?void 0:e.swarm_status)==null?void 0:_.overview,c=e==null?void 0:e.operations.microarch,p=e==null?void 0:e.decisions.summary,m=e==null?void 0:e.alerts.summary,u=(h=c==null?void 0:c.signals)==null?void 0:h.issue_pressure,f=c==null?void 0:c.cache;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(i==null?void 0:i.active)??0}</strong><small>${((b=e==null?void 0:e.detachments.summary)==null?void 0:b.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(p==null?void 0:p.pending)??0}</strong><small>${(p==null?void 0:p.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 주의</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((C=t==null?void 0:t.summary)==null?void 0:C.active_chains)??0}</strong><small>${((S=t==null?void 0:t.summary)==null?void 0:S.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${X(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(f==null?void 0:f.l1_hit_rate)!=null?`${ps(f.l1_hit_rate)} L1 적중`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"정보 없음"}</small></div>
    </div>
  `}function Df(){var Z,ae,W,ee,A,te,U,Ue,$t;const e=vs(),t=Ke.value,n=oe.value,s=wc(),a=s?Ye.value.find(K=>K.name===s)??null:null,i=s?st.value.filter(K=>K.assignee===s&&vf(K)):[],l=((Z=e==null?void 0:e.operations.summary)==null?void 0:Z.active)??0,c=((ae=e==null?void 0:e.detachments.summary)==null?void 0:ae.total)??0,p=((W=e==null?void 0:e.decisions.summary)==null?void 0:W.pending)??0,m=t==null?void 0:t.detachments.detachments.find(K=>{const Pe=K.detachment.heartbeat_deadline,ht=Pe?Date.parse(Pe):Number.NaN;return K.detachment.status==="stalled"||!Number.isNaN(ht)&&ht<=Date.now()}),u=t==null?void 0:t.alerts.alerts.find(K=>K.severity==="bad"),f=!!(n!=null&&n.room||n!=null&&n.project),_=(a==null?void 0:a.current_task)??null,h=mf(a==null?void 0:a.last_seen),b=h!=null?h<=120:null,C=[f?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?i.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:st.value.length>0?"masc_claim":"masc_add_task"}:_?b===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${_} 이지만 heartbeat가 stale 합니다 (${h}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${_}${h!=null?` · 마지막 활동 ${h}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!e||(((ee=e.topology.summary)==null?void 0:ee.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((A=e.topology.summary)==null?void 0:A.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((te=e.topology.summary)==null?void 0:te.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},p>0?{title:"디스패치 준비도",tone:"warn",detail:`${p}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||u?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${u?` · alert ${u.title??u.alert_id}`:""}${!t&&!m&&!u?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${t?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],S=f?!s||!a?"masc_join":i.length===0?st.value.length>0?"masc_claim":"masc_add_task":_?b===!1?"masc_heartbeat":!e||(((U=e.topology.summary)==null?void 0:U.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":p>0?"masc_policy_approve":l>0&&c===0||m||u?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",T=_f(S),x=ff(S==="masc_set_room"?["repo-root-room"]:S==="masc_plan_set_task"?["claimed-not-current"]:S==="masc_heartbeat"?["heartbeat-stale"]:S==="masc_dispatch_tick"?["no-detachments"]:S==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),R=no("room_task_hygiene"),z=no("cpv2_benchmark"),q=no("supervisor_session"),L=((Ue=rs.value)==null?void 0:Ue.docs)??[],Q=[R,z,q].filter(K=>K!==null);return o`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${w} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(T==null?void 0:T.title)??S}</strong>
            <span class="command-chip ok">${S}</span>
          </div>
          <p>${(T==null?void 0:T.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${($t=T==null?void 0:T.success_signals)!=null&&$t.length?o`<div class="command-tag-row">
                ${T.success_signals.map(K=>o`<span class="command-tag ok">${K}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${C.map(K=>o`
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

        ${x.length>0?o`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${x.length}</span>
                </div>
                <div class="command-guide-list">
                  ${x.map(K=>o`
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
          <${w} panelId="command.summary" compact=${!0} />
        </div>
        ${Go.value?o`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:pa.value?o`<div class="empty-state error">${pa.value}</div>`:o`
                <div class="command-path-grid">
                  ${Q.map(K=>o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${K.title}</strong>
                        <span class="command-chip">${K.id}</span>
                      </div>
                      <p>${K.summary}</p>
                      <div class="command-card-sub">${K.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${K.steps.slice(0,4).map(Pe=>o`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Pe.tool}</span>
                            <span>${Pe.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${L.length>0?o`<div class="command-doc-links">
                      ${L.map(K=>o`<span class="command-tag">${K.title}: ${K.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function wf(){return o`
    <${Ef} />
    <${Nf} />
    <${Df} />
  `}function Of(){return la.value?o`<div class="empty-state">command-plane detail 불러오는 중…</div>`:da.value?o`<div class="empty-state error">${da.value}</div>`:o`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}const Zo=g(null),Sr=1280,Cr=760;function Ar(e){switch((e??"").trim().toLowerCase()){case"room":return"룸";case"session":return"세션";case"operation":return"작전";case"detachment":return"분견대";case"lane":return"레인";case"worker":return"워커";case"keeper":return"키퍼";default:return(e==null?void 0:e.trim())||"노드"}}function bn(e,t,n){if(e<=0)return[];if(e===1)return[Math.round((t+n)/2)];const s=(n-t)/(e-1);return Array.from({length:e},(a,i)=>Math.round(t+i*s))}function qf(e,t){const n=new Map;for(const s of e){const a=t(s),i=n.get(a)??[];i.push(s),n.set(a,i)}return n}function Ff(e){const t=new Map,n=e.nodes,s=n.find(b=>b.kind==="room")??null,a=n.filter(b=>b.kind==="session"),i=n.filter(b=>b.kind==="operation"),l=n.filter(b=>b.kind==="detachment"),c=n.filter(b=>b.kind==="lane"),p=n.filter(b=>b.kind==="worker"),m=n.filter(b=>b.kind==="keeper");s&&t.set(s.id,{x:640,y:96}),bn(a.length,170,1110).forEach((b,C)=>{const S=a[C];S&&t.set(S.id,{x:b,y:220})}),bn(i.length,240,1040).forEach((b,C)=>{const S=i[C];S&&t.set(S.id,{x:b,y:330})}),bn(l.length,300,980).forEach((b,C)=>{const S=l[C];S&&t.set(S.id,{x:b,y:420})}),bn(c.length,170,1110).forEach((b,C)=>{const S=c[C];S&&t.set(S.id,{x:b,y:530})});const u=new Map(c.map(b=>{const C=t.get(b.id);return C?[b.id,C.x]:null}).filter(b=>b!==null)),f=qf(p,b=>b.lane_id?`lane:${b.lane_id}`:b.parent_id?b.parent_id:"free");let _=0;for(const[b,C]of f){let S=u.get(b);if(S==null){const $=t.get(b);S=$==null?void 0:$.x}S==null&&(S=180+_%5*200,_+=1),bn(C.length,S-90,S+90).forEach(($,x)=>{const R=C[x];if(!R)return;const z=x>5?Math.floor(x/6):0;t.set(R.id,{x:$,y:635+z*62})})}const h=m.length>3?[1120,1180]:[1140];return m.forEach((b,C)=>{const S=C%h.length,T=Math.floor(C/h.length);t.set(b.id,{x:h[S]??1140,y:190+T*108})}),t}function Kf(e,t){const n=(e.x+t.x)/2,s=t.y>=e.y?32:-32;return`M ${e.x} ${e.y} C ${n} ${e.y+s}, ${n} ${t.y-s}, ${t.x} ${t.y}`}function Tr(e,t,n){if(e==="command"){if(t){rt(t),ie("command",{...Ni(t),...n});return}ie("command",n);return}if(e==="intervene"){ie("intervene",n);return}ie("command",n)}function Uf(e){switch(e.kind){case"room":return{width:150,height:150,radius:74};case"worker":return{width:78,height:42,radius:22};case"lane":return{width:170,height:54,radius:16};case"keeper":return{width:120,height:56,radius:24};default:return{width:188,height:64,radius:18}}}function Hf({orchestra:e,roomPoint:t,onSelect:n}){if(!t||e.signals.length===0)return null;const s=108;return o`
    ${e.signals.slice(0,6).map((a,i)=>{const l=(-120+i*38)*(Math.PI/180),c=Math.round(t.x+Math.cos(l)*s),p=Math.round(t.y+Math.sin(l)*s);return o`
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
  `}function Bf({edges:e,positions:t,selectedId:n}){return o`
    ${e.map(s=>{const a=t.get(s.source),i=t.get(s.target);if(!a||!i)return null;const l=n!=null&&(s.source===n||s.target===n);return o`
        <path
          key=${s.id}
          d=${Kf(a,i)}
          class=${`orchestra-edge ${P(s.tone)} ${s.animated?"animated":""} ${l?"active":""}`}
        />
      `})}
  `}function Wf({orchestra:e,positions:t,selectedId:n,onSelect:s}){var i;const a=((i=e.focus)==null?void 0:i.target_kind)==="node"?e.focus.target_id:null;return o`
    ${e.nodes.map(l=>{const c=t.get(l.id);if(!c)return null;const p=Uf(l),m=l.id===n,u=l.id===a;if(l.kind==="room")return o`
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
        `;const f=c.x-p.width/2,_=c.y-p.height/2;return o`
        <g
          key=${l.id}
          class=${`orchestra-node ${l.kind} ${P(l.tone)} ${m?"selected":""} ${u?"focused":""}`}
          onClick=${()=>s(l.id)}
        >
          <rect x=${f} y=${_} width=${p.width} height=${p.height} rx=${p.radius} class="orchestra-node-body" />
          <text x=${f+16} y=${_+24} class="orchestra-node-glyph">${l.glyph??"•"}</text>
          <text x=${f+38} y=${_+24} class="orchestra-node-label">${l.label}</text>
          ${l.subtitle?o`<text x=${f+38} y=${_+42} class="orchestra-node-subtitle">${l.subtitle}</text>`:null}
          ${l.status?o`<text x=${f+p.width-10} y=${_+18} text-anchor="end" class="orchestra-node-status">${l.status}</text>`:null}
        </g>
      `})}
  `}function Fc(e){var s,a;const t=Zo.value;if(t){const i=e.nodes.find(c=>c.id===t);if(i)return{type:"node",value:i};const l=e.signals.find(c=>c.id===t);if(l)return{type:"signal",value:l}}if(((s=e.focus)==null?void 0:s.target_kind)==="node"){const i=e.nodes.find(l=>{var c;return l.id===((c=e.focus)==null?void 0:c.target_id)});if(i)return{type:"node",value:i}}if(((a=e.focus)==null?void 0:a.target_kind)==="signal"){const i=e.signals.find(l=>{var c;return l.id===((c=e.focus)==null?void 0:c.target_id)});if(i)return{type:"signal",value:i}}const n=e.nodes[0];return n?{type:"node",value:n}:null}function Gf({orchestra:e}){const t=Fc(e);if(!t)return o`<aside class="orchestra-drawer card"><div class="empty-state">선택 가능한 대상이 아직 없습니다.</div></aside>`;if(t.type==="signal"){const i=t.value;return o`
      <aside class="orchestra-drawer card ${P(i.tone)}">
          <div class="card-title-row">
            <div class="card-title">${i.label}</div>
          <span class="command-chip ${P(i.tone)}">${Ar(i.kind)}</span>
        </div>
        <p>${i.detail??"세부 설명이 없습니다."}</p>
        ${i.suggested_surface?o`
              <div class="command-action-row">
                <button
                  class="control-btn"
                  onClick=${()=>Tr("command",i.suggested_surface,i.suggested_params??{})}
                >
                  추천 화면 열기
                </button>
              </div>
            `:null}
      </aside>
    `}const n=t.value,s=e.signals.filter(i=>i.source_id===n.id||i.target_id===n.id),a=e.edges.filter(i=>i.source===n.id||i.target===n.id);return o`
    <aside class="orchestra-drawer card ${P(n.tone)}">
      <div class="card-title-row">
        <div class="card-title">${n.label}</div>
        <span class="command-chip ${P(n.tone)}">${Ar(n.kind)}</span>
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
          ${s.map(i=>o`<span class="command-chip ${P(i.tone)}">${i.label}</span>`)}
        </div>
      `:null}
      <div class="command-card-sub">연결 ${a.length}개 · 근거 ${n.provenance}</div>
      ${n.link_tab&&(n.link_surface||Object.keys(n.link_params??{}).length>0)?o`
            <div class="command-action-row">
              <button
                class="control-btn"
                onClick=${()=>Tr(n.link_tab??"command",n.link_surface,n.link_params??{})}
              >
                이 화면 열기
              </button>
            </div>
          `:null}
    </aside>
  `}function Jf(){var i,l,c,p;const e=xi.value;if(Jo.value&&!e)return o`<section class="card command-section"><div class="empty-state">오케스트라 맵 불러오는 중…</div></section>`;if(_a.value)return o`<section class="card command-section"><div class="empty-state error">${_a.value}</div></section>`;if(!e)return o`<section class="card command-section"><div class="empty-state">오케스트라 맵 데이터가 아직 없습니다.</div></section>`;const t=Ff(e),n=Fc(e),s=(n==null?void 0:n.value.id)??null,a=e.nodes.find(m=>m.kind==="room")?t.get(e.nodes.find(m=>m.kind==="room").id)??null:null;return o`
    <section class="card command-section orchestra-surface">
      <div class="card-title-row">
        <div class="card-title">오케스트라 맵</div>
        <${w} panelId="command.orchestra" compact=${!0} />
      </div>
      <p class="command-card-sub">룸 전체를 한 장의 작전판으로 읽는 시각화입니다. 노드를 누르면 관련 신호와 내려볼 대상을 바로 확인할 수 있습니다.</p>

      <div class="orchestra-shell">
        <div class="orchestra-canvas-wrap">
          <svg class="orchestra-canvas" viewBox=${`0 0 ${Sr} ${Cr}`}>
            <defs>
              <pattern id="orchestra-grid" width="32" height="32" patternUnits="userSpaceOnUse">
                <path d="M 32 0 L 0 0 0 32" fill="none" class="orchestra-grid-line"></path>
              </pattern>
            </defs>
            <rect width=${Sr} height=${Cr} fill="url(#orchestra-grid)" class="orchestra-grid"></rect>
            <${Bf} edges=${e.edges} positions=${t} selectedId=${s} />
            <${Hf} orchestra=${e} roomPoint=${a} onSelect=${m=>{Zo.value=m}} />
            <${Wf}
              orchestra=${e}
              positions=${t}
              selectedId=${s}
              onSelect=${m=>{Zo.value=m}}
            />
          </svg>
          <div class="orchestra-summary-strip">
            <span class="command-chip">세션 ${((i=e.summary)==null?void 0:i.session_count)??0}</span>
            <span class="command-chip">워커 ${((l=e.summary)==null?void 0:l.worker_count)??0}</span>
            <span class="command-chip">키퍼 ${((c=e.summary)==null?void 0:c.keeper_count)??0}</span>
            <span class="command-chip ${P(e.signals.some(m=>m.tone==="bad")?"bad":e.signals.length>0?"warn":"ok")}">
              신호 ${((p=e.summary)==null?void 0:p.signal_count)??e.signals.length}
            </span>
            <span class="command-chip">갱신 ${X(e.generated_at)}</span>
          </div>
        </div>

        <${Gf} orchestra=${e} />
      </div>
    </section>
  `}const Kc="masc_dashboard_agent_name";function Vf(){var t,n,s;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Kc))==null?void 0:s.trim())||"dashboard"}const Wa=g(Vf()),nn=g(""),xa=g("운영 점검"),sn=g(""),Gn=g(""),Jn=g("2"),cn=g(""),be=g("note"),Vn=g(""),Qn=g(""),Yn=g(""),Xn=g("2"),Zn=g(""),Sa=g("운영자 중지 요청"),Ca=g(""),an=g(""),Is=g(null);function Qf(e){const t=e.trim()||"dashboard";Wa.value=t,localStorage.setItem(Kc,t)}function Aa(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Oi(e){switch((e??"").trim().toLowerCase()){case"judgment":return"상주 판단";case"fallback":return"보조 읽기 모델";default:return(e==null?void 0:e.trim())||"안내"}}function Ta(e){switch((e??"").trim().toLowerCase()){case"judgment":return"ok";case"fallback":return"warn";default:return"warn"}}function qi(e){return e!=null&&e.enabled?e.refreshing?"갱신 중":e.judge_online?"온라인":e.last_error?"오류":"대기":"꺼짐"}function Yf(e){return e!=null&&e.enabled?e.judge_online?"ok":e.refreshing?"warn":"bad":"warn"}function Fi(e){return e!=null&&e.fresh_until?e.fresh_until:"갱신 기준 없음"}function Ir(e){return typeof e!="number"||!Number.isFinite(e)?"확인 없음":e<60?`${Math.round(e)}초 전`:e<3600?`${Math.round(e/60)}분 전`:`${Math.round(e/3600)}시간 전`}function dn(e){return typeof e=="string"?e.trim().toLowerCase():""}function Xf(e){var s;const t=dn(e.status);if(t==="paused")return"bad";if(t===""||t==="unknown")return"warn";const n=dn((s=e.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||t&&t!=="active"&&t!=="running"&&t!=="ended"?"warn":"ok"}function ao(e){const t=dn(e.status);return t==="offline"||t==="inactive"||t==="error"?"bad":t===""||t==="unknown"||(e.context_ratio??0)>=.8||e.context_ratio==null||e.last_turn_ago_s==null||(e.last_turn_ago_s??0)>=3600?"warn":"ok"}function Rr(e){return e.some(t=>dn(t.severity)==="bad")?"bad":e.length>0?"warn":"ok"}function Zf(e){return e.target_type==="team_session"}function eg(e){return e.target_type==="keeper"}function Pt(e){switch(e){case"broadcast":return"방송";case"room_pause":return"방 일시정지";case"room_resume":return"방 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"team_worker_spawn_batch":return"세션 작업자 교체";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"키퍼 메시지";case"keeper_msg":return"키퍼 메시지";case"swarm_run_continue":return"스웜 실행 계속";case"swarm_run_rerun":return"스웜 실행 재실행";case"swarm_run_abandon":return"스웜 실행 포기";default:return(e==null?void 0:e.trim())||"액션"}}function on(e){switch(e){case"room":return"방";case"team_session":return"세션";case"keeper":return"키퍼";case"swarm_run":return"스웜 실행";default:return(e==null?void 0:e.trim())||"대상"}}function Bt(e){switch(dn(e)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function Ia(e){return e?"확인 후 실행":"즉시 실행"}function tg(e){switch(e){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"worker_spawn_batch":return"작업자 교체";default:return e}}function me(e,t){if(!e)return null;const n=e[t];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function ng(e){return!e||typeof e!="object"||Array.isArray(e)?null:e}function sg(e){if(!e)return"";const t=e.spawn_batch;return Aa(t!==void 0?t:e)}function Uc(e){const t=ng(e.payload);if(e.target_type==="room"){if(e.action_type==="broadcast"){nn.value=me(t,"message")??e.summary;return}if(e.action_type==="task_inject"){sn.value=me(t,"title")??"운영자 주입 작업",Gn.value=me(t,"description")??e.summary,Jn.value=me(t,"priority")??Jn.value;return}e.action_type==="room_pause"&&(xa.value=me(t,"reason")??e.summary);return}if(e.target_type==="team_session"){if(e.target_id&&(cn.value=e.target_id),e.action_type==="team_stop"){Sa.value=me(t,"reason")??e.summary;return}be.value=e.action_type==="team_worker_spawn_batch"?"worker_spawn_batch":e.action_type==="team_task_inject"?"task":e.action_type==="team_broadcast"?"broadcast":"note";const n=me(t,"message");if(n&&(Vn.value=n),be.value==="worker_spawn_batch"){Zn.value=sg(t);return}be.value==="task"&&(Qn.value=me(t,"task_title")??me(t,"title")??"운영자 주입 작업",Yn.value=me(t,"task_description")??me(t,"description")??e.summary,Xn.value=me(t,"task_priority")??me(t,"priority")??Xn.value);return}e.target_type==="keeper"&&(e.target_id&&(Ca.value=e.target_id),an.value=me(t,"message")??e.summary)}function ag(e){Uc({action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.suggested_payload,summary:e.summary})}function og(e){Uc({action_type:e.action_type,target_type:e.target_type,target_id:e.target_id??null,payload:e.suggested_payload,summary:e.reason}),M("추천 액션 payload를 폼에 채웠습니다","success")}function ig(e,t,n){return!e||!e.target_type||e.target_type==="room"?!0:e.target_type==="team_session"?!!e.target_id&&t.some(s=>s.session_id===e.target_id):e.target_type==="keeper"?!!e.target_id&&n.some(s=>s.name===e.target_id):!0}async function pt(e){const t=Wa.value.trim()||"dashboard";try{const n=await Kl({actor:t,action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.payload});return n.confirm_required?M("확인 대기열에 올렸습니다","warning"):M(e.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return M(s,"error"),null}}async function Lr(){const e=nn.value.trim();if(!e)return;await pt({action_type:"broadcast",target_type:"room",payload:{message:e},successMessage:"방송을 보냈습니다"})&&(nn.value="")}async function rg(){await pt({action_type:"room_pause",target_type:"room",payload:{reason:xa.value.trim()||"운영 점검"},successMessage:"방 일시정지를 요청했습니다"})}async function Hc(){await pt({action_type:"room_resume",target_type:"room",payload:{},successMessage:"방 재개를 요청했습니다"})}async function lg(){const e=sn.value.trim();if(!e)return;await pt({action_type:"task_inject",target_type:"room",payload:{title:e,description:Gn.value.trim()||"개입 화면에서 주입",priority:Number.parseInt(Jn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(sn.value="",Gn.value="")}async function cg(){var l;const e=ge.value,t=cn.value||((l=e==null?void 0:e.sessions[0])==null?void 0:l.session_id)||"";if(!t){M("먼저 세션을 고르세요","warning");return}const n={};if(be.value==="worker_spawn_batch"){const c=Zn.value.trim();if(!c){M("spawn_batch JSON을 먼저 채우세요","warning");return}try{const m=JSON.parse(c);if(Array.isArray(m))n.spawn_batch=m;else if(m&&typeof m=="object"&&Array.isArray(m.spawn_batch))n.spawn_batch=m.spawn_batch;else{M("spawn_batch는 배열 또는 { spawn_batch: [...] } 형태여야 합니다","warning");return}}catch(m){const u=m instanceof Error?m.message:"spawn_batch JSON 파싱에 실패했습니다";M(u,"error");return}await pt({action_type:"team_worker_spawn_batch",target_type:"team_session",target_id:t,payload:n,successMessage:"작업자 교체 요청을 적용했습니다"})&&(Zn.value="");return}const s=Vn.value.trim();s&&(n.message=s);let a="team_note";be.value==="broadcast"?a="team_broadcast":be.value==="task"&&(a="team_task_inject"),be.value==="task"&&(n.task_title=Qn.value.trim()||"운영자 주입 작업",n.task_description=Yn.value.trim()||"개입 화면에서 주입",n.task_priority=Number.parseInt(Xn.value,10)||2),await pt({action_type:a,target_type:"team_session",target_id:t,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Vn.value="",be.value==="task"&&(Qn.value="",Yn.value=""))}async function dg(){var n;const e=ge.value,t=cn.value||((n=e==null?void 0:e.sessions[0])==null?void 0:n.session_id)||"";if(!t){M("먼저 세션을 고르세요","warning");return}await pt({action_type:"team_stop",target_type:"team_session",target_id:t,payload:{reason:Sa.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function ug(){var a;const e=ge.value,t=Ca.value||((a=e==null?void 0:e.keepers[0])==null?void 0:a.name)||"",n=an.value.trim();if(!t){M("먼저 키퍼를 고르세요","warning");return}if(!n)return;await pt({action_type:"keeper_message",target_type:"keeper",target_id:t,payload:{message:n},successMessage:`${t}에게 메시지를 보냈습니다`})&&(an.value="")}async function zr(e,t="confirm"){const n=Wa.value.trim()||"dashboard";try{await Ul(n,e,t),M(t==="deny"?"승인 대기를 거부했습니다":"확인 실행을 완료했습니다","success")}catch(s){const a=s instanceof Error?s.message:t==="deny"?"승인 대기 거부에 실패했습니다":"확인 실행에 실패했습니다";M(a,"error")}}function Bc(e){switch(e){case"explicit":return"실제 관리 단위";case"hybrid":return"관리 단위 + 자동 보강";case"auto":return"자동 투영";default:return"출처 미상"}}function Wc(e){switch(e){case"explicit":return"ok";case"hybrid":return"warn";case"auto":return"warn";default:return"warn"}}function pg(e){switch(e){case"explicit":return"지금 보이는 유닛은 실제로 정의된 지휘면 관리 단위입니다.";case"hybrid":return"일부는 실제 관리 단위이고, 비어 있는 부분은 실시간 에이전트 편성을 보고 자동 보강한 구조입니다.";case"auto":return"이 화면은 실시간 에이전트 편성을 지휘면 모양으로 자동 투영한 것입니다. 실제 명령 체계와 1:1로 같다고 보면 안 됩니다.";default:return"이 화면은 관리 토폴로지와 실효 토폴로지가 섞여 있을 수 있습니다."}}function mg(e){const t=e.unit.source??"unknown";return t==="explicit"?e.active_operation_count&&e.active_operation_count>0?"실제 관리 단위이며 연결된 작전이 있습니다.":"실제 관리 단위이지만 현재 연결된 작전은 없습니다.":t==="hybrid"?e.active_operation_count&&e.active_operation_count>0?"관리 단위를 기반으로 자동 보강된 구조이며 일부 작전이 연결돼 있습니다.":"관리 단위를 기반으로 자동 보강된 구조이며 현재 실행 연결은 약합니다.":e.active_operation_count&&e.active_operation_count>0?"자동 생성된 구조이지만 이 노드에 연결된 작전 흔적은 있습니다.":"자동 생성된 구조이며 현재 실행 연결은 없습니다."}function Gc({node:e,depth:t=0}){const n=e.roster_live??0,s=e.roster_total??e.unit.roster.length,a=e.active_operation_count??0,i=e.unit.policy,l=e.unit.source??"unknown",c=a>0?`${a}개 작전 연결`:"실행 연결 없음";return o`
    <div class="command-tree-node depth-${Math.min(t,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${e.unit.label}</strong>
            <span class="command-chip">${cf(e.unit.kind)}</span>
            <span class="command-chip ${P(e.health)}">${e.health??"ok"}</span>
            <span class="command-chip ${Wc(l)}">${Bc(l)}</span>
            <span class="command-chip ${a>0?"ok":"warn"}">${c}</span>
            ${i!=null&&i.frozen?o`<span class="command-chip warn">동결됨</span>`:null}
            ${i!=null&&i.kill_switch?o`<span class="command-chip bad">킬 스위치</span>`:null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${e.unit.unit_id}</span>
            <span>리더 ${e.unit.leader_id??"미지정"} / ${e.leader_status??"확인 필요"}</span>
            <span>편성 ${n}/${s}</span>
            <span>작전 ${a}</span>
            <span>자율성 ${(i==null?void 0:i.autonomy_level)??"정보 없음"}</span>
          </div>
          <div class="command-card-sub">${mg(e)}</div>
          ${e.reasons&&e.reasons.length>0?o`<div class="command-tag-row">
                ${e.reasons.map(p=>o`<span class="command-tag warn">${p}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${e.children.length>0?o`<div class="command-tree-children">
            ${e.children.map(p=>o`<${Gc} node=${p} depth=${t+1} />`)}
          </div>`:null}
    </div>
  `}function vg({alert:e}){return o`
    <article class="command-alert ${P(e.severity)}">
      <div class="command-card-head">
        <strong>${e.title??e.kind??e.alert_id}</strong>
        <span class="command-chip ${P(e.severity)}">${e.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${e.scope_type??"범위"}:${e.scope_id??"정보 없음"}</span>
        <span>${X(e.timestamp)}</span>
      </div>
      ${e.detail?o`<p>${e.detail}</p>`:null}
    </article>
  `}function Ki({event:e}){return o`
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
      <pre class="command-trace-detail">${ka(e.detail)}</pre>
    </article>
  `}function _g(){const e=Ke.value,t=e==null?void 0:e.topology,n=t==null?void 0:t.source,s=t==null?void 0:t.summary,a=(s==null?void 0:s.managed_unit_count)??0,i=(s==null?void 0:s.active_operation_count)??0;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${w} panelId="command.topology" compact=${!0} />
      </div>
      ${e?o`
            <div class="command-topology-explainer">
              <div class="command-tree-title-row">
                <span class="command-chip ${Wc(n)}">${Bc(n)}</span>
                <span class="command-chip">관리 유닛 ${a}</span>
                <span class="command-chip ${i>0?"ok":"warn"}">활성 작전 ${i}</span>
              </div>
              <p>${pg(n)}</p>
            </div>
          `:null}
      ${e&&e.topology.units.length>0?o`${e.topology.units.map(l=>o`<${Gc} node=${l} />`)}`:o`<div class="empty-state">지금은 실시간 에이전트나 관리 유닛 기준으로 그릴 지휘 계층이 없습니다.</div>`}
    </section>
  `}function fg(){const e=Ke.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${w} panelId="command.alerts" compact=${!0} />
      </div>
      ${e&&e.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${e.alerts.alerts.map(t=>o`<${vg} alert=${t} />`)}
          </div>`:o`<div class="empty-state">지금 올라온 지휘면 경보는 없습니다.</div>`}
    </section>
  `}function gg(){const e=Ke.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${w} panelId="command.trace" compact=${!0} />
      </div>
      ${e&&e.traces.events.length>0?o`<div class="command-trace-stack">
            ${e.traces.events.map(t=>o`<${Ki} event=${t} />`)}
          </div>`:o`<div class="empty-state">최근 트레이스 이벤트가 없습니다.</div>`}
    </section>
  `}function $g(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e,null,2)}catch{return String(e)}}function hg(e,t){return(t==null?void 0:t.status)==="abandoned"||(e==null?void 0:e.recommended_kind)==="continue"?"warn":(e==null?void 0:e.recommended_kind)==="rerun"?"bad":"ok"}function yg(e){switch(e){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(e==null?void 0:e.trim())||"결정"}}function Jc({swarm:e}){var f,_;const t=e.run_id,n=e.resolution_recommendation,s=e.run_resolution;if(!t||!n&&!s)return null;const a=wc()??"dashboard",i=((f=ge.value)==null?void 0:f.pending_confirms.find(h=>h.target_type==="swarm_run"&&h.target_id===t))??null,l=hg(n,s),c=((_=e.operation)==null?void 0:_.operation_id)??e.operation_id??void 0,p={run_id:t};c&&(p.operation_id=c),n!=null&&n.reason&&(p.reason=n.reason);const m=async h=>{await Kl({actor:a,action_type:h,target_type:"swarm_run",target_id:t,payload:p})},u=async h=>{i&&await Ul(a,i.confirm_token,h)};return o`
    <article class="command-guide-card ${P(l)}">
      <div class="command-guide-head">
        <strong>Run Resolution</strong>
        <span class="command-chip ${P(l)}">
          ${yg((s==null?void 0:s.status)??(n==null?void 0:n.recommended_kind)??null)}
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
      ${n!=null&&n.evidence?o`
            <div class="command-tag-row">
              <span class="command-tag">joined ${n.evidence.joined_workers??0}</span>
              <span class="command-tag">trace ${n.evidence.trace_events??0}</span>
              <span class="command-tag">message ${n.evidence.message_events??0}</span>
              ${n.evidence.runtime_blocker?o`<span class="command-tag ${P("bad")}">${n.evidence.runtime_blocker}</span>`:null}
            </div>
          `:null}
      ${i?o`
            <div class="command-guide-card warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip warn">${i.confirm_token}</span>
              </div>
              ${i.preview?o`<pre class="command-trace-detail">${$g(i.preview)}</pre>`:null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${()=>{u("confirm")}} disabled=${J.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${()=>{u("deny")}} disabled=${J.value}>취소</button>
              </div>
            </div>
          `:n?o`
              <div class="command-action-row">
                ${n.continue_available?o`<button class="control-btn ghost" onClick=${()=>{m("swarm_run_continue")}} disabled=${J.value}>Continue</button>`:null}
                ${n.rerun_available?o`<button class="control-btn" onClick=${()=>{m("swarm_run_rerun")}} disabled=${J.value}>Rerun</button>`:null}
                ${n.abandon_available?o`<button class="control-btn ghost" onClick=${()=>{m("swarm_run_abandon")}} disabled=${J.value}>Abandon</button>`:null}
              </div>
            `:null}
    </article>
  `}function Vc(e){return e.motion_state==="stalled"||e.hard_flags.some(t=>t.severity==="bad")?"bad":e.motion_state==="waiting"||e.hard_flags.some(t=>t.severity==="warn")?"warn":"ok"}function Qc({lanes:e}){const t={moving:0,waiting:0,stalled:0,terminal:0};for(const a of e){const i=a.motion_state;i in t?t[i]++:t.waiting++}if(e.length===0)return null;const s=[{key:"moving",count:t.moving,color:"var(--ok)"},{key:"waiting",count:t.waiting,color:"var(--warn)"},{key:"stalled",count:t.stalled,color:"var(--bad)"},{key:"terminal",count:t.terminal,color:"#556"}];return o`
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
  `}function bg({total:e}){const n=Math.min(e,20),s=e>20?e-20:0,a=Array.from({length:n});return o`
    <div class="swarm-worker-grid">
      ${a.map(()=>o`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?o`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${e})</span>
    </div>
  `}function kg({lane:e}){const t=e.counts??{},n=Vc(e),s=t.workers??0,a=t.operations??0,i=t.detachments??0,l=a+i,c=e.motion_state==="moving"?84:e.motion_state==="waiting"?58:e.motion_state==="terminal"?100:26;return o`
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
        ${s>0?o`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${bg} total=${s} />
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
      ${e.blockers.length>0?o`<div class="swarm-lane-blockers">막힘: ${e.blockers.join(" · ")}</div>`:null}
      ${e.hard_flags.length>0?o`
            <div class="swarm-lane-flags">
              ${e.hard_flags.map(p=>o`<span class="command-chip ${P(p.severity)}">${p.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Yc({lanes:e}){const t=e.slice(0,4);return t.length===0?null:o`
    <div class="swarm-storyboard">
      ${t.map(n=>{const s=Vc(n),a=n.counts.workers??0,i=n.counts.operations??0,l=n.counts.detachments??0;return o`
          <article class="swarm-story-card ${P(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${P(s)}">${n.motion_state}</span>
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
  `}function xg({event:e}){const t=e.timestamp?new Date(e.timestamp):null,n=t&&!isNaN(t.getTime())?t:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return o`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${P(e.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${e.title}</strong>
        <span class="swarm-event-kind">${e.kind}</span>
        ${e.detail?o`<div class="command-card-sub">${e.detail}</div>`:null}
      </div>
    </div>
  `}function Sg({gap:e}){return o`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${P(e.severity)}">${e.code} (${e.count})</span>
      <span class="command-card-sub">${e.summary}</span>
    </div>
  `}function Cg({proof:e}){const t=(e==null?void 0:e.status)==="missing"?"warn":(e==null?void 0:e.pass)===!1?"bad":(e==null?void 0:e.pass)===!0?"ok":"warn";return o`
    <div class="command-guide-card ${P(t)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${P(t)}">${(e==null?void 0:e.status)??"missing"}</span>
        </div>
      ${e?o`
            <div class="command-card-grid">
              <span>소스</span><span>${e.source}</span>
              <span>런</span><span>${e.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${X(e.captured_at)}</span>
              <span>통과</span><span>${e.pass==null?"n/a":e.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${e.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${e.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${e.workers.expected??"n/a"} 예상 · ${e.workers.done??"n/a"} 완료 · ${e.workers.final??"n/a"} 최종</span>
            </div>
            ${e.artifact_ref?o`<div class="command-card-foot">${e.artifact_ref}</div>`:null}
            ${e.missing_reason?o`<p>${e.missing_reason}</p>`:null}
          `:o`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function Ag(){const e=vs(),t=cs(D.value),n=pf(t),s=e==null?void 0:e.swarm_status,a=e==null?void 0:e.swarm_proof,i=(s==null?void 0:s.lanes.filter(f=>f.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],p=s==null?void 0:s.overview,m=s==null?void 0:s.recommended_next_action,u=i.length<=1;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${w} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?o`
            <${Yc} lanes=${i} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(p==null?void 0:p.active_lanes)??0}</strong><small>${(p==null?void 0:p.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(p==null?void 0:p.stalled_lanes)??0}</strong><small>${(p==null?void 0:p.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${X(p==null?void 0:p.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${X(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${i.length>0?o`<${Qc} lanes=${i} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${i.length>0?i.map(f=>o`<${kg} lane=${f} />`):o`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${Cg} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${P(l.some(f=>f.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?o`<div class="swarm-event-rail">${l.slice(0,4).map(f=>o`<${Sg} gap=${f} />`)}</div>`:o`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?o`<div class="swarm-event-rail">${c.map(f=>o`<${xg} event=${f} />`)}</div>`:o`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:o`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Tg({item:e}){return o`
    <article class="command-guide-card ${P(e.status)}">
      <div class="command-guide-head">
        <strong>${e.title}</strong>
        <span class="command-chip ${P(e.status)}">${e.status}</span>
      </div>
      <p>${e.detail}</p>
      <div class="command-card-foot">Next tool: ${e.next_tool}</div>
    </article>
  `}function Xc({blocker:e}){return o`
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
  `}function Ig({worker:e}){return o`
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
      ${e.last_message?o`<div class="command-card-foot">${X(e.last_message.timestamp)} · ${e.last_message.content}</div>`:null}
    </article>
  `}function Rg(){var p,m,u,f,_,h,b,C,S,T,$,x,R,z,q,L,Q,Z,ae,W,ee;const e=Et.value,t=qc(),n=Di(),s=(p=e==null?void 0:e.provider)!=null&&p.runtime_blocker?"blocked":(m=e==null?void 0:e.provider)!=null&&m.provider_reachable?"ready":"check",a=((u=e==null?void 0:e.provider)==null?void 0:u.actual_slots)??((f=e==null?void 0:e.provider)==null?void 0:f.total_slots)??0,i=((_=e==null?void 0:e.provider)==null?void 0:_.expected_slots)??"n/a",l=((h=e==null?void 0:e.provider)==null?void 0:h.actual_ctx)??((b=e==null?void 0:e.provider)==null?void 0:b.ctx_per_slot)??0,c=((C=e==null?void 0:e.provider)==null?void 0:C.expected_ctx)??"n/a";return o`
    <div class="command-section-stack">
      <${Ag} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${w} panelId="command.swarm" compact=${!0} />
          </div>
          ${ma.value?o`<div class="empty-state">Loading swarm live state…</div>`:va.value?o`<div class="empty-state error">${va.value}</div>`:e?o`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${e.run_id??t??"swarm-live"}</strong><small>${e.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((S=e.summary)==null?void 0:S.joined_workers)??0}/${((T=e.summary)==null?void 0:T.expected_workers)??0}</strong><small>${(($=e.summary)==null?void 0:$.live_workers)??0}개 가동 · ${((x=e.summary)==null?void 0:x.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${i} · ctx ${l}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(R=e.summary)!=null&&R.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((z=e.provider)==null?void 0:z.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(q=e.summary)!=null&&q.pass_end_to_end?"통과":"확인 필요"}</strong><small>${e.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((L=e.operation)==null?void 0:L.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((Q=e.squad)==null?void 0:Q.label)??"없음"}</span>
                      <span>실행체</span><span>${((Z=e.detachment)==null?void 0:Z.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((ae=e.summary)==null?void 0:ae.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((W=e.summary)==null?void 0:W.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((ee=e.provider)==null?void 0:ee.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${e.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${e.truth_notes.length>0?o`<div class="command-tag-row">
                          ${e.truth_notes.map(A=>o`<span class="command-tag">${A}</span>`)}
                        </div>`:null}
                    <${Jc} swarm=${e} />
                  `:o`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${w} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.checklist.length>0?o`<div class="command-card-stack">
                ${e.checklist.map(A=>o`<${Tg} item=${A} />`)}
              </div>`:o`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${w} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.workers.length>0?o`<div class="command-card-stack">
                ${e.workers.map(A=>o`<${Ig} worker=${A} />`)}
              </div>`:o`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${w} panelId="command.swarm" compact=${!0} />
          </div>
          ${e!=null&&e.provider?o`
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
                ${e.provider.detail?o`<div class="command-card-sub">${e.provider.detail}</div>`:null}
                ${e.provider.timeline.length>0?o`<div class="command-trace-stack">
                      ${e.provider.timeline.slice(-12).map(A=>o`
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
                    </div>`:o`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:o`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${w} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.blockers.length>0?o`<div class="command-card-stack">
                ${e.blockers.map(A=>o`<${Xc} blocker=${A} />`)}
              </div>`:o`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(e==null?void 0:e.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${w} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.recent_messages.length>0?o`<div class="command-trace-stack">
                ${e.recent_messages.map(A=>o`
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
              </div>`:o`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${w} panelId="command.trace" compact=${!0} />
          </div>
          ${e&&e.recent_trace_events.length>0?o`<div class="command-trace-stack">
                ${e.recent_trace_events.map(A=>o`<${Ki} event=${A} />`)}
              </div>`:o`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function Lg(e){return e==="swarm"?"스웜 실시간":"세션 요약"}function zg(e){switch(e){case"current":return"현재 과업 일치";case"drift":return"과업 드리프트";case"claim":return"착수 흔적 있음";case"no-claim":return"착수 흔적 없음";case"done":return"완료 흔적 있음";case"no-done":return"완료 흔적 없음";case"final":return"최종 보고 있음";case"no-final":return"최종 보고 없음";case"turn":return"턴 기록 있음";case"silent":return"턴 기록 없음";case"noted":return"노트 기록 있음";default:return e.startsWith("empty:")?`빈 노트 ${e.slice(6)}회`:e.startsWith("turns:")?`턴 ${e.slice(6)}회`:e}}function Pg(e){var n;const t=[e.current_task_matches_run?"current":"drift",e.claim_marker_seen?"claim":"no-claim",e.done_marker_seen?"done":"no-done",e.final_marker_seen?"final":"no-final"];return{key:`swarm:${e.name}`,name:e.name,role:e.role,lane:e.lane,status:e.status,source:"swarm",task:e.current_task??e.bound_task_title??e.bound_task_id??"할당 없음",heartbeat:e.heartbeat_age_sec!=null?`${Math.round(e.heartbeat_age_sec)}초`:e.heartbeat_fresh?"정상":"정보 없음",detail:[e.bound_task_status??null,e.detachment_member?"분견대 소속":null,e.squad_member?"분대 소속":null].filter(Boolean).join(" · ")||"스웜 실시간 카드",markers:t,note:((n=e.last_message)==null?void 0:n.content)??null}}function Mg(e,t){const n=e.actor??e.spawn_role??`워커-${t+1}`,s=e.spawn_role??e.worker_class??e.spawn_agent??"워커",a=e.lane_id??e.capsule_mode??e.control_domain??"세션",i=[e.has_turn?"turn":"silent",e.empty_note_turn_count>0?`empty:${e.empty_note_turn_count}`:"noted",e.turn_count>0?`turns:${e.turn_count}`:"turns:0"];return{key:`session:${n}:${t}`,name:n,role:s,lane:a,status:e.status,source:"session",task:e.task_profile??e.runtime_pool??"세션 레인",heartbeat:e.last_turn_ts_iso?X(e.last_turn_ts_iso):"정보 없음",detail:[e.spawn_agent??null,e.spawn_model??null,e.routing_confidence!=null?ps(e.routing_confidence):null].filter(Boolean).join(" · ")||"세션 요약 카드",markers:i,note:e.routing_reason??null}}function Pr(e){return P(e.severity)}function jg({worker:e}){return o`
    <article class="command-card compact warroom-worker-card ${P(Ht(e.status))}">
      <div class="command-card-head">
        <div>
          <strong>${e.name}</strong>
          <div class="command-card-sub">${e.role} · ${e.lane}</div>
        </div>
        <span class="command-chip ${P(Ht(e.status))}">${xt(e.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>출처</span><span>${Lg(e.source)}</span>
        <span>과업</span><span>${e.task}</span>
        <span>최근 신호</span><span>${e.heartbeat}</span>
        <span>근거</span><span>${e.detail}</span>
      </div>
      <div class="command-tag-row">
        ${e.markers.map(t=>o`<span class="command-tag">${zg(t)}</span>`)}
      </div>
      ${e.note?o`<div class="command-card-foot">${e.note}</div>`:null}
    </article>
  `}function Ze({label:e,surface:t,params:n={}}){return o`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(t){rt(t),ie("command",{...Ni(t),...n});return}ie("intervene")}}
    >
      ${e}
    </button>
  `}function Eg(){var ee,A,te,U,Ue,$t,K,Pe,ht,gn,$n,_s,fs,gs,$s,hs,ys,bs,Vi,Qi,Yi;const e=vs(),t=Et.value,n=ge.value,s=qe.value,a=hf(),i=t!=null&&t.operation?((ee=ls.value)==null?void 0:ee.operations.find(Y=>{var ks;return Y.operation.operation_id===((ks=t.operation)==null?void 0:ks.operation_id)}))??null:null,l=gf(),c=(t==null?void 0:t.workers)??[],p=(s==null?void 0:s.worker_cards)??[],m=l&&c.length>0?c.map(Pg):p.map(Mg),u=l,f=((A=e==null?void 0:e.decisions.summary)==null?void 0:A.pending)??0,_=(n==null?void 0:n.pending_confirms)??[],h=l?(t==null?void 0:t.blockers)??[]:[],b=(s==null?void 0:s.recommended_actions)??[],C=(te=s==null?void 0:s.active_recommended_actions)!=null&&te.length?s.active_recommended_actions:b,S=s==null?void 0:s.active_summary,T=(s==null?void 0:s.active_guidance_layer)??"fallback",$=(s==null?void 0:s.resident_judge_runtime)??(n==null?void 0:n.resident_judge_runtime),x=(s==null?void 0:s.attention_items)??[],R=((U=t==null?void 0:t.recent_messages[0])==null?void 0:U.timestamp)??null,z=((Ue=t==null?void 0:t.recent_trace_events[0])==null?void 0:Ue.timestamp)??null,q=l?R??z??null:null,L=a==null?void 0:a.summary,Q=(l?($t=t==null?void 0:t.summary)==null?void 0:$t.expected_workers:void 0)??(typeof(L==null?void 0:L.planned_worker_count)=="number"?L.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,Z=(l?(K=t==null?void 0:t.summary)==null?void 0:K.joined_workers:void 0)??(typeof(L==null?void 0:L.active_agent_count)=="number"?L.active_agent_count:void 0)??m.length,ae=h.length>0||f>0||_.length>0?"warn":u||a?"ok":"warn",W=l?((Pe=e==null?void 0:e.swarm_status)==null?void 0:Pe.lanes.filter(Y=>Y.present))??[]:[];return se(()=>{ke()},[]),se(()=>{a!=null&&a.session_id&&ln(a.session_id)},[a==null?void 0:a.session_id,n,(ht=t==null?void 0:t.detachment)==null?void 0:ht.session_id]),!u&&!a?ma.value||Fn.value?o`<div class="empty-state">실시간 워룸 불러오는 중…</div>`:o`
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
          <${Ze} label="작전 보기" surface="operations" />
          <${Ze} label="스웜 보기" surface="swarm" />
          <${Ze} label="개입 열기" />
          <${Ze} label="제어 보기" surface="control" />
        </div>
      </section>
    `:o`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${P(ae)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">실시간 워룸</span>
            <strong>${l?((gn=t==null?void 0:t.operation)==null?void 0:gn.objective)??(a==null?void 0:a.session_id)??"가동 중인 실행":(a==null?void 0:a.session_id)??"가동 중인 실행"}</strong>
            <div class="command-card-sub">
              ${l?(($n=t==null?void 0:t.operation)==null?void 0:$n.operation_id)??"작전 정보 없음":"세션 기준값"}
              ${a!=null&&a.session_id?` · 세션 ${a.session_id}`:""}
              ${l&&((_s=t==null?void 0:t.detachment)!=null&&_s.detachment_id)?` · 분견대 ${t.detachment.detachment_id}`:""}
            </div>
            ${S!=null&&S.summary?o`<div class="command-warroom-guidance ${Ta(T)}">
                  <strong>${Oi(T)}</strong>
                  <span>${S.summary}</span>
                </div>`:null}
          </div>
          <div class="command-action-row">
            <${Ze}
              label="스웜 상세"
              surface="swarm"
              params=${{...l&&((fs=t==null?void 0:t.operation)!=null&&fs.operation_id)?{operation_id:t.operation.operation_id}:{},...l&&(t!=null&&t.run_id)?{run_id:t.run_id}:{}}}
            />
            <${Ze} label="트레이스" surface="trace" />
            ${l&&i?o`<${Ze}
                  label="체인"
                  surface="chains"
                  params=${{operation:i.operation.operation_id}}
                />`:null}
            <${Ze} label="개입" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>워커</span>
            <strong>${Z??0}/${Q??0}</strong>
            <small>${l?((gs=t==null?void 0:t.summary)==null?void 0:gs.completed_workers)??0:0} 완료 · ${m.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>런타임</span>
            <strong>${l?($s=t==null?void 0:t.provider)!=null&&$s.runtime_blocker?"막힘":(hs=t==null?void 0:t.provider)!=null&&hs.provider_reachable?"준비됨":a?xt(a.status):"확인 필요":a?xt(a.status):"확인 필요"}</strong>
            <small>${l?`슬롯 ${((ys=t==null?void 0:t.provider)==null?void 0:ys.active_slots_now)??0}/${((bs=t==null?void 0:t.provider)==null?void 0:bs.actual_slots)??((Vi=t==null?void 0:t.provider)==null?void 0:Vi.total_slots)??0} · 컨텍스트 ${((Qi=t==null?void 0:t.provider)==null?void 0:Qi.actual_ctx)??((Yi=t==null?void 0:t.provider)==null?void 0:Yi.ctx_per_slot)??0}`:`세션 워커 ${(s==null?void 0:s.worker_cards.length)??0}`}</small>
          </div>
          <div class="monitor-stat-card ${P(h.length>0||f>0?"warn":"ok")}">
            <span>압력</span>
            <strong>${h.length+f+_.length}</strong>
            <small>막힘 ${h.length} · 승인 ${f} · 확인 ${_.length}</small>
          </div>
          <div class="monitor-stat-card ${P(Ta(T))}">
            <span>상주 판정기</span>
            <strong>${qi($)}</strong>
            <small>${Fi(S)}${$!=null&&$.model_used?` · ${$.model_used}`:""}</small>
          </div>
          <div class="monitor-stat-card">
            <span>마지막 신호</span>
            <strong>${X(q)}</strong>
            <small>${R?"메시지":z?"트레이스":"대기 중"}</small>
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
            ${W.length>0?o`
                  <${Yc} lanes=${W} />
                  <${Qc} lanes=${W} />
                `:a?o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${P(Ht(a.status))}">${xt(a.status)}</span>
                      </div>
                      <p>스웜 실시간 증거는 아직 약합니다. 이 카드는 세션 요약과 워커 기록을 기준으로 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${Cn(a.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${Cn(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:o`<div class="empty-state">보이는 레인이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">워커 현황</div>
              <${w} panelId="command.warroom" compact=${!0} />
            </div>
            ${m.length>0?o`<div class="command-card-stack">
                  ${m.map(Y=>o`<${jg} worker=${Y} />`)}
                </div>`:o`<div class="empty-state">활성 워커 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">상황 피드</div>
              <${w} panelId="command.warroom" compact=${!0} />
            </div>
            ${t&&t.recent_messages.length>0&&l?o`<div class="command-trace-stack">
                  ${t.recent_messages.map(Y=>o`
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
                </div>`:C.length>0||x.length>0?o`<div class="command-card-stack">
                    ${C.slice(0,4).map(Y=>o`
                      <article class="command-guide-card ${Pr(Y)}">
                        <div class="command-guide-head">
                          <strong>${Y.action_type}</strong>
                          <span class="command-chip ${Pr(Y)}">${Y.target_type}</span>
                        </div>
                        <p>${Y.reason}</p>
                      </article>
                    `)}
                    ${x.slice(0,3).map(Y=>o`
                      <article class="command-alert ${P(Y.severity)}">
                        <div class="command-card-head">
                          <strong>${Y.kind}</strong>
                          <span class="command-chip ${P(Y.severity)}">${Y.severity}</span>
                        </div>
                        <p>${Y.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?o`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((Y,ks)=>o`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>세션 이벤트 ${ks+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${ka(Y)}</pre>
                        </article>
                      `)}
                    </div>`:o`<div class="empty-state">메시지나 주의 항목이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">트레이스 흐름</div>
              <${w} panelId="command.trace" compact=${!0} />
            </div>
            ${t&&t.recent_trace_events.length>0?o`<div class="command-trace-stack">
                  ${t.recent_trace_events.map(Y=>o`<${Ki} event=${Y} />`)}
                </div>`:o`<div class="empty-state">실행 범위 트레이스 이벤트가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">압력</div>
              <${w} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&t?o`<${Jc} swarm=${t} />`:null}
              ${h.length>0?h.map(Y=>o`<${Xc} blocker=${Y} />`):o`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${f>0?o`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>승인 대기</strong>
                        <span class="command-chip warn">${f}</span>
                      </div>
                      <p>엄격 액션이 묶여 있습니다. 실제 승인 처리는 제어 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${_.length>0?o`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>확인 대기</strong>
                        <span class="command-chip warn">${_.length}</span>
                      </div>
                      <p>운영자 미리보기가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${_.slice(0,3).map(Y=>o`<span class="command-tag">${Y.confirm_token}</span>`)}
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
              ${l&&(t!=null&&t.operation)?o`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${t.operation.objective}</strong>
                          <div class="command-card-sub">${t.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${P(Ht(t.operation.status))}">${xt(t.operation.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>유닛</span><span>${t.operation.assigned_unit_id}</span>
                        <span>트레이스</span><span>${t.operation.trace_id}</span>
                        <span>자율성</span><span>${t.operation.autonomy_level??"정보 없음"}</span>
                        <span>최근 갱신</span><span>${X(t.operation.updated_at)}</span>
                      </div>
                    </article>
                  `:null}
              ${l&&(t!=null&&t.detachment)?o`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${t.detachment.detachment_id}</strong>
                          <div class="command-card-sub">${t.detachment.assigned_unit_id}</div>
                        </div>
                        <span class="command-chip ${P(Ht(t.detachment.status))}">${xt(t.detachment.status??"active")}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>리더</span><span>${t.detachment.leader_id??"미지정"}</span>
                        <span>편성</span><span>${t.detachment.roster.length}</span>
                        <span>세션</span><span>${t.detachment.session_id??"연결 없음"}</span>
                        <span>하트비트</span><span>${Ec(t.detachment.heartbeat_deadline)}</span>
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
                        <span class="command-chip ${P(Ht(a.status))}">${xt(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${Cn(a.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${Cn(a.remaining_sec)}</span>
                        <span>완료 변화량</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function Mr(e){switch((e??"").trim().toLowerCase()){case"active":return"가동 중";case"paused":return"일시정지";case"failed":return"실패";case"completed":case"done":return"완료";case"disconnected":return"끊김";case"preview":return"미리보기";case"captured":return"기록됨";default:return(e==null?void 0:e.trim())||"확인 필요"}}function Ng({source:e}){const t=hd(null),[n,s]=Yr(null);return se(()=>{let a=!1;const i=t.current;return i?(i.innerHTML="",s(null),(async()=>{try{const c=await ef(),{svg:p}=await c.render(`command-chain-${Z_()}`,e);if(a||!t.current)return;t.current.innerHTML=p}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid 렌더링에 실패했습니다")}})(),()=>{a=!0,t.current&&(t.current.innerHTML="")}):void 0},[e]),o`
    <div class="command-chain-graph-shell">
      ${n?o`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${t}></div>
    </div>
  `}function Dg({overlay:e,selected:t,onSelect:n}){const s=e.operation.chain,a=e.runtime;return o`
    <button class="command-chain-item ${t?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${e.operation.objective}</strong>
          <div class="command-card-sub">${e.operation.operation_id}</div>
        </div>
        <span class="command-chip ${lt(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??e.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?o`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?o`<span class="command-tag ${lt(s==null?void 0:s.status)}">${ps(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${Nc(e.history)}</div>
    </button>
  `}function wg({item:e}){return o`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${e.chain_id??"알 수 없는 체인"}</strong>
        <span class="command-chip ${lt(e.event)}">${e.event}</span>
      </div>
      <div class="command-card-sub">${X(e.timestamp)}</div>
      <div class="command-card-sub">${Nc(e)}</div>
    </article>
  `}function Og({node:e}){return o`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${e.id}</strong>
        <span class="command-chip ${lt(e.status)}">${e.status??"확인 필요"}</span>
      </div>
      <div class="command-card-sub">
        ${e.type??"노드"}
        ${typeof e.duration_ms=="number"?` · ${e.duration_ms}ms`:""}
      </div>
      ${e.error?o`<div class="command-card-sub error-text">${e.error}</div>`:null}
    </article>
  `}function qg({card:e}){const t=e.operation,n=`pause:${t.operation_id}`,s=`resume:${t.operation_id}`,a=`recall:${t.operation_id}`,i=t.chain,l=(i==null?void 0:i.run_id)??null;return o`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${t.objective}</strong>
          <div class="command-card-sub">${t.operation_id}</div>
        </div>
        <span class="command-chip ${P(t.status==="active"?"ok":t.status==="paused"?"warn":t.status==="failed"?"bad":"ok")}">${Mr(t.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${e.assigned_unit_label??t.assigned_unit_id}</span>
        <span>트레이스</span><span class="mono">${t.trace_id}</span>
        <span>자율성</span><span>${t.autonomy_level??"정보 없음"}</span>
        <span>예산 등급</span><span>${t.budget_class??"standard"}</span>
        <span>출처</span><span>${t.source??"managed"}</span>
        <span>최근 갱신</span><span>${X(t.updated_at)}</span>
      </div>
      ${i?o`
            <div class="command-tag-row">
              <span class="command-tag">${i.kind}</span>
              <span class="command-tag ${lt(i.status)}">${Mr(i.status)}</span>
              ${i.chain_id?o`<span class="command-tag">${i.chain_id}</span>`:null}
              ${i.run_id?o`<span class="command-tag">실행 ${i.run_id}</span>`:null}
            </div>
          `:null}
      ${t.checkpoint_ref?o`<div class="command-card-foot">체크포인트 ${t.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{rt("swarm"),ie("command",{surface:"swarm",operation_id:t.operation_id,...l?{run_id:l}:{}})}}
        >
          스웜 실시간 보기
        </button>
        ${i?o`
              <button
                class="control-btn ghost"
                onClick=${()=>{Ti(t.operation_id),rt("chains"),ie("command",{surface:"chains",operation:t.operation_id})}}
              >
                체인 열기
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="active"?o`
              <button class="control-btn ghost" disabled=${le(n)} onClick=${()=>ct(()=>Iv(t.operation_id))}>
                ${le(n)?"일시정지 중…":"일시정지"}
              </button>
              <button class="control-btn ghost" disabled=${le(a)} onClick=${()=>ct(()=>Lv(t.operation_id))}>
                ${le(a)?"회수 중…":"회수"}
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="paused"?o`
              <button class="control-btn ghost" disabled=${le(s)} onClick=${()=>ct(()=>Rv(t.operation_id))}>
                ${le(s)?"재개 중…":"재개"}
              </button>
            `:null}
      </div>
    </article>
  `}function Fg({card:e}){var n;const t=e.detachment;return o`
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
        <span>하트비트</span><span>${Ec(t.heartbeat_deadline)}</span>
        <span>최근 갱신</span><span>${X(t.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${t.heartbeat_deadline?o`<span class="command-tag ${Y_(t.heartbeat_deadline)}">
              기한 ${t.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Kg(){const e=Ke.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">작전</div>
          <${w} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.operations.operations.length>0?o`<div class="command-card-stack">
              ${e.operations.operations.map(t=>o`<${qg} card=${t} />`)}
            </div>`:o`<div class="empty-state">관리형 또는 투영된 작전이 없습니다.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">분견대</div>
          <${w} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${e.detachments.detachments.map(t=>o`<${Fg} card=${t} />`)}
            </div>`:o`<div class="empty-state">투영된 분견대가 없습니다.</div>`}
      </section>
    </div>
  `}function Ug(){var c,p,m,u,f,_,h,b,C,S,T,$,x,R,z,q;const e=ls.value,t=(e==null?void 0:e.operations)??[],n=Zt.value,s=t.find(L=>L.operation.operation_id===n)??t[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,i=((p=Un.value)==null?void 0:p.run)??(s==null?void 0:s.preview_run)??null,l=!((m=Un.value)!=null&&m.run)&&!!(s!=null&&s.preview_run);return se(()=>{a?Av(a):Cv()},[a]),o`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${w} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${lt(e==null?void 0:e.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp 연결</strong>
            <span class="command-chip ${lt(e==null?void 0:e.connection.status)}">${(e==null?void 0:e.connection.status)??"disconnected"}</span>
          </div>
          <p>${(e==null?void 0:e.connection.message)??"체인 요약은 MASC 프록시를 통해 집계됩니다."}</p>
          <div class="command-card-grid">
            <span>기준 URL</span><span>${(e==null?void 0:e.connection.base_url)??"정보 없음"}</span>
            <span>연결된 작전</span><span>${((u=e==null?void 0:e.summary)==null?void 0:u.linked_operations)??0}</span>
            <span>활성 체인</span><span>${((f=e==null?void 0:e.summary)==null?void 0:f.active_chains)??0}</span>
            <span>최근 실패</span><span>${((_=e==null?void 0:e.summary)==null?void 0:_.recent_failures)??0}</span>
            <span>마지막 이벤트</span><span>${X((h=e==null?void 0:e.summary)==null?void 0:h.last_history_event_at)}</span>
          </div>
        </article>

        ${fa.value?o`<div class="empty-state error">${fa.value}</div>`:null}

        ${Vo.value&&!e?o`<div class="empty-state">체인 오버레이 불러오는 중…</div>`:t.length>0?o`
                <div class="command-chain-list">
                  ${t.map(L=>o`
                    <${Dg}
                      overlay=${L}
                      selected=${(s==null?void 0:s.operation.operation_id)===L.operation.operation_id}
                      onSelect=${()=>Ti(L.operation.operation_id)}
                    />
                  `)}
                </div>
              `:o`<div class="empty-state">체인 기반 작전이 아직 없습니다.</div>`}

        <div class="command-chain-history">
          <div class="command-guide-head">
            <strong>최근 이력</strong>
            <span class="command-chip">${(e==null?void 0:e.recent_history.length)??0}</span>
          </div>
          ${e&&e.recent_history.length>0?o`
                <div class="command-card-stack">
                  ${e.recent_history.slice(0,6).map(L=>o`<${wg} item=${L} />`)}
                </div>
              `:o`<div class="empty-state">최근 체인 이력이 없습니다.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">체인 상세</div>
          <${w} panelId="command.chains" compact=${!0} />
        </div>
        ${s?o`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${lt((b=s.operation.chain)==null?void 0:b.status)}">
                    ${((C=s.operation.chain)==null?void 0:C.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>종류</span><span>${((S=s.operation.chain)==null?void 0:S.kind)??"chain_dsl"}</span>
                  <span>체인 ID</span><span>${((T=s.operation.chain)==null?void 0:T.chain_id)??"goal-driven"}</span>
                  <span>실행 ID</span><span>${a??"아직 구체화되지 않음"}</span>
                  <span>진행률</span><span>${ps(($=s.runtime)==null?void 0:$.progress)}</span>
                  <span>경과</span><span>${Cn((x=s.runtime)==null?void 0:x.elapsed_sec)}</span>
                  <span>최근 갱신</span><span>${X(((R=s.operation.chain)==null?void 0:R.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(z=s.operation.chain)!=null&&z.goal?o`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?o`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid 그래프</strong>
                        <span class="command-chip">${((q=s.operation.chain)==null?void 0:q.chain_id)??"graph"}</span>
                      </div>
                      <${Ng} source=${s.mermaid} />
                    </div>
                  `:o`<div class="empty-state">기록된 Mermaid 그래프가 아직 없습니다.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>실행 상세</strong>
                  <span class="command-chip ${(i==null?void 0:i.success)===!1?"bad":"ok"}">
                    ${i?i.success===!1?"실패":l?"미리보기":"기록됨":"대기 중"}
                  </span>
                </div>
                ${ga.value?o`<div class="empty-state">실행 상세 불러오는 중…</div>`:Hn.value?o`<div class="empty-state error">${Hn.value}</div>`:i&&i.nodes.length>0?o`
                          <div class="command-card-grid">
                            <span>체인</span><span>${i.chain_id}</span>
                            <span>실행</span><span>${i.run_id??"미리보기만 있음"}</span>
                            <span>지속시간</span><span>${i.duration_ms!=null?`${i.duration_ms}ms`:"정보 없음"}</span>
                            <span>노드</span><span>${i.nodes.length}</span>
                          </div>
                          ${l?o`<div class="command-card-foot">run-store에 기록되기 전, 설계된 체인으로 만든 미리보기입니다.</div>`:null}
                          <div class="command-card-stack">
                            ${i.nodes.map(L=>o`<${Og} node=${L} />`)}
                          </div>
                        `:o`<div class="empty-state">이 작전의 run-store 상세는 아직 없습니다.</div>`}
              </div>
            `:o`<div class="empty-state">그래프와 실행 상세를 보려면 체인 기반 작전을 고르세요.</div>`}
      </section>
    </div>
  `}function Hg(e){switch((e??"").trim().toLowerCase()){case"pending":return"대기 중";case"approved":return"승인됨";case"denied":return"거부됨";case"executed":return"실행됨";case"active":return"가동 중";default:return(e==null?void 0:e.trim())||"확인 필요"}}function Bg({decision:e}){const t=`approve:${e.decision_id}`,n=`deny:${e.decision_id}`,s=e.source==="projected_operator";return o`
    <article class="command-card ${P(e.status)}">
      <div class="command-card-head">
        <div>
          <strong>${e.requested_action}</strong>
          <div class="command-card-sub">${e.scope_type}:${e.scope_id}</div>
        </div>
        <span class="command-chip ${P(e.status)}">${Hg(e.status??"pending")}</span>
      </div>
      <div class="command-card-grid">
        <span>결정 ID</span><span>${e.decision_id}</span>
        <span>요청자</span><span>${e.requested_by??"알 수 없음"}</span>
        <span>출처</span><span>${e.source??"managed"}</span>
        <span>트레이스</span><span class="mono">${e.trace_id}</span>
        <span>생성 시각</span><span>${X(e.created_at)}</span>
        <span>이유</span><span>${e.reason??"정보 없음"}</span>
      </div>
      ${e.status==="pending"&&!s?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${le(t)} onClick=${()=>ct(()=>Pv(e.decision_id))}>
                ${le(t)?"승인 중…":"승인"}
              </button>
              <button class="control-btn ghost" disabled=${le(n)} onClick=${()=>ct(()=>Mv(e.decision_id))}>
                ${le(n)?"거부 중…":"거부"}
              </button>
            </div>
          `:null}
      ${s?o`<div class="command-card-foot">레거시 operator 승인입니다. 실제 실행은 operator control에서 처리합니다.</div>`:null}
    </article>
  `}function Wg({row:e}){var c,p,m;const t=e.unit,n=`freeze:${t.unit_id}`,s=`kill:${t.unit_id}`,a=!!((c=t.policy)!=null&&c.frozen),i=!!((p=t.policy)!=null&&p.kill_switch),l=Math.round((e.utilization??0)*100);return o`
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
        <span>킬 스위치</span><span>${i?"켜짐":"꺼짐"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${le(n)} onClick=${()=>ct(()=>jv(t.unit_id,!a))}>
          ${le(n)?"적용 중…":a?"동결 해제":"동결"}
        </button>
        <button class="control-btn ghost" disabled=${le(s)} onClick=${()=>ct(()=>Ev(t.unit_id,!i))}>
          ${le(s)?"적용 중…":i?"킬 스위치 해제":"킬 스위치 켜기"}
        </button>
      </div>
    </article>
  `}function Gg(){const e=Ke.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${w} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${e.decisions.decisions.map(t=>o`<${Bg} decision=${t} />`)}
            </div>`:o`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">유닛 제어</div>
          <${w} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${e.capacity.capacity.map(t=>o`<${Wg} row=${t} />`)}
            </div>`:o`<div class="empty-state">제어할 용량 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function Jg(){return o`
    <div class="command-surface-tabs grouped">
      ${nf.map(e=>o`
        <div class="command-tab-group" key=${e.id}>
          <span class="command-tab-group-label">${e.label}</span>
          <div class="command-tab-group-items">
            ${Dc.filter(t=>t.group===e.id).map(t=>o`
                <button
                  class="command-surface-tab ${V.value===t.id?"active":""}"
                  onClick=${()=>{rt(t.id),ie("command",Ni(t.id))}}
                >
                  ${t.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function Vg(){if(V.value==="warroom")return o`<${Eg} />`;if(V.value==="summary")return o`<${wf} />`;if(V.value==="orchestra")return o`<${Jf} />`;if(V.value==="swarm")return o`<${Rg} />`;if(!Ke.value)return o`<${Of} />`;switch(V.value){case"chains":return o`<${Ug} />`;case"topology":return o`<${_g} />`;case"alerts":return o`<${fg} />`;case"trace":return o`<${gg} />`;case"control":return o`<${Gg} />`;case"operations":default:return o`<${Kg} />`}}function Qg(){return se(()=>{Ut(),en(),Tv(),tt(),Rt()},[]),se(()=>{if(D.value.tab!=="command")return;const e=D.value.params.surface,t=D.value.params.operation,n=cs(D.value);if(kr(e))rt(e);else if(n){const s=$c(n);kr(s)&&rt(s)}else e||rt("warroom");t&&Ti(t),(e==="swarm"||e==="warroom"||e==="orchestra"||V.value==="warroom"||V.value==="orchestra")&&tt(),(e==="orchestra"||V.value==="orchestra")&&Rt(),(e==="warroom"||V.value==="warroom")&&ke()},[D.value.tab,D.value.params.surface,D.value.params.operation,D.value.params.operation_id,D.value.params.run_id,D.value.params.source,D.value.params.action_type,D.value.params.target_type,D.value.params.target_id,D.value.params.focus_kind]),se(()=>{let e=null;const t=()=>{e||(e=window.setTimeout(()=>{e=null,Ut(),en(),(V.value==="swarm"||V.value==="warroom"||V.value==="orchestra")&&tt(),V.value==="orchestra"&&Rt(),V.value==="warroom"&&ke()},250))},n=new EventSource(lf()),s=af.map(a=>{const i=()=>t();return n.addEventListener(a,i),{type:a,handler:i}});return n.onerror=()=>{t()},()=>{s.forEach(({type:a,handler:i})=>{n.removeEventListener(a,i)}),n.close(),e&&window.clearTimeout(e)}},[]),se(()=>{const e=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const t=V.value;t!=="swarm"&&t!=="warroom"&&t!=="orchestra"||(Ut(),tt(),t==="orchestra"&&Rt(),t==="warroom"&&ke())},5e3);return()=>{window.clearInterval(e)}},[]),o`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{ct(()=>zv())}}
            disabled=${le("dispatch:tick")}
          >
            ${le("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Ut(),en(),tt(),V.value==="warroom"&&ke()}}
            disabled=${ra.value}
          >
            ${ra.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${ca.value?o`<div class="empty-state error">${ca.value}</div>`:null}
      ${ua.value?o`<div class="empty-state error">${ua.value}</div>`:null}
      <${xe} surfaceId="command" />
      <${Mf} />
      ${V.value==="warroom"?null:o`<${jf} />`}
      <${Jg} />
      <${Vg} />
    </section>
  `}function Yg(){var S,T;const e=ge.value,t=bi.value,n=(e==null?void 0:e.room)??{},s=(e==null?void 0:e.pending_confirms)??[],a=e==null?void 0:e.pending_confirm_summary,i=a?a.confirm_required_actions:((e==null?void 0:e.available_actions)??[]).filter($=>$.confirm_required),l=((S=a==null?void 0:a.actor_filter)==null?void 0:S.trim())||null,c=(a==null?void 0:a.hidden_count)??0,p=(a==null?void 0:a.hidden_actors)??[],m=(e==null?void 0:e.recent_messages)??[],u=(t==null?void 0:t.recommended_actions)??[],f=(T=t==null?void 0:t.active_recommended_actions)!=null&&T.length?t.active_recommended_actions:u,_=t==null?void 0:t.active_summary,h=(t==null?void 0:t.resident_judge_runtime)??(e==null?void 0:e.resident_judge_runtime),b=(t==null?void 0:t.active_guidance_layer)??"fallback",C=m.slice(0,5);return o`
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
          <div class="ops-stat ${Yf(h)}">
            <span>Resident Judge</span>
            <strong>${qi(h)}</strong>
          </div>
        </div>

        <label class="control-label" for="ops-broadcast">Room 방송</label>
        <div class="control-row">
          <input
            id="ops-broadcast"
            class="control-input"
            type="text"
            placeholder="@agent 또는 room 전체 공지"
            value=${nn.value}
            onInput=${$=>{nn.value=$.target.value}}
            onKeyDown=${$=>{$.key==="Enter"&&Lr()}}
            disabled=${J.value}
          />
          <button class="control-btn" onClick=${()=>{Lr()}} disabled=${J.value||nn.value.trim()===""}>
            보내기
          </button>
        </div>

        <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
        <div class="control-row ops-split-row">
          <input
            id="ops-pause-reason"
            class="control-input"
            type="text"
            value=${xa.value}
            onInput=${$=>{xa.value=$.target.value}}
            disabled=${J.value}
          />
          <button class="control-btn ghost" onClick=${()=>{rg()}} disabled=${J.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{Hc()}} disabled=${J.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${sn.value}
          onInput=${$=>{sn.value=$.target.value}}
          disabled=${J.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${Gn.value}
          onInput=${$=>{Gn.value=$.target.value}}
          disabled=${J.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${Jn.value}
            onChange=${$=>{Jn.value=$.target.value}}
            disabled=${J.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{lg()}} disabled=${J.value||sn.value.trim()===""}>
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
        <article class="ops-guidance-card ${Ta(b)}">
          <div class="ops-guidance-head">
            <strong>${Oi(b)}</strong>
            <span>${(h==null?void 0:h.keeper_name)??(t==null?void 0:t.judgment_owner)??"judge 없음"}</span>
          </div>
          <div class="ops-guidance-body">
            ${(_==null?void 0:_.summary)??"현재 active guidance 요약이 없습니다. fallback queue만 표시합니다."}
          </div>
          <div class="ops-guidance-meta">
            <span>authoritative ${t!=null&&t.authoritative_judgment_available?"yes":"no"}</span>
            <span>${Fi(_)}</span>
            ${h!=null&&h.model_used?o`<span>${h.model_used}</span>`:null}
          </div>
        </article>
        ${Kn.value&&!t?o`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:f.length>0?o`
          <div class="ops-log-list">
            ${f.map($=>o`
              <article key=${`${$.action_type}:${$.target_type}:${$.target_id??"room"}`} class="ops-log-entry ${$.severity}">
                <div class="ops-log-head">
                  <strong>${Pt($.action_type)}</strong>
                  <span>${on($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                  <span>${Ia($.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${$.reason}</div>
                ${$.suggested_payload?o`
                  <div class="ops-confirmation-actions">
                    <button class="control-btn ghost" onClick=${()=>{og($)}} disabled=${J.value}>
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
          <${w} panelId="intervene.pending_confirmations" compact=${!0} />
        </div>
        <p class="ops-context-note">
          ${l?`현재 actor ${l} 기준 queue를 읽습니다. 승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다.`:"승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다."}
        </p>
        ${i.length>0?o`
          <div class="ops-log-list">
            ${i.map($=>o`
              <article key=${`${$.action_type}:${$.target_type}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${Pt($.action_type)}</strong>
                  <span>${on($.target_type)}</span>
                  <span>${Ia($.confirm_required)}</span>
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
                  <strong>${Pt($.action_type)}</strong>
                  <span>${on($.target_type)}${$.target_id?` · ${$.target_id}`:""}</span>
                  <span>${$.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${$.preview?o`<pre class="ops-code-block compact">${Aa($.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{zr($.confirm_token)}} disabled=${J.value}>
                    실행
                  </button>
                  <button class="control-btn ghost" onClick=${()=>{zr($.confirm_token,"deny")}} disabled=${J.value}>
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
          <${w} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${C.length>0?o`
          <div class="ops-feed-list">
            ${C.map($=>o`
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
  `}function Xg(){var m;const e=ge.value,t=qe.value,n=(e==null?void 0:e.sessions)??[],s=((e==null?void 0:e.available_actions)??[]).filter(u=>u.target_type==="team_session"),a=n.find(u=>u.session_id===cn.value)??n[0]??null,i=t==null?void 0:t.active_summary,l=(t==null?void 0:t.active_guidance_layer)??"fallback",c=(t==null?void 0:t.resident_judge_runtime)??(e==null?void 0:e.resident_judge_runtime),p=(m=t==null?void 0:t.active_recommended_actions)!=null&&m.length?t.active_recommended_actions:(t==null?void 0:t.recommended_actions)??[];return o`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${w} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?o`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(u=>{var f;return o`
            <button
              key=${u.session_id}
              class="ops-entity-card ${(a==null?void 0:a.session_id)===u.session_id?"active":""}"
              onClick=${()=>{cn.value=u.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${u.session_id}</strong>
                <span class="status-badge ${u.status??"idle"}">${Bt(u.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(u.progress_pct??0)}%</span>
                <span>${u.done_delta_total??0}건 완료</span>
                <span>${(f=u.team_health)!=null&&f.status?Bt(String(u.team_health.status)):"상태 확인 필요"}</span>
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
        ${a&&t?o`
          <article class="ops-guidance-card ${Ta(l)}">
            <div class="ops-guidance-head">
              <strong>${Oi(l)}</strong>
              <span>${qi(c)}</span>
            </div>
            <div class="ops-guidance-body">
              ${(i==null?void 0:i.summary)??"현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다."}
            </div>
            <div class="ops-guidance-meta">
              <span>authoritative ${t.authoritative_judgment_available?"yes":"no"}</span>
              <span>${Fi(i)}</span>
              ${c!=null&&c.model_used?o`<span>${c.model_used}</span>`:null}
            </div>
          </article>
          ${p.length>0?o`
            <div class="ops-log-list">
              ${p.map(u=>o`
                <article key=${`${u.action_type}:${u.target_type}:${u.target_id??"session"}`} class="ops-log-entry ${u.severity}">
                  <div class="ops-log-head">
                    <strong>${Pt(u.action_type)}</strong>
                    <span>${on(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
                  </div>
                  <div class="ops-log-body">${u.reason}</div>
                </article>
              `)}
            </div>
          `:null}
          <div class="ops-log-list">
            ${t.attention_items.length>0?t.attention_items.map(u=>o`
              <article key=${`${u.kind}:${u.target_id??"session"}`} class="ops-log-entry ${u.severity}">
                <div class="ops-log-head">
                  <strong>${u.kind}</strong>
                  <span>${on(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${u.summary}</div>
              </article>
            `):o`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${t.worker_cards.length>0?t.worker_cards.map(u=>o`
              <article key=${`${u.actor??u.spawn_role??"worker"}:${u.spawn_agent??u.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${u.actor??u.spawn_role??"worker"}</strong>
                  <span>${Bt(u.status)}</span>
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
          <${w} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>
        ${s.length>0?o`
          <div class="ops-log-list">
            ${s.map(u=>o`
              <article key=${u.action_type} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${Pt(u.action_type)}</strong>
                  <span>${Ia(u.confirm_required)}</span>
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
              <span>상태: ${Bt(a.status)}</span>
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
              <pre class="ops-code-block compact">${Aa(a.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:o`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${be.value}
            onChange=${u=>{be.value=u.target.value}}
            disabled=${J.value||!a}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
            <option value="worker_spawn_batch">worker 교체</option>
          </select>
          <button class="control-btn" onClick=${()=>{cg()}} disabled=${J.value||!a}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${tg(be.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${Vn.value}
          onInput=${u=>{Vn.value=u.target.value}}
          disabled=${J.value||!a}
        ></textarea>

        ${be.value==="task"?o`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${Qn.value}
            onInput=${u=>{Qn.value=u.target.value}}
            disabled=${J.value||!a}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${Yn.value}
            onInput=${u=>{Yn.value=u.target.value}}
            disabled=${J.value||!a}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${Xn.value}
            onChange=${u=>{Xn.value=u.target.value}}
            disabled=${J.value||!a}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
        `:be.value==="worker_spawn_batch"?o`
          <textarea
            class="control-textarea"
            rows=${6}
            placeholder='spawn_batch JSON, 예: [{"spawn_agent":"llama","spawn_prompt":"...", "spawn_role":"replacement"}]'
            value=${Zn.value}
            onInput=${u=>{Zn.value=u.target.value}}
            disabled=${J.value||!a}
          ></textarea>
        `:null}

        <div class="control-row ops-split-row">
          <input
            class="control-input"
            type="text"
            value=${Sa.value}
            onInput=${u=>{Sa.value=u.target.value}}
            disabled=${J.value||!a}
          />
          <button class="control-btn ghost" onClick=${()=>{dg()}} disabled=${J.value||!a}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function Zg(){var i;const e=ge.value,t=(e==null?void 0:e.keepers)??[],n=(e==null?void 0:e.persistent_agents)??[],s=(e==null?void 0:e.available_actions)??[],a=t.find(l=>l.name===Ca.value)??t[0]??null;return o`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${w} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${t.length===0?o`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:t.map(l=>o`
            <button
              key=${l.name}
              class="ops-entity-card ${(a==null?void 0:a.name)===l.name?"active":""}"
              onClick=${()=>{Ca.value=l.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${l.name}</strong>
                <span class="status-badge ${l.status??"idle"}">${Bt(l.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${l.model??"model 확인 필요"}</span>
                <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${Ir(l.last_turn_ago_s)}</span>
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
                    <span class="status-badge ${l.status??"idle"}">${Bt(l.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>persistent</span>
                    <span>${l.model??"model 확인 필요"}</span>
                    <span>${Ir(l.last_turn_ago_s)}</span>
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
          value=${an.value}
          onInput=${l=>{an.value=l.target.value}}
          disabled=${J.value||!a}
        ></textarea>
        <div class="control-row">
          <button class="control-btn" onClick=${()=>{ug()}} disabled=${J.value||!a||an.value.trim()===""}>
            keeper에 보내기
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">가능한 액션 목록</div>
          <${w} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
        <div class="ops-log-list">
          ${s.length?s.map(l=>o`
                <article key=${`${l.action_type}:${l.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${Pt(l.action_type)}</strong>
                    <span>${on(l.target_type)}</span>
                    <span>${Ia(l.confirm_required)}</span>
                  </div>
                  <div class="ops-log-body">${l.description??"설명이 아직 없습니다."}</div>
                </article>
              `):o`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 개입 로그</div>
          <${w} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <div class="ops-log-list">
          ${sa.value.length===0?o`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:sa.value.map(l=>o`
            <article key=${l.id} class="ops-log-entry ${l.outcome}">
              <div class="ops-log-head">
                <strong>${Pt(l.action_type)}</strong>
                <span>${l.target_label}</span>
                <span>${l.at}</span>
              </div>
              <div class="ops-log-body">${l.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function e$(){var R,z,q;const e=ge.value,t=D.value.tab==="intervene"?cs(D.value):null,n=bi.value,s=(e==null?void 0:e.room)??{},a=(e==null?void 0:e.sessions)??[],i=(e==null?void 0:e.keepers)??[],l=(e==null?void 0:e.pending_confirms)??[],c=e==null?void 0:e.pending_confirm_summary,p=(c==null?void 0:c.visible_count)??l.length,m=(c==null?void 0:c.total_count)??l.length,u=(c==null?void 0:c.hidden_count)??0,f=((R=c==null?void 0:c.actor_filter)==null?void 0:R.trim())||null,_=a.find(L=>L.session_id===cn.value)??a[0]??null,h=(n==null?void 0:n.attention_items)??[],b=h.filter(Zf),C=h.filter(eg),S=a.filter(L=>Xf(L)!=="ok"),T=i.filter(L=>ao(L)!=="ok"),$=ig(t,a,i);se(()=>{Mt()},[]),se(()=>{if(D.value.tab!=="intervene"){Is.value=null;return}if(!t){Is.value=null;return}Is.value!==t.id&&(Is.value=t.id,ag(t))},[D.value.tab,D.value.params.source,D.value.params.action_type,D.value.params.target_type,D.value.params.target_id,D.value.params.focus_kind,t==null?void 0:t.id]),se(()=>{const L=(_==null?void 0:_.session_id)??null;ln(L)},[_==null?void 0:_.session_id]);const x=[{key:"room",label:"방 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:u>0?`${p}/${m}`:p,detail:p>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":u>0&&f?`현재 개입 ID(${f}) 기준으로는 비어 있고, 다른 개입 ID 대기 ${u}건이 있습니다`:"지금 막혀 있는 확인 대기는 없습니다",tone:m>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:b.length>0?b.length:a.length,detail:b.length>0?((z=b[0])==null?void 0:z.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 팀 세션이 없습니다":"세션 쪽 긴급 주의 신호는 현재 없습니다",tone:b.length>0?Rr(b):a.length===0?"warn":S.some(L=>dn(L.status)==="paused")?"bad":S.length>0?"warn":"ok"},{key:"keeper",label:"키퍼 압력",value:C.length>0?C.length:T.length,detail:C.length>0?((q=C[0])==null?void 0:q.summary)??"직접 메시지나 상태 점검이 필요한 키퍼가 있습니다":T.length>0?"오래됐거나 오프라인이거나 텔레메트리가 비는 키퍼가 보입니다":"지금은 키퍼 쪽이 비교적 안정적입니다",tone:C.length>0?Rr(C):T.some(L=>ao(L)==="bad")?"bad":T.length>0?"warn":"ok"}];return o`
    <section class="ops-view">
      <${xe} surfaceId="intervene" />
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
            value=${Wa.value}
            onInput=${L=>Qf(L.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{ke(),Mt(),ln((_==null?void 0:_.session_id)??null)}}
            disabled=${Fn.value||J.value}
          >
            ${Fn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${ut.value?o`<section class="ops-banner error">${ut.value}</section>`:null}
      ${rn.value?o`<section class="ops-banner error">${rn.value}</section>`:null}
      ${t?o`
        <section class="ops-banner ${$?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${t.source_label}</strong>
            <span>${Ha(t.action_type)}</span>
            <span>${zi(t)}</span>
          </div>
          <div class="ops-handoff-body">${t.summary}</div>
          ${t.payload_preview?o`<div class="ops-handoff-preview">${t.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${$?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const L=[];if((p>0||u>0)&&L.push({label:u>0?`확인 대기 ${p}/${m}건 확인`:`확인 대기 ${p}건 처리`,desc:u>0&&f?`현재 개입 ID(${f}) 기준으로 보이는 대기열을 먼저 확인합니다`:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:p>0?"bad":"warn",onClick:()=>{const Q=document.querySelector(".ops-pending-section");Q==null||Q.scrollIntoView({behavior:"smooth"})}}),s.paused&&L.push({label:"방 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void Hc()}),T.length>0){const Q=T.filter(Z=>ao(Z)==="bad");L.push({label:Q.length>0?`오프라인 키퍼 ${Q.length}개`:`점검이 필요한 키퍼 ${T.length}개`,desc:Q.length>0?"메시지를 보내거나 상태를 확인하세요":"오래됐거나 텔레메트리가 비어 있습니다",tone:Q.length>0?"bad":"warn",onClick:()=>{const Z=document.querySelector(".ops-keeper-section");Z==null||Z.scrollIntoView({behavior:"smooth"})}})}return L.length===0?null:o`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${L.slice(0,3).map(Q=>o`
                <button class="ops-action-guide-item ${Q.tone}" onClick=${Q.onClick}>
                  <strong>${Q.label}</strong>
                  <span>${Q.desc}</span>
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
          ${x.map(L=>o`
            <div key=${L.key} class="ops-priority-card ${L.tone}">
              <span class="ops-priority-label">${L.label}</span>
              <strong>${L.value}</strong>
              <div class="ops-priority-detail">${L.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${Yg} />
        <${Xg} />
        <${Zg} />
      </div>
    </section>
  `}function t$({text:e}){if(!e)return null;const t=n$(e);return o`<div class="markdown-content">${t}</div>`}function n$(e){const t=e.split(`
`),n=[];let s=0;for(;s<t.length;){const a=t[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),p=[];for(s++;s<t.length&&!t[s].startsWith(l);)p.push(t[s]),s++;s++,n.push(o`<pre><code class=${c?`language-${c}`:""}>${p.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<t.length&&!t[s].includes("</think>");)l.push(t[s]),s++;if(s<t.length){const m=t[s].replace("</think>","").trim();m&&l.push(m),s++}const p=l.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${oo(p)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<t.length&&t[s].startsWith("> ");)l.push(t[s].slice(2)),s++;n.push(o`<blockquote>${oo(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<t.length;){const l=t[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;i.push(l),s++}i.length>0&&n.push(o`<p>${oo(i.join(`
`))}</p>`)}return n}function oo(e){const t=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(e))!==null;){if(a.index>s&&t.push(e.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);t.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);t.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);t.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&t.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<e.length&&t.push(e.slice(s)),t.length>0?t:[e]}const Zc=[{id:"recent",label:"최신순"},{id:"hot",label:"인기순"},{id:"trending",label:"급상승"},{id:"updated",label:"최근 갱신"},{id:"discussed",label:"토론 많은 순"}],Gs=g(null),Js=g([]),un=g(!1),zt=g(null),Pn=g(""),Mn=g(!1),Wt=g(!0),Ui=20,Ot=g(Ui);function s$(){var t,n;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const a$=g(s$());function o$(e){const t=e.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return t?t.length>180?`${t.slice(0,177)}...`:t:"미리보기 없음"}function jr(e){return e.updated_at!==e.created_at}function i$(e){if(e.post_kind)return e.post_kind==="automation";const t=(e.hearth??"").toLowerCase();return e.visibility!=="internal"||!e.expires_at||!t?!1:!!(t.startsWith("mdal")||t.includes("harness"))}function r$(e){return e==="lodge-system"||e==="team-session"}function es(e){return e.post_kind?e.post_kind:r$(e.author)?"system":i$(e)?"automation":"human"}function ed(e){const t=[],n=[];let s=0;return e.forEach(a=>{const i=es(a);if(!(i==="system"&&At.value)){if(i==="automation"&&Wt.value){s+=1;return}if(i==="human"){t.push(a);return}n.push(a)}}),{human:t,operations:n,hiddenAutomation:s}}function l$(e){if(!e.expires_at)return null;const t=Date.parse(e.expires_at);return Number.isFinite(t)?t<=Date.now()?o`<span class="board-meta-chip">만료됨</span>`:o`<span class="board-meta-chip">만료까지 <${G} timestamp=${e.expires_at} /></span>`:null}async function Hi(e){zt.value=e,Gs.value=null,Js.value=[],un.value=!0;try{const t=await yu(e);if(zt.value!==e)return;Gs.value={id:t.id,author:t.author,title:t.title,body:t.body,content:t.content,meta:t.meta,tags:t.tags,votes:t.votes,vote_balance:t.vote_balance,comment_count:t.comment_count,created_at:t.created_at,updated_at:t.updated_at,post_kind:t.post_kind,flair:t.flair,hearth:t.hearth,visibility:t.visibility,expires_at:t.expires_at,hearth_count:t.hearth_count},Js.value=t.comments??[]}catch{zt.value===e&&(Gs.value=null,Js.value=[])}finally{zt.value===e&&(un.value=!1)}}async function Er(e){const t=Pn.value.trim();if(t){Mn.value=!0;try{await bu(e,a$.value,t),Pn.value="",M("댓글을 등록했습니다","success"),await Hi(e),ot()}catch{M("댓글 등록에 실패했습니다","error")}finally{Mn.value=!1}}}function c$(){const e=On.value,t=Wt.value?"자동화 글 숨김":"자동화 글 표시 중";return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Zc.map(n=>o`
          <button
            class="board-sort-btn ${e===n.id?"active":""}"
            onClick=${()=>{On.value=n.id,Ot.value=Ui,ot()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Wt.value?"is-active":""}"
          onClick=${()=>{Wt.value=!Wt.value}}
        >
          ${t}
        </button>
        <button
          class="control-btn ghost ${At.value?"is-active":""}"
          onClick=${()=>{At.value=!At.value,ot()}}
        >
          ${At.value?"시스템 글 숨김":"시스템 글 표시 중"}
        </button>
        <button class="control-btn ghost" onClick=${ot} disabled=${qn.value}>
          ${qn.value?"새로고침 중...":"새로고침"}
        </button>
      </div>
    </div>
  `}function io(){var s;const e=((s=Zc.find(a=>a.id===On.value))==null?void 0:s.label)??On.value,t=ed(Ka.value),n=t.human.length+t.operations.length;return o`
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
        <strong>${Wt.value?`자동화 ${t.hiddenAutomation}건 숨김`:"분리된 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">시스템 글 정책</span>
        <strong>${At.value?"시스템 글 숨김":"시스템 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">최근 갱신</span>
        <strong>${Ko.value?o`<${G} timestamp=${Ko.value} />`:"아직 불러오지 않음"}</strong>
      </div>
    </div>
  `}function Nr({post:e}){const t=async(n,s)=>{s.stopPropagation();try{await vl(e.id,n),ot()}catch{M("투표에 실패했습니다","error")}};return o`
    <div class="board-post" onClick=${()=>Sd(e.id)}>
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
                ${jr(e)?o`<span class="board-meta-chip">수정됨</span>`:null}
                ${es(e)!=="human"?o`<span class="board-meta-chip">${es(e)}</span>`:null}
                ${e.hearth?o`<span class="board-meta-chip">${e.hearth}</span>`:null}
                ${e.visibility?o`<span class="board-meta-chip">${e.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>작성자 ${e.author}</span>
            <span><${G} timestamp=${e.created_at} /></span>
            ${jr(e)?o`<span>수정 <${G} timestamp=${e.updated_at} /></span>`:null}
            <span>댓글 ${e.comment_count}</span>
            <span>투표 ${e.votes??0}</span>
          </div>
        </div>
        <div class="post-snippet">${o$(e.body)}</div>
      </div>
    </div>
  `}function d$({comments:e}){return e.length===0?o`<div class="empty-state" style="font-size:13px">아직 댓글이 없습니다</div>`:o`
    <div class="comment-thread">
      ${e.map(t=>o`
        <div key=${t.id} class="board-comment">
          <span class="comment-author">${t.author}</span>
          <span class="comment-time"><${G} timestamp=${t.created_at} /></span>
          <div class="comment-text">${t.content}</div>
        </div>
      `)}
    </div>
  `}function u$({postId:e}){return o`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="댓글 추가..."
        value=${Pn.value}
        onInput=${t=>{Pn.value=t.target.value}}
        onKeyDown=${t=>{t.key==="Enter"&&Er(e)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Mn.value}
      />
      <button
        onClick=${()=>Er(e)}
        disabled=${Mn.value||Pn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Mn.value?"...":"등록"}
      </button>
    </div>
  `}function p$({post:e}){zt.value!==e.id&&!un.value&&Hi(e.id);const t=async n=>{try{await vl(e.id,n),ot()}catch{M("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>ie("memory")}>← 메모리로 돌아가기</button>
      <${I} title=${e.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${t$} text=${e.body} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${e.author}</span>
            <${G} timestamp=${e.created_at} />
            <span>${e.votes??0} votes</span>
          </div>
          ${e.hearth||e.visibility||e.expires_at?o`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${e.hearth?o`<span class="board-meta-chip">${e.hearth}</span>`:null}
                  ${e.visibility?o`<span class="board-meta-chip">${e.visibility}</span>`:null}
                  ${es(e)!=="human"?o`<span class="board-meta-chip">${es(e)}</span>`:null}
                  ${l$(e)}
                </div>
              `:null}
          ${e.meta?o`
                <details style="margin-top:12px;">
                  <summary>운영 메타</summary>
                  <div class="post-body" style="margin-top:8px;">
                    ${e.meta.source?o`<div><strong>출처</strong>: ${e.meta.source}</div>`:null}
                    ${e.meta.state_block?o`<pre style="white-space:pre-wrap; margin-top:8px;">${e.meta.state_block}</pre>`:null}
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
        ${un.value?o`<div class="loading-indicator">댓글 불러오는 중...</div>`:o`<${d$} comments=${Js.value} />`}
        <${u$} postId=${e.id} />
      <//>
    </div>
  `}function m$(){const e=ed(Ka.value),t=[...e.human,...e.operations],n=D.value.params.post??null,s=n?t.find(a=>a.id===n)??(zt.value===n?Gs.value:null):null;return n&&!s&&zt.value!==n&&!un.value&&Hi(n),n?s?o`
          <${xe} surfaceId="memory" />
          <${io} />
          <${p$} post=${s} />
        `:o`
          <div>
            <${xe} surfaceId="memory" />
            <${io} />
            <button class="back-btn" onClick=${()=>ie("memory")}>← 메모리로 돌아가기</button>
            ${un.value?o`<div class="loading-indicator">글 불러오는 중...</div>`:o`<div class="empty-state">글을 찾지 못했습니다</div>`}
          </div>
        `:o`
    <div>
      <${xe} surfaceId="memory" />
      <${io} />
      <${c$} />
      ${qn.value?o`<div class="loading-indicator">메모리 피드 불러오는 중...</div>`:t.length===0?o`<div class="empty-state">지금은 남아 있는 메모리 글이 없습니다</div>`:o`
              <${I} title="사람이 쓴 글" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${e.human.slice(0,Ot.value).map(a=>o`<${Nr} key=${a.id} post=${a} />`)}
                </div>
                ${e.human.length>Ot.value?o`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{Ot.value=Ot.value+Ui}}
                    >
                      더 보기 (${e.human.length-Ot.value}개 남음)
                    </button>
                  </div>
                `:null}
              <//>
              ${e.operations.length>0?o`
                    <${I} title="자동화 · 시스템" class="section" semanticId="memory.feed">
                      <div class="board-post-list">
                        ${e.operations.map(a=>o`<${Nr} key=${a.id} post=${a} />`)}
                      </div>
                    <//>
                  `:null}
            `}
    </div>
  `}function v$({ratio:e,size:t=40,stroke:n=4}){if(e==null)return null;const s=(t-n)/2,a=t/2,i=2*Math.PI*s,l=i*((100-e*100)/100);let c="mitosis-safe";return e>=.8?c="mitosis-critical":e>=.5&&(c="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(e*100)}%">
      <svg class="mitosis-ring" width="${t}" height="${t}" viewBox="0 0 ${t} ${t}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${c}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${l}" 
        />
      </svg>
      <span class="mitosis-text ${c}">${Math.round(e*100)}%</span>
    </div>
  `}const St=g(null),He=g(null),Be=g(null);function pn(e){return e==="bad"||e==="critical"||e==="offline"?"bad":e==="warn"||e==="paused"||e==="blocked"||e==="interrupted"?"warn":"ok"}function Ra(e){switch((e??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":return"주의";case"bad":case"critical":return"위험";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function _$(e){return e==="session"?"세션":"작전"}function f$(e){return typeof e!="number"||Number.isNaN(e)?"—":`${Math.round(e*100)}%`}function g$(e){return e?_t.value.find(t=>t.name===e||t.agent_name===e)??null:null}function $$(e){switch(e){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function h$(e){switch(e){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function y$(e){switch(e){case"acted":return"행동";case"passed":return"통과";case"skipped":return"건너뜀";case"failed":return"실패";default:return e}}function b$(e){switch(e){case"post":return"post";case"comment":return"comment";case"vote":return"vote";case"none":case null:case void 0:return"none";default:return e}}function La(e,t="없음"){const n=e??[];return n.length===0?t:n.length<=3?n.join(", "):`${n.slice(0,3).join(", ")} +${n.length-3}`}function Dr(e){if(!e)return;const t=Hv({targetType:e.target_type,targetId:e.target_id,focusKind:e.focus_kind,operationId:e.operation_id??null,commandSurface:e.command_surface??null,sourceLabel:"실행 진단",summary:e.label});fc(t),ie(e.surface,e.surface==="intervene"?gc(t):hc(t))}function Re({label:e,value:t,color:n,caption:s}){return o`
    <div class="stat-card">
      <div class="stat-label">${e}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${t}</div>
      ${s?o`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function Bi({intervene:e,command:t}){return o`
    <div class="control-row">
      ${e?o`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),Dr(e)}}
            >
              ${e.label}
            </button>
          `:null}
      ${t?o`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),Dr(t)}}
            >
              ${t.label}
            </button>
          `:null}
    </div>
  `}function k$({item:e,selected:t}){return o`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{St.value=t?null:e.id,He.value=null,Be.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.kind==="session"?e.target_id:e.linked_session_id??e.target_id}</div>
          <div class="mission-card-title">${e.summary}</div>
        </div>
        <span class="command-chip ${pn(e.severity)}">${Ra(e.status??e.severity)}</span>
      </div>
      <div class="mission-card-meta">
        <span>${_$(e.kind)}</span>
        ${e.linked_operation_id?o`<span>연결 작전 · ${e.linked_operation_id}</span>`:null}
        ${e.last_seen_at?o`<span><${G} timestamp=${e.last_seen_at} /></span>`:null}
      </div>
      <${Bi} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function x$({brief:e,selected:t}){return o`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.session-card"
      onClick=${()=>{He.value=t?null:e.session_id,Be.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          <div class="mission-card-title">${e.goal}</div>
        </div>
        <span class="command-chip ${pn(e.health??e.status)}">${Ra(e.status)}</span>
      </div>
      <div class="mission-card-meta">
        <span>건강도 · ${Ra(e.health??"ok")}</span>
        ${e.linked_operation_id?o`<span>연결 작전 · ${e.linked_operation_id}</span>`:null}
        ${e.last_activity_at?o`<span><${G} timestamp=${e.last_activity_at} /></span>`:null}
      </div>
      ${e.runtime_blocker?o`<div class="mission-card-detail">${e.runtime_blocker}</div>`:e.last_activity_summary?o`<div class="mission-card-detail">${e.last_activity_summary}</div>`:null}
      ${e.worker_gap_summary?o`<div class="monitor-footnote">${e.worker_gap_summary}</div>`:null}
      <${Bi} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function S$({brief:e,selected:t}){return o`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.operation-card"
      onClick=${()=>{Be.value=t?null:e.operation_id,He.value=e.linked_session_id??null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.operation_id}${e.assigned_unit_label?` · ${e.assigned_unit_label}`:""}</div>
          <div class="mission-card-title">${e.objective}</div>
        </div>
        <span class="command-chip ${pn(e.blocker_summary?"warn":e.status)}">${Ra(e.status)}</span>
      </div>
      <div class="mission-card-meta">
        ${e.stage?o`<span>단계 · ${e.stage}</span>`:null}
        ${e.linked_session_id?o`<span>세션 · ${e.linked_session_id}</span>`:null}
        ${e.updated_at?o`<span><${G} timestamp=${e.updated_at} /></span>`:null}
      </div>
      ${e.blocker_summary?o`<div class="mission-card-detail">${e.blocker_summary}</div>`:null}
      ${e.next_tool?o`<div class="monitor-footnote">다음 도구 · ${e.next_tool}</div>`:null}
      <${Bi} command=${e.command_handoff} />
    </button>
  `}function C$({tick:e}){return e?o`
    <div class="monitor-nested-card">
      <div class="stats-grid">
        <${Re} label="checked" value=${e.checked??0} color="#22d3ee" />
        <${Re} label="acted" value=${e.acted??0} color="#4ade80" />
        <${Re} label="passed" value=${e.passed??0} color="#94a3b8" />
        <${Re} label="skipped" value=${e.skipped??0} color="#fbbf24" />
        <${Re} label="failed" value=${e.failed??0} color="#fb7185" />
      </div>
      <div class="monitor-meta">
        ${e.last_tick_at?o`<span>마지막 tick <${G} timestamp=${e.last_tick_at} /></span>`:o`<span>마지막 tick 없음</span>`}
        ${e.last_skip_reason?o`<span>대표 skip 이유 · ${e.last_skip_reason}</span>`:null}
      </div>
      ${e.activity_report?o`<div class="monitor-footnote">${e.activity_report}</div>`:null}
    </div>
  `:o`<div class="empty-state">최근 lodge tick 기록이 없습니다.</div>`}function A$({row:e}){return o`
    <button
      class="monitor-row ${pn(e.outcome==="failed"?"bad":e.outcome==="skipped"?"warn":"ok")}"
      data-testid="execution.lodge-checkin-card"
      onClick=${()=>us(e.agent_name)}
    >
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.agent_name}</span>
            ${e.worker_name?o`<span class="monitor-sub">worker · ${e.worker_name}</span>`:null}
          </div>
          <div class="monitor-note">${e.reason??e.summary??"이유가 기록되지 않았습니다."}</div>
        </div>
        <span class="monitor-pill ${pn(e.outcome==="failed"?"bad":e.outcome==="skipped"?"warn":"ok")}">${y$(e.outcome)}</span>
      </div>
      <div class="monitor-meta">
        <span>trigger · ${e.trigger??"unknown"}</span>
        ${e.checked_at?o`<span><${G} timestamp=${e.checked_at} /></span>`:null}
        <span>action · ${b$(e.action_kind)}</span>
        <span>allow ${e.allowed_tool_names.length}</span>
        <span>used ${e.used_tool_names.length}</span>
      </div>
      ${e.summary&&e.summary!==e.reason?o`<div class="monitor-focus">${e.summary}</div>`:null}
      <div class="monitor-footnote">
        허용 도구: ${La(e.allowed_tool_names)} · 사용 도구: ${La(e.used_tool_names)}
      </div>
      ${e.failure_reason||e.decision_reason?o`<div class="monitor-footnote">
            ${e.failure_reason?`실패 이유: ${e.failure_reason}`:`판단 이유: ${e.decision_reason}`}
          </div>`:null}
    </button>
  `}function wr({row:e,testId:t}){return o`
    <button class="monitor-row ${e.tone} state-${e.state}" data-testid=${t} onClick=${()=>us(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.korean_name?o`<span class="monitor-sub">${e.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${e.note}</div>
        </div>
        <${gt} status=${e.status??"unknown"} />
        <span class="monitor-pill ${e.tone} state-${e.state}">${$$(e.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_signal_at?o`<span>신호 <${G} timestamp=${e.last_signal_at} /></span>`:o`<span>최근 신호 없음</span>`}
        <span>${(e.active_task_count??0)>0?`활성 작업 ${e.active_task_count}개`:"활성 작업 없음"}</span>
        ${e.related_session_id?o`<span>세션 · ${e.related_session_id}</span>`:null}
        ${e.related_operation_id?o`<span>작전 · ${e.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.recent_output_preview&&e.recent_output_preview!==e.focus?o`<div class="monitor-footnote">최근 상세: ${e.recent_output_preview}</div>`:null}
    </button>
  `}function T$({row:e}){var n,s;const t=()=>{const a=g$(e.name);a&&Mc(a)};return o`
    <button class="monitor-row ${e.tone} state-${e.state}" data-testid="execution.continuity-card" onClick=${t}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.korean_name?o`<span class="monitor-sub">${e.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${e.note}</div>
        </div>
        <${v$} ratio=${e.context_ratio??0} size=${34} stroke=${4} />
        <${gt} status=${e.status??"unknown"} />
        <span class="monitor-pill ${e.tone}">${h$(e.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_signal_at?o`<span>최근 활동 <${G} timestamp=${e.last_signal_at} /></span>`:o`<span>최근 활동 없음</span>`}
        ${e.related_session_id?o`<span>세션 · ${e.related_session_id}</span>`:null}
        ${e.continuity?o`<span>${e.continuity}</span>`:null}
        ${e.lifecycle?o`<span>생애주기 ${e.lifecycle}</span>`:null}
        <span>컨텍스트 ${f$(e.context_ratio)}</span>
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.continuity_summary||e.recent_output_preview?o`<div class="monitor-footnote">${e.continuity_summary??e.recent_output_preview}</div>`:null}
      ${e.skill_route_summary||e.tool_audit_source?o`<div class="monitor-footnote">
            ${e.skill_route_summary?`route · ${e.skill_route_summary}`:""}
            ${e.tool_audit_source?`${e.skill_route_summary?" · ":""}audit · ${e.tool_audit_source}`:""}
            ${e.tool_audit_at?o` · <${G} timestamp=${e.tool_audit_at} />`:null}
          </div>`:null}
      ${(((n=e.recent_tool_names)==null?void 0:n.length)??0)>0||(((s=e.allowed_tool_names)==null?void 0:s.length)??0)>0?o`<div class="monitor-footnote">
            recent tools: ${La(e.recent_tool_names)} · allowed: ${La(e.allowed_tool_names)}
          </div>`:null}
    </button>
  `}function I$(){const e=hl.value,t=yl.value,n=bl.value,s=kl.value,a=xl.value,i=Sl.value,l=_i.value,c=fi.value,p=Cl.value;St.value&&!t.some($=>$.id===St.value)&&(St.value=null),He.value&&!n.some($=>$.session_id===He.value)&&(He.value=null),Be.value&&!s.some($=>$.operation_id===Be.value)&&(Be.value=null);const m=St.value?t.find($=>$.id===St.value)??null:null,u=He.value?He.value:m?m.kind==="session"?m.target_id:m.linked_session_id??null:null,f=Be.value?Be.value:m?m.kind==="operation"?m.target_id:m.linked_operation_id??null:null,_=u?n.filter($=>$.session_id===u):f?n.filter($=>$.linked_operation_id===f):n,h=f?s.filter($=>$.operation_id===f):u?s.filter($=>{var x;return $.linked_session_id===u||$.operation_id===((x=_[0])==null?void 0:x.linked_operation_id)}):s,b=u||f?a.filter($=>(u?$.related_session_id===u:!1)||(f?$.related_operation_id===f:!1)):a,C=u?c.filter($=>$.related_session_id===u||$.tone!=="ok"):c,S=u?l.filter($=>_.some(x=>x.member_names.includes($.agent_name))):l,T=u||f?p.filter($=>(u?$.related_session_id===u:!1)||(f?$.related_operation_id===f:!1)||$.tone!=="ok"):p;return o`
    <div class="agents-monitor">
      <${xe} surfaceId="execution" />
      <div class="stats-grid">
        <${Re} label="활성 세션" value=${(e==null?void 0:e.active_sessions)??n.length} color="#4ade80" caption="실행 관점 세션 수" />
        <${Re} label="막힌 세션" value=${(e==null?void 0:e.blocked_sessions)??n.filter($=>pn($.health??$.status)!=="ok").length} color="#fbbf24" caption="개입이 필요한 세션 수" />
        <${Re} label="활성 작전" value=${(e==null?void 0:e.active_operations)??s.length} color="#22d3ee" caption="지휘 평면 작전 수" />
        <${Re} label="막힌 작전" value=${(e==null?void 0:e.blocked_operations)??s.filter($=>$.blocker_summary).length} color="#fb7185" caption="원인 확인이 필요한 작전 수" />
        <${Re} label="인력 경고" value=${(e==null?void 0:e.worker_alerts)??a.filter($=>$.tone!=="ok").length} color="#fb7185" caption="지원 인력 압박" />
        <${Re} label="연속성 경고" value=${(e==null?void 0:e.continuity_alerts)??c.filter($=>$.tone!=="ok").length} color="#fb7185" caption="키퍼 연속성 압박" />
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
          ${t.length===0?o`<div class="empty-state">지금은 막힌 실행이 없습니다.</div>`:t.map($=>o`<${k$} key=${$.id} item=${$} selected=${St.value===$.id} />`)}
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
            ${_.length===0?o`<div class="empty-state">선택된 실행과 연결된 세션이 없습니다.</div>`:_.map($=>o`<${x$} key=${$.session_id} brief=${$} selected=${He.value===$.session_id} />`)}
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
            ${h.length===0?o`<div class="empty-state">선택된 실행과 연결된 작전이 없습니다.</div>`:h.map($=>o`<${S$} key=${$.operation_id} brief=${$} selected=${Be.value===$.operation_id} />`)}
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
          <${C$} tick=${i} />
          <div class="monitor-list">
            ${S.length===0?o`<div class="empty-state">최근 lodge check-in 기록이 없습니다.</div>`:S.map($=>o`<${A$} key=${`${$.agent_name}-${$.checked_at??$.outcome}`} row=${$} />`)}
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
            ${b.length===0?o`<div class="empty-state">연결된 작업자가 없습니다.</div>`:b.map($=>o`<${wr} key=${$.name} row=${$} testId="execution.worker-card" />`)}
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
            ${C.length===0?o`<div class="empty-state">지금은 연속성 경고가 없습니다.</div>`:C.map($=>o`<${T$} key=${$.name} row=${$} />`)}
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
            ${T.length===0?o`<div class="empty-state">지금은 오프라인 작업자가 없습니다.</div>`:T.map($=>o`<${wr} key=${$.name} row=${$} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const ei=g(null),ti=g(null),jn=g(!1);async function Or(){if(!jn.value){jn.value=!0,ti.value=null;try{ei.value=await tu()}catch(e){ti.value=e instanceof Error?e.message:String(e)}finally{jn.value=!1}}}function R$(e){switch(e){case"essential":return"badge-essential";case"standard":return"badge-standard";default:return"badge-full"}}function L$({items:e,maxCount:t}){return e.length===0?o`<p class="muted">No tool calls recorded yet.</p>`:o`
    <div class="tool-bar-chart">
      ${e.map(n=>{const s=t>0?n.call_count/t*100:0;return o`
          <div class="tool-bar-row" key=${n.name}>
            <span class="tool-bar-name">${n.name}</span>
            <span class="tool-bar-tier ${R$(n.tier)}">${n.tier}</span>
            <div class="tool-bar-track">
              <div class="tool-bar-fill" style=${{width:`${s}%`}} />
            </div>
            <span class="tool-bar-count">${n.call_count}</span>
          </div>
        `})}
    </div>
  `}function z$({dist:e}){const t=e.full,n=t>0?(e.essential/t*100).toFixed(1):"0",s=t>0?(e.standard/t*100).toFixed(1):"0",a=t-e.standard,i=t>0?(a/t*100).toFixed(1):"0";return o`
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
        <span class="tier-dist-pct">${i}%</span>
      </div>
    </div>
  `}function P$(){const e=ei.value,t=jn.value,n=ti.value;return se(()=>{!ei.value&&!jn.value&&Or()},[]),o`
    <div class="tool-metrics">
      <div class="tool-metrics-header">
        <h3 class="tool-metrics-title">Tool Usage</h3>
        <button
          class="control-btn ghost"
          onClick=${()=>void Or()}
          disabled=${t}
        >
          ${t?"Loading...":e?"Refresh":"Load"}
        </button>
      </div>

      ${n?o`<div class="tool-metrics-error">${n}</div>`:null}

      ${e?o`
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
            <${z$} dist=${e.tier_distribution} />
          </div>
          <div class="tool-metrics-section">
            <h4>Top 20 Tools</h4>
            <${L$}
              items=${e.top_20}
              maxCount=${e.top_20.length>0?e.top_20[0].call_count:0}
            />
          </div>
        </div>
      `:t?null:o`
        <p class="muted">Click Load to fetch tool usage statistics.</p>
      `}
    </div>
  `}const ni=g(null),si=g(null),En=g(!1),kn=g(""),Rs=g("all"),ro=g(!1),lo=g(!1),co=g(!0),uo=g(!0);async function qr(){if(!En.value){En.value=!0,si.value=null;try{ni.value=await nu()}catch(e){si.value=e instanceof Error?e.message:String(e)}finally{En.value=!1}}}function M$(e,t){const n=t.trim().toLowerCase();return n?[e.name,e.description,e.category,e.required_permission??"",e.visibility,e.lifecycle,e.implementationStatus,e.tier,e.canonicalName??"",e.replacement??"",e.reason??"",...e.doc_refs,...e.prompt_hints].join(" ").toLowerCase().includes(n):!0}function Ls(e,t="default"){return o`
    <span
      style=${{fontSize:"11px",color:t==="ok"?"#7dd3fc":t==="warn"?"#fbbf24":"#cbd5e1",background:t==="ok"?"rgba(14, 165, 233, 0.18)":t==="warn"?"rgba(245, 158, 11, 0.18)":"rgba(148, 163, 184, 0.16)",borderRadius:"999px",padding:"2px 8px"}}
    >
      ${e}
    </span>
  `}function j$({item:e}){return o`
    <article class="tool-inventory-row">
      <div class="tool-inventory-head">
        <div>
          <div class="tool-inventory-name">${e.name}</div>
          <div class="tool-inventory-desc">${e.description}</div>
        </div>
        <div class="tool-inventory-badges">
          ${Ls(e.tier,e.tier==="essential"?"ok":e.tier==="standard"?"warn":"default")}
          ${Ls(e.visibility)}
          ${Ls(e.lifecycle,e.lifecycle==="deprecated"?"warn":"default")}
          ${Ls(e.implementationStatus)}
        </div>
      </div>
      <div class="tool-inventory-meta">
        <span>Category: <strong>${e.category}</strong></span>
        <span>Mode: <strong>${e.enabled_in_current_mode?"enabled":"disabled"}</strong></span>
        <span>Direct call: <strong>${e.direct_call_allowed?"allowed":"blocked"}</strong></span>
        <span>Permission: <strong>${e.required_permission??"none"}</strong></span>
      </div>
      ${e.reason?o`<div class="tool-inventory-reason">${e.reason}</div>`:null}
      <div class="tool-inventory-links">
        ${e.canonicalName?o`<span>Canonical: <strong>${e.canonicalName}</strong></span>`:null}
        ${e.replacement?o`<span>Replacement: <strong>${e.replacement}</strong></span>`:null}
        ${e.doc_refs.length>0?o`<span>Docs: <strong>${e.doc_refs.join(", ")}</strong></span>`:null}
      </div>
    </article>
  `}function E$(){const e=ni.value,t=En.value,n=si.value,s=(e==null?void 0:e.tool_inventory.tools)??[],a=(e==null?void 0:e.tool_usage)??null;se(()=>{!ni.value&&!En.value&&qr()},[]),se(()=>{var h;if(D.value.tab!=="tools")return;const _=(h=D.value.params.q)==null?void 0:h.trim();_&&_!==kn.value&&(kn.value=_)},[D.value.tab,D.value.params.q]);const i=Array.from(new Set(s.map(_=>_.category))).sort((_,h)=>_.localeCompare(h)),l=s.filter(_=>!(!M$(_,kn.value)||Rs.value!=="all"&&_.category!==Rs.value||ro.value&&!_.enabled_in_current_mode||lo.value&&!_.direct_call_allowed||!co.value&&_.visibility==="hidden"||!uo.value&&_.lifecycle==="deprecated")),c=s.length,p=s.filter(_=>_.enabled_in_current_mode).length,m=s.filter(_=>_.visibility==="hidden").length,u=s.filter(_=>_.lifecycle==="deprecated").length,f=s.filter(_=>_.direct_call_allowed).length;return o`
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
            <span class="stat-value">${m}</span>
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
            value=${kn.value}
            onInput=${_=>{kn.value=_.target.value}}
          />
          <select
            class="control-select"
            value=${Rs.value}
            onChange=${_=>{Rs.value=_.target.value}}
          >
            <option value="all">All categories</option>
            ${i.map(_=>o`<option value=${_}>${_}</option>`)}
          </select>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${ro.value}
              onChange=${_=>{ro.value=_.target.checked}}
            />
            <span>Enabled only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${lo.value}
              onChange=${_=>{lo.value=_.target.checked}}
            />
            <span>Direct-call only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${co.value}
              onChange=${_=>{co.value=_.target.checked}}
            />
            <span>Show hidden</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${uo.value}
              onChange=${_=>{uo.value=_.target.checked}}
            />
            <span>Show deprecated</span>
          </label>
          <button class="control-btn ghost" onClick=${()=>{qr()}} disabled=${t}>
            ${t?"Refreshing…":"Refresh inventory"}
          </button>
        </div>

        ${n?o`<div class="tool-metrics-error">${n}</div>`:null}

        <div class="tool-inventory-list">
          ${l.length>0?l.map(_=>o`<${j$} key=${_.name} item=${_} />`):o`<div class="empty-state">No tools matched the current filters.</div>`}
        </div>
      <//>

      <${I} title="Tool Usage" class="section">
        ${a?o`
              <div class="tool-inventory-usage-hint">
                Registered ${a.registered_count} · Distinct called ${a.distinct_tools_called} · Never called ${a.never_called_count}
              </div>
            `:null}
        <${P$} />
      <//>
    </div>
  `}const za=g("all"),Pa=g("all"),ai=g(new Set);function N$(e){const t=new Set(ai.value);t.has(e)?t.delete(e):t.add(e),ai.value=t}const td=ze(()=>{let e=Vt.value;return za.value!=="all"&&(e=e.filter(t=>t.horizon===za.value)),Pa.value!=="all"&&(e=e.filter(t=>t.status===Pa.value)),e}),D$=ze(()=>{const e={short:[],mid:[],long:[]};for(const t of td.value){const n=e[t.horizon];n&&n.push(t)}return e}),w$=ze(()=>{const e=Array.from(Tl.value.values());return e.sort((t,n)=>t.status==="running"&&n.status!=="running"?-1:n.status==="running"&&t.status!=="running"?1:t.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&t.status!=="interrupted"?1:n.elapsed_seconds-t.elapsed_seconds),e});function O$(e){return"★".repeat(Math.min(e,5))+"☆".repeat(Math.max(0,5-e))}function Wi(e){switch(e){case"short":return"단기";case"mid":return"중기";case"long":return"장기";default:return e}}function Vs(e){switch(e){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function q$(e){return e<60?`${Math.round(e)}s`:e<3600?`${Math.floor(e/60)}m ${Math.round(e%60)}s`:`${Math.floor(e/3600)}h ${Math.floor(e%3600/60)}m`}function Fr(e){return e.toFixed(4)}function Kr(e){const t=e.current_metric-e.baseline_metric;return`${t>=0?"+":""}${t.toFixed(4)}`}function F$(e){switch(e){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function K$(e){switch(e){case"active":return"진행 중";case"completed":return"완료";case"paused":return"일시정지";default:return"전체"}}function Ur(e,t){return(e.priority??4)-(t.priority??4)}function U$(e,t){const n=e.updated_at??e.created_at??"";return(t.updated_at??t.created_at??"").localeCompare(n)}function H$(e,t){return e.length<=t?e:e.slice(0,t)+"..."}function B$({goal:e}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Vs(e.horizon)}">
            ${Wi(e.horizon)}
          </span>
          <span class="goal-title">${e.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${e.priority}">${O$(e.priority)}</span>
          ${e.metric?o`<span class="goal-metric">${e.metric}${e.target_value?` → ${e.target_value}`:""}</span>`:null}
          ${e.due_date?o`<span class="goal-due">Due: <${G} timestamp=${e.due_date} /></span>`:null}
        </div>
        ${e.last_review_note?o`
          <div class="goal-review-note">${e.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${gt} status=${e.status} />
        <div class="goal-updated">
          <${G} timestamp=${e.updated_at} />
        </div>
      </div>
    </div>
  `}function po({horizon:e,items:t}){if(t.length===0)return null;const n=[...t].sort((s,a)=>a.priority-s.priority);return o`
    <${I} title="${Wi(e)} 목표 (${t.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>o`<${B$} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function W$(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">범위</label>
        ${["all","short","mid","long"].map(e=>o`
          <button
            class="goal-filter-btn ${za.value===e?"active":""}"
            onClick=${()=>{za.value=e}}
          >
            ${e==="all"?"전체":Wi(e)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">상태</label>
        ${["all","active","completed","paused"].map(e=>o`
          <button
            class="goal-filter-btn ${Pa.value===e?"active":""}"
            onClick=${()=>{Pa.value=e}}
          >
            ${K$(e)}
          </button>
        `)}
      </div>
    </div>
  `}function G$(){const e=Vt.value,t=e.filter(a=>a.status==="active").length,n=e.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of e)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${Vs("short")}">${s.short}</div>
        <div class="goal-summary-label">단기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Vs("mid")}">${s.mid}</div>
        <div class="goal-summary-label">중기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Vs("long")}">${s.long}</div>
        <div class="goal-summary-label">장기</div>
      </div>
    </div>
  `}function J$({loop:e}){const t=e.history[0],n=e.latest_tool_names&&e.latest_tool_names.length>0?`${e.latest_tool_call_count??e.latest_tool_names.length}개 도구: ${e.latest_tool_names.join(", ")}`:"아직 근거 없음";return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${e.profile}</div>
            <div class="planning-loop-sub">${e.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${gt} status=${e.status} />
            <span class="pill">${e.current_iteration}${e.max_iterations>0?`/${e.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Fr(e.baseline_metric)}</span>
          <span>현재 ${Fr(e.current_metric)}</span>
          <span class=${Kr(e).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Kr(e)}
          </span>
          <span>Elapsed ${q$(e.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${e.target||"명시된 목표가 없습니다"}</div>
        ${e.stop_reason||e.error_message?o`
              <div class="planning-loop-footnote">
                ${e.error_message??e.stop_reason}
              </div>
            `:null}
        <div class="planning-loop-footnote">
          ${e.strict_mode?"엄격 근거 모드":"레거시"} · ${e.worker_engine??"엔진 정보 없음"} · ${n}
        </div>
        ${t?o`
              <div class="planning-loop-footnote">
                최근 반복 #${t.iteration}: ${t.changes||t.next_suggestion||"서술 정보 없음"}
              </div>
            `:o`<div class="planning-loop-footnote">반복 이력이 아직 없습니다</div>`}
      </div>
    </div>
  `}function mo({task:e}){const t=e.priority??4,n=t<=1?"p1":t===2?"p2":t===3?"p3":"p4",s=ai.value.has(e.id),a=!!e.description;return o`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${F$(t)}</span>
        <div class="kanban-card-title">${e.title}</div>
      </div>
      ${a?o`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>N$(e.id)}
        >
          ${s?e.description:H$(e.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${e.created_at?o`<${G} timestamp=${e.created_at} />`:o`<span>-</span>`}
        ${e.assignee?o`<span class="kanban-assignee">${e.assignee}</span>`:null}
      </div>
    </div>
  `}function V$(){const{todo:e,inProgress:t,done:n}=Rl.value,s=[...e].sort(Ur),a=[...t].sort(Ur),i=[...n].sort(U$);return o`
    <${I} title="태스크 백로그" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>할 일</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${s.length===0?o`<div class="empty-state" style="opacity: 0.5;">대기 중인 태스크가 없습니다</div>`:s.map(l=>o`<${mo} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>진행 중</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${a.length===0?o`<div class="empty-state" style="opacity: 0.5;">진행 중인 태스크가 없습니다</div>`:a.map(l=>o`<${mo} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>완료</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${i.length===0?o`<div class="empty-state" style="opacity: 0.5;">완료된 태스크가 없습니다</div>`:i.slice(0,20).map(l=>o`<${mo} key=${l.id} task=${l} />`)}
          ${i.length>20?o`<div class="empty-state" style="opacity: 0.5;">...외 ${i.length-20}개 더 있음</div>`:null}
        </div>
      </div>
    <//>
  `}function Q$(){const{todo:e,inProgress:t,done:n}=Rl.value,s=e.length+t.length+n.length,a=[...e,...t].filter(u=>(u.priority??4)<=2).length,i=D$.value,l=w$.value,c=Vt.value.length>0,p=l.length>0,m=gi.value;return o`
    <div>
      <${xe} surfaceId="planning" />

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
          onClick=${()=>{yi(),Nl()}}
          disabled=${An.value||Tn.value}
        >
          ${An.value||Tn.value?"새로고침 중...":"계획 데이터 새로고침"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${V$} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          목표 파이프라인
          <span class="monitor-pill">${Vt.value.length}</span>
        </summary>
        <div>
          ${c?o`
            <${G$} />
            <${W$} />
            ${An.value&&Vt.value.length===0?o`<div class="loading-indicator">목표 불러오는 중...</div>`:td.value.length===0?o`<div class="empty-state">현재 필터에 맞는 목표가 없습니다</div>`:o`
                    <${po} horizon="short" items=${i.short??[]} />
                    <${po} horizon="mid" items=${i.mid??[]} />
                    <${po} horizon="long" items=${i.long??[]} />
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
          ${Tn.value&&l.length===0?o`<div class="loading-indicator">MDAL 루프 불러오는 중...</div>`:l.length===0&&(m==="error"||Qt.value)?o`<div class="empty-state">MDAL 스냅샷을 불러오지 못했습니다${Qt.value?`: ${Qt.value}`:""}. 백엔드 상태를 확인하세요.</div>`:l.length===0?o`<div class="empty-state">가동 중인 루프가 없습니다. <code>masc_mdal_start</code>로 시작할 수 있습니다.</div>`:o`
                  <div class="planning-loop-list">
                    ${l.map(u=>o`<${J$} key=${u.loop_id} loop=${u} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const Ma=g(!1),Nn=g(!1),Gt=g(!1),mt=g(""),Dn=g(""),oi=g("open"),we=g(null),ts=g(null),ja=g(null),Ea=g(null),ii=g(!1);function ns(e){return`${e.kind}:${e.id}`}function Gi(){var n;const e=ts.value,t=((n=we.value)==null?void 0:n.items)??[];return e?t.find(s=>ns(s)===e)??null:null}function Y$(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");return(t==null?void 0:t.trim())||"dashboard"}function X$(e){const t=e.trim().toLowerCase();return t==="open"||t==="pending"}function nd(e){return!!(e.judgment_summary&&e.judgment_summary.trim())}function sd(e){switch(oi.value){case"needs_quorum":return e.filter(t=>t.kind==="consensus"&&(t.votes??0)<(t.quorum??0));case"ready":return e.filter(t=>{var n;return(n=t.guardrail_state)==null?void 0:n.ready_to_execute});case"needs_approval":return e.filter(t=>{var n,s;return((n=t.guardrail_state)==null?void 0:n.requires_human_gate)||!!((s=t.guardrail_state)!=null&&s.pending_confirm)});case"judge_offline":return e.filter(t=>!nd(t));case"open":default:return e.filter(t=>X$(t.status))}}function Z$(e){if(e==null)return"없음";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Ga(e){const t=(e||"").toLowerCase();return t.includes("reject")||t.includes("deny")||t.includes("closed")||t.includes("cancel")?"negative":t.includes("approve")||t.includes("support")||t.includes("open")||t.includes("ready")?"positive":"neutral"}function eh(e){return typeof e!="number"||Number.isNaN(e)?"확인 필요":`${Math.round(e*100)}%`}function xn(e){return"resolved_tool"in e||"payload_preview"in e||"reason"in e}async function ad(e){if(ja.value=null,Ea.value=null,!!e){ii.value=!0,mt.value="";try{e.kind==="debate"?ja.value=await Ju(e.id):Ea.value=await Vu(e.id)}catch(t){mt.value=t instanceof Error?t.message:"거버넌스 상세를 불러오지 못했습니다"}finally{ii.value=!1}}}async function th(e){ts.value=ns(e),await ad(e)}async function mn(){var e;Ma.value=!0,mt.value="";try{const t=await Jd();we.value=t;const n=sd(t.items??[]),s=ts.value,a=n.find(i=>ns(i)===s)??n[0]??((e=t.items)==null?void 0:e[0])??null;ts.value=a?ns(a):null,await ad(a)}catch(t){mt.value=t instanceof Error?t.message:"거버넌스 상태를 불러오지 못했습니다"}finally{Ma.value=!1}}Qp(mn);async function Hr(){const e=Dn.value.trim();if(e){Nn.value=!0;try{const t=await Gu(e);Dn.value="",M(t!=null&&t.id?`토론을 시작했습니다: ${t.id}`:"토론을 시작했습니다","success"),await mn()}catch(t){const n=t instanceof Error?t.message:"토론 시작에 실패했습니다";mt.value=n,M(n,"error")}finally{Nn.value=!1}}}async function Br(e){var i,l;const t=Gi(),n=(i=t==null?void 0:t.guardrail_state)==null?void 0:i.pending_confirm,s=n==null?void 0:n.confirm_token;if(!s)return;const a=((l=n==null?void 0:n.actor)==null?void 0:l.trim())||Y$();Gt.value=!0;try{await ll(a,s,e),M(e==="confirm"?"액션을 승인했습니다":"액션을 거부했습니다","success"),await mn()}catch(c){const p=c instanceof Error?c.message:"대기 중인 액션 처리에 실패했습니다";mt.value=p,M(p,"error")}finally{Gt.value=!1}}function nh(){var n,s,a,i,l,c;const e=(n=we.value)==null?void 0:n.summary,t=(s=we.value)==null?void 0:s.judge;return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">열린 토론</span>
        <strong>${(e==null?void 0:e.debates_open)??((i=(a=we.value)==null?void 0:a.debates)==null?void 0:i.length)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">합의 세션</span>
        <strong>${(e==null?void 0:e.sessions_active)??((c=(l=we.value)==null?void 0:l.sessions)==null?void 0:c.length)??0}</strong>
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
  `}function sh(){return o`
    <${I} title="거버넌스 콘솔" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="토론 주제를 입력하세요..."
            value=${Dn.value}
            onInput=${e=>{Dn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&Hr()}}
            disabled=${Nn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Hr}
            disabled=${Nn.value||Dn.value.trim()===""}
          >
            ${Nn.value?"시작 중...":"토론 시작"}
          </button>
          <button class="control-btn ghost" onClick=${mn} disabled=${Ma.value}>
            ${Ma.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
        <div class="governance-filter-row">
          ${[["open","열림"],["needs_quorum","정족수 부족"],["ready","준비됨"],["needs_approval","승인 필요"],["judge_offline","판정기 오프라인"]].map(([e,t])=>o`
            <button
              class="control-btn ${oi.value===e?"is-active":"ghost"}"
              onClick=${async()=>{oi.value=e,await mn()}}
            >
              ${t}
            </button>
          `)}
        </div>
        ${mt.value?o`<div class="council-error">${mt.value}</div>`:null}
      </div>
    <//>
  `}function ah(){var t;const e=sd(((t=we.value)==null?void 0:t.items)??[]);return o`
    <${I} title="의사결정 수신함" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${e.length===0?o`
              <div class="empty-state">
                지금 필터에 맞는 토론이나 합의 세션이 없습니다.
              </div>
            `:e.map(n=>{var a,i;const s=ts.value===ns(n);return o`
                <button
                  class="council-row governance-decision-row ${s?"selected":""}"
                  onClick=${()=>th(n)}
                >
                  <div class="council-row-main">
                    <div class="governance-row-head">
                      <span class="governance-kind">${n.kind}</span>
                      <span class="council-topic">${n.topic}</span>
                    </div>
                    <div class="council-sub">
                      <span>${n.truth_summary||"사실 요약이 아직 없습니다"}</span>
                      ${n.last_activity_at?o`<span><${G} timestamp=${n.last_activity_at} /></span>`:null}
                    </div>
                    <div class="governance-chip-row">
                      ${(a=n.guardrail_state)!=null&&a.requires_human_gate?o`<span class="governance-chip warn">승인 필요</span>`:null}
                      ${(i=n.guardrail_state)!=null&&i.ready_to_execute?o`<span class="governance-chip ok">준비됨</span>`:null}
                      ${n.kind==="consensus"&&(n.votes??0)<(n.quorum??0)?o`<span class="governance-chip warn">정족수 부족</span>`:null}
                      ${nd(n)?null:o`<span class="governance-chip dim">판정기 오프라인</span>`}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${Ga(n.status)}">${n.status}</span>
                    ${n.kind==="consensus"?o`<span class="governance-vote-meter">${n.votes??0}/${n.quorum??0}</span>`:o`<span class="governance-vote-meter">${n.evidence_refs.length} refs</span>`}
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function oh({argument:e}){return o`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${Ga(e.position)}">${e.position}</span>
        <strong>${e.agent}</strong>
        ${e.created_at?o`<span><${G} timestamp=${e.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.content}</div>
      <div class="governance-chip-row">
        ${e.evidence.map(t=>o`<span class="governance-chip">${t}</span>`)}
        ${e.reply_to!=null?o`<span class="governance-chip">답글 #${e.reply_to}</span>`:null}
        ${e.mentions.map(t=>o`<span class="governance-chip">@${t}</span>`)}
        ${e.archetype?o`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function ih({vote:e}){return o`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${Ga(e.decision)}">${e.decision}</span>
        <strong>${e.agent}</strong>
        ${e.timestamp?o`<span><${G} timestamp=${e.timestamp} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.reason||"기록된 이유가 없습니다."}</div>
      <div class="governance-chip-row">
        ${e.weight!=null?o`<span class="governance-chip">가중치 ${e.weight}</span>`:null}
        ${e.archetype?o`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function rh(){const e=Gi(),t=ja.value,n=Ea.value;return o`
    <${I}
      title=${e?`${e.kind==="debate"?"토론":"합의"} 상세`:"의사결정 상세"}
      class="section"
      semanticId="governance.detail"
    >
      ${ii.value?o`<div class="loading-indicator">거버넌스 상세 불러오는 중...</div>`:e?e.kind==="debate"&&t?o`
                <div class="governance-detail-head">
                  <div>
                    <h3>${t.debate.topic}</h3>
                    <div class="council-sub">
                      <span>${t.debate.id}</span>
                      <span>${t.debate.status}</span>
                      ${t.debate.created_at?o`<span><${G} timestamp=${t.debate.created_at} /></span>`:null}
                    </div>
                  </div>
                  <div class="governance-balance-grid">
                    <span class="governance-balance"><strong>${t.summary.support_count}</strong> support</span>
                    <span class="governance-balance"><strong>${t.summary.oppose_count}</strong> oppose</span>
                    <span class="governance-balance"><strong>${t.summary.neutral_count}</strong> neutral</span>
                    <span class="governance-balance"><strong>${t.summary.total_arguments}</strong> total</span>
                  </div>
                </div>
                ${t.summary.summary_text?o`<div class="governance-summary-callout">${t.summary.summary_text}</div>`:null}
                <div class="governance-ledger">
                  ${t.arguments.length===0?o`<div class="empty-state">기록된 토론이 아직 없습니다.</div>`:t.arguments.map(s=>o`<${oh} key=${s.index} argument=${s} />`)}
                </div>
              `:e.kind==="consensus"&&n?o`
                  <div class="governance-detail-head">
                    <div>
                      <h3>${n.session.topic}</h3>
                      <div class="council-sub">
                        <span>${n.session.id}</span>
                        <span>${n.session.state}</span>
                      <span>시작자 ${n.session.initiator}</span>
                        ${n.session.created_at?o`<span><${G} timestamp=${n.session.created_at} /></span>`:null}
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
                    ${n.votes.length===0?o`<div class="empty-state">기록된 표결이 아직 없습니다.</div>`:n.votes.map(s=>o`<${ih} key=${s.agent+s.timestamp} vote=${s} />`)}
                  </div>
                `:o`<div class="empty-state">이 의사결정의 상세를 아직 읽을 수 없습니다.</div>`:o`<div class="empty-state">사실 계층과 판단을 보려면 의사결정 항목을 고르세요.</div>`}
    <//>
  `}function Wr({title:e,route:t}){if(!t)return null;const n=xn(t)?t.resolved_tool:t.delegated_tool,s=xn(t)?t.target_type:null,a=xn(t)?t.target_id:null,i=xn(t)?t.reason:null,l=xn(t)?t.payload_preview:null;return o`
    <div class="governance-side-block">
      <h4>${e}</h4>
      <div class="council-sub">
        ${n?o`<span>도구 ${n}</span>`:null}
        ${"action_type"in t&&t.action_type?o`<span>액션 ${t.action_type}</span>`:null}
        ${"confirmation_state"in t&&t.confirmation_state?o`<span>${t.confirmation_state}</span>`:null}
        ${"created_at"in t&&t.created_at?o`<span><${G} timestamp=${t.created_at} /></span>`:null}
      </div>
      ${s?o`<div class="governance-side-line">대상 ${s}${a?`:${a}`:""}</div>`:null}
      ${i?o`<div class="governance-side-line">${i}</div>`:null}
      ${l?o`<pre class="council-detail governance-preview">${Z$(l)}</pre>`:null}
    </div>
  `}function lh(){var c,p,m;const e=Gi(),t=ja.value,n=Ea.value,s=(t==null?void 0:t.context)??(n==null?void 0:n.context)??(e==null?void 0:e.context),a=(t==null?void 0:t.judgment)??(n==null?void 0:n.judgment),i=e==null?void 0:e.guardrail_state,l=(c=we.value)==null?void 0:c.judge;return o`
    <div class="governance-side-column">
      <${I} title="이유 / 가드레일" class="section" semanticId="governance.guardrail">
        ${e?o`
              <div class="governance-side-block">
                <h4>판정기</h4>
                <div class="council-sub">
                  <span>${l!=null&&l.judge_online?"온라인":"오프라인"}</span>
                  ${l!=null&&l.model_used?o`<span>${l.model_used}</span>`:null}
                  ${l!=null&&l.generated_at?o`<span><${G} timestamp=${l.generated_at} /></span>`:null}
                </div>
                ${e.judgment_summary?o`<div class="governance-summary-callout">${e.judgment_summary}</div>`:o`<div class="governance-side-line">현재 LLM 판단이 없어 사실 계층만 보여줍니다.</div>`}
                <div class="council-sub">
                  <span>신뢰도 ${eh(e.confidence)}</span>
                  ${a!=null&&a.keeper_name?o`<span>${a.keeper_name}</span>`:null}
                </div>
              </div>

              <${Wr} title="추천 경로" route=${e.recommended_action} />
              <${Wr} title="실행된 경로" route=${e.executed_route} />

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
                          onClick=${()=>Br("confirm")}
                          disabled=${Gt.value}
                        >
                          ${Gt.value?"처리 중...":"승인"}
                        </button>
                        <button
                          class="control-btn ghost"
                          onClick=${()=>Br("deny")}
                          disabled=${Gt.value}
                        >
                          ${Gt.value?"처리 중...":"거부"}
                        </button>
                      </div>
                    `:o`<div class="governance-side-line">이 의사결정에 대기 중인 사람 승인은 없습니다.</div>`}
              </div>
            `:o`<div class="empty-state">판단과 경로를 보려면 의사결정을 고르세요.</div>`}
      <//>

      <${I} title="맥락" class="section" semanticId="governance.context">
        ${e?o`
              <div class="governance-side-block">
                <div class="governance-chip-row">
                  ${s!=null&&s.board_post_id?o`<span class="governance-chip">board ${s.board_post_id}</span>`:null}
                  ${s!=null&&s.task_id?o`<span class="governance-chip">task ${s.task_id}</span>`:null}
                  ${s!=null&&s.operation_id?o`<span class="governance-chip">작전 ${s.operation_id}</span>`:null}
                  ${s!=null&&s.team_session_id?o`<span class="governance-chip">session ${s.team_session_id}</span>`:null}
                </div>
                ${e.related_agents.length>0?o`
                      <div class="governance-side-line">관련 에이전트</div>
                      <div class="governance-chip-row">
                        ${e.related_agents.map(u=>o`<span class="governance-chip dim">${u}</span>`)}
                      </div>
                    `:o`<div class="governance-side-line">명시적으로 연결된 맥락 기록이 없습니다.</div>`}
                ${e.evidence_refs.length>0?o`
                      <div class="governance-side-line">근거 참조</div>
                      <div class="governance-chip-row">
                        ${e.evidence_refs.map(u=>o`<span class="governance-chip">${u}</span>`)}
                      </div>
                    `:null}
              </div>
          `:o`<div class="empty-state">선택된 맥락이 없습니다.</div>`}
      <//>

      <${I} title="최근 활동" class="section" semanticId="governance.activity">
        <div class="governance-activity-list">
          ${(((p=we.value)==null?void 0:p.activity)??[]).slice(0,8).map(u=>o`
            <div class="governance-activity-row">
              <div class="governance-ledger-head">
                <span class="governance-badge ${Ga(u.kind)}">${u.kind}</span>
                ${u.actor?o`<strong>${u.actor}</strong>`:null}
                ${u.created_at?o`<span><${G} timestamp=${u.created_at} /></span>`:null}
              </div>
              <div class="governance-ledger-body">${u.summary||u.topic||"활동이 기록되었습니다."}</div>
            </div>
          `)}
          ${(((m=we.value)==null?void 0:m.activity)??[]).length===0?o`<div class="empty-state">기록된 거버넌스 활동이 없습니다.</div>`:null}
        </div>
      <//>
    </div>
  `}function ch(){return se(()=>{mn()},[]),o`
    <div>
      <${xe} surfaceId="governance" />
      <${nh} />
      <${sh} />
      <div class="governance-layout">
        <${ah} />
        <${rh} />
        <${lh} />
      </div>
    </div>
  `}const qt=g(""),vo=g("ability_check"),_o=g("10"),fo=g("12"),zs=g(""),Ps=g("idle"),et=g(""),Ms=g("keeper-late"),go=g("player"),$o=g(""),Ce=g("idle"),ho=g(null),js=g(""),yo=g(""),bo=g("player"),ko=g(""),xo=g(""),So=g(""),wn=g("20"),Co=g("20"),Ao=g(""),Es=g("idle"),ri=g(null),od=g("overview"),To=g("all"),Io=g("all"),Ro=g("all"),dh=12e4,Ja=g(null),Gr=g(Date.now());function uh(e,t){const n=t>0?e/t*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function ph(e,t){return t>0?Math.round(e/t*100):0}const mh={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},vh={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Ns(e){const t=e.trim();return t?t.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):e}function _h(e){const t=e.trim().toLowerCase();return mh[t]??"행동 선택 가중치에 영향을 주는 성향입니다."}function fh(e){const t=e.trim().toLowerCase();return vh[t]??"상황에 따라 선택되는 전술 액션입니다."}function ye(e,t,n=""){const s=e[t];return typeof s=="string"?s:n}function Ee(e,t,n=0){const s=e[t];return typeof s=="number"&&Number.isFinite(s)?s:n}function ss(e,t,n=!1){const s=e[t];return typeof s=="boolean"?s:n}const gh=new Set(["str","dex","con","int","wis","cha"]);function $h(e){const t=e.trim();if(!t)return{};let n;try{n=JSON.parse(t)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!v(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const l=a.trim();if(l){if(typeof i=="number"&&Number.isFinite(i)){s[l]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const c=Number.parseFloat(i.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function hh(e){const t=Number.parseInt(e.trim(),10);if(!Number.isFinite(t))return;const n=Math.max(1,t),s=Number.parseInt(wn.value.trim(),10);Number.isFinite(s)&&s>n&&(wn.value=String(n))}function li(e){const n=(e.actor_name??e.actor??e.actor_id??"system").trim();return n===""?"system":n}function yh(e){var n;return(((n=e.timestamp)==null?void 0:n.trim())??"")||"-"}function bh(e){od.value=e}function id(e){const t=Ja.value;return t==null||t<=e}function kh(e){const t=Ja.value;return t==null||t<=e?0:Math.max(0,Math.ceil((t-e)/1e3))}function Na(){Ja.value=null}function rd(e){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(e)}function xh(e,t){rd(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${e||"-"}`,`PHASE: ${t||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Ja.value=Date.now()+dh,M("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Qs(e){return id(e)?(M("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function ci(e,t,n){return rd([`[위험 액션 확인] ${e}`,`ROOM: ${t||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Sh({hp:e,max:t}){const n=ph(e,t),s=uh(e,t);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Ch({stats:e}){const t=[{label:"STR",value:e.strength},{label:"DEX",value:e.dexterity},{label:"CON",value:e.constitution},{label:"INT",value:e.intelligence},{label:"WIS",value:e.wisdom},{label:"CHA",value:e.charisma}];return o`
    <div class="trpg-actor-stats">
      ${t.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Ah({keeper:e,role:t}){if(!e)return null;const n=t==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${e}
    </span>
  `}function ld({actor:e}){var p,m,u,f;const t=(p=e.archetype)==null?void 0:p.trim(),n=(m=e.persona)==null?void 0:m.trim(),s=(u=e.portrait)==null?void 0:u.trim(),a=(f=e.background)==null?void 0:f.trim(),i=e.traits??[],l=e.skills??[],c=Object.entries(e.stats_raw??{}).filter(([_,h])=>Number.isFinite(h)).filter(([_])=>!gh.has(_.toLowerCase()));return o`
    <div class="trpg-actor">
      ${s?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${e.name} portrait`}
              loading="lazy"
              onError=${_=>{const h=_.target;h&&(h.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${e.name}</span>
        <${gt} status=${e.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${e.role}">${e.role}</span>
        <${Ah} keeper=${e.keeper} role=${e.role} />
      </div>
      ${e.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${e.stats.hp}/${e.stats.max_hp}
              ${e.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${e.stats.mp}/${e.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${e.stats.level}</span>
            </div>
            <${Sh} hp=${e.stats.hp} max=${e.stats.max_hp} />
            <${Ch} stats=${e.stats} />
          </div>
        `:null}
      ${t?o`<div class="trpg-actor-meta">Archetype: ${Ns(t)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([_,h])=>o`
                <span class="trpg-custom-stat-chip">${Ns(_)} ${h}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(_=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${Ns(_)}</span>
                  <span class="trpg-annot-desc">${_h(_)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${l.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${l.map(_=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${Ns(_)}</span>
                  <span class="trpg-annot-desc">${fh(_)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Th({mapStr:e}){return o`<pre class="trpg-map">${e}</pre>`}function cd({events:e,emptyLabel:t="아직 이벤트가 없습니다."}){return e.length===0?o`<div class="empty-state" style="font-size:13px">${t}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${e.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${yh(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${li(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${G} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Ih({events:e}){const t="__none__",n=To.value,s=Io.value,a=Ro.value,i=Array.from(new Set(e.map(li).map(f=>f.trim()).filter(f=>f!==""))).sort((f,_)=>f.localeCompare(_)),l=Array.from(new Set(e.map(f=>(f.type??"").trim()).filter(f=>f!==""))).sort((f,_)=>f.localeCompare(_)),c=e.some(f=>(f.type??"").trim()===""),p=Array.from(new Set(e.map(f=>(f.phase??"").trim()).filter(f=>f!==""))).sort((f,_)=>f.localeCompare(_)),m=e.some(f=>(f.phase??"").trim()===""),u=e.filter(f=>{if(n!=="all"&&li(f)!==n)return!1;const _=(f.type??"").trim(),h=(f.phase??"").trim();if(s===t){if(_!=="")return!1}else if(s!=="all"&&_!==s)return!1;if(a===t){if(h!=="")return!1}else if(a!=="all"&&h!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${f=>{To.value=f.target.value}}>
          <option value="all">all</option>
          ${i.map(f=>o`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${f=>{Io.value=f.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${t}>(none)</option>`:null}
          ${l.map(f=>o`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${f=>{Ro.value=f.target.value}}>
          <option value="all">all</option>
          ${m?o`<option value=${t}>(none)</option>`:null}
          ${p.map(f=>o`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{To.value="all",Io.value="all",Ro.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${u.length} / 전체 ${e.length}
      </span>
    </div>
    <${cd} events=${u.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Rh({outcome:e}){if(!e)return null;const t=i=>{const l=i.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=e.result==="victory"?"승리":e.result==="defeat"?"패배":e.result==="draw"?"무승부":"종료",s=e.result==="victory"?"#34d399":e.result==="defeat"?"#f87171":"#9ca3af",a=[e.reason?`원인: ${t(e.reason)}`:null,e.phase?`페이즈: ${t(e.phase)}`:null,typeof e.turn=="number"?`턴: ${e.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${e.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${t(e.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function dd({state:e}){const t=e.history??[];return t.length===0?null:o`
    <div class="trpg-round-list">
      ${t.slice(-10).map(n=>o`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
  `}function Lh({state:e,nowMs:t}){var m;const n=Je.value||((m=e.session)==null?void 0:m.room)||"",s=Ps.value,a=e.party??[];if(!a.find(u=>u.id===qt.value)&&a.length>0){const u=a[0];u&&(qt.value=u.id)}const l=async()=>{var f,_;if(!n){M("Room ID가 비어 있습니다.","error");return}if(!Qs(t))return;const u=((f=e.current_round)==null?void 0:f.phase)??((_=e.session)==null?void 0:_.status)??"unknown";if(ci("라운드 실행",n,u)){Ps.value="running";try{const h=await Nu(n);ri.value=h,Ps.value="ok";const b=v(h.summary)?h.summary:null,C=b?ss(b,"advanced",!1):!1,S=b?ye(b,"progress_reason",""):"";M(C?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${S?`: ${S}`:""}`,C?"success":"warning"),it()}catch(h){ri.value=null,Ps.value="error";const b=h instanceof Error?h.message:"라운드 실행에 실패했습니다.";M(b,"error")}finally{Na()}}},c=async()=>{var f,_;if(!n||!Qs(t))return;const u=((f=e.current_round)==null?void 0:f.phase)??((_=e.session)==null?void 0:_.status)??"unknown";if(ci("턴 강제 진행",n,u))try{await Ou(n),M("턴을 다음 단계로 이동했습니다.","success"),it()}catch{M("턴 이동에 실패했습니다.","error")}finally{Na()}},p=async()=>{if(!n||!Qs(t))return;const u=qt.value.trim();if(!u){M("먼저 Actor를 선택하세요.","warning");return}const f=Number.parseInt(_o.value,10),_=Number.parseInt(fo.value,10);if(Number.isNaN(f)||Number.isNaN(_)){M("stat/dc는 숫자여야 합니다.","warning");return}const h=Number.parseInt(zs.value,10),b=zs.value.trim()===""||Number.isNaN(h)?void 0:h;try{await wu({roomId:n,actorId:u,action:vo.value.trim()||"ability_check",statValue:f,dc:_,rawD20:b}),M("주사위 판정을 기록했습니다.","success"),it()}catch{M("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${u=>{Je.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${qt.value}
            onChange=${u=>{qt.value=u.target.value}}
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
              value=${vo.value}
              onInput=${u=>{vo.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${_o.value}
              onInput=${u=>{_o.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${fo.value}
              onInput=${u=>{fo.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${zs.value}
              onInput=${u=>{zs.value=u.target.value}}
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
  `}function zh({state:e}){var a;const t=Je.value||((a=e.session)==null?void 0:a.room)||"",n=Es.value,s=async()=>{if(!t){M("Room ID가 비어 있습니다.","warning");return}const i=js.value.trim(),l=yo.value.trim();if(!l&&!i){M("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(wn.value.trim(),10),p=Number.parseInt(Co.value.trim(),10),m=Number.isFinite(p)?Math.max(1,p):20,u=Number.isFinite(c)?Math.max(0,Math.min(m,c)):m;let f={};try{f=$h(Ao.value)}catch(_){M(_ instanceof Error?_.message:"능력치 JSON 오류","error");return}Es.value="spawning";try{const _=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,h=await qu(t,{actor_id:i||void 0,name:l||void 0,role:bo.value,idempotencyKey:_,portrait:xo.value.trim()||void 0,background:So.value.trim()||void 0,hp:u,max_hp:m,alive:u>0,stats:Object.keys(f).length>0?f:void 0}),b=typeof h.actor_id=="string"?h.actor_id.trim():"";if(!b)throw new Error("생성 응답에 actor_id가 없습니다.");const C=ko.value.trim();C&&await Fu(t,b,C),qt.value=b,et.value=b,i||(js.value=""),Es.value="ok",M(`Actor 생성 완료: ${b}`,"success"),await it()}catch(_){Es.value="error",M(_ instanceof Error?_.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${yo.value}
            onInput=${i=>{yo.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${bo.value}
            onChange=${i=>{bo.value=i.target.value}}
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
            value=${ko.value}
            onInput=${i=>{ko.value=i.target.value}}
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
              value=${js.value}
              onInput=${i=>{js.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${xo.value}
              onInput=${i=>{xo.value=i.target.value}}
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
              value=${wn.value}
              onInput=${i=>{wn.value=i.target.value}}
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
              value=${Co.value}
              onInput=${i=>{const l=i.target.value;Co.value=l,hh(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${So.value}
              onInput=${i=>{So.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Ao.value}
              onInput=${i=>{Ao.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Ph({state:e,nowMs:t}){var _;const n=Je.value||((_=e.session)==null?void 0:_.room)||"",s=e.join_gate,a=ho.value,i=v(a)?a:null,l=(e.party??[]).filter(h=>h.role!=="dm"),c=et.value.trim(),p=l.some(h=>h.id===c),m=p?c:c?"__manual__":"",u=async()=>{const h=et.value.trim(),b=Ms.value.trim();if(!n||!h){M("Room/Actor가 필요합니다.","warning");return}Ce.value="checking";try{const C=await Ku(n,h,b||void 0);ho.value=C,Ce.value="ok",M("참가 가능 여부를 갱신했습니다.","success")}catch(C){Ce.value="error";const S=C instanceof Error?C.message:"참가 가능 여부 확인에 실패했습니다.";M(S,"error")}},f=async()=>{var T,$;const h=et.value.trim(),b=Ms.value.trim(),C=$o.value.trim();if(!n||!h||!b){M("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Qs(t))return;const S=((T=e.current_round)==null?void 0:T.phase)??(($=e.session)==null?void 0:$.status)??"unknown";if(ci("Mid-Join 승인 요청",n,S)){Ce.value="requesting";try{const x=await Uu({room_id:n,actor_id:h,keeper_name:b,role:go.value,...C?{name:C}:{}});ho.value=x;const R=v(x)?ss(x,"granted",!1):!1,z=v(x)?ye(x,"reason_code",""):"";R?M("Mid-Join이 승인되었습니다.","success"):M(`Mid-Join이 거절되었습니다${z?`: ${z}`:""}`,"warning"),Ce.value=R?"ok":"error",it()}catch(x){Ce.value="error";const R=x instanceof Error?x.message:"Mid-Join 요청에 실패했습니다.";M(R,"error")}finally{Na()}}};return o`
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
            value=${m}
            onChange=${h=>{const b=h.target.value;if(b==="__manual__"){(p||!c)&&(et.value="");return}et.value=b}}
          >
            <option value="">Actor 선택</option>
            ${l.map(h=>o`
              <option value=${h.id}>${h.name} (${h.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${m==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${et.value}
                onInput=${h=>{et.value=h.target.value}}
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
            value=${Ms.value}
            onInput=${h=>{Ms.value=h.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${go.value}
            onChange=${h=>{go.value=h.target.value}}
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
            value=${$o.value}
            onInput=${h=>{$o.value=h.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${u} disabled=${Ce.value==="checking"||Ce.value==="requesting"}>
              ${Ce.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${f} disabled=${Ce.value==="checking"||Ce.value==="requesting"}>
              ${Ce.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${ss(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Ee(i,"effective_score",0)}/${Ee(i,"required_points",0)}</span>
            ${ye(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${ye(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function ud({state:e}){const t=[...e.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return t.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${t.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function pd({state:e}){var n;const t=e.current_round;return t?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${t.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${t.phase}</div>
      ${t.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=t.events[t.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function md(){const e=ri.value;if(!e)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const t=e.summary,n=v(t)?t:null,a=(Array.isArray(e.statuses)?e.statuses:[]).filter(v).slice(-8),i=e.canon_check,l=v(i)?i:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(z=>typeof z=="string").slice(0,3):[],p=l&&Array.isArray(l.violations)?l.violations.filter(z=>typeof z=="string").slice(0,3):[],m=n?ss(n,"advanced",!1):!1,u=n?ye(n,"progress_reason",""):"",f=n?ye(n,"progress_detail",""):"",_=n?Ee(n,"player_successes",0):0,h=n?Ee(n,"player_required_successes",0):0,b=n?ss(n,"dm_success",!1):!1,C=n?Ee(n,"timeouts",0):0,S=n?Ee(n,"unavailable",0):0,T=n?Ee(n,"reprompts",0):0,$=n?Ee(n,"npc_attacks",0):0,x=n?Ee(n,"keeper_timeout_sec",0):0,R=n?Ee(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${m?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${m?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${e.turn_before??0} → ${e.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${b?"DM ok":"DM stalled"} / players ${_}/${h}
          </span>
        </div>
        ${u?o`<div style="margin-top:4px; font-size:12px;">${u}</div>`:null}
        ${f?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${f}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${$}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${x||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${R}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(z=>{const q=ye(z,"status","unknown"),L=ye(z,"actor_id","-"),Q=ye(z,"role","-"),Z=ye(z,"reason",""),ae=ye(z,"action_type",""),W=ye(z,"reply","");return o`
                <div class="trpg-round-item ${q.includes("fallback")||q.includes("timeout")?"failed":"active"}">
                  <span>${L} (${Q})</span>
                  <span style="margin-left:auto; font-size:11px;">${q}</span>
                  ${ae?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${ae}</div>`:null}
                  ${Z?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${Z}</div>`:null}
                  ${W?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${W.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${ye(l,"status","unknown")}</strong>
            </div>
            ${p.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${p.map(z=>o`<div>violation: ${z}</div>`)}
                </div>`:null}
            ${c.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(z=>o`<div>warning: ${z}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Mh({state:e,nowMs:t}){var l,c,p;const n=Je.value||((l=e.session)==null?void 0:l.room)||"",s=((c=e.current_round)==null?void 0:c.phase)??((p=e.session)==null?void 0:p.status)??"unknown",a=id(t),i=kh(t);return o`
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
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>xh(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Na(),M("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function jh({active:e}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${e===n.id?"active":""}"
          role="tab"
          aria-selected=${e===n.id}
          onClick=${()=>bh(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Eh({state:e}){const t=e.party??[],n=e.story_log??[];return o`
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
          <${cd} events=${n.slice(-20)} />
        <//>

        ${e.map?o`
            <${I} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${Th} mapStr=${e.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${I} title="현재 라운드" semanticId="lab.trpg">
          <${pd} state=${e} />
        <//>

        <${I} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${ud} state=${e} />
        <//>

        <${I} title=${`파티 (${t.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${t.map(s=>o`<${ld} key=${s.id??s.name} actor=${s} />`)}
            ${t.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${e.history&&e.history.length>0?o`
            <${I} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
              <${dd} state=${e} />
            <//>
          `:null}
      </div>
    </div>
  `}function Nh({state:e}){const t=e.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${I} title=${`이벤트 타임라인 (${t.length})`}>
          <${Ih} events=${t} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${I} title="최근 라운드 결과" semanticId="lab.trpg">
          <${md} />
        <//>

        <${I} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${pd} state=${e} />
        <//>
      </div>
    </div>
  `}function Dh({state:e,nowMs:t}){const n=e.party??[];return o`
    <div>
      <${Mh} state=${e} nowMs=${t} />
      <div class="trpg-layout">
        <div>
          <${I} title="조작 패널" semanticId="lab.trpg">
            <${Lh} state=${e} nowMs=${t} />
          <//>

          <${I} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${zh} state=${e} />
          <//>

          <${I} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${Ph} state=${e} nowMs=${t} />
          <//>

          <${I} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${md} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${I} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${ud} state=${e} />
          <//>

          <${I} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${ld} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${e.history&&e.history.length>0?o`
              <${I} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
                <${dd} state=${e} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function wh(){var c,p,m,u,f;const e=Al.value,t=Fo.value;if(se(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const _=window.setInterval(()=>{Gr.value=Date.now()},1e3);return()=>{window.clearInterval(_)}},[]),t&&!e)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!e)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>it()}>Refresh</button>
      </div>
    `;const n=e.party??[],s=e.story_log??[],a=e.outcome,i=od.value,l=Gr.value;return o`
    <div>
      <${xe} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Je.value||((c=e.session)==null?void 0:c.room)||"-"} · phase: ${((p=e.current_round)==null?void 0:p.phase)??((m=e.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>it()}>새로고침</button>
      </div>

      <${Rh} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((u=e.session)==null?void 0:u.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((f=e.current_round)==null?void 0:f.round_number)??0}</div>
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

      <${jh} active=${i} />

      ${i==="overview"?o`<${Eh} state=${e} />`:i==="timeline"?o`<${Nh} state=${e} />`:o`<${Dh} state=${e} nowMs=${l} />`}
    </div>
  `}function Oh(){return o`
    <div>
      <${xe} surfaceId="lab" />
      <${I} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${I} title="TRPG" class="section" semanticId="lab.trpg">
        <${wh} />
      <//>
    </div>
  `}const Da=g(new Set(["broadcast","tasks","keepers","system"]));function qh(e){const t=new Set(Da.value);t.has(e)?t.delete(e):t.add(e),Da.value=t}const Ji=g(null);function vd(e){Ji.value=e}function Fh(e){return e.kind==="board"?"broadcast":e.kind==="tasks"?"tasks":e.kind==="keepers"?"keepers":"system"}const Kh=ze(()=>{const e=Da.value;return Xs.value.filter(t=>e.has(Fh(t)))}),Uh=12e4,Hh=ze(()=>{const e=Ll.value,t=Date.now();return Ye.value.map(n=>{const s=n.name.trim().toLowerCase(),a=e.get(s)??null;let i="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?i=t-new Date(l).getTime()>Uh?"stale":"working":i="working"}else(n.status==="offline"||n.status==="inactive")&&(i="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:i,currentTask:n.current_task,motion:a}})}),Bh=ze(()=>{const e=Ll.value;return Ye.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle").map(t=>{const n=t.name.trim().toLowerCase(),s=e.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let i="calm";return a>=3?i="hot":a>=1&&(i="normal"),{name:t.name,emoji:t.emoji??"",koreanName:t.koreanName??null,currentTask:t.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:i}}).sort((t,n)=>{const s={hot:0,normal:1,calm:2};return s[t.pressure]-s[n.pressure]})});function Jr(e){return e.kind==="board"?"live-event-broadcast":e.kind==="tasks"?"live-event-task":e.kind==="keepers"?"live-event-keeper":"live-event-system"}function Wh(e){const t=e.eventType;return t==="broadcast"?"broadcast":t==="agent_joined"?"joined":t==="agent_left"?"left":t==="task_update"?"task":t==="board_post"?"post":t==="board_comment"?"comment":t==="keeper_heartbeat"?"heartbeat":t==="keeper_handoff"?"handoff":t==="keeper_compaction"?"compact":t==="keeper_guardrail"?"guardrail":e.kind==="board"?"board":e.kind==="tasks"?"task":e.kind==="keepers"?"keeper":"system"}function Gh(e){switch(e){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function Jh(){const e=Hh.value,t=Ji.value;return e.length===0?o`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:o`
    <div class="pulse-strip">
      ${e.map(n=>o`
        <button
          key=${n.name}
          class="pulse-bubble ${Gh(n.state)} ${t===n.name?"pulse-selected":""}"
          onClick=${()=>vd(t===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const Vh=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function Qh(){const e=Da.value;return o`
    <div class="activity-filter-bar">
      ${Vh.map(t=>o`
        <button
          key=${t.kind}
          class="activity-filter-btn ${t.cssClass} ${e.has(t.kind)?"active":""}"
          onClick=${()=>qh(t.kind)}
        >
          ${t.label}
        </button>
      `)}
    </div>
  `}function Yh(){const e=Kh.value;return o`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${e.length} events</span>
      </div>
      <${Qh} />
      <div class="activity-stream-list">
        ${e.length===0?o`<div class="activity-empty">No events matching filters</div>`:e.map((t,n)=>o`
            <div
              key=${`${t.timestamp}-${n}`}
              class="activity-item ${Jr(t)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${Jr(t)}">${Wh(t)}</span>
                <span class="activity-agent">${t.agent}</span>
                <span class="activity-time">${Ic(t.timestamp)}</span>
              </div>
              <div class="activity-item-text">${t.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function Xh(e){switch(e){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function Zh(e){switch(e){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function ey(){const e=Bh.value,t=Ji.value;return o`
    <div class="focus-sidebar">
      <div class="focus-sidebar-head">
        <h3>Agents</h3>
        <span class="focus-count">${e.length} active</span>
      </div>
      <div class="focus-sidebar-list">
        ${e.length===0?o`<div class="focus-empty">No active agents</div>`:e.map(n=>o`
            <div
              key=${n.name}
              class="focus-agent-card ${t===n.name?"focus-agent-selected":""}"
              onClick=${()=>vd(t===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?o`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${Xh(n.pressure)}">
                  ${Zh(n.pressure)}
                  ${n.assignedCount>0?o` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?o`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?o`<span class="focus-activity-text">${n.lastActivityText}</span>`:o`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?o`<${G} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function ty(){const e=dt.value;return o`
    <div class="live-monitor">
      <div class="live-header">
        <h2>라이브 모니터</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${e?"connected":"disconnected"}"></span>
            ${e?"연결됨":"오프라인"}
          </span>
          <span class="live-stat">에이전트 ${Ye.value.length}</span>
          <span class="live-stat">이벤트 ${wa.value}</span>
        </div>
      </div>

      <${Jh} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${Yh} />
        </div>
        <div class="live-panel-side">
          <${ey} />
        </div>
      </div>
    </div>
  `}const Vr=[{id:"now",label:"지금",description:"지금 무슨 일이 벌어지는지 사회의 현재 상태를 먼저 읽는 표면"},{id:"why",label:"이유",description:"왜 그렇게 보이는지 근거, 메모리, 거버넌스로 뒤를 파는 표면"},{id:"act",label:"개입",description:"운영자 액션과 계획 조정을 통해 지금 상태를 바꾸는 표면"},{id:"lab",label:"실험",description:"실험적 오케스트레이션과 고급 지휘 표면을 분리해서 보는 영역"}],di=[{id:"mission",label:"상황판",icon:"🏠",group:"now",description:"room 중심으로 지금 상황과 사회의 흐름을 가장 먼저 읽는 기본 랜딩"},{id:"execution",label:"실행",icon:"🤖",group:"now",description:"agents, keepers, sessions를 중심으로 사회의 행위자를 읽는 표면"},{id:"live",label:"라이브",icon:"📡",group:"now",description:"실시간 에이전트 활동과 이벤트 흐름을 사회 관찰 관점으로 보는 표면"},{id:"proof",label:"근거",icon:"🔍",group:"why",description:"협업, 대화, 실행의 증거 경로를 확인하는 표면"},{id:"memory",label:"메모리",icon:"💬",group:"why",description:"게시글, 댓글, 비동기 기억으로 room의 누적 맥락을 읽는 표면"},{id:"governance",label:"거버넌스",icon:"⚖️",group:"why",description:"토론, 표결, 판단 구조를 규범과 결정의 관점에서 읽는 표면"},{id:"planning",label:"계획",icon:"🎯",group:"act",description:"목표, 백로그, 압력을 운영 관점으로 읽는 계획 표면"},{id:"tools",label:"도구",icon:"🧰",group:"act",description:"시스템 전체 도구 inventory와 사용 건강도를 확인하는 운영 표면"},{id:"intervene",label:"개입",icon:"🎮",group:"act",description:"룸, 세션, 키퍼에 직접 개입하는 운영 화면"},{id:"command",label:"지휘",icon:"🧭",group:"lab",description:"command-plane, swarm, resolution 같은 고급 지휘/실험 표면"},{id:"lab",label:"실험",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 표면을 메인 사회/운영 콘솔 밖에서 다룹니다"}];function ny(e){const t=e==null?void 0:e.trim();return t?t.length>10?t.slice(0,10):t:"커밋 정보 없음"}function Ie(e,t){return t==="live"?"가동 중":t==="quiet"?"조용함":t==="starting"?"기동 중":t==="idle"?e==="guardian"?"유휴":"대기 중":"비활성"}function Ae(e,t){return o`
    <div class="build-badge-row">
      <span>${e}</span>
      <strong>${t}</strong>
    </div>
  `}function Ds(e,t,n,s,a){return o`
    <div style="padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
      <div class="rail-card-head" style="margin:0;">
        <h3 style="font-size:12px;">${e}</h3>
        <span class="rail-section-chip ${n}">${t}</span>
      </div>
      ${s}
      ${a?o`<div class="rail-build-hint">${a}</div>`:null}
    </div>
  `}function sy({currentTab:e}){var p,m,u,f,_,h,b,C,S,T;const t=dt.value,n=(p=oe.value)==null?void 0:p.build,s=(m=oe.value)==null?void 0:m.lodge,a=(u=oe.value)==null?void 0:u.gardener,i=(f=oe.value)==null?void 0:f.guardian,l=(_=oe.value)==null?void 0:_.sentinel,c=[];if(s&&c.push(Ds("Lodge",s.enabled?Ie("lodge",s.quiet_active?"quiet":"live"):Ie("lodge","disabled"),s.enabled?s.quiet_active?"warn":"ok":"bad",[Ae("틱",s.total_ticks??0),Ae("체크인",s.total_checkins??0),Ae("최근 결과",((h=s.last_tick_result)==null?void 0:h.activity_report)??s.last_skip_reason??"없음")])),a&&c.push(Ds("Gardener",a.alive?Ie("gardener","live"):a.enabled?Ie("gardener","starting"):Ie("gardener","disabled"),a.alive?"ok":a.enabled?"warn":"bad",[Ae("최근 tick",a.last_tick_completed_at?o`<${G} timestamp=${a.last_tick_completed_at} />`:"기록 없음"),Ae("판단",`${a.last_intervention??"없음"} · ${a.last_decision_source??"없음"}`),Ae("백로그",`미할당 ${((b=a.health_summary)==null?void 0:b.todo_count)??0} · P1/2 ${((C=a.health_summary)==null?void 0:C.high_priority_todo)??0}`)],a.last_reason??a.last_error??void 0)),i){const $=i.masc_loops_running||i.lodge_loop_started||i.lodge_running;c.push(Ds("Guardian",$?Ie("guardian","live"):i.enabled?Ie("guardian","idle"):Ie("guardian","disabled"),$?"ok":i.enabled?"warn":"bad",[Ae("모드",i.mode??"알 수 없음"),Ae("루프",`zombie ${i.zombie_loop_running?"on":"off"} · gc ${i.gc_loop_running?"on":"off"}`),Ae("소유자",i.runtime_owner??"없음")],((S=i.last_lodge_result)==null?void 0:S.message)??i.last_gc_result??i.last_zombie_result??void 0))}return l&&c.push(Ds("Sentinel",l.started?Ie("sentinel","live"):l.enabled?Ie("sentinel","starting"):Ie("sentinel","disabled"),l.started?"ok":l.enabled?"warn":"bad",[Ae("에이전트",l.agent_name??"sentinel"),Ae("소비자",((T=l.consumers)==null?void 0:T.length)??0),Ae("가디언 소유자",l.guardian_runtime_owner??"없음")],l.llm_enabled===!0?"LLM 기반 housekeeping resident":void 0)),o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${w} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${t?"ok":"bad"}">${t?"연결됨":"오프라인"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>에이전트</span>
          <strong>${Ye.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>키퍼</span>
          <strong>${_t.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>태스크</span>
          <strong>${st.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>이벤트</span>
          <strong>${wa.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{os(),jl(),Qo(e)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>ie("intervene")}>
          개입 열기
        </button>
      </div>
      ${n?o`<div class="rail-build-hint">서버 빌드 · v${n.release_version} · ${ny(n.commit)}</div>`:null}
      ${c.length>0?o`
            <div style="margin-top:12px; display:flex; flex-direction:column; gap:10px;">
              ${c}
            </div>
          `:null}
    </section>
  `}function ay(){const e=ge.value,t=(e==null?void 0:e.pending_confirms.length)??0,n=(e==null?void 0:e.sessions.length)??0,s=(e==null?void 0:e.keepers.length)??0;return o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${w} panelId="side_rail.quick_actions" compact=${!0} />
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
          onClick=${()=>{ke(),Mt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>ie("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}const ws=g(!1);function oy(){const e=dt.value;return o`
    <div class="connection-status ${e?"connected":"disconnected"}">
      <span class="status-dot ${e?"connected":"disconnected"}"></span>
      <span class="status-text">${e?"연결됨":"재연결 중..."}</span>
      <span class="event-count">이벤트 ${wa.value}</span>
    </div>
  `}function iy(e){const t=e==null?void 0:e.trim();return t?t.length>10?t.slice(0,10):t:"커밋 정보 없음"}function ry(){const e=oe.value,t=e==null?void 0:e.build,n=t?`v${t.release_version} · ${iy(t.commit)}`:e!=null&&e.version?`v${e.version} · 커밋 정보 없음`:"버전 정보 없음";return o`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${ws.value}
        onClick=${()=>{ws.value=!ws.value}}
      >
        서버 빌드 · ${n}
      </button>
      ${ws.value?o`
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
                <strong>${t!=null&&t.started_at?o`<${G} timestamp=${t.started_at} />`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof(t==null?void 0:t.uptime_seconds)=="number"?`${t.uptime_seconds}s`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${e!=null&&e.generated_at?o`<${G} timestamp=${e.generated_at} />`:"알 수 없음"}</strong>
              </div>
            </div>
          `:null}
    </div>
  `}function ly(){const e=D.value.tab,t=di.find(s=>s.id===e),n=Vr.find(s=>s.id===(t==null?void 0:t.group));return o`
    <aside class="dashboard-rail">
      <${xe} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${w} panelId="side_rail.navigate" compact=${!0} />
          ${n?o`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${Vr.map(s=>o`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${di.filter(a=>a.group===s.id).map(a=>o`
                  <button
                    class="rail-tab-btn ${e===a.id?"active":""}"
                    onClick=${()=>ie(a.id)}
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

      <${sy} currentTab=${e} />
      <${ay} />
    </aside>
  `}function cy(){switch(D.value.tab){case"mission":return o`<${hr} />`;case"proof":return o`<${Pf} />`;case"execution":return o`<${I$} />`;case"tools":return o`<${E$} />`;case"live":return o`<${ty} />`;case"memory":return o`<${m$} />`;case"governance":return o`<${ch} />`;case"planning":return o`<${Q$} />`;case"intervene":return o`<${e$} />`;case"command":return o`<${Qg} />`;case"lab":return o`<${Oh} />`;default:return o`<${hr} />`}}function dy(){return qo.value&&!dt.value?o`<div class="loading-indicator">대시보드 불러오는 중...</div>`:o`<${cy} />`}function uy(){se(()=>{Cd(),sl(),El(),Tt(),jl(),Ql();const n=Zp();return em(),()=>{Md(),n(),tm()}},[]),se(()=>{const n=setInterval(()=>{Qo(D.value.tab)},15e3);return()=>{clearInterval(n)}},[]),se(()=>{Qo(D.value.tab)},[D.value.tab]);const e=D.value.tab,t=di.find(n=>n.id===e);return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC 대시보드
            <${ry} />
          </h1>
          <p class="header-subtitle">${(t==null?void 0:t.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${oy} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${ly} />
        <main class="dashboard-main">
          <${dy} />
        </main>
      </div>

      <${q_} />
      <${f_} />
      <${i_} />
    </div>
  `}const Qr=document.getElementById("app");Qr&&yd(o`<${uy} />`,Qr);export{Q_ as _};
