var xc=Object.defineProperty;var Sc=(e,t,n)=>t in e?xc(e,t,{enumerable:!0,configurable:!0,writable:!0,value:n}):e[t]=n;var Rt=(e,t,n)=>Sc(e,typeof t!="symbol"?t+"":t,n);import{e as Ac,_ as Cc,c as g,b as Ae,y as te,d as cr,A as Tc,G as Ic}from"./vendor-kuFK4-oj.js";(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const l of o.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=Ac.bind(Cc);const Rc=["mission","proof","execution","live","memory","governance","planning","intervene","command","lab"],dr={tab:"mission",params:{},postId:null};function ho(e){return!!e&&Rc.includes(e)}function li(e){try{return decodeURIComponent(e)}catch{return e}}function ci(e){const t={};return e&&new URLSearchParams(e).forEach((s,a)=>{t[a]=s}),t}function Pc(e){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function ur(e,t){if(e[0]==="chains"){const o={...t,surface:"chains"};return e[1]==="operation"&&e[2]&&(o.operation=li(e[2])),{tab:"command",params:o,postId:null}}if(e[0]==="lab"){const o={...t};return e[1]&&(o.surface=li(e[1])),{tab:"lab",params:o,postId:null}}const n=e[0],s=t.tab;return{tab:ho(n)?n:ho(s)?s:"mission",params:t,postId:null}}function js(e){const t=(e||"").replace(/^#/,"").trim();if(!t)return dr;const n=li(t);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=ci(a),l=Pc(s);return ur(l,o)}function Lc(e,t){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...dr,params:ci(t.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=ci(t.replace(/^\?/,""));return ur(s,a)}function pr(e){const t=e.tab==="lab"&&e.params.surface?`lab/${encodeURIComponent(e.params.surface)}`:e.tab,n=Object.entries(e.params).filter(([a])=>!(a==="tab"||e.tab==="lab"&&a==="surface"));if(n.length===0)return`#${t}`;const s=new URLSearchParams(n);return`#${t}?${s.toString()}`}const F=g(js(window.location.hash));window.addEventListener("hashchange",()=>{F.value=js(window.location.hash)});function de(e,t){const n={tab:e,params:t??{}};window.location.hash=pr(n)}function wc(e){window.location.hash=`#memory?post=${encodeURIComponent(e)}`}function Nc(){if(window.location.hash&&window.location.hash!=="#"){F.value=js(window.location.hash);return}const e=Lc(window.location.pathname,window.location.search);if(e){F.value=e;const t=pr(e);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${t}`);return}window.location.hash="#mission",F.value=js(window.location.hash)}const yo="masc_dashboard_sse_session_id",zc=1e3,Mc=15e3,st=g(!1),ya=g(0),mr=g(null),Ds=g([]);function Ec(){let e=sessionStorage.getItem(yo);return e||(e=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(yo,e)),e}const jc=200;function Dc(e,t,n="system",s={}){const a={agent:e,text:t,timestamp:Date.now(),kind:n,...s};Ds.value=[a,...Ds.value].slice(0,jc)}function di(e,t=88){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-3)}...`:n:void 0}function bo(e,t){const n=di(t);return n?`${e}: ${n}`:`New ${e.toLowerCase()}`}function Se(e,t,n,s,a={}){Dc(e,t,n,{eventType:s,...a})}let Le=null,Kt=null,ui=0;function vr(){Kt&&(clearTimeout(Kt),Kt=null)}function Oc(){if(Kt)return;ui++;const e=Math.min(ui,5),t=Math.min(Mc,zc*Math.pow(2,e));Kt=setTimeout(()=>{Kt=null,_r()},t)}function _r(){vr(),Le&&(Le.close(),Le=null);const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");n&&t.set("agent",n),s&&t.set("token",s),t.set("session_id",Ec());const a=t.toString()?`/sse?${t.toString()}`:"/sse",o=new EventSource(a);Le=o,o.onopen=()=>{Le===o&&(ui=0,st.value=!0)},o.onerror=()=>{Le===o&&(st.value=!1,o.close(),Le=null,Oc())},o.onmessage=l=>{try{const c=JSON.parse(l.data);ya.value++,mr.value=c,qc(c)}catch{}}}function qc(e){const t=e.type,n=e.agent??e.author??e.from??e.from_agent??"";switch(t){case"agent_joined":Se(n,"Joined","system","agent_joined");break;case"agent_left":Se(n,"Left","system","agent_left");break;case"broadcast":Se(n,`${(e.message??e.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Se(n,`Task: ${e.task_id??""} -> ${e.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Se(n,bo("Post",e.content??e.message),"board","board_post",{author:e.author??n,preview:di(e.content??e.message),postId:e.post_id});break;case"board_comment":case"masc/board_comment":Se(n,bo("Comment",e.content??e.message),"board","board_comment",{author:e.author??n,preview:di(e.content??e.message),postId:e.post_id});break;case"keeper_heartbeat":Se(e.name??n,`Heartbeat gen=${e.generation??"?"} ctx=${e.context_ratio!=null?Math.round(e.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Se(e.name??n,`Handoff gen ${e.from_generation??"?"} -> ${e.to_generation??"?"} (${e.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Se(e.name??n,`Compaction saved ${e.saved_tokens??"?"} tokens (${e.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Se(e.name??n,`Guardrail: ${e.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Se(n,t,"system","unknown")}}function Fc(){vr(),Le&&(Le.close(),Le=null),st.value=!1}function v(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function r(e){return typeof e=="string"&&e.trim()!==""?e.trim():void 0}function d(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function j(e){return typeof e=="boolean"?e:void 0}function W(e){return Array.isArray(e)?e.map(t=>typeof t=="string"?t.trim():"").filter(Boolean):[]}function pe(e,t=[]){if(Array.isArray(e))return e;if(!v(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function le(e){if(typeof e=="string"&&e.trim()!=="")return e;if(!(typeof e!="number"||!Number.isFinite(e)||e<=0))return new Date(e*1e3).toISOString()}function gr(){return new URLSearchParams(window.location.search)}const Kc="masc_dashboard_agent_name";function Bc(){var e;try{return((e=localStorage.getItem(Kc))==null?void 0:e.trim())||null}catch{return null}}function fr(){const e=gr(),t={},n=e.get("token"),s=Bc(),a=e.get("agent")??e.get("agent_name")??s;return n&&(t.Authorization=`Bearer ${n}`),a&&(t["X-MASC-Agent"]=a),t}function $r(){return{...fr(),"Content-Type":"application/json"}}const Uc=15e3,Di=3e4,Hc=6e4,ko=new Set([408,425,429,500,502,503,504]);class Gn extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);Rt(this,"method");Rt(this,"path");Rt(this,"status");Rt(this,"statusText");Rt(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function Oi(e,t,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(e,{...t,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const l=typeof t.method=="string"?t.method.toUpperCase():"GET";throw new Gn({method:l,path:e,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function Wc(){var t,n;const e=gr();return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function X(e){const t=await Oi(e,{headers:fr()},Uc);if(!t.ok)throw new Gn({method:"GET",path:e,status:t.status,statusText:t.statusText});return t.json()}function Gc(e){return new Promise(t=>setTimeout(t,e))}function Jc(e){const t=e.match(/\b(\d{3})\b/);if(!t)return null;const n=t[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function Vc(e){if(e instanceof Gn)return e.timeout||typeof e.status=="number"&&ko.has(e.status);if(!(e instanceof Error))return!1;if(/timeout after \d+ms/i.test(e.message))return!0;const t=Jc(e.message);return t!==null&&ko.has(t)}async function ba(e,t,n=2){let s=0;for(;;)try{return await t()}catch(a){if(!Vc(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${e} failed (attempt ${s+1}), retrying in ${o}ms`,a),await Gc(o),s+=1}}async function Ee(e,t,n,s=Di){const a=await Oi(e,{method:"POST",headers:{...$r(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new Gn({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.json()}async function Yc(e,t,n,s=Di){const a=await Oi(e,{method:"POST",headers:{...$r(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new Gn({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.text()}function Qc(e){const t=e.split(`
`).find(s=>s.startsWith("data: ")),n=t?t.slice(6).trim():e.trim();return JSON.parse(n)}function Xc(e){var t,n,s,a,o,l,c;if((t=e.error)!=null&&t.message)throw new Error(e.error.message);if((n=e.result)!=null&&n.isError){const p=((a=(s=e.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(p)}return((c=(l=(o=e.result)==null?void 0:o.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function rt(e,t){const n=await Yc("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:e,arguments:t},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Hc),s=Qc(n);return Xc(s)}function Zc(){return X("/api/v1/dashboard/shell")}function ed(){return X("/api/v1/dashboard/execution")}function td(e,t){const n=new URLSearchParams;return n.set("sort_by",e),t!=null&&t.excludeSystem&&n.set("exclude_system","true"),X(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function nd(){return ba("fetchDashboardGovernance",async()=>{const e=await X("/api/v1/dashboard/governance"),t=Array.isArray(e.items)?e.items.map(o=>hd(o)).filter(o=>o!==null):[],n=Array.isArray(e.pending_actions)?e.pending_actions.map(o=>br(o)).filter(o=>o!==null):[],s=t.filter(o=>o.kind==="debate").map(o=>({id:o.id,topic:o.topic,status:o.status,argument_count:o.evidence_refs.length,created_at:o.last_activity_at??void 0})),a=t.filter(o=>o.kind==="consensus").map(o=>({id:o.id,topic:o.topic,initiator:o.related_agents[0]||"system",votes:o.votes??0,quorum:o.quorum??0,threshold:o.threshold,state:o.status,created_at:o.last_activity_at??void 0}));return{generated_at:oe(e.generated_at)??void 0,summary:v(e.summary)?{debates:me(e.summary.debates)??void 0,voting_sessions:me(e.summary.voting_sessions)??void 0,debates_open:me(e.summary.debates_open)??void 0,sessions_active:me(e.summary.sessions_active)??void 0,sessions_without_quorum:me(e.summary.sessions_without_quorum)??void 0,ready_to_execute:me(e.summary.ready_to_execute)??void 0,oldest_open_debate_age_s:typeof e.summary.oldest_open_debate_age_s=="number"?e.summary.oldest_open_debate_age_s:null,last_activity_age_s:typeof e.summary.last_activity_age_s=="number"?e.summary.last_activity_age_s:null,judge_online:typeof e.summary.judge_online=="boolean"?e.summary.judge_online:void 0,judge_last_seen_at:oe(e.summary.judge_last_seen_at)}:void 0,debates:s,sessions:a,items:t,activity:Array.isArray(e.activity)?e.activity.map(o=>yd(o)).filter(o=>o!==null):[],judge:bd(e.judge),pending_actions:n}})}function sd(){return X("/api/v1/dashboard/semantics")}function ad(){return X("/api/v1/dashboard/mission")}function id(e){const t=`?session_id=${encodeURIComponent(e)}`;return X(`/api/v1/dashboard/session${t}`)}function od(e=!1){return X(`/api/v1/dashboard/mission/briefing${e?"?force=1":""}`)}function rd(e,t){const n=new URLSearchParams;e&&n.set("session_id",e),t&&n.set("operation_id",t);const s=n.toString();return X(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function ld(){return X("/api/v1/dashboard/planning")}function cd(){return X("/api/v1/tool-metrics")}function dd(){return X("/api/v1/operator")}function hr(e={}){const t=new URLSearchParams;e.targetType&&t.set("target_type",e.targetType),e.targetId&&t.set("target_id",e.targetId),e.includeWorkers!=null&&t.set("include_workers",e.includeWorkers?"true":"false");const n=t.toString();return X(`/api/v1/operator/digest${n?`?${n}`:""}`)}function ud(){return X("/api/v1/command-plane")}function pd(){return X("/api/v1/command-plane/summary")}function md(){return X("/api/v1/chains/summary")}function vd(e){return X(`/api/v1/chains/runs/${encodeURIComponent(e)}`)}function _d(){return X("/api/v1/command-plane/help")}function gd(e,t){const n=new URLSearchParams;e&&n.set("run_id",e),t&&n.set("operation_id",t);const s=n.toString();return X(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function fd(e,t){return Ee(e,t)}function $d(e){switch(e.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"swarm_run_continue":return 6e4;case"swarm_run_rerun":return 12e4;case"swarm_run_abandon":return 3e4;case"lodge_tick":return 45e3;default:return Di}}function ka(e){return Ee("/api/v1/operator/action",e,void 0,$d(e))}function yr(e,t,n="confirm"){return Ee("/api/v1/operator/confirm",{actor:e,confirm_token:t,decision:n})}function Ss(e){if(typeof e=="string"&&e.trim())return e;if(typeof e!="number"||Number.isNaN(e))return new Date().toISOString();const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}function oe(e){if(typeof e=="string"){const t=e.trim();return t||null}if(typeof e=="number"&&Number.isFinite(e)){const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}return null}function O(e){if(typeof e!="string")return null;const t=e.trim();return t||null}function br(e){if(!v(e))return null;const t=b(e.confirm_token??e.token,"").trim();return t?{confirm_token:t,actor:O(e.actor)??void 0,action_type:O(e.action_type)??void 0,target_type:O(e.target_type)??void 0,target_id:O(e.target_id),delegated_tool:O(e.delegated_tool)??void 0,created_at:oe(e.created_at)??void 0,preview:e.preview}:null}function qi(e){return v(e)?{board_post_id:O(e.board_post_id),task_id:O(e.task_id),operation_id:O(e.operation_id),team_session_id:O(e.team_session_id)}:{}}function kr(e){if(!v(e))return null;const t=O(e.action_kind),n=O(e.resolved_tool),s=O(e.target_type),a=O(e.target_id),o=O(e.reason);return!t&&!n&&!s&&!o?null:{action_kind:t??void 0,resolved_tool:n,target_type:s,target_id:a,reason:o??void 0,payload_preview:e.payload_preview}}function xr(e){if(!v(e))return null;const t=O(e.action_type),n=O(e.delegated_tool),s=O(e.confirmation_state),a=oe(e.created_at);return!t&&!n&&!s&&!a?null:{action_type:t??void 0,delegated_tool:n,confirmation_state:s??void 0,created_at:a}}function Sr(e){if(!v(e))return null;const t=br(e.pending_confirm),n=O(e.pending_confirm_token)??(t==null?void 0:t.confirm_token)??null;return{requires_human_gate:typeof e.requires_human_gate=="boolean"?e.requires_human_gate:void 0,pending_confirm:t,pending_confirm_token:n,ready_to_execute:typeof e.ready_to_execute=="boolean"?e.ready_to_execute:void 0}}function Ar(e){if(!v(e))return null;const t=O(e.summary),n=O(e.target_id);return!t&&!n?null:{judgment_id:O(e.judgment_id)??void 0,target_kind:O(e.target_kind)??void 0,target_id:n??void 0,status:O(e.status)??void 0,summary:t??void 0,confidence:typeof e.confidence=="number"?e.confidence:null,generated_at:oe(e.generated_at),expires_at:oe(e.expires_at),model_used:O(e.model_used),keeper_name:O(e.keeper_name),evidence_refs:we(e.evidence_refs),recommended_action:kr(e.recommended_action),guardrail_state:Sr(e.guardrail_state),executed_route:xr(e.executed_route)}}function hd(e){if(!v(e))return null;const t=b(e.id,"").trim(),n=b(e.topic,"").trim();if(!t||!n)return null;const s=qi(e.context);return{kind:b(e.kind,"debate"),id:t,topic:n,status:b(e.status??e.state,"open"),last_activity_at:oe(e.last_activity_at),truth_summary:O(e.truth_summary)??void 0,judgment_summary:O(e.judgment_summary),confidence:typeof e.confidence=="number"?e.confidence:null,related_agents:we(e.related_agents),context:s,linked_board_post_id:O(e.linked_board_post_id)??s.board_post_id??null,linked_task_id:O(e.linked_task_id)??s.task_id??null,linked_operation_id:O(e.linked_operation_id)??s.operation_id??null,linked_session_id:O(e.linked_session_id)??s.team_session_id??null,recommended_action:kr(e.recommended_action),executed_route:xr(e.executed_route),guardrail_state:Sr(e.guardrail_state),evidence_refs:we(e.evidence_refs),approve_count:me(e.approve_count),reject_count:me(e.reject_count),abstain_count:me(e.abstain_count),votes:me(e.votes),quorum:me(e.quorum),threshold:typeof e.threshold=="number"?e.threshold:void 0}}function yd(e){if(!v(e))return null;const t=b(e.kind,"").trim();return t?{kind:t,item_kind:O(e.item_kind)??void 0,item_id:O(e.item_id)??void 0,topic:O(e.topic)??void 0,created_at:oe(e.created_at),summary:O(e.summary)??void 0,actor:O(e.actor),index:me(e.index),decision:O(e.decision)}:null}function bd(e){if(v(e))return{judge_online:typeof e.judge_online=="boolean"?e.judge_online:void 0,refreshing:typeof e.refreshing=="boolean"?e.refreshing:void 0,generated_at:oe(e.generated_at),expires_at:oe(e.expires_at),model_used:O(e.model_used),keeper_name:O(e.keeper_name),last_error:O(e.last_error)}}function kd(e){var a;const t=e.trim(),s=((a=(t.startsWith("[flair:")?t.replace(/^\[flair:[^\]]+\]\s*/i,""):t).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function xd(e){if(!v(e))return null;const t=b(e.source,"").trim()||null,n=b(e.state_block,"").trim()||null;return!t&&!n?null:{source:t,state_block:n}}function Sd(e){if(!v(e))return null;const t=b(e.id,"").trim(),n=b(e.author,"").trim(),s=b(e.body,"").trim()||b(e.content,"").trim(),a=s;if(!t||!n)return null;const o=B(e.score,0),l=B(e.votes_up,0),c=B(e.votes_down,0),p=B(e.votes,o||l-c),m=B(e.comment_count,B(e.reply_count,0)),u=(()=>{const C=e.flair;if(typeof C=="string"&&C.trim())return C.trim();if(v(C)){const k=b(C.name,"").trim();if(k)return k}return b(e.flair_name,"").trim()||void 0})(),_=b(e.created_at_iso,"").trim()||Ss(e.created_at),f=b(e.updated_at_iso,"").trim()||(e.updated_at!==void 0?Ss(e.updated_at):_),S=b(e.title,"").trim()||kd(s),h=Array.isArray(e.tags)?e.tags.filter(C=>typeof C=="string"&&C.trim()!==""):[];return{id:t,author:n,post_kind:(()=>{const C=b(e.post_kind,"").trim().toLowerCase();return C==="automation"||C==="system"||C==="human"?C:void 0})(),title:S,body:s,content:a,meta:xd(e.meta),tags:h,votes:p,vote_balance:o,comment_count:m,created_at:_,updated_at:f,flair:u,hearth:b(e.hearth,"").trim()||null,visibility:b(e.visibility,"").trim()||void 0,expires_at:b(e.expires_at_iso,"").trim()||(e.expires_at!==void 0&&e.expires_at!==0?Ss(e.expires_at):"")||null,hearth_count:B(e.hearth_count,0)}}function Ad(e){if(!v(e))return null;const t=b(e.id,"").trim(),n=b(e.post_id,"").trim(),s=b(e.author,"").trim();return!t||!s?null:{id:t,post_id:n,author:s,content:b(e.content,""),created_at:Ss(e.created_at)}}async function Cd(e){return ba("fetchBoardPost",async()=>{const t=await X(`/api/v1/board/${e}?format=flat`),n=v(t.post)?t.post:t,s=Sd(n)??{id:e,author:"unknown",post_kind:"human",title:"Post",body:"",content:"",meta:null,tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(t.comments)?t.comments:[]).map(Ad).filter(l=>l!==null);return{...s,comments:o}})}function Cr(e,t){return Ee("/api/v1/tools/masc_board_vote",{post_id:e,direction:t,vote:t,voter:Wc()})}function Td(e,t,n){return Ee("/api/v1/tools/masc_board_comment",{post_id:e,author:t,content:n})}function Id(e){const t=b(e,"").trim().toLowerCase();if(t==="win"||t==="won"||t==="victory")return"victory";if(t==="lose"||t==="lost"||t==="defeat")return"defeat";if(t==="draw"||t==="stalemate"||t==="tie")return"draw"}function re(...e){for(const t of e){const n=b(t,"");if(n.trim())return n.trim()}return""}function xo(e){const t=Id(re(e.outcome,e.result,e.result_code));if(!t)return;const n=re(e.reason,e.reason_code,e.description,e.detail),s=re(e.summary,e.summary_ko,e.summary_en,e.note),a=re(e.details,e.details_text,e.text,e.note),o=re(e.winner,e.winner_name,e.actor_winner,e.winner_actor),l=re(e.winner_actor_id,e.winner_actor,e.actor_winner_id),c=re(e.raw_reason,e.raw_reason_code,e.error_message),p=(()=>{const _=e.evidence??e.evidence_ids??e.supporting_events??e.event_ids??[];return typeof _=="string"?[_]:Array.isArray(_)?_.map(f=>{if(typeof f=="string")return f.trim();if(v(f)){const $=b(f.summary,"").trim();if($)return $;const S=b(f.text,"").trim();if(S)return S;const h=b(f.type,"").trim();return h||b(f.event_id,"").trim()}return""}).filter(f=>f.length>0):[]})(),m=(()=>{const _=B(e.turn,Number.NaN);if(Number.isFinite(_))return _;const f=B(e.turn_number,Number.NaN);if(Number.isFinite(f))return f;const $=B(e.current_turn,Number.NaN);if(Number.isFinite($))return $;const S=B(e.round,Number.NaN);return Number.isFinite(S)?S:void 0})(),u=re(e.phase,e.phase_name,e.current_phase,e.phase_id);return{result:t,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:l||void 0,evidence:p.length>0?p:void 0,raw_reason:c||void 0,turn:m,phase:u||void 0}}function Rd(e,t){const n=v(e.state)?e.state:{};if(b(n.status,"active").toLowerCase()!=="ended")return;const a=[...t].reverse().find(l=>v(l)?b(l.type,"")==="session.outcome":!1),o=v(n.session_outcome)?n.session_outcome:{};if(v(o)&&Object.keys(o).length>0){const l=xo(o);if(l)return l}if(v(a))return xo(v(a.payload)?a.payload:{})}function b(e,t=""){return typeof e=="string"?e:t}function B(e,t=0){return typeof e=="number"&&Number.isFinite(e)?e:t}function me(e){if(typeof e=="number"&&Number.isFinite(e))return Math.trunc(e);if(typeof e=="string"){const t=Number.parseInt(e.trim(),10);if(Number.isFinite(t))return t}}function Os(e,t=!1){return typeof e=="boolean"?e:t}function we(e){return Array.isArray(e)?e.map(t=>{if(typeof t=="string")return t.trim();if(v(t)){const n=b(t.name,"").trim(),s=b(t.id,"").trim(),a=b(t.skill,"").trim();return n||s||a}return""}).filter(t=>t.length>0):[]}function Pd(e){const t={};if(!v(e)&&!Array.isArray(e))return t;if(v(e))return Object.entries(e).forEach(([n,s])=>{const a=n.trim(),o=b(s,"").trim();!a||!o||(t[a]=o)}),t;for(const n of e){if(!v(n))continue;const s=re(n.to,n.target,n.actor_id,n.name,n.id),a=re(n.relationship,n.relation,n.type,n.kind);!s||!a||(t[s]=a)}return t}function Ld(e,t,n){if(e==="dm"||e==="player"||e==="npc")return e;const s=t.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function ke(e,t,n,s=0){const a=e[t];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=e[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const wd=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Nd(e){const t=v(e.stats)?e.stats:{},n={};return Object.entries(t).forEach(([s,a])=>{const o=s.trim();o&&(wd.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function zd(e,t){if(e!=="dice.rolled")return;const n=B(t.raw_d20,0),s=B(t.total,0),a=B(t.bonus,0),o=b(t.action,"roll"),l=B(t.dc,0);return{notation:l>0?`${o} (DC ${l})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function Md(e){const t=JSON.stringify(e);return t?t.length>160?`${t.slice(0,157)}...`:t:""}function Ed(e){const t=e.trim().toLowerCase();return t?t.startsWith("dice.")?"dice":t.startsWith("combat.")||t.includes(".attack")||t.includes(".damage")?"combat":t.includes("actor.")?"actor":t.includes("turn.")||t==="turn.started"||t==="phase.changed"?"turn":t.includes("join.")?"join":t.includes("memory")?"memory":t.includes("world.")?"world":t.includes("narration")?"story":"meta":"meta"}function jd(e,t,n,s){const a=n||t||b(s.actor_id,"")||b(s.actor_name,"");switch(e){case"turn.action.proposed":{const o=b(s.proposed_action,b(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=b(s.reply,b(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return b(s.reply,b(s.content,b(s.text,"Narration")));case"dice.rolled":{const o=b(s.action,"roll"),l=B(s.total,0),c=B(s.dc,0),p=b(s.label,""),m=a||"actor",u=c>0?` vs DC ${c}`:"",_=p?` (${p})`:"";return`${m} ${o}: ${l}${u}${_}`}case"turn.started":return`Turn ${B(s.turn,1)} started`;case"phase.changed":return`Phase: ${b(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${b(s.name,v(s.actor)?b(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${b(s.keeper_name,b(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${b(s.keeper_name,b(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${B(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${B(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||b(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||b(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${b(s.reason_code,"unknown")}`;case"memory.signal":{const o=v(s.entity_refs)?s.entity_refs:{},l=b(o.requested_tier,""),c=b(o.effective_tier,""),p=Os(o.guardrail_applied,!1),m=b(s.summary_en,b(s.summary_ko,"Memory signal"));if(!l&&!c)return m;const u=l&&c?`${l}->${c}`:c||l;return`${m} [${u}${p?" (guardrail)":""}]`}case"world.event":{if(b(s.event_type,"")==="canon.check"){const l=b(s.status,"unknown"),c=b(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return b(s.description,b(s.summary,"World event"))}case"combat.attack":return b(s.summary,b(s.result,"Attack resolved"));case"combat.defense":return b(s.summary,b(s.result,"Defense resolved"));case"session.outcome":return b(s.summary,b(s.outcome,"Session ended"));default:{const o=Md(s);return o?`${e}: ${o}`:e}}}function Dd(e,t){const n=v(e)?e:{},s=b(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=b(n.actor_name,"").trim()||t[a]||b(v(n.payload)?n.payload.actor_name:"",""),l=v(n.payload)?n.payload:{},c=b(n.ts,b(n.timestamp,new Date().toISOString())),p=b(n.phase,b(l.phase,"")),m=b(n.category,"");return{type:s,actor:o||a||b(l.actor_name,""),actor_id:a||b(l.actor_id,""),actor_name:o,seq:n.seq,room_id:b(n.room_id,""),phase:p||void 0,category:m||Ed(s),visibility:b(n.visibility,b(l.visibility,"public")),event_id:b(n.event_id,""),content:jd(s,a,o,l),dice_roll:zd(s,l),timestamp:c}}function Od(e,t,n){var Q,se;const s=b(e.room_id,"")||n||"default",a=v(e.state)?e.state:{},o=v(a.party)?a.party:{},l=v(a.actor_control)?a.actor_control:{},c=v(a.join_gate)?a.join_gate:{},p=v(a.contribution_ledger)?a.contribution_ledger:{},m=Object.entries(o).map(([J,ee])=>{const A=v(ee)?ee:{},Ce=ke(A,"max_hp",void 0,10),He=ke(A,"hp",void 0,Ce),ut=ke(A,"max_mp",void 0,0),pt=ke(A,"mp",void 0,0),K=ke(A,"level",void 0,1),Te=ke(A,"xp",void 0,0),mt=Os(A.alive,He>0),dn=l[J],un=typeof dn=="string"?dn:void 0,ns=Ld(A.role,J,un),ss=me(A.generation),as=re(A.joined_at,A.joinedAt,A.started_at,A.startedAt),is=re(A.claimed_at,A.claimedAt,A.assigned_at,A.assignedAt,A.assigned_time),os=re(A.last_seen,A.lastSeen,A.last_seen_at,A.lastSeenAt,A.last_active,A.lastActive),rs=re(A.scene,A.current_scene,A.currentScene,A.world_scene,A.scene_name,A.sceneName),ls=re(A.location,A.current_location,A.currentLocation,A.position,A.zone,A.area);return{id:J,name:b(A.name,J),role:ns,keeper:un,archetype:b(A.archetype,""),persona:b(A.persona,""),portrait:b(A.portrait,"")||void 0,background:b(A.background,"")||void 0,traits:we(A.traits),skills:we(A.skills),stats_raw:Nd(A),status:mt?"active":"dead",generation:ss,joined_at:as||void 0,claimed_at:is||void 0,last_seen:os||void 0,scene:rs||void 0,location:ls||void 0,inventory:we(A.inventory),notes:we(A.notes),relationships:Pd(A.relationships),stats:{hp:He,max_hp:Ce,mp:pt,max_mp:ut,level:K,xp:Te,strength:ke(A,"strength","str",10),dexterity:ke(A,"dexterity","dex",10),constitution:ke(A,"constitution","con",10),intelligence:ke(A,"intelligence","int",10),wisdom:ke(A,"wisdom","wis",10),charisma:ke(A,"charisma","cha",10)}}}),u=m.filter(J=>J.status!=="dead"),_=Rd(e,t),f={phase_open:Os(c.phase_open,!0),min_points:B(c.min_points,3),window:b(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},$=Object.entries(p).map(([J,ee])=>{const A=v(ee)?ee:{};return{actor_id:J,score:B(A.score,0),last_reason:b(A.last_reason,"")||null,reasons:we(A.reasons)}}),S=m.reduce((J,ee)=>(J[ee.id]=ee.name,J),{}),h=t.map(J=>Dd(J,S)),C=B(a.turn,1),x=b(a.phase,"round"),k=b(a.map,""),N=v(a.world)?a.world:{},R=k||b(N.ascii_map,b(N.map,"")),P=h.filter((J,ee)=>{const A=t[ee];if(!v(A))return!1;const Ce=v(A.payload)?A.payload:{};return B(Ce.turn,-1)===C}),L=(P.length>0?P:h).slice(-12),I=b(a.status,"active");return{session:{id:s,room:s,status:I==="ended"?"ended":I==="paused"?"paused":"active",round:C,actors:u,created_at:((Q=h[0])==null?void 0:Q.timestamp)??new Date().toISOString()},current_round:{round_number:C,phase:x,events:L,timestamp:((se=h[h.length-1])==null?void 0:se.timestamp)??new Date().toISOString()},map:R||void 0,join_gate:f,contribution_ledger:$,outcome:_,party:u,story_log:h,history:[]}}async function qd(e){const t=`?room_id=${encodeURIComponent(e)}`,n=await X(`/api/v1/trpg/events${t}`);return Array.isArray(n.events)?n.events:[]}async function Fd(e){const t=`?room_id=${encodeURIComponent(e)}`,[n,s]=await Promise.all([X(`/api/v1/trpg/state${t}`),qd(e)]);return Od(n,s,e)}function Kd(e){return Ee("/api/v1/trpg/rounds/run",{room_id:e})}function Bd(e){const t="".trim().toLowerCase();if(t)switch(t){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return t}}function Ud(e){const t={room_id:e.roomId,actor_id:e.actorId,action:e.action,stat_value:e.statValue,dc:e.dc};return e.rawD20!=null&&(t.raw_d20=e.rawD20),e.ruleModule&&(t.rule_module=e.ruleModule),Ee("/api/v1/trpg/dice/roll",t)}function Hd(e,t){const n=Bd();return Ee("/api/v1/trpg/turns/advance",{room_id:e,...n?{phase:n}:{}})}function Wd(e,t){var a;const n=(a=t.idempotencyKey)==null?void 0:a.trim(),s={room_id:e};return t.actor_id&&t.actor_id.trim()&&(s.actor_id=t.actor_id.trim()),t.name&&t.name.trim()&&(s.name=t.name.trim()),t.role&&(s.role=t.role),t.archetype&&t.archetype.trim()&&(s.archetype=t.archetype.trim()),t.persona&&t.persona.trim()&&(s.persona=t.persona.trim()),t.portrait&&t.portrait.trim()&&(s.portrait=t.portrait.trim()),t.background&&t.background.trim()&&(s.background=t.background.trim()),t.hp!=null&&(s.hp=t.hp),t.max_hp!=null&&(s.max_hp=t.max_hp),t.alive!=null&&(s.alive=t.alive),Array.isArray(t.traits)&&t.traits.length>0&&(s.traits=t.traits),Array.isArray(t.skills)&&t.skills.length>0&&(s.skills=t.skills),Array.isArray(t.inventory)&&t.inventory.length>0&&(s.inventory=t.inventory),t.stats&&Object.keys(t.stats).length>0&&(s.stats=t.stats),n&&(s.idempotency_key=n),Ee("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function Gd(e,t,n){return Ee("/api/v1/trpg/actors/claim",{room_id:e,actor_id:t,keeper:n})}async function Jd(e,t,n){const s=await rt("trpg.join.eligibility",{room_id:e,actor_id:t,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Vd(e){const t=await rt("trpg.mid_join.request",e);return JSON.parse(t)}async function Yd(e,t){await rt("masc_broadcast",{agent_name:e,message:t})}async function Qd(e=40){return(await rt("masc_messages",{limit:e})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Xd(e,t=20){return rt("masc_task_history",{task_id:e,limit:t})}async function Zd(e){const t=await rt("masc_debate_start",{topic:e});try{return JSON.parse(t)}catch{return null}}async function eu(e){return ba("fetchDebateStatus",async()=>{const t=encodeURIComponent(e),n=await X(`/api/v1/council/debates/${t}/summary`);if(!v(n))return null;const s=v(n.debate)?n.debate:n,a=b(s.id,"").trim(),o=b(s.topic,"").trim();return!a||!o?null:{debate:{id:a,topic:o,status:b(s.status,"open"),created_at:oe(s.created_at_iso??s.created_at),closed_at:oe(s.closed_at)},arguments:Array.isArray(n.arguments)?n.arguments.flatMap(l=>v(l)?[{index:B(l.index,0),agent:b(l.agent,"unknown"),position:b(l.position,"neutral"),content:b(l.content,""),evidence:we(l.evidence),reply_to:me(l.reply_to)??null,mentions:we(l.mentions),archetype:O(l.archetype),created_at:oe(l.created_at)}]:[]):[],summary:{support_count:v(n.summary)?B(n.summary.support_count,0):B(n.support_count,0),oppose_count:v(n.summary)?B(n.summary.oppose_count,0):B(n.oppose_count,0),neutral_count:v(n.summary)?B(n.summary.neutral_count,0):B(n.neutral_count,0),total_arguments:v(n.summary)?B(n.summary.total_arguments,0):B(n.total_arguments,0),summary_text:v(n.summary)?b(n.summary.summary_text,""):b(n.summary_text,"")},context:qi(n.context),judgment:Ar(n.judgment)}})}async function tu(e){return ba("fetchConsensusSessionSummary",async()=>{const t=encodeURIComponent(e),n=await X(`/api/v1/council/sessions/${t}/summary`);if(!v(n)||!v(n.session))return null;const s=n.session,a=b(s.id,"").trim(),o=b(s.topic,"").trim();return!a||!o?null:{session:{id:a,topic:o,state:b(s.state,"open"),initiator:b(s.initiator,"system"),quorum:B(s.quorum,0),threshold:B(s.threshold,0),created_at:oe(s.created_at),closed_at:oe(s.closed_at)},votes:Array.isArray(n.votes)?n.votes.flatMap(l=>v(l)?[{agent:b(l.agent,"unknown"),decision:b(l.decision,"abstain"),reason:b(l.reason,""),timestamp:oe(l.timestamp),weight:typeof l.weight=="number"?l.weight:void 0,archetype:O(l.archetype)}]:[]):[],summary:{approve_count:v(n.summary)?B(n.summary.approve_count,0):0,reject_count:v(n.summary)?B(n.summary.reject_count,0):0,abstain_count:v(n.summary)?B(n.summary.abstain_count,0):0,quorum_met:v(n.summary)?Os(n.summary.quorum_met,!1):!1,result:v(n.summary)?O(n.summary.result):null},context:qi(n.context),judgment:Ar(n.judgment)}})}function nu(e,t,n){return rt("masc_keeper_msg",{name:e,message:t})}const su=g(""),Ke=g({}),ce=g({}),pi=g({}),mi=g({}),vi=g({}),_i=g({}),Be=g({});function ie(e,t,n){e.value={...e.value,[t]:n}}function au(e){var n;const t=(n=r(e))==null?void 0:n.toLowerCase();return t==="user"||t==="assistant"||t==="system"||t==="tool"?t:"other"}function iu(e){switch(e){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Na(e,t){if(!Array.isArray(e))return[];const n=[];for(const s of e){if(!v(s))continue;const a=r(s.name);if(!a)continue;const o=r(s[t]);t==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function ou(e){if(!v(e))return null;const t=r(e.name);return t?{name:t,trigger:r(e.trigger),outcome:r(e.outcome),summary:r(e.summary),reason:r(e.reason)}:null}function ru(e){const t=e.toLowerCase();return t.includes("graphql")?"graphql_error":t.includes("timeout")||t.includes("model")||t.includes("llm")||t.includes("api key")||t.includes("api_key")||t.includes("provider")?"llm_error":"unknown"}function lu(e,t){return e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":t==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":t==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":t==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Tr(e,t,n){return r(e)??lu(t,n)}function Ir(e,t){return typeof e=="boolean"?e:t==="recover"}function qs(e){if(!v(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);return!t||!n||!s?null:{health_state:t,quiet_reason:r(e.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:le(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:Ir(e.recoverable,n),summary:Tr(e.summary,t,r(e.quiet_reason)??null),keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function Rr(e){return v(e)?{hour:d(e.hour),checked:d(e.checked)??0,acted:d(e.acted)??0,acted_names:W(e.acted_names),activity_report:r(e.activity_report),quiet_hours_overridden:j(e.quiet_hours_overridden),skipped_reason:r(e.skipped_reason),acted_rows:Na(e.acted_rows,"summary").map(t=>({name:t.name,summary:t.summary})),passed_rows:Na(e.passed_rows,"reason").map(t=>({name:t.name,reason:t.reason})),skipped_rows:Na(e.skipped_rows,"reason").map(t=>({name:t.name,reason:t.reason})),checkins:Array.isArray(e.checkins)?e.checkins.map(ou).filter(t=>t!==null):[]}:null}function cu(e){return v(e)?{enabled:j(e.enabled)??!1,interval_s:d(e.interval_s)??0,quiet_start:d(e.quiet_start),quiet_end:d(e.quiet_end),quiet_active:j(e.quiet_active),use_planner:j(e.use_planner),delegate_llm:j(e.delegate_llm),agent_count:d(e.agent_count),agents:W(e.agents),last_tick_ago_s:d(e.last_tick_ago_s)??null,last_tick_ago:r(e.last_tick_ago),total_ticks:d(e.total_ticks),total_checkins:d(e.total_checkins),last_skip_reason:r(e.last_skip_reason)??null,last_tick_result:Rr(e.last_tick_result),active_self_heartbeats:W(e.active_self_heartbeats)}:null}function du(e){return v(e)?{status:e.status,diagnostic:qs(e.diagnostic)}:null}function uu(e){return v(e)?{recovered:j(e.recovered)??!1,skipped_reason:r(e.skipped_reason)??null,before:qs(e.before),after:qs(e.after),down:e.down,up:e.up}:null}function pu(e,t){var k,N;if(!(e!=null&&e.name))return null;const n=r((k=e.agent)==null?void 0:k.status)??r(e.status)??"unknown",s=r((N=e.agent)==null?void 0:N.error)??null,a=e.presence_keepalive??!0,o=e.keepalive_running??!1,l=e.turn_count??0,c=e.last_turn_ago_s??null,p=e.proactive_enabled??!1,m=e.proactive_cooldown_sec??0,u=e.last_proactive_ago_s??null,_=p&&u!=null?Math.max(0,m-u):null,f=l<=0||c==null?"never":c>900?"stale":"fresh",$=typeof e.last_heartbeat=="string"&&e.last_heartbeat.trim()?e.last_heartbeat:null,S=s??(a&&!o?"keeper keepalive is not running":null),h=n==="offline"||n==="inactive"?"offline":S?"degraded":f==="stale"?"stale":f==="never"?"idle":"healthy",C=S?ru(S):t!=null&&t.quiet_active&&f!=="fresh"?"quiet_hours":a&&!o?"disabled":l<=0?"never_started":_!=null&&_>0?"min_gap":f==="fresh"||f==="stale"?"no_recent_activity":"unknown",x=h==="offline"||h==="degraded"||h==="stale"?"recover":C==="quiet_hours"?"manual_lodge_poke":C==="unknown"?"probe":"direct_message";return{health_state:h,quiet_reason:C,next_action_path:x,last_reply_status:f,last_reply_at:$,last_reply_preview:null,last_error:S,next_eligible_at_s:_!=null&&_>0?_:null,recoverable:Ir(void 0,x),summary:Tr(void 0,h,C),keepalive_running:o}}function mu(e,t){if(!v(e))return null;const n=au(e.role),s=r(e.content)??r(e.preview);if(!s)return null;const a=le(e.ts_unix)??le(e.timestamp);return{id:`${n}-${a??"entry"}-${t}`,role:n,label:iu(n),text:s,timestamp:a,delivery:"history"}}function vu(e,t,n){const s=v(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,l)=>mu(o,l)).filter(o=>o!==null):[];return{name:e,diagnostic:qs(s==null?void 0:s.diagnostic),history:a,rawText:t,rawStatus:n,loadedAt:new Date().toISOString()}}function So(e,t){const n=ce.value[e]??[];ce.value={...ce.value,[e]:[...n,t].slice(-50)}}function _u(e,t){return e.role!==t.role||e.text!==t.text?!1:e.timestamp&&t.timestamp?e.timestamp===t.timestamp:!0}function gu(e,t){const s=(ce.value[e]??[]).filter(a=>a.delivery!=="history"&&!t.some(o=>_u(a,o)));ce.value={...ce.value,[e]:[...t,...s].slice(-50)}}function xa(e,t){Ke.value={...Ke.value,[e]:t},gu(e,t.history)}function Ao(e,t){const n=Ke.value[e];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};xa(e,{...n,diagnostic:{...s,...t}})}async function Fi(){try{await Jn()}catch(e){console.warn("[keeper-runtime] dashboard refresh failed",e)}}function fu(e){su.value=e.trim()}async function Pr(e,t=!1){const n=e.trim();if(!n)return null;if(!t&&Ke.value[n])return Ke.value[n];ie(pi,n,!0),ie(Be,n,null);try{const s=await rt("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=vu(n,s,a);return xa(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return ie(Be,n,a),null}finally{ie(pi,n,!1)}}async function $u(e,t){const n=e.trim(),s=t.trim();if(!n||!s)return;const a=`local-${Date.now()}`;So(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),ie(mi,n,!0),ie(Be,n,null);try{const o=await nu(n,s);ce.value={...ce.value,[n]:(ce.value[n]??[]).map(l=>l.id===a?{...l,delivery:"delivered"}:l)},So(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Ao(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await Fi()}catch(o){const l=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw ce.value={...ce.value,[n]:(ce.value[n]??[]).map(c=>c.id===a?{...c,delivery:"error",error:l}:c)},Ao(n,{last_reply_status:"error",last_error:l}),ie(Be,n,l),o}finally{ie(mi,n,!1)}}async function hu(e,t){const n=e.trim();if(!n)return null;ie(vi,n,!0),ie(Be,n,null);try{const s=await ka({actor:t,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=du(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const l=Ke.value[n];xa(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??ce.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Fi(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw ie(Be,n,a),s}finally{ie(vi,n,!1)}}async function yu(e,t){const n=e.trim();if(!n)return null;ie(_i,n,!0),ie(Be,n,null);try{const s=await ka({actor:t,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=uu(s.result),o=(a==null?void 0:a.after)??null;if(o){const l=Ke.value[n];xa(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??ce.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Fi(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw ie(Be,n,a),s}finally{ie(_i,n,!1)}}function vt(e){return(e??"").trim().toLowerCase()}function ge(e){const t=typeof e=="number"?e:Date.parse(e);return Number.isNaN(t)?0:t}function As(e,t=88){const n=e.replace(/\s+/g," ").trim();return n&&(n.length>t?`${n.slice(0,t-3)}...`:n)}function ds(e){return typeof e!="number"||!Number.isFinite(e)||e<0?null:new Date(Date.now()-e*1e3).toISOString()}function pn(e){return e.last_heartbeat??ds(e.last_turn_ago_s)??ds(e.last_proactive_ago_s)??ds(e.last_handoff_ago_s)??ds(e.last_compaction_ago_s)}function bu(e){const t=e.title.trim();return t||As(e.content)}function ku(e){const t=e.generation??"?",n=typeof e.context_ratio=="number"&&Number.isFinite(e.context_ratio)?`${Math.round(e.context_ratio*100)}%`:"?";return e.last_heartbeat?`Heartbeat gen=${t} ctx=${n}`:`Keeper snapshot gen=${t} ctx=${n}`}function xu(e,t,n,s,a={}){var N;const o=vt(e),l=t.filter(R=>vt(R.assignee)===o&&(R.status==="claimed"||R.status==="in_progress")).length,c=n.filter(R=>vt(R.from)===o).sort((R,P)=>ge(P.timestamp)-ge(R.timestamp))[0],p=s.filter(R=>vt(R.agent)===o||vt(R.author)===o).sort((R,P)=>ge(P.timestamp)-ge(R.timestamp))[0],m=(a.boardPosts??[]).filter(R=>vt(R.author)===o).sort((R,P)=>ge(P.updated_at||P.created_at)-ge(R.updated_at||R.created_at))[0],u=(a.keepers??[]).filter(R=>vt(R.name)===o&&pn(R)!==null).sort((R,P)=>ge(pn(P)??0)-ge(pn(R)??0))[0],_=c?ge(c.timestamp):0,f=p?ge(p.timestamp):0,$=m?ge(m.updated_at||m.created_at):0,S=u?ge(pn(u)??0):0,h=a.lastSeen?ge(a.lastSeen):0,C=((N=a.currentTask)==null?void 0:N.trim())||(l>0?`${l} claimed tasks`:null);if(_===0&&f===0&&$===0&&S===0&&h===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:C};const k=[c?{timestamp:c.timestamp,ts:_,text:As(c.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:$,text:`Post: ${As(bu(m))}`}:null,u?{timestamp:pn(u),ts:S,text:ku(u)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:f,text:As(p.text)}:null].filter(R=>R!==null).sort((R,P)=>P.ts-R.ts)[0];return k&&k.ts>=h?{activeAssignedCount:l,lastActivityAt:k.timestamp,lastActivityText:k.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:C??"Presence heartbeat"}}const Ue=g([]),Qe=g([]),gi=g([]),lt=g([]),ne=g(null),Su=g(null),Lr=g(null),wr=g([]),Nr=g([]),zr=g([]),Mr=g([]),Er=g([]),jr=g([]),fi=g(new Map),Sa=g([]),In=g("recent"),ht=g(!0),Dr=g(null),Fe=g(""),Bt=g([]),fn=g(!1),Or=g(new Map),Ki=g("unknown"),Ut=g(null),$i=g(!1),Rn=g(!1),hi=g(!1),$n=g(!1),Bi=g(null),Fs=g(!1),Ks=g(null),qr=g(null),yi=g(null),Au=g(null),Cu=g(null),Tu=g(null);Ae(()=>Ue.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle"));const Fr=Ae(()=>{const e=Qe.value;return{todo:e.filter(t=>t.status==="todo"),inProgress:e.filter(t=>t.status==="in_progress"||t.status==="claimed"),done:e.filter(t=>t.status==="done")}}),Kr=Ae(()=>{const e=new Map,t=Qe.value,n=gi.value,s=Ds.value,a=Sa.value,o=lt.value;for(const l of Ue.value)e.set(l.name.trim().toLowerCase(),xu(l.name,t,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:o}));return e});function Iu(e){var o;const t=((o=e.status)==null?void 0:o.toLowerCase())??"";if(t==="offline"||t==="inactive")return"offline";const n=e.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}Ae(()=>{const e=new Map;for(const t of lt.value)e.set(t.name,Iu(t));return e});const Ru=12e4;function Pu(e,t){const n=t.get(e.name);if(n!=null)return n;const s=e.last_heartbeat?Date.parse(e.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[e.last_turn_ago_s,e.last_proactive_ago_s,e.last_handoff_ago_s,e.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}Ae(()=>{const e=Date.now(),t=new Set,n=fi.value;for(const s of lt.value){const a=Pu(s,n);a!=null&&e-a>Ru&&t.add(s.name)}return t});function Lu(e){return e==="dashboard_refresh"||e==="masc/dashboard_refresh"||e.startsWith("goal_")||e.startsWith("masc/goal_")||e.startsWith("mdal_")||e.startsWith("masc/mdal_")||e.startsWith("operator_")||e.startsWith("masc/operator_")||e.startsWith("command_plane_")||e.startsWith("masc/command_plane_")}function Br(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="active"||t==="busy"||t==="listening"||t==="idle"||t==="inactive"||t==="offline"?t:t==="in_progress"||t==="claimed"?"busy":"offline"}function wu(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="todo"||t==="in_progress"||t==="claimed"||t==="done"||t==="cancelled"?t:t==="inprogress"?"in_progress":"todo"}function Nu(e){if(!v(e))return null;const t=r(e.name);return t?{name:t,agent_type:r(e.agent_type),status:Br(e.status),current_task:r(e.current_task)??null,joined_at:r(e.joined_at),last_seen:r(e.last_seen),capabilities:W(e.capabilities),emoji:r(e.emoji),koreanName:r(e.koreanName)??r(e.korean_name),model:r(e.model),traits:W(e.traits),interests:W(e.interests),activityLevel:d(e.activityLevel)??d(e.activity_level),primaryValue:r(e.primaryValue)??r(e.primary_value)}:null}function zu(e){if(!v(e))return null;const t=r(e.id),n=r(e.title);return!t||!n?null:{id:t,title:n,status:wu(e.status),priority:d(e.priority),assignee:r(e.assignee),description:r(e.description),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function Mu(e){if(!v(e))return null;const t=r(e.from)??r(e.from_agent)??"system",n=r(e.content)??"",s=r(e.timestamp)??new Date().toISOString();return{id:r(e.id),seq:d(e.seq),from:t,content:n,timestamp:s,type:r(e.type)}}function Ui(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="ok"||t==="warn"||t==="bad"?t:"ok"}function Eu(e){return v(e)?{active_sessions:d(e.active_sessions),blocked_sessions:d(e.blocked_sessions),active_operations:d(e.active_operations),blocked_operations:d(e.blocked_operations),runtime_pressure:d(e.runtime_pressure),worker_alerts:d(e.worker_alerts),continuity_alerts:d(e.continuity_alerts),priority_items:d(e.priority_items),todo_tasks:d(e.todo_tasks),claimed_tasks:d(e.claimed_tasks),running_tasks:d(e.running_tasks),done_tasks:d(e.done_tasks),cancelled_tasks:d(e.cancelled_tasks),keepers:d(e.keepers)}:null}function Xe(e){if(!v(e))return null;const t=r(e.surface),n=r(e.label),s=r(e.target_type),a=r(e.target_id),o=r(e.focus_kind);return!t||!n||!s||!a||!o?null:{surface:t==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:o,operation_id:r(e.operation_id)??null,command_surface:r(e.command_surface)??null}}function ju(e){if(!v(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.summary),a=r(e.target_type),o=r(e.target_id);return!t||!s||!a||!o||n!=="session"&&n!=="operation"?null:{id:t,kind:n,severity:Ui(e.severity),status:r(e.status),summary:s,target_type:a,target_id:o,linked_session_id:r(e.linked_session_id)??null,linked_operation_id:r(e.linked_operation_id)??null,last_seen_at:r(e.last_seen_at)??null,top_handoff:Xe(e.top_handoff),intervene_handoff:Xe(e.intervene_handoff),command_handoff:Xe(e.command_handoff)}}function Du(e){if(!v(e))return null;const t=r(e.session_id),n=r(e.goal);return!t||!n?null:{session_id:t,goal:n,room:r(e.room)??null,status:r(e.status),health:r(e.health),member_names:W(e.member_names),linked_operation_id:r(e.linked_operation_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,runtime_blocker:r(e.runtime_blocker)??null,worker_gap_summary:r(e.worker_gap_summary)??null,last_activity_at:r(e.last_activity_at)??null,last_activity_summary:r(e.last_activity_summary)??null,communication_summary:r(e.communication_summary)??null,active_count:d(e.active_count),required_count:d(e.required_count),top_handoff:Xe(e.top_handoff),intervene_handoff:Xe(e.intervene_handoff),command_handoff:Xe(e.command_handoff)}}function Ou(e){if(!v(e))return null;const t=r(e.operation_id),n=r(e.objective);return!t||!n?null:{operation_id:t,objective:n,status:r(e.status),stage:r(e.stage)??null,assigned_unit_id:r(e.assigned_unit_id)??null,assigned_unit_label:r(e.assigned_unit_label)??null,linked_session_id:r(e.linked_session_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,blocker_summary:r(e.blocker_summary)??null,search_status:r(e.search_status)??null,next_tool:r(e.next_tool)??null,updated_at:r(e.updated_at)??null,top_handoff:Xe(e.top_handoff),command_handoff:Xe(e.command_handoff)}}function Co(e){if(!v(e))return null;const t=r(e.name)??r(e.agent_name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline"?null:{name:t,agent_name:r(e.agent_name),status:r(e.status),tone:Ui(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,active_task_count:d(e.active_task_count),related_session_id:r(e.related_session_id)??null,related_operation_id:r(e.related_operation_id)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),model:r(e.model)??null,recent_output_preview:r(e.recent_output_preview)??null,recent_event:r(e.recent_event)??null}}function qu(e){if(!v(e))return null;const t=r(e.name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:t,agent_name:r(e.agent_name)??null,status:r(e.status),tone:Ui(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,last_autonomous_action_at:r(e.last_autonomous_action_at)??null,generation:d(e.generation),turn_count:d(e.turn_count),context_ratio:d(e.context_ratio)??null,continuity:r(e.continuity)??null,lifecycle:r(e.lifecycle)??null,related_session_id:r(e.related_session_id)??null,model:r(e.model)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),skill_reason:r(e.skill_reason)??null}}function To(e){if(typeof e.seq=="number"&&Number.isFinite(e.seq))return e.seq;const t=Date.parse(e.timestamp);return Number.isNaN(t)?0:t}function Fu(e,t){if(t.length===0)return e;const n=new Map;for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>To(s)-To(a)).slice(-500)}function Ku(e){return Array.isArray(e)?e.map(t=>{if(!v(t))return null;const n=d(t.ts_unix);if(n==null)return null;const s=v(t.handoff)?t.handoff:null;return{ts:n,context_ratio:d(t.context_ratio)??0,context_tokens:d(t.context_tokens)??0,context_max:d(t.context_max)??0,latency_ms:d(t.latency_ms)??0,generation:d(t.generation)??0,channel:typeof t.channel=="string"?t.channel:"turn",is_handoff:s!=null&&t.handoff_performed===!0,is_compaction:t.compacted===!0,compaction_saved_tokens:d(t.compaction_saved_tokens)??0,compaction_trigger:typeof t.compaction_trigger=="string"?t.compaction_trigger:null,model_used:typeof t.model_used=="string"?t.model_used:"",cost_usd:d(t.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?d(s.new_generation)??null:null}}).filter(t=>t!==null):[]}function Io(e){if(!v(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);if(!t||!n||!s)return null;const a=r(e.quiet_reason)??null,o=r(e.summary)??(t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:t,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:le(e.last_reply_at)??r(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:typeof e.recoverable=="boolean"?e.recoverable:n==="recover",summary:o,keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function Bu(e,t){return(Array.isArray(e)?e:v(e)&&Array.isArray(e.keepers)?e.keepers:[]).map(s=>{if(!v(s))return null;const a=v(s.agent)?s.agent:null,o=v(s.context)?s.context:null,l=v(s.metrics_window)?s.metrics_window:void 0,c=r(s.name);if(!c)return null;const p=d(s.context_ratio)??d(o==null?void 0:o.context_ratio),m=r(s.status)??r(a==null?void 0:a.status)??"offline",u=Br(m),_=r(s.model)??r(s.active_model)??r(s.primary_model),f=W(s.skill_secondary),$=o?{source:r(o.source),context_ratio:d(o.context_ratio),context_tokens:d(o.context_tokens),context_max:d(o.context_max),message_count:d(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,S=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:d(a.last_seen_ago_s),capabilities:W(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,h=Ku(s.metrics_series),C={name:c,runtime_class:s.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:typeof s.desired=="boolean"?s.desired:void 0,resident_registered:typeof s.resident_registered=="boolean"?s.resident_registered:void 0,reconcile_status:r(s.reconcile_status)??null,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:_,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:u,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:d(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:d(s.proactive_idle_sec),proactive_cooldown_sec:d(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:d(s.generation),turn_count:d(s.turn_count)??d(s.total_turns),keeper_age_s:d(s.keeper_age_s),last_turn_ago_s:d(s.last_turn_ago_s),last_handoff_ago_s:d(s.last_handoff_ago_s),last_compaction_ago_s:d(s.last_compaction_ago_s),last_proactive_ago_s:d(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:p,context_tokens:d(s.context_tokens)??d(o==null?void 0:o.context_tokens),context_max:d(s.context_max)??d(o==null?void 0:o.context_max),context_source:r(s.context_source)??r(o==null?void 0:o.source),context:$,traits:W(s.traits),interests:W(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:d(s.activityLevel)??d(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:W(s.recent_tool_names)??[],conversation_tail_count:d(s.conversation_tail_count),k2k_count:d(s.k2k_count),handoff_count_total:d(s.handoff_count_total)??d(s.trace_history_count),compaction_count:d(s.compaction_count),last_compaction_saved_tokens:d(s.last_compaction_saved_tokens),diagnostic:Io(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:f,skill_reason:r(s.skill_reason)??null,metrics_series:h.length>0?h:void 0,metrics_window:l,agent:S};return C.diagnostic=Io(s.diagnostic)??pu(C,(t==null?void 0:t.lodge)??null),C}).filter(s=>s!==null)}function Uu(e){if(!v(e))return;const t=r(e.release_version),n=le(e.started_at),s=d(e.uptime_seconds);if(!(!t||!n||s==null))return{release_version:t,commit:r(e.commit)??null,started_at:n,uptime_seconds:s}}function Hu(e){if(v(e))return{enabled:e.enabled===!0,alive:e.alive===!0,status:r(e.status)??void 0,tick_in_progress:typeof e.tick_in_progress=="boolean"?e.tick_in_progress:void 0,tick_count:d(e.tick_count)??void 0,check_interval_sec:d(e.check_interval_sec)??void 0,last_tick_started_at:le(e.last_tick_started_at)??r(e.last_tick_started_at)??null,last_tick_completed_at:le(e.last_tick_completed_at)??r(e.last_tick_completed_at)??null,next_tick_due_at:le(e.next_tick_due_at)??r(e.next_tick_due_at)??null,last_health_check_at:le(e.last_health_check_at)??r(e.last_health_check_at)??null,last_intervention:r(e.last_intervention)??void 0,last_decision_source:r(e.last_decision_source)??void 0,last_action:r(e.last_action)??void 0,last_target:r(e.last_target)??null,last_reason:r(e.last_reason)??null,last_error:r(e.last_error)??null,circuit_open:typeof e.circuit_open=="boolean"?e.circuit_open:void 0,circuit_open_until:le(e.circuit_open_until)??r(e.circuit_open_until)??null,can_spawn:typeof e.can_spawn=="boolean"?e.can_spawn:void 0,can_retire:typeof e.can_retire=="boolean"?e.can_retire:void 0,last_spawn_attempt_at:le(e.last_spawn_attempt_at)??r(e.last_spawn_attempt_at)??null,last_retirement_attempt_at:le(e.last_retirement_attempt_at)??r(e.last_retirement_attempt_at)??null,spawns_today:d(e.spawns_today)??void 0,retirements_today:d(e.retirements_today)??void 0,health_summary:v(e.health_summary)?{total_agents:d(e.health_summary.total_agents)??void 0,active_agents:d(e.health_summary.active_agents)??void 0,idle_agents:d(e.health_summary.idle_agents)??void 0,todo_count:d(e.health_summary.todo_count)??void 0,high_priority_todo:d(e.health_summary.high_priority_todo)??void 0,orphan_count:d(e.health_summary.orphan_count)??void 0,homeostatic_score:d(e.health_summary.homeostatic_score)??void 0,needs_workers:typeof e.health_summary.needs_workers=="boolean"?e.health_summary.needs_workers:void 0}:void 0}}function Ur(e,t){return v(e)?{...e,generated_at:t??le(e.generated_at)??void 0,build:Uu(e.build),lodge:cu(e.lodge)??void 0,gardener:Hu(e.gardener)??void 0}:null}function Hr(e,t){return t?e?{...e,...t,build:t.build??e.build,generated_at:t.generated_at??e.generated_at}:t:e}function Wu(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="running"||t==="interrupted"||t==="completed"||t==="stopped"||t==="error"?t:t.startsWith("error")?"error":"running"}function Gu(e){if(!v(e))return null;const t=d(e.iteration);if(t==null)return null;const n=d(e.metric_before)??0,s=d(e.metric_after)??n,a=v(e.evidence)?e.evidence:null;return{iteration:t,metric_before:n,metric_after:s,delta:d(e.delta)??s-n,changes:r(e.changes)??"",failed_attempts:r(e.failed_attempts)??"",next_suggestion:r(e.next_suggestion)??"",elapsed_ms:d(e.elapsed_ms)??0,cost_usd:d(e.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:d(a.tool_call_count)??0,tool_names:W(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function Ju(e){var o,l;if(!v(e))return null;const t=r(e.loop_id);if(!t)return null;const n=d(e.baseline_metric)??0,s=Array.isArray(e.history)?e.history.map(Gu).filter(c=>c!==null):[],a=d(e.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:t,profile:r(e.profile)??"unknown",status:Wu(e.status),strict_mode:typeof e.strict_mode=="boolean"?e.strict_mode:void 0,error_message:r(e.error_message)??r(e.error_reason)??null,stop_reason:r(e.stop_reason)??r(e.reason)??null,current_iteration:d(e.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:d(e.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(e.target)??"",stagnation_streak:d(e.stagnation_streak)??0,stagnation_limit:d(e.stagnation_limit)??0,elapsed_seconds:d(e.elapsed_seconds)??0,updated_at:le(e.updated_at)??null,stopped_at:le(e.stopped_at)??null,execution_mode:e.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:e.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(e.worker_model)??null,evidence_policy:e.evidence_policy==="hard"||e.evidence_policy==="legacy"?e.evidence_policy:void 0,latest_tool_call_count:d(e.latest_tool_call_count)??0,latest_tool_names:W(e.latest_tool_names)??[],session_id:r(e.session_id)??null,evidence_status:e.evidence_status==="legacy_unverified"?"legacy_unverified":e.evidence_status==="verified"?"verified":null,durability:e.durability==="persistent_backend"||e.durability==="memory_only"?e.durability:void 0,persistence_backend:e.persistence_backend==="filesystem"||e.persistence_backend==="postgres"||e.persistence_backend==="memory"?e.persistence_backend:void 0,recoverable:typeof e.recoverable=="boolean"?e.recoverable:void 0,history:s}}async function Jn(){$i.value=!0;try{await Promise.all([Gr(),yt()]),qr.value=new Date().toISOString()}catch(e){console.error("Dashboard refresh error:",e)}finally{$i.value=!1}}async function Wr(){Fs.value=!0,Ks.value=null;try{const e=await sd();Bi.value=e,Tu.value=new Date().toISOString()}catch(e){Ks.value=e instanceof Error?e.message:"Failed to load dashboard semantics"}finally{Fs.value=!1}}function Vu(e){var t;return((t=Bi.value)==null?void 0:t.surfaces.find(n=>n.id===e))??null}function Yu(e){var n;const t=((n=Bi.value)==null?void 0:n.surfaces)??[];for(const s of t){const a=s.panels.find(o=>o.id===e);if(a)return a}return null}function Qu(e){var s,a;Bt.value=(Array.isArray(e.goals)?e.goals:[]).map(o=>{if(!v(o))return null;const l=r(o.id),c=r(o.title),p=r(o.horizon),m=r(o.status),u=r(o.created_at),_=r(o.updated_at);return!l||!c||!p||!m||!u||!_?null:{id:l,horizon:p,title:c,metric:r(o.metric)??null,target_value:r(o.target_value)??null,due_date:r(o.due_date)??null,priority:d(o.priority)??3,status:m,parent_goal_id:r(o.parent_goal_id)??null,last_review_note:r(o.last_review_note)??null,last_review_at:r(o.last_review_at)??null,created_at:u,updated_at:_}}).filter(o=>o!==null);const t=new Map,n=Array.isArray((s=e.mdal)==null?void 0:s.loops)?e.mdal.loops:[];for(const o of n){const l=Ju(o);l&&t.set(l.loop_id,l)}Or.value=t,Ut.value=typeof((a=e.mdal)==null?void 0:a.error)=="string"?e.mdal.error:null,Ki.value=Ut.value?"error":t.size===0?"idle":"ready"}async function Gr(){try{const e=await Zc(),t=Ur(e.status,e.generated_at);t&&(ne.value=Hr(ne.value,t))}catch(e){console.error("Dashboard shell fetch error:",e)}}async function yt(){var e;try{const t=await ed(),n=Ur(t.status,t.generated_at),s=(e=ne.value)==null?void 0:e.room;n&&(ne.value=Hr(ne.value,n));const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Ue.value=(Array.isArray(t.agents)?t.agents:[]).map(Nu).filter(l=>l!==null),Qe.value=(Array.isArray(t.tasks)?t.tasks:[]).map(zu).filter(l=>l!==null);const o=(Array.isArray(t.messages)?t.messages:[]).map(Mu).filter(l=>l!==null);gi.value=a?o:Fu(gi.value,o),lt.value=Bu(t.keepers,n??ne.value),Lr.value=Eu(t.summary),wr.value=(Array.isArray(t.execution_queue)?t.execution_queue:Array.isArray(t.priority_queue)?t.priority_queue:[]).map(ju).filter(l=>l!==null),Nr.value=(Array.isArray(t.session_briefs)?t.session_briefs:[]).map(Du).filter(l=>l!==null),zr.value=(Array.isArray(t.operation_briefs)?t.operation_briefs:[]).map(Ou).filter(l=>l!==null),Mr.value=(Array.isArray(t.worker_support_briefs)?t.worker_support_briefs:Array.isArray(t.worker_briefs)?t.worker_briefs:[]).map(Co).filter(l=>l!==null),Er.value=(Array.isArray(t.continuity_briefs)?t.continuity_briefs:[]).map(qu).filter(l=>l!==null),jr.value=(Array.isArray(t.offline_worker_briefs)?t.offline_worker_briefs:[]).map(Co).filter(l=>l!==null),Su.value=null,qr.value=new Date().toISOString()}catch(t){console.error("Dashboard execution fetch error:",t)}}async function Ze(){Rn.value=!0;try{const e=await td(In.value,{excludeSystem:ht.value});Sa.value=e.posts??[],yi.value=new Date().toISOString()}catch(e){console.error("Board fetch error:",e)}finally{Rn.value=!1}}async function et(){var e;hi.value=!0;try{const t=Fe.value||((e=ne.value)==null?void 0:e.room)||"default";Fe.value||(Fe.value=t);const n=await Fd(t);Dr.value=n}catch(t){console.error("TRPG fetch error:",t)}finally{hi.value=!1}}async function Hi(){fn.value=!0,$n.value=!0;try{const e=await ld();Qu(e),Au.value=new Date().toISOString(),Cu.value=new Date().toISOString()}catch(e){console.error("Planning fetch error:",e),Ki.value="error",Ut.value=e instanceof Error?e.message:String(e)}finally{fn.value=!1,$n.value=!1}}async function Jr(){return Hi()}let Cs=null;function Xu(e){Cs=e}let Ts=null;function Zu(e){Ts=e}let Is=null;function ep(e){Is=e}const bt={};let za=null;function _t(e,t,n=500){bt[e]&&clearTimeout(bt[e]),bt[e]=setTimeout(()=>{t(),delete bt[e]},n)}function tp(){const e=mr.subscribe(t=>{if(t){if(t.type==="keeper_heartbeat"&&t.name){const n=new Map(fi.value);n.set(t.name,t.ts_unix?t.ts_unix*1e3:Date.now()),fi.value=n;return}(t.type==="agent_joined"||t.type==="agent_left")&&_t("execution",yt),Lu(t.type)&&(za||(za=setTimeout(()=>{Jn(),Ts==null||Ts(),Is==null||Is(),za=null},500))),(t.type.startsWith("task_")||t.type.startsWith("masc/task_"))&&_t("execution",yt),t.type==="broadcast"&&_t("execution",yt),(t.type==="keeper_handoff"||t.type==="keeper_compaction"||t.type==="keeper_guardrail")&&_t("execution",yt),(t.type==="board_post"||t.type==="masc/board_post"||t.type==="board_comment"||t.type==="masc/board_comment")&&_t("board",Ze),t.type.startsWith("decision_")&&_t("council",()=>Cs==null?void 0:Cs()),(t.type==="mdal_started"||t.type==="mdal_iteration"||t.type==="mdal_completed"||t.type==="mdal_stopped")&&_t("mdal",Jr,350)}});return()=>{e();for(const t of Object.keys(bt))clearTimeout(bt[t]),delete bt[t]}}let hn=null;function np(){hn||(hn=setInterval(()=>{st.value,Jn()},1e4))}function sp(){hn&&(clearInterval(hn),hn=null)}function ap({metric:e}){return i`
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
  `}function ip({panel:e}){return i`
    <div class="semantic-body">
      <div class="semantic-grid">
        <span>Purpose</span><span>${e.purpose}</span>
        <span>Solves</span><span>${e.problem_solved}</span>
        <span>When</span><span>${e.when_active}</span>
        <span>Agent Role</span><span>${e.agent_role}</span>
        <span>Ecosystem</span><span>${e.ecosystem_function}</span>
      </div>
      ${e.related_tools.length>0?i`<div class="semantic-tag-row">
            ${e.related_tools.map(t=>i`<span class="semantic-tag">${t}</span>`)}
          </div>`:null}
      ${e.metrics.length>0?i`<div class="semantic-metric-list">
            ${e.metrics.map(t=>i`<${ap} key=${t.id} metric=${t} />`)}
          </div>`:null}
    </div>
  `}function q({panelId:e,compact:t=!1,label:n="Why"}){const s=Yu(e);return s?i`
    <details class="semantic-inline ${t?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${ip} panel=${s} />
    </details>
  `:Fs.value?i`<span class="semantic-inline-state">Loading semantics…</span>`:null}function be({surfaceId:e,compact:t=!1}){const n=Vu(e);return n?i`
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
      ${n.panels.length>0?i`<div class="semantic-tag-row">
            ${n.panels.map(s=>i`<span class="semantic-tag">${s.title}</span>`)}
          </div>`:null}
    </section>
  `:Fs.value?i`<div class="semantic-surface-card ${t?"compact":""}">Loading semantics…</div>`:Ks.value?i`<div class="semantic-surface-card ${t?"compact":""}">${Ks.value}</div>`:null}function T({title:e,class:t,semanticId:n,testId:s,children:a}){return i`
    <div class="card ${t??""}" data-testid=${s}>
      ${e?i`
            <div class="card-title-row">
              <div class="card-title">${e}</div>
              ${n?i`<${q} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}const Vn=g(null),bi=g(!1),Bs=g(null),Vr=g(null),Mt=g(!1),$t=g(null),ki=g(null),Rs=g(!1),Ps=g(null);let Ht=null;function Ro(){Ht!==null&&(window.clearTimeout(Ht),Ht=null)}function op(e=1500){Ht===null&&(Ht=window.setTimeout(()=>{Ht=null,Us(!1)},e))}function E(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function y(e){return typeof e=="string"&&e.trim()!==""?e:void 0}function D(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function Wt(e){return typeof e=="boolean"?e:void 0}function U(e,t=[]){if(Array.isArray(e))return e;if(!E(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function rn(e){if(!E(e))return null;const t=y(e.kind),n=y(e.summary),s=y(e.target_type);return!t||!n||!s?null:{kind:t,severity:y(e.severity)??"warn",summary:n,target_type:s,target_id:y(e.target_id)??null,actor:y(e.actor)??null,evidence:e.evidence}}function Tt(e){if(!E(e))return null;const t=y(e.action_type),n=y(e.target_type),s=y(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:y(e.target_id)??null,severity:y(e.severity)??"warn",reason:s,confirm_required:Wt(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function rp(e){if(!E(e))return null;const t=y(e.session_id);return t?{session_id:t,goal:y(e.goal),status:y(e.status),health:y(e.health),scale_profile:y(e.scale_profile),control_profile:y(e.control_profile),planned_worker_count:D(e.planned_worker_count),active_agent_count:D(e.active_agent_count),last_turn_age_sec:D(e.last_turn_age_sec)??null,attention_count:D(e.attention_count),recommended_action_count:D(e.recommended_action_count),top_attention:rn(e.top_attention),top_recommendation:Tt(e.top_recommendation)}:null}function lp(e){if(!E(e))return null;const t=y(e.session_id);if(!t)return null;const n=E(e.status)?e.status:e,s=E(n.summary)?n.summary:void 0;return{session_id:t,status:y(e.status)??y(s==null?void 0:s.status)??(E(n.session)?y(n.session.status):void 0),progress_pct:D(e.progress_pct)??D(s==null?void 0:s.progress_pct),elapsed_sec:D(e.elapsed_sec)??D(s==null?void 0:s.elapsed_sec),remaining_sec:D(e.remaining_sec)??D(s==null?void 0:s.remaining_sec),done_delta_total:D(e.done_delta_total)??D(s==null?void 0:s.done_delta_total),summary:E(e.summary)?e.summary:s,team_health:E(e.team_health)?e.team_health:E(n.team_health)?n.team_health:void 0,communication_metrics:E(e.communication_metrics)?e.communication_metrics:E(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:E(e.orchestration_state)?e.orchestration_state:E(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:E(e.cascade_metrics)?e.cascade_metrics:E(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:E(e.report_paths)?Object.fromEntries(Object.entries(e.report_paths).map(([a,o])=>{const l=y(o);return l?[a,l]:null}).filter(a=>a!==null)):E(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const l=y(o);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:E(e.session)?e.session:E(n.session)?n.session:void 0,recent_events:U(e.recent_events,["events"]).filter(E)}}function cp(e){if(!E(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name),status:y(e.status),autonomy_level:y(e.autonomy_level),context_ratio:D(e.context_ratio),generation:D(e.generation),active_goal_ids:U(e.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:y(e.last_autonomous_action_at)??null,last_turn_ago_s:D(e.last_turn_ago_s),model:y(e.model)}:null}function dp(e){if(!E(e))return null;const t=y(e.confirm_token)??y(e.token);return t?{confirm_token:t,actor:y(e.actor),action_type:y(e.action_type),target_type:y(e.target_type),target_id:y(e.target_id)??null,delegated_tool:y(e.delegated_tool),created_at:y(e.created_at),preview:e.preview}:null}function up(e){if(!E(e))return null;const t=y(e.action_type),n=y(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:y(e.description),confirm_required:Wt(e.confirm_required)}}function pp(e){const t=E(e)?e:{};return{room_health:y(t.room_health),cluster:y(t.cluster),project:y(t.project),current_room:y(t.current_room)??null,paused:Wt(t.paused),tempo_interval_s:D(t.tempo_interval_s),active_agents:D(t.active_agents),keeper_pressure:D(t.keeper_pressure),active_operations:D(t.active_operations),pending_approvals:D(t.pending_approvals),incident_count:D(t.incident_count),recommended_action_count:D(t.recommended_action_count),top_attention:rn(t.top_attention),top_action:Tt(t.top_action)}}function mp(e){const t=E(e)?e:{},n=E(t.swarm_overview)?t.swarm_overview:{};return{health:y(t.health),active_operations:D(t.active_operations),pending_approvals:D(t.pending_approvals),swarm_overview:{active_lanes:D(n.active_lanes),moving_lanes:D(n.moving_lanes),stalled_lanes:D(n.stalled_lanes),projected_lanes:D(n.projected_lanes),last_movement_at:y(n.last_movement_at)??null},top_attention:rn(t.top_attention),top_action:Tt(t.top_action),session_cards:U(t.session_cards).map(rp).filter(s=>s!==null)}}function vp(e){const t=E(e)?e:{};return{sessions:U(t.sessions,["items"]).map(lp).filter(n=>n!==null),keepers:U(t.keepers,["items"]).map(cp).filter(n=>n!==null),pending_confirms:U(t.pending_confirms).map(dp).filter(n=>n!==null),available_actions:U(t.available_actions).map(up).filter(n=>n!==null)}}function _p(e){if(!E(e))return null;const t=y(e.id),n=y(e.kind),s=y(e.summary),a=y(e.target_type);return!t||!n||!s||!a?null:{id:t,kind:n,severity:y(e.severity)??"warn",summary:s,target_type:a,target_id:y(e.target_id)??null,top_action:Tt(e.top_action),related_session_ids:U(e.related_session_ids).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),related_agent_names:U(e.related_agent_names).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),evidence_preview:U(e.evidence_preview).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),last_seen_at:y(e.last_seen_at)??null}}function Yr(e){if(!E(e))return null;const t=y(e.session_id),n=y(e.goal);return!t||!n?null:{session_id:t,goal:n,room:y(e.room)??null,status:y(e.status),health:y(e.health),member_names:U(e.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:y(e.started_at)??null,elapsed_sec:D(e.elapsed_sec)??null,operation_id:y(e.operation_id)??null,blocker_summary:y(e.blocker_summary)??null,last_event_at:y(e.last_event_at)??null,last_event_summary:y(e.last_event_summary)??null,communication_summary:y(e.communication_summary)??null,active_count:D(e.active_count),required_count:D(e.required_count),related_attention_count:D(e.related_attention_count)??0,top_attention:rn(e.top_attention),top_recommendation:Tt(e.top_recommendation)}}function Qr(e){if(!E(e))return null;const t=y(e.agent_name);return t?{agent_name:t,status:y(e.status),current_work:y(e.current_work)??null,recent_input_preview:y(e.recent_input_preview)??null,recent_output_preview:y(e.recent_output_preview)??null,recent_tool_names:U(e.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_activity_at:y(e.last_activity_at)??null}:null}function Xr(e){if(!E(e))return null;const t=y(e.operation_id);return t?{operation_id:t,status:y(e.status),stage:y(e.stage)??null,detachment_status:y(e.detachment_status)??null,objective:y(e.objective)??null,updated_at:y(e.updated_at)??null}:null}function Zr(e){if(!E(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name)??null,status:y(e.status),generation:D(e.generation),context_ratio:D(e.context_ratio)??null,last_turn_ago_s:D(e.last_turn_ago_s)??null,current_work:y(e.current_work)??null}:null}function el(e){const t=Yr(e);return t?{...t,member_previews:U(E(e)?e.member_previews:void 0).map(Qr).filter(n=>n!==null),operation_badges:U(E(e)?e.operation_badges:void 0).map(Xr).filter(n=>n!==null),keeper_refs:U(E(e)?e.keeper_refs:void 0).map(Zr).filter(n=>n!==null)}:null}function gp(e){if(!E(e))return null;const t=y(e.agent_name);return t?{agent_name:t,status:y(e.status),where:y(e.where)??null,with_whom:U(e.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:y(e.current_work)??null,related_session_id:y(e.related_session_id)??null,related_attention_count:D(e.related_attention_count)??0,last_activity_at:y(e.last_activity_at)??null,recent_output_preview:y(e.recent_output_preview)??null,recent_input_preview:y(e.recent_input_preview)??null,recent_event:y(e.recent_event)??null,recent_tool_names:U(e.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),allowed_tool_names:U(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:U(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:D(e.latest_tool_call_count)??null,tool_audit_source:y(e.tool_audit_source)??null,tool_audit_at:y(e.tool_audit_at)??null}:null}function fp(e){if(!E(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name)??null,status:y(e.status),generation:D(e.generation),context_ratio:D(e.context_ratio)??null,last_turn_ago_s:D(e.last_turn_ago_s)??null,current_work:y(e.current_work)??null,last_autonomous_action_at:y(e.last_autonomous_action_at)??null,allowed_tool_names:U(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:U(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:D(e.latest_tool_call_count)??null,tool_audit_source:y(e.tool_audit_source)??null,tool_audit_at:y(e.tool_audit_at)??null}:null}function $p(e){if(!E(e))return null;const t=y(e.id),n=y(e.signal_type),s=y(e.summary),a=y(e.target_type);return!t||!n||!s||!a?null:{id:t,signal_type:n==="action"?"action":"attention",severity:y(e.severity)??"warn",summary:s,target_type:a,target_id:y(e.target_id)??null,attention:rn(e.attention),action:Tt(e.action)}}function hp(e){const t=E(e)?e:{},n=U(t.session_briefs).map(Yr).filter(a=>a!==null),s=U(t.sessions).map(el).filter(a=>a!==null);return{generated_at:y(t.generated_at),summary:pp(t.summary),incidents:U(t.incidents).map(rn).filter(a=>a!==null),recommended_actions:U(t.recommended_actions).map(Tt).filter(a=>a!==null),command_focus:mp(t.command_focus),operator_targets:vp(t.operator_targets),attention_queue:U(t.attention_queue).map(_p).filter(a=>a!==null),sessions:s.length>0?s:n.map(a=>({...a,member_previews:[],operation_badges:[],keeper_refs:[]})),session_briefs:n,agent_briefs:U(t.agent_briefs).map(gp).filter(a=>a!==null),keeper_briefs:U(t.keeper_briefs).map(fp).filter(a=>a!==null),internal_signals:U(t.internal_signals).map($p).filter(a=>a!==null)}}function yp(e){if(!E(e))return null;const t=y(e.id),n=y(e.summary);return!t||!n?null:{id:t,timestamp:y(e.timestamp)??null,event_type:y(e.event_type),actor:y(e.actor)??null,summary:n}}function bp(e){const t=E(e)?e:{};return{generated_at:y(t.generated_at),session_id:y(t.session_id)??"",session:el(t.session),timeline:U(t.timeline).map(yp).filter(n=>n!==null),participants:U(t.participants).map(Qr).filter(n=>n!==null),operations:U(t.operations).map(Xr).filter(n=>n!==null),keepers:U(t.keepers).map(Zr).filter(n=>n!==null),error:y(t.error)??null}}function kp(e){if(!E(e))return null;const t=y(e.id),n=y(e.label),s=y(e.summary);if(!t||!n||!s)return null;const a=y(e.status)??"unclear";return{id:t,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:y(e.signal_class)==="metadata_gap"||y(e.signal_class)==="mixed"||y(e.signal_class)==="operational_risk"?y(e.signal_class):void 0,evidence_quality:y(e.evidence_quality)==="strong"||y(e.evidence_quality)==="partial"||y(e.evidence_quality)==="missing"?y(e.evidence_quality):void 0,evidence:U(e.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function xp(e){if(!E(e))return null;const t=y(e.kind),n=y(e.summary),s=y(e.scope_type),a=y(e.severity);return!t||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:t,summary:n,scope_type:s,scope_id:y(e.scope_id)??null,severity:a}}function Sp(e){const t=E(e)?e:{},n=E(t.basis)?t.basis:{},s=y(t.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:y(t.generated_at),cached:Wt(t.cached),stale:Wt(t.stale),refreshing:Wt(t.refreshing),status:a,summary:y(t.summary)??null,model:y(t.model)??null,ttl_sec:D(t.ttl_sec),criteria:U(t.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:y(n.current_room)??null,crew_count:D(n.crew_count),agent_count:D(n.agent_count),keeper_count:D(n.keeper_count)},metadata_gap_count:D(t.metadata_gap_count),metadata_gaps:U(t.metadata_gaps).map(xp).filter(o=>o!==null),sections:U(t.sections).map(kp).filter(o=>o!==null),error:y(t.error)??null,last_error:y(t.last_error)??null}}async function tl(){bi.value=!0,Bs.value=null;try{const e=await ad();Vn.value=hp(e)}catch(e){Bs.value=e instanceof Error?e.message:"Failed to load mission snapshot"}finally{bi.value=!1}}async function Ap(e){if(!e){ki.value=null,Ps.value=null,Rs.value=!1;return}Rs.value=!0,Ps.value=null;try{const t=await id(e);ki.value=bp(t)}catch(t){Ps.value=t instanceof Error?t.message:"Failed to load session detail"}finally{Rs.value=!1}}async function Us(e=!1){Mt.value=!0,$t.value=null;try{const t=await od(e),n=Sp(t);Vr.value=n,n.refreshing||n.status==="pending"?op():Ro()}catch(t){$t.value=t instanceof Error?t.message:"Failed to load mission briefing",Ro()}finally{Mt.value=!1}}const Hs="masc_dashboard_workflow_context",Cp=900*1e3;function fe(e){return typeof e=="string"&&e.trim()!==""?e.trim():null}function We(e){const t=fe(e);return t||(typeof e=="number"&&Number.isFinite(e)?String(e):null)}function nl(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function xi(e){return v(e)?e:null}function Tp(e){if(!e)return null;try{return JSON.stringify(e)}catch{return null}}function Ip(e){if(!e)return null;try{const t=JSON.parse(e);if(!v(t))return null;const n=fe(t.id),s=fe(t.source_surface),a=fe(t.source_label),o=fe(t.summary),l=fe(t.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!o||!l?null:{id:n,source_surface:s,source_label:a,action_type:fe(t.action_type),target_type:fe(t.target_type),target_id:fe(t.target_id),focus_kind:fe(t.focus_kind),operation_id:fe(t.operation_id),command_surface:fe(t.command_surface),summary:o,payload_preview:fe(t.payload_preview),suggested_payload:xi(t.suggested_payload),preview:t.preview??null,evidence:t.evidence??null,created_at:l}}catch{return null}}function Wi(e){const t=Date.parse(e.created_at);return Number.isNaN(t)?!1:Date.now()-t<=Cp}function Rp(){const e=nl(),t=Ip((e==null?void 0:e.getItem(Hs))??null);return t?Wi(t)?t:(e==null||e.removeItem(Hs),null):null}const sl=g(Rp());function al(e){const t=e&&Wi(e)?e:null;sl.value=t;const n=nl();if(!n)return;if(!t){n.removeItem(Hs);return}const s=Tp(t);s&&n.setItem(Hs,s)}function Pp(e){if(!e)return null;const t=xi(e.suggested_payload);if(t)return t;if(v(e.preview)){const n=xi(e.preview.payload);if(n)return n}return null}function Lp(e){if(!e)return null;const t=We(e.message);if(t)return t;const n=We(e.task_title)??We(e.title),s=We(e.task_description)??We(e.description),a=We(e.reason),o=We(e.priority)??We(e.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function Gi(e,t,n,s,a,o,l,c){return[e,t,n??"action",s??"target",a??"room",o??"focus",l??"operation",c].join(":")}function ln(e,t,n="상황판 추천 액션"){const s=new Date().toISOString(),a=Pp(e),o=(e==null?void 0:e.target_type)??(t==null?void 0:t.target_type)??null,l=(e==null?void 0:e.target_id)??(t==null?void 0:t.target_id)??null,c=(t==null?void 0:t.kind)??(e==null?void 0:e.action_type)??null,p=(e==null?void 0:e.reason)??(t==null?void 0:t.summary)??n;return{id:Gi("mission",n,(e==null?void 0:e.action_type)??null,o,l,c,null,s),source_surface:"mission",source_label:n,action_type:(e==null?void 0:e.action_type)??null,target_type:o,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:p,payload_preview:Lp(a),suggested_payload:a,preview:(e==null?void 0:e.preview)??null,evidence:(t==null?void 0:t.evidence)??null,created_at:s}}function wp({targetType:e,targetId:t,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:o=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:Gi("execution",s,null,e,t,n,o,c),source_surface:"execution",source_label:s,action_type:null,target_type:e,target_id:t,focus_kind:n,operation_id:o,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function Np(e,t){return(t.source==="mission"||t.source==="execution")&&(t.action_type??null)===(e.action_type??null)&&(t.target_type??null)===(e.target_type??null)&&(t.target_id??null)===(e.target_id??null)&&(t.focus_kind??null)===(e.focus_kind??null)&&(t.operation_id??null)===(e.operation_id??null)}function Yn(e){const{params:t}=e;if(t.source!=="mission"&&t.source!=="execution")return null;const n=sl.value;if(n&&Wi(n)&&Np(n,t))return n;const s=new Date().toISOString(),a=t.source==="execution"?"execution":"mission";return{id:Gi(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",t.action_type??null,t.target_type??null,t.target_id??null,t.focus_kind??null,t.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:t.action_type??null,target_type:t.target_type??null,target_id:t.target_id??null,focus_kind:t.focus_kind??t.action_type??null,operation_id:t.operation_id??null,command_surface:t.surface??null,summary:a==="execution"?t.focus_kind?`${t.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":t.focus_kind?`${t.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function il(e){return{source:e.source_surface,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function ol(e){if(e.command_surface)return e.command_surface;const t=[e.focus_kind,e.summary,e.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"summary":t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")||t.includes("swarm")?"swarm":e.focus_kind==="operation"||e.target_type==="operation"?"operations":e.target_type==="room"?"summary":"swarm"}function rl(e){return{source:e.source_surface,surface:ol(e),...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function zp(e){return il(e)}function Mp(e){return rl(e)}function Ji(e){return e!=null&&e.target_type?e.target_id?`${e.target_type} · ${e.target_id}`:e.target_type:"대상 정보 없음"}function Aa(e){switch(e){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(e==null?void 0:e.trim())||"추천 액션"}}function Ep(e){switch(e){case"warroom":return"워룸";case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(e==null?void 0:e.trim())||"지휘"}}const qe=g(null),Ye=g(null);function Ie(e,t=120){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-1)}…`:n:null}function ve(e){return e==="bad"||e==="offline"||e==="critical"||e==="risk"?"bad":e==="warn"||e==="pending"||e==="degraded"||e==="interrupted"||e==="watch"?"warn":"ok"}function ze(e){if(!e)return"방금";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:n<86400?`${Math.round(n/3600)}h 전`:`${Math.round(n/86400)}d 전`}function jp(e){return typeof e!="number"||!Number.isFinite(e)||e<0?"n/a":e<60?`${Math.round(e)}s`:e<3600?`${Math.round(e/60)}m`:e<86400?`${Math.round(e/3600)}h`:`${Math.round(e/86400)}d`}function Dp(e){return e!=null&&e.confirm_required?"확인 후 실행":"즉시 실행"}function Op(e){return Ji(e?ln(e,null,"상황판 추천 액션"):null)}function Ca(e,t=ln()){al(t),de(e,e==="intervene"?zp(t):Mp(t))}function ll(e){Ca("intervene",ln(null,e,"상황판 incident"))}function cl(e){Ca("command",ln(null,e,"상황판 incident"))}function Vi(e,t,n="상황판 추천 액션"){Ca("intervene",ln(e,t,n))}function dl(e,t,n="상황판 추천 액션"){Ca("command",ln(e,t,n))}function Si(e,t){const n={source:"mission",target_type:"team_session",target_id:t,focus_kind:"team_session"};e==="command"&&(n.surface="swarm"),de(e,n)}function qp(e){return{kind:e.kind,severity:e.severity,summary:e.summary,target_type:e.target_type,target_id:e.target_id??null,actor:null,evidence:e.evidence_preview}}function Fp(e){var n,s;const t=lt.value.find(a=>a.name===e.name||a.agent_name===e.agent_name)??null;return{brief:e,keeper:t,currentWork:Ie(e.current_work,110)??Ie(t==null?void 0:t.skill_primary,110)??Ie(t==null?void 0:t.last_proactive_reason,110)??"명시된 keeper focus 없음",recentInput:Ie(t==null?void 0:t.recent_input_preview,120)??null,recentOutput:Ie(t==null?void 0:t.recent_output_preview,120)??Ie((n=t==null?void 0:t.diagnostic)==null?void 0:n.last_reply_preview,120)??Ie(t==null?void 0:t.last_proactive_preview,120)??null,recentEvent:Ie(t==null?void 0:t.last_proactive_reason,120)??Ie((s=t==null?void 0:t.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(t==null?void 0:t.recent_tool_names)??[]}}function Kp(){const e=Vn.value;if(!e)return new Map;const t=e.sessions.length>0?e.sessions:e.session_briefs;return new Map(t.map(n=>[n.session_id,n]))}function Bp(e){qe.value=qe.value===e?null:e,Ye.value=null}function ul(e){Ye.value=Ye.value===e?null:e,qe.value=null}function Up(){qe.value=null,Ye.value=null}function ct({status:e,label:t}){return i`
    <span class="status-badge ${e}">
      <span class="status-dot-inline ${e}"></span>
      ${t??e}
    </span>
  `}function pl(e){const t=Date.now(),n=typeof e=="number"?e<1e12?e*1e3:e:new Date(e).getTime(),s=Math.floor((t-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const o=Math.floor(a/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function G({timestamp:e}){const t=pl(e),n=typeof e=="string"?e:new Date(e<1e12?e*1e3:e).toISOString();return i`<span class="time-ago" title=${n}>${t}</span>`}let Hp=0;const kt=g([]);function z(e,t="success",n=4e3){const s=++Hp;kt.value=[...kt.value,{id:s,message:e,type:t}],setTimeout(()=>{kt.value=kt.value.filter(a=>a.id!==s)},n)}function Wp(e){kt.value=kt.value.filter(t=>t.id!==e)}function Gp(){const e=kt.value;return e.length===0?null:i`
    <div class="toast-container">
      ${e.map(t=>i`
        <div key=${t.id} class="toast ${t.type}" onClick=${()=>Wp(t.id)}>
          ${t.message}
        </div>
      `)}
    </div>
  `}const Jp="masc_dashboard_agent_name",cn=g(null),Ws=g(!1),Pn=g(""),Gs=g([]),Ln=g([]),Gt=g(""),yn=g(!1);function Ta(e){cn.value=e,Yi()}function Po(){cn.value=null,Pn.value="",Gs.value=[],Ln.value=[],Gt.value=""}function Vp(){const e=cn.value;return e?Ue.value.find(t=>t.name===e)??null:null}function ml(e){return e?Qe.value.filter(t=>t.assignee===e):[]}function vl(e){return e?lt.value.find(t=>t.agent_name===e||t.name===e)??null:null}function Yp(e){if(!e)return null;const t=Vn.value;return t?t.agent_briefs.find(n=>n.agent_name===e)??null:null}function Qp(e){if(!e)return[];const t=e.metrics_window;return(Array.isArray(t==null?void 0:t.top_tools)?t.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Xp(e){const t=vl(e);return t?t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]:[]}async function Yi(){const e=cn.value;if(e){Ws.value=!0,Pn.value="",Gs.value=[],Ln.value=[];try{const t=await Qd(80);Gs.value=t.filter(a=>a.includes(e)).slice(0,20);const n=ml(e).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await Xd(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const l=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));Ln.value=s}catch(t){Pn.value=t instanceof Error?t.message:"Failed to load agent detail"}finally{Ws.value=!1}}}async function Lo(){var s;const e=cn.value,t=Gt.value.trim();if(!e||!t)return;const n=((s=localStorage.getItem(Jp))==null?void 0:s.trim())||"dashboard";yn.value=!0;try{await Yd(n,`@${e} ${t}`),Gt.value="",z(`Mention sent to ${e}`,"success"),Yi()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";z(o,"error")}finally{yn.value=!1}}function Zp({task:e}){return i`
    <div class="agent-detail-task">
      <span class="pill">${e.id}</span>
      <span class="agent-detail-task-title">${e.title}</span>
      <${ct} status=${e.status} />
    </div>
  `}function em({row:e}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${e.taskId}</span>
      </div>
      <pre class="agent-history-pre">${e.text||"No task history yet"}</pre>
    </div>
  `}function tm(){var x,k,N,R,P,L,I;const e=cn.value;if(!e)return null;const t=Vp(),n=vl(e),s=Yp(e),a=ml(e),o=Gs.value,l=Xp(e),c=Qp(n),p=(s==null?void 0:s.allowed_tool_names)??[],m=(s==null?void 0:s.latest_tool_names)??[],u=s==null?void 0:s.latest_tool_call_count,_=s==null?void 0:s.tool_audit_source,f=s==null?void 0:s.tool_audit_at,$=(t==null?void 0:t.capabilities)??[],S=((x=ne.value)==null?void 0:x.room)??"default",h=((k=ne.value)==null?void 0:k.project)??"확인 없음",C=((N=ne.value)==null?void 0:N.cluster)??"확인 없음";return i`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${w=>{w.target.classList.contains("agent-detail-overlay")&&Po()}}
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
                        <${ct} status=${t.status} />
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
            ${(((R=t==null?void 0:t.traits)==null?void 0:R.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(P=t==null?void 0:t.traits)==null?void 0:P.map(w=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${w}</span>`)}
              </div>
            `:""}
            ${(((L=t==null?void 0:t.interests)==null?void 0:L.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(I=t==null?void 0:t.interests)==null?void 0:I.map(w=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${w}</span>`)}
              </div>
            `:""}
            ${$.length>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${$.map(w=>i`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${w}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${t?i`
                    ${t.current_task?i`<span>Task: ${t.current_task}</span>`:null}
                    ${t.last_seen?i`<span>Last seen: <${G} timestamp=${t.last_seen} /></span>`:null}
                    <span>Room: ${S}</span>
                    <span>Project: ${h}</span>
                    <span>Cluster: ${C}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Yi()}} disabled=${Ws.value}>
              ${Ws.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Po}>Close</button>
          </div>
        </div>

        ${Pn.value?i`<div class="council-error">${Pn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${T} title="Assigned Tasks">
            ${a.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${a.map(w=>i`<${Zp} key=${w.id} task=${w} />`)}</div>`}
          <//>

          <${T} title="Recent Activity">
            ${o.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${o.map((w,Q)=>i`<div key=${Q} class="agent-activity-line">${w}</div>`)}</div>`}
          <//>
        </div>

        <${T} title="Capabilities & Tool Audit">
          <div style="display:flex; flex-direction:column; gap:12px;">
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Capabilities</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${$.length>0?$.map(w=>i`<span class="pill">${w}</span>`):i`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Allowed tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${p.length>0?p.map(w=>i`<span class="pill">${w}</span>`):i`<span class="empty-state" style="font-size:12px;">No allowlist reported</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Observed tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${m.length>0?m.map(w=>i`<span class="pill">${w}</span>`):i`<span class="empty-state" style="font-size:12px;">No observed tool-use evidence</span>`}
              </div>
            </div>
            <div class="agent-detail-sub">
              <span>Tool calls: ${typeof u=="number"?u:"—"}</span>
              <span>Evidence source: ${_??"unreported"}</span>
              <span>
                Observed at:
                ${f?i` <${G} timestamp=${f} />`:" unreported"}
              </span>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Linked keeper recent tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${l.length>0?l.map(w=>i`<span class="pill">${w}</span>`):i`<span class="empty-state" style="font-size:12px;">No keeper tool telemetry</span>`}
              </div>
            </div>
            ${c.length>0?i`
                  <div>
                    <div style="font-size:12px; color:#888; margin-bottom:6px;">Keeper window top tools</div>
                    <div style="display:flex; flex-wrap:wrap; gap:6px;">
                      ${c.map(w=>i`<span class="pill">${w}</span>`)}
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

        <${T} title="Task History">
          ${Ln.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${Ln.value.map(w=>i`<${em} key=${w.taskId} row=${w} />`)}</div>`}
        <//>

        <${T} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Gt.value}
              onInput=${w=>{Gt.value=w.target.value}}
              onKeyDown=${w=>{w.key==="Enter"&&Lo()}}
              disabled=${yn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Lo()}}
              disabled=${yn.value||Gt.value.trim()===""}
            >
              ${yn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const _e=g(null),Qi=g(null),Me=g(null),wn=g(!1),at=g(null),Nn=g(!1),en=g(null),H=g(!1),Js=g([]);let nm=1;function sm(e){return v(e)?{id:r(e.id),seq:d(e.seq),from:r(e.from)??r(e.from_agent)??"system",content:r(e.content)??"",timestamp:r(e.timestamp)??new Date().toISOString(),type:r(e.type)}:null}function am(e){return v(e)?{room_id:r(e.room_id),current_room:r(e.current_room)??r(e.room),project:r(e.project),cluster:r(e.cluster),paused:j(e.paused),pause_reason:r(e.pause_reason)??null,paused_by:r(e.paused_by)??null,paused_at:r(e.paused_at)??null}:{}}function wo(e){if(!v(e))return;const t=Object.entries(e).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return t.length>0?Object.fromEntries(t):void 0}function _l(e){if(!v(e))return null;const t=r(e.kind),n=r(e.summary),s=r(e.target_type);return!t||!n||!s?null:{kind:t,severity:r(e.severity)??"warn",summary:n,target_type:s,target_id:r(e.target_id)??null,actor:r(e.actor)??null,evidence:e.evidence}}function bn(e){if(!v(e))return null;const t=r(e.action_type),n=r(e.target_type),s=r(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:r(e.target_id)??null,severity:r(e.severity)??"warn",reason:s,confirm_required:j(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function gl(e){return v(e)?{enabled:j(e.enabled),judge_online:j(e.judge_online),refreshing:j(e.refreshing),generated_at:r(e.generated_at)??null,expires_at:r(e.expires_at)??null,model_used:r(e.model_used)??null,keeper_name:r(e.keeper_name)??null,last_error:r(e.last_error)??null}:null}function Ma(e){return v(e)?{summary:r(e.summary)??null,confidence:d(e.confidence)??null,provenance:r(e.provenance)??null,authoritative:j(e.authoritative),surface:r(e.surface)??null,fresh_until:r(e.fresh_until)??null,keeper_name:r(e.keeper_name)??null,fallback_used:j(e.fallback_used),disagreement_with_truth:j(e.disagreement_with_truth)}:null}function im(e){return v(e)?{judgment_id:r(e.judgment_id)??void 0,surface:r(e.surface)??null,target_type:r(e.target_type)??null,target_id:r(e.target_id)??null,status:r(e.status)??null,summary:r(e.summary)??null,confidence:d(e.confidence)??null,generated_at:r(e.generated_at)??null,fresh_until:r(e.fresh_until)??null,keeper_name:r(e.keeper_name)??null,model_name:r(e.model_name)??null,runtime_name:r(e.runtime_name)??null,evidence_refs:W(e.evidence_refs),recommended_action:bn(e.recommended_action),supersedes:W(e.supersedes),fallback_used:j(e.fallback_used),disagreement_with_truth:j(e.disagreement_with_truth),provenance:r(e.provenance)??null}:null}function om(e){return v(e)?{actor:r(e.actor)??null,spawn_agent:r(e.spawn_agent)??null,spawn_role:r(e.spawn_role)??null,spawn_model:r(e.spawn_model)??null,worker_class:r(e.worker_class)??null,parent_actor:r(e.parent_actor)??null,capsule_mode:r(e.capsule_mode)??null,runtime_pool:r(e.runtime_pool)??null,lane_id:r(e.lane_id)??null,controller_level:r(e.controller_level)??null,control_domain:r(e.control_domain)??null,supervisor_actor:r(e.supervisor_actor)??null,model_tier:r(e.model_tier)??null,task_profile:r(e.task_profile)??null,risk_level:r(e.risk_level)??null,routing_confidence:d(e.routing_confidence)??null,routing_reason:r(e.routing_reason)??null,status:r(e.status)??"unknown",turn_count:d(e.turn_count)??0,empty_note_turn_count:d(e.empty_note_turn_count)??0,has_turn:j(e.has_turn)??!1,last_turn_ts_iso:r(e.last_turn_ts_iso)??null}:null}function rm(e){if(!v(e))return null;const t=r(e.session_id);return t?{session_id:t,goal:r(e.goal),status:r(e.status),health:r(e.health),scale_profile:r(e.scale_profile),control_profile:r(e.control_profile),planned_worker_count:d(e.planned_worker_count),active_agent_count:d(e.active_agent_count),last_turn_age_sec:d(e.last_turn_age_sec)??null,attention_count:d(e.attention_count),recommended_action_count:d(e.recommended_action_count),top_attention:_l(e.top_attention),top_recommendation:bn(e.top_recommendation)}:null}function fl(e){const t=v(e)?e:{};return{trace_id:r(t.trace_id),target_type:r(t.target_type)??"room",target_id:r(t.target_id)??null,health:r(t.health),judgment_owner:r(t.judgment_owner)??null,authoritative_judgment_available:j(t.authoritative_judgment_available),resident_judge_runtime:gl(t.resident_judge_runtime),judgment:im(t.judgment),active_guidance_layer:r(t.active_guidance_layer)??null,active_summary:Ma(t.active_summary),active_recommended_actions:pe(t.active_recommended_actions).map(bn).filter(n=>n!==null),active_recommendation_source:r(t.active_recommendation_source)??null,active_recommendation_summary:Ma(t.active_recommendation_summary),fallback_recommended_actions:pe(t.fallback_recommended_actions).map(bn).filter(n=>n!==null),recommendation_summary:Ma(t.recommendation_summary),swarm_status:v(t.swarm_status)?t.swarm_status:void 0,attention_items:pe(t.attention_items).map(_l).filter(n=>n!==null),recommended_actions:pe(t.recommended_actions).map(bn).filter(n=>n!==null),session_cards:pe(t.session_cards).map(rm).filter(n=>n!==null),worker_cards:pe(t.worker_cards).map(om).filter(n=>n!==null)}}function lm(e){if(!v(e))return null;const t=v(e.status)?e.status:void 0,n=v(e.summary)?e.summary:v(t==null?void 0:t.summary)?t.summary:void 0,s=v(e.session)?e.session:v(t==null?void 0:t.session)?t.session:void 0,a=r(e.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const o=wo(e.report_paths)??wo(t==null?void 0:t.report_paths),l=pe(e.recent_events,["events"]).filter(v);return{session_id:a,status:r(e.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:d(e.progress_pct)??d(n==null?void 0:n.progress_pct),elapsed_sec:d(e.elapsed_sec)??d(n==null?void 0:n.elapsed_sec),remaining_sec:d(e.remaining_sec)??d(n==null?void 0:n.remaining_sec),done_delta_total:d(e.done_delta_total)??d(n==null?void 0:n.done_delta_total),summary:n,team_health:v(e.team_health)?e.team_health:v(t==null?void 0:t.team_health)?t.team_health:void 0,communication_metrics:v(e.communication_metrics)?e.communication_metrics:v(t==null?void 0:t.communication_metrics)?t.communication_metrics:void 0,orchestration_state:v(e.orchestration_state)?e.orchestration_state:v(t==null?void 0:t.orchestration_state)?t.orchestration_state:void 0,cascade_metrics:v(e.cascade_metrics)?e.cascade_metrics:v(t==null?void 0:t.cascade_metrics)?t.cascade_metrics:void 0,report_paths:o,session:s,recent_events:l}}function No(e){if(!v(e))return null;const t=r(e.name);if(!t)return null;const n=v(e.context)?e.context:void 0;return{name:t,runtime_class:e.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:j(e.desired),resident_registered:j(e.resident_registered),agent_name:r(e.agent_name),status:r(e.status),autonomy_level:r(e.autonomy_level),context_ratio:d(e.context_ratio)??d(n==null?void 0:n.context_ratio),generation:d(e.generation),active_goal_ids:W(e.active_goal_ids),last_autonomous_action_at:r(e.last_autonomous_action_at)??null,last_turn_ago_s:d(e.last_turn_ago_s),model:r(e.model)??r(e.active_model)??r(e.primary_model)}}function cm(e){if(!v(e))return null;const t=r(e.confirm_token)??r(e.token);return t?{confirm_token:t,actor:r(e.actor),action_type:r(e.action_type),target_type:r(e.target_type),target_id:r(e.target_id)??null,delegated_tool:r(e.delegated_tool),created_at:r(e.created_at),preview:e.preview}:null}function $l(e){if(!v(e))return null;const t=r(e.action_type),n=r(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:r(e.description),confirm_required:j(e.confirm_required)}}function dm(e){return v(e)?{actor_filter:r(e.actor_filter)??null,filter_active:j(e.filter_active)??!1,visible_count:d(e.visible_count)??0,total_count:d(e.total_count)??0,hidden_count:d(e.hidden_count)??0,hidden_actors:W(e.hidden_actors),confirm_required_actions:pe(e.confirm_required_actions).map($l).filter(t=>t!==null)}:null}function um(e){const t=v(e)?e:{};return{room:am(t.room),sessions:pe(t.sessions,["items","sessions"]).map(lm).filter(n=>n!==null),keepers:pe(t.keepers,["items","keepers"]).map(No).filter(n=>n!==null),resident_judge_runtime:gl(t.resident_judge_runtime),persistent_agents:pe(t.persistent_agents,["items","persistent_agents"]).map(No).filter(n=>n!==null),recent_messages:pe(t.recent_messages,["messages"]).map(sm).filter(n=>n!==null),pending_confirms:pe(t.pending_confirms,["items","confirms"]).map(cm).filter(n=>n!==null),pending_confirm_summary:dm(t.pending_confirm_summary)??void 0,available_actions:pe(t.available_actions,["actions"]).map($l).filter(n=>n!==null)}}function us(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e)}catch{return String(e)}}function zo(e){return e.target_id?`${e.target_type}:${e.target_id}`:e.target_type}function Vs(e){Js.value=[{...e,id:nm++,at:new Date().toISOString()},...Js.value].slice(0,20)}function hl(e){return e.confirm_required?us(e.preview)||"Confirmation required":us(e.result)||us(e.executed_action)||us(e.delegated_tool_result)||e.status}async function ye(){wn.value=!0,at.value=null;try{const e=await dd();_e.value=um(e)}catch(e){at.value=e instanceof Error?e.message:"Failed to load operator snapshot"}finally{wn.value=!1}}async function Ct(){Nn.value=!0,en.value=null;try{const e=await hr({targetType:"room"});Qi.value=fl(e)}catch(e){en.value=e instanceof Error?e.message:"Failed to load operator digest"}finally{Nn.value=!1}}async function tn(e){if(!e){Me.value=null;return}Nn.value=!0,en.value=null;try{const t=await hr({targetType:"team_session",targetId:e,includeWorkers:!0});Me.value=fl(t)}catch(t){en.value=t instanceof Error?t.message:"Failed to load session digest"}finally{Nn.value=!1}}async function yl(e){var t;H.value=!0,at.value=null;try{const n=await ka(e);return Vs({actor:e.actor,action_type:e.action_type,target_label:zo(e),outcome:n.confirm_required?"preview":"executed",message:hl(n),delegated_tool:n.delegated_tool}),await ye(),await Ct(),(t=Me.value)!=null&&t.target_id&&await tn(Me.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw at.value=s,Vs({actor:e.actor,action_type:e.action_type,target_label:zo(e),outcome:"error",message:s}),n}finally{H.value=!1}}async function bl(e,t,n="confirm"){var s;H.value=!0,at.value=null;try{const a=await yr(e,t,n);return Vs({actor:e,action_type:n,target_label:t,outcome:"confirmed",message:hl(a),delegated_tool:a.delegated_tool}),await ye(),await Ct(),(s=Me.value)!=null&&s.target_id&&await tn(Me.value.target_id),a}catch(a){const o=a instanceof Error?a.message:"Operator confirmation failed";throw at.value=o,Vs({actor:e,action_type:"confirm",target_label:t,outcome:"error",message:o}),a}finally{H.value=!1}}ep(()=>{var e;ye(),Ct(),(e=Me.value)!=null&&e.target_id&&tn(Me.value.target_id)});function pm(e){switch(e){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function mm(e){switch(e){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function vm(e){switch(e.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return e.role}}function Mo(e){return e.delivery==="error"||e.delivery==="timeout"?"bad":e.delivery==="sending"?"warn":e.role==="assistant"?"assistant":e.role==="user"?"user":"warn"}function kl(e){if(!e)return null;const t=new Date(e);return Number.isNaN(t.getTime())?null:t.toLocaleTimeString()}function _m(e){return typeof e!="number"||!Number.isFinite(e)||e<=0?null:e<60?`${Math.round(e)}s`:`${Math.ceil(e/60)}m`}function xl(e){if(!e)return null;const t=Ke.value[e.name];return(t==null?void 0:t.diagnostic)??e.diagnostic??null}function gm({keeper:e,showRawStatus:t=!1}){if(te(()=>{e!=null&&e.name&&Pr(e.name)},[e==null?void 0:e.name]),!e)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Ke.value[e.name],s=xl(e),a=pi.value[e.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${pm(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${mm((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${kl(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${_m(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${t?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function fm({keeperName:e,placeholder:t}){const[n,s]=cr("");te(()=>{e&&Pr(e)},[e]);const a=ce.value[e]??[],o=mi.value[e]??!1,l=Be.value[e],c=async()=>{const p=n.trim();if(!(!e||!p)){s("");try{await $u(e,p)}catch(m){const u=m instanceof Error?m.message:`Failed to message ${e}`;z(u,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(p=>i`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Mo(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${Mo(p)}`}>${vm(p)}</span>
                  ${p.timestamp?i`<span class="keeper-conversation-time">${kl(p.timestamp)}</span>`:null}
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
  `}function $m({actor:e,keeper:t,onPokeLodge:n}){if(!t)return null;const s=xl(t),a=vi.value[t.name]??!1,o=_i.value[t.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{hu(t.name,e).catch(p=>{const m=p instanceof Error?p.message:`Failed to probe ${t.name}`;z(m,"error")})}}
        disabled=${a||!e.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{yu(t.name,e).catch(p=>{const m=p instanceof Error?p.message:`Failed to recover ${t.name}`;z(m,"error")})}}
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
  `}const Xi=g(null);function Sl(e){Xi.value=e,fu(e.name)}function Eo(){Xi.value=null}const wt=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function hm(e){if(!e)return 0;const t=wt.findIndex(n=>n.level===e);return t>=0?t:0}function ym({keeper:e}){const t=hm(e.autonomy_level),n=wt[t]??wt[0];if(!n)return null;const s=(t+1)/wt.length*100;return i`
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
            <strong><${G} timestamp=${e.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${e.active_goal_ids&&e.active_goal_ids.length>0?i`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${e.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Ls(e){return e?e>=1e6?`${(e/1e6).toFixed(1)}M`:e>=1e3?`${(e/1e3).toFixed(1)}K`:String(e):"—"}function bm(e){switch(e){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(e==null?void 0:e.trim())||"action"}}function km(e){return e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]}function xm(e){const t=e.metrics_window;return(Array.isArray(t==null?void 0:t.top_tools)?t.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Sm(e){const t=Vn.value;return t?t.keeper_briefs.find(n=>n.name===e.name||n.agent_name&&e.agent_name&&n.agent_name===e.agent_name)??null:null}function Am({keeper:e}){const t=e.metrics_series??[],n=t[t.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:e.generation??"-",hint:"Succession count"},{label:"Turns",value:e.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:e.context_ratio!=null?`${Math.round(e.context_ratio*100)}%`:"-",hint:e.context_ratio!=null&&e.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:e.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Ls(e.context_tokens)}</div>
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
  `}function Cm({keeper:e}){var u,_;const t=e.metrics_series??[];if(t.length<2){const f=(((u=e.context)==null?void 0:u.context_ratio)??0)*100,$=f>85?"#ef4444":f>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${f.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${f.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=t.length,l=t.map((f,$)=>{const S=a+$/(o-1)*(n-2*a),h=s-a-(f.context_ratio??0)*(s-2*a);return{x:S,y:h,p:f}}),c=l.map(({x:f,y:$})=>`${f.toFixed(1)},${$.toFixed(1)}`).join(" "),p=(((_=t[t.length-1])==null?void 0:_.context_ratio)??0)*100,m=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:f})=>f.is_handoff).map(({x:f})=>i`
          <line x1="${f.toFixed(1)}" y1="${a}" x2="${f.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${m}" stroke-width="1.5"/>
        ${l.filter(({p:f})=>f.is_compaction).map(({x:f,y:$})=>i`
          <circle cx="${f.toFixed(1)}" cy="${$.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}const Ea=g("");function Tm({keeper:e}){var a,o,l,c;const t=Ea.value.toLowerCase(),n=[{title:"Name",key:"name",value:e.name},{title:"Emoji",key:"emoji",value:e.emoji??"-"},{title:"Korean",key:"koreanName",value:e.koreanName??"-"},{title:"Model",key:"model",value:e.model??"-"},{title:"Status",key:"status",value:e.status},{title:"Primary",key:"primaryValue",value:e.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(e.activityLevel??"-")},{title:"Gen",key:"generation",value:String(e.generation??"-")},{title:"Turns",key:"turn_count",value:String(e.turn_count??"-")},{title:"Context",key:"context_ratio",value:e.context_ratio!=null?`${Math.round(e.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:e.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=e.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=e.interests)==null?void 0:o.join(", "))||"-"}],s=t?n.filter(p=>p.title.toLowerCase().includes(t)||p.key.includes(t)||p.value.toLowerCase().includes(t)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Ea.value}
        onInput=${p=>{Ea.value=p.target.value}}
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
      ${e.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Ls(e.context_tokens)}</span></div>`:""}
      ${e.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Ls(e.context_max)}</span></div>`:""}
      ${e.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${e.memory_recent_note}</span></div>`:""}
      ${e.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${e.k2k_count}</span></div>`:""}
      ${e.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${e.conversation_tail_count}</span></div>`:""}
      ${e.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${e.handoff_count_total}</span></div>`:""}
      ${e.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${e.compaction_count}</span></div>`:""}
      ${e.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Ls(e.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=e.context)==null?void 0:l.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${e.context.message_count}</span></div>`:""}
      ${((c=e.context)==null?void 0:c.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${e.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Im({stats:e}){const t=e.max_hp>0?Math.round(e.hp/e.max_hp*100):0,n=e.max_mp>0?Math.round(e.mp/e.max_mp*100):0;return i`
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
  `}function Rm({items:e}){return e.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${e.map((t,n)=>i`
        <div class="keeper-equipment-row">
          <span>${t}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Pm({rels:e}){const t=Object.entries(e);return t.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${t.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function jo({traits:e,label:t}){return e.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${t}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${e.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function ja(e){return e==null||Number.isNaN(e)?"-":`${Math.round(e*100)}%`}function Lm({keeper:e}){const t=e.metrics_window,n=[{label:"Model fallback",value:ja(typeof(t==null?void 0:t.model_fallback_rate)=="number"?t.model_fallback_rate:void 0)},{label:"Proactive fallback",value:ja(typeof(t==null?void 0:t.proactive_fallback_rate)=="number"?t.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:ja(typeof(t==null?void 0:t.memory_pass_rate)=="number"?t.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(t==null?void 0:t.handoff_count)=="number"?t.handoff_count:e.handoff_count_total??"-"},{label:"Compactions",value:typeof(t==null?void 0:t.compaction_events)=="number"?t.compaction_events:e.compaction_count??"-"},{label:"Saved tokens",value:typeof(t==null?void 0:t.compaction_saved_tokens)=="number"?t.compaction_saved_tokens:e.last_compaction_saved_tokens??"-"},{label:"K2K events",value:e.k2k_count??"-"},{label:"Conversation tail",value:e.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(t==null?void 0:t.tool_call_count)=="number"?t.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(t==null?void 0:t.proactive_preview_similarity_avg)=="number"?`${(t.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(t==null?void 0:t.memory_avg_score)=="number"?t.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(t==null?void 0:t.fallback_rate)=="number"?`${(t.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(s=>i`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function wm({keeper:e}){var h,C,x,k,N,R,P;const t=((h=_e.value)==null?void 0:h.room)??{},n=(((C=_e.value)==null?void 0:C.available_actions)??[]).filter(L=>L.target_type==="keeper"||L.target_type==="room").slice(0,8),s=km(e),a=xm(e),o=Sm(e),l=(o==null?void 0:o.allowed_tool_names)??[],c=(o==null?void 0:o.latest_tool_names)??[],p=o==null?void 0:o.latest_tool_call_count,m=o==null?void 0:o.tool_audit_source,u=o==null?void 0:o.tool_audit_at,_=((x=e.agent)==null?void 0:x.capabilities)??[],f=t.current_room??t.room_id??((k=ne.value)==null?void 0:k.room)??"default",$=t.project??((N=ne.value)==null?void 0:N.project)??"확인 없음",S=t.cluster??((R=ne.value)==null?void 0:R.cluster)??"확인 없음";return i`
    <div class="keeper-signal-list">
      <div class="keeper-signal-row">
        <span>Room</span>
        <strong>${f}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Project</span>
        <strong>${$}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Cluster</span>
        <strong>${S}</strong>
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
          ${l.length>0?l.map(L=>i`<span class="pill">${L}</span>`):i`<span style="font-size:12px; color:#888;">allowlist 미보고</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Observed tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${c.length>0?c.map(L=>i`<span class="pill">${L}</span>`):i`<span style="font-size:12px; color:#888;">observed tool-use evidence 없음</span>`}
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
        <strong>${u?i`<${G} timestamp=${u} />`:"unreported"}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Keeper recent tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${s.length>0?s.map(L=>i`<span class="pill">${L}</span>`):i`<span style="font-size:12px; color:#888;">도구 텔레메트리 없음</span>`}
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
          ${_.length>0?_.map(L=>i`<span class="pill">${L}</span>`):i`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(L=>i`<span class="pill">${bm(L.action_type)}</span>`):i`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function Al(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(t??n??"dashboard").trim()||"dashboard"}async function Nm(){try{const e=await ka({actor:Al(),action_type:"lodge_tick",target_type:"room",payload:{}}),t=Rr(e.result);await Jn(),t!=null&&t.skipped_reason?z(t.skipped_reason,"warning"):z(t?`Poke finished: ${t.acted}/${t.checked} acted`:"Poke finished",t&&t.acted>0?"success":"warning")}catch(e){const t=e instanceof Error?e.message:"Failed to run Lodge poke";z(t,"error")}}function zm({keeper:e}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${gm} keeper=${e} />
          <${$m}
            actor=${Al()}
            keeper=${e}
            onPokeLodge=${()=>{Nm()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${fm}
            keeperName=${e.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function Mm(){var t,n,s;const e=Xi.value;return e?i`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Eo()}}
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
            <${ct} status=${e.status} />
            ${e.model?i`<span class="pill">${e.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Eo()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Am} keeper=${e} />

        ${""}
        <${Cm} keeper=${e} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${T} title="Field Dictionary">
            <${Tm} keeper=${e} />
          <//>

          ${""}
          <${T} title="Profile">
            <${jo} traits=${e.traits??[]} label="Traits" />
            <${jo} traits=${e.interests??[]} label="Interests" />
            ${e.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${e.primaryValue}</span></div>`:null}
            ${e.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${e.skill_primary}</span>
                </div>`:null}
            ${e.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${e.skill_reason}</div>`:null}
            ${e.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${G} timestamp=${e.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${e.autonomy_level?i`
              <${T} title="Autonomy">
                <${ym} keeper=${e} />
              <//>
            `:null}

          ${""}
          ${e.trpg_stats?i`
              <${T} title="TRPG Stats">
                <${Im} stats=${e.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${e.inventory&&e.inventory.length>0?i`
              <${T} title="Equipment (${e.inventory.length})">
                <${Rm} items=${e.inventory} />
              <//>
            `:null}

          ${""}
          ${e.relationships&&Object.keys(e.relationships).length>0?i`
              <${T} title="Relationships (${Object.keys(e.relationships).length})">
                <${Pm} rels=${e.relationships} />
              <//>
            `:null}

          <${T} title="Runtime Signals">
            <${Lm} keeper=${e} />
          <//>

          <${T} title="Neighborhood & Tool Audit">
            <${wm} keeper=${e} />
          <//>

          <${T} title="Memory & Context">
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
        <${zm} keeper=${e} />
      </div>
    </div>
  `:null}function Em({cluster:e,project:t,room:n,generatedAt:s}){return i`
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
        <strong>${s?ze(s):"fresh"}</strong>
      </div>
    </div>
  `}function Pt({label:e,value:t,detail:n,tone:s}){return i`
    <article class="mission-stat-card ${ve(s)}">
      <span class="mission-stat-label">${e}</span>
      <strong class="mission-stat-value">${t}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function jm(){const e=Vr.value,t=ve((e==null?void 0:e.status)??($t.value?"bad":"warn")),n=!e||e.sections.length===0,s=(e==null?void 0:e.status)==="error"||(e==null?void 0:e.status)==="unavailable"&&!(e!=null&&e.cached);return i`
    <${T} title="LLM 판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>heuristic 대신 별도 판단 계층</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${t}">
          ${(e==null?void 0:e.status)??($t.value?"error":"loading")}
        </span>
        ${e!=null&&e.model?i`<span class="command-chip">${e.model}</span>`:null}
        ${e!=null&&e.generated_at?i`<span class="command-chip">${ze(e.generated_at)}</span>`:null}
        ${e!=null&&e.cached?i`<span class="command-chip">cached</span>`:null}
        ${e!=null&&e.stale?i`<span class="command-chip warn">stale</span>`:null}
        ${e!=null&&e.refreshing?i`<span class="command-chip warn">refreshing</span>`:null}
      </div>

      ${$t.value?i`<div class="empty-state error">${$t.value}</div>`:null}
      ${e!=null&&e.error?i`<div class="empty-state error">${e.error}</div>`:null}
      ${e!=null&&e.summary?i`<div class="mission-inline-note">${e.summary}</div>`:null}
      ${e!=null&&e.last_error&&!e.error?i`<div class="mission-inline-note">최근 refresh 실패: ${e.last_error}</div>`:null}

      ${e&&e.sections.length>0?i`
            <div class="mission-briefing-grid">
              ${e.sections.slice(0,3).map(a=>i`
                <article class="mission-briefing-section ${ve(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${ve(a.status)}">${a.status}</span>
                      ${a.signal_class==="metadata_gap"?i`<span class="command-chip">metadata gap</span>`:a.signal_class==="mixed"?i`<span class="command-chip warn">mixed</span>`:null}
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
          `:!Mt.value&&!$t.value&&n?i`
                <div class="empty-state">
                  ${(e==null?void 0:e.status)==="pending"?"최신 스냅샷으로 브리핑을 생성 중입니다. 마지막 성공 결과가 생기면 자동으로 다시 읽습니다.":"판단 레이어 결과가 아직 없습니다."}
                </div>
              `:null}

      ${e&&e.metadata_gaps.length>0?i`
            <details class="mission-card-disclosure compact mission-briefing-gaps">
              <summary>Observability Gaps (${e.metadata_gap_count??e.metadata_gaps.length})</summary>
              <div class="mission-list-stack">
                ${e.metadata_gaps.map(a=>i`
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
        <button class="control-btn ghost" onClick=${()=>{Us(s)}} disabled=${Mt.value}>
          ${Mt.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{Us(!0)}} disabled=${Mt.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function Dm({item:e,selected:t,sessionLookup:n}){const s=qp(e),a=e.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),o=e.top_action??null;return i`
    <article class="mission-attention-card ${ve((o==null?void 0:o.severity)??e.severity)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Bp(e.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${e.summary}</strong>
            <div class="mission-card-target">${e.kind}${e.target_id?` · ${e.target_id}`:""}</div>
          </div>
          <span class="command-chip ${ve((o==null?void 0:o.severity)??e.severity)}">${o?Dp(o):e.severity}</span>
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
            <strong>${e.last_seen_at?ze(e.last_seen_at):"n/a"}</strong>
            <small>${e.target_type}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${o?Aa(o.action_type):"판단 필요"}</strong>
            <small>${o?Op(o):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${o?i`<div class="mission-inline-note">${o.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?i`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>i`
                  <button class="mission-link-row" onClick=${()=>ul(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${l.status??"unknown"} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:i`<div class="empty-state">직접 연결된 session이 아직 없습니다.</div>`}

        ${e.related_agent_names.length>0?i`
              <div class="mission-pill-row">
                ${e.related_agent_names.slice(0,8).map(l=>i`
                  <button class="mission-pill action" onClick=${()=>Ta(l)}>${l}</button>
                `)}
              </div>
            `:null}

        ${e.evidence_preview.length>0?i`
              <details class="mission-card-disclosure compact">
                <summary>evidence preview</summary>
                <div class="mission-evidence-list">
                  ${e.evidence_preview.map(l=>i`<span>${l}</span>`)}
                </div>
              </details>
            `:null}
      </details>

      <div class="mission-card-actions">
        ${o?i`
              <button class="control-btn ghost" onClick=${()=>Vi(o,s,"Mission attention")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>dl(o,s,"Mission attention")}>
                원인 보기
              </button>
            `:i`
              <button class="control-btn ghost" onClick=${()=>ll(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>cl(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function Om({brief:e,selected:t}){var o,l;const n=e.member_previews.slice(0,4),s=e.top_recommendation??null,a=e.top_attention??null;return i`
    <article class="mission-crew-card ${ve(((o=e.top_attention)==null?void 0:o.severity)??e.health??e.status)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>ul(e.session_id)}>
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
            <strong>${jp(e.elapsed_sec)}</strong>
            <small>${e.started_at?`${ze(e.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 흐름</span>
            <strong>${e.last_event_at?ze(e.last_event_at):"n/a"}</strong>
            <small>${e.communication_summary??"요약 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>커버리지</span>
            <strong>${e.active_count??0}/${e.required_count||1}</strong>
            <small>active / required</small>
          </div>
        </div>
      </button>

      ${e.blocker_summary?i`<div class="mission-inline-note">막힘 · ${e.blocker_summary}</div>`:null}

      <div class="mission-crew-event">
        <span>최근 사건</span>
        <strong>${e.last_event_summary??"최근 session event가 없습니다."}</strong>
        <small>${e.last_event_at?ze(e.last_event_at):"시각 없음"}</small>
      </div>

      ${e.operation_badges.length>0?i`
            <div class="mission-pill-row">
              ${e.operation_badges.slice(0,3).map(c=>i`
                <span class="mission-pill">
                  ${c.operation_id} · ${c.status??"unknown"}${c.stage?` · ${c.stage}`:""}
                </span>
              `)}
            </div>
          `:null}

      ${n.length>0?i`
            <div class="mission-member-preview-grid">
              ${n.map(c=>i`
                <button class="mission-member-preview" onClick=${()=>Ta(c.agent_name)}>
                  <strong>${c.agent_name}</strong>
                  <span>${c.current_work??"현재 작업 없음"}</span>
                  <small>${c.recent_output_preview??c.recent_input_preview??"최근 입출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>Si("intervene",e.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>Si("command",e.session_id)}>세션 원인 보기</button>
        ${s?i`<button class="control-btn ghost" onClick=${()=>Vi(s,a,"Mission session brief")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function qm({detail:e,loading:t,error:n}){if(t&&!e)return i`
      <${T} title="세션 상세" class="mission-list-card">
        <div class="loading-indicator">세션 상세 불러오는 중...</div>
      <//>
    `;if(n&&!e)return i`
      <${T} title="세션 상세" class="mission-list-card">
        <div class="empty-state error">${n}</div>
      <//>
    `;if(!(e!=null&&e.session))return null;const s=e.session;return i`
    <${T} title="세션 상세" class="mission-list-card" semanticId="mission.session_detail">
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
                      <span>${a.timestamp?ze(a.timestamp):"n/a"}</span>
                    </div>
                    <small>${a.actor?`${a.actor} · `:""}${a.event_type??"event"}</small>
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
                  <button class="mission-member-preview" onClick=${()=>Ta(a.agent_name)}>
                    <strong>${a.agent_name}</strong>
                    <span>${a.current_work??"현재 작업 없음"}</span>
                    <small>
                      ${a.recent_output_preview??a.recent_input_preview??"최근 입출력 없음"}
                      ${a.last_activity_at?` · ${ze(a.last_activity_at)}`:""}
                    </small>
                  </button>
                `):i`<div class="empty-state">세션 참여자 미리보기가 없습니다.</div>`}
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
            ${e.operations.length>0?e.operations.map(a=>i`
                  <button class="mission-link-row" onClick=${()=>Si("command",s.session_id)}>
                    <strong>${a.operation_id}</strong>
                    <span>${a.status??"unknown"}${a.stage?` · ${a.stage}`:""}</span>
                    <small>${a.detachment_status??a.objective??"detachment 정보 없음"}</small>
                  </button>
                `):i`<div class="empty-state">연결된 operation이 없습니다.</div>`}
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
                    <span>${a.status??"unknown"}${a.generation!=null?` · gen ${a.generation}`:""}</span>
                    <small>${a.current_work??"current work 없음"}</small>
                  </div>
                `):i`<div class="empty-state">직접 연결된 keeper는 없습니다.</div>`}
          </div>
        </div>
      </div>
    <//>
  `}function Fm({row:e}){var n,s,a,o,l,c,p,m,u,_;const t=[`gen ${e.brief.generation??((n=e.keeper)==null?void 0:n.generation)??0}`,e.brief.context_ratio!=null?`ctx ${Math.round(e.brief.context_ratio*100)}%`:((s=e.keeper)==null?void 0:s.context_ratio)!=null?`ctx ${Math.round(e.keeper.context_ratio*100)}%`:null,e.brief.last_turn_ago_s!=null?`last turn ${Math.round(e.brief.last_turn_ago_s)}s`:null].filter(f=>f!==null).join(" · ");return i`
    <article class="mission-activity-card ${ve(e.brief.status??((a=e.keeper)==null?void 0:a.status))}">
      <button class="mission-card-select" onClick=${()=>{e.keeper&&Sl(e.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((o=e.keeper)==null?void 0:o.emoji)??""}</span>
            <div>
              <strong>${e.brief.name}</strong>
              ${(l=e.keeper)!=null&&l.koreanName?i`<span>${e.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${ve(e.brief.status??((c=e.keeper)==null?void 0:c.status))}">${e.brief.status??((p=e.keeper)==null?void 0:p.status)??"unknown"}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 heartbeat · ${(m=e.keeper)!=null&&m.last_heartbeat?ze(e.keeper.last_heartbeat):"n/a"}</span>
          <span>${t||"continuity 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${e.currentWork}</strong>
          ${(u=e.keeper)!=null&&u.skill_reason?i`<small>판단 요약 · ${Ie(e.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>continuity detail</summary>
        <div class="mission-activity-foot">
          <span>agent · ${e.brief.agent_name??((_=e.keeper)==null?void 0:_.agent_name)??"n/a"}</span>
          ${e.recentEvent?i`<span>최근 일 · ${e.recentEvent}</span>`:null}
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
  `}function Km({item:e}){const t=e.action??null,n=e.attention??null;return i`
    <article class="mission-action-card ${ve(e.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${ve(e.severity)}">
          ${e.signal_type==="action"&&t?Aa(t.action_type):(n==null?void 0:n.kind)??"signal"}
        </span>
        <span class="mission-card-target">${e.target_type}${e.target_id?` · ${e.target_id}`:""}</span>
      </div>
      <p>${e.summary}</p>
      ${t?i`<div class="mission-action-preview">${t.reason}</div>`:null}
      <div class="mission-card-actions">
        ${t?i`
              <button class="control-btn ghost" onClick=${()=>Vi(t,n,"Mission internal signal")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>dl(t,n,"Mission internal signal")}>이 이슈의 원인 보기</button>
            `:n?i`
                <button class="control-btn ghost" onClick=${()=>ll(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>cl(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function Do(){var $,S,h,C;const e=Vn.value;if(bi.value&&!e)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(Bs.value&&!e)return i`<div class="empty-state error">${Bs.value}</div>`;if(!e)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;qe.value&&!e.attention_queue.some(x=>x.id===qe.value)&&(qe.value=null);const t=e.sessions;Ye.value&&!t.some(x=>x.session_id===Ye.value)&&(Ye.value=null);const n=e.attention_queue.find(x=>x.id===qe.value)??null,s=(n==null?void 0:n.related_session_ids.find(x=>t.some(k=>k.session_id===x)))??null,a=Ye.value??s??(($=t[0])==null?void 0:$.session_id)??null,o=Kp(),l=t.find(x=>x.session_id===a)??null,c=e.keeper_briefs.slice(0,6).map(Fp),p=e.attention_queue.filter(x=>x.related_session_ids.length>0).slice(0,6),m=e.internal_signals.slice(0,3),u=t.filter(x=>{var N;const k=((N=x.top_attention)==null?void 0:N.severity)??x.health??x.status;return ve(k)!=="ok"||!!x.blocker_summary}).length,_=new Set(t.flatMap(x=>x.member_names)).size,f=t.flatMap(x=>x.member_previews??[]).filter(x=>x.recent_output_preview).length+c.filter(x=>x.recentOutput).length;return te(()=>{Ap(a)},[a]),i`
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
          <span class="command-chip">${e.generated_at?ze(e.generated_at):"fresh"}</span>
        </div>
      </div>

      <${Em}
        cluster=${e.summary.cluster}
        project=${e.summary.project}
        room=${e.summary.current_room}
        generatedAt=${e.generated_at}
      />

      <${jm} />

      <div class="mission-stat-grid">
        <${Pt} label="활성 세션" value=${t.length} detail="지금 진행중인 협업 단위" tone=${((S=l==null?void 0:l.top_attention)==null?void 0:S.severity)??(l==null?void 0:l.health)??"ok"} />
        <${Pt} label="막힌 세션" value=${u} detail="주의가 필요한 흐름" tone=${u>0?"warn":"ok"} />
        <${Pt} label="참여자" value=${_} detail="현재 세션에 연결된 actor" tone=${_>0?"ok":"warn"} />
        <${Pt} label="Keeper watch" value=${c.length} detail="continuity lane 관찰 대상" tone=${((h=c[0])==null?void 0:h.brief.status)??"ok"} />
        <${Pt} label="최근 output" value=${f} detail="메인에서 바로 읽을 수 있는 출력 수" tone=${f>0?"ok":"warn"} />
        <${Pt} label="내부 신호" value=${m.length} detail="시스템 진단은 보조 lane" tone=${((C=m[0])==null?void 0:C.severity)??"ok"} />
      </div>

      ${a?i`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${(l==null?void 0:l.goal)??a}${n?` · ${n.summary}`:""}</span>
              <button class="control-btn ghost" onClick=${Up}>선택 해제</button>
            </div>
          `:null}

      <${T} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 operation을 먼저 봅니다.</p>
        </div>
        <div class="mission-list-stack">
          ${t.length>0?t.map(x=>i`<${Om} key=${x.session_id} brief=${x} selected=${a===x.session_id} />`):i`<div class="empty-state">지금 활성 세션이 없습니다.</div>`}
        </div>
      <//>

      <${qm}
        detail=${ki.value}
        loading=${Rs.value}
        error=${Ps.value}
      />

      <div class="mission-human-grid">
        <${T} title="Attention Queue" class="mission-list-card" semanticId="mission.attention_queue">
          <div class="mission-section-head">
            <h3>어느 세션을 먼저 봐야 하나</h3>
            <p>문제와 경고는 세션에 연결된 것만 먼저 보여주고, 원인 분석은 선택된 세션에서 이어서 봅니다.</p>
          </div>
          <div class="mission-lane-stack">
            ${p.length>0?p.map(x=>i`<${Dm} key=${x.id} item=${x} selected=${qe.value===x.id} sessionLookup=${o} />`):i`<div class="empty-state">지금 session-level attention queue가 비어 있습니다.</div>`}
          </div>
        <//>

        <${T} title="Internal Signals" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>시스템 진단</h3>
            <p>artifact scope drift 같은 내부 신호는 메인 판단을 방해하지 않도록 접어둔 보조 lane으로만 유지합니다.</p>
          </div>
          <details class="mission-card-disclosure">
            <summary>내부 신호 ${m.length}</summary>
            <div class="mission-list-stack">
              ${m.length>0?m.map(x=>i`<${Km} key=${x.id} item=${x} />`):i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
            </div>
          </details>
        <//>
      </div>

      <${T} title="Keeper Continuity" class="mission-list-card" semanticId="mission.keeper_activity">
        <div class="mission-section-head">
          <h3>continuity lane</h3>
          <p>keeper는 세션과 별개로 보고, continuity 판단에 필요한 정보만 먼저 보여줍니다.</p>
        </div>
        <div class="mission-activity-list">
          ${c.length>0?c.map(x=>i`<${Fm} key=${x.brief.name} row=${x} />`):i`<div class="empty-state">지금 보이는 keeper가 없습니다.</div>`}
        </div>
        <div class="mission-card-actions">
          <button class="control-btn ghost" onClick=${()=>de("execution")}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${()=>de("command")}>지휘 진단면 보기</button>
        </div>
      <//>
    </section>
  `}const Cl=g(null),Ai=g(!1),Et=g(null);async function Tl(e,t){Ai.value=!0,Et.value=null;try{Cl.value=await rd(e,t)}catch(n){Et.value=n instanceof Error?n.message:String(n)}finally{Ai.value=!1}}const Bm="modulepreload",Um=function(e){return"/dashboard/"+e},Oo={},Hm=function(t,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(m){return Promise.all(m.map(u=>Promise.resolve(u).then(_=>({status:"fulfilled",value:_}),_=>({status:"rejected",reason:_}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),p=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(m=>{if(m=Um(m),m in Oo)return;Oo[m]=!0;const u=m.endsWith(".css"),_=u?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${_}`))return;const f=document.createElement("link");if(f.rel=u?"stylesheet":Bm,u||(f.as="script"),f.crossOrigin="",f.href=m,p&&f.setAttribute("nonce",p),document.head.appendChild(f),u)return new Promise(($,S)=>{f.addEventListener("load",$),f.addEventListener("error",()=>S(new Error(`Unable to preload CSS for ${m}`)))})}))}function o(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&o(c.reason);return t().catch(o)})},Zi=g(null),je=g(null),Ys=g(!1),Qs=g(!1),Xs=g(null),Zs=g(null),Ci=g(null),ea=g(null),Z=g("warroom"),Qn=g(null),Ti=g(!1),ta=g(null),It=g(null),na=g(!1),sa=g(null),Xn=g(null),Ii=g(!1),aa=g(null),zn=g(null),ia=g(!1),Mn=g(null),Jt=g(null);let _n=null;function eo(e){return e!=="summary"&&e!=="swarm"&&e!=="warroom"}function Il(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,o)=>{e.has(o)||e.set(o,a)}),e}function Wm(){const t=Il().get("run_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function Gm(){const t=Il().get("operation_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function Jm(e){if(v(e))return{policy_class:r(e.policy_class),approval_class:r(e.approval_class),tool_allowlist:W(e.tool_allowlist),model_allowlist:W(e.model_allowlist),requires_human_for:W(e.requires_human_for),autonomy_level:r(e.autonomy_level),escalation_timeout_sec:d(e.escalation_timeout_sec),kill_switch:j(e.kill_switch),frozen:j(e.frozen)}}function Vm(e){if(v(e))return{headcount_cap:d(e.headcount_cap),active_operation_cap:d(e.active_operation_cap),max_cost_usd:d(e.max_cost_usd),max_tokens:d(e.max_tokens)}}function to(e){if(!v(e))return null;const t=r(e.unit_id),n=r(e.label),s=r(e.kind);return!t||!n||!s?null:{unit_id:t,label:n,kind:s,parent_unit_id:r(e.parent_unit_id)??null,leader_id:r(e.leader_id)??null,roster:W(e.roster),capability_profile:W(e.capability_profile),source:r(e.source),created_at:r(e.created_at),updated_at:r(e.updated_at),policy:Jm(e.policy),budget:Vm(e.budget)}}function Rl(e){if(!v(e))return null;const t=to(e.unit);return t?{unit:t,leader_status:r(e.leader_status),roster_total:d(e.roster_total),roster_live:d(e.roster_live),active_operation_count:d(e.active_operation_count),health:r(e.health),reasons:W(e.reasons),children:Array.isArray(e.children)?e.children.map(Rl).filter(n=>n!==null):[]}:null}function Ym(e){if(v(e))return{total_units:d(e.total_units),company_count:d(e.company_count),platoon_count:d(e.platoon_count),squad_count:d(e.squad_count),leaf_agent_unit_count:d(e.leaf_agent_unit_count),live_agent_count:d(e.live_agent_count),managed_unit_count:d(e.managed_unit_count),active_operation_count:d(e.active_operation_count)}}function Pl(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),source:r(t.source),summary:Ym(t.summary),units:Array.isArray(t.units)?t.units.map(Rl).filter(n=>n!==null):[]}}function Qm(e){if(!v(e))return null;const t=r(e.kind),n=r(e.status);return!t||!n?null:{kind:t,chain_id:r(e.chain_id)??null,goal:r(e.goal)??null,run_id:r(e.run_id)??null,status:n,viewer_path:r(e.viewer_path)??null,last_sync_at:r(e.last_sync_at)??null}}function Ia(e){if(!v(e))return null;const t=r(e.operation_id),n=r(e.objective),s=r(e.assigned_unit_id),a=r(e.trace_id),o=r(e.status);return!t||!n||!s||!a||!o?null:{operation_id:t,objective:n,assigned_unit_id:s,autonomy_level:r(e.autonomy_level),policy_class:r(e.policy_class),budget_class:r(e.budget_class),detachment_session_id:r(e.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(e.checkpoint_ref)??null,active_goal_ids:W(e.active_goal_ids),note:r(e.note)??null,created_by:r(e.created_by),source:r(e.source),status:o,chain:Qm(e.chain),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function Xm(e){if(!v(e))return null;const t=Ia(e.operation);return t?{operation:t,assigned_unit_label:r(e.assigned_unit_label)}:null}function mn(e){if(v(e))return{tone:r(e.tone),pending_ops:d(e.pending_ops),blocked_ops:d(e.blocked_ops),in_flight_ops:d(e.in_flight_ops),pipeline_stalls:d(e.pipeline_stalls),bus_traffic:d(e.bus_traffic),l1_hit_rate:d(e.l1_hit_rate),invalidation_count:d(e.invalidation_count),current_pending:d(e.current_pending),current_in_flight:d(e.current_in_flight),cdb_wakeups:d(e.cdb_wakeups),total_stolen:d(e.total_stolen),avg_best_score:d(e.avg_best_score),avg_candidate_count:d(e.avg_candidate_count),best_first_operations:d(e.best_first_operations),active_sessions:d(e.active_sessions),commit_rate:d(e.commit_rate),total_speculations:d(e.total_speculations)}}function Zm(e){if(!v(e))return;const t=v(e.pipeline)?e.pipeline:void 0,n=v(e.cache)?e.cache:void 0,s=v(e.ooo)?e.ooo:void 0,a=v(e.speculative)?e.speculative:void 0,o=v(e.search_fabric)?e.search_fabric:void 0,l=v(e.signals)?e.signals:void 0;return{pipeline:t?{total_ops:d(t.total_ops),completed_ops:d(t.completed_ops),stalled_cycles:d(t.stalled_cycles),hazards_detected:d(t.hazards_detected),forwarding_used:d(t.forwarding_used),pipeline_flushes:d(t.pipeline_flushes),ipc:d(t.ipc)}:void 0,cache:n?{total_reads:d(n.total_reads),total_writes:d(n.total_writes),l1_hit_rate:d(n.l1_hit_rate),invalidation_count:d(n.invalidation_count),writeback_count:d(n.writeback_count),bus_traffic:d(n.bus_traffic)}:void 0,ooo:s?{agent_count:d(s.agent_count),total_added:d(s.total_added),total_issued:d(s.total_issued),total_completed:d(s.total_completed),total_stolen:d(s.total_stolen),cdb_wakeups:d(s.cdb_wakeups),stall_cycles:d(s.stall_cycles),global_cdb_events:d(s.global_cdb_events),current_pending:d(s.current_pending),current_in_flight:d(s.current_in_flight)}:void 0,speculative:a?{total_speculations:d(a.total_speculations),total_commits:d(a.total_commits),total_aborts:d(a.total_aborts),commit_rate:d(a.commit_rate),total_fast_calls:d(a.total_fast_calls),total_cost_usd:d(a.total_cost_usd),active_sessions:d(a.active_sessions)}:void 0,search_fabric:o?{total_operations:d(o.total_operations),best_first_operations:d(o.best_first_operations),legacy_operations:d(o.legacy_operations),blocked_operations:d(o.blocked_operations),ready_operations:d(o.ready_operations),research_pipeline_operations:d(o.research_pipeline_operations),avg_candidate_count:d(o.avg_candidate_count),avg_best_score:d(o.avg_best_score),top_stage:r(o.top_stage)??null}:void 0,signals:l?{issue_pressure:mn(l.issue_pressure),cache_contention:mn(l.cache_contention),scheduler_efficiency:mn(l.scheduler_efficiency),routing_confidence:mn(l.routing_confidence),speculative_posture:mn(l.speculative_posture)}:void 0}}function Ll(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),paused:d(n.paused),managed:d(n.managed),projected:d(n.projected)}:void 0,microarch:Zm(t.microarch),operations:Array.isArray(t.operations)?t.operations.map(Xm).filter(s=>s!==null):[]}}function wl(e){if(!v(e))return null;const t=r(e.detachment_id),n=r(e.operation_id),s=r(e.assigned_unit_id);return!t||!n||!s?null:{detachment_id:t,operation_id:n,assigned_unit_id:s,leader_id:r(e.leader_id)??null,roster:W(e.roster),session_id:r(e.session_id)??null,checkpoint_ref:r(e.checkpoint_ref)??null,runtime_kind:r(e.runtime_kind)??null,runtime_ref:r(e.runtime_ref)??null,source:r(e.source),status:r(e.status),last_event_at:r(e.last_event_at)??null,last_progress_at:r(e.last_progress_at)??null,heartbeat_deadline:r(e.heartbeat_deadline)??null,created_at:r(e.created_at),updated_at:r(e.updated_at)}}function ev(e){if(!v(e))return null;const t=wl(e.detachment);return t?{detachment:t,assigned_unit_label:r(e.assigned_unit_label),operation:Ia(e.operation)}:null}function Nl(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),projected:d(n.projected)}:void 0,detachments:Array.isArray(t.detachments)?t.detachments.map(ev).filter(s=>s!==null):[]}}function tv(e){if(!v(e))return null;const t=r(e.decision_id),n=r(e.trace_id),s=r(e.requested_action),a=r(e.scope_type),o=r(e.scope_id);return!t||!n||!s||!a||!o?null:{decision_id:t,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:r(e.operation_id)??null,target_unit_id:r(e.target_unit_id)??null,requested_by:r(e.requested_by),status:r(e.status),reason:r(e.reason)??null,source:r(e.source),detail:e.detail,created_at:r(e.created_at),decided_at:r(e.decided_at)??null,expires_at:r(e.expires_at)??null}}function zl(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),pending:d(n.pending),approved:d(n.approved),denied:d(n.denied)}:void 0,decisions:Array.isArray(t.decisions)?t.decisions.map(tv).filter(s=>s!==null):[]}}function nv(e){if(!v(e))return null;const t=to(e.unit);return t?{unit:t,roster_total:d(e.roster_total),roster_live:d(e.roster_live),headcount_cap:d(e.headcount_cap),active_operations:d(e.active_operations),active_operation_cap:d(e.active_operation_cap),utilization:d(e.utilization)}:null}function sv(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),capacity:Array.isArray(t.capacity)?t.capacity.map(nv).filter(n=>n!==null):[]}}function av(e){if(!v(e))return null;const t=r(e.alert_id);return t?{alert_id:t,severity:r(e.severity),kind:r(e.kind),scope_type:r(e.scope_type),scope_id:r(e.scope_id),title:r(e.title),detail:r(e.detail),timestamp:r(e.timestamp)}:null}function Ml(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),bad:d(n.bad),warn:d(n.warn)}:void 0,alerts:Array.isArray(t.alerts)?t.alerts.map(av).filter(s=>s!==null):[]}}function El(e){if(!v(e))return null;const t=r(e.event_id),n=r(e.trace_id),s=r(e.event_type);return!t||!n||!s?null:{event_id:t,trace_id:n,event_type:s,operation_id:r(e.operation_id)??null,unit_id:r(e.unit_id)??null,actor:r(e.actor)??null,source:r(e.source),timestamp:r(e.timestamp),detail:e.detail}}function iv(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),events:Array.isArray(t.events)?t.events.map(El).filter(n=>n!==null):[]}}function ov(e){if(!v(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s}}function rv(e){if(!v(e))return null;const t=r(e.lane_id),n=r(e.label),s=r(e.kind),a=r(e.phase),o=r(e.motion_state),l=r(e.source_of_truth),c=r(e.movement_reason),p=r(e.current_step);if(!t||!n||!s||!a||!o||!l||!c||!p)return null;const m=v(e.counts)?e.counts:{};return{lane_id:t,label:n,kind:s,present:j(e.present)??!1,phase:a,motion_state:o,source_of_truth:l,last_movement_at:r(e.last_movement_at)??null,movement_reason:c,current_step:p,blockers:W(e.blockers),counts:{operations:d(m.operations),detachments:d(m.detachments),workers:d(m.workers),approvals:d(m.approvals),alerts:d(m.alerts)},hard_flags:Array.isArray(e.hard_flags)?e.hard_flags.map(ov).filter(u=>u!==null):[]}}function lv(e){if(!v(e))return null;const t=r(e.event_id),n=r(e.lane_id),s=r(e.kind),a=r(e.timestamp),o=r(e.title),l=r(e.detail),c=r(e.tone),p=r(e.source);return!t||!n||!s||!a||!o||!l||!c||!p?null:{event_id:t,lane_id:n,kind:s,timestamp:a,title:o,detail:l,tone:c,source:p}}function cv(e){if(!v(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s,lane_ids:W(e.lane_ids),count:d(e.count)??0}}function jl(e){if(!v(e))return;const t=v(e.overview)?e.overview:{},n=v(e.gaps)?e.gaps:{},s=v(e.recommended_next_action)?e.recommended_next_action:void 0;return{generated_at:r(e.generated_at),overview:{active_lanes:d(t.active_lanes),moving_lanes:d(t.moving_lanes),stalled_lanes:d(t.stalled_lanes),projected_lanes:d(t.projected_lanes),last_movement_at:r(t.last_movement_at)??null},lanes:Array.isArray(e.lanes)?e.lanes.map(rv).filter(a=>a!==null):[],timeline:Array.isArray(e.timeline)?e.timeline.map(lv).filter(a=>a!==null):[],gaps:{count:d(n.count),items:Array.isArray(n.items)?n.items.map(cv).filter(a=>a!==null):[]},recommended_next_action:s?{tool:r(s.tool)??"masc_operator_snapshot",label:r(s.label)??"Observe operator state",reason:r(s.reason)??"",lane_id:r(s.lane_id)??null}:void 0}}function dv(e){if(!v(e))return;const t=v(e.workers)?e.workers:{},n=j(e.pass);return{status:r(e.status)??"missing",source:r(e.source)??"none",run_id:r(e.run_id)??null,captured_at:r(e.captured_at)??null,...n!==void 0?{pass:n}:{},...d(e.peak_hot_slots)!=null?{peak_hot_slots:d(e.peak_hot_slots)}:{},...d(e.ctx_per_slot)!=null?{ctx_per_slot:d(e.ctx_per_slot)}:{},workers:{expected:d(t.expected),joined:d(t.joined),current_task_bound:d(t.current_task_bound),fresh_heartbeats:d(t.fresh_heartbeats),done:d(t.done),final:d(t.final)},artifact_ref:r(e.artifact_ref)??null,missing_reason:r(e.missing_reason)??null}}function uv(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),topology:Pl(t.topology),operations:Ll(t.operations),detachments:Nl(t.detachments),alerts:Ml(t.alerts),decisions:zl(t.decisions),capacity:sv(t.capacity),traces:iv(t.traces),swarm_status:jl(t.swarm_status)}}function pv(e){const t=v(e)?e:{},n=Pl(t.topology),s=Ll(t.operations),a=Nl(t.detachments),o=Ml(t.alerts),l=zl(t.decisions);return{version:r(t.version),generated_at:r(t.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:jl(t.swarm_status),swarm_proof:dv(t.swarm_proof)}}function mv(e){return v(e)?{chain_id:r(e.chain_id)??null,started_at:d(e.started_at)??null,progress:d(e.progress)??null,elapsed_sec:d(e.elapsed_sec)??null}:null}function Dl(e){if(!v(e))return null;const t=r(e.event);return t?{event:t,chain_id:r(e.chain_id)??null,timestamp:r(e.timestamp)??null,duration_ms:d(e.duration_ms)??null,message:r(e.message)??null,tokens:d(e.tokens)??null}:null}function vv(e){if(!v(e))return null;const t=Ia(e.operation);return t?{operation:t,runtime:mv(e.runtime),history:Dl(e.history),mermaid:r(e.mermaid)??null,preview_run:Ol(e.preview_run)}:null}function _v(e){const t=v(e)?e:{};return{status:r(t.status)??"disconnected",base_url:r(t.base_url)??null,message:r(t.message)??null}}function gv(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),connection:_v(t.connection),summary:n?{linked_operations:d(n.linked_operations),active_chains:d(n.active_chains),running_operations:d(n.running_operations),recent_failures:d(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(t.operations)?t.operations.map(vv).filter(s=>s!==null):[],recent_history:Array.isArray(t.recent_history)?t.recent_history.map(Dl).filter(s=>s!==null):[]}}function fv(e){if(!v(e))return null;const t=r(e.id);return t?{id:t,type:r(e.type),status:r(e.status),duration_ms:d(e.duration_ms)??null,error:r(e.error)??null}:null}function Ol(e){if(!v(e))return null;const t=r(e.run_id),n=r(e.chain_id);return n?{run_id:t??null,chain_id:n,duration_ms:d(e.duration_ms),success:j(e.success),mermaid:r(e.mermaid),nodes:Array.isArray(e.nodes)?e.nodes.map(fv).filter(s=>s!==null):[]}:null}function $v(e){const t=v(e)?e:{};return{run:Ol(t.run)}}function hv(e){if(!v(e))return null;const t=r(e.title),n=r(e.path);return!t||!n?null:{title:t,path:n}}function yv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary);return!t||!n||!s?null:{id:t,title:n,summary:s}}function bv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.tool),a=r(e.summary);return!t||!n||!s||!a?null:{id:t,title:n,tool:s,summary:a,success_signals:W(e.success_signals),pitfalls:W(e.pitfalls)}}function kv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary),a=r(e.when_to_use);return!t||!n||!s||!a?null:{id:t,title:n,summary:s,when_to_use:a,steps:Array.isArray(e.steps)?e.steps.map(bv).filter(o=>o!==null):[]}}function xv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.description);return!t||!n||!s?null:{id:t,title:n,description:s,tools:W(e.tools)}}function Sv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.symptom),a=r(e.why),o=r(e.fix_tool),l=r(e.fix_summary);return!t||!n||!s||!a||!o||!l?null:{id:t,title:n,symptom:s,why:a,fix_tool:o,fix_summary:l}}function Av(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.path_id),a=r(e.transport);return!t||!n||!s||!a?null:{id:t,title:n,path_id:s,transport:a,request:e.request,response:e.response,notes:W(e.notes)}}function Cv(e){const t=v(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),docs:Array.isArray(t.docs)?t.docs.map(hv).filter(n=>n!==null):[],concepts:Array.isArray(t.concepts)?t.concepts.map(yv).filter(n=>n!==null):[],golden_paths:Array.isArray(t.golden_paths)?t.golden_paths.map(kv).filter(n=>n!==null):[],tool_groups:Array.isArray(t.tool_groups)?t.tool_groups.map(xv).filter(n=>n!==null):[],pitfalls:Array.isArray(t.pitfalls)?t.pitfalls.map(Sv).filter(n=>n!==null):[],examples:Array.isArray(t.examples)?t.examples.map(Av).filter(n=>n!==null):[]}}function Tv(e){if(!v(e))return null;const t=r(e.id),n=r(e.title),s=r(e.status),a=r(e.detail),o=r(e.next_tool);return!t||!n||!s||!a||!o?null:{id:t,title:n,status:s,detail:a,next_tool:o}}function Iv(e){if(!v(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.title),a=r(e.detail),o=r(e.next_tool);return!t||!n||!s||!a||!o?null:{code:t,severity:n,title:s,detail:a,next_tool:o}}function Rv(e){if(!v(e))return null;const t=r(e.from),n=r(e.content),s=r(e.timestamp),a=d(e.seq);return!t||!n||!s||a==null?null:{seq:a,from:t,content:n,timestamp:s}}function Pv(e){if(!v(e))return null;const t=r(e.name),n=r(e.role),s=r(e.lane),a=r(e.status),o=r(e.claim_marker),l=r(e.done_marker),c=r(e.final_marker);if(!t||!n||!s||!a||!o||!l||!c)return null;const p=(()=>{if(!v(e.last_message))return null;const m=d(e.last_message.seq),u=r(e.last_message.content),_=r(e.last_message.timestamp);return m==null||!u||!_?null:{seq:m,content:u,timestamp:_}})();return{name:t,role:n,lane:s,joined:j(e.joined)??!1,live_presence:j(e.live_presence)??!1,completed:j(e.completed)??!1,status:a,current_task:r(e.current_task)??null,bound_task_id:r(e.bound_task_id)??null,bound_task_title:r(e.bound_task_title)??null,bound_task_status:r(e.bound_task_status)??null,current_task_matches_run:j(e.current_task_matches_run)??!1,squad_member:j(e.squad_member)??!1,detachment_member:j(e.detachment_member)??!1,last_seen:r(e.last_seen)??null,heartbeat_age_sec:d(e.heartbeat_age_sec)??null,heartbeat_fresh:j(e.heartbeat_fresh)??!1,claim_marker_seen:j(e.claim_marker_seen)??!1,done_marker_seen:j(e.done_marker_seen)??!1,final_marker_seen:j(e.final_marker_seen)??!1,claim_marker:o,done_marker:l,final_marker:c,last_message:p}}function Lv(e){if(!v(e))return;const t=Array.isArray(e.timeline)?e.timeline.map(n=>{if(!v(n))return null;const s=r(n.timestamp),a=d(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:r(e.slot_url)??null,provider_base_url:r(e.provider_base_url)??null,provider_reachable:j(e.provider_reachable)??null,provider_status_code:d(e.provider_status_code)??null,provider_model_id:r(e.provider_model_id)??null,actual_model_id:r(e.actual_model_id)??null,expected_slots:d(e.expected_slots),actual_slots:d(e.actual_slots),expected_ctx:d(e.expected_ctx),actual_ctx:d(e.actual_ctx),slot_reachable:j(e.slot_reachable)??null,slot_status_code:d(e.slot_status_code)??null,runtime_blocker:r(e.runtime_blocker)??null,detail:r(e.detail)??null,checked_at:r(e.checked_at)??null,total_slots:d(e.total_slots),ctx_per_slot:d(e.ctx_per_slot),active_slots_now:d(e.active_slots_now),peak_active_slots:d(e.peak_active_slots),sample_count:d(e.sample_count),last_sample_at:r(e.last_sample_at)??null,timeline:t}}function wv(e){if(!v(e))return null;const t=r(e.run_id),n=r(e.status),s=r(e.decided_by),a=r(e.decided_at),o=r(e.reason);if(!t||!n||!s||!a||!o)return null;const l=[];return Array.isArray(e.history)&&e.history.forEach(c=>{if(!v(c))return;const p=r(c.status),m=r(c.decided_by),u=r(c.decided_at),_=r(c.reason);!p||!m||!u||!_||l.push({status:p,decided_by:m,decided_at:u,reason:_,operation_id:r(c.operation_id)??null,detachment_id:r(c.detachment_id)??null,note:r(c.note)??null})}),{run_id:t,status:n,decided_by:s,decided_at:a,reason:o,operation_id:r(e.operation_id)??null,detachment_id:r(e.detachment_id)??null,note:r(e.note)??null,history:l}}function Nv(e){if(!v(e))return null;const t=r(e.run_id),n=r(e.recommended_kind),s=r(e.reason);return!t||!n||!s?null:{run_id:t,recommended_kind:n,continue_available:j(e.continue_available)??!1,rerun_available:j(e.rerun_available)??!1,abandon_available:j(e.abandon_available)??!1,reason:s,evidence:v(e.evidence)?{operation_id:r(e.evidence.operation_id)??null,detachment_id:r(e.evidence.detachment_id)??null,joined_workers:d(e.evidence.joined_workers),current_task_bound:d(e.evidence.current_task_bound),fresh_heartbeats:d(e.evidence.fresh_heartbeats),trace_events:d(e.evidence.trace_events),message_events:d(e.evidence.message_events),runtime_blocker:r(e.evidence.runtime_blocker)??null}:void 0,provenance:r(e.provenance),decision_engine:r(e.decision_engine),authoritative:j(e.authoritative)}}function zv(e){const t=v(e)?e:{},n=v(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),run_id:r(t.run_id),room_id:r(t.room_id),operation_id:r(t.operation_id)??null,run_resolution:wv(t.run_resolution),resolution_recommendation:Nv(t.resolution_recommendation),recommended_next_tool:r(t.recommended_next_tool),summary:n?{expected_workers:d(n.expected_workers),joined_workers:d(n.joined_workers),live_workers:d(n.live_workers),squad_roster_size:d(n.squad_roster_size),detachment_roster_size:d(n.detachment_roster_size),current_task_bound:d(n.current_task_bound),fresh_heartbeats:d(n.fresh_heartbeats),claim_markers_seen:d(n.claim_markers_seen),done_markers_seen:d(n.done_markers_seen),final_markers_seen:d(n.final_markers_seen),completed_workers:d(n.completed_workers),peak_hot_slots:d(n.peak_hot_slots),hot_window_ok:j(n.hot_window_ok),pass_hot_concurrency:j(n.pass_hot_concurrency),pass_end_to_end:j(n.pass_end_to_end),pending_decisions:d(n.pending_decisions),pass:j(n.pass)}:void 0,provider:Lv(t.provider),operation:Ia(t.operation),squad:to(t.squad),detachment:wl(t.detachment),workers:Array.isArray(t.workers)?t.workers.map(Pv).filter(s=>s!==null):[],checklist:Array.isArray(t.checklist)?t.checklist.map(Tv).filter(s=>s!==null):[],blockers:Array.isArray(t.blockers)?t.blockers.map(Iv).filter(s=>s!==null):[],recent_messages:Array.isArray(t.recent_messages)?t.recent_messages.map(Rv).filter(s=>s!==null):[],recent_trace_events:Array.isArray(t.recent_trace_events)?t.recent_trace_events.map(El).filter(s=>s!==null):[],truth_notes:W(t.truth_notes)}}function St(e){Z.value=e,eo(e)&&Mv()}async function ql(){Ys.value=!0,Xs.value=null;try{const e=await pd();Zi.value=pv(e)}catch(e){Xs.value=e instanceof Error?e.message:"Failed to load command-plane summary"}finally{Ys.value=!1}}function no(e){Jt.value=e}async function so(){Qs.value=!0,Zs.value=null;try{const e=await ud();je.value=uv(e)}catch(e){Zs.value=e instanceof Error?e.message:"Failed to load command-plane snapshot"}finally{Qs.value=!1}}async function Mv(){je.value||Qs.value||await so()}async function jt(){await ql(),eo(Z.value)&&await so()}async function Vt(){var e;Ii.value=!0,aa.value=null;try{const t=await md(),n=gv(t);Xn.value=n;const s=Jt.value;n.operations.length===0?Jt.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Jt.value=((e=n.operations[0])==null?void 0:e.operation.operation_id)??null)}catch(t){aa.value=t instanceof Error?t.message:"Failed to load chain summary"}finally{Ii.value=!1}}function Ev(){_n=null,zn.value=null,ia.value=!1,Mn.value=null}async function jv(e){_n=e,ia.value=!0,Mn.value=null;try{const t=await vd(e);if(_n!==e)return;zn.value=$v(t)}catch(t){if(_n!==e)return;zn.value=null,Mn.value=t instanceof Error?t.message:"Failed to load chain run"}finally{_n===e&&(ia.value=!1)}}async function Dv(){Ti.value=!0,ta.value=null;try{const e=await _d();Qn.value=Cv(e)}catch(e){ta.value=e instanceof Error?e.message:"Failed to load command-plane help"}finally{Ti.value=!1}}async function Ve(e=Wm(),t=Gm()){na.value=!0,sa.value=null;try{const n=await gd(e,t);It.value=zv(n)}catch(n){sa.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{na.value=!1}}async function dt(e,t,n){Ci.value=e,ea.value=null;try{await fd(t,n),await ql(),(je.value||eo(Z.value))&&await so(),await Ve(),await Vt()}catch(s){throw ea.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{Ci.value=null}}function Ov(e){return dt(`pause:${e}`,"/api/v1/command-plane/operations/pause",{operation_id:e})}function qv(e){return dt(`resume:${e}`,"/api/v1/command-plane/operations/resume",{operation_id:e})}function Fv(e){return dt(`recall:${e}`,"/api/v1/command-plane/dispatch/recall",{operation_id:e})}function Kv(e={}){return dt("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...e.operationId?{operation_id:e.operationId}:{},...e.detachmentId?{detachment_id:e.detachmentId}:{}})}function Bv(e){return dt(`approve:${e}`,"/api/v1/command-plane/policy/approve",{decision_id:e})}function Uv(e){return dt(`deny:${e}`,"/api/v1/command-plane/policy/deny",{decision_id:e})}function Hv(e,t){return dt(`freeze:${e}`,"/api/v1/command-plane/policy/freeze",{unit_id:e,enabled:t})}function Wv(e,t){return dt(`kill:${e}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:e,enabled:t})}Zu(()=>{jt(),Vt(),(Z.value==="swarm"||Z.value==="warroom"||It.value!==null)&&Ve(),Z.value==="warroom"&&ye()});function oa(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Y(e){if(!e)return"n/a";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function Gv(e){if(!e)return"warn";const t=Date.parse(e);return Number.isNaN(t)?"warn":t<=Date.now()?"bad":"ok"}function Fl(e){if(!e)return"n/a";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.round((t-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function M(e){return e==="bad"?"bad":e==="warn"||e==="pending"?"warn":"ok"}let qo=!1,Jv=0;function Vv(){return++Jv}let Da=null;async function Yv(){Da||(Da=Hm(()=>import("./mermaid.core-D3upnTtD.js").then(t=>t.bE),[]).then(t=>t.default));const e=await Da;return qo||(e.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),qo=!0),e}function tt(e){if(!e)return"warn";const t=e.toLowerCase();return t.includes("failed")||t.includes("error")||t.includes("disconnected")||t.includes("stopped")?"bad":t.includes("running")||t.includes("active")||t.includes("degraded")||t.includes("pending")?"warn":"ok"}function Zn(e){return typeof e!="number"||!Number.isFinite(e)?"n/a":`${Math.round(e*100)}%`}function gn(e){return typeof e!="number"||!Number.isFinite(e)?"n/a":e<60?`${Math.round(e)}s`:e<3600?`${Math.round(e/60)}m`:`${Math.round(e/3600)}h`}function es(e){return typeof e!="number"||!Number.isFinite(e)?0:Math.max(0,Math.min(100,e))}function gt(e,t){return typeof e!="number"||!Number.isFinite(e)||typeof t!="number"||!Number.isFinite(t)||t<=0?0:es(e/t*100)}function Qv(e,t){const n=es(e);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${t};`}function Kl(e){if(!e)return"No recent chain history";const t=[e.event];return typeof e.duration_ms=="number"&&t.push(`${e.duration_ms}ms`),typeof e.tokens=="number"&&t.push(`${e.tokens} tokens`),e.message&&t.push(e.message),t.join(" · ")}const Xv=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Bl=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],Zv=Bl.map(e=>e.id),e_=["chain_start","node_start","node_complete","chain_complete","chain_error"],t_={warroom:{title:"라이브 워룸",description:"실제 run, worker, message, trace를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"실제 managed unit인지, live agent 기반 자동 투영인지 구분해서 봅니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function Fo(e){return!!e&&Zv.includes(e)}function n_(){const e=F.value.params;return e.source!=="mission"&&e.source!=="execution"?{}:{source:e.source,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function Ul(e){const t=n_();if(e==="operations")return t;if(e==="chains"){const n=Jt.value;return n?{...t,surface:e,operation:n}:{...t,surface:e}}return{...t,surface:e}}function s_(){const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");return n&&t.set("agent",n),s&&t.set("token",s),t.toString()?`/api/v1/chains/events?${t.toString()}`:"/api/v1/chains/events"}function a_(e){switch(e){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return e}}function ae(e){return Ci.value===e}function ts(){return Zi.value}function i_(e){var a,o,l,c,p,m,u;const t=Zi.value,n=It.value,s=Xn.value;switch(e){case"warroom":return{tool:"masc_observe_operations",reason:"live run, worker, message, trace를 한 화면에서 보고 필요한 detail 표면으로 바로 점프합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=t==null?void 0:t.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(o=t==null?void 0:t.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((p=(c=t==null?void 0:t.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:p.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(u=(m=s==null?void 0:s.operations[0])==null?void 0:m.preview_run)!=null&&u.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"이 구조가 실제 관리 단위인지 자동 투영인지 먼저 구분해야 command-plane을 오해하지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function o_(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"microarch":t.includes("leader_offline")||t.includes("roster_offline")?"alerts":t.includes("stale_data")?"swarm":null:null}function r_(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")?"recommendation":t.includes("gap")?"gaps":null:null}function Hl(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");if(!t)return null;const n=t.trim();return n===""?null:n}function Wl(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,o)=>{e.has(o)||e.set(o,a)}),e}function l_(){const t=Wl().get("run_id");if(!t)return null;const n=t.trim();return n===""?null:n}function Gl(){const t=Wl().get("operation_id");if(!t)return null;const n=t.trim();return n===""?null:n}function c_(e){if(!e)return null;const t=Date.parse(e);return Number.isNaN(t)?null:Math.max(0,Math.round((Date.now()-t)/1e3))}function d_(e){return e.status==="claimed"||e.status==="in_progress"}function u_(e){const t=Qn.value;if(!t)return null;for(const n of t.golden_paths){const s=n.steps.find(a=>a.tool===e);if(s)return s}return null}function Oa(e){var t;return((t=Qn.value)==null?void 0:t.golden_paths.find(n=>n.id===e))??null}function p_(e){const t=Qn.value;if(!t)return[];const n=new Set(e);return t.pitfalls.filter(s=>n.has(s.id))}async function nt(e){try{await e()}catch{}}function ao(e){return(e==null?void 0:e.trim().toLowerCase())??""}function Dt(e){const t=ao(e);return t.includes("failed")||t.includes("error")||t.includes("stopped")||t==="paused"?"bad":t.includes("active")||t.includes("running")||t.includes("healthy")||t.includes("ok")?"ok":"warn"}function ps(e){const t=ao(e);return t?t==="active"||t==="running"?"진행 중":t==="paused"?"일시정지":t==="done"||t==="ended"||t==="completed"?"완료":t==="failed"||t==="error"||t==="stopped"?"문제":(e==null?void 0:e.trim())||"확인 필요":"확인 필요"}function m_(){var n,s,a,o,l,c,p,m,u;const e=It.value;if(!e)return!1;const t=e.workers.some(_=>_.joined||_.live_presence||_.completed||_.current_task_matches_run||_.heartbeat_fresh||_.claim_marker_seen||_.done_marker_seen||_.final_marker_seen||!!_.current_task||!!_.bound_task_id||!!_.last_message);return!!((n=e.operation)!=null&&n.operation_id||(s=e.detachment)!=null&&s.detachment_id||(((a=e.summary)==null?void 0:a.joined_workers)??0)>0||(((o=e.summary)==null?void 0:o.live_workers)??0)>0||(((l=e.summary)==null?void 0:l.current_task_bound)??0)>0||(((c=e.summary)==null?void 0:c.fresh_heartbeats)??0)>0||(((p=e.summary)==null?void 0:p.claim_markers_seen)??0)>0||(((m=e.summary)==null?void 0:m.done_markers_seen)??0)>0||(((u=e.summary)==null?void 0:u.final_markers_seen)??0)>0||t||e.recent_messages.length>0||e.recent_trace_events.length>0)}function v_(e){const t=ao(e.status);return t==="active"||t==="running"}function __(){var o,l,c,p;const e=((o=_e.value)==null?void 0:o.sessions)??[],t=It.value,n=((l=t==null?void 0:t.detachment)==null?void 0:l.session_id)??null;if(n){const m=e.find(u=>u.session_id===n);if(m)return m}const s=((c=t==null?void 0:t.operation)==null?void 0:c.operation_id)??Gl();if(s){const m=e.find(u=>u.command_plane_operation_id===s);if(m)return m}const a=((p=t==null?void 0:t.detachment)==null?void 0:p.detachment_id)??null;if(a){const m=e.find(u=>u.command_plane_detachment_id===a);if(m)return m}return e.find(v_)??e[0]??null}function qa(e){return e==="proven"?"ok":e==="partial"?"warn":"bad"}function kn(e){return Array.isArray(e)?e:[]}function Re(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)?e:{}}function ms(e){return typeof e=="string"&&e.trim()!==""?e:null}function g_(e){return typeof e=="number"&&Number.isFinite(e)?e:null}function f_(e){const t=e.split("/");return t.length<=3?e:`…/${t.slice(-3).join("/")}`}function $_(e){return e==="proven"?"협업 증거가 충분합니다":e==="partial"?"흔적은 있으나 협업 증거가 덜 모였습니다":"증거가 부족합니다"}function h_(e,t,n,s,a){const o=[`${t}명의 actor 흔적이 기록돼 있습니다.`,n>0?`서로를 참조한 상호작용 증거가 ${n}건 있습니다.`:"서로를 참조한 명시적 상호작용 증거가 아직 없습니다.",s>0?`도구·산출물·체크포인트 증거가 ${s}건 있습니다.`:"도구·산출물·체크포인트 증거가 거의 없습니다.",a>0?`CPv2 backing trace가 ${a}건 있어 실행 흔적은 남아 있습니다.`:"managed backing trace는 아직 없습니다."];return e==="partial"?[o[0]??"",n===0?"partial인 이유: 참여 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.":"partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.",a>0?"다음 보강 포인트: 대화/상호참조 event를 남기면 proof가 더 강해집니다.":"다음 보강 포인트: managed trace 또는 산출물 linkage를 더 남기면 proof가 강해집니다."]:e==="proven"?[o[0]??"","결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.","다음 행동: raw evidence는 접어두고 세션 결과와 산출물만 확인하면 됩니다."]:[o[0]??"","결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.","다음 보강 포인트: participant 간 turn, tool evidence, deliverable linkage를 더 남겨야 합니다."]}function y_(e){const t=new Map;for(const n of e){const s=[n.timestamp??"",n.event_type??"",n.actor??"",n.summary??""].join("|"),a=n.source??"unknown",o=t.get(s);if(o){o.sources.includes(a)||o.sources.push(a),!o.operation_id&&n.operation_id&&(o.operation_id=n.operation_id);continue}t.set(s,{...n,sources:[a]})}return[...t.values()]}function b_(e){return e.sources.length===2?"team + command":e.sources.length===1?e.sources[0]??"source":e.sources.join(" + ")}function k_(e){const t=[];for(const[n,s]of Object.entries(e))if(s!=null){if(typeof s=="string"){if(s.trim()==="")continue;t.push({label:n,value:s});continue}if(typeof s=="number"||typeof s=="boolean"){t.push({label:n,value:String(s)});continue}}return t}function x_(e){const t=Re(e),n=Re(t.traces),s=Array.isArray(n.events)?n.events:[],a=Re(t.detachments),o=Array.isArray(a.detachments)?a.detachments:[],l=Re(o[0]),c=Re(l.detachment),p=Re(l.operation),m=Re(t.summary),u=Re(m.operations),_=Re(u.summary);return[{label:"operation",value:ms(t.operation_id)??"없음"},{label:"detachment",value:ms(t.detachment_id)??"없음"},{label:"trace events",value:`${s.length}`},{label:"detachment status",value:ms(c.status)??"없음"},{label:"operation stage",value:ms(p.stage)??"없음"},{label:"active ops",value:`${g_(_.active)??0}`}]}function S_({item:e}){return i`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${e.summary??e.event_type??"event"}</strong>
          <div class="command-meta-line">
            <span>${b_(e)}</span>
            <span>${e.event_type??"event"}</span>
            <span>${e.actor??"system"}</span>
          </div>
        </div>
        <span class="command-chip">${Y(e.timestamp)}</span>
      </div>
      ${e.sources.length>1?i`<div class="semantic-tag-row">
            ${e.sources.map(t=>i`<span class="semantic-tag">${t}</span>`)}
          </div>`:null}
    </article>
  `}function A_({item:e}){const t=e.recent_output_preview??null,n=e.recent_input_preview??null,s=e.recent_event_summary??null,a=(e.interaction_count??0)>0?"ok":"warn";return i`
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
      ${s?i`<div class="proof-summary-block">
            <strong>최근 흔적</strong>
            <span>${s}</span>
          </div>`:null}
      ${n||t?i`<div class="proof-io-grid">
            <div class="mission-activity-preview">
              <strong>최근 input</strong>
              <span>${n??"표시 가능한 input 없음"}</span>
            </div>
            <div class="mission-activity-preview">
              <strong>최근 output</strong>
              <span>${t??"표시 가능한 output 없음"}</span>
            </div>
          </div>`:null}
      ${kn(e.recent_tool_names).length>0?i`<div class="semantic-tag-row">
            ${kn(e.recent_tool_names).map(o=>i`<span class="semantic-tag">${o}</span>`)}
          </div>`:null}
    </article>
  `}function C_({item:e}){return i`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${e.kind}</strong>
          <div class="command-meta-line">
            <span>${f_(e.path)}</span>
          </div>
        </div>
        <span class="command-chip ${e.exists?"ok":"warn"}">${e.exists?"present":"missing"}</span>
      </div>
    </article>
  `}function Ko({title:e,rows:t}){return t.length===0?null:i`
    <div class="proof-kv-block">
      ${e?i`<strong>${e}</strong>`:null}
      <div class="proof-kv-grid">
        ${t.map(n=>i`
          <span>${n.label}</span>
          <strong>${n.value}</strong>
        `)}
      </div>
    </div>
  `}function T_(){var N,R,P;const e=F.value.params,t=e.session_id??null,n=e.operation_id??null;te(()=>{Tl(t,n)},[t,n]);const s=Cl.value;if(Ai.value&&!s)return i`<section class="dashboard-panel"><div class="loading-indicator">Loading proof…</div></section>`;if(Et.value&&!s)return i`<section class="dashboard-panel"><div class="error-card">${Et.value}</div></section>`;const a=s==null?void 0:s.summary,o=kn(s==null?void 0:s.actor_contributions),l=kn(s==null?void 0:s.artifacts),c=(s==null?void 0:s.proof_verdict)??"insufficient",p=(s==null?void 0:s.cp_backing_evidence)??null,m=Array.isArray((N=p==null?void 0:p.traces)==null?void 0:N.events)?((P=(R=p.traces)==null?void 0:R.events)==null?void 0:P.length)??0:0,u=(a==null?void 0:a.actors_count)??o.length,_=(a==null?void 0:a.interaction_count)??0,f=(a==null?void 0:a.evidence_count)??0,$=y_(kn(s==null?void 0:s.timeline)),S=k_(Re(s==null?void 0:s.goal_binding)),h=x_(p),C=l.filter(L=>L.exists).length,x=l.length-C,k=h_(c,u,_,f,m);return i`
    <section class="dashboard-panel mission-view">
      <${be} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>Proof</h2>
          <p>이 세션이 실제로 여러 actor의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${qa(c)}">${c}</span>
          ${s!=null&&s.session_id?i`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?i`<span class="command-chip">${Y(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${Et.value?i`<div class="error-card">${Et.value}</div>`:null}

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${qa(c)}">
          <span>Verdict</span>
          <strong>${$_(c)}</strong>
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
        <div class="summary-stat-card ${x===0&&l.length>0?"ok":"warn"}">
          <span>Artifacts</span>
          <strong>${C}/${l.length}</strong>
          <small>${x>0?`${x} missing`:"all present"}</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${T} title="3-Line Proof Summary" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, partial 이유, 다음 보강 포인트만 먼저 봅니다.</p>
          </div>
          <div class="proof-summary-stack">
            ${k.map((L,I)=>i`
              <article class="proof-summary-block ${I===1&&c!=="proven"?qa(c):""}">
                <strong>${I===0?"지금 결론":I===1?"왜 이렇게 판정됐나":"다음 보강 포인트"}</strong>
                <span>${L}</span>
              </article>
            `)}
          </div>
        <//>

        <${T} title="Goal Binding" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 proof가 어느 세션, 목표, operation에 묶였는지 읽습니다.</p>
          </div>
          <${Ko} rows=${S} />
          <details class="mission-card-disclosure compact">
            <summary>raw goal binding JSON</summary>
            <pre class="command-json-block">${oa((s==null?void 0:s.goal_binding)??{})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${T} title="Collaboration Timeline" class="mission-list-card" semanticId="proof.timeline">
          <div class="mission-section-head">
            <h3>협업 타임라인</h3>
            <p>team-session과 command-plane에서 같은 사건이 보이면 한 줄로 묶어 읽습니다.</p>
          </div>
          <div class="mission-list-stack">
            ${$.length>0?$.slice(0,18).map(L=>i`<${S_} key=${L.id} item=${L} />`):i`<div class="empty-state">표시할 timeline evidence가 없습니다.</div>`}
          </div>
        <//>

        <${T} title="Actor Contributions" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>turn 수보다 최근 흔적, 입출력, 도구, interaction 유무를 우선 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${o.length>0?o.map(L=>i`<${A_} key=${L.actor} item=${L} />`):i`<div class="empty-state">표시할 actor contribution이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${T} title="Backing Evidence" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>operation, detachment, trace 수만 먼저 보고, raw CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${Ko} rows=${h} />
          <details class="mission-card-disclosure compact">
            <summary>raw CPv2 backing JSON</summary>
            <pre class="command-json-block">${oa(p??{})}</pre>
          </details>
        <//>

        <${T} title="Artifacts" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>어떤 파일 산출물이 남았나</h3>
            <p>proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${l.length>0?l.map(L=>i`<${C_} key=${L.path} item=${L} />`):i`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function I_(){const e=Yn(F.value);return e?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${e.source_label}</strong>
        <span class="command-chip">${Aa(e.action_type)}</span>
        <span class="command-chip">${Ji(e)}</span>
        <span class="command-chip">${Ep(F.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${e.summary}</div>
      ${e.payload_preview?i`<div class="command-focus-preview">${e.payload_preview}</div>`:null}
    </section>
  `:null}function R_(){const e=Z.value,t=t_[e],n=i_(e);return i`
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
  `}function vs({label:e,value:t,subtext:n,percent:s,color:a}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${Qv(s,a)}>
        <div class="command-gauge-core">
          <strong>${t}</strong>
          <span>${Math.round(es(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${e}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function _s({label:e,value:t,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${M(a)}">
      <div class="command-signal-copy">
        <span>${e}</span>
        <strong>${t}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${M(a)}" style=${`width: ${Math.max(8,Math.round(es(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function P_(){var Q,se,J,ee;const e=ts(),t=e==null?void 0:e.topology.summary,n=e==null?void 0:e.operations.summary,s=e==null?void 0:e.detachments.summary,a=e==null?void 0:e.decisions.summary,o=e==null?void 0:e.alerts.summary,l=(Q=e==null?void 0:e.swarm_status)==null?void 0:Q.overview,c=e==null?void 0:e.swarm_proof,p=e==null?void 0:e.operations.microarch,m=(t==null?void 0:t.managed_unit_count)??0,u=(t==null?void 0:t.total_units)??0,_=(n==null?void 0:n.active)??0,f=(s==null?void 0:s.active)??0,$=(l==null?void 0:l.moving_lanes)??0,S=(l==null?void 0:l.active_lanes)??0,h=(c==null?void 0:c.workers.done)??0,C=(c==null?void 0:c.workers.expected)??0,x=(o==null?void 0:o.bad)??0,k=(o==null?void 0:o.warn)??0,N=(a==null?void 0:a.pending)??0,R=(a==null?void 0:a.total)??0,P=_+f,L=((se=p==null?void 0:p.cache)==null?void 0:se.l1_hit_rate)??((ee=(J=p==null?void 0:p.signals)==null?void 0:J.cache_contention)==null?void 0:ee.l1_hit_rate)??0,I=_>0||f>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",w=_>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${I}</h3>
        <p>${w}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${M(_>0?"ok":"warn")}">활성 작전 ${_}</span>
          <span class="command-chip ${M($>0?"ok":(S>0,"warn"))}">이동 레인 ${$}/${Math.max(S,$)}</span>
          <span class="command-chip ${M(x>0?"bad":k>0?"warn":"ok")}">치명 알림 ${x}</span>
          <span class="command-chip ${M(N>0?"warn":"ok")}">승인 대기 ${N}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${vs}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(u,m)}`}
          subtext=${u>0?`${u-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${gt(m,Math.max(u,m))}
          color="#67e8f9"
        />
        <${vs}
          label="실행 열도"
          value=${String(P)}
          subtext=${`${_}개 작전 + ${f}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${gt(P,Math.max(m,P||1))}
          color="#4ade80"
        />
        <${vs}
          label="스웜 이동감"
          value=${`${$}/${Math.max(S,$)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${Y(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${gt($,Math.max(S,$||1))}
          color="#fbbf24"
        />
        <${vs}
          label="증거 수집률"
          value=${`${h}/${Math.max(C,h)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${gt(h,Math.max(C,h||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${_s}
        label="승인 대기열"
        value=${`${N}건 대기`}
        detail=${`현재 정책 창에서 ${R}개 결정을 추적 중입니다`}
        percent=${gt(N,Math.max(R,N||1))}
        tone=${N>0?"warn":"ok"}
      />
      <${_s}
        label="알림 압력"
        value=${`${x} bad / ${k} warn`}
        detail=${x>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${gt(x*2+k,Math.max((x+k)*2,1))}
        tone=${x>0?"bad":k>0?"warn":"ok"}
      />
      <${_s}
        label="디스패치 점유"
          value=${`${f}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${gt(f,Math.max(m,f||1))}
        tone=${f>0?"ok":"warn"}
      />
      <${_s}
        label="캐시 신뢰도"
        value=${L?Zn(L):"n/a"}
        detail=${L?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${es((L??0)*100)}
        tone=${L>=.75?"ok":L>=.4?"warn":"bad"}
      />
    </div>
  `}function L_(){var f,$,S,h,C;const e=ts(),t=Xn.value,n=Yn(F.value),s=o_(n),a=e==null?void 0:e.topology.summary,o=e==null?void 0:e.operations.summary,l=(f=e==null?void 0:e.swarm_status)==null?void 0:f.overview,c=e==null?void 0:e.operations.microarch,p=e==null?void 0:e.decisions.summary,m=e==null?void 0:e.alerts.summary,u=($=c==null?void 0:c.signals)==null?void 0:$.issue_pressure,_=c==null?void 0:c.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((S=e==null?void 0:e.detachments.summary)==null?void 0:S.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(p==null?void 0:p.pending)??0}</strong><small>${(p==null?void 0:p.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((h=t==null?void 0:t.summary)==null?void 0:h.active_chains)??0}</strong><small>${((C=t==null?void 0:t.summary)==null?void 0:C.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${Y(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(_==null?void 0:_.l1_hit_rate)!=null?`${Zn(_.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"n/a"}</small></div>
    </div>
  `}function w_(){var Q,se,J,ee,A,Ce,He,ut,pt;const e=ts(),t=je.value,n=ne.value,s=Hl(),a=s?Ue.value.find(K=>K.name===s)??null:null,o=s?Qe.value.filter(K=>K.assignee===s&&d_(K)):[],l=((Q=e==null?void 0:e.operations.summary)==null?void 0:Q.active)??0,c=((se=e==null?void 0:e.detachments.summary)==null?void 0:se.total)??0,p=((J=e==null?void 0:e.decisions.summary)==null?void 0:J.pending)??0,m=t==null?void 0:t.detachments.detachments.find(K=>{const Te=K.detachment.heartbeat_deadline,mt=Te?Date.parse(Te):Number.NaN;return K.detachment.status==="stalled"||!Number.isNaN(mt)&&mt<=Date.now()}),u=t==null?void 0:t.alerts.alerts.find(K=>K.severity==="bad"),_=!!(n!=null&&n.room||n!=null&&n.project),f=(a==null?void 0:a.current_task)??null,$=c_(a==null?void 0:a.last_seen),S=$!=null?$<=120:null,h=[_?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:Qe.value.length>0?"masc_claim":"masc_add_task"}:f?S===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${f} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${f}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!e||(((ee=e.topology.summary)==null?void 0:ee.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((A=e.topology.summary)==null?void 0:A.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Ce=e.topology.summary)==null?void 0:Ce.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},p>0?{title:"디스패치 준비도",tone:"warn",detail:`${p}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||u?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${u?` · alert ${u.title??u.alert_id}`:""}${!t&&!m&&!u?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${t?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],C=_?!s||!a?"masc_join":o.length===0?Qe.value.length>0?"masc_claim":"masc_add_task":f?S===!1?"masc_heartbeat":!e||(((He=e.topology.summary)==null?void 0:He.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":p>0?"masc_policy_approve":l>0&&c===0||m||u?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",x=u_(C),N=p_(C==="masc_set_room"?["repo-root-room"]:C==="masc_plan_set_task"?["claimed-not-current"]:C==="masc_heartbeat"?["heartbeat-stale"]:C==="masc_dispatch_tick"?["no-detachments"]:C==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),R=Oa("room_task_hygiene"),P=Oa("cpv2_benchmark"),L=Oa("supervisor_session"),I=((ut=Qn.value)==null?void 0:ut.docs)??[],w=[R,P,L].filter(K=>K!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${q} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(x==null?void 0:x.title)??C}</strong>
            <span class="command-chip ok">${C}</span>
          </div>
          <p>${(x==null?void 0:x.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(pt=x==null?void 0:x.success_signals)!=null&&pt.length?i`<div class="command-tag-row">
                ${x.success_signals.map(K=>i`<span class="command-tag ok">${K}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${h.map(K=>i`
            <article class="command-readiness-row ${M(K.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${K.title}</strong>
                  <span class="command-chip ${M(K.tone)}">${K.tone}</span>
                </div>
                <p>${K.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${K.tool}</div>
            </article>
          `)}
        </div>

        ${N.length>0?i`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${N.length}</span>
                </div>
                <div class="command-guide-list">
                  ${N.map(K=>i`
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
          <${q} panelId="command.summary" compact=${!0} />
        </div>
        ${Ti.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:ta.value?i`<div class="empty-state error">${ta.value}</div>`:i`
                <div class="command-path-grid">
                  ${w.map(K=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${K.title}</strong>
                        <span class="command-chip">${K.id}</span>
                      </div>
                      <p>${K.summary}</p>
                      <div class="command-card-sub">${K.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${K.steps.slice(0,4).map(Te=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Te.tool}</span>
                            <span>${Te.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${I.length>0?i`<div class="command-doc-links">
                      ${I.map(K=>i`<span class="command-tag">${K.title}: ${K.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function N_(){return i`
    <${P_} />
    <${L_} />
    <${w_} />
  `}function z_(){return Qs.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:Zs.value?i`<div class="empty-state error">${Zs.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}const Jl="masc_dashboard_agent_name";function M_(){var t,n,s;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Jl))==null?void 0:s.trim())||"dashboard"}const Ra=g(M_()),Yt=g(""),ra=g("운영 점검"),Qt=g(""),En=g(""),jn=g("2"),nn=g(""),he=g("note"),Dn=g(""),On=g(""),qn=g(""),Fn=g("2"),Kn=g(""),la=g("운영자 중지 요청"),ca=g(""),Xt=g(""),gs=g(null);function E_(e){const t=e.trim()||"dashboard";Ra.value=t,localStorage.setItem(Jl,t)}function da(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function io(e){switch((e??"").trim().toLowerCase()){case"judgment":return"Resident judgment";case"fallback":return"Fallback read model";default:return(e==null?void 0:e.trim())||"Guidance"}}function ua(e){switch((e??"").trim().toLowerCase()){case"judgment":return"ok";case"fallback":return"warn";default:return"warn"}}function oo(e){return e!=null&&e.enabled?e.refreshing?"갱신 중":e.judge_online?"온라인":e.last_error?"오류":"대기":"꺼짐"}function j_(e){return e!=null&&e.enabled?e.judge_online?"ok":e.refreshing?"warn":"bad":"warn"}function ro(e){return e!=null&&e.fresh_until?e.fresh_until:"freshness 없음"}function Bo(e){return typeof e!="number"||!Number.isFinite(e)?"확인 없음":e<60?`${Math.round(e)}초 전`:e<3600?`${Math.round(e/60)}분 전`:`${Math.round(e/3600)}시간 전`}function sn(e){return typeof e=="string"?e.trim().toLowerCase():""}function D_(e){var s;const t=sn(e.status);if(t==="paused")return"bad";if(t===""||t==="unknown")return"warn";const n=sn((s=e.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||t&&t!=="active"&&t!=="running"&&t!=="ended"?"warn":"ok"}function Fa(e){const t=sn(e.status);return t==="offline"||t==="inactive"||t==="error"?"bad":t===""||t==="unknown"||(e.context_ratio??0)>=.8||e.context_ratio==null||e.last_turn_ago_s==null||(e.last_turn_ago_s??0)>=3600?"warn":"ok"}function Uo(e){return e.some(t=>sn(t.severity)==="bad")?"bad":e.length>0?"warn":"ok"}function O_(e){return e.target_type==="team_session"}function q_(e){return e.target_type==="keeper"}function At(e){switch(e){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"team_worker_spawn_batch":return"세션 worker 교체";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(e==null?void 0:e.trim())||"액션"}}function Zt(e){switch(e){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";case"swarm_run":return"swarm run";default:return(e==null?void 0:e.trim())||"target"}}function Ot(e){switch(sn(e)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function pa(e){return e?"확인 후 실행":"즉시 실행"}function F_(e){switch(e){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"worker_spawn_batch":return"worker 교체";default:return e}}function ue(e,t){if(!e)return null;const n=e[t];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function K_(e){return!e||typeof e!="object"||Array.isArray(e)?null:e}function B_(e){if(!e)return"";const t=e.spawn_batch;return da(t!==void 0?t:e)}function Vl(e){const t=K_(e.payload);if(e.target_type==="room"){if(e.action_type==="broadcast"){Yt.value=ue(t,"message")??e.summary;return}if(e.action_type==="task_inject"){Qt.value=ue(t,"title")??"운영자 주입 작업",En.value=ue(t,"description")??e.summary,jn.value=ue(t,"priority")??jn.value;return}e.action_type==="room_pause"&&(ra.value=ue(t,"reason")??e.summary);return}if(e.target_type==="team_session"){if(e.target_id&&(nn.value=e.target_id),e.action_type==="team_stop"){la.value=ue(t,"reason")??e.summary;return}he.value=e.action_type==="team_worker_spawn_batch"?"worker_spawn_batch":e.action_type==="team_task_inject"?"task":e.action_type==="team_broadcast"?"broadcast":"note";const n=ue(t,"message");if(n&&(Dn.value=n),he.value==="worker_spawn_batch"){Kn.value=B_(t);return}he.value==="task"&&(On.value=ue(t,"task_title")??ue(t,"title")??"운영자 주입 작업",qn.value=ue(t,"task_description")??ue(t,"description")??e.summary,Fn.value=ue(t,"task_priority")??ue(t,"priority")??Fn.value);return}e.target_type==="keeper"&&(e.target_id&&(ca.value=e.target_id),Xt.value=ue(t,"message")??e.summary)}function U_(e){Vl({action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.suggested_payload,summary:e.summary})}function H_(e){Vl({action_type:e.action_type,target_type:e.target_type,target_id:e.target_id??null,payload:e.suggested_payload,summary:e.reason}),z("추천 액션 payload를 폼에 채웠습니다","success")}function W_(e,t,n){return!e||!e.target_type||e.target_type==="room"?!0:e.target_type==="team_session"?!!e.target_id&&t.some(s=>s.session_id===e.target_id):e.target_type==="keeper"?!!e.target_id&&n.some(s=>s.name===e.target_id):!0}async function it(e){const t=Ra.value.trim()||"dashboard";try{const n=await yl({actor:t,action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.payload});return n.confirm_required?z("확인 대기열에 올렸습니다","warning"):z(e.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return z(s,"error"),null}}async function Ho(){const e=Yt.value.trim();if(!e)return;await it({action_type:"broadcast",target_type:"room",payload:{message:e},successMessage:"방송을 보냈습니다"})&&(Yt.value="")}async function G_(){await it({action_type:"room_pause",target_type:"room",payload:{reason:ra.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function Yl(){await it({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function J_(){const e=Qt.value.trim();if(!e)return;await it({action_type:"task_inject",target_type:"room",payload:{title:e,description:En.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(jn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(Qt.value="",En.value="")}async function V_(){var l;const e=_e.value,t=nn.value||((l=e==null?void 0:e.sessions[0])==null?void 0:l.session_id)||"";if(!t){z("먼저 세션을 고르세요","warning");return}const n={};if(he.value==="worker_spawn_batch"){const c=Kn.value.trim();if(!c){z("spawn_batch JSON을 먼저 채우세요","warning");return}try{const m=JSON.parse(c);if(Array.isArray(m))n.spawn_batch=m;else if(m&&typeof m=="object"&&Array.isArray(m.spawn_batch))n.spawn_batch=m.spawn_batch;else{z("spawn_batch는 배열 또는 { spawn_batch: [...] } 형태여야 합니다","warning");return}}catch(m){const u=m instanceof Error?m.message:"spawn_batch JSON 파싱에 실패했습니다";z(u,"error");return}await it({action_type:"team_worker_spawn_batch",target_type:"team_session",target_id:t,payload:n,successMessage:"worker 교체 요청을 적용했습니다"})&&(Kn.value="");return}const s=Dn.value.trim();s&&(n.message=s);let a="team_note";he.value==="broadcast"?a="team_broadcast":he.value==="task"&&(a="team_task_inject"),he.value==="task"&&(n.task_title=On.value.trim()||"운영자 주입 작업",n.task_description=qn.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(Fn.value,10)||2),await it({action_type:a,target_type:"team_session",target_id:t,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Dn.value="",he.value==="task"&&(On.value="",qn.value=""))}async function Y_(){var n;const e=_e.value,t=nn.value||((n=e==null?void 0:e.sessions[0])==null?void 0:n.session_id)||"";if(!t){z("먼저 세션을 고르세요","warning");return}await it({action_type:"team_stop",target_type:"team_session",target_id:t,payload:{reason:la.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Q_(){var a;const e=_e.value,t=ca.value||((a=e==null?void 0:e.keepers[0])==null?void 0:a.name)||"",n=Xt.value.trim();if(!t){z("먼저 keeper를 고르세요","warning");return}if(!n)return;await it({action_type:"keeper_message",target_type:"keeper",target_id:t,payload:{message:n},successMessage:`${t}에게 메시지를 보냈습니다`})&&(Xt.value="")}async function Wo(e,t="confirm"){const n=Ra.value.trim()||"dashboard";try{await bl(n,e,t),z(t==="deny"?"승인 대기를 거부했습니다":"확인 실행을 완료했습니다","success")}catch(s){const a=s instanceof Error?s.message:t==="deny"?"승인 대기 거부에 실패했습니다":"확인 실행에 실패했습니다";z(a,"error")}}function Ql(e){switch(e){case"explicit":return"실제 관리 단위";case"hybrid":return"관리 단위 + 자동 보강";case"auto":return"자동 투영";default:return"source unknown"}}function Xl(e){switch(e){case"explicit":return"ok";case"hybrid":return"warn";case"auto":return"warn";default:return"warn"}}function X_(e){switch(e){case"explicit":return"지금 보이는 unit은 실제로 정의된 command-plane 관리 단위입니다.";case"hybrid":return"일부는 실제 관리 단위이고, 비어 있는 부분은 live agent roster를 보고 자동 보강한 구조입니다.";case"auto":return"이 화면은 live agent roster를 command-plane 모양으로 자동 투영한 것입니다. 실제 명령 체계와 1:1로 같다고 보면 안 됩니다.";default:return"이 화면은 managed topology와 effective topology가 섞여 있을 수 있습니다."}}function Z_(e){const t=e.unit.source??"unknown";return t==="explicit"?e.active_operation_count&&e.active_operation_count>0?"실제 관리 단위이며 연결된 작전이 있습니다.":"실제 관리 단위이지만 현재 연결된 작전은 없습니다.":t==="hybrid"?e.active_operation_count&&e.active_operation_count>0?"관리 단위를 기반으로 자동 보강된 구조이며 일부 작전이 연결돼 있습니다.":"관리 단위를 기반으로 자동 보강된 구조이며 현재 실행 연결은 약합니다.":e.active_operation_count&&e.active_operation_count>0?"자동 생성된 구조이지만 이 노드에 연결된 작전 흔적은 있습니다.":"자동 생성된 구조이며 현재 실행 연결은 없습니다."}function Zl({node:e,depth:t=0}){const n=e.roster_live??0,s=e.roster_total??e.unit.roster.length,a=e.active_operation_count??0,o=e.unit.policy,l=e.unit.source??"unknown",c=a>0?`${a}개 작전 연결`:"실행 연결 없음";return i`
    <div class="command-tree-node depth-${Math.min(t,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${e.unit.label}</strong>
            <span class="command-chip">${a_(e.unit.kind)}</span>
            <span class="command-chip ${M(e.health)}">${e.health??"ok"}</span>
            <span class="command-chip ${Xl(l)}">${Ql(l)}</span>
            <span class="command-chip ${a>0?"ok":"warn"}">${c}</span>
            ${o!=null&&o.frozen?i`<span class="command-chip warn">frozen</span>`:null}
            ${o!=null&&o.kill_switch?i`<span class="command-chip bad">kill-switch</span>`:null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${e.unit.unit_id}</span>
            <span>Leader ${e.unit.leader_id??"unassigned"} / ${e.leader_status??"unknown"}</span>
            <span>Roster ${n}/${s}</span>
            <span>Ops ${a}</span>
            <span>Autonomy ${(o==null?void 0:o.autonomy_level)??"n/a"}</span>
          </div>
          <div class="command-card-sub">${Z_(e)}</div>
          ${e.reasons&&e.reasons.length>0?i`<div class="command-tag-row">
                ${e.reasons.map(p=>i`<span class="command-tag warn">${p}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${e.children.length>0?i`<div class="command-tree-children">
            ${e.children.map(p=>i`<${Zl} node=${p} depth=${t+1} />`)}
          </div>`:null}
    </div>
  `}function eg({alert:e}){return i`
    <article class="command-alert ${M(e.severity)}">
      <div class="command-card-head">
        <strong>${e.title??e.kind??e.alert_id}</strong>
        <span class="command-chip ${M(e.severity)}">${e.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${e.scope_type??"scope"}:${e.scope_id??"n/a"}</span>
        <span>${Y(e.timestamp)}</span>
      </div>
      ${e.detail?i`<p>${e.detail}</p>`:null}
    </article>
  `}function lo({event:e}){return i`
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
      <pre class="command-trace-detail">${oa(e.detail)}</pre>
    </article>
  `}function tg(){const e=je.value,t=e==null?void 0:e.topology,n=t==null?void 0:t.source,s=t==null?void 0:t.summary,a=(s==null?void 0:s.managed_unit_count)??0,o=(s==null?void 0:s.active_operation_count)??0;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${q} panelId="command.topology" compact=${!0} />
      </div>
      ${e?i`
            <div class="command-topology-explainer">
              <div class="command-tree-title-row">
                <span class="command-chip ${Xl(n)}">${Ql(n)}</span>
                <span class="command-chip">${a} managed</span>
                <span class="command-chip ${o>0?"ok":"warn"}">${o} active ops</span>
              </div>
              <p>${X_(n)}</p>
            </div>
          `:null}
      ${e&&e.topology.units.length>0?i`${e.topology.units.map(l=>i`<${Zl} node=${l} />`)}`:i`<div class="empty-state">지금은 live agent나 managed unit 기준으로 그릴 지휘 계층이 없습니다.</div>`}
    </section>
  `}function ng(){const e=je.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${q} panelId="command.alerts" compact=${!0} />
      </div>
      ${e&&e.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${e.alerts.alerts.map(t=>i`<${eg} alert=${t} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function sg(){const e=je.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${q} panelId="command.trace" compact=${!0} />
      </div>
      ${e&&e.traces.events.length>0?i`<div class="command-trace-stack">
            ${e.traces.events.map(t=>i`<${lo} event=${t} />`)}
          </div>`:i`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function ag(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e,null,2)}catch{return String(e)}}function ig(e,t){return(t==null?void 0:t.status)==="abandoned"||(e==null?void 0:e.recommended_kind)==="continue"?"warn":(e==null?void 0:e.recommended_kind)==="rerun"?"bad":"ok"}function og(e){switch(e){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(e==null?void 0:e.trim())||"결정"}}function ec({swarm:e}){var _,f;const t=e.run_id,n=e.resolution_recommendation,s=e.run_resolution;if(!t||!n&&!s)return null;const a=Hl()??"dashboard",o=((_=_e.value)==null?void 0:_.pending_confirms.find($=>$.target_type==="swarm_run"&&$.target_id===t))??null,l=ig(n,s),c=((f=e.operation)==null?void 0:f.operation_id)??e.operation_id??void 0,p={run_id:t};c&&(p.operation_id=c),n!=null&&n.reason&&(p.reason=n.reason);const m=async $=>{await yl({actor:a,action_type:$,target_type:"swarm_run",target_id:t,payload:p})},u=async $=>{o&&await bl(a,o.confirm_token,$)};return i`
    <article class="command-guide-card ${M(l)}">
      <div class="command-guide-head">
        <strong>Run Resolution</strong>
        <span class="command-chip ${M(l)}">
          ${og((s==null?void 0:s.status)??(n==null?void 0:n.recommended_kind)??null)}
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
      ${n!=null&&n.evidence?i`
            <div class="command-tag-row">
              <span class="command-tag">joined ${n.evidence.joined_workers??0}</span>
              <span class="command-tag">trace ${n.evidence.trace_events??0}</span>
              <span class="command-tag">message ${n.evidence.message_events??0}</span>
              ${n.evidence.runtime_blocker?i`<span class="command-tag ${M("bad")}">${n.evidence.runtime_blocker}</span>`:null}
            </div>
          `:null}
      ${o?i`
            <div class="command-guide-card warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip warn">${o.confirm_token}</span>
              </div>
              ${o.preview?i`<pre class="command-trace-detail">${ag(o.preview)}</pre>`:null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${()=>{u("confirm")}} disabled=${H.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${()=>{u("deny")}} disabled=${H.value}>취소</button>
              </div>
            </div>
          `:n?i`
              <div class="command-action-row">
                ${n.continue_available?i`<button class="control-btn ghost" onClick=${()=>{m("swarm_run_continue")}} disabled=${H.value}>Continue</button>`:null}
                ${n.rerun_available?i`<button class="control-btn" onClick=${()=>{m("swarm_run_rerun")}} disabled=${H.value}>Rerun</button>`:null}
                ${n.abandon_available?i`<button class="control-btn ghost" onClick=${()=>{m("swarm_run_abandon")}} disabled=${H.value}>Abandon</button>`:null}
              </div>
            `:null}
    </article>
  `}function tc(e){return e.motion_state==="stalled"||e.hard_flags.some(t=>t.severity==="bad")?"bad":e.motion_state==="waiting"||e.hard_flags.some(t=>t.severity==="warn")?"warn":"ok"}function nc({lanes:e}){const t={moving:0,waiting:0,stalled:0,terminal:0};for(const a of e){const o=a.motion_state;o in t?t[o]++:t.waiting++}if(e.length===0)return null;const s=[{key:"moving",count:t.moving,color:"var(--ok)"},{key:"waiting",count:t.waiting,color:"var(--warn)"},{key:"stalled",count:t.stalled,color:"var(--bad)"},{key:"terminal",count:t.terminal,color:"#556"}];return i`
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
  `}function rg({total:e}){const n=Math.min(e,20),s=e>20?e-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${e})</span>
    </div>
  `}function lg({lane:e}){const t=e.counts??{},n=tc(e),s=t.workers??0,a=t.operations??0,o=t.detachments??0,l=a+o,c=e.motion_state==="moving"?84:e.motion_state==="waiting"?58:e.motion_state==="terminal"?100:26;return i`
    <article class="swarm-lane-strip ${M(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${e.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${e.kind} · ${e.source_of_truth}</span>
            <strong>${e.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${M(n)}">${e.phase}</span>
          <span class="command-chip ${M(n)}">${e.motion_state}</span>
          <span class="command-chip">${Y(e.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${e.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${M(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${e.current_step}</span>
        </div>
        ${s>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${rg} total=${s} />
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
              ${e.hard_flags.map(p=>i`<span class="command-chip ${M(p.severity)}">${p.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function sc({lanes:e}){const t=e.slice(0,4);return t.length===0?null:i`
    <div class="swarm-storyboard">
      ${t.map(n=>{const s=tc(n),a=n.counts.workers??0,o=n.counts.operations??0,l=n.counts.detachments??0;return i`
          <article class="swarm-story-card ${M(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${M(s)}">${n.motion_state}</span>
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
  `}function cg({event:e}){const t=e.timestamp?new Date(e.timestamp):null,n=t&&!isNaN(t.getTime())?t:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${M(e.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${e.title}</strong>
        <span class="swarm-event-kind">${e.kind}</span>
        ${e.detail?i`<div class="command-card-sub">${e.detail}</div>`:null}
      </div>
    </div>
  `}function dg({gap:e}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${M(e.severity)}">${e.code} (${e.count})</span>
      <span class="command-card-sub">${e.summary}</span>
    </div>
  `}function ug({proof:e}){const t=(e==null?void 0:e.status)==="missing"?"warn":(e==null?void 0:e.pass)===!1?"bad":(e==null?void 0:e.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${M(t)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${M(t)}">${(e==null?void 0:e.status)??"missing"}</span>
        </div>
      ${e?i`
            <div class="command-card-grid">
              <span>소스</span><span>${e.source}</span>
              <span>런</span><span>${e.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${Y(e.captured_at)}</span>
              <span>통과</span><span>${e.pass==null?"n/a":e.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${e.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${e.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${e.workers.expected??"n/a"} 예상 · ${e.workers.done??"n/a"} 완료 · ${e.workers.final??"n/a"} 최종</span>
            </div>
            ${e.artifact_ref?i`<div class="command-card-foot">${e.artifact_ref}</div>`:null}
            ${e.missing_reason?i`<p>${e.missing_reason}</p>`:null}
          `:i`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function pg(){const e=ts(),t=Yn(F.value),n=r_(t),s=e==null?void 0:e.swarm_status,a=e==null?void 0:e.swarm_proof,o=(s==null?void 0:s.lanes.filter(_=>_.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],p=s==null?void 0:s.overview,m=s==null?void 0:s.recommended_next_action,u=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${q} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${sc} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(p==null?void 0:p.active_lanes)??0}</strong><small>${(p==null?void 0:p.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(p==null?void 0:p.stalled_lanes)??0}</strong><small>${(p==null?void 0:p.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${Y(p==null?void 0:p.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${Y(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${nc} lanes=${o} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(_=>i`<${lg} lane=${_} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${ug} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${M(l.some(_=>_.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?i`<div class="swarm-event-rail">${l.slice(0,4).map(_=>i`<${dg} gap=${_} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?i`<div class="swarm-event-rail">${c.map(_=>i`<${cg} event=${_} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function mg({item:e}){return i`
    <article class="command-guide-card ${M(e.status)}">
      <div class="command-guide-head">
        <strong>${e.title}</strong>
        <span class="command-chip ${M(e.status)}">${e.status}</span>
      </div>
      <p>${e.detail}</p>
      <div class="command-card-foot">Next tool: ${e.next_tool}</div>
    </article>
  `}function ac({blocker:e}){return i`
    <article class="command-alert ${M(e.severity)}">
      <div class="command-card-head">
        <strong>${e.title}</strong>
        <span class="command-chip ${M(e.severity)}">${e.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${e.code}</span>
        <span>next ${e.next_tool}</span>
      </div>
      <p>${e.detail}</p>
    </article>
  `}function vg({worker:e}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.name}</strong>
          <div class="command-card-sub">${e.role} · ${e.lane}</div>
        </div>
        <span class="command-chip ${M(e.joined?e.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${e.last_message?i`<div class="command-card-foot">${Y(e.last_message.timestamp)} · ${e.last_message.content}</div>`:null}
    </article>
  `}function _g(){var p,m,u,_,f,$,S,h,C,x,k,N,R,P,L,I,w,Q,se,J,ee;const e=It.value,t=l_(),n=Gl(),s=(p=e==null?void 0:e.provider)!=null&&p.runtime_blocker?"blocked":(m=e==null?void 0:e.provider)!=null&&m.provider_reachable?"ready":"check",a=((u=e==null?void 0:e.provider)==null?void 0:u.actual_slots)??((_=e==null?void 0:e.provider)==null?void 0:_.total_slots)??0,o=((f=e==null?void 0:e.provider)==null?void 0:f.expected_slots)??"n/a",l=(($=e==null?void 0:e.provider)==null?void 0:$.actual_ctx)??((S=e==null?void 0:e.provider)==null?void 0:S.ctx_per_slot)??0,c=((h=e==null?void 0:e.provider)==null?void 0:h.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${pg} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${q} panelId="command.swarm" compact=${!0} />
          </div>
          ${na.value?i`<div class="empty-state">Loading swarm live state…</div>`:sa.value?i`<div class="empty-state error">${sa.value}</div>`:e?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${e.run_id??t??"swarm-live"}</strong><small>${e.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((C=e.summary)==null?void 0:C.joined_workers)??0}/${((x=e.summary)==null?void 0:x.expected_workers)??0}</strong><small>${((k=e.summary)==null?void 0:k.live_workers)??0}개 가동 · ${((N=e.summary)==null?void 0:N.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${o} · ctx ${l}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(R=e.summary)!=null&&R.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((P=e.provider)==null?void 0:P.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(L=e.summary)!=null&&L.pass_end_to_end?"통과":"확인 필요"}</strong><small>${e.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((I=e.operation)==null?void 0:I.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((w=e.squad)==null?void 0:w.label)??"없음"}</span>
                      <span>실행체</span><span>${((Q=e.detachment)==null?void 0:Q.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((se=e.summary)==null?void 0:se.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((J=e.summary)==null?void 0:J.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((ee=e.provider)==null?void 0:ee.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${e.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${e.truth_notes.length>0?i`<div class="command-tag-row">
                          ${e.truth_notes.map(A=>i`<span class="command-tag">${A}</span>`)}
                        </div>`:null}
                    <${ec} swarm=${e} />
                  `:i`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${q} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.checklist.length>0?i`<div class="command-card-stack">
                ${e.checklist.map(A=>i`<${mg} item=${A} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${q} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.workers.length>0?i`<div class="command-card-stack">
                ${e.workers.map(A=>i`<${vg} worker=${A} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${q} panelId="command.swarm" compact=${!0} />
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
                  <span>Last Sample</span><span>${e.provider.last_sample_at?Y(e.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${e.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${e.provider.checked_at?Y(e.provider.checked_at):"n/a"}</span>
                </div>
                ${e.provider.detail?i`<div class="command-card-sub">${e.provider.detail}</div>`:null}
                ${e.provider.timeline.length>0?i`<div class="command-trace-stack">
                      ${e.provider.timeline.slice(-12).map(A=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${A.active_slots} active</strong>
                              <span class="command-chip">${Y(A.timestamp)}</span>
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
            <${q} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.blockers.length>0?i`<div class="command-card-stack">
                ${e.blockers.map(A=>i`<${ac} blocker=${A} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(e==null?void 0:e.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${q} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.recent_messages.length>0?i`<div class="command-trace-stack">
                ${e.recent_messages.map(A=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${A.from}</strong>
                        <span class="command-chip">${Y(A.timestamp)}</span>
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
            <${q} panelId="command.trace" compact=${!0} />
          </div>
          ${e&&e.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${e.recent_trace_events.map(A=>i`<${lo} event=${A} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function gg(e){var n;const t=[e.current_task_matches_run?"current":"drift",e.claim_marker_seen?"claim":"no-claim",e.done_marker_seen?"done":"no-done",e.final_marker_seen?"final":"no-final"];return{key:`swarm:${e.name}`,name:e.name,role:e.role,lane:e.lane,status:e.status,source:"swarm",task:e.current_task??e.bound_task_title??e.bound_task_id??"none",heartbeat:e.heartbeat_age_sec!=null?`${Math.round(e.heartbeat_age_sec)}s`:e.heartbeat_fresh?"clean":"n/a",detail:[e.bound_task_status??null,e.detachment_member?"detachment":null,e.squad_member?"squad":null].filter(Boolean).join(" · ")||"live swarm worker",markers:t,note:((n=e.last_message)==null?void 0:n.content)??null}}function fg(e,t){const n=e.actor??e.spawn_role??`worker-${t+1}`,s=e.spawn_role??e.worker_class??e.spawn_agent??"worker",a=e.lane_id??e.capsule_mode??e.control_domain??"session",o=[e.has_turn?"turn":"silent",e.empty_note_turn_count>0?`empty:${e.empty_note_turn_count}`:"noted",e.turn_count>0?`turns:${e.turn_count}`:"turns:0"];return{key:`session:${n}:${t}`,name:n,role:s,lane:a,status:e.status,source:"session",task:e.task_profile??e.runtime_pool??"session lane",heartbeat:e.last_turn_ts_iso?Y(e.last_turn_ts_iso):"n/a",detail:[e.spawn_agent??null,e.spawn_model??null,e.routing_confidence!=null?Zn(e.routing_confidence):null].filter(Boolean).join(" · ")||"session worker",markers:o,note:e.routing_reason??null}}function Go(e){return M(e.severity)}function $g({worker:e}){return i`
    <article class="command-card compact warroom-worker-card ${M(Dt(e.status))}">
      <div class="command-card-head">
        <div>
          <strong>${e.name}</strong>
          <div class="command-card-sub">${e.role} · ${e.lane}</div>
        </div>
        <span class="command-chip ${M(Dt(e.status))}">${e.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Source</span><span>${e.source}</span>
        <span>Task</span><span>${e.task}</span>
        <span>Heartbeat</span><span>${e.heartbeat}</span>
        <span>Detail</span><span>${e.detail}</span>
      </div>
      <div class="command-tag-row">
        ${e.markers.map(t=>i`<span class="command-tag">${t}</span>`)}
      </div>
      ${e.note?i`<div class="command-card-foot">${e.note}</div>`:null}
    </article>
  `}function Ge({label:e,surface:t,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(t){St(t),de("command",{...Ul(t),...n});return}de("intervene")}}
    >
      ${e}
    </button>
  `}function hg(){var ee,A,Ce,He,ut,pt,K,Te,mt,dn,un,ns,ss,as,is,os,rs,ls,go,fo,$o;const e=ts(),t=It.value,n=_e.value,s=Me.value,a=__(),o=t!=null&&t.operation?((ee=Xn.value)==null?void 0:ee.operations.find(V=>{var cs;return V.operation.operation_id===((cs=t.operation)==null?void 0:cs.operation_id)}))??null:null,l=m_(),c=(t==null?void 0:t.workers)??[],p=(s==null?void 0:s.worker_cards)??[],m=l&&c.length>0?c.map(gg):p.map(fg),u=l,_=((A=e==null?void 0:e.decisions.summary)==null?void 0:A.pending)??0,f=(n==null?void 0:n.pending_confirms)??[],$=l?(t==null?void 0:t.blockers)??[]:[],S=(s==null?void 0:s.recommended_actions)??[],h=(Ce=s==null?void 0:s.active_recommended_actions)!=null&&Ce.length?s.active_recommended_actions:S,C=s==null?void 0:s.active_summary,x=(s==null?void 0:s.active_guidance_layer)??"fallback",k=(s==null?void 0:s.resident_judge_runtime)??(n==null?void 0:n.resident_judge_runtime),N=(s==null?void 0:s.attention_items)??[],R=((He=t==null?void 0:t.recent_messages[0])==null?void 0:He.timestamp)??null,P=((ut=t==null?void 0:t.recent_trace_events[0])==null?void 0:ut.timestamp)??null,L=l?R??P??null:null,I=a==null?void 0:a.summary,w=(l?(pt=t==null?void 0:t.summary)==null?void 0:pt.expected_workers:void 0)??(typeof(I==null?void 0:I.planned_worker_count)=="number"?I.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,Q=(l?(K=t==null?void 0:t.summary)==null?void 0:K.joined_workers:void 0)??(typeof(I==null?void 0:I.active_agent_count)=="number"?I.active_agent_count:void 0)??m.length,se=$.length>0||_>0||f.length>0?"warn":u||a?"ok":"warn",J=l?((Te=e==null?void 0:e.swarm_status)==null?void 0:Te.lanes.filter(V=>V.present))??[]:[];return te(()=>{ye()},[]),te(()=>{a!=null&&a.session_id&&tn(a.session_id)},[a==null?void 0:a.session_id,n,(mt=t==null?void 0:t.detachment)==null?void 0:mt.session_id]),!u&&!a?na.value||wn.value?i`<div class="empty-state">live war room 불러오는 중…</div>`:i`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">라이브 워룸</div>
          <${q} panelId="command.warroom" compact=${!0} />
        </div>
        <div class="command-warroom-empty-copy">
          <strong>현재 live run 없음</strong>
          <p>활성 operation 또는 team session이 시작되면 이 화면이 자동으로 붙잡습니다.</p>
        </div>
        <div class="command-action-row">
          <${Ge} label="작전 보기" surface="operations" />
          <${Ge} label="스웜 보기" surface="swarm" />
          <${Ge} label="개입 열기" />
          <${Ge} label="제어 보기" surface="control" />
        </div>
      </section>
    `:i`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${M(se)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">Live War Room</span>
            <strong>${l?((dn=t==null?void 0:t.operation)==null?void 0:dn.objective)??(a==null?void 0:a.session_id)??"active run":(a==null?void 0:a.session_id)??"active run"}</strong>
            <div class="command-card-sub">
              ${l?((un=t==null?void 0:t.operation)==null?void 0:un.operation_id)??"operation 없음":"session truth"}
              ${a!=null&&a.session_id?` · session ${a.session_id}`:""}
              ${l&&((ns=t==null?void 0:t.detachment)!=null&&ns.detachment_id)?` · detachment ${t.detachment.detachment_id}`:""}
            </div>
            ${C!=null&&C.summary?i`<div class="command-warroom-guidance ${ua(x)}">
                  <strong>${io(x)}</strong>
                  <span>${C.summary}</span>
                </div>`:null}
          </div>
          <div class="command-action-row">
            <${Ge}
              label="스웜 상세"
              surface="swarm"
              params=${{...l&&((ss=t==null?void 0:t.operation)!=null&&ss.operation_id)?{operation_id:t.operation.operation_id}:{},...l&&(t!=null&&t.run_id)?{run_id:t.run_id}:{}}}
            />
            <${Ge} label="트레이스" surface="trace" />
            ${l&&o?i`<${Ge}
                  label="체인"
                  surface="chains"
                  params=${{operation:o.operation.operation_id}}
                />`:null}
            <${Ge} label="Intervene" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>Workers</span>
            <strong>${Q??0}/${w??0}</strong>
            <small>${l?((as=t==null?void 0:t.summary)==null?void 0:as.completed_workers)??0:0} 완료 · ${m.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${l?(is=t==null?void 0:t.provider)!=null&&is.runtime_blocker?"blocked":(os=t==null?void 0:t.provider)!=null&&os.provider_reachable?"ready":a?ps(a.status):"check":a?ps(a.status):"check"}</strong>
            <small>${l?`slots ${((rs=t==null?void 0:t.provider)==null?void 0:rs.active_slots_now)??0}/${((ls=t==null?void 0:t.provider)==null?void 0:ls.actual_slots)??((go=t==null?void 0:t.provider)==null?void 0:go.total_slots)??0} · ctx ${((fo=t==null?void 0:t.provider)==null?void 0:fo.actual_ctx)??(($o=t==null?void 0:t.provider)==null?void 0:$o.ctx_per_slot)??0}`:`session workers ${(s==null?void 0:s.worker_cards.length)??0}`}</small>
          </div>
          <div class="monitor-stat-card ${M($.length>0||_>0?"warn":"ok")}">
            <span>Pressure</span>
            <strong>${$.length+_+f.length}</strong>
            <small>blockers ${$.length} · approvals ${_} · confirms ${f.length}</small>
          </div>
          <div class="monitor-stat-card ${M(ua(x))}">
            <span>Resident Judge</span>
            <strong>${oo(k)}</strong>
            <small>${ro(C)}${k!=null&&k.model_used?` · ${k.model_used}`:""}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${Y(L)}</strong>
            <small>${R?"message":P?"trace":"waiting"}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${q} panelId="command.warroom" compact=${!0} />
            </div>
            ${J.length>0?i`
                  <${sc} lanes=${J} />
                  <${nc} lanes=${J} />
                `:a?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${M(Dt(a.status))}">${ps(a.status)}</span>
                      </div>
                      <p>command-plane live run은 아직 옅지만, session 쪽 worker와 digest를 기준으로 워룸을 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${gn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${gn(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 lane이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Worker Roster</div>
              <${q} panelId="command.warroom" compact=${!0} />
            </div>
            ${m.length>0?i`<div class="command-card-stack">
                  ${m.map(V=>i`<${$g} worker=${V} />`)}
                </div>`:i`<div class="empty-state">활성 worker 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Live Feed</div>
              <${q} panelId="command.warroom" compact=${!0} />
            </div>
            ${t&&t.recent_messages.length>0&&l?i`<div class="command-trace-stack">
                  ${t.recent_messages.map(V=>i`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${V.from}</strong>
                          <span class="command-chip">${Y(V.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${V.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${V.content}</pre>
                    </article>
                  `)}
                </div>`:h.length>0||N.length>0?i`<div class="command-card-stack">
                    ${h.slice(0,4).map(V=>i`
                      <article class="command-guide-card ${Go(V)}">
                        <div class="command-guide-head">
                          <strong>${V.action_type}</strong>
                          <span class="command-chip ${Go(V)}">${V.target_type}</span>
                        </div>
                        <p>${V.reason}</p>
                      </article>
                    `)}
                    ${N.slice(0,3).map(V=>i`
                      <article class="command-alert ${M(V.severity)}">
                        <div class="command-card-head">
                          <strong>${V.kind}</strong>
                          <span class="command-chip ${M(V.severity)}">${V.severity}</span>
                        </div>
                        <p>${V.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?i`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((V,cs)=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>session-event-${cs+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${oa(V)}</pre>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">메시지나 attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Trace Feed</div>
              <${q} panelId="command.trace" compact=${!0} />
            </div>
            ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                  ${t.recent_trace_events.map(V=>i`<${lo} event=${V} />`)}
                </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Pressure</div>
              <${q} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&t?i`<${ec} swarm=${t} />`:null}
              ${$.length>0?$.map(V=>i`<${ac} blocker=${V} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${_>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending approvals</strong>
                        <span class="command-chip warn">${_}</span>
                      </div>
                      <p>strict action이 묶여 있습니다. 실제 승인 처리는 control 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${f.length>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending confirms</strong>
                        <span class="command-chip warn">${f.length}</span>
                      </div>
                      <p>operator preview가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${f.slice(0,3).map(V=>i`<span class="command-tag">${V.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
            </div>
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Focus Detail</div>
              <${q} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&(t!=null&&t.operation)?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${t.operation.objective}</strong>
                          <div class="command-card-sub">${t.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${M(Dt(t.operation.status))}">${t.operation.status}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Unit</span><span>${t.operation.assigned_unit_id}</span>
                        <span>Trace</span><span>${t.operation.trace_id}</span>
                        <span>Autonomy</span><span>${t.operation.autonomy_level??"n/a"}</span>
                        <span>Updated</span><span>${Y(t.operation.updated_at)}</span>
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
                        <span class="command-chip ${M(Dt(t.detachment.status))}">${t.detachment.status??"active"}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Leader</span><span>${t.detachment.leader_id??"unassigned"}</span>
                        <span>Roster</span><span>${t.detachment.roster.length}</span>
                        <span>Session</span><span>${t.detachment.session_id??"none"}</span>
                        <span>Heartbeat</span><span>${Fl(t.detachment.heartbeat_deadline)}</span>
                      </div>
                    </article>
                  `:null}
              ${a?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${a.session_id}</strong>
                          <div class="command-card-sub">team session focus</div>
                        </div>
                        <span class="command-chip ${M(Dt(a.status))}">${ps(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${gn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${gn(a.remaining_sec)}</span>
                        <span>Done delta</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function yg({source:e}){const t=Tc(null),[n,s]=cr(null);return te(()=>{let a=!1;const o=t.current;return o?(o.innerHTML="",s(null),(async()=>{try{const c=await Yv(),{svg:p}=await c.render(`command-chain-${Vv()}`,e);if(a||!t.current)return;t.current.innerHTML=p}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid render failed")}})(),()=>{a=!0,t.current&&(t.current.innerHTML="")}):void 0},[e]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${t}></div>
    </div>
  `}function bg({overlay:e,selected:t,onSelect:n}){const s=e.operation.chain,a=e.runtime;return i`
    <button class="command-chain-item ${t?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${e.operation.objective}</strong>
          <div class="command-card-sub">${e.operation.operation_id}</div>
        </div>
        <span class="command-chip ${tt(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??e.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?i`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?i`<span class="command-tag ${tt(s==null?void 0:s.status)}">${Zn(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${Kl(e.history)}</div>
    </button>
  `}function kg({item:e}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${e.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${tt(e.event)}">${e.event}</span>
      </div>
      <div class="command-card-sub">${Y(e.timestamp)}</div>
      <div class="command-card-sub">${Kl(e)}</div>
    </article>
  `}function xg({node:e}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${e.id}</strong>
        <span class="command-chip ${tt(e.status)}">${e.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${e.type??"node"}
        ${typeof e.duration_ms=="number"?` · ${e.duration_ms}ms`:""}
      </div>
      ${e.error?i`<div class="command-card-sub error-text">${e.error}</div>`:null}
    </article>
  `}function Sg({card:e}){const t=e.operation,n=`pause:${t.operation_id}`,s=`resume:${t.operation_id}`,a=`recall:${t.operation_id}`,o=t.chain,l=(o==null?void 0:o.run_id)??null;return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${t.objective}</strong>
          <div class="command-card-sub">${t.operation_id}</div>
        </div>
        <span class="command-chip ${M(t.status==="active"?"ok":t.status==="paused"?"warn":t.status==="failed"?"bad":"ok")}">${t.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${e.assigned_unit_label??t.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Autonomy</span><span>${t.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${t.budget_class??"standard"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Updated</span><span>${Y(t.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${tt(o.status)}">${o.status}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">run ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${t.checkpoint_ref?i`<div class="command-card-foot">Checkpoint ${t.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{St("swarm"),de("command",{surface:"swarm",operation_id:t.operation_id,...l?{run_id:l}:{}})}}
        >
          Swarm Live
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{no(t.operation_id),St("chains"),de("command",{surface:"chains",operation:t.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="active"?i`
              <button class="control-btn ghost" disabled=${ae(n)} onClick=${()=>nt(()=>Ov(t.operation_id))}>
                ${ae(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${ae(a)} onClick=${()=>nt(()=>Fv(t.operation_id))}>
                ${ae(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="paused"?i`
              <button class="control-btn ghost" disabled=${ae(s)} onClick=${()=>nt(()=>qv(t.operation_id))}>
                ${ae(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function Ag({card:e}){var n;const t=e.detachment;return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.detachment_id}</strong>
          <div class="command-card-sub">${((n=e.operation)==null?void 0:n.objective)??t.operation_id}</div>
        </div>
        <span class="command-chip ${M(t.status)}">${t.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${e.assigned_unit_label??t.assigned_unit_id}</span>
        <span>Leader</span><span>${t.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${t.roster.length}</span>
        <span>Session</span><span>${t.session_id??"none"}</span>
        <span>Runtime</span><span>${t.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${t.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${Y(t.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Fl(t.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Y(t.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${t.heartbeat_deadline?i`<span class="command-tag ${Gv(t.heartbeat_deadline)}">
              deadline ${t.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function Cg(){const e=je.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${q} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.operations.operations.length>0?i`<div class="command-card-stack">
              ${e.operations.operations.map(t=>i`<${Sg} card=${t} />`)}
            </div>`:i`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${q} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${e.detachments.detachments.map(t=>i`<${Ag} card=${t} />`)}
            </div>`:i`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function Tg(){var c,p,m,u,_,f,$,S,h,C,x,k,N,R,P,L;const e=Xn.value,t=(e==null?void 0:e.operations)??[],n=Jt.value,s=t.find(I=>I.operation.operation_id===n)??t[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,o=((p=zn.value)==null?void 0:p.run)??(s==null?void 0:s.preview_run)??null,l=!((m=zn.value)!=null&&m.run)&&!!(s!=null&&s.preview_run);return te(()=>{a?jv(a):Ev()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${q} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${tt(e==null?void 0:e.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${tt(e==null?void 0:e.connection.status)}">${(e==null?void 0:e.connection.status)??"disconnected"}</span>
          </div>
          <p>${(e==null?void 0:e.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(e==null?void 0:e.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((u=e==null?void 0:e.summary)==null?void 0:u.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((_=e==null?void 0:e.summary)==null?void 0:_.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((f=e==null?void 0:e.summary)==null?void 0:f.recent_failures)??0}</span>
            <span>Last Event</span><span>${Y(($=e==null?void 0:e.summary)==null?void 0:$.last_history_event_at)}</span>
          </div>
        </article>

        ${aa.value?i`<div class="empty-state error">${aa.value}</div>`:null}

        ${Ii.value&&!e?i`<div class="empty-state">Loading chain overlays…</div>`:t.length>0?i`
                <div class="command-chain-list">
                  ${t.map(I=>i`
                    <${bg}
                      overlay=${I}
                      selected=${(s==null?void 0:s.operation.operation_id)===I.operation.operation_id}
                      onSelect=${()=>no(I.operation.operation_id)}
                    />
                  `)}
                </div>
              `:i`<div class="empty-state">No chain-backed operations yet.</div>`}

        <div class="command-chain-history">
          <div class="command-guide-head">
            <strong>Recent history</strong>
            <span class="command-chip">${(e==null?void 0:e.recent_history.length)??0}</span>
          </div>
          ${e&&e.recent_history.length>0?i`
                <div class="command-card-stack">
                  ${e.recent_history.slice(0,6).map(I=>i`<${kg} item=${I} />`)}
                </div>
              `:i`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${q} panelId="command.chains" compact=${!0} />
        </div>
        ${s?i`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${tt((S=s.operation.chain)==null?void 0:S.status)}">
                    ${((h=s.operation.chain)==null?void 0:h.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((C=s.operation.chain)==null?void 0:C.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((x=s.operation.chain)==null?void 0:x.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${Zn((k=s.runtime)==null?void 0:k.progress)}</span>
                  <span>Elapsed</span><span>${gn((N=s.runtime)==null?void 0:N.elapsed_sec)}</span>
                  <span>Updated</span><span>${Y(((R=s.operation.chain)==null?void 0:R.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(P=s.operation.chain)!=null&&P.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((L=s.operation.chain)==null?void 0:L.chain_id)??"graph"}</span>
                      </div>
                      <${yg} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":l?"preview":"captured":"pending"}
                  </span>
                </div>
                ${ia.value?i`<div class="empty-state">Loading run detail…</div>`:Mn.value?i`<div class="empty-state error">${Mn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${l?i`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(I=>i`<${xg} node=${I} />`)}
                          </div>
                        `:i`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:i`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function Ig({decision:e}){const t=`approve:${e.decision_id}`,n=`deny:${e.decision_id}`,s=e.source==="projected_operator";return i`
    <article class="command-card ${M(e.status)}">
      <div class="command-card-head">
        <div>
          <strong>${e.requested_action}</strong>
          <div class="command-card-sub">${e.scope_type}:${e.scope_id}</div>
        </div>
        <span class="command-chip ${M(e.status)}">${e.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${e.decision_id}</span>
        <span>By</span><span>${e.requested_by??"unknown"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Created</span><span>${Y(e.created_at)}</span>
        <span>Reason</span><span>${e.reason??"n/a"}</span>
      </div>
      ${e.status==="pending"&&!s?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${ae(t)} onClick=${()=>nt(()=>Bv(e.decision_id))}>
                ${ae(t)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${ae(n)} onClick=${()=>nt(()=>Uv(e.decision_id))}>
                ${ae(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function Rg({row:e}){var c,p,m;const t=e.unit,n=`freeze:${t.unit_id}`,s=`kill:${t.unit_id}`,a=!!((c=t.policy)!=null&&c.frozen),o=!!((p=t.policy)!=null&&p.kill_switch),l=Math.round((e.utilization??0)*100);return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.label}</strong>
          <div class="command-card-sub">${t.unit_id}</div>
        </div>
        <span class="command-chip ${M(l>100?"bad":l>70?"warn":"ok")}">${l}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${e.roster_live??0}/${e.roster_total??0}</span>
        <span>Headcount Cap</span><span>${e.headcount_cap??0}</span>
        <span>Ops</span><span>${e.active_operations??0}/${e.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((m=t.policy)==null?void 0:m.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${a?"yes":"no"}</span>
        <span>Kill Switch</span><span>${o?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${ae(n)} onClick=${()=>nt(()=>Hv(t.unit_id,!a))}>
          ${ae(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${ae(s)} onClick=${()=>nt(()=>Wv(t.unit_id,!o))}>
          ${ae(s)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function Pg(){const e=je.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${q} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${e.decisions.decisions.map(t=>i`<${Ig} decision=${t} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${q} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${e.capacity.capacity.map(t=>i`<${Rg} row=${t} />`)}
            </div>`:i`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function Lg(){return i`
    <div class="command-surface-tabs grouped">
      ${Xv.map(e=>i`
        <div class="command-tab-group" key=${e.id}>
          <span class="command-tab-group-label">${e.label}</span>
          <div class="command-tab-group-items">
            ${Bl.filter(t=>t.group===e.id).map(t=>i`
                <button
                  class="command-surface-tab ${Z.value===t.id?"active":""}"
                  onClick=${()=>{St(t.id),de("command",Ul(t.id))}}
                >
                  ${t.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function wg(){if(Z.value==="warroom")return i`<${hg} />`;if(Z.value==="summary")return i`<${N_} />`;if(Z.value==="swarm")return i`<${_g} />`;if(!je.value)return i`<${z_} />`;switch(Z.value){case"chains":return i`<${Tg} />`;case"topology":return i`<${tg} />`;case"alerts":return i`<${ng} />`;case"trace":return i`<${sg} />`;case"control":return i`<${Pg} />`;case"operations":default:return i`<${Cg} />`}}function Ng(){return te(()=>{jt(),Vt(),Dv(),Ve()},[]),te(()=>{if(F.value.tab!=="command")return;const e=F.value.params.surface,t=F.value.params.operation,n=Yn(F.value);if(Fo(e))St(e);else if(n){const s=ol(n);Fo(s)&&St(s)}else e||St("warroom");t&&no(t),(e==="swarm"||e==="warroom"||Z.value==="warroom")&&Ve(),(e==="warroom"||Z.value==="warroom")&&ye()},[F.value.tab,F.value.params.surface,F.value.params.operation,F.value.params.operation_id,F.value.params.run_id,F.value.params.source,F.value.params.action_type,F.value.params.target_type,F.value.params.target_id,F.value.params.focus_kind]),te(()=>{let e=null;const t=()=>{e||(e=window.setTimeout(()=>{e=null,jt(),Vt(),(Z.value==="swarm"||Z.value==="warroom")&&Ve(),Z.value==="warroom"&&ye()},250))},n=new EventSource(s_()),s=e_.map(a=>{const o=()=>t();return n.addEventListener(a,o),{type:a,handler:o}});return n.onerror=()=>{t()},()=>{s.forEach(({type:a,handler:o})=>{n.removeEventListener(a,o)}),n.close(),e&&window.clearTimeout(e)}},[]),te(()=>{const e=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const t=Z.value;t!=="swarm"&&t!=="warroom"||(jt(),Ve(),t==="warroom"&&ye())},5e3);return()=>{window.clearInterval(e)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{nt(()=>Kv())}}
            disabled=${ae("dispatch:tick")}
          >
            ${ae("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{jt(),Vt(),Ve(),Z.value==="warroom"&&ye()}}
            disabled=${Ys.value}
          >
            ${Ys.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Xs.value?i`<div class="empty-state error">${Xs.value}</div>`:null}
      ${ea.value?i`<div class="empty-state error">${ea.value}</div>`:null}
      <${be} surfaceId="command" />
      <${I_} />
      ${Z.value==="warroom"?null:i`<${R_} />`}
      <${Lg} />
      <${wg} />
    </section>
  `}function zg(){var C,x;const e=_e.value,t=Qi.value,n=(e==null?void 0:e.room)??{},s=(e==null?void 0:e.pending_confirms)??[],a=e==null?void 0:e.pending_confirm_summary,o=a?a.confirm_required_actions:((e==null?void 0:e.available_actions)??[]).filter(k=>k.confirm_required),l=((C=a==null?void 0:a.actor_filter)==null?void 0:C.trim())||null,c=(a==null?void 0:a.hidden_count)??0,p=(a==null?void 0:a.hidden_actors)??[],m=(e==null?void 0:e.recent_messages)??[],u=(t==null?void 0:t.recommended_actions)??[],_=(x=t==null?void 0:t.active_recommended_actions)!=null&&x.length?t.active_recommended_actions:u,f=t==null?void 0:t.active_summary,$=(t==null?void 0:t.resident_judge_runtime)??(e==null?void 0:e.resident_judge_runtime),S=(t==null?void 0:t.active_guidance_layer)??"fallback",h=m.slice(0,5);return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Room 개입</div>
          <${q} panelId="intervene.action_studio" compact=${!0} />
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
          <div class="ops-stat ${j_($)}">
            <span>Resident Judge</span>
            <strong>${oo($)}</strong>
          </div>
        </div>

        <label class="control-label" for="ops-broadcast">Room 방송</label>
        <div class="control-row">
          <input
            id="ops-broadcast"
            class="control-input"
            type="text"
            placeholder="@agent 또는 room 전체 공지"
            value=${Yt.value}
            onInput=${k=>{Yt.value=k.target.value}}
            onKeyDown=${k=>{k.key==="Enter"&&Ho()}}
            disabled=${H.value}
          />
          <button class="control-btn" onClick=${()=>{Ho()}} disabled=${H.value||Yt.value.trim()===""}>
            보내기
          </button>
        </div>

        <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
        <div class="control-row ops-split-row">
          <input
            id="ops-pause-reason"
            class="control-input"
            type="text"
            value=${ra.value}
            onInput=${k=>{ra.value=k.target.value}}
            disabled=${H.value}
          />
          <button class="control-btn ghost" onClick=${()=>{G_()}} disabled=${H.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{Yl()}} disabled=${H.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${Qt.value}
          onInput=${k=>{Qt.value=k.target.value}}
          disabled=${H.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${En.value}
          onInput=${k=>{En.value=k.target.value}}
          disabled=${H.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${jn.value}
            onChange=${k=>{jn.value=k.target.value}}
            disabled=${H.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{J_()}} disabled=${H.value||Qt.value.trim()===""}>
            주입
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">추천 개입</div>
          <${q} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
        <article class="ops-guidance-card ${ua(S)}">
          <div class="ops-guidance-head">
            <strong>${io(S)}</strong>
            <span>${($==null?void 0:$.keeper_name)??(t==null?void 0:t.judgment_owner)??"judge 없음"}</span>
          </div>
          <div class="ops-guidance-body">
            ${(f==null?void 0:f.summary)??"현재 active guidance 요약이 없습니다. fallback queue만 표시합니다."}
          </div>
          <div class="ops-guidance-meta">
            <span>authoritative ${t!=null&&t.authoritative_judgment_available?"yes":"no"}</span>
            <span>${ro(f)}</span>
            ${$!=null&&$.model_used?i`<span>${$.model_used}</span>`:null}
          </div>
        </article>
        ${Nn.value&&!t?i`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:_.length>0?i`
          <div class="ops-log-list">
            ${_.map(k=>i`
              <article key=${`${k.action_type}:${k.target_type}:${k.target_id??"room"}`} class="ops-log-entry ${k.severity}">
                <div class="ops-log-head">
                  <strong>${At(k.action_type)}</strong>
                  <span>${Zt(k.target_type)}${k.target_id?` · ${k.target_id}`:""}</span>
                  <span>${pa(k.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${k.reason}</div>
                ${k.suggested_payload?i`
                  <div class="ops-confirmation-actions">
                    <button class="control-btn ghost" onClick=${()=>{H_(k)}} disabled=${H.value}>
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
          <${q} panelId="intervene.pending_confirmations" compact=${!0} />
        </div>
        <p class="ops-context-note">
          ${l?`현재 actor ${l} 기준 queue를 읽습니다. 승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다.`:"승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다."}
        </p>
        ${o.length>0?i`
          <div class="ops-log-list">
            ${o.map(k=>i`
              <article key=${`${k.action_type}:${k.target_type}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${At(k.action_type)}</strong>
                  <span>${Zt(k.target_type)}</span>
                  <span>${pa(k.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${k.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}
        ${s.length>0?i`
          <div class="ops-confirmation-list">
            ${s.map(k=>i`
              <article key=${k.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${At(k.action_type)}</strong>
                  <span>${Zt(k.target_type)}${k.target_id?` · ${k.target_id}`:""}</span>
                  <span>${k.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${k.preview?i`<pre class="ops-code-block compact">${da(k.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{Wo(k.confirm_token)}} disabled=${H.value}>
                    실행
                  </button>
                  <button class="control-btn ghost" onClick=${()=>{Wo(k.confirm_token,"deny")}} disabled=${H.value}>
                    거부
                  </button>
                  <span class="ops-token">${k.confirm_token}</span>
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
          <${q} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${h.length>0?i`
          <div class="ops-feed-list">
            ${h.map(k=>i`
              <article key=${k.seq??k.id??k.timestamp} class="ops-feed-item">
                <div class="ops-feed-meta">
                  <strong>${k.from}</strong>
                  <span>${k.timestamp}</span>
                </div>
                <div class="ops-feed-content">${k.content}</div>
              </article>
            `)}
          </div>
        `:i`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
      </section>
    </div>
  `}function Mg(){var m;const e=_e.value,t=Me.value,n=(e==null?void 0:e.sessions)??[],s=((e==null?void 0:e.available_actions)??[]).filter(u=>u.target_type==="team_session"),a=n.find(u=>u.session_id===nn.value)??n[0]??null,o=t==null?void 0:t.active_summary,l=(t==null?void 0:t.active_guidance_layer)??"fallback",c=(t==null?void 0:t.resident_judge_runtime)??(e==null?void 0:e.resident_judge_runtime),p=(m=t==null?void 0:t.active_recommended_actions)!=null&&m.length?t.active_recommended_actions:(t==null?void 0:t.recommended_actions)??[];return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${q} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(u=>{var _;return i`
            <button
              key=${u.session_id}
              class="ops-entity-card ${(a==null?void 0:a.session_id)===u.session_id?"active":""}"
              onClick=${()=>{nn.value=u.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${u.session_id}</strong>
                <span class="status-badge ${u.status??"idle"}">${Ot(u.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(u.progress_pct??0)}%</span>
                <span>${u.done_delta_total??0}건 완료</span>
                <span>${(_=u.team_health)!=null&&_.status?Ot(String(u.team_health.status)):"상태 확인 필요"}</span>
              </div>
            </button>
          `})}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Session 요약</div>
          <${q} panelId="intervene.session_digest" compact=${!0} />
        </div>
        <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
        ${a&&t?i`
          <article class="ops-guidance-card ${ua(l)}">
            <div class="ops-guidance-head">
              <strong>${io(l)}</strong>
              <span>${oo(c)}</span>
            </div>
            <div class="ops-guidance-body">
              ${(o==null?void 0:o.summary)??"현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다."}
            </div>
            <div class="ops-guidance-meta">
              <span>authoritative ${t.authoritative_judgment_available?"yes":"no"}</span>
              <span>${ro(o)}</span>
              ${c!=null&&c.model_used?i`<span>${c.model_used}</span>`:null}
            </div>
          </article>
          ${p.length>0?i`
            <div class="ops-log-list">
              ${p.map(u=>i`
                <article key=${`${u.action_type}:${u.target_type}:${u.target_id??"session"}`} class="ops-log-entry ${u.severity}">
                  <div class="ops-log-head">
                    <strong>${At(u.action_type)}</strong>
                    <span>${Zt(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
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
                  <span>${Zt(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${u.summary}</div>
              </article>
            `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${t.worker_cards.length>0?t.worker_cards.map(u=>i`
              <article key=${`${u.actor??u.spawn_role??"worker"}:${u.spawn_agent??u.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${u.actor??u.spawn_role??"worker"}</strong>
                  <span>${Ot(u.status)}</span>
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
          <${q} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>
        ${s.length>0?i`
          <div class="ops-log-list">
            ${s.map(u=>i`
              <article key=${u.action_type} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${At(u.action_type)}</strong>
                  <span>${pa(u.confirm_required)}</span>
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
              <span>상태: ${Ot(a.status)}</span>
              <span>경과: ${a.elapsed_sec??0}초</span>
              <span>남은 시간: ${a.remaining_sec??0}초</span>
            </div>
            ${a.recent_events&&a.recent_events.length>0?i`
              <pre class="ops-code-block compact">${da(a.recent_events.slice(-3))}</pre>
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
            disabled=${H.value||!a}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
            <option value="worker_spawn_batch">worker 교체</option>
          </select>
          <button class="control-btn" onClick=${()=>{V_()}} disabled=${H.value||!a}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${F_(he.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${Dn.value}
          onInput=${u=>{Dn.value=u.target.value}}
          disabled=${H.value||!a}
        ></textarea>

        ${he.value==="task"?i`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${On.value}
            onInput=${u=>{On.value=u.target.value}}
            disabled=${H.value||!a}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${qn.value}
            onInput=${u=>{qn.value=u.target.value}}
            disabled=${H.value||!a}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${Fn.value}
            onChange=${u=>{Fn.value=u.target.value}}
            disabled=${H.value||!a}
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
            value=${Kn.value}
            onInput=${u=>{Kn.value=u.target.value}}
            disabled=${H.value||!a}
          ></textarea>
        `:null}

        <div class="control-row ops-split-row">
          <input
            class="control-input"
            type="text"
            value=${la.value}
            onInput=${u=>{la.value=u.target.value}}
            disabled=${H.value||!a}
          />
          <button class="control-btn ghost" onClick=${()=>{Y_()}} disabled=${H.value||!a}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function Eg(){var o;const e=_e.value,t=(e==null?void 0:e.keepers)??[],n=(e==null?void 0:e.persistent_agents)??[],s=(e==null?void 0:e.available_actions)??[],a=t.find(l=>l.name===ca.value)??t[0]??null;return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${q} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${t.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:t.map(l=>i`
            <button
              key=${l.name}
              class="ops-entity-card ${(a==null?void 0:a.name)===l.name?"active":""}"
              onClick=${()=>{ca.value=l.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${l.name}</strong>
                <span class="status-badge ${l.status??"idle"}">${Ot(l.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${l.model??"model 확인 필요"}</span>
                <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${Bo(l.last_turn_ago_s)}</span>
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
                    <span class="status-badge ${l.status??"idle"}">${Ot(l.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>persistent</span>
                    <span>${l.model??"model 확인 필요"}</span>
                    <span>${Bo(l.last_turn_ago_s)}</span>
                  </div>
                </article>
              `)}
        </div>
      </section>

      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Keeper 액션</div>
          <${q} panelId="intervene.action_studio" compact=${!0} />
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
          value=${Xt.value}
          onInput=${l=>{Xt.value=l.target.value}}
          disabled=${H.value||!a}
        ></textarea>
        <div class="control-row">
          <button class="control-btn" onClick=${()=>{Q_()}} disabled=${H.value||!a||Xt.value.trim()===""}>
            keeper에 보내기
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">가능한 액션 목록</div>
          <${q} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
        <div class="ops-log-list">
          ${s.length?s.map(l=>i`
                <article key=${`${l.action_type}:${l.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${At(l.action_type)}</strong>
                    <span>${Zt(l.target_type)}</span>
                    <span>${pa(l.confirm_required)}</span>
                  </div>
                  <div class="ops-log-body">${l.description??"설명이 아직 없습니다."}</div>
                </article>
              `):i`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 개입 로그</div>
          <${q} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <div class="ops-log-list">
          ${Js.value.length===0?i`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:Js.value.map(l=>i`
            <article key=${l.id} class="ops-log-entry ${l.outcome}">
              <div class="ops-log-head">
                <strong>${At(l.action_type)}</strong>
                <span>${l.target_label}</span>
                <span>${l.at}</span>
              </div>
              <div class="ops-log-body">${l.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function jg(){var R,P,L;const e=_e.value,t=F.value.tab==="intervene"?Yn(F.value):null,n=Qi.value,s=(e==null?void 0:e.room)??{},a=(e==null?void 0:e.sessions)??[],o=(e==null?void 0:e.keepers)??[],l=(e==null?void 0:e.pending_confirms)??[],c=e==null?void 0:e.pending_confirm_summary,p=(c==null?void 0:c.visible_count)??l.length,m=(c==null?void 0:c.total_count)??l.length,u=(c==null?void 0:c.hidden_count)??0,_=((R=c==null?void 0:c.actor_filter)==null?void 0:R.trim())||null,f=a.find(I=>I.session_id===nn.value)??a[0]??null,$=(n==null?void 0:n.attention_items)??[],S=$.filter(O_),h=$.filter(q_),C=a.filter(I=>D_(I)!=="ok"),x=o.filter(I=>Fa(I)!=="ok"),k=W_(t,a,o);te(()=>{Ct()},[]),te(()=>{if(F.value.tab!=="intervene"){gs.value=null;return}if(!t){gs.value=null;return}gs.value!==t.id&&(gs.value=t.id,U_(t))},[F.value.tab,F.value.params.source,F.value.params.action_type,F.value.params.target_type,F.value.params.target_id,F.value.params.focus_kind,t==null?void 0:t.id]),te(()=>{const I=(f==null?void 0:f.session_id)??null;tn(I)},[f==null?void 0:f.session_id]);const N=[{key:"room",label:"Room 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:u>0?`${p}/${m}`:p,detail:p>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":u>0&&_?`현재 actor(${_}) 기준으로는 비어 있고, 다른 actor 대기 ${u}건이 있습니다`:"지금 막혀 있는 확인 대기는 없습니다",tone:m>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:S.length>0?S.length:a.length,detail:S.length>0?((P=S[0])==null?void 0:P.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:S.length>0?Uo(S):a.length===0?"warn":C.some(I=>sn(I.status)==="paused")?"bad":C.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:h.length>0?h.length:x.length,detail:h.length>0?((L=h[0])==null?void 0:L.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":x.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:h.length>0?Uo(h):x.some(I=>Fa(I)==="bad")?"bad":x.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${be} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">Intervene</div>
            <${q} panelId="intervene.action_studio" compact=${!0} />
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
            value=${Ra.value}
            onInput=${I=>E_(I.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{ye(),Ct(),tn((f==null?void 0:f.session_id)??null)}}
            disabled=${wn.value||H.value}
          >
            ${wn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${at.value?i`<section class="ops-banner error">${at.value}</section>`:null}
      ${en.value?i`<section class="ops-banner error">${en.value}</section>`:null}
      ${t?i`
        <section class="ops-banner ${k?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${t.source_label}</strong>
            <span>${Aa(t.action_type)}</span>
            <span>${Ji(t)}</span>
          </div>
          <div class="ops-handoff-body">${t.summary}</div>
          ${t.payload_preview?i`<div class="ops-handoff-preview">${t.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${k?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const I=[];if((p>0||u>0)&&I.push({label:u>0?`확인 대기 ${p}/${m}건 확인`:`확인 대기 ${p}건 처리`,desc:u>0&&_?`현재 actor(${_}) 기준으로 보이는 queue를 먼저 확인합니다`:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:p>0?"bad":"warn",onClick:()=>{const w=document.querySelector(".ops-pending-section");w==null||w.scrollIntoView({behavior:"smooth"})}}),s.paused&&I.push({label:"Room 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void Yl()}),x.length>0){const w=x.filter(Q=>Fa(Q)==="bad");I.push({label:w.length>0?`Keeper ${w.length}개 오프라인`:`Keeper ${x.length}개 점검 필요`,desc:w.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:w.length>0?"bad":"warn",onClick:()=>{const Q=document.querySelector(".ops-keeper-section");Q==null||Q.scrollIntoView({behavior:"smooth"})}})}return I.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${I.slice(0,3).map(w=>i`
                <button class="ops-action-guide-item ${w.tone}" onClick=${w.onClick}>
                  <strong>${w.label}</strong>
                  <span>${w.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `})()}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${q} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 room인지, session인지, keeper인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${N.map(I=>i`
            <div key=${I.key} class="ops-priority-card ${I.tone}">
              <span class="ops-priority-label">${I.label}</span>
              <strong>${I.value}</strong>
              <div class="ops-priority-detail">${I.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${zg} />
        <${Mg} />
        <${Eg} />
      </div>
    </section>
  `}function Dg({text:e}){if(!e)return null;const t=Og(e);return i`<div class="markdown-content">${t}</div>`}function Og(e){const t=e.split(`
`),n=[];let s=0;for(;s<t.length;){const a=t[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),p=[];for(s++;s<t.length&&!t[s].startsWith(l);)p.push(t[s]),s++;s++,n.push(i`<pre><code class=${c?`language-${c}`:""}>${p.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<t.length&&!t[s].includes("</think>");)l.push(t[s]),s++;if(s<t.length){const m=t[s].replace("</think>","").trim();m&&l.push(m),s++}const p=l.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Ka(p)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<t.length&&t[s].startsWith("> ");)l.push(t[s].slice(2)),s++;n.push(i`<blockquote>${Ka(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<t.length;){const l=t[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;o.push(l),s++}o.length>0&&n.push(i`<p>${Ka(o.join(`
`))}</p>`)}return n}function Ka(e){const t=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(e))!==null;){if(a.index>s&&t.push(e.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);t.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);t.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);t.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&t.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<e.length&&t.push(e.slice(s)),t.length>0?t:[e]}const ic=[{id:"recent",label:"Latest"},{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],ws=g(null),Ns=g([]),an=g(!1),xt=g(null),xn=g(""),Sn=g(!1),qt=g(!0),co=20,Nt=g(co);function qg(){var t,n;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Fg=g(qg());function Kg(e){const t=e.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return t?t.length>180?`${t.slice(0,177)}...`:t:"No preview available"}function Jo(e){return e.updated_at!==e.created_at}function Bg(e){if(e.post_kind)return e.post_kind==="automation";const t=(e.hearth??"").toLowerCase();return e.visibility!=="internal"||!e.expires_at||!t?!1:!!(t.startsWith("mdal")||t.includes("harness"))}function Ug(e){return e==="lodge-system"||e==="team-session"}function Bn(e){return e.post_kind?e.post_kind:Ug(e.author)?"system":Bg(e)?"automation":"human"}function oc(e){const t=[],n=[];let s=0;return e.forEach(a=>{const o=Bn(a);if(!(o==="system"&&ht.value)){if(o==="automation"&&qt.value){s+=1;return}if(o==="human"){t.push(a);return}n.push(a)}}),{human:t,operations:n,hiddenAutomation:s}}function Hg(e){if(!e.expires_at)return null;const t=Date.parse(e.expires_at);return Number.isFinite(t)?t<=Date.now()?i`<span class="board-meta-chip">expired</span>`:i`<span class="board-meta-chip">expires <${G} timestamp=${e.expires_at} /></span>`:null}async function uo(e){xt.value=e,ws.value=null,Ns.value=[],an.value=!0;try{const t=await Cd(e);if(xt.value!==e)return;ws.value={id:t.id,author:t.author,title:t.title,body:t.body,content:t.content,meta:t.meta,tags:t.tags,votes:t.votes,vote_balance:t.vote_balance,comment_count:t.comment_count,created_at:t.created_at,updated_at:t.updated_at,post_kind:t.post_kind,flair:t.flair,hearth:t.hearth,visibility:t.visibility,expires_at:t.expires_at,hearth_count:t.hearth_count},Ns.value=t.comments??[]}catch{xt.value===e&&(ws.value=null,Ns.value=[])}finally{xt.value===e&&(an.value=!1)}}async function Vo(e){const t=xn.value.trim();if(t){Sn.value=!0;try{await Td(e,Fg.value,t),xn.value="",z("Comment posted","success"),await uo(e),Ze()}catch{z("Failed to post comment","error")}finally{Sn.value=!1}}}function Wg(){const e=In.value,t=qt.value?"Automation lane collapsed":"Automation lane visible";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${ic.map(n=>i`
          <button
            class="board-sort-btn ${e===n.id?"active":""}"
            onClick=${()=>{In.value=n.id,Nt.value=co,Ze()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${qt.value?"is-active":""}"
          onClick=${()=>{qt.value=!qt.value}}
        >
          ${t}
        </button>
        <button
          class="control-btn ghost ${ht.value?"is-active":""}"
          onClick=${()=>{ht.value=!ht.value,Ze()}}
        >
          ${ht.value?"System posts hidden":"System posts visible"}
        </button>
        <button class="control-btn ghost" onClick=${Ze} disabled=${Rn.value}>
          ${Rn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Ba(){var s;const e=((s=ic.find(a=>a.id===In.value))==null?void 0:s.label)??In.value,t=oc(Sa.value),n=t.human.length+t.operations.length;return i`
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
        <strong>${qt.value?`automation ${t.hiddenAutomation} hidden`:"separate lane"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${ht.value?"System posts hidden":"System lane visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${yi.value?i`<${G} timestamp=${yi.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Yo({post:e}){const t=async(n,s)=>{s.stopPropagation();try{await Cr(e.id,n),Ze()}catch{z("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>wc(e.id)}>
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
                ${Jo(e)?i`<span class="board-meta-chip">Updated</span>`:null}
                ${Bn(e)!=="human"?i`<span class="board-meta-chip">${Bn(e)}</span>`:null}
                ${e.hearth?i`<span class="board-meta-chip">${e.hearth}</span>`:null}
                ${e.visibility?i`<span class="board-meta-chip">${e.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>By ${e.author}</span>
            <span><${G} timestamp=${e.created_at} /></span>
            ${Jo(e)?i`<span>Updated <${G} timestamp=${e.updated_at} /></span>`:null}
            <span>${e.comment_count} comments</span>
            <span>${e.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${Kg(e.body)}</div>
      </div>
    </div>
  `}function Gg({comments:e}){return e.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${e.map(t=>i`
        <div key=${t.id} class="board-comment">
          <span class="comment-author">${t.author}</span>
          <span class="comment-time"><${G} timestamp=${t.created_at} /></span>
          <div class="comment-text">${t.content}</div>
        </div>
      `)}
    </div>
  `}function Jg({postId:e}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${xn.value}
        onInput=${t=>{xn.value=t.target.value}}
        onKeyDown=${t=>{t.key==="Enter"&&Vo(e)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Sn.value}
      />
      <button
        onClick=${()=>Vo(e)}
        disabled=${Sn.value||xn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Sn.value?"...":"Post"}
      </button>
    </div>
  `}function Vg({post:e}){xt.value!==e.id&&!an.value&&uo(e.id);const t=async n=>{try{await Cr(e.id,n),Ze()}catch{z("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>de("memory")}>← Back to Memory</button>
      <${T} title=${e.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${Dg} text=${e.body} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${e.author}</span>
            <${G} timestamp=${e.created_at} />
            <span>${e.votes??0} votes</span>
          </div>
          ${e.hearth||e.visibility||e.expires_at?i`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${e.hearth?i`<span class="board-meta-chip">${e.hearth}</span>`:null}
                  ${e.visibility?i`<span class="board-meta-chip">${e.visibility}</span>`:null}
                  ${Bn(e)!=="human"?i`<span class="board-meta-chip">${Bn(e)}</span>`:null}
                  ${Hg(e)}
                </div>
              `:null}
          ${e.meta?i`
                <details style="margin-top:12px;">
                  <summary>Operational meta</summary>
                  <div class="post-body" style="margin-top:8px;">
                    ${e.meta.source?i`<div><strong>source</strong>: ${e.meta.source}</div>`:null}
                    ${e.meta.state_block?i`<pre style="white-space:pre-wrap; margin-top:8px;">${e.meta.state_block}</pre>`:null}
                  </div>
                </details>
              `:null}
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>t("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>t("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${T} title="Comments" semanticId="memory.feed">
        ${an.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${Gg} comments=${Ns.value} />`}
        <${Jg} postId=${e.id} />
      <//>
    </div>
  `}function Yg(){const e=oc(Sa.value),t=[...e.human,...e.operations],n=F.value.params.post??null,s=n?t.find(a=>a.id===n)??(xt.value===n?ws.value:null):null;return n&&!s&&xt.value!==n&&!an.value&&uo(n),n?s?i`
          <${be} surfaceId="memory" />
          <${Ba} />
          <${Vg} post=${s} />
        `:i`
          <div>
            <${be} surfaceId="memory" />
            <${Ba} />
            <button class="back-btn" onClick=${()=>de("memory")}>← Back to Memory</button>
            ${an.value?i`<div class="loading-indicator">Loading post...</div>`:i`<div class="empty-state">Post not found</div>`}
          </div>
        `:i`
    <div>
      <${be} surfaceId="memory" />
      <${Ba} />
      <${Wg} />
      ${Rn.value?i`<div class="loading-indicator">Loading memory feed...</div>`:t.length===0?i`<div class="empty-state">No posts in durable memory right now</div>`:i`
              <${T} title="Human Posts" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${e.human.slice(0,Nt.value).map(a=>i`<${Yo} key=${a.id} post=${a} />`)}
                </div>
                ${e.human.length>Nt.value?i`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{Nt.value=Nt.value+co}}
                    >
                      Show more (${e.human.length-Nt.value} remaining)
                    </button>
                  </div>
                `:null}
              <//>
              ${e.operations.length>0?i`
                    <${T} title="Automation & System" class="section" semanticId="memory.feed">
                      <div class="board-post-list">
                        ${e.operations.map(a=>i`<${Yo} key=${a.id} post=${a} />`)}
                      </div>
                    <//>
                  `:null}
            `}
    </div>
  `}function Qg({ratio:e,size:t=40,stroke:n=4}){if(e==null)return null;const s=(t-n)/2,a=t/2,o=2*Math.PI*s,l=o*((100-e*100)/100);let c="mitosis-safe";return e>=.8?c="mitosis-critical":e>=.5&&(c="mitosis-warn"),i`
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
  `}const ft=g(null),De=g(null),Oe=g(null);function Pa(e){return e==="bad"||e==="critical"||e==="offline"?"bad":e==="warn"||e==="paused"||e==="blocked"||e==="interrupted"?"warn":"ok"}function Xg(e){return typeof e!="number"||Number.isNaN(e)?"—":`${Math.round(e*100)}%`}function Zg(e){return e?lt.value.find(t=>t.name===e||t.agent_name===e)??null:null}function ef(e){switch(e){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function tf(e){switch(e){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function Qo(e){if(!e)return;const t=wp({targetType:e.target_type,targetId:e.target_id,focusKind:e.focus_kind,operationId:e.operation_id??null,commandSurface:e.command_surface??null,sourceLabel:"Execution 진단",summary:e.label});al(t),de(e.surface,e.surface==="intervene"?il(t):rl(t))}function Lt({label:e,value:t,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${e}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${t}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function po({intervene:e,command:t}){return i`
    <div class="control-row">
      ${e?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),Qo(e)}}
            >
              ${e.label}
            </button>
          `:null}
      ${t?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),Qo(t)}}
            >
              ${t.label}
            </button>
          `:null}
    </div>
  `}function nf({item:e,selected:t}){return i`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{ft.value=t?null:e.id,De.value=null,Oe.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.kind==="session"?e.target_id:e.linked_session_id??e.target_id}</div>
          <div class="mission-card-title">${e.summary}</div>
        </div>
        <span class="command-chip ${Pa(e.severity)}">${e.status??e.severity}</span>
      </div>
      <div class="mission-card-meta">
        <span>${e.kind}</span>
        ${e.linked_operation_id?i`<span>linked op · ${e.linked_operation_id}</span>`:null}
        ${e.last_seen_at?i`<span><${G} timestamp=${e.last_seen_at} /></span>`:null}
      </div>
      <${po} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function sf({brief:e,selected:t}){return i`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.session-card"
      onClick=${()=>{De.value=t?null:e.session_id,Oe.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          <div class="mission-card-title">${e.goal}</div>
        </div>
        <span class="command-chip ${Pa(e.health??e.status)}">${e.status??"unknown"}</span>
      </div>
      <div class="mission-card-meta">
        <span>health · ${e.health??"ok"}</span>
        ${e.linked_operation_id?i`<span>op · ${e.linked_operation_id}</span>`:null}
        ${e.last_activity_at?i`<span><${G} timestamp=${e.last_activity_at} /></span>`:null}
      </div>
      ${e.runtime_blocker?i`<div class="mission-card-detail">${e.runtime_blocker}</div>`:e.last_activity_summary?i`<div class="mission-card-detail">${e.last_activity_summary}</div>`:null}
      ${e.worker_gap_summary?i`<div class="monitor-footnote">${e.worker_gap_summary}</div>`:null}
      <${po} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function af({brief:e,selected:t}){return i`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.operation-card"
      onClick=${()=>{Oe.value=t?null:e.operation_id,De.value=e.linked_session_id??null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.operation_id}${e.assigned_unit_label?` · ${e.assigned_unit_label}`:""}</div>
          <div class="mission-card-title">${e.objective}</div>
        </div>
        <span class="command-chip ${Pa(e.blocker_summary?"warn":e.status)}">${e.status??"unknown"}</span>
      </div>
      <div class="mission-card-meta">
        ${e.stage?i`<span>stage · ${e.stage}</span>`:null}
        ${e.linked_session_id?i`<span>session · ${e.linked_session_id}</span>`:null}
        ${e.updated_at?i`<span><${G} timestamp=${e.updated_at} /></span>`:null}
      </div>
      ${e.blocker_summary?i`<div class="mission-card-detail">${e.blocker_summary}</div>`:null}
      ${e.next_tool?i`<div class="monitor-footnote">next tool · ${e.next_tool}</div>`:null}
      <${po} command=${e.command_handoff} />
    </button>
  `}function Xo({row:e,testId:t}){return i`
    <button class="monitor-row ${e.tone} state-${e.state}" data-testid=${t} onClick=${()=>Ta(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.korean_name?i`<span class="monitor-sub">${e.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${e.note}</div>
        </div>
        <${ct} status=${e.status??"unknown"} />
        <span class="monitor-pill ${e.tone} state-${e.state}">${ef(e.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_signal_at?i`<span>신호 <${G} timestamp=${e.last_signal_at} /></span>`:i`<span>최근 신호 없음</span>`}
        <span>${(e.active_task_count??0)>0?`활성 작업 ${e.active_task_count}개`:"활성 작업 없음"}</span>
        ${e.related_session_id?i`<span>session · ${e.related_session_id}</span>`:null}
        ${e.related_operation_id?i`<span>op · ${e.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.recent_output_preview&&e.recent_output_preview!==e.focus?i`<div class="monitor-footnote">최근 상세: ${e.recent_output_preview}</div>`:null}
    </button>
  `}function of({row:e}){const t=()=>{const n=Zg(e.name);n&&Sl(n)};return i`
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
        <${Qg} ratio=${e.context_ratio??0} size=${34} stroke=${4} />
        <${ct} status=${e.status??"unknown"} />
        <span class="monitor-pill ${e.tone}">${tf(e.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_signal_at?i`<span>최근 활동 <${G} timestamp=${e.last_signal_at} /></span>`:i`<span>최근 활동 없음</span>`}
        ${e.related_session_id?i`<span>session · ${e.related_session_id}</span>`:null}
        ${e.continuity?i`<span>${e.continuity}</span>`:null}
        ${e.lifecycle?i`<span>라이프사이클 ${e.lifecycle}</span>`:null}
        <span>컨텍스트 ${Xg(e.context_ratio)}</span>
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.skill_reason?i`<div class="monitor-footnote">연속성 이유: ${e.skill_reason}</div>`:null}
    </button>
  `}function rf(){const e=Lr.value,t=wr.value,n=Nr.value,s=zr.value,a=Mr.value,o=Er.value,l=jr.value;ft.value&&!t.some(h=>h.id===ft.value)&&(ft.value=null),De.value&&!n.some(h=>h.session_id===De.value)&&(De.value=null),Oe.value&&!s.some(h=>h.operation_id===Oe.value)&&(Oe.value=null);const c=ft.value?t.find(h=>h.id===ft.value)??null:null,p=De.value?De.value:c?c.kind==="session"?c.target_id:c.linked_session_id??null:null,m=Oe.value?Oe.value:c?c.kind==="operation"?c.target_id:c.linked_operation_id??null:null,u=p?n.filter(h=>h.session_id===p):m?n.filter(h=>h.linked_operation_id===m):n,_=m?s.filter(h=>h.operation_id===m):p?s.filter(h=>{var C;return h.linked_session_id===p||h.operation_id===((C=u[0])==null?void 0:C.linked_operation_id)}):s,f=p||m?a.filter(h=>(p?h.related_session_id===p:!1)||(m?h.related_operation_id===m:!1)):a,$=p?o.filter(h=>h.related_session_id===p||h.tone!=="ok"):o,S=p||m?l.filter(h=>(p?h.related_session_id===p:!1)||(m?h.related_operation_id===m:!1)||h.tone!=="ok"):l;return i`
    <div class="agents-monitor">
      <${be} surfaceId="execution" />
      <div class="stats-grid">
        <${Lt} label="활성 세션" value=${(e==null?void 0:e.active_sessions)??n.length} color="#4ade80" caption="실행 관점의 session" />
        <${Lt} label="막힌 세션" value=${(e==null?void 0:e.blocked_sessions)??n.filter(h=>Pa(h.health??h.status)!=="ok").length} color="#fbbf24" caption="개입 후보 session" />
        <${Lt} label="활성 작전" value=${(e==null?void 0:e.active_operations)??s.length} color="#22d3ee" caption="command-plane operation" />
        <${Lt} label="막힌 작전" value=${(e==null?void 0:e.blocked_operations)??s.filter(h=>h.blocker_summary).length} color="#fb7185" caption="원인 분석이 필요한 작전" />
        <${Lt} label="worker 경고" value=${(e==null?void 0:e.worker_alerts)??a.filter(h=>h.tone!=="ok").length} color="#fb7185" caption="supporting worker pressure" />
        <${Lt} label="연속성 경고" value=${(e==null?void 0:e.continuity_alerts)??o.filter(h=>h.tone!=="ok").length} color="#fb7185" caption="keeper continuity pressure" />
      </div>

      <${T}
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
          ${t.length===0?i`<div class="empty-state">지금은 막힌 실행이 없습니다</div>`:t.map(h=>i`<${nf} key=${h.id} item=${h} selected=${ft.value===h.id} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${T}
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
            ${u.length===0?i`<div class="empty-state">선택된 실행과 연결된 session이 없습니다</div>`:u.map(h=>i`<${sf} key=${h.session_id} brief=${h} selected=${De.value===h.session_id} />`)}
          </div>
        <//>

        <${T}
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
            ${_.length===0?i`<div class="empty-state">선택된 실행과 연결된 operation이 없습니다</div>`:_.map(h=>i`<${af} key=${h.operation_id} brief=${h} selected=${Oe.value===h.operation_id} />`)}
          </div>
        <//>

        <${T}
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
            ${f.length===0?i`<div class="empty-state">연결된 worker가 없습니다</div>`:f.map(h=>i`<${Xo} key=${h.name} row=${h} testId="execution.worker-card" />`)}
          </div>
        <//>

        <${T}
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
            ${$.length===0?i`<div class="empty-state">지금은 연속성 경고가 없습니다</div>`:$.map(h=>i`<${of} key=${h.name} row=${h} />`)}
          </div>
        <//>

        <${T}
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
            ${S.length===0?i`<div class="empty-state">지금은 오프라인 worker가 없습니다</div>`:S.map(h=>i`<${Xo} key=${h.name} row=${h} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const ma=g("all"),va=g("all"),Ri=g(new Set);function lf(e){const t=new Set(Ri.value);t.has(e)?t.delete(e):t.add(e),Ri.value=t}const rc=Ae(()=>{let e=Bt.value;return ma.value!=="all"&&(e=e.filter(t=>t.horizon===ma.value)),va.value!=="all"&&(e=e.filter(t=>t.status===va.value)),e}),cf=Ae(()=>{const e={short:[],mid:[],long:[]};for(const t of rc.value){const n=e[t.horizon];n&&n.push(t)}return e}),df=Ae(()=>{const e=Array.from(Or.value.values());return e.sort((t,n)=>t.status==="running"&&n.status!=="running"?-1:n.status==="running"&&t.status!=="running"?1:t.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&t.status!=="interrupted"?1:n.elapsed_seconds-t.elapsed_seconds),e});function uf(e){return"★".repeat(Math.min(e,5))+"☆".repeat(Math.max(0,5-e))}function mo(e){switch(e){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return e}}function zs(e){switch(e){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function pf(e){return e<60?`${Math.round(e)}s`:e<3600?`${Math.floor(e/60)}m ${Math.round(e%60)}s`:`${Math.floor(e/3600)}h ${Math.floor(e%3600/60)}m`}function Zo(e){return e.toFixed(4)}function er(e){const t=e.current_metric-e.baseline_metric;return`${t>=0?"+":""}${t.toFixed(4)}`}function mf(e){switch(e){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function tr(e,t){return(e.priority??4)-(t.priority??4)}function vf(e,t){const n=e.updated_at??e.created_at??"";return(t.updated_at??t.created_at??"").localeCompare(n)}function _f(e,t){return e.length<=t?e:e.slice(0,t)+"..."}function gf({goal:e}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${zs(e.horizon)}">
            ${mo(e.horizon)}
          </span>
          <span class="goal-title">${e.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${e.priority}">${uf(e.priority)}</span>
          ${e.metric?i`<span class="goal-metric">${e.metric}${e.target_value?` → ${e.target_value}`:""}</span>`:null}
          ${e.due_date?i`<span class="goal-due">Due: <${G} timestamp=${e.due_date} /></span>`:null}
        </div>
        ${e.last_review_note?i`
          <div class="goal-review-note">${e.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${ct} status=${e.status} />
        <div class="goal-updated">
          <${G} timestamp=${e.updated_at} />
        </div>
      </div>
    </div>
  `}function Ua({horizon:e,items:t}){if(t.length===0)return null;const n=[...t].sort((s,a)=>a.priority-s.priority);return i`
    <${T} title="${mo(e)} Goals (${t.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${gf} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function ff(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(e=>i`
          <button
            class="goal-filter-btn ${ma.value===e?"active":""}"
            onClick=${()=>{ma.value=e}}
          >
            ${e==="all"?"All":mo(e)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(e=>i`
          <button
            class="goal-filter-btn ${va.value===e?"active":""}"
            onClick=${()=>{va.value=e}}
          >
            ${e==="all"?"All":e.charAt(0).toUpperCase()+e.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function $f(){const e=Bt.value,t=e.filter(a=>a.status==="active").length,n=e.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of e)a.horizon in s&&s[a.horizon]++;return i`
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
        <div class="goal-summary-value" style="color:${zs("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${zs("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${zs("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function hf({loop:e}){const t=e.history[0],n=e.latest_tool_names&&e.latest_tool_names.length>0?`${e.latest_tool_call_count??e.latest_tool_names.length} tool${(e.latest_tool_call_count??e.latest_tool_names.length)===1?"":"s"}: ${e.latest_tool_names.join(", ")}`:"No evidence yet";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${e.profile}</div>
            <div class="planning-loop-sub">${e.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${ct} status=${e.status} />
            <span class="pill">${e.current_iteration}${e.max_iterations>0?`/${e.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Zo(e.baseline_metric)}</span>
          <span>Current ${Zo(e.current_metric)}</span>
          <span class=${er(e).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${er(e)}
          </span>
          <span>Elapsed ${pf(e.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${e.target||"No explicit target provided"}</div>
        ${e.stop_reason||e.error_message?i`
              <div class="planning-loop-footnote">
                ${e.error_message??e.stop_reason}
              </div>
            `:null}
        <div class="planning-loop-footnote">
          ${e.strict_mode?"Strict hard evidence":"Legacy"} · ${e.worker_engine??"unknown engine"} · ${n}
        </div>
        ${t?i`
              <div class="planning-loop-footnote">
                Latest iteration #${t.iteration}: ${t.changes||t.next_suggestion||"No narrative"}
              </div>
            `:i`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function Ha({task:e}){const t=e.priority??4,n=t<=1?"p1":t===2?"p2":t===3?"p3":"p4",s=Ri.value.has(e.id),a=!!e.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${mf(t)}</span>
        <div class="kanban-card-title">${e.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>lf(e.id)}
        >
          ${s?e.description:_f(e.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${e.created_at?i`<${G} timestamp=${e.created_at} />`:i`<span>-</span>`}
        ${e.assignee?i`<span class="kanban-assignee">${e.assignee}</span>`:null}
      </div>
    </div>
  `}function yf(){const{todo:e,inProgress:t,done:n}=Fr.value,s=[...e].sort(tr),a=[...t].sort(tr),o=[...n].sort(vf);return i`
    <${T} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:s.map(l=>i`<${Ha} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:a.map(l=>i`<${Ha} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:o.slice(0,20).map(l=>i`<${Ha} key=${l.id} task=${l} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${o.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function bf(){const{todo:e,inProgress:t,done:n}=Fr.value,s=e.length+t.length+n.length,a=[...e,...t].filter(u=>(u.priority??4)<=2).length,o=cf.value,l=df.value,c=Bt.value.length>0,p=l.length>0,m=Ki.value;return i`
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
          onClick=${()=>{Hi(),Jr()}}
          disabled=${fn.value||$n.value}
        >
          ${fn.value||$n.value?"Refreshing...":"Refresh planning data"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${yf} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          Goal Pipeline
          <span class="monitor-pill">${Bt.value.length}</span>
        </summary>
        <div>
          ${c?i`
            <${$f} />
            <${ff} />
            ${fn.value&&Bt.value.length===0?i`<div class="loading-indicator">Loading goals...</div>`:rc.value.length===0?i`<div class="empty-state">No goals match the current filters</div>`:i`
                    <${Ua} horizon="short" items=${o.short??[]} />
                    <${Ua} horizon="mid" items=${o.mid??[]} />
                    <${Ua} horizon="long" items=${o.long??[]} />
                  `}
          `:i`
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
          ${$n.value&&l.length===0?i`<div class="loading-indicator">Loading MDAL loops...</div>`:l.length===0&&(m==="error"||Ut.value)?i`<div class="empty-state">MDAL snapshot could not be loaded${Ut.value?`: ${Ut.value}`:""}. Check backend health.</div>`:l.length===0?i`<div class="empty-state">No active loops. Use <code>masc_mdal_start</code> to start a loop.</div>`:i`
                  <div class="planning-loop-list">
                    ${l.map(u=>i`<${hf} key=${u.loop_id} loop=${u} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const _a=g(!1),An=g(!1),Ft=g(!1),ot=g(""),Cn=g(""),Pi=g("open"),Ne=g(null),Un=g(null),ga=g(null),fa=g(null),Li=g(!1);function Hn(e){return`${e.kind}:${e.id}`}function vo(){var n;const e=Un.value,t=((n=Ne.value)==null?void 0:n.items)??[];return e?t.find(s=>Hn(s)===e)??null:null}function kf(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");return(t==null?void 0:t.trim())||"dashboard"}function xf(e){const t=e.trim().toLowerCase();return t==="open"||t==="pending"}function lc(e){return!!(e.judgment_summary&&e.judgment_summary.trim())}function cc(e){switch(Pi.value){case"needs_quorum":return e.filter(t=>t.kind==="consensus"&&(t.votes??0)<(t.quorum??0));case"ready":return e.filter(t=>{var n;return(n=t.guardrail_state)==null?void 0:n.ready_to_execute});case"needs_approval":return e.filter(t=>{var n,s;return((n=t.guardrail_state)==null?void 0:n.requires_human_gate)||!!((s=t.guardrail_state)!=null&&s.pending_confirm)});case"judge_offline":return e.filter(t=>!lc(t));case"open":default:return e.filter(t=>xf(t.status))}}function Sf(e){if(e==null)return"none";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function La(e){const t=(e||"").toLowerCase();return t.includes("reject")||t.includes("deny")||t.includes("closed")||t.includes("cancel")?"negative":t.includes("approve")||t.includes("support")||t.includes("open")||t.includes("ready")?"positive":"neutral"}function Af(e){return typeof e!="number"||Number.isNaN(e)?"n/a":`${Math.round(e*100)}%`}function vn(e){return"resolved_tool"in e||"payload_preview"in e||"reason"in e}async function dc(e){if(ga.value=null,fa.value=null,!!e){Li.value=!0,ot.value="";try{e.kind==="debate"?ga.value=await eu(e.id):fa.value=await tu(e.id)}catch(t){ot.value=t instanceof Error?t.message:"Failed to load governance detail"}finally{Li.value=!1}}}async function Cf(e){Un.value=Hn(e),await dc(e)}async function on(){var e;_a.value=!0,ot.value="";try{const t=await nd();Ne.value=t;const n=cc(t.items??[]),s=Un.value,a=n.find(o=>Hn(o)===s)??n[0]??((e=t.items)==null?void 0:e[0])??null;Un.value=a?Hn(a):null,await dc(a)}catch(t){ot.value=t instanceof Error?t.message:"Failed to load governance state"}finally{_a.value=!1}}Xu(on);async function nr(){const e=Cn.value.trim();if(e){An.value=!0;try{const t=await Zd(e);Cn.value="",z(t!=null&&t.id?`Debate started: ${t.id}`:"Debate started","success"),await on()}catch(t){const n=t instanceof Error?t.message:"Failed to start debate";ot.value=n,z(n,"error")}finally{An.value=!1}}}async function sr(e){var o,l;const t=vo(),n=(o=t==null?void 0:t.guardrail_state)==null?void 0:o.pending_confirm,s=n==null?void 0:n.confirm_token;if(!s)return;const a=((l=n==null?void 0:n.actor)==null?void 0:l.trim())||kf();Ft.value=!0;try{await yr(a,s,e),z(e==="confirm"?"Action approved":"Action denied","success"),await on()}catch(c){const p=c instanceof Error?c.message:"Failed to update pending action";ot.value=p,z(p,"error")}finally{Ft.value=!1}}function Tf(){var n,s,a,o,l,c;const e=(n=Ne.value)==null?void 0:n.summary,t=(s=Ne.value)==null?void 0:s.judge;return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${(e==null?void 0:e.debates_open)??((o=(a=Ne.value)==null?void 0:a.debates)==null?void 0:o.length)??0}</strong>
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
  `}function If(){return i`
    <${T} title="Governance Console" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Cn.value}
            onInput=${e=>{Cn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&nr()}}
            disabled=${An.value}
          />
          <button
            class="control-btn secondary"
            onClick=${nr}
            disabled=${An.value||Cn.value.trim()===""}
          >
            ${An.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${on} disabled=${_a.value}>
            ${_a.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        <div class="governance-filter-row">
          ${[["open","Open"],["needs_quorum","Needs Quorum"],["ready","Ready"],["needs_approval","Needs Approval"],["judge_offline","Judge Offline"]].map(([e,t])=>i`
            <button
              class="control-btn ${Pi.value===e?"is-active":"ghost"}"
              onClick=${async()=>{Pi.value=e,await on()}}
            >
              ${t}
            </button>
          `)}
        </div>
        ${ot.value?i`<div class="council-error">${ot.value}</div>`:null}
      </div>
    <//>
  `}function Rf(){var t;const e=cc(((t=Ne.value)==null?void 0:t.items)??[]);return i`
    <${T} title="Decision Inbox" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${e.length===0?i`
              <div class="empty-state">
                Governance is quiet. No debates or consensus sessions match the current filter.
              </div>
            `:e.map(n=>{var a,o;const s=Un.value===Hn(n);return i`
                <button
                  class="council-row governance-decision-row ${s?"selected":""}"
                  onClick=${()=>Cf(n)}
                >
                  <div class="council-row-main">
                    <div class="governance-row-head">
                      <span class="governance-kind">${n.kind}</span>
                      <span class="council-topic">${n.topic}</span>
                    </div>
                    <div class="council-sub">
                      <span>${n.truth_summary||"No fact summary"}</span>
                      ${n.last_activity_at?i`<span><${G} timestamp=${n.last_activity_at} /></span>`:null}
                    </div>
                    <div class="governance-chip-row">
                      ${(a=n.guardrail_state)!=null&&a.requires_human_gate?i`<span class="governance-chip warn">needs approval</span>`:null}
                      ${(o=n.guardrail_state)!=null&&o.ready_to_execute?i`<span class="governance-chip ok">ready</span>`:null}
                      ${n.kind==="consensus"&&(n.votes??0)<(n.quorum??0)?i`<span class="governance-chip warn">quorum debt</span>`:null}
                      ${lc(n)?null:i`<span class="governance-chip dim">judge offline</span>`}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${La(n.status)}">${n.status}</span>
                    ${n.kind==="consensus"?i`<span class="governance-vote-meter">${n.votes??0}/${n.quorum??0}</span>`:i`<span class="governance-vote-meter">${n.evidence_refs.length} refs</span>`}
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function Pf({argument:e}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${La(e.position)}">${e.position}</span>
        <strong>${e.agent}</strong>
        ${e.created_at?i`<span><${G} timestamp=${e.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.content}</div>
      <div class="governance-chip-row">
        ${e.evidence.map(t=>i`<span class="governance-chip">${t}</span>`)}
        ${e.reply_to!=null?i`<span class="governance-chip">reply #${e.reply_to}</span>`:null}
        ${e.mentions.map(t=>i`<span class="governance-chip">@${t}</span>`)}
        ${e.archetype?i`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function Lf({vote:e}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${La(e.decision)}">${e.decision}</span>
        <strong>${e.agent}</strong>
        ${e.timestamp?i`<span><${G} timestamp=${e.timestamp} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.reason||"No reason recorded."}</div>
      <div class="governance-chip-row">
        ${e.weight!=null?i`<span class="governance-chip">weight ${e.weight}</span>`:null}
        ${e.archetype?i`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function wf(){const e=vo(),t=ga.value,n=fa.value;return i`
    <${T}
      title=${e?`${e.kind==="debate"?"Debate":"Consensus"} Detail`:"Decision Detail"}
      class="section"
      semanticId="governance.detail"
    >
      ${Li.value?i`<div class="loading-indicator">Loading governance detail...</div>`:e?e.kind==="debate"&&t?i`
                <div class="governance-detail-head">
                  <div>
                    <h3>${t.debate.topic}</h3>
                    <div class="council-sub">
                      <span>${t.debate.id}</span>
                      <span>${t.debate.status}</span>
                      ${t.debate.created_at?i`<span><${G} timestamp=${t.debate.created_at} /></span>`:null}
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
                  ${t.arguments.length===0?i`<div class="empty-state">No arguments recorded yet.</div>`:t.arguments.map(s=>i`<${Pf} key=${s.index} argument=${s} />`)}
                </div>
              `:e.kind==="consensus"&&n?i`
                  <div class="governance-detail-head">
                    <div>
                      <h3>${n.session.topic}</h3>
                      <div class="council-sub">
                        <span>${n.session.id}</span>
                        <span>${n.session.state}</span>
                        <span>initiator ${n.session.initiator}</span>
                        ${n.session.created_at?i`<span><${G} timestamp=${n.session.created_at} /></span>`:null}
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
                    ${n.votes.length===0?i`<div class="empty-state">No votes recorded yet.</div>`:n.votes.map(s=>i`<${Lf} key=${s.agent+s.timestamp} vote=${s} />`)}
                  </div>
                `:i`<div class="empty-state">Detail is unavailable for this decision.</div>`:i`<div class="empty-state">Select a decision item to inspect truth and judgment.</div>`}
    <//>
  `}function ar({title:e,route:t}){if(!t)return null;const n=vn(t)?t.resolved_tool:t.delegated_tool,s=vn(t)?t.target_type:null,a=vn(t)?t.target_id:null,o=vn(t)?t.reason:null,l=vn(t)?t.payload_preview:null;return i`
    <div class="governance-side-block">
      <h4>${e}</h4>
      <div class="council-sub">
        ${n?i`<span>tool ${n}</span>`:null}
        ${"action_type"in t&&t.action_type?i`<span>action ${t.action_type}</span>`:null}
        ${"confirmation_state"in t&&t.confirmation_state?i`<span>${t.confirmation_state}</span>`:null}
        ${"created_at"in t&&t.created_at?i`<span><${G} timestamp=${t.created_at} /></span>`:null}
      </div>
      ${s?i`<div class="governance-side-line">target ${s}${a?`:${a}`:""}</div>`:null}
      ${o?i`<div class="governance-side-line">${o}</div>`:null}
      ${l?i`<pre class="council-detail governance-preview">${Sf(l)}</pre>`:null}
    </div>
  `}function Nf(){var c,p,m;const e=vo(),t=ga.value,n=fa.value,s=(t==null?void 0:t.context)??(n==null?void 0:n.context)??(e==null?void 0:e.context),a=(t==null?void 0:t.judgment)??(n==null?void 0:n.judgment),o=e==null?void 0:e.guardrail_state,l=(c=Ne.value)==null?void 0:c.judge;return i`
    <div class="governance-side-column">
      <${T} title="Why / Guardrail" class="section" semanticId="governance.guardrail">
        ${e?i`
              <div class="governance-side-block">
                <h4>Judge</h4>
                <div class="council-sub">
                  <span>${l!=null&&l.judge_online?"online":"offline"}</span>
                  ${l!=null&&l.model_used?i`<span>${l.model_used}</span>`:null}
                  ${l!=null&&l.generated_at?i`<span><${G} timestamp=${l.generated_at} /></span>`:null}
                </div>
                ${e.judgment_summary?i`<div class="governance-summary-callout">${e.judgment_summary}</div>`:i`<div class="governance-side-line">No current LLM judgment. Showing truth layer only.</div>`}
                <div class="council-sub">
                  <span>confidence ${Af(e.confidence)}</span>
                  ${a!=null&&a.keeper_name?i`<span>${a.keeper_name}</span>`:null}
                </div>
              </div>

              <${ar} title="Recommended Route" route=${e.recommended_action} />
              <${ar} title="Executed Route" route=${e.executed_route} />

              <div class="governance-side-block">
                <h4>Guardrail State</h4>
                <div class="council-sub">
                  <span>${o!=null&&o.requires_human_gate?"human gate required":"no human gate"}</span>
                  ${o!=null&&o.ready_to_execute?i`<span>ready to execute</span>`:null}
                </div>
                ${o!=null&&o.pending_confirm?i`
                      <div class="governance-side-line">
                        pending ${o.pending_confirm.action_type||"action"}
                        ${o.pending_confirm.target_type?` on ${o.pending_confirm.target_type}`:""}
                      </div>
                      <div class="governance-action-row">
                        <button
                          class="control-btn secondary"
                          onClick=${()=>sr("confirm")}
                          disabled=${Ft.value}
                        >
                          ${Ft.value?"Working...":"Approve"}
                        </button>
                        <button
                          class="control-btn ghost"
                          onClick=${()=>sr("deny")}
                          disabled=${Ft.value}
                        >
                          ${Ft.value?"Working...":"Deny"}
                        </button>
                      </div>
                    `:i`<div class="governance-side-line">No pending human gate for this decision.</div>`}
              </div>
            `:i`<div class="empty-state">Select a decision to inspect judgment and route.</div>`}
      <//>

      <${T} title="Context" class="section" semanticId="governance.context">
        ${e?i`
              <div class="governance-side-block">
                <div class="governance-chip-row">
                  ${s!=null&&s.board_post_id?i`<span class="governance-chip">board ${s.board_post_id}</span>`:null}
                  ${s!=null&&s.task_id?i`<span class="governance-chip">task ${s.task_id}</span>`:null}
                  ${s!=null&&s.operation_id?i`<span class="governance-chip">operation ${s.operation_id}</span>`:null}
                  ${s!=null&&s.team_session_id?i`<span class="governance-chip">session ${s.team_session_id}</span>`:null}
                </div>
                ${e.related_agents.length>0?i`
                      <div class="governance-side-line">related agents</div>
                      <div class="governance-chip-row">
                        ${e.related_agents.map(u=>i`<span class="governance-chip dim">${u}</span>`)}
                      </div>
                    `:i`<div class="governance-side-line">No explicit linked context recorded.</div>`}
                ${e.evidence_refs.length>0?i`
                      <div class="governance-side-line">evidence refs</div>
                      <div class="governance-chip-row">
                        ${e.evidence_refs.map(u=>i`<span class="governance-chip">${u}</span>`)}
                      </div>
                    `:null}
              </div>
          `:i`<div class="empty-state">No context selected.</div>`}
      <//>

      <${T} title="Recent Activity" class="section" semanticId="governance.activity">
        <div class="governance-activity-list">
          ${(((p=Ne.value)==null?void 0:p.activity)??[]).slice(0,8).map(u=>i`
            <div class="governance-activity-row">
              <div class="governance-ledger-head">
                <span class="governance-badge ${La(u.kind)}">${u.kind}</span>
                ${u.actor?i`<strong>${u.actor}</strong>`:null}
                ${u.created_at?i`<span><${G} timestamp=${u.created_at} /></span>`:null}
              </div>
              <div class="governance-ledger-body">${u.summary||u.topic||"Activity recorded."}</div>
            </div>
          `)}
          ${(((m=Ne.value)==null?void 0:m.activity)??[]).length===0?i`<div class="empty-state">No governance activity recorded.</div>`:null}
        </div>
      <//>
    </div>
  `}function zf(){return te(()=>{on()},[]),i`
    <div>
      <${be} surfaceId="governance" />
      <${Tf} />
      <${If} />
      <div class="governance-layout">
        <${Rf} />
        <${wf} />
        <${Nf} />
      </div>
    </div>
  `}const zt=g(""),Wa=g("ability_check"),Ga=g("10"),Ja=g("12"),fs=g(""),$s=g("idle"),Je=g(""),hs=g("keeper-late"),Va=g("player"),Ya=g(""),xe=g("idle"),Qa=g(null),ys=g(""),Xa=g(""),Za=g("player"),ei=g(""),ti=g(""),ni=g(""),Tn=g("20"),si=g("20"),ai=g(""),bs=g("idle"),wi=g(null),uc=g("overview"),ii=g("all"),oi=g("all"),ri=g("all"),Mf=12e4,wa=g(null),ir=g(Date.now());function Ef(e,t){const n=t>0?e/t*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function jf(e,t){return t>0?Math.round(e/t*100):0}const Df={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Of={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function ks(e){const t=e.trim();return t?t.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):e}function qf(e){const t=e.trim().toLowerCase();return Df[t]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Ff(e){const t=e.trim().toLowerCase();return Of[t]??"상황에 따라 선택되는 전술 액션입니다."}function $e(e,t,n=""){const s=e[t];return typeof s=="string"?s:n}function Pe(e,t,n=0){const s=e[t];return typeof s=="number"&&Number.isFinite(s)?s:n}function Wn(e,t,n=!1){const s=e[t];return typeof s=="boolean"?s:n}const Kf=new Set(["str","dex","con","int","wis","cha"]);function Bf(e){const t=e.trim();if(!t)return{};let n;try{n=JSON.parse(t)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!v(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const l=a.trim();if(l){if(typeof o=="number"&&Number.isFinite(o)){s[l]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const c=Number.parseFloat(o.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function Uf(e){const t=Number.parseInt(e.trim(),10);if(!Number.isFinite(t))return;const n=Math.max(1,t),s=Number.parseInt(Tn.value.trim(),10);Number.isFinite(s)&&s>n&&(Tn.value=String(n))}function Ni(e){const n=(e.actor_name??e.actor??e.actor_id??"system").trim();return n===""?"system":n}function Hf(e){var n;return(((n=e.timestamp)==null?void 0:n.trim())??"")||"-"}function Wf(e){uc.value=e}function pc(e){const t=wa.value;return t==null||t<=e}function Gf(e){const t=wa.value;return t==null||t<=e?0:Math.max(0,Math.ceil((t-e)/1e3))}function $a(){wa.value=null}function mc(e){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(e)}function Jf(e,t){mc(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${e||"-"}`,`PHASE: ${t||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(wa.value=Date.now()+Mf,z("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Ms(e){return pc(e)?(z("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function zi(e,t,n){return mc([`[위험 액션 확인] ${e}`,`ROOM: ${t||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Vf({hp:e,max:t}){const n=jf(e,t),s=Ef(e,t);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Yf({stats:e}){const t=[{label:"STR",value:e.strength},{label:"DEX",value:e.dexterity},{label:"CON",value:e.constitution},{label:"INT",value:e.intelligence},{label:"WIS",value:e.wisdom},{label:"CHA",value:e.charisma}];return i`
    <div class="trpg-actor-stats">
      ${t.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Qf({keeper:e,role:t}){if(!e)return null;const n=t==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${e}
    </span>
  `}function vc({actor:e}){var p,m,u,_;const t=(p=e.archetype)==null?void 0:p.trim(),n=(m=e.persona)==null?void 0:m.trim(),s=(u=e.portrait)==null?void 0:u.trim(),a=(_=e.background)==null?void 0:_.trim(),o=e.traits??[],l=e.skills??[],c=Object.entries(e.stats_raw??{}).filter(([f,$])=>Number.isFinite($)).filter(([f])=>!Kf.has(f.toLowerCase()));return i`
    <div class="trpg-actor">
      ${s?i`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${e.name} portrait`}
              loading="lazy"
              onError=${f=>{const $=f.target;$&&($.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${e.name}</span>
        <${ct} status=${e.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${e.role}">${e.role}</span>
        <${Qf} keeper=${e.keeper} role=${e.role} />
      </div>
      ${e.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${e.stats.hp}/${e.stats.max_hp}
              ${e.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${e.stats.mp}/${e.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${e.stats.level}</span>
            </div>
            <${Vf} hp=${e.stats.hp} max=${e.stats.max_hp} />
            <${Yf} stats=${e.stats} />
          </div>
        `:null}
      ${t?i`<div class="trpg-actor-meta">Archetype: ${ks(t)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([f,$])=>i`
                <span class="trpg-custom-stat-chip">${ks(f)} ${$}</span>
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
                  <span class="trpg-annot-name">${ks(f)}</span>
                  <span class="trpg-annot-desc">${qf(f)}</span>
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
                  <span class="trpg-annot-name">${ks(f)}</span>
                  <span class="trpg-annot-desc">${Ff(f)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Xf({mapStr:e}){return i`<pre class="trpg-map">${e}</pre>`}function _c({events:e,emptyLabel:t="아직 이벤트가 없습니다."}){return e.length===0?i`<div class="empty-state" style="font-size:13px">${t}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${e.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Hf(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Ni(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${G} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Zf({events:e}){const t="__none__",n=ii.value,s=oi.value,a=ri.value,o=Array.from(new Set(e.map(Ni).map(_=>_.trim()).filter(_=>_!==""))).sort((_,f)=>_.localeCompare(f)),l=Array.from(new Set(e.map(_=>(_.type??"").trim()).filter(_=>_!==""))).sort((_,f)=>_.localeCompare(f)),c=e.some(_=>(_.type??"").trim()===""),p=Array.from(new Set(e.map(_=>(_.phase??"").trim()).filter(_=>_!==""))).sort((_,f)=>_.localeCompare(f)),m=e.some(_=>(_.phase??"").trim()===""),u=e.filter(_=>{if(n!=="all"&&Ni(_)!==n)return!1;const f=(_.type??"").trim(),$=(_.phase??"").trim();if(s===t){if(f!=="")return!1}else if(s!=="all"&&f!==s)return!1;if(a===t){if($!=="")return!1}else if(a!=="all"&&$!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${_=>{ii.value=_.target.value}}>
          <option value="all">all</option>
          ${o.map(_=>i`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${_=>{oi.value=_.target.value}}>
          <option value="all">all</option>
          ${c?i`<option value=${t}>(none)</option>`:null}
          ${l.map(_=>i`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${_=>{ri.value=_.target.value}}>
          <option value="all">all</option>
          ${m?i`<option value=${t}>(none)</option>`:null}
          ${p.map(_=>i`<option value=${_}>${_}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{ii.value="all",oi.value="all",ri.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${u.length} / 전체 ${e.length}
      </span>
    </div>
    <${_c} events=${u.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function e$({outcome:e}){if(!e)return null;const t=o=>{const l=o.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=e.result==="victory"?"승리":e.result==="defeat"?"패배":e.result==="draw"?"무승부":"종료",s=e.result==="victory"?"#34d399":e.result==="defeat"?"#f87171":"#9ca3af",a=[e.reason?`원인: ${t(e.reason)}`:null,e.phase?`페이즈: ${t(e.phase)}`:null,typeof e.turn=="number"?`턴: ${e.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${e.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${t(e.summary)}</div>`:null}
      ${a?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function gc({state:e}){const t=e.history??[];return t.length===0?null:i`
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
  `}function t$({state:e,nowMs:t}){var m;const n=Fe.value||((m=e.session)==null?void 0:m.room)||"",s=$s.value,a=e.party??[];if(!a.find(u=>u.id===zt.value)&&a.length>0){const u=a[0];u&&(zt.value=u.id)}const l=async()=>{var _,f;if(!n){z("Room ID가 비어 있습니다.","error");return}if(!Ms(t))return;const u=((_=e.current_round)==null?void 0:_.phase)??((f=e.session)==null?void 0:f.status)??"unknown";if(zi("라운드 실행",n,u)){$s.value="running";try{const $=await Kd(n);wi.value=$,$s.value="ok";const S=v($.summary)?$.summary:null,h=S?Wn(S,"advanced",!1):!1,C=S?$e(S,"progress_reason",""):"";z(h?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${C?`: ${C}`:""}`,h?"success":"warning"),et()}catch($){wi.value=null,$s.value="error";const S=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";z(S,"error")}finally{$a()}}},c=async()=>{var _,f;if(!n||!Ms(t))return;const u=((_=e.current_round)==null?void 0:_.phase)??((f=e.session)==null?void 0:f.status)??"unknown";if(zi("턴 강제 진행",n,u))try{await Hd(n),z("턴을 다음 단계로 이동했습니다.","success"),et()}catch{z("턴 이동에 실패했습니다.","error")}finally{$a()}},p=async()=>{if(!n||!Ms(t))return;const u=zt.value.trim();if(!u){z("먼저 Actor를 선택하세요.","warning");return}const _=Number.parseInt(Ga.value,10),f=Number.parseInt(Ja.value,10);if(Number.isNaN(_)||Number.isNaN(f)){z("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(fs.value,10),S=fs.value.trim()===""||Number.isNaN($)?void 0:$;try{await Ud({roomId:n,actorId:u,action:Wa.value.trim()||"ability_check",statValue:_,dc:f,rawD20:S}),z("주사위 판정을 기록했습니다.","success"),et()}catch{z("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${u=>{Fe.value=u.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${zt.value}
            onChange=${u=>{zt.value=u.target.value}}
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
              value=${Wa.value}
              onInput=${u=>{Wa.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Ga.value}
              onInput=${u=>{Ga.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ja.value}
              onInput=${u=>{Ja.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${fs.value}
              onInput=${u=>{fs.value=u.target.value}}
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
  `}function n$({state:e}){var a;const t=Fe.value||((a=e.session)==null?void 0:a.room)||"",n=bs.value,s=async()=>{if(!t){z("Room ID가 비어 있습니다.","warning");return}const o=ys.value.trim(),l=Xa.value.trim();if(!l&&!o){z("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Tn.value.trim(),10),p=Number.parseInt(si.value.trim(),10),m=Number.isFinite(p)?Math.max(1,p):20,u=Number.isFinite(c)?Math.max(0,Math.min(m,c)):m;let _={};try{_=Bf(ai.value)}catch(f){z(f instanceof Error?f.message:"능력치 JSON 오류","error");return}bs.value="spawning";try{const f=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await Wd(t,{actor_id:o||void 0,name:l||void 0,role:Za.value,idempotencyKey:f,portrait:ti.value.trim()||void 0,background:ni.value.trim()||void 0,hp:u,max_hp:m,alive:u>0,stats:Object.keys(_).length>0?_:void 0}),S=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!S)throw new Error("생성 응답에 actor_id가 없습니다.");const h=ei.value.trim();h&&await Gd(t,S,h),zt.value=S,Je.value=S,o||(ys.value=""),bs.value="ok",z(`Actor 생성 완료: ${S}`,"success"),await et()}catch(f){bs.value="error",z(f instanceof Error?f.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Xa.value}
            onInput=${o=>{Xa.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Za.value}
            onChange=${o=>{Za.value=o.target.value}}
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
            value=${ei.value}
            onInput=${o=>{ei.value=o.target.value}}
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
              value=${ys.value}
              onInput=${o=>{ys.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${ti.value}
              onInput=${o=>{ti.value=o.target.value}}
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
              value=${Tn.value}
              onInput=${o=>{Tn.value=o.target.value}}
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
              value=${si.value}
              onInput=${o=>{const l=o.target.value;si.value=l,Uf(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ni.value}
              onInput=${o=>{ni.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${ai.value}
              onInput=${o=>{ai.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function s$({state:e,nowMs:t}){var f;const n=Fe.value||((f=e.session)==null?void 0:f.room)||"",s=e.join_gate,a=Qa.value,o=v(a)?a:null,l=(e.party??[]).filter($=>$.role!=="dm"),c=Je.value.trim(),p=l.some($=>$.id===c),m=p?c:c?"__manual__":"",u=async()=>{const $=Je.value.trim(),S=hs.value.trim();if(!n||!$){z("Room/Actor가 필요합니다.","warning");return}xe.value="checking";try{const h=await Jd(n,$,S||void 0);Qa.value=h,xe.value="ok",z("참가 가능 여부를 갱신했습니다.","success")}catch(h){xe.value="error";const C=h instanceof Error?h.message:"참가 가능 여부 확인에 실패했습니다.";z(C,"error")}},_=async()=>{var x,k;const $=Je.value.trim(),S=hs.value.trim(),h=Ya.value.trim();if(!n||!$||!S){z("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Ms(t))return;const C=((x=e.current_round)==null?void 0:x.phase)??((k=e.session)==null?void 0:k.status)??"unknown";if(zi("Mid-Join 승인 요청",n,C)){xe.value="requesting";try{const N=await Vd({room_id:n,actor_id:$,keeper_name:S,role:Va.value,...h?{name:h}:{}});Qa.value=N;const R=v(N)?Wn(N,"granted",!1):!1,P=v(N)?$e(N,"reason_code",""):"";R?z("Mid-Join이 승인되었습니다.","success"):z(`Mid-Join이 거절되었습니다${P?`: ${P}`:""}`,"warning"),xe.value=R?"ok":"error",et()}catch(N){xe.value="error";const R=N instanceof Error?N.message:"Mid-Join 요청에 실패했습니다.";z(R,"error")}finally{$a()}}};return i`
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
            onChange=${$=>{const S=$.target.value;if(S==="__manual__"){(p||!c)&&(Je.value="");return}Je.value=S}}
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
                value=${Je.value}
                onInput=${$=>{Je.value=$.target.value}}
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
            value=${hs.value}
            onInput=${$=>{hs.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Va.value}
            onChange=${$=>{Va.value=$.target.value}}
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
            value=${Ya.value}
            onInput=${$=>{Ya.value=$.target.value}}
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
            Eligible: <strong>${Wn(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Pe(o,"effective_score",0)}/${Pe(o,"required_points",0)}</span>
            ${$e(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${$e(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function fc({state:e}){const t=[...e.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return t.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${t.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function $c({state:e}){var n;const t=e.current_round;return t?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${t.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${t.phase}</div>
      ${t.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=t.events[t.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function hc(){const e=wi.value;if(!e)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const t=e.summary,n=v(t)?t:null,a=(Array.isArray(e.statuses)?e.statuses:[]).filter(v).slice(-8),o=e.canon_check,l=v(o)?o:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(P=>typeof P=="string").slice(0,3):[],p=l&&Array.isArray(l.violations)?l.violations.filter(P=>typeof P=="string").slice(0,3):[],m=n?Wn(n,"advanced",!1):!1,u=n?$e(n,"progress_reason",""):"",_=n?$e(n,"progress_detail",""):"",f=n?Pe(n,"player_successes",0):0,$=n?Pe(n,"player_required_successes",0):0,S=n?Wn(n,"dm_success",!1):!1,h=n?Pe(n,"timeouts",0):0,C=n?Pe(n,"unavailable",0):0,x=n?Pe(n,"reprompts",0):0,k=n?Pe(n,"npc_attacks",0):0,N=n?Pe(n,"keeper_timeout_sec",0):0,R=n?Pe(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${m?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${m?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${e.turn_before??0} → ${e.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${S?"DM ok":"DM stalled"} / players ${f}/${$}
          </span>
        </div>
        ${u?i`<div style="margin-top:4px; font-size:12px;">${u}</div>`:null}
        ${_?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${_}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${h}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${N||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${R}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(P=>{const L=$e(P,"status","unknown"),I=$e(P,"actor_id","-"),w=$e(P,"role","-"),Q=$e(P,"reason",""),se=$e(P,"action_type",""),J=$e(P,"reply","");return i`
                <div class="trpg-round-item ${L.includes("fallback")||L.includes("timeout")?"failed":"active"}">
                  <span>${I} (${w})</span>
                  <span style="margin-left:auto; font-size:11px;">${L}</span>
                  ${se?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${se}</div>`:null}
                  ${Q?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${Q}</div>`:null}
                  ${J?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${J.slice(0,120)}</div>`:null}
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
                  ${p.map(P=>i`<div>violation: ${P}</div>`)}
                </div>`:null}
            ${c.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(P=>i`<div>warning: ${P}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function a$({state:e,nowMs:t}){var l,c,p;const n=Fe.value||((l=e.session)==null?void 0:l.room)||"",s=((c=e.current_round)==null?void 0:c.phase)??((p=e.session)==null?void 0:p.status)??"unknown",a=pc(t),o=Gf(t);return i`
    <${T} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${o}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>Jf(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{$a(),z("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function i$({active:e}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${e===n.id?"active":""}"
          role="tab"
          aria-selected=${e===n.id}
          onClick=${()=>Wf(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function o$({state:e}){const t=e.party??[],n=e.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${T} title="관전 가이드" semanticId="lab.trpg">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${T} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${_c} events=${n.slice(-20)} />
        <//>

        ${e.map?i`
            <${T} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${Xf} mapStr=${e.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${T} title="현재 라운드" semanticId="lab.trpg">
          <${$c} state=${e} />
        <//>

        <${T} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${fc} state=${e} />
        <//>

        <${T} title=${`파티 (${t.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${t.map(s=>i`<${vc} key=${s.id??s.name} actor=${s} />`)}
            ${t.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${e.history&&e.history.length>0?i`
            <${T} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
              <${gc} state=${e} />
            <//>
          `:null}
      </div>
    </div>
  `}function r$({state:e}){const t=e.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${T} title=${`이벤트 타임라인 (${t.length})`}>
          <${Zf} events=${t} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${T} title="최근 라운드 결과" semanticId="lab.trpg">
          <${hc} />
        <//>

        <${T} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${$c} state=${e} />
        <//>
      </div>
    </div>
  `}function l$({state:e,nowMs:t}){const n=e.party??[];return i`
    <div>
      <${a$} state=${e} nowMs=${t} />
      <div class="trpg-layout">
        <div>
          <${T} title="조작 패널" semanticId="lab.trpg">
            <${t$} state=${e} nowMs=${t} />
          <//>

          <${T} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${n$} state=${e} />
          <//>

          <${T} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${s$} state=${e} nowMs=${t} />
          <//>

          <${T} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${hc} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${T} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${fc} state=${e} />
          <//>

          <${T} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${vc} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${e.history&&e.history.length>0?i`
              <${T} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
                <${gc} state=${e} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function c$(){var c,p,m,u,_;const e=Dr.value,t=hi.value;if(te(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const f=window.setInterval(()=>{ir.value=Date.now()},1e3);return()=>{window.clearInterval(f)}},[]),t&&!e)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!e)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>et()}>Refresh</button>
      </div>
    `;const n=e.party??[],s=e.story_log??[],a=e.outcome,o=uc.value,l=ir.value;return i`
    <div>
      <${be} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Fe.value||((c=e.session)==null?void 0:c.room)||"-"} · phase: ${((p=e.current_round)==null?void 0:p.phase)??((m=e.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>et()}>새로고침</button>
      </div>

      <${e$} outcome=${a} />

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

      <${i$} active=${o} />

      ${o==="overview"?i`<${o$} state=${e} />`:o==="timeline"?i`<${r$} state=${e} />`:i`<${l$} state=${e} nowMs=${l} />`}
    </div>
  `}const yc=g(null),Mi=g(null),Es=g(!1);async function d$(){if(!Es.value){Es.value=!0,Mi.value=null;try{yc.value=await cd()}catch(e){Mi.value=e instanceof Error?e.message:String(e)}finally{Es.value=!1}}}function u$(e){switch(e){case"essential":return"badge-essential";case"standard":return"badge-standard";default:return"badge-full"}}function p$({items:e,maxCount:t}){return e.length===0?i`<p class="muted">No tool calls recorded yet.</p>`:i`
    <div class="tool-bar-chart">
      ${e.map(n=>{const s=t>0?n.call_count/t*100:0;return i`
          <div class="tool-bar-row" key=${n.name}>
            <span class="tool-bar-name">${n.name}</span>
            <span class="tool-bar-tier ${u$(n.tier)}">${n.tier}</span>
            <div class="tool-bar-track">
              <div class="tool-bar-fill" style=${{width:`${s}%`}} />
            </div>
            <span class="tool-bar-count">${n.call_count}</span>
          </div>
        `})}
    </div>
  `}function m$({dist:e}){const t=e.full,n=t>0?(e.essential/t*100).toFixed(1):"0",s=t>0?(e.standard/t*100).toFixed(1):"0",a=t-e.standard,o=t>0?(a/t*100).toFixed(1):"0";return i`
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
  `}function v$(){const e=yc.value,t=Es.value,n=Mi.value;return i`
    <div class="tool-metrics">
      <div class="tool-metrics-header">
        <h3 class="tool-metrics-title">Tool Usage</h3>
        <button
          class="control-btn ghost"
          onClick=${()=>void d$()}
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
            <${m$} dist=${e.tier_distribution} />
          </div>
          <div class="tool-metrics-section">
            <h4>Top 20 Tools</h4>
            <${p$}
              items=${e.top_20}
              maxCount=${e.top_20.length>0?e.top_20[0].call_count:0}
            />
          </div>
        </div>
      `:t?null:i`
        <p class="muted">Click Load to fetch tool usage statistics.</p>
      `}
    </div>
  `}function _$(){return i`
    <div>
      <${be} surfaceId="lab" />
      <${T} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${T} title="Tool Usage Metrics" class="section" semanticId="lab.tool_metrics">
        <${v$} />
      <//>

      <${T} title="TRPG" class="section" semanticId="lab.trpg">
        <${c$} />
      <//>
    </div>
  `}const ha=g(new Set(["broadcast","tasks","keepers","system"]));function g$(e){const t=new Set(ha.value);t.has(e)?t.delete(e):t.add(e),ha.value=t}const _o=g(null);function bc(e){_o.value=e}function f$(e){return e.kind==="board"?"broadcast":e.kind==="tasks"?"tasks":e.kind==="keepers"?"keepers":"system"}const $$=Ae(()=>{const e=ha.value;return Ds.value.filter(t=>e.has(f$(t)))}),h$=12e4,y$=Ae(()=>{const e=Kr.value,t=Date.now();return Ue.value.map(n=>{const s=n.name.trim().toLowerCase(),a=e.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?o=t-new Date(l).getTime()>h$?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),b$=Ae(()=>{const e=Kr.value;return Ue.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle").map(t=>{const n=t.name.trim().toLowerCase(),s=e.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:t.name,emoji:t.emoji??"",koreanName:t.koreanName??null,currentTask:t.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((t,n)=>{const s={hot:0,normal:1,calm:2};return s[t.pressure]-s[n.pressure]})});function or(e){return e.kind==="board"?"live-event-broadcast":e.kind==="tasks"?"live-event-task":e.kind==="keepers"?"live-event-keeper":"live-event-system"}function k$(e){const t=e.eventType;return t==="broadcast"?"broadcast":t==="agent_joined"?"joined":t==="agent_left"?"left":t==="task_update"?"task":t==="board_post"?"post":t==="board_comment"?"comment":t==="keeper_heartbeat"?"heartbeat":t==="keeper_handoff"?"handoff":t==="keeper_compaction"?"compact":t==="keeper_guardrail"?"guardrail":e.kind==="board"?"board":e.kind==="tasks"?"task":e.kind==="keepers"?"keeper":"system"}function x$(e){switch(e){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function S$(){const e=y$.value,t=_o.value;return e.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${e.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${x$(n.state)} ${t===n.name?"pulse-selected":""}"
          onClick=${()=>bc(t===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const A$=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function C$(){const e=ha.value;return i`
    <div class="activity-filter-bar">
      ${A$.map(t=>i`
        <button
          key=${t.kind}
          class="activity-filter-btn ${t.cssClass} ${e.has(t.kind)?"active":""}"
          onClick=${()=>g$(t.kind)}
        >
          ${t.label}
        </button>
      `)}
    </div>
  `}function T$(){const e=$$.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${e.length} events</span>
      </div>
      <${C$} />
      <div class="activity-stream-list">
        ${e.length===0?i`<div class="activity-empty">No events matching filters</div>`:e.map((t,n)=>i`
            <div
              key=${`${t.timestamp}-${n}`}
              class="activity-item ${or(t)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${or(t)}">${k$(t)}</span>
                <span class="activity-agent">${t.agent}</span>
                <span class="activity-time">${pl(t.timestamp)}</span>
              </div>
              <div class="activity-item-text">${t.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function I$(e){switch(e){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function R$(e){switch(e){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function P$(){const e=b$.value,t=_o.value;return i`
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
              onClick=${()=>bc(t===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${I$(n.pressure)}">
                  ${R$(n.pressure)}
                  ${n.assignedCount>0?i` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?i`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?i`<span class="focus-activity-text">${n.lastActivityText}</span>`:i`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?i`<${G} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function L$(){const e=st.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>Live Monitor</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${e?"connected":"disconnected"}"></span>
            ${e?"Connected":"Offline"}
          </span>
          <span class="live-stat">${Ue.value.length} agents</span>
          <span class="live-stat">${ya.value} events</span>
        </div>
      </div>

      <${S$} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${T$} />
        </div>
        <div class="live-panel-side">
          <${P$} />
        </div>
      </div>
    </div>
  `}const rr=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],Ei=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"proof",label:"Proof",icon:"🔍",group:"observe",description:"협업, 대화, 도구, backing evidence를 증명 중심으로 읽는 표면"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"live",label:"Live",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}],xs=g(!1);function w$(){const e=st.value;return i`
    <div class="connection-status ${e?"connected":"disconnected"}">
      <span class="status-dot ${e?"connected":"disconnected"}"></span>
      <span class="status-text">${e?"Live":"재연결 중..."}</span>
      <span class="event-count">${ya.value} events</span>
    </div>
  `}function kc(e){const t=e==null?void 0:e.trim();return t?t.length>10?t.slice(0,10):t:"commit unavailable"}function N$(){const e=ne.value,t=e==null?void 0:e.build,n=t?`v${t.release_version} · ${kc(t.commit)}`:e!=null&&e.version?`v${e.version} · commit unavailable`:"version unavailable";return i`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${xs.value}
        onClick=${()=>{xs.value=!xs.value}}
      >
        Server Build · ${n}
      </button>
      ${xs.value?i`
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
                <strong>${t!=null&&t.started_at?i`<${G} timestamp=${t.started_at} />`:"unknown"}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof(t==null?void 0:t.uptime_seconds)=="number"?`${t.uptime_seconds}s`:"unknown"}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${e!=null&&e.generated_at?i`<${G} timestamp=${e.generated_at} />`:"unknown"}</strong>
              </div>
            </div>
          `:null}
    </div>
  `}function ji(e){e==="command"&&(jt(),Vt(),(Z.value==="swarm"||Z.value==="warroom")&&Ve(),Z.value==="warroom"&&ye()),e==="mission"&&(tl(),Us()),e==="proof"&&Tl(F.value.params.session_id,F.value.params.operation_id),e==="execution"&&yt(),e==="intervene"&&(ye(),Ct()),e==="memory"&&Ze(),e==="planning"&&Hi(),e==="lab"&&et()}function z$({currentTab:e}){var a,o,l,c;const t=st.value,n=(a=ne.value)==null?void 0:a.build,s=(o=ne.value)==null?void 0:o.gardener;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${q} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${t?"ok":"bad"}">${t?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agent</span>
          <strong>${Ue.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keeper</span>
          <strong>${lt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Task</span>
          <strong>${Qe.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Event</span>
          <strong>${ya.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Jn(),Wr(),ji(e)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>de("intervene")}>
          개입 열기
        </button>
      </div>
      ${n?i`<div class="rail-build-hint">Server Build · v${n.release_version} · ${kc(n.commit)}</div>`:null}
      ${s?i`
        <div style="margin-top:12px; padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
          <div class="rail-card-head" style="margin:0;">
            <h3 style="font-size:12px;">Gardener</h3>
            <span class="rail-section-chip ${s.alive?"ok":s.enabled?"warn":"bad"}">
              ${s.alive?"Live":s.enabled?"Starting":"Disabled"}
            </span>
          </div>
          <div class="build-badge-row">
            <span>Last tick</span>
            <strong>${s.last_tick_completed_at?i`<${G} timestamp=${s.last_tick_completed_at} />`:"never"}</strong>
          </div>
          <div class="build-badge-row">
            <span>Decision</span>
            <strong>${s.last_intervention??"none"} · ${s.last_decision_source??"none"}</strong>
          </div>
          <div class="build-badge-row">
            <span>Action</span>
            <strong>${s.last_action??"none"}</strong>
          </div>
          <div class="build-badge-row">
            <span>Backlog</span>
            <strong>${((l=s.health_summary)==null?void 0:l.todo_count)??0} todo · P1/2 ${((c=s.health_summary)==null?void 0:c.high_priority_todo)??0}</strong>
          </div>
          ${s.last_reason?i`<div class="rail-build-hint">Reason · ${s.last_reason}</div>`:null}
          ${s.last_error?i`<div class="rail-build-hint" style="color:#fca5a5;">Error · ${s.last_error}</div>`:null}
        </div>
      `:null}
    </section>
  `}function M$(){const e=_e.value,t=(e==null?void 0:e.pending_confirms.length)??0,n=(e==null?void 0:e.sessions.length)??0,s=(e==null?void 0:e.keepers.length)??0;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${q} panelId="side_rail.quick_actions" compact=${!0} />
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
          onClick=${()=>{ye(),Ct()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>de("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function E$(){const e=F.value.tab,t=Ei.find(s=>s.id===e),n=rr.find(s=>s.id===(t==null?void 0:t.group));return i`
    <aside class="dashboard-rail">
      <${be} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${q} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${rr.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${Ei.filter(a=>a.group===s.id).map(a=>i`
                  <button
                    class="rail-tab-btn ${e===a.id?"active":""}"
                    onClick=${()=>de(a.id)}
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

      <${z$} currentTab=${e} />
      <${M$} />
    </aside>
  `}function j$(){switch(F.value.tab){case"mission":return i`<${Do} />`;case"proof":return i`<${T_} />`;case"execution":return i`<${rf} />`;case"live":return i`<${L$} />`;case"memory":return i`<${Yg} />`;case"governance":return i`<${zf} />`;case"planning":return i`<${bf} />`;case"intervene":return i`<${jg} />`;case"command":return i`<${Ng} />`;case"lab":return i`<${_$} />`;default:return i`<${Do} />`}}function D$(){te(()=>{Nc(),_r(),Gr(),yt(),Wr(),tl();const n=tp();return np(),()=>{Fc(),n(),sp()}},[]),te(()=>{const n=setInterval(()=>{ji(F.value.tab)},15e3);return()=>{clearInterval(n)}},[]),te(()=>{ji(F.value.tab)},[F.value.tab]);const e=F.value.tab,t=Ei.find(n=>n.id===e);return i`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <${N$} />
          </h1>
          <p class="header-subtitle">${(t==null?void 0:t.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${w$} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${E$} />
        <main class="dashboard-main">
          ${$i.value&&!st.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${j$} />`}
        </main>
      </div>

      <${Mm} />
      <${tm} />
      <${Gp} />
    </div>
  `}const lr=document.getElementById("app");lr&&Ic(i`<${D$} />`,lr);export{Hm as _};
