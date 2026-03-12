var Ad=Object.defineProperty;var Id=(e,t,n)=>t in e?Ad(e,t,{enumerable:!0,configurable:!0,writable:!0,value:n}):e[t]=n;var Dt=(e,t,n)=>Id(e,typeof t!="symbol"?t+"":t,n);import{e as Td,_ as Rd,c as f,b as Me,y as ae,d as vo,A as Ks,G as Md}from"./vendor-kuFK4-oj.js";(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const l of o.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=Td.bind(Rd);const Ld=["mission","proof","execution","tools","live","memory","governance","planning","intervene","command","lab"],rl={tab:"mission",params:{},postId:null};function ir(e){return!!e&&Ld.includes(e)}function Pi(e){try{return decodeURIComponent(e)}catch{return e}}function Ei(e){const t={};return e&&new URLSearchParams(e).forEach((s,a)=>{t[a]=s}),t}function zd(e){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function ll(e,t){if(e[0]==="chains"){const o={...t,surface:"chains"};return e[1]==="operation"&&e[2]&&(o.operation=Pi(e[2])),{tab:"command",params:o,postId:null}}if(e[0]==="lab"){const o={...t};return e[1]&&(o.surface=Pi(e[1])),{tab:"lab",params:o,postId:null}}const n=e[0],s=t.tab;return{tab:ir(n)?n:ir(s)?s:"mission",params:t,postId:null}}function ta(e){const t=(e||"").replace(/^#/,"").trim();if(!t)return rl;const n=Pi(t);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=Ei(a),l=zd(s);return ll(l,o)}function Pd(e,t){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...rl,params:Ei(t.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Ei(t.replace(/^\?/,""));return ll(s,a)}function cl(e){const t=e.tab==="lab"&&e.params.surface?`lab/${encodeURIComponent(e.params.surface)}`:e.tab,n=Object.entries(e.params).filter(([a])=>!(a==="tab"||e.tab==="lab"&&a==="surface"));if(n.length===0)return`#${t}`;const s=new URLSearchParams(n);return`#${t}?${s.toString()}`}const O=f(ta(window.location.hash));window.addEventListener("hashchange",()=>{O.value=ta(window.location.hash)});function oe(e,t){const n={tab:e,params:t??{}};window.location.hash=cl(n)}function Ed(e){window.location.hash=`#memory?post=${encodeURIComponent(e)}`}function jd(){if(window.location.hash&&window.location.hash!=="#"){O.value=ta(window.location.hash);return}const e=Pd(window.location.pathname,window.location.search);if(e){O.value=e;const t=cl(e);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${t}`);return}window.location.hash="#mission",O.value=ta(window.location.hash)}const or="masc_dashboard_sse_session_id",Nd=1e3,Dd=15e3,dt=f(!1),wa=f(0),dl=f(null),na=f([]);function Od(){let e=sessionStorage.getItem(or);return e||(e=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(or,e)),e}const qd=200;function Fd(e,t,n="system",s={}){const a={agent:e,text:t,timestamp:Date.now(),kind:n,...s};na.value=[a,...na.value].slice(0,qd)}function ji(e,t=88){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-3)}...`:n:void 0}function rr(e,t){const n=ji(t);return n?`${e}: ${n}`:`New ${e.toLowerCase()}`}function Ie(e,t,n,s,a={}){Fd(e,t,n,{eventType:s,...a})}let je=null,Jt=null,Ni=0;function ul(){Jt&&(clearTimeout(Jt),Jt=null)}function wd(){if(Jt)return;Ni++;const e=Math.min(Ni,5),t=Math.min(Dd,Nd*Math.pow(2,e));Jt=setTimeout(()=>{Jt=null,pl()},t)}function pl(){ul(),je&&(je.close(),je=null);const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");n&&t.set("agent",n),s&&t.set("token",s),t.set("session_id",Od());const a=t.toString()?`/sse?${t.toString()}`:"/sse",o=new EventSource(a);je=o,o.onopen=()=>{je===o&&(Ni=0,dt.value=!0)},o.onerror=()=>{je===o&&(dt.value=!1,o.close(),je=null,wd())},o.onmessage=l=>{try{const c=JSON.parse(l.data);wa.value++,dl.value=c,Kd(c)}catch{}}}function Kd(e){const t=e.type,n=e.agent??e.author??e.from??e.from_agent??"";switch(t){case"agent_joined":Ie(n,"Joined","system","agent_joined");break;case"agent_left":Ie(n,"Left","system","agent_left");break;case"broadcast":Ie(n,`${(e.message??e.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":Ie(n,`Task: ${e.task_id??""} -> ${e.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":Ie(n,rr("Post",e.content??e.message),"board","board_post",{author:e.author??n,preview:ji(e.content??e.message),postId:e.post_id});break;case"board_comment":case"masc/board_comment":Ie(n,rr("Comment",e.content??e.message),"board","board_comment",{author:e.author??n,preview:ji(e.content??e.message),postId:e.post_id});break;case"keeper_heartbeat":Ie(e.name??n,`Heartbeat gen=${e.generation??"?"} ctx=${e.context_ratio!=null?Math.round(e.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":Ie(e.name??n,`Handoff gen ${e.from_generation??"?"} -> ${e.to_generation??"?"} (${e.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":Ie(e.name??n,`Compaction saved ${e.saved_tokens??"?"} tokens (${e.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":Ie(e.name??n,`Guardrail: ${e.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:Ie(n,t,"system","unknown")}}function Bd(){ul(),je&&(je.close(),je=null),dt.value=!1}function m(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function r(e){return typeof e=="string"&&e.trim()!==""?e.trim():void 0}function d(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function j(e){return typeof e=="boolean"?e:void 0}function w(e){return Array.isArray(e)?e.map(t=>typeof t=="string"?t.trim():"").filter(Boolean):[]}function pe(e,t=[]){if(Array.isArray(e))return e;if(!m(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function re(e){if(typeof e=="string"&&e.trim()!=="")return e;if(!(typeof e!="number"||!Number.isFinite(e)||e<=0))return new Date(e*1e3).toISOString()}function go(){return new URLSearchParams(window.location.search)}const Ud="masc_dashboard_agent_name";function ml(){var e;try{return((e=localStorage.getItem(Ud))==null?void 0:e.trim())||null}catch{return null}}function fo(){var t,n;const e=go();return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||ml()||"dashboard"}function _l(){const e=go(),t={},n=e.get("token"),s=ml(),a=e.get("agent")??e.get("agent_name")??s;return n&&(t.Authorization=`Bearer ${n}`),a&&(t["X-MASC-Agent"]=a),t}function vl(){return{..._l(),"Content-Type":"application/json"}}const Hd=15e3,$o=3e4,Wd=6e4,lr=new Set([408,425,429,500,502,503,504]);class is extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);Dt(this,"method");Dt(this,"path");Dt(this,"status");Dt(this,"statusText");Dt(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function ho(e,t,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(e,{...t,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const l=typeof t.method=="string"?t.method.toUpperCase():"GET";throw new is({method:l,path:e,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function Gd(){var t,n;const e=go();return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function ne(e){const t=await ho(e,{headers:_l()},Hd);if(!t.ok)throw new is({method:"GET",path:e,status:t.status,statusText:t.statusText});return t.json()}function Jd(e){return new Promise(t=>setTimeout(t,e))}function Yd(e){const t=e.match(/\b(\d{3})\b/);if(!t)return null;const n=t[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function Vd(e){if(e instanceof is)return e.timeout||typeof e.status=="number"&&lr.has(e.status);if(!(e instanceof Error))return!1;if(/timeout after \d+ms/i.test(e.message))return!0;const t=Yd(e.message);return t!==null&&lr.has(t)}async function Ka(e,t,n=2){let s=0;for(;;)try{return await t()}catch(a){if(!Vd(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${e} failed (attempt ${s+1}), retrying in ${o}ms`,a),await Jd(o),s+=1}}async function Fe(e,t,n,s=$o){const a=await ho(e,{method:"POST",headers:{...vl(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new is({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.json()}async function Xd(e,t,n,s=$o){const a=await ho(e,{method:"POST",headers:{...vl(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new is({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.text()}function Qd(e){const t=e.split(`
`).find(s=>s.startsWith("data: ")),n=t?t.slice(6).trim():e.trim();return JSON.parse(n)}function Zd(e){var t,n,s,a,o,l,c;if((t=e.error)!=null&&t.message)throw new Error(e.error.message);if((n=e.result)!=null&&n.isError){const p=((a=(s=e.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(p)}return((c=(l=(o=e.result)==null?void 0:o.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function Et(e,t){const n=await Xd("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:e,arguments:t},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Wd),s=Qd(n);return Zd(s)}function eu(){return ne("/api/v1/dashboard/shell")}function tu(){return ne("/api/v1/dashboard/room-truth")}function nu(){return ne("/api/v1/dashboard/execution")}function su(e,t){const n=new URLSearchParams;return n.set("sort_by",e),t!=null&&t.excludeSystem&&n.set("exclude_system","true"),ne(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function au(){return Ka("fetchDashboardGovernance",async()=>{const e=await ne("/api/v1/dashboard/governance"),t=Array.isArray(e.items)?e.items.map(o=>xu(o)).filter(o=>o!==null):[],n=Array.isArray(e.pending_actions)?e.pending_actions.map(o=>$l(o)).filter(o=>o!==null):[],s=t.filter(o=>o.kind==="debate").map(o=>({id:o.id,topic:o.topic,status:o.status,argument_count:o.evidence_refs.length,created_at:o.last_activity_at??void 0})),a=t.filter(o=>o.kind==="consensus").map(o=>({id:o.id,topic:o.topic,initiator:o.related_agents[0]||"system",votes:o.votes??0,quorum:o.quorum??0,threshold:o.threshold,state:o.status,created_at:o.last_activity_at??void 0}));return{generated_at:de(e.generated_at)??void 0,summary:m(e.summary)?{debates:ve(e.summary.debates)??void 0,voting_sessions:ve(e.summary.voting_sessions)??void 0,debates_open:ve(e.summary.debates_open)??void 0,sessions_active:ve(e.summary.sessions_active)??void 0,sessions_without_quorum:ve(e.summary.sessions_without_quorum)??void 0,ready_to_execute:ve(e.summary.ready_to_execute)??void 0,oldest_open_debate_age_s:typeof e.summary.oldest_open_debate_age_s=="number"?e.summary.oldest_open_debate_age_s:null,last_activity_age_s:typeof e.summary.last_activity_age_s=="number"?e.summary.last_activity_age_s:null,judge_online:typeof e.summary.judge_online=="boolean"?e.summary.judge_online:void 0,judge_last_seen_at:de(e.summary.judge_last_seen_at)}:void 0,debates:s,sessions:a,items:t,activity:Array.isArray(e.activity)?e.activity.map(o=>Su(o)).filter(o=>o!==null):[],judge:Cu(e.judge),pending_actions:n}})}function iu(){return ne("/api/v1/dashboard/semantics")}function ou(){return ne("/api/v1/dashboard/mission")}function ru(e){const t=`?session_id=${encodeURIComponent(e)}`;return ne(`/api/v1/dashboard/session${t}`)}function lu(e=!1){return ne(`/api/v1/dashboard/mission/briefing${e?"?force=1":""}`)}function cu(e,t){const n=new URLSearchParams;e&&n.set("session_id",e),t&&n.set("operation_id",t);const s=n.toString();return ne(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function du(){return ne("/api/v1/dashboard/planning")}function uu(){return ne("/api/v1/tool-metrics")}function pu(){return ne("/api/v1/dashboard/tools")}function mu(){return ne("/api/v1/operator")}function gl(e={}){const t=new URLSearchParams;e.targetType&&t.set("target_type",e.targetType),e.targetId&&t.set("target_id",e.targetId),e.includeWorkers!=null&&t.set("include_workers",e.includeWorkers?"true":"false");const n=t.toString();return ne(`/api/v1/operator/digest${n?`?${n}`:""}`)}function _u(){return ne("/api/v1/command-plane")}function vu(){return ne("/api/v1/command-plane/summary")}function gu(){return ne("/api/v1/chains/summary")}function fu(e){return ne(`/api/v1/chains/runs/${encodeURIComponent(e)}`)}function $u(){return ne("/api/v1/command-plane/help")}function hu(e,t){const n=new URLSearchParams;e&&n.set("run_id",e),t&&n.set("operation_id",t);const s=n.toString();return ne(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function yu(e,t){const n=new URLSearchParams;e&&n.set("run_id",e),t&&n.set("operation_id",t);const s=n.toString();return ne(`/api/v1/command-plane/orchestra${s?`?${s}`:""}`)}function bu(e,t){return Fe(e,t)}function ku(e){switch(e.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"swarm_run_continue":return 6e4;case"swarm_run_rerun":return 12e4;case"swarm_run_abandon":return 3e4;case"lodge_tick":return 45e3;default:return $o}}function os(e){return Fe("/api/v1/operator/action",e,void 0,ku(e))}function fl(e,t,n="confirm"){return Fe("/api/v1/operator/confirm",{actor:e,confirm_token:t,decision:n})}function Bs(e){if(typeof e=="string"&&e.trim())return e;if(typeof e!="number"||Number.isNaN(e))return new Date().toISOString();const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}function de(e){if(typeof e=="string"){const t=e.trim();return t||null}if(typeof e=="number"&&Number.isFinite(e)){const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}return null}function K(e){if(typeof e!="string")return null;const t=e.trim();return t||null}function $l(e){if(!m(e))return null;const t=x(e.confirm_token??e.token,"").trim();return t?{confirm_token:t,actor:K(e.actor)??void 0,action_type:K(e.action_type)??void 0,target_type:K(e.target_type)??void 0,target_id:K(e.target_id),delegated_tool:K(e.delegated_tool)??void 0,created_at:de(e.created_at)??void 0,preview:e.preview}:null}function yo(e){return m(e)?{board_post_id:K(e.board_post_id),task_id:K(e.task_id),operation_id:K(e.operation_id),team_session_id:K(e.team_session_id)}:{}}function hl(e){if(!m(e))return null;const t=K(e.action_kind),n=K(e.resolved_tool),s=K(e.target_type),a=K(e.target_id),o=K(e.reason);return!t&&!n&&!s&&!o?null:{action_kind:t??void 0,resolved_tool:n,target_type:s,target_id:a,reason:o??void 0,payload_preview:e.payload_preview}}function yl(e){if(!m(e))return null;const t=K(e.action_type),n=K(e.delegated_tool),s=K(e.confirmation_state),a=de(e.created_at);return!t&&!n&&!s&&!a?null:{action_type:t??void 0,delegated_tool:n,confirmation_state:s??void 0,created_at:a}}function bl(e){if(!m(e))return null;const t=$l(e.pending_confirm),n=K(e.pending_confirm_token)??(t==null?void 0:t.confirm_token)??null;return{requires_human_gate:typeof e.requires_human_gate=="boolean"?e.requires_human_gate:void 0,pending_confirm:t,pending_confirm_token:n,ready_to_execute:typeof e.ready_to_execute=="boolean"?e.ready_to_execute:void 0}}function kl(e){if(!m(e))return null;const t=K(e.summary),n=K(e.target_id);return!t&&!n?null:{judgment_id:K(e.judgment_id)??void 0,target_kind:K(e.target_kind)??void 0,target_id:n??void 0,status:K(e.status)??void 0,summary:t??void 0,confidence:typeof e.confidence=="number"?e.confidence:null,generated_at:de(e.generated_at),expires_at:de(e.expires_at),model_used:K(e.model_used),keeper_name:K(e.keeper_name),evidence_refs:Ne(e.evidence_refs),recommended_action:hl(e.recommended_action),guardrail_state:bl(e.guardrail_state),executed_route:yl(e.executed_route)}}function xu(e){if(!m(e))return null;const t=x(e.id,"").trim(),n=x(e.topic,"").trim();if(!t||!n)return null;const s=yo(e.context);return{kind:x(e.kind,"debate"),id:t,topic:n,status:x(e.status??e.state,"open"),last_activity_at:de(e.last_activity_at),truth_summary:K(e.truth_summary)??void 0,judgment_summary:K(e.judgment_summary),confidence:typeof e.confidence=="number"?e.confidence:null,related_agents:Ne(e.related_agents),context:s,linked_board_post_id:K(e.linked_board_post_id)??s.board_post_id??null,linked_task_id:K(e.linked_task_id)??s.task_id??null,linked_operation_id:K(e.linked_operation_id)??s.operation_id??null,linked_session_id:K(e.linked_session_id)??s.team_session_id??null,recommended_action:hl(e.recommended_action),executed_route:yl(e.executed_route),guardrail_state:bl(e.guardrail_state),evidence_refs:Ne(e.evidence_refs),approve_count:ve(e.approve_count),reject_count:ve(e.reject_count),abstain_count:ve(e.abstain_count),votes:ve(e.votes),quorum:ve(e.quorum),threshold:typeof e.threshold=="number"?e.threshold:void 0}}function Su(e){if(!m(e))return null;const t=x(e.kind,"").trim();return t?{kind:t,item_kind:K(e.item_kind)??void 0,item_id:K(e.item_id)??void 0,topic:K(e.topic)??void 0,created_at:de(e.created_at),summary:K(e.summary)??void 0,actor:K(e.actor),index:ve(e.index),decision:K(e.decision)}:null}function Cu(e){if(m(e))return{judge_online:typeof e.judge_online=="boolean"?e.judge_online:void 0,refreshing:typeof e.refreshing=="boolean"?e.refreshing:void 0,generated_at:de(e.generated_at),expires_at:de(e.expires_at),model_used:K(e.model_used),keeper_name:K(e.keeper_name),last_error:K(e.last_error)}}function Au(e){var a;const t=e.trim(),s=((a=(t.startsWith("[flair:")?t.replace(/^\[flair:[^\]]+\]\s*/i,""):t).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Iu(e){if(!m(e))return null;const t=x(e.source,"").trim()||null,n=x(e.state_block,"").trim()||null;return!t&&!n?null:{source:t,state_block:n}}function Tu(e){if(!m(e))return null;const t=x(e.id,"").trim(),n=x(e.author,"").trim(),s=x(e.body,"").trim()||x(e.content,"").trim(),a=s;if(!t||!n)return null;const o=U(e.score,0),l=U(e.votes_up,0),c=U(e.votes_down,0),p=U(e.votes,o||l-c),_=U(e.comment_count,U(e.reply_count,0)),u=(()=>{const k=e.flair;if(typeof k=="string"&&k.trim())return k.trim();if(m(k)){const S=x(k.name,"").trim();if(S)return S}return x(e.flair_name,"").trim()||void 0})(),v=x(e.created_at_iso,"").trim()||Bs(e.created_at),g=x(e.updated_at_iso,"").trim()||(e.updated_at!==void 0?Bs(e.updated_at):v),C=x(e.title,"").trim()||Au(s),b=Array.isArray(e.tags)?e.tags.filter(k=>typeof k=="string"&&k.trim()!==""):[];return{id:t,author:n,post_kind:(()=>{const k=x(e.post_kind,"").trim().toLowerCase();return k==="automation"||k==="system"||k==="human"?k:void 0})(),title:C,body:s,content:a,meta:Iu(e.meta),tags:b,votes:p,vote_balance:o,comment_count:_,created_at:v,updated_at:g,flair:u,hearth:x(e.hearth,"").trim()||null,visibility:x(e.visibility,"").trim()||void 0,expires_at:x(e.expires_at_iso,"").trim()||(e.expires_at!==void 0&&e.expires_at!==0?Bs(e.expires_at):"")||null,hearth_count:U(e.hearth_count,0)}}function Ru(e){if(!m(e))return null;const t=x(e.id,"").trim(),n=x(e.post_id,"").trim(),s=x(e.author,"").trim();return!t||!s?null:{id:t,post_id:n,author:s,content:x(e.content,""),created_at:Bs(e.created_at)}}async function Mu(e){return Ka("fetchBoardPost",async()=>{const t=await ne(`/api/v1/board/${e}?format=flat`),n=m(t.post)?t.post:t,s=Tu(n)??{id:e,author:"unknown",post_kind:"human",title:"Post",body:"",content:"",meta:null,tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(t.comments)?t.comments:[]).map(Ru).filter(l=>l!==null);return{...s,comments:o}})}function xl(e,t){return Fe("/api/v1/tools/masc_board_vote",{post_id:e,direction:t,vote:t,voter:Gd()})}function Lu(e,t,n){return Fe("/api/v1/tools/masc_board_comment",{post_id:e,author:t,content:n})}function zu(e){const t=x(e,"").trim().toLowerCase();if(t==="win"||t==="won"||t==="victory")return"victory";if(t==="lose"||t==="lost"||t==="defeat")return"defeat";if(t==="draw"||t==="stalemate"||t==="tie")return"draw"}function ue(...e){for(const t of e){const n=x(t,"");if(n.trim())return n.trim()}return""}function cr(e){const t=zu(ue(e.outcome,e.result,e.result_code));if(!t)return;const n=ue(e.reason,e.reason_code,e.description,e.detail),s=ue(e.summary,e.summary_ko,e.summary_en,e.note),a=ue(e.details,e.details_text,e.text,e.note),o=ue(e.winner,e.winner_name,e.actor_winner,e.winner_actor),l=ue(e.winner_actor_id,e.winner_actor,e.actor_winner_id),c=ue(e.raw_reason,e.raw_reason_code,e.error_message),p=(()=>{const v=e.evidence??e.evidence_ids??e.supporting_events??e.event_ids??[];return typeof v=="string"?[v]:Array.isArray(v)?v.map(g=>{if(typeof g=="string")return g.trim();if(m(g)){const $=x(g.summary,"").trim();if($)return $;const C=x(g.text,"").trim();if(C)return C;const b=x(g.type,"").trim();return b||x(g.event_id,"").trim()}return""}).filter(g=>g.length>0):[]})(),_=(()=>{const v=U(e.turn,Number.NaN);if(Number.isFinite(v))return v;const g=U(e.turn_number,Number.NaN);if(Number.isFinite(g))return g;const $=U(e.current_turn,Number.NaN);if(Number.isFinite($))return $;const C=U(e.round,Number.NaN);return Number.isFinite(C)?C:void 0})(),u=ue(e.phase,e.phase_name,e.current_phase,e.phase_id);return{result:t,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:l||void 0,evidence:p.length>0?p:void 0,raw_reason:c||void 0,turn:_,phase:u||void 0}}function Pu(e,t){const n=m(e.state)?e.state:{};if(x(n.status,"active").toLowerCase()!=="ended")return;const a=[...t].reverse().find(l=>m(l)?x(l.type,"")==="session.outcome":!1),o=m(n.session_outcome)?n.session_outcome:{};if(m(o)&&Object.keys(o).length>0){const l=cr(o);if(l)return l}if(m(a))return cr(m(a.payload)?a.payload:{})}function x(e,t=""){return typeof e=="string"?e:t}function U(e,t=0){return typeof e=="number"&&Number.isFinite(e)?e:t}function ve(e){if(typeof e=="number"&&Number.isFinite(e))return Math.trunc(e);if(typeof e=="string"){const t=Number.parseInt(e.trim(),10);if(Number.isFinite(t))return t}}function sa(e,t=!1){return typeof e=="boolean"?e:t}function Ne(e){return Array.isArray(e)?e.map(t=>{if(typeof t=="string")return t.trim();if(m(t)){const n=x(t.name,"").trim(),s=x(t.id,"").trim(),a=x(t.skill,"").trim();return n||s||a}return""}).filter(t=>t.length>0):[]}function Eu(e){const t={};if(!m(e)&&!Array.isArray(e))return t;if(m(e))return Object.entries(e).forEach(([n,s])=>{const a=n.trim(),o=x(s,"").trim();!a||!o||(t[a]=o)}),t;for(const n of e){if(!m(n))continue;const s=ue(n.to,n.target,n.actor_id,n.name,n.id),a=ue(n.relationship,n.relation,n.type,n.kind);!s||!a||(t[s]=a)}return t}function ju(e,t,n){if(e==="dm"||e==="player"||e==="npc")return e;const s=t.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function xe(e,t,n,s=0){const a=e[t];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=e[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const Nu=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Du(e){const t=m(e.stats)?e.stats:{},n={};return Object.entries(t).forEach(([s,a])=>{const o=s.trim();o&&(Nu.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function Ou(e,t){if(e!=="dice.rolled")return;const n=U(t.raw_d20,0),s=U(t.total,0),a=U(t.bonus,0),o=x(t.action,"roll"),l=U(t.dc,0);return{notation:l>0?`${o} (DC ${l})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function qu(e){const t=JSON.stringify(e);return t?t.length>160?`${t.slice(0,157)}...`:t:""}function Fu(e){const t=e.trim().toLowerCase();return t?t.startsWith("dice.")?"dice":t.startsWith("combat.")||t.includes(".attack")||t.includes(".damage")?"combat":t.includes("actor.")?"actor":t.includes("turn.")||t==="turn.started"||t==="phase.changed"?"turn":t.includes("join.")?"join":t.includes("memory")?"memory":t.includes("world.")?"world":t.includes("narration")?"story":"meta":"meta"}function wu(e,t,n,s){const a=n||t||x(s.actor_id,"")||x(s.actor_name,"");switch(e){case"turn.action.proposed":{const o=x(s.proposed_action,x(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=x(s.reply,x(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return x(s.reply,x(s.content,x(s.text,"Narration")));case"dice.rolled":{const o=x(s.action,"roll"),l=U(s.total,0),c=U(s.dc,0),p=x(s.label,""),_=a||"actor",u=c>0?` vs DC ${c}`:"",v=p?` (${p})`:"";return`${_} ${o}: ${l}${u}${v}`}case"turn.started":return`Turn ${U(s.turn,1)} started`;case"phase.changed":return`Phase: ${x(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${x(s.name,m(s.actor)?x(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${x(s.keeper_name,x(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${x(s.keeper_name,x(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${U(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${U(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||x(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||x(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${x(s.reason_code,"unknown")}`;case"memory.signal":{const o=m(s.entity_refs)?s.entity_refs:{},l=x(o.requested_tier,""),c=x(o.effective_tier,""),p=sa(o.guardrail_applied,!1),_=x(s.summary_en,x(s.summary_ko,"Memory signal"));if(!l&&!c)return _;const u=l&&c?`${l}->${c}`:c||l;return`${_} [${u}${p?" (guardrail)":""}]`}case"world.event":{if(x(s.event_type,"")==="canon.check"){const l=x(s.status,"unknown"),c=x(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return x(s.description,x(s.summary,"World event"))}case"combat.attack":return x(s.summary,x(s.result,"Attack resolved"));case"combat.defense":return x(s.summary,x(s.result,"Defense resolved"));case"session.outcome":return x(s.summary,x(s.outcome,"Session ended"));default:{const o=qu(s);return o?`${e}: ${o}`:e}}}function Ku(e,t){const n=m(e)?e:{},s=x(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=x(n.actor_name,"").trim()||t[a]||x(m(n.payload)?n.payload.actor_name:"",""),l=m(n.payload)?n.payload:{},c=x(n.ts,x(n.timestamp,new Date().toISOString())),p=x(n.phase,x(l.phase,"")),_=x(n.category,"");return{type:s,actor:o||a||x(l.actor_name,""),actor_id:a||x(l.actor_id,""),actor_name:o,seq:n.seq,room_id:x(n.room_id,""),phase:p||void 0,category:_||Fu(s),visibility:x(n.visibility,x(l.visibility,"public")),event_id:x(n.event_id,""),content:wu(s,a,o,l),dice_roll:Ou(s,l),timestamp:c}}function Bu(e,t,n){var Q,ie;const s=x(e.room_id,"")||n||"default",a=m(e.state)?e.state:{},o=m(a.party)?a.party:{},l=m(a.actor_control)?a.actor_control:{},c=m(a.join_gate)?a.join_gate:{},p=m(a.contribution_ledger)?a.contribution_ledger:{},_=Object.entries(o).map(([E,I])=>{const A=m(I)?I:{},Z=xe(A,"max_hp",void 0,10),se=xe(A,"hp",void 0,Z),G=xe(A,"max_mp",void 0,0),Ke=xe(A,"mp",void 0,0),B=xe(A,"level",void 0,1),Le=xe(A,"xp",void 0,0),ft=sa(A.alive,se>0),gn=l[E],fn=typeof gn=="string"?gn:void 0,vs=ju(A.role,E,fn),gs=ve(A.generation),fs=ue(A.joined_at,A.joinedAt,A.started_at,A.startedAt),$s=ue(A.claimed_at,A.claimedAt,A.assigned_at,A.assignedAt,A.assigned_time),hs=ue(A.last_seen,A.lastSeen,A.last_seen_at,A.lastSeenAt,A.last_active,A.lastActive),ys=ue(A.scene,A.current_scene,A.currentScene,A.world_scene,A.scene_name,A.sceneName),bs=ue(A.location,A.current_location,A.currentLocation,A.position,A.zone,A.area);return{id:E,name:x(A.name,E),role:vs,keeper:fn,archetype:x(A.archetype,""),persona:x(A.persona,""),portrait:x(A.portrait,"")||void 0,background:x(A.background,"")||void 0,traits:Ne(A.traits),skills:Ne(A.skills),stats_raw:Du(A),status:ft?"active":"dead",generation:gs,joined_at:fs||void 0,claimed_at:$s||void 0,last_seen:hs||void 0,scene:ys||void 0,location:bs||void 0,inventory:Ne(A.inventory),notes:Ne(A.notes),relationships:Eu(A.relationships),stats:{hp:se,max_hp:Z,mp:Ke,max_mp:G,level:B,xp:Le,strength:xe(A,"strength","str",10),dexterity:xe(A,"dexterity","dex",10),constitution:xe(A,"constitution","con",10),intelligence:xe(A,"intelligence","int",10),wisdom:xe(A,"wisdom","wis",10),charisma:xe(A,"charisma","cha",10)}}}),u=_.filter(E=>E.status!=="dead"),v=Pu(e,t),g={phase_open:sa(c.phase_open,!0),min_points:U(c.min_points,3),window:x(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},$=Object.entries(p).map(([E,I])=>{const A=m(I)?I:{};return{actor_id:E,score:U(A.score,0),last_reason:x(A.last_reason,"")||null,reasons:Ne(A.reasons)}}),C=_.reduce((E,I)=>(E[I.id]=I.name,E),{}),b=t.map(E=>Ku(E,C)),k=U(a.turn,1),h=x(a.phase,"round"),S=x(a.map,""),L=m(a.world)?a.world:{},M=S||x(L.ascii_map,x(L.map,"")),P=b.filter((E,I)=>{const A=t[I];if(!m(A))return!1;const Z=m(A.payload)?A.payload:{};return U(Z.turn,-1)===k}),H=(P.length>0?P:b).slice(-12),T=x(a.status,"active");return{session:{id:s,room:s,status:T==="ended"?"ended":T==="paused"?"paused":"active",round:k,actors:u,created_at:((Q=b[0])==null?void 0:Q.timestamp)??new Date().toISOString()},current_round:{round_number:k,phase:h,events:H,timestamp:((ie=b[b.length-1])==null?void 0:ie.timestamp)??new Date().toISOString()},map:M||void 0,join_gate:g,contribution_ledger:$,outcome:v,party:u,story_log:b,history:[]}}async function Uu(e){const t=`?room_id=${encodeURIComponent(e)}`,n=await ne(`/api/v1/trpg/events${t}`);return Array.isArray(n.events)?n.events:[]}async function Hu(e){const t=`?room_id=${encodeURIComponent(e)}`,[n,s]=await Promise.all([ne(`/api/v1/trpg/state${t}`),Uu(e)]);return Bu(n,s,e)}function Wu(e){return Fe("/api/v1/trpg/rounds/run",{room_id:e})}function Gu(e){const t="".trim().toLowerCase();if(t)switch(t){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return t}}function Ju(e){const t={room_id:e.roomId,actor_id:e.actorId,action:e.action,stat_value:e.statValue,dc:e.dc};return e.rawD20!=null&&(t.raw_d20=e.rawD20),e.ruleModule&&(t.rule_module=e.ruleModule),Fe("/api/v1/trpg/dice/roll",t)}function Yu(e,t){const n=Gu();return Fe("/api/v1/trpg/turns/advance",{room_id:e,...n?{phase:n}:{}})}function Vu(e,t){var a;const n=(a=t.idempotencyKey)==null?void 0:a.trim(),s={room_id:e};return t.actor_id&&t.actor_id.trim()&&(s.actor_id=t.actor_id.trim()),t.name&&t.name.trim()&&(s.name=t.name.trim()),t.role&&(s.role=t.role),t.archetype&&t.archetype.trim()&&(s.archetype=t.archetype.trim()),t.persona&&t.persona.trim()&&(s.persona=t.persona.trim()),t.portrait&&t.portrait.trim()&&(s.portrait=t.portrait.trim()),t.background&&t.background.trim()&&(s.background=t.background.trim()),t.hp!=null&&(s.hp=t.hp),t.max_hp!=null&&(s.max_hp=t.max_hp),t.alive!=null&&(s.alive=t.alive),Array.isArray(t.traits)&&t.traits.length>0&&(s.traits=t.traits),Array.isArray(t.skills)&&t.skills.length>0&&(s.skills=t.skills),Array.isArray(t.inventory)&&t.inventory.length>0&&(s.inventory=t.inventory),t.stats&&Object.keys(t.stats).length>0&&(s.stats=t.stats),n&&(s.idempotency_key=n),Fe("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function Xu(e,t,n){return Fe("/api/v1/trpg/actors/claim",{room_id:e,actor_id:t,keeper:n})}async function Qu(e,t,n){const s=await Et("trpg.join.eligibility",{room_id:e,actor_id:t,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function Zu(e){const t=await Et("trpg.mid_join.request",e);return JSON.parse(t)}async function ep(e,t){await Et("masc_broadcast",{agent_name:e,message:t})}async function tp(e=40){return(await Et("masc_messages",{limit:e})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function np(e,t=20){return Et("masc_task_history",{task_id:e,limit:t})}async function sp(e){const t=await Et("masc_debate_start",{topic:e});try{return JSON.parse(t)}catch{return null}}async function ap(e){return Ka("fetchDebateStatus",async()=>{const t=encodeURIComponent(e),n=await ne(`/api/v1/council/debates/${t}/summary`);if(!m(n))return null;const s=m(n.debate)?n.debate:n,a=x(s.id,"").trim(),o=x(s.topic,"").trim();return!a||!o?null:{debate:{id:a,topic:o,status:x(s.status,"open"),created_at:de(s.created_at_iso??s.created_at),closed_at:de(s.closed_at)},arguments:Array.isArray(n.arguments)?n.arguments.flatMap(l=>m(l)?[{index:U(l.index,0),agent:x(l.agent,"unknown"),position:x(l.position,"neutral"),content:x(l.content,""),evidence:Ne(l.evidence),reply_to:ve(l.reply_to)??null,mentions:Ne(l.mentions),archetype:K(l.archetype),created_at:de(l.created_at)}]:[]):[],summary:{support_count:m(n.summary)?U(n.summary.support_count,0):U(n.support_count,0),oppose_count:m(n.summary)?U(n.summary.oppose_count,0):U(n.oppose_count,0),neutral_count:m(n.summary)?U(n.summary.neutral_count,0):U(n.neutral_count,0),total_arguments:m(n.summary)?U(n.summary.total_arguments,0):U(n.total_arguments,0),summary_text:m(n.summary)?x(n.summary.summary_text,""):x(n.summary_text,"")},context:yo(n.context),judgment:kl(n.judgment)}})}async function ip(e){return Ka("fetchConsensusSessionSummary",async()=>{const t=encodeURIComponent(e),n=await ne(`/api/v1/council/sessions/${t}/summary`);if(!m(n)||!m(n.session))return null;const s=n.session,a=x(s.id,"").trim(),o=x(s.topic,"").trim();return!a||!o?null:{session:{id:a,topic:o,state:x(s.state,"open"),initiator:x(s.initiator,"system"),quorum:U(s.quorum,0),threshold:U(s.threshold,0),created_at:de(s.created_at),closed_at:de(s.closed_at)},votes:Array.isArray(n.votes)?n.votes.flatMap(l=>m(l)?[{agent:x(l.agent,"unknown"),decision:x(l.decision,"abstain"),reason:x(l.reason,""),timestamp:de(l.timestamp),weight:typeof l.weight=="number"?l.weight:void 0,archetype:K(l.archetype)}]:[]):[],summary:{approve_count:m(n.summary)?U(n.summary.approve_count,0):0,reject_count:m(n.summary)?U(n.summary.reject_count,0):0,abstain_count:m(n.summary)?U(n.summary.abstain_count,0):0,quorum_met:m(n.summary)?sa(n.summary.quorum_met,!1):!1,result:m(n.summary)?K(n.summary.result):null},context:yo(n.context),judgment:kl(n.judgment)}})}const op=f(""),Je=f({}),me=f({}),Di=f({}),Oi=f({}),qi=f({}),Fi=f({}),Ye=f({});function ce(e,t,n){e.value={...e.value,[t]:n}}function rp(e){var n;const t=(n=r(e))==null?void 0:n.toLowerCase();return t==="user"||t==="assistant"||t==="system"||t==="tool"?t:"other"}function lp(e){switch(e){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Za(e,t){if(!Array.isArray(e))return[];const n=[];for(const s of e){if(!m(s))continue;const a=r(s.name);if(!a)continue;const o=r(s[t]);t==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function cp(e){if(!m(e))return null;const t=r(e.name);return t?{name:t,trigger:r(e.trigger),outcome:r(e.outcome),summary:r(e.summary),reason:r(e.reason)}:null}function dp(e){const t=e.toLowerCase();return t.includes("graphql")?"graphql_error":t.includes("timeout")||t.includes("model")||t.includes("llm")||t.includes("api key")||t.includes("api_key")||t.includes("provider")?"llm_error":"unknown"}function up(e,t){return e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":t==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":t==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":t==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Sl(e,t,n){return r(e)??up(t,n)}function Cl(e,t){return typeof e=="boolean"?e:t==="recover"}function aa(e){if(!m(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);return!t||!n||!s?null:{health_state:t,quiet_reason:r(e.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:re(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:Cl(e.recoverable,n),summary:Sl(e.summary,t,r(e.quiet_reason)??null),keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function Al(e){return m(e)?{hour:d(e.hour),checked:d(e.checked)??0,acted:d(e.acted)??0,acted_names:w(e.acted_names),activity_report:r(e.activity_report),quiet_hours_overridden:j(e.quiet_hours_overridden),skipped_reason:r(e.skipped_reason),acted_rows:Za(e.acted_rows,"summary").map(t=>({name:t.name,summary:t.summary})),passed_rows:Za(e.passed_rows,"reason").map(t=>({name:t.name,reason:t.reason})),skipped_rows:Za(e.skipped_rows,"reason").map(t=>({name:t.name,reason:t.reason})),checkins:Array.isArray(e.checkins)?e.checkins.map(cp).filter(t=>t!==null):[]}:null}function pp(e){return m(e)?{enabled:j(e.enabled)??!1,interval_s:d(e.interval_s)??0,quiet_start:d(e.quiet_start),quiet_end:d(e.quiet_end),quiet_active:j(e.quiet_active),use_planner:j(e.use_planner),delegate_llm:j(e.delegate_llm),agent_count:d(e.agent_count),agents:w(e.agents),last_tick_ago_s:d(e.last_tick_ago_s)??null,last_tick_ago:r(e.last_tick_ago),total_ticks:d(e.total_ticks),total_checkins:d(e.total_checkins),last_skip_reason:r(e.last_skip_reason)??null,last_tick_result:Al(e.last_tick_result),active_self_heartbeats:w(e.active_self_heartbeats)}:null}function mp(e){return m(e)?{status:e.status,diagnostic:aa(e.diagnostic)}:null}function _p(e){return m(e)?{recovered:j(e.recovered)??!1,skipped_reason:r(e.skipped_reason)??null,before:aa(e.before),after:aa(e.after),down:e.down,up:e.up}:null}function vp(e,t){var S,L;if(!(e!=null&&e.name))return null;const n=r((S=e.agent)==null?void 0:S.status)??r(e.status)??"unknown",s=r((L=e.agent)==null?void 0:L.error)??null,a=e.presence_keepalive??!0,o=e.keepalive_running??!1,l=e.turn_count??0,c=e.last_turn_ago_s??null,p=e.proactive_enabled??!1,_=e.proactive_cooldown_sec??0,u=e.last_proactive_ago_s??null,v=p&&u!=null?Math.max(0,_-u):null,g=l<=0||c==null?"never":c>900?"stale":"fresh",$=typeof e.last_heartbeat=="string"&&e.last_heartbeat.trim()?e.last_heartbeat:null,C=s??(a&&!o?"keeper keepalive is not running":null),b=n==="offline"||n==="inactive"?"offline":C?"degraded":g==="stale"?"stale":g==="never"?"idle":"healthy",k=C?dp(C):t!=null&&t.quiet_active&&g!=="fresh"?"quiet_hours":a&&!o?"disabled":l<=0?"never_started":v!=null&&v>0?"min_gap":g==="fresh"||g==="stale"?"no_recent_activity":"unknown",h=b==="offline"||b==="degraded"||b==="stale"?"recover":k==="quiet_hours"?"manual_lodge_poke":k==="unknown"?"probe":"direct_message";return{health_state:b,quiet_reason:k,next_action_path:h,last_reply_status:g,last_reply_at:$,last_reply_preview:null,last_error:C,next_eligible_at_s:v!=null&&v>0?v:null,recoverable:Cl(void 0,h),summary:Sl(void 0,b,k),keepalive_running:o}}function gp(e,t){if(!m(e))return null;const n=rp(e.role),s=r(e.content)??r(e.preview);if(!s)return null;const a=re(e.ts_unix)??re(e.timestamp);return{id:`${n}-${a??"entry"}-${t}`,role:n,label:lp(n),text:s,timestamp:a,delivery:"history"}}function fp(e,t,n){const s=m(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,l)=>gp(o,l)).filter(o=>o!==null):[];return{name:e,diagnostic:aa(s==null?void 0:s.diagnostic),history:a,rawText:t,rawStatus:n,loadedAt:new Date().toISOString()}}function $p(e){if(typeof e=="string")return e.trim();if(!m(e))return"";const t=r(e.reply)??r(e.content)??r(e.text)??r(e.message);if(t&&t.trim())return t.trim();const n=e.result;if(typeof n=="string")return n.trim();if(m(n)){const s=r(n.reply)??r(n.content)??r(n.text)??r(n.message);return(s==null?void 0:s.trim())??""}return""}function dr(e,t){const n=me.value[e]??[];me.value={...me.value,[e]:[...n,t].slice(-50)}}function hp(e,t){return e.role!==t.role||e.text!==t.text?!1:e.timestamp&&t.timestamp?e.timestamp===t.timestamp:!0}function yp(e,t){const s=(me.value[e]??[]).filter(a=>a.delivery!=="history"&&!t.some(o=>hp(a,o)));me.value={...me.value,[e]:[...t,...s].slice(-50)}}function Ba(e,t){Je.value={...Je.value,[e]:t},yp(e,t.history)}function ur(e,t){const n=Je.value[e];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ba(e,{...n,diagnostic:{...s,...t}})}async function bo(){try{await rs()}catch(e){console.warn("[keeper-runtime] dashboard refresh failed",e)}}function bp(e){op.value=e.trim()}async function Il(e,t=!1){const n=e.trim();if(!n)return null;if(!t&&Je.value[n])return Je.value[n];ce(Di,n,!0),ce(Ye,n,null);try{const s=await Et("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=fp(n,s,a);return Ba(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return ce(Ye,n,a),null}finally{ce(Di,n,!1)}}async function kp(e,t){const n=e.trim(),s=t.trim();if(!n||!s)return;const a=fo(),o=`local-${Date.now()}`;dr(n,{id:o,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),ce(Oi,n,!0),ce(Ye,n,null);try{const l=await os({actor:a,action_type:"keeper_message",target_type:"keeper",target_id:n,payload:{message:s}}),c=$p(l.result);me.value={...me.value,[n]:(me.value[n]??[]).map(p=>p.id===o?{...p,delivery:"delivered"}:p)},dr(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:c.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),ur(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(c.trim()||"(empty reply)").slice(0,200),last_error:null}),await bo()}catch(l){const c=l instanceof Error?l.message:`Failed to send direct message to ${n}`;throw me.value={...me.value,[n]:(me.value[n]??[]).map(p=>p.id===o?{...p,delivery:"error",error:c}:p)},ur(n,{last_reply_status:"error",last_error:c}),ce(Ye,n,c),l}finally{ce(Oi,n,!1)}}async function xp(e,t){const n=e.trim();if(!n)return null;ce(qi,n,!0),ce(Ye,n,null);try{const s=await os({actor:t,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=mp(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const l=Je.value[n];Ba(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??me.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await bo(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw ce(Ye,n,a),s}finally{ce(qi,n,!1)}}async function Sp(e,t){const n=e.trim();if(!n)return null;ce(Fi,n,!0),ce(Ye,n,null);try{const s=await os({actor:t,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=_p(s.result),o=(a==null?void 0:a.after)??null;if(o){const l=Je.value[n];Ba(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??me.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await bo(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw ce(Ye,n,a),s}finally{ce(Fi,n,!1)}}function $t(e){return(e??"").trim().toLowerCase()}function fe(e){const t=typeof e=="number"?e:Date.parse(e);return Number.isNaN(t)?0:t}function Us(e,t=88){const n=e.replace(/\s+/g," ").trim();return n&&(n.length>t?`${n.slice(0,t-3)}...`:n)}function xs(e){return typeof e!="number"||!Number.isFinite(e)||e<0?null:new Date(Date.now()-e*1e3).toISOString()}function $n(e){return e.last_heartbeat??xs(e.last_turn_ago_s)??xs(e.last_proactive_ago_s)??xs(e.last_handoff_ago_s)??xs(e.last_compaction_ago_s)}function Cp(e){const t=e.title.trim();return t||Us(e.content)}function Ap(e){const t=e.generation??"?",n=typeof e.context_ratio=="number"&&Number.isFinite(e.context_ratio)?`${Math.round(e.context_ratio*100)}%`:"?";return e.last_heartbeat?`Heartbeat gen=${t} ctx=${n}`:`Keeper snapshot gen=${t} ctx=${n}`}function Ip(e,t,n,s,a={}){var L;const o=$t(e),l=t.filter(M=>$t(M.assignee)===o&&(M.status==="claimed"||M.status==="in_progress")).length,c=n.filter(M=>$t(M.from)===o).sort((M,P)=>fe(P.timestamp)-fe(M.timestamp))[0],p=s.filter(M=>$t(M.agent)===o||$t(M.author)===o).sort((M,P)=>fe(P.timestamp)-fe(M.timestamp))[0],_=(a.boardPosts??[]).filter(M=>$t(M.author)===o).sort((M,P)=>fe(P.updated_at||P.created_at)-fe(M.updated_at||M.created_at))[0],u=(a.keepers??[]).filter(M=>$t(M.name)===o&&$n(M)!==null).sort((M,P)=>fe($n(P)??0)-fe($n(M)??0))[0],v=c?fe(c.timestamp):0,g=p?fe(p.timestamp):0,$=_?fe(_.updated_at||_.created_at):0,C=u?fe($n(u)??0):0,b=a.lastSeen?fe(a.lastSeen):0,k=((L=a.currentTask)==null?void 0:L.trim())||(l>0?`${l} claimed tasks`:null);if(v===0&&g===0&&$===0&&C===0&&b===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:k};const S=[c?{timestamp:c.timestamp,ts:v,text:Us(c.content)}:null,_?{timestamp:_.updated_at||_.created_at,ts:$,text:`Post: ${Us(Cp(_))}`}:null,u?{timestamp:$n(u),ts:C,text:Ap(u)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:g,text:Us(p.text)}:null].filter(M=>M!==null).sort((M,P)=>P.ts-M.ts)[0];return S&&S.ts>=b?{activeAssignedCount:l,lastActivityAt:S.timestamp,lastActivityText:S.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:k??"Presence heartbeat"}}const Ve=f([]),st=f([]),wi=f([]),_t=f([]),ge=f(null),Tp=f(null),Tl=f([]),Rl=f([]),Ml=f([]),Ll=f([]),zl=f(null),Pl=f([]),ko=f([]),El=f([]),Ki=f(new Map),Ua=f([]),On=f("recent"),Ct=f(!0),jl=f(null),We=f(""),Yt=f([]),An=f(!1),Nl=f(new Map),xo=f("unknown"),Vt=f(null),Bi=f(!1),qn=f(!1),Ui=f(!1),In=f(!1),So=f(null),ia=f(!1),oa=f(null),Dl=f(null),Hi=f(null),Rp=f(null),Mp=f(null),Lp=f(null);Me(()=>Ve.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle"));const Ol=Me(()=>{const e=st.value;return{todo:e.filter(t=>t.status==="todo"),inProgress:e.filter(t=>t.status==="in_progress"||t.status==="claimed"),done:e.filter(t=>t.status==="done")}}),ql=Me(()=>{const e=new Map,t=st.value,n=wi.value,s=na.value,a=Ua.value,o=_t.value;for(const l of Ve.value)e.set(l.name.trim().toLowerCase(),Ip(l.name,t,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:o}));return e});function zp(e){var o;const t=((o=e.status)==null?void 0:o.toLowerCase())??"";if(t==="offline"||t==="inactive")return"offline";const n=e.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}Me(()=>{const e=new Map;for(const t of _t.value)e.set(t.name,zp(t));return e});const Pp=12e4;function Ep(e,t){const n=t.get(e.name);if(n!=null)return n;const s=e.last_heartbeat?Date.parse(e.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[e.last_turn_ago_s,e.last_proactive_ago_s,e.last_handoff_ago_s,e.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}Me(()=>{const e=Date.now(),t=new Set,n=Ki.value;for(const s of _t.value){const a=Ep(s,n);a!=null&&e-a>Pp&&t.add(s.name)}return t});function jp(e){return e==="dashboard_refresh"||e==="masc/dashboard_refresh"||e.startsWith("goal_")||e.startsWith("masc/goal_")||e.startsWith("mdal_")||e.startsWith("masc/mdal_")||e.startsWith("operator_")||e.startsWith("masc/operator_")||e.startsWith("command_plane_")||e.startsWith("masc/command_plane_")}function Fl(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="active"||t==="busy"||t==="listening"||t==="idle"||t==="inactive"||t==="offline"?t:t==="in_progress"||t==="claimed"?"busy":"offline"}function Np(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="todo"||t==="in_progress"||t==="claimed"||t==="done"||t==="cancelled"?t:t==="inprogress"?"in_progress":"todo"}function Dp(e){if(!m(e))return null;const t=r(e.name);return t?{name:t,agent_type:r(e.agent_type),status:Fl(e.status),current_task:r(e.current_task)??null,joined_at:r(e.joined_at),last_seen:r(e.last_seen),capabilities:w(e.capabilities),emoji:r(e.emoji),koreanName:r(e.koreanName)??r(e.korean_name),model:r(e.model),traits:w(e.traits),interests:w(e.interests),activityLevel:d(e.activityLevel)??d(e.activity_level),primaryValue:r(e.primaryValue)??r(e.primary_value)}:null}function Op(e){if(!m(e))return null;const t=r(e.id),n=r(e.title);return!t||!n?null:{id:t,title:n,status:Np(e.status),priority:d(e.priority),assignee:r(e.assignee),description:r(e.description),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function qp(e){if(!m(e))return null;const t=r(e.from)??r(e.from_agent)??"system",n=r(e.content)??"",s=r(e.timestamp)??new Date().toISOString();return{id:r(e.id),seq:d(e.seq),from:t,content:n,timestamp:s,type:r(e.type)}}function Co(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="ok"||t==="warn"||t==="bad"?t:"ok"}function at(e){if(!m(e))return null;const t=r(e.surface),n=r(e.label),s=r(e.target_type),a=r(e.target_id),o=r(e.focus_kind);return!t||!n||!s||!a||!o?null:{surface:t==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:o,operation_id:r(e.operation_id)??null,command_surface:r(e.command_surface)??null}}function Fp(e){if(!m(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.summary),a=r(e.target_type),o=r(e.target_id);return!t||!s||!a||!o||n!=="session"&&n!=="operation"?null:{id:t,kind:n,severity:Co(e.severity),status:r(e.status),summary:s,target_type:a,target_id:o,linked_session_id:r(e.linked_session_id)??null,linked_operation_id:r(e.linked_operation_id)??null,last_seen_at:r(e.last_seen_at)??null,top_handoff:at(e.top_handoff),intervene_handoff:at(e.intervene_handoff),command_handoff:at(e.command_handoff)}}function wp(e){if(!m(e))return null;const t=r(e.session_id),n=r(e.goal);return!t||!n?null:{session_id:t,goal:n,room:r(e.room)??null,status:r(e.status),health:r(e.health),member_names:w(e.member_names),linked_operation_id:r(e.linked_operation_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,runtime_blocker:r(e.runtime_blocker)??null,worker_gap_summary:r(e.worker_gap_summary)??null,last_activity_at:r(e.last_activity_at)??null,last_activity_summary:r(e.last_activity_summary)??null,communication_summary:r(e.communication_summary)??null,active_count:d(e.active_count),required_count:d(e.required_count),top_handoff:at(e.top_handoff),intervene_handoff:at(e.intervene_handoff),command_handoff:at(e.command_handoff)}}function Kp(e){if(!m(e))return null;const t=r(e.operation_id),n=r(e.objective);return!t||!n?null:{operation_id:t,objective:n,status:r(e.status),stage:r(e.stage)??null,assigned_unit_id:r(e.assigned_unit_id)??null,assigned_unit_label:r(e.assigned_unit_label)??null,linked_session_id:r(e.linked_session_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,blocker_summary:r(e.blocker_summary)??null,search_status:r(e.search_status)??null,next_tool:r(e.next_tool)??null,updated_at:r(e.updated_at)??null,top_handoff:at(e.top_handoff),command_handoff:at(e.command_handoff)}}function pr(e){if(!m(e))return null;const t=r(e.name)??r(e.agent_name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline"?null:{name:t,agent_name:r(e.agent_name),status:r(e.status),tone:Co(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,active_task_count:d(e.active_task_count),related_session_id:r(e.related_session_id)??null,related_operation_id:r(e.related_operation_id)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),model:r(e.model)??null,recent_output_preview:r(e.recent_output_preview)??null,recent_event:r(e.recent_event)??null}}function Bp(e){return m(e)?{checked:d(e.checked),acted:d(e.acted),passed:d(e.passed),skipped:d(e.skipped),failed:d(e.failed),last_tick_at:r(e.last_tick_at)??null,last_skip_reason:r(e.last_skip_reason)??null,activity_report:r(e.activity_report)??null}:null}function Up(e){if(!m(e))return null;const t=r(e.agent_name),n=r(e.outcome);return!t||!n?null:{agent_name:t,trigger:r(e.trigger)??null,outcome:n,summary:r(e.summary)??null,reason:r(e.reason)??null,allowed_tool_names:w(e.allowed_tool_names)??[],used_tool_names:w(e.used_tool_names)??[],used_tool_call_count:d(e.used_tool_call_count)??null,action_kind:r(e.action_kind)??"none",tool_audit_source:r(e.tool_audit_source)??null,tool_audit_at:r(e.tool_audit_at)??null,checked_at:r(e.checked_at)??null,decision_reason:r(e.decision_reason)??null,worker_name:r(e.worker_name)??null,failure_reason:r(e.failure_reason)??null}}function Hp(e){if(!m(e))return null;const t=r(e.name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:t,agent_name:r(e.agent_name)??null,status:r(e.status),tone:Co(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,last_autonomous_action_at:r(e.last_autonomous_action_at)??null,generation:d(e.generation),turn_count:d(e.turn_count),context_ratio:d(e.context_ratio)??null,continuity:r(e.continuity)??null,lifecycle:r(e.lifecycle)??null,related_session_id:r(e.related_session_id)??null,model:r(e.model)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),skill_reason:r(e.skill_reason)??null,recent_input_preview:r(e.recent_input_preview)??null,recent_output_preview:r(e.recent_output_preview)??null,recent_tool_names:w(e.recent_tool_names)??[],allowed_tool_names:w(e.allowed_tool_names)??[],latest_tool_names:w(e.latest_tool_names)??[],latest_tool_call_count:d(e.latest_tool_call_count)??null,tool_audit_source:r(e.tool_audit_source)??null,tool_audit_at:r(e.tool_audit_at)??null,last_proactive_preview:r(e.last_proactive_preview)??null,continuity_summary:r(e.continuity_summary)??null,skill_route_summary:r(e.skill_route_summary)??null}}function mr(e){if(typeof e.seq=="number"&&Number.isFinite(e.seq))return e.seq;const t=Date.parse(e.timestamp);return Number.isNaN(t)?0:t}function Wp(e,t){if(t.length===0)return e;const n=new Map;for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>mr(s)-mr(a)).slice(-500)}function Gp(e){return Array.isArray(e)?e.map(t=>{if(!m(t))return null;const n=d(t.ts_unix);if(n==null)return null;const s=m(t.handoff)?t.handoff:null;return{ts:n,context_ratio:d(t.context_ratio)??0,context_tokens:d(t.context_tokens)??0,context_max:d(t.context_max)??0,latency_ms:d(t.latency_ms)??0,generation:d(t.generation)??0,channel:typeof t.channel=="string"?t.channel:"turn",is_handoff:s!=null&&t.handoff_performed===!0,is_compaction:t.compacted===!0,compaction_saved_tokens:d(t.compaction_saved_tokens)??0,compaction_trigger:typeof t.compaction_trigger=="string"?t.compaction_trigger:null,model_used:typeof t.model_used=="string"?t.model_used:"",cost_usd:d(t.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?d(s.new_generation)??null:null}}).filter(t=>t!==null):[]}function _r(e){if(!m(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);if(!t||!n||!s)return null;const a=r(e.quiet_reason)??null,o=r(e.summary)??(t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:t,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:re(e.last_reply_at)??r(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:typeof e.recoverable=="boolean"?e.recoverable:n==="recover",summary:o,keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function Jp(e,t){return(Array.isArray(e)?e:m(e)&&Array.isArray(e.keepers)?e.keepers:[]).map(s=>{if(!m(s))return null;const a=m(s.agent)?s.agent:null,o=m(s.context)?s.context:null,l=m(s.metrics_window)?s.metrics_window:void 0,c=r(s.name);if(!c)return null;const p=d(s.context_ratio)??d(o==null?void 0:o.context_ratio),_=r(s.status)??r(a==null?void 0:a.status)??"offline",u=Fl(_),v=r(s.model)??r(s.active_model)??r(s.primary_model),g=w(s.skill_secondary),$=o?{source:r(o.source),context_ratio:d(o.context_ratio),context_tokens:d(o.context_tokens),context_max:d(o.context_max),message_count:d(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,C=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:d(a.last_seen_ago_s),capabilities:w(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,b=Gp(s.metrics_series),k={name:c,runtime_class:s.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:typeof s.desired=="boolean"?s.desired:void 0,resident_registered:typeof s.resident_registered=="boolean"?s.resident_registered:void 0,reconcile_status:r(s.reconcile_status)??null,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:v,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:u,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:d(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:d(s.proactive_idle_sec),proactive_cooldown_sec:d(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:d(s.generation),turn_count:d(s.turn_count)??d(s.total_turns),keeper_age_s:d(s.keeper_age_s),last_turn_ago_s:d(s.last_turn_ago_s),last_handoff_ago_s:d(s.last_handoff_ago_s),last_compaction_ago_s:d(s.last_compaction_ago_s),last_proactive_ago_s:d(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:p,context_tokens:d(s.context_tokens)??d(o==null?void 0:o.context_tokens),context_max:d(s.context_max)??d(o==null?void 0:o.context_max),context_source:r(s.context_source)??r(o==null?void 0:o.source),context:$,traits:w(s.traits),interests:w(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:d(s.activityLevel)??d(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:w(s.recent_tool_names)??[],allowed_tool_names:w(s.allowed_tool_names)??[],latest_tool_names:w(s.latest_tool_names)??[],latest_tool_call_count:d(s.latest_tool_call_count)??null,tool_audit_source:r(s.tool_audit_source)??null,tool_audit_at:re(s.tool_audit_at)??r(s.tool_audit_at)??null,conversation_tail_count:d(s.conversation_tail_count),k2k_count:d(s.k2k_count),handoff_count_total:d(s.handoff_count_total)??d(s.trace_history_count),compaction_count:d(s.compaction_count),last_compaction_saved_tokens:d(s.last_compaction_saved_tokens),diagnostic:_r(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:g,skill_reason:r(s.skill_reason)??null,metrics_series:b.length>0?b:void 0,metrics_window:l,agent:C};return k.diagnostic=_r(s.diagnostic)??vp(k,(t==null?void 0:t.lodge)??null),k}).filter(s=>s!==null)}function Yp(e){if(!m(e))return;const t=r(e.release_version),n=re(e.started_at),s=d(e.uptime_seconds);if(!(!t||!n||s==null))return{release_version:t,commit:r(e.commit)??null,started_at:n,uptime_seconds:s}}function Vp(e){if(m(e))return{enabled:e.enabled===!0,alive:e.alive===!0,status:r(e.status)??void 0,tick_in_progress:typeof e.tick_in_progress=="boolean"?e.tick_in_progress:void 0,tick_count:d(e.tick_count)??void 0,check_interval_sec:d(e.check_interval_sec)??void 0,last_tick_started_at:re(e.last_tick_started_at)??r(e.last_tick_started_at)??null,last_tick_completed_at:re(e.last_tick_completed_at)??r(e.last_tick_completed_at)??null,next_tick_due_at:re(e.next_tick_due_at)??r(e.next_tick_due_at)??null,last_health_check_at:re(e.last_health_check_at)??r(e.last_health_check_at)??null,last_intervention:r(e.last_intervention)??void 0,last_decision_source:r(e.last_decision_source)??void 0,last_action:r(e.last_action)??void 0,last_target:r(e.last_target)??null,last_reason:r(e.last_reason)??null,last_error:r(e.last_error)??null,circuit_open:typeof e.circuit_open=="boolean"?e.circuit_open:void 0,circuit_open_until:re(e.circuit_open_until)??r(e.circuit_open_until)??null,can_spawn:typeof e.can_spawn=="boolean"?e.can_spawn:void 0,can_retire:typeof e.can_retire=="boolean"?e.can_retire:void 0,last_spawn_attempt_at:re(e.last_spawn_attempt_at)??r(e.last_spawn_attempt_at)??null,last_retirement_attempt_at:re(e.last_retirement_attempt_at)??r(e.last_retirement_attempt_at)??null,spawns_today:d(e.spawns_today)??void 0,retirements_today:d(e.retirements_today)??void 0,health_summary:m(e.health_summary)?{total_agents:d(e.health_summary.total_agents)??void 0,active_agents:d(e.health_summary.active_agents)??void 0,idle_agents:d(e.health_summary.idle_agents)??void 0,todo_count:d(e.health_summary.todo_count)??void 0,high_priority_todo:d(e.health_summary.high_priority_todo)??void 0,orphan_count:d(e.health_summary.orphan_count)??void 0,homeostatic_score:d(e.health_summary.homeostatic_score)??void 0,needs_workers:typeof e.health_summary.needs_workers=="boolean"?e.health_summary.needs_workers:void 0}:void 0}}function Xp(e){if(m(e))return{enabled:e.enabled===!0,mode:r(e.mode)??void 0,masc_enabled:typeof e.masc_enabled=="boolean"?e.masc_enabled:void 0,masc_loops_running:typeof e.masc_loops_running=="boolean"?e.masc_loops_running:void 0,runtime_owner:r(e.runtime_owner)??null,zombie_loop_running:typeof e.zombie_loop_running=="boolean"?e.zombie_loop_running:void 0,gc_loop_running:typeof e.gc_loop_running=="boolean"?e.gc_loop_running:void 0,lodge_enabled:typeof e.lodge_enabled=="boolean"?e.lodge_enabled:void 0,lodge_loop_started:typeof e.lodge_loop_started=="boolean"?e.lodge_loop_started:void 0,lodge_running:typeof e.lodge_running=="boolean"?e.lodge_running:void 0,last_zombie_cleanup:re(e.last_zombie_cleanup)??r(e.last_zombie_cleanup)??null,last_gc:re(e.last_gc)??r(e.last_gc)??null,last_lodge:re(e.last_lodge)??r(e.last_lodge)??null,last_zombie_result:r(e.last_zombie_result)??null,last_gc_result:r(e.last_gc_result)??null,last_lodge_result:m(e.last_lodge_result)?{ok:typeof e.last_lodge_result.ok=="boolean"?e.last_lodge_result.ok:void 0,message:r(e.last_lodge_result.message)??void 0}:null}}function Qp(e){if(m(e))return{enabled:e.enabled===!0,started:e.started===!0,agent_name:r(e.agent_name)??null,llm_enabled:typeof e.llm_enabled=="boolean"?e.llm_enabled:void 0,uptime_s:d(e.uptime_s)??void 0,embedded_guardian_loops_running:typeof e.embedded_guardian_loops_running=="boolean"?e.embedded_guardian_loops_running:void 0,guardian_runtime_owner:r(e.guardian_runtime_owner)??null,consumers:w(e.consumers)}}function wl(e,t){return m(e)?{...e,generated_at:t??re(e.generated_at)??void 0,build:Yp(e.build),lodge:pp(e.lodge)??void 0,gardener:Vp(e.gardener)??void 0,guardian:Xp(e.guardian)??void 0,sentinel:Qp(e.sentinel)??void 0}:null}function Kl(e,t){return t?e?{...e,...t,build:t.build??e.build,generated_at:t.generated_at??e.generated_at}:t:e}function Zp(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="running"||t==="interrupted"||t==="completed"||t==="stopped"||t==="error"?t:t.startsWith("error")?"error":"running"}function em(e){if(!m(e))return null;const t=d(e.iteration);if(t==null)return null;const n=d(e.metric_before)??0,s=d(e.metric_after)??n,a=m(e.evidence)?e.evidence:null;return{iteration:t,metric_before:n,metric_after:s,delta:d(e.delta)??s-n,changes:r(e.changes)??"",failed_attempts:r(e.failed_attempts)??"",next_suggestion:r(e.next_suggestion)??"",elapsed_ms:d(e.elapsed_ms)??0,cost_usd:d(e.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:d(a.tool_call_count)??0,tool_names:w(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function tm(e){var o,l;if(!m(e))return null;const t=r(e.loop_id);if(!t)return null;const n=d(e.baseline_metric)??0,s=Array.isArray(e.history)?e.history.map(em).filter(c=>c!==null):[],a=d(e.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:t,profile:r(e.profile)??"unknown",status:Zp(e.status),strict_mode:typeof e.strict_mode=="boolean"?e.strict_mode:void 0,error_message:r(e.error_message)??r(e.error_reason)??null,stop_reason:r(e.stop_reason)??r(e.reason)??null,current_iteration:d(e.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:d(e.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(e.target)??"",stagnation_streak:d(e.stagnation_streak)??0,stagnation_limit:d(e.stagnation_limit)??0,elapsed_seconds:d(e.elapsed_seconds)??0,updated_at:re(e.updated_at)??null,stopped_at:re(e.stopped_at)??null,execution_mode:e.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:e.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(e.worker_model)??null,evidence_policy:e.evidence_policy==="hard"||e.evidence_policy==="legacy"?e.evidence_policy:void 0,latest_tool_call_count:d(e.latest_tool_call_count)??0,latest_tool_names:w(e.latest_tool_names)??[],session_id:r(e.session_id)??null,evidence_status:e.evidence_status==="legacy_unverified"?"legacy_unverified":e.evidence_status==="verified"?"verified":null,durability:e.durability==="persistent_backend"||e.durability==="memory_only"?e.durability:void 0,persistence_backend:e.persistence_backend==="filesystem"||e.persistence_backend==="postgres"||e.persistence_backend==="memory"?e.persistence_backend:void 0,recoverable:typeof e.recoverable=="boolean"?e.recoverable:void 0,history:s}}async function rs(){Bi.value=!0;try{await Promise.all([Ul(),At()]),Dl.value=new Date().toISOString()}catch(e){console.error("Dashboard refresh error:",e)}finally{Bi.value=!1}}async function Bl(){ia.value=!0,oa.value=null;try{const e=await iu();So.value=e,Lp.value=new Date().toISOString()}catch(e){oa.value=e instanceof Error?e.message:"Failed to load dashboard semantics"}finally{ia.value=!1}}function nm(e){var t;return((t=So.value)==null?void 0:t.surfaces.find(n=>n.id===e))??null}function sm(e){var n;const t=((n=So.value)==null?void 0:n.surfaces)??[];for(const s of t){const a=s.panels.find(o=>o.id===e);if(a)return a}return null}function am(e){var s,a;Yt.value=(Array.isArray(e.goals)?e.goals:[]).map(o=>{if(!m(o))return null;const l=r(o.id),c=r(o.title),p=r(o.horizon),_=r(o.status),u=r(o.created_at),v=r(o.updated_at);return!l||!c||!p||!_||!u||!v?null:{id:l,horizon:p,title:c,metric:r(o.metric)??null,target_value:r(o.target_value)??null,due_date:r(o.due_date)??null,priority:d(o.priority)??3,status:_,parent_goal_id:r(o.parent_goal_id)??null,last_review_note:r(o.last_review_note)??null,last_review_at:r(o.last_review_at)??null,created_at:u,updated_at:v}}).filter(o=>o!==null);const t=new Map,n=Array.isArray((s=e.mdal)==null?void 0:s.loops)?e.mdal.loops:[];for(const o of n){const l=tm(o);l&&t.set(l.loop_id,l)}Nl.value=t,Vt.value=typeof((a=e.mdal)==null?void 0:a.error)=="string"?e.mdal.error:null,xo.value=Vt.value?"error":t.size===0?"idle":"ready"}async function Ul(){try{const e=await eu(),t=wl(e.status,e.generated_at);t&&(ge.value=Kl(ge.value,t))}catch(e){console.error("Dashboard shell fetch error:",e)}}async function At(){var e;try{const t=await nu(),n=wl(t.status,t.generated_at),s=(e=ge.value)==null?void 0:e.room;n&&(ge.value=Kl(ge.value,n));const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Ve.value=(Array.isArray(t.agents)?t.agents:[]).map(Dp).filter(l=>l!==null),st.value=(Array.isArray(t.tasks)?t.tasks:[]).map(Op).filter(l=>l!==null);const o=(Array.isArray(t.messages)?t.messages:[]).map(qp).filter(l=>l!==null);wi.value=a?o:Wp(wi.value,o),_t.value=Jp(t.keepers,n??ge.value),zl.value=Bp(t.lodge_tick),Pl.value=(Array.isArray(t.lodge_checkins)?t.lodge_checkins:[]).map(Up).filter(l=>l!==null),Tl.value=(Array.isArray(t.execution_queue)?t.execution_queue:Array.isArray(t.priority_queue)?t.priority_queue:[]).map(Fp).filter(l=>l!==null),Rl.value=(Array.isArray(t.session_briefs)?t.session_briefs:[]).map(wp).filter(l=>l!==null),Ml.value=(Array.isArray(t.operation_briefs)?t.operation_briefs:[]).map(Kp).filter(l=>l!==null),Ll.value=(Array.isArray(t.worker_support_briefs)?t.worker_support_briefs:Array.isArray(t.worker_briefs)?t.worker_briefs:[]).map(pr).filter(l=>l!==null),ko.value=(Array.isArray(t.continuity_briefs)?t.continuity_briefs:[]).map(Hp).filter(l=>l!==null),El.value=(Array.isArray(t.offline_worker_briefs)?t.offline_worker_briefs:[]).map(pr).filter(l=>l!==null),Tp.value=null,Dl.value=new Date().toISOString()}catch(t){console.error("Dashboard execution fetch error:",t)}}async function it(){qn.value=!0;try{const e=await su(On.value,{excludeSystem:Ct.value});Ua.value=e.posts??[],Hi.value=new Date().toISOString()}catch(e){console.error("Board fetch error:",e)}finally{qn.value=!1}}async function ot(){var e;Ui.value=!0;try{const t=We.value||((e=ge.value)==null?void 0:e.room)||"default";We.value||(We.value=t);const n=await Hu(t);jl.value=n}catch(t){console.error("TRPG fetch error:",t)}finally{Ui.value=!1}}async function Ao(){An.value=!0,In.value=!0;try{const e=await du();am(e),Rp.value=new Date().toISOString(),Mp.value=new Date().toISOString()}catch(e){console.error("Planning fetch error:",e),xo.value="error",Vt.value=e instanceof Error?e.message:String(e)}finally{An.value=!1,In.value=!1}}async function Hl(){return Ao()}const Io=f(null),Wi=f(!1),ra=f(null);function im(e){return m(e)?{room:r(e.room)??r(e.current_room),room_base_path:r(e.room_base_path),cluster:r(e.cluster),project:r(e.project),paused:j(e.paused),version:r(e.version),generated_at:r(e.generated_at),tempo_interval_s:d(e.tempo_interval_s)}:null}function om(e){return m(e)?{active_sessions:d(e.active_sessions),blocked_sessions:d(e.blocked_sessions),active_operations:d(e.active_operations),blocked_operations:d(e.blocked_operations),runtime_pressure:d(e.runtime_pressure),worker_alerts:d(e.worker_alerts),continuity_alerts:d(e.continuity_alerts),priority_items:d(e.priority_items),keepers:d(e.keepers)}:null}function rm(e){if(!m(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.severity),a=r(e.summary),o=r(e.target_type),l=r(e.target_id);return!t||!n||!s||!a||!o||!l?null:{id:t,kind:n,severity:s,summary:a,target_type:o,target_id:l,status:r(e.status),linked_session_id:r(e.linked_session_id)??null,linked_operation_id:r(e.linked_operation_id)??null,last_seen_at:r(e.last_seen_at)??null,top_handoff:m(e.top_handoff)?e.top_handoff:null,intervene_handoff:m(e.intervene_handoff)?e.intervene_handoff:null,command_handoff:m(e.command_handoff)?e.command_handoff:null}}function lm(e){if(!m(e))return null;const t=r(e.kind),n=r(e.summary),s=r(e.target_type);return!t||!n||!s?null:{kind:t,severity:r(e.severity)??"warn",summary:n,target_type:s,target_id:r(e.target_id)??null,actor:r(e.actor)??null,evidence:e.evidence}}function cm(e){if(!m(e))return null;const t=r(e.action_type),n=r(e.target_type),s=r(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:r(e.target_id)??null,severity:r(e.severity)??"warn",reason:s,confirm_required:j(e.confirm_required),suggested_payload:m(e.suggested_payload)?e.suggested_payload:void 0,preview:e.preview}}function dm(e){return m(e)?{actor_filter:r(e.actor_filter)??null,filter_active:j(e.filter_active)??!1,visible_count:d(e.visible_count)??0,total_count:d(e.total_count)??0,hidden_count:d(e.hidden_count)??0,hidden_actors:w(e.hidden_actors),confirm_required_actions:pe(e.confirm_required_actions).flatMap(t=>{if(!m(t))return[];const n=r(t.action_type),s=r(t.target_type);return!n||!s?[]:[{action_type:n,target_type:s,description:r(t.description),confirm_required:j(t.confirm_required)}]})}:null}function um(e){return m(e)?{count:d(e.count)??0,bad_count:d(e.bad_count)??0,warn_count:d(e.warn_count)??0,provenance:r(e.provenance)??null,top_item:lm(e.top_item)}:null}function pm(e){return m(e)?{count:d(e.count)??0,provenance:r(e.provenance)??null,top_action:cm(e.top_action)}:null}function mm(e){if(!m(e))return null;const t=r(e.label),n=r(e.reason),s=r(e.source),a=r(e.provenance);return!t||!n||!s||!a?null:{label:t,reason:n,source:s,provenance:a,target_kind:r(e.target_kind)??null,target_id:r(e.target_id)??null,suggested_tab:r(e.suggested_tab)??null,suggested_surface:r(e.suggested_surface)??null,suggested_params:m(e.suggested_params)?Object.fromEntries(Object.entries(e.suggested_params).map(([o,l])=>{const c=r(l);return c?[o,c]:null}).filter(o=>o!==null)):{}}}function _m(e){const t=m(e)?e:{},n=m(t.room)?t.room:{},s=m(t.execution)?t.execution:{},a=m(t.command)?t.command:{},o=m(t.operator)?t.operator:{};return{generated_at:r(t.generated_at),room:{status:im(n.status),counts:m(n.counts)?{agents:d(n.counts.agents),tasks:d(n.counts.tasks),keepers:d(n.counts.keepers)}:void 0,provenance:r(n.provenance)??null},execution:{summary:om(s.summary),top_queue:rm(s.top_queue),provenance:r(s.provenance)??null},command:{active_operations:d(a.active_operations),active_detachments:d(a.active_detachments),pending_approvals:d(a.pending_approvals),bad_alerts:d(a.bad_alerts),warn_alerts:d(a.warn_alerts),moving_lanes:d(a.moving_lanes),active_lanes:d(a.active_lanes),provenance:r(a.provenance)??null},operator:{health:r(o.health)??null,attention_summary:um(o.attention_summary),recommendation_summary:pm(o.recommendation_summary),pending_confirm_summary:dm(o.pending_confirm_summary),provenance:r(o.provenance)??null},focus:mm(t.focus)}}async function It(){Wi.value=!0,ra.value=null;try{const e=await tu();Io.value=_m(e)}catch(e){ra.value=e instanceof Error?e.message:"Failed to load room truth"}finally{Wi.value=!1}}let Hs=null;function vm(e){Hs=e}let Ws=null;function gm(e){Ws=e}let Gs=null;function fm(e){Gs=e}const Tt={};let ei=null;function ht(e,t,n=500){Tt[e]&&clearTimeout(Tt[e]),Tt[e]=setTimeout(()=>{t(),delete Tt[e]},n)}function $m(){const e=dl.subscribe(t=>{if(t){if(t.type==="keeper_heartbeat"&&t.name){const n=new Map(Ki.value);n.set(t.name,t.ts_unix?t.ts_unix*1e3:Date.now()),Ki.value=n;return}(t.type==="agent_joined"||t.type==="agent_left")&&ht("execution",At),jp(t.type)&&(ei||(ei=setTimeout(()=>{rs(),Ws==null||Ws(),Gs==null||Gs(),ei=null},500))),(t.type.startsWith("task_")||t.type.startsWith("masc/task_"))&&ht("execution",At),t.type==="broadcast"&&ht("execution",At),(t.type==="keeper_handoff"||t.type==="keeper_compaction"||t.type==="keeper_guardrail")&&ht("execution",At),(t.type==="board_post"||t.type==="masc/board_post"||t.type==="board_comment"||t.type==="masc/board_comment")&&ht("board",it),t.type.startsWith("decision_")&&ht("council",()=>Hs==null?void 0:Hs()),(t.type==="mdal_started"||t.type==="mdal_iteration"||t.type==="mdal_completed"||t.type==="mdal_stopped")&&ht("mdal",Hl,350)}});return()=>{e();for(const t of Object.keys(Tt))clearTimeout(Tt[t]),delete Tt[t]}}let Tn=null;function hm(){Tn||(Tn=setInterval(()=>{dt.value,rs()},1e4))}function ym(){Tn&&(clearInterval(Tn),Tn=null)}const Ae=f(null),To=f(null),qe=f(null),Fn=f(!1),ut=f(null),wn=f(!1),rn=f(null),J=f(!1),la=f([]);let bm=1;function km(e){return m(e)?{id:r(e.id),seq:d(e.seq),from:r(e.from)??r(e.from_agent)??"system",content:r(e.content)??"",timestamp:r(e.timestamp)??new Date().toISOString(),type:r(e.type)}:null}function xm(e){if(!m(e))return{};const t=r(e.current_room)??r(e.room);return{room_id:r(e.room_id)??t,current_room:t,project:r(e.project),cluster:r(e.cluster),paused:j(e.paused),pause_reason:r(e.pause_reason)??null,paused_by:r(e.paused_by)??null,paused_at:r(e.paused_at)??null}}function vr(e){if(!m(e))return;const t=Object.entries(e).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return t.length>0?Object.fromEntries(t):void 0}function Wl(e){if(!m(e))return null;const t=r(e.kind),n=r(e.summary),s=r(e.target_type);return!t||!n||!s?null:{kind:t,severity:r(e.severity)??"warn",summary:n,target_type:s,target_id:r(e.target_id)??null,actor:r(e.actor)??null,evidence:e.evidence}}function Rn(e){if(!m(e))return null;const t=r(e.action_type),n=r(e.target_type),s=r(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:r(e.target_id)??null,severity:r(e.severity)??"warn",reason:s,confirm_required:j(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function Gl(e){return m(e)?{enabled:j(e.enabled),judge_online:j(e.judge_online),refreshing:j(e.refreshing),generated_at:r(e.generated_at)??null,expires_at:r(e.expires_at)??null,model_used:r(e.model_used)??null,keeper_name:r(e.keeper_name)??null,last_error:r(e.last_error)??null}:null}function ti(e){return m(e)?{summary:r(e.summary)??null,confidence:d(e.confidence)??null,provenance:r(e.provenance)??null,authoritative:j(e.authoritative),surface:r(e.surface)??null,fresh_until:r(e.fresh_until)??null,keeper_name:r(e.keeper_name)??null,fallback_used:j(e.fallback_used),disagreement_with_truth:j(e.disagreement_with_truth)}:null}function Sm(e){return m(e)?{judgment_id:r(e.judgment_id)??void 0,surface:r(e.surface)??null,target_type:r(e.target_type)??null,target_id:r(e.target_id)??null,status:r(e.status)??null,summary:r(e.summary)??null,confidence:d(e.confidence)??null,generated_at:r(e.generated_at)??null,fresh_until:r(e.fresh_until)??null,keeper_name:r(e.keeper_name)??null,model_name:r(e.model_name)??null,runtime_name:r(e.runtime_name)??null,evidence_refs:w(e.evidence_refs),recommended_action:Rn(e.recommended_action),supersedes:w(e.supersedes),fallback_used:j(e.fallback_used),disagreement_with_truth:j(e.disagreement_with_truth),provenance:r(e.provenance)??null}:null}function Cm(e){return m(e)?{actor:r(e.actor)??null,spawn_agent:r(e.spawn_agent)??null,spawn_role:r(e.spawn_role)??null,spawn_model:r(e.spawn_model)??null,worker_class:r(e.worker_class)??null,parent_actor:r(e.parent_actor)??null,capsule_mode:r(e.capsule_mode)??null,runtime_pool:r(e.runtime_pool)??null,lane_id:r(e.lane_id)??null,controller_level:r(e.controller_level)??null,control_domain:r(e.control_domain)??null,supervisor_actor:r(e.supervisor_actor)??null,model_tier:r(e.model_tier)??null,task_profile:r(e.task_profile)??null,risk_level:r(e.risk_level)??null,routing_confidence:d(e.routing_confidence)??null,routing_reason:r(e.routing_reason)??null,status:r(e.status)??"unknown",turn_count:d(e.turn_count)??0,empty_note_turn_count:d(e.empty_note_turn_count)??0,has_turn:j(e.has_turn)??!1,last_turn_ts_iso:r(e.last_turn_ts_iso)??null}:null}function Am(e){if(!m(e))return null;const t=r(e.session_id);return t?{session_id:t,goal:r(e.goal),status:r(e.status),health:r(e.health),scale_profile:r(e.scale_profile),control_profile:r(e.control_profile),planned_worker_count:d(e.planned_worker_count),active_agent_count:d(e.active_agent_count),last_turn_age_sec:d(e.last_turn_age_sec)??null,attention_count:d(e.attention_count),recommended_action_count:d(e.recommended_action_count),top_attention:Wl(e.top_attention),top_recommendation:Rn(e.top_recommendation)}:null}function Jl(e){const t=m(e)?e:{};return{trace_id:r(t.trace_id),target_type:r(t.target_type)??"room",target_id:r(t.target_id)??null,health:r(t.health),judgment_owner:r(t.judgment_owner)??null,authoritative_judgment_available:j(t.authoritative_judgment_available),resident_judge_runtime:Gl(t.resident_judge_runtime),judgment:Sm(t.judgment),active_guidance_layer:r(t.active_guidance_layer)??null,active_summary:ti(t.active_summary),active_recommended_actions:pe(t.active_recommended_actions).map(Rn).filter(n=>n!==null),active_recommendation_source:r(t.active_recommendation_source)??null,active_recommendation_summary:ti(t.active_recommendation_summary),fallback_recommended_actions:pe(t.fallback_recommended_actions).map(Rn).filter(n=>n!==null),recommendation_summary:ti(t.recommendation_summary),swarm_status:m(t.swarm_status)?t.swarm_status:void 0,attention_items:pe(t.attention_items).map(Wl).filter(n=>n!==null),recommended_actions:pe(t.recommended_actions).map(Rn).filter(n=>n!==null),session_cards:pe(t.session_cards).map(Am).filter(n=>n!==null),worker_cards:pe(t.worker_cards).map(Cm).filter(n=>n!==null)}}function Im(e){if(!m(e))return null;const t=m(e.status)?e.status:void 0,n=m(e.summary)?e.summary:m(t==null?void 0:t.summary)?t.summary:void 0,s=m(e.session)?e.session:m(t==null?void 0:t.session)?t.session:void 0,a=r(e.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const o=vr(e.report_paths)??vr(t==null?void 0:t.report_paths),l=pe(e.recent_events,["events"]).filter(m);return{session_id:a,status:r(e.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:d(e.progress_pct)??d(n==null?void 0:n.progress_pct),elapsed_sec:d(e.elapsed_sec)??d(n==null?void 0:n.elapsed_sec),remaining_sec:d(e.remaining_sec)??d(n==null?void 0:n.remaining_sec),done_delta_total:d(e.done_delta_total)??d(n==null?void 0:n.done_delta_total),summary:n,team_health:m(e.team_health)?e.team_health:m(t==null?void 0:t.team_health)?t.team_health:void 0,communication_metrics:m(e.communication_metrics)?e.communication_metrics:m(t==null?void 0:t.communication_metrics)?t.communication_metrics:void 0,orchestration_state:m(e.orchestration_state)?e.orchestration_state:m(t==null?void 0:t.orchestration_state)?t.orchestration_state:void 0,cascade_metrics:m(e.cascade_metrics)?e.cascade_metrics:m(t==null?void 0:t.cascade_metrics)?t.cascade_metrics:void 0,report_paths:o,linked_autoresearch:m(e.linked_autoresearch)?e.linked_autoresearch:m(t==null?void 0:t.linked_autoresearch)?t.linked_autoresearch:void 0,session:s,recent_events:l}}function gr(e){if(!m(e))return null;const t=r(e.name);if(!t)return null;const n=m(e.context)?e.context:void 0;return{name:t,runtime_class:e.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:j(e.desired),resident_registered:j(e.resident_registered),agent_name:r(e.agent_name),status:r(e.status),autonomy_level:r(e.autonomy_level),context_ratio:d(e.context_ratio)??d(n==null?void 0:n.context_ratio),generation:d(e.generation),active_goal_ids:w(e.active_goal_ids),last_autonomous_action_at:r(e.last_autonomous_action_at)??null,last_turn_ago_s:d(e.last_turn_ago_s),model:r(e.model)??r(e.active_model)??r(e.primary_model)}}function Tm(e){if(!m(e))return null;const t=r(e.confirm_token)??r(e.token);return t?{confirm_token:t,actor:r(e.actor),action_type:r(e.action_type),target_type:r(e.target_type),target_id:r(e.target_id)??null,delegated_tool:r(e.delegated_tool),created_at:r(e.created_at),preview:e.preview}:null}function Yl(e){if(!m(e))return null;const t=r(e.action_type),n=r(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:r(e.description),confirm_required:j(e.confirm_required)}}function Rm(e){return m(e)?{actor_filter:r(e.actor_filter)??null,filter_active:j(e.filter_active)??!1,visible_count:d(e.visible_count)??0,total_count:d(e.total_count)??0,hidden_count:d(e.hidden_count)??0,hidden_actors:w(e.hidden_actors),confirm_required_actions:pe(e.confirm_required_actions).map(Yl).filter(t=>t!==null)}:null}function Mm(e){const t=m(e)?e:{};return{room:xm(t.room),sessions:pe(t.sessions,["items","sessions"]).map(Im).filter(n=>n!==null),keepers:pe(t.keepers,["items","keepers"]).map(gr).filter(n=>n!==null),resident_judge_runtime:Gl(t.resident_judge_runtime),persistent_agents:pe(t.persistent_agents,["items","persistent_agents"]).map(gr).filter(n=>n!==null),recent_messages:pe(t.recent_messages,["messages"]).map(km).filter(n=>n!==null),pending_confirms:pe(t.pending_confirms,["items","confirms"]).map(Tm).filter(n=>n!==null),pending_confirm_summary:Rm(t.pending_confirm_summary)??void 0,available_actions:pe(t.available_actions,["actions"]).map(Yl).filter(n=>n!==null)}}function Ss(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e)}catch{return String(e)}}function fr(e){return e.target_id?`${e.target_type}:${e.target_id}`:e.target_type}function ca(e){la.value=[{...e,id:bm++,at:new Date().toISOString()},...la.value].slice(0,20)}function Vl(e){return e.confirm_required?Ss(e.preview)||"Confirmation required":Ss(e.result)||Ss(e.executed_action)||Ss(e.delegated_tool_result)||e.status}async function be(){Fn.value=!0,ut.value=null;try{const e=await mu();Ae.value=Mm(e)}catch(e){ut.value=e instanceof Error?e.message:"Failed to load operator snapshot"}finally{Fn.value=!1}}async function Pt(){wn.value=!0,rn.value=null;try{const e=await gl({targetType:"room"});To.value=Jl(e)}catch(e){rn.value=e instanceof Error?e.message:"Failed to load operator digest"}finally{wn.value=!1}}async function ln(e){if(!e){qe.value=null;return}wn.value=!0,rn.value=null;try{const t=await gl({targetType:"team_session",targetId:e,includeWorkers:!0});qe.value=Jl(t)}catch(t){rn.value=t instanceof Error?t.message:"Failed to load session digest"}finally{wn.value=!1}}async function Xl(e){var t;J.value=!0,ut.value=null;try{const n=await os(e);return ca({actor:e.actor,action_type:e.action_type,target_label:fr(e),outcome:n.confirm_required?"preview":"executed",message:Vl(n),delegated_tool:n.delegated_tool}),await be(),await Pt(),(t=qe.value)!=null&&t.target_id&&await ln(qe.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw ut.value=s,ca({actor:e.actor,action_type:e.action_type,target_label:fr(e),outcome:"error",message:s}),n}finally{J.value=!1}}async function Ql(e,t,n="confirm"){var s;J.value=!0,ut.value=null;try{const a=await fl(e,t,n);return ca({actor:e,action_type:n,target_label:t,outcome:"confirmed",message:Vl(a),delegated_tool:a.delegated_tool}),await be(),await Pt(),(s=qe.value)!=null&&s.target_id&&await ln(qe.value.target_id),a}catch(a){const o=a instanceof Error?a.message:"Operator confirmation failed";throw ut.value=o,ca({actor:e,action_type:"confirm",target_label:t,outcome:"error",message:o}),a}finally{J.value=!1}}fm(()=>{var e;be(),Pt(),(e=qe.value)!=null&&e.target_id&&ln(qe.value.target_id)});const Ha=f(null),Gi=f(!1),da=f(null),Zl=f(null),Ft=f(!1),St=f(null),Ji=f(null),Js=f(!1),Ys=f(null);let Xt=null;function $r(){Xt!==null&&(window.clearTimeout(Xt),Xt=null)}function Lm(e=1500){Xt===null&&(Xt=window.setTimeout(()=>{Xt=null,ua(!1)},e))}function D(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function y(e){return typeof e=="string"&&e.trim()!==""?e:void 0}function q(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function Qt(e){return typeof e=="boolean"?e:void 0}function V(e,t=[]){if(Array.isArray(e))return e;if(!D(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function mn(e){if(!D(e))return null;const t=y(e.kind),n=y(e.summary),s=y(e.target_type);return!t||!n||!s?null:{kind:t,severity:y(e.severity)??"warn",summary:n,target_type:s,target_id:y(e.target_id)??null,actor:y(e.actor)??null,evidence:e.evidence}}function jt(e){if(!D(e))return null;const t=y(e.action_type),n=y(e.target_type),s=y(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:y(e.target_id)??null,severity:y(e.severity)??"warn",reason:s,confirm_required:Qt(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function zm(e){if(!D(e))return null;const t=y(e.session_id);return t?{session_id:t,goal:y(e.goal),status:y(e.status),health:y(e.health),scale_profile:y(e.scale_profile),control_profile:y(e.control_profile),planned_worker_count:q(e.planned_worker_count),active_agent_count:q(e.active_agent_count),last_turn_age_sec:q(e.last_turn_age_sec)??null,attention_count:q(e.attention_count),recommended_action_count:q(e.recommended_action_count),top_attention:mn(e.top_attention),top_recommendation:jt(e.top_recommendation)}:null}function Pm(e){if(!D(e))return null;const t=y(e.session_id);if(!t)return null;const n=D(e.status)?e.status:e,s=D(n.summary)?n.summary:void 0;return{session_id:t,status:y(e.status)??y(s==null?void 0:s.status)??(D(n.session)?y(n.session.status):void 0),progress_pct:q(e.progress_pct)??q(s==null?void 0:s.progress_pct),elapsed_sec:q(e.elapsed_sec)??q(s==null?void 0:s.elapsed_sec),remaining_sec:q(e.remaining_sec)??q(s==null?void 0:s.remaining_sec),done_delta_total:q(e.done_delta_total)??q(s==null?void 0:s.done_delta_total),summary:D(e.summary)?e.summary:s,team_health:D(e.team_health)?e.team_health:D(n.team_health)?n.team_health:void 0,communication_metrics:D(e.communication_metrics)?e.communication_metrics:D(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:D(e.orchestration_state)?e.orchestration_state:D(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:D(e.cascade_metrics)?e.cascade_metrics:D(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:D(e.report_paths)?Object.fromEntries(Object.entries(e.report_paths).map(([a,o])=>{const l=y(o);return l?[a,l]:null}).filter(a=>a!==null)):D(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const l=y(o);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:D(e.session)?e.session:D(n.session)?n.session:void 0,recent_events:V(e.recent_events,["events"]).filter(D)}}function Em(e){if(!D(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name),status:y(e.status),autonomy_level:y(e.autonomy_level),context_ratio:q(e.context_ratio),generation:q(e.generation),active_goal_ids:V(e.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:y(e.last_autonomous_action_at)??null,last_turn_ago_s:q(e.last_turn_ago_s),model:y(e.model)}:null}function jm(e){if(!D(e))return null;const t=y(e.confirm_token)??y(e.token);return t?{confirm_token:t,actor:y(e.actor),action_type:y(e.action_type),target_type:y(e.target_type),target_id:y(e.target_id)??null,delegated_tool:y(e.delegated_tool),created_at:y(e.created_at),preview:e.preview}:null}function Nm(e){if(!D(e))return null;const t=y(e.action_type),n=y(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:y(e.description),confirm_required:Qt(e.confirm_required)}}function Dm(e){const t=D(e)?e:{};return{room_health:y(t.room_health),cluster:y(t.cluster),project:y(t.project),current_room:y(t.current_room)??y(t.room)??null,paused:Qt(t.paused),tempo_interval_s:q(t.tempo_interval_s),active_agents:q(t.active_agents),keeper_pressure:q(t.keeper_pressure),active_operations:q(t.active_operations),pending_approvals:q(t.pending_approvals),incident_count:q(t.incident_count),recommended_action_count:q(t.recommended_action_count),top_attention:mn(t.top_attention),top_action:jt(t.top_action)}}function Om(e){const t=D(e)?e:{},n=D(t.swarm_overview)?t.swarm_overview:{};return{health:y(t.health),active_operations:q(t.active_operations),pending_approvals:q(t.pending_approvals),swarm_overview:{active_lanes:q(n.active_lanes),moving_lanes:q(n.moving_lanes),stalled_lanes:q(n.stalled_lanes),projected_lanes:q(n.projected_lanes),last_movement_at:y(n.last_movement_at)??null},top_attention:mn(t.top_attention),top_action:jt(t.top_action),session_cards:V(t.session_cards).map(zm).filter(s=>s!==null)}}function qm(e){const t=D(e)?e:{};return{sessions:V(t.sessions,["items"]).map(Pm).filter(n=>n!==null),keepers:V(t.keepers,["items"]).map(Em).filter(n=>n!==null),pending_confirms:V(t.pending_confirms).map(jm).filter(n=>n!==null),available_actions:V(t.available_actions).map(Nm).filter(n=>n!==null)}}function Fm(e){if(!D(e))return null;const t=y(e.id),n=y(e.kind),s=y(e.summary),a=y(e.target_type);return!t||!n||!s||!a?null:{id:t,kind:n,severity:y(e.severity)??"warn",summary:s,target_type:a,target_id:y(e.target_id)??null,top_action:jt(e.top_action),related_session_ids:V(e.related_session_ids).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),related_agent_names:V(e.related_agent_names).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),evidence_preview:V(e.evidence_preview).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),last_seen_at:y(e.last_seen_at)??null}}function ec(e){if(!D(e))return null;const t=y(e.session_id),n=y(e.goal);return!t||!n?null:{session_id:t,goal:n,room:y(e.room)??null,status:y(e.status),health:y(e.health),member_names:V(e.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:y(e.started_at)??null,elapsed_sec:q(e.elapsed_sec)??null,operation_id:y(e.operation_id)??null,blocker_summary:y(e.blocker_summary)??null,last_event_at:y(e.last_event_at)??null,last_event_summary:y(e.last_event_summary)??null,communication_summary:y(e.communication_summary)??null,active_count:q(e.active_count),required_count:q(e.required_count),related_attention_count:q(e.related_attention_count)??0,top_attention:mn(e.top_attention),top_recommendation:jt(e.top_recommendation)}}function tc(e){if(!D(e))return null;const t=y(e.agent_name);return t?{agent_name:t,display_name:y(e.display_name)??null,is_live:typeof e.is_live=="boolean"?e.is_live:void 0,current_work:y(e.current_work)??null,recent_input_preview:y(e.recent_input_preview)??null,recent_output_preview:y(e.recent_output_preview)??null,last_activity_at:y(e.last_activity_at)??null}:null}function nc(e){if(!D(e))return null;const t=y(e.operation_id);return t?{operation_id:t,status:y(e.status),stage:y(e.stage)??null,detachment_status:y(e.detachment_status)??null,objective:y(e.objective)??null,updated_at:y(e.updated_at)??null}:null}function sc(e){if(!D(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name)??null,status:y(e.status),generation:q(e.generation),context_ratio:q(e.context_ratio)??null,last_turn_ago_s:q(e.last_turn_ago_s)??null,current_work:y(e.current_work)??null}:null}function ac(e){const t=ec(e);return t?{...t,member_previews:V(D(e)?e.member_previews:void 0).map(tc).filter(n=>n!==null),operation_badges:V(D(e)?e.operation_badges:void 0).map(nc).filter(n=>n!==null),keeper_refs:V(D(e)?e.keeper_refs:void 0).map(sc).filter(n=>n!==null)}:null}function wm(e){if(!D(e))return null;const t=y(e.agent_name);return t?{agent_name:t,display_name:y(e.display_name)??null,is_live:typeof e.is_live=="boolean"?e.is_live:void 0,archived_reason:y(e.archived_reason)??null,status:y(e.status),current_work:y(e.current_work)??null,related_session_id:y(e.related_session_id)??null,last_activity_at:y(e.last_activity_at)??null,recent_output_preview:y(e.recent_output_preview)??null,recent_input_preview:y(e.recent_input_preview)??null}:null}function Km(e){if(!D(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name)??null,status:y(e.status),generation:q(e.generation),context_ratio:q(e.context_ratio)??null,last_turn_ago_s:q(e.last_turn_ago_s)??null,current_work:y(e.current_work)??null,last_autonomous_action_at:y(e.last_autonomous_action_at)??null,allowed_tool_names:V(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:V(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:q(e.latest_tool_call_count)??null,tool_audit_source:y(e.tool_audit_source)??null,tool_audit_at:y(e.tool_audit_at)??null}:null}function Bm(e){if(!D(e))return null;const t=y(e.id),n=y(e.signal_type),s=y(e.summary),a=y(e.target_type);return!t||!n||!s||!a?null:{id:t,signal_type:n==="action"?"action":"attention",severity:y(e.severity)??"warn",summary:s,target_type:a,target_id:y(e.target_id)??null,attention:mn(e.attention),action:jt(e.action)}}function Um(e){const t=D(e)?e:{},n=V(t.session_briefs).map(ec).filter(a=>a!==null),s=V(t.sessions).map(ac).filter(a=>a!==null);return{generated_at:y(t.generated_at),summary:Dm(t.summary),incidents:V(t.incidents).map(mn).filter(a=>a!==null),recommended_actions:V(t.recommended_actions).map(jt).filter(a=>a!==null),command_focus:Om(t.command_focus),operator_targets:qm(t.operator_targets),attention_queue:V(t.attention_queue).map(Fm).filter(a=>a!==null),sessions:s.length>0?s:n.map(a=>({...a,member_previews:[],operation_badges:[],keeper_refs:[]})),session_briefs:n,agent_briefs:V(t.agent_briefs).map(wm).filter(a=>a!==null),keeper_briefs:V(t.keeper_briefs).map(Km).filter(a=>a!==null),internal_signals:V(t.internal_signals).map(Bm).filter(a=>a!==null)}}function Hm(e){if(!D(e))return null;const t=y(e.id),n=y(e.summary);return!t||!n?null:{id:t,timestamp:y(e.timestamp)??null,event_type:y(e.event_type),actor:y(e.actor)??null,summary:n}}function Wm(e){const t=D(e)?e:{};return{generated_at:y(t.generated_at),session_id:y(t.session_id)??"",session:ac(t.session),timeline:V(t.timeline).map(Hm).filter(n=>n!==null),participants:V(t.participants).map(tc).filter(n=>n!==null),operations:V(t.operations).map(nc).filter(n=>n!==null),keepers:V(t.keepers).map(sc).filter(n=>n!==null),error:y(t.error)??null}}function Gm(e){if(!D(e))return null;const t=y(e.id),n=y(e.label),s=y(e.summary);if(!t||!n||!s)return null;const a=y(e.status)??"unclear";return{id:t,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:y(e.signal_class)==="metadata_gap"||y(e.signal_class)==="mixed"||y(e.signal_class)==="operational_risk"?y(e.signal_class):void 0,evidence_quality:y(e.evidence_quality)==="strong"||y(e.evidence_quality)==="partial"||y(e.evidence_quality)==="missing"?y(e.evidence_quality):void 0,evidence:V(e.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function Jm(e){if(!D(e))return null;const t=y(e.kind),n=y(e.summary),s=y(e.scope_type),a=y(e.severity);return!t||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:t,summary:n,scope_type:s,scope_id:y(e.scope_id)??null,severity:a}}function Ym(e){const t=D(e)?e:{},n=D(t.basis)?t.basis:{},s=y(t.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:y(t.generated_at),cached:Qt(t.cached),stale:Qt(t.stale),refreshing:Qt(t.refreshing),status:a,summary:y(t.summary)??null,model:y(t.model)??null,ttl_sec:q(t.ttl_sec),criteria:V(t.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:y(n.current_room)??null,crew_count:q(n.crew_count),agent_count:q(n.agent_count),keeper_count:q(n.keeper_count)},metadata_gap_count:q(t.metadata_gap_count),metadata_gaps:V(t.metadata_gaps).map(Jm).filter(o=>o!==null),sections:V(t.sections).map(Gm).filter(o=>o!==null),error:y(t.error)??null,last_error:y(t.last_error)??null}}async function ic(){Gi.value=!0,da.value=null;try{const e=await ou();Ha.value=Um(e)}catch(e){da.value=e instanceof Error?e.message:"Failed to load mission snapshot"}finally{Gi.value=!1}}async function Vm(e){if(!e){Ji.value=null,Ys.value=null,Js.value=!1;return}Js.value=!0,Ys.value=null;try{const t=await ru(e);Ji.value=Wm(t)}catch(t){Ys.value=t instanceof Error?t.message:"Failed to load session detail"}finally{Js.value=!1}}async function ua(e=!1){Ft.value=!0,St.value=null;try{const t=await lu(e),n=Ym(t);Zl.value=n,n.refreshing||n.status==="pending"?Lm():$r()}catch(t){St.value=t instanceof Error?t.message:"Failed to load mission briefing",$r()}finally{Ft.value=!1}}const oc=f(null),Yi=f(!1),wt=f(null);async function rc(e,t){Yi.value=!0,wt.value=null;try{oc.value=await cu(e,t)}catch(n){wt.value=n instanceof Error?n.message:String(n)}finally{Yi.value=!1}}const Ro=f(null),we=f(null),pa=f(!1),ma=f(!1),_a=f(null),va=f(null),Vi=f(null),ga=f(null),Y=f("warroom"),ls=f(null),Xi=f(!1),fa=f(null),Nt=f(null),$a=f(!1),ha=f(null),Mo=f(null),Qi=f(!1),ya=f(null),cs=f(null),Zi=f(!1),ba=f(null),Kn=f(null),ka=f(!1),Bn=f(null),Zt=f(null);let xn=null;function Lo(e){return e!=="summary"&&e!=="swarm"&&e!=="warroom"&&e!=="orchestra"}function lc(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,o)=>{e.has(o)||e.set(o,a)}),e}function cc(){const t=lc().get("run_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function dc(){const t=lc().get("operation_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function Xm(e){if(m(e))return{policy_class:r(e.policy_class),approval_class:r(e.approval_class),tool_allowlist:w(e.tool_allowlist),model_allowlist:w(e.model_allowlist),requires_human_for:w(e.requires_human_for),autonomy_level:r(e.autonomy_level),escalation_timeout_sec:d(e.escalation_timeout_sec),kill_switch:j(e.kill_switch),frozen:j(e.frozen)}}function Qm(e){if(m(e))return{headcount_cap:d(e.headcount_cap),active_operation_cap:d(e.active_operation_cap),max_cost_usd:d(e.max_cost_usd),max_tokens:d(e.max_tokens)}}function zo(e){if(!m(e))return null;const t=r(e.unit_id),n=r(e.label),s=r(e.kind);return!t||!n||!s?null:{unit_id:t,label:n,kind:s,parent_unit_id:r(e.parent_unit_id)??null,leader_id:r(e.leader_id)??null,roster:w(e.roster),capability_profile:w(e.capability_profile),source:r(e.source),created_at:r(e.created_at),updated_at:r(e.updated_at),policy:Xm(e.policy),budget:Qm(e.budget)}}function uc(e){if(!m(e))return null;const t=zo(e.unit);return t?{unit:t,leader_status:r(e.leader_status),roster_total:d(e.roster_total),roster_live:d(e.roster_live),active_operation_count:d(e.active_operation_count),health:r(e.health),reasons:w(e.reasons),children:Array.isArray(e.children)?e.children.map(uc).filter(n=>n!==null):[]}:null}function Zm(e){if(m(e))return{total_units:d(e.total_units),company_count:d(e.company_count),platoon_count:d(e.platoon_count),squad_count:d(e.squad_count),leaf_agent_unit_count:d(e.leaf_agent_unit_count),live_agent_count:d(e.live_agent_count),managed_unit_count:d(e.managed_unit_count),active_operation_count:d(e.active_operation_count)}}function pc(e){const t=m(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),source:r(t.source),summary:Zm(t.summary),units:Array.isArray(t.units)?t.units.map(uc).filter(n=>n!==null):[]}}function e_(e){if(!m(e))return null;const t=r(e.kind),n=r(e.status);return!t||!n?null:{kind:t,chain_id:r(e.chain_id)??null,goal:r(e.goal)??null,run_id:r(e.run_id)??null,status:n,viewer_path:r(e.viewer_path)??null,last_sync_at:r(e.last_sync_at)??null}}function Wa(e){if(!m(e))return null;const t=r(e.operation_id),n=r(e.objective),s=r(e.assigned_unit_id),a=r(e.trace_id),o=r(e.status);return!t||!n||!s||!a||!o?null:{operation_id:t,objective:n,assigned_unit_id:s,autonomy_level:r(e.autonomy_level),policy_class:r(e.policy_class),budget_class:r(e.budget_class),detachment_session_id:r(e.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(e.checkpoint_ref)??null,active_goal_ids:w(e.active_goal_ids),note:r(e.note)??null,created_by:r(e.created_by),source:r(e.source),status:o,chain:e_(e.chain),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function t_(e){if(!m(e))return null;const t=Wa(e.operation);return t?{operation:t,assigned_unit_label:r(e.assigned_unit_label)}:null}function hn(e){if(m(e))return{tone:r(e.tone),pending_ops:d(e.pending_ops),blocked_ops:d(e.blocked_ops),in_flight_ops:d(e.in_flight_ops),pipeline_stalls:d(e.pipeline_stalls),bus_traffic:d(e.bus_traffic),l1_hit_rate:d(e.l1_hit_rate),invalidation_count:d(e.invalidation_count),current_pending:d(e.current_pending),current_in_flight:d(e.current_in_flight),cdb_wakeups:d(e.cdb_wakeups),total_stolen:d(e.total_stolen),avg_best_score:d(e.avg_best_score),avg_candidate_count:d(e.avg_candidate_count),best_first_operations:d(e.best_first_operations),active_sessions:d(e.active_sessions),commit_rate:d(e.commit_rate),total_speculations:d(e.total_speculations)}}function n_(e){if(!m(e))return;const t=m(e.pipeline)?e.pipeline:void 0,n=m(e.cache)?e.cache:void 0,s=m(e.ooo)?e.ooo:void 0,a=m(e.speculative)?e.speculative:void 0,o=m(e.search_fabric)?e.search_fabric:void 0,l=m(e.signals)?e.signals:void 0;return{pipeline:t?{total_ops:d(t.total_ops),completed_ops:d(t.completed_ops),stalled_cycles:d(t.stalled_cycles),hazards_detected:d(t.hazards_detected),forwarding_used:d(t.forwarding_used),pipeline_flushes:d(t.pipeline_flushes),ipc:d(t.ipc)}:void 0,cache:n?{total_reads:d(n.total_reads),total_writes:d(n.total_writes),l1_hit_rate:d(n.l1_hit_rate),invalidation_count:d(n.invalidation_count),writeback_count:d(n.writeback_count),bus_traffic:d(n.bus_traffic)}:void 0,ooo:s?{agent_count:d(s.agent_count),total_added:d(s.total_added),total_issued:d(s.total_issued),total_completed:d(s.total_completed),total_stolen:d(s.total_stolen),cdb_wakeups:d(s.cdb_wakeups),stall_cycles:d(s.stall_cycles),global_cdb_events:d(s.global_cdb_events),current_pending:d(s.current_pending),current_in_flight:d(s.current_in_flight)}:void 0,speculative:a?{total_speculations:d(a.total_speculations),total_commits:d(a.total_commits),total_aborts:d(a.total_aborts),commit_rate:d(a.commit_rate),total_fast_calls:d(a.total_fast_calls),total_cost_usd:d(a.total_cost_usd),active_sessions:d(a.active_sessions)}:void 0,search_fabric:o?{total_operations:d(o.total_operations),best_first_operations:d(o.best_first_operations),legacy_operations:d(o.legacy_operations),blocked_operations:d(o.blocked_operations),ready_operations:d(o.ready_operations),research_pipeline_operations:d(o.research_pipeline_operations),avg_candidate_count:d(o.avg_candidate_count),avg_best_score:d(o.avg_best_score),top_stage:r(o.top_stage)??null}:void 0,signals:l?{issue_pressure:hn(l.issue_pressure),cache_contention:hn(l.cache_contention),scheduler_efficiency:hn(l.scheduler_efficiency),routing_confidence:hn(l.routing_confidence),speculative_posture:hn(l.speculative_posture)}:void 0}}function mc(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),paused:d(n.paused),managed:d(n.managed),projected:d(n.projected)}:void 0,microarch:n_(t.microarch),operations:Array.isArray(t.operations)?t.operations.map(t_).filter(s=>s!==null):[]}}function _c(e){if(!m(e))return null;const t=r(e.detachment_id),n=r(e.operation_id),s=r(e.assigned_unit_id);return!t||!n||!s?null:{detachment_id:t,operation_id:n,assigned_unit_id:s,leader_id:r(e.leader_id)??null,roster:w(e.roster),session_id:r(e.session_id)??null,checkpoint_ref:r(e.checkpoint_ref)??null,runtime_kind:r(e.runtime_kind)??null,runtime_ref:r(e.runtime_ref)??null,source:r(e.source),status:r(e.status),last_event_at:r(e.last_event_at)??null,last_progress_at:r(e.last_progress_at)??null,heartbeat_deadline:r(e.heartbeat_deadline)??null,created_at:r(e.created_at),updated_at:r(e.updated_at)}}function s_(e){if(!m(e))return null;const t=_c(e.detachment);return t?{detachment:t,assigned_unit_label:r(e.assigned_unit_label),operation:Wa(e.operation)}:null}function vc(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),projected:d(n.projected)}:void 0,detachments:Array.isArray(t.detachments)?t.detachments.map(s_).filter(s=>s!==null):[]}}function a_(e){if(!m(e))return null;const t=r(e.decision_id),n=r(e.trace_id),s=r(e.requested_action),a=r(e.scope_type),o=r(e.scope_id);return!t||!n||!s||!a||!o?null:{decision_id:t,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:r(e.operation_id)??null,target_unit_id:r(e.target_unit_id)??null,requested_by:r(e.requested_by),status:r(e.status),reason:r(e.reason)??null,source:r(e.source),detail:e.detail,created_at:r(e.created_at),decided_at:r(e.decided_at)??null,expires_at:r(e.expires_at)??null}}function gc(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),pending:d(n.pending),approved:d(n.approved),denied:d(n.denied)}:void 0,decisions:Array.isArray(t.decisions)?t.decisions.map(a_).filter(s=>s!==null):[]}}function i_(e){if(!m(e))return null;const t=zo(e.unit);return t?{unit:t,roster_total:d(e.roster_total),roster_live:d(e.roster_live),headcount_cap:d(e.headcount_cap),active_operations:d(e.active_operations),active_operation_cap:d(e.active_operation_cap),utilization:d(e.utilization)}:null}function o_(e){const t=m(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),capacity:Array.isArray(t.capacity)?t.capacity.map(i_).filter(n=>n!==null):[]}}function r_(e){if(!m(e))return null;const t=r(e.alert_id);return t?{alert_id:t,severity:r(e.severity),kind:r(e.kind),scope_type:r(e.scope_type),scope_id:r(e.scope_id),title:r(e.title),detail:r(e.detail),timestamp:r(e.timestamp)}:null}function fc(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),bad:d(n.bad),warn:d(n.warn)}:void 0,alerts:Array.isArray(t.alerts)?t.alerts.map(r_).filter(s=>s!==null):[]}}function $c(e){if(!m(e))return null;const t=r(e.event_id),n=r(e.trace_id),s=r(e.event_type);return!t||!n||!s?null:{event_id:t,trace_id:n,event_type:s,operation_id:r(e.operation_id)??null,unit_id:r(e.unit_id)??null,actor:r(e.actor)??null,source:r(e.source),timestamp:r(e.timestamp),detail:e.detail}}function l_(e){const t=m(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),events:Array.isArray(t.events)?t.events.map($c).filter(n=>n!==null):[]}}function c_(e){if(!m(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s}}function d_(e){if(!m(e))return null;const t=r(e.lane_id),n=r(e.label),s=r(e.kind),a=r(e.phase),o=r(e.motion_state),l=r(e.source_of_truth),c=r(e.movement_reason),p=r(e.current_step);if(!t||!n||!s||!a||!o||!l||!c||!p)return null;const _=m(e.counts)?e.counts:{};return{lane_id:t,label:n,kind:s,present:j(e.present)??!1,phase:a,motion_state:o,source_of_truth:l,last_movement_at:r(e.last_movement_at)??null,movement_reason:c,current_step:p,blockers:w(e.blockers),counts:{operations:d(_.operations),detachments:d(_.detachments),workers:d(_.workers),approvals:d(_.approvals),alerts:d(_.alerts)},hard_flags:Array.isArray(e.hard_flags)?e.hard_flags.map(c_).filter(u=>u!==null):[]}}function u_(e){if(!m(e))return null;const t=r(e.event_id),n=r(e.lane_id),s=r(e.kind),a=r(e.timestamp),o=r(e.title),l=r(e.detail),c=r(e.tone),p=r(e.source);return!t||!n||!s||!a||!o||!l||!c||!p?null:{event_id:t,lane_id:n,kind:s,timestamp:a,title:o,detail:l,tone:c,source:p}}function p_(e){if(!m(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s,why_it_matters:r(e.why_it_matters)??void 0,next_tool:r(e.next_tool)??void 0,next_step:r(e.next_step)??void 0,lane_ids:w(e.lane_ids),count:d(e.count)??0}}function Po(e){if(!m(e))return;const t=m(e.overview)?e.overview:{},n=m(e.gaps)?e.gaps:{},s=m(e.narrative)?e.narrative:{},a=m(e.recommended_next_action)?e.recommended_next_action:void 0;return{generated_at:r(e.generated_at),narrative:{state:r(s.state)??void 0,started:r(s.started)??void 0,active_work:r(s.active_work)??void 0,completion:r(s.completion)??void 0,lane_id:r(s.lane_id)??null},overview:{active_lanes:d(t.active_lanes),moving_lanes:d(t.moving_lanes),stalled_lanes:d(t.stalled_lanes),projected_lanes:d(t.projected_lanes),last_movement_at:r(t.last_movement_at)??null},lanes:Array.isArray(e.lanes)?e.lanes.map(d_).filter(o=>o!==null):[],timeline:Array.isArray(e.timeline)?e.timeline.map(u_).filter(o=>o!==null):[],gaps:{count:d(n.count),items:Array.isArray(n.items)?n.items.map(p_).filter(o=>o!==null):[]},recommended_next_action:a?{tool:r(a.tool)??"masc_operator_snapshot",label:r(a.label)??"Observe operator state",reason:r(a.reason)??"",lane_id:r(a.lane_id)??null}:void 0}}function hc(e){if(!m(e))return;const t=m(e.workers)?e.workers:{},n=j(e.pass);return{status:r(e.status)??"missing",source:r(e.source)??"none",reason_code:r(e.reason_code)??null,status_summary:r(e.status_summary)??null,run_id:r(e.run_id)??null,captured_at:r(e.captured_at)??null,...n!==void 0?{pass:n}:{},...d(e.peak_hot_slots)!=null?{peak_hot_slots:d(e.peak_hot_slots)}:{},...d(e.ctx_per_slot)!=null?{ctx_per_slot:d(e.ctx_per_slot)}:{},workers:{expected:d(t.expected),joined:d(t.joined),current_task_bound:d(t.current_task_bound),fresh_heartbeats:d(t.fresh_heartbeats),done:d(t.done),final:d(t.final)},expected_artifact_dir:r(e.expected_artifact_dir)??null,artifact_ref:r(e.artifact_ref)??null,missing_reason:r(e.missing_reason)??null}}function m_(e){const t=m(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),topology:pc(t.topology),operations:mc(t.operations),detachments:vc(t.detachments),alerts:fc(t.alerts),decisions:gc(t.decisions),capacity:o_(t.capacity),traces:l_(t.traces),swarm_status:Po(t.swarm_status)}}function __(e){const t=m(e)?e:{},n=pc(t.topology),s=mc(t.operations),a=vc(t.detachments),o=fc(t.alerts),l=gc(t.decisions);return{version:r(t.version),generated_at:r(t.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:Po(t.swarm_status),swarm_proof:hc(t.swarm_proof)}}function v_(e){return m(e)?{chain_id:r(e.chain_id)??null,started_at:d(e.started_at)??null,progress:d(e.progress)??null,elapsed_sec:d(e.elapsed_sec)??null}:null}function yc(e){if(!m(e))return null;const t=r(e.event);return t?{event:t,chain_id:r(e.chain_id)??null,timestamp:r(e.timestamp)??null,duration_ms:d(e.duration_ms)??null,message:r(e.message)??null,tokens:d(e.tokens)??null}:null}function g_(e){if(!m(e))return null;const t=Wa(e.operation);return t?{operation:t,runtime:v_(e.runtime),history:yc(e.history),mermaid:r(e.mermaid)??null,preview_run:bc(e.preview_run)}:null}function f_(e){const t=m(e)?e:{};return{status:r(t.status)??"disconnected",base_url:r(t.base_url)??null,message:r(t.message)??null}}function $_(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),connection:f_(t.connection),summary:n?{linked_operations:d(n.linked_operations),active_chains:d(n.active_chains),running_operations:d(n.running_operations),recent_failures:d(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(t.operations)?t.operations.map(g_).filter(s=>s!==null):[],recent_history:Array.isArray(t.recent_history)?t.recent_history.map(yc).filter(s=>s!==null):[]}}function h_(e){if(!m(e))return null;const t=r(e.id);return t?{id:t,type:r(e.type),status:r(e.status),duration_ms:d(e.duration_ms)??null,error:r(e.error)??null}:null}function bc(e){if(!m(e))return null;const t=r(e.run_id),n=r(e.chain_id);return n?{run_id:t??null,chain_id:n,duration_ms:d(e.duration_ms),success:j(e.success),mermaid:r(e.mermaid),nodes:Array.isArray(e.nodes)?e.nodes.map(h_).filter(s=>s!==null):[]}:null}function y_(e){const t=m(e)?e:{};return{run:bc(t.run)}}function b_(e){if(!m(e))return null;const t=r(e.title),n=r(e.path);return!t||!n?null:{title:t,path:n}}function k_(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary);return!t||!n||!s?null:{id:t,title:n,summary:s}}function x_(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.tool),a=r(e.summary);return!t||!n||!s||!a?null:{id:t,title:n,tool:s,summary:a,success_signals:w(e.success_signals),pitfalls:w(e.pitfalls)}}function S_(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary),a=r(e.when_to_use);return!t||!n||!s||!a?null:{id:t,title:n,summary:s,when_to_use:a,steps:Array.isArray(e.steps)?e.steps.map(x_).filter(o=>o!==null):[]}}function C_(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.description);return!t||!n||!s?null:{id:t,title:n,description:s,tools:w(e.tools)}}function A_(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.symptom),a=r(e.why),o=r(e.fix_tool),l=r(e.fix_summary);return!t||!n||!s||!a||!o||!l?null:{id:t,title:n,symptom:s,why:a,fix_tool:o,fix_summary:l}}function I_(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.path_id),a=r(e.transport);return!t||!n||!s||!a?null:{id:t,title:n,path_id:s,transport:a,request:e.request,response:e.response,notes:w(e.notes)}}function T_(e){const t=m(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),docs:Array.isArray(t.docs)?t.docs.map(b_).filter(n=>n!==null):[],concepts:Array.isArray(t.concepts)?t.concepts.map(k_).filter(n=>n!==null):[],golden_paths:Array.isArray(t.golden_paths)?t.golden_paths.map(S_).filter(n=>n!==null):[],tool_groups:Array.isArray(t.tool_groups)?t.tool_groups.map(C_).filter(n=>n!==null):[],pitfalls:Array.isArray(t.pitfalls)?t.pitfalls.map(A_).filter(n=>n!==null):[],examples:Array.isArray(t.examples)?t.examples.map(I_).filter(n=>n!==null):[]}}function R_(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.status),a=r(e.detail),o=r(e.next_tool);return!t||!n||!s||!a||!o?null:{id:t,title:n,status:s,detail:a,next_tool:o}}function M_(e){if(!m(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.title),a=r(e.detail),o=r(e.next_tool);return!t||!n||!s||!a||!o?null:{code:t,severity:n,title:s,detail:a,next_tool:o}}function L_(e){if(!m(e))return null;const t=r(e.from),n=r(e.content),s=r(e.timestamp),a=d(e.seq);return!t||!n||!s||a==null?null:{seq:a,from:t,content:n,timestamp:s}}function z_(e){if(!m(e))return null;const t=r(e.name),n=r(e.role),s=r(e.lane),a=r(e.status),o=r(e.claim_marker),l=r(e.done_marker),c=r(e.final_marker);if(!t||!n||!s||!a||!o||!l||!c)return null;const p=(()=>{if(!m(e.last_message))return null;const _=d(e.last_message.seq),u=r(e.last_message.content),v=r(e.last_message.timestamp);return _==null||!u||!v?null:{seq:_,content:u,timestamp:v}})();return{name:t,role:n,lane:s,joined:j(e.joined)??!1,live_presence:j(e.live_presence)??!1,completed:j(e.completed)??!1,status:a,current_task:r(e.current_task)??null,bound_task_id:r(e.bound_task_id)??null,bound_task_title:r(e.bound_task_title)??null,bound_task_status:r(e.bound_task_status)??null,current_task_matches_run:j(e.current_task_matches_run)??!1,squad_member:j(e.squad_member)??!1,detachment_member:j(e.detachment_member)??!1,last_seen:r(e.last_seen)??null,heartbeat_age_sec:d(e.heartbeat_age_sec)??null,heartbeat_fresh:j(e.heartbeat_fresh)??!1,claim_marker_seen:j(e.claim_marker_seen)??!1,done_marker_seen:j(e.done_marker_seen)??!1,final_marker_seen:j(e.final_marker_seen)??!1,claim_marker:o,done_marker:l,final_marker:c,last_message:p}}function P_(e){if(!m(e))return;const t=Array.isArray(e.timeline)?e.timeline.map(n=>{if(!m(n))return null;const s=r(n.timestamp),a=d(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:r(e.slot_url)??null,provider_base_url:r(e.provider_base_url)??null,provider_reachable:j(e.provider_reachable)??null,provider_status_code:d(e.provider_status_code)??null,provider_model_id:r(e.provider_model_id)??null,actual_model_id:r(e.actual_model_id)??null,expected_slots:d(e.expected_slots),actual_slots:d(e.actual_slots),expected_ctx:d(e.expected_ctx),actual_ctx:d(e.actual_ctx),configured_capacity:d(e.configured_capacity),slot_reachable:j(e.slot_reachable)??null,slot_status_code:d(e.slot_status_code)??null,runtime_blocker:r(e.runtime_blocker)??null,detail:r(e.detail)??null,checked_at:r(e.checked_at)??null,total_slots:d(e.total_slots),ctx_per_slot:d(e.ctx_per_slot),active_slots_now:d(e.active_slots_now),peak_active_slots:d(e.peak_active_slots),sample_count:d(e.sample_count),last_sample_at:r(e.last_sample_at)??null,timeline:t}}function E_(e){if(!m(e))return null;const t=r(e.run_id),n=r(e.status),s=r(e.decided_by),a=r(e.decided_at),o=r(e.reason);if(!t||!n||!s||!a||!o)return null;const l=[];return Array.isArray(e.history)&&e.history.forEach(c=>{if(!m(c))return;const p=r(c.status),_=r(c.decided_by),u=r(c.decided_at),v=r(c.reason);!p||!_||!u||!v||l.push({status:p,decided_by:_,decided_at:u,reason:v,operation_id:r(c.operation_id)??null,detachment_id:r(c.detachment_id)??null,note:r(c.note)??null})}),{run_id:t,status:n,decided_by:s,decided_at:a,reason:o,operation_id:r(e.operation_id)??null,detachment_id:r(e.detachment_id)??null,note:r(e.note)??null,history:l}}function j_(e){if(!m(e))return null;const t=r(e.run_id),n=r(e.recommended_kind),s=r(e.reason);return!t||!n||!s?null:{run_id:t,recommended_kind:n,continue_available:j(e.continue_available)??!1,rerun_available:j(e.rerun_available)??!1,abandon_available:j(e.abandon_available)??!1,reason:s,evidence:m(e.evidence)?{operation_id:r(e.evidence.operation_id)??null,detachment_id:r(e.evidence.detachment_id)??null,joined_workers:d(e.evidence.joined_workers),current_task_bound:d(e.evidence.current_task_bound),fresh_heartbeats:d(e.evidence.fresh_heartbeats),trace_events:d(e.evidence.trace_events),message_events:d(e.evidence.message_events),runtime_blocker:r(e.evidence.runtime_blocker)??null}:void 0,provenance:r(e.provenance),decision_engine:r(e.decision_engine),authoritative:j(e.authoritative)}}function N_(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),run_id:r(t.run_id),room_id:r(t.room_id),operation_id:r(t.operation_id)??null,run_resolution:E_(t.run_resolution),resolution_recommendation:j_(t.resolution_recommendation),recommended_next_tool:r(t.recommended_next_tool),summary:n?{expected_workers:d(n.expected_workers),joined_workers:d(n.joined_workers),live_workers:d(n.live_workers),squad_roster_size:d(n.squad_roster_size),detachment_roster_size:d(n.detachment_roster_size),current_task_bound:d(n.current_task_bound),fresh_heartbeats:d(n.fresh_heartbeats),claim_markers_seen:d(n.claim_markers_seen),done_markers_seen:d(n.done_markers_seen),final_markers_seen:d(n.final_markers_seen),completed_workers:d(n.completed_workers),peak_hot_slots:d(n.peak_hot_slots),hot_window_ok:j(n.hot_window_ok),pass_hot_concurrency:j(n.pass_hot_concurrency),pass_end_to_end:j(n.pass_end_to_end),pending_decisions:d(n.pending_decisions),pass:j(n.pass)}:void 0,provider:P_(t.provider),operation:Wa(t.operation),squad:zo(t.squad),detachment:_c(t.detachment),workers:Array.isArray(t.workers)?t.workers.map(z_).filter(s=>s!==null):[],checklist:Array.isArray(t.checklist)?t.checklist.map(R_).filter(s=>s!==null):[],blockers:Array.isArray(t.blockers)?t.blockers.map(M_).filter(s=>s!==null):[],recent_messages:Array.isArray(t.recent_messages)?t.recent_messages.map(L_).filter(s=>s!==null):[],recent_trace_events:Array.isArray(t.recent_trace_events)?t.recent_trace_events.map($c).filter(s=>s!==null):[],truth_notes:w(t.truth_notes)}}function D_(e){if(!m(e))return null;const t=r(e.label),n=r(e.value);return!t||!n?null:{label:t,value:n}}function O_(e){if(!m(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.label),a=r(e.tone),o=r(e.provenance);return!t||!n||!s||!a||!o?null:{id:t,kind:n,label:s,subtitle:r(e.subtitle)??null,status:r(e.status)??null,tone:a,pulse:r(e.pulse)??null,provenance:o,visual_class:r(e.visual_class)??void 0,glyph:r(e.glyph)??void 0,parent_id:r(e.parent_id)??null,lane_id:r(e.lane_id)??null,link_tab:r(e.link_tab)??null,link_surface:r(e.link_surface)??null,link_params:m(e.link_params)?Object.fromEntries(Object.entries(e.link_params).map(([l,c])=>{const p=r(c);return p?[l,p]:null}).filter(l=>l!==null)):{},facts:Array.isArray(e.facts)?e.facts.map(D_).filter(l=>l!==null):[]}}function q_(e){if(!m(e))return null;const t=r(e.id),n=r(e.source),s=r(e.target),a=r(e.kind),o=r(e.tone),l=r(e.provenance);return!t||!n||!s||!a||!o||!l?null:{id:t,source:n,target:s,kind:a,label:r(e.label)??null,tone:o,provenance:l,animated:j(e.animated)}}function F_(e){if(!m(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.label),a=r(e.tone),o=r(e.provenance);return!t||!n||!s||!a||!o?null:{id:t,kind:n,label:s,detail:r(e.detail)??null,tone:a,provenance:o,source_id:r(e.source_id)??null,target_id:r(e.target_id)??null,suggested_surface:r(e.suggested_surface)??null,suggested_params:m(e.suggested_params)?Object.fromEntries(Object.entries(e.suggested_params).map(([l,c])=>{const p=r(c);return p?[l,p]:null}).filter(l=>l!==null)):{}}}function w_(e){if(!m(e))return null;const t=r(e.target_kind),n=r(e.target_id),s=r(e.label),a=r(e.reason);return!t||!n||!s||!a?null:{target_kind:t,target_id:n,label:s,reason:a,suggested_surface:r(e.suggested_surface)??null,suggested_params:m(e.suggested_params)?Object.fromEntries(Object.entries(e.suggested_params).map(([o,l])=>{const c=r(l);return c?[o,c]:null}).filter(o=>o!==null)):{}}}function K_(e){const t=m(e)?e:{},n=m(t.room)?t.room:{},s=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),room:{room_id:r(n.room_id),project:r(n.project),cluster:r(n.cluster),paused:j(n.paused),pause_reason:r(n.pause_reason)??null,agent_count:d(n.agent_count),task_count:d(n.task_count),message_count:d(n.message_count)},summary:s?{session_count:d(s.session_count),operation_count:d(s.operation_count),detachment_count:d(s.detachment_count),lane_count:d(s.lane_count),worker_count:d(s.worker_count),keeper_count:d(s.keeper_count),signal_count:d(s.signal_count),alert_count:d(s.alert_count)}:void 0,nodes:Array.isArray(t.nodes)?t.nodes.map(O_).filter(a=>a!==null):[],edges:Array.isArray(t.edges)?t.edges.map(q_).filter(a=>a!==null):[],signals:Array.isArray(t.signals)?t.signals.map(F_).filter(a=>a!==null):[],focus:w_(t.focus),swarm_status:Po(t.swarm_status),swarm_proof:hc(t.swarm_proof),truth_notes:w(t.truth_notes)}}function rt(e){Y.value=e,Lo(e)&&B_()}async function kc(){pa.value=!0,_a.value=null;try{const e=await vu();Ro.value=__(e)}catch(e){_a.value=e instanceof Error?e.message:"Failed to load command-plane summary"}finally{pa.value=!1}}function Eo(e){Zt.value=e}async function jo(){ma.value=!0,va.value=null;try{const e=await _u();we.value=m_(e)}catch(e){va.value=e instanceof Error?e.message:"Failed to load command-plane snapshot"}finally{ma.value=!1}}async function B_(){we.value||ma.value||await jo()}async function Kt(){await kc(),Lo(Y.value)&&await jo()}async function en(){var e;Zi.value=!0,ba.value=null;try{const t=await gu(),n=$_(t);cs.value=n;const s=Zt.value;n.operations.length===0?Zt.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Zt.value=((e=n.operations[0])==null?void 0:e.operation.operation_id)??null)}catch(t){ba.value=t instanceof Error?t.message:"Failed to load chain summary"}finally{Zi.value=!1}}function U_(){xn=null,Kn.value=null,ka.value=!1,Bn.value=null}async function H_(e){xn=e,ka.value=!0,Bn.value=null;try{const t=await fu(e);if(xn!==e)return;Kn.value=y_(t)}catch(t){if(xn!==e)return;Kn.value=null,Bn.value=t instanceof Error?t.message:"Failed to load chain run"}finally{xn===e&&(ka.value=!1)}}async function W_(){Xi.value=!0,fa.value=null;try{const e=await $u();ls.value=T_(e)}catch(e){fa.value=e instanceof Error?e.message:"Failed to load command-plane help"}finally{Xi.value=!1}}async function tt(e=cc(),t=dc()){$a.value=!0,ha.value=null;try{const n=await hu(e,t);Nt.value=N_(n)}catch(n){ha.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{$a.value=!1}}async function Rt(e=cc(),t=dc()){Qi.value=!0,ya.value=null;try{const n=await yu(e,t);Mo.value=K_(n)}catch(n){ya.value=n instanceof Error?n.message:"Failed to load orchestra map"}finally{Qi.value=!1}}async function vt(e,t,n){Vi.value=e,ga.value=null;try{await bu(t,n),await kc(),(we.value||Lo(Y.value))&&await jo(),await tt(),await Rt(),await en()}catch(s){throw ga.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{Vi.value=null}}function G_(e){return vt(`pause:${e}`,"/api/v1/command-plane/operations/pause",{operation_id:e})}function J_(e){return vt(`resume:${e}`,"/api/v1/command-plane/operations/resume",{operation_id:e})}function Y_(e){return vt(`recall:${e}`,"/api/v1/command-plane/dispatch/recall",{operation_id:e})}function V_(e={}){return vt("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...e.operationId?{operation_id:e.operationId}:{},...e.detachmentId?{detachment_id:e.detachmentId}:{}})}function X_(e){return vt(`approve:${e}`,"/api/v1/command-plane/policy/approve",{decision_id:e})}function Q_(e){return vt(`deny:${e}`,"/api/v1/command-plane/policy/deny",{decision_id:e})}function Z_(e,t){return vt(`freeze:${e}`,"/api/v1/command-plane/policy/freeze",{unit_id:e,enabled:t})}function ev(e,t){return vt(`kill:${e}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:e,enabled:t})}gm(()=>{Kt(),en(),(Y.value==="swarm"||Y.value==="warroom"||Y.value==="orchestra"||Nt.value!==null)&&tt(),(Y.value==="orchestra"||Mo.value!==null)&&Rt(),Y.value==="warroom"&&be()});function eo(e){e==="command"&&(It(),Kt(),en(),(Y.value==="swarm"||Y.value==="warroom"||Y.value==="orchestra")&&tt(),Y.value==="orchestra"&&Rt(),Y.value==="warroom"&&be()),e==="mission"&&(It(),ic(),ua()),e==="proof"&&rc(O.value.params.session_id,O.value.params.operation_id),e==="execution"&&(It(),At()),e==="intervene"&&(It(),be(),Pt()),e==="memory"&&it(),e==="planning"&&Ao(),e==="lab"&&ot()}function tv({metric:e}){return i`
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
  `}function nv({panel:e}){return i`
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
            ${e.metrics.map(t=>i`<${tv} key=${t.id} metric=${t} />`)}
          </div>`:null}
    </div>
  `}function F({panelId:e,compact:t=!1,label:n="왜 필요한가"}){const s=sm(e);return s?i`
    <details class="semantic-inline ${t?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${nv} panel=${s} />
    </details>
  `:ia.value?i`<span class="semantic-inline-state">의미 계층 불러오는 중…</span>`:null}function ke({surfaceId:e,compact:t=!1}){const n=nm(e);return n?i`
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
  `:ia.value?i`<div class="semantic-surface-card ${t?"compact":""}">의미 계층 불러오는 중…</div>`:oa.value?i`<div class="semantic-surface-card ${t?"compact":""}">${oa.value}</div>`:null}function R({title:e,class:t,semanticId:n,testId:s,children:a}){return i`
    <div class="card ${t??""}" data-testid=${s}>
      ${e?i`
            <div class="card-title-row">
              <div class="card-title">${e}</div>
              ${n?i`<${F} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}function ni(e){const t=(e??"").trim().toLowerCase();return t==="bad"||t==="critical"||t==="offline"?"bad":t==="warn"||t==="paused"||t==="blocked"?"warn":"ok"}function sv(){var n;const e=(n=Io.value)==null?void 0:n.focus;if(!(e!=null&&e.suggested_tab))return;const t=e.suggested_params??{};if(e.suggested_tab==="intervene"){oe("intervene",t);return}oe("command",{...e.suggested_surface?{surface:e.suggested_surface}:{},...t})}function Ga(){var p,_,u,v,g,$;const e=Io.value;if(!e)return Wi.value?i`<section class="room-truth-strip room-truth-strip-loading">room truth 불러오는 중...</section>`:ra.value?i`<section class="room-truth-strip room-truth-strip-error">${ra.value}</section>`:null;const t=e.room.status,n=e.room.counts,s=(p=e.execution)==null?void 0:p.summary,a=(_=e.execution)==null?void 0:_.top_queue,o=e.command,l=e.operator,c=e.focus;return i`
    <section class="room-truth-strip">
      <article class="room-truth-card">
        <span class="room-truth-label">room truth</span>
        <strong>${(t==null?void 0:t.project)??"project"} · ${(t==null?void 0:t.room)??"default"}</strong>
        <p>${(n==null?void 0:n.agents)??0} agents · ${(n==null?void 0:n.tasks)??0} tasks · ${(n==null?void 0:n.keepers)??0} keepers</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${t!=null&&t.paused?"warn":"ok"}">${t!=null&&t.paused?"일시정지":"열림"}</span>
          <span class="command-chip">${(t==null?void 0:t.cluster)??"cluster:unknown"}</span>
          <span class="command-chip">${e.room.provenance??"truth"}</span>
        </div>
      </article>

      <article class="room-truth-card">
        <span class="room-truth-label">execution</span>
        <strong>세션 ${(s==null?void 0:s.active_sessions)??0} · 막힘 ${(s==null?void 0:s.blocked_sessions)??0}</strong>
        <p>${(a==null?void 0:a.summary)??"지금은 실행 대기열 최상단 항목이 없습니다."}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${ni(((s==null?void 0:s.blocked_sessions)??0)>0?"warn":"ok")}">priority ${(s==null?void 0:s.priority_items)??0}</span>
          <span class="command-chip">${((u=e.execution)==null?void 0:u.provenance)??"derived"}</span>
        </div>
      </article>

      <article class="room-truth-card">
        <span class="room-truth-label">control</span>
        <strong>작전 ${(o==null?void 0:o.active_operations)??0} · 승인 ${(o==null?void 0:o.pending_approvals)??0}</strong>
        <p>alerts bad ${(o==null?void 0:o.bad_alerts)??0} / warn ${(o==null?void 0:o.warn_alerts)??0} · lanes ${(o==null?void 0:o.moving_lanes)??0}/${(o==null?void 0:o.active_lanes)??0}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${ni(((o==null?void 0:o.bad_alerts)??0)>0?"bad":((o==null?void 0:o.warn_alerts)??0)>0||((o==null?void 0:o.pending_approvals)??0)>0?"warn":"ok")}">
            health ${(l==null?void 0:l.health)??"ok"}
          </span>
          <span class="command-chip">${(o==null?void 0:o.provenance)??"truth"}</span>
        </div>
      </article>

      <article class="room-truth-card room-truth-card-focus">
        <span class="room-truth-label">next focus</span>
        <strong>${(c==null?void 0:c.label)??"지금은 방 전체가 비교적 안정적입니다"}</strong>
        <p>${(c==null?void 0:c.reason)??((g=(v=l==null?void 0:l.attention_summary)==null?void 0:v.top_item)==null?void 0:g.summary)??(a==null?void 0:a.summary)??"다음 drill-down 대상이 아직 없습니다."}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${ni((c==null?void 0:c.provenance)==="fallback"?"warn":"ok")}">${(c==null?void 0:c.source)??"steady"}</span>
          <span class="command-chip">${(c==null?void 0:c.provenance)??(($=l==null?void 0:l.recommendation_summary)==null?void 0:$.provenance)??"derived"}</span>
        </div>
        ${c!=null&&c.suggested_tab?i`
              <div class="room-truth-actions">
                <button class="control-btn ghost" onClick=${sv}>
                  ${c.suggested_tab==="intervene"?"개입면 열기":"지휘면 열기"}
                </button>
              </div>
            `:null}
      </article>
    </section>
  `}const xa="masc_dashboard_workflow_context",av=900*1e3;function $e(e){return typeof e=="string"&&e.trim()!==""?e.trim():null}function Xe(e){const t=$e(e);return t||(typeof e=="number"&&Number.isFinite(e)?String(e):null)}function xc(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function to(e){return m(e)?e:null}function iv(e){if(!e)return null;try{return JSON.stringify(e)}catch{return null}}function ov(e){if(!e)return null;try{const t=JSON.parse(e);if(!m(t))return null;const n=$e(t.id),s=$e(t.source_surface),a=$e(t.source_label),o=$e(t.summary),l=$e(t.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!o||!l?null:{id:n,source_surface:s,source_label:a,action_type:$e(t.action_type),target_type:$e(t.target_type),target_id:$e(t.target_id),focus_kind:$e(t.focus_kind),operation_id:$e(t.operation_id),command_surface:$e(t.command_surface),summary:o,payload_preview:$e(t.payload_preview),suggested_payload:to(t.suggested_payload),preview:t.preview??null,evidence:t.evidence??null,created_at:l}}catch{return null}}function No(e){const t=Date.parse(e.created_at);return Number.isNaN(t)?!1:Date.now()-t<=av}function rv(){const e=xc(),t=ov((e==null?void 0:e.getItem(xa))??null);return t?No(t)?t:(e==null||e.removeItem(xa),null):null}const Sc=f(rv());function Cc(e){const t=e&&No(e)?e:null;Sc.value=t;const n=xc();if(!n)return;if(!t){n.removeItem(xa);return}const s=iv(t);s&&n.setItem(xa,s)}function lv(e){if(!e)return null;const t=to(e.suggested_payload);if(t)return t;if(m(e.preview)){const n=to(e.preview.payload);if(n)return n}return null}function cv(e){if(!e)return null;const t=Xe(e.message);if(t)return t;const n=Xe(e.task_title)??Xe(e.title),s=Xe(e.task_description)??Xe(e.description),a=Xe(e.reason),o=Xe(e.priority)??Xe(e.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function Do(e,t,n,s,a,o,l,c){return[e,t,n??"action",s??"target",a??"room",o??"focus",l??"operation",c].join(":")}function _n(e,t,n="상황판 추천 액션"){const s=new Date().toISOString(),a=lv(e),o=(e==null?void 0:e.target_type)??(t==null?void 0:t.target_type)??null,l=(e==null?void 0:e.target_id)??(t==null?void 0:t.target_id)??null,c=(t==null?void 0:t.kind)??(e==null?void 0:e.action_type)??null,p=(e==null?void 0:e.reason)??(t==null?void 0:t.summary)??n;return{id:Do("mission",n,(e==null?void 0:e.action_type)??null,o,l,c,null,s),source_surface:"mission",source_label:n,action_type:(e==null?void 0:e.action_type)??null,target_type:o,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:p,payload_preview:cv(a),suggested_payload:a,preview:(e==null?void 0:e.preview)??null,evidence:(t==null?void 0:t.evidence)??null,created_at:s}}function dv({targetType:e,targetId:t,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:o=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:Do("execution",s,null,e,t,n,o,c),source_surface:"execution",source_label:s,action_type:null,target_type:e,target_id:t,focus_kind:n,operation_id:o,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function uv(e,t){return(t.source==="mission"||t.source==="execution")&&(t.action_type??null)===(e.action_type??null)&&(t.target_type??null)===(e.target_type??null)&&(t.target_id??null)===(e.target_id??null)&&(t.focus_kind??null)===(e.focus_kind??null)&&(t.operation_id??null)===(e.operation_id??null)}function ds(e){const{params:t}=e;if(t.source!=="mission"&&t.source!=="execution")return null;const n=Sc.value;if(n&&No(n)&&uv(n,t))return n;const s=new Date().toISOString(),a=t.source==="execution"?"execution":"mission";return{id:Do(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",t.action_type??null,t.target_type??null,t.target_id??null,t.focus_kind??null,t.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:t.action_type??null,target_type:t.target_type??null,target_id:t.target_id??null,focus_kind:t.focus_kind??t.action_type??null,operation_id:t.operation_id??null,command_surface:t.surface??null,summary:a==="execution"?t.focus_kind?`${t.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":t.focus_kind?`${t.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function Ac(e){return{source:e.source_surface,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function Ic(e){if(e.command_surface)return e.command_surface;const t=[e.focus_kind,e.summary,e.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"summary":t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")||t.includes("swarm")?"swarm":e.focus_kind==="operation"||e.target_type==="operation"?"operations":e.target_type==="room"?"orchestra":"swarm"}function Tc(e){return{source:e.source_surface,surface:Ic(e),...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function pv(e){return Ac(e)}function mv(e){return Tc(e)}function Oo(e){return e!=null&&e.target_type?e.target_id?`${e.target_type} · ${e.target_id}`:e.target_type:"대상 정보 없음"}function Ja(e){switch(e){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(e==null?void 0:e.trim())||"추천 액션"}}function _v(e){switch(e){case"warroom":return"워룸";case"summary":return"요약";case"orchestra":return"오케스트라";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(e==null?void 0:e.trim())||"지휘"}}const He=f(null),nt=f(null);function ze(e,t=120){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-1)}…`:n:null}function Re(e){return e==="bad"||e==="offline"||e==="critical"||e==="risk"?"bad":e==="warn"||e==="pending"||e==="degraded"||e==="interrupted"||e==="watch"?"warn":"ok"}function Ge(e){if(!e)return"방금";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function vv(e){return typeof e!="number"||!Number.isFinite(e)||e<0?"확인 필요":e<60?`${Math.round(e)}초`:e<3600?`${Math.round(e/60)}분`:e<86400?`${Math.round(e/3600)}시간`:`${Math.round(e/86400)}일`}function Oe(e){switch((e??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"pending":return"대기 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":case"watch":return"주의";case"bad":case"critical":case"risk":return"위험";case"degraded":return"저하";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"loading":return"불러오는 중";case"error":return"오류";case"unavailable":return"사용 불가";case"stale":return"오래됨";case"refreshing":return"갱신 중";case"cached":return"캐시";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function Sa(e){switch((e??"").trim().toLowerCase()){case"room":return"방";case"team_session":case"session":return"세션";case"operation":return"작전";case"keeper":return"키퍼";case"agent":return"에이전트";default:return(e==null?void 0:e.trim())||"대상"}}function hr(e){switch((e??"").trim().toLowerCase()){case"metadata_gap":return"메타데이터 부족";case"mixed":return"신호 혼재";case"":return null;default:return(e==null?void 0:e.trim())||null}}function gv(e){return e!=null&&e.confirm_required?"확인 후 실행":"즉시 실행"}function fv(e){return Oo(e?_n(e,null,"상황판 추천 액션"):null)}function Ya(e,t=_n()){Cc(t),oe(e,e==="intervene"?pv(t):mv(t))}function Rc(e){Ya("intervene",_n(null,e,"상황판 incident"))}function Mc(e){Ya("command",_n(null,e,"상황판 incident"))}function qo(e,t,n="상황판 추천 액션"){Ya("intervene",_n(e,t,n))}function Lc(e,t,n="상황판 추천 액션"){Ya("command",_n(e,t,n))}function no(e,t){const n={source:"mission",target_type:"team_session",target_id:t,focus_kind:"team_session"};e==="command"&&(n.surface="swarm"),oe(e,n)}function $v(e){return{kind:e.kind,severity:e.severity,summary:e.summary,target_type:e.target_type,target_id:e.target_id??null,actor:null,evidence:e.evidence_preview}}function hv(e){var n,s;const t=_t.value.find(a=>a.name===e.name||a.agent_name===e.agent_name)??null;return{brief:e,keeper:t,currentWork:ze(e.current_work,110)??ze(t==null?void 0:t.skill_primary,110)??ze(t==null?void 0:t.last_proactive_reason,110)??"명시된 키퍼 초점 없음",recentInput:ze(t==null?void 0:t.recent_input_preview,120)??null,recentOutput:ze(t==null?void 0:t.recent_output_preview,120)??ze((n=t==null?void 0:t.diagnostic)==null?void 0:n.last_reply_preview,120)??ze(t==null?void 0:t.last_proactive_preview,120)??null,recentEvent:ze(t==null?void 0:t.last_proactive_reason,120)??ze((s=t==null?void 0:t.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(t==null?void 0:t.recent_tool_names)??[]}}function yv(){const e=Ha.value;if(!e)return new Map;const t=e.sessions.length>0?e.sessions:e.session_briefs;return new Map(t.map(n=>[n.session_id,n]))}function bv(e){He.value=He.value===e?null:e,nt.value=null}function zc(e){nt.value=nt.value===e?null:e,He.value=null}function kv(){He.value=null,nt.value=null}function xv({ratio:e,size:t=40,stroke:n=4}){if(e==null)return null;const s=(t-n)/2,a=t/2,o=2*Math.PI*s,l=o*((100-e*100)/100);let c="mitosis-safe";return e>=.8?c="mitosis-critical":e>=.5&&(c="mitosis-warn"),i`
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
  `}function Sv(e){switch(e.trim().toLowerCase()){case"active":case"running":return"가동 중";case"working":return"작업 중";case"watching":return"관찰 중";case"quiet":return"조용함";case"idle":return"유휴";case"ok":case"healthy":return"정상";case"warn":case"warning":case"degraded":return"주의";case"bad":case"critical":case"error":case"failed":return"위험";case"blocked":return"막힘";case"paused":return"일시정지";case"pending":return"대기";case"offline":case"inactive":return"오프라인";case"connected":return"연결됨";case"disconnected":return"끊김";case"ready":return"준비됨";case"done":case"completed":return"완료";case"unknown":return"알 수 없음";default:return e}}function gt({status:e,label:t}){return i`
    <span class="status-badge ${e}">
      <span class="status-dot-inline ${e}"></span>
      ${t??Sv(e)}
    </span>
  `}function Pc(e){const t=Date.now(),n=typeof e=="number"?e<1e12?e*1e3:e:new Date(e).getTime(),s=Math.floor((t-n)/1e3);if(s<60)return`${s}초 전`;const a=Math.floor(s/60);if(a<60)return`${a}분 전`;const o=Math.floor(a/60);return o<24?`${o}시간 전`:`${Math.floor(o/24)}일 전`}function X({timestamp:e}){const t=Pc(e),n=typeof e=="string"?e:new Date(e<1e12?e*1e3:e).toISOString();return i`<span class="time-ago" title=${n}>${t}</span>`}function Cv(e){return typeof e!="number"||Number.isNaN(e)?"—":`${Math.round(e*100)}%`}function yr(e,t="없음"){return!e||e.length===0?t:e.slice(0,4).join(", ")}function Ec({model:e,onClick:t,variant:n,testId:s}){var c,p,_,u;const a=!!e.recentEvent||!!e.recentInput||!!e.recentOutput||!!e.routeSummary||!!e.auditSource||!!e.auditAt||(((c=e.recentTools)==null?void 0:c.length)??0)>0||(((p=e.allowedTools)==null?void 0:p.length)??0)>0,o=n==="mission"?`mission-activity-card ${e.tone}`:"keeper-canonical-card",l=n==="mission"?"mission-card-select":`monitor-row ${e.tone}${e.stateClass?` state-${e.stateClass}`:""}`;return i`
    <article class=${o}>
      <button class=${l} data-testid=${s} onClick=${t}>
        <div class=${n==="mission"?"mission-activity-head":"monitor-row-header"}>
          <div class=${n==="mission"?"mission-activity-title":"monitor-row-title"}>
            <span class="agent-emoji">${e.emoji??""}</span>
            <div>
              <div class=${n==="mission"?"":"monitor-name-line"}>
                <strong class=${n==="mission"?"":"monitor-title"}>${e.name}</strong>
                ${e.koreanName?i`<span class=${n==="mission"?"":"monitor-sub"}>${e.koreanName}</span>`:null}
              </div>
              ${e.runtimeLabel?i`<div class=${n==="mission"?"":"monitor-sub"}>${e.runtimeLabel}</div>`:null}
              ${e.note?i`<div class=${n==="mission"?"":"monitor-note"}>${e.note}</div>`:null}
            </div>
          </div>
          ${n==="execution"?i`
                <${xv} ratio=${e.contextRatio??0} size=${34} stroke=${4} />
                <${gt} status=${e.statusRaw??"unknown"} />
                ${e.stateLabel?i`<span class="monitor-pill ${e.tone}">${e.stateLabel}</span>`:null}
              `:i`<span class="command-chip ${e.tone}">${e.statusLabel}</span>`}
        </div>

        <div class=${n==="mission"?"mission-activity-meta":"monitor-meta"}>
          ${e.lastActivityAt?i`<span>최근 활동 <${X} timestamp=${e.lastActivityAt} /></span>`:i`<span>${e.lastActivityFallback??"최근 활동 없음"}</span>`}
          ${e.relatedSessionId?i`<span>세션 · ${e.relatedSessionId}</span>`:null}
          ${e.continuity?i`<span>${e.continuity}</span>`:null}
          ${e.lifecycle?i`<span>생애주기 ${e.lifecycle}</span>`:null}
          <span>컨텍스트 ${Cv(e.contextRatio)}</span>
        </div>

        <div class=${n==="mission"?"mission-activity-focus":"monitor-focus"}>
          ${n==="mission"?i`
                <span>무엇을</span>
                <strong>${e.focus}</strong>
              `:i`${e.focus}`}
        </div>

        ${e.summary?i`<div class=${n==="mission"?"mission-inline-note":"monitor-footnote"}>${e.summary}</div>`:null}
      </button>

      ${a?i`
            <details class="mission-card-disclosure compact">
              <summary>${e.disclosureLabel??"세부 정보"}</summary>
              <div class="mission-activity-foot">
                ${e.recentEvent?i`<span>최근 일 · ${e.recentEvent}</span>`:null}
                ${e.routeSummary?i`<span>route · ${e.routeSummary}</span>`:null}
                ${e.auditSource?i`<span>audit · ${e.auditSource}</span>`:null}
                ${e.auditAt?i`<span><${X} timestamp=${e.auditAt} /></span>`:null}
              </div>
              ${e.recentInput||e.recentOutput?i`
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
                  `:null}
              ${(((_=e.recentTools)==null?void 0:_.length)??0)>0||(((u=e.allowedTools)==null?void 0:u.length)??0)>0?i`
                    <div class="mission-activity-foot">
                      <span>최근 도구 · ${yr(e.recentTools)}</span>
                      <span>허용 도구 · ${yr(e.allowedTools)}</span>
                    </div>
                  `:null}
            </details>
          `:null}
    </article>
  `}function jc(e,t){const n=e==null?void 0:e.trim(),s=t==null?void 0:t.trim();return s?n&&s===n?null:s:null}function Nc(e,t){const n=jc(e,t);return n?`runtime · ${n}`:null}function Dc(e,t){const n=e==null?void 0:e.trim(),s=jc(n,t);return n?s?`keeper key · ${n} · runtime agent · ${s}`:`keeper key · ${n}`:null}function si(e){return(e==null?void 0:e.trim().toLowerCase())??""}function Av(e){var t,n;return e?((t=e.agent)==null?void 0:t.exists)===!1||si((n=e.diagnostic)==null?void 0:n.health_state)==="offline"||si(e.status)==="offline"||si(e.status)==="inactive"?"offline":"online":"unlinked"}function Iv(e){switch(e){case"offline":return"offline";case"none_recent":return"none_recent";case"not_applicable":return"not_applicable";case"unlinked":return"unlinked";default:return"not_collected"}}function Tv(e){const t=Av(e);return t==="unlinked"?"unlinked":t==="offline"?"offline":"none_recent"}let Rv=0;const Mt=f([]);function N(e,t="success",n=4e3){const s=++Rv;Mt.value=[...Mt.value,{id:s,message:e,type:t}],setTimeout(()=>{Mt.value=Mt.value.filter(a=>a.id!==s)},n)}function Mv(e){Mt.value=Mt.value.filter(t=>t.id!==e)}function Lv(){const e=Mt.value;return e.length===0?null:i`
    <div class="toast-container">
      ${e.map(t=>i`
        <div key=${t.id} class="toast ${t.type}" onClick=${()=>Mv(t.id)}>
          ${t.message}
        </div>
      `)}
    </div>
  `}const zv="masc_dashboard_agent_name",vn=f(null),Ca=f(!1),Un=f(""),Aa=f([]),Hn=f([]),tn=f(""),Mn=f(!1);function us(e){vn.value=e,Fo()}function br(){vn.value=null,Un.value="",Aa.value=[],Hn.value=[],tn.value=""}function Pv(){const e=vn.value;return e?Ve.value.find(t=>t.name===e)??null:null}function Oc(e){return e?st.value.filter(t=>t.assignee===e):[]}function Ev(e){return e?_t.value.find(t=>t.agent_name===e||t.name===e)??null:null}function jv(e){if(!e)return null;const t=Ha.value;return t?t.agent_briefs.find(n=>n.agent_name===e)??null:null}function Nv(e){return e?ko.value.find(t=>t.agent_name===e||t.name===e)??null:null}async function Fo(){const e=vn.value;if(e){Ca.value=!0,Un.value="",Aa.value=[],Hn.value=[];try{const t=await tp(80);Aa.value=t.filter(a=>a.includes(e)).slice(0,20);const n=Oc(e).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await np(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const l=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));Hn.value=s}catch(t){Un.value=t instanceof Error?t.message:"Failed to load agent detail"}finally{Ca.value=!1}}}async function kr(){var s;const e=vn.value,t=tn.value.trim();if(!e||!t)return;const n=((s=localStorage.getItem(zv))==null?void 0:s.trim())||"dashboard";Mn.value=!0;try{await ep(n,`@${e} ${t}`),tn.value="",N(`Mention sent to ${e}`,"success"),Fo()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";N(o,"error")}finally{Mn.value=!1}}function Dv({task:e}){return i`
    <div class="agent-detail-task">
      <span class="pill">${e.id}</span>
      <span class="agent-detail-task-title">${e.title}</span>
      <${gt} status=${e.status} />
    </div>
  `}function Ov({row:e}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${e.taskId}</span>
      </div>
      <pre class="agent-history-pre">${e.text||"No task history yet"}</pre>
    </div>
  `}function xr(e,t=160){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-1)}…`:n:null}function qv(){const e=vn.value;if(!e)return null;const t=Pv(),n=Ev(e),s=Nv(e),a=jv(e),o=Oc(e),l=Aa.value,c=(a==null?void 0:a.display_name)??(n==null?void 0:n.name)??e,p=c!==e?e:null,_=(t==null?void 0:t.status)??(a==null?void 0:a.status)??"unknown",u=!t&&(a==null?void 0:a.is_live)===!1,v=(t==null?void 0:t.last_seen)??(a==null?void 0:a.last_activity_at)??null,g=(t==null?void 0:t.emoji)??(n==null?void 0:n.emoji),$=(t==null?void 0:t.koreanName)??(n==null?void 0:n.koreanName),C=xr(s==null?void 0:s.continuity_summary)??xr(s==null?void 0:s.skill_route_summary)??null,b=Dc(n==null?void 0:n.name,n==null?void 0:n.agent_name);return i`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${k=>{k.target.classList.contains("agent-detail-overlay")&&br()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${g?i`<span style="font-size:2rem">${g}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${c}
                  ${$?i`<span style="font-size:0.75em;color:#888">(${$})</span>`:""}
                  ${p?i`<span class="mono" style="font-size:0.75em;color:#888">${p}</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  <${gt} status=${_} />
                  ${u?i`<span class="pill">archived session participant</span>`:null}
                  ${t!=null&&t.model?i`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${t.model}</span>`:""}
                  ${!t&&(a!=null&&a.archived_reason)?i`<span style="font-size:0.75rem;color:#888">${a.archived_reason}</span>`:null}
                </div>
              </div>
            </div>
            <div class="agent-detail-sub">
              ${t!=null&&t.current_task||a!=null&&a.current_work?i`<span>Task: ${(t==null?void 0:t.current_task)??(a==null?void 0:a.current_work)}</span>`:null}
              ${v?i`<span>Last seen: <${X} timestamp=${v} /></span>`:null}
            </div>
            ${n||C||a!=null&&a.related_session_id?i`
                  <div class="agent-detail-sub">
                    ${n?i`<span>Linked keeper: ${n.name}${b?` · ${b}`:""}</span>`:null}
                    ${a!=null&&a.related_session_id?i`<span>Session: ${a.related_session_id}</span>`:null}
                    ${C?i`<span>${C}</span>`:null}
                  </div>
                `:null}
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Fo()}} disabled=${Ca.value}>
              ${Ca.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${br}>Close</button>
          </div>
        </div>

        ${Un.value?i`<div class="council-error">${Un.value}</div>`:null}

        <div class="agent-detail-grid">
          <${R} title="Assigned Tasks">
            ${o.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${o.map(k=>i`<${Dv} key=${k.id} task=${k} />`)}</div>`}
          <//>

          <${R} title="Recent Activity">
            ${l.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${l.map((k,h)=>i`<div key=${h} class="agent-activity-line">${k}</div>`)}</div>`}
          <//>
        </div>
        <${R} title="Task History">
          ${Hn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${Hn.value.map(k=>i`<${Ov} key=${k.taskId} row=${k} />`)}</div>`}
        <//>

        <${R} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${tn.value}
              onInput=${k=>{tn.value=k.target.value}}
              onKeyDown=${k=>{k.key==="Enter"&&kr()}}
              disabled=${Mn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{kr()}}
              disabled=${Mn.value||tn.value.trim()===""}
            >
              ${Mn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Fv(e){switch(e){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function wv(e){switch(e){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Kv(e){switch(e.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return e.role}}function Sr(e){return e.delivery==="error"||e.delivery==="timeout"?"bad":e.delivery==="sending"?"warn":e.role==="assistant"?"assistant":e.role==="user"?"user":"warn"}function qc(e){if(!e)return null;const t=new Date(e);return Number.isNaN(t.getTime())?null:t.toLocaleTimeString()}function Bv(e){return typeof e!="number"||!Number.isFinite(e)||e<=0?null:e<60?`${Math.round(e)}s`:`${Math.ceil(e/60)}m`}function Cr(e){switch(e){case"desired_offline":return"desired offline";case"recovering":return"recovering";case"healthy":return"healthy";case"offline":return"offline";default:return null}}function Fc(e){if(!e)return null;const t=Je.value[e.name];return(t==null?void 0:t.diagnostic)??e.diagnostic??null}function Uv({keeper:e,showRawStatus:t=!1}){if(ae(()=>{e!=null&&e.name&&Il(e.name)},[e==null?void 0:e.name]),!e)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Je.value[e.name],s=Fc(e),a=Di.value[e.name];return s?i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        ${Cr(s==null?void 0:s.continuity_state)?i`<span class="pill">${Cr(s==null?void 0:s.continuity_state)}</span>`:null}
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Fv(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${wv((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.continuity_summary)??(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${s.last_reply_status}
        ${s.last_reply_at?i` · ${qc(s.last_reply_at)}`:null}
        ${s.next_eligible_at_s?i` · next eligible ${Bv(s.next_eligible_at_s)}`:null}
      </div>
      ${s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${t?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `:i`
      <div class="control-result-box">
        <div class="control-status-copy">
          실시간 진단 데이터가 아직 없습니다.
        </div>
        ${t?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
      </div>
    `}function Hv({keeperName:e,placeholder:t}){const[n,s]=vo("");ae(()=>{e&&Il(e)},[e]);const a=me.value[e]??[],o=Oi.value[e]??!1,l=Ye.value[e],c=async()=>{const p=n.trim();if(!(!e||!p)){s("");try{await kp(e,p)}catch(_){const u=_ instanceof Error?_.message:`Failed to message ${e}`;N(u,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(p=>i`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Sr(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${Sr(p)}`}>${Kv(p)}</span>
                  ${p.timestamp?i`<span class="keeper-conversation-time">${qc(p.timestamp)}</span>`:null}
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
  `}function Wv({actor:e,keeper:t,onPokeLodge:n}){if(!t)return null;const s=Fc(t),a=qi.value[t.name]??!1,o=Fi.value[t.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{xp(t.name,e).catch(p=>{const _=p instanceof Error?p.message:`Failed to probe ${t.name}`;N(_,"error")})}}
        disabled=${a||!e.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{Sp(t.name,e).catch(p=>{const _=p instanceof Error?p.message:`Failed to recover ${t.name}`;N(_,"error")})}}
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
  `}const wo=f(null);function wc(e){wo.value=e,bp(e.name)}function Ar(){wo.value=null}function Gv(e){return typeof e!="number"||Number.isNaN(e)?"확인 필요":e>=.85?"높음":e>=.7?"상승 중":"안정"}function Jv({keeper:e}){var u,v;const t=e.metrics_series??[];if(t.length<2){const g=(((u=e.context)==null?void 0:u.context_ratio)??e.context_ratio??0)*100,$=g>85?"#ef4444":g>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${g.toFixed(1)}%;background:${$}"></div>
        </div>
        <span class="chart-pct">${g.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=t.length,l=t.map((g,$)=>{const C=a+$/(o-1)*(n-2*a),b=s-a-(g.context_ratio??0)*(s-2*a);return{x:C,y:b,p:g}}),c=l.map(({x:g,y:$})=>`${g.toFixed(1)},${$.toFixed(1)}`).join(" "),p=(((v=t[t.length-1])==null?void 0:v.context_ratio)??0)*100,_=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:g})=>g.is_handoff).map(({x:g})=>i`
          <line x1="${g.toFixed(1)}" y1="${a}" x2="${g.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${_}" stroke-width="1.5"/>
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}function Yv({stats:e}){const t=e.max_hp>0?Math.round(e.hp/e.max_hp*100):0,n=e.max_mp>0?Math.round(e.mp/e.max_mp*100):0;return i`
    <div>
      <div style="display:flex; gap:12px; margin-bottom:10px;">
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
        Level ${e.level} · XP ${e.xp}
      </div>
    </div>
  `}function Vv({items:e}){return e.length===0?i`<div class="empty-state" style="font-size:13px;">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${e.map((t,n)=>i`
        <div class="keeper-equipment-row">
          <span>${t}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Xv({rels:e}){const t=Object.entries(e);return t.length===0?i`<div class="empty-state" style="font-size:13px;">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${t.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Ir({traits:e,label:t}){return e.length===0?null:i`
    <div style="margin-bottom:12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${t}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${e.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}async function Qv(){try{const e=await os({actor:fo(),action_type:"lodge_tick",target_type:"room",payload:{}}),t=Al(e.result);await rs(),t!=null&&t.skipped_reason?N(t.skipped_reason,"warning"):N(t?`Poke finished: ${t.acted}/${t.checked} acted`:"Poke finished",t&&t.acted>0?"success":"warning")}catch(e){const t=e instanceof Error?e.message:"Failed to run Lodge poke";N(t,"error")}}function Zv({keeper:e}){return i`
    <div style="margin-top:24px; border-top:1px solid rgba(255,255,255,0.1); padding-top:24px;">
      <h3 style="margin:0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display:grid; grid-template-columns:1fr 1fr; gap:20px;">
        <div style="display:flex; flex-direction:column; gap:12px;">
          <${Uv} keeper=${e} />
          <${Wv}
            actor=${fo()}
            keeper=${e}
            onPokeLodge=${()=>{Qv()}}
          />
        </div>

        <div style="min-height:345px;">
          <${Hv}
            keeperName=${e.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function eg(){var s,a,o,l,c;const e=wo.value;if(!e)return null;const t=Dc(e.name,e.agent_name),n=(((s=e.traits)==null?void 0:s.length)??0)>0||(((a=e.interests)==null?void 0:a.length)??0)>0||!!e.skill_primary||!!e.last_heartbeat;return i`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${p=>{p.target.classList.contains("keeper-detail-overlay")&&Ar()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${e.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${e.name}</h2>
              ${e.koreanName?i`<div style="font-size:13px; color:#888;">${e.koreanName}</div>`:null}
              ${t?i`<div style="font-size:12px; color:#94a3b8;">${t}</div>`:null}
              ${e.agent_name?i`<div style="font-size:12px; color:#888;">Runtime agent: ${e.agent_name}</div>`:null}
            </div>
            <${gt} status=${e.status} />
          </div>
          <button
            onClick=${()=>Ar()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        <${Jv} keeper=${e} />

        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">
          ${n?i`
                <${R} title="Profile">
                  <${Ir} traits=${e.traits??[]} label="Traits" />
                  <${Ir} traits=${e.interests??[]} label="Interests" />
                  ${e.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">Skill route: <span style="color:#22d3ee;">${e.skill_primary}</span></div>`:null}
                  ${e.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">Last heartbeat: <${X} timestamp=${e.last_heartbeat} /></div>`:null}
                <//>
              `:null}

          ${e.trpg_stats?i`
                <${R} title="TRPG Stats">
                  <${Yv} stats=${e.trpg_stats} />
                <//>
              `:null}

          ${e.inventory&&e.inventory.length>0?i`
                <${R} title="Equipment (${e.inventory.length})">
                  <${Vv} items=${e.inventory} />
                <//>
              `:null}

          ${e.relationships&&Object.keys(e.relationships).length>0?i`
                <${R} title="Relationships (${Object.keys(e.relationships).length})">
                  <${Xv} rels=${e.relationships} />
                <//>
              `:null}

          <${R} title="Memory & Context">
            <div class="keeper-signal-list">
              <div class="keeper-signal-row">
                <span>Context pressure</span>
                <strong>${Gv(((o=e.context)==null?void 0:o.context_ratio)??e.context_ratio??null)}</strong>
              </div>
              <div class="keeper-signal-row">
                <span>Current ratio</span>
                <strong>
                  ${typeof(((l=e.context)==null?void 0:l.context_ratio)??e.context_ratio)=="number"?`${Math.round((((c=e.context)==null?void 0:c.context_ratio)??e.context_ratio??0)*100)}%`:"-"}
                </strong>
              </div>
              ${e.memory_recent_note?i`<div class="keeper-memory-note">${e.memory_recent_note}</div>`:i`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>

        <${Zv} keeper=${e} />
      </div>
    </div>
  `}function tg({cluster:e,project:t,room:n,generatedAt:s}){return i`
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
        <strong>${s?Ge(s):"기록 없음"}</strong>
      </div>
    </div>
  `}function ng(){const e=Zl.value,t=Re((e==null?void 0:e.status)??(St.value?"bad":"warn")),n=!e||e.sections.length===0,s=(e==null?void 0:e.status)==="error"||(e==null?void 0:e.status)==="unavailable"&&!(e!=null&&e.cached);return i`
    <${R} title="판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>휴리스틱 대신 별도 판단 결과</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${t}">
          ${Oe((e==null?void 0:e.status)??(St.value?"error":"loading"))}
        </span>
        ${e!=null&&e.model?i`<span class="command-chip">${e.model}</span>`:null}
        ${e!=null&&e.generated_at?i`<span class="command-chip">${Ge(e.generated_at)}</span>`:null}
        ${e!=null&&e.cached?i`<span class="command-chip">캐시</span>`:null}
        ${e!=null&&e.stale?i`<span class="command-chip warn">오래됨</span>`:null}
        ${e!=null&&e.refreshing?i`<span class="command-chip warn">갱신 중</span>`:null}
      </div>

      ${St.value?i`<div class="empty-state error">${St.value}</div>`:null}
      ${e!=null&&e.error?i`<div class="empty-state error">${e.error}</div>`:null}
      ${e!=null&&e.summary?i`<div class="mission-inline-note">${e.summary}</div>`:null}
      ${e!=null&&e.last_error&&!e.error?i`<div class="mission-inline-note">최근 갱신 실패: ${e.last_error}</div>`:null}

      ${e&&e.sections.length>0?i`
            <div class="mission-briefing-grid">
              ${e.sections.slice(0,3).map(a=>i`
                <article class="mission-briefing-section ${Re(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${Re(a.status)}">${Oe(a.status)}</span>
                      ${hr(a.signal_class)?i`<span class="command-chip ${a.signal_class==="mixed"?"warn":""}">${hr(a.signal_class)}</span>`:null}
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
          `:!Ft.value&&!St.value&&n?i`
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
                      <strong>${Sa(a.scope_type)}${a.scope_id?` · ${a.scope_id}`:""}</strong>
                      <span class="command-chip ${a.severity==="watch"?"warn":""}">${Oe(a.severity)}</span>
                    </div>
                    <p>${a.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{ua(s)}} disabled=${Ft.value}>
          ${Ft.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{ua(!0)}} disabled=${Ft.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function sg({item:e,selected:t,sessionLookup:n}){const s=$v(e),a=e.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),o=e.top_action??null;return i`
    <article class="mission-attention-card ${Re((o==null?void 0:o.severity)??e.severity)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>bv(e.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${e.summary}</strong>
            <div class="mission-card-target">${Sa(e.target_type)}${e.target_id?` · ${e.target_id}`:""}</div>
          </div>
          <span class="command-chip ${Re((o==null?void 0:o.severity)??e.severity)}">${o?gv(o):e.severity}</span>
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
            <strong>${e.last_seen_at?Ge(e.last_seen_at):"기록 없음"}</strong>
            <small>${Sa(e.target_type)}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${o?Ja(o.action_type):"판단 필요"}</strong>
            <small>${o?fv(o):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${o?i`<div class="mission-inline-note">${o.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?i`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>i`
                  <button class="mission-link-row" onClick=${()=>zc(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${Oe(l.status)} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:i`<div class="empty-state">직접 연결된 세션이 아직 없습니다.</div>`}

        ${e.related_agent_names.length>0?i`
              <div class="mission-pill-row">
                ${e.related_agent_names.slice(0,8).map(l=>i`
                  <button class="mission-pill action" onClick=${()=>us(l)}>${l}</button>
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
              <button class="control-btn ghost" onClick=${()=>qo(o,s,"상황판 주의 신호")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>Lc(o,s,"상황판 주의 신호")}>
                원인 보기
              </button>
            `:i`
              <button class="control-btn ghost" onClick=${()=>Rc(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Mc(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function ag({brief:e,selected:t}){var l,c;const n=e.member_previews.slice(0,4),s=e.top_recommendation??null,a=e.top_attention??null,o=n.map(p=>p.display_name??p.agent_name);return i`
    <article class="mission-crew-card ${Re(((l=e.top_attention)==null?void 0:l.severity)??e.health??e.status)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>zc(e.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${e.goal}</strong>
            <div class="mission-card-target">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          </div>
          <span class="command-chip ${Re(((c=e.top_attention)==null?void 0:c.severity)??e.health??e.status)}">${Oe(e.status)}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${e.member_names.length}</strong>
            <small>${o.slice(0,3).join(", ")||e.member_names.slice(0,3).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${vv(e.elapsed_sec)}</strong>
            <small>${e.started_at?`${Ge(e.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 흐름</span>
            <strong>${e.last_event_at?Ge(e.last_event_at):"기록 없음"}</strong>
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
        <small>${e.last_event_at?Ge(e.last_event_at):"시각 없음"}</small>
      </div>

      ${e.operation_badges.length>0?i`
            <div class="mission-pill-row">
              ${e.operation_badges.slice(0,3).map(p=>i`
                <span class="mission-pill">
                  ${p.operation_id} · ${Oe(p.status)}${p.stage?` · ${p.stage}`:""}
                </span>
              `)}
            </div>
          `:null}

      ${n.length>0?i`
            <div class="mission-member-preview-grid">
              ${n.map(p=>i`
                <button class="mission-member-preview" onClick=${()=>us(p.agent_name)}>
                  <strong>${p.display_name??p.agent_name}</strong>
                  <span>${p.current_work??"현재 작업 없음"}</span>
                  <small>
                    ${p.recent_output_preview??p.recent_input_preview??"최근 입출력 없음"}
                    ${p.is_live===!1?" · archived participant":""}
                  </small>
                </button>
              `)}
            </div>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>no("intervene",e.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>no("command",e.session_id)}>세션 원인 보기</button>
        ${s?i`<button class="control-btn ghost" onClick=${()=>qo(s,a,"상황판 세션 요약")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function ig({detail:e,loading:t,error:n}){if(t&&!e)return i`
      <${R} title="세션 상세" class="mission-list-card">
        <div class="loading-indicator">세션 상세 불러오는 중...</div>
      <//>
    `;if(n&&!e)return i`
      <${R} title="세션 상세" class="mission-list-card">
        <div class="empty-state error">${n}</div>
      <//>
    `;if(!(e!=null&&e.session))return null;const s=e.session;return i`
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
            <span class="command-chip">${e.timeline.length}</span>
          </div>
          <div class="mission-timeline-list">
            ${e.timeline.length>0?e.timeline.map(a=>i`
                  <article class="mission-timeline-row">
                    <div class="mission-card-head">
                      <strong>${a.summary}</strong>
                      <span>${a.timestamp?Ge(a.timestamp):"시각 없음"}</span>
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
                  <button class="mission-member-preview" onClick=${()=>us(a.agent_name)}>
                    <strong>${a.display_name??a.agent_name}</strong>
                    <span>${a.current_work??"현재 작업 없음"}</span>
                    <small>
                      ${a.recent_output_preview??a.recent_input_preview??"최근 입출력 없음"}
                      ${a.is_live===!1?" · archived participant":""}
                      ${a.last_activity_at?` · ${Ge(a.last_activity_at)}`:""}
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
                  <button class="mission-link-row" onClick=${()=>no("command",s.session_id)}>
                    <strong>${a.operation_id}</strong>
                    <span>${Oe(a.status)}${a.stage?` · ${a.stage}`:""}</span>
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
                    <span>${Oe(a.status)}${a.generation!=null?` · 세대 ${a.generation}`:""}</span>
                    <small>${a.current_work??"현재 작업 정보 없음"}</small>
                  </div>
                `):i`<div class="empty-state">직접 연결된 키퍼는 없습니다.</div>`}
          </div>
        </div>
      </div>
    <//>
  `}function og({row:e}){var o,l,c,p,_,u,v,g,$,C,b,k;const t=[`세대 ${e.brief.generation??((o=e.keeper)==null?void 0:o.generation)??0}`,e.brief.context_ratio!=null?`컨텍스트 ${Math.round(e.brief.context_ratio*100)}%`:((l=e.keeper)==null?void 0:l.context_ratio)!=null?`컨텍스트 ${Math.round(e.keeper.context_ratio*100)}%`:null,e.brief.last_turn_ago_s!=null?`최근 턴 ${Math.round(e.brief.last_turn_ago_s)}초 전`:null].filter(h=>h!==null).join(" · "),n=e.recentTools.length>0?e.recentTools.join(", "):Iv(Tv(e.keeper)),s=Nc(e.brief.name,e.brief.agent_name??((c=e.keeper)==null?void 0:c.agent_name)),a={name:e.brief.name,koreanName:((p=e.keeper)==null?void 0:p.koreanName)??null,runtimeLabel:s,emoji:((_=e.keeper)==null?void 0:_.emoji)??null,tone:Re(e.brief.status??((u=e.keeper)==null?void 0:u.status)),statusRaw:e.brief.status??((v=e.keeper)==null?void 0:v.status)??null,statusLabel:Oe(e.brief.status??((g=e.keeper)==null?void 0:g.status)),focus:e.currentWork,lastActivityAt:(($=e.keeper)==null?void 0:$.last_heartbeat)??null,lastActivityFallback:"최근 활동 없음",continuity:t||"연속성 정보 없음",contextRatio:e.brief.context_ratio??((C=e.keeper)==null?void 0:C.context_ratio)??null,summary:(b=e.keeper)!=null&&b.skill_reason?`판단 요약 · ${ze(e.keeper.skill_reason,120)}`:null,relatedSessionId:null,recentEvent:e.recentEvent,recentInput:e.recentInput,recentOutput:e.recentOutput,recentTools:e.recentTools,allowedTools:[],disclosureLabel:"연속성 상세"};return i`<${Ec}
    variant="mission"
    model=${{...a,recentTools:e.recentTools.length>0?e.recentTools:[n],recentEvent:e.recentEvent??`runtime agent · ${e.brief.agent_name??((k=e.keeper)==null?void 0:k.agent_name)??"기록 없음"}`}}
    onClick=${()=>{e.keeper&&wc(e.keeper)}}
  />`}function rg({item:e}){const t=e.action??null,n=e.attention??null;return i`
    <article class="mission-action-card ${Re(e.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${Re(e.severity)}">
          ${e.signal_type==="action"&&t?Ja(t.action_type):(n==null?void 0:n.kind)??"내부 신호"}
        </span>
        <span class="mission-card-target">${Sa(e.target_type)}${e.target_id?` · ${e.target_id}`:""}</span>
      </div>
      <p>${e.summary}</p>
      ${t?i`<div class="mission-action-preview">${t.reason}</div>`:null}
      <div class="mission-card-actions">
        ${t?i`
              <button class="control-btn ghost" onClick=${()=>qo(t,n,"상황판 내부 신호")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Lc(t,n,"상황판 내부 신호")}>이 이슈의 원인 보기</button>
            `:n?i`
                <button class="control-btn ghost" onClick=${()=>Rc(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>Mc(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function Tr(){var u;const e=Ha.value;if(Gi.value&&!e)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(da.value&&!e)return i`<div class="empty-state error">${da.value}</div>`;if(!e)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;He.value&&!e.attention_queue.some(v=>v.id===He.value)&&(He.value=null);const t=e.sessions;nt.value&&!t.some(v=>v.session_id===nt.value)&&(nt.value=null);const n=e.attention_queue.find(v=>v.id===He.value)??null,s=(n==null?void 0:n.related_session_ids.find(v=>t.some(g=>g.session_id===v)))??null,a=nt.value??s??((u=t[0])==null?void 0:u.session_id)??null,o=yv(),l=t.find(v=>v.session_id===a)??null,c=e.keeper_briefs.slice(0,6).map(hv),p=e.attention_queue.filter(v=>v.related_session_ids.length>0).slice(0,6),_=e.internal_signals.slice(0,3);return ae(()=>{Vm(a)},[a]),i`
    <section class="dashboard-panel mission-view">
      <${ke} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 어떤 세션이 돌고 있고, 누가 참여하며, 어디가 막혔는지를 한 시점에서 읽는 기본 관찰면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${Re(e.summary.room_health)}">${Oe(e.summary.room_health)}</span>
          <span class="command-chip">${e.summary.project??"프로젝트 미지정"}${e.summary.current_room?` · ${e.summary.current_room}`:""}</span>
          <span class="command-chip">${e.generated_at?Ge(e.generated_at):"기록 없음"}</span>
        </div>
      </div>

      <${Ga} />

      <${tg}
        cluster=${e.summary.cluster}
        project=${e.summary.project}
        room=${e.summary.current_room}
        generatedAt=${e.generated_at}
      />

      <${ng} />

      ${a?i`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${(l==null?void 0:l.goal)??a}${n?` · ${n.summary}`:""}</span>
              <button class="control-btn ghost" onClick=${kv}>선택 해제</button>
            </div>
          `:null}

      <${R} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 작전을 먼저 봅니다.</p>
        </div>
        <div class="mission-list-stack">
          ${t.length>0?t.map(v=>i`<${ag} key=${v.session_id} brief=${v} selected=${a===v.session_id} />`):i`<div class="empty-state">지금 활성 세션이 없습니다.</div>`}
        </div>
      <//>

      <${ig}
        detail=${Ji.value}
        loading=${Js.value}
        error=${Ys.value}
      />

      <div class="mission-human-grid">
        <${R} title="주의 대기열" class="mission-list-card" semanticId="mission.attention_queue">
          <div class="mission-section-head">
            <h3>어느 세션을 먼저 봐야 하나</h3>
            <p>문제와 경고는 세션에 연결된 것만 먼저 보여주고, 원인 분석은 선택된 세션에서 이어서 봅니다.</p>
          </div>
          <div class="mission-lane-stack">
            ${p.length>0?p.map(v=>i`<${sg} key=${v.id} item=${v} selected=${He.value===v.id} sessionLookup=${o} />`):i`<div class="empty-state">지금 세션 단위 주의 대기열은 비어 있습니다.</div>`}
          </div>
        <//>

        <${R} title="내부 신호" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>시스템 진단</h3>
            <p>artifact scope drift 같은 내부 신호는 메인 판단을 방해하지 않도록 접어 둔 보조 면에만 둡니다.</p>
          </div>
          <details class="mission-card-disclosure">
            <summary>내부 신호 ${_.length}</summary>
            <div class="mission-list-stack">
              ${_.length>0?_.map(v=>i`<${rg} key=${v.id} item=${v} />`):i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
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
          ${c.length>0?c.map(v=>i`<${og} key=${v.brief.name} row=${v} />`):i`<div class="empty-state">지금 보이는 키퍼가 없습니다.</div>`}
        </div>
        <div class="mission-card-actions">
          <button class="control-btn ghost" onClick=${()=>oe("execution")}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${()=>oe("command")}>지휘 진단면 보기</button>
        </div>
      <//>
    </section>
  `}const lg="modulepreload",cg=function(e){return"/dashboard/"+e},Rr={},dg=function(t,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(_){return Promise.all(_.map(u=>Promise.resolve(u).then(v=>({status:"fulfilled",value:v}),v=>({status:"rejected",reason:v}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),p=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(_=>{if(_=cg(_),_ in Rr)return;Rr[_]=!0;const u=_.endsWith(".css"),v=u?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${_}"]${v}`))return;const g=document.createElement("link");if(g.rel=u?"stylesheet":lg,u||(g.as="script"),g.crossOrigin="",g.href=_,p&&g.setAttribute("nonce",p),document.head.appendChild(g),u)return new Promise(($,C)=>{g.addEventListener("load",$),g.addEventListener("error",()=>C(new Error(`Unable to preload CSS for ${_}`)))})}))}function o(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&o(c.reason);return t().catch(o)})};function Ia(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function te(e){if(!e)return"정보 없음";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function ug(e){if(!e)return"warn";const t=Date.parse(e);return Number.isNaN(t)?"warn":t<=Date.now()?"bad":"ok"}function Kc(e){if(!e)return"정보 없음";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.round((t-Date.now())/1e3);return n<=0?"기한 지남":n<60?`${n}초 후`:n<3600?`${Math.round(n/60)}분 후`:n<86400?`${Math.round(n/3600)}시간 후`:`${Math.round(n/86400)}일 후`}function z(e){return e==="bad"?"bad":e==="warn"||e==="pending"?"warn":"ok"}let Mr=!1,pg=0;function mg(){return++pg}let ai=null;async function _g(){ai||(ai=dg(()=>import("./mermaid.core-CDzHfthG.js").then(t=>t.bE),[]).then(t=>t.default));const e=await ai;return Mr||(e.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),Mr=!0),e}function lt(e){if(!e)return"warn";const t=e.toLowerCase();return t.includes("failed")||t.includes("error")||t.includes("disconnected")||t.includes("stopped")?"bad":t.includes("running")||t.includes("active")||t.includes("degraded")||t.includes("pending")?"warn":"ok"}function ps(e){return typeof e!="number"||!Number.isFinite(e)?"정보 없음":`${Math.round(e*100)}%`}function Sn(e){return typeof e!="number"||!Number.isFinite(e)?"정보 없음":e<60?`${Math.round(e)}초`:e<3600?`${Math.round(e/60)}분`:`${Math.round(e/3600)}시간`}function ms(e){return typeof e!="number"||!Number.isFinite(e)?0:Math.max(0,Math.min(100,e))}function yt(e,t){return typeof e!="number"||!Number.isFinite(e)||typeof t!="number"||!Number.isFinite(t)||t<=0?0:ms(e/t*100)}function vg(e,t){const n=ms(e);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${t};`}function Bc(e){if(!e)return"최근 체인 이력이 없습니다";const t=[e.event];return typeof e.duration_ms=="number"&&t.push(`${e.duration_ms}ms`),typeof e.tokens=="number"&&t.push(`토큰 ${e.tokens}`),e.message&&t.push(e.message),t.join(" · ")}const gg=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Uc=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"orchestra",label:"오케스트라",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],fg=Uc.map(e=>e.id),$g=["chain_start","node_start","node_complete","chain_complete","chain_error"],hg={warroom:{title:"실시간 워룸",description:"실제 실행, 워커, 메시지, 트레이스를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 작전, 분견대, 의존 관계를 먼저 읽는 기본 진입 표면입니다."},orchestra:{title:"룸 오케스트라 맵",description:"룸, 세션, 레인, 워커, 키퍼를 한 장의 작전판으로 읽는 시각화 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"레인 이동, 워커 결속, 막힘을 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 작전별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"실제 관리 유닛인지, 실시간 에이전트 기반 자동 투영인지 구분해서 봅니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"작전, 주체, 유닛 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"결정 승인과 유닛 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function Lr(e){return!!e&&fg.includes(e)}function yg(){const e=O.value.params;return e.source!=="mission"&&e.source!=="execution"?{}:{source:e.source,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function Ko(e){const t=yg(),n=Gc(),s=Bo();if(e==="operations")return t;if(e==="chains"){const a=Zt.value;return a?{...t,surface:e,operation:a}:{...t,surface:e}}return e==="swarm"||e==="warroom"||e==="orchestra"?{...t,surface:e,...n?{run_id:n}:{},...s?{operation_id:s}:{}}:{...t,surface:e}}function bg(){const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");return n&&t.set("agent",n),s&&t.set("token",s),t.toString()?`/api/v1/chains/events?${t.toString()}`:"/api/v1/chains/events"}function kg(e){switch(e){case"company":return"중대";case"platoon":return"소대";case"squad":return"분대";case"agent":return"에이전트";default:return e}}function le(e){return Vi.value===e}function _s(){return Ro.value}function xg(e){var a,o,l,c,p,_,u;const t=Ro.value,n=Nt.value,s=cs.value;switch(e){case"warroom":return{tool:"masc_observe_operations",reason:"실시간 실행, 워커, 메시지, 트레이스를 한 화면에서 보고 필요한 세부 표면으로 바로 이동합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=t==null?void 0:t.operations.summary)==null?void 0:a.active)??0}개와 의존 관계를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(o=t==null?void 0:t.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((p=(c=t==null?void 0:t.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:p.reason)??"레인 이동과 막힘 근거를 보고 다음 확인 도구를 고릅니다."};case"orchestra":return{tool:"masc_operator_snapshot",reason:"룸, 세션, 레인, 워커, 키퍼를 한 장에서 훑은 뒤 내려볼 대상을 고릅니다."};case"chains":return{tool:(u=(_=s==null?void 0:s.operations[0])==null?void 0:_.preview_run)!=null&&u.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"이 구조가 실제 관리 단위인지 자동 투영인지 먼저 구분해야 지휘면을 오해하지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 유닛과 작전을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"트레이스 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 제어 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function Sg(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"microarch":t.includes("leader_offline")||t.includes("roster_offline")?"alerts":t.includes("stale_data")?"swarm":null:null}function Cg(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")?"recommendation":t.includes("gap")?"gaps":null:null}function Hc(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");if(!t)return null;const n=t.trim();return n===""?null:n}function Wc(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,o)=>{e.has(o)||e.set(o,a)}),e}function Gc(){const t=Wc().get("run_id");if(!t)return null;const n=t.trim();return n===""?null:n}function Bo(){const t=Wc().get("operation_id");if(!t)return null;const n=t.trim();return n===""?null:n}function Ag(e){if(!e)return null;const t=Date.parse(e);return Number.isNaN(t)?null:Math.max(0,Math.round((Date.now()-t)/1e3))}function Ig(e){return e.status==="claimed"||e.status==="in_progress"}function Tg(e){const t=ls.value;if(!t)return null;for(const n of t.golden_paths){const s=n.steps.find(a=>a.tool===e);if(s)return s}return null}function ii(e){var t;return((t=ls.value)==null?void 0:t.golden_paths.find(n=>n.id===e))??null}function Rg(e){const t=ls.value;if(!t)return[];const n=new Set(e);return t.pitfalls.filter(s=>n.has(s.id))}async function ct(e){try{await e()}catch{}}function Uo(e){return(e==null?void 0:e.trim().toLowerCase())??""}function Bt(e){const t=Uo(e);return t.includes("failed")||t.includes("error")||t.includes("stopped")||t==="paused"?"bad":t.includes("active")||t.includes("running")||t.includes("healthy")||t.includes("ok")?"ok":"warn"}function bt(e){const t=Uo(e);return t?t==="active"||t==="running"?"진행 중":t==="paused"?"일시정지":t==="done"||t==="ended"||t==="completed"?"완료":t==="failed"||t==="error"||t==="stopped"?"문제":(e==null?void 0:e.trim())||"확인 필요":"확인 필요"}function Mg(){var n,s,a,o,l,c,p,_,u;const e=Nt.value;if(!e)return!1;const t=e.workers.some(v=>v.joined||v.live_presence||v.completed||v.current_task_matches_run||v.heartbeat_fresh||v.claim_marker_seen||v.done_marker_seen||v.final_marker_seen||!!v.current_task||!!v.bound_task_id||!!v.last_message);return!!((n=e.operation)!=null&&n.operation_id||(s=e.detachment)!=null&&s.detachment_id||(((a=e.summary)==null?void 0:a.joined_workers)??0)>0||(((o=e.summary)==null?void 0:o.live_workers)??0)>0||(((l=e.summary)==null?void 0:l.current_task_bound)??0)>0||(((c=e.summary)==null?void 0:c.fresh_heartbeats)??0)>0||(((p=e.summary)==null?void 0:p.claim_markers_seen)??0)>0||(((_=e.summary)==null?void 0:_.done_markers_seen)??0)>0||(((u=e.summary)==null?void 0:u.final_markers_seen)??0)>0||t||e.recent_messages.length>0||e.recent_trace_events.length>0)}function Lg(e){const t=Uo(e.status);return t==="active"||t==="running"}function zg(){var o,l,c,p;const e=((o=Ae.value)==null?void 0:o.sessions)??[],t=Nt.value,n=((l=t==null?void 0:t.detachment)==null?void 0:l.session_id)??null;if(n){const _=e.find(u=>u.session_id===n);if(_)return _}const s=((c=t==null?void 0:t.operation)==null?void 0:c.operation_id)??Bo();if(s){const _=e.find(u=>u.command_plane_operation_id===s);if(_)return _}const a=((p=t==null?void 0:t.detachment)==null?void 0:p.detachment_id)??null;if(a){const _=e.find(u=>u.command_plane_detachment_id===a);if(_)return _}return e.find(Lg)??e[0]??null}function oi(e){return e==="proven"?"ok":e==="partial"?"warn":"bad"}function Ut(e){return Array.isArray(e)?e:[]}function Pe(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)?e:{}}function Cs(e){return typeof e=="string"&&e.trim()!==""?e:null}function Pg(e){return typeof e=="number"&&Number.isFinite(e)?e:null}function Eg(e){const t=e.split("/");return t.length<=3?e:`…/${t.slice(-3).join("/")}`}function jg(e){return e==="proven"?"충분":e==="partial"?"부분":"부족"}function Ng(e){return e==="proven"?"협업 증거가 충분합니다":e==="partial"?"흔적은 있으나 협업 증거가 덜 모였습니다":"증거가 부족합니다"}function Dg(e,t,n,s,a,o,l){const c=[`${t}명이 실제 흔적을 남겼고, 계획된 참여자는 ${n}명입니다.`,a>0?`서로를 참조한 상호작용 증거가 ${a}건 있습니다.`:"서로를 참조한 명시적 상호작용 증거가 아직 없습니다.",o>0?`도구·산출물·체크포인트 증거가 ${o}건 있습니다.`:"도구·산출물·체크포인트 증거가 거의 없습니다.",l>0?`CPv2 backing trace가 ${l}건 있어 실행 흔적은 남아 있습니다.`:"관리형 backing trace는 아직 없습니다."];return e==="partial"?[c[0]??"",s>0?`partial인 이유: 호출되었지만 응답하지 않은 참여자가 ${s}명 있습니다.`:a===0?"partial인 이유: 여러 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.":"partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.",l>0?"다음 보강 포인트: 응답 턴이나 도구 호출을 남기면 proof가 협업 수준으로 올라갑니다.":"다음 보강 포인트: 관리형 trace 또는 산출물 연결을 더 남기면 근거가 강해집니다."]:e==="proven"?[c[0]??"","결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.","다음 행동: raw evidence는 접어두고 결과 산출물과 다음 실행 결정만 확인하면 됩니다."]:[c[0]??"",s>0?`결론: 협업 시도는 있었지만 무응답 참여자가 ${s}명 있어 협업 증거로 인정하기 어렵습니다.`:"결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.",o>0?"다음 보강 포인트: 응답 턴과 도구 근거를 서로 연결해 남겨야 합니다.":"다음 보강 포인트: 참여자 간 턴, 도구 근거, 산출물 연결을 더 남겨야 합니다."]}function zr(e){return(e==null?void 0:e.mode)==="requested_not_found"?"bad":(e==null?void 0:e.mode)==="latest_auto_selected"?"warn":"ok"}function Og(e){return(e==null?void 0:e.mode)==="requested_not_found"?"선택 실패":(e==null?void 0:e.mode)==="latest_auto_selected"?"자동 선택":(e==null?void 0:e.mode)==="explicit"?"명시 선택":"선택 없음"}function qg(e){return e.activity_state==="acted"?(e.interaction_count??0)>0||(e.tool_evidence_count??0)>0?"ok":"warn":e.activity_state==="mentioned_only"?"warn":"bad"}function Fg(e){return e.activity_state==="acted"?"실제 흔적":e.activity_state==="mentioned_only"?"호출만 됨":"계획만 됨"}function wg(e){if(e.activity_state==="acted")return`턴 ${e.turn_count??0} · spawn ${e.spawn_count??0} · 도구 근거 ${e.tool_evidence_count??0}`;if(e.activity_state==="mentioned_only"){const t=e.requested_by?`호출자 ${e.requested_by}`:"호출자 미상";return`호출 ${e.mention_count??0}회 · ${t}`}return"계획된 참여자이지만 아직 이벤트가 없습니다."}function Pr(e){return Array.isArray(e.tool_names)?e.tool_names:[]}function Kg({selection:e}){return!e||e.mode==="explicit"?null:i`
    <div class="command-guide-card ${zr(e)}">
      <div class="command-guide-head">
        <strong>${Og(e)}</strong>
        <span class="command-chip ${zr(e)}">${e.mode??"none"}</span>
      </div>
      <p>${e.reason??"근거 컨텍스트 선택 정보가 없습니다."}</p>
      <div class="command-card-grid">
        <span>선택된 세션</span><span>${e.selected_session_id??"없음"}</span>
        <span>작성자</span><span>${e.selected_created_by??"없음"}</span>
        <span>선택된 목표</span><span>${e.selected_goal??"없음"}</span>
        <span>가용 세션 수</span><span>${e.available_session_count??0}</span>
      </div>
    </div>
  `}function Bg({item:e}){return i`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${e.summary??e.event_type??"도구 근거"}</strong>
          <div class="command-meta-line">
            <span>${e.actor??"시스템"}</span>
            <span>${e.event_type??"event"}</span>
          </div>
        </div>
        <span class="command-chip">${te(e.timestamp??null)}</span>
      </div>
      ${Pr(e).length>0?i`<div class="semantic-tag-row">
            ${Pr(e).map(t=>i`<span class="semantic-tag">${t}</span>`)}
          </div>`:null}
    </article>
  `}function Ug(e){const t=new Map;for(const n of e){const s=[n.timestamp??"",n.event_type??"",n.actor??"",n.summary??""].join("|"),a=n.source??"unknown",o=t.get(s);if(o){o.sources.includes(a)||o.sources.push(a),!o.operation_id&&n.operation_id&&(o.operation_id=n.operation_id);continue}t.set(s,{...n,sources:[a]})}return[...t.values()]}function Hg(e){return e.sources.length===2?"세션 + 지휘":e.sources.length===1?e.sources[0]==="unknown"?"출처 미상":e.sources[0]??"출처":e.sources.join(" + ")}function Wg(e){const t=[];for(const[n,s]of Object.entries(e))if(s!=null){if(typeof s=="string"){if(s.trim()==="")continue;t.push({label:n,value:s});continue}if(typeof s=="number"||typeof s=="boolean"){t.push({label:n,value:String(s)});continue}}return t}function Gg(e){const t=Pe(e),n=Pe(t.traces),s=Array.isArray(n.events)?n.events:[],a=Pe(t.detachments),o=Array.isArray(a.detachments)?a.detachments:[],l=Pe(o[0]),c=Pe(l.detachment),p=Pe(l.operation),_=Pe(t.summary),u=Pe(_.operations),v=Pe(u.summary);return[{label:"작전",value:Cs(t.operation_id)??"없음"},{label:"분견대",value:Cs(t.detachment_id)??"없음"},{label:"트레이스 이벤트",value:`${s.length}`},{label:"분견대 상태",value:Cs(c.status)??"없음"},{label:"작전 단계",value:Cs(p.stage)??"없음"},{label:"활성 작전",value:`${Pg(v.active)??0}`}]}function Jg({item:e}){return i`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${e.summary??e.event_type??"이벤트"}</strong>
          <div class="command-meta-line">
            <span>${Hg(e)}</span>
            <span>${e.event_type??"이벤트"}</span>
            <span>${e.actor??"시스템"}</span>
          </div>
        </div>
        <span class="command-chip">${te(e.timestamp)}</span>
      </div>
      ${e.sources.length>1?i`<div class="semantic-tag-row">
            ${e.sources.map(t=>i`<span class="semantic-tag">${t}</span>`)}
          </div>`:null}
    </article>
  `}function Yg({item:e}){const t=e.recent_output_preview??null,n=e.recent_input_preview??null,s=e.recent_event_summary??null,a=e.recent_request_preview??null,o=e.last_active_at??e.recent_request_at??null;return i`
    <article class="mission-activity-row proof-actor-row">
      <div class="mission-activity-head">
        <div>
          <strong>${e.actor}</strong>
          <div class="mission-activity-meta">
            <span>${e.role??"참여자"}</span>
            <span>${o?te(o):"기록 없음"}</span>
          </div>
        </div>
        <span class="command-chip ${qg(e)}">
          ${Fg(e)}
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>${wg(e)}</span>
      </div>
      ${e.activity_detail?i`<div class="proof-summary-block">
            <strong>현재 해석</strong>
            <span>${e.activity_detail}</span>
          </div>`:null}
      ${s?i`<div class="proof-summary-block">
            <strong>최근 흔적</strong>
            <span>${s}</span>
          </div>`:null}
      ${a&&e.activity_state!=="acted"?i`<div class="proof-summary-block">
            <strong>최근 요청</strong>
            <span>${a}</span>
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
      ${Ut(e.recent_tool_names).length>0?i`<div class="semantic-tag-row">
            ${Ut(e.recent_tool_names).map(l=>i`<span class="semantic-tag">${l}</span>`)}
          </div>`:null}
    </article>
  `}function Vg({item:e}){return i`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${e.kind}</strong>
          <div class="command-meta-line">
            <span>${Eg(e.path)}</span>
          </div>
        </div>
        <span class="command-chip ${e.exists?"ok":"warn"}">${e.exists?"존재함":"없음"}</span>
      </div>
    </article>
  `}function Er({title:e,rows:t}){return t.length===0?null:i`
    <div class="proof-kv-block">
      ${e?i`<strong>${e}</strong>`:null}
      <div class="proof-kv-grid">
        ${t.map(n=>i`
          <span>${n.label}</span>
          <strong>${n.value}</strong>
        `)}
      </div>
    </div>
  `}function Xg(){var W,Q,ie;const e=O.value.params,t=e.session_id??null,n=e.operation_id??null;ae(()=>{rc(t,n)},[t,n]);const s=oc.value;if(Yi.value&&!s)return i`<section class="dashboard-panel"><div class="loading-indicator">근거 화면 불러오는 중…</div></section>`;if(wt.value&&!s)return i`<section class="dashboard-panel"><div class="error-card">${wt.value}</div></section>`;const a=s==null?void 0:s.summary,o=(s==null?void 0:s.selection)??null,l=Ut(s==null?void 0:s.actor_contributions),c=Ut(s==null?void 0:s.artifacts),p=Ut(s==null?void 0:s.tool_evidence),_=(s==null?void 0:s.proof_verdict)??"insufficient",u=(s==null?void 0:s.cp_backing_evidence)??null,v=Array.isArray((W=u==null?void 0:u.traces)==null?void 0:W.events)?((ie=(Q=u.traces)==null?void 0:Q.events)==null?void 0:ie.length)??0:0,g=(a==null?void 0:a.actors_count)??l.length,$=(a==null?void 0:a.planned_actor_count)??l.length,C=(a==null?void 0:a.unanswered_actor_count)??l.filter(E=>E.activity_state!=="acted"&&(E.mention_count??0)>0).length,b=(a==null?void 0:a.mentioned_actor_count)??l.filter(E=>(E.mention_count??0)>0).length,k=(a==null?void 0:a.interaction_count)??0,h=(a==null?void 0:a.evidence_count)??0,S=Ug(Ut(s==null?void 0:s.timeline)),L=Wg(Pe(s==null?void 0:s.goal_binding)),M=Gg(u),P=c.filter(E=>E.exists).length,H=c.length-P,T=Dg(_,g,$,C,k,h,v);return i`
    <section class="dashboard-panel mission-view">
      <${ke} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>근거</h2>
          <p>이 세션이 실제로 여러 참여자의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${oi(_)}">${jg(_)}</span>
          ${s!=null&&s.session_id?i`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?i`<span class="command-chip">${te(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${wt.value?i`<div class="error-card">${wt.value}</div>`:null}

      <${Kg} selection=${o} />

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${oi(_)}">
          <span>판정</span>
          <strong>${Ng(_)}</strong>
          <small>${(a==null?void 0:a.detail)??"협업 증거를 verdict로 요약합니다."}</small>
        </div>
        <div class="summary-stat-card">
          <span>실제 흔적</span>
          <strong>${g}</strong>
          <small>이벤트를 남긴 actor 수</small>
        </div>
        <div class="summary-stat-card ${$>g?"warn":"ok"}">
          <span>계획된 참여자</span>
          <strong>${$}</strong>
          <small>${b>0?`${b}명 호출됨`:"호출 기록 없음"}</small>
        </div>
        <div class="summary-stat-card ${C>0?"warn":"ok"}">
          <span>무응답</span>
          <strong>${C}</strong>
          <small>${C>0?"호출됐지만 응답 근거 없음":"무응답 참여자 없음"}</small>
        </div>
        <div class="summary-stat-card ${k>0?"ok":"warn"}">
          <span>직접 상호작용</span>
          <strong>${k}</strong>
          <small>참여자 간 직접 연결 근거</small>
        </div>
        <div class="summary-stat-card ${h>0?"ok":"warn"}">
          <span>근거</span>
          <strong>${h}</strong>
          <small>도구 / 산출물 / 체크포인트</small>
        </div>
        <div class="summary-stat-card ${v>0?"ok":"warn"}">
          <span>CP 트레이스</span>
          <strong>${v}</strong>
          <small>관리형 backing 이벤트</small>
        </div>
        <div class="summary-stat-card ${H===0&&c.length>0?"ok":"warn"}">
          <span>산출물</span>
          <strong>${P}/${c.length}</strong>
          <small>${H>0?`${H}개 누락`:"전부 존재함"}</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${R} title="3줄 근거 요약" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, 왜 아직 부족한지, 다음에 무엇을 남겨야 하는지만 먼저 봅니다.</p>
          </div>
          <div class="proof-summary-stack">
            ${T.map((E,I)=>i`
              <article class="proof-summary-block ${I===1&&_!=="proven"?oi(_):""}">
                <strong>${I===0?"지금 결론":I===1?"왜 이렇게 판정됐나":"다음 보강 포인트"}</strong>
                <span>${E}</span>
              </article>
            `)}
          </div>
        <//>

        <${R} title="목표 연결" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 화면이 어떤 세션과 목표를 기준으로 그려졌는지 먼저 고정합니다.</p>
          </div>
          <${Er} rows=${L} />
          <details class="mission-card-disclosure compact">
            <summary>원본 목표 연결 JSON</summary>
            <pre class="command-json-block">${Ia((s==null?void 0:s.goal_binding)??{})}</pre>
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
            ${S.length>0?S.slice(0,18).map(E=>i`<${Jg} key=${E.id} item=${E} />`):i`<div class="empty-state">표시할 타임라인 근거가 없습니다.</div>`}
          </div>
        <//>

        <${R} title="참여 흔적" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>실제 흔적, 호출만 된 참여자, 계획만 된 참여자를 구분해서 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${l.length>0?l.map(E=>i`<${Yg} key=${E.actor} item=${E} />`):i`<div class="empty-state">표시할 참여 흔적이 없습니다.</div>`}
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
            ${p.length>0?p.map((E,I)=>i`<${Bg} key=${`${E.actor??"system"}-${I}`} item=${E} />`):i`<div class="empty-state">기록된 tool evidence가 없습니다.</div>`}
          </div>
        <//>

        <${R} title="실행 근거" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>작전, 분견대, 트레이스 수만 먼저 보고, 원본 CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${Er} rows=${M} />
          <details class="mission-card-disclosure compact">
            <summary>원본 CPv2 backing JSON</summary>
            <pre class="command-json-block">${Ia(u??{})}</pre>
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
            ${c.length>0?c.map(E=>i`<${Vg} key=${E.path} item=${E} />`):i`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function Qg(){const e=ds(O.value);return e?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${e.source_label}</strong>
        <span class="command-chip">${Ja(e.action_type)}</span>
        <span class="command-chip">${Oo(e)}</span>
        <span class="command-chip">${_v(O.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${e.summary}</div>
      ${e.payload_preview?i`<div class="command-focus-preview">${e.payload_preview}</div>`:null}
    </section>
  `:null}function Zg(){const e=Y.value,t=hg[e],n=xg(e);return i`
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
  `}function As({label:e,value:t,subtext:n,percent:s,color:a}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${vg(s,a)}>
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
  `}function Is({label:e,value:t,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${z(a)}">
      <div class="command-signal-copy">
        <span>${e}</span>
        <strong>${t}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${z(a)}" style=${`width: ${Math.max(8,Math.round(ms(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function ef(){var Q,ie,E,I;const e=_s(),t=e==null?void 0:e.topology.summary,n=e==null?void 0:e.operations.summary,s=e==null?void 0:e.detachments.summary,a=e==null?void 0:e.decisions.summary,o=e==null?void 0:e.alerts.summary,l=(Q=e==null?void 0:e.swarm_status)==null?void 0:Q.overview,c=e==null?void 0:e.swarm_proof,p=e==null?void 0:e.operations.microarch,_=(t==null?void 0:t.managed_unit_count)??0,u=(t==null?void 0:t.total_units)??0,v=(n==null?void 0:n.active)??0,g=(s==null?void 0:s.active)??0,$=(l==null?void 0:l.moving_lanes)??0,C=(l==null?void 0:l.active_lanes)??0,b=(c==null?void 0:c.workers.done)??0,k=(c==null?void 0:c.workers.expected)??0,h=(o==null?void 0:o.bad)??0,S=(o==null?void 0:o.warn)??0,L=(a==null?void 0:a.pending)??0,M=(a==null?void 0:a.total)??0,P=v+g,H=((ie=p==null?void 0:p.cache)==null?void 0:ie.l1_hit_rate)??((I=(E=p==null?void 0:p.signals)==null?void 0:E.cache_contention)==null?void 0:I.l1_hit_rate)??0,T=v>0||g>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",W=v>0||$>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${T}</h3>
        <p>${W}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${z(v>0?"ok":"warn")}">활성 작전 ${v}</span>
          <span class="command-chip ${z($>0?"ok":(C>0,"warn"))}">이동 레인 ${$}/${Math.max(C,$)}</span>
          <span class="command-chip ${z(h>0?"bad":S>0?"warn":"ok")}">치명 알림 ${h}</span>
          <span class="command-chip ${z(L>0?"warn":"ok")}">승인 대기 ${L}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${As}
          label="관리 단위 범위"
          value=${`${_}/${Math.max(u,_)}`}
          subtext=${u>0?`${u-_}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${yt(_,Math.max(u,_))}
          color="#67e8f9"
        />
        <${As}
          label="실행 열도"
          value=${String(P)}
          subtext=${`${v}개 작전 + ${g}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${yt(P,Math.max(_,P||1))}
          color="#4ade80"
        />
        <${As}
          label="스웜 이동감"
          value=${`${$}/${Math.max(C,$)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${te(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${yt($,Math.max(C,$||1))}
          color="#fbbf24"
        />
        <${As}
          label="증거 수집률"
          value=${`${b}/${Math.max(k,b)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${yt(b,Math.max(k,b||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${Is}
        label="승인 대기열"
        value=${`${L}건 대기`}
        detail=${`현재 정책 창에서 ${M}개 결정을 추적 중입니다`}
        percent=${yt(L,Math.max(M,L||1))}
        tone=${L>0?"warn":"ok"}
      />
      <${Is}
        label="알림 압력"
        value=${`치명 ${h} / 주의 ${S}`}
        detail=${h>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${yt(h*2+S,Math.max((h+S)*2,1))}
        tone=${h>0?"bad":S>0?"warn":"ok"}
      />
      <${Is}
        label="디스패치 점유"
          value=${`${g}개 가동`}
        detail=${_>0?`${_}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${yt(g,Math.max(_,g||1))}
        tone=${g>0?"ok":"warn"}
      />
      <${Is}
        label="캐시 신뢰도"
        value=${H?ps(H):"정보 없음"}
        detail=${H?"microarch 캐시 텔레메트리에서 집계한 L1 적중률":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${ms((H??0)*100)}
        tone=${H>=.75?"ok":H>=.4?"warn":"bad"}
      />
    </div>
  `}function tf(){var g,$,C,b,k;const e=_s(),t=cs.value,n=ds(O.value),s=Sg(n),a=e==null?void 0:e.topology.summary,o=e==null?void 0:e.operations.summary,l=(g=e==null?void 0:e.swarm_status)==null?void 0:g.overview,c=e==null?void 0:e.operations.microarch,p=e==null?void 0:e.decisions.summary,_=e==null?void 0:e.alerts.summary,u=($=c==null?void 0:c.signals)==null?void 0:$.issue_pressure,v=c==null?void 0:c.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((C=e==null?void 0:e.detachments.summary)==null?void 0:C.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(p==null?void 0:p.pending)??0}</strong><small>${(p==null?void 0:p.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(_==null?void 0:_.bad)??0}</strong><small>${(_==null?void 0:_.warn)??0}건 주의</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((b=t==null?void 0:t.summary)==null?void 0:b.active_chains)??0}</strong><small>${((k=t==null?void 0:t.summary)==null?void 0:k.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${te(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(u==null?void 0:u.pending_ops)??0}</strong><small>${(v==null?void 0:v.l1_hit_rate)!=null?`${ps(v.l1_hit_rate)} L1 적중`:"캐시 데이터 없음"} · ${(u==null?void 0:u.tone)??"정보 없음"}</small></div>
    </div>
  `}function nf(){var Q,ie,E,I,A,Z,se,G,Ke;const e=_s(),t=we.value,n=ge.value,s=Hc(),a=s?Ve.value.find(B=>B.name===s)??null:null,o=s?st.value.filter(B=>B.assignee===s&&Ig(B)):[],l=((Q=e==null?void 0:e.operations.summary)==null?void 0:Q.active)??0,c=((ie=e==null?void 0:e.detachments.summary)==null?void 0:ie.total)??0,p=((E=e==null?void 0:e.decisions.summary)==null?void 0:E.pending)??0,_=t==null?void 0:t.detachments.detachments.find(B=>{const Le=B.detachment.heartbeat_deadline,ft=Le?Date.parse(Le):Number.NaN;return B.detachment.status==="stalled"||!Number.isNaN(ft)&&ft<=Date.now()}),u=t==null?void 0:t.alerts.alerts.find(B=>B.severity==="bad"),v=!!(n!=null&&n.room||n!=null&&n.project),g=(a==null?void 0:a.current_task)??null,$=Ag(a==null?void 0:a.last_seen),C=$!=null?$<=120:null,b=[v?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:st.value.length>0?"masc_claim":"masc_add_task"}:g?C===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${g} 이지만 heartbeat가 stale 합니다 (${$}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${g}${$!=null?` · 마지막 활동 ${$}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!e||(((I=e.topology.summary)==null?void 0:I.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((A=e.topology.summary)==null?void 0:A.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Z=e.topology.summary)==null?void 0:Z.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},p>0?{title:"디스패치 준비도",tone:"warn",detail:`${p}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:_||u?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${_?` · detachment ${_.detachment.detachment_id} 가 stalled 상태입니다`:""}${u?` · alert ${u.title??u.alert_id}`:""}${!t&&!_&&!u?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${t?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],k=v?!s||!a?"masc_join":o.length===0?st.value.length>0?"masc_claim":"masc_add_task":g?C===!1?"masc_heartbeat":!e||(((se=e.topology.summary)==null?void 0:se.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":p>0?"masc_policy_approve":l>0&&c===0||_||u?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",h=Tg(k),L=Rg(k==="masc_set_room"?["repo-root-room"]:k==="masc_plan_set_task"?["claimed-not-current"]:k==="masc_heartbeat"?["heartbeat-stale"]:k==="masc_dispatch_tick"?["no-detachments"]:k==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),M=ii("room_task_hygiene"),P=ii("cpv2_benchmark"),H=ii("supervisor_session"),T=((G=ls.value)==null?void 0:G.docs)??[],W=[M,P,H].filter(B=>B!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${F} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(h==null?void 0:h.title)??k}</strong>
            <span class="command-chip ok">${k}</span>
          </div>
          <p>${(h==null?void 0:h.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(Ke=h==null?void 0:h.success_signals)!=null&&Ke.length?i`<div class="command-tag-row">
                ${h.success_signals.map(B=>i`<span class="command-tag ok">${B}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${b.map(B=>i`
            <article class="command-readiness-row ${z(B.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${B.title}</strong>
                  <span class="command-chip ${z(B.tone)}">${B.tone}</span>
                </div>
                <p>${B.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${B.tool}</div>
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
                  ${L.map(B=>i`
                    <article class="command-guide-inline">
                      <strong>${B.title}</strong>
                      <div>${B.symptom}</div>
                      <div class="command-card-sub">${B.fix_tool} 로 해결: ${B.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `:null}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">운영 경로</div>
          <${F} panelId="command.summary" compact=${!0} />
        </div>
        ${Xi.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:fa.value?i`<div class="empty-state error">${fa.value}</div>`:i`
                <div class="command-path-grid">
                  ${W.map(B=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${B.title}</strong>
                        <span class="command-chip">${B.id}</span>
                      </div>
                      <p>${B.summary}</p>
                      <div class="command-card-sub">${B.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${B.steps.slice(0,4).map(Le=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Le.tool}</span>
                            <span>${Le.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${T.length>0?i`<div class="command-doc-links">
                      ${T.map(B=>i`<span class="command-tag">${B.title}: ${B.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function sf(){return i`
    <${ef} />
    <${tf} />
    <${nf} />
  `}function af(){return ma.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:va.value?i`<div class="empty-state error">${va.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}const kt=f(null),Ts=f("compact"),Qe=f({zoom:1,panX:0,panY:0}),ri=f(!1),Rs=f(!1),Cn={width:1280,height:760},Jc=.42,Yc=1.9;function Vs(e,t,n){return Math.max(t,Math.min(n,e))}function Ho(e,t){const n=e==null?void 0:e.trim();return n?n.length<=t?n:`${n.slice(0,Math.max(1,t-1))}…`:null}function of(e){return e==="compact"?"집약":"균형"}function jr(e){switch((e??"").trim().toLowerCase()){case"room":return"룸";case"session":return"세션";case"operation":return"작전";case"detachment":return"분견대";case"lane":return"레인";case"worker":return"워커";case"keeper":return"키퍼";default:return(e==null?void 0:e.trim())||"노드"}}function Ms(e,t,n){if(e<=0)return[];if(e===1)return[Math.round((t+n)/2)];const s=(n-t)/(e-1);return Array.from({length:e},(a,o)=>Math.round(t+o*s))}function rf(e,t){const n=new Map;for(const s of e){const a=t(s),o=n.get(a)??[];o.push(s),n.set(a,o)}return n}function Vc(e){return e==="compact"?{room:{x:660,y:108},sessions:{y:228,min:220,max:1110},operations:{y:338,min:260,max:1050},detachments:{y:430,min:310,max:1e3},lanes:{y:540,min:220,max:1110},worker:{perRow:5,xSpacing:60,ySpacing:52,laneOffsetY:76,freeBaseY:662},keeper:{startX:1180,colSpacing:92,rowSpacing:90,startY:176,columns:2},signalRadius:116}:{room:{x:700,y:112},sessions:{y:236,min:240,max:1140},operations:{y:356,min:300,max:1080},detachments:{y:454,min:340,max:1030},lanes:{y:584,min:230,max:1110},worker:{perRow:4,xSpacing:72,ySpacing:60,laneOffsetY:82,freeBaseY:720},keeper:{startX:1210,colSpacing:108,rowSpacing:102,startY:188,columns:2},signalRadius:132}}function Xc(e,t){return e.kind==="room"?t==="compact"?{width:138,height:138,radius:68}:{width:156,height:156,radius:76}:e.kind==="worker"?t==="compact"?{width:70,height:36,radius:18}:{width:84,height:44,radius:22}:e.kind==="lane"?t==="compact"?{width:156,height:48,radius:15}:{width:176,height:56,radius:17}:e.kind==="keeper"?t==="compact"?{width:118,height:50,radius:22}:{width:132,height:60,radius:24}:e.kind==="session"?t==="compact"?{width:182,height:58,radius:17}:{width:202,height:68,radius:18}:t==="compact"?{width:176,height:58,radius:16}:{width:196,height:68,radius:18}}function lf(e,t){const n=e.kind==="worker"?t==="compact"?10:14:e.kind==="keeper"?t==="compact"?12:16:e.kind==="lane"?t==="compact"?16:22:t==="compact"?18:26;return Ho(e.label,n)??e.label}function cf(e,t){if(t==="compact"&&(e.kind==="worker"||e.kind==="keeper"||e.kind==="detachment"))return null;const n=e.kind==="session"?t==="compact"?20:28:t==="compact"?14:24;return Ho(e.subtitle,n)}function df(e,t){return t==="compact"&&e.kind!=="session"&&e.kind!=="operation"?null:Ho(e.status,t==="compact"?10:14)}function uf(e,t){const n=Vc(t),s=new Map,a=e.nodes,o=a.find(b=>b.kind==="room")??null,l=a.filter(b=>b.kind==="session"),c=a.filter(b=>b.kind==="operation"),p=a.filter(b=>b.kind==="detachment"),_=a.filter(b=>b.kind==="lane"),u=a.filter(b=>b.kind==="worker"),v=a.filter(b=>b.kind==="keeper");o&&s.set(o.id,{x:n.room.x,y:n.room.y}),Ms(l.length,n.sessions.min,n.sessions.max).forEach((b,k)=>{const h=l[k];h&&s.set(h.id,{x:b,y:n.sessions.y})}),Ms(c.length,n.operations.min,n.operations.max).forEach((b,k)=>{const h=c[k];h&&s.set(h.id,{x:b,y:n.operations.y})}),Ms(p.length,n.detachments.min,n.detachments.max).forEach((b,k)=>{const h=p[k];h&&s.set(h.id,{x:b,y:n.detachments.y})}),Ms(_.length,n.lanes.min,n.lanes.max).forEach((b,k)=>{const h=_[k];h&&s.set(h.id,{x:b,y:n.lanes.y})});const g=new Map(_.map(b=>{const k=s.get(b.id);return k?[b.id,k.x]:null}).filter(b=>b!==null)),$=rf(u,b=>b.lane_id?`lane:${b.lane_id}`:b.parent_id?b.parent_id:"free");let C=0;for(const[b,k]of $){let h=g.get(b.replace(/^lane:/,""));if(h==null){const L=s.get(b);h=L==null?void 0:L.x}h==null&&(h=260+C%4*180,C+=1);const S=Math.max(1,Math.ceil(k.length/n.worker.perRow));for(let L=0;L<S;L+=1){const M=k.slice(L*n.worker.perRow,(L+1)*n.worker.perRow),P=(M.length-1)*n.worker.xSpacing,H=h-P/2;M.forEach((T,W)=>{var Q;s.set(T.id,{x:Math.round(H+W*n.worker.xSpacing),y:b==="free"?n.worker.freeBaseY+L*n.worker.ySpacing:(((Q=s.get(b.replace(/^lane:/,"")))==null?void 0:Q.y)??n.lanes.y)+n.worker.laneOffsetY+L*n.worker.ySpacing})})}}return v.forEach((b,k)=>{const h=k%n.keeper.columns,S=Math.floor(k/n.keeper.columns);s.set(b.id,{x:n.keeper.startX+h*n.keeper.colSpacing,y:n.keeper.startY+S*n.keeper.rowSpacing})}),s}function pf(e,t,n){if(!t||e.signals.length===0)return[];const s=Vc(n);return e.signals.slice(0,6).map((a,o)=>{const l=(-130+o*36)*(Math.PI/180);return{signalNode:a,x:Math.round(t.x+Math.cos(l)*s.signalRadius),y:Math.round(t.y+Math.sin(l)*s.signalRadius)}})}function mf(e,t,n,s){let a=Number.POSITIVE_INFINITY,o=Number.NEGATIVE_INFINITY,l=Number.POSITIVE_INFINITY,c=Number.NEGATIVE_INFINITY;for(const p of e.nodes){const _=t.get(p.id);if(!_)continue;const u=Xc(p,s);p.kind==="room"?(a=Math.min(a,_.x-u.radius),o=Math.max(o,_.x+u.radius),l=Math.min(l,_.y-u.radius),c=Math.max(c,_.y+u.radius)):(a=Math.min(a,_.x-u.width/2),o=Math.max(o,_.x+u.width/2),l=Math.min(l,_.y-u.height/2),c=Math.max(c,_.y+u.height/2))}for(const p of n)a=Math.min(a,p.x-20),o=Math.max(o,p.x+20),l=Math.min(l,p.y-20),c=Math.max(c,p.y+20);return!Number.isFinite(a)||!Number.isFinite(o)||!Number.isFinite(l)||!Number.isFinite(c)?{minX:0,minY:0,maxX:Cn.width,maxY:Cn.height,width:Cn.width,height:Cn.height}:{minX:a,minY:l,maxX:o,maxY:c,width:Math.max(1,o-a),height:Math.max(1,c-l)}}function Nr(e,t,n){const s=n==="compact"?48:72,a=Math.max(360,t.width-s*2),o=Math.max(280,t.height-s*2),l=Vs(Math.min(a/Math.max(e.width,1),o/Math.max(e.height,1)),Jc,Yc),c=e.minX+e.width/2,p=e.minY+e.height/2;return{zoom:l,panX:t.width/2-c*l,panY:t.height/2-p*l}}function _f(e,t){const n=(e.x+t.x)/2,s=t.y>=e.y?32:-32;return`M ${e.x} ${e.y} C ${n} ${e.y+s}, ${n} ${t.y-s}, ${t.x} ${t.y}`}function Dr(e,t,n){if(e==="command"){if(t){rt(t),oe("command",{...Ko(t),...n});return}oe("command",n);return}if(e==="intervene"){oe("intervene",n);return}oe("command",n)}function vf({signalNodes:e,roomPoint:t,onSelect:n}){return!t||e.length===0?null:i`
    ${e.map(({signalNode:s,x:a,y:o})=>i`
      <g
        key=${s.id}
        data-orchestra-signal="true"
        class=${`orchestra-signal-node ${z(s.tone)}`}
        onClick=${()=>n(s.id)}
      >
        <title>${s.label}${s.detail?` — ${s.detail}`:""}</title>
        <line x1=${t.x} y1=${t.y} x2=${a} y2=${o} class="orchestra-signal-link" />
        <circle cx=${a} cy=${o} r="16" class="orchestra-signal-dot" />
        <text x=${a} y=${o+4} text-anchor="middle" class="orchestra-signal-glyph">!</text>
      </g>
    `)}
  `}function gf({edges:e,positions:t,selectedId:n}){return i`
    ${e.map(s=>{const a=t.get(s.source),o=t.get(s.target);if(!a||!o)return null;const l=n!=null&&(s.source===n||s.target===n);return i`
        <path
          key=${s.id}
          d=${_f(a,o)}
          class=${`orchestra-edge ${z(s.tone)} ${s.animated?"animated":""} ${l?"active":""}`}
        />
      `})}
  `}function ff({orchestra:e,positions:t,density:n,selectedId:s,onSelect:a}){var l;const o=((l=e.focus)==null?void 0:l.target_kind)==="node"?e.focus.target_id:null;return i`
    ${e.nodes.map(c=>{const p=t.get(c.id);if(!p)return null;const _=Xc(c,n),u=c.id===s,v=c.id===o,g=c.visual_class??c.kind,$=lf(c,n),C=cf(c,n),b=df(c,n);if(c.kind==="room")return i`
          <g
            key=${c.id}
            data-orchestra-node="true"
            class=${`orchestra-node room ${z(c.tone)} ${u?"selected":""} ${v?"focused":""}`}
            onClick=${()=>a(c.id)}
          >
            <title>${c.label}</title>
            <circle cx=${p.x} cy=${p.y} r=${_.radius} class="orchestra-room-ring outer" />
            <circle cx=${p.x} cy=${p.y} r=${_.radius-16} class="orchestra-room-ring inner" />
            <text x=${p.x} y=${p.y-10} text-anchor="middle" class="orchestra-room-glyph">${c.glyph??"◎"}</text>
            <text x=${p.x} y=${p.y+22} text-anchor="middle" class="orchestra-room-label">${$}</text>
          </g>
        `;const k=p.x-_.width/2,h=p.y-_.height/2;return i`
        <g
          key=${c.id}
          data-orchestra-node="true"
          class=${`orchestra-node ${g} ${z(c.tone)} ${u?"selected":""} ${v?"focused":""}`}
          onClick=${()=>a(c.id)}
        >
          <title>${c.label}${c.subtitle?` — ${c.subtitle}`:""}${c.status?` (${c.status})`:""}</title>
          <rect x=${k} y=${h} width=${_.width} height=${_.height} rx=${_.radius} class="orchestra-node-body" />
          <text x=${k+16} y=${h+24} class="orchestra-node-glyph">${c.glyph??"•"}</text>
          <text x=${k+38} y=${h+24} class="orchestra-node-label">${$}</text>
          ${C?i`<text x=${k+38} y=${h+42} class="orchestra-node-subtitle">${C}</text>`:null}
          ${b?i`<text x=${k+_.width-10} y=${h+18} text-anchor="end" class="orchestra-node-status">${b}</text>`:null}
        </g>
      `})}
  `}function Qc(e){var s,a;const t=kt.value;if(t){const o=e.nodes.find(c=>c.id===t);if(o)return{type:"node",value:o};const l=e.signals.find(c=>c.id===t);if(l)return{type:"signal",value:l}}if(((s=e.focus)==null?void 0:s.target_kind)==="node"){const o=e.nodes.find(l=>{var c;return l.id===((c=e.focus)==null?void 0:c.target_id)});if(o)return{type:"node",value:o}}if(((a=e.focus)==null?void 0:a.target_kind)==="signal"){const o=e.signals.find(l=>{var c;return l.id===((c=e.focus)==null?void 0:c.target_id)});if(o)return{type:"signal",value:o}}const n=e.nodes[0];return n?{type:"node",value:n}:null}function $f({orchestra:e}){const t=Qc(e);if(!t)return i`<aside class="orchestra-drawer card"><div class="empty-state">선택 가능한 대상이 아직 없습니다.</div></aside>`;if(t.type==="signal"){const o=t.value;return i`
      <aside class="orchestra-drawer card ${z(o.tone)}">
        <div class="card-title-row">
          <div class="card-title">${o.label}</div>
          <span class="command-chip ${z(o.tone)}">${jr(o.kind)}</span>
        </div>
        <p>${o.detail??"세부 설명이 없습니다."}</p>
        ${o.suggested_surface?i`
              <div class="command-action-row">
                <button
                  class="control-btn"
                  onClick=${()=>Dr("command",o.suggested_surface,o.suggested_params??{})}
                >
                  추천 화면 열기
                </button>
              </div>
            `:null}
      </aside>
    `}const n=t.value,s=e.signals.filter(o=>o.source_id===n.id||o.target_id===n.id),a=e.edges.filter(o=>o.source===n.id||o.target===n.id);return i`
    <aside class="orchestra-drawer card ${z(n.tone)}">
      <div class="card-title-row">
        <div class="card-title">${n.label}</div>
        <span class="command-chip ${z(n.tone)}">${jr(n.kind)}</span>
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
          ${s.map(o=>i`<span class="command-chip ${z(o.tone)}">${o.label}</span>`)}
        </div>
      `:null}
      <div class="command-card-sub">연결 ${a.length}개 · 근거 ${n.provenance}</div>
      ${n.link_tab&&(n.link_surface||Object.keys(n.link_params??{}).length>0)?i`
            <div class="command-action-row">
              <button
                class="control-btn"
                onClick=${()=>Dr(n.link_tab??"command",n.link_surface,n.link_params??{})}
              >
                이 화면 열기
              </button>
            </div>
          `:null}
    </aside>
  `}function hf(){var W,Q,ie,E;const e=Mo.value,t=Ks(null),n=Ks(null),s=Ks(""),[a,o]=vo(Cn);if(ae(()=>{const I=t.current;if(!I)return;const A=()=>{const se=I.getBoundingClientRect();se.width<=0||se.height<=0||o({width:Math.max(640,Math.round(se.width)),height:Math.max(480,Math.round(se.height))})};if(A(),typeof ResizeObserver>"u")return window.addEventListener("resize",A),()=>window.removeEventListener("resize",A);const Z=new ResizeObserver(()=>A());return Z.observe(I),()=>Z.disconnect()},[]),Qi.value&&!e)return i`<section class="card command-section"><div class="empty-state">오케스트라 맵 불러오는 중…</div></section>`;if(ya.value)return i`<section class="card command-section"><div class="empty-state error">${ya.value}</div></section>`;if(!e)return i`<section class="card command-section"><div class="empty-state">오케스트라 맵 데이터가 아직 없습니다.</div></section>`;const l=Ts.value,c=uf(e,l),p=e.nodes.find(I=>I.kind==="room")??null,_=p?c.get(p.id)??null:null,u=pf(e,_,l),v=mf(e,c,u,l),g=Qc(e),$=(g==null?void 0:g.value.id)??null,C=`${l}:${a.width}x${a.height}:${e.nodes.length}:${e.edges.length}:${e.signals.length}`,b=(I,A)=>{Qe.value=I,Rs.value=A},k=()=>{b(Nr(v,a,l),!1)},h=()=>{if(kt.value=null,l!=="compact"){Ts.value="compact",Rs.value=!1;return}k()};ae(()=>{$&&!e.nodes.some(I=>I.id===$)&&!e.signals.some(I=>I.id===$)&&(kt.value=null)},[C,$,e]),ae(()=>{(!Rs.value||s.current!==C)&&(b(Nr(v,a,l),!1),s.current=C)},[C]);const S=Qe.value,L=(I,A,Z)=>{const se=Qe.value.zoom,G=Vs(se*Z,Jc,Yc);if(Math.abs(G-se)<.001)return;const Ke=(I-Qe.value.panX)/se,B=(A-Qe.value.panY)/se;b({zoom:G,panX:I-Ke*G,panY:A-B*G},!0)},M=I=>{I.preventDefault();const A=t.current;if(!A)return;const Z=A.getBoundingClientRect(),se=Vs(I.clientX-Z.left,0,Z.width),G=Vs(I.clientY-Z.top,0,Z.height);L(se,G,I.deltaY<0?1.1:.92)},P=I=>{var se;const A=I.target;if(!(A instanceof Element)||!A.closest('[data-orchestra-background="true"]'))return;const Z=I.currentTarget;Z&&(n.current={pointerId:I.pointerId,startX:I.clientX,startY:I.clientY,panX:Qe.value.panX,panY:Qe.value.panY},ri.value=!0,Rs.value=!0,(se=Z.setPointerCapture)==null||se.call(Z,I.pointerId))},H=I=>{const A=n.current;!A||A.pointerId!==I.pointerId||b({zoom:Qe.value.zoom,panX:A.panX+(I.clientX-A.startX),panY:A.panY+(I.clientY-A.startY)},!0)},T=I=>{var Z;if(!n.current)return;const A=I==null?void 0:I.currentTarget;A&&I&&((Z=A.releasePointerCapture)==null||Z.call(A,I.pointerId)),n.current=null,ri.value=!1};return i`
    <section class="card command-section orchestra-surface">
      <div class="card-title-row">
        <div class="card-title">오케스트라 맵</div>
        <${F} panelId="command.orchestra" compact=${!0} />
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
            onClick=${()=>L(a.width/2,a.height/2,1.12)}
          >
            확대
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>L(a.width/2,a.height/2,.9)}
          >
            축소
          </button>
          <span class="command-chip">${Math.round(S.zoom*100)}%</span>
        </div>
        <div class="orchestra-toolbar-group">
          <button
            class=${`control-btn ${l==="balanced"?"is-active":"ghost"}`}
            onClick=${()=>{Ts.value="balanced",kt.value=$}}
          >
            균형
          </button>
          <button
            class=${`control-btn ${l==="compact"?"is-active":"ghost"}`}
            onClick=${()=>{Ts.value="compact",kt.value=$}}
          >
            집약
          </button>
          <span class="command-chip">${of(l)}</span>
        </div>
      </div>

      <div class="orchestra-shell">
        <div
          ref=${t}
          class="orchestra-canvas-wrap"
          onWheel=${M}
          onPointerDown=${P}
          onPointerMove=${H}
          onPointerUp=${T}
          onPointerCancel=${T}
          onPointerLeave=${()=>T()}
        >
          <svg
            class=${`orchestra-canvas ${ri.value?"is-dragging":""}`}
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
            <g transform=${`translate(${S.panX} ${S.panY}) scale(${S.zoom})`}>
              <${gf} edges=${e.edges} positions=${c} selectedId=${$} />
              <${vf} signalNodes=${u} roomPoint=${_} onSelect=${I=>{kt.value=I}} />
              <${ff}
                orchestra=${e}
                positions=${c}
                density=${l}
                selectedId=${$}
                onSelect=${I=>{kt.value=I}}
              />
            </g>
          </svg>
          <div class="orchestra-summary-strip">
            <span class="command-chip">세션 ${((W=e.summary)==null?void 0:W.session_count)??0}</span>
            <span class="command-chip">워커 ${((Q=e.summary)==null?void 0:Q.worker_count)??0}</span>
            <span class="command-chip">키퍼 ${((ie=e.summary)==null?void 0:ie.keeper_count)??0}</span>
            <span class="command-chip ${z(e.signals.some(I=>I.tone==="bad")?"bad":e.signals.length>0?"warn":"ok")}">
              신호 ${((E=e.summary)==null?void 0:E.signal_count)??e.signals.length}
            </span>
            <span class="command-chip">갱신 ${te(e.generated_at)}</span>
          </div>
        </div>

        <${$f} orchestra=${e} />
      </div>
    </section>
  `}const Zc="masc_dashboard_agent_name";function yf(){var t,n,s;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Zc))==null?void 0:s.trim())||"dashboard"}const Va=f(yf()),nn=f(""),Ta=f("운영 점검"),sn=f(""),Wn=f(""),Gn=f("2"),cn=f(""),ye=f("note"),Jn=f(""),Yn=f(""),Vn=f(""),Xn=f("2"),Qn=f(""),Ra=f("운영자 중지 요청"),Ma=f(""),an=f(""),Ls=f(null);function bf(e){const t=e.trim()||"dashboard";Va.value=t,localStorage.setItem(Zc,t)}function La(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Wo(e){switch((e??"").trim().toLowerCase()){case"judgment":return"상주 판단";case"fallback":return"보조 읽기 모델";default:return(e==null?void 0:e.trim())||"안내"}}function za(e){switch((e??"").trim().toLowerCase()){case"judgment":return"ok";case"fallback":return"warn";default:return"warn"}}function Go(e){return e!=null&&e.enabled?e.refreshing?"갱신 중":e.judge_online?"온라인":e.last_error?"오류":"대기":"꺼짐"}function kf(e){return e!=null&&e.enabled?e.judge_online?"ok":e.refreshing?"warn":"bad":"warn"}function Jo(e){return e!=null&&e.fresh_until?e.fresh_until:"갱신 기준 없음"}function Or(e){return typeof e!="number"||!Number.isFinite(e)?"확인 없음":e<60?`${Math.round(e)}초 전`:e<3600?`${Math.round(e/60)}분 전`:`${Math.round(e/3600)}시간 전`}function dn(e){return typeof e=="string"?e.trim().toLowerCase():""}function xf(e){var s;const t=dn(e.status);if(t==="paused")return"bad";if(t===""||t==="unknown")return"warn";const n=dn((s=e.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||t&&t!=="active"&&t!=="running"&&t!=="ended"?"warn":"ok"}function li(e){const t=dn(e.status);return t==="offline"||t==="inactive"||t==="error"?"bad":t===""||t==="unknown"||(e.context_ratio??0)>=.8||e.context_ratio==null||e.last_turn_ago_s==null||(e.last_turn_ago_s??0)>=3600?"warn":"ok"}function qr(e){return e.some(t=>dn(t.severity)==="bad")?"bad":e.length>0?"warn":"ok"}function Sf(e){return e.target_type==="team_session"}function Cf(e){return e.target_type==="keeper"}function zt(e){switch(e){case"broadcast":return"방송";case"room_pause":return"방 일시정지";case"room_resume":return"방 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"team_worker_spawn_batch":return"세션 작업자 교체";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"키퍼 메시지";case"keeper_msg":return"키퍼 메시지";case"swarm_run_continue":return"스웜 실행 계속";case"swarm_run_rerun":return"스웜 실행 재실행";case"swarm_run_abandon":return"스웜 실행 포기";default:return(e==null?void 0:e.trim())||"액션"}}function on(e){switch(e){case"room":return"방";case"team_session":return"세션";case"keeper":return"키퍼";case"swarm_run":return"스웜 실행";default:return(e==null?void 0:e.trim())||"대상"}}function Ht(e){switch(dn(e)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function Pa(e){return e?"확인 후 실행":"즉시 실행"}function Af(e){switch(e){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"worker_spawn_batch":return"작업자 교체";default:return e}}function _e(e,t){if(!e)return null;const n=e[t];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function If(e){return!e||typeof e!="object"||Array.isArray(e)?null:e}function Tf(e){if(!e)return"";const t=e.spawn_batch;return La(t!==void 0?t:e)}function ed(e){const t=If(e.payload);if(e.target_type==="room"){if(e.action_type==="broadcast"){nn.value=_e(t,"message")??e.summary;return}if(e.action_type==="task_inject"){sn.value=_e(t,"title")??"운영자 주입 작업",Wn.value=_e(t,"description")??e.summary,Gn.value=_e(t,"priority")??Gn.value;return}e.action_type==="room_pause"&&(Ta.value=_e(t,"reason")??e.summary);return}if(e.target_type==="team_session"){if(e.target_id&&(cn.value=e.target_id),e.action_type==="team_stop"){Ra.value=_e(t,"reason")??e.summary;return}ye.value=e.action_type==="team_worker_spawn_batch"?"worker_spawn_batch":e.action_type==="team_task_inject"?"task":e.action_type==="team_broadcast"?"broadcast":"note";const n=_e(t,"message");if(n&&(Jn.value=n),ye.value==="worker_spawn_batch"){Qn.value=Tf(t);return}ye.value==="task"&&(Yn.value=_e(t,"task_title")??_e(t,"title")??"운영자 주입 작업",Vn.value=_e(t,"task_description")??_e(t,"description")??e.summary,Xn.value=_e(t,"task_priority")??_e(t,"priority")??Xn.value);return}e.target_type==="keeper"&&(e.target_id&&(Ma.value=e.target_id),an.value=_e(t,"message")??e.summary)}function Rf(e){ed({action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.suggested_payload,summary:e.summary})}function Mf(e){ed({action_type:e.action_type,target_type:e.target_type,target_id:e.target_id??null,payload:e.suggested_payload,summary:e.reason}),N("추천 액션 payload를 폼에 채웠습니다","success")}function Lf(e,t,n){return!e||!e.target_type||e.target_type==="room"?!0:e.target_type==="team_session"?!!e.target_id&&t.some(s=>s.session_id===e.target_id):e.target_type==="keeper"?!!e.target_id&&n.some(s=>s.name===e.target_id):!0}async function pt(e){const t=Va.value.trim()||"dashboard";try{const n=await Xl({actor:t,action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.payload});return n.confirm_required?N("확인 대기열에 올렸습니다","warning"):N(e.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return N(s,"error"),null}}async function Fr(){const e=nn.value.trim();if(!e)return;await pt({action_type:"broadcast",target_type:"room",payload:{message:e},successMessage:"방송을 보냈습니다"})&&(nn.value="")}async function zf(){await pt({action_type:"room_pause",target_type:"room",payload:{reason:Ta.value.trim()||"운영 점검"},successMessage:"방 일시정지를 요청했습니다"})}async function td(){await pt({action_type:"room_resume",target_type:"room",payload:{},successMessage:"방 재개를 요청했습니다"})}async function Pf(){const e=sn.value.trim();if(!e)return;await pt({action_type:"task_inject",target_type:"room",payload:{title:e,description:Wn.value.trim()||"개입 화면에서 주입",priority:Number.parseInt(Gn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(sn.value="",Wn.value="")}async function Ef(){var l;const e=Ae.value,t=cn.value||((l=e==null?void 0:e.sessions[0])==null?void 0:l.session_id)||"";if(!t){N("먼저 세션을 고르세요","warning");return}const n={};if(ye.value==="worker_spawn_batch"){const c=Qn.value.trim();if(!c){N("spawn_batch JSON을 먼저 채우세요","warning");return}try{const _=JSON.parse(c);if(Array.isArray(_))n.spawn_batch=_;else if(_&&typeof _=="object"&&Array.isArray(_.spawn_batch))n.spawn_batch=_.spawn_batch;else{N("spawn_batch는 배열 또는 { spawn_batch: [...] } 형태여야 합니다","warning");return}}catch(_){const u=_ instanceof Error?_.message:"spawn_batch JSON 파싱에 실패했습니다";N(u,"error");return}await pt({action_type:"team_worker_spawn_batch",target_type:"team_session",target_id:t,payload:n,successMessage:"작업자 교체 요청을 적용했습니다"})&&(Qn.value="");return}const s=Jn.value.trim();s&&(n.message=s);let a="team_note";ye.value==="broadcast"?a="team_broadcast":ye.value==="task"&&(a="team_task_inject"),ye.value==="task"&&(n.task_title=Yn.value.trim()||"운영자 주입 작업",n.task_description=Vn.value.trim()||"개입 화면에서 주입",n.task_priority=Number.parseInt(Xn.value,10)||2),await pt({action_type:a,target_type:"team_session",target_id:t,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Jn.value="",ye.value==="task"&&(Yn.value="",Vn.value=""))}async function jf(){var n;const e=Ae.value,t=cn.value||((n=e==null?void 0:e.sessions[0])==null?void 0:n.session_id)||"";if(!t){N("먼저 세션을 고르세요","warning");return}await pt({action_type:"team_stop",target_type:"team_session",target_id:t,payload:{reason:Ra.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Nf(){var a;const e=Ae.value,t=Ma.value||((a=e==null?void 0:e.keepers[0])==null?void 0:a.name)||"",n=an.value.trim();if(!t){N("먼저 키퍼를 고르세요","warning");return}if(!n)return;await pt({action_type:"keeper_message",target_type:"keeper",target_id:t,payload:{message:n},successMessage:`${t}에게 메시지를 보냈습니다`})&&(an.value="")}async function wr(e,t="confirm"){const n=Va.value.trim()||"dashboard";try{await Ql(n,e,t),N(t==="deny"?"승인 대기를 거부했습니다":"확인 실행을 완료했습니다","success")}catch(s){const a=s instanceof Error?s.message:t==="deny"?"승인 대기 거부에 실패했습니다":"확인 실행에 실패했습니다";N(a,"error")}}function nd(e){switch(e){case"explicit":return"실제 관리 단위";case"hybrid":return"관리 단위 + 자동 보강";case"auto":return"자동 투영";default:return"출처 미상"}}function sd(e){switch(e){case"explicit":return"ok";case"hybrid":return"warn";case"auto":return"warn";default:return"warn"}}function Df(e){switch(e){case"explicit":return"지금 보이는 유닛은 실제로 정의된 지휘면 관리 단위입니다.";case"hybrid":return"일부는 실제 관리 단위이고, 비어 있는 부분은 실시간 에이전트 편성을 보고 자동 보강한 구조입니다.";case"auto":return"이 화면은 실시간 에이전트 편성을 지휘면 모양으로 자동 투영한 것입니다. 실제 명령 체계와 1:1로 같다고 보면 안 됩니다.";default:return"이 화면은 관리 토폴로지와 실효 토폴로지가 섞여 있을 수 있습니다."}}function Of(e){const t=e.unit.source??"unknown";return t==="explicit"?e.active_operation_count&&e.active_operation_count>0?"실제 관리 단위이며 연결된 작전이 있습니다.":"실제 관리 단위이지만 현재 연결된 작전은 없습니다.":t==="hybrid"?e.active_operation_count&&e.active_operation_count>0?"관리 단위를 기반으로 자동 보강된 구조이며 일부 작전이 연결돼 있습니다.":"관리 단위를 기반으로 자동 보강된 구조이며 현재 실행 연결은 약합니다.":e.active_operation_count&&e.active_operation_count>0?"자동 생성된 구조이지만 이 노드에 연결된 작전 흔적은 있습니다.":"자동 생성된 구조이며 현재 실행 연결은 없습니다."}function ad({node:e,depth:t=0}){const n=e.roster_live??0,s=e.roster_total??e.unit.roster.length,a=e.active_operation_count??0,o=e.unit.policy,l=e.unit.source??"unknown",c=a>0?`${a}개 작전 연결`:"실행 연결 없음";return i`
    <div class="command-tree-node depth-${Math.min(t,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${e.unit.label}</strong>
            <span class="command-chip">${kg(e.unit.kind)}</span>
            <span class="command-chip ${z(e.health)}">${e.health??"ok"}</span>
            <span class="command-chip ${sd(l)}">${nd(l)}</span>
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
            ${e.children.map(p=>i`<${ad} node=${p} depth=${t+1} />`)}
          </div>`:null}
    </div>
  `}function qf({alert:e}){return i`
    <article class="command-alert ${z(e.severity)}">
      <div class="command-card-head">
        <strong>${e.title??e.kind??e.alert_id}</strong>
        <span class="command-chip ${z(e.severity)}">${e.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${e.scope_type??"범위"}:${e.scope_id??"정보 없음"}</span>
        <span>${te(e.timestamp)}</span>
      </div>
      ${e.detail?i`<p>${e.detail}</p>`:null}
    </article>
  `}function Yo({event:e}){return i`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${e.event_type}</strong>
          <span class="command-chip">${e.source??"control_plane"}</span>
          <span class="command-chip">${te(e.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${e.operation_id??e.trace_id}
          ${e.unit_id?` · ${e.unit_id}`:""}
          ${e.actor?` · ${e.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${Ia(e.detail)}</pre>
    </article>
  `}function Ff(){const e=we.value,t=e==null?void 0:e.topology,n=t==null?void 0:t.source,s=t==null?void 0:t.summary,a=(s==null?void 0:s.managed_unit_count)??0,o=(s==null?void 0:s.active_operation_count)??0;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${F} panelId="command.topology" compact=${!0} />
      </div>
      ${e?i`
            <div class="command-topology-explainer">
              <div class="command-tree-title-row">
                <span class="command-chip ${sd(n)}">${nd(n)}</span>
                <span class="command-chip">관리 유닛 ${a}</span>
                <span class="command-chip ${o>0?"ok":"warn"}">활성 작전 ${o}</span>
              </div>
              <p>${Df(n)}</p>
            </div>
          `:null}
      ${e&&e.topology.units.length>0?i`${e.topology.units.map(l=>i`<${ad} node=${l} />`)}`:i`<div class="empty-state">지금은 실시간 에이전트나 관리 유닛 기준으로 그릴 지휘 계층이 없습니다.</div>`}
    </section>
  `}function wf(){const e=we.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${F} panelId="command.alerts" compact=${!0} />
      </div>
      ${e&&e.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${e.alerts.alerts.map(t=>i`<${qf} alert=${t} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 지휘면 경보는 없습니다.</div>`}
    </section>
  `}function Kf(){const e=we.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${F} panelId="command.trace" compact=${!0} />
      </div>
      ${e&&e.traces.events.length>0?i`<div class="command-trace-stack">
            ${e.traces.events.map(t=>i`<${Yo} event=${t} />`)}
          </div>`:i`<div class="empty-state">최근 트레이스 이벤트가 없습니다.</div>`}
    </section>
  `}function Bf(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Uf(e,t){return(t==null?void 0:t.status)==="abandoned"||(e==null?void 0:e.recommended_kind)==="continue"?"warn":(e==null?void 0:e.recommended_kind)==="rerun"?"bad":"ok"}function Hf(e){switch(e){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(e==null?void 0:e.trim())||"결정"}}function Wf(e){return e?e.runtime_blocker?"막힘":e.provider_reachable?"준비됨":"확인 필요":"확인 필요"}function id({swarm:e}){var v,g;const t=e.run_id,n=e.resolution_recommendation,s=e.run_resolution;if(!t||!n&&!s)return null;const a=Hc()??"dashboard",o=((v=Ae.value)==null?void 0:v.pending_confirms.find($=>$.target_type==="swarm_run"&&$.target_id===t))??null,l=Uf(n,s),c=((g=e.operation)==null?void 0:g.operation_id)??e.operation_id??void 0,p={run_id:t};c&&(p.operation_id=c),n!=null&&n.reason&&(p.reason=n.reason);const _=async $=>{await Xl({actor:a,action_type:$,target_type:"swarm_run",target_id:t,payload:p})},u=async $=>{o&&await Ql(a,o.confirm_token,$)};return i`
    <article class="command-guide-card ${z(l)}">
      <div class="command-guide-head">
        <strong>런 해석</strong>
        <span class="command-chip ${z(l)}">
          ${Hf((s==null?void 0:s.status)??(n==null?void 0:n.recommended_kind)??null)}
        </span>
      </div>
      <p>
        ${(s==null?void 0:s.status)==="abandoned"?`이 run은 ${s.decided_by}가 ${te(s.decided_at)}에 soft abandon 처리했습니다. ${s.reason}`:(n==null?void 0:n.reason)??"이 run에 대한 별도 resolution recommendation은 아직 없습니다."}
      </p>
      <div class="command-card-grid">
        <span>런</span><span>${t}</span>
        <span>근거 경로</span><span>${(n==null?void 0:n.provenance)??"recorded"}</span>
        <span>결정 엔진</span><span>${(n==null?void 0:n.decision_engine)??"operator_record"}</span>
        <span>권위성</span><span>${n!=null&&n.authoritative?"예":"아니오"}</span>
      </div>
      ${n!=null&&n.evidence?i`
            <div class="command-tag-row">
              <span class="command-tag">joined ${n.evidence.joined_workers??0}</span>
              <span class="command-tag">trace ${n.evidence.trace_events??0}</span>
              <span class="command-tag">message ${n.evidence.message_events??0}</span>
              ${n.evidence.runtime_blocker?i`<span class="command-tag ${z("bad")}">${n.evidence.runtime_blocker}</span>`:null}
            </div>
          `:null}
      ${o?i`
            <div class="command-guide-card warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip warn">${o.confirm_token}</span>
              </div>
              ${o.preview?i`<pre class="command-trace-detail">${Bf(o.preview)}</pre>`:null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${()=>{u("confirm")}} disabled=${J.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${()=>{u("deny")}} disabled=${J.value}>취소</button>
              </div>
            </div>
          `:n?i`
              <div class="command-action-row">
                ${n.continue_available?i`<button class="control-btn ghost" onClick=${()=>{_("swarm_run_continue")}} disabled=${J.value}>계속</button>`:null}
                ${n.rerun_available?i`<button class="control-btn" onClick=${()=>{_("swarm_run_rerun")}} disabled=${J.value}>재실행</button>`:null}
                ${n.abandon_available?i`<button class="control-btn ghost" onClick=${()=>{_("swarm_run_abandon")}} disabled=${J.value}>포기</button>`:null}
              </div>
            `:null}
    </article>
  `}function od(e){return e.motion_state==="stalled"||e.hard_flags.some(t=>t.severity==="bad")?"bad":e.motion_state==="waiting"||e.hard_flags.some(t=>t.severity==="warn")?"warn":"ok"}function rd({lanes:e}){const t={moving:0,waiting:0,stalled:0,terminal:0};for(const a of e){const o=a.motion_state;o in t?t[o]++:t.waiting++}if(e.length===0)return null;const s=[{key:"moving",count:t.moving,color:"var(--ok)"},{key:"waiting",count:t.waiting,color:"var(--warn)"},{key:"stalled",count:t.stalled,color:"var(--bad)"},{key:"terminal",count:t.terminal,color:"#556"}];return i`
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
  `}function Jf({lane:e}){const t=e.counts??{},n=od(e),s=t.workers??0,a=t.operations??0,o=t.detachments??0,l=a+o,c=e.motion_state==="moving"?84:e.motion_state==="waiting"?58:e.motion_state==="terminal"?100:26;return i`
    <article class="swarm-lane-strip ${z(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${e.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${e.kind} · ${e.source_of_truth}</span>
            <strong>${e.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${z(n)}">${e.phase}</span>
          <span class="command-chip ${z(n)}">${e.motion_state}</span>
          <span class="command-chip">${te(e.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${e.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${z(n)}" style=${`width:${c}%`}></span>
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
              ${e.hard_flags.map(p=>i`<span class="command-chip ${z(p.severity)}">${p.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function ld({lanes:e}){const t=e.slice(0,4);return t.length===0?null:i`
    <div class="swarm-storyboard">
      ${t.map(n=>{const s=od(n),a=n.counts.workers??0,o=n.counts.operations??0,l=n.counts.detachments??0;return i`
          <article class="swarm-story-card ${z(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${z(s)}">${n.motion_state}</span>
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
  `}function Yf({event:e}){const t=e.timestamp?new Date(e.timestamp):null,n=t&&!isNaN(t.getTime())?t:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${z(e.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${e.title}</strong>
        <span class="swarm-event-kind">${e.kind}</span>
        ${e.detail?i`<div class="command-card-sub">${e.detail}</div>`:null}
      </div>
    </div>
  `}function Vf({gap:e}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.summary}</strong>
          <div class="command-card-sub">${e.code} · lane ${e.lane_ids.join(", ")||"n/a"}</div>
        </div>
        <span class="command-chip ${z(e.severity)}">${e.count}</span>
      </div>
      ${e.why_it_matters?i`<p>${e.why_it_matters}</p>`:null}
      ${e.next_tool||e.next_step?i`
            <div class="command-card-grid">
              <span>다음 도구</span><span>${e.next_tool??"masc_observe_traces"}</span>
              <span>다음 확인</span><span>${e.next_step??"최근 trace를 확인합니다."}</span>
            </div>
          `:null}
    </article>
  `}function Xf({swarm:e}){const t=e==null?void 0:e.narrative;return t?i`
    <div class="command-guide-card highlight">
      <div class="command-guide-head">
        <strong>읽는 순서</strong>
        <span class="command-chip">${t.state??"idle"}</span>
      </div>
      <div class="proof-summary-stack">
        <article class="proof-summary-block">
          <strong>무엇으로 시작됐나</strong>
          <span>${t.started??"시작 근거가 없습니다."}</span>
        </article>
        <article class="proof-summary-block">
          <strong>지금 무엇을 하고 있나</strong>
          <span>${t.active_work??"현재 작업 설명이 없습니다."}</span>
        </article>
        <article class="proof-summary-block">
          <strong>끝났는가</strong>
          <span>${t.completion??"종료 근거가 없습니다."}</span>
        </article>
      </div>
    </div>
  `:null}function Qf({proof:e}){const t=(e==null?void 0:e.status)==="missing"?"warn":(e==null?void 0:e.pass)===!1?"bad":(e==null?void 0:e.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${z(t)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${z(t)}">${(e==null?void 0:e.status)??"missing"}</span>
        </div>
      ${e?i`
            <p>${e.status_summary??e.missing_reason??"아직 스웜 증거가 수집되지 않았습니다."}</p>
            <div class="command-card-grid">
              <span>소스</span><span>${e.source}</span>
              <span>상태 코드</span><span>${e.reason_code??"n/a"}</span>
              <span>런</span><span>${e.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${te(e.captured_at)}</span>
              <span>통과</span><span>${e.pass==null?"n/a":e.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${e.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${e.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${e.workers.expected??"n/a"} 예상 · ${e.workers.done??"n/a"} 완료 · ${e.workers.final??"n/a"} 최종</span>
            </div>
            ${e.expected_artifact_dir?i`<div class="command-card-foot">expected ${e.expected_artifact_dir}</div>`:null}
            ${e.artifact_ref?i`<div class="command-card-foot">${e.artifact_ref}</div>`:null}
            ${e.missing_reason?i`<p>${e.missing_reason}</p>`:null}
          `:i`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function Zf(){const e=_s(),t=ds(O.value),n=Cg(t),s=e==null?void 0:e.swarm_status,a=e==null?void 0:e.swarm_proof,o=(s==null?void 0:s.lanes.filter(v=>v.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],p=s==null?void 0:s.overview,_=s==null?void 0:s.recommended_next_action,u=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${F} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${ld} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(p==null?void 0:p.active_lanes)??0}</strong><small>${(p==null?void 0:p.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(p==null?void 0:p.stalled_lanes)??0}</strong><small>${(p==null?void 0:p.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${te(p==null?void 0:p.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${te(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(_==null?void 0:_.label)??"운영자 상태 확인"}</strong><small>${(_==null?void 0:_.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${rd} lanes=${o} />`:null}

            <div class="command-swarm-layout ${u?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(v=>i`<${Jf} lane=${v} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <${Xf} swarm=${s} />

                <div class="command-guide-card highlight ${n==="recommendation"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>${(_==null?void 0:_.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(_==null?void 0:_.lane_id)??"전체"}</span>
                  </div>
                  <p>${(_==null?void 0:_.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(_==null?void 0:_.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${Qf} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${z(l.some(v=>v.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?i`<div class="command-card-stack">${l.slice(0,4).map(v=>i`<${Vf} gap=${v} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?i`<div class="swarm-event-rail">${c.map(v=>i`<${Yf} event=${v} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function e$({item:e}){return i`
    <article class="command-guide-card ${z(e.status)}">
      <div class="command-guide-head">
        <strong>${e.title}</strong>
        <span class="command-chip ${z(e.status)}">${e.status}</span>
      </div>
      <p>${e.detail}</p>
      <div class="command-card-foot">Next tool: ${e.next_tool}</div>
    </article>
  `}function cd({blocker:e}){return i`
    <article class="command-alert ${z(e.severity)}">
      <div class="command-card-head">
        <strong>${e.title}</strong>
        <span class="command-chip ${z(e.severity)}">${e.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${e.code}</span>
        <span>next ${e.next_tool}</span>
      </div>
      <p>${e.detail}</p>
    </article>
  `}function t$({worker:e}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.name}</strong>
          <div class="command-card-sub">${e.role} · ${e.lane}</div>
        </div>
        <span class="command-chip ${z(e.joined?e.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${e.last_message?i`<div class="command-card-foot">${te(e.last_message.timestamp)} · ${e.last_message.content}</div>`:null}
    </article>
  `}function n$(){var u,v,g,$,C,b,k,h,S,L,M,P,H,T,W,Q,ie,E,I,A,Z,se;const e=Nt.value,t=Gc(),n=Bo(),s=Wf(e==null?void 0:e.provider),a=((u=e==null?void 0:e.provider)==null?void 0:u.configured_capacity)??0,o=((v=e==null?void 0:e.provider)==null?void 0:v.actual_slots)??((g=e==null?void 0:e.provider)==null?void 0:g.total_slots)??0,l=(($=e==null?void 0:e.provider)==null?void 0:$.expected_slots)??"n/a",c=((C=e==null?void 0:e.provider)==null?void 0:C.actual_ctx)??((b=e==null?void 0:e.provider)==null?void 0:b.ctx_per_slot)??0,p=((k=e==null?void 0:e.provider)==null?void 0:k.expected_ctx)??"n/a",_=((h=e==null?void 0:e.summary)==null?void 0:h.peak_hot_slots)??((S=e==null?void 0:e.provider)==null?void 0:S.peak_active_slots)??0;return i`
    <div class="command-section-stack">
      <${Zf} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${F} panelId="command.swarm" compact=${!0} />
          </div>
          ${$a.value?i`<div class="empty-state">Loading swarm live state…</div>`:ha.value?i`<div class="empty-state error">${ha.value}</div>`:e?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${e.run_id??t??"swarm-live"}</strong><small>${e.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((L=e.summary)==null?void 0:L.joined_workers)??0}/${((M=e.summary)==null?void 0:M.expected_workers)??0}</strong><small>${((P=e.summary)==null?void 0:P.live_workers)??0}개 가동 · ${((H=e.summary)==null?void 0:H.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임 계약</span><strong>${s}</strong><small>설정 ${a||"n/a"} · 실제 ${o}/${l} · ctx ${c}/${p}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(T=e.summary)!=null&&T.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>최대 hot ${_} · ${((W=e.provider)==null?void 0:W.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(Q=e.summary)!=null&&Q.pass_end_to_end?"통과":"확인 필요"}</strong><small>${e.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((ie=e.operation)==null?void 0:ie.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((E=e.squad)==null?void 0:E.label)??"없음"}</span>
                      <span>실행체</span><span>${((I=e.detachment)==null?void 0:I.detachment_id)??"없음"}</span>
                      <span>목표 해석</span><span>target profile 기준, 달성 사실과 분리</span>
                      <span>예상 워커</span><span>${((A=e.summary)==null?void 0:A.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((Z=e.summary)==null?void 0:Z.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((se=e.provider)==null?void 0:se.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${e.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${e.truth_notes.length>0?i`<div class="command-tag-row">
                          ${e.truth_notes.map(G=>i`<span class="command-tag">${G}</span>`)}
                        </div>`:null}
                    <${id} swarm=${e} />
                  `:i`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${F} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.checklist.length>0?i`<div class="command-card-stack">
                ${e.checklist.map(G=>i`<${e$} item=${G} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${F} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.workers.length>0?i`<div class="command-card-stack">
                ${e.workers.map(G=>i`<${t$} worker=${G} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${F} panelId="command.swarm" compact=${!0} />
          </div>
          ${e!=null&&e.provider?i`
                <div class="command-card-grid">
                  <span>프로바이더</span><span>${e.provider.provider_base_url??"정보 없음"}</span>
                  <span>프로바이더 응답</span><span>${e.provider.provider_reachable==null?"정보 없음":e.provider.provider_reachable?"가능":"불가"}</span>
                  <span>요청 모델</span><span>${e.provider.provider_model_id??"정보 없음"}</span>
                  <span>실제 모델</span><span>${e.provider.actual_model_id??"정보 없음"}</span>
                  <span>슬롯 URL</span><span>${e.provider.slot_url??"정보 없음"}</span>
                  <span>설정 용량</span><span>${e.provider.configured_capacity??"정보 없음"}</span>
                  <span>요구 슬롯</span><span>${e.provider.expected_slots??"정보 없음"}</span>
                  <span>실제 슬롯</span><span>${e.provider.actual_slots??e.provider.total_slots??0}</span>
                  <span>요구 컨텍스트</span><span>${e.provider.expected_ctx??"정보 없음"}</span>
                  <span>실제 컨텍스트</span><span>${e.provider.actual_ctx??e.provider.ctx_per_slot??0}</span>
                  <span>현재 hot</span><span>${e.provider.active_slots_now??0}</span>
                  <span>최대 hot</span><span>${e.provider.peak_active_slots??0}</span>
                  <span>샘플 수</span><span>${e.provider.sample_count??0}</span>
                  <span>마지막 샘플</span><span>${e.provider.last_sample_at?te(e.provider.last_sample_at):"정보 없음"}</span>
                  <span>런타임 막힘</span><span>${e.provider.runtime_blocker??"없음"}</span>
                  <span>검사 시각</span><span>${e.provider.checked_at?te(e.provider.checked_at):"정보 없음"}</span>
                </div>
                <div class="command-card-sub">
                  target profile과 실제 런타임은 다를 수 있습니다. 설정 용량, 실제 슬롯, 최대 hot 슬롯을 분리해서 읽으세요.
                </div>
                ${e.provider.detail?i`<div class="command-card-sub">${e.provider.detail}</div>`:null}
                ${e.provider.timeline.length>0?i`<div class="command-trace-stack">
                      ${e.provider.timeline.slice(-12).map(G=>i`
                          <article class="command-trace-row">
                            <div class="command-trace-main">
                              <div class="command-trace-head">
                                <strong>hot ${G.active_slots}</strong>
                                <span class="command-chip">${te(G.timestamp)}</span>
                              </div>
                            <div class="command-card-sub">slot ids ${G.active_slot_ids.join(", ")||"없음"}</div>
                            </div>
                          </article>
                      `)}
                    </div>`:i`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:i`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${F} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.blockers.length>0?i`<div class="command-card-stack">
                ${e.blockers.map(G=>i`<${cd} blocker=${G} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(e==null?void 0:e.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${F} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.recent_messages.length>0?i`<div class="command-trace-stack">
                ${e.recent_messages.map(G=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${G.from}</strong>
                        <span class="command-chip">${te(G.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${G.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${G.content}</pre>
                  </article>
                `)}
              </div>`:i`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${F} panelId="command.trace" compact=${!0} />
          </div>
          ${e&&e.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${e.recent_trace_events.map(G=>i`<${Yo} event=${G} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function s$(e){return e==="swarm"?"스웜 실시간":"세션 요약"}function a$(e){switch(e){case"current":return"현재 과업 일치";case"drift":return"과업 드리프트";case"claim":return"착수 흔적 있음";case"no-claim":return"착수 흔적 없음";case"done":return"완료 흔적 있음";case"no-done":return"완료 흔적 없음";case"final":return"최종 보고 있음";case"no-final":return"최종 보고 없음";case"turn":return"턴 기록 있음";case"silent":return"턴 기록 없음";case"noted":return"노트 기록 있음";default:return e.startsWith("empty:")?`빈 노트 ${e.slice(6)}회`:e.startsWith("turns:")?`턴 ${e.slice(6)}회`:e}}function i$(e){var n;const t=[e.current_task_matches_run?"current":"drift",e.claim_marker_seen?"claim":"no-claim",e.done_marker_seen?"done":"no-done",e.final_marker_seen?"final":"no-final"];return{key:`swarm:${e.name}`,name:e.name,role:e.role,lane:e.lane,status:e.status,source:"swarm",task:e.current_task??e.bound_task_title??e.bound_task_id??"할당 없음",heartbeat:e.heartbeat_age_sec!=null?`${Math.round(e.heartbeat_age_sec)}초`:e.heartbeat_fresh?"정상":"정보 없음",detail:[e.bound_task_status??null,e.detachment_member?"분견대 소속":null,e.squad_member?"분대 소속":null].filter(Boolean).join(" · ")||"스웜 실시간 카드",markers:t,note:((n=e.last_message)==null?void 0:n.content)??null}}function o$(e,t){const n=e.actor??e.spawn_role??`워커-${t+1}`,s=e.spawn_role??e.worker_class??e.spawn_agent??"워커",a=e.lane_id??e.capsule_mode??e.control_domain??"세션",o=[e.has_turn?"turn":"silent",e.empty_note_turn_count>0?`empty:${e.empty_note_turn_count}`:"noted",e.turn_count>0?`turns:${e.turn_count}`:"turns:0"];return{key:`session:${n}:${t}`,name:n,role:s,lane:a,status:e.status,source:"session",task:e.task_profile??e.runtime_pool??"세션 레인",heartbeat:e.last_turn_ts_iso?te(e.last_turn_ts_iso):"정보 없음",detail:[e.spawn_agent??null,e.spawn_model??null,e.routing_confidence!=null?ps(e.routing_confidence):null].filter(Boolean).join(" · ")||"세션 요약 카드",markers:o,note:e.routing_reason??null}}function Kr(e){return z(e.severity)}function r$({worker:e}){return i`
    <article class="command-card compact warroom-worker-card ${z(Bt(e.status))}">
      <div class="command-card-head">
        <div>
          <strong>${e.name}</strong>
          <div class="command-card-sub">${e.role} · ${e.lane}</div>
        </div>
        <span class="command-chip ${z(Bt(e.status))}">${bt(e.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>출처</span><span>${s$(e.source)}</span>
        <span>과업</span><span>${e.task}</span>
        <span>최근 신호</span><span>${e.heartbeat}</span>
        <span>근거</span><span>${e.detail}</span>
      </div>
      <div class="command-tag-row">
        ${e.markers.map(t=>i`<span class="command-tag">${a$(t)}</span>`)}
      </div>
      ${e.note?i`<div class="command-card-foot">${e.note}</div>`:null}
    </article>
  `}function Ze({label:e,surface:t,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(t){rt(t),oe("command",{...Ko(t),...n});return}oe("intervene")}}
    >
      ${e}
    </button>
  `}function l$(){var I,A,Z,se,G,Ke,B,Le,ft,gn,fn,vs,gs,fs,$s,hs,ys,bs,nr,sr,ar;const e=_s(),t=Nt.value,n=Ae.value,s=qe.value,a=zg(),o=t!=null&&t.operation?((I=cs.value)==null?void 0:I.operations.find(ee=>{var ks;return ee.operation.operation_id===((ks=t.operation)==null?void 0:ks.operation_id)}))??null:null,l=Mg(),c=(t==null?void 0:t.workers)??[],p=(s==null?void 0:s.worker_cards)??[],_=l&&c.length>0?c.map(i$):p.map(o$),u=l,v=((A=e==null?void 0:e.decisions.summary)==null?void 0:A.pending)??0,g=(n==null?void 0:n.pending_confirms)??[],$=l?(t==null?void 0:t.blockers)??[]:[],C=(s==null?void 0:s.recommended_actions)??[],b=(Z=s==null?void 0:s.active_recommended_actions)!=null&&Z.length?s.active_recommended_actions:C,k=s==null?void 0:s.active_summary,h=(s==null?void 0:s.active_guidance_layer)??"fallback",S=(s==null?void 0:s.resident_judge_runtime)??(n==null?void 0:n.resident_judge_runtime),L=(s==null?void 0:s.attention_items)??[],M=((se=t==null?void 0:t.recent_messages[0])==null?void 0:se.timestamp)??null,P=((G=t==null?void 0:t.recent_trace_events[0])==null?void 0:G.timestamp)??null,H=l?M??P??null:null,T=a==null?void 0:a.summary,W=(l?(Ke=t==null?void 0:t.summary)==null?void 0:Ke.expected_workers:void 0)??(typeof(T==null?void 0:T.planned_worker_count)=="number"?T.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,Q=(l?(B=t==null?void 0:t.summary)==null?void 0:B.joined_workers:void 0)??(typeof(T==null?void 0:T.active_agent_count)=="number"?T.active_agent_count:void 0)??_.length,ie=$.length>0||v>0||g.length>0?"warn":u||a?"ok":"warn",E=l?((Le=e==null?void 0:e.swarm_status)==null?void 0:Le.lanes.filter(ee=>ee.present))??[]:[];return ae(()=>{be()},[]),ae(()=>{a!=null&&a.session_id&&ln(a.session_id)},[a==null?void 0:a.session_id,n,(ft=t==null?void 0:t.detachment)==null?void 0:ft.session_id]),!u&&!a?$a.value||Fn.value?i`<div class="empty-state">실시간 워룸 불러오는 중…</div>`:i`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">실시간 워룸</div>
          <${F} panelId="command.warroom" compact=${!0} />
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
    `:i`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${z(ie)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">실시간 워룸</span>
            <strong>${l?((gn=t==null?void 0:t.operation)==null?void 0:gn.objective)??(a==null?void 0:a.session_id)??"가동 중인 실행":(a==null?void 0:a.session_id)??"가동 중인 실행"}</strong>
            <div class="command-card-sub">
              ${l?((fn=t==null?void 0:t.operation)==null?void 0:fn.operation_id)??"작전 정보 없음":"세션 기준값"}
              ${a!=null&&a.session_id?` · 세션 ${a.session_id}`:""}
              ${l&&((vs=t==null?void 0:t.detachment)!=null&&vs.detachment_id)?` · 분견대 ${t.detachment.detachment_id}`:""}
            </div>
            ${k!=null&&k.summary?i`<div class="command-warroom-guidance ${za(h)}">
                  <strong>${Wo(h)}</strong>
                  <span>${k.summary}</span>
                </div>`:null}
          </div>
          <div class="command-action-row">
            <${Ze}
              label="스웜 상세"
              surface="swarm"
              params=${{...l&&((gs=t==null?void 0:t.operation)!=null&&gs.operation_id)?{operation_id:t.operation.operation_id}:{},...l&&(t!=null&&t.run_id)?{run_id:t.run_id}:{}}}
            />
            <${Ze} label="트레이스" surface="trace" />
            ${l&&o?i`<${Ze}
                  label="체인"
                  surface="chains"
                  params=${{operation:o.operation.operation_id}}
                />`:null}
            <${Ze} label="개입" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>워커</span>
            <strong>${Q??0}/${W??0}</strong>
            <small>${l?((fs=t==null?void 0:t.summary)==null?void 0:fs.completed_workers)??0:0} 완료 · ${_.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>런타임</span>
            <strong>${l?($s=t==null?void 0:t.provider)!=null&&$s.runtime_blocker?"막힘":(hs=t==null?void 0:t.provider)!=null&&hs.provider_reachable?"준비됨":a?bt(a.status):"확인 필요":a?bt(a.status):"확인 필요"}</strong>
            <small>${l?`설정 ${((ys=t==null?void 0:t.provider)==null?void 0:ys.configured_capacity)??"n/a"} · 실제 ${((bs=t==null?void 0:t.provider)==null?void 0:bs.actual_slots)??((nr=t==null?void 0:t.provider)==null?void 0:nr.total_slots)??0} · hot ${((sr=t==null?void 0:t.summary)==null?void 0:sr.peak_hot_slots)??((ar=t==null?void 0:t.provider)==null?void 0:ar.peak_active_slots)??0}`:`세션 워커 ${(s==null?void 0:s.worker_cards.length)??0}`}</small>
          </div>
          <div class="monitor-stat-card ${z($.length>0||v>0?"warn":"ok")}">
            <span>압력</span>
            <strong>${$.length+v+g.length}</strong>
            <small>막힘 ${$.length} · 승인 ${v} · 확인 ${g.length}</small>
          </div>
          <div class="monitor-stat-card ${z(za(h))}">
            <span>상주 판정기</span>
            <strong>${Go(S)}</strong>
            <small>${Jo(k)}${S!=null&&S.model_used?` · ${S.model_used}`:""}</small>
          </div>
          <div class="monitor-stat-card">
            <span>마지막 신호</span>
            <strong>${te(H)}</strong>
            <small>${M?"메시지":P?"트레이스":"대기 중"}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${F} panelId="command.warroom" compact=${!0} />
            </div>
            ${E.length>0?i`
                  <${ld} lanes=${E} />
                  <${rd} lanes=${E} />
                `:a?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${z(Bt(a.status))}">${bt(a.status)}</span>
                      </div>
                      <p>스웜 실시간 증거는 아직 약합니다. 이 카드는 세션 요약과 워커 기록을 기준으로 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${Sn(a.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${Sn(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 레인이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">워커 현황</div>
              <${F} panelId="command.warroom" compact=${!0} />
            </div>
            ${_.length>0?i`<div class="command-card-stack">
                  ${_.map(ee=>i`<${r$} worker=${ee} />`)}
                </div>`:i`<div class="empty-state">활성 워커 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">상황 피드</div>
              <${F} panelId="command.warroom" compact=${!0} />
            </div>
            ${t&&t.recent_messages.length>0&&l?i`<div class="command-trace-stack">
                  ${t.recent_messages.map(ee=>i`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${ee.from}</strong>
                          <span class="command-chip">${te(ee.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${ee.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${ee.content}</pre>
                    </article>
                  `)}
                </div>`:b.length>0||L.length>0?i`<div class="command-card-stack">
                    ${b.slice(0,4).map(ee=>i`
                      <article class="command-guide-card ${Kr(ee)}">
                        <div class="command-guide-head">
                          <strong>${ee.action_type}</strong>
                          <span class="command-chip ${Kr(ee)}">${ee.target_type}</span>
                        </div>
                        <p>${ee.reason}</p>
                      </article>
                    `)}
                    ${L.slice(0,3).map(ee=>i`
                      <article class="command-alert ${z(ee.severity)}">
                        <div class="command-card-head">
                          <strong>${ee.kind}</strong>
                          <span class="command-chip ${z(ee.severity)}">${ee.severity}</span>
                        </div>
                        <p>${ee.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?i`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((ee,ks)=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>세션 이벤트 ${ks+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${Ia(ee)}</pre>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">메시지나 주의 항목이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">트레이스 흐름</div>
              <${F} panelId="command.trace" compact=${!0} />
            </div>
            ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                  ${t.recent_trace_events.map(ee=>i`<${Yo} event=${ee} />`)}
                </div>`:i`<div class="empty-state">실행 범위 트레이스 이벤트가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">압력</div>
              <${F} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&t?i`<${id} swarm=${t} />`:null}
              ${$.length>0?$.map(ee=>i`<${cd} blocker=${ee} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${v>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>승인 대기</strong>
                        <span class="command-chip warn">${v}</span>
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
                        ${g.slice(0,3).map(ee=>i`<span class="command-tag">${ee.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
            </div>
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">현재 초점</div>
              <${F} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&(t!=null&&t.operation)?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${t.operation.objective}</strong>
                          <div class="command-card-sub">${t.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${z(Bt(t.operation.status))}">${bt(t.operation.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>유닛</span><span>${t.operation.assigned_unit_id}</span>
                        <span>트레이스</span><span>${t.operation.trace_id}</span>
                        <span>자율성</span><span>${t.operation.autonomy_level??"정보 없음"}</span>
                        <span>최근 갱신</span><span>${te(t.operation.updated_at)}</span>
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
                        <span class="command-chip ${z(Bt(t.detachment.status))}">${bt(t.detachment.status??"active")}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>리더</span><span>${t.detachment.leader_id??"미지정"}</span>
                        <span>편성</span><span>${t.detachment.roster.length}</span>
                        <span>세션</span><span>${t.detachment.session_id??"연결 없음"}</span>
                        <span>하트비트</span><span>${Kc(t.detachment.heartbeat_deadline)}</span>
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
                        <span class="command-chip ${z(Bt(a.status))}">${bt(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>진행률</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"정보 없음"}</span>
                        <span>경과</span><span>${Sn(a.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${Sn(a.remaining_sec)}</span>
                        <span>완료 변화량</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function Br(e){switch((e??"").trim().toLowerCase()){case"active":return"가동 중";case"paused":return"일시정지";case"failed":return"실패";case"completed":case"done":return"완료";case"disconnected":return"끊김";case"preview":return"미리보기";case"captured":return"기록됨";default:return(e==null?void 0:e.trim())||"확인 필요"}}function c$({source:e}){const t=Ks(null),[n,s]=vo(null);return ae(()=>{let a=!1;const o=t.current;return o?(o.innerHTML="",s(null),(async()=>{try{const c=await _g(),{svg:p}=await c.render(`command-chain-${mg()}`,e);if(a||!t.current)return;t.current.innerHTML=p}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid 렌더링에 실패했습니다")}})(),()=>{a=!0,t.current&&(t.current.innerHTML="")}):void 0},[e]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${t}></div>
    </div>
  `}function d$({overlay:e,selected:t,onSelect:n}){const s=e.operation.chain,a=e.runtime;return i`
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
        ${s!=null&&s.chain_id?i`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?i`<span class="command-tag ${lt(s==null?void 0:s.status)}">${ps(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${Bc(e.history)}</div>
    </button>
  `}function u$({item:e}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${e.chain_id??"알 수 없는 체인"}</strong>
        <span class="command-chip ${lt(e.event)}">${e.event}</span>
      </div>
      <div class="command-card-sub">${te(e.timestamp)}</div>
      <div class="command-card-sub">${Bc(e)}</div>
    </article>
  `}function p$({node:e}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${e.id}</strong>
        <span class="command-chip ${lt(e.status)}">${e.status??"확인 필요"}</span>
      </div>
      <div class="command-card-sub">
        ${e.type??"노드"}
        ${typeof e.duration_ms=="number"?` · ${e.duration_ms}ms`:""}
      </div>
      ${e.error?i`<div class="command-card-sub error-text">${e.error}</div>`:null}
    </article>
  `}function m$({card:e}){const t=e.operation,n=`pause:${t.operation_id}`,s=`resume:${t.operation_id}`,a=`recall:${t.operation_id}`,o=t.chain,l=(o==null?void 0:o.run_id)??null;return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${t.objective}</strong>
          <div class="command-card-sub">${t.operation_id}</div>
        </div>
        <span class="command-chip ${z(t.status==="active"?"ok":t.status==="paused"?"warn":t.status==="failed"?"bad":"ok")}">${Br(t.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${e.assigned_unit_label??t.assigned_unit_id}</span>
        <span>트레이스</span><span class="mono">${t.trace_id}</span>
        <span>자율성</span><span>${t.autonomy_level??"정보 없음"}</span>
        <span>예산 등급</span><span>${t.budget_class??"standard"}</span>
        <span>출처</span><span>${t.source??"managed"}</span>
        <span>최근 갱신</span><span>${te(t.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${lt(o.status)}">${Br(o.status)}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">실행 ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${t.checkpoint_ref?i`<div class="command-card-foot">체크포인트 ${t.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{rt("swarm"),oe("command",{surface:"swarm",operation_id:t.operation_id,...l?{run_id:l}:{}})}}
        >
          스웜 실시간 보기
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{Eo(t.operation_id),rt("chains"),oe("command",{surface:"chains",operation:t.operation_id})}}
              >
                체인 열기
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="active"?i`
              <button class="control-btn ghost" disabled=${le(n)} onClick=${()=>ct(()=>G_(t.operation_id))}>
                ${le(n)?"일시정지 중…":"일시정지"}
              </button>
              <button class="control-btn ghost" disabled=${le(a)} onClick=${()=>ct(()=>Y_(t.operation_id))}>
                ${le(a)?"회수 중…":"회수"}
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="paused"?i`
              <button class="control-btn ghost" disabled=${le(s)} onClick=${()=>ct(()=>J_(t.operation_id))}>
                ${le(s)?"재개 중…":"재개"}
              </button>
            `:null}
      </div>
    </article>
  `}function _$({card:e}){var n;const t=e.detachment;return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.detachment_id}</strong>
          <div class="command-card-sub">${((n=e.operation)==null?void 0:n.objective)??t.operation_id}</div>
        </div>
        <span class="command-chip ${z(t.status)}">${t.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${e.assigned_unit_label??t.assigned_unit_id}</span>
        <span>리더</span><span>${t.leader_id??"미지정"}</span>
        <span>편성</span><span>${t.roster.length}</span>
        <span>세션</span><span>${t.session_id??"연결 없음"}</span>
        <span>런타임</span><span>${t.runtime_kind??"managed"}</span>
        <span>런타임 참조</span><span>${t.runtime_ref??"정보 없음"}</span>
        <span>진행 흔적</span><span>${te(t.last_progress_at)}</span>
        <span>하트비트</span><span>${Kc(t.heartbeat_deadline)}</span>
        <span>최근 갱신</span><span>${te(t.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${t.heartbeat_deadline?i`<span class="command-tag ${ug(t.heartbeat_deadline)}">
              기한 ${t.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function v$(){const e=we.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">작전</div>
          <${F} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.operations.operations.length>0?i`<div class="command-card-stack">
              ${e.operations.operations.map(t=>i`<${m$} card=${t} />`)}
            </div>`:i`<div class="empty-state">관리형 또는 투영된 작전이 없습니다.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">분견대</div>
          <${F} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${e.detachments.detachments.map(t=>i`<${_$} card=${t} />`)}
            </div>`:i`<div class="empty-state">투영된 분견대가 없습니다.</div>`}
      </section>
    </div>
  `}function g$(){var c,p,_,u,v,g,$,C,b,k,h,S,L,M,P,H;const e=cs.value,t=(e==null?void 0:e.operations)??[],n=Zt.value,s=t.find(T=>T.operation.operation_id===n)??t[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,o=((p=Kn.value)==null?void 0:p.run)??(s==null?void 0:s.preview_run)??null,l=!((_=Kn.value)!=null&&_.run)&&!!(s!=null&&s.preview_run);return ae(()=>{a?H_(a):U_()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${F} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${lt(e==null?void 0:e.connection.status)}">
          <div class="command-guide-head">
            <strong>native chain 연결</strong>
            <span class="command-chip ${lt(e==null?void 0:e.connection.status)}">${(e==null?void 0:e.connection.status)??"disconnected"}</span>
          </div>
          <p>${(e==null?void 0:e.connection.message)??"체인 요약은 MASC 프록시를 통해 집계됩니다."}</p>
          <div class="command-card-grid">
            <span>기준 URL</span><span>${(e==null?void 0:e.connection.base_url)??"정보 없음"}</span>
            <span>연결된 작전</span><span>${((u=e==null?void 0:e.summary)==null?void 0:u.linked_operations)??0}</span>
            <span>활성 체인</span><span>${((v=e==null?void 0:e.summary)==null?void 0:v.active_chains)??0}</span>
            <span>최근 실패</span><span>${((g=e==null?void 0:e.summary)==null?void 0:g.recent_failures)??0}</span>
            <span>마지막 이벤트</span><span>${te(($=e==null?void 0:e.summary)==null?void 0:$.last_history_event_at)}</span>
          </div>
        </article>

        ${ba.value?i`<div class="empty-state error">${ba.value}</div>`:null}

        ${Zi.value&&!e?i`<div class="empty-state">체인 오버레이 불러오는 중…</div>`:t.length>0?i`
                <div class="command-chain-list">
                  ${t.map(T=>i`
                    <${d$}
                      overlay=${T}
                      selected=${(s==null?void 0:s.operation.operation_id)===T.operation.operation_id}
                      onSelect=${()=>Eo(T.operation.operation_id)}
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
                  ${e.recent_history.slice(0,6).map(T=>i`<${u$} item=${T} />`)}
                </div>
              `:i`<div class="empty-state">최근 체인 이력이 없습니다.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">체인 상세</div>
          <${F} panelId="command.chains" compact=${!0} />
        </div>
        ${s?i`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${lt((C=s.operation.chain)==null?void 0:C.status)}">
                    ${((b=s.operation.chain)==null?void 0:b.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>종류</span><span>${((k=s.operation.chain)==null?void 0:k.kind)??"chain_dsl"}</span>
                  <span>체인 ID</span><span>${((h=s.operation.chain)==null?void 0:h.chain_id)??"goal-driven"}</span>
                  <span>실행 ID</span><span>${a??"아직 구체화되지 않음"}</span>
                  <span>진행률</span><span>${ps((S=s.runtime)==null?void 0:S.progress)}</span>
                  <span>경과</span><span>${Sn((L=s.runtime)==null?void 0:L.elapsed_sec)}</span>
                  <span>최근 갱신</span><span>${te(((M=s.operation.chain)==null?void 0:M.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(P=s.operation.chain)!=null&&P.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid 그래프</strong>
                        <span class="command-chip">${((H=s.operation.chain)==null?void 0:H.chain_id)??"graph"}</span>
                      </div>
                      <${c$} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">기록된 Mermaid 그래프가 아직 없습니다.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>실행 상세</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"실패":l?"미리보기":"기록됨":"대기 중"}
                  </span>
                </div>
                ${ka.value?i`<div class="empty-state">실행 상세 불러오는 중…</div>`:Bn.value?i`<div class="empty-state error">${Bn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>체인</span><span>${o.chain_id}</span>
                            <span>실행</span><span>${o.run_id??"미리보기만 있음"}</span>
                            <span>지속시간</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"정보 없음"}</span>
                            <span>노드</span><span>${o.nodes.length}</span>
                          </div>
                          ${l?i`<div class="command-card-foot">run-store에 기록되기 전, 설계된 체인으로 만든 미리보기입니다.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(T=>i`<${p$} node=${T} />`)}
                          </div>
                        `:i`<div class="empty-state">이 작전의 run-store 상세는 아직 없습니다.</div>`}
              </div>
            `:i`<div class="empty-state">그래프와 실행 상세를 보려면 체인 기반 작전을 고르세요.</div>`}
      </section>
    </div>
  `}function f$(e){switch((e??"").trim().toLowerCase()){case"pending":return"대기 중";case"approved":return"승인됨";case"denied":return"거부됨";case"executed":return"실행됨";case"active":return"가동 중";default:return(e==null?void 0:e.trim())||"확인 필요"}}function $$({decision:e}){const t=`approve:${e.decision_id}`,n=`deny:${e.decision_id}`,s=e.source==="projected_operator";return i`
    <article class="command-card ${z(e.status)}">
      <div class="command-card-head">
        <div>
          <strong>${e.requested_action}</strong>
          <div class="command-card-sub">${e.scope_type}:${e.scope_id}</div>
        </div>
        <span class="command-chip ${z(e.status)}">${f$(e.status??"pending")}</span>
      </div>
      <div class="command-card-grid">
        <span>결정 ID</span><span>${e.decision_id}</span>
        <span>요청자</span><span>${e.requested_by??"알 수 없음"}</span>
        <span>출처</span><span>${e.source??"managed"}</span>
        <span>트레이스</span><span class="mono">${e.trace_id}</span>
        <span>생성 시각</span><span>${te(e.created_at)}</span>
        <span>이유</span><span>${e.reason??"정보 없음"}</span>
      </div>
      ${e.status==="pending"&&!s?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${le(t)} onClick=${()=>ct(()=>X_(e.decision_id))}>
                ${le(t)?"승인 중…":"승인"}
              </button>
              <button class="control-btn ghost" disabled=${le(n)} onClick=${()=>ct(()=>Q_(e.decision_id))}>
                ${le(n)?"거부 중…":"거부"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">레거시 operator 승인입니다. 실제 실행은 operator control에서 처리합니다.</div>`:null}
    </article>
  `}function h$({row:e}){var c,p,_;const t=e.unit,n=`freeze:${t.unit_id}`,s=`kill:${t.unit_id}`,a=!!((c=t.policy)!=null&&c.frozen),o=!!((p=t.policy)!=null&&p.kill_switch),l=Math.round((e.utilization??0)*100);return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.label}</strong>
          <div class="command-card-sub">${t.unit_id}</div>
        </div>
        <span class="command-chip ${z(l>100?"bad":l>70?"warn":"ok")}">${l}%</span>
      </div>
      <div class="command-card-grid">
        <span>편성</span><span>${e.roster_live??0}/${e.roster_total??0}</span>
        <span>정원</span><span>${e.headcount_cap??0}</span>
        <span>작전</span><span>${e.active_operations??0}/${e.active_operation_cap??0}</span>
        <span>자율성</span><span>${((_=t.policy)==null?void 0:_.autonomy_level)??"정보 없음"}</span>
        <span>동결</span><span>${a?"예":"아니오"}</span>
        <span>킬 스위치</span><span>${o?"켜짐":"꺼짐"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${le(n)} onClick=${()=>ct(()=>Z_(t.unit_id,!a))}>
          ${le(n)?"적용 중…":a?"동결 해제":"동결"}
        </button>
        <button class="control-btn ghost" disabled=${le(s)} onClick=${()=>ct(()=>ev(t.unit_id,!o))}>
          ${le(s)?"적용 중…":o?"킬 스위치 해제":"킬 스위치 켜기"}
        </button>
      </div>
    </article>
  `}function y$(){const e=we.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${F} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${e.decisions.decisions.map(t=>i`<${$$} decision=${t} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">유닛 제어</div>
          <${F} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${e.capacity.capacity.map(t=>i`<${h$} row=${t} />`)}
            </div>`:i`<div class="empty-state">제어할 용량 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function b$(){return i`
    <div class="command-surface-tabs grouped">
      ${gg.map(e=>i`
        <div class="command-tab-group" key=${e.id}>
          <span class="command-tab-group-label">${e.label}</span>
          <div class="command-tab-group-items">
            ${Uc.filter(t=>t.group===e.id).map(t=>i`
                <button
                  class="command-surface-tab ${Y.value===t.id?"active":""}"
                  onClick=${()=>{rt(t.id),oe("command",Ko(t.id))}}
                >
                  ${t.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function k$(){if(Y.value==="warroom")return i`<${l$} />`;if(Y.value==="summary")return i`<${sf} />`;if(Y.value==="orchestra")return i`<${hf} />`;if(Y.value==="swarm")return i`<${n$} />`;if(!we.value)return i`<${af} />`;switch(Y.value){case"chains":return i`<${g$} />`;case"topology":return i`<${Ff} />`;case"alerts":return i`<${wf} />`;case"trace":return i`<${Kf} />`;case"control":return i`<${y$} />`;case"operations":default:return i`<${v$} />`}}function x$(){return ae(()=>{Kt(),en(),W_(),tt(),Rt()},[]),ae(()=>{if(O.value.tab!=="command")return;const e=O.value.params.surface,t=O.value.params.operation,n=ds(O.value);if(Lr(e))rt(e);else if(n){const s=Ic(n);Lr(s)&&rt(s)}else e||rt("warroom");t&&Eo(t),(e==="swarm"||e==="warroom"||e==="orchestra"||Y.value==="warroom"||Y.value==="orchestra")&&tt(),(e==="orchestra"||Y.value==="orchestra")&&Rt(),(e==="warroom"||Y.value==="warroom")&&be()},[O.value.tab,O.value.params.surface,O.value.params.operation,O.value.params.operation_id,O.value.params.run_id,O.value.params.source,O.value.params.action_type,O.value.params.target_type,O.value.params.target_id,O.value.params.focus_kind]),ae(()=>{let e=null;const t=()=>{e||(e=window.setTimeout(()=>{e=null,Kt(),en(),(Y.value==="swarm"||Y.value==="warroom"||Y.value==="orchestra")&&tt(),Y.value==="orchestra"&&Rt(),Y.value==="warroom"&&be()},250))},n=new EventSource(bg()),s=$g.map(a=>{const o=()=>t();return n.addEventListener(a,o),{type:a,handler:o}});return n.onerror=()=>{t()},()=>{s.forEach(({type:a,handler:o})=>{n.removeEventListener(a,o)}),n.close(),e&&window.clearTimeout(e)}},[]),ae(()=>{const e=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const t=Y.value;t!=="swarm"&&t!=="warroom"&&t!=="orchestra"||(Kt(),tt(),t==="orchestra"&&Rt(),t==="warroom"&&be())},5e3);return()=>{window.clearInterval(e)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{ct(()=>V_())}}
            disabled=${le("dispatch:tick")}
          >
            ${le("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{It(),Kt(),en(),tt(),Y.value==="warroom"&&be()}}
            disabled=${pa.value}
          >
            ${pa.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${_a.value?i`<div class="empty-state error">${_a.value}</div>`:null}
      ${ga.value?i`<div class="empty-state error">${ga.value}</div>`:null}
      <${ke} surfaceId="command" />
      <${Ga} />
      <${Qg} />
      ${Y.value==="warroom"?null:i`<${Zg} />`}
      <${b$} />
      <${k$} />
    </section>
  `}function S$(){var k,h;const e=Ae.value,t=To.value,n=(e==null?void 0:e.room)??{},s=(e==null?void 0:e.pending_confirms)??[],a=e==null?void 0:e.pending_confirm_summary,o=a?a.confirm_required_actions:((e==null?void 0:e.available_actions)??[]).filter(S=>S.confirm_required),l=((k=a==null?void 0:a.actor_filter)==null?void 0:k.trim())||null,c=(a==null?void 0:a.hidden_count)??0,p=(a==null?void 0:a.hidden_actors)??[],_=(e==null?void 0:e.recent_messages)??[],u=(t==null?void 0:t.recommended_actions)??[],v=(h=t==null?void 0:t.active_recommended_actions)!=null&&h.length?t.active_recommended_actions:u,g=t==null?void 0:t.active_summary,$=(t==null?void 0:t.resident_judge_runtime)??(e==null?void 0:e.resident_judge_runtime),C=(t==null?void 0:t.active_guidance_layer)??"fallback",b=_.slice(0,5);return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Room 개입</div>
          <${F} panelId="intervene.action_studio" compact=${!0} />
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
          <div class="ops-stat ${kf($)}">
            <span>Resident Judge</span>
            <strong>${Go($)}</strong>
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
            onInput=${S=>{nn.value=S.target.value}}
            onKeyDown=${S=>{S.key==="Enter"&&Fr()}}
            disabled=${J.value}
          />
          <button class="control-btn" onClick=${()=>{Fr()}} disabled=${J.value||nn.value.trim()===""}>
            보내기
          </button>
        </div>

        <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
        <div class="control-row ops-split-row">
          <input
            id="ops-pause-reason"
            class="control-input"
            type="text"
            value=${Ta.value}
            onInput=${S=>{Ta.value=S.target.value}}
            disabled=${J.value}
          />
          <button class="control-btn ghost" onClick=${()=>{zf()}} disabled=${J.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{td()}} disabled=${J.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${sn.value}
          onInput=${S=>{sn.value=S.target.value}}
          disabled=${J.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${Wn.value}
          onInput=${S=>{Wn.value=S.target.value}}
          disabled=${J.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${Gn.value}
            onChange=${S=>{Gn.value=S.target.value}}
            disabled=${J.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{Pf()}} disabled=${J.value||sn.value.trim()===""}>
            주입
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">추천 개입</div>
          <${F} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
        <article class="ops-guidance-card ${za(C)}">
          <div class="ops-guidance-head">
            <strong>${Wo(C)}</strong>
            <span>${($==null?void 0:$.keeper_name)??(t==null?void 0:t.judgment_owner)??"judge 없음"}</span>
          </div>
          <div class="ops-guidance-body">
            ${(g==null?void 0:g.summary)??"현재 active guidance 요약이 없습니다. fallback queue만 표시합니다."}
          </div>
          <div class="ops-guidance-meta">
            <span>authoritative ${t!=null&&t.authoritative_judgment_available?"yes":"no"}</span>
            <span>${Jo(g)}</span>
            ${$!=null&&$.model_used?i`<span>${$.model_used}</span>`:null}
          </div>
        </article>
        ${wn.value&&!t?i`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:v.length>0?i`
          <div class="ops-log-list">
            ${v.map(S=>i`
              <article key=${`${S.action_type}:${S.target_type}:${S.target_id??"room"}`} class="ops-log-entry ${S.severity}">
                <div class="ops-log-head">
                  <strong>${zt(S.action_type)}</strong>
                  <span>${on(S.target_type)}${S.target_id?` · ${S.target_id}`:""}</span>
                  <span>${Pa(S.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${S.reason}</div>
                ${S.suggested_payload?i`
                  <div class="ops-confirmation-actions">
                    <button class="control-btn ghost" onClick=${()=>{Mf(S)}} disabled=${J.value}>
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
          <${F} panelId="intervene.pending_confirmations" compact=${!0} />
        </div>
        <p class="ops-context-note">
          ${l?`현재 actor ${l} 기준 queue를 읽습니다. 승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다.`:"승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다."}
        </p>
        ${o.length>0?i`
          <div class="ops-log-list">
            ${o.map(S=>i`
              <article key=${`${S.action_type}:${S.target_type}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${zt(S.action_type)}</strong>
                  <span>${on(S.target_type)}</span>
                  <span>${Pa(S.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${S.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}
        ${s.length>0?i`
          <div class="ops-confirmation-list">
            ${s.map(S=>i`
              <article key=${S.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${zt(S.action_type)}</strong>
                  <span>${on(S.target_type)}${S.target_id?` · ${S.target_id}`:""}</span>
                  <span>${S.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${S.preview?i`<pre class="ops-code-block compact">${La(S.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{wr(S.confirm_token)}} disabled=${J.value}>
                    실행
                  </button>
                  <button class="control-btn ghost" onClick=${()=>{wr(S.confirm_token,"deny")}} disabled=${J.value}>
                    거부
                  </button>
                  <span class="ops-token">${S.confirm_token}</span>
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
          <${F} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${b.length>0?i`
          <div class="ops-feed-list">
            ${b.map(S=>i`
              <article key=${S.seq??S.id??S.timestamp} class="ops-feed-item">
                <div class="ops-feed-meta">
                  <strong>${S.from}</strong>
                  <span>${S.timestamp}</span>
                </div>
                <div class="ops-feed-content">${S.content}</div>
              </article>
            `)}
          </div>
        `:i`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
      </section>
    </div>
  `}function C$(){var _;const e=Ae.value,t=qe.value,n=(e==null?void 0:e.sessions)??[],s=((e==null?void 0:e.available_actions)??[]).filter(u=>u.target_type==="team_session"),a=n.find(u=>u.session_id===cn.value)??n[0]??null,o=t==null?void 0:t.active_summary,l=(t==null?void 0:t.active_guidance_layer)??"fallback",c=(t==null?void 0:t.resident_judge_runtime)??(e==null?void 0:e.resident_judge_runtime),p=(_=t==null?void 0:t.active_recommended_actions)!=null&&_.length?t.active_recommended_actions:(t==null?void 0:t.recommended_actions)??[];return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${F} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(u=>{var v;return i`
            <button
              key=${u.session_id}
              class="ops-entity-card ${(a==null?void 0:a.session_id)===u.session_id?"active":""}"
              onClick=${()=>{cn.value=u.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${u.session_id}</strong>
                <span class="status-badge ${u.status??"idle"}">${Ht(u.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(u.progress_pct??0)}%</span>
                <span>${u.done_delta_total??0}건 완료</span>
                <span>${(v=u.team_health)!=null&&v.status?Ht(String(u.team_health.status)):"상태 확인 필요"}</span>
              </div>
            </button>
          `})}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Session 요약</div>
          <${F} panelId="intervene.session_digest" compact=${!0} />
        </div>
        <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
        ${a&&t?i`
          <article class="ops-guidance-card ${za(l)}">
            <div class="ops-guidance-head">
              <strong>${Wo(l)}</strong>
              <span>${Go(c)}</span>
            </div>
            <div class="ops-guidance-body">
              ${(o==null?void 0:o.summary)??"현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다."}
            </div>
            <div class="ops-guidance-meta">
              <span>authoritative ${t.authoritative_judgment_available?"yes":"no"}</span>
              <span>${Jo(o)}</span>
              ${c!=null&&c.model_used?i`<span>${c.model_used}</span>`:null}
            </div>
          </article>
          ${p.length>0?i`
            <div class="ops-log-list">
              ${p.map(u=>i`
                <article key=${`${u.action_type}:${u.target_type}:${u.target_id??"session"}`} class="ops-log-entry ${u.severity}">
                  <div class="ops-log-head">
                    <strong>${zt(u.action_type)}</strong>
                    <span>${on(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
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
                  <span>${on(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${u.summary}</div>
              </article>
            `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${t.worker_cards.length>0?t.worker_cards.map(u=>i`
              <article key=${`${u.actor??u.spawn_role??"worker"}:${u.spawn_agent??u.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${u.actor??u.spawn_role??"worker"}</strong>
                  <span>${Ht(u.status)}</span>
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
          <${F} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>
        ${s.length>0?i`
          <div class="ops-log-list">
            ${s.map(u=>i`
              <article key=${u.action_type} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${zt(u.action_type)}</strong>
                  <span>${Pa(u.confirm_required)}</span>
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
              <span>상태: ${Ht(a.status)}</span>
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
              <pre class="ops-code-block compact">${La(a.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${ye.value}
            onChange=${u=>{ye.value=u.target.value}}
            disabled=${J.value||!a}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
            <option value="worker_spawn_batch">worker 교체</option>
          </select>
          <button class="control-btn" onClick=${()=>{Ef()}} disabled=${J.value||!a}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${Af(ye.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${Jn.value}
          onInput=${u=>{Jn.value=u.target.value}}
          disabled=${J.value||!a}
        ></textarea>

        ${ye.value==="task"?i`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${Yn.value}
            onInput=${u=>{Yn.value=u.target.value}}
            disabled=${J.value||!a}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${Vn.value}
            onInput=${u=>{Vn.value=u.target.value}}
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
        `:ye.value==="worker_spawn_batch"?i`
          <textarea
            class="control-textarea"
            rows=${6}
            placeholder='spawn_batch JSON, 예: [{"spawn_agent":"llama","spawn_prompt":"...", "spawn_role":"replacement"}]'
            value=${Qn.value}
            onInput=${u=>{Qn.value=u.target.value}}
            disabled=${J.value||!a}
          ></textarea>
        `:null}

        <div class="control-row ops-split-row">
          <input
            class="control-input"
            type="text"
            value=${Ra.value}
            onInput=${u=>{Ra.value=u.target.value}}
            disabled=${J.value||!a}
          />
          <button class="control-btn ghost" onClick=${()=>{jf()}} disabled=${J.value||!a}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function A$(){var o;const e=Ae.value,t=(e==null?void 0:e.keepers)??[],n=(e==null?void 0:e.persistent_agents)??[],s=(e==null?void 0:e.available_actions)??[],a=t.find(l=>l.name===Ma.value)??t[0]??null;return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${F} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${t.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:t.map(l=>i`
            <button
              key=${l.name}
              class="ops-entity-card ${(a==null?void 0:a.name)===l.name?"active":""}"
              onClick=${()=>{Ma.value=l.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${l.name}</strong>
                <span class="status-badge ${l.status??"idle"}">${Ht(l.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${l.model??"model 확인 필요"}</span>
                <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${Or(l.last_turn_ago_s)}</span>
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
                    <span class="status-badge ${l.status??"idle"}">${Ht(l.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>persistent</span>
                    <span>${l.model??"model 확인 필요"}</span>
                    <span>${Or(l.last_turn_ago_s)}</span>
                  </div>
                </article>
              `)}
        </div>
      </section>

      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Keeper 액션</div>
          <${F} panelId="intervene.action_studio" compact=${!0} />
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
          value=${an.value}
          onInput=${l=>{an.value=l.target.value}}
          disabled=${J.value||!a}
        ></textarea>
        <div class="control-row">
          <button class="control-btn" onClick=${()=>{Nf()}} disabled=${J.value||!a||an.value.trim()===""}>
            keeper에 보내기
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">가능한 액션 목록</div>
          <${F} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
        <div class="ops-log-list">
          ${s.length?s.map(l=>i`
                <article key=${`${l.action_type}:${l.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${zt(l.action_type)}</strong>
                    <span>${on(l.target_type)}</span>
                    <span>${Pa(l.confirm_required)}</span>
                  </div>
                  <div class="ops-log-body">${l.description??"설명이 아직 없습니다."}</div>
                </article>
              `):i`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 개입 로그</div>
          <${F} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <div class="ops-log-list">
          ${la.value.length===0?i`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:la.value.map(l=>i`
            <article key=${l.id} class="ops-log-entry ${l.outcome}">
              <div class="ops-log-head">
                <strong>${zt(l.action_type)}</strong>
                <span>${l.target_label}</span>
                <span>${l.at}</span>
              </div>
              <div class="ops-log-body">${l.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function I$(){var M,P,H;const e=Ae.value,t=O.value.tab==="intervene"?ds(O.value):null,n=To.value,s=(e==null?void 0:e.room)??{},a=(e==null?void 0:e.sessions)??[],o=(e==null?void 0:e.keepers)??[],l=(e==null?void 0:e.pending_confirms)??[],c=e==null?void 0:e.pending_confirm_summary,p=(c==null?void 0:c.visible_count)??l.length,_=(c==null?void 0:c.total_count)??l.length,u=(c==null?void 0:c.hidden_count)??0,v=((M=c==null?void 0:c.actor_filter)==null?void 0:M.trim())||null,g=a.find(T=>T.session_id===cn.value)??a[0]??null,$=(n==null?void 0:n.attention_items)??[],C=$.filter(Sf),b=$.filter(Cf),k=a.filter(T=>xf(T)!=="ok"),h=o.filter(T=>li(T)!=="ok"),S=Lf(t,a,o);ae(()=>{Pt()},[]),ae(()=>{if(O.value.tab!=="intervene"){Ls.value=null;return}if(!t){Ls.value=null;return}Ls.value!==t.id&&(Ls.value=t.id,Rf(t))},[O.value.tab,O.value.params.source,O.value.params.action_type,O.value.params.target_type,O.value.params.target_id,O.value.params.focus_kind,t==null?void 0:t.id]),ae(()=>{const T=(g==null?void 0:g.session_id)??null;ln(T)},[g==null?void 0:g.session_id]);const L=[{key:"room",label:"방 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:u>0?`${p}/${_}`:p,detail:p>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":u>0&&v?`현재 개입 ID(${v}) 기준으로는 비어 있고, 다른 개입 ID 대기 ${u}건이 있습니다`:"지금 막혀 있는 확인 대기는 없습니다",tone:_>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:C.length>0?C.length:a.length,detail:C.length>0?((P=C[0])==null?void 0:P.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 팀 세션이 없습니다":"세션 쪽 긴급 주의 신호는 현재 없습니다",tone:C.length>0?qr(C):a.length===0?"warn":k.some(T=>dn(T.status)==="paused")?"bad":k.length>0?"warn":"ok"},{key:"keeper",label:"키퍼 압력",value:b.length>0?b.length:h.length,detail:b.length>0?((H=b[0])==null?void 0:H.summary)??"직접 메시지나 상태 점검이 필요한 키퍼가 있습니다":h.length>0?"오래됐거나 오프라인이거나 텔레메트리가 비는 키퍼가 보입니다":"지금은 키퍼 쪽이 비교적 안정적입니다",tone:b.length>0?qr(b):h.some(T=>li(T)==="bad")?"bad":h.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${ke} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">개입</div>
            <${F} panelId="intervene.action_studio" compact=${!0} />
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
            value=${Va.value}
            onInput=${T=>bf(T.target.value)}
          />
            <button
              class="control-btn ghost"
              onClick=${()=>{It(),be(),Pt(),ln((g==null?void 0:g.session_id)??null)}}
            disabled=${Fn.value||J.value}
          >
            ${Fn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${ut.value?i`<section class="ops-banner error">${ut.value}</section>`:null}
      ${rn.value?i`<section class="ops-banner error">${rn.value}</section>`:null}
      <${Ga} />
      ${t?i`
        <section class="ops-banner ${S?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${t.source_label}</strong>
            <span>${Ja(t.action_type)}</span>
            <span>${Oo(t)}</span>
          </div>
          <div class="ops-handoff-body">${t.summary}</div>
          ${t.payload_preview?i`<div class="ops-handoff-preview">${t.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${S?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const T=[];if((p>0||u>0)&&T.push({label:u>0?`확인 대기 ${p}/${_}건 확인`:`확인 대기 ${p}건 처리`,desc:u>0&&v?`현재 개입 ID(${v}) 기준으로 보이는 대기열을 먼저 확인합니다`:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:p>0?"bad":"warn",onClick:()=>{const W=document.querySelector(".ops-pending-section");W==null||W.scrollIntoView({behavior:"smooth"})}}),s.paused&&T.push({label:"방 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void td()}),h.length>0){const W=h.filter(Q=>li(Q)==="bad");T.push({label:W.length>0?`오프라인 키퍼 ${W.length}개`:`점검이 필요한 키퍼 ${h.length}개`,desc:W.length>0?"메시지를 보내거나 상태를 확인하세요":"오래됐거나 텔레메트리가 비어 있습니다",tone:W.length>0?"bad":"warn",onClick:()=>{const Q=document.querySelector(".ops-keeper-section");Q==null||Q.scrollIntoView({behavior:"smooth"})}})}return T.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${T.slice(0,3).map(W=>i`
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
          <${F} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 방인지, 세션인지, 키퍼인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${L.map(T=>i`
            <div key=${T.key} class="ops-priority-card ${T.tone}">
              <span class="ops-priority-label">${T.label}</span>
              <strong>${T.value}</strong>
              <div class="ops-priority-detail">${T.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${S$} />
        <${C$} />
        <${A$} />
      </div>
    </section>
  `}function T$({text:e}){if(!e)return null;const t=R$(e);return i`<div class="markdown-content">${t}</div>`}function R$(e){const t=e.split(`
`),n=[];let s=0;for(;s<t.length;){const a=t[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),p=[];for(s++;s<t.length&&!t[s].startsWith(l);)p.push(t[s]),s++;s++,n.push(i`<pre><code class=${c?`language-${c}`:""}>${p.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<t.length&&!t[s].includes("</think>");)l.push(t[s]),s++;if(s<t.length){const _=t[s].replace("</think>","").trim();_&&l.push(_),s++}const p=l.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${ci(p)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<t.length&&t[s].startsWith("> ");)l.push(t[s].slice(2)),s++;n.push(i`<blockquote>${ci(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<t.length;){const l=t[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;o.push(l),s++}o.length>0&&n.push(i`<p>${ci(o.join(`
`))}</p>`)}return n}function ci(e){const t=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(e))!==null;){if(a.index>s&&t.push(e.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);t.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);t.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);t.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&t.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<e.length&&t.push(e.slice(s)),t.length>0?t:[e]}const dd=[{id:"recent",label:"최신순"},{id:"hot",label:"인기순"},{id:"trending",label:"급상승"},{id:"updated",label:"최근 갱신"},{id:"discussed",label:"토론 많은 순"}],Xs=f(null),Qs=f([]),un=f(!1),Lt=f(null),Ln=f(""),zn=f(!1),Wt=f(!0),Vo=20,Ot=f(Vo);function M$(){var t,n;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const L$=f(M$());function z$(e){const t=e.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return t?t.length>180?`${t.slice(0,177)}...`:t:"미리보기 없음"}function Ur(e){return e.updated_at!==e.created_at}function P$(e){if(e.post_kind)return e.post_kind==="automation";const t=(e.hearth??"").toLowerCase();return e.visibility!=="internal"||!e.expires_at||!t?!1:!!(t.startsWith("mdal")||t.includes("harness"))}function E$(e){return e==="lodge-system"||e==="team-session"}function Zn(e){return e.post_kind?e.post_kind:E$(e.author)?"system":P$(e)?"automation":"human"}function ud(e){const t=[],n=[];let s=0;return e.forEach(a=>{const o=Zn(a);if(!(o==="system"&&Ct.value)){if(o==="automation"&&Wt.value){s+=1;return}if(o==="human"){t.push(a);return}n.push(a)}}),{human:t,operations:n,hiddenAutomation:s}}function j$(e){if(!e.expires_at)return null;const t=Date.parse(e.expires_at);return Number.isFinite(t)?t<=Date.now()?i`<span class="board-meta-chip">만료됨</span>`:i`<span class="board-meta-chip">만료까지 <${X} timestamp=${e.expires_at} /></span>`:null}async function Xo(e){Lt.value=e,Xs.value=null,Qs.value=[],un.value=!0;try{const t=await Mu(e);if(Lt.value!==e)return;Xs.value={id:t.id,author:t.author,title:t.title,body:t.body,content:t.content,meta:t.meta,tags:t.tags,votes:t.votes,vote_balance:t.vote_balance,comment_count:t.comment_count,created_at:t.created_at,updated_at:t.updated_at,post_kind:t.post_kind,flair:t.flair,hearth:t.hearth,visibility:t.visibility,expires_at:t.expires_at,hearth_count:t.hearth_count},Qs.value=t.comments??[]}catch{Lt.value===e&&(Xs.value=null,Qs.value=[])}finally{Lt.value===e&&(un.value=!1)}}async function Hr(e){const t=Ln.value.trim();if(t){zn.value=!0;try{await Lu(e,L$.value,t),Ln.value="",N("댓글을 등록했습니다","success"),await Xo(e),it()}catch{N("댓글 등록에 실패했습니다","error")}finally{zn.value=!1}}}function N$(){const e=On.value,t=Wt.value?"자동화 글 숨김":"자동화 글 표시 중";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${dd.map(n=>i`
          <button
            class="board-sort-btn ${e===n.id?"active":""}"
            onClick=${()=>{On.value=n.id,Ot.value=Vo,it()}}
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
          class="control-btn ghost ${Ct.value?"is-active":""}"
          onClick=${()=>{Ct.value=!Ct.value,it()}}
        >
          ${Ct.value?"시스템 글 숨김":"시스템 글 표시 중"}
        </button>
        <button class="control-btn ghost" onClick=${it} disabled=${qn.value}>
          ${qn.value?"새로고침 중...":"새로고침"}
        </button>
      </div>
    </div>
  `}function di(){var s;const e=((s=dd.find(a=>a.id===On.value))==null?void 0:s.label)??On.value,t=ud(Ua.value),n=t.human.length+t.operations.length;return i`
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
        <strong>${Ct.value?"시스템 글 숨김":"시스템 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">최근 갱신</span>
        <strong>${Hi.value?i`<${X} timestamp=${Hi.value} />`:"아직 불러오지 않음"}</strong>
      </div>
    </div>
  `}function Wr({post:e}){const t=async(n,s)=>{s.stopPropagation();try{await xl(e.id,n),it()}catch{N("투표에 실패했습니다","error")}};return i`
    <div class="board-post" onClick=${()=>Ed(e.id)}>
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
                ${Ur(e)?i`<span class="board-meta-chip">수정됨</span>`:null}
                ${Zn(e)!=="human"?i`<span class="board-meta-chip">${Zn(e)}</span>`:null}
                ${e.hearth?i`<span class="board-meta-chip">${e.hearth}</span>`:null}
                ${e.visibility?i`<span class="board-meta-chip">${e.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>작성자 ${e.author}</span>
            <span><${X} timestamp=${e.created_at} /></span>
            ${Ur(e)?i`<span>수정 <${X} timestamp=${e.updated_at} /></span>`:null}
            <span>댓글 ${e.comment_count}</span>
            <span>투표 ${e.votes??0}</span>
          </div>
        </div>
        <div class="post-snippet">${z$(e.body)}</div>
      </div>
    </div>
  `}function D$({comments:e}){return e.length===0?i`<div class="empty-state" style="font-size:13px">아직 댓글이 없습니다</div>`:i`
    <div class="comment-thread">
      ${e.map(t=>i`
        <div key=${t.id} class="board-comment">
          <span class="comment-author">${t.author}</span>
          <span class="comment-time"><${X} timestamp=${t.created_at} /></span>
          <div class="comment-text">${t.content}</div>
        </div>
      `)}
    </div>
  `}function O$({postId:e}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="댓글 추가..."
        value=${Ln.value}
        onInput=${t=>{Ln.value=t.target.value}}
        onKeyDown=${t=>{t.key==="Enter"&&Hr(e)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${zn.value}
      />
      <button
        onClick=${()=>Hr(e)}
        disabled=${zn.value||Ln.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${zn.value?"...":"등록"}
      </button>
    </div>
  `}function q$({post:e}){Lt.value!==e.id&&!un.value&&Xo(e.id);const t=async n=>{try{await xl(e.id,n),it()}catch{N("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>oe("memory")}>← 메모리로 돌아가기</button>
      <${R} title=${e.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${T$} text=${e.body} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${e.author}</span>
            <${X} timestamp=${e.created_at} />
            <span>${e.votes??0} votes</span>
          </div>
          ${e.hearth||e.visibility||e.expires_at?i`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${e.hearth?i`<span class="board-meta-chip">${e.hearth}</span>`:null}
                  ${e.visibility?i`<span class="board-meta-chip">${e.visibility}</span>`:null}
                  ${Zn(e)!=="human"?i`<span class="board-meta-chip">${Zn(e)}</span>`:null}
                  ${j$(e)}
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

      <${R} title="댓글" semanticId="memory.feed">
        ${un.value?i`<div class="loading-indicator">댓글 불러오는 중...</div>`:i`<${D$} comments=${Qs.value} />`}
        <${O$} postId=${e.id} />
      <//>
    </div>
  `}function F$(){const e=ud(Ua.value),t=[...e.human,...e.operations],n=O.value.params.post??null,s=n?t.find(a=>a.id===n)??(Lt.value===n?Xs.value:null):null;return n&&!s&&Lt.value!==n&&!un.value&&Xo(n),n?s?i`
          <${ke} surfaceId="memory" />
          <${di} />
          <${q$} post=${s} />
        `:i`
          <div>
            <${ke} surfaceId="memory" />
            <${di} />
            <button class="back-btn" onClick=${()=>oe("memory")}>← 메모리로 돌아가기</button>
            ${un.value?i`<div class="loading-indicator">글 불러오는 중...</div>`:i`<div class="empty-state">글을 찾지 못했습니다</div>`}
          </div>
        `:i`
    <div>
      <${ke} surfaceId="memory" />
      <${di} />
      <${N$} />
      ${qn.value?i`<div class="loading-indicator">메모리 피드 불러오는 중...</div>`:t.length===0?i`<div class="empty-state">지금은 남아 있는 메모리 글이 없습니다</div>`:i`
              <${R} title="사람이 쓴 글" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${e.human.slice(0,Ot.value).map(a=>i`<${Wr} key=${a.id} post=${a} />`)}
                </div>
                ${e.human.length>Ot.value?i`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{Ot.value=Ot.value+Vo}}
                    >
                      더 보기 (${e.human.length-Ot.value}개 남음)
                    </button>
                  </div>
                `:null}
              <//>
              ${e.operations.length>0?i`
                    <${R} title="자동화 · 시스템" class="section" semanticId="memory.feed">
                      <div class="board-post-list">
                        ${e.operations.map(a=>i`<${Wr} key=${a.id} post=${a} />`)}
                      </div>
                    <//>
                  `:null}
            `}
    </div>
  `}const xt=f(null),Be=f(null),Ue=f(null);function es(e){return e==="bad"||e==="critical"||e==="offline"?"bad":e==="warn"||e==="paused"||e==="blocked"||e==="interrupted"?"warn":"ok"}function ts(e){switch((e??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":return"주의";case"bad":case"critical":return"위험";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function w$(e){return e==="session"?"세션":"작전"}function K$(e){return e?_t.value.find(t=>t.name===e||t.agent_name===e)??null:null}function B$(e){switch(e){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function U$(e){switch(e){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function H$(e){switch(e){case"acted":return"행동";case"passed":return"통과";case"skipped":return"건너뜀";case"failed":return"실패";default:return e}}function W$(e){switch(e){case"post":return"post";case"comment":return"comment";case"vote":return"vote";case"none":case null:case void 0:return"none";default:return e}}function Gr(e){if(!e)return;const t=dv({targetType:e.target_type,targetId:e.target_id,focusKind:e.focus_kind,operationId:e.operation_id??null,commandSurface:e.command_surface??null,sourceLabel:"실행 진단",summary:e.label});Cc(t),oe(e.surface,e.surface==="intervene"?Ac(t):Tc(t))}function yn({label:e,value:t,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${e}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${t}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function Qo({intervene:e,command:t}){return i`
    <div class="control-row">
      ${e?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),Gr(e)}}
            >
              ${e.label}
            </button>
          `:null}
      ${t?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),Gr(t)}}
            >
              ${t.label}
            </button>
          `:null}
    </div>
  `}function G$({item:e,selected:t}){return i`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{xt.value=t?null:e.id,Be.value=null,Ue.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.kind==="session"?e.target_id:e.linked_session_id??e.target_id}</div>
          <div class="mission-card-title">${e.summary}</div>
        </div>
        <span class="command-chip ${es(e.severity)}">${ts(e.status??e.severity)}</span>
      </div>
      <div class="mission-card-meta">
        <span>${w$(e.kind)}</span>
        ${e.linked_operation_id?i`<span>연결 작전 · ${e.linked_operation_id}</span>`:null}
        ${e.last_seen_at?i`<span><${X} timestamp=${e.last_seen_at} /></span>`:null}
      </div>
      <${Qo} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function J$({brief:e,selected:t}){return i`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.session-card"
      onClick=${()=>{Be.value=t?null:e.session_id,Ue.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          <div class="mission-card-title">${e.goal}</div>
        </div>
        <span class="command-chip ${es(e.health??e.status)}">${ts(e.status)}</span>
      </div>
      <div class="mission-card-meta">
        <span>건강도 · ${ts(e.health??"ok")}</span>
        ${e.linked_operation_id?i`<span>연결 작전 · ${e.linked_operation_id}</span>`:null}
        ${e.last_activity_at?i`<span><${X} timestamp=${e.last_activity_at} /></span>`:null}
      </div>
      ${e.runtime_blocker?i`<div class="mission-card-detail">${e.runtime_blocker}</div>`:e.last_activity_summary?i`<div class="mission-card-detail">${e.last_activity_summary}</div>`:null}
      ${e.worker_gap_summary?i`<div class="monitor-footnote">${e.worker_gap_summary}</div>`:null}
      <${Qo} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function Y$({brief:e,selected:t}){return i`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.operation-card"
      onClick=${()=>{Ue.value=t?null:e.operation_id,Be.value=e.linked_session_id??null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.operation_id}${e.assigned_unit_label?` · ${e.assigned_unit_label}`:""}</div>
          <div class="mission-card-title">${e.objective}</div>
        </div>
        <span class="command-chip ${es(e.blocker_summary?"warn":e.status)}">${ts(e.status)}</span>
      </div>
      <div class="mission-card-meta">
        ${e.stage?i`<span>단계 · ${e.stage}</span>`:null}
        ${e.linked_session_id?i`<span>세션 · ${e.linked_session_id}</span>`:null}
        ${e.updated_at?i`<span><${X} timestamp=${e.updated_at} /></span>`:null}
      </div>
      ${e.blocker_summary?i`<div class="mission-card-detail">${e.blocker_summary}</div>`:null}
      ${e.next_tool?i`<div class="monitor-footnote">다음 도구 · ${e.next_tool}</div>`:null}
      <${Qo} command=${e.command_handoff} />
    </button>
  `}function V$({tick:e}){return e?i`
    <div class="monitor-nested-card">
      <div class="stats-grid">
        <${yn} label="checked" value=${e.checked??0} color="#22d3ee" />
        <${yn} label="acted" value=${e.acted??0} color="#4ade80" />
        <${yn} label="passed" value=${e.passed??0} color="#94a3b8" />
        <${yn} label="skipped" value=${e.skipped??0} color="#fbbf24" />
        <${yn} label="failed" value=${e.failed??0} color="#fb7185" />
      </div>
      <div class="monitor-meta">
        ${e.last_tick_at?i`<span>마지막 tick <${X} timestamp=${e.last_tick_at} /></span>`:i`<span>마지막 tick 없음</span>`}
        ${e.last_skip_reason?i`<span>대표 skip 이유 · ${e.last_skip_reason}</span>`:null}
      </div>
      ${e.activity_report?i`<div class="monitor-footnote">${e.activity_report}</div>`:null}
    </div>
  `:i`<div class="empty-state">최근 lodge tick 기록이 없습니다.</div>`}function X$({row:e}){return i`
    <button
      class="monitor-row ${es(e.outcome==="failed"?"bad":e.outcome==="skipped"?"warn":"ok")}"
      data-testid="execution.lodge-checkin-card"
      onClick=${()=>us(e.agent_name)}
    >
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.agent_name}</span>
            ${e.worker_name?i`<span class="monitor-sub">worker · ${e.worker_name}</span>`:null}
          </div>
          <div class="monitor-note">${e.reason??e.summary??"이유가 기록되지 않았습니다."}</div>
        </div>
        <span class="monitor-pill ${es(e.outcome==="failed"?"bad":e.outcome==="skipped"?"warn":"ok")}">${H$(e.outcome)}</span>
      </div>
      <div class="monitor-meta">
        <span>trigger · ${e.trigger??"unknown"}</span>
        ${e.checked_at?i`<span><${X} timestamp=${e.checked_at} /></span>`:null}
        <span>action · ${W$(e.action_kind)}</span>
      </div>
      ${e.summary&&e.summary!==e.reason?i`<div class="monitor-focus">${e.summary}</div>`:null}
      ${e.failure_reason||e.decision_reason?i`<div class="monitor-footnote">
            ${e.failure_reason?`실패 이유: ${e.failure_reason}`:`판단 이유: ${e.decision_reason}`}
          </div>`:null}
    </button>
  `}function Jr({row:e,testId:t}){return i`
    <button class="monitor-row ${e.tone} state-${e.state}" data-testid=${t} onClick=${()=>us(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.korean_name?i`<span class="monitor-sub">${e.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${e.note}</div>
        </div>
        <${gt} status=${e.status??"unknown"} />
        <span class="monitor-pill ${e.tone} state-${e.state}">${B$(e.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_signal_at?i`<span>신호 <${X} timestamp=${e.last_signal_at} /></span>`:i`<span>최근 신호 없음</span>`}
        <span>${(e.active_task_count??0)>0?`활성 작업 ${e.active_task_count}개`:"활성 작업 없음"}</span>
        ${e.related_session_id?i`<span>세션 · ${e.related_session_id}</span>`:null}
        ${e.related_operation_id?i`<span>작전 · ${e.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.recent_output_preview&&e.recent_output_preview!==e.focus?i`<div class="monitor-footnote">최근 상세: ${e.recent_output_preview}</div>`:null}
    </button>
  `}function Q$({row:e}){const t=()=>{const a=K$(e.name);a&&wc(a)},n=Nc(e.name,e.agent_name),s={name:e.name,koreanName:e.korean_name??null,runtimeLabel:n,emoji:e.emoji??null,tone:e.tone,statusRaw:e.status??null,statusLabel:ts(e.status),stateClass:e.state,stateLabel:U$(e.state),contextRatio:e.context_ratio??null,note:e.note,focus:e.focus,lastActivityAt:e.last_signal_at??null,lastActivityFallback:"최근 활동 없음",relatedSessionId:e.related_session_id??null,continuity:e.continuity??null,lifecycle:e.lifecycle??null,summary:e.continuity_summary??e.recent_output_preview??null,recentInput:e.recent_input_preview??null,recentOutput:e.recent_output_preview??null,recentTools:e.recent_tool_names??[],allowedTools:e.allowed_tool_names??[],routeSummary:e.skill_route_summary??null,auditSource:e.tool_audit_source??null,auditAt:e.tool_audit_at??null,disclosureLabel:"연속성 상세"};return i`<${Ec}
    variant="execution"
    model=${s}
    onClick=${t}
    testId="execution.continuity-card"
  />`}function Z$(){const e=Tl.value,t=Rl.value,n=Ml.value,s=Ll.value,a=zl.value,o=Pl.value,l=ko.value,c=El.value;xt.value&&!e.some(h=>h.id===xt.value)&&(xt.value=null),Be.value&&!t.some(h=>h.session_id===Be.value)&&(Be.value=null),Ue.value&&!n.some(h=>h.operation_id===Ue.value)&&(Ue.value=null);const p=xt.value?e.find(h=>h.id===xt.value)??null:null,_=Be.value?Be.value:p?p.kind==="session"?p.target_id:p.linked_session_id??null:null,u=Ue.value?Ue.value:p?p.kind==="operation"?p.target_id:p.linked_operation_id??null:null,v=_?t.filter(h=>h.session_id===_):u?t.filter(h=>h.linked_operation_id===u):t,g=u?n.filter(h=>h.operation_id===u):_?n.filter(h=>{var S;return h.linked_session_id===_||h.operation_id===((S=v[0])==null?void 0:S.linked_operation_id)}):n,$=_||u?s.filter(h=>(_?h.related_session_id===_:!1)||(u?h.related_operation_id===u:!1)):s,C=_?l.filter(h=>h.related_session_id===_||h.tone!=="ok"):l,b=_?o.filter(h=>v.some(S=>S.member_names.includes(h.agent_name))):o,k=_||u?c.filter(h=>(_?h.related_session_id===_:!1)||(u?h.related_operation_id===u:!1)||h.tone!=="ok"):c;return i`
    <div class="agents-monitor">
      <${ke} surfaceId="execution" />
      <${Ga} />
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
          ${e.length===0?i`<div class="empty-state">지금은 막힌 실행이 없습니다.</div>`:e.map(h=>i`<${G$} key=${h.id} item=${h} selected=${xt.value===h.id} />`)}
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
            ${v.length===0?i`<div class="empty-state">선택된 실행과 연결된 세션이 없습니다.</div>`:v.map(h=>i`<${J$} key=${h.session_id} brief=${h} selected=${Be.value===h.session_id} />`)}
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
            ${g.length===0?i`<div class="empty-state">선택된 실행과 연결된 작전이 없습니다.</div>`:g.map(h=>i`<${Y$} key=${h.operation_id} brief=${h} selected=${Ue.value===h.operation_id} />`)}
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
          <${V$} tick=${a} />
          <div class="monitor-list">
            ${b.length===0?i`<div class="empty-state">최근 lodge check-in 기록이 없습니다.</div>`:b.map(h=>i`<${X$} key=${`${h.agent_name}-${h.checked_at??h.outcome}`} row=${h} />`)}
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
            ${$.length===0?i`<div class="empty-state">연결된 작업자가 없습니다.</div>`:$.map(h=>i`<${Jr} key=${h.name} row=${h} testId="execution.worker-card" />`)}
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
            ${C.length===0?i`<div class="empty-state">지금은 연속성 경고가 없습니다.</div>`:C.map(h=>i`<${Q$} key=${h.name} row=${h} />`)}
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
            ${k.length===0?i`<div class="empty-state">지금은 오프라인 작업자가 없습니다.</div>`:k.map(h=>i`<${Jr} key=${h.name} row=${h} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const so=f(null),ao=f(null),Pn=f(!1);async function Yr(){if(!Pn.value){Pn.value=!0,ao.value=null;try{so.value=await uu()}catch(e){ao.value=e instanceof Error?e.message:String(e)}finally{Pn.value=!1}}}function eh(e){switch(e){case"essential":return"badge-essential";case"standard":return"badge-standard";default:return"badge-full"}}function th({items:e,maxCount:t}){return e.length===0?i`<p class="muted">No tool calls recorded yet.</p>`:i`
    <div class="tool-bar-chart">
      ${e.map(n=>{const s=t>0?n.call_count/t*100:0;return i`
          <div class="tool-bar-row" key=${n.name}>
            <span class="tool-bar-name">${n.name}</span>
            <span class="tool-bar-tier ${eh(n.tier)}">${n.tier}</span>
            <div class="tool-bar-track">
              <div class="tool-bar-fill" style=${{width:`${s}%`}} />
            </div>
            <span class="tool-bar-count">${n.call_count}</span>
          </div>
        `})}
    </div>
  `}function nh({dist:e}){const t=e.full,n=t>0?(e.essential/t*100).toFixed(1):"0",s=t>0?(e.standard/t*100).toFixed(1):"0",a=t-e.standard,o=t>0?(a/t*100).toFixed(1):"0";return i`
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
  `}function sh(){const e=so.value,t=Pn.value,n=ao.value;return ae(()=>{!so.value&&!Pn.value&&Yr()},[]),i`
    <div class="tool-metrics">
      <div class="tool-metrics-header">
        <h3 class="tool-metrics-title">Tool Usage</h3>
        <button
          class="control-btn ghost"
          onClick=${()=>void Yr()}
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
            <${nh} dist=${e.tier_distribution} />
          </div>
          <div class="tool-metrics-section">
            <h4>Top 20 Tools</h4>
            <${th}
              items=${e.top_20}
              maxCount=${e.top_20.length>0?e.top_20[0].call_count:0}
            />
          </div>
        </div>
      `:t?null:i`
        <p class="muted">Click Load to fetch tool usage statistics.</p>
      `}
    </div>
  `}const io=f(null),oo=f(null),En=f(!1),bn=f(""),zs=f("all"),ui=f(!1),pi=f(!1),mi=f(!0),_i=f(!0);async function Vr(){if(!En.value){En.value=!0,oo.value=null;try{io.value=await pu()}catch(e){oo.value=e instanceof Error?e.message:String(e)}finally{En.value=!1}}}function ah(e,t){const n=t.trim().toLowerCase();return n?[e.name,e.description,e.category,e.required_permission??"",e.visibility,e.lifecycle,e.implementationStatus,e.tier,e.canonicalName??"",e.replacement??"",e.reason??"",...e.doc_refs,...e.prompt_hints].join(" ").toLowerCase().includes(n):!0}function Ps(e,t="default"){return i`
    <span
      style=${{fontSize:"11px",color:t==="ok"?"#7dd3fc":t==="warn"?"#fbbf24":"#cbd5e1",background:t==="ok"?"rgba(14, 165, 233, 0.18)":t==="warn"?"rgba(245, 158, 11, 0.18)":"rgba(148, 163, 184, 0.16)",borderRadius:"999px",padding:"2px 8px"}}
    >
      ${e}
    </span>
  `}function ih({item:e}){return i`
    <article class="tool-inventory-row">
      <div class="tool-inventory-head">
        <div>
          <div class="tool-inventory-name">${e.name}</div>
          <div class="tool-inventory-desc">${e.description}</div>
        </div>
        <div class="tool-inventory-badges">
          ${Ps(e.tier,e.tier==="essential"?"ok":e.tier==="standard"?"warn":"default")}
          ${Ps(e.visibility)}
          ${Ps(e.lifecycle,e.lifecycle==="deprecated"?"warn":"default")}
          ${Ps(e.implementationStatus)}
        </div>
      </div>
      <div class="tool-inventory-meta">
        <span>Category: <strong>${e.category}</strong></span>
        <span>Mode: <strong>${e.enabled_in_current_mode?"enabled":"disabled"}</strong></span>
        <span>Direct call: <strong>${e.direct_call_allowed?"allowed":"blocked"}</strong></span>
        <span>Permission: <strong>${e.required_permission??"none"}</strong></span>
      </div>
      ${e.reason?i`<div class="tool-inventory-reason">${e.reason}</div>`:null}
      <div class="tool-inventory-links">
        ${e.canonicalName?i`<span>Canonical: <strong>${e.canonicalName}</strong></span>`:null}
        ${e.replacement?i`<span>Replacement: <strong>${e.replacement}</strong></span>`:null}
        ${e.doc_refs.length>0?i`<span>Docs: <strong>${e.doc_refs.join(", ")}</strong></span>`:null}
      </div>
    </article>
  `}function oh(){const e=io.value,t=En.value,n=oo.value,s=(e==null?void 0:e.tool_inventory.tools)??[],a=(e==null?void 0:e.tool_usage)??null;ae(()=>{!io.value&&!En.value&&Vr()},[]),ae(()=>{var $;if(O.value.tab!=="tools")return;const g=($=O.value.params.q)==null?void 0:$.trim();g&&g!==bn.value&&(bn.value=g)},[O.value.tab,O.value.params.q]);const o=Array.from(new Set(s.map(g=>g.category))).sort((g,$)=>g.localeCompare($)),l=s.filter(g=>!(!ah(g,bn.value)||zs.value!=="all"&&g.category!==zs.value||ui.value&&!g.enabled_in_current_mode||pi.value&&!g.direct_call_allowed||!mi.value&&g.visibility==="hidden"||!_i.value&&g.lifecycle==="deprecated")),c=s.length,p=s.filter(g=>g.enabled_in_current_mode).length,_=s.filter(g=>g.visibility==="hidden").length,u=s.filter(g=>g.lifecycle==="deprecated").length,v=s.filter(g=>g.direct_call_allowed).length;return i`
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
            value=${bn.value}
            onInput=${g=>{bn.value=g.target.value}}
          />
          <select
            class="control-select"
            value=${zs.value}
            onChange=${g=>{zs.value=g.target.value}}
          >
            <option value="all">All categories</option>
            ${o.map(g=>i`<option value=${g}>${g}</option>`)}
          </select>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${ui.value}
              onChange=${g=>{ui.value=g.target.checked}}
            />
            <span>Enabled only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${pi.value}
              onChange=${g=>{pi.value=g.target.checked}}
            />
            <span>Direct-call only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${mi.value}
              onChange=${g=>{mi.value=g.target.checked}}
            />
            <span>Show hidden</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${_i.value}
              onChange=${g=>{_i.value=g.target.checked}}
            />
            <span>Show deprecated</span>
          </label>
          <button class="control-btn ghost" onClick=${()=>{Vr()}} disabled=${t}>
            ${t?"Refreshing…":"Refresh inventory"}
          </button>
        </div>

        ${n?i`<div class="tool-metrics-error">${n}</div>`:null}

        <div class="tool-inventory-list">
          ${l.length>0?l.map(g=>i`<${ih} key=${g.name} item=${g} />`):i`<div class="empty-state">No tools matched the current filters.</div>`}
        </div>
      <//>

      <${R} title="Tool Usage" class="section">
        ${a?i`
              <div class="tool-inventory-usage-hint">
                Registered ${a.registered_count} · Distinct called ${a.distinct_tools_called} · Never called ${a.never_called_count}
              </div>
            `:null}
        <${sh} />
      <//>
    </div>
  `}const Ea=f("all"),ja=f("all"),ro=f(new Set);function rh(e){const t=new Set(ro.value);t.has(e)?t.delete(e):t.add(e),ro.value=t}const pd=Me(()=>{let e=Yt.value;return Ea.value!=="all"&&(e=e.filter(t=>t.horizon===Ea.value)),ja.value!=="all"&&(e=e.filter(t=>t.status===ja.value)),e}),lh=Me(()=>{const e={short:[],mid:[],long:[]};for(const t of pd.value){const n=e[t.horizon];n&&n.push(t)}return e}),ch=Me(()=>{const e=Array.from(Nl.value.values());return e.sort((t,n)=>t.status==="running"&&n.status!=="running"?-1:n.status==="running"&&t.status!=="running"?1:t.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&t.status!=="interrupted"?1:n.elapsed_seconds-t.elapsed_seconds),e});function dh(e){return"★".repeat(Math.min(e,5))+"☆".repeat(Math.max(0,5-e))}function Zo(e){switch(e){case"short":return"단기";case"mid":return"중기";case"long":return"장기";default:return e}}function Zs(e){switch(e){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function uh(e){return e<60?`${Math.round(e)}s`:e<3600?`${Math.floor(e/60)}m ${Math.round(e%60)}s`:`${Math.floor(e/3600)}h ${Math.floor(e%3600/60)}m`}function Xr(e){return e.toFixed(4)}function Qr(e){const t=e.current_metric-e.baseline_metric;return`${t>=0?"+":""}${t.toFixed(4)}`}function ph(e){switch(e){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function mh(e){switch(e){case"active":return"진행 중";case"completed":return"완료";case"paused":return"일시정지";default:return"전체"}}function Zr(e,t){return(e.priority??4)-(t.priority??4)}function _h(e,t){const n=e.updated_at??e.created_at??"";return(t.updated_at??t.created_at??"").localeCompare(n)}function vh(e,t){return e.length<=t?e:e.slice(0,t)+"..."}function gh({goal:e}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Zs(e.horizon)}">
            ${Zo(e.horizon)}
          </span>
          <span class="goal-title">${e.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${e.priority}">${dh(e.priority)}</span>
          ${e.metric?i`<span class="goal-metric">${e.metric}${e.target_value?` → ${e.target_value}`:""}</span>`:null}
          ${e.due_date?i`<span class="goal-due">Due: <${X} timestamp=${e.due_date} /></span>`:null}
        </div>
        ${e.last_review_note?i`
          <div class="goal-review-note">${e.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${gt} status=${e.status} />
        <div class="goal-updated">
          <${X} timestamp=${e.updated_at} />
        </div>
      </div>
    </div>
  `}function vi({horizon:e,items:t}){if(t.length===0)return null;const n=[...t].sort((s,a)=>a.priority-s.priority);return i`
    <${R} title="${Zo(e)} 목표 (${t.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${gh} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function fh(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">범위</label>
        ${["all","short","mid","long"].map(e=>i`
          <button
            class="goal-filter-btn ${Ea.value===e?"active":""}"
            onClick=${()=>{Ea.value=e}}
          >
            ${e==="all"?"전체":Zo(e)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">상태</label>
        ${["all","active","completed","paused"].map(e=>i`
          <button
            class="goal-filter-btn ${ja.value===e?"active":""}"
            onClick=${()=>{ja.value=e}}
          >
            ${mh(e)}
          </button>
        `)}
      </div>
    </div>
  `}function $h(){const e=Yt.value,t=e.filter(a=>a.status==="active").length,n=e.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of e)a.horizon in s&&s[a.horizon]++;return i`
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
        <div class="goal-summary-value" style="color:${Zs("short")}">${s.short}</div>
        <div class="goal-summary-label">단기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Zs("mid")}">${s.mid}</div>
        <div class="goal-summary-label">중기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Zs("long")}">${s.long}</div>
        <div class="goal-summary-label">장기</div>
      </div>
    </div>
  `}function hh({loop:e}){const t=e.history[0],n=e.latest_tool_names&&e.latest_tool_names.length>0?`${e.latest_tool_call_count??e.latest_tool_names.length}개 도구: ${e.latest_tool_names.join(", ")}`:"아직 근거 없음";return i`
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
          <span>Baseline ${Xr(e.baseline_metric)}</span>
          <span>현재 ${Xr(e.current_metric)}</span>
          <span class=${Qr(e).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Qr(e)}
          </span>
          <span>Elapsed ${uh(e.elapsed_seconds)}</span>
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
  `}function gi({task:e}){const t=e.priority??4,n=t<=1?"p1":t===2?"p2":t===3?"p3":"p4",s=ro.value.has(e.id),a=!!e.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${ph(t)}</span>
        <div class="kanban-card-title">${e.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>rh(e.id)}
        >
          ${s?e.description:vh(e.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${e.created_at?i`<${X} timestamp=${e.created_at} />`:i`<span>-</span>`}
        ${e.assignee?i`<span class="kanban-assignee">${e.assignee}</span>`:null}
      </div>
    </div>
  `}function yh(){const{todo:e,inProgress:t,done:n}=Ol.value,s=[...e].sort(Zr),a=[...t].sort(Zr),o=[...n].sort(_h);return i`
    <${R} title="태스크 백로그" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>할 일</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">대기 중인 태스크가 없습니다</div>`:s.map(l=>i`<${gi} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>진행 중</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">진행 중인 태스크가 없습니다</div>`:a.map(l=>i`<${gi} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>완료</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">완료된 태스크가 없습니다</div>`:o.slice(0,20).map(l=>i`<${gi} key=${l.id} task=${l} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...외 ${o.length-20}개 더 있음</div>`:null}
        </div>
      </div>
    <//>
  `}function bh(){const{todo:e,inProgress:t,done:n}=Ol.value,s=e.length+t.length+n.length,a=[...e,...t].filter(u=>(u.priority??4)<=2).length,o=lh.value,l=ch.value,c=Yt.value.length>0,p=l.length>0,_=xo.value;return i`
    <div>
      <${ke} surfaceId="planning" />

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
          onClick=${()=>{Ao(),Hl()}}
          disabled=${An.value||In.value}
        >
          ${An.value||In.value?"새로고침 중...":"계획 데이터 새로고침"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${yh} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          목표 파이프라인
          <span class="monitor-pill">${Yt.value.length}</span>
        </summary>
        <div>
          ${c?i`
            <${$h} />
            <${fh} />
            ${An.value&&Yt.value.length===0?i`<div class="loading-indicator">목표 불러오는 중...</div>`:pd.value.length===0?i`<div class="empty-state">현재 필터에 맞는 목표가 없습니다</div>`:i`
                    <${vi} horizon="short" items=${o.short??[]} />
                    <${vi} horizon="mid" items=${o.mid??[]} />
                    <${vi} horizon="long" items=${o.long??[]} />
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
          ${In.value&&l.length===0?i`<div class="loading-indicator">MDAL 루프 불러오는 중...</div>`:l.length===0&&(_==="error"||Vt.value)?i`<div class="empty-state">MDAL 스냅샷을 불러오지 못했습니다${Vt.value?`: ${Vt.value}`:""}. 백엔드 상태를 확인하세요.</div>`:l.length===0?i`<div class="empty-state">가동 중인 루프가 없습니다. <code>masc_mdal_start</code>로 시작할 수 있습니다.</div>`:i`
                  <div class="planning-loop-list">
                    ${l.map(u=>i`<${hh} key=${u.loop_id} loop=${u} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const Na=f(!1),jn=f(!1),Gt=f(!1),mt=f(""),Nn=f(""),lo=f("open"),De=f(null),ns=f(null),Da=f(null),Oa=f(null),co=f(!1);function ss(e){return`${e.kind}:${e.id}`}function er(){var n;const e=ns.value,t=((n=De.value)==null?void 0:n.items)??[];return e?t.find(s=>ss(s)===e)??null:null}function kh(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");return(t==null?void 0:t.trim())||"dashboard"}function xh(e){const t=e.trim().toLowerCase();return t==="open"||t==="pending"}function md(e){return!!(e.judgment_summary&&e.judgment_summary.trim())}function _d(e){switch(lo.value){case"needs_quorum":return e.filter(t=>t.kind==="consensus"&&(t.votes??0)<(t.quorum??0));case"ready":return e.filter(t=>{var n;return(n=t.guardrail_state)==null?void 0:n.ready_to_execute});case"needs_approval":return e.filter(t=>{var n,s;return((n=t.guardrail_state)==null?void 0:n.requires_human_gate)||!!((s=t.guardrail_state)!=null&&s.pending_confirm)});case"judge_offline":return e.filter(t=>!md(t));case"open":default:return e.filter(t=>xh(t.status))}}function Sh(e){if(e==null)return"없음";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Xa(e){const t=(e||"").toLowerCase();return t.includes("reject")||t.includes("deny")||t.includes("closed")||t.includes("cancel")?"negative":t.includes("approve")||t.includes("support")||t.includes("open")||t.includes("ready")?"positive":"neutral"}function Ch(e){return typeof e!="number"||Number.isNaN(e)?"확인 필요":`${Math.round(e*100)}%`}function kn(e){return"resolved_tool"in e||"payload_preview"in e||"reason"in e}async function vd(e){if(Da.value=null,Oa.value=null,!!e){co.value=!0,mt.value="";try{e.kind==="debate"?Da.value=await ap(e.id):Oa.value=await ip(e.id)}catch(t){mt.value=t instanceof Error?t.message:"거버넌스 상세를 불러오지 못했습니다"}finally{co.value=!1}}}async function Ah(e){ns.value=ss(e),await vd(e)}async function pn(){var e;Na.value=!0,mt.value="";try{const t=await au();De.value=t;const n=_d(t.items??[]),s=ns.value,a=n.find(o=>ss(o)===s)??n[0]??((e=t.items)==null?void 0:e[0])??null;ns.value=a?ss(a):null,await vd(a)}catch(t){mt.value=t instanceof Error?t.message:"거버넌스 상태를 불러오지 못했습니다"}finally{Na.value=!1}}vm(pn);async function el(){const e=Nn.value.trim();if(e){jn.value=!0;try{const t=await sp(e);Nn.value="",N(t!=null&&t.id?`토론을 시작했습니다: ${t.id}`:"토론을 시작했습니다","success"),await pn()}catch(t){const n=t instanceof Error?t.message:"토론 시작에 실패했습니다";mt.value=n,N(n,"error")}finally{jn.value=!1}}}async function tl(e){var o,l;const t=er(),n=(o=t==null?void 0:t.guardrail_state)==null?void 0:o.pending_confirm,s=n==null?void 0:n.confirm_token;if(!s)return;const a=((l=n==null?void 0:n.actor)==null?void 0:l.trim())||kh();Gt.value=!0;try{await fl(a,s,e),N(e==="confirm"?"액션을 승인했습니다":"액션을 거부했습니다","success"),await pn()}catch(c){const p=c instanceof Error?c.message:"대기 중인 액션 처리에 실패했습니다";mt.value=p,N(p,"error")}finally{Gt.value=!1}}function Ih(){var n,s,a,o,l,c;const e=(n=De.value)==null?void 0:n.summary,t=(s=De.value)==null?void 0:s.judge;return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">열린 토론</span>
        <strong>${(e==null?void 0:e.debates_open)??((o=(a=De.value)==null?void 0:a.debates)==null?void 0:o.length)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">합의 세션</span>
        <strong>${(e==null?void 0:e.sessions_active)??((c=(l=De.value)==null?void 0:l.sessions)==null?void 0:c.length)??0}</strong>
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
  `}function Th(){return i`
    <${R} title="거버넌스 콘솔" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="토론 주제를 입력하세요..."
            value=${Nn.value}
            onInput=${e=>{Nn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&el()}}
            disabled=${jn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${el}
            disabled=${jn.value||Nn.value.trim()===""}
          >
            ${jn.value?"시작 중...":"토론 시작"}
          </button>
          <button class="control-btn ghost" onClick=${pn} disabled=${Na.value}>
            ${Na.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
        <div class="governance-filter-row">
          ${[["open","열림"],["needs_quorum","정족수 부족"],["ready","준비됨"],["needs_approval","승인 필요"],["judge_offline","판정기 오프라인"]].map(([e,t])=>i`
            <button
              class="control-btn ${lo.value===e?"is-active":"ghost"}"
              onClick=${async()=>{lo.value=e,await pn()}}
            >
              ${t}
            </button>
          `)}
        </div>
        ${mt.value?i`<div class="council-error">${mt.value}</div>`:null}
      </div>
    <//>
  `}function Rh(){var t;const e=_d(((t=De.value)==null?void 0:t.items)??[]);return i`
    <${R} title="의사결정 수신함" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${e.length===0?i`
              <div class="empty-state">
                지금 필터에 맞는 토론이나 합의 세션이 없습니다.
              </div>
            `:e.map(n=>{var a,o;const s=ns.value===ss(n);return i`
                <button
                  class="council-row governance-decision-row ${s?"selected":""}"
                  onClick=${()=>Ah(n)}
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
                      ${(a=n.guardrail_state)!=null&&a.requires_human_gate?i`<span class="governance-chip warn">승인 필요</span>`:null}
                      ${(o=n.guardrail_state)!=null&&o.ready_to_execute?i`<span class="governance-chip ok">준비됨</span>`:null}
                      ${n.kind==="consensus"&&(n.votes??0)<(n.quorum??0)?i`<span class="governance-chip warn">정족수 부족</span>`:null}
                      ${md(n)?null:i`<span class="governance-chip dim">판정기 오프라인</span>`}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${Xa(n.status)}">${n.status}</span>
                    ${n.kind==="consensus"?i`<span class="governance-vote-meter">${n.votes??0}/${n.quorum??0}</span>`:i`<span class="governance-vote-meter">${n.evidence_refs.length} refs</span>`}
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function Mh({argument:e}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${Xa(e.position)}">${e.position}</span>
        <strong>${e.agent}</strong>
        ${e.created_at?i`<span><${X} timestamp=${e.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.content}</div>
      <div class="governance-chip-row">
        ${e.evidence.map(t=>i`<span class="governance-chip">${t}</span>`)}
        ${e.reply_to!=null?i`<span class="governance-chip">답글 #${e.reply_to}</span>`:null}
        ${e.mentions.map(t=>i`<span class="governance-chip">@${t}</span>`)}
        ${e.archetype?i`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function Lh({vote:e}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${Xa(e.decision)}">${e.decision}</span>
        <strong>${e.agent}</strong>
        ${e.timestamp?i`<span><${X} timestamp=${e.timestamp} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.reason||"기록된 이유가 없습니다."}</div>
      <div class="governance-chip-row">
        ${e.weight!=null?i`<span class="governance-chip">가중치 ${e.weight}</span>`:null}
        ${e.archetype?i`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function zh(){const e=er(),t=Da.value,n=Oa.value;return i`
    <${R}
      title=${e?`${e.kind==="debate"?"토론":"합의"} 상세`:"의사결정 상세"}
      class="section"
      semanticId="governance.detail"
    >
      ${co.value?i`<div class="loading-indicator">거버넌스 상세 불러오는 중...</div>`:e?e.kind==="debate"&&t?i`
                <div class="governance-detail-head">
                  <div>
                    <h3>${t.debate.topic}</h3>
                    <div class="council-sub">
                      <span>${t.debate.id}</span>
                      <span>${t.debate.status}</span>
                      ${t.debate.created_at?i`<span><${X} timestamp=${t.debate.created_at} /></span>`:null}
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
                  ${t.arguments.length===0?i`<div class="empty-state">기록된 토론이 아직 없습니다.</div>`:t.arguments.map(s=>i`<${Mh} key=${s.index} argument=${s} />`)}
                </div>
              `:e.kind==="consensus"&&n?i`
                  <div class="governance-detail-head">
                    <div>
                      <h3>${n.session.topic}</h3>
                      <div class="council-sub">
                        <span>${n.session.id}</span>
                        <span>${n.session.state}</span>
                      <span>시작자 ${n.session.initiator}</span>
                        ${n.session.created_at?i`<span><${X} timestamp=${n.session.created_at} /></span>`:null}
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
                    ${n.votes.length===0?i`<div class="empty-state">기록된 표결이 아직 없습니다.</div>`:n.votes.map(s=>i`<${Lh} key=${s.agent+s.timestamp} vote=${s} />`)}
                  </div>
                `:i`<div class="empty-state">이 의사결정의 상세를 아직 읽을 수 없습니다.</div>`:i`<div class="empty-state">사실 계층과 판단을 보려면 의사결정 항목을 고르세요.</div>`}
    <//>
  `}function nl({title:e,route:t}){if(!t)return null;const n=kn(t)?t.resolved_tool:t.delegated_tool,s=kn(t)?t.target_type:null,a=kn(t)?t.target_id:null,o=kn(t)?t.reason:null,l=kn(t)?t.payload_preview:null;return i`
    <div class="governance-side-block">
      <h4>${e}</h4>
      <div class="council-sub">
        ${n?i`<span>도구 ${n}</span>`:null}
        ${"action_type"in t&&t.action_type?i`<span>액션 ${t.action_type}</span>`:null}
        ${"confirmation_state"in t&&t.confirmation_state?i`<span>${t.confirmation_state}</span>`:null}
        ${"created_at"in t&&t.created_at?i`<span><${X} timestamp=${t.created_at} /></span>`:null}
      </div>
      ${s?i`<div class="governance-side-line">대상 ${s}${a?`:${a}`:""}</div>`:null}
      ${o?i`<div class="governance-side-line">${o}</div>`:null}
      ${l?i`<pre class="council-detail governance-preview">${Sh(l)}</pre>`:null}
    </div>
  `}function Ph(){var c,p,_;const e=er(),t=Da.value,n=Oa.value,s=(t==null?void 0:t.context)??(n==null?void 0:n.context)??(e==null?void 0:e.context),a=(t==null?void 0:t.judgment)??(n==null?void 0:n.judgment),o=e==null?void 0:e.guardrail_state,l=(c=De.value)==null?void 0:c.judge;return i`
    <div class="governance-side-column">
      <${R} title="이유 / 가드레일" class="section" semanticId="governance.guardrail">
        ${e?i`
              <div class="governance-side-block">
                <h4>판정기</h4>
                <div class="council-sub">
                  <span>${l!=null&&l.judge_online?"온라인":"오프라인"}</span>
                  ${l!=null&&l.model_used?i`<span>${l.model_used}</span>`:null}
                  ${l!=null&&l.generated_at?i`<span><${X} timestamp=${l.generated_at} /></span>`:null}
                </div>
                ${e.judgment_summary?i`<div class="governance-summary-callout">${e.judgment_summary}</div>`:i`<div class="governance-side-line">현재 LLM 판단이 없어 사실 계층만 보여줍니다.</div>`}
                <div class="council-sub">
                  <span>신뢰도 ${Ch(e.confidence)}</span>
                  ${a!=null&&a.keeper_name?i`<span>${a.keeper_name}</span>`:null}
                </div>
              </div>

              <${nl} title="추천 경로" route=${e.recommended_action} />
              <${nl} title="실행된 경로" route=${e.executed_route} />

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
                          onClick=${()=>tl("confirm")}
                          disabled=${Gt.value}
                        >
                          ${Gt.value?"처리 중...":"승인"}
                        </button>
                        <button
                          class="control-btn ghost"
                          onClick=${()=>tl("deny")}
                          disabled=${Gt.value}
                        >
                          ${Gt.value?"처리 중...":"거부"}
                        </button>
                      </div>
                    `:i`<div class="governance-side-line">이 의사결정에 대기 중인 사람 승인은 없습니다.</div>`}
              </div>
            `:i`<div class="empty-state">판단과 경로를 보려면 의사결정을 고르세요.</div>`}
      <//>

      <${R} title="맥락" class="section" semanticId="governance.context">
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

      <${R} title="최근 활동" class="section" semanticId="governance.activity">
        <div class="governance-activity-list">
          ${(((p=De.value)==null?void 0:p.activity)??[]).slice(0,8).map(u=>i`
            <div class="governance-activity-row">
              <div class="governance-ledger-head">
                <span class="governance-badge ${Xa(u.kind)}">${u.kind}</span>
                ${u.actor?i`<strong>${u.actor}</strong>`:null}
                ${u.created_at?i`<span><${X} timestamp=${u.created_at} /></span>`:null}
              </div>
              <div class="governance-ledger-body">${u.summary||u.topic||"활동이 기록되었습니다."}</div>
            </div>
          `)}
          ${(((_=De.value)==null?void 0:_.activity)??[]).length===0?i`<div class="empty-state">기록된 거버넌스 활동이 없습니다.</div>`:null}
        </div>
      <//>
    </div>
  `}function Eh(){return ae(()=>{pn()},[]),i`
    <div>
      <${ke} surfaceId="governance" />
      <${Ih} />
      <${Th} />
      <div class="governance-layout">
        <${Rh} />
        <${zh} />
        <${Ph} />
      </div>
    </div>
  `}const qt=f(""),fi=f("ability_check"),$i=f("10"),hi=f("12"),Es=f(""),js=f("idle"),et=f(""),Ns=f("keeper-late"),yi=f("player"),bi=f(""),Se=f("idle"),ki=f(null),Ds=f(""),xi=f(""),Si=f("player"),Ci=f(""),Ai=f(""),Ii=f(""),Dn=f("20"),Ti=f("20"),Ri=f(""),Os=f("idle"),uo=f(null),gd=f("overview"),Mi=f("all"),Li=f("all"),zi=f("all"),jh=12e4,Qa=f(null),sl=f(Date.now());function Nh(e,t){const n=t>0?e/t*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Dh(e,t){return t>0?Math.round(e/t*100):0}const Oh={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},qh={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function qs(e){const t=e.trim();return t?t.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):e}function Fh(e){const t=e.trim().toLowerCase();return Oh[t]??"행동 선택 가중치에 영향을 주는 성향입니다."}function wh(e){const t=e.trim().toLowerCase();return qh[t]??"상황에 따라 선택되는 전술 액션입니다."}function he(e,t,n=""){const s=e[t];return typeof s=="string"?s:n}function Ee(e,t,n=0){const s=e[t];return typeof s=="number"&&Number.isFinite(s)?s:n}function as(e,t,n=!1){const s=e[t];return typeof s=="boolean"?s:n}const Kh=new Set(["str","dex","con","int","wis","cha"]);function Bh(e){const t=e.trim();if(!t)return{};let n;try{n=JSON.parse(t)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!m(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const l=a.trim();if(l){if(typeof o=="number"&&Number.isFinite(o)){s[l]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const c=Number.parseFloat(o.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function Uh(e){const t=Number.parseInt(e.trim(),10);if(!Number.isFinite(t))return;const n=Math.max(1,t),s=Number.parseInt(Dn.value.trim(),10);Number.isFinite(s)&&s>n&&(Dn.value=String(n))}function po(e){const n=(e.actor_name??e.actor??e.actor_id??"system").trim();return n===""?"system":n}function Hh(e){var n;return(((n=e.timestamp)==null?void 0:n.trim())??"")||"-"}function Wh(e){gd.value=e}function fd(e){const t=Qa.value;return t==null||t<=e}function Gh(e){const t=Qa.value;return t==null||t<=e?0:Math.max(0,Math.ceil((t-e)/1e3))}function qa(){Qa.value=null}function $d(e){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(e)}function Jh(e,t){$d(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${e||"-"}`,`PHASE: ${t||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Qa.value=Date.now()+jh,N("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function ea(e){return fd(e)?(N("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function mo(e,t,n){return $d([`[위험 액션 확인] ${e}`,`ROOM: ${t||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Yh({hp:e,max:t}){const n=Dh(e,t),s=Nh(e,t);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Vh({stats:e}){const t=[{label:"STR",value:e.strength},{label:"DEX",value:e.dexterity},{label:"CON",value:e.constitution},{label:"INT",value:e.intelligence},{label:"WIS",value:e.wisdom},{label:"CHA",value:e.charisma}];return i`
    <div class="trpg-actor-stats">
      ${t.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Xh({keeper:e,role:t}){if(!e)return null;const n=t==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${e}
    </span>
  `}function hd({actor:e}){var p,_,u,v;const t=(p=e.archetype)==null?void 0:p.trim(),n=(_=e.persona)==null?void 0:_.trim(),s=(u=e.portrait)==null?void 0:u.trim(),a=(v=e.background)==null?void 0:v.trim(),o=e.traits??[],l=e.skills??[],c=Object.entries(e.stats_raw??{}).filter(([g,$])=>Number.isFinite($)).filter(([g])=>!Kh.has(g.toLowerCase()));return i`
    <div class="trpg-actor">
      ${s?i`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${e.name} portrait`}
              loading="lazy"
              onError=${g=>{const $=g.target;$&&($.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${e.name}</span>
        <${gt} status=${e.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${e.role}">${e.role}</span>
        <${Xh} keeper=${e.keeper} role=${e.role} />
      </div>
      ${e.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${e.stats.hp}/${e.stats.max_hp}
              ${e.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${e.stats.mp}/${e.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${e.stats.level}</span>
            </div>
            <${Yh} hp=${e.stats.hp} max=${e.stats.max_hp} />
            <${Vh} stats=${e.stats} />
          </div>
        `:null}
      ${t?i`<div class="trpg-actor-meta">Archetype: ${qs(t)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([g,$])=>i`
                <span class="trpg-custom-stat-chip">${qs(g)} ${$}</span>
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
                  <span class="trpg-annot-name">${qs(g)}</span>
                  <span class="trpg-annot-desc">${Fh(g)}</span>
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
                  <span class="trpg-annot-name">${qs(g)}</span>
                  <span class="trpg-annot-desc">${wh(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Qh({mapStr:e}){return i`<pre class="trpg-map">${e}</pre>`}function yd({events:e,emptyLabel:t="아직 이벤트가 없습니다."}){return e.length===0?i`<div class="empty-state" style="font-size:13px">${t}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${e.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Hh(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${po(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${X} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Zh({events:e}){const t="__none__",n=Mi.value,s=Li.value,a=zi.value,o=Array.from(new Set(e.map(po).map(v=>v.trim()).filter(v=>v!==""))).sort((v,g)=>v.localeCompare(g)),l=Array.from(new Set(e.map(v=>(v.type??"").trim()).filter(v=>v!==""))).sort((v,g)=>v.localeCompare(g)),c=e.some(v=>(v.type??"").trim()===""),p=Array.from(new Set(e.map(v=>(v.phase??"").trim()).filter(v=>v!==""))).sort((v,g)=>v.localeCompare(g)),_=e.some(v=>(v.phase??"").trim()===""),u=e.filter(v=>{if(n!=="all"&&po(v)!==n)return!1;const g=(v.type??"").trim(),$=(v.phase??"").trim();if(s===t){if(g!=="")return!1}else if(s!=="all"&&g!==s)return!1;if(a===t){if($!=="")return!1}else if(a!=="all"&&$!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${v=>{Mi.value=v.target.value}}>
          <option value="all">all</option>
          ${o.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${v=>{Li.value=v.target.value}}>
          <option value="all">all</option>
          ${c?i`<option value=${t}>(none)</option>`:null}
          ${l.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${v=>{zi.value=v.target.value}}>
          <option value="all">all</option>
          ${_?i`<option value=${t}>(none)</option>`:null}
          ${p.map(v=>i`<option value=${v}>${v}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Mi.value="all",Li.value="all",zi.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${u.length} / 전체 ${e.length}
      </span>
    </div>
    <${yd} events=${u.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function ey({outcome:e}){if(!e)return null;const t=o=>{const l=o.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=e.result==="victory"?"승리":e.result==="defeat"?"패배":e.result==="draw"?"무승부":"종료",s=e.result==="victory"?"#34d399":e.result==="defeat"?"#f87171":"#9ca3af",a=[e.reason?`원인: ${t(e.reason)}`:null,e.phase?`페이즈: ${t(e.phase)}`:null,typeof e.turn=="number"?`턴: ${e.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${e.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${t(e.summary)}</div>`:null}
      ${a?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function bd({state:e}){const t=e.history??[];return t.length===0?null:i`
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
  `}function ty({state:e,nowMs:t}){var _;const n=We.value||((_=e.session)==null?void 0:_.room)||"",s=js.value,a=e.party??[];if(!a.find(u=>u.id===qt.value)&&a.length>0){const u=a[0];u&&(qt.value=u.id)}const l=async()=>{var v,g;if(!n){N("Room ID가 비어 있습니다.","error");return}if(!ea(t))return;const u=((v=e.current_round)==null?void 0:v.phase)??((g=e.session)==null?void 0:g.status)??"unknown";if(mo("라운드 실행",n,u)){js.value="running";try{const $=await Wu(n);uo.value=$,js.value="ok";const C=m($.summary)?$.summary:null,b=C?as(C,"advanced",!1):!1,k=C?he(C,"progress_reason",""):"";N(b?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${k?`: ${k}`:""}`,b?"success":"warning"),ot()}catch($){uo.value=null,js.value="error";const C=$ instanceof Error?$.message:"라운드 실행에 실패했습니다.";N(C,"error")}finally{qa()}}},c=async()=>{var v,g;if(!n||!ea(t))return;const u=((v=e.current_round)==null?void 0:v.phase)??((g=e.session)==null?void 0:g.status)??"unknown";if(mo("턴 강제 진행",n,u))try{await Yu(n),N("턴을 다음 단계로 이동했습니다.","success"),ot()}catch{N("턴 이동에 실패했습니다.","error")}finally{qa()}},p=async()=>{if(!n||!ea(t))return;const u=qt.value.trim();if(!u){N("먼저 Actor를 선택하세요.","warning");return}const v=Number.parseInt($i.value,10),g=Number.parseInt(hi.value,10);if(Number.isNaN(v)||Number.isNaN(g)){N("stat/dc는 숫자여야 합니다.","warning");return}const $=Number.parseInt(Es.value,10),C=Es.value.trim()===""||Number.isNaN($)?void 0:$;try{await Ju({roomId:n,actorId:u,action:fi.value.trim()||"ability_check",statValue:v,dc:g,rawD20:C}),N("주사위 판정을 기록했습니다.","success"),ot()}catch{N("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${u=>{We.value=u.target.value}}
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
              value=${fi.value}
              onInput=${u=>{fi.value=u.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${$i.value}
              onInput=${u=>{$i.value=u.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${hi.value}
              onInput=${u=>{hi.value=u.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Es.value}
              onInput=${u=>{Es.value=u.target.value}}
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
  `}function ny({state:e}){var a;const t=We.value||((a=e.session)==null?void 0:a.room)||"",n=Os.value,s=async()=>{if(!t){N("Room ID가 비어 있습니다.","warning");return}const o=Ds.value.trim(),l=xi.value.trim();if(!l&&!o){N("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Dn.value.trim(),10),p=Number.parseInt(Ti.value.trim(),10),_=Number.isFinite(p)?Math.max(1,p):20,u=Number.isFinite(c)?Math.max(0,Math.min(_,c)):_;let v={};try{v=Bh(Ri.value)}catch(g){N(g instanceof Error?g.message:"능력치 JSON 오류","error");return}Os.value="spawning";try{const g=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,$=await Vu(t,{actor_id:o||void 0,name:l||void 0,role:Si.value,idempotencyKey:g,portrait:Ai.value.trim()||void 0,background:Ii.value.trim()||void 0,hp:u,max_hp:_,alive:u>0,stats:Object.keys(v).length>0?v:void 0}),C=typeof $.actor_id=="string"?$.actor_id.trim():"";if(!C)throw new Error("생성 응답에 actor_id가 없습니다.");const b=Ci.value.trim();b&&await Xu(t,C,b),qt.value=C,et.value=C,o||(Ds.value=""),Os.value="ok",N(`Actor 생성 완료: ${C}`,"success"),await ot()}catch(g){Os.value="error",N(g instanceof Error?g.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${xi.value}
            onInput=${o=>{xi.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Si.value}
            onChange=${o=>{Si.value=o.target.value}}
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
            value=${Ci.value}
            onInput=${o=>{Ci.value=o.target.value}}
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
              value=${Ds.value}
              onInput=${o=>{Ds.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Ai.value}
              onInput=${o=>{Ai.value=o.target.value}}
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
              value=${Dn.value}
              onInput=${o=>{Dn.value=o.target.value}}
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
              value=${Ti.value}
              onInput=${o=>{const l=o.target.value;Ti.value=l,Uh(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Ii.value}
              onInput=${o=>{Ii.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Ri.value}
              onInput=${o=>{Ri.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function sy({state:e,nowMs:t}){var g;const n=We.value||((g=e.session)==null?void 0:g.room)||"",s=e.join_gate,a=ki.value,o=m(a)?a:null,l=(e.party??[]).filter($=>$.role!=="dm"),c=et.value.trim(),p=l.some($=>$.id===c),_=p?c:c?"__manual__":"",u=async()=>{const $=et.value.trim(),C=Ns.value.trim();if(!n||!$){N("Room/Actor가 필요합니다.","warning");return}Se.value="checking";try{const b=await Qu(n,$,C||void 0);ki.value=b,Se.value="ok",N("참가 가능 여부를 갱신했습니다.","success")}catch(b){Se.value="error";const k=b instanceof Error?b.message:"참가 가능 여부 확인에 실패했습니다.";N(k,"error")}},v=async()=>{var h,S;const $=et.value.trim(),C=Ns.value.trim(),b=bi.value.trim();if(!n||!$||!C){N("Room/Actor/Keeper가 필요합니다.","warning");return}if(!ea(t))return;const k=((h=e.current_round)==null?void 0:h.phase)??((S=e.session)==null?void 0:S.status)??"unknown";if(mo("Mid-Join 승인 요청",n,k)){Se.value="requesting";try{const L=await Zu({room_id:n,actor_id:$,keeper_name:C,role:yi.value,...b?{name:b}:{}});ki.value=L;const M=m(L)?as(L,"granted",!1):!1,P=m(L)?he(L,"reason_code",""):"";M?N("Mid-Join이 승인되었습니다.","success"):N(`Mid-Join이 거절되었습니다${P?`: ${P}`:""}`,"warning"),Se.value=M?"ok":"error",ot()}catch(L){Se.value="error";const M=L instanceof Error?L.message:"Mid-Join 요청에 실패했습니다.";N(M,"error")}finally{qa()}}};return i`
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
            value=${_}
            onChange=${$=>{const C=$.target.value;if(C==="__manual__"){(p||!c)&&(et.value="");return}et.value=C}}
          >
            <option value="">Actor 선택</option>
            ${l.map($=>i`
              <option value=${$.id}>${$.name} (${$.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${_==="__manual__"?i`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${et.value}
                onInput=${$=>{et.value=$.target.value}}
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
            value=${Ns.value}
            onInput=${$=>{Ns.value=$.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${yi.value}
            onChange=${$=>{yi.value=$.target.value}}
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
            value=${bi.value}
            onInput=${$=>{bi.value=$.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${u} disabled=${Se.value==="checking"||Se.value==="requesting"}>
              ${Se.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${v} disabled=${Se.value==="checking"||Se.value==="requesting"}>
              ${Se.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${as(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Ee(o,"effective_score",0)}/${Ee(o,"required_points",0)}</span>
            ${he(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${he(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function kd({state:e}){const t=[...e.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return t.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${t.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function xd({state:e}){var n;const t=e.current_round;return t?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${t.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${t.phase}</div>
      ${t.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=t.events[t.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Sd(){const e=uo.value;if(!e)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const t=e.summary,n=m(t)?t:null,a=(Array.isArray(e.statuses)?e.statuses:[]).filter(m).slice(-8),o=e.canon_check,l=m(o)?o:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(P=>typeof P=="string").slice(0,3):[],p=l&&Array.isArray(l.violations)?l.violations.filter(P=>typeof P=="string").slice(0,3):[],_=n?as(n,"advanced",!1):!1,u=n?he(n,"progress_reason",""):"",v=n?he(n,"progress_detail",""):"",g=n?Ee(n,"player_successes",0):0,$=n?Ee(n,"player_required_successes",0):0,C=n?as(n,"dm_success",!1):!1,b=n?Ee(n,"timeouts",0):0,k=n?Ee(n,"unavailable",0):0,h=n?Ee(n,"reprompts",0):0,S=n?Ee(n,"npc_attacks",0):0,L=n?Ee(n,"keeper_timeout_sec",0):0,M=n?Ee(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${_?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${_?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${e.turn_before??0} → ${e.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${C?"DM ok":"DM stalled"} / players ${g}/${$}
          </span>
        </div>
        ${u?i`<div style="margin-top:4px; font-size:12px;">${u}</div>`:null}
        ${v?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${v}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${b}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${h}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${L||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${M}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(P=>{const H=he(P,"status","unknown"),T=he(P,"actor_id","-"),W=he(P,"role","-"),Q=he(P,"reason",""),ie=he(P,"action_type",""),E=he(P,"reply","");return i`
                <div class="trpg-round-item ${H.includes("fallback")||H.includes("timeout")?"failed":"active"}">
                  <span>${T} (${W})</span>
                  <span style="margin-left:auto; font-size:11px;">${H}</span>
                  ${ie?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${ie}</div>`:null}
                  ${Q?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${Q}</div>`:null}
                  ${E?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${E.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${he(l,"status","unknown")}</strong>
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
  `}function ay({state:e,nowMs:t}){var l,c,p;const n=We.value||((l=e.session)==null?void 0:l.room)||"",s=((c=e.current_round)==null?void 0:c.phase)??((p=e.session)==null?void 0:p.status)??"unknown",a=fd(t),o=Gh(t);return i`
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
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>Jh(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{qa(),N("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function iy({active:e}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${e===n.id?"active":""}"
          role="tab"
          aria-selected=${e===n.id}
          onClick=${()=>Wh(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function oy({state:e}){const t=e.party??[],n=e.story_log??[];return i`
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
          <${yd} events=${n.slice(-20)} />
        <//>

        ${e.map?i`
            <${R} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${Qh} mapStr=${e.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${R} title="현재 라운드" semanticId="lab.trpg">
          <${xd} state=${e} />
        <//>

        <${R} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${kd} state=${e} />
        <//>

        <${R} title=${`파티 (${t.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${t.map(s=>i`<${hd} key=${s.id??s.name} actor=${s} />`)}
            ${t.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${e.history&&e.history.length>0?i`
            <${R} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
              <${bd} state=${e} />
            <//>
          `:null}
      </div>
    </div>
  `}function ry({state:e}){const t=e.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${R} title=${`이벤트 타임라인 (${t.length})`}>
          <${Zh} events=${t} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${R} title="최근 라운드 결과" semanticId="lab.trpg">
          <${Sd} />
        <//>

        <${R} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${xd} state=${e} />
        <//>
      </div>
    </div>
  `}function ly({state:e,nowMs:t}){const n=e.party??[];return i`
    <div>
      <${ay} state=${e} nowMs=${t} />
      <div class="trpg-layout">
        <div>
          <${R} title="조작 패널" semanticId="lab.trpg">
            <${ty} state=${e} nowMs=${t} />
          <//>

          <${R} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${ny} state=${e} />
          <//>

          <${R} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${sy} state=${e} nowMs=${t} />
          <//>

          <${R} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${Sd} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${R} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${kd} state=${e} />
          <//>

          <${R} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${hd} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${e.history&&e.history.length>0?i`
              <${R} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
                <${bd} state=${e} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function cy(){var c,p,_,u,v;const e=jl.value,t=Ui.value;if(ae(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const g=window.setInterval(()=>{sl.value=Date.now()},1e3);return()=>{window.clearInterval(g)}},[]),t&&!e)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!e)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>ot()}>Refresh</button>
      </div>
    `;const n=e.party??[],s=e.story_log??[],a=e.outcome,o=gd.value,l=sl.value;return i`
    <div>
      <${ke} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${We.value||((c=e.session)==null?void 0:c.room)||"-"} · phase: ${((p=e.current_round)==null?void 0:p.phase)??((_=e.session)==null?void 0:_.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>ot()}>새로고침</button>
      </div>

      <${ey} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((u=e.session)==null?void 0:u.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((v=e.current_round)==null?void 0:v.round_number)??0}</div>
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

      <${iy} active=${o} />

      ${o==="overview"?i`<${oy} state=${e} />`:o==="timeline"?i`<${ry} state=${e} />`:i`<${ly} state=${e} nowMs=${l} />`}
    </div>
  `}function dy(){return i`
    <div>
      <${ke} surfaceId="lab" />
      <${R} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${R} title="TRPG" class="section" semanticId="lab.trpg">
        <${cy} />
      <//>
    </div>
  `}const Fa=f(new Set(["broadcast","tasks","keepers","system"]));function uy(e){const t=new Set(Fa.value);t.has(e)?t.delete(e):t.add(e),Fa.value=t}const tr=f(null);function Cd(e){tr.value=e}function py(e){return e.kind==="board"?"broadcast":e.kind==="tasks"?"tasks":e.kind==="keepers"?"keepers":"system"}const my=Me(()=>{const e=Fa.value;return na.value.filter(t=>e.has(py(t)))}),_y=12e4,vy=Me(()=>{const e=ql.value,t=Date.now();return Ve.value.map(n=>{const s=n.name.trim().toLowerCase(),a=e.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?o=t-new Date(l).getTime()>_y?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),gy=Me(()=>{const e=ql.value;return Ve.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle").map(t=>{const n=t.name.trim().toLowerCase(),s=e.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:t.name,emoji:t.emoji??"",koreanName:t.koreanName??null,currentTask:t.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((t,n)=>{const s={hot:0,normal:1,calm:2};return s[t.pressure]-s[n.pressure]})});function al(e){return e.kind==="board"?"live-event-broadcast":e.kind==="tasks"?"live-event-task":e.kind==="keepers"?"live-event-keeper":"live-event-system"}function fy(e){const t=e.eventType;return t==="broadcast"?"broadcast":t==="agent_joined"?"joined":t==="agent_left"?"left":t==="task_update"?"task":t==="board_post"?"post":t==="board_comment"?"comment":t==="keeper_heartbeat"?"heartbeat":t==="keeper_handoff"?"handoff":t==="keeper_compaction"?"compact":t==="keeper_guardrail"?"guardrail":e.kind==="board"?"board":e.kind==="tasks"?"task":e.kind==="keepers"?"keeper":"system"}function $y(e){switch(e){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function hy(){const e=vy.value,t=tr.value;return e.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${e.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${$y(n.state)} ${t===n.name?"pulse-selected":""}"
          onClick=${()=>Cd(t===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const yy=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function by(){const e=Fa.value;return i`
    <div class="activity-filter-bar">
      ${yy.map(t=>i`
        <button
          key=${t.kind}
          class="activity-filter-btn ${t.cssClass} ${e.has(t.kind)?"active":""}"
          onClick=${()=>uy(t.kind)}
        >
          ${t.label}
        </button>
      `)}
    </div>
  `}function ky(){const e=my.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${e.length} events</span>
      </div>
      <${by} />
      <div class="activity-stream-list">
        ${e.length===0?i`<div class="activity-empty">No events matching filters</div>`:e.map((t,n)=>i`
            <div
              key=${`${t.timestamp}-${n}`}
              class="activity-item ${al(t)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${al(t)}">${fy(t)}</span>
                <span class="activity-agent">${t.agent}</span>
                <span class="activity-time">${Pc(t.timestamp)}</span>
              </div>
              <div class="activity-item-text">${t.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function xy(e){switch(e){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function Sy(e){switch(e){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function Cy(){const e=gy.value,t=tr.value;return i`
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
              onClick=${()=>Cd(t===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${xy(n.pressure)}">
                  ${Sy(n.pressure)}
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
  `}function Ay(){const e=dt.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>라이브 모니터</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${e?"connected":"disconnected"}"></span>
            ${e?"연결됨":"오프라인"}
          </span>
          <span class="live-stat">에이전트 ${Ve.value.length}</span>
          <span class="live-stat">이벤트 ${wa.value}</span>
        </div>
      </div>

      <${hy} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${ky} />
        </div>
        <div class="live-panel-side">
          <${Cy} />
        </div>
      </div>
    </div>
  `}const il=[{id:"observe",label:"관찰",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"맥락",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"개입",description:"개입과 운영 기준 지휘를 실행하는 표면"},{id:"lab",label:"실험",description:"실험적 기능은 메인 operator console 밖으로 분리"}],_o=[{id:"mission",label:"상황판",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"proof",label:"근거",icon:"🔍",group:"observe",description:"협업, 대화, 도구, 근거 기록을 증명 중심으로 읽는 표면"},{id:"execution",label:"실행",icon:"🤖",group:"observe",description:"워커, 태스크, 키퍼 연속성을 분리해서 보는 실행 표면"},{id:"tools",label:"도구",icon:"🧰",group:"observe",description:"시스템 전체 도구 inventory와 사용 통계를 함께 읽는 표면"},{id:"live",label:"라이브",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"계획",icon:"🎯",group:"observe",description:"목표, 지표 루프, 백로그 압력을 읽는 계획 표면"},{id:"memory",label:"메모리",icon:"💬",group:"context",description:"게시글과 댓글로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"거버넌스",icon:"⚖️",group:"context",description:"토론과 표결을 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"개입",icon:"🎮",group:"act",description:"룸, 세션, 키퍼 액션을 실행하는 개입 화면"},{id:"command",label:"지휘",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"실험",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 표면을 메인 콘솔 밖에서 다룹니다"}];function Iy(e){const t=e==null?void 0:e.trim();return t?t.length>10?t.slice(0,10):t:"커밋 정보 없음"}function Te(e,t){return t==="live"?"가동 중":t==="quiet"?"조용함":t==="starting"?"기동 중":t==="idle"?e==="guardian"?"유휴":"대기 중":"비활성"}function Ce(e,t){return i`
    <div class="build-badge-row">
      <span>${e}</span>
      <strong>${t}</strong>
    </div>
  `}function Fs(e,t,n,s,a){return i`
    <div style="padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
      <div class="rail-card-head" style="margin:0;">
        <h3 style="font-size:12px;">${e}</h3>
        <span class="rail-section-chip ${n}">${t}</span>
      </div>
      ${s}
      ${a?i`<div class="rail-build-hint">${a}</div>`:null}
    </div>
  `}function Ty({currentTab:e}){var p,_,u,v,g,$,C,b,k,h;const t=dt.value,n=(p=ge.value)==null?void 0:p.build,s=(_=ge.value)==null?void 0:_.lodge,a=(u=ge.value)==null?void 0:u.gardener,o=(v=ge.value)==null?void 0:v.guardian,l=(g=ge.value)==null?void 0:g.sentinel,c=[];if(s&&c.push(Fs("Lodge",s.enabled?Te("lodge",s.quiet_active?"quiet":"live"):Te("lodge","disabled"),s.enabled?s.quiet_active?"warn":"ok":"bad",[Ce("틱",s.total_ticks??0),Ce("체크인",s.total_checkins??0),Ce("최근 결과",(($=s.last_tick_result)==null?void 0:$.activity_report)??s.last_skip_reason??"없음")])),a&&c.push(Fs("Gardener",a.alive?Te("gardener","live"):a.enabled?Te("gardener","starting"):Te("gardener","disabled"),a.alive?"ok":a.enabled?"warn":"bad",[Ce("최근 tick",a.last_tick_completed_at?i`<${X} timestamp=${a.last_tick_completed_at} />`:"기록 없음"),Ce("판단",`${a.last_intervention??"없음"} · ${a.last_decision_source??"없음"}`),Ce("백로그",`미할당 ${((C=a.health_summary)==null?void 0:C.todo_count)??0} · P1/2 ${((b=a.health_summary)==null?void 0:b.high_priority_todo)??0}`)],a.last_reason??a.last_error??void 0)),o){const S=o.masc_loops_running||o.lodge_loop_started||o.lodge_running;c.push(Fs("Guardian",S?Te("guardian","live"):o.enabled?Te("guardian","idle"):Te("guardian","disabled"),S?"ok":o.enabled?"warn":"bad",[Ce("모드",o.mode??"알 수 없음"),Ce("루프",`zombie ${o.zombie_loop_running?"on":"off"} · gc ${o.gc_loop_running?"on":"off"}`),Ce("소유자",o.runtime_owner??"없음")],((k=o.last_lodge_result)==null?void 0:k.message)??o.last_gc_result??o.last_zombie_result??void 0))}return l&&c.push(Fs("Sentinel",l.started?Te("sentinel","live"):l.enabled?Te("sentinel","starting"):Te("sentinel","disabled"),l.started?"ok":l.enabled?"warn":"bad",[Ce("에이전트",l.agent_name??"sentinel"),Ce("소비자",((h=l.consumers)==null?void 0:h.length)??0),Ce("가디언 소유자",l.guardian_runtime_owner??"없음")],l.llm_enabled===!0?"LLM 기반 housekeeping resident":void 0)),i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${F} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${t?"ok":"bad"}">${t?"연결됨":"오프라인"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>에이전트</span>
          <strong>${Ve.value.length}</strong>
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
          onClick=${()=>{rs(),Bl(),eo(e)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>oe("intervene")}>
          개입 열기
        </button>
      </div>
      ${n?i`<div class="rail-build-hint">서버 빌드 · v${n.release_version} · ${Iy(n.commit)}</div>`:null}
      ${c.length>0?i`
            <div style="margin-top:12px; display:flex; flex-direction:column; gap:10px;">
              ${c}
            </div>
          `:null}
    </section>
  `}function Ry(){const e=Ae.value,t=(e==null?void 0:e.pending_confirms.length)??0,n=(e==null?void 0:e.sessions.length)??0,s=(e==null?void 0:e.keepers.length)??0;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${F} panelId="side_rail.quick_actions" compact=${!0} />
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
          onClick=${()=>{be(),Pt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>oe("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}const ws=f(!1);function My(){const e=dt.value;return i`
    <div class="connection-status ${e?"connected":"disconnected"}">
      <span class="status-dot ${e?"connected":"disconnected"}"></span>
      <span class="status-text">${e?"연결됨":"재연결 중..."}</span>
      <span class="event-count">이벤트 ${wa.value}</span>
    </div>
  `}function Ly(e){const t=e==null?void 0:e.trim();return t?t.length>10?t.slice(0,10):t:"커밋 정보 없음"}function zy(){const e=ge.value,t=e==null?void 0:e.build,n=t?`v${t.release_version} · ${Ly(t.commit)}`:e!=null&&e.version?`v${e.version} · 커밋 정보 없음`:"버전 정보 없음";return i`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${ws.value}
        onClick=${()=>{ws.value=!ws.value}}
      >
        서버 빌드 · ${n}
      </button>
      ${ws.value?i`
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
                <strong>${t!=null&&t.started_at?i`<${X} timestamp=${t.started_at} />`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof(t==null?void 0:t.uptime_seconds)=="number"?`${t.uptime_seconds}s`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${e!=null&&e.generated_at?i`<${X} timestamp=${e.generated_at} />`:"알 수 없음"}</strong>
              </div>
            </div>
          `:null}
    </div>
  `}function Py(){const e=O.value.tab,t=_o.find(s=>s.id===e),n=il.find(s=>s.id===(t==null?void 0:t.group));return i`
    <aside class="dashboard-rail">
      <${ke} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${F} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${il.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${_o.filter(a=>a.group===s.id).map(a=>i`
                  <button
                    class="rail-tab-btn ${e===a.id?"active":""}"
                    onClick=${()=>oe(a.id)}
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

      <${Ty} currentTab=${e} />
      <${Ry} />
    </aside>
  `}function Ey(){switch(O.value.tab){case"mission":return i`<${Tr} />`;case"proof":return i`<${Xg} />`;case"execution":return i`<${Z$} />`;case"tools":return i`<${oh} />`;case"live":return i`<${Ay} />`;case"memory":return i`<${F$} />`;case"governance":return i`<${Eh} />`;case"planning":return i`<${bh} />`;case"intervene":return i`<${I$} />`;case"command":return i`<${x$} />`;case"lab":return i`<${dy} />`;default:return i`<${Tr} />`}}function jy(){return Bi.value&&!dt.value?i`<div class="loading-indicator">대시보드 불러오는 중...</div>`:i`<${Ey} />`}function Ny(){ae(()=>{jd(),pl(),Ul(),It(),At(),Bl(),ic();const n=$m();return hm(),()=>{Bd(),n(),ym()}},[]),ae(()=>{const n=setInterval(()=>{eo(O.value.tab)},15e3);return()=>{clearInterval(n)}},[]),ae(()=>{eo(O.value.tab)},[O.value.tab]);const e=O.value.tab,t=_o.find(n=>n.id===e);return i`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC 대시보드
            <${zy} />
          </h1>
          <p class="header-subtitle">${(t==null?void 0:t.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${My} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${Py} />
        <main class="dashboard-main">
          <${jy} />
        </main>
      </div>

      <${eg} />
      <${qv} />
      <${Lv} />
    </div>
  `}const ol=document.getElementById("app");ol&&Md(i`<${Ny} />`,ol);export{dg as _};
