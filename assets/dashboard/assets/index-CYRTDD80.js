var Wl=Object.defineProperty;var Hl=(e,t,n)=>t in e?Wl(e,t,{enumerable:!0,configurable:!0,writable:!0,value:n}):e[t]=n;var It=(e,t,n)=>Hl(e,typeof t!="symbol"?t+"":t,n);import{e as Gl,_ as Jl,c as _,b as xe,y as ne,d as zo,A as Vl,G as Ql}from"./vendor-kuFK4-oj.js";(function(){const t=document.createElement("link").relList;if(t&&t.supports&&t.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const o of a)if(o.type==="childList")for(const l of o.addedNodes)l.tagName==="LINK"&&l.rel==="modulepreload"&&s(l)}).observe(document,{childList:!0,subtree:!0});function n(a){const o={};return a.integrity&&(o.integrity=a.integrity),a.referrerPolicy&&(o.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?o.credentials="include":a.crossOrigin==="anonymous"?o.credentials="omit":o.credentials="same-origin",o}function s(a){if(a.ep)return;a.ep=!0;const o=n(a);fetch(a.href,o)}})();var i=Gl.bind(Jl);const Yl=["mission","proof","execution","live","memory","governance","planning","intervene","command","lab"],Eo={tab:"mission",params:{},postId:null};function Ji(e){return!!e&&Yl.includes(e)}function Ha(e){try{return decodeURIComponent(e)}catch{return e}}function Ga(e){const t={};return e&&new URLSearchParams(e).forEach((s,a)=>{t[a]=s}),t}function Xl(e){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Do(e,t){if(e[0]==="chains"){const o={...t,surface:"chains"};return e[1]==="operation"&&e[2]&&(o.operation=Ha(e[2])),{tab:"command",params:o,postId:null}}if(e[0]==="lab"){const o={...t};return e[1]&&(o.surface=Ha(e[1])),{tab:"lab",params:o,postId:null}}const n=e[0],s=t.tab;return{tab:Ji(n)?n:Ji(s)?s:"mission",params:t,postId:null}}function Cs(e){const t=(e||"").replace(/^#/,"").trim();if(!t)return Eo;const n=Ha(t);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const o=Ga(a),l=Xl(s);return Do(l,o)}function Zl(e,t){const n=e.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...Eo,params:Ga(t.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Ga(t.replace(/^\?/,""));return Do(s,a)}function jo(e){const t=e.tab==="lab"&&e.params.surface?`lab/${encodeURIComponent(e.params.surface)}`:e.tab,n=Object.entries(e.params).filter(([a])=>!(a==="tab"||e.tab==="lab"&&a==="surface"));if(n.length===0)return`#${t}`;const s=new URLSearchParams(n);return`#${t}?${s.toString()}`}const j=_(Cs(window.location.hash));window.addEventListener("hashchange",()=>{j.value=Cs(window.location.hash)});function ue(e,t){const n={tab:e,params:t??{}};window.location.hash=jo(n)}function ec(e){window.location.hash=`#memory?post=${encodeURIComponent(e)}`}function tc(){if(window.location.hash&&window.location.hash!=="#"){j.value=Cs(window.location.hash);return}const e=Zl(window.location.pathname,window.location.search);if(e){j.value=e;const t=jo(e);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${t}`);return}window.location.hash="#mission",j.value=Cs(window.location.hash)}const Vi="masc_dashboard_sse_session_id",nc=1e3,sc=15e3,tt=_(!1),ra=_(0),Oo=_(null),Is=_([]);function ac(){let e=sessionStorage.getItem(Vi);return e||(e=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Vi,e)),e}const ic=200;function oc(e,t,n="system",s={}){const a={agent:e,text:t,timestamp:Date.now(),kind:n,...s};Is.value=[a,...Is.value].slice(0,ic)}function Ja(e,t=88){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-3)}...`:n:void 0}function Qi(e,t){const n=Ja(t);return n?`${e}: ${n}`:`New ${e.toLowerCase()}`}function ke(e,t,n,s,a={}){oc(e,t,n,{eventType:s,...a})}let Ie=null,qt=null,Va=0;function qo(){qt&&(clearTimeout(qt),qt=null)}function rc(){if(qt)return;Va++;const e=Math.min(Va,5),t=Math.min(sc,nc*Math.pow(2,e));qt=setTimeout(()=>{qt=null,Fo()},t)}function Fo(){qo(),Ie&&(Ie.close(),Ie=null);const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");n&&t.set("agent",n),s&&t.set("token",s),t.set("session_id",ac());const a=t.toString()?`/sse?${t.toString()}`:"/sse",o=new EventSource(a);Ie=o,o.onopen=()=>{Ie===o&&(Va=0,tt.value=!0)},o.onerror=()=>{Ie===o&&(tt.value=!1,o.close(),Ie=null,rc())},o.onmessage=l=>{try{const c=JSON.parse(l.data);ra.value++,Oo.value=c,lc(c)}catch{}}}function lc(e){const t=e.type,n=e.agent??e.author??e.from??e.from_agent??"";switch(t){case"agent_joined":ke(n,"Joined","system","agent_joined");break;case"agent_left":ke(n,"Left","system","agent_left");break;case"broadcast":ke(n,`${(e.message??e.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":ke(n,`Task: ${e.task_id??""} -> ${e.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":ke(n,Qi("Post",e.content??e.message),"board","board_post",{author:e.author??n,preview:Ja(e.content??e.message),postId:e.post_id});break;case"board_comment":case"masc/board_comment":ke(n,Qi("Comment",e.content??e.message),"board","board_comment",{author:e.author??n,preview:Ja(e.content??e.message),postId:e.post_id});break;case"keeper_heartbeat":ke(e.name??n,`Heartbeat gen=${e.generation??"?"} ctx=${e.context_ratio!=null?Math.round(e.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":ke(e.name??n,`Handoff gen ${e.from_generation??"?"} -> ${e.to_generation??"?"} (${e.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":ke(e.name??n,`Compaction saved ${e.saved_tokens??"?"} tokens (${e.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":ke(e.name??n,`Guardrail: ${e.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:ke(n,t,"system","unknown")}}function cc(){qo(),Ie&&(Ie.close(),Ie=null),tt.value=!1}function p(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function r(e){return typeof e=="string"&&e.trim()!==""?e.trim():void 0}function d(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function K(e){return typeof e=="boolean"?e:void 0}function H(e){return Array.isArray(e)?e.map(t=>typeof t=="string"?t.trim():"").filter(Boolean):[]}function Te(e,t=[]){if(Array.isArray(e))return e;if(!p(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function nt(e){if(typeof e=="string"&&e.trim()!=="")return e;if(!(typeof e!="number"||!Number.isFinite(e)||e<=0))return new Date(e*1e3).toISOString()}function Ko(){return new URLSearchParams(window.location.search)}function Uo(){const e=Ko(),t={},n=e.get("token"),s=e.get("agent")??e.get("agent_name");return n&&(t.Authorization=`Bearer ${n}`),s&&(t["X-MASC-Agent"]=s),t}function Bo(){return{...Uo(),"Content-Type":"application/json"}}const dc=15e3,hi=3e4,uc=6e4,Yi=new Set([408,425,429,500,502,503,504]);class Wn extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,o=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(o);It(this,"method");It(this,"path");It(this,"status");It(this,"statusText");It(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function yi(e,t,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(e,{...t,signal:s.signal})}catch(o){if(o instanceof Error&&o.name==="AbortError"){const l=typeof t.method=="string"?t.method.toUpperCase():"GET";throw new Wn({method:l,path:e,timeout:!0,timeoutMs:n})}throw o}finally{clearTimeout(a)}}function pc(){var t,n;const e=Ko();return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function ee(e){const t=await yi(e,{headers:Uo()},dc);if(!t.ok)throw new Wn({method:"GET",path:e,status:t.status,statusText:t.statusText});return t.json()}function mc(e){return new Promise(t=>setTimeout(t,e))}function vc(e){const t=e.match(/\b(\d{3})\b/);if(!t)return null;const n=t[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function _c(e){if(e instanceof Wn)return e.timeout||typeof e.status=="number"&&Yi.has(e.status);if(!(e instanceof Error))return!1;if(/timeout after \d+ms/i.test(e.message))return!0;const t=vc(e.message);return t!==null&&Yi.has(t)}async function la(e,t,n=2){let s=0;for(;;)try{return await t()}catch(a){if(!_c(a)||s>=n)throw a;const o=250*(s+1);console.warn(`[dashboard/api] ${e} failed (attempt ${s+1}), retrying in ${o}ms`,a),await mc(o),s+=1}}async function Me(e,t,n,s=hi){const a=await yi(e,{method:"POST",headers:{...Bo(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new Wn({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.json()}async function fc(e,t,n,s=hi){const a=await yi(e,{method:"POST",headers:{...Bo(),...n??{}},body:JSON.stringify(t)},s);if(!a.ok)throw new Wn({method:"POST",path:e,status:a.status,statusText:a.statusText});return a.text()}function gc(e){const t=e.split(`
`).find(s=>s.startsWith("data: ")),n=t?t.slice(6).trim():e.trim();return JSON.parse(n)}function $c(e){var t,n,s,a,o,l,c;if((t=e.error)!=null&&t.message)throw new Error(e.error.message);if((n=e.result)!=null&&n.isError){const u=((a=(s=e.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(u)}return((c=(l=(o=e.result)==null?void 0:o.content)==null?void 0:l[0])==null?void 0:c.text)??""}async function it(e,t){const n=await fc("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:e,arguments:t},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},uc),s=gc(n);return $c(s)}function hc(){return ee("/api/v1/dashboard/shell")}function yc(){return ee("/api/v1/dashboard/execution")}function bc(e,t){const n=new URLSearchParams;return n.set("sort_by",e),t!=null&&t.excludeSystem&&n.set("exclude_system","true"),ee(`/api/v1/dashboard/memory${n.toString()?`?${n}`:""}`)}function kc(){return la("fetchDashboardGovernance",async()=>{const e=await ee("/api/v1/dashboard/governance"),t=Array.isArray(e.items)?e.items.map(o=>Dc(o)).filter(o=>o!==null):[],n=Array.isArray(e.pending_actions)?e.pending_actions.map(o=>Go(o)).filter(o=>o!==null):[],s=t.filter(o=>o.kind==="debate").map(o=>({id:o.id,topic:o.topic,status:o.status,argument_count:o.evidence_refs.length,created_at:o.last_activity_at??void 0})),a=t.filter(o=>o.kind==="consensus").map(o=>({id:o.id,topic:o.topic,initiator:o.related_agents[0]||"system",votes:o.votes??0,quorum:o.quorum??0,threshold:o.threshold,state:o.status,created_at:o.last_activity_at??void 0}));return{generated_at:re(e.generated_at)??void 0,summary:p(e.summary)?{debates:me(e.summary.debates)??void 0,voting_sessions:me(e.summary.voting_sessions)??void 0,debates_open:me(e.summary.debates_open)??void 0,sessions_active:me(e.summary.sessions_active)??void 0,sessions_without_quorum:me(e.summary.sessions_without_quorum)??void 0,ready_to_execute:me(e.summary.ready_to_execute)??void 0,oldest_open_debate_age_s:typeof e.summary.oldest_open_debate_age_s=="number"?e.summary.oldest_open_debate_age_s:null,last_activity_age_s:typeof e.summary.last_activity_age_s=="number"?e.summary.last_activity_age_s:null,judge_online:typeof e.summary.judge_online=="boolean"?e.summary.judge_online:void 0,judge_last_seen_at:re(e.summary.judge_last_seen_at)}:void 0,debates:s,sessions:a,items:t,activity:Array.isArray(e.activity)?e.activity.map(o=>jc(o)).filter(o=>o!==null):[],judge:Oc(e.judge),pending_actions:n}})}function xc(){return ee("/api/v1/dashboard/semantics")}function Sc(){return ee("/api/v1/dashboard/mission")}function Ac(e=!1){return ee(`/api/v1/dashboard/mission/briefing${e?"?force=1":""}`)}function Cc(e,t){const n=new URLSearchParams;e&&n.set("session_id",e),t&&n.set("operation_id",t);const s=n.toString();return ee(`/api/v1/dashboard/proof${s?`?${s}`:""}`)}function Ic(){return ee("/api/v1/dashboard/planning")}function Tc(){return ee("/api/v1/operator")}function Wo(e={}){const t=new URLSearchParams;e.targetType&&t.set("target_type",e.targetType),e.targetId&&t.set("target_id",e.targetId),e.includeWorkers!=null&&t.set("include_workers",e.includeWorkers?"true":"false");const n=t.toString();return ee(`/api/v1/operator/digest${n?`?${n}`:""}`)}function Rc(){return ee("/api/v1/command-plane")}function wc(){return ee("/api/v1/command-plane/summary")}function Pc(){return ee("/api/v1/chains/summary")}function Lc(e){return ee(`/api/v1/chains/runs/${encodeURIComponent(e)}`)}function Nc(){return ee("/api/v1/command-plane/help")}function Mc(e,t){const n=new URLSearchParams;e&&n.set("run_id",e),t&&n.set("operation_id",t);const s=n.toString();return ee(`/api/v1/command-plane/swarm${s?`?${s}`:""}`)}function zc(e,t){return Me(e,t)}function Ec(e){switch(e.action_type){case"keeper_message":case"keeper_recover":return 9e4;case"swarm_run_continue":return 6e4;case"swarm_run_rerun":return 12e4;case"swarm_run_abandon":return 3e4;case"lodge_tick":return 45e3;default:return hi}}function ca(e){return Me("/api/v1/operator/action",e,void 0,Ec(e))}function Ho(e,t,n="confirm"){return Me("/api/v1/operator/confirm",{actor:e,confirm_token:t,decision:n})}function fs(e){if(typeof e=="string"&&e.trim())return e;if(typeof e!="number"||Number.isNaN(e))return new Date().toISOString();const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}function re(e){if(typeof e=="string"){const t=e.trim();return t||null}if(typeof e=="number"&&Number.isFinite(e)){const t=e<1e12?e*1e3:e;return new Date(t).toISOString()}return null}function M(e){if(typeof e!="string")return null;const t=e.trim();return t||null}function Go(e){if(!p(e))return null;const t=y(e.confirm_token??e.token,"").trim();return t?{confirm_token:t,actor:M(e.actor)??void 0,action_type:M(e.action_type)??void 0,target_type:M(e.target_type)??void 0,target_id:M(e.target_id),delegated_tool:M(e.delegated_tool)??void 0,created_at:re(e.created_at)??void 0,preview:e.preview}:null}function bi(e){return p(e)?{board_post_id:M(e.board_post_id),task_id:M(e.task_id),operation_id:M(e.operation_id),team_session_id:M(e.team_session_id)}:{}}function Jo(e){if(!p(e))return null;const t=M(e.action_kind),n=M(e.resolved_tool),s=M(e.target_type),a=M(e.target_id),o=M(e.reason);return!t&&!n&&!s&&!o?null:{action_kind:t??void 0,resolved_tool:n,target_type:s,target_id:a,reason:o??void 0,payload_preview:e.payload_preview}}function Vo(e){if(!p(e))return null;const t=M(e.action_type),n=M(e.delegated_tool),s=M(e.confirmation_state),a=re(e.created_at);return!t&&!n&&!s&&!a?null:{action_type:t??void 0,delegated_tool:n,confirmation_state:s??void 0,created_at:a}}function Qo(e){if(!p(e))return null;const t=Go(e.pending_confirm),n=M(e.pending_confirm_token)??(t==null?void 0:t.confirm_token)??null;return{requires_human_gate:typeof e.requires_human_gate=="boolean"?e.requires_human_gate:void 0,pending_confirm:t,pending_confirm_token:n,ready_to_execute:typeof e.ready_to_execute=="boolean"?e.ready_to_execute:void 0}}function Yo(e){if(!p(e))return null;const t=M(e.summary),n=M(e.target_id);return!t&&!n?null:{judgment_id:M(e.judgment_id)??void 0,target_kind:M(e.target_kind)??void 0,target_id:n??void 0,status:M(e.status)??void 0,summary:t??void 0,confidence:typeof e.confidence=="number"?e.confidence:null,generated_at:re(e.generated_at),expires_at:re(e.expires_at),model_used:M(e.model_used),keeper_name:M(e.keeper_name),evidence_refs:Re(e.evidence_refs),recommended_action:Jo(e.recommended_action),guardrail_state:Qo(e.guardrail_state),executed_route:Vo(e.executed_route)}}function Dc(e){if(!p(e))return null;const t=y(e.id,"").trim(),n=y(e.topic,"").trim();if(!t||!n)return null;const s=bi(e.context);return{kind:y(e.kind,"debate"),id:t,topic:n,status:y(e.status??e.state,"open"),last_activity_at:re(e.last_activity_at),truth_summary:M(e.truth_summary)??void 0,judgment_summary:M(e.judgment_summary),confidence:typeof e.confidence=="number"?e.confidence:null,related_agents:Re(e.related_agents),context:s,linked_board_post_id:M(e.linked_board_post_id)??s.board_post_id??null,linked_task_id:M(e.linked_task_id)??s.task_id??null,linked_operation_id:M(e.linked_operation_id)??s.operation_id??null,linked_session_id:M(e.linked_session_id)??s.team_session_id??null,recommended_action:Jo(e.recommended_action),executed_route:Vo(e.executed_route),guardrail_state:Qo(e.guardrail_state),evidence_refs:Re(e.evidence_refs),approve_count:me(e.approve_count),reject_count:me(e.reject_count),abstain_count:me(e.abstain_count),votes:me(e.votes),quorum:me(e.quorum),threshold:typeof e.threshold=="number"?e.threshold:void 0}}function jc(e){if(!p(e))return null;const t=y(e.kind,"").trim();return t?{kind:t,item_kind:M(e.item_kind)??void 0,item_id:M(e.item_id)??void 0,topic:M(e.topic)??void 0,created_at:re(e.created_at),summary:M(e.summary)??void 0,actor:M(e.actor),index:me(e.index),decision:M(e.decision)}:null}function Oc(e){if(p(e))return{judge_online:typeof e.judge_online=="boolean"?e.judge_online:void 0,refreshing:typeof e.refreshing=="boolean"?e.refreshing:void 0,generated_at:re(e.generated_at),expires_at:re(e.expires_at),model_used:M(e.model_used),keeper_name:M(e.keeper_name),last_error:M(e.last_error)}}function qc(e){var a;const t=e.trim(),s=((a=(t.startsWith("[flair:")?t.replace(/^\[flair:[^\]]+\]\s*/i,""):t).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Fc(e){if(!p(e))return null;const t=y(e.id,"").trim(),n=y(e.author,"").trim(),s=y(e.content,"").trim();if(!t||!n)return null;const a=F(e.score,0),o=F(e.votes_up,0),l=F(e.votes_down,0),c=F(e.votes,a||o-l),u=F(e.comment_count,F(e.reply_count,0)),m=(()=>{const $=e.flair;if(typeof $=="string"&&$.trim())return $.trim();if(p($)){const A=y($.name,"").trim();if(A)return A}return y(e.flair_name,"").trim()||void 0})(),v=y(e.created_at_iso,"").trim()||fs(e.created_at),f=y(e.updated_at_iso,"").trim()||(e.updated_at!==void 0?fs(e.updated_at):v),h=y(e.title,"").trim()||qc(s),k=Array.isArray(e.tags)?e.tags.filter($=>typeof $=="string"&&$.trim()!==""):[];return{id:t,author:n,post_kind:(()=>{const $=y(e.post_kind,"").trim().toLowerCase();return $==="automation"||$==="system"||$==="human"?$:void 0})(),title:h,content:s,tags:k,votes:c,vote_balance:a,comment_count:u,created_at:v,updated_at:f,flair:m,hearth:y(e.hearth,"").trim()||null,visibility:y(e.visibility,"").trim()||void 0,expires_at:y(e.expires_at_iso,"").trim()||(e.expires_at!==void 0&&e.expires_at!==0?fs(e.expires_at):"")||null,hearth_count:F(e.hearth_count,0)}}function Kc(e){if(!p(e))return null;const t=y(e.id,"").trim(),n=y(e.post_id,"").trim(),s=y(e.author,"").trim();return!t||!s?null:{id:t,post_id:n,author:s,content:y(e.content,""),created_at:fs(e.created_at)}}async function Uc(e){return la("fetchBoardPost",async()=>{const t=await ee(`/api/v1/board/${e}?format=flat`),n=p(t.post)?t.post:t,s=Fc(n)??{id:e,author:"unknown",post_kind:"human",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString(),hearth:null,visibility:"internal",expires_at:null},o=(Array.isArray(t.comments)?t.comments:[]).map(Kc).filter(l=>l!==null);return{...s,comments:o}})}function Xo(e,t){return Me("/api/v1/tools/masc_board_vote",{post_id:e,direction:t,vote:t,voter:pc()})}function Bc(e,t,n){return Me("/api/v1/tools/masc_board_comment",{post_id:e,author:t,content:n})}function Wc(e){const t=y(e,"").trim().toLowerCase();if(t==="win"||t==="won"||t==="victory")return"victory";if(t==="lose"||t==="lost"||t==="defeat")return"defeat";if(t==="draw"||t==="stalemate"||t==="tie")return"draw"}function le(...e){for(const t of e){const n=y(t,"");if(n.trim())return n.trim()}return""}function Xi(e){const t=Wc(le(e.outcome,e.result,e.result_code));if(!t)return;const n=le(e.reason,e.reason_code,e.description,e.detail),s=le(e.summary,e.summary_ko,e.summary_en,e.note),a=le(e.details,e.details_text,e.text,e.note),o=le(e.winner,e.winner_name,e.actor_winner,e.winner_actor),l=le(e.winner_actor_id,e.winner_actor,e.actor_winner_id),c=le(e.raw_reason,e.raw_reason_code,e.error_message),u=(()=>{const f=e.evidence??e.evidence_ids??e.supporting_events??e.event_ids??[];return typeof f=="string"?[f]:Array.isArray(f)?f.map(g=>{if(typeof g=="string")return g.trim();if(p(g)){const h=y(g.summary,"").trim();if(h)return h;const k=y(g.text,"").trim();if(k)return k;const $=y(g.type,"").trim();return $||y(g.event_id,"").trim()}return""}).filter(g=>g.length>0):[]})(),m=(()=>{const f=F(e.turn,Number.NaN);if(Number.isFinite(f))return f;const g=F(e.turn_number,Number.NaN);if(Number.isFinite(g))return g;const h=F(e.current_turn,Number.NaN);if(Number.isFinite(h))return h;const k=F(e.round,Number.NaN);return Number.isFinite(k)?k:void 0})(),v=le(e.phase,e.phase_name,e.current_phase,e.phase_id);return{result:t,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:o||void 0,winner_actor_id:l||void 0,evidence:u.length>0?u:void 0,raw_reason:c||void 0,turn:m,phase:v||void 0}}function Hc(e,t){const n=p(e.state)?e.state:{};if(y(n.status,"active").toLowerCase()!=="ended")return;const a=[...t].reverse().find(l=>p(l)?y(l.type,"")==="session.outcome":!1),o=p(n.session_outcome)?n.session_outcome:{};if(p(o)&&Object.keys(o).length>0){const l=Xi(o);if(l)return l}if(p(a))return Xi(p(a.payload)?a.payload:{})}function y(e,t=""){return typeof e=="string"?e:t}function F(e,t=0){return typeof e=="number"&&Number.isFinite(e)?e:t}function me(e){if(typeof e=="number"&&Number.isFinite(e))return Math.trunc(e);if(typeof e=="string"){const t=Number.parseInt(e.trim(),10);if(Number.isFinite(t))return t}}function Ts(e,t=!1){return typeof e=="boolean"?e:t}function Re(e){return Array.isArray(e)?e.map(t=>{if(typeof t=="string")return t.trim();if(p(t)){const n=y(t.name,"").trim(),s=y(t.id,"").trim(),a=y(t.skill,"").trim();return n||s||a}return""}).filter(t=>t.length>0):[]}function Gc(e){const t={};if(!p(e)&&!Array.isArray(e))return t;if(p(e))return Object.entries(e).forEach(([n,s])=>{const a=n.trim(),o=y(s,"").trim();!a||!o||(t[a]=o)}),t;for(const n of e){if(!p(n))continue;const s=le(n.to,n.target,n.actor_id,n.name,n.id),a=le(n.relationship,n.relation,n.type,n.kind);!s||!a||(t[s]=a)}return t}function Jc(e,t,n){if(e==="dm"||e==="player"||e==="npc")return e;const s=t.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function ye(e,t,n,s=0){const a=e[t];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const o=e[n];if(typeof o=="number"&&Number.isFinite(o))return o}return s}const Vc=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Qc(e){const t=p(e.stats)?e.stats:{},n={};return Object.entries(t).forEach(([s,a])=>{const o=s.trim();o&&(Vc.has(o.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[o]=a))}),n}function Yc(e,t){if(e!=="dice.rolled")return;const n=F(t.raw_d20,0),s=F(t.total,0),a=F(t.bonus,0),o=y(t.action,"roll"),l=F(t.dc,0);return{notation:l>0?`${o} (DC ${l})`:o,rolls:n>0?[n]:[],total:s,modifier:a}}function Xc(e){const t=JSON.stringify(e);return t?t.length>160?`${t.slice(0,157)}...`:t:""}function Zc(e){const t=e.trim().toLowerCase();return t?t.startsWith("dice.")?"dice":t.startsWith("combat.")||t.includes(".attack")||t.includes(".damage")?"combat":t.includes("actor.")?"actor":t.includes("turn.")||t==="turn.started"||t==="phase.changed"?"turn":t.includes("join.")?"join":t.includes("memory")?"memory":t.includes("world.")?"world":t.includes("narration")?"story":"meta":"meta"}function ed(e,t,n,s){const a=n||t||y(s.actor_id,"")||y(s.actor_name,"");switch(e){case"turn.action.proposed":{const o=y(s.proposed_action,y(s.reply,""));return o?`${a||"actor"}: ${o}`:"Action proposed"}case"turn.action.resolved":{const o=y(s.reply,y(s.result,""));return o?`Resolved: ${o}`:"Action resolved"}case"narration.posted":return y(s.reply,y(s.content,y(s.text,"Narration")));case"dice.rolled":{const o=y(s.action,"roll"),l=F(s.total,0),c=F(s.dc,0),u=y(s.label,""),m=a||"actor",v=c>0?` vs DC ${c}`:"",f=u?` (${u})`:"";return`${m} ${o}: ${l}${v}${f}`}case"turn.started":return`Turn ${F(s.turn,1)} started`;case"phase.changed":return`Phase: ${y(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${y(s.name,p(s.actor)?y(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${y(s.keeper_name,y(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${y(s.keeper_name,y(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${F(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${F(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||y(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||y(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${y(s.reason_code,"unknown")}`;case"memory.signal":{const o=p(s.entity_refs)?s.entity_refs:{},l=y(o.requested_tier,""),c=y(o.effective_tier,""),u=Ts(o.guardrail_applied,!1),m=y(s.summary_en,y(s.summary_ko,"Memory signal"));if(!l&&!c)return m;const v=l&&c?`${l}->${c}`:c||l;return`${m} [${v}${u?" (guardrail)":""}]`}case"world.event":{if(y(s.event_type,"")==="canon.check"){const l=y(s.status,"unknown"),c=y(s.contract_id,"n/a");return`Canon ${l}: ${c}`}return y(s.description,y(s.summary,"World event"))}case"combat.attack":return y(s.summary,y(s.result,"Attack resolved"));case"combat.defense":return y(s.summary,y(s.result,"Defense resolved"));case"session.outcome":return y(s.summary,y(s.outcome,"Session ended"));default:{const o=Xc(s);return o?`${e}: ${o}`:e}}}function td(e,t){const n=p(e)?e:{},s=y(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",o=y(n.actor_name,"").trim()||t[a]||y(p(n.payload)?n.payload.actor_name:"",""),l=p(n.payload)?n.payload:{},c=y(n.ts,y(n.timestamp,new Date().toISOString())),u=y(n.phase,y(l.phase,"")),m=y(n.category,"");return{type:s,actor:o||a||y(l.actor_name,""),actor_id:a||y(l.actor_id,""),actor_name:o,seq:n.seq,room_id:y(n.room_id,""),phase:u||void 0,category:m||Zc(s),visibility:y(n.visibility,y(l.visibility,"public")),event_id:y(n.event_id,""),content:ed(s,a,o,l),dice_roll:Yc(s,l),timestamp:c}}function nd(e,t,n){var te,se;const s=y(e.room_id,"")||n||"default",a=p(e.state)?e.state:{},o=p(a.party)?a.party:{},l=p(a.actor_control)?a.actor_control:{},c=p(a.join_gate)?a.join_gate:{},u=p(a.contribution_ledger)?a.contribution_ledger:{},m=Object.entries(o).map(([G,Z])=>{const S=p(Z)?Z:{},Se=ye(S,"max_hp",void 0,10),Be=ye(S,"hp",void 0,Se),lt=ye(S,"max_mp",void 0,0),ct=ye(S,"mp",void 0,0),O=ye(S,"level",void 0,1),Ae=ye(S,"xp",void 0,0),dt=Ts(S.alive,Be>0),ln=l[G],cn=typeof ln=="string"?ln:void 0,es=Jc(S.role,G,cn),ts=me(S.generation),ns=le(S.joined_at,S.joinedAt,S.started_at,S.startedAt),ss=le(S.claimed_at,S.claimedAt,S.assigned_at,S.assignedAt,S.assigned_time),U=le(S.last_seen,S.lastSeen,S.last_seen_at,S.lastSeenAt,S.last_active,S.lastActive),Ct=le(S.scene,S.current_scene,S.currentScene,S.world_scene,S.scene_name,S.sceneName),Bl=le(S.location,S.current_location,S.currentLocation,S.position,S.zone,S.area);return{id:G,name:y(S.name,G),role:es,keeper:cn,archetype:y(S.archetype,""),persona:y(S.persona,""),portrait:y(S.portrait,"")||void 0,background:y(S.background,"")||void 0,traits:Re(S.traits),skills:Re(S.skills),stats_raw:Qc(S),status:dt?"active":"dead",generation:ts,joined_at:ns||void 0,claimed_at:ss||void 0,last_seen:U||void 0,scene:Ct||void 0,location:Bl||void 0,inventory:Re(S.inventory),notes:Re(S.notes),relationships:Gc(S.relationships),stats:{hp:Be,max_hp:Se,mp:ct,max_mp:lt,level:O,xp:Ae,strength:ye(S,"strength","str",10),dexterity:ye(S,"dexterity","dex",10),constitution:ye(S,"constitution","con",10),intelligence:ye(S,"intelligence","int",10),wisdom:ye(S,"wisdom","wis",10),charisma:ye(S,"charisma","cha",10)}}}),v=m.filter(G=>G.status!=="dead"),f=Hc(e,t),g={phase_open:Ts(c.phase_open,!0),min_points:F(c.min_points,3),window:y(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},h=Object.entries(u).map(([G,Z])=>{const S=p(Z)?Z:{};return{actor_id:G,score:F(S.score,0),last_reason:y(S.last_reason,"")||null,reasons:Re(S.reasons)}}),k=m.reduce((G,Z)=>(G[Z.id]=Z.name,G),{}),$=t.map(G=>td(G,k)),C=F(a.turn,1),A=y(a.phase,"round"),T=y(a.map,""),x=p(a.world)?a.world:{},R=T||y(x.ascii_map,y(x.map,"")),w=$.filter((G,Z)=>{const S=t[Z];if(!p(S))return!1;const Se=p(S.payload)?S.payload:{};return F(Se.turn,-1)===C}),E=(w.length>0?w:$).slice(-12),J=y(a.status,"active");return{session:{id:s,room:s,status:J==="ended"?"ended":J==="paused"?"paused":"active",round:C,actors:v,created_at:((te=$[0])==null?void 0:te.timestamp)??new Date().toISOString()},current_round:{round_number:C,phase:A,events:E,timestamp:((se=$[$.length-1])==null?void 0:se.timestamp)??new Date().toISOString()},map:R||void 0,join_gate:g,contribution_ledger:h,outcome:f,party:v,story_log:$,history:[]}}async function sd(e){const t=`?room_id=${encodeURIComponent(e)}`,n=await ee(`/api/v1/trpg/events${t}`);return Array.isArray(n.events)?n.events:[]}async function ad(e){const t=`?room_id=${encodeURIComponent(e)}`,[n,s]=await Promise.all([ee(`/api/v1/trpg/state${t}`),sd(e)]);return nd(n,s,e)}function id(e){return Me("/api/v1/trpg/rounds/run",{room_id:e})}function od(e){const t="".trim().toLowerCase();if(t)switch(t){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return t}}function rd(e){const t={room_id:e.roomId,actor_id:e.actorId,action:e.action,stat_value:e.statValue,dc:e.dc};return e.rawD20!=null&&(t.raw_d20=e.rawD20),e.ruleModule&&(t.rule_module=e.ruleModule),Me("/api/v1/trpg/dice/roll",t)}function ld(e,t){const n=od();return Me("/api/v1/trpg/turns/advance",{room_id:e,...n?{phase:n}:{}})}function cd(e,t){var a;const n=(a=t.idempotencyKey)==null?void 0:a.trim(),s={room_id:e};return t.actor_id&&t.actor_id.trim()&&(s.actor_id=t.actor_id.trim()),t.name&&t.name.trim()&&(s.name=t.name.trim()),t.role&&(s.role=t.role),t.archetype&&t.archetype.trim()&&(s.archetype=t.archetype.trim()),t.persona&&t.persona.trim()&&(s.persona=t.persona.trim()),t.portrait&&t.portrait.trim()&&(s.portrait=t.portrait.trim()),t.background&&t.background.trim()&&(s.background=t.background.trim()),t.hp!=null&&(s.hp=t.hp),t.max_hp!=null&&(s.max_hp=t.max_hp),t.alive!=null&&(s.alive=t.alive),Array.isArray(t.traits)&&t.traits.length>0&&(s.traits=t.traits),Array.isArray(t.skills)&&t.skills.length>0&&(s.skills=t.skills),Array.isArray(t.inventory)&&t.inventory.length>0&&(s.inventory=t.inventory),t.stats&&Object.keys(t.stats).length>0&&(s.stats=t.stats),n&&(s.idempotency_key=n),Me("/api/v1/trpg/actors/spawn",s,n?{"Idempotency-Key":n}:void 0)}function dd(e,t,n){return Me("/api/v1/trpg/actors/claim",{room_id:e,actor_id:t,keeper:n})}async function ud(e,t,n){const s=await it("trpg.join.eligibility",{room_id:e,actor_id:t,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function pd(e){const t=await it("trpg.mid_join.request",e);return JSON.parse(t)}async function md(e,t){await it("masc_broadcast",{agent_name:e,message:t})}async function vd(e=40){return(await it("masc_messages",{limit:e})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function _d(e,t=20){return it("masc_task_history",{task_id:e,limit:t})}async function fd(e){const t=await it("masc_debate_start",{topic:e});try{return JSON.parse(t)}catch{return null}}async function gd(e){return la("fetchDebateStatus",async()=>{const t=encodeURIComponent(e),n=await ee(`/api/v1/council/debates/${t}/summary`);if(!p(n))return null;const s=p(n.debate)?n.debate:n,a=y(s.id,"").trim(),o=y(s.topic,"").trim();return!a||!o?null:{debate:{id:a,topic:o,status:y(s.status,"open"),created_at:re(s.created_at_iso??s.created_at),closed_at:re(s.closed_at)},arguments:Array.isArray(n.arguments)?n.arguments.flatMap(l=>p(l)?[{index:F(l.index,0),agent:y(l.agent,"unknown"),position:y(l.position,"neutral"),content:y(l.content,""),evidence:Re(l.evidence),reply_to:me(l.reply_to)??null,mentions:Re(l.mentions),archetype:M(l.archetype),created_at:re(l.created_at)}]:[]):[],summary:{support_count:p(n.summary)?F(n.summary.support_count,0):F(n.support_count,0),oppose_count:p(n.summary)?F(n.summary.oppose_count,0):F(n.oppose_count,0),neutral_count:p(n.summary)?F(n.summary.neutral_count,0):F(n.neutral_count,0),total_arguments:p(n.summary)?F(n.summary.total_arguments,0):F(n.total_arguments,0),summary_text:p(n.summary)?y(n.summary.summary_text,""):y(n.summary_text,"")},context:bi(n.context),judgment:Yo(n.judgment)}})}async function $d(e){return la("fetchConsensusSessionSummary",async()=>{const t=encodeURIComponent(e),n=await ee(`/api/v1/council/sessions/${t}/summary`);if(!p(n)||!p(n.session))return null;const s=n.session,a=y(s.id,"").trim(),o=y(s.topic,"").trim();return!a||!o?null:{session:{id:a,topic:o,state:y(s.state,"open"),initiator:y(s.initiator,"system"),quorum:F(s.quorum,0),threshold:F(s.threshold,0),created_at:re(s.created_at),closed_at:re(s.closed_at)},votes:Array.isArray(n.votes)?n.votes.flatMap(l=>p(l)?[{agent:y(l.agent,"unknown"),decision:y(l.decision,"abstain"),reason:y(l.reason,""),timestamp:re(l.timestamp),weight:typeof l.weight=="number"?l.weight:void 0,archetype:M(l.archetype)}]:[]):[],summary:{approve_count:p(n.summary)?F(n.summary.approve_count,0):0,reject_count:p(n.summary)?F(n.summary.reject_count,0):0,abstain_count:p(n.summary)?F(n.summary.abstain_count,0):0,quorum_met:p(n.summary)?Ts(n.summary.quorum_met,!1):!1,result:p(n.summary)?M(n.summary.result):null},context:bi(n.context),judgment:Yo(n.judgment)}})}function hd(e,t,n){return it("masc_keeper_msg",{name:e,message:t})}const yd=_(""),Fe=_({}),ce=_({}),Qa=_({}),Ya=_({}),Xa=_({}),Za=_({}),Ke=_({});function ie(e,t,n){e.value={...e.value,[t]:n}}function bd(e){var n;const t=(n=r(e))==null?void 0:n.toLowerCase();return t==="user"||t==="assistant"||t==="system"||t==="tool"?t:"other"}function kd(e){switch(e){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function $a(e,t){if(!Array.isArray(e))return[];const n=[];for(const s of e){if(!p(s))continue;const a=r(s.name);if(!a)continue;const o=r(s[t]);t==="summary"?n.push({name:a,summary:o}):n.push({name:a,reason:o})}return n}function xd(e){if(!p(e))return null;const t=r(e.name);return t?{name:t,trigger:r(e.trigger),outcome:r(e.outcome),summary:r(e.summary),reason:r(e.reason)}:null}function Sd(e){const t=e.toLowerCase();return t.includes("graphql")?"graphql_error":t.includes("timeout")||t.includes("model")||t.includes("llm")||t.includes("api key")||t.includes("api_key")||t.includes("provider")?"llm_error":"unknown"}function Ad(e,t){return e==="offline"||e==="degraded"||e==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":t==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":t==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":t==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function Zo(e,t,n){return r(e)??Ad(t,n)}function er(e,t){return typeof e=="boolean"?e:t==="recover"}function Rs(e){if(!p(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);return!t||!n||!s?null:{health_state:t,quiet_reason:r(e.quiet_reason)??null,next_action_path:n,last_reply_status:s,last_reply_at:nt(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:er(e.recoverable,n),summary:Zo(e.summary,t,r(e.quiet_reason)??null),keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function tr(e){return p(e)?{hour:d(e.hour),checked:d(e.checked)??0,acted:d(e.acted)??0,acted_names:H(e.acted_names),activity_report:r(e.activity_report),quiet_hours_overridden:K(e.quiet_hours_overridden),skipped_reason:r(e.skipped_reason),acted_rows:$a(e.acted_rows,"summary").map(t=>({name:t.name,summary:t.summary})),passed_rows:$a(e.passed_rows,"reason").map(t=>({name:t.name,reason:t.reason})),skipped_rows:$a(e.skipped_rows,"reason").map(t=>({name:t.name,reason:t.reason})),checkins:Array.isArray(e.checkins)?e.checkins.map(xd).filter(t=>t!==null):[]}:null}function Cd(e){return p(e)?{enabled:K(e.enabled)??!1,interval_s:d(e.interval_s)??0,quiet_start:d(e.quiet_start),quiet_end:d(e.quiet_end),quiet_active:K(e.quiet_active),use_planner:K(e.use_planner),delegate_llm:K(e.delegate_llm),agent_count:d(e.agent_count),agents:H(e.agents),last_tick_ago_s:d(e.last_tick_ago_s)??null,last_tick_ago:r(e.last_tick_ago),total_ticks:d(e.total_ticks),total_checkins:d(e.total_checkins),last_skip_reason:r(e.last_skip_reason)??null,last_tick_result:tr(e.last_tick_result),active_self_heartbeats:H(e.active_self_heartbeats)}:null}function Id(e){return p(e)?{status:e.status,diagnostic:Rs(e.diagnostic)}:null}function Td(e){return p(e)?{recovered:K(e.recovered)??!1,skipped_reason:r(e.skipped_reason)??null,before:Rs(e.before),after:Rs(e.after),down:e.down,up:e.up}:null}function Rd(e,t){var T,x;if(!(e!=null&&e.name))return null;const n=r((T=e.agent)==null?void 0:T.status)??r(e.status)??"unknown",s=r((x=e.agent)==null?void 0:x.error)??null,a=e.presence_keepalive??!0,o=e.keepalive_running??!1,l=e.turn_count??0,c=e.last_turn_ago_s??null,u=e.proactive_enabled??!1,m=e.proactive_cooldown_sec??0,v=e.last_proactive_ago_s??null,f=u&&v!=null?Math.max(0,m-v):null,g=l<=0||c==null?"never":c>900?"stale":"fresh",h=typeof e.last_heartbeat=="string"&&e.last_heartbeat.trim()?e.last_heartbeat:null,k=s??(a&&!o?"keeper keepalive is not running":null),$=n==="offline"||n==="inactive"?"offline":k?"degraded":g==="stale"?"stale":g==="never"?"idle":"healthy",C=k?Sd(k):t!=null&&t.quiet_active&&g!=="fresh"?"quiet_hours":a&&!o?"disabled":l<=0?"never_started":f!=null&&f>0?"min_gap":g==="fresh"||g==="stale"?"no_recent_activity":"unknown",A=$==="offline"||$==="degraded"||$==="stale"?"recover":C==="quiet_hours"?"manual_lodge_poke":C==="unknown"?"probe":"direct_message";return{health_state:$,quiet_reason:C,next_action_path:A,last_reply_status:g,last_reply_at:h,last_reply_preview:null,last_error:k,next_eligible_at_s:f!=null&&f>0?f:null,recoverable:er(void 0,A),summary:Zo(void 0,$,C),keepalive_running:o}}function wd(e,t){if(!p(e))return null;const n=bd(e.role),s=r(e.content)??r(e.preview);if(!s)return null;const a=nt(e.ts_unix)??nt(e.timestamp);return{id:`${n}-${a??"entry"}-${t}`,role:n,label:kd(n),text:s,timestamp:a,delivery:"history"}}function Pd(e,t,n){const s=p(n)?n:null,a=Array.isArray(s==null?void 0:s.history_tail)?s.history_tail.map((o,l)=>wd(o,l)).filter(o=>o!==null):[];return{name:e,diagnostic:Rs(s==null?void 0:s.diagnostic),history:a,rawText:t,rawStatus:n,loadedAt:new Date().toISOString()}}function Zi(e,t){const n=ce.value[e]??[];ce.value={...ce.value,[e]:[...n,t].slice(-50)}}function Ld(e,t){return e.role!==t.role||e.text!==t.text?!1:e.timestamp&&t.timestamp?e.timestamp===t.timestamp:!0}function Nd(e,t){const s=(ce.value[e]??[]).filter(a=>a.delivery!=="history"&&!t.some(o=>Ld(a,o)));ce.value={...ce.value,[e]:[...t,...s].slice(-50)}}function da(e,t){Fe.value={...Fe.value,[e]:t},Nd(e,t.history)}function eo(e,t){const n=Fe.value[e];if(!n)return;const s=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};da(e,{...n,diagnostic:{...s,...t}})}async function ki(){try{await Hn()}catch(e){console.warn("[keeper-runtime] dashboard refresh failed",e)}}function Md(e){yd.value=e.trim()}async function nr(e,t=!1){const n=e.trim();if(!n)return null;if(!t&&Fe.value[n])return Fe.value[n];ie(Qa,n,!0),ie(Ke,n,null);try{const s=await it("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let a=null;try{a=JSON.parse(s)}catch{a=null}const o=Pd(n,s,a);return da(n,o),o}catch(s){const a=s instanceof Error?s.message:`Failed to inspect ${n}`;return ie(Ke,n,a),null}finally{ie(Qa,n,!1)}}async function zd(e,t){const n=e.trim(),s=t.trim();if(!n||!s)return;const a=`local-${Date.now()}`;Zi(n,{id:a,role:"user",label:"You",text:s,timestamp:new Date().toISOString(),delivery:"sending"}),ie(Ya,n,!0),ie(Ke,n,null);try{const o=await hd(n,s);ce.value={...ce.value,[n]:(ce.value[n]??[]).map(l=>l.id===a?{...l,delivery:"delivered"}:l)},Zi(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:o.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),eo(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(o.trim()||"(empty reply)").slice(0,200),last_error:null}),await ki()}catch(o){const l=o instanceof Error?o.message:`Failed to send direct message to ${n}`;throw ce.value={...ce.value,[n]:(ce.value[n]??[]).map(c=>c.id===a?{...c,delivery:"error",error:l}:c)},eo(n,{last_reply_status:"error",last_error:l}),ie(Ke,n,l),o}finally{ie(Ya,n,!1)}}async function Ed(e,t){const n=e.trim();if(!n)return null;ie(Xa,n,!0),ie(Ke,n,null);try{const s=await ca({actor:t,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),a=Id(s.result),o=(a==null?void 0:a.diagnostic)??null;if(o){const l=Fe.value[n];da(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??ce.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ki(),o}catch(s){const a=s instanceof Error?s.message:`Failed to probe ${n}`;throw ie(Ke,n,a),s}finally{ie(Xa,n,!1)}}async function Dd(e,t){const n=e.trim();if(!n)return null;ie(Za,n,!0),ie(Ke,n,null);try{const s=await ca({actor:t,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),a=Td(s.result),o=(a==null?void 0:a.after)??null;if(o){const l=Fe.value[n];da(n,{name:n,diagnostic:o,history:(l==null?void 0:l.history)??ce.value[n]??[],rawText:(l==null?void 0:l.rawText)??"",rawStatus:s.result,loadedAt:new Date().toISOString()})}return await ki(),o}catch(s){const a=s instanceof Error?s.message:`Failed to recover ${n}`;throw ie(Ke,n,a),s}finally{ie(Za,n,!1)}}function ut(e){return(e??"").trim().toLowerCase()}function _e(e){const t=typeof e=="number"?e:Date.parse(e);return Number.isNaN(t)?0:t}function gs(e,t=88){const n=e.replace(/\s+/g," ").trim();return n&&(n.length>t?`${n.slice(0,t-3)}...`:n)}function as(e){return typeof e!="number"||!Number.isFinite(e)||e<0?null:new Date(Date.now()-e*1e3).toISOString()}function dn(e){return e.last_heartbeat??as(e.last_turn_ago_s)??as(e.last_proactive_ago_s)??as(e.last_handoff_ago_s)??as(e.last_compaction_ago_s)}function jd(e){const t=e.title.trim();return t||gs(e.content)}function Od(e){const t=e.generation??"?",n=typeof e.context_ratio=="number"&&Number.isFinite(e.context_ratio)?`${Math.round(e.context_ratio*100)}%`:"?";return e.last_heartbeat?`Heartbeat gen=${t} ctx=${n}`:`Keeper snapshot gen=${t} ctx=${n}`}function qd(e,t,n,s,a={}){var x;const o=ut(e),l=t.filter(R=>ut(R.assignee)===o&&(R.status==="claimed"||R.status==="in_progress")).length,c=n.filter(R=>ut(R.from)===o).sort((R,w)=>_e(w.timestamp)-_e(R.timestamp))[0],u=s.filter(R=>ut(R.agent)===o||ut(R.author)===o).sort((R,w)=>_e(w.timestamp)-_e(R.timestamp))[0],m=(a.boardPosts??[]).filter(R=>ut(R.author)===o).sort((R,w)=>_e(w.updated_at||w.created_at)-_e(R.updated_at||R.created_at))[0],v=(a.keepers??[]).filter(R=>ut(R.name)===o&&dn(R)!==null).sort((R,w)=>_e(dn(w)??0)-_e(dn(R)??0))[0],f=c?_e(c.timestamp):0,g=u?_e(u.timestamp):0,h=m?_e(m.updated_at||m.created_at):0,k=v?_e(dn(v)??0):0,$=a.lastSeen?_e(a.lastSeen):0,C=((x=a.currentTask)==null?void 0:x.trim())||(l>0?`${l} claimed tasks`:null);if(f===0&&g===0&&h===0&&k===0&&$===0)return{activeAssignedCount:l,lastActivityAt:null,lastActivityText:C};const T=[c?{timestamp:c.timestamp,ts:f,text:gs(c.content)}:null,m?{timestamp:m.updated_at||m.created_at,ts:h,text:`Post: ${gs(jd(m))}`}:null,v?{timestamp:dn(v),ts:k,text:Od(v)}:null,u?{timestamp:new Date(u.timestamp).toISOString(),ts:g,text:gs(u.text)}:null].filter(R=>R!==null).sort((R,w)=>w.ts-R.ts)[0];return T&&T.ts>=$?{activeAssignedCount:l,lastActivityAt:T.timestamp,lastActivityText:T.text}:{activeAssignedCount:l,lastActivityAt:a.lastSeen??null,lastActivityText:C??"Presence heartbeat"}}const ze=_([]),Le=_([]),Yt=_([]),Ue=_([]),oe=_(null),Fd=_(null),sr=_(null),ar=_([]),ir=_([]),or=_([]),rr=_([]),lr=_([]),cr=_([]),ei=_(new Map),Cn=_([]),In=_("recent"),Nt=_(!0),dr=_(null),qe=_(""),Ft=_([]),fn=_(!1),ur=_(new Map),xi=_("unknown"),Kt=_(null),ti=_(!1),Tn=_(!1),ni=_(!1),gn=_(!1),Si=_(null),ws=_(!1),Ps=_(null),pr=_(null),si=_(null),Kd=_(null),Ud=_(null),Bd=_(null);xe(()=>ze.value.filter(e=>e.status==="active"||e.status==="busy"||e.status==="listening"||e.status==="idle"));const mr=xe(()=>{const e=Le.value;return{todo:e.filter(t=>t.status==="todo"),inProgress:e.filter(t=>t.status==="in_progress"||t.status==="claimed"),done:e.filter(t=>t.status==="done")}}),vr=xe(()=>{const e=new Map,t=Le.value,n=Yt.value,s=Is.value,a=Cn.value,o=Ue.value;for(const l of ze.value)e.set(l.name.trim().toLowerCase(),qd(l.name,t,n,s,{currentTask:l.current_task,lastSeen:l.last_seen,boardPosts:a,keepers:o}));return e});function Wd(e){var o;const t=((o=e.status)==null?void 0:o.toLowerCase())??"";if(t==="offline"||t==="inactive")return"offline";const n=e.metrics_series;if(!n||n.length===0)return"idle";const s=n[n.length-1];if(!s)return"idle";if(s.is_handoff)return"handoff-imminent";if(s.is_compaction)return"compacting";const a=s.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}xe(()=>{const e=new Map;for(const t of Ue.value)e.set(t.name,Wd(t));return e});const Hd=12e4;function Gd(e,t){const n=t.get(e.name);if(n!=null)return n;const s=e.last_heartbeat?Date.parse(e.last_heartbeat):Number.NaN;if(!Number.isNaN(s))return s;const a=[e.last_turn_ago_s,e.last_proactive_ago_s,e.last_handoff_ago_s,e.last_compaction_ago_s].find(o=>typeof o=="number"&&Number.isFinite(o)&&o>=0);return typeof a=="number"?Date.now()-a*1e3:null}xe(()=>{const e=Date.now(),t=new Set,n=ei.value;for(const s of Ue.value){const a=Gd(s,n);a!=null&&e-a>Hd&&t.add(s.name)}return t});function Jd(e){return e==="dashboard_refresh"||e==="masc/dashboard_refresh"||e.startsWith("goal_")||e.startsWith("masc/goal_")||e.startsWith("mdal_")||e.startsWith("masc/mdal_")||e.startsWith("operator_")||e.startsWith("masc/operator_")||e.startsWith("command_plane_")||e.startsWith("masc/command_plane_")}function _r(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="active"||t==="busy"||t==="listening"||t==="idle"||t==="inactive"||t==="offline"?t:t==="in_progress"||t==="claimed"?"busy":"offline"}function Vd(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="todo"||t==="in_progress"||t==="claimed"||t==="done"||t==="cancelled"?t:t==="inprogress"?"in_progress":"todo"}function Qd(e){if(!p(e))return null;const t=r(e.name);return t?{name:t,agent_type:r(e.agent_type),status:_r(e.status),current_task:r(e.current_task)??null,joined_at:r(e.joined_at),last_seen:r(e.last_seen),capabilities:H(e.capabilities),emoji:r(e.emoji),koreanName:r(e.koreanName)??r(e.korean_name),model:r(e.model),traits:H(e.traits),interests:H(e.interests),activityLevel:d(e.activityLevel)??d(e.activity_level),primaryValue:r(e.primaryValue)??r(e.primary_value)}:null}function Yd(e){if(!p(e))return null;const t=r(e.id),n=r(e.title);return!t||!n?null:{id:t,title:n,status:Vd(e.status),priority:d(e.priority),assignee:r(e.assignee),description:r(e.description),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function Xd(e){if(!p(e))return null;const t=r(e.from)??r(e.from_agent)??"system",n=r(e.content)??"",s=r(e.timestamp)??new Date().toISOString();return{id:r(e.id),seq:d(e.seq),from:t,content:n,timestamp:s,type:r(e.type)}}function Ai(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="ok"||t==="warn"||t==="bad"?t:"ok"}function Zd(e){return p(e)?{active_sessions:d(e.active_sessions),blocked_sessions:d(e.blocked_sessions),active_operations:d(e.active_operations),blocked_operations:d(e.blocked_operations),runtime_pressure:d(e.runtime_pressure),worker_alerts:d(e.worker_alerts),continuity_alerts:d(e.continuity_alerts),priority_items:d(e.priority_items),todo_tasks:d(e.todo_tasks),claimed_tasks:d(e.claimed_tasks),running_tasks:d(e.running_tasks),done_tasks:d(e.done_tasks),cancelled_tasks:d(e.cancelled_tasks),keepers:d(e.keepers)}:null}function Qe(e){if(!p(e))return null;const t=r(e.surface),n=r(e.label),s=r(e.target_type),a=r(e.target_id),o=r(e.focus_kind);return!t||!n||!s||!a||!o?null:{surface:t==="command"?"command":"intervene",label:n,target_type:s,target_id:a,focus_kind:o,operation_id:r(e.operation_id)??null,command_surface:r(e.command_surface)??null}}function eu(e){if(!p(e))return null;const t=r(e.id),n=r(e.kind),s=r(e.summary),a=r(e.target_type),o=r(e.target_id);return!t||!s||!a||!o||n!=="session"&&n!=="operation"?null:{id:t,kind:n,severity:Ai(e.severity),status:r(e.status),summary:s,target_type:a,target_id:o,linked_session_id:r(e.linked_session_id)??null,linked_operation_id:r(e.linked_operation_id)??null,last_seen_at:r(e.last_seen_at)??null,top_handoff:Qe(e.top_handoff),intervene_handoff:Qe(e.intervene_handoff),command_handoff:Qe(e.command_handoff)}}function tu(e){if(!p(e))return null;const t=r(e.session_id),n=r(e.goal);return!t||!n?null:{session_id:t,goal:n,room:r(e.room)??null,status:r(e.status),health:r(e.health),member_names:H(e.member_names),linked_operation_id:r(e.linked_operation_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,runtime_blocker:r(e.runtime_blocker)??null,worker_gap_summary:r(e.worker_gap_summary)??null,last_activity_at:r(e.last_activity_at)??null,last_activity_summary:r(e.last_activity_summary)??null,communication_summary:r(e.communication_summary)??null,active_count:d(e.active_count),required_count:d(e.required_count),top_handoff:Qe(e.top_handoff),intervene_handoff:Qe(e.intervene_handoff),command_handoff:Qe(e.command_handoff)}}function nu(e){if(!p(e))return null;const t=r(e.operation_id),n=r(e.objective);return!t||!n?null:{operation_id:t,objective:n,status:r(e.status),stage:r(e.stage)??null,assigned_unit_id:r(e.assigned_unit_id)??null,assigned_unit_label:r(e.assigned_unit_label)??null,linked_session_id:r(e.linked_session_id)??null,linked_detachment_id:r(e.linked_detachment_id)??null,blocker_summary:r(e.blocker_summary)??null,search_status:r(e.search_status)??null,next_tool:r(e.next_tool)??null,updated_at:r(e.updated_at)??null,top_handoff:Qe(e.top_handoff),command_handoff:Qe(e.command_handoff)}}function to(e){if(!p(e))return null;const t=r(e.name)??r(e.agent_name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="working"&&a!=="watching"&&a!=="quiet"&&a!=="offline"?null:{name:t,agent_name:r(e.agent_name),status:r(e.status),tone:Ai(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,active_task_count:d(e.active_task_count),related_session_id:r(e.related_session_id)??null,related_operation_id:r(e.related_operation_id)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),model:r(e.model)??null,recent_output_preview:r(e.recent_output_preview)??null,recent_event:r(e.recent_event)??null}}function su(e){if(!p(e))return null;const t=r(e.name),n=r(e.note),s=r(e.focus),a=r(e.state);return!t||!n||!s||a!=="healthy"&&a!=="warning"&&a!=="critical"?null:{name:t,agent_name:r(e.agent_name)??null,status:r(e.status),tone:Ai(e.tone),state:a,note:n,focus:s,last_signal_at:r(e.last_signal_at)??null,last_autonomous_action_at:r(e.last_autonomous_action_at)??null,generation:d(e.generation),turn_count:d(e.turn_count),context_ratio:d(e.context_ratio)??null,continuity:r(e.continuity)??null,lifecycle:r(e.lifecycle)??null,related_session_id:r(e.related_session_id)??null,model:r(e.model)??null,emoji:r(e.emoji),korean_name:r(e.korean_name),skill_reason:r(e.skill_reason)??null}}function no(e){if(typeof e.seq=="number"&&Number.isFinite(e.seq))return e.seq;const t=Date.parse(e.timestamp);return Number.isNaN(t)?0:t}function au(e,t){if(t.length===0)return e;const n=new Map;for(const s of e){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}for(const s of t){const a=typeof s.seq=="number"?`seq:${s.seq}`:`ts:${s.timestamp}|from:${s.from}|content:${s.content}`;n.set(a,s)}return[...n.values()].sort((s,a)=>no(s)-no(a)).slice(-500)}function iu(e){return Array.isArray(e)?e.map(t=>{if(!p(t))return null;const n=d(t.ts_unix);if(n==null)return null;const s=p(t.handoff)?t.handoff:null;return{ts:n,context_ratio:d(t.context_ratio)??0,context_tokens:d(t.context_tokens)??0,context_max:d(t.context_max)??0,latency_ms:d(t.latency_ms)??0,generation:d(t.generation)??0,channel:typeof t.channel=="string"?t.channel:"turn",is_handoff:s!=null&&t.handoff_performed===!0,is_compaction:t.compacted===!0,compaction_saved_tokens:d(t.compaction_saved_tokens)??0,compaction_trigger:typeof t.compaction_trigger=="string"?t.compaction_trigger:null,model_used:typeof t.model_used=="string"?t.model_used:"",cost_usd:d(t.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?d(s.new_generation)??null:null}}).filter(t=>t!==null):[]}function so(e){if(!p(e))return null;const t=r(e.health_state),n=r(e.next_action_path),s=r(e.last_reply_status);if(!t||!n||!s)return null;const a=r(e.quiet_reason)??null,o=r(e.summary)??(t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":a==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":a==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":a==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response.");return{health_state:t,quiet_reason:a,next_action_path:n,last_reply_status:s,last_reply_at:nt(e.last_reply_at)??r(e.last_reply_at)??null,last_reply_preview:r(e.last_reply_preview)??null,last_error:r(e.last_error)??null,next_eligible_at_s:d(e.next_eligible_at_s)??null,recoverable:typeof e.recoverable=="boolean"?e.recoverable:n==="recover",summary:o,keepalive_running:typeof e.keepalive_running=="boolean"?e.keepalive_running:void 0}}function ou(e,t){return(Array.isArray(e)?e:p(e)&&Array.isArray(e.keepers)?e.keepers:[]).map(s=>{if(!p(s))return null;const a=p(s.agent)?s.agent:null,o=p(s.context)?s.context:null,l=p(s.metrics_window)?s.metrics_window:void 0,c=r(s.name);if(!c)return null;const u=d(s.context_ratio)??d(o==null?void 0:o.context_ratio),m=r(s.status)??r(a==null?void 0:a.status)??"offline",v=_r(m),f=r(s.model)??r(s.active_model)??r(s.primary_model),g=H(s.skill_secondary),h=o?{source:r(o.source),context_ratio:d(o.context_ratio),context_tokens:d(o.context_tokens),context_max:d(o.context_max),message_count:d(o.message_count),has_checkpoint:typeof o.has_checkpoint=="boolean"?o.has_checkpoint:void 0}:void 0,k=a?{name:r(a.name),exists:typeof a.exists=="boolean"?a.exists:void 0,error:r(a.error),agent_type:r(a.agent_type),status:r(a.status),current_task:r(a.current_task)??null,joined_at:r(a.joined_at),last_seen:r(a.last_seen),last_seen_ago_s:d(a.last_seen_ago_s),capabilities:H(a.capabilities),is_zombie:typeof a.is_zombie=="boolean"?a.is_zombie:void 0}:void 0,$=iu(s.metrics_series),C={name:c,emoji:r(s.emoji),koreanName:r(s.koreanName)??r(s.korean_name),agent_name:r(s.agent_name),trace_id:r(s.trace_id),model:f,primary_model:r(s.primary_model),active_model:r(s.active_model),next_model_hint:r(s.next_model_hint)??null,status:v,presence_keepalive:typeof s.presence_keepalive=="boolean"?s.presence_keepalive:void 0,presence_keepalive_sec:d(s.presence_keepalive_sec),keepalive_running:typeof s.keepalive_running=="boolean"?s.keepalive_running:void 0,proactive_enabled:typeof s.proactive_enabled=="boolean"?s.proactive_enabled:void 0,proactive_idle_sec:d(s.proactive_idle_sec),proactive_cooldown_sec:d(s.proactive_cooldown_sec),last_heartbeat:r(s.last_heartbeat)??r(a==null?void 0:a.last_seen),generation:d(s.generation),turn_count:d(s.turn_count)??d(s.total_turns),keeper_age_s:d(s.keeper_age_s),last_turn_ago_s:d(s.last_turn_ago_s),last_handoff_ago_s:d(s.last_handoff_ago_s),last_compaction_ago_s:d(s.last_compaction_ago_s),last_proactive_ago_s:d(s.last_proactive_ago_s),last_proactive_preview:r(s.last_proactive_preview)??null,context_ratio:u,context_tokens:d(s.context_tokens)??d(o==null?void 0:o.context_tokens),context_max:d(s.context_max)??d(o==null?void 0:o.context_max),context_source:r(s.context_source)??r(o==null?void 0:o.source),context:h,traits:H(s.traits),interests:H(s.interests),primaryValue:r(s.primaryValue)??r(s.primary_value),activityLevel:d(s.activityLevel)??d(s.activity_level),memory_recent_note:r(s.memory_recent_note)??null,recent_input_preview:r(s.recent_input_preview)??null,recent_output_preview:r(s.recent_output_preview)??null,recent_tool_names:H(s.recent_tool_names)??[],conversation_tail_count:d(s.conversation_tail_count),k2k_count:d(s.k2k_count),handoff_count_total:d(s.handoff_count_total)??d(s.trace_history_count),compaction_count:d(s.compaction_count),last_compaction_saved_tokens:d(s.last_compaction_saved_tokens),diagnostic:so(s.diagnostic),skill_primary:r(s.skill_primary)??null,skill_secondary:g,skill_reason:r(s.skill_reason)??null,metrics_series:$.length>0?$:void 0,metrics_window:l,agent:k};return C.diagnostic=so(s.diagnostic)??Rd(C,(t==null?void 0:t.lodge)??null),C}).filter(s=>s!==null)}function ru(e){if(!p(e))return;const t=r(e.release_version),n=nt(e.started_at),s=d(e.uptime_seconds);if(!(!t||!n||s==null))return{release_version:t,commit:r(e.commit)??null,started_at:n,uptime_seconds:s}}function fr(e,t){return p(e)?{...e,generated_at:t??nt(e.generated_at)??void 0,build:ru(e.build),lodge:Cd(e.lodge)??void 0}:null}function gr(e,t){return t?e?{...e,...t,build:t.build??e.build,generated_at:t.generated_at??e.generated_at}:t:e}function lu(e){const t=typeof e=="string"?e.toLowerCase():"";return t==="running"||t==="interrupted"||t==="completed"||t==="stopped"||t==="error"?t:t.startsWith("error")?"error":"running"}function cu(e){if(!p(e))return null;const t=d(e.iteration);if(t==null)return null;const n=d(e.metric_before)??0,s=d(e.metric_after)??n,a=p(e.evidence)?e.evidence:null;return{iteration:t,metric_before:n,metric_after:s,delta:d(e.delta)??s-n,changes:r(e.changes)??"",failed_attempts:r(e.failed_attempts)??"",next_suggestion:r(e.next_suggestion)??"",elapsed_ms:d(e.elapsed_ms)??0,cost_usd:d(e.cost_usd)??null,evidence:a?{worker_engine:(a.worker_engine==="api_tool_loop","api_tool_loop"),worker_model:r(a.worker_model)??"",tool_call_count:d(a.tool_call_count)??0,tool_names:H(a.tool_names)??[],session_id:r(a.session_id)??"",evidence_status:a.evidence_status==="legacy_unverified"?"legacy_unverified":"verified"}:null}}function du(e){var o,l;if(!p(e))return null;const t=r(e.loop_id);if(!t)return null;const n=d(e.baseline_metric)??0,s=Array.isArray(e.history)?e.history.map(cu).filter(c=>c!==null):[],a=d(e.current_metric)??((o=s[0])==null?void 0:o.metric_after)??n;return{loop_id:t,profile:r(e.profile)??"unknown",status:lu(e.status),strict_mode:typeof e.strict_mode=="boolean"?e.strict_mode:void 0,error_message:r(e.error_message)??r(e.error_reason)??null,stop_reason:r(e.stop_reason)??r(e.reason)??null,current_iteration:d(e.current_iteration)??((l=s[0])==null?void 0:l.iteration)??0,max_iterations:d(e.max_iterations)??0,baseline_metric:n,current_metric:a,target:r(e.target)??"",stagnation_streak:d(e.stagnation_streak)??0,stagnation_limit:d(e.stagnation_limit)??0,elapsed_seconds:d(e.elapsed_seconds)??0,updated_at:nt(e.updated_at)??null,stopped_at:nt(e.stopped_at)??null,execution_mode:e.execution_mode==="worker_spawn"?"worker_spawn":void 0,worker_engine:e.worker_engine==="api_tool_loop"?"api_tool_loop":null,worker_model:r(e.worker_model)??null,evidence_policy:e.evidence_policy==="hard"||e.evidence_policy==="legacy"?e.evidence_policy:void 0,latest_tool_call_count:d(e.latest_tool_call_count)??0,latest_tool_names:H(e.latest_tool_names)??[],session_id:r(e.session_id)??null,evidence_status:e.evidence_status==="legacy_unverified"?"legacy_unverified":e.evidence_status==="verified"?"verified":null,durability:e.durability==="persistent_backend"||e.durability==="memory_only"?e.durability:void 0,persistence_backend:e.persistence_backend==="filesystem"||e.persistence_backend==="postgres"||e.persistence_backend==="memory"?e.persistence_backend:void 0,recoverable:typeof e.recoverable=="boolean"?e.recoverable:void 0,history:s}}async function Hn(){ti.value=!0;try{await Promise.all([hr(),ft()]),pr.value=new Date().toISOString()}catch(e){console.error("Dashboard refresh error:",e)}finally{ti.value=!1}}async function $r(){ws.value=!0,Ps.value=null;try{const e=await xc();Si.value=e,Bd.value=new Date().toISOString()}catch(e){Ps.value=e instanceof Error?e.message:"Failed to load dashboard semantics"}finally{ws.value=!1}}function uu(e){var t;return((t=Si.value)==null?void 0:t.surfaces.find(n=>n.id===e))??null}function pu(e){var n;const t=((n=Si.value)==null?void 0:n.surfaces)??[];for(const s of t){const a=s.panels.find(o=>o.id===e);if(a)return a}return null}function mu(e){var s,a;Ft.value=(Array.isArray(e.goals)?e.goals:[]).map(o=>{if(!p(o))return null;const l=r(o.id),c=r(o.title),u=r(o.horizon),m=r(o.status),v=r(o.created_at),f=r(o.updated_at);return!l||!c||!u||!m||!v||!f?null:{id:l,horizon:u,title:c,metric:r(o.metric)??null,target_value:r(o.target_value)??null,due_date:r(o.due_date)??null,priority:d(o.priority)??3,status:m,parent_goal_id:r(o.parent_goal_id)??null,last_review_note:r(o.last_review_note)??null,last_review_at:r(o.last_review_at)??null,created_at:v,updated_at:f}}).filter(o=>o!==null);const t=new Map,n=Array.isArray((s=e.mdal)==null?void 0:s.loops)?e.mdal.loops:[];for(const o of n){const l=du(o);l&&t.set(l.loop_id,l)}ur.value=t,Kt.value=typeof((a=e.mdal)==null?void 0:a.error)=="string"?e.mdal.error:null,xi.value=Kt.value?"error":t.size===0?"idle":"ready"}async function hr(){try{const e=await hc(),t=fr(e.status,e.generated_at);t&&(oe.value=gr(oe.value,t))}catch(e){console.error("Dashboard shell fetch error:",e)}}async function ft(){var e;try{const t=await yc(),n=fr(t.status,t.generated_at),s=(e=oe.value)==null?void 0:e.room;n&&(oe.value=gr(oe.value,n));const a=s!=null&&(n==null?void 0:n.room)!=null&&s!==n.room;ze.value=(Array.isArray(t.agents)?t.agents:[]).map(Qd).filter(l=>l!==null),Le.value=(Array.isArray(t.tasks)?t.tasks:[]).map(Yd).filter(l=>l!==null);const o=(Array.isArray(t.messages)?t.messages:[]).map(Xd).filter(l=>l!==null);Yt.value=a?o:au(Yt.value,o),Ue.value=ou(t.keepers,n??oe.value),sr.value=Zd(t.summary),ar.value=(Array.isArray(t.execution_queue)?t.execution_queue:Array.isArray(t.priority_queue)?t.priority_queue:[]).map(eu).filter(l=>l!==null),ir.value=(Array.isArray(t.session_briefs)?t.session_briefs:[]).map(tu).filter(l=>l!==null),or.value=(Array.isArray(t.operation_briefs)?t.operation_briefs:[]).map(nu).filter(l=>l!==null),rr.value=(Array.isArray(t.worker_support_briefs)?t.worker_support_briefs:Array.isArray(t.worker_briefs)?t.worker_briefs:[]).map(to).filter(l=>l!==null),lr.value=(Array.isArray(t.continuity_briefs)?t.continuity_briefs:[]).map(su).filter(l=>l!==null),cr.value=(Array.isArray(t.offline_worker_briefs)?t.offline_worker_briefs:[]).map(to).filter(l=>l!==null),Fd.value=null,pr.value=new Date().toISOString()}catch(t){console.error("Dashboard execution fetch error:",t)}}async function Ye(){Tn.value=!0;try{const e=await bc(In.value,{excludeSystem:Nt.value});Cn.value=e.posts??[],si.value=new Date().toISOString()}catch(e){console.error("Board fetch error:",e)}finally{Tn.value=!1}}async function Xe(){var e;ni.value=!0;try{const t=qe.value||((e=oe.value)==null?void 0:e.room)||"default";qe.value||(qe.value=t);const n=await ad(t);dr.value=n}catch(t){console.error("TRPG fetch error:",t)}finally{ni.value=!1}}async function Ci(){fn.value=!0,gn.value=!0;try{const e=await Ic();mu(e),Kd.value=new Date().toISOString(),Ud.value=new Date().toISOString()}catch(e){console.error("Planning fetch error:",e),xi.value="error",Kt.value=e instanceof Error?e.message:String(e)}finally{fn.value=!1,gn.value=!1}}async function yr(){return Ci()}let $s=null;function vu(e){$s=e}let hs=null;function _u(e){hs=e}let ys=null;function fu(e){ys=e}const gt={};let ha=null;function pt(e,t,n=500){gt[e]&&clearTimeout(gt[e]),gt[e]=setTimeout(()=>{t(),delete gt[e]},n)}function gu(){const e=Oo.subscribe(t=>{if(t){if(t.type==="keeper_heartbeat"&&t.name){const n=new Map(ei.value);n.set(t.name,t.ts_unix?t.ts_unix*1e3:Date.now()),ei.value=n;return}(t.type==="agent_joined"||t.type==="agent_left")&&pt("execution",ft),Jd(t.type)&&(ha||(ha=setTimeout(()=>{Hn(),hs==null||hs(),ys==null||ys(),ha=null},500))),(t.type.startsWith("task_")||t.type.startsWith("masc/task_"))&&pt("execution",ft),t.type==="broadcast"&&pt("execution",ft),(t.type==="keeper_handoff"||t.type==="keeper_compaction"||t.type==="keeper_guardrail")&&pt("execution",ft),(t.type==="board_post"||t.type==="masc/board_post"||t.type==="board_comment"||t.type==="masc/board_comment")&&pt("board",Ye),t.type.startsWith("decision_")&&pt("council",()=>$s==null?void 0:$s()),(t.type==="mdal_started"||t.type==="mdal_iteration"||t.type==="mdal_completed"||t.type==="mdal_stopped")&&pt("mdal",yr,350)}});return()=>{e();for(const t of Object.keys(gt))clearTimeout(gt[t]),delete gt[t]}}let $n=null;function $u(){$n||($n=setInterval(()=>{tt.value,Hn()},1e4))}function hu(){$n&&(clearInterval($n),$n=null)}function yu({metric:e}){return i`
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
  `}function bu({panel:e}){return i`
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
            ${e.metrics.map(t=>i`<${yu} key=${t.id} metric=${t} />`)}
          </div>`:null}
    </div>
  `}function z({panelId:e,compact:t=!1,label:n="Why"}){const s=pu(e);return s?i`
    <details class="semantic-inline ${t?"compact":""}">
      <summary class="semantic-summary">${n}</summary>
      <${bu} panel=${s} />
    </details>
  `:ws.value?i`<span class="semantic-inline-state">Loading semantics…</span>`:null}function he({surfaceId:e,compact:t=!1}){const n=uu(e);return n?i`
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
  `:ws.value?i`<div class="semantic-surface-card ${t?"compact":""}">Loading semantics…</div>`:Ps.value?i`<div class="semantic-surface-card ${t?"compact":""}">${Ps.value}</div>`:null}function I({title:e,class:t,semanticId:n,testId:s,children:a}){return i`
    <div class="card ${t??""}" data-testid=${s}>
      ${e?i`
            <div class="card-title-row">
              <div class="card-title">${e}</div>
              ${n?i`<${z} panelId=${n} compact=${!0} />`:null}
            </div>
          `:null}
      ${a}
    </div>
  `}function Ii(e){const t=e.indexOf("-");if(t<0)return{model:e,nickname:e,isKeeper:e==="keeper"};const n=e.slice(0,t),s=e.slice(t+1);return{model:n,nickname:s,isKeeper:n==="keeper"}}function ku(e){return e==="keeper"||e.startsWith("keeper-")}const Gn=_(null),ai=_(!1),Ls=_(null),br=_(null),Mt=_(!1),_t=_(null);let Ut=null;function ao(){Ut!==null&&(window.clearTimeout(Ut),Ut=null)}function xu(e=1500){Ut===null&&(Ut=window.setTimeout(()=>{Ut=null,Ns(!1)},e))}function q(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function b(e){return typeof e=="string"&&e.trim()!==""?e:void 0}function N(e){return typeof e=="number"&&Number.isFinite(e)?e:void 0}function Bt(e){return typeof e=="boolean"?e:void 0}function V(e,t=[]){if(Array.isArray(e))return e;if(!q(e))return[];for(const n of t){const s=e[n];if(Array.isArray(s))return s}return[]}function an(e){if(!q(e))return null;const t=b(e.kind),n=b(e.summary),s=b(e.target_type);return!t||!n||!s?null:{kind:t,severity:b(e.severity)??"warn",summary:n,target_type:s,target_id:b(e.target_id)??null,actor:b(e.actor)??null,evidence:e.evidence}}function xt(e){if(!q(e))return null;const t=b(e.action_type),n=b(e.target_type),s=b(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:b(e.target_id)??null,severity:b(e.severity)??"warn",reason:s,confirm_required:Bt(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function Su(e){if(!q(e))return null;const t=b(e.session_id);return t?{session_id:t,goal:b(e.goal),status:b(e.status),health:b(e.health),scale_profile:b(e.scale_profile),control_profile:b(e.control_profile),planned_worker_count:N(e.planned_worker_count),active_agent_count:N(e.active_agent_count),last_turn_age_sec:N(e.last_turn_age_sec)??null,attention_count:N(e.attention_count),recommended_action_count:N(e.recommended_action_count),top_attention:an(e.top_attention),top_recommendation:xt(e.top_recommendation)}:null}function Au(e){if(!q(e))return null;const t=b(e.session_id);if(!t)return null;const n=q(e.status)?e.status:e,s=q(n.summary)?n.summary:void 0;return{session_id:t,status:b(e.status)??b(s==null?void 0:s.status)??(q(n.session)?b(n.session.status):void 0),progress_pct:N(e.progress_pct)??N(s==null?void 0:s.progress_pct),elapsed_sec:N(e.elapsed_sec)??N(s==null?void 0:s.elapsed_sec),remaining_sec:N(e.remaining_sec)??N(s==null?void 0:s.remaining_sec),done_delta_total:N(e.done_delta_total)??N(s==null?void 0:s.done_delta_total),summary:q(e.summary)?e.summary:s,team_health:q(e.team_health)?e.team_health:q(n.team_health)?n.team_health:void 0,communication_metrics:q(e.communication_metrics)?e.communication_metrics:q(n.communication_metrics)?n.communication_metrics:void 0,orchestration_state:q(e.orchestration_state)?e.orchestration_state:q(n.orchestration_state)?n.orchestration_state:void 0,cascade_metrics:q(e.cascade_metrics)?e.cascade_metrics:q(n.cascade_metrics)?n.cascade_metrics:void 0,report_paths:q(e.report_paths)?Object.fromEntries(Object.entries(e.report_paths).map(([a,o])=>{const l=b(o);return l?[a,l]:null}).filter(a=>a!==null)):q(n.report_paths)?Object.fromEntries(Object.entries(n.report_paths).map(([a,o])=>{const l=b(o);return l?[a,l]:null}).filter(a=>a!==null)):void 0,session:q(e.session)?e.session:q(n.session)?n.session:void 0,recent_events:V(e.recent_events,["events"]).filter(q)}}function Cu(e){if(!q(e))return null;const t=b(e.name);return t?{name:t,agent_name:b(e.agent_name),status:b(e.status),autonomy_level:b(e.autonomy_level),context_ratio:N(e.context_ratio),generation:N(e.generation),active_goal_ids:V(e.active_goal_ids).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),last_autonomous_action_at:b(e.last_autonomous_action_at)??null,last_turn_ago_s:N(e.last_turn_ago_s),model:b(e.model)}:null}function Iu(e){if(!q(e))return null;const t=b(e.confirm_token)??b(e.token);return t?{confirm_token:t,actor:b(e.actor),action_type:b(e.action_type),target_type:b(e.target_type),target_id:b(e.target_id)??null,delegated_tool:b(e.delegated_tool),created_at:b(e.created_at),preview:e.preview}:null}function Tu(e){if(!q(e))return null;const t=b(e.action_type),n=b(e.target_type);return!t||!n?null:{action_type:t,target_type:n,description:b(e.description),confirm_required:Bt(e.confirm_required)}}function Ru(e){const t=q(e)?e:{};return{room_health:b(t.room_health),cluster:b(t.cluster),project:b(t.project),current_room:b(t.current_room)??null,paused:Bt(t.paused),tempo_interval_s:N(t.tempo_interval_s),active_agents:N(t.active_agents),keeper_pressure:N(t.keeper_pressure),active_operations:N(t.active_operations),pending_approvals:N(t.pending_approvals),incident_count:N(t.incident_count),recommended_action_count:N(t.recommended_action_count),top_attention:an(t.top_attention),top_action:xt(t.top_action)}}function wu(e){const t=q(e)?e:{},n=q(t.swarm_overview)?t.swarm_overview:{};return{health:b(t.health),active_operations:N(t.active_operations),pending_approvals:N(t.pending_approvals),swarm_overview:{active_lanes:N(n.active_lanes),moving_lanes:N(n.moving_lanes),stalled_lanes:N(n.stalled_lanes),projected_lanes:N(n.projected_lanes),last_movement_at:b(n.last_movement_at)??null},top_attention:an(t.top_attention),top_action:xt(t.top_action),session_cards:V(t.session_cards).map(Su).filter(s=>s!==null)}}function Pu(e){const t=q(e)?e:{};return{sessions:V(t.sessions,["items"]).map(Au).filter(n=>n!==null),keepers:V(t.keepers,["items"]).map(Cu).filter(n=>n!==null),pending_confirms:V(t.pending_confirms).map(Iu).filter(n=>n!==null),available_actions:V(t.available_actions).map(Tu).filter(n=>n!==null)}}function Lu(e){if(!q(e))return null;const t=b(e.id),n=b(e.kind),s=b(e.summary),a=b(e.target_type);return!t||!n||!s||!a?null:{id:t,kind:n,severity:b(e.severity)??"warn",summary:s,target_type:a,target_id:b(e.target_id)??null,top_action:xt(e.top_action),related_session_ids:V(e.related_session_ids).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),related_agent_names:V(e.related_agent_names).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),evidence_preview:V(e.evidence_preview).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),last_seen_at:b(e.last_seen_at)??null}}function Nu(e){if(!q(e))return null;const t=b(e.session_id),n=b(e.goal);return!t||!n?null:{session_id:t,goal:n,room:b(e.room)??null,status:b(e.status),health:b(e.health),member_names:V(e.member_names).map(s=>typeof s=="string"?s.trim():"").filter(Boolean),started_at:b(e.started_at)??null,elapsed_sec:N(e.elapsed_sec)??null,last_event_at:b(e.last_event_at)??null,last_event_summary:b(e.last_event_summary)??null,communication_summary:b(e.communication_summary)??null,active_count:N(e.active_count),required_count:N(e.required_count),related_attention_count:N(e.related_attention_count)??0,top_attention:an(e.top_attention),top_recommendation:xt(e.top_recommendation)}}function Mu(e){if(!q(e))return null;const t=b(e.agent_name);return t?{agent_name:t,status:b(e.status),where:b(e.where)??null,with_whom:V(e.with_whom).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),current_work:b(e.current_work)??null,related_session_id:b(e.related_session_id)??null,related_attention_count:N(e.related_attention_count)??0,recent_output_preview:b(e.recent_output_preview)??null,recent_input_preview:b(e.recent_input_preview)??null,recent_event:b(e.recent_event)??null,recent_tool_names:V(e.recent_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),allowed_tool_names:V(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:V(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:N(e.latest_tool_call_count)??null,tool_audit_source:b(e.tool_audit_source)??null,tool_audit_at:b(e.tool_audit_at)??null}:null}function zu(e){if(!q(e))return null;const t=b(e.name);return t?{name:t,agent_name:b(e.agent_name)??null,status:b(e.status),generation:N(e.generation),context_ratio:N(e.context_ratio)??null,last_turn_ago_s:N(e.last_turn_ago_s)??null,current_work:b(e.current_work)??null,last_autonomous_action_at:b(e.last_autonomous_action_at)??null,allowed_tool_names:V(e.allowed_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_names:V(e.latest_tool_names).map(n=>typeof n=="string"?n.trim():"").filter(Boolean),latest_tool_call_count:N(e.latest_tool_call_count)??null,tool_audit_source:b(e.tool_audit_source)??null,tool_audit_at:b(e.tool_audit_at)??null}:null}function Eu(e){if(!q(e))return null;const t=b(e.id),n=b(e.signal_type),s=b(e.summary),a=b(e.target_type);return!t||!n||!s||!a?null:{id:t,signal_type:n==="action"?"action":"attention",severity:b(e.severity)??"warn",summary:s,target_type:a,target_id:b(e.target_id)??null,attention:an(e.attention),action:xt(e.action)}}function Du(e){const t=q(e)?e:{};return{generated_at:b(t.generated_at),summary:Ru(t.summary),incidents:V(t.incidents).map(an).filter(n=>n!==null),recommended_actions:V(t.recommended_actions).map(xt).filter(n=>n!==null),command_focus:wu(t.command_focus),operator_targets:Pu(t.operator_targets),attention_queue:V(t.attention_queue).map(Lu).filter(n=>n!==null),session_briefs:V(t.session_briefs).map(Nu).filter(n=>n!==null),agent_briefs:V(t.agent_briefs).map(Mu).filter(n=>n!==null),keeper_briefs:V(t.keeper_briefs).map(zu).filter(n=>n!==null),internal_signals:V(t.internal_signals).map(Eu).filter(n=>n!==null)}}function ju(e){if(!q(e))return null;const t=b(e.id),n=b(e.label),s=b(e.summary);if(!t||!n||!s)return null;const a=b(e.status)??"unclear";return{id:t,label:n,status:a==="ok"||a==="healthy"||a==="aligned"||a==="watch"||a==="risk"||a==="unclear"?a:"unclear",summary:s,signal_class:b(e.signal_class)==="metadata_gap"||b(e.signal_class)==="mixed"||b(e.signal_class)==="operational_risk"?b(e.signal_class):void 0,evidence_quality:b(e.evidence_quality)==="strong"||b(e.evidence_quality)==="partial"||b(e.evidence_quality)==="missing"?b(e.evidence_quality):void 0,evidence:V(e.evidence).map(l=>typeof l=="string"?l.trim():"").filter(Boolean)}}function Ou(e){if(!q(e))return null;const t=b(e.kind),n=b(e.summary),s=b(e.scope_type),a=b(e.severity);return!t||!n||!s||!a||s!=="session"&&s!=="keeper"&&s!=="agent"||a!=="info"&&a!=="watch"?null:{kind:t,summary:n,scope_type:s,scope_id:b(e.scope_id)??null,severity:a}}function qu(e){const t=q(e)?e:{},n=q(t.basis)?t.basis:{},s=b(t.status)??"error",a=s==="ok"||s==="pending"||s==="unavailable"||s==="error"?s:"error";return{generated_at:b(t.generated_at),cached:Bt(t.cached),stale:Bt(t.stale),refreshing:Bt(t.refreshing),status:a,summary:b(t.summary)??null,model:b(t.model)??null,ttl_sec:N(t.ttl_sec),criteria:V(t.criteria).map(o=>typeof o=="string"?o.trim():"").filter(Boolean),basis:{current_room:b(n.current_room)??null,crew_count:N(n.crew_count),agent_count:N(n.agent_count),keeper_count:N(n.keeper_count)},metadata_gap_count:N(t.metadata_gap_count),metadata_gaps:V(t.metadata_gaps).map(Ou).filter(o=>o!==null),sections:V(t.sections).map(ju).filter(o=>o!==null),error:b(t.error)??null,last_error:b(t.last_error)??null}}async function kr(){ai.value=!0,Ls.value=null;try{const e=await Sc();Gn.value=Du(e)}catch(e){Ls.value=e instanceof Error?e.message:"Failed to load mission snapshot"}finally{ai.value=!1}}async function Ns(e=!1){Mt.value=!0,_t.value=null;try{const t=await Ac(e),n=qu(t);br.value=n,n.refreshing||n.status==="pending"?xu():ao()}catch(t){_t.value=t instanceof Error?t.message:"Failed to load mission briefing",ao()}finally{Mt.value=!1}}const Ms="masc_dashboard_workflow_context",Fu=900*1e3;function fe(e){return typeof e=="string"&&e.trim()!==""?e.trim():null}function We(e){const t=fe(e);return t||(typeof e=="number"&&Number.isFinite(e)?String(e):null)}function xr(){if(typeof window>"u")return null;try{return window.sessionStorage}catch{return null}}function ii(e){return p(e)?e:null}function Ku(e){if(!e)return null;try{return JSON.stringify(e)}catch{return null}}function Uu(e){if(!e)return null;try{const t=JSON.parse(e);if(!p(t))return null;const n=fe(t.id),s=fe(t.source_surface),a=fe(t.source_label),o=fe(t.summary),l=fe(t.created_at);return!n||s!=="mission"&&s!=="execution"||!a||!o||!l?null:{id:n,source_surface:s,source_label:a,action_type:fe(t.action_type),target_type:fe(t.target_type),target_id:fe(t.target_id),focus_kind:fe(t.focus_kind),operation_id:fe(t.operation_id),command_surface:fe(t.command_surface),summary:o,payload_preview:fe(t.payload_preview),suggested_payload:ii(t.suggested_payload),preview:t.preview??null,evidence:t.evidence??null,created_at:l}}catch{return null}}function Ti(e){const t=Date.parse(e.created_at);return Number.isNaN(t)?!1:Date.now()-t<=Fu}function Bu(){const e=xr(),t=Uu((e==null?void 0:e.getItem(Ms))??null);return t?Ti(t)?t:(e==null||e.removeItem(Ms),null):null}const Sr=_(Bu());function Ar(e){const t=e&&Ti(e)?e:null;Sr.value=t;const n=xr();if(!n)return;if(!t){n.removeItem(Ms);return}const s=Ku(t);s&&n.setItem(Ms,s)}function Wu(e){if(!e)return null;const t=ii(e.suggested_payload);if(t)return t;if(p(e.preview)){const n=ii(e.preview.payload);if(n)return n}return null}function Hu(e){if(!e)return null;const t=We(e.message);if(t)return t;const n=We(e.task_title)??We(e.title),s=We(e.task_description)??We(e.description),a=We(e.reason),o=We(e.priority)??We(e.task_priority);return n&&s?`${n} · ${s}`:n&&o?`${n} · P${o}`:n||s||a||null}function Ri(e,t,n,s,a,o,l,c){return[e,t,n??"action",s??"target",a??"room",o??"focus",l??"operation",c].join(":")}function on(e,t,n="상황판 추천 액션"){const s=new Date().toISOString(),a=Wu(e),o=(e==null?void 0:e.target_type)??(t==null?void 0:t.target_type)??null,l=(e==null?void 0:e.target_id)??(t==null?void 0:t.target_id)??null,c=(t==null?void 0:t.kind)??(e==null?void 0:e.action_type)??null,u=(e==null?void 0:e.reason)??(t==null?void 0:t.summary)??n;return{id:Ri("mission",n,(e==null?void 0:e.action_type)??null,o,l,c,null,s),source_surface:"mission",source_label:n,action_type:(e==null?void 0:e.action_type)??null,target_type:o,target_id:l,focus_kind:c,operation_id:null,command_surface:null,summary:u,payload_preview:Hu(a),suggested_payload:a,preview:(e==null?void 0:e.preview)??null,evidence:(t==null?void 0:t.evidence)??null,created_at:s}}function Gu({targetType:e,targetId:t,focusKind:n,sourceLabel:s="Execution 진단",summary:a,operationId:o=null,commandSurface:l=null}){const c=new Date().toISOString();return{id:Ri("execution",s,null,e,t,n,o,c),source_surface:"execution",source_label:s,action_type:null,target_type:e,target_id:t,focus_kind:n,operation_id:o,command_surface:l,summary:a,payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:c}}function Ju(e,t){return(t.source==="mission"||t.source==="execution")&&(t.action_type??null)===(e.action_type??null)&&(t.target_type??null)===(e.target_type??null)&&(t.target_id??null)===(e.target_id??null)&&(t.focus_kind??null)===(e.focus_kind??null)&&(t.operation_id??null)===(e.operation_id??null)}function Jn(e){const{params:t}=e;if(t.source!=="mission"&&t.source!=="execution")return null;const n=Sr.value;if(n&&Ti(n)&&Ju(n,t))return n;const s=new Date().toISOString(),a=t.source==="execution"?"execution":"mission";return{id:Ri(a,a==="execution"?"Execution 이어보기":"상황판 이어보기",t.action_type??null,t.target_type??null,t.target_id??null,t.focus_kind??null,t.operation_id??null,s),source_surface:a,source_label:a==="execution"?"Execution 이어보기":"상황판 이어보기",action_type:t.action_type??null,target_type:t.target_type??null,target_id:t.target_id??null,focus_kind:t.focus_kind??t.action_type??null,operation_id:t.operation_id??null,command_surface:t.surface??null,summary:a==="execution"?t.focus_kind?`${t.focus_kind} 기준으로 열린 execution 컨텍스트입니다.`:"Execution에서 이어진 컨텍스트입니다.":t.focus_kind?`${t.focus_kind} 기준으로 열린 컨텍스트입니다.`:"상황판에서 이어진 컨텍스트입니다.",payload_preview:null,suggested_payload:null,preview:null,evidence:null,created_at:s}}function Cr(e){return{source:e.source_surface,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function Ir(e){if(e.command_surface)return e.command_surface;const t=[e.focus_kind,e.summary,e.action_type].filter(n=>typeof n=="string"&&n.trim()!=="").join(" ").toLowerCase();return t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"summary":t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")||t.includes("swarm")?"swarm":e.focus_kind==="operation"||e.target_type==="operation"?"operations":e.target_type==="room"?"summary":"swarm"}function Tr(e){return{source:e.source_surface,surface:Ir(e),...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function Vu(e){return Cr(e)}function Qu(e){return Tr(e)}function wi(e){return e!=null&&e.target_type?e.target_id?`${e.target_type} · ${e.target_id}`:e.target_type:"대상 정보 없음"}function ua(e){switch(e){case"broadcast":return"room 방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"task_inject":return"room 작업 주입";case"team_turn":return"session 업데이트";case"team_note":return"session 노트";case"team_broadcast":return"session 방송";case"team_task_inject":return"session 작업";case"team_stop":return"session 중지";case"keeper_msg":case"keeper_message":return"keeper 메시지";case"keeper_probe":return"keeper probe";case"keeper_recover":return"keeper recover";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(e==null?void 0:e.trim())||"추천 액션"}}function Yu(e){switch(e){case"warroom":return"워룸";case"summary":return"요약";case"swarm":return"스웜";case"chains":return"체인";case"topology":return"토폴로지";case"alerts":return"알림";case"trace":return"트레이스";case"control":return"제어";case"operations":return"작전";default:return(e==null?void 0:e.trim())||"지휘"}}const Je=_(null),Oe=_(null);function Y(e,t=120){const n=(e??"").replace(/\s+/g," ").trim();return n?n.length>t?`${n.slice(0,t-1)}…`:n:null}function de(e){return e==="bad"||e==="offline"||e==="critical"||e==="risk"?"bad":e==="warn"||e==="pending"||e==="degraded"||e==="interrupted"||e==="watch"?"warn":"ok"}function bt(e){if(!e)return"방금";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}s 전`:n<3600?`${Math.round(n/60)}m 전`:n<86400?`${Math.round(n/3600)}h 전`:`${Math.round(n/86400)}d 전`}function Xu(e){return typeof e!="number"||!Number.isFinite(e)||e<0?"n/a":e<60?`${Math.round(e)}s`:e<3600?`${Math.round(e/60)}m`:e<86400?`${Math.round(e/3600)}h`:`${Math.round(e/86400)}d`}function Zu(e){return e!=null&&e.confirm_required?"확인 후 실행":"즉시 실행"}function ep(e){return wi(e?on(e,null,"상황판 추천 액션"):null)}function pa(e,t=on()){Ar(t),ue(e,e==="intervene"?Vu(t):Qu(t))}function Rr(e){pa("intervene",on(null,e,"상황판 incident"))}function wr(e){pa("command",on(null,e,"상황판 incident"))}function Pi(e,t,n="상황판 추천 액션"){pa("intervene",on(e,t,n))}function Pr(e,t,n="상황판 추천 액션"){pa("command",on(e,t,n))}function io(e,t){const n={source:"mission",target_type:"team_session",target_id:t,focus_kind:"team_session"};e==="command"&&(n.surface="swarm"),ue(e,n)}function tp(e){return{kind:e.kind,severity:e.severity,summary:e.summary,target_type:e.target_type,target_id:e.target_id??null,actor:null,evidence:e.evidence_preview}}function Lr(e,t){const n=e.trim().toLowerCase();return[...t].filter(s=>(s.from??"").trim().toLowerCase()===n).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function np(e){return e.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")}function sp(e,t){if(!t)return!1;const n=np(t);return new RegExp(`(?:^|[^a-z0-9_])@${n}(?![a-z0-9_-])`,"i").test(e)}function ap(e,t){const n=e.trim().toLowerCase();return[...t].filter(s=>{if((s.from??"").trim().toLowerCase()===n)return!1;const o=(s.content??"").trim().toLowerCase();return sp(o,n)}).sort((s,a)=>Date.parse(a.timestamp)-Date.parse(s.timestamp))[0]??null}function ip(e){return Ue.value.find(t=>t.agent_name===e||t.name===e)??null}function Nr(e){return ze.value.find(t=>t.name===e)??null}function Mr(e,t){const n=Y(e,100);if(!n)return null;const s=t.find(o=>o.id===n);if(s)return`${s.id} · ${Y(s.title,92)}`;const a=t.find(o=>o.title===n);return a?`${a.id} · ${Y(a.title,92)}`:n}function op(e){var c,u;const t=Nr(e.agent_name),n=ip(e.agent_name),s=Lr(e.agent_name,Yt.value),a=ap(e.agent_name,Yt.value),o=Ii(e.agent_name),l=(n==null?void 0:n.skill_primary)??(t!=null&&t.capabilities&&t.capabilities.length>0?t.capabilities.slice(0,3).join(", "):null)??o.model??(t==null?void 0:t.agent_type)??null;return{brief:e,agent:t,keeper:n,where:e.where??"room",withWhom:e.with_whom,currentWork:e.current_work??Mr((t==null?void 0:t.current_task)??null,Le.value)??"명시된 current task 없음",how:l,recentInput:Y(e.recent_input_preview,120)??Y(a==null?void 0:a.content,120)??Y(n==null?void 0:n.recent_input_preview,120)??null,recentOutput:Y(e.recent_output_preview,120)??Y(s==null?void 0:s.content,120)??Y(n==null?void 0:n.recent_output_preview,120)??Y((c=n==null?void 0:n.diagnostic)==null?void 0:c.last_reply_preview,120)??null,recentEvent:Y(e.recent_event,120)??Y((u=n==null?void 0:n.diagnostic)==null?void 0:u.summary,120)??null,recentTools:e.recent_tool_names.length>0?e.recent_tool_names:(n==null?void 0:n.recent_tool_names)??[]}}function rp(e){var n,s;const t=Ue.value.find(a=>a.name===e.name||a.agent_name===e.agent_name)??null;return{brief:e,keeper:t,currentWork:Y(e.current_work,110)??Y(t==null?void 0:t.skill_primary,110)??Y(t==null?void 0:t.last_proactive_reason,110)??"명시된 keeper focus 없음",recentInput:Y(t==null?void 0:t.recent_input_preview,120)??null,recentOutput:Y(t==null?void 0:t.recent_output_preview,120)??Y((n=t==null?void 0:t.diagnostic)==null?void 0:n.last_reply_preview,120)??Y(t==null?void 0:t.last_proactive_preview,120)??null,recentEvent:Y(t==null?void 0:t.last_proactive_reason,120)??Y((s=t==null?void 0:t.diagnostic)==null?void 0:s.summary,120)??null,recentTools:(t==null?void 0:t.recent_tool_names)??[]}}function lp(){const e=Gn.value;return e?new Map(e.session_briefs.map(t=>[t.session_id,t])):new Map}function cp(e){const t=Nr(e),n=Lr(e,Yt.value),s=Ii(e);return{name:e,model:s.model,nickname:s.nickname,currentTask:Mr((t==null?void 0:t.current_task)??null,Le.value)??"agent snapshot 없음",output:Y(n==null?void 0:n.content,96)}}function dp(e){Je.value=Je.value===e?null:e,Oe.value=null}function zr(e){Oe.value=Oe.value===e?null:e}function up(){Je.value=null,Oe.value=null}function ot({status:e,label:t}){return i`
    <span class="status-badge ${e}">
      <span class="status-dot-inline ${e}"></span>
      ${t??e}
    </span>
  `}function Er(e){const t=Date.now(),n=typeof e=="number"?e<1e12?e*1e3:e:new Date(e).getTime(),s=Math.floor((t-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const o=Math.floor(a/60);return o<24?`${o}h ago`:`${Math.floor(o/24)}d ago`}function B({timestamp:e}){const t=Er(e),n=typeof e=="string"?e:new Date(e<1e12?e*1e3:e).toISOString();return i`<span class="time-ago" title=${n}>${t}</span>`}let pp=0;const $t=_([]);function P(e,t="success",n=4e3){const s=++pp;$t.value=[...$t.value,{id:s,message:e,type:t}],setTimeout(()=>{$t.value=$t.value.filter(a=>a.id!==s)},n)}function mp(e){$t.value=$t.value.filter(t=>t.id!==e)}function vp(){const e=$t.value;return e.length===0?null:i`
    <div class="toast-container">
      ${e.map(t=>i`
        <div key=${t.id} class="toast ${t.type}" onClick=${()=>mp(t.id)}>
          ${t.message}
        </div>
      `)}
    </div>
  `}const _p="masc_dashboard_agent_name",rn=_(null),zs=_(!1),Rn=_(""),Es=_([]),wn=_([]),Wt=_(""),hn=_(!1);function Pn(e){rn.value=e,Li()}function oo(){rn.value=null,Rn.value="",Es.value=[],wn.value=[],Wt.value=""}function fp(){const e=rn.value;return e?ze.value.find(t=>t.name===e)??null:null}function Dr(e){return e?Le.value.filter(t=>t.assignee===e):[]}function jr(e){return e?Ue.value.find(t=>t.agent_name===e||t.name===e)??null:null}function gp(e){if(!e)return null;const t=Gn.value;return t?t.agent_briefs.find(n=>n.agent_name===e)??null:null}function $p(e){if(!e)return[];const t=e.metrics_window;return(Array.isArray(t==null?void 0:t.top_tools)?t.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function hp(e){const t=jr(e);return t?t.recent_tool_names&&t.recent_tool_names.length>0?t.recent_tool_names:[]:[]}async function Li(){const e=rn.value;if(e){zs.value=!0,Rn.value="",Es.value=[],wn.value=[];try{const t=await vd(80);Es.value=t.filter(a=>a.includes(e)).slice(0,20);const n=Dr(e).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const o=await _d(a.id,25);return{taskId:a.id,text:o.trim()}}catch(o){const l=o instanceof Error?o.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${l}`}}}));wn.value=s}catch(t){Rn.value=t instanceof Error?t.message:"Failed to load agent detail"}finally{zs.value=!1}}}async function ro(){var s;const e=rn.value,t=Wt.value.trim();if(!e||!t)return;const n=((s=localStorage.getItem(_p))==null?void 0:s.trim())||"dashboard";hn.value=!0;try{await md(n,`@${e} ${t}`),Wt.value="",P(`Mention sent to ${e}`,"success"),Li()}catch(a){const o=a instanceof Error?a.message:"Failed to send mention";P(o,"error")}finally{hn.value=!1}}function yp({task:e}){return i`
    <div class="agent-detail-task">
      <span class="pill">${e.id}</span>
      <span class="agent-detail-task-title">${e.title}</span>
      <${ot} status=${e.status} />
    </div>
  `}function bp({row:e}){return i`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${e.taskId}</span>
      </div>
      <pre class="agent-history-pre">${e.text||"No task history yet"}</pre>
    </div>
  `}function kp(){var A,T,x,R,w,E,J;const e=rn.value;if(!e)return null;const t=fp(),n=jr(e),s=gp(e),a=Dr(e),o=Es.value,l=hp(e),c=$p(n),u=(s==null?void 0:s.allowed_tool_names)??[],m=(s==null?void 0:s.latest_tool_names)??[],v=s==null?void 0:s.latest_tool_call_count,f=s==null?void 0:s.tool_audit_source,g=s==null?void 0:s.tool_audit_at,h=(t==null?void 0:t.capabilities)??[],k=((A=oe.value)==null?void 0:A.room)??"default",$=((T=oe.value)==null?void 0:T.project)??"확인 없음",C=((x=oe.value)==null?void 0:x.cluster)??"확인 없음";return i`
    <div
      class="agent-detail-overlay"
      data-testid="agent-detail-overlay"
      onClick=${D=>{D.target.classList.contains("agent-detail-overlay")&&oo()}}
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
                        <${ot} status=${t.status} />
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
                ${(w=t==null?void 0:t.traits)==null?void 0:w.map(D=>i`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${D}</span>`)}
              </div>
            `:""}
            ${(((E=t==null?void 0:t.interests)==null?void 0:E.length)??0)>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(J=t==null?void 0:t.interests)==null?void 0:J.map(D=>i`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${D}</span>`)}
              </div>
            `:""}
            ${h.length>0?i`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${h.map(D=>i`<span style="font-size:0.7rem;background:#183153;color:#7dd3fc;padding:2px 8px;border-radius:10px">${D}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${t?i`
                    ${t.current_task?i`<span>Task: ${t.current_task}</span>`:null}
                    ${t.last_seen?i`<span>Last seen: <${B} timestamp=${t.last_seen} /></span>`:null}
                    <span>Room: ${k}</span>
                    <span>Project: ${$}</span>
                    <span>Cluster: ${C}</span>
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Li()}} disabled=${zs.value}>
              ${zs.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${oo}>Close</button>
          </div>
        </div>

        ${Rn.value?i`<div class="council-error">${Rn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${I} title="Assigned Tasks">
            ${a.length===0?i`<div class="empty-state">No assigned tasks</div>`:i`<div class="agent-detail-task-list">${a.map(D=>i`<${yp} key=${D.id} task=${D} />`)}</div>`}
          <//>

          <${I} title="Recent Activity">
            ${o.length===0?i`<div class="empty-state">No recent room activity match</div>`:i`<div class="agent-activity-list">${o.map((D,te)=>i`<div key=${te} class="agent-activity-line">${D}</div>`)}</div>`}
          <//>
        </div>

        <${I} title="Capabilities & Tool Audit">
          <div style="display:flex; flex-direction:column; gap:12px;">
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Capabilities</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${h.length>0?h.map(D=>i`<span class="pill">${D}</span>`):i`<span class="empty-state" style="font-size:12px;">No capability metadata</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Allowed tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${u.length>0?u.map(D=>i`<span class="pill">${D}</span>`):i`<span class="empty-state" style="font-size:12px;">No allowlist reported</span>`}
              </div>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Observed tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${m.length>0?m.map(D=>i`<span class="pill">${D}</span>`):i`<span class="empty-state" style="font-size:12px;">No observed tool-use evidence</span>`}
              </div>
            </div>
            <div class="agent-detail-sub">
              <span>Tool calls: ${typeof v=="number"?v:"—"}</span>
              <span>Evidence source: ${f??"unreported"}</span>
              <span>
                Observed at:
                ${g?i` <${B} timestamp=${g} />`:" unreported"}
              </span>
            </div>
            <div>
              <div style="font-size:12px; color:#888; margin-bottom:6px;">Linked keeper recent tools</div>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${l.length>0?l.map(D=>i`<span class="pill">${D}</span>`):i`<span class="empty-state" style="font-size:12px;">No keeper tool telemetry</span>`}
              </div>
            </div>
            ${c.length>0?i`
                  <div>
                    <div style="font-size:12px; color:#888; margin-bottom:6px;">Keeper window top tools</div>
                    <div style="display:flex; flex-wrap:wrap; gap:6px;">
                      ${c.map(D=>i`<span class="pill">${D}</span>`)}
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
          ${wn.value.length===0?i`<div class="empty-state">No task history loaded</div>`:i`<div class="agent-history-list">${wn.value.map(D=>i`<${bp} key=${D.taskId} row=${D} />`)}</div>`}
        <//>

        <${I} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Wt.value}
              onInput=${D=>{Wt.value=D.target.value}}
              onKeyDown=${D=>{D.key==="Enter"&&ro()}}
              disabled=${hn.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{ro()}}
              disabled=${hn.value||Wt.value.trim()===""}
            >
              ${hn.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const ve=_(null),Ni=_(null),Ne=_(null),Ln=_(!1),st=_(null),Nn=_(!1),Xt=_(null),W=_(!1),Ds=_([]);let xp=1;function Sp(e){return p(e)?{id:r(e.id),seq:d(e.seq),from:r(e.from)??r(e.from_agent)??"system",content:r(e.content)??"",timestamp:r(e.timestamp)??new Date().toISOString(),type:r(e.type)}:null}function Ap(e){return p(e)?{room_id:r(e.room_id),current_room:r(e.current_room)??r(e.room),project:r(e.project),cluster:r(e.cluster),paused:K(e.paused),pause_reason:r(e.pause_reason)??null,paused_by:r(e.paused_by)??null,paused_at:r(e.paused_at)??null}:{}}function lo(e){if(!p(e))return;const t=Object.entries(e).map(([n,s])=>{const a=r(s);return a?[n,a]:null}).filter(n=>n!==null);return t.length>0?Object.fromEntries(t):void 0}function Or(e){if(!p(e))return null;const t=r(e.kind),n=r(e.summary),s=r(e.target_type);return!t||!n||!s?null:{kind:t,severity:r(e.severity)??"warn",summary:n,target_type:s,target_id:r(e.target_id)??null,actor:r(e.actor)??null,evidence:e.evidence}}function qr(e){if(!p(e))return null;const t=r(e.action_type),n=r(e.target_type),s=r(e.reason);return!t||!n||!s?null:{action_type:t,target_type:n,target_id:r(e.target_id)??null,severity:r(e.severity)??"warn",reason:s,confirm_required:K(e.confirm_required),suggested_payload:e.suggested_payload,preview:e.preview}}function Cp(e){return p(e)?{actor:r(e.actor)??null,spawn_agent:r(e.spawn_agent)??null,spawn_role:r(e.spawn_role)??null,spawn_model:r(e.spawn_model)??null,worker_class:r(e.worker_class)??null,parent_actor:r(e.parent_actor)??null,capsule_mode:r(e.capsule_mode)??null,runtime_pool:r(e.runtime_pool)??null,lane_id:r(e.lane_id)??null,controller_level:r(e.controller_level)??null,control_domain:r(e.control_domain)??null,supervisor_actor:r(e.supervisor_actor)??null,model_tier:r(e.model_tier)??null,task_profile:r(e.task_profile)??null,risk_level:r(e.risk_level)??null,routing_confidence:d(e.routing_confidence)??null,routing_reason:r(e.routing_reason)??null,status:r(e.status)??"unknown",turn_count:d(e.turn_count)??0,empty_note_turn_count:d(e.empty_note_turn_count)??0,has_turn:K(e.has_turn)??!1,last_turn_ts_iso:r(e.last_turn_ts_iso)??null}:null}function Ip(e){if(!p(e))return null;const t=r(e.session_id);return t?{session_id:t,goal:r(e.goal),status:r(e.status),health:r(e.health),scale_profile:r(e.scale_profile),control_profile:r(e.control_profile),planned_worker_count:d(e.planned_worker_count),active_agent_count:d(e.active_agent_count),last_turn_age_sec:d(e.last_turn_age_sec)??null,attention_count:d(e.attention_count),recommended_action_count:d(e.recommended_action_count),top_attention:Or(e.top_attention),top_recommendation:qr(e.top_recommendation)}:null}function Fr(e){const t=p(e)?e:{};return{trace_id:r(t.trace_id),target_type:r(t.target_type)??"room",target_id:r(t.target_id)??null,health:r(t.health),swarm_status:p(t.swarm_status)?t.swarm_status:void 0,attention_items:Te(t.attention_items).map(Or).filter(n=>n!==null),recommended_actions:Te(t.recommended_actions).map(qr).filter(n=>n!==null),session_cards:Te(t.session_cards).map(Ip).filter(n=>n!==null),worker_cards:Te(t.worker_cards).map(Cp).filter(n=>n!==null)}}function Tp(e){if(!p(e))return null;const t=p(e.status)?e.status:void 0,n=p(e.summary)?e.summary:p(t==null?void 0:t.summary)?t.summary:void 0,s=p(e.session)?e.session:p(t==null?void 0:t.session)?t.session:void 0,a=r(e.session_id)??r(n==null?void 0:n.session_id)??r(s==null?void 0:s.session_id);if(!a)return null;const o=lo(e.report_paths)??lo(t==null?void 0:t.report_paths),l=Te(e.recent_events,["events"]).filter(p);return{session_id:a,status:r(e.status)??r(n==null?void 0:n.status)??r(s==null?void 0:s.status),progress_pct:d(e.progress_pct)??d(n==null?void 0:n.progress_pct),elapsed_sec:d(e.elapsed_sec)??d(n==null?void 0:n.elapsed_sec),remaining_sec:d(e.remaining_sec)??d(n==null?void 0:n.remaining_sec),done_delta_total:d(e.done_delta_total)??d(n==null?void 0:n.done_delta_total),summary:n,team_health:p(e.team_health)?e.team_health:p(t==null?void 0:t.team_health)?t.team_health:void 0,communication_metrics:p(e.communication_metrics)?e.communication_metrics:p(t==null?void 0:t.communication_metrics)?t.communication_metrics:void 0,orchestration_state:p(e.orchestration_state)?e.orchestration_state:p(t==null?void 0:t.orchestration_state)?t.orchestration_state:void 0,cascade_metrics:p(e.cascade_metrics)?e.cascade_metrics:p(t==null?void 0:t.cascade_metrics)?t.cascade_metrics:void 0,report_paths:o,session:s,recent_events:l}}function Rp(e){if(!p(e))return null;const t=r(e.name);if(!t)return null;const n=p(e.context)?e.context:void 0;return{name:t,agent_name:r(e.agent_name),status:r(e.status),autonomy_level:r(e.autonomy_level),context_ratio:d(e.context_ratio)??d(n==null?void 0:n.context_ratio),generation:d(e.generation),active_goal_ids:H(e.active_goal_ids),last_autonomous_action_at:r(e.last_autonomous_action_at)??null,last_turn_ago_s:d(e.last_turn_ago_s),model:r(e.model)??r(e.active_model)??r(e.primary_model)}}function wp(e){if(!p(e))return null;const t=r(e.confirm_token)??r(e.token);return t?{confirm_token:t,actor:r(e.actor),action_type:r(e.action_type),target_type:r(e.target_type),target_id:r(e.target_id)??null,delegated_tool:r(e.delegated_tool),created_at:r(e.created_at),preview:e.preview}:null}function Pp(e){const t=p(e)?e:{};return{room:Ap(t.room),sessions:Te(t.sessions,["items","sessions"]).map(Tp).filter(n=>n!==null),keepers:Te(t.keepers,["items","keepers"]).map(Rp).filter(n=>n!==null),recent_messages:Te(t.recent_messages,["messages"]).map(Sp).filter(n=>n!==null),pending_confirms:Te(t.pending_confirms,["items","confirms"]).map(wp).filter(n=>n!==null),available_actions:Te(t.available_actions,["actions"]).filter(p).map(n=>({action_type:r(n.action_type)??"unknown",target_type:r(n.target_type)??"unknown",description:r(n.description),confirm_required:K(n.confirm_required)}))}}function is(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e)}catch{return String(e)}}function co(e){return e.target_id?`${e.target_type}:${e.target_id}`:e.target_type}function js(e){Ds.value=[{...e,id:xp++,at:new Date().toISOString()},...Ds.value].slice(0,20)}function Kr(e){return e.confirm_required?is(e.preview)||"Confirmation required":is(e.result)||is(e.executed_action)||is(e.delegated_tool_result)||e.status}async function $e(){Ln.value=!0,st.value=null;try{const e=await Tc();ve.value=Pp(e)}catch(e){st.value=e instanceof Error?e.message:"Failed to load operator snapshot"}finally{Ln.value=!1}}async function kt(){Nn.value=!0,Xt.value=null;try{const e=await Wo({targetType:"room"});Ni.value=Fr(e)}catch(e){Xt.value=e instanceof Error?e.message:"Failed to load operator digest"}finally{Nn.value=!1}}async function Zt(e){if(!e){Ne.value=null;return}Nn.value=!0,Xt.value=null;try{const t=await Wo({targetType:"team_session",targetId:e,includeWorkers:!0});Ne.value=Fr(t)}catch(t){Xt.value=t instanceof Error?t.message:"Failed to load session digest"}finally{Nn.value=!1}}async function Ur(e){var t;W.value=!0,st.value=null;try{const n=await ca(e);return js({actor:e.actor,action_type:e.action_type,target_label:co(e),outcome:n.confirm_required?"preview":"executed",message:Kr(n),delegated_tool:n.delegated_tool}),await $e(),await kt(),(t=Ne.value)!=null&&t.target_id&&await Zt(Ne.value.target_id),n}catch(n){const s=n instanceof Error?n.message:"Operator action failed";throw st.value=s,js({actor:e.actor,action_type:e.action_type,target_label:co(e),outcome:"error",message:s}),n}finally{W.value=!1}}async function Br(e,t,n="confirm"){var s;W.value=!0,st.value=null;try{const a=await Ho(e,t,n);return js({actor:e,action_type:n,target_label:t,outcome:"confirmed",message:Kr(a),delegated_tool:a.delegated_tool}),await $e(),await kt(),(s=Ne.value)!=null&&s.target_id&&await Zt(Ne.value.target_id),a}catch(a){const o=a instanceof Error?a.message:"Operator confirmation failed";throw st.value=o,js({actor:e,action_type:"confirm",target_label:t,outcome:"error",message:o}),a}finally{W.value=!1}}fu(()=>{var e;$e(),kt(),(e=Ne.value)!=null&&e.target_id&&Zt(Ne.value.target_id)});function Lp(e){switch(e){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function Np(e){switch(e){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function Mp(e){switch(e.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return e.role}}function uo(e){return e.delivery==="error"||e.delivery==="timeout"?"bad":e.delivery==="sending"?"warn":e.role==="assistant"?"assistant":e.role==="user"?"user":"warn"}function Wr(e){if(!e)return null;const t=new Date(e);return Number.isNaN(t.getTime())?null:t.toLocaleTimeString()}function zp(e){return typeof e!="number"||!Number.isFinite(e)||e<=0?null:e<60?`${Math.round(e)}s`:`${Math.ceil(e/60)}m`}function Hr(e){if(!e)return null;const t=Fe.value[e.name];return(t==null?void 0:t.diagnostic)??e.diagnostic??null}function Ep({keeper:e,showRawStatus:t=!1}){if(ne(()=>{e!=null&&e.name&&nr(e.name)},[e==null?void 0:e.name]),!e)return i`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Fe.value[e.name],s=Hr(e),a=Qa.value[e.name];return i`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(s==null?void 0:s.health_state)??"unknown"}</span>
        <span class="pill">${Lp(s==null?void 0:s.quiet_reason)}</span>
        <span class="pill">next ${Np((s==null?void 0:s.next_action_path)??"direct_message")}</span>
        ${a?i`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(s==null?void 0:s.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(s==null?void 0:s.last_reply_status)??"unknown"}
        ${s!=null&&s.last_reply_at?i` · ${Wr(s.last_reply_at)}`:null}
        ${s!=null&&s.next_eligible_at_s?i` · next eligible ${zp(s.next_eligible_at_s)}`:null}
      </div>
      ${s!=null&&s.last_error?i`<div class="control-status-copy control-error-copy">${s.last_error}</div>`:null}
      ${t?i`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function Dp({keeperName:e,placeholder:t}){const[n,s]=zo("");ne(()=>{e&&nr(e)},[e]);const a=ce.value[e]??[],o=Ya.value[e]??!1,l=Ke.value[e],c=async()=>{const u=n.trim();if(!(!e||!u)){s("");try{await zd(e,u)}catch(m){const v=m instanceof Error?m.message:`Failed to message ${e}`;P(v,"error")}}};return i`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${a.length===0?i`<div class="control-status-copy">No direct keeper conversation yet.</div>`:a.map(u=>i`
              <div class="keeper-conversation-item" key=${u.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${uo(u)}`}>${u.label}</span>
                  <span class=${`keeper-role-chip ${uo(u)}`}>${Mp(u)}</span>
                  ${u.timestamp?i`<span class="keeper-conversation-time">${Wr(u.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${u.text}</div>
                ${u.error?i`<div class="keeper-conversation-error">${u.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${t}
          value=${n}
          onInput=${u=>{s(u.target.value)}}
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
  `}function jp({actor:e,keeper:t,onPokeLodge:n}){if(!t)return null;const s=Hr(t),a=Xa.value[t.name]??!1,o=Za.value[t.name]??!1,l=(s==null?void 0:s.next_action_path)??"direct_message",c=(s==null?void 0:s.recoverable)??l==="recover";return i`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${l==="probe"?"is-active":""}`}
        onClick=${()=>{Ed(t.name,e).catch(u=>{const m=u instanceof Error?u.message:`Failed to probe ${t.name}`;P(m,"error")})}}
        disabled=${a||!e.trim()}
      >
        ${a?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${l==="recover"?"is-active":""}`}
        onClick=${()=>{Dd(t.name,e).catch(u=>{const m=u instanceof Error?u.message:`Failed to recover ${t.name}`;P(m,"error")})}}
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
  `}const Mi=_(null);function Gr(e){Mi.value=e,Md(e.name)}function po(){Mi.value=null}const wt=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function Op(e){if(!e)return 0;const t=wt.findIndex(n=>n.level===e);return t>=0?t:0}function qp({keeper:e}){const t=Op(e.autonomy_level),n=wt[t]??wt[0];if(!n)return null;const s=(t+1)/wt.length*100;return i`
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
            <strong><${B} timestamp=${e.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${e.active_goal_ids&&e.active_goal_ids.length>0?i`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${e.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function bs(e){return e?e>=1e6?`${(e/1e6).toFixed(1)}M`:e>=1e3?`${(e/1e3).toFixed(1)}K`:String(e):"—"}function Fp(e){switch(e){case"keeper_message":return"message";case"keeper_probe":return"probe";case"keeper_recover":return"recover";case"broadcast":return"broadcast";case"room_pause":return"pause";case"room_resume":return"resume";case"lodge_tick":return"lodge";default:return(e==null?void 0:e.trim())||"action"}}function Kp(e){return e.recent_tool_names&&e.recent_tool_names.length>0?e.recent_tool_names:[]}function Up(e){const t=e.metrics_window;return(Array.isArray(t==null?void 0:t.top_tools)?t.top_tools:[]).map(s=>typeof s=="object"&&s!==null&&"tool"in s&&typeof s.tool=="string"?s.tool:null).filter(s=>s!==null)}function Bp(e){const t=Gn.value;return t?t.keeper_briefs.find(n=>n.name===e.name||n.agent_name&&e.agent_name&&n.agent_name===e.agent_name)??null:null}function Wp({keeper:e}){const t=e.metrics_series??[],n=t[t.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:e.generation??"-",hint:"Succession count"},{label:"Turns",value:e.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:e.context_ratio!=null?`${Math.round(e.context_ratio*100)}%`:"-",hint:e.context_ratio!=null&&e.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:e.activityLevel??"-",hint:"Level 0–5"}];return i`
    <div class="keeper-kpis">
      ${a.map(o=>i`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${o.label}</div>
          <div class="keeper-kpi-value">${o.value}</div>
          ${o.hint?i`<div class="keeper-kpi-hint">${o.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${bs(e.context_tokens)}</div>
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
  `}function Hp({keeper:e}){var v,f;const t=e.metrics_series??[];if(t.length<2){const g=(((v=e.context)==null?void 0:v.context_ratio)??0)*100,h=g>85?"#ef4444":g>70?"#f59e0b":"#22c55e";return i`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${g.toFixed(1)}%;background:${h}"></div>
        </div>
        <span class="chart-pct">${g.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,o=t.length,l=t.map((g,h)=>{const k=a+h/(o-1)*(n-2*a),$=s-a-(g.context_ratio??0)*(s-2*a);return{x:k,y:$,p:g}}),c=l.map(({x:g,y:h})=>`${g.toFixed(1)},${h.toFixed(1)}`).join(" "),u=(((f=t[t.length-1])==null?void 0:f.context_ratio)??0)*100,m=u>85?"#ef4444":u>70?"#f59e0b":"#22c55e";return i`
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
      <span class="chart-pct">${u.toFixed(1)}%</span>
    </div>`}const ya=_("");function Gp({keeper:e}){var a,o,l,c;const t=ya.value.toLowerCase(),n=[{title:"Name",key:"name",value:e.name},{title:"Emoji",key:"emoji",value:e.emoji??"-"},{title:"Korean",key:"koreanName",value:e.koreanName??"-"},{title:"Model",key:"model",value:e.model??"-"},{title:"Status",key:"status",value:e.status},{title:"Primary",key:"primaryValue",value:e.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(e.activityLevel??"-")},{title:"Gen",key:"generation",value:String(e.generation??"-")},{title:"Turns",key:"turn_count",value:String(e.turn_count??"-")},{title:"Context",key:"context_ratio",value:e.context_ratio!=null?`${Math.round(e.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:e.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=e.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((o=e.interests)==null?void 0:o.join(", "))||"-"}],s=t?n.filter(u=>u.title.toLowerCase().includes(t)||u.key.includes(t)||u.value.toLowerCase().includes(t)):n;return i`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${ya.value}
        onInput=${u=>{ya.value=u.target.value}}
      />
      ${s.map(u=>i`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${u.title}</span>
          <span class="keeper-field-key">${u.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${u.value}</span>
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
      ${e.context_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${bs(e.context_tokens)}</span></div>`:""}
      ${e.context_max!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${bs(e.context_max)}</span></div>`:""}
      ${e.memory_recent_note?i`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${e.memory_recent_note}</span></div>`:""}
      ${e.k2k_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${e.k2k_count}</span></div>`:""}
      ${e.conversation_tail_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${e.conversation_tail_count}</span></div>`:""}
      ${e.handoff_count_total!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${e.handoff_count_total}</span></div>`:""}
      ${e.compaction_count!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${e.compaction_count}</span></div>`:""}
      ${e.last_compaction_saved_tokens!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${bs(e.last_compaction_saved_tokens)}</span></div>`:""}
      ${((l=e.context)==null?void 0:l.message_count)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${e.context.message_count}</span></div>`:""}
      ${((c=e.context)==null?void 0:c.has_checkpoint)!=null?i`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${e.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Jp({stats:e}){const t=e.max_hp>0?Math.round(e.hp/e.max_hp*100):0,n=e.max_mp>0?Math.round(e.mp/e.max_mp*100):0;return i`
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
  `}function Vp({items:e}){return e.length===0?i`<div class="empty-state" style="font-size:13px">No equipment</div>`:i`
    <div class="keeper-equipment-list">
      ${e.map((t,n)=>i`
        <div class="keeper-equipment-row">
          <span>${t}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Qp({rels:e}){const t=Object.entries(e);return t.length===0?i`<div class="empty-state" style="font-size:13px">No relationships</div>`:i`
    <div class="keeper-k2k-list">
      ${t.map(([n,s])=>i`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function mo({traits:e,label:t}){return e.length===0?null:i`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${t}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${e.map(n=>i`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function ba(e){return e==null||Number.isNaN(e)?"-":`${Math.round(e*100)}%`}function Yp({keeper:e}){const t=e.metrics_window,n=[{label:"Model fallback",value:ba(typeof(t==null?void 0:t.model_fallback_rate)=="number"?t.model_fallback_rate:void 0)},{label:"Proactive fallback",value:ba(typeof(t==null?void 0:t.proactive_fallback_rate)=="number"?t.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:ba(typeof(t==null?void 0:t.memory_pass_rate)=="number"?t.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(t==null?void 0:t.handoff_count)=="number"?t.handoff_count:e.handoff_count_total??"-"},{label:"Compactions",value:typeof(t==null?void 0:t.compaction_events)=="number"?t.compaction_events:e.compaction_count??"-"},{label:"Saved tokens",value:typeof(t==null?void 0:t.compaction_saved_tokens)=="number"?t.compaction_saved_tokens:e.last_compaction_saved_tokens??"-"},{label:"K2K events",value:e.k2k_count??"-"},{label:"Conversation tail",value:e.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(t==null?void 0:t.tool_call_count)=="number"?t.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(t==null?void 0:t.proactive_preview_similarity_avg)=="number"?`${(t.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(t==null?void 0:t.memory_avg_score)=="number"?t.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(t==null?void 0:t.fallback_rate)=="number"?`${(t.fallback_rate*100).toFixed(1)}%`:"-"}];return i`
    <div class="keeper-signal-list">
      ${n.map(s=>i`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function Xp({keeper:e}){var $,C,A,T,x,R,w;const t=(($=ve.value)==null?void 0:$.room)??{},n=(((C=ve.value)==null?void 0:C.available_actions)??[]).filter(E=>E.target_type==="keeper"||E.target_type==="room").slice(0,8),s=Kp(e),a=Up(e),o=Bp(e),l=(o==null?void 0:o.allowed_tool_names)??[],c=(o==null?void 0:o.latest_tool_names)??[],u=o==null?void 0:o.latest_tool_call_count,m=o==null?void 0:o.tool_audit_source,v=o==null?void 0:o.tool_audit_at,f=((A=e.agent)==null?void 0:A.capabilities)??[],g=t.current_room??t.room_id??((T=oe.value)==null?void 0:T.room)??"default",h=t.project??((x=oe.value)==null?void 0:x.project)??"확인 없음",k=t.cluster??((R=oe.value)==null?void 0:R.cluster)??"확인 없음";return i`
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
        <strong>${k}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Current task</span>
        <strong>${((w=e.agent)==null?void 0:w.current_task)??"없음"}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Skill route</span>
        <strong>${e.skill_primary??"미확인"}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Allowed tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${l.length>0?l.map(E=>i`<span class="pill">${E}</span>`):i`<span style="font-size:12px; color:#888;">allowlist 미보고</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Observed tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${c.length>0?c.map(E=>i`<span class="pill">${E}</span>`):i`<span style="font-size:12px; color:#888;">observed tool-use evidence 없음</span>`}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Tool calls</span>
        <strong>${typeof u=="number"?u:"—"}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Evidence source</span>
        <strong>${m??"unreported"}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Observed at</span>
        <strong>${v?i`<${B} timestamp=${v} />`:"unreported"}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Keeper recent tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${s.length>0?s.map(E=>i`<span class="pill">${E}</span>`):i`<span style="font-size:12px; color:#888;">도구 텔레메트리 없음</span>`}
        </div>
      </div>
      ${a.length>0?i`
            <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
              <span style="font-size:12px; color:#888;">Window top tools</span>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${a.map(E=>i`<span class="pill">${E}</span>`)}
              </div>
            </div>
          `:null}
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${f.length>0?f.map(E=>i`<span class="pill">${E}</span>`):i`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${n.length>0?n.map(E=>i`<span class="pill">${Fp(E.action_type)}</span>`):i`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `}function Jr(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(t??n??"dashboard").trim()||"dashboard"}async function Zp(){try{const e=await ca({actor:Jr(),action_type:"lodge_tick",target_type:"room",payload:{}}),t=tr(e.result);await Hn(),t!=null&&t.skipped_reason?P(t.skipped_reason,"warning"):P(t?`Poke finished: ${t.acted}/${t.checked} acted`:"Poke finished",t&&t.acted>0?"success":"warning")}catch(e){const t=e instanceof Error?e.message:"Failed to run Lodge poke";P(t,"error")}}function em({keeper:e}){return i`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${Ep} keeper=${e} />
          <${jp}
            actor=${Jr()}
            keeper=${e}
            onPokeLodge=${()=>{Zp()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${Dp}
            keeperName=${e.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function tm(){var t,n,s;const e=Mi.value;return e?i`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&po()}}
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
            <${ot} status=${e.status} />
            ${e.model?i`<span class="pill">${e.model}</span>`:null}
          </div>
          <button
            onClick=${()=>po()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Wp} keeper=${e} />

        ${""}
        <${Hp} keeper=${e} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${I} title="Field Dictionary">
            <${Gp} keeper=${e} />
          <//>

          ${""}
          <${I} title="Profile">
            <${mo} traits=${e.traits??[]} label="Traits" />
            <${mo} traits=${e.interests??[]} label="Interests" />
            ${e.primaryValue?i`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${e.primaryValue}</span></div>`:null}
            ${e.skill_primary?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${e.skill_primary}</span>
                </div>`:null}
            ${e.skill_reason?i`<div style="font-size:12px; color:#888; margin-top:4px;">${e.skill_reason}</div>`:null}
            ${e.last_heartbeat?i`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${B} timestamp=${e.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${e.autonomy_level?i`
              <${I} title="Autonomy">
                <${qp} keeper=${e} />
              <//>
            `:null}

          ${""}
          ${e.trpg_stats?i`
              <${I} title="TRPG Stats">
                <${Jp} stats=${e.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${e.inventory&&e.inventory.length>0?i`
              <${I} title="Equipment (${e.inventory.length})">
                <${Vp} items=${e.inventory} />
              <//>
            `:null}

          ${""}
          ${e.relationships&&Object.keys(e.relationships).length>0?i`
              <${I} title="Relationships (${Object.keys(e.relationships).length})">
                <${Qp} rels=${e.relationships} />
              <//>
            `:null}

          <${I} title="Runtime Signals">
            <${Yp} keeper=${e} />
          <//>

          <${I} title="Neighborhood & Tool Audit">
            <${Xp} keeper=${e} />
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
        <${em} keeper=${e} />
      </div>
    </div>
  `:null}function nm({cluster:e,project:t,room:n,generatedAt:s}){return i`
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
        <strong>${s?bt(s):"fresh"}</strong>
      </div>
    </div>
  `}function Tt({label:e,value:t,detail:n,tone:s}){return i`
    <article class="mission-stat-card ${de(s)}">
      <span class="mission-stat-label">${e}</span>
      <strong class="mission-stat-value">${t}</strong>
      <small class="mission-stat-detail">${n}</small>
    </article>
  `}function sm(){const e=br.value,t=de((e==null?void 0:e.status)??(_t.value?"bad":"warn")),n=!e||e.sections.length===0,s=(e==null?void 0:e.status)==="error"||(e==null?void 0:e.status)==="unavailable"&&!(e!=null&&e.cached);return i`
    <${I} title="LLM 판단 레이어" class="mission-briefing-card" semanticId="mission.llm_briefing">
      <div class="mission-section-head">
        <h3>heuristic 대신 별도 판단 계층</h3>
        <p>핵심 해석 3줄만 먼저 보여주고, 근거는 접어서 둡니다.</p>
      </div>

      <div class="mission-briefing-meta">
        <span class="command-chip ${t}">
          ${(e==null?void 0:e.status)??(_t.value?"error":"loading")}
        </span>
        ${e!=null&&e.model?i`<span class="command-chip">${e.model}</span>`:null}
        ${e!=null&&e.generated_at?i`<span class="command-chip">${bt(e.generated_at)}</span>`:null}
        ${e!=null&&e.cached?i`<span class="command-chip">cached</span>`:null}
        ${e!=null&&e.stale?i`<span class="command-chip warn">stale</span>`:null}
        ${e!=null&&e.refreshing?i`<span class="command-chip warn">refreshing</span>`:null}
      </div>

      ${_t.value?i`<div class="empty-state error">${_t.value}</div>`:null}
      ${e!=null&&e.error?i`<div class="empty-state error">${e.error}</div>`:null}
      ${e!=null&&e.summary?i`<div class="mission-inline-note">${e.summary}</div>`:null}
      ${e!=null&&e.last_error&&!e.error?i`<div class="mission-inline-note">최근 refresh 실패: ${e.last_error}</div>`:null}

      ${e&&e.sections.length>0?i`
            <div class="mission-briefing-grid">
              ${e.sections.slice(0,3).map(a=>i`
                <article class="mission-briefing-section ${de(a.status)}">
                  <div class="mission-card-head">
                    <strong>${a.label}</strong>
                    <div class="mission-briefing-section-chips">
                      <span class="command-chip ${de(a.status)}">${a.status}</span>
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
          `:!Mt.value&&!_t.value&&n?i`
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
        <button class="control-btn ghost" onClick=${()=>{Ns(s)}} disabled=${Mt.value}>
          ${Mt.value?"응답 기다리는 중…":"판단 다시 읽기"}
        </button>
        <button class="control-btn ghost" onClick=${()=>{Ns(!0)}} disabled=${Mt.value}>
          강제 갱신
        </button>
      </div>
    <//>
  `}function am({item:e,selected:t,sessionLookup:n}){const s=tp(e),a=e.related_session_ids.map(l=>n.get(l)).filter(l=>l!=null),o=e.top_action??null;return i`
    <article class="mission-attention-card ${de((o==null?void 0:o.severity)??e.severity)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>dp(e.id)}>
        <div class="mission-card-head">
          <div>
            <strong>${e.summary}</strong>
            <div class="mission-card-target">${e.kind}${e.target_id?` · ${e.target_id}`:""}</div>
          </div>
          <span class="command-chip ${de((o==null?void 0:o.severity)??e.severity)}">${o?Zu(o):e.severity}</span>
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
            <strong>${e.last_seen_at?bt(e.last_seen_at):"n/a"}</strong>
            <small>${e.target_type}</small>
          </div>
          <div class="mission-fact-tile">
            <span>다음 액션</span>
            <strong>${o?ua(o.action_type):"판단 필요"}</strong>
            <small>${o?ep(o):"추천 액션 없음"}</small>
          </div>
        </div>
      </button>

      ${o?i`<div class="mission-inline-note">${o.reason}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>연결된 흐름 보기</summary>
        ${a.length>0?i`
              <div class="mission-link-list">
                ${a.slice(0,4).map(l=>i`
                  <button class="mission-link-row" onClick=${()=>zr(l.session_id)}>
                    <strong>${l.goal}</strong>
                    <span>${l.status??"unknown"} · ${l.last_event_summary??"최근 사건 없음"}</span>
                  </button>
                `)}
              </div>
            `:i`<div class="empty-state">직접 연결된 session이 아직 없습니다.</div>`}

        ${e.related_agent_names.length>0?i`
              <div class="mission-pill-row">
                ${e.related_agent_names.slice(0,8).map(l=>i`
                  <button class="mission-pill action" onClick=${()=>Pn(l)}>${l}</button>
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
              <button class="control-btn ghost" onClick=${()=>Pi(o,s,"Mission attention")}>
                이 액션으로 개입 열기
              </button>
              <button class="control-btn ghost" onClick=${()=>Pr(o,s,"Mission attention")}>
                원인 보기
              </button>
            `:i`
              <button class="control-btn ghost" onClick=${()=>Rr(s)}>이 이슈로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>wr(s)}>이 이슈의 원인 보기</button>
            `}
      </div>
    </article>
  `}function im({brief:e,selected:t}){var o,l;const n=e.member_names.slice(0,6).map(cp),s=e.top_recommendation??null,a=e.top_attention??null;return i`
    <article class="mission-crew-card ${de(((o=e.top_attention)==null?void 0:o.severity)??e.health??e.status)} ${t?"is-selected":""}">
      <button class="mission-card-select" onClick=${()=>zr(e.session_id)}>
        <div class="mission-card-head">
          <div>
            <strong>${e.goal}</strong>
            <div class="mission-card-target">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          </div>
          <span class="command-chip ${de(((l=e.top_attention)==null?void 0:l.severity)??e.health??e.status)}">${e.status??"unknown"}</span>
        </div>

        <div class="mission-fact-grid">
          <div class="mission-fact-tile">
            <span>멤버</span>
            <strong>${e.member_names.length}</strong>
            <small>${e.member_names.slice(0,3).join(", ")||"n/a"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>가동 시간</span>
            <strong>${Xu(e.elapsed_sec)}</strong>
            <small>${e.started_at?`${bt(e.started_at)} 시작`:"시작 시각 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>커뮤니케이션</span>
            <strong>${e.communication_summary?"요약됨":"n/a"}</strong>
            <small>${e.communication_summary??"요약 없음"}</small>
          </div>
          <div class="mission-fact-tile">
            <span>커버리지</span>
            <strong>${e.active_count??0}/${e.required_count||1}</strong>
            <small>active / required</small>
          </div>
        </div>
      </button>

      <div class="mission-crew-event">
        <span>최근 사건</span>
        <strong>${e.last_event_summary??"최근 session event가 없습니다."}</strong>
        <small>${e.last_event_at?bt(e.last_event_at):"시각 없음"}</small>
      </div>

      ${e.top_attention?i`<div class="mission-inline-note">attention: ${e.top_attention.summary}</div>`:null}

      <details class="mission-card-disclosure">
        <summary>session detail</summary>
        ${n.length>0?i`
              <div class="mission-pill-row">
                ${n.map(c=>i`
                  <button class="mission-pill action" onClick=${()=>Pn(c.name)}>
                    ${c.model!==c.nickname?`${c.model} · `:""}${c.nickname}
                  </button>
                `)}
              </div>
            `:null}

        ${n.length>0?i`
              <details class="mission-card-disclosure compact">
                <summary>member output preview</summary>
                <div class="mission-link-list">
                  ${n.map(c=>i`
                    <button class="mission-link-row" onClick=${()=>Pn(c.name)}>
                      <strong>${c.nickname}</strong>
                      <span>${c.currentTask}</span>
                      <small>${c.output??"최근 출력 없음"}</small>
                    </button>
                  `)}
                </div>
              </details>
            `:null}
      </details>

      <div class="mission-card-actions">
        <button class="control-btn ghost" onClick=${()=>io("intervene",e.session_id)}>세션 개입 열기</button>
        <button class="control-btn ghost" onClick=${()=>io("command",e.session_id)}>세션 원인 보기</button>
        ${s?i`<button class="control-btn ghost" onClick=${()=>Pi(s,a,"Mission session brief")}>추천 액션 열기</button>`:null}
      </div>
    </article>
  `}function om({row:e}){var s,a,o,l,c;const t=Ii(e.brief.agent_name),n=e.withWhom.length>0?e.withWhom.slice(0,3).join(", "):"단독 또는 room-level";return i`
    <article class="mission-activity-card ${de(e.brief.status??((s=e.agent)==null?void 0:s.status))}">
      <button class="mission-card-select" onClick=${()=>Pn(e.brief.agent_name)}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((a=e.agent)==null?void 0:a.emoji)??((o=e.keeper)==null?void 0:o.emoji)??""}</span>
            <div>
              <strong>${e.brief.agent_name}</strong>
              <span>${t.model!==t.nickname?`${t.model} · `:""}${t.nickname}</span>
            </div>
          </div>
          <span class="command-chip ${de(e.brief.status??((l=e.agent)==null?void 0:l.status))}">${e.brief.status??((c=e.agent)==null?void 0:c.status)??"unknown"}</span>
        </div>

        <div class="mission-activity-meta">
          <span>어디서 · ${e.where}</span>
          <span>누구와 · ${n}</span>
          <span>attention · ${e.brief.related_attention_count}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${e.currentWork}</strong>
          ${e.how?i`<small>어떻게 · ${e.how}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>recent trace</summary>
        <div class="mission-activity-foot">
          ${e.recentEvent?i`<span>최근 일 · ${e.recentEvent}</span>`:i`<span>최근 사건 요약 없음</span>`}
          <span>관련 session · ${e.brief.related_session_id??"없음"}</span>
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
            <span>최근 도구 · ${e.recentTools.length>0?e.recentTools.join(", "):"도구 텔레메트리 없음"}</span>
          </div>
        </details>
      </details>
    </article>
  `}function rm({row:e}){var n,s,a,o,l,c,u,m,v,f;const t=[`gen ${e.brief.generation??((n=e.keeper)==null?void 0:n.generation)??0}`,e.brief.context_ratio!=null?`ctx ${Math.round(e.brief.context_ratio*100)}%`:((s=e.keeper)==null?void 0:s.context_ratio)!=null?`ctx ${Math.round(e.keeper.context_ratio*100)}%`:null,e.brief.last_turn_ago_s!=null?`last turn ${Math.round(e.brief.last_turn_ago_s)}s`:null].filter(g=>g!==null).join(" · ");return i`
    <article class="mission-activity-card ${de(e.brief.status??((a=e.keeper)==null?void 0:a.status))}">
      <button class="mission-card-select" onClick=${()=>{e.keeper&&Gr(e.keeper)}}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${((o=e.keeper)==null?void 0:o.emoji)??""}</span>
            <div>
              <strong>${e.brief.name}</strong>
              ${(l=e.keeper)!=null&&l.koreanName?i`<span>${e.keeper.koreanName}</span>`:null}
            </div>
          </div>
          <span class="command-chip ${de(e.brief.status??((c=e.keeper)==null?void 0:c.status))}">${e.brief.status??((u=e.keeper)==null?void 0:u.status)??"unknown"}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 heartbeat · ${(m=e.keeper)!=null&&m.last_heartbeat?bt(e.keeper.last_heartbeat):"n/a"}</span>
          <span>${t||"continuity 정보 없음"}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${e.currentWork}</strong>
          ${(v=e.keeper)!=null&&v.skill_reason?i`<small>판단 요약 · ${Y(e.keeper.skill_reason,120)}</small>`:null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>continuity detail</summary>
        <div class="mission-activity-foot">
          <span>agent · ${e.brief.agent_name??((f=e.keeper)==null?void 0:f.agent_name)??"n/a"}</span>
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
  `}function lm({item:e}){const t=e.action??null,n=e.attention??null;return i`
    <article class="mission-action-card ${de(e.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${de(e.severity)}">
          ${e.signal_type==="action"&&t?ua(t.action_type):(n==null?void 0:n.kind)??"signal"}
        </span>
        <span class="mission-card-target">${e.target_type}${e.target_id?` · ${e.target_id}`:""}</span>
      </div>
      <p>${e.summary}</p>
      ${t?i`<div class="mission-action-preview">${t.reason}</div>`:null}
      <div class="mission-card-actions">
        ${t?i`
              <button class="control-btn ghost" onClick=${()=>Pi(t,n,"Mission internal signal")}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${()=>Pr(t,n,"Mission internal signal")}>이 이슈의 원인 보기</button>
            `:n?i`
                <button class="control-btn ghost" onClick=${()=>Rr(n)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${()=>wr(n)}>이 이슈의 원인 보기</button>
              `:null}
      </div>
    </article>
  `}function vo(){var g,h,k,$,C,A,T;const e=Gn.value;if(ai.value&&!e)return i`<div class="loading-indicator">상황판 스냅샷 불러오는 중...</div>`;if(Ls.value&&!e)return i`<div class="empty-state error">${Ls.value}</div>`;if(!e)return i`<div class="empty-state">상황판 스냅샷이 아직 없습니다.</div>`;Je.value&&!e.attention_queue.some(x=>x.id===Je.value)&&(Je.value=null),Oe.value&&!e.session_briefs.some(x=>x.session_id===Oe.value)&&(Oe.value=null);const t=e.attention_queue.find(x=>x.id===Je.value)??null,n=Oe.value,s=lp(),a=t?new Set(t.related_session_ids):null,o=t?new Set(t.related_agent_names):null,l=(a?e.session_briefs.filter(x=>a.has(x.session_id)):e.session_briefs).slice(0,t?8:6),c=e.agent_briefs.filter(x=>!ku(x.agent_name)).filter(x=>n?x.related_session_id===n:o&&a?o.has(x.agent_name)||(x.related_session_id?a.has(x.related_session_id):!1):!0).slice(0,n||t?10:8).map(op),u=e.keeper_briefs.slice(0,6).map(rp),m=e.attention_queue.slice(0,6),v=e.internal_signals.slice(0,3),f=c.filter(x=>x.recentOutput).length+u.filter(x=>x.recentOutput).length;return i`
    <section class="dashboard-panel mission-view">
      <${he} surfaceId="mission" />
      <div class="panel-header">
        <div>
          <h2>상황판</h2>
          <p>원인 분석과 개입 판단을 먼저 보는 landing 입니다. 문제 → 영향 session → 관련 actor 순서로 좁혀서 읽습니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${de(e.summary.room_health)}">${e.summary.room_health??"ok"}</span>
          <span class="command-chip">${e.summary.project??"room"}${e.summary.current_room?` · ${e.summary.current_room}`:""}</span>
          <span class="command-chip">${e.generated_at?bt(e.generated_at):"fresh"}</span>
        </div>
      </div>

      <${nm}
        cluster=${e.summary.cluster}
        project=${e.summary.project}
        room=${e.summary.current_room}
        generatedAt=${e.generated_at}
      />

      <${sm} />

      <div class="mission-stat-grid">
        <${Tt} label="주의 큐" value=${m.length} detail="개입 판단이 필요한 issue" tone=${((g=m[0])==null?void 0:g.severity)??"ok"} />
        <${Tt} label="영향 session" value=${l.length} detail="현재 선택 기준으로 좁힌 흐름" tone=${((k=(h=l[0])==null?void 0:h.top_attention)==null?void 0:k.severity)??(($=l[0])==null?void 0:$.health)??"ok"} />
        <${Tt} label="영향 agent" value=${c.length} detail="선택된 흐름에 연결된 actor" tone=${((C=c[0])==null?void 0:C.brief.status)??"ok"} />
        <${Tt} label="Keeper watch" value=${u.length} detail="continuity lane 관찰 대상" tone=${((A=u[0])==null?void 0:A.brief.status)??"ok"} />
        <${Tt} label="최근 output" value=${f} detail="선택된 영역에서 바로 읽을 수 있는 출력 수" tone=${f>0?"ok":"warn"} />
        <${Tt} label="내부 신호" value=${v.length} detail="room/system 진단은 하단 보조 lane" tone=${((T=v[0])==null?void 0:T.severity)??"ok"} />
      </div>

      ${t||n?i`
            <div class="mission-selection-bar">
              <span>현재 drill-down · ${t?t.summary:"session 선택"}${n?` · ${n}`:""}</span>
              <button class="control-btn ghost" onClick=${up}>선택 해제</button>
            </div>
          `:null}

      <${I} title="Attention Queue" class="mission-list-card" semanticId="mission.attention_queue">
        <div class="mission-section-head">
          <h3>이슈에서 시작</h3>
          <p>문제와 경고를 먼저 보고, 여기서 session과 agent로 좁혀갑니다.</p>
        </div>
        <div class="mission-lane-stack">
          ${m.length>0?m.map(x=>i`<${am} key=${x.id} item=${x} selected=${Je.value===x.id} sessionLookup=${s} />`):i`<div class="empty-state">지금 Mission attention queue가 비어 있습니다.</div>`}
        </div>
      <//>

      <div class="mission-human-grid">
        <${I} title="Affected Sessions" class="mission-list-card" semanticId="mission.session_briefs">
          <div class="mission-section-head">
            <h3>영향받는 session</h3>
            <p>attention과 직접 연결된 흐름만 먼저 보여주고, member preview는 한 단계 더 열었을 때만 보여줍니다.</p>
          </div>
          <div class="mission-list-stack">
            ${l.length>0?l.map(x=>i`<${im} key=${x.session_id} brief=${x} selected=${Oe.value===x.session_id} />`):i`<div class="empty-state">현재 선택과 연결된 session이 없습니다.</div>`}
          </div>
        <//>

        <${I} title="Impacted Agents" class="mission-list-card" semanticId="mission.agent_activity">
          <div class="mission-section-head">
            <h3>관련 agent</h3>
            <p>선택된 incident 또는 session과 연결된 actor만 보여주고, input-output은 접어서 둡니다.</p>
          </div>
          <div class="mission-activity-list">
            ${c.length>0?c.map(x=>i`<${om} key=${x.brief.agent_name} row=${x} />`):i`<div class="empty-state">현재 선택과 연결된 agent가 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${I} title="Keeper Continuity" class="mission-list-card" semanticId="mission.keeper_activity">
          <div class="mission-section-head">
            <h3>continuity lane</h3>
            <p>keeper는 별도 lane으로 보고, continuity 판단에 필요한 정보만 먼저 보여줍니다.</p>
          </div>
          <div class="mission-activity-list">
            ${u.length>0?u.map(x=>i`<${rm} key=${x.brief.name} row=${x} />`):i`<div class="empty-state">지금 보이는 keeper가 없습니다.</div>`}
          </div>
        <//>

        <${I} title="Internal Signals" class="mission-list-card" semanticId="mission.internal_signals">
          <div class="mission-section-head">
            <h3>room / system 보조 신호</h3>
            <p>artifact scope drift 같은 시스템 진단은 메인 판단 근거가 아니라 보조 lane으로만 유지합니다.</p>
          </div>
          <div class="mission-list-stack">
            ${v.length>0?v.map(x=>i`<${lm} key=${x.id} item=${x} />`):i`<div class="empty-state">지금은 내부 진단 경고가 없습니다.</div>`}
          </div>
          <div class="mission-card-actions">
            <button class="control-btn ghost" onClick=${()=>ue("execution")}>실행 관찰면 보기</button>
            <button class="control-btn ghost" onClick=${()=>ue("command")}>지휘 진단면 보기</button>
          </div>
        <//>
      </div>
    </section>
  `}const Vr=_(null),oi=_(!1),zt=_(null);async function Qr(e,t){oi.value=!0,zt.value=null;try{Vr.value=await Cc(e,t)}catch(n){zt.value=n instanceof Error?n.message:String(n)}finally{oi.value=!1}}const cm="modulepreload",dm=function(e){return"/dashboard/"+e},_o={},um=function(t,n,s){let a=Promise.resolve();if(n&&n.length>0){let l=function(m){return Promise.all(m.map(v=>Promise.resolve(v).then(f=>({status:"fulfilled",value:f}),f=>({status:"rejected",reason:f}))))};document.getElementsByTagName("link");const c=document.querySelector("meta[property=csp-nonce]"),u=(c==null?void 0:c.nonce)||(c==null?void 0:c.getAttribute("nonce"));a=l(n.map(m=>{if(m=dm(m),m in _o)return;_o[m]=!0;const v=m.endsWith(".css"),f=v?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${m}"]${f}`))return;const g=document.createElement("link");if(g.rel=v?"stylesheet":cm,v||(g.as="script"),g.crossOrigin="",g.href=m,u&&g.setAttribute("nonce",u),document.head.appendChild(g),v)return new Promise((h,k)=>{g.addEventListener("load",h),g.addEventListener("error",()=>k(new Error(`Unable to preload CSS for ${m}`)))})}))}function o(l){const c=new Event("vite:preloadError",{cancelable:!0});if(c.payload=l,window.dispatchEvent(c),!c.defaultPrevented)throw l}return a.then(l=>{for(const c of l||[])c.status==="rejected"&&o(c.reason);return t().catch(o)})},zi=_(null),Ee=_(null),Os=_(!1),qs=_(!1),Fs=_(null),Ks=_(null),ri=_(null),Us=_(null),X=_("warroom"),Vn=_(null),li=_(!1),Bs=_(null),St=_(null),Ws=_(!1),Hs=_(null),Qn=_(null),ci=_(!1),Gs=_(null),Mn=_(null),Js=_(!1),zn=_(null),Ht=_(null);let mn=null;function Ei(e){return e!=="summary"&&e!=="swarm"&&e!=="warroom"}function Yr(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,o)=>{e.has(o)||e.set(o,a)}),e}function pm(){const t=Yr().get("run_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function mm(){const t=Yr().get("operation_id")??void 0;return t&&t.trim()!==""?t.trim():void 0}function vm(e){if(p(e))return{policy_class:r(e.policy_class),approval_class:r(e.approval_class),tool_allowlist:H(e.tool_allowlist),model_allowlist:H(e.model_allowlist),requires_human_for:H(e.requires_human_for),autonomy_level:r(e.autonomy_level),escalation_timeout_sec:d(e.escalation_timeout_sec),kill_switch:K(e.kill_switch),frozen:K(e.frozen)}}function _m(e){if(p(e))return{headcount_cap:d(e.headcount_cap),active_operation_cap:d(e.active_operation_cap),max_cost_usd:d(e.max_cost_usd),max_tokens:d(e.max_tokens)}}function Di(e){if(!p(e))return null;const t=r(e.unit_id),n=r(e.label),s=r(e.kind);return!t||!n||!s?null:{unit_id:t,label:n,kind:s,parent_unit_id:r(e.parent_unit_id)??null,leader_id:r(e.leader_id)??null,roster:H(e.roster),capability_profile:H(e.capability_profile),source:r(e.source),created_at:r(e.created_at),updated_at:r(e.updated_at),policy:vm(e.policy),budget:_m(e.budget)}}function Xr(e){if(!p(e))return null;const t=Di(e.unit);return t?{unit:t,leader_status:r(e.leader_status),roster_total:d(e.roster_total),roster_live:d(e.roster_live),active_operation_count:d(e.active_operation_count),health:r(e.health),reasons:H(e.reasons),children:Array.isArray(e.children)?e.children.map(Xr).filter(n=>n!==null):[]}:null}function fm(e){if(p(e))return{total_units:d(e.total_units),company_count:d(e.company_count),platoon_count:d(e.platoon_count),squad_count:d(e.squad_count),leaf_agent_unit_count:d(e.leaf_agent_unit_count),live_agent_count:d(e.live_agent_count),managed_unit_count:d(e.managed_unit_count),active_operation_count:d(e.active_operation_count)}}function Zr(e){const t=p(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),source:r(t.source),summary:fm(t.summary),units:Array.isArray(t.units)?t.units.map(Xr).filter(n=>n!==null):[]}}function gm(e){if(!p(e))return null;const t=r(e.kind),n=r(e.status);return!t||!n?null:{kind:t,chain_id:r(e.chain_id)??null,goal:r(e.goal)??null,run_id:r(e.run_id)??null,status:n,viewer_path:r(e.viewer_path)??null,last_sync_at:r(e.last_sync_at)??null}}function ma(e){if(!p(e))return null;const t=r(e.operation_id),n=r(e.objective),s=r(e.assigned_unit_id),a=r(e.trace_id),o=r(e.status);return!t||!n||!s||!a||!o?null:{operation_id:t,objective:n,assigned_unit_id:s,autonomy_level:r(e.autonomy_level),policy_class:r(e.policy_class),budget_class:r(e.budget_class),detachment_session_id:r(e.detachment_session_id)??null,trace_id:a,checkpoint_ref:r(e.checkpoint_ref)??null,active_goal_ids:H(e.active_goal_ids),note:r(e.note)??null,created_by:r(e.created_by),source:r(e.source),status:o,chain:gm(e.chain),created_at:r(e.created_at),updated_at:r(e.updated_at)}}function $m(e){if(!p(e))return null;const t=ma(e.operation);return t?{operation:t,assigned_unit_label:r(e.assigned_unit_label)}:null}function un(e){if(p(e))return{tone:r(e.tone),pending_ops:d(e.pending_ops),blocked_ops:d(e.blocked_ops),in_flight_ops:d(e.in_flight_ops),pipeline_stalls:d(e.pipeline_stalls),bus_traffic:d(e.bus_traffic),l1_hit_rate:d(e.l1_hit_rate),invalidation_count:d(e.invalidation_count),current_pending:d(e.current_pending),current_in_flight:d(e.current_in_flight),cdb_wakeups:d(e.cdb_wakeups),total_stolen:d(e.total_stolen),avg_best_score:d(e.avg_best_score),avg_candidate_count:d(e.avg_candidate_count),best_first_operations:d(e.best_first_operations),active_sessions:d(e.active_sessions),commit_rate:d(e.commit_rate),total_speculations:d(e.total_speculations)}}function hm(e){if(!p(e))return;const t=p(e.pipeline)?e.pipeline:void 0,n=p(e.cache)?e.cache:void 0,s=p(e.ooo)?e.ooo:void 0,a=p(e.speculative)?e.speculative:void 0,o=p(e.search_fabric)?e.search_fabric:void 0,l=p(e.signals)?e.signals:void 0;return{pipeline:t?{total_ops:d(t.total_ops),completed_ops:d(t.completed_ops),stalled_cycles:d(t.stalled_cycles),hazards_detected:d(t.hazards_detected),forwarding_used:d(t.forwarding_used),pipeline_flushes:d(t.pipeline_flushes),ipc:d(t.ipc)}:void 0,cache:n?{total_reads:d(n.total_reads),total_writes:d(n.total_writes),l1_hit_rate:d(n.l1_hit_rate),invalidation_count:d(n.invalidation_count),writeback_count:d(n.writeback_count),bus_traffic:d(n.bus_traffic)}:void 0,ooo:s?{agent_count:d(s.agent_count),total_added:d(s.total_added),total_issued:d(s.total_issued),total_completed:d(s.total_completed),total_stolen:d(s.total_stolen),cdb_wakeups:d(s.cdb_wakeups),stall_cycles:d(s.stall_cycles),global_cdb_events:d(s.global_cdb_events),current_pending:d(s.current_pending),current_in_flight:d(s.current_in_flight)}:void 0,speculative:a?{total_speculations:d(a.total_speculations),total_commits:d(a.total_commits),total_aborts:d(a.total_aborts),commit_rate:d(a.commit_rate),total_fast_calls:d(a.total_fast_calls),total_cost_usd:d(a.total_cost_usd),active_sessions:d(a.active_sessions)}:void 0,search_fabric:o?{total_operations:d(o.total_operations),best_first_operations:d(o.best_first_operations),legacy_operations:d(o.legacy_operations),blocked_operations:d(o.blocked_operations),ready_operations:d(o.ready_operations),research_pipeline_operations:d(o.research_pipeline_operations),avg_candidate_count:d(o.avg_candidate_count),avg_best_score:d(o.avg_best_score),top_stage:r(o.top_stage)??null}:void 0,signals:l?{issue_pressure:un(l.issue_pressure),cache_contention:un(l.cache_contention),scheduler_efficiency:un(l.scheduler_efficiency),routing_confidence:un(l.routing_confidence),speculative_posture:un(l.speculative_posture)}:void 0}}function el(e){const t=p(e)?e:{},n=p(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),paused:d(n.paused),managed:d(n.managed),projected:d(n.projected)}:void 0,microarch:hm(t.microarch),operations:Array.isArray(t.operations)?t.operations.map($m).filter(s=>s!==null):[]}}function tl(e){if(!p(e))return null;const t=r(e.detachment_id),n=r(e.operation_id),s=r(e.assigned_unit_id);return!t||!n||!s?null:{detachment_id:t,operation_id:n,assigned_unit_id:s,leader_id:r(e.leader_id)??null,roster:H(e.roster),session_id:r(e.session_id)??null,checkpoint_ref:r(e.checkpoint_ref)??null,runtime_kind:r(e.runtime_kind)??null,runtime_ref:r(e.runtime_ref)??null,source:r(e.source),status:r(e.status),last_event_at:r(e.last_event_at)??null,last_progress_at:r(e.last_progress_at)??null,heartbeat_deadline:r(e.heartbeat_deadline)??null,created_at:r(e.created_at),updated_at:r(e.updated_at)}}function ym(e){if(!p(e))return null;const t=tl(e.detachment);return t?{detachment:t,assigned_unit_label:r(e.assigned_unit_label),operation:ma(e.operation)}:null}function nl(e){const t=p(e)?e:{},n=p(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),active:d(n.active),projected:d(n.projected)}:void 0,detachments:Array.isArray(t.detachments)?t.detachments.map(ym).filter(s=>s!==null):[]}}function bm(e){if(!p(e))return null;const t=r(e.decision_id),n=r(e.trace_id),s=r(e.requested_action),a=r(e.scope_type),o=r(e.scope_id);return!t||!n||!s||!a||!o?null:{decision_id:t,trace_id:n,requested_action:s,scope_type:a,scope_id:o,operation_id:r(e.operation_id)??null,target_unit_id:r(e.target_unit_id)??null,requested_by:r(e.requested_by),status:r(e.status),reason:r(e.reason)??null,source:r(e.source),detail:e.detail,created_at:r(e.created_at),decided_at:r(e.decided_at)??null,expires_at:r(e.expires_at)??null}}function sl(e){const t=p(e)?e:{},n=p(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),pending:d(n.pending),approved:d(n.approved),denied:d(n.denied)}:void 0,decisions:Array.isArray(t.decisions)?t.decisions.map(bm).filter(s=>s!==null):[]}}function km(e){if(!p(e))return null;const t=Di(e.unit);return t?{unit:t,roster_total:d(e.roster_total),roster_live:d(e.roster_live),headcount_cap:d(e.headcount_cap),active_operations:d(e.active_operations),active_operation_cap:d(e.active_operation_cap),utilization:d(e.utilization)}:null}function xm(e){const t=p(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),capacity:Array.isArray(t.capacity)?t.capacity.map(km).filter(n=>n!==null):[]}}function Sm(e){if(!p(e))return null;const t=r(e.alert_id);return t?{alert_id:t,severity:r(e.severity),kind:r(e.kind),scope_type:r(e.scope_type),scope_id:r(e.scope_id),title:r(e.title),detail:r(e.detail),timestamp:r(e.timestamp)}:null}function al(e){const t=p(e)?e:{},n=p(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),summary:n?{total:d(n.total),bad:d(n.bad),warn:d(n.warn)}:void 0,alerts:Array.isArray(t.alerts)?t.alerts.map(Sm).filter(s=>s!==null):[]}}function il(e){if(!p(e))return null;const t=r(e.event_id),n=r(e.trace_id),s=r(e.event_type);return!t||!n||!s?null:{event_id:t,trace_id:n,event_type:s,operation_id:r(e.operation_id)??null,unit_id:r(e.unit_id)??null,actor:r(e.actor)??null,source:r(e.source),timestamp:r(e.timestamp),detail:e.detail}}function Am(e){const t=p(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),events:Array.isArray(t.events)?t.events.map(il).filter(n=>n!==null):[]}}function Cm(e){if(!p(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s}}function Im(e){if(!p(e))return null;const t=r(e.lane_id),n=r(e.label),s=r(e.kind),a=r(e.phase),o=r(e.motion_state),l=r(e.source_of_truth),c=r(e.movement_reason),u=r(e.current_step);if(!t||!n||!s||!a||!o||!l||!c||!u)return null;const m=p(e.counts)?e.counts:{};return{lane_id:t,label:n,kind:s,present:K(e.present)??!1,phase:a,motion_state:o,source_of_truth:l,last_movement_at:r(e.last_movement_at)??null,movement_reason:c,current_step:u,blockers:H(e.blockers),counts:{operations:d(m.operations),detachments:d(m.detachments),workers:d(m.workers),approvals:d(m.approvals),alerts:d(m.alerts)},hard_flags:Array.isArray(e.hard_flags)?e.hard_flags.map(Cm).filter(v=>v!==null):[]}}function Tm(e){if(!p(e))return null;const t=r(e.event_id),n=r(e.lane_id),s=r(e.kind),a=r(e.timestamp),o=r(e.title),l=r(e.detail),c=r(e.tone),u=r(e.source);return!t||!n||!s||!a||!o||!l||!c||!u?null:{event_id:t,lane_id:n,kind:s,timestamp:a,title:o,detail:l,tone:c,source:u}}function Rm(e){if(!p(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.summary);return!t||!n||!s?null:{code:t,severity:n,summary:s,lane_ids:H(e.lane_ids),count:d(e.count)??0}}function ol(e){if(!p(e))return;const t=p(e.overview)?e.overview:{},n=p(e.gaps)?e.gaps:{},s=p(e.recommended_next_action)?e.recommended_next_action:void 0;return{generated_at:r(e.generated_at),overview:{active_lanes:d(t.active_lanes),moving_lanes:d(t.moving_lanes),stalled_lanes:d(t.stalled_lanes),projected_lanes:d(t.projected_lanes),last_movement_at:r(t.last_movement_at)??null},lanes:Array.isArray(e.lanes)?e.lanes.map(Im).filter(a=>a!==null):[],timeline:Array.isArray(e.timeline)?e.timeline.map(Tm).filter(a=>a!==null):[],gaps:{count:d(n.count),items:Array.isArray(n.items)?n.items.map(Rm).filter(a=>a!==null):[]},recommended_next_action:s?{tool:r(s.tool)??"masc_operator_snapshot",label:r(s.label)??"Observe operator state",reason:r(s.reason)??"",lane_id:r(s.lane_id)??null}:void 0}}function wm(e){if(!p(e))return;const t=p(e.workers)?e.workers:{},n=K(e.pass);return{status:r(e.status)??"missing",source:r(e.source)??"none",run_id:r(e.run_id)??null,captured_at:r(e.captured_at)??null,...n!==void 0?{pass:n}:{},...d(e.peak_hot_slots)!=null?{peak_hot_slots:d(e.peak_hot_slots)}:{},...d(e.ctx_per_slot)!=null?{ctx_per_slot:d(e.ctx_per_slot)}:{},workers:{expected:d(t.expected),joined:d(t.joined),current_task_bound:d(t.current_task_bound),fresh_heartbeats:d(t.fresh_heartbeats),done:d(t.done),final:d(t.final)},artifact_ref:r(e.artifact_ref)??null,missing_reason:r(e.missing_reason)??null}}function Pm(e){const t=p(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),topology:Zr(t.topology),operations:el(t.operations),detachments:nl(t.detachments),alerts:al(t.alerts),decisions:sl(t.decisions),capacity:xm(t.capacity),traces:Am(t.traces),swarm_status:ol(t.swarm_status)}}function Lm(e){const t=p(e)?e:{},n=Zr(t.topology),s=el(t.operations),a=nl(t.detachments),o=al(t.alerts),l=sl(t.decisions);return{version:r(t.version),generated_at:r(t.generated_at),topology:{version:n.version,generated_at:n.generated_at,source:n.source,summary:n.summary},operations:{version:s.version,generated_at:s.generated_at,summary:s.summary,microarch:s.microarch},detachments:{version:a.version,generated_at:a.generated_at,summary:a.summary},alerts:{version:o.version,generated_at:o.generated_at,summary:o.summary},decisions:{version:l.version,generated_at:l.generated_at,summary:l.summary},swarm_status:ol(t.swarm_status),swarm_proof:wm(t.swarm_proof)}}function Nm(e){return p(e)?{chain_id:r(e.chain_id)??null,started_at:d(e.started_at)??null,progress:d(e.progress)??null,elapsed_sec:d(e.elapsed_sec)??null}:null}function rl(e){if(!p(e))return null;const t=r(e.event);return t?{event:t,chain_id:r(e.chain_id)??null,timestamp:r(e.timestamp)??null,duration_ms:d(e.duration_ms)??null,message:r(e.message)??null,tokens:d(e.tokens)??null}:null}function Mm(e){if(!p(e))return null;const t=ma(e.operation);return t?{operation:t,runtime:Nm(e.runtime),history:rl(e.history),mermaid:r(e.mermaid)??null,preview_run:ll(e.preview_run)}:null}function zm(e){const t=p(e)?e:{};return{status:r(t.status)??"disconnected",base_url:r(t.base_url)??null,message:r(t.message)??null}}function Em(e){const t=p(e)?e:{},n=p(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),connection:zm(t.connection),summary:n?{linked_operations:d(n.linked_operations),active_chains:d(n.active_chains),running_operations:d(n.running_operations),recent_failures:d(n.recent_failures),last_history_event_at:r(n.last_history_event_at)??null}:void 0,operations:Array.isArray(t.operations)?t.operations.map(Mm).filter(s=>s!==null):[],recent_history:Array.isArray(t.recent_history)?t.recent_history.map(rl).filter(s=>s!==null):[]}}function Dm(e){if(!p(e))return null;const t=r(e.id);return t?{id:t,type:r(e.type),status:r(e.status),duration_ms:d(e.duration_ms)??null,error:r(e.error)??null}:null}function ll(e){if(!p(e))return null;const t=r(e.run_id),n=r(e.chain_id);return n?{run_id:t??null,chain_id:n,duration_ms:d(e.duration_ms),success:K(e.success),mermaid:r(e.mermaid),nodes:Array.isArray(e.nodes)?e.nodes.map(Dm).filter(s=>s!==null):[]}:null}function jm(e){const t=p(e)?e:{};return{run:ll(t.run)}}function Om(e){if(!p(e))return null;const t=r(e.title),n=r(e.path);return!t||!n?null:{title:t,path:n}}function qm(e){if(!p(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary);return!t||!n||!s?null:{id:t,title:n,summary:s}}function Fm(e){if(!p(e))return null;const t=r(e.id),n=r(e.title),s=r(e.tool),a=r(e.summary);return!t||!n||!s||!a?null:{id:t,title:n,tool:s,summary:a,success_signals:H(e.success_signals),pitfalls:H(e.pitfalls)}}function Km(e){if(!p(e))return null;const t=r(e.id),n=r(e.title),s=r(e.summary),a=r(e.when_to_use);return!t||!n||!s||!a?null:{id:t,title:n,summary:s,when_to_use:a,steps:Array.isArray(e.steps)?e.steps.map(Fm).filter(o=>o!==null):[]}}function Um(e){if(!p(e))return null;const t=r(e.id),n=r(e.title),s=r(e.description);return!t||!n||!s?null:{id:t,title:n,description:s,tools:H(e.tools)}}function Bm(e){if(!p(e))return null;const t=r(e.id),n=r(e.title),s=r(e.symptom),a=r(e.why),o=r(e.fix_tool),l=r(e.fix_summary);return!t||!n||!s||!a||!o||!l?null:{id:t,title:n,symptom:s,why:a,fix_tool:o,fix_summary:l}}function Wm(e){if(!p(e))return null;const t=r(e.id),n=r(e.title),s=r(e.path_id),a=r(e.transport);return!t||!n||!s||!a?null:{id:t,title:n,path_id:s,transport:a,request:e.request,response:e.response,notes:H(e.notes)}}function Hm(e){const t=p(e)?e:{};return{version:r(t.version),generated_at:r(t.generated_at),docs:Array.isArray(t.docs)?t.docs.map(Om).filter(n=>n!==null):[],concepts:Array.isArray(t.concepts)?t.concepts.map(qm).filter(n=>n!==null):[],golden_paths:Array.isArray(t.golden_paths)?t.golden_paths.map(Km).filter(n=>n!==null):[],tool_groups:Array.isArray(t.tool_groups)?t.tool_groups.map(Um).filter(n=>n!==null):[],pitfalls:Array.isArray(t.pitfalls)?t.pitfalls.map(Bm).filter(n=>n!==null):[],examples:Array.isArray(t.examples)?t.examples.map(Wm).filter(n=>n!==null):[]}}function Gm(e){if(!p(e))return null;const t=r(e.id),n=r(e.title),s=r(e.status),a=r(e.detail),o=r(e.next_tool);return!t||!n||!s||!a||!o?null:{id:t,title:n,status:s,detail:a,next_tool:o}}function Jm(e){if(!p(e))return null;const t=r(e.code),n=r(e.severity),s=r(e.title),a=r(e.detail),o=r(e.next_tool);return!t||!n||!s||!a||!o?null:{code:t,severity:n,title:s,detail:a,next_tool:o}}function Vm(e){if(!p(e))return null;const t=r(e.from),n=r(e.content),s=r(e.timestamp),a=d(e.seq);return!t||!n||!s||a==null?null:{seq:a,from:t,content:n,timestamp:s}}function Qm(e){if(!p(e))return null;const t=r(e.name),n=r(e.role),s=r(e.lane),a=r(e.status),o=r(e.claim_marker),l=r(e.done_marker),c=r(e.final_marker);if(!t||!n||!s||!a||!o||!l||!c)return null;const u=(()=>{if(!p(e.last_message))return null;const m=d(e.last_message.seq),v=r(e.last_message.content),f=r(e.last_message.timestamp);return m==null||!v||!f?null:{seq:m,content:v,timestamp:f}})();return{name:t,role:n,lane:s,joined:K(e.joined)??!1,live_presence:K(e.live_presence)??!1,completed:K(e.completed)??!1,status:a,current_task:r(e.current_task)??null,bound_task_id:r(e.bound_task_id)??null,bound_task_title:r(e.bound_task_title)??null,bound_task_status:r(e.bound_task_status)??null,current_task_matches_run:K(e.current_task_matches_run)??!1,squad_member:K(e.squad_member)??!1,detachment_member:K(e.detachment_member)??!1,last_seen:r(e.last_seen)??null,heartbeat_age_sec:d(e.heartbeat_age_sec)??null,heartbeat_fresh:K(e.heartbeat_fresh)??!1,claim_marker_seen:K(e.claim_marker_seen)??!1,done_marker_seen:K(e.done_marker_seen)??!1,final_marker_seen:K(e.final_marker_seen)??!1,claim_marker:o,done_marker:l,final_marker:c,last_message:u}}function Ym(e){if(!p(e))return;const t=Array.isArray(e.timeline)?e.timeline.map(n=>{if(!p(n))return null;const s=r(n.timestamp),a=d(n.active_slots);if(!s||a==null)return null;const o=Array.isArray(n.active_slot_ids)?n.active_slot_ids.map(l=>typeof l=="number"&&Number.isFinite(l)?l:null).filter(l=>l!=null):[];return{timestamp:s,active_slots:a,active_slot_ids:o}}).filter(n=>n!==null):[];return{slot_url:r(e.slot_url)??null,provider_base_url:r(e.provider_base_url)??null,provider_reachable:K(e.provider_reachable)??null,provider_status_code:d(e.provider_status_code)??null,provider_model_id:r(e.provider_model_id)??null,actual_model_id:r(e.actual_model_id)??null,expected_slots:d(e.expected_slots),actual_slots:d(e.actual_slots),expected_ctx:d(e.expected_ctx),actual_ctx:d(e.actual_ctx),slot_reachable:K(e.slot_reachable)??null,slot_status_code:d(e.slot_status_code)??null,runtime_blocker:r(e.runtime_blocker)??null,detail:r(e.detail)??null,checked_at:r(e.checked_at)??null,total_slots:d(e.total_slots),ctx_per_slot:d(e.ctx_per_slot),active_slots_now:d(e.active_slots_now),peak_active_slots:d(e.peak_active_slots),sample_count:d(e.sample_count),last_sample_at:r(e.last_sample_at)??null,timeline:t}}function Xm(e){if(!p(e))return null;const t=r(e.run_id),n=r(e.status),s=r(e.decided_by),a=r(e.decided_at),o=r(e.reason);if(!t||!n||!s||!a||!o)return null;const l=[];return Array.isArray(e.history)&&e.history.forEach(c=>{if(!p(c))return;const u=r(c.status),m=r(c.decided_by),v=r(c.decided_at),f=r(c.reason);!u||!m||!v||!f||l.push({status:u,decided_by:m,decided_at:v,reason:f,operation_id:r(c.operation_id)??null,detachment_id:r(c.detachment_id)??null,note:r(c.note)??null})}),{run_id:t,status:n,decided_by:s,decided_at:a,reason:o,operation_id:r(e.operation_id)??null,detachment_id:r(e.detachment_id)??null,note:r(e.note)??null,history:l}}function Zm(e){if(!p(e))return null;const t=r(e.run_id),n=r(e.recommended_kind),s=r(e.reason);return!t||!n||!s?null:{run_id:t,recommended_kind:n,continue_available:K(e.continue_available)??!1,rerun_available:K(e.rerun_available)??!1,abandon_available:K(e.abandon_available)??!1,reason:s,evidence:p(e.evidence)?{operation_id:r(e.evidence.operation_id)??null,detachment_id:r(e.evidence.detachment_id)??null,joined_workers:d(e.evidence.joined_workers),current_task_bound:d(e.evidence.current_task_bound),fresh_heartbeats:d(e.evidence.fresh_heartbeats),trace_events:d(e.evidence.trace_events),message_events:d(e.evidence.message_events),runtime_blocker:r(e.evidence.runtime_blocker)??null}:void 0,provenance:r(e.provenance),decision_engine:r(e.decision_engine),authoritative:K(e.authoritative)}}function ev(e){const t=p(e)?e:{},n=p(t.summary)?t.summary:void 0;return{version:r(t.version),generated_at:r(t.generated_at),run_id:r(t.run_id),room_id:r(t.room_id),operation_id:r(t.operation_id)??null,run_resolution:Xm(t.run_resolution),resolution_recommendation:Zm(t.resolution_recommendation),recommended_next_tool:r(t.recommended_next_tool),summary:n?{expected_workers:d(n.expected_workers),joined_workers:d(n.joined_workers),live_workers:d(n.live_workers),squad_roster_size:d(n.squad_roster_size),detachment_roster_size:d(n.detachment_roster_size),current_task_bound:d(n.current_task_bound),fresh_heartbeats:d(n.fresh_heartbeats),claim_markers_seen:d(n.claim_markers_seen),done_markers_seen:d(n.done_markers_seen),final_markers_seen:d(n.final_markers_seen),completed_workers:d(n.completed_workers),peak_hot_slots:d(n.peak_hot_slots),hot_window_ok:K(n.hot_window_ok),pass_hot_concurrency:K(n.pass_hot_concurrency),pass_end_to_end:K(n.pass_end_to_end),pending_decisions:d(n.pending_decisions),pass:K(n.pass)}:void 0,provider:Ym(t.provider),operation:ma(t.operation),squad:Di(t.squad),detachment:tl(t.detachment),workers:Array.isArray(t.workers)?t.workers.map(Qm).filter(s=>s!==null):[],checklist:Array.isArray(t.checklist)?t.checklist.map(Gm).filter(s=>s!==null):[],blockers:Array.isArray(t.blockers)?t.blockers.map(Jm).filter(s=>s!==null):[],recent_messages:Array.isArray(t.recent_messages)?t.recent_messages.map(Vm).filter(s=>s!==null):[],recent_trace_events:Array.isArray(t.recent_trace_events)?t.recent_trace_events.map(il).filter(s=>s!==null):[],truth_notes:H(t.truth_notes)}}function yt(e){X.value=e,Ei(e)&&tv()}async function cl(){Os.value=!0,Fs.value=null;try{const e=await wc();zi.value=Lm(e)}catch(e){Fs.value=e instanceof Error?e.message:"Failed to load command-plane summary"}finally{Os.value=!1}}function ji(e){Ht.value=e}async function Oi(){qs.value=!0,Ks.value=null;try{const e=await Rc();Ee.value=Pm(e)}catch(e){Ks.value=e instanceof Error?e.message:"Failed to load command-plane snapshot"}finally{qs.value=!1}}async function tv(){Ee.value||qs.value||await Oi()}async function Et(){await cl(),Ei(X.value)&&await Oi()}async function Gt(){var e;ci.value=!0,Gs.value=null;try{const t=await Pc(),n=Em(t);Qn.value=n;const s=Ht.value;n.operations.length===0?Ht.value=null:(!s||!n.operations.some(a=>a.operation.operation_id===s))&&(Ht.value=((e=n.operations[0])==null?void 0:e.operation.operation_id)??null)}catch(t){Gs.value=t instanceof Error?t.message:"Failed to load chain summary"}finally{ci.value=!1}}function nv(){mn=null,Mn.value=null,Js.value=!1,zn.value=null}async function sv(e){mn=e,Js.value=!0,zn.value=null;try{const t=await Lc(e);if(mn!==e)return;Mn.value=jm(t)}catch(t){if(mn!==e)return;Mn.value=null,zn.value=t instanceof Error?t.message:"Failed to load chain run"}finally{mn===e&&(Js.value=!1)}}async function av(){li.value=!0,Bs.value=null;try{const e=await Nc();Vn.value=Hm(e)}catch(e){Bs.value=e instanceof Error?e.message:"Failed to load command-plane help"}finally{li.value=!1}}async function Ve(e=pm(),t=mm()){Ws.value=!0,Hs.value=null;try{const n=await Mc(e,t);St.value=ev(n)}catch(n){Hs.value=n instanceof Error?n.message:"Failed to load command-plane swarm view"}finally{Ws.value=!1}}async function rt(e,t,n){ri.value=e,Us.value=null;try{await zc(t,n),await cl(),(Ee.value||Ei(X.value))&&await Oi(),await Ve(),await Gt()}catch(s){throw Us.value=s instanceof Error?s.message:"Failed to execute command-plane action",s}finally{ri.value=null}}function iv(e){return rt(`pause:${e}`,"/api/v1/command-plane/operations/pause",{operation_id:e})}function ov(e){return rt(`resume:${e}`,"/api/v1/command-plane/operations/resume",{operation_id:e})}function rv(e){return rt(`recall:${e}`,"/api/v1/command-plane/dispatch/recall",{operation_id:e})}function lv(e={}){return rt("dispatch:tick","/api/v1/command-plane/dispatch/tick",{...e.operationId?{operation_id:e.operationId}:{},...e.detachmentId?{detachment_id:e.detachmentId}:{}})}function cv(e){return rt(`approve:${e}`,"/api/v1/command-plane/policy/approve",{decision_id:e})}function dv(e){return rt(`deny:${e}`,"/api/v1/command-plane/policy/deny",{decision_id:e})}function uv(e,t){return rt(`freeze:${e}`,"/api/v1/command-plane/policy/freeze",{unit_id:e,enabled:t})}function pv(e,t){return rt(`kill:${e}`,"/api/v1/command-plane/policy/kill-switch",{unit_id:e,enabled:t})}_u(()=>{Et(),Gt(),(X.value==="swarm"||X.value==="warroom"||St.value!==null)&&Ve(),X.value==="warroom"&&$e()});function Vs(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Q(e){if(!e)return"n/a";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.max(0,Math.round((Date.now()-t)/1e3));return n<60?`${n}s ago`:n<3600?`${Math.round(n/60)}m ago`:n<86400?`${Math.round(n/3600)}h ago`:`${Math.round(n/86400)}d ago`}function mv(e){if(!e)return"warn";const t=Date.parse(e);return Number.isNaN(t)?"warn":t<=Date.now()?"bad":"ok"}function dl(e){if(!e)return"n/a";const t=Date.parse(e);if(Number.isNaN(t))return e;const n=Math.round((t-Date.now())/1e3);return n<=0?"expired":n<60?`in ${n}s`:n<3600?`in ${Math.round(n/60)}m`:n<86400?`in ${Math.round(n/3600)}h`:`in ${Math.round(n/86400)}d`}function L(e){return e==="bad"?"bad":e==="warn"||e==="pending"?"warn":"ok"}let fo=!1,vv=0;function _v(){return++vv}let ka=null;async function fv(){ka||(ka=um(()=>import("./mermaid.core-Cg5tZms4.js").then(t=>t.bE),[]).then(t=>t.default));const e=await ka;return fo||(e.initialize({startOnLoad:!1,theme:"dark",securityLevel:"loose"}),fo=!0),e}function Ze(e){if(!e)return"warn";const t=e.toLowerCase();return t.includes("failed")||t.includes("error")||t.includes("disconnected")||t.includes("stopped")?"bad":t.includes("running")||t.includes("active")||t.includes("degraded")||t.includes("pending")?"warn":"ok"}function Yn(e){return typeof e!="number"||!Number.isFinite(e)?"n/a":`${Math.round(e*100)}%`}function vn(e){return typeof e!="number"||!Number.isFinite(e)?"n/a":e<60?`${Math.round(e)}s`:e<3600?`${Math.round(e/60)}m`:`${Math.round(e/3600)}h`}function Xn(e){return typeof e!="number"||!Number.isFinite(e)?0:Math.max(0,Math.min(100,e))}function mt(e,t){return typeof e!="number"||!Number.isFinite(e)||typeof t!="number"||!Number.isFinite(t)||t<=0?0:Xn(e/t*100)}function gv(e,t){const n=Xn(e);return`--gauge-angle:${Math.max(10,Math.round(n/100*360))}deg;--gauge-color:${t};`}function ul(e){if(!e)return"No recent chain history";const t=[e.event];return typeof e.duration_ms=="number"&&t.push(`${e.duration_ms}ms`),typeof e.tokens=="number"&&t.push(`${e.tokens} tokens`),e.message&&t.push(e.message),t.join(" · ")}const $v=[{id:"status",label:"현황"},{id:"history",label:"이력"},{id:"control",label:"통제"}],pl=[{id:"warroom",label:"워룸",group:"status"},{id:"summary",label:"요약",group:"status"},{id:"topology",label:"토폴로지",group:"status"},{id:"swarm",label:"스웜",group:"status"},{id:"operations",label:"작전",group:"history"},{id:"trace",label:"트레이스",group:"history"},{id:"chains",label:"체인",group:"history"},{id:"control",label:"제어",group:"control"},{id:"alerts",label:"알림",group:"control"}],hv=pl.map(e=>e.id),yv=["chain_start","node_start","node_complete","chain_complete","chain_error"],bv={warroom:{title:"라이브 워룸",description:"실제 run, worker, message, trace를 한 화면에서 따라가는 기본 진입 표면입니다."},operations:{title:"현재 작전 상세",description:"활성 operation, detachment, dependency를 먼저 읽는 기본 진입 표면입니다."},swarm:{title:"스웜 실행 흐름",description:"lane 이동, worker 결속, blocker를 따라가며 현장감 있게 보는 표면입니다."},chains:{title:"체인 런타임",description:"체인 연결 상태와 operation별 실행 그래프를 확인하는 표면입니다."},topology:{title:"지휘 계층",description:"company에서 agent까지 지휘 계층과 live roster를 확인합니다."},alerts:{title:"경보 모음",description:"지금 개입을 밀어올리는 alert만 모아서 보는 표면입니다."},trace:{title:"최근 트레이스",description:"operation, actor, unit 단위 이벤트를 시간순으로 보는 표면입니다."},control:{title:"승인과 제어",description:"decision 승인과 unit 제어를 실제로 수행하는 표면입니다."},summary:{title:"지휘 요약",description:"전체 지휘면을 한 번에 훑는 계기판 성격의 요약 표면입니다."}};function go(e){return!!e&&hv.includes(e)}function kv(){const e=j.value.params;return e.source!=="mission"&&e.source!=="execution"?{}:{source:e.source,...e.action_type?{action_type:e.action_type}:{},...e.target_type?{target_type:e.target_type}:{},...e.target_id?{target_id:e.target_id}:{},...e.focus_kind?{focus_kind:e.focus_kind}:{},...e.operation_id?{operation_id:e.operation_id}:{}}}function ml(e){const t=kv();if(e==="operations")return t;if(e==="chains"){const n=Ht.value;return n?{...t,surface:e,operation:n}:{...t,surface:e}}return{...t,surface:e}}function xv(){const e=new URLSearchParams(window.location.search),t=new URLSearchParams,n=e.get("agent")??e.get("agent_name"),s=e.get("token");return n&&t.set("agent",n),s&&t.set("token",s),t.toString()?`/api/v1/chains/events?${t.toString()}`:"/api/v1/chains/events"}function Sv(e){switch(e){case"company":return"중대 / Company";case"platoon":return"소대 / Platoon";case"squad":return"분대 / Squad";case"agent":return"에이전트 / Agent";default:return e}}function ae(e){return ri.value===e}function Zn(){return zi.value}function Av(e){var a,o,l,c,u,m,v;const t=zi.value,n=St.value,s=Qn.value;switch(e){case"warroom":return{tool:"masc_observe_operations",reason:"live run, worker, message, trace를 한 화면에서 보고 필요한 detail 표면으로 바로 점프합니다."};case"operations":return{tool:"masc_operation_status",reason:`활성 작전 ${((a=t==null?void 0:t.operations.summary)==null?void 0:a.active)??0}개와 dependency를 먼저 확인합니다.`};case"swarm":return{tool:(n==null?void 0:n.recommended_next_tool)??((l=(o=t==null?void 0:t.swarm_status)==null?void 0:o.recommended_next_action)==null?void 0:l.tool)??"masc_observe_traces",reason:((u=(c=t==null?void 0:t.swarm_status)==null?void 0:c.recommended_next_action)==null?void 0:u.reason)??"lane 이동과 blocker를 보고 다음 probe 도구를 고릅니다."};case"chains":return{tool:(v=(m=s==null?void 0:s.operations[0])==null?void 0:m.preview_run)!=null&&v.chain_id?"masc_chain_run_get":"masc_chain_snapshot",reason:"체인 연결 상태와 최근 run 그래프를 함께 보면 병목을 빨리 좁힐 수 있습니다."};case"topology":return{tool:"masc_observe_topology",reason:"지휘 계층과 live roster를 같이 봐야 빈 squad나 고립 unit을 놓치지 않습니다."};case"alerts":return{tool:"masc_observe_alerts",reason:"경보에서 먼저 문제가 된 unit과 operation을 고릅니다."};case"trace":return{tool:"masc_observe_traces",reason:"trace 흐름으로 원인 이벤트를 바로 따라갈 수 있습니다."};case"control":return{tool:"masc_operator_action",reason:"승인이나 kill switch 같은 실제 조작은 control 표면과 operator action이 이어집니다."};case"summary":default:return{tool:"masc_observe_operations",reason:"요약을 본 뒤에는 현재 작전 표면으로 내려가 실제 움직임을 확인하는 게 가장 빠릅니다."}}}function Cv(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("artifact_scope")||t.includes("routing_confidence")||t.includes("cache_contention")?"microarch":t.includes("leader_offline")||t.includes("roster_offline")?"alerts":t.includes("stale_data")?"swarm":null:null}function Iv(e){var n;const t=((n=e==null?void 0:e.focus_kind)==null?void 0:n.toLowerCase())??"";return t?t.includes("stale_data")||t.includes("leader_offline")||t.includes("roster_offline")||t.includes("managed")?"recommendation":t.includes("gap")?"gaps":null:null}function vl(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");if(!t)return null;const n=t.trim();return n===""?null:n}function _l(){if(typeof window>"u")return new URLSearchParams;const e=new URLSearchParams(window.location.search),t=window.location.hash.replace(/^#/,""),n=t.indexOf("?");return n>=0&&new URLSearchParams(t.slice(n+1)).forEach((a,o)=>{e.has(o)||e.set(o,a)}),e}function Tv(){const t=_l().get("run_id");if(!t)return null;const n=t.trim();return n===""?null:n}function fl(){const t=_l().get("operation_id");if(!t)return null;const n=t.trim();return n===""?null:n}function Rv(e){if(!e)return null;const t=Date.parse(e);return Number.isNaN(t)?null:Math.max(0,Math.round((Date.now()-t)/1e3))}function wv(e){return e.status==="claimed"||e.status==="in_progress"}function Pv(e){const t=Vn.value;if(!t)return null;for(const n of t.golden_paths){const s=n.steps.find(a=>a.tool===e);if(s)return s}return null}function xa(e){var t;return((t=Vn.value)==null?void 0:t.golden_paths.find(n=>n.id===e))??null}function Lv(e){const t=Vn.value;if(!t)return[];const n=new Set(e);return t.pitfalls.filter(s=>n.has(s.id))}async function et(e){try{await e()}catch{}}function qi(e){return(e==null?void 0:e.trim().toLowerCase())??""}function Dt(e){const t=qi(e);return t.includes("failed")||t.includes("error")||t.includes("stopped")||t==="paused"?"bad":t.includes("active")||t.includes("running")||t.includes("healthy")||t.includes("ok")?"ok":"warn"}function Sa(e){const t=qi(e);return t?t==="active"||t==="running"?"진행 중":t==="paused"?"일시정지":t==="done"||t==="ended"||t==="completed"?"완료":t==="failed"||t==="error"||t==="stopped"?"문제":(e==null?void 0:e.trim())||"확인 필요":"확인 필요"}function Nv(){var t,n,s;const e=St.value;return e?!!(e.run_id||(t=e.operation)!=null&&t.operation_id||(n=e.detachment)!=null&&n.detachment_id||(((s=e.summary)==null?void 0:s.expected_workers)??0)>0||e.workers.length>0||e.recent_messages.length>0||e.recent_trace_events.length>0):!1}function Mv(e){const t=qi(e.status);return t==="active"||t==="running"}function zv(){var o,l,c,u;const e=((o=ve.value)==null?void 0:o.sessions)??[],t=St.value,n=((l=t==null?void 0:t.detachment)==null?void 0:l.session_id)??null;if(n){const m=e.find(v=>v.session_id===n);if(m)return m}const s=((c=t==null?void 0:t.operation)==null?void 0:c.operation_id)??fl();if(s){const m=e.find(v=>v.command_plane_operation_id===s);if(m)return m}const a=((u=t==null?void 0:t.detachment)==null?void 0:u.detachment_id)??null;if(a){const m=e.find(v=>v.command_plane_detachment_id===a);if(m)return m}return e.find(Mv)??e[0]??null}function Ev(e){return e==="proven"?"ok":e==="partial"?"warn":"bad"}function yn(e){return Array.isArray(e)?e:[]}function Dv({item:e}){return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.summary??e.event_type??"event"}</strong>
          <div class="command-meta-line">
            <span>${e.source??"source"}</span>
            <span>${e.event_type??"event"}</span>
            <span>${e.actor??"system"}</span>
          </div>
        </div>
        <span class="command-chip">${Q(e.timestamp)}</span>
      </div>
    </article>
  `}function jv({item:e}){return i`
    <article class="mission-activity-row">
      <div class="mission-activity-head">
        <div>
          <strong>${e.actor}</strong>
          <div class="mission-activity-meta">
            <span>${e.role??"participant"}</span>
            <span>${e.last_active_at?Q(e.last_active_at):"n/a"}</span>
          </div>
        </div>
        <span class="command-chip ${e.interaction_count&&e.interaction_count>0?"warn":"ok"}">
          ${e.interaction_count??0} interactions
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>turns ${e.turn_count??0}</span>
        <span>spawn ${e.spawn_count??0}</span>
        <span>tool evidence ${e.tool_evidence_count??0}</span>
      </div>
      ${e.recent_input_preview?i`<div class="mission-activity-preview"><strong>Input</strong><span>${e.recent_input_preview}</span></div>`:null}
      ${e.recent_output_preview?i`<div class="mission-activity-preview"><strong>Output</strong><span>${e.recent_output_preview}</span></div>`:null}
      ${yn(e.recent_tool_names).length>0?i`<div class="semantic-tag-row">
            ${yn(e.recent_tool_names).map(t=>i`<span class="semantic-tag">${t}</span>`)}
          </div>`:null}
      ${e.recent_event_summary?i`<div class="mission-activity-copy"><span>${e.recent_event_summary}</span></div>`:null}
    </article>
  `}function Ov({item:e}){return i`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${e.kind}</strong>
          <div class="command-meta-line">
            <span>${e.path}</span>
          </div>
        </div>
        <span class="command-chip ${e.exists?"ok":"warn"}">${e.exists?"present":"missing"}</span>
      </div>
    </article>
  `}function qv(){var f,g,h;const e=j.value.params,t=e.session_id??null,n=e.operation_id??null;ne(()=>{Qr(t,n)},[t,n]);const s=Vr.value;if(oi.value&&!s)return i`<section class="dashboard-panel"><div class="loading-indicator">Loading proof…</div></section>`;if(zt.value&&!s)return i`<section class="dashboard-panel"><div class="error-card">${zt.value}</div></section>`;const a=s==null?void 0:s.summary,o=yn(s==null?void 0:s.timeline),l=yn(s==null?void 0:s.actor_contributions),c=yn(s==null?void 0:s.artifacts),u=(s==null?void 0:s.proof_verdict)??"insufficient",m=(s==null?void 0:s.cp_backing_evidence)??null,v=Array.isArray((f=m==null?void 0:m.traces)==null?void 0:f.events)?((h=(g=m.traces)==null?void 0:g.events)==null?void 0:h.length)??0:0;return i`
    <section class="dashboard-panel mission-view">
      <${he} surfaceId="proof" />
      <div class="panel-header">
        <div>
          <h2>Proof</h2>
          <p>협업, 대화, 도구 사용, backing evidence를 한 화면에서 증명하는 표면입니다.</p>
        </div>
        <div class="mission-header-meta">
          <span class="command-chip ${Ev(u)}">${u}</span>
          ${s!=null&&s.session_id?i`<span class="command-chip">${s.session_id}</span>`:null}
          ${s!=null&&s.generated_at?i`<span class="command-chip">${Q(s.generated_at)}</span>`:null}
        </div>
      </div>

      ${zt.value?i`<div class="error-card">${zt.value}</div>`:null}

      <div class="mission-stat-grid">
        <div class="summary-stat-card">
          <span>Actors</span>
          <strong>${(a==null?void 0:a.actors_count)??l.length}</strong>
          <small>proof lane participants</small>
        </div>
        <div class="summary-stat-card">
          <span>Interactions</span>
          <strong>${(a==null?void 0:a.interaction_count)??0}</strong>
          <small>cross-actor evidence</small>
        </div>
        <div class="summary-stat-card">
          <span>Evidence</span>
          <strong>${(a==null?void 0:a.evidence_count)??0}</strong>
          <small>tool / deliverable / checkpoint</small>
        </div>
        <div class="summary-stat-card">
          <span>CP Traces</span>
          <strong>${(a==null?void 0:a.cp_trace_count)??v}</strong>
          <small>managed backing events</small>
        </div>
      </div>

      <div class="mission-human-grid">
        <${I} title="3-Line Proof Summary" class="mission-list-card" semanticId="proof.summary">
          <div class="mission-section-head">
            <h3>핵심 증명</h3>
          </div>
          <div class="mission-list-stack">
            <div class="command-card">
              <div class="command-card-head">
                <div>
                  <strong>${(a==null?void 0:a.headline)??"No collaboration proof selected."}</strong>
                  <div class="command-meta-line">
                    <span>${(a==null?void 0:a.detail)??"Provide session_id or open the latest team session."}</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        <//>

        <${I} title="Goal Binding" class="mission-list-card" semanticId="proof.goal_binding">
          <div class="mission-section-head">
            <h3>목표 연결</h3>
          </div>
          <pre class="command-json-block">${Vs((s==null?void 0:s.goal_binding)??{})}</pre>
        <//>
      </div>

      <div class="mission-human-grid">
        <${I} title="Collaboration Timeline" class="mission-list-card" semanticId="proof.timeline">
          <div class="mission-section-head">
            <h3>협업 타임라인</h3>
            <p>session events와 command-plane traces를 한 흐름으로 읽습니다.</p>
          </div>
          <div class="mission-list-stack">
            ${o.length>0?o.slice(0,24).map(k=>i`<${Dv} key=${k.id} item=${k} />`):i`<div class="empty-state">표시할 timeline evidence가 없습니다.</div>`}
          </div>
        <//>

        <${I} title="Actor Contributions" class="mission-list-card" semanticId="proof.contributions">
          <div class="mission-section-head">
            <h3>actor 기여</h3>
            <p>누가 무엇을 했고 어떤 input/output을 남겼는지 봅니다.</p>
          </div>
          <div class="mission-activity-list">
            ${l.length>0?l.map(k=>i`<${jv} key=${k.actor} item=${k} />`):i`<div class="empty-state">표시할 actor contribution이 없습니다.</div>`}
          </div>
        <//>
      </div>

      <div class="mission-human-grid">
        <${I} title="Backing Evidence" class="mission-list-card" semanticId="proof.backing">
          <div class="mission-section-head">
            <h3>CPv2 backing evidence</h3>
          </div>
          <pre class="command-json-block">${Vs(m??{})}</pre>
        <//>

        <${I} title="Artifacts" class="mission-list-card" semanticId="proof.artifacts">
          <div class="mission-section-head">
            <h3>생성 산출물</h3>
          </div>
          <div class="mission-list-stack">
            ${c.length>0?c.map(k=>i`<${Ov} key=${k.path} item=${k} />`):i`<div class="empty-state">기록된 artifact가 없습니다.</div>`}
          </div>
        <//>
      </div>
    </section>
  `}function Fv(){const e=Jn(j.value);return e?i`
    <section class="command-focus-banner">
      <div class="command-focus-head">
        <strong>${e.source_label}</strong>
        <span class="command-chip">${ua(e.action_type)}</span>
        <span class="command-chip">${wi(e)}</span>
        <span class="command-chip">${Yu(j.value.params.surface??"warroom")}</span>
      </div>
      <div class="command-focus-body">${e.summary}</div>
      ${e.payload_preview?i`<div class="command-focus-preview">${e.payload_preview}</div>`:null}
    </section>
  `:null}function Kv(){const e=X.value,t=bv[e],n=Av(e);return i`
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
  `}function os({label:e,value:t,subtext:n,percent:s,color:a}){return i`
    <article class="command-gauge-card">
      <div class="command-gauge-ring" style=${gv(s,a)}>
        <div class="command-gauge-core">
          <strong>${t}</strong>
          <span>${Math.round(Xn(s))}%</span>
        </div>
      </div>
      <div class="command-gauge-copy">
        <span>${e}</span>
        <small>${n}</small>
      </div>
    </article>
  `}function rs({label:e,value:t,detail:n,percent:s,tone:a}){return i`
    <article class="command-signal-rail ${L(a)}">
      <div class="command-signal-copy">
        <span>${e}</span>
        <strong>${t}</strong>
      </div>
      <div class="command-signal-bar">
        <span class="${L(a)}" style=${`width: ${Math.max(8,Math.round(Xn(s)))}%`}></span>
      </div>
      <small>${n}</small>
    </article>
  `}function Uv(){var te,se,G,Z;const e=Zn(),t=e==null?void 0:e.topology.summary,n=e==null?void 0:e.operations.summary,s=e==null?void 0:e.detachments.summary,a=e==null?void 0:e.decisions.summary,o=e==null?void 0:e.alerts.summary,l=(te=e==null?void 0:e.swarm_status)==null?void 0:te.overview,c=e==null?void 0:e.swarm_proof,u=e==null?void 0:e.operations.microarch,m=(t==null?void 0:t.managed_unit_count)??0,v=(t==null?void 0:t.total_units)??0,f=(n==null?void 0:n.active)??0,g=(s==null?void 0:s.active)??0,h=(l==null?void 0:l.moving_lanes)??0,k=(l==null?void 0:l.active_lanes)??0,$=(c==null?void 0:c.workers.done)??0,C=(c==null?void 0:c.workers.expected)??0,A=(o==null?void 0:o.bad)??0,T=(o==null?void 0:o.warn)??0,x=(a==null?void 0:a.pending)??0,R=(a==null?void 0:a.total)??0,w=f+g,E=((se=u==null?void 0:u.cache)==null?void 0:se.l1_hit_rate)??((Z=(G=u==null?void 0:u.signals)==null?void 0:G.cache_contention)==null?void 0:Z.l1_hit_rate)??0,J=f>0||g>0?"지휘면이 실제로 움직이고 있습니다":"계층은 준비됐지만 실행은 아직 잠복 상태입니다",D=f>0||h>0?"무거운 상세 탭으로 들어가기 전에, 여기서 먼저 압력과 이동감, 운영 부채를 읽을 수 있어야 합니다.":"이 화면은 체크리스트보다 계기판에 가까워야 합니다. 아래 게이지가 지금 어디가 살아 있는지 먼저 보여줍니다.";return i`
    <section class="command-hero command-hero-summary">
      <div class="command-hero-copy">
        <span class="command-hero-kicker">현재 지휘 상태</span>
        <h3>${J}</h3>
        <p>${D}</p>
        <div class="command-hero-badges">
        <span class="command-chip ${L(f>0?"ok":"warn")}">활성 작전 ${f}</span>
          <span class="command-chip ${L(h>0?"ok":(k>0,"warn"))}">이동 레인 ${h}/${Math.max(k,h)}</span>
          <span class="command-chip ${L(A>0?"bad":T>0?"warn":"ok")}">치명 알림 ${A}</span>
          <span class="command-chip ${L(x>0?"warn":"ok")}">승인 대기 ${x}</span>
        </div>
      </div>

      <div class="command-gauge-grid">
        <${os}
          label="관리 단위 범위"
          value=${`${m}/${Math.max(v,m)}`}
          subtext=${v>0?`${v-m}개 단위는 아직 명시 정책 바깥에 있습니다`:"토폴로지 요약이 아직 없습니다"}
          percent=${mt(m,Math.max(v,m))}
          color="#67e8f9"
        />
        <${os}
          label="실행 열도"
          value=${String(w)}
          subtext=${`${f}개 작전 + ${g}개 실행체가 실제 부하를 들고 있습니다`}
          percent=${mt(w,Math.max(m,w||1))}
          color="#4ade80"
        />
        <${os}
          label="스웜 이동감"
          value=${`${h}/${Math.max(k,h)}`}
          subtext=${l!=null&&l.last_movement_at?`마지막 이동 ${Q(l.last_movement_at)}`:"최근 스웜 이동이 아직 없습니다"}
          percent=${mt(h,Math.max(k,h||1))}
          color="#fbbf24"
        />
        <${os}
          label="증거 수집률"
          value=${`${$}/${Math.max(C,$)}`}
          subtext=${c!=null&&c.status?`증거 소스 ${c.source} · ${c.status}`:"스웜 증거 아티팩트가 아직 없습니다"}
          percent=${mt($,Math.max(C,$||1))}
          color="#f472b6"
        />
      </div>
    </section>
    <div class="command-signal-grid">
      <${rs}
        label="승인 대기열"
        value=${`${x}건 대기`}
        detail=${`현재 정책 창에서 ${R}개 결정을 추적 중입니다`}
        percent=${mt(x,Math.max(R,x||1))}
        tone=${x>0?"warn":"ok"}
      />
      <${rs}
        label="알림 압력"
        value=${`${A} bad / ${T} warn`}
        detail=${A>0?"치명 신호가 이미 요약면에서 보입니다":"보드를 지배하는 hard-stop 알림은 아직 없습니다"}
        percent=${mt(A*2+T,Math.max((A+T)*2,1))}
        tone=${A>0?"bad":T>0?"warn":"ok"}
      />
      <${rs}
        label="디스패치 점유"
          value=${`${g}개 가동`}
        detail=${m>0?`${m}개 관리 단위가 작업을 받을 수 있습니다`:"관리 단위 토폴로지가 아직 없습니다"}
        percent=${mt(g,Math.max(m,g||1))}
        tone=${g>0?"ok":"warn"}
      />
      <${rs}
        label="캐시 신뢰도"
        value=${E?Yn(E):"n/a"}
        detail=${E?"microarch 캐시 텔레메트리에서 집계한 L1 hit rate":"캐시 텔레메트리가 아직 집계되지 않았습니다"}
        percent=${Xn((E??0)*100)}
        tone=${E>=.75?"ok":E>=.4?"warn":"bad"}
      />
    </div>
  `}function Bv(){var g,h,k,$,C;const e=Zn(),t=Qn.value,n=Jn(j.value),s=Cv(n),a=e==null?void 0:e.topology.summary,o=e==null?void 0:e.operations.summary,l=(g=e==null?void 0:e.swarm_status)==null?void 0:g.overview,c=e==null?void 0:e.operations.microarch,u=e==null?void 0:e.decisions.summary,m=e==null?void 0:e.alerts.summary,v=(h=c==null?void 0:c.signals)==null?void 0:h.issue_pressure,f=c==null?void 0:c.cache;return i`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>유닛</span><strong>${(a==null?void 0:a.total_units)??0}</strong><small>${(a==null?void 0:a.managed_unit_count)??0}개 관리 중</small></div>
      <div class="monitor-stat-card"><span>작전</span><strong>${(o==null?void 0:o.active)??0}</strong><small>${((k=e==null?void 0:e.detachments.summary)==null?void 0:k.active)??0}개 실행체</small></div>
      <div class="monitor-stat-card"><span>승인</span><strong>${(u==null?void 0:u.pending)??0}</strong><small>${(u==null?void 0:u.total)??0}개 추적 중</small></div>
      <div class="monitor-stat-card ${s==="alerts"?"highlight":""}"><span>알림</span><strong>${(m==null?void 0:m.bad)??0}</strong><small>${(m==null?void 0:m.warn)??0}건 warn</small></div>
      <div class="monitor-stat-card"><span>체인</span><strong>${(($=t==null?void 0:t.summary)==null?void 0:$.active_chains)??0}</strong><small>${((C=t==null?void 0:t.summary)==null?void 0:C.linked_operations)??0}개 연결</small></div>
      <div class="monitor-stat-card ${s==="swarm"?"highlight":""}"><span>스웜</span><strong>${(l==null?void 0:l.active_lanes)??0}</strong><small>${l?`${l.stalled_lanes??0}개 정체 · ${Q(l.last_movement_at)}`:"lane snapshot 없음"}</small></div>
      <div class="monitor-stat-card ${s==="microarch"?"highlight":""}"><span>마이크로아크</span><strong>${(v==null?void 0:v.pending_ops)??0}</strong><small>${(f==null?void 0:f.l1_hit_rate)!=null?`${Yn(f.l1_hit_rate)} L1 hit`:"캐시 데이터 없음"} · ${(v==null?void 0:v.tone)??"n/a"}</small></div>
    </div>
  `}function Wv(){var te,se,G,Z,S,Se,Be,lt,ct;const e=Zn(),t=Ee.value,n=oe.value,s=vl(),a=s?ze.value.find(O=>O.name===s)??null:null,o=s?Le.value.filter(O=>O.assignee===s&&wv(O)):[],l=((te=e==null?void 0:e.operations.summary)==null?void 0:te.active)??0,c=((se=e==null?void 0:e.detachments.summary)==null?void 0:se.total)??0,u=((G=e==null?void 0:e.decisions.summary)==null?void 0:G.pending)??0,m=t==null?void 0:t.detachments.detachments.find(O=>{const Ae=O.detachment.heartbeat_deadline,dt=Ae?Date.parse(Ae):Number.NaN;return O.detachment.status==="stalled"||!Number.isNaN(dt)&&dt<=Date.now()}),v=t==null?void 0:t.alerts.alerts.find(O=>O.severity==="bad"),f=!!(n!=null&&n.room||n!=null&&n.project),g=(a==null?void 0:a.current_task)??null,h=Rv(a==null?void 0:a.last_seen),k=h!=null?h<=120:null,$=[f?{title:"Room 준비도",tone:"ok",detail:`${(n==null?void 0:n.room)??(n==null?void 0:n.project)??"unknown"} · base ${(n==null?void 0:n.room_base_path)??"n/a"}`,tool:"masc_status"}:{title:"Room 준비도",tone:"bad",detail:"아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.",tool:"masc_set_room"},s?a?o.length===0?{title:"Task 준비도",tone:"warn",detail:`${s} 에게 배정된 claimed task가 없습니다. 먼저 claim 하거나 만들어야 합니다.`,tool:Le.value.length>0?"masc_claim":"masc_add_task"}:g?k===!1?{title:"Task 준비도",tone:"warn",detail:`${s} current_task=${g} 이지만 heartbeat가 stale 합니다 (${h}s).`,tool:"masc_heartbeat"}:{title:"Task 준비도",tone:"ok",detail:`${s} current_task=${g}${h!=null?` · 마지막 활동 ${h}s 전`:""}`,tool:"masc_plan_get_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 에 claimed task는 있지만 session current_task binding이 없습니다.`,tool:"masc_plan_set_task"}:{title:"Task 준비도",tone:"bad",detail:`${s} 이 room roster에 보이지 않습니다.`,tool:"masc_join"}:{title:"Task 준비도",tone:"warn",detail:"?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.",tool:"masc_join"},!e||(((Z=e.topology.summary)==null?void 0:Z.managed_unit_count)??0)===0?{title:"작전 준비도",tone:"warn",detail:"관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.",tool:"masc_unit_define"}:l===0?{title:"작전 준비도",tone:"warn",detail:`${((S=e.topology.summary)==null?void 0:S.managed_unit_count)??0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,tool:"masc_operation_start"}:{title:"작전 준비도",tone:"ok",detail:`${((Se=e.topology.summary)==null?void 0:Se.managed_unit_count)??0}개 관리 단위 위에서 ${l}개 활성 작전이 돌고 있습니다.`,tool:"masc_observe_operations"},u>0?{title:"디스패치 준비도",tone:"warn",detail:`${u}개의 pending approval이 strict action을 막고 있습니다.`,tool:"masc_policy_approve"}:l>0&&c===0?{title:"디스패치 준비도",tone:"bad",detail:"active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.",tool:"masc_dispatch_tick"}:m||v?{title:"디스패치 준비도",tone:"warn",detail:`dispatch 재정렬이 필요합니다${m?` · detachment ${m.detachment.detachment_id} 가 stalled 상태입니다`:""}${v?` · alert ${v.title??v.alert_id}`:""}${!t&&!m&&!v?" · 정확한 원인은 detail 탭에서 확인하세요.":""}.`,tool:u>0?"masc_policy_approve":"masc_dispatch_tick"}:{title:"디스패치 준비도",tone:"ok",detail:`${c}개 detachment가 보이고 strict approval backlog도 없습니다${t?"":" · detail pane은 열릴 때만 로드됩니다."}.`,tool:"masc_detachment_list"}],C=f?!s||!a?"masc_join":o.length===0?Le.value.length>0?"masc_claim":"masc_add_task":g?k===!1?"masc_heartbeat":!e||(((Be=e.topology.summary)==null?void 0:Be.managed_unit_count)??0)===0?"masc_unit_define":l===0?"masc_operation_start":u>0?"masc_policy_approve":l>0&&c===0||m||v?"masc_dispatch_tick":"masc_observe_traces":"masc_plan_set_task":"masc_set_room",A=Pv(C),x=Lv(C==="masc_set_room"?["repo-root-room"]:C==="masc_plan_set_task"?["claimed-not-current"]:C==="masc_heartbeat"?["heartbeat-stale"]:C==="masc_dispatch_tick"?["no-detachments"]:C==="masc_policy_approve"?["pending-approval"]:["repo-root-room","claimed-not-current","heartbeat-stale"]).slice(0,2),R=xa("room_task_hygiene"),w=xa("cpv2_benchmark"),E=xa("supervisor_session"),J=((lt=Vn.value)==null?void 0:lt.docs)??[],D=[R,w,E].filter(O=>O!==null);return i`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">즉시 조치</div>
          <${z} panelId="command.summary" compact=${!0} />
        </div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${(A==null?void 0:A.title)??C}</strong>
            <span class="command-chip ok">${C}</span>
          </div>
          <p>${(A==null?void 0:A.summary)??"지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다."}</p>
          ${(ct=A==null?void 0:A.success_signals)!=null&&ct.length?i`<div class="command-tag-row">
                ${A.success_signals.map(O=>i`<span class="command-tag ok">${O}</span>`)}
              </div>`:null}
        </div>

        <div class="command-readiness-list">
          ${$.map(O=>i`
            <article class="command-readiness-row ${L(O.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${O.title}</strong>
                  <span class="command-chip ${L(O.tone)}">${O.tone}</span>
                </div>
                <p>${O.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${O.tool}</div>
            </article>
          `)}
        </div>

        ${x.length>0?i`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>자주 막히는 지점</strong>
                  <span class="command-chip warn">${x.length}</span>
                </div>
                <div class="command-guide-list">
                  ${x.map(O=>i`
                    <article class="command-guide-inline">
                      <strong>${O.title}</strong>
                      <div>${O.symptom}</div>
                      <div class="command-card-sub">${O.fix_tool} 로 해결: ${O.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `:null}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">운영 경로</div>
          <${z} panelId="command.summary" compact=${!0} />
        </div>
        ${li.value?i`<div class="empty-state">CPv2 runbook 불러오는 중…</div>`:Bs.value?i`<div class="empty-state error">${Bs.value}</div>`:i`
                <div class="command-path-grid">
                  ${D.map(O=>i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${O.title}</strong>
                        <span class="command-chip">${O.id}</span>
                      </div>
                      <p>${O.summary}</p>
                      <div class="command-card-sub">${O.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${O.steps.slice(0,4).map(Ae=>i`
                          <div class="command-step-row">
                            <span class="command-step-tool">${Ae.tool}</span>
                            <span>${Ae.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${J.length>0?i`<div class="command-doc-links">
                      ${J.map(O=>i`<span class="command-tag">${O.title}: ${O.path}</span>`)}
                    </div>`:null}
              `}
      </section>
    </div>
  `}function Hv(){return i`
    <${Uv} />
    <${Bv} />
    <${Wv} />
  `}function Gv(){return qs.value?i`<div class="empty-state">command-plane detail 불러오는 중…</div>`:Ks.value?i`<div class="empty-state error">${Ks.value}</div>`:i`<div class="empty-state">surface를 선택하면 command-plane detail을 로드합니다.</div>`}function gl({node:e,depth:t=0}){const n=e.roster_live??0,s=e.roster_total??e.unit.roster.length,a=e.active_operation_count??0,o=e.unit.policy;return i`
    <div class="command-tree-node depth-${Math.min(t,3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${e.unit.label}</strong>
            <span class="command-chip">${Sv(e.unit.kind)}</span>
            <span class="command-chip ${L(e.health)}">${e.health??"ok"}</span>
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
            ${e.children.map(l=>i`<${gl} node=${l} depth=${t+1} />`)}
          </div>`:null}
    </div>
  `}function Jv({alert:e}){return i`
    <article class="command-alert ${L(e.severity)}">
      <div class="command-card-head">
        <strong>${e.title??e.kind??e.alert_id}</strong>
        <span class="command-chip ${L(e.severity)}">${e.severity??"warn"}</span>
      </div>
      <div class="command-alert-meta">
        <span>${e.scope_type??"scope"}:${e.scope_id??"n/a"}</span>
        <span>${Q(e.timestamp)}</span>
      </div>
      ${e.detail?i`<p>${e.detail}</p>`:null}
    </article>
  `}function Fi({event:e}){return i`
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
      <pre class="command-trace-detail">${Vs(e.detail)}</pre>
    </article>
  `}function Vv(){const e=Ee.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">지휘 계층</div>
        <${z} panelId="command.topology" compact=${!0} />
      </div>
      ${e&&e.topology.units.length>0?i`${e.topology.units.map(t=>i`<${gl} node=${t} />`)}`:i`<div class="empty-state">아직 그려진 지휘 계층이 없습니다.</div>`}
    </section>
  `}function Qv(){const e=Ee.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">경보</div>
        <${z} panelId="command.alerts" compact=${!0} />
      </div>
      ${e&&e.alerts.alerts.length>0?i`<div class="command-card-stack">
            ${e.alerts.alerts.map(t=>i`<${Jv} alert=${t} />`)}
          </div>`:i`<div class="empty-state">지금 올라온 command-plane 경보는 없습니다.</div>`}
    </section>
  `}function Yv(){const e=Ee.value;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">최근 트레이스</div>
        <${z} panelId="command.trace" compact=${!0} />
      </div>
      ${e&&e.traces.events.length>0?i`<div class="command-trace-stack">
            ${e.traces.events.map(t=>i`<${Fi} event=${t} />`)}
          </div>`:i`<div class="empty-state">최근 trace event가 없습니다.</div>`}
    </section>
  `}function Xv(e){if(typeof e=="string")return e;if(e==null)return"";try{return JSON.stringify(e,null,2)}catch{return String(e)}}function Zv(e,t){return(t==null?void 0:t.status)==="abandoned"||(e==null?void 0:e.recommended_kind)==="continue"?"warn":(e==null?void 0:e.recommended_kind)==="rerun"?"bad":"ok"}function e_(e){switch(e){case"continue":case"continued":return"계속";case"rerun":return"재실행";case"abandon":case"abandoned":return"포기";default:return(e==null?void 0:e.trim())||"결정"}}function $l({swarm:e}){var f,g;const t=e.run_id,n=e.resolution_recommendation,s=e.run_resolution;if(!t||!n&&!s)return null;const a=vl()??"dashboard",o=((f=ve.value)==null?void 0:f.pending_confirms.find(h=>h.target_type==="swarm_run"&&h.target_id===t))??null,l=Zv(n,s),c=((g=e.operation)==null?void 0:g.operation_id)??e.operation_id??void 0,u={run_id:t};c&&(u.operation_id=c),n!=null&&n.reason&&(u.reason=n.reason);const m=async h=>{await Ur({actor:a,action_type:h,target_type:"swarm_run",target_id:t,payload:u})},v=async h=>{o&&await Br(a,o.confirm_token,h)};return i`
    <article class="command-guide-card ${L(l)}">
      <div class="command-guide-head">
        <strong>Run Resolution</strong>
        <span class="command-chip ${L(l)}">
          ${e_((s==null?void 0:s.status)??(n==null?void 0:n.recommended_kind)??null)}
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
              ${n.evidence.runtime_blocker?i`<span class="command-tag ${L("bad")}">${n.evidence.runtime_blocker}</span>`:null}
            </div>
          `:null}
      ${o?i`
            <div class="command-guide-card warn">
              <div class="command-guide-head">
                <strong>확인 대기</strong>
                <span class="command-chip warn">${o.confirm_token}</span>
              </div>
              ${o.preview?i`<pre class="command-trace-detail">${Xv(o.preview)}</pre>`:null}
              <div class="command-action-row">
                <button class="control-btn" onClick=${()=>{v("confirm")}} disabled=${W.value}>확인 실행</button>
                <button class="control-btn ghost" onClick=${()=>{v("deny")}} disabled=${W.value}>취소</button>
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
  `}function hl(e){return e.motion_state==="stalled"||e.hard_flags.some(t=>t.severity==="bad")?"bad":e.motion_state==="waiting"||e.hard_flags.some(t=>t.severity==="warn")?"warn":"ok"}function yl({lanes:e}){const t={moving:0,waiting:0,stalled:0,terminal:0};for(const a of e){const o=a.motion_state;o in t?t[o]++:t.waiting++}if(e.length===0)return null;const s=[{key:"moving",count:t.moving,color:"var(--ok)"},{key:"waiting",count:t.waiting,color:"var(--warn)"},{key:"stalled",count:t.stalled,color:"var(--bad)"},{key:"terminal",count:t.terminal,color:"#556"}];return i`
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
  `}function t_({total:e}){const n=Math.min(e,20),s=e>20?e-20:0,a=Array.from({length:n});return i`
    <div class="swarm-worker-grid">
      ${a.map(()=>i`<span class="swarm-worker-dot present"></span>`)}
      ${s>0?i`<span class="swarm-worker-count">+${s}</span>`:null}
      <span class="swarm-worker-count">(워커 ${e})</span>
    </div>
  `}function n_({lane:e}){const t=e.counts??{},n=hl(e),s=t.workers??0,a=t.operations??0,o=t.detachments??0,l=a+o,c=e.motion_state==="moving"?84:e.motion_state==="waiting"?58:e.motion_state==="terminal"?100:26;return i`
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
          <span class="command-chip">${Q(e.last_movement_at)}</span>
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
        ${s>0?i`
              <div class="swarm-lane-row">
                <span class="swarm-lane-row-label">워커</span>
                <${t_} total=${s} />
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
              ${e.hard_flags.map(u=>i`<span class="command-chip ${L(u.severity)}">${u.code}</span>`)}
            </div>
          `:null}
    </article>
  `}function bl({lanes:e}){const t=e.slice(0,4);return t.length===0?null:i`
    <div class="swarm-storyboard">
      ${t.map(n=>{const s=hl(n),a=n.counts.workers??0,o=n.counts.operations??0,l=n.counts.detachments??0;return i`
          <article class="swarm-story-card ${L(s)}">
            <div class="swarm-story-topline">
              <span class="command-chip ${L(s)}">${n.motion_state}</span>
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
  `}function s_({event:e}){const t=e.timestamp?new Date(e.timestamp):null,n=t&&!isNaN(t.getTime())?t:null,s=n?`${String(n.getHours()).padStart(2,"0")}:${String(n.getMinutes()).padStart(2,"0")}`:"";return i`
    <div class="swarm-event-node">
      <span class="swarm-event-dot ${L(e.tone)}"></span>
      <span class="swarm-event-time">${s}</span>
      <div class="swarm-event-body">
        <strong>${e.title}</strong>
        <span class="swarm-event-kind">${e.kind}</span>
        ${e.detail?i`<div class="command-card-sub">${e.detail}</div>`:null}
      </div>
    </div>
  `}function a_({gap:e}){return i`
    <div class="swarm-gap-inline">
      <span class="swarm-gap-dot"></span>
      <span class="command-chip ${L(e.severity)}">${e.code} (${e.count})</span>
      <span class="command-card-sub">${e.summary}</span>
    </div>
  `}function i_({proof:e}){const t=(e==null?void 0:e.status)==="missing"?"warn":(e==null?void 0:e.pass)===!1?"bad":(e==null?void 0:e.pass)===!0?"ok":"warn";return i`
    <div class="command-guide-card ${L(t)}">
        <div class="command-guide-head">
          <strong>Hot Proof / 가동 증거</strong>
          <span class="command-chip ${L(t)}">${(e==null?void 0:e.status)??"missing"}</span>
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
  `}function o_(){const e=Zn(),t=Jn(j.value),n=Iv(t),s=e==null?void 0:e.swarm_status,a=e==null?void 0:e.swarm_proof,o=(s==null?void 0:s.lanes.filter(f=>f.present))??[],l=(s==null?void 0:s.gaps.items)??[],c=(s==null?void 0:s.timeline.slice(0,8))??[],u=s==null?void 0:s.overview,m=s==null?void 0:s.recommended_next_action,v=o.length<=1;return i`
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
        <${z} panelId="command.swarm" compact=${!0} />
      </div>
      ${s?i`
            <${bl} lanes=${o} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${(u==null?void 0:u.active_lanes)??0}</strong><small>${(u==null?void 0:u.moving_lanes)??0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${(u==null?void 0:u.stalled_lanes)??0}</strong><small>${(u==null?void 0:u.projected_lanes)??0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${Q(u==null?void 0:u.last_movement_at)}</strong><small>${s.generated_at?`스냅샷 ${Q(s.generated_at)}`:"방금 스냅샷"}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${(m==null?void 0:m.label)??"운영자 상태 확인"}</strong><small>${(m==null?void 0:m.tool)??"masc_operator_snapshot"}</small></div>
            </div>

            ${o.length>0?i`<${yl} lanes=${o} />`:null}

            <div class="command-swarm-layout ${v?"compact":""}">
              <div class="command-card-stack">
                ${o.length>0?o.map(f=>i`<${n_} lane=${f} />`):i`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
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

                <${i_} proof=${a} />

                <div class="command-guide-card ${l.length>0?"warn":"ok"} ${n==="gaps"?"focus":""}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${L(l.some(f=>f.severity==="bad")?"bad":l.length>0?"warn":"ok")}">${l.length}</span>
                  </div>
                  ${l.length>0?i`<div class="swarm-event-rail">${l.slice(0,4).map(f=>i`<${a_} gap=${f} />`)}</div>`:i`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${c.length}</span>
                  </div>
                  ${c.length>0?i`<div class="swarm-event-rail">${c.map(f=>i`<${s_} event=${f} />`)}</div>`:i`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `:i`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `}function r_({item:e}){return i`
    <article class="command-guide-card ${L(e.status)}">
      <div class="command-guide-head">
        <strong>${e.title}</strong>
        <span class="command-chip ${L(e.status)}">${e.status}</span>
      </div>
      <p>${e.detail}</p>
      <div class="command-card-foot">Next tool: ${e.next_tool}</div>
    </article>
  `}function kl({blocker:e}){return i`
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
  `}function l_({worker:e}){return i`
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
      ${e.last_message?i`<div class="command-card-foot">${Q(e.last_message.timestamp)} · ${e.last_message.content}</div>`:null}
    </article>
  `}function c_(){var u,m,v,f,g,h,k,$,C,A,T,x,R,w,E,J,D,te,se,G,Z;const e=St.value,t=Tv(),n=fl(),s=(u=e==null?void 0:e.provider)!=null&&u.runtime_blocker?"blocked":(m=e==null?void 0:e.provider)!=null&&m.provider_reachable?"ready":"check",a=((v=e==null?void 0:e.provider)==null?void 0:v.actual_slots)??((f=e==null?void 0:e.provider)==null?void 0:f.total_slots)??0,o=((g=e==null?void 0:e.provider)==null?void 0:g.expected_slots)??"n/a",l=((h=e==null?void 0:e.provider)==null?void 0:h.actual_ctx)??((k=e==null?void 0:e.provider)==null?void 0:k.ctx_per_slot)??0,c=(($=e==null?void 0:e.provider)==null?void 0:$.expected_ctx)??"n/a";return i`
    <div class="command-section-stack">
      <${o_} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${Ws.value?i`<div class="empty-state">Loading swarm live state…</div>`:Hs.value?i`<div class="empty-state error">${Hs.value}</div>`:e?i`
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${e.run_id??t??"swarm-live"}</strong><small>${e.room_id??"room 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${((C=e.summary)==null?void 0:C.joined_workers)??0}/${((A=e.summary)==null?void 0:A.expected_workers)??0}</strong><small>${((T=e.summary)==null?void 0:T.live_workers)??0}개 가동 · ${((x=e.summary)==null?void 0:x.completed_workers)??0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${s}</strong><small>slots ${a}/${o} · ctx ${l}/${c}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${(R=e.summary)!=null&&R.pass_hot_concurrency?"통과":"확인 필요"}</strong><small>${((w=e.provider)==null?void 0:w.slot_url)??"slot 정보 없음"}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${(E=e.summary)!=null&&E.pass_end_to_end?"통과":"확인 필요"}</strong><small>${e.recommended_next_tool??"masc_observe_traces"}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${((J=e.operation)==null?void 0:J.operation_id)??n??"없음"}</span>
                      <span>분대</span><span>${((D=e.squad)==null?void 0:D.label)??"없음"}</span>
                      <span>실행체</span><span>${((te=e.detachment)==null?void 0:te.detachment_id)??"없음"}</span>
                      <span>예상 워커</span><span>${((se=e.summary)==null?void 0:se.expected_workers)??0}명</span>
                      <span>최종 마커</span><span>${((G=e.summary)==null?void 0:G.final_markers_seen)??0}</span>
                      <span>런타임 막힘</span><span>${((Z=e.provider)==null?void 0:Z.runtime_blocker)??"없음"}</span>
                      <span>추천 도구</span><span>${e.recommended_next_tool??"masc_observe_traces"}</span>
                    </div>
                    ${e.truth_notes.length>0?i`<div class="command-tag-row">
                          ${e.truth_notes.map(S=>i`<span class="command-tag">${S}</span>`)}
                        </div>`:null}
                    <${$l} swarm=${e} />
                  `:i`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.checklist.length>0?i`<div class="command-card-stack">
                ${e.checklist.map(S=>i`<${r_} item=${S} />`)}
              </div>`:i`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.workers.length>0?i`<div class="command-card-stack">
                ${e.workers.map(S=>i`<${l_} worker=${S} />`)}
              </div>`:i`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
            <${z} panelId="command.swarm" compact=${!0} />
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
                      ${e.provider.timeline.slice(-12).map(S=>i`
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
                    </div>`:i`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `:i`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.blockers.length>0?i`<div class="command-card-stack">
                ${e.blockers.map(S=>i`<${kl} blocker=${S} />`)}
              </div>`:i`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${(e==null?void 0:e.recommended_next_tool)??"masc_observe_traces"} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
            <${z} panelId="command.swarm" compact=${!0} />
          </div>
          ${e&&e.recent_messages.length>0?i`<div class="command-trace-stack">
                ${e.recent_messages.map(S=>i`
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
              </div>`:i`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
            <${z} panelId="command.trace" compact=${!0} />
          </div>
          ${e&&e.recent_trace_events.length>0?i`<div class="command-trace-stack">
                ${e.recent_trace_events.map(S=>i`<${Fi} event=${S} />`)}
              </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `}function d_(e){var n;const t=[e.current_task_matches_run?"current":"drift",e.claim_marker_seen?"claim":"no-claim",e.done_marker_seen?"done":"no-done",e.final_marker_seen?"final":"no-final"];return{key:`swarm:${e.name}`,name:e.name,role:e.role,lane:e.lane,status:e.status,source:"swarm",task:e.current_task??e.bound_task_title??e.bound_task_id??"none",heartbeat:e.heartbeat_age_sec!=null?`${Math.round(e.heartbeat_age_sec)}s`:e.heartbeat_fresh?"clean":"n/a",detail:[e.bound_task_status??null,e.detachment_member?"detachment":null,e.squad_member?"squad":null].filter(Boolean).join(" · ")||"live swarm worker",markers:t,note:((n=e.last_message)==null?void 0:n.content)??null}}function u_(e,t){const n=e.actor??e.spawn_role??`worker-${t+1}`,s=e.spawn_role??e.worker_class??e.spawn_agent??"worker",a=e.lane_id??e.capsule_mode??e.control_domain??"session",o=[e.has_turn?"turn":"silent",e.empty_note_turn_count>0?`empty:${e.empty_note_turn_count}`:"noted",e.turn_count>0?`turns:${e.turn_count}`:"turns:0"];return{key:`session:${n}:${t}`,name:n,role:s,lane:a,status:e.status,source:"session",task:e.task_profile??e.runtime_pool??"session lane",heartbeat:e.last_turn_ts_iso?Q(e.last_turn_ts_iso):"n/a",detail:[e.spawn_agent??null,e.spawn_model??null,e.routing_confidence!=null?Yn(e.routing_confidence):null].filter(Boolean).join(" · ")||"session worker",markers:o,note:e.routing_reason??null}}function $o(e){return L(e.severity)}function p_({worker:e}){return i`
    <article class="command-card compact warroom-worker-card ${L(Dt(e.status))}">
      <div class="command-card-head">
        <div>
          <strong>${e.name}</strong>
          <div class="command-card-sub">${e.role} · ${e.lane}</div>
        </div>
        <span class="command-chip ${L(Dt(e.status))}">${e.status}</span>
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
  `}function He({label:e,surface:t,params:n={}}){return i`
    <button
      class="control-btn ghost"
      onClick=${()=>{if(t){yt(t),ue("command",{...ml(t),...n});return}ue("intervene")}}
    >
      ${e}
    </button>
  `}function m_(){var J,D,te,se,G,Z,S,Se,Be,lt,ct,O,Ae,dt,ln,cn,es,ts,ns,ss;const e=Zn(),t=St.value,n=ve.value,s=Ne.value,a=zv(),o=t!=null&&t.operation?((J=Qn.value)==null?void 0:J.operations.find(U=>{var Ct;return U.operation.operation_id===((Ct=t.operation)==null?void 0:Ct.operation_id)}))??null:null,l=(t==null?void 0:t.workers)??[],c=(s==null?void 0:s.worker_cards)??[],u=l.length>0?l.map(d_):c.map(u_),m=Nv(),v=((D=e==null?void 0:e.decisions.summary)==null?void 0:D.pending)??0,f=(n==null?void 0:n.pending_confirms)??[],g=(t==null?void 0:t.blockers)??[],h=(s==null?void 0:s.recommended_actions)??[],k=(s==null?void 0:s.attention_items)??[],$=((te=t==null?void 0:t.recent_messages[0])==null?void 0:te.timestamp)??null,C=((se=t==null?void 0:t.recent_trace_events[0])==null?void 0:se.timestamp)??null,A=$??C??null,T=a==null?void 0:a.summary,x=((G=t==null?void 0:t.summary)==null?void 0:G.expected_workers)??(typeof(T==null?void 0:T.planned_worker_count)=="number"?T.planned_worker_count:void 0)??(s==null?void 0:s.worker_cards.length)??0,R=((Z=t==null?void 0:t.summary)==null?void 0:Z.joined_workers)??(typeof(T==null?void 0:T.active_agent_count)=="number"?T.active_agent_count:void 0)??u.length,w=g.length>0||v>0||f.length>0?"warn":m||a?"ok":"warn",E=((S=e==null?void 0:e.swarm_status)==null?void 0:S.lanes.filter(U=>U.present))??[];return ne(()=>{$e()},[]),ne(()=>{a!=null&&a.session_id&&Zt(a.session_id)},[a==null?void 0:a.session_id,n,(Se=t==null?void 0:t.detachment)==null?void 0:Se.session_id]),!m&&!a?Ws.value||Ln.value?i`<div class="empty-state">live war room 불러오는 중…</div>`:i`
      <section class="card command-section command-warroom-empty">
        <div class="card-title-row">
          <div class="card-title">라이브 워룸</div>
          <${z} panelId="command.warroom" compact=${!0} />
        </div>
        <div class="command-warroom-empty-copy">
          <strong>현재 live run 없음</strong>
          <p>활성 operation 또는 team session이 시작되면 이 화면이 자동으로 붙잡습니다.</p>
        </div>
        <div class="command-action-row">
          <${He} label="작전 보기" surface="operations" />
          <${He} label="스웜 보기" surface="swarm" />
          <${He} label="개입 열기" />
          <${He} label="제어 보기" surface="control" />
        </div>
      </section>
    `:i`
    <div class="command-section-stack">
      <section class="command-warroom-strip ${L(w)}">
        <div class="command-warroom-strip-head">
          <div>
            <span class="command-hero-kicker">Live War Room</span>
            <strong>${((Be=t==null?void 0:t.operation)==null?void 0:Be.objective)??(a==null?void 0:a.session_id)??"active run"}</strong>
            <div class="command-card-sub">
              ${((lt=t==null?void 0:t.operation)==null?void 0:lt.operation_id)??"operation 없음"}
              ${a!=null&&a.session_id?` · session ${a.session_id}`:""}
              ${(ct=t==null?void 0:t.detachment)!=null&&ct.detachment_id?` · detachment ${t.detachment.detachment_id}`:""}
            </div>
          </div>
          <div class="command-action-row">
            <${He}
              label="스웜 상세"
              surface="swarm"
              params=${{...(O=t==null?void 0:t.operation)!=null&&O.operation_id?{operation_id:t.operation.operation_id}:{},...t!=null&&t.run_id?{run_id:t.run_id}:{}}}
            />
            <${He} label="트레이스" surface="trace" />
            ${o?i`<${He}
                  label="체인"
                  surface="chains"
                  params=${{operation:o.operation.operation_id}}
                />`:null}
            <${He} label="Intervene" />
          </div>
        </div>
        <div class="command-warroom-strip-stats">
          <div class="monitor-stat-card">
            <span>Workers</span>
            <strong>${R??0}/${x??0}</strong>
            <small>${((Ae=t==null?void 0:t.summary)==null?void 0:Ae.completed_workers)??0} 완료 · ${u.length} 카드</small>
          </div>
          <div class="monitor-stat-card">
            <span>Runtime</span>
            <strong>${(dt=t==null?void 0:t.provider)!=null&&dt.runtime_blocker?"blocked":(ln=t==null?void 0:t.provider)!=null&&ln.provider_reachable?"ready":a?Sa(a.status):"check"}</strong>
            <small>slots ${((cn=t==null?void 0:t.provider)==null?void 0:cn.active_slots_now)??0}/${((es=t==null?void 0:t.provider)==null?void 0:es.actual_slots)??((ts=t==null?void 0:t.provider)==null?void 0:ts.total_slots)??0} · ctx ${((ns=t==null?void 0:t.provider)==null?void 0:ns.actual_ctx)??((ss=t==null?void 0:t.provider)==null?void 0:ss.ctx_per_slot)??0}</small>
          </div>
          <div class="monitor-stat-card ${L(g.length>0||v>0?"warn":"ok")}">
            <span>Pressure</span>
            <strong>${g.length+v+f.length}</strong>
            <small>blockers ${g.length} · approvals ${v} · confirms ${f.length}</small>
          </div>
          <div class="monitor-stat-card">
            <span>Last signal</span>
            <strong>${Q(A)}</strong>
            <small>${$?"message":C?"trace":"waiting"}</small>
          </div>
        </div>
      </section>

      <div class="command-warroom-grid">
        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">실행 흐름</div>
              <${z} panelId="command.warroom" compact=${!0} />
            </div>
            ${E.length>0?i`
                  <${bl} lanes=${E} />
                  <${yl} lanes=${E} />
                `:a?i`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${a.session_id}</strong>
                        <span class="command-chip ${L(Dt(a.status))}">${Sa(a.status)}</span>
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
              <${z} panelId="command.warroom" compact=${!0} />
            </div>
            ${u.length>0?i`<div class="command-card-stack">
                  ${u.map(U=>i`<${p_} worker=${U} />`)}
                </div>`:i`<div class="empty-state">활성 worker 카드가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Live Feed</div>
              <${z} panelId="command.warroom" compact=${!0} />
            </div>
            ${t&&t.recent_messages.length>0?i`<div class="command-trace-stack">
                  ${t.recent_messages.map(U=>i`
                    <article class="command-trace-row">
                      <div class="command-trace-main">
                        <div class="command-trace-head">
                          <strong>${U.from}</strong>
                          <span class="command-chip">${Q(U.timestamp)}</span>
                        </div>
                        <div class="command-card-sub">seq ${U.seq}</div>
                      </div>
                      <pre class="command-trace-detail">${U.content}</pre>
                    </article>
                  `)}
                </div>`:h.length>0||k.length>0?i`<div class="command-card-stack">
                    ${h.slice(0,4).map(U=>i`
                      <article class="command-guide-card ${$o(U)}">
                        <div class="command-guide-head">
                          <strong>${U.action_type}</strong>
                          <span class="command-chip ${$o(U)}">${U.target_type}</span>
                        </div>
                        <p>${U.reason}</p>
                      </article>
                    `)}
                    ${k.slice(0,3).map(U=>i`
                      <article class="command-alert ${L(U.severity)}">
                        <div class="command-card-head">
                          <strong>${U.kind}</strong>
                          <span class="command-chip ${L(U.severity)}">${U.severity}</span>
                        </div>
                        <p>${U.summary}</p>
                      </article>
                    `)}
                  </div>`:a!=null&&a.recent_events&&a.recent_events.length>0?i`<div class="command-trace-stack">
                      ${a.recent_events.slice(0,6).map((U,Ct)=>i`
                        <article class="command-trace-row">
                          <div class="command-trace-main">
                            <div class="command-trace-head">
                              <strong>session-event-${Ct+1}</strong>
                              <span class="command-chip">${a.session_id}</span>
                            </div>
                          </div>
                          <pre class="command-trace-detail">${Vs(U)}</pre>
                        </article>
                      `)}
                    </div>`:i`<div class="empty-state">메시지나 attention feed가 아직 없습니다.</div>`}
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Trace Feed</div>
              <${z} panelId="command.trace" compact=${!0} />
            </div>
            ${t&&t.recent_trace_events.length>0?i`<div class="command-trace-stack">
                  ${t.recent_trace_events.map(U=>i`<${Fi} event=${U} />`)}
                </div>`:i`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
          </section>
        </div>

        <div class="command-warroom-column">
          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Pressure</div>
              <${z} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${t?i`<${$l} swarm=${t} />`:null}
              ${g.length>0?g.map(U=>i`<${kl} blocker=${U} />`):i`<div class="command-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
              ${v>0?i`
                    <article class="command-guide-card warn">
                      <div class="command-guide-head">
                        <strong>Pending approvals</strong>
                        <span class="command-chip warn">${v}</span>
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
                        ${f.slice(0,3).map(U=>i`<span class="command-tag">${U.confirm_token}</span>`)}
                      </div>
                    </article>
                  `:null}
            </div>
          </section>

          <section class="card command-section">
            <div class="card-title-row">
              <div class="card-title">Focus Detail</div>
              <${z} panelId="command.warroom" compact=${!0} />
            </div>
            <div class="command-card-stack">
              ${t!=null&&t.operation?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${t.operation.objective}</strong>
                          <div class="command-card-sub">${t.operation.operation_id}</div>
                        </div>
                        <span class="command-chip ${L(Dt(t.operation.status))}">${t.operation.status}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Unit</span><span>${t.operation.assigned_unit_id}</span>
                        <span>Trace</span><span>${t.operation.trace_id}</span>
                        <span>Autonomy</span><span>${t.operation.autonomy_level??"n/a"}</span>
                        <span>Updated</span><span>${Q(t.operation.updated_at)}</span>
                      </div>
                    </article>
                  `:null}
              ${t!=null&&t.detachment?i`
                    <article class="command-card compact">
                      <div class="command-card-head">
                        <div>
                          <strong>${t.detachment.detachment_id}</strong>
                          <div class="command-card-sub">${t.detachment.assigned_unit_id}</div>
                        </div>
                        <span class="command-chip ${L(Dt(t.detachment.status))}">${t.detachment.status??"active"}</span>
                      </div>
                      <div class="command-card-grid">
                        <span>Leader</span><span>${t.detachment.leader_id??"unassigned"}</span>
                        <span>Roster</span><span>${t.detachment.roster.length}</span>
                        <span>Session</span><span>${t.detachment.session_id??"none"}</span>
                        <span>Heartbeat</span><span>${dl(t.detachment.heartbeat_deadline)}</span>
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
                        <span class="command-chip ${L(Dt(a.status))}">${Sa(a.status)}</span>
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
  `}function v_({source:e}){const t=Vl(null),[n,s]=zo(null);return ne(()=>{let a=!1;const o=t.current;return o?(o.innerHTML="",s(null),(async()=>{try{const c=await fv(),{svg:u}=await c.render(`command-chain-${_v()}`,e);if(a||!t.current)return;t.current.innerHTML=u}catch(c){if(a)return;s(c instanceof Error?c.message:"Mermaid render failed")}})(),()=>{a=!0,t.current&&(t.current.innerHTML="")}):void 0},[e]),i`
    <div class="command-chain-graph-shell">
      ${n?i`<div class="empty-state error">${n}</div>`:null}
      <div class="command-chain-graph" ref=${t}></div>
    </div>
  `}function __({overlay:e,selected:t,onSelect:n}){const s=e.operation.chain,a=e.runtime;return i`
    <button class="command-chain-item ${t?"selected":""}" onClick=${n}>
      <div class="command-card-head">
        <div>
          <strong>${e.operation.objective}</strong>
          <div class="command-card-sub">${e.operation.operation_id}</div>
        </div>
        <span class="command-chip ${Ze(s==null?void 0:s.status)}">${(s==null?void 0:s.status)??e.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${(s==null?void 0:s.kind)??"chain_dsl"}</span>
        ${s!=null&&s.chain_id?i`<span class="command-tag">${s.chain_id}</span>`:null}
        ${a?i`<span class="command-tag ${Ze(s==null?void 0:s.status)}">${Yn(a.progress)} progress</span>`:null}
      </div>
      <div class="command-card-sub">${ul(e.history)}</div>
    </button>
  `}function f_({item:e}){return i`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${e.chain_id??"unknown-chain"}</strong>
        <span class="command-chip ${Ze(e.event)}">${e.event}</span>
      </div>
      <div class="command-card-sub">${Q(e.timestamp)}</div>
      <div class="command-card-sub">${ul(e)}</div>
    </article>
  `}function g_({node:e}){return i`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${e.id}</strong>
        <span class="command-chip ${Ze(e.status)}">${e.status??"unknown"}</span>
      </div>
      <div class="command-card-sub">
        ${e.type??"node"}
        ${typeof e.duration_ms=="number"?` · ${e.duration_ms}ms`:""}
      </div>
      ${e.error?i`<div class="command-card-sub error-text">${e.error}</div>`:null}
    </article>
  `}function $_({card:e}){const t=e.operation,n=`pause:${t.operation_id}`,s=`resume:${t.operation_id}`,a=`recall:${t.operation_id}`,o=t.chain,l=(o==null?void 0:o.run_id)??null;return i`
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
        <span>Updated</span><span>${Q(t.updated_at)}</span>
      </div>
      ${o?i`
            <div class="command-tag-row">
              <span class="command-tag">${o.kind}</span>
              <span class="command-tag ${Ze(o.status)}">${o.status}</span>
              ${o.chain_id?i`<span class="command-tag">${o.chain_id}</span>`:null}
              ${o.run_id?i`<span class="command-tag">run ${o.run_id}</span>`:null}
            </div>
          `:null}
      ${t.checkpoint_ref?i`<div class="command-card-foot">Checkpoint ${t.checkpoint_ref}</div>`:null}
      <div class="command-action-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{yt("swarm"),ue("command",{surface:"swarm",operation_id:t.operation_id,...l?{run_id:l}:{}})}}
        >
          Swarm Live
        </button>
        ${o?i`
              <button
                class="control-btn ghost"
                onClick=${()=>{ji(t.operation_id),yt("chains"),ue("command",{surface:"chains",operation:t.operation_id})}}
              >
                Open Chain
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="active"?i`
              <button class="control-btn ghost" disabled=${ae(n)} onClick=${()=>et(()=>iv(t.operation_id))}>
                ${ae(n)?"Pausing…":"Pause"}
              </button>
              <button class="control-btn ghost" disabled=${ae(a)} onClick=${()=>et(()=>rv(t.operation_id))}>
                ${ae(a)?"Recalling…":"Recall"}
              </button>
            `:null}
        ${t.source==="managed"&&t.status==="paused"?i`
              <button class="control-btn ghost" disabled=${ae(s)} onClick=${()=>et(()=>ov(t.operation_id))}>
                ${ae(s)?"Resuming…":"Resume"}
              </button>
            `:null}
      </div>
    </article>
  `}function h_({card:e}){var n;const t=e.detachment;return i`
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
        <span>Progress</span><span>${Q(t.last_progress_at)}</span>
        <span>Heartbeat</span><span>${dl(t.heartbeat_deadline)}</span>
        <span>Updated</span><span>${Q(t.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${t.heartbeat_deadline?i`<span class="command-tag ${mv(t.heartbeat_deadline)}">
              deadline ${t.heartbeat_deadline}
            </span>`:null}
      </div>
    </article>
  `}function y_(){const e=Ee.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Operations</div>
          <${z} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.operations.operations.length>0?i`<div class="command-card-stack">
              ${e.operations.operations.map(t=>i`<${$_} card=${t} />`)}
            </div>`:i`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Detachments</div>
          <${z} panelId="command.operations" compact=${!0} />
        </div>
        ${e&&e.detachments.detachments.length>0?i`<div class="command-card-stack">
              ${e.detachments.detachments.map(t=>i`<${h_} card=${t} />`)}
            </div>`:i`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `}function b_(){var c,u,m,v,f,g,h,k,$,C,A,T,x,R,w,E;const e=Qn.value,t=(e==null?void 0:e.operations)??[],n=Ht.value,s=t.find(J=>J.operation.operation_id===n)??t[0]??null,a=((c=s==null?void 0:s.operation.chain)==null?void 0:c.run_id)??null,o=((u=Mn.value)==null?void 0:u.run)??(s==null?void 0:s.preview_run)??null,l=!((m=Mn.value)!=null&&m.run)&&!!(s!=null&&s.preview_run);return ne(()=>{a?sv(a):nv()},[a]),i`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chains</div>
          <${z} panelId="command.chains" compact=${!0} />
        </div>
        <article class="command-guide-card ${Ze(e==null?void 0:e.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${Ze(e==null?void 0:e.connection.status)}">${(e==null?void 0:e.connection.status)??"disconnected"}</span>
          </div>
          <p>${(e==null?void 0:e.connection.message)??"Chain summary is aggregated through the MASC proxy."}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${(e==null?void 0:e.connection.base_url)??"n/a"}</span>
            <span>Linked Ops</span><span>${((v=e==null?void 0:e.summary)==null?void 0:v.linked_operations)??0}</span>
            <span>Active Chains</span><span>${((f=e==null?void 0:e.summary)==null?void 0:f.active_chains)??0}</span>
            <span>Recent Failures</span><span>${((g=e==null?void 0:e.summary)==null?void 0:g.recent_failures)??0}</span>
            <span>Last Event</span><span>${Q((h=e==null?void 0:e.summary)==null?void 0:h.last_history_event_at)}</span>
          </div>
        </article>

        ${Gs.value?i`<div class="empty-state error">${Gs.value}</div>`:null}

        ${ci.value&&!e?i`<div class="empty-state">Loading chain overlays…</div>`:t.length>0?i`
                <div class="command-chain-list">
                  ${t.map(J=>i`
                    <${__}
                      overlay=${J}
                      selected=${(s==null?void 0:s.operation.operation_id)===J.operation.operation_id}
                      onSelect=${()=>ji(J.operation.operation_id)}
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
                  ${e.recent_history.slice(0,6).map(J=>i`<${f_} item=${J} />`)}
                </div>
              `:i`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Chain Detail</div>
          <${z} panelId="command.chains" compact=${!0} />
        </div>
        ${s?i`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${s.operation.objective}</strong>
                    <div class="command-card-sub">${s.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${Ze((k=s.operation.chain)==null?void 0:k.status)}">
                    ${(($=s.operation.chain)==null?void 0:$.status)??s.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${((C=s.operation.chain)==null?void 0:C.kind)??"chain_dsl"}</span>
                  <span>Chain ID</span><span>${((A=s.operation.chain)==null?void 0:A.chain_id)??"goal-driven"}</span>
                  <span>Run ID</span><span>${a??"not materialized"}</span>
                  <span>Progress</span><span>${Yn((T=s.runtime)==null?void 0:T.progress)}</span>
                  <span>Elapsed</span><span>${vn((x=s.runtime)==null?void 0:x.elapsed_sec)}</span>
                  <span>Updated</span><span>${Q(((R=s.operation.chain)==null?void 0:R.last_sync_at)??s.operation.updated_at)}</span>
                </div>
                ${(w=s.operation.chain)!=null&&w.goal?i`<div class="command-card-foot">${s.operation.chain.goal}</div>`:null}
              </article>

              ${s.mermaid?i`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${((E=s.operation.chain)==null?void 0:E.chain_id)??"graph"}</span>
                      </div>
                      <${v_} source=${s.mermaid} />
                    </div>
                  `:i`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${(o==null?void 0:o.success)===!1?"bad":"ok"}">
                    ${o?o.success===!1?"failed":l?"preview":"captured":"pending"}
                  </span>
                </div>
                ${Js.value?i`<div class="empty-state">Loading run detail…</div>`:zn.value?i`<div class="empty-state error">${zn.value}</div>`:o&&o.nodes.length>0?i`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${o.chain_id}</span>
                            <span>Run</span><span>${o.run_id??"preview only"}</span>
                            <span>Duration</span><span>${o.duration_ms!=null?`${o.duration_ms}ms`:"n/a"}</span>
                            <span>Nodes</span><span>${o.nodes.length}</span>
                          </div>
                          ${l?i`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`:null}
                          <div class="command-card-stack">
                            ${o.nodes.map(J=>i`<${g_} node=${J} />`)}
                          </div>
                        `:i`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `:i`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `}function k_({decision:e}){const t=`approve:${e.decision_id}`,n=`deny:${e.decision_id}`,s=e.source==="projected_operator";return i`
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
        <span>Created</span><span>${Q(e.created_at)}</span>
        <span>Reason</span><span>${e.reason??"n/a"}</span>
      </div>
      ${e.status==="pending"&&!s?i`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${ae(t)} onClick=${()=>et(()=>cv(e.decision_id))}>
                ${ae(t)?"Approving…":"Approve"}
              </button>
              <button class="control-btn ghost" disabled=${ae(n)} onClick=${()=>et(()=>dv(e.decision_id))}>
                ${ae(n)?"Denying…":"Deny"}
              </button>
            </div>
          `:null}
      ${s?i`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>`:null}
    </article>
  `}function x_({row:e}){var c,u,m;const t=e.unit,n=`freeze:${t.unit_id}`,s=`kill:${t.unit_id}`,a=!!((c=t.policy)!=null&&c.frozen),o=!!((u=t.policy)!=null&&u.kill_switch),l=Math.round((e.utilization??0)*100);return i`
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
        <span>Kill Switch</span><span>${o?"on":"off"}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${ae(n)} onClick=${()=>et(()=>uv(t.unit_id,!a))}>
          ${ae(n)?"Applying…":a?"Unfreeze":"Freeze"}
        </button>
        <button class="control-btn ghost" disabled=${ae(s)} onClick=${()=>et(()=>pv(t.unit_id,!o))}>
          ${ae(s)?"Applying…":o?"Clear Kill Switch":"Enable Kill Switch"}
        </button>
      </div>
    </article>
  `}function S_(){const e=Ee.value;return i`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">승인 대기</div>
          <${z} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.decisions.decisions.length>0?i`<div class="command-card-stack">
              ${e.decisions.decisions.map(t=>i`<${k_} decision=${t} />`)}
            </div>`:i`<div class="empty-state">지금 승인 대기 항목은 없습니다.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title-row">
          <div class="card-title">Unit 제어</div>
          <${z} panelId="command.control" compact=${!0} />
        </div>
        ${e&&e.capacity.capacity.length>0?i`<div class="command-card-stack">
              ${e.capacity.capacity.map(t=>i`<${x_} row=${t} />`)}
            </div>`:i`<div class="empty-state">제어할 capacity 행이 아직 없습니다.</div>`}
      </section>
    </div>
  `}function A_(){return i`
    <div class="command-surface-tabs grouped">
      ${$v.map(e=>i`
        <div class="command-tab-group" key=${e.id}>
          <span class="command-tab-group-label">${e.label}</span>
          <div class="command-tab-group-items">
            ${pl.filter(t=>t.group===e.id).map(t=>i`
                <button
                  class="command-surface-tab ${X.value===t.id?"active":""}"
                  onClick=${()=>{yt(t.id),ue("command",ml(t.id))}}
                >
                  ${t.label}
                </button>
              `)}
          </div>
        </div>
      `)}
    </div>
  `}function C_(){if(X.value==="warroom")return i`<${m_} />`;if(X.value==="summary")return i`<${Hv} />`;if(X.value==="swarm")return i`<${c_} />`;if(!Ee.value)return i`<${Gv} />`;switch(X.value){case"chains":return i`<${b_} />`;case"topology":return i`<${Vv} />`;case"alerts":return i`<${Qv} />`;case"trace":return i`<${Yv} />`;case"control":return i`<${S_} />`;case"operations":default:return i`<${y_} />`}}function I_(){return ne(()=>{Et(),Gt(),av(),Ve()},[]),ne(()=>{if(j.value.tab!=="command")return;const e=j.value.params.surface,t=j.value.params.operation,n=Jn(j.value);if(go(e))yt(e);else if(n){const s=Ir(n);go(s)&&yt(s)}else e||yt("warroom");t&&ji(t),(e==="swarm"||e==="warroom"||X.value==="warroom")&&Ve(),(e==="warroom"||X.value==="warroom")&&$e()},[j.value.tab,j.value.params.surface,j.value.params.operation,j.value.params.operation_id,j.value.params.run_id,j.value.params.source,j.value.params.action_type,j.value.params.target_type,j.value.params.target_id,j.value.params.focus_kind]),ne(()=>{let e=null;const t=()=>{e||(e=window.setTimeout(()=>{e=null,Et(),Gt(),(X.value==="swarm"||X.value==="warroom")&&Ve(),X.value==="warroom"&&$e()},250))},n=new EventSource(xv()),s=yv.map(a=>{const o=()=>t();return n.addEventListener(a,o),{type:a,handler:o}});return n.onerror=()=>{t()},()=>{s.forEach(({type:a,handler:o})=>{n.removeEventListener(a,o)}),n.close(),e&&window.clearTimeout(e)}},[]),ne(()=>{const e=window.setInterval(()=>{if(document.visibilityState==="hidden")return;const t=X.value;t!=="swarm"&&t!=="warroom"||(Et(),Ve(),t==="warroom"&&$e())},5e3);return()=>{window.clearInterval(e)}},[]),i`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>지휘면</h2>
          <p>기본 진입은 라이브 워룸입니다. 실제 run, worker, message, trace를 먼저 보고 필요할 때만 detail surface로 내려갑니다.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{et(()=>lv())}}
            disabled=${ae("dispatch:tick")}
          >
            ${ae("dispatch:tick")?"정리 중...":"Tick 실행"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Et(),Gt(),Ve(),X.value==="warroom"&&$e()}}
            disabled=${Os.value}
          >
            ${Os.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${Fs.value?i`<div class="empty-state error">${Fs.value}</div>`:null}
      ${Us.value?i`<div class="empty-state error">${Us.value}</div>`:null}
      <${he} surfaceId="command" />
      <${Fv} />
      ${X.value==="warroom"?null:i`<${Kv} />`}
      <${A_} />
      <${C_} />
    </section>
  `}const xl="masc_dashboard_agent_name";function T_(){var t,n,s;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||((s=localStorage.getItem(xl))==null?void 0:s.trim())||"dashboard"}const va=_(T_()),Jt=_(""),di=_("운영 점검"),Vt=_(""),En=_(""),Dn=_("2"),en=_(""),we=_("note"),jn=_(""),On=_(""),qn=_(""),Fn=_("2"),Qs=_("운영자 중지 요청"),Ys=_(""),Qt=_(""),ls=_(null);function R_(e){const t=e.trim()||"dashboard";va.value=t,localStorage.setItem(xl,t)}function Sl(e){if(e==null)return"";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function w_(e){return typeof e!="number"||!Number.isFinite(e)?"확인 없음":e<60?`${Math.round(e)}초 전`:e<3600?`${Math.round(e/60)}분 전`:`${Math.round(e/3600)}시간 전`}function tn(e){return typeof e=="string"?e.trim().toLowerCase():""}function P_(e){var s;const t=tn(e.status);if(t==="paused")return"bad";if(t===""||t==="unknown")return"warn";const n=tn((s=e.team_health)==null?void 0:s.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||t&&t!=="active"&&t!=="running"&&t!=="ended"?"warn":"ok"}function Aa(e){const t=tn(e.status);return t==="offline"||t==="inactive"||t==="error"?"bad":t===""||t==="unknown"||(e.context_ratio??0)>=.8||e.context_ratio==null||e.last_turn_ago_s==null||(e.last_turn_ago_s??0)>=3600?"warn":"ok"}function ho(e){return e.some(t=>tn(t.severity)==="bad")?"bad":e.length>0?"warn":"ok"}function L_(e){return e.target_type==="team_session"}function N_(e){return e.target_type==="keeper"}function Xs(e){switch(e){case"broadcast":return"방송";case"room_pause":return"room 일시정지";case"room_resume":return"room 재개";case"team_turn":return"세션 업데이트";case"team_note":return"세션 노트";case"team_broadcast":return"세션 방송";case"team_task_inject":return"세션 작업 주입";case"task_inject":return"작업 주입";case"team_stop":return"세션 중지";case"keeper_message":return"keeper 메시지";case"keeper_msg":return"keeper 메시지";case"swarm_run_continue":return"swarm run 계속";case"swarm_run_rerun":return"swarm run 재실행";case"swarm_run_abandon":return"swarm run 포기";default:return(e==null?void 0:e.trim())||"액션"}}function Zs(e){switch(e){case"room":return"room";case"team_session":return"session";case"keeper":return"keeper";case"swarm_run":return"swarm run";default:return(e==null?void 0:e.trim())||"target"}}function _n(e){switch(tn(e)){case"running":case"active":return"진행 중";case"paused":return"일시정지";case"ended":case"done":return"종료";case"offline":return"오프라인";case"idle":return"대기";case"unknown":case"":return"확인 필요";default:return(e==null?void 0:e.trim())||"확인 필요"}}function Al(e){return e?"확인 후 실행":"즉시 실행"}function M_(e){switch(e){case"note":return"노트";case"broadcast":return"방송";case"task":return"작업";default:return e}}function pe(e,t){if(!e)return null;const n=e[t];return typeof n=="string"&&n.trim()!==""?n.trim():typeof n=="number"&&Number.isFinite(n)?String(n):null}function z_(e){if(e.action_type==="team_task_inject")return"task";if(e.action_type==="team_broadcast")return"broadcast";if(e.action_type==="team_note")return"note";if(e.action_type==="team_turn"){const t=pe(e.suggested_payload,"turn_kind");if(t==="broadcast"||t==="task")return t}return"note"}function E_(e){const t=e.suggested_payload;if(e.target_type==="room"){if(e.action_type==="broadcast"){Jt.value=pe(t,"message")??e.summary;return}e.action_type==="task_inject"&&(Vt.value=pe(t,"title")??"운영자 주입 작업",En.value=pe(t,"description")??e.summary,Dn.value=pe(t,"priority")??Dn.value);return}if(e.target_type==="team_session"){if(e.target_id&&(en.value=e.target_id),e.action_type==="team_stop"){Qs.value=pe(t,"reason")??e.summary;return}we.value=z_(e);const n=pe(t,"message");n&&(jn.value=n),we.value==="task"&&(On.value=pe(t,"task_title")??pe(t,"title")??"운영자 주입 작업",qn.value=pe(t,"task_description")??pe(t,"description")??e.summary,Fn.value=pe(t,"task_priority")??pe(t,"priority")??Fn.value);return}e.target_type==="keeper"&&(e.target_id&&(Ys.value=e.target_id),Qt.value=pe(t,"message")??e.summary)}function D_(e,t,n){return!e||!e.target_type||e.target_type==="room"?!0:e.target_type==="team_session"?!!e.target_id&&t.some(s=>s.session_id===e.target_id):e.target_type==="keeper"?!!e.target_id&&n.some(s=>s.name===e.target_id):!0}async function At(e){const t=va.value.trim()||"dashboard";try{const n=await Ur({actor:t,action_type:e.action_type,target_type:e.target_type,target_id:e.target_id,payload:e.payload});return n.confirm_required?P("확인 대기열에 올렸습니다","warning"):P(e.successMessage,"success"),n}catch(n){const s=n instanceof Error?n.message:"개입 실행에 실패했습니다";return P(s,"error"),null}}async function yo(){const e=Jt.value.trim();if(!e)return;await At({action_type:"broadcast",target_type:"room",payload:{message:e},successMessage:"방송을 보냈습니다"})&&(Jt.value="")}async function j_(){await At({action_type:"room_pause",target_type:"room",payload:{reason:di.value.trim()||"운영 점검"},successMessage:"room 일시정지를 요청했습니다"})}async function Cl(){await At({action_type:"room_resume",target_type:"room",payload:{},successMessage:"room 재개를 요청했습니다"})}async function O_(){const e=Vt.value.trim();if(!e)return;await At({action_type:"task_inject",target_type:"room",payload:{title:e,description:En.value.trim()||"Intervene 화면에서 주입",priority:Number.parseInt(Dn.value,10)||2},successMessage:"작업 주입을 보냈습니다"})&&(Vt.value="",En.value="")}async function q_(){var l;const e=ve.value,t=en.value||((l=e==null?void 0:e.sessions[0])==null?void 0:l.session_id)||"";if(!t){P("먼저 세션을 고르세요","warning");return}const n={},s=jn.value.trim();s&&(n.message=s);let a="team_note";we.value==="broadcast"?a="team_broadcast":we.value==="task"&&(a="team_task_inject"),we.value==="task"&&(n.task_title=On.value.trim()||"운영자 주입 작업",n.task_description=qn.value.trim()||"Intervene 화면에서 주입",n.task_priority=Number.parseInt(Fn.value,10)||2),await At({action_type:a,target_type:"team_session",target_id:t,payload:n,successMessage:"세션 액션을 적용했습니다"})&&(jn.value="",we.value==="task"&&(On.value="",qn.value=""))}async function F_(){var n;const e=ve.value,t=en.value||((n=e==null?void 0:e.sessions[0])==null?void 0:n.session_id)||"";if(!t){P("먼저 세션을 고르세요","warning");return}await At({action_type:"team_stop",target_type:"team_session",target_id:t,payload:{reason:Qs.value.trim()||"운영자 중지 요청"},successMessage:"세션 중지를 요청했습니다"})}async function K_(){var a;const e=ve.value,t=Ys.value||((a=e==null?void 0:e.keepers[0])==null?void 0:a.name)||"",n=Qt.value.trim();if(!t){P("먼저 keeper를 고르세요","warning");return}if(!n)return;await At({action_type:"keeper_message",target_type:"keeper",target_id:t,payload:{message:n},successMessage:`${t}에게 메시지를 보냈습니다`})&&(Qt.value="")}async function U_(e){const t=va.value.trim()||"dashboard";try{await Br(t,e),P("확인 실행을 완료했습니다","success")}catch(n){const s=n instanceof Error?n.message:"확인 실행에 실패했습니다";P(s,"error")}}function B_(){const e=ve.value,t=Ni.value,n=(e==null?void 0:e.room)??{},s=(e==null?void 0:e.pending_confirms)??[],a=(e==null?void 0:e.recent_messages)??[],o=(t==null?void 0:t.recommended_actions)??[],l=a.slice(0,5);return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Room 개입</div>
          <${z} panelId="intervene.action_studio" compact=${!0} />
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
        </div>

        <label class="control-label" for="ops-broadcast">Room 방송</label>
        <div class="control-row">
          <input
            id="ops-broadcast"
            class="control-input"
            type="text"
            placeholder="@agent 또는 room 전체 공지"
            value=${Jt.value}
            onInput=${c=>{Jt.value=c.target.value}}
            onKeyDown=${c=>{c.key==="Enter"&&yo()}}
            disabled=${W.value}
          />
          <button class="control-btn" onClick=${()=>{yo()}} disabled=${W.value||Jt.value.trim()===""}>
            보내기
          </button>
        </div>

        <label class="control-label" for="ops-pause-reason">일시정지 / 재개</label>
        <div class="control-row ops-split-row">
          <input
            id="ops-pause-reason"
            class="control-input"
            type="text"
            value=${di.value}
            onInput=${c=>{di.value=c.target.value}}
            disabled=${W.value}
          />
          <button class="control-btn ghost" onClick=${()=>{j_()}} disabled=${W.value}>
            일시정지
          </button>
          <button class="control-btn ghost" onClick=${()=>{Cl()}} disabled=${W.value}>
            재개
          </button>
        </div>

        <div class="ops-section-head">작업 주입</div>
        <input
          class="control-input"
          type="text"
          placeholder="작업 제목"
          value=${Vt.value}
          onInput=${c=>{Vt.value=c.target.value}}
          disabled=${W.value}
        />
        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="작업 설명"
          value=${En.value}
          onInput=${c=>{En.value=c.target.value}}
          disabled=${W.value}
        ></textarea>
        <div class="control-row ops-split-row">
          <select
            class="control-input ops-select"
            value=${Dn.value}
            onChange=${c=>{Dn.value=c.target.value}}
            disabled=${W.value}
          >
            <option value="1">P1</option>
            <option value="2">P2</option>
            <option value="3">P3</option>
            <option value="4">P4</option>
            <option value="5">P5</option>
          </select>
          <button class="control-btn" onClick=${()=>{O_()}} disabled=${W.value||Vt.value.trim()===""}>
            주입
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">추천 개입</div>
          <${z} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드 digest가 지금 가장 작은 다음 행동을 추천합니다.</p>
        ${Nn.value&&!t?i`
          <div class="ops-empty">개입 추천을 불러오는 중입니다...</div>
        `:o.length>0?i`
          <div class="ops-log-list">
            ${o.map(c=>i`
              <article key=${`${c.action_type}:${c.target_type}:${c.target_id??"room"}`} class="ops-log-entry ${c.severity}">
                <div class="ops-log-head">
                  <strong>${Xs(c.action_type)}</strong>
                  <span>${Zs(c.target_type)}${c.target_id?` · ${c.target_id}`:""}</span>
                  <span>${Al(c.confirm_required)}</span>
                </div>
                <div class="ops-log-body">${c.reason}</div>
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
          <${z} panelId="intervene.pending_confirmations" compact=${!0} />
        </div>
        <p class="ops-context-note">미리보기만 끝났고 아직 사람이 눌러줘야 하는 액션만 남깁니다.</p>
        ${s.length>0?i`
          <div class="ops-confirmation-list">
            ${s.map(c=>i`
              <article key=${c.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${Xs(c.action_type)}</strong>
                  <span>${Zs(c.target_type)}${c.target_id?` · ${c.target_id}`:""}</span>
                  <span>${c.delegated_tool??"위임 도구 확인 필요"}</span>
                </div>
                ${c.preview?i`<pre class="ops-code-block compact">${Sl(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{U_(c.confirm_token)}} disabled=${W.value}>
                    실행
                  </button>
                  <span class="ops-token">${c.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        `:i`<div class="ops-empty">지금 승인 대기는 없습니다.</div>`}
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 Room 메시지</div>
          <${z} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <p class="ops-context-note">room 맥락은 참고만 하고, 실제 판단은 위의 개입 큐 기준으로 합니다.</p>
        ${l.length>0?i`
          <div class="ops-feed-list">
            ${l.map(c=>i`
              <article key=${c.seq??c.id??c.timestamp} class="ops-feed-item">
                <div class="ops-feed-meta">
                  <strong>${c.from}</strong>
                  <span>${c.timestamp}</span>
                </div>
                <div class="ops-feed-content">${c.content}</div>
              </article>
            `)}
          </div>
        `:i`<div class="ops-empty">최근 room 메시지가 없습니다.</div>`}
      </section>
    </div>
  `}function W_(){const e=ve.value,t=Ne.value,n=(e==null?void 0:e.sessions)??[],s=n.find(a=>a.session_id===en.value)??n[0]??null;return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">Session 개입</div>
          <${z} panelId="intervene.session_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">어떤 세션이 뜨거운지 고르고, 그 세션에만 노트, 작업, 중지를 적용합니다.</p>

        <div class="ops-entity-list">
          ${n.length===0?i`<div class="ops-empty">지금 활성 team session이 없습니다.</div>`:n.map(a=>{var o;return i`
            <button
              key=${a.session_id}
              class="ops-entity-card ${(s==null?void 0:s.session_id)===a.session_id?"active":""}"
              onClick=${()=>{en.value=a.session_id}}
            >
              <div class="ops-entity-title-row">
                <strong>${a.session_id}</strong>
                <span class="status-badge ${a.status??"idle"}">${_n(a.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${Math.round(a.progress_pct??0)}%</span>
                <span>${a.done_delta_total??0}건 완료</span>
                <span>${(o=a.team_health)!=null&&o.status?_n(String(a.team_health.status)):"상태 확인 필요"}</span>
              </div>
            </button>
          `})}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Session 요약</div>
          <${z} panelId="intervene.session_digest" compact=${!0} />
        </div>
        <p class="ops-context-note">snapshot이 아니라 digest 기준 attention과 worker 카드를 보여줍니다.</p>
        ${s&&t?i`
          <div class="ops-log-list">
            ${t.attention_items.length>0?t.attention_items.map(a=>i`
              <article key=${`${a.kind}:${a.target_id??"session"}`} class="ops-log-entry ${a.severity}">
                <div class="ops-log-head">
                  <strong>${a.kind}</strong>
                  <span>${Zs(a.target_type)}${a.target_id?` · ${a.target_id}`:""}</span>
                </div>
                <div class="ops-log-body">${a.summary}</div>
              </article>
            `):i`<div class="ops-empty">이 세션의 attention item은 없습니다.</div>`}
            ${t.worker_cards.length>0?t.worker_cards.map(a=>i`
              <article key=${`${a.actor??a.spawn_role??"worker"}:${a.spawn_agent??a.runtime_pool??"runtime"}`} class="ops-log-entry">
                <div class="ops-log-head">
                  <strong>${a.actor??a.spawn_role??"worker"}</strong>
                  <span>${_n(a.status)}</span>
                  <span>${a.spawn_agent??a.runtime_pool??"runtime 확인 필요"}</span>
                </div>
                <div class="ops-log-body">
                  ${a.worker_class??"worker"}${a.lane_id?` · ${a.lane_id}`:""}${a.routing_reason?` · ${a.routing_reason}`:""}
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
          <${z} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 세션에만 메모, 작업, 체크포인트, 중지 요청을 보냅니다.</p>

        ${s?i`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${s.session_id}</div>
            <div class="ops-detail-meta">
              <span>상태: ${_n(s.status)}</span>
              <span>경과: ${s.elapsed_sec??0}초</span>
              <span>남은 시간: ${s.remaining_sec??0}초</span>
            </div>
            ${s.recent_events&&s.recent_events.length>0?i`
              <pre class="ops-code-block compact">${Sl(s.recent_events.slice(-3))}</pre>
            `:null}
          </div>
        `:i`<div class="ops-empty">먼저 세션을 하나 고르세요.</div>`}

        <label class="control-label" for="ops-turn-kind">세션 액션</label>
        <div class="control-row ops-split-row">
          <select
            id="ops-turn-kind"
            class="control-input ops-select"
            value=${we.value}
            onChange=${a=>{we.value=a.target.value}}
            disabled=${W.value||!s}
          >
            <option value="note">노트</option>
            <option value="broadcast">방송</option>
            <option value="task">작업</option>
          </select>
          <button class="control-btn" onClick=${()=>{q_()}} disabled=${W.value||!s}>
            적용
          </button>
        </div>
        <div class="ops-context-note">현재 선택: ${M_(we.value)}</div>

        <textarea
          class="control-textarea"
          rows=${3}
          placeholder="세션에 남길 메시지"
          value=${jn.value}
          onInput=${a=>{jn.value=a.target.value}}
          disabled=${W.value||!s}
        ></textarea>

        ${we.value==="task"?i`
          <input
            class="control-input"
            type="text"
            placeholder="주입할 작업 제목"
            value=${On.value}
            onInput=${a=>{On.value=a.target.value}}
            disabled=${W.value||!s}
          />
          <textarea
            class="control-textarea"
            rows=${2}
            placeholder="주입할 작업 설명"
            value=${qn.value}
            onInput=${a=>{qn.value=a.target.value}}
            disabled=${W.value||!s}
          ></textarea>
          <select
            class="control-input ops-select"
            value=${Fn.value}
            onChange=${a=>{Fn.value=a.target.value}}
            disabled=${W.value||!s}
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
            value=${Qs.value}
            onInput=${a=>{Qs.value=a.target.value}}
            disabled=${W.value||!s}
          />
          <button class="control-btn ghost" onClick=${()=>{F_()}} disabled=${W.value||!s}>
            세션 중지
          </button>
        </div>
      </section>
    </div>
  `}function H_(){var a;const e=ve.value,t=(e==null?void 0:e.keepers)??[],n=(e==null?void 0:e.available_actions)??[],s=t.find(o=>o.name===Ys.value)??t[0]??null;return i`
    <div class="ops-column">
      <section class="card ops-panel ops-lane-panel ops-keeper-section">
        <div class="card-title-row">
          <div class="card-title">Keeper 개입</div>
          <${z} panelId="intervene.keeper_queue" compact=${!0} />
        </div>
        <p class="ops-context-note">장기 실행 중인 keeper를 고르고 바로 probe나 방향 수정 메시지를 보냅니다.</p>

        <div class="ops-entity-list">
          ${t.length===0?i`<div class="ops-empty">지금 보이는 keeper가 없습니다.</div>`:t.map(o=>i`
            <button
              key=${o.name}
              class="ops-entity-card ${(s==null?void 0:s.name)===o.name?"active":""}"
              onClick=${()=>{Ys.value=o.name}}
            >
              <div class="ops-entity-title-row">
                <strong>${o.name}</strong>
                <span class="status-badge ${o.status??"idle"}">${_n(o.status)}</span>
              </div>
              <div class="ops-entity-meta">
                <span>${o.model??"model 확인 필요"}</span>
                <span>${typeof o.context_ratio=="number"?`${Math.round(o.context_ratio*100)}% ctx`:"ctx 확인 필요"}</span>
                <span>${w_(o.last_turn_ago_s)}</span>
              </div>
            </button>
          `)}
        </div>
      </section>

      <section class="card ops-panel ops-lane-panel">
        <div class="card-title-row">
          <div class="card-title">선택한 Keeper 액션</div>
          <${z} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">선택한 keeper에만 직접 메시지를 보내서 probe, 수정, 재지시를 합니다.</p>

        ${s?i`
          <div class="ops-detail-card">
            <div class="ops-detail-title">${s.name}</div>
            <div class="ops-detail-meta">
              <span>자율성: ${s.autonomy_level??"확인 없음"}</span>
              <span>세대: ${s.generation??0}</span>
              <span>활성 목표: ${((a=s.active_goal_ids)==null?void 0:a.length)??0}</span>
            </div>
          </div>
        `:i`<div class="ops-empty">먼저 keeper를 하나 고르세요.</div>`}

        <label class="control-label" for="ops-keeper-message">Keeper 메시지</label>
        <textarea
          id="ops-keeper-message"
          class="control-textarea"
          rows=${6}
          placeholder="구조화된 probe, 방향 수정, 재지시 내용을 적으세요"
          value=${Qt.value}
          onInput=${o=>{Qt.value=o.target.value}}
          disabled=${W.value||!s}
        ></textarea>
        <div class="control-row">
          <button class="control-btn" onClick=${()=>{K_()}} disabled=${W.value||!s||Qt.value.trim()===""}>
            keeper에 보내기
          </button>
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">가능한 액션 목록</div>
          <${z} panelId="intervene.action_studio" compact=${!0} />
        </div>
        <p class="ops-context-note">백엔드가 현재 허용한다고 광고하는 액션입니다. 일부는 이 화면의 폼과 1:1로 연결됩니다.</p>
        <div class="ops-log-list">
          ${n.length?n.map(o=>i`
                <article key=${`${o.action_type}:${o.target_type}`} class="ops-log-entry">
                  <div class="ops-log-head">
                    <strong>${Xs(o.action_type)}</strong>
                    <span>${Zs(o.target_type)}</span>
                    <span>${Al(o.confirm_required)}</span>
                  </div>
                  <div class="ops-log-body">${o.description??"설명이 아직 없습니다."}</div>
                </article>
              `):i`<div class="ops-empty">노출된 액션 설명이 없습니다.</div>`}
        </div>
      </section>

      <section class="card ops-panel">
        <div class="card-title-row">
          <div class="card-title">최근 개입 로그</div>
          <${z} panelId="intervene.recommended_actions" compact=${!0} />
        </div>
        <div class="ops-log-list">
          ${Ds.value.length===0?i`
            <div class="ops-empty">이 세션에서 실행한 개입이 아직 없습니다.</div>
          `:Ds.value.map(o=>i`
            <article key=${o.id} class="ops-log-entry ${o.outcome}">
              <div class="ops-log-head">
                <strong>${Xs(o.action_type)}</strong>
                <span>${o.target_label}</span>
                <span>${o.at}</span>
              </div>
              <div class="ops-log-body">${o.message}</div>
            </article>
          `)}
        </div>
      </section>
    </div>
  `}function G_(){var $,C;const e=ve.value,t=j.value.tab==="intervene"?Jn(j.value):null,n=Ni.value,s=(e==null?void 0:e.room)??{},a=(e==null?void 0:e.sessions)??[],o=(e==null?void 0:e.keepers)??[],l=(e==null?void 0:e.pending_confirms)??[],c=a.find(A=>A.session_id===en.value)??a[0]??null,u=(n==null?void 0:n.attention_items)??[],m=u.filter(L_),v=u.filter(N_),f=a.filter(A=>P_(A)!=="ok"),g=o.filter(A=>Aa(A)!=="ok"),h=D_(t,a,o);ne(()=>{kt()},[]),ne(()=>{if(j.value.tab!=="intervene"){ls.value=null;return}if(!t){ls.value=null;return}ls.value!==t.id&&(ls.value=t.id,E_(t))},[j.value.tab,j.value.params.source,j.value.params.action_type,j.value.params.target_type,j.value.params.target_id,j.value.params.focus_kind,t==null?void 0:t.id]),ne(()=>{const A=(c==null?void 0:c.session_id)??null;Zt(A)},[c==null?void 0:c.session_id]);const k=[{key:"room",label:"Room 게이트",value:s.paused?"일시정지":"열림",detail:s.paused?`재개 전환 대기 중${s.pause_reason?` · ${s.pause_reason}`:""}`:"지금은 새 액션과 새 작업을 바로 받을 수 있습니다",tone:s.paused?"bad":"ok"},{key:"confirm",label:"확인 대기",value:l.length,detail:l.length>0?"미리보기만 된 개입이 아직 사람 확인을 기다리고 있습니다":"지금 막혀 있는 확인 대기는 없습니다",tone:l.length>0?"warn":"ok"},{key:"session",label:"세션 리스크",value:m.length>0?m.length:a.length,detail:m.length>0?(($=m[0])==null?void 0:$.summary)??"세션 중 하나가 방향 수정이나 중지 판단을 기다리고 있습니다":a.length===0?"지금 관리 중인 team session이 없습니다":"세션 쪽 긴급 attention은 현재 없습니다",tone:m.length>0?ho(m):a.length===0?"warn":f.some(A=>tn(A.status)==="paused")?"bad":f.length>0?"warn":"ok"},{key:"keeper",label:"Keeper 압력",value:v.length>0?v.length:g.length,detail:v.length>0?((C=v[0])==null?void 0:C.summary)??"직접 메시지나 상태 점검이 필요한 keeper가 있습니다":g.length>0?"stale, offline, telemetry 누락 keeper가 보입니다":"지금은 keeper 쪽이 비교적 안정적입니다",tone:v.length>0?ho(v):g.some(A=>Aa(A)==="bad")?"bad":g.length>0?"warn":"ok"}];return i`
    <section class="ops-view">
      <${he} surfaceId="intervene" />
      <div class="ops-header card">
        <div>
          <div class="card-title-row">
            <div class="card-title">Intervene</div>
            <${z} panelId="intervene.action_studio" compact=${!0} />
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
            value=${va.value}
            onInput=${A=>R_(A.target.value)}
          />
          <button
            class="control-btn ghost"
            onClick=${()=>{$e(),kt(),Zt((c==null?void 0:c.session_id)??null)}}
            disabled=${Ln.value||W.value}
          >
            ${Ln.value?"새로고침 중...":"새로고침"}
          </button>
        </div>
      </div>

      ${st.value?i`<section class="ops-banner error">${st.value}</section>`:null}
      ${Xt.value?i`<section class="ops-banner error">${Xt.value}</section>`:null}
      ${t?i`
        <section class="ops-banner ${h?"info":"warn"} ops-handoff-banner">
          <div class="ops-handoff-head">
            <strong>${t.source_label}</strong>
            <span>${ua(t.action_type)}</span>
            <span>${wi(t)}</span>
          </div>
          <div class="ops-handoff-body">${t.summary}</div>
          ${t.payload_preview?i`<div class="ops-handoff-preview">${t.payload_preview}</div>`:null}
          <div class="ops-handoff-meta">
            ${h?"추천 액션 기준으로 대상 선택과 입력값을 미리 맞춰 두었습니다.":"대상이 현재 snapshot에 없습니다. 일반 개입 화면으로 열렸고, 실제 대상 선택은 수동으로 해야 합니다."}
          </div>
        </section>
      `:null}

      ${(()=>{const A=[];if(l.length>0&&A.push({label:`확인 대기 ${l.length}건 처리`,desc:"승인 또는 거부가 필요한 개입이 대기 중입니다",tone:"bad",onClick:()=>{const T=document.querySelector(".ops-pending-section");T==null||T.scrollIntoView({behavior:"smooth"})}}),s.paused&&A.push({label:"Room 재개",desc:`현재 일시정지 상태${s.pause_reason?` (${s.pause_reason})`:""}`,tone:"warn",onClick:()=>void Cl()}),g.length>0){const T=g.filter(x=>Aa(x)==="bad");A.push({label:T.length>0?`Keeper ${T.length}개 오프라인`:`Keeper ${g.length}개 점검 필요`,desc:T.length>0?"메시지를 보내거나 상태를 확인하세요":"stale 또는 telemetry 누락",tone:T.length>0?"bad":"warn",onClick:()=>{const x=document.querySelector(".ops-keeper-section");x==null||x.scrollIntoView({behavior:"smooth"})}})}return A.length===0?null:i`
          <section class="ops-action-guide">
            <h3 class="ops-action-guide-title">지금 할 수 있는 것</h3>
            <div class="ops-action-guide-list">
              ${A.slice(0,3).map(T=>i`
                <button class="ops-action-guide-item ${T.tone}" onClick=${T.onClick}>
                  <strong>${T.label}</strong>
                  <span>${T.desc}</span>
                </button>
              `)}
            </div>
          </section>
        `})()}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">개입 우선순위</h2>
          <${z} panelId="intervene.priority_cards" compact=${!0} />
          <p class="monitor-subheadline">지금 가장 먼저 손댈 대상이 room인지, session인지, keeper인지 먼저 좁힙니다.</p>
        </div>
        <div class="ops-priority-grid">
          ${k.map(A=>i`
            <div key=${A.key} class="ops-priority-card ${A.tone}">
              <span class="ops-priority-label">${A.label}</span>
              <strong>${A.value}</strong>
              <div class="ops-priority-detail">${A.detail}</div>
            </div>
          `)}
        </div>
      </section>

      <div class="ops-workbench">
        <${B_} />
        <${W_} />
        <${H_} />
      </div>
    </section>
  `}function J_({text:e}){if(!e)return null;const t=V_(e);return i`<div class="markdown-content">${t}</div>`}function V_(e){const t=e.split(`
`),n=[];let s=0;for(;s<t.length;){const a=t[s];if(/^(`{3,}|~{3,})/.test(a)){const l=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(l.length).trim(),u=[];for(s++;s<t.length&&!t[s].startsWith(l);)u.push(t[s]),s++;s++,n.push(i`<pre><code class=${c?`language-${c}`:""}>${u.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const l=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&l.push(c),s++;s<t.length&&!t[s].includes("</think>");)l.push(t[s]),s++;if(s<t.length){const m=t[s].replace("</think>","").trim();m&&l.push(m),s++}const u=l.join(`
`).trim();n.push(i`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Ca(u)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const l=[];for(;s<t.length&&t[s].startsWith("> ");)l.push(t[s].slice(2)),s++;n.push(i`<blockquote>${Ca(l.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const o=[];for(;s<t.length;){const l=t[s];if(l.trim()===""||/^(`{3,}|~{3,})/.test(l)||l.startsWith("> ")||l.trim().startsWith("<think>"))break;o.push(l),s++}o.length>0&&n.push(i`<p>${Ca(o.join(`
`))}</p>`)}return n}function Ca(e){const t=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(e))!==null;){if(a.index>s&&t.push(e.slice(s,a.index)),a[1]){const o=a[1].slice(1,-1);t.push(i`<code>${o}</code>`)}else if(a[2]){const o=a[2].slice(2,-2);t.push(i`<strong>${o}</strong>`)}else if(a[3]){const o=a[3].slice(1,-1);t.push(i`<em>${o}</em>`)}else a[4]&&a[5]&&t.push(i`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<e.length&&t.push(e.slice(s)),t.length>0?t:[e]}const Il=[{id:"recent",label:"Latest"},{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],ks=_(null),xs=_([]),nn=_(!1),ht=_(null),bn=_(""),kn=_(!1),jt=_(!0),Ki=20,Pt=_(Ki);function Q_(){var t,n;const e=new URLSearchParams(window.location.search);return((t=e.get("agent"))==null?void 0:t.trim())||((n=e.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Y_=_(Q_());function X_(e){const t=e.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return t?t.length>180?`${t.slice(0,177)}...`:t:"No preview available"}function bo(e){return e.updated_at!==e.created_at}function Z_(e){const t=`${e.title} ${e.author} ${e.tags.join(" ")} ${e.flair??""}`.toLowerCase();return/\b(test|smoke|harness|sandbox|dummy|sample|tmp|qa|e2e)\b/.test(t)||t.includes("테스트")||t.includes("실험")}function ef(e){if(e.post_kind)return e.post_kind==="automation";const t=(e.hearth??"").toLowerCase();return e.visibility!=="internal"||!e.expires_at||!t?!1:!!(t.startsWith("mdal")||t.includes("harness"))}function Tl(e){return jt.value?e.filter(t=>ef(t)?!1:t.post_kind||t.hearth||t.visibility||t.expires_at?!0:!Z_(t)):e}async function Ui(e){ht.value=e,ks.value=null,xs.value=[],nn.value=!0;try{const t=await Uc(e);if(ht.value!==e)return;ks.value={id:t.id,author:t.author,title:t.title,content:t.content,tags:t.tags,votes:t.votes,vote_balance:t.vote_balance,comment_count:t.comment_count,created_at:t.created_at,updated_at:t.updated_at,post_kind:t.post_kind,flair:t.flair,hearth:t.hearth,visibility:t.visibility,expires_at:t.expires_at,hearth_count:t.hearth_count},xs.value=t.comments??[]}catch{ht.value===e&&(ks.value=null,xs.value=[])}finally{ht.value===e&&(nn.value=!1)}}async function ko(e){const t=bn.value.trim();if(t){kn.value=!0;try{await Bc(e,Y_.value,t),bn.value="",P("Comment posted","success"),await Ui(e),Ye()}catch{P("Failed to post comment","error")}finally{kn.value=!1}}}function tf(){const e=In.value,t=jt.value?"Hiding automation posts":"Show automation posts";return i`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Il.map(n=>i`
          <button
            class="board-sort-btn ${e===n.id?"active":""}"
            onClick=${()=>{In.value=n.id,Pt.value=Ki,Ye()}}
          >
            ${n.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${jt.value?"is-active":""}"
          onClick=${()=>{jt.value=!jt.value}}
        >
          ${t}
        </button>
        <button
          class="control-btn ghost ${Nt.value?"is-active":""}"
          onClick=${()=>{Nt.value=!Nt.value,Ye()}}
        >
          ${Nt.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${Ye} disabled=${Tn.value}>
          ${Tn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Ia(){var s;const e=((s=Il.find(a=>a.id===In.value))==null?void 0:s.label)??In.value,t=Tl(Cn.value),n=Cn.value.length-t.length;return i`
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
        <strong>${jt.value?`automation ${n} hidden`:"full feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${Nt.value?"Auto reports hidden":"Full memory feed"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${si.value?i`<${B} timestamp=${si.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function nf({post:e}){const t=async(n,s)=>{s.stopPropagation();try{await Xo(e.id,n),Ye()}catch{P("Failed to vote","error")}};return i`
    <div class="board-post" onClick=${()=>ec(e.id)}>
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
                ${bo(e)?i`<span class="board-meta-chip">Updated</span>`:null}
                ${e.hearth?i`<span class="board-meta-chip">${e.hearth}</span>`:null}
                ${e.visibility?i`<span class="board-meta-chip">${e.visibility}</span>`:null}
              </div>
            </div>
          <div class="post-meta">
            <span>By ${e.author}</span>
            <span><${B} timestamp=${e.created_at} /></span>
            ${bo(e)?i`<span>Updated <${B} timestamp=${e.updated_at} /></span>`:null}
            <span>${e.comment_count} comments</span>
            <span>${e.votes??0} votes</span>
          </div>
        </div>
        <div class="post-snippet">${X_(e.content)}</div>
      </div>
    </div>
  `}function sf({comments:e}){return e.length===0?i`<div class="empty-state" style="font-size:13px">No comments yet</div>`:i`
    <div class="comment-thread">
      ${e.map(t=>i`
        <div key=${t.id} class="board-comment">
          <span class="comment-author">${t.author}</span>
          <span class="comment-time"><${B} timestamp=${t.created_at} /></span>
          <div class="comment-text">${t.content}</div>
        </div>
      `)}
    </div>
  `}function af({postId:e}){return i`
    <div class="comment-form" style="margin-top:12px; display:flex; gap:8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${bn.value}
        onInput=${t=>{bn.value=t.target.value}}
        onKeyDown=${t=>{t.key==="Enter"&&ko(e)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${kn.value}
      />
      <button
        onClick=${()=>ko(e)}
        disabled=${kn.value||bn.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${kn.value?"...":"Post"}
      </button>
    </div>
  `}function of({post:e}){ht.value!==e.id&&!nn.value&&Ui(e.id);const t=async n=>{try{await Xo(e.id,n),Ye()}catch{P("Failed to vote","error")}};return i`
    <div>
      <button class="back-btn" onClick=${()=>ue("memory")}>← Back to Memory</button>
      <${I} title=${e.title} semanticId="memory.feed">
        <div class="board-detail">
          <div class="post-body">
            <${J_} text=${e.content} />
          </div>
          <div class="post-meta" style="margin-top:12px;">
            <span>${e.author}</span>
            <${B} timestamp=${e.created_at} />
            <span>${e.votes??0} votes</span>
          </div>
          ${e.hearth||e.visibility||e.expires_at?i`
                <div class="post-chip-row" style="margin-top:8px;">
                  ${e.hearth?i`<span class="board-meta-chip">${e.hearth}</span>`:null}
                  ${e.visibility?i`<span class="board-meta-chip">${e.visibility}</span>`:null}
                  ${e.expires_at?i`<span class="board-meta-chip">expires <${B} timestamp=${e.expires_at} /></span>`:null}
                </div>
              `:null}
          <div style="margin-top:8px; display:flex; gap:6px;">
            <button class="vote-btn upvote" onClick=${()=>t("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>t("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${I} title="Comments" semanticId="memory.feed">
        ${nn.value?i`<div class="loading-indicator">Loading comments...</div>`:i`<${sf} comments=${xs.value} />`}
        <${af} postId=${e.id} />
      <//>
    </div>
  `}function rf(){const e=Tl(Cn.value),t=j.value.params.post??null,n=t?e.find(s=>s.id===t)??(ht.value===t?ks.value:null):null;return t&&!n&&ht.value!==t&&!nn.value&&Ui(t),t?n?i`
          <${he} surfaceId="memory" />
          <${Ia} />
          <${of} post=${n} />
        `:i`
          <div>
            <${he} surfaceId="memory" />
            <${Ia} />
            <button class="back-btn" onClick=${()=>ue("memory")}>← Back to Memory</button>
            ${nn.value?i`<div class="loading-indicator">Loading post...</div>`:i`<div class="empty-state">Post not found</div>`}
          </div>
        `:i`
    <div>
      <${he} surfaceId="memory" />
      <${Ia} />
      <${tf} />
      ${Tn.value?i`<div class="loading-indicator">Loading memory feed...</div>`:e.length===0?i`<div class="empty-state">No posts in durable memory right now</div>`:i`
              <${I} title="Posts / Comments" class="section" semanticId="memory.feed">
                <div class="board-post-list">
                  ${e.slice(0,Pt.value).map(s=>i`<${nf} key=${s.id} post=${s} />`)}
                </div>
                ${e.length>Pt.value?i`
                  <div style="text-align:center; padding:12px 0;">
                    <button
                      class="control-btn ghost"
                      onClick=${()=>{Pt.value=Pt.value+Ki}}
                    >
                      Show more (${e.length-Pt.value} remaining)
                    </button>
                  </div>
                `:null}
              <//>
            `}
    </div>
  `}function lf({ratio:e,size:t=40,stroke:n=4}){if(e==null)return null;const s=(t-n)/2,a=t/2,o=2*Math.PI*s,l=o*((100-e*100)/100);let c="mitosis-safe";return e>=.8?c="mitosis-critical":e>=.5&&(c="mitosis-warn"),i`
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
  `}const vt=_(null),De=_(null),je=_(null);function _a(e){return e==="bad"||e==="critical"||e==="offline"?"bad":e==="warn"||e==="paused"||e==="blocked"||e==="interrupted"?"warn":"ok"}function cf(e){return typeof e!="number"||Number.isNaN(e)?"—":`${Math.round(e*100)}%`}function df(e){return e?Ue.value.find(t=>t.name===e||t.agent_name===e)??null:null}function uf(e){switch(e){case"working":return"작업 중";case"watching":return"대기 중";case"quiet":return"조용함";case"offline":return"오프라인"}}function pf(e){switch(e){case"critical":return"위험";case"warning":return"주의";default:return"정상"}}function xo(e){if(!e)return;const t=Gu({targetType:e.target_type,targetId:e.target_id,focusKind:e.focus_kind,operationId:e.operation_id??null,commandSurface:e.command_surface??null,sourceLabel:"Execution 진단",summary:e.label});Ar(t),ue(e.surface,e.surface==="intervene"?Cr(t):Tr(t))}function Rt({label:e,value:t,color:n,caption:s}){return i`
    <div class="stat-card">
      <div class="stat-label">${e}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${t}</div>
      ${s?i`<div class="monitor-stat-caption">${s}</div>`:null}
    </div>
  `}function Bi({intervene:e,command:t}){return i`
    <div class="control-row">
      ${e?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-intervene"
              onClick=${n=>{n.stopPropagation(),xo(e)}}
            >
              ${e.label}
            </button>
          `:null}
      ${t?i`
            <button
              class="control-btn ghost"
              data-testid="execution.handoff-command"
              onClick=${n=>{n.stopPropagation(),xo(t)}}
            >
              ${t.label}
            </button>
          `:null}
    </div>
  `}function mf({item:e,selected:t}){return i`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.queue-card"
      onClick=${()=>{vt.value=t?null:e.id,De.value=null,je.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.kind==="session"?e.target_id:e.linked_session_id??e.target_id}</div>
          <div class="mission-card-title">${e.summary}</div>
        </div>
        <span class="command-chip ${_a(e.severity)}">${e.status??e.severity}</span>
      </div>
      <div class="mission-card-meta">
        <span>${e.kind}</span>
        ${e.linked_operation_id?i`<span>linked op · ${e.linked_operation_id}</span>`:null}
        ${e.last_seen_at?i`<span><${B} timestamp=${e.last_seen_at} /></span>`:null}
      </div>
      <${Bi} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function vf({brief:e,selected:t}){return i`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.session-card"
      onClick=${()=>{De.value=t?null:e.session_id,je.value=null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.session_id}${e.room?` · ${e.room}`:""}</div>
          <div class="mission-card-title">${e.goal}</div>
        </div>
        <span class="command-chip ${_a(e.health??e.status)}">${e.status??"unknown"}</span>
      </div>
      <div class="mission-card-meta">
        <span>health · ${e.health??"ok"}</span>
        ${e.linked_operation_id?i`<span>op · ${e.linked_operation_id}</span>`:null}
        ${e.last_activity_at?i`<span><${B} timestamp=${e.last_activity_at} /></span>`:null}
      </div>
      ${e.runtime_blocker?i`<div class="mission-card-detail">${e.runtime_blocker}</div>`:e.last_activity_summary?i`<div class="mission-card-detail">${e.last_activity_summary}</div>`:null}
      ${e.worker_gap_summary?i`<div class="monitor-footnote">${e.worker_gap_summary}</div>`:null}
      <${Bi} intervene=${e.intervene_handoff} command=${e.command_handoff} />
    </button>
  `}function _f({brief:e,selected:t}){return i`
    <button
      class="mission-card-select ${t?"active":""}"
      data-testid="execution.operation-card"
      onClick=${()=>{je.value=t?null:e.operation_id,De.value=e.linked_session_id??null}}
    >
      <div class="mission-card-head">
        <div>
          <div class="mission-card-target">${e.operation_id}${e.assigned_unit_label?` · ${e.assigned_unit_label}`:""}</div>
          <div class="mission-card-title">${e.objective}</div>
        </div>
        <span class="command-chip ${_a(e.blocker_summary?"warn":e.status)}">${e.status??"unknown"}</span>
      </div>
      <div class="mission-card-meta">
        ${e.stage?i`<span>stage · ${e.stage}</span>`:null}
        ${e.linked_session_id?i`<span>session · ${e.linked_session_id}</span>`:null}
        ${e.updated_at?i`<span><${B} timestamp=${e.updated_at} /></span>`:null}
      </div>
      ${e.blocker_summary?i`<div class="mission-card-detail">${e.blocker_summary}</div>`:null}
      ${e.next_tool?i`<div class="monitor-footnote">next tool · ${e.next_tool}</div>`:null}
      <${Bi} command=${e.command_handoff} />
    </button>
  `}function So({row:e,testId:t}){return i`
    <button class="monitor-row ${e.tone} state-${e.state}" data-testid=${t} onClick=${()=>Pn(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.korean_name?i`<span class="monitor-sub">${e.korean_name}</span>`:null}
          </div>
          <div class="monitor-note">${e.note}</div>
        </div>
        <${ot} status=${e.status??"unknown"} />
        <span class="monitor-pill ${e.tone} state-${e.state}">${uf(e.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_signal_at?i`<span>신호 <${B} timestamp=${e.last_signal_at} /></span>`:i`<span>최근 신호 없음</span>`}
        <span>${(e.active_task_count??0)>0?`활성 작업 ${e.active_task_count}개`:"활성 작업 없음"}</span>
        ${e.related_session_id?i`<span>session · ${e.related_session_id}</span>`:null}
        ${e.related_operation_id?i`<span>op · ${e.related_operation_id}</span>`:null}
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.recent_output_preview&&e.recent_output_preview!==e.focus?i`<div class="monitor-footnote">최근 상세: ${e.recent_output_preview}</div>`:null}
    </button>
  `}function ff({row:e}){const t=()=>{const n=df(e.name);n&&Gr(n)};return i`
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
        <${lf} ratio=${e.context_ratio??0} size=${34} stroke=${4} />
        <${ot} status=${e.status??"unknown"} />
        <span class="monitor-pill ${e.tone}">${pf(e.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_signal_at?i`<span>최근 활동 <${B} timestamp=${e.last_signal_at} /></span>`:i`<span>최근 활동 없음</span>`}
        ${e.related_session_id?i`<span>session · ${e.related_session_id}</span>`:null}
        ${e.continuity?i`<span>${e.continuity}</span>`:null}
        ${e.lifecycle?i`<span>라이프사이클 ${e.lifecycle}</span>`:null}
        <span>컨텍스트 ${cf(e.context_ratio)}</span>
      </div>

      <div class="monitor-focus">${e.focus}</div>
      ${e.skill_reason?i`<div class="monitor-footnote">연속성 이유: ${e.skill_reason}</div>`:null}
    </button>
  `}function gf(){const e=sr.value,t=ar.value,n=ir.value,s=or.value,a=rr.value,o=lr.value,l=cr.value;vt.value&&!t.some($=>$.id===vt.value)&&(vt.value=null),De.value&&!n.some($=>$.session_id===De.value)&&(De.value=null),je.value&&!s.some($=>$.operation_id===je.value)&&(je.value=null);const c=vt.value?t.find($=>$.id===vt.value)??null:null,u=De.value?De.value:c?c.kind==="session"?c.target_id:c.linked_session_id??null:null,m=je.value?je.value:c?c.kind==="operation"?c.target_id:c.linked_operation_id??null:null,v=u?n.filter($=>$.session_id===u):m?n.filter($=>$.linked_operation_id===m):n,f=m?s.filter($=>$.operation_id===m):u?s.filter($=>{var C;return $.linked_session_id===u||$.operation_id===((C=v[0])==null?void 0:C.linked_operation_id)}):s,g=u||m?a.filter($=>(u?$.related_session_id===u:!1)||(m?$.related_operation_id===m:!1)):a,h=u?o.filter($=>$.related_session_id===u||$.tone!=="ok"):o,k=u||m?l.filter($=>(u?$.related_session_id===u:!1)||(m?$.related_operation_id===m:!1)||$.tone!=="ok"):l;return i`
    <div class="agents-monitor">
      <${he} surfaceId="execution" />
      <div class="stats-grid">
        <${Rt} label="활성 세션" value=${(e==null?void 0:e.active_sessions)??n.length} color="#4ade80" caption="실행 관점의 session" />
        <${Rt} label="막힌 세션" value=${(e==null?void 0:e.blocked_sessions)??n.filter($=>_a($.health??$.status)!=="ok").length} color="#fbbf24" caption="개입 후보 session" />
        <${Rt} label="활성 작전" value=${(e==null?void 0:e.active_operations)??s.length} color="#22d3ee" caption="command-plane operation" />
        <${Rt} label="막힌 작전" value=${(e==null?void 0:e.blocked_operations)??s.filter($=>$.blocker_summary).length} color="#fb7185" caption="원인 분석이 필요한 작전" />
        <${Rt} label="worker 경고" value=${(e==null?void 0:e.worker_alerts)??a.filter($=>$.tone!=="ok").length} color="#fb7185" caption="supporting worker pressure" />
        <${Rt} label="연속성 경고" value=${(e==null?void 0:e.continuity_alerts)??o.filter($=>$.tone!=="ok").length} color="#fb7185" caption="keeper continuity pressure" />
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
          ${t.length===0?i`<div class="empty-state">지금은 막힌 실행이 없습니다</div>`:t.map($=>i`<${mf} key=${$.id} item=${$} selected=${vt.value===$.id} />`)}
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
            ${v.length===0?i`<div class="empty-state">선택된 실행과 연결된 session이 없습니다</div>`:v.map($=>i`<${vf} key=${$.session_id} brief=${$} selected=${De.value===$.session_id} />`)}
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
            ${f.length===0?i`<div class="empty-state">선택된 실행과 연결된 operation이 없습니다</div>`:f.map($=>i`<${_f} key=${$.operation_id} brief=${$} selected=${je.value===$.operation_id} />`)}
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
            ${g.length===0?i`<div class="empty-state">연결된 worker가 없습니다</div>`:g.map($=>i`<${So} key=${$.name} row=${$} testId="execution.worker-card" />`)}
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
            ${h.length===0?i`<div class="empty-state">지금은 연속성 경고가 없습니다</div>`:h.map($=>i`<${ff} key=${$.name} row=${$} />`)}
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
            ${k.length===0?i`<div class="empty-state">지금은 오프라인 worker가 없습니다</div>`:k.map($=>i`<${So} key=${$.name} row=${$} testId="execution.offline-worker-card" />`)}
          </div>
        <//>
      </div>
    </div>
  `}const ea=_("all"),ta=_("all"),ui=_(new Set);function $f(e){const t=new Set(ui.value);t.has(e)?t.delete(e):t.add(e),ui.value=t}const Rl=xe(()=>{let e=Ft.value;return ea.value!=="all"&&(e=e.filter(t=>t.horizon===ea.value)),ta.value!=="all"&&(e=e.filter(t=>t.status===ta.value)),e}),hf=xe(()=>{const e={short:[],mid:[],long:[]};for(const t of Rl.value){const n=e[t.horizon];n&&n.push(t)}return e}),yf=xe(()=>{const e=Array.from(ur.value.values());return e.sort((t,n)=>t.status==="running"&&n.status!=="running"?-1:n.status==="running"&&t.status!=="running"?1:t.status==="interrupted"&&n.status!=="interrupted"?-1:n.status==="interrupted"&&t.status!=="interrupted"?1:n.elapsed_seconds-t.elapsed_seconds),e});function bf(e){return"★".repeat(Math.min(e,5))+"☆".repeat(Math.max(0,5-e))}function Wi(e){switch(e){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return e}}function Ss(e){switch(e){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function kf(e){return e<60?`${Math.round(e)}s`:e<3600?`${Math.floor(e/60)}m ${Math.round(e%60)}s`:`${Math.floor(e/3600)}h ${Math.floor(e%3600/60)}m`}function Ao(e){return e.toFixed(4)}function Co(e){const t=e.current_metric-e.baseline_metric;return`${t>=0?"+":""}${t.toFixed(4)}`}function xf(e){switch(e){case 1:return"P1";case 2:return"P2";case 3:return"P3";default:return"P4"}}function Io(e,t){return(e.priority??4)-(t.priority??4)}function Sf(e,t){const n=e.updated_at??e.created_at??"";return(t.updated_at??t.created_at??"").localeCompare(n)}function Af(e,t){return e.length<=t?e:e.slice(0,t)+"..."}function Cf({goal:e}){return i`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Ss(e.horizon)}">
            ${Wi(e.horizon)}
          </span>
          <span class="goal-title">${e.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${e.priority}">${bf(e.priority)}</span>
          ${e.metric?i`<span class="goal-metric">${e.metric}${e.target_value?` → ${e.target_value}`:""}</span>`:null}
          ${e.due_date?i`<span class="goal-due">Due: <${B} timestamp=${e.due_date} /></span>`:null}
        </div>
        ${e.last_review_note?i`
          <div class="goal-review-note">${e.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${ot} status=${e.status} />
        <div class="goal-updated">
          <${B} timestamp=${e.updated_at} />
        </div>
      </div>
    </div>
  `}function Ta({horizon:e,items:t}){if(t.length===0)return null;const n=[...t].sort((s,a)=>a.priority-s.priority);return i`
    <${I} title="${Wi(e)} Goals (${t.length})" class="section" semanticId="planning.goal_pipeline">
      <div class="goal-list">
        ${n.map(s=>i`<${Cf} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function If(){return i`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(e=>i`
          <button
            class="goal-filter-btn ${ea.value===e?"active":""}"
            onClick=${()=>{ea.value=e}}
          >
            ${e==="all"?"All":Wi(e)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(e=>i`
          <button
            class="goal-filter-btn ${ta.value===e?"active":""}"
            onClick=${()=>{ta.value=e}}
          >
            ${e==="all"?"All":e.charAt(0).toUpperCase()+e.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function Tf(){const e=Ft.value,t=e.filter(a=>a.status==="active").length,n=e.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of e)a.horizon in s&&s[a.horizon]++;return i`
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
        <div class="goal-summary-value" style="color:${Ss("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Ss("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Ss("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function Rf({loop:e}){const t=e.history[0],n=e.latest_tool_names&&e.latest_tool_names.length>0?`${e.latest_tool_call_count??e.latest_tool_names.length} tool${(e.latest_tool_call_count??e.latest_tool_names.length)===1?"":"s"}: ${e.latest_tool_names.join(", ")}`:"No evidence yet";return i`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${e.profile}</div>
            <div class="planning-loop-sub">${e.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${ot} status=${e.status} />
            <span class="pill">${e.current_iteration}${e.max_iterations>0?`/${e.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Ao(e.baseline_metric)}</span>
          <span>Current ${Ao(e.current_metric)}</span>
          <span class=${Co(e).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Co(e)}
          </span>
          <span>Elapsed ${kf(e.elapsed_seconds)}</span>
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
  `}function Ra({task:e}){const t=e.priority??4,n=t<=1?"p1":t===2?"p2":t===3?"p3":"p4",s=ui.value.has(e.id),a=!!e.description;return i`
    <div class="kanban-card ${n}">
      <div class="kanban-card-header">
        <span class="priority-badge priority-badge--${n}">${xf(t)}</span>
        <div class="kanban-card-title">${e.title}</div>
      </div>
      ${a?i`
        <div
          class="task-description-preview ${s?"task-description-preview--expanded":""}"
          onClick=${()=>$f(e.id)}
        >
          ${s?e.description:Af(e.description??"",80)}
        </div>
      `:null}
      <div class="kanban-card-meta">
        ${e.created_at?i`<${B} timestamp=${e.created_at} />`:i`<span>-</span>`}
        ${e.assignee?i`<span class="kanban-assignee">${e.assignee}</span>`:null}
      </div>
    </div>
  `}function wf(){const{todo:e,inProgress:t,done:n}=mr.value,s=[...e].sort(Io),a=[...t].sort(Io),o=[...n].sort(Sf);return i`
    <${I} title="Task Backlog" class="section" semanticId="planning.backlog">
      <div class="kanban-board">
        <div class="kanban-column">
          <div class="kanban-header todo">
            <span>TO DO</span>
            <span class="kanban-badge">${e.length}</span>
          </div>
          ${s.length===0?i`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:s.map(l=>i`<${Ra} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header inprogress">
            <span>IN PROGRESS</span>
            <span class="kanban-badge">${t.length}</span>
          </div>
          ${a.length===0?i`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:a.map(l=>i`<${Ra} key=${l.id} task=${l} />`)}
        </div>
        <div class="kanban-column">
          <div class="kanban-header done">
            <span>DONE</span>
            <span class="kanban-badge">${n.length}</span>
          </div>
          ${o.length===0?i`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:o.slice(0,20).map(l=>i`<${Ra} key=${l.id} task=${l} />`)}
          ${o.length>20?i`<div class="empty-state" style="opacity: 0.5;">...and ${o.length-20} more</div>`:null}
        </div>
      </div>
    <//>
  `}function Pf(){const{todo:e,inProgress:t,done:n}=mr.value,s=e.length+t.length+n.length,a=[...e,...t].filter(v=>(v.priority??4)<=2).length,o=hf.value,l=yf.value,c=Ft.value.length>0,u=l.length>0,m=xi.value;return i`
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
          onClick=${()=>{Ci(),yr()}}
          disabled=${fn.value||gn.value}
        >
          ${fn.value||gn.value?"Refreshing...":"Refresh planning data"}
        </button>
      </div>

      <!-- Step 2: Task Backlog at top -->
      <${wf} />

      <!-- Step 3: Goals in collapsible details -->
      <details class="overview-section-collapsible" open=${c}>
        <summary>
          Goal Pipeline
          <span class="monitor-pill">${Ft.value.length}</span>
        </summary>
        <div>
          ${c?i`
            <${Tf} />
            <${If} />
            ${fn.value&&Ft.value.length===0?i`<div class="loading-indicator">Loading goals...</div>`:Rl.value.length===0?i`<div class="empty-state">No goals match the current filters</div>`:i`
                    <${Ta} horizon="short" items=${o.short??[]} />
                    <${Ta} horizon="mid" items=${o.mid??[]} />
                    <${Ta} horizon="long" items=${o.long??[]} />
                  `}
          `:i`
            <div class="empty-state">
              No goals defined. Use <code>masc_goal_upsert</code> to create goals.
            </div>
          `}
        </div>
      </details>

      <!-- MDAL Loops in collapsible details -->
      <details class="overview-section-collapsible" open=${u}>
        <summary>
          MDAL Loops
          <span class="monitor-pill">${l.length}</span>
        </summary>
        <div>
          ${gn.value&&l.length===0?i`<div class="loading-indicator">Loading MDAL loops...</div>`:l.length===0&&(m==="error"||Kt.value)?i`<div class="empty-state">MDAL snapshot could not be loaded${Kt.value?`: ${Kt.value}`:""}. Check backend health.</div>`:l.length===0?i`<div class="empty-state">No active loops. Use <code>masc_mdal_start</code> to start a loop.</div>`:i`
                  <div class="planning-loop-list">
                    ${l.map(v=>i`<${Rf} key=${v.loop_id} loop=${v} />`)}
                  </div>
                `}
        </div>
      </details>
    </div>
  `}const na=_(!1),xn=_(!1),Ot=_(!1),at=_(""),Sn=_(""),pi=_("open"),Pe=_(null),Kn=_(null),sa=_(null),aa=_(null),mi=_(!1);function Un(e){return`${e.kind}:${e.id}`}function Hi(){var n;const e=Kn.value,t=((n=Pe.value)==null?void 0:n.items)??[];return e?t.find(s=>Un(s)===e)??null:null}function Lf(){const e=new URLSearchParams(window.location.search),t=e.get("agent")??e.get("agent_name");return(t==null?void 0:t.trim())||"dashboard"}function Nf(e){const t=e.trim().toLowerCase();return t==="open"||t==="pending"}function wl(e){return!!(e.judgment_summary&&e.judgment_summary.trim())}function Pl(e){switch(pi.value){case"needs_quorum":return e.filter(t=>t.kind==="consensus"&&(t.votes??0)<(t.quorum??0));case"ready":return e.filter(t=>{var n;return(n=t.guardrail_state)==null?void 0:n.ready_to_execute});case"needs_approval":return e.filter(t=>{var n,s;return((n=t.guardrail_state)==null?void 0:n.requires_human_gate)||!!((s=t.guardrail_state)!=null&&s.pending_confirm)});case"judge_offline":return e.filter(t=>!wl(t));case"open":default:return e.filter(t=>Nf(t.status))}}function Mf(e){if(e==null)return"none";if(typeof e=="string")return e;try{return JSON.stringify(e,null,2)}catch{return String(e)}}function fa(e){const t=(e||"").toLowerCase();return t.includes("reject")||t.includes("deny")||t.includes("closed")||t.includes("cancel")?"negative":t.includes("approve")||t.includes("support")||t.includes("open")||t.includes("ready")?"positive":"neutral"}function zf(e){return typeof e!="number"||Number.isNaN(e)?"n/a":`${Math.round(e*100)}%`}function pn(e){return"resolved_tool"in e||"payload_preview"in e||"reason"in e}async function Ll(e){if(sa.value=null,aa.value=null,!!e){mi.value=!0,at.value="";try{e.kind==="debate"?sa.value=await gd(e.id):aa.value=await $d(e.id)}catch(t){at.value=t instanceof Error?t.message:"Failed to load governance detail"}finally{mi.value=!1}}}async function Ef(e){Kn.value=Un(e),await Ll(e)}async function sn(){var e;na.value=!0,at.value="";try{const t=await kc();Pe.value=t;const n=Pl(t.items??[]),s=Kn.value,a=n.find(o=>Un(o)===s)??n[0]??((e=t.items)==null?void 0:e[0])??null;Kn.value=a?Un(a):null,await Ll(a)}catch(t){at.value=t instanceof Error?t.message:"Failed to load governance state"}finally{na.value=!1}}vu(sn);async function To(){const e=Sn.value.trim();if(e){xn.value=!0;try{const t=await fd(e);Sn.value="",P(t!=null&&t.id?`Debate started: ${t.id}`:"Debate started","success"),await sn()}catch(t){const n=t instanceof Error?t.message:"Failed to start debate";at.value=n,P(n,"error")}finally{xn.value=!1}}}async function Ro(e){var o,l;const t=Hi(),n=(o=t==null?void 0:t.guardrail_state)==null?void 0:o.pending_confirm,s=n==null?void 0:n.confirm_token;if(!s)return;const a=((l=n==null?void 0:n.actor)==null?void 0:l.trim())||Lf();Ot.value=!0;try{await Ho(a,s,e),P(e==="confirm"?"Action approved":"Action denied","success"),await sn()}catch(c){const u=c instanceof Error?c.message:"Failed to update pending action";at.value=u,P(u,"error")}finally{Ot.value=!1}}function Df(){var n,s,a,o,l,c;const e=(n=Pe.value)==null?void 0:n.summary,t=(s=Pe.value)==null?void 0:s.judge;return i`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Open debates</span>
        <strong>${(e==null?void 0:e.debates_open)??((o=(a=Pe.value)==null?void 0:a.debates)==null?void 0:o.length)??0}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Consensus sessions</span>
        <strong>${(e==null?void 0:e.sessions_active)??((c=(l=Pe.value)==null?void 0:l.sessions)==null?void 0:c.length)??0}</strong>
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
  `}function jf(){return i`
    <${I} title="Governance Console" class="section" semanticId="governance.supervisor">
      <div class="governance-toolbar">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Sn.value}
            onInput=${e=>{Sn.value=e.target.value}}
            onKeyDown=${e=>{e.key==="Enter"&&To()}}
            disabled=${xn.value}
          />
          <button
            class="control-btn secondary"
            onClick=${To}
            disabled=${xn.value||Sn.value.trim()===""}
          >
            ${xn.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${sn} disabled=${na.value}>
            ${na.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        <div class="governance-filter-row">
          ${[["open","Open"],["needs_quorum","Needs Quorum"],["ready","Ready"],["needs_approval","Needs Approval"],["judge_offline","Judge Offline"]].map(([e,t])=>i`
            <button
              class="control-btn ${pi.value===e?"is-active":"ghost"}"
              onClick=${async()=>{pi.value=e,await sn()}}
            >
              ${t}
            </button>
          `)}
        </div>
        ${at.value?i`<div class="council-error">${at.value}</div>`:null}
      </div>
    <//>
  `}function Of(){var t;const e=Pl(((t=Pe.value)==null?void 0:t.items)??[]);return i`
    <${I} title="Decision Inbox" class="section" semanticId="governance.inbox">
      <div class="council-list governance-inbox">
        ${e.length===0?i`
              <div class="empty-state">
                Governance is quiet. No debates or consensus sessions match the current filter.
              </div>
            `:e.map(n=>{var a,o;const s=Kn.value===Un(n);return i`
                <button
                  class="council-row governance-decision-row ${s?"selected":""}"
                  onClick=${()=>Ef(n)}
                >
                  <div class="council-row-main">
                    <div class="governance-row-head">
                      <span class="governance-kind">${n.kind}</span>
                      <span class="council-topic">${n.topic}</span>
                    </div>
                    <div class="council-sub">
                      <span>${n.truth_summary||"No fact summary"}</span>
                      ${n.last_activity_at?i`<span><${B} timestamp=${n.last_activity_at} /></span>`:null}
                    </div>
                    <div class="governance-chip-row">
                      ${(a=n.guardrail_state)!=null&&a.requires_human_gate?i`<span class="governance-chip warn">needs approval</span>`:null}
                      ${(o=n.guardrail_state)!=null&&o.ready_to_execute?i`<span class="governance-chip ok">ready</span>`:null}
                      ${n.kind==="consensus"&&(n.votes??0)<(n.quorum??0)?i`<span class="governance-chip warn">quorum debt</span>`:null}
                      ${wl(n)?null:i`<span class="governance-chip dim">judge offline</span>`}
                    </div>
                  </div>
                  <div class="governance-row-side">
                    <span class="council-state ${fa(n.status)}">${n.status}</span>
                    ${n.kind==="consensus"?i`<span class="governance-vote-meter">${n.votes??0}/${n.quorum??0}</span>`:i`<span class="governance-vote-meter">${n.evidence_refs.length} refs</span>`}
                  </div>
                </button>
              `})}
      </div>
    <//>
  `}function qf({argument:e}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${fa(e.position)}">${e.position}</span>
        <strong>${e.agent}</strong>
        ${e.created_at?i`<span><${B} timestamp=${e.created_at} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.content}</div>
      <div class="governance-chip-row">
        ${e.evidence.map(t=>i`<span class="governance-chip">${t}</span>`)}
        ${e.reply_to!=null?i`<span class="governance-chip">reply #${e.reply_to}</span>`:null}
        ${e.mentions.map(t=>i`<span class="governance-chip">@${t}</span>`)}
        ${e.archetype?i`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function Ff({vote:e}){return i`
    <div class="governance-ledger-row">
      <div class="governance-ledger-head">
        <span class="governance-badge ${fa(e.decision)}">${e.decision}</span>
        <strong>${e.agent}</strong>
        ${e.timestamp?i`<span><${B} timestamp=${e.timestamp} /></span>`:null}
      </div>
      <div class="governance-ledger-body">${e.reason||"No reason recorded."}</div>
      <div class="governance-chip-row">
        ${e.weight!=null?i`<span class="governance-chip">weight ${e.weight}</span>`:null}
        ${e.archetype?i`<span class="governance-chip dim">${e.archetype}</span>`:null}
      </div>
    </div>
  `}function Kf(){const e=Hi(),t=sa.value,n=aa.value;return i`
    <${I}
      title=${e?`${e.kind==="debate"?"Debate":"Consensus"} Detail`:"Decision Detail"}
      class="section"
      semanticId="governance.detail"
    >
      ${mi.value?i`<div class="loading-indicator">Loading governance detail...</div>`:e?e.kind==="debate"&&t?i`
                <div class="governance-detail-head">
                  <div>
                    <h3>${t.debate.topic}</h3>
                    <div class="council-sub">
                      <span>${t.debate.id}</span>
                      <span>${t.debate.status}</span>
                      ${t.debate.created_at?i`<span><${B} timestamp=${t.debate.created_at} /></span>`:null}
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
                  ${t.arguments.length===0?i`<div class="empty-state">No arguments recorded yet.</div>`:t.arguments.map(s=>i`<${qf} key=${s.index} argument=${s} />`)}
                </div>
              `:e.kind==="consensus"&&n?i`
                  <div class="governance-detail-head">
                    <div>
                      <h3>${n.session.topic}</h3>
                      <div class="council-sub">
                        <span>${n.session.id}</span>
                        <span>${n.session.state}</span>
                        <span>initiator ${n.session.initiator}</span>
                        ${n.session.created_at?i`<span><${B} timestamp=${n.session.created_at} /></span>`:null}
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
                    ${n.votes.length===0?i`<div class="empty-state">No votes recorded yet.</div>`:n.votes.map(s=>i`<${Ff} key=${s.agent+s.timestamp} vote=${s} />`)}
                  </div>
                `:i`<div class="empty-state">Detail is unavailable for this decision.</div>`:i`<div class="empty-state">Select a decision item to inspect truth and judgment.</div>`}
    <//>
  `}function wo({title:e,route:t}){if(!t)return null;const n=pn(t)?t.resolved_tool:t.delegated_tool,s=pn(t)?t.target_type:null,a=pn(t)?t.target_id:null,o=pn(t)?t.reason:null,l=pn(t)?t.payload_preview:null;return i`
    <div class="governance-side-block">
      <h4>${e}</h4>
      <div class="council-sub">
        ${n?i`<span>tool ${n}</span>`:null}
        ${"action_type"in t&&t.action_type?i`<span>action ${t.action_type}</span>`:null}
        ${"confirmation_state"in t&&t.confirmation_state?i`<span>${t.confirmation_state}</span>`:null}
        ${"created_at"in t&&t.created_at?i`<span><${B} timestamp=${t.created_at} /></span>`:null}
      </div>
      ${s?i`<div class="governance-side-line">target ${s}${a?`:${a}`:""}</div>`:null}
      ${o?i`<div class="governance-side-line">${o}</div>`:null}
      ${l?i`<pre class="council-detail governance-preview">${Mf(l)}</pre>`:null}
    </div>
  `}function Uf(){var c,u,m;const e=Hi(),t=sa.value,n=aa.value,s=(t==null?void 0:t.context)??(n==null?void 0:n.context)??(e==null?void 0:e.context),a=(t==null?void 0:t.judgment)??(n==null?void 0:n.judgment),o=e==null?void 0:e.guardrail_state,l=(c=Pe.value)==null?void 0:c.judge;return i`
    <div class="governance-side-column">
      <${I} title="Why / Guardrail" class="section" semanticId="governance.guardrail">
        ${e?i`
              <div class="governance-side-block">
                <h4>Judge</h4>
                <div class="council-sub">
                  <span>${l!=null&&l.judge_online?"online":"offline"}</span>
                  ${l!=null&&l.model_used?i`<span>${l.model_used}</span>`:null}
                  ${l!=null&&l.generated_at?i`<span><${B} timestamp=${l.generated_at} /></span>`:null}
                </div>
                ${e.judgment_summary?i`<div class="governance-summary-callout">${e.judgment_summary}</div>`:i`<div class="governance-side-line">No current LLM judgment. Showing truth layer only.</div>`}
                <div class="council-sub">
                  <span>confidence ${zf(e.confidence)}</span>
                  ${a!=null&&a.keeper_name?i`<span>${a.keeper_name}</span>`:null}
                </div>
              </div>

              <${wo} title="Recommended Route" route=${e.recommended_action} />
              <${wo} title="Executed Route" route=${e.executed_route} />

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
                          onClick=${()=>Ro("confirm")}
                          disabled=${Ot.value}
                        >
                          ${Ot.value?"Working...":"Approve"}
                        </button>
                        <button
                          class="control-btn ghost"
                          onClick=${()=>Ro("deny")}
                          disabled=${Ot.value}
                        >
                          ${Ot.value?"Working...":"Deny"}
                        </button>
                      </div>
                    `:i`<div class="governance-side-line">No pending human gate for this decision.</div>`}
              </div>
            `:i`<div class="empty-state">Select a decision to inspect judgment and route.</div>`}
      <//>

      <${I} title="Context" class="section" semanticId="governance.context">
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
                        ${e.related_agents.map(v=>i`<span class="governance-chip dim">${v}</span>`)}
                      </div>
                    `:i`<div class="governance-side-line">No explicit linked context recorded.</div>`}
                ${e.evidence_refs.length>0?i`
                      <div class="governance-side-line">evidence refs</div>
                      <div class="governance-chip-row">
                        ${e.evidence_refs.map(v=>i`<span class="governance-chip">${v}</span>`)}
                      </div>
                    `:null}
              </div>
          `:i`<div class="empty-state">No context selected.</div>`}
      <//>

      <${I} title="Recent Activity" class="section" semanticId="governance.activity">
        <div class="governance-activity-list">
          ${(((u=Pe.value)==null?void 0:u.activity)??[]).slice(0,8).map(v=>i`
            <div class="governance-activity-row">
              <div class="governance-ledger-head">
                <span class="governance-badge ${fa(v.kind)}">${v.kind}</span>
                ${v.actor?i`<strong>${v.actor}</strong>`:null}
                ${v.created_at?i`<span><${B} timestamp=${v.created_at} /></span>`:null}
              </div>
              <div class="governance-ledger-body">${v.summary||v.topic||"Activity recorded."}</div>
            </div>
          `)}
          ${(((m=Pe.value)==null?void 0:m.activity)??[]).length===0?i`<div class="empty-state">No governance activity recorded.</div>`:null}
        </div>
      <//>
    </div>
  `}function Bf(){return ne(()=>{sn()},[]),i`
    <div>
      <${he} surfaceId="governance" />
      <${Df} />
      <${jf} />
      <div class="governance-layout">
        <${Of} />
        <${Kf} />
        <${Uf} />
      </div>
    </div>
  `}const Lt=_(""),wa=_("ability_check"),Pa=_("10"),La=_("12"),cs=_(""),ds=_("idle"),Ge=_(""),us=_("keeper-late"),Na=_("player"),Ma=_(""),be=_("idle"),za=_(null),ps=_(""),Ea=_(""),Da=_("player"),ja=_(""),Oa=_(""),qa=_(""),An=_("20"),Fa=_("20"),Ka=_(""),ms=_("idle"),vi=_(null),Nl=_("overview"),Ua=_("all"),Ba=_("all"),Wa=_("all"),Wf=12e4,ga=_(null),Po=_(Date.now());function Hf(e,t){const n=t>0?e/t*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Gf(e,t){return t>0?Math.round(e/t*100):0}const Jf={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Vf={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function vs(e){const t=e.trim();return t?t.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):e}function Qf(e){const t=e.trim().toLowerCase();return Jf[t]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Yf(e){const t=e.trim().toLowerCase();return Vf[t]??"상황에 따라 선택되는 전술 액션입니다."}function ge(e,t,n=""){const s=e[t];return typeof s=="string"?s:n}function Ce(e,t,n=0){const s=e[t];return typeof s=="number"&&Number.isFinite(s)?s:n}function Bn(e,t,n=!1){const s=e[t];return typeof s=="boolean"?s:n}const Xf=new Set(["str","dex","con","int","wis","cha"]);function Zf(e){const t=e.trim();if(!t)return{};let n;try{n=JSON.parse(t)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!p(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,o])=>{const l=a.trim();if(l){if(typeof o=="number"&&Number.isFinite(o)){s[l]=Math.max(0,Math.trunc(o));return}if(typeof o=="string"){const c=Number.parseFloat(o.trim());if(Number.isFinite(c)){s[l]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${l}' 값은 숫자여야 합니다.`)}}),s}function eg(e){const t=Number.parseInt(e.trim(),10);if(!Number.isFinite(t))return;const n=Math.max(1,t),s=Number.parseInt(An.value.trim(),10);Number.isFinite(s)&&s>n&&(An.value=String(n))}function _i(e){const n=(e.actor_name??e.actor??e.actor_id??"system").trim();return n===""?"system":n}function tg(e){var n;return(((n=e.timestamp)==null?void 0:n.trim())??"")||"-"}function ng(e){Nl.value=e}function Ml(e){const t=ga.value;return t==null||t<=e}function sg(e){const t=ga.value;return t==null||t<=e?0:Math.max(0,Math.ceil((t-e)/1e3))}function ia(){ga.value=null}function zl(e){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(e)}function ag(e,t){zl(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${e||"-"}`,`PHASE: ${t||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(ga.value=Date.now()+Wf,P("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function As(e){return Ml(e)?(P("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function fi(e,t,n){return zl([`[위험 액션 확인] ${e}`,`ROOM: ${t||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function ig({hp:e,max:t}){const n=Gf(e,t),s=Hf(e,t);return i`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function og({stats:e}){const t=[{label:"STR",value:e.strength},{label:"DEX",value:e.dexterity},{label:"CON",value:e.constitution},{label:"INT",value:e.intelligence},{label:"WIS",value:e.wisdom},{label:"CHA",value:e.charisma}];return i`
    <div class="trpg-actor-stats">
      ${t.map(n=>i`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function rg({keeper:e,role:t}){if(!e)return null;const n=t==="dm"?"dm":"player";return i`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${e}
    </span>
  `}function El({actor:e}){var u,m,v,f;const t=(u=e.archetype)==null?void 0:u.trim(),n=(m=e.persona)==null?void 0:m.trim(),s=(v=e.portrait)==null?void 0:v.trim(),a=(f=e.background)==null?void 0:f.trim(),o=e.traits??[],l=e.skills??[],c=Object.entries(e.stats_raw??{}).filter(([g,h])=>Number.isFinite(h)).filter(([g])=>!Xf.has(g.toLowerCase()));return i`
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
        <${ot} status=${e.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${e.role}">${e.role}</span>
        <${rg} keeper=${e.keeper} role=${e.role} />
      </div>
      ${e.stats?i`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${e.stats.hp}/${e.stats.max_hp}
              ${e.stats.max_mp>0?i`<span style="margin-left:8px;">MP ${e.stats.mp}/${e.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${e.stats.level}</span>
            </div>
            <${ig} hp=${e.stats.hp} max=${e.stats.max_hp} />
            <${og} stats=${e.stats} />
          </div>
        `:null}
      ${t?i`<div class="trpg-actor-meta">Archetype: ${vs(t)}</div>`:null}
      ${a?i`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?i`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?i`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([g,h])=>i`
                <span class="trpg-custom-stat-chip">${vs(g)} ${h}</span>
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
                  <span class="trpg-annot-name">${vs(g)}</span>
                  <span class="trpg-annot-desc">${Qf(g)}</span>
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
                  <span class="trpg-annot-name">${vs(g)}</span>
                  <span class="trpg-annot-desc">${Yf(g)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function lg({mapStr:e}){return i`<pre class="trpg-map">${e}</pre>`}function Dl({events:e,emptyLabel:t="아직 이벤트가 없습니다."}){return e.length===0?i`<div class="empty-state" style="font-size:13px">${t}</div>`:i`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${e.map((n,s)=>{var a;return i`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${tg(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${_i(n)}</strong>
            ${" "}
          ${n.dice_roll?i`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${B} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function cg({events:e}){const t="__none__",n=Ua.value,s=Ba.value,a=Wa.value,o=Array.from(new Set(e.map(_i).map(f=>f.trim()).filter(f=>f!==""))).sort((f,g)=>f.localeCompare(g)),l=Array.from(new Set(e.map(f=>(f.type??"").trim()).filter(f=>f!==""))).sort((f,g)=>f.localeCompare(g)),c=e.some(f=>(f.type??"").trim()===""),u=Array.from(new Set(e.map(f=>(f.phase??"").trim()).filter(f=>f!==""))).sort((f,g)=>f.localeCompare(g)),m=e.some(f=>(f.phase??"").trim()===""),v=e.filter(f=>{if(n!=="all"&&_i(f)!==n)return!1;const g=(f.type??"").trim(),h=(f.phase??"").trim();if(s===t){if(g!=="")return!1}else if(s!=="all"&&g!==s)return!1;if(a===t){if(h!=="")return!1}else if(a!=="all"&&h!==a)return!1;return!0});return i`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${f=>{Ua.value=f.target.value}}>
          <option value="all">all</option>
          ${o.map(f=>i`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${f=>{Ba.value=f.target.value}}>
          <option value="all">all</option>
          ${c?i`<option value=${t}>(none)</option>`:null}
          ${l.map(f=>i`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${f=>{Wa.value=f.target.value}}>
          <option value="all">all</option>
          ${m?i`<option value=${t}>(none)</option>`:null}
          ${u.map(f=>i`<option value=${f}>${f}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{Ua.value="all",Ba.value="all",Wa.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${v.length} / 전체 ${e.length}
      </span>
    </div>
    <${Dl} events=${v.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function dg({outcome:e}){if(!e)return null;const t=o=>{const l=o.trim();return l&&(/[A-Z]/.test(l)&&!l.includes(" ")?l.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():l.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=e.result==="victory"?"승리":e.result==="defeat"?"패배":e.result==="draw"?"무승부":"종료",s=e.result==="victory"?"#34d399":e.result==="defeat"?"#f87171":"#9ca3af",a=[e.reason?`원인: ${t(e.reason)}`:null,e.phase?`페이즈: ${t(e.phase)}`:null,typeof e.turn=="number"?`턴: ${e.turn}`:null].filter(Boolean).join(" · ");return i`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${e.summary?i`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${t(e.summary)}</div>`:null}
      ${a?i`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function jl({state:e}){const t=e.history??[];return t.length===0?null:i`
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
  `}function ug({state:e,nowMs:t}){var m;const n=qe.value||((m=e.session)==null?void 0:m.room)||"",s=ds.value,a=e.party??[];if(!a.find(v=>v.id===Lt.value)&&a.length>0){const v=a[0];v&&(Lt.value=v.id)}const l=async()=>{var f,g;if(!n){P("Room ID가 비어 있습니다.","error");return}if(!As(t))return;const v=((f=e.current_round)==null?void 0:f.phase)??((g=e.session)==null?void 0:g.status)??"unknown";if(fi("라운드 실행",n,v)){ds.value="running";try{const h=await id(n);vi.value=h,ds.value="ok";const k=p(h.summary)?h.summary:null,$=k?Bn(k,"advanced",!1):!1,C=k?ge(k,"progress_reason",""):"";P($?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${C?`: ${C}`:""}`,$?"success":"warning"),Xe()}catch(h){vi.value=null,ds.value="error";const k=h instanceof Error?h.message:"라운드 실행에 실패했습니다.";P(k,"error")}finally{ia()}}},c=async()=>{var f,g;if(!n||!As(t))return;const v=((f=e.current_round)==null?void 0:f.phase)??((g=e.session)==null?void 0:g.status)??"unknown";if(fi("턴 강제 진행",n,v))try{await ld(n),P("턴을 다음 단계로 이동했습니다.","success"),Xe()}catch{P("턴 이동에 실패했습니다.","error")}finally{ia()}},u=async()=>{if(!n||!As(t))return;const v=Lt.value.trim();if(!v){P("먼저 Actor를 선택하세요.","warning");return}const f=Number.parseInt(Pa.value,10),g=Number.parseInt(La.value,10);if(Number.isNaN(f)||Number.isNaN(g)){P("stat/dc는 숫자여야 합니다.","warning");return}const h=Number.parseInt(cs.value,10),k=cs.value.trim()===""||Number.isNaN(h)?void 0:h;try{await rd({roomId:n,actorId:v,action:wa.value.trim()||"ability_check",statValue:f,dc:g,rawD20:k}),P("주사위 판정을 기록했습니다.","success"),Xe()}catch{P("주사위 판정 기록에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${v=>{qe.value=v.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${Lt.value}
            onChange=${v=>{Lt.value=v.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(v=>i`<option value=${v.id}>${v.name} (${v.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${wa.value}
              onInput=${v=>{wa.value=v.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Pa.value}
              onInput=${v=>{Pa.value=v.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${La.value}
              onInput=${v=>{La.value=v.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${cs.value}
              onInput=${v=>{cs.value=v.target.value}}
              onKeyDown=${v=>{v.key==="Enter"&&u()}}
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

      ${s!=="idle"?i`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function pg({state:e}){var a;const t=qe.value||((a=e.session)==null?void 0:a.room)||"",n=ms.value,s=async()=>{if(!t){P("Room ID가 비어 있습니다.","warning");return}const o=ps.value.trim(),l=Ea.value.trim();if(!l&&!o){P("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(An.value.trim(),10),u=Number.parseInt(Fa.value.trim(),10),m=Number.isFinite(u)?Math.max(1,u):20,v=Number.isFinite(c)?Math.max(0,Math.min(m,c)):m;let f={};try{f=Zf(Ka.value)}catch(g){P(g instanceof Error?g.message:"능력치 JSON 오류","error");return}ms.value="spawning";try{const g=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,h=await cd(t,{actor_id:o||void 0,name:l||void 0,role:Da.value,idempotencyKey:g,portrait:Oa.value.trim()||void 0,background:qa.value.trim()||void 0,hp:v,max_hp:m,alive:v>0,stats:Object.keys(f).length>0?f:void 0}),k=typeof h.actor_id=="string"?h.actor_id.trim():"";if(!k)throw new Error("생성 응답에 actor_id가 없습니다.");const $=ja.value.trim();$&&await dd(t,k,$),Lt.value=k,Ge.value=k,o||(ps.value=""),ms.value="ok",P(`Actor 생성 완료: ${k}`,"success"),await Xe()}catch(g){ms.value="error",P(g instanceof Error?g.message:"Actor 생성에 실패했습니다.","error")}};return i`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${Ea.value}
            onInput=${o=>{Ea.value=o.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Da.value}
            onChange=${o=>{Da.value=o.target.value}}
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
            value=${ja.value}
            onInput=${o=>{ja.value=o.target.value}}
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
              value=${ps.value}
              onInput=${o=>{ps.value=o.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${Oa.value}
              onInput=${o=>{Oa.value=o.target.value}}
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
              value=${Fa.value}
              onInput=${o=>{const l=o.target.value;Fa.value=l,eg(l)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${qa.value}
              onInput=${o=>{qa.value=o.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${Ka.value}
              onInput=${o=>{Ka.value=o.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?i`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function mg({state:e,nowMs:t}){var g;const n=qe.value||((g=e.session)==null?void 0:g.room)||"",s=e.join_gate,a=za.value,o=p(a)?a:null,l=(e.party??[]).filter(h=>h.role!=="dm"),c=Ge.value.trim(),u=l.some(h=>h.id===c),m=u?c:c?"__manual__":"",v=async()=>{const h=Ge.value.trim(),k=us.value.trim();if(!n||!h){P("Room/Actor가 필요합니다.","warning");return}be.value="checking";try{const $=await ud(n,h,k||void 0);za.value=$,be.value="ok",P("참가 가능 여부를 갱신했습니다.","success")}catch($){be.value="error";const C=$ instanceof Error?$.message:"참가 가능 여부 확인에 실패했습니다.";P(C,"error")}},f=async()=>{var A,T;const h=Ge.value.trim(),k=us.value.trim(),$=Ma.value.trim();if(!n||!h||!k){P("Room/Actor/Keeper가 필요합니다.","warning");return}if(!As(t))return;const C=((A=e.current_round)==null?void 0:A.phase)??((T=e.session)==null?void 0:T.status)??"unknown";if(fi("Mid-Join 승인 요청",n,C)){be.value="requesting";try{const x=await pd({room_id:n,actor_id:h,keeper_name:k,role:Na.value,...$?{name:$}:{}});za.value=x;const R=p(x)?Bn(x,"granted",!1):!1,w=p(x)?ge(x,"reason_code",""):"";R?P("Mid-Join이 승인되었습니다.","success"):P(`Mid-Join이 거절되었습니다${w?`: ${w}`:""}`,"warning"),be.value=R?"ok":"error",Xe()}catch(x){be.value="error";const R=x instanceof Error?x.message:"Mid-Join 요청에 실패했습니다.";P(R,"error")}finally{ia()}}};return i`
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
            onChange=${h=>{const k=h.target.value;if(k==="__manual__"){(u||!c)&&(Ge.value="");return}Ge.value=k}}
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
                value=${Ge.value}
                onInput=${h=>{Ge.value=h.target.value}}
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
            value=${us.value}
            onInput=${h=>{us.value=h.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Na.value}
            onChange=${h=>{Na.value=h.target.value}}
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
            value=${Ma.value}
            onInput=${h=>{Ma.value=h.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${v} disabled=${be.value==="checking"||be.value==="requesting"}>
              ${be.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${f} disabled=${be.value==="checking"||be.value==="requesting"}>
              ${be.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${o?i`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${Bn(o,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Ce(o,"effective_score",0)}/${Ce(o,"required_points",0)}</span>
            ${ge(o,"reason_code","")?i`<span style="margin-left:8px;">Reason: ${ge(o,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Ol({state:e}){const t=[...e.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return t.length===0?i`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:i`
    <div class="trpg-round-list">
      ${t.map(n=>i`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function ql({state:e}){var n;const t=e.current_round;return t?i`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${t.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${t.phase}</div>
      ${t.events.length>0?i`<div class="trpg-next-action-target">
            Last: ${(n=t.events[t.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Fl(){const e=vi.value;if(!e)return i`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const t=e.summary,n=p(t)?t:null,a=(Array.isArray(e.statuses)?e.statuses:[]).filter(p).slice(-8),o=e.canon_check,l=p(o)?o:null,c=l&&Array.isArray(l.warnings)?l.warnings.filter(w=>typeof w=="string").slice(0,3):[],u=l&&Array.isArray(l.violations)?l.violations.filter(w=>typeof w=="string").slice(0,3):[],m=n?Bn(n,"advanced",!1):!1,v=n?ge(n,"progress_reason",""):"",f=n?ge(n,"progress_detail",""):"",g=n?Ce(n,"player_successes",0):0,h=n?Ce(n,"player_required_successes",0):0,k=n?Bn(n,"dm_success",!1):!1,$=n?Ce(n,"timeouts",0):0,C=n?Ce(n,"unavailable",0):0,A=n?Ce(n,"reprompts",0):0,T=n?Ce(n,"npc_attacks",0):0,x=n?Ce(n,"keeper_timeout_sec",0):0,R=n?Ce(n,"roll_audit_count",0):0;return i`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${m?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${m?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${e.turn_before??0} → ${e.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${k?"DM ok":"DM stalled"} / players ${g}/${h}
          </span>
        </div>
        ${v?i`<div style="margin-top:4px; font-size:12px;">${v}</div>`:null}
        ${f?i`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${f}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${$}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${T}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${x||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${R}</div></div>
      </div>

      ${a.length>0?i`
          <div class="trpg-round-list">
            ${a.map(w=>{const E=ge(w,"status","unknown"),J=ge(w,"actor_id","-"),D=ge(w,"role","-"),te=ge(w,"reason",""),se=ge(w,"action_type",""),G=ge(w,"reply","");return i`
                <div class="trpg-round-item ${E.includes("fallback")||E.includes("timeout")?"failed":"active"}">
                  <span>${J} (${D})</span>
                  <span style="margin-left:auto; font-size:11px;">${E}</span>
                  ${se?i`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${se}</div>`:null}
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
            ${u.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${u.map(w=>i`<div>violation: ${w}</div>`)}
                </div>`:null}
            ${c.length>0?i`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(w=>i`<div>warning: ${w}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function vg({state:e,nowMs:t}){var l,c,u;const n=qe.value||((l=e.session)==null?void 0:l.room)||"",s=((c=e.current_round)==null?void 0:c.phase)??((u=e.session)==null?void 0:u.status)??"unknown",a=Ml(t),o=sg(t);return i`
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
          ${a?i`<button class="trpg-run-btn recommend" onClick=${()=>ag(n,s)}>잠금 해제 (120초)</button>`:i`<button class="trpg-run-btn secondary" onClick=${()=>{ia(),P("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function _g({active:e}){return i`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>i`
        <button
          class="trpg-screen-tab ${e===n.id?"active":""}"
          role="tab"
          aria-selected=${e===n.id}
          onClick=${()=>ng(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function fg({state:e}){const t=e.party??[],n=e.story_log??[];return i`
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
          <${Dl} events=${n.slice(-20)} />
        <//>

        ${e.map?i`
            <${I} title="맵" style="margin-top:16px;" semanticId="lab.trpg">
              <${lg} mapStr=${e.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${I} title="현재 라운드" semanticId="lab.trpg">
          <${ql} state=${e} />
        <//>

        <${I} title="기여도" style="margin-top:16px;" semanticId="lab.trpg">
          <${Ol} state=${e} />
        <//>

        <${I} title=${`파티 (${t.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${t.map(s=>i`<${El} key=${s.id??s.name} actor=${s} />`)}
            ${t.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${e.history&&e.history.length>0?i`
            <${I} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
              <${jl} state=${e} />
            <//>
          `:null}
      </div>
    </div>
  `}function gg({state:e}){const t=e.story_log??[];return i`
    <div class="trpg-layout">
      <div>
        <${I} title=${`이벤트 타임라인 (${t.length})`}>
          <${cg} events=${t} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${I} title="최근 라운드 결과" semanticId="lab.trpg">
          <${Fl} />
        <//>

        <${I} title="현재 라운드" style="margin-top:16px;" semanticId="lab.trpg">
          <${ql} state=${e} />
        <//>
      </div>
    </div>
  `}function $g({state:e,nowMs:t}){const n=e.party??[];return i`
    <div>
      <${vg} state=${e} nowMs=${t} />
      <div class="trpg-layout">
        <div>
          <${I} title="조작 패널" semanticId="lab.trpg">
            <${ug} state=${e} nowMs=${t} />
          <//>

          <${I} title="Actor Spawn" style="margin-top:16px;" semanticId="lab.trpg">
            <${pg} state=${e} />
          <//>

          <${I} title="Mid-Join Gate" style="margin-top:16px;" semanticId="lab.trpg">
            <${mg} state=${e} nowMs=${t} />
          <//>

          <${I} title="최근 라운드 결과" style="margin-top:16px;" semanticId="lab.trpg">
            <${Fl} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${I} title="기여도" style="margin-top:0;" semanticId="lab.trpg">
            <${Ol} state=${e} />
          <//>

          <${I} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>i`<${El} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?i`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${e.history&&e.history.length>0?i`
              <${I} title=${`히스토리 (${e.history.length})`} style="margin-top:16px;">
                <${jl} state=${e} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function hg(){var c,u,m,v,f;const e=dr.value,t=ni.value;if(ne(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const g=window.setInterval(()=>{Po.value=Date.now()},1e3);return()=>{window.clearInterval(g)}},[]),t&&!e)return i`<div class="loading-indicator">Loading TRPG state...</div>`;if(!e)return i`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Xe()}>Refresh</button>
      </div>
    `;const n=e.party??[],s=e.story_log??[],a=e.outcome,o=Nl.value,l=Po.value;return i`
    <div>
      <${he} surfaceId="lab" />
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${qe.value||((c=e.session)==null?void 0:c.room)||"-"} · phase: ${((u=e.current_round)==null?void 0:u.phase)??((m=e.session)==null?void 0:m.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Xe()}>새로고침</button>
      </div>

      <${dg} outcome=${a} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((v=e.session)==null?void 0:v.status)??"active"}</div>
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

      <${_g} active=${o} />

      ${o==="overview"?i`<${fg} state=${e} />`:o==="timeline"?i`<${gg} state=${e} />`:i`<${$g} state=${e} nowMs=${l} />`}
    </div>
  `}function yg(){return i`
    <div>
      <${he} surfaceId="lab" />
      <${I} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      <${I} title="TRPG" class="section" semanticId="lab.trpg">
        <${hg} />
      <//>
    </div>
  `}const oa=_(new Set(["broadcast","tasks","keepers","system"]));function bg(e){const t=new Set(oa.value);t.has(e)?t.delete(e):t.add(e),oa.value=t}const Gi=_(null);function Kl(e){Gi.value=e}function kg(e){return e.kind==="board"?"broadcast":e.kind==="tasks"?"tasks":e.kind==="keepers"?"keepers":"system"}const xg=xe(()=>{const e=oa.value;return Is.value.filter(t=>e.has(kg(t)))}),Sg=12e4,Ag=xe(()=>{const e=vr.value,t=Date.now();return ze.value.map(n=>{const s=n.name.trim().toLowerCase(),a=e.get(s)??null;let o="idle";if(n.status==="active"||n.status==="busy"){const l=a==null?void 0:a.lastActivityAt;l?o=t-new Date(l).getTime()>Sg?"stale":"working":o="working"}else(n.status==="offline"||n.status==="inactive")&&(o="stale");return{name:n.name,emoji:n.emoji??"",koreanName:n.koreanName??null,state:o,currentTask:n.current_task,motion:a}})}),Cg=xe(()=>{const e=vr.value;return ze.value.filter(t=>t.status==="active"||t.status==="busy"||t.status==="listening"||t.status==="idle").map(t=>{const n=t.name.trim().toLowerCase(),s=e.get(n),a=(s==null?void 0:s.activeAssignedCount)??0;let o="calm";return a>=3?o="hot":a>=1&&(o="normal"),{name:t.name,emoji:t.emoji??"",koreanName:t.koreanName??null,currentTask:t.current_task,lastActivityAt:(s==null?void 0:s.lastActivityAt)??null,lastActivityText:(s==null?void 0:s.lastActivityText)??null,assignedCount:a,pressure:o}}).sort((t,n)=>{const s={hot:0,normal:1,calm:2};return s[t.pressure]-s[n.pressure]})});function Lo(e){return e.kind==="board"?"live-event-broadcast":e.kind==="tasks"?"live-event-task":e.kind==="keepers"?"live-event-keeper":"live-event-system"}function Ig(e){const t=e.eventType;return t==="broadcast"?"broadcast":t==="agent_joined"?"joined":t==="agent_left"?"left":t==="task_update"?"task":t==="board_post"?"post":t==="board_comment"?"comment":t==="keeper_heartbeat"?"heartbeat":t==="keeper_handoff"?"handoff":t==="keeper_compaction"?"compact":t==="keeper_guardrail"?"guardrail":e.kind==="board"?"board":e.kind==="tasks"?"task":e.kind==="keepers"?"keeper":"system"}function Tg(e){switch(e){case"working":return"pulse-working";case"stale":return"pulse-stale";default:return"pulse-idle"}}function Rg(){const e=Ag.value,t=Gi.value;return e.length===0?i`
      <div class="pulse-strip">
        <span class="pulse-strip-empty">No agents connected</span>
      </div>
    `:i`
    <div class="pulse-strip">
      ${e.map(n=>i`
        <button
          key=${n.name}
          class="pulse-bubble ${Tg(n.state)} ${t===n.name?"pulse-selected":""}"
          onClick=${()=>Kl(t===n.name?null:n.name)}
          title="${n.koreanName?`${n.name} (${n.koreanName})`:n.name}${n.currentTask?` — ${n.currentTask}`:""}"
        >
          <span class="pulse-emoji">${n.emoji||n.name.charAt(0).toUpperCase()}</span>
          <span class="pulse-name">${n.koreanName??n.name}</span>
        </button>
      `)}
    </div>
  `}const wg=[{kind:"broadcast",label:"Broadcast",cssClass:"live-event-broadcast"},{kind:"tasks",label:"Task",cssClass:"live-event-task"},{kind:"keepers",label:"Keeper",cssClass:"live-event-keeper"},{kind:"system",label:"System",cssClass:"live-event-system"}];function Pg(){const e=oa.value;return i`
    <div class="activity-filter-bar">
      ${wg.map(t=>i`
        <button
          key=${t.kind}
          class="activity-filter-btn ${t.cssClass} ${e.has(t.kind)?"active":""}"
          onClick=${()=>bg(t.kind)}
        >
          ${t.label}
        </button>
      `)}
    </div>
  `}function Lg(){const e=xg.value;return i`
    <div class="activity-stream">
      <div class="activity-stream-head">
        <h3>Activity Stream</h3>
        <span class="activity-count">${e.length} events</span>
      </div>
      <${Pg} />
      <div class="activity-stream-list">
        ${e.length===0?i`<div class="activity-empty">No events matching filters</div>`:e.map((t,n)=>i`
            <div
              key=${`${t.timestamp}-${n}`}
              class="activity-item ${Lo(t)} ${n===0?"activity-item-new":""}"
            >
              <div class="activity-item-head">
                <span class="activity-kind-chip ${Lo(t)}">${Ig(t)}</span>
                <span class="activity-agent">${t.agent}</span>
                <span class="activity-time">${Er(t.timestamp)}</span>
              </div>
              <div class="activity-item-text">${t.text}</div>
            </div>
          `)}
      </div>
    </div>
  `}function Ng(e){switch(e){case"hot":return"focus-pressure-hot";case"normal":return"focus-pressure-normal";default:return"focus-pressure-calm"}}function Mg(e){switch(e){case"hot":return"High";case"normal":return"Active";default:return"Calm"}}function zg(){const e=Cg.value,t=Gi.value;return i`
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
              onClick=${()=>Kl(t===n.name?null:n.name)}
            >
              <div class="focus-agent-header">
                <span class="focus-agent-name">
                  ${n.emoji?i`<span class="focus-emoji">${n.emoji}</span>`:null}
                  ${n.koreanName??n.name}
                </span>
                <span class="focus-pressure-badge ${Ng(n.pressure)}">
                  ${Mg(n.pressure)}
                  ${n.assignedCount>0?i` <span class="focus-task-count">${n.assignedCount}</span>`:null}
                </span>
              </div>
              ${n.currentTask?i`<div class="focus-current-task">${n.currentTask}</div>`:null}
              <div class="focus-agent-footer">
                ${n.lastActivityText?i`<span class="focus-activity-text">${n.lastActivityText}</span>`:i`<span class="focus-activity-text focus-no-activity">No recent activity</span>`}
                ${n.lastActivityAt?i`<${B} timestamp=${n.lastActivityAt} />`:null}
              </div>
            </div>
          `)}
      </div>
    </div>
  `}function Eg(){const e=tt.value;return i`
    <div class="live-monitor">
      <div class="live-header">
        <h2>Live Monitor</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${e?"connected":"disconnected"}"></span>
            ${e?"Connected":"Offline"}
          </span>
          <span class="live-stat">${ze.value.length} agents</span>
          <span class="live-stat">${ra.value} events</span>
        </div>
      </div>

      <${Rg} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${Lg} />
        </div>
        <div class="live-panel-side">
          <${zg} />
        </div>
      </div>
    </div>
  `}const No=[{id:"observe",label:"Observe",description:"지금 상태, 실행 압력, 계획 상태를 먼저 읽는 운영 표면"},{id:"context",label:"Context",description:"비동기 메모리와 의사결정 거버넌스를 분리해서 보는 표면"},{id:"act",label:"Act",description:"개입과 system-of-record 지휘를 실행하는 표면"},{id:"lab",label:"Lab",description:"실험적 기능은 메인 operator console 밖으로 분리"}],gi=[{id:"mission",label:"Mission",icon:"🏠",group:"observe",description:"지금 문제, 다음 액션, 운영 포커스를 먼저 보는 기본 랜딩"},{id:"proof",label:"Proof",icon:"🔍",group:"observe",description:"협업, 대화, 도구, backing evidence를 증명 중심으로 읽는 표면"},{id:"execution",label:"Execution",icon:"🤖",group:"observe",description:"worker, task, keeper continuity를 분리해서 보는 실행 표면"},{id:"live",label:"Live",icon:"📡",group:"observe",description:"실시간 에이전트 활동과 이벤트 스트림을 한눈에 모니터링"},{id:"planning",label:"Planning",icon:"🎯",group:"observe",description:"goal, metric loop, backlog 압력을 읽는 계획 표면"},{id:"memory",label:"Memory",icon:"💬",group:"context",description:"posts/comments만으로 room의 비동기 메모리를 읽는 표면"},{id:"governance",label:"Governance",icon:"⚖️",group:"context",description:"debate와 voting만 분리해 의사결정 상태를 보는 표면"},{id:"intervene",label:"Intervene",icon:"🎮",group:"act",description:"room, session, keeper 액션을 실행하는 개입 화면"},{id:"command",label:"Command",icon:"🧭",group:"act",description:"유닛 계층, 작전 체인, 승인, 추적 이력을 보는 상세 화면"},{id:"lab",label:"Lab",icon:"⚔️",group:"lab",description:"TRPG 같은 실험 surface를 메인 console 밖에서 다룹니다"}],_s=_(!1);function Dg(){const e=tt.value;return i`
    <div class="connection-status ${e?"connected":"disconnected"}">
      <span class="status-dot ${e?"connected":"disconnected"}"></span>
      <span class="status-text">${e?"Live":"재연결 중..."}</span>
      <span class="event-count">${ra.value} events</span>
    </div>
  `}function Ul(e){const t=e==null?void 0:e.trim();return t?t.length>10?t.slice(0,10):t:"commit unavailable"}function jg(){const e=oe.value,t=e==null?void 0:e.build,n=t?`v${t.release_version} · ${Ul(t.commit)}`:e!=null&&e.version?`v${e.version} · commit unavailable`:"version unavailable";return i`
    <div class="build-identity-wrap">
      <button
        class="version-badge build-badge-trigger"
        type="button"
        aria-expanded=${_s.value}
        onClick=${()=>{_s.value=!_s.value}}
      >
        Server Build · ${n}
      </button>
      ${_s.value?i`
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
                <strong>${t!=null&&t.started_at?i`<${B} timestamp=${t.started_at} />`:"unknown"}</strong>
              </div>
              <div class="build-badge-row">
                <span>업타임</span>
                <strong>${typeof(t==null?void 0:t.uptime_seconds)=="number"?`${t.uptime_seconds}s`:"unknown"}</strong>
              </div>
              <div class="build-badge-row">
                <span>쉘 스냅샷</span>
                <strong>${e!=null&&e.generated_at?i`<${B} timestamp=${e.generated_at} />`:"unknown"}</strong>
              </div>
            </div>
          `:null}
    </div>
  `}function $i(e){e==="command"&&(Et(),Gt(),(X.value==="swarm"||X.value==="warroom")&&Ve(),X.value==="warroom"&&$e()),e==="mission"&&(kr(),Ns()),e==="proof"&&Qr(j.value.params.session_id,j.value.params.operation_id),e==="execution"&&ft(),e==="intervene"&&($e(),kt()),e==="memory"&&Ye(),e==="planning"&&Ci(),e==="lab"&&Xe()}function Og({currentTab:e}){var s;const t=tt.value,n=(s=oe.value)==null?void 0:s.build;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${z} panelId="side_rail.snapshot" compact=${!0} />
        <span class="rail-section-chip ${t?"ok":"bad"}">${t?"Live":"Offline"}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>Agent</span>
          <strong>${ze.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Keeper</span>
          <strong>${Ue.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Task</span>
          <strong>${Le.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Event</span>
          <strong>${ra.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Hn(),$r(),$i(e)}}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${()=>ue("intervene")}>
          개입 열기
        </button>
      </div>
      ${n?i`<div class="rail-build-hint">Server Build · v${n.release_version} · ${Ul(n.commit)}</div>`:null}
    </section>
  `}function qg(){const e=ve.value,t=(e==null?void 0:e.pending_confirms.length)??0,n=(e==null?void 0:e.sessions.length)??0,s=(e==null?void 0:e.keepers.length)??0;return i`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${z} panelId="side_rail.quick_actions" compact=${!0} />
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
          onClick=${()=>{$e(),kt()}}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${()=>ue("intervene")}>
          개입 열기
        </button>
      </div>
    </section>
  `}function Fg(){const e=j.value.tab,t=gi.find(s=>s.id===e),n=No.find(s=>s.id===(t==null?void 0:t.group));return i`
    <aside class="dashboard-rail">
      <${he} surfaceId="side_rail" compact=${!0} />
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>탐색</h3>
          <${z} panelId="side_rail.navigate" compact=${!0} />
          ${n?i`<span class="rail-section-chip">${n.label}</span>`:null}
        </div>
        ${No.map(s=>i`
          <div class="rail-nav-group" key=${s.id}>
            <div class="rail-group-label">${s.label}</div>
            <div class="rail-group-copy">${s.description}</div>
            <div class="rail-tab-list">
              ${gi.filter(a=>a.group===s.id).map(a=>i`
                  <button
                    class="rail-tab-btn ${e===a.id?"active":""}"
                    onClick=${()=>ue(a.id)}
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

      <${Og} currentTab=${e} />
      <${qg} />
    </aside>
  `}function Kg(){switch(j.value.tab){case"mission":return i`<${vo} />`;case"proof":return i`<${qv} />`;case"execution":return i`<${gf} />`;case"live":return i`<${Eg} />`;case"memory":return i`<${rf} />`;case"governance":return i`<${Bf} />`;case"planning":return i`<${Pf} />`;case"intervene":return i`<${G_} />`;case"command":return i`<${I_} />`;case"lab":return i`<${yg} />`;default:return i`<${vo} />`}}function Ug(){ne(()=>{tc(),Fo(),hr(),ft(),$r(),kr();const n=gu();return $u(),()=>{cc(),n(),hu()}},[]),ne(()=>{const n=setInterval(()=>{$i(j.value.tab)},15e3);return()=>{clearInterval(n)}},[]),ne(()=>{$i(j.value.tab)},[j.value.tab]);const e=j.value.tab,t=gi.find(n=>n.id===e);return i`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <${jg} />
          </h1>
          <p class="header-subtitle">${(t==null?void 0:t.description)??"운영자 의사결정 및 실행 콘솔"}</p>
        </div>
        <div class="header-right">
          <${Dg} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${Fg} />
        <main class="dashboard-main">
          ${ti.value&&!tt.value?i`<div class="loading-indicator">Loading dashboard...</div>`:i`<${Kg} />`}
        </main>
      </div>

      <${tm} />
      <${kp} />
      <${vp} />
    </div>
  `}const Mo=document.getElementById("app");Mo&&Ql(i`<${Ug} />`,Mo);export{um as _};
