var pc=Object.defineProperty;var mc=(e,t,n)=>t in e?pc(e,t,{enumerable:!0,configurable:!0,writable:!0,value:n}):e[t]=n;var It=(e,t,n)=>mc(e,typeof t!="symbol"?t+"":t,n);import{e as vc,_ as _c,c as f,b as xe,y as ee,d as tr,A as gc,G as fc}from"./vendor-kuFK4-oj.js";(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const l of o.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=vc.bind(_c);const $c=["mission","proof","execution","live","memory","governance","planning","intervene","command","lab"],nr={tab:"mission",params:{},postId:null};function mo(e){return!!e&&$c.includes(e)}function ni(e){try{return decodeURIComponent(e)}catch{return e}}function si(e){const t={};return e&&new URLSearchParams(e).forEach((s,a)=>{t[a]=s}),t}function hc(e){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function sr(e,t){if(e[0]==="chains"){const o={...t,surface:"chains"};return e[1]==="operation"&&e[2]&&(o.operation=ni(e[2])),{tab:"command",params:o,postId:null}}if(e[0]==="lab"){const o={...t};return e[1]&&(o.surface=ni(e[1])),{tab:"lab",params:o,postId:null}}const n=e[0],s=t.tab;return{tab:mo(n)?n:mo(s)?s:"mission",params:t,postId:null}}function Ms(e){const t=(e||"").replace(/^#/,"").trim();if(!t)return nr;const n=ni(t);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=si(a),l=hc(s);return sr(l,o)}function yc(e,t){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...nr,params:si(t.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=si(t.replace(/^\?/,""));return sr(s,a)}function ar(e){const t=e.tab==="lab"&&e.params.surface?`lab/${encodeURIComponent(e.params.surface)}`:e.tab,n=Object.entries(e.params).filter(([a])=>!(a==="tab"||e.tab==="lab"&&a==="surface"));if(n.length===0)return`#${t}`;const s=new URLSearchParams(n);return`#${t}?${s.toString()}`}const O=f(Ms(window.location.hash));window.addEventListener("hashchange",()=>{O.value=Ms(window.location.hash)});function ce(e,t){const n={tab:e,params:t??{}};window.location.hash=ar(n)}function bc(e){window.location.hash=`#memory?post=${encodeURIComponent(e)}`}function kc(){if(window.location.hash&&window.location.hash!=="#"){O.value=Ms(window.location.hash);return}const e=yc(window.location.pathname,window.location.search);if(e){O.value=e;const t=ar(e);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${t}`);return}window.location.hash="#mission",O.value=Ms(window.location.hash)}const vo="masc_dashboard_sse_session_id",xc=1e3,Sc=15e3,nt=f(!1),_a=f(0),ir=f(null),js=f([]);function Ac(){let e=sessionStorage.getItem(vo);return e||(e=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(vo,e)),e}const Cc=200;function Ic(e,t,n="system",s={}){const a={agent:e,text:t,timestamp:Date.now(),kind:n,...s};js.value=[a,...js.value].slice(0,Cc)}function ai(e,t=88){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-3)}...`:n:void 0}function _o(e,t){const n=ai(t);return n?`${e}: ${n}`:`New ${e.toLowerCase()}`}function ke(e,t,n,s,a={}){Ic(e,t,n,{eventType:s,...a})}let Re=null,Ft=null,ii=0;function or(){Ft&&(clearTimeout(Ft),Ft=null)}function Tc(){if(Ft)return;ii++;const e=Math.min(ii,5),t=Math.min(Sc,xc*Math.pow(2,e));Ft=setTimeout(()=>{Ft=null,rr()},t)}function rr(){or(),Re&&(Re.close(),Re=null);const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");n&&t.set("agent",n),s&&t.set("token",s),t.set("session_id",Ac());const a=t.toString()?`/sse?${t.toString()}`:"/sse",o=new EventSource(a);Re=o,o.onopen=()=>{Re===o&&(ii=0,nt.value=!0)},o.onerror=()=>{Re===o&&(nt.value=!1,o.close(),Re=null,Tc())},o.onmessage=l=>{try{const c=JSON.parse(l.data);_a.value++,ir.value=c,Rc(c)}catch{}}}function Rc(e){const t=e.type,n=e.agent??e.author??e.from??e.from_agent??"";switch(t){case"agent_joined":ke(n,"Joined","system","agent_joined");break;case"agent_left":ke(n,"Left","system","agent_left");break;case"broadcast":ke(n,`${(e.message??e.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":ke(n,`Task: ${e.task_id??""} -> ${e.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":ke(n,_o("Post",e.content??e.message),"board","board_post",{author:e.author??n,preview:ai(e.content??e.message),postId:e.post_id});break;case"board_comment":case"masc/board_comment":ke(n,_o("Comment",e.content??e.message),"board","board_comment",{author:e.author??n,preview:ai(e.content??e.message),postId:e.post_id});break;case"keeper_heartbeat":ke(e.name??n,`Heartbeat gen=${e.generation??"?"} ctx=${e.context_ratio!=null?Math.round(e.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":ke(e.name??n,`Handoff gen ${e.from_generation??"?"} -> ${e.to_generation??"?"} (${e.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":ke(e.name??n,`Compaction saved ${e.saved_tokens??"?"} tokens (${e.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":ke(e.name??n,`Guardrail: ${e.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:ke(n,t,"system","unknown")}}function Pc(){or(),Re&&(Re.close(),Re=null),nt.value=!1}function m(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function r(e){return typeof e=="string"&&e.trim()!==""?e.trim():void 0}function d(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function j(e){return typeof e=="boolean"?e:void 0}function H(e){return Array.isArray(e)?e.map(t=>typeof t=="string"?t.trim():"").filter(Boolean):[]}function fe(e,t=[]){if(Array.isArray(e))return e;if(!m(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function st(e){if(typeof e=="string"&&e.trim()!=="")return e;if(!(typeof e!="number"||!Number.isFinite(e)||e<=0))return new Date(e*1e3).toISOString()}function lr(){return new URLSearchParams(window.location.search)}function cr(){const e=lr(),t={},n=e.get("token"),s=e.get("agent")??e.get("agent_name");return n&&(t.Authorization=`Bearer ${n}`),s&&(t["X-MASC-Agent"]=s),t}function dr(){return{...cr(),"Content-Type":"application/json"}}const Lc=15e3,Ni=3e4,Nc=6e4,go=new Set([408,425,429,500,502,503,504]);class Wn extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);It(this,"method");It(this,"path");It(this,"status");It(this,"statusText");It(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function wi(e,t,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(e,{...t,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const l=typeof t.method=="string"?t.method.toUpperCase():"GET";throw new Wn({method:l,path:e,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function wc(){var t,n;const e=lr();return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function X(e){const t=await wi(e,{headers:cr()},Lc);if(!t.ok)throw new Wn({method:"GET",path:e,status:t.status,statusText:t.statusText});return t.json()}function zc(e){return new Promise(t=>setTimeout(t,e))}function Mc(e){const t=e.match(/\b(\d{3})\b/);if(!t)return null;const n=t[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function jc(e){if(e instanceof Wn)return e.timeout||typeof e.status=="number"&&go.has(e.status);if(!(e instanceof Error))return!1;if(/timeout after \d+ms/i.test(e.message))return!0;const t=Mc(e.message);return t!==null&&go.has(t)}async function ga(e,t,n=2){let s=0;for(;;)try{return await t()}catch(a){if(!jc(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${e} failed (attempt ${s+1}), retrying in ${o}ms`,a),await zc(o),s+=1}}async function Me(e,t,n,s=Ni){const a=await wi(e,{method:"POST",headers:{...dr(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new Wn({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.json()}async function Ec(e,t,n,s=Ni){const a=await wi(e,{method:"POST",headers:{...dr(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new Wn({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.text()}function Dc(e){const t=e.split(`
`).find(s=>s.startsWith("data: ")),n=t?t.slice(6).trim():e.trim();return JSON.parse(n)}function Oc(e){var t,n,s,a,o,l,c;if((t=e.error)!=null&&t.message)throw new Error(e.error.message);if((n=e.result)!=null&&n.isError){const p=((a=(s=e.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(p)}return((c=(l=(o=e.result)==null?void 0:o.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function ot(e,t){const n=await Ec("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:e,arguments:t},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Nc),s=Dc(n);return Oc(s)}function qc(){return X("/api/v1/dashboard/shell")}function Fc(){return X("/api/v1/dashboard/execution")}function Kc(e,t){const n=new URLSearchParams;return n.set("sort_by",e),t!=null&&t.excludeSystem&&n.set("exclude_system","true"),X(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function Uc(){return ga("fetchDashboardGovernance",async()=>{const e=await X("/api/v1/dashboard/governance"),t=Array.isArray(e.items)?e.items.map(o=>id(o)).filter(o=>o!==null):[],n=Array.isArray(e.pending_actions)?e.pending_actions.map(o=>mr(o)).filter(o=>o!==null):[],s=t.filter(o=>o.kind==="debate").map(o=>({id:o.id,topic:o.topic,status:o.status,argument_count:o.evidence_refs.length,created_at:o.last_activity_at??void 0})),a=t.filter(o=>o.kind==="consensus").map(o=>({id:o.id,topic:o.topic,initiator:o.related_agents[0]||"system",votes:o.votes??0,quorum:o.quorum??0,threshold:o.threshold,state:o.status,created_at:o.last_activity_at??void 0}));return{generated_at:oe(e.generated_at)??void 0,summary:m(e.summary)?{debates:ue(e.summary.debates)??void 0,voting_sessions:ue(e.summary.voting_sessions)??void 0,debates_open:ue(e.summary.debates_open)??void 0,sessions_active:ue(e.summary.sessions_active)??void 0,sessions_without_quorum:ue(e.summary.sessions_without_quorum)??void 0,ready_to_execute:ue(e.summary.ready_to_execute)??void 0,oldest_open_debate_age_s:typeof e.summary.oldest_open_debate_age_s=="number"?e.summary.oldest_open_debate_age_s:null,last_activity_age_s:typeof e.summary.last_activity_age_s=="number"?e.summary.last_activity_age_s:null,judge_online:typeof e.summary.judge_online=="boolean"?e.summary.judge_online:void 0,judge_last_seen_at:oe(e.summary.judge_last_seen_at)}:void 0,debates:s,sessions:a,items:t,activity:Array.isArray(e.activity)?e.activity.map(o=>od(o)).filter(o=>o!==null):[],judge:rd(e.judge),pending_actions:n}})}function Bc(){return X("/api/v1/dashboard/semantics")}function Hc(){return X("/api/v1/dashboard/mission")}function Wc(e){const t=`?session_id=${encodeURIComponent(e)}`;return X(`/api/v1/dashboard/session${t}`)}function Gc(e=!1){return X(`/api/v1/dashboard/mission/briefing${e?"?force=1":""}`)}function Jc(e,t){const n=new URLSearchParams;e&&n.set("session_id",e),t&&n.set("operation_id",t);const s=n.toString();return X(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function Vc(){return X("/api/v1/dashboard/planning")}function Qc(){return X("/api/v1/operator")}function ur(e={}){const t=new URLSearchParams;e.targetType&&t.set("target_type",e.targetType),e.targetId&&t.set("target_id",e.targetId),e.includeWorkers!=null&&t.set("include_workers",e.includeWorkers?"true":"false");const n=t.toString();return X(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Yc(){return X("/api/v1/command-plane")}function Xc(){return X("/api/v1/command-plane/summary")}function Zc(){return X("/api/v1/chains/summary")}function ed(e){return X(`/api/v1/chains/runs/${encodeURIComponent(e)}`)}function td(){return X("/api/v1/command-plane/help")}function nd(e,t){const n=new URLSearchParams;e&&n.set("run_id",e),t&&n.set("operation_id",t);const s=n.toString();return X(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function sd(e,t){return Me(e,t)}function ad(e){switch(e.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"swarm_run_continue":return 6e4;case"swarm_run_rerun":return 12e4;case"swarm_run_abandon":return 3e4;case"lodge_tick":return 45e3;default:return Ni}}function fa(e){return Me("/api/v1/operator/action",e,void 0,ad(e))}function pr(e,t,n="confirm"){return Me("/api/v1/operator/confirm",{actor:e,confirm_token:t,decision:n})}function xs(e){if(typeof e=="string"&&e.trim())return e;if(typeof e!="number"||Number.isNaN(e))return new Date().toISOString();const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}function oe(e){if(typeof e=="string"){const t=e.trim();return t||null}if(typeof e=="number"&&Number.isFinite(e)){const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}return null}function E(e){if(typeof e!="string")return null;const t=e.trim();return t||null}function mr(e){if(!m(e))return null;const t=k(e.confirm_token??e.token,"").trim();return t?{confirm_token:t,actor:E(e.actor)??void 0,action_type:E(e.action_type)??void 0,target_type:E(e.target_type)??void 0,target_id:E(e.target_id),delegated_tool:E(e.delegated_tool)??void 0,created_at:oe(e.created_at)??void 0,preview:e.preview}:null}function zi(e){return m(e)?{board_post_id:E(e.board_post_id),task_id:E(e.task_id),operation_id:E(e.operation_id),team_session_id:E(e.team_session_id)}:{}}function vr(e){if(!m(e))return null;const t=E(e.action_kind),n=E(e.resolved_tool),s=E(e.target_type),a=E(e.target_id),o=E(e.reason);return!t&&!n&&!s&&!o?null:{action_kind:t??void 0,resolved_tool:n,target_type:s,target_id:a,reason:o??void 0,payload_preview:e.payload_preview}}function _r(e){if(!m(e))return null;const t=E(e.action_type),n=E(e.delegated_tool),s=E(e.confirmation_state),a=oe(e.created_at);return!t&&!n&&!s&&!a?null:{action_type:t??void 0,delegated_tool:n,confirmation_state:s??void 0,created_at:a}}function gr(e){if(!m(e))return null;const t=mr(e.pending_confirm),n=E(e.pending_confirm_token)??(t==null?void 0:t.confirm_token)??null;return{requires_human_gate:typeof e.requires_human_gate=="boolean"?e.requires_human_gate:void 0,pending_confirm:t,pending_confirm_token:n,ready_to_execute:typeof e.ready_to_execute=="boolean"?e.ready_to_execute:void 0}}function fr(e){if(!m(e))return null;const t=E(e.summary),n=E(e.target_id);return!t&&!n?null:{judgment_id:E(e.judgment_id)??void 0,target_kind:E(e.target_kind)??void 0,target_id:n??void 0,status:E(e.status)??void 0,summary:t??void 0,confidence:typeof e.confidence=="number"?e.confidence:null,generated_at:oe(e.generated_at),expires_at:oe(e.expires_at),model_used:E(e.model_used),keeper_name:E(e.keeper_name),evidence_refs:Pe(e.evidence_refs),recommended_action:vr(e.recommended_action),guardrail_state:gr(e.guardrail_state),executed_route:_r(e.executed_route)}}function id(e){if(!m(e))return null;const t=k(e.id,"").trim(),n=k(e.topic,"").trim();if(!t||!n)return null;const s=zi(e.context);return{kind:k(e.kind,"debate"),id:t,topic:n,status:k(e.status??e.state,"open"),last_activity_at:oe(e.last_activity_at),truth_summary:E(e.truth_summary)??void 0,judgment_summary:E(e.judgment_summary),confidence:typeof e.confidence=="number"?e.confidence:null,related_agents:Pe(e.related_agents),context:s,linked_board_post_id:E(e.linked_board_post_id)??s.board_post_id??null,linked_task_id:E(e.linked_task_id)??s.task_id??null,linked_operation_id:E(e.linked_operation_id)??s.operation_id??null,linked_session_id:E(e.linked_session_id)??s.team_session_id??null,recommended_action:vr(e.recommended_action),executed_route:_r(e.executed_route),guardrail_state:gr(e.guardrail_state),evidence_refs:Pe(e.evidence_refs),approve_count:ue(e.approve_count),reject_count:ue(e.reject_count),abstain_count:ue(e.abstain_count),votes:ue(e.votes),quorum:ue(e.quorum),threshold:typeof e.threshold=="number"?e.threshold:void 0}}function od(e){if(!m(e))return null;const t=k(e.kind,"").trim();return t?{kind:t,item_kind:E(e.item_kind)??void 0,item_id:E(e.item_id)??void 0,topic:E(e.topic)??void 0,created_at:oe(e.created_at),summary:E(e.summary)??void 0,actor:E(e.actor),index:ue(e.index),decision:E(e.decision)}:null}function rd(e){if(m(e))return{judge_online:typeof e.judge_online=="boolean"?e.judge_online:void 0,refreshing:typeof e.refreshing=="boolean"?e.refreshing:void 0,generated_at:oe(e.generated_at),expires_at:oe(e.expires_at),model_used:E(e.model_used),keeper_name:E(e.keeper_name),last_error:E(e.last_error)}}function ld(e){var a;const t=e.trim(),s=((a=(t.startsWith("[flair:")?t.replace(/^\[flair:[^\]]+\]\s*/i,""):t).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function cd(e){if(!m(e))return null;const t=k(e.id,"").trim(),n=k(e.author,"").trim(),s=k(e.content,"").trim();if(!t||!n)return null;const a=U(e.score,0),o=U(e.votes_up,0),l=U(e.votes_down,0),c=U(e.votes,a||o-l),p=U(e.comment_count,U(e.reply_count,0)),u=(()=>{const $=e.flair;if(typeof $=="string"&&$.trim())return $.trim();if(m($)){const b=k($.name,"").trim();if(b)return b}return k(e.flair_name,"").trim()||void 0})(),_=k(e.created_at_iso,"").trim()||xs(e.created_at),g=k(e.updated_at_iso,"").trim()||(e.updated_at!==void 0?xs(e.updated_at):_),y=k(e.title,"").trim()||ld(s),S=Array.isArray(e.tags)?e.tags.filter($=>typeof $=="string"&&$.trim()!==""):[];return{id:t,author:n,post_kind:(()=>{const $=k(e.post_kind,"").trim().toLowerCase();return $==="automation"||$==="system"||$==="human"?$:void 0})(),title:y,content:s,tags:S,votes:c,vote_balance:a,comment_count:p,created_at:_,updated_at:g,flair:u,hearth:k(e.hearth,"").trim()||null,visibility:k(e.visibility,"").trim()||void 0,expires_at:k(e.expires_at_iso,"").trim()||(e.expires_at!==void 0&&e.expires_at!==0?xs(e.expires_at):"")||null,hearth_count:U(e.hearth_count,0)}}function dd(e){if(!m(e))return null;const t=k(e.id,"").trim(),n=k(e.post_id,"").trim(),s=k(e.author,"").trim();return!t||!s?null:{id:t,post_id:n,author:s,content:k(e.content,""),created_at:xs(e.created_at)}}async function ud(e){return ga("fetchBoardPost",async()=>{const t=await X(`/api/v1/board/${e}?format=flat`),n=m(t.post)?t.post:t,s=cd(n)??{id:e,author:"unknown",post_kind:"human",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(t.comments)?t.comments:[]).map(dd).filter(l=>l!==null);return{...s,comments:o}})}function $r(e,t){return Me("/api/v1/tools/masc_board_vote",{post_id:e,direction:t,vote:t,voter:wc()})}function pd(e,t,n){return Me("/api/v1/tools/masc_board_comment",{post_id:e,author:t,content:n})}function md(e){const t=k(e,"").trim().toLowerCase();if(t==="win"||t==="won"||t==="victory")return"victory";if(t==="lose"||t==="lost"||t==="defeat")return"defeat";if(t==="draw"||t==="stalemate"||t==="tie")return"draw"}function re(...e){for(const t of e){const n=k(t,"");if(n.trim())return n.trim()}return""}function fo(e){const t=md(re(e.outcome,e.result,e.result_code));if(!t)return;const n=re(e.reason,e.reason_code,e.description,e.detail),s=re(e.summary,e.summary_ko,e.summary_en,e.note),a=re(e.details,e.details_text,e.text,e.note),o=re(e.winner,e.winner_name,e.actor_winner,e.winner_actor),l=re(e.winner_actor_id,e.winner_actor,e.actor_winner_id),c=re(e.raw_reason,e.raw_reason_code,e.error_message),p=(()=>{const g=e.evidence??e.evidence_ids??e.supporting_events??e.event_ids??[];return typeof g=="string"?[g]:Array.isArray(g)?g.map(v=>{if(typeof v=="string")return v.trim();if(m(v)){const y=k(v.summary,"").trim();if(y)return y;const S=k(v.text,"").trim();if(S)return S;const $=k(v.type,"").trim();return $||k(v.event_id,"").trim()}return""}).filter(v=>v.length>0):[]})(),u=(()=>{const g=U(e.turn,Number.NaN);if(Number.isFinite(g))return g;const v=U(e.turn_number,Number.NaN);if(Number.isFinite(v))return v;const y=U(e.current_turn,Number.NaN);if(Number.isFinite(y))return y;const S=U(e.round,Number.NaN);return Number.isFinite(S)?S:void 0})(),_=re(e.phase,e.phase_name,e.current_phase,e.phase_id);return{result:t,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:l||void 0,evidence:p.length>0?p:void 0,raw_reason:c||void 0,turn:u,phase:_||void 0}}function vd(e,t){const n=m(e.state)?e.state:{};if(k(n.status,"active").toLowerCase()!=="ended")return;const a=[...t].reverse().find(l=>m(l)?k(l.type,"")==="session.outcome":!1),o=m(n.session_outcome)?n.session_outcome:{};if(m(o)&&Object.keys(o).length>0){const l=fo(o);if(l)return l}if(m(a))return fo(m(a.payload)?a.payload:{})}function k(e,t=""){return typeof e=="string"?e:t}function U(e,t=0){return typeof e=="number"&&Number.isFinite(e)?e:t}function ue(e){if(typeof e=="number"&&Number.isFinite(e))return Math.trunc(e);if(typeof e=="string"){const t=Number.parseInt(e.trim(),10);if(Number.isFinite(t))return t}}function Es(e,t=!1){return typeof e=="boolean"?e:t}function Pe(e){return Array.isArray(e)?e.map(t=>{if(typeof t=="string")return t.trim();if(m(t)){const n=k(t.name,"").trim(),s=k(t.id,"").trim(),a=k(t.skill,"").trim();return n||s||a}return""}).filter(t=>t.length>0):[]}function _d(e){const t={};if(!m(e)&&!Array.isArray(e))return t;if(m(e))return Object.entries(e).forEach(([n,s])=>{const a=n.trim(),o=k(s,"").trim();!a||!o||(t[a]=o)}),t;for(const n of e){if(!m(n))continue;const s=re(n.to,n.target,n.actor_id,n.name,n.id),a=re(n.relationship,n.relation,n.type,n.kind);!s||!a||(t[s]=a)}return t}function gd(e,t,n){if(e==="dm"||e==="player"||e==="npc")return e;const s=t.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function ye(e,t,n,s=0){const a=e[t];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=e[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const fd=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function $d(e){const t=m(e.stats)?e.stats:{},n={};return Object.entries(t).forEach(([s,a])=>{const o=s.trim();o&&(fd.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function hd(e,t){if(e!=="dice.rolled")return;const n=U(t.raw_d20,0),s=U(t.total,0),a=U(t.bonus,0),o=k(t.action,"roll"),l=U(t.dc,0);return{notation:l>0?`${o} (DC ${l})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function yd(e){const t=JSON.stringify(e);return t?t.length>160?`${t.slice(0,157)}...`:t:""}function bd(e){const t=e.trim().toLowerCase();return t?t.startsWith("dice.")?"dice":t.startsWith("combat.")||t.includes(".attack")||t.includes(".damage")?"combat":t.includes("actor.")?"actor":t.includes("turn.")||t==="turn.started"||t==="phase.changed"?"turn":t.includes("join.")?"join":t.includes("memory")?"memory":t.includes("world.")?"world":t.includes("narration")?"story":"meta":"meta"}function kd(e,t,n,s){const a=n||t||k(s.actor_id,"")||k(s.actor_name,"");switch(e){case"turn.action.proposed":{const o=k(s.proposed_action,k(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=k(s.reply,k(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return k(s.reply,k(s.content,k(s.text,"Narration")));case"dice.rolled":{const o=k(s.action,"roll"),l=U(s.total,0),c=U(s.dc,0),p=k(s.label,""),u=a||"actor",_=c>0?` vs DC ${c}`:"",g=p?` (${p})`:"";return`${u} ${o}: ${l}${_}${g}`}case"turn.started":return`Turn ${U(s.turn,1)} started`;case"phase.changed":return`Phase: ${k(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${k(s.name,m(s.actor)?k(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${k(s.keeper_name,k(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${k(s.keeper_name,k(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${U(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${U(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||k(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||k(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${k(s.reason_code,"unknown")}`;case"memory.signal":{const o=m(s.entity_refs)?s.entity_refs:{},l=k(o.requested_tier,""),c=k(o.effective_tier,""),p=Es(o.guardrail_applied,!1),u=k(s.summary_en,k(s.summary_ko,"Memory signal"));if(!l&&!c)return u;const _=l&&c?`${l}->${c}`:c||l;return`${u} [${_}${p?" (guardrail)":""}]`}case"world.event":{if(k(s.event_type,"")==="canon.check"){const l=k(s.status,"unknown"),c=k(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return k(s.description,k(s.summary,"World event"))}case"combat.attack":return k(s.summary,k(s.result,"Attack resolved"));case"combat.defense":return k(s.summary,k(s.result,"Defense resolved"));case"session.outcome":return k(s.summary,k(s.outcome,"Session ended"));default:{const o=yd(s);return o?`${e}: ${o}`:e}}}function xd(e,t){const n=m(e)?e:{},s=k(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=k(n.actor_name,"").trim()||t[a]||k(m(n.payload)?n.payload.actor_name:"",""),l=m(n.payload)?n.payload:{},c=k(n.ts,k(n.timestamp,new Date().toISOString())),p=k(n.phase,k(l.phase,"")),u=k(n.category,"");return{type:s,actor:o||a||k(l.actor_name,""),actor_id:a||k(l.actor_id,""),actor_name:o,seq:n.seq,room_id:k(n.room_id,""),phase:p||void 0,category:u||bd(s),visibility:k(n.visibility,k(l.visibility,"public")),event_id:k(n.event_id,""),content:kd(s,a,o,l),dice_roll:hd(s,l),timestamp:c}}function Sd(e,t,n){var te,ne;const s=k(e.room_id,"")||n||"default",a=m(e.state)?e.state:{},o=m(a.party)?a.party:{},l=m(a.actor_control)?a.actor_control:{},c=m(a.join_gate)?a.join_gate:{},p=m(a.contribution_ledger)?a.contribution_ledger:{},u=Object.entries(o).map(([G,Z])=>{const x=m(Z)?Z:{},Se=ye(x,"max_hp",void 0,10),Be=ye(x,"hp",void 0,Se),dt=ye(x,"max_mp",void 0,0),ut=ye(x,"mp",void 0,0),F=ye(x,"level",void 0,1),Ae=ye(x,"xp",void 0,0),pt=Es(x.alive,Be>0),ln=l[G],cn=typeof ln=="string"?ln:void 0,ts=gd(x.role,G,cn),ns=ue(x.generation),ss=re(x.joined_at,x.joinedAt,x.started_at,x.startedAt),as=re(x.claimed_at,x.claimedAt,x.assigned_at,x.assignedAt,x.assigned_time),is=re(x.last_seen,x.lastSeen,x.last_seen_at,x.lastSeenAt,x.last_active,x.lastActive),os=re(x.scene,x.current_scene,x.currentScene,x.world_scene,x.scene_name,x.sceneName),rs=re(x.location,x.current_location,x.currentLocation,x.position,x.zone,x.area);return{id:G,name:k(x.name,G),role:ts,keeper:cn,archetype:k(x.archetype,""),persona:k(x.persona,""),portrait:k(x.portrait,"")||void 0,background:k(x.background,"")||void 0,traits:Pe(x.traits),skills:Pe(x.skills),stats_raw:$d(x),status:pt?"active":"dead",generation:ns,joined_at:ss||void 0,claimed_at:as||void 0,last_seen:is||void 0,scene:os||void 0,location:rs||void 0,inventory:Pe(x.inventory),notes:Pe(x.notes),relationships:_d(x.relationships),stats:{hp:Be,max_hp:Se,mp:ut,max_mp:dt,level:F,xp:Ae,strength:ye(x,"strength","str",10),dexterity:ye(x,"dexterity","dex",10),constitution:ye(x,"constitution","con",10),intelligence:ye(x,"intelligence","int",10),wisdom:ye(x,"wisdom","wis",10),charisma:ye(x,"charisma","cha",10)}}}),_=u.filter(G=>G.status!=="dead"),g=vd(e,t),v={phase_open:Es(c.phase_open,!0),min_points:U(c.min_points,3),window:k(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},y=Object.entries(p).map(([G,Z])=>{const x=m(Z)?Z:{};return{actor_id:G,score:U(x.score,0),last_reason:k(x.last_reason,"")||null,reasons:Pe(x.reasons)}}),S=u.reduce((G,Z)=>(G[Z.id]=Z.name,G),{}),$=t.map(G=>xd(G,S)),A=U(a.turn,1),b=k(a.phase,"round"),I=k(a.map,""),R=m(a.world)?a.world:{},T=I||k(R.ascii_map,k(R.map,"")),P=$.filter((G,Z)=>{const x=t[Z];if(!m(x))return!1;const Se=m(x.payload)?x.payload:{};return U(Se.turn,-1)===A}),L=(P.length>0?P:$).slice(-12),K=k(a.status,"active");return{session:{id:s,room:s,status:K==="ended"?"ended":K==="paused"?"paused":"active",round:A,actors:_,created_at:((te=$[0])==null?void 0:te.timestamp)??new Date().toISOString()},current_round:{round_number:A,phase:b,events:L,timestamp:((ne=$[$.length-1])==null?void 0:ne.timestamp)??new Date().toISOString()},map:T||void 0,join_gate:v,contribution_ledger:y,outcome:g,party:_,story_log:$,history:[]}}async function Ad(e){const t=`?room_id=${encodeURIComponent(e)}`,n=await X(`/api/v1/trpg/events${t}`);return Array.isArray(n.events)?n.events:[]}async function Cd(e){const t=`?room_id=${encodeURIComponent(e)}`,[n,s]=await Promise.all([X(`/api/v1/trpg/state${t}`),Ad(e)]);return Sd(n,s,e)}function Id(e){return Me("/api/v1/trpg/rounds/run",{room_id:e})}function Td(e){const t="".trim().toLowerCase();if(t)switch(t){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return t}}function Rd(e){const t={room_id:e.roomId,actor_id:e.actorId,action:e.action,stat_value:e.statValue,dc:e.dc};return e.rawD20!=null&&(t.raw_d20=e.rawD20),e.ruleModule&&(t.rule_module=e.ruleModule),Me("/api/v1/trpg/dice/roll",t)}function Pd(e,t){const n=Td();return Me("/api/v1/trpg/turns/advance",{room_id:e,...n?{phase:n}:{}})}function Ld(e,t){var a;const n=(a=t.idempotencyKey)==null?void 0:a.trim(),s={room_id:e};return t.actor_id&&t.actor_id.trim()&&(s.actor_id=t.actor_id.trim()),t.name&&t.name.trim()&&(s.name=t.name.trim()),t.role&&(s.role=t.role),t.archetype&&t.archetype.trim()&&(s.archetype=t.archetype.trim()),t.persona&&t.persona.trim()&&(s.persona=t.persona.trim()),t.portrait&&t.portrait.trim()&&(s.portrait=t.portrait.trim()),t.background&&t.background.trim()&&(s.background=t.background.trim()),t.hp!=null&&(s.hp=t.hp),t.max_hp!=null&&(s.max_hp=t.max_hp),t.alive!=null&&(s.alive=t.alive),Array.isArray(t.traits)&&t.traits.length>0&&(s.traits=t.traits),Array.isArray(t.skills)&&t.skills.length>0&&(s.skills=t.skills),Array.isArray(t.inventory)&&t.inventory.length>0&&(s.inventory=t.inventory),t.stats&&Object.keys(t.stats).length>0&&(s.stats=t.stats),n&&(s.idempotency_key=n),Me("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function Nd(e,t,n){return Me("/api/v1/trpg/actors/claim",{room_id:e,actor_id:t,keeper:n})}async function wd(e,t,n){const s=await ot("trpg.join.eligibility",{room_id:e,actor_id:t,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function zd(e){const t=await ot("trpg.mid_join.request",e);return JSON.parse(t)}async function Md(e,t){await ot("masc_broadcast",{agent_name:e,message:t})}async function jd(e=40){return(await ot("masc_messages",{limit:e})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Ed(e,t=20){return ot("masc_task_history",{task_id:e,limit:t})}async function Dd(e){const t=await ot("masc_debate_start",{topic:e});try{return JSON.parse(t)}catch{return null}}async function Od(e){return ga("fetchDebateStatus",async()=>{const t=encodeURIComponent(e),n=await X(`/api/v1/council/debates/${t}/summary`);if(!m(n))return null;const s=m(n.debate)?n.debate:n,a=k(s.id,"").trim(),o=k(s.topic,"").trim();return!a||!o?null:{debate:{id:a,topic:o,status:k(s.status,"open"),created_at:oe(s.created_at_iso??s.created_at),closed_at:oe(s.closed_at)},arguments:Array.isArray(n.arguments)?n.arguments.flatMap(l=>m(l)?[{index:U(l.index,0),agent:k(l.agent,"unknown"),position:k(l.position,"neutral"),content:k(l.content,""),evidence:Pe(l.evidence),reply_to:ue(l.reply_to)??null,mentions:Pe(l.mentions),archetype:E(l.archetype),created_at:oe(l.created_at)}]:[]):[],summary:{support_count:m(n.summary)?U(n.summary.support_count,0):U(n.support_count,0),oppose_count:m(n.summary)?U(n.summary.oppose_count,0):U(n.oppose_count,0),neutral_count:m(n.summary)?U(n.summary.neutral_count,0):U(n.neutral_count,0),total_arguments:m(n.summary)?U(n.summary.total_arguments,0):U(n.total_arguments,0),summary_text:m(n.summary)?k(n.summary.summary_text,""):k(n.summary_text,"")},context:zi(n.context),judgment:fr(n.judgment)}})}async function qd(e){return ga("fetchConsensusSessionSummary",async()=>{const t=encodeURIComponent(e),n=await X(`/api/v1/council/sessions/${t}/summary`);if(!m(n)||!m(n.session))return null;const s=n.session,a=k(s.id,"").trim(),o=k(s.topic,"").trim();return!a||!o?null:{session:{id:a,topic:o,state:k(s.state,"open"),initiator:k(s.initiator,"system"),quorum:U(s.quorum,0),threshold:U(s.threshold,0),created_at:oe(s.created_at),closed_at:oe(s.closed_at)},votes:Array.isArray(n.votes)?n.votes.flatMap(l=>m(l)?[{agent:k(l.agent,"unknown"),decision:k(l.decision,"abstain"),reason:k(l.reason,""),timestamp:oe(l.timestamp),weight:typeof l.weight=="number"?l.weight:void 0,archetype:E(l.archetype)}]:[]):[],summary:{approve_count:m(n.summary)?U(n.summary.approve_count,0):0,reject_count:m(n.summary)?U(n.summary.reject_count,0):0,abstain_count:m(n.summary)?U(n.summary.abstain_count,0):0,quorum_met:m(n.summary)?Es(n.summary.quorum_met,!1):!1,result:m(n.summary)?E(n.summary.result):null},context:zi(n.context),judgment:fr(n.judgment)}})}function Fd(e,t,n){return ot("masc_keeper_msg",{name:e,message:t})}const Kd=f(""),Fe=f({}),le=f({}),oi=f({}),ri=f({}),li=f({}),ci=f({}),Ke=f({});function ae(e,t,n){e.value={...e.value,[t]:n}}function Ud(e){var n;const t=(n=r(e))==null?void 0:n.toLowerCase();return t==="user"||t==="assistant"||t==="system"||t==="tool"?t:"other"}function Bd(e){switch(e){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Ia(e,t){if(!Array.isArray(e))return[];const n=[];for(const s of e){if(!m(s))continue;const a=r(s.name);if(!a)continue;const o=r(s[t]);t==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function Hd(e){if(!m(e))return null;const t=r(e.name);return t?{name:t,trigger:r(e.trigger),outcome:r(e.outcome),summary:r(e.summary),reason:r(e.reason)}:null}function Wd(e){const t=e.toLowerCase();return t.includes("graphql")?"graphql_error":t.includes("timeout")||t.includes("model")||t.includes("llm")||t.includes("api key")||t.includes("api_key")||t.includes("provider")?"llm_error":"unknown"}function Gd(e,t){return e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":t==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":t==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":t==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function hr(e,t,n){return r(e)??Gd(t,n)}function yr(e,t){return typeof e=="boolean"?e:t==="recover"}function Ds(e){if(!m(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);return!t||!n||!s?null:{health_state:t,quiet_reason:r(e.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:st(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:yr(e.recoverable,n),summary:hr(e.summary,t,r(e.quiet_reason)??null),keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function br(e){return m(e)?{hour:d(e.hour),checked:d(e.checked)??0,acted:d(e.acted)??0,acted_names:H(e.acted_names),activity_report:r(e.activity_report),quiet_hours_overridden:j(e.quiet_hours_overridden),skipped_reason:r(e.skipped_reason),acted_rows:Ia(e.acted_rows,"summary").map(t=>({name:t.name,summary:t.summary})),passed_rows:Ia(e.passed_rows,"reason").map(t=>({name:t.name,reason:t.reason})),skipped_rows:Ia(e.skipped_rows,"reason").map(t=>({name:t.name,reason:t.reason})),checkins:Array.isArray(e.checkins)?e.checkins.map(Hd).filter(t=>t!==null):[]}:null}function Jd(e){return m(e)?{enabled:j(e.enabled)??!1,interval_s:d(e.interval_s)??0,quiet_start:d(e.quiet_start),quiet_end:d(e.quiet_end),quiet_active:j(e.quiet_active),use_planner:j(e.use_planner),delegate_llm:j(e.delegate_llm),agent_count:d(e.agent_count),agents:H(e.agents),last_tick_ago_s:d(e.last_tick_ago_s)??null,last_tick_ago:r(e.last_tick_ago),total_ticks:d(e.total_ticks),total_checkins:d(e.total_checkins),last_skip_reason:r(e.last_skip_reason)??null,last_tick_result:br(e.last_tick_result),active_self_heartbeats:H(e.active_self_heartbeats)}:null}function Vd(e){return m(e)?{status:e.status,diagnostic:Ds(e.diagnostic)}:null}function Qd(e){return m(e)?{recovered:j(e.recovered)??!1,skipped_reason:r(e.skipped_reason)??null,before:Ds(e.before),after:Ds(e.after),down:e.down,up:e.up}:null}function Yd(e,t){var I,R;if(!(e!=null&&e.name))return null;const n=r((I=e.agent)==null?void 0:I.status)??r(e.status)??"unknown",s=r((R=e.agent)==null?void 0:R.error)??null,a=e.presence_keepalive??!0,o=e.keepalive_running??!1,l=e.turn_count??0,c=e.last_turn_ago_s??null,p=e.proactive_enabled??!1,u=e.proactive_cooldown_sec??0,_=e.last_proactive_ago_s??null,g=p&&_!=null?Math.max(0,u-_):null,v=l<=0||c==null?"never":c>900?"stale":"fresh",y=typeof e.last_heartbeat=="string"&&e.last_heartbeat.trim()?e.last_heartbeat:null,S=s??(a&&!o?"keeper keepalive is not running":null),$=n==="offline"||n==="inactive"?"offline":S?"degraded":v==="stale"?"stale":v==="never"?"idle":"healthy",A=S?Wd(S):t!=null&&t.quiet_active&&v!=="fresh"?"quiet_hours":a&&!o?"disabled":l<=0?"never_started":g!=null&&g>0?"min_gap":v==="fresh"||v==="stale"?"no_recent_activity":"unknown",b=$==="offline"||$==="degraded"||$==="stale"?"recover":A==="quiet_hours"?"manual_lodge_poke":A==="unknown"?"probe":"direct_message";return{health_state:$,quiet_reason:A,next_action_path:b,last_reply_status:v,last_reply_at:y,last_reply_preview:null,last_error:S,next_eligible_at_s:g!=null&&g>0?g:null,recoverable:yr(void 0,b),summary:hr(void 0,$,A),keepalive_running:o}}function Xd(e,t){if(!m(e))return null;const n=Ud(e.role),s=r(e.content)??r(e.preview);if(!s)return null;const a=st(e.ts_unix)??st(e.timestamp);return{id:`${n}-${a??"entry"}-${t}`,role:n,label:Bd(n),text:s,timestamp:a,delivery:"history"}}function Zd(e,t,n){const s=m(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,l)=>Xd(o,l)).filter(o=>o!==null):[];return{name:e,diagnostic:Ds(s==null?void 0:s.diagnostic),history:a,rawText:t,rawStatus:n,loadedAt:new Date().toISOString()}}function $o(e,t){const n=le.value[e]??[];le.value={...le.value,[e]:[...n,t].slice(-50)}}function eu(e,t){return e.role!==t.role||e.text!==t.text?!1:e.timestamp&&t.timestamp?e.timestamp===t.timestamp:!0}function tu(e,t){const s=(le.value[e]??[]).filter(a=>a.delivery!=="history"&&!t.some(o=>eu(a,o)));le.value={...le.value,[e]:[...t,...s].slice(-50)}}function $a(e,t){Fe.value={...Fe.value,[e]:t},tu(e,t.history)}function ho(e,t){const n=Fe.value[e];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};$a(e,{...n,diagnostic:{...s,...t}})}async function Mi(){try{await Gn()}catch(e){console.warn("[keeper-runtime] dashboard refresh failed",e)}}function nu(e){Kd.value=e.trim()}async function kr(e,t=!1){const n=e.trim();if(!n)return null;if(!t&&Fe.value[n])return Fe.value[n];ae(oi,n,!0),ae(Ke,n,null);try{const s=await ot("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=Zd(n,s,a);return $a(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return ae(Ke,n,a),null}finally{ae(oi,n,!1)}}async function su(e,t){const n=e.trim(),s=t.trim();if(!n||!s)return;const a=`local-${Date.now()}`;$o(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),ae(ri,n,!0),ae(Ke,n,null);try{const o=await Fd(n,s);le.value={...le.value,[n]:(le.value[n]??[]).map(l=>l.id===a?{...l,delivery:"delivered"}:l)},$o(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),ho(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await Mi()}catch(o){const l=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw le.value={...le.value,[n]:(le.value[n]??[]).map(c=>c.id===a?{...c,delivery:"error",error:l}:c)},ho(n,{last_reply_status:"error",last_error:l}),ae(Ke,n,l),o}finally{ae(ri,n,!1)}}async function au(e,t){const n=e.trim();if(!n)return null;ae(li,n,!0),ae(Ke,n,null);try{const s=await fa({actor:t,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=Vd(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const l=Fe.value[n];$a(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??le.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Mi(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw ae(Ke,n,a),s}finally{ae(li,n,!1)}}async function iu(e,t){const n=e.trim();if(!n)return null;ae(ci,n,!0),ae(Ke,n,null);try{const s=await fa({actor:t,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Qd(s.result),o=(a==null?void 0:a.after)??null;if(o){const l=Fe.value[n];$a(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??le.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await Mi(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw ae(Ke,n,a),s}finally{ae(ci,n,!1)}}function mt(e){return(e??"").trim().toLowerCase()}function ve(e){const t=typeof e=="number"?e:Date.parse(e);return Number.isNaN(t)?0:t}function Ss(e,t=88){const n=e.replace(/\s+/g," ").trim();return n&&(n.length>t?`${n.slice(0,t-3)}...`:n)}function cs(e){return typeof e!="number"||!Number.isFinite(e)||e<0?null:new Date(Date.now()-e*1e3).toISOString()}function dn(e){return e.last_heartbeat??cs(e.last_turn_ago_s)??cs(e.last_proactive_ago_s)??cs(e.last_handoff_ago_s)??cs(e.last_compaction_ago_s)}function ou(e){const t=e.title.trim();return t||Ss(e.content)}function ru(e){const t=e.generation??"?",n=typeof e.context_ratio=="number"&&Number.isFinite(e.context_ratio)?`${Math.round(e.context_ratio*100)}%`:"?";return e.last_heartbeat?`Heartbeat gen=${t} ctx=${n}`:`Keeper snapshot gen=${t} ctx=${n}`}function lu(e,t,n,s,a={}){var R;const o=mt(e),l=t.filter(T=>mt(T.assignee)===o&&(T.status==="claimed"||T.status==="in_progress")).length,c=n.filter(T=>mt(T.from)===o).sort((T,P)=>ve(P.timestamp)-ve(T.timestamp))[0],p=s.filter(T=>mt(T.agent)===o||mt(T.author)===o).sort((T,P)=>ve(P.timestamp)-ve(T.timestamp))[0],u=(a.boardPosts??[]).filter(T=>mt(T.author)===o).sort((T,P)=>ve(P.updated_at||P.created_at)-ve(T.updated_at||T.created_at))[0],_=(a.keepers??[]).filter(T=>mt(T.name)===o&&dn(T)!==null).sort((T,P)=>ve(dn(P)??0)-ve(dn(T)??0))[0],g=c?ve(c.timestamp):0,v=p?ve(p.timestamp):0,y=u?ve(u.updated_at||u.created_at):0,S=_?ve(dn(_)??0):0,$=a.lastSeen?ve(a.lastSeen):0,A=((R=a.currentTask)==null?void 0:R.trim())||(l>0?`${l} claimed tasks`:null);if(g===0&&v===0&&y===0&&S===0&&$===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:A};const I=[c?{timestamp:c.timestamp,ts:g,text:Ss(c.content)}:null,u?{timestamp:u.updated_at||u.created_at,ts:y,text:`Post: ${Ss(ou(u))}`}:null,_?{timestamp:dn(_),ts:S,text:ru(_)}:null,p?{timestamp:new Date(p.timestamp).toISOString(),ts:v,text:Ss(p.text)}:null].filter(T=>T!==null).sort((T,P)=>P.ts-T.ts)[0];return I&&I.ts>=$?{activeAssignedCount:l,lastActivityAt:I.timestamp,lastActivityText:I.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:A??"Presence heartbeat"}}const Ue=f([]),Qe=f([]),di=f([]),rt=f([]),ie=f(null),cu=f(null),xr=f(null),Sr=f([]),Ar=f([]),Cr=f([]),Ir=f([]),Tr=f([]),Rr=f([]),ui=f(new Map),Cn=f([]),In=f("recent"),wt=f(!0),Pr=f(null),qe=f(""),Kt=f([]),_n=f(!1),Lr=f(new Map),ji=f("unknown"),Ut=f(null),pi=f(!1),Tn=f(!1),mi=f(!1),gn=f(!1),Ei=f(null),Os=f(!1),qs=f(null),Nr=f(null),vi=f(null),du=f(null),uu=f(null),pu=f(null);xe(()=>Ue.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle"));const wr=xe(()=>{const e=Qe.value;return{todo:e.filter(t=>t.status==="todo"),inProgress:e.filter(t=>t.status==="in_progress"||t.status==="claimed"),done:e.filter(t=>t.status==="done")}}),zr=xe(()=>{const e=new Map,t=Qe.value,n=di.value,s=js.value,a=Cn.value,o=rt.value;for(const l of Ue.value)e.set(l.name.trim().toLowerCase(),lu(l.name,t,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:o}));return e});function mu(e){var o;const t=((o=e.status)==null?void 0:o.toLowerCase())??"";if(t==="offline"||t==="inactive")return"offline";const n=e.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}xe(()=>{const e=new Map;for(const t of rt.value)e.set(t.name,mu(t));return e});const vu=12e4;function _u(e,t){const n=t.get(e.name);if(n!=null)return n;const s=e.last_heartbeat?Date.parse(e.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[e.last_turn_ago_s,e.last_proactive_ago_s,e.last_handoff_ago_s,e.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}xe(()=>{const e=Date.now(),t=new Set,n=ui.value;for(const s of rt.value){const a=_u(s,n);a!=null&&e-a>vu&&t.add(s.name)}return t});function gu(e){return e==="dashboard_refresh"||e==="masc/dashboard_refresh"||e.startsWith("goal_")||e.startsWith("masc/goal_")||e.startsWith("mdal_")||e.startsWith("masc/mdal_")||e.startsWith("operator_")||e.startsWith("masc/operator_")||e.startsWith("command_plane_")||e.startsWith("masc/command_plane_")}function Mr(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="active"||t==="busy"||t==="listening"||t==="idle"||t==="inactive"||t==="offline"?t:t==="in_progress"||t==="claimed"?"busy":"offline"}function fu(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="todo"||t==="in_progress"||t==="claimed"||t==="done"||t==="cancelled"?t:t==="inprogress"?"in_progress":"todo"}function $u(e){if(!m(e))return null;const t=r(e.name);return t?{name:t,agent_type:r(e.agent_type),status:Mr(e.status),current_task:r(e.current_task)??null,joined_at:r(e.joined_at),last_seen:r(e.last_seen),capabilities:H(e.capabilities),emoji:r(e.emoji),koreanName:r(e.koreanName)??r(e.korean_name),model:r(e.model),traits:H(e.traits),interests:H(e.interests),activityLevel:d(e.activityLevel)??d(e.activity_level),primaryValue:r(e.primaryValue)??r(e.primary_value)}:null}function hu(e){if(!m(e))return null;const t=r(e.id),n=r(e.title);return!t||!n?null:{id:t,title:n,status:fu(e.status),priority:d(e.priority),assignee:r(e.assignee),description:r(e.description),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function yu(e){if(!m(e))return null;const t=r(e.from)??r(e.from_agent)??"system",n=r(e.content)??"",s=r(e.timestamp)??new Date().toISOString();return{id:r(e.id),seq:d(e.seq),from:t,content:n,timestamp:s,type:r(e.type)}}function Di(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="ok"||t==="warn"||t==="bad"?t:"ok"}function bu(e){return m(e)?{active_sessions:d(e.active_sessions),blocked_sessions:d(e.blocked_sessions),active_operations:d(e.active_operations),blocked_operations:d(e.blocked_operations),runtime_pressure:d(e.runtime_pressure),worker_alerts:d(e.worker_alerts),continuity_alerts:d(e.continuity_alerts),priority_items:d(e.priority_items),todo_tasks:d(e.todo_tasks),claimed_tasks:d(e.claimed_tasks),running_tasks:d(e.running_tasks),done_tasks:d(e.done_tasks),cancelled_tasks:d(e.cancelled_tasks),keepers:d(e.keepers)}:null}function Ye(e){if(!m(e))return null;const t=r(e.surface),n=r(e.label),s=r(e.target_type),a=r(e.target_id),o=r(e.focus_kind);return!t||!n||!s||!a||!o?null:{surface:t==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:o,operation_id:r(e.operation_id)??null,command_surface:r(e.command_surface)??null}}function ku(e){if(!m(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.summary),a=r(e.target_type),o=r(e.target_id);return!t||!s||!a||!o||n!=="session"&&n!=="operation"?null:{id:t,kind:n,severity:Di(e.severity),status:r(e.status),summary:s,target_type:a,target_id:o,linked_session_id:r(e.linked_session_id)??null,linked_operation_id:r(e.linked_operation_id)??null,last_seen_at:r(e.last_seen_at)??null,top_handoff:Ye(e.top_handoff),intervene_handoff:Ye(e.intervene_handoff),command_handoff:Ye(e.command_handoff)}}function xu(e){if(!m(e))return null;const t=r(e.session_id),n=r(e.goal);return!t||!n?null:{session_id:t,goal:n,room:r(e.room)??null,status:r(e.status),health:r(e.health),member_names:H(e.member_names),linked_operation_id:r(e.linked_operation_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,runtime_blocker:r(e.runtime_blocker)??null,worker_gap_summary:r(e.worker_gap_summary)??null,last_activity_at:r(e.last_activity_at)??null,last_activity_summary:r(e.last_activity_summary)??null,communication_summary:r(e.communication_summary)??null,active_count:d(e.active_count),required_count:d(e.required_count),top_handoff:Ye(e.top_handoff),intervene_handoff:Ye(e.intervene_handoff),command_handoff:Ye(e.command_handoff)}}function Su(e){if(!m(e))return null;const t=r(e.operation_id),n=r(e.objective);return!t||!n?null:{operation_id:t,objective:n,status:r(e.status),stage:r(e.stage)??null,assigned_unit_id:r(e.assigned_unit_id)??null,assigned_unit_label:r(e.assigned_unit_label)??null,linked_session_id:r(e.linked_session_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,blocker_summary:r(e.blocker_summary)??null,search_status:r(e.search_status)??null,next_tool:r(e.next_tool)??null,updated_at:r(e.updated_at)??null,top_handoff:Ye(e.top_handoff),command_handoff:Ye(e.command_handoff)}}function yo(e){if(!m(e))return null;const t=r(e.name)??r(e.agent_name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline"?null:{name:t,agent_name:r(e.agent_name),status:r(e.status),tone:Di(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,active_task_count:d(e.active_task_count),related_session_id:r(e.related_session_id)??null,related_operation_id:r(e.related_operation_id)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),model:r(e.model)??null,recent_output_preview:r(e.recent_output_preview)??null,recent_event:r(e.recent_event)??null}}function Au(e){if(!m(e))return null;const t=r(e.name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:t,agent_name:r(e.agent_name)??null,status:r(e.status),tone:Di(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,last_autonomous_action_at:r(e.last_autonomous_action_at)??null,generation:d(e.generation),turn_count:d(e.turn_count),context_ratio:d(e.context_ratio)??null,continuity:r(e.continuity)??null,lifecycle:r(e.lifecycle)??null,related_session_id:r(e.related_session_id)??null,model:r(e.model)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),skill_reason:r(e.skill_reason)??null}}function bo(e){if(typeof e.seq=="number"&&Number.isFinite(e.seq))return e.seq;const t=Date.parse(e.timestamp);return Number.isNaN(t)?0:t}function Cu(e,t){if(t.length===0)return e;const n=new Map;for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>bo(s)-bo(a)).slice(-500)}function Iu(e){return Array.isArray(e)?e.map(t=>{if(!m(t))return null;const n=d(t.ts_unix);if(n==null)return null;const s=m(t.handoff)?t.handoff:null;return{ts:n,context_ratio:d(t.context_ratio)??0,context_tokens:d(t.context_tokens)??0,context_max:d(t.context_max)??0,latency_ms:d(t.latency_ms)??0,generation:d(t.generation)??0,channel:typeof t.channel=="string"?t.channel:"turn",is_handoff:s!=null&&t.handoff_performed===!0,is_compaction:t.compacted===!0,compaction_saved_tokens:d(t.compaction_saved_tokens)??0,compaction_trigger:typeof t.compaction_trigger=="string"?t.compaction_trigger:null,model_used:typeof t.model_used=="string"?t.model_used:"",cost_usd:d(t.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?d(s.new_generation)??null:null}}).filter(t=>t!==null):[]}function ko(e){if(!m(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);if(!t||!n||!s)return null;const a=r(e.quiet_reason)??null,o=r(e.summary)??(t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:t,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:st(e.last_reply_at)??r(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:typeof e.recoverable=="boolean"?e.recoverable:n==="recover",summary:o,keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function Tu(e,t){return(Array.isArray(e)?e:m(e)&&Array.isArray(e.keepers)?e.keepers:[]).map(s=>{if(!m(s))return null;const a=m(s.agent)?s.agent:null,o=m(s.context)?s.context:null,l=m(s.metrics_window)?s.metrics_window:void 0,c=r(s.name);if(!c)return null;const p=d(s.context_ratio)??d(o==null?void 0:o.context_ratio),u=r(s.status)??r(a==null?void 0:a.status)??"offline",_=Mr(u),g=r(s.model)??r(s.active_model)??r(s.primary_model),v=H(s.skill_secondary),y=o?{source:r(o.source),context_ratio:d(o.context_ratio),context_tokens:d(o.context_tokens),context_max:d(o.context_max),message_count:d(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,S=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:d(a.last_seen_ago_s),capabilities:H(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,$=Iu(s.metrics_series),A={name:c,runtime_class:s.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:typeof s.desired=="boolean"?s.desired:void 0,resident_registered:typeof s.resident_registered=="boolean"?s.resident_registered:void 0,reconcile_status:r(s.reconcile_status)??null,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:g,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:_,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:d(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:d(s.proactive_idle_sec),proactive_cooldown_sec:d(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:d(s.generation),turn_count:d(s.turn_count)??d(s.total_turns),keeper_age_s:d(s.keeper_age_s),last_turn_ago_s:d(s.last_turn_ago_s),last_handoff_ago_s:d(s.last_handoff_ago_s),last_compaction_ago_s:d(s.last_compaction_ago_s),last_proactive_ago_s:d(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:p,context_tokens:d(s.context_tokens)??d(o==null?void 0:o.context_tokens),context_max:d(s.context_max)??d(o==null?void 0:o.context_max),context_source:r(s.context_source)??r(o==null?void 0:o.source),context:y,traits:H(s.traits),interests:H(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:d(s.activityLevel)??d(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:H(s.recent_tool_names)??[],conversation_tail_count:d(s.conversation_tail_count),k2k_count:d(s.k2k_count),handoff_count_total:d(s.handoff_count_total)??d(s.trace_history_count),compaction_count:d(s.compaction_count),last_compaction_saved_tokens:d(s.last_compaction_saved_tokens),diagnostic:ko(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:v,skill_reason:r(s.skill_reason)??null,metrics_series:$.length>0?$:void 0,metrics_window:l,agent:S};return A.diagnostic=ko(s.diagnostic)??Yd(A,(t==null?void 0:t.lodge)??null),A}).filter(s=>s!==null)}function Ru(e){if(!m(e))return;const t=r(e.release_version),n=st(e.started_at),s=d(e.uptime_seconds);if(!(!t||!n||s==null))return{release_version:t,commit:r(e.commit)??null,started_at:n,uptime_seconds:s}}function jr(e,t){return m(e)?{...e,generated_at:t??st(e.generated_at)??void 0,build:Ru(e.build),lodge:Jd(e.lodge)??void 0}:null}function Er(e,t){return t?e?{...e,...t,build:t.build??e.build,generated_at:t.generated_at??e.generated_at}:t:e}function Pu(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="running"||t==="interrupted"||t==="completed"||t==="stopped"||t==="error"?t:t.startsWith("error")?"error":"running"}function Lu(e){if(!m(e))return null;const t=d(e.iteration);if(t==null)return null;const n=d(e.metric_before)??0,s=d(e.metric_after)??n,a=m(e.evidence)?e.evidence:null;return{iteration:t,metric_before:n,metric_after:s,delta:d(e.delta)??s-n,changes:r(e.changes)??"",failed_attempts:r(e.failed_attempts)??"",next_suggestion:r(e.next_suggestion)??"",elapsed_ms:d(e.elapsed_ms)??0,cost_usd:d(e.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:d(a.tool_call_count)??0,tool_names:H(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function Nu(e){var o,l;if(!m(e))return null;const t=r(e.loop_id);if(!t)return null;const n=d(e.baseline_metric)??0,s=Array.isArray(e.history)?e.history.map(Lu).filter(c=>c!==null):[],a=d(e.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:t,profile:r(e.profile)??"unknown",status:Pu(e.status),strict_mode:typeof e.strict_mode=="boolean"?e.strict_mode:void 0,error_message:r(e.error_message)??r(e.error_reason)??null,stop_reason:r(e.stop_reason)??r(e.reason)??null,current_iteration:d(e.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:d(e.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(e.target)??"",stagnation_streak:d(e.stagnation_streak)??0,stagnation_limit:d(e.stagnation_limit)??0,elapsed_seconds:d(e.elapsed_seconds)??0,updated_at:st(e.updated_at)??null,stopped_at:st(e.stopped_at)??null,execution_mode:e.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:e.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(e.worker_model)??null,evidence_policy:e.evidence_policy==="hard"||e.evidence_policy==="legacy"?e.evidence_policy:void 0,latest_tool_call_count:d(e.latest_tool_call_count)??0,latest_tool_names:H(e.latest_tool_names)??[],session_id:r(e.session_id)??null,evidence_status:e.evidence_status==="legacy_unverified"?"legacy_unverified":e.evidence_status==="verified"?"verified":null,durability:e.durability==="persistent_backend"||e.durability==="memory_only"?e.durability:void 0,persistence_backend:e.persistence_backend==="filesystem"||e.persistence_backend==="postgres"||e.persistence_backend==="memory"?e.persistence_backend:void 0,recoverable:typeof e.recoverable=="boolean"?e.recoverable:void 0,history:s}}async function Gn(){pi.value=!0;try{await Promise.all([Or(),$t()]),Nr.value=new Date().toISOString()}catch(e){console.error("Dashboard refresh error:",e)}finally{pi.value=!1}}async function Dr(){Os.value=!0,qs.value=null;try{const e=await Bc();Ei.value=e,pu.value=new Date().toISOString()}catch(e){qs.value=e instanceof Error?e.message:"Failed to load dashboard semantics"}finally{Os.value=!1}}function wu(e){var t;return((t=Ei.value)==null?void 0:t.surfaces.find(n=>n.id===e))??null}function zu(e){var n;const t=((n=Ei.value)==null?void 0:n.surfaces)??[];for(const s of t){const a=s.panels.find(o=>o.id===e);if(a)return a}return null}function Mu(e){var s,a;Kt.value=(Array.isArray(e.goals)?e.goals:[]).map(o=>{if(!m(o))return null;const l=r(o.id),c=r(o.title),p=r(o.horizon),u=r(o.status),_=r(o.created_at),g=r(o.updated_at);return!l||!c||!p||!u||!_||!g?null:{id:l,horizon:p,title:c,metric:r(o.metric)??null,target_value:r(o.target_value)??null,due_date:r(o.due_date)??null,priority:d(o.priority)??3,status:u,parent_goal_id:r(o.parent_goal_id)??null,last_review_note:r(o.last_review_note)??null,last_review_at:r(o.last_review_at)??null,created_at:_,updated_at:g}}).filter(o=>o!==null);const t=new Map,n=Array.isArray((s=e.mdal)==null?void 0:s.loops)?e.mdal.loops:[];for(const o of n){const l=Nu(o);l&&t.set(l.loop_id,l)}Lr.value=t,Ut.value=typeof((a=e.mdal)==null?void 0:a.error)=="string"?e.mdal.error:null,ji.value=Ut.value?"error":t.size===0?"idle":"ready"}async function Or(){try{const e=await qc(),t=jr(e.status,e.generated_at);t&&(ie.value=Er(ie.value,t))}catch(e){console.error("Dashboard shell fetch error:",e)}}async function $t(){var e;try{const t=await Fc(),n=jr(t.status,t.generated_at),s=(e=ie.value)==null?void 0:e.room;n&&(ie.value=Er(ie.value,n));const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;Ue.value=(Array.isArray(t.agents)?t.agents:[]).map($u).filter(l=>l!==null),Qe.value=(Array.isArray(t.tasks)?t.tasks:[]).map(hu).filter(l=>l!==null);const o=(Array.isArray(t.messages)?t.messages:[]).map(yu).filter(l=>l!==null);di.value=a?o:Cu(di.value,o),rt.value=Tu(t.keepers,n??ie.value),xr.value=bu(t.summary),Sr.value=(Array.isArray(t.execution_queue)?t.execution_queue:Array.isArray(t.priority_queue)?t.priority_queue:[]).map(ku).filter(l=>l!==null),Ar.value=(Array.isArray(t.session_briefs)?t.session_briefs:[]).map(xu).filter(l=>l!==null),Cr.value=(Array.isArray(t.operation_briefs)?t.operation_briefs:[]).map(Su).filter(l=>l!==null),Ir.value=(Array.isArray(t.worker_support_briefs)?t.worker_support_briefs:Array.isArray(t.worker_briefs)?t.worker_briefs:[]).map(yo).filter(l=>l!==null),Tr.value=(Array.isArray(t.continuity_briefs)?t.continuity_briefs:[]).map(Au).filter(l=>l!==null),Rr.value=(Array.isArray(t.offline_worker_briefs)?t.offline_worker_briefs:[]).map(yo).filter(l=>l!==null),cu.value=null,Nr.value=new Date().toISOString()}catch(t){console.error("Dashboard execution fetch error:",t)}}async function Xe(){Tn.value=!0;try{const e=await Kc(In.value,{excludeSystem:wt.value});Cn.value=e.posts??[],vi.value=new Date().toISOString()}catch(e){console.error("Board fetch error:",e)}finally{Tn.value=!1}}async function Ze(){var e;mi.value=!0;try{const t=qe.value||((e=ie.value)==null?void 0:e.room)||"default";qe.value||(qe.value=t);const n=await Cd(t);Pr.value=n}catch(t){console.error("TRPG fetch error:",t)}finally{mi.value=!1}}async function Oi(){_n.value=!0,gn.value=!0;try{const e=await Vc();Mu(e),du.value=new Date().toISOString(),uu.value=new Date().toISOString()}catch(e){console.error("Planning fetch error:",e),ji.value="error",Ut.value=e instanceof Error?e.message:String(e)}finally{_n.value=!1,gn.value=!1}}async function qr(){return Oi()}let As=null;function ju(e){As=e}let Cs=null;function Eu(e){Cs=e}let Is=null;function Du(e){Is=e}const ht={};let Ta=null;function vt(e,t,n=500){ht[e]&&clearTimeout(ht[e]),ht[e]=setTimeout(()=>{t(),delete ht[e]},n)}function Ou(){const e=ir.subscribe(t=>{if(t){if(t.type==="keeper_heartbeat"&&t.name){const n=new Map(ui.value);n.set(t.name,t.ts_unix?t.ts_unix*1e3:Date.now()),ui.value=n;return}(t.type==="agent_joined"||t.type==="agent_left")&&vt("execution",$t),gu(t.type)&&(Ta||(Ta=setTimeout(()=>{Gn(),Cs==null||Cs(),Is==null||Is(),Ta=null},500))),(t.type.startsWith("task_")||t.type.startsWith("masc/task_"))&&vt("execution",$t),t.type==="broadcast"&&vt("execution",$t),(t.type==="keeper_handoff"||t.type==="keeper_compaction"||t.type==="keeper_guardrail")&&vt("execution",$t),(t.type==="board_post"||t.type==="masc/board_post"||t.type==="board_comment"||t.type==="masc/board_comment")&&vt("board",Xe),t.type.startsWith("decision_")&&vt("council",()=>As==null?void 0:As()),(t.type==="mdal_started"||t.type==="mdal_iteration"||t.type==="mdal_completed"||t.type==="mdal_stopped")&&vt("mdal",qr,350)}});return()=>{e();for(const t of Object.keys(ht))clearTimeout(ht[t]),delete ht[t]}}let fn=null;function qu(){fn||(fn=setInterval(()=>{nt.value,Gn()},1e4))}function Fu(){fn&&(clearInterval(fn),fn=null)}function Ku({metric:e}){return i`
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
  `}function Uu({panel:e}){return i`
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
            ${e.metrics.map(t=>i`<${Ku} key=${t.id} metric=${t} />`)}
          </div>`:null}
    </div>
  `}function D({panelId:e,compact:t=!1,label:n="Why"}){const s=zu(e);return s?i`
    <details class="semantic-inline ${t?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${Uu} panel=${s} />
    </details>
  `:Os.value?i`<span class="semantic-inline-state">Loading semantics…</span>`:null}function he({surfaceId:e,compact:t=!1}){const n=wu(e);return n?i`
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
  `:Os.value?i`<div class="semantic-surface-card ${t?"compact":""}">Loading semantics…</div>`:qs.value?i`<div class="semantic-surface-card ${t?"compact":""}">${qs.value}</div>`:null}function C({title:e,class:t,semanticId:n,testId:s,children:a}){return i`
    <div class="card ${t??""}" data-testid=${s}>
      ${e?i`
            <div class="card-title-row">
              <div class="card-title">${e}</div>
              ${n?i`<${D} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}const Jn=f(null),_i=f(!1),Fs=f(null),Fr=f(null),zt=f(!1),ft=f(null),gi=f(null),Ts=f(!1),Rs=f(null);let Bt=null;function xo(){Bt!==null&&(window.clearTimeout(Bt),Bt=null)}function Bu(e=1500){Bt===null&&(Bt=window.setTimeout(()=>{Bt=null,Ks(!1)},e))}function z(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function h(e){return typeof e=="string"&&e.trim()!==""?e:void 0}function M(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function Ht(e){return typeof e=="boolean"?e:void 0}function B(e,t=[]){if(Array.isArray(e))return e;if(!z(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function an(e){if(!z(e))return null;const t=h(e.kind),n=h(e.summary),s=h(e.target_type);return!t||!n||!s?null:{kind:t,severity:h(e.severity)??"warn",summary:n,target_type:s,target_id:h(e.target_id)??null,actor:h(e.actor)??null,evidence:e.evidence}}function St(e){if(!z(e))return null;const t=h(e.action_type),n=h(e.target_type),s=h(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:h(e.target_id)??null,severity:h(e.severity)??"warn",reason:s,confirm_required:Ht(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function Hu(e){if(!z(e))return null;const t=h(e.session_id);return t?{session_id:t,goal:h(e.goal),status:h(e.status),health:h(e.health),scale_profile:h(e.scale_profile),control_profile:h(e.control_profile),planned_worker_count:M(e.planned_worker_count),active_agent_count:M(e.active_agent_count),last_turn_age_sec:M(e.last_turn_age_sec)??null,attention_count:M(e.attention_count),recommended_action_count:M(e.recommended_action_count),top_attention:an(e.top_attention),top_recommendation:St(e.top_recommendation)}:null}function Wu(e){if(!z(e))return null;const t=h(e.session_id);if(!t)return null;const n=z(e.status)?e.status:e,s=z(n.summary)?n.summary:void 0;return{session_id:t,status:h(e.status)??h(s==null?void 0:s.status)??(z(n.session)?h(n.session.status):void 0),progress_pct:M(e.progress_pct)??M(s==null?void 0:s.progress_pct),elapsed_sec:M(e.elapsed_sec)??M(s==null?void 0:s.elapsed_sec),remaining_sec:M(e.remaining_sec)??M(s==null?void 0:s.remaining_sec),done_delta_total:M(e.done_delta_total)??M(s==null?void 0:s.done_delta_total),summary:z(e.summary)?e.summary:s,team_health:z(e.team_health)?e.team_health:z(n.team_health)?n.team_health:void 0,communication_metrics:z(e.communication_metrics)?e.communication_metrics:z(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:z(e.orchestration_state)?e.orchestration_state:z(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:z(e.cascade_metrics)?e.cascade_metrics:z(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:z(e.report_paths)?Object.fromEntries(Object.entries(e.report_paths).map(([a,o])=>{const l=h(o);return l?[a,l]:null}).filter(a=>a!==null)):z(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const l=h(o);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:z(e.session)?e.session:z(n.session)?n.session:void 0,recent_events:B(e.recent_events,["events"]).filter(z)}}function Gu(e){if(!z(e))return null;const t=h(e.name);return t?{name:t,agent_name:h(e.agent_name),status:h(e.status),autonomy_level:h(e.autonomy_level),context_ratio:M(e.context_ratio),generation:M(e.generation),active_goal_ids:B(e.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:h(e.last_autonomous_action_at)??null,last_turn_ago_s:M(e.last_turn_ago_s),model:h(e.model)}:null}function Ju(e){if(!z(e))return null;const t=h(e.confirm_token)??h(e.token);return t?{confirm_token:t,actor:h(e.actor),action_type:h(e.action_type),target_type:h(e.target_type),target_id:h(e.target_id)??null,delegated_tool:h(e.delegated_tool),created_at:h(e.created_at),preview:e.preview}:null}function Vu(e){if(!z(e))return null;const t=h(e.action_type),n=h(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:h(e.description),confirm_required:Ht(e.confirm_required)}}function Qu(e){const t=z(e)?e:{};return{room_health:h(t.room_health),cluster:h(t.cluster),project:h(t.project),current_room:h(t.current_room)??null,paused:Ht(t.paused),tempo_interval_s:M(t.tempo_interval_s),active_agents:M(t.active_agents),keeper_pressure:M(t.keeper_pressure),active_operations:M(t.active_operations),pending_approvals:M(t.pending_approvals),incident_count:M(t.incident_count),recommended_action_count:M(t.recommended_action_count),top_attention:an(t.top_attention),top_action:St(t.top_action)}}function Yu(e){const t=z(e)?e:{},n=z(t.swarm_overview)?t.swarm_overview:{};return{health:h(t.health),active_operations:M(t.active_operations),pending_approvals:M(t.pending_approvals),swarm_overview:{active_lanes:M(n.active_lanes),moving_lanes:M(n.moving_lanes),stalled_lanes:M(n.stalled_lanes),projected_lanes:M(n.projected_lanes),last_movement_at:h(n.last_movement_at)??null},top_attention:an(t.top_attention),top_action:St(t.top_action),session_cards:B(t.session_cards).map(Hu).filter(s=>s!==null)}}function Xu(e){const t=z(e)?e:{};return{sessions:B(t.sessions,["items"]).map(Wu).filter(n=>n!==null),keepers:B(t.keepers,["items"]).map(Gu).filter(n=>n!==null),pending_confirms:B(t.pending_confirms).map(Ju).filter(n=>n!==null),available_actions:B(t.available_actions).map(Vu).filter(n=>n!==null)}}function Zu(e){if(!z(e))return null;const t=h(e.id),n=h(e.kind),s=h(e.summary),a=h(e.target_type);return!t||!n||!s||!a?null:{id:t,kind:n,severity:h(e.severity)??"warn",summary:s,target_type:a,target_id:h(e.target_id)??null,top_action:St(e.top_action),related_session_ids:B(e.related_session_ids).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),related_agent_names:B(e.related_agent_names).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),evidence_preview:B(e.evidence_preview).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),last_seen_at:h(e.last_seen_at)??null}}function Kr(e){if(!z(e))return null;const t=h(e.session_id),n=h(e.goal);return!t||!n?null:{session_id:t,goal:n,room:h(e.room)??null,status:h(e.status),health:h(e.health),member_names:B(e.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:h(e.started_at)??null,elapsed_sec:M(e.elapsed_sec)??null,operation_id:h(e.operation_id)??null,blocker_summary:h(e.blocker_summary)??null,last_event_at:h(e.last_event_at)??null,last_event_summary:h(e.last_event_summary)??null,communication_summary:h(e.communication_summary)??null,active_count:M(e.active_count),required_count:M(e.required_count),related_attention_count:M(e.related_attention_count)??0,top_attention:an(e.top_attention),top_recommendation:St(e.top_recommendation)}}function Ur(e){if(!z(e))return null;const t=h(e.agent_name);return t?{agent_name:t,status:h(e.status),current_work:h(e.current_work)??null,recent_input_preview:h(e.recent_input_preview)??null,recent_output_preview:h(e.recent_output_preview)??null,recent_tool_names:B(e.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_activity_at:h(e.last_activity_at)??null}:null}function Br(e){if(!z(e))return null;const t=h(e.operation_id);return t?{operation_id:t,status:h(e.status),stage:h(e.stage)??null,detachment_status:h(e.detachment_status)??null,objective:h(e.objective)??null,updated_at:h(e.updated_at)??null}:null}function Hr(e){if(!z(e))return null;const t=h(e.name);return t?{name:t,agent_name:h(e.agent_name)??null,status:h(e.status),generation:M(e.generation),context_ratio:M(e.context_ratio)??null,last_turn_ago_s:M(e.last_turn_ago_s)??null,current_work:h(e.current_work)??null}:null}function Wr(e){const t=Kr(e);return t?{...t,member_previews:B(z(e)?e.member_previews:void 0).map(Ur).filter(n=>n!==null),operation_badges:B(z(e)?e.operation_badges:void 0).map(Br).filter(n=>n!==null),keeper_refs:B(z(e)?e.keeper_refs:void 0).map(Hr).filter(n=>n!==null)}:null}function ep(e){if(!z(e))return null;const t=h(e.agent_name);return t?{agent_name:t,status:h(e.status),where:h(e.where)??null,with_whom:B(e.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:h(e.current_work)??null,related_session_id:h(e.related_session_id)??null,related_attention_count:M(e.related_attention_count)??0,last_activity_at:h(e.last_activity_at)??null,recent_output_preview:h(e.recent_output_preview)??null,recent_input_preview:h(e.recent_input_preview)??null,recent_event:h(e.recent_event)??null,recent_tool_names:B(e.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),allowed_tool_names:B(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:B(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:M(e.latest_tool_call_count)??null,tool_audit_source:h(e.tool_audit_source)??null,tool_audit_at:h(e.tool_audit_at)??null}:null}function tp(e){if(!z(e))return null;const t=h(e.name);return t?{name:t,agent_name:h(e.agent_name)??null,status:h(e.status),generation:M(e.generation),context_ratio:M(e.context_ratio)??null,last_turn_ago_s:M(e.last_turn_ago_s)??null,current_work:h(e.current_work)??null,last_autonomous_action_at:h(e.last_autonomous_action_at)??null,allowed_tool_names:B(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:B(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:M(e.latest_tool_call_count)??null,tool_audit_source:h(e.tool_audit_source)??null,tool_audit_at:h(e.tool_audit_at)??null}:null}function np(e){if(!z(e))return null;const t=h(e.id),n=h(e.signal_type),s=h(e.summary),a=h(e.target_type);return!t||!n||!s||!a?null:{id:t,signal_type:n==="action"?"action":"attention",severity:h(e.severity)??"warn",summary:s,target_type:a,target_id:h(e.target_id)??null,attention:an(e.attention),action:St(e.action)}}function sp(e){const t=z(e)?e:{},n=B(t.session_briefs).map(Kr).filter(a=>a!==null),s=B(t.sessions).map(Wr).filter(a=>a!==null);return{generated_at:h(t.generated_at),summary:Qu(t.summary),incidents:B(t.incidents).map(an).filter(a=>a!==null),recommended_actions:B(t.recommended_actions).map(St).filter(a=>a!==null),command_focus:Yu(t.command_focus),operator_targets:Xu(t.operator_targets),attention_queue:B(t.attention_queue).map(Zu).filter(a=>a!==null),sessions:s.length>0?s:n.map(a=>({...a,member_previews:[],operation_badges:[],keeper_refs:[]})),session_briefs:n,agent_briefs:B(t.agent_briefs).map(ep).filter(a=>a!==null),keeper_briefs:B(t.keeper_briefs).map(tp).filter(a=>a!==null),internal_signals:B(t.internal_signals).map(np).filter(a=>a!==null)}}function ap(e){if(!z(e))return null;const t=h(e.id),n=h(e.summary);return!t||!n?null:{id:t,timestamp:h(e.timestamp)??null,event_type:h(e.event_type),actor:h(e.actor)??null,summary:n}}function ip(e){const t=z(e)?e:{};return{generated_at:h(t.generated_at),session_id:h(t.session_id)??"",session:Wr(t.session),timeline:B(t.timeline).map(ap).filter(n=>n!==null),participants:B(t.participants).map(Ur).filter(n=>n!==null),operations:B(t.operations).map(Br).filter(n=>n!==null),keepers:B(t.keepers).map(Hr).filter(n=>n!==null),error:h(t.error)??null}}function op(e){if(!z(e))return null;const t=h(e.id),n=h(e.label),s=h(e.summary);if(!t||!n||!s)return null;const a=h(e.status)??"unclear";return{id:t,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:h(e.signal_class)==="metadata_gap"||h(e.signal_class)==="mixed"||h(e.signal_class)==="operational_risk"?h(e.signal_class):void 0,evidence_quality:h(e.evidence_quality)==="strong"||h(e.evidence_quality)==="partial"||h(e.evidence_quality)==="missing"?h(e.evidence_quality):void 0,evidence:B(e.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function rp(e){if(!z(e))return null;const t=h(e.kind),n=h(e.summary),s=h(e.scope_type),a=h(e.severity);return!t||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:t,summary:n,scope_type:s,scope_id:h(e.scope_id)??null,severity:a}}function lp(e){const t=z(e)?e:{},n=z(t.basis)?t.basis:{},s=h(t.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:h(t.generated_at),cached:Ht(t.cached),stale:Ht(t.stale),refreshing:Ht(t.refreshing),status:a,summary:h(t.summary)??null,model:h(t.model)??null,ttl_sec:M(t.ttl_sec),criteria:B(t.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:h(n.current_room)??null,crew_count:M(n.crew_count),agent_count:M(n.agent_count),keeper_count:M(n.keeper_count)},metadata_gap_count:M(t.metadata_gap_count),metadata_gaps:B(t.metadata_gaps).map(rp).filter(o=>o!==null),sections:B(t.sections).map(op).filter(o=>o!==null),error:h(t.error)??null,last_error:h(t.last_error)??null}}async function Gr(){_i.value=!0,Fs.value=null;try{const e=await Hc();Jn.value=sp(e)}catch(e){Fs.value=e instanceof Error?e.message:"Failed to load mission snapshot"}finally{_i.value=!1}}async function cp(e){if(!e){gi.value=null,Rs.value=null,Ts.value=!1;return}Ts.value=!0,Rs.value=null;try{const t=await Wc(e);gi.value=ip(t)}catch(t){Rs.value=t instanceof Error?t.message:"Failed to load session detail"}finally{Ts.value=!1}}async function Ks(e=!1){zt.value=!0,ft.value=null;try{const t=await Gc(e),n=lp(t);Fr.value=n,n.refreshing||n.status==="pending"?Bu():xo()}catch(t){ft.value=t instanceof Error?t.message:"Failed to load mission briefing",xo()}finally{zt.value=!1}}const Us="masc_dashboard_workflow_context",dp=900*1e3;function _e(e){return typeof e=="string"&&e.trim()!==""?e.trim():null}function He(e){const t=_e(e);return t||(typeof e=="number"&&Number.isFinite(e)?String(e):null)}function Jr(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function fi(e){return m(e)?e:null}function up(e){if(!e)return null;try{return JSON.stringify(e)}catch{return null}}function pp(e){if(!e)return null;try{const t=JSON.parse(e);if(!m(t))return null;const n=_e(t.id),s=_e(t.source_surface),a=_e(t.source_label),o=_e(t.summary),l=_e(t.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!o||!l?null:{id:n,source_surface:s,source_label:a,action_type:_e(t.action_type),target_type:_e(t.target_type),target_id:_e(t.target_id),focus_kind:_e(t.focus_kind),operation_id:_e(t.operation_id),command_surface:_e(t.command_surface),summary:o,payload_preview:_e(t.payload_preview),suggested_payload:fi(t.suggested_payload),preview:t.preview??null,evidence:t.evidence??null,created_at:l}}catch{return null}}function qi(e){const t=Date.parse(e.created_at);return Number.isNaN(t)?!1:Date.now()-t<=dp}function mp(){const e=Jr(),t=pp((e==null?void 0:e.getItem(Us))??null);return t?qi(t)?t:(e==null||e.removeItem(Us),null):null}const Vr=f(mp());function Qr(e){const t=e&&qi(e)?e:null;Vr.value=t;const n=Jr();if(!n)return;if(!t){n.removeItem(Us);return}const s=up(t);s&&n.setItem(Us,s)}function vp(e){if(!e)return null;const t=fi(e.suggested_payload);if(t)return t;if(m(e.preview)){const n=fi(e.preview.payload);if(n)return n}return null}function _p(e){if(!e)return null;const t=He(e.message);if(t)return t;const n=He(e.task_title)??He(e.title),s=He(e.task_description)??He(e.description),a=He(e.reason),o=He(e.priority)??He(e.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function Fi(e,t,n,s,a,o,l,c){return[e,t,n??"action",s??"target",a??"room",o??"focus",l??"operation",c].join(":")}function on(e,t,n="상황판 추천 액션"){const s=new Date().toISOString(),a=vp(e),o=(e==null?void 0:e.target_type)??(t==null?void 0:t.target_type)??null,l=(e==null?void 0:e.target_id)??(t==null?void 0:t.target_id)??null,c=(t==null?void 0:t.kind)??(e==null?void 0:e.action_type)??null,p=(e==null?void 0:e.reason)??(t==null?void 0:t.summary)??n;return{id:Fi("mission",n,(e==null?void 0:e.action_type)??null,o,l,c,null,s),source_surface:"mission",source_label:n,action_type:(e==null?void 0:e.action_type)??null,target_type:o,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:p,payload_preview:_p(a),suggested_payload:a,preview:(e==null?void 0:e.preview)??null,evidence:(t==null?void 0:t.evidence)??null,created_at:s}}function gp({targetType:e,targetId:t,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:o=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:Fi("execution",s,null,e,t,n,o,c),source_surface:"execution",source_label:s,action_type:null,target_type:e,target_id:t,focus_kind:n,operation_id:o,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function fp(e,t){return(t.source==="mission"||t.source==="execution")&&(t.action_type??null)===(e.action_type??null)&&(t.target_type??null)===(e.target_type??null)&&(t.target_id??null)===(e.target_id??null)&&(t.focus_kind??null)===(e.focus_kind??null)&&(t.operation_id??null)===(e.operation_id??null)}function Vn(e){const{params:t}=e;if(t.source!=="mission"&&t.source!=="execution")return null;const n=Vr.value;if(n&&qi(n)&&fp(n,t))return n;const s=new Date().toISOString(),a=t.source==="execution"?"execution":"mission";return{id:Fi(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",t.action_type??null,t.target_type??null,t.target_id??null,t.focus_kind??null,t.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:t.action_type??null,target_type:t.target_type??null,target_id:t.target_id??null,focus_kind:t.focus_kind??t.action_type??null,operation_id:t.operation_id??null,command_surface:t.surface??null,summary:a==="execution"?t.focus_kind?`${t.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":t.focus_kind?`${t.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function Yr(e){return{source:e.source_surface,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function Xr(e){if(e.command_surface)return e.command_surface;const t=[e.focus_kind,e.summary,e.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"summary":t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")||t.includes("swarm")?"swarm":e.focus_kind==="operation"||e.target_type==="operation"?"operations":e.target_type==="room"?"summary":"swarm"}function Zr(e){return{source:e.source_surface,surface:Xr(e),...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function $p(e){return Yr(e)}function hp(e){return Zr(e)}function Ki(e){return e!=null&&e.target_type?e.target_id?`${e.target_type} · ${e.target_id}`:e.target_type:"대상 정보 없음"}function ha(e){switch(e){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(e==null?void 0:e.trim())||"추천 액션"}}function yp(e){switch(e){case"warroom":return"워룸";case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(e==null?void 0:e.trim())||"지휘"}}const Oe=f(null),Ve=f(null);function Ce(e,t=120){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-1)}…`:n:null}function pe(e){return e==="bad"||e==="offline"||e==="critical"||e==="risk"?"bad":e==="warn"||e==="pending"||e==="degraded"||e==="interrupted"||e==="watch"?"warn":"ok"}function we(e){if(!e)return"방금";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:n<86400?`${Math.round(n/3600)}h 전`:`${Math.round(n/86400)}d 전`}function bp(e){return typeof e!="number"||!Number.isFinite(e)||e<0?"n/a":e<60?`${Math.round(e)}s`:e<3600?`${Math.round(e/60)}m`:e<86400?`${Math.round(e/3600)}h`:`${Math.round(e/86400)}d`}function kp(e){return e!=null&&e.confirm_required?"확인 후 실행":"즉시 실행"}function xp(e){return Ki(e?on(e,null,"상황판 추천 액션"):null)}function ya(e,t=on()){Qr(t),ce(e,e==="intervene"?$p(t):hp(t))}function el(e){ya("intervene",on(null,e,"상황판 incident"))}function tl(e){ya("command",on(null,e,"상황판 incident"))}function Ui(e,t,n="상황판 추천 액션"){ya("intervene",on(e,t,n))}function nl(e,t,n="상황판 추천 액션"){ya("command",on(e,t,n))}function $i(e,t){const n={source:"mission",target_type:"team_session",target_id:t,focus_kind:"team_session"};e==="command"&&(n.surface="swarm"),ce(e,n)}function Sp(e){return{kind:e.kind,severity:e.severity,summary:e.summary,target_type:e.target_type,target_id:e.target_id??null,actor:null,evidence:e.evidence_preview}}function Ap(e){var n,s;const t=rt.value.find(a=>a.name===e.name||a.agent_name===e.agent_name)??null;return{brief:e,keeper:t,currentWork:Ce(e.current_work,110)??Ce(t==null?void 0:t.skill_primary,110)??Ce(t==null?void 0:t.last_proactive_reason,110)??"명시된 keeper focus 없음",recentInput:Ce(t==null?void 0:t.recent_input_preview,120)??null,recentOutput:Ce(t==null?void 0:t.recent_output_preview,120)??Ce((n=t==null?void 0:t.diagnostic)==null?void 0:n.last_reply_preview,120)??Ce(t==null?void 0:t.last_proactive_preview,120)??null,recentEvent:Ce(t==null?void 0:t.last_proactive_reason,120)??Ce((s=t==null?void 0:t.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(t==null?void 0:t.recent_tool_names)??[]}}function Cp(){const e=Jn.value;if(!e)return new Map;const t=e.sessions.length>0?e.sessions:e.session_briefs;return new Map(t.map(n=>[n.session_id,n]))}function Ip(e){Oe.value=Oe.value===e?null:e,Ve.value=null}function sl(e){Ve.value=Ve.value===e?null:e,Oe.value=null}function Tp(){Oe.value=null,Ve.value=null}function lt({status:e,label:t}){return i`
    <span class="status-badge ${e}">
      <span class="status-dot-inline ${e}"></span>
      ${t??e}
    </span>
  `}function al(e){const t=Date.now(),n=typeof e=="number"?e<1e12?e*1e3:e:new Date(e).getTime(),s=Math.floor((t-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const o=Math.floor(a/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function W({timestamp:e}){const t=al(e),n=typeof e=="string"?e:new Date(e<1e12?e*1e3:e).toISOString();return i`<span class="time-ago" title=${n}>${t}</span>`}let Rp=0;const yt=f([]);function N(e,t="success",n=4e3){const s=++Rp;yt.value=[...yt.value,{id:s,message:e,type:t}],setTimeout(()=>{yt.value=yt.value.filter(a=>a.id!==s)},n)}function Pp(e){yt.value=yt.value.filter(t=>t.id!==e)}function Lp(){const e=yt.value;return e.length===0?null:i`
    <div class="toast-container">
      ${e.map(t=>i`
        <div key=${t.id} class="toast ${t.type}" onClick=${()=>Pp(t.id)}>
          ${t.message}
        </div>
      `)}
    </div>
  `}const Np="masc_dashboard_agent_name",rn=f(null),Bs=f(!1),Rn=f(""),Hs=f([]),Pn=f([]),Wt=f(""),$n=f(!1);function ba(e){rn.value=e,Bi()}function So(){rn.value=null,Rn.value="",Hs.value=[],Pn.value=[],Wt.value=""}function wp(){const e=rn.value;return e?Ue.value.find(t=>t.name===e)??null:null}function il(e){return e?Qe.value.filter(t=>t.assignee===e):[]}function ol(e){return e?rt.value.find(t=>t.agent_name===e||t.name===e)??null:null}function zp(e){if(!e)return null;const t=Jn.value;return t?t.agent_briefs.find(n=>n.agent_name===e)??null:null}function Mp(e){if(!e)return[];const t=e.metrics_window;return(Array.isArray(t==null?void 0:t.top_tools)?t.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function jp(e){const t=ol(e);return t?t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]:[]}async function Bi(){const e=rn.value;if(e){Bs.value=!0,Rn.value="",Hs.value=[],Pn.value=[];try{const t=await jd(80);Hs.value=t.filter(a=>a.includes(e)).slice(0,20);const n=il(e).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await Ed(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const l=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));Pn.value=s}catch(t){Rn.value=t instanceof Error?t.message:"Failed to load agent detail"}finally{Bs.value=!1}}}async function Ao(){var s;const e=rn.value,t=Wt.value.trim();if(!e||!t)return;const n=((s=localStorage.getItem(Np))==null?void 0:s.trim())||"dashboard";$n.value=!0;try{await Md(n,`@${e} ${t}`),Wt.value="",N(`Mention sent to ${e}`,"success"),Bi()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";N(o,"error")}finally{$n.value=!1}}function Ep({task:e}){return i`
    <div class="agent-detail-task">
      <span class="pill">${e.id}</span>
      <span class="agent-detail-task-title">${e.title}</span>
      <${lt} status=${e.status} />
    </div>
  `}function Dp({row:e}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${e.taskId}</span>
      </div>
      <pre class="agent-history-pre">${e.text||"No task history yet"}</pre>
    </div>
  `}function Op(){var b,I,R,T,P,L,K;const e=rn.value;if(!e)return null;const t=wp(),n=ol(e),s=zp(e),a=il(e),o=Hs.value,l=jp(e),c=Mp(n),p=(s==null?void 0:s.allowed_tool_names)??[],u=(s==null?void 0:s.latest_tool_names)??[],_=s==null?void 0:s.latest_tool_call_count,g=s==null?void 0:s.tool_audit_source,v=s==null?void 0:s.tool_audit_at,y=(t==null?void 0:t.capabilities)??[],S=((b=ie.value)==null?void 0:b.room)??"default",$=((I=ie.value)==null?void 0:I.project)??"확인 없음",A=((R=ie.value)==null?void 0:R.cluster)??"확인 없음";return i`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${q=>{q.target.classList.contains("agent-detail-overlay")&&So()}}
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
                        <${lt} status=${t.status} />
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
                ${(P=t==null?void 0:t.traits)==null?void 0:P.map(q=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${q}</span>`)}
              </div>
            `:""}
            ${(((L=t==null?void 0:t.interests)==null?void 0:L.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(K=t==null?void 0:t.interests)==null?void 0:K.map(q=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${q}</span>`)}
              </div>
            `:""}
            ${y.length>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${y.map(q=>i`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${q}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${t?i`
                    ${t.current_task?i`<span>Task: ${t.current_task}</span>`:null}
                    ${t.last_seen?i`<span>Last seen: <${W} timestamp=${t.last_seen} /></span>`:null}
                    <span>Room: ${S}</span>
                    <span>Project: ${$}</span>
                    <span>Cluster: ${A}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Bi()}} disabled=${Bs.value}>
              ${Bs.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${So}>Close</button>
          </div>
        </div>

        ${Rn.value?i`<div class="council-error">${Rn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${C} title="Assigned Tasks">
            ${a.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${a.map(q=>i`<${Ep} key=${q.id} task=${q} />`)}</div>`}
          <//>

          <${C} title="Recent Activity">
            ${o.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${o.map((q,te)=>i`<div key=${te} class="agent-activity-line">${q}</div>`)}</div>`}
          <//>
        </div>

        <${C} title="Capabilities & Tool Audit">
          <div style="display:flex; flex-direction:column; gap:12px;">
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Capabilities</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${y.length>0?y.map(q=>i`<span class="pill">${q}</span>`):i`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Allowed tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${p.length>0?p.map(q=>i`<span class="pill">${q}</span>`):i`<span class="empty-state" style="font-size:12px;">No allowlist reported</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Observed tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${u.length>0?u.map(q=>i`<span class="pill">${q}</span>`):i`<span class="empty-state" style="font-size:12px;">No observed tool-use evidence</span>`}
              </div>
            </div>
            <div class="agent-detail-sub">
              <span>Tool calls: ${typeof _=="number"?_:"—"}</span>
              <span>Evidence source: ${g??"unreported"}</span>
              <span>
                Observed at:
                ${v?i` <${W} timestamp=${v} />`:" unreported"}
              </span>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Linked keeper recent tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${l.length>0?l.map(q=>i`<span class="pill">${q}</span>`):i`<span class="empty-state" style="font-size:12px;">No keeper tool telemetry</span>`}
              </div>
            </div>
            ${c.length>0?i`
                  <div>
                    <div style="font-size:12px; color:#888; margin-bottom:6px;">Keeper window top tools</div>
                    <div style="display:flex; flex-wrap:wrap; gap:6px;">
                      ${c.map(q=>i`<span class="pill">${q}</span>`)}
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

        <${C} title="Task History">
          ${Pn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${Pn.value.map(q=>i`<${Dp} key=${q.taskId} row=${q} />`)}</div>`}
        <//>

        <${C} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Wt.value}
              onInput=${q=>{Wt.value=q.target.value}}
              onKeyDown=${q=>{q.key==="Enter"&&Ao()}}
              disabled=${$n.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Ao()}}
              disabled=${$n.value||Wt.value.trim()===""}
            >
              ${$n.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const me=f(null),Hi=f(null),ze=f(null),Ln=f(!1),at=f(null),Nn=f(!1),Xt=f(null),V=f(!1),Ws=f([]);let qp=1;function Fp(e){return m(e)?{id:r(e.id),seq:d(e.seq),from:r(e.from)??r(e.from_agent)??"system",content:r(e.content)??"",timestamp:r(e.timestamp)??new Date().toISOString(),type:r(e.type)}:null}function Kp(e){return m(e)?{room_id:r(e.room_id),current_room:r(e.current_room)??r(e.room),project:r(e.project),cluster:r(e.cluster),paused:j(e.paused),pause_reason:r(e.pause_reason)??null,paused_by:r(e.paused_by)??null,paused_at:r(e.paused_at)??null}:{}}function Co(e){if(!m(e))return;const t=Object.entries(e).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return t.length>0?Object.fromEntries(t):void 0}function rl(e){if(!m(e))return null;const t=r(e.kind),n=r(e.summary),s=r(e.target_type);return!t||!n||!s?null:{kind:t,severity:r(e.severity)??"warn",summary:n,target_type:s,target_id:r(e.target_id)??null,actor:r(e.actor)??null,evidence:e.evidence}}function hn(e){if(!m(e))return null;const t=r(e.action_type),n=r(e.target_type),s=r(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:r(e.target_id)??null,severity:r(e.severity)??"warn",reason:s,confirm_required:j(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function ll(e){return m(e)?{enabled:j(e.enabled),judge_online:j(e.judge_online),refreshing:j(e.refreshing),generated_at:r(e.generated_at)??null,expires_at:r(e.expires_at)??null,model_used:r(e.model_used)??null,keeper_name:r(e.keeper_name)??null,last_error:r(e.last_error)??null}:null}function Ra(e){return m(e)?{summary:r(e.summary)??null,confidence:d(e.confidence)??null,provenance:r(e.provenance)??null,authoritative:j(e.authoritative),surface:r(e.surface)??null,fresh_until:r(e.fresh_until)??null,keeper_name:r(e.keeper_name)??null,fallback_used:j(e.fallback_used),disagreement_with_truth:j(e.disagreement_with_truth)}:null}function Up(e){return m(e)?{judgment_id:r(e.judgment_id)??void 0,surface:r(e.surface)??null,target_type:r(e.target_type)??null,target_id:r(e.target_id)??null,status:r(e.status)??null,summary:r(e.summary)??null,confidence:d(e.confidence)??null,generated_at:r(e.generated_at)??null,fresh_until:r(e.fresh_until)??null,keeper_name:r(e.keeper_name)??null,model_name:r(e.model_name)??null,runtime_name:r(e.runtime_name)??null,evidence_refs:H(e.evidence_refs),recommended_action:hn(e.recommended_action),supersedes:H(e.supersedes),fallback_used:j(e.fallback_used),disagreement_with_truth:j(e.disagreement_with_truth),provenance:r(e.provenance)??null}:null}function Bp(e){return m(e)?{actor:r(e.actor)??null,spawn_agent:r(e.spawn_agent)??null,spawn_role:r(e.spawn_role)??null,spawn_model:r(e.spawn_model)??null,worker_class:r(e.worker_class)??null,parent_actor:r(e.parent_actor)??null,capsule_mode:r(e.capsule_mode)??null,runtime_pool:r(e.runtime_pool)??null,lane_id:r(e.lane_id)??null,controller_level:r(e.controller_level)??null,control_domain:r(e.control_domain)??null,supervisor_actor:r(e.supervisor_actor)??null,model_tier:r(e.model_tier)??null,task_profile:r(e.task_profile)??null,risk_level:r(e.risk_level)??null,routing_confidence:d(e.routing_confidence)??null,routing_reason:r(e.routing_reason)??null,status:r(e.status)??"unknown",turn_count:d(e.turn_count)??0,empty_note_turn_count:d(e.empty_note_turn_count)??0,has_turn:j(e.has_turn)??!1,last_turn_ts_iso:r(e.last_turn_ts_iso)??null}:null}function Hp(e){if(!m(e))return null;const t=r(e.session_id);return t?{session_id:t,goal:r(e.goal),status:r(e.status),health:r(e.health),scale_profile:r(e.scale_profile),control_profile:r(e.control_profile),planned_worker_count:d(e.planned_worker_count),active_agent_count:d(e.active_agent_count),last_turn_age_sec:d(e.last_turn_age_sec)??null,attention_count:d(e.attention_count),recommended_action_count:d(e.recommended_action_count),top_attention:rl(e.top_attention),top_recommendation:hn(e.top_recommendation)}:null}function cl(e){const t=m(e)?e:{};return{trace_id:r(t.trace_id),target_type:r(t.target_type)??"room",target_id:r(t.target_id)??null,health:r(t.health),judgment_owner:r(t.judgment_owner)??null,authoritative_judgment_available:j(t.authoritative_judgment_available),resident_judge_runtime:ll(t.resident_judge_runtime),judgment:Up(t.judgment),active_guidance_layer:r(t.active_guidance_layer)??null,active_summary:Ra(t.active_summary),active_recommended_actions:fe(t.active_recommended_actions).map(hn).filter(n=>n!==null),active_recommendation_source:r(t.active_recommendation_source)??null,active_recommendation_summary:Ra(t.active_recommendation_summary),fallback_recommended_actions:fe(t.fallback_recommended_actions).map(hn).filter(n=>n!==null),recommendation_summary:Ra(t.recommendation_summary),swarm_status:m(t.swarm_status)?t.swarm_status:void 0,attention_items:fe(t.attention_items).map(rl).filter(n=>n!==null),recommended_actions:fe(t.recommended_actions).map(hn).filter(n=>n!==null),session_cards:fe(t.session_cards).map(Hp).filter(n=>n!==null),worker_cards:fe(t.worker_cards).map(Bp).filter(n=>n!==null)}}function Wp(e){if(!m(e))return null;const t=m(e.status)?e.status:void 0,n=m(e.summary)?e.summary:m(t==null?void 0:t.summary)?t.summary:void 0,s=m(e.session)?e.session:m(t==null?void 0:t.session)?t.session:void 0,a=r(e.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const o=Co(e.report_paths)??Co(t==null?void 0:t.report_paths),l=fe(e.recent_events,["events"]).filter(m);return{session_id:a,status:r(e.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:d(e.progress_pct)??d(n==null?void 0:n.progress_pct),elapsed_sec:d(e.elapsed_sec)??d(n==null?void 0:n.elapsed_sec),remaining_sec:d(e.remaining_sec)??d(n==null?void 0:n.remaining_sec),done_delta_total:d(e.done_delta_total)??d(n==null?void 0:n.done_delta_total),summary:n,team_health:m(e.team_health)?e.team_health:m(t==null?void 0:t.team_health)?t.team_health:void 0,communication_metrics:m(e.communication_metrics)?e.communication_metrics:m(t==null?void 0:t.communication_metrics)?t.communication_metrics:void 0,orchestration_state:m(e.orchestration_state)?e.orchestration_state:m(t==null?void 0:t.orchestration_state)?t.orchestration_state:void 0,cascade_metrics:m(e.cascade_metrics)?e.cascade_metrics:m(t==null?void 0:t.cascade_metrics)?t.cascade_metrics:void 0,report_paths:o,session:s,recent_events:l}}function Io(e){if(!m(e))return null;const t=r(e.name);if(!t)return null;const n=m(e.context)?e.context:void 0;return{name:t,runtime_class:e.runtime_class==="persistent_agent"?"persistent_agent":"resident_keeper",desired:j(e.desired),resident_registered:j(e.resident_registered),agent_name:r(e.agent_name),status:r(e.status),autonomy_level:r(e.autonomy_level),context_ratio:d(e.context_ratio)??d(n==null?void 0:n.context_ratio),generation:d(e.generation),active_goal_ids:H(e.active_goal_ids),last_autonomous_action_at:r(e.last_autonomous_action_at)??null,last_turn_ago_s:d(e.last_turn_ago_s),model:r(e.model)??r(e.active_model)??r(e.primary_model)}}function Gp(e){if(!m(e))return null;const t=r(e.confirm_token)??r(e.token);return t?{confirm_token:t,actor:r(e.actor),action_type:r(e.action_type),target_type:r(e.target_type),target_id:r(e.target_id)??null,delegated_tool:r(e.delegated_tool),created_at:r(e.created_at),preview:e.preview}:null}function Jp(e){const t=m(e)?e:{};return{room:Kp(t.room),sessions:fe(t.sessions,["items","sessions"]).map(Wp).filter(n=>n!==null),keepers:fe(t.keepers,["items","keepers"]).map(Io).filter(n=>n!==null),resident_judge_runtime:ll(t.resident_judge_runtime),persistent_agents:fe(t.persistent_agents,["items","persistent_agents"]).map(Io).filter(n=>n!==null),recent_messages:fe(t.recent_messages,["messages"]).map(Fp).filter(n=>n!==null),pending_confirms:fe(t.pending_confirms,["items","confirms"]).map(Gp).filter(n=>n!==null),available_actions:fe(t.available_actions,["actions"]).filter(m).map(n=>({action_type:r(n.action_type)??"unknown",target_type:r(n.target_type)??"unknown",description:r(n.description),confirm_required:j(n.confirm_required)}))}}function ds(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e)}catch{return String(e)}}function To(e){return e.target_id?`${e.target_type}:${e.target_id}`:e.target_type}function Gs(e){Ws.value=[{...e,id:qp++,at:new Date().toISOString()},...Ws.value].slice(0,20)}function dl(e){return e.confirm_required?ds(e.preview)||"Confirmation required":ds(e.result)||ds(e.executed_action)||ds(e.delegated_tool_result)||e.status}async function $e(){Ln.value=!0,at.value=null;try{const e=await Qc();me.value=Jp(e)}catch(e){at.value=e instanceof Error?e.message:"Failed to load operator snapshot"}finally{Ln.value=!1}}async function xt(){Nn.value=!0,Xt.value=null;try{const e=await ur({targetType:"room"});Hi.value=cl(e)}catch(e){Xt.value=e instanceof Error?e.message:"Failed to load operator digest"}finally{Nn.value=!1}}async function Zt(e){if(!e){ze.value=null;return}Nn.value=!0,Xt.value=null;try{const t=await ur({targetType:"team_session",targetId:e,includeWorkers:!0});ze.value=cl(t)}catch(t){Xt.value=t instanceof Error?t.message:"Failed to load session digest"}finally{Nn.value=!1}}async function ul(e){var t;V.value=!0,at.value=null;try{const n=await fa(e);return Gs({actor:e.actor,action_type:e.action_type,target_label:To(e),outcome:n.confirm_required?"preview":"executed",message:dl(n),delegated_tool:n.delegated_tool}),await $e(),await xt(),(t=ze.value)!=null&&t.target_id&&await Zt(ze.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw at.value=s,Gs({actor:e.actor,action_type:e.action_type,target_label:To(e),outcome:"error",message:s}),n}finally{V.value=!1}}async function pl(e,t,n="confirm"){var s;V.value=!0,at.value=null;try{const a=await pr(e,t,n);return Gs({actor:e,action_type:n,target_label:t,outcome:"confirmed",message:dl(a),delegated_tool:a.delegated_tool}),await $e(),await xt(),(s=ze.value)!=null&&s.target_id&&await Zt(ze.value.target_id),a}catch(a){const o=a instanceof Error?a.message:"Operator confirmation failed";throw at.value=o,Gs({actor:e,action_type:"confirm",target_label:t,outcome:"error",message:o}),a}finally{V.value=!1}}Du(()=>{var e;$e(),xt(),(e=ze.value)!=null&&e.target_id&&Zt(ze.value.target_id)});function Vp(e){switch(e){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Qp(e){switch(e){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Yp(e){switch(e.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return e.role}}function Ro(e){return e.delivery==="error"||e.delivery==="timeout"?"bad":e.delivery==="sending"?"warn":e.role==="assistant"?"assistant":e.role==="user"?"user":"warn"}function ml(e){if(!e)return null;const t=new Date(e);return Number.isNaN(t.getTime())?null:t.toLocaleTimeString()}function Xp(e){return typeof e!="number"||!Number.isFinite(e)||e<=0?null:e<60?`${Math.round(e)}s`:`${Math.ceil(e/60)}m`}function vl(e){if(!e)return null;const t=Fe.value[e.name];return(t==null?void 0:t.diagnostic)??e.diagnostic??null}function Zp({keeper:e,showRawStatus:t=!1}){if(ee(()=>{e!=null&&e.name&&kr(e.name)},[e==null?void 0:e.name]),!e)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Fe.value[e.name],s=vl(e),a=oi.value[e.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Vp(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Qp((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${ml(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${Xp(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${t?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function em({keeperName:e,placeholder:t}){const[n,s]=tr("");ee(()=>{e&&kr(e)},[e]);const a=le.value[e]??[],o=ri.value[e]??!1,l=Ke.value[e],c=async()=>{const p=n.trim();if(!(!e||!p)){s("");try{await su(e,p)}catch(u){const _=u instanceof Error?u.message:`Failed to message ${e}`;N(_,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(p=>i`
              <div class="keeper-conversation-item" key=${p.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Ro(p)}`}>${p.label}</span>
                  <span class=${`keeper-role-chip ${Ro(p)}`}>${Yp(p)}</span>
                  ${p.timestamp?i`<span class="keeper-conversation-time">${ml(p.timestamp)}</span>`:null}
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
  `}function tm({actor:e,keeper:t,onPokeLodge:n}){if(!t)return null;const s=vl(t),a=li.value[t.name]??!1,o=ci.value[t.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{au(t.name,e).catch(p=>{const u=p instanceof Error?p.message:`Failed to probe ${t.name}`;N(u,"error")})}}
        disabled=${a||!e.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{iu(t.name,e).catch(p=>{const u=p instanceof Error?p.message:`Failed to recover ${t.name}`;N(u,"error")})}}
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
  `}const Wi=f(null);function _l(e){Wi.value=e,nu(e.name)}function Po(){Wi.value=null}const Pt=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function nm(e){if(!e)return 0;const t=Pt.findIndex(n=>n.level===e);return t>=0?t:0}function sm({keeper:e}){const t=nm(e.autonomy_level),n=Pt[t]??Pt[0];if(!n)return null;const s=(t+1)/Pt.length*100;return i`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${t+1} / ${Pt.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${Pt.map((a,o)=>i`
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
            <strong><${W} timestamp=${e.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${e.active_goal_ids&&e.active_goal_ids.length>0?i`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${e.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Ps(e){return e?e>=1e6?`${(e/1e6).toFixed(1)}M`:e>=1e3?`${(e/1e3).toFixed(1)}K`:String(e):"—"}function am(e){switch(e){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(e==null?void 0:e.trim())||"action"}}function im(e){return e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]}function om(e){const t=e.metrics_window;return(Array.isArray(t==null?void 0:t.top_tools)?t.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function rm(e){const t=Jn.value;return t?t.keeper_briefs.find(n=>n.name===e.name||n.agent_name&&e.agent_name&&n.agent_name===e.agent_name)??null:null}function lm({keeper:e}){const t=e.metrics_series??[],n=t[t.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:e.generation??"-",hint:"Succession count"},{label:"Turns",value:e.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:e.context_ratio!=null?`${Math.round(e.context_ratio*100)}%`:"-",hint:e.context_ratio!=null&&e.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:e.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Ps(e.context_tokens)}</div>
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
  `}function cm({keeper:e}){var _,g;const t=e.metrics_series??[];if(t.length<2){const v=(((_=e.context)==null?void 0:_.context_ratio)??0)*100,y=v>85?"#ef4444":v>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${v.toFixed(1)}%;background:${y}"></div>
        </div>
        <span class="chart-pct">${v.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=t.length,l=t.map((v,y)=>{const S=a+y/(o-1)*(n-2*a),$=s-a-(v.context_ratio??0)*(s-2*a);return{x:S,y:$,p:v}}),c=l.map(({x:v,y})=>`${v.toFixed(1)},${y.toFixed(1)}`).join(" "),p=(((g=t[t.length-1])==null?void 0:g.context_ratio)??0)*100,u=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return i`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${l.filter(({p:v})=>v.is_handoff).map(({x:v})=>i`
          <line x1="${v.toFixed(1)}" y1="${a}" x2="${v.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${u}" stroke-width="1.5"/>
        ${l.filter(({p:v})=>v.is_compaction).map(({x:v,y})=>i`
          <circle cx="${v.toFixed(1)}" cy="${y.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${p.toFixed(1)}%</span>
    </div>`}const Pa=f("");function dm({keeper:e}){var a,o,l,c;const t=Pa.value.toLowerCase(),n=[{title:"Name",key:"name",value:e.name},{title:"Emoji",key:"emoji",value:e.emoji??"-"},{title:"Korean",key:"koreanName",value:e.koreanName??"-"},{title:"Model",key:"model",value:e.model??"-"},{title:"Status",key:"status",value:e.status},{title:"Primary",key:"primaryValue",value:e.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(e.activityLevel??"-")},{title:"Gen",key:"generation",value:String(e.generation??"-")},{title:"Turns",key:"turn_count",value:String(e.turn_count??"-")},{title:"Context",key:"context_ratio",value:e.context_ratio!=null?`${Math.round(e.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:e.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=e.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=e.interests)==null?void 0:o.join(", "))||"-"}],s=t?n.filter(p=>p.title.toLowerCase().includes(t)||p.key.includes(t)||p.value.toLowerCase().includes(t)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Pa.value}
        onInput=${p=>{Pa.value=p.target.value}}
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
      ${e.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Ps(e.context_tokens)}</span></div>`:""}
      ${e.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Ps(e.context_max)}</span></div>`:""}
      ${e.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${e.memory_recent_note}</span></div>`:""}
      ${e.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${e.k2k_count}</span></div>`:""}
      ${e.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${e.conversation_tail_count}</span></div>`:""}
      ${e.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${e.handoff_count_total}</span></div>`:""}
      ${e.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${e.compaction_count}</span></div>`:""}
      ${e.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Ps(e.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=e.context)==null?void 0:l.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${e.context.message_count}</span></div>`:""}
      ${((c=e.context)==null?void 0:c.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${e.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function um({stats:e}){const t=e.max_hp>0?Math.round(e.hp/e.max_hp*100):0,n=e.max_mp>0?Math.round(e.mp/e.max_mp*100):0;return i`
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
  `}function pm({items:e}){return e.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${e.map((t,n)=>i`
        <div class="keeper-equipment-row">
          <span>${t}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function mm({rels:e}){const t=Object.entries(e);return t.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${t.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Lo({traits:e,label:t}){return e.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${t}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${e.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function La(e){return e==null||Number.isNaN(e)?"-":`${Math.round(e*100)}%`}function vm({keeper:e}){const t=e.metrics_window,n=[{label:"Model fallback",value:La(typeof(t==null?void 0:t.model_fallback_rate)=="number"?t.model_fallback_rate:void 0)},{label:"Proactive fallback",value:La(typeof(t==null?void 0:t.proactive_fallback_rate)=="number"?t.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:La(typeof(t==null?void 0:t.memory_pass_rate)=="number"?t.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(t==null?void 0:t.handoff_count)=="number"?t.handoff_count:e.handoff_count_total??"-"},{label:"Compactions",value:typeof(t==null?void 0:t.compaction_events)=="number"?t.compaction_events:e.compaction_count??"-"},{label:"Saved tokens",value:typeof(t==null?void 0:t.compaction_saved_tokens)=="number"?t.compaction_saved_tokens:e.last_compaction_saved_tokens??"-"},{label:"K2K events",value:e.k2k_count??"-"},{label:"Conversation tail",value:e.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(t==null?void 0:t.tool_call_count)=="number"?t.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(t==null?void 0:t.proactive_preview_similarity_avg)=="number"?`${(t.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(t==null?void 0:t.memory_avg_score)=="number"?t.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(t==null?void 0:t.fallback_rate)=="number"?`${(t.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(s=>i`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function _m({keeper:e}){var $,A,b,I,R,T,P;const t=(($=me.value)==null?void 0:$.room)??{},n=(((A=me.value)==null?void 0:A.available_actions)??[]).filter(L=>L.target_type==="keeper"||L.target_type==="room").slice(0,8),s=im(e),a=om(e),o=rm(e),l=(o==null?void 0:o.allowed_tool_names)??[],c=(o==null?void 0:o.latest_tool_names)??[],p=o==null?void 0:o.latest_tool_call_count,u=o==null?void 0:o.tool_audit_source,_=o==null?void 0:o.tool_audit_at,g=((b=e.agent)==null?void 0:b.capabilities)??[],v=t.current_room??t.room_id??((I=ie.value)==null?void 0:I.room)??"default",y=t.project??((R=ie.value)==null?void 0:R.project)??"확인 없음",S=t.cluster??((T=ie.value)==null?void 0:T.cluster)??"확인 없음";return i`
    <div class="keeper-signal-list">
      <div class="keeper-signal-row">
        <span>Room</span>
        <strong>${v}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Project</span>
        <strong>${y}</strong>
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
        <strong>${u??"unreported"}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Observed at</span>
        <strong>${_?i`<${W} timestamp=${_} />`:"unreported"}</strong>
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
          ${g.length>0?g.map(L=>i`<span class="pill">${L}</span>`):i`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(L=>i`<span class="pill">${am(L.action_type)}</span>`):i`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function gl(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(t??n??"dashboard").trim()||"dashboard"}async function gm(){try{const e=await fa({actor:gl(),action_type:"lodge_tick",target_type:"room",payload:{}}),t=br(e.result);await Gn(),t!=null&&t.skipped_reason?N(t.skipped_reason,"warning"):N(t?`Poke finished: ${t.acted}/${t.checked} acted`:"Poke finished",t&&t.acted>0?"success":"warning")}catch(e){const t=e instanceof Error?e.message:"Failed to run Lodge poke";N(t,"error")}}function fm({keeper:e}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Zp} keeper=${e} />
          <${tm}
            actor=${gl()}
            keeper=${e}
            onPokeLodge=${()=>{gm()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${em}
            keeperName=${e.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function $m(){var t,n,s;const e=Wi.value;return e?i`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Po()}}
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
            <${lt} status=${e.status} />
            ${e.model?i`<span class="pill">${e.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Po()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${lm} keeper=${e} />

        ${""}
        <${cm} keeper=${e} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${C} title="Field Dictionary">
            <${dm} keeper=${e} />
          <//>

          ${""}
          <${C} title="Profile">
            <${Lo} traits=${e.traits??[]} label="Traits" />
            <${Lo} traits=${e.interests??[]} label="Interests" />
            ${e.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${e.primaryValue}</span></div>`:null}
            ${e.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${e.skill_primary}</span>
                </div>`:null}
            ${e.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${e.skill_reason}</div>`:null}
            ${e.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${W} timestamp=${e.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${e.autonomy_level?i`
              <${C} title="Autonomy">
                <${sm} keeper=${e} />
              <//>
            `:null}

          ${""}
          ${e.trpg_stats?i`
              <${C} title="TRPG Stats">
                <${um} stats=${e.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${e.inventory&&e.inventory.length>0?i`
              <${C} title="Equipment (${e.inventory.length})">
                <${pm} items=${e.inventory} />
              <//>
            `:null}

          ${""}
          ${e.relationships&&Object.keys(e.relationships).length>0?i`
              <${C} title="Relationships (${Object.keys(e.relationships).length})">
                <${mm} rels=${e.relationships} />
              <//>
            `:null}

          <${C} title="Runtime Signals">
            <${vm} keeper=${e} />
          <//>

          <${C} title="Neighborhood & Tool Audit">
            <${_m} keeper=${e} />
          <//>

          <${C} title="Memory & Context">
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
        <${fm} keeper=${e} />
      </div>
    </div>
  `:null}function hm({cluster:e,project:t,room:n,generatedAt:s}){return i`
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
        <strong>${s?we(s):"fresh"}</strong>
      </div>
    </div>
  `}function Tt({label:e,value:t,detail:n,tone:s}){return i`
    <article class="mission-stat-card ${pe(s)}">
      <span class="mission-stat-label">${e}</span>
      <strong class="mission-stat-value">${t}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function ym(){const e=Fr.value,t=pe((e==null?void 0:e.status)??(ft.value?"bad":"warn")),n=!e||e.sections.length===0,s=(e==null?void 0:e.status)==="error"||(e==null?void 0:e.status)==="unavailable"&&!(e!=null&&e.cached);return i`
    <${C} title="LLM 판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>heuristic 대신 별도 판단 계층</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${t}">
          ${(e==null?void 0:e.status)??(ft.value?"error":"loading")}
        </span>
        ${e!=null&&e.model?i`<span class="command-chip">${e.model}</span>`:null}
        ${e!=null&&e.generated_at?i`<span class="command-chip">${we(e.generated_at)}</span>`:null}
        ${e!=null&&e.cached?i`<span class="command-chip">cached</span>`:null}
        ${e!=null&&e.stale?i`<span class="command-chip warn">stale</span>`:null}
        ${e!=null&&e.refreshing?i`<span class="command-chip warn">refreshing</span>`:null}
      </div>

      ${ft.value?i`<div class="empty-state error">${ft.value}</div>`:null}
      ${e!=null&&e.error?i`<div class="empty-state error">${e.error}</div>`:null}
      ${e!=null&&e.summary?i`<div class="mission-inline-note">${e.summary}</div>`:null}
      ${e!=null&&e.last_error&&!e.error?i`<div class="mission-inline-note">최근 refresh 실패: ${e.last_error}</div>`:null}

      ${e&&e.sections.length>0?i`
            <div class="mission-briefing-grid">
              ${e.sections.slice(0,3).map(a=>i`
                <article class="mission-briefing-section ${pe(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${pe(a.status)}">${a.status}</span>
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
          `:!zt.value&&!ft.value&&n?i`
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
        <button class="control-btn ghost" onClick=${()=>{Ks(s)}} disabled=${zt.value}>
          ${zt.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{Ks(!0)}} disabled=${zt.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function bm({item:e,selected:t,sessionLookup:n}){const s=Sp(e),a=e.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),o=e.top_action??null;return i`
    <article class="mission-attention-card ${pe((o==null?void 0:o.severity)??e.severity)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>Ip(e.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${e.summary}</strong>
            <div class="mission-card-target">${e.kind}${e.target_id?` · ${e.target_id}`:""}</div>
          </div>
          <span class="command-chip ${pe((o==null?void 0:o.severity)??e.severity)}">${o?kp(o):e.severity}</span>
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
            <strong>${e.last_seen_at?we(e.last_seen_at):"n/a"}</strong>
            <small>${e.target_type}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${o?ha(o.action_type):"판단 필요"}</strong>
            <small>${o?xp(o):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${o?i`<div class="mission-inline-note">${o.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?i`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>i`
                  <button class="mission-link-row" onClick=${()=>sl(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${l.status??"unknown"} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:i`<div class="empty-state">직접 연결된 session이 아직 없습니다.</div>`}

        ${e.related_agent_names.length>0?i`
              <div class="mission-pill-row">
                ${e.related_agent_names.slice(0,8).map(l=>i`
                  <button class="mission-pill action" onClick=${()=>ba(l)}>${l}</button>
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
              <button class="control-btn ghost" onClick=${()=>Ui(o,s,"Mission attention")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>nl(o,s,"Mission attention")}>
                원인 보기
              </button>
            `:i`
              <button class="control-btn ghost" onClick=${()=>el(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>tl(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function km({brief:e,selected:t}){var o,l;const n=e.member_previews.slice(0,4),s=e.top_recommendation??null,a=e.top_attention??null;return i`
    <article class="mission-crew-card ${pe(((o=e.top_attention)==null?void 0:o.severity)??e.health??e.status)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>sl(e.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${e.goal}</strong>
            <div class="mission-card-target">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          </div>
          <span class="command-chip ${pe(((l=e.top_attention)==null?void 0:l.severity)??e.health??e.status)}">${e.status??"unknown"}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${e.member_names.length}</strong>
            <small>${e.member_names.slice(0,3).join(", ")||"n/a"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${bp(e.elapsed_sec)}</strong>
            <small>${e.started_at?`${we(e.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>최근 흐름</span>
            <strong>${e.last_event_at?we(e.last_event_at):"n/a"}</strong>
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
        <small>${e.last_event_at?we(e.last_event_at):"시각 없음"}</small>
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
                <button class="mission-member-preview" onClick=${()=>ba(c.agent_name)}>
                  <strong>${c.agent_name}</strong>
                  <span>${c.current_work??"현재 작업 없음"}</span>
                  <small>${c.recent_output_preview??c.recent_input_preview??"최근 입출력 없음"}</small>
                </button>
              `)}
            </div>
          `:null}

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>$i("intervene",e.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>$i("command",e.session_id)}>세션 원인 보기</button>
        ${s?i`<button class="control-btn ghost" onClick=${()=>Ui(s,a,"Mission session brief")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function xm({detail:e,loading:t,error:n}){if(t&&!e)return i`
      <${C} title="세션 상세" class="mission-list-card">
        <div class="loading-indicator">세션 상세 불러오는 중...</div>
      <//>
    `;if(n&&!e)return i`
      <${C} title="세션 상세" class="mission-list-card">
        <div class="empty-state error">${n}</div>
      <//>
    `;if(!(e!=null&&e.session))return null;const s=e.session;return i`
    <${C} title="세션 상세" class="mission-list-card" semanticId="mission.session_detail">
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
                      <span>${a.timestamp?we(a.timestamp):"n/a"}</span>
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
                  <button class="mission-member-preview" onClick=${()=>ba(a.agent_name)}>
                    <strong>${a.agent_name}</strong>
                    <span>${a.current_work??"현재 작업 없음"}</span>
                    <small>
                      ${a.recent_output_preview??a.recent_input_preview??"최근 입출력 없음"}
                      ${a.last_activity_at?` · ${we(a.last_activity_at)}`:""}
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
                  <button class="mission-link-row" onClick=${()=>$i("command",s.session_id)}>
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
  `}function Sm({row:e}){var n,s,a,o,l,c,p,u,_,g;const t=[`gen ${e.brief.generation??((n=e.keeper)==null?void 0:n.generation)??0}`,e.brief.context_ratio!=null?`ctx ${Math.round(e.brief.context_ratio*100)}%`:((s=e.keeper)==null?void 0:s.context_ratio)!=null?`ctx ${Math.round(e.keeper.context_ratio*100)}%`:null,e.brief.last_turn_ago_s!=null?`last turn ${Math.round(e.brief.last_turn_ago_s)}s`:null].filter(v=>v!==null).join(" · ");return i`
    <article class="mission-activity-card ${pe(e.brief.status??((a=e.keeper)==null?void 0:a.status))}">
      <button class="mission-card-select" onClick=${()=>{e.keeper&&_l(e.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((o=e.keeper)==null?void 0:o.emoji)??""}</span>
            <div>
              <strong>${e.brief.name}</strong>
              ${(l=e.keeper)!=null&&l.koreanName?i`<span>${e.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${pe(e.brief.status??((c=e.keeper)==null?void 0:c.status))}">${e.brief.status??((p=e.keeper)==null?void 0:p.status)??"unknown"}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 heartbeat · ${(u=e.keeper)!=null&&u.last_heartbeat?we(e.keeper.last_heartbeat):"n/a"}</span>
          <span>${t||"continuity 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${e.currentWork}</strong>
          ${(_=e.keeper)!=null&&_.skill_reason?i`<small>판단 요약 · ${Ce(e.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>continuity detail</summary>
        <div class="mission-activity-foot">
          <span>agent · ${e.brief.agent_name??((g=e.keeper)==null?void 0:g.agent_name)??"n/a"}</span>
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
  `}function Am({item:e}){const t=e.action??null,n=e.attention??null;return i`
    <article class="mission-action-card ${pe(e.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${pe(e.severity)}">
          ${e.signal_type==="action"&&t?ha(t.action_type):(n==null?void 0:n.kind)??"signal"}
        </span>
        <span class="mission-card-target">${e.target_type}${e.target_id?` · ${e.target_id}`:""}</span>
      </div>
      <p>${e.summary}</p>
      ${t?i`<div class="mission-action-preview">${t.reason}</div>`:null}
      <div class="mission-card-actions">
        ${t?i`
              <button class="control-btn ghost" onClick=${()=>Ui(t,n,"Mission internal signal")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>nl(t,n,"Mission internal signal")}>이 이슈의 원인 보기</button>
            `:n?i`
                <button class="control-btn ghost" onClick=${()=>el(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>tl(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function No(){var y,S,$,A;const e=Jn.value;if(_i.value&&!e)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(Fs.value&&!e)return i`<div class="empty-state error">${Fs.value}</div>`;if(!e)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;Oe.value&&!e.attention_queue.some(b=>b.id===Oe.value)&&(Oe.value=null);const t=e.sessions;Ve.value&&!t.some(b=>b.session_id===Ve.value)&&(Ve.value=null);const n=e.attention_queue.find(b=>b.id===Oe.value)??null,s=(n==null?void 0:n.related_session_ids.find(b=>t.some(I=>I.session_id===b)))??null,a=Ve.value??s??((y=t[0])==null?void 0:y.session_id)??null,o=Cp(),l=t.find(b=>b.session_id===a)??null,c=e.keeper_briefs.slice(0,6).map(Ap),p=e.attention_queue.filter(b=>b.related_session_ids.length>0).slice(0,6),u=e.internal_signals.slice(0,3),_=t.filter(b=>{var R;const I=((R=b.top_attention)==null?void 0:R.severity)??b.health??b.status;return pe(I)!=="ok"||!!b.blocker_summary}).length,g=new Set(t.flatMap(b=>b.member_names)).size,v=t.flatMap(b=>b.member_previews??[]).filter(b=>b.recent_output_preview).length+c.filter(b=>b.recentOutput).length;return ee(()=>{cp(a)},[a]),i`
    <section class="dashboard-panel mission-view">
      <${he} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>지금 어떤 세션이 돌고 있고, 누가 참여하며, 어디가 막혔는지를 한 시점에서 읽는 기본 관찰면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${pe(e.summary.room_health)}">${e.summary.room_health??"ok"}</span>
          <span class="command-chip">${e.summary.project??"room"}${e.summary.current_room?` · ${e.summary.current_room}`:""}</span>
          <span class="command-chip">${e.generated_at?we(e.generated_at):"fresh"}</span>
        </div>
      </div>

      <${hm}
        cluster=${e.summary.cluster}
        project=${e.summary.project}
        room=${e.summary.current_room}
        generatedAt=${e.generated_at}
      />

      <${ym} />

      <div class="mission-stat-grid">
        <${Tt} label="활성 세션" value=${t.length} detail="지금 진행중인 협업 단위" tone=${((S=l==null?void 0:l.top_attention)==null?void 0:S.severity)??(l==null?void 0:l.health)??"ok"} />
        <${Tt} label="막힌 세션" value=${_} detail="주의가 필요한 흐름" tone=${_>0?"warn":"ok"} />
        <${Tt} label="참여자" value=${g} detail="현재 세션에 연결된 actor" tone=${g>0?"ok":"warn"} />
        <${Tt} label="Keeper watch" value=${c.length} detail="continuity lane 관찰 대상" tone=${(($=c[0])==null?void 0:$.brief.status)??"ok"} />
        <${Tt} label="최근 output" value=${v} detail="메인에서 바로 읽을 수 있는 출력 수" tone=${v>0?"ok":"warn"} />
        <${Tt} label="내부 신호" value=${u.length} detail="시스템 진단은 보조 lane" tone=${((A=u[0])==null?void 0:A.severity)??"ok"} />
      </div>

      ${a?i`
            <div class="mission-selection-bar">
              <span>현재 관찰 세션 · ${(l==null?void 0:l.goal)??a}${n?` · ${n.summary}`:""}</span>
              <button class="control-btn ghost" onClick=${Tp}>선택 해제</button>
            </div>
          `:null}

      <${C} title="진행중인 세션" class="mission-list-card" semanticId="mission.session_briefs">
        <div class="mission-section-head">
          <h3>지금 진행중인 일</h3>
          <p>세션을 기준으로 목표, 최근 흐름, 막힘, 연결된 operation을 먼저 봅니다.</p>
        </div>
        <div class="mission-list-stack">
          ${t.length>0?t.map(b=>i`<${km} key=${b.session_id} brief=${b} selected=${a===b.session_id} />`):i`<div class="empty-state">지금 활성 세션이 없습니다.</div>`}
        </div>
      <//>

      <${xm}
        detail=${gi.value}
        loading=${Ts.value}
        error=${Rs.value}
      />

      <div class="mission-human-grid">
        <${C} title="Attention Queue" class="mission-list-card" semanticId="mission.attention_queue">
          <div class="mission-section-head">
            <h3>어느 세션을 먼저 봐야 하나</h3>
            <p>문제와 경고는 세션에 연결된 것만 먼저 보여주고, 원인 분석은 선택된 세션에서 이어서 봅니다.</p>
          </div>
          <div class="mission-lane-stack">
            ${p.length>0?p.map(b=>i`<${bm} key=${b.id} item=${b} selected=${Oe.value===b.id} sessionLookup=${o} />`):i`<div class="empty-state">지금 session-level attention queue가 비어 있습니다.</div>`}
          </div>
        <//>

        <${C} title="Internal Signals" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>시스템 진단</h3>
            <p>artifact scope drift 같은 내부 신호는 메인 판단을 방해하지 않도록 접어둔 보조 lane으로만 유지합니다.</p>
          </div>
          <details class="mission-card-disclosure">
            <summary>내부 신호 ${u.length}</summary>
            <div class="mission-list-stack">
              ${u.length>0?u.map(b=>i`<${Am} key=${b.id} item=${b} />`):i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
            </div>
          </details>
        <//>
      </div>

      <${C} title="Keeper Continuity" class="mission-list-card" semanticId="mission.keeper_activity">
        <div class="mission-section-head">
          <h3>continuity lane</h3>
          <p>keeper는 세션과 별개로 보고, continuity 판단에 필요한 정보만 먼저 보여줍니다.</p>
        </div>
        <div class="mission-activity-list">
          ${c.length>0?c.map(b=>i`<${Sm} key=${b.brief.name} row=${b} />`):i`<div class="empty-state">지금 보이는 keeper가 없습니다.</div>`}
        </div>
        <div class="mission-card-actions">
          <button class="control-btn ghost" onClick=${()=>ce("execution")}>실행 관찰면 보기</button>
          <button class="control-btn ghost" onClick=${()=>ce("command")}>지휘 진단면 보기</button>
        </div>
      <//>
    </section>
  `}const fl=f(null),hi=f(!1),Mt=f(null);async function $l(e,t){hi.value=!0,Mt.value=null;try{fl.value=await Jc(e,t)}catch(n){Mt.value=n instanceof Error?n.message:String(n)}finally{hi.value=!1}}const Cm="modulepreload",Im=function(e){return"/dashboard/"+e},wo={},Tm=function(t,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(u){return Promise.all(u.map(_=>Promise.resolve(_).then(g=>({status:"fulfilled",value:g}),g=>({status:"rejected",reason:g}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),p=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(u=>{if(u=Im(u),u in wo)return;wo[u]=!0;const _=u.endsWith(".css"),g=_?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${u}"]${g}`))return;const v=document.createElement("link");if(v.rel=_?"stylesheet":Cm,_||(v.as="script"),v.crossOrigin="",v.href=u,p&&v.setAttribute("nonce",p),document.head.appendChild(v),_)return new Promise((y,S)=>{v.addEventListener("load",y),v.addEventListener("error",()=>S(new Error(`Unable to preload CSS for ${u}`)))})}))}function o(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&o(c.reason);return t().catch(o)})},Gi=f(null),je=f(null),Js=f(!1),Vs=f(!1),Qs=f(null),Ys=f(null),yi=f(null),Xs=f(null),Y=f("warroom"),Qn=f(null),bi=f(!1),Zs=f(null),At=f(null),ea=f(!1),ta=f(null),Yn=f(null),ki=f(!1),na=f(null),wn=f(null),sa=f(!1),zn=f(null),Gt=f(null);let mn=null;function Ji(e){return e!=="summary"&&e!=="swarm"&&e!=="warroom"}function hl(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,o)=>{e.has(o)||e.set(o,a)}),e}function Rm(){const t=hl().get("run_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function Pm(){const t=hl().get("operation_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function Lm(e){if(m(e))return{policy_class:r(e.policy_class),approval_class:r(e.approval_class),tool_allowlist:H(e.tool_allowlist),model_allowlist:H(e.model_allowlist),requires_human_for:H(e.requires_human_for),autonomy_level:r(e.autonomy_level),escalation_timeout_sec:d(e.escalation_timeout_sec),kill_switch:j(e.kill_switch),frozen:j(e.frozen)}}function Nm(e){if(m(e))return{headcount_cap:d(e.headcount_cap),active_operation_cap:d(e.active_operation_cap),max_cost_usd:d(e.max_cost_usd),max_tokens:d(e.max_tokens)}}function Vi(e){if(!m(e))return null;const t=r(e.unit_id),n=r(e.label),s=r(e.kind);return!t||!n||!s?null:{unit_id:t,label:n,kind:s,parent_unit_id:r(e.parent_unit_id)??null,leader_id:r(e.leader_id)??null,roster:H(e.roster),capability_profile:H(e.capability_profile),source:r(e.source),created_at:r(e.created_at),updated_at:r(e.updated_at),policy:Lm(e.policy),budget:Nm(e.budget)}}function yl(e){if(!m(e))return null;const t=Vi(e.unit);return t?{unit:t,leader_status:r(e.leader_status),roster_total:d(e.roster_total),roster_live:d(e.roster_live),active_operation_count:d(e.active_operation_count),health:r(e.health),reasons:H(e.reasons),children:Array.isArray(e.children)?e.children.map(yl).filter(n=>n!==null):[]}:null}function wm(e){if(m(e))return{total_units:d(e.total_units),company_count:d(e.company_count),platoon_count:d(e.platoon_count),squad_count:d(e.squad_count),leaf_agent_unit_count:d(e.leaf_agent_unit_count),live_agent_count:d(e.live_agent_count),managed_unit_count:d(e.managed_unit_count),active_operation_count:d(e.active_operation_count)}}function bl(e){const t=m(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),source:r(t.source),summary:wm(t.summary),units:Array.isArray(t.units)?t.units.map(yl).filter(n=>n!==null):[]}}function zm(e){if(!m(e))return null;const t=r(e.kind),n=r(e.status);return!t||!n?null:{kind:t,chain_id:r(e.chain_id)??null,goal:r(e.goal)??null,run_id:r(e.run_id)??null,status:n,viewer_path:r(e.viewer_path)??null,last_sync_at:r(e.last_sync_at)??null}}function ka(e){if(!m(e))return null;const t=r(e.operation_id),n=r(e.objective),s=r(e.assigned_unit_id),a=r(e.trace_id),o=r(e.status);return!t||!n||!s||!a||!o?null:{operation_id:t,objective:n,assigned_unit_id:s,autonomy_level:r(e.autonomy_level),policy_class:r(e.policy_class),budget_class:r(e.budget_class),detachment_session_id:r(e.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(e.checkpoint_ref)??null,active_goal_ids:H(e.active_goal_ids),note:r(e.note)??null,created_by:r(e.created_by),source:r(e.source),status:o,chain:zm(e.chain),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function Mm(e){if(!m(e))return null;const t=ka(e.operation);return t?{operation:t,assigned_unit_label:r(e.assigned_unit_label)}:null}function un(e){if(m(e))return{tone:r(e.tone),pending_ops:d(e.pending_ops),blocked_ops:d(e.blocked_ops),in_flight_ops:d(e.in_flight_ops),pipeline_stalls:d(e.pipeline_stalls),bus_traffic:d(e.bus_traffic),l1_hit_rate:d(e.l1_hit_rate),invalidation_count:d(e.invalidation_count),current_pending:d(e.current_pending),current_in_flight:d(e.current_in_flight),cdb_wakeups:d(e.cdb_wakeups),total_stolen:d(e.total_stolen),avg_best_score:d(e.avg_best_score),avg_candidate_count:d(e.avg_candidate_count),best_first_operations:d(e.best_first_operations),active_sessions:d(e.active_sessions),commit_rate:d(e.commit_rate),total_speculations:d(e.total_speculations)}}function jm(e){if(!m(e))return;const t=m(e.pipeline)?e.pipeline:void 0,n=m(e.cache)?e.cache:void 0,s=m(e.ooo)?e.ooo:void 0,a=m(e.speculative)?e.speculative:void 0,o=m(e.search_fabric)?e.search_fabric:void 0,l=m(e.signals)?e.signals:void 0;return{pipeline:t?{total_ops:d(t.total_ops),completed_ops:d(t.completed_ops),stalled_cycles:d(t.stalled_cycles),hazards_detected:d(t.hazards_detected),forwarding_used:d(t.forwarding_used),pipeline_flushes:d(t.pipeline_flushes),ipc:d(t.ipc)}:void 0,cache:n?{total_reads:d(n.total_reads),total_writes:d(n.total_writes),l1_hit_rate:d(n.l1_hit_rate),invalidation_count:d(n.invalidation_count),writeback_count:d(n.writeback_count),bus_traffic:d(n.bus_traffic)}:void 0,ooo:s?{agent_count:d(s.agent_count),total_added:d(s.total_added),total_issued:d(s.total_issued),total_completed:d(s.total_completed),total_stolen:d(s.total_stolen),cdb_wakeups:d(s.cdb_wakeups),stall_cycles:d(s.stall_cycles),global_cdb_events:d(s.global_cdb_events),current_pending:d(s.current_pending),current_in_flight:d(s.current_in_flight)}:void 0,speculative:a?{total_speculations:d(a.total_speculations),total_commits:d(a.total_commits),total_aborts:d(a.total_aborts),commit_rate:d(a.commit_rate),total_fast_calls:d(a.total_fast_calls),total_cost_usd:d(a.total_cost_usd),active_sessions:d(a.active_sessions)}:void 0,search_fabric:o?{total_operations:d(o.total_operations),best_first_operations:d(o.best_first_operations),legacy_operations:d(o.legacy_operations),blocked_operations:d(o.blocked_operations),ready_operations:d(o.ready_operations),research_pipeline_operations:d(o.research_pipeline_operations),avg_candidate_count:d(o.avg_candidate_count),avg_best_score:d(o.avg_best_score),top_stage:r(o.top_stage)??null}:void 0,signals:l?{issue_pressure:un(l.issue_pressure),cache_contention:un(l.cache_contention),scheduler_efficiency:un(l.scheduler_efficiency),routing_confidence:un(l.routing_confidence),speculative_posture:un(l.speculative_posture)}:void 0}}function kl(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),paused:d(n.paused),managed:d(n.managed),projected:d(n.projected)}:void 0,microarch:jm(t.microarch),operations:Array.isArray(t.operations)?t.operations.map(Mm).filter(s=>s!==null):[]}}function xl(e){if(!m(e))return null;const t=r(e.detachment_id),n=r(e.operation_id),s=r(e.assigned_unit_id);return!t||!n||!s?null:{detachment_id:t,operation_id:n,assigned_unit_id:s,leader_id:r(e.leader_id)??null,roster:H(e.roster),session_id:r(e.session_id)??null,checkpoint_ref:r(e.checkpoint_ref)??null,runtime_kind:r(e.runtime_kind)??null,runtime_ref:r(e.runtime_ref)??null,source:r(e.source),status:r(e.status),last_event_at:r(e.last_event_at)??null,last_progress_at:r(e.last_progress_at)??null,heartbeat_deadline:r(e.heartbeat_deadline)??null,created_at:r(e.created_at),updated_at:r(e.updated_at)}}function Em(e){if(!m(e))return null;const t=xl(e.detachment);return t?{detachment:t,assigned_unit_label:r(e.assigned_unit_label),operation:ka(e.operation)}:null}function Sl(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),projected:d(n.projected)}:void 0,detachments:Array.isArray(t.detachments)?t.detachments.map(Em).filter(s=>s!==null):[]}}function Dm(e){if(!m(e))return null;const t=r(e.decision_id),n=r(e.trace_id),s=r(e.requested_action),a=r(e.scope_type),o=r(e.scope_id);return!t||!n||!s||!a||!o?null:{decision_id:t,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:r(e.operation_id)??null,target_unit_id:r(e.target_unit_id)??null,requested_by:r(e.requested_by),status:r(e.status),reason:r(e.reason)??null,source:r(e.source),detail:e.detail,created_at:r(e.created_at),decided_at:r(e.decided_at)??null,expires_at:r(e.expires_at)??null}}function Al(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),pending:d(n.pending),approved:d(n.approved),denied:d(n.denied)}:void 0,decisions:Array.isArray(t.decisions)?t.decisions.map(Dm).filter(s=>s!==null):[]}}function Om(e){if(!m(e))return null;const t=Vi(e.unit);return t?{unit:t,roster_total:d(e.roster_total),roster_live:d(e.roster_live),headcount_cap:d(e.headcount_cap),active_operations:d(e.active_operations),active_operation_cap:d(e.active_operation_cap),utilization:d(e.utilization)}:null}function qm(e){const t=m(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),capacity:Array.isArray(t.capacity)?t.capacity.map(Om).filter(n=>n!==null):[]}}function Fm(e){if(!m(e))return null;const t=r(e.alert_id);return t?{alert_id:t,severity:r(e.severity),kind:r(e.kind),scope_type:r(e.scope_type),scope_id:r(e.scope_id),title:r(e.title),detail:r(e.detail),timestamp:r(e.timestamp)}:null}function Cl(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),bad:d(n.bad),warn:d(n.warn)}:void 0,alerts:Array.isArray(t.alerts)?t.alerts.map(Fm).filter(s=>s!==null):[]}}function Il(e){if(!m(e))return null;const t=r(e.event_id),n=r(e.trace_id),s=r(e.event_type);return!t||!n||!s?null:{event_id:t,trace_id:n,event_type:s,operation_id:r(e.operation_id)??null,unit_id:r(e.unit_id)??null,actor:r(e.actor)??null,source:r(e.source),timestamp:r(e.timestamp),detail:e.detail}}function Km(e){const t=m(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),events:Array.isArray(t.events)?t.events.map(Il).filter(n=>n!==null):[]}}function Um(e){if(!m(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s}}function Bm(e){if(!m(e))return null;const t=r(e.lane_id),n=r(e.label),s=r(e.kind),a=r(e.phase),o=r(e.motion_state),l=r(e.source_of_truth),c=r(e.movement_reason),p=r(e.current_step);if(!t||!n||!s||!a||!o||!l||!c||!p)return null;const u=m(e.counts)?e.counts:{};return{lane_id:t,label:n,kind:s,present:j(e.present)??!1,phase:a,motion_state:o,source_of_truth:l,last_movement_at:r(e.last_movement_at)??null,movement_reason:c,current_step:p,blockers:H(e.blockers),counts:{operations:d(u.operations),detachments:d(u.detachments),workers:d(u.workers),approvals:d(u.approvals),alerts:d(u.alerts)},hard_flags:Array.isArray(e.hard_flags)?e.hard_flags.map(Um).filter(_=>_!==null):[]}}function Hm(e){if(!m(e))return null;const t=r(e.event_id),n=r(e.lane_id),s=r(e.kind),a=r(e.timestamp),o=r(e.title),l=r(e.detail),c=r(e.tone),p=r(e.source);return!t||!n||!s||!a||!o||!l||!c||!p?null:{event_id:t,lane_id:n,kind:s,timestamp:a,title:o,detail:l,tone:c,source:p}}function Wm(e){if(!m(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s,lane_ids:H(e.lane_ids),count:d(e.count)??0}}function Tl(e){if(!m(e))return;const t=m(e.overview)?e.overview:{},n=m(e.gaps)?e.gaps:{},s=m(e.recommended_next_action)?e.recommended_next_action:void 0;return{generated_at:r(e.generated_at),overview:{active_lanes:d(t.active_lanes),moving_lanes:d(t.moving_lanes),stalled_lanes:d(t.stalled_lanes),projected_lanes:d(t.projected_lanes),last_movement_at:r(t.last_movement_at)??null},lanes:Array.isArray(e.lanes)?e.lanes.map(Bm).filter(a=>a!==null):[],timeline:Array.isArray(e.timeline)?e.timeline.map(Hm).filter(a=>a!==null):[],gaps:{count:d(n.count),items:Array.isArray(n.items)?n.items.map(Wm).filter(a=>a!==null):[]},recommended_next_action:s?{tool:r(s.tool)??"masc_operator_snapshot",label:r(s.label)??"Observe operator state",reason:r(s.reason)??"",lane_id:r(s.lane_id)??null}:void 0}}function Gm(e){if(!m(e))return;const t=m(e.workers)?e.workers:{},n=j(e.pass);return{status:r(e.status)??"missing",source:r(e.source)??"none",run_id:r(e.run_id)??null,captured_at:r(e.captured_at)??null,...n!==void 0?{pass:n}:{},...d(e.peak_hot_slots)!=null?{peak_hot_slots:d(e.peak_hot_slots)}:{},...d(e.ctx_per_slot)!=null?{ctx_per_slot:d(e.ctx_per_slot)}:{},workers:{expected:d(t.expected),joined:d(t.joined),current_task_bound:d(t.current_task_bound),fresh_heartbeats:d(t.fresh_heartbeats),done:d(t.done),final:d(t.final)},artifact_ref:r(e.artifact_ref)??null,missing_reason:r(e.missing_reason)??null}}function Jm(e){const t=m(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),topology:bl(t.topology),operations:kl(t.operations),detachments:Sl(t.detachments),alerts:Cl(t.alerts),decisions:Al(t.decisions),capacity:qm(t.capacity),traces:Km(t.traces),swarm_status:Tl(t.swarm_status)}}function Vm(e){const t=m(e)?e:{},n=bl(t.topology),s=kl(t.operations),a=Sl(t.detachments),o=Cl(t.alerts),l=Al(t.decisions);return{version:r(t.version),generated_at:r(t.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:Tl(t.swarm_status),swarm_proof:Gm(t.swarm_proof)}}function Qm(e){return m(e)?{chain_id:r(e.chain_id)??null,started_at:d(e.started_at)??null,progress:d(e.progress)??null,elapsed_sec:d(e.elapsed_sec)??null}:null}function Rl(e){if(!m(e))return null;const t=r(e.event);return t?{event:t,chain_id:r(e.chain_id)??null,timestamp:r(e.timestamp)??null,duration_ms:d(e.duration_ms)??null,message:r(e.message)??null,tokens:d(e.tokens)??null}:null}function Ym(e){if(!m(e))return null;const t=ka(e.operation);return t?{operation:t,runtime:Qm(e.runtime),history:Rl(e.history),mermaid:r(e.mermaid)??null,preview_run:Pl(e.preview_run)}:null}function Xm(e){const t=m(e)?e:{};return{status:r(t.status)??"disconnected",base_url:r(t.base_url)??null,message:r(t.message)??null}}function Zm(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),connection:Xm(t.connection),summary:n?{linked_operations:d(n.linked_operations),active_chains:d(n.active_chains),running_operations:d(n.running_operations),recent_failures:d(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(t.operations)?t.operations.map(Ym).filter(s=>s!==null):[],recent_history:Array.isArray(t.recent_history)?t.recent_history.map(Rl).filter(s=>s!==null):[]}}function ev(e){if(!m(e))return null;const t=r(e.id);return t?{id:t,type:r(e.type),status:r(e.status),duration_ms:d(e.duration_ms)??null,error:r(e.error)??null}:null}function Pl(e){if(!m(e))return null;const t=r(e.run_id),n=r(e.chain_id);return n?{run_id:t??null,chain_id:n,duration_ms:d(e.duration_ms),success:j(e.success),mermaid:r(e.mermaid),nodes:Array.isArray(e.nodes)?e.nodes.map(ev).filter(s=>s!==null):[]}:null}function tv(e){const t=m(e)?e:{};return{run:Pl(t.run)}}function nv(e){if(!m(e))return null;const t=r(e.title),n=r(e.path);return!t||!n?null:{title:t,path:n}}function sv(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary);return!t||!n||!s?null:{id:t,title:n,summary:s}}function av(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.tool),a=r(e.summary);return!t||!n||!s||!a?null:{id:t,title:n,tool:s,summary:a,success_signals:H(e.success_signals),pitfalls:H(e.pitfalls)}}function iv(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary),a=r(e.when_to_use);return!t||!n||!s||!a?null:{id:t,title:n,summary:s,when_to_use:a,steps:Array.isArray(e.steps)?e.steps.map(av).filter(o=>o!==null):[]}}function ov(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.description);return!t||!n||!s?null:{id:t,title:n,description:s,tools:H(e.tools)}}function rv(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.symptom),a=r(e.why),o=r(e.fix_tool),l=r(e.fix_summary);return!t||!n||!s||!a||!o||!l?null:{id:t,title:n,symptom:s,why:a,fix_tool:o,fix_summary:l}}function lv(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.path_id),a=r(e.transport);return!t||!n||!s||!a?null:{id:t,title:n,path_id:s,transport:a,request:e.request,response:e.response,notes:H(e.notes)}}function cv(e){const t=m(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),docs:Array.isArray(t.docs)?t.docs.map(nv).filter(n=>n!==null):[],concepts:Array.isArray(t.concepts)?t.concepts.map(sv).filter(n=>n!==null):[],golden_paths:Array.isArray(t.golden_paths)?t.golden_paths.map(iv).filter(n=>n!==null):[],tool_groups:Array.isArray(t.tool_groups)?t.tool_groups.map(ov).filter(n=>n!==null):[],pitfalls:Array.isArray(t.pitfalls)?t.pitfalls.map(rv).filter(n=>n!==null):[],examples:Array.isArray(t.examples)?t.examples.map(lv).filter(n=>n!==null):[]}}function dv(e){if(!m(e))return null;const t=r(e.id),n=r(e.title),s=r(e.status),a=r(e.detail),o=r(e.next_tool);return!t||!n||!s||!a||!o?null:{id:t,title:n,status:s,detail:a,next_tool:o}}function uv(e){if(!m(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.title),a=r(e.detail),o=r(e.next_tool);return!t||!n||!s||!a||!o?null:{code:t,severity:n,title:s,detail:a,next_tool:o}}function pv(e){if(!m(e))return null;const t=r(e.from),n=r(e.content),s=r(e.timestamp),a=d(e.seq);return!t||!n||!s||a==null?null:{seq:a,from:t,content:n,timestamp:s}}function mv(e){if(!m(e))return null;const t=r(e.name),n=r(e.role),s=r(e.lane),a=r(e.status),o=r(e.claim_marker),l=r(e.done_marker),c=r(e.final_marker);if(!t||!n||!s||!a||!o||!l||!c)return null;const p=(()=>{if(!m(e.last_message))return null;const u=d(e.last_message.seq),_=r(e.last_message.content),g=r(e.last_message.timestamp);return u==null||!_||!g?null:{seq:u,content:_,timestamp:g}})();return{name:t,role:n,lane:s,joined:j(e.joined)??!1,live_presence:j(e.live_presence)??!1,completed:j(e.completed)??!1,status:a,current_task:r(e.current_task)??null,bound_task_id:r(e.bound_task_id)??null,bound_task_title:r(e.bound_task_title)??null,bound_task_status:r(e.bound_task_status)??null,current_task_matches_run:j(e.current_task_matches_run)??!1,squad_member:j(e.squad_member)??!1,detachment_member:j(e.detachment_member)??!1,last_seen:r(e.last_seen)??null,heartbeat_age_sec:d(e.heartbeat_age_sec)??null,heartbeat_fresh:j(e.heartbeat_fresh)??!1,claim_marker_seen:j(e.claim_marker_seen)??!1,done_marker_seen:j(e.done_marker_seen)??!1,final_marker_seen:j(e.final_marker_seen)??!1,claim_marker:o,done_marker:l,final_marker:c,last_message:p}}function vv(e){if(!m(e))return;const t=Array.isArray(e.timeline)?e.timeline.map(n=>{if(!m(n))return null;const s=r(n.timestamp),a=d(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:r(e.slot_url)??null,provider_base_url:r(e.provider_base_url)??null,provider_reachable:j(e.provider_reachable)??null,provider_status_code:d(e.provider_status_code)??null,provider_model_id:r(e.provider_model_id)??null,actual_model_id:r(e.actual_model_id)??null,expected_slots:d(e.expected_slots),actual_slots:d(e.actual_slots),expected_ctx:d(e.expected_ctx),actual_ctx:d(e.actual_ctx),slot_reachable:j(e.slot_reachable)??null,slot_status_code:d(e.slot_status_code)??null,runtime_blocker:r(e.runtime_blocker)??null,detail:r(e.detail)??null,checked_at:r(e.checked_at)??null,total_slots:d(e.total_slots),ctx_per_slot:d(e.ctx_per_slot),active_slots_now:d(e.active_slots_now),peak_active_slots:d(e.peak_active_slots),sample_count:d(e.sample_count),last_sample_at:r(e.last_sample_at)??null,timeline:t}}function _v(e){if(!m(e))return null;const t=r(e.run_id),n=r(e.status),s=r(e.decided_by),a=r(e.decided_at),o=r(e.reason);if(!t||!n||!s||!a||!o)return null;const l=[];return Array.isArray(e.history)&&e.history.forEach(c=>{if(!m(c))return;const p=r(c.status),u=r(c.decided_by),_=r(c.decided_at),g=r(c.reason);!p||!u||!_||!g||l.push({status:p,decided_by:u,decided_at:_,reason:g,operation_id:r(c.operation_id)??null,detachment_id:r(c.detachment_id)??null,note:r(c.note)??null})}),{run_id:t,status:n,decided_by:s,decided_at:a,reason:o,operation_id:r(e.operation_id)??null,detachment_id:r(e.detachment_id)??null,note:r(e.note)??null,history:l}}function gv(e){if(!m(e))return null;const t=r(e.run_id),n=r(e.recommended_kind),s=r(e.reason);return!t||!n||!s?null:{run_id:t,recommended_kind:n,continue_available:j(e.continue_available)??!1,rerun_available:j(e.rerun_available)??!1,abandon_available:j(e.abandon_available)??!1,reason:s,evidence:m(e.evidence)?{operation_id:r(e.evidence.operation_id)??null,detachment_id:r(e.evidence.detachment_id)??null,joined_workers:d(e.evidence.joined_workers),current_task_bound:d(e.evidence.current_task_bound),fresh_heartbeats:d(e.evidence.fresh_heartbeats),trace_events:d(e.evidence.trace_events),message_events:d(e.evidence.message_events),runtime_blocker:r(e.evidence.runtime_blocker)??null}:void 0,provenance:r(e.provenance),decision_engine:r(e.decision_engine),authoritative:j(e.authoritative)}}function fv(e){const t=m(e)?e:{},n=m(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),run_id:r(t.run_id),room_id:r(t.room_id),operation_id:r(t.operation_id)??null,run_resolution:_v(t.run_resolution),resolution_recommendation:gv(t.resolution_recommendation),recommended_next_tool:r(t.recommended_next_tool),summary:n?{expected_workers:d(n.expected_workers),joined_workers:d(n.joined_workers),live_workers:d(n.live_workers),squad_roster_size:d(n.squad_roster_size),detachment_roster_size:d(n.detachment_roster_size),current_task_bound:d(n.current_task_bound),fresh_heartbeats:d(n.fresh_heartbeats),claim_markers_seen:d(n.claim_markers_seen),done_markers_seen:d(n.done_markers_seen),final_markers_seen:d(n.final_markers_seen),completed_workers:d(n.completed_workers),peak_hot_slots:d(n.peak_hot_slots),hot_window_ok:j(n.hot_window_ok),pass_hot_concurrency:j(n.pass_hot_concurrency),pass_end_to_end:j(n.pass_end_to_end),pending_decisions:d(n.pending_decisions),pass:j(n.pass)}:void 0,provider:vv(t.provider),operation:ka(t.operation),squad:Vi(t.squad),detachment:xl(t.detachment),workers:Array.isArray(t.workers)?t.workers.map(mv).filter(s=>s!==null):[],checklist:Array.isArray(t.checklist)?t.checklist.map(dv).filter(s=>s!==null):[],blockers:Array.isArray(t.blockers)?t.blockers.map(uv).filter(s=>s!==null):[],recent_messages:Array.isArray(t.recent_messages)?t.recent_messages.map(pv).filter(s=>s!==null):[],recent_trace_events:Array.isArray(t.recent_trace_events)?t.recent_trace_events.map(Il).filter(s=>s!==null):[],truth_notes:H(t.truth_notes)}}function kt(e){Y.value=e,Ji(e)&&$v()}async function Ll(){Js.value=!0,Qs.value=null;try{const e=await Xc();Gi.value=Vm(e)}catch(e){Qs.value=e instanceof Error?e.message:"Failed to load command-plane summary"}finally{Js.value=!1}}function Qi(e){Gt.value=e}async function Yi(){Vs.value=!0,Ys.value=null;try{const e=await Yc();je.value=Jm(e)}catch(e){Ys.value=e instanceof Error?e.message:"Failed to load command-plane snapshot"}finally{Vs.value=!1}}async function $v(){je.value||Vs.value||await Yi()}async function jt(){await Ll(),Ji(Y.value)&&await Yi()}async function Jt(){var e;ki.value=!0,na.value=null;try{const t=await Zc(),n=Zm(t);Yn.value=n;const s=Gt.value;n.operations.length===0?Gt.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Gt.value=((e=n.operations[0])==null?void 0:e.operation.operation_id)??null)}catch(t){na.value=t instanceof Error?t.message:"Failed to load chain summary"}finally{ki.value=!1}}function hv(){mn=null,wn.value=null,sa.value=!1,zn.value=null}async function yv(e){mn=e,sa.value=!0,zn.value=null;try{const t=await ed(e);if(mn!==e)return;wn.value=tv(t)}catch(t){if(mn!==e)return;wn.value=null,zn.value=t instanceof Error?t.message:"Failed to load chain run"}finally{mn===e&&(sa.value=!1)}}async function bv(){bi.value=!0,Zs.value=null;try{const e=await td();Qn.value=cv(e)}catch(e){Zs.value=e instanceof Error?e.message:"Failed to load command-plane help"}finally{bi.value=!1}}async function Je(e=Rm(),t=Pm()){ea.value=!0,ta.value=null;try{const n=await nd(e,t);At.value=fv(n)}catch(n){ta.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{ea.value=!1}}async function ct(e,t,n){yi.value=e,Xs.value=null;try{await sd(t,n),await Ll(),(je.value||Ji(Y.value))&&await Yi(),await Je(),await Jt()}catch(s){throw Xs.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{yi.value=null}}function kv(e){return ct(`pause:${e}`,"/api/v1/command-plane/operations/pause",{operation_id:e})}function xv(e){return ct(`resume:${e}`,"/api/v1/command-plane/operations/resume",{operation_id:e})}function Sv(e){return ct(`recall:${e}`,"/api/v1/command-plane/dispatch/recall",{operation_id:e})}function Av(e={}){return ct("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...e.operationId?{operation_id:e.operationId}:{},...e.detachmentId?{detachment_id:e.detachmentId}:{}})}function Cv(e){return ct(`approve:${e}`,"/api/v1/command-plane/policy/approve",{decision_id:e})}function Iv(e){return ct(`deny:${e}`,"/api/v1/command-plane/policy/deny",{decision_id:e})}function Tv(e,t){return ct(`freeze:${e}`,"/api/v1/command-plane/policy/freeze",{unit_id:e,enabled:t})}function Rv(e,t){return ct(`kill:${e}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:e,enabled:t})}Eu(()=>{jt(),Jt(),(Y.value==="swarm"||Y.value==="warroom"||At.value!==null)&&Je(),Y.value==="warroom"&&$e()});function aa(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Q(e){if(!e)return"n/a";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function Pv(e){if(!e)return"warn";const t=Date.parse(e);return Number.isNaN(t)?"warn":t<=Date.now()?"bad":"ok"}function Nl(e){if(!e)return"n/a";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.round((t-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function w(e){return e==="bad"?"bad":e==="warn"||e==="pending"?"warn":"ok"}let zo=!1,Lv=0;function Nv(){return++Lv}let Na=null;async function wv(){Na||(Na=Tm(()=>import("./mermaid.core-PygIN7J6.js").then(t=>t.bE),[]).then(t=>t.default));const e=await Na;return zo||(e.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),zo=!0),e}function et(e){if(!e)return"warn";const t=e.toLowerCase();return t.includes("failed")||t.includes("error")||t.includes("disconnected")||t.includes("stopped")?"bad":t.includes("running")||t.includes("active")||t.includes("degraded")||t.includes("pending")?"warn":"ok"}function Xn(e){return typeof e!="number"||!Number.isFinite(e)?"n/a":`${Math.round(e*100)}%`}function vn(e){return typeof e!="number"||!Number.isFinite(e)?"n/a":e<60?`${Math.round(e)}s`:e<3600?`${Math.round(e/60)}m`:`${Math.round(e/3600)}h`}function Zn(e){return typeof e!="number"||!Number.isFinite(e)?0:Math.max(0,Math.min(100,e))}function _t(e,t){return typeof e!="number"||!Number.isFinite(e)||typeof t!="number"||!Number.isFinite(t)||t<=0?0:Zn(e/t*100)}function zv(e,t){const n=Zn(e);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${t};`}function wl(e){if(!e)return"No recent chain history";const t=[e.event];return typeof e.duration_ms=="number"&&t.push(`${e.duration_ms}ms`),typeof e.tokens=="number"&&t.push(`${e.tokens} tokens`),e.message&&t.push(e.message),t.join(" · ")}const Mv=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],zl=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],jv=zl.map(e=>e.id),Ev=["chain_start","node_start","node_complete","chain_complete","chain_error"],Dv={warroom:{title:"라이브 워룸",description:"실제 run, worker, message, trace를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function Mo(e){return!!e&&jv.includes(e)}function Ov(){const e=O.value.params;return e.source!=="mission"&&e.source!=="execution"?{}:{source:e.source,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function Ml(e){const t=Ov();if(e==="operations")return t;if(e==="chains"){const n=Gt.value;return n?{...t,surface:e,operation:n}:{...t,surface:e}}return{...t,surface:e}}function qv(){const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");return n&&t.set("agent",n),s&&t.set("token",s),t.toString()?`/api/v1/chains/events?${t.toString()}`:"/api/v1/chains/events"}function Fv(e){switch(e){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return e}}function se(e){return yi.value===e}function es(){return Gi.value}function Kv(e){var a,o,l,c,p,u,_;const t=Gi.value,n=At.value,s=Yn.value;switch(e){case"warroom":return{tool:"masc_observe_operations",reason:"live run, worker, message, trace를 한 화면에서 보고 필요한 detail 표면으로 바로 점프합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=t==null?void 0:t.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(o=t==null?void 0:t.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((p=(c=t==null?void 0:t.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:p.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(_=(u=s==null?void 0:s.operations[0])==null?void 0:u.preview_run)!=null&&_.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function Uv(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"microarch":t.includes("leader_offline")||t.includes("roster_offline")?"alerts":t.includes("stale_data")?"swarm":null:null}function Bv(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")?"recommendation":t.includes("gap")?"gaps":null:null}function jl(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");if(!t)return null;const n=t.trim();return n===""?null:n}function El(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,o)=>{e.has(o)||e.set(o,a)}),e}function Hv(){const t=El().get("run_id");if(!t)return null;const n=t.trim();return n===""?null:n}function Dl(){const t=El().get("operation_id");if(!t)return null;const n=t.trim();return n===""?null:n}function Wv(e){if(!e)return null;const t=Date.parse(e);return Number.isNaN(t)?null:Math.max(0,Math.round((Date.now()-t)/1e3))}function Gv(e){return e.status==="claimed"||e.status==="in_progress"}function Jv(e){const t=Qn.value;if(!t)return null;for(const n of t.golden_paths){const s=n.steps.find(a=>a.tool===e);if(s)return s}return null}function wa(e){var t;return((t=Qn.value)==null?void 0:t.golden_paths.find(n=>n.id===e))??null}function Vv(e){const t=Qn.value;if(!t)return[];const n=new Set(e);return t.pitfalls.filter(s=>n.has(s.id))}async function tt(e){try{await e()}catch{}}function Xi(e){return(e==null?void 0:e.trim().toLowerCase())??""}function Et(e){const t=Xi(e);return t.includes("failed")||t.includes("error")||t.includes("stopped")||t==="paused"?"bad":t.includes("active")||t.includes("running")||t.includes("healthy")||t.includes("ok")?"ok":"warn"}function us(e){const t=Xi(e);return t?t==="active"||t==="running"?"진행 중":t==="paused"?"일시정지":t==="done"||t==="ended"||t==="completed"?"완료":t==="failed"||t==="error"||t==="stopped"?"문제":(e==null?void 0:e.trim())||"확인 필요":"확인 필요"}function Qv(){var n,s,a,o,l,c,p,u,_;const e=At.value;if(!e)return!1;const t=e.workers.some(g=>g.joined||g.live_presence||g.completed||g.current_task_matches_run||g.heartbeat_fresh||g.claim_marker_seen||g.done_marker_seen||g.final_marker_seen||!!g.current_task||!!g.bound_task_id||!!g.last_message);return!!((n=e.operation)!=null&&n.operation_id||(s=e.detachment)!=null&&s.detachment_id||(((a=e.summary)==null?void 0:a.joined_workers)??0)>0||(((o=e.summary)==null?void 0:o.live_workers)??0)>0||(((l=e.summary)==null?void 0:l.current_task_bound)??0)>0||(((c=e.summary)==null?void 0:c.fresh_heartbeats)??0)>0||(((p=e.summary)==null?void 0:p.claim_markers_seen)??0)>0||(((u=e.summary)==null?void 0:u.done_markers_seen)??0)>0||(((_=e.summary)==null?void 0:_.final_markers_seen)??0)>0||t||e.recent_messages.length>0||e.recent_trace_events.length>0)}function Yv(e){const t=Xi(e.status);return t==="active"||t==="running"}function Xv(){var o,l,c,p;const e=((o=me.value)==null?void 0:o.sessions)??[],t=At.value,n=((l=t==null?void 0:t.detachment)==null?void 0:l.session_id)??null;if(n){const u=e.find(_=>_.session_id===n);if(u)return u}const s=((c=t==null?void 0:t.operation)==null?void 0:c.operation_id)??Dl();if(s){const u=e.find(_=>_.command_plane_operation_id===s);if(u)return u}const a=((p=t==null?void 0:t.detachment)==null?void 0:p.detachment_id)??null;if(a){const u=e.find(_=>_.command_plane_detachment_id===a);if(u)return u}return e.find(Yv)??e[0]??null}function za(e){return e==="proven"?"ok":e==="partial"?"warn":"bad"}function yn(e){return Array.isArray(e)?e:[]}function Ie(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)?e:{}}function ps(e){return typeof e=="string"&&e.trim()!==""?e:null}function Zv(e){return typeof e=="number"&&Number.isFinite(e)?e:null}function e_(e){const t=e.split("/");return t.length<=3?e:`…/${t.slice(-3).join("/")}`}function t_(e){return e==="proven"?"협업 증거가 충분합니다":e==="partial"?"흔적은 있으나 협업 증거가 덜 모였습니다":"증거가 부족합니다"}function n_(e,t,n,s,a){const o=[`${t}명의 actor 흔적이 기록돼 있습니다.`,n>0?`서로를 참조한 상호작용 증거가 ${n}건 있습니다.`:"서로를 참조한 명시적 상호작용 증거가 아직 없습니다.",s>0?`도구·산출물·체크포인트 증거가 ${s}건 있습니다.`:"도구·산출물·체크포인트 증거가 거의 없습니다.",a>0?`CPv2 backing trace가 ${a}건 있어 실행 흔적은 남아 있습니다.`:"managed backing trace는 아직 없습니다."];return e==="partial"?[o[0]??"",n===0?"partial인 이유: 참여 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.":"partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.",a>0?"다음 보강 포인트: 대화/상호참조 event를 남기면 proof가 더 강해집니다.":"다음 보강 포인트: managed trace 또는 산출물 linkage를 더 남기면 proof가 강해집니다."]:e==="proven"?[o[0]??"","결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.","다음 행동: raw evidence는 접어두고 세션 결과와 산출물만 확인하면 됩니다."]:[o[0]??"","결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.","다음 보강 포인트: participant 간 turn, tool evidence, deliverable linkage를 더 남겨야 합니다."]}function s_(e){const t=new Map;for(const n of e){const s=[n.timestamp??"",n.event_type??"",n.actor??"",n.summary??""].join("|"),a=n.source??"unknown",o=t.get(s);if(o){o.sources.includes(a)||o.sources.push(a),!o.operation_id&&n.operation_id&&(o.operation_id=n.operation_id);continue}t.set(s,{...n,sources:[a]})}return[...t.values()]}function a_(e){return e.sources.length===2?"team + command":e.sources.length===1?e.sources[0]??"source":e.sources.join(" + ")}function i_(e){const t=[];for(const[n,s]of Object.entries(e))if(s!=null){if(typeof s=="string"){if(s.trim()==="")continue;t.push({label:n,value:s});continue}if(typeof s=="number"||typeof s=="boolean"){t.push({label:n,value:String(s)});continue}}return t}function o_(e){const t=Ie(e),n=Ie(t.traces),s=Array.isArray(n.events)?n.events:[],a=Ie(t.detachments),o=Array.isArray(a.detachments)?a.detachments:[],l=Ie(o[0]),c=Ie(l.detachment),p=Ie(l.operation),u=Ie(t.summary),_=Ie(u.operations),g=Ie(_.summary);return[{label:"operation",value:ps(t.operation_id)??"없음"},{label:"detachment",value:ps(t.detachment_id)??"없음"},{label:"trace events",value:`${s.length}`},{label:"detachment status",value:ps(c.status)??"없음"},{label:"operation stage",value:ps(p.stage)??"없음"},{label:"active ops",value:`${Zv(g.active)??0}`}]}function r_({item:e}){return i`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${e.summary??e.event_type??"event"}</strong>
          <div class="command-meta-line">
            <span>${a_(e)}</span>
            <span>${e.event_type??"event"}</span>
            <span>${e.actor??"system"}</span>
          </div>
        </div>
        <span class="command-chip">${Q(e.timestamp)}</span>
      </div>
      ${e.sources.length>1?i`<div class="semantic-tag-row">
            ${e.sources.map(t=>i`<span class="semantic-tag">${t}</span>`)}
          </div>`:null}
    </article>
  `}function l_({item:e}){const t=e.recent_output_preview??null,n=e.recent_input_preview??null,s=e.recent_event_summary??null,a=(e.interaction_count??0)>0?"ok":"warn";return i`
    <article class="mission-activity-row proof-actor-row">
      <div class="mission-activity-head">
        <div>
          <strong>${e.actor}</strong>
          <div class="mission-activity-meta">
            <span>${e.role??"participant"}</span>
            <span>${e.last_active_at?Q(e.last_active_at):"n/a"}</span>
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
      ${yn(e.recent_tool_names).length>0?i`<div class="semantic-tag-row">
            ${yn(e.recent_tool_names).map(o=>i`<span class="semantic-tag">${o}</span>`)}
          </div>`:null}
    </article>
  `}function c_({item:e}){return i`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${e.kind}</strong>
          <div class="command-meta-line">
            <span>${e_(e.path)}</span>
          </div>
        </div>
        <span class="command-chip ${e.exists?"ok":"warn"}">${e.exists?"present":"missing"}</span>
      </div>
    </article>
  `}function jo({title:e,rows:t}){return t.length===0?null:i`
    <div class="proof-kv-block">
      ${e?i`<strong>${e}</strong>`:null}
      <div class="proof-kv-grid">
        ${t.map(n=>i`
          <span>${n.label}</span>
          <strong>${n.value}</strong>
        `)}
      </div>
    </div>
  `}function d_(){var R,T,P;const e=O.value.params,t=e.session_id??null,n=e.operation_id??null;ee(()=>{$l(t,n)},[t,n]);const s=fl.value;if(hi.value&&!s)return i`<section class="dashboard-panel"><div class="loading-indicator">Loading proof…</div></section>`;if(Mt.value&&!s)return i`<section class="dashboard-panel"><div class="error-card">${Mt.value}</div></section>`;const a=s==null?void 0:s.summary,o=yn(s==null?void 0:s.actor_contributions),l=yn(s==null?void 0:s.artifacts),c=(s==null?void 0:s.proof_verdict)??"insufficient",p=(s==null?void 0:s.cp_backing_evidence)??null,u=Array.isArray((R=p==null?void 0:p.traces)==null?void 0:R.events)?((P=(T=p.traces)==null?void 0:T.events)==null?void 0:P.length)??0:0,_=(a==null?void 0:a.actors_count)??o.length,g=(a==null?void 0:a.interaction_count)??0,v=(a==null?void 0:a.evidence_count)??0,y=s_(yn(s==null?void 0:s.timeline)),S=i_(Ie(s==null?void 0:s.goal_binding)),$=o_(p),A=l.filter(L=>L.exists).length,b=l.length-A,I=n_(c,_,g,v,u);return i`
    <section class="dashboard-panel mission-view">
      <${he} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>Proof</h2>
          <p>이 세션이 실제로 여러 actor의 흔적, 상호작용, 산출물, 실행 backing을 남겼는지 읽는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${za(c)}">${c}</span>
          ${s!=null&&s.session_id?i`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?i`<span class="command-chip">${Q(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${Mt.value?i`<div class="error-card">${Mt.value}</div>`:null}

      <div class="mission-stat-grid">
        <div class="summary-stat-card ${za(c)}">
          <span>Verdict</span>
          <strong>${t_(c)}</strong>
          <small>${(a==null?void 0:a.detail)??"협업 증거를 verdict로 요약합니다."}</small>
        </div>
        <div class="summary-stat-card">
          <span>Actors</span>
          <strong>${_}</strong>
          <small>기록된 참여 actor 수</small>
        </div>
        <div class="summary-stat-card ${g>0?"ok":"warn"}">
          <span>Interactions</span>
          <strong>${g}</strong>
          <small>actor 간 직접 상호작용 증거</small>
        </div>
        <div class="summary-stat-card ${v>0?"ok":"warn"}">
          <span>Evidence</span>
          <strong>${v}</strong>
          <small>tool / deliverable / checkpoint</small>
        </div>
        <div class="summary-stat-card ${u>0?"ok":"warn"}">
          <span>CP Traces</span>
          <strong>${u}</strong>
          <small>managed backing events</small>
        </div>
        <div class="summary-stat-card ${b===0&&l.length>0?"ok":"warn"}">
          <span>Artifacts</span>
          <strong>${A}/${l.length}</strong>
          <small>${b>0?`${b} missing`:"all present"}</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${C} title="3-Line Proof Summary" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
            <p>결론, partial 이유, 다음 보강 포인트만 먼저 봅니다.</p>
          </div>
          <div class="proof-summary-stack">
            ${I.map((L,K)=>i`
              <article class="proof-summary-block ${K===1&&c!=="proven"?za(c):""}">
                <strong>${K===0?"지금 결론":K===1?"왜 이렇게 판정됐나":"다음 보강 포인트"}</strong>
                <span>${L}</span>
              </article>
            `)}
          </div>
        <//>

        <${C} title="Goal Binding" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>무엇을 증명하려는가</h3>
            <p>이 proof가 어느 세션, 목표, operation에 묶였는지 읽습니다.</p>
          </div>
          <${jo} rows=${S} />
          <details class="mission-card-disclosure compact">
            <summary>raw goal binding JSON</summary>
            <pre class="command-json-block">${aa((s==null?void 0:s.goal_binding)??{})}</pre>
          </details>
        <//>
      </div>

      <div class="mission-human-grid">
        <${C} title="Collaboration Timeline" class="mission-list-card" semanticId="proof.timeline">
          <div class="mission-section-head">
            <h3>협업 타임라인</h3>
            <p>team-session과 command-plane에서 같은 사건이 보이면 한 줄로 묶어 읽습니다.</p>
          </div>
          <div class="mission-list-stack">
            ${y.length>0?y.slice(0,18).map(L=>i`<${r_} key=${L.id} item=${L} />`):i`<div class="empty-state">표시할 timeline evidence가 없습니다.</div>`}
          </div>
        <//>

        <${C} title="Actor Contributions" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>누가 무엇을 남겼는가</h3>
            <p>turn 수보다 최근 흔적, 입출력, 도구, interaction 유무를 우선 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${o.length>0?o.map(L=>i`<${l_} key=${L.actor} item=${L} />`):i`<div class="empty-state">표시할 actor contribution이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${C} title="Backing Evidence" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>실행 backing은 얼마나 남아 있나</h3>
            <p>operation, detachment, trace 수만 먼저 보고, raw CPv2 dump는 접어서 봅니다.</p>
          </div>
          <${jo} rows=${$} />
          <details class="mission-card-disclosure compact">
            <summary>raw CPv2 backing JSON</summary>
            <pre class="command-json-block">${aa(p??{})}</pre>
          </details>
        <//>

        <${C} title="Artifacts" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>어떤 파일 산출물이 남았나</h3>
            <p>proof/report/session 기록 파일의 존재 여부를 빠르게 확인합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${l.length>0?l.map(L=>i`<${c_} key=${L.path} item=${L} />`):i`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function u_(){const e=Vn(O.value);return e?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${e.source_label}</strong>
        <span class="command-chip">${ha(e.action_type)}</span>
        <span class="command-chip">${Ki(e)}</span>
        <span class="command-chip">${yp(O.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${e.summary}</div>
      ${e.payload_preview?i`<div class="command-focus-preview">${e.payload_preview}</div>`:null}
    </section>
  `:null}function p_(){const e=Y.value,t=Dv[e],n=Kv(e);return i`
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
  `}function ms({label:e,value:t,subtext:n,percent:s,color:a}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${zv(s,a)}>
        <div class="command-gauge-core">
          <strong>${t}</strong>
          <span>${Math.round(Zn(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${e}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function vs({label:e,value:t,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${w(a)}">
      <div class="command-signal-copy">
        <span>${e}</span>
        <strong>${t}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${w(a)}" style=${`width: ${Math.max(8,Math.round(Zn(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function m_(){var te,ne,G,Z;const e=es(),t=e==null?void 0:e.topology.summary,n=e==null?void 0:e.operations.summary,s=e==null?void 0:e.detachments.summary,a=e==null?void 0:e.decisions.summary,o=e==null?void 0:e.alerts.summary,l=(te=e==null?void 0:e.swarm_status)==null?void 0:te.overview,c=e==null?void 0:e.swarm_proof,p=e==null?void 0:e.operations.microarch,u=(t==null?void 0:t.managed_unit_count)??0,_=(t==null?void 0:t.total_units)??0,g=(n==null?void 0:n.active)??0,v=(s==null?void 0:s.active)??0,y=(l==null?void 0:l.moving_lanes)??0,S=(l==null?void 0:l.active_lanes)??0,$=(c==null?void 0:c.workers.done)??0,A=(c==null?void 0:c.workers.expected)??0,b=(o==null?void 0:o.bad)??0,I=(o==null?void 0:o.warn)??0,R=(a==null?void 0:a.pending)??0,T=(a==null?void 0:a.total)??0,P=g+v,L=((ne=p==null?void 0:p.cache)==null?void 0:ne.l1_hit_rate)??((Z=(G=p==null?void 0:p.signals)==null?void 0:G.cache_contention)==null?void 0:Z.l1_hit_rate)??0,K=g>0||v>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",q=g>0||y>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${K}</h3>
        <p>${q}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${w(g>0?"ok":"warn")}">활성 작전 ${g}</span>
          <span class="command-chip ${w(y>0?"ok":(S>0,"warn"))}">이동 레인 ${y}/${Math.max(S,y)}</span>
          <span class="command-chip ${w(b>0?"bad":I>0?"warn":"ok")}">치명 알림 ${b}</span>
          <span class="command-chip ${w(R>0?"warn":"ok")}">승인 대기 ${R}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${ms}
          label="관리 단위 범위"
          value=${`${u}/${Math.max(_,u)}`}
          subtext=${_>0?`${_-u}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${_t(u,Math.max(_,u))}
          color="#67e8f9"
        />
        <${ms}
          label="실행 열도"
          value=${String(P)}
          subtext=${`${g}개 작전 + ${v}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${_t(P,Math.max(u,P||1))}
          color="#4ade80"
        />
        <${ms}
          label="스웜 이동감"
          value=${`${y}/${Math.max(S,y)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${Q(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${_t(y,Math.max(S,y||1))}
          color="#fbbf24"
        />
        <${ms}
          label="증거 수집률"
          value=${`${$}/${Math.max(A,$)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${_t($,Math.max(A,$||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${vs}
        label="승인 대기열"
        value=${`${R}건 대기`}
        detail=${`현재 정책 창에서 ${T}개 결정을 추적 중입니다`}
        percent=${_t(R,Math.max(T,R||1))}
        tone=${R>0?"warn":"ok"}
      />
      <${vs}
        label="알림 압력"
        value=${`${b} bad / ${I} warn`}
        detail=${b>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${_t(b*2+I,Math.max((b+I)*2,1))}
        tone=${b>0?"bad":I>0?"warn":"ok"}
      />
      <${vs}
        label="디스패치 점유"
          value=${`${v}개 가동`}
        detail=${u>0?`${u}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${_t(v,Math.max(u,v||1))}
        tone=${v>0?"ok":"warn"}
      />
      <${vs}
        label="캐시 신뢰도"
        value=${L?Xn(L):"n/a"}
        detail=${L?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Zn((L??0)*100)}
        tone=${L>=.75?"ok":L>=.4?"warn":"bad"}
      />
    </div>
  `}function v_(){var v,y,S,$,A;const e=es(),t=Yn.value,n=Vn(O.value),s=Uv(n),a=e==null?void 0:e.topology.summary,o=e==null?void 0:e.operations.summary,l=(v=e==null?void 0:e.swarm_status)==null?void 0:v.overview,c=e==null?void 0:e.operations.microarch,p=e==null?void 0:e.decisions.summary,u=e==null?void 0:e.alerts.summary,_=(y=c==null?void 0:c.signals)==null?void 0:y.issue_pressure,g=c==null?void 0:c.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((S=e==null?void 0:e.detachments.summary)==null?void 0:S.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(p==null?void 0:p.pending)??0}</strong><small>${(p==null?void 0:p.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(u==null?void 0:u.bad)??0}</strong><small>${(u==null?void 0:u.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${(($=t==null?void 0:t.summary)==null?void 0:$.active_chains)??0}</strong><small>${((A=t==null?void 0:t.summary)==null?void 0:A.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${Q(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(_==null?void 0:_.pending_ops)??0}</strong><small>${(g==null?void 0:g.l1_hit_rate)!=null?`${Xn(g.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(_==null?void 0:_.tone)??"n/a"}</small></div>
    </div>
  `}function __(){var te,ne,G,Z,x,Se,Be,dt,ut;const e=es(),t=je.value,n=ie.value,s=jl(),a=s?Ue.value.find(F=>F.name===s)??null:null,o=s?Qe.value.filter(F=>F.assignee===s&&Gv(F)):[],l=((te=e==null?void 0:e.operations.summary)==null?void 0:te.active)??0,c=((ne=e==null?void 0:e.detachments.summary)==null?void 0:ne.total)??0,p=((G=e==null?void 0:e.decisions.summary)==null?void 0:G.pending)??0,u=t==null?void 0:t.detachments.detachments.find(F=>{const Ae=F.detachment.heartbeat_deadline,pt=Ae?Date.parse(Ae):Number.NaN;return F.detachment.status==="stalled"||!Number.isNaN(pt)&&pt<=Date.now()}),_=t==null?void 0:t.alerts.alerts.find(F=>F.severity==="bad"),g=!!(n!=null&&n.room||n!=null&&n.project),v=(a==null?void 0:a.current_task)??null,y=Wv(a==null?void 0:a.last_seen),S=y!=null?y<=120:null,$=[g?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:Qe.value.length>0?"masc_claim":"masc_add_task"}:v?S===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${v} 이지만 heartbeat가 stale 합니다 (${y}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${v}${y!=null?` · 마지막 활동 ${y}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!e||(((Z=e.topology.summary)==null?void 0:Z.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((x=e.topology.summary)==null?void 0:x.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Se=e.topology.summary)==null?void 0:Se.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},p>0?{title:"디스패치 준비도",tone:"warn",detail:`${p}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:u||_?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${u?` · detachment ${u.detachment.detachment_id} 가 stalled 상태입니다`:""}${_?` · alert ${_.title??_.alert_id}`:""}${!t&&!u&&!_?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:p>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${t?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],A=g?!s||!a?"masc_join":o.length===0?Qe.value.length>0?"masc_claim":"masc_add_task":v?S===!1?"masc_heartbeat":!e||(((Be=e.topology.summary)==null?void 0:Be.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":p>0?"masc_policy_approve":l>0&&c===0||u||_?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",b=Jv(A),R=Vv(A==="masc_set_room"?["repo-root-room"]:A==="masc_plan_set_task"?["claimed-not-current"]:A==="masc_heartbeat"?["heartbeat-stale"]:A==="masc_dispatch_tick"?["no-detachments"]:A==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),T=wa("room_task_hygiene"),P=wa("cpv2_benchmark"),L=wa("supervisor_session"),K=((dt=Qn.value)==null?void 0:dt.docs)??[],q=[T,P,L].filter(F=>F!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${D} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(b==null?void 0:b.title)??A}</strong>
            <span class="command-chip ok">${A}</span>
          </div>
          <p>${(b==null?void 0:b.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(ut=b==null?void 0:b.success_signals)!=null&&ut.length?i`<div class="command-tag-row">
                ${b.success_signals.map(F=>i`<span class="command-tag ok">${F}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${$.map(F=>i`
            <article class="command-readiness-row ${w(F.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${F.title}</strong>
                  <span class="command-chip ${w(F.tone)}">${F.tone}</span>
                </div>
                <p>${F.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${F.tool}</div>
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
                  ${R.map(F=>i`
                    <article class="command-guide-inline">
                      <strong>${F.title}</strong>
                      <div>${F.symptom}</div>
                      <div class="command-card-sub">${F.fix_tool} 로 해결: ${F.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `:null}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">운영 경로</div>
          <${D} panelId="command.summary" compact=${!0} />
        </div>
        ${bi.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:Zs.value?i`<div class="empty-state error">${Zs.value}</div>`:i`
                <div class="command-path-grid">
                  ${q.map(F=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${F.title}</strong>
                        <span class="command-chip">${F.id}</span>
                      </div>
                      <p>${F.summary}</p>
                      <div class="command-card-sub">${F.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${F.steps.slice(0,4).map(Ae=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Ae.tool}</span>
                            <span>${Ae.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${K.length>0?i`<div class="command-doc-links">
                      ${K.map(F=>i`<span class="command-tag">${F.title}: ${F.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function g_(){return i`
    <${m_} />
    <${v_} />
    <${__} />
  `}function f_(){return Vs.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:Ys.value?i`<div class="empty-state error">${Ys.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}const Ol="masc_dashboard_agent_name";function $_(){var t,n,s;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(Ol))==null?void 0:s.trim())||"dashboard"}const xa=f($_()),Vt=f(""),xi=f("운영 점검"),Qt=f(""),Mn=f(""),jn=f("2"),en=f(""),Le=f("note"),En=f(""),Dn=f(""),On=f(""),qn=f("2"),ia=f("운영자 중지 요청"),oa=f(""),Yt=f(""),_s=f(null);function h_(e){const t=e.trim()||"dashboard";xa.value=t,localStorage.setItem(Ol,t)}function ql(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Zi(e){switch((e??"").trim().toLowerCase()){case"judgment":return"Resident judgment";case"fallback":return"Fallback read model";default:return(e==null?void 0:e.trim())||"Guidance"}}function ra(e){switch((e??"").trim().toLowerCase()){case"judgment":return"ok";case"fallback":return"warn";default:return"warn"}}function eo(e){return e!=null&&e.enabled?e.refreshing?"갱신 중":e.judge_online?"온라인":e.last_error?"오류":"대기":"꺼짐"}function y_(e){return e!=null&&e.enabled?e.judge_online?"ok":e.refreshing?"warn":"bad":"warn"}function to(e){return e!=null&&e.fresh_until?e.fresh_until:"freshness 없음"}function Eo(e){return typeof e!="number"||!Number.isFinite(e)?"확인 없음":e<60?`${Math.round(e)}초 전`:e<3600?`${Math.round(e/60)}분 전`:`${Math.round(e/3600)}시간 전`}function tn(e){return typeof e=="string"?e.trim().toLowerCase():""}function b_(e){var s;const t=tn(e.status);if(t==="paused")return"bad";if(t===""||t==="unknown")return"warn";const n=tn((s=e.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||t&&t!=="active"&&t!=="running"&&t!=="ended"?"warn":"ok"}function Ma(e){const t=tn(e.status);return t==="offline"||t==="inactive"||t==="error"?"bad":t===""||t==="unknown"||(e.context_ratio??0)>=.8||e.context_ratio==null||e.last_turn_ago_s==null||(e.last_turn_ago_s??0)>=3600?"warn":"ok"}function Do(e){return e.some(t=>tn(t.severity)==="bad")?"bad":e.length>0?"warn":"ok"}function k_(e){return e.target_type==="team_session"}function x_(e){return e.target_type==="keeper"}function Fn(e){switch(e){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(e==null?void 0:e.trim())||"액션"}}function Kn(e){switch(e){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";case"swarm_run":return"swarm run";default:return(e==null?void 0:e.trim())||"target"}}function Dt(e){switch(tn(e)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function Fl(e){return e?"확인 후 실행":"즉시 실행"}function S_(e){switch(e){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";default:return e}}function de(e,t){if(!e)return null;const n=e[t];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function A_(e){if(e.action_type==="team_task_inject")return"task";if(e.action_type==="team_broadcast")return"broadcast";if(e.action_type==="team_note")return"note";if(e.action_type==="team_turn"){const t=de(e.suggested_payload,"turn_kind");if(t==="broadcast"||t==="task")return t}return"note"}function C_(e){const t=e.suggested_payload;if(e.target_type==="room"){if(e.action_type==="broadcast"){Vt.value=de(t,"message")??e.summary;return}e.action_type==="task_inject"&&(Qt.value=de(t,"title")??"운영자 주입 작업",Mn.value=de(t,"description")??e.summary,jn.value=de(t,"priority")??jn.value);return}if(e.target_type==="team_session"){if(e.target_id&&(en.value=e.target_id),e.action_type==="team_stop"){ia.value=de(t,"reason")??e.summary;return}Le.value=A_(e);const n=de(t,"message");n&&(En.value=n),Le.value==="task"&&(Dn.value=de(t,"task_title")??de(t,"title")??"운영자 주입 작업",On.value=de(t,"task_description")??de(t,"description")??e.summary,qn.value=de(t,"task_priority")??de(t,"priority")??qn.value);return}e.target_type==="keeper"&&(e.target_id&&(oa.value=e.target_id),Yt.value=de(t,"message")??e.summary)}function I_(e,t,n){return!e||!e.target_type||e.target_type==="room"?!0:e.target_type==="team_session"?!!e.target_id&&t.some(s=>s.session_id===e.target_id):e.target_type==="keeper"?!!e.target_id&&n.some(s=>s.name===e.target_id):!0}async function Ct(e){const t=xa.value.trim()||"dashboard";try{const n=await ul({actor:t,action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.payload});return n.confirm_required?N("확인 대기열에 올렸습니다","warning"):N(e.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return N(s,"error"),null}}async function Oo(){const e=Vt.value.trim();if(!e)return;await Ct({action_type:"broadcast",target_type:"room",payload:{message:e},successMessage:"방송을 보냈습니다"})&&(Vt.value="")}async function T_(){await Ct({action_type:"room_pause",target_type:"room",payload:{reason:xi.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function Kl(){await Ct({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function R_(){const e=Qt.value.trim();if(!e)return;await Ct({action_type:"task_inject",target_type:"room",payload:{title:e,description:Mn.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(jn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(Qt.value="",Mn.value="")}async function P_(){var l;const e=me.value,t=en.value||((l=e==null?void 0:e.sessions[0])==null?void 0:l.session_id)||"";if(!t){N("먼저 세션을 고르세요","warning");return}const n={},s=En.value.trim();s&&(n.message=s);let a="team_note";Le.value==="broadcast"?a="team_broadcast":Le.value==="task"&&(a="team_task_inject"),Le.value==="task"&&(n.task_title=Dn.value.trim()||"운영자 주입 작업",n.task_description=On.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(qn.value,10)||2),await Ct({action_type:a,target_type:"team_session",target_id:t,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(En.value="",Le.value==="task"&&(Dn.value="",On.value=""))}async function L_(){var n;const e=me.value,t=en.value||((n=e==null?void 0:e.sessions[0])==null?void 0:n.session_id)||"";if(!t){N("먼저 세션을 고르세요","warning");return}await Ct({action_type:"team_stop",target_type:"team_session",target_id:t,payload:{reason:ia.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function N_(){var a;const e=me.value,t=oa.value||((a=e==null?void 0:e.keepers[0])==null?void 0:a.name)||"",n=Yt.value.trim();if(!t){N("먼저 keeper를 고르세요","warning");return}if(!n)return;await Ct({action_type:"keeper_message",target_type:"keeper",target_id:t,payload:{message:n},successMessage:`${t}에게 메시지를 보냈습니다`})&&(Yt.value="")}async function w_(e){const t=xa.value.trim()||"dashboard";try{await pl(t,e),N("확인 실행을 완료했습니다","success")}catch(n){const s=n instanceof Error?n.message:"확인 실행에 실패했습니다";N(s,"error")}}function Ul({node:e,depth:t=0}){const n=e.roster_live??0,s=e.roster_total??e.unit.roster.length,a=e.active_operation_count??0,o=e.unit.policy;return i`
    <div class="command-tree-node depth-${Math.min(t,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${e.unit.label}</strong>
            <span class="command-chip">${Fv(e.unit.kind)}</span>
            <span class="command-chip ${w(e.health)}">${e.health??"ok"}</span>
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
          ${e.reasons&&e.reasons.length>0?i`<div class="command-tag-row">
                ${e.reasons.map(l=>i`<span class="command-tag warn">${l}</span>`)}
              </div>`:null}
        </div>
      </div>
      ${e.children.length>0?i`<div class="command-tree-children">
            ${e.children.map(l=>i`<${Ul} node=${l} depth=${t+1} />`)}
          </div>`:null}
    </div>
  `}function z_({alert:e}){return i`
    <article class="command-alert ${w(e.severity)}">
      <div class="command-card-head">
        <strong>${e.title??e.kind??e.alert_id}</strong>
        <span class="command-chip ${w(e.severity)}">${e.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${e.scope_type??"scope"}:${e.scope_id??"n/a"}</span>
        <span>${Q(e.timestamp)}</span>
      </div>
      ${e.detail?i`<p>${e.detail}</p>`:null}
    </article>
  `}function no({event:e}){return i`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${e.event_type}</strong>
          <span class="command-chip">${e.source??"control_plane"}</span>
          <span class="command-chip">${Q(e.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${e.operation_id??e.trace_id}
          ${e.unit_id?` · ${e.unit_id}`:""}
          ${e.actor?` · ${e.actor}`:""}
        </div>
      </div>
      <pre class="command-trace-detail">${aa(e.detail)}</pre>
    </article>
  `}function M_(){const e=je.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${D} panelId="command.topology" compact=${!0} />
      </div>
      ${e&&e.topology.units.length>0?i`${e.topology.units.map(t=>i`<${Ul} node=${t} />`)}`:i`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function j_(){const e=je.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${D} panelId="command.alerts" compact=${!0} />
      </div>
      ${e&&e.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${e.alerts.alerts.map(t=>i`<${z_} alert=${t} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function E_(){const e=je.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${D} panelId="command.trace" compact=${!0} />
      </div>
      ${e&&e.traces.events.length>0?i`<div class="command-trace-stack">
            ${e.traces.events.map(t=>i`<${no} event=${t} />`)}
          </div>`:i`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function D_(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e,null,2)}catch{return String(e)}}function O_(e,t){return(t==null?void 0:t.status)==="abandoned"||(e==null?void 0:e.recommended_kind)==="continue"?"warn":(e==null?void 0:e.recommended_kind)==="rerun"?"bad":"ok"}function q_(e){switch(e){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(e==null?void 0:e.trim())||"결정"}}function Bl({swarm:e}){var g,v;const t=e.run_id,n=e.resolution_recommendation,s=e.run_resolution;if(!t||!n&&!s)return null;const a=jl()??"dashboard",o=((g=me.value)==null?void 0:g.pending_confirms.find(y=>y.target_type==="swarm_run"&&y.target_id===t))??null,l=O_(n,s),c=((v=e.operation)==null?void 0:v.operation_id)??e.operation_id??void 0,p={run_id:t};c&&(p.operation_id=c),n!=null&&n.reason&&(p.reason=n.reason);const u=async y=>{await ul({actor:a,action_type:y,target_type:"swarm_run",target_id:t,payload:p})},_=async y=>{o&&await pl(a,o.confirm_token,y)};return i`
    <article class="command-guide-card ${w(l)}">
      <div class="command-guide-head">
        <strong>Run Resolution</strong>
        <span class="command-chip ${w(l)}">
          ${q_((s==null?void 0:s.status)??(n==null?void 0:n.recommended_kind)??null)}
        </span>
      </div>
      <p>
        ${(s==null?void 0:s.status)==="abandoned"?`이 run은 ${s.decided_by}가 ${Q(s.decided_at)}에 soft abandon 처리했습니다. ${s.reason}`:(n==null?void 0:n.reason)??"이 run에 대한 별도 resolution recommendation은 아직 없습니다."}
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
              ${n.evidence.runtime_blocker?i`<span class="command-tag ${w("bad")}">${n.evidence.runtime_blocker}</span>`:null}
            </div>
          `:null}
      ${o?i`
            <div class="command-guide-card warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip warn">${o.confirm_token}</span>
              </div>
              ${o.preview?i`<pre class="command-trace-detail">${D_(o.preview)}</pre>`:null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${()=>{_("confirm")}} disabled=${V.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${()=>{_("deny")}} disabled=${V.value}>취소</button>
              </div>
            </div>
          `:n?i`
              <div class="command-action-row">
                ${n.continue_available?i`<button class="control-btn ghost" onClick=${()=>{u("swarm_run_continue")}} disabled=${V.value}>Continue</button>`:null}
                ${n.rerun_available?i`<button class="control-btn" onClick=${()=>{u("swarm_run_rerun")}} disabled=${V.value}>Rerun</button>`:null}
                ${n.abandon_available?i`<button class="control-btn ghost" onClick=${()=>{u("swarm_run_abandon")}} disabled=${V.value}>Abandon</button>`:null}
              </div>
            `:null}
    </article>
  `}function Hl(e){return e.motion_state==="stalled"||e.hard_flags.some(t=>t.severity==="bad")?"bad":e.motion_state==="waiting"||e.hard_flags.some(t=>t.severity==="warn")?"warn":"ok"}function Wl({lanes:e}){const t={moving:0,waiting:0,stalled:0,terminal:0};for(const a of e){const o=a.motion_state;o in t?t[o]++:t.waiting++}if(e.length===0)return null;const s=[{key:"moving",count:t.moving,color:"var(--ok)"},{key:"waiting",count:t.waiting,color:"var(--warn)"},{key:"stalled",count:t.stalled,color:"var(--bad)"},{key:"terminal",count:t.terminal,color:"#556"}];return i`
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
  `}function F_({total:e}){const n=Math.min(e,20),s=e>20?e-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${e})</span>
    </div>
  `}function K_({lane:e}){const t=e.counts??{},n=Hl(e),s=t.workers??0,a=t.operations??0,o=t.detachments??0,l=a+o,c=e.motion_state==="moving"?84:e.motion_state==="waiting"?58:e.motion_state==="terminal"?100:26;return i`
    <article class="swarm-lane-strip ${w(n)}">
      <div class="swarm-lane-head">
        <div class="swarm-lane-head-left">
          <span class="swarm-motion-dot ${e.motion_state}"></span>
          <div>
            <span class="swarm-lane-kicker">${e.kind} · ${e.source_of_truth}</span>
            <strong>${e.label}</strong>
          </div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${w(n)}">${e.phase}</span>
          <span class="command-chip ${w(n)}">${e.motion_state}</span>
          <span class="command-chip">${Q(e.last_movement_at)}</span>
        </div>
      </div>
      <p class="swarm-lane-reason">${e.movement_reason}</p>
      <div class="swarm-lane-track">
        <span class="${w(n)}" style=${`width:${c}%`}></span>
      </div>
      <div class="swarm-lane-details">
        <div class="swarm-lane-row">
          <span class="swarm-lane-row-label">Step</span>
          <span>${e.current_step}</span>
        </div>
        ${s>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${F_} total=${s} />
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
              ${e.hard_flags.map(p=>i`<span class="command-chip ${w(p.severity)}">${p.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function Gl({lanes:e}){const t=e.slice(0,4);return t.length===0?null:i`
    <div class="swarm-storyboard">
      ${t.map(n=>{const s=Hl(n),a=n.counts.workers??0,o=n.counts.operations??0,l=n.counts.detachments??0;return i`
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
  `}function U_({event:e}){const t=e.timestamp?new Date(e.timestamp):null,n=t&&!isNaN(t.getTime())?t:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${w(e.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${e.title}</strong>
        <span class="swarm-event-kind">${e.kind}</span>
        ${e.detail?i`<div class="command-card-sub">${e.detail}</div>`:null}
      </div>
    </div>
  `}function B_({gap:e}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${w(e.severity)}">${e.code} (${e.count})</span>
      <span class="command-card-sub">${e.summary}</span>
    </div>
  `}function H_({proof:e}){const t=(e==null?void 0:e.status)==="missing"?"warn":(e==null?void 0:e.pass)===!1?"bad":(e==null?void 0:e.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${w(t)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${w(t)}">${(e==null?void 0:e.status)??"missing"}</span>
        </div>
      ${e?i`
            <div class="command-card-grid">
              <span>소스</span><span>${e.source}</span>
              <span>런</span><span>${e.run_id??"n/a"}</span>
              <span>수집 시각</span><span>${Q(e.captured_at)}</span>
              <span>통과</span><span>${e.pass==null?"n/a":e.pass?"예":"아니오"}</span>
              <span>최대 Hot Slots</span><span>${e.peak_hot_slots??"n/a"}</span>
              <span>Ctx / Slot</span><span>${e.ctx_per_slot??"n/a"}</span>
              <span>워커 증거</span><span>${e.workers.expected??"n/a"} 예상 · ${e.workers.done??"n/a"} 완료 · ${e.workers.final??"n/a"} 최종</span>
            </div>
            ${e.artifact_ref?i`<div class="command-card-foot">${e.artifact_ref}</div>`:null}
            ${e.missing_reason?i`<p>${e.missing_reason}</p>`:null}
          `:i`<p>아직 스웜 증거가 수집되지 않았습니다.</p>`}
    </div>
  `}function W_(){const e=es(),t=Vn(O.value),n=Bv(t),s=e==null?void 0:e.swarm_status,a=e==null?void 0:e.swarm_proof,o=(s==null?void 0:s.lanes.filter(g=>g.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],p=s==null?void 0:s.overview,u=s==null?void 0:s.recommended_next_action,_=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${D} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${Gl} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(p==null?void 0:p.active_lanes)??0}</strong><small>${(p==null?void 0:p.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(p==null?void 0:p.stalled_lanes)??0}</strong><small>${(p==null?void 0:p.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${Q(p==null?void 0:p.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${Q(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(u==null?void 0:u.label)??"운영자 상태 확인"}</strong><small>${(u==null?void 0:u.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${Wl} lanes=${o} />`:null}

            <div class="command-swarm-layout ${_?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(g=>i`<${K_} lane=${g} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight ${n==="recommendation"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>${(u==null?void 0:u.label)??"운영자 상태 확인"}</strong>
                    <span class="command-chip">${(u==null?void 0:u.lane_id)??"전체"}</span>
                  </div>
                  <p>${(u==null?void 0:u.reason)??"보이는 활성 스웜 레인이 아직 없습니다."}</p>
                  <div class="command-card-foot">${(u==null?void 0:u.tool)??"masc_operator_snapshot"}</div>
                </div>

                <${H_} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${w(l.some(g=>g.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?i`<div class="swarm-event-rail">${l.slice(0,4).map(g=>i`<${B_} gap=${g} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?i`<div class="swarm-event-rail">${c.map(g=>i`<${U_} event=${g} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function G_({item:e}){return i`
    <article class="command-guide-card ${w(e.status)}">
      <div class="command-guide-head">
        <strong>${e.title}</strong>
        <span class="command-chip ${w(e.status)}">${e.status}</span>
      </div>
      <p>${e.detail}</p>
      <div class="command-card-foot">Next tool: ${e.next_tool}</div>
    </article>
  `}function Jl({blocker:e}){return i`
    <article class="command-alert ${w(e.severity)}">
      <div class="command-card-head">
        <strong>${e.title}</strong>
        <span class="command-chip ${w(e.severity)}">${e.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${e.code}</span>
        <span>next ${e.next_tool}</span>
      </div>
      <p>${e.detail}</p>
    </article>
  `}function J_({worker:e}){return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${e.name}</strong>
          <div class="command-card-sub">${e.role} · ${e.lane}</div>
        </div>
        <span class="command-chip ${w(e.joined?e.heartbeat_fresh?"ok":"warn":"bad")}">
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
      ${e.last_message?i`<div class="command-card-foot">${Q(e.last_message.timestamp)} · ${e.last_message.content}</div>`:null}
    </article>
  `}function V_(){var p,u,_,g,v,y,S,$,A,b,I,R,T,P,L,K,q,te,ne,G,Z;const e=At.value,t=Hv(),n=Dl(),s=(p=e==null?void 0:e.provider)!=null&&p.runtime_blocker?"blocked":(u=e==null?void 0:e.provider)!=null&&u.provider_reachable?"ready":"check",a=((_=e==null?void 0:e.provider)==null?void 0:_.actual_slots)??((g=e==null?void 0:e.provider)==null?void 0:g.total_slots)??0,o=((v=e==null?void 0:e.provider)==null?void 0:v.expected_slots)??"n/a",l=((y=e==null?void 0:e.provider)==null?void 0:y.actual_ctx)??((S=e==null?void 0:e.provider)==null?void 0:S.ctx_per_slot)??0,c=(($=e==null?void 0:e.provider)==null?void 0:$.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${W_} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${ea.value?i`<div class="empty-state">Loading swarm live state…</div>`:ta.value?i`<div class="empty-state error">${ta.value}</div>`:e?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${e.run_id??t??"swarm-live"}</strong><small>${e.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((A=e.summary)==null?void 0:A.joined_workers)??0}/${((b=e.summary)==null?void 0:b.expected_workers)??0}</strong><small>${((I=e.summary)==null?void 0:I.live_workers)??0}개 가동 · ${((R=e.summary)==null?void 0:R.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${o} · ctx ${l}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(T=e.summary)!=null&&T.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((P=e.provider)==null?void 0:P.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(L=e.summary)!=null&&L.pass_end_to_end?"통과":"확인 필요"}</strong><small>${e.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((K=e.operation)==null?void 0:K.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((q=e.squad)==null?void 0:q.label)??"없음"}</span>
                      <span>실행체</span><span>${((te=e.detachment)==null?void 0:te.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((ne=e.summary)==null?void 0:ne.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((G=e.summary)==null?void 0:G.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((Z=e.provider)==null?void 0:Z.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${e.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${e.truth_notes.length>0?i`<div class="command-tag-row">
                          ${e.truth_notes.map(x=>i`<span class="command-tag">${x}</span>`)}
                        </div>`:null}
                    <${Bl} swarm=${e} />
                  `:i`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.checklist.length>0?i`<div class="command-card-stack">
                ${e.checklist.map(x=>i`<${G_} item=${x} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.workers.length>0?i`<div class="command-card-stack">
                ${e.workers.map(x=>i`<${J_} worker=${x} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${D} panelId="command.swarm" compact=${!0} />
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
                  <span>Last Sample</span><span>${e.provider.last_sample_at?Q(e.provider.last_sample_at):"n/a"}</span>
                  <span>런타임 막힘</span><span>${e.provider.runtime_blocker??"none"}</span>
                  <span>Doctor Checked</span><span>${e.provider.checked_at?Q(e.provider.checked_at):"n/a"}</span>
                </div>
                ${e.provider.detail?i`<div class="command-card-sub">${e.provider.detail}</div>`:null}
                ${e.provider.timeline.length>0?i`<div class="command-trace-stack">
                      ${e.provider.timeline.slice(-12).map(x=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>${x.active_slots} active</strong>
                              <span class="command-chip">${Q(x.timestamp)}</span>
                            </div>
                            <div class="command-card-sub">slots ${x.active_slot_ids.join(", ")||"none"}</div>
                          </div>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:i`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.blockers.length>0?i`<div class="command-card-stack">
                ${e.blockers.map(x=>i`<${Jl} blocker=${x} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(e==null?void 0:e.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${D} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.recent_messages.length>0?i`<div class="command-trace-stack">
                ${e.recent_messages.map(x=>i`
                  <article class="command-trace-row">
                    <div class="command-trace-main">
                      <div class="command-trace-head">
                        <strong>${x.from}</strong>
                        <span class="command-chip">${Q(x.timestamp)}</span>
                      </div>
                      <div class="command-card-sub">seq ${x.seq}</div>
                    </div>
                    <pre class="command-trace-detail">${x.content}</pre>
                  </article>
                `)}
              </div>`:i`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${D} panelId="command.trace" compact=${!0} />
          </div>
          ${e&&e.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${e.recent_trace_events.map(x=>i`<${no} event=${x} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function Q_(e){var n;const t=[e.current_task_matches_run?"current":"drift",e.claim_marker_seen?"claim":"no-claim",e.done_marker_seen?"done":"no-done",e.final_marker_seen?"final":"no-final"];return{key:`swarm:${e.name}`,name:e.name,role:e.role,lane:e.lane,status:e.status,source:"swarm",task:e.current_task??e.bound_task_title??e.bound_task_id??"none",heartbeat:e.heartbeat_age_sec!=null?`${Math.round(e.heartbeat_age_sec)}s`:e.heartbeat_fresh?"clean":"n/a",detail:[e.bound_task_status??null,e.detachment_member?"detachment":null,e.squad_member?"squad":null].filter(Boolean).join(" · ")||"live swarm worker",markers:t,note:((n=e.last_message)==null?void 0:n.content)??null}}function Y_(e,t){const n=e.actor??e.spawn_role??`worker-${t+1}`,s=e.spawn_role??e.worker_class??e.spawn_agent??"worker",a=e.lane_id??e.capsule_mode??e.control_domain??"session",o=[e.has_turn?"turn":"silent",e.empty_note_turn_count>0?`empty:${e.empty_note_turn_count}`:"noted",e.turn_count>0?`turns:${e.turn_count}`:"turns:0"];return{key:`session:${n}:${t}`,name:n,role:s,lane:a,status:e.status,source:"session",task:e.task_profile??e.runtime_pool??"session lane",heartbeat:e.last_turn_ts_iso?Q(e.last_turn_ts_iso):"n/a",detail:[e.spawn_agent??null,e.spawn_model??null,e.routing_confidence!=null?Xn(e.routing_confidence):null].filter(Boolean).join(" · ")||"session worker",markers:o,note:e.routing_reason??null}}function qo(e){return w(e.severity)}function X_({worker:e}){return i`
    <article class="command-card compact warroom-worker-card ${w(Et(e.status))}">
      <div class="command-card-head">
        <div>
          <strong>${e.name}</strong>
          <div class="command-card-sub">${e.role} · ${e.lane}</div>
        </div>
        <span class="command-chip ${w(Et(e.status))}">${e.status}</span>
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
  `}function We({label:e,surface:t,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(t){kt(t),ce("command",{...Ml(t),...n});return}ce("intervene")}}
    >
      ${e}
    </button>
  `}function Z_(){var Z,x,Se,Be,dt,ut,F,Ae,pt,ln,cn,ts,ns,ss,as,is,os,rs,co,uo,po;const e=es(),t=At.value,n=me.value,s=ze.value,a=Xv(),o=t!=null&&t.operation?((Z=Yn.value)==null?void 0:Z.operations.find(J=>{var ls;return J.operation.operation_id===((ls=t.operation)==null?void 0:ls.operation_id)}))??null:null,l=Qv(),c=(t==null?void 0:t.workers)??[],p=(s==null?void 0:s.worker_cards)??[],u=l&&c.length>0?c.map(Q_):p.map(Y_),_=l,g=((x=e==null?void 0:e.decisions.summary)==null?void 0:x.pending)??0,v=(n==null?void 0:n.pending_confirms)??[],y=l?(t==null?void 0:t.blockers)??[]:[],S=(s==null?void 0:s.recommended_actions)??[],$=(Se=s==null?void 0:s.active_recommended_actions)!=null&&Se.length?s.active_recommended_actions:S,A=s==null?void 0:s.active_summary,b=(s==null?void 0:s.active_guidance_layer)??"fallback",I=(s==null?void 0:s.resident_judge_runtime)??(n==null?void 0:n.resident_judge_runtime),R=(s==null?void 0:s.attention_items)??[],T=((Be=t==null?void 0:t.recent_messages[0])==null?void 0:Be.timestamp)??null,P=((dt=t==null?void 0:t.recent_trace_events[0])==null?void 0:dt.timestamp)??null,L=l?T??P??null:null,K=a==null?void 0:a.summary,q=(l?(ut=t==null?void 0:t.summary)==null?void 0:ut.expected_workers:void 0)??(typeof(K==null?void 0:K.planned_worker_count)=="number"?K.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,te=(l?(F=t==null?void 0:t.summary)==null?void 0:F.joined_workers:void 0)??(typeof(K==null?void 0:K.active_agent_count)=="number"?K.active_agent_count:void 0)??u.length,ne=y.length>0||g>0||v.length>0?"warn":_||a?"ok":"warn",G=l?((Ae=e==null?void 0:e.swarm_status)==null?void 0:Ae.lanes.filter(J=>J.present))??[]:[];return ee(()=>{$e()},[]),ee(()=>{a!=null&&a.session_id&&Zt(a.session_id)},[a==null?void 0:a.session_id,n,(pt=t==null?void 0:t.detachment)==null?void 0:pt.session_id]),!_&&!a?ea.value||Ln.value?i`<div class="empty-state">live war room 불러오는 중…</div>`:i`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">라이브 워룸</div>
          <${D} panelId="command.warroom" compact=${!0} />
        </div>
        <div class="command-warroom-empty-copy">
          <strong>현재 live run 없음</strong>
          <p>활성 operation 또는 team session이 시작되면 이 화면이 자동으로 붙잡습니다.</p>
        </div>
        <div class="command-action-row">
          <${We} label="작전 보기" surface="operations" />
          <${We} label="스웜 보기" surface="swarm" />
          <${We} label="개입 열기" />
          <${We} label="제어 보기" surface="control" />
        </div>
      </section>
    `:i`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${w(ne)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">Live War Room</span>
            <strong>${l?((ln=t==null?void 0:t.operation)==null?void 0:ln.objective)??(a==null?void 0:a.session_id)??"active run":(a==null?void 0:a.session_id)??"active run"}</strong>
            <div class="command-card-sub">
              ${l?((cn=t==null?void 0:t.operation)==null?void 0:cn.operation_id)??"operation 없음":"session truth"}
              ${a!=null&&a.session_id?` · session ${a.session_id}`:""}
              ${l&&((ts=t==null?void 0:t.detachment)!=null&&ts.detachment_id)?` · detachment ${t.detachment.detachment_id}`:""}
            </div>
            ${A!=null&&A.summary?i`<div class="command-warroom-guidance ${ra(b)}">
                  <strong>${Zi(b)}</strong>
                  <span>${A.summary}</span>
                </div>`:null}
          </div>
          <div class="command-action-row">
            <${We}
              label="스웜 상세"
              surface="swarm"
              params=${{...l&&((ns=t==null?void 0:t.operation)!=null&&ns.operation_id)?{operation_id:t.operation.operation_id}:{},...l&&(t!=null&&t.run_id)?{run_id:t.run_id}:{}}}
            />
            <${We} label="트레이스" surface="trace" />
            ${l&&o?i`<${We}
                  label="체인"
                  surface="chains"
                  params=${{operation:o.operation.operation_id}}
                />`:null}
            <${We} label="Intervene" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>Workers</span>
            <strong>${te??0}/${q??0}</strong>
            <small>${l?((ss=t==null?void 0:t.summary)==null?void 0:ss.completed_workers)??0:0} 완료 · ${u.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${l?(as=t==null?void 0:t.provider)!=null&&as.runtime_blocker?"blocked":(is=t==null?void 0:t.provider)!=null&&is.provider_reachable?"ready":a?us(a.status):"check":a?us(a.status):"check"}</strong>
            <small>${l?`slots ${((os=t==null?void 0:t.provider)==null?void 0:os.active_slots_now)??0}/${((rs=t==null?void 0:t.provider)==null?void 0:rs.actual_slots)??((co=t==null?void 0:t.provider)==null?void 0:co.total_slots)??0} · ctx ${((uo=t==null?void 0:t.provider)==null?void 0:uo.actual_ctx)??((po=t==null?void 0:t.provider)==null?void 0:po.ctx_per_slot)??0}`:`session workers ${(s==null?void 0:s.worker_cards.length)??0}`}</small>
          </div>
          <div class="monitor-stat-card ${w(y.length>0||g>0?"warn":"ok")}">
            <span>Pressure</span>
            <strong>${y.length+g+v.length}</strong>
            <small>blockers ${y.length} · approvals ${g} · confirms ${v.length}</small>
          </div>
          <div class="monitor-stat-card ${w(ra(b))}">
            <span>Resident Judge</span>
            <strong>${eo(I)}</strong>
            <small>${to(A)}${I!=null&&I.model_used?` · ${I.model_used}`:""}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${Q(L)}</strong>
            <small>${T?"message":P?"trace":"waiting"}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            ${G.length>0?i`
                  <${Gl} lanes=${G} />
                  <${Wl} lanes=${G} />
                `:a?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${w(Et(a.status))}">${us(a.status)}</span>
                      </div>
                      <p>command-plane live run은 아직 옅지만, session 쪽 worker와 digest를 기준으로 워룸을 유지합니다.</p>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${vn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${vn(a.remaining_sec)}</span>
                      </div>
                    </article>
                  `:i`<div class="empty-state">보이는 lane이 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Worker Roster</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            ${u.length>0?i`<div class="command-card-stack">
                  ${u.map(J=>i`<${X_} worker=${J} />`)}
                </div>`:i`<div class="empty-state">활성 worker 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Live Feed</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            ${t&&t.recent_messages.length>0&&l?i`<div class="command-trace-stack">
                  ${t.recent_messages.map(J=>i`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${J.from}</strong>
                          <span class="command-chip">${Q(J.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${J.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${J.content}</pre>
                    </article>
                  `)}
                </div>`:$.length>0||R.length>0?i`<div class="command-card-stack">
                    ${$.slice(0,4).map(J=>i`
                      <article class="command-guide-card ${qo(J)}">
                        <div class="command-guide-head">
                          <strong>${J.action_type}</strong>
                          <span class="command-chip ${qo(J)}">${J.target_type}</span>
                        </div>
                        <p>${J.reason}</p>
                      </article>
                    `)}
                    ${R.slice(0,3).map(J=>i`
                      <article class="command-alert ${w(J.severity)}">
                        <div class="command-card-head">
                          <strong>${J.kind}</strong>
                          <span class="command-chip ${w(J.severity)}">${J.severity}</span>
                        </div>
                        <p>${J.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?i`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((J,ls)=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>session-event-${ls+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${aa(J)}</pre>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">메시지나 attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Trace Feed</div>
              <${D} panelId="command.trace" compact=${!0} />
            </div>
            ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                  ${t.recent_trace_events.map(J=>i`<${no} event=${J} />`)}
                </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Pressure</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&t?i`<${Bl} swarm=${t} />`:null}
              ${y.length>0?y.map(J=>i`<${Jl} blocker=${J} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${g>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending approvals</strong>
                        <span class="command-chip warn">${g}</span>
                      </div>
                      <p>strict action이 묶여 있습니다. 실제 승인 처리는 control 표면에서 합니다.</p>
                    </article>
                  `:null}
              ${v.length>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending confirms</strong>
                        <span class="command-chip warn">${v.length}</span>
                      </div>
                      <p>operator preview가 사람 확인을 기다리고 있습니다.</p>
                      <div class="command-tag-row">
                        ${v.slice(0,3).map(J=>i`<span class="command-tag">${J.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
            </div>
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Focus Detail</div>
              <${D} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${l&&(t!=null&&t.operation)?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${t.operation.objective}</strong>
                          <div class="command-card-sub">${t.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${w(Et(t.operation.status))}">${t.operation.status}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Unit</span><span>${t.operation.assigned_unit_id}</span>
                        <span>Trace</span><span>${t.operation.trace_id}</span>
                        <span>Autonomy</span><span>${t.operation.autonomy_level??"n/a"}</span>
                        <span>Updated</span><span>${Q(t.operation.updated_at)}</span>
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
                        <span class="command-chip ${w(Et(t.detachment.status))}">${t.detachment.status??"active"}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Leader</span><span>${t.detachment.leader_id??"unassigned"}</span>
                        <span>Roster</span><span>${t.detachment.roster.length}</span>
                        <span>Session</span><span>${t.detachment.session_id??"none"}</span>
                        <span>Heartbeat</span><span>${Nl(t.detachment.heartbeat_deadline)}</span>
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
                        <span class="command-chip ${w(Et(a.status))}">${us(a.status)}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Progress</span><span>${a.progress_pct!=null?`${a.progress_pct}%`:"n/a"}</span>
                        <span>Elapsed</span><span>${vn(a.elapsed_sec)}</span>
                        <span>Remaining</span><span>${vn(a.remaining_sec)}</span>
                        <span>Done delta</span><span>${a.done_delta_total??0}</span>
                      </div>
                    </article>
                  `:null}
            </div>
          </section>
        </div>
      </div>
    </div>
  `}function eg({source:e}){const t=gc(null),[n,s]=tr(null);return ee(()=>{let a=!1;const o=t.current;return o?(o.innerHTML="",s(null),(async()=>{try{const c=await wv(),{svg:p}=await c.render(`command-chain-${Nv()}`,e);if(a||!t.current)return;t.current.innerHTML=p}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid render failed")}})(),()=>{a=!0,t.current&&(t.current.innerHTML="")}):void 0},[e]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${t}></div>
    </div>
  `}function tg({overlay:e,selected:t,onSelect:n}){const s=e.operation.chain,a=e.runtime;return i`
    <button class="command-chain-item ${t?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${e.operation.objective}</strong>
          <div class="command-card-sub">${e.operation.operation_id}</div>
        </div>
        <span class="command-chip ${et(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??e.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?i`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?i`<span class="command-tag ${et(s==null?void 0:s.status)}">${Xn(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${wl(e.history)}</div>
    </button>
  `}function ng({item:e}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${e.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${et(e.event)}">${e.event}</span>
      </div>
      <div class="command-card-sub">${Q(e.timestamp)}</div>
      <div class="command-card-sub">${wl(e)}</div>
    </article>
  `}function sg({node:e}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${e.id}</strong>
        <span class="command-chip ${et(e.status)}">${e.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${e.type??"node"}
        ${typeof e.duration_ms=="number"?` · ${e.duration_ms}ms`:""}
      </div>
      ${e.error?i`<div class="command-card-sub error-text">${e.error}</div>`:null}
    </article>
  `}function ag({card:e}){const t=e.operation,n=`pause:${t.operation_id}`,s=`resume:${t.operation_id}`,a=`recall:${t.operation_id}`,o=t.chain,l=(o==null?void 0:o.run_id)??null;return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${t.objective}</strong>
          <div class="command-card-sub">${t.operation_id}</div>
        </div>
        <span class="command-chip ${w(t.status==="active"?"ok":t.status==="paused"?"warn":t.status==="failed"?"bad":"ok")}">${t.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${e.assigned_unit_label??t.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${t.trace_id}</span>
        <span>Autonomy</span><span>${t.autonomy_level??"n/a"}</span>
        <span>Budget</span><span>${t.budget_class??"standard"}</span>
        <span>Source</span><span>${t.source??"managed"}</span>
        <span>Updated</span><span>${Q(t.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${et(o.status)}">${o.status}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">run ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${t.checkpoint_ref?i`<div class="command-card-foot">Checkpoint ${t.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{kt("swarm"),ce("command",{surface:"swarm",operation_id:t.operation_id,...l?{run_id:l}:{}})}}
        >
          Swarm Live
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{Qi(t.operation_id),kt("chains"),ce("command",{surface:"chains",operation:t.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="active"?i`
              <button class="control-btn ghost" disabled=${se(n)} onClick=${()=>tt(()=>kv(t.operation_id))}>
                ${se(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${se(a)} onClick=${()=>tt(()=>Sv(t.operation_id))}>
                ${se(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="paused"?i`
              <button class="control-btn ghost" disabled=${se(s)} onClick=${()=>tt(()=>xv(t.operation_id))}>
                ${se(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function ig({card:e}){var n;const t=e.detachment;return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.detachment_id}</strong>
          <div class="command-card-sub">${((n=e.operation)==null?void 0:n.objective)??t.operation_id}</div>
        </div>
        <span class="command-chip ${w(t.status)}">${t.status??"active"}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${e.assigned_unit_label??t.assigned_unit_id}</span>
        <span>Leader</span><span>${t.leader_id??"unassigned"}</span>
        <span>Roster</span><span>${t.roster.length}</span>
        <span>Session</span><span>${t.session_id??"none"}</span>
        <span>Runtime</span><span>${t.runtime_kind??"managed"}</span>
        <span>Runtime Ref</span><span>${t.runtime_ref??"n/a"}</span>
        <span>Progress</span><span>${Q(t.last_progress_at)}</span>
        <span>Heartbeat</span><span>${Nl(t.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Q(t.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${t.heartbeat_deadline?i`<span class="command-tag ${Pv(t.heartbeat_deadline)}">
              deadline ${t.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function og(){const e=je.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${D} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.operations.operations.length>0?i`<div class="command-card-stack">
              ${e.operations.operations.map(t=>i`<${ag} card=${t} />`)}
            </div>`:i`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${D} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${e.detachments.detachments.map(t=>i`<${ig} card=${t} />`)}
            </div>`:i`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function rg(){var c,p,u,_,g,v,y,S,$,A,b,I,R,T,P,L;const e=Yn.value,t=(e==null?void 0:e.operations)??[],n=Gt.value,s=t.find(K=>K.operation.operation_id===n)??t[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,o=((p=wn.value)==null?void 0:p.run)??(s==null?void 0:s.preview_run)??null,l=!((u=wn.value)!=null&&u.run)&&!!(s!=null&&s.preview_run);return ee(()=>{a?yv(a):hv()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${D} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${et(e==null?void 0:e.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${et(e==null?void 0:e.connection.status)}">${(e==null?void 0:e.connection.status)??"disconnected"}</span>
          </div>
          <p>${(e==null?void 0:e.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(e==null?void 0:e.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((_=e==null?void 0:e.summary)==null?void 0:_.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((g=e==null?void 0:e.summary)==null?void 0:g.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((v=e==null?void 0:e.summary)==null?void 0:v.recent_failures)??0}</span>
            <span>Last Event</span><span>${Q((y=e==null?void 0:e.summary)==null?void 0:y.last_history_event_at)}</span>
          </div>
        </article>

        ${na.value?i`<div class="empty-state error">${na.value}</div>`:null}

        ${ki.value&&!e?i`<div class="empty-state">Loading chain overlays…</div>`:t.length>0?i`
                <div class="command-chain-list">
                  ${t.map(K=>i`
                    <${tg}
                      overlay=${K}
                      selected=${(s==null?void 0:s.operation.operation_id)===K.operation.operation_id}
                      onSelect=${()=>Qi(K.operation.operation_id)}
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
                  ${e.recent_history.slice(0,6).map(K=>i`<${ng} item=${K} />`)}
                </div>
              `:i`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${D} panelId="command.chains" compact=${!0} />
        </div>
        ${s?i`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${et((S=s.operation.chain)==null?void 0:S.status)}">
                    ${(($=s.operation.chain)==null?void 0:$.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((A=s.operation.chain)==null?void 0:A.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((b=s.operation.chain)==null?void 0:b.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${Xn((I=s.runtime)==null?void 0:I.progress)}</span>
                  <span>Elapsed</span><span>${vn((R=s.runtime)==null?void 0:R.elapsed_sec)}</span>
                  <span>Updated</span><span>${Q(((T=s.operation.chain)==null?void 0:T.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(P=s.operation.chain)!=null&&P.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((L=s.operation.chain)==null?void 0:L.chain_id)??"graph"}</span>
                      </div>
                      <${eg} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":l?"preview":"captured":"pending"}
                  </span>
                </div>
                ${sa.value?i`<div class="empty-state">Loading run detail…</div>`:zn.value?i`<div class="empty-state error">${zn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${l?i`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(K=>i`<${sg} node=${K} />`)}
                          </div>
                        `:i`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:i`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function lg({decision:e}){const t=`approve:${e.decision_id}`,n=`deny:${e.decision_id}`,s=e.source==="projected_operator";return i`
    <article class="command-card ${w(e.status)}">
      <div class="command-card-head">
        <div>
          <strong>${e.requested_action}</strong>
          <div class="command-card-sub">${e.scope_type}:${e.scope_id}</div>
        </div>
        <span class="command-chip ${w(e.status)}">${e.status??"pending"}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${e.decision_id}</span>
        <span>By</span><span>${e.requested_by??"unknown"}</span>
        <span>Source</span><span>${e.source??"managed"}</span>
        <span>Trace</span><span class="mono">${e.trace_id}</span>
        <span>Created</span><span>${Q(e.created_at)}</span>
        <span>Reason</span><span>${e.reason??"n/a"}</span>
      </div>
      ${e.status==="pending"&&!s?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${se(t)} onClick=${()=>tt(()=>Cv(e.decision_id))}>
                ${se(t)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${se(n)} onClick=${()=>tt(()=>Iv(e.decision_id))}>
                ${se(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function cg({row:e}){var c,p,u;const t=e.unit,n=`freeze:${t.unit_id}`,s=`kill:${t.unit_id}`,a=!!((c=t.policy)!=null&&c.frozen),o=!!((p=t.policy)!=null&&p.kill_switch),l=Math.round((e.utilization??0)*100);return i`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${t.label}</strong>
          <div class="command-card-sub">${t.unit_id}</div>
        </div>
        <span class="command-chip ${w(l>100?"bad":l>70?"warn":"ok")}">${l}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${e.roster_live??0}/${e.roster_total??0}</span>
        <span>Headcount Cap</span><span>${e.headcount_cap??0}</span>
        <span>Ops</span><span>${e.active_operations??0}/${e.active_operation_cap??0}</span>
        <span>Autonomy</span><span>${((u=t.policy)==null?void 0:u.autonomy_level)??"n/a"}</span>
        <span>Frozen</span><span>${a?"yes":"no"}</span>
        <span>Kill Switch</span><span>${o?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${se(n)} onClick=${()=>tt(()=>Tv(t.unit_id,!a))}>
          ${se(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${se(s)} onClick=${()=>tt(()=>Rv(t.unit_id,!o))}>
          ${se(s)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function dg(){const e=je.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${D} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${e.decisions.decisions.map(t=>i`<${lg} decision=${t} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${D} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${e.capacity.capacity.map(t=>i`<${cg} row=${t} />`)}
            </div>`:i`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function ug(){return i`
    <div class="command-surface-tabs grouped">
      ${Mv.map(e=>i`
        <div class="command-tab-group" key=${e.id}>
          <span class="command-tab-group-label">${e.label}</span>
          <div class="command-tab-group-items">
            ${zl.filter(t=>t.group===e.id).map(t=>i`
                <button
                  class="command-surface-tab ${Y.value===t.id?"active":""}"
                  onClick=${()=>{kt(t.id),ce("command",Ml(t.id))}}
                >
                  ${t.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function pg(){if(Y.value==="warroom")return i`<${Z_} />`;if(Y.value==="summary")return i`<${g_} />`;if(Y.value==="swarm")return i`<${V_} />`;if(!je.value)return i`<${f_} />`;switch(Y.value){case"chains":return i`<${rg} />`;case"topology":return i`<${M_} />`;case"alerts":return i`<${j_} />`;case"trace":return i`<${E_} />`;case"control":return i`<${dg} />`;case"operations":default:return i`<${og} />`}}function mg(){return ee(()=>{jt(),Jt(),bv(),Je()},[]),ee(()=>{if(O.value.tab!=="command")return;const e=O.value.params.surface,t=O.value.params.operation,n=Vn(O.value);if(Mo(e))kt(e);else if(n){const s=Xr(n);Mo(s)&&kt(s)}else e||kt("warroom");t&&Qi(t),(e==="swarm"||e==="warroom"||Y.value==="warroom")&&Je(),(e==="warroom"||Y.value==="warroom")&&$e()},[O.value.tab,O.value.params.surface,O.value.params.operation,O.value.params.operation_id,O.value.params.run_id,O.value.params.source,O.value.params.action_type,O.value.params.target_type,O.value.params.target_id,O.value.params.focus_kind]),ee(()=>{let e=null;const t=()=>{e||(e=window.setTimeout(()=>{e=null,jt(),Jt(),(Y.value==="swarm"||Y.value==="warroom")&&Je(),Y.value==="warroom"&&$e()},250))},n=new EventSource(qv()),s=Ev.map(a=>{const o=()=>t();return n.addEventListener(a,o),{type:a,handler:o}});return n.onerror=()=>{t()},()=>{s.forEach(({type:a,handler:o})=>{n.removeEventListener(a,o)}),n.close(),e&&window.clearTimeout(e)}},[]),ee(()=>{const e=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const t=Y.value;t!=="swarm"&&t!=="warroom"||(jt(),Je(),t==="warroom"&&$e())},5e3);return()=>{window.clearInterval(e)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{tt(()=>Av())}}
            disabled=${se("dispatch:tick")}
          >
            ${se("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{jt(),Jt(),Je(),Y.value==="warroom"&&$e()}}
            disabled=${Js.value}
          >
            ${Js.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Qs.value?i`<div class="empty-state error">${Qs.value}</div>`:null}
      ${Xs.value?i`<div class="empty-state error">${Xs.value}</div>`:null}
      <${he} surfaceId="command" />
      <${u_} />
      ${Y.value==="warroom"?null:i`<${p_} />`}
      <${ug} />
      <${pg} />
    </section>
  `}function vg(){var g;const e=me.value,t=Hi.value,n=(e==null?void 0:e.room)??{},s=(e==null?void 0:e.pending_confirms)??[],a=(e==null?void 0:e.recent_messages)??[],o=(t==null?void 0:t.recommended_actions)??[],l=(g=t==null?void 0:t.active_recommended_actions)!=null&&g.length?t.active_recommended_actions:o,c=t==null?void 0:t.active_summary,p=(t==null?void 0:t.resident_judge_runtime)??(e==null?void 0:e.resident_judge_runtime),u=(t==null?void 0:t.active_guidance_layer)??"fallback",_=a.slice(0,5);return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Room 개입</div>
          <${D} panelId="intervene.action_studio" compact=${!0} />
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
          <div class="ops-stat ${y_(p)}">
            <span>Resident Judge</span>
            <strong>${eo(p)}</strong>
          </div>
        </div>

        <label class="control-label" for="ops-broadcast">Room 방송</label>
        <div class="control-row">
          <input
            id="ops-broadcast"
            class="control-input"
            type="text"
            placeholder="@agent 또는 room 전체 공지"
            value=${Vt.value}
            onInput=${v=>{Vt.value=v.target.value}}
            onKeyDown=${v=>{v.key==="Enter"&&Oo()}}
            disabled=${V.value}
          />
          <button class="control-btn" onClick=${()=>{Oo()}} disabled=${V.value||Vt.value.trim()===""}>
            보내기
          </button>
        </div>

        <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
        <div class="control-row ops-split-row">
          <input
            id="ops-pause-reason"
            class="control-input"
            type="text"
            value=${xi.value}
            onInput=${v=>{xi.value=v.target.value}}
            disabled=${V.value}
          />
          <button class="control-btn ghost" onClick=${()=>{T_()}} disabled=${V.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{Kl()}} disabled=${V.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${Qt.value}
          onInput=${v=>{Qt.value=v.target.value}}
          disabled=${V.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${Mn.value}
          onInput=${v=>{Mn.value=v.target.value}}
          disabled=${V.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${jn.value}
            onChange=${v=>{jn.value=v.target.value}}
            disabled=${V.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{R_()}} disabled=${V.value||Qt.value.trim()===""}>
            주입
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">추천 개입</div>
          <${D} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
        <article class="ops-guidance-card ${ra(u)}">
          <div class="ops-guidance-head">
            <strong>${Zi(u)}</strong>
            <span>${(p==null?void 0:p.keeper_name)??(t==null?void 0:t.judgment_owner)??"judge 없음"}</span>
          </div>
          <div class="ops-guidance-body">
            ${(c==null?void 0:c.summary)??"현재 active guidance 요약이 없습니다. fallback queue만 표시합니다."}
          </div>
          <div class="ops-guidance-meta">
            <span>authoritative ${t!=null&&t.authoritative_judgment_available?"yes":"no"}</span>
            <span>${to(c)}</span>
            ${p!=null&&p.model_used?i`<span>${p.model_used}</span>`:null}
          </div>
        </article>
        ${Nn.value&&!t?i`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:l.length>0?i`
          <div class="ops-log-list">
            ${l.map(v=>i`
              <article key=${`${v.action_type}:${v.target_type}:${v.target_id??"room"}`} class="ops-log-entry ${v.severity}">
                <div class="ops-log-head">
                  <strong>${Fn(v.action_type)}</strong>
                  <span>${Kn(v.target_type)}${v.target_id?` · ${v.target_id}`:""}</span>
                  <span>${Fl(v.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${v.reason}</div>
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
          <${D} panelId="intervene.pending_confirmations" compact=${!0} />
        </div>
        <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
        ${s.length>0?i`
          <div class="ops-confirmation-list">
            ${s.map(v=>i`
              <article key=${v.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${Fn(v.action_type)}</strong>
                  <span>${Kn(v.target_type)}${v.target_id?` · ${v.target_id}`:""}</span>
                  <span>${v.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${v.preview?i`<pre class="ops-code-block compact">${ql(v.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{w_(v.confirm_token)}} disabled=${V.value}>
                    실행
                  </button>
                  <span class="ops-token">${v.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        `:i`<div class="ops-empty">지금 승인 대기는 없습니다.</div>`}
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 Room 메시지</div>
          <${D} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${_.length>0?i`
          <div class="ops-feed-list">
            ${_.map(v=>i`
              <article key=${v.seq??v.id??v.timestamp} class="ops-feed-item">
                <div class="ops-feed-meta">
                  <strong>${v.from}</strong>
                  <span>${v.timestamp}</span>
                </div>
                <div class="ops-feed-content">${v.content}</div>
              </article>
            `)}
          </div>
        `:i`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
      </section>
    </div>
  `}function _g(){var p;const e=me.value,t=ze.value,n=(e==null?void 0:e.sessions)??[],s=n.find(u=>u.session_id===en.value)??n[0]??null,a=t==null?void 0:t.active_summary,o=(t==null?void 0:t.active_guidance_layer)??"fallback",l=(t==null?void 0:t.resident_judge_runtime)??(e==null?void 0:e.resident_judge_runtime),c=(p=t==null?void 0:t.active_recommended_actions)!=null&&p.length?t.active_recommended_actions:(t==null?void 0:t.recommended_actions)??[];return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${D} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(u=>{var _;return i`
            <button
              key=${u.session_id}
              class="ops-entity-card ${(s==null?void 0:s.session_id)===u.session_id?"active":""}"
              onClick=${()=>{en.value=u.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${u.session_id}</strong>
                <span class="status-badge ${u.status??"idle"}">${Dt(u.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(u.progress_pct??0)}%</span>
                <span>${u.done_delta_total??0}건 완료</span>
                <span>${(_=u.team_health)!=null&&_.status?Dt(String(u.team_health.status)):"상태 확인 필요"}</span>
              </div>
            </button>
          `})}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Session 요약</div>
          <${D} panelId="intervene.session_digest" compact=${!0} />
        </div>
        <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
        ${s&&t?i`
          <article class="ops-guidance-card ${ra(o)}">
            <div class="ops-guidance-head">
              <strong>${Zi(o)}</strong>
              <span>${eo(l)}</span>
            </div>
            <div class="ops-guidance-body">
              ${(a==null?void 0:a.summary)??"현재 이 session에 대한 resident guidance가 없습니다. fallback digest를 표시합니다."}
            </div>
            <div class="ops-guidance-meta">
              <span>authoritative ${t.authoritative_judgment_available?"yes":"no"}</span>
              <span>${to(a)}</span>
              ${l!=null&&l.model_used?i`<span>${l.model_used}</span>`:null}
            </div>
          </article>
          ${c.length>0?i`
            <div class="ops-log-list">
              ${c.map(u=>i`
                <article key=${`${u.action_type}:${u.target_type}:${u.target_id??"session"}`} class="ops-log-entry ${u.severity}">
                  <div class="ops-log-head">
                    <strong>${Fn(u.action_type)}</strong>
                    <span>${Kn(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
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
                  <span>${Kn(u.target_type)}${u.target_id?` · ${u.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${u.summary}</div>
              </article>
            `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${t.worker_cards.length>0?t.worker_cards.map(u=>i`
              <article key=${`${u.actor??u.spawn_role??"worker"}:${u.spawn_agent??u.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${u.actor??u.spawn_role??"worker"}</strong>
                  <span>${Dt(u.status)}</span>
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
          <${D} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>

        ${s?i`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${s.session_id}</div>
            <div class="ops-detail-meta">
              <span>상태: ${Dt(s.status)}</span>
              <span>경과: ${s.elapsed_sec??0}초</span>
              <span>남은 시간: ${s.remaining_sec??0}초</span>
            </div>
            ${s.recent_events&&s.recent_events.length>0?i`
              <pre class="ops-code-block compact">${ql(s.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${Le.value}
            onChange=${u=>{Le.value=u.target.value}}
            disabled=${V.value||!s}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
          </select>
          <button class="control-btn" onClick=${()=>{P_()}} disabled=${V.value||!s}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${S_(Le.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${En.value}
          onInput=${u=>{En.value=u.target.value}}
          disabled=${V.value||!s}
        ></textarea>

        ${Le.value==="task"?i`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${Dn.value}
            onInput=${u=>{Dn.value=u.target.value}}
            disabled=${V.value||!s}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${On.value}
            onInput=${u=>{On.value=u.target.value}}
            disabled=${V.value||!s}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${qn.value}
            onChange=${u=>{qn.value=u.target.value}}
            disabled=${V.value||!s}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
        `:null}

        <div class="control-row ops-split-row">
          <input
            class="control-input"
            type="text"
            value=${ia.value}
            onInput=${u=>{ia.value=u.target.value}}
            disabled=${V.value||!s}
          />
          <button class="control-btn ghost" onClick=${()=>{L_()}} disabled=${V.value||!s}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function gg(){var o;const e=me.value,t=(e==null?void 0:e.keepers)??[],n=(e==null?void 0:e.persistent_agents)??[],s=(e==null?void 0:e.available_actions)??[],a=t.find(l=>l.name===oa.value)??t[0]??null;return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${D} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${t.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:t.map(l=>i`
            <button
              key=${l.name}
              class="ops-entity-card ${(a==null?void 0:a.name)===l.name?"active":""}"
              onClick=${()=>{oa.value=l.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${l.name}</strong>
                <span class="status-badge ${l.status??"idle"}">${Dt(l.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${l.model??"model 확인 필요"}</span>
                <span>${typeof l.context_ratio=="number"?`${Math.round(l.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${Eo(l.last_turn_ago_s)}</span>
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
                    <span class="status-badge ${l.status??"idle"}">${Dt(l.status)}</span>
                  </div>
                  <div class="ops-entity-meta">
                    <span>persistent</span>
                    <span>${l.model??"model 확인 필요"}</span>
                    <span>${Eo(l.last_turn_ago_s)}</span>
                  </div>
                </article>
              `)}
        </div>
      </section>

      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Keeper 액션</div>
          <${D} panelId="intervene.action_studio" compact=${!0} />
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
          value=${Yt.value}
          onInput=${l=>{Yt.value=l.target.value}}
          disabled=${V.value||!a}
        ></textarea>
        <div class="control-row">
          <button class="control-btn" onClick=${()=>{N_()}} disabled=${V.value||!a||Yt.value.trim()===""}>
            keeper에 보내기
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">가능한 액션 목록</div>
          <${D} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
        <div class="ops-log-list">
          ${s.length?s.map(l=>i`
                <article key=${`${l.action_type}:${l.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${Fn(l.action_type)}</strong>
                    <span>${Kn(l.target_type)}</span>
                    <span>${Fl(l.confirm_required)}</span>
                  </div>
                  <div class="ops-log-body">${l.description??"설명이 아직 없습니다."}</div>
                </article>
              `):i`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 개입 로그</div>
          <${D} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <div class="ops-log-list">
          ${Ws.value.length===0?i`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:Ws.value.map(l=>i`
            <article key=${l.id} class="ops-log-entry ${l.outcome}">
              <div class="ops-log-head">
                <strong>${Fn(l.action_type)}</strong>
                <span>${l.target_label}</span>
                <span>${l.at}</span>
              </div>
              <div class="ops-log-body">${l.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function fg(){var $,A;const e=me.value,t=O.value.tab==="intervene"?Vn(O.value):null,n=Hi.value,s=(e==null?void 0:e.room)??{},a=(e==null?void 0:e.sessions)??[],o=(e==null?void 0:e.keepers)??[],l=(e==null?void 0:e.pending_confirms)??[],c=a.find(b=>b.session_id===en.value)??a[0]??null,p=(n==null?void 0:n.attention_items)??[],u=p.filter(k_),_=p.filter(x_),g=a.filter(b=>b_(b)!=="ok"),v=o.filter(b=>Ma(b)!=="ok"),y=I_(t,a,o);ee(()=>{xt()},[]),ee(()=>{if(O.value.tab!=="intervene"){_s.value=null;return}if(!t){_s.value=null;return}_s.value!==t.id&&(_s.value=t.id,C_(t))},[O.value.tab,O.value.params.source,O.value.params.action_type,O.value.params.target_type,O.value.params.target_id,O.value.params.focus_kind,t==null?void 0:t.id]),ee(()=>{const b=(c==null?void 0:c.session_id)??null;Zt(b)},[c==null?void 0:c.session_id]);const S=[{key:"room",label:"Room 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:l.length,detail:l.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:l.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:u.length>0?u.length:a.length,detail:u.length>0?(($=u[0])==null?void 0:$.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:u.length>0?Do(u):a.length===0?"warn":g.some(b=>tn(b.status)==="paused")?"bad":g.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:_.length>0?_.length:v.length,detail:_.length>0?((A=_[0])==null?void 0:A.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":v.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:_.length>0?Do(_):v.some(b=>Ma(b)==="bad")?"bad":v.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${he} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">Intervene</div>
            <${D} panelId="intervene.action_studio" compact=${!0} />
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
            value=${xa.value}
            onInput=${b=>h_(b.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{$e(),xt(),Zt((c==null?void 0:c.session_id)??null)}}
            disabled=${Ln.value||V.value}
          >
            ${Ln.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${at.value?i`<section class="ops-banner error">${at.value}</section>`:null}
      ${Xt.value?i`<section class="ops-banner error">${Xt.value}</section>`:null}
      ${t?i`
        <section class="ops-banner ${y?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${t.source_label}</strong>
            <span>${ha(t.action_type)}</span>
            <span>${Ki(t)}</span>
          </div>
          <div class="ops-handoff-body">${t.summary}</div>
          ${t.payload_preview?i`<div class="ops-handoff-preview">${t.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${y?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const b=[];if(l.length>0&&b.push({label:`확인 대기 ${l.length}건 처리`,desc:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:"bad",onClick:()=>{const I=document.querySelector(".ops-pending-section");I==null||I.scrollIntoView({behavior:"smooth"})}}),s.paused&&b.push({label:"Room 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void Kl()}),v.length>0){const I=v.filter(R=>Ma(R)==="bad");b.push({label:I.length>0?`Keeper ${I.length}개 오프라인`:`Keeper ${v.length}개 점검 필요`,desc:I.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:I.length>0?"bad":"warn",onClick:()=>{const R=document.querySelector(".ops-keeper-section");R==null||R.scrollIntoView({behavior:"smooth"})}})}return b.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${b.slice(0,3).map(I=>i`
                <button class="ops-action-guide-item ${I.tone}" onClick=${I.onClick}>
                  <strong>${I.label}</strong>
                  <span>${I.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `})()}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${D} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 room인지, session인지, keeper인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${S.map(b=>i`
            <div key=${b.key} class="ops-priority-card ${b.tone}">
              <span class="ops-priority-label">${b.label}</span>
              <strong>${b.value}</strong>
              <div class="ops-priority-detail">${b.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${vg} />
        <${_g} />
        <${gg} />
      </div>
    </section>
  `}function $g({text:e}){if(!e)return null;const t=hg(e);return i`<div class="markdown-content">${t}</div>`}function hg(e){const t=e.split(`
`),n=[];let s=0;for(;s<t.length;){const a=t[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),p=[];for(s++;s<t.length&&!t[s].startsWith(l);)p.push(t[s]),s++;s++,n.push(i`<pre><code class=${c?`language-${c}`:""}>${p.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<t.length&&!t[s].includes("</think>");)l.push(t[s]),s++;if(s<t.length){const u=t[s].replace("</think>","").trim();u&&l.push(u),s++}const p=l.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${ja(p)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<t.length&&t[s].startsWith("> ");)l.push(t[s].slice(2)),s++;n.push(i`<blockquote>${ja(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<t.length;){const l=t[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;o.push(l),s++}o.length>0&&n.push(i`<p>${ja(o.join(`
`))}</p>`)}return n}function ja(e){const t=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(e))!==null;){if(a.index>s&&t.push(e.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);t.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);t.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);t.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&t.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<e.length&&t.push(e.slice(s)),t.length>0?t:[e]}const Vl=[{id:"recent",label:"Latest"},{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Ls=f(null),Ns=f([]),nn=f(!1),bt=f(null),bn=f(""),kn=f(!1),Ot=f(!0),so=20,Lt=f(so);function yg(){var t,n;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const bg=f(yg());function kg(e){const t=e.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return t?t.length>180?`${t.slice(0,177)}...`:t:"No preview available"}function Fo(e){return e.updated_at!==e.created_at}function xg(e){const t=`${e.title} ${e.author} ${e.tags.join(" ")} ${e.flair??""}`.toLowerCase();return/\b(test|smoke|harness|sandbox|dummy|sample|tmp|qa|e2e)\b/.test(t)||t.includes("테스트")||t.includes("실험")}function Sg(e){if(e.post_kind)return e.post_kind==="automation";const t=(e.hearth??"").toLowerCase();return e.visibility!=="internal"||!e.expires_at||!t?!1:!!(t.startsWith("mdal")||t.includes("harness"))}function Ql(e){return Ot.value?e.filter(t=>Sg(t)?!1:t.post_kind||t.hearth||t.visibility||t.expires_at?!0:!xg(t)):e}async function ao(e){bt.value=e,Ls.value=null,Ns.value=[],nn.value=!0;try{const t=await ud(e);if(bt.value!==e)return;Ls.value={id:t.id,author:t.author,title:t.title,content:t.content,tags:t.tags,votes:t.votes,vote_balance:t.vote_balance,comment_count:t.comment_count,created_at:t.created_at,updated_at:t.updated_at,post_kind:t.post_kind,flair:t.flair,hearth:t.hearth,visibility:t.visibility,expires_at:t.expires_at,hearth_count:t.hearth_count},Ns.value=t.comments??[]}catch{bt.value===e&&(Ls.value=null,Ns.value=[])}finally{bt.value===e&&(nn.value=!1)}}async function Ko(e){const t=bn.value.trim();if(t){kn.value=!0;try{await pd(e,bg.value,t),bn.value="",N("Comment posted","success"),await ao(e),Xe()}catch{N("Failed to post comment","error")}finally{kn.value=!1}}}function Ag(){const e=In.value,t=Ot.value?"Hiding automation posts":"Show automation posts";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Vl.map(n=>i`
          <button
            class="board-sort-btn ${e===n.id?"active":""}"
            onClick=${()=>{In.value=n.id,Lt.value=so,Xe()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Ot.value?"is-active":""}"
          onClick=${()=>{Ot.value=!Ot.value}}
        >
          ${t}
        </button>
        <button
          class="control-btn ghost ${wt.value?"is-active":""}"
          onClick=${()=>{wt.value=!wt.value,Xe()}}
        >
          ${wt.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${Xe} disabled=${Tn.value}>
          ${Tn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Ea(){var s;const e=((s=Vl.find(a=>a.id===In.value))==null?void 0:s.label)??In.value,t=Ql(Cn.value),n=Cn.value.length-t.length;return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${t.length}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Sort</span>
        <strong>${e}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise filter</span>
        <strong>${Ot.value?`automation ${n} hidden`:"full feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${wt.value?"Auto reports hidden":"Full memory feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${vi.value?i`<${W} timestamp=${vi.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Cg({post:e}){const t=async(n,s)=>{s.stopPropagation();try{await $r(e.id,n),Xe()}catch{N("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>bc(e.id)}>
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
                ${Fo(e)?i`<span class="board-meta-chip">Updated</span>`:null}
                ${e.hearth?i`<span class="board-meta-chip">${e.hearth}</span>`:null}
                ${e.visibility?i`<span class="board-meta-chip">${e.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>By ${e.author}</span>
            <span><${W} timestamp=${e.created_at} /></span>
            ${Fo(e)?i`<span>Updated <${W} timestamp=${e.updated_at} /></span>`:null}
            <span>${e.comment_count} comments</span>
            <span>${e.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${kg(e.content)}</div>
      </div>
    </div>
  `}function Ig({comments:e}){return e.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${e.map(t=>i`
        <div key=${t.id} class="board-comment">
          <span class="comment-author">${t.author}</span>
          <span class="comment-time"><${W} timestamp=${t.created_at} /></span>
          <div class="comment-text">${t.content}</div>
        </div>
      `)}
    </div>
  `}function Tg({postId:e}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${bn.value}
        onInput=${t=>{bn.value=t.target.value}}
        onKeyDown=${t=>{t.key==="Enter"&&Ko(e)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${kn.value}
      />
      <button
        onClick=${()=>Ko(e)}
        disabled=${kn.value||bn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${kn.value?"...":"Post"}
      </button>
    </div>
  `}function Rg({post:e}){bt.value!==e.id&&!nn.value&&ao(e.id);const t=async n=>{try{await $r(e.id,n),Xe()}catch{N("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>ce("memory")}>← Back to Memory</button>
      <${C} title=${e.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${$g} text=${e.content} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${e.author}</span>
            <${W} timestamp=${e.created_at} />
            <span>${e.votes??0} votes</span>
          </div>
          ${e.hearth||e.visibility||e.expires_at?i`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${e.hearth?i`<span class="board-meta-chip">${e.hearth}</span>`:null}
                  ${e.visibility?i`<span class="board-meta-chip">${e.visibility}</span>`:null}
                  ${e.expires_at?i`<span class="board-meta-chip">expires <${W} timestamp=${e.expires_at} /></span>`:null}
                </div>
              `:null}
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>t("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>t("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${C} title="Comments" semanticId="memory.feed">
        ${nn.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${Ig} comments=${Ns.value} />`}
        <${Tg} postId=${e.id} />
      <//>
    </div>
  `}function Pg(){const e=Ql(Cn.value),t=O.value.params.post??null,n=t?e.find(s=>s.id===t)??(bt.value===t?Ls.value:null):null;return t&&!n&&bt.value!==t&&!nn.value&&ao(t),t?n?i`
          <${he} surfaceId="memory" />
          <${Ea} />
          <${Rg} post=${n} />
        `:i`
          <div>
            <${he} surfaceId="memory" />
            <${Ea} />
            <button class="back-btn" onClick=${()=>ce("memory")}>← Back to Memory</button>
            ${nn.value?i`<div class="loading-indicator">Loading post...</div>`:i`<div class="empty-state">Post not found</div>`}
          </div>
        `:i`
    <div>
      <${he} surfaceId="memory" />
      <${Ea} />
      <${Ag} />
      ${Tn.value?i`<div class="loading-indicator">Loading memory feed...</div>`:e.length===0?i`<div class="empty-state">No posts in durable memory right now</div>`:i`
              <${C} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${e.slice(0,Lt.value).map(s=>i`<${Cg} key=${s.id} post=${s} />`)}
                </div>
                ${e.length>Lt.value?i`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{Lt.value=Lt.value+so}}
                    >
                      Show more (${e.length-Lt.value} remaining)
                    </button>
                  </div>
                `:null}
              <//>
            `}
    </div>
  `}function Lg({ratio:e,size:t=40,stroke:n=4}){if(e==null)return null;const s=(t-n)/2,a=t/2,o=2*Math.PI*s,l=o*((100-e*100)/100);let c="mitosis-safe";return e>=.8?c="mitosis-critical":e>=.5&&(c="mitosis-warn"),i`
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
  `}const gt=f(null),Ee=f(null),De=f(null);function Sa(e){return e==="bad"||e==="critical"||e==="offline"?"bad":e==="warn"||e==="paused"||e==="blocked"||e==="interrupted"?"warn":"ok"}function Ng(e){return typeof e!="number"||Number.isNaN(e)?"—":`${Math.round(e*100)}%`}function wg(e){return e?rt.value.find(t=>t.name===e||t.agent_name===e)??null:null}function zg(e){switch(e){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function Mg(e){switch(e){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function Uo(e){if(!e)return;const t=gp({targetType:e.target_type,targetId:e.target_id,focusKind:e.focus_kind,operationId:e.operation_id??null,commandSurface:e.command_surface??null,sourceLabel:"Execution 진단",summary:e.label});Qr(t),ce(e.surface,e.surface==="intervene"?Yr(t):Zr(t))}function Rt({label:e,value:t,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${e}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${t}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function io({intervene:e,command:t}){return i`
    <div class="control-row">
      ${e?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),Uo(e)}}
            >
              ${e.label}
            </button>
          `:null}
      ${t?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),Uo(t)}}
            >
              ${t.label}
            </button>
          `:null}
    </div>
  `}function jg({item:e,selected:t}){return i`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{gt.value=t?null:e.id,Ee.value=null,De.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.kind==="session"?e.target_id:e.linked_session_id??e.target_id}</div>
          <div class="mission-card-title">${e.summary}</div>
        </div>
        <span class="command-chip ${Sa(e.severity)}">${e.status??e.severity}</span>
      </div>
      <div class="mission-card-meta">
        <span>${e.kind}</span>
        ${e.linked_operation_id?i`<span>linked op · ${e.linked_operation_id}</span>`:null}
        ${e.last_seen_at?i`<span><${W} timestamp=${e.last_seen_at} /></span>`:null}
      </div>
      <${io} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function Eg({brief:e,selected:t}){return i`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.session-card"
      onClick=${()=>{Ee.value=t?null:e.session_id,De.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          <div class="mission-card-title">${e.goal}</div>
        </div>
        <span class="command-chip ${Sa(e.health??e.status)}">${e.status??"unknown"}</span>
      </div>
      <div class="mission-card-meta">
        <span>health · ${e.health??"ok"}</span>
        ${e.linked_operation_id?i`<span>op · ${e.linked_operation_id}</span>`:null}
        ${e.last_activity_at?i`<span><${W} timestamp=${e.last_activity_at} /></span>`:null}
      </div>
      ${e.runtime_blocker?i`<div class="mission-card-detail">${e.runtime_blocker}</div>`:e.last_activity_summary?i`<div class="mission-card-detail">${e.last_activity_summary}</div>`:null}
      ${e.worker_gap_summary?i`<div class="monitor-footnote">${e.worker_gap_summary}</div>`:null}
      <${io} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function Dg({brief:e,selected:t}){return i`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.operation-card"
      onClick=${()=>{De.value=t?null:e.operation_id,Ee.value=e.linked_session_id??null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.operation_id}${e.assigned_unit_label?` · ${e.assigned_unit_label}`:""}</div>
          <div class="mission-card-title">${e.objective}</div>
        </div>
        <span class="command-chip ${Sa(e.blocker_summary?"warn":e.status)}">${e.status??"unknown"}</span>
      </div>
      <div class="mission-card-meta">
        ${e.stage?i`<span>stage · ${e.stage}</span>`:null}
        ${e.linked_session_id?i`<span>session · ${e.linked_session_id}</span>`:null}
        ${e.updated_at?i`<span><${W} timestamp=${e.updated_at} /></span>`:null}
      </div>
      ${e.blocker_summary?i`<div class="mission-card-detail">${e.blocker_summary}</div>`:null}
      ${e.next_tool?i`<div class="monitor-footnote">next tool · ${e.next_tool}</div>`:null}
      <${io} command=${e.command_handoff} />
    </button>
  `}function Bo({row:e,testId:t}){return i`
    <button class="monitor-row ${e.tone} state-${e.state}" data-testid=${t} onClick=${()=>ba(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.korean_name?i`<span class="monitor-sub">${e.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${e.note}</div>
        </div>
        <${lt} status=${e.status??"unknown"} />
        <span class="monitor-pill ${e.tone} state-${e.state}">${zg(e.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_signal_at?i`<span>신호 <${W} timestamp=${e.last_signal_at} /></span>`:i`<span>최근 신호 없음</span>`}
        <span>${(e.active_task_count??0)>0?`활성 작업 ${e.active_task_count}개`:"활성 작업 없음"}</span>
        ${e.related_session_id?i`<span>session · ${e.related_session_id}</span>`:null}
        ${e.related_operation_id?i`<span>op · ${e.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.recent_output_preview&&e.recent_output_preview!==e.focus?i`<div class="monitor-footnote">최근 상세: ${e.recent_output_preview}</div>`:null}
    </button>
  `}function Og({row:e}){const t=()=>{const n=wg(e.name);n&&_l(n)};return i`
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
        <${Lg} ratio=${e.context_ratio??0} size=${34} stroke=${4} />
        <${lt} status=${e.status??"unknown"} />
        <span class="monitor-pill ${e.tone}">${Mg(e.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_signal_at?i`<span>최근 활동 <${W} timestamp=${e.last_signal_at} /></span>`:i`<span>최근 활동 없음</span>`}
        ${e.related_session_id?i`<span>session · ${e.related_session_id}</span>`:null}
        ${e.continuity?i`<span>${e.continuity}</span>`:null}
        ${e.lifecycle?i`<span>라이프사이클 ${e.lifecycle}</span>`:null}
        <span>컨텍스트 ${Ng(e.context_ratio)}</span>
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.skill_reason?i`<div class="monitor-footnote">연속성 이유: ${e.skill_reason}</div>`:null}
    </button>
  `}function qg(){const e=xr.value,t=Sr.value,n=Ar.value,s=Cr.value,a=Ir.value,o=Tr.value,l=Rr.value;gt.value&&!t.some($=>$.id===gt.value)&&(gt.value=null),Ee.value&&!n.some($=>$.session_id===Ee.value)&&(Ee.value=null),De.value&&!s.some($=>$.operation_id===De.value)&&(De.value=null);const c=gt.value?t.find($=>$.id===gt.value)??null:null,p=Ee.value?Ee.value:c?c.kind==="session"?c.target_id:c.linked_session_id??null:null,u=De.value?De.value:c?c.kind==="operation"?c.target_id:c.linked_operation_id??null:null,_=p?n.filter($=>$.session_id===p):u?n.filter($=>$.linked_operation_id===u):n,g=u?s.filter($=>$.operation_id===u):p?s.filter($=>{var A;return $.linked_session_id===p||$.operation_id===((A=_[0])==null?void 0:A.linked_operation_id)}):s,v=p||u?a.filter($=>(p?$.related_session_id===p:!1)||(u?$.related_operation_id===u:!1)):a,y=p?o.filter($=>$.related_session_id===p||$.tone!=="ok"):o,S=p||u?l.filter($=>(p?$.related_session_id===p:!1)||(u?$.related_operation_id===u:!1)||$.tone!=="ok"):l;return i`
    <div class="agents-monitor">
      <${he} surfaceId="execution" />
      <div class="stats-grid">
        <${Rt} label="활성 세션" value=${(e==null?void 0:e.active_sessions)??n.length} color="#4ade80" caption="실행 관점의 session" />
        <${Rt} label="막힌 세션" value=${(e==null?void 0:e.blocked_sessions)??n.filter($=>Sa($.health??$.status)!=="ok").length} color="#fbbf24" caption="개입 후보 session" />
        <${Rt} label="활성 작전" value=${(e==null?void 0:e.active_operations)??s.length} color="#22d3ee" caption="command-plane operation" />
        <${Rt} label="막힌 작전" value=${(e==null?void 0:e.blocked_operations)??s.filter($=>$.blocker_summary).length} color="#fb7185" caption="원인 분석이 필요한 작전" />
        <${Rt} label="worker 경고" value=${(e==null?void 0:e.worker_alerts)??a.filter($=>$.tone!=="ok").length} color="#fb7185" caption="supporting worker pressure" />
        <${Rt} label="연속성 경고" value=${(e==null?void 0:e.continuity_alerts)??o.filter($=>$.tone!=="ok").length} color="#fb7185" caption="keeper continuity pressure" />
      </div>

      <${C}
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
          ${t.length===0?i`<div class="empty-state">지금은 막힌 실행이 없습니다</div>`:t.map($=>i`<${jg} key=${$.id} item=${$} selected=${gt.value===$.id} />`)}
        </div>
      <//>

      <div class="agents-workbench">
        <${C}
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
            ${_.length===0?i`<div class="empty-state">선택된 실행과 연결된 session이 없습니다</div>`:_.map($=>i`<${Eg} key=${$.session_id} brief=${$} selected=${Ee.value===$.session_id} />`)}
          </div>
        <//>

        <${C}
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
            ${g.length===0?i`<div class="empty-state">선택된 실행과 연결된 operation이 없습니다</div>`:g.map($=>i`<${Dg} key=${$.operation_id} brief=${$} selected=${De.value===$.operation_id} />`)}
          </div>
        <//>

        <${C}
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
            ${v.length===0?i`<div class="empty-state">연결된 worker가 없습니다</div>`:v.map($=>i`<${Bo} key=${$.name} row=${$} testId="execution.worker-card" />`)}
          </div>
        <//>

        <${C}
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
            ${y.length===0?i`<div class="empty-state">지금은 연속성 경고가 없습니다</div>`:y.map($=>i`<${Og} key=${$.name} row=${$} />`)}
          </div>
        <//>

        <${C}
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
            ${S.length===0?i`<div class="empty-state">지금은 오프라인 worker가 없습니다</div>`:S.map($=>i`<${Bo} key=${$.name} row=${$} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const la=f("all"),ca=f("all"),Si=f(new Set);function Fg(e){const t=new Set(Si.value);t.has(e)?t.delete(e):t.add(e),Si.value=t}const Yl=xe(()=>{let e=Kt.value;return la.value!=="all"&&(e=e.filter(t=>t.horizon===la.value)),ca.value!=="all"&&(e=e.filter(t=>t.status===ca.value)),e}),Kg=xe(()=>{const e={short:[],mid:[],long:[]};for(const t of Yl.value){const n=e[t.horizon];n&&n.push(t)}return e}),Ug=xe(()=>{const e=Array.from(Lr.value.values());return e.sort((t,n)=>t.status==="running"&&n.status!=="running"?-1:n.status==="running"&&t.status!=="running"?1:t.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&t.status!=="interrupted"?1:n.elapsed_seconds-t.elapsed_seconds),e});function Bg(e){return"★".repeat(Math.min(e,5))+"☆".repeat(Math.max(0,5-e))}function oo(e){switch(e){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return e}}function ws(e){switch(e){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function Hg(e){return e<60?`${Math.round(e)}s`:e<3600?`${Math.floor(e/60)}m ${Math.round(e%60)}s`:`${Math.floor(e/3600)}h ${Math.floor(e%3600/60)}m`}function Ho(e){return e.toFixed(4)}function Wo(e){const t=e.current_metric-e.baseline_metric;return`${t>=0?"+":""}${t.toFixed(4)}`}function Wg(e){switch(e){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function Go(e,t){return(e.priority??4)-(t.priority??4)}function Gg(e,t){const n=e.updated_at??e.created_at??"";return(t.updated_at??t.created_at??"").localeCompare(n)}function Jg(e,t){return e.length<=t?e:e.slice(0,t)+"..."}function Vg({goal:e}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ws(e.horizon)}">
            ${oo(e.horizon)}
          </span>
          <span class="goal-title">${e.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${e.priority}">${Bg(e.priority)}</span>
          ${e.metric?i`<span class="goal-metric">${e.metric}${e.target_value?` → ${e.target_value}`:""}</span>`:null}
          ${e.due_date?i`<span class="goal-due">Due: <${W} timestamp=${e.due_date} /></span>`:null}
        </div>
        ${e.last_review_note?i`
          <div class="goal-review-note">${e.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${lt} status=${e.status} />
        <div class="goal-updated">
          <${W} timestamp=${e.updated_at} />
        </div>
      </div>
    </div>
  `}function Da({horizon:e,items:t}){if(t.length===0)return null;const n=[...t].sort((s,a)=>a.priority-s.priority);return i`
    <${C} title="${oo(e)} Goals (${t.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${Vg} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function Qg(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(e=>i`
          <button
            class="goal-filter-btn ${la.value===e?"active":""}"
            onClick=${()=>{la.value=e}}
          >
            ${e==="all"?"All":oo(e)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(e=>i`
          <button
            class="goal-filter-btn ${ca.value===e?"active":""}"
            onClick=${()=>{ca.value=e}}
          >
            ${e==="all"?"All":e.charAt(0).toUpperCase()+e.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function Yg(){const e=Kt.value,t=e.filter(a=>a.status==="active").length,n=e.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of e)a.horizon in s&&s[a.horizon]++;return i`
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
        <div class="goal-summary-value" style="color:${ws("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ws("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ws("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function Xg({loop:e}){const t=e.history[0],n=e.latest_tool_names&&e.latest_tool_names.length>0?`${e.latest_tool_call_count??e.latest_tool_names.length} tool${(e.latest_tool_call_count??e.latest_tool_names.length)===1?"":"s"}: ${e.latest_tool_names.join(", ")}`:"No evidence yet";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${e.profile}</div>
            <div class="planning-loop-sub">${e.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${lt} status=${e.status} />
            <span class="pill">${e.current_iteration}${e.max_iterations>0?`/${e.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Ho(e.baseline_metric)}</span>
          <span>Current ${Ho(e.current_metric)}</span>
          <span class=${Wo(e).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Wo(e)}
          </span>
          <span>Elapsed ${Hg(e.elapsed_seconds)}</span>
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
  `}function Oa({task:e}){const t=e.priority??4,n=t<=1?"p1":t===2?"p2":t===3?"p3":"p4",s=Si.value.has(e.id),a=!!e.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${Wg(t)}</span>
        <div class="kanban-card-title">${e.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>Fg(e.id)}
        >
          ${s?e.description:Jg(e.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${e.created_at?i`<${W} timestamp=${e.created_at} />`:i`<span>-</span>`}
        ${e.assignee?i`<span class="kanban-assignee">${e.assignee}</span>`:null}
      </div>
    </div>
  `}function Zg(){const{todo:e,inProgress:t,done:n}=wr.value,s=[...e].sort(Go),a=[...t].sort(Go),o=[...n].sort(Gg);return i`
    <${C} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:s.map(l=>i`<${Oa} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:a.map(l=>i`<${Oa} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:o.slice(0,20).map(l=>i`<${Oa} key=${l.id} task=${l} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${o.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function ef(){const{todo:e,inProgress:t,done:n}=wr.value,s=e.length+t.length+n.length,a=[...e,...t].filter(_=>(_.priority??4)<=2).length,o=Kg.value,l=Ug.value,c=Kt.value.length>0,p=l.length>0,u=ji.value;return i`
    <div>
      <${he} surfaceId="planning" />

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
          onClick=${()=>{Oi(),qr()}}
          disabled=${_n.value||gn.value}
        >
          ${_n.value||gn.value?"Refreshing...":"Refresh planning data"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${Zg} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          Goal Pipeline
          <span class="monitor-pill">${Kt.value.length}</span>
        </summary>
        <div>
          ${c?i`
            <${Yg} />
            <${Qg} />
            ${_n.value&&Kt.value.length===0?i`<div class="loading-indicator">Loading goals...</div>`:Yl.value.length===0?i`<div class="empty-state">No goals match the current filters</div>`:i`
                    <${Da} horizon="short" items=${o.short??[]} />
                    <${Da} horizon="mid" items=${o.mid??[]} />
                    <${Da} horizon="long" items=${o.long??[]} />
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
          ${gn.value&&l.length===0?i`<div class="loading-indicator">Loading MDAL loops...</div>`:l.length===0&&(u==="error"||Ut.value)?i`<div class="empty-state">MDAL snapshot could not be loaded${Ut.value?`: ${Ut.value}`:""}. Check backend health.</div>`:l.length===0?i`<div class="empty-state">No active loops. Use <code>masc_mdal_start</code> to start a loop.</div>`:i`
                  <div class="planning-loop-list">
                    ${l.map(_=>i`<${Xg} key=${_.loop_id} loop=${_} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const da=f(!1),xn=f(!1),qt=f(!1),it=f(""),Sn=f(""),Ai=f("open"),Ne=f(null),Un=f(null),ua=f(null),pa=f(null),Ci=f(!1);function Bn(e){return`${e.kind}:${e.id}`}function ro(){var n;const e=Un.value,t=((n=Ne.value)==null?void 0:n.items)??[];return e?t.find(s=>Bn(s)===e)??null:null}function tf(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");return(t==null?void 0:t.trim())||"dashboard"}function nf(e){const t=e.trim().toLowerCase();return t==="open"||t==="pending"}function Xl(e){return!!(e.judgment_summary&&e.judgment_summary.trim())}function Zl(e){switch(Ai.value){case"needs_quorum":return e.filter(t=>t.kind==="consensus"&&(t.votes??0)<(t.quorum??0));case"ready":return e.filter(t=>{var n;return(n=t.guardrail_state)==null?void 0:n.ready_to_execute});case"needs_approval":return e.filter(t=>{var n,s;return((n=t.guardrail_state)==null?void 0:n.requires_human_gate)||!!((s=t.guardrail_state)!=null&&s.pending_confirm)});case"judge_offline":return e.filter(t=>!Xl(t));case"open":default:return e.filter(t=>nf(t.status))}}function sf(e){if(e==null)return"none";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Aa(e){const t=(e||"").toLowerCase();return t.includes("reject")||t.includes("deny")||t.includes("closed")||t.includes("cancel")?"negative":t.includes("approve")||t.includes("support")||t.includes("open")||t.includes("ready")?"positive":"neutral"}function af(e){return typeof e!="number"||Number.isNaN(e)?"n/a":`${Math.round(e*100)}%`}function pn(e){return"resolved_tool"in e||"payload_preview"in e||"reason"in e}async function ec(e){if(ua.value=null,pa.value=null,!!e){Ci.value=!0,it.value="";try{e.kind==="debate"?ua.value=await Od(e.id):pa.value=await qd(e.id)}catch(t){it.value=t instanceof Error?t.message:"Failed to load governance detail"}finally{Ci.value=!1}}}async function of(e){Un.value=Bn(e),await ec(e)}async function sn(){var e;da.value=!0,it.value="";try{const t=await Uc();Ne.value=t;const n=Zl(t.items??[]),s=Un.value,a=n.find(o=>Bn(o)===s)??n[0]??((e=t.items)==null?void 0:e[0])??null;Un.value=a?Bn(a):null,await ec(a)}catch(t){it.value=t instanceof Error?t.message:"Failed to load governance state"}finally{da.value=!1}}ju(sn);async function Jo(){const e=Sn.value.trim();if(e){xn.value=!0;try{const t=await Dd(e);Sn.value="",N(t!=null&&t.id?`Debate started: ${t.id}`:"Debate started","success"),await sn()}catch(t){const n=t instanceof Error?t.message:"Failed to start debate";it.value=n,N(n,"error")}finally{xn.value=!1}}}async function Vo(e){var o,l;const t=ro(),n=(o=t==null?void 0:t.guardrail_state)==null?void 0:o.pending_confirm,s=n==null?void 0:n.confirm_token;if(!s)return;const a=((l=n==null?void 0:n.actor)==null?void 0:l.trim())||tf();qt.value=!0;try{await pr(a,s,e),N(e==="confirm"?"Action approved":"Action denied","success"),await sn()}catch(c){const p=c instanceof Error?c.message:"Failed to update pending action";it.value=p,N(p,"error")}finally{qt.value=!1}}function rf(){var n,s,a,o,l,c;const e=(n=Ne.value)==null?void 0:n.summary,t=(s=Ne.value)==null?void 0:s.judge;return i`
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
  `}function lf(){return i`
    <${C} title="Governance Console" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Sn.value}
            onInput=${e=>{Sn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&Jo()}}
            disabled=${xn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Jo}
            disabled=${xn.value||Sn.value.trim()===""}
          >
            ${xn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${sn} disabled=${da.value}>
            ${da.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        <div class="governance-filter-row">
          ${[["open","Open"],["needs_quorum","Needs Quorum"],["ready","Ready"],["needs_approval","Needs Approval"],["judge_offline","Judge Offline"]].map(([e,t])=>i`
            <button
              class="control-btn ${Ai.value===e?"is-active":"ghost"}"
              onClick=${async()=>{Ai.value=e,await sn()}}
            >
              ${t}
            </button>
          `)}
        </div>
        ${it.value?i`<div class="council-error">${it.value}</div>`:null}
      </div>
    <//>
  `}function cf(){var t;const e=Zl(((t=Ne.value)==null?void 0:t.items)??[]);return i`
    <${C} title="Decision Inbox" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${e.length===0?i`
              <div class="empty-state">
                Governance is quiet. No debates or consensus sessions match the current filter.
              </div>
            `:e.map(n=>{var a,o;const s=Un.value===Bn(n);return i`
                <button
                  class="council-row governance-decision-row ${s?"selected":""}"
                  onClick=${()=>of(n)}
                >
                  <div class="council-row-main">
                    <div class="governance-row-head">
                      <span class="governance-kind">${n.kind}</span>
                      <span class="council-topic">${n.topic}</span>
                    </div>
                    <div class="council-sub">
                      <span>${n.truth_summary||"No fact summary"}</span>
                      ${n.last_activity_at?i`<span><${W} timestamp=${n.last_activity_at} /></span>`:null}
                    </div>
                    <div class="governance-chip-row">
                      ${(a=n.guardrail_state)!=null&&a.requires_human_gate?i`<span class="governance-chip warn">needs approval</span>`:null}
                      ${(o=n.guardrail_state)!=null&&o.ready_to_execute?i`<span class="governance-chip ok">ready</span>`:null}
                      ${n.kind==="consensus"&&(n.votes??0)<(n.quorum??0)?i`<span class="governance-chip warn">quorum debt</span>`:null}
                      ${Xl(n)?null:i`<span class="governance-chip dim">judge offline</span>`}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${Aa(n.status)}">${n.status}</span>
                    ${n.kind==="consensus"?i`<span class="governance-vote-meter">${n.votes??0}/${n.quorum??0}</span>`:i`<span class="governance-vote-meter">${n.evidence_refs.length} refs</span>`}
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function df({argument:e}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${Aa(e.position)}">${e.position}</span>
        <strong>${e.agent}</strong>
        ${e.created_at?i`<span><${W} timestamp=${e.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.content}</div>
      <div class="governance-chip-row">
        ${e.evidence.map(t=>i`<span class="governance-chip">${t}</span>`)}
        ${e.reply_to!=null?i`<span class="governance-chip">reply #${e.reply_to}</span>`:null}
        ${e.mentions.map(t=>i`<span class="governance-chip">@${t}</span>`)}
        ${e.archetype?i`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function uf({vote:e}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${Aa(e.decision)}">${e.decision}</span>
        <strong>${e.agent}</strong>
        ${e.timestamp?i`<span><${W} timestamp=${e.timestamp} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.reason||"No reason recorded."}</div>
      <div class="governance-chip-row">
        ${e.weight!=null?i`<span class="governance-chip">weight ${e.weight}</span>`:null}
        ${e.archetype?i`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function pf(){const e=ro(),t=ua.value,n=pa.value;return i`
    <${C}
      title=${e?`${e.kind==="debate"?"Debate":"Consensus"} Detail`:"Decision Detail"}
      class="section"
      semanticId="governance.detail"
    >
      ${Ci.value?i`<div class="loading-indicator">Loading governance detail...</div>`:e?e.kind==="debate"&&t?i`
                <div class="governance-detail-head">
                  <div>
                    <h3>${t.debate.topic}</h3>
                    <div class="council-sub">
                      <span>${t.debate.id}</span>
                      <span>${t.debate.status}</span>
                      ${t.debate.created_at?i`<span><${W} timestamp=${t.debate.created_at} /></span>`:null}
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
                  ${t.arguments.length===0?i`<div class="empty-state">No arguments recorded yet.</div>`:t.arguments.map(s=>i`<${df} key=${s.index} argument=${s} />`)}
                </div>
              `:e.kind==="consensus"&&n?i`
                  <div class="governance-detail-head">
                    <div>
                      <h3>${n.session.topic}</h3>
                      <div class="council-sub">
                        <span>${n.session.id}</span>
                        <span>${n.session.state}</span>
                        <span>initiator ${n.session.initiator}</span>
                        ${n.session.created_at?i`<span><${W} timestamp=${n.session.created_at} /></span>`:null}
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
                    ${n.votes.length===0?i`<div class="empty-state">No votes recorded yet.</div>`:n.votes.map(s=>i`<${uf} key=${s.agent+s.timestamp} vote=${s} />`)}
                  </div>
                `:i`<div class="empty-state">Detail is unavailable for this decision.</div>`:i`<div class="empty-state">Select a decision item to inspect truth and judgment.</div>`}
    <//>
  `}function Qo({title:e,route:t}){if(!t)return null;const n=pn(t)?t.resolved_tool:t.delegated_tool,s=pn(t)?t.target_type:null,a=pn(t)?t.target_id:null,o=pn(t)?t.reason:null,l=pn(t)?t.payload_preview:null;return i`
    <div class="governance-side-block">
      <h4>${e}</h4>
      <div class="council-sub">
        ${n?i`<span>tool ${n}</span>`:null}
        ${"action_type"in t&&t.action_type?i`<span>action ${t.action_type}</span>`:null}
        ${"confirmation_state"in t&&t.confirmation_state?i`<span>${t.confirmation_state}</span>`:null}
        ${"created_at"in t&&t.created_at?i`<span><${W} timestamp=${t.created_at} /></span>`:null}
      </div>
      ${s?i`<div class="governance-side-line">target ${s}${a?`:${a}`:""}</div>`:null}
      ${o?i`<div class="governance-side-line">${o}</div>`:null}
      ${l?i`<pre class="council-detail governance-preview">${sf(l)}</pre>`:null}
    </div>
  `}function mf(){var c,p,u;const e=ro(),t=ua.value,n=pa.value,s=(t==null?void 0:t.context)??(n==null?void 0:n.context)??(e==null?void 0:e.context),a=(t==null?void 0:t.judgment)??(n==null?void 0:n.judgment),o=e==null?void 0:e.guardrail_state,l=(c=Ne.value)==null?void 0:c.judge;return i`
    <div class="governance-side-column">
      <${C} title="Why / Guardrail" class="section" semanticId="governance.guardrail">
        ${e?i`
              <div class="governance-side-block">
                <h4>Judge</h4>
                <div class="council-sub">
                  <span>${l!=null&&l.judge_online?"online":"offline"}</span>
                  ${l!=null&&l.model_used?i`<span>${l.model_used}</span>`:null}
                  ${l!=null&&l.generated_at?i`<span><${W} timestamp=${l.generated_at} /></span>`:null}
                </div>
                ${e.judgment_summary?i`<div class="governance-summary-callout">${e.judgment_summary}</div>`:i`<div class="governance-side-line">No current LLM judgment. Showing truth layer only.</div>`}
                <div class="council-sub">
                  <span>confidence ${af(e.confidence)}</span>
                  ${a!=null&&a.keeper_name?i`<span>${a.keeper_name}</span>`:null}
                </div>
              </div>

              <${Qo} title="Recommended Route" route=${e.recommended_action} />
              <${Qo} title="Executed Route" route=${e.executed_route} />

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
                          onClick=${()=>Vo("confirm")}
                          disabled=${qt.value}
                        >
                          ${qt.value?"Working...":"Approve"}
                        </button>
                        <button
                          class="control-btn ghost"
                          onClick=${()=>Vo("deny")}
                          disabled=${qt.value}
                        >
                          ${qt.value?"Working...":"Deny"}
                        </button>
                      </div>
                    `:i`<div class="governance-side-line">No pending human gate for this decision.</div>`}
              </div>
            `:i`<div class="empty-state">Select a decision to inspect judgment and route.</div>`}
      <//>

      <${C} title="Context" class="section" semanticId="governance.context">
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
                        ${e.related_agents.map(_=>i`<span class="governance-chip dim">${_}</span>`)}
                      </div>
                    `:i`<div class="governance-side-line">No explicit linked context recorded.</div>`}
                ${e.evidence_refs.length>0?i`
                      <div class="governance-side-line">evidence refs</div>
                      <div class="governance-chip-row">
                        ${e.evidence_refs.map(_=>i`<span class="governance-chip">${_}</span>`)}
                      </div>
                    `:null}
              </div>
          `:i`<div class="empty-state">No context selected.</div>`}
      <//>

      <${C} title="Recent Activity" class="section" semanticId="governance.activity">
        <div class="governance-activity-list">
          ${(((p=Ne.value)==null?void 0:p.activity)??[]).slice(0,8).map(_=>i`
            <div class="governance-activity-row">
              <div class="governance-ledger-head">
                <span class="governance-badge ${Aa(_.kind)}">${_.kind}</span>
                ${_.actor?i`<strong>${_.actor}</strong>`:null}
                ${_.created_at?i`<span><${W} timestamp=${_.created_at} /></span>`:null}
              </div>
              <div class="governance-ledger-body">${_.summary||_.topic||"Activity recorded."}</div>
            </div>
          `)}
          ${(((u=Ne.value)==null?void 0:u.activity)??[]).length===0?i`<div class="empty-state">No governance activity recorded.</div>`:null}
        </div>
      <//>
    </div>
  `}function vf(){return ee(()=>{sn()},[]),i`
    <div>
      <${he} surfaceId="governance" />
      <${rf} />
      <${lf} />
      <div class="governance-layout">
        <${cf} />
        <${pf} />
        <${mf} />
      </div>
    </div>
  `}const Nt=f(""),qa=f("ability_check"),Fa=f("10"),Ka=f("12"),gs=f(""),fs=f("idle"),Ge=f(""),$s=f("keeper-late"),Ua=f("player"),Ba=f(""),be=f("idle"),Ha=f(null),hs=f(""),Wa=f(""),Ga=f("player"),Ja=f(""),Va=f(""),Qa=f(""),An=f("20"),Ya=f("20"),Xa=f(""),ys=f("idle"),Ii=f(null),tc=f("overview"),Za=f("all"),ei=f("all"),ti=f("all"),_f=12e4,Ca=f(null),Yo=f(Date.now());function gf(e,t){const n=t>0?e/t*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function ff(e,t){return t>0?Math.round(e/t*100):0}const $f={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},hf={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function bs(e){const t=e.trim();return t?t.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):e}function yf(e){const t=e.trim().toLowerCase();return $f[t]??"행동 선택 가중치에 영향을 주는 성향입니다."}function bf(e){const t=e.trim().toLowerCase();return hf[t]??"상황에 따라 선택되는 전술 액션입니다."}function ge(e,t,n=""){const s=e[t];return typeof s=="string"?s:n}function Te(e,t,n=0){const s=e[t];return typeof s=="number"&&Number.isFinite(s)?s:n}function Hn(e,t,n=!1){const s=e[t];return typeof s=="boolean"?s:n}const kf=new Set(["str","dex","con","int","wis","cha"]);function xf(e){const t=e.trim();if(!t)return{};let n;try{n=JSON.parse(t)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!m(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const l=a.trim();if(l){if(typeof o=="number"&&Number.isFinite(o)){s[l]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const c=Number.parseFloat(o.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function Sf(e){const t=Number.parseInt(e.trim(),10);if(!Number.isFinite(t))return;const n=Math.max(1,t),s=Number.parseInt(An.value.trim(),10);Number.isFinite(s)&&s>n&&(An.value=String(n))}function Ti(e){const n=(e.actor_name??e.actor??e.actor_id??"system").trim();return n===""?"system":n}function Af(e){var n;return(((n=e.timestamp)==null?void 0:n.trim())??"")||"-"}function Cf(e){tc.value=e}function nc(e){const t=Ca.value;return t==null||t<=e}function If(e){const t=Ca.value;return t==null||t<=e?0:Math.max(0,Math.ceil((t-e)/1e3))}function ma(){Ca.value=null}function sc(e){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(e)}function Tf(e,t){sc(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${e||"-"}`,`PHASE: ${t||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Ca.value=Date.now()+_f,N("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function zs(e){return nc(e)?(N("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Ri(e,t,n){return sc([`[위험 액션 확인] ${e}`,`ROOM: ${t||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Rf({hp:e,max:t}){const n=ff(e,t),s=gf(e,t);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function Pf({stats:e}){const t=[{label:"STR",value:e.strength},{label:"DEX",value:e.dexterity},{label:"CON",value:e.constitution},{label:"INT",value:e.intelligence},{label:"WIS",value:e.wisdom},{label:"CHA",value:e.charisma}];return i`
    <div class="trpg-actor-stats">
      ${t.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Lf({keeper:e,role:t}){if(!e)return null;const n=t==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${e}
    </span>
  `}function ac({actor:e}){var p,u,_,g;const t=(p=e.archetype)==null?void 0:p.trim(),n=(u=e.persona)==null?void 0:u.trim(),s=(_=e.portrait)==null?void 0:_.trim(),a=(g=e.background)==null?void 0:g.trim(),o=e.traits??[],l=e.skills??[],c=Object.entries(e.stats_raw??{}).filter(([v,y])=>Number.isFinite(y)).filter(([v])=>!kf.has(v.toLowerCase()));return i`
    <div class="trpg-actor">
      ${s?i`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${e.name} portrait`}
              loading="lazy"
              onError=${v=>{const y=v.target;y&&(y.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${e.name}</span>
        <${lt} status=${e.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${e.role}">${e.role}</span>
        <${Lf} keeper=${e.keeper} role=${e.role} />
      </div>
      ${e.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${e.stats.hp}/${e.stats.max_hp}
              ${e.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${e.stats.mp}/${e.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${e.stats.level}</span>
            </div>
            <${Rf} hp=${e.stats.hp} max=${e.stats.max_hp} />
            <${Pf} stats=${e.stats} />
          </div>
        `:null}
      ${t?i`<div class="trpg-actor-meta">Archetype: ${bs(t)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([v,y])=>i`
                <span class="trpg-custom-stat-chip">${bs(v)} ${y}</span>
              `)}
            </div>
          </div>
        `:null}
      ${o.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${o.map(v=>i`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${bs(v)}</span>
                  <span class="trpg-annot-desc">${yf(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${l.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${l.map(v=>i`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${bs(v)}</span>
                  <span class="trpg-annot-desc">${bf(v)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Nf({mapStr:e}){return i`<pre class="trpg-map">${e}</pre>`}function ic({events:e,emptyLabel:t="아직 이벤트가 없습니다."}){return e.length===0?i`<div class="empty-state" style="font-size:13px">${t}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${e.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Af(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Ti(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${W} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function wf({events:e}){const t="__none__",n=Za.value,s=ei.value,a=ti.value,o=Array.from(new Set(e.map(Ti).map(g=>g.trim()).filter(g=>g!==""))).sort((g,v)=>g.localeCompare(v)),l=Array.from(new Set(e.map(g=>(g.type??"").trim()).filter(g=>g!==""))).sort((g,v)=>g.localeCompare(v)),c=e.some(g=>(g.type??"").trim()===""),p=Array.from(new Set(e.map(g=>(g.phase??"").trim()).filter(g=>g!==""))).sort((g,v)=>g.localeCompare(v)),u=e.some(g=>(g.phase??"").trim()===""),_=e.filter(g=>{if(n!=="all"&&Ti(g)!==n)return!1;const v=(g.type??"").trim(),y=(g.phase??"").trim();if(s===t){if(v!=="")return!1}else if(s!=="all"&&v!==s)return!1;if(a===t){if(y!=="")return!1}else if(a!=="all"&&y!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${g=>{Za.value=g.target.value}}>
          <option value="all">all</option>
          ${o.map(g=>i`<option value=${g}>${g}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${g=>{ei.value=g.target.value}}>
          <option value="all">all</option>
          ${c?i`<option value=${t}>(none)</option>`:null}
          ${l.map(g=>i`<option value=${g}>${g}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${g=>{ti.value=g.target.value}}>
          <option value="all">all</option>
          ${u?i`<option value=${t}>(none)</option>`:null}
          ${p.map(g=>i`<option value=${g}>${g}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Za.value="all",ei.value="all",ti.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${_.length} / 전체 ${e.length}
      </span>
    </div>
    <${ic} events=${_.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function zf({outcome:e}){if(!e)return null;const t=o=>{const l=o.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=e.result==="victory"?"승리":e.result==="defeat"?"패배":e.result==="draw"?"무승부":"종료",s=e.result==="victory"?"#34d399":e.result==="defeat"?"#f87171":"#9ca3af",a=[e.reason?`원인: ${t(e.reason)}`:null,e.phase?`페이즈: ${t(e.phase)}`:null,typeof e.turn=="number"?`턴: ${e.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${e.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${t(e.summary)}</div>`:null}
      ${a?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function oc({state:e}){const t=e.history??[];return t.length===0?null:i`
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
  `}function Mf({state:e,nowMs:t}){var u;const n=qe.value||((u=e.session)==null?void 0:u.room)||"",s=fs.value,a=e.party??[];if(!a.find(_=>_.id===Nt.value)&&a.length>0){const _=a[0];_&&(Nt.value=_.id)}const l=async()=>{var g,v;if(!n){N("Room ID가 비어 있습니다.","error");return}if(!zs(t))return;const _=((g=e.current_round)==null?void 0:g.phase)??((v=e.session)==null?void 0:v.status)??"unknown";if(Ri("라운드 실행",n,_)){fs.value="running";try{const y=await Id(n);Ii.value=y,fs.value="ok";const S=m(y.summary)?y.summary:null,$=S?Hn(S,"advanced",!1):!1,A=S?ge(S,"progress_reason",""):"";N($?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${A?`: ${A}`:""}`,$?"success":"warning"),Ze()}catch(y){Ii.value=null,fs.value="error";const S=y instanceof Error?y.message:"라운드 실행에 실패했습니다.";N(S,"error")}finally{ma()}}},c=async()=>{var g,v;if(!n||!zs(t))return;const _=((g=e.current_round)==null?void 0:g.phase)??((v=e.session)==null?void 0:v.status)??"unknown";if(Ri("턴 강제 진행",n,_))try{await Pd(n),N("턴을 다음 단계로 이동했습니다.","success"),Ze()}catch{N("턴 이동에 실패했습니다.","error")}finally{ma()}},p=async()=>{if(!n||!zs(t))return;const _=Nt.value.trim();if(!_){N("먼저 Actor를 선택하세요.","warning");return}const g=Number.parseInt(Fa.value,10),v=Number.parseInt(Ka.value,10);if(Number.isNaN(g)||Number.isNaN(v)){N("stat/dc는 숫자여야 합니다.","warning");return}const y=Number.parseInt(gs.value,10),S=gs.value.trim()===""||Number.isNaN(y)?void 0:y;try{await Rd({roomId:n,actorId:_,action:qa.value.trim()||"ability_check",statValue:g,dc:v,rawD20:S}),N("주사위 판정을 기록했습니다.","success"),Ze()}catch{N("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${_=>{qe.value=_.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Nt.value}
            onChange=${_=>{Nt.value=_.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(_=>i`<option value=${_.id}>${_.name} (${_.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${qa.value}
              onInput=${_=>{qa.value=_.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Fa.value}
              onInput=${_=>{Fa.value=_.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Ka.value}
              onInput=${_=>{Ka.value=_.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${gs.value}
              onInput=${_=>{gs.value=_.target.value}}
              onKeyDown=${_=>{_.key==="Enter"&&p()}}
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
  `}function jf({state:e}){var a;const t=qe.value||((a=e.session)==null?void 0:a.room)||"",n=ys.value,s=async()=>{if(!t){N("Room ID가 비어 있습니다.","warning");return}const o=hs.value.trim(),l=Wa.value.trim();if(!l&&!o){N("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(An.value.trim(),10),p=Number.parseInt(Ya.value.trim(),10),u=Number.isFinite(p)?Math.max(1,p):20,_=Number.isFinite(c)?Math.max(0,Math.min(u,c)):u;let g={};try{g=xf(Xa.value)}catch(v){N(v instanceof Error?v.message:"능력치 JSON 오류","error");return}ys.value="spawning";try{const v=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,y=await Ld(t,{actor_id:o||void 0,name:l||void 0,role:Ga.value,idempotencyKey:v,portrait:Va.value.trim()||void 0,background:Qa.value.trim()||void 0,hp:_,max_hp:u,alive:_>0,stats:Object.keys(g).length>0?g:void 0}),S=typeof y.actor_id=="string"?y.actor_id.trim():"";if(!S)throw new Error("생성 응답에 actor_id가 없습니다.");const $=Ja.value.trim();$&&await Nd(t,S,$),Nt.value=S,Ge.value=S,o||(hs.value=""),ys.value="ok",N(`Actor 생성 완료: ${S}`,"success"),await Ze()}catch(v){ys.value="error",N(v instanceof Error?v.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Wa.value}
            onInput=${o=>{Wa.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ga.value}
            onChange=${o=>{Ga.value=o.target.value}}
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
            value=${Ja.value}
            onInput=${o=>{Ja.value=o.target.value}}
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
              value=${hs.value}
              onInput=${o=>{hs.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Va.value}
              onInput=${o=>{Va.value=o.target.value}}
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
              value=${An.value}
              onInput=${o=>{An.value=o.target.value}}
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
              value=${Ya.value}
              onInput=${o=>{const l=o.target.value;Ya.value=l,Sf(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${Qa.value}
              onInput=${o=>{Qa.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Xa.value}
              onInput=${o=>{Xa.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Ef({state:e,nowMs:t}){var v;const n=qe.value||((v=e.session)==null?void 0:v.room)||"",s=e.join_gate,a=Ha.value,o=m(a)?a:null,l=(e.party??[]).filter(y=>y.role!=="dm"),c=Ge.value.trim(),p=l.some(y=>y.id===c),u=p?c:c?"__manual__":"",_=async()=>{const y=Ge.value.trim(),S=$s.value.trim();if(!n||!y){N("Room/Actor가 필요합니다.","warning");return}be.value="checking";try{const $=await wd(n,y,S||void 0);Ha.value=$,be.value="ok",N("참가 가능 여부를 갱신했습니다.","success")}catch($){be.value="error";const A=$ instanceof Error?$.message:"참가 가능 여부 확인에 실패했습니다.";N(A,"error")}},g=async()=>{var b,I;const y=Ge.value.trim(),S=$s.value.trim(),$=Ba.value.trim();if(!n||!y||!S){N("Room/Actor/Keeper가 필요합니다.","warning");return}if(!zs(t))return;const A=((b=e.current_round)==null?void 0:b.phase)??((I=e.session)==null?void 0:I.status)??"unknown";if(Ri("Mid-Join 승인 요청",n,A)){be.value="requesting";try{const R=await zd({room_id:n,actor_id:y,keeper_name:S,role:Ua.value,...$?{name:$}:{}});Ha.value=R;const T=m(R)?Hn(R,"granted",!1):!1,P=m(R)?ge(R,"reason_code",""):"";T?N("Mid-Join이 승인되었습니다.","success"):N(`Mid-Join이 거절되었습니다${P?`: ${P}`:""}`,"warning"),be.value=T?"ok":"error",Ze()}catch(R){be.value="error";const T=R instanceof Error?R.message:"Mid-Join 요청에 실패했습니다.";N(T,"error")}finally{ma()}}};return i`
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
            value=${u}
            onChange=${y=>{const S=y.target.value;if(S==="__manual__"){(p||!c)&&(Ge.value="");return}Ge.value=S}}
          >
            <option value="">Actor 선택</option>
            ${l.map(y=>i`
              <option value=${y.id}>${y.name} (${y.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${u==="__manual__"?i`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Ge.value}
                onInput=${y=>{Ge.value=y.target.value}}
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
            value=${$s.value}
            onInput=${y=>{$s.value=y.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ua.value}
            onChange=${y=>{Ua.value=y.target.value}}
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
            value=${Ba.value}
            onInput=${y=>{Ba.value=y.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${_} disabled=${be.value==="checking"||be.value==="requesting"}>
              ${be.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${g} disabled=${be.value==="checking"||be.value==="requesting"}>
              ${be.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Hn(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Te(o,"effective_score",0)}/${Te(o,"required_points",0)}</span>
            ${ge(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${ge(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function rc({state:e}){const t=[...e.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return t.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${t.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function lc({state:e}){var n;const t=e.current_round;return t?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${t.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${t.phase}</div>
      ${t.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=t.events[t.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function cc(){const e=Ii.value;if(!e)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const t=e.summary,n=m(t)?t:null,a=(Array.isArray(e.statuses)?e.statuses:[]).filter(m).slice(-8),o=e.canon_check,l=m(o)?o:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(P=>typeof P=="string").slice(0,3):[],p=l&&Array.isArray(l.violations)?l.violations.filter(P=>typeof P=="string").slice(0,3):[],u=n?Hn(n,"advanced",!1):!1,_=n?ge(n,"progress_reason",""):"",g=n?ge(n,"progress_detail",""):"",v=n?Te(n,"player_successes",0):0,y=n?Te(n,"player_required_successes",0):0,S=n?Hn(n,"dm_success",!1):!1,$=n?Te(n,"timeouts",0):0,A=n?Te(n,"unavailable",0):0,b=n?Te(n,"reprompts",0):0,I=n?Te(n,"npc_attacks",0):0,R=n?Te(n,"keeper_timeout_sec",0):0,T=n?Te(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${u?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${u?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${e.turn_before??0} → ${e.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${S?"DM ok":"DM stalled"} / players ${v}/${y}
          </span>
        </div>
        ${_?i`<div style="margin-top:4px; font-size:12px;">${_}</div>`:null}
        ${g?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${g}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${$}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${b}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${I}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${R||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${T}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(P=>{const L=ge(P,"status","unknown"),K=ge(P,"actor_id","-"),q=ge(P,"role","-"),te=ge(P,"reason",""),ne=ge(P,"action_type",""),G=ge(P,"reply","");return i`
                <div class="trpg-round-item ${L.includes("fallback")||L.includes("timeout")?"failed":"active"}">
                  <span>${K} (${q})</span>
                  <span style="margin-left:auto; font-size:11px;">${L}</span>
                  ${ne?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${ne}</div>`:null}
                  ${te?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${te}</div>`:null}
                  ${G?i`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${G.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${l?i`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${ge(l,"status","unknown")}</strong>
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
  `}function Df({state:e,nowMs:t}){var l,c,p;const n=qe.value||((l=e.session)==null?void 0:l.room)||"",s=((c=e.current_round)==null?void 0:c.phase)??((p=e.session)==null?void 0:p.status)??"unknown",a=nc(t),o=If(t);return i`
    <${C} title="조작 안전 잠금" style="margin-bottom:16px;" semanticId="lab.trpg">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${o}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>Tf(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{ma(),N("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Of({active:e}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${e===n.id?"active":""}"
          role="tab"
          aria-selected=${e===n.id}
          onClick=${()=>Cf(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function qf({state:e}){const t=e.party??[],n=e.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${C} title="관전 가이드" semanticId="lab.trpg">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${C} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${ic} events=${n.slice(-20)} />
        <//>

        ${e.map?i`
            <${C} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${Nf} mapStr=${e.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${C} title="현재 라운드" semanticId="lab.trpg">
          <${lc} state=${e} />
        <//>

        <${C} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${rc} state=${e} />
        <//>

        <${C} title=${`파티 (${t.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${t.map(s=>i`<${ac} key=${s.id??s.name} actor=${s} />`)}
            ${t.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${e.history&&e.history.length>0?i`
            <${C} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
              <${oc} state=${e} />
            <//>
          `:null}
      </div>
    </div>
  `}function Ff({state:e}){const t=e.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${C} title=${`이벤트 타임라인 (${t.length})`}>
          <${wf} events=${t} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${C} title="최근 라운드 결과" semanticId="lab.trpg">
          <${cc} />
        <//>

        <${C} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${lc} state=${e} />
        <//>
      </div>
    </div>
  `}function Kf({state:e,nowMs:t}){const n=e.party??[];return i`
    <div>
      <${Df} state=${e} nowMs=${t} />
      <div class="trpg-layout">
        <div>
          <${C} title="조작 패널" semanticId="lab.trpg">
            <${Mf} state=${e} nowMs=${t} />
          <//>

          <${C} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${jf} state=${e} />
          <//>

          <${C} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${Ef} state=${e} nowMs=${t} />
          <//>

          <${C} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${cc} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${C} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${rc} state=${e} />
          <//>

          <${C} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${ac} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${e.history&&e.history.length>0?i`
              <${C} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
                <${oc} state=${e} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Uf(){var c,p,u,_,g;const e=Pr.value,t=mi.value;if(ee(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const v=window.setInterval(()=>{Yo.value=Date.now()},1e3);return()=>{window.clearInterval(v)}},[]),t&&!e)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!e)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Ze()}>Refresh</button>
      </div>
    `;const n=e.party??[],s=e.story_log??[],a=e.outcome,o=tc.value,l=Yo.value;return i`
    <div>
      <${he} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${qe.value||((c=e.session)==null?void 0:c.room)||"-"} · phase: ${((p=e.current_round)==null?void 0:p.phase)??((u=e.session)==null?void 0:u.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Ze()}>새로고침</button>
      </div>

      <${zf} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((_=e.session)==null?void 0:_.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((g=e.current_round)==null?void 0:g.round_number)??0}</div>
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

      <${Of} active=${o} />

      ${o==="overview"?i`<${qf} state=${e} />`:o==="timeline"?i`<${Ff} state=${e} />`:i`<${Kf} state=${e} nowMs=${l} />`}
    </div>
  `}function Bf(){return i`
    <div>
      <${he} surfaceId="lab" />
      <${C} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${C} title="TRPG" class="section" semanticId="lab.trpg">
        <${Uf} />
      <//>
    </div>
  `}const va=f(new Set(["broadcast","tasks","keepers","system"]));function Hf(e){const t=new Set(va.value);t.has(e)?t.delete(e):t.add(e),va.value=t}const lo=f(null);function dc(e){lo.value=e}function Wf(e){return e.kind==="board"?"broadcast":e.kind==="tasks"?"tasks":e.kind==="keepers"?"keepers":"system"}const Gf=xe(()=>{const e=va.value;return js.value.filter(t=>e.has(Wf(t)))}),Jf=12e4,Vf=xe(()=>{const e=zr.value,t=Date.now();return Ue.value.map(n=>{const s=n.name.trim().toLowerCase(),a=e.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?o=t-new Date(l).getTime()>Jf?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),Qf=xe(()=>{const e=zr.value;return Ue.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle").map(t=>{const n=t.name.trim().toLowerCase(),s=e.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:t.name,emoji:t.emoji??"",koreanName:t.koreanName??null,currentTask:t.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((t,n)=>{const s={hot:0,normal:1,calm:2};return s[t.pressure]-s[n.pressure]})});function Xo(e){return e.kind==="board"?"live-event-broadcast":e.kind==="tasks"?"live-event-task":e.kind==="keepers"?"live-event-keeper":"live-event-system"}function Yf(e){const t=e.eventType;return t==="broadcast"?"broadcast":t==="agent_joined"?"joined":t==="agent_left"?"left":t==="task_update"?"task":t==="board_post"?"post":t==="board_comment"?"comment":t==="keeper_heartbeat"?"heartbeat":t==="keeper_handoff"?"handoff":t==="keeper_compaction"?"compact":t==="keeper_guardrail"?"guardrail":e.kind==="board"?"board":e.kind==="tasks"?"task":e.kind==="keepers"?"keeper":"system"}function Xf(e){switch(e){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function Zf(){const e=Vf.value,t=lo.value;return e.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${e.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${Xf(n.state)} ${t===n.name?"pulse-selected":""}"
          onClick=${()=>dc(t===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const e$=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function t$(){const e=va.value;return i`
    <div class="activity-filter-bar">
      ${e$.map(t=>i`
        <button
          key=${t.kind}
          class="activity-filter-btn ${t.cssClass} ${e.has(t.kind)?"active":""}"
          onClick=${()=>Hf(t.kind)}
        >
          ${t.label}
        </button>
      `)}
    </div>
  `}function n$(){const e=Gf.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${e.length} events</span>
      </div>
      <${t$} />
      <div class="activity-stream-list">
        ${e.length===0?i`<div class="activity-empty">No events matching filters</div>`:e.map((t,n)=>i`
            <div
              key=${`${t.timestamp}-${n}`}
              class="activity-item ${Xo(t)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${Xo(t)}">${Yf(t)}</span>
                <span class="activity-agent">${t.agent}</span>
                <span class="activity-time">${al(t.timestamp)}</span>
              </div>
              <div class="activity-item-text">${t.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function s$(e){switch(e){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function a$(e){switch(e){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function i$(){const e=Qf.value,t=lo.value;return i`
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
              onClick=${()=>dc(t===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${s$(n.pressure)}">
                  ${a$(n.pressure)}
                  ${n.assignedCount>0?i` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?i`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?i`<span class="focus-activity-text">${n.lastActivityText}</span>`:i`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?i`<${W} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function o$(){const e=nt.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>Live Monitor</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${e?"connected":"disconnected"}"></span>
            ${e?"Connected":"Offline"}
          </span>
          <span class="live-stat">${Ue.value.length} agents</span>
          <span class="live-stat">${_a.value} events</span>
        </div>
      </div>

      <${Zf} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${n$} />
        </div>
        <div class="live-panel-side">
          <${i$} />
        </div>
      </div>
    </div>
  `}const Zo=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],Pi=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"proof",label:"Proof",icon:"🔍",group:"observe",description:"협업, 대화, 도구, backing evidence를 증명 중심으로 읽는 표면"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"live",label:"Live",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}],ks=f(!1);function r$(){const e=nt.value;return i`
    <div class="connection-status ${e?"connected":"disconnected"}">
      <span class="status-dot ${e?"connected":"disconnected"}"></span>
      <span class="status-text">${e?"Live":"재연결 중..."}</span>
      <span class="event-count">${_a.value} events</span>
    </div>
  `}function uc(e){const t=e==null?void 0:e.trim();return t?t.length>10?t.slice(0,10):t:"commit unavailable"}function l$(){const e=ie.value,t=e==null?void 0:e.build,n=t?`v${t.release_version} · ${uc(t.commit)}`:e!=null&&e.version?`v${e.version} · commit unavailable`:"version unavailable";return i`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${ks.value}
        onClick=${()=>{ks.value=!ks.value}}
      >
        Server Build · ${n}
      </button>
      ${ks.value?i`
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
                <strong>${t!=null&&t.started_at?i`<${W} timestamp=${t.started_at} />`:"unknown"}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof(t==null?void 0:t.uptime_seconds)=="number"?`${t.uptime_seconds}s`:"unknown"}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${e!=null&&e.generated_at?i`<${W} timestamp=${e.generated_at} />`:"unknown"}</strong>
              </div>
            </div>
          `:null}
    </div>
  `}function Li(e){e==="command"&&(jt(),Jt(),(Y.value==="swarm"||Y.value==="warroom")&&Je(),Y.value==="warroom"&&$e()),e==="mission"&&(Gr(),Ks()),e==="proof"&&$l(O.value.params.session_id,O.value.params.operation_id),e==="execution"&&$t(),e==="intervene"&&($e(),xt()),e==="memory"&&Xe(),e==="planning"&&Oi(),e==="lab"&&Ze()}function c$({currentTab:e}){var s;const t=nt.value,n=(s=ie.value)==null?void 0:s.build;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${D} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${t?"ok":"bad"}">${t?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agent</span>
          <strong>${Ue.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keeper</span>
          <strong>${rt.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Task</span>
          <strong>${Qe.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Event</span>
          <strong>${_a.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Gn(),Dr(),Li(e)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>ce("intervene")}>
          개입 열기
        </button>
      </div>
      ${n?i`<div class="rail-build-hint">Server Build · v${n.release_version} · ${uc(n.commit)}</div>`:null}
    </section>
  `}function d$(){const e=me.value,t=(e==null?void 0:e.pending_confirms.length)??0,n=(e==null?void 0:e.sessions.length)??0,s=(e==null?void 0:e.keepers.length)??0;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${D} panelId="side_rail.quick_actions" compact=${!0} />
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
          onClick=${()=>{$e(),xt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>ce("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function u$(){const e=O.value.tab,t=Pi.find(s=>s.id===e),n=Zo.find(s=>s.id===(t==null?void 0:t.group));return i`
    <aside class="dashboard-rail">
      <${he} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${D} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${Zo.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${Pi.filter(a=>a.group===s.id).map(a=>i`
                  <button
                    class="rail-tab-btn ${e===a.id?"active":""}"
                    onClick=${()=>ce(a.id)}
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

      <${c$} currentTab=${e} />
      <${d$} />
    </aside>
  `}function p$(){switch(O.value.tab){case"mission":return i`<${No} />`;case"proof":return i`<${d_} />`;case"execution":return i`<${qg} />`;case"live":return i`<${o$} />`;case"memory":return i`<${Pg} />`;case"governance":return i`<${vf} />`;case"planning":return i`<${ef} />`;case"intervene":return i`<${fg} />`;case"command":return i`<${mg} />`;case"lab":return i`<${Bf} />`;default:return i`<${No} />`}}function m$(){ee(()=>{kc(),rr(),Or(),$t(),Dr(),Gr();const n=Ou();return qu(),()=>{Pc(),n(),Fu()}},[]),ee(()=>{const n=setInterval(()=>{Li(O.value.tab)},15e3);return()=>{clearInterval(n)}},[]),ee(()=>{Li(O.value.tab)},[O.value.tab]);const e=O.value.tab,t=Pi.find(n=>n.id===e);return i`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <${l$} />
          </h1>
          <p class="header-subtitle">${(t==null?void 0:t.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${r$} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${u$} />
        <main class="dashboard-main">
          ${pi.value&&!nt.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${p$} />`}
        </main>
      </div>

      <${$m} />
      <${Op} />
      <${Lp} />
    </div>
  `}const er=document.getElementById("app");er&&fc(i`<${m$} />`,er);export{Tm as _};
