var Dc=Object.defineProperty;var Oc=(e,t,n)=>t in e?Dc(e,t,{enumerable:!0,configurable:!0,writable:!0,value:n}):e[t]=n;var Lt=(e,t,n)=>Oc(e,typeof t!="symbol"?t+"":t,n);import{e as qc,_ as Fc,c as g,b as Ce,y as ne,d as xr,A as Kc,G as Bc}from"./vendor-kuFK4-oj.js";(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const l of i.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var o=qc.bind(Fc);const Uc=["mission","proof","execution","live","memory","governance","planning","intervene","command","lab"],Sr={tab:"mission",params:{},postId:null};function Pi(e){return!!e&&Uc.includes(e)}function vo(e){try{return decodeURIComponent(e)}catch{return e}}function _o(e){const t={};return e&&new URLSearchParams(e).forEach((s,a)=>{t[a]=s}),t}function Hc(e){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Ar(e,t){if(e[0]==="chains"){const i={...t,surface:"chains"};return e[1]==="operation"&&e[2]&&(i.operation=vo(e[2])),{tab:"command",params:i,postId:null}}if(e[0]==="lab"){const i={...t};return e[1]&&(i.surface=vo(e[1])),{tab:"lab",params:i,postId:null}}const n=e[0],s=t.tab;return{tab:Pi(n)?n:Pi(s)?s:"mission",params:t,postId:null}}function Fs(e){const t=(e||"").replace(/^#/,"").trim();if(!t)return Sr;const n=vo(t);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=_o(a),l=Hc(s);return Ar(l,i)}function Wc(e,t){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Sr,params:_o(t.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=_o(t.replace(/^\?/,""));return Ar(s,a)}function Cr(e){const t=e.tab==="lab"&&e.params.surface?`lab/${encodeURIComponent(e.params.surface)}`:e.tab,n=Object.entries(e.params).filter(([a])=>!(a==="tab"||e.tab==="lab"&&a==="surface"));if(n.length===0)return`#${t}`;const s=new URLSearchParams(n);return`#${t}?${s.toString()}`}const F=g(Fs(window.location.hash));window.addEventListener("hashchange",()=>{F.value=Fs(window.location.hash)});function se(e,t){const n={tab:e,params:t??{}};window.location.hash=Cr(n)}function Gc(e){window.location.hash=`#memory?post=${encodeURIComponent(e)}`}function Jc(){if(window.location.hash&&window.location.hash!=="#"){F.value=Fs(window.location.hash);return}const e=Wc(window.location.pathname,window.location.search);if(e){F.value=e;const t=Cr(e);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${t}`);return}window.location.hash="#mission",F.value=Fs(window.location.hash)}const Li="masc_dashboard_sse_session_id",Vc=1e3,Qc=15e3,ot=g(!1),Aa=g(0),Ir=g(null),Ks=g([]);function Yc(){let e=sessionStorage.getItem(Li);return e||(e=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Li,e)),e}const Xc=200;function Zc(e,t,n="system",s={}){const a={agent:e,text:t,timestamp:Date.now(),kind:n,...s};Ks.value=[a,...Ks.value].slice(0,Xc)}function go(e,t=88){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-3)}...`:n:void 0}function zi(e,t){const n=go(t);return n?`${e}: ${n}`:`New ${e.toLowerCase()}`}function Ae(e,t,n,s,a={}){Zc(e,t,n,{eventType:s,...a})}let ze=null,Ut=null,fo=0;function Tr(){Ut&&(clearTimeout(Ut),Ut=null)}function ed(){if(Ut)return;fo++;const e=Math.min(fo,5),t=Math.min(Qc,Vc*Math.pow(2,e));Ut=setTimeout(()=>{Ut=null,Rr()},t)}function Rr(){Tr(),ze&&(ze.close(),ze=null);const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");n&&t.set("agent",n),s&&t.set("token",s),t.set("session_id",Yc());const a=t.toString()?`/sse?${t.toString()}`:"/sse",i=new EventSource(a);ze=i,i.onopen=()=>{ze===i&&(fo=0,ot.value=!0)},i.onerror=()=>{ze===i&&(ot.value=!1,i.close(),ze=null,ed())},i.onmessage=l=>{try{const c=JSON.parse(l.data);Aa.value++,Ir.value=c,td(c)}catch{}}}function td(e){const t=e.type,n=e.agent??e.author??e.from??e.from_agent??"";switch(t){case"agent_joined":Ae(n,"Joined","system","agent_joined");break;case"agent_left":Ae(n,"Left","system","agent_left");break;case"broadcast":Ae(n,`${(e.message??e.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Ae(n,`Task: ${e.task_id??""} -> ${e.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Ae(n,zi("Post",e.content??e.message),"board","board_post",{author:e.author??n,preview:go(e.content??e.message),postId:e.post_id});break;case"board_comment":case"masc/board_comment":Ae(n,zi("Comment",e.content??e.message),"board","board_comment",{author:e.author??n,preview:go(e.content??e.message),postId:e.post_id});break;case"keeper_heartbeat":Ae(e.name??n,`Heartbeat gen=${e.generation??"?"} ctx=${e.context_ratio!=null?Math.round(e.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Ae(e.name??n,`Handoff gen ${e.from_generation??"?"} -> ${e.to_generation??"?"} (${e.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Ae(e.name??n,`Compaction saved ${e.saved_tokens??"?"} tokens (${e.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Ae(e.name??n,`Guardrail: ${e.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Ae(n,t,"system","unknown")}}function nd(){Tr(),ze&&(ze.close(),ze=null),ot.value=!1}function v(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function r(e){return typeof e=="string"&&e.trim()!==""?e.trim():void 0}function d(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function j(e){return typeof e=="boolean"?e:void 0}function H(e){return Array.isArray(e)?e.map(t=>typeof t=="string"?t.trim():"").filter(Boolean):[]}function pe(e,t=[]){if(Array.isArray(e))return e;if(!v(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function ae(e){if(typeof e=="string"&&e.trim()!=="")return e;if(!(typeof e!="number"||!Number.isFinite(e)||e<=0))return new Date(e*1e3).toISOString()}function Pr(){return new URLSearchParams(window.location.search)}const sd="masc_dashboard_agent_name";function ad(){var e;try{return((e=localStorage.getItem(sd))==null?void 0:e.trim())||null}catch{return null}}function Lr(){const e=Pr(),t={},n=e.get("token"),s=ad(),a=e.get("agent")??e.get("agent_name")??s;return n&&(t.Authorization=`Bearer ${n}`),a&&(t["X-MASC-Agent"]=a),t}function zr(){return{...Lr(),"Content-Type":"application/json"}}const od=15e3,Wo=3e4,id=6e4,Mi=new Set([408,425,429,500,502,503,504]);class Qn extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);Lt(this,"method");Lt(this,"path");Lt(this,"status");Lt(this,"statusText");Lt(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function Go(e,t,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(e,{...t,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const l=typeof t.method=="string"?t.method.toUpperCase():"GET";throw new Qn({method:l,path:e,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function rd(){var t,n;const e=Pr();return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function X(e){const t=await Go(e,{headers:Lr()},od);if(!t.ok)throw new Qn({method:"GET",path:e,status:t.status,statusText:t.statusText});return t.json()}function ld(e){return new Promise(t=>setTimeout(t,e))}function cd(e){const t=e.match(/\b(\d{3})\b/);if(!t)return null;const n=t[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function dd(e){if(e instanceof Qn)return e.timeout||typeof e.status=="number"&&Mi.has(e.status);if(!(e instanceof Error))return!1;if(/timeout after \d+ms/i.test(e.message))return!0;const t=cd(e.message);return t!==null&&Mi.has(t)}async function Ca(e,t,n=2){let s=0;for(;;)try{return await t()}catch(a){if(!dd(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${e} failed (attempt ${s+1}), retrying in ${i}ms`,a),await ld(i),s+=1}}async function we(e,t,n,s=Wo){const a=await Go(e,{method:"POST",headers:{...zr(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new Qn({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.json()}async function ud(e,t,n,s=Wo){const a=await Go(e,{method:"POST",headers:{...zr(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new Qn({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.text()}function pd(e){const t=e.split(`
`).find(s=>s.startsWith("data: ")),n=t?t.slice(6).trim():e.trim();return JSON.parse(n)}function md(e){var t,n,s,a,i,l,c;if((t=e.error)!=null&&t.message)throw new Error(e.error.message);if((n=e.result)!=null&&n.isError){const p=((a=(s=e.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(p)}return((c=(l=(i=e.result)==null?void 0:i.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function ct(e,t){const n=await ud("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:e,arguments:t},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},id),s=pd(n);return md(s)}function vd(){return X("/api/v1/dashboard/shell")}function _d(){return X("/api/v1/dashboard/execution")}function gd(e,t){const n=new URLSearchParams;return n.set("sort_by",e),t!=null&&t.excludeSystem&&n.set("exclude_system","true"),X(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function fd(){return Ca("fetchDashboardGovernance",async()=>{const e=await X("/api/v1/dashboard/governance"),t=Array.isArray(e.items)?e.items.map(i=>Ed(i)).filter(i=>i!==null):[],n=Array.isArray(e.pending_actions)?e.pending_actions.map(i=>Er(i)).filter(i=>i!==null):[],s=t.filter(i=>i.kind==="debate").map(i=>({id:i.id,topic:i.topic,status:i.status,argument_count:i.evidence_refs.length,created_at:i.last_activity_at??void 0})),a=t.filter(i=>i.kind==="consensus").map(i=>({id:i.id,topic:i.topic,initiator:i.related_agents[0]||"system",votes:i.votes??0,quorum:i.quorum??0,threshold:i.threshold,state:i.status,created_at:i.last_activity_at??void 0}));return{generated_at:le(e.generated_at)??void 0,summary:v(e.summary)?{debates:me(e.summary.debates)??void 0,voting_sessions:me(e.summary.voting_sessions)??void 0,debates_open:me(e.summary.debates_open)??void 0,sessions_active:me(e.summary.sessions_active)??void 0,sessions_without_quorum:me(e.summary.sessions_without_quorum)??void 0,ready_to_execute:me(e.summary.ready_to_execute)??void 0,oldest_open_debate_age_s:typeof e.summary.oldest_open_debate_age_s=="number"?e.summary.oldest_open_debate_age_s:null,last_activity_age_s:typeof e.summary.last_activity_age_s=="number"?e.summary.last_activity_age_s:null,judge_online:typeof e.summary.judge_online=="boolean"?e.summary.judge_online:void 0,judge_last_seen_at:le(e.summary.judge_last_seen_at)}:void 0,debates:s,sessions:a,items:t,activity:Array.isArray(e.activity)?e.activity.map(i=>jd(i)).filter(i=>i!==null):[],judge:wd(e.judge),pending_actions:n}})}function $d(){return X("/api/v1/dashboard/semantics")}function hd(){return X("/api/v1/dashboard/mission")}function yd(e){const t=`?session_id=${encodeURIComponent(e)}`;return X(`/api/v1/dashboard/session${t}`)}function bd(e=!1){return X(`/api/v1/dashboard/mission/briefing${e?"?force=1":""}`)}function kd(e,t){const n=new URLSearchParams;e&&n.set("session_id",e),t&&n.set("operation_id",t);const s=n.toString();return X(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function xd(){return X("/api/v1/dashboard/planning")}function Sd(){return X("/api/v1/tool-metrics")}function Ad(){return X("/api/v1/operator")}function Mr(e={}){const t=new URLSearchParams;e.targetType&&t.set("target_type",e.targetType),e.targetId&&t.set("target_id",e.targetId),e.includeWorkers!=null&&t.set("include_workers",e.includeWorkers?"true":"false");const n=t.toString();return X(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Cd(){return X("/api/v1/command-plane")}function Id(){return X("/api/v1/command-plane/summary")}function Td(){return X("/api/v1/chains/summary")}function Rd(e){return X(`/api/v1/chains/runs/${encodeURIComponent(e)}`)}function Pd(){return X("/api/v1/command-plane/help")}function Ld(e,t){const n=new URLSearchParams;e&&n.set("run_id",e),t&&n.set("operation_id",t);const s=n.toString();return X(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function zd(e,t){const n=new URLSearchParams;e&&n.set("run_id",e),t&&n.set("operation_id",t);const s=n.toString();return X(`/api/v1/command-plane/orchestra${s?`?${s}`:""}`)}function Md(e,t){return we(e,t)}function Nd(e){switch(e.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"swarm_run_continue":return 6e4;case"swarm_run_rerun":return 12e4;case"swarm_run_abandon":return 3e4;case"lodge_tick":return 45e3;default:return Wo}}function Ia(e){return we("/api/v1/operator/action",e,void 0,Nd(e))}function Nr(e,t,n="confirm"){return we("/api/v1/operator/confirm",{actor:e,confirm_token:t,decision:n})}function Ts(e){if(typeof e=="string"&&e.trim())return e;if(typeof e!="number"||Number.isNaN(e))return new Date().toISOString();const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}function le(e){if(typeof e=="string"){const t=e.trim();return t||null}if(typeof e=="number"&&Number.isFinite(e)){const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}return null}function q(e){if(typeof e!="string")return null;const t=e.trim();return t||null}function Er(e){if(!v(e))return null;const t=k(e.confirm_token??e.token,"").trim();return t?{confirm_token:t,actor:q(e.actor)??void 0,action_type:q(e.action_type)??void 0,target_type:q(e.target_type)??void 0,target_id:q(e.target_id),delegated_tool:q(e.delegated_tool)??void 0,created_at:le(e.created_at)??void 0,preview:e.preview}:null}function Jo(e){return v(e)?{board_post_id:q(e.board_post_id),task_id:q(e.task_id),operation_id:q(e.operation_id),team_session_id:q(e.team_session_id)}:{}}function jr(e){if(!v(e))return null;const t=q(e.action_kind),n=q(e.resolved_tool),s=q(e.target_type),a=q(e.target_id),i=q(e.reason);return!t&&!n&&!s&&!i?null:{action_kind:t??void 0,resolved_tool:n,target_type:s,target_id:a,reason:i??void 0,payload_preview:e.payload_preview}}function wr(e){if(!v(e))return null;const t=q(e.action_type),n=q(e.delegated_tool),s=q(e.confirmation_state),a=le(e.created_at);return!t&&!n&&!s&&!a?null:{action_type:t??void 0,delegated_tool:n,confirmation_state:s??void 0,created_at:a}}function Dr(e){if(!v(e))return null;const t=Er(e.pending_confirm),n=q(e.pending_confirm_token)??(t==null?void 0:t.confirm_token)??null;return{requires_human_gate:typeof e.requires_human_gate=="boolean"?e.requires_human_gate:void 0,pending_confirm:t,pending_confirm_token:n,ready_to_execute:typeof e.ready_to_execute=="boolean"?e.ready_to_execute:void 0}}function Or(e){if(!v(e))return null;const t=q(e.summary),n=q(e.target_id);return!t&&!n?null:{judgment_id:q(e.judgment_id)??void 0,target_kind:q(e.target_kind)??void 0,target_id:n??void 0,status:q(e.status)??void 0,summary:t??void 0,confidence:typeof e.confidence=="number"?e.confidence:null,generated_at:le(e.generated_at),expires_at:le(e.expires_at),model_used:q(e.model_used),keeper_name:q(e.keeper_name),evidence_refs:Me(e.evidence_refs),recommended_action:jr(e.recommended_action),guardrail_state:Dr(e.guardrail_state),executed_route:wr(e.executed_route)}}function Ed(e){if(!v(e))return null;const t=k(e.id,"").trim(),n=k(e.topic,"").trim();if(!t||!n)return null;const s=Jo(e.context);return{kind:k(e.kind,"debate"),id:t,topic:n,status:k(e.status??e.state,"open"),last_activity_at:le(e.last_activity_at),truth_summary:q(e.truth_summary)??void 0,judgment_summary:q(e.judgment_summary),confidence:typeof e.confidence=="number"?e.confidence:null,related_agents:Me(e.related_agents),context:s,linked_board_post_id:q(e.linked_board_post_id)??s.board_post_id??null,linked_task_id:q(e.linked_task_id)??s.task_id??null,linked_operation_id:q(e.linked_operation_id)??s.operation_id??null,linked_session_id:q(e.linked_session_id)??s.team_session_id??null,recommended_action:jr(e.recommended_action),executed_route:wr(e.executed_route),guardrail_state:Dr(e.guardrail_state),evidence_refs:Me(e.evidence_refs),approve_count:me(e.approve_count),reject_count:me(e.reject_count),abstain_count:me(e.abstain_count),votes:me(e.votes),quorum:me(e.quorum),threshold:typeof e.threshold=="number"?e.threshold:void 0}}function jd(e){if(!v(e))return null;const t=k(e.kind,"").trim();return t?{kind:t,item_kind:q(e.item_kind)??void 0,item_id:q(e.item_id)??void 0,topic:q(e.topic)??void 0,created_at:le(e.created_at),summary:q(e.summary)??void 0,actor:q(e.actor),index:me(e.index),decision:q(e.decision)}:null}function wd(e){if(v(e))return{judge_online:typeof e.judge_online=="boolean"?e.judge_online:void 0,refreshing:typeof e.refreshing=="boolean"?e.refreshing:void 0,generated_at:le(e.generated_at),expires_at:le(e.expires_at),model_used:q(e.model_used),keeper_name:q(e.keeper_name),last_error:q(e.last_error)}}function Dd(e){var a;const t=e.trim(),s=((a=(t.startsWith("[flair:")?t.replace(/^\[flair:[^\]]+\]\s*/i,""):t).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Od(e){if(!v(e))return null;const t=k(e.source,"").trim()||null,n=k(e.state_block,"").trim()||null;return!t&&!n?null:{source:t,state_block:n}}function qd(e){if(!v(e))return null;const t=k(e.id,"").trim(),n=k(e.author,"").trim(),s=k(e.body,"").trim()||k(e.content,"").trim(),a=s;if(!t||!n)return null;const i=B(e.score,0),l=B(e.votes_up,0),c=B(e.votes_down,0),p=B(e.votes,i||l-c),m=B(e.comment_count,B(e.reply_count,0)),u=(()=>{const S=e.flair;if(typeof S=="string"&&S.trim())return S.trim();if(v(S)){const x=k(S.name,"").trim();if(x)return x}return k(e.flair_name,"").trim()||void 0})(),_=k(e.created_at_iso,"").trim()||Ts(e.created_at),f=k(e.updated_at_iso,"").trim()||(e.updated_at!==void 0?Ts(e.updated_at):_),b=k(e.title,"").trim()||Dd(s),$=Array.isArray(e.tags)?e.tags.filter(S=>typeof S=="string"&&S.trim()!==""):[];return{id:t,author:n,post_kind:(()=>{const S=k(e.post_kind,"").trim().toLowerCase();return S==="automation"||S==="system"||S==="human"?S:void 0})(),title:b,body:s,content:a,meta:Od(e.meta),tags:$,votes:p,vote_balance:i,comment_count:m,created_at:_,updated_at:f,flair:u,hearth:k(e.hearth,"").trim()||null,visibility:k(e.visibility,"").trim()||void 0,expires_at:k(e.expires_at_iso,"").trim()||(e.expires_at!==void 0&&e.expires_at!==0?Ts(e.expires_at):"")||null,hearth_count:B(e.hearth_count,0)}}function Fd(e){if(!v(e))return null;const t=k(e.id,"").trim(),n=k(e.post_id,"").trim(),s=k(e.author,"").trim();return!t||!s?null:{id:t,post_id:n,author:s,content:k(e.content,""),created_at:Ts(e.created_at)}}async function Kd(e){return Ca("fetchBoardPost",async()=>{const t=await X(`/api/v1/board/${e}?format=flat`),n=v(t.post)?t.post:t,s=qd(n)??{id:e,author:"unknown",post_kind:"human",title:"Post",body:"",content:"",meta:null,tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},i=(Array.isArray(t.comments)?t.comments:[]).map(Fd).filter(l=>l!==null);return{...s,comments:i}})}function qr(e,t){return we("/api/v1/tools/masc_board_vote",{post_id:e,direction:t,vote:t,voter:rd()})}function Bd(e,t,n){return we("/api/v1/tools/masc_board_comment",{post_id:e,author:t,content:n})}function Ud(e){const t=k(e,"").trim().toLowerCase();if(t==="win"||t==="won"||t==="victory")return"victory";if(t==="lose"||t==="lost"||t==="defeat")return"defeat";if(t==="draw"||t==="stalemate"||t==="tie")return"draw"}function ce(...e){for(const t of e){const n=k(t,"");if(n.trim())return n.trim()}return""}function Ni(e){const t=Ud(ce(e.outcome,e.result,e.result_code));if(!t)return;const n=ce(e.reason,e.reason_code,e.description,e.detail),s=ce(e.summary,e.summary_ko,e.summary_en,e.note),a=ce(e.details,e.details_text,e.text,e.note),i=ce(e.winner,e.winner_name,e.actor_winner,e.winner_actor),l=ce(e.winner_actor_id,e.winner_actor,e.actor_winner_id),c=ce(e.raw_reason,e.raw_reason_code,e.error_message),p=(()=>{const _=e.evidence??e.evidence_ids??e.supporting_events??e.event_ids??[];return typeof _=="string"?[_]:Array.isArray(_)?_.map(f=>{if(typeof f=="string")return f.trim();if(v(f)){const h=k(f.summary,"").trim();if(h)return h;const b=k(f.text,"").trim();if(b)return b;const $=k(f.type,"").trim();return $||k(f.event_id,"").trim()}return""}).filter(f=>f.length>0):[]})(),m=(()=>{const _=B(e.turn,Number.NaN);if(Number.isFinite(_))return _;const f=B(e.turn_number,Number.NaN);if(Number.isFinite(f))return f;const h=B(e.current_turn,Number.NaN);if(Number.isFinite(h))return h;const b=B(e.round,Number.NaN);return Number.isFinite(b)?b:void 0})(),u=ce(e.phase,e.phase_name,e.current_phase,e.phase_id);return{result:t,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:l||void 0,evidence:p.length>0?p:void 0,raw_reason:c||void 0,turn:m,phase:u||void 0}}function Hd(e,t){const n=v(e.state)?e.state:{};if(k(n.status,"active").toLowerCase()!=="ended")return;const a=[...t].reverse().find(l=>v(l)?k(l.type,"")==="session.outcome":!1),i=v(n.session_outcome)?n.session_outcome:{};if(v(i)&&Object.keys(i).length>0){const l=Ni(i);if(l)return l}if(v(a))return Ni(v(a.payload)?a.payload:{})}function k(e,t=""){return typeof e=="string"?e:t}function B(e,t=0){return typeof e=="number"&&Number.isFinite(e)?e:t}function me(e){if(typeof e=="number"&&Number.isFinite(e))return Math.trunc(e);if(typeof e=="string"){const t=Number.parseInt(e.trim(),10);if(Number.isFinite(t))return t}}function Bs(e,t=!1){return typeof e=="boolean"?e:t}function Me(e){return Array.isArray(e)?e.map(t=>{if(typeof t=="string")return t.trim();if(v(t)){const n=k(t.name,"").trim(),s=k(t.id,"").trim(),a=k(t.skill,"").trim();return n||s||a}return""}).filter(t=>t.length>0):[]}function Wd(e){const t={};if(!v(e)&&!Array.isArray(e))return t;if(v(e))return Object.entries(e).forEach(([n,s])=>{const a=n.trim(),i=k(s,"").trim();!a||!i||(t[a]=i)}),t;for(const n of e){if(!v(n))continue;const s=ce(n.to,n.target,n.actor_id,n.name,n.id),a=ce(n.relationship,n.relation,n.type,n.kind);!s||!a||(t[s]=a)}return t}function Gd(e,t,n){if(e==="dm"||e==="player"||e==="npc")return e;const s=t.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function ke(e,t,n,s=0){const a=e[t];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=e[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const Jd=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Vd(e){const t=v(e.stats)?e.stats:{},n={};return Object.entries(t).forEach(([s,a])=>{const i=s.trim();i&&(Jd.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function Qd(e,t){if(e!=="dice.rolled")return;const n=B(t.raw_d20,0),s=B(t.total,0),a=B(t.bonus,0),i=k(t.action,"roll"),l=B(t.dc,0);return{notation:l>0?`${i} (DC ${l})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Yd(e){const t=JSON.stringify(e);return t?t.length>160?`${t.slice(0,157)}...`:t:""}function Xd(e){const t=e.trim().toLowerCase();return t?t.startsWith("dice.")?"dice":t.startsWith("combat.")||t.includes(".attack")||t.includes(".damage")?"combat":t.includes("actor.")?"actor":t.includes("turn.")||t==="turn.started"||t==="phase.changed"?"turn":t.includes("join.")?"join":t.includes("memory")?"memory":t.includes("world.")?"world":t.includes("narration")?"story":"meta":"meta"}function Zd(e,t,n,s){const a=n||t||k(s.actor_id,"")||k(s.actor_name,"");switch(e){case"turn.action.proposed":{const i=k(s.proposed_action,k(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=k(s.reply,k(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return k(s.reply,k(s.content,k(s.text,"Narration")));case"dice.rolled":{const i=k(s.action,"roll"),l=B(s.total,0),c=B(s.dc,0),p=k(s.label,""),m=a||"actor",u=c>0?` vs DC ${c}`:"",_=p?` (${p})`:"";return`${m} ${i}: ${l}${u}${_}`}case"turn.started":return`Turn ${B(s.turn,1)} started`;case"phase.changed":return`Phase: ${k(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${k(s.name,v(s.actor)?k(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${k(s.keeper_name,k(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${k(s.keeper_name,k(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${B(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${B(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||k(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||k(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${k(s.reason_code,"unknown")}`;case"memory.signal":{const i=v(s.entity_refs)?s.entity_refs:{},l=k(i.requested_tier,""),c=k(i.effective_tier,""),p=Bs(i.guardrail_applied,!1),m=k(s.summary_en,k(s.summary_ko,"Memory signal"));if(!l&&!c)return m;const u=l&&c?`${l}->${c}`:c||l;return`${m} [${u}${p?" (guardrail)":""}]`}case"world.event":{if(k(s.event_type,"")==="canon.check"){const l=k(s.status,"unknown"),c=k(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return k(s.description,k(s.summary,"World event"))}case"combat.attack":return k(s.summary,k(s.result,"Attack resolved"));case"combat.defense":return k(s.summary,k(s.result,"Defense resolved"));case"session.outcome":return k(s.summary,k(s.outcome,"Session ended"));default:{const i=Yd(s);return i?`${e}: ${i}`:e}}}function eu(e,t){const n=v(e)?e:{},s=k(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=k(n.actor_name,"").trim()||t[a]||k(v(n.payload)?n.payload.actor_name:"",""),l=v(n.payload)?n.payload:{},c=k(n.ts,k(n.timestamp,new Date().toISOString())),p=k(n.phase,k(l.phase,"")),m=k(n.category,"");return{type:s,actor:i||a||k(l.actor_name,""),actor_id:a||k(l.actor_id,""),actor_name:i,seq:n.seq,room_id:k(n.room_id,""),phase:p||void 0,category:m||Xd(s),visibility:k(n.visibility,k(l.visibility,"public")),event_id:k(n.event_id,""),content:Zd(s,a,i,l),dice_roll:Qd(s,l),timestamp:c}}function tu(e,t,n){var Z,oe;const s=k(e.room_id,"")||n||"default",a=v(e.state)?e.state:{},i=v(a.party)?a.party:{},l=v(a.actor_control)?a.actor_control:{},c=v(a.join_gate)?a.join_gate:{},p=v(a.contribution_ledger)?a.contribution_ledger:{},m=Object.entries(i).map(([V,ee])=>{const C=v(ee)?ee:{},Ie=ke(C,"max_hp",void 0,10),We=ke(C,"hp",void 0,Ie),mt=ke(C,"max_mp",void 0,0),vt=ke(C,"mp",void 0,0),K=ke(C,"level",void 0,1),Te=ke(C,"xp",void 0,0),_t=Bs(C.alive,We>0),pn=l[V],mn=typeof pn=="string"?pn:void 0,os=Gd(C.role,V,mn),is=me(C.generation),rs=ce(C.joined_at,C.joinedAt,C.started_at,C.startedAt),ls=ce(C.claimed_at,C.claimedAt,C.assigned_at,C.assignedAt,C.assigned_time),cs=ce(C.last_seen,C.lastSeen,C.last_seen_at,C.lastSeenAt,C.last_active,C.lastActive),ds=ce(C.scene,C.current_scene,C.currentScene,C.world_scene,C.scene_name,C.sceneName),us=ce(C.location,C.current_location,C.currentLocation,C.position,C.zone,C.area);return{id:V,name:k(C.name,V),role:os,keeper:mn,archetype:k(C.archetype,""),persona:k(C.persona,""),portrait:k(C.portrait,"")||void 0,background:k(C.background,"")||void 0,traits:Me(C.traits),skills:Me(C.skills),stats_raw:Vd(C),status:_t?"active":"dead",generation:is,joined_at:rs||void 0,claimed_at:ls||void 0,last_seen:cs||void 0,scene:ds||void 0,location:us||void 0,inventory:Me(C.inventory),notes:Me(C.notes),relationships:Wd(C.relationships),stats:{hp:We,max_hp:Ie,mp:vt,max_mp:mt,level:K,xp:Te,strength:ke(C,"strength","str",10),dexterity:ke(C,"dexterity","dex",10),constitution:ke(C,"constitution","con",10),intelligence:ke(C,"intelligence","int",10),wisdom:ke(C,"wisdom","wis",10),charisma:ke(C,"charisma","cha",10)}}}),u=m.filter(V=>V.status!=="dead"),_=Hd(e,t),f={phase_open:Bs(c.phase_open,!0),min_points:B(c.min_points,3),window:k(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},h=Object.entries(p).map(([V,ee])=>{const C=v(ee)?ee:{};return{actor_id:V,score:B(C.score,0),last_reason:k(C.last_reason,"")||null,reasons:Me(C.reasons)}}),b=m.reduce((V,ee)=>(V[ee.id]=ee.name,V),{}),$=t.map(V=>eu(V,b)),S=B(a.turn,1),A=k(a.phase,"round"),x=k(a.map,""),z=v(a.world)?a.world:{},T=x||k(z.ascii_map,k(z.map,"")),P=$.filter((V,ee)=>{const C=t[ee];if(!v(C))return!1;const Ie=v(C.payload)?C.payload:{};return B(Ie.turn,-1)===S}),M=(P.length>0?P:$).slice(-12),R=k(a.status,"active");return{session:{id:s,room:s,status:R==="ended"?"ended":R==="paused"?"paused":"active",round:S,actors:u,created_at:((Z=$[0])==null?void 0:Z.timestamp)??new Date().toISOString()},current_round:{round_number:S,phase:A,events:M,timestamp:((oe=$[$.length-1])==null?void 0:oe.timestamp)??new Date().toISOString()},map:T||void 0,join_gate:f,contribution_ledger:h,outcome:_,party:u,story_log:$,history:[]}}async function nu(e){const t=`?room_id=${encodeURIComponent(e)}`,n=await X(`/api/v1/trpg/events${t}`);return Array.isArray(n.events)?n.events:[]}async function su(e){const t=`?room_id=${encodeURIComponent(e)}`,[n,s]=await Promise.all([X(`/api/v1/trpg/state${t}`),nu(e)]);return tu(n,s,e)}function au(e){return we("/api/v1/trpg/rounds/run",{room_id:e})}function ou(e){const t="".trim().toLowerCase();if(t)switch(t){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return t}}function iu(e){const t={room_id:e.roomId,actor_id:e.actorId,action:e.action,stat_value:e.statValue,dc:e.dc};return e.rawD20!=null&&(t.raw_d20=e.rawD20),e.ruleModule&&(t.rule_module=e.ruleModule),we("/api/v1/trpg/dice/roll",t)}function ru(e,t){const n=ou();return we("/api/v1/trpg/turns/advance",{room_id:e,...n?{phase:n}:{}})}function lu(e,t){var a;const n=(a=t.idempotencyKey)==null?void 0:a.trim(),s={room_id:e};return t.actor_id&&t.actor_id.trim()&&(s.actor_id=t.actor_id.trim()),t.name&&t.name.trim()&&(s.name=t.name.trim()),t.role&&(s.role=t.role),t.archetype&&t.archetype.trim()&&(s.archetype=t.archetype.trim()),t.persona&&t.persona.trim()&&(s.persona=t.persona.trim()),t.portrait&&t.portrait.trim()&&(s.portrait=t.portrait.trim()),t.background&&t.background.trim()&&(s.background=t.background.trim()),t.hp!=null&&(s.hp=t.hp),t.max_hp!=null&&(s.max_hp=t.max_hp),t.alive!=null&&(s.alive=t.alive),Array.isArray(t.traits)&&t.traits.length>0&&(s.traits=t.traits),Array.isArray(t.skills)&&t.skills.length>0&&(s.skills=t.skills),Array.isArray(t.inventory)&&t.inventory.length>0&&(s.inventory=t.inventory),t.stats&&Object.keys(t.stats).length>0&&(s.stats=t.stats),n&&(s.idempotency_key=n),we("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function cu(e,t,n){return we("/api/v1/trpg/actors/claim",{room_id:e,actor_id:t,keeper:n})}async function du(e,t,n){const s=await ct("trpg.join.eligibility",{room_id:e,actor_id:t,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function uu(e){const t=await ct("trpg.mid_join.request",e);return JSON.parse(t)}async function pu(e,t){await ct("masc_broadcast",{agent_name:e,message:t})}async function mu(e=40){return(await ct("masc_messages",{limit:e})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function vu(e,t=20){return ct("masc_task_history",{task_id:e,limit:t})}async function _u(e){const t=await ct("masc_debate_start",{topic:e});try{return JSON.parse(t)}catch{return null}}async function gu(e){return Ca("fetchDebateStatus",async()=>{const t=encodeURIComponent(e),n=await X(`/api/v1/council/debates/${t}/summary`);if(!v(n))return null;const s=v(n.debate)?n.debate:n,a=k(s.id,"").trim(),i=k(s.topic,"").trim();return!a||!i?null:{debate:{id:a,topic:i,status:k(s.status,"open"),created_at:le(s.created_at_iso??s.created_at),closed_at:le(s.closed_at)},arguments:Array.isArray(n.arguments)?n.arguments.flatMap(l=>v(l)?[{index:B(l.index,0),agent:k(l.agent,"unknown"),position:k(l.position,"neutral"),content:k(l.content,""),evidence:Me(l.evidence),reply_to:me(l.reply_to)??null,mentions:Me(l.mentions),archetype:q(l.archetype),created_at:le(l.created_at)}]:[]):[],summary:{support_count:v(n.summary)?B(n.summary.support_count,0):B(n.support_count,0),oppose_count:v(n.summary)?B(n.summary.oppose_count,0):B(n.oppose_count,0),neutral_count:v(n.summary)?B(n.summary.neutral_count,0):B(n.neutral_count,0),total_arguments:v(n.summary)?B(n.summary.total_arguments,0):B(n.total_arguments,0),summary_text:v(n.summary)?k(n.summary.summary_text,""):k(n.summary_text,"")},context:Jo(n.context),judgment:Or(n.judgment)}})}async function fu(e){return Ca("fetchConsensusSessionSummary",async()=>{const t=encodeURIComponent(e),n=await X(`/api/v1/council/sessions/${t}/summary`);if(!v(n)||!v(n.session))return null;const s=n.session,a=k(s.id,"").trim(),i=k(s.topic,"").trim();return!a||!i?null:{session:{id:a,topic:i,state:k(s.state,"open"),initiator:k(s.initiator,"system"),quorum:B(s.quorum,0),threshold:B(s.threshold,0),created_at:le(s.created_at),closed_at:le(s.closed_at)},votes:Array.isArray(n.votes)?n.votes.flatMap(l=>v(l)?[{agent:k(l.agent,"unknown"),decision:k(l.decision,"abstain"),reason:k(l.reason,""),timestamp:le(l.timestamp),weight:typeof l.weight=="number"?l.weight:void 0,archetype:q(l.archetype)}]:[]):[],summary:{approve_count:v(n.summary)?B(n.summary.approve_count,0):0,reject_count:v(n.summary)?B(n.summary.reject_count,0):0,abstain_count:v(n.summary)?B(n.summary.abstain_count,0):0,quorum_met:v(n.summary)?Bs(n.summary.quorum_met,!1):!1,result:v(n.summary)?q(n.summary.result):null},context:Jo(n.context),judgment:Or(n.judgment)}})}function $u(e,t,n){return ct("masc_keeper_msg",{name:e,message:t})}const hu=g(""),Be=g({}),de=g({}),$o=g({}),ho=g({}),yo=g({}),bo=g({}),Ue=g({});function re(e,t,n){e.value={...e.value,[t]:n}}function yu(e){var n;const t=(n=r(e))==null?void 0:n.toLowerCase();return t==="user"||t==="assistant"||t==="system"||t==="tool"?t:"other"}function bu(e){switch(e){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Da(e,t){if(!Array.isArray(e))return[];const n=[];for(const s of e){if(!v(s))continue;const a=r(s.name);if(!a)continue;const i=r(s[t]);t==="summary"?n.push({name:a,summary:i}):n.push({name:a,reason:i})}return n}function ku(e){if(!v(e))return null;const t=r(e.name);return t?{name:t,trigger:r(e.trigger),outcome:r(e.outcome),summary:r(e.summary),reason:r(e.reason)}:null}function xu(e){const t=e.toLowerCase();return t.includes("graphql")?"graphql_error":t.includes("timeout")||t.includes("model")||t.includes("llm")||t.includes("api key")||t.includes("api_key")||t.includes("provider")?"llm_error":"unknown"}function Su(e,t){return e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":t==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":t==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":t==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Fr(e,t,n){return r(e)??Su(t,n)}function Kr(e,t){return typeof e=="boolean"?e:t==="recover"}function Us(e){if(!v(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);return!t||!n||!s?null:{health_state:t,quiet_reason:r(e.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:ae(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:Kr(e.recoverable,n),summary:Fr(e.summary,t,r(e.quiet_reason)??null),keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function Br(e){return v(e)?{hour:d(e.hour),checked:d(e.checked)??0,acted:d(e.acted)??0,acted_names:H(e.acted_names),activity_report:r(e.activity_report),quiet_hours_overridden:j(e.quiet_hours_overridden),skipped_reason:r(e.skipped_reason),acted_rows:Da(e.acted_rows,"summary").map(t=>({name:t.name,summary:t.summary})),passed_rows:Da(e.passed_rows,"reason").map(t=>({name:t.name,reason:t.reason})),skipped_rows:Da(e.skipped_rows,"reason").map(t=>({name:t.name,reason:t.reason})),checkins:Array.isArray(e.checkins)?e.checkins.map(ku).filter(t=>t!==null):[]}:null}function Au(e){return v(e)?{enabled:j(e.enabled)??!1,interval_s:d(e.interval_s)??0,quiet_start:d(e.quiet_start),quiet_end:d(e.quiet_end),quiet_active:j(e.quiet_active),use_planner:j(e.use_planner),delegate_llm:j(e.delegate_llm),agent_count:d(e.agent_count),agents:H(e.agents),last_tick_ago_s:d(e.last_tick_ago_s)??null,last_tick_ago:r(e.last_tick_ago),total_ticks:d(e.total_ticks),total_checkins:d(e.total_checkins),last_skip_reason:r(e.last_skip_reason)??null,last_tick_result:Br(e.last_tick_result),active_self_heartbeats:H(e.active_self_heartbeats)}:null}function Cu(e){return v(e)?{status:e.status,diagnostic:Us(e.diagnostic)}:null}function Iu(e){return v(e)?{recovered:j(e.recovered)??!1,skipped_reason:r(e.skipped_reason)??null,before:Us(e.before),after:Us(e.after),down:e.down,up:e.up}:null}function Tu(e,t){var x,z;if(!(e!=null&&e.name))return null;const n=r((x=e.agent)==null?void 0:x.status)??r(e.status)??"unknown",s=r((z=e.agent)==null?void 0:z.error)??null,a=e.presence_keepalive??!0,i=e.keepalive_running??!1,l=e.turn_count??0,c=e.last_turn_ago_s??null,p=e.proactive_enabled??!1,m=e.proactive_cooldown_sec??0,u=e.last_proactive_ago_s??null,_=p&&u!=null?Math.max(0,m-u):null,f=l<=0||c==null?"never":c>900?"stale":"fresh",h=typeof e.last_heartbeat=="string"&&e.last_heartbeat.trim()?e.last_heartbeat:null,b=s??(a&&!i?"keeper keepalive is not running":null),$=n==="offline"||n==="inactive"?"offline":b?"degraded":f==="stale"?"stale":f==="never"?"idle":"healthy",S=b?xu(b):t!=null&&t.quiet_active&&f!=="fresh"?"quiet_hours":a&&!i?"disabled":l<=0?"never_started":_!=null&&_>0?"min_gap":f==="fresh"||f==="stale"?"no_recent_activity":"unknown",A=$==="offline"||$==="degraded"||$==="stale"?"recover":S==="quiet_hours"?"manual_lodge_poke":S==="unknown"?"probe":"direct_message";return{health_state:$,quiet_reason:S,next_action_path:A,last_reply_status:f,last_reply_at:h,last_reply_preview:null,last_error:b,next_eligible_at_s:_!=null&&_>0?_:null,recoverable:Kr(void 0,A),summary:Fr(void 0,$,S),keepalive_running:i}}function Ru(e,t){if(!v(e))return null;const n=yu(e.role),s=r(e.content)??r(e.preview);if(!s)return null;const a=ae(e.ts_unix)??ae(e.timestamp);return{id:`${n}-${a??"entry"}-${t}`,role:n,label:bu(n),text:s,timestamp:a,delivery:"history"}}function Pu(e,t,n){const s=v(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((i,l)=>Ru(i,l)).filter(i=>i!==null):[];return{name:e,diagnostic:Us(s==null?void 0:s.diagnostic),history:a,rawText:t,rawStatus:n,loadedAt:new Date().toISOString()}}function Ei(e,t){const n=de.value[e]??[];de.value={...de.value,[e]:[...n,t].slice(-50)}}function Lu(e,t){return e.role!==t.role||e.text!==t.text?!1:e.timestamp&&t.timestamp?e.timestamp===t.timestamp:!0}function zu(e,t){const s=(de.value[e]??[]).filter(a=>a.delivery!=="history"&&!t.some(i=>Lu(a,i)));de.value={...de.value,[e]:[...t,...s].slice(-50)}}function Ta(e,t){Be.value={...Be.value,[e]:t},zu(e,t.history)}function ji(e,t){const n=Be.value[e];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ta(e,{...n,diagnostic:{...s,...t}})}async function Vo(){try{await Yn()}catch(e){console.warn("[keeper-runtime] dashboard refresh failed",e)}}function Mu(e){hu.value=e.trim()}async function Ur(e,t=!1){const n=e.trim();if(!n)return null;if(!t&&Be.value[n])return Be.value[n];re($o,n,!0),re(Ue,n,null);try{const s=await ct("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const i=Pu(n,s,a);return Ta(n,i),i}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return re(Ue,n,a),null}finally{re($o,n,!1)}}async function Nu(e,t){const n=e.trim(),s=t.trim();if(!n||!s)return;const a=`local-${Date.now()}`;Ei(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),re(ho,n,!0),re(Ue,n,null);try{const i=await $u(n,s);de.value={...de.value,[n]:(de.value[n]??[]).map(l=>l.id===a?{...l,delivery:"delivered"}:l)},Ei(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),ji(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await Vo()}catch(i){const l=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw de.value={...de.value,[n]:(de.value[n]??[]).map(c=>c.id===a?{...c,delivery:"error",error:l}:c)},ji(n,{last_reply_status:"error",last_error:l}),re(Ue,n,l),i}finally{re(ho,n,!1)}}async function Eu(e,t){const n=e.trim();if(!n)return null;re(yo,n,!0),re(Ue,n,null);try{const s=await Ia({actor:t,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=Cu(s.result),i=(a==null?void 0:a.diagnostic)??null;if(i){const l=Be.value[n];Ta(n,{name:n,diagnostic:i,history:(l==null?void 0:l.history)??de.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Vo(),i}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw re(Ue,n,a),s}finally{re(yo,n,!1)}}async function ju(e,t){const n=e.trim();if(!n)return null;re(bo,n,!0),re(Ue,n,null);try{const s=await Ia({actor:t,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Iu(s.result),i=(a==null?void 0:a.after)??null;if(i){const l=Be.value[n];Ta(n,{name:n,diagnostic:i,history:(l==null?void 0:l.history)??de.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Vo(),i}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw re(Ue,n,a),s}finally{re(bo,n,!1)}}function gt(e){return(e??"").trim().toLowerCase()}function ge(e){const t=typeof e=="number"?e:Date.parse(e);return Number.isNaN(t)?0:t}function Rs(e,t=88){const n=e.replace(/\s+/g," ").trim();return n&&(n.length>t?`${n.slice(0,t-3)}...`:n)}function ms(e){return typeof e!="number"||!Number.isFinite(e)||e<0?null:new Date(Date.now()-e*1e3).toISOString()}function vn(e){return e.last_heartbeat??ms(e.last_turn_ago_s)??ms(e.last_proactive_ago_s)??ms(e.last_handoff_ago_s)??ms(e.last_compaction_ago_s)}function wu(e){const t=e.title.trim();return t||Rs(e.content)}function Du(e){const t=e.generation??"?",n=typeof e.context_ratio=="number"&&Number.isFinite(e.context_ratio)?`${Math.round(e.context_ratio*100)}%`:"?";return e.last_heartbeat?`Heartbeat gen=${t} ctx=${n}`:`Keeper snapshot gen=${t} ctx=${n}`}function Ou(e,t,n,s,a={}){var z;const i=gt(e),l=t.filter(T=>gt(T.assignee)===i&&(T.status==="claimed"||T.status==="in_progress")).length,c=n.filter(T=>gt(T.from)===i).sort((T,P)=>ge(P.timestamp)-ge(T.timestamp))[0],p=s.filter(T=>gt(T.agent)===i||gt(T.author)===i).sort((T,P)=>ge(P.timestamp)-ge(T.timestamp))[0],m=(a.boardPosts??[]).filter(T=>gt(T.author)===i).sort((T,P)=>ge(P.updated_at||P.created_at)-ge(T.updated_at||T.created_at))[0],u=(a.keepers??[]).filter(T=>gt(T.name)===i&&vn(T)!==null).sort((T,P)=>ge(vn(P)??0)-ge(vn(T)??0))[0],_=c?ge(c.timestamp):0,f=p?ge(p.timestamp):0,h=m?ge(m.updated_at||m.created_at):0,b=u?ge(vn(u)??0):0,$=a.lastSeen?ge(a.lastSeen):0,S=((z=a.currentTask)==null?void 0:z.trim())||(l>0?`${l} claimed tasks`:null);if(_===0&&f===0&&h===0&&b===0&&$===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:S};const x=[c?{timestamp:c.timestamp,ts:_,text:Rs(c.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:h,text:`Post: ${Rs(wu(m))}`}:null,u?{timestamp:vn(u),ts:b,text:Du(u)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:f,text:Rs(p.text)}:null].filter(T=>T!==null).sort((T,P)=>P.ts-T.ts)[0];return x&&x.ts>=$?{activeAssignedCount:l,lastActivityAt:x.timestamp,lastActivityText:x.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:S??"Presence heartbeat"}}const He=g([]),Xe=g([]),ko=g([]),dt=g([]),te=g(null),qu=g(null),Hr=g(null),Wr=g([]),Gr=g([]),Jr=g([]),Vr=g([]),Qr=g([]),Yr=g([]),xo=g(new Map),Ra=g([]),Ln=g("recent"),bt=g(!0),Xr=g(null),Ke=g(""),Ht=g([]),yn=g(!1),Zr=g(new Map),Qo=g("unknown"),Wt=g(null),So=g(!1),zn=g(!1),Ao=g(!1),bn=g(!1),Yo=g(null),Hs=g(!1),Ws=g(null),el=g(null),Co=g(null),Fu=g(null),Ku=g(null),Bu=g(null);Ce(()=>He.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle"));const tl=Ce(()=>{const e=Xe.value;return{todo:e.filter(t=>t.status==="todo"),inProgress:e.filter(t=>t.status==="in_progress"||t.status==="claimed"),done:e.filter(t=>t.status==="done")}}),nl=Ce(()=>{const e=new Map,t=Xe.value,n=ko.value,s=Ks.value,a=Ra.value,i=dt.value;for(const l of He.value)e.set(l.name.trim().toLowerCase(),Ou(l.name,t,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:i}));return e});function Uu(e){var i;const t=((i=e.status)==null?void 0:i.toLowerCase())??"";if(t==="offline"||t==="inactive")return"offline";const n=e.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}Ce(()=>{const e=new Map;for(const t of dt.value)e.set(t.name,Uu(t));return e});const Hu=12e4;function Wu(e,t){const n=t.get(e.name);if(n!=null)return n;const s=e.last_heartbeat?Date.parse(e.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[e.last_turn_ago_s,e.last_proactive_ago_s,e.last_handoff_ago_s,e.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof a=="number"?Date.now()-a*1e3:null}Ce(()=>{const e=Date.now(),t=new Set,n=xo.value;for(const s of dt.value){const a=Wu(s,n);a!=null&&e-a>Hu&&t.add(s.name)}return t});function Gu(e){return e==="dashboard_refresh"||e==="masc/dashboard_refresh"||e.startsWith("goal_")||e.startsWith("masc/goal_")||e.startsWith("mdal_")||e.startsWith("masc/mdal_")||e.startsWith("operator_")||e.startsWith("masc/operator_")||e.startsWith("command_plane_")||e.startsWith("masc/command_plane_")}function sl(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="active"||t==="busy"||t==="listening"||t==="idle"||t==="inactive"||t==="offline"?t:t==="in_progress"||t==="claimed"?"busy":"offline"}function Ju(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="todo"||t==="in_progress"||t==="claimed"||t==="done"||t==="cancelled"?t:t==="inprogress"?"in_progress":"todo"}function Vu(e){if(!v(e))return null;const t=r(e.name);return t?{name:t,agent_type:r(e.agent_type),status:sl(e.status),current_task:r(e.current_task)??null,joined_at:r(e.joined_at),last_seen:r(e.last_seen),capabilities:H(e.capabilities),emoji:r(e.emoji),koreanName:r(e.koreanName)??r(e.korean_name),model:r(e.model),traits:H(e.traits),interests:H(e.interests),activityLevel:d(e.activityLevel)??d(e.activity_level),primaryValue:r(e.primaryValue)??r(e.primary_value)}:null}function Qu(e){if(!v(e))return null;const t=r(e.id),n=r(e.title);return!t||!n?null:{id:t,title:n,status:Ju(e.status),priority:d(e.priority),assignee:r(e.assignee),description:r(e.description),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function Yu(e){if(!v(e))return null;const t=r(e.from)??r(e.from_agent)??"system",n=r(e.content)??"",s=r(e.timestamp)??new Date().toISOString();return{id:r(e.id),seq:d(e.seq),from:t,content:n,timestamp:s,type:r(e.type)}}function Xo(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="ok"||t==="warn"||t==="bad"?t:"ok"}function Xu(e){return v(e)?{active_sessions:d(e.active_sessions),blocked_sessions:d(e.blocked_sessions),active_operations:d(e.active_operations),blocked_operations:d(e.blocked_operations),runtime_pressure:d(e.runtime_pressure),worker_alerts:d(e.worker_alerts),continuity_alerts:d(e.continuity_alerts),priority_items:d(e.priority_items),todo_tasks:d(e.todo_tasks),claimed_tasks:d(e.claimed_tasks),running_tasks:d(e.running_tasks),done_tasks:d(e.done_tasks),cancelled_tasks:d(e.cancelled_tasks),keepers:d(e.keepers)}:null}function Ze(e){if(!v(e))return null;const t=r(e.surface),n=r(e.label),s=r(e.target_type),a=r(e.target_id),i=r(e.focus_kind);return!t||!n||!s||!a||!i?null:{surface:t==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:i,operation_id:r(e.operation_id)??null,command_surface:r(e.command_surface)??null}}function Zu(e){if(!v(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.summary),a=r(e.target_type),i=r(e.target_id);return!t||!s||!a||!i||n!=="session"&&n!=="operation"?null:{id:t,kind:n,severity:Xo(e.severity),status:r(e.status),summary:s,target_type:a,target_id:i,linked_session_id:r(e.linked_session_id)??null,linked_operation_id:r(e.linked_operation_id)??null,last_seen_at:r(e.last_seen_at)??null,top_handoff:Ze(e.top_handoff),intervene_handoff:Ze(e.intervene_handoff),command_handoff:Ze(e.command_handoff)}}function ep(e){if(!v(e))return null;const t=r(e.session_id),n=r(e.goal);return!t||!n?null:{session_id:t,goal:n,room:r(e.room)??null,status:r(e.status),health:r(e.health),member_names:H(e.member_names),linked_operation_id:r(e.linked_operation_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,runtime_blocker:r(e.runtime_blocker)??null,worker_gap_summary:r(e.worker_gap_summary)??null,last_activity_at:r(e.last_activity_at)??null,last_activity_summary:r(e.last_activity_summary)??null,communication_summary:r(e.communication_summary)??null,active_count:d(e.active_count),required_count:d(e.required_count),top_handoff:Ze(e.top_handoff),intervene_handoff:Ze(e.intervene_handoff),command_handoff:Ze(e.command_handoff)}}function tp(e){if(!v(e))return null;const t=r(e.operation_id),n=r(e.objective);return!t||!n?null:{operation_id:t,objective:n,status:r(e.status),stage:r(e.stage)??null,assigned_unit_id:r(e.assigned_unit_id)??null,assigned_unit_label:r(e.assigned_unit_label)??null,linked_session_id:r(e.linked_session_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,blocker_summary:r(e.blocker_summary)??null,search_status:r(e.search_status)??null,next_tool:r(e.next_tool)??null,updated_at:r(e.updated_at)??null,top_handoff:Ze(e.top_handoff),command_handoff:Ze(e.command_handoff)}}function wi(e){if(!v(e))return null;const t=r(e.name)??r(e.agent_name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline"?null:{name:t,agent_name:r(e.agent_name),status:r(e.status),tone:Xo(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,active_task_count:d(e.active_task_count),related_session_id:r(e.related_session_id)??null,related_operation_id:r(e.related_operation_id)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),model:r(e.model)??null,recent_output_preview:r(e.recent_output_preview)??null,recent_event:r(e.recent_event)??null}}function np(e){if(!v(e))return null;const t=r(e.name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:t,agent_name:r(e.agent_name)??null,status:r(e.status),tone:Xo(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,last_autonomous_action_at:r(e.last_autonomous_action_at)??null,generation:d(e.generation),turn_count:d(e.turn_count),context_ratio:d(e.context_ratio)??null,continuity:r(e.continuity)??null,lifecycle:r(e.lifecycle)??null,related_session_id:r(e.related_session_id)??null,model:r(e.model)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),skill_reason:r(e.skill_reason)??null}}function Di(e){if(typeof e.seq=="number"&&Number.isFinite(e.seq))return e.seq;const t=Date.parse(e.timestamp);return Number.isNaN(t)?0:t}function sp(e,t){if(t.length===0)return e;const n=new Map;for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>Di(s)-Di(a)).slice(-500)}function ap(e){return Array.isArray(e)?e.map(t=>{if(!v(t))return null;const n=d(t.ts_unix);if(n==null)return null;const s=v(t.handoff)?t.handoff:null;return{ts:n,context_ratio:d(t.context_ratio)??0,context_tokens:d(t.context_tokens)??0,context_max:d(t.context_max)??0,latency_ms:d(t.latency_ms)??0,generation:d(t.generation)??0,channel:typeof t.channel=="string"?t.channel:"turn",is_handoff:s!=null&&t.handoff_performed===!0,is_compaction:t.compacted===!0,compaction_saved_tokens:d(t.compaction_saved_tokens)??0,compaction_trigger:typeof t.compaction_trigger=="string"?t.compaction_trigger:null,model_used:typeof t.model_used=="string"?t.model_used:"",cost_usd:d(t.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?d(s.new_generation)??null:null}}).filter(t=>t!==null):[]}function Oi(e){if(!v(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);if(!t||!n||!s)return null;const a=r(e.quiet_reason)??null,i=r(e.summary)??(t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:t,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:ae(e.last_reply_at)??r(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:typeof e.recoverable=="boolean"?e.recoverable:n==="recover",summary:i,keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function op(e,t){return(Array.isArray(e)?e:v(e)&&Array.isArray(e.keepers)?e.keepers:[]).map(s=>{if(!v(s))return null;const a=v(s.agent)?s.agent:null,i=v(s.context)?s.context:null,l=v(s.metrics_window)?s.metrics_window:void 0,c=r(s.name);if(!c)return null;const p=d(s.context_ratio)??d(i==null?void 0:i.context_ratio),m=r(s.status)??r(a==null?void 0:a.status)??"offline",u=sl(m),_=r(s.model)??r(s.active_model)??r(s.primary_model),f=H(s.skill_secondary),h=i?{source:r(i.source),context_ratio:d(i.context_ratio),context_tokens:d(i.context_tokens),context_max:d(i.context_max),message_count:d(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,b=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:d(a.last_seen_ago_s),capabilities:H(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,$=ap(s.metrics_series),S={name:c,runtime_class:s.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:typeof s.desired=="boolean"?s.desired:void 0,resident_registered:typeof s.resident_registered=="boolean"?s.resident_registered:void 0,reconcile_status:r(s.reconcile_status)??null,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:_,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:u,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:d(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:d(s.proactive_idle_sec),proactive_cooldown_sec:d(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:d(s.generation),turn_count:d(s.turn_count)??d(s.total_turns),keeper_age_s:d(s.keeper_age_s),last_turn_ago_s:d(s.last_turn_ago_s),last_handoff_ago_s:d(s.last_handoff_ago_s),last_compaction_ago_s:d(s.last_compaction_ago_s),last_proactive_ago_s:d(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:p,context_tokens:d(s.context_tokens)??d(i==null?void 0:i.context_tokens),context_max:d(s.context_max)??d(i==null?void 0:i.context_max),context_source:r(s.context_source)??r(i==null?void 0:i.source),context:h,traits:H(s.traits),interests:H(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:d(s.activityLevel)??d(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:H(s.recent_tool_names)??[],conversation_tail_count:d(s.conversation_tail_count),k2k_count:d(s.k2k_count),handoff_count_total:d(s.handoff_count_total)??d(s.trace_history_count),compaction_count:d(s.compaction_count),last_compaction_saved_tokens:d(s.last_compaction_saved_tokens),diagnostic:Oi(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:f,skill_reason:r(s.skill_reason)??null,metrics_series:$.length>0?$:void 0,metrics_window:l,agent:b};return S.diagnostic=Oi(s.diagnostic)??Tu(S,(t==null?void 0:t.lodge)??null),S}).filter(s=>s!==null)}function ip(e){if(!v(e))return;const t=r(e.release_version),n=ae(e.started_at),s=d(e.uptime_seconds);if(!(!t||!n||s==null))return{release_version:t,commit:r(e.commit)??null,started_at:n,uptime_seconds:s}}function rp(e){if(v(e))return{enabled:e.enabled===!0,alive:e.alive===!0,status:r(e.status)??void 0,tick_in_progress:typeof e.tick_in_progress=="boolean"?e.tick_in_progress:void 0,tick_count:d(e.tick_count)??void 0,check_interval_sec:d(e.check_interval_sec)??void 0,last_tick_started_at:ae(e.last_tick_started_at)??r(e.last_tick_started_at)??null,last_tick_completed_at:ae(e.last_tick_completed_at)??r(e.last_tick_completed_at)??null,next_tick_due_at:ae(e.next_tick_due_at)??r(e.next_tick_due_at)??null,last_health_check_at:ae(e.last_health_check_at)??r(e.last_health_check_at)??null,last_intervention:r(e.last_intervention)??void 0,last_decision_source:r(e.last_decision_source)??void 0,last_action:r(e.last_action)??void 0,last_target:r(e.last_target)??null,last_reason:r(e.last_reason)??null,last_error:r(e.last_error)??null,circuit_open:typeof e.circuit_open=="boolean"?e.circuit_open:void 0,circuit_open_until:ae(e.circuit_open_until)??r(e.circuit_open_until)??null,can_spawn:typeof e.can_spawn=="boolean"?e.can_spawn:void 0,can_retire:typeof e.can_retire=="boolean"?e.can_retire:void 0,last_spawn_attempt_at:ae(e.last_spawn_attempt_at)??r(e.last_spawn_attempt_at)??null,last_retirement_attempt_at:ae(e.last_retirement_attempt_at)??r(e.last_retirement_attempt_at)??null,spawns_today:d(e.spawns_today)??void 0,retirements_today:d(e.retirements_today)??void 0,health_summary:v(e.health_summary)?{total_agents:d(e.health_summary.total_agents)??void 0,active_agents:d(e.health_summary.active_agents)??void 0,idle_agents:d(e.health_summary.idle_agents)??void 0,todo_count:d(e.health_summary.todo_count)??void 0,high_priority_todo:d(e.health_summary.high_priority_todo)??void 0,orphan_count:d(e.health_summary.orphan_count)??void 0,homeostatic_score:d(e.health_summary.homeostatic_score)??void 0,needs_workers:typeof e.health_summary.needs_workers=="boolean"?e.health_summary.needs_workers:void 0}:void 0}}function lp(e){if(v(e))return{enabled:e.enabled===!0,mode:r(e.mode)??void 0,masc_enabled:typeof e.masc_enabled=="boolean"?e.masc_enabled:void 0,masc_loops_running:typeof e.masc_loops_running=="boolean"?e.masc_loops_running:void 0,runtime_owner:r(e.runtime_owner)??null,zombie_loop_running:typeof e.zombie_loop_running=="boolean"?e.zombie_loop_running:void 0,gc_loop_running:typeof e.gc_loop_running=="boolean"?e.gc_loop_running:void 0,lodge_enabled:typeof e.lodge_enabled=="boolean"?e.lodge_enabled:void 0,lodge_loop_started:typeof e.lodge_loop_started=="boolean"?e.lodge_loop_started:void 0,lodge_running:typeof e.lodge_running=="boolean"?e.lodge_running:void 0,last_zombie_cleanup:ae(e.last_zombie_cleanup)??r(e.last_zombie_cleanup)??null,last_gc:ae(e.last_gc)??r(e.last_gc)??null,last_lodge:ae(e.last_lodge)??r(e.last_lodge)??null,last_zombie_result:r(e.last_zombie_result)??null,last_gc_result:r(e.last_gc_result)??null,last_lodge_result:v(e.last_lodge_result)?{ok:typeof e.last_lodge_result.ok=="boolean"?e.last_lodge_result.ok:void 0,message:r(e.last_lodge_result.message)??void 0}:null}}function cp(e){if(v(e))return{enabled:e.enabled===!0,started:e.started===!0,agent_name:r(e.agent_name)??null,llm_enabled:typeof e.llm_enabled=="boolean"?e.llm_enabled:void 0,uptime_s:d(e.uptime_s)??void 0,embedded_guardian_loops_running:typeof e.embedded_guardian_loops_running=="boolean"?e.embedded_guardian_loops_running:void 0,guardian_runtime_owner:r(e.guardian_runtime_owner)??null,consumers:H(e.consumers)}}function al(e,t){return v(e)?{...e,generated_at:t??ae(e.generated_at)??void 0,build:ip(e.build),lodge:Au(e.lodge)??void 0,gardener:rp(e.gardener)??void 0,guardian:lp(e.guardian)??void 0,sentinel:cp(e.sentinel)??void 0}:null}function ol(e,t){return t?e?{...e,...t,build:t.build??e.build,generated_at:t.generated_at??e.generated_at}:t:e}function dp(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="running"||t==="interrupted"||t==="completed"||t==="stopped"||t==="error"?t:t.startsWith("error")?"error":"running"}function up(e){if(!v(e))return null;const t=d(e.iteration);if(t==null)return null;const n=d(e.metric_before)??0,s=d(e.metric_after)??n,a=v(e.evidence)?e.evidence:null;return{iteration:t,metric_before:n,metric_after:s,delta:d(e.delta)??s-n,changes:r(e.changes)??"",failed_attempts:r(e.failed_attempts)??"",next_suggestion:r(e.next_suggestion)??"",elapsed_ms:d(e.elapsed_ms)??0,cost_usd:d(e.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:d(a.tool_call_count)??0,tool_names:H(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function pp(e){var i,l;if(!v(e))return null;const t=r(e.loop_id);if(!t)return null;const n=d(e.baseline_metric)??0,s=Array.isArray(e.history)?e.history.map(up).filter(c=>c!==null):[],a=d(e.current_metric)??((i=s[0])==null?void 0:i.metric_after)??n;return{loop_id:t,profile:r(e.profile)??"unknown",status:dp(e.status),strict_mode:typeof e.strict_mode=="boolean"?e.strict_mode:void 0,error_message:r(e.error_message)??r(e.error_reason)??null,stop_reason:r(e.stop_reason)??r(e.reason)??null,current_iteration:d(e.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:d(e.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(e.target)??"",stagnation_streak:d(e.stagnation_streak)??0,stagnation_limit:d(e.stagnation_limit)??0,elapsed_seconds:d(e.elapsed_seconds)??0,updated_at:ae(e.updated_at)??null,stopped_at:ae(e.stopped_at)??null,execution_mode:e.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:e.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(e.worker_model)??null,evidence_policy:e.evidence_policy==="hard"||e.evidence_policy==="legacy"?e.evidence_policy:void 0,latest_tool_call_count:d(e.latest_tool_call_count)??0,latest_tool_names:H(e.latest_tool_names)??[],session_id:r(e.session_id)??null,evidence_status:e.evidence_status==="legacy_unverified"?"legacy_unverified":e.evidence_status==="verified"?"verified":null,durability:e.durability==="persistent_backend"||e.durability==="memory_only"?e.durability:void 0,persistence_backend:e.persistence_backend==="filesystem"||e.persistence_backend==="postgres"||e.persistence_backend==="memory"?e.persistence_backend:void 0,recoverable:typeof e.recoverable=="boolean"?e.recoverable:void 0,history:s}}async function Yn(){So.value=!0;try{await Promise.all([rl(),kt()]),el.value=new Date().toISOString()}catch(e){console.error("Dashboard refresh error:",e)}finally{So.value=!1}}async function il(){Hs.value=!0,Ws.value=null;try{const e=await $d();Yo.value=e,Bu.value=new Date().toISOString()}catch(e){Ws.value=e instanceof Error?e.message:"Failed to load dashboard semantics"}finally{Hs.value=!1}}function mp(e){var t;return((t=Yo.value)==null?void 0:t.surfaces.find(n=>n.id===e))??null}function vp(e){var n;const t=((n=Yo.value)==null?void 0:n.surfaces)??[];for(const s of t){const a=s.panels.find(i=>i.id===e);if(a)return a}return null}function _p(e){var s,a;Ht.value=(Array.isArray(e.goals)?e.goals:[]).map(i=>{if(!v(i))return null;const l=r(i.id),c=r(i.title),p=r(i.horizon),m=r(i.status),u=r(i.created_at),_=r(i.updated_at);return!l||!c||!p||!m||!u||!_?null:{id:l,horizon:p,title:c,metric:r(i.metric)??null,target_value:r(i.target_value)??null,due_date:r(i.due_date)??null,priority:d(i.priority)??3,status:m,parent_goal_id:r(i.parent_goal_id)??null,last_review_note:r(i.last_review_note)??null,last_review_at:r(i.last_review_at)??null,created_at:u,updated_at:_}}).filter(i=>i!==null);const t=new Map,n=Array.isArray((s=e.mdal)==null?void 0:s.loops)?e.mdal.loops:[];for(const i of n){const l=pp(i);l&&t.set(l.loop_id,l)}Zr.value=t,Wt.value=typeof((a=e.mdal)==null?void 0:a.error)=="string"?e.mdal.error:null,Qo.value=Wt.value?"error":t.size===0?"idle":"ready"}async function rl(){try{const e=await vd(),t=al(e.status,e.generated_at);t&&(te.value=ol(te.value,t))}catch(e){console.error("Dashboard shell fetch error:",e)}}async function kt(){var e;try{const t=await _d(),n=al(t.status,t.generated_at),s=(e=te.value)==null?void 0:e.room;n&&(te.value=ol(te.value,n));const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;He.value=(Array.isArray(t.agents)?t.agents:[]).map(Vu).filter(l=>l!==null),Xe.value=(Array.isArray(t.tasks)?t.tasks:[]).map(Qu).filter(l=>l!==null);const i=(Array.isArray(t.messages)?t.messages:[]).map(Yu).filter(l=>l!==null);ko.value=a?i:sp(ko.value,i),dt.value=op(t.keepers,n??te.value),Hr.value=Xu(t.summary),Wr.value=(Array.isArray(t.execution_queue)?t.execution_queue:Array.isArray(t.priority_queue)?t.priority_queue:[]).map(Zu).filter(l=>l!==null),Gr.value=(Array.isArray(t.session_briefs)?t.session_briefs:[]).map(ep).filter(l=>l!==null),Jr.value=(Array.isArray(t.operation_briefs)?t.operation_briefs:[]).map(tp).filter(l=>l!==null),Vr.value=(Array.isArray(t.worker_support_briefs)?t.worker_support_briefs:Array.isArray(t.worker_briefs)?t.worker_briefs:[]).map(wi).filter(l=>l!==null),Qr.value=(Array.isArray(t.continuity_briefs)?t.continuity_briefs:[]).map(np).filter(l=>l!==null),Yr.value=(Array.isArray(t.offline_worker_briefs)?t.offline_worker_briefs:[]).map(wi).filter(l=>l!==null),qu.value=null,el.value=new Date().toISOString()}catch(t){console.error("Dashboard execution fetch error:",t)}}async function et(){zn.value=!0;try{const e=await gd(Ln.value,{excludeSystem:bt.value});Ra.value=e.posts??[],Co.value=new Date().toISOString()}catch(e){console.error("Board fetch error:",e)}finally{zn.value=!1}}async function tt(){var e;Ao.value=!0;try{const t=Ke.value||((e=te.value)==null?void 0:e.room)||"default";Ke.value||(Ke.value=t);const n=await su(t);Xr.value=n}catch(t){console.error("TRPG fetch error:",t)}finally{Ao.value=!1}}async function Zo(){yn.value=!0,bn.value=!0;try{const e=await xd();_p(e),Fu.value=new Date().toISOString(),Ku.value=new Date().toISOString()}catch(e){console.error("Planning fetch error:",e),Qo.value="error",Wt.value=e instanceof Error?e.message:String(e)}finally{yn.value=!1,bn.value=!1}}async function ll(){return Zo()}let Ps=null;function gp(e){Ps=e}let Ls=null;function fp(e){Ls=e}let zs=null;function $p(e){zs=e}const xt={};let Oa=null;function ft(e,t,n=500){xt[e]&&clearTimeout(xt[e]),xt[e]=setTimeout(()=>{t(),delete xt[e]},n)}function hp(){const e=Ir.subscribe(t=>{if(t){if(t.type==="keeper_heartbeat"&&t.name){const n=new Map(xo.value);n.set(t.name,t.ts_unix?t.ts_unix*1e3:Date.now()),xo.value=n;return}(t.type==="agent_joined"||t.type==="agent_left")&&ft("execution",kt),Gu(t.type)&&(Oa||(Oa=setTimeout(()=>{Yn(),Ls==null||Ls(),zs==null||zs(),Oa=null},500))),(t.type.startsWith("task_")||t.type.startsWith("masc/task_"))&&ft("execution",kt),t.type==="broadcast"&&ft("execution",kt),(t.type==="keeper_handoff"||t.type==="keeper_compaction"||t.type==="keeper_guardrail")&&ft("execution",kt),(t.type==="board_post"||t.type==="masc/board_post"||t.type==="board_comment"||t.type==="masc/board_comment")&&ft("board",et),t.type.startsWith("decision_")&&ft("council",()=>Ps==null?void 0:Ps()),(t.type==="mdal_started"||t.type==="mdal_iteration"||t.type==="mdal_completed"||t.type==="mdal_stopped")&&ft("mdal",ll,350)}});return()=>{e();for(const t of Object.keys(xt))clearTimeout(xt[t]),delete xt[t]}}let kn=null;function yp(){kn||(kn=setInterval(()=>{ot.value,Yn()},1e4))}function bp(){kn&&(clearInterval(kn),kn=null)}const _e=g(null),ei=g(null),je=g(null),Mn=g(!1),it=g(null),Nn=g(!1),nn=g(null),W=g(!1),Gs=g([]);let kp=1;function xp(e){return v(e)?{id:r(e.id),seq:d(e.seq),from:r(e.from)??r(e.from_agent)??"system",content:r(e.content)??"",timestamp:r(e.timestamp)??new Date().toISOString(),type:r(e.type)}:null}function Sp(e){return v(e)?{room_id:r(e.room_id),current_room:r(e.current_room)??r(e.room),project:r(e.project),cluster:r(e.cluster),paused:j(e.paused),pause_reason:r(e.pause_reason)??null,paused_by:r(e.paused_by)??null,paused_at:r(e.paused_at)??null}:{}}function qi(e){if(!v(e))return;const t=Object.entries(e).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return t.length>0?Object.fromEntries(t):void 0}function cl(e){if(!v(e))return null;const t=r(e.kind),n=r(e.summary),s=r(e.target_type);return!t||!n||!s?null:{kind:t,severity:r(e.severity)??"warn",summary:n,target_type:s,target_id:r(e.target_id)??null,actor:r(e.actor)??null,evidence:e.evidence}}function xn(e){if(!v(e))return null;const t=r(e.action_type),n=r(e.target_type),s=r(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:r(e.target_id)??null,severity:r(e.severity)??"warn",reason:s,confirm_required:j(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function dl(e){return v(e)?{enabled:j(e.enabled),judge_online:j(e.judge_online),refreshing:j(e.refreshing),generated_at:r(e.generated_at)??null,expires_at:r(e.expires_at)??null,model_used:r(e.model_used)??null,keeper_name:r(e.keeper_name)??null,last_error:r(e.last_error)??null}:null}function qa(e){return v(e)?{summary:r(e.summary)??null,confidence:d(e.confidence)??null,provenance:r(e.provenance)??null,authoritative:j(e.authoritative),surface:r(e.surface)??null,fresh_until:r(e.fresh_until)??null,keeper_name:r(e.keeper_name)??null,fallback_used:j(e.fallback_used),disagreement_with_truth:j(e.disagreement_with_truth)}:null}function Ap(e){return v(e)?{judgment_id:r(e.judgment_id)??void 0,surface:r(e.surface)??null,target_type:r(e.target_type)??null,target_id:r(e.target_id)??null,status:r(e.status)??null,summary:r(e.summary)??null,confidence:d(e.confidence)??null,generated_at:r(e.generated_at)??null,fresh_until:r(e.fresh_until)??null,keeper_name:r(e.keeper_name)??null,model_name:r(e.model_name)??null,runtime_name:r(e.runtime_name)??null,evidence_refs:H(e.evidence_refs),recommended_action:xn(e.recommended_action),supersedes:H(e.supersedes),fallback_used:j(e.fallback_used),disagreement_with_truth:j(e.disagreement_with_truth),provenance:r(e.provenance)??null}:null}function Cp(e){return v(e)?{actor:r(e.actor)??null,spawn_agent:r(e.spawn_agent)??null,spawn_role:r(e.spawn_role)??null,spawn_model:r(e.spawn_model)??null,worker_class:r(e.worker_class)??null,parent_actor:r(e.parent_actor)??null,capsule_mode:r(e.capsule_mode)??null,runtime_pool:r(e.runtime_pool)??null,lane_id:r(e.lane_id)??null,controller_level:r(e.controller_level)??null,control_domain:r(e.control_domain)??null,supervisor_actor:r(e.supervisor_actor)??null,model_tier:r(e.model_tier)??null,task_profile:r(e.task_profile)??null,risk_level:r(e.risk_level)??null,routing_confidence:d(e.routing_confidence)??null,routing_reason:r(e.routing_reason)??null,status:r(e.status)??"unknown",turn_count:d(e.turn_count)??0,empty_note_turn_count:d(e.empty_note_turn_count)??0,has_turn:j(e.has_turn)??!1,last_turn_ts_iso:r(e.last_turn_ts_iso)??null}:null}function Ip(e){if(!v(e))return null;const t=r(e.session_id);return t?{session_id:t,goal:r(e.goal),status:r(e.status),health:r(e.health),scale_profile:r(e.scale_profile),control_profile:r(e.control_profile),planned_worker_count:d(e.planned_worker_count),active_agent_count:d(e.active_agent_count),last_turn_age_sec:d(e.last_turn_age_sec)??null,attention_count:d(e.attention_count),recommended_action_count:d(e.recommended_action_count),top_attention:cl(e.top_attention),top_recommendation:xn(e.top_recommendation)}:null}function ul(e){const t=v(e)?e:{};return{trace_id:r(t.trace_id),target_type:r(t.target_type)??"room",target_id:r(t.target_id)??null,health:r(t.health),judgment_owner:r(t.judgment_owner)??null,authoritative_judgment_available:j(t.authoritative_judgment_available),resident_judge_runtime:dl(t.resident_judge_runtime),judgment:Ap(t.judgment),active_guidance_layer:r(t.active_guidance_layer)??null,active_summary:qa(t.active_summary),active_recommended_actions:pe(t.active_recommended_actions).map(xn).filter(n=>n!==null),active_recommendation_source:r(t.active_recommendation_source)??null,active_recommendation_summary:qa(t.active_recommendation_summary),fallback_recommended_actions:pe(t.fallback_recommended_actions).map(xn).filter(n=>n!==null),recommendation_summary:qa(t.recommendation_summary),swarm_status:v(t.swarm_status)?t.swarm_status:void 0,attention_items:pe(t.attention_items).map(cl).filter(n=>n!==null),recommended_actions:pe(t.recommended_actions).map(xn).filter(n=>n!==null),session_cards:pe(t.session_cards).map(Ip).filter(n=>n!==null),worker_cards:pe(t.worker_cards).map(Cp).filter(n=>n!==null)}}function Tp(e){if(!v(e))return null;const t=v(e.status)?e.status:void 0,n=v(e.summary)?e.summary:v(t==null?void 0:t.summary)?t.summary:void 0,s=v(e.session)?e.session:v(t==null?void 0:t.session)?t.session:void 0,a=r(e.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const i=qi(e.report_paths)??qi(t==null?void 0:t.report_paths),l=pe(e.recent_events,["events"]).filter(v);return{session_id:a,status:r(e.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:d(e.progress_pct)??d(n==null?void 0:n.progress_pct),elapsed_sec:d(e.elapsed_sec)??d(n==null?void 0:n.elapsed_sec),remaining_sec:d(e.remaining_sec)??d(n==null?void 0:n.remaining_sec),done_delta_total:d(e.done_delta_total)??d(n==null?void 0:n.done_delta_total),summary:n,team_health:v(e.team_health)?e.team_health:v(t==null?void 0:t.team_health)?t.team_health:void 0,communication_metrics:v(e.communication_metrics)?e.communication_metrics:v(t==null?void 0:t.communication_metrics)?t.communication_metrics:void 0,orchestration_state:v(e.orchestration_state)?e.orchestration_state:v(t==null?void 0:t.orchestration_state)?t.orchestration_state:void 0,cascade_metrics:v(e.cascade_metrics)?e.cascade_metrics:v(t==null?void 0:t.cascade_metrics)?t.cascade_metrics:void 0,report_paths:i,linked_autoresearch:v(e.linked_autoresearch)?e.linked_autoresearch:v(t==null?void 0:t.linked_autoresearch)?t.linked_autoresearch:void 0,session:s,recent_events:l}}function Fi(e){if(!v(e))return null;const t=r(e.name);if(!t)return null;const n=v(e.context)?e.context:void 0;return{name:t,runtime_class:e.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:j(e.desired),resident_registered:j(e.resident_registered),agent_name:r(e.agent_name),status:r(e.status),autonomy_level:r(e.autonomy_level),context_ratio:d(e.context_ratio)??d(n==null?void 0:n.context_ratio),generation:d(e.generation),active_goal_ids:H(e.active_goal_ids),last_autonomous_action_at:r(e.last_autonomous_action_at)??null,last_turn_ago_s:d(e.last_turn_ago_s),model:r(e.model)??r(e.active_model)??r(e.primary_model)}}function Rp(e){if(!v(e))return null;const t=r(e.confirm_token)??r(e.token);return t?{confirm_token:t,actor:r(e.actor),action_type:r(e.action_type),target_type:r(e.target_type),target_id:r(e.target_id)??null,delegated_tool:r(e.delegated_tool),created_at:r(e.created_at),preview:e.preview}:null}function pl(e){if(!v(e))return null;const t=r(e.action_type),n=r(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:r(e.description),confirm_required:j(e.confirm_required)}}function Pp(e){return v(e)?{actor_filter:r(e.actor_filter)??null,filter_active:j(e.filter_active)??!1,visible_count:d(e.visible_count)??0,total_count:d(e.total_count)??0,hidden_count:d(e.hidden_count)??0,hidden_actors:H(e.hidden_actors),confirm_required_actions:pe(e.confirm_required_actions).map(pl).filter(t=>t!==null)}:null}function Lp(e){const t=v(e)?e:{};return{room:Sp(t.room),sessions:pe(t.sessions,["items","sessions"]).map(Tp).filter(n=>n!==null),keepers:pe(t.keepers,["items","keepers"]).map(Fi).filter(n=>n!==null),resident_judge_runtime:dl(t.resident_judge_runtime),persistent_agents:pe(t.persistent_agents,["items","persistent_agents"]).map(Fi).filter(n=>n!==null),recent_messages:pe(t.recent_messages,["messages"]).map(xp).filter(n=>n!==null),pending_confirms:pe(t.pending_confirms,["items","confirms"]).map(Rp).filter(n=>n!==null),pending_confirm_summary:Pp(t.pending_confirm_summary)??void 0,available_actions:pe(t.available_actions,["actions"]).map(pl).filter(n=>n!==null)}}function vs(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e)}catch{return String(e)}}function Ki(e){return e.target_id?`${e.target_type}:${e.target_id}`:e.target_type}function Js(e){Gs.value=[{...e,id:kp++,at:new Date().toISOString()},...Gs.value].slice(0,20)}function ml(e){return e.confirm_required?vs(e.preview)||"Confirmation required":vs(e.result)||vs(e.executed_action)||vs(e.delegated_tool_result)||e.status}async function ye(){Mn.value=!0,it.value=null;try{const e=await Ad();_e.value=Lp(e)}catch(e){it.value=e instanceof Error?e.message:"Failed to load operator snapshot"}finally{Mn.value=!1}}async function Tt(){Nn.value=!0,nn.value=null;try{const e=await Mr({targetType:"room"});ei.value=ul(e)}catch(e){nn.value=e instanceof Error?e.message:"Failed to load operator digest"}finally{Nn.value=!1}}async function sn(e){if(!e){je.value=null;return}Nn.value=!0,nn.value=null;try{const t=await Mr({targetType:"team_session",targetId:e,includeWorkers:!0});je.value=ul(t)}catch(t){nn.value=t instanceof Error?t.message:"Failed to load session digest"}finally{Nn.value=!1}}async function vl(e){var t;W.value=!0,it.value=null;try{const n=await Ia(e);return Js({actor:e.actor,action_type:e.action_type,target_label:Ki(e),outcome:n.confirm_required?"preview":"executed",message:ml(n),delegated_tool:n.delegated_tool}),await ye(),await Tt(),(t=je.value)!=null&&t.target_id&&await sn(je.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw it.value=s,Js({actor:e.actor,action_type:e.action_type,target_label:Ki(e),outcome:"error",message:s}),n}finally{W.value=!1}}async function _l(e,t,n="confirm"){var s;W.value=!0,it.value=null;try{const a=await Nr(e,t,n);return Js({actor:e,action_type:n,target_label:t,outcome:"confirmed",message:ml(a),delegated_tool:a.delegated_tool}),await ye(),await Tt(),(s=je.value)!=null&&s.target_id&&await sn(je.value.target_id),a}catch(a){const i=a instanceof Error?a.message:"Operator confirmation failed";throw it.value=i,Js({actor:e,action_type:"confirm",target_label:t,outcome:"error",message:i}),a}finally{W.value=!1}}$p(()=>{var e;ye(),Tt(),(e=je.value)!=null&&e.target_id&&sn(je.value.target_id)});const Xn=g(null),Io=g(!1),Vs=g(null),gl=g(null),wt=g(!1),yt=g(null),To=g(null),Ms=g(!1),Ns=g(null);let Gt=null;function Bi(){Gt!==null&&(window.clearTimeout(Gt),Gt=null)}function zp(e=1500){Gt===null&&(Gt=window.setTimeout(()=>{Gt=null,Qs(!1)},e))}function w(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function y(e){return typeof e=="string"&&e.trim()!==""?e:void 0}function D(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function Jt(e){return typeof e=="boolean"?e:void 0}function U(e,t=[]){if(Array.isArray(e))return e;if(!w(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function cn(e){if(!w(e))return null;const t=y(e.kind),n=y(e.summary),s=y(e.target_type);return!t||!n||!s?null:{kind:t,severity:y(e.severity)??"warn",summary:n,target_type:s,target_id:y(e.target_id)??null,actor:y(e.actor)??null,evidence:e.evidence}}function Rt(e){if(!w(e))return null;const t=y(e.action_type),n=y(e.target_type),s=y(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:y(e.target_id)??null,severity:y(e.severity)??"warn",reason:s,confirm_required:Jt(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function Mp(e){if(!w(e))return null;const t=y(e.session_id);return t?{session_id:t,goal:y(e.goal),status:y(e.status),health:y(e.health),scale_profile:y(e.scale_profile),control_profile:y(e.control_profile),planned_worker_count:D(e.planned_worker_count),active_agent_count:D(e.active_agent_count),last_turn_age_sec:D(e.last_turn_age_sec)??null,attention_count:D(e.attention_count),recommended_action_count:D(e.recommended_action_count),top_attention:cn(e.top_attention),top_recommendation:Rt(e.top_recommendation)}:null}function Np(e){if(!w(e))return null;const t=y(e.session_id);if(!t)return null;const n=w(e.status)?e.status:e,s=w(n.summary)?n.summary:void 0;return{session_id:t,status:y(e.status)??y(s==null?void 0:s.status)??(w(n.session)?y(n.session.status):void 0),progress_pct:D(e.progress_pct)??D(s==null?void 0:s.progress_pct),elapsed_sec:D(e.elapsed_sec)??D(s==null?void 0:s.elapsed_sec),remaining_sec:D(e.remaining_sec)??D(s==null?void 0:s.remaining_sec),done_delta_total:D(e.done_delta_total)??D(s==null?void 0:s.done_delta_total),summary:w(e.summary)?e.summary:s,team_health:w(e.team_health)?e.team_health:w(n.team_health)?n.team_health:void 0,communication_metrics:w(e.communication_metrics)?e.communication_metrics:w(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:w(e.orchestration_state)?e.orchestration_state:w(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:w(e.cascade_metrics)?e.cascade_metrics:w(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:w(e.report_paths)?Object.fromEntries(Object.entries(e.report_paths).map(([a,i])=>{const l=y(i);return l?[a,l]:null}).filter(a=>a!==null)):w(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,i])=>{const l=y(i);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:w(e.session)?e.session:w(n.session)?n.session:void 0,recent_events:U(e.recent_events,["events"]).filter(w)}}function Ep(e){if(!w(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name),status:y(e.status),autonomy_level:y(e.autonomy_level),context_ratio:D(e.context_ratio),generation:D(e.generation),active_goal_ids:U(e.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:y(e.last_autonomous_action_at)??null,last_turn_ago_s:D(e.last_turn_ago_s),model:y(e.model)}:null}function jp(e){if(!w(e))return null;const t=y(e.confirm_token)??y(e.token);return t?{confirm_token:t,actor:y(e.actor),action_type:y(e.action_type),target_type:y(e.target_type),target_id:y(e.target_id)??null,delegated_tool:y(e.delegated_tool),created_at:y(e.created_at),preview:e.preview}:null}function wp(e){if(!w(e))return null;const t=y(e.action_type),n=y(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:y(e.description),confirm_required:Jt(e.confirm_required)}}function Dp(e){const t=w(e)?e:{};return{room_health:y(t.room_health),cluster:y(t.cluster),project:y(t.project),current_room:y(t.current_room)??null,paused:Jt(t.paused),tempo_interval_s:D(t.tempo_interval_s),active_agents:D(t.active_agents),keeper_pressure:D(t.keeper_pressure),active_operations:D(t.active_operations),pending_approvals:D(t.pending_approvals),incident_count:D(t.incident_count),recommended_action_count:D(t.recommended_action_count),top_attention:cn(t.top_attention),top_action:Rt(t.top_action)}}function Op(e){const t=w(e)?e:{},n=w(t.swarm_overview)?t.swarm_overview:{};return{health:y(t.health),active_operations:D(t.active_operations),pending_approvals:D(t.pending_approvals),swarm_overview:{active_lanes:D(n.active_lanes),moving_lanes:D(n.moving_lanes),stalled_lanes:D(n.stalled_lanes),projected_lanes:D(n.projected_lanes),last_movement_at:y(n.last_movement_at)??null},top_attention:cn(t.top_attention),top_action:Rt(t.top_action),session_cards:U(t.session_cards).map(Mp).filter(s=>s!==null)}}function qp(e){const t=w(e)?e:{};return{sessions:U(t.sessions,["items"]).map(Np).filter(n=>n!==null),keepers:U(t.keepers,["items"]).map(Ep).filter(n=>n!==null),pending_confirms:U(t.pending_confirms).map(jp).filter(n=>n!==null),available_actions:U(t.available_actions).map(wp).filter(n=>n!==null)}}function Fp(e){if(!w(e))return null;const t=y(e.id),n=y(e.kind),s=y(e.summary),a=y(e.target_type);return!t||!n||!s||!a?null:{id:t,kind:n,severity:y(e.severity)??"warn",summary:s,target_type:a,target_id:y(e.target_id)??null,top_action:Rt(e.top_action),related_session_ids:U(e.related_session_ids).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),related_agent_names:U(e.related_agent_names).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),evidence_preview:U(e.evidence_preview).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),last_seen_at:y(e.last_seen_at)??null}}function fl(e){if(!w(e))return null;const t=y(e.session_id),n=y(e.goal);return!t||!n?null:{session_id:t,goal:n,room:y(e.room)??null,status:y(e.status),health:y(e.health),member_names:U(e.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:y(e.started_at)??null,elapsed_sec:D(e.elapsed_sec)??null,operation_id:y(e.operation_id)??null,blocker_summary:y(e.blocker_summary)??null,last_event_at:y(e.last_event_at)??null,last_event_summary:y(e.last_event_summary)??null,communication_summary:y(e.communication_summary)??null,active_count:D(e.active_count),required_count:D(e.required_count),related_attention_count:D(e.related_attention_count)??0,top_attention:cn(e.top_attention),top_recommendation:Rt(e.top_recommendation)}}function $l(e){if(!w(e))return null;const t=y(e.agent_name);return t?{agent_name:t,status:y(e.status),current_work:y(e.current_work)??null,recent_input_preview:y(e.recent_input_preview)??null,recent_output_preview:y(e.recent_output_preview)??null,recent_tool_names:U(e.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_activity_at:y(e.last_activity_at)??null}:null}function hl(e){if(!w(e))return null;const t=y(e.operation_id);return t?{operation_id:t,status:y(e.status),stage:y(e.stage)??null,detachment_status:y(e.detachment_status)??null,objective:y(e.objective)??null,updated_at:y(e.updated_at)??null}:null}function yl(e){if(!w(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name)??null,status:y(e.status),generation:D(e.generation),context_ratio:D(e.context_ratio)??null,last_turn_ago_s:D(e.last_turn_ago_s)??null,current_work:y(e.current_work)??null}:null}function bl(e){const t=fl(e);return t?{...t,member_previews:U(w(e)?e.member_previews:void 0).map($l).filter(n=>n!==null),operation_badges:U(w(e)?e.operation_badges:void 0).map(hl).filter(n=>n!==null),keeper_refs:U(w(e)?e.keeper_refs:void 0).map(yl).filter(n=>n!==null)}:null}function Kp(e){if(!w(e))return null;const t=y(e.agent_name);return t?{agent_name:t,status:y(e.status),where:y(e.where)??null,with_whom:U(e.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:y(e.current_work)??null,related_session_id:y(e.related_session_id)??null,related_attention_count:D(e.related_attention_count)??0,last_activity_at:y(e.last_activity_at)??null,recent_output_preview:y(e.recent_output_preview)??null,recent_input_preview:y(e.recent_input_preview)??null,recent_event:y(e.recent_event)??null,recent_tool_names:U(e.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),allowed_tool_names:U(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:U(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:D(e.latest_tool_call_count)??null,tool_audit_source:y(e.tool_audit_source)??null,tool_audit_at:y(e.tool_audit_at)??null}:null}function Bp(e){if(!w(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name)??null,status:y(e.status),generation:D(e.generation),context_ratio:D(e.context_ratio)??null,last_turn_ago_s:D(e.last_turn_ago_s)??null,current_work:y(e.current_work)??null,last_autonomous_action_at:y(e.last_autonomous_action_at)??null,allowed_tool_names:U(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:U(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:D(e.latest_tool_call_count)??null,tool_audit_source:y(e.tool_audit_source)??null,tool_audit_at:y(e.tool_audit_at)??null}:null}function Up(e){if(!w(e))return null;const t=y(e.id),n=y(e.signal_type),s=y(e.summary),a=y(e.target_type);return!t||!n||!s||!a?null:{id:t,signal_type:n==="action"?"action":"attention",severity:y(e.severity)??"warn",summary:s,target_type:a,target_id:y(e.target_id)??null,attention:cn(e.attention),action:Rt(e.action)}}function Hp(e){const t=w(e)?e:{},n=U(t.session_briefs).map(fl).filter(a=>a!==null),s=U(t.sessions).map(bl).filter(a=>a!==null);return{generated_at:y(t.generated_at),summary:Dp(t.summary),incidents:U(t.incidents).map(cn).filter(a=>a!==null),recommended_actions:U(t.recommended_actions).map(Rt).filter(a=>a!==null),command_focus:Op(t.command_focus),operator_targets:qp(t.operator_targets),attention_queue:U(t.attention_queue).map(Fp).filter(a=>a!==null),sessions:s.length>0?s:n.map(a=>({...a,member_previews:[],operation_badges:[],keeper_refs:[]})),session_briefs:n,agent_briefs:U(t.agent_briefs).map(Kp).filter(a=>a!==null),keeper_briefs:U(t.keeper_briefs).map(Bp).filter(a=>a!==null),internal_signals:U(t.internal_signals).map(Up).filter(a=>a!==null)}}function Wp(e){if(!w(e))return null;const t=y(e.id),n=y(e.summary);return!t||!n?null:{id:t,timestamp:y(e.timestamp)??null,event_type:y(e.event_type),actor:y(e.actor)??null,summary:n}}function Gp(e){const t=w(e)?e:{};return{generated_at:y(t.generated_at),session_id:y(t.session_id)??"",session:bl(t.session),timeline:U(t.timeline).map(Wp).filter(n=>n!==null),participants:U(t.participants).map($l).filter(n=>n!==null),operations:U(t.operations).map(hl).filter(n=>n!==null),keepers:U(t.keepers).map(yl).filter(n=>n!==null),error:y(t.error)??null}}function Jp(e){if(!w(e))return null;const t=y(e.id),n=y(e.label),s=y(e.summary);if(!t||!n||!s)return null;const a=y(e.status)??"unclear";return{id:t,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:y(e.signal_class)==="metadata_gap"||y(e.signal_class)==="mixed"||y(e.signal_class)==="operational_risk"?y(e.signal_class):void 0,evidence_quality:y(e.evidence_quality)==="strong"||y(e.evidence_quality)==="partial"||y(e.evidence_quality)==="missing"?y(e.evidence_quality):void 0,evidence:U(e.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function Vp(e){if(!w(e))return null;const t=y(e.kind),n=y(e.summary),s=y(e.scope_type),a=y(e.severity);return!t||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:t,summary:n,scope_type:s,scope_id:y(e.scope_id)??null,severity:a}}function Qp(e){const t=w(e)?e:{},n=w(t.basis)?t.basis:{},s=y(t.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:y(t.generated_at),cached:Jt(t.cached),stale:Jt(t.stale),refreshing:Jt(t.refreshing),status:a,summary:y(t.summary)??null,model:y(t.model)??null,ttl_sec:D(t.ttl_sec),criteria:U(t.criteria).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),basis:{current_room:y(n.current_room)??null,crew_count:D(n.crew_count),agent_count:D(n.agent_count),keeper_count:D(n.keeper_count)},metadata_gap_count:D(t.metadata_gap_count),metadata_gaps:U(t.metadata_gaps).map(Vp).filter(i=>i!==null),sections:U(t.sections).map(Jp).filter(i=>i!==null),error:y(t.error)??null,last_error:y(t.last_error)??null}}async function kl(){Io.value=!0,Vs.value=null;try{const e=await hd();Xn.value=Hp(e)}catch(e){Vs.value=e instanceof Error?e.message:"Failed to load mission snapshot"}finally{Io.value=!1}}async function Yp(e){if(!e){To.value=null,Ns.value=null,Ms.value=!1;return}Ms.value=!0,Ns.value=null;try{const t=await yd(e);To.value=Gp(t)}catch(t){Ns.value=t instanceof Error?t.message:"Failed to load session detail"}finally{Ms.value=!1}}async function Qs(e=!1){wt.value=!0,yt.value=null;try{const t=await bd(e),n=Qp(t);gl.value=n,n.refreshing||n.status==="pending"?zp():Bi()}catch(t){yt.value=t instanceof Error?t.message:"Failed to load mission briefing",Bi()}finally{wt.value=!1}}const xl=g(null),Ro=g(!1),Dt=g(null);async function Sl(e,t){Ro.value=!0,Dt.value=null;try{xl.value=await kd(e,t)}catch(n){Dt.value=n instanceof Error?n.message:String(n)}finally{Ro.value=!1}}const ti=g(null),De=g(null),Ys=g(!1),Xs=g(!1),Zs=g(null),ea=g(null),Po=g(null),ta=g(null),G=g("warroom"),Zn=g(null),Lo=g(!1),na=g(null),Pt=g(null),sa=g(!1),aa=g(null),ni=g(null),zo=g(!1),oa=g(null),es=g(null),Mo=g(!1),ia=g(null),En=g(null),ra=g(!1),jn=g(null),Vt=g(null);let $n=null;function si(e){return e!=="summary"&&e!=="swarm"&&e!=="warroom"&&e!=="orchestra"}function Al(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,i)=>{e.has(i)||e.set(i,a)}),e}function Cl(){const t=Al().get("run_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function Il(){const t=Al().get("operation_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function Xp(e){if(v(e))return{policy_class:r(e.policy_class),approval_class:r(e.approval_class),tool_allowlist:H(e.tool_allowlist),model_allowlist:H(e.model_allowlist),requires_human_for:H(e.requires_human_for),autonomy_level:r(e.autonomy_level),escalation_timeout_sec:d(e.escalation_timeout_sec),kill_switch:j(e.kill_switch),frozen:j(e.frozen)}}function Zp(e){if(v(e))return{headcount_cap:d(e.headcount_cap),active_operation_cap:d(e.active_operation_cap),max_cost_usd:d(e.max_cost_usd),max_tokens:d(e.max_tokens)}}function ai(e){if(!v(e))return null;const t=r(e.unit_id),n=r(e.label),s=r(e.kind);return!t||!n||!s?null:{unit_id:t,label:n,kind:s,parent_unit_id:r(e.parent_unit_id)??null,leader_id:r(e.leader_id)??null,roster:H(e.roster),capability_profile:H(e.capability_profile),source:r(e.source),created_at:r(e.created_at),updated_at:r(e.updated_at),policy:Xp(e.policy),budget:Zp(e.budget)}}function Tl(e){if(!v(e))return null;const t=ai(e.unit);return t?{unit:t,leader_status:r(e.leader_status),roster_total:d(e.roster_total),roster_live:d(e.roster_live),active_operation_count:d(e.active_operation_count),health:r(e.health),reasons:H(e.reasons),children:Array.isArray(e.children)?e.children.map(Tl).filter(n=>n!==null):[]}:null}function em(e){if(v(e))return{total_units:d(e.total_units),company_count:d(e.company_count),platoon_count:d(e.platoon_count),squad_count:d(e.squad_count),leaf_agent_unit_count:d(e.leaf_agent_unit_count),live_agent_count:d(e.live_agent_count),managed_unit_count:d(e.managed_unit_count),active_operation_count:d(e.active_operation_count)}}function Rl(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),source:r(t.source),summary:em(t.summary),units:Array.isArray(t.units)?t.units.map(Tl).filter(n=>n!==null):[]}}function tm(e){if(!v(e))return null;const t=r(e.kind),n=r(e.status);return!t||!n?null:{kind:t,chain_id:r(e.chain_id)??null,goal:r(e.goal)??null,run_id:r(e.run_id)??null,status:n,viewer_path:r(e.viewer_path)??null,last_sync_at:r(e.last_sync_at)??null}}function Pa(e){if(!v(e))return null;const t=r(e.operation_id),n=r(e.objective),s=r(e.assigned_unit_id),a=r(e.trace_id),i=r(e.status);return!t||!n||!s||!a||!i?null:{operation_id:t,objective:n,assigned_unit_id:s,autonomy_level:r(e.autonomy_level),policy_class:r(e.policy_class),budget_class:r(e.budget_class),detachment_session_id:r(e.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(e.checkpoint_ref)??null,active_goal_ids:H(e.active_goal_ids),note:r(e.note)??null,created_by:r(e.created_by),source:r(e.source),status:i,chain:tm(e.chain),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function nm(e){if(!v(e))return null;const t=Pa(e.operation);return t?{operation:t,assigned_unit_label:r(e.assigned_unit_label)}:null}function _n(e){if(v(e))return{tone:r(e.tone),pending_ops:d(e.pending_ops),blocked_ops:d(e.blocked_ops),in_flight_ops:d(e.in_flight_ops),pipeline_stalls:d(e.pipeline_stalls),bus_traffic:d(e.bus_traffic),l1_hit_rate:d(e.l1_hit_rate),invalidation_count:d(e.invalidation_count),current_pending:d(e.current_pending),current_in_flight:d(e.current_in_flight),cdb_wakeups:d(e.cdb_wakeups),total_stolen:d(e.total_stolen),avg_best_score:d(e.avg_best_score),avg_candidate_count:d(e.avg_candidate_count),best_first_operations:d(e.best_first_operations),active_sessions:d(e.active_sessions),commit_rate:d(e.commit_rate),total_speculations:d(e.total_speculations)}}function sm(e){if(!v(e))return;const t=v(e.pipeline)?e.pipeline:void 0,n=v(e.cache)?e.cache:void 0,s=v(e.ooo)?e.ooo:void 0,a=v(e.speculative)?e.speculative:void 0,i=v(e.search_fabric)?e.search_fabric:void 0,l=v(e.signals)?e.signals:void 0;return{pipeline:t?{total_ops:d(t.total_ops),completed_ops:d(t.completed_ops),stalled_cycles:d(t.stalled_cycles),hazards_detected:d(t.hazards_detected),forwarding_used:d(t.forwarding_used),pipeline_flushes:d(t.pipeline_flushes),ipc:d(t.ipc)}:void 0,cache:n?{total_reads:d(n.total_reads),total_writes:d(n.total_writes),l1_hit_rate:d(n.l1_hit_rate),invalidation_count:d(n.invalidation_count),writeback_count:d(n.writeback_count),bus_traffic:d(n.bus_traffic)}:void 0,ooo:s?{agent_count:d(s.agent_count),total_added:d(s.total_added),total_issued:d(s.total_issued),total_completed:d(s.total_completed),total_stolen:d(s.total_stolen),cdb_wakeups:d(s.cdb_wakeups),stall_cycles:d(s.stall_cycles),global_cdb_events:d(s.global_cdb_events),current_pending:d(s.current_pending),current_in_flight:d(s.current_in_flight)}:void 0,speculative:a?{total_speculations:d(a.total_speculations),total_commits:d(a.total_commits),total_aborts:d(a.total_aborts),commit_rate:d(a.commit_rate),total_fast_calls:d(a.total_fast_calls),total_cost_usd:d(a.total_cost_usd),active_sessions:d(a.active_sessions)}:void 0,search_fabric:i?{total_operations:d(i.total_operations),best_first_operations:d(i.best_first_operations),legacy_operations:d(i.legacy_operations),blocked_operations:d(i.blocked_operations),ready_operations:d(i.ready_operations),research_pipeline_operations:d(i.research_pipeline_operations),avg_candidate_count:d(i.avg_candidate_count),avg_best_score:d(i.avg_best_score),top_stage:r(i.top_stage)??null}:void 0,signals:l?{issue_pressure:_n(l.issue_pressure),cache_contention:_n(l.cache_contention),scheduler_efficiency:_n(l.scheduler_efficiency),routing_confidence:_n(l.routing_confidence),speculative_posture:_n(l.speculative_posture)}:void 0}}function Pl(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),paused:d(n.paused),managed:d(n.managed),projected:d(n.projected)}:void 0,microarch:sm(t.microarch),operations:Array.isArray(t.operations)?t.operations.map(nm).filter(s=>s!==null):[]}}function Ll(e){if(!v(e))return null;const t=r(e.detachment_id),n=r(e.operation_id),s=r(e.assigned_unit_id);return!t||!n||!s?null:{detachment_id:t,operation_id:n,assigned_unit_id:s,leader_id:r(e.leader_id)??null,roster:H(e.roster),session_id:r(e.session_id)??null,checkpoint_ref:r(e.checkpoint_ref)??null,runtime_kind:r(e.runtime_kind)??null,runtime_ref:r(e.runtime_ref)??null,source:r(e.source),status:r(e.status),last_event_at:r(e.last_event_at)??null,last_progress_at:r(e.last_progress_at)??null,heartbeat_deadline:r(e.heartbeat_deadline)??null,created_at:r(e.created_at),updated_at:r(e.updated_at)}}function am(e){if(!v(e))return null;const t=Ll(e.detachment);return t?{detachment:t,assigned_unit_label:r(e.assigned_unit_label),operation:Pa(e.operation)}:null}function zl(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),projected:d(n.projected)}:void 0,detachments:Array.isArray(t.detachments)?t.detachments.map(am).filter(s=>s!==null):[]}}function om(e){if(!v(e))return null;const t=r(e.decision_id),n=r(e.trace_id),s=r(e.requested_action),a=r(e.scope_type),i=r(e.scope_id);return!t||!n||!s||!a||!i?null:{decision_id:t,trace_id:n,requested_action:s,scope_type:a,scope_id:i,operation_id:r(e.operation_id)??null,target_unit_id:r(e.target_unit_id)??null,requested_by:r(e.requested_by),status:r(e.status),reason:r(e.reason)??null,source:r(e.source),detail:e.detail,created_at:r(e.created_at),decided_at:r(e.decided_at)??null,expires_at:r(e.expires_at)??null}}function Ml(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),pending:d(n.pending),approved:d(n.approved),denied:d(n.denied)}:void 0,decisions:Array.isArray(t.decisions)?t.decisions.map(om).filter(s=>s!==null):[]}}function im(e){if(!v(e))return null;const t=ai(e.unit);return t?{unit:t,roster_total:d(e.roster_total),roster_live:d(e.roster_live),headcount_cap:d(e.headcount_cap),active_operations:d(e.active_operations),active_operation_cap:d(e.active_operation_cap),utilization:d(e.utilization)}:null}function rm(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),capacity:Array.isArray(t.capacity)?t.capacity.map(im).filter(n=>n!==null):[]}}function lm(e){if(!v(e))return null;const t=r(e.alert_id);return t?{alert_id:t,severity:r(e.severity),kind:r(e.kind),scope_type:r(e.scope_type),scope_id:r(e.scope_id),title:r(e.title),detail:r(e.detail),timestamp:r(e.timestamp)}:null}function Nl(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),bad:d(n.bad),warn:d(n.warn)}:void 0,alerts:Array.isArray(t.alerts)?t.alerts.map(lm).filter(s=>s!==null):[]}}function El(e){if(!v(e))return null;const t=r(e.event_id),n=r(e.trace_id),s=r(e.event_type);return!t||!n||!s?null:{event_id:t,trace_id:n,event_type:s,operation_id:r(e.operation_id)??null,unit_id:r(e.unit_id)??null,actor:r(e.actor)??null,source:r(e.source),timestamp:r(e.timestamp),detail:e.detail}}function cm(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),events:Array.isArray(t.events)?t.events.map(El).filter(n=>n!==null):[]}}function dm(e){if(!v(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s}}function um(e){if(!v(e))return null;const t=r(e.lane_id),n=r(e.label),s=r(e.kind),a=r(e.phase),i=r(e.motion_state),l=r(e.source_of_truth),c=r(e.movement_reason),p=r(e.current_step);if(!t||!n||!s||!a||!i||!l||!c||!p)return null;const m=v(e.counts)?e.counts:{};return{lane_id:t,label:n,kind:s,present:j(e.present)??!1,phase:a,motion_state:i,source_of_truth:l,last_movement_at:r(e.last_movement_at)??null,movement_reason:c,current_step:p,blockers:H(e.blockers),counts:{operations:d(m.operations),detachments:d(m.detachments),workers:d(m.workers),approvals:d(m.approvals),alerts:d(m.alerts)},hard_flags:Array.isArray(e.hard_flags)?e.hard_flags.map(dm).filter(u=>u!==null):[]}}function pm(e){if(!v(e))return null;const t=r(e.event_id),n=r(e.lane_id),s=r(e.kind),a=r(e.timestamp),i=r(e.title),l=r(e.detail),c=r(e.tone),p=r(e.source);return!t||!n||!s||!a||!i||!l||!c||!p?null:{event_id:t,lane_id:n,kind:s,timestamp:a,title:i,detail:l,tone:c,source:p}}function mm(e){if(!v(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s,lane_ids:H(e.lane_ids),count:d(e.count)??0}}function oi(e){if(!v(e))return;const t=v(e.overview)?e.overview:{},n=v(e.gaps)?e.gaps:{},s=v(e.recommended_next_action)?e.recommended_next_action:void 0;return{generated_at:r(e.generated_at),overview:{active_lanes:d(t.active_lanes),moving_lanes:d(t.moving_lanes),stalled_lanes:d(t.stalled_lanes),projected_lanes:d(t.projected_lanes),last_movement_at:r(t.last_movement_at)??null},lanes:Array.isArray(e.lanes)?e.lanes.map(um).filter(a=>a!==null):[],timeline:Array.isArray(e.timeline)?e.timeline.map(pm).filter(a=>a!==null):[],gaps:{count:d(n.count),items:Array.isArray(n.items)?n.items.map(mm).filter(a=>a!==null):[]},recommended_next_action:s?{tool:r(s.tool)??"masc_operator_snapshot",label:r(s.label)??"Observe operator state",reason:r(s.reason)??"",lane_id:r(s.lane_id)??null}:void 0}}function jl(e){if(!v(e))return;const t=v(e.workers)?e.workers:{},n=j(e.pass);return{status:r(e.status)??"missing",source:r(e.source)??"none",run_id:r(e.run_id)??null,captured_at:r(e.captured_at)??null,...n!==void 0?{pass:n}:{},...d(e.peak_hot_slots)!=null?{peak_hot_slots:d(e.peak_hot_slots)}:{},...d(e.ctx_per_slot)!=null?{ctx_per_slot:d(e.ctx_per_slot)}:{},workers:{expected:d(t.expected),joined:d(t.joined),current_task_bound:d(t.current_task_bound),fresh_heartbeats:d(t.fresh_heartbeats),done:d(t.done),final:d(t.final)},artifact_ref:r(e.artifact_ref)??null,missing_reason:r(e.missing_reason)??null}}function vm(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),topology:Rl(t.topology),operations:Pl(t.operations),detachments:zl(t.detachments),alerts:Nl(t.alerts),decisions:Ml(t.decisions),capacity:rm(t.capacity),traces:cm(t.traces),swarm_status:oi(t.swarm_status)}}function _m(e){const t=v(e)?e:{},n=Rl(t.topology),s=Pl(t.operations),a=zl(t.detachments),i=Nl(t.alerts),l=Ml(t.decisions);return{version:r(t.version),generated_at:r(t.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:i.version,generated_at:i.generated_at,summary:i.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:oi(t.swarm_status),swarm_proof:jl(t.swarm_proof)}}function gm(e){return v(e)?{chain_id:r(e.chain_id)??null,started_at:d(e.started_at)??null,progress:d(e.progress)??null,elapsed_sec:d(e.elapsed_sec)??null}:null}function wl(e){if(!v(e))return null;const t=r(e.event);return t?{event:t,chain_id:r(e.chain_id)??null,timestamp:r(e.timestamp)??null,duration_ms:d(e.duration_ms)??null,message:r(e.message)??null,tokens:d(e.tokens)??null}:null}function fm(e){if(!v(e))return null;const t=Pa(e.operation);return t?{operation:t,runtime:gm(e.runtime),history:wl(e.history),mermaid:r(e.mermaid)??null,preview_run:Dl(e.preview_run)}:null}function $m(e){const t=v(e)?e:{};return{status:r(t.status)??"disconnected",base_url:r(t.base_url)??null,message:r(t.message)??null}}function hm(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),connection:$m(t.connection),summary:n?{linked_operations:d(n.linked_operations),active_chains:d(n.active_chains),running_operations:d(n.running_operations),recent_failures:d(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(t.operations)?t.operations.map(fm).filter(s=>s!==null):[],recent_history:Array.isArray(t.recent_history)?t.recent_history.map(wl).filter(s=>s!==null):[]}}function ym(e){if(!v(e))return null;const t=r(e.id);return t?{id:t,type:r(e.type),status:r(e.status),duration_ms:d(e.duration_ms)??null,error:r(e.error)??null}:null}function Dl(e){if(!v(e))return null;const t=r(e.run_id),n=r(e.chain_id);return n?{run_id:t??null,chain_id:n,duration_ms:d(e.duration_ms),success:j(e.success),mermaid:r(e.mermaid),nodes:Array.isArray(e.nodes)?e.nodes.map(ym).filter(s=>s!==null):[]}:null}function bm(e){const t=v(e)?e:{};return{run:Dl(t.run)}}function km(e){if(!v(e))return null;const t=r(e.title),n=r(e.path);return!t||!n?null:{title:t,path:n}}function xm(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary);return!t||!n||!s?null:{id:t,title:n,summary:s}}function Sm(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.tool),a=r(e.summary);return!t||!n||!s||!a?null:{id:t,title:n,tool:s,summary:a,success_signals:H(e.success_signals),pitfalls:H(e.pitfalls)}}function Am(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary),a=r(e.when_to_use);return!t||!n||!s||!a?null:{id:t,title:n,summary:s,when_to_use:a,steps:Array.isArray(e.steps)?e.steps.map(Sm).filter(i=>i!==null):[]}}function Cm(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.description);return!t||!n||!s?null:{id:t,title:n,description:s,tools:H(e.tools)}}function Im(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.symptom),a=r(e.why),i=r(e.fix_tool),l=r(e.fix_summary);return!t||!n||!s||!a||!i||!l?null:{id:t,title:n,symptom:s,why:a,fix_tool:i,fix_summary:l}}function Tm(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.path_id),a=r(e.transport);return!t||!n||!s||!a?null:{id:t,title:n,path_id:s,transport:a,request:e.request,response:e.response,notes:H(e.notes)}}function Rm(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),docs:Array.isArray(t.docs)?t.docs.map(km).filter(n=>n!==null):[],concepts:Array.isArray(t.concepts)?t.concepts.map(xm).filter(n=>n!==null):[],golden_paths:Array.isArray(t.golden_paths)?t.golden_paths.map(Am).filter(n=>n!==null):[],tool_groups:Array.isArray(t.tool_groups)?t.tool_groups.map(Cm).filter(n=>n!==null):[],pitfalls:Array.isArray(t.pitfalls)?t.pitfalls.map(Im).filter(n=>n!==null):[],examples:Array.isArray(t.examples)?t.examples.map(Tm).filter(n=>n!==null):[]}}function Pm(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.status),a=r(e.detail),i=r(e.next_tool);return!t||!n||!s||!a||!i?null:{id:t,title:n,status:s,detail:a,next_tool:i}}function Lm(e){if(!v(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.title),a=r(e.detail),i=r(e.next_tool);return!t||!n||!s||!a||!i?null:{code:t,severity:n,title:s,detail:a,next_tool:i}}function zm(e){if(!v(e))return null;const t=r(e.from),n=r(e.content),s=r(e.timestamp),a=d(e.seq);return!t||!n||!s||a==null?null:{seq:a,from:t,content:n,timestamp:s}}function Mm(e){if(!v(e))return null;const t=r(e.name),n=r(e.role),s=r(e.lane),a=r(e.status),i=r(e.claim_marker),l=r(e.done_marker),c=r(e.final_marker);if(!t||!n||!s||!a||!i||!l||!c)return null;const p=(()=>{if(!v(e.last_message))return null;const m=d(e.last_message.seq),u=r(e.last_message.content),_=r(e.last_message.timestamp);return m==null||!u||!_?null:{seq:m,content:u,timestamp:_}})();return{name:t,role:n,lane:s,joined:j(e.joined)??!1,live_presence:j(e.live_presence)??!1,completed:j(e.completed)??!1,status:a,current_task:r(e.current_task)??null,bound_task_id:r(e.bound_task_id)??null,bound_task_title:r(e.bound_task_title)??null,bound_task_status:r(e.bound_task_status)??null,current_task_matches_run:j(e.current_task_matches_run)??!1,squad_member:j(e.squad_member)??!1,detachment_member:j(e.detachment_member)??!1,last_seen:r(e.last_seen)??null,heartbeat_age_sec:d(e.heartbeat_age_sec)??null,heartbeat_fresh:j(e.heartbeat_fresh)??!1,claim_marker_seen:j(e.claim_marker_seen)??!1,done_marker_seen:j(e.done_marker_seen)??!1,final_marker_seen:j(e.final_marker_seen)??!1,claim_marker:i,done_marker:l,final_marker:c,last_message:p}}function Nm(e){if(!v(e))return;const t=Array.isArray(e.timeline)?e.timeline.map(n=>{if(!v(n))return null;const s=r(n.timestamp),a=d(n.active_slots);if(!s||a==null)return null;const i=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:i}}).filter(n=>n!==null):[];return{slot_url:r(e.slot_url)??null,provider_base_url:r(e.provider_base_url)??null,provider_reachable:j(e.provider_reachable)??null,provider_status_code:d(e.provider_status_code)??null,provider_model_id:r(e.provider_model_id)??null,actual_model_id:r(e.actual_model_id)??null,expected_slots:d(e.expected_slots),actual_slots:d(e.actual_slots),expected_ctx:d(e.expected_ctx),actual_ctx:d(e.actual_ctx),slot_reachable:j(e.slot_reachable)??null,slot_status_code:d(e.slot_status_code)??null,runtime_blocker:r(e.runtime_blocker)??null,detail:r(e.detail)??null,checked_at:r(e.checked_at)??null,total_slots:d(e.total_slots),ctx_per_slot:d(e.ctx_per_slot),active_slots_now:d(e.active_slots_now),peak_active_slots:d(e.peak_active_slots),sample_count:d(e.sample_count),last_sample_at:r(e.last_sample_at)??null,timeline:t}}function Em(e){if(!v(e))return null;const t=r(e.run_id),n=r(e.status),s=r(e.decided_by),a=r(e.decided_at),i=r(e.reason);if(!t||!n||!s||!a||!i)return null;const l=[];return Array.isArray(e.history)&&e.history.forEach(c=>{if(!v(c))return;const p=r(c.status),m=r(c.decided_by),u=r(c.decided_at),_=r(c.reason);!p||!m||!u||!_||l.push({status:p,decided_by:m,decided_at:u,reason:_,operation_id:r(c.operation_id)??null,detachment_id:r(c.detachment_id)??null,note:r(c.note)??null})}),{run_id:t,status:n,decided_by:s,decided_at:a,reason:i,operation_id:r(e.operation_id)??null,detachment_id:r(e.detachment_id)??null,note:r(e.note)??null,history:l}}function jm(e){if(!v(e))return null;const t=r(e.run_id),n=r(e.recommended_kind),s=r(e.reason);return!t||!n||!s?null:{run_id:t,recommended_kind:n,continue_available:j(e.continue_available)??!1,rerun_available:j(e.rerun_available)??!1,abandon_available:j(e.abandon_available)??!1,reason:s,evidence:v(e.evidence)?{operation_id:r(e.evidence.operation_id)??null,detachment_id:r(e.evidence.detachment_id)??null,joined_workers:d(e.evidence.joined_workers),current_task_bound:d(e.evidence.current_task_bound),fresh_heartbeats:d(e.evidence.fresh_heartbeats),trace_events:d(e.evidence.trace_events),message_events:d(e.evidence.message_events),runtime_blocker:r(e.evidence.runtime_blocker)??null}:void 0,provenance:r(e.provenance),decision_engine:r(e.decision_engine),authoritative:j(e.authoritative)}}function wm(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),run_id:r(t.run_id),room_id:r(t.room_id),operation_id:r(t.operation_id)??null,run_resolution:Em(t.run_resolution),resolution_recommendation:jm(t.resolution_recommendation),recommended_next_tool:r(t.recommended_next_tool),summary:n?{expected_workers:d(n.expected_workers),joined_workers:d(n.joined_workers),live_workers:d(n.live_workers),squad_roster_size:d(n.squad_roster_size),detachment_roster_size:d(n.detachment_roster_size),current_task_bound:d(n.current_task_bound),fresh_heartbeats:d(n.fresh_heartbeats),claim_markers_seen:d(n.claim_markers_seen),done_markers_seen:d(n.done_markers_seen),final_markers_seen:d(n.final_markers_seen),completed_workers:d(n.completed_workers),peak_hot_slots:d(n.peak_hot_slots),hot_window_ok:j(n.hot_window_ok),pass_hot_concurrency:j(n.pass_hot_concurrency),pass_end_to_end:j(n.pass_end_to_end),pending_decisions:d(n.pending_decisions),pass:j(n.pass)}:void 0,provider:Nm(t.provider),operation:Pa(t.operation),squad:ai(t.squad),detachment:Ll(t.detachment),workers:Array.isArray(t.workers)?t.workers.map(Mm).filter(s=>s!==null):[],checklist:Array.isArray(t.checklist)?t.checklist.map(Pm).filter(s=>s!==null):[],blockers:Array.isArray(t.blockers)?t.blockers.map(Lm).filter(s=>s!==null):[],recent_messages:Array.isArray(t.recent_messages)?t.recent_messages.map(zm).filter(s=>s!==null):[],recent_trace_events:Array.isArray(t.recent_trace_events)?t.recent_trace_events.map(El).filter(s=>s!==null):[],truth_notes:H(t.truth_notes)}}function Dm(e){if(!v(e))return null;const t=r(e.label),n=r(e.value);return!t||!n?null:{label:t,value:n}}function Om(e){if(!v(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.label),a=r(e.tone),i=r(e.provenance);return!t||!n||!s||!a||!i?null:{id:t,kind:n,label:s,subtitle:r(e.subtitle)??null,status:r(e.status)??null,tone:a,pulse:r(e.pulse)??null,provenance:i,visual_class:r(e.visual_class)??void 0,glyph:r(e.glyph)??void 0,parent_id:r(e.parent_id)??null,lane_id:r(e.lane_id)??null,link_tab:r(e.link_tab)??null,link_surface:r(e.link_surface)??null,link_params:v(e.link_params)?Object.fromEntries(Object.entries(e.link_params).map(([l,c])=>{const p=r(c);return p?[l,p]:null}).filter(l=>l!==null)):{},facts:Array.isArray(e.facts)?e.facts.map(Dm).filter(l=>l!==null):[]}}function qm(e){if(!v(e))return null;const t=r(e.id),n=r(e.source),s=r(e.target),a=r(e.kind),i=r(e.tone),l=r(e.provenance);return!t||!n||!s||!a||!i||!l?null:{id:t,source:n,target:s,kind:a,label:r(e.label)??null,tone:i,provenance:l,animated:j(e.animated)}}function Fm(e){if(!v(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.label),a=r(e.tone),i=r(e.provenance);return!t||!n||!s||!a||!i?null:{id:t,kind:n,label:s,detail:r(e.detail)??null,tone:a,provenance:i,source_id:r(e.source_id)??null,target_id:r(e.target_id)??null,suggested_surface:r(e.suggested_surface)??null,suggested_params:v(e.suggested_params)?Object.fromEntries(Object.entries(e.suggested_params).map(([l,c])=>{const p=r(c);return p?[l,p]:null}).filter(l=>l!==null)):{}}}function Km(e){if(!v(e))return null;const t=r(e.target_kind),n=r(e.target_id),s=r(e.label),a=r(e.reason);return!t||!n||!s||!a?null:{target_kind:t,target_id:n,label:s,reason:a,suggested_surface:r(e.suggested_surface)??null,suggested_params:v(e.suggested_params)?Object.fromEntries(Object.entries(e.suggested_params).map(([i,l])=>{const c=r(l);return c?[i,c]:null}).filter(i=>i!==null)):{}}}function Bm(e){const t=v(e)?e:{},n=v(t.room)?t.room:{},s=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),room:{room_id:r(n.room_id),project:r(n.project),cluster:r(n.cluster),paused:j(n.paused),pause_reason:r(n.pause_reason)??null,agent_count:d(n.agent_count),task_count:d(n.task_count),message_count:d(n.message_count)},summary:s?{session_count:d(s.session_count),operation_count:d(s.operation_count),detachment_count:d(s.detachment_count),lane_count:d(s.lane_count),worker_count:d(s.worker_count),keeper_count:d(s.keeper_count),signal_count:d(s.signal_count),alert_count:d(s.alert_count)}:void 0,nodes:Array.isArray(t.nodes)?t.nodes.map(Om).filter(a=>a!==null):[],edges:Array.isArray(t.edges)?t.edges.map(qm).filter(a=>a!==null):[],signals:Array.isArray(t.signals)?t.signals.map(Fm).filter(a=>a!==null):[],focus:Km(t.focus),swarm_status:oi(t.swarm_status),swarm_proof:jl(t.swarm_proof),truth_notes:H(t.truth_notes)}}function nt(e){G.value=e,si(e)&&Um()}async function Ol(){Ys.value=!0,Zs.value=null;try{const e=await Id();ti.value=_m(e)}catch(e){Zs.value=e instanceof Error?e.message:"Failed to load command-plane summary"}finally{Ys.value=!1}}function ii(e){Vt.value=e}async function ri(){Xs.value=!0,ea.value=null;try{const e=await Cd();De.value=vm(e)}catch(e){ea.value=e instanceof Error?e.message:"Failed to load command-plane snapshot"}finally{Xs.value=!1}}async function Um(){De.value||Xs.value||await ri()}async function Ot(){await Ol(),si(G.value)&&await ri()}async function Qt(){var e;Mo.value=!0,ia.value=null;try{const t=await Td(),n=hm(t);es.value=n;const s=Vt.value;n.operations.length===0?Vt.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Vt.value=((e=n.operations[0])==null?void 0:e.operation.operation_id)??null)}catch(t){ia.value=t instanceof Error?t.message:"Failed to load chain summary"}finally{Mo.value=!1}}function Hm(){$n=null,En.value=null,ra.value=!1,jn.value=null}async function Wm(e){$n=e,ra.value=!0,jn.value=null;try{const t=await Rd(e);if($n!==e)return;En.value=bm(t)}catch(t){if($n!==e)return;En.value=null,jn.value=t instanceof Error?t.message:"Failed to load chain run"}finally{$n===e&&(ra.value=!1)}}async function Gm(){Lo.value=!0,na.value=null;try{const e=await Pd();Zn.value=Rm(e)}catch(e){na.value=e instanceof Error?e.message:"Failed to load command-plane help"}finally{Lo.value=!1}}async function Qe(e=Cl(),t=Il()){sa.value=!0,aa.value=null;try{const n=await Ld(e,t);Pt.value=wm(n)}catch(n){aa.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{sa.value=!1}}async function St(e=Cl(),t=Il()){zo.value=!0,oa.value=null;try{const n=await zd(e,t);ni.value=Bm(n)}catch(n){oa.value=n instanceof Error?n.message:"Failed to load orchestra map"}finally{zo.value=!1}}async function ut(e,t,n){Po.value=e,ta.value=null;try{await Md(t,n),await Ol(),(De.value||si(G.value))&&await ri(),await Qe(),await St(),await Qt()}catch(s){throw ta.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{Po.value=null}}function Jm(e){return ut(`pause:${e}`,"/api/v1/command-plane/operations/pause",{operation_id:e})}function Vm(e){return ut(`resume:${e}`,"/api/v1/command-plane/operations/resume",{operation_id:e})}function Qm(e){return ut(`recall:${e}`,"/api/v1/command-plane/dispatch/recall",{operation_id:e})}function Ym(e={}){return ut("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...e.operationId?{operation_id:e.operationId}:{},...e.detachmentId?{detachment_id:e.detachmentId}:{}})}function Xm(e){return ut(`approve:${e}`,"/api/v1/command-plane/policy/approve",{decision_id:e})}function Zm(e){return ut(`deny:${e}`,"/api/v1/command-plane/policy/deny",{decision_id:e})}function ev(e,t){return ut(`freeze:${e}`,"/api/v1/command-plane/policy/freeze",{unit_id:e,enabled:t})}function tv(e,t){return ut(`kill:${e}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:e,enabled:t})}fp(()=>{Ot(),Qt(),(G.value==="swarm"||G.value==="warroom"||G.value==="orchestra"||Pt.value!==null)&&Qe(),(G.value==="orchestra"||ni.value!==null)&&St(),G.value==="warroom"&&ye()});function No(e){e==="command"&&(Ot(),Qt(),(G.value==="swarm"||G.value==="warroom"||G.value==="orchestra")&&Qe(),G.value==="orchestra"&&St(),G.value==="warroom"&&ye()),e==="mission"&&(kl(),Qs()),e==="proof"&&Sl(F.value.params.session_id,F.value.params.operation_id),e==="execution"&&kt(),e==="intervene"&&(ye(),Tt()),e==="memory"&&et(),e==="planning"&&Zo(),e==="lab"&&tt()}function nv({metric:e}){return o`
    <article class="semantic-metric-row">
      <div class="semantic-metric-head">
        <strong>${e.label}</strong>
        <span class="semantic-code">${e.id}</span>
      </div>
      <p>${e.what_it_measures}</p>
      <div class="semantic-grid compact">
        <span>Why</span><span>${e.why_it_exists}</span>
        <span>Source</span><span>${e.source_path}</span>
        <span>Trigger</span><span>${e.update_trigger}</span>
        <span>Agent Effect</span><span>${e.agent_behavior_effect}</span>
        <span>Ecosystem</span><span>${e.ecosystem_effect}</span>
        <span>Interpret</span><span>${e.interpretation}</span>
        <span>Bad Smell</span><span>${e.bad_smell}</span>
        <span>Next</span><span>${e.next_action}</span>
      </div>
    </article>
  `}function sv({panel:e}){return o`
    <div class="semantic-body">
      <div class="semantic-grid">
        <span>Purpose</span><span>${e.purpose}</span>
        <span>Solves</span><span>${e.problem_solved}</span>
        <span>When</span><span>${e.when_active}</span>
        <span>Agent Role</span><span>${e.agent_role}</span>
        <span>Ecosystem</span><span>${e.ecosystem_function}</span>
      </div>
      ${e.related_tools.length>0?o`<div class="semantic-tag-row">
            ${e.related_tools.map(t=>o`<span class="semantic-tag">${t}</span>`)}
          </div>`:null}
      ${e.metrics.length>0?o`<div class="semantic-metric-list">
            ${e.metrics.map(t=>o`<${nv} key=${t.id} metric=${t} />`)}
          </div>`:null}
    </div>
  `}function O({panelId:e,compact:t=!1,label:n="Why"}){const s=vp(e);return s?o`
    <details class="semantic-inline ${t?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${sv} panel=${s} />
    </details>
  `:Hs.value?o`<span class="semantic-inline-state">Loading semantics…</span>`:null}function be({surfaceId:e,compact:t=!1}){const n=mp(e);return n?o`
    <section class="semantic-surface-card ${t?"compact":""}">
      <div class="semantic-surface-head">
        <strong>${n.label}</strong>
        <span class="semantic-code">${n.id}</span>
      </div>
      <p class="semantic-lead">${n.purpose}</p>
      <div class="semantic-grid">
        <span>Solves</span><span>${n.problem_solved}</span>
        <span>When</span><span>${n.when_active}</span>
        <span>Agent Role</span><span>${n.agent_role}</span>
        <span>Ecosystem</span><span>${n.ecosystem_function}</span>
      </div>
      ${n.panels.length>0?o`<div class="semantic-tag-row">
            ${n.panels.map(s=>o`<span class="semantic-tag">${s.title}</span>`)}
          </div>`:null}
    </section>
  `:Hs.value?o`<div class="semantic-surface-card ${t?"compact":""}">Loading semantics…</div>`:Ws.value?o`<div class="semantic-surface-card ${t?"compact":""}">${Ws.value}</div>`:null}function I({title:e,class:t,semanticId:n,testId:s,children:a}){return o`
    <div class="card ${t??""}" data-testid=${s}>
      ${e?o`
            <div class="card-title-row">
              <div class="card-title">${e}</div>
              ${n?o`<${O} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}const la="masc_dashboard_workflow_context",av=900*1e3;function fe(e){return typeof e=="string"&&e.trim()!==""?e.trim():null}function Ge(e){const t=fe(e);return t||(typeof e=="number"&&Number.isFinite(e)?String(e):null)}function ql(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function Eo(e){return v(e)?e:null}function ov(e){if(!e)return null;try{return JSON.stringify(e)}catch{return null}}function iv(e){if(!e)return null;try{const t=JSON.parse(e);if(!v(t))return null;const n=fe(t.id),s=fe(t.source_surface),a=fe(t.source_label),i=fe(t.summary),l=fe(t.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!i||!l?null:{id:n,source_surface:s,source_label:a,action_type:fe(t.action_type),target_type:fe(t.target_type),target_id:fe(t.target_id),focus_kind:fe(t.focus_kind),operation_id:fe(t.operation_id),command_surface:fe(t.command_surface),summary:i,payload_preview:fe(t.payload_preview),suggested_payload:Eo(t.suggested_payload),preview:t.preview??null,evidence:t.evidence??null,created_at:l}}catch{return null}}function li(e){const t=Date.parse(e.created_at);return Number.isNaN(t)?!1:Date.now()-t<=av}function rv(){const e=ql(),t=iv((e==null?void 0:e.getItem(la))??null);return t?li(t)?t:(e==null||e.removeItem(la),null):null}const Fl=g(rv());function Kl(e){const t=e&&li(e)?e:null;Fl.value=t;const n=ql();if(!n)return;if(!t){n.removeItem(la);return}const s=ov(t);s&&n.setItem(la,s)}function lv(e){if(!e)return null;const t=Eo(e.suggested_payload);if(t)return t;if(v(e.preview)){const n=Eo(e.preview.payload);if(n)return n}return null}function cv(e){if(!e)return null;const t=Ge(e.message);if(t)return t;const n=Ge(e.task_title)??Ge(e.title),s=Ge(e.task_description)??Ge(e.description),a=Ge(e.reason),i=Ge(e.priority)??Ge(e.task_priority);return n&&s?`${n} · ${s}`:n&&i?`${n} · P${i}`:n||s||a||null}function ci(e,t,n,s,a,i,l,c){return[e,t,n??"action",s??"target",a??"room",i??"focus",l??"operation",c].join(":")}function dn(e,t,n="상황판 추천 액션"){const s=new Date().toISOString(),a=lv(e),i=(e==null?void 0:e.target_type)??(t==null?void 0:t.target_type)??null,l=(e==null?void 0:e.target_id)??(t==null?void 0:t.target_id)??null,c=(t==null?void 0:t.kind)??(e==null?void 0:e.action_type)??null,p=(e==null?void 0:e.reason)??(t==null?void 0:t.summary)??n;return{id:ci("mission",n,(e==null?void 0:e.action_type)??null,i,l,c,null,s),source_surface:"mission",source_label:n,action_type:(e==null?void 0:e.action_type)??null,target_type:i,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:p,payload_preview:cv(a),suggested_payload:a,preview:(e==null?void 0:e.preview)??null,evidence:(t==null?void 0:t.evidence)??null,created_at:s}}function dv({targetType:e,targetId:t,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:i=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:ci("execution",s,null,e,t,n,i,c),source_surface:"execution",source_label:s,action_type:null,target_type:e,target_id:t,focus_kind:n,operation_id:i,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function uv(e,t){return(t.source==="mission"||t.source==="execution")&&(t.action_type??null)===(e.action_type??null)&&(t.target_type??null)===(e.target_type??null)&&(t.target_id??null)===(e.target_id??null)&&(t.focus_kind??null)===(e.focus_kind??null)&&(t.operation_id??null)===(e.operation_id??null)}function ts(e){const{params:t}=e;if(t.source!=="mission"&&t.source!=="execution")return null;const n=Fl.value;if(n&&li(n)&&uv(n,t))return n;const s=new Date().toISOString(),a=t.source==="execution"?"execution":"mission";return{id:ci(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",t.action_type??null,t.target_type??null,t.target_id??null,t.focus_kind??null,t.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:t.action_type??null,target_type:t.target_type??null,target_id:t.target_id??null,focus_kind:t.focus_kind??t.action_type??null,operation_id:t.operation_id??null,command_surface:t.surface??null,summary:a==="execution"?t.focus_kind?`${t.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":t.focus_kind?`${t.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function Bl(e){return{source:e.source_surface,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function Ul(e){if(e.command_surface)return e.command_surface;const t=[e.focus_kind,e.summary,e.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"summary":t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")||t.includes("swarm")?"swarm":e.focus_kind==="operation"||e.target_type==="operation"?"operations":e.target_type==="room"?"orchestra":"swarm"}function Hl(e){return{source:e.source_surface,surface:Ul(e),...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function pv(e){return Bl(e)}function mv(e){return Hl(e)}function di(e){return e!=null&&e.target_type?e.target_id?`${e.target_type} · ${e.target_id}`:e.target_type:"대상 정보 없음"}function La(e){switch(e){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(e==null?void 0:e.trim())||"추천 액션"}}function vv(e){switch(e){case"warroom":return"워룸";case"summary":return"요약";case"orchestra":return"오케스트라";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(e==null?void 0:e.trim())||"지휘"}}const Fe=g(null),Ye=g(null);function Re(e,t=120){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-1)}…`:n:null}function ve(e){return e==="bad"||e==="offline"||e==="critical"||e==="risk"?"bad":e==="warn"||e==="pending"||e==="degraded"||e==="interrupted"||e==="watch"?"warn":"ok"}function Ee(e){if(!e)return"방금";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:n<86400?`${Math.round(n/3600)}h 전`:`${Math.round(n/86400)}d 전`}function _v(e){return typeof e!="number"||!Number.isFinite(e)||e<0?"n/a":e<60?`${Math.round(e)}s`:e<3600?`${Math.round(e/60)}m`:e<86400?`${Math.round(e/3600)}h`:`${Math.round(e/86400)}d`}function gv(e){return e!=null&&e.confirm_required?"확인 후 실행":"즉시 실행"}function fv(e){return di(e?dn(e,null,"상황판 추천 액션"):null)}function za(e,t=dn()){Kl(t),se(e,e==="intervene"?pv(t):mv(t))}function Wl(e){za("intervene",dn(null,e,"상황판 incident"))}function Gl(e){za("command",dn(null,e,"상황판 incident"))}function ui(e,t,n="상황판 추천 액션"){za("intervene",dn(e,t,n))}function Jl(e,t,n="상황판 추천 액션"){za("command",dn(e,t,n))}function jo(e,t){const n={source:"mission",target_type:"team_session",target_id:t,focus_kind:"team_session"};e==="command"&&(n.surface="swarm"),se(e,n)}function $v(e){return{kind:e.kind,severity:e.severity,summary:e.summary,target_type:e.target_type,target_id:e.target_id??null,actor:null,evidence:e.evidence_preview}}function hv(e){var n,s;const t=dt.value.find(a=>a.name===e.name||a.agent_name===e.agent_name)??null;return{brief:e,keeper:t,currentWork:Re(e.current_work,110)??Re(t==null?void 0:t.skill_primary,110)??Re(t==null?void 0:t.last_proactive_reason,110)??"명시된 keeper focus 없음",recentInput:Re(t==null?void 0:t.recent_input_preview,120)??null,recentOutput:Re(t==null?void 0:t.recent_output_preview,120)??Re((n=t==null?void 0:t.diagnostic)==null?void 0:n.last_reply_preview,120)??Re(t==null?void 0:t.last_proactive_preview,120)??null,recentEvent:Re(t==null?void 0:t.last_proactive_reason,120)??Re((s=t==null?void 0:t.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(t==null?void 0:t.recent_tool_names)??[]}}function yv(){const e=Xn.value;if(!e)return new Map;const t=e.sessions.length>0?e.sessions:e.session_briefs;return new Map(t.map(n=>[n.session_id,n]))}function bv(e){Fe.value=Fe.value===e?null:e,Ye.value=null}function Vl(e){Ye.value=Ye.value===e?null:e,Fe.value=null}function kv(){Fe.value=null,Ye.value=null}function pt({status:e,label:t}){return o`
    <span class="status-badge ${e}">
      <span class="status-dot-inline ${e}"></span>
      ${t??e}
    </span>
  `}function Ql(e){const t=Date.now(),n=typeof e=="number"?e<1e12?e*1e3:e:new Date(e).getTime(),s=Math.floor((t-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function J({timestamp:e}){const t=Ql(e),n=typeof e=="string"?e:new Date(e<1e12?e*1e3:e).toISOString();return o`<span class="time-ago" title=${n}>${t}</span>`}let xv=0;const At=g([]);function E(e,t="success",n=4e3){const s=++xv;At.value=[...At.value,{id:s,message:e,type:t}],setTimeout(()=>{At.value=At.value.filter(a=>a.id!==s)},n)}function Sv(e){At.value=At.value.filter(t=>t.id!==e)}function Av(){const e=At.value;return e.length===0?null:o`
    <div class="toast-container">
      ${e.map(t=>o`
        <div key=${t.id} class="toast ${t.type}" onClick=${()=>Sv(t.id)}>
          ${t.message}
        </div>
      `)}
    </div>
  `}const Cv="masc_dashboard_agent_name",un=g(null),ca=g(!1),wn=g(""),da=g([]),Dn=g([]),Yt=g(""),Sn=g(!1);function Ma(e){un.value=e,pi()}function Ui(){un.value=null,wn.value="",da.value=[],Dn.value=[],Yt.value=""}function Iv(){const e=un.value;return e?He.value.find(t=>t.name===e)??null:null}function Yl(e){return e?Xe.value.filter(t=>t.assignee===e):[]}function Xl(e){return e?dt.value.find(t=>t.agent_name===e||t.name===e)??null:null}function Tv(e){if(!e)return null;const t=Xn.value;return t?t.agent_briefs.find(n=>n.agent_name===e)??null:null}function Rv(e){if(!e)return[];const t=e.metrics_window;return(Array.isArray(t==null?void 0:t.top_tools)?t.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Pv(e){const t=Xl(e);return t?t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]:[]}async function pi(){const e=un.value;if(e){ca.value=!0,wn.value="",da.value=[],Dn.value=[];try{const t=await mu(80);da.value=t.filter(a=>a.includes(e)).slice(0,20);const n=Yl(e).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await vu(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const l=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));Dn.value=s}catch(t){wn.value=t instanceof Error?t.message:"Failed to load agent detail"}finally{ca.value=!1}}}async function Hi(){var s;const e=un.value,t=Yt.value.trim();if(!e||!t)return;const n=((s=localStorage.getItem(Cv))==null?void 0:s.trim())||"dashboard";Sn.value=!0;try{await pu(n,`@${e} ${t}`),Yt.value="",E(`Mention sent to ${e}`,"success"),pi()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";E(i,"error")}finally{Sn.value=!1}}function Lv({task:e}){return o`
    <div class="agent-detail-task">
      <span class="pill">${e.id}</span>
      <span class="agent-detail-task-title">${e.title}</span>
      <${pt} status=${e.status} />
    </div>
  `}function zv({row:e}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${e.taskId}</span>
      </div>
      <pre class="agent-history-pre">${e.text||"No task history yet"}</pre>
    </div>
  `}function Mv(){var A,x,z,T,P,M,R;const e=un.value;if(!e)return null;const t=Iv(),n=Xl(e),s=Tv(e),a=Yl(e),i=da.value,l=Pv(e),c=Rv(n),p=(s==null?void 0:s.allowed_tool_names)??[],m=(s==null?void 0:s.latest_tool_names)??[],u=s==null?void 0:s.latest_tool_call_count,_=s==null?void 0:s.tool_audit_source,f=s==null?void 0:s.tool_audit_at,h=(t==null?void 0:t.capabilities)??[],b=((A=te.value)==null?void 0:A.room)??"default",$=((x=te.value)==null?void 0:x.project)??"확인 없음",S=((z=te.value)==null?void 0:z.cluster)??"확인 없음";return o`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${N=>{N.target.classList.contains("agent-detail-overlay")&&Ui()}}
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
                        <${pt} status=${t.status} />
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
            ${(((T=t==null?void 0:t.traits)==null?void 0:T.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(P=t==null?void 0:t.traits)==null?void 0:P.map(N=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${N}</span>`)}
              </div>
            `:""}
            ${(((M=t==null?void 0:t.interests)==null?void 0:M.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(R=t==null?void 0:t.interests)==null?void 0:R.map(N=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${N}</span>`)}
              </div>
            `:""}
            ${h.length>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${h.map(N=>o`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${N}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${t?o`
                    ${t.current_task?o`<span>Task: ${t.current_task}</span>`:null}
                    ${t.last_seen?o`<span>Last seen: <${J} timestamp=${t.last_seen} /></span>`:null}
                    <span>Room: ${b}</span>
                    <span>Project: ${$}</span>
                    <span>Cluster: ${S}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{pi()}} disabled=${ca.value}>
              ${ca.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Ui}>Close</button>
          </div>
        </div>

        ${wn.value?o`<div class="council-error">${wn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${I} title="Assigned Tasks">
            ${a.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${a.map(N=>o`<${Lv} key=${N.id} task=${N} />`)}</div>`}
          <//>

          <${I} title="Recent Activity">
            ${i.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${i.map((N,Z)=>o`<div key=${Z} class="agent-activity-line">${N}</div>`)}</div>`}
          <//>
        </div>

        <${I} title="Capabilities & Tool Audit">
          <div style="display:flex; flex-direction:column; gap:12px;">
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Capabilities</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${h.length>0?h.map(N=>o`<span class="pill">${N}</span>`):o`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Allowed tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${p.length>0?p.map(N=>o`<span class="pill">${N}</span>`):o`<span class="empty-state" style="font-size:12px;">No allowlist reported</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Observed tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${m.length>0?m.map(N=>o`<span class="pill">${N}</span>`):o`<span class="empty-state" style="font-size:12px;">No observed tool-use evidence</span>`}
              </div>
            </div>
            <div class="agent-detail-sub">
              <span>Tool calls: ${typeof u=="number"?u:"—"}</span>
              <span>Evidence source: ${_??"unreported"}</span>
              <span>
                Observed at:
                ${f?o` <${J} timestamp=${f} />`:" unreported"}
              </span>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Linked keeper recent tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${l.length>0?l.map(N=>o`<span class="pill">${N}</span>`):o`<span class="empty-state" style="font-size:12px;">No keeper tool telemetry</span>`}
              </div>
            </div>
            ${c.length>0?o`
                  <div>
                    <div style="font-size:12px; color:#888; margin-bottom:6px;">Keeper window top tools</div>
                    <div style="display:flex; flex-wrap:wrap; gap:6px;">
                      ${c.map(N=>o`<span class="pill">${N}</span>`)}
                    </div>
                  </div>
                `:null}
            ${n?o`
                  <div style="font-size:12px; color:#888;">
                    Linked keeper: <span style="color:#4ade80;">${n.name}</span>
                    ${n.skill_primary?o` · route <span style="color:#22d3ee;">${n.skill_primary}</span>`:null}
                  </div>
                `:null}
          </div>
        <//>

        <${I} title="Task History">
          ${Dn.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Dn.value.map(N=>o`<${zv} key=${N.taskId} row=${N} />`)}</div>`}
        <//>

        <${I} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Yt.value}
              onInput=${N=>{Yt.value=N.target.value}}
              onKeyDown=${N=>{N.key==="Enter"&&Hi()}}
              disabled=${Sn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Hi()}}
              disabled=${Sn.value||Yt.value.trim()===""}
            >
              ${Sn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Nv(e){switch(e){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Ev(e){switch(e){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function jv(e){switch(e.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return e.role}}function Wi(e){return e.delivery==="error"||e.delivery==="timeout"?"bad":e.delivery==="sending"?"warn":e.role==="assistant"?"assistant":e.role==="user"?"user":"warn"}function Zl(e){if(!e)return null;const t=new Date(e);return Number.isNaN(t.getTime())?null:t.toLocaleTimeString()}function wv(e){return typeof e!="number"||!Number.isFinite(e)||e<=0?null:e<60?`${Math.round(e)}s`:`${Math.ceil(e/60)}m`}function ec(e){if(!e)return null;const t=Be.value[e.name];return(t==null?void 0:t.diagnostic)??e.diagnostic??null}function Dv({keeper:e,showRawStatus:t=!1}){if(ne(()=>{e!=null&&e.name&&Ur(e.name)},[e==null?void 0:e.name]),!e)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Be.value[e.name],s=ec(e),a=$o.value[e.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Nv(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Ev((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?o` · ${Zl(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?o` · next eligible ${wv(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?o`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${t?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Ov({keeperName:e,placeholder:t}){const[n,s]=xr("");ne(()=>{e&&Ur(e)},[e]);const a=de.value[e]??[],i=ho.value[e]??!1,l=Ue.value[e],c=async()=>{const p=n.trim();if(!(!e||!p)){s("");try{await Nu(e,p)}catch(m){const u=m instanceof Error?m.message:`Failed to message ${e}`;E(u,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(p=>o`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Wi(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${Wi(p)}`}>${jv(p)}</span>
                  ${p.timestamp?o`<span class="keeper-conversation-time">${Zl(p.timestamp)}</span>`:null}
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
  `}function qv({actor:e,keeper:t,onPokeLodge:n}){if(!t)return null;const s=ec(t),a=yo.value[t.name]??!1,i=bo.value[t.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{Eu(t.name,e).catch(p=>{const m=p instanceof Error?p.message:`Failed to probe ${t.name}`;E(m,"error")})}}
        disabled=${a||!e.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{ju(t.name,e).catch(p=>{const m=p instanceof Error?p.message:`Failed to recover ${t.name}`;E(m,"error")})}}
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
  `}const mi=g(null);function tc(e){mi.value=e,Mu(e.name)}function Gi(){mi.value=null}const Nt=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Fv(e){if(!e)return 0;const t=Nt.findIndex(n=>n.level===e);return t>=0?t:0}function Kv({keeper:e}){const t=Fv(e.autonomy_level),n=Nt[t]??Nt[0];if(!n)return null;const s=(t+1)/Nt.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${t+1} / ${Nt.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Nt.map((a,i)=>o`
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
            <strong><${J} timestamp=${e.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${e.active_goal_ids&&e.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${e.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Es(e){return e?e>=1e6?`${(e/1e6).toFixed(1)}M`:e>=1e3?`${(e/1e3).toFixed(1)}K`:String(e):"—"}function Bv(e){switch(e){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(e==null?void 0:e.trim())||"action"}}function Uv(e){return e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]}function Hv(e){const t=e.metrics_window;return(Array.isArray(t==null?void 0:t.top_tools)?t.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Wv(e){const t=Xn.value;return t?t.keeper_briefs.find(n=>n.name===e.name||n.agent_name&&e.agent_name&&n.agent_name===e.agent_name)??null:null}function Gv({keeper:e}){const t=e.metrics_series??[],n=t[t.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:e.generation??"-",hint:"Succession count"},{label:"Turns",value:e.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:e.context_ratio!=null?`${Math.round(e.context_ratio*100)}%`:"-",hint:e.context_ratio!=null&&e.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:e.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Es(e.context_tokens)}</div>
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
  `}function Jv({keeper:e}){var u,_;const t=e.metrics_series??[];if(t.length<2){const f=(((u=e.context)==null?void 0:u.context_ratio)??0)*100,h=f>85?"#ef4444":f>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${f.toFixed(1)}%;background:${h}"></div>
        </div>
        <span class="chart-pct">${f.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=t.length,l=t.map((f,h)=>{const b=a+h/(i-1)*(n-2*a),$=s-a-(f.context_ratio??0)*(s-2*a);return{x:b,y:$,p:f}}),c=l.map(({x:f,y:h})=>`${f.toFixed(1)},${h.toFixed(1)}`).join(" "),p=(((_=t[t.length-1])==null?void 0:_.context_ratio)??0)*100,m=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:f})=>f.is_handoff).map(({x:f})=>o`
          <line x1="${f.toFixed(1)}" y1="${a}" x2="${f.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${m}" stroke-width="1.5"/>
        ${l.filter(({p:f})=>f.is_compaction).map(({x:f,y:h})=>o`
          <circle cx="${f.toFixed(1)}" cy="${h.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}const Fa=g("");function Vv({keeper:e}){var a,i,l,c;const t=Fa.value.toLowerCase(),n=[{title:"Name",key:"name",value:e.name},{title:"Emoji",key:"emoji",value:e.emoji??"-"},{title:"Korean",key:"koreanName",value:e.koreanName??"-"},{title:"Model",key:"model",value:e.model??"-"},{title:"Status",key:"status",value:e.status},{title:"Primary",key:"primaryValue",value:e.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(e.activityLevel??"-")},{title:"Gen",key:"generation",value:String(e.generation??"-")},{title:"Turns",key:"turn_count",value:String(e.turn_count??"-")},{title:"Context",key:"context_ratio",value:e.context_ratio!=null?`${Math.round(e.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:e.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=e.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=e.interests)==null?void 0:i.join(", "))||"-"}],s=t?n.filter(p=>p.title.toLowerCase().includes(t)||p.key.includes(t)||p.value.toLowerCase().includes(t)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Fa.value}
        onInput=${p=>{Fa.value=p.target.value}}
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
      ${e.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Es(e.context_tokens)}</span></div>`:""}
      ${e.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Es(e.context_max)}</span></div>`:""}
      ${e.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${e.memory_recent_note}</span></div>`:""}
      ${e.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${e.k2k_count}</span></div>`:""}
      ${e.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${e.conversation_tail_count}</span></div>`:""}
      ${e.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${e.handoff_count_total}</span></div>`:""}
      ${e.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${e.compaction_count}</span></div>`:""}
      ${e.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Es(e.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=e.context)==null?void 0:l.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${e.context.message_count}</span></div>`:""}
      ${((c=e.context)==null?void 0:c.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${e.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Qv({stats:e}){const t=e.max_hp>0?Math.round(e.hp/e.max_hp*100):0,n=e.max_mp>0?Math.round(e.mp/e.max_mp*100):0;return o`
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
  `}function Yv({items:e}){return e.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${e.map((t,n)=>o`
        <div class="keeper-equipment-row">
          <span>${t}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Xv({rels:e}){const t=Object.entries(e);return t.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${t.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Ji({traits:e,label:t}){return e.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${t}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${e.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Ka(e){return e==null||Number.isNaN(e)?"-":`${Math.round(e*100)}%`}function Zv({keeper:e}){const t=e.metrics_window,n=[{label:"Model fallback",value:Ka(typeof(t==null?void 0:t.model_fallback_rate)=="number"?t.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Ka(typeof(t==null?void 0:t.proactive_fallback_rate)=="number"?t.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Ka(typeof(t==null?void 0:t.memory_pass_rate)=="number"?t.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(t==null?void 0:t.handoff_count)=="number"?t.handoff_count:e.handoff_count_total??"-"},{label:"Compactions",value:typeof(t==null?void 0:t.compaction_events)=="number"?t.compaction_events:e.compaction_count??"-"},{label:"Saved tokens",value:typeof(t==null?void 0:t.compaction_saved_tokens)=="number"?t.compaction_saved_tokens:e.last_compaction_saved_tokens??"-"},{label:"K2K events",value:e.k2k_count??"-"},{label:"Conversation tail",value:e.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(t==null?void 0:t.tool_call_count)=="number"?t.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(t==null?void 0:t.proactive_preview_similarity_avg)=="number"?`${(t.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(t==null?void 0:t.memory_avg_score)=="number"?t.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(t==null?void 0:t.fallback_rate)=="number"?`${(t.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function e_({keeper:e}){var $,S,A,x,z,T,P;const t=(($=_e.value)==null?void 0:$.room)??{},n=(((S=_e.value)==null?void 0:S.available_actions)??[]).filter(M=>M.target_type==="keeper"||M.target_type==="room").slice(0,8),s=Uv(e),a=Hv(e),i=Wv(e),l=(i==null?void 0:i.allowed_tool_names)??[],c=(i==null?void 0:i.latest_tool_names)??[],p=i==null?void 0:i.latest_tool_call_count,m=i==null?void 0:i.tool_audit_source,u=i==null?void 0:i.tool_audit_at,_=((A=e.agent)==null?void 0:A.capabilities)??[],f=t.current_room??t.room_id??((x=te.value)==null?void 0:x.room)??"default",h=t.project??((z=te.value)==null?void 0:z.project)??"확인 없음",b=t.cluster??((T=te.value)==null?void 0:T.cluster)??"확인 없음";return o`
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
        <strong>${b}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Current task</span>
        <strong>${((P=e.agent)==null?void 0:P.current_task)??"없음"}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Skill route</span>
        <strong>${e.skill_primary??"미확인"}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Allowed tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${l.length>0?l.map(M=>o`<span class="pill">${M}</span>`):o`<span style="font-size:12px; color:#888;">allowlist 미보고</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Observed tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${c.length>0?c.map(M=>o`<span class="pill">${M}</span>`):o`<span style="font-size:12px; color:#888;">observed tool-use evidence 없음</span>`}
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
        <strong>${u?o`<${J} timestamp=${u} />`:"unreported"}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Keeper recent tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${s.length>0?s.map(M=>o`<span class="pill">${M}</span>`):o`<span style="font-size:12px; color:#888;">도구 텔레메트리 없음</span>`}
        </div>
      </div>
      ${a.length>0?o`
            <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
              <span style="font-size:12px; color:#888;">Window top tools</span>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${a.map(M=>o`<span class="pill">${M}</span>`)}
              </div>
            </div>
          `:null}
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${_.length>0?_.map(M=>o`<span class="pill">${M}</span>`):o`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(M=>o`<span class="pill">${Bv(M.action_type)}</span>`):o`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function nc(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(t??n??"dashboard").trim()||"dashboard"}async function t_(){try{const e=await Ia({actor:nc(),action_type:"lodge_tick",target_type:"room",payload:{}}),t=Br(e.result);await Yn(),t!=null&&t.skipped_reason?E(t.skipped_reason,"warning"):E(t?`Poke finished: ${t.acted}/${t.checked} acted`:"Poke finished",t&&t.acted>0?"success":"warning")}catch(e){const t=e instanceof Error?e.message:"Failed to run Lodge poke";E(t,"error")}}function n_({keeper:e}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Dv} keeper=${e} />
          <${qv}
            actor=${nc()}
            keeper=${e}
            onPokeLodge=${()=>{t_()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Ov}
            keeperName=${e.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function s_(){var t,n,s;const e=mi.value;return e?o`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Gi()}}
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
            <${pt} status=${e.status} />
            ${e.model?o`<span class="pill">${e.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Gi()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Gv} keeper=${e} />

        ${""}
        <${Jv} keeper=${e} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${I} title="Field Dictionary">
            <${Vv} keeper=${e} />
          <//>

          ${""}
          <${I} title="Profile">
            <${Ji} traits=${e.traits??[]} label="Traits" />
            <${Ji} traits=${e.interests??[]} label="Interests" />
            ${e.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${e.primaryValue}</span></div>`:null}
            ${e.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${e.skill_primary}</span>
                </div>`:null}
            ${e.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${e.skill_reason}</div>`:null}
            ${e.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${J} timestamp=${e.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${e.autonomy_level?o`
              <${I} title="Autonomy">
                <${Kv} keeper=${e} />
              <//>
            `:null}

          ${""}
          ${e.trpg_stats?o`
              <${I} title="TRPG Stats">
                <${Qv} stats=${e.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${e.inventory&&e.inventory.length>0?o`
              <${I} title="Equipment (${e.inventory.length})">
                <${Yv} items=${e.inventory} />
              <//>
            `:null}

          ${""}
          ${e.relationships&&Object.keys(e.relationships).length>0?o`
              <${I} title="Relationships (${Object.keys(e.relationships).length})">
                <${Xv} rels=${e.relationships} />
              <//>
            `:null}

          <${I} title="Runtime Signals">
            <${Zv} keeper=${e} />
          <//>

          <${I} title="Neighborhood & Tool Audit">
            <${e_} keeper=${e} />
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
        <${n_} keeper=${e} />
      </div>
    </div>
  `:null}function a_({cluster:e,project:t,room:n,generatedAt:s}){return o`
    <div class="mission-context-bar">
      <div class="mission-context-item">
        <span>cluster</span>
        <strong>${e??"확인 없음"}</strong>
      </div>
      <div class="mission-context-item">
        <span>project</span>
        <strong>${t??"확인 없음"}</strong>
      </div>
      <div class="mission-context-item">
        <span>room</span>
        <strong>${n??"default"}</strong>
      </div>
      <div class="mission-context-item">
        <span>generated</span>
        <strong>${s?Ee(s):"fresh"}</strong>
      </div>
    </div>
  `}function zt({label:e,value:t,detail:n,tone:s}){return o`
    <article class="mission-stat-card ${ve(s)}">
      <span class="mission-stat-label">${e}</span>
      <strong class="mission-stat-value">${t}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function o_(){const e=gl.value,t=ve((e==null?void 0:e.status)??(yt.value?"bad":"warn")),n=!e||e.sections.length===0,s=(e==null?void 0:e.status)==="error"||(e==null?void 0:e.status)==="unavailable"&&!(e!=null&&e.cached);return o`
    <${I} title="LLM 판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>heuristic 대신 별도 판단 계층</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${t}">
          ${(e==null?void 0:e.status)??(yt.value?"error":"loading")}
        </span>
        ${e!=null&&e.model?o`<span class="command-chip">${e.model}</span>`:null}
        ${e!=null&&e.generated_at?o`<span class="command-chip">${Ee(e.generated_at)}</span>`:null}
        ${e!=null&&e.cached?o`<span class="command-chip">cached</span>`:null}
        ${e!=null&&e.stale?o`<span class="command-chip warn">stale</span>`:null}
        ${e!=null&&e.refreshing?o`<span class="command-chip warn">refreshing</span>`:null}
      </div>

      ${yt.value?o`<div class="empty-state error">${yt.value}</div>`:null}
      ${e!=null&&e.error?o`<div class="empty-state error">${e.error}</div>`:null}
      ${e!=null&&e.summary?o`<div class="mission-inline-note">${e.summary}</div>`:null}
      ${e!=null&&e.last_error&&!e.error?o`<div class="mission-inline-note">최근 refresh 실패: ${e.last_error}</div>`:null}

      ${e&&e.sections.length>0?o`
            <div class="mission-briefing-grid">
              ${e.sections.slice(0,3).map(a=>o`
                <article class="mission-briefing-section ${ve(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${ve(a.status)}">${a.status}</span>
                      ${a.signal_class==="metadata_gap"?o`<span class="command-chip">metadata gap</span>`:a.signal_class==="mixed"?o`<span class="command-chip warn">mixed</span>`:null}
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
          `:!wt.value&&!yt.value&&n?o`
                <div class="empty-state">
                  ${(e==null?void 0:e.status)==="pending"?"최신 스냅샷으로 브리핑을 생성 중입니다. 마지막 성공 결과가 생기면 자동으로 다시 읽습니다.":"판단 레이어 결과가 아직 없습니다."}
                </div>
              `:null}

      ${e&&e.metadata_gaps.length>0?o`
            <details class="mission-card-disclosure compact mission-briefing-gaps">
              <summary>Observability Gaps (${e.metadata_gap_count??e.metadata_gaps.length})</summary>
              <div class="mission-list-stack">
                ${e.metadata_gaps.map(a=>o`
                  <article class="mission-briefing-gap ${a.severity==="watch"?"warn":""}">
                    <div class="mission-card-head">
                      <strong>${a.scope_type}${a.scope_id?` · ${a.scope_id}`:""}</strong>
                      <span class="command-chip ${a.severity==="watch"?"warn":""}">${a.severity}</span>
                    </div>
                    <p>${a.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{Qs(s)}} disabled=${wt.value}>
          ${wt.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{Qs(!0)}} disabled=${wt.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function i_({item:e,selected:t,sessionLookup:n}){const s=$v(e),a=e.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),i=e.top_action??null;return o`
    <article class="mission-attention-card ${ve((i==null?void 0:i.severity)??e.severity)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>bv(e.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${e.summary}</strong>
            <div class="mission-card-target">${e.kind}${e.target_id?` · ${e.target_id}`:""}</div>
          </div>
          <span class="command-chip ${ve((i==null?void 0:i.severity)??e.severity)}">${i?gv(i):e.severity}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>영향 session</span>
            <strong>${e.related_session_ids.length}</strong>
            <small>${e.related_session_ids.slice(0,2).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>영향 agent</span>
            <strong>${e.related_agent_names.length}</strong>
            <small>${e.related_agent_names.slice(0,3).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 신호</span>
            <strong>${e.last_seen_at?Ee(e.last_seen_at):"n/a"}</strong>
            <small>${e.target_type}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${i?La(i.action_type):"판단 필요"}</strong>
            <small>${i?fv(i):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${i?o`<div class="mission-inline-note">${i.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?o`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>o`
                  <button class="mission-link-row" onClick=${()=>Vl(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${l.status??"unknown"} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:o`<div class="empty-state">직접 연결된 session이 아직 없습니다.</div>`}

        ${e.related_agent_names.length>0?o`
              <div class="mission-pill-row">
                ${e.related_agent_names.slice(0,8).map(l=>o`
                  <button class="mission-pill action" onClick=${()=>Ma(l)}>${l}</button>
                `)}
              </div>
            `:null}

        ${e.evidence_preview.length>0?o`
              <details class="mission-card-disclosure compact">
                <summary>evidence preview</summary>
                <div class="mission-evidence-list">
                  ${e.evidence_preview.map(l=>o`<span>${l}</span>`)}
                </div>
              </details>
            `:null}
      </details>

      <div class="mission-card-actions">
        ${i?o`
              <button class="control-btn ghost" onClick=${()=>ui(i,s,"Mission attention")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>Jl(i,s,"Mission attention")}>
                원인 보기
              </button>
            `:o`
              <button class="control-btn ghost" onClick=${()=>Wl(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Gl(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function r_({brief:e,selected:t}){var i,l;const n=e.member_previews.slice(0,4),s=e.top_recommendation??null,a=e.top_attention??null;return o`
    <article class="mission-crew-card ${ve(((i=e.top_attention)==null?void 0:i.severity)??e.health??e.status)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Vl(e.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${e.goal}</strong>
            <div class="mission-card-target">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          </div>
          <span class="command-chip ${ve(((l=e.top_attention)==null?void 0:l.severity)??e.health??e.status)}">${e.status??"unknown"}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${e.member_names.length}</strong>
            <small>${e.member_names.slice(0,3).join(", ")||"n/a"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${_v(e.elapsed_sec)}</strong>
            <small>${e.started_at?`${Ee(e.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 흐름</span>
            <strong>${e.last_event_at?Ee(e.last_event_at):"n/a"}</strong>
            <small>${e.communication_summary??"요약 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>커버리지</span>
            <strong>${e.active_count??0}/${e.required_count||1}</strong>
            <small>active / required</small>
          </div>
        </div>
      </button>

      ${e.blocker_summary?o`<div class="mission-inline-note">막힘 · ${e.blocker_summary}</div>`:null}

      <div class="mission-crew-event">
        <span>최근 사건</span>
        <strong>${e.last_event_summary??"최근 session event가 없습니다."}</strong>
        <small>${e.last_event_at?Ee(e.last_event_at):"시각 없음"}</small>
      </div>

      ${e.operation_badges.length>0?o`
            <div class="mission-pill-row">
              ${e.operation_badges.slice(0,3).map(c=>o`
                <span class="mission-pill">
                  ${c.operation_id} · ${c.status??"unknown"}${c.stage?` · ${c.stage}`:""}
                </span>
              `)}
            </div>
          `:null}

      ${n.length>0?o`
            <div class="mission-member-preview-grid">
              ${n.map(c=>o`
                <button class="mission-member-preview" onClick=${()=>Ma(c.agent_name)}>
                  <strong>${c.agent_name}</strong>
                  <span>${c.current_work??"현재 작업 없음"}</span>
                  <small>${c.recent_output_preview??c.recent_input_preview??"최근 입출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>jo("intervene",e.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>jo("command",e.session_id)}>세션 원인 보기</button>
        ${s?o`<button class="control-btn ghost" onClick=${()=>ui(s,a,"Mission session brief")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function l_({detail:e,loading:t,error:n}){if(t&&!e)return o`
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
                      <span>${a.timestamp?Ee(a.timestamp):"n/a"}</span>
                    </div>
                    <small>${a.actor?`${a.actor} · `:""}${a.event_type??"event"}</small>
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
                  <button class="mission-member-preview" onClick=${()=>Ma(a.agent_name)}>
                    <strong>${a.agent_name}</strong>
                    <span>${a.current_work??"현재 작업 없음"}</span>
                    <small>
                      ${a.recent_output_preview??a.recent_input_preview??"최근 입출력 없음"}
                      ${a.last_activity_at?` · ${Ee(a.last_activity_at)}`:""}
                    </small>
                  </button>
                `):o`<div class="empty-state">세션 참여자 미리보기가 없습니다.</div>`}
          </div>
        </div>
      </div>

      <div class="mission-detail-grid">
        <div class="mission-detail-column">
          <div class="mission-card-head">
            <strong>연결된 operation</strong>
            <span class="command-chip">${e.operations.length}</span>
          </div>
          <div class="mission-link-list">
            ${e.operations.length>0?e.operations.map(a=>o`
                  <button class="mission-link-row" onClick=${()=>jo("command",s.session_id)}>
                    <strong>${a.operation_id}</strong>
                    <span>${a.status??"unknown"}${a.stage?` · ${a.stage}`:""}</span>
                    <small>${a.detachment_status??a.objective??"detachment 정보 없음"}</small>
                  </button>
                `):o`<div class="empty-state">연결된 operation이 없습니다.</div>`}
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
                    <span>${a.status??"unknown"}${a.generation!=null?` · gen ${a.generation}`:""}</span>
                    <small>${a.current_work??"current work 없음"}</small>
                  </div>
                `):o`<div class="empty-state">직접 연결된 keeper는 없습니다.</div>`}
          </div>
        </div>
      </div>
    <//>
  `}function c_({row:e}){var n,s,a,i,l,c,p,m,u,_;const t=[`gen ${e.brief.generation??((n=e.keeper)==null?void 0:n.generation)??0}`,e.brief.context_ratio!=null?`ctx ${Math.round(e.brief.context_ratio*100)}%`:((s=e.keeper)==null?void 0:s.context_ratio)!=null?`ctx ${Math.round(e.keeper.context_ratio*100)}%`:null,e.brief.last_turn_ago_s!=null?`last turn ${Math.round(e.brief.last_turn_ago_s)}s`:null].filter(f=>f!==null).join(" · ");return o`
    <article class="mission-activity-card ${ve(e.brief.status??((a=e.keeper)==null?void 0:a.status))}">
      <button class="mission-card-select" onClick=${()=>{e.keeper&&tc(e.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((i=e.keeper)==null?void 0:i.emoji)??""}</span>
            <div>
              <strong>${e.brief.name}</strong>
              ${(l=e.keeper)!=null&&l.koreanName?o`<span>${e.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${ve(e.brief.status??((c=e.keeper)==null?void 0:c.status))}">${e.brief.status??((p=e.keeper)==null?void 0:p.status)??"unknown"}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 heartbeat · ${(m=e.keeper)!=null&&m.last_heartbeat?Ee(e.keeper.last_heartbeat):"n/a"}</span>
          <span>${t||"continuity 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${e.currentWork}</strong>
          ${(u=e.keeper)!=null&&u.skill_reason?o`<small>판단 요약 · ${Re(e.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>continuity detail</summary>
        <div class="mission-activity-foot">
          <span>agent · ${e.brief.agent_name??((_=e.keeper)==null?void 0:_.agent_name)??"n/a"}</span>
          ${e.recentEvent?o`<span>최근 일 · ${e.recentEvent}</span>`:null}
        </div>
        <details class="mission-card-disclosure compact">
          <summary>input / output / tools</summary>
          <div class="mission-io-stack">
            <div class="mission-io-item">
              <span>최근 input</span>
              <strong>${e.recentInput??"표시 가능한 recent input 없음"}</strong>
            </div>
            <div class="mission-io-item">
              <span>최근 output</span>
              <strong>${e.recentOutput??"표시 가능한 recent output 없음"}</strong>
            </div>
          </div>
          <div class="mission-activity-foot">
            <span>최근 도구 · ${e.recentTools.length>0?e.recentTools.join(", "):"도구 사용 없음"}</span>
          </div>
        </details>
      </details>
    </article>
  `}function d_({item:e}){const t=e.action??null,n=e.attention??null;return o`
    <article class="mission-action-card ${ve(e.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${ve(e.severity)}">
          ${e.signal_type==="action"&&t?La(t.action_type):(n==null?void 0:n.kind)??"signal"}
        </span>
        <span class="mission-card-target">${e.target_type}${e.target_id?` · ${e.target_id}`:""}</span>
      </div>
      <p>${e.summary}</p>
      ${t?o`<div class="mission-action-preview">${t.reason}</div>`:null}
      <div class="mission-card-actions">
        ${t?o`
              <button class="control-btn ghost" onClick=${()=>ui(t,n,"Mission internal signal")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Jl(t,n,"Mission internal signal")}>이 이슈의 원인 보기</button>
            `:n?o`
                <button class="control-btn ghost" onClick=${()=>Wl(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>Gl(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function Vi(){var h,b,$,S;const e=Xn.value;if(Io.value&&!e)return o`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(Vs.value&&!e)return o`<div class="empty-state error">${Vs.value}</div>`;if(!e)return o`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;Fe.value&&!e.attention_queue.some(A=>A.id===Fe.value)&&(Fe.value=null);const t=e.sessions;Ye.value&&!t.some(A=>A.session_id===Ye.value)&&(Ye.value=null);const n=e.attention_queue.find(A=>A.id===Fe.value)??null,s=(n==null?void 0:n.related_session_ids.find(A=>t.some(x=>x.session_id===A)))??null,a=Ye.value??s??((h=t[0])==null?void 0:h.session_id)??null,i=yv(),l=t.find(A=>A.session_id===a)??null,c=e.keeper_briefs.slice(0,6).map(hv),p=e.attention_queue.filter(A=>A.related_session_ids.length>0).slice(0,6),m=e.internal_signals.slice(0,3),u=t.filter(A=>{var z;const x=((z=A.top_attention)==null?void 0:z.severity)??A.health??A.status;return ve(x)!=="ok"||!!A.blocker_summary}).length,_=new Set(t.flatMap(A=>A.member_names)).size,f=t.flatMap(A=>A.member_previews??[]).filter(A=>A.recent_output_preview).length+c.filter(A=>A.recentOutput).length;return ne(()=>{Yp(a)},[a]),o`
    <section class="dashboard-panel mission-view">
      <${be} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 어떤 세션이 돌고 있고, 누가 참여하며, 어디가 막혔는지를 한 시점에서 읽는 기본 관찰면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${ve(e.summary.room_health)}">${e.summary.room_health??"ok"}</span>
          <span class="command-chip">${e.summary.project??"room"}${e.summary.current_room?` · ${e.summary.current_room}`:""}</span>
          <span class="command-chip">${e.generated_at?Ee(e.generated_at):"fresh"}</span>
        </div>
      </div>

      <${a_}
        cluster=${e.summary.cluster}
        project=${e.summary.project}
        room=${e.summary.current_room}
        generatedAt=${e.generated_at}
      />

      <${o_} />

      <div class="mission-stat-grid">
        <${zt} label="활성 세션" value=${t.length} detail="지금 진행중인 협업 단위" tone=${((b=l==null?void 0:l.top_attention)==null?void 0:b.severity)??(l==null?void 0:l.health)??"ok"} />
        <${zt} label="막힌 세션" value=${u} detail="주의가 필요한 흐름" tone=${u>0?"warn":"ok"} />
        <${zt} label="참여자" value=${_} detail="현재 세션에 연결된 actor" tone=${_>0?"ok":"warn"} />
        <${zt} label="Keeper watch" value=${c.length} detail="continuity lane 관찰 대상" tone=${(($=c[0])==null?void 0:$.brief.status)??"ok"} />
        <${zt} label="최근 output" value=${f} detail="메인에서 바로 읽을 수 있는 출력 수" tone=${f>0?"ok":"warn"} />
        <${zt} label="내부 신호" value=${m.length} detail="시스템 진단은 보조 lane" tone=${((S=m[0])==null?void 0:S.severity)??"ok"} />
      </div>

      ${a?o`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${(l==null?void 0:l.goal)??a}${n?` · ${n.summary}`:""}</span>
              <button class="control-btn ghost" onClick=${kv}>선택 해제</button>
            </div>
          `:null}

      <${I} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 operation을 먼저 봅니다.</p>
        </div>
        <div class="mission-list-stack">
          ${t.length>0?t.map(A=>o`<${r_} key=${A.session_id} brief=${A} selected=${a===A.session_id} />`):o`<div class="empty-state">지금 활성 세션이 없습니다.</div>`}
        </div>
      <//>

      <${l_}
        detail=${To.value}
        loading=${Ms.value}
        error=${Ns.value}
      />

      <div class="mission-human-grid">
        <${I} title="Attention Queue" class="mission-list-card" semanticId="mission.attention_queue">
          <div class="mission-section-head">
            <h3>어느 세션을 먼저 봐야 하나</h3>
            <p>문제와 경고는 세션에 연결된 것만 먼저 보여주고, 원인 분석은 선택된 세션에서 이어서 봅니다.</p>
          </div>
          <div class="mission-lane-stack">
            ${p.length>0?p.map(A=>o`<${i_} key=${A.id} item=${A} selected=${Fe.value===A.id} sessionLookup=${i} />`):o`<div class="empty-state">지금 session-level attention queue가 비어 있습니다.</div>`}
          </div>
        <//>

        <${I} title="Internal Signals" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>시스템 진단</h3>
            <p>artifact scope drift 같은 내부 신호는 메인 판단을 방해하지 않도록 접어둔 보조 lane으로만 유지합니다.</p>
          </div>
          <details class="mission-card-disclosure">
            <summary>내부 신호 ${m.length}</summary>
            <div class="mission-list-stack">
              ${m.length>0?m.map(A=>o`<${d_} key=${A.id} item=${A} />`):o`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
            </div>
          </details>
        <//>
      </div>

      <${I} title="Keeper Continuity" class="mission-list-card" semanticId="mission.keeper_activity">
        <div class="mission-section-head">
          <h3>continuity lane</h3>
          <p>keeper는 세션과 별개로 보고, continuity 판단에 필요한 정보만 먼저 보여줍니다.</p>
        </div>
        <div class="mission-activity-list">
          ${c.length>0?c.map(A=>o`<${c_} key=${A.brief.name} row=${A} />`):o`<div class="empty-state">지금 보이는 keeper가 없습니다.</div>`}
        </div>
        <div class="mission-card-actions">
          <button class="control-btn ghost" onClick=${()=>se("execution")}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${()=>se("command")}>지휘 진단면 보기</button>
        </div>
      <//>
    </section>
  `}const u_="modulepreload",p_=function(e){return"/dashboard/"+e},Qi={},m_=function(t,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(m){return Promise.all(m.map(u=>Promise.resolve(u).then(_=>({status:"fulfilled",value:_}),_=>({status:"rejected",reason:_}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),p=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(m=>{if(m=p_(m),m in Qi)return;Qi[m]=!0;const u=m.endsWith(".css"),_=u?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${_}`))return;const f=document.createElement("link");if(f.rel=u?"stylesheet":u_,u||(f.as="script"),f.crossOrigin="",f.href=m,p&&f.setAttribute("nonce",p),document.head.appendChild(f),u)return new Promise((h,b)=>{f.addEventListener("load",h),f.addEventListener("error",()=>b(new Error(`Unable to preload CSS for ${m}`)))})}))}function i(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&i(c.reason);return t().catch(i)})};function ua(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Y(e){if(!e)return"n/a";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function v_(e){if(!e)return"warn";const t=Date.parse(e);return Number.isNaN(t)?"warn":t<=Date.now()?"bad":"ok"}function sc(e){if(!e)return"n/a";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.round((t-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function L(e){return e==="bad"?"bad":e==="warn"||e==="pending"?"warn":"ok"}let Yi=!1,__=0;function g_(){return++__}let Ba=null;async function f_(){Ba||(Ba=m_(()=>import("./mermaid.core-BJVFXVzt.js").then(t=>t.bE),[]).then(t=>t.default));const e=await Ba;return Yi||(e.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),Yi=!0),e}function st(e){if(!e)return"warn";const t=e.toLowerCase();return t.includes("failed")||t.includes("error")||t.includes("disconnected")||t.includes("stopped")?"bad":t.includes("running")||t.includes("active")||t.includes("degraded")||t.includes("pending")?"warn":"ok"}function ns(e){return typeof e!="number"||!Number.isFinite(e)?"n/a":`${Math.round(e*100)}%`}function hn(e){return typeof e!="number"||!Number.isFinite(e)?"n/a":e<60?`${Math.round(e)}s`:e<3600?`${Math.round(e/60)}m`:`${Math.round(e/3600)}h`}function ss(e){return typeof e!="number"||!Number.isFinite(e)?0:Math.max(0,Math.min(100,e))}function $t(e,t){return typeof e!="number"||!Number.isFinite(e)||typeof t!="number"||!Number.isFinite(t)||t<=0?0:ss(e/t*100)}function $_(e,t){const n=ss(e);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${t};`}function ac(e){if(!e)return"No recent chain history";const t=[e.event];return typeof e.duration_ms=="number"&&t.push(`${e.duration_ms}ms`),typeof e.tokens=="number"&&t.push(`${e.tokens} tokens`),e.message&&t.push(e.message),t.join(" · ")}const h_=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],oc=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"orchestra",label:"오케스트라",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],y_=oc.map(e=>e.id),b_=["chain_start","node_start","node_complete","chain_complete","chain_error"],k_={warroom:{title:"라이브 워룸",description:"실제 run, worker, message, trace를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},orchestra:{title:"룸 오케스트라 맵",description:"room, session, lane, worker, keeper를 한 장의 작전판으로 읽는 시각화 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"실제 managed unit인지, live agent 기반 자동 투영인지 구분해서 봅니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function Xi(e){return!!e&&y_.includes(e)}function x_(){const e=F.value.params;return e.source!=="mission"&&e.source!=="execution"?{}:{source:e.source,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function vi(e){const t=x_(),n=lc(),s=_i();if(e==="operations")return t;if(e==="chains"){const a=Vt.value;return a?{...t,surface:e,operation:a}:{...t,surface:e}}return e==="swarm"||e==="warroom"||e==="orchestra"?{...t,surface:e,...n?{run_id:n}:{},...s?{operation_id:s}:{}}:{...t,surface:e}}function S_(){const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");return n&&t.set("agent",n),s&&t.set("token",s),t.toString()?`/api/v1/chains/events?${t.toString()}`:"/api/v1/chains/events"}function A_(e){switch(e){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return e}}function ie(e){return Po.value===e}function as(){return ti.value}function C_(e){var a,i,l,c,p,m,u;const t=ti.value,n=Pt.value,s=es.value;switch(e){case"warroom":return{tool:"masc_observe_operations",reason:"live run, worker, message, trace를 한 화면에서 보고 필요한 detail 표면으로 바로 점프합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=t==null?void 0:t.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(i=t==null?void 0:t.swarm_status)==null?void 0:i.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((p=(c=t==null?void 0:t.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:p.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"orchestra":return{tool:"masc_operator_snapshot",reason:"room, session, lane, worker, keeper를 한 장에서 훑은 뒤 drill-down 대상을 고릅니다."};case"chains":return{tool:(u=(m=s==null?void 0:s.operations[0])==null?void 0:m.preview_run)!=null&&u.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"이 구조가 실제 관리 단위인지 자동 투영인지 먼저 구분해야 command-plane을 오해하지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function I_(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"microarch":t.includes("leader_offline")||t.includes("roster_offline")?"alerts":t.includes("stale_data")?"swarm":null:null}function T_(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")?"recommendation":t.includes("gap")?"gaps":null:null}function ic(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");if(!t)return null;const n=t.trim();return n===""?null:n}function rc(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,i)=>{e.has(i)||e.set(i,a)}),e}function lc(){const t=rc().get("run_id");if(!t)return null;const n=t.trim();return n===""?null:n}function _i(){const t=rc().get("operation_id");if(!t)return null;const n=t.trim();return n===""?null:n}function R_(e){if(!e)return null;const t=Date.parse(e);return Number.isNaN(t)?null:Math.max(0,Math.round((Date.now()-t)/1e3))}function P_(e){return e.status==="claimed"||e.status==="in_progress"}function L_(e){const t=Zn.value;if(!t)return null;for(const n of t.golden_paths){const s=n.steps.find(a=>a.tool===e);if(s)return s}return null}function Ua(e){var t;return((t=Zn.value)==null?void 0:t.golden_paths.find(n=>n.id===e))??null}function z_(e){const t=Zn.value;if(!t)return[];const n=new Set(e);return t.pitfalls.filter(s=>n.has(s.id))}async function at(e){try{await e()}catch{}}function gi(e){return(e==null?void 0:e.trim().toLowerCase())??""}function qt(e){const t=gi(e);return t.includes("failed")||t.includes("error")||t.includes("stopped")||t==="paused"?"bad":t.includes("active")||t.includes("running")||t.includes("healthy")||t.includes("ok")?"ok":"warn"}function _s(e){const t=gi(e);return t?t==="active"||t==="running"?"진행 중":t==="paused"?"일시정지":t==="done"||t==="ended"||t==="completed"?"완료":t==="failed"||t==="error"||t==="stopped"?"문제":(e==null?void 0:e.trim())||"확인 필요":"확인 필요"}function M_(){var n,s,a,i,l,c,p,m,u;const e=Pt.value;if(!e)return!1;const t=e.workers.some(_=>_.joined||_.live_presence||_.completed||_.current_task_matches_run||_.heartbeat_fresh||_.claim_marker_seen||_.done_marker_seen||_.final_marker_seen||!!_.current_task||!!_.bound_task_id||!!_.last_message);return!!((n=e.operation)!=null&&n.operation_id||(s=e.detachment)!=null&&s.detachment_id||(((a=e.summary)==null?void 0:a.joined_workers)??0)>0||(((i=e.summary)==null?void 0:i.live_workers)??0)>0||(((l=e.summary)==null?void 0:l.current_task_bound)??0)>0||(((c=e.summary)==null?void 0:c.fresh_heartbeats)??0)>0||(((p=e.summary)==null?void 0:p.claim_markers_seen)??0)>0||(((m=e.summary)==null?void 0:m.done_markers_seen)??0)>0||(((u=e.summary)==null?void 0:u.final_markers_seen)??0)>0||t||e.recent_messages.length>0||e.recent_trace_events.length>0)}function N_(e){const t=gi(e.status);return t==="active"||t==="running"}function E_(){var i,l,c,p;const e=((i=_e.value)==null?void 0:i.sessions)??[],t=Pt.value,n=((l=t==null?void 0:t.detachment)==null?void 0:l.session_id)??null;if(n){const m=e.find(u=>u.session_id===n);if(m)return m}const s=((c=t==null?void 0:t.operation)==null?void 0:c.operation_id)??_i();if(s){const m=e.find(u=>u.command_plane_operation_id===s);if(m)return m}const a=((p=t==null?void 0:t.detachment)==null?void 0:p.detachment_id)??null;if(a){const m=e.find(u=>u.command_plane_detachment_id===a);if(m)return m}return e.find(N_)??e[0]??null}function Ha(e){return e==="proven"?"ok":e==="partial"?"warn":"bad"}function An(e){return Array.isArray(e)?e:[]}function Pe(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)?e:{}}function gs(e){return typeof e=="string"&&e.trim()!==""?e:null}function j_(e){return typeof e=="number"&&Number.isFinite(e)?e:null}function w_(e){const t=e.split("/");return t.length<=3?e:`…/${t.slice(-3).join("/")}`}function D_(e){return e==="proven"?"협업 증거가 충분합니다":e==="partial"?"흔적은 있으나 협업 증거가 덜 모였습니다":"증거가 부족합니다"}function O_(e,t,n,s,a){const i=[`${t}명의 actor 흔적이 기록돼 있습니다.`,n>0?`서로를 참조한 상호작용 증거가 ${n}건 있습니다.`:"서로를 참조한 명시적 상호작용 증거가 아직 없습니다.",s>0?`도구·산출물·체크포인트 증거가 ${s}건 있습니다.`:"도구·산출물·체크포인트 증거가 거의 없습니다.",a>0?`CPv2 backing trace가 ${a}건 있어 실행 흔적은 남아 있습니다.`:"managed backing trace는 아직 없습니다."];return e==="partial"?[i[0]??"",n===0?"partial인 이유: 참여 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.":"partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.",a>0?"다음 보강 포인트: 대화/상호참조 event를 남기면 proof가 더 강해집니다.":"다음 보강 포인트: managed trace 또는 산출물 linkage를 더 남기면 proof가 강해집니다."]:e==="proven"?[i[0]??"","결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.","다음 행동: raw evidence는 접어두고 세션 결과와 산출물만 확인하면 됩니다."]:[i[0]??"","결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.","다음 보강 포인트: participant 간 turn, tool evidence, deliverable linkage를 더 남겨야 합니다."]}function q_(e){const t=new Map;for(const n of e){const s=[n.timestamp??"",n.event_type??"",n.actor??"",n.summary??""].join("|"),a=n.source??"unknown",i=t.get(s);if(i){i.sources.includes(a)||i.sources.push(a),!i.operation_id&&n.operation_id&&(i.operation_id=n.operation_id);continue}t.set(s,{...n,sources:[a]})}return[...t.values()]}function F_(e){return e.sources.length===2?"team + command":e.sources.length===1?e.sources[0]??"source":e.sources.join(" + ")}function K_(e){const t=[];for(const[n,s]of Object.entries(e))if(s!=null){if(typeof s=="string"){if(s.trim()==="")continue;t.push({label:n,value:s});continue}if(typeof s=="number"||typeof s=="boolean"){t.push({label:n,value:String(s)});continue}}return t}function B_(e){const t=Pe(e),n=Pe(t.traces),s=Array.isArray(n.events)?n.events:[],a=Pe(t.detachments),i=Array.isArray(a.detachments)?a.detachments:[],l=Pe(i[0]),c=Pe(l.detachment),p=Pe(l.operation),m=Pe(t.summary),u=Pe(m.operations),_=Pe(u.summary);return[{label:"operation",value:gs(t.operation_id)??"없음"},{label:"detachment",value:gs(t.detachment_id)??"없음"},{label:"trace events",value:`${s.length}`},{label:"detachment status",value:gs(c.status)??"없음"},{label:"operation stage",value:gs(p.stage)??"없음"},{label:"active ops",value:`${j_(_.active)??0}`}]}function U_({item:e}){return o`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${e.summary??e.event_type??"event"}</strong>
          <div class="command-meta-line">
            <span>${F_(e)}</span>
            <span>${e.event_type??"event"}</span>
            <span>${e.actor??"system"}</span>
          </div>
        </div>
        <span class="command-chip">${Y(e.timestamp)}</span>
      </div>
      ${e.sources.length>1?o`<div class="semantic-tag-row">
            ${e.sources.map(t=>o`<span class="semantic-tag">${t}</span>`)}
          </div>`:null}
    </article>
  `}function H_({item:e}){const t=e.recent_output_preview??null,n=e.recent_input_preview??null,s=e.recent_event_summary??null,a=(e.interaction_count??0)>0?"ok":"warn";return o`
    <article class="mission-activity-row proof-actor-row">
      <div class="mission-activity-head">
        <div>
          <strong>${e.actor}</strong>
          <div class="mission-activity-meta">
            <span>${e.role??"participant"}</span>
            <span>${e.last_active_at?Y(e.last_active_at):"n/a"}</span>
          </div>
        </div>
        <span class="command-chip ${a}">
          ${(e.interaction_count??0)>0?`${e.interaction_count} interaction`:"interaction 없음"}
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>turn ${e.turn_count??0}</span>
        <span>spawn ${e.spawn_count??0}</span>
        <span>tool evidence ${e.tool_evidence_count??0}</span>
      </div>
      ${s?o`<div class="proof-summary-block">
            <strong>최근 흔적</strong>
            <span>${s}</span>
          </div>`:null}
      ${n||t?o`<div class="proof-io-grid">
            <div class="mission-activity-preview">
              <strong>최근 input</strong>
              <span>${n??"표시 가능한 input 없음"}</span>
            </div>
            <div class="mission-activity-preview">
              <strong>최근 output</strong>
              <span>${t??"표시 가능한 output 없음"}</span>
            </div>
          </div>`:null}
      ${An(e.recent_tool_names).length>0?o`<div class="semantic-tag-row">
            ${An(e.recent_tool_names).map(i=>o`<span class="semantic-tag">${i}</span>`)}
          </div>`:null}
    </article>
  `}function W_({item:e}){return o`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${e.kind}</strong>
          <div class="command-meta-line">
            <span>${w_(e.path)}</span>
          </div>
        </div>
        <span class="command-chip ${e.exists?"ok":"warn"}">${e.exists?"present":"missing"}</span>
      </div>
    </article>
  `}function Zi({title:e,rows:t}){return t.length===0?null:o`
    <div class="proof-kv-block">
      ${e?o`<strong>${e}</strong>`:null}
      <div class="proof-kv-grid">
        ${t.map(n=>o`
          <span>${n.label}</span>
          <strong>${n.value}</strong>
        `)}
      </div>
    </div>
  `}function G_(){var z,T,P;const e=F.value.params,t=e.session_id??null,n=e.operation_id??null;ne(()=>{Sl(t,n)},[t,n]);const s=xl.value;if(Ro.value&&!s)return o`<section class="dashboard-panel"><div class="loading-indicator">Loading proof…</div></section>`;if(Dt.value&&!s)return o`<section class="dashboard-panel"><div class="error-card">${Dt.value}</div></section>`;const a=s==null?void 0:s.summary,i=An(s==null?void 0:s.actor_contributions),l=An(s==null?void 0:s.artifacts),c=(s==null?void 0:s.proof_verdict)??"insufficient",p=(s==null?void 0:s.cp_backing_evidence)??null,m=Array.isArray((z=p==null?void 0:p.traces)==null?void 0:z.events)?((P=(T=p.traces)==null?void 0:T.events)==null?void 0:P.length)??0:0,u=(a==null?void 0:a.actors_count)??i.length,_=(a==null?void 0:a.interaction_count)??0,f=(a==null?void 0:a.evidence_count)??0,h=q_(An(s==null?void 0:s.timeline)),b=K_(Pe(s==null?void 0:s.goal_binding)),$=B_(p),S=l.filter(M=>M.exists).length,A=l.length-S,x=O_(c,u,_,f,m);return o`
    <section class="dashboard-panel mission-view">
      <${be} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>Proof</h2>
          <p>이 세션이 실제로 여러 actor의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${Ha(c)}">${c}</span>
          ${s!=null&&s.session_id?o`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?o`<span class="command-chip">${Y(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${Dt.value?o`<div class="error-card">${Dt.value}</div>`:null}

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${Ha(c)}">
          <span>Verdict</span>
          <strong>${D_(c)}</strong>
          <small>${(a==null?void 0:a.detail)??"협업 증거를 verdict로 요약합니다."}</small>
        </div>
        <div class="summary-stat-card">
          <span>Actors</span>
          <strong>${u}</strong>
          <small>기록된 참여 actor 수</small>
        </div>
        <div class="summary-stat-card ${_>0?"ok":"warn"}">
          <span>Interactions</span>
          <strong>${_}</strong>
          <small>actor 간 직접 상호작용 증거</small>
        </div>
        <div class="summary-stat-card ${f>0?"ok":"warn"}">
          <span>Evidence</span>
          <strong>${f}</strong>
          <small>tool / deliverable / checkpoint</small>
        </div>
        <div class="summary-stat-card ${m>0?"ok":"warn"}">
          <span>CP Traces</span>
          <strong>${m}</strong>
          <small>managed backing events</small>
        </div>
        <div class="summary-stat-card ${A===0&&l.length>0?"ok":"warn"}">
          <span>Artifacts</span>
          <strong>${S}/${l.length}</strong>
          <small>${A>0?`${A} missing`:"all present"}</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${I} title="3-Line Proof Summary" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, partial 이유, 다음 보강 포인트만 먼저 봅니다.</p>
          </div>
          <div class="proof-summary-stack">
            ${x.map((M,R)=>o`
              <article class="proof-summary-block ${R===1&&c!=="proven"?Ha(c):""}">
                <strong>${R===0?"지금 결론":R===1?"왜 이렇게 판정됐나":"다음 보강 포인트"}</strong>
                <span>${M}</span>
              </article>
            `)}
          </div>
        <//>

        <${I} title="Goal Binding" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 proof가 어느 세션, 목표, operation에 묶였는지 읽습니다.</p>
          </div>
          <${Zi} rows=${b} />
          <details class="mission-card-disclosure compact">
            <summary>raw goal binding JSON</summary>
            <pre class="command-json-block">${ua((s==null?void 0:s.goal_binding)??{})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${I} title="Collaboration Timeline" class="mission-list-card" semanticId="proof.timeline">
          <div class="mission-section-head">
            <h3>협업 타임라인</h3>
            <p>team-session과 command-plane에서 같은 사건이 보이면 한 줄로 묶어 읽습니다.</p>
          </div>
          <div class="mission-list-stack">
            ${h.length>0?h.slice(0,18).map(M=>o`<${U_} key=${M.id} item=${M} />`):o`<div class="empty-state">표시할 timeline evidence가 없습니다.</div>`}
          </div>
        <//>

        <${I} title="Actor Contributions" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>turn 수보다 최근 흔적, 입출력, 도구, interaction 유무를 우선 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${i.length>0?i.map(M=>o`<${H_} key=${M.actor} item=${M} />`):o`<div class="empty-state">표시할 actor contribution이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${I} title="Backing Evidence" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>operation, detachment, trace 수만 먼저 보고, raw CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${Zi} rows=${$} />
          <details class="mission-card-disclosure compact">
            <summary>raw CPv2 backing JSON</summary>
            <pre class="command-json-block">${ua(p??{})}</pre>
          </details>
        <//>

        <${I} title="Artifacts" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>어떤 파일 산출물이 남았나</h3>
            <p>proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${l.length>0?l.map(M=>o`<${W_} key=${M.path} item=${M} />`):o`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function J_(){const e=ts(F.value);return e?o`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${e.source_label}</strong>
        <span class="command-chip">${La(e.action_type)}</span>
        <span class="command-chip">${di(e)}</span>
        <span class="command-chip">${vv(F.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${e.summary}</div>
      ${e.payload_preview?o`<div class="command-focus-preview">${e.payload_preview}</div>`:null}
    </section>
  `:null}function V_(){const e=G.value,t=k_[e],n=C_(e);return o`
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
  `}function fs({label:e,value:t,subtext:n,percent:s,color:a}){return o`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${$_(s,a)}>
        <div class="command-gauge-core">
          <strong>${t}</strong>
          <span>${Math.round(ss(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${e}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function $s({label:e,value:t,detail:n,percent:s,tone:a}){return o`
    <article class="command-signal-rail ${L(a)}">
      <div class="command-signal-copy">
        <span>${e}</span>
        <strong>${t}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${L(a)}" style=${`width: ${Math.max(8,Math.round(ss(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function Q_(){var Z,oe,V,ee;const e=as(),t=e==null?void 0:e.topology.summary,n=e==null?void 0:e.operations.summary,s=e==null?void 0:e.detachments.summary,a=e==null?void 0:e.decisions.summary,i=e==null?void 0:e.alerts.summary,l=(Z=e==null?void 0:e.swarm_status)==null?void 0:Z.overview,c=e==null?void 0:e.swarm_proof,p=e==null?void 0:e.operations.microarch,m=(t==null?void 0:t.managed_unit_count)??0,u=(t==null?void 0:t.total_units)??0,_=(n==null?void 0:n.active)??0,f=(s==null?void 0:s.active)??0,h=(l==null?void 0:l.moving_lanes)??0,b=(l==null?void 0:l.active_lanes)??0,$=(c==null?void 0:c.workers.done)??0,S=(c==null?void 0:c.workers.expected)??0,A=(i==null?void 0:i.bad)??0,x=(i==null?void 0:i.warn)??0,z=(a==null?void 0:a.pending)??0,T=(a==null?void 0:a.total)??0,P=_+f,M=((oe=p==null?void 0:p.cache)==null?void 0:oe.l1_hit_rate)??((ee=(V=p==null?void 0:p.signals)==null?void 0:V.cache_contention)==null?void 0:ee.l1_hit_rate)??0,R=_>0||f>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",N=_>0||h>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return o`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${R}</h3>
        <p>${N}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${L(_>0?"ok":"warn")}">활성 작전 ${_}</span>
          <span class="command-chip ${L(h>0?"ok":(b>0,"warn"))}">이동 레인 ${h}/${Math.max(b,h)}</span>
          <span class="command-chip ${L(A>0?"bad":x>0?"warn":"ok")}">치명 알림 ${A}</span>
          <span class="command-chip ${L(z>0?"warn":"ok")}">승인 대기 ${z}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${fs}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(u,m)}`}
          subtext=${u>0?`${u-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${$t(m,Math.max(u,m))}
          color="#67e8f9"
        />
        <${fs}
          label="실행 열도"
          value=${String(P)}
          subtext=${`${_}개 작전 + ${f}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${$t(P,Math.max(m,P||1))}
          color="#4ade80"
        />
        <${fs}
          label="스웜 이동감"
          value=${`${h}/${Math.max(b,h)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${Y(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${$t(h,Math.max(b,h||1))}
          color="#fbbf24"
        />
        <${fs}
          label="증거 수집률"
          value=${`${$}/${Math.max(S,$)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${$t($,Math.max(S,$||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${$s}
        label="승인 대기열"
        value=${`${z}건 대기`}
        detail=${`현재 정책 창에서 ${T}개 결정을 추적 중입니다`}
        percent=${$t(z,Math.max(T,z||1))}
        tone=${z>0?"warn":"ok"}
      />
      <${$s}
        label="알림 압력"
        value=${`${A} bad / ${x} warn`}
        detail=${A>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${$t(A*2+x,Math.max((A+x)*2,1))}
        tone=${A>0?"bad":x>0?"warn":"ok"}
      />
      <${$s}
        label="디스패치 점유"
          value=${`${f}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${$t(f,Math.max(m,f||1))}
        tone=${f>0?"ok":"warn"}
      />
      <${$s}
        label="캐시 신뢰도"
        value=${M?ns(M):"n/a"}
        detail=${M?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${ss((M??0)*100)}
        tone=${M>=.75?"ok":M>=.4?"warn":"bad"}
      />
    </div>
  `}function Y_(){var f,h,b,$,S;const e=as(),t=es.value,n=ts(F.value),s=I_(n),a=e==null?void 0:e.topology.summary,i=e==null?void 0:e.operations.summary,l=(f=e==null?void 0:e.swarm_status)==null?void 0:f.overview,c=e==null?void 0:e.operations.microarch,p=e==null?void 0:e.decisions.summary,m=e==null?void 0:e.alerts.summary,u=(h=c==null?void 0:c.signals)==null?void 0:h.issue_pressure,_=c==null?void 0:c.cache;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(i==null?void 0:i.active)??0}</strong><small>${((b=e==null?void 0:e.detachments.summary)==null?void 0:b.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(p==null?void 0:p.pending)??0}</strong><small>${(p==null?void 0:p.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${(($=t==null?void 0:t.summary)==null?void 0:$.active_chains)??0}</strong><small>${((S=t==null?void 0:t.summary)==null?void 0:S.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${Y(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(_==null?void 0:_.l1_hit_rate)!=null?`${ns(_.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"n/a"}</small></div>
    </div>
  `}function X_(){var Z,oe,V,ee,C,Ie,We,mt,vt;const e=as(),t=De.value,n=te.value,s=ic(),a=s?He.value.find(K=>K.name===s)??null:null,i=s?Xe.value.filter(K=>K.assignee===s&&P_(K)):[],l=((Z=e==null?void 0:e.operations.summary)==null?void 0:Z.active)??0,c=((oe=e==null?void 0:e.detachments.summary)==null?void 0:oe.total)??0,p=((V=e==null?void 0:e.decisions.summary)==null?void 0:V.pending)??0,m=t==null?void 0:t.detachments.detachments.find(K=>{const Te=K.detachment.heartbeat_deadline,_t=Te?Date.parse(Te):Number.NaN;return K.detachment.status==="stalled"||!Number.isNaN(_t)&&_t<=Date.now()}),u=t==null?void 0:t.alerts.alerts.find(K=>K.severity==="bad"),_=!!(n!=null&&n.room||n!=null&&n.project),f=(a==null?void 0:a.current_task)??null,h=R_(a==null?void 0:a.last_seen),b=h!=null?h<=120:null,$=[_?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?i.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:Xe.value.length>0?"masc_claim":"masc_add_task"}:f?b===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${f} 이지만 heartbeat가 stale 합니다 (${h}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${f}${h!=null?` · 마지막 활동 ${h}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!e||(((ee=e.topology.summary)==null?void 0:ee.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((C=e.topology.summary)==null?void 0:C.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Ie=e.topology.summary)==null?void 0:Ie.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},p>0?{title:"디스패치 준비도",tone:"warn",detail:`${p}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||u?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${u?` · alert ${u.title??u.alert_id}`:""}${!t&&!m&&!u?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${t?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],S=_?!s||!a?"masc_join":i.length===0?Xe.value.length>0?"masc_claim":"masc_add_task":f?b===!1?"masc_heartbeat":!e||(((We=e.topology.summary)==null?void 0:We.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":p>0?"masc_policy_approve":l>0&&c===0||m||u?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",A=L_(S),z=z_(S==="masc_set_room"?["repo-root-room"]:S==="masc_plan_set_task"?["claimed-not-current"]:S==="masc_heartbeat"?["heartbeat-stale"]:S==="masc_dispatch_tick"?["no-detachments"]:S==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),T=Ua("room_task_hygiene"),P=Ua("cpv2_benchmark"),M=Ua("supervisor_session"),R=((mt=Zn.value)==null?void 0:mt.docs)??[],N=[T,P,M].filter(K=>K!==null);return o`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${O} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(A==null?void 0:A.title)??S}</strong>
            <span class="command-chip ok">${S}</span>
          </div>
          <p>${(A==null?void 0:A.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(vt=A==null?void 0:A.success_signals)!=null&&vt.length?o`<div class="command-tag-row">
                ${A.success_signals.map(K=>o`<span class="command-tag ok">${K}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${$.map(K=>o`
            <article class="command-readiness-row ${L(K.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${K.title}</strong>
                  <span class="command-chip ${L(K.tone)}">${K.tone}</span>
                </div>
                <p>${K.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${K.tool}</div>
            </article>
          `)}
        </div>

        ${z.length>0?o`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${z.length}</span>
                </div>
                <div class="command-guide-list">
                  ${z.map(K=>o`
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
        ${Lo.value?o`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:na.value?o`<div class="empty-state error">${na.value}</div>`:o`
                <div class="command-path-grid">
                  ${N.map(K=>o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${K.title}</strong>
                        <span class="command-chip">${K.id}</span>
                      </div>
                      <p>${K.summary}</p>
                      <div class="command-card-sub">${K.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${K.steps.slice(0,4).map(Te=>o`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Te.tool}</span>
                            <span>${Te.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${R.length>0?o`<div class="command-doc-links">
                      ${R.map(K=>o`<span class="command-tag">${K.title}: ${K.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Z_(){return o`
    <${Q_} />
    <${Y_} />
    <${X_} />
  `}function eg(){return Xs.value?o`<div class="empty-state">command-plane detail 불러오는 중…</div>`:ea.value?o`<div class="empty-state error">${ea.value}</div>`:o`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}const wo=g(null),er=1280,tr=760;function gn(e,t,n){if(e<=0)return[];if(e===1)return[Math.round((t+n)/2)];const s=(n-t)/(e-1);return Array.from({length:e},(a,i)=>Math.round(t+i*s))}function tg(e,t){const n=new Map;for(const s of e){const a=t(s),i=n.get(a)??[];i.push(s),n.set(a,i)}return n}function ng(e){const t=new Map,n=e.nodes,s=n.find(b=>b.kind==="room")??null,a=n.filter(b=>b.kind==="session"),i=n.filter(b=>b.kind==="operation"),l=n.filter(b=>b.kind==="detachment"),c=n.filter(b=>b.kind==="lane"),p=n.filter(b=>b.kind==="worker"),m=n.filter(b=>b.kind==="keeper");s&&t.set(s.id,{x:640,y:96}),gn(a.length,170,1110).forEach((b,$)=>{const S=a[$];S&&t.set(S.id,{x:b,y:220})}),gn(i.length,240,1040).forEach((b,$)=>{const S=i[$];S&&t.set(S.id,{x:b,y:330})}),gn(l.length,300,980).forEach((b,$)=>{const S=l[$];S&&t.set(S.id,{x:b,y:420})}),gn(c.length,170,1110).forEach((b,$)=>{const S=c[$];S&&t.set(S.id,{x:b,y:530})});const u=new Map(c.map(b=>{const $=t.get(b.id);return $?[b.id,$.x]:null}).filter(b=>b!==null)),_=tg(p,b=>b.lane_id?`lane:${b.lane_id}`:b.parent_id?b.parent_id:"free");let f=0;for(const[b,$]of _){let S=u.get(b);if(S==null){const x=t.get(b);S=x==null?void 0:x.x}S==null&&(S=180+f%5*200,f+=1),gn($.length,S-90,S+90).forEach((x,z)=>{const T=$[z];if(!T)return;const P=z>5?Math.floor(z/6):0;t.set(T.id,{x,y:635+P*62})})}const h=m.length>3?[1120,1180]:[1140];return m.forEach((b,$)=>{const S=$%h.length,A=Math.floor($/h.length);t.set(b.id,{x:h[S]??1140,y:190+A*108})}),t}function sg(e,t){const n=(e.x+t.x)/2,s=t.y>=e.y?32:-32;return`M ${e.x} ${e.y} C ${n} ${e.y+s}, ${n} ${t.y-s}, ${t.x} ${t.y}`}function nr(e,t,n){if(e==="command"){if(t){nt(t),se("command",{...vi(t),...n});return}se("command",n);return}if(e==="intervene"){se("intervene",n);return}se("command",n)}function ag(e){switch(e.kind){case"room":return{width:150,height:150,radius:74};case"worker":return{width:78,height:42,radius:22};case"lane":return{width:170,height:54,radius:16};case"keeper":return{width:120,height:56,radius:24};default:return{width:188,height:64,radius:18}}}function og({orchestra:e,roomPoint:t,onSelect:n}){if(!t||e.signals.length===0)return null;const s=108;return o`
    ${e.signals.slice(0,6).map((a,i)=>{const l=(-120+i*38)*(Math.PI/180),c=Math.round(t.x+Math.cos(l)*s),p=Math.round(t.y+Math.sin(l)*s);return o`
        <g
          key=${a.id}
          class=${`orchestra-signal-node ${L(a.tone)}`}
          onClick=${()=>n(a.id)}
        >
          <line x1=${t.x} y1=${t.y} x2=${c} y2=${p} class="orchestra-signal-link" />
          <circle cx=${c} cy=${p} r="16" class="orchestra-signal-dot" />
          <text x=${c} y=${p+4} text-anchor="middle" class="orchestra-signal-glyph">!</text>
        </g>
      `})}
  `}function ig({edges:e,positions:t,selectedId:n}){return o`
    ${e.map(s=>{const a=t.get(s.source),i=t.get(s.target);if(!a||!i)return null;const l=n!=null&&(s.source===n||s.target===n);return o`
        <path
          key=${s.id}
          d=${sg(a,i)}
          class=${`orchestra-edge ${L(s.tone)} ${s.animated?"animated":""} ${l?"active":""}`}
        />
      `})}
  `}function rg({orchestra:e,positions:t,selectedId:n,onSelect:s}){var i;const a=((i=e.focus)==null?void 0:i.target_kind)==="node"?e.focus.target_id:null;return o`
    ${e.nodes.map(l=>{const c=t.get(l.id);if(!c)return null;const p=ag(l),m=l.id===n,u=l.id===a;if(l.kind==="room")return o`
          <g
            key=${l.id}
            class=${`orchestra-node room ${L(l.tone)} ${m?"selected":""} ${u?"focused":""}`}
            onClick=${()=>s(l.id)}
          >
            <circle cx=${c.x} cy=${c.y} r=${p.radius} class="orchestra-room-ring outer" />
            <circle cx=${c.x} cy=${c.y} r=${p.radius-16} class="orchestra-room-ring inner" />
            <text x=${c.x} y=${c.y-10} text-anchor="middle" class="orchestra-room-glyph">${l.glyph??"◎"}</text>
            <text x=${c.x} y=${c.y+22} text-anchor="middle" class="orchestra-room-label">${l.label}</text>
          </g>
        `;const _=c.x-p.width/2,f=c.y-p.height/2;return o`
        <g
          key=${l.id}
          class=${`orchestra-node ${l.kind} ${L(l.tone)} ${m?"selected":""} ${u?"focused":""}`}
          onClick=${()=>s(l.id)}
        >
          <rect x=${_} y=${f} width=${p.width} height=${p.height} rx=${p.radius} class="orchestra-node-body" />
          <text x=${_+16} y=${f+24} class="orchestra-node-glyph">${l.glyph??"•"}</text>
          <text x=${_+38} y=${f+24} class="orchestra-node-label">${l.label}</text>
          ${l.subtitle?o`<text x=${_+38} y=${f+42} class="orchestra-node-subtitle">${l.subtitle}</text>`:null}
          ${l.status?o`<text x=${_+p.width-10} y=${f+18} text-anchor="end" class="orchestra-node-status">${l.status}</text>`:null}
        </g>
      `})}
  `}function cc(e){var s,a;const t=wo.value;if(t){const i=e.nodes.find(c=>c.id===t);if(i)return{type:"node",value:i};const l=e.signals.find(c=>c.id===t);if(l)return{type:"signal",value:l}}if(((s=e.focus)==null?void 0:s.target_kind)==="node"){const i=e.nodes.find(l=>{var c;return l.id===((c=e.focus)==null?void 0:c.target_id)});if(i)return{type:"node",value:i}}if(((a=e.focus)==null?void 0:a.target_kind)==="signal"){const i=e.signals.find(l=>{var c;return l.id===((c=e.focus)==null?void 0:c.target_id)});if(i)return{type:"signal",value:i}}const n=e.nodes[0];return n?{type:"node",value:n}:null}function lg({orchestra:e}){const t=cc(e);if(!t)return o`<aside class="orchestra-drawer card"><div class="empty-state">선택 가능한 대상이 아직 없습니다.</div></aside>`;if(t.type==="signal"){const i=t.value;return o`
      <aside class="orchestra-drawer card ${L(i.tone)}">
        <div class="card-title-row">
          <div class="card-title">${i.label}</div>
          <span class="command-chip ${L(i.tone)}">${i.kind}</span>
        </div>
        <p>${i.detail??"세부 설명이 없습니다."}</p>
        ${i.suggested_surface?o`
              <div class="command-action-row">
                <button
                  class="control-btn"
                  onClick=${()=>nr("command",i.suggested_surface,i.suggested_params??{})}
                >
                  ${i.suggested_surface} 열기
                </button>
              </div>
            `:null}
      </aside>
    `}const n=t.value,s=e.signals.filter(i=>i.source_id===n.id||i.target_id===n.id),a=e.edges.filter(i=>i.source===n.id||i.target===n.id);return o`
    <aside class="orchestra-drawer card ${L(n.tone)}">
      <div class="card-title-row">
        <div class="card-title">${n.label}</div>
        <span class="command-chip ${L(n.tone)}">${n.kind}</span>
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
          ${s.map(i=>o`<span class="command-chip ${L(i.tone)}">${i.label}</span>`)}
        </div>
      `:null}
      <div class="command-card-sub">연결 ${a.length}개 · provenance ${n.provenance}</div>
      ${n.link_tab&&(n.link_surface||Object.keys(n.link_params??{}).length>0)?o`
            <div class="command-action-row">
              <button
                class="control-btn"
                onClick=${()=>nr(n.link_tab??"command",n.link_surface,n.link_params??{})}
              >
                열기
              </button>
            </div>
          `:null}
    </aside>
  `}function cg(){var i,l,c,p;const e=ni.value;if(zo.value&&!e)return o`<section class="card command-section"><div class="empty-state">오케스트라 맵 불러오는 중…</div></section>`;if(oa.value)return o`<section class="card command-section"><div class="empty-state error">${oa.value}</div></section>`;if(!e)return o`<section class="card command-section"><div class="empty-state">오케스트라 맵 데이터가 아직 없습니다.</div></section>`;const t=ng(e),n=cc(e),s=(n==null?void 0:n.value.id)??null,a=e.nodes.find(m=>m.kind==="room")?t.get(e.nodes.find(m=>m.kind==="room").id)??null:null;return o`
    <section class="card command-section orchestra-surface">
      <div class="card-title-row">
        <div class="card-title">오케스트라</div>
        <${O} panelId="command.orchestra" compact=${!0} />
      </div>
      <p class="command-card-sub">room 전체를 한 장의 작전판으로 읽는 시각화입니다. 클릭하면 drill-down 대상과 관련 신호를 바로 볼 수 있습니다.</p>

      <div class="orchestra-shell">
        <div class="orchestra-canvas-wrap">
          <svg class="orchestra-canvas" viewBox=${`0 0 ${er} ${tr}`}>
            <defs>
              <pattern id="orchestra-grid" width="32" height="32" patternUnits="userSpaceOnUse">
                <path d="M 32 0 L 0 0 0 32" fill="none" class="orchestra-grid-line"></path>
              </pattern>
            </defs>
            <rect width=${er} height=${tr} fill="url(#orchestra-grid)" class="orchestra-grid"></rect>
            <${ig} edges=${e.edges} positions=${t} selectedId=${s} />
            <${og} orchestra=${e} roomPoint=${a} onSelect=${m=>{wo.value=m}} />
            <${rg}
              orchestra=${e}
              positions=${t}
              selectedId=${s}
              onSelect=${m=>{wo.value=m}}
            />
          </svg>
          <div class="orchestra-summary-strip">
            <span class="command-chip">sessions ${((i=e.summary)==null?void 0:i.session_count)??0}</span>
            <span class="command-chip">workers ${((l=e.summary)==null?void 0:l.worker_count)??0}</span>
            <span class="command-chip">keepers ${((c=e.summary)==null?void 0:c.keeper_count)??0}</span>
            <span class="command-chip ${L(e.signals.some(m=>m.tone==="bad")?"bad":e.signals.length>0?"warn":"ok")}">
              signals ${((p=e.summary)==null?void 0:p.signal_count)??e.signals.length}
            </span>
            <span class="command-chip">${Y(e.generated_at)}</span>
          </div>
        </div>

        <${lg} orchestra=${e} />
      </div>
    </section>
  `}const dc="masc_dashboard_agent_name";function dg(){var t,n,s;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(dc))==null?void 0:s.trim())||"dashboard"}const Na=g(dg()),Xt=g(""),pa=g("운영 점검"),Zt=g(""),On=g(""),qn=g("2"),an=g(""),he=g("note"),Fn=g(""),Kn=g(""),Bn=g(""),Un=g("2"),Hn=g(""),ma=g("운영자 중지 요청"),va=g(""),en=g(""),hs=g(null);function ug(e){const t=e.trim()||"dashboard";Na.value=t,localStorage.setItem(dc,t)}function _a(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function fi(e){switch((e??"").trim().toLowerCase()){case"judgment":return"Resident judgment";case"fallback":return"Fallback read model";default:return(e==null?void 0:e.trim())||"Guidance"}}function ga(e){switch((e??"").trim().toLowerCase()){case"judgment":return"ok";case"fallback":return"warn";default:return"warn"}}function $i(e){return e!=null&&e.enabled?e.refreshing?"갱신 중":e.judge_online?"온라인":e.last_error?"오류":"대기":"꺼짐"}function pg(e){return e!=null&&e.enabled?e.judge_online?"ok":e.refreshing?"warn":"bad":"warn"}function hi(e){return e!=null&&e.fresh_until?e.fresh_until:"freshness 없음"}function sr(e){return typeof e!="number"||!Number.isFinite(e)?"확인 없음":e<60?`${Math.round(e)}초 전`:e<3600?`${Math.round(e/60)}분 전`:`${Math.round(e/3600)}시간 전`}function on(e){return typeof e=="string"?e.trim().toLowerCase():""}function mg(e){var s;const t=on(e.status);if(t==="paused")return"bad";if(t===""||t==="unknown")return"warn";const n=on((s=e.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||t&&t!=="active"&&t!=="running"&&t!=="ended"?"warn":"ok"}function Wa(e){const t=on(e.status);return t==="offline"||t==="inactive"||t==="error"?"bad":t===""||t==="unknown"||(e.context_ratio??0)>=.8||e.context_ratio==null||e.last_turn_ago_s==null||(e.last_turn_ago_s??0)>=3600?"warn":"ok"}function ar(e){return e.some(t=>on(t.severity)==="bad")?"bad":e.length>0?"warn":"ok"}function vg(e){return e.target_type==="team_session"}function _g(e){return e.target_type==="keeper"}function It(e){switch(e){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"team_worker_spawn_batch":return"세션 worker 교체";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(e==null?void 0:e.trim())||"액션"}}function tn(e){switch(e){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";case"swarm_run":return"swarm run";default:return(e==null?void 0:e.trim())||"target"}}function Ft(e){switch(on(e)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function fa(e){return e?"확인 후 실행":"즉시 실행"}function gg(e){switch(e){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"worker_spawn_batch":return"worker 교체";default:return e}}function ue(e,t){if(!e)return null;const n=e[t];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function fg(e){return!e||typeof e!="object"||Array.isArray(e)?null:e}function $g(e){if(!e)return"";const t=e.spawn_batch;return _a(t!==void 0?t:e)}function uc(e){const t=fg(e.payload);if(e.target_type==="room"){if(e.action_type==="broadcast"){Xt.value=ue(t,"message")??e.summary;return}if(e.action_type==="task_inject"){Zt.value=ue(t,"title")??"운영자 주입 작업",On.value=ue(t,"description")??e.summary,qn.value=ue(t,"priority")??qn.value;return}e.action_type==="room_pause"&&(pa.value=ue(t,"reason")??e.summary);return}if(e.target_type==="team_session"){if(e.target_id&&(an.value=e.target_id),e.action_type==="team_stop"){ma.value=ue(t,"reason")??e.summary;return}he.value=e.action_type==="team_worker_spawn_batch"?"worker_spawn_batch":e.action_type==="team_task_inject"?"task":e.action_type==="team_broadcast"?"broadcast":"note";const n=ue(t,"message");if(n&&(Fn.value=n),he.value==="worker_spawn_batch"){Hn.value=$g(t);return}he.value==="task"&&(Kn.value=ue(t,"task_title")??ue(t,"title")??"운영자 주입 작업",Bn.value=ue(t,"task_description")??ue(t,"description")??e.summary,Un.value=ue(t,"task_priority")??ue(t,"priority")??Un.value);return}e.target_type==="keeper"&&(e.target_id&&(va.value=e.target_id),en.value=ue(t,"message")??e.summary)}function hg(e){uc({action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.suggested_payload,summary:e.summary})}function yg(e){uc({action_type:e.action_type,target_type:e.target_type,target_id:e.target_id??null,payload:e.suggested_payload,summary:e.reason}),E("추천 액션 payload를 폼에 채웠습니다","success")}function bg(e,t,n){return!e||!e.target_type||e.target_type==="room"?!0:e.target_type==="team_session"?!!e.target_id&&t.some(s=>s.session_id===e.target_id):e.target_type==="keeper"?!!e.target_id&&n.some(s=>s.name===e.target_id):!0}async function rt(e){const t=Na.value.trim()||"dashboard";try{const n=await vl({actor:t,action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.payload});return n.confirm_required?E("확인 대기열에 올렸습니다","warning"):E(e.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return E(s,"error"),null}}async function or(){const e=Xt.value.trim();if(!e)return;await rt({action_type:"broadcast",target_type:"room",payload:{message:e},successMessage:"방송을 보냈습니다"})&&(Xt.value="")}async function kg(){await rt({action_type:"room_pause",target_type:"room",payload:{reason:pa.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function pc(){await rt({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function xg(){const e=Zt.value.trim();if(!e)return;await rt({action_type:"task_inject",target_type:"room",payload:{title:e,description:On.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(qn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(Zt.value="",On.value="")}async function Sg(){var l;const e=_e.value,t=an.value||((l=e==null?void 0:e.sessions[0])==null?void 0:l.session_id)||"";if(!t){E("먼저 세션을 고르세요","warning");return}const n={};if(he.value==="worker_spawn_batch"){const c=Hn.value.trim();if(!c){E("spawn_batch JSON을 먼저 채우세요","warning");return}try{const m=JSON.parse(c);if(Array.isArray(m))n.spawn_batch=m;else if(m&&typeof m=="object"&&Array.isArray(m.spawn_batch))n.spawn_batch=m.spawn_batch;else{E("spawn_batch는 배열 또는 { spawn_batch: [...] } 형태여야 합니다","warning");return}}catch(m){const u=m instanceof Error?m.message:"spawn_batch JSON 파싱에 실패했습니다";E(u,"error");return}await rt({action_type:"team_worker_spawn_batch",target_type:"team_session",target_id:t,payload:n,successMessage:"worker 교체 요청을 적용했습니다"})&&(Hn.value="");return}const s=Fn.value.trim();s&&(n.message=s);let a="team_note";he.value==="broadcast"?a="team_broadcast":he.value==="task"&&(a="team_task_inject"),he.value==="task"&&(n.task_title=Kn.value.trim()||"운영자 주입 작업",n.task_description=Bn.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(Un.value,10)||2),await rt({action_type:a,target_type:"team_session",target_id:t,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Fn.value="",he.value==="task"&&(Kn.value="",Bn.value=""))}async function Ag(){var n;const e=_e.value,t=an.value||((n=e==null?void 0:e.sessions[0])==null?void 0:n.session_id)||"";if(!t){E("먼저 세션을 고르세요","warning");return}await rt({action_type:"team_stop",target_type:"team_session",target_id:t,payload:{reason:ma.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Cg(){var a;const e=_e.value,t=va.value||((a=e==null?void 0:e.keepers[0])==null?void 0:a.name)||"",n=en.value.trim();if(!t){E("먼저 keeper를 고르세요","warning");return}if(!n)return;await rt({action_type:"keeper_message",target_type:"keeper",target_id:t,payload:{message:n},successMessage:`${t}에게 메시지를 보냈습니다`})&&(en.value="")}async function ir(e,t="confirm"){const n=Na.value.trim()||"dashboard";try{await _l(n,e,t),E(t==="deny"?"승인 대기를 거부했습니다":"확인 실행을 완료했습니다","success")}catch(s){const a=s instanceof Error?s.message:t==="deny"?"승인 대기 거부에 실패했습니다":"확인 실행에 실패했습니다";E(a,"error")}}function mc(e){switch(e){case"explicit":return"실제 관리 단위";case"hybrid":return"관리 단위 + 자동 보강";case"auto":return"자동 투영";default:return"source unknown"}}function vc(e){switch(e){case"explicit":return"ok";case"hybrid":return"warn";case"auto":return"warn";default:return"warn"}}function Ig(e){switch(e){case"explicit":return"지금 보이는 unit은 실제로 정의된 command-plane 관리 단위입니다.";case"hybrid":return"일부는 실제 관리 단위이고, 비어 있는 부분은 live agent roster를 보고 자동 보강한 구조입니다.";case"auto":return"이 화면은 live agent roster를 command-plane 모양으로 자동 투영한 것입니다. 실제 명령 체계와 1:1로 같다고 보면 안 됩니다.";default:return"이 화면은 managed topology와 effective topology가 섞여 있을 수 있습니다."}}function Tg(e){const t=e.unit.source??"unknown";return t==="explicit"?e.active_operation_count&&e.active_operation_count>0?"실제 관리 단위이며 연결된 작전이 있습니다.":"실제 관리 단위이지만 현재 연결된 작전은 없습니다.":t==="hybrid"?e.active_operation_count&&e.active_operation_count>0?"관리 단위를 기반으로 자동 보강된 구조이며 일부 작전이 연결돼 있습니다.":"관리 단위를 기반으로 자동 보강된 구조이며 현재 실행 연결은 약합니다.":e.active_operation_count&&e.active_operation_count>0?"자동 생성된 구조이지만 이 노드에 연결된 작전 흔적은 있습니다.":"자동 생성된 구조이며 현재 실행 연결은 없습니다."}function _c({node:e,depth:t=0}){const n=e.roster_live??0,s=e.roster_total??e.unit.roster.length,a=e.active_operation_count??0,i=e.unit.policy,l=e.unit.source??"unknown",c=a>0?`${a}개 작전 연결`:"실행 연결 없음";return o`
    <div class="command-tree-node depth-${Math.min(t,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${e.unit.label}</strong>
            <span class="command-chip">${A_(e.unit.kind)}</span>
            <span class="command-chip ${L(e.health)}">${e.health??"ok"}</span>
            <span class="command-chip ${vc(l)}">${mc(l)}</span>
            <span class="command-chip ${a>0?"ok":"warn"}">${c}</span>
            ${i!=null&&i.frozen?o`<span class="command-chip warn">frozen</span>`:null}
            ${i!=null&&i.kill_switch?o`<span class="command-chip bad">kill-switch</span>`:null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${e.unit.unit_id}</span>
            <span>Leader ${e.unit.leader_id??"unassigned"} / ${e.leader_status??"unknown"}</span>
            <span>Roster ${n}/${s}</span>
            <span>Ops ${a}</span>
            <span>Autonomy ${(i==null?void 0:i.autonomy_level)??"n/a"}</span>
          </div>
          <div class="command-card-sub">${Tg(e)}</div>
          ${e.reasons&&e.reasons.length>0?o`<div class="command-tag-row">
                ${e.reasons.map(p=>o`<span class="command-tag warn">${p}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${e.children.length>0?o`<div class="command-tree-children">
            ${e.children.map(p=>o`<${_c} node=${p} depth=${t+1} />`)}
          </div>`:null}
    </div>
  `}function Rg({alert:e}){return o`
    <article class="command-alert ${L(e.severity)}">
      <div class="command-card-head">
        <strong>${e.title??e.kind??e.alert_id}</strong>
        <span class="command-chip ${L(e.severity)}">${e.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${e.scope_type??"scope"}:${e.scope_id??"n/a"}</span>
        <span>${Y(e.timestamp)}</span>
      </div>
      ${e.detail?o`<p>${e.detail}</p>`:null}
    </article>
  `}function yi({event:e}){return o`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${e.event_type}</strong>
          <span class="command-chip">${e.source??"control_plane"}</span>
          <span class="command-chip">${Y(e.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${e.operation_id??e.trace_id}
          ${e.unit_id?` · ${e.unit_id}`:""}
          ${e.actor?` · ${e.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${ua(e.detail)}</pre>
    </article>
  `}function Pg(){const e=De.value,t=e==null?void 0:e.topology,n=t==null?void 0:t.source,s=t==null?void 0:t.summary,a=(s==null?void 0:s.managed_unit_count)??0,i=(s==null?void 0:s.active_operation_count)??0;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${O} panelId="command.topology" compact=${!0} />
      </div>
      ${e?o`
            <div class="command-topology-explainer">
              <div class="command-tree-title-row">
                <span class="command-chip ${vc(n)}">${mc(n)}</span>
                <span class="command-chip">${a} managed</span>
                <span class="command-chip ${i>0?"ok":"warn"}">${i} active ops</span>
              </div>
              <p>${Ig(n)}</p>
            </div>
          `:null}
      ${e&&e.topology.units.length>0?o`${e.topology.units.map(l=>o`<${_c} node=${l} />`)}`:o`<div class="empty-state">지금은 live agent나 managed unit 기준으로 그릴 지휘 계층이 없습니다.</div>`}
    </section>
  `}function Lg(){const e=De.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${O} panelId="command.alerts" compact=${!0} />
      </div>
      ${e&&e.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${e.alerts.alerts.map(t=>o`<${Rg} alert=${t} />`)}
          </div>`:o`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function zg(){const e=De.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${O} panelId="command.trace" compact=${!0} />
      </div>
      ${e&&e.traces.events.length>0?o`<div class="command-trace-stack">
            ${e.traces.events.map(t=>o`<${yi} event=${t} />`)}
          </div>`:o`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function Mg(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Ng(e,t){return(t==null?void 0:t.status)==="abandoned"||(e==null?void 0:e.recommended_kind)==="continue"?"warn":(e==null?void 0:e.recommended_kind)==="rerun"?"bad":"ok"}function Eg(e){switch(e){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(e==null?void 0:e.trim())||"결정"}}function gc({swarm:e}){var _,f;const t=e.run_id,n=e.resolution_recommendation,s=e.run_resolution;if(!t||!n&&!s)return null;const a=ic()??"dashboard",i=((_=_e.value)==null?void 0:_.pending_confirms.find(h=>h.target_type==="swarm_run"&&h.target_id===t))??null,l=Ng(n,s),c=((f=e.operation)==null?void 0:f.operation_id)??e.operation_id??void 0,p={run_id:t};c&&(p.operation_id=c),n!=null&&n.reason&&(p.reason=n.reason);const m=async h=>{await vl({actor:a,action_type:h,target_type:"swarm_run",target_id:t,payload:p})},u=async h=>{i&&await _l(a,i.confirm_token,h)};return o`
    <article class="command-guide-card ${L(l)}">
      <div class="command-guide-head">
        <strong>Run Resolution</strong>
        <span class="command-chip ${L(l)}">
          ${Eg((s==null?void 0:s.status)??(n==null?void 0:n.recommended_kind)??null)}
        </span>
      </div>
      <p>
        ${(s==null?void 0:s.status)==="abandoned"?`이 run은 ${s.decided_by}가 ${Y(s.decided_at)}에 soft abandon 처리했습니다. ${s.reason}`:(n==null?void 0:n.reason)??"이 run에 대한 별도 resolution recommendation은 아직 없습니다."}
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
              ${n.evidence.runtime_blocker?o`<span class="command-tag ${L("bad")}">${n.evidence.runtime_blocker}</span>`:null}
            </div>
          `:null}
      ${i?o`
            <div class="command-guide-card warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip warn">${i.confirm_token}</span>
              </div>
              ${i.preview?o`<pre class="command-trace-detail">${Mg(i.preview)}</pre>`:null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${()=>{u("confirm")}} disabled=${W.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${()=>{u("deny")}} disabled=${W.value}>취소</button>
              </div>
            </div>
          `:n?o`
              <div class="command-action-row">
                ${n.continue_available?o`<button class="control-btn ghost" onClick=${()=>{m("swarm_run_continue")}} disabled=${W.value}>Continue</button>`:null}
                ${n.rerun_available?o`<button class="control-btn" onClick=${()=>{m("swarm_run_rerun")}} disabled=${W.value}>Rerun</button>`:null}
                ${n.abandon_available?o`<button class="control-btn ghost" onClick=${()=>{m("swarm_run_abandon")}} disabled=${W.value}>Abandon</button>`:null}
              </div>
            `:null}
    </article>
  `}function fc(e){return e.motion_state==="stalled"||e.hard_flags.some(t=>t.severity==="bad")?"bad":e.motion_state==="waiting"||e.hard_flags.some(t=>t.severity==="warn")?"warn":"ok"}function $c({lanes:e}){const t={moving:0,waiting:0,stalled:0,terminal:0};for(const a of e){const i=a.motion_state;i in t?t[i]++:t.waiting++}if(e.length===0)return null;const s=[{key:"moving",count:t.moving,color:"var(--ok)"},{key:"waiting",count:t.waiting,color:"var(--warn)"},{key:"stalled",count:t.stalled,color:"var(--bad)"},{key:"terminal",count:t.terminal,color:"#556"}];return o`
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
  `}function jg({total:e}){const n=Math.min(e,20),s=e>20?e-20:0,a=Array.from({length:n});return o`
    <div class="swarm-worker-grid">
      ${a.map(()=>o`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?o`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${e})</span>
    </div>
  `}function wg({lane:e}){const t=e.counts??{},n=fc(e),s=t.workers??0,a=t.operations??0,i=t.detachments??0,l=a+i,c=e.motion_state==="moving"?84:e.motion_state==="waiting"?58:e.motion_state==="terminal"?100:26;return o`
    <article class="swarm-lane-strip ${L(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${e.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${e.kind} · ${e.source_of_truth}</span>
            <strong>${e.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${L(n)}">${e.phase}</span>
          <span class="command-chip ${L(n)}">${e.motion_state}</span>
          <span class="command-chip">${Y(e.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${e.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${L(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${e.current_step}</span>
        </div>
        ${s>0?o`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${jg} total=${s} />
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
              ${e.hard_flags.map(p=>o`<span class="command-chip ${L(p.severity)}">${p.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function hc({lanes:e}){const t=e.slice(0,4);return t.length===0?null:o`
    <div class="swarm-storyboard">
      ${t.map(n=>{const s=fc(n),a=n.counts.workers??0,i=n.counts.operations??0,l=n.counts.detachments??0;return o`
          <article class="swarm-story-card ${L(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${L(s)}">${n.motion_state}</span>
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
  `}function Dg({event:e}){const t=e.timestamp?new Date(e.timestamp):null,n=t&&!isNaN(t.getTime())?t:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return o`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${L(e.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${e.title}</strong>
        <span class="swarm-event-kind">${e.kind}</span>
        ${e.detail?o`<div class="command-card-sub">${e.detail}</div>`:null}
      </div>
    </div>
  `}function Og({gap:e}){return o`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${L(e.severity)}">${e.code} (${e.count})</span>
      <span class="command-card-sub">${e.summary}</span>
    </div>
  `}function qg({proof:e}){const t=(e==null?void 0:e.status)==="missing"?"warn":(e==null?void 0:e.pass)===!1?"bad":(e==null?void 0:e.pass)===!0?"ok":"warn";return o`
    <div class="command-guide-card ${L(t)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${L(t)}">${(e==null?void 0:e.status)??"missing"}</span>
        </div>
      ${e?o`
            <div class="command-card-grid">
              <span>소스</span><span>${e.source}</span>
              <span>런</span><span>${e.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${Y(e.captured_at)}</span>
              <span>통과</span><span>${e.pass==null?"n/a":e.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${e.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${e.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${e.workers.expected??"n/a"} 예상 · ${e.workers.done??"n/a"} 완료 · ${e.workers.final??"n/a"} 최종</span>
            </div>
            ${e.artifact_ref?o`<div class="command-card-foot">${e.artifact_ref}</div>`:null}
            ${e.missing_reason?o`<p>${e.missing_reason}</p>`:null}
          `:o`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function Fg(){const e=as(),t=ts(F.value),n=T_(t),s=e==null?void 0:e.swarm_status,a=e==null?void 0:e.swarm_proof,i=(s==null?void 0:s.lanes.filter(_=>_.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],p=s==null?void 0:s.overview,m=s==null?void 0:s.recommended_next_action,u=i.length<=1;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${O} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?o`
            <${hc} lanes=${i} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(p==null?void 0:p.active_lanes)??0}</strong><small>${(p==null?void 0:p.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(p==null?void 0:p.stalled_lanes)??0}</strong><small>${(p==null?void 0:p.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${Y(p==null?void 0:p.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${Y(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${i.length>0?o`<${$c} lanes=${i} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${i.length>0?i.map(_=>o`<${wg} lane=${_} />`):o`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${qg} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${L(l.some(_=>_.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?o`<div class="swarm-event-rail">${l.slice(0,4).map(_=>o`<${Og} gap=${_} />`)}</div>`:o`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?o`<div class="swarm-event-rail">${c.map(_=>o`<${Dg} event=${_} />`)}</div>`:o`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:o`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function Kg({item:e}){return o`
    <article class="command-guide-card ${L(e.status)}">
      <div class="command-guide-head">
        <strong>${e.title}</strong>
        <span class="command-chip ${L(e.status)}">${e.status}</span>
      </div>
      <p>${e.detail}</p>
      <div class="command-card-foot">Next tool: ${e.next_tool}</div>
    </article>
  `}function yc({blocker:e}){return o`
    <article class="command-alert ${L(e.severity)}">
      <div class="command-card-head">
        <strong>${e.title}</strong>
        <span class="command-chip ${L(e.severity)}">${e.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${e.code}</span>
        <span>next ${e.next_tool}</span>
      </div>
      <p>${e.detail}</p>
    </article>
  `}function Bg({worker:e}){return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.name}</strong>
          <div class="command-card-sub">${e.role} · ${e.lane}</div>
        </div>
        <span class="command-chip ${L(e.joined?e.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${e.last_message?o`<div class="command-card-foot">${Y(e.last_message.timestamp)} · ${e.last_message.content}</div>`:null}
    </article>
  `}function Ug(){var p,m,u,_,f,h,b,$,S,A,x,z,T,P,M,R,N,Z,oe,V,ee;const e=Pt.value,t=lc(),n=_i(),s=(p=e==null?void 0:e.provider)!=null&&p.runtime_blocker?"blocked":(m=e==null?void 0:e.provider)!=null&&m.provider_reachable?"ready":"check",a=((u=e==null?void 0:e.provider)==null?void 0:u.actual_slots)??((_=e==null?void 0:e.provider)==null?void 0:_.total_slots)??0,i=((f=e==null?void 0:e.provider)==null?void 0:f.expected_slots)??"n/a",l=((h=e==null?void 0:e.provider)==null?void 0:h.actual_ctx)??((b=e==null?void 0:e.provider)==null?void 0:b.ctx_per_slot)??0,c=(($=e==null?void 0:e.provider)==null?void 0:$.expected_ctx)??"n/a";return o`
    <div class="command-section-stack">
      <${Fg} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${sa.value?o`<div class="empty-state">Loading swarm live state…</div>`:aa.value?o`<div class="empty-state error">${aa.value}</div>`:e?o`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${e.run_id??t??"swarm-live"}</strong><small>${e.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((S=e.summary)==null?void 0:S.joined_workers)??0}/${((A=e.summary)==null?void 0:A.expected_workers)??0}</strong><small>${((x=e.summary)==null?void 0:x.live_workers)??0}개 가동 · ${((z=e.summary)==null?void 0:z.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${i} · ctx ${l}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(T=e.summary)!=null&&T.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((P=e.provider)==null?void 0:P.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(M=e.summary)!=null&&M.pass_end_to_end?"통과":"확인 필요"}</strong><small>${e.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((R=e.operation)==null?void 0:R.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((N=e.squad)==null?void 0:N.label)??"없음"}</span>
                      <span>실행체</span><span>${((Z=e.detachment)==null?void 0:Z.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((oe=e.summary)==null?void 0:oe.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((V=e.summary)==null?void 0:V.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((ee=e.provider)==null?void 0:ee.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${e.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${e.truth_notes.length>0?o`<div class="command-tag-row">
                          ${e.truth_notes.map(C=>o`<span class="command-tag">${C}</span>`)}
                        </div>`:null}
                    <${gc} swarm=${e} />
                  `:o`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.checklist.length>0?o`<div class="command-card-stack">
                ${e.checklist.map(C=>o`<${Kg} item=${C} />`)}
              </div>`:o`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.workers.length>0?o`<div class="command-card-stack">
                ${e.workers.map(C=>o`<${Bg} worker=${C} />`)}
              </div>`:o`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${O} panelId="command.swarm" compact=${!0} />
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
                  <span>Last Sample</span><span>${e.provider.last_sample_at?Y(e.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${e.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${e.provider.checked_at?Y(e.provider.checked_at):"n/a"}</span>
                </div>
                ${e.provider.detail?o`<div class="command-card-sub">${e.provider.detail}</div>`:null}
                ${e.provider.timeline.length>0?o`<div class="command-trace-stack">
                      ${e.provider.timeline.slice(-12).map(C=>o`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${C.active_slots} active</strong>
                              <span class="command-chip">${Y(C.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${C.active_slot_ids.join(", ")||"none"}</div>
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
          ${e&&e.blockers.length>0?o`<div class="command-card-stack">
                ${e.blockers.map(C=>o`<${yc} blocker=${C} />`)}
              </div>`:o`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(e==null?void 0:e.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${O} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.recent_messages.length>0?o`<div class="command-trace-stack">
                ${e.recent_messages.map(C=>o`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${C.from}</strong>
                        <span class="command-chip">${Y(C.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${C.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${C.content}</pre>
                  </article>
                `)}
              </div>`:o`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${O} panelId="command.trace" compact=${!0} />
          </div>
          ${e&&e.recent_trace_events.length>0?o`<div class="command-trace-stack">
                ${e.recent_trace_events.map(C=>o`<${yi} event=${C} />`)}
              </div>`:o`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function Hg(e){var n;const t=[e.current_task_matches_run?"current":"drift",e.claim_marker_seen?"claim":"no-claim",e.done_marker_seen?"done":"no-done",e.final_marker_seen?"final":"no-final"];return{key:`swarm:${e.name}`,name:e.name,role:e.role,lane:e.lane,status:e.status,source:"swarm",task:e.current_task??e.bound_task_title??e.bound_task_id??"none",heartbeat:e.heartbeat_age_sec!=null?`${Math.round(e.heartbeat_age_sec)}s`:e.heartbeat_fresh?"clean":"n/a",detail:[e.bound_task_status??null,e.detachment_member?"detachment":null,e.squad_member?"squad":null].filter(Boolean).join(" · ")||"live swarm worker",markers:t,note:((n=e.last_message)==null?void 0:n.content)??null}}function Wg(e,t){const n=e.actor??e.spawn_role??`worker-${t+1}`,s=e.spawn_role??e.worker_class??e.spawn_agent??"worker",a=e.lane_id??e.capsule_mode??e.control_domain??"session",i=[e.has_turn?"turn":"silent",e.empty_note_turn_count>0?`empty:${e.empty_note_turn_count}`:"noted",e.turn_count>0?`turns:${e.turn_count}`:"turns:0"];return{key:`session:${n}:${t}`,name:n,role:s,lane:a,status:e.status,source:"session",task:e.task_profile??e.runtime_pool??"session lane",heartbeat:e.last_turn_ts_iso?Y(e.last_turn_ts_iso):"n/a",detail:[e.spawn_agent??null,e.spawn_model??null,e.routing_confidence!=null?ns(e.routing_confidence):null].filter(Boolean).join(" · ")||"session worker",markers:i,note:e.routing_reason??null}}function rr(e){return L(e.severity)}function Gg({worker:e}){return o`
    <article class="command-card compact warroom-worker-card ${L(qt(e.status))}">
      <div class="command-card-head">
        <div>
          <strong>${e.name}</strong>
          <div class="command-card-sub">${e.role} · ${e.lane}</div>
        </div>
        <span class="command-chip ${L(qt(e.status))}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Source</span><span>${e.source}</span>
        <span>Task</span><span>${e.task}</span>
        <span>Heartbeat</span><span>${e.heartbeat}</span>
        <span>Detail</span><span>${e.detail}</span>
      </div>
      <div class="command-tag-row">
        ${e.markers.map(t=>o`<span class="command-tag">${t}</span>`)}
      </div>
      ${e.note?o`<div class="command-card-foot">${e.note}</div>`:null}
    </article>
  `}function Je({label:e,surface:t,params:n={}}){return o`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(t){nt(t),se("command",{...vi(t),...n});return}se("intervene")}}
    >
      ${e}
    </button>
  `}function Jg(){var ee,C,Ie,We,mt,vt,K,Te,_t,pn,mn,os,is,rs,ls,cs,ds,us,Ii,Ti,Ri;const e=as(),t=Pt.value,n=_e.value,s=je.value,a=E_(),i=t!=null&&t.operation?((ee=es.value)==null?void 0:ee.operations.find(Q=>{var ps;return Q.operation.operation_id===((ps=t.operation)==null?void 0:ps.operation_id)}))??null:null,l=M_(),c=(t==null?void 0:t.workers)??[],p=(s==null?void 0:s.worker_cards)??[],m=l&&c.length>0?c.map(Hg):p.map(Wg),u=l,_=((C=e==null?void 0:e.decisions.summary)==null?void 0:C.pending)??0,f=(n==null?void 0:n.pending_confirms)??[],h=l?(t==null?void 0:t.blockers)??[]:[],b=(s==null?void 0:s.recommended_actions)??[],$=(Ie=s==null?void 0:s.active_recommended_actions)!=null&&Ie.length?s.active_recommended_actions:b,S=s==null?void 0:s.active_summary,A=(s==null?void 0:s.active_guidance_layer)??"fallback",x=(s==null?void 0:s.resident_judge_runtime)??(n==null?void 0:n.resident_judge_runtime),z=(s==null?void 0:s.attention_items)??[],T=((We=t==null?void 0:t.recent_messages[0])==null?void 0:We.timestamp)??null,P=((mt=t==null?void 0:t.recent_trace_events[0])==null?void 0:mt.timestamp)??null,M=l?T??P??null:null,R=a==null?void 0:a.summary,N=(l?(vt=t==null?void 0:t.summary)==null?void 0:vt.expected_workers:void 0)??(typeof(R==null?void 0:R.planned_worker_count)=="number"?R.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,Z=(l?(K=t==null?void 0:t.summary)==null?void 0:K.joined_workers:void 0)??(typeof(R==null?void 0:R.active_agent_count)=="number"?R.active_agent_count:void 0)??m.length,oe=h.length>0||_>0||f.length>0?"warn":u||a?"ok":"warn",V=l?((Te=e==null?void 0:e.swarm_status)==null?void 0:Te.lanes.filter(Q=>Q.present))??[]:[];return ne(()=>{ye()},[]),ne(()=>{a!=null&&a.session_id&&sn(a.session_id)},[a==null?void 0:a.session_id,n,(_t=t==null?void 0:t.detachment)==null?void 0:_t.session_id]),!u&&!a?sa.value||Mn.value?o`<div class="empty-state">live war room 불러오는 중…</div>`:o`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">라이브 워룸</div>
          <${O} panelId="command.warroom" compact=${!0} />
        </div>
        <div class="command-warroom-empty-copy">
          <strong>현재 live run 없음</strong>
          <p>활성 operation 또는 team session이 시작되면 이 화면이 자동으로 붙잡습니다.</p>
        </div>
        <div class="command-action-row">
          <${Je} label="작전 보기" surface="operations" />
          <${Je} label="스웜 보기" surface="swarm" />
          <${Je} label="개입 열기" />
          <${Je} label="제어 보기" surface="control" />
        </div>
      </section>
    `:o`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${L(oe)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">Live War Room</span>
            <strong>${l?((pn=t==null?void 0:t.operation)==null?void 0:pn.objective)??(a==null?void 0:a.session_id)??"active run":(a==null?void 0:a.session_id)??"active run"}</strong>
            <div class="command-card-sub">
              ${l?((mn=t==null?void 0:t.operation)==null?void 0:mn.operation_id)??"operation 없음":"session truth"}
              ${a!=null&&a.session_id?` · session ${a.session_id}`:""}
              ${l&&((os=t==null?void 0:t.detachment)!=null&&os.detachment_id)?` · detachment ${t.detachment.detachment_id}`:""}
            </div>
            ${S!=null&&S.summary?o`<div class="command-warroom-guidance ${ga(A)}">
                  <strong>${fi(A)}</strong>
                  <span>${S.summary}</span>
                </div>`:null}
          </div>
          <div class="command-action-row">
            <${Je}
              label="스웜 상세"
              surface="swarm"
              params=${{...l&&((is=t==null?void 0:t.operation)!=null&&is.operation_id)?{operation_id:t.operation.operation_id}:{},...l&&(t!=null&&t.run_id)?{run_id:t.run_id}:{}}}
            />
            <${Je} label="트레이스" surface="trace" />
            ${l&&i?o`<${Je}
                  label="체인"
                  surface="chains"
                  params=${{operation:i.operation.operation_id}}
                />`:null}
            <${Je} label="Intervene" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>Workers</span>
            <strong>${Z??0}/${N??0}</strong>
            <small>${l?((rs=t==null?void 0:t.summary)==null?void 0:rs.completed_workers)??0:0} 완료 · ${m.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${l?(ls=t==null?void 0:t.provider)!=null&&ls.runtime_blocker?"blocked":(cs=t==null?void 0:t.provider)!=null&&cs.provider_reachable?"ready":a?_s(a.status):"check":a?_s(a.status):"check"}</strong>
            <small>${l?`slots ${((ds=t==null?void 0:t.provider)==null?void 0:ds.active_slots_now)??0}/${((us=t==null?void 0:t.provider)==null?void 0:us.actual_slots)??((Ii=t==null?void 0:t.provider)==null?void 0:Ii.total_slots)??0} · ctx ${((Ti=t==null?void 0:t.provider)==null?void 0:Ti.actual_ctx)??((Ri=t==null?void 0:t.provider)==null?void 0:Ri.ctx_per_slot)??0}`:`session workers ${(s==null?void 0:s.worker_cards.length)??0}`}</small>
          </div>
          <div class="monitor-stat-card ${L(h.length>0||_>0?"warn":"ok")}">
            <span>Pressure</span>
            <strong>${h.length+_+f.length}</strong>
            <small>blockers ${h.length} · approvals ${_} · confirms ${f.length}</small>
          </div>
          <div class="monitor-stat-card ${L(ga(A))}">
            <span>Resident Judge</span>
            <strong>${$i(x)}</strong>
            <small>${hi(S)}${x!=null&&x.model_used?` · ${x.model_used}`:""}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${Y(M)}</strong>
            <small>${T?"message":P?"trace":"waiting"}</small>
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
            ${V.length>0?o`
                  <${hc} lanes=${V} />
                  <${$c} lanes=${V} />
                `:a?o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${L(qt(a.status))}">${_s(a.status)}</span>
                      </div>
                      <p>command-plane live run은 아직 옅지만, session 쪽 worker와 digest를 기준으로 워룸을 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${hn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${hn(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:o`<div class="empty-state">보이는 lane이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Worker Roster</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${m.length>0?o`<div class="command-card-stack">
                  ${m.map(Q=>o`<${Gg} worker=${Q} />`)}
                </div>`:o`<div class="empty-state">활성 worker 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Live Feed</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            ${t&&t.recent_messages.length>0&&l?o`<div class="command-trace-stack">
                  ${t.recent_messages.map(Q=>o`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${Q.from}</strong>
                          <span class="command-chip">${Y(Q.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${Q.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${Q.content}</pre>
                    </article>
                  `)}
                </div>`:$.length>0||z.length>0?o`<div class="command-card-stack">
                    ${$.slice(0,4).map(Q=>o`
                      <article class="command-guide-card ${rr(Q)}">
                        <div class="command-guide-head">
                          <strong>${Q.action_type}</strong>
                          <span class="command-chip ${rr(Q)}">${Q.target_type}</span>
                        </div>
                        <p>${Q.reason}</p>
                      </article>
                    `)}
                    ${z.slice(0,3).map(Q=>o`
                      <article class="command-alert ${L(Q.severity)}">
                        <div class="command-card-head">
                          <strong>${Q.kind}</strong>
                          <span class="command-chip ${L(Q.severity)}">${Q.severity}</span>
                        </div>
                        <p>${Q.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?o`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((Q,ps)=>o`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>session-event-${ps+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${ua(Q)}</pre>
                        </article>
                      `)}
                    </div>`:o`<div class="empty-state">메시지나 attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Trace Feed</div>
              <${O} panelId="command.trace" compact=${!0} />
            </div>
            ${t&&t.recent_trace_events.length>0?o`<div class="command-trace-stack">
                  ${t.recent_trace_events.map(Q=>o`<${yi} event=${Q} />`)}
                </div>`:o`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Pressure</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&t?o`<${gc} swarm=${t} />`:null}
              ${h.length>0?h.map(Q=>o`<${yc} blocker=${Q} />`):o`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${_>0?o`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending approvals</strong>
                        <span class="command-chip warn">${_}</span>
                      </div>
                      <p>strict action이 묶여 있습니다. 실제 승인 처리는 control 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${f.length>0?o`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending confirms</strong>
                        <span class="command-chip warn">${f.length}</span>
                      </div>
                      <p>operator preview가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${f.slice(0,3).map(Q=>o`<span class="command-tag">${Q.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
            </div>
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Focus Detail</div>
              <${O} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&(t!=null&&t.operation)?o`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${t.operation.objective}</strong>
                          <div class="command-card-sub">${t.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${L(qt(t.operation.status))}">${t.operation.status}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Unit</span><span>${t.operation.assigned_unit_id}</span>
                        <span>Trace</span><span>${t.operation.trace_id}</span>
                        <span>Autonomy</span><span>${t.operation.autonomy_level??"n/a"}</span>
                        <span>Updated</span><span>${Y(t.operation.updated_at)}</span>
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
                        <span class="command-chip ${L(qt(t.detachment.status))}">${t.detachment.status??"active"}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Leader</span><span>${t.detachment.leader_id??"unassigned"}</span>
                        <span>Roster</span><span>${t.detachment.roster.length}</span>
                        <span>Session</span><span>${t.detachment.session_id??"none"}</span>
                        <span>Heartbeat</span><span>${sc(t.detachment.heartbeat_deadline)}</span>
                      </div>
                    </article>
                  `:null}
              ${a?o`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${a.session_id}</strong>
                          <div class="command-card-sub">team session focus</div>
                        </div>
                        <span class="command-chip ${L(qt(a.status))}">${_s(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${hn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${hn(a.remaining_sec)}</span>
                        <span>Done delta</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function Vg({source:e}){const t=Kc(null),[n,s]=xr(null);return ne(()=>{let a=!1;const i=t.current;return i?(i.innerHTML="",s(null),(async()=>{try{const c=await f_(),{svg:p}=await c.render(`command-chain-${g_()}`,e);if(a||!t.current)return;t.current.innerHTML=p}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid render failed")}})(),()=>{a=!0,t.current&&(t.current.innerHTML="")}):void 0},[e]),o`
    <div class="command-chain-graph-shell">
      ${n?o`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${t}></div>
    </div>
  `}function Qg({overlay:e,selected:t,onSelect:n}){const s=e.operation.chain,a=e.runtime;return o`
    <button class="command-chain-item ${t?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${e.operation.objective}</strong>
          <div class="command-card-sub">${e.operation.operation_id}</div>
        </div>
        <span class="command-chip ${st(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??e.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?o`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?o`<span class="command-tag ${st(s==null?void 0:s.status)}">${ns(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${ac(e.history)}</div>
    </button>
  `}function Yg({item:e}){return o`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${e.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${st(e.event)}">${e.event}</span>
      </div>
      <div class="command-card-sub">${Y(e.timestamp)}</div>
      <div class="command-card-sub">${ac(e)}</div>
    </article>
  `}function Xg({node:e}){return o`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${e.id}</strong>
        <span class="command-chip ${st(e.status)}">${e.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${e.type??"node"}
        ${typeof e.duration_ms=="number"?` · ${e.duration_ms}ms`:""}
      </div>
      ${e.error?o`<div class="command-card-sub error-text">${e.error}</div>`:null}
    </article>
  `}function Zg({card:e}){const t=e.operation,n=`pause:${t.operation_id}`,s=`resume:${t.operation_id}`,a=`recall:${t.operation_id}`,i=t.chain,l=(i==null?void 0:i.run_id)??null;return o`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${t.objective}</strong>
          <div class="command-card-sub">${t.operation_id}</div>
        </div>
        <span class="command-chip ${L(t.status==="active"?"ok":t.status==="paused"?"warn":t.status==="failed"?"bad":"ok")}">${t.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${e.assigned_unit_label??t.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Autonomy</span><span>${t.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${t.budget_class??"standard"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Updated</span><span>${Y(t.updated_at)}</span>
      </div>
      ${i?o`
            <div class="command-tag-row">
              <span class="command-tag">${i.kind}</span>
              <span class="command-tag ${st(i.status)}">${i.status}</span>
              ${i.chain_id?o`<span class="command-tag">${i.chain_id}</span>`:null}
              ${i.run_id?o`<span class="command-tag">run ${i.run_id}</span>`:null}
            </div>
          `:null}
      ${t.checkpoint_ref?o`<div class="command-card-foot">Checkpoint ${t.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{nt("swarm"),se("command",{surface:"swarm",operation_id:t.operation_id,...l?{run_id:l}:{}})}}
        >
          Swarm Live
        </button>
        ${i?o`
              <button
                class="control-btn ghost"
                onClick=${()=>{ii(t.operation_id),nt("chains"),se("command",{surface:"chains",operation:t.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="active"?o`
              <button class="control-btn ghost" disabled=${ie(n)} onClick=${()=>at(()=>Jm(t.operation_id))}>
                ${ie(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${ie(a)} onClick=${()=>at(()=>Qm(t.operation_id))}>
                ${ie(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="paused"?o`
              <button class="control-btn ghost" disabled=${ie(s)} onClick=${()=>at(()=>Vm(t.operation_id))}>
                ${ie(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function ef({card:e}){var n;const t=e.detachment;return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.detachment_id}</strong>
          <div class="command-card-sub">${((n=e.operation)==null?void 0:n.objective)??t.operation_id}</div>
        </div>
        <span class="command-chip ${L(t.status)}">${t.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${e.assigned_unit_label??t.assigned_unit_id}</span>
        <span>Leader</span><span>${t.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${t.roster.length}</span>
        <span>Session</span><span>${t.session_id??"none"}</span>
        <span>Runtime</span><span>${t.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${t.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${Y(t.last_progress_at)}</span>
        <span>Heartbeat</span><span>${sc(t.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Y(t.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${t.heartbeat_deadline?o`<span class="command-tag ${v_(t.heartbeat_deadline)}">
              deadline ${t.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function tf(){const e=De.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${O} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.operations.operations.length>0?o`<div class="command-card-stack">
              ${e.operations.operations.map(t=>o`<${Zg} card=${t} />`)}
            </div>`:o`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${O} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${e.detachments.detachments.map(t=>o`<${ef} card=${t} />`)}
            </div>`:o`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function nf(){var c,p,m,u,_,f,h,b,$,S,A,x,z,T,P,M;const e=es.value,t=(e==null?void 0:e.operations)??[],n=Vt.value,s=t.find(R=>R.operation.operation_id===n)??t[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,i=((p=En.value)==null?void 0:p.run)??(s==null?void 0:s.preview_run)??null,l=!((m=En.value)!=null&&m.run)&&!!(s!=null&&s.preview_run);return ne(()=>{a?Wm(a):Hm()},[a]),o`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${O} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${st(e==null?void 0:e.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${st(e==null?void 0:e.connection.status)}">${(e==null?void 0:e.connection.status)??"disconnected"}</span>
          </div>
          <p>${(e==null?void 0:e.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(e==null?void 0:e.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((u=e==null?void 0:e.summary)==null?void 0:u.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((_=e==null?void 0:e.summary)==null?void 0:_.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((f=e==null?void 0:e.summary)==null?void 0:f.recent_failures)??0}</span>
            <span>Last Event</span><span>${Y((h=e==null?void 0:e.summary)==null?void 0:h.last_history_event_at)}</span>
          </div>
        </article>

        ${ia.value?o`<div class="empty-state error">${ia.value}</div>`:null}

        ${Mo.value&&!e?o`<div class="empty-state">Loading chain overlays…</div>`:t.length>0?o`
                <div class="command-chain-list">
                  ${t.map(R=>o`
                    <${Qg}
                      overlay=${R}
                      selected=${(s==null?void 0:s.operation.operation_id)===R.operation.operation_id}
                      onSelect=${()=>ii(R.operation.operation_id)}
                    />
                  `)}
                </div>
              `:o`<div class="empty-state">No chain-backed operations yet.</div>`}

        <div class="command-chain-history">
          <div class="command-guide-head">
            <strong>Recent history</strong>
            <span class="command-chip">${(e==null?void 0:e.recent_history.length)??0}</span>
          </div>
          ${e&&e.recent_history.length>0?o`
                <div class="command-card-stack">
                  ${e.recent_history.slice(0,6).map(R=>o`<${Yg} item=${R} />`)}
                </div>
              `:o`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${O} panelId="command.chains" compact=${!0} />
        </div>
        ${s?o`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${st((b=s.operation.chain)==null?void 0:b.status)}">
                    ${(($=s.operation.chain)==null?void 0:$.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((S=s.operation.chain)==null?void 0:S.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((A=s.operation.chain)==null?void 0:A.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${ns((x=s.runtime)==null?void 0:x.progress)}</span>
                  <span>Elapsed</span><span>${hn((z=s.runtime)==null?void 0:z.elapsed_sec)}</span>
                  <span>Updated</span><span>${Y(((T=s.operation.chain)==null?void 0:T.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(P=s.operation.chain)!=null&&P.goal?o`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?o`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((M=s.operation.chain)==null?void 0:M.chain_id)??"graph"}</span>
                      </div>
                      <${Vg} source=${s.mermaid} />
                    </div>
                  `:o`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(i==null?void 0:i.success)===!1?"bad":"ok"}">
                    ${i?i.success===!1?"failed":l?"preview":"captured":"pending"}
                  </span>
                </div>
                ${ra.value?o`<div class="empty-state">Loading run detail…</div>`:jn.value?o`<div class="empty-state error">${jn.value}</div>`:i&&i.nodes.length>0?o`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${i.chain_id}</span>
                            <span>Run</span><span>${i.run_id??"preview only"}</span>
                            <span>Duration</span><span>${i.duration_ms!=null?`${i.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${i.nodes.length}</span>
                          </div>
                          ${l?o`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${i.nodes.map(R=>o`<${Xg} node=${R} />`)}
                          </div>
                        `:o`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:o`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function sf({decision:e}){const t=`approve:${e.decision_id}`,n=`deny:${e.decision_id}`,s=e.source==="projected_operator";return o`
    <article class="command-card ${L(e.status)}">
      <div class="command-card-head">
        <div>
          <strong>${e.requested_action}</strong>
          <div class="command-card-sub">${e.scope_type}:${e.scope_id}</div>
        </div>
        <span class="command-chip ${L(e.status)}">${e.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${e.decision_id}</span>
        <span>By</span><span>${e.requested_by??"unknown"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Created</span><span>${Y(e.created_at)}</span>
        <span>Reason</span><span>${e.reason??"n/a"}</span>
      </div>
      ${e.status==="pending"&&!s?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${ie(t)} onClick=${()=>at(()=>Xm(e.decision_id))}>
                ${ie(t)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${ie(n)} onClick=${()=>at(()=>Zm(e.decision_id))}>
                ${ie(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?o`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function af({row:e}){var c,p,m;const t=e.unit,n=`freeze:${t.unit_id}`,s=`kill:${t.unit_id}`,a=!!((c=t.policy)!=null&&c.frozen),i=!!((p=t.policy)!=null&&p.kill_switch),l=Math.round((e.utilization??0)*100);return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.label}</strong>
          <div class="command-card-sub">${t.unit_id}</div>
        </div>
        <span class="command-chip ${L(l>100?"bad":l>70?"warn":"ok")}">${l}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${e.roster_live??0}/${e.roster_total??0}</span>
        <span>Headcount Cap</span><span>${e.headcount_cap??0}</span>
        <span>Ops</span><span>${e.active_operations??0}/${e.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((m=t.policy)==null?void 0:m.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${a?"yes":"no"}</span>
        <span>Kill Switch</span><span>${i?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${ie(n)} onClick=${()=>at(()=>ev(t.unit_id,!a))}>
          ${ie(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${ie(s)} onClick=${()=>at(()=>tv(t.unit_id,!i))}>
          ${ie(s)?"Applying…":i?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function of(){const e=De.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${O} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${e.decisions.decisions.map(t=>o`<${sf} decision=${t} />`)}
            </div>`:o`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${O} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${e.capacity.capacity.map(t=>o`<${af} row=${t} />`)}
            </div>`:o`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function rf(){return o`
    <div class="command-surface-tabs grouped">
      ${h_.map(e=>o`
        <div class="command-tab-group" key=${e.id}>
          <span class="command-tab-group-label">${e.label}</span>
          <div class="command-tab-group-items">
            ${oc.filter(t=>t.group===e.id).map(t=>o`
                <button
                  class="command-surface-tab ${G.value===t.id?"active":""}"
                  onClick=${()=>{nt(t.id),se("command",vi(t.id))}}
                >
                  ${t.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function lf(){if(G.value==="warroom")return o`<${Jg} />`;if(G.value==="summary")return o`<${Z_} />`;if(G.value==="orchestra")return o`<${cg} />`;if(G.value==="swarm")return o`<${Ug} />`;if(!De.value)return o`<${eg} />`;switch(G.value){case"chains":return o`<${nf} />`;case"topology":return o`<${Pg} />`;case"alerts":return o`<${Lg} />`;case"trace":return o`<${zg} />`;case"control":return o`<${of} />`;case"operations":default:return o`<${tf} />`}}function cf(){return ne(()=>{Ot(),Qt(),Gm(),Qe(),St()},[]),ne(()=>{if(F.value.tab!=="command")return;const e=F.value.params.surface,t=F.value.params.operation,n=ts(F.value);if(Xi(e))nt(e);else if(n){const s=Ul(n);Xi(s)&&nt(s)}else e||nt("warroom");t&&ii(t),(e==="swarm"||e==="warroom"||e==="orchestra"||G.value==="warroom"||G.value==="orchestra")&&Qe(),(e==="orchestra"||G.value==="orchestra")&&St(),(e==="warroom"||G.value==="warroom")&&ye()},[F.value.tab,F.value.params.surface,F.value.params.operation,F.value.params.operation_id,F.value.params.run_id,F.value.params.source,F.value.params.action_type,F.value.params.target_type,F.value.params.target_id,F.value.params.focus_kind]),ne(()=>{let e=null;const t=()=>{e||(e=window.setTimeout(()=>{e=null,Ot(),Qt(),(G.value==="swarm"||G.value==="warroom"||G.value==="orchestra")&&Qe(),G.value==="orchestra"&&St(),G.value==="warroom"&&ye()},250))},n=new EventSource(S_()),s=b_.map(a=>{const i=()=>t();return n.addEventListener(a,i),{type:a,handler:i}});return n.onerror=()=>{t()},()=>{s.forEach(({type:a,handler:i})=>{n.removeEventListener(a,i)}),n.close(),e&&window.clearTimeout(e)}},[]),ne(()=>{const e=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const t=G.value;t!=="swarm"&&t!=="warroom"&&t!=="orchestra"||(Ot(),Qe(),t==="orchestra"&&St(),t==="warroom"&&ye())},5e3);return()=>{window.clearInterval(e)}},[]),o`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{at(()=>Ym())}}
            disabled=${ie("dispatch:tick")}
          >
            ${ie("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Ot(),Qt(),Qe(),G.value==="warroom"&&ye()}}
            disabled=${Ys.value}
          >
            ${Ys.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Zs.value?o`<div class="empty-state error">${Zs.value}</div>`:null}
      ${ta.value?o`<div class="empty-state error">${ta.value}</div>`:null}
      <${be} surfaceId="command" />
      <${J_} />
      ${G.value==="warroom"?null:o`<${V_} />`}
      <${rf} />
      <${lf} />
    </section>
  `}function df(){var S,A;const e=_e.value,t=ei.value,n=(e==null?void 0:e.room)??{},s=(e==null?void 0:e.pending_confirms)??[],a=e==null?void 0:e.pending_confirm_summary,i=a?a.confirm_required_actions:((e==null?void 0:e.available_actions)??[]).filter(x=>x.confirm_required),l=((S=a==null?void 0:a.actor_filter)==null?void 0:S.trim())||null,c=(a==null?void 0:a.hidden_count)??0,p=(a==null?void 0:a.hidden_actors)??[],m=(e==null?void 0:e.recent_messages)??[],u=(t==null?void 0:t.recommended_actions)??[],_=(A=t==null?void 0:t.active_recommended_actions)!=null&&A.length?t.active_recommended_actions:u,f=t==null?void 0:t.active_summary,h=(t==null?void 0:t.resident_judge_runtime)??(e==null?void 0:e.resident_judge_runtime),b=(t==null?void 0:t.active_guidance_layer)??"fallback",$=m.slice(0,5);return o`
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
          <div class="ops-stat ${pg(h)}">
            <span>Resident Judge</span>
            <strong>${$i(h)}</strong>
          </div>
        </div>

        <label class="control-label" for="ops-broadcast">Room 방송</label>
        <div class="control-row">
          <input
            id="ops-broadcast"
            class="control-input"
            type="text"
            placeholder="@agent 또는 room 전체 공지"
            value=${Xt.value}
            onInput=${x=>{Xt.value=x.target.value}}
            onKeyDown=${x=>{x.key==="Enter"&&or()}}
            disabled=${W.value}
          />
          <button class="control-btn" onClick=${()=>{or()}} disabled=${W.value||Xt.value.trim()===""}>
            보내기
          </button>
        </div>

        <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
        <div class="control-row ops-split-row">
          <input
            id="ops-pause-reason"
            class="control-input"
            type="text"
            value=${pa.value}
            onInput=${x=>{pa.value=x.target.value}}
            disabled=${W.value}
          />
          <button class="control-btn ghost" onClick=${()=>{kg()}} disabled=${W.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{pc()}} disabled=${W.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${Zt.value}
          onInput=${x=>{Zt.value=x.target.value}}
          disabled=${W.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${On.value}
          onInput=${x=>{On.value=x.target.value}}
          disabled=${W.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${qn.value}
            onChange=${x=>{qn.value=x.target.value}}
            disabled=${W.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{xg()}} disabled=${W.value||Zt.value.trim()===""}>
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
        <article class="ops-guidance-card ${ga(b)}">
          <div class="ops-guidance-head">
            <strong>${fi(b)}</strong>
            <span>${(h==null?void 0:h.keeper_name)??(t==null?void 0:t.judgment_owner)??"judge 없음"}</span>
          </div>
          <div class="ops-guidance-body">
            ${(f==null?void 0:f.summary)??"현재 active guidance 요약이 없습니다. fallback queue만 표시합니다."}
          </div>
          <div class="ops-guidance-meta">
            <span>authoritative ${t!=null&&t.authoritative_judgment_available?"yes":"no"}</span>
            <span>${hi(f)}</span>
            ${h!=null&&h.model_used?o`<span>${h.model_used}</span>`:null}
          </div>
        </article>
        ${Nn.value&&!t?o`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:_.length>0?o`
          <div class="ops-log-list">
            ${_.map(x=>o`
              <article key=${`${x.action_type}:${x.target_type}:${x.target_id??"room"}`} class="ops-log-entry ${x.severity}">
                <div class="ops-log-head">
                  <strong>${It(x.action_type)}</strong>
                  <span>${tn(x.target_type)}${x.target_id?` · ${x.target_id}`:""}</span>
                  <span>${fa(x.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${x.reason}</div>
                ${x.suggested_payload?o`
                  <div class="ops-confirmation-actions">
                    <button class="control-btn ghost" onClick=${()=>{yg(x)}} disabled=${W.value}>
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
            ${i.map(x=>o`
              <article key=${`${x.action_type}:${x.target_type}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${It(x.action_type)}</strong>
                  <span>${tn(x.target_type)}</span>
                  <span>${fa(x.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${x.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}
        ${s.length>0?o`
          <div class="ops-confirmation-list">
            ${s.map(x=>o`
              <article key=${x.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${It(x.action_type)}</strong>
                  <span>${tn(x.target_type)}${x.target_id?` · ${x.target_id}`:""}</span>
                  <span>${x.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${x.preview?o`<pre class="ops-code-block compact">${_a(x.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{ir(x.confirm_token)}} disabled=${W.value}>
                    실행
                  </button>
                  <button class="control-btn ghost" onClick=${()=>{ir(x.confirm_token,"deny")}} disabled=${W.value}>
                    거부
                  </button>
                  <span class="ops-token">${x.confirm_token}</span>
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
          <${O} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${$.length>0?o`
          <div class="ops-feed-list">
            ${$.map(x=>o`
              <article key=${x.seq??x.id??x.timestamp} class="ops-feed-item">
                <div class="ops-feed-meta">
                  <strong>${x.from}</strong>
                  <span>${x.timestamp}</span>
                </div>
                <div class="ops-feed-content">${x.content}</div>
              </article>
            `)}
          </div>
        `:o`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
      </section>
    </div>
  `}function uf(){var m;const e=_e.value,t=je.value,n=(e==null?void 0:e.sessions)??[],s=((e==null?void 0:e.available_actions)??[]).filter(u=>u.target_type==="team_session"),a=n.find(u=>u.session_id===an.value)??n[0]??null,i=t==null?void 0:t.active_summary,l=(t==null?void 0:t.active_guidance_layer)??"fallback",c=(t==null?void 0:t.resident_judge_runtime)??(e==null?void 0:e.resident_judge_runtime),p=(m=t==null?void 0:t.active_recommended_actions)!=null&&m.length?t.active_recommended_actions:(t==null?void 0:t.recommended_actions)??[];return o`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${O} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?o`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(u=>{var _;return o`
            <button
              key=${u.session_id}
              class="ops-entity-card ${(a==null?void 0:a.session_id)===u.session_id?"active":""}"
              onClick=${()=>{an.value=u.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${u.session_id}</strong>
                <span class="status-badge ${u.status??"idle"}">${Ft(u.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(u.progress_pct??0)}%</span>
                <span>${u.done_delta_total??0}건 완료</span>
                <span>${(_=u.team_health)!=null&&_.status?Ft(String(u.team_health.status)):"상태 확인 필요"}</span>
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
        ${a&&t?o`
          <article class="ops-guidance-card ${ga(l)}">
            <div class="ops-guidance-head">
              <strong>${fi(l)}</strong>
              <span>${$i(c)}</span>
            </div>
            <div class="ops-guidance-body">
              ${(i==null?void 0:i.summary)??"현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다."}
            </div>
            <div class="ops-guidance-meta">
              <span>authoritative ${t.authoritative_judgment_available?"yes":"no"}</span>
              <span>${hi(i)}</span>
              ${c!=null&&c.model_used?o`<span>${c.model_used}</span>`:null}
            </div>
          </article>
          ${p.length>0?o`
            <div class="ops-log-list">
              ${p.map(u=>o`
                <article key=${`${u.action_type}:${u.target_type}:${u.target_id??"session"}`} class="ops-log-entry ${u.severity}">
                  <div class="ops-log-head">
                    <strong>${It(u.action_type)}</strong>
                    <span>${tn(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
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
                  <span>${tn(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${u.summary}</div>
              </article>
            `):o`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${t.worker_cards.length>0?t.worker_cards.map(u=>o`
              <article key=${`${u.actor??u.spawn_role??"worker"}:${u.spawn_agent??u.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${u.actor??u.spawn_role??"worker"}</strong>
                  <span>${Ft(u.status)}</span>
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
          <${O} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>
        ${s.length>0?o`
          <div class="ops-log-list">
            ${s.map(u=>o`
              <article key=${u.action_type} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${It(u.action_type)}</strong>
                  <span>${fa(u.confirm_required)}</span>
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
              <span>상태: ${Ft(a.status)}</span>
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
              <pre class="ops-code-block compact">${_a(a.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:o`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

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
          <button class="control-btn" onClick=${()=>{Sg()}} disabled=${W.value||!a}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${gg(he.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${Fn.value}
          onInput=${u=>{Fn.value=u.target.value}}
          disabled=${W.value||!a}
        ></textarea>

        ${he.value==="task"?o`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${Kn.value}
            onInput=${u=>{Kn.value=u.target.value}}
            disabled=${W.value||!a}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${Bn.value}
            onInput=${u=>{Bn.value=u.target.value}}
            disabled=${W.value||!a}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${Un.value}
            onChange=${u=>{Un.value=u.target.value}}
            disabled=${W.value||!a}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
        `:he.value==="worker_spawn_batch"?o`
          <textarea
            class="control-textarea"
            rows=${6}
            placeholder='spawn_batch JSON, 예: [{"spawn_agent":"llama","spawn_prompt":"...", "spawn_role":"replacement"}]'
            value=${Hn.value}
            onInput=${u=>{Hn.value=u.target.value}}
            disabled=${W.value||!a}
          ></textarea>
        `:null}

        <div class="control-row ops-split-row">
          <input
            class="control-input"
            type="text"
            value=${ma.value}
            onInput=${u=>{ma.value=u.target.value}}
            disabled=${W.value||!a}
          />
          <button class="control-btn ghost" onClick=${()=>{Ag()}} disabled=${W.value||!a}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function pf(){var i;const e=_e.value,t=(e==null?void 0:e.keepers)??[],n=(e==null?void 0:e.persistent_agents)??[],s=(e==null?void 0:e.available_actions)??[],a=t.find(l=>l.name===va.value)??t[0]??null;return o`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${O} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${t.length===0?o`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:t.map(l=>o`
            <button
              key=${l.name}
              class="ops-entity-card ${(a==null?void 0:a.name)===l.name?"active":""}"
              onClick=${()=>{va.value=l.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${l.name}</strong>
                <span class="status-badge ${l.status??"idle"}">${Ft(l.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${l.model??"model 확인 필요"}</span>
                <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${sr(l.last_turn_ago_s)}</span>
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
                    <span class="status-badge ${l.status??"idle"}">${Ft(l.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>persistent</span>
                    <span>${l.model??"model 확인 필요"}</span>
                    <span>${sr(l.last_turn_ago_s)}</span>
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
        `:o`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

        <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
        <textarea
          id="ops-keeper-message"
          class="control-textarea"
          rows=${6}
          placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
          value=${en.value}
          onInput=${l=>{en.value=l.target.value}}
          disabled=${W.value||!a}
        ></textarea>
        <div class="control-row">
          <button class="control-btn" onClick=${()=>{Cg()}} disabled=${W.value||!a||en.value.trim()===""}>
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
          ${s.length?s.map(l=>o`
                <article key=${`${l.action_type}:${l.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${It(l.action_type)}</strong>
                    <span>${tn(l.target_type)}</span>
                    <span>${fa(l.confirm_required)}</span>
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
          ${Gs.value.length===0?o`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:Gs.value.map(l=>o`
            <article key=${l.id} class="ops-log-entry ${l.outcome}">
              <div class="ops-log-head">
                <strong>${It(l.action_type)}</strong>
                <span>${l.target_label}</span>
                <span>${l.at}</span>
              </div>
              <div class="ops-log-body">${l.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function mf(){var T,P,M;const e=_e.value,t=F.value.tab==="intervene"?ts(F.value):null,n=ei.value,s=(e==null?void 0:e.room)??{},a=(e==null?void 0:e.sessions)??[],i=(e==null?void 0:e.keepers)??[],l=(e==null?void 0:e.pending_confirms)??[],c=e==null?void 0:e.pending_confirm_summary,p=(c==null?void 0:c.visible_count)??l.length,m=(c==null?void 0:c.total_count)??l.length,u=(c==null?void 0:c.hidden_count)??0,_=((T=c==null?void 0:c.actor_filter)==null?void 0:T.trim())||null,f=a.find(R=>R.session_id===an.value)??a[0]??null,h=(n==null?void 0:n.attention_items)??[],b=h.filter(vg),$=h.filter(_g),S=a.filter(R=>mg(R)!=="ok"),A=i.filter(R=>Wa(R)!=="ok"),x=bg(t,a,i);ne(()=>{Tt()},[]),ne(()=>{if(F.value.tab!=="intervene"){hs.value=null;return}if(!t){hs.value=null;return}hs.value!==t.id&&(hs.value=t.id,hg(t))},[F.value.tab,F.value.params.source,F.value.params.action_type,F.value.params.target_type,F.value.params.target_id,F.value.params.focus_kind,t==null?void 0:t.id]),ne(()=>{const R=(f==null?void 0:f.session_id)??null;sn(R)},[f==null?void 0:f.session_id]);const z=[{key:"room",label:"Room 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:u>0?`${p}/${m}`:p,detail:p>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":u>0&&_?`현재 actor(${_}) 기준으로는 비어 있고, 다른 actor 대기 ${u}건이 있습니다`:"지금 막혀 있는 확인 대기는 없습니다",tone:m>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:b.length>0?b.length:a.length,detail:b.length>0?((P=b[0])==null?void 0:P.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:b.length>0?ar(b):a.length===0?"warn":S.some(R=>on(R.status)==="paused")?"bad":S.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:$.length>0?$.length:A.length,detail:$.length>0?((M=$[0])==null?void 0:M.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":A.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:$.length>0?ar($):A.some(R=>Wa(R)==="bad")?"bad":A.length>0?"warn":"ok"}];return o`
    <section class="ops-view">
      <${be} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">Intervene</div>
            <${O} panelId="intervene.action_studio" compact=${!0} />
          </div>
          <h2 class="ops-heading">room, session, keeper에 바로 손대는 개입 화면</h2>
          <p class="ops-subheading">
            읽는 화면이 아니라 행동하는 화면입니다. room, session, keeper를 나눠서 보고 바로 개입합니다.
          </p>
        </div>
        <div class="ops-toolbar">
          <label class="control-label" for="ops-actor">개입 ID</label>
          <input
            id="ops-actor"
            class="control-input ops-actor-input"
            type="text"
            value=${Na.value}
            onInput=${R=>ug(R.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{ye(),Tt(),sn((f==null?void 0:f.session_id)??null)}}
            disabled=${Mn.value||W.value}
          >
            ${Mn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${it.value?o`<section class="ops-banner error">${it.value}</section>`:null}
      ${nn.value?o`<section class="ops-banner error">${nn.value}</section>`:null}
      ${t?o`
        <section class="ops-banner ${x?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${t.source_label}</strong>
            <span>${La(t.action_type)}</span>
            <span>${di(t)}</span>
          </div>
          <div class="ops-handoff-body">${t.summary}</div>
          ${t.payload_preview?o`<div class="ops-handoff-preview">${t.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${x?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const R=[];if((p>0||u>0)&&R.push({label:u>0?`확인 대기 ${p}/${m}건 확인`:`확인 대기 ${p}건 처리`,desc:u>0&&_?`현재 actor(${_}) 기준으로 보이는 queue를 먼저 확인합니다`:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:p>0?"bad":"warn",onClick:()=>{const N=document.querySelector(".ops-pending-section");N==null||N.scrollIntoView({behavior:"smooth"})}}),s.paused&&R.push({label:"Room 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void pc()}),A.length>0){const N=A.filter(Z=>Wa(Z)==="bad");R.push({label:N.length>0?`Keeper ${N.length}개 오프라인`:`Keeper ${A.length}개 점검 필요`,desc:N.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:N.length>0?"bad":"warn",onClick:()=>{const Z=document.querySelector(".ops-keeper-section");Z==null||Z.scrollIntoView({behavior:"smooth"})}})}return R.length===0?null:o`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${R.slice(0,3).map(N=>o`
                <button class="ops-action-guide-item ${N.tone}" onClick=${N.onClick}>
                  <strong>${N.label}</strong>
                  <span>${N.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `})()}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${O} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 room인지, session인지, keeper인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${z.map(R=>o`
            <div key=${R.key} class="ops-priority-card ${R.tone}">
              <span class="ops-priority-label">${R.label}</span>
              <strong>${R.value}</strong>
              <div class="ops-priority-detail">${R.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${df} />
        <${uf} />
        <${pf} />
      </div>
    </section>
  `}function vf({text:e}){if(!e)return null;const t=_f(e);return o`<div class="markdown-content">${t}</div>`}function _f(e){const t=e.split(`
`),n=[];let s=0;for(;s<t.length;){const a=t[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),p=[];for(s++;s<t.length&&!t[s].startsWith(l);)p.push(t[s]),s++;s++,n.push(o`<pre><code class=${c?`language-${c}`:""}>${p.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<t.length&&!t[s].includes("</think>");)l.push(t[s]),s++;if(s<t.length){const m=t[s].replace("</think>","").trim();m&&l.push(m),s++}const p=l.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Ga(p)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<t.length&&t[s].startsWith("> ");)l.push(t[s].slice(2)),s++;n.push(o`<blockquote>${Ga(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<t.length;){const l=t[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;i.push(l),s++}i.length>0&&n.push(o`<p>${Ga(i.join(`
`))}</p>`)}return n}function Ga(e){const t=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(e))!==null;){if(a.index>s&&t.push(e.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);t.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);t.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);t.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&t.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<e.length&&t.push(e.slice(s)),t.length>0?t:[e]}const bc=[{id:"recent",label:"Latest"},{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],js=g(null),ws=g([]),rn=g(!1),Ct=g(null),Cn=g(""),In=g(!1),Kt=g(!0),bi=20,Et=g(bi);function gf(){var t,n;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const ff=g(gf());function $f(e){const t=e.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return t?t.length>180?`${t.slice(0,177)}...`:t:"No preview available"}function lr(e){return e.updated_at!==e.created_at}function hf(e){if(e.post_kind)return e.post_kind==="automation";const t=(e.hearth??"").toLowerCase();return e.visibility!=="internal"||!e.expires_at||!t?!1:!!(t.startsWith("mdal")||t.includes("harness"))}function yf(e){return e==="lodge-system"||e==="team-session"}function Wn(e){return e.post_kind?e.post_kind:yf(e.author)?"system":hf(e)?"automation":"human"}function kc(e){const t=[],n=[];let s=0;return e.forEach(a=>{const i=Wn(a);if(!(i==="system"&&bt.value)){if(i==="automation"&&Kt.value){s+=1;return}if(i==="human"){t.push(a);return}n.push(a)}}),{human:t,operations:n,hiddenAutomation:s}}function bf(e){if(!e.expires_at)return null;const t=Date.parse(e.expires_at);return Number.isFinite(t)?t<=Date.now()?o`<span class="board-meta-chip">expired</span>`:o`<span class="board-meta-chip">expires <${J} timestamp=${e.expires_at} /></span>`:null}async function ki(e){Ct.value=e,js.value=null,ws.value=[],rn.value=!0;try{const t=await Kd(e);if(Ct.value!==e)return;js.value={id:t.id,author:t.author,title:t.title,body:t.body,content:t.content,meta:t.meta,tags:t.tags,votes:t.votes,vote_balance:t.vote_balance,comment_count:t.comment_count,created_at:t.created_at,updated_at:t.updated_at,post_kind:t.post_kind,flair:t.flair,hearth:t.hearth,visibility:t.visibility,expires_at:t.expires_at,hearth_count:t.hearth_count},ws.value=t.comments??[]}catch{Ct.value===e&&(js.value=null,ws.value=[])}finally{Ct.value===e&&(rn.value=!1)}}async function cr(e){const t=Cn.value.trim();if(t){In.value=!0;try{await Bd(e,ff.value,t),Cn.value="",E("Comment posted","success"),await ki(e),et()}catch{E("Failed to post comment","error")}finally{In.value=!1}}}function kf(){const e=Ln.value,t=Kt.value?"Automation lane collapsed":"Automation lane visible";return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${bc.map(n=>o`
          <button
            class="board-sort-btn ${e===n.id?"active":""}"
            onClick=${()=>{Ln.value=n.id,Et.value=bi,et()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Kt.value?"is-active":""}"
          onClick=${()=>{Kt.value=!Kt.value}}
        >
          ${t}
        </button>
        <button
          class="control-btn ghost ${bt.value?"is-active":""}"
          onClick=${()=>{bt.value=!bt.value,et()}}
        >
          ${bt.value?"System posts hidden":"System posts visible"}
        </button>
        <button class="control-btn ghost" onClick=${et} disabled=${zn.value}>
          ${zn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Ja(){var s;const e=((s=bc.find(a=>a.id===Ln.value))==null?void 0:s.label)??Ln.value,t=kc(Ra.value),n=t.human.length+t.operations.length;return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${n}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Sort</span>
        <strong>${e}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise filter</span>
        <strong>${Kt.value?`automation ${t.hiddenAutomation} hidden`:"separate lane"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${bt.value?"System posts hidden":"System lane visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Co.value?o`<${J} timestamp=${Co.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function dr({post:e}){const t=async(n,s)=>{s.stopPropagation();try{await qr(e.id,n),et()}catch{E("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>Gc(e.id)}>
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
                ${lr(e)?o`<span class="board-meta-chip">Updated</span>`:null}
                ${Wn(e)!=="human"?o`<span class="board-meta-chip">${Wn(e)}</span>`:null}
                ${e.hearth?o`<span class="board-meta-chip">${e.hearth}</span>`:null}
                ${e.visibility?o`<span class="board-meta-chip">${e.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>By ${e.author}</span>
            <span><${J} timestamp=${e.created_at} /></span>
            ${lr(e)?o`<span>Updated <${J} timestamp=${e.updated_at} /></span>`:null}
            <span>${e.comment_count} comments</span>
            <span>${e.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${$f(e.body)}</div>
      </div>
    </div>
  `}function xf({comments:e}){return e.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${e.map(t=>o`
        <div key=${t.id} class="board-comment">
          <span class="comment-author">${t.author}</span>
          <span class="comment-time"><${J} timestamp=${t.created_at} /></span>
          <div class="comment-text">${t.content}</div>
        </div>
      `)}
    </div>
  `}function Sf({postId:e}){return o`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Cn.value}
        onInput=${t=>{Cn.value=t.target.value}}
        onKeyDown=${t=>{t.key==="Enter"&&cr(e)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${In.value}
      />
      <button
        onClick=${()=>cr(e)}
        disabled=${In.value||Cn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${In.value?"...":"Post"}
      </button>
    </div>
  `}function Af({post:e}){Ct.value!==e.id&&!rn.value&&ki(e.id);const t=async n=>{try{await qr(e.id,n),et()}catch{E("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>se("memory")}>← Back to Memory</button>
      <${I} title=${e.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${vf} text=${e.body} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${e.author}</span>
            <${J} timestamp=${e.created_at} />
            <span>${e.votes??0} votes</span>
          </div>
          ${e.hearth||e.visibility||e.expires_at?o`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${e.hearth?o`<span class="board-meta-chip">${e.hearth}</span>`:null}
                  ${e.visibility?o`<span class="board-meta-chip">${e.visibility}</span>`:null}
                  ${Wn(e)!=="human"?o`<span class="board-meta-chip">${Wn(e)}</span>`:null}
                  ${bf(e)}
                </div>
              `:null}
          ${e.meta?o`
                <details style="margin-top:12px;">
                  <summary>Operational meta</summary>
                  <div class="post-body" style="margin-top:8px;">
                    ${e.meta.source?o`<div><strong>source</strong>: ${e.meta.source}</div>`:null}
                    ${e.meta.state_block?o`<pre style="white-space:pre-wrap; margin-top:8px;">${e.meta.state_block}</pre>`:null}
                  </div>
                </details>
              `:null}
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>t("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>t("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${I} title="Comments" semanticId="memory.feed">
        ${rn.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${xf} comments=${ws.value} />`}
        <${Sf} postId=${e.id} />
      <//>
    </div>
  `}function Cf(){const e=kc(Ra.value),t=[...e.human,...e.operations],n=F.value.params.post??null,s=n?t.find(a=>a.id===n)??(Ct.value===n?js.value:null):null;return n&&!s&&Ct.value!==n&&!rn.value&&ki(n),n?s?o`
          <${be} surfaceId="memory" />
          <${Ja} />
          <${Af} post=${s} />
        `:o`
          <div>
            <${be} surfaceId="memory" />
            <${Ja} />
            <button class="back-btn" onClick=${()=>se("memory")}>← Back to Memory</button>
            ${rn.value?o`<div class="loading-indicator">Loading post...</div>`:o`<div class="empty-state">Post not found</div>`}
          </div>
        `:o`
    <div>
      <${be} surfaceId="memory" />
      <${Ja} />
      <${kf} />
      ${zn.value?o`<div class="loading-indicator">Loading memory feed...</div>`:t.length===0?o`<div class="empty-state">No posts in durable memory right now</div>`:o`
              <${I} title="Human Posts" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${e.human.slice(0,Et.value).map(a=>o`<${dr} key=${a.id} post=${a} />`)}
                </div>
                ${e.human.length>Et.value?o`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{Et.value=Et.value+bi}}
                    >
                      Show more (${e.human.length-Et.value} remaining)
                    </button>
                  </div>
                `:null}
              <//>
              ${e.operations.length>0?o`
                    <${I} title="Automation & System" class="section" semanticId="memory.feed">
                      <div class="board-post-list">
                        ${e.operations.map(a=>o`<${dr} key=${a.id} post=${a} />`)}
                      </div>
                    <//>
                  `:null}
            `}
    </div>
  `}function If({ratio:e,size:t=40,stroke:n=4}){if(e==null)return null;const s=(t-n)/2,a=t/2,i=2*Math.PI*s,l=i*((100-e*100)/100);let c="mitosis-safe";return e>=.8?c="mitosis-critical":e>=.5&&(c="mitosis-warn"),o`
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
  `}const ht=g(null),Oe=g(null),qe=g(null);function Ea(e){return e==="bad"||e==="critical"||e==="offline"?"bad":e==="warn"||e==="paused"||e==="blocked"||e==="interrupted"?"warn":"ok"}function Tf(e){return typeof e!="number"||Number.isNaN(e)?"—":`${Math.round(e*100)}%`}function Rf(e){return e?dt.value.find(t=>t.name===e||t.agent_name===e)??null:null}function Pf(e){switch(e){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function Lf(e){switch(e){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function ur(e){if(!e)return;const t=dv({targetType:e.target_type,targetId:e.target_id,focusKind:e.focus_kind,operationId:e.operation_id??null,commandSurface:e.command_surface??null,sourceLabel:"Execution 진단",summary:e.label});Kl(t),se(e.surface,e.surface==="intervene"?Bl(t):Hl(t))}function Mt({label:e,value:t,color:n,caption:s}){return o`
    <div class="stat-card">
      <div class="stat-label">${e}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${t}</div>
      ${s?o`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function xi({intervene:e,command:t}){return o`
    <div class="control-row">
      ${e?o`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),ur(e)}}
            >
              ${e.label}
            </button>
          `:null}
      ${t?o`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),ur(t)}}
            >
              ${t.label}
            </button>
          `:null}
    </div>
  `}function zf({item:e,selected:t}){return o`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{ht.value=t?null:e.id,Oe.value=null,qe.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.kind==="session"?e.target_id:e.linked_session_id??e.target_id}</div>
          <div class="mission-card-title">${e.summary}</div>
        </div>
        <span class="command-chip ${Ea(e.severity)}">${e.status??e.severity}</span>
      </div>
      <div class="mission-card-meta">
        <span>${e.kind}</span>
        ${e.linked_operation_id?o`<span>linked op · ${e.linked_operation_id}</span>`:null}
        ${e.last_seen_at?o`<span><${J} timestamp=${e.last_seen_at} /></span>`:null}
      </div>
      <${xi} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function Mf({brief:e,selected:t}){return o`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.session-card"
      onClick=${()=>{Oe.value=t?null:e.session_id,qe.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          <div class="mission-card-title">${e.goal}</div>
        </div>
        <span class="command-chip ${Ea(e.health??e.status)}">${e.status??"unknown"}</span>
      </div>
      <div class="mission-card-meta">
        <span>health · ${e.health??"ok"}</span>
        ${e.linked_operation_id?o`<span>op · ${e.linked_operation_id}</span>`:null}
        ${e.last_activity_at?o`<span><${J} timestamp=${e.last_activity_at} /></span>`:null}
      </div>
      ${e.runtime_blocker?o`<div class="mission-card-detail">${e.runtime_blocker}</div>`:e.last_activity_summary?o`<div class="mission-card-detail">${e.last_activity_summary}</div>`:null}
      ${e.worker_gap_summary?o`<div class="monitor-footnote">${e.worker_gap_summary}</div>`:null}
      <${xi} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function Nf({brief:e,selected:t}){return o`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.operation-card"
      onClick=${()=>{qe.value=t?null:e.operation_id,Oe.value=e.linked_session_id??null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.operation_id}${e.assigned_unit_label?` · ${e.assigned_unit_label}`:""}</div>
          <div class="mission-card-title">${e.objective}</div>
        </div>
        <span class="command-chip ${Ea(e.blocker_summary?"warn":e.status)}">${e.status??"unknown"}</span>
      </div>
      <div class="mission-card-meta">
        ${e.stage?o`<span>stage · ${e.stage}</span>`:null}
        ${e.linked_session_id?o`<span>session · ${e.linked_session_id}</span>`:null}
        ${e.updated_at?o`<span><${J} timestamp=${e.updated_at} /></span>`:null}
      </div>
      ${e.blocker_summary?o`<div class="mission-card-detail">${e.blocker_summary}</div>`:null}
      ${e.next_tool?o`<div class="monitor-footnote">next tool · ${e.next_tool}</div>`:null}
      <${xi} command=${e.command_handoff} />
    </button>
  `}function pr({row:e,testId:t}){return o`
    <button class="monitor-row ${e.tone} state-${e.state}" data-testid=${t} onClick=${()=>Ma(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.korean_name?o`<span class="monitor-sub">${e.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${e.note}</div>
        </div>
        <${pt} status=${e.status??"unknown"} />
        <span class="monitor-pill ${e.tone} state-${e.state}">${Pf(e.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_signal_at?o`<span>신호 <${J} timestamp=${e.last_signal_at} /></span>`:o`<span>최근 신호 없음</span>`}
        <span>${(e.active_task_count??0)>0?`활성 작업 ${e.active_task_count}개`:"활성 작업 없음"}</span>
        ${e.related_session_id?o`<span>session · ${e.related_session_id}</span>`:null}
        ${e.related_operation_id?o`<span>op · ${e.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.recent_output_preview&&e.recent_output_preview!==e.focus?o`<div class="monitor-footnote">최근 상세: ${e.recent_output_preview}</div>`:null}
    </button>
  `}function Ef({row:e}){const t=()=>{const n=Rf(e.name);n&&tc(n)};return o`
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
        <${If} ratio=${e.context_ratio??0} size=${34} stroke=${4} />
        <${pt} status=${e.status??"unknown"} />
        <span class="monitor-pill ${e.tone}">${Lf(e.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_signal_at?o`<span>최근 활동 <${J} timestamp=${e.last_signal_at} /></span>`:o`<span>최근 활동 없음</span>`}
        ${e.related_session_id?o`<span>session · ${e.related_session_id}</span>`:null}
        ${e.continuity?o`<span>${e.continuity}</span>`:null}
        ${e.lifecycle?o`<span>라이프사이클 ${e.lifecycle}</span>`:null}
        <span>컨텍스트 ${Tf(e.context_ratio)}</span>
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">연속성 이유: ${e.skill_reason}</div>`:null}
    </button>
  `}function jf(){const e=Hr.value,t=Wr.value,n=Gr.value,s=Jr.value,a=Vr.value,i=Qr.value,l=Yr.value;ht.value&&!t.some($=>$.id===ht.value)&&(ht.value=null),Oe.value&&!n.some($=>$.session_id===Oe.value)&&(Oe.value=null),qe.value&&!s.some($=>$.operation_id===qe.value)&&(qe.value=null);const c=ht.value?t.find($=>$.id===ht.value)??null:null,p=Oe.value?Oe.value:c?c.kind==="session"?c.target_id:c.linked_session_id??null:null,m=qe.value?qe.value:c?c.kind==="operation"?c.target_id:c.linked_operation_id??null:null,u=p?n.filter($=>$.session_id===p):m?n.filter($=>$.linked_operation_id===m):n,_=m?s.filter($=>$.operation_id===m):p?s.filter($=>{var S;return $.linked_session_id===p||$.operation_id===((S=u[0])==null?void 0:S.linked_operation_id)}):s,f=p||m?a.filter($=>(p?$.related_session_id===p:!1)||(m?$.related_operation_id===m:!1)):a,h=p?i.filter($=>$.related_session_id===p||$.tone!=="ok"):i,b=p||m?l.filter($=>(p?$.related_session_id===p:!1)||(m?$.related_operation_id===m:!1)||$.tone!=="ok"):l;return o`
    <div class="agents-monitor">
      <${be} surfaceId="execution" />
      <div class="stats-grid">
        <${Mt} label="활성 세션" value=${(e==null?void 0:e.active_sessions)??n.length} color="#4ade80" caption="실행 관점의 session" />
        <${Mt} label="막힌 세션" value=${(e==null?void 0:e.blocked_sessions)??n.filter($=>Ea($.health??$.status)!=="ok").length} color="#fbbf24" caption="개입 후보 session" />
        <${Mt} label="활성 작전" value=${(e==null?void 0:e.active_operations)??s.length} color="#22d3ee" caption="command-plane operation" />
        <${Mt} label="막힌 작전" value=${(e==null?void 0:e.blocked_operations)??s.filter($=>$.blocker_summary).length} color="#fb7185" caption="원인 분석이 필요한 작전" />
        <${Mt} label="worker 경고" value=${(e==null?void 0:e.worker_alerts)??a.filter($=>$.tone!=="ok").length} color="#fb7185" caption="supporting worker pressure" />
        <${Mt} label="연속성 경고" value=${(e==null?void 0:e.continuity_alerts)??i.filter($=>$.tone!=="ok").length} color="#fb7185" caption="keeper continuity pressure" />
      </div>

      <${I}
        title="Execution Queue"
        class="section"
        semanticId="execution.queue"
        testId="execution.queue"
      >
        <div class="monitor-section-head">
          <h2 class="monitor-headline">지금 막힌 실행과 다음 handoff</h2>
          <p class="monitor-subheadline">session과 operation을 한 queue로 보고, 어디를 먼저 Intervene/Command로 넘길지 판단합니다.</p>
        </div>
        <div class="monitor-alert-list">
          ${t.length===0?o`<div class="empty-state">지금은 막힌 실행이 없습니다</div>`:t.map($=>o`<${zf} key=${$.id} item=${$} selected=${ht.value===$.id} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${I}
          title="Affected Sessions"
          class="section"
          semanticId="execution.sessions"
          testId="execution.session-briefs"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">영향받는 session</h2>
            <p class="monitor-subheadline">queue에서 고른 실행이 어떤 session 목표와 runtime blocker를 갖는지 요약합니다.</p>
          </div>
          <div class="monitor-list">
            ${u.length===0?o`<div class="empty-state">선택된 실행과 연결된 session이 없습니다</div>`:u.map($=>o`<${Mf} key=${$.session_id} brief=${$} selected=${Oe.value===$.session_id} />`)}
          </div>
        <//>

        <${I}
          title="Affected Operations"
          class="section"
          semanticId="execution.operations"
          testId="execution.operation-briefs"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">영향받는 작전</h2>
            <p class="monitor-subheadline">command-plane operation의 blocker와 next tool을 얇게 보여주고, deep truth는 Command로 넘깁니다.</p>
          </div>
          <div class="monitor-list">
            ${_.length===0?o`<div class="empty-state">선택된 실행과 연결된 operation이 없습니다</div>`:_.map($=>o`<${Nf} key=${$.operation_id} brief=${$} selected=${qe.value===$.operation_id} />`)}
          </div>
        <//>

        <${I}
          title="Worker Support"
          class="section"
          semanticId="execution.worker_support"
          testId="execution.worker-support"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">지원 worker</h2>
            <p class="monitor-subheadline">선택된 session/operation에 연결된 worker만 보이고, 전체 worker wall은 더 이상 첫 화면을 차지하지 않습니다.</p>
          </div>
          <div class="monitor-list">
            ${f.length===0?o`<div class="empty-state">연결된 worker가 없습니다</div>`:f.map($=>o`<${pr} key=${$.name} row=${$} testId="execution.worker-card" />`)}
          </div>
        <//>

        <${I}
          title="Continuity"
          class="section"
          semanticId="execution.continuity"
          testId="execution.continuity"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">연속성 보조 lane</h2>
            <p class="monitor-subheadline">keeper continuity는 supporting lane으로만 남기고, unhealthy keeper 위주로 노출합니다.</p>
          </div>
          <div class="monitor-list">
            ${h.length===0?o`<div class="empty-state">지금은 연속성 경고가 없습니다</div>`:h.map($=>o`<${Ef} key=${$.name} row=${$} />`)}
          </div>
        <//>

        <${I}
          title="Offline Workers"
          class="section"
          semanticId="execution.offline"
          testId="execution.offline-workers"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">오프라인 worker</h2>
            <p class="monitor-subheadline">빠진 worker는 하단 lane으로 분리해 활성 실행 판단을 방해하지 않게 유지합니다.</p>
          </div>
          <div class="monitor-list">
            ${b.length===0?o`<div class="empty-state">지금은 오프라인 worker가 없습니다</div>`:b.map($=>o`<${pr} key=${$.name} row=${$} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const $a=g("all"),ha=g("all"),Do=g(new Set);function wf(e){const t=new Set(Do.value);t.has(e)?t.delete(e):t.add(e),Do.value=t}const xc=Ce(()=>{let e=Ht.value;return $a.value!=="all"&&(e=e.filter(t=>t.horizon===$a.value)),ha.value!=="all"&&(e=e.filter(t=>t.status===ha.value)),e}),Df=Ce(()=>{const e={short:[],mid:[],long:[]};for(const t of xc.value){const n=e[t.horizon];n&&n.push(t)}return e}),Of=Ce(()=>{const e=Array.from(Zr.value.values());return e.sort((t,n)=>t.status==="running"&&n.status!=="running"?-1:n.status==="running"&&t.status!=="running"?1:t.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&t.status!=="interrupted"?1:n.elapsed_seconds-t.elapsed_seconds),e});function qf(e){return"★".repeat(Math.min(e,5))+"☆".repeat(Math.max(0,5-e))}function Si(e){switch(e){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return e}}function Ds(e){switch(e){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Ff(e){return e<60?`${Math.round(e)}s`:e<3600?`${Math.floor(e/60)}m ${Math.round(e%60)}s`:`${Math.floor(e/3600)}h ${Math.floor(e%3600/60)}m`}function mr(e){return e.toFixed(4)}function vr(e){const t=e.current_metric-e.baseline_metric;return`${t>=0?"+":""}${t.toFixed(4)}`}function Kf(e){switch(e){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function _r(e,t){return(e.priority??4)-(t.priority??4)}function Bf(e,t){const n=e.updated_at??e.created_at??"";return(t.updated_at??t.created_at??"").localeCompare(n)}function Uf(e,t){return e.length<=t?e:e.slice(0,t)+"..."}function Hf({goal:e}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Ds(e.horizon)}">
            ${Si(e.horizon)}
          </span>
          <span class="goal-title">${e.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${e.priority}">${qf(e.priority)}</span>
          ${e.metric?o`<span class="goal-metric">${e.metric}${e.target_value?` → ${e.target_value}`:""}</span>`:null}
          ${e.due_date?o`<span class="goal-due">Due: <${J} timestamp=${e.due_date} /></span>`:null}
        </div>
        ${e.last_review_note?o`
          <div class="goal-review-note">${e.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${pt} status=${e.status} />
        <div class="goal-updated">
          <${J} timestamp=${e.updated_at} />
        </div>
      </div>
    </div>
  `}function Va({horizon:e,items:t}){if(t.length===0)return null;const n=[...t].sort((s,a)=>a.priority-s.priority);return o`
    <${I} title="${Si(e)} Goals (${t.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>o`<${Hf} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function Wf(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(e=>o`
          <button
            class="goal-filter-btn ${$a.value===e?"active":""}"
            onClick=${()=>{$a.value=e}}
          >
            ${e==="all"?"All":Si(e)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(e=>o`
          <button
            class="goal-filter-btn ${ha.value===e?"active":""}"
            onClick=${()=>{ha.value=e}}
          >
            ${e==="all"?"All":e.charAt(0).toUpperCase()+e.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function Gf(){const e=Ht.value,t=e.filter(a=>a.status==="active").length,n=e.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of e)a.horizon in s&&s[a.horizon]++;return o`
    <div class="goal-summary">
      <div class="goal-summary-item">
        <div class="goal-summary-value">${e.length}</div>
        <div class="goal-summary-label">Total</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#4ade80">${t}</div>
        <div class="goal-summary-label">Active</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#888">${n}</div>
        <div class="goal-summary-label">Completed</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Ds("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Ds("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Ds("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function Jf({loop:e}){const t=e.history[0],n=e.latest_tool_names&&e.latest_tool_names.length>0?`${e.latest_tool_call_count??e.latest_tool_names.length} tool${(e.latest_tool_call_count??e.latest_tool_names.length)===1?"":"s"}: ${e.latest_tool_names.join(", ")}`:"No evidence yet";return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${e.profile}</div>
            <div class="planning-loop-sub">${e.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${pt} status=${e.status} />
            <span class="pill">${e.current_iteration}${e.max_iterations>0?`/${e.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${mr(e.baseline_metric)}</span>
          <span>Current ${mr(e.current_metric)}</span>
          <span class=${vr(e).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${vr(e)}
          </span>
          <span>Elapsed ${Ff(e.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${e.target||"No explicit target provided"}</div>
        ${e.stop_reason||e.error_message?o`
              <div class="planning-loop-footnote">
                ${e.error_message??e.stop_reason}
              </div>
            `:null}
        <div class="planning-loop-footnote">
          ${e.strict_mode?"Strict hard evidence":"Legacy"} · ${e.worker_engine??"unknown engine"} · ${n}
        </div>
        ${t?o`
              <div class="planning-loop-footnote">
                Latest iteration #${t.iteration}: ${t.changes||t.next_suggestion||"No narrative"}
              </div>
            `:o`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function Qa({task:e}){const t=e.priority??4,n=t<=1?"p1":t===2?"p2":t===3?"p3":"p4",s=Do.value.has(e.id),a=!!e.description;return o`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${Kf(t)}</span>
        <div class="kanban-card-title">${e.title}</div>
      </div>
      ${a?o`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>wf(e.id)}
        >
          ${s?e.description:Uf(e.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${e.created_at?o`<${J} timestamp=${e.created_at} />`:o`<span>-</span>`}
        ${e.assignee?o`<span class="kanban-assignee">${e.assignee}</span>`:null}
      </div>
    </div>
  `}function Vf(){const{todo:e,inProgress:t,done:n}=tl.value,s=[...e].sort(_r),a=[...t].sort(_r),i=[...n].sort(Bf);return o`
    <${I} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${s.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:s.map(l=>o`<${Qa} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${a.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:a.map(l=>o`<${Qa} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${i.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:i.slice(0,20).map(l=>o`<${Qa} key=${l.id} task=${l} />`)}
          ${i.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${i.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function Qf(){const{todo:e,inProgress:t,done:n}=tl.value,s=e.length+t.length+n.length,a=[...e,...t].filter(u=>(u.priority??4)<=2).length,i=Df.value,l=Of.value,c=Ht.value.length>0,p=l.length>0,m=Qo.value;return o`
    <div>
      <${be} surfaceId="planning" />

      <!-- Step 1: Task-based stats grid -->
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Total tasks</div>
          <div class="stat-value">${s}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">TODO</div>
          <div class="stat-value" style="color:#e0e0e0">${e.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">In Progress</div>
          <div class="stat-value" style="color:#fbbf24">${t.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Done</div>
          <div class="stat-value" style="color:#4ade80">${n.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">High Priority</div>
          <div class="stat-value" style="color:${a>0?"#f87171":"#888"}">${a}</div>
        </div>
      </div>

      <!-- Compact refresh toolbar -->
      <div class="planning-toolbar">
        <button
          class="control-btn secondary"
          onClick=${()=>{Zo(),ll()}}
          disabled=${yn.value||bn.value}
        >
          ${yn.value||bn.value?"Refreshing...":"Refresh planning data"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${Vf} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          Goal Pipeline
          <span class="monitor-pill">${Ht.value.length}</span>
        </summary>
        <div>
          ${c?o`
            <${Gf} />
            <${Wf} />
            ${yn.value&&Ht.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:xc.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
                    <${Va} horizon="short" items=${i.short??[]} />
                    <${Va} horizon="mid" items=${i.mid??[]} />
                    <${Va} horizon="long" items=${i.long??[]} />
                  `}
          `:o`
            <div class="empty-state">
              No goals defined. Use <code>masc_goal_upsert</code> to create goals.
            </div>
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible" open=${p}>
        <summary>
          MDAL Loops
          <span class="monitor-pill">${l.length}</span>
        </summary>
        <div>
          ${bn.value&&l.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:l.length===0&&(m==="error"||Wt.value)?o`<div class="empty-state">MDAL snapshot could not be loaded${Wt.value?`: ${Wt.value}`:""}. Check backend health.</div>`:l.length===0?o`<div class="empty-state">No active loops. Use <code>masc_mdal_start</code> to start a loop.</div>`:o`
                  <div class="planning-loop-list">
                    ${l.map(u=>o`<${Jf} key=${u.loop_id} loop=${u} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const ya=g(!1),Tn=g(!1),Bt=g(!1),lt=g(""),Rn=g(""),Oo=g("open"),Ne=g(null),Gn=g(null),ba=g(null),ka=g(null),qo=g(!1);function Jn(e){return`${e.kind}:${e.id}`}function Ai(){var n;const e=Gn.value,t=((n=Ne.value)==null?void 0:n.items)??[];return e?t.find(s=>Jn(s)===e)??null:null}function Yf(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");return(t==null?void 0:t.trim())||"dashboard"}function Xf(e){const t=e.trim().toLowerCase();return t==="open"||t==="pending"}function Sc(e){return!!(e.judgment_summary&&e.judgment_summary.trim())}function Ac(e){switch(Oo.value){case"needs_quorum":return e.filter(t=>t.kind==="consensus"&&(t.votes??0)<(t.quorum??0));case"ready":return e.filter(t=>{var n;return(n=t.guardrail_state)==null?void 0:n.ready_to_execute});case"needs_approval":return e.filter(t=>{var n,s;return((n=t.guardrail_state)==null?void 0:n.requires_human_gate)||!!((s=t.guardrail_state)!=null&&s.pending_confirm)});case"judge_offline":return e.filter(t=>!Sc(t));case"open":default:return e.filter(t=>Xf(t.status))}}function Zf(e){if(e==null)return"none";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function ja(e){const t=(e||"").toLowerCase();return t.includes("reject")||t.includes("deny")||t.includes("closed")||t.includes("cancel")?"negative":t.includes("approve")||t.includes("support")||t.includes("open")||t.includes("ready")?"positive":"neutral"}function e$(e){return typeof e!="number"||Number.isNaN(e)?"n/a":`${Math.round(e*100)}%`}function fn(e){return"resolved_tool"in e||"payload_preview"in e||"reason"in e}async function Cc(e){if(ba.value=null,ka.value=null,!!e){qo.value=!0,lt.value="";try{e.kind==="debate"?ba.value=await gu(e.id):ka.value=await fu(e.id)}catch(t){lt.value=t instanceof Error?t.message:"Failed to load governance detail"}finally{qo.value=!1}}}async function t$(e){Gn.value=Jn(e),await Cc(e)}async function ln(){var e;ya.value=!0,lt.value="";try{const t=await fd();Ne.value=t;const n=Ac(t.items??[]),s=Gn.value,a=n.find(i=>Jn(i)===s)??n[0]??((e=t.items)==null?void 0:e[0])??null;Gn.value=a?Jn(a):null,await Cc(a)}catch(t){lt.value=t instanceof Error?t.message:"Failed to load governance state"}finally{ya.value=!1}}gp(ln);async function gr(){const e=Rn.value.trim();if(e){Tn.value=!0;try{const t=await _u(e);Rn.value="",E(t!=null&&t.id?`Debate started: ${t.id}`:"Debate started","success"),await ln()}catch(t){const n=t instanceof Error?t.message:"Failed to start debate";lt.value=n,E(n,"error")}finally{Tn.value=!1}}}async function fr(e){var i,l;const t=Ai(),n=(i=t==null?void 0:t.guardrail_state)==null?void 0:i.pending_confirm,s=n==null?void 0:n.confirm_token;if(!s)return;const a=((l=n==null?void 0:n.actor)==null?void 0:l.trim())||Yf();Bt.value=!0;try{await Nr(a,s,e),E(e==="confirm"?"Action approved":"Action denied","success"),await ln()}catch(c){const p=c instanceof Error?c.message:"Failed to update pending action";lt.value=p,E(p,"error")}finally{Bt.value=!1}}function n$(){var n,s,a,i,l,c;const e=(n=Ne.value)==null?void 0:n.summary,t=(s=Ne.value)==null?void 0:s.judge;return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${(e==null?void 0:e.debates_open)??((i=(a=Ne.value)==null?void 0:a.debates)==null?void 0:i.length)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Consensus sessions</span>
        <strong>${(e==null?void 0:e.sessions_active)??((c=(l=Ne.value)==null?void 0:l.sessions)==null?void 0:c.length)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Needs quorum</span>
        <strong>${(e==null?void 0:e.sessions_without_quorum)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Ready to execute</span>
        <strong>${(e==null?void 0:e.ready_to_execute)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Judge</span>
        <strong>${(t==null?void 0:t.judge_online)??(e==null?void 0:e.judge_online)?"Online":"Offline"}</strong>
      </div>
    </div>
  `}function s$(){return o`
    <${I} title="Governance Console" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Rn.value}
            onInput=${e=>{Rn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&gr()}}
            disabled=${Tn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${gr}
            disabled=${Tn.value||Rn.value.trim()===""}
          >
            ${Tn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${ln} disabled=${ya.value}>
            ${ya.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        <div class="governance-filter-row">
          ${[["open","Open"],["needs_quorum","Needs Quorum"],["ready","Ready"],["needs_approval","Needs Approval"],["judge_offline","Judge Offline"]].map(([e,t])=>o`
            <button
              class="control-btn ${Oo.value===e?"is-active":"ghost"}"
              onClick=${async()=>{Oo.value=e,await ln()}}
            >
              ${t}
            </button>
          `)}
        </div>
        ${lt.value?o`<div class="council-error">${lt.value}</div>`:null}
      </div>
    <//>
  `}function a$(){var t;const e=Ac(((t=Ne.value)==null?void 0:t.items)??[]);return o`
    <${I} title="Decision Inbox" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${e.length===0?o`
              <div class="empty-state">
                Governance is quiet. No debates or consensus sessions match the current filter.
              </div>
            `:e.map(n=>{var a,i;const s=Gn.value===Jn(n);return o`
                <button
                  class="council-row governance-decision-row ${s?"selected":""}"
                  onClick=${()=>t$(n)}
                >
                  <div class="council-row-main">
                    <div class="governance-row-head">
                      <span class="governance-kind">${n.kind}</span>
                      <span class="council-topic">${n.topic}</span>
                    </div>
                    <div class="council-sub">
                      <span>${n.truth_summary||"No fact summary"}</span>
                      ${n.last_activity_at?o`<span><${J} timestamp=${n.last_activity_at} /></span>`:null}
                    </div>
                    <div class="governance-chip-row">
                      ${(a=n.guardrail_state)!=null&&a.requires_human_gate?o`<span class="governance-chip warn">needs approval</span>`:null}
                      ${(i=n.guardrail_state)!=null&&i.ready_to_execute?o`<span class="governance-chip ok">ready</span>`:null}
                      ${n.kind==="consensus"&&(n.votes??0)<(n.quorum??0)?o`<span class="governance-chip warn">quorum debt</span>`:null}
                      ${Sc(n)?null:o`<span class="governance-chip dim">judge offline</span>`}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${ja(n.status)}">${n.status}</span>
                    ${n.kind==="consensus"?o`<span class="governance-vote-meter">${n.votes??0}/${n.quorum??0}</span>`:o`<span class="governance-vote-meter">${n.evidence_refs.length} refs</span>`}
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function o$({argument:e}){return o`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${ja(e.position)}">${e.position}</span>
        <strong>${e.agent}</strong>
        ${e.created_at?o`<span><${J} timestamp=${e.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.content}</div>
      <div class="governance-chip-row">
        ${e.evidence.map(t=>o`<span class="governance-chip">${t}</span>`)}
        ${e.reply_to!=null?o`<span class="governance-chip">reply #${e.reply_to}</span>`:null}
        ${e.mentions.map(t=>o`<span class="governance-chip">@${t}</span>`)}
        ${e.archetype?o`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function i$({vote:e}){return o`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${ja(e.decision)}">${e.decision}</span>
        <strong>${e.agent}</strong>
        ${e.timestamp?o`<span><${J} timestamp=${e.timestamp} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.reason||"No reason recorded."}</div>
      <div class="governance-chip-row">
        ${e.weight!=null?o`<span class="governance-chip">weight ${e.weight}</span>`:null}
        ${e.archetype?o`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function r$(){const e=Ai(),t=ba.value,n=ka.value;return o`
    <${I}
      title=${e?`${e.kind==="debate"?"Debate":"Consensus"} Detail`:"Decision Detail"}
      class="section"
      semanticId="governance.detail"
    >
      ${qo.value?o`<div class="loading-indicator">Loading governance detail...</div>`:e?e.kind==="debate"&&t?o`
                <div class="governance-detail-head">
                  <div>
                    <h3>${t.debate.topic}</h3>
                    <div class="council-sub">
                      <span>${t.debate.id}</span>
                      <span>${t.debate.status}</span>
                      ${t.debate.created_at?o`<span><${J} timestamp=${t.debate.created_at} /></span>`:null}
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
                  ${t.arguments.length===0?o`<div class="empty-state">No arguments recorded yet.</div>`:t.arguments.map(s=>o`<${o$} key=${s.index} argument=${s} />`)}
                </div>
              `:e.kind==="consensus"&&n?o`
                  <div class="governance-detail-head">
                    <div>
                      <h3>${n.session.topic}</h3>
                      <div class="council-sub">
                        <span>${n.session.id}</span>
                        <span>${n.session.state}</span>
                        <span>initiator ${n.session.initiator}</span>
                        ${n.session.created_at?o`<span><${J} timestamp=${n.session.created_at} /></span>`:null}
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
                    ${n.votes.length===0?o`<div class="empty-state">No votes recorded yet.</div>`:n.votes.map(s=>o`<${i$} key=${s.agent+s.timestamp} vote=${s} />`)}
                  </div>
                `:o`<div class="empty-state">Detail is unavailable for this decision.</div>`:o`<div class="empty-state">Select a decision item to inspect truth and judgment.</div>`}
    <//>
  `}function $r({title:e,route:t}){if(!t)return null;const n=fn(t)?t.resolved_tool:t.delegated_tool,s=fn(t)?t.target_type:null,a=fn(t)?t.target_id:null,i=fn(t)?t.reason:null,l=fn(t)?t.payload_preview:null;return o`
    <div class="governance-side-block">
      <h4>${e}</h4>
      <div class="council-sub">
        ${n?o`<span>tool ${n}</span>`:null}
        ${"action_type"in t&&t.action_type?o`<span>action ${t.action_type}</span>`:null}
        ${"confirmation_state"in t&&t.confirmation_state?o`<span>${t.confirmation_state}</span>`:null}
        ${"created_at"in t&&t.created_at?o`<span><${J} timestamp=${t.created_at} /></span>`:null}
      </div>
      ${s?o`<div class="governance-side-line">target ${s}${a?`:${a}`:""}</div>`:null}
      ${i?o`<div class="governance-side-line">${i}</div>`:null}
      ${l?o`<pre class="council-detail governance-preview">${Zf(l)}</pre>`:null}
    </div>
  `}function l$(){var c,p,m;const e=Ai(),t=ba.value,n=ka.value,s=(t==null?void 0:t.context)??(n==null?void 0:n.context)??(e==null?void 0:e.context),a=(t==null?void 0:t.judgment)??(n==null?void 0:n.judgment),i=e==null?void 0:e.guardrail_state,l=(c=Ne.value)==null?void 0:c.judge;return o`
    <div class="governance-side-column">
      <${I} title="Why / Guardrail" class="section" semanticId="governance.guardrail">
        ${e?o`
              <div class="governance-side-block">
                <h4>Judge</h4>
                <div class="council-sub">
                  <span>${l!=null&&l.judge_online?"online":"offline"}</span>
                  ${l!=null&&l.model_used?o`<span>${l.model_used}</span>`:null}
                  ${l!=null&&l.generated_at?o`<span><${J} timestamp=${l.generated_at} /></span>`:null}
                </div>
                ${e.judgment_summary?o`<div class="governance-summary-callout">${e.judgment_summary}</div>`:o`<div class="governance-side-line">No current LLM judgment. Showing truth layer only.</div>`}
                <div class="council-sub">
                  <span>confidence ${e$(e.confidence)}</span>
                  ${a!=null&&a.keeper_name?o`<span>${a.keeper_name}</span>`:null}
                </div>
              </div>

              <${$r} title="Recommended Route" route=${e.recommended_action} />
              <${$r} title="Executed Route" route=${e.executed_route} />

              <div class="governance-side-block">
                <h4>Guardrail State</h4>
                <div class="council-sub">
                  <span>${i!=null&&i.requires_human_gate?"human gate required":"no human gate"}</span>
                  ${i!=null&&i.ready_to_execute?o`<span>ready to execute</span>`:null}
                </div>
                ${i!=null&&i.pending_confirm?o`
                      <div class="governance-side-line">
                        pending ${i.pending_confirm.action_type||"action"}
                        ${i.pending_confirm.target_type?` on ${i.pending_confirm.target_type}`:""}
                      </div>
                      <div class="governance-action-row">
                        <button
                          class="control-btn secondary"
                          onClick=${()=>fr("confirm")}
                          disabled=${Bt.value}
                        >
                          ${Bt.value?"Working...":"Approve"}
                        </button>
                        <button
                          class="control-btn ghost"
                          onClick=${()=>fr("deny")}
                          disabled=${Bt.value}
                        >
                          ${Bt.value?"Working...":"Deny"}
                        </button>
                      </div>
                    `:o`<div class="governance-side-line">No pending human gate for this decision.</div>`}
              </div>
            `:o`<div class="empty-state">Select a decision to inspect judgment and route.</div>`}
      <//>

      <${I} title="Context" class="section" semanticId="governance.context">
        ${e?o`
              <div class="governance-side-block">
                <div class="governance-chip-row">
                  ${s!=null&&s.board_post_id?o`<span class="governance-chip">board ${s.board_post_id}</span>`:null}
                  ${s!=null&&s.task_id?o`<span class="governance-chip">task ${s.task_id}</span>`:null}
                  ${s!=null&&s.operation_id?o`<span class="governance-chip">operation ${s.operation_id}</span>`:null}
                  ${s!=null&&s.team_session_id?o`<span class="governance-chip">session ${s.team_session_id}</span>`:null}
                </div>
                ${e.related_agents.length>0?o`
                      <div class="governance-side-line">related agents</div>
                      <div class="governance-chip-row">
                        ${e.related_agents.map(u=>o`<span class="governance-chip dim">${u}</span>`)}
                      </div>
                    `:o`<div class="governance-side-line">No explicit linked context recorded.</div>`}
                ${e.evidence_refs.length>0?o`
                      <div class="governance-side-line">evidence refs</div>
                      <div class="governance-chip-row">
                        ${e.evidence_refs.map(u=>o`<span class="governance-chip">${u}</span>`)}
                      </div>
                    `:null}
              </div>
          `:o`<div class="empty-state">No context selected.</div>`}
      <//>

      <${I} title="Recent Activity" class="section" semanticId="governance.activity">
        <div class="governance-activity-list">
          ${(((p=Ne.value)==null?void 0:p.activity)??[]).slice(0,8).map(u=>o`
            <div class="governance-activity-row">
              <div class="governance-ledger-head">
                <span class="governance-badge ${ja(u.kind)}">${u.kind}</span>
                ${u.actor?o`<strong>${u.actor}</strong>`:null}
                ${u.created_at?o`<span><${J} timestamp=${u.created_at} /></span>`:null}
              </div>
              <div class="governance-ledger-body">${u.summary||u.topic||"Activity recorded."}</div>
            </div>
          `)}
          ${(((m=Ne.value)==null?void 0:m.activity)??[]).length===0?o`<div class="empty-state">No governance activity recorded.</div>`:null}
        </div>
      <//>
    </div>
  `}function c$(){return ne(()=>{ln()},[]),o`
    <div>
      <${be} surfaceId="governance" />
      <${n$} />
      <${s$} />
      <div class="governance-layout">
        <${a$} />
        <${r$} />
        <${l$} />
      </div>
    </div>
  `}const jt=g(""),Ya=g("ability_check"),Xa=g("10"),Za=g("12"),ys=g(""),bs=g("idle"),Ve=g(""),ks=g("keeper-late"),eo=g("player"),to=g(""),xe=g("idle"),no=g(null),xs=g(""),so=g(""),ao=g("player"),oo=g(""),io=g(""),ro=g(""),Pn=g("20"),lo=g("20"),co=g(""),Ss=g("idle"),Fo=g(null),Ic=g("overview"),uo=g("all"),po=g("all"),mo=g("all"),d$=12e4,wa=g(null),hr=g(Date.now());function u$(e,t){const n=t>0?e/t*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function p$(e,t){return t>0?Math.round(e/t*100):0}const m$={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},v$={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function As(e){const t=e.trim();return t?t.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):e}function _$(e){const t=e.trim().toLowerCase();return m$[t]??"행동 선택 가중치에 영향을 주는 성향입니다."}function g$(e){const t=e.trim().toLowerCase();return v$[t]??"상황에 따라 선택되는 전술 액션입니다."}function $e(e,t,n=""){const s=e[t];return typeof s=="string"?s:n}function Le(e,t,n=0){const s=e[t];return typeof s=="number"&&Number.isFinite(s)?s:n}function Vn(e,t,n=!1){const s=e[t];return typeof s=="boolean"?s:n}const f$=new Set(["str","dex","con","int","wis","cha"]);function $$(e){const t=e.trim();if(!t)return{};let n;try{n=JSON.parse(t)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!v(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const l=a.trim();if(l){if(typeof i=="number"&&Number.isFinite(i)){s[l]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const c=Number.parseFloat(i.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function h$(e){const t=Number.parseInt(e.trim(),10);if(!Number.isFinite(t))return;const n=Math.max(1,t),s=Number.parseInt(Pn.value.trim(),10);Number.isFinite(s)&&s>n&&(Pn.value=String(n))}function Ko(e){const n=(e.actor_name??e.actor??e.actor_id??"system").trim();return n===""?"system":n}function y$(e){var n;return(((n=e.timestamp)==null?void 0:n.trim())??"")||"-"}function b$(e){Ic.value=e}function Tc(e){const t=wa.value;return t==null||t<=e}function k$(e){const t=wa.value;return t==null||t<=e?0:Math.max(0,Math.ceil((t-e)/1e3))}function xa(){wa.value=null}function Rc(e){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(e)}function x$(e,t){Rc(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${e||"-"}`,`PHASE: ${t||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(wa.value=Date.now()+d$,E("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Os(e){return Tc(e)?(E("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Bo(e,t,n){return Rc([`[위험 액션 확인] ${e}`,`ROOM: ${t||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function S$({hp:e,max:t}){const n=p$(e,t),s=u$(e,t);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function A$({stats:e}){const t=[{label:"STR",value:e.strength},{label:"DEX",value:e.dexterity},{label:"CON",value:e.constitution},{label:"INT",value:e.intelligence},{label:"WIS",value:e.wisdom},{label:"CHA",value:e.charisma}];return o`
    <div class="trpg-actor-stats">
      ${t.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function C$({keeper:e,role:t}){if(!e)return null;const n=t==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${e}
    </span>
  `}function Pc({actor:e}){var p,m,u,_;const t=(p=e.archetype)==null?void 0:p.trim(),n=(m=e.persona)==null?void 0:m.trim(),s=(u=e.portrait)==null?void 0:u.trim(),a=(_=e.background)==null?void 0:_.trim(),i=e.traits??[],l=e.skills??[],c=Object.entries(e.stats_raw??{}).filter(([f,h])=>Number.isFinite(h)).filter(([f])=>!f$.has(f.toLowerCase()));return o`
    <div class="trpg-actor">
      ${s?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${e.name} portrait`}
              loading="lazy"
              onError=${f=>{const h=f.target;h&&(h.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${e.name}</span>
        <${pt} status=${e.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${e.role}">${e.role}</span>
        <${C$} keeper=${e.keeper} role=${e.role} />
      </div>
      ${e.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${e.stats.hp}/${e.stats.max_hp}
              ${e.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${e.stats.mp}/${e.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${e.stats.level}</span>
            </div>
            <${S$} hp=${e.stats.hp} max=${e.stats.max_hp} />
            <${A$} stats=${e.stats} />
          </div>
        `:null}
      ${t?o`<div class="trpg-actor-meta">Archetype: ${As(t)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([f,h])=>o`
                <span class="trpg-custom-stat-chip">${As(f)} ${h}</span>
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
                  <span class="trpg-annot-name">${As(f)}</span>
                  <span class="trpg-annot-desc">${_$(f)}</span>
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
                  <span class="trpg-annot-name">${As(f)}</span>
                  <span class="trpg-annot-desc">${g$(f)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function I$({mapStr:e}){return o`<pre class="trpg-map">${e}</pre>`}function Lc({events:e,emptyLabel:t="아직 이벤트가 없습니다."}){return e.length===0?o`<div class="empty-state" style="font-size:13px">${t}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${e.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${y$(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Ko(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${J} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function T$({events:e}){const t="__none__",n=uo.value,s=po.value,a=mo.value,i=Array.from(new Set(e.map(Ko).map(_=>_.trim()).filter(_=>_!==""))).sort((_,f)=>_.localeCompare(f)),l=Array.from(new Set(e.map(_=>(_.type??"").trim()).filter(_=>_!==""))).sort((_,f)=>_.localeCompare(f)),c=e.some(_=>(_.type??"").trim()===""),p=Array.from(new Set(e.map(_=>(_.phase??"").trim()).filter(_=>_!==""))).sort((_,f)=>_.localeCompare(f)),m=e.some(_=>(_.phase??"").trim()===""),u=e.filter(_=>{if(n!=="all"&&Ko(_)!==n)return!1;const f=(_.type??"").trim(),h=(_.phase??"").trim();if(s===t){if(f!=="")return!1}else if(s!=="all"&&f!==s)return!1;if(a===t){if(h!=="")return!1}else if(a!=="all"&&h!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${_=>{uo.value=_.target.value}}>
          <option value="all">all</option>
          ${i.map(_=>o`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${_=>{po.value=_.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${t}>(none)</option>`:null}
          ${l.map(_=>o`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${_=>{mo.value=_.target.value}}>
          <option value="all">all</option>
          ${m?o`<option value=${t}>(none)</option>`:null}
          ${p.map(_=>o`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{uo.value="all",po.value="all",mo.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${u.length} / 전체 ${e.length}
      </span>
    </div>
    <${Lc} events=${u.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function R$({outcome:e}){if(!e)return null;const t=i=>{const l=i.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=e.result==="victory"?"승리":e.result==="defeat"?"패배":e.result==="draw"?"무승부":"종료",s=e.result==="victory"?"#34d399":e.result==="defeat"?"#f87171":"#9ca3af",a=[e.reason?`원인: ${t(e.reason)}`:null,e.phase?`페이즈: ${t(e.phase)}`:null,typeof e.turn=="number"?`턴: ${e.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${e.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${t(e.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function zc({state:e}){const t=e.history??[];return t.length===0?null:o`
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
  `}function P$({state:e,nowMs:t}){var m;const n=Ke.value||((m=e.session)==null?void 0:m.room)||"",s=bs.value,a=e.party??[];if(!a.find(u=>u.id===jt.value)&&a.length>0){const u=a[0];u&&(jt.value=u.id)}const l=async()=>{var _,f;if(!n){E("Room ID가 비어 있습니다.","error");return}if(!Os(t))return;const u=((_=e.current_round)==null?void 0:_.phase)??((f=e.session)==null?void 0:f.status)??"unknown";if(Bo("라운드 실행",n,u)){bs.value="running";try{const h=await au(n);Fo.value=h,bs.value="ok";const b=v(h.summary)?h.summary:null,$=b?Vn(b,"advanced",!1):!1,S=b?$e(b,"progress_reason",""):"";E($?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${S?`: ${S}`:""}`,$?"success":"warning"),tt()}catch(h){Fo.value=null,bs.value="error";const b=h instanceof Error?h.message:"라운드 실행에 실패했습니다.";E(b,"error")}finally{xa()}}},c=async()=>{var _,f;if(!n||!Os(t))return;const u=((_=e.current_round)==null?void 0:_.phase)??((f=e.session)==null?void 0:f.status)??"unknown";if(Bo("턴 강제 진행",n,u))try{await ru(n),E("턴을 다음 단계로 이동했습니다.","success"),tt()}catch{E("턴 이동에 실패했습니다.","error")}finally{xa()}},p=async()=>{if(!n||!Os(t))return;const u=jt.value.trim();if(!u){E("먼저 Actor를 선택하세요.","warning");return}const _=Number.parseInt(Xa.value,10),f=Number.parseInt(Za.value,10);if(Number.isNaN(_)||Number.isNaN(f)){E("stat/dc는 숫자여야 합니다.","warning");return}const h=Number.parseInt(ys.value,10),b=ys.value.trim()===""||Number.isNaN(h)?void 0:h;try{await iu({roomId:n,actorId:u,action:Ya.value.trim()||"ability_check",statValue:_,dc:f,rawD20:b}),E("주사위 판정을 기록했습니다.","success"),tt()}catch{E("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${u=>{Ke.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${jt.value}
            onChange=${u=>{jt.value=u.target.value}}
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
              value=${Ya.value}
              onInput=${u=>{Ya.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Xa.value}
              onInput=${u=>{Xa.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Za.value}
              onInput=${u=>{Za.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${ys.value}
              onInput=${u=>{ys.value=u.target.value}}
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
  `}function L$({state:e}){var a;const t=Ke.value||((a=e.session)==null?void 0:a.room)||"",n=Ss.value,s=async()=>{if(!t){E("Room ID가 비어 있습니다.","warning");return}const i=xs.value.trim(),l=so.value.trim();if(!l&&!i){E("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Pn.value.trim(),10),p=Number.parseInt(lo.value.trim(),10),m=Number.isFinite(p)?Math.max(1,p):20,u=Number.isFinite(c)?Math.max(0,Math.min(m,c)):m;let _={};try{_=$$(co.value)}catch(f){E(f instanceof Error?f.message:"능력치 JSON 오류","error");return}Ss.value="spawning";try{const f=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,h=await lu(t,{actor_id:i||void 0,name:l||void 0,role:ao.value,idempotencyKey:f,portrait:io.value.trim()||void 0,background:ro.value.trim()||void 0,hp:u,max_hp:m,alive:u>0,stats:Object.keys(_).length>0?_:void 0}),b=typeof h.actor_id=="string"?h.actor_id.trim():"";if(!b)throw new Error("생성 응답에 actor_id가 없습니다.");const $=oo.value.trim();$&&await cu(t,b,$),jt.value=b,Ve.value=b,i||(xs.value=""),Ss.value="ok",E(`Actor 생성 완료: ${b}`,"success"),await tt()}catch(f){Ss.value="error",E(f instanceof Error?f.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${so.value}
            onInput=${i=>{so.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${ao.value}
            onChange=${i=>{ao.value=i.target.value}}
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
            value=${oo.value}
            onInput=${i=>{oo.value=i.target.value}}
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
              value=${xs.value}
              onInput=${i=>{xs.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${io.value}
              onInput=${i=>{io.value=i.target.value}}
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
              value=${Pn.value}
              onInput=${i=>{Pn.value=i.target.value}}
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
              value=${lo.value}
              onInput=${i=>{const l=i.target.value;lo.value=l,h$(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ro.value}
              onInput=${i=>{ro.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${co.value}
              onInput=${i=>{co.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function z$({state:e,nowMs:t}){var f;const n=Ke.value||((f=e.session)==null?void 0:f.room)||"",s=e.join_gate,a=no.value,i=v(a)?a:null,l=(e.party??[]).filter(h=>h.role!=="dm"),c=Ve.value.trim(),p=l.some(h=>h.id===c),m=p?c:c?"__manual__":"",u=async()=>{const h=Ve.value.trim(),b=ks.value.trim();if(!n||!h){E("Room/Actor가 필요합니다.","warning");return}xe.value="checking";try{const $=await du(n,h,b||void 0);no.value=$,xe.value="ok",E("참가 가능 여부를 갱신했습니다.","success")}catch($){xe.value="error";const S=$ instanceof Error?$.message:"참가 가능 여부 확인에 실패했습니다.";E(S,"error")}},_=async()=>{var A,x;const h=Ve.value.trim(),b=ks.value.trim(),$=to.value.trim();if(!n||!h||!b){E("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Os(t))return;const S=((A=e.current_round)==null?void 0:A.phase)??((x=e.session)==null?void 0:x.status)??"unknown";if(Bo("Mid-Join 승인 요청",n,S)){xe.value="requesting";try{const z=await uu({room_id:n,actor_id:h,keeper_name:b,role:eo.value,...$?{name:$}:{}});no.value=z;const T=v(z)?Vn(z,"granted",!1):!1,P=v(z)?$e(z,"reason_code",""):"";T?E("Mid-Join이 승인되었습니다.","success"):E(`Mid-Join이 거절되었습니다${P?`: ${P}`:""}`,"warning"),xe.value=T?"ok":"error",tt()}catch(z){xe.value="error";const T=z instanceof Error?z.message:"Mid-Join 요청에 실패했습니다.";E(T,"error")}finally{xa()}}};return o`
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
            onChange=${h=>{const b=h.target.value;if(b==="__manual__"){(p||!c)&&(Ve.value="");return}Ve.value=b}}
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
                value=${Ve.value}
                onInput=${h=>{Ve.value=h.target.value}}
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
            value=${ks.value}
            onInput=${h=>{ks.value=h.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${eo.value}
            onChange=${h=>{eo.value=h.target.value}}
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
            value=${to.value}
            onInput=${h=>{to.value=h.target.value}}
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
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Vn(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Le(i,"effective_score",0)}/${Le(i,"required_points",0)}</span>
            ${$e(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${$e(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Mc({state:e}){const t=[...e.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return t.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${t.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Nc({state:e}){var n;const t=e.current_round;return t?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${t.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${t.phase}</div>
      ${t.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=t.events[t.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Ec(){const e=Fo.value;if(!e)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const t=e.summary,n=v(t)?t:null,a=(Array.isArray(e.statuses)?e.statuses:[]).filter(v).slice(-8),i=e.canon_check,l=v(i)?i:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(P=>typeof P=="string").slice(0,3):[],p=l&&Array.isArray(l.violations)?l.violations.filter(P=>typeof P=="string").slice(0,3):[],m=n?Vn(n,"advanced",!1):!1,u=n?$e(n,"progress_reason",""):"",_=n?$e(n,"progress_detail",""):"",f=n?Le(n,"player_successes",0):0,h=n?Le(n,"player_required_successes",0):0,b=n?Vn(n,"dm_success",!1):!1,$=n?Le(n,"timeouts",0):0,S=n?Le(n,"unavailable",0):0,A=n?Le(n,"reprompts",0):0,x=n?Le(n,"npc_attacks",0):0,z=n?Le(n,"keeper_timeout_sec",0):0,T=n?Le(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${m?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${m?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${e.turn_before??0} → ${e.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${b?"DM ok":"DM stalled"} / players ${f}/${h}
          </span>
        </div>
        ${u?o`<div style="margin-top:4px; font-size:12px;">${u}</div>`:null}
        ${_?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${_}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${$}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${z||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${T}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(P=>{const M=$e(P,"status","unknown"),R=$e(P,"actor_id","-"),N=$e(P,"role","-"),Z=$e(P,"reason",""),oe=$e(P,"action_type",""),V=$e(P,"reply","");return o`
                <div class="trpg-round-item ${M.includes("fallback")||M.includes("timeout")?"failed":"active"}">
                  <span>${R} (${N})</span>
                  <span style="margin-left:auto; font-size:11px;">${M}</span>
                  ${oe?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${oe}</div>`:null}
                  ${Z?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${Z}</div>`:null}
                  ${V?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${V.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${$e(l,"status","unknown")}</strong>
            </div>
            ${p.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${p.map(P=>o`<div>violation: ${P}</div>`)}
                </div>`:null}
            ${c.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(P=>o`<div>warning: ${P}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function M$({state:e,nowMs:t}){var l,c,p;const n=Ke.value||((l=e.session)==null?void 0:l.room)||"",s=((c=e.current_round)==null?void 0:c.phase)??((p=e.session)==null?void 0:p.status)??"unknown",a=Tc(t),i=k$(t);return o`
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
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>x$(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{xa(),E("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function N$({active:e}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${e===n.id?"active":""}"
          role="tab"
          aria-selected=${e===n.id}
          onClick=${()=>b$(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function E$({state:e}){const t=e.party??[],n=e.story_log??[];return o`
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
          <${Lc} events=${n.slice(-20)} />
        <//>

        ${e.map?o`
            <${I} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${I$} mapStr=${e.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${I} title="현재 라운드" semanticId="lab.trpg">
          <${Nc} state=${e} />
        <//>

        <${I} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${Mc} state=${e} />
        <//>

        <${I} title=${`파티 (${t.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${t.map(s=>o`<${Pc} key=${s.id??s.name} actor=${s} />`)}
            ${t.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${e.history&&e.history.length>0?o`
            <${I} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
              <${zc} state=${e} />
            <//>
          `:null}
      </div>
    </div>
  `}function j$({state:e}){const t=e.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${I} title=${`이벤트 타임라인 (${t.length})`}>
          <${T$} events=${t} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${I} title="최근 라운드 결과" semanticId="lab.trpg">
          <${Ec} />
        <//>

        <${I} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${Nc} state=${e} />
        <//>
      </div>
    </div>
  `}function w$({state:e,nowMs:t}){const n=e.party??[];return o`
    <div>
      <${M$} state=${e} nowMs=${t} />
      <div class="trpg-layout">
        <div>
          <${I} title="조작 패널" semanticId="lab.trpg">
            <${P$} state=${e} nowMs=${t} />
          <//>

          <${I} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${L$} state=${e} />
          <//>

          <${I} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${z$} state=${e} nowMs=${t} />
          <//>

          <${I} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${Ec} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${I} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${Mc} state=${e} />
          <//>

          <${I} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${Pc} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${e.history&&e.history.length>0?o`
              <${I} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
                <${zc} state=${e} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function D$(){var c,p,m,u,_;const e=Xr.value,t=Ao.value;if(ne(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const f=window.setInterval(()=>{hr.value=Date.now()},1e3);return()=>{window.clearInterval(f)}},[]),t&&!e)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!e)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>tt()}>Refresh</button>
      </div>
    `;const n=e.party??[],s=e.story_log??[],a=e.outcome,i=Ic.value,l=hr.value;return o`
    <div>
      <${be} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Ke.value||((c=e.session)==null?void 0:c.room)||"-"} · phase: ${((p=e.current_round)==null?void 0:p.phase)??((m=e.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>tt()}>새로고침</button>
      </div>

      <${R$} outcome=${a} />

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

      <${N$} active=${i} />

      ${i==="overview"?o`<${E$} state=${e} />`:i==="timeline"?o`<${j$} state=${e} />`:o`<${w$} state=${e} nowMs=${l} />`}
    </div>
  `}const jc=g(null),Uo=g(null),qs=g(!1);async function O$(){if(!qs.value){qs.value=!0,Uo.value=null;try{jc.value=await Sd()}catch(e){Uo.value=e instanceof Error?e.message:String(e)}finally{qs.value=!1}}}function q$(e){switch(e){case"essential":return"badge-essential";case"standard":return"badge-standard";default:return"badge-full"}}function F$({items:e,maxCount:t}){return e.length===0?o`<p class="muted">No tool calls recorded yet.</p>`:o`
    <div class="tool-bar-chart">
      ${e.map(n=>{const s=t>0?n.call_count/t*100:0;return o`
          <div class="tool-bar-row" key=${n.name}>
            <span class="tool-bar-name">${n.name}</span>
            <span class="tool-bar-tier ${q$(n.tier)}">${n.tier}</span>
            <div class="tool-bar-track">
              <div class="tool-bar-fill" style=${{width:`${s}%`}} />
            </div>
            <span class="tool-bar-count">${n.call_count}</span>
          </div>
        `})}
    </div>
  `}function K$({dist:e}){const t=e.full,n=t>0?(e.essential/t*100).toFixed(1):"0",s=t>0?(e.standard/t*100).toFixed(1):"0",a=t-e.standard,i=t>0?(a/t*100).toFixed(1):"0";return o`
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
  `}function B$(){const e=jc.value,t=qs.value,n=Uo.value;return o`
    <div class="tool-metrics">
      <div class="tool-metrics-header">
        <h3 class="tool-metrics-title">Tool Usage</h3>
        <button
          class="control-btn ghost"
          onClick=${()=>void O$()}
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
            <${K$} dist=${e.tier_distribution} />
          </div>
          <div class="tool-metrics-section">
            <h4>Top 20 Tools</h4>
            <${F$}
              items=${e.top_20}
              maxCount=${e.top_20.length>0?e.top_20[0].call_count:0}
            />
          </div>
        </div>
      `:t?null:o`
        <p class="muted">Click Load to fetch tool usage statistics.</p>
      `}
    </div>
  `}function U$(){return o`
    <div>
      <${be} surfaceId="lab" />
      <${I} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${I} title="Tool Usage Metrics" class="section" semanticId="lab.tool_metrics">
        <${B$} />
      <//>

      <${I} title="TRPG" class="section" semanticId="lab.trpg">
        <${D$} />
      <//>
    </div>
  `}const Sa=g(new Set(["broadcast","tasks","keepers","system"]));function H$(e){const t=new Set(Sa.value);t.has(e)?t.delete(e):t.add(e),Sa.value=t}const Ci=g(null);function wc(e){Ci.value=e}function W$(e){return e.kind==="board"?"broadcast":e.kind==="tasks"?"tasks":e.kind==="keepers"?"keepers":"system"}const G$=Ce(()=>{const e=Sa.value;return Ks.value.filter(t=>e.has(W$(t)))}),J$=12e4,V$=Ce(()=>{const e=nl.value,t=Date.now();return He.value.map(n=>{const s=n.name.trim().toLowerCase(),a=e.get(s)??null;let i="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?i=t-new Date(l).getTime()>J$?"stale":"working":i="working"}else(n.status==="offline"||n.status==="inactive")&&(i="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:i,currentTask:n.current_task,motion:a}})}),Q$=Ce(()=>{const e=nl.value;return He.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle").map(t=>{const n=t.name.trim().toLowerCase(),s=e.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let i="calm";return a>=3?i="hot":a>=1&&(i="normal"),{name:t.name,emoji:t.emoji??"",koreanName:t.koreanName??null,currentTask:t.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:i}}).sort((t,n)=>{const s={hot:0,normal:1,calm:2};return s[t.pressure]-s[n.pressure]})});function yr(e){return e.kind==="board"?"live-event-broadcast":e.kind==="tasks"?"live-event-task":e.kind==="keepers"?"live-event-keeper":"live-event-system"}function Y$(e){const t=e.eventType;return t==="broadcast"?"broadcast":t==="agent_joined"?"joined":t==="agent_left"?"left":t==="task_update"?"task":t==="board_post"?"post":t==="board_comment"?"comment":t==="keeper_heartbeat"?"heartbeat":t==="keeper_handoff"?"handoff":t==="keeper_compaction"?"compact":t==="keeper_guardrail"?"guardrail":e.kind==="board"?"board":e.kind==="tasks"?"task":e.kind==="keepers"?"keeper":"system"}function X$(e){switch(e){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function Z$(){const e=V$.value,t=Ci.value;return e.length===0?o`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:o`
    <div class="pulse-strip">
      ${e.map(n=>o`
        <button
          key=${n.name}
          class="pulse-bubble ${X$(n.state)} ${t===n.name?"pulse-selected":""}"
          onClick=${()=>wc(t===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const eh=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function th(){const e=Sa.value;return o`
    <div class="activity-filter-bar">
      ${eh.map(t=>o`
        <button
          key=${t.kind}
          class="activity-filter-btn ${t.cssClass} ${e.has(t.kind)?"active":""}"
          onClick=${()=>H$(t.kind)}
        >
          ${t.label}
        </button>
      `)}
    </div>
  `}function nh(){const e=G$.value;return o`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${e.length} events</span>
      </div>
      <${th} />
      <div class="activity-stream-list">
        ${e.length===0?o`<div class="activity-empty">No events matching filters</div>`:e.map((t,n)=>o`
            <div
              key=${`${t.timestamp}-${n}`}
              class="activity-item ${yr(t)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${yr(t)}">${Y$(t)}</span>
                <span class="activity-agent">${t.agent}</span>
                <span class="activity-time">${Ql(t.timestamp)}</span>
              </div>
              <div class="activity-item-text">${t.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function sh(e){switch(e){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function ah(e){switch(e){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function oh(){const e=Q$.value,t=Ci.value;return o`
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
              onClick=${()=>wc(t===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?o`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${sh(n.pressure)}">
                  ${ah(n.pressure)}
                  ${n.assignedCount>0?o` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?o`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?o`<span class="focus-activity-text">${n.lastActivityText}</span>`:o`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?o`<${J} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function ih(){const e=ot.value;return o`
    <div class="live-monitor">
      <div class="live-header">
        <h2>Live Monitor</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${e?"connected":"disconnected"}"></span>
            ${e?"Connected":"Offline"}
          </span>
          <span class="live-stat">${He.value.length} agents</span>
          <span class="live-stat">${Aa.value} events</span>
        </div>
      </div>

      <${Z$} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${nh} />
        </div>
        <div class="live-panel-side">
          <${oh} />
        </div>
      </div>
    </div>
  `}const br=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],Ho=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"proof",label:"Proof",icon:"🔍",group:"observe",description:"협업, 대화, 도구, backing evidence를 증명 중심으로 읽는 표면"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"live",label:"Live",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}];function rh(e){const t=e==null?void 0:e.trim();return t?t.length>10?t.slice(0,10):t:"commit unavailable"}function Se(e,t){return o`
    <div class="build-badge-row">
      <span>${e}</span>
      <strong>${t}</strong>
    </div>
  `}function Cs(e,t,n,s,a){return o`
    <div style="padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
      <div class="rail-card-head" style="margin:0;">
        <h3 style="font-size:12px;">${e}</h3>
        <span class="rail-section-chip ${n}">${t}</span>
      </div>
      ${s}
      ${a?o`<div class="rail-build-hint">${a}</div>`:null}
    </div>
  `}function lh({currentTab:e}){var p,m,u,_,f,h,b,$,S,A;const t=ot.value,n=(p=te.value)==null?void 0:p.build,s=(m=te.value)==null?void 0:m.lodge,a=(u=te.value)==null?void 0:u.gardener,i=(_=te.value)==null?void 0:_.guardian,l=(f=te.value)==null?void 0:f.sentinel,c=[];if(s&&c.push(Cs("Lodge",s.enabled?s.quiet_active?"Quiet":"Live":"Disabled",s.enabled?s.quiet_active?"warn":"ok":"bad",[Se("Ticks",s.total_ticks??0),Se("Checkins",s.total_checkins??0),Se("Last result",((h=s.last_tick_result)==null?void 0:h.activity_report)??s.last_skip_reason??"none")])),a&&c.push(Cs("Gardener",a.alive?"Live":a.enabled?"Starting":"Disabled",a.alive?"ok":a.enabled?"warn":"bad",[Se("Last tick",a.last_tick_completed_at?o`<${J} timestamp=${a.last_tick_completed_at} />`:"never"),Se("Decision",`${a.last_intervention??"none"} · ${a.last_decision_source??"none"}`),Se("Backlog",`${((b=a.health_summary)==null?void 0:b.todo_count)??0} todo · P1/2 ${(($=a.health_summary)==null?void 0:$.high_priority_todo)??0}`)],a.last_reason??a.last_error??void 0)),i){const x=i.masc_loops_running||i.lodge_loop_started||i.lodge_running;c.push(Cs("Guardian",x?"Live":i.enabled?"Idle":"Disabled",x?"ok":i.enabled?"warn":"bad",[Se("Mode",i.mode??"unknown"),Se("Loops",`zombie ${i.zombie_loop_running?"on":"off"} · gc ${i.gc_loop_running?"on":"off"}`),Se("Owner",i.runtime_owner??"none")],((S=i.last_lodge_result)==null?void 0:S.message)??i.last_gc_result??i.last_zombie_result??void 0))}return l&&c.push(Cs("Sentinel",l.started?"Live":l.enabled?"Starting":"Disabled",l.started?"ok":l.enabled?"warn":"bad",[Se("Agent",l.agent_name??"sentinel"),Se("Consumers",((A=l.consumers)==null?void 0:A.length)??0),Se("Guardian owner",l.guardian_runtime_owner??"none")],l.llm_enabled===!0?"LLM-enabled housekeeping resident":void 0)),o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${O} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${t?"ok":"bad"}">${t?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agent</span>
          <strong>${He.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keeper</span>
          <strong>${dt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Task</span>
          <strong>${Xe.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Event</span>
          <strong>${Aa.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Yn(),il(),No(e)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>se("intervene")}>
          개입 열기
        </button>
      </div>
      ${n?o`<div class="rail-build-hint">Server Build · v${n.release_version} · ${rh(n.commit)}</div>`:null}
      ${c.length>0?o`
            <div style="margin-top:12px; display:flex; flex-direction:column; gap:10px;">
              ${c}
            </div>
          `:null}
    </section>
  `}function ch(){const e=_e.value,t=(e==null?void 0:e.pending_confirms.length)??0,n=(e==null?void 0:e.sessions.length)??0,s=(e==null?void 0:e.keepers.length)??0;return o`
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
          <span>Keeper</span>
          <strong>${s}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{ye(),Tt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>se("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}const Is=g(!1);function dh(){const e=ot.value;return o`
    <div class="connection-status ${e?"connected":"disconnected"}">
      <span class="status-dot ${e?"connected":"disconnected"}"></span>
      <span class="status-text">${e?"Live":"재연결 중..."}</span>
      <span class="event-count">${Aa.value} events</span>
    </div>
  `}function uh(e){const t=e==null?void 0:e.trim();return t?t.length>10?t.slice(0,10):t:"commit unavailable"}function ph(){const e=te.value,t=e==null?void 0:e.build,n=t?`v${t.release_version} · ${uh(t.commit)}`:e!=null&&e.version?`v${e.version} · commit unavailable`:"version unavailable";return o`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${Is.value}
        onClick=${()=>{Is.value=!Is.value}}
      >
        Server Build · ${n}
      </button>
      ${Is.value?o`
            <div class="build-badge-panel">
              <div class="build-badge-row">
                <span>릴리즈</span>
                <strong>${(t==null?void 0:t.release_version)??(e==null?void 0:e.version)??"unknown"}</strong>
              </div>
              <div class="build-badge-row">
                <span>커밋</span>
                <strong>${(t==null?void 0:t.commit)??"commit unavailable"}</strong>
              </div>
              <div class="build-badge-row">
                <span>서버 시작</span>
                <strong>${t!=null&&t.started_at?o`<${J} timestamp=${t.started_at} />`:"unknown"}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof(t==null?void 0:t.uptime_seconds)=="number"?`${t.uptime_seconds}s`:"unknown"}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${e!=null&&e.generated_at?o`<${J} timestamp=${e.generated_at} />`:"unknown"}</strong>
              </div>
            </div>
          `:null}
    </div>
  `}function mh(){const e=F.value.tab,t=Ho.find(s=>s.id===e),n=br.find(s=>s.id===(t==null?void 0:t.group));return o`
    <aside class="dashboard-rail">
      <${be} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${O} panelId="side_rail.navigate" compact=${!0} />
          ${n?o`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${br.map(s=>o`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${Ho.filter(a=>a.group===s.id).map(a=>o`
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

      <${lh} currentTab=${e} />
      <${ch} />
    </aside>
  `}function vh(){switch(F.value.tab){case"mission":return o`<${Vi} />`;case"proof":return o`<${G_} />`;case"execution":return o`<${jf} />`;case"live":return o`<${ih} />`;case"memory":return o`<${Cf} />`;case"governance":return o`<${c$} />`;case"planning":return o`<${Qf} />`;case"intervene":return o`<${mf} />`;case"command":return o`<${cf} />`;case"lab":return o`<${U$} />`;default:return o`<${Vi} />`}}function _h(){return So.value&&!ot.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${vh} />`}function gh(){ne(()=>{Jc(),Rr(),rl(),kt(),il(),kl();const n=hp();return yp(),()=>{nd(),n(),bp()}},[]),ne(()=>{const n=setInterval(()=>{No(F.value.tab)},15e3);return()=>{clearInterval(n)}},[]),ne(()=>{No(F.value.tab)},[F.value.tab]);const e=F.value.tab,t=Ho.find(n=>n.id===e);return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <${ph} />
          </h1>
          <p class="header-subtitle">${(t==null?void 0:t.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${dh} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${mh} />
        <main class="dashboard-main">
          <${_h} />
        </main>
      </div>

      <${s_} />
      <${Mv} />
      <${Av} />
    </div>
  `}const kr=document.getElementById("app");kr&&Bc(o`<${gh} />`,kr);export{m_ as _};
