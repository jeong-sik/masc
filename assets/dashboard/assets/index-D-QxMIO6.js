var Id=Object.defineProperty;var zd=(e,t,n)=>t in e?Id(e,t,{enumerable:!0,configurable:!0,writable:!0,value:n}):e[t]=n;var Ot=(e,t,n)=>zd(e,typeof t!="symbol"?t+"":t,n);import{e as Rd,_ as Ld,c as $,b as Pe,y as oe,d as dl,A as Pd,G as Md}from"./vendor-kuFK4-oj.js";(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const l of i.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var o=Rd.bind(Ld);const jd=["mission","proof","execution","tools","live","memory","governance","planning","intervene","command","lab"],ul={tab:"mission",params:{},postId:null};function lr(e){return!!e&&jd.includes(e)}function Oo(e){try{return decodeURIComponent(e)}catch{return e}}function qo(e){const t={};return e&&new URLSearchParams(e).forEach((s,a)=>{t[a]=s}),t}function Ed(e){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function pl(e,t){if(e[0]==="chains"){const i={...t,surface:"chains"};return e[1]==="operation"&&e[2]&&(i.operation=Oo(e[2])),{tab:"command",params:i,postId:null}}if(e[0]==="lab"){const i={...t};return e[1]&&(i.surface=Oo(e[1])),{tab:"lab",params:i,postId:null}}const n=e[0],s=t.tab;return{tab:lr(n)?n:lr(s)?s:"mission",params:t,postId:null}}function ea(e){const t=(e||"").replace(/^#/,"").trim();if(!t)return ul;const n=Oo(t);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=qo(a),l=Ed(s);return pl(l,i)}function Nd(e,t){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...ul,params:qo(t.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=qo(t.replace(/^\?/,""));return pl(s,a)}function ml(e){const t=e.tab==="lab"&&e.params.surface?`lab/${encodeURIComponent(e.params.surface)}`:e.tab,n=Object.entries(e.params).filter(([a])=>!(a==="tab"||e.tab==="lab"&&a==="surface"));if(n.length===0)return`#${t}`;const s=new URLSearchParams(n);return`#${t}?${s.toString()}`}const O=$(ea(window.location.hash));window.addEventListener("hashchange",()=>{O.value=ea(window.location.hash)});function ie(e,t){const n={tab:e,params:t??{}};window.location.hash=ml(n)}function Dd(e){window.location.hash=`#memory?post=${encodeURIComponent(e)}`}function Od(){if(window.location.hash&&window.location.hash!=="#"){O.value=ea(window.location.hash);return}const e=Nd(window.location.pathname,window.location.search);if(e){O.value=e;const t=ml(e);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${t}`);return}window.location.hash="#mission",O.value=ea(window.location.hash)}const cr="masc_dashboard_sse_session_id",qd=1e3,wd=15e3,ut=$(!1),Ka=$(0),_l=$(null),ta=$([]);function Fd(){let e=sessionStorage.getItem(cr);return e||(e=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(cr,e)),e}const Kd=200;function Hd(e,t,n="system",s={}){const a={agent:e,text:t,timestamp:Date.now(),kind:n,...s};ta.value=[a,...ta.value].slice(0,Kd)}function wo(e,t=88){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-3)}...`:n:void 0}function dr(e,t){const n=wo(t);return n?`${e}: ${n}`:`New ${e.toLowerCase()}`}function ze(e,t,n,s,a={}){Hd(e,t,n,{eventType:s,...a})}let De=null,Xt=null,Fo=0;function vl(){Xt&&(clearTimeout(Xt),Xt=null)}function Ud(){if(Xt)return;Fo++;const e=Math.min(Fo,5),t=Math.min(wd,qd*Math.pow(2,e));Xt=setTimeout(()=>{Xt=null,fl()},t)}function fl(){vl(),De&&(De.close(),De=null);const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");n&&t.set("agent",n),s&&t.set("token",s),t.set("session_id",Fd());const a=t.toString()?`/sse?${t.toString()}`:"/sse",i=new EventSource(a);De=i,i.onopen=()=>{De===i&&(Fo=0,ut.value=!0)},i.onerror=()=>{De===i&&(ut.value=!1,i.close(),De=null,Ud())},i.onmessage=l=>{try{const c=JSON.parse(l.data);Ka.value++,_l.value=c,Bd(c)}catch{}}}function Bd(e){const t=e.type,n=e.agent??e.author??e.from??e.from_agent??"";switch(t){case"agent_joined":ze(n,"Joined","system","agent_joined");break;case"agent_left":ze(n,"Left","system","agent_left");break;case"broadcast":ze(n,`${(e.message??e.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":ze(n,`Task: ${e.task_id??""} -> ${e.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":ze(n,dr("Post",e.content??e.message),"board","board_post",{author:e.author??n,preview:wo(e.content??e.message),postId:e.post_id});break;case"board_comment":case"masc/board_comment":ze(n,dr("Comment",e.content??e.message),"board","board_comment",{author:e.author??n,preview:wo(e.content??e.message),postId:e.post_id});break;case"keeper_heartbeat":ze(e.name??n,`Heartbeat gen=${e.generation??"?"} ctx=${e.context_ratio!=null?Math.round(e.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":ze(e.name??n,`Handoff gen ${e.from_generation??"?"} -> ${e.to_generation??"?"} (${e.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":ze(e.name??n,`Compaction saved ${e.saved_tokens??"?"} tokens (${e.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":ze(e.name??n,`Guardrail: ${e.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:ze(n,t,"system","unknown")}}function Wd(){vl(),De&&(De.close(),De=null),ut.value=!1}function m(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function r(e){return typeof e=="string"&&e.trim()!==""?e.trim():void 0}function d(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function j(e){return typeof e=="boolean"?e:void 0}function w(e){return Array.isArray(e)?e.map(t=>typeof t=="string"?t.trim():"").filter(Boolean):[]}function ce(e,t=[]){if(Array.isArray(e))return e;if(!m(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function le(e){if(typeof e=="string"&&e.trim()!=="")return e;if(!(typeof e!="number"||!Number.isFinite(e)||e<=0))return new Date(e*1e3).toISOString()}function gl(){return new URLSearchParams(window.location.search)}const Gd="masc_dashboard_agent_name";function Jd(){var e;try{return((e=localStorage.getItem(Gd))==null?void 0:e.trim())||null}catch{return null}}function $l(){const e=gl(),t={},n=e.get("token"),s=Jd(),a=e.get("agent")??e.get("agent_name")??s;return n&&(t.Authorization=`Bearer ${n}`),a&&(t["X-MASC-Agent"]=a),t}function hl(){return{...$l(),"Content-Type":"application/json"}}const Vd=15e3,yi=3e4,Yd=6e4,ur=new Set([408,425,429,500,502,503,504]);class is extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);Ot(this,"method");Ot(this,"path");Ot(this,"status");Ot(this,"statusText");Ot(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function bi(e,t,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(e,{...t,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const l=typeof t.method=="string"?t.method.toUpperCase():"GET";throw new is({method:l,path:e,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function Qd(){var t,n;const e=gl();return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function ne(e){const t=await bi(e,{headers:$l()},Vd);if(!t.ok)throw new is({method:"GET",path:e,status:t.status,statusText:t.statusText});return t.json()}function Xd(e){return new Promise(t=>setTimeout(t,e))}function Zd(e){const t=e.match(/\b(\d{3})\b/);if(!t)return null;const n=t[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function eu(e){if(e instanceof is)return e.timeout||typeof e.status=="number"&&ur.has(e.status);if(!(e instanceof Error))return!1;if(/timeout after \d+ms/i.test(e.message))return!0;const t=Zd(e.message);return t!==null&&ur.has(t)}async function Ha(e,t,n=2){let s=0;for(;;)try{return await t()}catch(a){if(!eu(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${e} failed (attempt ${s+1}), retrying in ${i}ms`,a),await Xd(i),s+=1}}async function He(e,t,n,s=yi){const a=await bi(e,{method:"POST",headers:{...hl(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new is({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.json()}async function tu(e,t,n,s=yi){const a=await bi(e,{method:"POST",headers:{...hl(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new is({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.text()}function nu(e){const t=e.split(`
`).find(s=>s.startsWith("data: ")),n=t?t.slice(6).trim():e.trim();return JSON.parse(n)}function su(e){var t,n,s,a,i,l,c;if((t=e.error)!=null&&t.message)throw new Error(e.error.message);if((n=e.result)!=null&&n.isError){const u=((a=(s=e.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(u)}return((c=(l=(i=e.result)==null?void 0:i.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function Ie(e,t){const n=await tu("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:e,arguments:t},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Yd),s=nu(n);return su(s)}function Ua(e){const t=e.trim();return t?JSON.parse(t):{}}async function au(e){return Ua(await Ie("masc_autoresearch_status",{loop_id:e}))}async function ou(e,t){return Ua(await Ie("masc_autoresearch_inject",{loop_id:e,hypothesis:t}))}async function iu(e){return Ua(await Ie("masc_autoresearch_cycle",{loop_id:e}))}async function ru(e,t){return Ua(await Ie("masc_autoresearch_stop",{loop_id:e,reason:t}))}function lu(){return ne("/api/v1/dashboard/shell")}function cu(){return ne("/api/v1/dashboard/room-truth")}function du(){return ne("/api/v1/dashboard/execution")}function uu(e,t){const n=new URLSearchParams;return n.set("sort_by",e),t!=null&&t.excludeSystem&&n.set("exclude_system","true"),ne(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function pu(){return Ha("fetchDashboardGovernance",async()=>{const e=await ne("/api/v1/dashboard/governance"),t=Array.isArray(e.items)?e.items.map(i=>Lu(i)).filter(i=>i!==null):[],n=Array.isArray(e.pending_actions)?e.pending_actions.map(i=>kl(i)).filter(i=>i!==null):[],s=t.filter(i=>i.kind==="debate").map(i=>({id:i.id,topic:i.topic,status:i.status,argument_count:i.evidence_refs.length,created_at:i.last_activity_at??void 0})),a=t.filter(i=>i.kind==="consensus").map(i=>({id:i.id,topic:i.topic,initiator:i.related_agents[0]||"system",votes:i.votes??0,quorum:i.quorum??0,threshold:i.threshold,state:i.status,created_at:i.last_activity_at??void 0}));return{generated_at:pe(e.generated_at)??void 0,summary:m(e.summary)?{debates:fe(e.summary.debates)??void 0,voting_sessions:fe(e.summary.voting_sessions)??void 0,debates_open:fe(e.summary.debates_open)??void 0,sessions_active:fe(e.summary.sessions_active)??void 0,sessions_without_quorum:fe(e.summary.sessions_without_quorum)??void 0,ready_to_execute:fe(e.summary.ready_to_execute)??void 0,oldest_open_debate_age_s:typeof e.summary.oldest_open_debate_age_s=="number"?e.summary.oldest_open_debate_age_s:null,last_activity_age_s:typeof e.summary.last_activity_age_s=="number"?e.summary.last_activity_age_s:null,judge_online:typeof e.summary.judge_online=="boolean"?e.summary.judge_online:void 0,judge_last_seen_at:pe(e.summary.judge_last_seen_at)}:void 0,debates:s,sessions:a,items:t,activity:Array.isArray(e.activity)?e.activity.map(i=>Pu(i)).filter(i=>i!==null):[],judge:Mu(e.judge),pending_actions:n}})}function mu(){return ne("/api/v1/dashboard/semantics")}function _u(){return ne("/api/v1/dashboard/mission")}function vu(e){const t=`?session_id=${encodeURIComponent(e)}`;return ne(`/api/v1/dashboard/session${t}`)}function fu(e=!1){return ne(`/api/v1/dashboard/mission/briefing${e?"?force=1":""}`)}function gu(e,t){const n=new URLSearchParams;e&&n.set("session_id",e),t&&n.set("operation_id",t);const s=n.toString();return ne(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function $u(){return ne("/api/v1/dashboard/planning")}function hu(){return ne("/api/v1/tool-metrics")}function yu(){return ne("/api/v1/dashboard/tools")}function bu(){return ne("/api/v1/operator")}function yl(e={}){const t=new URLSearchParams;e.targetType&&t.set("target_type",e.targetType),e.targetId&&t.set("target_id",e.targetId),e.includeWorkers!=null&&t.set("include_workers",e.includeWorkers?"true":"false");const n=t.toString();return ne(`/api/v1/operator/digest${n?`?${n}`:""}`)}function ku(){return ne("/api/v1/command-plane")}function xu(){return ne("/api/v1/command-plane/summary")}function Su(){return ne("/api/v1/chains/summary")}function Cu(e){return ne(`/api/v1/chains/runs/${encodeURIComponent(e)}`)}function Au(){return ne("/api/v1/command-plane/help")}function Tu(e,t){const n=new URLSearchParams;e&&n.set("run_id",e),t&&n.set("operation_id",t);const s=n.toString();return ne(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function Iu(e,t){const n=new URLSearchParams;e&&n.set("run_id",e),t&&n.set("operation_id",t);const s=n.toString();return ne(`/api/v1/command-plane/orchestra${s?`?${s}`:""}`)}function zu(e,t){return He(e,t)}function Ru(e){switch(e.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"swarm_run_continue":return 6e4;case"swarm_run_rerun":return 12e4;case"swarm_run_abandon":return 3e4;case"lodge_tick":return 45e3;default:return yi}}function Ba(e){return He("/api/v1/operator/action",e,void 0,Ru(e))}function bl(e,t,n="confirm"){return He("/api/v1/operator/confirm",{actor:e,confirm_token:t,decision:n})}function Ks(e){if(typeof e=="string"&&e.trim())return e;if(typeof e!="number"||Number.isNaN(e))return new Date().toISOString();const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}function pe(e){if(typeof e=="string"){const t=e.trim();return t||null}if(typeof e=="number"&&Number.isFinite(e)){const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}return null}function F(e){if(typeof e!="string")return null;const t=e.trim();return t||null}function kl(e){if(!m(e))return null;const t=k(e.confirm_token??e.token,"").trim();return t?{confirm_token:t,actor:F(e.actor)??void 0,action_type:F(e.action_type)??void 0,target_type:F(e.target_type)??void 0,target_id:F(e.target_id),delegated_tool:F(e.delegated_tool)??void 0,created_at:pe(e.created_at)??void 0,preview:e.preview}:null}function ki(e){return m(e)?{board_post_id:F(e.board_post_id),task_id:F(e.task_id),operation_id:F(e.operation_id),team_session_id:F(e.team_session_id)}:{}}function xl(e){if(!m(e))return null;const t=F(e.action_kind),n=F(e.resolved_tool),s=F(e.target_type),a=F(e.target_id),i=F(e.reason);return!t&&!n&&!s&&!i?null:{action_kind:t??void 0,resolved_tool:n,target_type:s,target_id:a,reason:i??void 0,payload_preview:e.payload_preview}}function Sl(e){if(!m(e))return null;const t=F(e.action_type),n=F(e.delegated_tool),s=F(e.confirmation_state),a=pe(e.created_at);return!t&&!n&&!s&&!a?null:{action_type:t??void 0,delegated_tool:n,confirmation_state:s??void 0,created_at:a}}function Cl(e){if(!m(e))return null;const t=kl(e.pending_confirm),n=F(e.pending_confirm_token)??(t==null?void 0:t.confirm_token)??null;return{requires_human_gate:typeof e.requires_human_gate=="boolean"?e.requires_human_gate:void 0,pending_confirm:t,pending_confirm_token:n,ready_to_execute:typeof e.ready_to_execute=="boolean"?e.ready_to_execute:void 0}}function Al(e){if(!m(e))return null;const t=F(e.summary),n=F(e.target_id);return!t&&!n?null:{judgment_id:F(e.judgment_id)??void 0,target_kind:F(e.target_kind)??void 0,target_id:n??void 0,status:F(e.status)??void 0,summary:t??void 0,confidence:typeof e.confidence=="number"?e.confidence:null,generated_at:pe(e.generated_at),expires_at:pe(e.expires_at),model_used:F(e.model_used),keeper_name:F(e.keeper_name),evidence_refs:Oe(e.evidence_refs),recommended_action:xl(e.recommended_action),guardrail_state:Cl(e.guardrail_state),executed_route:Sl(e.executed_route)}}function Lu(e){if(!m(e))return null;const t=k(e.id,"").trim(),n=k(e.topic,"").trim();if(!t||!n)return null;const s=ki(e.context);return{kind:k(e.kind,"debate"),id:t,topic:n,status:k(e.status??e.state,"open"),last_activity_at:pe(e.last_activity_at),truth_summary:F(e.truth_summary)??void 0,judgment_summary:F(e.judgment_summary),confidence:typeof e.confidence=="number"?e.confidence:null,related_agents:Oe(e.related_agents),context:s,linked_board_post_id:F(e.linked_board_post_id)??s.board_post_id??null,linked_task_id:F(e.linked_task_id)??s.task_id??null,linked_operation_id:F(e.linked_operation_id)??s.operation_id??null,linked_session_id:F(e.linked_session_id)??s.team_session_id??null,recommended_action:xl(e.recommended_action),executed_route:Sl(e.executed_route),guardrail_state:Cl(e.guardrail_state),evidence_refs:Oe(e.evidence_refs),approve_count:fe(e.approve_count),reject_count:fe(e.reject_count),abstain_count:fe(e.abstain_count),votes:fe(e.votes),quorum:fe(e.quorum),threshold:typeof e.threshold=="number"?e.threshold:void 0}}function Pu(e){if(!m(e))return null;const t=k(e.kind,"").trim();return t?{kind:t,item_kind:F(e.item_kind)??void 0,item_id:F(e.item_id)??void 0,topic:F(e.topic)??void 0,created_at:pe(e.created_at),summary:F(e.summary)??void 0,actor:F(e.actor),index:fe(e.index),decision:F(e.decision)}:null}function Mu(e){if(m(e))return{judge_online:typeof e.judge_online=="boolean"?e.judge_online:void 0,refreshing:typeof e.refreshing=="boolean"?e.refreshing:void 0,generated_at:pe(e.generated_at),expires_at:pe(e.expires_at),model_used:F(e.model_used),keeper_name:F(e.keeper_name),last_error:F(e.last_error)}}function ju(e){var a;const t=e.trim(),s=((a=(t.startsWith("[flair:")?t.replace(/^\[flair:[^\]]+\]\s*/i,""):t).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Eu(e){if(!m(e))return null;const t=k(e.source,"").trim()||null,n=k(e.state_block,"").trim()||null;return!t&&!n?null:{source:t,state_block:n}}function Nu(e){if(!m(e))return null;const t=k(e.id,"").trim(),n=k(e.author,"").trim(),s=k(e.body,"").trim()||k(e.content,"").trim(),a=s;if(!t||!n)return null;const i=U(e.score,0),l=U(e.votes_up,0),c=U(e.votes_down,0),u=U(e.votes,i||l-c),p=U(e.comment_count,U(e.reply_count,0)),g=(()=>{const x=e.flair;if(typeof x=="string"&&x.trim())return x.trim();if(m(x)){const _=k(x.name,"").trim();if(_)return _}return k(e.flair_name,"").trim()||void 0})(),f=k(e.created_at_iso,"").trim()||Ks(e.created_at),v=k(e.updated_at_iso,"").trim()||(e.updated_at!==void 0?Ks(e.updated_at):f),b=k(e.title,"").trim()||ju(s),C=Array.isArray(e.tags)?e.tags.filter(x=>typeof x=="string"&&x.trim()!==""):[];return{id:t,author:n,post_kind:(()=>{const x=k(e.post_kind,"").trim().toLowerCase();return x==="automation"||x==="system"||x==="human"?x:void 0})(),title:b,body:s,content:a,meta:Eu(e.meta),tags:C,votes:u,vote_balance:i,comment_count:p,created_at:f,updated_at:v,flair:g,hearth:k(e.hearth,"").trim()||null,visibility:k(e.visibility,"").trim()||void 0,expires_at:k(e.expires_at_iso,"").trim()||(e.expires_at!==void 0&&e.expires_at!==0?Ks(e.expires_at):"")||null,hearth_count:U(e.hearth_count,0)}}function Du(e){if(!m(e))return null;const t=k(e.id,"").trim(),n=k(e.post_id,"").trim(),s=k(e.author,"").trim();return!t||!s?null:{id:t,post_id:n,author:s,content:k(e.content,""),created_at:Ks(e.created_at)}}async function Ou(e){return Ha("fetchBoardPost",async()=>{const t=await ne(`/api/v1/board/${e}?format=flat`),n=m(t.post)?t.post:t,s=Nu(n)??{id:e,author:"unknown",post_kind:"human",title:"Post",body:"",content:"",meta:null,tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},i=(Array.isArray(t.comments)?t.comments:[]).map(Du).filter(l=>l!==null);return{...s,comments:i}})}function Tl(e,t){return He("/api/v1/tools/masc_board_vote",{post_id:e,direction:t,vote:t,voter:Qd()})}function qu(e,t,n){return He("/api/v1/tools/masc_board_comment",{post_id:e,author:t,content:n})}function wu(e){const t=k(e,"").trim().toLowerCase();if(t==="win"||t==="won"||t==="victory")return"victory";if(t==="lose"||t==="lost"||t==="defeat")return"defeat";if(t==="draw"||t==="stalemate"||t==="tie")return"draw"}function me(...e){for(const t of e){const n=k(t,"");if(n.trim())return n.trim()}return""}function pr(e){const t=wu(me(e.outcome,e.result,e.result_code));if(!t)return;const n=me(e.reason,e.reason_code,e.description,e.detail),s=me(e.summary,e.summary_ko,e.summary_en,e.note),a=me(e.details,e.details_text,e.text,e.note),i=me(e.winner,e.winner_name,e.actor_winner,e.winner_actor),l=me(e.winner_actor_id,e.winner_actor,e.actor_winner_id),c=me(e.raw_reason,e.raw_reason_code,e.error_message),u=(()=>{const f=e.evidence??e.evidence_ids??e.supporting_events??e.event_ids??[];return typeof f=="string"?[f]:Array.isArray(f)?f.map(v=>{if(typeof v=="string")return v.trim();if(m(v)){const h=k(v.summary,"").trim();if(h)return h;const b=k(v.text,"").trim();if(b)return b;const C=k(v.type,"").trim();return C||k(v.event_id,"").trim()}return""}).filter(v=>v.length>0):[]})(),p=(()=>{const f=U(e.turn,Number.NaN);if(Number.isFinite(f))return f;const v=U(e.turn_number,Number.NaN);if(Number.isFinite(v))return v;const h=U(e.current_turn,Number.NaN);if(Number.isFinite(h))return h;const b=U(e.round,Number.NaN);return Number.isFinite(b)?b:void 0})(),g=me(e.phase,e.phase_name,e.current_phase,e.phase_id);return{result:t,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:l||void 0,evidence:u.length>0?u:void 0,raw_reason:c||void 0,turn:p,phase:g||void 0}}function Fu(e,t){const n=m(e.state)?e.state:{};if(k(n.status,"active").toLowerCase()!=="ended")return;const a=[...t].reverse().find(l=>m(l)?k(l.type,"")==="session.outcome":!1),i=m(n.session_outcome)?n.session_outcome:{};if(m(i)&&Object.keys(i).length>0){const l=pr(i);if(l)return l}if(m(a))return pr(m(a.payload)?a.payload:{})}function k(e,t=""){return typeof e=="string"?e:t}function U(e,t=0){return typeof e=="number"&&Number.isFinite(e)?e:t}function fe(e){if(typeof e=="number"&&Number.isFinite(e))return Math.trunc(e);if(typeof e=="string"){const t=Number.parseInt(e.trim(),10);if(Number.isFinite(t))return t}}function na(e,t=!1){return typeof e=="boolean"?e:t}function Oe(e){return Array.isArray(e)?e.map(t=>{if(typeof t=="string")return t.trim();if(m(t)){const n=k(t.name,"").trim(),s=k(t.id,"").trim(),a=k(t.skill,"").trim();return n||s||a}return""}).filter(t=>t.length>0):[]}function Ku(e){const t={};if(!m(e)&&!Array.isArray(e))return t;if(m(e))return Object.entries(e).forEach(([n,s])=>{const a=n.trim(),i=k(s,"").trim();!a||!i||(t[a]=i)}),t;for(const n of e){if(!m(n))continue;const s=me(n.to,n.target,n.actor_id,n.name,n.id),a=me(n.relationship,n.relation,n.type,n.kind);!s||!a||(t[s]=a)}return t}function Hu(e,t,n){if(e==="dm"||e==="player"||e==="npc")return e;const s=t.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function Ce(e,t,n,s=0){const a=e[t];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=e[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const Uu=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Bu(e){const t=m(e.stats)?e.stats:{},n={};return Object.entries(t).forEach(([s,a])=>{const i=s.trim();i&&(Uu.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function Wu(e,t){if(e!=="dice.rolled")return;const n=U(t.raw_d20,0),s=U(t.total,0),a=U(t.bonus,0),i=k(t.action,"roll"),l=U(t.dc,0);return{notation:l>0?`${i} (DC ${l})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function Gu(e){const t=JSON.stringify(e);return t?t.length>160?`${t.slice(0,157)}...`:t:""}function Ju(e){const t=e.trim().toLowerCase();return t?t.startsWith("dice.")?"dice":t.startsWith("combat.")||t.includes(".attack")||t.includes(".damage")?"combat":t.includes("actor.")?"actor":t.includes("turn.")||t==="turn.started"||t==="phase.changed"?"turn":t.includes("join.")?"join":t.includes("memory")?"memory":t.includes("world.")?"world":t.includes("narration")?"story":"meta":"meta"}function Vu(e,t,n,s){const a=n||t||k(s.actor_id,"")||k(s.actor_name,"");switch(e){case"turn.action.proposed":{const i=k(s.proposed_action,k(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=k(s.reply,k(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return k(s.reply,k(s.content,k(s.text,"Narration")));case"dice.rolled":{const i=k(s.action,"roll"),l=U(s.total,0),c=U(s.dc,0),u=k(s.label,""),p=a||"actor",g=c>0?` vs DC ${c}`:"",f=u?` (${u})`:"";return`${p} ${i}: ${l}${g}${f}`}case"turn.started":return`Turn ${U(s.turn,1)} started`;case"phase.changed":return`Phase: ${k(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${k(s.name,m(s.actor)?k(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${k(s.keeper_name,k(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${k(s.keeper_name,k(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${U(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${U(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||k(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||k(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${k(s.reason_code,"unknown")}`;case"memory.signal":{const i=m(s.entity_refs)?s.entity_refs:{},l=k(i.requested_tier,""),c=k(i.effective_tier,""),u=na(i.guardrail_applied,!1),p=k(s.summary_en,k(s.summary_ko,"Memory signal"));if(!l&&!c)return p;const g=l&&c?`${l}->${c}`:c||l;return`${p} [${g}${u?" (guardrail)":""}]`}case"world.event":{if(k(s.event_type,"")==="canon.check"){const l=k(s.status,"unknown"),c=k(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return k(s.description,k(s.summary,"World event"))}case"combat.attack":return k(s.summary,k(s.result,"Attack resolved"));case"combat.defense":return k(s.summary,k(s.result,"Defense resolved"));case"session.outcome":return k(s.summary,k(s.outcome,"Session ended"));default:{const i=Gu(s);return i?`${e}: ${i}`:e}}}function Yu(e,t){const n=m(e)?e:{},s=k(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=k(n.actor_name,"").trim()||t[a]||k(m(n.payload)?n.payload.actor_name:"",""),l=m(n.payload)?n.payload:{},c=k(n.ts,k(n.timestamp,new Date().toISOString())),u=k(n.phase,k(l.phase,"")),p=k(n.category,"");return{type:s,actor:i||a||k(l.actor_name,""),actor_id:a||k(l.actor_id,""),actor_name:i,seq:n.seq,room_id:k(n.room_id,""),phase:u||void 0,category:p||Ju(s),visibility:k(n.visibility,k(l.visibility,"public")),event_id:k(n.event_id,""),content:Vu(s,a,i,l),dice_roll:Wu(s,l),timestamp:c}}function Qu(e,t,n){var Q,se;const s=k(e.room_id,"")||n||"default",a=m(e.state)?e.state:{},i=m(a.party)?a.party:{},l=m(a.actor_control)?a.actor_control:{},c=m(a.join_gate)?a.join_gate:{},u=m(a.contribution_ledger)?a.contribution_ledger:{},p=Object.entries(i).map(([M,J])=>{const A=m(J)?J:{},X=Ce(A,"max_hp",void 0,10),K=Ce(A,"hp",void 0,X),te=Ce(A,"max_mp",void 0,0),$t=Ce(A,"mp",void 0,0),H=Ce(A,"level",void 0,1),Me=Ce(A,"xp",void 0,0),ht=na(A.alive,K>0),yn=l[M],bn=typeof yn=="string"?yn:void 0,gs=Hu(A.role,M,bn),$s=fe(A.generation),hs=me(A.joined_at,A.joinedAt,A.started_at,A.startedAt),ys=me(A.claimed_at,A.claimedAt,A.assigned_at,A.assignedAt,A.assigned_time),bs=me(A.last_seen,A.lastSeen,A.last_seen_at,A.lastSeenAt,A.last_active,A.lastActive),ks=me(A.scene,A.current_scene,A.currentScene,A.world_scene,A.scene_name,A.sceneName),xs=me(A.location,A.current_location,A.currentLocation,A.position,A.zone,A.area);return{id:M,name:k(A.name,M),role:gs,keeper:bn,archetype:k(A.archetype,""),persona:k(A.persona,""),portrait:k(A.portrait,"")||void 0,background:k(A.background,"")||void 0,traits:Oe(A.traits),skills:Oe(A.skills),stats_raw:Bu(A),status:ht?"active":"dead",generation:$s,joined_at:hs||void 0,claimed_at:ys||void 0,last_seen:bs||void 0,scene:ks||void 0,location:xs||void 0,inventory:Oe(A.inventory),notes:Oe(A.notes),relationships:Ku(A.relationships),stats:{hp:K,max_hp:X,mp:$t,max_mp:te,level:H,xp:Me,strength:Ce(A,"strength","str",10),dexterity:Ce(A,"dexterity","dex",10),constitution:Ce(A,"constitution","con",10),intelligence:Ce(A,"intelligence","int",10),wisdom:Ce(A,"wisdom","wis",10),charisma:Ce(A,"charisma","cha",10)}}}),g=p.filter(M=>M.status!=="dead"),f=Fu(e,t),v={phase_open:na(c.phase_open,!0),min_points:U(c.min_points,3),window:k(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},h=Object.entries(u).map(([M,J])=>{const A=m(J)?J:{};return{actor_id:M,score:U(A.score,0),last_reason:k(A.last_reason,"")||null,reasons:Oe(A.reasons)}}),b=p.reduce((M,J)=>(M[J.id]=J.name,M),{}),C=t.map(M=>Yu(M,b)),x=U(a.turn,1),S=k(a.phase,"round"),_=k(a.map,""),I=m(a.world)?a.world:{},R=_||k(I.ascii_map,k(I.map,"")),L=C.filter((M,J)=>{const A=t[J];if(!m(A))return!1;const X=m(A.payload)?A.payload:{};return U(X.turn,-1)===x}),V=(L.length>0?L:C).slice(-12),z=k(a.status,"active");return{session:{id:s,room:s,status:z==="ended"?"ended":z==="paused"?"paused":"active",round:x,actors:g,created_at:((Q=C[0])==null?void 0:Q.timestamp)??new Date().toISOString()},current_round:{round_number:x,phase:S,events:V,timestamp:((se=C[C.length-1])==null?void 0:se.timestamp)??new Date().toISOString()},map:R||void 0,join_gate:v,contribution_ledger:h,outcome:f,party:g,story_log:C,history:[]}}async function Xu(e){const t=`?room_id=${encodeURIComponent(e)}`,n=await ne(`/api/v1/trpg/events${t}`);return Array.isArray(n.events)?n.events:[]}async function Zu(e){const t=`?room_id=${encodeURIComponent(e)}`,[n,s]=await Promise.all([ne(`/api/v1/trpg/state${t}`),Xu(e)]);return Qu(n,s,e)}function ep(e){return He("/api/v1/trpg/rounds/run",{room_id:e})}function tp(e){const t="".trim().toLowerCase();if(t)switch(t){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return t}}function np(e){const t={room_id:e.roomId,actor_id:e.actorId,action:e.action,stat_value:e.statValue,dc:e.dc};return e.rawD20!=null&&(t.raw_d20=e.rawD20),e.ruleModule&&(t.rule_module=e.ruleModule),He("/api/v1/trpg/dice/roll",t)}function sp(e,t){const n=tp();return He("/api/v1/trpg/turns/advance",{room_id:e,...n?{phase:n}:{}})}function ap(e,t){var a;const n=(a=t.idempotencyKey)==null?void 0:a.trim(),s={room_id:e};return t.actor_id&&t.actor_id.trim()&&(s.actor_id=t.actor_id.trim()),t.name&&t.name.trim()&&(s.name=t.name.trim()),t.role&&(s.role=t.role),t.archetype&&t.archetype.trim()&&(s.archetype=t.archetype.trim()),t.persona&&t.persona.trim()&&(s.persona=t.persona.trim()),t.portrait&&t.portrait.trim()&&(s.portrait=t.portrait.trim()),t.background&&t.background.trim()&&(s.background=t.background.trim()),t.hp!=null&&(s.hp=t.hp),t.max_hp!=null&&(s.max_hp=t.max_hp),t.alive!=null&&(s.alive=t.alive),Array.isArray(t.traits)&&t.traits.length>0&&(s.traits=t.traits),Array.isArray(t.skills)&&t.skills.length>0&&(s.skills=t.skills),Array.isArray(t.inventory)&&t.inventory.length>0&&(s.inventory=t.inventory),t.stats&&Object.keys(t.stats).length>0&&(s.stats=t.stats),n&&(s.idempotency_key=n),He("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function op(e,t,n){return He("/api/v1/trpg/actors/claim",{room_id:e,actor_id:t,keeper:n})}async function ip(e,t,n){const s=await Ie("trpg.join.eligibility",{room_id:e,actor_id:t,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function rp(e){const t=await Ie("trpg.mid_join.request",e);return JSON.parse(t)}async function lp(e,t){await Ie("masc_broadcast",{agent_name:e,message:t})}async function cp(e=40){return(await Ie("masc_messages",{limit:e})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function dp(e,t=20){return Ie("masc_task_history",{task_id:e,limit:t})}async function up(e){const t=await Ie("masc_debate_start",{topic:e});try{return JSON.parse(t)}catch{return null}}async function pp(e){return Ha("fetchDebateStatus",async()=>{const t=encodeURIComponent(e),n=await ne(`/api/v1/council/debates/${t}/summary`);if(!m(n))return null;const s=m(n.debate)?n.debate:n,a=k(s.id,"").trim(),i=k(s.topic,"").trim();return!a||!i?null:{debate:{id:a,topic:i,status:k(s.status,"open"),created_at:pe(s.created_at_iso??s.created_at),closed_at:pe(s.closed_at)},arguments:Array.isArray(n.arguments)?n.arguments.flatMap(l=>m(l)?[{index:U(l.index,0),agent:k(l.agent,"unknown"),position:k(l.position,"neutral"),content:k(l.content,""),evidence:Oe(l.evidence),reply_to:fe(l.reply_to)??null,mentions:Oe(l.mentions),archetype:F(l.archetype),created_at:pe(l.created_at)}]:[]):[],summary:{support_count:m(n.summary)?U(n.summary.support_count,0):U(n.support_count,0),oppose_count:m(n.summary)?U(n.summary.oppose_count,0):U(n.oppose_count,0),neutral_count:m(n.summary)?U(n.summary.neutral_count,0):U(n.neutral_count,0),total_arguments:m(n.summary)?U(n.summary.total_arguments,0):U(n.total_arguments,0),summary_text:m(n.summary)?k(n.summary.summary_text,""):k(n.summary_text,"")},context:ki(n.context),judgment:Al(n.judgment)}})}async function mp(e){return Ha("fetchConsensusSessionSummary",async()=>{const t=encodeURIComponent(e),n=await ne(`/api/v1/council/sessions/${t}/summary`);if(!m(n)||!m(n.session))return null;const s=n.session,a=k(s.id,"").trim(),i=k(s.topic,"").trim();return!a||!i?null:{session:{id:a,topic:i,state:k(s.state,"open"),initiator:k(s.initiator,"system"),quorum:U(s.quorum,0),threshold:U(s.threshold,0),created_at:pe(s.created_at),closed_at:pe(s.closed_at)},votes:Array.isArray(n.votes)?n.votes.flatMap(l=>m(l)?[{agent:k(l.agent,"unknown"),decision:k(l.decision,"abstain"),reason:k(l.reason,""),timestamp:pe(l.timestamp),weight:typeof l.weight=="number"?l.weight:void 0,archetype:F(l.archetype)}]:[]):[],summary:{approve_count:m(n.summary)?U(n.summary.approve_count,0):0,reject_count:m(n.summary)?U(n.summary.reject_count,0):0,abstain_count:m(n.summary)?U(n.summary.abstain_count,0):0,quorum_met:m(n.summary)?na(n.summary.quorum_met,!1):!1,result:m(n.summary)?F(n.summary.result):null},context:ki(n.context),judgment:Al(n.judgment)}})}function _p(e,t,n){return Ie("masc_keeper_msg",{name:e,message:t})}const vp=$(""),Ye=$({}),_e=$({}),Ko=$({}),Ho=$({}),Uo=$({}),Bo=$({}),Qe=$({});function ue(e,t,n){e.value={...e.value,[t]:n}}function fp(e){var n;const t=(n=r(e))==null?void 0:n.toLowerCase();return t==="user"||t==="assistant"||t==="system"||t==="tool"?t:"other"}function gp(e){switch(e){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function to(e,t){if(!Array.isArray(e))return[];const n=[];for(const s of e){if(!m(s))continue;const a=r(s.name);if(!a)continue;const i=r(s[t]);t==="summary"?n.push({name:a,summary:i}):n.push({name:a,reason:i})}return n}function $p(e){if(!m(e))return null;const t=r(e.name);return t?{name:t,trigger:r(e.trigger),outcome:r(e.outcome),summary:r(e.summary),reason:r(e.reason)}:null}function hp(e){const t=e.toLowerCase();return t.includes("graphql")?"graphql_error":t.includes("timeout")||t.includes("model")||t.includes("llm")||t.includes("api key")||t.includes("api_key")||t.includes("provider")?"llm_error":"unknown"}function yp(e,t){return e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":t==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":t==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":t==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Il(e,t,n){return r(e)??yp(t,n)}function zl(e,t){return typeof e=="boolean"?e:t==="recover"}function sa(e){if(!m(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);return!t||!n||!s?null:{health_state:t,quiet_reason:r(e.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:le(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:zl(e.recoverable,n),summary:Il(e.summary,t,r(e.quiet_reason)??null),keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function Rl(e){return m(e)?{hour:d(e.hour),checked:d(e.checked)??0,acted:d(e.acted)??0,acted_names:w(e.acted_names),activity_report:r(e.activity_report),quiet_hours_overridden:j(e.quiet_hours_overridden),skipped_reason:r(e.skipped_reason),acted_rows:to(e.acted_rows,"summary").map(t=>({name:t.name,summary:t.summary})),passed_rows:to(e.passed_rows,"reason").map(t=>({name:t.name,reason:t.reason})),skipped_rows:to(e.skipped_rows,"reason").map(t=>({name:t.name,reason:t.reason})),checkins:Array.isArray(e.checkins)?e.checkins.map($p).filter(t=>t!==null):[]}:null}function bp(e){return m(e)?{enabled:j(e.enabled)??!1,interval_s:d(e.interval_s)??0,quiet_start:d(e.quiet_start),quiet_end:d(e.quiet_end),quiet_active:j(e.quiet_active),use_planner:j(e.use_planner),delegate_llm:j(e.delegate_llm),agent_count:d(e.agent_count),agents:w(e.agents),last_tick_ago_s:d(e.last_tick_ago_s)??null,last_tick_ago:r(e.last_tick_ago),total_ticks:d(e.total_ticks),total_checkins:d(e.total_checkins),last_skip_reason:r(e.last_skip_reason)??null,last_tick_result:Rl(e.last_tick_result),active_self_heartbeats:w(e.active_self_heartbeats)}:null}function kp(e){return m(e)?{status:e.status,diagnostic:sa(e.diagnostic)}:null}function xp(e){return m(e)?{recovered:j(e.recovered)??!1,skipped_reason:r(e.skipped_reason)??null,before:sa(e.before),after:sa(e.after),down:e.down,up:e.up}:null}function Sp(e,t){var _,I;if(!(e!=null&&e.name))return null;const n=r((_=e.agent)==null?void 0:_.status)??r(e.status)??"unknown",s=r((I=e.agent)==null?void 0:I.error)??null,a=e.presence_keepalive??!0,i=e.keepalive_running??!1,l=e.turn_count??0,c=e.last_turn_ago_s??null,u=e.proactive_enabled??!1,p=e.proactive_cooldown_sec??0,g=e.last_proactive_ago_s??null,f=u&&g!=null?Math.max(0,p-g):null,v=l<=0||c==null?"never":c>900?"stale":"fresh",h=typeof e.last_heartbeat=="string"&&e.last_heartbeat.trim()?e.last_heartbeat:null,b=s??(a&&!i?"keeper keepalive is not running":null),C=n==="offline"||n==="inactive"?"offline":b?"degraded":v==="stale"?"stale":v==="never"?"idle":"healthy",x=b?hp(b):t!=null&&t.quiet_active&&v!=="fresh"?"quiet_hours":a&&!i?"disabled":l<=0?"never_started":f!=null&&f>0?"min_gap":v==="fresh"||v==="stale"?"no_recent_activity":"unknown",S=C==="offline"||C==="degraded"||C==="stale"?"recover":x==="quiet_hours"?"manual_lodge_poke":x==="unknown"?"probe":"direct_message";return{health_state:C,quiet_reason:x,next_action_path:S,last_reply_status:v,last_reply_at:h,last_reply_preview:null,last_error:b,next_eligible_at_s:f!=null&&f>0?f:null,recoverable:zl(void 0,S),summary:Il(void 0,C,x),keepalive_running:i}}function Cp(e,t){if(!m(e))return null;const n=fp(e.role),s=r(e.content)??r(e.preview);if(!s)return null;const a=le(e.ts_unix)??le(e.timestamp);return{id:`${n}-${a??"entry"}-${t}`,role:n,label:gp(n),text:s,timestamp:a,delivery:"history"}}function Ap(e,t,n){const s=m(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((i,l)=>Cp(i,l)).filter(i=>i!==null):[];return{name:e,diagnostic:sa(s==null?void 0:s.diagnostic),history:a,rawText:t,rawStatus:n,loadedAt:new Date().toISOString()}}function mr(e,t){const n=_e.value[e]??[];_e.value={..._e.value,[e]:[...n,t].slice(-50)}}function Tp(e,t){return e.role!==t.role||e.text!==t.text?!1:e.timestamp&&t.timestamp?e.timestamp===t.timestamp:!0}function Ip(e,t){const s=(_e.value[e]??[]).filter(a=>a.delivery!=="history"&&!t.some(i=>Tp(a,i)));_e.value={..._e.value,[e]:[...t,...s].slice(-50)}}function Wa(e,t){Ye.value={...Ye.value,[e]:t},Ip(e,t.history)}function _r(e,t){const n=Ye.value[e];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Wa(e,{...n,diagnostic:{...s,...t}})}async function xi(){try{await rs()}catch(e){console.warn("[keeper-runtime] dashboard refresh failed",e)}}function zp(e){vp.value=e.trim()}async function Ll(e,t=!1){const n=e.trim();if(!n)return null;if(!t&&Ye.value[n])return Ye.value[n];ue(Ko,n,!0),ue(Qe,n,null);try{const s=await Ie("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const i=Ap(n,s,a);return Wa(n,i),i}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return ue(Qe,n,a),null}finally{ue(Ko,n,!1)}}async function Rp(e,t){const n=e.trim(),s=t.trim();if(!n||!s)return;const a=`local-${Date.now()}`;mr(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),ue(Ho,n,!0),ue(Qe,n,null);try{const i=await _p(n,s);_e.value={..._e.value,[n]:(_e.value[n]??[]).map(l=>l.id===a?{...l,delivery:"delivered"}:l)},mr(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),_r(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await xi()}catch(i){const l=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw _e.value={..._e.value,[n]:(_e.value[n]??[]).map(c=>c.id===a?{...c,delivery:"error",error:l}:c)},_r(n,{last_reply_status:"error",last_error:l}),ue(Qe,n,l),i}finally{ue(Ho,n,!1)}}async function Lp(e,t){const n=e.trim();if(!n)return null;ue(Uo,n,!0),ue(Qe,n,null);try{const s=await Ba({actor:t,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=kp(s.result),i=(a==null?void 0:a.diagnostic)??null;if(i){const l=Ye.value[n];Wa(n,{name:n,diagnostic:i,history:(l==null?void 0:l.history)??_e.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await xi(),i}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw ue(Qe,n,a),s}finally{ue(Uo,n,!1)}}async function Pp(e,t){const n=e.trim();if(!n)return null;ue(Bo,n,!0),ue(Qe,n,null);try{const s=await Ba({actor:t,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=xp(s.result),i=(a==null?void 0:a.after)??null;if(i){const l=Ye.value[n];Wa(n,{name:n,diagnostic:i,history:(l==null?void 0:l.history)??_e.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await xi(),i}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw ue(Qe,n,a),s}finally{ue(Bo,n,!1)}}function yt(e){return(e??"").trim().toLowerCase()}function ye(e){const t=typeof e=="number"?e:Date.parse(e);return Number.isNaN(t)?0:t}function Hs(e,t=88){const n=e.replace(/\s+/g," ").trim();return n&&(n.length>t?`${n.slice(0,t-3)}...`:n)}function Cs(e){return typeof e!="number"||!Number.isFinite(e)||e<0?null:new Date(Date.now()-e*1e3).toISOString()}function kn(e){return e.last_heartbeat??Cs(e.last_turn_ago_s)??Cs(e.last_proactive_ago_s)??Cs(e.last_handoff_ago_s)??Cs(e.last_compaction_ago_s)}function Mp(e){const t=e.title.trim();return t||Hs(e.content)}function jp(e){const t=e.generation??"?",n=typeof e.context_ratio=="number"&&Number.isFinite(e.context_ratio)?`${Math.round(e.context_ratio*100)}%`:"?";return e.last_heartbeat?`Heartbeat gen=${t} ctx=${n}`:`Keeper snapshot gen=${t} ctx=${n}`}function Ep(e,t,n,s,a={}){var I;const i=yt(e),l=t.filter(R=>yt(R.assignee)===i&&(R.status==="claimed"||R.status==="in_progress")).length,c=n.filter(R=>yt(R.from)===i).sort((R,L)=>ye(L.timestamp)-ye(R.timestamp))[0],u=s.filter(R=>yt(R.agent)===i||yt(R.author)===i).sort((R,L)=>ye(L.timestamp)-ye(R.timestamp))[0],p=(a.boardPosts??[]).filter(R=>yt(R.author)===i).sort((R,L)=>ye(L.updated_at||L.created_at)-ye(R.updated_at||R.created_at))[0],g=(a.keepers??[]).filter(R=>yt(R.name)===i&&kn(R)!==null).sort((R,L)=>ye(kn(L)??0)-ye(kn(R)??0))[0],f=c?ye(c.timestamp):0,v=u?ye(u.timestamp):0,h=p?ye(p.updated_at||p.created_at):0,b=g?ye(kn(g)??0):0,C=a.lastSeen?ye(a.lastSeen):0,x=((I=a.currentTask)==null?void 0:I.trim())||(l>0?`${l} claimed tasks`:null);if(f===0&&v===0&&h===0&&b===0&&C===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:x};const _=[c?{timestamp:c.timestamp,ts:f,text:Hs(c.content)}:null,p?{timestamp:p.updated_at||p.created_at,ts:h,text:`Post: ${Hs(Mp(p))}`}:null,g?{timestamp:kn(g),ts:b,text:jp(g)}:null,u?{timestamp:new Date(u.timestamp).toISOString(),ts:v,text:Hs(u.text)}:null].filter(R=>R!==null).sort((R,L)=>L.ts-R.ts)[0];return _&&_.ts>=C?{activeAssignedCount:l,lastActivityAt:_.timestamp,lastActivityText:_.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:x??"Presence heartbeat"}}const Xe=$([]),at=$([]),Wo=$([]),vt=$([]),re=$(null),Np=$(null),Pl=$(null),Ml=$([]),jl=$([]),El=$([]),Nl=$([]),Dl=$(null),Si=$([]),Ci=$([]),Ol=$([]),Go=$(new Map),Ga=$([]),Fn=$("recent"),At=$(!0),ql=$(null),Ve=$(""),Zt=$([]),zn=$(!1),wl=$(new Map),Ai=$("unknown"),en=$(null),Jo=$(!1),Kn=$(!1),Vo=$(!1),Rn=$(!1),Ti=$(null),aa=$(!1),oa=$(null),Fl=$(null),Yo=$(null),Dp=$(null),Op=$(null),qp=$(null);Pe(()=>Xe.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle"));const Kl=Pe(()=>{const e=at.value;return{todo:e.filter(t=>t.status==="todo"),inProgress:e.filter(t=>t.status==="in_progress"||t.status==="claimed"),done:e.filter(t=>t.status==="done")}}),Hl=Pe(()=>{const e=new Map,t=at.value,n=Wo.value,s=ta.value,a=Ga.value,i=vt.value;for(const l of Xe.value)e.set(l.name.trim().toLowerCase(),Ep(l.name,t,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:i}));return e});function wp(e){var i;const t=((i=e.status)==null?void 0:i.toLowerCase())??"";if(t==="offline"||t==="inactive")return"offline";const n=e.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}Pe(()=>{const e=new Map;for(const t of vt.value)e.set(t.name,wp(t));return e});const Fp=12e4;function Kp(e,t){const n=t.get(e.name);if(n!=null)return n;const s=e.last_heartbeat?Date.parse(e.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[e.last_turn_ago_s,e.last_proactive_ago_s,e.last_handoff_ago_s,e.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof a=="number"?Date.now()-a*1e3:null}Pe(()=>{const e=Date.now(),t=new Set,n=Go.value;for(const s of vt.value){const a=Kp(s,n);a!=null&&e-a>Fp&&t.add(s.name)}return t});function Hp(e){return e==="dashboard_refresh"||e==="masc/dashboard_refresh"||e.startsWith("goal_")||e.startsWith("masc/goal_")||e.startsWith("mdal_")||e.startsWith("masc/mdal_")||e.startsWith("operator_")||e.startsWith("masc/operator_")||e.startsWith("command_plane_")||e.startsWith("masc/command_plane_")}function Ul(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="active"||t==="busy"||t==="listening"||t==="idle"||t==="inactive"||t==="offline"?t:t==="in_progress"||t==="claimed"?"busy":"offline"}function Up(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="todo"||t==="in_progress"||t==="claimed"||t==="done"||t==="cancelled"?t:t==="inprogress"?"in_progress":"todo"}function Bp(e){if(!m(e))return null;const t=r(e.name);return t?{name:t,agent_type:r(e.agent_type),status:Ul(e.status),current_task:r(e.current_task)??null,joined_at:r(e.joined_at),last_seen:r(e.last_seen),capabilities:w(e.capabilities),emoji:r(e.emoji),koreanName:r(e.koreanName)??r(e.korean_name),model:r(e.model),traits:w(e.traits),interests:w(e.interests),activityLevel:d(e.activityLevel)??d(e.activity_level),primaryValue:r(e.primaryValue)??r(e.primary_value)}:null}function Wp(e){if(!m(e))return null;const t=r(e.id),n=r(e.title);return!t||!n?null:{id:t,title:n,status:Up(e.status),priority:d(e.priority),assignee:r(e.assignee),description:r(e.description),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function Gp(e){if(!m(e))return null;const t=r(e.from)??r(e.from_agent)??"system",n=r(e.content)??"",s=r(e.timestamp)??new Date().toISOString();return{id:r(e.id),seq:d(e.seq),from:t,content:n,timestamp:s,type:r(e.type)}}function Ii(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="ok"||t==="warn"||t==="bad"?t:"ok"}function Jp(e){return m(e)?{active_sessions:d(e.active_sessions),blocked_sessions:d(e.blocked_sessions),active_operations:d(e.active_operations),blocked_operations:d(e.blocked_operations),runtime_pressure:d(e.runtime_pressure),worker_alerts:d(e.worker_alerts),continuity_alerts:d(e.continuity_alerts),priority_items:d(e.priority_items),todo_tasks:d(e.todo_tasks),claimed_tasks:d(e.claimed_tasks),running_tasks:d(e.running_tasks),done_tasks:d(e.done_tasks),cancelled_tasks:d(e.cancelled_tasks),keepers:d(e.keepers)}:null}function ot(e){if(!m(e))return null;const t=r(e.surface),n=r(e.label),s=r(e.target_type),a=r(e.target_id),i=r(e.focus_kind);return!t||!n||!s||!a||!i?null:{surface:t==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:i,operation_id:r(e.operation_id)??null,command_surface:r(e.command_surface)??null}}function Vp(e){if(!m(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.summary),a=r(e.target_type),i=r(e.target_id);return!t||!s||!a||!i||n!=="session"&&n!=="operation"?null:{id:t,kind:n,severity:Ii(e.severity),status:r(e.status),summary:s,target_type:a,target_id:i,linked_session_id:r(e.linked_session_id)??null,linked_operation_id:r(e.linked_operation_id)??null,last_seen_at:r(e.last_seen_at)??null,top_handoff:ot(e.top_handoff),intervene_handoff:ot(e.intervene_handoff),command_handoff:ot(e.command_handoff)}}function Yp(e){if(!m(e))return null;const t=r(e.session_id),n=r(e.goal);return!t||!n?null:{session_id:t,goal:n,room:r(e.room)??null,status:r(e.status),health:r(e.health),member_names:w(e.member_names),linked_operation_id:r(e.linked_operation_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,runtime_blocker:r(e.runtime_blocker)??null,worker_gap_summary:r(e.worker_gap_summary)??null,last_activity_at:r(e.last_activity_at)??null,last_activity_summary:r(e.last_activity_summary)??null,communication_summary:r(e.communication_summary)??null,active_count:d(e.active_count),required_count:d(e.required_count),top_handoff:ot(e.top_handoff),intervene_handoff:ot(e.intervene_handoff),command_handoff:ot(e.command_handoff)}}function Qp(e){if(!m(e))return null;const t=r(e.operation_id),n=r(e.objective);return!t||!n?null:{operation_id:t,objective:n,status:r(e.status),stage:r(e.stage)??null,assigned_unit_id:r(e.assigned_unit_id)??null,assigned_unit_label:r(e.assigned_unit_label)??null,linked_session_id:r(e.linked_session_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,blocker_summary:r(e.blocker_summary)??null,search_status:r(e.search_status)??null,next_tool:r(e.next_tool)??null,updated_at:r(e.updated_at)??null,top_handoff:ot(e.top_handoff),command_handoff:ot(e.command_handoff)}}function vr(e){if(!m(e))return null;const t=r(e.name)??r(e.agent_name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline"?null:{name:t,agent_name:r(e.agent_name),status:r(e.status),tone:Ii(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,active_task_count:d(e.active_task_count),related_session_id:r(e.related_session_id)??null,related_operation_id:r(e.related_operation_id)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),model:r(e.model)??null,recent_output_preview:r(e.recent_output_preview)??null,recent_event:r(e.recent_event)??null}}function Xp(e){return m(e)?{checked:d(e.checked),acted:d(e.acted),passed:d(e.passed),skipped:d(e.skipped),failed:d(e.failed),last_tick_at:r(e.last_tick_at)??null,last_skip_reason:r(e.last_skip_reason)??null,activity_report:r(e.activity_report)??null}:null}function Zp(e){if(!m(e))return null;const t=r(e.agent_name),n=r(e.outcome);return!t||!n?null:{agent_name:t,trigger:r(e.trigger)??null,outcome:n,summary:r(e.summary)??null,reason:r(e.reason)??null,allowed_tool_names:w(e.allowed_tool_names)??[],used_tool_names:w(e.used_tool_names)??[],used_tool_call_count:d(e.used_tool_call_count)??null,action_kind:r(e.action_kind)??"none",tool_audit_source:r(e.tool_audit_source)??null,tool_audit_at:r(e.tool_audit_at)??null,checked_at:r(e.checked_at)??null,decision_reason:r(e.decision_reason)??null,worker_name:r(e.worker_name)??null,failure_reason:r(e.failure_reason)??null}}function em(e){if(!m(e))return null;const t=r(e.name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:t,agent_name:r(e.agent_name)??null,status:r(e.status),tone:Ii(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,last_autonomous_action_at:r(e.last_autonomous_action_at)??null,generation:d(e.generation),turn_count:d(e.turn_count),context_ratio:d(e.context_ratio)??null,continuity:r(e.continuity)??null,lifecycle:r(e.lifecycle)??null,related_session_id:r(e.related_session_id)??null,model:r(e.model)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),skill_reason:r(e.skill_reason)??null,recent_input_preview:r(e.recent_input_preview)??null,recent_output_preview:r(e.recent_output_preview)??null,recent_tool_names:w(e.recent_tool_names)??[],allowed_tool_names:w(e.allowed_tool_names)??[],latest_tool_names:w(e.latest_tool_names)??[],latest_tool_call_count:d(e.latest_tool_call_count)??null,tool_audit_source:r(e.tool_audit_source)??null,tool_audit_at:r(e.tool_audit_at)??null,last_proactive_preview:r(e.last_proactive_preview)??null,continuity_summary:r(e.continuity_summary)??null,skill_route_summary:r(e.skill_route_summary)??null}}function fr(e){if(typeof e.seq=="number"&&Number.isFinite(e.seq))return e.seq;const t=Date.parse(e.timestamp);return Number.isNaN(t)?0:t}function tm(e,t){if(t.length===0)return e;const n=new Map;for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>fr(s)-fr(a)).slice(-500)}function nm(e){return Array.isArray(e)?e.map(t=>{if(!m(t))return null;const n=d(t.ts_unix);if(n==null)return null;const s=m(t.handoff)?t.handoff:null;return{ts:n,context_ratio:d(t.context_ratio)??0,context_tokens:d(t.context_tokens)??0,context_max:d(t.context_max)??0,latency_ms:d(t.latency_ms)??0,generation:d(t.generation)??0,channel:typeof t.channel=="string"?t.channel:"turn",is_handoff:s!=null&&t.handoff_performed===!0,is_compaction:t.compacted===!0,compaction_saved_tokens:d(t.compaction_saved_tokens)??0,compaction_trigger:typeof t.compaction_trigger=="string"?t.compaction_trigger:null,model_used:typeof t.model_used=="string"?t.model_used:"",cost_usd:d(t.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?d(s.new_generation)??null:null}}).filter(t=>t!==null):[]}function gr(e){if(!m(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);if(!t||!n||!s)return null;const a=r(e.quiet_reason)??null,i=r(e.summary)??(t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:t,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:le(e.last_reply_at)??r(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:typeof e.recoverable=="boolean"?e.recoverable:n==="recover",summary:i,keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function sm(e,t){return(Array.isArray(e)?e:m(e)&&Array.isArray(e.keepers)?e.keepers:[]).map(s=>{if(!m(s))return null;const a=m(s.agent)?s.agent:null,i=m(s.context)?s.context:null,l=m(s.metrics_window)?s.metrics_window:void 0,c=r(s.name);if(!c)return null;const u=d(s.context_ratio)??d(i==null?void 0:i.context_ratio),p=r(s.status)??r(a==null?void 0:a.status)??"offline",g=Ul(p),f=r(s.model)??r(s.active_model)??r(s.primary_model),v=w(s.skill_secondary),h=i?{source:r(i.source),context_ratio:d(i.context_ratio),context_tokens:d(i.context_tokens),context_max:d(i.context_max),message_count:d(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,b=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:d(a.last_seen_ago_s),capabilities:w(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,C=nm(s.metrics_series),x={name:c,runtime_class:s.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:typeof s.desired=="boolean"?s.desired:void 0,resident_registered:typeof s.resident_registered=="boolean"?s.resident_registered:void 0,reconcile_status:r(s.reconcile_status)??null,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:f,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:g,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:d(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:d(s.proactive_idle_sec),proactive_cooldown_sec:d(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:d(s.generation),turn_count:d(s.turn_count)??d(s.total_turns),keeper_age_s:d(s.keeper_age_s),last_turn_ago_s:d(s.last_turn_ago_s),last_handoff_ago_s:d(s.last_handoff_ago_s),last_compaction_ago_s:d(s.last_compaction_ago_s),last_proactive_ago_s:d(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:u,context_tokens:d(s.context_tokens)??d(i==null?void 0:i.context_tokens),context_max:d(s.context_max)??d(i==null?void 0:i.context_max),context_source:r(s.context_source)??r(i==null?void 0:i.source),context:h,traits:w(s.traits),interests:w(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:d(s.activityLevel)??d(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:w(s.recent_tool_names)??[],allowed_tool_names:w(s.allowed_tool_names)??[],latest_tool_names:w(s.latest_tool_names)??[],latest_tool_call_count:d(s.latest_tool_call_count)??null,tool_audit_source:r(s.tool_audit_source)??null,tool_audit_at:le(s.tool_audit_at)??r(s.tool_audit_at)??null,conversation_tail_count:d(s.conversation_tail_count),k2k_count:d(s.k2k_count),handoff_count_total:d(s.handoff_count_total)??d(s.trace_history_count),compaction_count:d(s.compaction_count),last_compaction_saved_tokens:d(s.last_compaction_saved_tokens),diagnostic:gr(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:v,skill_reason:r(s.skill_reason)??null,metrics_series:C.length>0?C:void 0,metrics_window:l,agent:b};return x.diagnostic=gr(s.diagnostic)??Sp(x,(t==null?void 0:t.lodge)??null),x}).filter(s=>s!==null)}function am(e){if(!m(e))return;const t=r(e.release_version),n=le(e.started_at),s=d(e.uptime_seconds);if(!(!t||!n||s==null))return{release_version:t,commit:r(e.commit)??null,started_at:n,uptime_seconds:s}}function om(e){if(m(e))return{enabled:e.enabled===!0,alive:e.alive===!0,status:r(e.status)??void 0,tick_in_progress:typeof e.tick_in_progress=="boolean"?e.tick_in_progress:void 0,tick_count:d(e.tick_count)??void 0,check_interval_sec:d(e.check_interval_sec)??void 0,last_tick_started_at:le(e.last_tick_started_at)??r(e.last_tick_started_at)??null,last_tick_completed_at:le(e.last_tick_completed_at)??r(e.last_tick_completed_at)??null,next_tick_due_at:le(e.next_tick_due_at)??r(e.next_tick_due_at)??null,last_health_check_at:le(e.last_health_check_at)??r(e.last_health_check_at)??null,last_intervention:r(e.last_intervention)??void 0,last_decision_source:r(e.last_decision_source)??void 0,last_action:r(e.last_action)??void 0,last_target:r(e.last_target)??null,last_reason:r(e.last_reason)??null,last_error:r(e.last_error)??null,circuit_open:typeof e.circuit_open=="boolean"?e.circuit_open:void 0,circuit_open_until:le(e.circuit_open_until)??r(e.circuit_open_until)??null,can_spawn:typeof e.can_spawn=="boolean"?e.can_spawn:void 0,can_retire:typeof e.can_retire=="boolean"?e.can_retire:void 0,last_spawn_attempt_at:le(e.last_spawn_attempt_at)??r(e.last_spawn_attempt_at)??null,last_retirement_attempt_at:le(e.last_retirement_attempt_at)??r(e.last_retirement_attempt_at)??null,spawns_today:d(e.spawns_today)??void 0,retirements_today:d(e.retirements_today)??void 0,health_summary:m(e.health_summary)?{total_agents:d(e.health_summary.total_agents)??void 0,active_agents:d(e.health_summary.active_agents)??void 0,idle_agents:d(e.health_summary.idle_agents)??void 0,todo_count:d(e.health_summary.todo_count)??void 0,high_priority_todo:d(e.health_summary.high_priority_todo)??void 0,orphan_count:d(e.health_summary.orphan_count)??void 0,homeostatic_score:d(e.health_summary.homeostatic_score)??void 0,needs_workers:typeof e.health_summary.needs_workers=="boolean"?e.health_summary.needs_workers:void 0}:void 0}}function im(e){if(m(e))return{enabled:e.enabled===!0,mode:r(e.mode)??void 0,masc_enabled:typeof e.masc_enabled=="boolean"?e.masc_enabled:void 0,masc_loops_running:typeof e.masc_loops_running=="boolean"?e.masc_loops_running:void 0,runtime_owner:r(e.runtime_owner)??null,zombie_loop_running:typeof e.zombie_loop_running=="boolean"?e.zombie_loop_running:void 0,gc_loop_running:typeof e.gc_loop_running=="boolean"?e.gc_loop_running:void 0,lodge_enabled:typeof e.lodge_enabled=="boolean"?e.lodge_enabled:void 0,lodge_loop_started:typeof e.lodge_loop_started=="boolean"?e.lodge_loop_started:void 0,lodge_running:typeof e.lodge_running=="boolean"?e.lodge_running:void 0,last_zombie_cleanup:le(e.last_zombie_cleanup)??r(e.last_zombie_cleanup)??null,last_gc:le(e.last_gc)??r(e.last_gc)??null,last_lodge:le(e.last_lodge)??r(e.last_lodge)??null,last_zombie_result:r(e.last_zombie_result)??null,last_gc_result:r(e.last_gc_result)??null,last_lodge_result:m(e.last_lodge_result)?{ok:typeof e.last_lodge_result.ok=="boolean"?e.last_lodge_result.ok:void 0,message:r(e.last_lodge_result.message)??void 0}:null}}function rm(e){if(m(e))return{enabled:e.enabled===!0,started:e.started===!0,agent_name:r(e.agent_name)??null,llm_enabled:typeof e.llm_enabled=="boolean"?e.llm_enabled:void 0,uptime_s:d(e.uptime_s)??void 0,embedded_guardian_loops_running:typeof e.embedded_guardian_loops_running=="boolean"?e.embedded_guardian_loops_running:void 0,guardian_runtime_owner:r(e.guardian_runtime_owner)??null,consumers:w(e.consumers)}}function Bl(e,t){return m(e)?{...e,generated_at:t??le(e.generated_at)??void 0,build:am(e.build),lodge:bp(e.lodge)??void 0,gardener:om(e.gardener)??void 0,guardian:im(e.guardian)??void 0,sentinel:rm(e.sentinel)??void 0}:null}function Wl(e,t){return t?e?{...e,...t,build:t.build??e.build,generated_at:t.generated_at??e.generated_at}:t:e}function lm(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="running"||t==="interrupted"||t==="completed"||t==="stopped"||t==="error"?t:t.startsWith("error")?"error":"running"}function cm(e){if(!m(e))return null;const t=d(e.iteration);if(t==null)return null;const n=d(e.metric_before)??0,s=d(e.metric_after)??n,a=m(e.evidence)?e.evidence:null;return{iteration:t,metric_before:n,metric_after:s,delta:d(e.delta)??s-n,changes:r(e.changes)??"",failed_attempts:r(e.failed_attempts)??"",next_suggestion:r(e.next_suggestion)??"",elapsed_ms:d(e.elapsed_ms)??0,cost_usd:d(e.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:d(a.tool_call_count)??0,tool_names:w(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function dm(e){var i,l;if(!m(e))return null;const t=r(e.loop_id);if(!t)return null;const n=d(e.baseline_metric)??0,s=Array.isArray(e.history)?e.history.map(cm).filter(c=>c!==null):[],a=d(e.current_metric)??((i=s[0])==null?void 0:i.metric_after)??n;return{loop_id:t,profile:r(e.profile)??"unknown",status:lm(e.status),strict_mode:typeof e.strict_mode=="boolean"?e.strict_mode:void 0,error_message:r(e.error_message)??r(e.error_reason)??null,stop_reason:r(e.stop_reason)??r(e.reason)??null,current_iteration:d(e.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:d(e.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(e.target)??"",stagnation_streak:d(e.stagnation_streak)??0,stagnation_limit:d(e.stagnation_limit)??0,elapsed_seconds:d(e.elapsed_seconds)??0,updated_at:le(e.updated_at)??null,stopped_at:le(e.stopped_at)??null,execution_mode:e.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:e.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(e.worker_model)??null,evidence_policy:e.evidence_policy==="hard"||e.evidence_policy==="legacy"?e.evidence_policy:void 0,latest_tool_call_count:d(e.latest_tool_call_count)??0,latest_tool_names:w(e.latest_tool_names)??[],session_id:r(e.session_id)??null,evidence_status:e.evidence_status==="legacy_unverified"?"legacy_unverified":e.evidence_status==="verified"?"verified":null,durability:e.durability==="persistent_backend"||e.durability==="memory_only"?e.durability:void 0,persistence_backend:e.persistence_backend==="filesystem"||e.persistence_backend==="postgres"||e.persistence_backend==="memory"?e.persistence_backend:void 0,recoverable:typeof e.recoverable=="boolean"?e.recoverable:void 0,history:s}}async function rs(){Jo.value=!0;try{await Promise.all([Jl(),Tt()]),Fl.value=new Date().toISOString()}catch(e){console.error("Dashboard refresh error:",e)}finally{Jo.value=!1}}async function Gl(){aa.value=!0,oa.value=null;try{const e=await mu();Ti.value=e,qp.value=new Date().toISOString()}catch(e){oa.value=e instanceof Error?e.message:"Failed to load dashboard semantics"}finally{aa.value=!1}}function um(e){var t;return((t=Ti.value)==null?void 0:t.surfaces.find(n=>n.id===e))??null}function pm(e){var n;const t=((n=Ti.value)==null?void 0:n.surfaces)??[];for(const s of t){const a=s.panels.find(i=>i.id===e);if(a)return a}return null}function mm(e){var s,a;Zt.value=(Array.isArray(e.goals)?e.goals:[]).map(i=>{if(!m(i))return null;const l=r(i.id),c=r(i.title),u=r(i.horizon),p=r(i.status),g=r(i.created_at),f=r(i.updated_at);return!l||!c||!u||!p||!g||!f?null:{id:l,horizon:u,title:c,metric:r(i.metric)??null,target_value:r(i.target_value)??null,due_date:r(i.due_date)??null,priority:d(i.priority)??3,status:p,parent_goal_id:r(i.parent_goal_id)??null,last_review_note:r(i.last_review_note)??null,last_review_at:r(i.last_review_at)??null,created_at:g,updated_at:f}}).filter(i=>i!==null);const t=new Map,n=Array.isArray((s=e.mdal)==null?void 0:s.loops)?e.mdal.loops:[];for(const i of n){const l=dm(i);l&&t.set(l.loop_id,l)}wl.value=t,en.value=typeof((a=e.mdal)==null?void 0:a.error)=="string"?e.mdal.error:null,Ai.value=en.value?"error":t.size===0?"idle":"ready"}async function Jl(){try{const e=await lu(),t=Bl(e.status,e.generated_at);t&&(re.value=Wl(re.value,t))}catch(e){console.error("Dashboard shell fetch error:",e)}}async function Tt(){var e;try{const t=await du(),n=Bl(t.status,t.generated_at),s=(e=re.value)==null?void 0:e.room;n&&(re.value=Wl(re.value,n));const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Xe.value=(Array.isArray(t.agents)?t.agents:[]).map(Bp).filter(l=>l!==null),at.value=(Array.isArray(t.tasks)?t.tasks:[]).map(Wp).filter(l=>l!==null);const i=(Array.isArray(t.messages)?t.messages:[]).map(Gp).filter(l=>l!==null);Wo.value=a?i:tm(Wo.value,i),vt.value=sm(t.keepers,n??re.value),Pl.value=Jp(t.summary),Dl.value=Xp(t.lodge_tick),Si.value=(Array.isArray(t.lodge_checkins)?t.lodge_checkins:[]).map(Zp).filter(l=>l!==null),Ml.value=(Array.isArray(t.execution_queue)?t.execution_queue:Array.isArray(t.priority_queue)?t.priority_queue:[]).map(Vp).filter(l=>l!==null),jl.value=(Array.isArray(t.session_briefs)?t.session_briefs:[]).map(Yp).filter(l=>l!==null),El.value=(Array.isArray(t.operation_briefs)?t.operation_briefs:[]).map(Qp).filter(l=>l!==null),Nl.value=(Array.isArray(t.worker_support_briefs)?t.worker_support_briefs:Array.isArray(t.worker_briefs)?t.worker_briefs:[]).map(vr).filter(l=>l!==null),Ci.value=(Array.isArray(t.continuity_briefs)?t.continuity_briefs:[]).map(em).filter(l=>l!==null),Ol.value=(Array.isArray(t.offline_worker_briefs)?t.offline_worker_briefs:[]).map(vr).filter(l=>l!==null),Np.value=null,Fl.value=new Date().toISOString()}catch(t){console.error("Dashboard execution fetch error:",t)}}async function it(){Kn.value=!0;try{const e=await uu(Fn.value,{excludeSystem:At.value});Ga.value=e.posts??[],Yo.value=new Date().toISOString()}catch(e){console.error("Board fetch error:",e)}finally{Kn.value=!1}}async function rt(){var e;Vo.value=!0;try{const t=Ve.value||((e=re.value)==null?void 0:e.room)||"default";Ve.value||(Ve.value=t);const n=await Zu(t);ql.value=n}catch(t){console.error("TRPG fetch error:",t)}finally{Vo.value=!1}}async function zi(){zn.value=!0,Rn.value=!0;try{const e=await $u();mm(e),Dp.value=new Date().toISOString(),Op.value=new Date().toISOString()}catch(e){console.error("Planning fetch error:",e),Ai.value="error",en.value=e instanceof Error?e.message:String(e)}finally{zn.value=!1,Rn.value=!1}}async function Vl(){return zi()}const Ri=$(null),Qo=$(!1),ia=$(null);function _m(e){return m(e)?{room:r(e.room)??r(e.current_room),room_base_path:r(e.room_base_path),cluster:r(e.cluster),project:r(e.project),paused:j(e.paused),version:r(e.version),generated_at:r(e.generated_at),tempo_interval_s:d(e.tempo_interval_s)}:null}function vm(e){return m(e)?{active_sessions:d(e.active_sessions),blocked_sessions:d(e.blocked_sessions),active_operations:d(e.active_operations),blocked_operations:d(e.blocked_operations),runtime_pressure:d(e.runtime_pressure),worker_alerts:d(e.worker_alerts),continuity_alerts:d(e.continuity_alerts),priority_items:d(e.priority_items),keepers:d(e.keepers)}:null}function fm(e){if(!m(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.severity),a=r(e.summary),i=r(e.target_type),l=r(e.target_id);return!t||!n||!s||!a||!i||!l?null:{id:t,kind:n,severity:s,summary:a,target_type:i,target_id:l,status:r(e.status),linked_session_id:r(e.linked_session_id)??null,linked_operation_id:r(e.linked_operation_id)??null,last_seen_at:r(e.last_seen_at)??null,top_handoff:m(e.top_handoff)?e.top_handoff:null,intervene_handoff:m(e.intervene_handoff)?e.intervene_handoff:null,command_handoff:m(e.command_handoff)?e.command_handoff:null}}function gm(e){if(!m(e))return null;const t=r(e.kind),n=r(e.summary),s=r(e.target_type);return!t||!n||!s?null:{kind:t,severity:r(e.severity)??"warn",summary:n,target_type:s,target_id:r(e.target_id)??null,actor:r(e.actor)??null,evidence:e.evidence}}function $m(e){if(!m(e))return null;const t=r(e.action_type),n=r(e.target_type),s=r(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:r(e.target_id)??null,severity:r(e.severity)??"warn",reason:s,confirm_required:j(e.confirm_required),suggested_payload:m(e.suggested_payload)?e.suggested_payload:void 0,preview:e.preview}}function hm(e){return m(e)?{actor_filter:r(e.actor_filter)??null,filter_active:j(e.filter_active)??!1,visible_count:d(e.visible_count)??0,total_count:d(e.total_count)??0,hidden_count:d(e.hidden_count)??0,hidden_actors:w(e.hidden_actors),confirm_required_actions:ce(e.confirm_required_actions).flatMap(t=>{if(!m(t))return[];const n=r(t.action_type),s=r(t.target_type);return!n||!s?[]:[{action_type:n,target_type:s,description:r(t.description),confirm_required:j(t.confirm_required)}]})}:null}function ym(e){return m(e)?{count:d(e.count)??0,bad_count:d(e.bad_count)??0,warn_count:d(e.warn_count)??0,provenance:r(e.provenance)??null,top_item:gm(e.top_item)}:null}function bm(e){return m(e)?{count:d(e.count)??0,provenance:r(e.provenance)??null,top_action:$m(e.top_action)}:null}function km(e){if(!m(e))return null;const t=r(e.label),n=r(e.reason),s=r(e.source),a=r(e.provenance);return!t||!n||!s||!a?null:{label:t,reason:n,source:s,provenance:a,target_kind:r(e.target_kind)??null,target_id:r(e.target_id)??null,suggested_tab:r(e.suggested_tab)??null,suggested_surface:r(e.suggested_surface)??null,suggested_params:m(e.suggested_params)?Object.fromEntries(Object.entries(e.suggested_params).map(([i,l])=>{const c=r(l);return c?[i,c]:null}).filter(i=>i!==null)):{}}}function xm(e){const t=m(e)?e:{},n=m(t.room)?t.room:{},s=m(t.execution)?t.execution:{},a=m(t.command)?t.command:{},i=m(t.operator)?t.operator:{};return{generated_at:r(t.generated_at),room:{status:_m(n.status),counts:m(n.counts)?{agents:d(n.counts.agents),tasks:d(n.counts.tasks),keepers:d(n.counts.keepers)}:void 0,provenance:r(n.provenance)??null},execution:{summary:vm(s.summary),top_queue:fm(s.top_queue),provenance:r(s.provenance)??null},command:{active_operations:d(a.active_operations),active_detachments:d(a.active_detachments),pending_approvals:d(a.pending_approvals),bad_alerts:d(a.bad_alerts),warn_alerts:d(a.warn_alerts),moving_lanes:d(a.moving_lanes),active_lanes:d(a.active_lanes),provenance:r(a.provenance)??null},operator:{health:r(i.health)??null,attention_summary:ym(i.attention_summary),recommendation_summary:bm(i.recommendation_summary),pending_confirm_summary:hm(i.pending_confirm_summary),provenance:r(i.provenance)??null},focus:km(t.focus)}}async function It(){Qo.value=!0,ia.value=null;try{const e=await cu();Ri.value=xm(e)}catch(e){ia.value=e instanceof Error?e.message:"Failed to load room truth"}finally{Qo.value=!1}}let Us=null;function Sm(e){Us=e}let Bs=null;function Cm(e){Bs=e}let Ws=null;function Am(e){Ws=e}const zt={};let no=null;function bt(e,t,n=500){zt[e]&&clearTimeout(zt[e]),zt[e]=setTimeout(()=>{t(),delete zt[e]},n)}function Tm(){const e=_l.subscribe(t=>{if(t){if(t.type==="keeper_heartbeat"&&t.name){const n=new Map(Go.value);n.set(t.name,t.ts_unix?t.ts_unix*1e3:Date.now()),Go.value=n;return}(t.type==="agent_joined"||t.type==="agent_left")&&bt("execution",Tt),Hp(t.type)&&(no||(no=setTimeout(()=>{rs(),Bs==null||Bs(),Ws==null||Ws(),no=null},500))),(t.type.startsWith("task_")||t.type.startsWith("masc/task_"))&&bt("execution",Tt),t.type==="broadcast"&&bt("execution",Tt),(t.type==="keeper_handoff"||t.type==="keeper_compaction"||t.type==="keeper_guardrail")&&bt("execution",Tt),(t.type==="board_post"||t.type==="masc/board_post"||t.type==="board_comment"||t.type==="masc/board_comment")&&bt("board",it),t.type.startsWith("decision_")&&bt("council",()=>Us==null?void 0:Us()),(t.type==="mdal_started"||t.type==="mdal_iteration"||t.type==="mdal_completed"||t.type==="mdal_stopped")&&bt("mdal",Vl,350)}});return()=>{e();for(const t of Object.keys(zt))clearTimeout(zt[t]),delete zt[t]}}let Ln=null;function Im(){Ln||(Ln=setInterval(()=>{ut.value,rs()},1e4))}function zm(){Ln&&(clearInterval(Ln),Ln=null)}const he=$(null),Li=$(null),Ke=$(null),Hn=$(!1),pt=$(null),Un=$(!1),un=$(null),ae=$(!1),ra=$([]);let Rm=1;function Lm(e){return m(e)?{id:r(e.id),seq:d(e.seq),from:r(e.from)??r(e.from_agent)??"system",content:r(e.content)??"",timestamp:r(e.timestamp)??new Date().toISOString(),type:r(e.type)}:null}function Pm(e){return m(e)?{room_id:r(e.room_id),current_room:r(e.current_room)??r(e.room),project:r(e.project),cluster:r(e.cluster),paused:j(e.paused),pause_reason:r(e.pause_reason)??null,paused_by:r(e.paused_by)??null,paused_at:r(e.paused_at)??null}:{}}function $r(e){if(!m(e))return;const t=Object.entries(e).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return t.length>0?Object.fromEntries(t):void 0}function Yl(e){if(!m(e))return null;const t=r(e.kind),n=r(e.summary),s=r(e.target_type);return!t||!n||!s?null:{kind:t,severity:r(e.severity)??"warn",summary:n,target_type:s,target_id:r(e.target_id)??null,actor:r(e.actor)??null,evidence:e.evidence}}function Pn(e){if(!m(e))return null;const t=r(e.action_type),n=r(e.target_type),s=r(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:r(e.target_id)??null,severity:r(e.severity)??"warn",reason:s,confirm_required:j(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function Ql(e){return m(e)?{enabled:j(e.enabled),judge_online:j(e.judge_online),refreshing:j(e.refreshing),generated_at:r(e.generated_at)??null,expires_at:r(e.expires_at)??null,model_used:r(e.model_used)??null,keeper_name:r(e.keeper_name)??null,last_error:r(e.last_error)??null}:null}function so(e){return m(e)?{summary:r(e.summary)??null,confidence:d(e.confidence)??null,provenance:r(e.provenance)??null,authoritative:j(e.authoritative),surface:r(e.surface)??null,fresh_until:r(e.fresh_until)??null,keeper_name:r(e.keeper_name)??null,fallback_used:j(e.fallback_used),disagreement_with_truth:j(e.disagreement_with_truth)}:null}function Mm(e){return m(e)?{judgment_id:r(e.judgment_id)??void 0,surface:r(e.surface)??null,target_type:r(e.target_type)??null,target_id:r(e.target_id)??null,status:r(e.status)??null,summary:r(e.summary)??null,confidence:d(e.confidence)??null,generated_at:r(e.generated_at)??null,fresh_until:r(e.fresh_until)??null,keeper_name:r(e.keeper_name)??null,model_name:r(e.model_name)??null,runtime_name:r(e.runtime_name)??null,evidence_refs:w(e.evidence_refs),recommended_action:Pn(e.recommended_action),supersedes:w(e.supersedes),fallback_used:j(e.fallback_used),disagreement_with_truth:j(e.disagreement_with_truth),provenance:r(e.provenance)??null}:null}function jm(e){return m(e)?{actor:r(e.actor)??null,spawn_agent:r(e.spawn_agent)??null,spawn_role:r(e.spawn_role)??null,spawn_model:r(e.spawn_model)??null,worker_class:r(e.worker_class)??null,parent_actor:r(e.parent_actor)??null,capsule_mode:r(e.capsule_mode)??null,runtime_pool:r(e.runtime_pool)??null,lane_id:r(e.lane_id)??null,controller_level:r(e.controller_level)??null,control_domain:r(e.control_domain)??null,supervisor_actor:r(e.supervisor_actor)??null,model_tier:r(e.model_tier)??null,task_profile:r(e.task_profile)??null,risk_level:r(e.risk_level)??null,routing_confidence:d(e.routing_confidence)??null,routing_reason:r(e.routing_reason)??null,status:r(e.status)??"unknown",turn_count:d(e.turn_count)??0,empty_note_turn_count:d(e.empty_note_turn_count)??0,has_turn:j(e.has_turn)??!1,last_turn_ts_iso:r(e.last_turn_ts_iso)??null}:null}function Em(e){if(!m(e))return null;const t=r(e.session_id);return t?{session_id:t,goal:r(e.goal),status:r(e.status),health:r(e.health),scale_profile:r(e.scale_profile),control_profile:r(e.control_profile),planned_worker_count:d(e.planned_worker_count),active_agent_count:d(e.active_agent_count),last_turn_age_sec:d(e.last_turn_age_sec)??null,attention_count:d(e.attention_count),recommended_action_count:d(e.recommended_action_count),top_attention:Yl(e.top_attention),top_recommendation:Pn(e.top_recommendation)}:null}function hr(e){if(!m(e))return;const t=r(e.loop_id),n=r(e.status);if(!(!t&&!n))return{loop_id:t??void 0,session_id:r(e.session_id)??void 0,status:n??void 0,current_cycle:d(e.current_cycle)??void 0,best_score:d(e.best_score)??void 0,last_decision:r(e.last_decision)??null,target_file:r(e.target_file)??void 0,workdir:r(e.workdir)??void 0,source_workdir:r(e.source_workdir)??void 0,program_note:r(e.program_note)??null,operation_id:r(e.operation_id)??null,queued_hypothesis:r(e.queued_hypothesis)??null,warnings:ce(e.warnings).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),error:r(e.error)??null}}function Xl(e){const t=m(e)?e:{};return{trace_id:r(t.trace_id),target_type:r(t.target_type)??"room",target_id:r(t.target_id)??null,health:r(t.health),judgment_owner:r(t.judgment_owner)??null,authoritative_judgment_available:j(t.authoritative_judgment_available),resident_judge_runtime:Ql(t.resident_judge_runtime),judgment:Mm(t.judgment),active_guidance_layer:r(t.active_guidance_layer)??null,active_summary:so(t.active_summary),active_recommended_actions:ce(t.active_recommended_actions).map(Pn).filter(n=>n!==null),active_recommendation_source:r(t.active_recommendation_source)??null,active_recommendation_summary:so(t.active_recommendation_summary),fallback_recommended_actions:ce(t.fallback_recommended_actions).map(Pn).filter(n=>n!==null),recommendation_summary:so(t.recommendation_summary),swarm_status:m(t.swarm_status)?t.swarm_status:void 0,attention_items:ce(t.attention_items).map(Yl).filter(n=>n!==null),recommended_actions:ce(t.recommended_actions).map(Pn).filter(n=>n!==null),session_cards:ce(t.session_cards).map(Em).filter(n=>n!==null),worker_cards:ce(t.worker_cards).map(jm).filter(n=>n!==null)}}function Nm(e){if(!m(e))return null;const t=m(e.status)?e.status:void 0,n=m(e.summary)?e.summary:m(t==null?void 0:t.summary)?t.summary:void 0,s=m(e.session)?e.session:m(t==null?void 0:t.session)?t.session:void 0,a=r(e.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const i=$r(e.report_paths)??$r(t==null?void 0:t.report_paths),l=ce(e.recent_events,["events"]).filter(m);return{session_id:a,status:r(e.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:d(e.progress_pct)??d(n==null?void 0:n.progress_pct),elapsed_sec:d(e.elapsed_sec)??d(n==null?void 0:n.elapsed_sec),remaining_sec:d(e.remaining_sec)??d(n==null?void 0:n.remaining_sec),done_delta_total:d(e.done_delta_total)??d(n==null?void 0:n.done_delta_total),summary:n,team_health:m(e.team_health)?e.team_health:m(t==null?void 0:t.team_health)?t.team_health:void 0,communication_metrics:m(e.communication_metrics)?e.communication_metrics:m(t==null?void 0:t.communication_metrics)?t.communication_metrics:void 0,orchestration_state:m(e.orchestration_state)?e.orchestration_state:m(t==null?void 0:t.orchestration_state)?t.orchestration_state:void 0,cascade_metrics:m(e.cascade_metrics)?e.cascade_metrics:m(t==null?void 0:t.cascade_metrics)?t.cascade_metrics:void 0,report_paths:i,linked_autoresearch:hr(e.linked_autoresearch)??hr(t==null?void 0:t.linked_autoresearch),session:s,recent_events:l}}function yr(e){if(!m(e))return null;const t=r(e.name);if(!t)return null;const n=m(e.context)?e.context:void 0;return{name:t,runtime_class:e.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:j(e.desired),resident_registered:j(e.resident_registered),agent_name:r(e.agent_name),status:r(e.status),autonomy_level:r(e.autonomy_level),context_ratio:d(e.context_ratio)??d(n==null?void 0:n.context_ratio),generation:d(e.generation),active_goal_ids:w(e.active_goal_ids),last_autonomous_action_at:r(e.last_autonomous_action_at)??null,last_turn_ago_s:d(e.last_turn_ago_s),model:r(e.model)??r(e.active_model)??r(e.primary_model)}}function Dm(e){if(!m(e))return null;const t=r(e.confirm_token)??r(e.token);return t?{confirm_token:t,actor:r(e.actor),action_type:r(e.action_type),target_type:r(e.target_type),target_id:r(e.target_id)??null,delegated_tool:r(e.delegated_tool),created_at:r(e.created_at),preview:e.preview}:null}function Zl(e){if(!m(e))return null;const t=r(e.action_type),n=r(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:r(e.description),confirm_required:j(e.confirm_required)}}function Om(e){return m(e)?{actor_filter:r(e.actor_filter)??null,filter_active:j(e.filter_active)??!1,visible_count:d(e.visible_count)??0,total_count:d(e.total_count)??0,hidden_count:d(e.hidden_count)??0,hidden_actors:w(e.hidden_actors),confirm_required_actions:ce(e.confirm_required_actions).map(Zl).filter(t=>t!==null)}:null}function qm(e){const t=m(e)?e:{};return{room:Pm(t.room),sessions:ce(t.sessions,["items","sessions"]).map(Nm).filter(n=>n!==null),keepers:ce(t.keepers,["items","keepers"]).map(yr).filter(n=>n!==null),resident_judge_runtime:Ql(t.resident_judge_runtime),persistent_agents:ce(t.persistent_agents,["items","persistent_agents"]).map(yr).filter(n=>n!==null),recent_messages:ce(t.recent_messages,["messages"]).map(Lm).filter(n=>n!==null),pending_confirms:ce(t.pending_confirms,["items","confirms"]).map(Dm).filter(n=>n!==null),pending_confirm_summary:Om(t.pending_confirm_summary)??void 0,available_actions:ce(t.available_actions,["actions"]).map(Zl).filter(n=>n!==null)}}function As(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e)}catch{return String(e)}}function br(e){return e.target_id?`${e.target_type}:${e.target_id}`:e.target_type}function la(e){ra.value=[{...e,id:Rm++,at:new Date().toISOString()},...ra.value].slice(0,20)}function ec(e){return e.confirm_required?As(e.preview)||"Confirmation required":As(e.result)||As(e.executed_action)||As(e.delegated_tool_result)||e.status}async function ge(){Hn.value=!0,pt.value=null;try{const e=await bu();he.value=qm(e)}catch(e){pt.value=e instanceof Error?e.message:"Failed to load operator snapshot"}finally{Hn.value=!1}}async function jt(){Un.value=!0,un.value=null;try{const e=await yl({targetType:"room"});Li.value=Xl(e)}catch(e){un.value=e instanceof Error?e.message:"Failed to load operator digest"}finally{Un.value=!1}}async function Et(e){if(!e){Ke.value=null;return}Un.value=!0,un.value=null;try{const t=await yl({targetType:"team_session",targetId:e,includeWorkers:!0});Ke.value=Xl(t)}catch(t){un.value=t instanceof Error?t.message:"Failed to load session digest"}finally{Un.value=!1}}async function tc(e){var t;ae.value=!0,pt.value=null;try{const n=await Ba(e);return la({actor:e.actor,action_type:e.action_type,target_label:br(e),outcome:n.confirm_required?"preview":"executed",message:ec(n),delegated_tool:n.delegated_tool}),await ge(),await jt(),(t=Ke.value)!=null&&t.target_id&&await Et(Ke.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw pt.value=s,la({actor:e.actor,action_type:e.action_type,target_label:br(e),outcome:"error",message:s}),n}finally{ae.value=!1}}async function nc(e,t,n="confirm"){var s;ae.value=!0,pt.value=null;try{const a=await bl(e,t,n);return la({actor:e,action_type:n,target_label:t,outcome:"confirmed",message:ec(a),delegated_tool:a.delegated_tool}),await ge(),await jt(),(s=Ke.value)!=null&&s.target_id&&await Et(Ke.value.target_id),a}catch(a){const i=a instanceof Error?a.message:"Operator confirmation failed";throw pt.value=i,la({actor:e,action_type:"confirm",target_label:t,outcome:"error",message:i}),a}finally{ae.value=!1}}Am(()=>{var e;ge(),jt(),(e=Ke.value)!=null&&e.target_id&&Et(Ke.value.target_id)});const ls=$(null),Xo=$(!1),ca=$(null),sc=$(null),Ut=$(!1),Ct=$(null),Zo=$(null),Gs=$(!1),Js=$(null);let tn=null;function kr(){tn!==null&&(window.clearTimeout(tn),tn=null)}function wm(e=1500){tn===null&&(tn=window.setTimeout(()=>{tn=null,da(!1)},e))}function N(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function y(e){return typeof e=="string"&&e.trim()!==""?e:void 0}function D(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function nn(e){return typeof e=="boolean"?e:void 0}function B(e,t=[]){if(Array.isArray(e))return e;if(!N(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function gn(e){if(!N(e))return null;const t=y(e.kind),n=y(e.summary),s=y(e.target_type);return!t||!n||!s?null:{kind:t,severity:y(e.severity)??"warn",summary:n,target_type:s,target_id:y(e.target_id)??null,actor:y(e.actor)??null,evidence:e.evidence}}function Nt(e){if(!N(e))return null;const t=y(e.action_type),n=y(e.target_type),s=y(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:y(e.target_id)??null,severity:y(e.severity)??"warn",reason:s,confirm_required:nn(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function Fm(e){if(!N(e))return null;const t=y(e.session_id);return t?{session_id:t,goal:y(e.goal),status:y(e.status),health:y(e.health),scale_profile:y(e.scale_profile),control_profile:y(e.control_profile),planned_worker_count:D(e.planned_worker_count),active_agent_count:D(e.active_agent_count),last_turn_age_sec:D(e.last_turn_age_sec)??null,attention_count:D(e.attention_count),recommended_action_count:D(e.recommended_action_count),top_attention:gn(e.top_attention),top_recommendation:Nt(e.top_recommendation)}:null}function Km(e){if(!N(e))return null;const t=y(e.session_id);if(!t)return null;const n=N(e.status)?e.status:e,s=N(n.summary)?n.summary:void 0;return{session_id:t,status:y(e.status)??y(s==null?void 0:s.status)??(N(n.session)?y(n.session.status):void 0),progress_pct:D(e.progress_pct)??D(s==null?void 0:s.progress_pct),elapsed_sec:D(e.elapsed_sec)??D(s==null?void 0:s.elapsed_sec),remaining_sec:D(e.remaining_sec)??D(s==null?void 0:s.remaining_sec),done_delta_total:D(e.done_delta_total)??D(s==null?void 0:s.done_delta_total),summary:N(e.summary)?e.summary:s,team_health:N(e.team_health)?e.team_health:N(n.team_health)?n.team_health:void 0,communication_metrics:N(e.communication_metrics)?e.communication_metrics:N(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:N(e.orchestration_state)?e.orchestration_state:N(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:N(e.cascade_metrics)?e.cascade_metrics:N(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:N(e.report_paths)?Object.fromEntries(Object.entries(e.report_paths).map(([a,i])=>{const l=y(i);return l?[a,l]:null}).filter(a=>a!==null)):N(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,i])=>{const l=y(i);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:N(e.session)?e.session:N(n.session)?n.session:void 0,recent_events:B(e.recent_events,["events"]).filter(N)}}function Hm(e){if(!N(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name),status:y(e.status),autonomy_level:y(e.autonomy_level),context_ratio:D(e.context_ratio),generation:D(e.generation),active_goal_ids:B(e.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:y(e.last_autonomous_action_at)??null,last_turn_ago_s:D(e.last_turn_ago_s),model:y(e.model)}:null}function Um(e){if(!N(e))return null;const t=y(e.confirm_token)??y(e.token);return t?{confirm_token:t,actor:y(e.actor),action_type:y(e.action_type),target_type:y(e.target_type),target_id:y(e.target_id)??null,delegated_tool:y(e.delegated_tool),created_at:y(e.created_at),preview:e.preview}:null}function Bm(e){if(!N(e))return null;const t=y(e.action_type),n=y(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:y(e.description),confirm_required:nn(e.confirm_required)}}function Wm(e){const t=N(e)?e:{};return{room_health:y(t.room_health),cluster:y(t.cluster),project:y(t.project),current_room:y(t.current_room)??null,paused:nn(t.paused),tempo_interval_s:D(t.tempo_interval_s),active_agents:D(t.active_agents),keeper_pressure:D(t.keeper_pressure),active_operations:D(t.active_operations),pending_approvals:D(t.pending_approvals),incident_count:D(t.incident_count),recommended_action_count:D(t.recommended_action_count),top_attention:gn(t.top_attention),top_action:Nt(t.top_action)}}function Gm(e){const t=N(e)?e:{},n=N(t.swarm_overview)?t.swarm_overview:{};return{health:y(t.health),active_operations:D(t.active_operations),pending_approvals:D(t.pending_approvals),swarm_overview:{active_lanes:D(n.active_lanes),moving_lanes:D(n.moving_lanes),stalled_lanes:D(n.stalled_lanes),projected_lanes:D(n.projected_lanes),last_movement_at:y(n.last_movement_at)??null},top_attention:gn(t.top_attention),top_action:Nt(t.top_action),session_cards:B(t.session_cards).map(Fm).filter(s=>s!==null)}}function Jm(e){const t=N(e)?e:{};return{sessions:B(t.sessions,["items"]).map(Km).filter(n=>n!==null),keepers:B(t.keepers,["items"]).map(Hm).filter(n=>n!==null),pending_confirms:B(t.pending_confirms).map(Um).filter(n=>n!==null),available_actions:B(t.available_actions).map(Bm).filter(n=>n!==null)}}function Vm(e){if(!N(e))return null;const t=y(e.id),n=y(e.kind),s=y(e.summary),a=y(e.target_type);return!t||!n||!s||!a?null:{id:t,kind:n,severity:y(e.severity)??"warn",summary:s,target_type:a,target_id:y(e.target_id)??null,top_action:Nt(e.top_action),related_session_ids:B(e.related_session_ids).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),related_agent_names:B(e.related_agent_names).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),evidence_preview:B(e.evidence_preview).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),last_seen_at:y(e.last_seen_at)??null}}function ac(e){if(!N(e))return null;const t=y(e.session_id),n=y(e.goal);return!t||!n?null:{session_id:t,goal:n,room:y(e.room)??null,status:y(e.status),health:y(e.health),member_names:B(e.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:y(e.started_at)??null,elapsed_sec:D(e.elapsed_sec)??null,operation_id:y(e.operation_id)??null,blocker_summary:y(e.blocker_summary)??null,last_event_at:y(e.last_event_at)??null,last_event_summary:y(e.last_event_summary)??null,communication_summary:y(e.communication_summary)??null,active_count:D(e.active_count),required_count:D(e.required_count),related_attention_count:D(e.related_attention_count)??0,top_attention:gn(e.top_attention),top_recommendation:Nt(e.top_recommendation)}}function oc(e){if(!N(e))return null;const t=y(e.agent_name);return t?{agent_name:t,status:y(e.status),current_work:y(e.current_work)??null,recent_input_preview:y(e.recent_input_preview)??null,recent_output_preview:y(e.recent_output_preview)??null,recent_tool_names:B(e.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_activity_at:y(e.last_activity_at)??null}:null}function ic(e){if(!N(e))return null;const t=y(e.operation_id);return t?{operation_id:t,status:y(e.status),stage:y(e.stage)??null,detachment_status:y(e.detachment_status)??null,objective:y(e.objective)??null,updated_at:y(e.updated_at)??null}:null}function rc(e){if(!N(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name)??null,status:y(e.status),generation:D(e.generation),context_ratio:D(e.context_ratio)??null,last_turn_ago_s:D(e.last_turn_ago_s)??null,current_work:y(e.current_work)??null}:null}function lc(e){const t=ac(e);return t?{...t,member_previews:B(N(e)?e.member_previews:void 0).map(oc).filter(n=>n!==null),operation_badges:B(N(e)?e.operation_badges:void 0).map(ic).filter(n=>n!==null),keeper_refs:B(N(e)?e.keeper_refs:void 0).map(rc).filter(n=>n!==null)}:null}function Ym(e){if(!N(e))return null;const t=y(e.agent_name);return t?{agent_name:t,status:y(e.status),where:y(e.where)??null,with_whom:B(e.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:y(e.current_work)??null,related_session_id:y(e.related_session_id)??null,related_attention_count:D(e.related_attention_count)??0,last_activity_at:y(e.last_activity_at)??null,recent_output_preview:y(e.recent_output_preview)??null,recent_input_preview:y(e.recent_input_preview)??null,recent_event:y(e.recent_event)??null,recent_tool_names:B(e.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),allowed_tool_names:B(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:B(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:D(e.latest_tool_call_count)??null,tool_audit_source:y(e.tool_audit_source)??null,tool_audit_at:y(e.tool_audit_at)??null}:null}function Qm(e){if(!N(e))return null;const t=y(e.name);return t?{name:t,agent_name:y(e.agent_name)??null,status:y(e.status),generation:D(e.generation),context_ratio:D(e.context_ratio)??null,last_turn_ago_s:D(e.last_turn_ago_s)??null,current_work:y(e.current_work)??null,last_autonomous_action_at:y(e.last_autonomous_action_at)??null,allowed_tool_names:B(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:B(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:D(e.latest_tool_call_count)??null,tool_audit_source:y(e.tool_audit_source)??null,tool_audit_at:y(e.tool_audit_at)??null}:null}function Xm(e){if(!N(e))return null;const t=y(e.id),n=y(e.signal_type),s=y(e.summary),a=y(e.target_type);return!t||!n||!s||!a?null:{id:t,signal_type:n==="action"?"action":"attention",severity:y(e.severity)??"warn",summary:s,target_type:a,target_id:y(e.target_id)??null,attention:gn(e.attention),action:Nt(e.action)}}function Zm(e){const t=N(e)?e:{},n=B(t.session_briefs).map(ac).filter(a=>a!==null),s=B(t.sessions).map(lc).filter(a=>a!==null);return{generated_at:y(t.generated_at),summary:Wm(t.summary),incidents:B(t.incidents).map(gn).filter(a=>a!==null),recommended_actions:B(t.recommended_actions).map(Nt).filter(a=>a!==null),command_focus:Gm(t.command_focus),operator_targets:Jm(t.operator_targets),attention_queue:B(t.attention_queue).map(Vm).filter(a=>a!==null),sessions:s.length>0?s:n.map(a=>({...a,member_previews:[],operation_badges:[],keeper_refs:[]})),session_briefs:n,agent_briefs:B(t.agent_briefs).map(Ym).filter(a=>a!==null),keeper_briefs:B(t.keeper_briefs).map(Qm).filter(a=>a!==null),internal_signals:B(t.internal_signals).map(Xm).filter(a=>a!==null)}}function e_(e){if(!N(e))return null;const t=y(e.id),n=y(e.summary);return!t||!n?null:{id:t,timestamp:y(e.timestamp)??null,event_type:y(e.event_type),actor:y(e.actor)??null,summary:n}}function t_(e){const t=N(e)?e:{};return{generated_at:y(t.generated_at),session_id:y(t.session_id)??"",session:lc(t.session),timeline:B(t.timeline).map(e_).filter(n=>n!==null),participants:B(t.participants).map(oc).filter(n=>n!==null),operations:B(t.operations).map(ic).filter(n=>n!==null),keepers:B(t.keepers).map(rc).filter(n=>n!==null),error:y(t.error)??null}}function n_(e){if(!N(e))return null;const t=y(e.id),n=y(e.label),s=y(e.summary);if(!t||!n||!s)return null;const a=y(e.status)??"unclear";return{id:t,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:y(e.signal_class)==="metadata_gap"||y(e.signal_class)==="mixed"||y(e.signal_class)==="operational_risk"?y(e.signal_class):void 0,evidence_quality:y(e.evidence_quality)==="strong"||y(e.evidence_quality)==="partial"||y(e.evidence_quality)==="missing"?y(e.evidence_quality):void 0,evidence:B(e.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function s_(e){if(!N(e))return null;const t=y(e.kind),n=y(e.summary),s=y(e.scope_type),a=y(e.severity);return!t||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:t,summary:n,scope_type:s,scope_id:y(e.scope_id)??null,severity:a}}function a_(e){const t=N(e)?e:{},n=N(t.basis)?t.basis:{},s=y(t.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:y(t.generated_at),cached:nn(t.cached),stale:nn(t.stale),refreshing:nn(t.refreshing),status:a,summary:y(t.summary)??null,model:y(t.model)??null,ttl_sec:D(t.ttl_sec),criteria:B(t.criteria).map(i=>typeof i=="string"?i.trim():"").filter(Boolean),basis:{current_room:y(n.current_room)??null,crew_count:D(n.crew_count),agent_count:D(n.agent_count),keeper_count:D(n.keeper_count)},metadata_gap_count:D(t.metadata_gap_count),metadata_gaps:B(t.metadata_gaps).map(s_).filter(i=>i!==null),sections:B(t.sections).map(n_).filter(i=>i!==null),error:y(t.error)??null,last_error:y(t.last_error)??null}}async function cc(){Xo.value=!0,ca.value=null;try{const e=await _u();ls.value=Zm(e)}catch(e){ca.value=e instanceof Error?e.message:"Failed to load mission snapshot"}finally{Xo.value=!1}}async function o_(e){if(!e){Zo.value=null,Js.value=null,Gs.value=!1;return}Gs.value=!0,Js.value=null;try{const t=await vu(e);Zo.value=t_(t)}catch(t){Js.value=t instanceof Error?t.message:"Failed to load session detail"}finally{Gs.value=!1}}async function da(e=!1){Ut.value=!0,Ct.value=null;try{const t=await fu(e),n=a_(t);sc.value=n,n.refreshing||n.status==="pending"?wm():kr()}catch(t){Ct.value=t instanceof Error?t.message:"Failed to load mission briefing",kr()}finally{Ut.value=!1}}const dc=$(null),ei=$(!1),Bt=$(null);async function uc(e,t){ei.value=!0,Bt.value=null;try{dc.value=await gu(e,t)}catch(n){Bt.value=n instanceof Error?n.message:String(n)}finally{ei.value=!1}}const Pi=$(null),Ue=$(null),ua=$(!1),pa=$(!1),ma=$(null),_a=$(null),ti=$(null),va=$(null),Y=$("warroom"),cs=$(null),ni=$(!1),fa=$(null),Dt=$(null),ga=$(!1),$a=$(null),Mi=$(null),si=$(!1),ha=$(null),ds=$(null),ai=$(!1),ya=$(null),Bn=$(null),ba=$(!1),Wn=$(null),sn=$(null);let Tn=null;function ji(e){return e!=="summary"&&e!=="swarm"&&e!=="warroom"&&e!=="orchestra"}function pc(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,i)=>{e.has(i)||e.set(i,a)}),e}function mc(){const t=pc().get("run_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function _c(){const t=pc().get("operation_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function i_(e){if(m(e))return{policy_class:r(e.policy_class),approval_class:r(e.approval_class),tool_allowlist:w(e.tool_allowlist),model_allowlist:w(e.model_allowlist),requires_human_for:w(e.requires_human_for),autonomy_level:r(e.autonomy_level),escalation_timeout_sec:d(e.escalation_timeout_sec),kill_switch:j(e.kill_switch),frozen:j(e.frozen)}}function r_(e){if(m(e))return{headcount_cap:d(e.headcount_cap),active_operation_cap:d(e.active_operation_cap),max_cost_usd:d(e.max_cost_usd),max_tokens:d(e.max_tokens)}}function Ei(e){if(!m(e))return null;const t=r(e.unit_id),n=r(e.label),s=r(e.kind);return!t||!n||!s?null:{unit_id:t,label:n,kind:s,parent_unit_id:r(e.parent_unit_id)??null,leader_id:r(e.leader_id)??null,roster:w(e.roster),capability_profile:w(e.capability_profile),source:r(e.source),created_at:r(e.created_at),updated_at:r(e.updated_at),policy:i_(e.policy),budget:r_(e.budget)}}function vc(e){if(!m(e))return null;const t=Ei(e.unit);return t?{unit:t,leader_status:r(e.leader_status),roster_total:d(e.roster_total),roster_live:d(e.roster_live),active_operation_count:d(e.active_operation_count),health:r(e.health),reasons:w(e.reasons),children:Array.isArray(e.children)?e.children.map(vc).filter(n=>n!==null):[]}:null}function l_(e){if(m(e))return{total_units:d(e.total_units),company_count:d(e.company_count),platoon_count:d(e.platoon_count),squad_count:d(e.squad_count),leaf_agent_unit_count:d(e.leaf_agent_unit_count),live_agent_count:d(e.live_agent_count),managed_unit_count:d(e.managed_unit_count),active_operation_count:d(e.active_operation_count)}}function fc(e){const t=m(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),source:r(t.source),summary:l_(t.summary),units:Array.isArray(t.units)?t.units.map(vc).filter(n=>n!==null):[]}}function c_(e){if(!m(e))return null;const t=r(e.kind),n=r(e.status);return!t||!n?null:{kind:t,chain_id:r(e.chain_id)??null,goal:r(e.goal)??null,run_id:r(e.run_id)??null,status:n,viewer_path:r(e.viewer_path)??null,last_sync_at:r(e.last_sync_at)??null}}function Ja(e){if(!m(e))return null;const t=r(e.operation_id),n=r(e.objective),s=r(e.assigned_unit_id),a=r(e.trace_id),i=r(e.status);return!t||!n||!s||!a||!i?null:{operation_id:t,objective:n,assigned_unit_id:s,autonomy_level:r(e.autonomy_level),policy_class:r(e.policy_class),budget_class:r(e.budget_class),detachment_session_id:r(e.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(e.checkpoint_ref)??null,active_goal_ids:w(e.active_goal_ids),note:r(e.note)??null,created_by:r(e.created_by),source:r(e.source),status:i,chain:c_(e.chain),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function d_(e){if(!m(e))return null;const t=Ja(e.operation);return t?{operation:t,assigned_unit_label:r(e.assigned_unit_label)}:null}function xn(e){if(m(e))return{tone:r(e.tone),pending_ops:d(e.pending_ops),blocked_ops:d(e.blocked_ops),in_flight_ops:d(e.in_flight_ops),pipeline_stalls:d(e.pipeline_stalls),bus_traffic:d(e.bus_traffic),l1_hit_rate:d(e.l1_hit_rate),invalidation_count:d(e.invalidation_count),current_pending:d(e.current_pending),current_in_flight:d(e.current_in_flight),cdb_wakeups:d(e.cdb_wakeups),total_stolen:d(e.total_stolen),avg_best_score:d(e.avg_best_score),avg_candidate_count:d(e.avg_candidate_count),best_first_operations:d(e.best_first_operations),active_sessions:d(e.active_sessions),commit_rate:d(e.commit_rate),total_speculations:d(e.total_speculations)}}function u_(e){if(!m(e))return;const t=m(e.pipeline)?e.pipeline:void 0,n=m(e.cache)?e.cache:void 0,s=m(e.ooo)?e.ooo:void 0,a=m(e.speculative)?e.speculative:void 0,i=m(e.search_fabric)?e.search_fabric:void 0,l=m(e.signals)?e.signals:void 0;return{pipeline:t?{total_ops:d(t.total_ops),completed_ops:d(t.completed_ops),stalled_cycles:d(t.stalled_cycles),hazards_detected:d(t.hazards_detected),forwarding_used:d(t.forwarding_used),pipeline_flushes:d(t.pipeline_flushes),ipc:d(t.ipc)}:void 0,cache:n?{total_reads:d(n.total_reads),total_writes:d(n.total_writes),l1_hit_rate:d(n.l1_hit_rate),invalidation_count:d(n.invalidation_count),writeback_count:d(n.writeback_count),bus_traffic:d(n.bus_traffic)}:void 0,ooo:s?{agent_count:d(s.agent_count),total_added:d(s.total_added),total_issued:d(s.total_issued),total_completed:d(s.total_completed),total_stolen:d(s.total_stolen),cdb_wakeups:d(s.cdb_wakeups),stall_cycles:d(s.stall_cycles),global_cdb_events:d(s.global_cdb_events),current_pending:d(s.current_pending),current_in_flight:d(s.current_in_flight)}:void 0,speculative:a?{total_speculations:d(a.total_speculations),total_commits:d(a.total_commits),total_aborts:d(a.total_aborts),commit_rate:d(a.commit_rate),total_fast_calls:d(a.total_fast_calls),total_cost_usd:d(a.total_cost_usd),active_sessions:d(a.active_sessions)}:void 0,search_fabric:i?{total_operations:d(i.total_operations),best_first_operations:d(i.best_first_operations),legacy_operations:d(i.legacy_operations),blocked_operations:d(i.blocked_operations),ready_operations:d(i.ready_operations),research_pipeline_operations:d(i.research_pipeline_operations),avg_candidate_count:d(i.avg_candidate_count),avg_best_score:d(i.avg_best_score),top_stage:r(i.top_stage)??null}:void 0,signals:l?{issue_pressure:xn(l.issue_pressure),cache_contention:xn(l.cache_contention),scheduler_efficiency:xn(l.scheduler_efficiency),routing_confidence:xn(l.routing_confidence),speculative_posture:xn(l.speculative_posture)}:void 0}}function gc(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),paused:d(n.paused),managed:d(n.managed),projected:d(n.projected)}:void 0,microarch:u_(t.microarch),operations:Array.isArray(t.operations)?t.operations.map(d_).filter(s=>s!==null):[]}}function $c(e){if(!m(e))return null;const t=r(e.detachment_id),n=r(e.operation_id),s=r(e.assigned_unit_id);return!t||!n||!s?null:{detachment_id:t,operation_id:n,assigned_unit_id:s,leader_id:r(e.leader_id)??null,roster:w(e.roster),session_id:r(e.session_id)??null,checkpoint_ref:r(e.checkpoint_ref)??null,runtime_kind:r(e.runtime_kind)??null,runtime_ref:r(e.runtime_ref)??null,source:r(e.source),status:r(e.status),last_event_at:r(e.last_event_at)??null,last_progress_at:r(e.last_progress_at)??null,heartbeat_deadline:r(e.heartbeat_deadline)??null,created_at:r(e.created_at),updated_at:r(e.updated_at)}}function p_(e){if(!m(e))return null;const t=$c(e.detachment);return t?{detachment:t,assigned_unit_label:r(e.assigned_unit_label),operation:Ja(e.operation)}:null}function hc(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),projected:d(n.projected)}:void 0,detachments:Array.isArray(t.detachments)?t.detachments.map(p_).filter(s=>s!==null):[]}}function m_(e){if(!m(e))return null;const t=r(e.decision_id),n=r(e.trace_id),s=r(e.requested_action),a=r(e.scope_type),i=r(e.scope_id);return!t||!n||!s||!a||!i?null:{decision_id:t,trace_id:n,requested_action:s,scope_type:a,scope_id:i,operation_id:r(e.operation_id)??null,target_unit_id:r(e.target_unit_id)??null,requested_by:r(e.requested_by),status:r(e.status),reason:r(e.reason)??null,source:r(e.source),detail:e.detail,created_at:r(e.created_at),decided_at:r(e.decided_at)??null,expires_at:r(e.expires_at)??null}}function yc(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),pending:d(n.pending),approved:d(n.approved),denied:d(n.denied)}:void 0,decisions:Array.isArray(t.decisions)?t.decisions.map(m_).filter(s=>s!==null):[]}}function __(e){if(!m(e))return null;const t=Ei(e.unit);return t?{unit:t,roster_total:d(e.roster_total),roster_live:d(e.roster_live),headcount_cap:d(e.headcount_cap),active_operations:d(e.active_operations),active_operation_cap:d(e.active_operation_cap),utilization:d(e.utilization)}:null}function v_(e){const t=m(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),capacity:Array.isArray(t.capacity)?t.capacity.map(__).filter(n=>n!==null):[]}}function f_(e){if(!m(e))return null;const t=r(e.alert_id);return t?{alert_id:t,severity:r(e.severity),kind:r(e.kind),scope_type:r(e.scope_type),scope_id:r(e.scope_id),title:r(e.title),detail:r(e.detail),timestamp:r(e.timestamp)}:null}function bc(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),bad:d(n.bad),warn:d(n.warn)}:void 0,alerts:Array.isArray(t.alerts)?t.alerts.map(f_).filter(s=>s!==null):[]}}function kc(e){if(!m(e))return null;const t=r(e.event_id),n=r(e.trace_id),s=r(e.event_type);return!t||!n||!s?null:{event_id:t,trace_id:n,event_type:s,operation_id:r(e.operation_id)??null,unit_id:r(e.unit_id)??null,actor:r(e.actor)??null,source:r(e.source),timestamp:r(e.timestamp),detail:e.detail}}function g_(e){const t=m(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),events:Array.isArray(t.events)?t.events.map(kc).filter(n=>n!==null):[]}}function $_(e){if(!m(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s}}function h_(e){if(!m(e))return null;const t=r(e.lane_id),n=r(e.label),s=r(e.kind),a=r(e.phase),i=r(e.motion_state),l=r(e.source_of_truth),c=r(e.movement_reason),u=r(e.current_step);if(!t||!n||!s||!a||!i||!l||!c||!u)return null;const p=m(e.counts)?e.counts:{};return{lane_id:t,label:n,kind:s,present:j(e.present)??!1,phase:a,motion_state:i,source_of_truth:l,last_movement_at:r(e.last_movement_at)??null,movement_reason:c,current_step:u,blockers:w(e.blockers),counts:{operations:d(p.operations),detachments:d(p.detachments),workers:d(p.workers),approvals:d(p.approvals),alerts:d(p.alerts)},hard_flags:Array.isArray(e.hard_flags)?e.hard_flags.map($_).filter(g=>g!==null):[]}}function y_(e){if(!m(e))return null;const t=r(e.event_id),n=r(e.lane_id),s=r(e.kind),a=r(e.timestamp),i=r(e.title),l=r(e.detail),c=r(e.tone),u=r(e.source);return!t||!n||!s||!a||!i||!l||!c||!u?null:{event_id:t,lane_id:n,kind:s,timestamp:a,title:i,detail:l,tone:c,source:u}}function b_(e){if(!m(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s,why_it_matters:r(e.why_it_matters)??void 0,next_tool:r(e.next_tool)??void 0,next_step:r(e.next_step)??void 0,lane_ids:w(e.lane_ids),count:d(e.count)??0}}function Ni(e){if(!m(e))return;const t=m(e.overview)?e.overview:{},n=m(e.gaps)?e.gaps:{},s=m(e.narrative)?e.narrative:{},a=m(e.recommended_next_action)?e.recommended_next_action:void 0;return{generated_at:r(e.generated_at),narrative:{state:r(s.state)??void 0,started:r(s.started)??void 0,active_work:r(s.active_work)??void 0,completion:r(s.completion)??void 0,lane_id:r(s.lane_id)??null},overview:{active_lanes:d(t.active_lanes),moving_lanes:d(t.moving_lanes),stalled_lanes:d(t.stalled_lanes),projected_lanes:d(t.projected_lanes),last_movement_at:r(t.last_movement_at)??null},lanes:Array.isArray(e.lanes)?e.lanes.map(h_).filter(i=>i!==null):[],timeline:Array.isArray(e.timeline)?e.timeline.map(y_).filter(i=>i!==null):[],gaps:{count:d(n.count),items:Array.isArray(n.items)?n.items.map(b_).filter(i=>i!==null):[]},recommended_next_action:a?{tool:r(a.tool)??"masc_operator_snapshot",label:r(a.label)??"Observe operator state",reason:r(a.reason)??"",lane_id:r(a.lane_id)??null}:void 0}}function xc(e){if(!m(e))return;const t=m(e.workers)?e.workers:{},n=j(e.pass);return{status:r(e.status)??"missing",source:r(e.source)??"none",reason_code:r(e.reason_code)??null,status_summary:r(e.status_summary)??null,run_id:r(e.run_id)??null,captured_at:r(e.captured_at)??null,...n!==void 0?{pass:n}:{},...d(e.peak_hot_slots)!=null?{peak_hot_slots:d(e.peak_hot_slots)}:{},...d(e.ctx_per_slot)!=null?{ctx_per_slot:d(e.ctx_per_slot)}:{},workers:{expected:d(t.expected),joined:d(t.joined),current_task_bound:d(t.current_task_bound),fresh_heartbeats:d(t.fresh_heartbeats),done:d(t.done),final:d(t.final)},expected_artifact_dir:r(e.expected_artifact_dir)??null,artifact_ref:r(e.artifact_ref)??null,missing_reason:r(e.missing_reason)??null}}function k_(e){const t=m(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),topology:fc(t.topology),operations:gc(t.operations),detachments:hc(t.detachments),alerts:bc(t.alerts),decisions:yc(t.decisions),capacity:v_(t.capacity),traces:g_(t.traces),swarm_status:Ni(t.swarm_status)}}function x_(e){const t=m(e)?e:{},n=fc(t.topology),s=gc(t.operations),a=hc(t.detachments),i=bc(t.alerts),l=yc(t.decisions);return{version:r(t.version),generated_at:r(t.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:i.version,generated_at:i.generated_at,summary:i.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:Ni(t.swarm_status),swarm_proof:xc(t.swarm_proof)}}function S_(e){return m(e)?{chain_id:r(e.chain_id)??null,started_at:d(e.started_at)??null,progress:d(e.progress)??null,elapsed_sec:d(e.elapsed_sec)??null}:null}function Sc(e){if(!m(e))return null;const t=r(e.event);return t?{event:t,chain_id:r(e.chain_id)??null,timestamp:r(e.timestamp)??null,duration_ms:d(e.duration_ms)??null,message:r(e.message)??null,tokens:d(e.tokens)??null}:null}function C_(e){if(!m(e))return null;const t=Ja(e.operation);return t?{operation:t,runtime:S_(e.runtime),history:Sc(e.history),mermaid:r(e.mermaid)??null,preview_run:Cc(e.preview_run)}:null}function A_(e){const t=m(e)?e:{};return{status:r(t.status)??"disconnected",base_url:r(t.base_url)??null,message:r(t.message)??null}}function T_(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),connection:A_(t.connection),summary:n?{linked_operations:d(n.linked_operations),active_chains:d(n.active_chains),running_operations:d(n.running_operations),recent_failures:d(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(t.operations)?t.operations.map(C_).filter(s=>s!==null):[],recent_history:Array.isArray(t.recent_history)?t.recent_history.map(Sc).filter(s=>s!==null):[]}}function I_(e){if(!m(e))return null;const t=r(e.id);return t?{id:t,type:r(e.type),status:r(e.status),duration_ms:d(e.duration_ms)??null,error:r(e.error)??null}:null}function Cc(e){if(!m(e))return null;const t=r(e.run_id),n=r(e.chain_id);return n?{run_id:t??null,chain_id:n,duration_ms:d(e.duration_ms),success:j(e.success),mermaid:r(e.mermaid),nodes:Array.isArray(e.nodes)?e.nodes.map(I_).filter(s=>s!==null):[]}:null}function z_(e){const t=m(e)?e:{};return{run:Cc(t.run)}}function R_(e){if(!m(e))return null;const t=r(e.title),n=r(e.path);return!t||!n?null:{title:t,path:n}}function L_(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary);return!t||!n||!s?null:{id:t,title:n,summary:s}}function P_(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.tool),a=r(e.summary);return!t||!n||!s||!a?null:{id:t,title:n,tool:s,summary:a,success_signals:w(e.success_signals),pitfalls:w(e.pitfalls)}}function M_(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary),a=r(e.when_to_use);return!t||!n||!s||!a?null:{id:t,title:n,summary:s,when_to_use:a,steps:Array.isArray(e.steps)?e.steps.map(P_).filter(i=>i!==null):[]}}function j_(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.description);return!t||!n||!s?null:{id:t,title:n,description:s,tools:w(e.tools)}}function E_(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.symptom),a=r(e.why),i=r(e.fix_tool),l=r(e.fix_summary);return!t||!n||!s||!a||!i||!l?null:{id:t,title:n,symptom:s,why:a,fix_tool:i,fix_summary:l}}function N_(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.path_id),a=r(e.transport);return!t||!n||!s||!a?null:{id:t,title:n,path_id:s,transport:a,request:e.request,response:e.response,notes:w(e.notes)}}function D_(e){const t=m(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),docs:Array.isArray(t.docs)?t.docs.map(R_).filter(n=>n!==null):[],concepts:Array.isArray(t.concepts)?t.concepts.map(L_).filter(n=>n!==null):[],golden_paths:Array.isArray(t.golden_paths)?t.golden_paths.map(M_).filter(n=>n!==null):[],tool_groups:Array.isArray(t.tool_groups)?t.tool_groups.map(j_).filter(n=>n!==null):[],pitfalls:Array.isArray(t.pitfalls)?t.pitfalls.map(E_).filter(n=>n!==null):[],examples:Array.isArray(t.examples)?t.examples.map(N_).filter(n=>n!==null):[]}}function O_(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.status),a=r(e.detail),i=r(e.next_tool);return!t||!n||!s||!a||!i?null:{id:t,title:n,status:s,detail:a,next_tool:i}}function q_(e){if(!m(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.title),a=r(e.detail),i=r(e.next_tool);return!t||!n||!s||!a||!i?null:{code:t,severity:n,title:s,detail:a,next_tool:i}}function w_(e){if(!m(e))return null;const t=r(e.from),n=r(e.content),s=r(e.timestamp),a=d(e.seq);return!t||!n||!s||a==null?null:{seq:a,from:t,content:n,timestamp:s}}function F_(e){if(!m(e))return null;const t=r(e.name),n=r(e.role),s=r(e.lane),a=r(e.status),i=r(e.claim_marker),l=r(e.done_marker),c=r(e.final_marker);if(!t||!n||!s||!a||!i||!l||!c)return null;const u=(()=>{if(!m(e.last_message))return null;const p=d(e.last_message.seq),g=r(e.last_message.content),f=r(e.last_message.timestamp);return p==null||!g||!f?null:{seq:p,content:g,timestamp:f}})();return{name:t,role:n,lane:s,joined:j(e.joined)??!1,live_presence:j(e.live_presence)??!1,completed:j(e.completed)??!1,status:a,current_task:r(e.current_task)??null,bound_task_id:r(e.bound_task_id)??null,bound_task_title:r(e.bound_task_title)??null,bound_task_status:r(e.bound_task_status)??null,current_task_matches_run:j(e.current_task_matches_run)??!1,squad_member:j(e.squad_member)??!1,detachment_member:j(e.detachment_member)??!1,last_seen:r(e.last_seen)??null,heartbeat_age_sec:d(e.heartbeat_age_sec)??null,heartbeat_fresh:j(e.heartbeat_fresh)??!1,claim_marker_seen:j(e.claim_marker_seen)??!1,done_marker_seen:j(e.done_marker_seen)??!1,final_marker_seen:j(e.final_marker_seen)??!1,claim_marker:i,done_marker:l,final_marker:c,last_message:u}}function K_(e){if(!m(e))return;const t=Array.isArray(e.timeline)?e.timeline.map(n=>{if(!m(n))return null;const s=r(n.timestamp),a=d(n.active_slots);if(!s||a==null)return null;const i=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:i}}).filter(n=>n!==null):[];return{slot_url:r(e.slot_url)??null,provider_base_url:r(e.provider_base_url)??null,provider_reachable:j(e.provider_reachable)??null,provider_status_code:d(e.provider_status_code)??null,provider_model_id:r(e.provider_model_id)??null,actual_model_id:r(e.actual_model_id)??null,expected_slots:d(e.expected_slots),actual_slots:d(e.actual_slots),expected_ctx:d(e.expected_ctx),actual_ctx:d(e.actual_ctx),configured_capacity:d(e.configured_capacity),slot_reachable:j(e.slot_reachable)??null,slot_status_code:d(e.slot_status_code)??null,runtime_blocker:r(e.runtime_blocker)??null,detail:r(e.detail)??null,checked_at:r(e.checked_at)??null,total_slots:d(e.total_slots),ctx_per_slot:d(e.ctx_per_slot),active_slots_now:d(e.active_slots_now),peak_active_slots:d(e.peak_active_slots),sample_count:d(e.sample_count),last_sample_at:r(e.last_sample_at)??null,timeline:t}}function H_(e){if(!m(e))return null;const t=r(e.run_id),n=r(e.status),s=r(e.decided_by),a=r(e.decided_at),i=r(e.reason);if(!t||!n||!s||!a||!i)return null;const l=[];return Array.isArray(e.history)&&e.history.forEach(c=>{if(!m(c))return;const u=r(c.status),p=r(c.decided_by),g=r(c.decided_at),f=r(c.reason);!u||!p||!g||!f||l.push({status:u,decided_by:p,decided_at:g,reason:f,operation_id:r(c.operation_id)??null,detachment_id:r(c.detachment_id)??null,note:r(c.note)??null})}),{run_id:t,status:n,decided_by:s,decided_at:a,reason:i,operation_id:r(e.operation_id)??null,detachment_id:r(e.detachment_id)??null,note:r(e.note)??null,history:l}}function U_(e){if(!m(e))return null;const t=r(e.run_id),n=r(e.recommended_kind),s=r(e.reason);return!t||!n||!s?null:{run_id:t,recommended_kind:n,continue_available:j(e.continue_available)??!1,rerun_available:j(e.rerun_available)??!1,abandon_available:j(e.abandon_available)??!1,reason:s,evidence:m(e.evidence)?{operation_id:r(e.evidence.operation_id)??null,detachment_id:r(e.evidence.detachment_id)??null,joined_workers:d(e.evidence.joined_workers),current_task_bound:d(e.evidence.current_task_bound),fresh_heartbeats:d(e.evidence.fresh_heartbeats),trace_events:d(e.evidence.trace_events),message_events:d(e.evidence.message_events),runtime_blocker:r(e.evidence.runtime_blocker)??null}:void 0,provenance:r(e.provenance),decision_engine:r(e.decision_engine),authoritative:j(e.authoritative)}}function B_(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),run_id:r(t.run_id),room_id:r(t.room_id),operation_id:r(t.operation_id)??null,run_resolution:H_(t.run_resolution),resolution_recommendation:U_(t.resolution_recommendation),recommended_next_tool:r(t.recommended_next_tool),summary:n?{expected_workers:d(n.expected_workers),joined_workers:d(n.joined_workers),live_workers:d(n.live_workers),squad_roster_size:d(n.squad_roster_size),detachment_roster_size:d(n.detachment_roster_size),current_task_bound:d(n.current_task_bound),fresh_heartbeats:d(n.fresh_heartbeats),claim_markers_seen:d(n.claim_markers_seen),done_markers_seen:d(n.done_markers_seen),final_markers_seen:d(n.final_markers_seen),completed_workers:d(n.completed_workers),peak_hot_slots:d(n.peak_hot_slots),hot_window_ok:j(n.hot_window_ok),pass_hot_concurrency:j(n.pass_hot_concurrency),pass_end_to_end:j(n.pass_end_to_end),pending_decisions:d(n.pending_decisions),pass:j(n.pass)}:void 0,provider:K_(t.provider),operation:Ja(t.operation),squad:Ei(t.squad),detachment:$c(t.detachment),workers:Array.isArray(t.workers)?t.workers.map(F_).filter(s=>s!==null):[],checklist:Array.isArray(t.checklist)?t.checklist.map(O_).filter(s=>s!==null):[],blockers:Array.isArray(t.blockers)?t.blockers.map(q_).filter(s=>s!==null):[],recent_messages:Array.isArray(t.recent_messages)?t.recent_messages.map(w_).filter(s=>s!==null):[],recent_trace_events:Array.isArray(t.recent_trace_events)?t.recent_trace_events.map(kc).filter(s=>s!==null):[],truth_notes:w(t.truth_notes)}}function W_(e){if(!m(e))return null;const t=r(e.label),n=r(e.value);return!t||!n?null:{label:t,value:n}}function G_(e){if(!m(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.label),a=r(e.tone),i=r(e.provenance);return!t||!n||!s||!a||!i?null:{id:t,kind:n,label:s,subtitle:r(e.subtitle)??null,status:r(e.status)??null,tone:a,pulse:r(e.pulse)??null,provenance:i,visual_class:r(e.visual_class)??void 0,glyph:r(e.glyph)??void 0,parent_id:r(e.parent_id)??null,lane_id:r(e.lane_id)??null,link_tab:r(e.link_tab)??null,link_surface:r(e.link_surface)??null,link_params:m(e.link_params)?Object.fromEntries(Object.entries(e.link_params).map(([l,c])=>{const u=r(c);return u?[l,u]:null}).filter(l=>l!==null)):{},facts:Array.isArray(e.facts)?e.facts.map(W_).filter(l=>l!==null):[]}}function J_(e){if(!m(e))return null;const t=r(e.id),n=r(e.source),s=r(e.target),a=r(e.kind),i=r(e.tone),l=r(e.provenance);return!t||!n||!s||!a||!i||!l?null:{id:t,source:n,target:s,kind:a,label:r(e.label)??null,tone:i,provenance:l,animated:j(e.animated)}}function V_(e){if(!m(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.label),a=r(e.tone),i=r(e.provenance);return!t||!n||!s||!a||!i?null:{id:t,kind:n,label:s,detail:r(e.detail)??null,tone:a,provenance:i,source_id:r(e.source_id)??null,target_id:r(e.target_id)??null,suggested_surface:r(e.suggested_surface)??null,suggested_params:m(e.suggested_params)?Object.fromEntries(Object.entries(e.suggested_params).map(([l,c])=>{const u=r(c);return u?[l,u]:null}).filter(l=>l!==null)):{}}}function Y_(e){if(!m(e))return null;const t=r(e.target_kind),n=r(e.target_id),s=r(e.label),a=r(e.reason);return!t||!n||!s||!a?null:{target_kind:t,target_id:n,label:s,reason:a,suggested_surface:r(e.suggested_surface)??null,suggested_params:m(e.suggested_params)?Object.fromEntries(Object.entries(e.suggested_params).map(([i,l])=>{const c=r(l);return c?[i,c]:null}).filter(i=>i!==null)):{}}}function Q_(e){const t=m(e)?e:{},n=m(t.room)?t.room:{},s=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),room:{room_id:r(n.room_id),project:r(n.project),cluster:r(n.cluster),paused:j(n.paused),pause_reason:r(n.pause_reason)??null,agent_count:d(n.agent_count),task_count:d(n.task_count),message_count:d(n.message_count)},summary:s?{session_count:d(s.session_count),operation_count:d(s.operation_count),detachment_count:d(s.detachment_count),lane_count:d(s.lane_count),worker_count:d(s.worker_count),keeper_count:d(s.keeper_count),signal_count:d(s.signal_count),alert_count:d(s.alert_count)}:void 0,nodes:Array.isArray(t.nodes)?t.nodes.map(G_).filter(a=>a!==null):[],edges:Array.isArray(t.edges)?t.edges.map(J_).filter(a=>a!==null):[],signals:Array.isArray(t.signals)?t.signals.map(V_).filter(a=>a!==null):[],focus:Y_(t.focus),swarm_status:Ni(t.swarm_status),swarm_proof:xc(t.swarm_proof),truth_notes:w(t.truth_notes)}}function lt(e){Y.value=e,ji(e)&&X_()}async function Ac(){ua.value=!0,ma.value=null;try{const e=await xu();Pi.value=x_(e)}catch(e){ma.value=e instanceof Error?e.message:"Failed to load command-plane summary"}finally{ua.value=!1}}function Di(e){sn.value=e}async function Oi(){pa.value=!0,_a.value=null;try{const e=await ku();Ue.value=k_(e)}catch(e){_a.value=e instanceof Error?e.message:"Failed to load command-plane snapshot"}finally{pa.value=!1}}async function X_(){Ue.value||pa.value||await Oi()}async function Wt(){await Ac(),ji(Y.value)&&await Oi()}async function an(){var e;ai.value=!0,ya.value=null;try{const t=await Su(),n=T_(t);ds.value=n;const s=sn.value;n.operations.length===0?sn.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(sn.value=((e=n.operations[0])==null?void 0:e.operation.operation_id)??null)}catch(t){ya.value=t instanceof Error?t.message:"Failed to load chain summary"}finally{ai.value=!1}}function Z_(){Tn=null,Bn.value=null,ba.value=!1,Wn.value=null}async function ev(e){Tn=e,ba.value=!0,Wn.value=null;try{const t=await Cu(e);if(Tn!==e)return;Bn.value=z_(t)}catch(t){if(Tn!==e)return;Bn.value=null,Wn.value=t instanceof Error?t.message:"Failed to load chain run"}finally{Tn===e&&(ba.value=!1)}}async function tv(){ni.value=!0,fa.value=null;try{const e=await Au();cs.value=D_(e)}catch(e){fa.value=e instanceof Error?e.message:"Failed to load command-plane help"}finally{ni.value=!1}}async function nt(e=mc(),t=_c()){ga.value=!0,$a.value=null;try{const n=await Tu(e,t);Dt.value=B_(n)}catch(n){$a.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{ga.value=!1}}async function Rt(e=mc(),t=_c()){si.value=!0,ha.value=null;try{const n=await Iu(e,t);Mi.value=Q_(n)}catch(n){ha.value=n instanceof Error?n.message:"Failed to load orchestra map"}finally{si.value=!1}}async function ft(e,t,n){ti.value=e,va.value=null;try{await zu(t,n),await Ac(),(Ue.value||ji(Y.value))&&await Oi(),await nt(),await Rt(),await an()}catch(s){throw va.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{ti.value=null}}function nv(e){return ft(`pause:${e}`,"/api/v1/command-plane/operations/pause",{operation_id:e})}function sv(e){return ft(`resume:${e}`,"/api/v1/command-plane/operations/resume",{operation_id:e})}function av(e){return ft(`recall:${e}`,"/api/v1/command-plane/dispatch/recall",{operation_id:e})}function ov(e={}){return ft("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...e.operationId?{operation_id:e.operationId}:{},...e.detachmentId?{detachment_id:e.detachmentId}:{}})}function iv(e){return ft(`approve:${e}`,"/api/v1/command-plane/policy/approve",{decision_id:e})}function rv(e){return ft(`deny:${e}`,"/api/v1/command-plane/policy/deny",{decision_id:e})}function lv(e,t){return ft(`freeze:${e}`,"/api/v1/command-plane/policy/freeze",{unit_id:e,enabled:t})}function cv(e,t){return ft(`kill:${e}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:e,enabled:t})}Cm(()=>{Wt(),an(),(Y.value==="swarm"||Y.value==="warroom"||Y.value==="orchestra"||Dt.value!==null)&&nt(),(Y.value==="orchestra"||Mi.value!==null)&&Rt(),Y.value==="warroom"&&ge()});function oi(e){e==="command"&&(It(),Wt(),an(),(Y.value==="swarm"||Y.value==="warroom"||Y.value==="orchestra")&&nt(),Y.value==="orchestra"&&Rt(),Y.value==="warroom"&&ge()),e==="mission"&&(It(),cc(),da()),e==="proof"&&uc(O.value.params.session_id,O.value.params.operation_id),e==="execution"&&(It(),Tt()),e==="intervene"&&(It(),ge(),jt()),e==="memory"&&it(),e==="planning"&&zi(),e==="lab"&&rt()}function dv({metric:e}){return o`
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
  `}function uv({panel:e}){return o`
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
            ${e.metrics.map(t=>o`<${dv} key=${t.id} metric=${t} />`)}
          </div>`:null}
    </div>
  `}function q({panelId:e,compact:t=!1,label:n="왜 필요한가"}){const s=pm(e);return s?o`
    <details class="semantic-inline ${t?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${uv} panel=${s} />
    </details>
  `:aa.value?o`<span class="semantic-inline-state">의미 계층 불러오는 중…</span>`:null}function Se({surfaceId:e,compact:t=!1}){const n=um(e);return n?o`
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
  `:aa.value?o`<div class="semantic-surface-card ${t?"compact":""}">의미 계층 불러오는 중…</div>`:oa.value?o`<div class="semantic-surface-card ${t?"compact":""}">${oa.value}</div>`:null}function T({title:e,class:t,semanticId:n,testId:s,children:a}){return o`
    <div class="card ${t??""}" data-testid=${s}>
      ${e?o`
            <div class="card-title-row">
              <div class="card-title">${e}</div>
              ${n?o`<${q} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}function ao(e){const t=(e??"").trim().toLowerCase();return t==="bad"||t==="critical"||t==="offline"?"bad":t==="warn"||t==="paused"||t==="blocked"?"warn":"ok"}function pv(){var n;const e=(n=Ri.value)==null?void 0:n.focus;if(!(e!=null&&e.suggested_tab))return;const t=e.suggested_params??{};if(e.suggested_tab==="intervene"){ie("intervene",t);return}ie("command",{...e.suggested_surface?{surface:e.suggested_surface}:{},...t})}function Va(){var u,p,g,f,v,h;const e=Ri.value;if(!e)return Qo.value?o`<section class="room-truth-strip room-truth-strip-loading">room truth 불러오는 중...</section>`:ia.value?o`<section class="room-truth-strip room-truth-strip-error">${ia.value}</section>`:null;const t=e.room.status,n=e.room.counts,s=(u=e.execution)==null?void 0:u.summary,a=(p=e.execution)==null?void 0:p.top_queue,i=e.command,l=e.operator,c=e.focus;return o`
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
          <span class="command-chip ${ao(((s==null?void 0:s.blocked_sessions)??0)>0?"warn":"ok")}">priority ${(s==null?void 0:s.priority_items)??0}</span>
          <span class="command-chip">${((g=e.execution)==null?void 0:g.provenance)??"derived"}</span>
        </div>
      </article>

      <article class="room-truth-card">
        <span class="room-truth-label">control</span>
        <strong>작전 ${(i==null?void 0:i.active_operations)??0} · 승인 ${(i==null?void 0:i.pending_approvals)??0}</strong>
        <p>alerts bad ${(i==null?void 0:i.bad_alerts)??0} / warn ${(i==null?void 0:i.warn_alerts)??0} · lanes ${(i==null?void 0:i.moving_lanes)??0}/${(i==null?void 0:i.active_lanes)??0}</p>
        <div class="room-truth-chip-row">
          <span class="command-chip ${ao(((i==null?void 0:i.bad_alerts)??0)>0?"bad":((i==null?void 0:i.warn_alerts)??0)>0||((i==null?void 0:i.pending_approvals)??0)>0?"warn":"ok")}">
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
          <span class="command-chip ${ao((c==null?void 0:c.provenance)==="fallback"?"warn":"ok")}">${(c==null?void 0:c.source)??"steady"}</span>
          <span class="command-chip">${(c==null?void 0:c.provenance)??((h=l==null?void 0:l.recommendation_summary)==null?void 0:h.provenance)??"derived"}</span>
        </div>
        ${c!=null&&c.suggested_tab?o`
              <div class="room-truth-actions">
                <button class="control-btn ghost" onClick=${pv}>
                  ${c.suggested_tab==="intervene"?"개입면 열기":"지휘면 열기"}
                </button>
              </div>
            `:null}
      </article>
    </section>
  `}const ka="masc_dashboard_workflow_context",mv=900*1e3;function be(e){return typeof e=="string"&&e.trim()!==""?e.trim():null}function Ze(e){const t=be(e);return t||(typeof e=="number"&&Number.isFinite(e)?String(e):null)}function Tc(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function ii(e){return m(e)?e:null}function _v(e){if(!e)return null;try{return JSON.stringify(e)}catch{return null}}function vv(e){if(!e)return null;try{const t=JSON.parse(e);if(!m(t))return null;const n=be(t.id),s=be(t.source_surface),a=be(t.source_label),i=be(t.summary),l=be(t.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!i||!l?null:{id:n,source_surface:s,source_label:a,action_type:be(t.action_type),target_type:be(t.target_type),target_id:be(t.target_id),focus_kind:be(t.focus_kind),operation_id:be(t.operation_id),command_surface:be(t.command_surface),summary:i,payload_preview:be(t.payload_preview),suggested_payload:ii(t.suggested_payload),preview:t.preview??null,evidence:t.evidence??null,created_at:l}}catch{return null}}function qi(e){const t=Date.parse(e.created_at);return Number.isNaN(t)?!1:Date.now()-t<=mv}function fv(){const e=Tc(),t=vv((e==null?void 0:e.getItem(ka))??null);return t?qi(t)?t:(e==null||e.removeItem(ka),null):null}const Ic=$(fv());function zc(e){const t=e&&qi(e)?e:null;Ic.value=t;const n=Tc();if(!n)return;if(!t){n.removeItem(ka);return}const s=_v(t);s&&n.setItem(ka,s)}function gv(e){if(!e)return null;const t=ii(e.suggested_payload);if(t)return t;if(m(e.preview)){const n=ii(e.preview.payload);if(n)return n}return null}function $v(e){if(!e)return null;const t=Ze(e.message);if(t)return t;const n=Ze(e.task_title)??Ze(e.title),s=Ze(e.task_description)??Ze(e.description),a=Ze(e.reason),i=Ze(e.priority)??Ze(e.task_priority);return n&&s?`${n} · ${s}`:n&&i?`${n} · P${i}`:n||s||a||null}function wi(e,t,n,s,a,i,l,c){return[e,t,n??"action",s??"target",a??"room",i??"focus",l??"operation",c].join(":")}function $n(e,t,n="상황판 추천 액션"){const s=new Date().toISOString(),a=gv(e),i=(e==null?void 0:e.target_type)??(t==null?void 0:t.target_type)??null,l=(e==null?void 0:e.target_id)??(t==null?void 0:t.target_id)??null,c=(t==null?void 0:t.kind)??(e==null?void 0:e.action_type)??null,u=(e==null?void 0:e.reason)??(t==null?void 0:t.summary)??n;return{id:wi("mission",n,(e==null?void 0:e.action_type)??null,i,l,c,null,s),source_surface:"mission",source_label:n,action_type:(e==null?void 0:e.action_type)??null,target_type:i,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:u,payload_preview:$v(a),suggested_payload:a,preview:(e==null?void 0:e.preview)??null,evidence:(t==null?void 0:t.evidence)??null,created_at:s}}function hv({targetType:e,targetId:t,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:i=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:wi("execution",s,null,e,t,n,i,c),source_surface:"execution",source_label:s,action_type:null,target_type:e,target_id:t,focus_kind:n,operation_id:i,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function yv(e,t){return(t.source==="mission"||t.source==="execution")&&(t.action_type??null)===(e.action_type??null)&&(t.target_type??null)===(e.target_type??null)&&(t.target_id??null)===(e.target_id??null)&&(t.focus_kind??null)===(e.focus_kind??null)&&(t.operation_id??null)===(e.operation_id??null)}function us(e){const{params:t}=e;if(t.source!=="mission"&&t.source!=="execution")return null;const n=Ic.value;if(n&&qi(n)&&yv(n,t))return n;const s=new Date().toISOString(),a=t.source==="execution"?"execution":"mission";return{id:wi(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",t.action_type??null,t.target_type??null,t.target_id??null,t.focus_kind??null,t.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:t.action_type??null,target_type:t.target_type??null,target_id:t.target_id??null,focus_kind:t.focus_kind??t.action_type??null,operation_id:t.operation_id??null,command_surface:t.surface??null,summary:a==="execution"?t.focus_kind?`${t.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":t.focus_kind?`${t.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function Rc(e){return{source:e.source_surface,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function Lc(e){if(e.command_surface)return e.command_surface;const t=[e.focus_kind,e.summary,e.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"summary":t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")||t.includes("swarm")?"swarm":e.focus_kind==="operation"||e.target_type==="operation"?"operations":e.target_type==="room"?"orchestra":"swarm"}function Pc(e){return{source:e.source_surface,surface:Lc(e),...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function bv(e){return Rc(e)}function kv(e){return Pc(e)}function Fi(e){return e!=null&&e.target_type?e.target_id?`${e.target_type} · ${e.target_id}`:e.target_type:"대상 정보 없음"}function Ya(e){switch(e){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(e==null?void 0:e.trim())||"추천 액션"}}function xv(e){switch(e){case"warroom":return"워룸";case"summary":return"요약";case"orchestra":return"오케스트라";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(e==null?void 0:e.trim())||"지휘"}}const Ge=$(null),st=$(null);function je(e,t=120){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-1)}…`:n:null}function $e(e){return e==="bad"||e==="offline"||e==="critical"||e==="risk"?"bad":e==="warn"||e==="pending"||e==="degraded"||e==="interrupted"||e==="watch"?"warn":"ok"}function we(e){if(!e)return"방금";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function Sv(e){return typeof e!="number"||!Number.isFinite(e)||e<0?"확인 필요":e<60?`${Math.round(e)}초`:e<3600?`${Math.round(e/60)}분`:e<86400?`${Math.round(e/3600)}시간`:`${Math.round(e/86400)}일`}function Fe(e){switch((e??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"pending":return"대기 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":case"watch":return"주의";case"bad":case"critical":case"risk":return"위험";case"degraded":return"저하";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"loading":return"불러오는 중";case"error":return"오류";case"unavailable":return"사용 불가";case"stale":return"오래됨";case"refreshing":return"갱신 중";case"cached":return"캐시";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function xa(e){switch((e??"").trim().toLowerCase()){case"room":return"방";case"team_session":case"session":return"세션";case"operation":return"작전";case"keeper":return"키퍼";case"agent":return"에이전트";default:return(e==null?void 0:e.trim())||"대상"}}function xr(e){switch((e??"").trim().toLowerCase()){case"metadata_gap":return"메타데이터 부족";case"mixed":return"신호 혼재";case"":return null;default:return(e==null?void 0:e.trim())||null}}function Cv(e){return e!=null&&e.confirm_required?"확인 후 실행":"즉시 실행"}function Av(e){return Fi(e?$n(e,null,"상황판 추천 액션"):null)}function Qa(e,t=$n()){zc(t),ie(e,e==="intervene"?bv(t):kv(t))}function Mc(e){Qa("intervene",$n(null,e,"상황판 incident"))}function jc(e){Qa("command",$n(null,e,"상황판 incident"))}function Ki(e,t,n="상황판 추천 액션"){Qa("intervene",$n(e,t,n))}function Ec(e,t,n="상황판 추천 액션"){Qa("command",$n(e,t,n))}function ri(e,t){const n={source:"mission",target_type:"team_session",target_id:t,focus_kind:"team_session"};e==="command"&&(n.surface="swarm"),ie(e,n)}function Tv(e){return{kind:e.kind,severity:e.severity,summary:e.summary,target_type:e.target_type,target_id:e.target_id??null,actor:null,evidence:e.evidence_preview}}function Iv(e){var n,s;const t=vt.value.find(a=>a.name===e.name||a.agent_name===e.agent_name)??null;return{brief:e,keeper:t,currentWork:je(e.current_work,110)??je(t==null?void 0:t.skill_primary,110)??je(t==null?void 0:t.last_proactive_reason,110)??"명시된 키퍼 초점 없음",recentInput:je(t==null?void 0:t.recent_input_preview,120)??null,recentOutput:je(t==null?void 0:t.recent_output_preview,120)??je((n=t==null?void 0:t.diagnostic)==null?void 0:n.last_reply_preview,120)??je(t==null?void 0:t.last_proactive_preview,120)??null,recentEvent:je(t==null?void 0:t.last_proactive_reason,120)??je((s=t==null?void 0:t.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(t==null?void 0:t.recent_tool_names)??[]}}function zv(){const e=ls.value;if(!e)return new Map;const t=e.sessions.length>0?e.sessions:e.session_briefs;return new Map(t.map(n=>[n.session_id,n]))}function Rv(e){Ge.value=Ge.value===e?null:e,st.value=null}function Nc(e){st.value=st.value===e?null:e,Ge.value=null}function Lv(){Ge.value=null,st.value=null}function oo(e){return(e==null?void 0:e.trim().toLowerCase())??""}function ps(e){var t,n;return e?((t=e.agent)==null?void 0:t.exists)===!1||oo((n=e.diagnostic)==null?void 0:n.health_state)==="offline"||oo(e.status)==="offline"||oo(e.status)==="inactive"?"offline":"online":"unlinked"}function Je(e){switch(e){case"offline":return"offline";case"none_recent":return"none_recent";case"not_applicable":return"not_applicable";case"unlinked":return"unlinked";default:return"not_collected"}}function Dc(e){const t=ps(e);return t==="unlinked"?"unlinked":t==="offline"?"offline":"not_collected"}function Oc(e,t){const n=ps(e);return n==="unlinked"?"unlinked":n==="offline"?"offline":t!=null&&t.trim()?"none_recent":"not_collected"}function qc(e,t){const n=ps(e);return n==="unlinked"?"unlinked":n==="offline"?"offline":t!=null&&t.trim()?"none_recent":"not_collected"}function Hi(e){const t=ps(e);return t==="unlinked"?"unlinked":t==="offline"?"offline":"none_recent"}function wc(e){const t=e==null?void 0:e.trim();ie("tools",t?{q:t}:void 0)}function Pv(e){switch(e.trim().toLowerCase()){case"active":case"running":return"가동 중";case"working":return"작업 중";case"watching":return"관찰 중";case"quiet":return"조용함";case"idle":return"유휴";case"ok":case"healthy":return"정상";case"warn":case"warning":case"degraded":return"주의";case"bad":case"critical":case"error":case"failed":return"위험";case"blocked":return"막힘";case"paused":return"일시정지";case"pending":return"대기";case"offline":case"inactive":return"오프라인";case"connected":return"연결됨";case"disconnected":return"끊김";case"ready":return"준비됨";case"done":case"completed":return"완료";case"unknown":return"알 수 없음";default:return e}}function gt({status:e,label:t}){return o`
    <span class="status-badge ${e}">
      <span class="status-dot-inline ${e}"></span>
      ${t??Pv(e)}
    </span>
  `}function Fc(e){const t=Date.now(),n=typeof e=="number"?e<1e12?e*1e3:e:new Date(e).getTime(),s=Math.floor((t-n)/1e3);if(s<60)return`${s}초 전`;const a=Math.floor(s/60);if(a<60)return`${a}분 전`;const i=Math.floor(a/60);return i<24?`${i}시간 전`:`${Math.floor(i/24)}일 전`}function W({timestamp:e}){const t=Fc(e),n=typeof e=="string"?e:new Date(e<1e12?e*1e3:e).toISOString();return o`<span class="time-ago" title=${n}>${t}</span>`}let Mv=0;const Lt=$([]);function E(e,t="success",n=4e3){const s=++Mv;Lt.value=[...Lt.value,{id:s,message:e,type:t}],setTimeout(()=>{Lt.value=Lt.value.filter(a=>a.id!==s)},n)}function jv(e){Lt.value=Lt.value.filter(t=>t.id!==e)}function Ev(){const e=Lt.value;return e.length===0?null:o`
    <div class="toast-container">
      ${e.map(t=>o`
        <div key=${t.id} class="toast ${t.type}" onClick=${()=>jv(t.id)}>
          ${t.message}
        </div>
      `)}
    </div>
  `}const Nv="masc_dashboard_agent_name",hn=$(null),Sa=$(!1),Gn=$(""),Ca=$([]),Jn=$([]),on=$(""),Mn=$(!1);function ms(e){hn.value=e,Ui()}function Sr(){hn.value=null,Gn.value="",Ca.value=[],Jn.value=[],on.value=""}function Dv(){const e=hn.value;return e?Xe.value.find(t=>t.name===e)??null:null}function Kc(e){return e?at.value.filter(t=>t.assignee===e):[]}function Hc(e){return e?vt.value.find(t=>t.agent_name===e||t.name===e)??null:null}function Ov(e){if(!e)return null;const t=ls.value;return t?t.agent_briefs.find(n=>n.agent_name===e)??null:null}function qv(e){if(!e)return[];const t=e.metrics_window;return(Array.isArray(t==null?void 0:t.top_tools)?t.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function wv(e){const t=Hc(e);return t?t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]:[]}function Cr(...e){for(const t of e)if(t&&t.length>0)return t;return[]}function Fv(e){return e?Ci.value.find(t=>t.agent_name===e||t.name===e)??null:null}function Kv(e){return e?Si.value.find(t=>t.agent_name===e||t.worker_name===e)??null:null}async function Ui(){const e=hn.value;if(e){Sa.value=!0,Gn.value="",Ca.value=[],Jn.value=[];try{const t=await cp(80);Ca.value=t.filter(a=>a.includes(e)).slice(0,20);const n=Kc(e).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await dp(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const l=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));Jn.value=s}catch(t){Gn.value=t instanceof Error?t.message:"Failed to load agent detail"}finally{Sa.value=!1}}}async function Ar(){var s;const e=hn.value,t=on.value.trim();if(!e||!t)return;const n=((s=localStorage.getItem(Nv))==null?void 0:s.trim())||"dashboard";Mn.value=!0;try{await lp(n,`@${e} ${t}`),on.value="",E(`Mention sent to ${e}`,"success"),Ui()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";E(i,"error")}finally{Mn.value=!1}}function Hv({task:e}){return o`
    <div class="agent-detail-task">
      <span class="pill">${e.id}</span>
      <span class="agent-detail-task-title">${e.title}</span>
      <${gt} status=${e.status} />
    </div>
  `}function Uv({row:e}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${e.taskId}</span>
      </div>
      <pre class="agent-history-pre">${e.text||"No task history yet"}</pre>
    </div>
  `}function Bv(){var G,Q,se,M,J,A,X;const e=hn.value;if(!e)return null;const t=Dv(),n=Hc(e),s=Fv(e),a=Kv(e),i=Ov(e),l=Kc(e),c=Ca.value,u=wv(e),p=qv(n),g=Cr(s==null?void 0:s.allowed_tool_names,i==null?void 0:i.allowed_tool_names,a==null?void 0:a.allowed_tool_names,n==null?void 0:n.allowed_tool_names),f=Cr(s==null?void 0:s.latest_tool_names,i==null?void 0:i.latest_tool_names,a==null?void 0:a.used_tool_names,n==null?void 0:n.latest_tool_names),v=(s==null?void 0:s.latest_tool_call_count)??(i==null?void 0:i.latest_tool_call_count)??(a==null?void 0:a.used_tool_call_count)??(n==null?void 0:n.latest_tool_call_count),h=(s==null?void 0:s.tool_audit_source)??(i==null?void 0:i.tool_audit_source)??(a==null?void 0:a.tool_audit_source)??(n==null?void 0:n.tool_audit_source),b=(s==null?void 0:s.tool_audit_at)??(i==null?void 0:i.tool_audit_at)??(a==null?void 0:a.tool_audit_at)??(n==null?void 0:n.tool_audit_at),C=(t==null?void 0:t.capabilities)??[],x=((G=re.value)==null?void 0:G.room)??"default",S=((Q=re.value)==null?void 0:Q.project)??"확인 없음",_=((se=re.value)==null?void 0:se.cluster)??"확인 없음",I=Je(Dc(n)),R=Je(Oc(n,h)),L=Je(qc(n,h)),V=Je(Hi(n)),z=g[0]??f[0]??u[0]??null;return o`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${K=>{K.target.classList.contains("agent-detail-overlay")&&Sr()}}
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
            ${(((M=t==null?void 0:t.traits)==null?void 0:M.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(J=t==null?void 0:t.traits)==null?void 0:J.map(K=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${K}</span>`)}
              </div>
            `:""}
            ${(((A=t==null?void 0:t.interests)==null?void 0:A.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(X=t==null?void 0:t.interests)==null?void 0:X.map(K=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${K}</span>`)}
              </div>
            `:""}
            ${C.length>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${C.map(K=>o`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${K}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${t?o`
                    ${t.current_task?o`<span>Task: ${t.current_task}</span>`:null}
                    ${t.last_seen?o`<span>Last seen: <${W} timestamp=${t.last_seen} /></span>`:null}
                    <span>Room: ${x}</span>
                    <span>Project: ${S}</span>
                    <span>Cluster: ${_}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Ui()}} disabled=${Sa.value}>
              ${Sa.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Sr}>Close</button>
          </div>
        </div>

        ${Gn.value?o`<div class="council-error">${Gn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${T} title="Assigned Tasks">
            ${l.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${l.map(K=>o`<${Hv} key=${K.id} task=${K} />`)}</div>`}
          <//>

          <${T} title="Recent Activity">
            ${c.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${c.map((K,te)=>o`<div key=${te} class="agent-activity-line">${K}</div>`)}</div>`}
          <//>
        </div>

        <${T} title="Capabilities & Tool Audit">
          <div style="display:flex; flex-direction:column; gap:12px;">
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Capabilities</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${C.length>0?C.map(K=>o`<span class="pill">${K}</span>`):o`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
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
                ${g.length>0?g.map(K=>o`<span class="pill">${K}</span>`):o`<span class="empty-state" style="font-size:12px;">${I}</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Observed tools</div>
              <div style="font-size:11px; color:#64748b; margin-bottom:6px;">Recent execution evidence, not policy allowlist.</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${f.length>0?f.map(K=>o`<span class="pill">${K}</span>`):o`<span class="empty-state" style="font-size:12px;">${R}</span>`}
              </div>
            </div>
            <div class="agent-detail-sub">
              <span>Tool calls: ${typeof v=="number"?v:R==="none_recent"?0:L}</span>
              <span>Evidence source: ${h??L}</span>
              <span>
                Observed at:
                ${b?o` <${W} timestamp=${b} />`:` ${L}`}
              </span>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Linked keeper recent tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${u.length>0?u.map(K=>o`<span class="pill">${K}</span>`):o`<span class="empty-state" style="font-size:12px;">${V}</span>`}
              </div>
            </div>
            ${p.length>0?o`
                  <div>
                    <div style="font-size:12px; color:#888; margin-bottom:6px;">Keeper window top tools</div>
                    <div style="display:flex; flex-wrap:wrap; gap:6px;">
                      ${p.map(K=>o`<span class="pill">${K}</span>`)}
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
              <${T} title="Latest Lodge Check-in">
                <div class="agent-detail-sub">
                  <span>Outcome: ${a.outcome}</span>
                  <span>Trigger: ${a.trigger??"unknown"}</span>
                  <span>Action: ${a.action_kind??"none"}</span>
                  ${a.checked_at?o`<span>Checked: <${W} timestamp=${a.checked_at} /></span>`:null}
                </div>
                ${a.reason?o`<div class="monitor-footnote">${a.reason}</div>`:null}
                ${a.summary&&a.summary!==a.reason?o`<div class="monitor-footnote">${a.summary}</div>`:null}
                ${a.failure_reason?o`<div class="monitor-footnote">Failure: ${a.failure_reason}</div>`:a.decision_reason?o`<div class="monitor-footnote">Decision: ${a.decision_reason}</div>`:null}
              <//>
            `:null}

        <${T} title="Task History">
          ${Jn.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Jn.value.map(K=>o`<${Uv} key=${K.taskId} row=${K} />`)}</div>`}
        <//>

        <${T} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${on.value}
              onInput=${K=>{on.value=K.target.value}}
              onKeyDown=${K=>{K.key==="Enter"&&Ar()}}
              disabled=${Mn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Ar()}}
              disabled=${Mn.value||on.value.trim()===""}
            >
              ${Mn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Wv(e){switch(e){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Gv(e){switch(e){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Jv(e){switch(e.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return e.role}}function Tr(e){return e.delivery==="error"||e.delivery==="timeout"?"bad":e.delivery==="sending"?"warn":e.role==="assistant"?"assistant":e.role==="user"?"user":"warn"}function Uc(e){if(!e)return null;const t=new Date(e);return Number.isNaN(t.getTime())?null:t.toLocaleTimeString()}function Vv(e){return typeof e!="number"||!Number.isFinite(e)||e<=0?null:e<60?`${Math.round(e)}s`:`${Math.ceil(e/60)}m`}function Bc(e){if(!e)return null;const t=Ye.value[e.name];return(t==null?void 0:t.diagnostic)??e.diagnostic??null}function Yv({keeper:e,showRawStatus:t=!1}){if(oe(()=>{e!=null&&e.name&&Ll(e.name)},[e==null?void 0:e.name]),!e)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Ye.value[e.name],s=Bc(e),a=Ko.value[e.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Wv(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Gv((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?o` · ${Uc(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?o` · next eligible ${Vv(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?o`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${t?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Qv({keeperName:e,placeholder:t}){const[n,s]=dl("");oe(()=>{e&&Ll(e)},[e]);const a=_e.value[e]??[],i=Ho.value[e]??!1,l=Qe.value[e],c=async()=>{const u=n.trim();if(!(!e||!u)){s("");try{await Rp(e,u)}catch(p){const g=p instanceof Error?p.message:`Failed to message ${e}`;E(g,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(u=>o`
              <div class="keeper-conversation-item" key=${u.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Tr(u)}`}>${u.label}</span>
                  <span class=${`keeper-role-chip ${Tr(u)}`}>${Jv(u)}</span>
                  ${u.timestamp?o`<span class="keeper-conversation-time">${Uc(u.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${u.text}</div>
                ${u.error?o`<div class="keeper-conversation-error">${u.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${t}
          value=${n}
          onInput=${u=>{s(u.target.value)}}
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
  `}function Xv({actor:e,keeper:t,onPokeLodge:n}){if(!t)return null;const s=Bc(t),a=Uo.value[t.name]??!1,i=Bo.value[t.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{Lp(t.name,e).catch(u=>{const p=u instanceof Error?u.message:`Failed to probe ${t.name}`;E(p,"error")})}}
        disabled=${a||!e.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{Pp(t.name,e).catch(u=>{const p=u instanceof Error?u.message:`Failed to recover ${t.name}`;E(p,"error")})}}
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
  `}const Bi=$(null);function Wc(e){Bi.value=e,zp(e.name)}function Ir(){Bi.value=null}const Ft=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Zv(e){if(!e)return 0;const t=Ft.findIndex(n=>n.level===e);return t>=0?t:0}function ef({keeper:e}){const t=Zv(e.autonomy_level),n=Ft[t]??Ft[0];if(!n)return null;const s=(t+1)/Ft.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${t+1} / ${Ft.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Ft.map((a,i)=>o`
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
            <strong><${W} timestamp=${e.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${e.active_goal_ids&&e.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${e.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Vs(e){return e?e>=1e6?`${(e/1e6).toFixed(1)}M`:e>=1e3?`${(e/1e3).toFixed(1)}K`:String(e):"—"}function tf(e){switch(e){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(e==null?void 0:e.trim())||"action"}}function nf(e){return e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]}function sf(e){const t=e.metrics_window;return(Array.isArray(t==null?void 0:t.top_tools)?t.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function af(e){const t=ls.value;return t?t.keeper_briefs.find(n=>n.name===e.name||n.agent_name&&e.agent_name&&n.agent_name===e.agent_name)??null:null}function of({keeper:e}){const t=e.metrics_series??[],n=t[t.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:e.generation??"-",hint:"Succession count"},{label:"Turns",value:e.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:e.context_ratio!=null?`${Math.round(e.context_ratio*100)}%`:"-",hint:e.context_ratio!=null&&e.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:e.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Vs(e.context_tokens)}</div>
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
  `}function rf({keeper:e}){var g,f;const t=e.metrics_series??[];if(t.length<2){const v=(((g=e.context)==null?void 0:g.context_ratio)??0)*100,h=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${h}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=t.length,l=t.map((v,h)=>{const b=a+h/(i-1)*(n-2*a),C=s-a-(v.context_ratio??0)*(s-2*a);return{x:b,y:C,p:v}}),c=l.map(({x:v,y:h})=>`${v.toFixed(1)},${h.toFixed(1)}`).join(" "),u=(((f=t[t.length-1])==null?void 0:f.context_ratio)??0)*100,p=u>85?"#ef4444":u>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:v})=>v.is_handoff).map(({x:v})=>o`
          <line x1="${v.toFixed(1)}" y1="${a}" x2="${v.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${p}" stroke-width="1.5"/>
        ${l.filter(({p:v})=>v.is_compaction).map(({x:v,y:h})=>o`
          <circle cx="${v.toFixed(1)}" cy="${h.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${u.toFixed(1)}%</span>
    </div>`}const io=$("");function lf({keeper:e}){var a,i,l,c;const t=io.value.toLowerCase(),n=[{title:"Name",key:"name",value:e.name},{title:"Emoji",key:"emoji",value:e.emoji??"-"},{title:"Korean",key:"koreanName",value:e.koreanName??"-"},{title:"Model",key:"model",value:e.model??"-"},{title:"Status",key:"status",value:e.status},{title:"Primary",key:"primaryValue",value:e.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(e.activityLevel??"-")},{title:"Gen",key:"generation",value:String(e.generation??"-")},{title:"Turns",key:"turn_count",value:String(e.turn_count??"-")},{title:"Context",key:"context_ratio",value:e.context_ratio!=null?`${Math.round(e.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:e.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=e.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=e.interests)==null?void 0:i.join(", "))||"-"}],s=t?n.filter(u=>u.title.toLowerCase().includes(t)||u.key.includes(t)||u.value.toLowerCase().includes(t)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${io.value}
        onInput=${u=>{io.value=u.target.value}}
      />
      ${s.map(u=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${u.title}</span>
          <span class="keeper-field-key">${u.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${u.value}</span>
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
      ${e.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Vs(e.context_tokens)}</span></div>`:""}
      ${e.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Vs(e.context_max)}</span></div>`:""}
      ${e.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${e.memory_recent_note}</span></div>`:""}
      ${e.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${e.k2k_count}</span></div>`:""}
      ${e.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${e.conversation_tail_count}</span></div>`:""}
      ${e.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${e.handoff_count_total}</span></div>`:""}
      ${e.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${e.compaction_count}</span></div>`:""}
      ${e.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Vs(e.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=e.context)==null?void 0:l.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${e.context.message_count}</span></div>`:""}
      ${((c=e.context)==null?void 0:c.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${e.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function cf({stats:e}){const t=e.max_hp>0?Math.round(e.hp/e.max_hp*100):0,n=e.max_mp>0?Math.round(e.mp/e.max_mp*100):0;return o`
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
  `}function df({items:e}){return e.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${e.map((t,n)=>o`
        <div class="keeper-equipment-row">
          <span>${t}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function uf({rels:e}){const t=Object.entries(e);return t.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${t.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function zr({traits:e,label:t}){return e.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${t}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${e.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function ro(e){return e==null||Number.isNaN(e)?"-":`${Math.round(e*100)}%`}function pf({keeper:e}){const t=e.metrics_window,n=[{label:"Model fallback",value:ro(typeof(t==null?void 0:t.model_fallback_rate)=="number"?t.model_fallback_rate:void 0)},{label:"Proactive fallback",value:ro(typeof(t==null?void 0:t.proactive_fallback_rate)=="number"?t.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:ro(typeof(t==null?void 0:t.memory_pass_rate)=="number"?t.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(t==null?void 0:t.handoff_count)=="number"?t.handoff_count:e.handoff_count_total??"-"},{label:"Compactions",value:typeof(t==null?void 0:t.compaction_events)=="number"?t.compaction_events:e.compaction_count??"-"},{label:"Saved tokens",value:typeof(t==null?void 0:t.compaction_saved_tokens)=="number"?t.compaction_saved_tokens:e.last_compaction_saved_tokens??"-"},{label:"K2K events",value:e.k2k_count??"-"},{label:"Conversation tail",value:e.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(t==null?void 0:t.tool_call_count)=="number"?t.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(t==null?void 0:t.proactive_preview_similarity_avg)=="number"?`${(t.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(t==null?void 0:t.memory_avg_score)=="number"?t.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(t==null?void 0:t.fallback_rate)=="number"?`${(t.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function mf({keeper:e}){var z,G,Q,se,M,J,A;const t=((z=he.value)==null?void 0:z.room)??{},n=(((G=he.value)==null?void 0:G.available_actions)??[]).filter(X=>X.target_type==="keeper"||X.target_type==="room").slice(0,8),s=nf(e),a=sf(e),i=af(e),l=i!=null&&i.allowed_tool_names&&i.allowed_tool_names.length>0?i.allowed_tool_names:e.allowed_tool_names??[],c=i!=null&&i.latest_tool_names&&i.latest_tool_names.length>0?i.latest_tool_names:e.latest_tool_names??[],u=(i==null?void 0:i.latest_tool_call_count)??e.latest_tool_call_count,p=(i==null?void 0:i.tool_audit_source)??e.tool_audit_source,g=(i==null?void 0:i.tool_audit_at)??e.tool_audit_at,f=((Q=e.agent)==null?void 0:Q.capabilities)??[],v=t.current_room??t.room_id??((se=re.value)==null?void 0:se.room)??"default",h=t.project??((M=re.value)==null?void 0:M.project)??"확인 없음",b=t.cluster??((J=re.value)==null?void 0:J.cluster)??"확인 없음",C=Je(Dc(e)),x=Je(Oc(e,p)),S=Je(qc(e,p)),_=Je(Hi(e)),I=ps(e),R=((A=e.agent)==null?void 0:A.current_task)??(I==="offline"?"offline":"not_collected"),L=e.skill_primary??(I==="offline"?"offline":"not_collected"),V=l[0]??c[0]??s[0]??null;return o`
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
        <strong>${b}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Current task</span>
        <strong>${R}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Skill route</span>
        <strong>${L}</strong>
      </div>
      <div style="display:flex; justify-content:flex-end; margin-top:4px;">
        <button class="control-btn ghost" onClick=${()=>{wc(V)}}>
          Open tools panel
        </button>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Allowed tools</span>
        <span style="font-size:11px; color:#64748b;">Currently permitted tools for this keeper runtime.</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${l.length>0?l.map(X=>o`<span class="pill">${X}</span>`):o`<span style="font-size:12px; color:#888;">${C}</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Observed tools</span>
        <span style="font-size:11px; color:#64748b;">Recent execution evidence from heartbeat or runtime telemetry.</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${c.length>0?c.map(X=>o`<span class="pill">${X}</span>`):o`<span style="font-size:12px; color:#888;">${x}</span>`}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Tool calls</span>
        <strong>${typeof u=="number"?u:x==="none_recent"?0:S}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Evidence source</span>
        <strong>${p??S}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Observed at</span>
        <strong>${g?o`<${W} timestamp=${g} />`:S}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Keeper recent tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${s.length>0?s.map(X=>o`<span class="pill">${X}</span>`):o`<span style="font-size:12px; color:#888;">${_}</span>`}
        </div>
      </div>
      ${a.length>0?o`
            <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
              <span style="font-size:12px; color:#888;">Window top tools</span>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${a.map(X=>o`<span class="pill">${X}</span>`)}
              </div>
            </div>
          `:null}
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${f.length>0?f.map(X=>o`<span class="pill">${X}</span>`):o`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(X=>o`<span class="pill">${tf(X.action_type)}</span>`):o`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function Gc(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(t??n??"dashboard").trim()||"dashboard"}async function _f(){try{const e=await Ba({actor:Gc(),action_type:"lodge_tick",target_type:"room",payload:{}}),t=Rl(e.result);await rs(),t!=null&&t.skipped_reason?E(t.skipped_reason,"warning"):E(t?`Poke finished: ${t.acted}/${t.checked} acted`:"Poke finished",t&&t.acted>0?"success":"warning")}catch(e){const t=e instanceof Error?e.message:"Failed to run Lodge poke";E(t,"error")}}function vf({keeper:e}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Yv} keeper=${e} />
          <${Xv}
            actor=${Gc()}
            keeper=${e}
            onPokeLodge=${()=>{_f()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Qv}
            keeperName=${e.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function ff(){var t,n,s;const e=Bi.value;return e?o`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Ir()}}
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
            onClick=${()=>Ir()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${of} keeper=${e} />

        ${""}
        <${rf} keeper=${e} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${T} title="Field Dictionary">
            <${lf} keeper=${e} />
          <//>

          ${""}
          <${T} title="Profile">
            <${zr} traits=${e.traits??[]} label="Traits" />
            <${zr} traits=${e.interests??[]} label="Interests" />
            ${e.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${e.primaryValue}</span></div>`:null}
            ${e.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${e.skill_primary}</span>
                </div>`:null}
            ${e.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${e.skill_reason}</div>`:null}
            ${e.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${W} timestamp=${e.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${e.autonomy_level?o`
              <${T} title="Autonomy">
                <${ef} keeper=${e} />
              <//>
            `:null}

          ${""}
          ${e.trpg_stats?o`
              <${T} title="TRPG Stats">
                <${cf} stats=${e.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${e.inventory&&e.inventory.length>0?o`
              <${T} title="Equipment (${e.inventory.length})">
                <${df} items=${e.inventory} />
              <//>
            `:null}

          ${""}
          ${e.relationships&&Object.keys(e.relationships).length>0?o`
              <${T} title="Relationships (${Object.keys(e.relationships).length})">
                <${uf} rels=${e.relationships} />
              <//>
            `:null}

          <${T} title="Runtime Signals">
            <${pf} keeper=${e} />
          <//>

          <${T} title="Neighborhood & Tool Audit">
            <${mf} keeper=${e} />
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
              ${e.memory_recent_note?o`
                  <div class="keeper-memory-note">
                    ${e.memory_recent_note}
                  </div>
                `:o`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${vf} keeper=${e} />
      </div>
    </div>
  `:null}function gf({cluster:e,project:t,room:n,generatedAt:s}){return o`
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
        <strong>${s?we(s):"기록 없음"}</strong>
      </div>
    </div>
  `}function qt({label:e,value:t,detail:n,tone:s}){return o`
    <article class="mission-stat-card ${$e(s)}">
      <span class="mission-stat-label">${e}</span>
      <strong class="mission-stat-value">${t}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function $f(){const e=sc.value,t=$e((e==null?void 0:e.status)??(Ct.value?"bad":"warn")),n=!e||e.sections.length===0,s=(e==null?void 0:e.status)==="error"||(e==null?void 0:e.status)==="unavailable"&&!(e!=null&&e.cached);return o`
    <${T} title="판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>휴리스틱 대신 별도 판단 결과</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${t}">
          ${Fe((e==null?void 0:e.status)??(Ct.value?"error":"loading"))}
        </span>
        ${e!=null&&e.model?o`<span class="command-chip">${e.model}</span>`:null}
        ${e!=null&&e.generated_at?o`<span class="command-chip">${we(e.generated_at)}</span>`:null}
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
                <article class="mission-briefing-section ${$e(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${$e(a.status)}">${Fe(a.status)}</span>
                      ${xr(a.signal_class)?o`<span class="command-chip ${a.signal_class==="mixed"?"warn":""}">${xr(a.signal_class)}</span>`:null}
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
          `:!Ut.value&&!Ct.value&&n?o`
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
                      <strong>${xa(a.scope_type)}${a.scope_id?` · ${a.scope_id}`:""}</strong>
                      <span class="command-chip ${a.severity==="watch"?"warn":""}">${Fe(a.severity)}</span>
                    </div>
                    <p>${a.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>{da(s)}} disabled=${Ut.value}>
          ${Ut.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{da(!0)}} disabled=${Ut.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function hf({item:e,selected:t,sessionLookup:n}){const s=Tv(e),a=e.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),i=e.top_action??null;return o`
    <article class="mission-attention-card ${$e((i==null?void 0:i.severity)??e.severity)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Rv(e.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${e.summary}</strong>
            <div class="mission-card-target">${xa(e.target_type)}${e.target_id?` · ${e.target_id}`:""}</div>
          </div>
          <span class="command-chip ${$e((i==null?void 0:i.severity)??e.severity)}">${i?Cv(i):e.severity}</span>
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
            <strong>${e.last_seen_at?we(e.last_seen_at):"기록 없음"}</strong>
            <small>${xa(e.target_type)}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${i?Ya(i.action_type):"판단 필요"}</strong>
            <small>${i?Av(i):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${i?o`<div class="mission-inline-note">${i.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?o`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>o`
                  <button class="mission-link-row" onClick=${()=>Nc(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${Fe(l.status)} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:o`<div class="empty-state">직접 연결된 세션이 아직 없습니다.</div>`}

        ${e.related_agent_names.length>0?o`
              <div class="mission-pill-row">
                ${e.related_agent_names.slice(0,8).map(l=>o`
                  <button class="mission-pill action" onClick=${()=>ms(l)}>${l}</button>
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
              <button class="control-btn ghost" onClick=${()=>Ki(i,s,"상황판 주의 신호")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>Ec(i,s,"상황판 주의 신호")}>
                원인 보기
              </button>
            `:o`
              <button class="control-btn ghost" onClick=${()=>Mc(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>jc(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function yf({brief:e,selected:t}){var i,l;const n=e.member_previews.slice(0,4),s=e.top_recommendation??null,a=e.top_attention??null;return o`
    <article class="mission-crew-card ${$e(((i=e.top_attention)==null?void 0:i.severity)??e.health??e.status)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Nc(e.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${e.goal}</strong>
            <div class="mission-card-target">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          </div>
          <span class="command-chip ${$e(((l=e.top_attention)==null?void 0:l.severity)??e.health??e.status)}">${Fe(e.status)}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${e.member_names.length}</strong>
            <small>${e.member_names.slice(0,3).join(", ")||"없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${Sv(e.elapsed_sec)}</strong>
            <small>${e.started_at?`${we(e.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 흐름</span>
            <strong>${e.last_event_at?we(e.last_event_at):"기록 없음"}</strong>
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
        <small>${e.last_event_at?we(e.last_event_at):"시각 없음"}</small>
      </div>

      ${e.operation_badges.length>0?o`
            <div class="mission-pill-row">
              ${e.operation_badges.slice(0,3).map(c=>o`
                <span class="mission-pill">
                  ${c.operation_id} · ${Fe(c.status)}${c.stage?` · ${c.stage}`:""}
                </span>
              `)}
            </div>
          `:null}

      ${n.length>0?o`
            <div class="mission-member-preview-grid">
              ${n.map(c=>o`
                <button class="mission-member-preview" onClick=${()=>ms(c.agent_name)}>
                  <strong>${c.agent_name}</strong>
                  <span>${c.current_work??"현재 작업 없음"}</span>
                  <small>${c.recent_output_preview??c.recent_input_preview??"최근 입출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>ri("intervene",e.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>ri("command",e.session_id)}>세션 원인 보기</button>
        ${s?o`<button class="control-btn ghost" onClick=${()=>Ki(s,a,"상황판 세션 요약")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function bf({detail:e,loading:t,error:n}){if(t&&!e)return o`
      <${T} title="세션 상세" class="mission-list-card">
        <div class="loading-indicator">세션 상세 불러오는 중...</div>
      <//>
    `;if(n&&!e)return o`
      <${T} title="세션 상세" class="mission-list-card">
        <div class="empty-state error">${n}</div>
      <//>
    `;if(!(e!=null&&e.session))return null;const s=e.session;return o`
    <${T} title="세션 상세" class="mission-list-card" semanticId="mission.session_detail">
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
                      <span>${a.timestamp?we(a.timestamp):"시각 없음"}</span>
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
                  <button class="mission-member-preview" onClick=${()=>ms(a.agent_name)}>
                    <strong>${a.agent_name}</strong>
                    <span>${a.current_work??"현재 작업 없음"}</span>
                    <small>
                      ${a.recent_output_preview??a.recent_input_preview??"최근 입출력 없음"}
                      ${a.last_activity_at?` · ${we(a.last_activity_at)}`:""}
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
                  <button class="mission-link-row" onClick=${()=>ri("command",s.session_id)}>
                    <strong>${a.operation_id}</strong>
                    <span>${Fe(a.status)}${a.stage?` · ${a.stage}`:""}</span>
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
                    <span>${Fe(a.status)}${a.generation!=null?` · 세대 ${a.generation}`:""}</span>
                    <small>${a.current_work??"현재 작업 정보 없음"}</small>
                  </div>
                `):o`<div class="empty-state">직접 연결된 키퍼는 없습니다.</div>`}
          </div>
        </div>
      </div>
    <//>
  `}function kf({row:e}){var s,a,i,l,c,u,p,g,f,v;const t=[`세대 ${e.brief.generation??((s=e.keeper)==null?void 0:s.generation)??0}`,e.brief.context_ratio!=null?`컨텍스트 ${Math.round(e.brief.context_ratio*100)}%`:((a=e.keeper)==null?void 0:a.context_ratio)!=null?`컨텍스트 ${Math.round(e.keeper.context_ratio*100)}%`:null,e.brief.last_turn_ago_s!=null?`최근 턴 ${Math.round(e.brief.last_turn_ago_s)}초 전`:null].filter(h=>h!==null).join(" · "),n=e.recentTools.length>0?e.recentTools.join(", "):Je(Hi(e.keeper));return o`
    <article class="mission-activity-card ${$e(e.brief.status??((i=e.keeper)==null?void 0:i.status))}">
      <button class="mission-card-select" onClick=${()=>{e.keeper&&Wc(e.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((l=e.keeper)==null?void 0:l.emoji)??""}</span>
            <div>
              <strong>${e.brief.name}</strong>
              ${(c=e.keeper)!=null&&c.koreanName?o`<span>${e.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${$e(e.brief.status??((u=e.keeper)==null?void 0:u.status))}">${Fe(e.brief.status??((p=e.keeper)==null?void 0:p.status))}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 하트비트 · ${(g=e.keeper)!=null&&g.last_heartbeat?we(e.keeper.last_heartbeat):"기록 없음"}</span>
          <span>${t||"연속성 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${e.currentWork}</strong>
          ${(f=e.keeper)!=null&&f.skill_reason?o`<small>판단 요약 · ${je(e.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>연속성 상세</summary>
        <div class="mission-activity-foot">
          <span>에이전트 · ${e.brief.agent_name??((v=e.keeper)==null?void 0:v.agent_name)??"기록 없음"}</span>
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
  `}function xf({item:e}){const t=e.action??null,n=e.attention??null;return o`
    <article class="mission-action-card ${$e(e.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${$e(e.severity)}">
          ${e.signal_type==="action"&&t?Ya(t.action_type):(n==null?void 0:n.kind)??"내부 신호"}
        </span>
        <span class="mission-card-target">${xa(e.target_type)}${e.target_id?` · ${e.target_id}`:""}</span>
      </div>
      <p>${e.summary}</p>
      ${t?o`<div class="mission-action-preview">${t.reason}</div>`:null}
      <div class="mission-card-actions">
        ${t?o`
              <button class="control-btn ghost" onClick=${()=>Ki(t,n,"상황판 내부 신호")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Ec(t,n,"상황판 내부 신호")}>이 이슈의 원인 보기</button>
            `:n?o`
                <button class="control-btn ghost" onClick=${()=>Mc(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>jc(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function Rr(){var h,b,C,x;const e=ls.value;if(Xo.value&&!e)return o`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(ca.value&&!e)return o`<div class="empty-state error">${ca.value}</div>`;if(!e)return o`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;Ge.value&&!e.attention_queue.some(S=>S.id===Ge.value)&&(Ge.value=null);const t=e.sessions;st.value&&!t.some(S=>S.session_id===st.value)&&(st.value=null);const n=e.attention_queue.find(S=>S.id===Ge.value)??null,s=(n==null?void 0:n.related_session_ids.find(S=>t.some(_=>_.session_id===S)))??null,a=st.value??s??((h=t[0])==null?void 0:h.session_id)??null,i=zv(),l=t.find(S=>S.session_id===a)??null,c=e.keeper_briefs.slice(0,6).map(Iv),u=e.attention_queue.filter(S=>S.related_session_ids.length>0).slice(0,6),p=e.internal_signals.slice(0,3),g=t.filter(S=>{var I;const _=((I=S.top_attention)==null?void 0:I.severity)??S.health??S.status;return $e(_)!=="ok"||!!S.blocker_summary}).length,f=new Set(t.flatMap(S=>S.member_names)).size,v=t.flatMap(S=>S.member_previews??[]).filter(S=>S.recent_output_preview).length+c.filter(S=>S.recentOutput).length;return oe(()=>{o_(a)},[a]),o`
    <section class="dashboard-panel mission-view">
      <${Se} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 어떤 세션이 돌고 있고, 누가 참여하며, 어디가 막혔는지를 한 시점에서 읽는 기본 관찰면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${$e(e.summary.room_health)}">${Fe(e.summary.room_health)}</span>
          <span class="command-chip">${e.summary.project??"프로젝트 미지정"}${e.summary.current_room?` · ${e.summary.current_room}`:""}</span>
          <span class="command-chip">${e.generated_at?we(e.generated_at):"기록 없음"}</span>
        </div>
      </div>

      <${Va} />

      <${gf}
        cluster=${e.summary.cluster}
        project=${e.summary.project}
        room=${e.summary.current_room}
        generatedAt=${e.generated_at}
      />

      <${$f} />

      <div class="mission-stat-grid">
        <${qt} label="활성 세션" value=${t.length} detail="지금 진행중인 협업 단위" tone=${((b=l==null?void 0:l.top_attention)==null?void 0:b.severity)??(l==null?void 0:l.health)??"ok"} />
        <${qt} label="막힌 세션" value=${g} detail="주의가 필요한 흐름" tone=${g>0?"warn":"ok"} />
        <${qt} label="참여자" value=${f} detail="현재 세션에 연결된 주체" tone=${f>0?"ok":"warn"} />
        <${qt} label="키퍼 관찰" value=${c.length} detail="연속성 확인 대상" tone=${((C=c[0])==null?void 0:C.brief.status)??"ok"} />
        <${qt} label="최근 응답" value=${v} detail="메인에서 바로 읽을 수 있는 응답 수" tone=${v>0?"ok":"warn"} />
        <${qt} label="내부 신호" value=${p.length} detail="시스템 진단은 보조 면에만 유지" tone=${((x=p[0])==null?void 0:x.severity)??"ok"} />
      </div>

      ${a?o`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${(l==null?void 0:l.goal)??a}${n?` · ${n.summary}`:""}</span>
              <button class="control-btn ghost" onClick=${Lv}>선택 해제</button>
            </div>
          `:null}

      <${T} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 작전을 먼저 봅니다.</p>
        </div>
        <div class="mission-list-stack">
          ${t.length>0?t.map(S=>o`<${yf} key=${S.session_id} brief=${S} selected=${a===S.session_id} />`):o`<div class="empty-state">지금 활성 세션이 없습니다.</div>`}
        </div>
      <//>

      <${bf}
        detail=${Zo.value}
        loading=${Gs.value}
        error=${Js.value}
      />

      <div class="mission-human-grid">
        <${T} title="주의 대기열" class="mission-list-card" semanticId="mission.attention_queue">
          <div class="mission-section-head">
            <h3>어느 세션을 먼저 봐야 하나</h3>
            <p>문제와 경고는 세션에 연결된 것만 먼저 보여주고, 원인 분석은 선택된 세션에서 이어서 봅니다.</p>
          </div>
          <div class="mission-lane-stack">
            ${u.length>0?u.map(S=>o`<${hf} key=${S.id} item=${S} selected=${Ge.value===S.id} sessionLookup=${i} />`):o`<div class="empty-state">지금 세션 단위 주의 대기열은 비어 있습니다.</div>`}
          </div>
        <//>

        <${T} title="내부 신호" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>시스템 진단</h3>
            <p>artifact scope drift 같은 내부 신호는 메인 판단을 방해하지 않도록 접어 둔 보조 면에만 둡니다.</p>
          </div>
          <details class="mission-card-disclosure">
            <summary>내부 신호 ${p.length}</summary>
            <div class="mission-list-stack">
              ${p.length>0?p.map(S=>o`<${xf} key=${S.id} item=${S} />`):o`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
            </div>
          </details>
        <//>
      </div>

      <${T} title="키퍼 연속성" class="mission-list-card" semanticId="mission.keeper_activity">
        <div class="mission-section-head">
          <h3>연속성 보조 면</h3>
          <p>키퍼는 세션과 별개로 보고, 연속성 판단에 필요한 정보만 먼저 보여줍니다.</p>
        </div>
        <div class="mission-activity-list">
          ${c.length>0?c.map(S=>o`<${kf} key=${S.brief.name} row=${S} />`):o`<div class="empty-state">지금 보이는 키퍼가 없습니다.</div>`}
        </div>
        <div class="mission-card-actions">
          <button class="control-btn ghost" onClick=${()=>ie("execution")}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${()=>ie("command")}>지휘 진단면 보기</button>
        </div>
      <//>
    </section>
  `}const Sf="modulepreload",Cf=function(e){return"/dashboard/"+e},Lr={},Af=function(t,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(p){return Promise.all(p.map(g=>Promise.resolve(g).then(f=>({status:"fulfilled",value:f}),f=>({status:"rejected",reason:f}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),u=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(p=>{if(p=Cf(p),p in Lr)return;Lr[p]=!0;const g=p.endsWith(".css"),f=g?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${p}"]${f}`))return;const v=document.createElement("link");if(v.rel=g?"stylesheet":Sf,g||(v.as="script"),v.crossOrigin="",v.href=p,u&&v.setAttribute("nonce",u),document.head.appendChild(v),g)return new Promise((h,b)=>{v.addEventListener("load",h),v.addEventListener("error",()=>b(new Error(`Unable to preload CSS for ${p}`)))})}))}function i(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&i(c.reason);return t().catch(i)})};function Aa(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function ee(e){if(!e)return"정보 없음";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}초 전`:n<3600?`${Math.round(n/60)}분 전`:n<86400?`${Math.round(n/3600)}시간 전`:`${Math.round(n/86400)}일 전`}function Tf(e){if(!e)return"warn";const t=Date.parse(e);return Number.isNaN(t)?"warn":t<=Date.now()?"bad":"ok"}function Jc(e){if(!e)return"정보 없음";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.round((t-Date.now())/1e3);return n<=0?"기한 지남":n<60?`${n}초 후`:n<3600?`${Math.round(n/60)}분 후`:n<86400?`${Math.round(n/3600)}시간 후`:`${Math.round(n/86400)}일 후`}function P(e){return e==="bad"?"bad":e==="warn"||e==="pending"?"warn":"ok"}let Pr=!1,If=0;function zf(){return++If}let lo=null;async function Rf(){lo||(lo=Af(()=>import("./mermaid.core-DEBD72iT.js").then(t=>t.bE),[]).then(t=>t.default));const e=await lo;return Pr||(e.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),Pr=!0),e}function ct(e){if(!e)return"warn";const t=e.toLowerCase();return t.includes("failed")||t.includes("error")||t.includes("disconnected")||t.includes("stopped")?"bad":t.includes("running")||t.includes("active")||t.includes("degraded")||t.includes("pending")?"warn":"ok"}function _s(e){return typeof e!="number"||!Number.isFinite(e)?"정보 없음":`${Math.round(e*100)}%`}function In(e){return typeof e!="number"||!Number.isFinite(e)?"정보 없음":e<60?`${Math.round(e)}초`:e<3600?`${Math.round(e/60)}분`:`${Math.round(e/3600)}시간`}function vs(e){return typeof e!="number"||!Number.isFinite(e)?0:Math.max(0,Math.min(100,e))}function kt(e,t){return typeof e!="number"||!Number.isFinite(e)||typeof t!="number"||!Number.isFinite(t)||t<=0?0:vs(e/t*100)}function Lf(e,t){const n=vs(e);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${t};`}function Vc(e){if(!e)return"최근 체인 이력이 없습니다";const t=[e.event];return typeof e.duration_ms=="number"&&t.push(`${e.duration_ms}ms`),typeof e.tokens=="number"&&t.push(`토큰 ${e.tokens}`),e.message&&t.push(e.message),t.join(" · ")}const Pf=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],Yc=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"orchestra",label:"오케스트라",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],Mf=Yc.map(e=>e.id),jf=["chain_start","node_start","node_complete","chain_complete","chain_error"],Ef={warroom:{title:"실시간 워룸",description:"실제 실행, 워커, 메시지, 트레이스를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 작전, 분견대, 의존 관계를 먼저 읽는 기본 진입 표면입니다."},orchestra:{title:"룸 오케스트라 맵",description:"룸, 세션, 레인, 워커, 키퍼를 한 장의 작전판으로 읽는 시각화 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"레인 이동, 워커 결속, 막힘을 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 작전별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"실제 관리 유닛인지, 실시간 에이전트 기반 자동 투영인지 구분해서 봅니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"작전, 주체, 유닛 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"결정 승인과 유닛 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function Mr(e){return!!e&&Mf.includes(e)}function Nf(){const e=O.value.params;return e.source!=="mission"&&e.source!=="execution"?{}:{source:e.source,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function Wi(e){const t=Nf(),n=Zc(),s=Gi();if(e==="operations")return t;if(e==="chains"){const a=sn.value;return a?{...t,surface:e,operation:a}:{...t,surface:e}}return e==="swarm"||e==="warroom"||e==="orchestra"?{...t,surface:e,...n?{run_id:n}:{},...s?{operation_id:s}:{}}:{...t,surface:e}}function Df(){const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");return n&&t.set("agent",n),s&&t.set("token",s),t.toString()?`/api/v1/chains/events?${t.toString()}`:"/api/v1/chains/events"}function Of(e){switch(e){case"company":return"중대";case"platoon":return"소대";case"squad":return"분대";case"agent":return"에이전트";default:return e}}function de(e){return ti.value===e}function fs(){return Pi.value}function qf(e){var a,i,l,c,u,p,g;const t=Pi.value,n=Dt.value,s=ds.value;switch(e){case"warroom":return{tool:"masc_observe_operations",reason:"실시간 실행, 워커, 메시지, 트레이스를 한 화면에서 보고 필요한 세부 표면으로 바로 이동합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=t==null?void 0:t.operations.summary)==null?void 0:a.active)??0}개와 의존 관계를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(i=t==null?void 0:t.swarm_status)==null?void 0:i.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((u=(c=t==null?void 0:t.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:u.reason)??"레인 이동과 막힘 근거를 보고 다음 확인 도구를 고릅니다."};case"orchestra":return{tool:"masc_operator_snapshot",reason:"룸, 세션, 레인, 워커, 키퍼를 한 장에서 훑은 뒤 내려볼 대상을 고릅니다."};case"chains":return{tool:(g=(p=s==null?void 0:s.operations[0])==null?void 0:p.preview_run)!=null&&g.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"이 구조가 실제 관리 단위인지 자동 투영인지 먼저 구분해야 지휘면을 오해하지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 유닛과 작전을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"트레이스 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 제어 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function wf(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"microarch":t.includes("leader_offline")||t.includes("roster_offline")?"alerts":t.includes("stale_data")?"swarm":null:null}function Ff(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")?"recommendation":t.includes("gap")?"gaps":null:null}function Qc(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");if(!t)return null;const n=t.trim();return n===""?null:n}function Xc(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,i)=>{e.has(i)||e.set(i,a)}),e}function Zc(){const t=Xc().get("run_id");if(!t)return null;const n=t.trim();return n===""?null:n}function Gi(){const t=Xc().get("operation_id");if(!t)return null;const n=t.trim();return n===""?null:n}function Kf(e){if(!e)return null;const t=Date.parse(e);return Number.isNaN(t)?null:Math.max(0,Math.round((Date.now()-t)/1e3))}function Hf(e){return e.status==="claimed"||e.status==="in_progress"}function Uf(e){const t=cs.value;if(!t)return null;for(const n of t.golden_paths){const s=n.steps.find(a=>a.tool===e);if(s)return s}return null}function co(e){var t;return((t=cs.value)==null?void 0:t.golden_paths.find(n=>n.id===e))??null}function Bf(e){const t=cs.value;if(!t)return[];const n=new Set(e);return t.pitfalls.filter(s=>n.has(s.id))}async function dt(e){try{await e()}catch{}}function Ji(e){return(e==null?void 0:e.trim().toLowerCase())??""}function Gt(e){const t=Ji(e);return t.includes("failed")||t.includes("error")||t.includes("stopped")||t==="paused"?"bad":t.includes("active")||t.includes("running")||t.includes("healthy")||t.includes("ok")?"ok":"warn"}function xt(e){const t=Ji(e);return t?t==="active"||t==="running"?"진행 중":t==="paused"?"일시정지":t==="done"||t==="ended"||t==="completed"?"완료":t==="failed"||t==="error"||t==="stopped"?"문제":(e==null?void 0:e.trim())||"확인 필요":"확인 필요"}function Wf(){var n,s,a,i,l,c,u,p,g;const e=Dt.value;if(!e)return!1;const t=e.workers.some(f=>f.joined||f.live_presence||f.completed||f.current_task_matches_run||f.heartbeat_fresh||f.claim_marker_seen||f.done_marker_seen||f.final_marker_seen||!!f.current_task||!!f.bound_task_id||!!f.last_message);return!!((n=e.operation)!=null&&n.operation_id||(s=e.detachment)!=null&&s.detachment_id||(((a=e.summary)==null?void 0:a.joined_workers)??0)>0||(((i=e.summary)==null?void 0:i.live_workers)??0)>0||(((l=e.summary)==null?void 0:l.current_task_bound)??0)>0||(((c=e.summary)==null?void 0:c.fresh_heartbeats)??0)>0||(((u=e.summary)==null?void 0:u.claim_markers_seen)??0)>0||(((p=e.summary)==null?void 0:p.done_markers_seen)??0)>0||(((g=e.summary)==null?void 0:g.final_markers_seen)??0)>0||t||e.recent_messages.length>0||e.recent_trace_events.length>0)}function Gf(e){const t=Ji(e.status);return t==="active"||t==="running"}function Jf(){var i,l,c,u;const e=((i=he.value)==null?void 0:i.sessions)??[],t=Dt.value,n=((l=t==null?void 0:t.detachment)==null?void 0:l.session_id)??null;if(n){const p=e.find(g=>g.session_id===n);if(p)return p}const s=((c=t==null?void 0:t.operation)==null?void 0:c.operation_id)??Gi();if(s){const p=e.find(g=>g.command_plane_operation_id===s);if(p)return p}const a=((u=t==null?void 0:t.detachment)==null?void 0:u.detachment_id)??null;if(a){const p=e.find(g=>g.command_plane_detachment_id===a);if(p)return p}return e.find(Gf)??e[0]??null}function uo(e){return e==="proven"?"ok":e==="partial"?"warn":"bad"}function Jt(e){return Array.isArray(e)?e:[]}function Ee(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)?e:{}}function Ts(e){return typeof e=="string"&&e.trim()!==""?e:null}function Vf(e){return typeof e=="number"&&Number.isFinite(e)?e:null}function Yf(e){const t=e.split("/");return t.length<=3?e:`…/${t.slice(-3).join("/")}`}function Qf(e){return e==="proven"?"충분":e==="partial"?"부분":"부족"}function Xf(e){return e==="proven"?"협업 증거가 충분합니다":e==="partial"?"흔적은 있으나 협업 증거가 덜 모였습니다":"증거가 부족합니다"}function Zf(e,t,n,s,a,i,l){const c=[`${t}명이 실제 흔적을 남겼고, 계획된 참여자는 ${n}명입니다.`,a>0?`서로를 참조한 상호작용 증거가 ${a}건 있습니다.`:"서로를 참조한 명시적 상호작용 증거가 아직 없습니다.",i>0?`도구·산출물·체크포인트 증거가 ${i}건 있습니다.`:"도구·산출물·체크포인트 증거가 거의 없습니다.",l>0?`CPv2 backing trace가 ${l}건 있어 실행 흔적은 남아 있습니다.`:"관리형 backing trace는 아직 없습니다."];return e==="partial"?[c[0]??"",s>0?`partial인 이유: 호출되었지만 응답하지 않은 참여자가 ${s}명 있습니다.`:a===0?"partial인 이유: 여러 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.":"partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.",l>0?"다음 보강 포인트: 응답 턴이나 도구 호출을 남기면 proof가 협업 수준으로 올라갑니다.":"다음 보강 포인트: 관리형 trace 또는 산출물 연결을 더 남기면 근거가 강해집니다."]:e==="proven"?[c[0]??"","결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.","다음 행동: raw evidence는 접어두고 결과 산출물과 다음 실행 결정만 확인하면 됩니다."]:[c[0]??"",s>0?`결론: 협업 시도는 있었지만 무응답 참여자가 ${s}명 있어 협업 증거로 인정하기 어렵습니다.`:"결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.",i>0?"다음 보강 포인트: 응답 턴과 도구 근거를 서로 연결해 남겨야 합니다.":"다음 보강 포인트: 참여자 간 턴, 도구 근거, 산출물 연결을 더 남겨야 합니다."]}function jr(e){return(e==null?void 0:e.mode)==="requested_not_found"?"bad":(e==null?void 0:e.mode)==="latest_auto_selected"?"warn":"ok"}function eg(e){return(e==null?void 0:e.mode)==="requested_not_found"?"선택 실패":(e==null?void 0:e.mode)==="latest_auto_selected"?"자동 선택":(e==null?void 0:e.mode)==="explicit"?"명시 선택":"선택 없음"}function tg(e){return e.activity_state==="acted"?(e.interaction_count??0)>0||(e.tool_evidence_count??0)>0?"ok":"warn":e.activity_state==="mentioned_only"?"warn":"bad"}function ng(e){return e.activity_state==="acted"?"실제 흔적":e.activity_state==="mentioned_only"?"호출만 됨":"계획만 됨"}function sg(e){if(e.activity_state==="acted")return`턴 ${e.turn_count??0} · spawn ${e.spawn_count??0} · 도구 근거 ${e.tool_evidence_count??0}`;if(e.activity_state==="mentioned_only"){const t=e.requested_by?`호출자 ${e.requested_by}`:"호출자 미상";return`호출 ${e.mention_count??0}회 · ${t}`}return"계획된 참여자이지만 아직 이벤트가 없습니다."}function Er(e){return Array.isArray(e.tool_names)?e.tool_names:[]}function ag({selection:e}){return!e||e.mode==="explicit"?null:o`
    <div class="command-guide-card ${jr(e)}">
      <div class="command-guide-head">
        <strong>${eg(e)}</strong>
        <span class="command-chip ${jr(e)}">${e.mode??"none"}</span>
      </div>
      <p>${e.reason??"근거 컨텍스트 선택 정보가 없습니다."}</p>
      <div class="command-card-grid">
        <span>선택된 세션</span><span>${e.selected_session_id??"없음"}</span>
        <span>작성자</span><span>${e.selected_created_by??"없음"}</span>
        <span>선택된 목표</span><span>${e.selected_goal??"없음"}</span>
        <span>가용 세션 수</span><span>${e.available_session_count??0}</span>
      </div>
    </div>
  `}function og({item:e}){return o`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${e.summary??e.event_type??"도구 근거"}</strong>
          <div class="command-meta-line">
            <span>${e.actor??"시스템"}</span>
            <span>${e.event_type??"event"}</span>
          </div>
        </div>
        <span class="command-chip">${ee(e.timestamp??null)}</span>
      </div>
      ${Er(e).length>0?o`<div class="semantic-tag-row">
            ${Er(e).map(t=>o`<span class="semantic-tag">${t}</span>`)}
          </div>`:null}
    </article>
  `}function ig(e){const t=new Map;for(const n of e){const s=[n.timestamp??"",n.event_type??"",n.actor??"",n.summary??""].join("|"),a=n.source??"unknown",i=t.get(s);if(i){i.sources.includes(a)||i.sources.push(a),!i.operation_id&&n.operation_id&&(i.operation_id=n.operation_id);continue}t.set(s,{...n,sources:[a]})}return[...t.values()]}function rg(e){return e.sources.length===2?"세션 + 지휘":e.sources.length===1?e.sources[0]==="unknown"?"출처 미상":e.sources[0]??"출처":e.sources.join(" + ")}function lg(e){const t=[];for(const[n,s]of Object.entries(e))if(s!=null){if(typeof s=="string"){if(s.trim()==="")continue;t.push({label:n,value:s});continue}if(typeof s=="number"||typeof s=="boolean"){t.push({label:n,value:String(s)});continue}}return t}function cg(e){const t=Ee(e),n=Ee(t.traces),s=Array.isArray(n.events)?n.events:[],a=Ee(t.detachments),i=Array.isArray(a.detachments)?a.detachments:[],l=Ee(i[0]),c=Ee(l.detachment),u=Ee(l.operation),p=Ee(t.summary),g=Ee(p.operations),f=Ee(g.summary);return[{label:"작전",value:Ts(t.operation_id)??"없음"},{label:"분견대",value:Ts(t.detachment_id)??"없음"},{label:"트레이스 이벤트",value:`${s.length}`},{label:"분견대 상태",value:Ts(c.status)??"없음"},{label:"작전 단계",value:Ts(u.stage)??"없음"},{label:"활성 작전",value:`${Vf(f.active)??0}`}]}function dg({item:e}){return o`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${e.summary??e.event_type??"이벤트"}</strong>
          <div class="command-meta-line">
            <span>${rg(e)}</span>
            <span>${e.event_type??"이벤트"}</span>
            <span>${e.actor??"시스템"}</span>
          </div>
        </div>
        <span class="command-chip">${ee(e.timestamp)}</span>
      </div>
      ${e.sources.length>1?o`<div class="semantic-tag-row">
            ${e.sources.map(t=>o`<span class="semantic-tag">${t}</span>`)}
          </div>`:null}
    </article>
  `}function ug({item:e}){const t=e.recent_output_preview??null,n=e.recent_input_preview??null,s=e.recent_event_summary??null,a=e.recent_request_preview??null,i=e.last_active_at??e.recent_request_at??null;return o`
    <article class="mission-activity-row proof-actor-row">
      <div class="mission-activity-head">
        <div>
          <strong>${e.actor}</strong>
          <div class="mission-activity-meta">
            <span>${e.role??"참여자"}</span>
            <span>${i?ee(i):"기록 없음"}</span>
          </div>
        </div>
        <span class="command-chip ${tg(e)}">
          ${ng(e)}
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>${sg(e)}</span>
      </div>
      ${e.activity_detail?o`<div class="proof-summary-block">
            <strong>현재 해석</strong>
            <span>${e.activity_detail}</span>
          </div>`:null}
      ${s?o`<div class="proof-summary-block">
            <strong>최근 흔적</strong>
            <span>${s}</span>
          </div>`:null}
      ${a&&e.activity_state!=="acted"?o`<div class="proof-summary-block">
            <strong>최근 요청</strong>
            <span>${a}</span>
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
      ${Jt(e.recent_tool_names).length>0?o`<div class="semantic-tag-row">
            ${Jt(e.recent_tool_names).map(l=>o`<span class="semantic-tag">${l}</span>`)}
          </div>`:null}
    </article>
  `}function pg({item:e}){return o`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${e.kind}</strong>
          <div class="command-meta-line">
            <span>${Yf(e.path)}</span>
          </div>
        </div>
        <span class="command-chip ${e.exists?"ok":"warn"}">${e.exists?"존재함":"없음"}</span>
      </div>
    </article>
  `}function Nr({title:e,rows:t}){return t.length===0?null:o`
    <div class="proof-kv-block">
      ${e?o`<strong>${e}</strong>`:null}
      <div class="proof-kv-grid">
        ${t.map(n=>o`
          <span>${n.label}</span>
          <strong>${n.value}</strong>
        `)}
      </div>
    </div>
  `}function mg(){var G,Q,se;const e=O.value.params,t=e.session_id??null,n=e.operation_id??null;oe(()=>{uc(t,n)},[t,n]);const s=dc.value;if(ei.value&&!s)return o`<section class="dashboard-panel"><div class="loading-indicator">근거 화면 불러오는 중…</div></section>`;if(Bt.value&&!s)return o`<section class="dashboard-panel"><div class="error-card">${Bt.value}</div></section>`;const a=s==null?void 0:s.summary,i=(s==null?void 0:s.selection)??null,l=Jt(s==null?void 0:s.actor_contributions),c=Jt(s==null?void 0:s.artifacts),u=Jt(s==null?void 0:s.tool_evidence),p=(s==null?void 0:s.proof_verdict)??"insufficient",g=(s==null?void 0:s.cp_backing_evidence)??null,f=Array.isArray((G=g==null?void 0:g.traces)==null?void 0:G.events)?((se=(Q=g.traces)==null?void 0:Q.events)==null?void 0:se.length)??0:0,v=(a==null?void 0:a.actors_count)??l.length,h=(a==null?void 0:a.planned_actor_count)??l.length,b=(a==null?void 0:a.unanswered_actor_count)??l.filter(M=>M.activity_state!=="acted"&&(M.mention_count??0)>0).length,C=(a==null?void 0:a.mentioned_actor_count)??l.filter(M=>(M.mention_count??0)>0).length,x=(a==null?void 0:a.interaction_count)??0,S=(a==null?void 0:a.evidence_count)??0,_=ig(Jt(s==null?void 0:s.timeline)),I=lg(Ee(s==null?void 0:s.goal_binding)),R=cg(g),L=c.filter(M=>M.exists).length,V=c.length-L,z=Zf(p,v,h,b,x,S,f);return o`
    <section class="dashboard-panel mission-view">
      <${Se} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>근거</h2>
          <p>이 세션이 실제로 여러 참여자의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${uo(p)}">${Qf(p)}</span>
          ${s!=null&&s.session_id?o`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?o`<span class="command-chip">${ee(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${Bt.value?o`<div class="error-card">${Bt.value}</div>`:null}

      <${ag} selection=${i} />

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${uo(p)}">
          <span>판정</span>
          <strong>${Xf(p)}</strong>
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
          <small>${C>0?`${C}명 호출됨`:"호출 기록 없음"}</small>
        </div>
        <div class="summary-stat-card ${b>0?"warn":"ok"}">
          <span>무응답</span>
          <strong>${b}</strong>
          <small>${b>0?"호출됐지만 응답 근거 없음":"무응답 참여자 없음"}</small>
        </div>
        <div class="summary-stat-card ${x>0?"ok":"warn"}">
          <span>직접 상호작용</span>
          <strong>${x}</strong>
          <small>참여자 간 직접 연결 근거</small>
        </div>
        <div class="summary-stat-card ${S>0?"ok":"warn"}">
          <span>근거</span>
          <strong>${S}</strong>
          <small>도구 / 산출물 / 체크포인트</small>
        </div>
        <div class="summary-stat-card ${f>0?"ok":"warn"}">
          <span>CP 트레이스</span>
          <strong>${f}</strong>
          <small>관리형 backing 이벤트</small>
        </div>
        <div class="summary-stat-card ${V===0&&c.length>0?"ok":"warn"}">
          <span>산출물</span>
          <strong>${L}/${c.length}</strong>
          <small>${V>0?`${V}개 누락`:"전부 존재함"}</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${T} title="3줄 근거 요약" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, 왜 아직 부족한지, 다음에 무엇을 남겨야 하는지만 먼저 봅니다.</p>
          </div>
          <div class="proof-summary-stack">
            ${z.map((M,J)=>o`
              <article class="proof-summary-block ${J===1&&p!=="proven"?uo(p):""}">
                <strong>${J===0?"지금 결론":J===1?"왜 이렇게 판정됐나":"다음 보강 포인트"}</strong>
                <span>${M}</span>
              </article>
            `)}
          </div>
        <//>

        <${T} title="목표 연결" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 화면이 어떤 세션과 목표를 기준으로 그려졌는지 먼저 고정합니다.</p>
          </div>
          <${Nr} rows=${I} />
          <details class="mission-card-disclosure compact">
            <summary>원본 목표 연결 JSON</summary>
            <pre class="command-json-block">${Aa((s==null?void 0:s.goal_binding)??{})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${T} title="협업 타임라인" class="mission-list-card" semanticId="proof.timeline">
          <div class="mission-section-head">
            <h3>협업 타임라인</h3>
            <p>team-session과 command-plane에서 같은 사건이 보이면 한 줄로 묶어 읽습니다.</p>
          </div>
          <div class="mission-list-stack">
            ${_.length>0?_.slice(0,18).map(M=>o`<${dg} key=${M.id} item=${M} />`):o`<div class="empty-state">표시할 타임라인 근거가 없습니다.</div>`}
          </div>
        <//>

        <${T} title="참여 흔적" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>실제 흔적, 호출만 된 참여자, 계획만 된 참여자를 구분해서 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${l.length>0?l.map(M=>o`<${ug} key=${M.actor} item=${M} />`):o`<div class="empty-state">표시할 참여 흔적이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${T} title="도구 근거" class="mission-list-card" semanticId="proof.tool_evidence">
          <div class="mission-section-head">
            <h3>어떤 도구를 언제 썼는가</h3>
            <p>숫자만 보여주지 말고, 최근 도구 호출 근거를 직접 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${u.length>0?u.map((M,J)=>o`<${og} key=${`${M.actor??"system"}-${J}`} item=${M} />`):o`<div class="empty-state">기록된 tool evidence가 없습니다.</div>`}
          </div>
        <//>

        <${T} title="실행 근거" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>작전, 분견대, 트레이스 수만 먼저 보고, 원본 CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${Nr} rows=${R} />
          <details class="mission-card-disclosure compact">
            <summary>원본 CPv2 backing JSON</summary>
            <pre class="command-json-block">${Aa(g??{})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${T} title="산출물" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>어떤 파일 산출물이 남았나</h3>
            <p>proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${c.length>0?c.map(M=>o`<${pg} key=${M.path} item=${M} />`):o`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function _g(){const e=us(O.value);return e?o`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${e.source_label}</strong>
        <span class="command-chip">${Ya(e.action_type)}</span>
        <span class="command-chip">${Fi(e)}</span>
        <span class="command-chip">${xv(O.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${e.summary}</div>
      ${e.payload_preview?o`<div class="command-focus-preview">${e.payload_preview}</div>`:null}
    </section>
  `:null}function vg(){const e=Y.value,t=Ef[e],n=qf(e);return o`
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
  `}function Is({label:e,value:t,subtext:n,percent:s,color:a}){return o`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${Lf(s,a)}>
        <div class="command-gauge-core">
          <strong>${t}</strong>
          <span>${Math.round(vs(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${e}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function zs({label:e,value:t,detail:n,percent:s,tone:a}){return o`
    <article class="command-signal-rail ${P(a)}">
      <div class="command-signal-copy">
        <span>${e}</span>
        <strong>${t}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${P(a)}" style=${`width: ${Math.max(8,Math.round(vs(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function fg(){var Q,se,M,J;const e=fs(),t=e==null?void 0:e.topology.summary,n=e==null?void 0:e.operations.summary,s=e==null?void 0:e.detachments.summary,a=e==null?void 0:e.decisions.summary,i=e==null?void 0:e.alerts.summary,l=(Q=e==null?void 0:e.swarm_status)==null?void 0:Q.overview,c=e==null?void 0:e.swarm_proof,u=e==null?void 0:e.operations.microarch,p=(t==null?void 0:t.managed_unit_count)??0,g=(t==null?void 0:t.total_units)??0,f=(n==null?void 0:n.active)??0,v=(s==null?void 0:s.active)??0,h=(l==null?void 0:l.moving_lanes)??0,b=(l==null?void 0:l.active_lanes)??0,C=(c==null?void 0:c.workers.done)??0,x=(c==null?void 0:c.workers.expected)??0,S=(i==null?void 0:i.bad)??0,_=(i==null?void 0:i.warn)??0,I=(a==null?void 0:a.pending)??0,R=(a==null?void 0:a.total)??0,L=f+v,V=((se=u==null?void 0:u.cache)==null?void 0:se.l1_hit_rate)??((J=(M=u==null?void 0:u.signals)==null?void 0:M.cache_contention)==null?void 0:J.l1_hit_rate)??0,z=f>0||v>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",G=f>0||h>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return o`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${z}</h3>
        <p>${G}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${P(f>0?"ok":"warn")}">활성 작전 ${f}</span>
          <span class="command-chip ${P(h>0?"ok":(b>0,"warn"))}">이동 레인 ${h}/${Math.max(b,h)}</span>
          <span class="command-chip ${P(S>0?"bad":_>0?"warn":"ok")}">치명 알림 ${S}</span>
          <span class="command-chip ${P(I>0?"warn":"ok")}">승인 대기 ${I}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${Is}
          label="관리 단위 범위"
          value=${`${p}/${Math.max(g,p)}`}
          subtext=${g>0?`${g-p}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${kt(p,Math.max(g,p))}
          color="#67e8f9"
        />
        <${Is}
          label="실행 열도"
          value=${String(L)}
          subtext=${`${f}개 작전 + ${v}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${kt(L,Math.max(p,L||1))}
          color="#4ade80"
        />
        <${Is}
          label="스웜 이동감"
          value=${`${h}/${Math.max(b,h)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${ee(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${kt(h,Math.max(b,h||1))}
          color="#fbbf24"
        />
        <${Is}
          label="증거 수집률"
          value=${`${C}/${Math.max(x,C)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${kt(C,Math.max(x,C||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${zs}
        label="승인 대기열"
        value=${`${I}건 대기`}
        detail=${`현재 정책 창에서 ${R}개 결정을 추적 중입니다`}
        percent=${kt(I,Math.max(R,I||1))}
        tone=${I>0?"warn":"ok"}
      />
      <${zs}
        label="알림 압력"
        value=${`치명 ${S} / 주의 ${_}`}
        detail=${S>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${kt(S*2+_,Math.max((S+_)*2,1))}
        tone=${S>0?"bad":_>0?"warn":"ok"}
      />
      <${zs}
        label="디스패치 점유"
          value=${`${v}개 가동`}
        detail=${p>0?`${p}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${kt(v,Math.max(p,v||1))}
        tone=${v>0?"ok":"warn"}
      />
      <${zs}
        label="캐시 신뢰도"
        value=${V?_s(V):"정보 없음"}
        detail=${V?"microarch 캐시 텔레메트리에서 집계한 L1 적중률":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${vs((V??0)*100)}
        tone=${V>=.75?"ok":V>=.4?"warn":"bad"}
      />
    </div>
  `}function gg(){var v,h,b,C,x;const e=fs(),t=ds.value,n=us(O.value),s=wf(n),a=e==null?void 0:e.topology.summary,i=e==null?void 0:e.operations.summary,l=(v=e==null?void 0:e.swarm_status)==null?void 0:v.overview,c=e==null?void 0:e.operations.microarch,u=e==null?void 0:e.decisions.summary,p=e==null?void 0:e.alerts.summary,g=(h=c==null?void 0:c.signals)==null?void 0:h.issue_pressure,f=c==null?void 0:c.cache;return o`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(i==null?void 0:i.active)??0}</strong><small>${((b=e==null?void 0:e.detachments.summary)==null?void 0:b.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(u==null?void 0:u.pending)??0}</strong><small>${(u==null?void 0:u.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(p==null?void 0:p.bad)??0}</strong><small>${(p==null?void 0:p.warn)??0}건 주의</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${((C=t==null?void 0:t.summary)==null?void 0:C.active_chains)??0}</strong><small>${((x=t==null?void 0:t.summary)==null?void 0:x.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${ee(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(g==null?void 0:g.pending_ops)??0}</strong><small>${(f==null?void 0:f.l1_hit_rate)!=null?`${_s(f.l1_hit_rate)} L1 적중`:"캐시 데이터 없음"} · ${(g==null?void 0:g.tone)??"정보 없음"}</small></div>
    </div>
  `}function $g(){var Q,se,M,J,A,X,K,te,$t;const e=fs(),t=Ue.value,n=re.value,s=Qc(),a=s?Xe.value.find(H=>H.name===s)??null:null,i=s?at.value.filter(H=>H.assignee===s&&Hf(H)):[],l=((Q=e==null?void 0:e.operations.summary)==null?void 0:Q.active)??0,c=((se=e==null?void 0:e.detachments.summary)==null?void 0:se.total)??0,u=((M=e==null?void 0:e.decisions.summary)==null?void 0:M.pending)??0,p=t==null?void 0:t.detachments.detachments.find(H=>{const Me=H.detachment.heartbeat_deadline,ht=Me?Date.parse(Me):Number.NaN;return H.detachment.status==="stalled"||!Number.isNaN(ht)&&ht<=Date.now()}),g=t==null?void 0:t.alerts.alerts.find(H=>H.severity==="bad"),f=!!(n!=null&&n.room||n!=null&&n.project),v=(a==null?void 0:a.current_task)??null,h=Kf(a==null?void 0:a.last_seen),b=h!=null?h<=120:null,C=[f?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?i.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:at.value.length>0?"masc_claim":"masc_add_task"}:v?b===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${v} 이지만 heartbeat가 stale 합니다 (${h}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${v}${h!=null?` · 마지막 활동 ${h}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!e||(((J=e.topology.summary)==null?void 0:J.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((A=e.topology.summary)==null?void 0:A.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((X=e.topology.summary)==null?void 0:X.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},u>0?{title:"디스패치 준비도",tone:"warn",detail:`${u}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:p||g?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${p?` · detachment ${p.detachment.detachment_id} 가 stalled 상태입니다`:""}${g?` · alert ${g.title??g.alert_id}`:""}${!t&&!p&&!g?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:u>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${t?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],x=f?!s||!a?"masc_join":i.length===0?at.value.length>0?"masc_claim":"masc_add_task":v?b===!1?"masc_heartbeat":!e||(((K=e.topology.summary)==null?void 0:K.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":u>0?"masc_policy_approve":l>0&&c===0||p||g?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",S=Uf(x),I=Bf(x==="masc_set_room"?["repo-root-room"]:x==="masc_plan_set_task"?["claimed-not-current"]:x==="masc_heartbeat"?["heartbeat-stale"]:x==="masc_dispatch_tick"?["no-detachments"]:x==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),R=co("room_task_hygiene"),L=co("cpv2_benchmark"),V=co("supervisor_session"),z=((te=cs.value)==null?void 0:te.docs)??[],G=[R,L,V].filter(H=>H!==null);return o`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${q} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(S==null?void 0:S.title)??x}</strong>
            <span class="command-chip ok">${x}</span>
          </div>
          <p>${(S==null?void 0:S.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${($t=S==null?void 0:S.success_signals)!=null&&$t.length?o`<div class="command-tag-row">
                ${S.success_signals.map(H=>o`<span class="command-tag ok">${H}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${C.map(H=>o`
            <article class="command-readiness-row ${P(H.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${H.title}</strong>
                  <span class="command-chip ${P(H.tone)}">${H.tone}</span>
                </div>
                <p>${H.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${H.tool}</div>
            </article>
          `)}
        </div>

        ${I.length>0?o`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${I.length}</span>
                </div>
                <div class="command-guide-list">
                  ${I.map(H=>o`
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
          <${q} panelId="command.summary" compact=${!0} />
        </div>
        ${ni.value?o`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:fa.value?o`<div class="empty-state error">${fa.value}</div>`:o`
                <div class="command-path-grid">
                  ${G.map(H=>o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${H.title}</strong>
                        <span class="command-chip">${H.id}</span>
                      </div>
                      <p>${H.summary}</p>
                      <div class="command-card-sub">${H.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${H.steps.slice(0,4).map(Me=>o`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Me.tool}</span>
                            <span>${Me.title}</span>
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
  `}function hg(){return o`
    <${fg} />
    <${gg} />
    <${$g} />
  `}function yg(){return pa.value?o`<div class="empty-state">command-plane detail 불러오는 중…</div>`:_a.value?o`<div class="empty-state error">${_a.value}</div>`:o`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}const li=$(null),Dr=1280,Or=760;function qr(e){switch((e??"").trim().toLowerCase()){case"room":return"룸";case"session":return"세션";case"operation":return"작전";case"detachment":return"분견대";case"lane":return"레인";case"worker":return"워커";case"keeper":return"키퍼";default:return(e==null?void 0:e.trim())||"노드"}}function Sn(e,t,n){if(e<=0)return[];if(e===1)return[Math.round((t+n)/2)];const s=(n-t)/(e-1);return Array.from({length:e},(a,i)=>Math.round(t+i*s))}function bg(e,t){const n=new Map;for(const s of e){const a=t(s),i=n.get(a)??[];i.push(s),n.set(a,i)}return n}function kg(e){const t=new Map,n=e.nodes,s=n.find(b=>b.kind==="room")??null,a=n.filter(b=>b.kind==="session"),i=n.filter(b=>b.kind==="operation"),l=n.filter(b=>b.kind==="detachment"),c=n.filter(b=>b.kind==="lane"),u=n.filter(b=>b.kind==="worker"),p=n.filter(b=>b.kind==="keeper");s&&t.set(s.id,{x:640,y:96}),Sn(a.length,170,1110).forEach((b,C)=>{const x=a[C];x&&t.set(x.id,{x:b,y:220})}),Sn(i.length,240,1040).forEach((b,C)=>{const x=i[C];x&&t.set(x.id,{x:b,y:330})}),Sn(l.length,300,980).forEach((b,C)=>{const x=l[C];x&&t.set(x.id,{x:b,y:420})}),Sn(c.length,170,1110).forEach((b,C)=>{const x=c[C];x&&t.set(x.id,{x:b,y:530})});const g=new Map(c.map(b=>{const C=t.get(b.id);return C?[b.id,C.x]:null}).filter(b=>b!==null)),f=bg(u,b=>b.lane_id?`lane:${b.lane_id}`:b.parent_id?b.parent_id:"free");let v=0;for(const[b,C]of f){let x=g.get(b);if(x==null){const _=t.get(b);x=_==null?void 0:_.x}x==null&&(x=180+v%5*200,v+=1),Sn(C.length,x-90,x+90).forEach((_,I)=>{const R=C[I];if(!R)return;const L=I>5?Math.floor(I/6):0;t.set(R.id,{x:_,y:635+L*62})})}const h=p.length>3?[1120,1180]:[1140];return p.forEach((b,C)=>{const x=C%h.length,S=Math.floor(C/h.length);t.set(b.id,{x:h[x]??1140,y:190+S*108})}),t}function xg(e,t){const n=(e.x+t.x)/2,s=t.y>=e.y?32:-32;return`M ${e.x} ${e.y} C ${n} ${e.y+s}, ${n} ${t.y-s}, ${t.x} ${t.y}`}function wr(e,t,n){if(e==="command"){if(t){lt(t),ie("command",{...Wi(t),...n});return}ie("command",n);return}if(e==="intervene"){ie("intervene",n);return}ie("command",n)}function Sg(e){switch(e.kind){case"room":return{width:150,height:150,radius:74};case"worker":return{width:78,height:42,radius:22};case"lane":return{width:170,height:54,radius:16};case"keeper":return{width:120,height:56,radius:24};default:return{width:188,height:64,radius:18}}}function Cg({orchestra:e,roomPoint:t,onSelect:n}){if(!t||e.signals.length===0)return null;const s=108;return o`
    ${e.signals.slice(0,6).map((a,i)=>{const l=(-120+i*38)*(Math.PI/180),c=Math.round(t.x+Math.cos(l)*s),u=Math.round(t.y+Math.sin(l)*s);return o`
        <g
          key=${a.id}
          class=${`orchestra-signal-node ${P(a.tone)}`}
          onClick=${()=>n(a.id)}
        >
          <line x1=${t.x} y1=${t.y} x2=${c} y2=${u} class="orchestra-signal-link" />
          <circle cx=${c} cy=${u} r="16" class="orchestra-signal-dot" />
          <text x=${c} y=${u+4} text-anchor="middle" class="orchestra-signal-glyph">!</text>
        </g>
      `})}
  `}function Ag({edges:e,positions:t,selectedId:n}){return o`
    ${e.map(s=>{const a=t.get(s.source),i=t.get(s.target);if(!a||!i)return null;const l=n!=null&&(s.source===n||s.target===n);return o`
        <path
          key=${s.id}
          d=${xg(a,i)}
          class=${`orchestra-edge ${P(s.tone)} ${s.animated?"animated":""} ${l?"active":""}`}
        />
      `})}
  `}function Tg({orchestra:e,positions:t,selectedId:n,onSelect:s}){var i;const a=((i=e.focus)==null?void 0:i.target_kind)==="node"?e.focus.target_id:null;return o`
    ${e.nodes.map(l=>{const c=t.get(l.id);if(!c)return null;const u=Sg(l),p=l.id===n,g=l.id===a;if(l.kind==="room")return o`
          <g
            key=${l.id}
            class=${`orchestra-node room ${P(l.tone)} ${p?"selected":""} ${g?"focused":""}`}
            onClick=${()=>s(l.id)}
          >
            <circle cx=${c.x} cy=${c.y} r=${u.radius} class="orchestra-room-ring outer" />
            <circle cx=${c.x} cy=${c.y} r=${u.radius-16} class="orchestra-room-ring inner" />
            <text x=${c.x} y=${c.y-10} text-anchor="middle" class="orchestra-room-glyph">${l.glyph??"◎"}</text>
            <text x=${c.x} y=${c.y+22} text-anchor="middle" class="orchestra-room-label">${l.label}</text>
          </g>
        `;const f=c.x-u.width/2,v=c.y-u.height/2;return o`
        <g
          key=${l.id}
          class=${`orchestra-node ${l.kind} ${P(l.tone)} ${p?"selected":""} ${g?"focused":""}`}
          onClick=${()=>s(l.id)}
        >
          <rect x=${f} y=${v} width=${u.width} height=${u.height} rx=${u.radius} class="orchestra-node-body" />
          <text x=${f+16} y=${v+24} class="orchestra-node-glyph">${l.glyph??"•"}</text>
          <text x=${f+38} y=${v+24} class="orchestra-node-label">${l.label}</text>
          ${l.subtitle?o`<text x=${f+38} y=${v+42} class="orchestra-node-subtitle">${l.subtitle}</text>`:null}
          ${l.status?o`<text x=${f+u.width-10} y=${v+18} text-anchor="end" class="orchestra-node-status">${l.status}</text>`:null}
        </g>
      `})}
  `}function ed(e){var s,a;const t=li.value;if(t){const i=e.nodes.find(c=>c.id===t);if(i)return{type:"node",value:i};const l=e.signals.find(c=>c.id===t);if(l)return{type:"signal",value:l}}if(((s=e.focus)==null?void 0:s.target_kind)==="node"){const i=e.nodes.find(l=>{var c;return l.id===((c=e.focus)==null?void 0:c.target_id)});if(i)return{type:"node",value:i}}if(((a=e.focus)==null?void 0:a.target_kind)==="signal"){const i=e.signals.find(l=>{var c;return l.id===((c=e.focus)==null?void 0:c.target_id)});if(i)return{type:"signal",value:i}}const n=e.nodes[0];return n?{type:"node",value:n}:null}function Ig({orchestra:e}){const t=ed(e);if(!t)return o`<aside class="orchestra-drawer card"><div class="empty-state">선택 가능한 대상이 아직 없습니다.</div></aside>`;if(t.type==="signal"){const i=t.value;return o`
      <aside class="orchestra-drawer card ${P(i.tone)}">
          <div class="card-title-row">
            <div class="card-title">${i.label}</div>
          <span class="command-chip ${P(i.tone)}">${qr(i.kind)}</span>
        </div>
        <p>${i.detail??"세부 설명이 없습니다."}</p>
        ${i.suggested_surface?o`
              <div class="command-action-row">
                <button
                  class="control-btn"
                  onClick=${()=>wr("command",i.suggested_surface,i.suggested_params??{})}
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
        <span class="command-chip ${P(n.tone)}">${qr(n.kind)}</span>
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
                onClick=${()=>wr(n.link_tab??"command",n.link_surface,n.link_params??{})}
              >
                이 화면 열기
              </button>
            </div>
          `:null}
    </aside>
  `}function zg(){var i,l,c,u;const e=Mi.value;if(si.value&&!e)return o`<section class="card command-section"><div class="empty-state">오케스트라 맵 불러오는 중…</div></section>`;if(ha.value)return o`<section class="card command-section"><div class="empty-state error">${ha.value}</div></section>`;if(!e)return o`<section class="card command-section"><div class="empty-state">오케스트라 맵 데이터가 아직 없습니다.</div></section>`;const t=kg(e),n=ed(e),s=(n==null?void 0:n.value.id)??null,a=e.nodes.find(p=>p.kind==="room")?t.get(e.nodes.find(p=>p.kind==="room").id)??null:null;return o`
    <section class="card command-section orchestra-surface">
      <div class="card-title-row">
        <div class="card-title">오케스트라 맵</div>
        <${q} panelId="command.orchestra" compact=${!0} />
      </div>
      <p class="command-card-sub">룸 전체를 한 장의 작전판으로 읽는 시각화입니다. 노드를 누르면 관련 신호와 내려볼 대상을 바로 확인할 수 있습니다.</p>

      <div class="orchestra-shell">
        <div class="orchestra-canvas-wrap">
          <svg class="orchestra-canvas" viewBox=${`0 0 ${Dr} ${Or}`}>
            <defs>
              <pattern id="orchestra-grid" width="32" height="32" patternUnits="userSpaceOnUse">
                <path d="M 32 0 L 0 0 0 32" fill="none" class="orchestra-grid-line"></path>
              </pattern>
            </defs>
            <rect width=${Dr} height=${Or} fill="url(#orchestra-grid)" class="orchestra-grid"></rect>
            <${Ag} edges=${e.edges} positions=${t} selectedId=${s} />
            <${Cg} orchestra=${e} roomPoint=${a} onSelect=${p=>{li.value=p}} />
            <${Tg}
              orchestra=${e}
              positions=${t}
              selectedId=${s}
              onSelect=${p=>{li.value=p}}
            />
          </svg>
          <div class="orchestra-summary-strip">
            <span class="command-chip">세션 ${((i=e.summary)==null?void 0:i.session_count)??0}</span>
            <span class="command-chip">워커 ${((l=e.summary)==null?void 0:l.worker_count)??0}</span>
            <span class="command-chip">키퍼 ${((c=e.summary)==null?void 0:c.keeper_count)??0}</span>
            <span class="command-chip ${P(e.signals.some(p=>p.tone==="bad")?"bad":e.signals.length>0?"warn":"ok")}">
              신호 ${((u=e.summary)==null?void 0:u.signal_count)??e.signals.length}
            </span>
            <span class="command-chip">갱신 ${ee(e.generated_at)}</span>
          </div>
        </div>

        <${Ig} orchestra=${e} />
      </div>
    </section>
  `}const td="masc_dashboard_agent_name";function Rg(){var t,n,s;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(td))==null?void 0:s.trim())||"dashboard"}const Xa=$(Rg()),rn=$(""),Ta=$("운영 점검"),ln=$(""),Vn=$(""),Yn=$("2"),pn=$(""),xe=$("note"),Qn=$(""),Xn=$(""),Zn=$(""),es=$("2"),ts=$(""),Ia=$("운영자 중지 요청"),za=$(""),cn=$(""),Rs=$(null);function Lg(e){const t=e.trim()||"dashboard";Xa.value=t,localStorage.setItem(td,t)}function Ra(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Vi(e){switch((e??"").trim().toLowerCase()){case"judgment":return"상주 판단";case"fallback":return"보조 읽기 모델";default:return(e==null?void 0:e.trim())||"안내"}}function La(e){switch((e??"").trim().toLowerCase()){case"judgment":return"ok";case"fallback":return"warn";default:return"warn"}}function Yi(e){return e!=null&&e.enabled?e.refreshing?"갱신 중":e.judge_online?"온라인":e.last_error?"오류":"대기":"꺼짐"}function Pg(e){return e!=null&&e.enabled?e.judge_online?"ok":e.refreshing?"warn":"bad":"warn"}function Qi(e){return e!=null&&e.fresh_until?e.fresh_until:"갱신 기준 없음"}function Fr(e){return typeof e!="number"||!Number.isFinite(e)?"확인 없음":e<60?`${Math.round(e)}초 전`:e<3600?`${Math.round(e/60)}분 전`:`${Math.round(e/3600)}시간 전`}function mn(e){return typeof e=="string"?e.trim().toLowerCase():""}function Mg(e){var s;const t=mn(e.status);if(t==="paused")return"bad";if(t===""||t==="unknown")return"warn";const n=mn((s=e.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||t&&t!=="active"&&t!=="running"&&t!=="ended"?"warn":"ok"}function po(e){const t=mn(e.status);return t==="offline"||t==="inactive"||t==="error"?"bad":t===""||t==="unknown"||(e.context_ratio??0)>=.8||e.context_ratio==null||e.last_turn_ago_s==null||(e.last_turn_ago_s??0)>=3600?"warn":"ok"}function Kr(e){return e.some(t=>mn(t.severity)==="bad")?"bad":e.length>0?"warn":"ok"}function jg(e){return e.target_type==="team_session"}function Eg(e){return e.target_type==="keeper"}function Mt(e){switch(e){case"broadcast":return"방송";case"room_pause":return"방 일시정지";case"room_resume":return"방 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"team_worker_spawn_batch":return"세션 작업자 교체";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"키퍼 메시지";case"keeper_msg":return"키퍼 메시지";case"swarm_run_continue":return"스웜 실행 계속";case"swarm_run_rerun":return"스웜 실행 재실행";case"swarm_run_abandon":return"스웜 실행 포기";default:return(e==null?void 0:e.trim())||"액션"}}function dn(e){switch(e){case"room":return"방";case"team_session":return"세션";case"keeper":return"키퍼";case"swarm_run":return"스웜 실행";default:return(e==null?void 0:e.trim())||"대상"}}function Vt(e){switch(mn(e)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function Pa(e){return e?"확인 후 실행":"즉시 실행"}function Ng(e){switch(e){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";case"worker_spawn_batch":return"작업자 교체";default:return e}}function ve(e,t){if(!e)return null;const n=e[t];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function Dg(e){return!e||typeof e!="object"||Array.isArray(e)?null:e}function Og(e){if(!e)return"";const t=e.spawn_batch;return Ra(t!==void 0?t:e)}function nd(e){const t=Dg(e.payload);if(e.target_type==="room"){if(e.action_type==="broadcast"){rn.value=ve(t,"message")??e.summary;return}if(e.action_type==="task_inject"){ln.value=ve(t,"title")??"운영자 주입 작업",Vn.value=ve(t,"description")??e.summary,Yn.value=ve(t,"priority")??Yn.value;return}e.action_type==="room_pause"&&(Ta.value=ve(t,"reason")??e.summary);return}if(e.target_type==="team_session"){if(e.target_id&&(pn.value=e.target_id),e.action_type==="team_stop"){Ia.value=ve(t,"reason")??e.summary;return}xe.value=e.action_type==="team_worker_spawn_batch"?"worker_spawn_batch":e.action_type==="team_task_inject"?"task":e.action_type==="team_broadcast"?"broadcast":"note";const n=ve(t,"message");if(n&&(Qn.value=n),xe.value==="worker_spawn_batch"){ts.value=Og(t);return}xe.value==="task"&&(Xn.value=ve(t,"task_title")??ve(t,"title")??"운영자 주입 작업",Zn.value=ve(t,"task_description")??ve(t,"description")??e.summary,es.value=ve(t,"task_priority")??ve(t,"priority")??es.value);return}e.target_type==="keeper"&&(e.target_id&&(za.value=e.target_id),cn.value=ve(t,"message")??e.summary)}function qg(e){nd({action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.suggested_payload,summary:e.summary})}function wg(e){nd({action_type:e.action_type,target_type:e.target_type,target_id:e.target_id??null,payload:e.suggested_payload,summary:e.reason}),E("추천 액션 payload를 폼에 채웠습니다","success")}function Fg(e,t,n){return!e||!e.target_type||e.target_type==="room"?!0:e.target_type==="team_session"?!!e.target_id&&t.some(s=>s.session_id===e.target_id):e.target_type==="keeper"?!!e.target_id&&n.some(s=>s.name===e.target_id):!0}async function mt(e){const t=Xa.value.trim()||"dashboard";try{const n=await tc({actor:t,action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.payload});return n.confirm_required?E("확인 대기열에 올렸습니다","warning"):E(e.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return E(s,"error"),null}}async function Hr(){const e=rn.value.trim();if(!e)return;await mt({action_type:"broadcast",target_type:"room",payload:{message:e},successMessage:"방송을 보냈습니다"})&&(rn.value="")}async function Kg(){await mt({action_type:"room_pause",target_type:"room",payload:{reason:Ta.value.trim()||"운영 점검"},successMessage:"방 일시정지를 요청했습니다"})}async function sd(){await mt({action_type:"room_resume",target_type:"room",payload:{},successMessage:"방 재개를 요청했습니다"})}async function Hg(){const e=ln.value.trim();if(!e)return;await mt({action_type:"task_inject",target_type:"room",payload:{title:e,description:Vn.value.trim()||"개입 화면에서 주입",priority:Number.parseInt(Yn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(ln.value="",Vn.value="")}async function Ug(){var l;const e=he.value,t=pn.value||((l=e==null?void 0:e.sessions[0])==null?void 0:l.session_id)||"";if(!t){E("먼저 세션을 고르세요","warning");return}const n={};if(xe.value==="worker_spawn_batch"){const c=ts.value.trim();if(!c){E("spawn_batch JSON을 먼저 채우세요","warning");return}try{const p=JSON.parse(c);if(Array.isArray(p))n.spawn_batch=p;else if(p&&typeof p=="object"&&Array.isArray(p.spawn_batch))n.spawn_batch=p.spawn_batch;else{E("spawn_batch는 배열 또는 { spawn_batch: [...] } 형태여야 합니다","warning");return}}catch(p){const g=p instanceof Error?p.message:"spawn_batch JSON 파싱에 실패했습니다";E(g,"error");return}await mt({action_type:"team_worker_spawn_batch",target_type:"team_session",target_id:t,payload:n,successMessage:"작업자 교체 요청을 적용했습니다"})&&(ts.value="");return}const s=Qn.value.trim();s&&(n.message=s);let a="team_note";xe.value==="broadcast"?a="team_broadcast":xe.value==="task"&&(a="team_task_inject"),xe.value==="task"&&(n.task_title=Xn.value.trim()||"운영자 주입 작업",n.task_description=Zn.value.trim()||"개입 화면에서 주입",n.task_priority=Number.parseInt(es.value,10)||2),await mt({action_type:a,target_type:"team_session",target_id:t,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(Qn.value="",xe.value==="task"&&(Xn.value="",Zn.value=""))}async function Bg(){var n;const e=he.value,t=pn.value||((n=e==null?void 0:e.sessions[0])==null?void 0:n.session_id)||"";if(!t){E("먼저 세션을 고르세요","warning");return}await mt({action_type:"team_stop",target_type:"team_session",target_id:t,payload:{reason:Ia.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function Wg(){var a;const e=he.value,t=za.value||((a=e==null?void 0:e.keepers[0])==null?void 0:a.name)||"",n=cn.value.trim();if(!t){E("먼저 키퍼를 고르세요","warning");return}if(!n)return;await mt({action_type:"keeper_message",target_type:"keeper",target_id:t,payload:{message:n},successMessage:`${t}에게 메시지를 보냈습니다`})&&(cn.value="")}async function Ur(e,t="confirm"){const n=Xa.value.trim()||"dashboard";try{await nc(n,e,t),E(t==="deny"?"승인 대기를 거부했습니다":"확인 실행을 완료했습니다","success")}catch(s){const a=s instanceof Error?s.message:t==="deny"?"승인 대기 거부에 실패했습니다":"확인 실행에 실패했습니다";E(a,"error")}}function ad(e){switch(e){case"explicit":return"실제 관리 단위";case"hybrid":return"관리 단위 + 자동 보강";case"auto":return"자동 투영";default:return"출처 미상"}}function od(e){switch(e){case"explicit":return"ok";case"hybrid":return"warn";case"auto":return"warn";default:return"warn"}}function Gg(e){switch(e){case"explicit":return"지금 보이는 유닛은 실제로 정의된 지휘면 관리 단위입니다.";case"hybrid":return"일부는 실제 관리 단위이고, 비어 있는 부분은 실시간 에이전트 편성을 보고 자동 보강한 구조입니다.";case"auto":return"이 화면은 실시간 에이전트 편성을 지휘면 모양으로 자동 투영한 것입니다. 실제 명령 체계와 1:1로 같다고 보면 안 됩니다.";default:return"이 화면은 관리 토폴로지와 실효 토폴로지가 섞여 있을 수 있습니다."}}function Jg(e){const t=e.unit.source??"unknown";return t==="explicit"?e.active_operation_count&&e.active_operation_count>0?"실제 관리 단위이며 연결된 작전이 있습니다.":"실제 관리 단위이지만 현재 연결된 작전은 없습니다.":t==="hybrid"?e.active_operation_count&&e.active_operation_count>0?"관리 단위를 기반으로 자동 보강된 구조이며 일부 작전이 연결돼 있습니다.":"관리 단위를 기반으로 자동 보강된 구조이며 현재 실행 연결은 약합니다.":e.active_operation_count&&e.active_operation_count>0?"자동 생성된 구조이지만 이 노드에 연결된 작전 흔적은 있습니다.":"자동 생성된 구조이며 현재 실행 연결은 없습니다."}function id({node:e,depth:t=0}){const n=e.roster_live??0,s=e.roster_total??e.unit.roster.length,a=e.active_operation_count??0,i=e.unit.policy,l=e.unit.source??"unknown",c=a>0?`${a}개 작전 연결`:"실행 연결 없음";return o`
    <div class="command-tree-node depth-${Math.min(t,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${e.unit.label}</strong>
            <span class="command-chip">${Of(e.unit.kind)}</span>
            <span class="command-chip ${P(e.health)}">${e.health??"ok"}</span>
            <span class="command-chip ${od(l)}">${ad(l)}</span>
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
          <div class="command-card-sub">${Jg(e)}</div>
          ${e.reasons&&e.reasons.length>0?o`<div class="command-tag-row">
                ${e.reasons.map(u=>o`<span class="command-tag warn">${u}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${e.children.length>0?o`<div class="command-tree-children">
            ${e.children.map(u=>o`<${id} node=${u} depth=${t+1} />`)}
          </div>`:null}
    </div>
  `}function Vg({alert:e}){return o`
    <article class="command-alert ${P(e.severity)}">
      <div class="command-card-head">
        <strong>${e.title??e.kind??e.alert_id}</strong>
        <span class="command-chip ${P(e.severity)}">${e.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${e.scope_type??"범위"}:${e.scope_id??"정보 없음"}</span>
        <span>${ee(e.timestamp)}</span>
      </div>
      ${e.detail?o`<p>${e.detail}</p>`:null}
    </article>
  `}function Xi({event:e}){return o`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${e.event_type}</strong>
          <span class="command-chip">${e.source??"control_plane"}</span>
          <span class="command-chip">${ee(e.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${e.operation_id??e.trace_id}
          ${e.unit_id?` · ${e.unit_id}`:""}
          ${e.actor?` · ${e.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${Aa(e.detail)}</pre>
    </article>
  `}function Yg(){const e=Ue.value,t=e==null?void 0:e.topology,n=t==null?void 0:t.source,s=t==null?void 0:t.summary,a=(s==null?void 0:s.managed_unit_count)??0,i=(s==null?void 0:s.active_operation_count)??0;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${q} panelId="command.topology" compact=${!0} />
      </div>
      ${e?o`
            <div class="command-topology-explainer">
              <div class="command-tree-title-row">
                <span class="command-chip ${od(n)}">${ad(n)}</span>
                <span class="command-chip">관리 유닛 ${a}</span>
                <span class="command-chip ${i>0?"ok":"warn"}">활성 작전 ${i}</span>
              </div>
              <p>${Gg(n)}</p>
            </div>
          `:null}
      ${e&&e.topology.units.length>0?o`${e.topology.units.map(l=>o`<${id} node=${l} />`)}`:o`<div class="empty-state">지금은 실시간 에이전트나 관리 유닛 기준으로 그릴 지휘 계층이 없습니다.</div>`}
    </section>
  `}function Qg(){const e=Ue.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${q} panelId="command.alerts" compact=${!0} />
      </div>
      ${e&&e.alerts.alerts.length>0?o`<div class="command-card-stack">
            ${e.alerts.alerts.map(t=>o`<${Vg} alert=${t} />`)}
          </div>`:o`<div class="empty-state">지금 올라온 지휘면 경보는 없습니다.</div>`}
    </section>
  `}function Xg(){const e=Ue.value;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${q} panelId="command.trace" compact=${!0} />
      </div>
      ${e&&e.traces.events.length>0?o`<div class="command-trace-stack">
            ${e.traces.events.map(t=>o`<${Xi} event=${t} />`)}
          </div>`:o`<div class="empty-state">최근 트레이스 이벤트가 없습니다.</div>`}
    </section>
  `}function Zg(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e,null,2)}catch{return String(e)}}function e$(e,t){return(t==null?void 0:t.status)==="abandoned"||(e==null?void 0:e.recommended_kind)==="continue"?"warn":(e==null?void 0:e.recommended_kind)==="rerun"?"bad":"ok"}function t$(e){switch(e){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(e==null?void 0:e.trim())||"결정"}}function n$(e){return e?e.runtime_blocker?"막힘":e.provider_reachable?"준비됨":"확인 필요":"확인 필요"}function rd({swarm:e}){var f,v;const t=e.run_id,n=e.resolution_recommendation,s=e.run_resolution;if(!t||!n&&!s)return null;const a=Qc()??"dashboard",i=((f=he.value)==null?void 0:f.pending_confirms.find(h=>h.target_type==="swarm_run"&&h.target_id===t))??null,l=e$(n,s),c=((v=e.operation)==null?void 0:v.operation_id)??e.operation_id??void 0,u={run_id:t};c&&(u.operation_id=c),n!=null&&n.reason&&(u.reason=n.reason);const p=async h=>{await tc({actor:a,action_type:h,target_type:"swarm_run",target_id:t,payload:u})},g=async h=>{i&&await nc(a,i.confirm_token,h)};return o`
    <article class="command-guide-card ${P(l)}">
      <div class="command-guide-head">
        <strong>런 해석</strong>
        <span class="command-chip ${P(l)}">
          ${t$((s==null?void 0:s.status)??(n==null?void 0:n.recommended_kind)??null)}
        </span>
      </div>
      <p>
        ${(s==null?void 0:s.status)==="abandoned"?`이 run은 ${s.decided_by}가 ${ee(s.decided_at)}에 soft abandon 처리했습니다. ${s.reason}`:(n==null?void 0:n.reason)??"이 run에 대한 별도 resolution recommendation은 아직 없습니다."}
      </p>
      <div class="command-card-grid">
        <span>런</span><span>${t}</span>
        <span>근거 경로</span><span>${(n==null?void 0:n.provenance)??"recorded"}</span>
        <span>결정 엔진</span><span>${(n==null?void 0:n.decision_engine)??"operator_record"}</span>
        <span>권위성</span><span>${n!=null&&n.authoritative?"예":"아니오"}</span>
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
              ${i.preview?o`<pre class="command-trace-detail">${Zg(i.preview)}</pre>`:null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${()=>{g("confirm")}} disabled=${ae.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${()=>{g("deny")}} disabled=${ae.value}>취소</button>
              </div>
            </div>
          `:n?o`
              <div class="command-action-row">
                ${n.continue_available?o`<button class="control-btn ghost" onClick=${()=>{p("swarm_run_continue")}} disabled=${ae.value}>계속</button>`:null}
                ${n.rerun_available?o`<button class="control-btn" onClick=${()=>{p("swarm_run_rerun")}} disabled=${ae.value}>재실행</button>`:null}
                ${n.abandon_available?o`<button class="control-btn ghost" onClick=${()=>{p("swarm_run_abandon")}} disabled=${ae.value}>포기</button>`:null}
              </div>
            `:null}
    </article>
  `}function ld(e){return e.motion_state==="stalled"||e.hard_flags.some(t=>t.severity==="bad")?"bad":e.motion_state==="waiting"||e.hard_flags.some(t=>t.severity==="warn")?"warn":"ok"}function cd({lanes:e}){const t={moving:0,waiting:0,stalled:0,terminal:0};for(const a of e){const i=a.motion_state;i in t?t[i]++:t.waiting++}if(e.length===0)return null;const s=[{key:"moving",count:t.moving,color:"var(--ok)"},{key:"waiting",count:t.waiting,color:"var(--warn)"},{key:"stalled",count:t.stalled,color:"var(--bad)"},{key:"terminal",count:t.terminal,color:"#556"}];return o`
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
  `}function s$({total:e}){const n=Math.min(e,20),s=e>20?e-20:0,a=Array.from({length:n});return o`
    <div class="swarm-worker-grid">
      ${a.map(()=>o`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?o`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${e})</span>
    </div>
  `}function a$({lane:e}){const t=e.counts??{},n=ld(e),s=t.workers??0,a=t.operations??0,i=t.detachments??0,l=a+i,c=e.motion_state==="moving"?84:e.motion_state==="waiting"?58:e.motion_state==="terminal"?100:26;return o`
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
          <span class="command-chip">${ee(e.last_movement_at)}</span>
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
                <${s$} total=${s} />
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
              ${e.hard_flags.map(u=>o`<span class="command-chip ${P(u.severity)}">${u.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function dd({lanes:e}){const t=e.slice(0,4);return t.length===0?null:o`
    <div class="swarm-storyboard">
      ${t.map(n=>{const s=ld(n),a=n.counts.workers??0,i=n.counts.operations??0,l=n.counts.detachments??0;return o`
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
  `}function o$({event:e}){const t=e.timestamp?new Date(e.timestamp):null,n=t&&!isNaN(t.getTime())?t:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return o`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${P(e.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${e.title}</strong>
        <span class="swarm-event-kind">${e.kind}</span>
        ${e.detail?o`<div class="command-card-sub">${e.detail}</div>`:null}
      </div>
    </div>
  `}function i$({gap:e}){return o`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.summary}</strong>
          <div class="command-card-sub">${e.code} · lane ${e.lane_ids.join(", ")||"n/a"}</div>
        </div>
        <span class="command-chip ${P(e.severity)}">${e.count}</span>
      </div>
      ${e.why_it_matters?o`<p>${e.why_it_matters}</p>`:null}
      ${e.next_tool||e.next_step?o`
            <div class="command-card-grid">
              <span>다음 도구</span><span>${e.next_tool??"masc_observe_traces"}</span>
              <span>다음 확인</span><span>${e.next_step??"최근 trace를 확인합니다."}</span>
            </div>
          `:null}
    </article>
  `}function r$({swarm:e}){const t=e==null?void 0:e.narrative;return t?o`
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
  `:null}function l$({proof:e}){const t=(e==null?void 0:e.status)==="missing"?"warn":(e==null?void 0:e.pass)===!1?"bad":(e==null?void 0:e.pass)===!0?"ok":"warn";return o`
    <div class="command-guide-card ${P(t)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${P(t)}">${(e==null?void 0:e.status)??"missing"}</span>
        </div>
      ${e?o`
            <p>${e.status_summary??e.missing_reason??"아직 스웜 증거가 수집되지 않았습니다."}</p>
            <div class="command-card-grid">
              <span>소스</span><span>${e.source}</span>
              <span>상태 코드</span><span>${e.reason_code??"n/a"}</span>
              <span>런</span><span>${e.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${ee(e.captured_at)}</span>
              <span>통과</span><span>${e.pass==null?"n/a":e.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${e.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${e.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${e.workers.expected??"n/a"} 예상 · ${e.workers.done??"n/a"} 완료 · ${e.workers.final??"n/a"} 최종</span>
            </div>
            ${e.expected_artifact_dir?o`<div class="command-card-foot">expected ${e.expected_artifact_dir}</div>`:null}
            ${e.artifact_ref?o`<div class="command-card-foot">${e.artifact_ref}</div>`:null}
            ${e.missing_reason?o`<p>${e.missing_reason}</p>`:null}
          `:o`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function c$(){const e=fs(),t=us(O.value),n=Ff(t),s=e==null?void 0:e.swarm_status,a=e==null?void 0:e.swarm_proof,i=(s==null?void 0:s.lanes.filter(f=>f.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],u=s==null?void 0:s.overview,p=s==null?void 0:s.recommended_next_action,g=i.length<=1;return o`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${q} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?o`
            <${dd} lanes=${i} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(u==null?void 0:u.active_lanes)??0}</strong><small>${(u==null?void 0:u.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(u==null?void 0:u.stalled_lanes)??0}</strong><small>${(u==null?void 0:u.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${ee(u==null?void 0:u.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${ee(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(p==null?void 0:p.label)??"운영자 상태 확인"}</strong><small>${(p==null?void 0:p.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${i.length>0?o`<${cd} lanes=${i} />`:null}

            <div class="command-swarm-layout ${g?"compact":""}">
              <div class="command-card-stack">
                ${i.length>0?i.map(f=>o`<${a$} lane=${f} />`):o`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <${r$} swarm=${s} />

                <div class="command-guide-card highlight ${n==="recommendation"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>${(p==null?void 0:p.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(p==null?void 0:p.lane_id)??"전체"}</span>
                  </div>
                  <p>${(p==null?void 0:p.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(p==null?void 0:p.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${l$} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${P(l.some(f=>f.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?o`<div class="command-card-stack">${l.slice(0,4).map(f=>o`<${i$} gap=${f} />`)}</div>`:o`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?o`<div class="swarm-event-rail">${c.map(f=>o`<${o$} event=${f} />`)}</div>`:o`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:o`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function d$({item:e}){return o`
    <article class="command-guide-card ${P(e.status)}">
      <div class="command-guide-head">
        <strong>${e.title}</strong>
        <span class="command-chip ${P(e.status)}">${e.status}</span>
      </div>
      <p>${e.detail}</p>
      <div class="command-card-foot">Next tool: ${e.next_tool}</div>
    </article>
  `}function ud({blocker:e}){return o`
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
  `}function u$({worker:e}){return o`
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
      ${e.last_message?o`<div class="command-card-foot">${ee(e.last_message.timestamp)} · ${e.last_message.content}</div>`:null}
    </article>
  `}function p$(){var g,f,v,h,b,C,x,S,_,I,R,L,V,z,G,Q,se,M,J,A,X,K;const e=Dt.value,t=Zc(),n=Gi(),s=n$(e==null?void 0:e.provider),a=((g=e==null?void 0:e.provider)==null?void 0:g.configured_capacity)??0,i=((f=e==null?void 0:e.provider)==null?void 0:f.actual_slots)??((v=e==null?void 0:e.provider)==null?void 0:v.total_slots)??0,l=((h=e==null?void 0:e.provider)==null?void 0:h.expected_slots)??"n/a",c=((b=e==null?void 0:e.provider)==null?void 0:b.actual_ctx)??((C=e==null?void 0:e.provider)==null?void 0:C.ctx_per_slot)??0,u=((x=e==null?void 0:e.provider)==null?void 0:x.expected_ctx)??"n/a",p=((S=e==null?void 0:e.summary)==null?void 0:S.peak_hot_slots)??((_=e==null?void 0:e.provider)==null?void 0:_.peak_active_slots)??0;return o`
    <div class="command-section-stack">
      <${c$} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${q} panelId="command.swarm" compact=${!0} />
          </div>
          ${ga.value?o`<div class="empty-state">Loading swarm live state…</div>`:$a.value?o`<div class="empty-state error">${$a.value}</div>`:e?o`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${e.run_id??t??"swarm-live"}</strong><small>${e.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((I=e.summary)==null?void 0:I.joined_workers)??0}/${((R=e.summary)==null?void 0:R.expected_workers)??0}</strong><small>${((L=e.summary)==null?void 0:L.live_workers)??0}개 가동 · ${((V=e.summary)==null?void 0:V.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임 계약</span><strong>${s}</strong><small>설정 ${a||"n/a"} · 실제 ${i}/${l} · ctx ${c}/${u}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(z=e.summary)!=null&&z.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>최대 hot ${p} · ${((G=e.provider)==null?void 0:G.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(Q=e.summary)!=null&&Q.pass_end_to_end?"통과":"확인 필요"}</strong><small>${e.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((se=e.operation)==null?void 0:se.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((M=e.squad)==null?void 0:M.label)??"없음"}</span>
                      <span>실행체</span><span>${((J=e.detachment)==null?void 0:J.detachment_id)??"없음"}</span>
                      <span>목표 해석</span><span>target profile 기준, 달성 사실과 분리</span>
                      <span>예상 워커</span><span>${((A=e.summary)==null?void 0:A.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((X=e.summary)==null?void 0:X.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((K=e.provider)==null?void 0:K.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${e.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${e.truth_notes.length>0?o`<div class="command-tag-row">
                          ${e.truth_notes.map(te=>o`<span class="command-tag">${te}</span>`)}
                        </div>`:null}
                    <${rd} swarm=${e} />
                  `:o`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${q} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.checklist.length>0?o`<div class="command-card-stack">
                ${e.checklist.map(te=>o`<${d$} item=${te} />`)}
              </div>`:o`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${q} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.workers.length>0?o`<div class="command-card-stack">
                ${e.workers.map(te=>o`<${u$} worker=${te} />`)}
              </div>`:o`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${q} panelId="command.swarm" compact=${!0} />
          </div>
          ${e!=null&&e.provider?o`
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
                  <span>마지막 샘플</span><span>${e.provider.last_sample_at?ee(e.provider.last_sample_at):"정보 없음"}</span>
                  <span>런타임 막힘</span><span>${e.provider.runtime_blocker??"없음"}</span>
                  <span>검사 시각</span><span>${e.provider.checked_at?ee(e.provider.checked_at):"정보 없음"}</span>
                </div>
                <div class="command-card-sub">
                  target profile과 실제 런타임은 다를 수 있습니다. 설정 용량, 실제 슬롯, 최대 hot 슬롯을 분리해서 읽으세요.
                </div>
                ${e.provider.detail?o`<div class="command-card-sub">${e.provider.detail}</div>`:null}
                ${e.provider.timeline.length>0?o`<div class="command-trace-stack">
                      ${e.provider.timeline.slice(-12).map(te=>o`
                          <article class="command-trace-row">
                            <div class="command-trace-main">
                              <div class="command-trace-head">
                                <strong>hot ${te.active_slots}</strong>
                                <span class="command-chip">${ee(te.timestamp)}</span>
                              </div>
                            <div class="command-card-sub">slot ids ${te.active_slot_ids.join(", ")||"없음"}</div>
                            </div>
                          </article>
                      `)}
                    </div>`:o`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:o`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${q} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.blockers.length>0?o`<div class="command-card-stack">
                ${e.blockers.map(te=>o`<${ud} blocker=${te} />`)}
              </div>`:o`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(e==null?void 0:e.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${q} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.recent_messages.length>0?o`<div class="command-trace-stack">
                ${e.recent_messages.map(te=>o`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${te.from}</strong>
                        <span class="command-chip">${ee(te.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${te.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${te.content}</pre>
                  </article>
                `)}
              </div>`:o`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${q} panelId="command.trace" compact=${!0} />
          </div>
          ${e&&e.recent_trace_events.length>0?o`<div class="command-trace-stack">
                ${e.recent_trace_events.map(te=>o`<${Xi} event=${te} />`)}
              </div>`:o`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function m$(e){return e==="swarm"?"스웜 실시간":"세션 요약"}function _$(e){switch(e){case"current":return"현재 과업 일치";case"drift":return"과업 드리프트";case"claim":return"착수 흔적 있음";case"no-claim":return"착수 흔적 없음";case"done":return"완료 흔적 있음";case"no-done":return"완료 흔적 없음";case"final":return"최종 보고 있음";case"no-final":return"최종 보고 없음";case"turn":return"턴 기록 있음";case"silent":return"턴 기록 없음";case"noted":return"노트 기록 있음";default:return e.startsWith("empty:")?`빈 노트 ${e.slice(6)}회`:e.startsWith("turns:")?`턴 ${e.slice(6)}회`:e}}function v$(e){var n;const t=[e.current_task_matches_run?"current":"drift",e.claim_marker_seen?"claim":"no-claim",e.done_marker_seen?"done":"no-done",e.final_marker_seen?"final":"no-final"];return{key:`swarm:${e.name}`,name:e.name,role:e.role,lane:e.lane,status:e.status,source:"swarm",task:e.current_task??e.bound_task_title??e.bound_task_id??"할당 없음",heartbeat:e.heartbeat_age_sec!=null?`${Math.round(e.heartbeat_age_sec)}초`:e.heartbeat_fresh?"정상":"정보 없음",detail:[e.bound_task_status??null,e.detachment_member?"분견대 소속":null,e.squad_member?"분대 소속":null].filter(Boolean).join(" · ")||"스웜 실시간 카드",markers:t,note:((n=e.last_message)==null?void 0:n.content)??null}}function f$(e,t){const n=e.actor??e.spawn_role??`워커-${t+1}`,s=e.spawn_role??e.worker_class??e.spawn_agent??"워커",a=e.lane_id??e.capsule_mode??e.control_domain??"세션",i=[e.has_turn?"turn":"silent",e.empty_note_turn_count>0?`empty:${e.empty_note_turn_count}`:"noted",e.turn_count>0?`turns:${e.turn_count}`:"turns:0"];return{key:`session:${n}:${t}`,name:n,role:s,lane:a,status:e.status,source:"session",task:e.task_profile??e.runtime_pool??"세션 레인",heartbeat:e.last_turn_ts_iso?ee(e.last_turn_ts_iso):"정보 없음",detail:[e.spawn_agent??null,e.spawn_model??null,e.routing_confidence!=null?_s(e.routing_confidence):null].filter(Boolean).join(" · ")||"세션 요약 카드",markers:i,note:e.routing_reason??null}}function Br(e){return P(e.severity)}function g$({worker:e}){return o`
    <article class="command-card compact warroom-worker-card ${P(Gt(e.status))}">
      <div class="command-card-head">
        <div>
          <strong>${e.name}</strong>
          <div class="command-card-sub">${e.role} · ${e.lane}</div>
        </div>
        <span class="command-chip ${P(Gt(e.status))}">${xt(e.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>출처</span><span>${m$(e.source)}</span>
        <span>과업</span><span>${e.task}</span>
        <span>최근 신호</span><span>${e.heartbeat}</span>
        <span>근거</span><span>${e.detail}</span>
      </div>
      <div class="command-tag-row">
        ${e.markers.map(t=>o`<span class="command-tag">${_$(t)}</span>`)}
      </div>
      ${e.note?o`<div class="command-card-foot">${e.note}</div>`:null}
    </article>
  `}function et({label:e,surface:t,params:n={}}){return o`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(t){lt(t),ie("command",{...Wi(t),...n});return}ie("intervene")}}
    >
      ${e}
    </button>
  `}function $$(){var J,A,X,K,te,$t,H,Me,ht,yn,bn,gs,$s,hs,ys,bs,ks,xs,or,ir,rr;const e=fs(),t=Dt.value,n=he.value,s=Ke.value,a=Jf(),i=t!=null&&t.operation?((J=ds.value)==null?void 0:J.operations.find(Z=>{var Ss;return Z.operation.operation_id===((Ss=t.operation)==null?void 0:Ss.operation_id)}))??null:null,l=Wf(),c=(t==null?void 0:t.workers)??[],u=(s==null?void 0:s.worker_cards)??[],p=l&&c.length>0?c.map(v$):u.map(f$),g=l,f=((A=e==null?void 0:e.decisions.summary)==null?void 0:A.pending)??0,v=(n==null?void 0:n.pending_confirms)??[],h=l?(t==null?void 0:t.blockers)??[]:[],b=(s==null?void 0:s.recommended_actions)??[],C=(X=s==null?void 0:s.active_recommended_actions)!=null&&X.length?s.active_recommended_actions:b,x=s==null?void 0:s.active_summary,S=(s==null?void 0:s.active_guidance_layer)??"fallback",_=(s==null?void 0:s.resident_judge_runtime)??(n==null?void 0:n.resident_judge_runtime),I=(s==null?void 0:s.attention_items)??[],R=((K=t==null?void 0:t.recent_messages[0])==null?void 0:K.timestamp)??null,L=((te=t==null?void 0:t.recent_trace_events[0])==null?void 0:te.timestamp)??null,V=l?R??L??null:null,z=a==null?void 0:a.summary,G=(l?($t=t==null?void 0:t.summary)==null?void 0:$t.expected_workers:void 0)??(typeof(z==null?void 0:z.planned_worker_count)=="number"?z.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,Q=(l?(H=t==null?void 0:t.summary)==null?void 0:H.joined_workers:void 0)??(typeof(z==null?void 0:z.active_agent_count)=="number"?z.active_agent_count:void 0)??p.length,se=h.length>0||f>0||v.length>0?"warn":g||a?"ok":"warn",M=l?((Me=e==null?void 0:e.swarm_status)==null?void 0:Me.lanes.filter(Z=>Z.present))??[]:[];return oe(()=>{ge()},[]),oe(()=>{a!=null&&a.session_id&&Et(a.session_id)},[a==null?void 0:a.session_id,n,(ht=t==null?void 0:t.detachment)==null?void 0:ht.session_id]),!g&&!a?ga.value||Hn.value?o`<div class="empty-state">실시간 워룸 불러오는 중…</div>`:o`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">실시간 워룸</div>
          <${q} panelId="command.warroom" compact=${!0} />
        </div>
        <div class="command-warroom-empty-copy">
          <strong>지금 보이는 실시간 실행이 없습니다</strong>
          <p>활성 작전이나 팀 세션이 시작되면 이 화면이 자동으로 붙잡습니다.</p>
        </div>
        <div class="command-action-row">
          <${et} label="작전 보기" surface="operations" />
          <${et} label="스웜 보기" surface="swarm" />
          <${et} label="개입 열기" />
          <${et} label="제어 보기" surface="control" />
        </div>
      </section>
    `:o`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${P(se)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">실시간 워룸</span>
            <strong>${l?((yn=t==null?void 0:t.operation)==null?void 0:yn.objective)??(a==null?void 0:a.session_id)??"가동 중인 실행":(a==null?void 0:a.session_id)??"가동 중인 실행"}</strong>
            <div class="command-card-sub">
              ${l?((bn=t==null?void 0:t.operation)==null?void 0:bn.operation_id)??"작전 정보 없음":"세션 기준값"}
              ${a!=null&&a.session_id?` · 세션 ${a.session_id}`:""}
              ${l&&((gs=t==null?void 0:t.detachment)!=null&&gs.detachment_id)?` · 분견대 ${t.detachment.detachment_id}`:""}
            </div>
            ${x!=null&&x.summary?o`<div class="command-warroom-guidance ${La(S)}">
                  <strong>${Vi(S)}</strong>
                  <span>${x.summary}</span>
                </div>`:null}
          </div>
          <div class="command-action-row">
            <${et}
              label="스웜 상세"
              surface="swarm"
              params=${{...l&&(($s=t==null?void 0:t.operation)!=null&&$s.operation_id)?{operation_id:t.operation.operation_id}:{},...l&&(t!=null&&t.run_id)?{run_id:t.run_id}:{}}}
            />
            <${et} label="트레이스" surface="trace" />
            ${l&&i?o`<${et}
                  label="체인"
                  surface="chains"
                  params=${{operation:i.operation.operation_id}}
                />`:null}
            <${et} label="개입" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>워커</span>
            <strong>${Q??0}/${G??0}</strong>
            <small>${l?((hs=t==null?void 0:t.summary)==null?void 0:hs.completed_workers)??0:0} 완료 · ${p.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>런타임</span>
            <strong>${l?(ys=t==null?void 0:t.provider)!=null&&ys.runtime_blocker?"막힘":(bs=t==null?void 0:t.provider)!=null&&bs.provider_reachable?"준비됨":a?xt(a.status):"확인 필요":a?xt(a.status):"확인 필요"}</strong>
            <small>${l?`설정 ${((ks=t==null?void 0:t.provider)==null?void 0:ks.configured_capacity)??"n/a"} · 실제 ${((xs=t==null?void 0:t.provider)==null?void 0:xs.actual_slots)??((or=t==null?void 0:t.provider)==null?void 0:or.total_slots)??0} · hot ${((ir=t==null?void 0:t.summary)==null?void 0:ir.peak_hot_slots)??((rr=t==null?void 0:t.provider)==null?void 0:rr.peak_active_slots)??0}`:`세션 워커 ${(s==null?void 0:s.worker_cards.length)??0}`}</small>
          </div>
          <div class="monitor-stat-card ${P(h.length>0||f>0?"warn":"ok")}">
            <span>압력</span>
            <strong>${h.length+f+v.length}</strong>
            <small>막힘 ${h.length} · 승인 ${f} · 확인 ${v.length}</small>
          </div>
          <div class="monitor-stat-card ${P(La(S))}">
            <span>상주 판정기</span>
            <strong>${Yi(_)}</strong>
            <small>${Qi(x)}${_!=null&&_.model_used?` · ${_.model_used}`:""}</small>
          </div>
          <div class="monitor-stat-card">
            <span>마지막 신호</span>
            <strong>${ee(V)}</strong>
            <small>${R?"메시지":L?"트레이스":"대기 중"}</small>
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
            ${M.length>0?o`
                  <${dd} lanes=${M} />
                  <${cd} lanes=${M} />
                `:a?o`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${P(Gt(a.status))}">${xt(a.status)}</span>
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
              <${q} panelId="command.warroom" compact=${!0} />
            </div>
            ${p.length>0?o`<div class="command-card-stack">
                  ${p.map(Z=>o`<${g$} worker=${Z} />`)}
                </div>`:o`<div class="empty-state">활성 워커 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">상황 피드</div>
              <${q} panelId="command.warroom" compact=${!0} />
            </div>
            ${t&&t.recent_messages.length>0&&l?o`<div class="command-trace-stack">
                  ${t.recent_messages.map(Z=>o`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${Z.from}</strong>
                          <span class="command-chip">${ee(Z.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${Z.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${Z.content}</pre>
                    </article>
                  `)}
                </div>`:C.length>0||I.length>0?o`<div class="command-card-stack">
                    ${C.slice(0,4).map(Z=>o`
                      <article class="command-guide-card ${Br(Z)}">
                        <div class="command-guide-head">
                          <strong>${Z.action_type}</strong>
                          <span class="command-chip ${Br(Z)}">${Z.target_type}</span>
                        </div>
                        <p>${Z.reason}</p>
                      </article>
                    `)}
                    ${I.slice(0,3).map(Z=>o`
                      <article class="command-alert ${P(Z.severity)}">
                        <div class="command-card-head">
                          <strong>${Z.kind}</strong>
                          <span class="command-chip ${P(Z.severity)}">${Z.severity}</span>
                        </div>
                        <p>${Z.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?o`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((Z,Ss)=>o`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>세션 이벤트 ${Ss+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${Aa(Z)}</pre>
                        </article>
                      `)}
                    </div>`:o`<div class="empty-state">메시지나 주의 항목이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">트레이스 흐름</div>
              <${q} panelId="command.trace" compact=${!0} />
            </div>
            ${t&&t.recent_trace_events.length>0?o`<div class="command-trace-stack">
                  ${t.recent_trace_events.map(Z=>o`<${Xi} event=${Z} />`)}
                </div>`:o`<div class="empty-state">실행 범위 트레이스 이벤트가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">압력</div>
              <${q} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&t?o`<${rd} swarm=${t} />`:null}
              ${h.length>0?h.map(Z=>o`<${ud} blocker=${Z} />`):o`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
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
                        ${v.slice(0,3).map(Z=>o`<span class="command-tag">${Z.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
            </div>
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">현재 초점</div>
              <${q} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&(t!=null&&t.operation)?o`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${t.operation.objective}</strong>
                          <div class="command-card-sub">${t.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${P(Gt(t.operation.status))}">${xt(t.operation.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>유닛</span><span>${t.operation.assigned_unit_id}</span>
                        <span>트레이스</span><span>${t.operation.trace_id}</span>
                        <span>자율성</span><span>${t.operation.autonomy_level??"정보 없음"}</span>
                        <span>최근 갱신</span><span>${ee(t.operation.updated_at)}</span>
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
                        <span class="command-chip ${P(Gt(t.detachment.status))}">${xt(t.detachment.status??"active")}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>리더</span><span>${t.detachment.leader_id??"미지정"}</span>
                        <span>편성</span><span>${t.detachment.roster.length}</span>
                        <span>세션</span><span>${t.detachment.session_id??"연결 없음"}</span>
                        <span>하트비트</span><span>${Jc(t.detachment.heartbeat_deadline)}</span>
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
                        <span class="command-chip ${P(Gt(a.status))}">${xt(a.status)}</span>
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
  `}function Wr(e){switch((e??"").trim().toLowerCase()){case"active":return"가동 중";case"paused":return"일시정지";case"failed":return"실패";case"completed":case"done":return"완료";case"disconnected":return"끊김";case"preview":return"미리보기";case"captured":return"기록됨";default:return(e==null?void 0:e.trim())||"확인 필요"}}function h$({source:e}){const t=Pd(null),[n,s]=dl(null);return oe(()=>{let a=!1;const i=t.current;return i?(i.innerHTML="",s(null),(async()=>{try{const c=await Rf(),{svg:u}=await c.render(`command-chain-${zf()}`,e);if(a||!t.current)return;t.current.innerHTML=u}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid 렌더링에 실패했습니다")}})(),()=>{a=!0,t.current&&(t.current.innerHTML="")}):void 0},[e]),o`
    <div class="command-chain-graph-shell">
      ${n?o`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${t}></div>
    </div>
  `}function y$({overlay:e,selected:t,onSelect:n}){const s=e.operation.chain,a=e.runtime;return o`
    <button class="command-chain-item ${t?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${e.operation.objective}</strong>
          <div class="command-card-sub">${e.operation.operation_id}</div>
        </div>
        <span class="command-chip ${ct(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??e.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?o`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?o`<span class="command-tag ${ct(s==null?void 0:s.status)}">${_s(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${Vc(e.history)}</div>
    </button>
  `}function b$({item:e}){return o`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${e.chain_id??"알 수 없는 체인"}</strong>
        <span class="command-chip ${ct(e.event)}">${e.event}</span>
      </div>
      <div class="command-card-sub">${ee(e.timestamp)}</div>
      <div class="command-card-sub">${Vc(e)}</div>
    </article>
  `}function k$({node:e}){return o`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${e.id}</strong>
        <span class="command-chip ${ct(e.status)}">${e.status??"확인 필요"}</span>
      </div>
      <div class="command-card-sub">
        ${e.type??"노드"}
        ${typeof e.duration_ms=="number"?` · ${e.duration_ms}ms`:""}
      </div>
      ${e.error?o`<div class="command-card-sub error-text">${e.error}</div>`:null}
    </article>
  `}function x$({card:e}){const t=e.operation,n=`pause:${t.operation_id}`,s=`resume:${t.operation_id}`,a=`recall:${t.operation_id}`,i=t.chain,l=(i==null?void 0:i.run_id)??null;return o`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${t.objective}</strong>
          <div class="command-card-sub">${t.operation_id}</div>
        </div>
        <span class="command-chip ${P(t.status==="active"?"ok":t.status==="paused"?"warn":t.status==="failed"?"bad":"ok")}">${Wr(t.status)}</span>
      </div>
      <div class="command-card-grid">
        <span>유닛</span><span>${e.assigned_unit_label??t.assigned_unit_id}</span>
        <span>트레이스</span><span class="mono">${t.trace_id}</span>
        <span>자율성</span><span>${t.autonomy_level??"정보 없음"}</span>
        <span>예산 등급</span><span>${t.budget_class??"standard"}</span>
        <span>출처</span><span>${t.source??"managed"}</span>
        <span>최근 갱신</span><span>${ee(t.updated_at)}</span>
      </div>
      ${i?o`
            <div class="command-tag-row">
              <span class="command-tag">${i.kind}</span>
              <span class="command-tag ${ct(i.status)}">${Wr(i.status)}</span>
              ${i.chain_id?o`<span class="command-tag">${i.chain_id}</span>`:null}
              ${i.run_id?o`<span class="command-tag">실행 ${i.run_id}</span>`:null}
            </div>
          `:null}
      ${t.checkpoint_ref?o`<div class="command-card-foot">체크포인트 ${t.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{lt("swarm"),ie("command",{surface:"swarm",operation_id:t.operation_id,...l?{run_id:l}:{}})}}
        >
          스웜 실시간 보기
        </button>
        ${i?o`
              <button
                class="control-btn ghost"
                onClick=${()=>{Di(t.operation_id),lt("chains"),ie("command",{surface:"chains",operation:t.operation_id})}}
              >
                체인 열기
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="active"?o`
              <button class="control-btn ghost" disabled=${de(n)} onClick=${()=>dt(()=>nv(t.operation_id))}>
                ${de(n)?"일시정지 중…":"일시정지"}
              </button>
              <button class="control-btn ghost" disabled=${de(a)} onClick=${()=>dt(()=>av(t.operation_id))}>
                ${de(a)?"회수 중…":"회수"}
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="paused"?o`
              <button class="control-btn ghost" disabled=${de(s)} onClick=${()=>dt(()=>sv(t.operation_id))}>
                ${de(s)?"재개 중…":"재개"}
              </button>
            `:null}
      </div>
    </article>
  `}function S$({card:e}){var n;const t=e.detachment;return o`
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
        <span>진행 흔적</span><span>${ee(t.last_progress_at)}</span>
        <span>하트비트</span><span>${Jc(t.heartbeat_deadline)}</span>
        <span>최근 갱신</span><span>${ee(t.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${t.heartbeat_deadline?o`<span class="command-tag ${Tf(t.heartbeat_deadline)}">
              기한 ${t.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function C$(){const e=Ue.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">작전</div>
          <${q} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.operations.operations.length>0?o`<div class="command-card-stack">
              ${e.operations.operations.map(t=>o`<${x$} card=${t} />`)}
            </div>`:o`<div class="empty-state">관리형 또는 투영된 작전이 없습니다.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">분견대</div>
          <${q} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.detachments.detachments.length>0?o`<div class="command-card-stack">
              ${e.detachments.detachments.map(t=>o`<${S$} card=${t} />`)}
            </div>`:o`<div class="empty-state">투영된 분견대가 없습니다.</div>`}
      </section>
    </div>
  `}function A$(){var c,u,p,g,f,v,h,b,C,x,S,_,I,R,L,V;const e=ds.value,t=(e==null?void 0:e.operations)??[],n=sn.value,s=t.find(z=>z.operation.operation_id===n)??t[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,i=((u=Bn.value)==null?void 0:u.run)??(s==null?void 0:s.preview_run)??null,l=!((p=Bn.value)!=null&&p.run)&&!!(s!=null&&s.preview_run);return oe(()=>{a?ev(a):Z_()},[a]),o`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${q} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${ct(e==null?void 0:e.connection.status)}">
          <div class="command-guide-head">
            <strong>native chain 연결</strong>
            <span class="command-chip ${ct(e==null?void 0:e.connection.status)}">${(e==null?void 0:e.connection.status)??"disconnected"}</span>
          </div>
          <p>${(e==null?void 0:e.connection.message)??"체인 요약은 MASC 프록시를 통해 집계됩니다."}</p>
          <div class="command-card-grid">
            <span>기준 URL</span><span>${(e==null?void 0:e.connection.base_url)??"정보 없음"}</span>
            <span>연결된 작전</span><span>${((g=e==null?void 0:e.summary)==null?void 0:g.linked_operations)??0}</span>
            <span>활성 체인</span><span>${((f=e==null?void 0:e.summary)==null?void 0:f.active_chains)??0}</span>
            <span>최근 실패</span><span>${((v=e==null?void 0:e.summary)==null?void 0:v.recent_failures)??0}</span>
            <span>마지막 이벤트</span><span>${ee((h=e==null?void 0:e.summary)==null?void 0:h.last_history_event_at)}</span>
          </div>
        </article>

        ${ya.value?o`<div class="empty-state error">${ya.value}</div>`:null}

        ${ai.value&&!e?o`<div class="empty-state">체인 오버레이 불러오는 중…</div>`:t.length>0?o`
                <div class="command-chain-list">
                  ${t.map(z=>o`
                    <${y$}
                      overlay=${z}
                      selected=${(s==null?void 0:s.operation.operation_id)===z.operation.operation_id}
                      onSelect=${()=>Di(z.operation.operation_id)}
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
                  ${e.recent_history.slice(0,6).map(z=>o`<${b$} item=${z} />`)}
                </div>
              `:o`<div class="empty-state">최근 체인 이력이 없습니다.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">체인 상세</div>
          <${q} panelId="command.chains" compact=${!0} />
        </div>
        ${s?o`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${ct((b=s.operation.chain)==null?void 0:b.status)}">
                    ${((C=s.operation.chain)==null?void 0:C.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>종류</span><span>${((x=s.operation.chain)==null?void 0:x.kind)??"chain_dsl"}</span>
                  <span>체인 ID</span><span>${((S=s.operation.chain)==null?void 0:S.chain_id)??"goal-driven"}</span>
                  <span>실행 ID</span><span>${a??"아직 구체화되지 않음"}</span>
                  <span>진행률</span><span>${_s((_=s.runtime)==null?void 0:_.progress)}</span>
                  <span>경과</span><span>${In((I=s.runtime)==null?void 0:I.elapsed_sec)}</span>
                  <span>최근 갱신</span><span>${ee(((R=s.operation.chain)==null?void 0:R.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(L=s.operation.chain)!=null&&L.goal?o`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?o`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid 그래프</strong>
                        <span class="command-chip">${((V=s.operation.chain)==null?void 0:V.chain_id)??"graph"}</span>
                      </div>
                      <${h$} source=${s.mermaid} />
                    </div>
                  `:o`<div class="empty-state">기록된 Mermaid 그래프가 아직 없습니다.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>실행 상세</strong>
                  <span class="command-chip ${(i==null?void 0:i.success)===!1?"bad":"ok"}">
                    ${i?i.success===!1?"실패":l?"미리보기":"기록됨":"대기 중"}
                  </span>
                </div>
                ${ba.value?o`<div class="empty-state">실행 상세 불러오는 중…</div>`:Wn.value?o`<div class="empty-state error">${Wn.value}</div>`:i&&i.nodes.length>0?o`
                          <div class="command-card-grid">
                            <span>체인</span><span>${i.chain_id}</span>
                            <span>실행</span><span>${i.run_id??"미리보기만 있음"}</span>
                            <span>지속시간</span><span>${i.duration_ms!=null?`${i.duration_ms}ms`:"정보 없음"}</span>
                            <span>노드</span><span>${i.nodes.length}</span>
                          </div>
                          ${l?o`<div class="command-card-foot">run-store에 기록되기 전, 설계된 체인으로 만든 미리보기입니다.</div>`:null}
                          <div class="command-card-stack">
                            ${i.nodes.map(z=>o`<${k$} node=${z} />`)}
                          </div>
                        `:o`<div class="empty-state">이 작전의 run-store 상세는 아직 없습니다.</div>`}
              </div>
            `:o`<div class="empty-state">그래프와 실행 상세를 보려면 체인 기반 작전을 고르세요.</div>`}
      </section>
    </div>
  `}function T$(e){switch((e??"").trim().toLowerCase()){case"pending":return"대기 중";case"approved":return"승인됨";case"denied":return"거부됨";case"executed":return"실행됨";case"active":return"가동 중";default:return(e==null?void 0:e.trim())||"확인 필요"}}function I$({decision:e}){const t=`approve:${e.decision_id}`,n=`deny:${e.decision_id}`,s=e.source==="projected_operator";return o`
    <article class="command-card ${P(e.status)}">
      <div class="command-card-head">
        <div>
          <strong>${e.requested_action}</strong>
          <div class="command-card-sub">${e.scope_type}:${e.scope_id}</div>
        </div>
        <span class="command-chip ${P(e.status)}">${T$(e.status??"pending")}</span>
      </div>
      <div class="command-card-grid">
        <span>결정 ID</span><span>${e.decision_id}</span>
        <span>요청자</span><span>${e.requested_by??"알 수 없음"}</span>
        <span>출처</span><span>${e.source??"managed"}</span>
        <span>트레이스</span><span class="mono">${e.trace_id}</span>
        <span>생성 시각</span><span>${ee(e.created_at)}</span>
        <span>이유</span><span>${e.reason??"정보 없음"}</span>
      </div>
      ${e.status==="pending"&&!s?o`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${de(t)} onClick=${()=>dt(()=>iv(e.decision_id))}>
                ${de(t)?"승인 중…":"승인"}
              </button>
              <button class="control-btn ghost" disabled=${de(n)} onClick=${()=>dt(()=>rv(e.decision_id))}>
                ${de(n)?"거부 중…":"거부"}
              </button>
            </div>
          `:null}
      ${s?o`<div class="command-card-foot">레거시 operator 승인입니다. 실제 실행은 operator control에서 처리합니다.</div>`:null}
    </article>
  `}function z$({row:e}){var c,u,p;const t=e.unit,n=`freeze:${t.unit_id}`,s=`kill:${t.unit_id}`,a=!!((c=t.policy)!=null&&c.frozen),i=!!((u=t.policy)!=null&&u.kill_switch),l=Math.round((e.utilization??0)*100);return o`
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
        <span>자율성</span><span>${((p=t.policy)==null?void 0:p.autonomy_level)??"정보 없음"}</span>
        <span>동결</span><span>${a?"예":"아니오"}</span>
        <span>킬 스위치</span><span>${i?"켜짐":"꺼짐"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${de(n)} onClick=${()=>dt(()=>lv(t.unit_id,!a))}>
          ${de(n)?"적용 중…":a?"동결 해제":"동결"}
        </button>
        <button class="control-btn ghost" disabled=${de(s)} onClick=${()=>dt(()=>cv(t.unit_id,!i))}>
          ${de(s)?"적용 중…":i?"킬 스위치 해제":"킬 스위치 켜기"}
        </button>
      </div>
    </article>
  `}function R$(){const e=Ue.value;return o`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${q} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.decisions.decisions.length>0?o`<div class="command-card-stack">
              ${e.decisions.decisions.map(t=>o`<${I$} decision=${t} />`)}
            </div>`:o`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">유닛 제어</div>
          <${q} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.capacity.capacity.length>0?o`<div class="command-card-stack">
              ${e.capacity.capacity.map(t=>o`<${z$} row=${t} />`)}
            </div>`:o`<div class="empty-state">제어할 용량 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function L$(){return o`
    <div class="command-surface-tabs grouped">
      ${Pf.map(e=>o`
        <div class="command-tab-group" key=${e.id}>
          <span class="command-tab-group-label">${e.label}</span>
          <div class="command-tab-group-items">
            ${Yc.filter(t=>t.group===e.id).map(t=>o`
                <button
                  class="command-surface-tab ${Y.value===t.id?"active":""}"
                  onClick=${()=>{lt(t.id),ie("command",Wi(t.id))}}
                >
                  ${t.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function P$(){if(Y.value==="warroom")return o`<${$$} />`;if(Y.value==="summary")return o`<${hg} />`;if(Y.value==="orchestra")return o`<${zg} />`;if(Y.value==="swarm")return o`<${p$} />`;if(!Ue.value)return o`<${yg} />`;switch(Y.value){case"chains":return o`<${A$} />`;case"topology":return o`<${Yg} />`;case"alerts":return o`<${Qg} />`;case"trace":return o`<${Xg} />`;case"control":return o`<${R$} />`;case"operations":default:return o`<${C$} />`}}function M$(){return oe(()=>{Wt(),an(),tv(),nt(),Rt()},[]),oe(()=>{if(O.value.tab!=="command")return;const e=O.value.params.surface,t=O.value.params.operation,n=us(O.value);if(Mr(e))lt(e);else if(n){const s=Lc(n);Mr(s)&&lt(s)}else e||lt("warroom");t&&Di(t),(e==="swarm"||e==="warroom"||e==="orchestra"||Y.value==="warroom"||Y.value==="orchestra")&&nt(),(e==="orchestra"||Y.value==="orchestra")&&Rt(),(e==="warroom"||Y.value==="warroom")&&ge()},[O.value.tab,O.value.params.surface,O.value.params.operation,O.value.params.operation_id,O.value.params.run_id,O.value.params.source,O.value.params.action_type,O.value.params.target_type,O.value.params.target_id,O.value.params.focus_kind]),oe(()=>{let e=null;const t=()=>{e||(e=window.setTimeout(()=>{e=null,Wt(),an(),(Y.value==="swarm"||Y.value==="warroom"||Y.value==="orchestra")&&nt(),Y.value==="orchestra"&&Rt(),Y.value==="warroom"&&ge()},250))},n=new EventSource(Df()),s=jf.map(a=>{const i=()=>t();return n.addEventListener(a,i),{type:a,handler:i}});return n.onerror=()=>{t()},()=>{s.forEach(({type:a,handler:i})=>{n.removeEventListener(a,i)}),n.close(),e&&window.clearTimeout(e)}},[]),oe(()=>{const e=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const t=Y.value;t!=="swarm"&&t!=="warroom"&&t!=="orchestra"||(Wt(),nt(),t==="orchestra"&&Rt(),t==="warroom"&&ge())},5e3);return()=>{window.clearInterval(e)}},[]),o`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{dt(()=>ov())}}
            disabled=${de("dispatch:tick")}
          >
            ${de("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{It(),Wt(),an(),nt(),Y.value==="warroom"&&ge()}}
            disabled=${ua.value}
          >
            ${ua.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${ma.value?o`<div class="empty-state error">${ma.value}</div>`:null}
      ${va.value?o`<div class="empty-state error">${va.value}</div>`:null}
      <${Se} surfaceId="command" />
      <${Va} />
      <${_g} />
      ${Y.value==="warroom"?null:o`<${vg} />`}
      <${L$} />
      <${P$} />
    </section>
  `}function j$(){var x,S;const e=he.value,t=Li.value,n=(e==null?void 0:e.room)??{},s=(e==null?void 0:e.pending_confirms)??[],a=e==null?void 0:e.pending_confirm_summary,i=a?a.confirm_required_actions:((e==null?void 0:e.available_actions)??[]).filter(_=>_.confirm_required),l=((x=a==null?void 0:a.actor_filter)==null?void 0:x.trim())||null,c=(a==null?void 0:a.hidden_count)??0,u=(a==null?void 0:a.hidden_actors)??[],p=(e==null?void 0:e.recent_messages)??[],g=(t==null?void 0:t.recommended_actions)??[],f=(S=t==null?void 0:t.active_recommended_actions)!=null&&S.length?t.active_recommended_actions:g,v=t==null?void 0:t.active_summary,h=(t==null?void 0:t.resident_judge_runtime)??(e==null?void 0:e.resident_judge_runtime),b=(t==null?void 0:t.active_guidance_layer)??"fallback",C=p.slice(0,5);return o`
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
          <div class="ops-stat ${Pg(h)}">
            <span>Resident Judge</span>
            <strong>${Yi(h)}</strong>
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
            onInput=${_=>{rn.value=_.target.value}}
            onKeyDown=${_=>{_.key==="Enter"&&Hr()}}
            disabled=${ae.value}
          />
          <button class="control-btn" onClick=${()=>{Hr()}} disabled=${ae.value||rn.value.trim()===""}>
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
            onInput=${_=>{Ta.value=_.target.value}}
            disabled=${ae.value}
          />
          <button class="control-btn ghost" onClick=${()=>{Kg()}} disabled=${ae.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{sd()}} disabled=${ae.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${ln.value}
          onInput=${_=>{ln.value=_.target.value}}
          disabled=${ae.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${Vn.value}
          onInput=${_=>{Vn.value=_.target.value}}
          disabled=${ae.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${Yn.value}
            onChange=${_=>{Yn.value=_.target.value}}
            disabled=${ae.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{Hg()}} disabled=${ae.value||ln.value.trim()===""}>
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
        <article class="ops-guidance-card ${La(b)}">
          <div class="ops-guidance-head">
            <strong>${Vi(b)}</strong>
            <span>${(h==null?void 0:h.keeper_name)??(t==null?void 0:t.judgment_owner)??"judge 없음"}</span>
          </div>
          <div class="ops-guidance-body">
            ${(v==null?void 0:v.summary)??"현재 active guidance 요약이 없습니다. fallback queue만 표시합니다."}
          </div>
          <div class="ops-guidance-meta">
            <span>authoritative ${t!=null&&t.authoritative_judgment_available?"yes":"no"}</span>
            <span>${Qi(v)}</span>
            ${h!=null&&h.model_used?o`<span>${h.model_used}</span>`:null}
          </div>
        </article>
        ${Un.value&&!t?o`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:f.length>0?o`
          <div class="ops-log-list">
            ${f.map(_=>o`
              <article key=${`${_.action_type}:${_.target_type}:${_.target_id??"room"}`} class="ops-log-entry ${_.severity}">
                <div class="ops-log-head">
                  <strong>${Mt(_.action_type)}</strong>
                  <span>${dn(_.target_type)}${_.target_id?` · ${_.target_id}`:""}</span>
                  <span>${Pa(_.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${_.reason}</div>
                ${_.suggested_payload?o`
                  <div class="ops-confirmation-actions">
                    <button class="control-btn ghost" onClick=${()=>{wg(_)}} disabled=${ae.value}>
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
          <${q} panelId="intervene.pending_confirmations" compact=${!0} />
        </div>
        <p class="ops-context-note">
          ${l?`현재 actor ${l} 기준 queue를 읽습니다. 승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다.`:"승인 대기는 즉시 실행이 아니라 preview-confirm 경로를 타는 액션만 쌓입니다."}
        </p>
        ${i.length>0?o`
          <div class="ops-log-list">
            ${i.map(_=>o`
              <article key=${`${_.action_type}:${_.target_type}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${Mt(_.action_type)}</strong>
                  <span>${dn(_.target_type)}</span>
                  <span>${Pa(_.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${_.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}
        ${s.length>0?o`
          <div class="ops-confirmation-list">
            ${s.map(_=>o`
              <article key=${_.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${Mt(_.action_type)}</strong>
                  <span>${dn(_.target_type)}${_.target_id?` · ${_.target_id}`:""}</span>
                  <span>${_.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${_.preview?o`<pre class="ops-code-block compact">${Ra(_.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{Ur(_.confirm_token)}} disabled=${ae.value}>
                    실행
                  </button>
                  <button class="control-btn ghost" onClick=${()=>{Ur(_.confirm_token,"deny")}} disabled=${ae.value}>
                    거부
                  </button>
                  <span class="ops-token">${_.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        `:o`
          <div class="ops-empty">
            ${c>0&&l?`현재 선택한 actor(${l}) 기준 승인 대기는 0건입니다. 다른 actor 대기 ${c}건${u.length>0?` · ${u.join(", ")}`:""}`:"지금 승인 대기는 없습니다. 위 목록의 preview-confirm 액션을 먼저 만들어야 여기에 쌓입니다."}
          </div>
        `}
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 Room 메시지</div>
          <${q} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${C.length>0?o`
          <div class="ops-feed-list">
            ${C.map(_=>o`
              <article key=${_.seq??_.id??_.timestamp} class="ops-feed-item">
                <div class="ops-feed-meta">
                  <strong>${_.from}</strong>
                  <span>${_.timestamp}</span>
                </div>
                <div class="ops-feed-content">${_.content}</div>
              </article>
            `)}
          </div>
        `:o`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
      </section>
    </div>
  `}const wt=$(""),mo=$(!1),Ls=$(null);function E$(){var S;const e=he.value,t=Ke.value,n=(e==null?void 0:e.sessions)??[],s=((e==null?void 0:e.available_actions)??[]).filter(_=>_.target_type==="team_session"),a=n.find(_=>_.session_id===pn.value)??n[0]??null,i=t==null?void 0:t.active_summary,l=(t==null?void 0:t.active_guidance_layer)??"fallback",c=(t==null?void 0:t.resident_judge_runtime)??(e==null?void 0:e.resident_judge_runtime),u=(a==null?void 0:a.linked_autoresearch)??null,p=ae.value||mo.value,g=(S=t==null?void 0:t.active_recommended_actions)!=null&&S.length?t.active_recommended_actions:(t==null?void 0:t.recommended_actions)??[],f=async()=>{await ge(),a!=null&&a.session_id&&await Et(a.session_id)},v=async _=>{mo.value=!0,Ls.value=null;try{await _(),await f()}catch(I){Ls.value=I instanceof Error?I.message:"Autoresearch action failed"}finally{mo.value=!1}},h=async()=>{u!=null&&u.loop_id&&await v(()=>au(u.loop_id))},b=async()=>{if(!(u!=null&&u.loop_id)||!wt.value.trim())return;const _=wt.value.trim();await v(()=>ou(u.loop_id,_)),wt.value=""},C=async()=>{u!=null&&u.loop_id&&await v(()=>iu(u.loop_id))},x=async()=>{u!=null&&u.loop_id&&await v(()=>ru(u.loop_id,"dashboard stop request"))};return o`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${q} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?o`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(_=>{var I;return o`
            <button
              key=${_.session_id}
              class="ops-entity-card ${(a==null?void 0:a.session_id)===_.session_id?"active":""}"
              onClick=${()=>{pn.value=_.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${_.session_id}</strong>
                <span class="status-badge ${_.status??"idle"}">${Vt(_.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(_.progress_pct??0)}%</span>
                <span>${_.done_delta_total??0}건 완료</span>
                <span>${(I=_.team_health)!=null&&I.status?Vt(String(_.team_health.status)):"상태 확인 필요"}</span>
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
        ${a&&t?o`
          <article class="ops-guidance-card ${La(l)}">
            <div class="ops-guidance-head">
              <strong>${Vi(l)}</strong>
              <span>${Yi(c)}</span>
            </div>
            <div class="ops-guidance-body">
              ${(i==null?void 0:i.summary)??"현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다."}
            </div>
            <div class="ops-guidance-meta">
              <span>authoritative ${t.authoritative_judgment_available?"yes":"no"}</span>
              <span>${Qi(i)}</span>
              ${c!=null&&c.model_used?o`<span>${c.model_used}</span>`:null}
            </div>
          </article>
          ${g.length>0?o`
            <div class="ops-log-list">
              ${g.map(_=>o`
                <article key=${`${_.action_type}:${_.target_type}:${_.target_id??"session"}`} class="ops-log-entry ${_.severity}">
                  <div class="ops-log-head">
                    <strong>${Mt(_.action_type)}</strong>
                    <span>${dn(_.target_type)}${_.target_id?` · ${_.target_id}`:""}</span>
                  </div>
                  <div class="ops-log-body">${_.reason}</div>
                </article>
              `)}
            </div>
          `:null}
          <div class="ops-log-list">
            ${t.attention_items.length>0?t.attention_items.map(_=>o`
              <article key=${`${_.kind}:${_.target_id??"session"}`} class="ops-log-entry ${_.severity}">
                <div class="ops-log-head">
                  <strong>${_.kind}</strong>
                  <span>${dn(_.target_type)}${_.target_id?` · ${_.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${_.summary}</div>
              </article>
            `):o`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${t.worker_cards.length>0?t.worker_cards.map(_=>o`
              <article key=${`${_.actor??_.spawn_role??"worker"}:${_.spawn_agent??_.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${_.actor??_.spawn_role??"worker"}</strong>
                  <span>${Vt(_.status)}</span>
                  <span>${_.spawn_agent??_.runtime_pool??"runtime 확인 필요"}</span>
                </div>
                <div class="ops-log-body">
                  ${_.worker_class??"worker"}${_.lane_id?` · ${_.lane_id}`:""}${_.routing_reason?` · ${_.routing_reason}`:""}
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
          <${q} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>
        ${s.length>0?o`
          <div class="ops-log-list">
            ${s.map(_=>o`
              <article key=${_.action_type} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${Mt(_.action_type)}</strong>
                  <span>${Pa(_.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${_.description??"설명 확인 필요"}</div>
              </article>
            `)}
          </div>
        `:null}

        ${a?o`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${a.session_id}</div>
            <div class="ops-detail-meta">
              <span>상태: ${Vt(a.status)}</span>
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
              <pre class="ops-code-block compact">${Ra(a.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:o`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        ${u!=null&&u.loop_id?o`
          <label class="control-label" for="ops-autoresearch-hypothesis">Autoresearch 제어</label>
          <div class="control-row ops-split-row">
            <button class="control-btn ghost" onClick=${()=>{h()}} disabled=${p}>
              상태 새로고침
            </button>
            <button class="control-btn" onClick=${()=>{C()}} disabled=${p}>
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
            value=${wt.value}
            onInput=${_=>{wt.value=_.target.value}}
            disabled=${p}
          ></textarea>
          <div class="control-row ops-split-row">
            <button class="control-btn" onClick=${()=>{b()}} disabled=${p||!wt.value.trim()}>
              hypothesis 주입
            </button>
            <span class="ops-context-note">canonical control은 MCP tool이고, 이 화면은 그 상태를 읽고 이어서 제어합니다.</span>
          </div>
          ${Ls.value?o`<div class="ops-empty">${Ls.value}</div>`:null}
        `:null}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${xe.value}
            onChange=${_=>{xe.value=_.target.value}}
            disabled=${p||!a}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
            <option value="worker_spawn_batch">worker 교체</option>
          </select>
          <button class="control-btn" onClick=${()=>{Ug()}} disabled=${p||!a}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${Ng(xe.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${Qn.value}
          onInput=${_=>{Qn.value=_.target.value}}
          disabled=${p||!a}
        ></textarea>

        ${xe.value==="task"?o`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${Xn.value}
            onInput=${_=>{Xn.value=_.target.value}}
            disabled=${p||!a}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${Zn.value}
            onInput=${_=>{Zn.value=_.target.value}}
            disabled=${p||!a}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${es.value}
            onChange=${_=>{es.value=_.target.value}}
            disabled=${p||!a}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
        `:xe.value==="worker_spawn_batch"?o`
          <textarea
            class="control-textarea"
            rows=${6}
            placeholder='spawn_batch JSON, 예: [{"spawn_agent":"llama","spawn_prompt":"...", "spawn_role":"replacement"}]'
            value=${ts.value}
            onInput=${_=>{ts.value=_.target.value}}
            disabled=${p||!a}
          ></textarea>
        `:null}

        <div class="control-row ops-split-row">
          <input
            class="control-input"
            type="text"
            value=${Ia.value}
            onInput=${_=>{Ia.value=_.target.value}}
            disabled=${p||!a}
          />
          <button class="control-btn ghost" onClick=${()=>{Bg()}} disabled=${p||!a}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function N$(){var i;const e=he.value,t=(e==null?void 0:e.keepers)??[],n=(e==null?void 0:e.persistent_agents)??[],s=(e==null?void 0:e.available_actions)??[],a=t.find(l=>l.name===za.value)??t[0]??null;return o`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${q} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${t.length===0?o`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:t.map(l=>o`
            <button
              key=${l.name}
              class="ops-entity-card ${(a==null?void 0:a.name)===l.name?"active":""}"
              onClick=${()=>{za.value=l.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${l.name}</strong>
                <span class="status-badge ${l.status??"idle"}">${Vt(l.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${l.model??"model 확인 필요"}</span>
                <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${Fr(l.last_turn_ago_s)}</span>
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
                    <span class="status-badge ${l.status??"idle"}">${Vt(l.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>persistent</span>
                    <span>${l.model??"model 확인 필요"}</span>
                    <span>${Fr(l.last_turn_ago_s)}</span>
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
          disabled=${ae.value||!a}
        ></textarea>
        <div class="control-row">
          <button class="control-btn" onClick=${()=>{Wg()}} disabled=${ae.value||!a||cn.value.trim()===""}>
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
          ${s.length?s.map(l=>o`
                <article key=${`${l.action_type}:${l.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${Mt(l.action_type)}</strong>
                    <span>${dn(l.target_type)}</span>
                    <span>${Pa(l.confirm_required)}</span>
                  </div>
                  <div class="ops-log-body">${l.description??"설명이 아직 없습니다."}</div>
                </article>
              `):o`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 개입 로그</div>
          <${q} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <div class="ops-log-list">
          ${ra.value.length===0?o`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:ra.value.map(l=>o`
            <article key=${l.id} class="ops-log-entry ${l.outcome}">
              <div class="ops-log-head">
                <strong>${Mt(l.action_type)}</strong>
                <span>${l.target_label}</span>
                <span>${l.at}</span>
              </div>
              <div class="ops-log-body">${l.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function D$(){var R,L,V;const e=he.value,t=O.value.tab==="intervene"?us(O.value):null,n=Li.value,s=(e==null?void 0:e.room)??{},a=(e==null?void 0:e.sessions)??[],i=(e==null?void 0:e.keepers)??[],l=(e==null?void 0:e.pending_confirms)??[],c=e==null?void 0:e.pending_confirm_summary,u=(c==null?void 0:c.visible_count)??l.length,p=(c==null?void 0:c.total_count)??l.length,g=(c==null?void 0:c.hidden_count)??0,f=((R=c==null?void 0:c.actor_filter)==null?void 0:R.trim())||null,v=a.find(z=>z.session_id===pn.value)??a[0]??null,h=(n==null?void 0:n.attention_items)??[],b=h.filter(jg),C=h.filter(Eg),x=a.filter(z=>Mg(z)!=="ok"),S=i.filter(z=>po(z)!=="ok"),_=Fg(t,a,i);oe(()=>{jt()},[]),oe(()=>{if(O.value.tab!=="intervene"){Rs.value=null;return}if(!t){Rs.value=null;return}Rs.value!==t.id&&(Rs.value=t.id,qg(t))},[O.value.tab,O.value.params.source,O.value.params.action_type,O.value.params.target_type,O.value.params.target_id,O.value.params.focus_kind,t==null?void 0:t.id]),oe(()=>{const z=(v==null?void 0:v.session_id)??null;Et(z)},[v==null?void 0:v.session_id]);const I=[{key:"room",label:"방 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:g>0?`${u}/${p}`:u,detail:u>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":g>0&&f?`현재 개입 ID(${f}) 기준으로는 비어 있고, 다른 개입 ID 대기 ${g}건이 있습니다`:"지금 막혀 있는 확인 대기는 없습니다",tone:p>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:b.length>0?b.length:a.length,detail:b.length>0?((L=b[0])==null?void 0:L.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 팀 세션이 없습니다":"세션 쪽 긴급 주의 신호는 현재 없습니다",tone:b.length>0?Kr(b):a.length===0?"warn":x.some(z=>mn(z.status)==="paused")?"bad":x.length>0?"warn":"ok"},{key:"keeper",label:"키퍼 압력",value:C.length>0?C.length:S.length,detail:C.length>0?((V=C[0])==null?void 0:V.summary)??"직접 메시지나 상태 점검이 필요한 키퍼가 있습니다":S.length>0?"오래됐거나 오프라인이거나 텔레메트리가 비는 키퍼가 보입니다":"지금은 키퍼 쪽이 비교적 안정적입니다",tone:C.length>0?Kr(C):S.some(z=>po(z)==="bad")?"bad":S.length>0?"warn":"ok"}];return o`
    <section class="ops-view">
      <${Se} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">개입</div>
            <${q} panelId="intervene.action_studio" compact=${!0} />
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
            value=${Xa.value}
            onInput=${z=>Lg(z.target.value)}
          />
            <button
              class="control-btn ghost"
              onClick=${()=>{It(),ge(),jt(),Et((v==null?void 0:v.session_id)??null)}}
            disabled=${Hn.value||ae.value}
          >
            ${Hn.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${pt.value?o`<section class="ops-banner error">${pt.value}</section>`:null}
      ${un.value?o`<section class="ops-banner error">${un.value}</section>`:null}
      <${Va} />
      ${t?o`
        <section class="ops-banner ${_?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${t.source_label}</strong>
            <span>${Ya(t.action_type)}</span>
            <span>${Fi(t)}</span>
          </div>
          <div class="ops-handoff-body">${t.summary}</div>
          ${t.payload_preview?o`<div class="ops-handoff-preview">${t.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${_?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const z=[];if((u>0||g>0)&&z.push({label:g>0?`확인 대기 ${u}/${p}건 확인`:`확인 대기 ${u}건 처리`,desc:g>0&&f?`현재 개입 ID(${f}) 기준으로 보이는 대기열을 먼저 확인합니다`:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:u>0?"bad":"warn",onClick:()=>{const G=document.querySelector(".ops-pending-section");G==null||G.scrollIntoView({behavior:"smooth"})}}),s.paused&&z.push({label:"방 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void sd()}),S.length>0){const G=S.filter(Q=>po(Q)==="bad");z.push({label:G.length>0?`오프라인 키퍼 ${G.length}개`:`점검이 필요한 키퍼 ${S.length}개`,desc:G.length>0?"메시지를 보내거나 상태를 확인하세요":"오래됐거나 텔레메트리가 비어 있습니다",tone:G.length>0?"bad":"warn",onClick:()=>{const Q=document.querySelector(".ops-keeper-section");Q==null||Q.scrollIntoView({behavior:"smooth"})}})}return z.length===0?null:o`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${z.slice(0,3).map(G=>o`
                <button class="ops-action-guide-item ${G.tone}" onClick=${G.onClick}>
                  <strong>${G.label}</strong>
                  <span>${G.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `})()}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${q} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 방인지, 세션인지, 키퍼인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${I.map(z=>o`
            <div key=${z.key} class="ops-priority-card ${z.tone}">
              <span class="ops-priority-label">${z.label}</span>
              <strong>${z.value}</strong>
              <div class="ops-priority-detail">${z.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${j$} />
        <${E$} />
        <${N$} />
      </div>
    </section>
  `}function O$({text:e}){if(!e)return null;const t=q$(e);return o`<div class="markdown-content">${t}</div>`}function q$(e){const t=e.split(`
`),n=[];let s=0;for(;s<t.length;){const a=t[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),u=[];for(s++;s<t.length&&!t[s].startsWith(l);)u.push(t[s]),s++;s++,n.push(o`<pre><code class=${c?`language-${c}`:""}>${u.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<t.length&&!t[s].includes("</think>");)l.push(t[s]),s++;if(s<t.length){const p=t[s].replace("</think>","").trim();p&&l.push(p),s++}const u=l.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${_o(u)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<t.length&&t[s].startsWith("> ");)l.push(t[s].slice(2)),s++;n.push(o`<blockquote>${_o(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<t.length;){const l=t[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;i.push(l),s++}i.length>0&&n.push(o`<p>${_o(i.join(`
`))}</p>`)}return n}function _o(e){const t=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(e))!==null;){if(a.index>s&&t.push(e.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);t.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);t.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);t.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&t.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<e.length&&t.push(e.slice(s)),t.length>0?t:[e]}const pd=[{id:"recent",label:"최신순"},{id:"hot",label:"인기순"},{id:"trending",label:"급상승"},{id:"updated",label:"최근 갱신"},{id:"discussed",label:"토론 많은 순"}],Ys=$(null),Qs=$([]),_n=$(!1),Pt=$(null),jn=$(""),En=$(!1),Yt=$(!0),Zi=20,Kt=$(Zi);function w$(){var t,n;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const F$=$(w$());function K$(e){const t=e.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return t?t.length>180?`${t.slice(0,177)}...`:t:"미리보기 없음"}function Gr(e){return e.updated_at!==e.created_at}function H$(e){if(e.post_kind)return e.post_kind==="automation";const t=(e.hearth??"").toLowerCase();return e.visibility!=="internal"||!e.expires_at||!t?!1:!!(t.startsWith("mdal")||t.includes("harness"))}function U$(e){return e==="lodge-system"||e==="team-session"}function ns(e){return e.post_kind?e.post_kind:U$(e.author)?"system":H$(e)?"automation":"human"}function md(e){const t=[],n=[];let s=0;return e.forEach(a=>{const i=ns(a);if(!(i==="system"&&At.value)){if(i==="automation"&&Yt.value){s+=1;return}if(i==="human"){t.push(a);return}n.push(a)}}),{human:t,operations:n,hiddenAutomation:s}}function B$(e){if(!e.expires_at)return null;const t=Date.parse(e.expires_at);return Number.isFinite(t)?t<=Date.now()?o`<span class="board-meta-chip">만료됨</span>`:o`<span class="board-meta-chip">만료까지 <${W} timestamp=${e.expires_at} /></span>`:null}async function er(e){Pt.value=e,Ys.value=null,Qs.value=[],_n.value=!0;try{const t=await Ou(e);if(Pt.value!==e)return;Ys.value={id:t.id,author:t.author,title:t.title,body:t.body,content:t.content,meta:t.meta,tags:t.tags,votes:t.votes,vote_balance:t.vote_balance,comment_count:t.comment_count,created_at:t.created_at,updated_at:t.updated_at,post_kind:t.post_kind,flair:t.flair,hearth:t.hearth,visibility:t.visibility,expires_at:t.expires_at,hearth_count:t.hearth_count},Qs.value=t.comments??[]}catch{Pt.value===e&&(Ys.value=null,Qs.value=[])}finally{Pt.value===e&&(_n.value=!1)}}async function Jr(e){const t=jn.value.trim();if(t){En.value=!0;try{await qu(e,F$.value,t),jn.value="",E("댓글을 등록했습니다","success"),await er(e),it()}catch{E("댓글 등록에 실패했습니다","error")}finally{En.value=!1}}}function W$(){const e=Fn.value,t=Yt.value?"자동화 글 숨김":"자동화 글 표시 중";return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${pd.map(n=>o`
          <button
            class="board-sort-btn ${e===n.id?"active":""}"
            onClick=${()=>{Fn.value=n.id,Kt.value=Zi,it()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Yt.value?"is-active":""}"
          onClick=${()=>{Yt.value=!Yt.value}}
        >
          ${t}
        </button>
        <button
          class="control-btn ghost ${At.value?"is-active":""}"
          onClick=${()=>{At.value=!At.value,it()}}
        >
          ${At.value?"시스템 글 숨김":"시스템 글 표시 중"}
        </button>
        <button class="control-btn ghost" onClick=${it} disabled=${Kn.value}>
          ${Kn.value?"새로고침 중...":"새로고침"}
        </button>
      </div>
    </div>
  `}function vo(){var s;const e=((s=pd.find(a=>a.id===Fn.value))==null?void 0:s.label)??Fn.value,t=md(Ga.value),n=t.human.length+t.operations.length;return o`
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
        <strong>${Yt.value?`자동화 ${t.hiddenAutomation}건 숨김`:"분리된 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">시스템 글 정책</span>
        <strong>${At.value?"시스템 글 숨김":"시스템 레인 표시"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">최근 갱신</span>
        <strong>${Yo.value?o`<${W} timestamp=${Yo.value} />`:"아직 불러오지 않음"}</strong>
      </div>
    </div>
  `}function Vr({post:e}){const t=async(n,s)=>{s.stopPropagation();try{await Tl(e.id,n),it()}catch{E("투표에 실패했습니다","error")}};return o`
    <div class="board-post" onClick=${()=>Dd(e.id)}>
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
                ${Gr(e)?o`<span class="board-meta-chip">수정됨</span>`:null}
                ${ns(e)!=="human"?o`<span class="board-meta-chip">${ns(e)}</span>`:null}
                ${e.hearth?o`<span class="board-meta-chip">${e.hearth}</span>`:null}
                ${e.visibility?o`<span class="board-meta-chip">${e.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>작성자 ${e.author}</span>
            <span><${W} timestamp=${e.created_at} /></span>
            ${Gr(e)?o`<span>수정 <${W} timestamp=${e.updated_at} /></span>`:null}
            <span>댓글 ${e.comment_count}</span>
            <span>투표 ${e.votes??0}</span>
          </div>
        </div>
        <div class="post-snippet">${K$(e.body)}</div>
      </div>
    </div>
  `}function G$({comments:e}){return e.length===0?o`<div class="empty-state" style="font-size:13px">아직 댓글이 없습니다</div>`:o`
    <div class="comment-thread">
      ${e.map(t=>o`
        <div key=${t.id} class="board-comment">
          <span class="comment-author">${t.author}</span>
          <span class="comment-time"><${W} timestamp=${t.created_at} /></span>
          <div class="comment-text">${t.content}</div>
        </div>
      `)}
    </div>
  `}function J$({postId:e}){return o`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="댓글 추가..."
        value=${jn.value}
        onInput=${t=>{jn.value=t.target.value}}
        onKeyDown=${t=>{t.key==="Enter"&&Jr(e)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${En.value}
      />
      <button
        onClick=${()=>Jr(e)}
        disabled=${En.value||jn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${En.value?"...":"등록"}
      </button>
    </div>
  `}function V$({post:e}){Pt.value!==e.id&&!_n.value&&er(e.id);const t=async n=>{try{await Tl(e.id,n),it()}catch{E("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>ie("memory")}>← 메모리로 돌아가기</button>
      <${T} title=${e.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${O$} text=${e.body} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${e.author}</span>
            <${W} timestamp=${e.created_at} />
            <span>${e.votes??0} votes</span>
          </div>
          ${e.hearth||e.visibility||e.expires_at?o`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${e.hearth?o`<span class="board-meta-chip">${e.hearth}</span>`:null}
                  ${e.visibility?o`<span class="board-meta-chip">${e.visibility}</span>`:null}
                  ${ns(e)!=="human"?o`<span class="board-meta-chip">${ns(e)}</span>`:null}
                  ${B$(e)}
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

      <${T} title="댓글" semanticId="memory.feed">
        ${_n.value?o`<div class="loading-indicator">댓글 불러오는 중...</div>`:o`<${G$} comments=${Qs.value} />`}
        <${J$} postId=${e.id} />
      <//>
    </div>
  `}function Y$(){const e=md(Ga.value),t=[...e.human,...e.operations],n=O.value.params.post??null,s=n?t.find(a=>a.id===n)??(Pt.value===n?Ys.value:null):null;return n&&!s&&Pt.value!==n&&!_n.value&&er(n),n?s?o`
          <${Se} surfaceId="memory" />
          <${vo} />
          <${V$} post=${s} />
        `:o`
          <div>
            <${Se} surfaceId="memory" />
            <${vo} />
            <button class="back-btn" onClick=${()=>ie("memory")}>← 메모리로 돌아가기</button>
            ${_n.value?o`<div class="loading-indicator">글 불러오는 중...</div>`:o`<div class="empty-state">글을 찾지 못했습니다</div>`}
          </div>
        `:o`
    <div>
      <${Se} surfaceId="memory" />
      <${vo} />
      <${W$} />
      ${Kn.value?o`<div class="loading-indicator">메모리 피드 불러오는 중...</div>`:t.length===0?o`<div class="empty-state">지금은 남아 있는 메모리 글이 없습니다</div>`:o`
              <${T} title="사람이 쓴 글" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${e.human.slice(0,Kt.value).map(a=>o`<${Vr} key=${a.id} post=${a} />`)}
                </div>
                ${e.human.length>Kt.value?o`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{Kt.value=Kt.value+Zi}}
                    >
                      더 보기 (${e.human.length-Kt.value}개 남음)
                    </button>
                  </div>
                `:null}
              <//>
              ${e.operations.length>0?o`
                    <${T} title="자동화 · 시스템" class="section" semanticId="memory.feed">
                      <div class="board-post-list">
                        ${e.operations.map(a=>o`<${Vr} key=${a.id} post=${a} />`)}
                      </div>
                    <//>
                  `:null}
            `}
    </div>
  `}function Q$({ratio:e,size:t=40,stroke:n=4}){if(e==null)return null;const s=(t-n)/2,a=t/2,i=2*Math.PI*s,l=i*((100-e*100)/100);let c="mitosis-safe";return e>=.8?c="mitosis-critical":e>=.5&&(c="mitosis-warn"),o`
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
  `}const St=$(null),Be=$(null),We=$(null);function vn(e){return e==="bad"||e==="critical"||e==="offline"?"bad":e==="warn"||e==="paused"||e==="blocked"||e==="interrupted"?"warn":"ok"}function Ma(e){switch((e??"").trim().toLowerCase()){case"ok":case"healthy":case"green":return"안정";case"active":case"running":return"진행 중";case"paused":return"일시정지";case"blocked":return"막힘";case"interrupted":return"중단됨";case"warn":return"주의";case"bad":case"critical":return"위험";case"offline":return"오프라인";case"idle":case"quiet":return"대기";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function X$(e){return e==="session"?"세션":"작전"}function Z$(e){return typeof e!="number"||Number.isNaN(e)?"—":`${Math.round(e*100)}%`}function eh(e){return e?vt.value.find(t=>t.name===e||t.agent_name===e)??null:null}function th(e){switch(e){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function nh(e){switch(e){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function sh(e){switch(e){case"acted":return"행동";case"passed":return"통과";case"skipped":return"건너뜀";case"failed":return"실패";default:return e}}function ah(e){switch(e){case"post":return"post";case"comment":return"comment";case"vote":return"vote";case"none":case null:case void 0:return"none";default:return e}}function ja(e,t="없음"){const n=e??[];return n.length===0?t:n.length<=3?n.join(", "):`${n.slice(0,3).join(", ")} +${n.length-3}`}function Yr(e){if(!e)return;const t=hv({targetType:e.target_type,targetId:e.target_id,focusKind:e.focus_kind,operationId:e.operation_id??null,commandSurface:e.command_surface??null,sourceLabel:"실행 진단",summary:e.label});zc(t),ie(e.surface,e.surface==="intervene"?Rc(t):Pc(t))}function Le({label:e,value:t,color:n,caption:s}){return o`
    <div class="stat-card">
      <div class="stat-label">${e}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${t}</div>
      ${s?o`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function tr({intervene:e,command:t}){return o`
    <div class="control-row">
      ${e?o`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),Yr(e)}}
            >
              ${e.label}
            </button>
          `:null}
      ${t?o`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),Yr(t)}}
            >
              ${t.label}
            </button>
          `:null}
    </div>
  `}function oh({item:e,selected:t}){return o`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{St.value=t?null:e.id,Be.value=null,We.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.kind==="session"?e.target_id:e.linked_session_id??e.target_id}</div>
          <div class="mission-card-title">${e.summary}</div>
        </div>
        <span class="command-chip ${vn(e.severity)}">${Ma(e.status??e.severity)}</span>
      </div>
      <div class="mission-card-meta">
        <span>${X$(e.kind)}</span>
        ${e.linked_operation_id?o`<span>연결 작전 · ${e.linked_operation_id}</span>`:null}
        ${e.last_seen_at?o`<span><${W} timestamp=${e.last_seen_at} /></span>`:null}
      </div>
      <${tr} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function ih({brief:e,selected:t}){return o`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.session-card"
      onClick=${()=>{Be.value=t?null:e.session_id,We.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          <div class="mission-card-title">${e.goal}</div>
        </div>
        <span class="command-chip ${vn(e.health??e.status)}">${Ma(e.status)}</span>
      </div>
      <div class="mission-card-meta">
        <span>건강도 · ${Ma(e.health??"ok")}</span>
        ${e.linked_operation_id?o`<span>연결 작전 · ${e.linked_operation_id}</span>`:null}
        ${e.last_activity_at?o`<span><${W} timestamp=${e.last_activity_at} /></span>`:null}
      </div>
      ${e.runtime_blocker?o`<div class="mission-card-detail">${e.runtime_blocker}</div>`:e.last_activity_summary?o`<div class="mission-card-detail">${e.last_activity_summary}</div>`:null}
      ${e.worker_gap_summary?o`<div class="monitor-footnote">${e.worker_gap_summary}</div>`:null}
      <${tr} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function rh({brief:e,selected:t}){return o`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.operation-card"
      onClick=${()=>{We.value=t?null:e.operation_id,Be.value=e.linked_session_id??null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.operation_id}${e.assigned_unit_label?` · ${e.assigned_unit_label}`:""}</div>
          <div class="mission-card-title">${e.objective}</div>
        </div>
        <span class="command-chip ${vn(e.blocker_summary?"warn":e.status)}">${Ma(e.status)}</span>
      </div>
      <div class="mission-card-meta">
        ${e.stage?o`<span>단계 · ${e.stage}</span>`:null}
        ${e.linked_session_id?o`<span>세션 · ${e.linked_session_id}</span>`:null}
        ${e.updated_at?o`<span><${W} timestamp=${e.updated_at} /></span>`:null}
      </div>
      ${e.blocker_summary?o`<div class="mission-card-detail">${e.blocker_summary}</div>`:null}
      ${e.next_tool?o`<div class="monitor-footnote">다음 도구 · ${e.next_tool}</div>`:null}
      <${tr} command=${e.command_handoff} />
    </button>
  `}function lh({tick:e}){return e?o`
    <div class="monitor-nested-card">
      <div class="stats-grid">
        <${Le} label="checked" value=${e.checked??0} color="#22d3ee" />
        <${Le} label="acted" value=${e.acted??0} color="#4ade80" />
        <${Le} label="passed" value=${e.passed??0} color="#94a3b8" />
        <${Le} label="skipped" value=${e.skipped??0} color="#fbbf24" />
        <${Le} label="failed" value=${e.failed??0} color="#fb7185" />
      </div>
      <div class="monitor-meta">
        ${e.last_tick_at?o`<span>마지막 tick <${W} timestamp=${e.last_tick_at} /></span>`:o`<span>마지막 tick 없음</span>`}
        ${e.last_skip_reason?o`<span>대표 skip 이유 · ${e.last_skip_reason}</span>`:null}
      </div>
      ${e.activity_report?o`<div class="monitor-footnote">${e.activity_report}</div>`:null}
    </div>
  `:o`<div class="empty-state">최근 lodge tick 기록이 없습니다.</div>`}function ch({row:e}){return o`
    <button
      class="monitor-row ${vn(e.outcome==="failed"?"bad":e.outcome==="skipped"?"warn":"ok")}"
      data-testid="execution.lodge-checkin-card"
      onClick=${()=>ms(e.agent_name)}
    >
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.agent_name}</span>
            ${e.worker_name?o`<span class="monitor-sub">worker · ${e.worker_name}</span>`:null}
          </div>
          <div class="monitor-note">${e.reason??e.summary??"이유가 기록되지 않았습니다."}</div>
        </div>
        <span class="monitor-pill ${vn(e.outcome==="failed"?"bad":e.outcome==="skipped"?"warn":"ok")}">${sh(e.outcome)}</span>
      </div>
      <div class="monitor-meta">
        <span>trigger · ${e.trigger??"unknown"}</span>
        ${e.checked_at?o`<span><${W} timestamp=${e.checked_at} /></span>`:null}
        <span>action · ${ah(e.action_kind)}</span>
        <span>allow ${e.allowed_tool_names.length}</span>
        <span>used ${e.used_tool_names.length}</span>
      </div>
      ${e.summary&&e.summary!==e.reason?o`<div class="monitor-focus">${e.summary}</div>`:null}
      <div class="monitor-footnote">
        허용 도구: ${ja(e.allowed_tool_names)} · 사용 도구: ${ja(e.used_tool_names)}
      </div>
      ${e.failure_reason||e.decision_reason?o`<div class="monitor-footnote">
            ${e.failure_reason?`실패 이유: ${e.failure_reason}`:`판단 이유: ${e.decision_reason}`}
          </div>`:null}
    </button>
  `}function Qr({row:e,testId:t}){return o`
    <button class="monitor-row ${e.tone} state-${e.state}" data-testid=${t} onClick=${()=>ms(e.name)}>
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
        <span class="monitor-pill ${e.tone} state-${e.state}">${th(e.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_signal_at?o`<span>신호 <${W} timestamp=${e.last_signal_at} /></span>`:o`<span>최근 신호 없음</span>`}
        <span>${(e.active_task_count??0)>0?`활성 작업 ${e.active_task_count}개`:"활성 작업 없음"}</span>
        ${e.related_session_id?o`<span>세션 · ${e.related_session_id}</span>`:null}
        ${e.related_operation_id?o`<span>작전 · ${e.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.recent_output_preview&&e.recent_output_preview!==e.focus?o`<div class="monitor-footnote">최근 상세: ${e.recent_output_preview}</div>`:null}
    </button>
  `}function dh({row:e}){var n,s;const t=()=>{const a=eh(e.name);a&&Wc(a)};return o`
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
        <${Q$} ratio=${e.context_ratio??0} size=${34} stroke=${4} />
        <${gt} status=${e.status??"unknown"} />
        <span class="monitor-pill ${e.tone}">${nh(e.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_signal_at?o`<span>최근 활동 <${W} timestamp=${e.last_signal_at} /></span>`:o`<span>최근 활동 없음</span>`}
        ${e.related_session_id?o`<span>세션 · ${e.related_session_id}</span>`:null}
        ${e.continuity?o`<span>${e.continuity}</span>`:null}
        ${e.lifecycle?o`<span>생애주기 ${e.lifecycle}</span>`:null}
        <span>컨텍스트 ${Z$(e.context_ratio)}</span>
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.recent_output_preview||e.continuity_summary?o`<div class="monitor-footnote">${e.recent_output_preview??e.continuity_summary}</div>`:null}
      ${e.skill_route_summary||e.tool_audit_source?o`<div class="monitor-footnote">
            ${e.skill_route_summary?`route · ${e.skill_route_summary}`:""}
            ${e.tool_audit_source?`${e.skill_route_summary?" · ":""}audit · ${e.tool_audit_source}`:""}
            ${e.tool_audit_at?o` · <${W} timestamp=${e.tool_audit_at} />`:null}
          </div>`:null}
      ${(((n=e.recent_tool_names)==null?void 0:n.length)??0)>0||(((s=e.allowed_tool_names)==null?void 0:s.length)??0)>0?o`<div class="monitor-footnote">
            recent tools: ${ja(e.recent_tool_names)} · allowed: ${ja(e.allowed_tool_names)}
          </div>`:null}
    </button>
  `}function uh(){const e=Pl.value,t=Ml.value,n=jl.value,s=El.value,a=Nl.value,i=Dl.value,l=Si.value,c=Ci.value,u=Ol.value;St.value&&!t.some(_=>_.id===St.value)&&(St.value=null),Be.value&&!n.some(_=>_.session_id===Be.value)&&(Be.value=null),We.value&&!s.some(_=>_.operation_id===We.value)&&(We.value=null);const p=St.value?t.find(_=>_.id===St.value)??null:null,g=Be.value?Be.value:p?p.kind==="session"?p.target_id:p.linked_session_id??null:null,f=We.value?We.value:p?p.kind==="operation"?p.target_id:p.linked_operation_id??null:null,v=g?n.filter(_=>_.session_id===g):f?n.filter(_=>_.linked_operation_id===f):n,h=f?s.filter(_=>_.operation_id===f):g?s.filter(_=>{var I;return _.linked_session_id===g||_.operation_id===((I=v[0])==null?void 0:I.linked_operation_id)}):s,b=g||f?a.filter(_=>(g?_.related_session_id===g:!1)||(f?_.related_operation_id===f:!1)):a,C=g?c.filter(_=>_.related_session_id===g||_.tone!=="ok"):c,x=g?l.filter(_=>v.some(I=>I.member_names.includes(_.agent_name))):l,S=g||f?u.filter(_=>(g?_.related_session_id===g:!1)||(f?_.related_operation_id===f:!1)||_.tone!=="ok"):u;return o`
    <div class="agents-monitor">
      <${Se} surfaceId="execution" />
      <${Va} />
      <div class="stats-grid">
        <${Le} label="활성 세션" value=${(e==null?void 0:e.active_sessions)??n.length} color="#4ade80" caption="실행 관점 세션 수" />
        <${Le} label="막힌 세션" value=${(e==null?void 0:e.blocked_sessions)??n.filter(_=>vn(_.health??_.status)!=="ok").length} color="#fbbf24" caption="개입이 필요한 세션 수" />
        <${Le} label="활성 작전" value=${(e==null?void 0:e.active_operations)??s.length} color="#22d3ee" caption="지휘 평면 작전 수" />
        <${Le} label="막힌 작전" value=${(e==null?void 0:e.blocked_operations)??s.filter(_=>_.blocker_summary).length} color="#fb7185" caption="원인 확인이 필요한 작전 수" />
        <${Le} label="인력 경고" value=${(e==null?void 0:e.worker_alerts)??a.filter(_=>_.tone!=="ok").length} color="#fb7185" caption="지원 인력 압박" />
        <${Le} label="연속성 경고" value=${(e==null?void 0:e.continuity_alerts)??c.filter(_=>_.tone!=="ok").length} color="#fb7185" caption="키퍼 연속성 압박" />
      </div>

      <${T}
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
          ${t.length===0?o`<div class="empty-state">지금은 막힌 실행이 없습니다.</div>`:t.map(_=>o`<${oh} key=${_.id} item=${_} selected=${St.value===_.id} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${T}
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
            ${v.length===0?o`<div class="empty-state">선택된 실행과 연결된 세션이 없습니다.</div>`:v.map(_=>o`<${ih} key=${_.session_id} brief=${_} selected=${Be.value===_.session_id} />`)}
          </div>
        <//>

        <${T}
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
            ${h.length===0?o`<div class="empty-state">선택된 실행과 연결된 작전이 없습니다.</div>`:h.map(_=>o`<${rh} key=${_.operation_id} brief=${_} selected=${We.value===_.operation_id} />`)}
          </div>
        <//>

        <${T}
          title="Lodge Check-ins"
          class="section"
          semanticId="execution.lodge"
          testId="execution.lodge-checkins"
        >
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Lodge Check-ins</h2>
            <p class="monitor-subheadline">최근 lodge tick에서 누가 무엇을 허용받았고, 실제로 어떻게 행동했는지 먼저 보여줍니다.</p>
          </div>
          <${lh} tick=${i} />
          <div class="monitor-list">
            ${x.length===0?o`<div class="empty-state">최근 lodge check-in 기록이 없습니다.</div>`:x.map(_=>o`<${ch} key=${`${_.agent_name}-${_.checked_at??_.outcome}`} row=${_} />`)}
          </div>
        <//>

        <${T}
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
            ${b.length===0?o`<div class="empty-state">연결된 작업자가 없습니다.</div>`:b.map(_=>o`<${Qr} key=${_.name} row=${_} testId="execution.worker-card" />`)}
          </div>
        <//>

        <${T}
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
            ${C.length===0?o`<div class="empty-state">지금은 연속성 경고가 없습니다.</div>`:C.map(_=>o`<${dh} key=${_.name} row=${_} />`)}
          </div>
        <//>

        <${T}
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
            ${S.length===0?o`<div class="empty-state">지금은 오프라인 작업자가 없습니다.</div>`:S.map(_=>o`<${Qr} key=${_.name} row=${_} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const ci=$(null),di=$(null),Nn=$(!1);async function Xr(){if(!Nn.value){Nn.value=!0,di.value=null;try{ci.value=await hu()}catch(e){di.value=e instanceof Error?e.message:String(e)}finally{Nn.value=!1}}}function ph(e){switch(e){case"essential":return"badge-essential";case"standard":return"badge-standard";default:return"badge-full"}}function mh({items:e,maxCount:t}){return e.length===0?o`<p class="muted">No tool calls recorded yet.</p>`:o`
    <div class="tool-bar-chart">
      ${e.map(n=>{const s=t>0?n.call_count/t*100:0;return o`
          <div class="tool-bar-row" key=${n.name}>
            <span class="tool-bar-name">${n.name}</span>
            <span class="tool-bar-tier ${ph(n.tier)}">${n.tier}</span>
            <div class="tool-bar-track">
              <div class="tool-bar-fill" style=${{width:`${s}%`}} />
            </div>
            <span class="tool-bar-count">${n.call_count}</span>
          </div>
        `})}
    </div>
  `}function _h({dist:e}){const t=e.full,n=t>0?(e.essential/t*100).toFixed(1):"0",s=t>0?(e.standard/t*100).toFixed(1):"0",a=t-e.standard,i=t>0?(a/t*100).toFixed(1):"0";return o`
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
  `}function vh(){const e=ci.value,t=Nn.value,n=di.value;return oe(()=>{!ci.value&&!Nn.value&&Xr()},[]),o`
    <div class="tool-metrics">
      <div class="tool-metrics-header">
        <h3 class="tool-metrics-title">Tool Usage</h3>
        <button
          class="control-btn ghost"
          onClick=${()=>void Xr()}
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
            <${_h} dist=${e.tier_distribution} />
          </div>
          <div class="tool-metrics-section">
            <h4>Top 20 Tools</h4>
            <${mh}
              items=${e.top_20}
              maxCount=${e.top_20.length>0?e.top_20[0].call_count:0}
            />
          </div>
        </div>
      `:t?null:o`
        <p class="muted">Click Load to fetch tool usage statistics.</p>
      `}
    </div>
  `}const ui=$(null),pi=$(null),Dn=$(!1),Cn=$(""),Ps=$("all"),fo=$(!1),go=$(!1),$o=$(!0),ho=$(!0);async function Zr(){if(!Dn.value){Dn.value=!0,pi.value=null;try{ui.value=await yu()}catch(e){pi.value=e instanceof Error?e.message:String(e)}finally{Dn.value=!1}}}function fh(e,t){const n=t.trim().toLowerCase();return n?[e.name,e.description,e.category,e.required_permission??"",e.visibility,e.lifecycle,e.implementationStatus,e.tier,e.canonicalName??"",e.replacement??"",e.reason??"",...e.doc_refs,...e.prompt_hints].join(" ").toLowerCase().includes(n):!0}function Ms(e,t="default"){return o`
    <span
      style=${{fontSize:"11px",color:t==="ok"?"#7dd3fc":t==="warn"?"#fbbf24":"#cbd5e1",background:t==="ok"?"rgba(14, 165, 233, 0.18)":t==="warn"?"rgba(245, 158, 11, 0.18)":"rgba(148, 163, 184, 0.16)",borderRadius:"999px",padding:"2px 8px"}}
    >
      ${e}
    </span>
  `}function gh({item:e}){return o`
    <article class="tool-inventory-row">
      <div class="tool-inventory-head">
        <div>
          <div class="tool-inventory-name">${e.name}</div>
          <div class="tool-inventory-desc">${e.description}</div>
        </div>
        <div class="tool-inventory-badges">
          ${Ms(e.tier,e.tier==="essential"?"ok":e.tier==="standard"?"warn":"default")}
          ${Ms(e.visibility)}
          ${Ms(e.lifecycle,e.lifecycle==="deprecated"?"warn":"default")}
          ${Ms(e.implementationStatus)}
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
  `}function $h(){const e=ui.value,t=Dn.value,n=pi.value,s=(e==null?void 0:e.tool_inventory.tools)??[],a=(e==null?void 0:e.tool_usage)??null;oe(()=>{!ui.value&&!Dn.value&&Zr()},[]),oe(()=>{var h;if(O.value.tab!=="tools")return;const v=(h=O.value.params.q)==null?void 0:h.trim();v&&v!==Cn.value&&(Cn.value=v)},[O.value.tab,O.value.params.q]);const i=Array.from(new Set(s.map(v=>v.category))).sort((v,h)=>v.localeCompare(h)),l=s.filter(v=>!(!fh(v,Cn.value)||Ps.value!=="all"&&v.category!==Ps.value||fo.value&&!v.enabled_in_current_mode||go.value&&!v.direct_call_allowed||!$o.value&&v.visibility==="hidden"||!ho.value&&v.lifecycle==="deprecated")),c=s.length,u=s.filter(v=>v.enabled_in_current_mode).length,p=s.filter(v=>v.visibility==="hidden").length,g=s.filter(v=>v.lifecycle==="deprecated").length,f=s.filter(v=>v.direct_call_allowed).length;return o`
    <div>
      <${T} title="System Tool Inventory" class="section">
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
            <span class="stat-value">${u}</span>
            <span class="stat-label">Mode enabled</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${p}</span>
            <span class="stat-label">Hidden</span>
          </div>
          <div class="tool-inventory-stat">
            <span class="stat-value">${g}</span>
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
            value=${Ps.value}
            onChange=${v=>{Ps.value=v.target.value}}
          >
            <option value="all">All categories</option>
            ${i.map(v=>o`<option value=${v}>${v}</option>`)}
          </select>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${fo.value}
              onChange=${v=>{fo.value=v.target.checked}}
            />
            <span>Enabled only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${go.value}
              onChange=${v=>{go.value=v.target.checked}}
            />
            <span>Direct-call only</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${$o.value}
              onChange=${v=>{$o.value=v.target.checked}}
            />
            <span>Show hidden</span>
          </label>
          <label class="tool-inventory-toggle">
            <input
              type="checkbox"
              checked=${ho.value}
              onChange=${v=>{ho.value=v.target.checked}}
            />
            <span>Show deprecated</span>
          </label>
          <button class="control-btn ghost" onClick=${()=>{Zr()}} disabled=${t}>
            ${t?"Refreshing…":"Refresh inventory"}
          </button>
        </div>

        ${n?o`<div class="tool-metrics-error">${n}</div>`:null}

        <div class="tool-inventory-list">
          ${l.length>0?l.map(v=>o`<${gh} key=${v.name} item=${v} />`):o`<div class="empty-state">No tools matched the current filters.</div>`}
        </div>
      <//>

      <${T} title="Tool Usage" class="section">
        ${a?o`
              <div class="tool-inventory-usage-hint">
                Registered ${a.registered_count} · Distinct called ${a.distinct_tools_called} · Never called ${a.never_called_count}
              </div>
            `:null}
        <${vh} />
      <//>
    </div>
  `}const Ea=$("all"),Na=$("all"),mi=$(new Set);function hh(e){const t=new Set(mi.value);t.has(e)?t.delete(e):t.add(e),mi.value=t}const _d=Pe(()=>{let e=Zt.value;return Ea.value!=="all"&&(e=e.filter(t=>t.horizon===Ea.value)),Na.value!=="all"&&(e=e.filter(t=>t.status===Na.value)),e}),yh=Pe(()=>{const e={short:[],mid:[],long:[]};for(const t of _d.value){const n=e[t.horizon];n&&n.push(t)}return e}),bh=Pe(()=>{const e=Array.from(wl.value.values());return e.sort((t,n)=>t.status==="running"&&n.status!=="running"?-1:n.status==="running"&&t.status!=="running"?1:t.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&t.status!=="interrupted"?1:n.elapsed_seconds-t.elapsed_seconds),e});function kh(e){return"★".repeat(Math.min(e,5))+"☆".repeat(Math.max(0,5-e))}function nr(e){switch(e){case"short":return"단기";case"mid":return"중기";case"long":return"장기";default:return e}}function Xs(e){switch(e){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function xh(e){return e<60?`${Math.round(e)}s`:e<3600?`${Math.floor(e/60)}m ${Math.round(e%60)}s`:`${Math.floor(e/3600)}h ${Math.floor(e%3600/60)}m`}function el(e){return e.toFixed(4)}function tl(e){const t=e.current_metric-e.baseline_metric;return`${t>=0?"+":""}${t.toFixed(4)}`}function Sh(e){switch(e){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function Ch(e){switch(e){case"active":return"진행 중";case"completed":return"완료";case"paused":return"일시정지";default:return"전체"}}function nl(e,t){return(e.priority??4)-(t.priority??4)}function Ah(e,t){const n=e.updated_at??e.created_at??"";return(t.updated_at??t.created_at??"").localeCompare(n)}function Th(e,t){return e.length<=t?e:e.slice(0,t)+"..."}function Ih({goal:e}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Xs(e.horizon)}">
            ${nr(e.horizon)}
          </span>
          <span class="goal-title">${e.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${e.priority}">${kh(e.priority)}</span>
          ${e.metric?o`<span class="goal-metric">${e.metric}${e.target_value?` → ${e.target_value}`:""}</span>`:null}
          ${e.due_date?o`<span class="goal-due">Due: <${W} timestamp=${e.due_date} /></span>`:null}
        </div>
        ${e.last_review_note?o`
          <div class="goal-review-note">${e.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${gt} status=${e.status} />
        <div class="goal-updated">
          <${W} timestamp=${e.updated_at} />
        </div>
      </div>
    </div>
  `}function yo({horizon:e,items:t}){if(t.length===0)return null;const n=[...t].sort((s,a)=>a.priority-s.priority);return o`
    <${T} title="${nr(e)} 목표 (${t.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>o`<${Ih} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function zh(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">범위</label>
        ${["all","short","mid","long"].map(e=>o`
          <button
            class="goal-filter-btn ${Ea.value===e?"active":""}"
            onClick=${()=>{Ea.value=e}}
          >
            ${e==="all"?"전체":nr(e)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">상태</label>
        ${["all","active","completed","paused"].map(e=>o`
          <button
            class="goal-filter-btn ${Na.value===e?"active":""}"
            onClick=${()=>{Na.value=e}}
          >
            ${Ch(e)}
          </button>
        `)}
      </div>
    </div>
  `}function Rh(){const e=Zt.value,t=e.filter(a=>a.status==="active").length,n=e.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of e)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${Xs("short")}">${s.short}</div>
        <div class="goal-summary-label">단기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Xs("mid")}">${s.mid}</div>
        <div class="goal-summary-label">중기</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Xs("long")}">${s.long}</div>
        <div class="goal-summary-label">장기</div>
      </div>
    </div>
  `}function Lh({loop:e}){const t=e.history[0],n=e.latest_tool_names&&e.latest_tool_names.length>0?`${e.latest_tool_call_count??e.latest_tool_names.length}개 도구: ${e.latest_tool_names.join(", ")}`:"아직 근거 없음";return o`
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
          <span>Baseline ${el(e.baseline_metric)}</span>
          <span>현재 ${el(e.current_metric)}</span>
          <span class=${tl(e).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${tl(e)}
          </span>
          <span>Elapsed ${xh(e.elapsed_seconds)}</span>
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
  `}function bo({task:e}){const t=e.priority??4,n=t<=1?"p1":t===2?"p2":t===3?"p3":"p4",s=mi.value.has(e.id),a=!!e.description;return o`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${Sh(t)}</span>
        <div class="kanban-card-title">${e.title}</div>
      </div>
      ${a?o`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>hh(e.id)}
        >
          ${s?e.description:Th(e.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${e.created_at?o`<${W} timestamp=${e.created_at} />`:o`<span>-</span>`}
        ${e.assignee?o`<span class="kanban-assignee">${e.assignee}</span>`:null}
      </div>
    </div>
  `}function Ph(){const{todo:e,inProgress:t,done:n}=Kl.value,s=[...e].sort(nl),a=[...t].sort(nl),i=[...n].sort(Ah);return o`
    <${T} title="태스크 백로그" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>할 일</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${s.length===0?o`<div class="empty-state" style="opacity: 0.5;">대기 중인 태스크가 없습니다</div>`:s.map(l=>o`<${bo} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>진행 중</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${a.length===0?o`<div class="empty-state" style="opacity: 0.5;">진행 중인 태스크가 없습니다</div>`:a.map(l=>o`<${bo} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>완료</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${i.length===0?o`<div class="empty-state" style="opacity: 0.5;">완료된 태스크가 없습니다</div>`:i.slice(0,20).map(l=>o`<${bo} key=${l.id} task=${l} />`)}
          ${i.length>20?o`<div class="empty-state" style="opacity: 0.5;">...외 ${i.length-20}개 더 있음</div>`:null}
        </div>
      </div>
    <//>
  `}function Mh(){const{todo:e,inProgress:t,done:n}=Kl.value,s=e.length+t.length+n.length,a=[...e,...t].filter(g=>(g.priority??4)<=2).length,i=yh.value,l=bh.value,c=Zt.value.length>0,u=l.length>0,p=Ai.value;return o`
    <div>
      <${Se} surfaceId="planning" />

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
          onClick=${()=>{zi(),Vl()}}
          disabled=${zn.value||Rn.value}
        >
          ${zn.value||Rn.value?"새로고침 중...":"계획 데이터 새로고침"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${Ph} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          목표 파이프라인
          <span class="monitor-pill">${Zt.value.length}</span>
        </summary>
        <div>
          ${c?o`
            <${Rh} />
            <${zh} />
            ${zn.value&&Zt.value.length===0?o`<div class="loading-indicator">목표 불러오는 중...</div>`:_d.value.length===0?o`<div class="empty-state">현재 필터에 맞는 목표가 없습니다</div>`:o`
                    <${yo} horizon="short" items=${i.short??[]} />
                    <${yo} horizon="mid" items=${i.mid??[]} />
                    <${yo} horizon="long" items=${i.long??[]} />
                  `}
          `:o`
            <div class="empty-state">
              정의된 목표가 없습니다. <code>masc_goal_upsert</code>로 목표를 만들 수 있습니다.
            </div>
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible" open=${u}>
        <summary>
          MDAL 루프
          <span class="monitor-pill">${l.length}</span>
        </summary>
        <div>
          ${Rn.value&&l.length===0?o`<div class="loading-indicator">MDAL 루프 불러오는 중...</div>`:l.length===0&&(p==="error"||en.value)?o`<div class="empty-state">MDAL 스냅샷을 불러오지 못했습니다${en.value?`: ${en.value}`:""}. 백엔드 상태를 확인하세요.</div>`:l.length===0?o`<div class="empty-state">가동 중인 루프가 없습니다. <code>masc_mdal_start</code>로 시작할 수 있습니다.</div>`:o`
                  <div class="planning-loop-list">
                    ${l.map(g=>o`<${Lh} key=${g.loop_id} loop=${g} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const Da=$(!1),On=$(!1),Qt=$(!1),_t=$(""),qn=$(""),_i=$("open"),qe=$(null),ss=$(null),Oa=$(null),qa=$(null),vi=$(!1);function as(e){return`${e.kind}:${e.id}`}function sr(){var n;const e=ss.value,t=((n=qe.value)==null?void 0:n.items)??[];return e?t.find(s=>as(s)===e)??null:null}function jh(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");return(t==null?void 0:t.trim())||"dashboard"}function Eh(e){const t=e.trim().toLowerCase();return t==="open"||t==="pending"}function vd(e){return!!(e.judgment_summary&&e.judgment_summary.trim())}function fd(e){switch(_i.value){case"needs_quorum":return e.filter(t=>t.kind==="consensus"&&(t.votes??0)<(t.quorum??0));case"ready":return e.filter(t=>{var n;return(n=t.guardrail_state)==null?void 0:n.ready_to_execute});case"needs_approval":return e.filter(t=>{var n,s;return((n=t.guardrail_state)==null?void 0:n.requires_human_gate)||!!((s=t.guardrail_state)!=null&&s.pending_confirm)});case"judge_offline":return e.filter(t=>!vd(t));case"open":default:return e.filter(t=>Eh(t.status))}}function Nh(e){if(e==null)return"없음";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Za(e){const t=(e||"").toLowerCase();return t.includes("reject")||t.includes("deny")||t.includes("closed")||t.includes("cancel")?"negative":t.includes("approve")||t.includes("support")||t.includes("open")||t.includes("ready")?"positive":"neutral"}function Dh(e){return typeof e!="number"||Number.isNaN(e)?"확인 필요":`${Math.round(e*100)}%`}function An(e){return"resolved_tool"in e||"payload_preview"in e||"reason"in e}async function gd(e){if(Oa.value=null,qa.value=null,!!e){vi.value=!0,_t.value="";try{e.kind==="debate"?Oa.value=await pp(e.id):qa.value=await mp(e.id)}catch(t){_t.value=t instanceof Error?t.message:"거버넌스 상세를 불러오지 못했습니다"}finally{vi.value=!1}}}async function Oh(e){ss.value=as(e),await gd(e)}async function fn(){var e;Da.value=!0,_t.value="";try{const t=await pu();qe.value=t;const n=fd(t.items??[]),s=ss.value,a=n.find(i=>as(i)===s)??n[0]??((e=t.items)==null?void 0:e[0])??null;ss.value=a?as(a):null,await gd(a)}catch(t){_t.value=t instanceof Error?t.message:"거버넌스 상태를 불러오지 못했습니다"}finally{Da.value=!1}}Sm(fn);async function sl(){const e=qn.value.trim();if(e){On.value=!0;try{const t=await up(e);qn.value="",E(t!=null&&t.id?`토론을 시작했습니다: ${t.id}`:"토론을 시작했습니다","success"),await fn()}catch(t){const n=t instanceof Error?t.message:"토론 시작에 실패했습니다";_t.value=n,E(n,"error")}finally{On.value=!1}}}async function al(e){var i,l;const t=sr(),n=(i=t==null?void 0:t.guardrail_state)==null?void 0:i.pending_confirm,s=n==null?void 0:n.confirm_token;if(!s)return;const a=((l=n==null?void 0:n.actor)==null?void 0:l.trim())||jh();Qt.value=!0;try{await bl(a,s,e),E(e==="confirm"?"액션을 승인했습니다":"액션을 거부했습니다","success"),await fn()}catch(c){const u=c instanceof Error?c.message:"대기 중인 액션 처리에 실패했습니다";_t.value=u,E(u,"error")}finally{Qt.value=!1}}function qh(){var n,s,a,i,l,c;const e=(n=qe.value)==null?void 0:n.summary,t=(s=qe.value)==null?void 0:s.judge;return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">열린 토론</span>
        <strong>${(e==null?void 0:e.debates_open)??((i=(a=qe.value)==null?void 0:a.debates)==null?void 0:i.length)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">합의 세션</span>
        <strong>${(e==null?void 0:e.sessions_active)??((c=(l=qe.value)==null?void 0:l.sessions)==null?void 0:c.length)??0}</strong>
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
  `}function wh(){return o`
    <${T} title="거버넌스 콘솔" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="토론 주제를 입력하세요..."
            value=${qn.value}
            onInput=${e=>{qn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&sl()}}
            disabled=${On.value}
          />
          <button
            class="control-btn secondary"
            onClick=${sl}
            disabled=${On.value||qn.value.trim()===""}
          >
            ${On.value?"시작 중...":"토론 시작"}
          </button>
          <button class="control-btn ghost" onClick=${fn} disabled=${Da.value}>
            ${Da.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
        <div class="governance-filter-row">
          ${[["open","열림"],["needs_quorum","정족수 부족"],["ready","준비됨"],["needs_approval","승인 필요"],["judge_offline","판정기 오프라인"]].map(([e,t])=>o`
            <button
              class="control-btn ${_i.value===e?"is-active":"ghost"}"
              onClick=${async()=>{_i.value=e,await fn()}}
            >
              ${t}
            </button>
          `)}
        </div>
        ${_t.value?o`<div class="council-error">${_t.value}</div>`:null}
      </div>
    <//>
  `}function Fh(){var t;const e=fd(((t=qe.value)==null?void 0:t.items)??[]);return o`
    <${T} title="의사결정 수신함" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${e.length===0?o`
              <div class="empty-state">
                지금 필터에 맞는 토론이나 합의 세션이 없습니다.
              </div>
            `:e.map(n=>{var a,i;const s=ss.value===as(n);return o`
                <button
                  class="council-row governance-decision-row ${s?"selected":""}"
                  onClick=${()=>Oh(n)}
                >
                  <div class="council-row-main">
                    <div class="governance-row-head">
                      <span class="governance-kind">${n.kind}</span>
                      <span class="council-topic">${n.topic}</span>
                    </div>
                    <div class="council-sub">
                      <span>${n.truth_summary||"사실 요약이 아직 없습니다"}</span>
                      ${n.last_activity_at?o`<span><${W} timestamp=${n.last_activity_at} /></span>`:null}
                    </div>
                    <div class="governance-chip-row">
                      ${(a=n.guardrail_state)!=null&&a.requires_human_gate?o`<span class="governance-chip warn">승인 필요</span>`:null}
                      ${(i=n.guardrail_state)!=null&&i.ready_to_execute?o`<span class="governance-chip ok">준비됨</span>`:null}
                      ${n.kind==="consensus"&&(n.votes??0)<(n.quorum??0)?o`<span class="governance-chip warn">정족수 부족</span>`:null}
                      ${vd(n)?null:o`<span class="governance-chip dim">판정기 오프라인</span>`}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${Za(n.status)}">${n.status}</span>
                    ${n.kind==="consensus"?o`<span class="governance-vote-meter">${n.votes??0}/${n.quorum??0}</span>`:o`<span class="governance-vote-meter">${n.evidence_refs.length} refs</span>`}
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function Kh({argument:e}){return o`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${Za(e.position)}">${e.position}</span>
        <strong>${e.agent}</strong>
        ${e.created_at?o`<span><${W} timestamp=${e.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.content}</div>
      <div class="governance-chip-row">
        ${e.evidence.map(t=>o`<span class="governance-chip">${t}</span>`)}
        ${e.reply_to!=null?o`<span class="governance-chip">답글 #${e.reply_to}</span>`:null}
        ${e.mentions.map(t=>o`<span class="governance-chip">@${t}</span>`)}
        ${e.archetype?o`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function Hh({vote:e}){return o`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${Za(e.decision)}">${e.decision}</span>
        <strong>${e.agent}</strong>
        ${e.timestamp?o`<span><${W} timestamp=${e.timestamp} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.reason||"기록된 이유가 없습니다."}</div>
      <div class="governance-chip-row">
        ${e.weight!=null?o`<span class="governance-chip">가중치 ${e.weight}</span>`:null}
        ${e.archetype?o`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function Uh(){const e=sr(),t=Oa.value,n=qa.value;return o`
    <${T}
      title=${e?`${e.kind==="debate"?"토론":"합의"} 상세`:"의사결정 상세"}
      class="section"
      semanticId="governance.detail"
    >
      ${vi.value?o`<div class="loading-indicator">거버넌스 상세 불러오는 중...</div>`:e?e.kind==="debate"&&t?o`
                <div class="governance-detail-head">
                  <div>
                    <h3>${t.debate.topic}</h3>
                    <div class="council-sub">
                      <span>${t.debate.id}</span>
                      <span>${t.debate.status}</span>
                      ${t.debate.created_at?o`<span><${W} timestamp=${t.debate.created_at} /></span>`:null}
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
                  ${t.arguments.length===0?o`<div class="empty-state">기록된 토론이 아직 없습니다.</div>`:t.arguments.map(s=>o`<${Kh} key=${s.index} argument=${s} />`)}
                </div>
              `:e.kind==="consensus"&&n?o`
                  <div class="governance-detail-head">
                    <div>
                      <h3>${n.session.topic}</h3>
                      <div class="council-sub">
                        <span>${n.session.id}</span>
                        <span>${n.session.state}</span>
                      <span>시작자 ${n.session.initiator}</span>
                        ${n.session.created_at?o`<span><${W} timestamp=${n.session.created_at} /></span>`:null}
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
                    ${n.votes.length===0?o`<div class="empty-state">기록된 표결이 아직 없습니다.</div>`:n.votes.map(s=>o`<${Hh} key=${s.agent+s.timestamp} vote=${s} />`)}
                  </div>
                `:o`<div class="empty-state">이 의사결정의 상세를 아직 읽을 수 없습니다.</div>`:o`<div class="empty-state">사실 계층과 판단을 보려면 의사결정 항목을 고르세요.</div>`}
    <//>
  `}function ol({title:e,route:t}){if(!t)return null;const n=An(t)?t.resolved_tool:t.delegated_tool,s=An(t)?t.target_type:null,a=An(t)?t.target_id:null,i=An(t)?t.reason:null,l=An(t)?t.payload_preview:null;return o`
    <div class="governance-side-block">
      <h4>${e}</h4>
      <div class="council-sub">
        ${n?o`<span>도구 ${n}</span>`:null}
        ${"action_type"in t&&t.action_type?o`<span>액션 ${t.action_type}</span>`:null}
        ${"confirmation_state"in t&&t.confirmation_state?o`<span>${t.confirmation_state}</span>`:null}
        ${"created_at"in t&&t.created_at?o`<span><${W} timestamp=${t.created_at} /></span>`:null}
      </div>
      ${s?o`<div class="governance-side-line">대상 ${s}${a?`:${a}`:""}</div>`:null}
      ${i?o`<div class="governance-side-line">${i}</div>`:null}
      ${l?o`<pre class="council-detail governance-preview">${Nh(l)}</pre>`:null}
    </div>
  `}function Bh(){var c,u,p;const e=sr(),t=Oa.value,n=qa.value,s=(t==null?void 0:t.context)??(n==null?void 0:n.context)??(e==null?void 0:e.context),a=(t==null?void 0:t.judgment)??(n==null?void 0:n.judgment),i=e==null?void 0:e.guardrail_state,l=(c=qe.value)==null?void 0:c.judge;return o`
    <div class="governance-side-column">
      <${T} title="이유 / 가드레일" class="section" semanticId="governance.guardrail">
        ${e?o`
              <div class="governance-side-block">
                <h4>판정기</h4>
                <div class="council-sub">
                  <span>${l!=null&&l.judge_online?"온라인":"오프라인"}</span>
                  ${l!=null&&l.model_used?o`<span>${l.model_used}</span>`:null}
                  ${l!=null&&l.generated_at?o`<span><${W} timestamp=${l.generated_at} /></span>`:null}
                </div>
                ${e.judgment_summary?o`<div class="governance-summary-callout">${e.judgment_summary}</div>`:o`<div class="governance-side-line">현재 LLM 판단이 없어 사실 계층만 보여줍니다.</div>`}
                <div class="council-sub">
                  <span>신뢰도 ${Dh(e.confidence)}</span>
                  ${a!=null&&a.keeper_name?o`<span>${a.keeper_name}</span>`:null}
                </div>
              </div>

              <${ol} title="추천 경로" route=${e.recommended_action} />
              <${ol} title="실행된 경로" route=${e.executed_route} />

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
                          onClick=${()=>al("confirm")}
                          disabled=${Qt.value}
                        >
                          ${Qt.value?"처리 중...":"승인"}
                        </button>
                        <button
                          class="control-btn ghost"
                          onClick=${()=>al("deny")}
                          disabled=${Qt.value}
                        >
                          ${Qt.value?"처리 중...":"거부"}
                        </button>
                      </div>
                    `:o`<div class="governance-side-line">이 의사결정에 대기 중인 사람 승인은 없습니다.</div>`}
              </div>
            `:o`<div class="empty-state">판단과 경로를 보려면 의사결정을 고르세요.</div>`}
      <//>

      <${T} title="맥락" class="section" semanticId="governance.context">
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
                        ${e.related_agents.map(g=>o`<span class="governance-chip dim">${g}</span>`)}
                      </div>
                    `:o`<div class="governance-side-line">명시적으로 연결된 맥락 기록이 없습니다.</div>`}
                ${e.evidence_refs.length>0?o`
                      <div class="governance-side-line">근거 참조</div>
                      <div class="governance-chip-row">
                        ${e.evidence_refs.map(g=>o`<span class="governance-chip">${g}</span>`)}
                      </div>
                    `:null}
              </div>
          `:o`<div class="empty-state">선택된 맥락이 없습니다.</div>`}
      <//>

      <${T} title="최근 활동" class="section" semanticId="governance.activity">
        <div class="governance-activity-list">
          ${(((u=qe.value)==null?void 0:u.activity)??[]).slice(0,8).map(g=>o`
            <div class="governance-activity-row">
              <div class="governance-ledger-head">
                <span class="governance-badge ${Za(g.kind)}">${g.kind}</span>
                ${g.actor?o`<strong>${g.actor}</strong>`:null}
                ${g.created_at?o`<span><${W} timestamp=${g.created_at} /></span>`:null}
              </div>
              <div class="governance-ledger-body">${g.summary||g.topic||"활동이 기록되었습니다."}</div>
            </div>
          `)}
          ${(((p=qe.value)==null?void 0:p.activity)??[]).length===0?o`<div class="empty-state">기록된 거버넌스 활동이 없습니다.</div>`:null}
        </div>
      <//>
    </div>
  `}function Wh(){return oe(()=>{fn()},[]),o`
    <div>
      <${Se} surfaceId="governance" />
      <${qh} />
      <${wh} />
      <div class="governance-layout">
        <${Fh} />
        <${Uh} />
        <${Bh} />
      </div>
    </div>
  `}const Ht=$(""),ko=$("ability_check"),xo=$("10"),So=$("12"),js=$(""),Es=$("idle"),tt=$(""),Ns=$("keeper-late"),Co=$("player"),Ao=$(""),Ae=$("idle"),To=$(null),Ds=$(""),Io=$(""),zo=$("player"),Ro=$(""),Lo=$(""),Po=$(""),wn=$("20"),Mo=$("20"),jo=$(""),Os=$("idle"),fi=$(null),$d=$("overview"),Eo=$("all"),No=$("all"),Do=$("all"),Gh=12e4,eo=$(null),il=$(Date.now());function Jh(e,t){const n=t>0?e/t*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Vh(e,t){return t>0?Math.round(e/t*100):0}const Yh={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Qh={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function qs(e){const t=e.trim();return t?t.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):e}function Xh(e){const t=e.trim().toLowerCase();return Yh[t]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Zh(e){const t=e.trim().toLowerCase();return Qh[t]??"상황에 따라 선택되는 전술 액션입니다."}function ke(e,t,n=""){const s=e[t];return typeof s=="string"?s:n}function Ne(e,t,n=0){const s=e[t];return typeof s=="number"&&Number.isFinite(s)?s:n}function os(e,t,n=!1){const s=e[t];return typeof s=="boolean"?s:n}const ey=new Set(["str","dex","con","int","wis","cha"]);function ty(e){const t=e.trim();if(!t)return{};let n;try{n=JSON.parse(t)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!m(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const l=a.trim();if(l){if(typeof i=="number"&&Number.isFinite(i)){s[l]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const c=Number.parseFloat(i.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function ny(e){const t=Number.parseInt(e.trim(),10);if(!Number.isFinite(t))return;const n=Math.max(1,t),s=Number.parseInt(wn.value.trim(),10);Number.isFinite(s)&&s>n&&(wn.value=String(n))}function gi(e){const n=(e.actor_name??e.actor??e.actor_id??"system").trim();return n===""?"system":n}function sy(e){var n;return(((n=e.timestamp)==null?void 0:n.trim())??"")||"-"}function ay(e){$d.value=e}function hd(e){const t=eo.value;return t==null||t<=e}function oy(e){const t=eo.value;return t==null||t<=e?0:Math.max(0,Math.ceil((t-e)/1e3))}function wa(){eo.value=null}function yd(e){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(e)}function iy(e,t){yd(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${e||"-"}`,`PHASE: ${t||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(eo.value=Date.now()+Gh,E("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Zs(e){return hd(e)?(E("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function $i(e,t,n){return yd([`[위험 액션 확인] ${e}`,`ROOM: ${t||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function ry({hp:e,max:t}){const n=Vh(e,t),s=Jh(e,t);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function ly({stats:e}){const t=[{label:"STR",value:e.strength},{label:"DEX",value:e.dexterity},{label:"CON",value:e.constitution},{label:"INT",value:e.intelligence},{label:"WIS",value:e.wisdom},{label:"CHA",value:e.charisma}];return o`
    <div class="trpg-actor-stats">
      ${t.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function cy({keeper:e,role:t}){if(!e)return null;const n=t==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${e}
    </span>
  `}function bd({actor:e}){var u,p,g,f;const t=(u=e.archetype)==null?void 0:u.trim(),n=(p=e.persona)==null?void 0:p.trim(),s=(g=e.portrait)==null?void 0:g.trim(),a=(f=e.background)==null?void 0:f.trim(),i=e.traits??[],l=e.skills??[],c=Object.entries(e.stats_raw??{}).filter(([v,h])=>Number.isFinite(h)).filter(([v])=>!ey.has(v.toLowerCase()));return o`
    <div class="trpg-actor">
      ${s?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${e.name} portrait`}
              loading="lazy"
              onError=${v=>{const h=v.target;h&&(h.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${e.name}</span>
        <${gt} status=${e.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${e.role}">${e.role}</span>
        <${cy} keeper=${e.keeper} role=${e.role} />
      </div>
      ${e.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${e.stats.hp}/${e.stats.max_hp}
              ${e.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${e.stats.mp}/${e.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${e.stats.level}</span>
            </div>
            <${ry} hp=${e.stats.hp} max=${e.stats.max_hp} />
            <${ly} stats=${e.stats} />
          </div>
        `:null}
      ${t?o`<div class="trpg-actor-meta">Archetype: ${qs(t)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([v,h])=>o`
                <span class="trpg-custom-stat-chip">${qs(v)} ${h}</span>
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
                  <span class="trpg-annot-name">${qs(v)}</span>
                  <span class="trpg-annot-desc">${Xh(v)}</span>
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
                  <span class="trpg-annot-name">${qs(v)}</span>
                  <span class="trpg-annot-desc">${Zh(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function dy({mapStr:e}){return o`<pre class="trpg-map">${e}</pre>`}function kd({events:e,emptyLabel:t="아직 이벤트가 없습니다."}){return e.length===0?o`<div class="empty-state" style="font-size:13px">${t}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${e.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${sy(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${gi(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${W} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function uy({events:e}){const t="__none__",n=Eo.value,s=No.value,a=Do.value,i=Array.from(new Set(e.map(gi).map(f=>f.trim()).filter(f=>f!==""))).sort((f,v)=>f.localeCompare(v)),l=Array.from(new Set(e.map(f=>(f.type??"").trim()).filter(f=>f!==""))).sort((f,v)=>f.localeCompare(v)),c=e.some(f=>(f.type??"").trim()===""),u=Array.from(new Set(e.map(f=>(f.phase??"").trim()).filter(f=>f!==""))).sort((f,v)=>f.localeCompare(v)),p=e.some(f=>(f.phase??"").trim()===""),g=e.filter(f=>{if(n!=="all"&&gi(f)!==n)return!1;const v=(f.type??"").trim(),h=(f.phase??"").trim();if(s===t){if(v!=="")return!1}else if(s!=="all"&&v!==s)return!1;if(a===t){if(h!=="")return!1}else if(a!=="all"&&h!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${f=>{Eo.value=f.target.value}}>
          <option value="all">all</option>
          ${i.map(f=>o`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${f=>{No.value=f.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${t}>(none)</option>`:null}
          ${l.map(f=>o`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${f=>{Do.value=f.target.value}}>
          <option value="all">all</option>
          ${p?o`<option value=${t}>(none)</option>`:null}
          ${u.map(f=>o`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Eo.value="all",No.value="all",Do.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${g.length} / 전체 ${e.length}
      </span>
    </div>
    <${kd} events=${g.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function py({outcome:e}){if(!e)return null;const t=i=>{const l=i.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=e.result==="victory"?"승리":e.result==="defeat"?"패배":e.result==="draw"?"무승부":"종료",s=e.result==="victory"?"#34d399":e.result==="defeat"?"#f87171":"#9ca3af",a=[e.reason?`원인: ${t(e.reason)}`:null,e.phase?`페이즈: ${t(e.phase)}`:null,typeof e.turn=="number"?`턴: ${e.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${e.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${t(e.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function xd({state:e}){const t=e.history??[];return t.length===0?null:o`
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
  `}function my({state:e,nowMs:t}){var p;const n=Ve.value||((p=e.session)==null?void 0:p.room)||"",s=Es.value,a=e.party??[];if(!a.find(g=>g.id===Ht.value)&&a.length>0){const g=a[0];g&&(Ht.value=g.id)}const l=async()=>{var f,v;if(!n){E("Room ID가 비어 있습니다.","error");return}if(!Zs(t))return;const g=((f=e.current_round)==null?void 0:f.phase)??((v=e.session)==null?void 0:v.status)??"unknown";if($i("라운드 실행",n,g)){Es.value="running";try{const h=await ep(n);fi.value=h,Es.value="ok";const b=m(h.summary)?h.summary:null,C=b?os(b,"advanced",!1):!1,x=b?ke(b,"progress_reason",""):"";E(C?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${x?`: ${x}`:""}`,C?"success":"warning"),rt()}catch(h){fi.value=null,Es.value="error";const b=h instanceof Error?h.message:"라운드 실행에 실패했습니다.";E(b,"error")}finally{wa()}}},c=async()=>{var f,v;if(!n||!Zs(t))return;const g=((f=e.current_round)==null?void 0:f.phase)??((v=e.session)==null?void 0:v.status)??"unknown";if($i("턴 강제 진행",n,g))try{await sp(n),E("턴을 다음 단계로 이동했습니다.","success"),rt()}catch{E("턴 이동에 실패했습니다.","error")}finally{wa()}},u=async()=>{if(!n||!Zs(t))return;const g=Ht.value.trim();if(!g){E("먼저 Actor를 선택하세요.","warning");return}const f=Number.parseInt(xo.value,10),v=Number.parseInt(So.value,10);if(Number.isNaN(f)||Number.isNaN(v)){E("stat/dc는 숫자여야 합니다.","warning");return}const h=Number.parseInt(js.value,10),b=js.value.trim()===""||Number.isNaN(h)?void 0:h;try{await np({roomId:n,actorId:g,action:ko.value.trim()||"ability_check",statValue:f,dc:v,rawD20:b}),E("주사위 판정을 기록했습니다.","success"),rt()}catch{E("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${g=>{Ve.value=g.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Ht.value}
            onChange=${g=>{Ht.value=g.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(g=>o`<option value=${g.id}>${g.name} (${g.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${ko.value}
              onInput=${g=>{ko.value=g.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${xo.value}
              onInput=${g=>{xo.value=g.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${So.value}
              onInput=${g=>{So.value=g.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${js.value}
              onInput=${g=>{js.value=g.target.value}}
              onKeyDown=${g=>{g.key==="Enter"&&u()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${u}>Roll</button>
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
  `}function _y({state:e}){var a;const t=Ve.value||((a=e.session)==null?void 0:a.room)||"",n=Os.value,s=async()=>{if(!t){E("Room ID가 비어 있습니다.","warning");return}const i=Ds.value.trim(),l=Io.value.trim();if(!l&&!i){E("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(wn.value.trim(),10),u=Number.parseInt(Mo.value.trim(),10),p=Number.isFinite(u)?Math.max(1,u):20,g=Number.isFinite(c)?Math.max(0,Math.min(p,c)):p;let f={};try{f=ty(jo.value)}catch(v){E(v instanceof Error?v.message:"능력치 JSON 오류","error");return}Os.value="spawning";try{const v=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,h=await ap(t,{actor_id:i||void 0,name:l||void 0,role:zo.value,idempotencyKey:v,portrait:Lo.value.trim()||void 0,background:Po.value.trim()||void 0,hp:g,max_hp:p,alive:g>0,stats:Object.keys(f).length>0?f:void 0}),b=typeof h.actor_id=="string"?h.actor_id.trim():"";if(!b)throw new Error("생성 응답에 actor_id가 없습니다.");const C=Ro.value.trim();C&&await op(t,b,C),Ht.value=b,tt.value=b,i||(Ds.value=""),Os.value="ok",E(`Actor 생성 완료: ${b}`,"success"),await rt()}catch(v){Os.value="error",E(v instanceof Error?v.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Io.value}
            onInput=${i=>{Io.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${zo.value}
            onChange=${i=>{zo.value=i.target.value}}
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
            value=${Ro.value}
            onInput=${i=>{Ro.value=i.target.value}}
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
              onInput=${i=>{Ds.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Lo.value}
              onInput=${i=>{Lo.value=i.target.value}}
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
              value=${Mo.value}
              onInput=${i=>{const l=i.target.value;Mo.value=l,ny(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Po.value}
              onInput=${i=>{Po.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${jo.value}
              onInput=${i=>{jo.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function vy({state:e,nowMs:t}){var v;const n=Ve.value||((v=e.session)==null?void 0:v.room)||"",s=e.join_gate,a=To.value,i=m(a)?a:null,l=(e.party??[]).filter(h=>h.role!=="dm"),c=tt.value.trim(),u=l.some(h=>h.id===c),p=u?c:c?"__manual__":"",g=async()=>{const h=tt.value.trim(),b=Ns.value.trim();if(!n||!h){E("Room/Actor가 필요합니다.","warning");return}Ae.value="checking";try{const C=await ip(n,h,b||void 0);To.value=C,Ae.value="ok",E("참가 가능 여부를 갱신했습니다.","success")}catch(C){Ae.value="error";const x=C instanceof Error?C.message:"참가 가능 여부 확인에 실패했습니다.";E(x,"error")}},f=async()=>{var S,_;const h=tt.value.trim(),b=Ns.value.trim(),C=Ao.value.trim();if(!n||!h||!b){E("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Zs(t))return;const x=((S=e.current_round)==null?void 0:S.phase)??((_=e.session)==null?void 0:_.status)??"unknown";if($i("Mid-Join 승인 요청",n,x)){Ae.value="requesting";try{const I=await rp({room_id:n,actor_id:h,keeper_name:b,role:Co.value,...C?{name:C}:{}});To.value=I;const R=m(I)?os(I,"granted",!1):!1,L=m(I)?ke(I,"reason_code",""):"";R?E("Mid-Join이 승인되었습니다.","success"):E(`Mid-Join이 거절되었습니다${L?`: ${L}`:""}`,"warning"),Ae.value=R?"ok":"error",rt()}catch(I){Ae.value="error";const R=I instanceof Error?I.message:"Mid-Join 요청에 실패했습니다.";E(R,"error")}finally{wa()}}};return o`
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
            onChange=${h=>{const b=h.target.value;if(b==="__manual__"){(u||!c)&&(tt.value="");return}tt.value=b}}
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
                value=${tt.value}
                onInput=${h=>{tt.value=h.target.value}}
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
            onInput=${h=>{Ns.value=h.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Co.value}
            onChange=${h=>{Co.value=h.target.value}}
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
            value=${Ao.value}
            onInput=${h=>{Ao.value=h.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${g} disabled=${Ae.value==="checking"||Ae.value==="requesting"}>
              ${Ae.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${f} disabled=${Ae.value==="checking"||Ae.value==="requesting"}>
              ${Ae.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${os(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Ne(i,"effective_score",0)}/${Ne(i,"required_points",0)}</span>
            ${ke(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${ke(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Sd({state:e}){const t=[...e.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return t.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${t.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Cd({state:e}){var n;const t=e.current_round;return t?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${t.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${t.phase}</div>
      ${t.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=t.events[t.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Ad(){const e=fi.value;if(!e)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const t=e.summary,n=m(t)?t:null,a=(Array.isArray(e.statuses)?e.statuses:[]).filter(m).slice(-8),i=e.canon_check,l=m(i)?i:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(L=>typeof L=="string").slice(0,3):[],u=l&&Array.isArray(l.violations)?l.violations.filter(L=>typeof L=="string").slice(0,3):[],p=n?os(n,"advanced",!1):!1,g=n?ke(n,"progress_reason",""):"",f=n?ke(n,"progress_detail",""):"",v=n?Ne(n,"player_successes",0):0,h=n?Ne(n,"player_required_successes",0):0,b=n?os(n,"dm_success",!1):!1,C=n?Ne(n,"timeouts",0):0,x=n?Ne(n,"unavailable",0):0,S=n?Ne(n,"reprompts",0):0,_=n?Ne(n,"npc_attacks",0):0,I=n?Ne(n,"keeper_timeout_sec",0):0,R=n?Ne(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${p?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${p?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${e.turn_before??0} → ${e.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${b?"DM ok":"DM stalled"} / players ${v}/${h}
          </span>
        </div>
        ${g?o`<div style="margin-top:4px; font-size:12px;">${g}</div>`:null}
        ${f?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${f}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${_}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${I||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${R}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(L=>{const V=ke(L,"status","unknown"),z=ke(L,"actor_id","-"),G=ke(L,"role","-"),Q=ke(L,"reason",""),se=ke(L,"action_type",""),M=ke(L,"reply","");return o`
                <div class="trpg-round-item ${V.includes("fallback")||V.includes("timeout")?"failed":"active"}">
                  <span>${z} (${G})</span>
                  <span style="margin-left:auto; font-size:11px;">${V}</span>
                  ${se?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${se}</div>`:null}
                  ${Q?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${Q}</div>`:null}
                  ${M?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${M.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${ke(l,"status","unknown")}</strong>
            </div>
            ${u.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${u.map(L=>o`<div>violation: ${L}</div>`)}
                </div>`:null}
            ${c.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(L=>o`<div>warning: ${L}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function fy({state:e,nowMs:t}){var l,c,u;const n=Ve.value||((l=e.session)==null?void 0:l.room)||"",s=((c=e.current_round)==null?void 0:c.phase)??((u=e.session)==null?void 0:u.status)??"unknown",a=hd(t),i=oy(t);return o`
    <${T} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>iy(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{wa(),E("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function gy({active:e}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${e===n.id?"active":""}"
          role="tab"
          aria-selected=${e===n.id}
          onClick=${()=>ay(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function $y({state:e}){const t=e.party??[],n=e.story_log??[];return o`
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
          <${kd} events=${n.slice(-20)} />
        <//>

        ${e.map?o`
            <${T} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${dy} mapStr=${e.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${T} title="현재 라운드" semanticId="lab.trpg">
          <${Cd} state=${e} />
        <//>

        <${T} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${Sd} state=${e} />
        <//>

        <${T} title=${`파티 (${t.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${t.map(s=>o`<${bd} key=${s.id??s.name} actor=${s} />`)}
            ${t.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${e.history&&e.history.length>0?o`
            <${T} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
              <${xd} state=${e} />
            <//>
          `:null}
      </div>
    </div>
  `}function hy({state:e}){const t=e.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${T} title=${`이벤트 타임라인 (${t.length})`}>
          <${uy} events=${t} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${T} title="최근 라운드 결과" semanticId="lab.trpg">
          <${Ad} />
        <//>

        <${T} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${Cd} state=${e} />
        <//>
      </div>
    </div>
  `}function yy({state:e,nowMs:t}){const n=e.party??[];return o`
    <div>
      <${fy} state=${e} nowMs=${t} />
      <div class="trpg-layout">
        <div>
          <${T} title="조작 패널" semanticId="lab.trpg">
            <${my} state=${e} nowMs=${t} />
          <//>

          <${T} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${_y} state=${e} />
          <//>

          <${T} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${vy} state=${e} nowMs=${t} />
          <//>

          <${T} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${Ad} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${T} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${Sd} state=${e} />
          <//>

          <${T} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${bd} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${e.history&&e.history.length>0?o`
              <${T} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
                <${xd} state=${e} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function by(){var c,u,p,g,f;const e=ql.value,t=Vo.value;if(oe(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const v=window.setInterval(()=>{il.value=Date.now()},1e3);return()=>{window.clearInterval(v)}},[]),t&&!e)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!e)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>rt()}>Refresh</button>
      </div>
    `;const n=e.party??[],s=e.story_log??[],a=e.outcome,i=$d.value,l=il.value;return o`
    <div>
      <${Se} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Ve.value||((c=e.session)==null?void 0:c.room)||"-"} · phase: ${((u=e.current_round)==null?void 0:u.phase)??((p=e.session)==null?void 0:p.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>rt()}>새로고침</button>
      </div>

      <${py} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((g=e.session)==null?void 0:g.status)??"active"}</div>
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

      <${gy} active=${i} />

      ${i==="overview"?o`<${$y} state=${e} />`:i==="timeline"?o`<${hy} state=${e} />`:o`<${yy} state=${e} nowMs=${l} />`}
    </div>
  `}function ky(){return o`
    <div>
      <${Se} surfaceId="lab" />
      <${T} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${T} title="TRPG" class="section" semanticId="lab.trpg">
        <${by} />
      <//>
    </div>
  `}const Fa=$(new Set(["broadcast","tasks","keepers","system"]));function xy(e){const t=new Set(Fa.value);t.has(e)?t.delete(e):t.add(e),Fa.value=t}const ar=$(null);function Td(e){ar.value=e}function Sy(e){return e.kind==="board"?"broadcast":e.kind==="tasks"?"tasks":e.kind==="keepers"?"keepers":"system"}const Cy=Pe(()=>{const e=Fa.value;return ta.value.filter(t=>e.has(Sy(t)))}),Ay=12e4,Ty=Pe(()=>{const e=Hl.value,t=Date.now();return Xe.value.map(n=>{const s=n.name.trim().toLowerCase(),a=e.get(s)??null;let i="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?i=t-new Date(l).getTime()>Ay?"stale":"working":i="working"}else(n.status==="offline"||n.status==="inactive")&&(i="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:i,currentTask:n.current_task,motion:a}})}),Iy=Pe(()=>{const e=Hl.value;return Xe.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle").map(t=>{const n=t.name.trim().toLowerCase(),s=e.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let i="calm";return a>=3?i="hot":a>=1&&(i="normal"),{name:t.name,emoji:t.emoji??"",koreanName:t.koreanName??null,currentTask:t.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:i}}).sort((t,n)=>{const s={hot:0,normal:1,calm:2};return s[t.pressure]-s[n.pressure]})});function rl(e){return e.kind==="board"?"live-event-broadcast":e.kind==="tasks"?"live-event-task":e.kind==="keepers"?"live-event-keeper":"live-event-system"}function zy(e){const t=e.eventType;return t==="broadcast"?"broadcast":t==="agent_joined"?"joined":t==="agent_left"?"left":t==="task_update"?"task":t==="board_post"?"post":t==="board_comment"?"comment":t==="keeper_heartbeat"?"heartbeat":t==="keeper_handoff"?"handoff":t==="keeper_compaction"?"compact":t==="keeper_guardrail"?"guardrail":e.kind==="board"?"board":e.kind==="tasks"?"task":e.kind==="keepers"?"keeper":"system"}function Ry(e){switch(e){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function Ly(){const e=Ty.value,t=ar.value;return e.length===0?o`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:o`
    <div class="pulse-strip">
      ${e.map(n=>o`
        <button
          key=${n.name}
          class="pulse-bubble ${Ry(n.state)} ${t===n.name?"pulse-selected":""}"
          onClick=${()=>Td(t===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const Py=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function My(){const e=Fa.value;return o`
    <div class="activity-filter-bar">
      ${Py.map(t=>o`
        <button
          key=${t.kind}
          class="activity-filter-btn ${t.cssClass} ${e.has(t.kind)?"active":""}"
          onClick=${()=>xy(t.kind)}
        >
          ${t.label}
        </button>
      `)}
    </div>
  `}function jy(){const e=Cy.value;return o`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${e.length} events</span>
      </div>
      <${My} />
      <div class="activity-stream-list">
        ${e.length===0?o`<div class="activity-empty">No events matching filters</div>`:e.map((t,n)=>o`
            <div
              key=${`${t.timestamp}-${n}`}
              class="activity-item ${rl(t)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${rl(t)}">${zy(t)}</span>
                <span class="activity-agent">${t.agent}</span>
                <span class="activity-time">${Fc(t.timestamp)}</span>
              </div>
              <div class="activity-item-text">${t.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function Ey(e){switch(e){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function Ny(e){switch(e){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function Dy(){const e=Iy.value,t=ar.value;return o`
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
              onClick=${()=>Td(t===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?o`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${Ey(n.pressure)}">
                  ${Ny(n.pressure)}
                  ${n.assignedCount>0?o` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?o`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?o`<span class="focus-activity-text">${n.lastActivityText}</span>`:o`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?o`<${W} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function Oy(){const e=ut.value;return o`
    <div class="live-monitor">
      <div class="live-header">
        <h2>라이브 모니터</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${e?"connected":"disconnected"}"></span>
            ${e?"연결됨":"오프라인"}
          </span>
          <span class="live-stat">에이전트 ${Xe.value.length}</span>
          <span class="live-stat">이벤트 ${Ka.value}</span>
        </div>
      </div>

      <${Ly} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${jy} />
        </div>
        <div class="live-panel-side">
          <${Dy} />
        </div>
      </div>
    </div>
  `}const ll=[{id:"observe",label:"관찰",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"맥락",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"개입",description:"개입과 운영 기준 지휘를 실행하는 표면"},{id:"lab",label:"실험",description:"실험적 기능은 메인 operator console 밖으로 분리"}],hi=[{id:"mission",label:"상황판",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"proof",label:"근거",icon:"🔍",group:"observe",description:"협업, 대화, 도구, 근거 기록을 증명 중심으로 읽는 표면"},{id:"execution",label:"실행",icon:"🤖",group:"observe",description:"워커, 태스크, 키퍼 연속성을 분리해서 보는 실행 표면"},{id:"tools",label:"도구",icon:"🧰",group:"observe",description:"시스템 전체 도구 inventory와 사용 통계를 함께 읽는 표면"},{id:"live",label:"라이브",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"계획",icon:"🎯",group:"observe",description:"목표, 지표 루프, 백로그 압력을 읽는 계획 표면"},{id:"memory",label:"메모리",icon:"💬",group:"context",description:"게시글과 댓글로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"거버넌스",icon:"⚖️",group:"context",description:"토론과 표결을 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"개입",icon:"🎮",group:"act",description:"룸, 세션, 키퍼 액션을 실행하는 개입 화면"},{id:"command",label:"지휘",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"실험",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 표면을 메인 콘솔 밖에서 다룹니다"}];function qy(e){const t=e==null?void 0:e.trim();return t?t.length>10?t.slice(0,10):t:"커밋 정보 없음"}function Re(e,t){return t==="live"?"가동 중":t==="quiet"?"조용함":t==="starting"?"기동 중":t==="idle"?e==="guardian"?"유휴":"대기 중":"비활성"}function Te(e,t){return o`
    <div class="build-badge-row">
      <span>${e}</span>
      <strong>${t}</strong>
    </div>
  `}function ws(e,t,n,s,a){return o`
    <div style="padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
      <div class="rail-card-head" style="margin:0;">
        <h3 style="font-size:12px;">${e}</h3>
        <span class="rail-section-chip ${n}">${t}</span>
      </div>
      ${s}
      ${a?o`<div class="rail-build-hint">${a}</div>`:null}
    </div>
  `}function wy({currentTab:e}){var u,p,g,f,v,h,b,C,x,S;const t=ut.value,n=(u=re.value)==null?void 0:u.build,s=(p=re.value)==null?void 0:p.lodge,a=(g=re.value)==null?void 0:g.gardener,i=(f=re.value)==null?void 0:f.guardian,l=(v=re.value)==null?void 0:v.sentinel,c=[];if(s&&c.push(ws("Lodge",s.enabled?Re("lodge",s.quiet_active?"quiet":"live"):Re("lodge","disabled"),s.enabled?s.quiet_active?"warn":"ok":"bad",[Te("틱",s.total_ticks??0),Te("체크인",s.total_checkins??0),Te("최근 결과",((h=s.last_tick_result)==null?void 0:h.activity_report)??s.last_skip_reason??"없음")])),a&&c.push(ws("Gardener",a.alive?Re("gardener","live"):a.enabled?Re("gardener","starting"):Re("gardener","disabled"),a.alive?"ok":a.enabled?"warn":"bad",[Te("최근 tick",a.last_tick_completed_at?o`<${W} timestamp=${a.last_tick_completed_at} />`:"기록 없음"),Te("판단",`${a.last_intervention??"없음"} · ${a.last_decision_source??"없음"}`),Te("백로그",`미할당 ${((b=a.health_summary)==null?void 0:b.todo_count)??0} · P1/2 ${((C=a.health_summary)==null?void 0:C.high_priority_todo)??0}`)],a.last_reason??a.last_error??void 0)),i){const _=i.masc_loops_running||i.lodge_loop_started||i.lodge_running;c.push(ws("Guardian",_?Re("guardian","live"):i.enabled?Re("guardian","idle"):Re("guardian","disabled"),_?"ok":i.enabled?"warn":"bad",[Te("모드",i.mode??"알 수 없음"),Te("루프",`zombie ${i.zombie_loop_running?"on":"off"} · gc ${i.gc_loop_running?"on":"off"}`),Te("소유자",i.runtime_owner??"없음")],((x=i.last_lodge_result)==null?void 0:x.message)??i.last_gc_result??i.last_zombie_result??void 0))}return l&&c.push(ws("Sentinel",l.started?Re("sentinel","live"):l.enabled?Re("sentinel","starting"):Re("sentinel","disabled"),l.started?"ok":l.enabled?"warn":"bad",[Te("에이전트",l.agent_name??"sentinel"),Te("소비자",((S=l.consumers)==null?void 0:S.length)??0),Te("가디언 소유자",l.guardian_runtime_owner??"없음")],l.llm_enabled===!0?"LLM 기반 housekeeping resident":void 0)),o`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${q} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${t?"ok":"bad"}">${t?"연결됨":"오프라인"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>에이전트</span>
          <strong>${Xe.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>키퍼</span>
          <strong>${vt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>태스크</span>
          <strong>${at.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>이벤트</span>
          <strong>${Ka.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{rs(),Gl(),oi(e)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>ie("intervene")}>
          개입 열기
        </button>
      </div>
      ${n?o`<div class="rail-build-hint">서버 빌드 · v${n.release_version} · ${qy(n.commit)}</div>`:null}
      ${c.length>0?o`
            <div style="margin-top:12px; display:flex; flex-direction:column; gap:10px;">
              ${c}
            </div>
          `:null}
    </section>
  `}function Fy(){const e=he.value,t=(e==null?void 0:e.pending_confirms.length)??0,n=(e==null?void 0:e.sessions.length)??0,s=(e==null?void 0:e.keepers.length)??0;return o`
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
          <span>키퍼</span>
          <strong>${s}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{ge(),jt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>ie("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}const Fs=$(!1);function Ky(){const e=ut.value;return o`
    <div class="connection-status ${e?"connected":"disconnected"}">
      <span class="status-dot ${e?"connected":"disconnected"}"></span>
      <span class="status-text">${e?"연결됨":"재연결 중..."}</span>
      <span class="event-count">이벤트 ${Ka.value}</span>
    </div>
  `}function Hy(e){const t=e==null?void 0:e.trim();return t?t.length>10?t.slice(0,10):t:"커밋 정보 없음"}function Uy(){const e=re.value,t=e==null?void 0:e.build,n=t?`v${t.release_version} · ${Hy(t.commit)}`:e!=null&&e.version?`v${e.version} · 커밋 정보 없음`:"버전 정보 없음";return o`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${Fs.value}
        onClick=${()=>{Fs.value=!Fs.value}}
      >
        서버 빌드 · ${n}
      </button>
      ${Fs.value?o`
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
                <strong>${t!=null&&t.started_at?o`<${W} timestamp=${t.started_at} />`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof(t==null?void 0:t.uptime_seconds)=="number"?`${t.uptime_seconds}s`:"알 수 없음"}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${e!=null&&e.generated_at?o`<${W} timestamp=${e.generated_at} />`:"알 수 없음"}</strong>
              </div>
            </div>
          `:null}
    </div>
  `}function By(){const e=O.value.tab,t=hi.find(s=>s.id===e),n=ll.find(s=>s.id===(t==null?void 0:t.group));return o`
    <aside class="dashboard-rail">
      <${Se} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${q} panelId="side_rail.navigate" compact=${!0} />
          ${n?o`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${ll.map(s=>o`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${hi.filter(a=>a.group===s.id).map(a=>o`
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

      <${wy} currentTab=${e} />
      <${Fy} />
    </aside>
  `}function Wy(){switch(O.value.tab){case"mission":return o`<${Rr} />`;case"proof":return o`<${mg} />`;case"execution":return o`<${uh} />`;case"tools":return o`<${$h} />`;case"live":return o`<${Oy} />`;case"memory":return o`<${Y$} />`;case"governance":return o`<${Wh} />`;case"planning":return o`<${Mh} />`;case"intervene":return o`<${D$} />`;case"command":return o`<${M$} />`;case"lab":return o`<${ky} />`;default:return o`<${Rr} />`}}function Gy(){return Jo.value&&!ut.value?o`<div class="loading-indicator">대시보드 불러오는 중...</div>`:o`<${Wy} />`}function Jy(){oe(()=>{Od(),fl(),Jl(),It(),Tt(),Gl(),cc();const n=Tm();return Im(),()=>{Wd(),n(),zm()}},[]),oe(()=>{const n=setInterval(()=>{oi(O.value.tab)},15e3);return()=>{clearInterval(n)}},[]),oe(()=>{oi(O.value.tab)},[O.value.tab]);const e=O.value.tab,t=hi.find(n=>n.id===e);return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC 대시보드
            <${Uy} />
          </h1>
          <p class="header-subtitle">${(t==null?void 0:t.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${Ky} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${By} />
        <main class="dashboard-main">
          <${Gy} />
        </main>
      </div>

      <${ff} />
      <${Bv} />
      <${Ev} />
    </div>
  `}const cl=document.getElementById("app");cl&&Md(o`<${Jy} />`,cl);export{Af as _};
